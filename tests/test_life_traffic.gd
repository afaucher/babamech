extends TestCase
## Ambient life, phase 2: pods and service carts (scripts/world/life/life_traffic.gd, life_fleet.gd). The traffic plan is
## deterministic and checksummed with its caps; over 10 minutes of calm, vehicles stay in the lanes heading along them,
## only cross a junction in its turn phase, never overlap and never come near a walker on a crossing, and never jump; a
## threat e-stops them within 2 s inside their braking distance, an empty pod with the threat ahead backs away from it,
## passengers get out and run, and the loop rejoins its timetable later with no jump; blasts, shots and a mech's foot
## wreck vehicles for good and kill the passengers still inside; two instances fed the same events agree; snapshots
## round-trip. Time is driven with advance_to() and pure queries, never frames.

var district: CityDistrict


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_plan_checks()
	_calm_checks()
	district = CityDistrict.new()
	add_child(district)
	district.build({"seed": 1, "walls": 1.0})
	_panic_checks()
	_flee_check()
	_rider_check()
	_wreck_checks()
	_queue_check()
	_two_instances()
	_snapshot_check()
	finish()


func _life(n: int = -1) -> AmbientLife:
	var life := AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup(district, n)
	return life


func _world(x: float, s: float, h: float) -> Vector3:
	return district.global_transform * district.ring.arc_to_world(x, s, h)


# --- Plan ------------------------------------------------------------------------------------------------

func _plan_checks() -> void:
	var sums := {}
	for seed in [1, 2, 3]:
		var p := CityPlan.make({"seed": seed})
		var a := LifeTraffic.make(LifePlan.make(p))
		var b := LifeTraffic.make(LifePlan.make(CityPlan.make({"seed": seed})))
		eq(a.checksum(), b.checksum(), "seed %d: the same traffic twice" % seed)
		sums[a.checksum()] = true
		eq(a.pods, 8, "seed %d: 8 pods in the default district" % seed)
		eq(a.carts, 2, "seed %d: 2 carts" % seed)
		eq(a.count(), 10, "seed %d: 10 vehicles" % seed)
		var docked := 0
		for lo: Dictionary in a.loops:
			check(float(lo["L"]) / LifePlan.CYCLE == floorf(float(lo["L"]) / LifePlan.CYCLE), "a lap is whole signal cycles")
		print("traffic seed %d: %s  loops %d  laps %s" % [seed, a.checksum(), a.loops.size(),
				str(a.loops.map(func(lo: Dictionary) -> int: return int(lo["L"])))])
	eq(sums.size(), 3, "three seeds, three traffic checksums")
	var lp := LifePlan.make(CityPlan.make({"seed": 1}))
	var capped := LifeTraffic.make(lp, 50, 10)
	eq(capped.pods, LifeTraffic.PODS_CAP, "pods capped at 12")
	eq(capped.carts, LifeTraffic.CARTS_CAP, "carts capped at 4")
	eq(LifeTraffic.make(lp, 3, 0).count(), 3, "the pods / carts params set the counts")


# --- Calm ------------------------------------------------------------------------------------------------

## The four corners of a vehicle's footprint, grown by `pad`.
static func _box(p: Dictionary, size: Vector3, pad: float) -> PackedVector2Array:
	var h := float(p["heading"])
	var f := Vector2(sin(h), cos(h)) * (size.z * 0.5 + pad)
	var r := Vector2(cos(h), -sin(h)) * (size.x * 0.5 + pad)
	var c := Vector2(p["x"], p["s"])
	return PackedVector2Array([c + f + r, c + f - r, c - f - r, c - f + r])


