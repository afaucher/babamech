extends TestCase
## Exo-Trooper Fireteam Redo verification (docs/design/enemy-troop-squads.md):
##   1. Variable-sized mixed rifle/AT fireteams (seeded 3-6 ground, 2-4 roof) of individual EnemyTrooper EnemyBase units.
##   2. Per-trooper seeded jitter (distinct pace, reaction delay, aim error, cooldown mult, idle sway, formation offset).
##   3. Independent cover selection: troopers in a CityDistrict claim separate cover corners (>= 3.5 m apart).
##   4. Independent HP / death / morale: killing 1 trooper drops only that trooper & decrements alive_per_deck by 1;
##      losing >= 50% triggers fireteam.morale_broken & survivor fallback/regroup (overridden by deck hunt-out).
##   5. Staggered single-shot firing (telegraphs >= 0.55 s rifle / 0.85 s AT, burst == 1), jump-pack ascent, mech stomp crush.
##   6. Co-op EnemySync replicates every individual trooper puppet and propagates individual kills cleanly.

const DT := 1.0 / 60.0


func setup() -> void:
	_variable_composition_and_jitter()
	await _independent_cover_and_individual_death()
	await _staggered_single_shots_morale_and_stomp()
	await _jump_pack_rooftop_ascent()
	await _coop_enemy_sync_individual_troopers()
	finish()


func _world(physics: bool = false, ring: RingFrame = null) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = physics
	w.ring = ring
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


func _variable_composition_and_jitter() -> void:
	# 1. Variable-sized seeded fireteam compositions across seeds & weights (3-6 ground, 2-4 roof).
	var ground_sizes := {}
	var saw_mixed_at := false
	for s in range(1, 20):
		var rng := RandomNumberGenerator.new()
		rng.seed = s * 1337
		for w_name: String in ["light", "medium", "heavy"]:
			var comp := EnemyTroopSquad.roll_composition(rng, w_name, false, 6)
			check(comp.size() >= 3 and comp.size() <= 6, "ground squad size in 3..6 (%d for %s)" % [comp.size(), w_name])
			ground_sizes[comp.size()] = true
			if "trooper_rifle" in comp and "trooper_at" in comp:
				saw_mixed_at = true
		var rcomp := EnemyTroopSquad.roll_composition(rng, "medium", true, 4)
		check(rcomp.size() >= 2 and rcomp.size() <= 4, "roof squad size in 2..4 (%d)" % rcomp.size())
		eq(rcomp[0], "trooper_at", "rooftop fireteam leader carries AT launcher")
	check(ground_sizes.size() >= 3, "ground fireteams vary in size across seeds/weights (%s)" % str(ground_sizes.keys()))
	check(saw_mixed_at, "ground fireteams mix riflemen and AT specialists")

	# 2. Seeded per-trooper jitter produces distinct individuals (never clones in lockstep).
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var paces := {}
	var reacts := {}
	var aims := {}
	var sways := {}
	for i in 5:
		var tr := EnemyTrooper.new()
		tr.configure("trooper_rifle" if i < 4 else "trooper_at", "jit_sq_t%d" % i, w, sq, null, 77 + i)
		paces[snappedf(tr._pace_mult, 0.001)] = true
		reacts[snappedf(tr._react_delay, 0.001)] = true
		aims[snappedf(tr._aim_error_deg, 0.001)] = true
		sways[snappedf(tr._sway_phase, 0.001)] = true
		tr.queue_free()
	check(paces.size() >= 4, "per-trooper pace multipliers vary across squad (%d unique)" % paces.size())
	check(reacts.size() >= 4, "per-trooper reaction delays vary across squad (%d unique)" % reacts.size())
	check(aims.size() >= 4, "per-trooper aim error varies across squad (%d unique)" % aims.size())
	check(sways.size() >= 4, "per-trooper idle sway phases vary across squad (%d unique)" % sways.size())
	sq.queue_free()
	w.queue_free()


