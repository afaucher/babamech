class_name PilotHead
extends Node3D
## An expressive pilot head (docs/design/pilot-heads.md): a tree of rigid low-poly pieces built by a head definition
## (PilotFace, one file per head in scripts/pilot/heads/, listed in REGISTRY) and driven in layers: a mood (standing
## state, cross-faded), reactions (one-shots on top), the neck springs (PilotNeck: motion with the mech, looks), idle life
## (PilotIdle: seeded blinks, glances, tics). Origin at the neck base, facing -Z, about 1.2 tall, like the static heads.
##
## Driving it:
##   feed(delta, state)   the normal path, once per frame from the mech (MechRig). state keys, all optional:
##                          vel       Vector3, the mech's velocity in the head's (= hull's) local frame, model units / s
##                                    (-Z forward, +Y up); acceleration is derived from it
##                          yaw_rate  float, rad / s, + = turning left
##                          grounded  bool (true)      heat  float 0..1 (0)      hp  float 0..1 (1)
##                          shutdown, disabled, firing, aiming, effort   bool (false)
##                          footfall  bool, true on the frame a foot lands (a small nod)
##                        It picks the mood by priority (pick_mood), detects landings (grounded edge + the last
##                        airborne downward speed -> impact, scaled; hard ones add a flinch) and advances everything by
##                        delta * time_scale.
##   set_inputs(extra)    sticky state from a second feeder (PilotCombatLink: heat, hp, shutdown, disabled, firing,
##                        aiming, effort; EXTRA_KEYS), merged into every later feed so two feeders never fight: an
##                        explicit feed key wins, except effort, which ORs. Calls accumulate; clear_inputs() drops them.
##                        The idle path (_process) uses them too (without effort).
##   _process             when feed has not been called this frame or the last, the head idles on its own (inputs at
##                        their defaults, mood stern unless overridden), scaled by time_scale. Never both in one frame.
##   advance(delta)       the deterministic step both use (no wall clock, no frame count); tests call it directly.
## Same id + seed + the same calls = the same channels and poses.
## Effects: the head emits `fx(kind, strength)` (FX_KINDS); its own PilotFx child (fx_node) draws them. "stars" / "smoke" are
## continuous: strength 1 starts them, 0 stops (scatters) them. The others are one-shots with a strength.
## Cosmetic only (Net.LOCAL): every machine runs each head from that mech's synced state; gameplay never reads it.

signal fx(kind: String, strength: float)

## Head id -> definition script. A new head adds one line here (ids without a line fall back to FALLBACK).
const REGISTRY := {
	"chicken": "res://scripts/pilot/heads/pilot_head_chicken.gd",
	"duck": "res://scripts/pilot/heads/pilot_head_duck.gd",
	"pickle": "res://scripts/pilot/heads/pilot_head_pickle.gd",
	"corn": "res://scripts/pilot/heads/pilot_head_corn.gd",
	"dog": "res://scripts/pilot/heads/pilot_head_dog.gd",
}
const FALLBACK := "chicken"
const FX_KINDS: Array[String] = ["steam", "sweat", "stars", "smoke", "chips", "flash"]

## Mood thresholds (design section 3.2).
const HEAT_STRAINED := 0.7
const HEAT_OVERHEATED := 0.9
const HP_AFRAID := 0.25
## A hit of at least this fraction of HP adds Pain to the Flinch.
const PAIN_AMOUNT := 0.15
## Landing speeds (model units / s, downward): below LAND_MIN nothing, LAND_FULL = full impact, LAND_HARD adds a flinch.
const LAND_MIN := 1.5
const LAND_FULL := 12.0
const LAND_HARD := 9.0
## After a hit with a direction, the head turns toward the source LOOK_DELAY later, for LOOK_HOLD.
const LOOK_DELAY := 0.15
const LOOK_HOLD := 0.6
## Acceleration smoothing (seconds) and the eye height looks are measured from.
const ACCEL_TAU := 0.05
const EYE_HEIGHT := 0.85
const STEAM_EVERY := Vector2(0.5, 0.9)
const SWEAT_EVERY := Vector2(1.5, 3.0)
const AIR_STRETCH := 0.05
const AIR_FLAIR := 0.3
const FOOTFALL_NOD := 60.0       ## deg / s of nod kick per footfall
const TREMBLE_DEG := 1.6
const DEFAULTS := {"vel": Vector3.ZERO, "yaw_rate": 0.0, "grounded": true, "heat": 0.0, "hp": 1.0, "shutdown": false,
	"disabled": false, "firing": false, "aiming": false, "effort": false, "footfall": false}
