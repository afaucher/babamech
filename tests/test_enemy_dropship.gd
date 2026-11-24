extends TestCase
## Carrier Drop Ship ("dropship", EnemyDropDrone) Phase 2 verification (docs/design/enemy-troop-squads.md §6):
##   1. Watertight placeholder meshes + art-mesh deferral, hull (140 HP) & rotors (55 HP, 1.5x crit "rotor_failure").
##   2. Approach -> Descend -> 1.5 s Drop Telegraph (kind = "dropship") -> deploys 1 EnemyTroopSquad (troop_squad on
##      street, troop_roof on roof) via deploy_from_air(), then climbs out & despawns cleanly (remove_enemy called).
##   3. Counterplay: shooting down Drop Ship before 1.5 s finishes destroys carried squad mid-air (0 troopers spawned!).
##   4. Scout Drone beacon triggers EnemySquad.request_dropship() obeying strict per-deck cap (1 solo) & living-defender
##      guard, and never runs on client puppets.
##   5. Co-op EnemySync replicates dynamic "add" (Drop Ship + deployed EnemyTroopSquad) and "gone" (exfiltrated Drop Ship).
##   6. Real stack missions (seeds ROUND_TRIP_SEEDS, every deck): a full round trip through the deck's air doors (created
##      hidden in a recess, not hittable until its door is passable, out through the opening, fly in, drop, fly out, in
##      through an air door, removed inside its recess, the door shut again afterwards), the hull box never touching the
##      collision world (buildings, towers, pillars, park columns, walls, ceiling, the door frames; mechs aside), never
##      outside the deck's walls (but in a door) or above its ceiling, through the wall plane only while that door is
##      passable; the squad lands on valid street ground. Deck 0 again with the air doors switched off (the fallback).

const DT := 1.0 / 60.0
const TEST_TIMEOUT := 900
const ROUND_TRIP_SEEDS := [1, 4, 7, 403112]
const ROUND_TRIP_LIMIT := 150.0   ## game s per flight


func setup() -> void:
	await _meshes_components_and_counterplay_cancel()
	await _approach_telegraph_deploy_and_exfil()
	await _rooftop_drop_and_scout_drone_beacon_cap()
	await _multi_seed_stack_reachable_drop_zones()
	await _coop_enemy_sync_add_and_gone()
	await _stack_round_trips_clear()
	finish()


func _init() -> void:
	timeout_sec = float(TEST_TIMEOUT)


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 66
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


