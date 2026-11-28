extends TestCase
## The spine's lanes and markings (docs/design/city-spine.md sections 2 and 3; CityStreets.spine_layout, plan data only, no
## pixels): right-hand traffic, two-way roads, one lane per direction. For several sections, on every deck: exactly one
## tram track and only on the tram deck; a service road only in a ramp lane with a ramp mouth on that deck, a promenade
## (no road markings) elsewhere; every stop line on its road's approach half, before its junction box (or DOOR_STOP before a
## road door); arrows in the right-hand lane of their direction, the left-turn pocket only on the main road; zebras only on
## the main road and service roads and never in a junction box; the main road's split derived from its width; the ramp
## parts lie on the plan's slope run (sec.ramp_run) and their free ends, drawn ribbon included, are RAMP_END_PAST_BOX off
## every junction box; the avenue pods drive on the painted lane centres, walkers cross on the drawn zebras, and the rail crossing rule
## exists only where there is track. Street props (CityPropLayout) keep off the paint, the track and the platform, and on
## the spine only trees stand, on the planted medians and verges (a tree line on each).

const SEEDS := [1, 2, 3, 4, 5, 7, 9]
const EPS := 0.01


func setup() -> void:
	timeout_sec = 240.0
	_split()
	for seed_: int in SEEDS:
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			_deck(sec, k, "seed %d deck %d" % [seed_, k])
	finish()


## The main road's split: 1 m edges, lanes capped at 4.5 m, the rest to the centre strip.
func _split() -> void:
	var s14 := CityDims.avenue_split(14.0)
	near(float(s14["edge"]), 1.0, 1e-6, "14 m main road: 1 m edges")
	near(float(s14["lane"]), 4.0, 1e-6, "14 m main road: 4 m lanes")
	near(float(s14["centre"]), 4.0, 1e-6, "14 m main road: 4 m centre strip")
	var s18 := CityDims.avenue_split(18.0)
	near(float(s18["lane"]), 4.5, 1e-6, "18 m main road: lanes capped at 4.5 m")
	near(float(s18["centre"]), 7.0, 1e-6, "18 m main road: the surplus goes to the centre strip")
	var l14 := CityDims.avenue_lanes(Vector2(0.0, 14.0))
	near(l14.x, 3.0, 1e-6, "14 m: the +s lane is centred 3 m in from the -x edge")
	near(l14.y, 11.0, 1e-6, "14 m: the -s lane 3 m in from the +x edge")


