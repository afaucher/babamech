class_name EnemyWreckFx
extends RefCounted
## An enemy's fire and wreck presentation (looks only; nothing here is gameplay): manual-stepped LowPolyFlame socket /
## wreck flame jets (a living unit's broken-part sockets burn too), the ruptured core glow cooling to charcoal, and the
## rising faceted smoke of a downed wreck. It parents its nodes to the enemy and reads only the enemy's transform, `up`,
## `probe_height` and `target_id`; the enemy hands it the wreck's specs, its rupture point and the looks generator.
## The falling-wreck physics of the fliers is EnemyFlier's (_start_wreck_motion). All fields Net.LOCAL.

const CORE_COOL_TIME := 8.0         ## s for ruptured glowing core to cool toward dark charcoal
const SMOKE_DURATION := 13.0        ## s rising faceted smoke chunks emit from a downed wreck
const SMOKE_PUFF_COUNT := 4

var _e: EnemyBase
var _flame_entries: Array = []      ## [{stream, base_len, base_w, base_root, age, duration, done}]
var _core_glow_mi: MeshInstance3D = null
var _core_glow_mat: StandardMaterial3D = null
var _core_cool_age := 0.0
var _core_cooling := false
var _core_pos := Vector3.ZERO       ## enemy-local rupture point of the wreck (smoke origin)
var _core_scale := 1.0
var _smoke_puffs: Array = []        ## [{mi, age, life, start, vel, spin, size, done}]


func _init(e: EnemyBase = null) -> void:   # null only for the net contract test, which instantiates every script bare
	_e = e


func net_fields() -> Dictionary:
	return {"_e": Net.LOCAL, "_flame_entries": Net.LOCAL, "_core_glow_mi": Net.LOCAL, "_core_glow_mat": Net.LOCAL,
		"_core_cool_age": Net.LOCAL, "_core_cooling": Net.LOCAL, "_core_pos": Net.LOCAL, "_core_scale": Net.LOCAL,
		"_smoke_puffs": Net.LOCAL}


## Attach a manual-stepped LowPolyFlame.Stream whose -Y points along `local_dir` (duration <= 0 burns while alive).
func attach_flame(parent_node: Node3D, local_pos: Vector3, local_dir: Vector3,
		length: float, width: float, speed: float, count: int, root_scale: float,
		burn_duration: float, seed_tag: String) -> LowPolyFlame.Stream:
	var host: Node3D = parent_node if parent_node != null and is_instance_valid(parent_node) else _e
	var st := LowPolyFlame.Stream.new()
	st.name = "Flame_%s" % seed_tag
	st.position = local_pos
	var d := local_dir.normalized() if local_dir.length_squared() > 1e-6 else Vector3.UP
	var neg_d := -d
	var ref := Vector3.RIGHT if absf(neg_d.x) < 0.92 else Vector3.FORWARD
	var x := ref.cross(neg_d).normalized()
	var z := x.cross(neg_d).normalized()
	st.basis = Basis(x, neg_d, z)
	st.length = length
	st.width = width
	st.speed = speed
	st.count = count
	st.spread = 0.16
	st.tumble = 0.42
	st.root = root_scale
	st.jitter_seed = hash([_e.target_id, seed_tag])
	st.manual = true
	st.emitting = true
	host.add_child(st)
	st.rebuild()
	st.advance(0.18)
	_flame_entries.append({
		"stream": st, "base_len": length, "base_w": width, "base_root": root_scale,
		"age": 0.0, "duration": burn_duration, "done": false,
	})
	return st


func spawn_core_glow(local_pos: Vector3, scale_val: float, cooling: bool) -> void:
	if _core_glow_mi != null and is_instance_valid(_core_glow_mi):
		_core_glow_mi.queue_free()
	_core_glow_mi = EnemyMeshes.instance("rupture_core")
	_core_glow_mi.name = "RuptureCoreGlow"
	_core_glow_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core_glow_mi.position = local_pos
	_core_glow_mi.scale = Vector3.ONE * scale_val
	_core_glow_mat = StandardMaterial3D.new()
	_core_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_glow_mat.albedo_color = LowPolyFlame.MID
	_core_glow_mi.material_override = _core_glow_mat
	_e.add_child(_core_glow_mi)
	_core_cool_age = 0.0
	_core_cooling = cooling