func _meshes_components_and_counterplay_cancel() -> void:
	for part: String in ["dropship_hull", "dropship_rotors", "dropship_bay"]:
		var m := EnemyDropDrone.placeholder_mesh(part)
		check(m != null and m.get_surface_count() > 0, "EnemyDropDrone placeholder %s builds" % part)
		check(not EnemyDropDrone.has_art_mesh(part) or EnemyMeshes.mesh(part).get_surface_count() > 0,
			"has_art_mesh check for %s is valid" % part)

	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	var ds := EnemyDropDrone.new()
	ds.configure("dropship", "drop_cancel_1", w, sq, null, 1)
	ds.position = Vector3(0.0, 12.0, -40.0)
	ds.configure_drop(Vector3(0.0, 0.0, -40.0), false, 6.0, Vector3(30.0, 28.0, -80.0))
	sq.add_enemy(ds)
	await frames(1)

	eq(ds.comp_order(), ["hull", "rotors"], "dropship has hull and rotors components")
	eq(ds.world_spheres().size(), 4, "dropship has 4 hit spheres (2 hull + 2 rotors)")
	near(float(ds.max_hp["hull"]), 140.0, 0.01, "hull HP = 140")
	near(float(ds.max_hp["rotors"]), 55.0, 0.01, "rotors HP = 55")

	var cause := [""]
	var cancelled := [false]
	var deployed := [0]
	ds.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: cause[0] = c)
	ds.troops_deployed.connect(func(_d: EnemyDropDrone, ts: Array) -> void: deployed[0] += ts.size())
	sq.enemy_event.connect(func(kind: String, enemy: Node, _pay: Dictionary) -> void:
		if enemy == ds and kind == "telegraph_cancelled":
			cancelled[0] = true
	)

	# Advance until Drop Ship enters its 1.5 s drop-bay telegraph, then snipe its rotors weak point mid-telegraph!
	var saw_tele := false
	for _i in 180:
		w.advance(DT)
		if ds.ai_state == EnemyBase.STATE_TELEGRAPH:
			saw_tele = true
			for _j in 30:
				w.advance(DT)  # 0.5 s into 1.5 s drop bay window
			# 38 raw * 1.5x = 57 >= 55 -> critical rotor_failure kill!
			ds.apply_damage(38.0, "rotors", "player1")
			break
	check(saw_tele, "dropship reached STATE_TELEGRAPH over drop zone")
	check(ds.destroyed(), "sniping rotors weak point (38 raw @ 1.5x) destroys dropship")
	eq(cause[0], "rotor_failure", "rotors kill emits rotor_failure cause")
	check(cancelled[0], "killing dropship mid-telegraph cancels drop telegraph")
	for _i in 120:
		w.advance(DT)
	eq(deployed[0], 0, "destroying dropship before 1.5 s cancels troop deployment (0 deployed)")
	eq(sq.enemies.size(), 1, "no troop squad was added to squad after mid-air shootdown")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _approach_telegraph_deploy_and_exfil() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	var ds := EnemyDropDrone.new()
	ds.configure("dropship", "drop_street_1", w, sq, null, 2)
	ds.spawn_deck = 0
	ds.position = Vector3(-24.0, 20.0, -76.0)
	var drop_pt := Vector3(0.0, 0.0, -40.0)
	var exfil_pt := Vector3(28.0, 28.0, -80.0)
	ds.configure_drop(drop_pt, false, 6.0, exfil_pt)
	sq.add_enemy(ds)

	var tele_kind := [""]
	var tele_dur := [0.0]
	var deployed_ref := [null]
	var removed := [false]
	var ds_shots := [0]
	sq.enemy_event.connect(func(kind: String, enemy: Node, pay: Dictionary) -> void:
		if enemy == ds and kind == "telegraph_started":
			tele_kind[0] = str(pay.get("kind", ""))
			tele_dur[0] = float(pay.get("duration", 0.0))
	)
	sq.enemy_removed.connect(func(e: EnemyBase) -> void:
		if e == ds:
			removed[0] = true
	)
	ds.troops_deployed.connect(func(_d: EnemyDropDrone, ts: Array) -> void:
		deployed_ref[0] = ts
	)
	w.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == ds.target_id:
			ds_shots[0] += 1
	)
	await frames(1)

	# Step full lifecycle: Approach (~2.5 s) -> Descend (~1.0 s) -> Telegraph (1.5 s) -> Deploy -> Exfil (<= 4.5 s).
	for _i in 660:  # 11 s max
		w.advance(DT)
		if removed[0]:
			break
	eq(tele_kind[0], "dropship", "dropship emits dropship telegraph kind")
	check(tele_dur[0] >= 1.49, "dropship telegraph duration >= 1.5 s (%.2f s)" % tele_dur[0])
	eq(ds_shots[0], 0, "unarmed dropship never fires weapons")
	var deployed_list: Array = deployed_ref[0] if deployed_ref[0] is Array else []
	check(deployed_list.size() >= 3 and deployed_list.size() <= 5,
		"dropship deployed a variable fireteam of 3-5 individual troopers (%d)" % deployed_list.size())
	var shared_ft: EnemyTroopSquad = null
	for raw_t: Variant in deployed_list:
		var tr := raw_t as EnemyTrooper
		check(tr != null and is_instance_valid(tr), "deployed member is a live individual EnemyTrooper")
		if tr != null:
			check(tr.enemy_type in ["trooper_rifle", "trooper_at"], "deployed trooper has valid kit (%s)" % tr.enemy_type)
			check(not tr.on_roof, "street drop trooper is ground-mobile")
			check(tr.global_position.distance_to(drop_pt) < 14.0,
				"deployed trooper landed near drop zone (err=%.2f m)" % tr.global_position.distance_to(drop_pt))
			if shared_ft == null:
				shared_ft = tr.fireteam
			else:
				eq(tr.fireteam, shared_ft, "deployed troopers share one EnemyTroopSquad fireteam controller")
	check(removed[0], "empty dropship climbed out and cleanly removed itself after exfil")
	check(not ds in sq.enemies, "exfiltrated dropship is no longer in squad.enemies (never blocks MissionRules)")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _rooftop_drop_and_scout_drone_beacon_cap() -> void:
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 3.0, "walls": 1.0})
	var plan := city.plan
	var ring := city.ring

	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, plan, ring)
	sq.max_drops_per_deck = 1

	# 1. Explicit rooftop drop deploys rooftop EnemyTrooper fireteam (on_roof = true).
	var roof_ds := EnemyDropDrone.new()
	roof_ds.configure("dropship", "drop_roof_1", w, sq, ring, 3)
	var r_drop := ring.arc_to_world(0.0, 20.0, 9.5)
	roof_ds.up = ring.up_at(r_drop)
	roof_ds.transform = Transform3D(ring.basis_at_arc(20.0), r_drop + roof_ds.up * 11.5)
	roof_ds.configure_drop(r_drop, true, 5.2, ring.arc_to_world(20.0, 90.0, 28.0))
	sq.add_enemy(roof_ds)
	var r_deployed := [null]
	roof_ds.troops_deployed.connect(func(_d: EnemyDropDrone, ts: Array) -> void: r_deployed[0] = ts)
	await frames(1)
	for _i in 180:
		w.advance(DT)
		if r_deployed[0] != null:
			break
	var rlist: Array = r_deployed[0] if r_deployed[0] is Array else []
	check(rlist.size() >= 2 and (rlist[0] as EnemyTrooper).on_roof, "rooftop drop deploys on_roof EnemyTrooper fireteam (%d)" % rlist.size())
	# Remove finished dropship so we can cleanly test Scout Drone beacon cap below.
	sq.remove_enemy(roof_ds)
	w.unregister(roof_ds)
	roof_ds.queue_free()
	await frames(1)

	# 2. Scout Drone beacon triggers request_dropship() obeying strict per-deck cap (1 solo).
	var p := _mock_player(w, ring.arc_to_world(0.0, -50.0, CityPlan.CURB_H))
	var drone := EnemyDrone.new()
	drone.configure("drone", "scout_caller", w, sq, ring, 4)
	var d_pos := ring.arc_to_world(0.0, 10.0, 15.0)
	drone.up = ring.up_at(d_pos)
	drone.transform = Transform3D(Basis(ring.basis_at_arc(10.0).y, PI) * ring.basis_at_arc(10.0), d_pos)
	sq.add_enemy(drone)
	await frames(1)

	# Let drone spot player and complete its 0.65 s beacon -> spawns exactly 1 Drop Ship!
	for _i in 180:
		w.advance(DT)
		if drone._beacon_count >= 1:
			break
	check(drone._beacon_count >= 1, "scout drone completed Alert Beacon")
	eq(int(sq._deck_drops.get(0, 0)), 1, "scout drone beacon triggered 1 Drop Ship on deck 0")
	# A second call to request_dropship on deck 0 must be refused by max_drops_per_deck = 1!
	var second := sq.request_dropship(p.global_position, 0)
	check(second == null, "strict max_drops_per_deck cap blocks 2nd dropship on same deck")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	city.queue_free()
	await frames(1)


