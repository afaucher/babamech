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
##   4. Nobody is shut in (playtest R2.4, MissionBays through MissionFlow's own roll-out / hold path): a unit standing in
##      the doorway keeps the door open past its normal close, is pushed out at the hard limit and the door then shuts
##      with it outside; a unit walking back into the open bay is walked out at once; one that cannot be got out is
##      withdrawn after the push (no death, no wreck, not alive for the sweep / "beaten"); a follow-up ordered so its door
##      would open just after the close never snaps the leaves shut ("warn") in between; a staged group whose door is
##      sealed before it opens is withdrawn (not left dormant); a client-side shot at a staged unit does nothing (the
##      host refuses hits on staged units).
##   5. Lift cars (R2.22), REAL lifts on seeds LIFT_SEEDS: every lift source answers a car; the car's fit (printed) and
##      every rolled lift group's full load inside the usable car (no tanks / fliers; a tank would fit); a group ordered
##      through MissionFlow stages inside the car (dormant, unhittable, still) until passable, all out within LIFT_LIMIT s,
##      none inside at the close, none stuck at the door or back inside afterwards, the follow-up load works, the INBOUND
##      marker sits at the lift door.
##   5b. Crew never shut in (MissionBays rule 5), on a gate bay and a lift car: a pilot inside holds the door open past its
##      close with no limit (crew_inside / busy_sources), the director picks another source meanwhile, the door shuts once
##      the pilot is out, and a shut door with a pilot inside opens again (one re-open order).
##   6. Soak (seeds SOAK_SEEDS): every reserve group of every deck released by the real director (fast options), the crew
##      standing on each deck in turn: at every door close no live unit is inside its bay.

const DT := 1.0 / 60.0
const LIFT_LIMIT := 10.0     ## s from passable until every unit has left a lift car
const LIFT_SEEDS := [1, 4, 7, 22, 403112]
const KEEP_CLOSE := 25.0     ## s for a door to shut once the pilot is out (KEEP + CLOSE + slack)
const REOPEN_LIMIT := 12.0   ## s for a shut door with a pilot inside to be passable again
const SOAK_SEEDS := [1, 4, 7, 22, 403112]
const SOAK_DECK := 90.0      ## s of mission per deck in the soak
const SOAK_DIRECTOR := {"rest_first": 3.0, "rest_last": 2.0, "arrival_rest": 1.0, "grace": 3.0, "follow_gap": 0.5}
const ROLL_LIMIT := 12.0     ## s from passable until every staged unit has left the bay
const DRONE_LIMIT := 40.0    ## s for a drone to reach the crew
const DRONE_REACH := 80.0
const DRONE_IN_REACH := 45.0 ## m a drone must come to a mech standing inside an open bay


func _init() -> void:
	timeout_sec = 900.0


func setup() -> void:
	_formation()
	await _real_bay()
	await _guard_rules()
	await _lift_car()
	await _crew_rules()
	await _soak()
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



# --- Nobody is shut in (R2.4) ---------------------------------------------------------------------------------------

## A solo stack drive on `seed_n` driven by hand (MissionFlow / CombatWorld physics off; _tick steps them).
func _drive(seed_n: int, kill_garrison: bool) -> MissionScene:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = seed_n
	add_child(td)
	await frames(6)
	td.drive_override = true
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)
	td.mission.set_physics_process(false)
	if kill_garrison:
		for e in td.combat.squad.enemies.duplicate():
			if is_instance_valid(e) and not e.destroyed():
				e.apply_damage(1.0e7, e.core_component(), "test")
		td.combat.world.advance(DT)
	return td


## One host step of the bay machinery as MissionFlow runs it (_spawn_due: _roll_due then bays.tick).
func _tick(td: MissionScene) -> void:
	var mw := td.stack.mission
	var mf := td.mission
	mw.advance_to(mw.now + DT)
	mf._clock = mw.now
	td.combat.world.advance(DT)
	mf._roll_due()
	mf.bays.tick(DT)
	td.combat.player_target.repair_all()


