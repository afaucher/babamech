extends TestCase
## Valkyrie Rocket Gunship ("gunship", EnemyGunship) verification:
##   1. Watertight placeholder meshes + art-mesh deferral, 3 components (hull/pods/thrusters), pods disarm + 65 shock
##      dmg + wing-stub socket flame, and thrusters 1.5x critical kill ("engine_failure").
##   2. Cover-skim closing from 130 m -> <= 68 m, >= 0.70 s gunship_salvo telegraph, 4-rocket alternating left/right
##      pod salvo, and post-salvo break-off climb.
##   3. Host nearby-fire hearing (hear_fire) alerts gunship; client puppet runs zero AI and never moves/fires.
##   4. Co-op EnemySync manifest/puppet round-trip replicates gunship pose, aim, pods break, and destruction cleanly.

const DT := 1.0 / 60.0
const TEST_TIMEOUT := 400
const ENGAGED_SEEDS := [4, 1]
const ENGAGED_WINDOW := 30.0      ## s after first contact the gunship is watched for
const ENGAGED_MIN_SHARE := 0.7    ## of the window: within its rockets' range AND in line of sight of the mech


func setup() -> void:
	await _meshes_components_disarm_and_thruster_kill()
	await _approach_salvo_alternating_pods_and_breakoff()
	await _hearing_and_puppet_silence()
	await _coop_enemy_sync_roundtrip()
	for seed_n: int in ENGAGED_SEEDS:
		await _engaged_stays_in_range_and_visible(seed_n)
	finish()


func _init() -> void:
	timeout_sec = float(TEST_TIMEOUT)


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 88
	w.use_physics = physics
	add_child(w)
	return w


func _mock_player(w: CombatWorld, at: Vector3, id: String = "player1") -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = id
	p.owner_peer = 1
	p.team = "player"
	p.set_max_hp({"torso": 10000.0})
	p.add_hit_sphere("torso", Vector3(0.0, 4.0, 0.0), 2.1)
	p.position = at
	add_child(p)
	w.register(p)
	return p