func _multi_seed_stack_reachable_drop_zones() -> void:
	var total_checks := 0
	var roof_picks := 0
	var invalid_ground := 0
	var unreachable := 0
	var empty_picks := 0
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	for s in range(1, 9):
		var sec := SectionPlan.make({"seed": float(s)})
		var plans: Array[CityPlan] = []
		var rings: Array[RingFrame] = []
		for k in sec.deck_count:
			var dp := CityPlan.for_deck(sec, k)
			var dr := RingFrame.new(sec.radius_of(k))
			plans.append(dp)
			rings.append(dr)
			sq.add_deck_nav(k, dp)
		for k in sec.deck_count:
			var dp := plans[k]
			var dr := rings[k]
			var lane := (dp.avenue_x().x + dp.avenue_x().y) * 0.5
			var samples: Array[Vector2] = [
				Vector2(lane, dp.extent.position.y + 28.0),
				Vector2(lane, 0.0),
			]
			if sec.has_method("arrival"):
				var arr: Dictionary = sec.arrival(k)
				if arr.has("x") and arr.has("s"):
					samples[0] = Vector2(float(arr["x"]), float(arr["s"]))
			for sp_arc in samples:
				total_checks += 1
				sq._drop_seq += 1
				var target_w := dr.arc_to_world(sp_arc.x, sp_arc.y, CityPlan.CURB_H)
				var zone := sq._pick_drop_zone(dp, dr, target_w, k)
				if zone.is_empty():
					empty_picks += 1
					continue
				if bool(zone.get("is_roof", false)):
					roof_picks += 1
				var da3 := dr.world_to_arc(zone["drop"] as Vector3)
				var drop_arc := Vector2(da3.x, da3.y)
				if not EnemySquad._valid_ground_drop_point(dp, drop_arc):
					invalid_ground += 1
				var path := sq.find_arc_path(sp_arc, drop_arc, k)
				if path.is_empty():
					unreachable += 1

	check(total_checks >= 32, "checked >= 32 multi-seed stack deck drop zones (%d)" % total_checks)
	eq(empty_picks, 0, "0 empty dropship drop zones across seeds 1..8 all decks")
	eq(roof_picks, 0, "0 live dropship drop zones placed on rooftops across seeds 1..8")
	eq(invalid_ground, 0, "0 drop zones overlapping buildings, pillars, floor cuts, or ramps")
	eq(unreachable, 0, "0 drop zones disconnected from deck road graph")

	# Also verify a street-dropped squad starts in active hunt pursuit toward the nearest deck player.
	var pw := _mock_player(w, Vector3(0.0, 0.0, 0.0), "hunt_p1")
	var ds := EnemyDropDrone.new()
	ds.configure("dropship", "drop_hunt_1", w, sq, null, 9)
	ds.position = Vector3(0.0, 11.5, -45.0)
	ds.configure_drop(Vector3(0.0, 0.0, -45.0), false, 6.0, Vector3(25.0, 28.0, -85.0))
	sq.add_enemy(ds)
	var dep := [null]
	ds.troops_deployed.connect(func(_d: EnemyDropDrone, ts: Array) -> void: dep[0] = ts)
	await frames(1)
	for _i in 240:
		w.advance(DT)
		if dep[0] != null:
			break
	var dlist: Array = dep[0] if dep[0] is Array else []
	check(dlist.size() >= 3, "street dropship deployed individual trooper fireteam (%d)" % dlist.size())
	if not dlist.is_empty():
		var dts := dlist[0] as EnemyTrooper
		check(dts._hunting, "dropped street troopers start actively hunting nearest player")
		check(dts._last_target_ref == pw and dts._target_id == pw.target_id, "dropped street troopers acquired deck player immediately")

	pw.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _coop_enemy_sync_add_and_gone() -> void:
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

	# Spawn Drop Ship dynamically on host -> verify EnemySync queues "add" -> client spawns puppet!
	var ds := EnemyDropDrone.new()
	ds.configure("dropship", "sync_drop_1", hw, hsq, null, 7)
	ds.position = Vector3(0.0, 11.5, -35.0)
	ds.configure_drop(Vector3(0.0, 0.0, -35.0), false, 6.0, Vector3(0.0, 28.0, -60.0))
	hsq.add_enemy(ds)
	await frames(1)

	# Replay host's queued "add" items into client EnemySync.
	var q1: Array = hsync._queue.duplicate()
	hsync._queue.clear()
	for it: Array in q1:
		csync._apply_item(str(it[0]), int(it[1]), it[2])
	await frames(1)
	var ds_net_id := ds.net_id
	check(csync.by_net.has(ds_net_id) and (csync.by_net[ds_net_id] as EnemyBase).enemy_type == "dropship",
		"EnemySync 'add' spawns dropship puppet on client")

	# Step host through telegraph -> deploy troop squad -> exfil & remove dropship -> replay "add" + "gone" to client!
	for _i in 450:
		hw.advance(DT)
		if not is_instance_valid(ds) or not ds in hsq.enemies:
			break
	var q2: Array = hsync._queue.duplicate()
	hsync._queue.clear()
	var add_troop_count := 0
	var saw_gone_drop := false
	for it: Array in q2:
		var k := str(it[0])
		if k == "add":
			add_troop_count += 1
		elif k == "gone" and int(it[1]) == ds_net_id:
			saw_gone_drop = true
		csync._apply_item(k, int(it[1]), it[2])
	await frames(1)

	check(add_troop_count >= 3, "EnemySync queued individual 'add' events for all deployed troopers (%d)" % add_troop_count)
	check(saw_gone_drop, "EnemySync queued 'gone' when Drop Ship exfiltrated")
	check(not csync.by_net.has(ds_net_id), "client removed exfiltrated dropship puppet cleanly")
	eq(csync.by_net.size(), add_troop_count, "client holds all %d individual deployed trooper puppets" % add_troop_count)

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()
	hsq.queue_free()
	hw.queue_free()
	await frames(1)


