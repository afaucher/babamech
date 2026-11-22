extends TestCase
## Tactics, long-range variants, Patrol Drone, cover-bounding, and co-op puppet round-trip
## (docs/design/enemy-tactics-and-drones.md Phases A-D).

const DT := 1.0 / 60.0


func setup() -> void:
	await _drone_hearing_standoff_and_beacon()
	await _drone_beacon_cancel_and_puppet()
	await _new_variants_and_weapons()
	await _cover_bounding_and_peek_in_city()
	await _enemy_sync_manifest_roundtrip()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
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


func _drone_hearing_standoff_and_beacon() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# Drone patrolling at 105 m (outside patrol sight 115? No, face it AWAY so visual FOV doesn't see player first,
	# and place it at 102 m within its 120 m extended hearing radius).
	var drone := EnemyDrone.new()
	drone.configure("drone", "drone_test", w, sq, null, 1)
	drone.spawn_deck = 0
	drone.position = Vector3(0.0, 15.0, -102.0)
	drone.rotation.y = 0.0  # facing -Z, away from player at origin
	drone.set_patrol_points([Vector2(-20.0, -102.0), Vector2(20.0, -102.0)])
	sq.add_enemy(drone)

	# Idle ground defender 90 m from drone on deck 0 (outside normal 52 m relay, inside 130 m beacon!).
	var defender := EnemyStrider.new()
	defender.configure("strider_breacher", "def_deck0", w, sq, null, 2)
	defender.spawn_deck = 0
	defender.position = Vector3(88.0, 0.0, -102.0)
	defender.rotation.y = 0.0
	sq.add_enemy(defender)

	# Idle ground defender on deck 1 (same XZ, different deck -> must NEVER be pulled by deck 0 beacon!).
	var other_deck := EnemyStrider.new()
	other_deck.configure("strider", "def_deck1", w, sq, null, 3)
	other_deck.spawn_deck = 1
	other_deck.position = Vector3(20.0, 0.0, -102.0)
	other_deck.rotation.y = 0.0
	sq.add_enemy(other_deck)
	sq.deck_of = func(pos: Vector3) -> int:
		return 0 if pos.y < 50.0 else 1

	var beacon_started := [false]
	var beacon_dur := [0.0]
	var drone_shots := [0]
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if enemy == drone and kind == "telegraph_started" and str(pay.get("kind", "")) == "beacon":
			beacon_started[0] = true
			beacon_dur[0] = float(pay.get("duration", 0.0))
	)
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == drone.target_id:
			drone_shots[0] += 1
	)
	await frames(1)

	# Fire a player autocannon shot at origin (within 120 m drone hearing, well outside 25 m ground hearing).
	var rec := Combat.fire_record(p.target_id, 1, "autocannon", "autocannon", Vector3(0.0, 4.0, 0.0), Vector3(0.0, 4.0, 60.0), w.now, 0, 0.0)
	w.fire(rec)
	check(drone._investigating, "drone heard distant player gunfire at 102 m and began investigating")
	check(not defender.is_alerted(), "drone hearing does not blindly alert ground defenders before beacon completes")
	w.advance(DT)

	# Advance up to 4 s: drone spots player, runs 0.65 s Alert Beacon, and pulls deck-0 defender 90 m away!
	for _i in 240:
		w.advance(DT)
		if drone._beacon_count >= 1:
			break
	check(beacon_started[0], "drone emitted beacon telegraph_started event")
	check(beacon_dur[0] >= 0.64, "drone beacon telegraph >= 0.65 s (%.2f s)" % beacon_dur[0])
	check(drone._beacon_count >= 1, "drone completed Alert Beacon pulse")
	check(defender.is_alerted(), "drone Alert Beacon pulled ground defender 90 m away on same deck")
	check(not other_deck.is_alerted(), "drone Alert Beacon did NOT pull defender on another deck")
	eq(drone_shots[0], 0, "unarmed drone never fires any weapons")

	# Standoff retreat check: push player inside 45 m of drone -> drone actively backs out toward standoff band (>= 72 m).
	p.global_position = Vector3(drone.global_position.x, 0.0, drone.global_position.z + 36.0)
	var d_before := Vector2(drone.global_position.x - p.global_position.x, drone.global_position.z - p.global_position.z).length()
	for _i in 240:
		w.advance(DT)
	var d_after := Vector2(drone.global_position.x - p.global_position.x, drone.global_position.z - p.global_position.z).length()
	check(d_after > d_before + 25.0 and d_after >= 72.0,
		"drone retreats from close player into standoff band (%.1f m -> %.1f m)" % [d_before, d_after])

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _drone_beacon_cancel_and_puppet() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	var drone := EnemyDrone.new()
	drone.configure("drone", "drone_cancel", w, sq, null, 4)
	drone.position = Vector3(0.0, 15.0, -85.0)
	drone.rotation.y = PI  # facing player directly
	sq.add_enemy(drone)

	var defender := EnemyStrider.new()
	defender.configure("strider", "def_unpulled", w, sq, null, 5)
	defender.position = Vector3(85.0, 0.0, -85.0)
	defender.rotation.y = 0.0
	sq.add_enemy(defender)

	var cancelled := [false]
	sq.enemy_event.connect(func(kind: String, enemy: Node, _pay: Dictionary) -> void:
		if enemy == drone and kind == "telegraph_cancelled":
			cancelled[0] = true
	)
	await frames(1)

	# Step until drone starts charging its 0.65 s beacon, then snipe its optic weak point mid-charge!
	var saw_tele := false
	for _i in 60:
		w.advance(DT)
		if drone.ai_state == EnemyBase.STATE_TELEGRAPH:
			saw_tele = true
			for _j in 12:
				w.advance(DT)  # 0.2 s into the 0.65 s flare
			drone.apply_damage(30.0, "optic", p.target_id)
			break
	check(saw_tele, "drone entered STATE_TELEGRAPH for Alert Beacon")
	check(drone.destroyed(), "sniping drone optic weak point kills drone immediately")
	check(cancelled[0], "killing drone mid-beacon emits telegraph_cancelled")
	for _i in 60:
		w.advance(DT)
	check(not defender.is_alerted(), "killing drone during 0.65 s beacon cancels the reinforcement pull")
	eq(drone._beacon_count, 0, "cancelled beacon never completed")

	# Puppet drone runs zero AI and never starts beacons or moves on its own.
	var pup := EnemyDrone.new()
	pup.configure("drone", "drone_puppet", w, sq, null, 6)
	pup.puppet = true
	pup.position = Vector3(0.0, 15.0, -50.0)
	pup.rotation.y = PI
	sq.add_enemy(pup)
	await frames(1)
	var pup_pos0 := pup.global_position
	for _i in 90:
		w.advance(DT)
	eq(pup.ai_state, EnemyBase.STATE_IDLE, "puppet drone runs zero AI")
	near(pup.global_position.distance_to(pup_pos0), 0.0, 0.01, "puppet drone stays put without host stream")
	pup.puppet_telegraph("enemy_beacon", 0.25, 0.65, Vector3.ZERO)
	pup.puppet_tick(DT)
	eq(pup.ai_state, EnemyBase.STATE_TELEGRAPH, "puppet drone displays host-streamed beacon telegraph")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _new_variants_and_weapons() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.max_attackers = 4
	sq.slot_stagger = 0.0

	# 1. turret_sniper engages at 180 m with enemy_lance (>= 0.95 s telegraph).
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))
	var sniper := EnemyTurret.new()
	sniper.configure("turret_sniper", "sniper_1", w, sq, null, 10)
	sniper.position = Vector3(0.0, 0.0, -180.0)
	sniper.rotation.y = PI
	sq.add_enemy(sniper)
	var fired_by := {}
	var tele_durs := {}
	w.fired.connect(func(rec: Dictionary) -> void:
		var sid := str(rec.get("shooter", ""))
		if not fired_by.has(sid):
			fired_by[sid] = []
		(fired_by[sid] as Array).append(rec)
	)
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if kind == "telegraph_started":
			tele_durs[(enemy as EnemyBase).target_id] = float(pay.get("duration", 0.0))
	)
	await frames(1)
	# Force alert so sniper engages from 180 m (alert sight 215 m, lance range 215 m).
	sniper.receive_squad_alert(p)
	for _i in 180:
		w.advance(DT)
		if fired_by.has("sniper_1"):
			break
	check(fired_by.has("sniper_1"), "turret_sniper fired enemy_lance at 180 m")
	check(float(tele_durs.get("sniper_1", 0.0)) >= 0.94,
		"turret_sniper lance telegraph >= 0.95 s (%.2f s)" % float(tele_durs.get("sniper_1", 0.0)))

	# 2. turret_missile fires 3-rocket staggered salvo at 160 m.
	var mt := EnemyTurret.new()
	mt.configure("turret_missile", "missile_1", w, sq, null, 11)
	mt.position = Vector3(16.0, 0.0, -160.0)
	mt.rotation.y = PI
	sq.add_enemy(mt)
	await frames(1)
	mt.receive_squad_alert(p)
	for _i in 240:
		w.advance(DT)
		if (fired_by.get("missile_1", []) as Array).size() >= 3:
			break
	check((fired_by.get("missile_1", []) as Array).size() >= 3,
		"turret_missile fired 3-rocket salvo at 160 m (got %d)" % (fired_by.get("missile_1", []) as Array).size())
	check(float(tele_durs.get("missile_1", 0.0)) >= 0.84,
		"turret_missile salvo telegraph >= 0.85 s (%.2f s)" % float(tele_durs.get("missile_1", 0.0)))

	# 3. strider_breacher fires 5-pellet horizontal fan at 45 m.
	var br := EnemyStrider.new()
	br.configure("strider_breacher", "breacher_1", w, sq, null, 12)
	br.position = Vector3(-6.0, 0.0, -45.0)
	br.rotation.y = PI
	sq.add_enemy(br)
	await frames(1)
	for _i in 180:
		w.advance(DT)
		if (fired_by.get("breacher_1", []) as Array).size() >= 5:
			break
	var pellets: Array = fired_by.get("breacher_1", [])
	eq(pellets.size(), 5, "strider_breacher fired 5-pellet scatter fan at 45 m")
	if pellets.size() == 5:
		var d0: Vector3 = (pellets[0] as Dictionary)["dir"]
		var d4: Vector3 = (pellets[4] as Dictionary)["dir"]
		var fan_ang := rad_to_deg(d0.angle_to(d4))
		check(fan_ang >= 5.0 and fan_ang <= 11.0, "scatter 5-pellet horizontal fan angle ~7.5 deg (%.1f deg)" % fan_ang)

	# 4. Strider HP bump check: chassis 125, sensor 65 (single 55 dmg body hit leaves strider alive).
	var st := EnemyStrider.new()
	st.configure("strider", "strider_hp", w, sq, null, 13)
	st.ai_mode = "idle"
	sq.add_enemy(st)
	await frames(1)
	near(float(st.max_hp["chassis"]), 125.0, 0.01, "strider chassis HP bumped to 125")
	near(float(st.max_hp["sensor"]), 65.0, 0.01, "strider sensor HP bumped to 65")
	st.apply_damage(55.0, "chassis", p.target_id)
	check(not st.destroyed(), "strider survives a 55 dmg body hit")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _cover_bounding_and_peek_in_city() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 1.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring

	var w := _world(true)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)

	var p_pos := ring.arc_to_world(0.0, -78.0, CityPlan.CURB_H)
	var p := _mock_player(w, p_pos)
	var threat_arc := Vector2(0.0, -78.0)

	# Compare 2D LOS exposure ratio of find_cover_path vs straight find_arc_path across the full district (s: -78..+92).
	var start_arc := Vector2(0.0, 92.0)
	var raw_path := sq.find_arc_path(start_arc, threat_arc)
	var cov_path := sq.find_cover_path(start_arc, threat_arc, threat_arc, -1, EnemyCatalog.engage_range("strider_breacher"))
	check(not raw_path.is_empty() and not cov_path.is_empty(), "both road-graph paths found across city district")
	var raw_exp := _path_exposure(sq, raw_path, threat_arc)
	var cov_exp := _path_exposure(sq, cov_path, threat_arc)
	check(cov_exp < raw_exp,
		"find_cover_path lowers open-LOS exposure vs straight path (cover=%.2f < straight=%.2f)" % [cov_exp, raw_exp])

	# Spawn a live strider_breacher inside the district ~135 m away behind city blocks, alert it via LKP,
	# and verify it enters BOUND -> executes PEEK -> advances toward the target!
	var br_arc := Vector2(56.0, 48.0)
	var br_pt := EnemySpawner._find_clear_ground(plan, br_arc, EnemySpawner.STRIDER_CLEAR, [threat_arc], 10.0, threat_arc)
	if is_nan(br_pt.x):
		br_pt = Vector2(0.0, 56.0)
	var br := EnemyStrider.new()
	br.configure("strider_breacher", "breacher_city", w, sq, ring, 21)
	var br_w := ring.arc_to_world(br_pt.x, br_pt.y, CityPlan.CURB_H)
	br.up = ring.up_at(br_w)
	br.transform = Transform3D(ring.basis_at_arc(br_pt.y), br_w)
	sq.add_enemy(br)
	await frames(2)

	sq.report_sighting(br, p, p_pos + p.up * 4.0)
	br.receive_squad_alert(p)
	var saw_bound := false
	var saw_peek := false
	var d0 := br.global_position.distance_to(p.global_position)
	for _i in 660:  # 11 s of real-physics cover-bounding
		w.advance(DT)
		var dbg := br.debug_info()
		if str(dbg["cover_mode"]) == "bound":
			saw_bound = true
		elif str(dbg["cover_mode"]) == "peek":
			saw_peek = true
	var d1 := br.global_position.distance_to(p.global_position)
	check(saw_bound, "strider_breacher entered cover-bounding (BOUND) mode outside engage_range")
	check(saw_peek or br._peek_count >= 1,
		"strider_breacher executed peek-to-reacquire cycle while bounding (peeks=%d)" % br._peek_count)
	check(d1 < d0 - 20.0, "cover-bounding breacher made real forward progress (%.1f m -> %.1f m)" % [d0, d1])

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	city.queue_free()
	await frames(1)


