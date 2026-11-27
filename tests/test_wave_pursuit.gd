extends TestCase
## Wave pursuit & abandoned-defend regression test (docs/design/mission-objectives.md §5, §9):
##   1. Real-stack Seed 1 waves (lift, shaft, gate sources at ~85-200 m): every combat wave unit must persistently
##      pursue its target from spawn to contact (closing from ~150 m to within 80 m in <= 35 s, never drifting away or
##      reverting to patrol/cover-idle), then stay engaged (within its weapon's range, still targeting the mech).
##   2. Cross-deck (Seed 1): wave units on a deck with no crew never sleep; they walk the ramps to the crew's deck
##      (down and up) and close on the mech there.
##   3. Abandoned Defend (Seed 7 deck 2): when the crew leaves the defend deck while the relay is live, defend-wave
##      units stay awake, pursue the relay, and damage it (while deck garrisons stay asleep / never touch the relay).

const DT := 1.0 / 60.0
const CLOSE_DIST := 80.0
const ENGAGE_HOLD := 10.0   ## s every unit that made contact is watched after the 35 s closing window
## s cap to reach the crew's deck and close within CLOSE_DIST, from a source ~300 m away by road plus a ramp (seed 1 on
## 2026-11-23: down arrives ~42 s / closes ~66 s, up ~37 s / ~49 s; strider flank pace, so about 2x headroom).
const XDECK_TIME := 120.0


func _init() -> void:
	timeout_sec = 120.0


func setup() -> void:
	await _probe_seed1_wave_closing()
	await _probe_seed1_cross_deck()
	await _probe_seed1_ramp_turnaround()
	await _probe_seed7_abandoned_defend()
	finish()


