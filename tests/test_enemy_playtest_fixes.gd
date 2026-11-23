extends TestCase
## Comprehensive verification of all five playtest enemy upgrades:
##   1. Mounted turrets +40% fire rate (enemy_bolter, enemy_lance, enemy_rockets) with telegraphs >= 0.3 s.
##   2. Two-step per-deck last-enemy hunt / reveal + 120 s anti-soft-lock safety valve.
##   3. Falling aerial wrecks (EnemyDrone, EnemyGunship, EnemyDropDrone fall under gravity and settle on deck).
##   4. Scout Drone spotlight (hidden while idle/patrol/distant; visible & aimed at player when alerted <= 45 m)
##      + real CityStack ramp crossing on seed 4 (climbs cleanly over ramp without reversing patrol).
##   5. Multi-seed multi-deck anti-stuck & cover-corner building clearance + ground unstick recovery.

const DT := 1.0 / 60.0


func setup() -> void:
	_turret_fire_rate_upgrade()
	await _hunt_reveal_and_safety_valve()
	await _falling_aerial_wrecks()
	await _drone_spotlight_and_ramp_crossing()
	await _multi_deck_clearance_cover_and_unstick()
	await _deck_rehome_and_fell_out_cull()
	await _diegetic_beacons_and_status_bars()
	await _ai_perf_lod_and_deck_awake()
	finish()


func _world(physics: bool = false, ring: RingFrame = null) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 42
	w.use_physics = physics
	w.ring = ring
	add_child(w)
	return w


func _make_floor(y: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(240.0, 1.0, 240.0)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0.0, y - 0.5, 0.0)
	add_child(body)
	return body


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


# --- 1. Mounted Turrets +40% Fire Rate --------------------------------------------------------------------

func _turret_fire_rate_upgrade() -> void:
	var bolter := EnemyCatalog.weapon("enemy_bolter")
	var lance := EnemyCatalog.weapon("enemy_lance")
	var rockets := EnemyCatalog.weapon("enemy_rockets")
	near(float(bolter["burst_cooldown"]), 2.0, 0.02, "enemy_bolter burst_cooldown reduced +40% to 2.0 s")
	near(float(bolter["burst_interval"]), 0.17, 0.01, "enemy_bolter burst_interval reduced +40% to 0.17 s")
	check(float(bolter["telegraph"]) >= EnemyCatalog.MIN_TELEGRAPH, "enemy_bolter telegraph >= 0.3 s")
	near(float(lance["burst_cooldown"]), 3.0, 0.02, "enemy_lance burst_cooldown reduced +40% to 3.0 s")
	check(float(lance["telegraph"]) >= EnemyCatalog.MIN_TELEGRAPH, "enemy_lance telegraph >= 0.3 s")
	near(float(rockets["burst_cooldown"]), 3.29, 0.02, "enemy_rockets burst_cooldown reduced +40% to 3.29 s")
	near(float(rockets["burst_interval"]), 0.16, 0.01, "enemy_rockets burst_interval reduced +40% to 0.16 s")
	check(float(rockets["telegraph"]) >= EnemyCatalog.MIN_TELEGRAPH, "enemy_rockets telegraph >= 0.3 s")


# --- 2. Two-Step Per-Deck Hunt / Reveal + 120 s Anti-Soft-Lock Valve -------------------------------------

