extends TestCase
## Ambient life, phase 3: section decks, the whole stack, the tram and checkpoints (scripts/world/life/;
## docs/design/ambient-life.md "As built", phase 3). Section seeds 1-5: plans build with stable checksums and counts within
## the caps; over 10 minutes of calm, people never stand in a floor cut (ramp holes and mouths, shafts), in the rail lane
## (except crossing it on a cross street with the tram's timetable 40 m clear) or outside the walls; vehicles never enter
## the rail or ramp lanes or a floor cut and never overlap; a heavy checkpoint's 6 s stop is in the timetable at its stop
## line. Only the top deck has a tram (the rail crossing rule only there): on the rail lane's centre line, one way, a train
## a period, dwelling 20 s at the station, within its speed and acceleration limits, continuous while in sight; a threat
## within 60 m halts it with no jump, it restarts 15 s after the last one and the timetable resumes; its bodies follow it.
## On a stack: ids are unique across decks, a threat on deck 0 leaves deck 1 calm, sweep / blast / pusher work on an offset rotated
## deck in world space, an agent that leaves and re-enters a viewer's range is exactly where the events put it, and a
## snapshot round-trips. setup(district) and the stand-alone checksums are unchanged. No wall-clock timing.

const T0 := 1000.0
const SAMPLE := 600.0
## Stand-alone goldens: life plans captured before phase 3 (unchanged by it); traffic recaptured when the adopted capsule
## pod changed the pod footprint to 3.5 m (its stop lines moved 0.05 m; phase 3 itself left traffic unchanged). Valid while CityPlan seed 1 keeps the plan checksum recorded with them
## (another session may change the city plan; then only the section checks run).
## Re-captured 2026-11-23 with the stand-alone plan (city variety: alleys and road forms on by default; life follows the
## forms: no signal over pedestrian streets / courts, loops only round blocks with vehicle roads, one loop per lane). Was
## 1: 509c51ad1d41d49a / 742568104e969d8d, 2: 504b06bd82a5a9ab / f95817faffc270f1, 3: 14c5573cbbee8a40 / 3daf84e9a4299bca
## (plan 209989488eaa0e52).
const GOLDEN := {
	1: ["cde9f443947f3108", "9871bde2f8293485"],
	2: ["663736b939fb3227", "4f11c6e60adf44b5"],
	3: ["8d12b766dfd8f264", "a3fb3d0f9cf1877b"],
}
const GOLDEN_PLAN_SEED1 := "bd1d848c575e85df"

var stack: CityStack
var life: AmbientLife
var killed: Array = []


func _init() -> void:
	timeout_sec = 500.0


func setup() -> void:
	_pod_checks()
	_standalone_unchanged()
	for seed in [1, 2, 3, 4, 5]:
		_plan_checks(seed)
	for seed in [1, 2, 3, 4, 5]:
		_tram_checks(seed)
	_tram_halt_checks()
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 1}))
	life = _stack_life()
	_id_checks()
	_deck_isolation()
	_tram_body_checks()
	_rotated_checks()
	_viewer_checks()
	_snapshot_checks()
	_event_feed_checks()
	finish()


func _stack_life() -> AmbientLife:
	var l := AmbientLife.new()
	add_child(l)
	l.set_process(false)
	l.setup_stack(stack)
	l.advance_to(T0)
	return l


# --- The pod (user pick capsule_a, adopted in LifeCars) ----------------------------------------------------------

## <= 500 triangles in every lights state, closed (every directed edge has its reverse: no holes when a wreck rolls over),
## the footprint LifeTraffic uses, the wheels under the body showing below it.
func _pod_checks() -> void:
	for lights in 3:
		var geo := CityGeo.new()
		LifeCars.pod(geo, lights)
		var tris := geo.tri_count()
		check(tris <= 500, "pod (lights %d): %d triangles (budget 500)" % [lights, tris])
		var edges := {}
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for i in range(0, geo.verts.size(), 3):
			for k in 3:
				var a := geo.verts[i + k]
				var b := geo.verts[i + (k + 1) % 3]
				lo = lo.min(a)
				hi = hi.max(a)
				var key := "%s>%s" % [_vk(a), _vk(b)]
				edges[key] = int(edges.get(key, 0)) + 1
		var open := 0
		for key: String in edges:
			var parts := key.split(">")
			if int(edges.get(parts[1] + ">" + parts[0], 0)) != int(edges[key]):
				open += 1
		eq(open, 0, "pod (lights %d): closed, consistently wound" % lights)
		var size: Vector3 = LifeTraffic.SIZE["pod"]
		near(hi.z - lo.z, size.z, 0.08, "pod: length matches LifeTraffic.SIZE (%.2f m)" % (hi.z - lo.z))
		near(hi.x - lo.x, size.x, 0.08, "pod: width matches LifeTraffic.SIZE (%.2f m)" % (hi.x - lo.x))
		near(lo.y, 0.0, 0.01, "pod: wheels on the road")
		print("pod lights %d: %d triangles, %.2f x %.2f x %.2f m" % [lights, tris, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z])