## A group ordered through MissionFlow's own path (_open, staged by the spawner, _rollouts): its units.
func _order(td: MissionScene, k: int, sid: String, wid: String, theme: String, n: int, open_at: float, seed_n: int) -> Array[EnemyBase]:
	var mf := td.mission
	var mw := td.stack.mission
	var o := {"wave": wid, "deck": k, "source": sid, "open_at": open_at, "max_units": n, "reason": "test", "order_t": mw.now}
	mf._open(o)
	var src := mf.plan.source(sid).duplicate()
	src["point"] = mw.source_point(sid)
	src["bay"] = mf.source_bay(sid)
	EnemySpawner.spawn_wave(o, {"id": wid, "share": 1.0, "theme": theme, "units": n}, src, {"stack": td.stack,
		"world": td.combat.world, "squad": td.combat.squad, "seed": seed_n, "crew": 1, "pool": mf.plan.pool(k), "skip_meshes": true})
	mf._rollouts.append({"wave": wid, "source": sid, "open_at": open_at})
	var out: Array[EnemyBase] = []
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave == wid:
			out.append(e)
	return out


func _gate_with_bay(td: MissionScene, k: int) -> String:
	for s: Dictionary in td.mission.plan.deck_sources(k):
		if not td.mission.source_bay(str(s["id"])).is_empty():
			return str(s["id"])
	return ""


func _put(td: MissionScene, k: int, e: EnemyBase, bay: Dictionary, depth: float, lat: float = 0.0) -> void:
	var o: Vector2 = bay["out"]
	var p: Vector2 = (bay["door"] as Vector2) - o * depth + Vector2(-o.y, o.x) * lat
	e.global_position = td.stack.from_deck_arc(k, p.x, p.y, CityPlan.CURB_H)


func _place_crew(td: MissionScene, k: int, bay: Dictionary, dist: float) -> void:
	var want: Vector2 = (bay["door"] as Vector2) + (bay["out"] as Vector2) * dist
	var node: Vector2 = want
	var best := INF
	for rn: Vector2 in CityGraphs.road_graph(td.stack.decks[k].plan)["nodes"]:
		if rn.distance_to(want) < best:
			best = rn.distance_to(want)
			node = rn
	var m_pos := td.stack.from_deck_arc(k, node.x, node.y, 0.5)
	td.mech.global_position = m_pos
	td.combat.player_target.global_position = m_pos


func _ev(evs: Array, id: String, ev: String) -> Dictionary:
	for e: Dictionary in evs:
		if str(e["id"]) == id and str(e["ev"]) == ev:
			return e
	return {}


