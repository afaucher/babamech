extends TestCase
## Enemy AI, squad coordination, curved-deck movement, deterministic spawning, Audio bus contract, and EnemyLab sweep.

const DT := 1.0 / 60.0


func setup() -> void:
	await _telegraph_invariant_and_audio_bus()
	await _delayed_relay_and_interrupt()
	await _attack_slots_limit()
	await _curved_ring_and_spawner_determinism()
	await _enemy_lab_contract()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = physics
	add_child(w)
	return w


func _mock_player(w: CombatWorld, at: Vector3) -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = "player1"
	p.owner_peer = 1
	p.team = "player"
	p.mass_class = "mech"
	p.set_max_hp({"torso": 5000.0})
	p.add_hit_sphere("torso", Vector3(0, 4.0, 0), 2.0)
	p.position = at
	add_child(p)
	w.register(p)
	return p


func _telegraph_invariant_and_audio_bus() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	check(sq.is_in_group("enemy_squad"), "EnemySquad joins group enemy_squad")
	var events: Array = []
	sq.enemy_event.connect(func(kind: String, _e: Node, payload: Dictionary) -> void:
		events.append({"kind": kind, "payload": payload}))
	var fired_recs: Array = []
	w.fired.connect(func(rec: Dictionary) -> void: fired_recs.append(rec))

	var p := _mock_player(w, Vector3(0, 0, -45))
	var t := EnemyTurret.new()
	t.configure("turret", "turret_01", w, sq, null, 1)
	t.telegraph_scale = 0.05   # extreme low slider: must still clamp >= 0.3 s!
	sq.add_enemy(t)
	await frames(1)
	check(t.is_in_group("enemies"), "EnemyBase joins group enemies")

	# Advance through alert (0.35 s) + telegraph (>= 0.3 s) + burst fire.
	for _i in 120:
		w.advance(DT)

	var tele := {}
	var fired_ev := {}
	var alert_ev := {}
	for ev: Dictionary in events:
		if str(ev["kind"]) == "telegraph_started" and tele.is_empty():
			tele = ev["payload"]
		elif str(ev["kind"]) == "weapon_fired" and fired_ev.is_empty():
			fired_ev = ev["payload"]
		elif str(ev["kind"]) == "alerted" and alert_ev.is_empty():
			alert_ev = ev["payload"]
	check(not alert_ev.is_empty() and str(alert_ev["state"]) == "spotted", "alerted event emitted with spotted state")
	check(not tele.is_empty(), "telegraph_started event emitted")
	check(float(tele.get("duration", 0.0)) >= EnemyCatalog.MIN_TELEGRAPH - 1e-4,
		"telegraph duration enforces >= 0.3 s floor (%.3f s)" % float(tele.get("duration", 0.0)))
	check(str(tele.get("kind", "")) in ["beam", "cannon", "mortar", "pulse"], "telegraph kind matches Audio contract")
	check(not fired_ev.is_empty(), "weapon_fired event emitted after telegraph")
	check(not fired_recs.is_empty() and bool(fired_recs[0].get("enemy", false)) and str(fired_recs[0].get("team", "")) == "enemy",
		"enemy fire record carries enemy=true and team='enemy'")

	# Stagger cancels telegraph and emits telegraph_cancelled.
	var s := EnemyStrider.new()
	s.configure("strider", "strider_cancel", w, sq, null, 2)
	s.position = Vector3(12, 0, 0)
	sq.add_enemy(s)
	await frames(1)
	var cancelled := [""]
	sq.enemy_event.connect(func(kind: String, _e: Node, payload: Dictionary) -> void:
		if kind == "telegraph_cancelled" and str(payload.get("id", "")) == "strider_cancel":
			cancelled[0] = str(payload.get("reason", "")))
	for _i in 60:
		w.advance(DT)
		if s.ai_state == EnemyBase.STATE_TELEGRAPH:
			s.apply_impulse(Vector3(8.0, 0, 0), "player1")
			w.advance(DT)
			break
	eq(cancelled[0], "stagger", "staggering mid-telegraph emits telegraph_cancelled(stagger)")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _delayed_relay_and_interrupt() -> void:
	# Case A: spotter stays alive past 0.45 s -> blind squadmate behind it receives relay alert.
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, -50))
	var spotter := EnemyStrider.new()
	spotter.configure("strider", "spotter_a", w, sq, null, 1)
	sq.add_enemy(spotter)
	var buddy := EnemyStrider.new()
	buddy.configure("strider", "buddy_a", w, sq, null, 2)
	buddy.position = Vector3(25, 0, 0)
	buddy.rotation.y = PI   # facing away from player, out of initial FOV
	buddy.sight_range = 10.0   # cannot see player directly at 55 m
	sq.add_enemy(buddy)
	await frames(1)
	w.advance(DT)
	check(spotter.is_alerted() and not buddy.is_alerted(), "spotter alerts immediately; buddy not alerted yet")
	for _i in 35:   # ~0.58 s > 0.45 s RELAY_DELAY
		w.advance(DT)
	check(buddy.is_alerted(), "buddy receives delayed squad alert after 0.45 s relay")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)

	# Case B: kill spotter BEFORE 0.45 s -> relay never fires and buddy stays unalerted!
	var w2 := _world(false)
	var sq2 := EnemySquad.new()
	add_child(sq2)
	sq2.setup(w2)
	var p2 := _mock_player(w2, Vector3(0, 0, -50))
	var spot2 := EnemyStrider.new()
	spot2.configure("strider", "spotter_b", w2, sq2, null, 1)
	sq2.add_enemy(spot2)
	var buddy2 := EnemyStrider.new()
	buddy2.configure("strider", "buddy_b", w2, sq2, null, 2)
	buddy2.position = Vector3(25, 0, 0)
	buddy2.rotation.y = PI
	buddy2.sight_range = 10.0
	sq2.add_enemy(buddy2)
	await frames(1)
	w2.advance(DT)
	check(spot2.is_alerted(), "spotter_b spotted target")
	spot2.apply_damage(100.0, "sensor", "player1")   # kill before 0.45 s relay
	for _i in 45:
		w2.advance(DT)
	check(not buddy2.is_alerted(), "killing spotter before 0.45 s prevents squad relay alert")
	p2.queue_free()
	sq2.queue_free()
	w2.queue_free()
	await frames(1)


