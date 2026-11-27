extends TestCase
## Gate-bay staging (docs/design/pacing-director.md "Staging in gate bays"; BayFormation, EnemySpawner.plan_wave with a
## bay, EnemyBase.staged / roll_out, EnemySquad.roll_out_wave, MissionWorld.source_bay). Behavioural, no pinned positions:
##   1. Formation (pure, seeds 1-60, mixed groups with a tank and a gunship): every footprint inside the usable rectangle,
##      no two overlapping, not collinear (spread across the lane), not clumped (mean nearest neighbour), deterministic for
##      a seed and different between seeds, the heaviest unit in the front row near the centre, fliers under the lintel,
##      every roll-out lane fits the door (a tank's included), a group bigger than the bay leaves the rest pending.
##   2. Real stack (seed 1, deck 1 gate with a bay): a group ordered 2 s before open_at is staged in the closed bay
##      (dormant: not hittable, not awake, not moving) until the door is passable, then every unit is out of the bay
##      within ROLL_LIMIT s and none is inside when the door closes.
##   3. A drone staged in the bay flies out under the lintel and reaches the crew (<= 80 m); a drone outside comes back
##      in through the open door toward a mech standing inside the bay.

const DT := 1.0 / 60.0
const ROLL_LIMIT := 12.0     ## s from passable until every staged unit has left the bay
const DRONE_LIMIT := 40.0    ## s for a drone to reach the crew
const DRONE_REACH := 80.0
const DRONE_IN_REACH := 45.0 ## m a drone must come to a mech standing inside an open bay


func _init() -> void:
	timeout_sec = 150.0


func setup() -> void:
	_formation()
	await _real_bay()
	finish()


func _bay() -> Dictionary:
	# A narrow lane gate as built (door 12.8 m x 9 m, usable 20 m x 16 m behind the wall), pointing +s into the deck.
	return BayFormation.from_world_bay({"ok": true, "origin": Vector2(5.0, -16.0), "out": Vector2(0, 1),
		"door": Vector2(5.0, 0.0), "half_width": 10.0, "depth_from": 8.0, "depth_to": 24.0, "height": 17.0,
		"door_w": 12.8, "door_h": 9.0, "exit_arc": Vector2(5.0, 6.0)})


