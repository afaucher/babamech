extends TestCase
## SITE FIT (docs/design/city-ramps-and-stack.md "Mission world", the fit rule; MissionProps.snap_site_fit): every flag,
## defend relay and hold zone of the default MissionPlan is reachable by the WIDEST mech, a disc of CityPlan.MECH_R_MAX +
## MissionProps.FIT_MARGIN (4.1 m), from the deck's walk graph to within 0.9 x the objective's radius of the snapped site
## (the hold: into its zone, 1 m in). Checked with this test's OWN flood (not FitMask): a 1 m grid, every cell tested
## against bucketed obstacles (court_open's: tiers and solids lower than MECH_TOP and higher than a step, pillar cores,
## park column rings, floor cuts + curb, ramps + 0.5 m, the walls) plus every mission piece on the deck (its clear radius),
## seeded from the walk graph's NODES. Also: the old rule (MissionProps.snap_site, the same chain of avoids) is computed
## beside it; the sites it put out of reach are listed (they are the ones that moved), every other site is identical to
## the old rule's, key for key. MECH_R_MAX covers every chassis in MechCatalog. Informational: per seed, how many facing
## gaps between buildings of a downtown block are wider than a Strider needs (4.4 m) but narrower than 8.2 m.

const SEEDS := [1, 2, 3, 4, 5, 6, 7, 9]
## The cases the Mech session's note found (2026-11-24) with the old rule: printed when the old rule still misses them.
const NOTE_CASES := ["4:d1_p", "6:d0_p", "7:d2_b0"]
const CELL := 1.0
const BUCKET := 8.0

var old_fail: Array[String] = []
var moved: Array[String] = []


func setup() -> void:
	timeout_sec = 600.0
	var rmax := 0.0
	for id: String in MechCatalog.CHASSIS:
		var cr := float(MechCatalog.movement(id)["capsule_radius"])
		rmax = maxf(rmax, cr)
		check(CityPlan.MECH_R_MAX >= cr, "CityPlan.MECH_R_MAX %.2f covers chassis %s (capsule radius %.2f)" % [CityPlan.MECH_R_MAX, id, cr])
	print("[SiteFit] widest chassis capsule %.2f m, MECH_R_MAX %.2f, fit disc %.2f m" % [rmax, CityPlan.MECH_R_MAX, MissionProps.fit_r()])
	var only := OS.get_environment("FIT_SEED")
	var seeds: Array = [int(only)] if only.is_valid_int() else SEEDS
	for s: int in seeds:
		await _seed(s)
	print("[SiteFit] old rule out of reach: %s" % str(old_fail))
	print("[SiteFit] moved for fit: %s" % str(moved))
	for c: String in NOTE_CASES:
		if not old_fail.has(c):
			print("[SiteFit] note case %s is reachable under the old rule now (the section changed?)" % c)
	finish()