## The keys set_inputs accepts.
const EXTRA_KEYS: Array[String] = ["heat", "hp", "shutdown", "disabled", "firing", "aiming", "effort"]

var time_scale := 1.0
var fx_enabled := true
## Idle blinks / glances / tics on (tests turn it off for exact poses).
var idle_enabled := true
## Menu / hangar: tics without waiting for calm.
var idle_always := false
## The head actually built (an unknown or unrigged id falls back), the id asked for, and the look seed.
var head_id := ""
var requested_id := ""
var look_seed := 0
var face: PilotFace
var neck := PilotNeck.new()
var idle := PilotIdle.new()
## The effects layer (PilotFx), made in setup and fed by the `fx` signal; advanced from advance().
var fx_node: PilotFx

var _ch := {}
var _time := 0.0
var _mood_override := ""
var _auto_mood := "stern"
var _mood_w := {}
var _reactions: Array[Dictionary] = []
var _look_on := false
var _look_point := Vector3.ZERO
var _hit_look := Vector2.ZERO
var _hit_t := 1e9
var _in := DEFAULTS.duplicate()
var _extra := {}
var _prev_vel := Vector3.ZERO
var _accel := Vector3.ZERO
var _was_grounded := true
var _air_vy := 0.0
var _effort_held := false
var _fed_frame := -10
var _fx_rng := RandomNumberGenerator.new()
var _steam_t := 0.0
var _sweat_t := 0.0
var _phase := Vector3.ZERO
var _fx_mood := "stern"
var _fx_dazed := ""


## A head for `id` (MechCatalog head ids; unknown or not-yet-rigged ids fall back to FALLBACK), seeded for its idle.
static func make(id: String, head_seed: int = 0) -> PilotHead:
	var h := PilotHead.new()
	h.setup(id, head_seed)
	return h


static func ids() -> Array[String]:
	var out: Array[String] = []
	for k: String in REGISTRY:
		out.append(k)
	return out


static func moods() -> Array[String]:
	return ["stern", "focused", "strained", "overheated", "afraid", "dazed"]


static func reactions() -> Array[String]:
	return PilotExpressions.REACTION_ORDER.duplicate()


static func expressions() -> Array[String]:
	var out := moods()
	out.append_array(reactions())
	return out


## The mood a state asks for, by priority: dazed > afraid > overheated > strained > focused > stern.
static func pick_mood(state: Dictionary) -> String:
	if bool(state.get("disabled", false)) or bool(state.get("shutdown", false)):
		return "dazed"
	if float(state.get("hp", 1.0)) < HP_AFRAID:
		return "afraid"
	var heat := float(state.get("heat", 0.0))
	if heat >= HEAT_OVERHEATED:
		return "overheated"
	if heat >= HEAT_STRAINED:
		return "strained"
	if bool(state.get("firing", false)) or bool(state.get("aiming", false)):
		return "focused"
	return "stern"


func setup(id: String, head_seed: int = 0) -> void:
	requested_id = id
	head_id = id if REGISTRY.has(id) else FALLBACK
	look_seed = head_seed
	name = "PilotHead_" + head_id
	face = (load(REGISTRY[head_id]) as GDScript).new() as PilotFace
	face.build(self)
	fx_node = PilotFx.new()
	add_child(fx_node)
	fx_node.attach(self)
	neck.configure(face.style, face.pendulums)
	idle.setup(head_id, head_seed, face.tics)
	_fx_rng.seed = hash("fx:%s:%d" % [head_id, head_seed])
	_phase = Vector3(_fx_rng.randf() * TAU, _fx_rng.randf() * TAU, _fx_rng.randf() * TAU)
	_steam_t = _fx_rng.randf_range(STEAM_EVERY.x, STEAM_EVERY.y)
	_sweat_t = _fx_rng.randf_range(SWEAT_EVERY.x, SWEAT_EVERY.y)
	for m: String in moods():
		_mood_w[m] = 1.0 if m == "stern" else 0.0
	_ch = PilotExpressions.mood_row("stern", face.overrides)
	advance(0.0)