static func _vk(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x * 2000.0), roundi(v.y * 2000.0), roundi(v.z * 2000.0)]


# --- Stand-alone unchanged -------------------------------------------------------------------------------------

func _standalone_unchanged() -> void:
	var golden_plan := CityPlan.make({"seed": 1}).checksum() == GOLDEN_PLAN_SEED1
	for seed: int in GOLDEN:
		var lp := LifePlan.make(CityPlan.make({"seed": seed}))
		var tr := LifeTraffic.make(lp)
		check(lp.tram == null and lp.rail_edges.is_empty(), "seed %d stand-alone: no tram, no rail crossings" % seed)
		check(tr.checks.is_empty(), "seed %d stand-alone: no checkpoints" % seed)
		if golden_plan:
			eq(lp.checksum(), GOLDEN[seed][0], "seed %d: stand-alone life plan checksum unchanged" % seed)
			eq(tr.checksum(), GOLDEN[seed][1], "seed %d: stand-alone traffic checksum unchanged" % seed)
	if not golden_plan:
		print("(the stand-alone city plan changed since the goldens were taken: golden life checksums skipped)")
	# setup(district) on a stand-alone district: one unit, ids from 0, no tram, no barriers.
	var d := CityDistrict.new()
	add_child(d)
	d.build({"seed": 1, "walls": 1.0})
	var l := AmbientLife.new()
	add_child(l)
	l.set_process(false)
	l.setup(d)
	l.advance_to(T0)
	check(l.units.size() == 1 and l.unit(0).get_parent() == l and l.stack == null, "setup(district): one deck, routed by the node")
	check(l.unit(0).tram == null and l.unit(0).tram_cars == null and l.unit(0).barriers == null, "setup(district): no tram, no barriers on a district of its own")
	eq(l.ids().size(), l.count(), "setup(district): ids are 0..count-1")
	eq(l.count(), 24 + LifePlan.RIDERS, "setup(district): the default 24 people (+ riders)")
	check(l.is_in_group("ambient_life"), "setup(district): in the group")
	l.queue_free()
	d.queue_free()


# --- Plans ---------------------------------------------------------------------------------------------------

func _plan_checks(seed: int) -> void:
	var sec := SectionPlan.make({"seed": seed})
	var sums := {}
	for k in sec.deck_count:
		var cp := CityPlan.for_deck(sec, k)
		var a := LifePlan.make(cp)
		var b := LifePlan.make(CityPlan.for_deck(SectionPlan.make({"seed": seed}), k))
		eq(a.checksum(), b.checksum(), "seed %d deck %d: the same life plan twice" % [seed, k])
		sums[a.checksum()] = true
		var ta := LifeTraffic.make(a)
		var tb := LifeTraffic.make(b)
		eq(ta.checksum(), tb.checksum(), "seed %d deck %d: the same traffic twice" % [seed, k])
		check(a.count > 0 and a.count <= LifePlan.PEOPLE_CAP, "seed %d deck %d: people within the cap (%d)" % [seed, k, a.count])
		check(ta.pods > 0 and ta.pods <= LifeTraffic.PODS_CAP, "seed %d deck %d: pods within the cap (%d)" % [seed, k, ta.pods])
		check(ta.carts >= 0 and ta.carts <= LifeTraffic.CARTS_CAP, "seed %d deck %d: carts within the cap (%d)" % [seed, k, ta.carts])
		check((a.tram != null) == (k == 0), "seed %d deck %d: a tram only on the top deck" % [seed, k])
		check(a.rail_edges.is_empty() != (k == 0), "seed %d deck %d: the rail crossing rule only with a tram (%d)" % [seed, k, a.rail_edges.size()])
		var avenue := 0
		for lo: Dictionary in ta.loops:
			if lo.has("avenue"):
				avenue += 1
		print("life section seed %d deck %d: plan %s traffic %s  people %d doors %d  pods %d (avenue loops %d) carts %d  rail crossings %d  tram period %.0f s stops %d" % [
				seed, k, a.checksum(), ta.checksum(), a.count, a.doors.size(), ta.pods, avenue, ta.carts, a.rail_edges.size(),
				a.tram.period if a.tram != null else 0.0, a.tram.stops.size() if a.tram != null else 0])
		if k == seed % sec.deck_count or seed == 1:
			_people_sample(cp, a, "seed %d deck %d" % [seed, k])
			_vehicle_sample(cp, ta, "seed %d deck %d" % [seed, k])
		_checkpoint_checks(cp, ta, "seed %d deck %d" % [seed, k])
	eq(sums.size(), sec.deck_count, "seed %d: every deck its own life checksum" % seed)


