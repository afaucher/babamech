extends TestCase
## Real-physics enemy effectiveness & anti-bug audit (use_physics = true, real CityDistrict geometry):
##   1. Predictable straight walker vs. evasive dodger (proves velocity lead threatens lazy walking while dodges work).
##   2. True LKP memory, cover-flushing mortar & anti-wallhack in a real CityDistrict (proves zero wallhack behind walls).
##   3. Multi-seed spawn clearance across 15 city seeds + 3 live 12 s physics patrol audits (zero clipping, no stuck units).
##   4. Real-weapon ballistic TTK & rooftop weak-point hit-sphere verification through WeaponRack.

const DT := 1.0 / 60.0


func setup() -> void:
	await _spawn_calmness_and_pocket_isolation()
	await _dodge_vs_straight_benchmark()
	await _lkp_mortar_and_anti_wallhack()
	await _multi_seed_spawn_and_patrol_audit()
	await _real_weapon_ttk_and_rooftop_vents()
	finish()


# --- 0. Spawn Calmness & Pocket Isolation (Real TestDrive) ------------------------------------------------

func _spawn_calmness_and_pocket_isolation() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	td.drive_override = true
	await frames(2)
	var enemy_shots := [0]
	td.combat.world.fired.connect(func(rec: Dictionary) -> void:
		if bool(rec.get("enemy", false)):
			enemy_shots[0] += 1)
	var hp0 := td.combat.player_target.total_hp()
	# Stand at spawn for 3.0 s: zero enemies should shoot at you on frame 0!
	for _i in 180:
		td.combat.world.advance(DT)
	eq(enemy_shots[0], 0, "standing at Test Drive spawn for 3 s draws 0 enemy shots")
	near(td.combat.player_target.total_hp(), hp0, 0.01, "player takes 0 damage on spawn")
	var entry_k := int(td.stack.section.entry["deck"]) if td.stack != null else 0
	var on_entry := td.combat.enemies.filter(func(e: EnemyBase) -> bool: return e.spawn_deck == entry_k)
	check(on_entry.size() >= 5 and on_entry.size() <= 7,
		"Test Drive spawns 5-7 spaced enemies on the entry deck (%d; every deck has its own encounter)" % on_entry.size())

	# Alerting the avenue scout (enemies[0]) must NOT pull distant pockets (> 80 m away).
	var scout := td.combat.enemies[0]
	scout.apply_damage(10.0, "chassis", "player1")
	for _i in 50:   # past 0.45 s comm relay
		td.combat.world.advance(DT)
	check(scout.is_alerted(), "shooting the avenue scout alerts it")
	var far_checked := 0
	var far_alerted := 0
	for e in td.combat.enemies:
		if e == scout:
			continue
		if e.global_position.distance_to(scout.global_position) > 80.0:
			far_checked += 1
			if e.is_alerted():
				far_alerted += 1
	check(far_checked >= 1 and far_alerted == 0,
		"distant pockets stay unalerted when engaging avenue scout (%d/%d far alerted)" % [far_alerted, far_checked])
	td.queue_free()
	await frames(2)


# --- 1. Careless Slow Target vs. Evasive Dodger -----------------------------------------------------------

func _dodge_vs_straight_benchmark() -> void:
	var careless := await _run_dodge_trial(false)
	var evasive := await _run_dodge_trial(true)
	print("[effectiveness] careless slow target: %d hits, %.1f dmg | evasive dodger: %d hits, %.1f dmg" % [
		careless["hits"], careless["dmg"], evasive["hits"], evasive["dmg"]])
	check(int(careless["hits"]) >= 2 and float(careless["dmg"]) >= 80.0,
		"enemy shots hit hard when you don't dodge (%d hits, %.1f dmg)" % [careless["hits"], careless["dmg"]])
	check(float(evasive["dmg"]) < float(careless["dmg"]) * 0.35,
		"active strafing + telegraph dodge avoids most fire (%.1f vs %.1f)" % [evasive["dmg"], careless["dmg"]])


