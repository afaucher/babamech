class_name EnemyHeatLook
extends RefCounted
## A unit's diegetic overheat (R2.27; docs/design/enemy-ai-structure.md "Overheat look"), mirroring the player mech
## (radiator fins glow with heat, MechRig's shutdown sag): COSMETIC, every machine, no messages, no gameplay state.
##   - Fins: the unit's VENT_GLOW faces follow its heat fraction (EnemyGlow instance uniforms: dim ember when cool, orange,
##     white-hot at the cap). Written at RATE (10 Hz) and only when the quantised value moved.
##   - Shutdown: optics / lamps go dark (a quick stutter out), `slump` eases 0 -> 1 on an underdamped spring (the units
##     read it: sag / barrel droop / flier wobble, visual pivots only, never the root, so hit shapes stay put), steam
##     puffs vent from the fins while they are hot.
##   - Reboot: the lights flicker back over FLICKER_TIME; the body rises RISE_DELAY s later.
## The shut state follows the unit's own `overheated` / `rebooted` signals: the moments the squad's "overheated" /
## "rebooted" events (CombatAudio's power-down / spin-up) fire, on the host (EnemyBase.tick, the heat.shutdown edge) and
## on a client (EnemySync replays the host's heat event). If the replicated heat.shutdown disagrees for RECONCILE s (a
## late joiner, a test that sets heat directly) the look adopts it silently. Heat: the host's gauge; a puppet's is the
## streamed u8 fraction (NetEnemyCodec), so both show the same glow.

const RATE := 0.1                 ## s between instance-uniform writes while steady (10 Hz)
const HEAT_STEPS := 24.0          ## the fin glow is quantised to 1/24 of the heat cap
const LIGHT_STEPS := 16.0
const SLUMP_TIME := 0.6           ## s the slump (and the rise) takes to settle, overshoot included (MechRig.sag_time)
const SLUMP_DAMP := 0.45          ## the spring's damping ratio (about 20 % overshoot, as MechRig's SAG_DAMP)
const RISE_DELAY := 0.3           ## s after the reboot before the body rises (the lights come first)
const DARK_TIME := 0.25           ## s the lights take to stutter out on shutdown
const FLICKER_TIME := 0.7         ## s the lights flicker back on reboot
const RECONCILE := 0.5            ## s of disagreement with the replicated heat.shutdown before adopting it
const STEAM_EVERY := 0.22         ## s between steam puffs while shut down and the fins are hot
const STEAM_MIN_HEAT := 0.5       ## no steam once the fins have cooled under this
const STEAM_LIFE := 1.2           ## s a puff lives
const STEAM_POOL := 6
const STEAM_COLOR := Color(0.84, 0.84, 0.82)
## The reboot flicker: [time (s from the reboot), lights] steps (on, off, on, low, on, dip, on).
const FLICKER := [[0.0, 1.0], [0.07, 0.0], [0.16, 1.0], [0.24, 0.15], [0.38, 1.0], [0.48, 0.35], [0.56, 1.0]]
## The shutdown stutter: [time (s from the overheat), lights].
const DARKEN := [[0.0, 0.25], [0.06, 0.8], [0.12, 0.1], [0.18, 0.4], [DARK_TIME, 0.0]]

var unit: EnemyBase
var optic_heat := 0.0             ## 1: the optics carry the heat ramp too (units whose fins are not the main lit part)
var steam_scale := 1.0            ## puff size (the unit's size)
var shut := false                 ## the look's shutdown state (from the overheated / rebooted moments)
var slump := 0.0                  ## 0 upright .. 1 slumped (overshoots past either end while easing)
var lights := 1.0                 ## 0 dark .. 1 lit (optics / lamps)
var glow_heat := 0.0              ## the heat fraction the fins show (unquantised)
var overheats := 0                ## tests: overheated moments seen
var reboots := 0                  ## tests: rebooted moments seen
var _slump_v := 0.0
var _edge_t := 99.0               ## s since the last overheated / rebooted moment
var _write_t := 0.0
var _shown_heat := -2.0           ## the values last written (quantised)
var _shown_lights := -2.0
var _mis: Array[MeshInstance3D] = []
var _bound := false
var _mismatch_t := 0.0
var _steam: Array[Dictionary] = []
var _steam_t := 0.0
var _steam_i := 0
var _clock := 0.0


