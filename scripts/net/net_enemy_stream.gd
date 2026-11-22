class_name NetEnemyStream
extends Node
## The host-owned enemies' stream (W4, cast's M3): the host runs every enemy and streams its pose / AI state / HP; each
## client shows puppets. Child "Enemies" of the Session autoload (Session.enemies), so it survives scene reloads.
##
## STREAMING (NetWire.T_ENEMY: unreliable, sequence-numbered, newest wins; NetEnemyCodec has the bytes)
##   host -> every client   the enemies due this tick (EnemySync picks them: ACTIVE_RATE when changed, IDLE_RATE as a
##                          keep-alive), MAX_ENTRIES per packet, every entry sampled at the packet's stamp
## SHOWING (NetEnemyBuffer, one per net id): a puppet renders `delay` (100 ms or more, adaptive) behind host_time().
##
## The game (scripts/game/enemy_sync.gd) talks to it through a small API and never touches the wire:
##   begin()            the mission's enemies exist on this machine (host: it will send; client: it will receive)
##   send(states)       host: these samples now (NetEnemyState, t / n filled by the caller)
##   pose(n)            client: the state to show for enemy `n` now (interpolated), null before its first sample
##   forget(n)          client: enemy `n` is gone
##   end()              the mission's scene is going
## Plus newest(n), buffer(n), and `stats` for tests and telemetry. Discrete changes (spawn, telegraph, destruction,
## enemy fire) are reliable events the game sends with Session.send_event (EnemySync: "enemy.*").

const ACTIVE_RATE := 20.0         ## Hz: an enemy whose state changed since its last sample
const IDLE_RATE := 2.0            ## Hz: keep-alive for an enemy that sits still (a lost packet then costs 0.5 s)

var active := false
## Counters since begin(): packets / bytes / entries sent and received on T_ENEMY (bytes include NetWire's header), the
## largest packet sent, entries refused (not newer).
var stats := {}

var _session: NetSession = null
var _buffers: Dictionary = {}     ## net id -> NetEnemyBuffer (client)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_session = get_parent() as NetSession
	if _session == null:
		return
	_session.packet_received.connect(_on_packet)
	_session.session_ended.connect(func(_reason: String) -> void: end())
	_reset_stats()


func _reset_stats() -> void:
	stats = {"out_packets": 0, "out_bytes": 0, "out_max": 0, "out_entries": 0, "in_packets": 0, "in_bytes": 0,
		"in_entries": 0, "in_refused": 0}


func begin() -> void:
	end()
	if _session == null or not _session.online():
		return
	_reset_stats()
	active = true


func end() -> void:
	active = false
	_buffers.clear()


## Host: stream `states` (sampled now) to every client, MAX_ENTRIES per packet.
func send(states: Array[NetEnemyState]) -> void:
	if not active or _session == null or not _session.hosting or _session.roster.size() < 2 or states.is_empty():
		return
	var i := 0
	while i < states.size():
		var chunk: Array[NetEnemyState] = states.slice(i, i + NetEnemyCodec.MAX_ENTRIES)
		i += NetEnemyCodec.MAX_ENTRIES
		var payload := NetEnemyCodec.encode(chunk)
		if _session.send_packet(0, NetEnemyCodec.ENEMY_TYPE, payload) < 0:
			return
		var bytes := NetWire.HEADER + payload.size()
		var clients := _session.roster.size() - 1
		stats["out_packets"] = int(stats["out_packets"]) + clients
		stats["out_bytes"] = int(stats["out_bytes"]) + bytes * clients
		stats["out_entries"] = int(stats["out_entries"]) + chunk.size() * clients
		stats["out_max"] = maxi(int(stats["out_max"]), bytes)


func buffer(n: int) -> NetEnemyBuffer:
	return _buffers.get(n) as NetEnemyBuffer


func newest(n: int) -> NetEnemyState:
	var b := buffer(n)
	return b.newest() if b != null else null


func delay_of(n: int) -> float:
	var b := buffer(n)
	return b.delay if b != null else NetEnemyBuffer.DELAY


## Client: the state to show for enemy `n` now (its buffer at host_time() - delay); null before the first sample.
func pose(n: int) -> NetEnemyState:
	var b := buffer(n)
	if b == null or _session == null:
		return null
	return b.sample(_now() - b.delay)


func forget(n: int) -> void:
	_buffers.erase(n)


func _process(delta: float) -> void:
	if not active:
		return
	for n: int in _buffers:
		(_buffers[n] as NetEnemyBuffer).step_delay(delta)


func _on_packet(from: int, type: int, _seq: int, stamp_ms: int, payload: PackedByteArray) -> void:
	if type != NetEnemyCodec.ENEMY_TYPE or not active or _session.hosting or from != 1:
		return
	stats["in_packets"] = int(stats["in_packets"]) + 1
	stats["in_bytes"] = int(stats["in_bytes"]) + NetWire.HEADER + payload.size()
	var arrival := _now()
	var stamp := NetMechStream._unwrap_stamp(stamp_ms, arrival)
	for s in NetEnemyCodec.decode(payload, stamp):
		stats["in_entries"] = int(stats["in_entries"]) + 1
		var b := buffer(s.n)
		if b == null:
			b = NetEnemyBuffer.new()
			_buffers[s.n] = b
		if not b.push(s, arrival):
			stats["in_refused"] = int(stats["in_refused"]) + 1


func _now() -> float:
	return _session.host_time() if _session != null else 0.0
