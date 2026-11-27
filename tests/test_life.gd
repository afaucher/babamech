extends TestCase
## Ambient life, phase 1: people (scripts/world/life/; docs/design/ambient-life.md). The plan is deterministic and
## checksummed with its caps; calm poses stay on sidewalks, green crossings, benches and doors and never jump; a threat
## sends everyone in range away within 1.5 s and into shelter or a crouch within 30 s while people out of range stay calm
## (except the ripple); calm returns; sweeps, blasts and a mech foot kill exactly those in reach (never indoors), tally and
## signal it, and the dead stay down; snapshots round-trip; a moved and rotated district works in world space; two
## instances fed the same events agree. Time is driven with advance_to(), never frames.

var district: CityDistrict
var killed: Array = []


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_plan_checks()
	_calm_checks()
	district = CityDistrict.new()
	add_child(district)
	district.build({"seed": 1, "walls": 1.0})
	_threat_checks()
	_kill_checks()
	_pusher_check()
	_snapshot_check()
	_moved_check()
	_two_instances()
	finish()


func _life(d: CityDistrict = null, n: int = -1) -> AmbientLife:
	var life := AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup(d if d != null else district, n)
	return life


func _world(d: CityDistrict, x: float, s: float, h: float) -> Vector3:
	return d.global_transform * d.ring.arc_to_world(x, s, h)


# --- Plan ------------------------------------------------------------------------------------------------

func _plan_checks() -> void:
	var sums := {}
	for seed in [1, 2, 3]:
		var a := LifePlan.make(CityPlan.make({"seed": seed}))
		var b := LifePlan.make(CityPlan.make({"seed": seed}))
		eq(a.checksum(), b.checksum(), "seed %d: the same plan twice, the same life checksum" % seed)
		sums[a.checksum()] = true
		eq(a.count, 24, "seed %d: 24 people in the default 220 x 240 district" % seed)
		check(a.doors.size() > 20, "seed %d: doors (%d)" % [seed, a.doors.size()])
		check(a.benches.size() > 0, "seed %d: benches (%d)" % [seed, a.benches.size()])
		var crossings := 0
		for ed: Array in a.edges:
			if int(ed[2]) == LifePlan.CROSS:
				crossings += 1
		check(crossings > 10, "seed %d: crossings (%d)" % [seed, crossings])
		print("life plan seed %d: %s  doors %d  benches %d  nodes %d  edges %d  crossings %d" % [seed, a.checksum(),
				a.doors.size(), a.benches.size(), a.nodes.size(), a.edges.size(), crossings])
	eq(sums.size(), 3, "three seeds, three checksums")
	var p := CityPlan.make({"seed": 1})
	eq(LifePlan.make(p, 500).count, LifePlan.PEOPLE_CAP, "the people param is capped at 60")
	eq(LifePlan.make(p, 7).count, 7, "the people param sets the count")
	var big := CityPlan.make({"seed": 1, "size_x": 300.0, "size_s": 320.0})
	eq(LifePlan.make(big).count, 44, "scaled by area (300 x 320)")
	check(LifePlan.make(p, 5).checksum() != LifePlan.make(p, 6).checksum(), "the count is in the checksum")


# --- Calm ------------------------------------------------------------------------------------------------

