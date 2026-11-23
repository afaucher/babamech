extends TestCase
## Exo-Trooper Squads Phase 1 verification (docs/design/enemy-troop-squads.md):
##   1. Individual trooper kills (t0..t3) reduce active shooters without wiping squad; all 4 dead -> squad destroyed.
##   2. Splash wipes tightly clustered squads; spread-out anti-cluster formations survive outside blast radius & scatter.
##   3. Street corner cover selection, peek-to-fire telegraph (1 shot/peeking trooper), and duck-back reload cycle.
##   4. Rooftop AT squad parapet firing + street squad jump-pack ascent onto adjacent standable low roof (<= 12 m).
##   5. Host-only mech stomp (3.0 m) crushes troopers underfoot & triggers scatter; client puppet never stomps.
##   6. Phase 2 hook deploy_from_air() jet-drop descent onto target deck.
##   7. Co-op EnemySync manifest & puppet_apply round-trip for troop_squad & troop_roof (per-trooper downed state).

const DT := 1.0 / 60.0


func setup() -> void:
	await _individual_kills_and_firepower_degradation()
	await _splash_cluster_wipe_vs_spread_and_scatter()
	await _corner_cover_peek_fire_duck_and_jump_pack()
	await _rooftop_at_squad_and_mech_stomp()
	await _deploy_from_air_and_coop_sync()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 55
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