func net_fields() -> Dictionary:
	return {"unit": Net.LOCAL, "optic_heat": Net.LOCAL, "steam_scale": Net.LOCAL, "shut": Net.LOCAL, "slump": Net.LOCAL,
		"lights": Net.LOCAL, "glow_heat": Net.LOCAL, "overheats": Net.LOCAL, "reboots": Net.LOCAL, "_slump_v": Net.LOCAL,
		"_edge_t": Net.LOCAL, "_write_t": Net.LOCAL, "_shown_heat": Net.LOCAL, "_shown_lights": Net.LOCAL,
		"_mis": Net.LOCAL, "_bound": Net.LOCAL, "_mismatch_t": Net.LOCAL, "_steam": Net.LOCAL, "_steam_t": Net.LOCAL,
		"_steam_i": Net.LOCAL, "_clock": Net.LOCAL}


func _init(u: EnemyBase = null) -> void:
	unit = u
	if u != null:
		u.overheated.connect(_on_overheated)
		u.rebooted.connect(_on_rebooted)
		_write_t = RATE * float(posmod(u.get_instance_id(), 7)) / 7.0   # spread the units' writes over the frames


func _on_overheated(_e: EnemyBase) -> void:
	if shut:
		return
	shut = true
	overheats += 1
	_edge_t = 0.0
	_steam_t = 0.0
	_mismatch_t = 0.0


func _on_rebooted(_e: EnemyBase) -> void:
	if not shut:
		return
	shut = false
	reboots += 1
	_edge_t = 0.0
	_mismatch_t = 0.0


## The lit meshes of the unit (every MeshInstance3D under it whose lit surface is EnemyGlow's): found on the first step,
## after the unit built its parts. rebind() looks again (a unit that swaps its parts).
func rebind() -> void:
	_bound = false


func _bind() -> void:
	_bound = true
	_mis.clear()
	var stack: Array[Node] = [unit]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi != null and EnemyGlow.drives(mi):
			_mis.append(mi)
	_shown_heat = -2.0
	_shown_lights = -2.0


## One presentation step: `heat` the unit's heat fraction (0..1), `shutdown` its (replicated) heat.shutdown.
func step(dt: float, heat: float, shutdown: bool) -> void:
	if unit == null:
		return
	if not _bound:
		_bind()
	_clock += dt
	_edge_t += dt
	if shutdown != shut:
		_mismatch_t += dt
		if _mismatch_t >= RECONCILE:
			shut = shutdown
			_edge_t = 99.0      # adopted, not a moment: no stutter / flicker
			_mismatch_t = 0.0
	else:
		_mismatch_t = 0.0
	glow_heat = clampf(heat, 0.0, 1.0)
	lights = _lights_now()
	_step_slump(dt)
	_step_steam(dt)
	_write(dt)


func _lights_now() -> float:
	if shut:
		return _track(DARKEN, _edge_t)
	return _track(FLICKER, _edge_t) if _edge_t < FLICKER_TIME else 1.0


static func _track(steps: Array, t: float) -> float:
	var v := 1.0
	for s: Array in steps:
		if t >= float(s[0]):
			v = float(s[1])
	return v


func _step_slump(dt: float) -> void:
	var target := 1.0 if shut or _edge_t < RISE_DELAY else 0.0
	if absf(slump - target) < 1e-4 and absf(_slump_v) < 1e-3:
		slump = target
		_slump_v = 0.0
		return
	var w := PI / (SLUMP_TIME * 0.55 * sqrt(1.0 - SLUMP_DAMP * SLUMP_DAMP))
	var steps := maxi(1, ceili(dt / 0.01))
	var h := dt / float(steps)
	for i in steps:
		_slump_v += (w * w * (target - slump) - 2.0 * SLUMP_DAMP * w * _slump_v) * h
		slump += _slump_v * h


## The uniforms: steady at RATE, every frame while the lights stutter / flicker; only when a quantised value moved.
func _write(dt: float) -> void:
	_write_t -= dt
	var fast := _edge_t < FLICKER_TIME
	if _write_t > 0.0 and not fast:
		return
	if _write_t <= 0.0:
		_write_t += RATE
		if _write_t <= 0.0:
			_write_t = RATE
	var qh := roundf(glow_heat * HEAT_STEPS) / HEAT_STEPS
	var ql := roundf(lights * LIGHT_STEPS) / LIGHT_STEPS
	if qh == _shown_heat and ql == _shown_lights:
		return
	_shown_heat = qh
	_shown_lights = ql
	for mi: MeshInstance3D in _mis:
		if is_instance_valid(mi):
			mi.set_instance_shader_parameter("vent_heat", qh)
			mi.set_instance_shader_parameter("lights", ql)
			mi.set_instance_shader_parameter("optic_heat", optic_heat)


