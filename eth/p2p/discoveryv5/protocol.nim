import
  std/[tables, sets, options, math, random],
  json_serialization/std/net,
  stew/[byteutils, endians2], chronicles, chronos, stint,
  eth/[rlp, keys], ../enode, types, encoding, node, routing_table, enr

import nimcrypto except toHex

logScope:
  topics = "discv5"

const
  alpha = 3 ## Kademlia concurrency factor
  lookupRequestLimit = 3
  findNodeResultLimit = 15 # applies in FINDNODE handler
  maxNodesPerPacket = 3
  lookupInterval = 60.seconds ## Interval of launching a random lookup to
  ## populate the routing table. go-ethereum seems to do 3 runs every 30
  ## minutes. Trinity starts one every minute.
  handshakeTimeout* = 2.seconds ## timeout for the reply on the
  ## whoareyou message
  responseTimeout* = 2.seconds ## timeout for the response of a request-response
  ## call
  magicSize = 32 ## size of the magic which is the start of the whoareyou
  ## message

type
  Protocol* = ref object
    transp: DatagramTransport
    localNode*: Node
    privateKey: PrivateKey
    whoareyouMagic: array[magicSize, byte]
    idHash: array[32, byte]
    pendingRequests: Table[AuthTag, PendingRequest]
    db: Database
    routingTable: RoutingTable
    codec*: Codec
    awaitedPackets: Table[(Node, RequestId), Future[Option[Packet]]]
    lookupLoop: Future[void]
    revalidateLoop: Future[void]

  PendingRequest = object
    node: Node
    packet: seq[byte]

proc whoareyouMagic(toNode: NodeId): array[magicSize, byte] =
  const prefix = "WHOAREYOU"
  var data: array[prefix.len + sizeof(toNode), byte]
  data[0 .. sizeof(toNode) - 1] = toNode.toByteArrayBE()
  for i, c in prefix: data[sizeof(toNode) + i] = byte(c)
  sha256.digest(data).data

proc newProtocol*(privKey: PrivateKey, db: Database,
                  ip: IpAddress, tcpPort, udpPort: Port): Protocol =
  let
    a = Address(ip: ip, tcpPort: tcpPort, udpPort: udpPort)
    enode = initENode(privKey.getPublicKey(), a)
    enrRec = enr.Record.init(12, privKey, a)
    node = newNode(enode, enrRec)

  result = Protocol(
    privateKey: privKey,
    db: db,
    localNode: node,
    whoareyouMagic: whoareyouMagic(node.id),
    idHash: sha256.digest(node.id.toByteArrayBE).data,
    codec: Codec(localNode: node, privKey: privKey, db: db))

  result.routingTable.init(node)

func privKey*(p: Protocol): lent PrivateKey =
  p.privateKey

proc send(d: Protocol, a: Address, data: seq[byte]) =
  # debug "Sending bytes", amount = data.len, to = a
  let ta = initTAddress(a.ip, a.udpPort)
  let f = d.transp.sendTo(ta, data)
  f.callback = proc(data: pointer) {.gcsafe.} =
    if f.failed:
      debug "Discovery send failed", msg = f.readError.msg

proc send(d: Protocol, n: Node, data: seq[byte]) =
  d.send(n.node.address, data)

proc `xor`[N: static[int], T](a, b: array[N, T]): array[N, T] =
  for i in 0 .. a.high:
    result[i] = a[i] xor b[i]

proc isWhoAreYou(d: Protocol, msg: Bytes): bool =
  if msg.len > d.whoareyouMagic.len:
    result = d.whoareyouMagic == msg.toOpenArray(0, magicSize - 1)

proc decodeWhoAreYou(d: Protocol, msg: Bytes): Whoareyou =
  result = Whoareyou()
  result[] = rlp.decode(msg.toRange[magicSize .. ^1], WhoareyouObj)

