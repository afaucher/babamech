class_name NetMechStream
extends Node
## Mech sync (co-op step 2, cast's M2 / NetSnapshot): every machine OWNS its own mech and streams it, and shows everyone
## else's as a PUPPET. Child "Mechs" of the Session autoload (Session.mechs), so it survives scene reloads.
##
## STREAMING (NetWire.T_SNAP: unreliable, sequence-numbered, newest wins; NetMechCodec has the bytes)
##   client -> host   30 Hz: its own mech (37 bytes);
##   host -> client   30 Hz: every mech but that client's own: the host's (live) and the OTHER clients' (the newest
##                    sample received, forwarded with its age so it keeps its moment on the shared clock). Clients only
##                    talk to the host (star topology, as the session: server_relay is off).
## SHOWING (NetPuppetBuffer): a puppet renders `delay` (100 ms or more, adaptive) behind Session.host_time().
##
## The game talks to it through a small API and never touches the wire:
##   begin(local_peer, seats)   the mission's mechs are built: `seats` is peer -> crew seat for every crew mech; the
##                              local one is streamed, every other one is a puppet
##   feed(state, delta)         the local mech's state after this physics step (a NetMechState; t, peer and tp are
##                              filled in here). Call it every physics step; the newest one goes out at SEND_RATE
##   pose(peer)                 the puppet's state to show now (interpolated), null before its first sample
##   end()                      the mission's scene is going
## Plus newest(peer), buffer(peer), delay_of(peer), puppet_peers(), and `stats` for tests and telemetry.

const SEND_RATE := 30.0
const SEND_INTERVAL := 1.0 / SEND_RATE
const TELEPORT_DIST := 6.0        ## a mech that moved farther than this between two feeds jumped (a respawn)
const FORWARD_MAX_AGE := 0.3      ## a client's sample older than this is not forwarded (it stopped sending)
const CLOCK_EASE := 0.05          ## feed(): share of the step clock's gap to host_time() closed per physics step
const CLOCK_SNAP := 0.25          ## feed(): a gap wider than this re-anchors the step clock

var active := false
var local_peer := 0
## Counters since begin(): packets / bytes sent and received on T_SNAP (bytes include NetWire's header), the largest
## packet sent, entries received, entries refused (not newer, or not the sender's to send).
var stats := {}

var _session: NetSession = null
var _seats: Dictionary = {}        ## peer -> seat
var _peers: Dictionary = {}        ## seat -> peer
var _buffers: Dictionary = {}      ## peer -> NetPuppetBuffer (every crew mech but the local one)
var _local: NetMechState = null    ## the newest fed state of the local mech
var _last_fed_pos := Vector3.INF
var _tp := 0
var _next_send := 0.0
var _step_t := -1.0                ## feed()'s step clock (host_time seconds)
var _forwarded: Dictionary = {}    ## host: (receiver << 32 | owner) -> t of the last sample of owner forwarded to receiver


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_session = get_parent() as NetSession
	if _session == null:
		return
	_session.packet_received.connect(_on_packet)
	_session.session_ended.connect(func(_reason: String) -> void: end())
	_reset_stats()


func _reset_stats() -> void:
	stats = {"out_packets": 0, "out_bytes": 0, "out_max": 0, "in_packets": 0, "in_bytes": 0, "in_entries": 0,
		"in_refused": 0, "forwarded": 0}


## The mission's mechs are built. `seats`: peer -> crew seat (1..7) for every mech in the mission, the local one too.
func begin(local_peer_: int, seats: Dictionary) -> void:
	end()
	if _session == null or not _session.online():
		return
	local_peer = local_peer_
	for p: int in seats:
		_seats[p] = int(seats[p])
		_peers[int(seats[p])] = p
		if p != local_peer:
			_buffers[p] = NetPuppetBuffer.new()
	_reset_stats()
	_next_send = _now()
	active = true


func end() -> void:
	active = false
	_seats.clear()
	_peers.clear()
	_buffers.clear()
	_forwarded.clear()
	_local = null
	_last_fed_pos = Vector3.INF
	_step_t = -1.0
	local_peer = 0


## The local mech's state after a physics step of `delta` s. Stamps it: peer, teleport counter (a jump of more than
## TELEPORT_DIST since the last feed bumps it and zeroes the velocity, decided here so no sample carries the new place
## with the old counter), and t on a STEP CLOCK: the last t plus `delta`, eased toward host_time() (CLOCK_EASE per step,
## re-anchored past CLOCK_SNAP). A frame hitch runs several physics steps back to back within a millisecond or two;
## stamping those with host_time() would squeeze 50 ms of motion into 2 ms and the puppet would lurch. delta <= 0
## stamps host_time() as it is.
func feed(s: NetMechState, delta: float = 0.0) -> void:
	if not active:
		return
	s.peer = local_peer
	var now := _now()
	if delta <= 0.0 or _step_t < 0.0:
		_step_t = now
	else:
		_step_t += delta
		var err := now - _step_t
		_step_t = now if absf(err) > CLOCK_SNAP else _step_t + err * CLOCK_EASE
	s.t = minf(_step_t, now)
	if _last_fed_pos != Vector3.INF and s.pos.distance_to(_last_fed_pos) > TELEPORT_DIST:
		_tp = (_tp + 1) & 15
		s.vel = Vector3.ZERO
	_last_fed_pos = s.pos
	s.tp = _tp
	_local = s


