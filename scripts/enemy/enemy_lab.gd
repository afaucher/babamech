class_name EnemyLab
extends Node3D
## Lab subject "enemies" (docs/design/enemies.md §6): showcases all 3 enemy classes (Enforcer Turret, Hound Skirmisher,
## Bastion Siege Tank) beside an 8 m Strider player mech for scale/silhouette/palette inspection, plus a live skirmish
## arena with cover blocks, a 9 m roof perch, a moving target bot, tunable AI sliders, and a 3D debug overlay.

const PRESETS := ["showcase", "skirmish", "turret_only", "strider_only", "tank_only", "drone", "long_range", "breacher_cover"]
const AI_MODES := ["live", "idle", "telegraph_loop", "overheat"]
const TARGET_MODES := ["strafe", "stationary", "hidden", "bot_rookie", "bot_average", "bot_veteran", "bot_brawler"]
const DEBUG_MODES := ["on", "off"]

const PARAMS := [
	["telegraph_scale", "Telegraph scale (min 0.3s)", 0.6, 2.0],
	["attack_slots", "Attack slots / target", 1.0, 4.0],
	["enemy_speed_scale", "Enemy speed scale", 0.25, 2.0],
	["hp_scale", "Enemy HP scale", 0.25, 3.0],
	["sight_range", "Sight range (m)", 40.0, 200.0],
]

var time_scale := 1.0
var preset := "showcase"
var ai_mode := "live"
var target_mode := "strafe"
var debug_overlay := "on"

var telegraph_scale := 1.0
var attack_slots := 2.0
var enemy_speed_scale := 1.0
var hp_scale := 1.0
var sight_range := 140.0

var world: CombatWorld
var squad: EnemySquad
var ref_mech: MechModel
var mock_target: CombatTarget
var _mock_visual: MechModel
var bot_mech: MechController
var _bot_rig: MechRig
var bot_target: PlayerTarget
var bot_rack: WeaponRack
var bot_ai: PlayerBot
var _bot_reset_t := -1.0
var _bot_round := 0
var _t := 0.0
var _debug_mi: MeshInstance3D
var _debug_mesh: ImmediateMesh


func _ready() -> void:
	world = CombatWorld.new()
	world.name = "CombatWorld"
	world.mission_seed = 42
	add_child(world)
	squad = EnemySquad.new()
	add_child(squad)
	squad.setup(world, null, null)
	_build_arena()
	_debug_mesh = ImmediateMesh.new()
	_debug_mi = CombatMeshes.instance(_debug_mesh)
	_debug_mi.top_level = true
	add_child(_debug_mi)
	_rebuild()


func lab_own_ground() -> bool:
	return true


func _build_arena() -> void:
	# Bright sunlit city-palette yard (asphalt road, cream sidewalk, terracotta cover, 9 m roof perch).
	_add_block(Vector3(110.0, 1.0, 110.0), Vector3(0.0, -0.5, -20.0), CityPalette.c("asphalt"))
	_add_block(Vector3(24.0, 0.2, 110.0), Vector3(-42.0, 0.1, -20.0), CityPalette.c("sidewalk"))
	_add_block(Vector3(24.0, 0.2, 110.0), Vector3(42.0, 0.1, -20.0), CityPalette.c("sidewalk"))
	# 9 m jumpable rooftop building for rooftop turret placement.
	_add_block(Vector3(14.0, 9.0, 14.0), Vector3(-22.0, 4.5, -38.0), CityPalette.c("cream"))
	_add_block(Vector3(14.4, 0.4, 14.4), Vector3(-22.0, 9.2, -38.0), CityPalette.c("roof"))
	# Low cover blocks in the yard (used for LOS / hidden flush-mortar testing).
	_add_block(Vector3(10.0, 6.0, 3.0), Vector3(0.0, 3.0, -14.0), CityPalette.c("terracotta"))
	_add_block(Vector3(8.0, 7.5, 8.0), Vector3(22.0, 3.75, -34.0), CityPalette.c("sage"))