func _process(delta: float) -> void:
	if face == null or Engine.get_process_frames() - _fed_frame <= 1:
		return
	var want := DEFAULTS.duplicate()
	want.merge(_extra, true)
	want["effort"] = false
	if _in != want:
		_in = want
		_prev_vel = Vector3.ZERO
		_accel = Vector3.ZERO
		_auto_mood = pick_mood(want)
		_was_grounded = true
		_release_effort()
	advance(delta * time_scale)


## The driven path (see the header for the state keys).
func feed(delta: float, state: Dictionary) -> void:
	_fed_frame = Engine.get_process_frames()
	var dt := maxf(delta, 0.0) if is_finite(delta) else 0.0
	_in = DEFAULTS.duplicate()
	_in.merge(_extra, true)
	_in.merge(state, true)
	if _extra.has("effort"):
		_in["effort"] = bool(state.get("effort", false)) or bool(_extra["effort"])
	var vel: Vector3 = _in["vel"]
	if not vel.is_finite():
		vel = Vector3.ZERO
	if dt > 0.0:
		var raw := (vel - _prev_vel) / dt
		_accel = _accel.lerp(raw, 1.0 - exp(-dt / ACCEL_TAU))
		if not _accel.is_finite():
			_accel = Vector3.ZERO
	_prev_vel = vel
	var grounded := bool(_in["grounded"])
	if grounded and not _was_grounded:
		_land(maxf(-_air_vy, -vel.y))
	if not grounded:
		_air_vy = vel.y
	_was_grounded = grounded
	if bool(_in["footfall"]):
		neck.kick(Vector3(-deg_to_rad(FOOTFALL_NOD) * neck.footfall_gain, 0.0, 0.0))
	if bool(_in["effort"]) and not _effort_held:
		react("effort")
		_effort_held = true
		for r in _reactions:
			if r["id"] == "effort":
				r["held"] = true
	elif not bool(_in["effort"]):
		_release_effort()
	_auto_mood = pick_mood(_in)
	advance(dt * time_scale)


## Sticky inputs (EXTRA_KEYS) merged into every later feed / idle step (see the header). Later calls overwrite keys.
func set_inputs(extra: Dictionary) -> void:
	for k: String in extra:
		if k in EXTRA_KEYS:
			_extra[k] = extra[k]
		else:
			push_warning("PilotHead: set_inputs ignores " + k)


func clear_inputs() -> void:
	_extra.clear()


## The sticky inputs set so far.
func inputs() -> Dictionary:
	return _extra.duplicate()


## Overrides the automatic mood until clear_mood().
func set_mood(id: String) -> void:
	if id in moods():
		_mood_override = id
	else:
		push_warning("PilotHead: unknown mood " + id)


func clear_mood() -> void:
	_mood_override = ""


## The mood the head is in (or fading to).
func mood() -> String:
	return _mood_override if _mood_override != "" else _auto_mood


## A one-shot reaction (reactions()). A stronger one replaces a weaker running one of the same kind; different kinds
## stack. `local_dir` (head frame, toward the source; optional) aims the reactions that look (alert) or flinch away.
func react(id: String, strength: float = 1.0, local_dir: Vector3 = Vector3.ZERO) -> void:
	if not PilotExpressions.REACTIONS.has(id):
		push_warning("PilotHead: unknown reaction " + id)
		return
	strength = clampf(strength if is_finite(strength) else 0.0, 0.0, 1.5)
	if strength <= 0.0:
		return
	var d := PilotExpressions.reaction(id, face.overrides)
	for i in range(_reactions.size() - 1, -1, -1):
		var r := _reactions[i]
		if r["id"] == id:
			if strength >= float(r["s"]) * _env(r):
				_reactions.remove_at(i)
			else:
				return
	var inst := {"id": id, "s": strength, "t": 0.0, "d": d, "held": false, "has_dir": false, "dir": Vector2.ZERO}
	if local_dir.length_squared() > 1e-6 and local_dir.is_finite():
		inst["has_dir"] = true
		inst["dir"] = _dir_to_look(local_dir)
	var k: Dictionary = d.get("kick", {})
	neck.kick(Vector3(float(k.get("pitch", 0.0)), float(k.get("yaw", 0.0)), float(k.get("roll", 0.0))) * deg_to_rad(strength),
		deg_to_rad(float(k.get("flair", 0.0))) * strength, float(k.get("squash", 0.0)) * strength)
	_reactions.append(inst)
	if d.has("fx") and strength >= float(d.get("fx_min", 0.0)):
		_emit(str(d["fx"]), float(d.get("fx_strength", strength)))