func _hunt_reveal_and_safety_valve() -> void:
	# Verify default production constants (never trigger above 3; conservative quiet + reveal delays).
	eq(EnemySquad.HUNT_MAX_REMAINING, 3, "HUNT_MAX_REMAINING == 3")
	near(EnemySquad.HUNT_QUIET_S, 75.0, 0.01, "HUNT_QUIET_S == 75.0 s")
	near(EnemySquad.REVEAL_HUNT_DELAY_S, 50.0, 0.01, "REVEAL_HUNT_DELAY_S == 50.0 s")
	near(EnemySquad.CULL_IDLE_S, 120.0, 0.01, "CULL_IDLE_S == 120.0 s")

	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	# Speed up thresholds deterministically for fast headless verification while testing every branch.
	sq.hunt_last_quiet_s = 0.5
	sq.reveal_hunt_delay_s = 1.0
	sq.cull_idle_s = 1.5

	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	# Case A: 12 enemies alive far away + long quiet (even AFTER deck contact!) -> NEVER hunt or reveal!
	var crowd: Array[EnemyBase] = []
	for i in 12:
		var st := EnemyStrider.new()
		st.configure("strider", "far_%02d" % i, w, sq, null, 50 + i)
		st.spawn_deck = 0
		st.position = Vector3(float(i - 6) * 14.0, 0.0, -240.0)
		st.sight_range = 35.0
		sq.add_enemy(st)
		crowd.append(st)
	sq.note_deck_activity(0)
	await frames(1)
	for _i in 180:  # 3.0 s >> 0.5 s + 1.0 s
		w.advance(DT)
	var any_crowd_hunt := false
	var any_crowd_rev := false
	for e in crowd:
		if e._hunting:
			any_crowd_hunt = true
		if e.revealed:
			any_crowd_rev = true
	check(not any_crowd_hunt, "12 alive enemies far away NEVER trigger last-enemy hunt during quiet travel")
	check(not any_crowd_rev, "12 alive enemies far away NEVER trigger reveal markers")
	sq.clear_enemies()
	await frames(1)

	# Case B: <= 3 enemies alive BEFORE any deck combat contact -> NEVER hunt or reveal!
	var mob := EnemyStrider.new()
	mob.configure("strider", "hunt_mob", w, sq, null, 1)
	mob.spawn_deck = 0
	mob.position = Vector3(0.0, 0.0, -180.0)
	mob.sight_range = 35.0
	sq.add_enemy(mob)

	var tur := EnemyTurret.new()
	tur.configure("turret", "hunt_tur", w, sq, null, 2)
	tur.spawn_deck = 0
	tur.position = Vector3(220.0, 0.0, 0.0)
	tur.sight_range = 35.0
	sq.add_enemy(tur)

	var revealed_ids: Array[String] = []
	var revealed_decks: Array[int] = []
	sq.stragglers_revealed.connect(func(deck: int, units: Array) -> void:
		revealed_decks.append(deck)
		for u in units:
			if u is EnemyBase:
				revealed_ids.append((u as EnemyBase).target_id)
	)
	var cull_cause := [""]
	tur.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: cull_cause[0] = c)
	await frames(1)

	for _i in 120:  # 2.0 s quiet before any deck contact
		w.advance(DT)
	check(not mob._hunting and not mob.revealed and not tur.revealed,
		"<= 3 enemies do NOT hunt or reveal before the crew has had combat contact on that deck")

	# Case C: 2 alive + 2 queued wave units on deck 0 (= 4 > 3) after contact -> still NO hunt/reveal!
	sq.note_deck_activity(0)
	sq._wave_decks["d0_w0"] = 0
	sq._wave_unreleased_pending["d0_w0"] = 2
	for _i in 120:
		w.advance(DT)
	check(not mob._hunting and not mob.revealed and not tur.revealed,
		"queued wave units count toward remaining (2 alive + 2 queued = 4 > 3 -> no hunt/reveal)")
	sq._wave_unreleased_pending.clear()

	# Case D: <= 3 remaining + deck engaged + hunt_last_quiet_s -> Step 1 hunt -> reveal_hunt_delay_s -> Step 2 reveal -> Step 3 cull!
	var mob_d0 := mob.global_position.distance_to(p.global_position)
	for _i in 45:  # 0.75 s > hunt_last_quiet_s (0.5 s)
		w.advance(DT)

	check(mob._hunting, "remaining mobile enemy entered Step 1 hunt mode when <= 3 left after contact")
	check(not mob.revealed and not tur.revealed,
		"neither hunter nor turret reveals immediately before reveal_hunt_delay_s")

	# Step another 1.25 s -> mobile hunter advances toward player AND unengaged stragglers reveal after reveal_hunt_delay_s (1.0 s)!
	for _i in 75:
		w.advance(DT)
	var mob_d1 := mob.global_position.distance_to(p.global_position)
	check(mob_d1 < mob_d0 - 5.0, "hunting mobile enemy actively closed distance toward player (%.1f m -> %.1f m)" % [mob_d0, mob_d1])
	check(mob.revealed, "unengaged mobile hunter revealed after reveal_hunt_delay_s")
	check(tur.revealed, "unengaged turret revealed after reveal_hunt_delay_s")
	check("hunt_mob" in revealed_ids and "hunt_tur" in revealed_ids, "stragglers_revealed signal fired for both")
	check(0 in revealed_decks, "stragglers_revealed reported deck 0")

	# Step another 1.8 s -> Step 3 anti-soft-lock safety valve culls unreachable revealed enemies (measured from reveal)!
	for _i in 110:
		w.advance(DT)
	check(tur.destroyed(), "unreachable revealed turret culled cleanly after cull_idle_s from reveal")
	eq(cull_cause[0], "timeout", "safety-valve cull reports cause 'timeout'")
	check(mob.destroyed(), "unreachable revealed hunter culled cleanly after cull_idle_s from reveal")
	eq(sq.alive_count(), 0, "alive_count() drops to 0 so MissionRules never soft-locks")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