func _formation() -> void:
	var bay := _bay()
	var kinds := ["trooper_rifle", "tank", "strider", "gunship", "strider_breacher", "trooper_at"]
	var layouts := {}
	var min_spread := INF
	var min_nn := INF
	for seed_ in range(1, 61):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_
		var sl := BayFormation.layout(bay, kinds, rng)
		var tag := "seed %d" % seed_
		if not eq(sl.size(), kinds.size(), tag + ": all 6 fit the bay"):
			continue
		var pts: Array[Vector2] = []
		for a: Dictionary in sl:
			var r := float(a["r"])
			check(absf(float(a["u"])) + r <= float(bay["half"]) + 0.001, tag + ": %s inside the side walls" % a["kind"])
			check(float(a["v"]) - r >= float(bay["v_min"]) - 0.001 and float(a["v"]) + r <= float(bay["v_max"]) + 0.001,
				tag + ": %s between the door margin and the back wall (v %.1f r %.1f)" % [a["kind"], float(a["v"]), r])
			check(float(a["v"]) - r >= BayFormation.DOOR_MARGIN - 0.001, tag + ": >= 4 m behind the door plane")
			pts.append(Vector2(float(a["u"]), float(a["v"])))
			if BayFormation.is_air(str(a["kind"])):
				check(float(a["h"]) + r <= float(bay["door_h"]) - BayFormation.LINTEL_CLEAR + r + 0.001 and float(a["h"]) <= 5.0,
					tag + ": %s hovers low (%.1f m) under the 9 m lintel" % [a["kind"], float(a["h"])])
		var nn_sum := 0.0
		for i in sl.size():
			var nn := INF
			for j in sl.size():
				if i == j:
					continue
				var d := pts[i].distance_to(pts[j])
				var need := float(sl[i]["r"]) + float(sl[j]["r"])
				check(d >= need - 0.001, tag + ": %s and %s do not overlap (%.2f >= %.2f)" % [sl[i]["kind"], sl[j]["kind"], d, need])
				nn = minf(nn, d)
			nn_sum += nn
		min_nn = minf(min_nn, nn_sum / float(sl.size()))
		# Not collinear: the smaller principal spread (about the best-fit line) is clearly non-zero.
		var c := Vector2.ZERO
		for p in pts:
			c += p
		c /= float(pts.size())
		var sxx := 0.0
		var syy := 0.0
		var sxy := 0.0
		for p in pts:
			sxx += (p.x - c.x) * (p.x - c.x)
			syy += (p.y - c.y) * (p.y - c.y)
			sxy += (p.x - c.x) * (p.y - c.y)
		var tr := (sxx + syy) / float(pts.size())
		var det := (sxx * syy - sxy * sxy) / float(pts.size() * pts.size())
		var small := tr * 0.5 - sqrt(maxf(tr * tr * 0.25 - det, 0.0))
		min_spread = minf(min_spread, sqrt(maxf(small, 0.0)))
		# The tank: front row, near the centre.
		for a: Dictionary in sl:
			if a["kind"] == "tank":
				check(float(a["v"]) - float(bay["v_min"]) <= float(a["r"]) + BayFormation.ROW_JITTER + BayFormation.JITTER + 0.01,
					tag + ": the tank is in the front rank (v %.1f)" % float(a["v"]))
				check(absf(float(a["u"])) <= 4.5, tag + ": the tank near the centre (u %.1f)" % float(a["u"]))
		layouts[seed_] = str(pts)
		# Roll-out lanes fit the door.
		for a: Dictionary in sl:
			var path := BayFormation.exit_path(bay, a, 15.0, CityPlan.CURB_H)
			var lane := absf((path[0].x) - 5.0)
			check(lane + float(a["r"]) <= float(bay["door_w"]) * 0.5 + 0.001, tag + ": %s's lane (%.1f) fits the door" % [a["kind"], lane])
			if BayFormation.is_air(str(a["kind"])):
				check(path[1].z <= float(bay["door_h"]) - BayFormation.LINTEL_CLEAR, tag + ": %s leaves under the lintel" % a["kind"])
				near(path[2].z, 15.0, 0.001, tag + ": then climbs to cruise height outside")
	print("formation: smallest cross-line spread %.2f m, smallest mean nearest neighbour %.2f m" % [min_spread, min_nn])
	check(min_spread >= 1.5, "never a straight line (smallest spread %.2f m)" % min_spread)
	check(min_nn >= 5.0, "never a tight clump (mean nearest neighbour >= 5 m, smallest %.2f)" % min_nn)
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 7
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 7
	eq(str(BayFormation.layout(bay, kinds, rng_a)), str(BayFormation.layout(bay, kinds, rng_b)), "deterministic for a seed")
	check(layouts[1] != layouts[2] and layouts[2] != layouts[3], "different between seeds")
	check(EnemySpawner.TANK_CLEAR * 2.0 + BayFormation.LANE_MARGIN * 2.0 <= 12.8, "a tank fits through the narrowest door")
	var many: Array = []
	for i in 20:
		many.append("tank")
	var rng_c := RandomNumberGenerator.new()
	var sl2 := BayFormation.layout(bay, many, rng_c)
	check(sl2.size() > 0 and sl2.size() < 20, "20 tanks do not fit: %d staged, the rest pending" % sl2.size())
	# The spawner with a bay: staged specs with roll-out paths, the overflow pending.
	var big := {"id": "bw", "share": 1.0, "theme": "mixed", "units": 6}
	var src := {"id": "s", "deck": 0, "kind": "gate", "x": 5.0, "s": 8.0, "toward": {"x": 5.0, "s": 28.0}, "load": 6, "bay": bay}
	var r := EnemySpawner.plan_wave(null, null, {"wave": "bw", "max_units": 6}, big, src, 10, 3, 0, 1.0)
	eq(int(r["spawn_count"]) + int(r["pending"]), 6, "6 units: staged + pending")
	for sp: Dictionary in r["specs"]:
		check(bool(sp.get("staged", false)) and (sp["exit"] as Array).size() == 3, "%s is staged with a roll-out path" % sp["type"])


# --- Real stack ---------------------------------------------------------------------------------------------------