func _add_block(size: Vector3, at: Vector3, col: Color) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.set_meta("surface_color", col)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	var k := MeshKit.new()
	k.box(size, col)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit(MechMeshes.materials())
	body.add_child(mi)
	add_child(body)


func _clear_player_target() -> void:
	if mock_target != null:
		if world != null:
			world.unregister(mock_target)
		if mock_target.get_parent() == self:
			remove_child(mock_target)
		mock_target.queue_free()
		mock_target = null
		_mock_visual = null
	if bot_ai != null:
		if bot_ai.get_parent() == self:
			remove_child(bot_ai)
		bot_ai.queue_free()
		bot_ai = null
	if bot_rack != null:
		if bot_rack.get_parent() == self:
			remove_child(bot_rack)
		bot_rack.queue_free()
		bot_rack = null
	if bot_target != null:
		if world != null:
			world.unregister(bot_target)
		if bot_target.get_parent() == self:
			remove_child(bot_target)
		bot_target.queue_free()
		bot_target = null
	if bot_mech != null:
		if bot_mech.get_parent() == self:
			remove_child(bot_mech)
		bot_mech.queue_free()
		bot_mech = null
		_bot_rig = null
	_bot_reset_t = -1.0


func _spawn_player_target() -> void:
	_clear_player_target()
	if preset == "showcase" or world == null:
		return
	if target_mode.begins_with("bot_"):
		var prof := target_mode.substr(4)
		var loadout := BotProfile.get_loadout(prof)
		bot_mech = MechSpawn.make("chicken", "strider", loadout)
		bot_mech.name = "LabBotMech"
		bot_mech.position = Vector3(0.0, 0.0, 6.0)
		add_child(bot_mech)
		_bot_rig = MechSpawn.rig_of(bot_mech)
		bot_mech.set_physics_process(false)
		if _bot_rig != null:
			_bot_rig.set_physics_process(false)
		var ma := bot_mech.get_node_or_null("Audio")
		if ma != null:
			ma.set_physics_process(false)
		var tfx := bot_mech.get_node_or_null("Thrusters")
		if tfx != null:
			tfx.set_physics_process(false)

		bot_target = PlayerTarget.new()
		bot_target.name = "LabBotTarget"
		bot_target.auto_respawn_delay = -1.0
		add_child(bot_target)
		bot_target.bind(world, bot_mech, _bot_rig.model if _bot_rig != null else null, "lab_player", 1)
		world.register(bot_target)

		bot_rack = WeaponRack.new()
		bot_rack.name = "LabBotRack"
		bot_rack.auto_step = false
		bot_rack.read_input = false
		bot_rack.manual_aim = true
		bot_rack.slot_disabled = bot_target.is_slot_destroyed
		add_child(bot_rack)
		bot_rack.bind(world, bot_mech, _bot_rig.model if _bot_rig != null else null, null, "lab_player", 1)

		bot_ai = PlayerBot.new()
		bot_ai.name = "LabPlayerBot"
		bot_ai.auto_step = false
		bot_ai.configure(prof, 42 + _bot_round * 7, "lab_bot")
		add_child(bot_ai)
		bot_ai.bind(bot_mech, bot_rack, bot_target, world, squad, null, null, null)
		bot_ai.set_arena_roofs([
			{"center": Vector3(-22.0, 9.4, -38.0), "size": Vector2(14.0, 14.0), "roof_h": 9.4},
			{"center": Vector3(22.0, 7.5, -34.0), "size": Vector2(8.0, 8.0), "roof_h": 7.5},
		])
		return

	# Default mock target modes (strafe / stationary / hidden).
	mock_target = CombatTarget.new()
	mock_target.name = "MockPlayer"
	mock_target.target_id = "lab_player"
	mock_target.owner_peer = 1
	mock_target.team = "player"
	mock_target.mass_class = "mech"
	mock_target.set_max_hp({"torso": 10000.0})
	mock_target.add_hit_sphere("torso", Vector3(0.0, 4.2, 0.0), 2.1)
	mock_target.position = _mock_pos(0.0)
	add_child(mock_target)
	_mock_visual = MechModel.new()
	_mock_visual.scale = Vector3.ONE * 2.0
	mock_target.add_child(_mock_visual)
	_mock_visual.configure("chicken", "strider", {})
	world.register(mock_target)