func _guard_rules() -> void:
	var td: MissionScene = await _drive(1, true)
	var mf := td.mission
	var mw := td.stack.mission
	var sq: EnemySquad = td.combat.squad
	var k := 1
	var sid := _gate_with_bay(td, k)
	if not check(sid != "", "guard: deck 2 has a gate bay"):
		td.queue_free()
		return
	var bay := mf.source_bay(sid)
	_place_crew(td, k, bay, 110.0)
	await frames(2)
	# A + B: one unit stands in the doorway (pushable), one is held deep inside (cannot be got out).
	var units := _order(td, k, sid, "guard_a", "light", 3, mw.now + 2.0, 11)
	if not check(units.size() >= 2, "guard: the group is staged (%d)" % units.size()):
		td.queue_free()
		return
	var t := 0.0
	while t < 25.0:
		t += DT
		_tick(td)
		var busy := false
		for u in units:
			if is_instance_valid(u) and (u.staged or u.is_rolling_out()):
				busy = true
		if not busy and t > 6.0:
			break
	var normal := float(mw.source_state(sid)["close_at"])
	var u0 := units[0]
	var u1 := units[1]
	u0.ai_mode = "idle"
	u1.ai_mode = "idle"
	_put(td, k, u0, bay, 0.5)
	_put(td, k, u1, bay, 12.0)
	var u1_died := [false]
	u1.destroyed_enemy.connect(func(_e: EnemyBase, _c: String, _p: Vector3) -> void: u1_died[0] = true)
	var u1_id := u1.target_id
	var u0_id := u0.target_id
	var open_after_normal := false
	var limit := normal + MissionBays.HARD_LIMIT
	var shut_t := INF
	var end_t := limit + MissionBays.PUSH_MAX + 12.0
	while mw.now < end_t:
		_tick(td)
		if is_instance_valid(u1) and u1 in sq.enemies:
			u1.roll_out([] as Array[Vector3], 0.0)   # stuck: whatever pushes it, it stays deep inside
			_put(td, k, u1, bay, 12.0)
		var st := str(mw.source_state(sid)["state"])
		if mw.now > normal + 2.0 and mw.now < normal + 3.0 and st == "open":
			open_after_normal = true
		if st == "shut":
			shut_t = mw.now
			break
	var evs: Array = mf.bays.events
	print("guard events: %s" % str(evs))
	check(open_after_normal, "a unit in the doorway keeps the door open past its normal close (%.1f)" % normal)
	check(not _ev(evs, u1_id, "reentry").is_empty(), "a unit found deep inside the open bay is walked out (reentry)")
	var push0 := _ev(evs, u0_id, "push")
	check(not push0.is_empty() and float(push0.get("t", 0.0)) >= limit - 0.3, "the doorway unit is pushed out at the hard limit (%s, limit %.1f)" % [
		str(push0.get("t", "never")), limit])
	var rem := _ev(evs, u1_id, "removed")
	check(not rem.is_empty() and float(rem.get("t", 0.0)) >= limit + MissionBays.PUSH_MAX - 0.3,
		"the stuck unit is withdrawn after the push (%s)" % str(rem.get("t", "never")))
	check(not is_instance_valid(u1) or not (u1 in sq.enemies), "the withdrawn unit left the squad (not alive for the sweep)")
	check(not u1_died[0], "withdrawn, not killed (no death, no wreck, no credit)")
	var wc: Dictionary = sq.wave_counts().get("guard_a", {})
	eq(int(wc.get("total", 0)), units.size(), "the group's total still counts the withdrawn unit (beaten bookkeeping)")
	check(int(wc.get("alive", 99)) <= units.size() - 1, "and it is not alive (%s)" % str(wc))
	check(shut_t < INF, "the door shuts once nobody is inside (%.1f)" % shut_t)
	if is_instance_valid(u0):
		var b0 := _behind(td, k, u0, bay["door"], bay["out"])
		check(b0 < -1.0 and not u0.destroyed(), "the pushed unit is out on the street, alive (%.1f m)" % b0)
	for u in units:
		if is_instance_valid(u) and not u.destroyed() and u in sq.enemies:
			u.apply_damage(1.0e7, u.core_component(), "test")
	# C: a follow-up whose door would open just after the close: extended, never snapped shut into "warn".
	var g1 := _order(td, k, sid, "guard_d", "light", 2, mw.now + 2.0, 12)
	var states: Array = []
	var ordered2 := false
	var g2: Array[EnemyBase] = []
	t = 0.0
	while t < 60.0:
		t += DT
		_tick(td)
		var st2 := mw.source_state(sid)
		var s := str(st2["state"])
		if states.is_empty() or str(states.back()) != s:
			states.append(s)
		if not ordered2 and s == "open" and float(st2["close_at"]) - mw.now < 1.5:
			ordered2 = true
			g2 = _order(td, k, sid, "guard_d2", "light", 2, float(st2["close_at"]) + 1.0, 13)
		if ordered2 and s == "shut":
			break
	print("guard follow-up door states: %s" % str(states))
	check(ordered2, "the follow-up was ordered while the door was open")
	var first_open := states.find("open")
	check(first_open >= 0 and not ("warn" in states.slice(first_open)), "the open door never snapped shut for the follow-up (%s)" % str(states))
	var rolled := 0
	for u in g2:
		if is_instance_valid(u) and not u.staged:
			rolled += 1
	eq(rolled, g2.size(), "the follow-up group rolled out through the held door")
	for u in g1 + g2:
		if is_instance_valid(u) and not u.destroyed() and u in sq.enemies:
			u.apply_damage(1.0e7, u.core_component(), "test")
	# D: staged units refuse hits (a client's shot), and a staged group whose door is sealed is withdrawn (rule 5).
	var gs := _order(td, k, sid, "guard_s", "light", 2, mw.now + 2.0, 14)
	if check(not gs.is_empty(), "the sealed-door group is staged"):
		var u := gs[0]
		var hp0 := u.core_hp_ratio()
		u.apply_damage(500.0, u.core_component(), "client_shot")
		eq(u.core_hp_ratio(), hp0, "a hit on a staged unit does nothing (the host refuses it)")
	mw.close_source(sid)
	for i in 240:   # an open door closes over CLOSE s before it counts as sealed
		_tick(td)
	var left := 0
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == "guard_s":
			left += 1
	eq(left, 0, "a staged group behind a sealed door is withdrawn, not left dormant")
	td.queue_free()
	await frames(3)


