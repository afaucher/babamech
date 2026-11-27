class_name BalanceScenarios
extends RefCounted
## Standardized combat balance scenarios and fast deterministic headless runner (docs/design/player-ai.md §4).
## Builds real MechSpawn + WeaponRack + PlayerTarget + EnemySquad + CityDistrict/arena static colliders
## and advances synchronously at DT = 1/60 s for <15 s full-matrix execution.

const DT := 1.0 / 60.0

const DUEL_IDS := ["duel_turret", "duel_strider", "duel_tank_street", "duel_tank_rooftop"]
const POCKET_IDS := ["pocket_vanguard", "pocket_crossfire", "pocket_cover_siege"]
const CITY_IDS := ["city_solo"]
const COOP_IDS := ["city_coop_2p", "city_coop_4p"]


static func tier_of(scenario_id: String) -> String:
	if scenario_id in DUEL_IDS:
		return "duel"
	if scenario_id in POCKET_IDS:
		return "pocket"
	if scenario_id in COOP_IDS:
		return "coop"
	return "city"


static func crew_count_of(scenario_id: String) -> int:
	if scenario_id == "city_coop_2p":
		return 2
	if scenario_id == "city_coop_4p":
		return 4
	return 1


static func crew_profiles_for(prof: String, crew: int) -> Array[String]:
	if crew <= 1:
		return [prof]
	if prof == "mixed":
		if crew == 2:
			return ["average", "brawler"]
		return ["rookie", "average", "veteran", "brawler"]
	var out: Array[String] = []
	for _i in crew:
		out.append(prof)
	return out


## Build the ordered list of run specs [{scenario, profile, seed, loadout, overrides}] for a suite preset.
static func build_suite(suite: String, profiles_filter: Array[String] = [], seeds: Array[int] = [],
		loadout_override: String = "", overrides: Dictionary = {}) -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	var city_seeds: Array[int] = []
	if not seeds.is_empty():
		city_seeds = seeds
	elif suite in ["quick", "coop"]:
		city_seeds = [1, 2, 3]
	else:
		city_seeds = [1, 2, 3, 4, 5]

	match suite:
		"duels":
			var profs := profiles_filter if not profiles_filter.is_empty() else (["rookie", "average", "veteran"] as Array[String])
			for sc in DUEL_IDS:
				for p in profs:
					specs.append(_spec(sc, p, 101, loadout_override, overrides))
		"pockets":
			var profs := profiles_filter if not profiles_filter.is_empty() else (["rookie", "average", "veteran", "brawler"] as Array[String])
			for sc in POCKET_IDS:
				for p in profs:
					specs.append(_spec(sc, p, 202, loadout_override, overrides))
		"city":
			var profs := profiles_filter if not profiles_filter.is_empty() else (["average", "veteran"] as Array[String])
			for p in profs:
				for sd in city_seeds:
					specs.append(_spec("city_solo", p, sd, loadout_override, overrides))
		"coop":
			var profs := profiles_filter if not profiles_filter.is_empty() else (["average", "mixed", "veteran"] as Array[String])
			for sc in COOP_IDS:
				for p in profs:
					for sd in city_seeds:
						specs.append(_spec(sc, p, sd, loadout_override, overrides))
		"full":
			var profs := profiles_filter if not profiles_filter.is_empty() else BotProfile.PROFILE_ORDER.duplicate()
			for sc in DUEL_IDS + POCKET_IDS:
				for p in profs:
					specs.append(_spec(sc, p, 101, loadout_override, overrides))
			for p in profs:
				for sd in city_seeds:
					specs.append(_spec("city_solo", p, sd, loadout_override, overrides))
			var coop_profs := profiles_filter if not profiles_filter.is_empty() else (["average", "mixed", "veteran"] as Array[String])
			for sc in COOP_IDS:
				for p in coop_profs:
					for sd in [1, 2, 3]:
						specs.append(_spec(sc, p, sd, loadout_override, overrides))
		_:  # "quick" (default < 15 s)
			var duel_profs := profiles_filter if not profiles_filter.is_empty() else (["rookie", "average", "veteran"] as Array[String])
			var pocket_profs := profiles_filter if not profiles_filter.is_empty() else (["average", "veteran", "brawler"] as Array[String])
			var city_profs := profiles_filter if not profiles_filter.is_empty() else (["average", "veteran"] as Array[String])
			for sc in DUEL_IDS:
				for p in duel_profs:
					specs.append(_spec(sc, p, 101, loadout_override, overrides))
			for sc in ["pocket_vanguard", "pocket_crossfire"]:
				for p in pocket_profs:
					specs.append(_spec(sc, p, 202, loadout_override, overrides))
			for p in city_profs:
				for sd in city_seeds:
					specs.append(_spec("city_solo", p, sd, loadout_override, overrides))
	return specs


