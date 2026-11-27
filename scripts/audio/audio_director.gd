class_name AudioDirector
extends Node
## Global audio director (autoload `Audio`; docs/design/audio.md §3).
## Owns the 7-bus AudioServer hierarchy, fixed 2D/3D voice pools, capped managed loops (with stealing past the cap), headless-safe expiry reclamation, per-cue
## cooldowns & polyphony caps, priority stealing, priority ducking (telegraphs/heat/blasts), and the MusicDirector.
## Strictly cosmetic (Net LOCAL): zero gameplay state, zero network/Steam calls, uses its own `looks_rng`.

const BUS_MASTER := "Master"
const BUS_MUSIC := "Music"
const BUS_AMBIENCE := "Ambience"
const BUS_SFX := "SFX"
const BUS_SFX_PLAYER := "SFX_Player"
const BUS_SFX_WORLD := "SFX_World"
const BUS_SFX_TELEGRAPH := "SFX_Telegraph"
const BUS_SFX_UI := "SFX_UI"

const AMBIENCE_TRIM_LINEAR := 0.70   ## relative to GameSettings["sfx"]

## Sub-buses to create if missing: [name, parent_bus, nominal_db]
const BUS_TREE := [
	[BUS_MUSIC, BUS_MASTER, 0.0],
	[BUS_AMBIENCE, BUS_MASTER, 0.0],
	[BUS_SFX, BUS_MASTER, 0.0],
	[BUS_SFX_PLAYER, BUS_SFX, 0.0],
	[BUS_SFX_WORLD, BUS_SFX, -2.0],
	[BUS_SFX_TELEGRAPH, BUS_SFX, 2.0],
	[BUS_SFX_UI, BUS_SFX, -1.0],
]

## 3D distance rolloff profiles for a 200 m curved ring city.
const PROFILES := {
	"foley": {"unit_size": 8.0, "max_distance": 55.0, "cutoff_hz": 3500.0},
	"local_mech": {"unit_size": 22.0, "max_distance": 80.0, "cutoff_hz": 9000.0},
	"weapon": {"unit_size": 18.0, "max_distance": 160.0, "cutoff_hz": 4500.0},
	"explosion": {"unit_size": 30.0, "max_distance": 240.0, "cutoff_hz": 2500.0},
	"telegraph": {"unit_size": 24.0, "max_distance": 140.0, "cutoff_hz": 8000.0},
}

const POOL_2D := 12
const POOL_3D := 32
## Managed loops at once. A mission machine can want 11 (4 crew thrusters, own heat, 5 weapon-slot charge / spin loops,
## missile lock tone); past the cap a loop request takes the least important loop's voice (start_loop, _loop_victim).
const POOL_LOOPS := 24
## A world loop must be this much nearer than the farthest world loop to take its voice (no steal-back when two are close).
const LOOP_STEAL_MARGIN_M := 5.0
const TELEGRAPH_DUCK_WORLD_DB := -3.5
const TELEGRAPH_DUCK_MUSIC_DB := -2.5
const BLAST_DUCK_DB := -2.0
const BLAST_DUCK_DUR := 0.40
const MAX_RECORDED_EVENTS := 256

var bank := SoundBank.new()
var music: MusicDirector
var looks_rng := RandomNumberGenerator.new()
var pilot_cues_enabled := true
var prewarm_enabled := true
var record_events := false          ## tests set true to inspect emitted audio cues deterministically
var recent_events: Array[Dictionary] = []
## No sound at all: set in _ready on a headless run (tests, `--headless` bots; the engine's audio driver is Dummy there).
## Silent, a cue is not played (no AudioStreamPlayer.play(), so the dummy driver mixes nothing) and, unless a test
## records events (record_events), not even fetched or synthesised: play_2d / play_3d / start_loop return 0, as when a
## cue is refused, and the music / ambience beds never start. With record_events the bookkeeping (slots, expiry,
## cooldowns, ducking, the recorder) runs as before, only play() is skipped. A test that times the live audio path
## (test_perf) sets it back to false.
var silent := false