func _run_dodge_trial(evasive: bool) -> Dictionary:
	var w := CombatWorld.new()
	w.mission_seed = 101
	w.use_physics = true
	add_child(w)
	# Real ground slab so physics raycasts & splash work identically to gameplay.
	var floor_b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(260.0, 1.0, 160.0)
	cs.shape = box
	floor_b.add_child(cs)
	floor_b.position = Vector3(0.0, -0.5, -30.0)
	add_child(floor_b)

	var sq := EnemySquad.new()
	sq.max_attackers = 2
	add_child(sq)
	sq.setup(w)

	var turret := EnemyTurret.new()
	turret.configure("turret", "bench_turret", w, sq, null, 1)
	turret.position = Vector3(-8.0, 0.0, -48.0)
	turret.rotation.y = PI
	sq.add_enemy(turret)

	var tank := EnemyTank.new()
	tank.configure("tank", "bench_tank", w, sq, null, 2)
	tank.position = Vector3(12.0, 0.0, -56.0)
	tank.rotation.y = PI
	sq.add_enemy(tank)

	var mech := MechController.new()
	mech.position = Vector3(-18.0 if not evasive else -35.0, 0.0, 0.0)
	add_child(mech)
	var pt := PlayerTarget.new()
	add_child(pt)
	pt.bind(w, mech, null, "player1", 1)
	pt.set_max_hp({"torso": 10000.0, "leg_l": 10000.0, "leg_r": 10000.0, "head": 10000.0})
	pt.auto_respawn_delay = -1.0
	w.register(pt)

	var hits := [0]
	var dmg := [0.0]
	pt.damaged.connect(func(amount: float, _c: String, _s: String) -> void:
		hits[0] += 1
		dmg[0] += amount)

	var dir := [1.0]
	var dodge_delay := [-1.0]
	if evasive:
		sq.enemy_event.connect(func(kind: String, _e: Node, _p: Dictionary) -> void:
			if kind == "telegraph_started" and dodge_delay[0] < 0.0:
				dodge_delay[0] = 0.16)   # realistic player reaction time

	await frames(2)
	for _i in 660:   # 11.0 s of live combat
		if evasive and dodge_delay[0] >= 0.0:
			dodge_delay[0] -= DT
			if dodge_delay[0] <= 0.0:
				dodge_delay[0] = -1.0
				dir[0] = -dir[0]
		var move_spd := 12.0 if evasive else 1.2
		if mech.position.x > 45.0:
			dir[0] = -1.0
		elif mech.position.x < -45.0:
			dir[0] = 1.0
		var v := Vector3(dir[0] * move_spd, 0.0, 0.0)
		mech.velocity = v
		mech.global_position += v * DT
		w.advance(DT)

	pt.queue_free()
	mech.queue_free()
	sq.queue_free()
	floor_b.queue_free()
	w.queue_free()
	await frames(1)
	return {"hits": hits[0], "dmg": dmg[0]}


# --- 2. True LKP, Cover-Flush Mortar & Anti-Wallhack (Real CityDistrict, use_physics = true) --------------

