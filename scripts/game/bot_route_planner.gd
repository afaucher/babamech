class_name BotRoutePlanner
extends RefCounted
## Deck-aware route planner for the mission bot (MissionBot, `--bot`): from a point on one deck of the stack to a point on
## the same or another deck, through the section's real connections. Plain data from the SectionPlan and each deck's
## CityPlan (no physics), built once per mission; every machine's bot builds its own (input-only, nothing networked).
##
## COORDINATES. Nodes live on a deck in that deck's arc metres (x, s). Routes come out as legs whose points are (x, theta)
## (theta = s / radius_of(deck)): decks are concentric, so (x, theta) is the same top-down position on every deck and a
## leg that changes deck (a ramp, a drop) is one polyline.
##
## GRAPH, per deck. Longitudinal lines (constant x): the centre of every road along s, except the 50 m transit spine,
## which gives one line per lane (ramp_a, the avenue's two carriageways, rail, ramp_b). Cross lines (constant s): every
## cross road's centre. A node wherever two lines cross plus the extra points below, a walk edge between neighbouring
## points on a line, unless the segment touches a floor cut (grown CUT_GROW: shafts, ramp holes, the half cross road at a
## ramp's mouth) or a ramp standing on this deck (its lower part, out of the ceiling down to its foot; a cross road may
## pass under it where it is UNDER_RAMP_H high and no pier stands). Blocks (cells) are never crossed by line edges.
##
## BETWEEN DECKS.
##   ramp   two-way. In at the mouth (MOUTH m before its top cross line on the upper deck, ON the lane centre line, so the
##          bot lines up along the lane before the slope: the mouth node is reachable only along the lane, the top cross
##          road's half over the cut is blocked), out FOOT_OUT m past the foot on the lower deck, the leg a straight line
##          down the lane centre between the parapets.
##   shaft  down only. From the middle of any side of the shaft's cell (on the road around it) straight in to the hole's
##          centre; the drop lands at the same (x, theta) on the first deck below that has floor there (a stacked atrium
##          drops two decks), in that deck's park, joined to the roads around its cell.
##   glide  down one deck through an atrium (the hole below the shaft is another hole): run in fast, and once in the
##          lower deck's airspace hold height on the thrusters and fly on past the lower hole's far edge (GLIDE_PAST m),
##          landing on its plaza. Planned only where the landing point has floor.
##   lifts  don't move yet: skipped (their platforms are not open holes).
## Start and goal attach to the nearest nodes they can walk to in a straight line (no floor cut, no block but their own).
## `blocked` edges (stuck there, MissionBot) are left out of later plans.

const CUT_GROW := 1.5          ## m: a walk edge keeps this far from any floor cut
const LANE_SPLIT := 4.5        ## m either side of the avenue lane's median: its two carriageway lines
const MOUTH := 7.0             ## m before the ramp's top cross line: the ramp's entry node (on the lane centre)
const FOOT_OUT := 8.0          ## m past the ramp's foot cross line on the lower deck: its exit node
const UNDER_RAMP_H := 10.0     ## m: a cross road passes under a ramp where it is at least this high
const PIER_CLEAR := 5.0        ## m: ...and no pier stands within this
const RAMP_EXTRA := 15.0       ## route cost added to a ramp's length
const SHAFT_COST := 40.0       ## route cost of a drop (the risk of landing on something)
const GLIDE_COST := 90.0       ## route cost of a glide (heat, a harder manoeuvre)
const GLIDE_PAST := 10.0       ## m past the lower hole's far edge a glide lands
const ATTACH_N := 8            ## at most this many links from a start / goal into the graph
const ATTACH_RANGE := 160.0    ## m
const EXIT_OUT := 4.0          ## m past a block's side a start inside it walks out to
const BUILDING_IN := 3.5      ## m inside a block's edge (its sidewalk) a straight walk may go; past it stand buildings