func _probe_seed1_wave_closing() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = 1
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
	var pt: PlayerTarget = td.combat.player_target

	for k in [0, 1, 2]:
		var pool: Dictionary = mplan.pool(k)
		var waves: Array = pool.get("reserve", [])
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
		var rg := CityGraphs.road_graph(td.stack.decks[k].plan)
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
			# As in the game (MissionFlow orders the door, then spawns at open_at): the door is open when the wave comes.
			# A gate's units appear in its recess behind the leaves; with the leaves shut (now solid) a unit that cannot
			# squeeze past them never gets out (the 1.75x waves put a third trooper there).
			if td.stack.mission != null:
				td.stack.mission.open_source(str(sdef["id"]), td.mission.now())
				td.stack.mission.advance_to(td.mission.now() + 0.5)
				await frames(2)
			var ctx := {"stack": td.stack, "world": w, "squad": sq, "seed": 1 + si, "crew": 1, "pool": pool, "skip_meshes": true}
			EnemySpawner.spawn_wave(order, wv, sdef, ctx)
			var units: Array[EnemyBase] = []
			for e in sq.enemies:
				if is_instance_valid(e) and e.wave == wid and not e.destroyed():
					units.append(e)
			var start_d := {}
			var min_d := {}
			var close_t := {}
			var contact_t := {}   # first time within the unit's engage range of the mech (-1: never)
			var max_after := {}   # farthest from the mech after that contact
			for u in units:
				var d0 := u.global_position.distance_to(m_pos)
				start_d[u.target_id] = d0
				min_d[u.target_id] = d0
				close_t[u.target_id] = 0.0 if d0 <= CLOSE_DIST else -1.0
				contact_t[u.target_id] = -1.0
				max_after[u.target_id] = 0.0
				var a0 := td.stack.to_deck_arc(u.global_position)
				print("[wave] d%d %s (%s) src=%s(%s) start=%.1fm arc=(%.1f,%.1f) -> mech=(%.1f,%.1f)" % [
					k, u.target_id, u.enemy_type, str(sdef["id"]), str(sdef["kind"]),
					d0, float(a0["x"]), float(a0["s"]), best_node.x, best_node.y])
			# Step 35 s (2100 frames) and track closing time to <= 80 m, then ENGAGE_HOLD s more so every unit that made
			# contact is watched for at least that long after it. The mech is the fixture, not the subject: it is kept
			# standing (repair_all every frame). Units used to kill it at ~27 s, it respawned at the deck's entry ~330 m
			# away and they (rightly) went after it there: the "drift" this probe once showed.
			for f in 2100 + int(ENGAGE_HOLD / DT):
				if pt != null:
					pt.repair_all()
				w.advance(DT)
				var t := float(f + 1) * DT
				for u in units:
					if not is_instance_valid(u) or u.destroyed():
						continue
					var d := u.global_position.distance_to(m_pos)
					if f < 2100:
						if d < float(min_d[u.target_id]):
							min_d[u.target_id] = d
						if float(close_t[u.target_id]) < 0.0 and d <= CLOSE_DIST:
							close_t[u.target_id] = t
					if float(contact_t[u.target_id]) < 0.0:
						if d <= EnemyCatalog.engage_range(u.enemy_type):
							contact_t[u.target_id] = t
					elif d > float(max_after[u.target_id]):
						max_after[u.target_id] = d
			var t_end := float(2100 + int(ENGAGE_HOLD / DT)) * DT
			for u in units:
				if not is_instance_valid(u):
					continue
				var ac := td.stack.to_deck_arc(u.global_position)
				var d_end := u.global_position.distance_to(m_pos)
				var d0 := float(start_d[u.target_id])
				var md := float(min_d[u.target_id])
				var ct := float(close_t[u.target_id])
				var wp0 := str(u._path_points[0]) if not u._path_points.is_empty() else "none"
				print("[wave]   END d%d %s (%s): state=%s los=%s hunt=%s tgt=%s start=%.1fm min=%.1fm end=%.1fm close_t=%.1fs contact_t=%.1fs max_after=%.1fm arc=(%.1f,%.1f) path=%d wp0=%s" % [
					k, u.target_id, u.enemy_type, u.ai_state, str(u._has_los), str(u._hunting), u._target_id,
					d0, md, d_end, ct, float(contact_t[u.target_id]), float(max_after[u.target_id]),
					float(ac["x"]), float(ac["s"]), u._path_points.size(), wp0])
				# Budget: <= 30 s at 150 m (scales slightly if source was > 155 m away).
				var max_t := maxf(30.0, (d0 - CLOSE_DIST) / 4.5 + 14.0)
				# Every source kind asserts, ramps included: a unit snapped beside a ramp mouth (seed 1 d0_ramp_0, unit _02 at
				# arc (-65, 186.5)) used to cut the corner into the mouth, walk down the ramp, get re-homed to the deck below
				# and sleep there. Paths and steering now keep out of floor cuts (EnemySquad.deck_cuts).
				check(md <= CLOSE_DIST, "wave unit %s (%s from %s) closed within 80 m (start=%.1f min=%.1f end=%.1f)" % [
					u.target_id, u.enemy_type, str(sdef["kind"]), d0, md, d_end])
				if md <= CLOSE_DIST:
					check(ct <= max_t, "wave unit %s closed in %.1f s (<= %.1f s from %.1f m)" % [u.target_id, ct, max_t, d0])
				# Stays engaged after contact: once within its engage range (EnemyCatalog.engage_range), an armed unit never
				# gets farther from the mech than its primary weapon's range for the rest of the run (>= ENGAGE_HOLD s), and
				# still holds the mech as its target at the end. Unarmed spotters (the drone) have no range to keep.
				var wpn := str(EnemyCatalog.unit(u.enemy_type).get("primary_weapon", ""))
				if wpn == "" or u.destroyed():
					continue
				var w_range := float(EnemyCatalog.weapon(wpn).get("range", 0.0))
				var cnt := float(contact_t[u.target_id])
				check(cnt >= 0.0, "wave unit %s (%s) made contact (within its %.0f m engage range; min=%.1f)" % [
					u.target_id, u.enemy_type, EnemyCatalog.engage_range(u.enemy_type), md])
				if cnt >= 0.0:
					check(t_end - cnt >= ENGAGE_HOLD - 0.01, "wave unit %s watched %.1f s after contact" % [u.target_id, t_end - cnt])
					check(float(max_after[u.target_id]) <= w_range, "wave unit %s (%s) stayed engaged after contact at %.1f s: max %.1f m (<= %s range %.0f m), end %.1f m" % [
						u.target_id, u.enemy_type, cnt, float(max_after[u.target_id]), wpn, w_range, d_end])
					check(pt != null and u._target_id == pt.target_id and u.is_alerted(), "wave unit %s still targets the mech at the end (state=%s target=%s)" % [
						u.target_id, u.ai_state, u._target_id])
			for u in units:
				if is_instance_valid(u) and not u.destroyed():
					u.apply_damage(1.0e7, u.core_component(), "test")

	td.queue_free()
	await frames(3)