func _seed(seed_n: int) -> void:
	var sec := SectionPlan.make({"seed": float(seed_n)})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	var plan := MissionPlan.make(sec, {})
	var mw := stack.setup_mission(plan)
	var fit_ms := []
	var site_ms := []
	for c: Array in mw.chunk_log:
		if str(c[0]).begins_with("fit "):
			fit_ms.append("%s %.1f" % [c[0], float(c[1])])
		elif str(c[0]).begins_with("site "):
			site_ms.append("%s %.1f" % [str(c[0]).substr(5), float(c[1])])
	var graph := []
	for d: CityDistrict in stack.decks:
		if MissionProps.has_fit_mask(d.plan):
			graph.append("d%d %.1f" % [d.plan.deck, MissionProps.fit_mask(d.plan).graph_ms])
	print("[SiteFit] seed %d: mask chunks (ms) %s (of which walk_graph %s); site chunks (ms) %s" % [seed_n, str(fit_ms), str(graph),
			str(site_ms)])
	# The old rule, chained as MissionWorld._site chains it (flags, then relays; each avoids the pieces before it on its deck).
	var old := {}
	for kind: String in ["flag", "defend"]:
		for o: Dictionary in plan.objectives:
			if str(o["type"]) != kind:
				continue
			var k := int(o["deck"])
			var avoid := []
			for id2: Variant in old:
				if int(old[id2]["deck"]) == k:
					avoid.append([Vector2(float(old[id2]["x"]), float(old[id2]["s"])), float(old[id2]["clear"])])
			var clear := MissionWorld.FLAG_CLEAR if kind == "flag" else MissionWorld.ASSET_CLEAR
			var r := MissionProps.snap_site(stack.decks[k], Vector2(float(o["site"]["x"]), float(o["site"]["s"])), MissionWorld.snap_reach(o),
					clear, avoid)
			r["deck"] = k
			r["clear"] = clear
			old[o["id"]] = r
	var new := {}
	for o: Dictionary in plan.objectives:
		match str(o["type"]):
			"flag": new[o["id"]] = mw.flag_site(o["id"])
			"defend": new[o["id"]] = mw.asset_site(o["id"])
	# Same or moved for fit.
	for id: Variant in old:
		var a: Dictionary = old[id]
		var b: Dictionary = new[id]
		var tag := "seed %d deck %d %s" % [seed_n, int(a["deck"]), str(id)]
		if bool(b.get("moved_for_fit", false)):
			var pa := Vector2(float(a["x"]), float(a["s"]))
			var pb := Vector2(float(b["x"]), float(b["s"]))
			moved.append("%d:%s" % [seed_n, str(id)])
			print("[SiteFit] MOVED %s: (%.0f, %.0f) -> (%.0f, %.0f), %.1f m" % [tag, pa.x, pa.y, pb.x, pb.y, pa.distance_to(pb)])
		else:
			for key: String in ["x", "s", "h", "snapped", "ok", "deck", "clear"]:
				eq(b.get(key), a.get(key), "%s: %s as the old rule" % [tag, key])
		check(bool(b.get("fit", false)), "%s: fit" % tag)
	# The independent flood, per deck, for the old pieces and the new ones.
	for k in stack.decks.size():
		var objs: Array = []
		for o: Dictionary in plan.objectives:
			if int(o["deck"]) == k and str(o["type"]) in ["flag", "defend", "hold"]:
				objs.append(o)
		if objs.is_empty():
			continue
		var dplan := stack.decks[k].plan
		for which in 2:
			var sites: Dictionary = old if which == 0 else new
			var pieces := []
			for id: Variant in sites:
				if int(sites[id]["deck"]) == k:
					pieces.append([Vector2(float(sites[id]["x"]), float(sites[id]["s"])), float(sites[id]["clear"])])
			var reach := _flood(dplan, MissionProps.fit_r(), pieces)
			for o: Dictionary in objs:
				var ok: bool
				if str(o["type"]) == "hold":
					ok = _reaches_zone(dplan, reach, ((o["params"] as Dictionary)["zone"] as Rect2).grow(-1.0))
				else:
					var st: Dictionary = sites[o["id"]]
					ok = _reaches(dplan, reach, Vector2(float(st["x"]), float(st["s"])), float(o["radius"]) * MissionProps.FIT_GOAL)
				var tag := "seed %d deck %d %s (%s %s)" % [seed_n, k, str(o["id"]), o["role"], o["type"]]
				if which == 0:
					if not ok:
						old_fail.append("%d:%s" % [seed_n, str(o["id"])])
						print("[SiteFit] old rule: %s out of reach of a %.1f m disc" % [tag, MissionProps.fit_r()])
				else:
					check(ok, "%s: a %.1f m disc reaches it from the walk graph" % [tag, MissionProps.fit_r()])
					if ok and old_fail.has("%d:%s" % [seed_n, str(o["id"])]):
						check(moved.has("%d:%s" % [seed_n, str(o["id"])]), "%s: out of reach before, so it moved" % tag)
	_gaps(seed_n, stack)
	mw.teardown(false)
	stack.queue_free()
	await frames(1)