var stack: CityStack
var sec: SectionPlan
var cuts: Array = []           ## per deck: Array[Rect2] (CityPlan.floor_cuts())
var unders: Array = []         ## per deck: [{rect, part, piers}] ramp parts standing on the deck
var cells: Array = []          ## per deck: Array[Rect2] the blocks
var xlines: Array = []         ## per deck: Array[float]
var slines: Array = []         ## per deck: Array[float]
var pos: Array[Vector2] = []   ## node -> (x, s) on its deck
var deck_of: Array[int] = []   ## node -> deck
var adj: Array = []            ## node -> [edge id]
var edges: Array = []          ## edge -> {a, b, kind: walk | ramp | shaft | glide, from, to, cost, pts: [(x, theta)]}
var blocked: Dictionary = {}   ## edge id -> true
var by_deck: Array = []        ## per deck: [node]
var closed: Array = []         ## per deck: Array[Rect2] road segments a mech can't walk (a superblock "none" court
#                                CityPlan.court_open() says is blocked); line edges through them are left out
var last_error := ""
var no_drops := false         ## tests: plan without shafts and glides (ramps only)
var _key: Dictionary = {}      ## "k:x:s" -> node


func net_fields() -> Dictionary:
	return {"stack": Net.LOCAL, "sec": Net.LOCAL, "cuts": Net.PRIVATE, "unders": Net.PRIVATE, "cells": Net.PRIVATE,
		"xlines": Net.PRIVATE, "slines": Net.PRIVATE, "pos": Net.PRIVATE, "deck_of": Net.PRIVATE, "adj": Net.PRIVATE,
		"edges": Net.PRIVATE, "blocked": Net.PRIVATE, "by_deck": Net.PRIVATE, "closed": Net.PRIVATE, "last_error": Net.PRIVATE,
		"_key": Net.PRIVATE, "no_drops": Net.PRIVATE}


func setup(st: CityStack) -> void:
	stack = st
	var plans: Array[CityPlan] = []
	for d in st.decks:
		plans.append(d.plan)
	setup_plans(st.section, plans)