func _individual_kills_and_firepower_degradation() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	var tr := EnemyTroopSquad.new()
	tr.configure("troop_squad", "troops_1", w, sq, null, 1)
	tr.position = Vector3(0.0, 0.0, -55.0)
	tr.rotation.y = PI
	sq.add_enemy(tr)
	await frames(1)

	eq(tr.alive_trooper_count(), 4, "troop_squad starts with 4 alive troopers")
	eq(tr.world_spheres().size(), 4, "4 alive hit spheres initially")
	near(tr.core_hp_ratio(), 1.0, 0.001, "aggregate squad HP ratio = 1.0")

	# Precision kill of t0 does NOT kill the squad!
	tr.apply_damage(35.0, "t0", p.target_id)
	check(not tr.destroyed(), "killing t0 does NOT destroy the troop squad")
	eq(tr.alive_trooper_count(), 3, "3 troopers remain after t0 dies")
	eq(tr.world_spheres().size(), 3, "dead trooper t0 removed from live world_spheres()")
	near(tr.core_hp_ratio(), 0.75, 0.01, "aggregate HP drops cleanly to 0.75 (3/4)")

	# Kill t1 and t2 -> 1 survivor left -> verify a single volley only fires 1 shot!
	tr.apply_damage(35.0, "t1", p.target_id)
	tr.apply_damage(35.0, "t2", p.target_id)
	eq(tr.alive_trooper_count(), 1, "1 survivor remains")
	check(not tr.destroyed(), "squad still alive with 1 survivor")

	var shots := [0]
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == tr.target_id:
			shots[0] += 1
	)
	for _i in 200:
		w.advance(DT)
		if shots[0] >= 1 and tr.ai_state == EnemyBase.STATE_COOLDOWN:
			break
	eq(shots[0], 1, "1 surviving trooper fires exactly 1 single shot per peek volley")

	# Kill final survivor t3 -> squad destroyed cleanly!
	var cause := [""]
	tr.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: cause[0] = c)
	tr.apply_damage(35.0, "t3", p.target_id)
	check(tr.destroyed() and not tr.is_hittable(), "killing all 4 troopers destroys the squad")
	eq(cause[0], "squad_wiped", "squad wipe emits squad_wiped cause")
	eq(tr.world_spheres().size(), 0, "wiped squad has 0 live hit spheres")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _splash_cluster_wipe_vs_spread_and_scatter() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# A. Tightly clustered squad (1.5 m spacing -> total width 4.5 m): one Mortar blast (R = 8.0 m, dmg = 90) wipes ALL 4!
	var cl := EnemyTroopSquad.new()
	cl.configure("troop_squad", "troops_cluster", w, sq, null, 2)
	cl.position = Vector3(0.0, 0.0, -50.0)
	cl.rotation.y = PI
	cl.set_formation_spacing(1.5, 4.0)
	sq.add_enemy(cl)
	await frames(1)

	var blast_rec := Combat.fire_record(p.target_id, 1, "mortar", "mortar", Vector3.ZERO, cl.global_position, w.now, 0, 0.0)
	var mortar_st := {"splash_radius": 8.0, "splash_damage": 90.0, "splash_knockback": 4.0, "splash_lift": 1.0}
	w.splash(blast_rec, mortar_st, cl.global_position)
	check(cl.destroyed() and cl.alive_trooper_count() == 0,
		"one explosive splash blast wipes tightly clustered 4-man squad (alive=%d)" % cl.alive_trooper_count())

	# B. Anti-cluster spread-out squad (5.5 m spacing -> span 16.5 m): small rocket splash (R = 4.2 m) on t0
	# kills/chunks t0 while distant troopers t2 & t3 survive unscathed AND trigger scatter!
	var sp_sq := EnemyTroopSquad.new()
	sp_sq.configure("troop_squad", "troops_spread", w, sq, null, 3)
	sp_sq.position = Vector3(30.0, 0.0, -60.0)
	sp_sq.rotation.y = PI
	sp_sq.set_formation_spacing(5.5, 9.0)
	sq.add_enemy(sp_sq)
	await frames(1)

	var t0_pos := sp_sq.trooper_world_pos("t0")
	var rocket_rec := Combat.fire_record(p.target_id, 1, "rockets", "rockets", Vector3.ZERO, t0_pos, w.now, 1, 0.0)
	var rocket_st := {"splash_radius": 4.2, "splash_damage": 45.0, "splash_knockback": 2.0, "splash_lift": 0.5}
	w.splash(rocket_rec, rocket_st, t0_pos)
	check(not sp_sq.destroyed(), "spread-out squad survives localized rocket splash on edge trooper")
	check(float(sp_sq.hp["t0"]) <= 0.0, "edge trooper t0 inside blast center killed")
	check(float(sp_sq.hp["t2"]) > 29.0 and float(sp_sq.hp["t3"]) > 29.0,
		"distant spread troopers t2 & t3 outside blast radius take 0 splash damage")
	check(sp_sq._scatter_count >= 1, "surviving spread troopers triggered scatter response on splash hit")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _corner_cover_peek_fire_duck_and_jump_pack() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 2.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring

	var w := _world(true)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)

	# 1. Peek -> 3 single shots -> duck cycle on full 4-man street squad.
	var p_pos := ring.arc_to_world(0.0, -56.0, CityPlan.CURB_H)
	var p := _mock_player(w, p_pos)
	var tr := EnemyTroopSquad.new()
	tr.configure("troop_squad", "troops_peek", w, sq, ring, 4)
	var tr_pos := ring.arc_to_world(0.0, 0.0, CityPlan.CURB_H)
	tr.up = ring.up_at(tr_pos)
	var base_b := ring.basis_at_arc(0.0)
	tr.transform = Transform3D(Basis(base_b.y, PI) * base_b, tr_pos)  # face -s toward player at s=-56
	sq.add_enemy(tr)

	var rifle_shots: Array[Vector3] = []
	var saw_tele := [false]
	var tele_dur := [0.0]
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == tr.target_id:
			rifle_shots.append(rec["origin"] as Vector3)
	)
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if enemy == tr and kind == "telegraph_started":
			saw_tele[0] = true
			tele_dur[0] = float(pay.get("duration", 0.0))
	)
	await frames(2)

	var saw_peek_up := false
	var saw_duck_after := false
	for _i in 360:
		w.advance(DT)
		if tr.ai_state == EnemyBase.STATE_TELEGRAPH and tr._peek_frac > 0.4:
			saw_peek_up = true
		if rifle_shots.size() >= 3 and tr._cooldown > 0.0 and tr._peek_frac < 0.2:
			saw_duck_after = true
			break
	check(saw_tele[0] and tele_dur[0] >= 0.59, "troop_squad telegraphs >= 0.60 s before volley (%.2f s)" % tele_dur[0])
	check(saw_peek_up, "troopers rise/lean out during peek telegraph")
	check(rifle_shots.size() >= 3, "full 4-man squad fires 3 staggered single shots (got %d)" % rifle_shots.size())
	if rifle_shots.size() >= 2:
		check(rifle_shots[0].distance_to(rifle_shots[1]) > 1.0,
			"each peeking trooper fires from its own distinct world muzzle position")
	check(saw_duck_after, "troopers duck back behind cover after completing their single-shot volley")

	# 2. Street squad jump-pack ascent onto adjacent standable low roof (<= 12 m) when rushed by player mech!
	var low_b := {}
	for b: Dictionary in plan.buildings:
		if bool(b.get("pillar", false)):
			continue
		for t: Dictionary in b.get("tiers", []):
			if bool(t.get("stand", false)) and str(t.get("kind", "")) != "plant":
				var y1 := float(t["y1"])
				var sz: Vector2 = t["size"]
				if y1 >= 3.0 and y1 <= EnemyTroopSquad.JUMP_MAX_ROOF_H and minf(sz.x, sz.y) >= 6.0:
					low_b = {"b": b, "t": t}
					break
		if not low_b.is_empty():
			break
	check(not low_b.is_empty(), "city district has a standable low roof (<= 12 m) for jump-pack test")
	if not low_b.is_empty():
		var b: Dictionary = low_b["b"]
		var t: Dictionary = low_b["t"]
		var bc: Vector2 = b["center"]
		var tc := bc + (t["off"] as Vector2)
		var half: Vector2 = (t["size"] as Vector2) * 0.5
		var street_arc := Vector2(tc.x - half.x - 4.5, tc.y)
		var jp := EnemyTroopSquad.new()
		jp.configure("troop_squad", "troops_jump", w, sq, ring, 5)
		var jp_w := ring.arc_to_world(street_arc.x, street_arc.y, CityPlan.CURB_H)
		jp.up = ring.up_at(jp_w)
		jp.transform = Transform3D(ring.basis_at_arc(street_arc.y), jp_w)
		sq.add_enemy(jp)
		await frames(1)
		# Rush player within 16 m along the street -> triggers 1.4 s jump-pack ascent onto the adjacent roof!
		p.global_position = ring.arc_to_world(street_arc.x, street_arc.y - 16.0, CityPlan.CURB_H)
		sq.report_sighting(jp, p, p.global_position + p.up * 4.0)
		jp.receive_squad_alert(p)
		for _i in 180:
			w.advance(DT)
			if jp._on_roof:
				break
		check(jp._jump_count >= 1 and jp._on_roof,
			"rushed street squad executed jump-pack ascent onto adjacent low roof (jumps=%d, on_roof=%s)" % [jp._jump_count, str(jp._on_roof)])
		var end_h := ring.height(jp.global_position)
		check(end_h >= 2.8, "jump-packed squad landed cleanly on roof elevation (h=%.1f m)" % end_h)

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	city.queue_free()
	await frames(1)