# --- The independent flood ---------------------------------------------------------------------------------------------

## Obstacles of a plan for a disc: [[kind 0 rect / 1 disc, Rect2 or [Vector2, radius]]].
func _obstacles(p: CityPlan, pieces: Array) -> Array:
	var out := []
	for bi in p.buildings.size():
		var b: Dictionary = p.buildings[bi]
		for t: Dictionary in b["tiers"]:
			if float(t["y0"]) < CityPlan.MECH_TOP and float(t["y1"]) > CityPlan.STEP_H:
				out.append([0, p.tier_rect(bi, t)])
		for so: Dictionary in b.get("solids", []):
			if float(so["y0"]) < CityPlan.MECH_TOP and float(so["y1"]) > CityPlan.STEP_H:
				var sz: Vector2 = so["size"]
				out.append([0, Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz)])
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			out.append([0, Rect2(Vector2(float(b["core"]["x"]), float(b["core"]["s"])) - cs * 0.5, cs)])
	for col: Dictionary in p.columns:
		out.append([1, [Vector2(float(col["x"]), float(col["s"])), float(col["ring_r"])]])
	for o in p.floor_cuts():
		out.append([0, o.grow(CityStreets.HOLE_CURB)])
	for rp: Dictionary in p.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		out.append([0, Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(0.5)])
	for pc: Array in pieces:
		out.append([1, pc])
	return out