## 6. One flight per deck per seed in the real game (TestDrive, plan mode), at 2x game speed; then deck 0 again with the
## air doors off (EnemySquad.air_doors_enabled = false: the in-deck fallback).
func _stack_round_trips_clear() -> void:
	var box := BoxShape3D.new()
	box.size = EnemyDropDrone.HULL_SIZE * 0.98
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = box
	q.collide_with_areas = false
	var flights := 0
	var through_doors := 0
	Engine.time_scale = 2.0
	for seed_n: int in ROUND_TRIP_SEEDS:
		var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
		td.city_mode = TestDrive.MODE_STACK
		td.seed_value = seed_n
		td.objectives = true
		add_child(td)
		await frames(4)
		td.drive_override = true
		td.mech.move_input = Vector2.ZERO
		var sq: EnemySquad = td.combat.squad
		var pt: PlayerTarget = td.combat.player_target
		var mw: MissionWorld = td.stack.mission
		sq.max_drops_per_deck = 99
		var runs: Array = []
		for k in td.stack.decks.size():
			runs.append([k, true])
		runs.append([0, false])
		for run: Array in runs:
			var k: int = run[0]
			var doors_on: bool = run[1]
			sq.air_doors_enabled = doors_on
			var plan: CityPlan = sq.deck_plan(k)
			var nodes: Array = plan.walk_graph()["nodes"]
			var tn: Vector2 = nodes[(7919 * (k + 1) + seed_n) % nodes.size()]
			var mp := td.stack.from_deck_arc(k, tn.x, tn.y, 0.5)
			td.mech.global_position = mp
			td.mech.velocity = Vector3.ZERO
			pt.global_position = mp
			await frames(2)
			for e in sq.enemies.duplicate():
				if is_instance_valid(e) and e.enemy_type == "dropship":
					sq.remove_enemy(e)
					e.queue_free()
			sq._deck_drops.clear()
			var ds := sq.request_dropship(td.stack.from_deck_arc(k, tn.x, tn.y, 1.0), k)
			var tag := "seed %d deck %d%s" % [seed_n, k, "" if doors_on else " (doors off)"]
			if not check(ds != null, tag + ": a dropship is called in"):
				continue
			flights += 1
			var door_n := mw.air_door_count(k) if doors_on else 0
			var air_in := str(ds._air_in.get("id", ""))
			if door_n > 0:
				through_doors += 1
				check(air_in != "" and ds.staged and not ds.is_hittable(), tag + ": created hidden in an air door's recess, not hittable")
			else:
				check(air_in == "" and not ds.staged, tag + ": no air door: the in-deck appear point")
			var drop_arc := ds._arc2(ds._drop_pos)
			var landed := [null]
			ds.troops_deployed.connect(func(_d: EnemyDropDrone, arr: Array) -> void: landed[0] = arr.duplicate())
			var removed := [false]
			var ds_id := ds.target_id
			var on_removed := func(e: EnemyBase) -> void:
				if is_instance_valid(e) and e.target_id == ds_id:
					removed[0] = true
			sq.enemy_removed.connect(on_removed)
			q.exclude = [td.mech.get_rid()] as Array[RID]
			var hits := 0
			var outside := 0
			var early_hit := 0
			var shut_pass := 0
			var t := 0.0
			var first_hit := ""
			var last_pos := ds._world_pos()
			var air_out := ""
			while t < ROUND_TRIP_LIMIT and not removed[0]:
				await get_tree().physics_frame
				t += Engine.time_scale / float(Engine.physics_ticks_per_second)
				pt.repair_all()
				if removed[0] or not is_instance_valid(ds) or ds.destroyed():
					break
				last_pos = ds._world_pos()
				air_out = str(ds._air_out.get("id", ""))
				var ph := ds._drop_phase
				var in_door := ph == EnemyDropDrone.PHASE_DOOR_OUT or ph == EnemyDropDrone.PHASE_DOOR_IN
				var a := ds._arc2(last_pos)
				if in_door and air_in != "":
					var did := air_in if ph == EnemyDropDrone.PHASE_DOOR_OUT else air_out
					var passable := bool(mw.source_state(did).get("passable", false))
					if ds.staged and ds.is_hittable():
						early_hit += 1
					if not plan.extent.has_point(a) and not ds.staged and not passable \
							and (ph == EnemyDropDrone.PHASE_DOOR_OUT or ds._air_open_at > 0.0):
						shut_pass += 1   # moving behind the wall plane with its door not fully open
				q.transform = ds.global_transform
				for hh: Dictionary in ds.get_world_3d().direct_space_state.intersect_shape(q, 4):
					if not (hh["collider"] is CharacterBody3D):
						hits += 1
						if first_hit == "":
							first_hit = "%s at %s h %.1f (%s)" % [str((hh["collider"] as Node).name) if hh["collider"] is Node else "?",
								str(a), ds.ring.height(last_pos), ph]
						break
				if (not plan.extent.has_point(a) and not in_door) or ds.ring.height(last_pos) + EnemyDropDrone.HULL_SIZE.y * 0.5 > plan.p("ceiling"):
					outside += 1
			sq.enemy_removed.disconnect(on_removed)
			print("[Test] round trip %s: %.1f s, doors %s>%s, hull contacts %d, outside %d, troops %d %s" % [tag, t, air_in, air_out,
				hits, outside, (landed[0] as Array).size() if landed[0] is Array else -1, first_hit])
			eq(hits, 0, tag + ": the hull never touches geometry (%s)" % first_hit)
			eq(outside, 0, tag + ": never outside the walls (but in a door) or above the ceiling")
			eq(early_hit, 0, tag + ": not hittable while hidden")
			eq(shut_pass, 0, tag + ": behind the wall plane only while its door is passable")
			check(removed[0], tag + ": the round trip ends (left the deck) within %.0f s (%.1f)" % [ROUND_TRIP_LIMIT, t])
			var arr: Array = landed[0] if landed[0] is Array else []
			check(arr.size() >= 3, tag + ": the squad was dropped (%d)" % arr.size())
			check(EnemySquad._valid_ground_drop_point(plan, drop_arc), tag + ": the drop zone is valid street ground")
			if door_n > 0 and air_out != "":
				var dd := {}
				for i in door_n:
					var cand := mw.air_door(k, i)
					if str(cand.get("id", "")) == air_out:
						dd = cand
				var off := last_pos.distance_to(dd["hide"] as Vector3) if not dd.is_empty() else -1.0
				check(not dd.is_empty() and off < 2.0, tag + ": removed inside the recess of %s (%.1f m from its hide point)" % [air_out, off])
				# The door shuts again after its hold.
				var w := 0.0
				while w < 20.0 and str(mw.source_state(air_out).get("state", "")) != "shut":
					await get_tree().physics_frame
					w += Engine.time_scale / float(Engine.physics_ticks_per_second)
				eq(str(mw.source_state(air_out).get("state", "")), "shut", tag + ": %s shut again after the ship went in" % air_out)
		sq.air_doors_enabled = true
		td.queue_free()
		await frames(2)
	Engine.time_scale = 1.0
	check(flights >= 16, "round trips flown over %d seeds (%d)" % [ROUND_TRIP_SEEDS.size(), flights])
	check(through_doors >= 8, "most went through air doors (%d)" % through_doors)
