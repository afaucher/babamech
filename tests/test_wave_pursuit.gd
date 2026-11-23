extends TestCase
## Wave pursuit & abandoned-defend regression test (docs/design/mission-objectives.md §5, §9):
##   1. Real-stack Seed 1 waves (lift, shaft, gate sources at ~85-200 m): every combat wave unit must persistently
##      pursue its target from spawn to contact (closing from ~150 m to within 80 m in <= 35 s, never drifting away or
##      reverting to patrol/cover-idle).
##   2. Abandoned Defend (Seed 7 deck 2): when the crew leaves the defend deck while the relay is live, defend-wave
##      units stay awake, pursue the relay, and damage it (while deck garrisons stay asleep / never touch the relay).

const DT := 1.0 / 60.0
const CLOSE_DIST := 80.0


func _init() -> void:
	timeout_sec = 120.0


func setup() -> void:
	await _probe_seed1_wave_closing()
	await _probe_seed7_abandoned_defend()
	finish()


func _probe_seed1_wave_closing() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 1
	td.objectives = true
	add_child(td)
	await frames(6)
	td.drive_override = true
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)
	if td.mission != null:
		td.mission.set_physics_process(false)

	var mplan: MissionPlan = td.mission.plan
	var sq: EnemySquad = td.combat.squad
	var w: CombatWorld = td.combat.world

	for k in [0, 1, 2]:
		var pool: Dictionary = mplan.pool(k)
		var waves: Array = pool.get("waves", [])
		var srcs := mplan.deck_sources(k)
		if waves.is_empty() or srcs.is_empty():
			continue
		# Pick up to 3 distinct source kinds (gate, lift, shaft, ramp) on deck k and place mech ~150 m away on a road node!
		var picked: Array[Dictionary] = []
		var seen_kinds := {}
		for s: Dictionary in srcs:
			var sk := str(s["kind"])
			if not seen_kinds.has(sk):
				seen_kinds[sk] = true
				picked.append(s)
		# Clear existing garrison on deck k so we isolate wave pursuit cleanly.
		for e in sq.enemies.duplicate():
			if is_instance_valid(e) and e.spawn_deck == k:
				e.apply_damage(1.0e7, e.core_component(), "test")
		var rg := td.stack.decks[k].plan.road_graph()
		var rnodes: Array = rg["nodes"]

		for si in picked.size():
			var sdef: Dictionary = picked[si].duplicate(true)
			sdef["point"] = td.stack.mission.source_point(str(sdef["id"])) if td.stack.mission != null else {}
			var s_arc := Vector2(float(sdef["x"]), float(sdef["s"]))
			# Place mech on the road crossing closest to 150 m from this source (matching Missions' release-time source pick!).
			var best_node: Vector2 = rnodes[0]
			var best_err := INF
			for rn: Vector2 in rnodes:
				var err := absf(rn.distance_to(s_arc) - 150.0)
				if err < best_err:
					best_err = err
					best_node = rn
			var m_pos := td.stack.from_deck_arc(k, best_node.x, best_node.y, 0.5)
			td.mech.global_position = m_pos
			td.mech.velocity = Vector3.ZERO
			if td.combat.player_target != null:
				td.combat.player_target.global_position = m_pos
			await frames(2)
			var wv: Dictionary = waves[si % waves.size()].duplicate(true)
			var wid := "probe_d%d_%s_%d" % [k, str(sdef["kind"]), si]
			wv["id"] = wid
			var order := {"wave": wid, "deck": k, "source": str(sdef["id"]), "open_at": w.now, "max_units": 6}
			var ctx := {"stack": td.stack, "world": w, "squad": sq, "seed": 1 + si, "crew": 1, "pool": pool, "skip_meshes": true}
			EnemySpawner.spawn_wave(order, wv, sdef, ctx)
			var units: Array[EnemyBase] = []
			for e in sq.enemies:
				if is_instance_valid(e) and e.wave == wid and not e.destroyed():
					units.append(e)
			var start_d := {}
			var min_d := {}
			var close_t := {}
			for u in units:
				var d0 := u.global_position.distance_to(m_pos)
				start_d[u.target_id] = d0
				min_d[u.target_id] = d0
				close_t[u.target_id] = 0.0 if d0 <= CLOSE_DIST else -1.0
				var a0 := td.stack.to_deck_arc(u.global_position)
				print("[wave] d%d %s (%s) src=%s(%s) start=%.1fm arc=(%.1f,%.1f) -> mech=(%.1f,%.1f)" % [
					k, u.target_id, u.enemy_type, str(sdef["id"]), str(sdef["kind"]),
					d0, float(a0["x"]), float(a0["s"]), best_node.x, best_node.y])
			# Step 35 s (2100 frames) and track closing time to <= 80 m.
			for f in 2100:
				w.advance(DT)
				for u in units:
					if not is_instance_valid(u) or u.destroyed():
						continue
					var d := u.global_position.distance_to(m_pos)
					if d < float(min_d[u.target_id]):
						min_d[u.target_id] = d
					if float(close_t[u.target_id]) < 0.0 and d <= CLOSE_DIST:
						close_t[u.target_id] = float(f + 1) * DT
			for u in units:
				if not is_instance_valid(u):
					continue
				var ac := td.stack.to_deck_arc(u.global_position)
				var d_end := u.global_position.distance_to(m_pos)
				var d0 := float(start_d[u.target_id])
				var md := float(min_d[u.target_id])
				var ct := float(close_t[u.target_id])
				var wp0 := str(u._path_points[0]) if not u._path_points.is_empty() else "none"
				print("[wave]   END d%d %s (%s): state=%s los=%s hunt=%s start=%.1fm min=%.1fm end=%.1fm close_t=%.1fs arc=(%.1f,%.1f) path=%d wp0=%s" % [
					k, u.target_id, u.enemy_type, u.ai_state, str(u._has_los), str(u._hunting),
					d0, md, d_end, ct, float(ac["x"]), float(ac["s"]), u._path_points.size(), wp0])
				# Budget: <= 30 s at 150 m (scales slightly if source was > 155 m away).
				var max_t := maxf(30.0, (d0 - CLOSE_DIST) / 4.5 + 14.0)
				# Every source kind asserts, ramps included: a unit snapped beside a ramp mouth (seed 1 d0_ramp_0, unit _02 at
				# arc (-65, 186.5)) used to cut the corner into the mouth, walk down the ramp, get re-homed to the deck below
				# and sleep there. Paths and steering now keep out of floor cuts (EnemySquad.deck_cuts).
				check(md <= CLOSE_DIST, "wave unit %s (%s from %s) closed within 80 m (start=%.1f min=%.1f end=%.1f)" % [
					u.target_id, u.enemy_type, str(sdef["kind"]), d0, md, d_end])
				if md <= CLOSE_DIST:
					check(ct <= max_t, "wave unit %s closed in %.1f s (<= %.1f s from %.1f m)" % [u.target_id, ct, max_t, d0])
			for u in units:
				if is_instance_valid(u) and not u.destroyed():
					u.apply_damage(1.0e7, u.core_component(), "test")

	td.queue_free()
	await frames(3)