func _rooftop_at_squad_and_mech_stomp() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# 1. Rooftop Anti-Armor Team fires enemy_troop_at at 150 m with >= 0.85 s telegraph.
	var roof_sq := EnemyTroopSquad.new()
	roof_sq.configure("troop_roof", "troop_roof_1", w, sq, null, 6)
	roof_sq.position = Vector3(0.0, 10.0, -150.0)
	roof_sq.rotation.y = PI
	sq.add_enemy(roof_sq)

	var at_shots := [0]
	var at_tele := [0.0]
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == roof_sq.target_id and str(rec.get("weapon", "")) == "enemy_troop_at":
			at_shots[0] += 1
	)
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if enemy == roof_sq and kind == "telegraph_started":
			at_tele[0] = float(pay.get("duration", 0.0))
	)
	await frames(1)
	roof_sq.receive_squad_alert(p)
	for _i in 200:
		w.advance(DT)
		if at_shots[0] >= 2:
			break
	check(at_tele[0] >= 0.84, "troop_roof AT telegraph >= 0.85 s (%.2f s)" % at_tele[0])
	eq(at_shots[0], 2, "troop_roof fires 2 staggered shoulder AT rockets per peek volley")

	# 2. Mech Stomp (host-only): moving player walks within 3.0 m of t0 -> crushes t0 immediately & scatters survivors!
	var st_sq := EnemyTroopSquad.new()
	st_sq.configure("troop_squad", "troops_stomp", w, sq, null, 7)
	st_sq.position = Vector3(40.0, 0.0, -20.0)
	st_sq.ai_mode = "idle"
	st_sq.set_formation_spacing(5.0, 9.0)
	sq.add_enemy(st_sq)

	# Client puppet squad at same spot must NEVER self-stomp!
	var pup_sq := EnemyTroopSquad.new()
	pup_sq.configure("troop_squad", "troops_puppet_stomp", w, sq, null, 8)
	pup_sq.puppet = true
	pup_sq.position = Vector3(40.0, 0.0, -20.0)
	pup_sq.set_formation_spacing(5.0, 9.0)
	sq.add_enemy(pup_sq)
	await frames(1)

	var t0_spot := st_sq.trooper_world_pos("t0")
	p.global_position = t0_spot + Vector3(0.0, 0.0, 4.0)
	w.advance(DT)  # seed _player_prev_pos
	p.global_position = t0_spot + Vector3(0.0, 0.0, 0.8)  # moving ~192 m/s into 0.8 m of t0
	w.advance(DT)
	check(float(st_sq.hp["t0"]) <= 0.0 and st_sq._stomped_count >= 1,
		"moving player mech stomps trooper t0 underfoot (stomped=%d)" % st_sq._stomped_count)
	check(st_sq._scatter_count >= 1, "surviving squadmates scatter after a teammate is stomped")
	eq(pup_sq.alive_trooper_count(), 4, "client puppet squad NEVER runs host mech-stomp logic")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _deploy_from_air_and_coop_sync() -> void:
	var hw := _world(false)
	var hsq := EnemySquad.new()
	add_child(hsq)
	hsq.setup(hw)
	var hsync := EnemySync.new()
	hsync.world = hw
	hsync.squad = hsq
	hsync.hosting = true
	add_child(hsync)

	# 1. deploy_from_air() descends cleanly over 0.8 s onto landing_pos and enters STATE_ENGAGE.
	var drop_sq := EnemyTroopSquad.new()
	drop_sq.configure("troop_squad", "sync_troop_drop", hw, hsq, null, 9)
	hsq.add_enemy(drop_sq)
	await frames(1)
	var land_pt := Vector3(12.0, 0.0, -40.0)
	drop_sq.deploy_from_air(land_pt, 1)
	check(drop_sq._drop_active and drop_sq.global_position.y > 9.0, "deploy_from_air starts squad 11 m aloft")
	eq(drop_sq.spawn_deck, 1, "deploy_from_air assigns target spawn_deck")
	for _i in 65:
		hw.advance(DT)
	check(not drop_sq._drop_active and drop_sq.global_position.distance_to(land_pt) < 0.25,
		"deploy_from_air lands cleanly at landing_pos in 0.8 s (err=%.2f m)" % drop_sq.global_position.distance_to(land_pt))

	# 2. Co-op EnemySync manifest + puppet_apply round-trip (individual trooper HP + downed visuals on client).
	var roof_e := EnemyTroopSquad.new()
	roof_e.configure("troop_roof", "sync_troop_roof", hw, hsq, null, 10)
	roof_e.position = Vector3(-16.0, 9.0, -42.0)
	hsq.add_enemy(roof_e)
	hsync._adopt(drop_sq)
	hsync._adopt(roof_e)
	await frames(1)

	# Kill t0 and t2 on host BEFORE streaming puppet_state to client!
	drop_sq.apply_damage(40.0, "t0", "player1")
	drop_sq.apply_damage(40.0, "t2", "player1")

	var man := hsync.manifest()
	eq(man.size(), 2, "EnemySync manifest contains both troop_squad and troop_roof")

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

	eq(csync.by_net.size(), 2, "client EnemySync spawned both troop squad puppets")
	var pup_drop := csync.by_net[drop_sq.net_id] as EnemyTroopSquad
	check(pup_drop != null and pup_drop.puppet, "spawned troop_squad is a client puppet")
	pup_drop.puppet_apply(drop_sq.puppet_state())
	pup_drop.puppet_tick(DT)
	eq(pup_drop.alive_trooper_count(), 2, "client puppet mirrors exact surviving trooper count (2/4)")
	check(bool(pup_drop._trooper_down.get("t0", false)) and bool(pup_drop._trooper_down.get("t2", false)),
		"client puppet knocks down killed troopers t0 and t2")
	check(not bool(pup_drop._trooper_down.get("t1", false)) and not bool(pup_drop._trooper_down.get("t3", false)),
		"client puppet keeps surviving troopers t1 and t3 upright")

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	hsq.queue_free()
	hw.queue_free()
	await frames(1)