func _calm_checks() -> void:
	var p := CityPlan.make({"seed": 2})
	var lp := LifePlan.make(p)
	var tr := LifeTraffic.make(lp)
	var fleet := LifeFleet.new(tr)
	var boxes := tr.boxes()
	var medians: Array[Rect2] = []
	var av := p.avenue_x()
	medians.append(Rect2((av.x + av.y) * 0.5 - 1.5, p.extent.position.y, 3.0, p.extent.size.y))
	var off_lane := 0
	var askew := 0
	var red := 0
	var overlap := 0
	var close_same := 0
	var near_walker := 0
	var jumps := 0
	var states := {}
	var last: Array = []
	for v in tr.count():
		last.append(null)
	var t := 2000.0
	while t < 2600.0:
		var poses: Array = []
		for v in tr.count():
			var q := fleet.pose(v, t)
			poses.append(q)
			states[q["state"]] = int(states.get(q["state"], 0)) + 1
			var at := Vector2(q["x"], q["s"])
			for b: Dictionary in p.blocks:
				if (b["rect"] as Rect2).grow(-0.2).has_point(at):
					off_lane += 1
			for m in medians:
				var in_box := false
				for bx: Dictionary in boxes:
					if (bx["rect"] as Rect2).has_point(at):
						in_box = true
				if m.has_point(at) and not in_box:
					off_lane += 1
			var in_junction := -1
			for bx: Dictionary in boxes:
				if (bx["rect"] as Rect2).has_point(at):
					in_junction = int(bx["j"])
			if in_junction >= 0 and not lp.all_red(in_junction, t):
				red += 1
			if in_junction < 0 and q["state"] == "driving":
				var hd := Vector2(sin(float(q["heading"])), cos(float(q["heading"])))
				if absf(hd.x) < 0.75 and absf(hd.y) < 0.75:      # more than ~40 degrees off both axes
					askew += 1
			if last[v] != null and (last[v] as Vector2).distance_to(at) > 12.0 * 0.25 + 0.5:
				jumps += 1
			last[v] = at
		for a in tr.count():
			for b in range(a + 1, tr.count()):
				var pa: Dictionary = poses[a]
				var pb: Dictionary = poses[b]
				var ka := _box(pa, LifeTraffic.SIZE[tr.vehicles[a]["kind"]], 0.15)
				var kb := _box(pb, LifeTraffic.SIZE[tr.vehicles[b]["kind"]], 0.15)
				if not Geometry2D.intersect_polygons(ka, kb).is_empty():
					overlap += 1
				if int(tr.vehicles[a]["loop"]) == int(tr.vehicles[b]["loop"]) and \
						Vector2(pa["x"], pa["s"]).distance_to(Vector2(pb["x"], pb["s"])) < 5.0:
					close_same += 1
		# walkers on crossings
		for id in lp.count:
			var w := lp.calm_pose(id, t)
			if not w["visible"] or w["state"] != "cross":
				continue
			var wp := Vector2(w["x"], w["s"])
			var on_road := true
			for b: Dictionary in p.blocks:
				if (b["rect"] as Rect2).has_point(wp):
					on_road = false
			if not on_road:
				continue
			for q: Dictionary in poses:
				if Vector2(q["x"], q["s"]).distance_to(wp) < 2.5:
					near_walker += 1
		t += 0.25
	print("traffic calm: states %s" % str(states))
	eq(off_lane, 0, "vehicles never drive on a sidewalk, a block or the median")
	eq(askew, 0, "between junctions a driving vehicle heads along its road")
	eq(red, 0, "vehicles are in a junction only during its turn phase (both walk signals red)")
	eq(overlap, 0, "no two vehicles' footprints ever touch")
	eq(close_same, 0, "no two vehicles of one loop come within 5 m")
	eq(near_walker, 0, "no vehicle within 2.5 m of a walker on a crossing")
	eq(jumps, 0, "no vehicle jumps between samples")
	for st: String in ["driving", "stopped", "docked", "dwell"]:
		check(int(states.get(st, 0)) > 0, "calm traffic has %s vehicles" % st)


# --- Firefight -------------------------------------------------------------------------------------------

