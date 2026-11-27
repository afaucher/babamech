class_name CityGraphs
extends RefCounted
## Road and walk graphs of a finished CityPlan (docs/design/city-variety.md "Graphs"): read-only views built from the
## plan's data after generation. Static: no state, draws nothing from the seed, so nothing here is in the plan checksum.

## Road centre-line graph: a node at every crossing, an edge along every road between neighbouring crossings.
## No edge crosses a floor cut (a cross road that does not bridge a ramp's cut, CityPlan.bridge_allowed); an edge may
## run along a cut's edge (the road at a ramp's mouth). Returns {nodes: [Vector2], edges: [[i, j]]}.
static func road_graph(plan: CityPlan) -> Dictionary:
	var g := _grid_graph(plan)
	if not plan.forms.is_empty():
		# Pedestrian streets and superblocks are no roads (SectionPlan.road_graph drops the same segments).
		var ns := plan.roads_s.size()
		var drive := []
		for ed: Array in g["edges"]:
			var a := int(ed[0])
			var b := int(ed[1])
			var ok := plan.seg_drives("s", a / ns, a % ns) if b == a + 1 else plan.seg_drives("x", a % ns, a / ns)
			if ok:
				drive.append(ed)
		g["edges"] = drive
	if plan.site == null or plan.site.floor_holes.is_empty():
		return g
	var cuts := plan.floor_cuts()
	var kept := []
	for ed: Array in g["edges"]:
		var p: Vector2 = g["nodes"][int(ed[0])]
		var q: Vector2 = g["nodes"][int(ed[1])]
		var lo := Vector2(minf(p.x, q.x), minf(p.y, q.y))
		var hi := Vector2(maxf(p.x, q.x), maxf(p.y, q.y))
		var blocked := false
		for o in cuts:
			var inner := o.grow(-0.5)
			if lo.x < inner.end.x and hi.x > inner.position.x and lo.y < inner.end.y and hi.y > inner.position.y:
				blocked = true
				break
		if not blocked:
			kept.append(ed)
	g["edges"] = kept
	return g


## WALK graph (docs/design/city-variety.md "Graphs"): where a MECH (or an enemy, or the bot) can go along the roads, as
## opposed to road_graph(), which is where VEHICLES go. Same shape as road_graph() and a drop-in for its consumers: the
## same `nodes` (same ids, same positions: node i * ns + j is the crossing of roads_x[i] and roads_s[j]) and `edges`
## [[i, j]], plus one key:
##   forms   {Vector2i(min(i, j), max(i, j)): form} for every edge: "street" | "lane" | "pedestrian" | "none" | "alley"
## Edges: every road_graph() edge first, in its order (each keeps its own form, street or lane); then every pedestrian
## segment, then every superblock ("none") segment whose court the mech capsule can cross from one end crossing to the
## other (court_open: from plan data), grid order. Never an edge across a floor cut (the same test road_graph() uses,
## which also covers a ramp's removed bridge: floor_cuts()). On a plan with no forms walk_graph() == road_graph() plus
## the `forms` key.
## `with_alleys`: each service alley adds a node at each of its two mouths, on the centre line of the road it opens onto,
## level with the alley's centre line; that road's edge is split there (its halves keep the road's form) and an edge
## "alley" runs mouth to mouth through the alley. Mouth node ids follow the grid's (from nx * ns up), in plan.alleys
## order, the alley's low-side mouth first (-x for an alley along x, -s for one along s); a mouth within 1 m of another on
## the same road (two alleys lined up across it) shares that node. Existing ids never change.
static func walk_graph(plan: CityPlan, with_alleys: bool = false) -> Dictionary:
	var g := road_graph(plan)
	var edges: Array = (g["edges"] as Array).duplicate()
	var nodes: Array[Vector2] = []
	nodes.assign(g["nodes"])
	var ns := plan.roads_s.size()
	var forms_of := {}
	var have := {}
	for ed: Array in edges:
		var a := int(ed[0])
		var b := int(ed[1])
		var key := Vector2i(mini(a, b), maxi(a, b))
		have[key] = true
		forms_of[key] = plan.seg_form("s", a / ns, a % ns) if absi(b - a) == 1 else plan.seg_form("x", a % ns, mini(a, b) / ns)
	if not plan.forms.is_empty():
		var cuts: Array[Rect2] = plan.floor_cuts() if plan.site != null else ([] as Array[Rect2])
		var grid := _grid_graph(plan)
		for want: String in ["pedestrian", "none"]:
			for ed: Array in grid["edges"]:
				var a := int(ed[0])
				var b := int(ed[1])
				var key := Vector2i(a, b)
				if have.has(key):
					continue
				var axis := "s" if b == a + 1 else "x"
				var line := a / ns if axis == "s" else a % ns
				var index := a % ns if axis == "s" else a / ns
				if plan.seg_form(axis, line, index) != want:
					continue
				if want == "none" and not court_open(plan, axis, line, index):
					continue
				if crosses_cut(nodes[a], nodes[b], cuts):
					continue
				edges.append([a, b])
				have[key] = true
				forms_of[key] = want
	g["edges"] = edges
	g["forms"] = forms_of
	if with_alleys and not plan.alleys.is_empty():
		_walk_alleys(plan, g)
	return g