## 10 minutes of calm at 2 s: never in a floor cut, never outside the walls, in the rail lane only on a rail crossing
## with the tram's timetable more than 40 m clear.
func _people_sample(cp: CityPlan, lp: LifePlan, what: String) -> void:
	var cuts := cp.floor_cuts()
	var rail := cp.section.lane_x("rail")
	var e := cp.extent
	var out := 0
	var hole := 0
	var on_rail := 0
	var bad_rail := 0
	var seen := 0
	for id in lp.count:
		var t := 0.0
		while t < SAMPLE:
			var p := lp.calm_pose(id, T0 + t)
			var tt := T0 + t
			t += 2.0
			if not p["visible"]:
				continue
			seen += 1
			var at := Vector2(p["x"], p["s"])
			if not e.has_point(at):
				out += 1
			for o in cuts:
				if o.grow(0.3).has_point(at):
					hole += 1
			if at.x > rail.x + 0.5 and at.x < rail.y - 0.5:
				on_rail += 1
				var ok := false
				for ei: int in lp.rail_edges:
					# 1.0 m: walkers keep to their own lane of the crossing, up to 0.9 m off its centre line (user, 2026-11-27).
					if absf(at.y - float(lp.rail_edges[ei])) < 1.0:
						ok = true
				if lp.tram == null:
					continue        # no tram on this deck: no rail rule (the rail lane is a verge, crossed freely)
				var b := lp.tram.base(tt)
				if not ok or absf(float(b["s"]) - at.y) - LifeTram.HALF < 40.0:
					bad_rail += 1
	print("life section %s: %d outdoor samples, %d on the rail lane" % [what, seen, on_rail])
	check(seen > 1000, "%s: people outdoors over 10 minutes (%d samples)" % [what, seen])
	eq(out, 0, "%s: nobody outside the walls" % what)
	eq(hole, 0, "%s: nobody in a floor cut or ramp mouth" % what)
	eq(bad_rail, 0, "%s: in the rail lane only on a cross-street crossing with the tram 40 m clear (%d samples on the rail)" % [what, on_rail])


## 10 minutes of calm at 0.5 s: no vehicle in the rail or ramp lanes, a floor cut or outside the walls; never two closer
## than 3 m (centre to centre).
func _vehicle_sample(cp: CityPlan, tr: LifeTraffic, what: String) -> void:
	var lanes: Array[Vector2] = []
	for n: String in ["rail", "ramp_a", "ramp_b"]:
		lanes.append(cp.section.lane_x(n))
	var cuts := cp.floor_cuts()
	var e := cp.extent
	var bad_lane := 0
	var bad_cut := 0
	var bad_out := 0
	var close := 0
	var t := 0.0
	while t < SAMPLE:
		var pts: Array[Vector2] = []
		for vid in tr.count():
			var p := tr.base_pose(vid, T0 + t)
			var at := Vector2(p["x"], p["s"])
			pts.append(at)
			var hw := float((LifeTraffic.SIZE[tr.vehicles[vid]["kind"]] as Vector3).x) * 0.5
			for l in lanes:
				if at.x > l.x - hw + 0.05 and at.x < l.y + hw - 0.05:
					bad_lane += 1
			for o in cuts:
				if o.grow(CityDims.HOLE_CURB + hw).has_point(at):
					bad_cut += 1
			if not e.grow(-hw).has_point(at):
				bad_out += 1
		for i in pts.size():
			for j in range(i + 1, pts.size()):
				if pts[i].distance_to(pts[j]) < 3.0:
					close += 1
		t += 0.5
	eq(bad_lane, 0, "%s: no vehicle in the rail or ramp lanes" % what)
	eq(bad_cut, 0, "%s: no vehicle in a floor cut" % what)
	eq(bad_out, 0, "%s: no vehicle outside the walls" % what)
	eq(close, 0, "%s: no two vehicles closer than 3 m" % what)