## A pod driving at time t (and, if `empty`, carrying nobody), or -1.
func _driving_pod(life: AmbientLife, empty: int = -1, mid_side: bool = false) -> int:
	for v in life.vehicle_count():
		if life.vehicle_kind(v) != "pod" or life.vehicle_state(v) != "driving":
			continue
		var q := life.fleet.pose(v, life.now)
		if float(q["v"]) < 5.0:
			continue
		var li := int(life.traffic.vehicles[v]["loop"])
		if mid_side and (life.traffic.zone_at(li, float(q["u"])) >= 0 or float(life.traffic.zone_ahead(li, float(q["u"]))[1]) < 25.0):
			continue
		var n := life.traffic.riders(v, life.now)
		if empty == 1 and n > 0 or empty == 0 and n == 0:
			continue
		return v
	return -1


func _find_time(life: AmbientLife, t0: float, empty: int, mid_side: bool = false) -> int:
	var t := t0
	while t < t0 + 300.0:
		life.advance_to(t)
		var v := _driving_pod(life, empty, mid_side)
		if v >= 0:
			return v
		t += 1.0
	return -1


func _anchor(life: AmbientLife, v: int) -> Dictionary:
	var e: Dictionary = life.fleet.episodes.get(int(life.traffic.vehicles[v]["loop"]), {})
	return e["v"].get(v, {}) if not e.is_empty() else {}


## Footprint overlaps, jumps (> 2 m between samples) and junction entries outside a turn phase (after a restart) over
## [t0, t1] in steps of dt. Returns [overlaps, jumps, reds].
func _sweep_safety(life: AmbientLife, t0: float, t1: float, dt: float) -> Array:
	var boxes := life.traffic.boxes()
	var overlaps := 0
	var jumps := 0
	var reds := 0
	var last: Array = []
	for v in life.vehicle_count():
		last.append(null)
	var t := t0
	while t <= t1:
		var poses: Array = []
		for v in life.vehicle_count():
			var q := life.fleet.pose(v, t)
			poses.append(q)
			var at := Vector2(q["x"], q["s"])
			if last[v] != null:
				var was: Vector2 = last[v]
				if was.distance_to(at) > 2.0:
					if jumps == 0:
						print("jump at %.2f: %d %s %s -> %s" % [t, v, q["state"], was, at])
					jumps += 1
				if not q["wreck"] and not q["held"] and was.distance_to(at) > 1e-3:
					for bx: Dictionary in boxes:
						var r: Rect2 = bx["rect"]
						if r.has_point(at) and not r.has_point(was) and not life.plan.all_red(int(bx["j"]), t):
							reds += 1
			last[v] = at
		for a in life.vehicle_count():
			for b in range(a + 1, life.vehicle_count()):
				if poses[a]["wreck"] or poses[b]["wreck"]:
					continue
				var ka := _box(poses[a], LifeTraffic.SIZE[life.traffic.vehicles[a]["kind"]], 0.1)
				var kb := _box(poses[b], LifeTraffic.SIZE[life.traffic.vehicles[b]["kind"]], 0.1)
				if not Geometry2D.intersect_polygons(ka, kb).is_empty():
					if overlaps == 0:
						print("overlap at %.2f: %d %s %s / %d %s %s" % [t, a, poses[a]["state"], Vector2(poses[a]["x"], poses[a]["s"]), b, poses[b]["state"], Vector2(poses[b]["x"], poses[b]["s"])])
					overlaps += 1
		t += dt
	return [overlaps, jumps, reds]