var _clock := 0.0                   ## monotonic seconds for deterministic headless voice expiry & cooldowns
var _next_handle := 1
var _pool_2d: Array[Dictionary] = []     ## {player, handle, cue, bus, priority, started, expires}
var _pool_3d: Array[Dictionary] = []     ## {player, handle, cue, bus, priority, started, expires, pos}
var _loops: Dictionary = {}              ## tag -> {player, is_3d, cue, bus, handle}
var _last_play: Dictionary = {}          ## cue_id -> _clock of last accepted play
var _enemy_telegraphs: Dictionary = {}   ## owner_id -> handle
var _heat_duck := false
var _blast_duck_t := 0.0
var _duck_world_db := 0.0
var _duck_music_db := 0.0
var _base_world_db := -2.0
var _base_music_linear := 0.7
var _base_sfx_linear := 0.8
var loops_stolen := 0                ## diagnostics: loops that gave their voice to a more important one past the cap
var loops_refused := 0               ## diagnostics: loop requests refused at the cap (everything held more important)


func _init() -> void:
	looks_rng.seed = 0xA0D10


func net_fields() -> Dictionary:
	return {
		"bank": Net.LOCAL, "music": Net.LOCAL, "looks_rng": Net.LOCAL, "pilot_cues_enabled": Net.LOCAL,
		"prewarm_enabled": Net.LOCAL, "record_events": Net.LOCAL, "recent_events": Net.LOCAL, "silent": Net.LOCAL,
		"_clock": Net.LOCAL, "_next_handle": Net.LOCAL, "_pool_2d": Net.LOCAL, "_pool_3d": Net.LOCAL,
		"_loops": Net.LOCAL, "_last_play": Net.LOCAL, "_enemy_telegraphs": Net.LOCAL,
		"_heat_duck": Net.LOCAL, "_blast_duck_t": Net.LOCAL, "_duck_world_db": Net.LOCAL,
		"_duck_music_db": Net.LOCAL, "_base_world_db": Net.LOCAL, "_base_music_linear": Net.LOCAL,
		"_base_sfx_linear": Net.LOCAL, "loops_stolen": Net.LOCAL, "loops_refused": Net.LOCAL,
	}


## The game's AudioDirector (the "Audio" autoload under the root) as seen from `node`, or null when `node` is out of
## the tree or there is none.
static func of(node: Node) -> AudioDirector:
	if not node.is_inside_tree():
		return null
	return node.get_tree().root.get_node_or_null("Audio") as AudioDirector


## Build the 7-bus hierarchy + Master limiter + SFX glue compressor (idempotent; safe in --headless).
static func ensure_buses() -> void:
	for entry: Array in BUS_TREE:
		var bname: String = entry[0]
		var parent: String = entry[1]
		var nom_db: float = entry[2]
		var idx := AudioServer.get_bus_index(bname)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bname)
			AudioServer.set_bus_volume_db(idx, nom_db)
		AudioServer.set_bus_send(idx, parent)
	# Master safety limiter (-0.5 dB ceiling, prevents clipping during 4-player chaos).
	var master_idx := AudioServer.get_bus_index(BUS_MASTER)
	if master_idx >= 0 and not _has_effect(master_idx, AudioEffectLimiter):
		var lim := AudioEffectLimiter.new()
		lim.ceiling_db = -0.5
		lim.threshold_db = -1.0
		AudioServer.add_bus_effect(master_idx, lim)
	# SFX gentle glue compressor.
	var sfx_idx := AudioServer.get_bus_index(BUS_SFX)
	if sfx_idx >= 0 and not _has_effect(sfx_idx, AudioEffectCompressor):
		var comp := AudioEffectCompressor.new()
		comp.threshold = -10.0
		comp.ratio = 2.5
		comp.attack_us = 10000.0
		comp.release_ms = 120.0
		AudioServer.add_bus_effect(sfx_idx, comp)


static func _has_effect(bus_idx: int, effect_type: Variant) -> bool:
	for i in AudioServer.get_bus_effect_count(bus_idx):
		if is_instance_of(AudioServer.get_bus_effect(bus_idx, i), effect_type):
			return true
	return false


func _ready() -> void:
	silent = DisplayServer.get_name() == "headless"
	ensure_buses()
	_alloc_pools()
	music = MusicDirector.new()
	add_child(music)
	music.setup(self)
	var st := GameSettings.load_settings()
	sync_user_volumes(float(st.get("music", 0.7)), float(st.get("sfx", 0.8)))
	if prewarm_enabled and not silent:
		bank.start_async_prewarm()