func _meshes_components_disarm_and_thruster_kill() -> void:
	for part: String in ["gunship_hull", "gunship_pods", "gunship_thrusters"]:
		var m := EnemyGunship.placeholder_mesh(part)
		check(m != null and m.get_surface_count() > 0, "EnemyGunship placeholder %s builds" % part)
		# has_art_mesh() cleanly defers once EnemyMeshes implements the part (> 36 verts / > 2.2 m).
		check(not EnemyGunship.has_art_mesh(part) or EnemyMeshes.mesh(part).get_surface_count() > 0,
			"has_art_mesh check for %s is valid" % part)

	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	var g1 := EnemyGunship.new()
	g1.configure("gunship", "gunship_pods_test", w, sq, null, 1)
	g1.ai_mode = "idle"
	g1.position = Vector3(0.0, 11.5, -40.0)
	sq.add_enemy(g1)
	await frames(1)

	eq(g1.comp_order(), ["hull", "pods", "thrusters"], "gunship has hull, pods, thrusters components")
	eq(g1.world_spheres().size(), 6, "gunship has 6 hit spheres (2 hull + 2 pods + 2 thrusters)")
	near(float(g1.max_hp["hull"]), 190.0, 0.01, "hull HP = 190")
	near(float(g1.max_hp["pods"]), 95.0, 0.01, "pods HP = 95")
	near(float(g1.max_hp["thrusters"]), 85.0, 0.01, "thrusters HP = 85")

	# Destroying pods disarms primary rockets, deals 65 shock damage to hull, hides pods, and attaches socket flame!
	var hull0 := float(g1.hp["hull"])
	g1.apply_damage(100.0, "pods", "player1")
	check(not g1.destroyed(), "destroying gunship pods leaves damaged hull airborne")
	check(g1._primary_disabled, "broken pods disable primary rocket salvo")
	near(float(g1.hp["hull"]), hull0 - 65.0, 0.1, "broken pods deal 65 shock damage to hull")
	check(not g1._pods_mi.visible, "broken pods mesh hidden")
	check(g1.wreck.has_active_flame(), "broken pods attach wing-stub socket flame")

	# Thrusters weak point (85 HP at 1.5x -> 57 raw dmg kills with cause "engine_failure").
	var g2 := EnemyGunship.new()
	g2.configure("gunship", "gunship_thrusters_test", w, sq, null, 2)
	g2.ai_mode = "idle"
	g2.position = Vector3(14.0, 11.5, -40.0)
	sq.add_enemy(g2)
	var cause := [""]
	g2.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: cause[0] = c)
	await frames(1)
	g2.apply_damage(58.0, "thrusters", "player1")
	check(g2.destroyed(), "58 raw dmg (87 eff >= 85) on thrusters critically kills gunship")
	eq(cause[0], "engine_failure", "thrusters critical kill emits engine_failure cause")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _approach_salvo_alternating_pods_and_breakoff() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# Spawn gunship 130 m away and alert it -> closes via cover-skim into <= 68 m, telegraphs >= 0.70 s,
	# fires 4 alternating left/right pod rockets, and enters break-off climb!
	var g := EnemyGunship.new()
	g.configure("gunship", "gunship_run", w, sq, null, 3)
	g.position = Vector3(0.0, 11.5, -130.0)
	g.rotation.y = PI
	sq.add_enemy(g)

	var rockets: Array[Dictionary] = []
	var tele_kind := [""]
	var tele_dur := [0.0]
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == g.target_id:
			rockets.append(rec)
	)
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if enemy == g and kind == "telegraph_started":
			tele_kind[0] = str(pay.get("kind", ""))
			tele_dur[0] = float(pay.get("duration", 0.0))
	)
	await frames(1)

	g.receive_squad_alert(p)
	sq.report_sighting(g, p, Vector3(0.0, 4.0, 0.0))
	var min_dist := INF
	var max_breakoff_alt := 0.0
	for _i in 660:  # up to 11 s
		w.advance(DT)
		var d := Vector2(g.global_position.x, g.global_position.z).length()
		min_dist = minf(min_dist, d)
		if g._breakoff_count >= 1:
			max_breakoff_alt = maxf(max_breakoff_alt, g.global_position.y)
			if g._breakoff_t < 1.8:
				break

	check(min_dist <= EnemyGunship.CLOSE_ENGAGE_R + 2.0,
		"gunship closed from 130 m into close rocket range (min dist %.1f m)" % min_dist)
	eq(tele_kind[0], "gunship_salvo", "gunship emits gunship_salvo telegraph kind")
	check(tele_dur[0] >= 0.69, "gunship telegraph >= 0.70 s (%.2f s)" % tele_dur[0])
	eq(rockets.size(), 4, "gunship fired 4-rocket strafing salvo (got %d)" % rockets.size())
	if rockets.size() == 4:
		var o0: Vector3 = rockets[0]["origin"]
		var o1: Vector3 = rockets[1]["origin"]
		var o2: Vector3 = rockets[2]["origin"]
		check(o0.distance_to(o1) >= 2.2,
			"consecutive rockets alternate left/right wing pods (sep %.2f m)" % o0.distance_to(o1))
		check(o0.distance_to(o2) < o0.distance_to(o1) + 2.5,
			"third rocket returns to first pod side")
	check(g._breakoff_count >= 1 and max_breakoff_alt > 12.2,
		"gunship entered post-salvo break-off climb (count=%d, peak alt=%.1f m)" % [g._breakoff_count, max_breakoff_alt])

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _hearing_and_puppet_silence() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# Host gunship facing away at 18 m hears nearby player shot via Weapons' hear_fire hook!
	var g := EnemyGunship.new()
	g.configure("gunship", "gunship_hear", w, sq, null, 4)
	g.position = Vector3(0.0, 11.5, -18.0)
	g.rotation.y = 0.0  # facing away (-Z)
	sq.add_enemy(g)

	# Client puppet gunship must NEVER alert, move, or fire!
	var pup := EnemyGunship.new()
	pup.configure("gunship", "gunship_puppet", w, sq, null, 5)
	pup.puppet = true
	pup.position = Vector3(6.0, 11.5, -18.0)
	pup.rotation.y = PI
	sq.add_enemy(pup)
	await frames(1)

	var pup_pos0 := pup.global_position
	var shot := Combat.fire_record(p.target_id, 1, "autocannon", "autocannon", Vector3(0.0, 4.0, 0.0), Vector3(0.0, 4.0, -40.0), w.now, 0, 0.0)
	w.fire(shot)
	for _i in 60:
		w.advance(DT)
	check(g.is_alerted(), "host gunship alerted by nearby player fire via hear_fire")
	eq(pup.ai_state, EnemyBase.STATE_IDLE, "client puppet gunship runs zero AI")
	near(pup.global_position.distance_to(pup_pos0), 0.0, 0.01, "client puppet gunship does not move without host stream")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _coop_enemy_sync_roundtrip() -> void:
	var hw := _world(false)
	var hsq := EnemySquad.new()
	add_child(hsq)
	hsq.setup(hw)
	var hsync := EnemySync.new()
	hsync.world = hw
	hsync.squad = hsq
	hsync.hosting = true
	add_child(hsync)

	var g := EnemyGunship.new()
	g.configure("gunship", "sync_gunship", hw, hsq, null, 6)
	g.position = Vector3(0.0, 11.5, -45.0)
	hsq.add_enemy(g)
	hsync._adopt(g)
	await frames(1)

	var man := hsync.manifest()
	eq(man.size(), 1, "EnemySync manifest contains gunship")

	var cw := _world(false)
	var csq := EnemySquad.new()
	add_child(csq)
	csq.setup(cw)
	var csync := EnemySync.new()
	csync.world = cw
	csync.squad = csq
	csync.hosting = false
	add_child(csync)
	for en in man:
		csync._spawn_puppet(en)
	await frames(1)

	var pg := csync.by_net[g.net_id] as EnemyGunship
	check(pg != null and pg.puppet, "client EnemySync spawned gunship puppet")
	eq(pg.world_spheres().size(), 6, "gunship puppet has all 6 hit spheres")
	g.set_puppet_aim(Vector2(0.5, -0.22))
	pg.puppet_apply(g.puppet_state())
	pg.puppet_tick(DT)
	near(pg.puppet_aim().y, -0.22, 0.01, "gunship puppet pitch synced from host")
	pg.puppet_break("pods")
	check(not pg._pods_mi.visible and pg.wreck.has_active_flame(), "gunship puppet replays pods break & wing flame")

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	hsq.queue_free()
	hw.queue_free()
	await frames(1)