## Every heavy checkpoint on the deck: some loop turns at it, and every such loop holds CHECK_STOP s at that stop line
## (in its legs, before the turn), within 25 m of the barrier line.
func _checkpoint_checks(cp: CityPlan, tr: LifeTraffic, what: String) -> void:
	for jid: int in tr.checks:
		var hk: Dictionary = tr.checks[jid]
		var loops := 0
		for li in tr.loops.size():
			var lo: Dictionary = tr.loops[li]
			for m: Dictionary in lo["marks"]:
				if int(m.get("check", -1)) != jid:
					continue
				loops += 1
				var u := float(m["u"])
				var held := 0.0
				var legs: PackedFloat64Array = lo["legs"]
				for i in legs.size() / LifeTraffic.LEG:
					var o := i * LifeTraffic.LEG
					if int(legs[o + 4]) == LifeTraffic.HOLD and absf(legs[o + 2] - u) < 0.02 and absf(legs[o + 3] - u) < 0.02:
						held = legs[o + 1] - legs[o]
				near(held, LifeTraffic.CHECK_STOP, 1e-6, "%s: a loop stops %.0f s at the heavy checkpoint" % [what, LifeTraffic.CHECK_STOP])
				var pt: Vector2 = tr.point_at(li, u)[0]
				var dist := pt.distance_to(Vector2(hk["x"], hk["s"]))
				check(dist < 25.0, "%s: the checkpoint stop is at the barrier (%.1f m)" % [what, dist])
		check(loops > 0, "%s: some vehicle loop passes the heavy checkpoint at junction %d" % [what, jid])
	var heavy := 0
	for it: Dictionary in LifeBarriers.items(cp):
		if it["kind"] == "heavy":
			heavy += 1
	eq(heavy, tr.checks.size(), "%s: a barrier at every heavy checkpoint" % what)


# --- The tram ------------------------------------------------------------------------------------------------

## Only the top deck has a tram: on the rail lane's centre line, one way (+s), coming in hidden from the s0 tunnel,
## dwelling DWELL s at the station's centre, leaving into the s1 tunnel, one train a period (>= pass time + GAP); while
## visible it moves continuously, never over 14 m/s nor 1.2 m/s^2, never backwards.
func _tram_checks(seed: int) -> void:
	var sec := SectionPlan.make({"seed": seed})
	for k in sec.deck_count:
		var cp := CityPlan.for_deck(sec, k)
		var tram := LifeTram.make(cp, 0.37)
		var what := "seed %d deck %d tram" % [seed, k]
		if k > 0:
			check(tram == null, "%s: none (only the top deck has a tram)" % what)
			continue
		if not check(tram != null, "%s: the top deck has one" % what):
			continue
		var rail := sec.lane_x("rail")
		near(tram.x, (rail.x + rail.y) * 0.5, 1e-6, "%s: on the rail lane's centre line" % what)
		check(tram.x - LifeTram.CAR_W * 0.5 > rail.x and tram.x + LifeTram.CAR_W * 0.5 < rail.y, "%s: its cars inside the rail lane" % what)
		var st := CityStation.of(cp)
		if check(not st.is_empty(), "%s: the deck has its station" % what):
			near(tram.stop_s, float(st["stop_s"]), 1e-6, "%s: it stops at the platform's centre" % what)
		check(tram.period >= tram.pass_time + LifeTram.GAP - 1e-6 and tram.period >= LifeTram.PERIOD, "%s: period %.0f s (pass %.1f s)" % [what, tram.period, tram.pass_time])
		var dt := 0.1
		var prev := tram.pose(T0)
		var jumps := 0
		var too_fast := 0
		var too_hard := 0
		var backwards := 0
		var visible_t := 0.0
		var arrivals := 0
		var dwell := 0.0
		var best_dwell := 0.0
		var t := dt
		while t <= tram.period * 2.0:
			var p := tram.pose(T0 + t)
			var s := float(p["s"])
			var v := float(p["v"])
			var vis: bool = p["mode"] != "away"
			var pvis: bool = prev["mode"] != "away"
			if vis and pvis:
				if absf(s - float(prev["s"])) > LifeTram.V * dt + 1e-3:
					jumps += 1
				if absf(v - float(prev["v"])) > LifeTram.ACC * dt + 1e-3:
					too_hard += 1
				if s < float(prev["s"]) - 1e-6:
					backwards += 1
			if vis and not pvis:
				arrivals += 1
			if v > LifeTram.V + 1e-3 or v < -1e-9:
				too_fast += 1
			if vis:
				visible_t += dt
			if p["mode"] == "dwell" and absf(s - tram.stop_s) < 0.01:
				dwell += dt
				best_dwell = maxf(best_dwell, dwell)
			else:
				dwell = 0.0
			prev = p
			t += dt
		eq(jumps, 0, "%s: continuous motion while visible" % what)
		eq(too_fast, 0, "%s: never over 14 m/s, never backwards (speed)" % what)
		eq(too_hard, 0, "%s: never over 1.2 m/s^2 on the timetable" % what)
		eq(backwards, 0, "%s: one way only" % what)
		check(arrivals >= 2, "%s: a train comes in every period (%d in two)" % [what, arrivals])
		check(visible_t > 30.0 and visible_t < tram.period * 2.0 - 30.0, "%s: in sight part of the time (%.0f s of %.0f)" % [what, visible_t, tram.period * 2.0])
		check(best_dwell >= LifeTram.DWELL - 0.15, "%s: dwells 20 s at the station (%.1f s)" % [what, best_dwell])
		print("life section %s: period %.0f s, pass %.1f s, stop s %.1f, track x %.2f, checksum %s" % [what, tram.period, tram.pass_time, tram.stop_s, tram.x, tram.checksum()])