func _exit_tree() -> void:
	bank.shutdown_async()


func fetch_stream(cue_id: String) -> AudioStreamWAV:
	if bank.is_async_started():
		return bank.get_stream_nonblocking(cue_id)
	return bank.get_stream(cue_id)


func _alloc_pools() -> void:
	if not _pool_2d.is_empty():
		return
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.name = "Voice2D_%d" % i
		add_child(p)
		_pool_2d.append({"player": p, "handle": 0, "cue": "", "bus": BUS_SFX_UI, "priority": 0, "started": -1.0, "expires": -1.0})
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "Voice3D_%d" % i
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p3)
		_pool_3d.append({"player": p3, "handle": 0, "cue": "", "bus": BUS_SFX_WORLD, "priority": 0, "started": -1.0, "expires": -1.0, "pos": Vector3.ZERO})


## Silent and nobody inspects the cues: skip the cue entirely (no fetch, no synthesis, no voice).
func skip_cues() -> bool:
	return silent and not record_events


## Called by GameSettings.apply() so ducking offsets preserve the user's Music/SFX slider levels.
func sync_user_volumes(music_linear: float, sfx_linear: float) -> void:
	_base_music_linear = clampf(music_linear, 0.0, 1.0)
	_base_sfx_linear = clampf(sfx_linear, 0.0, 1.0)
	_apply_bus_gains()


func _process(delta: float) -> void:
	advance_clock(delta)
	if bank.is_async_started():
		bank.drain_async()


## Advance the internal audio clock (public so headless unit tests can drive expiry & ducking deterministically).
func advance_clock(delta: float) -> void:
	if delta <= 0.0:
		return
	_clock += delta
	_reclaim_expired()
	if _blast_duck_t > 0.0:
		_blast_duck_t = maxf(_blast_duck_t - delta, 0.0)
	_update_ducking(delta)


func _reclaim_expired() -> void:
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) != 0 and _clock >= float(v["expires"]):
			var p: AudioStreamPlayer = v["player"]
			if p.playing:
				p.stop()
			_clear_slot(v)
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) != 0 and _clock >= float(v["expires"]):
			var p3: AudioStreamPlayer3D = v["player"]
			if p3.playing:
				p3.stop()
			_clear_slot(v)


static func _clear_slot(v: Dictionary) -> void:
	v["handle"] = 0
	v["cue"] = ""
	v["priority"] = 0
	v["expires"] = -1.0


func _update_ducking(delta: float) -> void:
	var tel_active := _heat_duck or active_on_bus(BUS_SFX_TELEGRAPH) > 0
	var want_world := TELEGRAPH_DUCK_WORLD_DB if tel_active else 0.0
	var want_music := (TELEGRAPH_DUCK_MUSIC_DB if tel_active else 0.0) + (BLAST_DUCK_DB if _blast_duck_t > 0.0 else 0.0)
	var atk := 1.0 / 0.04
	var rel := 1.0 / 0.25
	var prev_w := _duck_world_db
	var prev_m := _duck_music_db
	_duck_world_db = move_toward(_duck_world_db, want_world, (atk if want_world < _duck_world_db else rel) * 6.0 * delta)
	_duck_music_db = move_toward(_duck_music_db, want_music, (atk if want_music < _duck_music_db else rel) * 6.0 * delta)
	if absf(_duck_world_db - prev_w) > 0.01 or absf(_duck_music_db - prev_m) > 0.01:
		_apply_bus_gains()


func _apply_bus_gains() -> void:
	var w_idx := AudioServer.get_bus_index(BUS_SFX_WORLD)
	if w_idx >= 0:
		AudioServer.set_bus_volume_db(w_idx, _base_world_db + _duck_world_db)
	var m_idx := AudioServer.get_bus_index(BUS_MUSIC)
	if m_idx >= 0:
		AudioServer.set_bus_volume_db(m_idx, linear_to_db(maxf(_base_music_linear, 0.0001)) + _duck_music_db)
		AudioServer.set_bus_mute(m_idx, _base_music_linear <= 0.001)
	var a_idx := AudioServer.get_bus_index(BUS_AMBIENCE)
	if a_idx >= 0:
		var amb_lin := _base_sfx_linear * AMBIENCE_TRIM_LINEAR
		var blast_off := BLAST_DUCK_DB if _blast_duck_t > 0.0 else 0.0
		AudioServer.set_bus_volume_db(a_idx, linear_to_db(maxf(amb_lin, 0.0001)) + blast_off)
		AudioServer.set_bus_mute(a_idx, _base_sfx_linear <= 0.001)