func _independent_cover_and_individual_death() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 3.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring

	var w := _world(true, ring)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)

	var p := _mock_player(w, ring.arc_to_world(0.0, -55.0, CityPlan.CURB_H))
	var ft := EnemyTroopSquad.make("cover_sq", 0, ring.arc_to_world(0.0, 12.0, CityPlan.CURB_H), false)
	sq.register_fireteam(ft)

	var troopers: Array[EnemyTrooper] = []
	for i in 4:
		var tr := EnemyTrooper.new()
		var kit := "trooper_at" if i == 3 else "trooper_rifle"
		tr.configure(kit, "cov_t%d" % i, w, sq, ring, 100 + i)
		tr.spawn_deck = 0
		tr.attach_fireteam(ft, i)
		var pos_w := ring.arc_to_world(float(i - 1) * 5.0, 10.0 + float(i % 2) * 4.0, CityPlan.CURB_H)
		tr.up = ring.up_at(pos_w)
		tr.transform = Transform3D(ring.basis_at_arc(10.0), pos_w)
		sq.add_enemy(tr)
		troopers.append(tr)
	await frames(2)

	# Alert squad and let each trooper independently pick & claim its own distinct cover corner!
	troopers[0].hear_fire(p)
	for _i in 120:
		w.advance(DT)

	check(ft.claimed_covers.size() >= 2, "multiple troopers independently claimed cover corners (%d)" % ft.claimed_covers.size())
	var corners: Array = ft.claimed_covers.values()
	var min_sep := INF
	for i in corners.size():
		for j in range(i + 1, corners.size()):
			min_sep = minf(min_sep, (corners[i] as Vector3).distance_to(corners[j] as Vector3))
	if corners.size() >= 2:
		check(min_sep >= EnemyTroopSquad.COVER_MIN_SEP - 0.1,
			"claimed cover corners are distinct per trooper (min sep=%.2f m)" % min_sep)

	# Direct projectile Hit + explosive splash Hit both land cleanly on EnemyTrooper without script errors!
	var direct_h := Hit.new()
	direct_h.damage = 12.0
	direct_h.component = "body"
	direct_h.weapon = "autocannon"
	direct_h.shooter = "player1"
	direct_h.point = troopers[1].global_position
	w.deliver(troopers[1], direct_h)
	check(not troopers[1].destroyed() and float(troopers[1].hp["body"]) < 20.0,
		"direct Hit via CombatWorld.deliver damages trooper cleanly without error")
	var sc_before := troopers[2]._scatter_count
	var srec := Combat.fire_record("player1", 1, "rockets", "rockets", p.global_position, troopers[2].global_position, w.now, 1)
	srec["team"] = "player"
	w.splash(srec, w.stats("rockets"), troopers[2].global_position + Vector3(1.5, 0.0, 0.0))
	check(not troopers[2].destroyed() and troopers[2]._scatter_count > sc_before,
		"explosive splash via CombatWorld.splash damages & triggers scatter panic cleanly")

	# Killing ONE trooper must NOT kill the rest and must decrement alive_per_deck by exactly 1!
	var before := EnemySync.alive_per_deck(sq.enemies, 1)[0]
	eq(before, 4, "all 4 individual troopers counted in alive_per_deck")
	troopers[0].apply_damage(35.0, "body", "player1")
	check(troopers[0].destroyed(), "35 dmg kills individual 30 HP trooper_rifle")
	eq(EnemySync.alive_per_deck(sq.enemies, 1)[0], 3, "killing 1 trooper leaves 3 alive in alive_per_deck")
	eq(ft.alive_count(), 3, "fireteam tracks 3 surviving troopers")
	check(not troopers[1].destroyed() and not troopers[2].destroyed() and not troopers[3].destroyed(),
		"killing trooper 0 does not harm or destroy squadmates")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	city.queue_free()
	await frames(1)