## The enemy died: its wreck flames (`specs`: the enemy's _wreck_flame_specs), the cooling core glow at the enemy-local
## rupture point and the smoke puffs (drawn from `rng`, the looks generator).
func start(specs: Array, core_pos: Vector3, core_scale: float, rng: RandomNumberGenerator) -> void:
	_core_pos = core_pos
	_core_scale = core_scale
	_clear_flames()
	for sp: Dictionary in specs:
		var host: Node3D = sp.get("parent", _e)
		attach_flame(
			host,
			sp["pos"] as Vector3,
			sp["dir"] as Vector3,
			float(sp["length"]),
			float(sp["width"]),
			float(sp.get("speed", 10.5)),
			int(sp.get("count", 6)),
			float(sp.get("root", 1.0)),
			float(sp.get("duration", 7.5)),
			str(sp.get("tag", "wreck")),
		)
	spawn_core_glow(core_pos, core_scale, true)
	_spawn_smoke(rng)


## One wreck step (`dead_time`: s since death; smoke re-emits until SMOKE_DURATION). False once everything is out.
func step(dt: float, dead_time: float, rng: RandomNumberGenerator) -> bool:
	var flames_on := _tick_flames(dt)
	var core_on := _tick_core_glow(dt)
	var smoke_on := _tick_smoke(dt, dead_time, rng)
	return flames_on or core_on or smoke_on


## A living enemy's socket flames (broken parts burn while it fights on).
func step_flames(dt: float) -> void:
	if not _flame_entries.is_empty():
		_tick_flames(dt)


func clear() -> void:
	_clear_flames()
	_clear_smoke()
	if _core_glow_mi != null and is_instance_valid(_core_glow_mi):
		_core_glow_mi.queue_free()
	_core_glow_mi = null
	_core_glow_mat = null
	_core_cool_age = 0.0
	_core_cooling = false


func active_flame_streams() -> Array[LowPolyFlame.Stream]:
	var out: Array[LowPolyFlame.Stream] = []
	for e: Dictionary in _flame_entries:
		var st: LowPolyFlame.Stream = e["stream"]
		if is_instance_valid(st) and (st.emitting or st.active()):
			out.append(st)
	return out


func has_active_flame() -> bool:
	return not active_flame_streams().is_empty()


func _smoke_origin() -> Vector3:
	return _e.global_transform * _core_pos if _e.is_inside_tree() else _e.position + _e.up * _e.probe_height


func _spawn_smoke(rng: RandomNumberGenerator) -> void:
	_clear_smoke()
	var origin := _smoke_origin()
	var up_b := ImpactFx.basis_for_normal(_e.up)
	for i in SMOKE_PUFF_COUNT:
		var mi := CombatMeshes.instance(CombatMeshes.ico(ImpactFx.SMOKE))
		mi.name = "WreckSmoke_%d" % i
		mi.top_level = true
		mi.visible = false
		_e.add_child(mi)
		var life := rng.randf_range(1.9, 2.7)
		var puff := {
			"mi": mi, "age": -float(i) * 0.55, "life": life, "start": origin,
			"vel": _smoke_vel(rng, up_b),
			"spin": Vector3(rng.randf_range(-2.2, 2.2), rng.randf_range(-2.2, 2.2), rng.randf_range(-2.2, 2.2)),
			"size": rng.randf_range(0.65, 1.15) * _core_scale,
			"done": false,
		}
		_smoke_puffs.append(puff)


func _smoke_vel(rng: RandomNumberGenerator, up_b: Basis) -> Vector3:
	var ang := rng.randf_range(0.0, TAU)
	return _e.up * rng.randf_range(2.6, 4.4) + (up_b.x * cos(ang) + up_b.z * sin(ang)) * rng.randf_range(0.35, 1.15)