func _rebuild() -> void:
	if squad == null:
		return
	squad.clear_enemies()
	squad.max_attackers = maxi(int(round(attack_slots)), 1)
	if ref_mech != null:
		if ref_mech.get_parent() == self:
			remove_child(ref_mech)
		ref_mech.queue_free()
		ref_mech = null
	_clear_player_target()
	_t = 0.0

	if preset == "showcase":
		# Side-by-side scale & silhouette lineup: 8 m player Strider beside Turret, Skirmisher, and Siege Tank.
		ref_mech = MechModel.new()
		ref_mech.scale = Vector3.ONE * 2.0
		ref_mech.position = Vector3(-13.0, 0.0, 0.0)
		ref_mech.rotation.y = PI
		add_child(ref_mech)
		ref_mech.configure("chicken", "strider", {})
		_spawn("strider", "lab_strider", Vector3(-5.0, 0.0, 0.0), PI, "idle")
		_spawn("turret", "lab_turret", Vector3(3.0, 0.0, 0.0), PI, "idle")
		_spawn("tank", "lab_tank", Vector3(13.0, 0.0, 0.0), PI, "idle")
		return

	_spawn_player_target()

	match preset:
		"skirmish":
			_spawn("turret", "lab_roof_turret", Vector3(-22.0, 9.4, -38.0), PI, ai_mode)
			var s1 := _spawn("strider", "lab_strider_1", Vector3(-9.0, 0.0, -34.0), PI, ai_mode)
			s1.set_patrol_points([Vector2(-12.0, -30.0), Vector2(10.0, -30.0)])
			var s2 := _spawn("strider", "lab_strider_2", Vector3(12.0, 0.0, -30.0), PI, ai_mode)
			s2.set_patrol_points([Vector2(14.0, -24.0), Vector2(-6.0, -40.0)])
			_spawn("tank", "lab_tank_1", Vector3(2.0, 0.0, -48.0), PI, ai_mode)
		"turret_only":
			_spawn("turret", "lab_turret_1", Vector3(0.0, 0.0, -36.0), PI, ai_mode)
		"strider_only":
			var s := _spawn("strider", "lab_strider_1", Vector3(0.0, 0.0, -34.0), PI, ai_mode)
			s.set_patrol_points([Vector2(-12.0, -32.0), Vector2(12.0, -32.0)])
		"tank_only":
			_spawn("tank", "lab_tank_1", Vector3(0.0, 0.0, -44.0), PI, ai_mode)
		"drone":
			var d := _spawn("drone", "lab_drone_1", Vector3(0.0, 15.0, -40.0), PI, ai_mode)
			d.set_patrol_points([Vector2(-24.0, -32.0), Vector2(24.0, -32.0), Vector2(24.0, -56.0), Vector2(-24.0, -56.0)])
			_spawn("strider_breacher", "lab_drone_escort", Vector3(24.0, 0.0, -48.0), PI, ai_mode)
		"long_range":
			_spawn("turret_sniper", "lab_sniper_1", Vector3(-22.0, 9.4, -38.0), PI, ai_mode)
			_spawn("turret_missile", "lab_missile_1", Vector3(22.0, 7.5, -34.0), PI, ai_mode)
		"breacher_cover":
			var b1 := _spawn("strider_breacher", "lab_breacher_1", Vector3(-14.0, 0.0, -46.0), PI, ai_mode)
			b1.set_patrol_points([Vector2(-18.0, -44.0), Vector2(-4.0, -44.0)])
			var b2 := _spawn("strider_breacher", "lab_breacher_2", Vector3(14.0, 0.0, -46.0), PI, ai_mode)
			b2.set_patrol_points([Vector2(18.0, -44.0), Vector2(4.0, -44.0)])
	_sync_params()