# --- Public One-Shot API --------------------------------------------------------------------------------

func play_ui(cue_id: String, pitch_mult: float = 1.0, db_offset: float = 0.0) -> int:
	return play_2d(cue_id, db_offset, pitch_mult, BUS_SFX_UI)


func play_2d(cue_id: String, db_offset: float = 0.0, pitch_mult: float = 1.0, bus_override: String = "") -> int:
	if skip_cues():
		return 0
	var sp := SoundBank.spec(cue_id)
	if sp.is_empty():
		return 0
	if not _check_limits(cue_id, sp):
		return 0
	var prio := int(sp.get("priority", 1))
	var slot := _acquire_slot(_pool_2d, prio, Vector3.ZERO, false)
	if slot.is_empty():
		return 0
	var stream := fetch_stream(cue_id)
	if stream == null:
		return 0
	var bus := bus_override if bus_override != "" else str(sp.get("bus", BUS_SFX_PLAYER))
	var pitch := clampf(_jitter_pitch(pitch_mult, float(sp.get("jitter", 0.0))), 0.25, 3.0)
	var db := float(sp.get("db", 0.0)) + db_offset
	var p: AudioStreamPlayer = slot["player"]
	p.stream = stream
	p.bus = bus
	p.volume_db = db
	p.pitch_scale = pitch
	if not silent:
		p.play()
	var handle := _stamp_slot(slot, cue_id, bus, prio, stream.get_length() / pitch, Vector3.ZERO)
	_last_play[cue_id] = _clock
	_record("2d", cue_id, bus, Vector3.ZERO, db, pitch, handle)
	return handle


func play_3d(cue_id: String, world_pos: Vector3, db_offset: float = 0.0, pitch_mult: float = 1.0,
		profile_override: String = "", bus_override: String = "") -> int:
	if skip_cues():
		return 0
	var sp := SoundBank.spec(cue_id)
	if sp.is_empty():
		return 0
	var prof_name := profile_override if profile_override != "" else str(sp.get("profile", "weapon"))
	if prof_name == "2d":
		return play_2d(cue_id, db_offset, pitch_mult, bus_override)
	var prof: Dictionary = PROFILES.get(prof_name, PROFILES["weapon"])
	var max_dist := float(prof["max_distance"])
	var listener: Variant = _listener_pos()
	if listener != null and (listener as Vector3).distance_to(world_pos) > max_dist * 1.05:
		return 0
	if not _check_limits(cue_id, sp):
		return 0
	var prio := int(sp.get("priority", 1))
	var slot := _acquire_slot(_pool_3d, prio, world_pos, true)
	if slot.is_empty():
		return 0
	var stream := fetch_stream(cue_id)
	if stream == null:
		return 0
	var bus := bus_override if bus_override != "" else str(sp.get("bus", BUS_SFX_WORLD))
	var pitch := clampf(_jitter_pitch(pitch_mult, float(sp.get("jitter", 0.0))), 0.25, 3.0)
	var db := float(sp.get("db", 0.0)) + db_offset
	var p3: AudioStreamPlayer3D = slot["player"]
	p3.stream = stream
	p3.bus = bus
	p3.volume_db = db
	p3.pitch_scale = pitch
	p3.unit_size = float(prof["unit_size"])
	p3.max_distance = max_dist
	p3.attenuation_filter_cutoff_hz = float(prof["cutoff_hz"])
	p3.global_position = world_pos
	if not silent:
		p3.play()
	var handle := _stamp_slot(slot, cue_id, bus, prio, stream.get_length() / pitch, world_pos)
	_last_play[cue_id] = _clock
	_record("3d", cue_id, bus, world_pos, db, pitch, handle)
	return handle


func stop_voice(handle: int) -> void:
	if handle <= 0:
		return
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) == handle:
			(v["player"] as AudioStreamPlayer).stop()
			_clear_slot(v)
			return
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) == handle:
			(v["player"] as AudioStreamPlayer3D).stop()
			_clear_slot(v)
			return