func _real_bay() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = 1
	add_child(td)
	await frames(6)
	td.drive_override = true
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)
	var mf := td.mission
	mf.set_physics_process(false)
	var sq: EnemySquad = td.combat.squad
	var w: CombatWorld = td.combat.world
	var mw: MissionWorld = td.stack.mission
	var pt: PlayerTarget = td.combat.player_target
	for e in sq.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")
	w.advance(DT)
	var k := 1
	var src := {}
	var bay := {}
	for s: Dictionary in mf.plan.deck_sources(k):
		var b := mf.source_bay(str(s["id"]))
		if not b.is_empty():
			src = s.duplicate(true)
			bay = b
			break
	if not check(not bay.is_empty(), "deck 2 has a gate with a staging bay"):
		td.queue_free()
		return
	var sid := str(src["id"])
	src["point"] = mw.source_point(sid)
	src["bay"] = bay
	var out: Vector2 = bay["out"]
	var door: Vector2 = bay["door"]
	print("bay %s: door (%.0f, %.0f) out (%.2f, %.2f) half %.1f v %.1f..%.1f door %.1f x %.1f" % [sid, door.x, door.y, out.x,
		out.y, float(bay["half"]), float(bay["v_min"]), float(bay["v_max"]), float(bay["door_w"]), float(bay["door_h"])])
	# The crew on the road node nearest 110 m in front of the door.
	var want := door + out * 110.0
	var node: Vector2 = want
	var best := INF
	for rn: Vector2 in CityGraphs.road_graph(td.stack.decks[k].plan)["nodes"]:
		if rn.distance_to(want) < best:
			best = rn.distance_to(want)
			node = rn
	var m_pos := td.stack.from_deck_arc(k, node.x, node.y, 0.5)
	td.mech.global_position = m_pos
	pt.global_position = m_pos
	await frames(2)
	# Order: staged at once, open_at 2 s later, passable OPENING after.
	var open_at := mw.now + 2.0
	mw.open_source(sid, open_at, 12.0, mw.now)
	var wid := "bay_test"
	var wv := {"id": wid, "share": 1.0, "theme": "heavy", "units": 6}
	var order := {"wave": wid, "deck": k, "source": sid, "open_at": open_at, "max_units": 6}
	EnemySpawner.spawn_wave(order, wv, src, {"stack": td.stack, "world": w, "squad": sq, "seed": 5, "crew": 1,
		"pool": mf.plan.pool(k), "skip_meshes": true})
	var units: Array[EnemyBase] = []
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == wid:
			units.append(e)
	check(units.size() >= 3, "the group is created at the order (%d units)" % units.size())
	var start := {}
	for u in units:
		start[u.target_id] = u.global_position
		check(u.staged and not u.is_hittable() and not u._is_awake(), "%s staged: dormant and not hittable" % u.enemy_type)
		check(_behind(td, k, u, door, out) > 2.0, "%s stands inside the bay (%.1f m behind the door)" % [u.enemy_type,
			_behind(td, k, u, door, out)])
	# Until passable nothing moves.
	var passable_at := float(mw.source_state(sid).get("passable_at", open_at + MissionWorld.OPENING))
	while mw.now < passable_at - DT:
		mw.advance_to(mw.now + DT)
		w.advance(DT)
	for u in units:
		check(is_instance_valid(u) and not u.destroyed(), "%s was not culled while staged (the bay reaches 26 m behind the wall)" % u.enemy_type)
		check(u.global_position.distance_to(start[u.target_id]) < 0.05, "%s did not move behind the closed door" % u.enemy_type)
	check(not bool(mw.source_state(sid).get("passable", true)), "the door is not passable yet")
	mw.advance_to(passable_at + DT)
	check(bool(mw.source_state(sid).get("passable", false)), "the door is passable at open_at + OPENING")
	sq.roll_out_wave(wid)
	mw.hold_source(sid, mw.now + 15.0)
	var out_t := {}
	var t := 0.0
	while t < ROLL_LIMIT + 2.0:
		t += DT
		mw.advance_to(mw.now + DT)
		w.advance(DT)
		for u in units:
			if not out_t.has(u.target_id) and is_instance_valid(u) and _behind(td, k, u, door, out) < -1.0:
				out_t[u.target_id] = t
		if out_t.size() == units.size():
			break
	for u in units:
		check(out_t.has(u.target_id) and float(out_t[u.target_id]) <= ROLL_LIMIT, "%s left the bay within %.0f s (%s)" % [
			u.enemy_type, ROLL_LIMIT, str(out_t.get(u.target_id, "never"))])
	print("roll-out: %s" % str(out_t))
	var close_at := float(mw.source_state(sid).get("close_at", INF))
	var inside := 0
	for u in units:
		if is_instance_valid(u) and not u.destroyed() and _behind(td, k, u, door, out) > 0.0:
			inside += 1
	check(mw.now < close_at, "the door is still open after the roll-out")
	eq(inside, 0, "nobody is left inside the bay before the door closes")
	for u in units:
		if is_instance_valid(u) and not u.destroyed():
			u.apply_damage(1.0e7, u.core_component(), "test")
	# A drone staged in the bay: out under the lintel, then to the crew.
	var drone := _stage_drone(td, sq, w, k, bay, "bay_drone_1")
	await frames(1)
	var low := INF
	var top := 0.0
	var reached := INF
	drone.roll_out(drone.get_meta("exit_path"), 0.0)
	t = 0.0
	while t < DRONE_LIMIT:
		t += DT
		mw.advance_to(mw.now + DT)
		w.advance(DT)
		if not is_instance_valid(drone) or drone.destroyed():
			break
		var b := _behind(td, k, drone, door, out)
		if b > -0.5 and b < 3.0:
			top = maxf(top, td.stack.deck_ring(k).height(drone.global_position))
		reached = minf(reached, drone.global_position.distance_to(m_pos))
		if reached <= DRONE_REACH:
			break
	check(top <= float(bay["door_h"]) - 0.5, "the drone crossed the door plane under the lintel (%.1f m <= %.1f)" % [top, float(bay["door_h"])])
	check(reached <= DRONE_REACH, "the drone reached the crew (%.0f m <= %.0f) in %.1f s" % [reached, DRONE_REACH, t])
	# Back in: the mech stands inside the open bay; a drone outside must come in through the door toward it.
	mw.hold_source(sid, mw.now + 200.0)
	var inside_pt := door - out * 12.0
	var in_pos := td.stack.from_deck_arc(k, inside_pt.x, inside_pt.y, 0.5)
	td.mech.global_position = in_pos
	pt.global_position = in_pos
	await frames(2)
	var closest := INF
	t = 0.0
	while t < DRONE_LIMIT and is_instance_valid(drone) and not drone.destroyed():
		t += DT
		pt.repair_all()
		mw.advance_to(mw.now + DT)
		w.advance(DT)
		closest = minf(closest, drone.global_position.distance_to(in_pos))
		if closest <= DRONE_IN_REACH * 0.5:
			break
	print("drone back in: closest %.1f m to the mech inside the bay" % closest)
	check(closest <= DRONE_IN_REACH, "a drone comes back toward a target inside the open bay (%.1f m <= %.0f)" % [closest, DRONE_IN_REACH])
	td.queue_free()
	await frames(3)