## The newest state fed for the local mech (what goes out next), null before the first feed.
func local_state() -> NetMechState:
	return _local


func is_puppet(peer: int) -> bool:
	return _buffers.has(peer)


func puppet_peers() -> Array[int]:
	var out: Array[int] = []
	for p: int in _buffers:
		out.append(p)
	out.sort()
	return out


func buffer(peer: int) -> NetPuppetBuffer:
	return _buffers.get(peer) as NetPuppetBuffer


func newest(peer: int) -> NetMechState:
	var b := buffer(peer)
	return b.newest() if b != null else null


func delay_of(peer: int) -> float:
	var b := buffer(peer)
	return b.delay if b != null else NetPuppetBuffer.DELAY


## The state to show for `peer`'s puppet now: its buffer sampled at host_time() - delay (state.t is that render time).
## Null before the first sample (the delays are slewed in _process).
func pose(peer: int) -> NetMechState:
	var b := buffer(peer)
	if b == null or _session == null:
		return null
	return b.sample(_now() - b.delay)


func _process(delta: float) -> void:
	if not active or _session == null or not _session.online():
		return
	for p: int in _buffers:
		(_buffers[p] as NetPuppetBuffer).step_delay(delta)
	var now := _now()
	if now >= _next_send:
		_next_send += SEND_INTERVAL
		if _next_send < now - SEND_INTERVAL:
			_next_send = now
		_send(now)


func _send(now: float) -> void:
	if _session.roster.size() < 2:
		return
	if not _session.hosting:
		if _local != null:
			var one: Array[NetMechState] = [_local]
			_send_to(1, one, now)
		return
	for peer: int in _session.roster:
		if peer == 1:
			continue
		var states: Array[NetMechState] = []
		if _local != null:
			states.append(_local)
		for p: int in _buffers:
			if p == peer:
				continue
			var n := (_buffers[p] as NetPuppetBuffer).newest()
			var key := (peer << 32) | (p & 0xFFFFFFFF)
			if n != null and now - n.t <= FORWARD_MAX_AGE and n.t > float(_forwarded.get(key, -1.0)):
				_forwarded[key] = n.t   # (each sample once: the receiver would refuse a repeat as not newer)
				states.append(n)
				stats["forwarded"] = int(stats["forwarded"]) + 1
		if not states.is_empty():
			_send_to(peer, states, now)


func _send_to(peer: int, states: Array[NetMechState], now: float) -> void:
	var payload := NetMechCodec.encode(states, _seats, now)
	if _session.send_packet(peer, NetMechCodec.SNAP_TYPE, payload) < 0:
		return
	var bytes := NetWire.HEADER + payload.size()
	stats["out_packets"] = int(stats["out_packets"]) + 1
	stats["out_bytes"] = int(stats["out_bytes"]) + bytes
	stats["out_max"] = maxi(int(stats["out_max"]), bytes)


func _on_packet(from: int, type: int, _seq: int, stamp_ms: int, payload: PackedByteArray) -> void:
	if type != NetMechCodec.SNAP_TYPE or not active:
		return
	if not _session.hosting and from != 1:
		return
	stats["in_packets"] = int(stats["in_packets"]) + 1
	stats["in_bytes"] = int(stats["in_bytes"]) + NetWire.HEADER + payload.size()
	var arrival := _now()
	var stamp := _unwrap_stamp(stamp_ms, arrival)
	for s in NetMechCodec.decode(payload, _peers, stamp):
		stats["in_entries"] = int(stats["in_entries"]) + 1
		# Never our own mech; on the host, a client may only send its own.
		if s.peer == local_peer or not _buffers.has(s.peer) or (_session.hosting and s.peer != from):
			stats["in_refused"] = int(stats["in_refused"]) + 1
			continue
		if not (_buffers[s.peer] as NetPuppetBuffer).push(s, arrival):
			stats["in_refused"] = int(stats["in_refused"]) + 1


## The wire stamps packets with host_time in ms mod 2^32 (49.7 days); put it back on the seconds timeline nearest `now`.
static func _unwrap_stamp(stamp_ms: int, now: float) -> float:
	var now_ms := int(now * 1000.0)
	var d := (stamp_ms - now_ms) & 0xFFFFFFFF
	if d >= 0x80000000:
		d -= 0x100000000
	return float(now_ms + d) / 1000.0


func _now() -> float:
	return _session.host_time() if _session != null else 0.0