proc sendWhoareyou(d: Protocol, address: Address, toNode: NodeId, authTag: AuthTag) =
  trace "sending who are you", to = $toNode, toAddress = $address
  let challenge = Whoareyou(authTag: authTag, recordSeq: 0)
  encoding.randomBytes(challenge.idNonce)
  # If there is already a handshake going on for this nodeid then we drop this
  # new one. Handshake will get cleaned up after `handshakeTimeout`.
  # If instead overwriting the handshake would be allowed, the handshake timeout
  # will need to be canceled each time.
  # TODO: could also clean up handshakes in a seperate call, e.g. triggered in
  # a loop.
  # Use toNode + address to make it more difficult for an attacker to occupy
  # the handshake of another node.

  let key = HandShakeKey(nodeId: toNode, address: $address)
  if not d.codec.handshakes.hasKeyOrPut(key, challenge):
    sleepAsync(handshakeTimeout).addCallback() do(data: pointer):
      # TODO: should we still provide cancellation in case handshake completes
      # correctly?
      d.codec.handshakes.del(key)

    var data = @(whoareyouMagic(toNode))
    data.add(rlp.encode(challenge[]))
    d.send(address, data)

proc sendNodes(d: Protocol, toNode: Node, reqId: RequestId, nodes: openarray[Node]) =
  proc sendNodes(d: Protocol, toNode: Node, packet: NodesPacket, reqId: RequestId) {.nimcall.} =
    let (data, _) = d.codec.encodeEncrypted(toNode, encodePacket(packet, reqId), challenge = nil)
    d.send(toNode, data)

  var packet: NodesPacket
  packet.total = ceil(nodes.len / maxNodesPerPacket).uint32

  for i in 0 ..< nodes.len:
    packet.enrs.add(nodes[i].record)
    if packet.enrs.len == 3:
      d.sendNodes(toNode, packet, reqId)
      packet.enrs.setLen(0)

  if packet.enrs.len != 0:
    d.sendNodes(toNode, packet, reqId)

proc handlePing(d: Protocol, fromNode: Node, ping: PingPacket, reqId: RequestId) =
  let a = fromNode.address
  var pong: PongPacket
  pong.enrSeq = ping.enrSeq
  pong.ip = case a.ip.family
    of IpAddressFamily.IPv4: @(a.ip.address_v4)
    of IpAddressFamily.IPv6: @(a.ip.address_v6)
  pong.port = a.udpPort.uint16

  let (data, _) = d.codec.encodeEncrypted(fromNode, encodePacket(pong, reqId), challenge = nil)
  d.send(fromNode, data)

proc handleFindNode(d: Protocol, fromNode: Node, fn: FindNodePacket, reqId: RequestId) =
  if fn.distance == 0:
    d.sendNodes(fromNode, reqId, [d.localNode])
  else:
    let distance = min(fn.distance, 256)
    d.sendNodes(fromNode, reqId, d.routingTable.neighboursAtDistance(distance))