# --- 3. Falling Aerial Wrecks (Drone, Gunship, Drop Ship) ------------------------------------------------

func _falling_aerial_wrecks() -> void:
	var floor_b := _make_floor(0.0)
	var w := _world(true)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	var drone := EnemyDrone.new()
	drone.configure("drone", "wreck_drone", w, sq, null, 1)
	drone.ai_mode = "idle"
	drone.position = Vector3(-16.0, 15.0, -20.0)
	sq.add_enemy(drone)

	var gunship := EnemyGunship.new()
	gunship.configure("gunship", "wreck_gunship", w, sq, null, 2)
	gunship.ai_mode = "idle"
	gunship.position = Vector3(0.0, 14.0, -20.0)
	sq.add_enemy(gunship)

	var dropship := EnemyDropDrone.new()
	dropship.configure("dropship", "wreck_dropship", w, sq, null, 3)
	dropship.ai_mode = "idle"
	dropship.position = Vector3(16.0, 18.0, -20.0)
	sq.add_enemy(dropship)
	await frames(2)

	drone.apply_damage(999.0, "hull", "player1")
	gunship.apply_damage(999.0, "hull", "player1")
	dropship.apply_damage(999.0, "hull", "player1")

	for e: EnemyBase in [drone, gunship, dropship]:
		check(e.destroyed(), "%s destroyed cleanly" % e.enemy_type)
		check(e._wreck_falling, "%s enters deterministic falling-wreck crash on death" % e.enemy_type)
		check(e.has_charred_hulk(), "%s keeps visible charred hull while crashing" % e.enemy_type)
		check(e.has_active_flame(), "%s trails active LowPolyFlame.Stream while crashing" % e.enemy_type)

	# Simulate 4.5 s of gravity + bounce + settle.
	for _i in 270:
		w.advance(DT)

	for e: EnemyBase in [drone, gunship, dropship]:
		var rest_r := e._wreck_ground_radius()
		check(not e._wreck_falling, "%s wreck finished falling and settled" % e.enemy_type)
		check(e.global_position.y >= 0.0 and e.global_position.y <= rest_r + 0.5,
			"%s wreck settled flush on floor (y=%.2f m, rest_r=%.2f m)" % [e.enemy_type, e.global_position.y, rest_r])

	sq.queue_free()
	w.queue_free()
	floor_b.queue_free()
	await frames(1)


# --- 4. Scout Drone Spotlight & Real CityStack Seed 4 Ramp Crossing --------------------------------------

