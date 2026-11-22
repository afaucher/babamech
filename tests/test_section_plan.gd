extends TestCase
## SectionPlan (docs/design/mission-section.md): deterministic and checksummed; a route from the entry to the lowest
## deck for vehicles AND for mechs; pillars line up between decks; every cell is reachable; no connection sits in a
## pillar it isn't housed in; the planner holds up across seeds and at the ends of every setting.

const SETTINGS := [
	{}, {"decks": 2.0}, {"decks": 5.0}, {"arc": 300.0}, {"arc": 900.0}, {"width": 160.0}, {"width": 450.0},
	{"radius": 150.0}, {"radius": 600.0}, {"cell": 60.0}, {"cell": 140.0}, {"ramp_grade": 0.08}, {"ramp_grade": 0.35},
	{"shafts": 0.0}, {"shafts": 3.0}, {"express": 0.0}, {"w_urban": 0.0, "w_park": 0.0, "w_industrial": 0.0},
	{"w_park": 2.0}, {"w_industrial": 2.0}, {"decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0},
	{"radius": 150.0, "decks": 5.0},     # small radius, many decks: lower decks much longer than the top one
]


func setup() -> void:
	_determinism()
	var kinds := {}
	var shafts := 0
	for seed_ in range(1, 41):
		var plan := SectionPlan.make({"seed": float(seed_)})
		_check_plan(plan, "seed %d" % seed_)
		for c: Dictionary in plan.connectors:
			kinds[c["kind"]] = true
			if c["kind"] == "shaft":
				shafts += 1
	for id: String in ["ramp", "lift", "shaft"]:
		check(kinds.has(id), "some seed uses a " + id)
	check(shafts >= 40 * 2, "default sections get a shaft on every deck but the lowest (%d over 40 seeds)" % shafts)
	for i in SETTINGS.size():
		for seed_ in [3, 11, 29]:
			var o: Dictionary = (SETTINGS[i] as Dictionary).duplicate()
			o["seed"] = float(seed_)
			_check_plan(SectionPlan.make(o), "settings %d seed %d" % [i, seed_])
	_deck_views()
	_geometry()
	finish()


func _determinism() -> void:
	var a := SectionPlan.make({"seed": 7.0})
	var b := SectionPlan.make({"seed": 7.0})
	eq(a.checksum(), b.checksum(), "same seed, same plan")
	eq(str(a.decks), str(b.decks), "same seed, same zones")
	eq(str(a.connectors), str(b.connectors), "same seed, same connectors")
	b.generate({"seed": 8.0})
	check(a.checksum() != b.checksum(), "another seed, another plan")
	b.generate({"seed": 7.0})
	eq(a.checksum(), b.checksum(), "regenerating in place gives the same plan")
	var sums := {}
	for seed_ in range(1, 41):
		sums[SectionPlan.make({"seed": float(seed_)}).checksum()] = true
	check(sums.size() >= 38, "seeds give different sections (%d of 40)" % sums.size())
	check(SectionPlan.make({"seed": 7.0, "w_park": 1.5}).checksum() != a.checksum(), "the zone mix changes the plan")


func _check_plan(plan: SectionPlan, tag: String) -> void:
	var n := plan.deck_count
	check(n >= 2 and plan.cols >= 2 and plan.rows >= 4, tag + ": grid")
	# --- Routes: vehicles (roads, ramps, lifts; the locked express lift not needed) and mechs.
	var road := SectionPlan.walk(plan.road_graph(false), plan.entry_node())
	check(float(road["dist"][plan.extraction_node()]) < INF, tag + ": vehicles can drive from the entry to the extraction")
	for k in n:
		check(float(road["dist"][plan.node_id(k, plan.spine_line, plan.rows / 2)]) < INF, tag + ": vehicles reach deck %d" % k)
	var back := SectionPlan.walk(plan.road_graph(false), plan.extraction_node())
	check(float(back["dist"][plan.entry_node()]) < INF, tag + ": vehicles can drive back up")
	var mech := SectionPlan.walk(plan.mech_graph(false), plan.entry_cell())
	check(float(mech["dist"][plan.extraction_cell()]) < INF, tag + ": mechs can reach the extraction")
	# Every zone cell is reachable by a mech, and borders a road crossing a vehicle can reach.
	for k in n:
		for r in plan.rows:
			for c in plan.cols:
				check(float(mech["dist"][plan.cell_id(k, c, r)]) < INF, "%s: cell %d/%d,%d reachable by mechs" % [tag, k, c, r])
				var any := false
				for corner: Vector2i in [Vector2i(c, r), Vector2i(c + 1, r), Vector2i(c, r + 1), Vector2i(c + 1, r + 1)]:
					any = any or float(road["dist"][plan.node_id(k, corner.x, corner.y)]) < INF
				check(any, "%s: cell %d/%d,%d has road access" % [tag, k, c, r])
				check(plan.zone(k, c, r) in SectionPlan.ZONES, "%s: cell %d/%d,%d has a zone" % [tag, k, c, r])
	check(not (plan.route["vehicle"] as Array).is_empty() and not (plan.route["mech"] as Array).is_empty(), tag + ": routes recorded")
	eq(int(plan.route["vehicle"][0]["deck"]), 0, tag + ": the route starts on the top deck")
	eq(int(plan.route["vehicle"][-1]["deck"]), n - 1, tag + ": the route ends on the lowest deck")
	check(float(plan.route["mech_len"]) <= float(plan.route["vehicle_len"]) * 1.5, tag + ": the mech route is no detour")
	# One vehicle connection per deck transition is critical and unlocked.
	for k in n - 1:
		var found := false
		for c: Dictionary in plan.connectors:
			if c["role"] == "critical" and c["vehicles"] and not c["locked"] and int(c["from"]) <= k and int(c["to"]) >= k + 1:
				found = true
		check(found, "%s: a critical vehicle connection from deck %d down" % [tag, k])
	# --- Pillars: one column through every deck (same angle, same x), inside its cell on every deck, never in a road.
	var seen := {}
	for id in plan.pillars.size():
		var q: Dictionary = plan.pillars[id]
		eq(plan.pillar_at(q["col"], q["row"]), id, tag + ": pillar lookup")
		check(not seen.has(Vector2i(q["col"], q["row"])), tag + ": one pillar per cell")
		seen[Vector2i(q["col"], q["row"])] = true
		for k in n:
			var pt := plan.pillar_point(k, id)
			near(pt.y / plan.radius_of(k), float(q["theta"]), 1e-6, tag + ": pillar %d at the same angle on deck %d" % [id, k])
			near(pt.x, float(q["x"]), 1e-3, tag + ": pillar %d at the same x on deck %d" % [id, k])
			var rad := plan.pillar_radius(k, id)
			var cell := plan.cell_rect(k, q["col"], q["row"])
			check(cell.encloses(Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0)),
					"%s: pillar %d (%s) inside its cell on deck %d" % [tag, id, plan.pillar_style(k, id), k])
			# Stacked pillars meet: the one below ends at this deck's slab right under this one.
			if k + 1 < n:
				var top_of_lower := plan.to_world(k + 1, pt.x, plan.pillar_point(k + 1, id).y, plan.clear_height())
				var foot := plan.to_world(k, pt.x, pt.y, -plan.p("slab"))
				check(top_of_lower.distance_to(foot) < 0.001, tag + ": pillar %d stacks from deck %d to %d" % [id, k + 1, k])
	# Long-span bays (no pillar) never share an edge, and only exist under / over shafts.
	for r in plan.rows:
		for c in plan.cols:
			if plan.pillar_at(c, r) >= 0:
				continue
			check(c + 1 >= plan.cols or plan.pillar_at(c + 1, r) >= 0, "%s: long-span bays %d,%d don't touch" % [tag, c, r])
			check(r + 1 >= plan.rows or plan.pillar_at(c, r + 1) >= 0, "%s: long-span bays %d,%d don't touch" % [tag, c, r])
			var has_shaft := false
			for cn: Dictionary in plan.connectors:
				has_shaft = has_shaft or (cn["kind"] == "shaft" and int(cn["col"]) == c and int(cn["row"]) == r)
			check(has_shaft, "%s: bay %d,%d without a pillar has a shaft" % [tag, c, r])
	# --- Connections: clear of every pillar they aren't housed in, on every deck they touch; holes stay off the roads.
	for ci in plan.connectors.size():
		var cn: Dictionary = plan.connectors[ci]
		check(int(cn["to"]) > int(cn["from"]) and int(cn["from"]) >= 0 and int(cn["to"]) < n, tag + ": connector decks")
		for k: int in cn["stops"]:
			var rect := plan.connector_rect(ci, k)
			check(rect.size.x > 1.0 and rect.size.y > 1.0, tag + ": connector %d has a footprint" % ci)
			check(absf(rect.get_center().y) + rect.size.y * 0.5 <= plan.arc_of(k) * 0.5 + 0.01, tag + ": connector %d inside the section" % ci)
			for id in plan.pillars.size():
				if id == int(cn["pillar"]):
					continue
				var pt := plan.pillar_point(k, id)
				var rad := plan.pillar_radius(k, id) + SectionPlan.CONNECT_CLEAR
				check(not rect.intersects(Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0)),
						"%s: %s %d clear of pillar %d on deck %d" % [tag, cn["kind"], ci, id, k])
		match str(cn["kind"]):
			"lift":
				check(int(cn["pillar"]) >= 0 and plan.pillars[int(cn["pillar"])]["lift"], tag + ": a lift rides in a lift pillar")
				var st: Array = cn["stops"]
				eq(st, range(int(cn["from"]), int(cn["to"]) + 1), tag + ": lift %d stops on every deck from..to" % ci)
				eq(int(cn["top"]["deck"]), int(st[0]), tag + ": lift %d top is its first stop" % ci)
				eq(int(cn["bottom"]["deck"]), int(st[-1]), tag + ": lift %d bottom is its last stop" % ci)
				for k: int in st:
					eq(plan.zone(k, cn["col"], cn["row"]), "transit", tag + ": a lift stop is a transit cell")
					eq(plan.pillar_style(k, int(cn["pillar"])), "lift", tag + ": lift pillar style")
					# The platform: the same square on every stop, centred in its pillar and inside its footprint.
					var pid := int(cn["pillar"])
					var rect := plan.connector_rect(ci, k)
					var at := plan.pillar_point(k, pid)
					near(rect.size.x, SectionPlan.LIFT_PLATFORM, 0.01, tag + ": lift %d platform width on deck %d" % [ci, k])
					near(rect.size.y, SectionPlan.LIFT_PLATFORM, 0.01, tag + ": lift %d platform length on deck %d" % [ci, k])
					check(rect.get_center().distance_to(at) < 0.01, tag + ": lift %d platform centred on its pillar on deck %d" % [ci, k])
					var half := plan.pillar_radius(k, pid)
					check(Rect2(at.x - half, at.y - half, half * 2.0, half * 2.0).grow(0.01).encloses(rect),
							tag + ": lift %d platform inside its pillar on deck %d" % [ci, k])
			"shaft":
				eq(plan.zone(cn["from"], cn["col"], cn["row"]), "open", tag + ": a shaft is cut in an open-air cell")
				check(plan.zone(cn["to"], cn["col"], cn["row"]) in ["park", "open"], tag + ": a shaft lands on open ground")
				check(plan.cell_rect(cn["from"], cn["col"], cn["row"]).encloses(plan.connector_rect(ci, cn["from"])), tag + ": shaft inside its cell")
				check(not cn["vehicles"] and not cn["two_way"], tag + ": a shaft is a one-way drop for mechs")
			"ramp":
				var lane := plan.lane_x(cn["lane"])
				near(float(cn["x0"]), lane.x, 0.001, tag + ": ramp in its spine lane")
				var length := (float(cn["theta1"]) - float(cn["theta0"])) * plan.radius_of(int(cn["from"]))
				check(plan.p("pitch") / length <= plan.p("ramp_grade") + 0.0001, tag + ": ramp no steeper than the grade (%.3f)" % (plan.p("pitch") / length))
				eq(plan.zone(cn["from"], cn["col"], cn["row"]), "transit", tag + ": ramp head is a transit cell")
				eq(plan.zone(cn["to"], cn["col"], cn["foot_row"]), "transit", tag + ": ramp foot is a transit cell")
	# Two ramps never share a lane on one deck.
	for a in plan.connectors.size():
		for b in range(a + 1, plan.connectors.size()):
			var ca: Dictionary = plan.connectors[a]
			var cb: Dictionary = plan.connectors[b]
			if ca["kind"] != "ramp" or cb["kind"] != "ramp":
				continue
			for k in n:
				if (ca["stops"] as Array).has(k) and (cb["stops"] as Array).has(k):
					check(not plan.connector_rect(a, k).intersects(plan.connector_rect(b, k)), tag + ": ramps %d and %d apart on deck %d" % [a, b, k])
	# --- Ends, regions, hooks.
	eq(plan.zone(0, plan.entry["col"], plan.entry["row"]), "transit", tag + ": the entry is a station")
	eq(plan.zone(n - 1, plan.extraction["col"], plan.extraction["row"]), "transit", tag + ": the extraction is a station")
	for k in n:
		var cells := 0
		for reg: Dictionary in plan.decks[k]["regions"]:
			cells += (reg["cells"] as Array).size()
			for cell: Vector2i in reg["cells"]:
				eq(plan.zone(k, cell.x, cell.y), str(reg["kind"]), tag + ": region kind")
				check((reg["rect"] as Rect2).grow(0.01).encloses(plan.cell_rect(k, cell.x, cell.y)), tag + ": region bounds")
		eq(cells, plan.cols * plan.rows, tag + ": regions cover deck %d" % k)
		if plan.p("w_park") > 0.001:
			var parks := 0
			for row: Array in plan.decks[k]["zones"]:
				parks += row.count("park")
			check(parks >= 1, tag + ": deck %d has a park" % k)
	# --- Boundaries: four walls a deck; the crew's portals are gates in bulkheads on the spine; gates sit on road lines.
	eq(plan.boundaries.size(), n * 4, tag + ": four walls on every deck")
	var portals := {}
	for k in n:
		for edge in SectionPlan.EDGES:
			var b := plan.boundary(k, edge)
			eq(int(b["deck"]), k, tag + ": boundary deck")
			eq(str(b["edge"]), edge, tag + ": boundary edge")
			check(b["kind"] in ["bulkhead", "window"], tag + ": boundary kind")
			eq(bool(b["backdrop"]), b["kind"] == "window", tag + ": a window wall shows the ring beyond")
			var wall := plan.boundary_rect(k, edge)
			var inside := Rect2(-plan.p("width") * 0.5, -plan.arc_of(k) * 0.5, plan.p("width"), plan.arc_of(k))
			check(not wall.grow(-0.01).intersects(inside), tag + ": wall %s outside the section's ground" % edge)
			for g: Dictionary in b["gates"]:
				check(g["kind"] in ["portal", "blast_door", "collapsed"], tag + ": gate kind")
				eq(str(g["axis"]), "s" if edge.begins_with("s") else "x", tag + ": a gate is where a road meets the wall")
				check(int(g["line"]) >= 1 and int(g["line"]) < (plan.cols if g["axis"] == "s" else plan.rows), tag + ": gate on a road line")
				check(wall.grow(0.01).has_point(Vector2(float(g["x"]), float(g["s"]))), tag + ": gate in wall %s" % edge)
				if g["kind"] == "portal":
					portals[g["role"]] = [k, edge]
					eq(str(b["kind"]), "bulkhead", tag + ": a portal is a gate in a bulkhead")
					eq(int(g["line"]), plan.spine_line, tag + ": a portal is on the spine")
				else:
					eq(str(g["role"]), "", tag + ": only portals have a role")
	eq(portals.size(), 2, tag + ": one entry portal and one extraction portal")
	eq(portals.get("entry"), [0, "s0"], tag + ": the entry portal is in the top deck's wall")
	eq(portals.get("extraction"), [n - 1, "s1" if int(plan.extraction["j"]) > 0 else "s0"], tag + ": the extraction portal")
	var checkpoints := 0
	for h: Dictionary in plan.hooks:
		check(int(h["deck"]) >= 0 and int(h["deck"]) < n, tag + ": hook deck")
		check(absf(float(h["x"])) <= plan.p("width") * 0.5 and absf(float(h["s"])) <= plan.arc_of(int(h["deck"])) * 0.5, tag + ": hook inside the section")
		if h["kind"] == "checkpoint" and h["size"] == "heavy":
			checkpoints += 1
	check(checkpoints >= n - 1, tag + ": a heavy checkpoint at every way down")