## A hit: `local_dir` toward the source in the head's frame (zero = unknown), `amount` the fraction of HP it took.
## Flinch away from it (scaled by amount), Pain when large, then look toward the source LOOK_DELAY later for LOOK_HOLD.
func react_hit(local_dir: Vector3, amount: float) -> void:
	amount = clampf(amount if is_finite(amount) else 0.0, 0.0, 1.0)
	react("flinch", clampf(0.35 + amount * 4.0, 0.35, 1.0), local_dir)
	if amount >= PAIN_AMOUNT:
		react("pain", clampf(amount / 0.3, 0.6, 1.0))
	if local_dir.length_squared() > 1e-6 and local_dir.is_finite():
		_hit_look = _dir_to_look(local_dir)
		_hit_t = 0.0
		neck.kick(Vector3(0.0, -signf(_hit_look.x) * deg_to_rad(150.0), 0.0))


## Look at a point (global) with the aim priority: eyes first, then the head, within the neck limits.
func look_at_point(global_pos: Vector3) -> void:
	_look_on = global_pos.is_finite()
	_look_point = global_pos


func clear_look() -> void:
	_look_on = false


## Starts one of the head's idle tics now (lab / tests). False if the head has no such tic.
func play_tic(id: String) -> bool:
	return idle.play_tic(id)


func tics() -> Array[String]:
	var out: Array[String] = []
	for t: Dictionary in face.tics:
		out.append(str(t.get("id", "")))
	return out


## The current blended channel values.
func channels() -> Dictionary:
	return _ch.duplicate()


func piece(piece_name: String) -> Node3D:
	return face.piece(piece_name)


func face_count() -> int:
	var n := 0
	for mi in find_children("*", "MeshInstance3D", true, false):
		if fx_node != null and fx_node.is_ancestor_of(mi):
			continue
		var m := (mi as MeshInstance3D).mesh
		if m != null:
			for s in m.get_surface_count():
				n += m.surface_get_array_len(s) / 3
	return n


## Head seconds advanced so far.
func elapsed() -> float:
	return _time


## Is a reaction of this kind running?
func reacting(id: String) -> bool:
	for r in _reactions:
		if r["id"] == id:
			return true
	return false