func _drone_spotlight_and_ramp_crossing() -> void:
	# A. Spotlight gating & aiming.
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0.0, 0.0, 0.0))

	var drone := EnemyDrone.new()
	drone.configure("drone", "spot_drone", w, sq, null, 7)
	drone.position = Vector3(0.0, 15.0, -70.0)
	drone.rotation.y = 0.0  # facing away -> patrolling
	drone.set_patrol_points([Vector2(-20.0, -70.0), Vector2(20.0, -70.0)])
	sq.add_enemy(drone)
	await frames(1)

	w.advance(DT)
	check(not drone._cone_mi.visible, "drone spotlight hidden by default while patrolling")

	# Alert drone while player is distant (70 m > 45 m SPOTLIGHT_RANGE): spotlight must stay OFF!
	drone.rotation.y = PI
	for _i in 15:
		w.advance(DT)
	check(drone.is_alerted() and drone._has_los, "drone spotted player at 70 m")
	check(not drone._cone_mi.visible, "drone spotlight stays OFF when player is distant (70 m > 45 m)")

	# Move player close (24 m <= 45 m) while alerted with LOS -> spotlight turns ON and points directly at player!
	p.global_position = Vector3(drone.global_position.x, 0.0, drone.global_position.z + 24.0)
	w.advance(DT)
	check(drone._cone_mi.visible, "drone spotlight turns ON when alerted with LOS within 45 m")
	var cone_dir := (-drone._cone_mi.global_basis.y).normalized()
	var to_player := ((p.global_position + Vector3(0.0, 4.0, 0.0)) - drone._cone_mi.global_position).normalized()
	check(cone_dir.dot(to_player) > 0.96,
		"drone spotlight aims directly at player mech torso (dot=%.3f)" % cone_dir.dot(to_player))

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)

	# B. Real CityStack seed 4 ramp crossing (drone patrols across a real ramp viaduct without reversing!).
	var sec := SectionPlan.make({"seed": 4.0})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec, {"with_rig": false, "with_backdrop": false})
	await frames(2)

	# Find a real ramp connector and test on its bottom deck (where the ramp viaduct rises up toward the ceiling!).
	var ramp_conn := {}
	for c: Dictionary in sec.connectors:
		if str(c.get("kind", "")) == "ramp":
			ramp_conn = c
			break
	if check(not ramp_conn.is_empty(), "section seed 4 has a real ramp connector"):
		var bot_deck := int(ramp_conn["to"])
		var d_ring := stack.deck_ring(bot_deck)
		var d_plan := stack.decks[bot_deck].plan
		var r_x := (float(ramp_conn["x0"]) + float(ramp_conn["x1"])) * 0.5
		var s0 := float(ramp_conn["theta0"]) * sec.radius_of(bot_deck)
		var s1 := float(ramp_conn["theta1"]) * sec.radius_of(bot_deck)
		var mid_s := (s0 + s1) * 0.5
		var start_arc := Vector2(r_x - 22.0, mid_s)
		var goal_arc := Vector2(r_x + 22.0, mid_s)

		var rw := _world(true, d_ring)
		var rsq := EnemySquad.new()
		add_child(rsq)
		rsq.setup(rw, d_plan, d_ring)
		rsq.add_deck_nav(bot_deck, d_plan)

		var rd := EnemyDrone.new()
		rd.configure("drone", "ramp_drone", rw, rsq, d_ring, 9)
		rd.spawn_deck = bot_deck
		var start_w := d_ring.arc_to_world(start_arc.x, start_arc.y, 15.0)
		rd.up = d_ring.up_at(start_w)
		rd.transform = Transform3D(d_ring.basis_at_arc(start_arc.y), start_w)
		rd.set_patrol_points([goal_arc, Vector2(r_x + 36.0, mid_s)])
		rsq.add_enemy(rd)
		await frames(2)

		var max_alt := 15.0
		var crossed := false
		for _i in 360:   # 6 s patrol crossing
			rw.advance(DT)
			var a3 := d_ring.world_to_arc(rd.global_position)
			max_alt = maxf(max_alt, a3.z)
			if a3.x > r_x + 12.0:
				crossed = true
				break
		var end_arc := d_ring.world_to_arc(rd.global_position)
		check(crossed, "drone crossed real seed 4 ramp cleanly without reversing (x: %.1f -> %.1f, ramp_x=%.1f, peak_alt=%.1f m)" % [
			start_arc.x, end_arc.x, r_x, max_alt])

		rsq.queue_free()
		rw.queue_free()
		await frames(1)

	stack.queue_free()
	await frames(1)