## Metres behind the door plane (positive inside the bay, negative out on the deck).
func _behind(td: MissionScene, k: int, e: Node3D, door: Vector2, out: Vector2) -> float:
	var a := td.stack.to_deck_arc(e.global_position)
	return -(Vector2(float(a["x"]), float(a["s"])) - door).dot(out)


func _stage_drone(td: MissionScene, sq: EnemySquad, w: CombatWorld, k: int, bay: Dictionary, id: String) -> EnemyBase:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var sl := BayFormation.layout(bay, ["drone"], rng)
	var a: Dictionary = sl[0]
	var cruise := CityPlan.CURB_H + EnemySpawner.DRONE_CRUISE_ALT
	var path := BayFormation.exit_path(bay, a, cruise, CityPlan.CURB_H)
	var at: Vector2 = a["arc"]
	var spec := {"id": id, "type": "drone", "x": at.x, "s": at.y, "h": CityPlan.CURB_H + float(a["h"]), "yaw_arc": 0.0,
		"wave": id, "staged": true}
	var made := EnemySpawner.spawn_specs([spec] as Array[Dictionary], td.stack.decks[k].plan, td.stack.deck_ring(k), w, sq,
		9, true, "", k, id)
	var d := made[0]
	d.set_meta("exit_path", path)
	var tgt := td.combat.player_target
	d.begin_hunt_pursuit(tgt, tgt.global_position)
	return d
