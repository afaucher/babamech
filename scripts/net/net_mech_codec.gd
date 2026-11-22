class_name NetMechCodec
extends RefCounted
## The mech snapshot, hand-packed (co-op step 2, cast's NetCodec): what rides in a NetWire.T_SNAP packet.
##
## PAYLOAD  (after NetWire's 7-byte header: u8 type | u16 seq | u32 stamp_ms)
##   u8  count                         mechs in this packet (a client sends 1; the host sends up to 3: its own and the
##                                     other clients', never the receiver's own)
##   count x ENTRY
##
## ENTRY (29 bytes)
##   u8  head      crew seat (bits 0-2, 1..4) | teleport counter (bits 4-7)
##   u8  flags     grounded 1 | thrusting 2 | emergency 4 | shutdown 8 | hover 16 | designator 32
##   u8  age       2 ms units between the sample and the packet's stamp (0 for the sender's own mech; a client's mech
##                 the host FORWARDS carries its age, so the sample keeps its moment on the shared clock), at most 510 ms
##   i24 x, y, z   millimetres (+-8388 m: the ring decks are a few hundred metres across)
##   i16 vx,vy,vz  cm/s (+-327 m/s)
##   u16 yaw       body heading in the ring frame, 65536 steps of a turn
##   i8  leg_yaw   hip twist, pi/127 rad steps
##   u8  heat      0..255 of heat_cap
##   u8  impact    last touchdown speed, 1/4 m/s (0..63.75)
##   i16 aim x,y,z the aim point relative to the mech, 1/4 m (+-8 km)
##
## A client's snapshot is 7 + 1 + 29 = 37 bytes; the host's to a client in a full crew carries 3 mechs, 95 bytes (the
## budget is 100: MAX_PACKET). At 30 Hz: 1.1 KB/s up, at most 2.9 KB/s down per client.
##
## MECH_FIELDS is what test_net_contract holds this codec to: every var named must be OWNER on its class, and every OWNER
## var of MechController must be carried here (position, velocity and facing are engine properties, sampled directly).

const SNAP_TYPE := NetWire.T_SNAP
const ENTRY_SIZE := 29
const COUNT_SIZE := 1
const MAX_PACKET := 100
const FLAG_GROUNDED := 1
const FLAG_THRUST := 2
const FLAG_EMERGENCY := 4
const FLAG_SHUTDOWN := 8
const FLAG_HOVER := 16
const FLAG_DESIGNATOR := 32
const AGE_UNIT := 0.002
const AGE_MAX := 0.51
const IMPACT_UNIT := 0.25
const AIM_UNIT := 0.25

## Class -> {var: the entry part that carries it}. Checked by tests/test_net_contract.gd.
const MECH_FIELDS := {
	"MechController": {"heat": "heat", "shutdown": "flags", "thrusting": "flags", "emergency": "flags",
		"last_impact": "impact", "puppet_grounded": "flags"},
	"MechRig": {"leg_yaw": "leg_yaw"},
}


## The payload for `states` (each with its peer); `seats` maps peer -> crew seat (1..7); `sent_at` is the packet's
## moment on the shared clock (ages are measured to it). Entries whose peer has no seat are left out.
static func encode(states: Array[NetMechState], seats: Dictionary, sent_at: float) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	var keep: Array[NetMechState] = []
	for s in states:
		if seats.has(s.peer):
			keep.append(s)
	b.put_u8(keep.size())
	for s in keep:
		_put_entry(b, s, int(seats[s.peer]), sent_at)
	return b.data_array


static func _put_entry(b: StreamPeerBuffer, s: NetMechState, seat: int, sent_at: float) -> void:
	b.put_u8((seat & 7) | ((s.tp & 15) << 4))
	var flags := 0
	if s.grounded: flags |= FLAG_GROUNDED
	if s.thrusting: flags |= FLAG_THRUST
	if s.emergency: flags |= FLAG_EMERGENCY
	if s.shutdown: flags |= FLAG_SHUTDOWN
	if s.hover: flags |= FLAG_HOVER
	if s.designator: flags |= FLAG_DESIGNATOR
	b.put_u8(flags)
	b.put_u8(clampi(roundi(clampf(sent_at - s.t, 0.0, AGE_MAX) / AGE_UNIT), 0, 255))
	for c in 3:
		_put_i24(b, roundi(s.pos[c] * 1000.0))
	for c in 3:
		b.put_16(clampi(roundi(s.vel[c] * 100.0), -32767, 32767))
	b.put_u16(roundi(wrapf(s.yaw, 0.0, TAU) / TAU * 65536.0) & 0xFFFF)
	b.put_8(clampi(roundi(wrapf(s.leg_yaw, -PI, PI) / PI * 127.0), -127, 127))
	b.put_u8(clampi(roundi(s.heat * 255.0), 0, 255))
	b.put_u8(clampi(roundi(s.last_impact / IMPACT_UNIT), 0, 255))
	var rel := s.aim - s.pos
	for c in 3:
		b.put_16(clampi(roundi(rel[c] / AIM_UNIT), -32767, 32767))


## The states in a payload; `peers` maps crew seat -> peer, `stamp` is the packet's stamp (seconds). Entries for an
## unknown seat are dropped. Stops (returning what it read) at a truncated entry.
static func decode(payload: PackedByteArray, peers: Dictionary, stamp: float) -> Array[NetMechState]:
	var out: Array[NetMechState] = []
	if payload.size() < COUNT_SIZE:
		return out
	var b := StreamPeerBuffer.new()
	b.data_array = payload
	var n := b.get_u8()
	for i in n:
		if b.get_available_bytes() < ENTRY_SIZE:
			break
		var head := b.get_u8()
		var s := NetMechState.new()
		var seat := head & 7
		s.tp = (head >> 4) & 15
		var flags := b.get_u8()
		s.grounded = (flags & FLAG_GROUNDED) != 0
		s.thrusting = (flags & FLAG_THRUST) != 0
		s.emergency = (flags & FLAG_EMERGENCY) != 0
		s.shutdown = (flags & FLAG_SHUTDOWN) != 0
		s.hover = (flags & FLAG_HOVER) != 0
		s.designator = (flags & FLAG_DESIGNATOR) != 0
		s.t = stamp - float(b.get_u8()) * AGE_UNIT
		var p := Vector3.ZERO
		for c in 3:
			p[c] = float(_get_i24(b)) / 1000.0
		s.pos = p
		var v := Vector3.ZERO
		for c in 3:
			v[c] = float(b.get_16()) / 100.0
		s.vel = v
		s.yaw = float(b.get_u16()) / 65536.0 * TAU
		s.leg_yaw = float(b.get_8()) / 127.0 * PI
		s.heat = float(b.get_u8()) / 255.0
		s.last_impact = float(b.get_u8()) * IMPACT_UNIT
		var a := Vector3.ZERO
		for c in 3:
			a[c] = float(b.get_16()) * AIM_UNIT
		s.aim = s.pos + a
		if not peers.has(seat):
			continue
		s.peer = int(peers[seat])
		out.append(s)
	return out


static func _put_i24(b: StreamPeerBuffer, v: int) -> void:
	var u := clampi(v, -8388607, 8388607) & 0xFFFFFF
	b.put_u16(u & 0xFFFF)
	b.put_u8((u >> 16) & 0xFF)


static func _get_i24(b: StreamPeerBuffer) -> int:
	var u := b.get_u16() | (b.get_u8() << 16)
	return u - 0x1000000 if u & 0x800000 else u
