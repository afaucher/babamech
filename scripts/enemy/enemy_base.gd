class_name EnemyBase
extends CombatTarget
## Shared base class for all enemies (docs/design/enemies.md): host-owned (owner_peer = 0), component HP with weak-point
## multipliers & critical kills, curved-deck RingFrame alignment & rooftop-shove falling, AI state machine with strict
## >= 0.3 s telegraphs, attack-slot arbitration via EnemySquad, diegetic hit flash / status bar, and unified Audio signals.

const STATE_IDLE := "idle"
const STATE_PATROL := "patrol"
const STATE_ALERT := "alert"
const STATE_ENGAGE := "engage"
const STATE_FLANK := "flank"
const STATE_TELEGRAPH := "telegraph"
const STATE_FIRE := "fire"
const STATE_COOLDOWN := "cooldown"
const STATE_STAGGERED := "staggered"
const STATE_OVERHEATED := "overheated"
const STATE_DEAD := "dead"

const HIT_FLASH_TIME := 0.07
const WRECK_LINGER := 2.8
const CORE_COOL_TIME := 8.0         ## s for ruptured glowing core to cool toward dark charcoal
const SMOKE_DURATION := 13.0        ## s rising faceted smoke chunks emit from a downed wreck
const SMOKE_PUFF_COUNT := 4
const FALL_DAMAGE_SPEED := 12.0
const FALL_DAMAGE_PER_MPS := 5.0
const ALERT_DELAY := 0.35
const RELAY_DELAY := 0.45
const NO_LOS_MORTAR_TIME := 2.5
const VEL_SMOOTH_RATE := 3.5      ## 1/s smoothing for target velocity lead (tracks steady walks, lags sharp dodges)
const MAX_LEAD_TIME := 2.0        ## s max velocity lead lookahead

signal alerted(enemy: EnemyBase, target_id: String)
signal comms_relayed(enemy: EnemyBase)
signal telegraph_started(enemy: EnemyBase, weapon_id: String, duration: float, muzzle: Vector3)
signal telegraph_cancelled(enemy: EnemyBase, reason: String)
signal weapon_fired(enemy: EnemyBase, weapon_id: String, muzzle: Vector3, aim_point: Vector3)
signal component_damaged(enemy: EnemyBase, component: String, hp_ratio: float, weak_point: bool)
signal component_destroyed(enemy: EnemyBase, component: String, at: Vector3)
signal overheated(enemy: EnemyBase)
signal rebooted(enemy: EnemyBase)
signal destroyed_enemy(enemy: EnemyBase, cause: String, at: Vector3)
signal footstep(enemy: EnemyBase, at: Vector3)

var enemy_type := "turret"
var world: CombatWorld
var squad: Node                  ## EnemySquad (typed loosely to avoid cyclic preload issues)
var ring: RingFrame              ## null on flat arenas (enemy_lab), set on curved city decks
var ai_mode := "live"            ## "live" | "idle" | "telegraph_loop" | "overheat"
var hp_scale := 1.0
var speed_scale := 1.0
var telegraph_scale := 1.0
var sight_range := 140.0
var auto_remove_wreck := false   ## true in Test Drive to clean wrecks after WRECK_LINGER; false in lab/tests
## Co-op (W4, scripts/game/enemy_sync.gd): the enemy's number in the host's manifest (NetEnemyCodec entries name it), the
## deck it spawned on (MissionRules counts alive enemies per deck), and `puppet`: a crew client's copy of a host enemy (no
## AI: CombatWorld never ticks it there; EnemySync shows it from the host's stream through the PUPPET API at the end).
var net_id := 0
var spawn_deck := 0
var puppet := false

# Owner gameplay state
var ai_state := STATE_IDLE
var _dead := false
var _dead_time := 0.0
var _primary_disabled := false
var _speed_mult := 1.0
var _shot_index := 0
var _target_id := ""
var _aim_point := Vector3.ZERO
var _locked_aim := Vector3.ZERO
var _active_weapon := ""
var _telegraph_t := 0.0
var _telegraph_dur := 0.0
var _burst_left := 0
var _burst_timer := 0.0
var _cooldown := 0.0
var _alert_timer := 0.0
var _relay_timer := -1.0
var _relayed := false
var _no_los_time := 0.0
var _has_slot := false
var _has_los := false
var _patrol_points: Array[Vector2] = []
var _patrol_idx := 0
var _path_points: Array[Vector2] = []
var _path_timer := 0.0
var _flank_sign := 1.0
var _last_air_fall := 0.0
var _grounded_now := true

# Continuous read-only telemetry for Audio loops
var move_speed_ratio := 0.0
var turret_slew_speed := 0.0
var heat_ratio := 0.0

# Internal / cosmetic references
var _cfg: Dictionary = {}
var _comp_meta: Dictionary = {}  ## comp_id -> catalog dict
var _comp_nodes: Dictionary = {} ## comp_id -> Array[MeshInstance3D]
var _flash_timers: Dictionary = {}
var _telegraph_fx: EnemyTelegraphFx
var _status_bar: EnemyStatusBar
var _rng := RandomNumberGenerator.new()
var _built_visuals := false
var _was_shutdown := false
var _was_staggered := false
var _home_xf := Transform3D.IDENTITY
var _last_target_ref: CombatTarget = null
var _last_seen_pos := Vector3.ZERO
var _tracked_tid := ""
var _prev_target_pos := Vector3.ZERO
var _target_vel := Vector3.ZERO
var _has_prev_pos := false
var _last_hit_dir := Vector3.ZERO
var _flame_entries: Array = []      ## [{stream, base_len, base_w, base_root, age, duration, done}]
var _core_glow_mi: MeshInstance3D = null
var _core_glow_mat: StandardMaterial3D = null
var _core_cool_age := 0.0
var _core_cooling := false
var _smoke_puffs: Array = []        ## [{mi, age, life, start, vel, spin, size, done}]
var _wreck_cooled := false