func _panic_checks() -> void:
	var life := _life()
	var v := _find_time(life, 1000.0, 0, true)
	if not check(v >= 0, "an occupied pod driving to stop"):
		return
	var T := life.now
	var q0 := life.fleet.pose(v, T)
	var v0 := float(q0["v"])
	var f0 := Vector2(sin(float(q0["heading"])), cos(float(q0["heading"])))
	life.raise_threat(_world(float(q0["x"]) + f0.x * 15.0, float(q0["s"]) + f0.y * 15.0, 1.0), 20.0, 2)
	var stopped_by := INF
	var t := T
	while t < T + 3.0:
		t += 0.05
		if str(life.fleet.pose(v, t)["state"]) in ["estop", "abandoned", "fleeing"] and is_inf(stopped_by):
			stopped_by = t - T
	check(stopped_by <= 2.0, "the pod e-stops within 2 s of a threat in range (%.2f s)" % stopped_by)
	var a := _anchor(life, v)
	if check(not a.is_empty() and float(a["doors"]) > 0.0, "the occupied pod stops to let its passengers out"):
		var x_t0 := float(a["v"]) * (float(a["t0"]) - T)
		var ep: Dictionary = life.fleet.episodes[int(life.traffic.vehicles[v]["loop"])]
		var at_doors := life.fleet._x_free(ep, v, float(a["doors"]))
		check(at_doors - x_t0 <= v0 * v0 / (2.0 * LifeFleet.DECEL) + 0.3, "it stops within its braking distance")
	# Back to normal: 15 s after the threat every vehicle of every halted loop moves again within 5 s.
	var R := T + LifeFleet.RESTART
	var halted: Array[int] = []
	for k in life.vehicle_count():
		var ak := _anchor(life, k)
		var li := int(life.traffic.vehicles[k]["loop"])
		if not ak.is_empty() and float(life.fleet.episodes[li]["t"]) == T:
			var rest_u := float(ak["u"]) + float(ak["xs"])
			# (one halted inside a turn, or right at its stop line, waits for its turn phase: that is normal driving)
			if life.traffic.zone_at(li, rest_u) < 0 and float(life.traffic.zone_ahead(li, rest_u)[1]) > 1.0:
				halted.append(k)
	check(not halted.is_empty(), "the threat halted some vehicles (%d)" % halted.size())
	var late: Array[int] = []
	for k in halted:
		var moved := false
		var p0 := life.fleet.pose(k, R)
		t = R
		while t <= R + 5.0:
			t += 0.1
			var p := life.fleet.pose(k, t)
			if Vector2(p["x"], p["s"]).distance_to(Vector2(p0["x"], p0["s"])) > 0.3:
				moved = true
				break
		if not moved:
			late.append(k)
			var pk := life.fleet.pose(k, R + 5.0)
			var lk := int(life.traffic.vehicles[k]["loop"])
			print("late %d: %s v %.2f  to stop %.1f  zone %d" % [k, pk["state"], float(pk["v"]), float(life.traffic.zone_ahead(lk, float(pk["u"]))[1]), life.traffic.zone_at(lk, float(pk["u"]))])
	eq(late.size(), 0, "every halted vehicle moves again within 5 s of the restart (late: %s)" % str(late))
	var safety := _sweep_safety(life, T, T + 240.0, 0.1)
	eq(int(safety[0]), 0, "no two vehicles overlap while stopping, waiting and resuming")
	eq(int(safety[1]), 0, "no vehicle jumps more than 2 m in 0.1 s")
	eq(int(safety[2]), 0, "after the restart no vehicle enters a junction outside its turn phase")
	var off := 0
	for k in halted:
		var e: Dictionary = life.fleet.episodes[int(life.traffic.vehicles[k]["loop"])]
		var q := life.fleet.pose(k, T + 300.0)
		var b := life.traffic.base_pose(k, T + 300.0 - life.fleet.shift_of(e))
		if Vector2(q["x"], q["s"]).distance_to(Vector2(b["x"], b["s"])) > 1e-4:
			off += 1
	eq(off, 0, "five minutes later every vehicle is on its (shifted) timetable")
	life.queue_free()