# --- Lift car (R2.22) -----------------------------------------------------------------------------------------------

func _lift_car() -> void:
	# Footprints (EnemySpawner clearance radius; catalog body radius / sphere top) against Environment's car.
	var rows := PackedStringArray()
	for kind: String in ["tank", "strider", "strider_breacher", "trooper_rifle", "trooper_at", "gunship", "drone"]:
		var c := EnemyCatalog.unit(kind)
		var top := 0.0
		for comp: Dictionary in c.get("components", []):
			for sp: Dictionary in comp.get("spheres", []):
				top = maxf(top, (sp["center"] as Vector3).y + float(sp["radius"]))
		rows.append("%s clear r %.1f, body r %.1f, top %.1f m" % [kind, BayFormation.radius_of(kind), float(c.get("body_radius", 0.0)), top])
	print("footprints: %s" % "; ".join(rows))
	for seed_n: int in LIFT_SEEDS:
		await _lift_seed(seed_n)


## The car's fit (pure, over formation seeds; printed) and every rolled lift group's load (the plan's lift load) inside the
## usable car.
func _lift_fit(bay: Dictionary, tag: String) -> void:
	var o: Vector2 = bay["out"]
	var sets: Array = []
	for kind: String in ["strider", "strider_breacher", "trooper_rifle"]:
		var ks: Array = []
		for i in 12:
			ks.append(kind)
		sets.append(ks)
	sets.append(["tank", "strider", "strider"])
	sets.append(["tank", "strider", "trooper_rifle", "trooper_rifle", "trooper_at"])
	for kinds: Array in sets:
		var lo := 99
		var hi := 0
		for s in range(1, 41):
			var rng := RandomNumberGenerator.new()
			rng.seed = s
			var n := BayFormation.layout(bay, kinds, rng).size()
			lo = mini(lo, n)
			hi = maxi(hi, n)
		print("%s fit: %d..%d of %d (%s)" % [tag, lo, hi, kinds.size(), ",".join(PackedStringArray(kinds.slice(0, 2)))])
		if kinds[0] == "tank" and kinds.size() == 3:
			check(lo == kinds.size(), "%s: a tank fits the car with %s (composition unchanged: lifts roll no tank)" % [tag, str(kinds.slice(1))])
	var lo_g := 99
	var hist := {}
	var u_max := 0.0
	var v_lo := INF
	var v_hi := 0.0
	var ld := int(MissionPlan.LOAD["lift"])
	for s in range(1, 41):
		var theme: String = ["light", "mixed", "heavy"][s % 3]
		var r := EnemySpawner.plan_wave(null, null, {"wave": "lf", "max_units": 6}, {"id": "lf", "share": 1.0,
			"theme": theme, "units": 6}, {"id": "l", "kind": "lift", "x": 0.0, "s": 0.0, "load": ld, "bay": bay}, 10, s, 0, 1.0)
		lo_g = mini(lo_g, int(r["spawn_count"]))
		hist[int(r["spawn_count"])] = int(hist.get(int(r["spawn_count"]), 0)) + 1
		for sp: Dictionary in r["specs"]:
			check(not (str(sp["type"]) in ["tank", "gunship", "drone"]), "%s: lift groups roll no tank / flier (%s)" % [tag, sp["type"]])
			var rel := Vector2(float(sp["x"]), float(sp["s"])) - (bay["door"] as Vector2)
			var rad := BayFormation.radius_of(str(sp["type"]))
			u_max = maxf(u_max, absf(rel.dot(Vector2(-o.y, o.x))) + rad)
			v_lo = minf(v_lo, -rel.dot(o) - rad)
			v_hi = maxf(v_hi, -rel.dot(o) + rad)
	print("%s: rolled lift groups (load %d, 40 rolls, staged: count) %s; footprints |lateral| <= %.1f m (usable %.1f), %.1f..%.1f m in (usable %.1f..%.1f)" % [
		tag, ld, str(hist), u_max, float(bay["half"]), v_lo, v_hi, float(bay["v_min"]), float(bay["v_max"])])
	check(lo_g >= ld - 1, "%s: a rolled lift group stages at least %d of its %d in the real car (%d; the rest is the follow-up load)" % [tag, ld - 1, ld, lo_g])
	check(u_max <= float(bay["half"]) + 0.001 and v_lo >= float(bay["v_min"]) - 0.001 and v_hi <= float(bay["v_max"]) + 0.001,
		"%s: the formation stays inside the usable car" % tag)