## The deterministic step: moods, idle, reactions, channels, neck, pieces, effect cues.
func advance(delta: float) -> void:
	if face == null:
		return
	delta = maxf(delta, 0.0) if is_finite(delta) else 0.0
	_time += delta
	_hit_t += delta
	_step_moods(delta)
	if idle_enabled:
		var calm := mood() == "stern" and not bool(_in["firing"]) and not _busy()
		var dart := float(PilotExpressions.mood_pose("afraid", face.overrides).get("dart", 0.0)) * float(_mood_w["afraid"])
		for r: String in idle.step(delta, calm, idle_always, dart):
			react(r)
	_step_reactions(delta)

	# Channels and the neck's targets, layer by layer.
	var ch := {}
	for c: String in PilotExpressions.CHANNEL_ORDER:
		ch[c] = 0.0
	var pose := Vector3.ZERO    # degrees
	var sink := 0.0
	var push := 0.0
	var squash := 0.0
	var flair_back := 0.0
	var drift := 0.0
	var wsum := 0.0
	for m: String in moods():
		wsum += float(_mood_w[m])
	for m: String in moods():
		var w := float(_mood_w[m]) / maxf(wsum, 1e-6)
		if w <= 0.0:
			continue
		var row := PilotExpressions.mood_row(m, face.overrides)
		for c: String in row:
			ch[c] += float(row[c]) * w
		var mp := PilotExpressions.mood_pose(m, face.overrides)
		pose += Vector3(float(mp.get("pitch", 0.0)), float(mp.get("yaw", 0.0)), float(mp.get("roll", 0.0))) * w
		sink += float(mp.get("sink", 0.0)) * w
		push += float(mp.get("push", 0.0)) * w
		flair_back += float(mp.get("flair_back", 0.0)) * w
		var sway := float(mp.get("sway", 0.0))
		if sway > 0.0:
			var hz := float(mp.get("sway_hz", 0.5))
			pose += Vector3(0.0, sway * 0.6 * sin(TAU * hz * 0.66 * _time + 1.0), sway * sin(TAU * hz * _time)) * w
		var pant := float(mp.get("pant_hz", 0.0))
		if pant > 0.0:
			var s := sin(TAU * pant * _time)
			ch["jaw"] += float(mp.get("pant_jaw", 0.0)) * (0.5 + 0.5 * s) * w
			pose.x += float(mp.get("pant_nod", 0.0)) * s * w
		ch["brow_skew"] += float(mp.get("twitch", 0.0)) * pow(maxf(0.0, sin(TAU * 0.8 * _time)), 12.0) * w
		drift += float(mp.get("drift", 0.0)) * w
	for r in _reactions:
		var e := _env(r) * float(r["s"])
		var d: Dictionary = r["d"]
		var rc: Dictionary = d.get("ch", {})
		for c: String in rc:
			ch[c] += float(rc[c]) * e
		var rp: Dictionary = d.get("pose", {})
		pose += Vector3(float(rp.get("pitch", 0.0)), float(rp.get("yaw", 0.0)), float(rp.get("roll", 0.0))) * e
		if bool(r["has_dir"]):
			var side := signf((r["dir"] as Vector2).x)
			pose.y -= side * float(rp.get("away", 0.0)) * e
			pose.z -= side * float(rp.get("away_roll", 0.0)) * e
		sink += float(rp.get("sink", 0.0)) * e
		push += float(rp.get("push", 0.0)) * e
		squash += float(rp.get("squash", 0.0)) * e
		flair_back += float(rp.get("flair_back", 0.0)) * e
		if d.has("shake"):
			var sh: Dictionary = d["shake"]
			var t := float(r["t"])
			if t >= float(sh["from"]) and t <= float(sh["to"]):
				pose.y += float(sh["deg"]) * sin(TAU * float(sh["hz"]) * (t - float(sh["from"]))) * float(r["s"])
	if idle_enabled:
		pose += idle.neck * rad_to_deg(1.0)
		push += idle.push
		sink -= idle.lift
		for c: String in idle.channels:
			ch[c] += float(idle.channels[c])
	var tremble := clampf(float(ch["tremble"]), 0.0, 1.0)
	if tremble > 0.0:
		pose += Vector3(sin(_time * 29.0 + _phase.x), sin(_time * 37.0 + _phase.y), sin(_time * 43.0 + _phase.z)) \
			* TREMBLE_DEG * tremble
	var grounded := bool(_in["grounded"])
	if not grounded:
		squash -= AIR_STRETCH
		ch["flair"] += AIR_FLAIR

	# Where the head points: damage look > reaction look (alert) > aim > idle glance (+ turn lead, when not overridden).
	var look := Vector2.ZERO
	var override := false
	if _hit_t >= LOOK_DELAY and _hit_t < LOOK_DELAY + LOOK_HOLD:
		look = _hit_look
		override = true
	else:
		for r in _reactions:
			if bool(r["has_dir"]) and bool((r["d"] as Dictionary).get("look", false)) and _env(r) > 0.0:
				look = r["dir"]
				override = true
		if not override and _look_on:
			look = _point_to_look(_look_point)
			override = true
		if not override and idle_enabled and idle.glance_on:
			look = idle.glance
	neck.look = look
	neck.use_lead = not override
	neck.accel = _accel
	neck.yaw_rate = float(_in["yaw_rate"])
	neck.pose = pose * deg_to_rad(1.0)
	neck.pose_sink = sink
	neck.pose_push = push
	neck.pose_squash = squash
	neck.flair_level = clampf(float(ch["flair"]), -1.0, 1.0)
	var fl := Vector2(deg_to_rad(flair_back), 0.0)
	if idle_enabled:
		fl += idle.flair
	if tremble > 0.0:
		fl += Vector2(sin(_time * 31.0 + _phase.y), sin(_time * 41.0 + _phase.z)) * deg_to_rad(6.0) * tremble
	neck.flair_offset = fl
	neck.pend_offset = Vector2(deg_to_rad(-8.0) * float(ch["mouth_curve"]), 0.0)
	neck.step(delta)

	# The eyes cover what the head has not turned yet.
	ch["gaze_x"] += -neck.eye.x / PilotNeck.EYE_LIMIT
	ch["gaze_y"] += neck.eye.y / PilotNeck.EYE_LIMIT
	if tremble > 0.0:
		ch["gaze_x"] += sin(_time * 53.0 + _phase.x) * 0.06 * tremble
	for c: String in ch:
		ch[c] = PilotExpressions.clamp_channel(c, float(ch[c]))
	_ch = ch
	face.pose(_ch, neck, {"time": _time, "drift": drift, "tremble": tremble})
	_step_fx(delta)
	if fx_node != null:
		fx_node.advance(delta)