func _deck(sec: SectionPlan, k: int, what: String) -> void:
	var plan := CityPlan.for_deck(sec, k)
	var lay := CityStreets.spine_layout(plan)
	var lanes: Dictionary = lay["lanes"]
	var marks: Array = lay["marks"]
	if not check(lanes.size() == 4, "%s: the spine has its four lanes" % what):
		return
	# Lane kinds.
	var rail: Dictionary = lanes["rail"]
	eq(str(rail["kind"]), "tram" if k == CityDims.TRAM_DECK else "verge", "%s: the tram strip has track only on the tram deck" % what)
	for id: String in ["ramp_a", "ramp_b"]:
		var ln: Dictionary = lanes[id]
		var has := not CityStreets.lane_ramps(plan, float(ln["a"]), float(ln["b"])).is_empty()
		eq(str(ln["kind"]), "service" if has else "promenade", "%s: %s is a service road only with a ramp mouth on the deck" % [what, id])
	print("%s: ramp_a %s, avenue %s, rail %s, ramp_b %s" % [what, lanes["ramp_a"]["kind"], lanes["avenue"]["kind"], rail["kind"], lanes["ramp_b"]["kind"]])
	var by_kind := {}
	for m: Dictionary in marks:
		var kk := str(m["kind"])
		by_kind[kk] = int(by_kind.get(kk, 0)) + 1
		var lane := str(m["lane"])
		if lanes.has(lane) and str(lanes[lane]["kind"]) == "promenade":
			check(kk == "promenade", "%s: nothing but paving on the promenade %s (found %s)" % [what, lane, kk])
	# Track.
	var tracks := marks.filter(func(m: Dictionary) -> bool: return m["kind"] == "track")
	eq(tracks.size(), 1 if k == CityDims.TRAM_DECK else 0, "%s: exactly one track on the tram deck, none elsewhere" % what)
	var rx := sec.lane_x("rail")
	for t: Dictionary in tracks:
		near(float(t["x"]), (rx.x + rx.y) * 0.5, 1e-4, "%s: the track runs on the tram strip's centre line" % what)
	var hatches := marks.filter(func(m: Dictionary) -> bool: return m["kind"] == "hatch" and m["what"] == "tram_box")
	eq(hatches.size(), plan.roads_s.size() if k == CityDims.TRAM_DECK else 0, "%s: a keep-clear hatch in every junction box over the track" % what)
	# Stop lines, arrows, zebras.
	var av := sec.lane_x("avenue")
	var sp := CityDims.avenue_split(av.y - av.x)
	var xl0 := av.x + float(sp["edge"])
	var xl1 := xl0 + float(sp["lane"])
	var xr1 := av.y - float(sp["edge"])
	var xr0 := xr1 - float(sp["lane"])
	var centres := CityDims.avenue_lanes(av)
	var walls := CityStreets.end_walls(plan)
	var road := CityStreets.spine_road(plan)
	var bad_stop := 0
	var bad_arrow := 0
	var bad_zebra := 0
	var through_x := {}
	for m: Dictionary in marks:
		var lane := str(m["lane"])
		match str(m["kind"]):
			"stop":
				var r: Rect2 = m["rect"]
				var dir := float(m["dir"])
				var ok := true
				if lane == "avenue" and bool(m["door"]):
					# Across the door-bound half of the main road, as far as the door reaches.
					var mid := (av.x + av.y) * 0.5
					ok = (r.end.x <= mid + EPS and r.position.x >= xl0 - EPS) if dir > 0.0 else (r.position.x >= mid - EPS and r.end.x <= xr1 + EPS)
				elif lane == "avenue":
					ok = (r.end.x <= xr0 + EPS and r.position.x <= xl0 + EPS) if dir > 0.0 else (r.position.x >= xl1 - EPS and r.end.x >= xr1 - EPS)
				else:
					var ln: Dictionary = lanes[lane]
					var mid := (float(ln["a"]) + float(ln["b"])) * 0.5
					ok = (r.end.x <= mid + EPS) if dir > 0.0 else (r.position.x >= mid - EPS)
				var bx := Vector2(float(plan.roads_s[int(m["junction"])]["a"]), float(plan.roads_s[int(m["junction"])]["b"]))
				if bool(m["door"]):
					var at := float(walls[int(m["junction"])]["at"])
					ok = ok and absf(absf(at - (r.end.y if dir > 0.0 else r.position.y)) - CityStreets.DOOR_STOP) < EPS
				else:
					var gap := (bx.x - r.end.y) if dir > 0.0 else (r.position.y - bx.y)
					ok = ok and gap > 0.0 and gap < 10.0
				if not ok:
					bad_stop += 1
					print("%s: stop line off its approach half: %s" % [what, str(m)])
			"arrow":
				var at: Vector2 = m["at"]
				var fwd: Vector2 = m["fwd"]
				var glyph := str(m["glyph"])
				var ok := true
				if lane == "cross":
					var cr: Dictionary = plan.roads_s[int(m["junction"])]
					var c := (float(cr["a"]) + float(cr["b"])) * 0.5
					ok = glyph == "combined" and ((at.y > c and at.x < float(road["a"])) if fwd.x > 0.0 else (at.y < c and at.x > float(road["b"])))
				elif lane == "avenue":
					if glyph == "left":
						ok = absf(at.x - (av.x + av.y) * 0.5) < EPS
					else:
						ok = glyph == "straight_right" and absf(at.x - (centres.x if fwd.y > 0.0 else centres.y)) < EPS
						through_x[fwd.y > 0.0] = at.x
				else:
					var ln: Dictionary = lanes[lane]
					var mid := (float(ln["a"]) + float(ln["b"])) * 0.5
					ok = str(ln["kind"]) == "service" and glyph in ["straight_right", "down", "merge"] and ((at.x < mid) if fwd.y > 0.0 else (at.x > mid))
				# An arrow points toward its junction: the box lies ahead.
				if lane != "cross":
					var cr2: Dictionary = plan.roads_s[int(m["junction"])]
					ok = ok and ((float(cr2["a"]) > at.y) if fwd.y > 0.0 else (float(cr2["b"]) < at.y))
				if not ok:
					bad_arrow += 1
					print("%s: arrow wrong: %s" % [what, str(m)])
			"zebra":
				var r: Rect2 = m["rect"]
				var ok: bool = lanes.has(lane) and str(lanes[lane]["kind"]) in ["main", "service"]
				for cr: Dictionary in plan.roads_s:
					if r.end.y > float(cr["a"]) + EPS and r.position.y < float(cr["b"]) - EPS:
						ok = false
				if not ok:
					bad_zebra += 1
					print("%s: zebra wrong: %s" % [what, str(m)])
	eq(bad_stop, 0, "%s: every stop line on its approach half, before its box or door (%d)" % [what, int(by_kind.get("stop", 0))])
	eq(bad_arrow, 0, "%s: every arrow in the right lane, pointing at its junction; left turns only from the main road's pocket (%d)" % [what, int(by_kind.get("arrow", 0))])
	eq(bad_zebra, 0, "%s: zebras only on the main road and service roads, never in a junction box (%d)" % [what, int(by_kind.get("zebra", 0))])
	check(int(by_kind.get("stop", 0)) > 0 and int(by_kind.get("arrow", 0)) > 0 and int(by_kind.get("zebra", 0)) > 0, "%s: stop lines, arrows and zebras drawn" % what)
	# Ramp slope runs.
	# Ramp slope runs (R2.17): every part on the plan's run (sec.ramp_run), its end (the top part's mouth, the bottom
	# part's foot) clear of every junction box by the plan's own margin (cross road half width + RAMP_END_PAST_BOX from
	# the line centre, so RAMP_END_PAST_BOX past the box), and the drawn ribbon ending there. Physics: test_ramp_walk.
	for r: Dictionary in plan.ramps:
		var top: bool = r["role"] == "top"
		var run := CityDims.ramp_run(plan, r)
		var prun := plan.section.ramp_run(int(r["connector"]), plan.deck)
		near(run.x, prun.x, 1e-3, "%s: the %s part's run starts where the plan's does" % [what, r["role"]])
		near(run.y, prun.y, 1e-3, "%s: and ends where the plan's does" % what)
		var end_s := float(r["s_top"]) if top else float(r["s_foot"])
		near(end_s, run.x if top else run.y, 1e-3, "%s: the %s part's free end is on the run's end" % [what, r["role"]])
		var drawn := CityStreets.ramp_span(r, plan.site.slab, true)
		check(absf(drawn.x - end_s) < 1e-3 or absf(drawn.y - end_s) < 1e-3, "%s: the drawn ribbon ends there" % what)
		var clear := INF
		for cr: Dictionary in plan.roads_s:
			clear = minf(clear, maxf(float(cr["a"]) - end_s, end_s - float(cr["b"])))
		check(clear >= SectionPlan.RAMP_END_PAST_BOX - 0.5, "%s: the %s part's slope ends %.2f m off the nearest junction box" % [what, r["role"], clear])
	# Life: pods on the painted lanes, walkers on the zebras, the rail rule only with track.
	var lp := LifePlan.new()
	lp.build(plan)
	var tr := LifeTraffic.new()
	tr.build(lp)
	var avenue_loops := 0
	for lo: Dictionary in tr.loops:
		if not lo.has("avenue"):
			continue
		avenue_loops += 1
		var on := [false, false]
		for p: Vector2 in lo["pts"]:
			on[0] = on[0] or absf(p.x - centres.x) < 1e-4
			on[1] = on[1] or absf(p.x - centres.y) < 1e-4
		check(on[0] and on[1], "%s: avenue loop %d drives on both painted lane centres" % [what, int(lo["avenue"])])
	if avenue_loops > 0:
		for d: bool in through_x:
			near(float(through_x[d]), centres.x if d else centres.y, 1e-4, "%s: the through arrow marks the lane the pods drive" % what)
	var zebras := marks.filter(func(m: Dictionary) -> bool: return m["kind"] == "zebra" and m["lane"] == "avenue")
	var crossings := 0
	for e: Array in lp.edges:
		if int(e[2]) != LifePlan.CROSS or int(e[4]) != 0:
			continue
		var pa: Vector2 = lp.nodes[int(e[0])]
		var pb: Vector2 = lp.nodes[int(e[1])]
		if not (absf(minf(pa.x, pb.x) - av.x) < 1e-3 and absf(maxf(pa.x, pb.x) - av.y) < 1e-3):
			continue
		crossings += 1
		var on_zebra := false
		for z: Dictionary in zebras:
			var zr: Rect2 = z["rect"]
			on_zebra = on_zebra or (pa.y > zr.position.y and pa.y < zr.end.y)
		check(on_zebra, "%s: the walkers' way over the main road at s %.1f is on a drawn zebra" % [what, pa.y])
	check(crossings > 0, "%s: walkers cross the spine somewhere" % what)
	check(lp.rail_edges.is_empty() == (k != CityDims.TRAM_DECK), "%s: the rail crossing rule only where there is track (%d)" % [what, lp.rail_edges.size()])
	_props(plan, lanes, marks, what)