## One seed: every lift answers a car; on EVERY lift (every deck) a 6-unit group is ordered through MissionFlow's own
## path: staged in the car (dormant, unhittable, still), out through the doorway once passable, nobody inside at the
## close, no unit stuck at / back in the door afterwards, the INBOUND marker at the lift door; on the first lift also the
## follow-up load stages and rolls out.
func _lift_seed(seed_n: int) -> void:
	var td: MissionScene = await _drive(seed_n, true)
	var mf := td.mission
	var tag := "lift seed %d" % seed_n
	var lifts: Array = []
	var no_car := 0
	for s: Dictionary in mf.plan.sources:
		if str(s["kind"]) != "lift":
			continue
		if mf.source_bay(str(s["id"])).is_empty():
			no_car += 1
		else:
			lifts.append(s)
	print("%s: %d lift sources with a car, %d without" % [tag, lifts.size(), no_car])
	eq(no_car, 0, "%s: every lift source answers a car (source_bay ok)" % tag)
	if lifts.is_empty():
		td.queue_free()
		await frames(3)
		return
	for i in lifts.size():
		await _lift_run(td, lifts[i], "%s %s" % [tag, str(lifts[i]["id"])], seed_n, i == 0)
	td.queue_free()
	await frames(3)


## One lift of a seed: a group ordered through MissionFlow's path (see _lift_seed); `follow`: also its follow-up load (and
## the car's fit table).
func _lift_run(td: MissionScene, src: Dictionary, tag: String, seed_n: int, follow: bool) -> void:
	var mf := td.mission
	var mw := td.stack.mission
	var sq: EnemySquad = td.combat.squad
	var wid := "lift_%s" % str(src["id"])
	var sid := str(src["id"])
	var k := int(src["deck"])
	var bay := mf.source_bay(sid)
	var wb := mw.source_bay(sid)
	if follow:
		_lift_fit(bay, tag)
	_place_crew(td, k, bay, 110.0)
	await frames(2)
	var open_at := mw.now + 2.0
	var units := _order(td, k, sid, wid, "mixed", 6, open_at, 21 + seed_n)
	var o: Vector2 = bay["out"]
	check(units.size() >= 1 and units.size() <= int(MissionPlan.LOAD["lift"]), "%s: the group is created at the order inside the car (%d, load %d)" % [
		tag, units.size(), int(MissionPlan.LOAD["lift"])])
	var start := {}
	for u in units:
		start[u.target_id] = u.global_position
		var c0 := MissionBays.contains_in(wb, u.global_position, mw, sid)
		check(u.staged and not u.is_hittable() and not u._is_awake(), "%s: %s staged in the car: dormant, not hittable" % [tag, u.enemy_type])
		check(bool(c0["inside"]), "%s: %s stands inside the car (%.1f m in)" % [tag, u.enemy_type, float(c0["depth"])])
	var ap: Variant = mf.alert_point({"source": sid, "deck": k})
	var door_w: Vector3 = (wb["frame"] as Transform3D).origin
	check(ap is Vector3 and (ap as Vector3).distance_to(door_w) < 6.0, "%s: the INBOUND marker sits at the lift door (%s m)" % [tag,
		str((ap as Vector3).distance_to(door_w)) if ap is Vector3 else "none"])
	var passable_at := float(mw.source_state(sid).get("passable_at", open_at + MissionWorld.passable_after("lift")))
	var early := 0
	var moved := 0
	var out_t := {}
	var t := 0.0
	var inside_at_close := -1
	while t < 60.0:
		t += DT
		_tick(td)
		if mw.now < passable_at - DT:
			for u in units:
				if not u.staged:
					early += 1
				elif u.global_position.distance_to(start[u.target_id]) > 0.05:
					moved += 1
			continue
		for u in units:
			if not out_t.has(u.target_id) and is_instance_valid(u) and _behind(td, k, u, bay["door"], o) < -1.0:
				out_t[u.target_id] = mw.now - passable_at
		var st := str(mw.source_state(sid)["state"])
		if st == "closing" and inside_at_close < 0:
			inside_at_close = 0
			for u in units:
				if is_instance_valid(u) and not u.destroyed() and u in sq.enemies \
						and bool(MissionBays.contains_in(wb, u.global_position, mw, sid)["inside"]):
					inside_at_close += 1
		if st == "shut" and inside_at_close >= 0:
			break
	eq(early, 0, "%s: nobody leaves the car before its door is passable" % tag)
	eq(moved, 0, "%s: nobody moves inside the shut car" % tag)
	for u in units:
		check(out_t.has(u.target_id) and float(out_t[u.target_id]) <= LIFT_LIMIT, "%s: %s left the car within %.0f s of passable (%s)" % [
			tag, u.enemy_type, LIFT_LIMIT, str(out_t.get(u.target_id, "never"))])
	print("%s: %s roll-out %s" % [tag, sid, str(out_t)])
	eq(inside_at_close, 0, "%s: nobody is inside the car when its door closes" % tag)
	# After the roll-out: on its own AI outside, not stuck at the door, never back in, nobody walked out again / withdrawn.
	var back_in := 0
	var near_door := 0
	for u in units:
		if not is_instance_valid(u) or u.destroyed() or not (u in sq.enemies):
			continue
		var c := MissionBays.contains_in(wb, u.global_position, mw, sid)
		if bool(c["inside"]):
			back_in += 1
		if absf(float(c["depth"])) < 3.0 and absf(_lat(td, k, u, bay)) < 8.0:
			near_door += 1
		check(not u.is_rolling_out() and not u.staged, "%s: %s is on its own AI outside" % [tag, u.enemy_type])
	eq(back_in, 0, "%s: no unit is back inside the car" % tag)
	eq(near_door, 0, "%s: no unit is stuck at the lift door" % tag)
	var redo := 0
	for ev: Dictionary in mf.bays.events:
		if str(ev["src"]) == sid and str(ev["ev"]) in ["removed", "reentry", "push"]:
			redo += 1
	eq(redo, 0, "%s: nobody had to be walked out again, pushed or withdrawn" % tag)
	if not follow:
		_kill_wave(sq, wid)
		return
	# The follow-up load of the same group: staged in the car, then out like the first.
	var seen := {}
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == wid:
			seen[e.target_id] = true
	var open2 := mw.now + 2.0
	_order(td, k, sid, wid, "mixed", 6, open2, 21 + seed_n)
	var more: Array[EnemyBase] = []
	for e in sq.enemies:
		if is_instance_valid(e) and e.wave == wid and not seen.has(e.target_id):
			more.append(e)
	check(not more.is_empty(), "%s: the follow-up load stages in the car (%d more)" % [tag, more.size()])
	for u in more:
		check(u.staged and bool(MissionBays.contains_in(wb, u.global_position, mw, sid)["inside"]), "%s: follow-up %s staged inside" % [tag, u.enemy_type])
	var pass2 := float(mw.source_state(sid).get("passable_at", open2 + 1.5))
	t = 0.0
	while t < 40.0 and mw.now < pass2 + LIFT_LIMIT:
		t += DT
		_tick(td)
	for u in more:
		check(is_instance_valid(u) and not u.staged and _behind(td, k, u, bay["door"], o) < -1.0,
			"%s: follow-up %s rolled out of the car" % [tag, u.enemy_type])
	_kill_wave(sq, wid)