# --- Managed Loops (thrusters, heat hum, gatling spin, laser charge) ------------------------------------
## Callers call start_loop every frame while they want the loop (MechAudio, CombatAudio, AudioLab) and stop_loop when
## they stop wanting it. Past POOL_LOOPS a new loop takes the voice of the least important held one (_loop_victim:
## world before local, then farthest from the listener); the loser's tag is simply gone (update_loop / stop_loop on it
## do nothing, has_loop is false), so its owner's next start_loop asks again and resumes once a voice is free. It can't
## steal back: it was the least important, and a world loop needs LOOP_STEAL_MARGIN_M to beat another.

func start_loop(tag: String, cue_id: String, is_3d: bool, pos: Vector3 = Vector3.ZERO, db_offset: float = 0.0,
		pitch: float = 1.0, bus_override: String = "", profile_override: String = "") -> int:
	if skip_cues():
		return 0
	if _loops.has(tag):
		update_loop(tag, pos, db_offset, pitch)
		return int(_loops[tag]["handle"])
	var sp := SoundBank.spec(cue_id)
	if sp.is_empty():
		return 0
	var bus := bus_override if bus_override != "" else str(sp.get("bus", BUS_SFX_PLAYER))
	if _loops.size() >= POOL_LOOPS:
		var victim := _loop_victim(_is_world_loop(is_3d, bus), pos)
		if victim == "":
			loops_refused += 1
			_record("loop_refused", cue_id, bus, pos, 0.0, pitch, 0)
			return 0
		loops_stolen += 1
		stop_loop(victim)
	var stream := fetch_stream(cue_id)
	if stream == null:
		return 0
	var db := float(sp.get("db", 0.0)) + db_offset
	var handle := _next_handle
	_next_handle += 1
	if is_3d:
		var prof_name := profile_override if profile_override != "" else str(sp.get("profile", "local_mech"))
		var prof: Dictionary = PROFILES.get(prof_name, PROFILES["local_mech"])
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "Loop3D_" + tag.replace(".", "_")
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.stream = stream
		p3.bus = bus
		p3.volume_db = db
		p3.pitch_scale = clampf(pitch, 0.25, 3.0)
		p3.unit_size = float(prof["unit_size"])
		p3.max_distance = float(prof["max_distance"])
		p3.attenuation_filter_cutoff_hz = float(prof["cutoff_hz"])
		add_child(p3)
		p3.global_position = pos
		if not silent:
			p3.play()
		_loops[tag] = {"player": p3, "is_3d": true, "cue": cue_id, "bus": bus, "base_db": float(sp.get("db", 0.0)), "handle": handle}
	else:
		var p := AudioStreamPlayer.new()
		p.name = "Loop2D_" + tag.replace(".", "_")
		p.stream = stream
		p.bus = bus
		p.volume_db = db
		p.pitch_scale = clampf(pitch, 0.25, 3.0)
		add_child(p)
		if not silent:
			p.play()
		_loops[tag] = {"player": p, "is_3d": false, "cue": cue_id, "bus": bus, "base_db": float(sp.get("db", 0.0)), "handle": handle}
	_record("loop_start", cue_id, bus, pos, db, pitch, handle)
	return handle


func update_loop(tag: String, pos: Vector3, db_offset: float, pitch: float) -> void:
	if not _loops.has(tag):
		return
	var entry: Dictionary = _loops[tag]
	var db := float(entry["base_db"]) + db_offset
	var pt := clampf(pitch, 0.25, 3.0)
	if bool(entry["is_3d"]):
		var p3: AudioStreamPlayer3D = entry["player"]
		p3.global_position = pos
		p3.volume_db = db
		p3.pitch_scale = pt
	else:
		var p: AudioStreamPlayer = entry["player"]
		p.volume_db = db
		p.pitch_scale = pt


func stop_loop(tag: String) -> void:
	if not _loops.has(tag):
		return
	var entry: Dictionary = _loops[tag]
	var p: Node = entry["player"]
	if is_instance_valid(p):
		p.call("stop")
		p.queue_free()
	_record("loop_stop", str(entry["cue"]), str(entry["bus"]), Vector3.ZERO, 0.0, 1.0, int(entry["handle"]))
	_loops.erase(tag)


func has_loop(tag: String) -> bool:
	return _loops.has(tag)