func _init() -> void:
	super._init()
	owner_peer = 0
	team = "enemy"
	add_to_group("enemies")


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"enemy_type": Net.SPAWN, "world": Net.LOCAL, "squad": Net.LOCAL, "ring": Net.SPAWN,
		"ai_mode": Net.SPAWN, "hp_scale": Net.SPAWN, "speed_scale": Net.SPAWN, "telegraph_scale": Net.SPAWN,
		"sight_range": Net.SPAWN, "auto_remove_wreck": Net.SPAWN,
		"net_id": Net.SPAWN, "spawn_deck": Net.SPAWN, "puppet": Net.SPAWN,
		"ai_state": Net.OWNER, "_dead": Net.OWNER, "_dead_time": Net.PRIVATE,
		"_primary_disabled": Net.OWNER, "_speed_mult": Net.OWNER, "_shot_index": Net.OWNER,
		"_target_id": Net.OWNER, "_aim_point": Net.OWNER, "_locked_aim": Net.OWNER,
		"_active_weapon": Net.OWNER, "_telegraph_t": Net.OWNER, "_telegraph_dur": Net.OWNER,
		"_burst_left": Net.PRIVATE, "_burst_timer": Net.PRIVATE, "_cooldown": Net.PRIVATE,
		"_alert_timer": Net.PRIVATE, "_relay_timer": Net.PRIVATE, "_relayed": Net.PRIVATE,
		"_no_los_time": Net.PRIVATE, "_has_slot": Net.PRIVATE, "_has_los": Net.PRIVATE,
		"_patrol_points": Net.SPAWN, "_patrol_idx": Net.PRIVATE, "_path_points": Net.PRIVATE,
		"_path_timer": Net.PRIVATE, "_flank_sign": Net.SPAWN, "_last_air_fall": Net.PRIVATE,
		"_grounded_now": Net.PRIVATE,
		"move_speed_ratio": Net.LOCAL, "turret_slew_speed": Net.LOCAL, "heat_ratio": Net.LOCAL,
		"_cfg": Net.LOCAL, "_comp_meta": Net.LOCAL, "_comp_nodes": Net.LOCAL, "_flash_timers": Net.LOCAL,
		"_telegraph_fx": Net.LOCAL, "_status_bar": Net.LOCAL, "_rng": Net.PRIVATE,
		"_built_visuals": Net.LOCAL, "_was_shutdown": Net.PRIVATE, "_was_staggered": Net.PRIVATE,
		"_home_xf": Net.SPAWN, "_last_target_ref": Net.LOCAL, "_last_seen_pos": Net.OWNER,
		"_tracked_tid": Net.PRIVATE, "_prev_target_pos": Net.PRIVATE, "_target_vel": Net.PRIVATE,
		"_has_prev_pos": Net.PRIVATE, "_last_hit_dir": Net.LOCAL, "_flame_entries": Net.LOCAL,
		"_core_glow_mi": Net.LOCAL, "_core_glow_mat": Net.LOCAL, "_core_cool_age": Net.LOCAL,
		"_core_cooling": Net.LOCAL, "_smoke_puffs": Net.LOCAL, "_wreck_cooled": Net.LOCAL,
	})
	return f


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	enemy_type = type_id
	target_id = id
	name = id
	world = w
	squad = sq
	ring = r
	hp_scale = maxf(hp_mult, 0.1)
	_rng.seed = hash([seed_val, id, type_id])
	_flank_sign = -1.0 if _rng.randi() % 2 == 0 else 1.0
	_cfg = EnemyCatalog.unit(type_id)
	mass_class = str(_cfg.get("mass_class", "mech"))
	sight_range = float(_cfg.get("sight_range", 140.0))
	probe_height = float(_cfg.get("probe_height", 2.4))
	body_radius = float(_cfg.get("body_radius", 2.0))
	heat = Heat.new(float(_cfg.get("heat_cap", 60.0)), float(_cfg.get("cooling", 4.0)))
	_apply_catalog_components()


func _apply_catalog_components() -> void:
	_comp_meta.clear()
	hit_shapes.clear()
	var caps := {}
	for c: Dictionary in _cfg.get("components", []):
		var cid := str(c["id"])
		_comp_meta[cid] = c
		caps[cid] = float(c["hp"]) * hp_scale
		for sp: Dictionary in c.get("spheres", []):
			add_hit_sphere(cid, sp["center"] as Vector3, float(sp["radius"]))
	if caps.is_empty():
		caps["body"] = 100.0 * hp_scale
	set_max_hp(caps)


func _ready() -> void:
	if _cfg.is_empty():
		_cfg = EnemyCatalog.unit(enemy_type)
		_apply_catalog_components()
	_home_xf = global_transform
	if ring != null:
		up = ring.up_at(global_position)
	ground_y = global_position.dot(up)
	if not _built_visuals:
		_build_visuals()
		_built_visuals = true
	_telegraph_fx = EnemyTelegraphFx.new()
	add_child(_telegraph_fx)
	_status_bar = EnemyStatusBar.new()
	_status_bar.position = Vector3(0.0, float(_cfg.get("bar_height", 6.2)), 0.0)
	add_child(_status_bar)


## Override in subclasses to build articulated MeshKit nodes and call _register_comp_mesh(comp_id, mi).
func _build_visuals() -> void:
	var mi := EnemyMeshes.instance("turret_base")
	add_child(mi)
	_register_comp_mesh(core_component(), mi)


func _register_comp_mesh(comp_id: String, mi: MeshInstance3D) -> void:
	if not _comp_nodes.has(comp_id):
		_comp_nodes[comp_id] = []
	(_comp_nodes[comp_id] as Array).append(mi)


func core_component() -> String:
	return str(_cfg.get("core", hp.keys()[0] if not hp.is_empty() else "body"))


func destroyed() -> bool:
	return _dead


func is_hittable() -> bool:
	return not _dead


func core_hp_ratio() -> float:
	var c := core_component()
	var cap := maxf(float(max_hp.get(c, 1.0)), 0.001)
	return clampf(float(hp.get(c, 0.0)) / cap, 0.0, 1.0)


func is_alerted() -> bool:
	return ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_TELEGRAPH, STATE_FIRE, STATE_COOLDOWN]


func eye_world() -> Vector3:
	var h := float(_cfg.get("eye_height", 4.2))
	return global_transform * Vector3(0.0, h, 0.0) if is_inside_tree() else position + up * h


## Override in subclasses for exact articulated muzzle world position.
func muzzle_world(_weapon_id: String = "") -> Vector3:
	return eye_world() + (-global_basis.z * 2.0 if is_inside_tree() else Vector3(0, 0, -2.0))


func telegraph_orb_radius(weapon_id: String) -> float:
	match weapon_id:
		"enemy_siege_shell": return 1.35
		"enemy_mortar": return 0.95
		"enemy_bolter": return 0.85
		_: return 0.62


# --- Damage, Weak Points, Heat & Destruction ---------------------------------------------------------------

func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty() or _dead:
		return
	var core := core_component()
	var c := component if (component != "" and hp.has(component)) else core
	var meta: Dictionary = _comp_meta.get(c, {})
	var mult := float(meta.get("mult", 1.0))
	var weak := bool(meta.get("weak_point", false))
	var eff := amount * mult
	var before := float(hp[c])
	if before <= 0.0 and c != core:
		var over := float(meta.get("overflow_to_core", 0.5))
		if over > 0.0:
			_damage_core_directly(eff * over, src)
		return
	hp[c] = maxf(before - eff, 0.0)
	_trigger_hit_flash(c)
	damaged.emit(eff, c, src)
	var ratio := float(hp[c]) / maxf(float(max_hp.get(c, 1.0)), 0.001)
	component_damaged.emit(self, c, ratio, weak)
	_emit_squad("component_damaged", {"id": target_id, "component": c, "hp_ratio": ratio, "weak_point": weak, "pos": _world_pos()})
	_on_damaged_alert(src)
	if before > 0.0 and float(hp[c]) <= 0.0:
		_on_component_broken(c, meta)


func _damage_core_directly(amount: float, src: String) -> void:
	var core := core_component()
	if amount <= 0.0 or _dead or not hp.has(core):
		return
	var before := float(hp[core])
	hp[core] = maxf(before - amount, 0.0)
	_trigger_hit_flash(core)
	damaged.emit(amount, core, src)
	var ratio := float(hp[core]) / maxf(float(max_hp.get(core, 1.0)), 0.001)
	component_damaged.emit(self, core, ratio, false)
	_emit_squad("component_damaged", {"id": target_id, "component": core, "hp_ratio": ratio, "weak_point": false, "pos": _world_pos()})
	if before > 0.0 and float(hp[core]) <= 0.0:
		_kill("core")