## A superblock's court (segment `axis` / `line` / `index`, form none) lets the mech capsule (radius MECH_R, MECH_TOP
## tall) cross it from one end crossing to the other, decided from plan data: the corridor along the segment's centre line
## (MECH_R either side) is inside the strip with WALK_MARGIN to spare, and no building tier or solid lower than MECH_TOP
## and higher than a step (STEP_H), no pillar core, park column, floor cut or ramp reaches into it. The court itself is
## sidewalk-high (CURB_H), a step from the road at both ends; its trees and benches are knockable props, no obstacle.
static func court_open(plan: CityPlan, axis: String, line: int, index: int) -> bool:
	var r := plan.seg_inner(axis, line, index)
	var across := 0 if axis == "s" else 1
	if r.size[across] < 2.0 * CityPlan.MECH_R + CityPlan.WALK_MARGIN:
		return false
	var c := r.get_center()[across]
	var corridor := r
	corridor.position[across] = c - CityPlan.MECH_R
	corridor.size[across] = 2.0 * CityPlan.MECH_R
	# Reach a little into both crossings: the capsule steps up onto the court from there.
	corridor.position[1 - across] -= CityPlan.MECH_R
	corridor.size[1 - across] += 2.0 * CityPlan.MECH_R
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		for t: Dictionary in b["tiers"]:
			if float(t["y0"]) < CityPlan.MECH_TOP and float(t["y1"]) > CityPlan.STEP_H and plan.tier_rect(i, t).intersects(corridor):
				return false
		for so: Dictionary in b.get("solids", []):
			var sz: Vector2 = so["size"]
			if float(so["y0"]) < CityPlan.MECH_TOP and float(so["y1"]) > CityPlan.STEP_H \
					and Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz).intersects(corridor):
				return false
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			if Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs).intersects(corridor):
				return false
	for col: Dictionary in plan.columns:
		var rr := float(col["ring_r"])
		if Rect2(float(col["x"]) - rr, float(col["s"]) - rr, rr * 2.0, rr * 2.0).intersects(corridor):
			return false
	if plan.site != null:
		for o in plan.floor_cuts():
			if o.grow(CityDims.HOLE_CURB).intersects(corridor):
				return false
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).intersects(corridor):
			return false
	return true




## The road_graph() floor-cut test: the edge's bounding box overlaps a cut shrunk by 0.5 m.
static func crosses_cut(p: Vector2, q: Vector2, cuts: Array[Rect2]) -> bool:
	var lo := Vector2(minf(p.x, q.x), minf(p.y, q.y))
	var hi := Vector2(maxf(p.x, q.x), maxf(p.y, q.y))
	for o in cuts:
		var inner := o.grow(-0.5)
		if lo.x < inner.end.x and hi.x > inner.position.x and lo.y < inner.end.y and hi.y > inner.position.y:
			return true
	return false