## The street props against the paint (CityPropLayout): on the spine only trees, and only on its planted strips
## (CityDims.spine_planted: medians, verges); no prop on a stop line, zebra, hatch (tram box, nose, service end, lift
## apron), arrow, the track's swept path (+0.5 m) or the station platform (but its own lamps and benches); a tree line on
## every planted strip, the verges included on a deck without track.
func _props(plan: CityPlan, lanes: Dictionary, marks: Array, what: String) -> void:
	var items := CityPropLayout.layout(plan)
	var road := CityStreets.spine_road(plan)
	var planted := CityDims.spine_planted(plan)
	var st := CityStation.of(plan)
	var plat: Rect2 = st.get("rect", Rect2())
	var n_station := 0 if st.is_empty() else CityStation.items(st).size()
	var keep_off: Array = []      # [rect, label]
	var track_x := NAN
	for m: Dictionary in marks:
		match str(m["kind"]):
			"stop", "zebra", "hatch":
				keep_off.append([(m["rect"] as Rect2).grow(0.3), "%s %s" % [m["kind"], m.get("what", "")]])
			"arrow":
				var at: Vector2 = m["at"]
				var fwd: Vector2 = m["fwd"]
				var half := Vector2(1.2, CityStreets.ARROW_L * 0.5) if absf(fwd.y) > 0.5 else Vector2(CityStreets.ARROW_L * 0.5, 1.2)
				keep_off.append([Rect2(at - half, half * 2.0), "arrow %s" % m["glyph"]])
			"track":
				track_x = float(m["x"])
	var bad := []
	var trees_on := {}      # planted rect index -> trees on it
	for i in items.size():
		var it: Dictionary = items[i]
		if CityPropSim.is_roof(it):
			continue
		var at := Vector2(it["x"], it["s"])
		var own_station := i >= items.size() - n_station and plat.has_point(at)
		if own_station:
			continue
		for ko: Array in keep_off:
			if (ko[0] as Rect2).has_point(at):
				bad.append([it["type"], ko[1], at])
		if not is_nan(track_x) and absf(at.x - track_x) < LifeTram.CAR_W * 0.5 + 0.5 and plan.extent.has_point(at):
			bad.append([it["type"], "track", at])
		if plat.has_area() and plat.grow(0.5).has_point(at):
			bad.append([it["type"], "platform", at])
		if at.x > float(road["a"]) - EPS and at.x < float(road["b"]) + EPS:
			var on := -1
			for r in planted.size():
				if planted[r].has_point(at):
					on = r
			if it["type"] != "tree" or on < 0:
				bad.append([it["type"], "on the spine off its planted strips", at])
			else:
				trees_on[on] = int(trees_on.get(on, 0)) + 1
	eq(bad, [], "%s: no prop on the spine's paint, track or platform; on the spine only trees on the planted strips" % what)
	var bare := 0
	var verges := 0
	var verge_trees := 0
	var rail: Dictionary = lanes["rail"]
	for r in planted.size():
		var is_verge: bool = planted[r].position.x >= float(rail["a"]) - EPS and planted[r].end.x <= float(rail["b"]) + EPS
		if is_verge:
			verges += 1
			verge_trees += int(trees_on.get(r, 0))
		if int(trees_on.get(r, 0)) == 0:
			bare += 1
	eq(bare, 0, "%s: a tree line on every planted strip (%d strips)" % [what, planted.size()])
	if str(rail["kind"]) == "verge":
		check(verges > 0 and verge_trees >= verges, "%s: trees on the tram strip's verges (%d on %d)" % [what, verge_trees, verges])
	else:
		eq(verges, 0, "%s: no verge on the deck with track" % what)