func _probe_seed7_abandoned_defend() -> void:
	MissionFlow.test_plan = {"hold": 6.0, "linger": 600.0}
	MissionFlow.test_director = {"lull": 1.5, "lull_min": 1.5, "grace": 1.5, "follow_gap": 0.5}
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 7
	td.objectives = true
	add_child(td)
	await frames(6)
	td.drive_override = true
	var mf: MissionFlow = td.mission
	var prim: Dictionary = mf.plan.primary(1)   # Seed 7 deck 1 (deck 2 1-based) is a defend
	var def_id := str(prim["id"])
	var def_deck := int(prim["deck"])
	var site: Dictionary = mf.rules.objective(def_id)["site"]
	# Activate the defend by stepping onto its site briefly.
	td.mech.global_position = td.stack.from_deck_arc(def_deck, float(site["x"]), float(site["s"]), 0.5)
	td.mech.velocity = Vector3.ZERO
	for _i in 120:
		await get_tree().physics_frame
		if mf.rules.obj_state(def_id) == "active" and td.combat.asset(def_id) != null and td.combat.asset(def_id).is_hittable():
			break
	check(mf.rules.obj_state(def_id) == "active", "seed 7 defend %s activated" % def_id)

	# Pause MissionFlow / mech physics and move the crew OFF deck 1 onto deck 2 (abandoning the relay!).
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)
	mf.set_physics_process(false)

	var other_deck := mini(def_deck + 1, td.stack.decks.size() - 1)
	var away_pos := td.stack.from_deck_arc(other_deck, 0.0, 0.0, 0.5)
	td.mech.global_position = away_pos
	if td.combat.player_target != null:
		td.combat.player_target.global_position = away_pos
	await frames(2)

	var sq: EnemySquad = td.combat.squad
	var w: CombatWorld = td.combat.world
	w.advance(DT)   # refresh EnemySquad's per-tick awake cache after moving crew off deck
	var relay: AssetTarget = td.combat.asset(def_id)
	check(relay != null and relay.is_hittable(), "defend relay is live and hittable")
	check(not sq.deck_awake(def_deck), "deck %d has no crew mech (garrison stays asleep)" % def_deck)

	# Spawn a defend wave for def_id while the crew is on another deck.
	var pool: Dictionary = mf.plan.pool(def_deck)
	var def_wave := {}
	for wv: Dictionary in pool.get("waves", []):
		var tr: Dictionary = wv.get("trigger", {})
		if str(tr.get("id", "")) == def_id and str(tr.get("step", "")) == "start":
			def_wave = wv
			break
	check(not def_wave.is_empty(), "found a defend wave for %s" % def_id)
	var sdef: Dictionary = mf.plan.source(str(def_wave["source"])).duplicate(true)
	sdef["point"] = td.stack.mission.source_point(str(sdef["id"])) if td.stack.mission != null else {}
	var order := {"wave": str(def_wave["id"]), "deck": def_deck, "source": str(sdef["id"]), "open_at": w.now, "max_units": 4}
	EnemySpawner.spawn_wave(order, def_wave, sdef, {"stack": td.stack, "world": w, "squad": sq, "seed": 7, "crew": 1, "pool": pool, "skip_meshes": true})

	var relay_hits := [0]
	var hit_by_garrison := [false]
	relay.asset_damaged.connect(func(_id: String, _amt: float, src: String) -> void:
		relay_hits[0] += 1
		for e in sq.enemies:
			if is_instance_valid(e) and e.target_id == src and e.wave == "":
				hit_by_garrison[0] = true)

	# Step up to 60 s: defend wave units must stay awake, close to the relay, and damage it (garrison never shoots it)!
	for _f in 3600:
		w.advance(DT)
		if int(relay_hits[0]) >= 1:
			break
	print("[defend] abandoned relay hits=%d hit_by_garrison=%s" % [int(relay_hits[0]), str(hit_by_garrison[0])])
	check(int(relay_hits[0]) >= 1, "abandoned defend wave stays awake and attacks the live relay (hits=%d)" % int(relay_hits[0]))
	check(not bool(hit_by_garrison[0]), "asleep deck garrison never hits the abandoned relay")

	td.queue_free()
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}
	await frames(3)