func _staggered_single_shots_morale_and_stomp() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.max_attackers = 4

	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))
	var ft := EnemyTroopSquad.make("fire_sq", 0, Vector3(0.0, 0.0, -52.0), false)
	sq.register_fireteam(ft)
	var troopers: Array[EnemyTrooper] = []
	for i in 4:
		var tr := EnemyTrooper.new()
		var kit := "trooper_at" if i == 3 else "trooper_rifle"
		tr.configure(kit, "fire_t%d" % i, w, sq, null, 200 + i)
		tr.attach_fireteam(ft, i)
		tr.position = Vector3(float(i) * 5.5 - 8.25, 0.0, -52.0 - float(i % 2) * 3.0)
		tr.rotation.y = PI
		sq.add_enemy(tr)
		troopers.append(tr)

	var tele_times: Array[float] = []
	var rifle_tele := [INF]
	var at_tele := [INF]
	var shots_by := {}
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if kind == "telegraph_started":
			tele_times.append(w.now)
			var w_id := str(pay.get("weapon", ""))
			var dur := float(pay.get("duration", 0.0))
			if w_id == "enemy_troop_rifle":
				rifle_tele[0] = minf(rifle_tele[0], dur)
			elif w_id == "enemy_troop_at":
				at_tele[0] = minf(at_tele[0], dur)
	)
	w.fired.connect(func(rec: Dictionary) -> void:
		var sh := str(rec.get("shooter", ""))
		shots_by[sh] = int(shots_by.get(sh, 0)) + 1
	)
	await frames(1)

	# Step 3.5 s: verify staggered telegraphs & single shots from multiple individual troopers!
	for _i in 210:
		w.advance(DT)
	check(tele_times.size() >= 2, "multiple individual troopers telegraphed shots (%d)" % tele_times.size())
	if tele_times.size() >= 2:
		check(tele_times[1] - tele_times[0] >= EnemyTroopSquad.FIRE_STAGGER_GAP - 0.02,
			"trooper fire starts are staggered (dt=%.2f s)" % (tele_times[1] - tele_times[0]))
	check(rifle_tele[0] >= 0.54 or rifle_tele[0] == INF, "trooper_rifle telegraph >= 0.55 s")
	check(at_tele[0] >= 0.84 or at_tele[0] == INF, "trooper_at telegraph >= 0.85 s")
	check(shots_by.size() >= 2, "at least 2 distinct individual troopers fired (%s)" % str(shots_by))

	# Morale check: killing 2 of 4 troopers breaks morale & triggers survivor retreat/displacement!
	check(not ft.morale_broken, "morale intact with 4/4 troopers alive")
	troopers[0].apply_damage(40.0, "body", "player1")
	check(not ft.morale_broken, "morale intact after 1 loss (3/4 alive)")
	troopers[1].apply_damage(40.0, "body", "player1")
	check(ft.morale_broken, "morale breaks after >= 50% losses (2/4 down)")
	check(troopers[2]._retreating or troopers[3]._retreating, "surviving troopers enter retreat/regroup on morale break")

	# Host-only mech stomp crush: moving mech crushes ONLY the trooper it steps on!
	var stomp_cause := [""]
	troopers[2].destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: stomp_cause[0] = c)
	var tp2 := troopers[2].global_position
	p.global_position = tp2 + Vector3(0.0, 0.0, 3.8)
	w.advance(DT)
	p.global_position = tp2 + Vector3(0.0, 0.0, 0.4)
	w.advance(DT)
	check(troopers[2].destroyed(), "moving mech crushes individual trooper underfoot")
	eq(stomp_cause[0], "crushed", "stomp kill emits 'crushed' cause")
	check(not troopers[3].destroyed(), "stomping trooper 2 does NOT crush distant squadmate trooper 3")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _jump_pack_rooftop_ascent() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 3.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring

	var w := _world(false, ring)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)

	# Place a ground trooper right next to a low standable roof (<= 12 m) and rush it!
	var start_arc := Vector2(NAN, NAN)
	for b: Dictionary in plan.buildings:
		if bool(b.get("pillar", false)):
			continue
		var bc: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			if not bool(t.get("stand", false)) or str(t.get("kind", "")) == "plant":
				continue
			var y1 := float(t["y1"])
			var sz: Vector2 = t["size"]
			if y1 >= 3.0 and y1 <= EnemyTrooper.JUMP_MAX_ROOF_H and minf(sz.x, sz.y) >= 5.0:
				var tc := bc + (t["off"] as Vector2)
				for side_d: Vector2 in [Vector2(sz.x * 0.5 + 3.5, 0.0), Vector2(-sz.x * 0.5 - 3.5, 0.0),
						Vector2(0.0, sz.y * 0.5 + 3.5), Vector2(0.0, -sz.y * 0.5 - 3.5)]:
					var cand := tc + side_d
					if EnemySpawner.clear_of_buildings(plan, cand, 1.5, 0.0):
						start_arc = cand
						break
			if not is_nan(start_arc.x):
				break
		if not is_nan(start_arc.x):
			break
	check(not is_nan(start_arc.x), "found standable low roof for jump-pack test")
	if not is_nan(start_arc.x):
		var tr := EnemyTrooper.new()
		tr.configure("trooper_rifle", "jump_t0", w, sq, ring, 301)
		var pos_w := ring.arc_to_world(start_arc.x, start_arc.y, CityPlan.CURB_H)
		tr.up = ring.up_at(pos_w)
		tr.transform = Transform3D(ring.basis_at_arc(start_arc.y), pos_w)
		sq.add_enemy(tr)
		var p := _mock_player(w, ring.arc_to_world(start_arc.x, start_arc.y - 12.0, CityPlan.CURB_H))
		await frames(1)
		tr._trigger_scatter_or_jump(p.global_position, null)
		check(tr._jump_active, "individual trooper initiated jump-pack ascent onto adjacent low roof")
		for _i in 100:
			w.advance(DT)
		check(tr.on_roof and not tr._jump_active, "trooper landed cleanly on rooftop parapet")
		check(ring.height(tr.global_position) >= 2.8, "trooper elevated onto roof (h=%.1f m)" % ring.height(tr.global_position))
		p.queue_free()

	sq.queue_free()
	w.queue_free()
	city.queue_free()
	await frames(1)