## Behaviour in the real game (MissionScene, plan mode): a hunting wave gunship put 120 m from a mech parked on a deck-0
## street crossing (kept standing) closes in, and for ENGAGED_WINDOW s after first contact (within CLOSE_ENGAGE_R)
## stays within its rockets' range and in line of sight of the mech (ray from the mech's eye height to its hull) for at
## least ENGAGED_MIN_SHARE of the time: a gunship that is shooting can be shot back. Then its pods are shot off: the
## disarmed gunship circles in reach (never farther than EVADE_RING_MAX + 25 m) instead of fleeing out of sight
## (seed 4: it used to fly to the deck's far end, 400 m out, and the sweep never ended).
func _engaged_stays_in_range_and_visible(seed_n: int) -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = seed_n
	add_child(td)
	await frames(4)
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var sq: EnemySquad = td.combat.squad
	var pt: PlayerTarget = td.combat.player_target
	var plan: CityPlan = sq.deck_plan(0)
	var nodes: Array = CityGraphs.walk_graph(plan)["nodes"]
	var tag := "seed %d" % seed_n
	# The crossing nearest the deck centre, the gunship 120 m along the deck from it (inside the keep-in rect).
	var c := plan.extent.get_center()
	var mn: Vector2 = nodes[0]
	for n: Vector2 in nodes:
		if n.distance_to(c) < mn.distance_to(c):
			mn = n
	var mp := td.stack.from_deck_arc(0, mn.x, mn.y, 0.5)
	td.mech.global_position = mp
	td.mech.velocity = Vector3.ZERO
	pt.global_position = mp
	await frames(2)
	var g := EnemySpawner.make_enemy("gunship") as EnemyGunship
	g.configure("gunship", "test_gs_%d" % seed_n, td.combat.world, sq, sq.deck_ring(0), seed_n)
	g.spawn_deck = 0
	g.wave = "test_engaged"
	var ga := Vector2(mn.x, mn.y + (120.0 if mn.y < c.y + 1.0 else -120.0))
	var gp := sq.deck_ring(0).arc_to_world(ga.x, ga.y, 14.0)
	g.up = sq.deck_ring(0).up_at(gp)
	g.transform = Transform3D(Basis(Vector3.RIGHT, g.up, Vector3.RIGHT.cross(g.up)).orthonormalized(), gp)
	sq.add_enemy(g)
	await frames(1)
	g.begin_hunt_pursuit(pt, g._target_aim_center(pt))
	var w_range := float(EnemyCatalog.weapon(str(EnemyCatalog.unit("gunship")["primary_weapon"])).get("range", 88.0))
	var space := td.mech.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.exclude = [td.mech.get_rid()]
	var t := 0.0
	var contact := -1.0
	var samples := 0
	var good := 0
	var max_d := 0.0
	var disarmed_at := -1.0
	var max_disarmed := 0.0
	while t < 75.0:
		await get_tree().physics_frame
		t += 1.0 / float(Engine.physics_ticks_per_second)
		pt.repair_all()
		if not is_instance_valid(g) or g.destroyed():
			break
		var d := g._world_pos().distance_to(mp)
		if contact < 0.0:
			if d <= EnemyGunship.CLOSE_ENGAGE_R:
				contact = t
			continue
		if t - contact <= ENGAGED_WINDOW:
			samples += 1
			max_d = maxf(max_d, d)
			q.from = mp + g.up * 6.0
			q.to = g._world_pos()
			var hit := space.intersect_ray(q)
			var vis := hit.is_empty() or q.from.distance_to(hit["position"] as Vector3) > q.from.distance_to(q.to) - 3.0
			if vis and d <= w_range:
				good += 1
			continue
		if disarmed_at < 0.0:
			g.apply_damage(1.0e4, "pods", "test")
			disarmed_at = t
			continue
		if t - disarmed_at > 3.0:
			max_disarmed = maxf(max_disarmed, d)
		if t - disarmed_at > 25.0:
			break
	var share := float(good) / maxf(float(samples), 1.0)
	print("[Test] engaged gunship %s: contact at %.1f s, in range + visible %.0f %% of %.0f s (max %.1f m), disarmed max %.1f m" % [
		tag, contact, share * 100.0, ENGAGED_WINDOW, max_d, max_disarmed])
	check(contact >= 0.0, tag + ": the gunship makes contact (within %.0f m)" % EnemyGunship.CLOSE_ENGAGE_R)
	check(share >= ENGAGED_MIN_SHARE, tag + ": in range and visible to its target %.0f %% of the window (>= %.0f %%)" % [
		share * 100.0, ENGAGED_MIN_SHARE * 100.0])
	check(disarmed_at > 0.0 and max_disarmed <= EnemyGunship.EVADE_RING_MAX + 25.0,
		tag + ": disarmed, it circles in reach (max %.1f m)" % max_disarmed)
	td.queue_free()
	await frames(2)