# --- 5. Multi-Seed Multi-Deck Anti-Stuck, Cover Corners & Wall Unstick -----------------------------------

func _multi_deck_clearance_cover_and_unstick() -> void:
	# A. Multi-deck stack spawn clearance + EnemyTroopSquad._find_corner_cover rejects occupied corners.
	var sec := SectionPlan.make({"seed": 4.0})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec, {"with_rig": false, "with_backdrop": false})
	await frames(2)

	var w := _world(true, stack.deck_ring(0))
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, stack.decks[0].plan, stack.deck_ring(0))
	var bad_spawns := 0
	var bad_corners := 0
	for k in stack.decks.size():
		var dp := stack.decks[k].plan
		var dr := stack.deck_ring(k)
		sq.add_deck_nav(k, dp)
		eq(sq.deck_plan(k), dp, "EnemySquad.deck_plan(%d) returns deck %d's own CityPlan" % [k, k])
		var spawn_ref := dr.arc_to_world((dp.avenue_x().x + dp.avenue_x().y) * 0.5, dp.extent.position.y + 30.0, CityPlan.CURB_H)
		var list := EnemySpawner.spawn_all(dp, dr, spawn_ref, w, sq, 400 + k, false, 1, "d%d_" % k, k)
		for e in list:
			var a3 := dr.world_to_arc(e.position)
			if not EnemySpawner.clear_of_buildings(dp, Vector2(a3.x, a3.y), 1.5, a3.z + 0.25):
				bad_spawns += 1
			if e is EnemyTrooper and not (e as EnemyTrooper).on_roof:
				var corner := (e as EnemyTrooper)._find_independent_cover(e.position, spawn_ref)
				if not is_nan(corner.x):
					var ca := dr.world_to_arc(corner)
					if not EnemySpawner.clear_of_buildings(dp, Vector2(ca.x, ca.y), 1.6, 0.0):
						bad_corners += 1
	eq(bad_spawns, 0, "0 multi-deck spawns inside buildings across all stack decks")
	eq(bad_corners, 0, "0 EnemyTroopSquad cover corners inside neighboring buildings/pillars/cuts")

	sq.queue_free()
	w.queue_free()
	stack.queue_free()
	await frames(1)

	# B. Ground unit facing a solid wall must NOT oscillate at 60 Hz; unsticks cleanly around the obstacle!
	var fw := _world(true)
	var floor_b := _make_floor(0.0)
	var wall := StaticBody3D.new()
	var wcs := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(14.0, 6.0, 2.0)
	wcs.shape = wbox
	wall.add_child(wcs)
	wall.position = Vector3(0.0, 3.0, -10.0)
	add_child(wall)

	var fsq := EnemySquad.new()
	add_child(fsq)
	fsq.setup(fw)
	var st := EnemyStrider.new()
	st.configure("strider", "unstick_strider", fw, fsq, null, 19)
	st.position = Vector3(0.0, 0.0, 0.0)
	st.set_patrol_points([Vector2(0.0, -35.0), Vector2(0.0, 10.0)])
	fsq.add_enemy(st)
	await frames(2)

	var flips := 0
	var prev_sign := st._flank_sign
	for _i in 360:   # 6.0 s navigating past the 14 m wide wall
		fw.advance(DT)
		if st._flank_sign != prev_sign:
			flips += 1
			prev_sign = st._flank_sign
	check(flips <= 8, "committed _avoid_timer eliminates 60 Hz _flank_sign oscillation (flips=%d)" % flips)
	check(st.global_position.z < -12.0 or absf(st.global_position.x) > 5.0,
		"strider steered cleanly around blocking wall instead of pacing in place (pos=%s)" % str(st.global_position))

	fsq.queue_free()
	wall.queue_free()
	floor_b.queue_free()
	fw.queue_free()
	await frames(1)


# --- 6. Cross-Deck Dynamic Re-Homing & Fell-Out-of-Mission Culling ---------------------------------------