## The same from plain data (tests, tools): the section and every deck's CityPlan.
func setup_plans(section: SectionPlan, plans: Array[CityPlan]) -> void:
	sec = section
	var n := sec.deck_count
	var extras: Array = []      # per deck: [Vector2] points that sit on a line
	var specials: Array = []    # [{fk, fa, tk, ta, kind, two_way, cost, pts}]
	for k in n:
		var plan: CityPlan = plans[k]
		cuts.append(plan.floor_cuts())
		var u: Array = []
		for r: Dictionary in plan.ramps:
			if r["role"] != "bottom":
				continue
			var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
			var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
			u.append({"rect": Rect2(float(r["x0"]) - 1.0, s0, float(r["x1"]) - float(r["x0"]) + 2.0, s1 - s0), "part": r,
				"piers": CityStreets.pier_s(r, plan)})
		unders.append(u)
		var c: Array[Rect2] = []
		for b: Dictionary in plan.blocks:
			c.append(b["rect"] as Rect2)
		cells.append(c)
		closed.append(_closed_segments(plan))
		var xs: Array[float] = []
		for road: Dictionary in plan.roads_x:
			if road.has("lanes"):
				for l: Dictionary in road["lanes"]:
					var mid := (float(l["a"]) + float(l["b"])) * 0.5
					if str(l["lane"]) == "avenue":
						xs.append(mid - LANE_SPLIT)
						xs.append(mid + LANE_SPLIT)
					else:
						xs.append(mid)
			else:
				xs.append((float(road["a"]) + float(road["b"])) * 0.5)
		xs.sort()
		xlines.append(xs)
		var ss: Array[float] = []
		for road: Dictionary in plan.roads_s:
			ss.append((float(road["a"]) + float(road["b"])) * 0.5)
		ss.sort()
		slines.append(ss)
		extras.append([])
		by_deck.append([])
	# Ramps: a mouth node on the upper deck, an exit node on the lower one, both on the lane centre line.
	for ci in sec.connectors.size():
		var cn: Dictionary = sec.connectors[ci]
		if cn["kind"] != "ramp" or bool(cn["locked"]):
			continue
		var top := int(cn["from"])
		var low := int(cn["to"])
		var lane := (float(cn["x0"]) + float(cn["x1"])) * 0.5
		var dir := signf(float(sec.row_theta[int(cn["foot_line"])]) - float(sec.row_theta[int(cn["top_line"])]))
		var mt := Vector2(lane, sec.line_s(top, int(cn["top_line"])) - dir * MOUTH)
		var mf := Vector2(lane, sec.line_s(low, int(cn["foot_line"])) + dir * FOOT_OUT)
		(extras[top] as Array).append(mt)
		(extras[low] as Array).append(mf)
		var a := xt(top, mt)
		var b := xt(low, mf)
		var length := absf(b.y - a.y) * (sec.radius_of(top) + sec.radius_of(low)) * 0.5
		specials.append({"fk": top, "fa": mt, "tk": low, "ta": mf, "kind": "ramp", "two_way": true,
			"cost": length + RAMP_EXTRA, "pts": [a, b], "connector": ci})
	# Shafts: side nodes on the roads round the cell, the drop to the first floor below, a glide through an atrium.
	var free: Array = []        # [{k, p, links: [Vector2 on k]}] nodes off the lines (landings)
	for ci in sec.connectors.size():
		var cn: Dictionary = sec.connectors[ci]
		if cn["kind"] != "shaft":
			continue
		var k := int(cn["from"])
		var col := int(cn["col"])
		var row := int(cn["row"])
		var hole := sec.connector_rect(ci, k)
		var c := hole.get_center()
		var th := c.y / sec.radius_of(k)
		var mids := _side_mids(k, col, row, c)
		for m: Vector2 in mids:
			(extras[k] as Array).append(m)
		var j := k + 1
		while j < n and in_cut(j, Vector2(c.x, th * sec.radius_of(j)), 0.5):
			j += 1
		if j >= n:
			continue
		var land := Vector2(c.x, th * sec.radius_of(j))
		var land_mids := _side_mids(j, col, row, land)
		for m: Vector2 in land_mids:
			(extras[j] as Array).append(m)
		free.append({"k": j, "p": land, "links": land_mids})
		for m: Vector2 in mids:
			specials.append({"fk": k, "fa": m, "tk": j, "ta": land, "kind": "shaft", "two_way": false,
				"cost": m.distance_to(c) + SHAFT_COST + 10.0 * float(j - k - 1), "pts": [xt(k, m), Vector2(c.x, th)],
				"connector": ci})
		if j == k + 1:
			continue
		# An atrium: glide over the hole below to its far side, on deck k + 1.
		var k1 := k + 1
		var below := Vector2(c.x, th * sec.radius_of(k1))
		var lower := _cut_at(k1, below)
		for m: Vector2 in mids:
			var u2 := (c - m).normalized()
			var g := below
			if absf(u2.x) > absf(u2.y):
				g.x = (lower.end.x if u2.x > 0.0 else lower.position.x) + signf(u2.x) * GLIDE_PAST
			else:
				g.y = (lower.end.y if u2.y > 0.0 else lower.position.y) + signf(u2.y) * GLIDE_PAST
			if in_cut(k1, g, 1.0):
				continue
			var g_mids := _side_mids(k1, col, row, g)
			for gm: Vector2 in g_mids:
				(extras[k1] as Array).append(gm)
			free.append({"k": k1, "p": g, "links": g_mids})
			specials.append({"fk": k, "fa": m, "tk": k1, "ta": g, "kind": "glide", "two_way": false,
				"cost": m.distance_to(c) + GLIDE_COST, "pts": [xt(k, m), xt(k1, g)], "connector": ci})
	# The lines: a node at every crossing and extra point, a walk edge between neighbours.
	for k in n:
		var xs: Array[float] = xlines[k]
		var ss: Array[float] = slines[k]
		for x in xs:
			var on: Array[float] = ss.duplicate()
			for e: Vector2 in extras[k]:
				if absf(e.x - x) < 0.01:
					on.append(e.y)
			on.sort()
			for i in on.size() - 1:
				if on[i + 1] - on[i] > 0.05:
					_walk_edge(k, Vector2(x, on[i]), Vector2(x, on[i + 1]), true)
		for s in ss:
			var on: Array[float] = xs.duplicate()
			for e: Vector2 in extras[k]:
				if absf(e.y - s) < 0.01:
					on.append(e.x)
			on.sort()
			for i in on.size() - 1:
				if on[i + 1] - on[i] > 0.05:
					_walk_edge(k, Vector2(on[i], s), Vector2(on[i + 1], s), true)
	for f: Dictionary in free:
		for m: Vector2 in f["links"]:
			_walk_edge(int(f["k"]), f["p"], m, false)
	for sp: Dictionary in specials:
		var a := _node(int(sp["fk"]), sp["fa"])
		var b := _node(int(sp["tk"]), sp["ta"])
		_add_edge(a, b, str(sp["kind"]), float(sp["cost"]), sp["pts"], int(sp["connector"]))
		if bool(sp["two_way"]):
			var back: Array = (sp["pts"] as Array).duplicate()
			back.reverse()
			_add_edge(b, a, str(sp["kind"]), float(sp["cost"]), back, int(sp["connector"]))