func _coop_enemy_sync_individual_troopers() -> void:
	var hw := _world(false)
	var hsq := EnemySquad.new()
	add_child(hsq)
	hsq.setup(hw)
	var hsync := EnemySync.new()
	hsync.world = hw
	hsync.squad = hsq
	hsync.hosting = true
	hsq.enemy_spawned.connect(hsync._on_spawned)
	hsq.enemy_removed.connect(hsync._on_removed)
	hsq.enemy_event.connect(hsync._on_enemy_event)
	add_child(hsync)

	var cw := _world(false)
	var csq := EnemySquad.new()
	add_child(csq)
	csq.setup(cw)
	var csync := EnemySync.new()
	csync.world = cw
	csync.squad = csq
	csync.hosting = false
	add_child(csync)

	# Spawn a 4-man mixed fireteam on host; verify manifest spawns 4 distinct puppets on client!
	var ft := EnemyTroopSquad.make("net_sq", 0, Vector3(0.0, 0.0, -40.0), false)
	hsq.register_fireteam(ft)
	var host_troopers: Array[EnemyTrooper] = []
	for i in 4:
		var tr := EnemyTrooper.new()
		var kit := "trooper_at" if i == 3 else "trooper_rifle"
		tr.configure(kit, "net_t%d" % i, hw, hsq, null, 400 + i)
		tr.attach_fireteam(ft, i)
		tr.position = Vector3(float(i) * 5.0 - 7.5, 0.0, -40.0)
		hsq.add_enemy(tr)
		host_troopers.append(tr)
	await frames(1)

	var man := hsync.manifest()
	eq(man.size(), 4, "EnemySync manifest contains all 4 individual troopers")
	for entry in man:
		csync._spawn_puppet(entry)
	await frames(1)
	eq(csync.by_net.size(), 4, "client spawned 4 independent trooper puppets")

	# Kill trooper 1 on host -> replay discrete events -> only puppet 1 dies on client!
	hsync._queue.clear()
	host_troopers[1].apply_damage(40.0, "body", "player1")
	var q: Array = hsync._queue.duplicate()
	hsync._queue.clear()
	for it: Array in q:
		csync._apply_item(str(it[0]), int(it[1]), it[2])
	await frames(1)

	var dead_id := host_troopers[1].net_id
	var live_id := host_troopers[0].net_id
	check((csync.by_net[dead_id] as EnemyBase).destroyed(), "killed trooper puppet is destroyed on client")
	check(not (csync.by_net[live_id] as EnemyBase).destroyed(), "surviving squadmate puppet remains alive on client")
	eq(EnemySync.alive_per_deck(csq.enemies, 1)[0], 3, "client alive_per_deck reflects 3 surviving troopers")

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	hsq.queue_free()
	hw.queue_free()
	await frames(1)