func _spawn(type_id: String, id: String, at: Vector3, yaw: float, mode: String) -> EnemyBase:
	var e := EnemySpawner.make_enemy(type_id)
	e.configure(type_id, id, world, squad, null, 42, hp_scale)
	e.ai_mode = mode
	e.position = at
	e.rotation.y = yaw
	squad.add_enemy(e)
	return e


func _sync_params() -> void:
	if squad == null:
		return
	squad.max_attackers = maxi(int(round(attack_slots)), 1)
	for e in squad.enemies:
		if not is_instance_valid(e):
			continue
		e.telegraph_scale = telegraph_scale
		e.speed_scale = enemy_speed_scale
		e.sight_range = sight_range
		if preset != "showcase":
			e.ai_mode = ai_mode


func _mock_pos(t: float) -> Vector3:
	match target_mode:
		"stationary": return Vector3(0.0, 0.0, 6.0)
		"hidden": return Vector3(0.0, 0.0, -8.5)     # tucked directly behind the central terracotta cover block
	return Vector3(sin(t * 0.65) * 18.0, 0.0, 6.0)


func _physics_process(delta: float) -> void:
	step(delta * time_scale)


func step(dt: float) -> void:
	if world == null or dt <= 0.0:
		return
	_t += dt
	if mock_target != null and is_instance_valid(mock_target):
		mock_target.global_position = _mock_pos(_t)
		mock_target.reset_state()
	elif bot_ai != null and is_instance_valid(bot_ai) and bot_mech != null and is_instance_valid(bot_mech):
		bot_ai.step(dt)
		bot_mech.step(dt)
		if _bot_rig != null and is_instance_valid(_bot_rig):
			_bot_rig.update_pose(dt)
		if bot_rack != null and is_instance_valid(bot_rack):
			bot_rack.step(dt)
		# Auto-reset skirmish 2.5 s after all enemies fall or the player bot is disabled.
		var ended := (bot_target != null and bot_target.disabled) or (squad != null and squad.alive_count() == 0)
		if ended:
			if _bot_reset_t < 0.0:
				_bot_reset_t = 2.5
			else:
				_bot_reset_t -= dt
				if _bot_reset_t <= 0.0:
					_bot_round += 1
					_rebuild()
					return
		else:
			_bot_reset_t = -1.0
	world.advance(dt)
	_draw_debug()


func _draw_debug() -> void:
	if _debug_mesh == null:
		return
	_debug_mesh.clear_surfaces()
	if debug_overlay != "on" or squad == null:
		return
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES, CombatMeshes.ribbon_material())
	for e in squad.enemies:
		if not is_instance_valid(e) or e.destroyed():
			continue
		var info := e.debug_info()
		# Hit-sphere rings (yellow for weak points, cyan for regular components).
		for sp: Dictionary in e.world_spheres():
			var c: Vector3 = sp["center"]
			var r: float = float(sp["radius"])
			var comp := str(sp["component"])
			var is_wp := comp in ["gun", "sensor", "vents", "optic"]
			_draw_circle(c, r, Color(1.0, 0.85, 0.2) if is_wp else Color(0.25, 0.85, 0.95))
		# LOS ray to current aim point (green = clear LOS, red = blocked).
		if e.is_alerted():
			var eye := e.eye_world()
			var aim: Vector3 = info["aim"]
			var col := Color(0.2, 1.0, 0.35) if bool(info["has_los"]) else Color(1.0, 0.2, 0.2)
			_line(eye, aim, col)
		# Active attack-slot ring on the ground.
		if bool(info["has_slot"]):
			_draw_circle(e.global_position + Vector3(0.0, 0.25, 0.0), e.body_radius + 0.8, Color(1.0, 0.2, 0.2))
	# Shared target board LKP marker.
	for tid: String in squad.known_targets:
		var lkp: Vector3 = squad.known_targets[tid]["pos"]
		_draw_circle(lkp, 1.4, Color(1.0, 0.5, 0.1))
	# PlayerBot spectator debug lines (cyan aim, green nav, magenta dodge, gold roof jump).
	if bot_ai != null and is_instance_valid(bot_ai) and bot_mech != null and is_instance_valid(bot_mech):
		var dbg := bot_ai.debug_state()
		var bp := bot_mech.global_position
		var eye := bp + Vector3(0.0, PlayerBot.EYE_HEIGHT, 0.0)
		var aim_w: Vector3 = dbg["aim"]
		if aim_w.distance_squared_to(eye) > 1.0:
			_line(eye, aim_w, Color(0.15, 0.95, 1.0))
		var nav_g: Vector3 = dbg["nav_goal"]
		if nav_g.distance_squared_to(bp) > 0.5:
			_line(bp + Vector3(0.0, 0.4, 0.0), nav_g + Vector3(0.0, 0.4, 0.0), Color(0.25, 0.95, 0.35))
		var dd: Vector3 = dbg["dodge_dir"]
		if dd.length_squared() > 0.01:
			_line(bp + Vector3(0.0, 4.0, 0.0), bp + Vector3(0.0, 4.0, 0.0) + dd.normalized() * 8.0, Color(1.0, 0.2, 0.85))
		var rg: Vector3 = dbg.get("roof_goal", Vector3(NAN, NAN, NAN))
		if not is_nan(rg.x):
			_line(bp + Vector3(0.0, 4.0, 0.0), rg, Color(1.0, 0.82, 0.15))
			_draw_circle(rg + Vector3(0.0, 0.25, 0.0), 2.5, Color(1.0, 0.82, 0.15))
	_debug_mesh.surface_end()