func _kill_wave(sq: EnemySquad, wid: String) -> void:
	for e in sq.enemies.duplicate():
		if is_instance_valid(e) and e.wave == wid and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


func _lat(td: MissionScene, k: int, e: Node3D, bay: Dictionary) -> float:
	var a := td.stack.to_deck_arc(e.global_position)
	var o: Vector2 = bay["out"]
	return (Vector2(float(a["x"]), float(a["s"])) - (bay["door"] as Vector2)).dot(Vector2(-o.y, o.x))


# --- Crew mechs are never shut in (MissionBays rule 5) ------------------------------------------------------------

func _crew_rules() -> void:
	var td: MissionScene = await _drive(1, true)
	var mf := td.mission
	var mw := td.stack.mission
	var ids: Array = []
	var gate := _gate_with_bay(td, 1)
	if gate != "":
		ids.append(gate)
	for s: Dictionary in mf.plan.sources:
		if str(s["kind"]) == "lift" and not mf.source_bay(str(s["id"])).is_empty():
			ids.append(str(s["id"]))
			break
	check(ids.size() == 2, "crew: a gate bay and a lift car to stand in (%s)" % str(ids))
	for sid: String in ids:
		var kd := int(mf.plan.source(sid)["deck"])
		var bay := mf.source_bay(sid)
		var tag := "crew %s" % sid
		var slots := mw.bay_slots(sid, 1)
		if not check(not slots.is_empty(), tag + ": a stand point inside"):
			continue
		var inside_p := slots[0].origin
		# 1. A pilot inside keeps the door open past its close, with no limit.
		_place_crew(td, kd, bay, 110.0)
		check(not mf.bays.crew_inside(sid), tag + ": crew_inside false with the mech out on the deck")
		mw.open_source(sid, mw.now + 0.5, 3.0, mw.now)
		var normal := float(mw.source_state(sid)["close_at"])
		while mw.now < normal - 1.0:
			_tick(td)
		td.mech.global_position = inside_p
		td.combat.player_target.global_position = inside_p
		check(mf.bays.crew_inside(sid), tag + ": crew_inside true with the mech in the bay")
		check(mf.bays.busy_sources().has(sid), tag + ": the door is busy for the director")
		var not_open := 0
		var end_t := normal + MissionBays.HARD_LIMIT + MissionBays.PUSH_MAX + 5.0
		while mw.now < end_t:
			_tick(td)
			if str(mw.source_state(sid)["state"]) != "open":
				not_open += 1
		eq(not_open, 0, tag + ": the door stayed open %.0f s past its close (past the units' hard limit) with a pilot inside" % (end_t - normal))
		# 2. Never staged onto the pilot: no release picks the busy door.
		var dir := mf.director
		dir._busy = mf.bays.busy_sources()
		var door_arc: Vector2 = bay["door"]
		var picks := {}
		for quick: bool in [false, true]:
			picks[dir._pick_source_at(kd, door_arc, {}, [], quick)] = true
		picks[dir._pick_flag_source(kd, door_arc, {}, [])] = true
		check(not picks.has(sid), tag + ": the director picks another source while a pilot stands in it (%s)" % str(picks.keys()))
		dir._busy = {}
		# 3. The pilot out: the door shuts.
		_place_crew(td, kd, bay, 110.0)
		var t := 0.0
		while t < KEEP_CLOSE and str(mw.source_state(sid)["state"]) != "shut":
			t += DT
			_tick(td)
		eq(str(mw.source_state(sid)["state"]), "shut", tag + ": with the pilot out the door shuts (%.1f s)" % t)
		# 4. A shut door with a pilot inside (respawned there) opens again.
		td.mech.global_position = inside_p
		td.combat.player_target.global_position = inside_p
		var opened := false
		t = 0.0
		while t < REOPEN_LIMIT:
			t += DT
			_tick(td)
			if bool(mw.source_state(sid).get("passable", false)):
				opened = true
				break
		check(opened, tag + ": a shut door with a pilot inside opens again (%.1f s)" % t)
		var reo := 0
		for ev: Dictionary in mf.bays.events:
			if str(ev["src"]) == sid and str(ev["ev"]) == "crew_reopen":
				reo += 1
		eq(reo, 1, tag + ": one re-open order")
		_place_crew(td, kd, bay, 110.0)
		t = 0.0
		while t < KEEP_CLOSE and str(mw.source_state(sid)["state"]) != "shut":
			t += DT
			_tick(td)
	td.queue_free()
	await frames(3)