proc receive*(d: Protocol, a: Address, msg: Bytes) {.gcsafe,
  raises: [
    Defect,
    # TODO This is now coming from Chronos's callSoon
    Exception,
    # TODO All of these should probably be handled here
    RlpError,
    IOError,
    TransportAddressError,
    EthKeysException,
    Secp256k1Exception,
  ].} =
  if msg.len < tagSize: # or magicSize, can be either
    return # Invalid msg

  # debug "Packet received: ", length = msg.len

  if d.isWhoAreYou(msg):
    trace "Received whoareyou", localNode = $d.localNode, address = a
    let whoareyou = d.decodeWhoAreYou(msg)
    var pr: PendingRequest
    if d.pendingRequests.take(whoareyou.authTag, pr):
      let toNode = pr.node
      try:
        let (data, _) = d.codec.encodeEncrypted(toNode, pr.packet, challenge = whoareyou)
        d.send(toNode, data)
      except RandomSourceDepleted as err:
        debug "Failed to respond to a who-you-are msg " &
              "due to randomness source depletion."

  else:
    var tag: array[tagSize, byte]
    tag[0 .. ^1] = msg.toOpenArray(0, tagSize - 1)
    let senderData = tag xor d.idHash
    let sender = readUintBE[256](senderData)

    var authTag: AuthTag
    var node: Node
    var packet: Packet
    let decoded = d.codec.decodeEncrypted(sender, a, msg, authTag, node, packet)
    if decoded == DecodeStatus.Success:
      if node.isNil:
        node = d.routingTable.getNode(sender)
      else:
        debug "Adding new node to routing table", node = $node, localNode = $d.localNode
        discard d.routingTable.addNode(node)

      doAssert(not node.isNil, "No node in the routing table (internal error?)")

      case packet.kind
      of ping:
        d.handlePing(node, packet.ping, packet.reqId)
      of findNode:
        d.handleFindNode(node, packet.findNode, packet.reqId)
      else:
        var waiter: Future[Option[Packet]]
        if d.awaitedPackets.take((node, packet.reqId), waiter):
          waiter.complete(packet.some)
        else:
          debug "TODO: handle packet: ", packet = packet.kind, origin = $node
    elif decoded == DecodeStatus.DecryptError:
      debug "Could not decrypt packet, respond with whoareyou",
        localNode = $d.localNode, address = a
      # only sendingWhoareyou in case it is a decryption failure
      d.sendWhoareyou(a, sender, authTag)
    elif decoded == DecodeStatus.PacketError:
      # Still adding the node in case there is a packet error (could be
      # unsupported packet)
      if not node.isNil:
        debug "Adding new node to routing table", node = $node, localNode = $d.localNode
        discard d.routingTable.addNode(node)

proc waitPacket(d: Protocol, fromNode: Node, reqId: RequestId): Future[Option[Packet]] =
  result = newFuture[Option[Packet]]("waitPacket")
  let res = result
  let key = (fromNode, reqId)
  sleepAsync(responseTimeout).addCallback() do(data: pointer):
    d.awaitedPackets.del(key)
    if not res.finished:
      res.complete(none(Packet))
  d.awaitedPackets[key] = result

proc addNodesFromENRs(result: var seq[Node], enrs: openarray[Record]) =
  for r in enrs: result.add(newNode(r))

proc waitNodes(d: Protocol, fromNode: Node, reqId: RequestId): Future[seq[Node]] {.async.} =
  var op = await d.waitPacket(fromNode, reqId)
  if op.isSome and op.get.kind == nodes:
    result.addNodesFromENRs(op.get.nodes.enrs)
    let total = op.get.nodes.total
    for i in 1 ..< total:
      op = await d.waitPacket(fromNode, reqId)
      if op.isSome and op.get.kind == nodes:
        result.addNodesFromENRs(op.get.nodes.enrs)
      else:
        break

proc findNode(d: Protocol, toNode: Node, distance: uint32): Future[seq[Node]] {.async.} =
  let reqId = newRequestId()
  let packet = encodePacket(FindNodePacket(distance: distance), reqId)
  let (data, nonce) = d.codec.encodeEncrypted(toNode, packet, challenge = nil)
  d.pendingRequests[nonce] = PendingRequest(node: toNode, packet: packet)
  d.send(toNode, data)
  result = await d.waitNodes(toNode, reqId)

proc lookupDistances(target, dest: NodeId): seq[uint32] =
  let td = logDist(target, dest)
  result.add(td)
  var i = 1'u32
  while result.len < lookupRequestLimit:
    if td + i < 256:
      result.add(td + i)
    if td - i > 0'u32:
      result.add(td - i)
    inc i

proc lookupWorker(p: Protocol, destNode: Node, target: NodeId): Future[seq[Node]] {.async.} =
  let dists = lookupDistances(target, destNode.id)
  var i = 0
  while i < lookupRequestLimit and result.len < findNodeResultLimit:
    # TODO: Handle failures
    let r = await p.findNode(destNode, dists[i])
    # TODO: I guess it makes sense to limit here also to `findNodeResultLimit`?
    result.add(r)
    inc i

  for n in result:
    discard p.routingTable.addNode(n)