func apply_heat(amount: float, _src: String) -> void:
	if amount <= 0.0 or _dead:
		return
	heat.add(amount)


func apply_hit(h: Hit) -> void:
	if _dead:
		return
	if h.impulse.length_squared() > 1e-6:
		_last_hit_dir = h.impulse.normalized()
	elif h.normal.length_squared() > 1e-6:
		_last_hit_dir = (-h.normal).normalized()
	var meta: Dictionary = _comp_meta.get(h.component, {})
	var heat_mult := float(meta.get("heat_mult", 1.0))
	apply_damage(h.damage, h.component, h.shooter)
	if not _dead and h.impulse != Vector3.ZERO:
		apply_impulse(h.impulse, h.shooter)
	if not _dead and h.heat > 0.0:
		apply_heat(h.heat * heat_mult, h.shooter)


func _on_component_broken(c: String, meta: Dictionary) -> void:
	var pos := _world_pos()
	component_destroyed.emit(self, c, pos)
	_emit_squad("component_destroyed", {"id": target_id, "component": c, "pos": pos})
	if c == core_component():
		_kill("core")
		return
	if bool(meta.get("critical_kill", false)):
		var cause := str(meta.get("kill_cause", "weak_point"))
		_kill(cause)
		return
	# Non-fatal component break: apply mechanical penalty, pop debris, attach socket flame + local burst.
	if float(meta.get("cripple_speed", 0.0)) > 0.0:
		_speed_mult = minf(_speed_mult, float(meta["cripple_speed"]))
	if float(meta.get("cripple_stagger", 0.0)) > 0.0:
		knock.stagger_left = maxf(knock.stagger_left, float(meta["cripple_stagger"]))
		_cancel_telegraph("stagger")
	if bool(meta.get("disable_primary", false)):
		_primary_disabled = true
		_cancel_telegraph("destroyed")
	_spawn_component_debris(c)
	_on_component_visual_broken(c)
	if world != null:
		world.spawn_impact(pos + up * probe_height, up, 2.4, EnemyMeshes.CHARRED, true)
	var shock := float(meta.get("shock_to_core", 0.0))
	if shock > 0.0 and not puppet:   # a puppet's core HP comes from the host's stream
		_damage_core_directly(shock, "shock")


func _on_component_visual_broken(_comp_id: String) -> void:
	pass


func _kill(cause: String) -> void:
	if _dead:
		return
	_dead = true
	_dead_time = 0.0
	_wreck_cooled = false
	ai_state = STATE_DEAD
	_cancel_telegraph("destroyed")
	_release_slot()
	for k: String in hp:
		hp[k] = 0.0
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()
	if _status_bar != null:
		_status_bar.visible = false
	var pos := _world_pos()
	var exp_r := float(_cfg.get("explosion_radius", 4.0))
	var col_h := float(_cfg.get("explosion_column", 0.0))
	if world != null:
		var fx := world.spawn_impact(pos + up * (probe_height * 0.8), up, exp_r, EnemyMeshes.CHARRED, true)
		if fx != null and col_h > 0.0:
			fx.add_column(col_h)
	_spawn_death_debris(cause)
	_on_destroyed_visual()
	_start_wreck_fx()
	if squad != null and squad.has_method("register_wreck"):
		squad.register_wreck(self)
	destroyed_enemy.emit(self, cause, pos)
	_emit_squad("destroyed", {"id": target_id, "cause": cause, "pos": pos, "radius": exp_r})


func _on_destroyed_visual() -> void:
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi):
				mi.visible = false


# --- Persistent Destruction: Pop-Off Debris, Socket/Wreck Flames, Ruptured Core & Rising Smoke -------------

func _spawn_component_debris(_comp_id: String) -> void:
	pass


func _spawn_death_debris(_cause: String) -> void:
	pass


func _wreck_flame_specs() -> Array[Dictionary]:
	return [{
		"parent": self, "pos": _core_rupture_pos(), "dir": Vector3(0.08, 1.0, 0.05),
		"length": 3.8, "width": 0.9, "speed": 10.5, "count": 6, "root": 0.95, "duration": 7.5, "tag": "core",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, probe_height * 0.85, 0.0)


func _core_rupture_scale() -> float:
	return 1.0


func _debris_field() -> EnemyDebrisField:
	if squad != null and squad.has_method("get_debris_field"):
		return squad.get_debris_field() as EnemyDebrisField
	return null


func _looks_rng() -> RandomNumberGenerator:
	if world != null:
		return world.looks_rng
	return _rng


func _pop_part(part: String, xf: Transform3D, up_min: float, up_max: float, rad_min: float, rad_max: float,
		spin_max: float, charred: bool = false, mesh_scale: Vector3 = Vector3.ONE) -> EnemyDebris:
	var df := _debris_field()
	if df == null:
		return null
	var rng := _looks_rng()
	var up_b := ImpactFx.basis_for_normal(up)
	var ang := rng.randf_range(0.0, TAU)
	var horiz := (up_b.x * cos(ang) + up_b.z * sin(ang)).normalized()
	if _last_hit_dir.length_squared() > 1e-4:
		var flat_hit := _last_hit_dir - up * _last_hit_dir.dot(up)
		if flat_hit.length_squared() > 1e-4:
			horiz = (horiz * 0.55 + flat_hit.normalized() * 0.45).normalized()
	var vel := up * rng.randf_range(up_min, up_max) + horiz * rng.randf_range(rad_min, rad_max)
	var ang_vel := Vector3(rng.randf_range(-spin_max, spin_max), rng.randf_range(-spin_max, spin_max), rng.randf_range(-spin_max, spin_max))
	return df.spawn_chunk(part, xf, vel, ang_vel, charred, mesh_scale, ring)


func _pop_plates(origin_world: Vector3, count: int, up_min: float = 6.0, up_max: float = 11.0,
		rad_min: float = 4.0, rad_max: float = 9.0) -> void:
	var df := _debris_field()
	if df == null:
		return
	var rng := _looks_rng()
	var up_b := ImpactFx.basis_for_normal(up)
	for i in count:
		var part := "debris_plate" if i % 2 == 0 else "debris_chunk"
		var off := (up_b.x * rng.randf_range(-1.1, 1.1) + up_b.z * rng.randf_range(-1.1, 1.1) + up * rng.randf_range(-0.3, 0.7))
		var rot := Basis.from_euler(Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU)))
		var sc := Vector3.ONE * rng.randf_range(0.8, 1.25)
		_pop_part(part, Transform3D(rot, origin_world + off), up_min, up_max, rad_min, rad_max, 6.5, i % 2 == 1, sc)


## Attach a manual-stepped LowPolyFlame.Stream whose -Y points along `local_dir` (duration <= 0 burns while alive).
func _attach_flame_stream(parent_node: Node3D, local_pos: Vector3, local_dir: Vector3,
		length: float, width: float, speed: float, count: int, root_scale: float,
		burn_duration: float, seed_tag: String) -> LowPolyFlame.Stream:
	var host := parent_node if parent_node != null and is_instance_valid(parent_node) else self
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
	st.jitter_seed = hash([target_id, seed_tag])
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


func _spawn_core_glow(local_pos: Vector3, scale_val: float, cooling: bool) -> void:
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
	add_child(_core_glow_mi)
	_core_cool_age = 0.0
	_core_cooling = cooling