func _tram_halt_checks() -> void:
	var cp := CityPlan.for_deck(SectionPlan.make({"seed": 2}), 0)
	var tram := LifeTram.make(cp, 0.21)
	# Find the tram in sight at cruise speed.
	var T := T0
	while not (tram.state_of(T) == "running" and float(tram.pose(T)["v"]) > LifeTram.V - 0.01):
		T += 0.5
	var s0 := float(tram.pose(T)["s"])
	tram.apply_threat({"x": tram.x + 70.0, "s": s0, "r": 40.0, "st": 2, "t": T})
	eq(tram.episodes.size(), 0, "tram: a threat 70 m from every car does not halt it")
	tram.apply_threat({"x": tram.x + 30.0, "s": s0, "r": 40.0, "st": 2, "t": T})
	eq(tram.episodes.size(), 1, "tram: a threat 30 m away halts it")
	var dt := 0.02
	var prev := tram.pose(T - dt)
	var jumps := 0
	var hard := 0
	var t := T
	var stopped_at := -1.0
	while t < T + 60.0:
		var p := tram.pose(t)
		if p["mode"] != "away" and prev["mode"] != "away":
			if absf(float(p["s"]) - float(prev["s"])) > LifeTram.V * dt + 1e-3:
				jumps += 1
			if absf(float(p["v"]) - float(prev["v"])) > LifeTram.BRAKE * dt + 1e-3:
				hard += 1
		if stopped_at < 0.0 and absf(float(p["v"])) < 1e-6 and t > T + 1.0:
			stopped_at = t
		prev = p
		t += dt
	eq(jumps, 0, "tram halt: no jump through braking, the halt and the restart")
	eq(hard, 0, "tram halt: never harder than 2.5 m/s^2")
	near(stopped_at, T + LifeTram.REACT + LifeTram.V / LifeTram.BRAKE, 0.05, "tram halt: brakes from 14 m/s to a stop at 2.5 m/s^2")
	eq(tram.state_of(T + 8.0), "halted", "tram halt: halted")
	check(bool(tram.pose(T + 8.0)["hazard"]), "tram halt: hazards on")
	eq(tram.state_of(T + LifeTram.RESTART - 0.1), "halted", "tram halt: still held just before 15 s")
	eq(tram.state_of(T + LifeTram.RESTART + 0.5), "running", "tram halt: restarts 15 s after the threat")
	var later := T + tram.period * 3.0
	near(float(tram.pose(later)["s"]), float(tram.base(later)["s"]), 1e-6, "tram halt: the timetable resumes with a later train")
	var tram2 := LifeTram.make(cp, 0.21)
	tram2.apply_threat({"x": tram2.x, "s": s0, "r": 40.0, "st": 2, "t": T})
	tram2.apply_threat({"x": tram2.x, "s": float(tram2.pose(T + 10.0)["s"]), "r": 40.0, "st": 2, "t": T + 10.0})
	eq(tram2.episodes.size(), 1, "tram: a threat during the hold extends it (one episode)")
	eq(tram2.state_of(T + 24.8), "halted", "tram: held until 15 s after the last threat")
	eq(tram2.state_of(T + 25.5), "running", "tram: restarts 15 s after the last threat")
	var tram3 := LifeTram.make(cp, 0.21)
	tram3.restore(tram2.snapshot())
	var same := true
	for i in 100:
		if absf(float(tram3.pose(T + float(i))["s"]) - float(tram2.pose(T + float(i))["s"])) > 1e-6:
			same = false
	check(same, "tram: snapshot round trip")


# --- Stack ---------------------------------------------------------------------------------------------------

