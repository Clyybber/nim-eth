import
  std/options,
  stint, stew/endians2, stew/shims/net,
  types, node, lru

export lru

{.push raises: [Defect].}

const keySize = sizeof(NodeId) +
                16 + # max size of ip address (ipv6)
                2 # Sizeof port

type
  SessionKey* = array[keySize, byte]
  SessionValue* = array[sizeof(AesKey) + sizeof(AesKey), byte]
  Sessions* = LRUCache[SessionKey, SessionValue]

proc makeKey(id: NodeId, address: Address): SessionKey =
  var pos = 0
  result[pos ..< pos+sizeof(id)] = toBytes(id)
  pos.inc(sizeof(id))
  case address.ip.family
  of IpAddressFamily.IpV4:
    result[pos ..< pos+sizeof(address.ip.address_v4)] = address.ip.address_v4
  of IpAddressFamily.IpV6:
    result[pos ..< pos+sizeof(address.ip.address_v6)] = address.ip.address_v6
  pos.inc(sizeof(address.ip.address_v6))
  result[pos ..< pos+sizeof(address.port)] = toBytes(address.port.uint16)

proc store*(s: var Sessions, id: NodeId, address: Address, r, w: AesKey) =
  var value: array[sizeof(r) + sizeof(w), byte]
  value[0 .. 15] = r
  value[16 .. ^1] = w
  s.put(makeKey(id, address), value)

proc load*(s: var Sessions, id: NodeId, address: Address, r, w: var AesKey): bool =
  let res = s.get(makeKey(id, address))
  if res.isSome():
    let val = res.get()
    copyMem(addr r[0], unsafeAddr val[0], sizeof(r))
    copyMem(addr w[0], unsafeAddr val[sizeof(r)], sizeof(w))
    return true
  else:
    return false

proc del*(s: var Sessions, id: NodeId, address: Address) =
  s.del(makeKey(id, address))