## Wave units released on a deck with no crew: they used to be re-homed / left there asleep for good (EnemyBase._is_awake
## only kept defend waves awake). Now every wave unit stays awake and walks the section's ramps toward the crew's deck
## (EnemySquad._step_wave_transit). Down: crew on deck 1, a deck-0 wave. Up: crew on deck 0, a deck-1 wave.
func _probe_seed1_cross_deck() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = 1
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
	var pt: PlayerTarget = td.combat.player_target
	for e in sq.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")   # isolate the wave from every deck's garrison
	for pair: Array in [[0, 1], [1, 0]]:
		var wave_deck := int(pair[0])
		var crew_deck := int(pair[1])
		var waves: Array = mplan.pool(wave_deck).get("reserve", [])
		var src := {}
		for s: Dictionary in mplan.deck_sources(wave_deck):
			if str(s["kind"]) in ["gate", "lift"]:
				src = s.duplicate(true)
				break
		check(not waves.is_empty() and not src.is_empty(), "deck %d has a wave and a gate/lift source" % wave_deck)
		if waves.is_empty() or src.is_empty():
			continue
		src["point"] = td.stack.mission.source_point(str(src["id"])) if td.stack.mission != null else {}
		# The crew mech on a road crossing of crew_deck near the middle of the map.
		var rnodes: Array = CityGraphs.road_graph(td.stack.decks[crew_deck].plan)["nodes"]
		var node: Vector2 = rnodes[0]
		for rn: Vector2 in rnodes:
			if rn.length() < node.length():
				node = rn
		var m_pos := td.stack.from_deck_arc(crew_deck, node.x, node.y, 0.5)
		td.mech.global_position = m_pos
		td.mech.velocity = Vector3.ZERO
		pt.global_position = m_pos
		pt.repair_all()
		await frames(2)
		var wid := "xdeck_%d_to_%d" % [wave_deck, crew_deck]
		var wv: Dictionary = waves[0].duplicate(true)
		wv["id"] = wid
		var order := {"wave": wid, "deck": wave_deck, "source": str(src["id"]), "open_at": w.now, "max_units": 4}
		# Open the wave door as MissionFlow._open does (MissionFlow is paused here) and keep its clock running below.
		var mw: MissionWorld = td.stack.mission
		if mw != null:
			mw.open_source(str(src["id"]), mw.now, 1.0e6)
		EnemySpawner.spawn_wave(order, wv, src, {"stack": td.stack, "world": w, "squad": sq, "seed": 11, "crew": 1,
			"pool": mplan.pool(wave_deck), "skip_meshes": true})
		var units: Array[EnemyBase] = []
		for e in sq.enemies:
			# Ground walkers only: drones fly their own way (they stay awake, nothing walks them across decks).
			if is_instance_valid(e) and e.wave == wid and not e.destroyed() and e.is_mobile() \
					and not (e is EnemyDrone or e is EnemyGunship or e is EnemyDropDrone):
				units.append(e)
		check(not units.is_empty(), "%s spawned ground units" % wid)
		var arrive_t := {}
		var close_t := {}
		var min_d := {}
		for u in units:
			arrive_t[u.target_id] = -1.0
			close_t[u.target_id] = -1.0
			min_d[u.target_id] = u.global_position.distance_to(m_pos)
			print("[xdeck] %s %s (%s) start deck %d %.1f m from the mech" % [wid, u.target_id, u.enemy_type, u.spawn_deck,
				float(min_d[u.target_id])])
		for f in int(XDECK_TIME / DT):
			pt.repair_all()
			if mw != null:
				mw.advance_to(mw.now + DT)
			w.advance(DT)
			var t := float(f + 1) * DT
			var all_close := true
			for u in units:
				if not is_instance_valid(u) or u.destroyed():
					continue
				var d := u.global_position.distance_to(m_pos)
				min_d[u.target_id] = minf(float(min_d[u.target_id]), d)
				if float(arrive_t[u.target_id]) < 0.0 and u.spawn_deck == crew_deck:
					arrive_t[u.target_id] = t
				if float(close_t[u.target_id]) < 0.0 and u.spawn_deck == crew_deck and d <= CLOSE_DIST:
					close_t[u.target_id] = t
				if float(close_t[u.target_id]) < 0.0:
					all_close = false
			if all_close:
				break
		for u in units:
			if not is_instance_valid(u) or u.destroyed():
				continue
			var a := td.stack.to_deck_arc(u.global_position)
			print("[xdeck]   END %s %s (%s): deck=%d state=%s transit=%d arrive_t=%.1fs close_t=%.1fs min=%.1fm arc=(%.1f,%.1f)" % [
				wid, u.target_id, u.enemy_type, u.spawn_deck, u.ai_state, u._transit_deck, float(arrive_t[u.target_id]),
				float(close_t[u.target_id]), float(min_d[u.target_id]), float(a["x"]), float(a["s"])])
			check(float(arrive_t[u.target_id]) >= 0.0, "%s unit %s (%s) walked from deck %d to the crew's deck %d" % [
				wid, u.target_id, u.enemy_type, wave_deck, crew_deck])
			check(float(close_t[u.target_id]) >= 0.0, "%s unit %s (%s) closed within %.0f m of the mech on deck %d (min %.1f m)" % [
				wid, u.target_id, u.enemy_type, CLOSE_DIST, crew_deck, float(min_d[u.target_id])])
		for e in sq.enemies:
			if is_instance_valid(e) and e.wave == wid and not e.destroyed():
				e.apply_damage(1.0e7, e.core_component(), "test")
	td.queue_free()
	await frames(3)