func _attack_slots_limit() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	sq.max_attackers = 2
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, -50))
	for i in 4:
		var t := EnemyTurret.new()
		t.configure("turret", "slot_t_%d" % i, w, sq, null, i + 1)
		t.position = Vector3((float(i) - 1.5) * 10.0, 0, 0)
		sq.add_enemy(t)
	await frames(1)
	var peak_attacking := 0
	for _i in 180:
		w.advance(DT)
		var cur := 0
		for e in sq.enemies:
			if e.ai_state in [EnemyBase.STATE_TELEGRAPH, EnemyBase.STATE_FIRE]:
				cur += 1
		peak_attacking = maxi(peak_attacking, cur)
	check(peak_attacking > 0 and peak_attacking <= 2,
		"attack slots cap simultaneous attackers to <= 2 (peak %d)" % peak_attacking)
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _curved_ring_and_spawner_determinism() -> void:
	var plan1 := CityPlan.make({"seed": 7.0, "walls": 1.0})
	var ring1 := RingFrame.new(plan1.p("radius"))
	var spawn_p := ring1.arc_to_world(0.0, 12.0, CityPlan.CURB_H + 0.3)
	var a := EnemySpawner.plan_encounters(plan1, ring1, spawn_p)
	var b := EnemySpawner.plan_encounters(plan1, ring1, spawn_p)
	eq(a.size(), b.size(), "same seed spawns identical enemy count (%d)" % a.size())
	check(a.size() >= 6 and a.size() <= 7, "city district spawns a well-spaced 6-7 enemy set (%d)" % a.size())
	var types := {}
	for i in a.size():
		eq(str(a[i]["id"]), str(b[i]["id"]), "deterministic enemy id %d" % i)
		near(float(a[i]["x"]), float(b[i]["x"]), 0.0001, "deterministic x %d" % i)
		near(float(a[i]["s"]), float(b[i]["s"]), 0.0001, "deterministic s %d" % i)
		var d := Vector2(float(a[i]["x"]), float(a[i]["s"])).distance_to(Vector2(0.0, 12.0))
		check(d >= EnemySpawner.SPAWN_SAFE_RADIUS - 0.1, "enemy %s respects spawn safe radius (%.1f m)" % [a[i]["id"], d])
		types[str(a[i]["type"])] = int(types.get(str(a[i]["type"]), 0)) + 1
	var n_turret := int(types.get("turret", 0)) + int(types.get("turret_sniper", 0)) + int(types.get("turret_missile", 0))
	var n_strider := int(types.get("strider", 0)) + int(types.get("strider_breacher", 0))
	var n_troop := int(types.get("troop_squad", 0)) + int(types.get("troop_roof", 0))
	check(n_turret >= 1 and n_strider >= 1 and int(types.get("tank", 0)) >= 1 and int(types.get("drone", 0)) >= 1 and n_troop >= 1,
		"district includes turret, strider, tank, drone and troop classes (%s)" % str(types))

	var plan2 := CityPlan.make({"seed": 8.0, "walls": 1.0})
	var ring2 := RingFrame.new(plan2.p("radius"))
	var c := EnemySpawner.plan_encounters(plan2, ring2, ring2.arc_to_world(0.0, 12.0, 0.5))
	var same_all := a.size() == c.size()
	if same_all:
		for i in a.size():
			if absf(float(a[i]["x"]) - float(c[i]["x"])) > 0.1 or absf(float(a[i]["s"]) - float(c[i]["s"])) > 0.1:
				same_all = false
				break
	check(not same_all, "different city seed produces a different enemy layout")

	# Curved-deck movement: Skirmisher patrols along RingFrame arc and stays upright to ring.up_at(pos) + emits footsteps.
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan1, ring1)
	var st := EnemyStrider.new()
	st.configure("strider", "ring_mover", w, sq, ring1, 1)
	var p0 := ring1.arc_to_world(0.0, 10.0, 0.0)
	st.up = ring1.up_at(p0)
	st.transform = Transform3D(ring1.basis_at_arc(10.0), p0)
	st.set_patrol_points([Vector2(0.0, 45.0), Vector2(0.0, 10.0)])
	sq.add_enemy(st)
	var steps := [0]
	sq.enemy_event.connect(func(kind: String, _e: Node, _pay: Dictionary) -> void:
		if kind == "footstep":
			steps[0] += 1)
	await frames(1)
	for _i in 120:
		w.advance(DT)
	var arc_end := ring1.world_to_arc(st.global_position)
	check(arc_end.y > 18.0, "strider walked forward along curved ring arc (s=%.1f)" % arc_end.y)
	near(st.global_basis.y.dot(ring1.up_at(st.global_position)), 1.0, 0.01, "strider stays upright to local radial up")
	check(steps[0] >= 2, "strider emits footstep events on stride (%d)" % steps[0])
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _enemy_lab_contract() -> void:
	var lab := EnemyLab.new()
	add_child(lab)
	await frames(2)
	check(lab.lab_own_ground(), "EnemyLab brings its own ground")
	for p: Dictionary in lab.lab_params():
		lab.set_lab_param(str(p["id"]), float(p["min"]))
		lab.step(DT)
		lab.set_lab_param(str(p["id"]), float(p["max"]))
		lab.step(DT)
	for o: Dictionary in lab.lab_options():
		for ch: Variant in o["choices"]:
			lab.set_lab_option(str(o["id"]), str(ch))
			lab.step(DT)
	lab.queue_free()
	await frames(1)