func _flee_check() -> void:
	var life := _life()
	# A pod with nobody aboard and a long clear stretch ahead: a threat behind it sends it off forward.
	var v := -1
	var t := 1400.0
	while t < 1900.0 and v < 0:
		life.advance_to(t)
		for k in life.vehicle_count():
			if life.vehicle_kind(k) != "pod" or life.vehicle_state(k) != "driving" or life.traffic.riders(k, t) > 0:
				continue
			var q := life.fleet.pose(k, t)
			var li := int(life.traffic.vehicles[k]["loop"])
			if float(life.traffic.zone_ahead(li, float(q["u"]))[1]) > 40.0 and life.traffic.zone_at(li, float(q["u"])) < 0:
				v = k
				break
		t += 0.5
	if not check(v >= 0, "an empty pod with room ahead"):
		return
	var T := life.now
	var q0 := life.fleet.pose(v, T)
	var fwd := Vector2(sin(float(q0["heading"])), cos(float(q0["heading"])))
	var c := Vector2(q0["x"], q0["s"]) - fwd * 12.0
	life.raise_threat(_world(c.x, c.y, 1.0), 20.0, 2)
	var a := _anchor(life, v)
	if check(not a.is_empty() and int(a["flee"]) == LifeFleet.FWD, "an empty pod with the threat behind speeds away forward"):
		var top := 0.0
		var seen := false
		t = T
		while t < float(a["te"]):
			t += 0.05
			var q := life.fleet.pose(v, t)
			top = maxf(top, float(q["v"]))
			if q["state"] == "fleeing":
				seen = true
		check(seen, "its state is fleeing")
		check(top >= 12.0, "it reaches at least 12 m/s (%.1f)" % top)
		var end := life.fleet.pose(v, float(a["te"]) + 0.1)
		check(Vector2(end["x"], end["s"]).distance_to(c) > Vector2(q0["x"], q0["s"]).distance_to(c) + 10.0,
				"it ends up further from the threat (%.1f m -> %.1f m)" % [Vector2(q0["x"], q0["s"]).distance_to(c),
				Vector2(end["x"], end["s"]).distance_to(c)])
		var safety := _sweep_safety(life, T, T + 60.0, 0.05)
		eq(int(safety[0]), 0, "speeding away it overlaps nobody")
	# The threat ahead of another empty pod: it backs away.
	life.advance_to(life.now + 40.0)
	var w := -1
	for k in life.vehicle_count():
		if k != v and life.vehicle_kind(k) == "pod" and life.vehicle_state(k) == "driving" and life.traffic.riders(k, life.now) == 0:
			w = k
	if w >= 0:
		var qw := life.fleet.pose(w, life.now)
		var fw := Vector2(sin(float(qw["heading"])), cos(float(qw["heading"])))
		var cw := Vector2(qw["x"], qw["s"]) + fw * 18.0
		life.raise_threat(_world(cw.x, cw.y, 1.0), 20.0, 2)
		var aw := _anchor(life, w)
		if not aw.is_empty() and int(aw["flee"]) == LifeFleet.REV:
			var endw := life.fleet.pose(w, float(aw["te"]) + 0.1)
			check(Vector2(endw["x"], endw["s"]).distance_to(cw) > Vector2(qw["x"], qw["s"]).distance_to(cw) + 5.0,
					"a pod with the threat ahead backs away from it")
		else:
			print("(no reversing pod in this sample)")
	life.queue_free()


func _rider_check() -> void:
	var life := _life()
	var v := _find_time(life, 1800.0, 0)
	if not check(v >= 0, "a pod with passengers driving"):
		return
	var T := life.now
	var n := life.traffic.riders(v, T + 0.5)
	var q0 := life.fleet.pose(v, T)
	life.raise_threat(_world(float(q0["x"]), float(q0["s"]), 1.0), 15.0, 2)
	eq(life.crowd.riders_used, n, "%d passenger(s) get out" % n)
	life.advance_to(T + 4.0)
	var out := 0
	for k in n:
		var id := life.plan.count + k
		if life.visible_now(id) and life.state_of(id) in ["wary", "fleeing", "cowering"]:
			out += 1
	eq(out, n, "the passengers are outside, running or crouching")
	life.queue_free()