proc lookup*(p: Protocol, target: NodeId): Future[seq[Node]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # TODO: Sort the returned nodes on distance
  result = p.routingTable.neighbours(target, BUCKET_SIZE)
  var asked = initHashSet[NodeId]()
  asked.incl(p.localNode.id)
  var seen = asked
  for node in result:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)

  while true:
    var i = 0
    while i < result.len and pendingQueries.len < alpha:
      let n = result[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
      inc i

    trace "discv5 pending queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let idx = await oneIndex(pendingQueries)
    trace "Got discv5 lookup response", idx

    let nodes = pendingQueries[idx].read
    pendingQueries.del(idx)
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        if result.len < BUCKET_SIZE:
          result.add(n)

proc lookupRandom*(p: Protocol): Future[seq[Node]]
    {.raises:[RandomSourceDepleted, Defect, Exception].} =
  var id: NodeId
  if randomBytes(addr id, sizeof(id)) != sizeof(id):
    raise newException(RandomSourceDepleted, "Could not randomize bytes")
  p.lookup(id)

proc processClient(transp: DatagramTransport,
                   raddr: TransportAddress): Future[void] {.async, gcsafe.} =
  var proto = getUserData[Protocol](transp)
  try:
    # TODO: Maybe here better to use `peekMessage()` to avoid allocation,
    # but `Bytes` object is just a simple seq[byte], and `ByteRange` object
    # do not support custom length.
    var buf = transp.getMessage()
    let a = Address(ip: raddr.address, udpPort: raddr.port, tcpPort: raddr.port)
    proto.receive(a, buf)
  except RlpError as e:
    debug "Receive failed", exception = e.name, msg = e.msg
  # TODO: what else can be raised? Figure this out and be more restrictive?
  except CatchableError as e:
    debug "Receive failed", exception = e.name, msg = e.msg,
      stacktrace = e.getStackTrace()

proc ping(p: Protocol, toNode: Node): RequestId =
  let
    reqId = newRequestId()
    ping = PingPacket(enrSeq: p.localNode.record.seqNum)
    packet = encodePacket(ping, reqId)
    (data, nonce) = p.codec.encodeEncrypted(toNode, packet, challenge = nil)
  p.pendingRequests[nonce] = PendingRequest(node: toNode, packet: packet)
  p.send(toNode, data)
  return reqId

proc revalidateNode(p: Protocol, n: Node)
    {.async, raises:[Defect, Exception].} = # TODO: Exception
  let reqId = p.ping(n)

  let resp = await p.waitPacket(n, reqId)
  if resp.isSome and resp.get.kind == pong:
    let pong = resp.get.pong
    if pong.enrSeq > n.record.seqNum:
      # TODO: Request new ENR
      discard

    p.routingTable.setJustSeen(n)
    trace "Revalidated node", node = $n
  else:
    if false: # TODO: if not bootnode:
      p.routingTable.removeNode(n)

proc revalidateLoop(p: Protocol) {.async.} =
  try:
    # TODO: We need to handle actual errors still, which might just allow to
    # continue the loop. However, currently `revalidateNode` raises a general
    # `Exception` making this rather hard.
    while true:
      await sleepAsync(rand(10 * 1000).milliseconds)
      let n = p.routingTable.nodeToRevalidate()
      if not n.isNil:
        # TODO: Should we do these in parallel and/or async to be certain of how
        # often nodes are revalidated?
        await p.revalidateNode(n)
  except CancelledError:
    trace "revalidateLoop canceled"

proc lookupLoop(d: Protocol) {.async.} =
  ## TODO: Same story as for `revalidateLoop`
  try:
    while true:
      let nodes = await d.lookupRandom()
      trace "Discovered nodes", nodes = $nodes
      await sleepAsync(lookupInterval)
  except CancelledError:
    trace "lookupLoop canceled"

proc open*(d: Protocol) =
  debug "Starting discovery node", node = $d.localNode,
    uri = toURI(d.localNode.record)
  # TODO allow binding to specific IP / IPv6 / etc
  let ta = initTAddress(IPv4_any(), d.localNode.node.address.udpPort)
  d.transp = newDatagramTransport(processClient, udata = d, local = ta)
  # Might want to move these to a separate proc if this turns out to be needed.
  d.lookupLoop = lookupLoop(d)
  d.revalidateLoop = revalidateLoop(d)

proc close*(d: Protocol) =
  doAssert(not d.lookupLoop.isNil() or not d.revalidateLoop.isNil())
  doAssert(not d.transp.closed)

  debug "Closing discovery node", node = $d.localNode
  d.revalidateLoop.cancel()
  d.lookupLoop.cancel()
  # TODO: unsure if close can't create issues in the not awaited cancellations
  # above
  d.transp.close()

proc closeWait*(d: Protocol) {.async.} =
  doAssert(not d.lookupLoop.isNil() or not d.revalidateLoop.isNil())
  doAssert(not d.transp.closed)

  debug "Closing discovery node", node = $d.localNode
  await allFutures([d.revalidateLoop.cancelAndWait(),
    d.lookupLoop.cancelAndWait()])
  await d.transp.closeWait()

proc addNode*(d: Protocol, node: Node) =
  discard d.routingTable.addNode(node)

template addNode*(d: Protocol, enode: ENode) =
  addNode d, newNode(enode)

template addNode*(d: Protocol, r: Record) =
  addNode d, newNode(r)

proc addNode*(d: Protocol, enr: EnrUri) =
  var r: Record
  let res = r.fromUri(enr)
  doAssert(res)
  d.addNode newNode(r)

proc randomNodes*(k: Protocol, count: int): seq[Node] =
  k.routingTable.randomNodes(count)

proc nodesDiscovered*(k: Protocol): int {.inline.} = k.routingTable.len

when isMainModule:
  import discovery_db
  import eth/trie/db

  proc genDiscoveries(n: int): seq[Protocol] =
    var pks = ["98b3d4d4fe348ac5192d16b46aa36c41f847b9f265ba4d56f6326669449a968b", "88d125288fbb19ecd7b6a355faf3e842e3c6158d38af14bb97ac8d957ec9cb58", "c9a24471d2f84efa103b9abbdedd4c0fea8402f94e5ceb3ca4d9cff951fc407f"]
    for i in 0 ..< n:
      var pk: PrivateKey
      if i < pks.len:
        pk = initPrivateKey(pks[i])
      else:
        pk = newPrivateKey()

      let d = newProtocol(pk, DiscoveryDB.init(newMemoryDB()),
                          parseIpAddress("127.0.0.1"), Port(12001 + i), Port(12001 + i))
      d.open()
      result.add(d)

  proc addNode(d: openarray[Protocol], enr: string) =
    for dd in d: dd.addNode(EnrUri(enr))

  proc test() {.async.} =
    block:
      let d = genDiscoveries(3)
      d.addNode("enr:-IS4QPvi3TdAUd2Jdrx-8ScRbCzrV1kVsTTM02mfz8Fx7CtrAfYN7AjxTx3MWbY2efRmAhS-Yyv4nhyzKu_YS6jSh08BgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQJeWTAJhJYN2q3BvcQwsyo7pIi8KnfwDIrhNdflCFvqr4N1ZHCCD6A")

      for i, dd in d:
        let nodes = await dd.lookupRandom()
        echo "NODES ", i, ": ", nodes

    # block:
    #   var d = genDiscoveries(4)
    #   let rootD = d[0]
    #   d.del(0)


    #   d.addNode(rootD.localNode.record.toUri)

    #   for i, dd in d:
    #     let nodes = await dd.lookupRandom()
    #     echo "NODES ", i, ": ", nodes

  waitFor test()
  runForever()