func _start_wreck_fx() -> void:
	_clear_flames()
	for sp: Dictionary in _wreck_flame_specs():
		var host: Node3D = sp.get("parent", self)
		_attach_flame_stream(
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
	_spawn_core_glow(_core_rupture_pos(), _core_rupture_scale(), true)
	_spawn_wreck_smoke()


func _spawn_wreck_smoke() -> void:
	_clear_smoke()
	var rng := _looks_rng()
	var origin := global_transform * _core_rupture_pos() if is_inside_tree() else position + up * probe_height
	var up_b := ImpactFx.basis_for_normal(up)
	for i in SMOKE_PUFF_COUNT:
		var mi := CombatMeshes.instance(CombatMeshes.ico(ImpactFx.SMOKE))
		mi.name = "WreckSmoke_%d" % i
		mi.top_level = true
		mi.visible = false
		add_child(mi)
		var life := rng.randf_range(1.9, 2.7)
		var puff := {
			"mi": mi, "age": -float(i) * 0.55, "life": life, "start": origin,
			"vel": _smoke_vel(rng, up_b),
			"spin": Vector3(rng.randf_range(-2.2, 2.2), rng.randf_range(-2.2, 2.2), rng.randf_range(-2.2, 2.2)),
			"size": rng.randf_range(0.65, 1.15) * _core_rupture_scale(),
			"done": false,
		}
		_smoke_puffs.append(puff)


func _smoke_vel(rng: RandomNumberGenerator, up_b: Basis) -> Vector3:
	var ang := rng.randf_range(0.0, TAU)
	return up * rng.randf_range(2.6, 4.4) + (up_b.x * cos(ang) + up_b.z * sin(ang)) * rng.randf_range(0.35, 1.15)


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


func _tick_wreck_smoke(dt: float) -> bool:
	var any_active := false
	var rng := _looks_rng()
	var up_b := ImpactFx.basis_for_normal(up)
	var origin := global_transform * _core_rupture_pos() if is_inside_tree() else position + up * probe_height
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
			if _dead_time < SMOKE_DURATION:
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


func _tick_wreck_fx(dt: float) -> void:
	var flames_on := _tick_flames(dt)
	var core_on := _tick_core_glow(dt)
	var smoke_on := _tick_wreck_smoke(dt)
	if not flames_on and not core_on and not smoke_on:
		_wreck_cooled = true


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


func _clear_destruction_fx() -> void:
	_clear_flames()
	_clear_smoke()
	if _core_glow_mi != null and is_instance_valid(_core_glow_mi):
		_core_glow_mi.queue_free()
	_core_glow_mi = null
	_core_glow_mat = null
	_core_cool_age = 0.0
	_core_cooling = false
	_wreck_cooled = false


func active_flame_streams() -> Array[LowPolyFlame.Stream]:
	var out: Array[LowPolyFlame.Stream] = []
	for e: Dictionary in _flame_entries:
		var st: LowPolyFlame.Stream = e["stream"]
		if is_instance_valid(st) and (st.emitting or st.active()):
			out.append(st)
	return out


func has_active_flame() -> bool:
	return not active_flame_streams().is_empty()


func has_charred_hulk() -> bool:
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi) and mi.visible:
				return true
	return false


func _trigger_hit_flash(comp_id: String) -> void:
	_flash_timers[comp_id] = HIT_FLASH_TIME
	for mi: MeshInstance3D in _comp_nodes.get(comp_id, []):
		if is_instance_valid(mi):
			mi.material_overlay = EnemyMeshes.flash_material()


func _tick_flashes(dt: float) -> void:
	for comp_id: String in _flash_timers.keys():
		var rem := float(_flash_timers[comp_id]) - dt
		if rem <= 0.0:
			_flash_timers.erase(comp_id)
			for mi: MeshInstance3D in _comp_nodes.get(comp_id, []):
				if is_instance_valid(mi):
					mi.material_overlay = null
		else:
			_flash_timers[comp_id] = rem


func _on_damaged_alert(src: String) -> void:
	if _dead or ai_mode == "idle":
		return
	if not is_alerted() and world != null:
		for t: CombatTarget in world.targets:
			if is_instance_valid(t) and t.target_id == src and t.team != team:
				_enter_alert(t, "spotted")
				return


# --- Tick (Host-owned simulation + local presentation) ----------------------------------------------------

func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	if puppet:   # co-op (W4): a client's copy has no AI; it is only shown
		puppet_tick(dt)
		return
	if _dead:
		if not _flash_timers.is_empty():
			_tick_flashes(dt)
		if _wreck_cooled and not auto_remove_wreck:
			return
		_dead_time += dt
		if _telegraph_fx != null:
			_telegraph_fx.tick_only(dt)
		if auto_remove_wreck and _dead_time >= WRECK_LINGER:
			if squad != null and squad.has_method("remove_enemy"):
				squad.remove_enemy(self)
			if world != null:
				world.unregister(self)
			queue_free()
			return
		if not _wreck_cooled:
			_tick_wreck_fx(dt)
		return
	_tick_flashes(dt)
	if squad != null and squad.has_method("deck_awake") and not squad.deck_awake(spawn_deck):
		return   # stack (W4): no crew mech on this enemy's deck: it sleeps

	# Update curved-deck local frame & ground plane BEFORE knockback step so rooftop shoves fall naturally!
	var pos := _world_pos()
	if ring != null:
		up = ring.up_at(pos)
	_update_dynamic_ground(pos, space)

	var prev_vu := knock.velocity.dot(up)
	var was_air := not _grounded_now
	super.tick(dt, space)
	pos = _world_pos()
	if ring != null:
		up = ring.up_at(pos)
	_grounded_now = pos.dot(up) <= ground_y + 0.08
	if not _grounded_now:
		_last_air_fall = maxf(_last_air_fall, -knock.velocity.dot(up))
	elif was_air:
		var impact_v := maxf(_last_air_fall, -prev_vu)
		if impact_v > FALL_DAMAGE_SPEED:
			_damage_core_directly((impact_v - FALL_DAMAGE_SPEED) * FALL_DAMAGE_PER_MPS, "fall")
		_last_air_fall = 0.0

	# Track overheat / reboot transitions for signals.
	heat_ratio = heat.fraction()
	if heat.shutdown and not _was_shutdown:
		_was_shutdown = true
		_cancel_telegraph("overheat")
		_release_slot()
		overheated.emit(self)
		_emit_squad("overheated", {"id": target_id, "pos": pos})
	elif not heat.shutdown and _was_shutdown:
		_was_shutdown = false
		rebooted.emit(self)
		_emit_squad("rebooted", {"id": target_id, "pos": pos})

	# Track stagger transitions.
	var stag := knock.staggered()
	if stag and not _was_staggered:
		_was_staggered = true
		_cancel_telegraph("stagger")
		_release_slot()
	elif not stag and _was_staggered:
		_was_staggered = false

	# Step AI only when alive.
	if not _dead:
		_step_ai(dt, space)
		_update_visuals(dt)
		if not _flame_entries.is_empty():
			_tick_flames(dt)