func _deck_rehome_and_fell_out_cull() -> void:
	var sec := SectionPlan.make({"seed": 4.0})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec, {"with_rig": false, "with_backdrop": false})
	await frames(2)

	var w := _world(false, stack.deck_ring(0))
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, stack.decks[0].plan, stack.deck_ring(0))
	sq.deck_of = stack.deck_at
	for k in stack.decks.size():
		sq.add_deck_nav(k, stack.decks[k].plan)
		sq._deck_rings[k] = stack.deck_ring(k)

	var hsync := EnemySync.new()
	hsync.world = w
	hsync.squad = sq
	hsync.hosting = true
	sq.enemy_spawned.connect(hsync._on_spawned)
	sq.enemy_event.connect(hsync._on_enemy_event)
	add_child(hsync)

	var cw := _world(false, stack.deck_ring(0))
	var csq := EnemySquad.new()
	add_child(csq)
	csq.setup(cw, stack.decks[0].plan, stack.deck_ring(0))
	for k in stack.decks.size():
		csq._deck_rings[k] = stack.deck_ring(k)
	var csync := EnemySync.new()
	csync.world = cw
	csync.squad = csq
	csync.ring = stack.deck_ring(0)
	csync.hosting = false
	add_child(csync)

	# 1. Enemy spawns on deck 0 -> mirror onto client puppet.
	var st := EnemyStrider.new()
	st.configure("strider", "fall_rehome_1", w, sq, stack.deck_ring(0), 77)
	st.spawn_deck = 0
	var p0 := stack.from_deck_arc(0, 0.0, 0.0, CityPlan.CURB_H)
	st.up = stack.deck_ring(0).up_at(p0)
	st.transform = Transform3D(stack.deck_ring(0).basis_at_arc(0.0), p0)
	sq.add_enemy(st)
	await frames(1)
	for entry in hsync.manifest():
		csync._spawn_puppet(entry)
	hsync._queue.clear()
	await frames(1)
	eq(EnemySync.alive_per_deck(sq.enemies, sec.deck_count)[0], 1, "initially counted on deck 0 (host)")
	eq(EnemySync.alive_per_deck(csq.enemies, sec.deck_count)[0], 1, "initially counted on deck 0 (client)")

	# 2. Enemy falls / is knocked onto deck 1 -> re-homes to deck 1 on host AND client; deck 0 clears to 0!
	var p1 := stack.from_deck_arc(1, 0.0, 0.0, CityPlan.CURB_H)
	st.global_position = p1
	for _i in 20:  # >= 0.25 s triggers 4 Hz _step_deck_rehome
		w.advance(DT)
	eq(st.spawn_deck, 1, "fallen enemy dynamically re-homed to deck 1 on host")
	eq(st.ring, stack.deck_ring(1), "re-homed enemy switched RingFrame to deck 1")
	var host_counts := EnemySync.alive_per_deck(sq.enemies, sec.deck_count)
	eq(host_counts[0], 0, "deck 0 count dropped to 0 so deck 0 can clear cleanly (host)")
	eq(host_counts[1], 1, "deck 1 count increased to 1 (host)")

	# Replay EnemySync queue -> client puppet mirrors spawn_deck == 1 too!
	for it: Array in hsync._queue:
		csync._apply_item(str(it[0]), int(it[1]), it[2])
	hsync._queue.clear()
	var client_counts := EnemySync.alive_per_deck(csq.enemies, sec.deck_count)
	eq(client_counts[0], 0, "client puppet left deck 0 (deck 0 count = 0)")
	eq(client_counts[1], 1, "client puppet re-homed to deck 1 (deck 1 count = 1)")

	# 3. Enemy knocked completely below the lowest deck (out of mission area) -> culled cleanly ("fell_out")!
	var fell_cause := [""]
	st.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: fell_cause[0] = c)
	var bottom_k := stack.decks.size() - 1
	st.global_position = stack.from_deck_arc(bottom_k, 0.0, 0.0, -24.0)
	for _i in 20:
		w.advance(DT)
	check(st.destroyed(), "enemy that fell completely out of the mission area is culled cleanly")
	eq(fell_cause[0], "fell_out", "out-of-area cull reports cause 'fell_out'")
	eq(sq.alive_count(), 0, "out-of-area enemy no longer counts toward any deck")

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	sq.queue_free()
	w.queue_free()
	stack.queue_free()
	await frames(1)