func _tick_flames(dt: float) -> bool:
	var any_active := false
	for e: Dictionary in _flame_entries:
		if bool(e["done"]):
			continue
		var st: LowPolyFlame.Stream = e["stream"]
		if not is_instance_valid(st):
			e["done"] = true
			continue
		var dur := float(e["duration"])
		var a := float(e["age"]) + dt
		e["age"] = a
		if dur > 0.0:
			var taper_start := dur * 0.62
			if a >= dur:
				st.emitting = false
				st.root = 0.0
			elif a > taper_start:
				var k := clampf(1.0 - (a - taper_start) / maxf(dur - taper_start, 0.01), 0.12, 1.0)
				st.length = float(e["base_len"]) * k
				st.width = float(e["base_w"]) * lerpf(0.45, 1.0, k)
				st.root = float(e["base_root"]) * k
		st.advance(dt)
		if dur > 0.0 and not st.emitting and not st.active():
			e["done"] = true
		else:
			any_active = true
	return any_active


func _tick_core_glow(dt: float) -> bool:
	if not _core_cooling or _core_glow_mat == null:
		return false
	_core_cool_age += dt
	var u := clampf(_core_cool_age / CORE_COOL_TIME, 0.0, 1.0)
	var ember_dark := Color(0.45, 0.12, 0.04)
	if u < 0.25:
		_core_glow_mat.albedo_color = LowPolyFlame.MID.lerp(LowPolyFlame.OUTER, u / 0.25)
	elif u < 0.65:
		_core_glow_mat.albedo_color = LowPolyFlame.OUTER.lerp(ember_dark, (u - 0.25) / 0.40)
	else:
		_core_glow_mat.albedo_color = ember_dark.lerp(EnemyMeshes.CHARRED, (u - 0.65) / 0.35)
	if u >= 1.0:
		_core_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_core_glow_mat.roughness = 0.95
		_core_cooling = false
		return false
	return true


func _tick_smoke(dt: float, dead_time: float, rng: RandomNumberGenerator) -> bool:
	var any_active := false
	var up_b := ImpactFx.basis_for_normal(_e.up)
	var origin := _smoke_origin()
	for p: Dictionary in _smoke_puffs:
		if bool(p["done"]):
			continue
		var mi: MeshInstance3D = p["mi"]
		if not is_instance_valid(mi):
			p["done"] = true
			continue
		var a := float(p["age"]) + dt
		var life := float(p["life"])
		if a >= life:
			if dead_time < SMOKE_DURATION:
				a = 0.0
				p["start"] = origin
				p["vel"] = _smoke_vel(rng, up_b)
				p["life"] = rng.randf_range(1.9, 2.7)
				life = float(p["life"])
			else:
				mi.visible = false
				p["done"] = true
				continue
		p["age"] = a
		any_active = true
		if a < 0.0:
			mi.visible = false
			continue
		var u := clampf(a / maxf(life, 0.01), 0.0, 1.0)
		if u > 0.92:
			mi.visible = false
			continue
		mi.visible = true
		var at := (p["start"] as Vector3) + (p["vel"] as Vector3) * a
		var sz := float(p["size"]) * lerpf(0.35, 1.2, pow(u, 0.65))
		var b := Basis.from_euler((p["spin"] as Vector3) * a)
		mi.global_transform = Transform3D(b.scaled(Vector3.ONE * sz), at)
	return any_active


func _clear_flames() -> void:
	for e: Dictionary in _flame_entries:
		var st: LowPolyFlame.Stream = e["stream"]
		if is_instance_valid(st):
			st.queue_free()
	_flame_entries.clear()


func _clear_smoke() -> void:
	for p: Dictionary in _smoke_puffs:
		var mi: MeshInstance3D = p["mi"]
		if is_instance_valid(mi):
			mi.queue_free()
	_smoke_puffs.clear()