func _update_dynamic_ground(pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	if mass_factor() <= 0.0:
		return
	var g := _probe_ground_point(pos, space)
	if not is_nan(g.x):
		ground_y = g.dot(up)
	elif ring != null:
		ground_y = (pos - up * ring.height(pos)).dot(up)


func _probe_ground_point(pos: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(pos + up * 1.8, pos - up * 45.0)
		var h := space.intersect_ray(q)
		if not h.is_empty():
			return h["position"] as Vector3
	if ring != null:
		return pos - up * ring.height(pos)
	return Vector3(pos.x, 0.0, pos.z)


# --- AI State Machine -------------------------------------------------------------------------------------

func _step_ai(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if _cooldown > 0.0:
		_cooldown = maxf(_cooldown - dt, 0.0)
	if _relay_timer >= 0.0:
		_relay_timer -= dt
		if _relay_timer <= 0.0:
			_relay_timer = -1.0
			_fire_comms_relay()

	if ai_mode == "idle":
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	if ai_mode == "overheat":
		if not heat.shutdown:
			heat.add(heat.cap)
		ai_state = STATE_OVERHEATED
		_align_to_ring()
		return
	if heat.shutdown:
		ai_state = STATE_OVERHEATED
		_align_to_ring()
		return
	if knock.staggered():
		ai_state = STATE_STAGGERED
		_align_to_ring()
		return

	# Perception: check LOS to opposing targets (or shared squad target board).
	var target := _acquire_target(space)
	if target == null:
		_has_los = false
		_no_los_time = 0.0
		_cancel_telegraph("lost_los")
		_release_slot()
		var board_entry: Dictionary = _board_entry() if is_alerted() else {}
		if not board_entry.is_empty():
			_step_search(dt, board_entry["pos"] as Vector3, space)
		else:
			if ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_COOLDOWN]:
				_emit_squad("alerted", {"id": target_id, "state": "lost", "pos": _world_pos()})
			_step_patrol(dt, space)
		return

	_target_id = target.target_id
	_last_target_ref = target
	var target_pos := Vector3.ZERO
	if _has_los:
		target_pos = _target_aim_center(target)
		_last_seen_pos = target_pos
		_update_target_velocity(target, target_pos, dt)
		_no_los_time = 0.0
		if _relayed and squad != null and squad.has_method("report_sighting"):
			squad.report_sighting(self, target, target_pos)
	else:
		# TRUE LKP MEMORY (zero wallhack): when LOS is lost, aim/move/mortar ONLY at the frozen shared LKP!
		var b_entry := _board_entry()
		if not b_entry.is_empty():
			target_pos = b_entry["pos"] as Vector3
		else:
			target_pos = _last_seen_pos
		_target_vel = Vector3.ZERO
		_has_prev_pos = false
		_no_los_time += dt
	_aim_point = target_pos

	# Alert reaction delay before engaging.
	if ai_state in [STATE_IDLE, STATE_PATROL]:
		_enter_alert(target, "spotted")
		return
	if ai_state == STATE_ALERT:
		_alert_timer -= dt
		_track_aim(target_pos, dt)
		if _alert_timer <= 0.0:
			ai_state = STATE_ENGAGE
		return

	# Active telegraph wind-up.
	if ai_state == STATE_TELEGRAPH:
		_step_telegraph(dt, target, target_pos)
		return

	# Active burst firing.
	if ai_state == STATE_FIRE:
		_step_firing(dt)
		return

	# Reposition / flank while tracking target & waiting for cooldown + attack slot.
	_step_engage_movement(dt, target_pos, space)
	var track_err := _track_aim(target_pos, dt)
	var w_id := _choose_weapon(target_pos)
	if w_id != "" and _cooldown <= 0.0 and (track_err < 0.28 or w_id == "enemy_mortar"):
		if _request_slot(target.target_id):
			_begin_telegraph(w_id, target_pos)


func _enter_alert(target: CombatTarget, reason_state: String) -> void:
	if is_alerted():
		return
	ai_state = STATE_ALERT
	_target_id = target.target_id
	_alert_timer = ALERT_DELAY
	if reason_state == "spotted" and not _relayed:
		_relay_timer = RELAY_DELAY
	alerted.emit(self, target.target_id)
	_emit_squad("alerted", {"id": target_id, "state": reason_state, "pos": _world_pos()})


## Called by EnemySquad when a squadmate finishes its 0.45 s comm relay.
func receive_squad_alert(target: CombatTarget) -> void:
	if _dead or is_alerted() or ai_mode == "idle":
		return
	_relayed = true
	_enter_alert(target, "relay")


func _fire_comms_relay() -> void:
	if _dead or _relayed:
		return
	_relayed = true
	if _telegraph_fx != null:
		_telegraph_fx.trigger_relay_ring(eye_world(), up)
	comms_relayed.emit(self)
	if squad != null:
		if _last_target_ref != null and is_instance_valid(_last_target_ref) and squad.has_method("report_sighting"):
			squad.report_sighting(self, _last_target_ref, _last_seen_pos)
		if squad.has_method("relay_alert_from"):
			squad.relay_alert_from(self, _target_id)


func _choose_weapon(target_pos: Vector3) -> String:
	var dist := _world_pos().distance_to(target_pos)
	var prim := str(_cfg.get("primary_weapon", ""))
	if prim != "" and not _primary_disabled and _has_los:
		var pst := EnemyCatalog.weapon(prim)
		if dist <= float(pst.get("range", 160.0)):
			return prim
	var sec := str(_cfg.get("secondary_weapon", ""))
	if sec != "" and not _has_los and _no_los_time >= NO_LOS_MORTAR_TIME:
		var sst := EnemyCatalog.weapon(sec)
		if dist >= float(sst.get("min_range", 30.0)) and dist <= float(sst.get("range", 175.0)):
			return sec
	return ""


func _begin_telegraph(weapon_id: String, target_pos: Vector3) -> void:
	_active_weapon = weapon_id
	_telegraph_dur = EnemyCatalog.telegraph_duration(weapon_id, telegraph_scale)
	_telegraph_t = 0.0
	_locked_aim = _lead_aim_point(weapon_id, target_pos, _telegraph_dur)
	ai_state = STATE_TELEGRAPH
	var st := EnemyCatalog.weapon(weapon_id)
	var muz := muzzle_world(weapon_id)
	telegraph_started.emit(self, weapon_id, _telegraph_dur, muz)
	_emit_squad("telegraph_started", {
		"id": target_id, "weapon": weapon_id, "kind": str(st.get("telegraph_kind", "cannon")),
		"pos": muz, "target_pos": _locked_aim, "duration": _telegraph_dur,
	})


func _step_telegraph(dt: float, _target: CombatTarget, live_pos: Vector3) -> void:
	if _active_weapon != "enemy_mortar" and not _has_los and ai_mode != "telegraph_loop":
		_cancel_telegraph("lost_los")
		_release_slot()
		ai_state = STATE_ENGAGE
		return
	_telegraph_t += dt
	var st := EnemyCatalog.weapon(_active_weapon)
	var lock_share := float(st.get("lock_share", 0.6))
	if _telegraph_t < _telegraph_dur * lock_share:
		var rem_tele := maxf(_telegraph_dur - _telegraph_t, 0.0)
		_locked_aim = _lead_aim_point(_active_weapon, live_pos, rem_tele)
		_track_aim(_locked_aim, dt)
	else:
		_track_aim(_locked_aim, dt)
	if _telegraph_t >= _telegraph_dur:
		ai_state = STATE_FIRE
		_burst_left = maxi(int(st.get("burst", 1)), 1)
		_burst_timer = 0.0
		heat.add(float(st.get("self_heat", 10.0)))


func _update_target_velocity(target: CombatTarget, live_pos: Vector3, dt: float) -> void:
	if dt <= 1e-5:
		return
	var raw_v := Vector3.ZERO
	if target is PlayerTarget and (target as PlayerTarget).mech != null:
		raw_v = (target as PlayerTarget).mech.velocity
	elif _has_prev_pos and _tracked_tid == target.target_id:
		raw_v = (live_pos - _prev_target_pos) / dt
		if raw_v.length() > 60.0:
			raw_v = Vector3.ZERO
			_target_vel = Vector3.ZERO
	else:
		_target_vel = Vector3.ZERO
	var alpha := clampf(dt * VEL_SMOOTH_RATE, 0.0, 1.0)
	_target_vel = _target_vel.lerp(raw_v, alpha)
	_tracked_tid = target.target_id
	_prev_target_pos = live_pos
	_has_prev_pos = true


## Partial velocity lead in the local floor plane (never extrapolates an unseen LKP).
func _lead_aim_point(weapon_id: String, base_pos: Vector3, rem_tele: float) -> Vector3:
	if not _has_los:
		return base_pos
	var st := EnemyCatalog.weapon(weapon_id)
	var lf := float(st.get("lead_factor", 0.0))
	if lf <= 0.0 or _target_vel.length_squared() < 0.04:
		return base_pos
	var flat_v := _target_vel - up * _target_vel.dot(up)
	var muz := muzzle_world(weapon_id)
	var dist := muz.distance_to(base_pos)
	var flight_t := 0.0
	if str(st.get("kind", "")) == "arc":
		flight_t = MortarShell.flight_time_for(st, dist)
	else:
		flight_t = dist / maxf(float(st.get("speed", 50.0)), 1.0)
	var lead_t := minf(rem_tele + flight_t, MAX_LEAD_TIME) * lf
	return base_pos + flat_v * lead_t


func _step_firing(dt: float) -> void:
	var st := EnemyCatalog.weapon(_active_weapon)
	_burst_timer -= dt
	if _burst_timer <= 0.0 and _burst_left > 0:
		_fire_one_round(st)
		_burst_left -= 1
		_burst_timer = float(st.get("burst_interval", 0.15))
	if _burst_left <= 0:
		_cooldown = float(st.get("burst_cooldown", 2.0))
		_release_slot()
		ai_state = STATE_COOLDOWN if ai_mode == "live" else STATE_ENGAGE


func _fire_one_round(st: Dictionary) -> void:
	if world == null or puppet or not Net.is_host():   # co-op (W4): only the host's enemies fire
		return
	var muz := muzzle_world(_active_weapon)
	var aim := _locked_aim
	# Static aim kick throws turret shots visibly off target.
	var extra_spread := float(st.get("spread", 0.0)) + aim_kick
	var rec := Combat.fire_record(target_id, 1, _active_weapon, _active_weapon, muz, aim, world.now, _shot_index, extra_spread)
	rec["enemy"] = true
	rec["team"] = team
	_shot_index += 1
	world.fire(rec)
	weapon_fired.emit(self, _active_weapon, muz, aim)
	_emit_squad("weapon_fired", {"id": target_id, "weapon": _active_weapon, "pos": muz, "aim_point": aim})


func _cancel_telegraph(reason: String) -> void:
	if ai_state == STATE_TELEGRAPH:
		telegraph_cancelled.emit(self, reason)
		_emit_squad("telegraph_cancelled", {"id": target_id, "reason": reason})
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	_burst_left = 0
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()


func _request_slot(tid: String) -> bool:
	if _has_slot:
		return true
	if squad == null or not squad.has_method("request_attack_slot"):
		_has_slot = true
		return true
	var prio := float(_cfg.get("slot_priority", 1.0))
	_has_slot = bool(squad.request_attack_slot(target_id, tid, prio))
	return _has_slot


func _release_slot() -> void:
	if not _has_slot:
		return
	_has_slot = false
	if squad != null and squad.has_method("release_attack_slot"):
		squad.release_attack_slot(target_id)


# --- Perception & Movement Helpers ------------------------------------------------------------------------

func _acquire_target(space: PhysicsDirectSpaceState3D) -> CombatTarget:
	if world == null:
		return null
	var eye := eye_world()
	var best: CombatTarget = null
	var eff_range := sight_range
	if not is_alerted() and ai_mode != "telegraph_loop":
		eff_range = minf(sight_range, float(_cfg.get("patrol_sight_range", 65.0)))
	var best_d := eff_range
	var best_los := false
	var fov_cos := cos(deg_to_rad(float(_cfg.get("fov_deg", 110.0)) * 0.5))
	var fwd := -global_basis.z if is_inside_tree() else Vector3.FORWARD
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t == self or not t.is_hittable():
			continue
		if t.team == team or t.team == "":
			continue
		var tp := _target_aim_center(t)
		var d := eye.distance_to(tp)
		if d > eff_range:
			continue
		if squad != null and squad.has_method("on_deck") and not squad.on_deck(t.global_position, spawn_deck):
			continue   # stack (W4): only targets on this enemy's own deck
		var in_fov := is_alerted() or ai_mode == "telegraph_loop" or fwd.dot((tp - eye).normalized()) >= fov_cos
		var los := in_fov and _check_los(eye, tp, space)
		if los and (not best_los or d < best_d):
			best = t
			best_d = d
			best_los = true
	if best != null:
		_has_los = true
		return best
	# Fall back to shared squad target board only once this unit is alerted (prevents bypassing comm relay delay).
	_has_los = false
	if is_alerted():
		var entry := _board_entry()
		if not entry.is_empty():
			var bt: Variant = entry.get("target")
			if bt != null and is_instance_valid(bt) and (bt as CombatTarget).is_hittable():
				return bt as CombatTarget
	return null


func _board_entry() -> Dictionary:
	if squad != null and squad.has_method("best_known_target"):
		return squad.best_known_target(_world_pos(), spawn_deck)
	return {}


func _target_aim_center(t: CombatTarget) -> Vector3:
	if t.hit_shapes.size() > 0:
		var sp: Dictionary = t.world_spheres()[0]
		return sp["center"] as Vector3
	return t.global_position + t.up * 3.5


func _check_los(from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D) -> bool:
	if space == null or not world.use_physics:
		return true
	var d := from.distance_to(to)
	if d < 2.0:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var h := space.intersect_ray(q)
	if h.is_empty():
		return true
	return from.distance_to(h["position"] as Vector3) >= d - 2.6


func _step_patrol(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if float(_cfg.get("move_speed", 0.0)) <= 0.0 or _patrol_points.is_empty():
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	ai_state = STATE_PATROL
	var goal_arc := _patrol_points[_patrol_idx % _patrol_points.size()]
	var goal_w := _arc_to_world_pos(goal_arc)
	if _world_pos().distance_to(goal_w) < 4.5:
		_patrol_idx = (_patrol_idx + 1) % _patrol_points.size()
		goal_w = _arc_to_world_pos(_patrol_points[_patrol_idx])
	_steer_toward(goal_w, float(_cfg["move_speed"]) * 0.6 * speed_scale * _speed_mult, dt, space)


func _step_search(dt: float, lkp: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var spd := float(_cfg.get("move_speed", 0.0))
	if spd <= 0.0:
		_track_aim(lkp, dt)
		return
	if _world_pos().distance_to(lkp) > 10.0:
		_move_along_plan(lkp, spd * 0.85 * speed_scale * _speed_mult, dt, space)
	else:
		_align_to_ring()


func _step_engage_movement(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var base_spd := float(_cfg.get("move_speed", 0.0))
	if base_spd <= 0.0:
		_align_to_ring()
		return
	var pos := _world_pos()
	var dist := pos.distance_to(target_pos)
	var pref := float(_cfg.get("preferred_range", 45.0))
	var min_r := float(_cfg.get("min_range", 16.0))
	if not _has_los:
		ai_state = STATE_FLANK
		_move_along_plan(target_pos, float(_cfg.get("flank_speed", base_spd)) * speed_scale * _speed_mult, dt, space)
		return
	if dist > pref * 1.25:
		ai_state = STATE_ENGAGE
		_move_along_plan(target_pos, base_spd * speed_scale * _speed_mult, dt, space)
	elif dist < min_r:
		ai_state = STATE_FLANK
		var away := (pos - target_pos)
		away -= up * away.dot(up)
		var dest := pos + away.normalized() * 14.0
		_steer_toward(dest, base_spd * 0.8 * speed_scale * _speed_mult, dt, space)
	elif enemy_type == "strider":
		# Light skirmishers orbit/flank laterally instead of standing still in the street.
		ai_state = STATE_FLANK
		var to_t := target_pos - pos
		to_t -= up * to_t.dot(up)
		if to_t.length_squared() > 1e-4:
			var side := to_t.normalized().cross(up) * _flank_sign
			_steer_toward(pos + side * 12.0, float(_cfg.get("flank_speed", base_spd)) * 0.72 * speed_scale * _speed_mult, dt, space)
	else:
		ai_state = STATE_ENGAGE
		_align_to_ring()


func _move_along_plan(goal_w: Vector3, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	_path_timer -= dt
	if _path_timer <= 0.0 and squad != null and squad.has_method("find_arc_path"):
		_path_timer = 1.0
		_path_points = squad.find_arc_path(_world_to_arc2(_world_pos()), _world_to_arc2(goal_w), spawn_deck)
	var steer_goal := goal_w
	while not _path_points.is_empty():
		var wp := _arc_to_world_pos(_path_points[0])
		if _world_pos().distance_to(wp) < 6.0:
			_path_points.pop_front()
		else:
			steer_goal = wp
			break
	_steer_toward(steer_goal, spd, dt, space)


func _steer_toward(goal_w: Vector3, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if spd <= 0.05 or knock.moving() or not _grounded_now:
		_align_to_ring()
		return
	var pos := _world_pos()
	var to_g := goal_w - pos
	to_g -= up * to_g.dot(up)
	if to_g.length_squared() < 0.25:
		_align_to_ring()
		return
	var dir := to_g.normalized()
	# Soft sibling separation.
	if squad != null and squad.has_method("separation_vector"):
		var sep: Vector3 = squad.separation_vector(self)
		sep -= up * sep.dot(up)
		dir = (dir + sep * 1.4).normalized()
	# 3-whisker obstacle avoidance in local floor plane.
	if space != null and world != null and world.use_physics:
		var c := pos + up * probe_height
		var look_d := body_radius + 4.5
		if _ray_blocked(space, c, c + dir * look_d):
			var left_d := dir.rotated(up, 0.75)
			var right_d := dir.rotated(up, -0.75)
			var lb := _ray_blocked(space, c, c + left_d * look_d)
			var rb := _ray_blocked(space, c, c + right_d * look_d)
			if not lb and rb:
				dir = left_d
			elif not rb and lb:
				dir = right_d
			else:
				dir = dir.rotated(up, _flank_sign * 1.2)
				_flank_sign = -_flank_sign
	# Turn hull smoothly toward move direction in local tangent plane.
	var cur_fwd := (-global_basis.z) if is_inside_tree() else Vector3.FORWARD
	cur_fwd = (cur_fwd - up * cur_fwd.dot(up)).normalized()
	if cur_fwd.length_squared() < 1e-6:
		cur_fwd = dir
	var turn_max := float(_cfg.get("turn_rate", 2.0)) * dt
	var signed_ang := cur_fwd.signed_angle_to(dir, up)
	var new_fwd := cur_fwd.rotated(up, clampf(signed_ang, -turn_max, turn_max)).normalized()
	var move_align := clampf(cur_fwd.dot(dir), 0.25, 1.0)
	var step_vec := new_fwd * spd * move_align * dt
	# Check immediate collision before advancing.
	if space != null and world != null and world.use_physics:
		var c := pos + up * probe_height
		if _ray_blocked(space, c, c + new_fwd * (body_radius + step_vec.length() + 0.4)):
			step_vec = Vector3.ZERO
	var next_pos := pos + step_vec
	if ring != null:
		up = ring.up_at(next_pos)
	var g := _probe_ground_point(next_pos, space)
	if not is_nan(g.x):
		# Prevent mobile ground units from walking straight up tall walls (> 1.6 m step).
		var dh := (g - next_pos).dot(up)
		if dh <= 1.6 and dh >= -4.0:
			next_pos = g
		elif dh > 1.6:
			next_pos = pos
			step_vec = Vector3.ZERO
	ground_y = next_pos.dot(up)
	if is_inside_tree():
		global_position = next_pos
		var flat_f := (new_fwd - up * new_fwd.dot(up)).normalized()
		if flat_f.length_squared() > 1e-6:
			global_basis = Basis(flat_f.cross(up).normalized(), up, -flat_f)
	else:
		position = next_pos
	var max_s := maxf(float(_cfg.get("flank_speed", _cfg.get("move_speed", 1.0))), 0.1)
	move_speed_ratio = clampf(step_vec.length() / maxf(dt, 1e-4) / max_s, 0.0, 1.0)


func _ray_blocked(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var h := space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b))
	return not h.is_empty() and absf((h["normal"] as Vector3).dot(up)) < 0.72


func _align_to_ring() -> void:
	if not is_inside_tree():
		return
	var f := -global_basis.z
	f -= up * f.dot(up)
	if f.length_squared() < 1e-6:
		f = ring.tangent_at(global_position) if ring != null else Vector3.FORWARD
	f = f.normalized()
	global_basis = Basis(f.cross(up).normalized(), up, -f)


## Subclasses override to slew turret / head and return angular aim error (rad).
func _track_aim(_target_pos: Vector3, _dt: float) -> float:
	return 0.0


func _update_visuals(dt: float) -> void:
	if _telegraph_fx != null:
		if ai_state == STATE_TELEGRAPH and _telegraph_dur > 0.0:
			var frac := clampf(_telegraph_t / _telegraph_dur, 0.0, 1.0)
			var st := EnemyCatalog.weapon(_active_weapon)
			var locked := frac >= float(st.get("lock_share", 0.6))
			var show_beam := _active_weapon != "enemy_mortar"
			_telegraph_fx.show_telegraph(muzzle_world(_active_weapon), _locked_aim, frac, locked,
				telegraph_orb_radius(_active_weapon), show_beam, dt)
		else:
			_telegraph_fx.hide_telegraph()
			_telegraph_fx.tick_only(dt)
	if _status_bar != null:
		var tag := "OVERHEAT" if heat.shutdown else ("STAGGER" if knock.staggered() else "")
		_status_bar.refresh(core_hp_ratio(), heat_ratio, is_alerted(), ai_state == STATE_TELEGRAPH, tag, _dead, dt)


func _world_pos() -> Vector3:
	return global_position if is_inside_tree() else position


func _world_to_arc2(p: Vector3) -> Vector2:
	if ring != null:
		var a := ring.world_to_arc(p)
		return Vector2(a.x, a.y)
	return Vector2(p.x, p.z)


func _arc_to_world_pos(arc2: Vector2) -> Vector3:
	if ring != null:
		return ring.arc_to_world(arc2.x, arc2.y, CityPlan.CURB_H)
	return Vector3(arc2.x, 0.0, arc2.y)


func _emit_squad(kind: String, payload: Dictionary) -> void:
	if squad != null and squad.has_method("emit_enemy_event"):
		squad.emit_enemy_event(kind, self, payload)


func set_patrol_points(pts: Array[Vector2]) -> void:
	_patrol_points = pts.duplicate()
	_patrol_idx = 0


func debug_info() -> Dictionary:
	return {
		"id": target_id, "type": enemy_type, "state": ai_state, "hp": total_hp(), "core_hp": float(hp.get(core_component(), 0.0)),
		"heat": heat.value, "has_los": _has_los, "has_slot": _has_slot, "aim": _aim_point, "locked_aim": _locked_aim,
		"path": _path_points, "dead": _dead,
	}


func reset_enemy() -> void:
	_dead = false
	_dead_time = 0.0
	_primary_disabled = false
	_speed_mult = 1.0
	_relayed = false
	_relay_timer = -1.0
	_no_los_time = 0.0
	_cooldown = 0.0
	_target_vel = Vector3.ZERO
	_has_prev_pos = false
	_last_seen_pos = Vector3.ZERO
	_last_hit_dir = Vector3.ZERO
	_clear_destruction_fx()
	_cancel_telegraph("reset")
	_release_slot()
	ai_state = STATE_IDLE
	_apply_catalog_components()
	reset_state()
	if is_inside_tree():
		global_transform = _home_xf
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi):
				mi.visible = true
				mi.material_overlay = null
				mi.material_override = null
	_on_reset_visual()


func _on_reset_visual() -> void:
	pass


# --- Co-op PUPPET (W4; scripts/game/enemy_sync.gd) ---------------------------------------------------------------
# The host reads puppet_state() from its real enemy; a crew client writes it into its copy (`puppet` true) with
# puppet_apply(), replays discrete changes with puppet_telegraph / puppet_break / puppet_kill, and runs the
# presentation with puppet_tick() (hit flashes, telegraph, status bar, stride, wreck fx). No AI, no verbs.

## The enemy's OWNER state the puppets need: {state, aim (Vector2: subclass turret / torso yaw, pitch), heat (0..1),
## shutdown, stagger, kick (aim_kick deg), lock (the locked aim point, world), dead, hp (PackedFloat32Array: each
## component's fraction, comp_order() order)}.
func puppet_state() -> Dictionary:
	var fr := PackedFloat32Array()
	for c in comp_order():
		fr.append(clampf(float(hp.get(c, 0.0)) / maxf(float(max_hp.get(c, 1.0)), 0.001), 0.0, 1.0))
	return {"state": ai_state, "aim": puppet_aim(), "heat": heat.fraction(), "shutdown": heat.shutdown,
		"stagger": knock.staggered(), "kick": aim_kick, "lock": _locked_aim, "dead": _dead, "hp": fr}


## Component ids in catalog order (the order puppet_state's hp fractions use).
func comp_order() -> Array[String]:
	var out: Array[String] = []
	for c: Dictionary in _cfg.get("components", []):
		out.append(str(c["id"]))
	if out.is_empty():
		out.append_array(hp.keys())
	return out


## Subclasses: the aim pose (turret yaw / pitch, torso yaw) as a Vector2, and setting it on a puppet.
func puppet_aim() -> Vector2:
	return Vector2.ZERO


func set_puppet_aim(_a: Vector2) -> void:
	pass


## Puppet: the host's streamed state (puppet_state's keys; "move" / "slew" are derived by the caller from the motion).
## A component whose HP went down flashes.
func puppet_apply(st: Dictionary) -> void:
	if _dead:
		return
	ai_state = str(st.get("state", ai_state))
	set_puppet_aim(st.get("aim", Vector2.ZERO) as Vector2)
	heat.value = float(st.get("heat", 0.0)) * heat.cap
	heat.shutdown = bool(st.get("shutdown", false))
	heat_ratio = float(st.get("heat", 0.0))
	knock.stagger_left = 0.2 if bool(st.get("stagger", false)) else 0.0
	aim_kick = float(st.get("kick", 0.0))
	move_speed_ratio = float(st.get("move", 0.0))
	turret_slew_speed = float(st.get("slew", 0.0))
	if st.has("lock"):
		_locked_aim = st["lock"] as Vector3
	var fr: PackedFloat32Array = st.get("hp", PackedFloat32Array())
	var order := comp_order()
	for i in mini(fr.size(), order.size()):
		var c := order[i]
		var v := fr[i] * float(max_hp.get(c, 0.0))
		if v < float(hp.get(c, 0.0)) - 0.01:
			_trigger_hit_flash(c)
		hp[c] = v


## Puppet: a telegraph of `weapon_id` running for `elapsed` of its `dur` s (the host's start on the shared clock),
## toward `lock` (world). puppet_telegraph_end() stops showing it (fired, or cancelled).
func puppet_telegraph(weapon_id: String, elapsed: float, dur: float, lock: Vector3) -> void:
	if _dead:
		return
	_active_weapon = weapon_id
	_telegraph_dur = maxf(dur, 0.01)
	_telegraph_t = clampf(elapsed, 0.0, _telegraph_dur)
	_locked_aim = lock
	ai_state = STATE_TELEGRAPH


func puppet_telegraph_end() -> void:
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	if ai_state == STATE_TELEGRAPH:
		ai_state = STATE_ENGAGE
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()


## Puppet: the host's component `c` broke: the same pop-off debris, flame, impact and signals (a core / critical break
## kills it here too, as on the host).
func puppet_break(c: String) -> void:
	if _dead or not hp.has(c):
		return
	hp[c] = 0.0
	_on_component_broken(c, _comp_meta.get(c, {}))


## Puppet: the host's enemy was destroyed: the same explosion, debris (looks generator) and wreck.
func puppet_kill(cause: String) -> void:
	_kill(cause)


## Puppet presentation step (instead of tick(), which only the host runs).
func puppet_tick(dt: float) -> void:
	_tick_flashes(dt)
	if _dead:
		if _wreck_cooled:
			return
		_dead_time += dt
		if _telegraph_fx != null:
			_telegraph_fx.tick_only(dt)
		_tick_wreck_fx(dt)
		return
	if ring != null:
		up = ring.up_at(_world_pos())
	_update_visuals(dt)
	if not _flame_entries.is_empty():
		_tick_flames(dt)