## 4. Ramp turnaround (seed 1): a wave unit walking a ramp toward the crew's deck turns round when the crew comes back to
## the deck it is leaving (the bot respawned on deck 0 and returned to deck 1 while the last two deck-1 units walked the
## ~290 m ramp up to deck 0 and back, ~70 s of the sweep). After the crew returns it gets no farther from the ramp's
## entry than one transit refresh of walking, and is back on the crew's deck and within CLOSE_DIST in time.
func _probe_seed1_ramp_turnaround() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = 1
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
	var pt: PlayerTarget = td.combat.player_target
	var mw: MissionWorld = td.stack.mission
	for e in sq.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")
	var wave_deck := 0
	var away_deck := 1
	var waves: Array = mplan.pool(wave_deck).get("reserve", [])
	var src := {}
	for s: Dictionary in mplan.deck_sources(wave_deck):
		if str(s["kind"]) in ["gate", "lift"]:
			src = s.duplicate(true)
			break
	if not check(not waves.is_empty() and not src.is_empty(), "turnaround: deck 0 has a wave and a gate/lift source"):
		td.queue_free()
		await frames(3)
		return
	src["point"] = mw.source_point(str(src["id"])) if mw != null else {}
	var place := func(k: int) -> Vector3:
		var rnodes: Array = CityGraphs.road_graph(td.stack.decks[k].plan)["nodes"]
		var node: Vector2 = rnodes[0]
		for rn: Vector2 in rnodes:
			if rn.length() < node.length():
				node = rn
		var p := td.stack.from_deck_arc(k, node.x, node.y, 0.5)
		td.mech.global_position = p
		td.mech.velocity = Vector3.ZERO
		pt.global_position = p
		pt.repair_all()
		return p
	var m_pos: Vector3 = place.call(away_deck)
	await frames(2)
	var wid := "turn_0"
	var wv: Dictionary = waves[0].duplicate(true)
	wv["id"] = wid
	if mw != null:
		mw.open_source(str(src["id"]), mw.now, 1.0e6)
	EnemySpawner.spawn_wave({"wave": wid, "deck": wave_deck, "source": str(src["id"]), "open_at": w.now, "max_units": 4},
		wv, src, {"stack": td.stack, "world": w, "squad": sq, "seed": 11, "crew": 1, "pool": mplan.pool(wave_deck),
		"skip_meshes": true})
	var units: Array[EnemyBase] = []
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == wid and not e.destroyed() and e.is_mobile() \
				and not (e is EnemyDrone or e is EnemyGunship or e is EnemyDropDrone):
			units.append(e)
	check(not units.is_empty(), "turnaround: the wave spawned ground units")
	# Walk until the first unit is well onto the ramp (15 s on it), then bring the crew back to deck 0.
	var walker: EnemyBase = null
	var on_ramp_t := 0.0
	for f in int(XDECK_TIME / DT):
		pt.repair_all()
		if mw != null:
			mw.advance_to(mw.now + DT)
		w.advance(DT)
		for u in units:
			if walker == null and is_instance_valid(u) and not u.destroyed() and u.is_on_transit_ramp():
				walker = u
		if walker != null:
			on_ramp_t += DT
			if on_ramp_t >= 15.0:
				break
	if not check(walker != null and walker.is_on_transit_ramp(), "turnaround: a unit is walking the ramp toward deck 1"):
		td.queue_free()
		await frames(3)
		return
	var entry: Vector3 = walker._transit_entry
	m_pos = place.call(wave_deck)
	var d0 := walker.global_position.distance_to(entry)
	var d_max := d0
	var back_t := -1.0
	var close_t := -1.0
	var limit := 15.0 + 40.0   # its 15 s back down the ramp + reaching the mech, at flank pace with headroom
	for f in int(limit / DT):
		pt.repair_all()
		if mw != null:
			mw.advance_to(mw.now + DT)
		w.advance(DT)
		if not is_instance_valid(walker) or walker.destroyed():
			break
		if back_t < 0.0:   # until it is off the ramp (then it walks on toward the mech, away from the entry)
			d_max = maxf(d_max, walker.global_position.distance_to(entry))
		var t := float(f + 1) * DT
		if back_t < 0.0 and walker.spawn_deck == wave_deck and not walker.is_on_transit_ramp():
			back_t = t
		if close_t < 0.0 and walker.spawn_deck == wave_deck and walker.global_position.distance_to(m_pos) <= CLOSE_DIST:
			close_t = t
			break
	print("[turn] %s (%s): from entry %.1f m at the crew's return, max %.1f m, off the ramp at %.1f s, close at %.1f s" % [
		walker.target_id, walker.enemy_type, d0, d_max, back_t, close_t])
	var spd := float(EnemyCatalog.unit(walker.enemy_type).get("flank_speed", 14.0))
	check(d_max <= d0 + spd * 1.5, "turnaround: %s turned round on the ramp (%.1f m from its entry when the crew returned, max %.1f m)" % [
		walker.target_id, d0, d_max])
	check(close_t >= 0.0, "turnaround: %s came back down and closed within %.0f m of the mech on deck 0 in %.0f s" % [
		walker.target_id, CLOSE_DIST, limit])
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == wid and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")
	td.queue_free()
	await frames(3)


func _probe_seed7_abandoned_defend() -> void:
	MissionFlow.test_plan = {"hold": 6.0}
	MissionFlow.test_director = {"rest_first": 1.5, "rest_last": 1.5, "arrival_rest": 1.0, "grace": 1.5, "follow_gap": 0.5}
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = 7
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
	for wv: Dictionary in pool.get("reserve", []):
		if str(wv.get("for", "")) == def_id:
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