func _calm_checks() -> void:
	var p := CityPlan.make({"seed": 2})
	var lp := LifePlan.make(p)
	var lp2 := LifePlan.make(CityPlan.make({"seed": 2}))
	var bad_place := 0
	var bad_light := 0
	var in_bld := 0
	var jumps := 0
	var differ := 0
	var outdoors := 0
	var samples := 0
	var states := {}
	var footprints: Array[Rect2] = []
	for b: Dictionary in p.buildings:
		if not (b["tiers"] as Array).is_empty():
			footprints.append(Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"]))
	for id in lp.count:
		var last: Variant = null
		var t := 1000.0
		var k := 0
		while t < 1400.0:
			var q := lp.calm_pose(id, t)
			samples += 1
			states[q["state"]] = int(states.get(q["state"], 0)) + 1
			if k % 10 == 0:
				var q2 := lp2.calm_pose(id, t)
				if absf(float(q2["x"]) - float(q["x"])) > 1e-9 or absf(float(q2["s"]) - float(q["s"])) > 1e-9:
					differ += 1
			if q["visible"]:
				outdoors += 1
				var at := Vector2(q["x"], q["s"])
				if last != null and (last as Vector2).distance_to(at) > 1.0:
					jumps += 1
				last = at
				var on_block := false
				for b: Dictionary in p.blocks:
					if (b["rect"] as Rect2).has_point(at):
						on_block = true
						break
				if not on_block:
					var c := lp.crossing_at(at.x, at.y)
					if c.is_empty():
						bad_place += 1
					# junction -1: a crossing with no signal (over a pedestrian street or a superblock's court, no
					# vehicles: docs/design/city-variety.md), crossed whenever a walker gets there.
					elif int(c["junction"]) >= 0 and not lp.green(int(c["junction"]), int(c["axis"]), t):
						bad_light += 1
				if k % 5 == 0:
					for r in footprints:
						if r.grow(-0.05).has_point(at):
							in_bld += 1
			else:
				last = null
			t += 0.2
			k += 1
	print("calm: %d samples, %d outdoors, states %s" % [samples, outdoors, str(states)])
	check(outdoors > samples * 0.3, "a good share of people are outdoors (%d / %d)" % [outdoors, samples])
	for st: String in ["walk", "cross", "indoor"]:
		check(int(states.get(st, 0)) > 0, "the timetable has %s poses" % st)
	check(int(states.get("wait", 0)) + int(states.get("sit", 0)) > 0, "people wait at lights or sit on benches")
	eq(differ, 0, "two plans from the same seed give the same calm poses")
	eq(bad_place, 0, "calm people off the sidewalks are only ever on a crossing")
	eq(bad_light, 0, "calm people are on a crossing only while it shows walk")
	eq(in_bld, 0, "calm people never stand inside a building footprint")
	eq(jumps, 0, "calm motion never jumps more than 1 m in 0.2 s")


# --- Threats ---------------------------------------------------------------------------------------------

func _threat_checks() -> void:
	for T: float in [1000.0, 1700.0, 2600.0]:
		_threat_check(T)


func _threat_check(T: float) -> void:
	var life := _life()
	life.advance_to(T)
	var c := life.unit(0).crowd
	# Aim at the person with the most neighbours outdoors.
	var best := -1
	var best_n := -1
	for id in life.count():
		var p := c.pose(id, T)
		if not p["visible"]:
			continue
		var n := 0
		for j in life.count():
			var q := c.pose(j, T)
			if q["visible"] and Vector2(q["x"], q["s"]).distance_to(Vector2(p["x"], p["s"])) < 30.0:
				n += 1
		if n > best_n:
			best_n = n
			best = id
	if not check(best >= 0, "someone is outdoors at t = %f" % T):
		return
	var at := Vector2(c.pose(best, T)["x"], c.pose(best, T)["s"])
	var radius := 30.0
	var in_range: Array[int] = []
	var out_range: Array[int] = []
	for id in life.count():
		var p := c.pose(id, T)
		if not p["visible"]:
			continue
		if Vector2(p["x"], p["s"]).distance_to(at) <= radius:
			in_range.append(id)
		else:
			out_range.append(id)
	print("threat at %.0f: %d in range, %d outdoors out of range" % [T, in_range.size(), out_range.size()])
	var events := {}
	life.civilian_event.connect(func(kind: String, _pos: Vector3) -> void: events[kind] = int(events.get(kind, 0)) + 1)
	life.raise_threat(_world(district, at.x, at.y, 1.0), radius, 2)
	eq(life.sent.size(), 1, "the host decided one threat event")
	# A second threat 3 m away a moment later is merged away; one far away waits for the rate limit.
	life.advance_to(T + 0.1)
	life.raise_threat(_world(district, at.x + 3.0, at.y, 1.0), radius, 2)
	eq(life.sent.size(), 1, "a threat within 10 m and 0.25 s is merged")
	life.raise_threat(_world(district, at.x + 200.0, at.y, 1.0), 5.0, 1)
	eq(life.sent.size(), 1, "at most 4 threat events a second leave the host")
	life.advance_to(T + 0.3)
	eq(life.sent.size(), 2, "the waiting threat goes out 0.25 s later")
	var t := T + 0.3
	while t < T + 1.5:
		t += 0.1
		life.advance_to(t)
	var late := 0
	for id in in_range:
		if life.state_of(id) == "calm":
			late += 1
	eq(late, 0, "everyone in range has left calm within 1.5 s")
	var reached := {}
	while t < T + 30.0:
		t += 0.5
		life.advance_to(t)
		for id in in_range:
			if life.state_of(id) in ["sheltered", "cowering", "hands_up"]:
				reached[id] = true
	var safe := reached.size()
	eq(safe, in_range.size(), "everyone in range is sheltered or cowering within 30 s")
	var stray := 0
	for id in out_range:
		if life.state_of(id) != "calm" and not (c.recs.has(id) and int(c.recs[id]["st"]) == 1):
			stray += 1
	eq(stray, 0, "people out of range stay calm, except those the ripple reached")
	check(int(events.get("gasp", 0)) + int(events.get("scream", 0)) > 0, "audio hooks fire (%s)" % str(events))
	check(c.door_count(int(c.recs[in_range[0]]["door"]) if c.recs.has(in_range[0]) and int(c.recs[in_range[0]]["door"]) >= 0 else 0, t) >= 0, "door counts")
	while t < T + 125.0:
		t += 1.0
		life.advance_to(t)
	var restless := 0
	for id in life.count():
		if life.state_of(id) != "calm":
			restless += 1
	eq(restless, 0, "everyone is back on the timetable 2 minutes after the last threat")
	life.queue_free()


# --- Killing ---------------------------------------------------------------------------------------------

func _expected_hits(life: AmbientLife, a: Vector3, b: Vector3, reach: float) -> Array[int]:
	var out: Array[int] = []
	for id in life.count():
		if not life.visible_now(id) or life.state_of(id) == "down":
			continue
		var xf := life.pose_of(id)
		var head := xf.origin + xf.basis.y.normalized() * LifeDeck.HEIGHT
		var pts := Geometry3D.get_closest_points_between_segments(a, b, xf.origin, head)
		if pts[0].distance_to(pts[1]) <= reach:
			out.append(id)
	return out


func _kill_checks() -> void:
	var life := _life()
	killed.clear()
	life.civilian_killed.connect(func(id: int, _pos: Vector3, src: int) -> void: killed.append([id, src]))
	var T := 1300.0
	life.advance_to(T)
	var target := -1
	for id in life.count():
		if life.visible_now(id):
			target = id
			break
	if not check(target >= 0, "someone outdoors to shoot"):
		return
	var xf := life.pose_of(target)
	var side := xf.basis.x.normalized()
	var a := xf.origin + xf.basis.y * 1.0 + side * 6.0
	var b := xf.origin + xf.basis.y * 1.0 - side * 6.0
	var want := _expected_hits(life, a, b, 0.2 + LifeDeck.MARGIN)
	var n := life.sweep(a, b, 0.2, 3)
	eq(n, want.size(), "the sweep kills exactly those within r + 0.4 m (%s)" % str(want))
	check(target in want, "including the person it was aimed at")
	eq(life.state_of(target), "down", "the person hit is down")
	eq(int(life.tally()["killed_by_players"]), want.size(), "killed_by_players")
	eq(int(life.tally()["by_src"].get(3, 0)), want.size(), "counted against the shooter")
	eq(killed.size(), want.size(), "civilian_killed once per kill")
	eq(life.sweep(a, b, 0.2, 3), 0, "the dead are not killed twice")
	# A miss: 3 m above everyone's head.
	eq(life.sweep(a + xf.basis.y * 4.0, b + xf.basis.y * 4.0, 0.2, 3), 0, "a shot overhead kills nobody")
	# A blast by an enemy at someone else.
	var other := -1
	for id in life.count():
		if life.visible_now(id) and life.state_of(id) != "down" and life.pose_of(id).origin.distance_to(xf.origin) > 15.0:
			other = id
			break
	if check(other >= 0, "someone else outdoors"):
		var at := life.pose_of(other).origin + Vector3(0.0, 0.5, 0.0)
		var wanted := 0
		for id in life.count():
			if life.visible_now(id) and life.state_of(id) != "down":
				var f := life.pose_of(id)
				if Geometry3D.get_closest_point_to_segment(at, f.origin, f.origin + f.basis.y.normalized() * 1.8).distance_to(at) <= 4.0:
					wanted += 1
		eq(life.blast(at, 4.0, -1), wanted, "the blast kills exactly those within its radius")
		eq(int(life.tally()["killed_by_enemies"]), wanted, "killed_by_enemies")
		eq(life.state_of(other), "down", "the blast's target is down")
	# Indoors is safe.
	var inside := -1
	for id in life.count():
		if not life.visible_now(id) and life.state_of(id) != "down":
			inside = id
			break
	if check(inside >= 0, "someone indoors"):
		var door := life.unit(0).crowd.pose(inside, life.now)
		eq(life.blast(_world(district, door["x"], door["s"], 1.0), 2.5, 7) >= 0, true, "a blast at a door")
		check(life.state_of(inside) != "down", "a person indoors is not killed")
	# The dead fall in 0.4 s and stay down.
	var lying := life.pose_of(target)
	life.advance_to(T + 0.2)
	var mid := life.pose_of(target)
	life.advance_to(T + 300.0)
	var later := life.pose_of(target)
	check(mid.basis.y.normalized().angle_to(lying.basis.y.normalized()) > 0.05, "the body is tipping over at 0.2 s")
	check(later.basis.y.normalized().angle_to(xf.basis.y.normalized()) > 1.5, "the body lies flat")
	eq(life.state_of(target), "down", "the dead stay down after calm returns")
	life.queue_free()


func _pusher_check() -> void:
	var life := _life()
	var T := 1500.0
	life.advance_to(T)
	var target := -1
	for id in life.count():
		if life.visible_now(id) and life.state_of(id) == "calm":
			target = id
			break
	if not check(target >= 0, "someone outdoors for the foot"):
		return
	var foot := Node3D.new()
	add_child(foot)
	life.add_pusher(foot, 1.0, 2)
	var start := life.pose_of(target).origin + life.pose_of(target).basis.x.normalized() * 3.0
	foot.global_position = start
	life.advance_to(T + 0.05)
	# Walk the foot at 5 m/s straight at the person.
	var t := T + 0.05
	for i in 40:
		var to := life.pose_of(target).origin - foot.global_position
		if to.length() < 0.05:
			break
		foot.global_position += to.normalized() * minf(0.25, to.length())
		t += 0.05
		life.advance_to(t)
		if life.state_of(target) == "down":
			break
	eq(life.state_of(target), "down", "a fast mech foot kills the person it steps on")
	eq(int(life.tally()["by_src"].get(2, 0)) >= 1, true, "counted against the foot's pilot")
	# A slow foot kills nobody.
	var other := -1
	for id in life.count():
		if life.visible_now(id) and life.state_of(id) == "calm":
			other = id
			break
	if other >= 0:
		life.remove_pusher(foot)
		foot.global_position = life.pose_of(other).origin
		life.add_pusher(foot, 1.0, 2)
		life.advance_to(t + 0.05)
		foot.global_position += Vector3(0.05, 0.0, 0.0)
		life.advance_to(t + 0.1)
		check(life.state_of(other) != "down", "a foot standing still (1 m/s) kills nobody")
	foot.queue_free()
	life.queue_free()


# --- Snapshot, world space, two instances ------------------------------------------------------------------

func _busy(life: AmbientLife, T: float) -> void:
	life.advance_to(T)
	for id in life.count():
		if life.visible_now(id):
			var at := life.pose_of(id).origin
			life.raise_threat(at, 25.0, 2)
			break
	life.advance_to(T + 2.0)
	for id in range(life.count() - 1, -1, -1):
		if life.visible_now(id) and life.state_of(id) != "down":
			var xf := life.pose_of(id)
			life.sweep(xf.origin + Vector3(-3, 1, 0), xf.origin + Vector3(3, 1, 0), 0.2, 1)
			break
	life.advance_to(T + 3.0)


func _snapshot_check() -> void:
	var a := _life()
	_busy(a, 2000.0)
	var bytes := a.snapshot()
	check(bytes.size() < 2048, "the snapshot is small (%d bytes)" % bytes.size())
	var b := _life()
	b.advance_to(a.now)
	b.restore(bytes)
	eq(b.snapshot().hex_encode(), bytes.hex_encode(), "snapshot -> restore -> snapshot is unchanged")
	eq(b.tally(), a.tally(), "the tallies survive the snapshot")
	var diff := 0
	for dt: float in [0.0, 5.0, 20.0, 50.0, 100.0]:
		a.advance_to(2003.0 + dt)
		b.advance_to(2003.0 + dt)
		for id in a.count():
			if a.state_of(id) != b.state_of(id) or a.pose_of(id).origin.distance_to(b.pose_of(id).origin) > 1e-3:
				diff += 1
	eq(diff, 0, "a restored crowd moves exactly like the original")
	a.queue_free()
	b.queue_free()


func _moved_check() -> void:
	var holder := Node3D.new()
	holder.transform = Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.RIGHT, 0.2), Vector3(40.0, -12.0, 300.0))
	add_child(holder)
	var d := CityDistrict.new()
	d.with_rig = false
	holder.add_child(d)
	d.build({"seed": 1, "walls": 1.0})
	var moved := _life(d)
	var plain := _life()
	moved.advance_to(1100.0)
	plain.advance_to(1100.0)
	var off := 0
	var target := -1
	for id in moved.count():
		var want := d.global_transform * (district.global_transform.affine_inverse() * plain.pose_of(id).origin)
		if moved.pose_of(id).origin.distance_to(want) > 1e-3:
			off += 1
		if target < 0 and moved.visible_now(id):
			target = id
	eq(off, 0, "people stand in the moved district exactly where they stand in the plain one")
	if check(target >= 0, "someone outdoors in the moved district"):
		var xf := moved.pose_of(target)
		var up := xf.basis.y.normalized()
		var n := moved.sweep(xf.origin + up - xf.basis.x * 2.0, xf.origin + up + xf.basis.x * 2.0, 0.1, 4)
		check(n >= 1 and moved.state_of(target) == "down", "a world-space sweep kills in a moved, rotated district")
		eq(plain.state_of(target) == "down", false, "and not in the other district")
	moved.queue_free()
	plain.queue_free()
	holder.queue_free()


func _two_instances() -> void:
	var a := _life()
	var b := _life()
	_busy(a, 2500.0)
	a.advance_to(2504.0)
	for id in a.count():
		if a.visible_now(id) and a.state_of(id) != "down":
			a.blast(a.pose_of(id).origin, 1.0, -1)
			break
	check(a.sent.size() >= 2, "the host decided threat and down events (%d)" % a.sent.size())
	for e: Array in a.sent:
		b.apply_event(str(e[0]), e[1])
	var diff := 0
	var t := 2504.0
	while t < 2700.0:
		a.advance_to(t)
		b.advance_to(t)
		for id in a.count():
			if a.state_of(id) != b.state_of(id) or a.pose_of(id).origin.distance_to(b.pose_of(id).origin) > 1e-6:
				diff += 1
		t += 3.7
	eq(diff, 0, "two instances fed the same events agree at every sampled time")
	eq(a.tally(), b.tally(), "and keep the same tally")
	a.queue_free()
	b.queue_free()