func _id_checks() -> void:
	var ids := life.ids()
	var seen := {}
	for id in ids:
		seen[id] = true
	eq(seen.size(), ids.size(), "stack: person ids unique across decks (%d)" % ids.size())
	eq(ids.size(), life.count(), "stack: count() is every deck's people")
	var vids := life.vehicle_ids()
	var vseen := {}
	for id in vids:
		vseen[id] = true
	eq(vseen.size(), vids.size(), "stack: vehicle ids unique across decks (%d)" % vids.size())
	eq(life.units.size(), stack.decks.size(), "stack: one unit per deck")
	for u in life.units:
		check(not u.is_in_group("ambient_life"), "stack: a unit is not in the group")
		check((u.tram != null and u.tram_cars != null) == (u.deck == 0), "stack deck %d: a tram only on the top deck" % u.deck)
	check(life.is_in_group("ambient_life"), "stack: the stack node is in the group")
	var in_group := 0
	for n in get_tree().get_nodes_in_group("ambient_life"):
		if not n.is_queued_for_deletion():
			in_group += 1
	eq(in_group, 1, "stack: one node in the group")


## A calm person outdoors on deck k (a stack id), or -1.
func _outdoor(k: int) -> int:
	var u := life.unit(k)
	for i in u.count():
		if u.visible_now(i) and u.state_of(i) == "calm":
			return k * AmbientLife.ID_STRIDE + i
	return -1


func _alarmed(k: int) -> int:
	var u := life.unit(k)
	var n := 0
	for i in u.count():
		var st := u.state_of(i)
		if st == "wary" or st == "fleeing" or st == "cowering" or st == "hands_up":
			n += 1
	return n


func _deck_isolation() -> void:
	var id := _outdoor(0)
	check(id >= 0, "stack: someone outdoors on deck 0")
	if id < 0:
		return
	var p := life.pose_of(id)
	life.raise_threat(p.origin + p.basis.y * 1.0, 40.0, 2)
	life.advance_to(T0 + 3.0)
	check(_alarmed(0) > 0, "stack: a threat on deck 0 alarms people on deck 0 (%d)" % _alarmed(0))
	eq(_alarmed(1), 0, "stack: ... and nobody on deck 1")
	eq(_alarmed(2), 0, "stack: ... nor deck 2")
	check(life.unit(1).tram == null and life.unit(1).tram_cars == null, "stack: deck 1 has no tram")
	var d: Dictionary = life.sent[-1][1]
	eq(int(d.get("deck", -1)), 0, "stack: the threat event names its deck")
	life.restore(PackedByteArray())
	life.advance_to(T0)


func _tram_body_checks() -> void:
	var u := life.unit(0)
	var ok := true
	var enabled := 0
	for i in 40:
		life.advance_to(T0 + float(i) * 7.3)
		for c in LifeTram.CARS:
			var want := u.tram_car_pose(c)
			var got := u.tram_cars.bodies[c].global_transform
			if want.origin.distance_to(got.origin) > 1e-3 or not want.basis.is_equal_approx(got.basis):
				ok = false
			var cs := LifeTram.car_s(float(u.tram.pose(u.now)["s"]), c)
			var shape := u.tram_cars.bodies[c].get_child(0) as CollisionShape3D
			if u.tram.car_solid(cs) == shape.disabled:
				ok = false
			if not shape.disabled:
				enabled += 1
	check(ok, "tram: every car's collision body follows the tram's pose (and is off beyond a wall)")
	check(enabled > 0, "tram: car collision is on inside the map")
	eq(u.tram_cars.bodies[0].collision_layer, 1, "tram: cars on the district's collision layer")
	check(u.tram_cars.bodies[0] is AnimatableBody3D, "tram: kinematic bodies (AnimatableBody3D)")
	# Shots and blasts ignore the tram (only a threat event halts it).
	var c0 := u.tram_car_pose(1)
	life.sweep(c0.origin + c0.basis.x * 20.0 + c0.basis.y * 1.5, c0.origin - c0.basis.x * 20.0 + c0.basis.y * 1.5, 0.3, 1)
	life.blast(c0.origin + c0.basis.y * 1.0, 3.0, 1)
	eq(u.tram.episodes.size(), 0, "tram: shots and blasts do not touch it")
	life.restore(PackedByteArray())
	life.advance_to(T0)