func _line(a: Vector3, b: Vector3, col: Color) -> void:
	_debug_mesh.surface_set_color(col)
	_debug_mesh.surface_add_vertex(a)
	_debug_mesh.surface_add_vertex(b)


func _draw_circle(c: Vector3, r: float, col: Color, segs: int = 12) -> void:
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		_line(c + Vector3(cos(a0) * r, 0.0, sin(a0) * r), c + Vector3(cos(a1) * r, 0.0, sin(a1) * r), col)


# --- Lab contract -----------------------------------------------------------------------------------------

func lab_params() -> Array:
	var vals := {
		"telegraph_scale": telegraph_scale, "attack_slots": attack_slots,
		"enemy_speed_scale": enemy_speed_scale, "hp_scale": hp_scale, "sight_range": sight_range,
	}
	var out: Array = []
	for p: Array in PARAMS:
		out.append({"id": p[0], "label": p[1], "min": p[2], "max": p[3], "value": float(vals[p[0]])})
	return out


func set_lab_param(id: String, v: float) -> void:
	match id:
		"telegraph_scale": telegraph_scale = v
		"attack_slots": attack_slots = v
		"enemy_speed_scale": enemy_speed_scale = v
		"hp_scale":
			hp_scale = v
			_rebuild()
			return
		"sight_range": sight_range = v
	_sync_params()


func lab_options() -> Array:
	return [
		{"id": "preset", "label": "Preset", "choices": PRESETS, "value": preset},
		{"id": "ai_mode", "label": "AI mode", "choices": AI_MODES, "value": ai_mode},
		{"id": "target_mode", "label": "Target bot", "choices": TARGET_MODES, "value": target_mode},
		{"id": "debug_overlay", "label": "Debug overlay", "choices": DEBUG_MODES, "value": debug_overlay},
	]


func set_lab_option(id: String, v: String) -> void:
	match id:
		"preset":
			if v in PRESETS:
				preset = v
				_rebuild()
		"ai_mode":
			if v in AI_MODES:
				ai_mode = v
				_sync_params()
		"target_mode":
			if v in TARGET_MODES and v != target_mode:
				var was_bot := target_mode.begins_with("bot_")
				var now_bot := v.begins_with("bot_")
				target_mode = v
				if preset != "showcase" and (was_bot or now_bot):
					_spawn_player_target()
		"debug_overlay":
			if v in DEBUG_MODES:
				debug_overlay = v


func lab_focus() -> Vector3:
	if preset == "showcase":
		return Vector3(2.0, 3.0, 0.0)
	return Vector3(2.0, 4.0, -24.0)


func lab_radius() -> float:
	return 24.0 if preset == "showcase" else 42.0