func _busy() -> bool:
	for r in _reactions:
		if r["id"] != "blink":
			return true
	return false


func _step_moods(delta: float) -> void:
	var target := mood()
	var rate := delta / PilotExpressions.MOOD_FADE
	for m: String in moods():
		var w := float(_mood_w[m])
		_mood_w[m] = minf(w + rate, 1.0) if m == target else maxf(w - rate, 0.0)


func _step_reactions(delta: float) -> void:
	var blinks := 0
	var keep: Array[Dictionary] = []
	for r in _reactions:
		var d: Dictionary = r["d"]
		var t0 := float(r["t"])
		var t := t0 + delta
		if bool(d.get("held", false)) and bool(r["held"]):
			t = minf(t, float(d["a"]))
		r["t"] = t
		for bt in d.get("blinks", []):
			if t0 < float(bt) and t >= float(bt):
				blinks += 1
		if t < PilotExpressions.duration(d):
			keep.append(r)
	_reactions = keep
	for i in blinks:
		react("blink")


func _env(r: Dictionary) -> float:
	var d: Dictionary = r["d"]
	return PilotExpressions.envelope(float(r["t"]), float(d["a"]), float(d["h"]), float(d["r"]))


func _release_effort() -> void:
	if not _effort_held:
		return
	_effort_held = false
	for r in _reactions:
		if r["id"] == "effort":
			r["held"] = false


func _land(speed: float) -> void:
	if not is_finite(speed) or speed < LAND_MIN:
		return
	react("impact", clampf((speed - LAND_MIN) / (LAND_FULL - LAND_MIN), 0.2, 1.0))
	if speed >= LAND_HARD:
		react("flinch", clampf(speed / LAND_FULL, 0.4, 1.0))


## A direction in the head's frame as a look (yaw + = left, pitch + = up).
static func _dir_to_look(d: Vector3) -> Vector2:
	return Vector2(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))


func _point_to_look(p: Vector3) -> Vector2:
	var xf := global_transform if is_inside_tree() else transform
	var local := xf.affine_inverse() * p - Vector3(0.0, EYE_HEIGHT, 0.0)
	if local.length_squared() < 1e-6:
		return Vector2.ZERO
	return _dir_to_look(local)


func _step_fx(delta: float) -> void:
	var m := mood()
	if m != _fx_mood:
		if _fx_dazed != "":
			_emit(_fx_dazed, 0.0)
			_fx_dazed = ""
		if m == "dazed":
			_fx_dazed = "smoke" if bool(_in["disabled"]) else "stars"
			_emit(_fx_dazed, 1.0)
		_fx_mood = m
	if delta <= 0.0:
		return
	if float(_mood_w["overheated"]) > 0.5:
		_steam_t -= delta
		if _steam_t <= 0.0:
			_steam_t = _fx_rng.randf_range(STEAM_EVERY.x, STEAM_EVERY.y)
			_emit("steam", float(_mood_w["overheated"]))
	if float(_mood_w["overheated"]) + float(_mood_w["strained"]) > 0.5:
		_sweat_t -= delta
		if _sweat_t <= 0.0:
			_sweat_t = _fx_rng.randf_range(SWEAT_EVERY.x, SWEAT_EVERY.y)
			_emit("sweat", 1.0)


func _emit(kind: String, strength: float) -> void:
	if fx_enabled:
		fx.emit(kind, strength)