func _wreck_checks() -> void:
	var life := _life()
	var v := _find_time(life, 2200.0, 0)
	if not check(v >= 0, "an occupied pod to wreck"):
		return
	var n := life.traffic.riders(v, life.now)
	var xf := life.vehicle_pose(v)
	var hit := life.blast(xf.origin + xf.basis.x * 1.5 + Vector3(0, 0.5, 0), 3.0, 4)
	check(hit >= 1, "a blast beside it hits it")
	eq(life.vehicle_state(v), "wreck", "the pod is a wreck")
	eq(int(life.tally()["occupants_killed"]), n, "its %d passenger(s) inside are killed" % n)
	check(int(life.tally()["by_src"].get(4, 0)) >= n, "counted against the shooter")
	life.advance_to(life.now + 1.0)
	check(life.vehicle_pose(v).basis.y.normalized().angle_to(xf.basis.y.normalized()) > 1.2, "the blast tipped it onto its side")
	var cart := -1
	for k in life.vehicle_count():
		if life.vehicle_kind(k) == "cart" and life.vehicle_state(k) != "wreck":
			cart = k
	if check(cart >= 0, "a cart"):
		var cx := life.vehicle_pose(cart)
		var up := cx.basis.y.normalized()
		check(life.sweep(cx.origin + up - cx.basis.x * 3.0, cx.origin + up + cx.basis.x * 3.0, 0.2, 5) >= 1, "a shot through the cart hits it")
		eq(life.vehicle_state(cart), "wreck", "the cart is a wreck")
	var other := -1
	for k in life.vehicle_count():
		if life.vehicle_kind(k) == "pod" and life.vehicle_state(k) != "wreck":
			other = k
	if check(other >= 0, "another pod"):
		var foot := Node3D.new()
		add_child(foot)
		var ox := life.vehicle_pose(other)
		foot.global_position = ox.origin + ox.basis.x * 5.0
		life.add_pusher(foot, 1.0, 6)
		var t := life.now
		for i in 40:
			t += 0.05
			foot.global_position = foot.global_position.move_toward(life.vehicle_pose(other).origin, 0.3)
			life.advance_to(t)
			if life.vehicle_state(other) == "wreck":
				break
		eq(life.vehicle_state(other), "wreck", "a mech's foot walking into a pod wrecks it")
		foot.queue_free()
	life.advance_to(life.now + 400.0)
	eq(life.vehicle_state(v), "wreck", "a wreck stays a wreck")
	check(int(life.tally()["wrecks"]) >= 2, "the tally counts the wrecks (%d)" % int(life.tally()["wrecks"]))
	life.queue_free()


## A wreck in a lane: the loop's other vehicle queues 6 m short of it (no hazards); shoved out, it drives on.
func _queue_check() -> void:
	var life := _life()
	var loop := -1
	for li in life.traffic.loops.size():
		if life.traffic.loop_vehicles(li).size() >= 2:
			loop = li
			break
	if not check(loop >= 0, "a loop with two vehicles"):
		return
	var ids := life.traffic.loop_vehicles(loop)
	var T := 2600.0
	life.advance_to(T)
	var w := ids[0]
	var follower := ids[1]
	life._decide_wreck(w, Vector2(0.0, 1.0), 2, 0, 0.5)          # a shot: wrecked where it stands, in its lane
	eq(life.vehicle_state(w), "wreck", "the pod is wrecked in its lane")
	var rest := life.fleet._wreck_rest(w)
	var length := float(life.traffic.loops[loop]["length"])
	var uw := life.traffic.lane_u(loop, Vector2(rest["x"], rest["s"]), LifeFleet.IN_LANE)
	check(uw >= 0.0, "the wreck lies in the loop's lane")
	var queued := -1.0
	var t := T
	while t < T + 600.0:
		t += 0.5
		var q := life.fleet.pose(follower, t)
		var gap := fposmod(uw - float(q["u"]), length)
		if q["state"] == "stopped" and not q["hazard"] and absf(float(q["v"])) < 1e-3 and gap < 30.0 and t > T + 20.0:
			queued = t
			check(gap >= LifeFleet.GAP + 3.4 - 0.05, "the follower stops 6 m short of the wreck (centre gap %.1f m)" % gap)
			break
	if not check(queued > 0.0, "the follower queues behind the wreck, hazards off"):
		life.queue_free()
		return
	var still := life.fleet.pose(follower, queued + 60.0)
	check(still["state"] == "stopped", "and stays queued while the wreck blocks the lane")
	life.advance_to(queued + 60.0)
	# Shove the wreck clear of the lane, sideways.
	var hd := float(rest["heading"])
	var side := Vector2(cos(hd), -sin(hd))
	life._decide_wreck(w, side, 2, 2, 10.0)
	var rest2 := life.fleet._wreck_rest(w)
	if check(life.traffic.lane_u(loop, Vector2(rest2["x"], rest2["s"]), LifeFleet.IN_LANE) < 0.0, "the shove clears the lane"):
		var t0 := life.now
		var p0 := life.fleet.pose(follower, t0)
		var moved := false
		t = t0
		while t < t0 + 5.0:
			t += 0.1
			var p := life.fleet.pose(follower, t)
			if Vector2(p["x"], p["s"]).distance_to(Vector2(p0["x"], p0["s"])) > 0.3:
				moved = true
				break
		check(moved, "freed, the follower drives on within 5 s")
		var safety := _sweep_safety(life, T, t0 + 120.0, 0.1)
		eq(int(safety[0]), 0, "no overlaps around the wreck")
		eq(int(safety[1]), 0, "no jumps around the wreck")
	life.queue_free()