# --- Soak --------------------------------------------------------------------------------------------------------------

func _soak() -> void:
	MissionFlow.test_director = SOAK_DIRECTOR
	var closes := 0
	var trapped := 0
	var acted := 0
	for seed_n: int in SOAK_SEEDS:
		var td: MissionScene = await _drive(seed_n, false)
		var mf := td.mission
		var mw := td.stack.mission
		var sq: EnemySquad = td.combat.squad
		var wbays := {}
		for k in mf.plan.deck_count:
			for s: Dictionary in mf.plan.deck_sources(k):
				var b := mw.source_bay(str(s["id"]))
				if bool(b.get("ok", false)):
					wbays[str(s["id"])] = b
		var last := {}
		var step_i := 0
		for k in mf.plan.deck_count:
			var arr := SectionEncounters.arrival(td.stack.section, k)
			var mp := td.stack.from_deck_arc(k, float(arr["x"]), float(arr["s"]), 0.5)
			td.mech.global_position = mp
			td.combat.player_target.global_position = mp
			await frames(1)
			var t := 0.0
			while t < SOAK_DECK:
				t += DT
				step_i += 1
				td.combat.player_target.repair_all()
				mf._physics_process(DT)
				td.combat.world.advance(DT)
				if step_i % 15 != 0:
					continue
				for sid: String in wbays:
					var st := str(mw.source_state(sid)["state"])
					var was := str(last.get(sid, "shut"))
					last[sid] = st
					if st == was or not (st == "closing" or (was == "open" and st != "open")):
						continue
					closes += 1
					for e in sq.enemies:
						if is_instance_valid(e) and not e.destroyed() and not e.staged \
								and bool(MissionBays.contains_in(wbays[sid], e.global_position)["inside"]):
							trapped += 1
							print("soak seed %d: %s inside %s as its door closes (%s)" % [seed_n, e.target_id, sid, e.ai_state])
				if step_i % 120 == 0:   # keep the director releasing: the wave unit farthest from every bay goes down
					_soak_cull(sq, wbays)
				if step_i % 1800 == 0:
					await frames(1)
		acted += mf.bays.events.size()
		td.queue_free()
		await frames(3)
	MissionFlow.test_director = {}
	print("soak: %d door closes over seeds %s, bay guard events %d" % [closes, str(SOAK_SEEDS), acted])
	check(closes >= 10, "the soak closed doors (%d)" % closes)
	eq(trapped, 0, "no live unit is ever inside a bay as its door closes")


func _soak_cull(sq: EnemySquad, wbays: Dictionary) -> void:
	var best: EnemyBase = null
	var best_d := -1.0
	for e in sq.enemies:
		if not is_instance_valid(e) or e.destroyed() or e.wave == "" or e.staged or e.is_rolling_out() or e.enemy_type == "dropship":
			continue
		var near := INF
		for sid: String in wbays:
			var c := MissionBays.contains_in(wbays[sid], e.global_position)
			near = minf(near, absf(float(c["depth"])) + absf(float(c["x"])))
		if near > best_d:
			best_d = near
			best = e
	if best != null and best_d > 40.0:
		best.apply_damage(1.0e7, best.core_component(), "test")