## (x, s) on deck k -> (x, theta).
func xt(k: int, p: Vector2) -> Vector2:
	return Vector2(p.x, p.y / sec.radius_of(k))


## (x, theta) -> (x, s) on deck k.
func on_deck(k: int, q: Vector2) -> Vector2:
	return Vector2(q.x, q.y * sec.radius_of(k))


func in_cut(k: int, p: Vector2, grow: float = 0.0) -> bool:
	for r: Rect2 in cuts[k]:
		if r.grow(grow).has_point(p):
			return true
	return false


## The floor cut of deck k holding p (or the nearest), as a Rect2.
func _cut_at(k: int, p: Vector2) -> Rect2:
	var best := Rect2(p, Vector2.ZERO)
	var best_d := INF
	for r: Rect2 in cuts[k]:
		var d := 0.0 if r.has_point(p) else r.get_center().distance_to(p)
		if d < best_d:
			best_d = d
			best = r
	return best


## The middle of each side of cell (col, row) on deck k, on the nearest line outside that side, level with `c`.
func _side_mids(k: int, col: int, row: int, c: Vector2) -> Array:
	var r := sec.cell_rect(k, col, row)
	var out: Array = []
	var xl := -INF
	var xr := INF
	for x: float in xlines[k]:
		if x <= r.position.x:
			xl = maxf(xl, x)
		if x >= r.end.x:
			xr = minf(xr, x)
	var sb := -INF
	var stp := INF
	for s: float in slines[k]:
		if s <= r.position.y:
			sb = maxf(sb, s)
		if s >= r.end.y:
			stp = minf(stp, s)
	for m: Vector2 in [Vector2(xl, c.y), Vector2(xr, c.y), Vector2(c.x, sb), Vector2(c.x, stp)]:
		if is_finite(m.x) and is_finite(m.y):
			out.append(m)
	return out


func _node(k: int, p: Vector2) -> int:
	var key := "%d:%.2f:%.2f" % [k, p.x, p.y]
	if _key.has(key):
		return int(_key[key])
	var i := pos.size()
	pos.append(p)
	deck_of.append(k)
	adj.append([])
	(by_deck[k] as Array).append(i)
	_key[key] = i
	return i


func _walk_edge(k: int, a: Vector2, b: Vector2, on_line: bool) -> void:
	if not seg_ok(k, a, b, -1 if on_line else cell_at(k, a), on_line):
		return
	if on_line:
		var mid := (a + b) * 0.5
		for r: Rect2 in closed[k]:
			if r.has_point(mid):
				return
	var ia := _node(k, a)
	var ib := _node(k, b)
	var d := a.distance_to(b)
	_add_edge(ia, ib, "walk", d, [xt(k, a), xt(k, b)], -1)
	_add_edge(ib, ia, "walk", d, [xt(k, b), xt(k, a)], -1)


func _add_edge(a: int, b: int, kind: String, cost: float, pts: Array, connector: int) -> void:
	var id := edges.size()
	edges.append({"a": a, "b": b, "kind": kind, "from": deck_of[a], "to": deck_of[b], "cost": cost, "pts": pts,
		"connector": connector})
	(adj[a] as Array).append(id)