func _lkp_mortar_and_anti_wallhack() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 1.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring
	await frames(2)

	# Pick a real avenue-facing building tall enough (>= 9 m) to completely block LOS behind it.
	var cover_b := {}
	for b: Dictionary in plan.buildings:
		if bool(b.get("pillar", false)):
			continue
		var c: Vector2 = b["center"]
		var sz: Vector2 = b["size"]
		if absf(c.x) < 34.0 and absf(c.x) > 12.0 and c.y > 0.0 and c.y < 70.0 and float(b["roof_h"]) >= 9.0 and minf(sz.x, sz.y) >= 10.0:
			cover_b = b
			break
	if not check(not cover_b.is_empty(), "found a real avenue-facing building for LOS cover test"):
		city.queue_free()
		return

	var bc: Vector2 = cover_b["center"]
	var bsz: Vector2 = cover_b["size"]
	var side_sign := 1.0 if bc.x > 0.0 else -1.0
	# Visible spot on the avenue in front of the building, hidden spot tucked behind the far side of that building,
	# and a distant silent-relocate spot 48 m farther away on the far side of the block!
	var visible_arc := Vector2(0.0, bc.y)
	var behind_arc := Vector2(bc.x + side_sign * (bsz.x * 0.5 + 4.5), bc.y)
	var relocate_arc := Vector2(bc.x + side_sign * (bsz.x * 0.5 + 5.5), bc.y - 48.0)
	var enemy_tank_arc := Vector2(0.0, bc.y - 54.0)
	var enemy_skirm_arc := Vector2(-side_sign * 4.0, bc.y - 36.0)

	# Case A: Cover-camper stays behind the wall -> Tank lobs enemy_mortar at LKP & Skirmisher advances!
	var res_a := await _run_lkp_case(plan, ring, visible_arc, behind_arc, behind_arc, enemy_tank_arc, enemy_skirm_arc)
	print("[effectiveness] LKP Case A (cover camper): mortar_fired=%s err_to_lkp=%.1f m, skirm_move=%.1f m" % [
		res_a["mortar_fired"], res_a["mortar_err_lkp"], res_a["skirm_move"]])
	check(bool(res_a["lost_los"]), "real building wall blocked enemy LOS")
	check(bool(res_a["mortar_fired"]), "Tank fired cover-flushing enemy_mortar when player hid behind building")
	check(float(res_a["mortar_err_lkp"]) < 8.0, "flush mortar targeted the LKP (err %.1f m)" % res_a["mortar_err_lkp"])
	check(float(res_a["skirm_move"]) >= 8.0, "Skirmisher moved toward LKP around city blocks (%.1f m)" % res_a["skirm_move"])

	# Case B: Silent relocator breaks LOS and moves 48 m away -> mortar aims at OLD LKP, NOT new live pos!
	var res_b := await _run_lkp_case(plan, ring, visible_arc, behind_arc, relocate_arc, enemy_tank_arc, enemy_skirm_arc)
	print("[effectiveness] LKP Case B (relocator): mortar_fired=%s err_old_lkp=%.1f m, dist_to_new_pos=%.1f m, lkp_drift=%.2f m" % [
		res_b["mortar_fired"], res_b["mortar_err_lkp"], res_b["mortar_dist_new"], res_b["lkp_drift"]])
	check(bool(res_b["mortar_fired"]), "Tank still fired flush mortar on Case B")
	check(float(res_b["lkp_drift"]) < 1.0, "shared target board LKP stayed frozen while out of LOS (drift %.2f m)" % res_b["lkp_drift"])
	check(float(res_b["mortar_err_lkp"]) < 8.0 and float(res_b["mortar_dist_new"]) > 28.0,
		"anti-wallhack: mortar hit old LKP (%.1f m) not new hidden position (%.1f m)" % [res_b["mortar_err_lkp"], res_b["mortar_dist_new"]])

	city.queue_free()
	await frames(1)


func _run_lkp_case(plan: CityPlan, ring: RingFrame, vis_arc: Vector2, hide_arc: Vector2,
		final_arc: Vector2, tank_arc: Vector2, skirm_arc: Vector2) -> Dictionary:
	var w := CombatWorld.new()
	w.mission_seed = 55
	w.use_physics = true
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)

	var tank := EnemyTank.new()
	tank.configure("tank", "lkp_tank", w, sq, ring, 1)
	var tp := ring.arc_to_world(tank_arc.x, tank_arc.y, 0.0)
	tank.up = ring.up_at(tp)
	tank.transform = Transform3D(ring.basis_at_arc(tank_arc.y), tp)
	sq.add_enemy(tank)

	var skirm := EnemyStrider.new()
	skirm.configure("strider", "lkp_skirm", w, sq, ring, 2)
	var sp := ring.arc_to_world(skirm_arc.x, skirm_arc.y, 0.0)
	skirm.up = ring.up_at(sp)
	skirm.transform = Transform3D(ring.basis_at_arc(skirm_arc.y), sp)
	sq.add_enemy(skirm)

	var p := CombatTarget.new()
	p.target_id = "player1"
	p.owner_peer = 1
	p.team = "player"
	p.mass_class = "mech"
	p.set_max_hp({"torso": 10000.0})
	p.add_hit_sphere("torso", Vector3(0.0, 4.0, 0.0), 2.0)
	var vp := ring.arc_to_world(vis_arc.x, vis_arc.y, 0.0)
	p.up = ring.up_at(vp)
	p.transform = Transform3D(ring.basis_at_arc(vis_arc.y), vp)
	add_child(p)
	w.register(p)

	var mortar_target := [Vector3(NAN, NAN, NAN)]
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("weapon", "")) == "enemy_mortar" and is_nan(mortar_target[0].x):
			mortar_target[0] = rec["target"] as Vector3)

	await frames(2)
	# Phase 1: visible on avenue for 1.0 s -> both enemies spot & publish LKP to squad board.
	for _i in 65:
		w.advance(DT)
	var lkp0: Vector3 = sq.known_targets.get("player1", {}).get("pos", Vector3.ZERO)

	# Phase 2: duck behind building wall (and optionally silently relocate far behind another block).
	var hp_pos := ring.arc_to_world(hide_arc.x, hide_arc.y, CityPlan.CURB_H)
	p.transform = Transform3D(ring.basis_at_arc(hide_arc.y), hp_pos)
	w.advance(DT)
	var lost_los := (not tank._has_los) and (not skirm._has_los)

	var fin_pos := ring.arc_to_world(final_arc.x, final_arc.y, CityPlan.CURB_H)
	p.transform = Transform3D(ring.basis_at_arc(final_arc.y), fin_pos)
	var skirm_start := skirm.global_position
	var max_skirm_move := 0.0
	for _i in 480:   # 8.0 s out of LOS
		w.advance(DT)
		max_skirm_move = maxf(max_skirm_move, skirm.global_position.distance_to(skirm_start))

	var lkp_end: Vector3 = sq.known_targets.get("player1", {}).get("pos", lkp0)
	var mt: Vector3 = mortar_target[0]
	var fired := not is_nan(mt.x)
	var err_lkp := mt.distance_to(lkp0) if fired else INF
	var dist_new := mt.distance_to(fin_pos + p.up * 4.0) if fired else 0.0

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)
	return {
		"lost_los": lost_los, "mortar_fired": fired, "mortar_err_lkp": err_lkp,
		"mortar_dist_new": dist_new, "lkp_drift": lkp_end.distance_to(lkp0), "skirm_move": max_skirm_move,
	}