# --- 7. Diegetic-Only Indicators (No Overhead Diamonds, No Floating Beacons, Physical Reveal Flare) -------

func _diegetic_beacons_and_status_bars() -> void:
	# A. EnemyStatusBar: zero floating overhead diamonds or LOCATE tags; stays hidden on undamaged alerted/revealed units.
	var sb := EnemyStatusBar.new()
	add_child(sb)
	await frames(1)
	sb.refresh(1.0, 0.0, true, true, "", false, DT, true)
	check(not sb.visible, "EnemyStatusBar stays hidden on undamaged alerted/telegraphing/revealed enemy (no overhead diamond)")
	check(not sb._tag.visible, "no floating LOCATE tag over revealed enemy")
	sb.refresh(0.5, 0.0, true, false, "", false, DT, false)
	check(sb.visible and sb._bar_hp.visible, "EnemyStatusBar still shows compact HP bar when actually damaged")
	sb.queue_free()

	# B. EnemyTelegraphFx: keeps muzzle charge orb & Scout Drone Alert Beacon; hides comms relay ring & dropship ground ring;
	#    replaces floating UI reveal pillar with a physical rising signal flare + smoke puffs!
	var fx := EnemyTelegraphFx.new()
	add_child(fx)
	await frames(1)
	fx.trigger_relay_ring(Vector3.ZERO, Vector3.UP)
	fx.tick_only(0.1)
	check(not fx._beacon_ring.visible, "regular comms trigger_relay_ring does not show a floating ring")
	fx.show_telegraph(Vector3(0, 2, -10), Vector3.ZERO, 0.5, false, 0.85, true, DT)
	check(fx._shell.visible and fx._core.visible and not fx._beacon_ring.visible,
		"diegetic muzzle charge orb stays visible during telegraph with no floating ring")
	fx.show_beacon_flare(Vector3(0, 14, -30), Vector3.UP, 0.5, DT)
	check(fx._shell.visible and fx._beacon_ring.visible, "Scout Drone physical Alert Beacon flare & ring stay active")
	fx.show_drop_ring(Vector3(0, 11, -30), Vector3(0, 0, -30), Vector3.UP, 0.5, DT)
	check(fx._shell.visible and not fx._beacon_ring.visible, "dropship keeps bay glow but hides floating ground ring")
	fx.hide_telegraph()
	fx.show_reveal_flare(Vector3(0, 2, -20), Vector3.UP, 0.0)
	fx.show_reveal_flare(Vector3(0, 2, -20), Vector3.UP, 0.6)
	check(fx._flare_ember.visible and fx._flare_ember.global_position.y > 6.0,
		"revealed straggler launches physical rising signal flare (y=%.1f m)" % fx._flare_ember.global_position.y)
	fx.show_reveal_flare(Vector3(0, 2, -20), Vector3.UP, EnemyTelegraphFx.FLARE_LIFE + 0.5)
	check(not fx._flare_ember.visible, "physical signal flare fades out cleanly between launches")
	fx.queue_free()
	await frames(1)


# --- 8. AI Performance Invariants (deck_awake AssetTarget Skip, Empty-Scan Cadence, AI LOD & Profiling) ---