static func _dist(ob: Array, pt: Vector2) -> float:
	if int(ob[0]) == 1:
		return (ob[1][0] as Vector2).distance_to(pt) - float(ob[1][1])
	var q: Rect2 = ob[1]
	var dx := maxf(maxf(q.position.x - pt.x, pt.x - q.end.x), 0.0)
	var dy := maxf(maxf(q.position.y - pt.y, pt.y - q.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)


static func _bounds(ob: Array) -> Rect2:
	if int(ob[0]) == 1:
		var rr := float(ob[1][1])
		return Rect2(ob[1][0] - Vector2(rr, rr), Vector2(rr, rr) * 2.0)
	return ob[1]


## {nx, ns, origin, reach: PackedByteArray}: the cells a disc of radius r reaches from the walk graph's nodes.
func _flood(p: CityPlan, r: float, pieces: Array) -> Dictionary:
	var obs := _obstacles(p, pieces)
	var buckets := {}
	for i in obs.size():
		var bb := _bounds(obs[i]).grow(r)
		for bx in range(floori(bb.position.x / BUCKET), floori(bb.end.x / BUCKET) + 1):
			for by in range(floori(bb.position.y / BUCKET), floori(bb.end.y / BUCKET) + 1):
				(buckets.get_or_add(Vector2i(bx, by), []) as Array).append(i)
	var e := p.extent
	var nx := int(ceilf(e.size.x / CELL))
	var ns := int(ceilf(e.size.y / CELL))
	var inner := e.grow(-r)
	var state := PackedByteArray()   # 0 unknown, 1 free, 2 blocked, 3 reached
	state.resize(nx * ns)
	var is_free := func(c: int) -> bool:
		if state[c] != 0:
			return state[c] != 2
		var pt := e.position + Vector2(float(c % nx) + 0.5, float(c / nx) + 0.5) * CELL
		var ok := inner.has_point(pt)
		if ok:
			for i: int in buckets.get(Vector2i(floori(pt.x / BUCKET), floori(pt.y / BUCKET)), []):
				if _dist(obs[i], pt) < r:
					ok = false
					break
		state[c] = 1 if ok else 2
		return ok
	var q := PackedInt32Array()
	var g := p.walk_graph()
	for nd: Vector2 in g["nodes"]:
		var i := floori((nd.x - e.position.x) / CELL)
		var j := floori((nd.y - e.position.y) / CELL)
		if i < 0 or j < 0 or i >= nx or j >= ns:
			continue
		var c := j * nx + i
		if is_free.call(c) and state[c] != 3:
			state[c] = 3
			q.append(c)
	var head := 0
	while head < q.size():
		var c := q[head]
		head += 1
		var i := c % nx
		var j := c / nx
		for nb: Vector2i in [Vector2i(i - 1, j), Vector2i(i + 1, j), Vector2i(i, j - 1), Vector2i(i, j + 1)]:
			if nb.x < 0 or nb.y < 0 or nb.x >= nx or nb.y >= ns:
				continue
			var n := nb.y * nx + nb.x
			if state[n] == 3 or not is_free.call(n):
				continue
			state[n] = 3
			q.append(n)
	return {"nx": nx, "ns": ns, "origin": e.position, "state": state}


func _reaches(_p: CityPlan, f: Dictionary, at: Vector2, goal_r: float) -> bool:
	var nx := int(f["nx"])
	var ns := int(f["ns"])
	var o: Vector2 = f["origin"]
	var st: PackedByteArray = f["state"]
	var n := int(ceilf(goal_r / CELL)) + 1
	var ci := floori((at.x - o.x) / CELL)
	var cj := floori((at.y - o.y) / CELL)
	for j in range(cj - n, cj + n + 1):
		for i in range(ci - n, ci + n + 1):
			if i < 0 or j < 0 or i >= nx or j >= ns:
				continue
			if st[j * nx + i] == 3 and (o + Vector2(float(i) + 0.5, float(j) + 0.5) * CELL).distance_to(at) <= goal_r:
				return true
	return false


func _reaches_zone(_p: CityPlan, f: Dictionary, z: Rect2) -> bool:
	var nx := int(f["nx"])
	var o: Vector2 = f["origin"]
	var st: PackedByteArray = f["state"]
	for c in st.size():
		if st[c] == 3 and z.has_point(o + Vector2(float(c % nx) + 0.5, float(c / nx) + 0.5) * CELL):
			return true
	return false


# --- Information: narrow gaps in downtown blocks -------------------------------------------------------------------------

## Facing gaps (projections overlapping by >= 2 m) between low tiers of two different buildings in the same downtown block,
## wider than 2 x MECH_R + 0 (4.4 m) and narrower than 2 x fit_r() (8.2 m). Printed, not checked.
func _gaps(seed_n: int, stack: CityStack) -> void:
	var lo := 2.0 * CityPlan.MECH_R
	var hi := 2.0 * MissionProps.fit_r()
	var total := 0
	var parts: Array[String] = []
	for k in stack.decks.size():
		var p := stack.decks[k].plan
		var n := 0
		for bi: int in p.downtown_blocks():
			var rects := []      # [building, Rect2]
			for i: int in p.buildings_in(bi):
				for t: Dictionary in p.buildings[i]["tiers"]:
					if float(t["y0"]) < CityPlan.MECH_TOP and float(t["y1"]) > CityPlan.STEP_H:
						rects.append([i, p.tier_rect(i, t)])
			var pairs := {}
			for a in rects.size():
				for b in range(a + 1, rects.size()):
					if int(rects[a][0]) == int(rects[b][0]):
						continue
					var ra: Rect2 = rects[a][1]
					var rb: Rect2 = rects[b][1]
					var ox := minf(ra.end.x, rb.end.x) - maxf(ra.position.x, rb.position.x)
					var os := minf(ra.end.y, rb.end.y) - maxf(ra.position.y, rb.position.y)
					var gap := INF
					if ox >= 2.0 and os < 0.0:
						gap = -os
					elif os >= 2.0 and ox < 0.0:
						gap = -ox
					if gap > lo and gap < hi:
						pairs[Vector2i(mini(int(rects[a][0]), int(rects[b][0])), maxi(int(rects[a][0]), int(rects[b][0])))] = gap
			n += pairs.size()
		total += n
		parts.append("d%d %d" % [k, n])
	print("[SiteFit] seed %d: downtown building pairs with a facing gap %.1f..%.1f m: %d (%s)" % [seed_n, lo, hi, total, ", ".join(parts)])