# --- 3. Multi-Seed Spawn Clearance (15 Seeds) & Live Physics Patrol Audit (3 Seeds) -----------------------

func _multi_seed_spawn_and_patrol_audit() -> void:
	var total_enemies := 0
	var seeds_clean := 0
	var max_ground_err := 0.0
	var patrol_max_moves: Array[float] = []

	for seed_i in range(1, 16):
		var city := CityDistrict.new()
		city.with_rig = false
		city.with_backdrop = false
		add_child(city)
		city.build({"seed": float(seed_i), "walls": 1.0})
		var plan := city.plan
		var ring := city.ring
		var spawn_p := ring.arc_to_world(0.0, 12.0, CityPlan.CURB_H + 0.3)

		var w := CombatWorld.new()
		w.mission_seed = seed_i
		w.use_physics = true
		add_child(w)
		var sq := EnemySquad.new()
		add_child(sq)
		sq.setup(w, plan, ring)
		var list := EnemySpawner.spawn_all(plan, ring, spawn_p, w, sq, seed_i, false)
		await frames(2)
		var sp := w.space()
		var seed_ok := list.size() >= 6 and list.size() <= 7
		total_enemies += list.size()

		for e in list:
			var arc := ring.world_to_arc(e.global_position)
			var d_spawn := Vector2(arc.x, arc.y).distance_to(Vector2(0.0, 12.0))
			var safe_r := EnemySpawner.DRONE_SAFE_RADIUS if e.enemy_type == "drone" else EnemySpawner.SPAWN_SAFE_RADIUS
			if d_spawn < safe_r - 0.1:
				seed_ok = false
				check(false, "seed %d %s too close to spawn (%.1f m)" % [seed_i, e.target_id, d_spawn])
			var clear_r := EnemySpawner.TURRET_CLEAR if e.enemy_type.begins_with("turret") else (
				EnemySpawner.TANK_CLEAR if e.enemy_type == "tank" else (
				EnemySpawner.DRONE_CLEAR if e.enemy_type == "drone" else (
				EnemySpawner.TROOP_CLEAR if e.enemy_type.begins_with("troop") else EnemySpawner.STRIDER_CLEAR)))
			if not EnemySpawner.clear_of_buildings(plan, Vector2(arc.x, arc.y), clear_r * 0.9, arc.z + 0.25):
				seed_ok = false
				check(false, "seed %d %s overlaps building/pillar at %s" % [seed_i, e.target_id, str(arc)])
			if e.enemy_type == "drone":
				if arc.z < 11.0 or arc.z > 22.0:
					seed_ok = false
					check(false, "seed %d %s drone altitude out of cruise band (%.1f m)" % [seed_i, e.target_id, arc.z])
			else:
				# Real physics ground / rooftop surface check.
				var u := ring.up_at(e.global_position)
				var q := PhysicsRayQueryParameters3D.create(e.global_position + u * 1.5, e.global_position - u * 4.0)
				var h := sp.intersect_ray(q)
				if h.is_empty():
					seed_ok = false
					check(false, "seed %d %s has no physics surface underneath" % [seed_i, e.target_id])
				else:
					var err := absf(((h["position"] as Vector3) - e.global_position).dot(u))
					max_ground_err = maxf(max_ground_err, err)
					if err > 1.0:
						seed_ok = false
						check(false, "seed %d %s ground mismatch %.2f m" % [seed_i, e.target_id, err])

		# Live 12 s physics patrol audit for seeds 1..3.
		if seed_i <= 3:
			var prev_pos := {}
			var path_dist := {}
			for e in list:
				prev_pos[e.target_id] = e.global_position
				path_dist[e.target_id] = 0.0
			for _t in 720:
				w.advance(DT)
				for e in list:
					var pnow := e.global_position
					path_dist[e.target_id] = float(path_dist[e.target_id]) + pnow.distance_to(prev_pos[e.target_id] as Vector3)
					prev_pos[e.target_id] = pnow
			var best_move := 0.0
			for e in list:
				var moved := float(path_dist[e.target_id])
				if not e.enemy_type.begins_with("turret"):
					best_move = maxf(best_move, moved)
				var up_dot := e.global_basis.y.dot(ring.up_at(e.global_position))
				check(up_dot > 0.97, "seed %d %s stays upright after 12 s patrol (dot=%.3f)" % [seed_i, e.target_id, up_dot])
			patrol_max_moves.append(best_move)
			check(best_move >= 25.0, "seed %d mobile patrol covered real ground (max %.1f m)" % [seed_i, best_move])

		if seed_ok:
			seeds_clean += 1
		sq.queue_free()
		w.queue_free()
		city.queue_free()
		await frames(1)

	print("[effectiveness] multi-seed audit: %d/15 seeds clean (%d enemies), max_ground_err=%.3f m, 12s patrol max moves=%s" % [
		seeds_clean, total_enemies, max_ground_err, str(patrol_max_moves)])
	eq(seeds_clean, 15, "all 15 city seeds spawned cleanly with zero building overlap and valid ground/roof support")