static func _spec(sc: String, prof: String, sd: int, loadout_override: String, overrides: Dictionary) -> Dictionary:
	return {
		"scenario": sc,
		"profile": prof,
		"seed": sd,
		"loadout": loadout_override,
		"overrides": overrides,
	}


## Parse CLI override string like "enemy_bolter.damage=28,turret.base_hp=120,tank.hp_scale=0.85".
static func parse_overrides(raw: String) -> Dictionary:
	var out := {}
	if raw.strip_edges() == "":
		return out
	for tok: String in raw.split(","):
		var s := tok.strip_edges()
		var eq_i := s.find("=")
		if eq_i <= 0:
			continue
		var k := s.substr(0, eq_i).strip_edges()
		var v_str := s.substr(eq_i + 1).strip_edges()
		if v_str.is_valid_float():
			out[k] = float(v_str)
	return out


## Execute one complete deterministic real-physics scenario and return finalized BotMetrics.
static func run_scenario(host: Node, spec: Dictionary) -> Dictionary:
	var sc_id := str(spec.get("scenario", "duel_turret"))
	var prof := str(spec.get("profile", "average"))
	var sd := int(spec.get("seed", 1))
	var loadout_override := str(spec.get("loadout", ""))
	var overrides: Dictionary = spec.get("overrides", {})
	var tier := tier_of(sc_id)
	var crew := crew_count_of(sc_id)
	var crew_profs := crew_profiles_for(prof, crew)

	var root := Node3D.new()
	root.name = "Sim_%s_%s_%d" % [sc_id, prof, sd]
	host.add_child(root)

	var world := CombatWorld.new()
	world.name = "CombatWorld"
	world.mission_seed = sd
	world.use_physics = true
	_apply_weapon_overrides(world, overrides)
	root.add_child(world)

	var squad := EnemySquad.new()
	squad.name = "EnemySquad"
	root.add_child(squad)

	var city: CityDistrict = null
	var plan: CityPlan = null
	var ring: RingFrame = null
	var arena_roofs: Array[Dictionary] = []
	var player_xfs: Array[Transform3D] = []
	var max_s := 60.0

	if sc_id in ["city_solo", "city_coop_2p", "city_coop_4p"]:
		city = CityDistrict.new()
		city.name = "City"
		city.with_rig = false
		city.with_backdrop = false
		root.add_child(city)
		city.build({"seed": float(sd), "walls": 1.0})
		plan = city.plan
		ring = city.ring
		var center_spawn := ring.arc_to_world(0.0, 12.0, CityPlan.CURB_H + 0.3)
		var offsets: Array[Vector2] = [Vector2(0.0, 12.0)]
		if crew == 2:
			offsets = [Vector2(-5.5, 12.0), Vector2(5.5, 12.0)]
		elif crew == 4:
			offsets = [Vector2(-5.5, 12.0), Vector2(5.5, 12.0), Vector2(-5.5, 3.0), Vector2(5.5, 3.0)]
		for off: Vector2 in offsets:
			player_xfs.append(Transform3D(ring.basis_at_arc(off.y), ring.arc_to_world(off.x, off.y, CityPlan.CURB_H + 0.3)))
		if crew == 1:
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			max_s = 150.0
		elif crew == 2:
			squad.max_attackers = 2
			squad.slot_stagger = 0.35
			max_s = 130.0
		else:
			squad.max_attackers = 3
			squad.slot_stagger = 0.25
			max_s = 120.0
		squad.setup(world, plan, ring)
		EnemySpawner.spawn_all(plan, ring, center_spawn, world, squad, sd, false, crew)
	else:
		squad.setup(world, null, null)
		var arena_info := _build_flat_scenario(root, world, squad, sc_id, sd)
		arena_roofs = arena_info["roofs"]
		player_xfs = [arena_info["player_xf"] as Transform3D]
		max_s = float(arena_info["max_s"])

	# Apply any per-enemy HP overrides cleanly without mutating EnemyCatalog constants.
	_apply_enemy_overrides(squad, overrides)

	var bot_squad: PlayerBotSquad = null
	if crew > 1:
		bot_squad = PlayerBotSquad.new()
		bot_squad.name = "PlayerBotSquad"
		var bias := 0.78 if prof == "veteran" else (0.50 if prof == "mixed" else 0.62)
		bot_squad.setup(world, bias)
		root.add_child(bot_squad)

	# Build real player mech stack(s): MechSpawn + PlayerTarget + WeaponRack + PlayerBot.
	var heads := ["chicken", "pickle", "corn", "dog"]
	var mechs: Array[MechController] = []
	var rigs: Array[MechRig] = []
	var targets: Array[PlayerTarget] = []
	var racks: Array[WeaponRack] = []
	var bots: Array[PlayerBot] = []
	var primary_loadout_name := loadout_override if loadout_override != "" else str(BotProfile.get_profile(crew_profs[0]).get("loadout", "default"))

	for ci in crew:
		var cprof := crew_profs[ci]
		var cloadout_name := loadout_override if loadout_override != "" else str(BotProfile.get_profile(cprof).get("loadout", "default"))
		var cloadout := BotProfile.get_loadout(cloadout_name)
		# Optional spec keys (tools/balance/chassis_compare.gd): "chassis" (default strider), "loadout_dict" (an explicit
		# loadout, over the named one), "on_spawn" Callable(mech, rack, target) after the stack binds (what-if tweaks),
		# "on_step" Callable(dt, mechs, racks, targets, bots) after each step's metrics sample.
		var chassis_id := str(spec.get("chassis", "strider"))
		if spec.has("loadout_dict"):
			cloadout = (spec["loadout_dict"] as Dictionary).duplicate()
		var pid := "player%d" % (ci + 1)
		var bid := "bot%d" % (ci + 1)

		var mech := MechSpawn.make(heads[ci % heads.size()], chassis_id, cloadout)
		mech.name = "Mech_%d" % (ci + 1)
		mech.ring = ring
		root.add_child(mech)
		mech.global_transform = player_xfs[ci]
		var rig := MechSpawn.rig_of(mech)

		var pt := PlayerTarget.new()
		pt.name = "PlayerTarget_%d" % (ci + 1)
		pt.auto_respawn_delay = -1.0    # record defeat cleanly instead of respawning
		root.add_child(pt)
		pt.bind(world, mech, rig.model, pid, 1)
		world.register(pt)

		var rack := WeaponRack.new()
		rack.name = "WeaponRack_%d" % (ci + 1)
		rack.auto_step = false
		rack.read_input = false
		rack.manual_aim = true
		rack.slot_disabled = pt.is_slot_destroyed
		root.add_child(rack)
		rack.bind(world, mech, rig.model, null, pid, 1)

		var bot := PlayerBot.new()
		bot.name = "PlayerBot_%d" % (ci + 1)
		bot.auto_step = false
		bot.configure(cprof, sd + ci * 17, bid)
		root.add_child(bot)
		bot.bind(mech, rack, pt, world, squad, plan, ring, null)
		if not arena_roofs.is_empty():
			bot.set_arena_roofs(arena_roofs)
		if bot_squad != null:
			bot_squad.add_bot(bot)
		if spec.get("on_spawn") is Callable and (spec["on_spawn"] as Callable).is_valid():
			(spec["on_spawn"] as Callable).call(mech, rack, pt)

		# Disable automatic _physics_process so our tight deterministic loop controls exact step order & speed.
		mech.set_physics_process(false)
		rig.set_physics_process(false)
		var ma := mech.get_node_or_null("Audio")
		if ma != null:
			ma.set_physics_process(false)
		var tfx := mech.get_node_or_null("Thrusters")
		if tfx != null:
			tfx.set_physics_process(false)

		mechs.append(mech)
		rigs.append(rig)
		targets.append(pt)
		racks.append(rack)
		bots.append(bot)

	# Let PhysicsServer3D register all StaticBody3D colliders and run mech _ready() cleanly.
	var tree := host.get_tree()
	await tree.physics_frame
	await tree.physics_frame
	for ci in crew:
		mechs[ci].global_transform = player_xfs[ci]
		mechs[ci].velocity = Vector3.ZERO
		rigs[ci].gait.reset([])
		rigs[ci].update_pose(DT)
		targets[ci].tick(DT, world.space())

	var metrics := BotMetrics.new()
	metrics.bind(sc_id, tier, prof, sd, primary_loadout_name, world, squad, null, null, null, null, ring)
	for ci in crew:
		metrics.add_player(targets[ci], mechs[ci], racks[ci], bots[ci])

	var steps := int(ceil(max_s / DT))
	var on_step: Callable = spec["on_step"] if spec.get("on_step") is Callable else Callable()
	var won := false
	var end_reason := "timeout"
	var sim_t := 0.0
	for _i in steps:
		sim_t += DT
		if bot_squad != null:
			bot_squad.step_coordination(sim_t)
		for ci in crew:
			bots[ci].step(DT)
		for ci in crew:
			mechs[ci].step(DT)
		for ci in crew:
			rigs[ci].update_pose(DT)
		for ci in crew:
			racks[ci].step(DT)
		world.advance(DT)
		metrics.sample(DT)
		if on_step.is_valid():
			on_step.call(DT, mechs, racks, targets, bots)

		var any_alive := false
		for pt: PlayerTarget in targets:
			if not pt.disabled:
				any_alive = true
				break
		if not any_alive:
			won = false
			end_reason = "disabled"
			break
		if squad.alive_count() == 0:
			won = true
			end_reason = "cleared"
			break

	var result := metrics.finalize(won, end_reason)
	if bot_squad != null:
		result["callouts_posted"] = bot_squad.callouts_posted
	result["verdict"] = BalanceVerdict.evaluate_row(result)

	# Tear down cleanly so memory and PhysicsServer3D stay lean across long sweeps.
	root.queue_free()
	await tree.process_frame
	return result