## A world loop: 3D and not on the player's bus (a crew mech's thruster). Local loops (2D, or the player's own 3D
## loops on SFX_Player: heat, own thruster, weapon charge / spin, lock tone) always win over world loops.
static func _is_world_loop(is_3d: bool, bus: String) -> bool:
	return is_3d and bus != BUS_SFX_PLAYER


## The held loop a new loop at `pos` may take the voice of at the cap, or "" when every held loop is more important.
## Victim: a world loop before a local one, then the farthest from the listener. A world request only takes a world
## loop at least LOOP_STEAL_MARGIN_M farther than itself; a local request takes the farthest world loop, or, when every
## held loop is local, none (a local loop is never cut for another: the refused one asks again next frame).
func _loop_victim(want_world: bool, pos: Vector3) -> String:
	var listener: Variant = _listener_pos()
	var best := ""
	var best_dist := -1.0
	for tag: String in _loops:
		var e: Dictionary = _loops[tag]
		if not _is_world_loop(bool(e["is_3d"]), str(e["bus"])):
			continue
		var p: Node = e["player"]
		var d := 0.0
		if listener != null and is_instance_valid(p):
			d = (listener as Vector3).distance_to((p as Node3D).global_position)
		if d > best_dist:
			best = tag
			best_dist = d
	if best == "" or not want_world:
		return best
	var my_dist := (listener as Vector3).distance_to(pos) if listener != null else 0.0
	return best if my_dist + LOOP_STEAL_MARGIN_M < best_dist else ""


# --- Enemy Telegraph & Alert Facade (docs/design/audio.md §4) -------------------------------------------

## Play a spatialized >=0.3 s enemy telegraph on SFX_Telegraph, pitch-scaled to match `duration`.
func play_enemy_telegraph(owner_id: String, kind: String, world_pos: Vector3, duration: float = 0.55) -> int:
	cancel_enemy_telegraph(owner_id)
	if skip_cues():
		return 0
	var cue := "enemy.telegraph." + kind
	if not SoundBank.has_cue(cue):
		cue = "enemy.telegraph.generic"
	var stream := fetch_stream(cue)
	var ref_dur := stream.get_length() if stream != null else 0.55
	var clamped_dur := clampf(duration, 0.3, 2.5)
	var pitch := clampf(ref_dur / clamped_dur, 0.5, 2.0)
	var h := play_3d(cue, world_pos, 0.0, pitch, "telegraph", BUS_SFX_TELEGRAPH)
	if h > 0 and owner_id != "":
		_enemy_telegraphs[owner_id] = h
	return h


func cancel_enemy_telegraph(owner_id: String) -> void:
	if owner_id == "" or not _enemy_telegraphs.has(owner_id):
		return
	var h := int(_enemy_telegraphs[owner_id])
	_enemy_telegraphs.erase(owner_id)
	stop_voice(h)


func play_enemy_alert(state: String, world_pos: Vector3) -> int:
	var cue := "enemy.alert." + state
	if not SoundBank.has_cue(cue):
		cue = "enemy.alert.spotted"
	return play_3d(cue, world_pos)


## Play subtle deadpan radio-filtered pilot cue for `head_id` ("chicken"|"pickle"|"corn"|"dog").
func play_pilot_cue(head_id: String) -> int:
	if not pilot_cues_enabled:
		return 0
	var cue := "pilot." + head_id
	if not SoundBank.has_cue(cue):
		return 0
	return play_2d(cue)


func set_heat_duck(active: bool) -> void:
	_heat_duck = active


func trigger_blast_duck(strength: float, blast_pos: Vector3 = Vector3.ZERO) -> void:
	if strength < 4.5:
		return
	var lp: Variant = _listener_pos()
	if lp != null and blast_pos != Vector3.ZERO and (lp as Vector3).distance_to(blast_pos) > 35.0:
		return
	_blast_duck_t = BLAST_DUCK_DUR


# --- Diagnostics & Tests --------------------------------------------------------------------------------

func active_2d_count() -> int:
	var n := 0
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) != 0:
			n += 1
	return n


func active_3d_count() -> int:
	var n := 0
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) != 0:
			n += 1
	return n


func active_loop_count() -> int:
	return _loops.size()