func _rotated_checks() -> void:
	stack.position = Vector3(30.0, -12.0, 55.0)
	stack.rotation = Vector3(0.2, 0.7, -0.1)
	# 2026-11-23 (forms live): pushers are handed to a deck by CityStack.deck_at, which ignored the stack's rotation (the
	# foot below was handed to deck 1 once the forms moved the person picked to s = -117). Every deck, far along the arc.
	var wrong := []
	for k in stack.decks.size():
		var dk: CityDistrict = stack.decks[k]
		for s: float in [-160.0, -117.0, -60.0, 0.0, 60.0, 117.0, 160.0]:
			for h: float in [0.2, 1.5]:
				if stack.deck_at(dk.to_global(dk.ring.arc_to_world(40.0, s, h))) != k:
					wrong.append([k, s, h])
	eq(wrong, [], "rotated stack: deck_at names the deck a point stands on, anywhere along the arc")
	life.restore(PackedByteArray())
	life.advance_to(T0 + 5.0)
	killed.clear()
	if not life.civilian_killed.is_connected(_on_killed):
		life.civilian_killed.connect(_on_killed)
	var id := _outdoor(1)
	check(id >= 0, "rotated stack: someone outdoors on deck 1")
	if id >= 0:
		var xf := life.pose_of(id)
		var mid := xf.origin + xf.basis.y * 1.0
		var n := life.sweep(mid - xf.basis.x * 0.6, mid + xf.basis.x * 0.6, 0.1, 1)
		check(n >= 1, "rotated stack: a short sweep through a person on deck 1 hits (%d)" % n)
		eq(life.state_of(id), "down", "rotated stack: that person is down")
		check(killed.size() >= 1 and int(killed[0]) == id, "rotated stack: civilian_killed carries the stack id (%s, want %d)" % [str(killed), id])
	var u2 := life.unit(2)
	var vid := -1
	for v in u2.vehicle_count():
		if u2.vehicle_state(v) != "wreck":
			vid = v
			break
	check(vid >= 0, "rotated stack: a vehicle on deck 2")
	if vid >= 0:
		var vx := u2.vehicle_pose(vid)
		life.blast(vx.origin + vx.basis.y * 0.8, 2.5, 1)
		eq(life.vehicle_state(2 * AmbientLife.ID_STRIDE + vid), "wreck", "rotated stack: a blast on deck 2 wrecks the vehicle there")
	var pid := _outdoor(0)
	check(pid >= 0, "rotated stack: someone outdoors on deck 0")
	if pid >= 0:
		var foot := Node3D.new()
		add_child(foot)
		var target := life.pose_of(pid).origin
		var dir := life.pose_of(pid).basis.x
		foot.global_position = target - dir * 3.0
		life.add_pusher(foot, 1.0, 2)
		var t := life.now
		for i in 20:
			foot.global_position += dir * 0.3
			t += 0.05
			life.advance_to(t)
		eq(life.state_of(pid), "down", "rotated stack: a mech foot walking through a person on deck 0 kills")
		life.remove_pusher(foot)
		foot.queue_free()
	stack.position = Vector3.ZERO
	stack.rotation = Vector3.ZERO
	life.restore(PackedByteArray())
	life.advance_to(T0)


func _on_killed(id: int, _p: Vector3, _src: int) -> void:
	killed.append(id)


## Frames (not advance_to): the per-tick culling path, offline clock.
func _frames(l: AmbientLife, n: int, dt: float) -> void:
	for i in n:
		l._process(dt)      # (steps every deck)


func _viewer_checks() -> void:
	var viewer := Node3D.new()
	add_child(viewer)
	var u := life.unit(0)
	var e := u.district.plan.extent
	viewer.global_position = u.district.global_transform * u.district.ring.arc_to_world(e.position.x + 10.0, e.position.y + 10.0, 5.0)
	life.add_viewer(viewer)
	life.advance_to(T0 + 20.0)
	_frames(life, 4, 0.05)
	check(not life.unit(1)._active and not life.unit(2)._active, "viewer on deck 0: decks 1 and 2 are not evaluated")
	check(u._active and u._cull, "viewer on deck 0: deck 0 is, culled by range")
	var far := -1
	for i in u.count():
		if u.visible_now(i) and u.state_of(i) == "calm" and u.pose_of(i).origin.distance_to(viewer.global_position) > 260.0:
			far = i
			break
	check(far >= 0, "viewer: someone outdoors far from the viewer")
	if far < 0:
		life.remove_viewer(viewer)
		viewer.queue_free()
		return
	check(not u.drawn_now(far), "viewer: a person beyond 200 m is not drawn")
	var shown := 0
	for i in u.count():
		if u.drawn_now(i):
			shown += 1
	check(shown < u.count(), "viewer: only part of the deck is drawn (%d of %d)" % [shown, u.count()])
	# A threat at it while it is out of range.
	var at := u.pose_of(far).origin
	var up := u.pose_of(far).basis.y
	var t_ev := life.now
	life.raise_threat(at, 40.0, 2)
	_frames(life, 60, 0.05)
	var ref := _stack_life()
	ref.restore(PackedByteArray())
	for ev: Array in life.sent:
		if float((ev[1] as Dictionary).get("t", 0.0)) >= t_ev - 1e-6:
			ref.apply_event(ev[0], ev[1])
	# Bring the viewer to it.
	viewer.global_position = at + up * 5.0
	_frames(life, 30, 0.05)
	ref.advance_to(life.now)
	eq(u.state_of(far), ref.unit(0).state_of(far), "viewer: back in range, its state is the one the events imply (%s)" % u.state_of(far))
	var exact := ref.unit(0).pose_of(far).origin
	check(u.pose_of(far).origin.distance_to(exact) < 1e-3, "viewer: back in range, exactly where the events put it")
	if u.visible_now(far):
		check(u.drawn_now(far), "viewer: drawn again once in range")
		var f := clampf((u.now - u._ta[far]) / maxf(u._tb[far] - u._ta[far], 1e-6), 0.0, 1.0)
		var drawn: Transform3D = u.to_world() * u._xa[far].interpolate_with(u._xb[far], f)
		check(drawn.origin.distance_to(exact) < 1.0, "viewer: its drawn pose is on its exact pose (%.2f m)" % drawn.origin.distance_to(exact))
	ref.queue_free()
	life.remove_viewer(viewer)
	viewer.queue_free()
	_frames(life, 2, 0.05)
	check(life.unit(1)._active, "no viewer: every deck evaluated again")
	life.restore(PackedByteArray())
	life.advance_to(T0)