## The fin glow / lights as last written (-2 = never): tests.
func shown_heat() -> float:
	return _shown_heat


func shown_lights() -> float:
	return _shown_lights


func lit_meshes() -> Array[MeshInstance3D]:
	return _mis


## Back to the meshes' plain look (dead: the wreck keeps its old look; reset: a fresh unit). Steam cleared.
func reset() -> void:
	shut = false
	slump = 0.0
	_slump_v = 0.0
	lights = 1.0
	_edge_t = 99.0
	_mismatch_t = 0.0
	for mi: MeshInstance3D in _mis:
		if is_instance_valid(mi):
			mi.set_instance_shader_parameter("vent_heat", -1.0)
			mi.set_instance_shader_parameter("lights", 1.0)
			mi.set_instance_shader_parameter("optic_heat", 0.0)
	_shown_heat = -2.0
	_shown_lights = -2.0
	for p: Dictionary in _steam:
		var mi: MeshInstance3D = p["mi"]
		if is_instance_valid(mi):
			mi.visible = false
		p["age"] = STEAM_LIFE


# --- Steam: a few light puffs rising from the fins (looks RNG only) --------------------------------------------------

func _step_steam(dt: float) -> void:
	if shut and glow_heat >= STEAM_MIN_HEAT and unit.is_inside_tree():
		_steam_t -= dt
		if _steam_t <= 0.0:
			_steam_t = STEAM_EVERY
			_puff()
	for p: Dictionary in _steam:
		var a := float(p["age"])
		if a >= STEAM_LIFE:
			continue
		var mi: MeshInstance3D = p["mi"]
		if not is_instance_valid(mi):
			p["age"] = STEAM_LIFE
			continue
		a += dt
		p["age"] = a
		if a >= STEAM_LIFE:
			mi.visible = false
			continue
		var u := a / STEAM_LIFE
		var at := (p["start"] as Vector3) + (p["vel"] as Vector3) * a
		var sz := float(p["size"]) * lerpf(0.4, 1.6, pow(u, 0.6)) * (1.0 - 0.5 * u * u)
		mi.global_transform = Transform3D(Basis.from_euler((p["spin"] as Vector3) * a).scaled(Vector3.ONE * sz), at)


func _puff() -> void:
	var src := _vent_source()
	if src.is_empty():
		return
	var rng := unit._looks_rng()
	var p: Dictionary = {}
	for q: Dictionary in _steam:
		if float(q["age"]) >= STEAM_LIFE:
			p = q
			break
	if p.is_empty():
		if _steam.size() >= STEAM_POOL:
			return
		var mi := CombatMeshes.instance(CombatMeshes.ico(STEAM_COLOR))
		mi.name = "OverheatSteam_%d" % _steam.size()
		mi.top_level = true
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		unit.add_child(mi)
		p = {"mi": mi}
		_steam.append(p)
	var up := unit.up
	var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	side = side.rotated(up, rng.randf_range(0.0, TAU))
	p["start"] = src[0] as Vector3
	p["vel"] = up * rng.randf_range(2.4, 3.6) + side * rng.randf_range(0.2, 0.8)
	p["spin"] = Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
	p["size"] = rng.randf_range(0.5, 0.8) * steam_scale
	p["age"] = 0.0
	(p["mi"] as MeshInstance3D).visible = true


## Where the next puff starts (world): the fins of the lit meshes in turn; the unit's top when it has none.
func _vent_source() -> Array:
	var pts: Array = []
	for mi: MeshInstance3D in _mis:
		if is_instance_valid(mi) and mi.is_visible_in_tree():
			for v: Vector3 in EnemyGlow.vent_points(mi.mesh):
				pts.append(mi.global_transform * v)
	if pts.is_empty():
		pts.append(unit.global_position + unit.up * unit.probe_height)
	_steam_i = (_steam_i + 1) % pts.size()
	return [pts[_steam_i]]


## Steam puffs showing now (tests).
func steam_live() -> int:
	var n := 0
	for p: Dictionary in _steam:
		if float(p["age"]) < STEAM_LIFE:
			n += 1
	return n


## A flier's shutdown look (visual pivot only): {sink (m, along the pivot's up), pitch (rad, nose down), roll (rad)} at
## `amp` (1 = drone). A slow wobble on top of the slump; the sink stays inside the hover bob's envelope.
func flier_offsets(amp: float) -> Vector3:
	var s := clampf(slump, 0.0, 1.3)
	return Vector3(-0.25 * s * amp, 0.30 * s * amp, sin(_clock * 5.5) * 0.12 * s * amp)