## The road segments of `plan` the mech can't walk along (CityPlan road forms, docs/design/city-variety.md "Graphs"):
## superblock ("none") segments whose court isn't open (CityPlan.court_open). Streets, lanes and pedestrian streets are
## walkable (the planner walks every road line: CityPlan.walk_graph()'s edges, not road_graph()'s vehicle edges).
static func _closed_segments(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if not plan.has_method("seg_form") or not plan.has_method("court_open"):
		return out
	var nx := plan.roads_x.size()
	var ns := plan.roads_s.size()
	for i in nx:
		for j in ns - 1:
			if plan.seg_form("s", i, j) == "none" and not plan.court_open("s", i, j):
				out.append(plan.seg_inner("s", i, j))
	for j in ns:
		for i in nx - 1:
			if plan.seg_form("x", j, i) == "none" and not plan.court_open("x", j, i):
				out.append(plan.seg_inner("x", j, i))
	return out


## True when walking straight from a to b on deck k touches no floor cut (grown CUT_GROW), no ramp standing on the deck
## (a cross road may pass under it, see the header) and, unless `skip_cells`, no block other than block `own`.
func seg_ok(k: int, a: Vector2, b: Vector2, own: int = -1, skip_cells: bool = false) -> bool:
	for r: Rect2 in cuts[k]:
		if seg_hits(a, b, r.grow(CUT_GROW)):
			return false
	for u: Dictionary in unders[k]:
		if not seg_hits(a, b, u["rect"]):
			continue
		if absf(a.y - b.y) > 0.01:
			return false
		if CityPlan.ramp_height(u["part"], a.y) < UNDER_RAMP_H:
			return false
		for ps: float in u["piers"]:
			if absf(ps - a.y) < PIER_CLEAR:
				return false
	if not skip_cells:
		var cs: Array[Rect2] = cells[k]
		for i in cs.size():
			if i != own and seg_hits(a, b, cs[i].grow(-BUILDING_IN)):
				return false
	return true


## The block of deck k whose inside (past its sidewalk, BUILDING_IN) holds p, or -1.
func cell_at(k: int, p: Vector2) -> int:
	var cs: Array[Rect2] = cells[k]
	for i in cs.size():
		if cs[i].grow(-BUILDING_IN).has_point(p):
			return i
	return -1


## Segment a-b against an axis-aligned rect (Liang-Barsky).
static func seg_hits(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var p0 := a[axis]
		var dd := d[axis]
		var lo := r.position[axis]
		var hi := r.end[axis]
		if absf(dd) < 1e-6:
			if p0 < lo or p0 > hi:
				return false
		else:
			var ta := (lo - p0) / dd
			var tb := (hi - p0) / dd
			if ta > tb:
				var tmp := ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return false
	return true


## Links from a point on deck k into the graph: [[node, cost]], the nearest ones it can walk to straight.
func _attach(k: int, p: Vector2, reverse: bool) -> Array:
	var own := cell_at(k, p)
	var cand: Array = []
	for i: int in by_deck[k]:
		var d := pos[i].distance_to(p)
		if d < ATTACH_RANGE:
			cand.append([i, d])
	cand.sort_custom(func(u: Array, v: Array) -> bool: return float(u[1]) < float(v[1]))
	var out: Array = []
	for c: Array in cand:
		if out.size() >= ATTACH_N:
			break
		var i := int(c[0])
		var ok := seg_ok(k, pos[i], p, own) if reverse else seg_ok(k, p, pos[i], own)
		if ok:
			out.append([i, float(c[1])])
	if out.is_empty():
		# Nothing straight (in a corner, on a roof): the nearest few anyway, dearer.
		for c: Array in cand.slice(0, 3):
			out.append([int(c[0]), float(c[1]) * 3.0 + 30.0])
	return out


## The route from (x, s) `p0` on deck k0 to `p1` on deck k1: an Array of legs
##   {kind: walk | ramp | shaft | glide, from, to, pts: [(x, theta)], edges: [edge id], connector}
## (consecutive walk edges merged into one walk leg that starts at p0 and ends at p1). Empty when there is no way
## (last_error says why). `end_on_road`: the goal may be off the walkable ground (an enemy in a block, on a roof): the
## route ends on the road node that best trades path length against straight distance to it, never walking into the block.
## `h0`: the start's height above deck k0's floor (on the floor beside a ramp's lower part, the route first steps out of
## its lane; up on the ramp itself it does not).
func plan(k0: int, p0: Vector2, k1: int, p1: Vector2, end_on_road: bool = false, h0: float = 0.0, _depth: int = 0) -> Array:
	last_error = ""
	var own0 := cell_at(k0, p0)
	for u: Dictionary in unders[k0]:
		var ur: Rect2 = u["rect"]
		if _depth < 2 and h0 < 2.0 and ur.has_point(p0) and not ur.has_point(p1):
			# Beside / under a ramp's lower part (its foot, its parapets): out to the nearer side of the lane first.
			var near_x := ur.position.x - 2.5 if p0.x - ur.position.x < ur.end.x - p0.x else ur.end.x + 2.5
			var far_x := ur.end.x + 2.5 if near_x < ur.position.x else ur.position.x - 2.5
			var ex := Vector2(near_x, p0.y)
			if cell_at(k0, ex) >= 0 or in_cut(k0, ex, CUT_GROW):
				ex = Vector2(far_x, p0.y)   # the nearer side is a block or a hole: the other side of the lane
			var rest2 := plan(k0, ex, k1, p1, end_on_road, 0.0, _depth + 1)
			if not rest2.is_empty():
				if rest2[0]["kind"] == "walk" and int(rest2[0]["from"]) == k0:
					(rest2[0]["pts"] as Array).push_front(xt(k0, p0))
				else:
					rest2.push_front({"kind": "walk", "from": k0, "to": k0, "pts": [xt(k0, p0), xt(k0, ex)], "edges": [], "connector": -1})
			return rest2
	if _depth < 2 and own0 >= 0 and not (k0 == k1 and cell_at(k1, p1) == own0):
		# Inside a block (a plaza, a park, between buildings): out by its nearest side first, never across it.
		var e := exit_point(k0, own0, p0)
		var rest := plan(k0, e, k1, p1, end_on_road, 0.0, _depth + 1)
		if rest.is_empty():
			return rest
		var first: Dictionary = rest[0]
		if first["kind"] == "walk" and int(first["from"]) == k0:
			(first["pts"] as Array).push_front(xt(k0, p0))
		else:
			rest.push_front({"kind": "walk", "from": k0, "to": k0, "pts": [xt(k0, p0), xt(k0, e)], "edges": [], "connector": -1})
		return rest
	if k0 == k1 and seg_ok(k0, p0, p1, own0) and (own0 >= 0 or not end_on_road or cell_at(k1, p1) < 0):
		return [{"kind": "walk", "from": k0, "to": k0, "pts": [xt(k0, p0), xt(k0, p1)], "edges": [], "connector": -1}]
	var starts := _attach(k0, p0, false)
	var goals := {}
	if end_on_road and cell_at(k1, p1) >= 0:
		var near: Array = []
		for i: int in by_deck[k1]:
			near.append([i, pos[i].distance_to(p1)])
		near.sort_custom(func(u: Array, v: Array) -> bool: return float(u[1]) < float(v[1]))
		for g: Array in near.slice(0, 10):
			goals[int(g[0])] = float(g[1]) * 4.0   # get close: a metre nearer the target is worth 4 m of walking
	else:
		end_on_road = false
		for g: Array in _attach(k1, p1, true):
			goals[int(g[0])] = float(g[1])
	var r_ref := sec.radius_of(k1)
	var target := xt(k1, p1)
	var g_score := {}
	var came := {}      # node -> edge id (-1: from the start)
	var open: Array[int] = []
	var f := {}
	for s: Array in starts:
		var i := int(s[0])
		if float(s[1]) < float(g_score.get(i, INF)):
			g_score[i] = float(s[1])
			came[i] = -1
			f[i] = float(s[1]) + _h(i, target, r_ref)
			if not i in open:
				open.append(i)
	var closed := {}
	var best_end := -1
	var best_total := INF
	while not open.is_empty():
		var bi := 0
		for q in range(1, open.size()):
			if float(f[open[q]]) < float(f[open[bi]]):
				bi = q
		var cur := open[bi]
		open.remove_at(bi)
		if float(f[cur]) >= best_total:
			break
		closed[cur] = true
		if goals.has(cur):
			var tot := float(g_score[cur]) + float(goals[cur])
			if tot < best_total:
				best_total = tot
				best_end = cur
		for eid: int in adj[cur]:
			if blocked.has(eid) or (no_drops and edges[eid]["kind"] in ["shaft", "glide"]):
				continue
			var e: Dictionary = edges[eid]
			var nb := int(e["b"])
			if closed.has(nb):
				continue
			var tent := float(g_score[cur]) + float(e["cost"])
			if tent < float(g_score.get(nb, INF)):
				g_score[nb] = tent
				came[nb] = eid
				f[nb] = tent + _h(nb, target, r_ref)
				if not nb in open:
					open.append(nb)
	if best_end < 0:
		last_error = "no way from deck %d to deck %d" % [k0, k1]
		return []
	var chain: Array[int] = []
	var node := best_end
	while int(came[node]) >= 0:
		var eid := int(came[node])
		chain.append(eid)
		node = int(edges[eid]["a"])
	chain.reverse()
	# Merge into legs.
	var legs: Array = []
	var cur_leg := {"kind": "walk", "from": k0, "to": k0, "pts": [xt(k0, p0)], "edges": [], "connector": -1}
	(cur_leg["pts"] as Array).append(xt(deck_of[node], pos[node]))   # the node the start attached to
	for eid in chain:
		var e: Dictionary = edges[eid]
		if e["kind"] == "walk":
			(cur_leg["pts"] as Array).append((e["pts"] as Array)[-1])
			(cur_leg["edges"] as Array).append(eid)
			continue
		legs.append(cur_leg)
		legs.append({"kind": e["kind"], "from": int(e["from"]), "to": int(e["to"]), "pts": (e["pts"] as Array).duplicate(),
			"edges": [eid], "connector": int(e["connector"])})
		var b := int(e["b"])
		cur_leg = {"kind": "walk", "from": deck_of[b], "to": deck_of[b], "pts": [xt(deck_of[b], pos[b])], "edges": [],
			"connector": -1}
	if not end_on_road:
		(cur_leg["pts"] as Array).append(xt(k1, p1))
	legs.append(cur_leg)
	# Drop degenerate walk legs (a single point repeated).
	var out: Array = []
	for leg: Dictionary in legs:
		if leg["kind"] == "walk":
			var pts: Array = _dedup(leg["pts"])
			if pts.size() < 2:
				continue
			leg["pts"] = pts
		out.append(leg)
	return out


func _dedup(pts: Array) -> Array:
	var out: Array = []
	for q: Vector2 in pts:
		if out.is_empty() or (out[-1] as Vector2).distance_to(q) > 0.01:
			out.append(q)
	return out


func _h(i: int, target: Vector2, r_ref: float) -> float:
	var q := xt(deck_of[i], pos[i])
	return Vector2(q.x - target.x, (q.y - target.y) * r_ref).length() * 0.9


## Mark the walk edge of `leg` nearest the arc point p (x, theta) as blocked (both ways). Returns whether one was found.
func block_near(leg: Dictionary, p: Vector2) -> bool:
	var best := -1
	var best_d := INF
	for eid: int in leg["edges"]:
		var e: Dictionary = edges[eid]
		var k := int(e["from"])
		var a := on_deck(k, (e["pts"] as Array)[0])
		var b := on_deck(k, (e["pts"] as Array)[-1])
		var q := on_deck(k, p)
		var d := Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q)
		if d < best_d:
			best_d = d
			best = eid
	if best < 0 or best_d > 25.0:
		return false
	blocked[best] = true
	var e2: Dictionary = edges[best]
	for eid: int in adj[int(e2["b"])]:
		if int(edges[eid]["b"]) == int(e2["a"]) and edges[eid]["kind"] == e2["kind"]:
			blocked[eid] = true
	return true


## Summary for logs and tests: {nodes, edges, ramps, shafts, glides}.
func summary() -> Dictionary:
	var c := {"nodes": pos.size(), "edges": edges.size(), "ramp": 0, "shaft": 0, "glide": 0}
	for e: Dictionary in edges:
		if c.has(e["kind"]):
			c[e["kind"]] = int(c[e["kind"]]) + 1
	return c


## Just outside (EXIT_OUT m, on the road) the side of block `ci` of deck k nearest to p that is open road.
func exit_point(k: int, ci: int, p: Vector2) -> Vector2:
	var r: Rect2 = cells[k][ci]
	var sides := [[p.x - r.position.x, Vector2(r.position.x - EXIT_OUT, p.y)], [r.end.x - p.x, Vector2(r.end.x + EXIT_OUT, p.y)],
		[p.y - r.position.y, Vector2(p.x, r.position.y - EXIT_OUT)], [r.end.y - p.y, Vector2(p.x, r.end.y + EXIT_OUT)]]
	sides.sort_custom(func(u: Array, v: Array) -> bool: return float(u[0]) < float(v[0]))
	for sd: Array in sides:   # the nearest side that comes out on open road (not into a cut or beside a ramp's foot)
		var q: Vector2 = sd[1]
		if in_cut(k, q, CUT_GROW) or _in_under(k, q):
			continue
		return q
	return sides[0][1]


func _in_under(k: int, q: Vector2) -> bool:
	for u: Dictionary in unders[k]:
		if (u["rect"] as Rect2).has_point(q):
			return true
	return false