func _signature(l: AmbientLife) -> String:
	var parts := PackedStringArray()
	for id in l.ids():
		var xf := l.pose_of(id)
		parts.append("%d:%s:%.3f,%.3f,%.3f" % [id, l.state_of(id), xf.origin.x, xf.origin.y, xf.origin.z])
	for id in l.vehicle_ids():
		var xf := l.vehicle_pose(id)
		parts.append("v%d:%s:%.3f,%.3f,%.3f" % [id, l.vehicle_state(id), xf.origin.x, xf.origin.y, xf.origin.z])
	for u in l.units:
		if u.tram != null:
			parts.append("tram%d:%s:%.3f" % [u.deck, u.tram.state_of(u.now), float(u.tram.pose(u.now)["s"])])
	return "|".join(parts)


## A threat beside the tram (deck 0), a kill on deck 1, a wreck on deck 2.
func _busy() -> void:
	life.restore(PackedByteArray())
	life.sent.clear()
	life.advance_to(maxf(life.now, T0) + 60.0)      # past the last threat the earlier checks sent (a deck sends at most 4 a second)
	for k in life.units.size():
		var u := life.unit(k)
		if u.tram == null:
			continue
		while u.tram.state_of(life.now) == "away" or absf(float(u.tram.pose(life.now)["s"])) > u.tram.wall_hi - 60.0:
			life.advance_to(life.now + 2.0)      # a train in sight, well inside the deck
		var c := u.tram_car_pose(1)
		life.raise_threat(c.origin + c.basis.x * 25.0, 40.0, 2)
		life.advance_to(life.now + 0.3)
	var id := _outdoor(1)
	if id >= 0:
		var xf := life.pose_of(id)
		life.sweep(xf.origin + xf.basis.y - xf.basis.x, xf.origin + xf.basis.y + xf.basis.x, 0.2, 3)
	var u2 := life.unit(2)
	for v in u2.vehicle_count():
		if u2.vehicle_state(v) != "wreck":
			var vx := u2.vehicle_pose(v)
			life.blast(vx.origin + vx.basis.y * 0.8, 2.0, 3)
			break
	life.advance_to(life.now + 6.0)


func _snapshot_checks() -> void:
	_busy()
	var halted := 0
	for u in life.units:
		halted += u.tram.episodes.size() if u.tram != null else 0
	check(halted > 0, "stack snapshot: the busy scene halted trams (%d)" % halted)
	var bytes := life.snapshot()
	var other := _stack_life()
	other.advance_to(life.now)
	other.restore(bytes)
	other.advance_to(life.now)
	for t: float in [0.0, 12.0, 40.0]:
		life.advance_to(life.now + t)
		other.advance_to(life.now)
		eq(_signature(other), _signature(life), "stack snapshot: the joiner agrees %.0f s on" % t)
	eq(JSON.stringify(other.tally()), JSON.stringify(life.tally()), "stack snapshot: same tallies")
	print("life stack snapshot: %d bytes (3 decks, busy)" % bytes.size())
	other.queue_free()


func _event_feed_checks() -> void:
	_busy()
	var other := _stack_life()
	other.restore(PackedByteArray())
	for ev: Array in life.sent:
		other.apply_event(ev[0], ev[1])
	other.advance_to(life.now)
	eq(_signature(other), _signature(life), "stack: a second instance fed the host's events (with \"d\") agrees")
	other.queue_free()
