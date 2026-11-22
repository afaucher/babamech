class_name NetEnemyCodec
extends RefCounted
## The host's enemy stream, hand-packed (W4): what rides in a NetWire.T_ENEMY packet, host -> each client.
##
## PAYLOAD  (after NetWire's 7-byte header: u8 type | u16 seq | u32 stamp_ms; every entry is sampled at the stamp)
##   u8  count                         enemies in this packet (at most MAX_ENTRIES)
##   count x ENTRY
##
## ENTRY (BASE_SIZE = 28 bytes + 1 per component; 31-33 for the turret / skirmisher / siege tank)
##   u16 n         net id (the enemy's number in the host's manifest, "enemy.spawn")
##   u8  state     index in STATES (EnemyBase.ai_state)
##   u8  flags     shutdown 1 | staggered 2 | dead 4
##   i24 x, y, z   millimetres (+-8388 m)
##   u16 yaw       hull heading in the ring frame, 65536 steps of a turn
##   i16 aim yaw   the subclass's aim pose (EnemyBase.puppet_aim: turret / torso yaw), pi/32767 rad steps
##   i16 aim pitch                     (turret pitch), pi/32767 rad steps
##   u8  heat      0..255 of the heat cap
##   u8  kick      aim_kick, 0.1 deg steps (0..25.5)
##   i16 lock x,y,z  the telegraph's locked aim point relative to the enemy, LOCK_UNIT m (+-2 km)
##   u8  ncomp     components that follow
##   u8 x ncomp    component HP, 0..255 of its max (EnemyBase.comp_order() order)
##
## 10 enemies are about 330 bytes a packet; MAX_ENTRIES (32) keeps one packet under ~1.1 KB, inside the ~1200 B
## unreliable MTU (more enemies go in more packets). Rates (NetEnemyStream / EnemySync): ACTIVE_RATE for an enemy whose
## state changed since its last sample, IDLE_RATE (a keep-alive) for one that sits still; a dead enemy is not streamed
## (its destruction is a reliable event).
##
## ENEMY_FIELDS is what test_net_contract holds this codec to (the carriers' first half): every var named is OWNER on
## its class. Their other OWNER vars stay on the host: the AI's working state (target, slots, path) never leaves it, and
## the telegraph's start and the destruction travel as reliable events (EnemySync).

const ENEMY_TYPE := NetWire.T_ENEMY
const BASE_SIZE := 28
const COUNT_SIZE := 1
const MAX_ENTRIES := 32
const MAX_COMPONENTS := 16
const LOCK_UNIT := 1.0 / 16.0
const KICK_UNIT := 0.1
const FLAG_SHUTDOWN := 1
const FLAG_STAGGER := 2
const FLAG_DEAD := 4
const STATES := ["idle", "patrol", "alert", "engage", "flank", "telegraph", "fire", "cooldown", "staggered", "overheated",
	"dead"]

## Class -> {var: entry part}. Checked by tests/test_net_contract.gd (each must be Net.OWNER).
const ENEMY_FIELDS := {
	"EnemyBase": {"ai_state": "state", "_dead": "flags", "_locked_aim": "lock", "hp": "comp", "heat": "heat",
		"aim_kick": "kick"},
	"EnemyTurret": {"_yaw": "aim", "_pitch": "aim"},
	"EnemyTank": {"_turret_yaw": "aim"},
	"EnemyStrider": {"_aim_yaw": "aim"},
}


static func state_index(s: String) -> int:
	return maxi(STATES.find(s), 0)


static func state_name(i: int) -> String:
	return str(STATES[i]) if i >= 0 and i < STATES.size() else "idle"


static func entry_size(s: NetEnemyState) -> int:
	return BASE_SIZE + mini(s.hp.size(), MAX_COMPONENTS)


## The payload for `states` (at most MAX_ENTRIES; the rest are left out: split before calling).
static func encode(states: Array[NetEnemyState]) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	var n := mini(states.size(), MAX_ENTRIES)
	b.put_u8(n)
	for i in n:
		_put_entry(b, states[i])
	return b.data_array


static func _put_entry(b: StreamPeerBuffer, s: NetEnemyState) -> void:
	b.put_u16(s.n & 0xFFFF)
	b.put_u8(clampi(s.state, 0, 255))
	var flags := 0
	if s.shutdown: flags |= FLAG_SHUTDOWN
	if s.stagger: flags |= FLAG_STAGGER
	if s.dead: flags |= FLAG_DEAD
	b.put_u8(flags)
	for c in 3:
		NetMechCodec._put_i24(b, roundi(s.pos[c] * 1000.0))
	b.put_u16(roundi(wrapf(s.yaw, 0.0, TAU) / TAU * 65536.0) & 0xFFFF)
	b.put_16(clampi(roundi(wrapf(s.aim.x, -PI, PI) / PI * 32767.0), -32767, 32767))
	b.put_16(clampi(roundi(wrapf(s.aim.y, -PI, PI) / PI * 32767.0), -32767, 32767))
	b.put_u8(clampi(roundi(s.heat * 255.0), 0, 255))
	b.put_u8(clampi(roundi(s.kick / KICK_UNIT), 0, 255))
	var rel := s.lock - s.pos
	for c in 3:
		b.put_16(clampi(roundi(rel[c] / LOCK_UNIT), -32767, 32767))
	var nc := mini(s.hp.size(), MAX_COMPONENTS)
	b.put_u8(nc)
	for i in nc:
		b.put_u8(clampi(roundi(clampf(s.hp[i], 0.0, 1.0) * 255.0), 0, 255))


## The states in a payload, each stamped `stamp` (the packet's moment, seconds). Stops at a truncated entry.
static func decode(payload: PackedByteArray, stamp: float) -> Array[NetEnemyState]:
	var out: Array[NetEnemyState] = []
	if payload.size() < COUNT_SIZE:
		return out
	var b := StreamPeerBuffer.new()
	b.data_array = payload
	var n := b.get_u8()
	for i in n:
		if b.get_available_bytes() < BASE_SIZE:
			break
		var s := NetEnemyState.new()
		s.t = stamp
		s.n = b.get_u16()
		s.state = b.get_u8()
		var flags := b.get_u8()
		s.shutdown = (flags & FLAG_SHUTDOWN) != 0
		s.stagger = (flags & FLAG_STAGGER) != 0
		s.dead = (flags & FLAG_DEAD) != 0
		var p := Vector3.ZERO
		for c in 3:
			p[c] = float(NetMechCodec._get_i24(b)) / 1000.0
		s.pos = p
		s.yaw = float(b.get_u16()) / 65536.0 * TAU
		s.aim = Vector2(float(b.get_16()) / 32767.0 * PI, float(b.get_16()) / 32767.0 * PI)
		s.heat = float(b.get_u8()) / 255.0
		s.kick = float(b.get_u8()) * KICK_UNIT
		var l := Vector3.ZERO
		for c in 3:
			l[c] = float(b.get_16()) * LOCK_UNIT
		s.lock = s.pos + l
		var nc := b.get_u8()
		if b.get_available_bytes() < nc:
			break
		s.hp.resize(nc)
		for c in nc:
			s.hp[c] = float(b.get_u8()) / 255.0
		out.append(s)
	return out