func _path_exposure(sq: EnemySquad, pts: Array[Vector2], threat_arc: Vector2) -> float:
	if pts.is_empty():
		return 1.0
	var exposed := 0
	for pt in pts:
		if not sq.arc_segment_occluded(pt, threat_arc):
			exposed += 1
	return float(exposed) / float(pts.size())


func _enemy_sync_manifest_roundtrip() -> void:
	var hw := _world(false)
	var hsq := EnemySquad.new()
	add_child(hsq)
	hsq.setup(hw)
	var hsync := EnemySync.new()
	hsync.world = hw
	hsync.squad = hsq
	hsync.hosting = true
	add_child(hsync)

	var types: Array[String] = ["drone", "turret_sniper", "turret_missile", "strider_breacher"]
	for i in types.size():
		var tid: String = types[i]
		var e := EnemySpawner.make_enemy(tid)
		e.configure(tid, "sync_%s" % tid, hw, hsq, null, 30 + i)
		e.position = Vector3(float(i) * 14.0, 15.0 if tid == "drone" else 0.0, -30.0)
		hsq.add_enemy(e)
		hsync._adopt(e)
	await frames(1)

	var man := hsync.manifest()
	eq(man.size(), 4, "EnemySync manifest contains all 4 new enemy types")

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

	eq(csync.by_net.size(), 4, "client EnemySync spawned all 4 new enemy puppets from manifest")
	for n: int in csync.by_net:
		var pe := csync.by_net[n] as EnemyBase
		var he := hsync.by_net[n] as EnemyBase
		check(pe.puppet, "spawned %s is marked puppet" % pe.enemy_type)
		eq(pe.enemy_type, he.enemy_type, "puppet enemy_type matches host (%s)" % he.enemy_type)
		check(pe.hit_shapes.size() >= 2, "puppet %s has hit spheres" % pe.enemy_type)
		var st := he.puppet_state()
		pe.puppet_apply(st)
		pe.puppet_tick(DT)
		eq(pe.ai_state, he.ai_state, "puppet %s applied host state cleanly" % pe.enemy_type)

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	hsq.queue_free()
	hw.queue_free()
	await frames(1)