func active_on_bus(bus_name: String) -> int:
	var n := 0
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) != 0 and str(v["bus"]) == bus_name:
			n += 1
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) != 0 and str(v["bus"]) == bus_name:
			n += 1
	return n


func active_for_cue(cue_id: String) -> int:
	var n := 0
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) != 0 and str(v["cue"]) == cue_id:
			n += 1
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) != 0 and str(v["cue"]) == cue_id:
			n += 1
	return n


func duck_world_db() -> float:
	return _duck_world_db


func duck_music_db() -> float:
	return _duck_music_db


func clear_events() -> void:
	recent_events.clear()


func reset_state() -> void:
	for v: Dictionary in _pool_2d:
		if int(v["handle"]) != 0:
			(v["player"] as AudioStreamPlayer).stop()
			_clear_slot(v)
	for v: Dictionary in _pool_3d:
		if int(v["handle"]) != 0:
			(v["player"] as AudioStreamPlayer3D).stop()
			_clear_slot(v)
	for tag: String in _loops.keys():
		stop_loop(tag)
	_last_play.clear()
	_enemy_telegraphs.clear()
	_heat_duck = false
	_blast_duck_t = 0.0
	_duck_world_db = 0.0
	_duck_music_db = 0.0
	_apply_bus_gains()
	recent_events.clear()


# --- Internals ------------------------------------------------------------------------------------------

func _check_limits(cue_id: String, sp: Dictionary) -> bool:
	var cd_s := float(sp.get("cooldown_ms", 0)) / 1000.0
	if cd_s > 0.0 and _last_play.has(cue_id) and (_clock - float(_last_play[cue_id])) < cd_s - 1e-6:
		return false
	var cap := int(sp.get("max_voices", 8))
	if cap > 0 and active_for_cue(cue_id) >= cap:
		return false
	return true


func _acquire_slot(pool: Array[Dictionary], prio: int, world_pos: Vector3, is_3d: bool) -> Dictionary:
	# 1. Free slot first.
	for v: Dictionary in pool:
		if int(v["handle"]) == 0:
			return v
	# 2. Steal lowest priority (never steal priority 3 for a lower priority); tie-break by farthest, then oldest.
	var listener: Variant = _listener_pos() if is_3d else null
	var best: Dictionary = {}
	var best_prio := 999
	var best_dist := -1.0
	var best_started := INF
	for v: Dictionary in pool:
		var vp := int(v["priority"])
		if vp >= 3 and prio < 3:
			continue
		if vp > prio:
			continue
		var dist := (listener as Vector3).distance_to(v["pos"] as Vector3) if (is_3d and listener != null) else 0.0
		var st := float(v["started"])
		var better := vp < best_prio
		if not better and vp == best_prio:
			if is_3d and absf(dist - best_dist) > 1.0:
				better = dist > best_dist
			else:
				better = st < best_started
		if better:
			best = v
			best_prio = vp
			best_dist = dist
			best_started = st
	if not best.is_empty():
		(best["player"] as Node).call("stop")
		_clear_slot(best)
	return best


func _stamp_slot(slot: Dictionary, cue_id: String, bus: String, prio: int, dur: float, pos: Vector3) -> int:
	var h := _next_handle
	_next_handle += 1
	slot["handle"] = h
	slot["cue"] = cue_id
	slot["bus"] = bus
	slot["priority"] = prio
	slot["started"] = _clock
	slot["expires"] = _clock + maxf(dur, 0.02)
	if slot.has("pos"):
		slot["pos"] = pos
	return h


func _jitter_pitch(base_pitch: float, jitter: float) -> float:
	if jitter <= 0.0:
		return base_pitch
	return base_pitch * looks_rng.randf_range(1.0 - jitter, 1.0 + jitter)


func _listener_pos() -> Variant:
	var vp := get_viewport()
	if vp == null:
		return null
	var cam := vp.get_camera_3d()
	return cam.global_position if cam != null and cam.is_inside_tree() else null


func _record(kind: String, cue_id: String, bus: String, pos: Vector3, db: float, pitch: float, handle: int) -> void:
	if not record_events:
		return
	if recent_events.size() >= MAX_RECORDED_EVENTS:
		recent_events.pop_front()
	recent_events.append({
		"kind": kind, "cue": cue_id, "bus": bus, "pos": pos, "db": db, "pitch": pitch, "handle": handle, "t": _clock,
	})