func _ai_perf_lod_and_deck_awake() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.deck_of = func(p: Vector3) -> int: return 1 if p.y > 40.0 else 0

	# A. Defend relay (AssetTarget, team == "player") on deck 1 must NOT wake deck 1!
	var relay := AssetTarget.new("relay_d1", 2.5, 6.0)
	relay.position = Vector3(0, 60.0, 0)
	add_child(relay)
	w.register(relay)

	var tr := EnemyTrooper.new()
	tr.configure("trooper_rifle", "asleep_trooper_1", w, sq, null, 7)
	tr.spawn_deck = 1
	tr.position = Vector3(12, 60.0, 0)
	sq.add_enemy(tr)
	await frames(1)

	check(not sq.deck_awake(1), "Defend AssetTarget alone does NOT wake empty deck 1")
	tr._scatter_cd = 2.0
	w.advance(DT)
	check(is_equal_approx(tr._scatter_cd, 2.0), "A1: asleep EnemyTrooper skips tick completely when deck is asleep")

	# B. Standing crew mech on deck 0 wakes deck 0, keeps deck 1 asleep; enemies > 150 m away LOD-throttle at 15 Hz.
	var p := CombatTarget.new()
	p.target_id = "crew_1"
	p.team = "player"
	p.mass_class = "static"
	p.set_max_hp({"torso": 200.0})
	p.add_hit_sphere("torso", Vector3(0, 3.0, 0), 2.5)
	p.position = Vector3(0, 0, 0)
	add_child(p)
	w.register(p)

	var far_e := EnemyStrider.new()
	far_e.configure("strider", "far_lod_1", w, sq, null, 11)
	far_e.spawn_deck = 0
	far_e.position = Vector3(220.0, 0.0, 0.0)   # 220 m > 150 m LOD threshold, out of sight range
	far_e.set_patrol_points([Vector2(220.0, 0.0), Vector2(220.0, 40.0)])
	sq.add_enemy(far_e)

	var near_e := EnemyStrider.new()
	near_e.configure("strider", "near_prof_1", w, sq, null, 13)
	near_e.spawn_deck = 0
	near_e.position = Vector3(45.0, 0.0, 0.0)   # within 150 m & sight range
	sq.add_enemy(near_e)
	await frames(1)

	check(sq.deck_awake(0), "standing crew mech wakes deck 0")
	check(not sq.deck_awake(1), "deck 1 stays asleep even with crew mech on deck 0 + AssetTarget on deck 1")

	# Step 12 frames with CombatWorld.profiling enabled -> check A2/A3 empty-scan cadence, A6 LOD skips, A7 prof keys.
	CombatWorld.prof.clear()
	CombatWorld.prof_samples.clear()
	CombatWorld.profiling = true
	var lod_skips := 0
	var lod_ticks := 0
	for _i in 12:
		w.advance(DT)
		if far_e._lod_dt > 0.0:
			lod_skips += 1
		else:
			lod_ticks += 1
	CombatWorld.profiling = false

	eq(lod_skips, 9, "A6: enemy > 150 m away skips 9 of 12 ticks (15 Hz LOD)")
	eq(lod_ticks, 3, "A6: enemy > 150 m away executes 3 of 12 ticks with dt*4")
	check(far_e._perc_valid and far_e._cached_target == null,
		"A2/A3: empty perception scan stays cached (_perc_valid=true) instead of rescanning every frame")

	# A6 safety: enemy > 150 m away in STATE_TELEGRAPH is NEVER LOD-skipped!
	far_e.ai_state = EnemyBase.STATE_TELEGRAPH
	far_e._lod_dt = 0.0
	w.advance(DT)
	check(is_equal_approx(far_e._lod_dt, 0.0), "A6: enemy in STATE_TELEGRAPH is never LOD-throttled")

	# A4: zero-allocation _target_aim_center populates CombatTarget world sphere cache cleanly.
	var aim_c := near_e._target_aim_center(p)
	check(aim_c.distance_to(Vector3(0, 3.0, 0)) < 0.01 and p.wc_n == 1,
		"A4: _target_aim_center uses CombatTarget.refresh_world_cache (wc_centers[0])")

	# A7: CombatWorld.profiling recorded AI phase keys.
	check(CombatWorld.prof.has("ai.acquire"), "A7: CombatWorld.prof records ai.acquire")
	check(CombatWorld.prof.has("ai.visuals"), "A7: CombatWorld.prof records ai.visuals")
	check(CombatWorld.prof.has("ai.steer"), "A7: CombatWorld.prof records ai.steer")
	CombatWorld.prof.clear()
	CombatWorld.prof_samples.clear()

	relay.queue_free()
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)