# --- 4. Real-Weapon Ballistic TTK & Rooftop Weak-Point Hit-Sphere Verification ----------------------------

func _real_weapon_ttk_and_rooftop_vents() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = true
	add_child(w)
	var floor_b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	cs.shape = box
	floor_b.add_child(cs)
	floor_b.position = Vector3(0.0, -0.5, -50.0)
	add_child(floor_b)

	var mech := MechController.new()
	add_child(mech)
	var model := MechModel.new()
	model.scale = Vector3.ONE * 2.0
	mech.add_child(model)
	model.configure("chicken", "strider", {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "mortar"})
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(w, mech, model, null, "player1", 1)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	await frames(2)

	# A. Real default Strider burst (laser + autocannon + rockets) vs Hound Skirmisher at 45 m.
	var sk := EnemyStrider.new()
	sk.configure("strider", "ttk_strider", w, sq, null, 1)
	sk.ai_mode = "idle"
	sk.position = Vector3(0.0, 0.0, -45.0)
	sq.add_enemy(sk)
	await frames(1)
	rack.set_enabled(1, true)
	rack.set_enabled(2, true)
	rack.set_enabled(3, true)
	rack.set_enabled(5, false)
	var sk_ttk := _fire_until_dead(w, rack, sk, "chassis", 4.0)
	check(sk.destroyed() and sk_ttk <= 2.5, "real default burst kills Skirmisher at 45 m cleanly (TTK %.2f s)" % sk_ttk)

	# A2. Single fresh Rocket Pod salvo (<= 6 rockets of 36 ammo) heavily damages or kills a Skirmisher at 45 m!
	mech.heat = 0.0
	mech.shutdown = false
	var r_mount: WeaponMount = rack.mounts[2]
	if r_mount != null:
		r_mount.cooldown = 0.0
		r_mount.salvo_left = 0
		r_mount.ammo = 36
	var sk_r := EnemyStrider.new()
	sk_r.configure("strider", "ttk_strider_rockets", w, sq, null, 4)
	sk_r.ai_mode = "idle"
	sk_r.position = Vector3(0.0, 0.0, -45.0)
	sq.add_enemy(sk_r)
	await frames(1)
	rack.set_enabled(1, false)
	rack.set_enabled(2, false)
	rack.set_enabled(3, true)   # Rocket Pod only
	rack.set_enabled(5, false)
	var ammo_before := int(rack.slots()[2]["ammo"])
	var skr_ttk := _fire_until_dead(w, rack, sk_r, "chassis", 2.2)
	var rockets_used := ammo_before - int(rack.slots()[2]["ammo"])
	var dmg_done := float(sk_r.max_hp.get("chassis", 125.0)) - float(sk_r.hp.get("chassis", 0.0))
	check((sk_r.destroyed() or dmg_done >= 50.0) and rockets_used <= 6,
		"one Rocket Pod salvo chunks/kills a Skirmisher at 45 m (%d rockets, %.0f dmg, %.2f s)" % [rockets_used, dmg_done, skr_ttk])

	# B. Real laser + autocannon vs Enforcer Turret gun weak point at 50 m.
	mech.heat = 0.0
	mech.shutdown = false
	var tu := EnemyTurret.new()
	tu.configure("turret", "ttk_turret", w, sq, null, 2)
	tu.ai_mode = "idle"
	tu.position = Vector3(0.0, 0.0, -50.0)
	sq.add_enemy(tu)
	await frames(1)
	rack.set_enabled(1, true)
	rack.set_enabled(2, true)
	rack.set_enabled(3, false)
	rack.set_enabled(5, false)
	var tu_ttk := _fire_until_dead(w, rack, tu, "gun", 4.0)
	check(tu.destroyed() and tu_ttk <= 1.8, "real laser+AC kills Turret via gun weak point at 50 m (TTK %.2f s)" % tu_ttk)

	# C. Elevated rooftop vantage (+15 m up, 42 m behind/above) firing real Side Laser at Tank's rear `vents` weak point!
	mech.heat = 0.0
	mech.shutdown = false
	mech.global_position = Vector3(0.0, 15.0, 0.0)
	var tk := EnemyTank.new()
	tk.configure("tank", "ttk_tank", w, sq, null, 3)
	tk.ai_mode = "idle"
	tk.position = Vector3(0.0, 0.0, -42.0)   # facing -Z -> rear vents at +Z face directly toward our rooftop mech!
	sq.add_enemy(tk)
	await frames(2)
	var melt := [""]
	tk.destroyed_enemy.connect(func(_e: EnemyBase, cause: String, _at: Vector3) -> void: melt[0] = cause)
	rack.set_enabled(1, true)   # solo Side Laser
	rack.set_enabled(2, false)
	rack.set_enabled(3, false)
	rack.set_enabled(5, false)
	var tk_ttk := _fire_until_dead(w, rack, tk, "vents", 3.0)
	print("[effectiveness] real-weapon TTKs: Skirmisher(45m)=%.2fs, Turret-gun(50m)=%.2fs, Tank-rooftop-vents(42m/+15m)=%.2fs (cause=%s)" % [
		sk_ttk, tu_ttk, tk_ttk, melt[0]])
	check(tk.destroyed() and tk_ttk <= 1.5, "rooftop real Side Laser melts Tank via vents weak point (TTK %.2f s)" % tk_ttk)
	eq(melt[0], "meltdown", "rooftop shot genuinely hit the vents sphere and triggered meltdown")

	sq.queue_free()
	rack.queue_free()
	mech.queue_free()
	floor_b.queue_free()
	w.queue_free()
	await frames(1)


func _fire_until_dead(w: CombatWorld, rack: WeaponRack, target: EnemyBase, comp_id: String, max_s: float) -> float:
	var t := 0.0
	rack.set_trigger(true)
	while t < max_s and not target.destroyed():
		for sp: Dictionary in target.world_spheres():
			if str(sp["component"]) == comp_id:
				rack.aim_point = sp["center"] as Vector3
				break
		rack.step(DT)
		w.advance(DT)
		t += DT
	rack.set_trigger(false)
	return t