static func _build_flat_scenario(root: Node3D, world: CombatWorld, squad: EnemySquad, sc_id: String, sd: int) -> Dictionary:
	# Paved arena floor slab.
	_add_block(root, Vector3(220.0, 1.0, 220.0), Vector3(0.0, -0.5, -35.0), Color(0.28, 0.29, 0.31))
	var roofs: Array[Dictionary] = []
	var player_xf := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
	var max_s := 55.0

	match sc_id:
		"duel_turret":
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			_add_block(root, Vector3(7.0, 5.5, 3.0), Vector3(-16.0, 2.75, -24.0), Color(0.65, 0.42, 0.34))
			_spawn_enemy(world, squad, "turret", "duel_turret_1", Vector3(0.0, 0.0, -50.0), PI, sd + 1)
			max_s = 45.0

		"duel_strider":
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			var s := _spawn_enemy(world, squad, "strider", "duel_strider_1", Vector3(0.0, 0.0, -45.0), PI, sd + 2)
			s.set_patrol_points([Vector2(-14.0, -42.0), Vector2(14.0, -42.0)])
			max_s = 45.0

		"duel_tank_street":
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			_add_block(root, Vector3(9.0, 6.5, 4.0), Vector3(-18.0, 3.25, -30.0), Color(0.65, 0.42, 0.34))
			_spawn_enemy(world, squad, "tank", "duel_tank_1", Vector3(0.0, 0.0, -60.0), PI, sd + 3)
			max_s = 65.0

		"duel_tank_rooftop":
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			# Jumpable 9 m flanking rooftop perch beside spawn: from street the tank faces +Z so hull/turret occlude
			# its rear vents; climbing the 9 m roof at (20, 9, -26) exposes the rear vents cleanly from above!
			_add_block(root, Vector3(14.0, 9.0, 14.0), Vector3(20.0, 4.5, -26.0), Color(0.82, 0.78, 0.70))
			roofs.append({"center": Vector3(20.0, 9.0, -26.0), "size": Vector2(14.0, 14.0), "roof_h": 9.0})
			player_xf = Transform3D(Basis.IDENTITY, Vector3(10.0, 0.0, -10.0))
			_spawn_enemy(world, squad, "tank", "duel_tank_roof_1", Vector3(0.0, 0.0, -52.0), PI, sd + 4)
			max_s = 65.0

		"pocket_vanguard":
			squad.max_attackers = 1
			squad.slot_stagger = 0.85
			_add_block(root, Vector3(14.0, 9.0, 14.0), Vector3(-20.0, 4.5, -38.0), Color(0.82, 0.78, 0.70))
			_add_block(root, Vector3(10.0, 6.0, 3.0), Vector3(0.0, 3.0, -18.0), Color(0.65, 0.42, 0.34))
			roofs.append({"center": Vector3(-20.0, 9.0, -38.0), "size": Vector2(14.0, 14.0), "roof_h": 9.0})
			_spawn_enemy(world, squad, "turret", "van_turret_1", Vector3(-20.0, 9.0, -38.0), PI, sd + 11)
			var sk := _spawn_enemy(world, squad, "strider", "van_strider_1", Vector3(10.0, 0.0, -36.0), PI, sd + 12)
			sk.set_patrol_points([Vector2(14.0, -30.0), Vector2(-6.0, -32.0)])
			max_s = 75.0

		"pocket_crossfire":
			squad.max_attackers = 2
			squad.slot_stagger = 0.80
			# Mirrors EnemyLab's skirmish yard geometry.
			_add_block(root, Vector3(14.0, 9.0, 14.0), Vector3(-22.0, 4.5, -38.0), Color(0.82, 0.78, 0.70))
			_add_block(root, Vector3(10.0, 6.0, 3.0), Vector3(0.0, 3.0, -16.0), Color(0.65, 0.42, 0.34))
			_add_block(root, Vector3(8.0, 7.5, 8.0), Vector3(22.0, 3.75, -34.0), Color(0.45, 0.56, 0.46))
			roofs.append({"center": Vector3(22.0, 7.5, -34.0), "size": Vector2(8.0, 8.0), "roof_h": 7.5})
			_spawn_enemy(world, squad, "turret", "xf_turret_1", Vector3(-22.0, 9.0, -38.0), PI, sd + 21)
			var s1 := _spawn_enemy(world, squad, "strider", "xf_strider_1", Vector3(-9.0, 0.0, -34.0), PI, sd + 22)
			s1.set_patrol_points([Vector2(-12.0, -30.0), Vector2(10.0, -30.0)])
			var s2 := _spawn_enemy(world, squad, "strider", "xf_strider_2", Vector3(12.0, 0.0, -30.0), PI, sd + 23)
			s2.set_patrol_points([Vector2(14.0, -24.0), Vector2(-6.0, -40.0)])
			_spawn_enemy(world, squad, "tank", "xf_tank_1", Vector3(2.0, 0.0, -48.0), PI, sd + 24)
			max_s = 110.0

		"pocket_cover_siege":
			squad.max_attackers = 2
			squad.slot_stagger = 0.80
			_add_block(root, Vector3(12.0, 7.5, 8.0), Vector3(-13.0, 3.75, -24.0), Color(0.65, 0.42, 0.34))
			_add_block(root, Vector3(12.0, 7.5, 8.0), Vector3(13.0, 3.75, -24.0), Color(0.45, 0.56, 0.46))
			roofs.append({"center": Vector3(-13.0, 7.5, -24.0), "size": Vector2(12.0, 8.0), "roof_h": 7.5})
			roofs.append({"center": Vector3(13.0, 7.5, -24.0), "size": Vector2(12.0, 8.0), "roof_h": 7.5})
			_spawn_enemy(world, squad, "tank", "cs_tank_1", Vector3(0.0, 0.0, -58.0), PI, sd + 31)
			var s3 := _spawn_enemy(world, squad, "strider", "cs_strider_1", Vector3(14.0, 0.0, -44.0), PI, sd + 32)
			s3.set_patrol_points([Vector2(16.0, -38.0), Vector2(-14.0, -42.0)])
			max_s = 90.0

	return {"roofs": roofs, "player_xf": player_xf, "max_s": max_s}