## walk_graph(true): the alley mouth nodes, the split road edges and the edges through the alleys (see walk_graph).
static func _walk_alleys(plan: CityPlan, g: Dictionary) -> void:
	var nodes: Array[Vector2] = []
	nodes.assign(g["nodes"])
	var edges: Array = g["edges"]
	var forms_of: Dictionary = g["forms"]
	var ns := plan.roads_s.size()
	var cuts: Array[Rect2] = plan.floor_cuts() if plan.site != null else ([] as Array[Rect2])
	var on_edge := {}       # Vector2i grid edge -> [[t along it, node id]]
	var through := []       # [node a, node b]
	for a: Dictionary in plan.alleys:
		var bi := int(a["block"])
		var ix := int(plan.blocks[bi]["ix"])
		var js := int(plan.blocks[bi]["is"])
		var c: Vector2 = (a["rect"] as Rect2).get_center()
		var ends: Array[int] = []
		for side in 2:
			var e0: int
			var e1: int
			var p: Vector2
			if int(a["axis"]) == 0:
				# Along x: mouths on roads_x[ix] (-x) and roads_x[ix + 1] (+x), on their segment between roads_s[js], [js + 1].
				var li := ix + side
				e0 = li * ns + js
				e1 = e0 + 1
				p = Vector2((float(plan.roads_x[li]["a"]) + float(plan.roads_x[li]["b"])) * 0.5, c.y)
			else:
				var lj := js + side
				e0 = ix * ns + lj
				e1 = (ix + 1) * ns + lj
				p = Vector2(c.x, (float(plan.roads_s[lj]["a"]) + float(plan.roads_s[lj]["b"])) * 0.5)
			# The alley's end on the building line: when the way from there to the road's centre line crosses a floor cut
			# (an alley opening onto a wide spine beside its ramp lane), the mouth stays there, on no road edge.
			var inner := c
			var z: Rect2 = (plan.blocks[bi]["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
			inner[int(a["axis"])] = z.position[int(a["axis"])] if side == 0 else z.end[int(a["axis"])]
			if crosses_cut(p, inner, cuts):
				ends.append(nodes.size())
				nodes.append(inner)
				continue
			var key := Vector2i(e0, e1)
			var list: Array = on_edge.get_or_add(key, [])
			var id := -1
			for m: Array in list:
				if (nodes[int(m[1])] as Vector2).distance_to(p) < 1.0:
					id = int(m[1])
			if id < 0:
				id = nodes.size()
				nodes.append(p)
				list.append([nodes[e0].distance_to(p), id])
			ends.append(id)
		through.append(ends)
	# Split each road edge an alley opens onto (only if the walk graph has it: never re-add a cut or vehicle-only drop).
	var out := []
	var split := {}
	for key: Vector2i in on_edge:
		split[key] = true
	for ed: Array in edges:
		var a := int(ed[0])
		var b := int(ed[1])
		var key := Vector2i(mini(a, b), maxi(a, b))
		if not split.has(key):
			out.append(ed)
			continue
		var f: String = forms_of[key]
		forms_of.erase(key)
		var list: Array = on_edge[key]
		list.sort_custom(func(u: Array, v: Array) -> bool: return float(u[0]) < float(v[0]))
		var prev := key.x
		for m: Array in list:
			out.append([prev, int(m[1])])
			forms_of[Vector2i(mini(prev, int(m[1])), maxi(prev, int(m[1])))] = f
			prev = int(m[1])
		out.append([prev, key.y])
		forms_of[Vector2i(mini(prev, key.y), maxi(prev, key.y))] = f
	for ends: Array in through:
		var a := int(ends[0])
		var b := int(ends[1])
		if a == b or crosses_cut(nodes[a], nodes[b], cuts):
			continue
		out.append([a, b])
		forms_of[Vector2i(mini(a, b), maxi(a, b))] = "alley"
	g["nodes"] = nodes
	g["edges"] = out


static func _grid_graph(plan: CityPlan) -> Dictionary:
	var nodes: Array[Vector2] = []
	var edges := []
	var nx := plan.roads_x.size()
	var ns := plan.roads_s.size()
	for i in nx:
		for j in ns:
			nodes.append(Vector2((float(plan.roads_x[i]["a"]) + float(plan.roads_x[i]["b"])) * 0.5,
					(float(plan.roads_s[j]["a"]) + float(plan.roads_s[j]["b"])) * 0.5))
	for i in nx:
		for j in ns:
			if j + 1 < ns:
				edges.append([i * ns + j, i * ns + j + 1])
			if i + 1 < nx:
				edges.append([i * ns + j, (i + 1) * ns + j])
	return {"nodes": nodes, "edges": edges}