# --- Two instances and snapshots ---------------------------------------------------------------------------

func _busy(life: AmbientLife, T: float) -> void:
	life.advance_to(T)
	var v := _driving_pod(life)
	if v >= 0:
		var q := life.fleet.pose(v, T)
		life.raise_threat(_world(float(q["x"]), float(q["s"]), 1.0), 20.0, 2)
	life.advance_to(T + 2.0)
	for k in life.vehicle_count():
		if life.vehicle_state(k) != "wreck" and k != v:
			var xf := life.vehicle_pose(k)
			life.blast(xf.origin + Vector3(0, 0.5, 0), 2.0, -1)
			break
	life.advance_to(T + 3.0)


func _signature(life: AmbientLife, t: float) -> String:
	var out := PackedStringArray()
	for v in life.vehicle_count():
		var q := life.fleet.pose(v, t)
		out.append("%s@%d,%d,%d" % [q["state"], int(round(float(q["x"]) * 100.0)), int(round(float(q["s"]) * 100.0)),
				int(round(float(q["tilt"]) * 100.0))])
	for id in life.count():
		out.append(str(life.crowd.state_of(id, t)))
	return ",".join(out)


func _two_instances() -> void:
	var a := _life()
	var b := _life()
	_busy(a, 3000.0)
	check(a.sent.size() >= 2, "the host decided a threat and a wreck (%d events)" % a.sent.size())
	for e: Array in a.sent:
		b.apply_event(str(e[0]), e[1])
	var diff := 0
	var t := 3003.0
	while t < 3400.0:
		if _signature(a, t) != _signature(b, t):
			diff += 1
		t += 4.3
	eq(diff, 0, "two instances fed the same events agree on every vehicle and person")
	eq(a.tally(), b.tally(), "and on the tally")
	a.queue_free()
	b.queue_free()


func _snapshot_check() -> void:
	var a := _life()
	_busy(a, 3500.0)
	var bytes := a.snapshot()
	check(bytes.size() < 4096, "the snapshot is small (%d bytes)" % bytes.size())
	var b := _life()
	b.advance_to(a.now)
	b.restore(bytes)
	eq(b.snapshot().hex_encode(), bytes.hex_encode(), "snapshot -> restore -> snapshot is unchanged")
	var diff := 0
	for dt: float in [0.0, 5.0, 30.0, 100.0, 300.0]:
		if _signature(a, a.now + dt) != _signature(b, a.now + dt):
			diff += 1
	eq(diff, 0, "a restored fleet moves exactly like the original")
	a.queue_free()
	b.queue_free()