static func _spawn_enemy(world: CombatWorld, squad: EnemySquad, type_id: String, id: String,
		pos: Vector3, yaw: float, sd: int) -> EnemyBase:
	var e := EnemySpawner.make_enemy(type_id)
	e.configure(type_id, id, world, squad, null, sd, 1.0)
	e.auto_remove_wreck = false
	e.position = pos
	e.rotation.y = yaw
	squad.add_enemy(e)
	return e


static func _add_block(parent: Node3D, size: Vector3, at: Vector3, col: Color) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.set_meta("surface_color", col)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)


static func _apply_weapon_overrides(world: CombatWorld, overrides: Dictionary) -> void:
	for k: String in overrides:
		var parts := k.split(".")
		if parts.size() != 2:
			continue
		var target_id := parts[0]
		var stat := parts[1]
		if MechCatalog.WEAPONS.has(target_id) or EnemyCatalog.WEAPONS.has(target_id):
			if not world.overrides.has(target_id):
				world.overrides[target_id] = {}
			(world.overrides[target_id] as Dictionary)[stat] = float(overrides[k])


static func _apply_enemy_overrides(squad: EnemySquad, overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	for e: EnemyBase in squad.enemies:
		var prefix := e.enemy_type + "."
		var hp_scale_ov := float(overrides.get(prefix + "hp_scale", overrides.get("enemy.hp_scale", 1.0)))
		var tele_ov := float(overrides.get(prefix + "telegraph_scale", overrides.get("enemy.telegraph_scale", 1.0)))
		if tele_ov != 1.0:
			e.telegraph_scale = tele_ov
		var changed_hp := false
		var caps := e.max_hp.duplicate()
		if hp_scale_ov != 1.0:
			for c: String in caps:
				caps[c] = float(caps[c]) * hp_scale_ov
			changed_hp = true
		for c: String in caps.keys():
			var ck := prefix + c + "_hp"
			if overrides.has(ck):
				caps[c] = float(overrides[ck])
				changed_hp = true
		if changed_hp:
			e.set_max_hp(caps)