## deck_view: read-only, consistent with the plan's own helpers, and blocks + road strips tile each deck's ground.
func _deck_views() -> void:
	var cases := []
	for seed_ in range(1, 9):
		cases.append({"seed": float(seed_)})
	cases.append({"decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0, "seed": 11.0})
	for o: Dictionary in cases:
		var plan := SectionPlan.make(o)
		var views := []
		for k in plan.deck_count:
			var tag := "view %s deck %d" % [str(o), k]
			var sum := plan.checksum()
			var v := plan.deck_view(k)
			eq(plan.checksum(), sum, tag + ": deck_view leaves the plan alone")
			eq(str(plan.deck_view(k)), str(v), tag + ": deck_view is repeatable")
			views.append(v)
			_check_view(plan, k, v, tag)
		# Ceiling openings: the deck above's holes, at the same x and the same angles.
		eq((views[0]["ceiling_openings"] as Array).size(), 0, "view %s: the top deck has no ceiling openings" % str(o))
		for k in plan.deck_count - 1:
			var holes := []
			for cn: Dictionary in views[k]["connectors"]:
				if cn["part"] == "hole":
					holes.append(cn)
			var openings: Array = views[k + 1]["ceiling_openings"]
			eq(openings.size(), holes.size(), "view %s: deck %d's holes open deck %d's ceiling" % [str(o), k, k + 1])
			for n in mini(openings.size(), holes.size()):
				var h: Rect2 = holes[n]["rect"]
				var op: Rect2 = openings[n]["rect"]
				eq(int(openings[n]["connector"]), int(holes[n]["id"]), "view %s: opening %d matches its hole" % [str(o), n])
				near(op.position.x, h.position.x, 1e-3, "view %s: opening %d x0" % [str(o), n])
				near(op.end.x, h.end.x, 1e-3, "view %s: opening %d x1" % [str(o), n])
				near(op.position.y / plan.radius_of(k + 1), h.position.y / plan.radius_of(k), 1e-4, "view %s: opening %d theta0" % [str(o), n])
				near(op.end.y / plan.radius_of(k + 1), h.end.y / plan.radius_of(k), 1e-4, "view %s: opening %d theta1" % [str(o), n])


func _check_view(plan: SectionPlan, k: int, v: Dictionary, tag: String) -> void:
	var extent: Rect2 = v["extent"]
	near(extent.size.y, plan.arc_of(k), 1e-3, tag + ": extent spans the arc")
	near(extent.size.x, plan.p("width"), 1e-3, tag + ": extent spans the width")
	# --- Blocks.
	var blocks: Array = v["blocks"]
	eq(blocks.size(), plan.cols * plan.rows, tag + ": one block per cell")
	var regions: Array = plan.decks[k]["regions"]
	for b: Dictionary in blocks:
		var c := int(b["col"])
		var r := int(b["row"])
		eq(blocks[r * plan.cols + c], b, tag + ": blocks are row-major")
		eq(b["rect"], plan.cell_rect(k, c, r), tag + ": block rect is the cell")
		eq(str(b["zone"]), plan.zone(k, c, r), tag + ": block zone")
		var ri := int(b["region"])
		check(ri >= 0 and ri < regions.size(), tag + ": block %d,%d has a region" % [c, r])
		if ri >= 0 and ri < regions.size():
			check((regions[ri]["cells"] as Array).has(Vector2i(c, r)), tag + ": block %d,%d is in its region" % [c, r])
			eq(str(regions[ri]["kind"]), str(b["zone"]), tag + ": region kind is the block's zone")
		eq(int(b["pillar"]), plan.pillar_at(c, r), tag + ": block pillar")
	# --- Road strips: inside the ground, off every block, and with the blocks they cover it all.
	var strips: Array = v["road_strips"]
	for st: Dictionary in strips:
		var sr: Rect2 = st["rect"]
		check(extent.grow(0.01).encloses(sr), tag + ": strip %s %d inside the extent" % [st["kind"], st["line"]])
		for b: Dictionary in blocks:
			check(not sr.grow(-0.01).intersects((b["rect"] as Rect2).grow(-0.01)),
					"%s: strip %s %d off block %d,%d" % [tag, st["kind"], st["line"], b["col"], b["row"]])
	# Sample the ground every 7 m, offset so no point lands on an edge. Messages only built on failure (thousands of points).
	var block_rects: Array[Rect2] = []
	for b: Dictionary in blocks:
		block_rects.append(b["rect"])
	var strip_rects: Array[Rect2] = []
	for st: Dictionary in strips:
		strip_rects.append(st["rect"])
	var bad := 0
	var x := extent.position.x + 0.37
	while x < extent.end.x:
		var s := extent.position.y + 0.53
		while s < extent.end.y:
			var pt := Vector2(x, s)
			var in_blocks := 0
			for br in block_rects:
				if br.has_point(pt):
					in_blocks += 1
			var on_road := false
			for sr in strip_rects:
				if sr.has_point(pt):
					on_road = true
					break
			if not ((in_blocks == 1) != on_road and in_blocks <= 1):
				bad += 1
				if bad <= 5:
					check(false, "%s: %s is in one block or on a road (%d, %s)" % [tag, str(pt), in_blocks, on_road])
			s += 7.0
		x += 7.0
	eq(bad, 0, tag + ": blocks and road strips tile the ground")
	# The spine's lanes sit side by side, west to east, and fill the spine.
	var lanes := []
	for st: Dictionary in strips:
		if st["axis"] == "s" and int(st["line"]) == plan.spine_line:
			lanes.append(st)
	eq(lanes.size(), SectionPlan.SPINE_LANES.size(), tag + ": one strip per spine lane")
	if lanes.size() == SectionPlan.SPINE_LANES.size():
		for n in lanes.size():
			eq(str(lanes[n]["lane"]), str(SectionPlan.SPINE_LANES[n][0]), tag + ": spine lanes in order")
			if n > 0:
				near((lanes[n]["rect"] as Rect2).position.x, (lanes[n - 1]["rect"] as Rect2).end.x, 1e-3, tag + ": spine lanes adjacent")
		near((lanes[-1]["rect"] as Rect2).end.x - (lanes[0]["rect"] as Rect2).position.x, SectionPlan.SPINE_W, 1e-3, tag + ": spine lanes span the spine")
	# --- Pillars.
	var pils: Array = v["pillars"]
	eq(pils.size(), plan.pillars.size(), tag + ": every pillar")
	for q: Dictionary in pils:
		var half := float(q["half"])
		var cell: Rect2 = blocks[int(q["row"]) * plan.cols + int(q["col"])]["rect"]
		check(cell.encloses(Rect2(float(q["x"]) - half, float(q["s"]) - half, half * 2.0, half * 2.0)), tag + ": pillar %d inside its block" % q["id"])
		eq(bool(q["lift"]), q["kind"] == "lift", tag + ": pillar %d lift flag" % q["id"])
	# --- Connectors.
	var stops := {}
	for cn: Dictionary in v["connectors"]:
		if cn["part"] == "hole":
			check(plan.is_hole(int(cn["id"]), k), tag + ": hole %d cuts this floor" % cn["id"])
		if cn["part"] == "stop":
			stops[int(cn["id"])] = true
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		if c["kind"] == "lift" and (c["stops"] as Array).has(k):
			check(stops.has(ci), tag + ": lift %d stops here" % ci)
	# --- Walls.
	var walls: Array = v["walls"]
	eq(walls.size(), 4, tag + ": four walls")
	for n in mini(walls.size(), 4):
		var edge := SectionPlan.EDGES[n]
		var b := plan.boundary(k, edge)
		eq(str(walls[n]["edge"]), edge, tag + ": walls in EDGES order")
		eq(walls[n]["rect"], plan.boundary_rect(k, edge), tag + ": wall %s rect" % edge)
		eq(str(walls[n]["kind"]), str(b["kind"]), tag + ": wall %s kind" % edge)
		eq(bool(walls[n]["backdrop"]), bool(b["backdrop"]), tag + ": wall %s backdrop" % edge)
		eq(str(walls[n]["gates"]), str(b["gates"]), tag + ": wall %s gates" % edge)


func _geometry() -> void:
	var plan := SectionPlan.make({"seed": 5.0})
	near(plan.clear_height(), 40.0, 0.001, "40 m from floor to ceiling by default")
	near(plan.to_world(plan.deck_count - 1, 0.0, 0.0, 0.0).length(), 0.0, 0.001, "the lowest deck's floor passes through the origin")
	for k in plan.deck_count:
		var ring := plan.ring(k)
		for s in [-120.0, 0.0, 77.0]:
			var a := plan.to_world(k, 12.0, s, 3.0)
			var b := ring.arc_to_world(12.0, s, 3.0) + plan.deck_offset(k)
			check(a.distance_to(b) < 0.001, "to_world matches RingFrame + deck_offset on deck %d" % k)
		near(plan.arc_of(k), plan.span * plan.radius_of(k), 0.001, "lower decks are longer")
		# Cells sit between their roads and never overlap.
		for r in plan.rows:
			for c in plan.cols:
				var rect := plan.cell_rect(k, c, r)
				check(rect.size.x > 20.0 and rect.size.y > 20.0, "cell %d,%d has room (%s)" % [c, r, str(rect.size)])
				if c + 1 < plan.cols:
					check(plan.cell_rect(k, c + 1, r).position.x - rect.end.x >= SectionPlan.ARTERIAL_W - 0.01, "a road between columns")
				if r + 1 < plan.rows:
					check(plan.cell_rect(k, c, r + 1).position.y - rect.end.y >= SectionPlan.ARTERIAL_W - 0.01, "a road between rows")
	var lanes := 0.0
	for l: Array in SectionPlan.SPINE_LANES:
		lanes += float(l[1])
	near(lanes, SectionPlan.SPINE_W, 0.001, "the spine's lanes add up")
	# The top of deck k+1's space is the underside of deck k.
	var under := plan.to_world(0, 0.0, 0.0, -plan.p("slab"))
	var ceil_ := plan.to_world(1, 0.0, 0.0, plan.clear_height())
	check(under.distance_to(ceil_) < 0.001, "deck 1's ceiling is deck 0's underside")
