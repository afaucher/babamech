class_name EnemyNav
extends RefCounted
## The enemies' path service (owned by EnemySquad as `squad.nav`): per-deck walk graphs (CityGraphs.walk_graph(), alleys
## off, plus park / plaza centres), 2D occluders (building tiers >= 6 m and pillar cores) and floor cuts (ramp mouths,
## holes), all in a deck's 2D arc (x, s) space, and the queries over them: road-graph A*, cover-weighted A* that avoids a
## threat's open sightlines, arc-space occlusion, nearest road point, reachable nodes. Built from the plans only (no RNG,
## no game state): `reset(plan)` for the default (single-district) deck, `add_deck(k, plan)` per stack deck. Queries
## take `deck` (-1 or an unknown deck = the default). All fields Net.LOCAL.

const COVER_EXPOSURE_PENALTY := 140.0     ## m A* penalty for road nodes in open LOS of the threat (beats side-street detour)
const COVER_MID_EXPOSURE_PENALTY := 70.0  ## m A* penalty when edge midpoint is exposed to the threat
const CUT_PATH_MARGIN := 2.0              ## m: paths keep a body's width clear of floor cuts (ramp mouths, holes)

var _graph_nodes: Array[Vector2] = []
var _graph_adj: Array = []
var _occluders: Array = []         ## [{rect: Rect2, h: float}] tall building tiers (>= 6 m) & pillar cores in arc space
var _occluder_rects: Array[Rect2] = [] ## flat Rect2 cache parallel to _occluders (zero Dictionary lookups in cover A*)
## Floor cuts (ramp mouths and floor holes, CityPlan.floor_cuts) in arc space: walkable-looking openings a ground unit
## must not step into (a ramp mouth has no railing). Not LOS occluders: they only shape paths and steering.
var _cut_rects: Array[Rect2] = []
## Multi-deck stack (W4): deck k -> [nodes, adj] (that deck's road graph, add_deck); enemies path on their own deck's.
var _deck_graphs: Dictionary = {}
var _deck_occluders: Dictionary = {} ## deck k -> Array of {rect: Rect2, h: float}
var _deck_occluder_rects: Dictionary = {} ## deck k -> Array[Rect2]
var _deck_cut_rects: Dictionary = {}      ## deck k -> Array[Rect2]


func net_fields() -> Dictionary:
	return {"_graph_nodes": Net.LOCAL, "_graph_adj": Net.LOCAL, "_occluders": Net.LOCAL, "_occluder_rects": Net.LOCAL,
		"_cut_rects": Net.LOCAL, "_deck_graphs": Net.LOCAL, "_deck_occluders": Net.LOCAL,
		"_deck_occluder_rects": Net.LOCAL, "_deck_cut_rects": Net.LOCAL}


## Drops every deck and builds the default deck's nav from `plan` (null: empty).
func reset(plan: CityPlan) -> void:
	_deck_graphs.clear()
	_deck_occluders.clear()
	_deck_occluder_rects.clear()
	_deck_cut_rects.clear()
	_build(plan)


## Stack deck k's road graph & 2D occluders (its own plan, in its own arc coordinates) for find_arc_path / find_cover_path.
func add_deck(k: int, deck_plan: CityPlan) -> void:
	var keep_n := _graph_nodes
	var keep_a := _graph_adj
	var keep_o := _occluders
	var keep_r := _occluder_rects
	var keep_c := _cut_rects
	_graph_nodes = [] as Array[Vector2]
	_graph_adj = []
	_occluders = []
	_occluder_rects = [] as Array[Rect2]
	_build(deck_plan)
	_deck_graphs[k] = [_graph_nodes, _graph_adj]
	_deck_occluders[k] = _occluders
	_deck_occluder_rects[k] = _occluder_rects
	_deck_cut_rects[k] = _cut_rects
	_graph_nodes = keep_n
	_graph_adj = keep_a
	_occluders = keep_o
	_occluder_rects = keep_r
	_cut_rects = keep_c


## [nodes: Array[Vector2], adj: Array] of deck `deck`'s walk graph (the default deck's for an unknown deck).
func graph(deck: int = -1) -> Array:
	if _deck_graphs.has(deck):
		return _deck_graphs[deck]
	return [_graph_nodes, _graph_adj]


func _build(plan: CityPlan) -> void:
	_graph_nodes.clear()
	_graph_adj.clear()
	_occluders.clear()
	_occluder_rects.clear()
	_cut_rects = [] as Array[Rect2]
	if plan == null:
		return
	if plan.site != null:
		_cut_rects = plan.floor_cuts()
	# Where a walker goes (CityGraphs.walk_graph, alleys off): every road edge, pedestrian streets and crossable courts,
	# never across a floor cut. Every ground unit (tanks too) walks it; road_graph() is the vehicles' (ambient traffic).
	var rg := CityGraphs.walk_graph(plan)
	for n: Vector2 in rg["nodes"]:
		_graph_nodes.append(n)
		_graph_adj.append([])
	for ed: Array in rg["edges"]:
		var a := int(ed[0])
		var b := int(ed[1])
		if b in (_graph_adj[a] as Array):
			continue
		(_graph_adj[a] as Array).append(b)
		(_graph_adj[b] as Array).append(a)
	# Also link park / plaza centers to their nearest road crossing so patrols can traverse open lots.
	for l: Dictionary in plan.lots:
		if str(l["kind"]) == "open" and str(l.get("open", "")) in ["park", "plaza"]:
			var c: Vector2 = (l["rect"] as Rect2).get_center()
			var near := _nearest_node(c)
			if near >= 0:
				var idx := _graph_nodes.size()
				_graph_nodes.append(c)
				_graph_adj.append([near])
				(_graph_adj[near] as Array).append(idx)
	# Pre-cache 2D solid building footprints (tiers >= 6 m) & pillar cores for O(N) cover-path & drone clearance queries.
	for b: Dictionary in plan.buildings:
		var bc: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			var y1 := float(t["y1"])
			if y1 < 6.0:
				continue
			var sz: Vector2 = t["size"]
			var tc := bc + (t["off"] as Vector2)
			var rr := Rect2(tc - sz * 0.5, sz)
			_occluders.append({"rect": rr, "h": y1 + CityPlan.CURB_H})
			_occluder_rects.append(rr)
		if bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var csz: Vector2 = core["size"]
			var cc := Vector2(float(core["x"]), float(core["s"]))
			var cr := Rect2(cc - csz * 0.5, csz)
			_occluders.append({"rect": cr, "h": 99.0})
			_occluder_rects.append(cr)


func _nearest_node(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _graph_nodes.size():
		var d := p.distance_squared_to(_graph_nodes[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## Nearest road-graph node in 2D arc space for deck `deck` (used by ground unstick recovery).
## Prefers real road crossings (degree >= 2) at least `min_dist` away so unsticking never picks a dead-end or own feet.
func nearest_road_point(arc2: Vector2, deck: int = -1, min_dist: float = 0.0) -> Vector2:
	var g := graph(deck)
	var nodes: Array[Vector2] = g[0]
	var adj: Array = g[1]
	if nodes.is_empty():
		return Vector2(NAN, NAN)
	var min_d2 := min_dist * min_dist
	var best := Vector2(NAN, NAN)
	var best_d := INF
	var fallback := nodes[0]
	var fallback_d := INF
	for i in nodes.size():
		var d := arc2.distance_squared_to(nodes[i])
		if d < fallback_d:
			fallback_d = d
			fallback = nodes[i]
		if d < min_d2:
			continue
		var deg := (adj[i] as Array).size() if i < adj.size() else 0
		var score := d + (4000.0 if deg < 2 else 0.0)
		if score < best_d:
			best_d = score
			best = nodes[i]
	return best if not is_nan(best.x) else fallback


## All road/plaza graph nodes on `deck` reachable via graph edges from the node nearest `start_arc`.
func reachable_nodes(start_arc: Vector2, deck: int) -> Array[Vector2]:
	var g := graph(deck)
	var nodes: Array[Vector2] = g[0]
	var adj: Array = g[1]
	var out: Array[Vector2] = []
	if nodes.is_empty():
		return out
	var start := 0
	var best_d := INF
	for i in nodes.size():
		var d := start_arc.distance_squared_to(nodes[i])
		if d < best_d:
			best_d = d
			start = i
	var visited := PackedByteArray()
	visited.resize(nodes.size())
	visited[start] = 1
	var queue: Array[int] = [start]
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		out.append(nodes[cur])
		for nxt: int in adj[cur]:
			if visited[nxt] == 0:
				visited[nxt] = 1
				queue.append(nxt)
	return out


## Cached 2D building occluders [{rect: Rect2, h: float}] for deck `deck` (or single-district default).
func deck_occluders(deck: int = -1) -> Array:
	if _deck_occluders.has(deck):
		return _deck_occluders[deck] as Array
	return _occluders


## Floor cuts of deck deck (or the single-district default) in arc space: ramp mouths and floor holes.
func deck_cuts(deck: int = -1) -> Array[Rect2]:
	if _deck_cut_rects.has(deck):
		return _deck_cut_rects[deck] as Array[Rect2]
	return _cut_rects


## True when segment a-b (arc space) passes within CUT_PATH_MARGIN of a floor cut in cuts.
static func seg_crosses_cuts(a: Vector2, b: Vector2, cuts: Array[Rect2]) -> bool:
	for o: Rect2 in cuts:
		if segment_hits_rect(a, b, o.grow(CUT_PATH_MARGIN)):
			return true
	return false


func _deck_occ_rects(deck: int = -1) -> Array[Rect2]:
	if _deck_occluder_rects.has(deck):
		return _deck_occluder_rects[deck] as Array[Rect2]
	return _occluder_rects


## Fast 2D arc-space LOS occlusion check against tall building tiers (>= 6 m) and pillar cores.
func arc_segment_occluded(a: Vector2, b: Vector2, deck: int = -1) -> bool:
	return arc_seg_occluded_rects(a, b, _deck_occ_rects(deck))


static func arc_seg_occluded_rects(a: Vector2, b: Vector2, rects: Array[Rect2]) -> bool:
	var min_x := minf(a.x, b.x)
	var max_x := maxf(a.x, b.x)
	var min_y := minf(a.y, b.y)
	var max_y := maxf(a.y, b.y)
	for r: Rect2 in rects:
		if max_x < r.position.x or min_x > r.end.x or max_y < r.position.y or min_y > r.end.y:
			continue
		if segment_hits_rect(a, b, r):
			return true
	return false


static func segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	if absf(d.x) < 1e-6:
		if a.x < r.position.x or a.x > r.end.x:
			return false
	else:
		var inv := 1.0 / d.x
		var tx1 := (r.position.x - a.x) * inv
		var tx2 := (r.end.x - a.x) * inv
		if tx1 > tx2:
			var tmp := tx1
			tx1 = tx2
			tx2 = tmp
		t0 = maxf(t0, tx1)
		t1 = minf(t1, tx2)
		if t0 > t1:
			return false
	if absf(d.y) < 1e-6:
		if a.y < r.position.y or a.y > r.end.y:
			return false
	else:
		var inv := 1.0 / d.y
		var ty1 := (r.position.y - a.y) * inv
		var ty2 := (r.end.y - a.y) * inv
		if ty1 > ty2:
			var tmp := ty1
			ty1 = ty2
			ty2 = tmp
		t0 = maxf(t0, ty1)
		t1 = minf(t1, ty2)
		if t0 > t1:
			return false
	return true


func find_arc_path(from_arc: Vector2, to_arc: Vector2, deck: int = -1) -> Array[Vector2]:
	var rects := _deck_occ_rects(deck)
	var cuts := deck_cuts(deck)
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_arc_path(from_arc, to_arc, rects, cuts)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_arc_path(from_arc, to_arc, rects, cuts)


## Pick nearest navigable road crossing to `p`, avoiding 1-degree park/plaza dead-end spurs (which cause backtracking
## on straight avenues) and preferring un-occluded crossings; optionally restricted to nodes in `allowed` (non-zero).
func _nearest_nav_node(p: Vector2, rects: Array[Rect2], allowed: PackedByteArray = PackedByteArray(),
		cuts: Array[Rect2] = []) -> int:
	var n_count := _graph_nodes.size()
	var use_mask := allowed.size() == n_count
	var best := -1
	var best_score := INF
	for i in n_count:
		if use_mask and allowed[i] == 0:
			continue
		var np := _graph_nodes[i]
		var d2 := p.distance_squared_to(np)
		var deg := (_graph_adj[i] as Array).size()
		# Penalize 1-degree park/plaza spurs and occluded crossings behind building blocks.
		var score := d2
		if deg < 2:
			score += 2500.0
		if score >= best_score:
			continue   # cannot win: skip the segment tests below
		if not rects.is_empty() and d2 > 36.0 and arc_seg_occluded_rects(p, np, rects):
			score += 3600.0
		# A crossing reached only across a floor cut (a ramp mouth, a hole) is not the one to walk to first.
		if score < best_score and not cuts.is_empty() and d2 > 36.0 and seg_crosses_cuts(p, np, cuts):
			score += 3600.0
		if score < best_score:
			best_score = score
			best = i
	if best >= 0:
		return best
	return _nearest_node(p)


## Mark all nodes reachable from `root` in `_graph_adj` (used as fallback when a floor cut splits the road graph).
func _component_mask(root: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(_graph_nodes.size())
	if root < 0 or root >= _graph_nodes.size():
		return mask
	mask[root] = 1
	var q: Array[int] = [root]
	var head := 0
	while head < q.size():
		var cur := q[head]
		head += 1
		for nb: int in _graph_adj[cur]:
			if mask[nb] == 0:
				mask[nb] = 1
				q.append(nb)
	return mask


## Clean up a reconstructed road path: prepend start node `s` when walking directly to `rev[0]` crosses a building,
## and drop any leading waypoint that lies behind `from_arc` relative to the next open waypoint (eliminates U-turns).
func _finalize_arc_path(from_arc: Vector2, s: int, rev: Array[Vector2], rects: Array[Rect2],
		cuts: Array[Rect2] = []) -> Array[Vector2]:
	if rev.is_empty():
		return rev
	var s_pt := _graph_nodes[s]
	if from_arc.distance_to(s_pt) > 6.5 and not rects.is_empty() and arc_seg_occluded_rects(from_arc, rev[0], rects):
		rev.push_front(s_pt)
	elif not cuts.is_empty() and rev[0] != s_pt and seg_crosses_cuts(from_arc, rev[0], cuts):
		# The straight line to the first waypoint runs over a floor cut (e.g. diagonally across a ramp mouth, which has
		# no railing): walk to the start crossing first, along the road.
		rev.push_front(s_pt)
	while rev.size() >= 2:
		var v0 := rev[0] - from_arc
		var v1 := rev[1] - rev[0]
		if v0.dot(v1) < 0.0 and (rects.is_empty() or not arc_seg_occluded_rects(from_arc, rev[1], rects)) \
				and (cuts.is_empty() or not seg_crosses_cuts(from_arc, rev[1], cuts)):
			rev.pop_front()
		else:
			break
	return rev


## Cover-weighted road-graph A* (docs/design/enemy-tactics-and-drones.md §4.2): penalizes nodes and edge midpoints
## that sit in open 2D LOS of `threat_arc` outside `engage_range * 0.75`, steering flankers down occluded side streets.
func find_cover_path(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, deck: int = -1,
		engage_range: float = 60.0) -> Array[Vector2]:
	var rects := _deck_occ_rects(deck)
	var cuts := deck_cuts(deck)
	if rects.is_empty():
		return find_arc_path(from_arc, to_arc, deck)
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_cover_path_internal(from_arc, to_arc, threat_arc, rects, engage_range, cuts)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_cover_path_internal(from_arc, to_arc, threat_arc, rects, engage_range, cuts)


func _find_cover_path_internal(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, rects: Array[Rect2],
		engage_range: float, cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var n_count := _graph_nodes.size()
	if n_count == 0 or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_nav_node(from_arc, rects, PackedByteArray(), cuts)
	var g := _nearest_nav_node(to_arc, rects, PackedByteArray(), cuts)
	if s < 0 or g < 0 or s == g:
		return out
	var safe_band2 := (engage_range * 0.75) * (engage_range * 0.75)
	var node_exp := PackedByteArray()  # 0 = unseen, 1 = occluded, 2 = exposed
	node_exp.resize(n_count)
	var closed := PackedByteArray()
	closed.resize(n_count)
	var open: Array[int] = [s]
	var came := {}
	var g_score := {s: 0.0}
	var goal_p := _graph_nodes[g]
	var f_score := {s: _graph_nodes[s].distance_to(goal_p)}
	while not open.is_empty():
		var best_i := 0
		var best_f := float(f_score.get(open[0], INF))
		for k in range(1, open.size()):
			var fk := float(f_score.get(open[k], INF))
			if fk < best_f:
				best_f = fk
				best_i = k
		var cur := open[best_i]
		if cur == g:
			var rev: Array[Vector2] = []
			var node := cur
			while came.has(node):
				rev.append(_graph_nodes[node])
				node = int(came[node])
			rev.reverse()
			return _finalize_arc_path(from_arc, s, rev, rects, cuts)
		open.remove_at(best_i)
		closed[cur] = 1
		var cur_p := _graph_nodes[cur]
		var cur_exp := node_exp[cur]
		if cur_exp == 0:
			cur_exp = 1 if (cur_p.distance_squared_to(threat_arc) <= safe_band2 or arc_seg_occluded_rects(cur_p, threat_arc, rects)) else 2
			node_exp[cur] = cur_exp
		for nb: int in _graph_adj[cur]:
			if closed[nb] != 0:
				continue
			var nb_p := _graph_nodes[nb]
			var step_cost := cur_p.distance_to(nb_p)
			var nb_exp := node_exp[nb]
			if nb_exp == 0:
				nb_exp = 1 if (nb_p.distance_squared_to(threat_arc) <= safe_band2 or arc_seg_occluded_rects(nb_p, threat_arc, rects)) else 2
				node_exp[nb] = nb_exp
			if nb_exp == 2:
				step_cost += COVER_EXPOSURE_PENALTY
			if cur_exp == 2 or nb_exp == 2:
				var mid := (cur_p + nb_p) * 0.5
				if mid.distance_squared_to(threat_arc) > safe_band2 and not arc_seg_occluded_rects(mid, threat_arc, rects):
					step_cost += COVER_MID_EXPOSURE_PENALTY
			var tent := float(g_score[cur]) + step_cost
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + nb_p.distance_to(goal_p)
				if not nb in open:
					open.append(nb)
	return out


func _find_arc_path(from_arc: Vector2, to_arc: Vector2, rects: Array[Rect2] = [], cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _graph_nodes.is_empty() or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_nav_node(from_arc, rects, PackedByteArray(), cuts)
	var g := _nearest_nav_node(to_arc, rects, PackedByteArray(), cuts)
	if s < 0 or g < 0:
		return out
	if s == g:
		return _same_node_path(from_arc, to_arc, g, rects, cuts)
	var res := _astar_arc(from_arc, s, g, rects, cuts)
	if not res.is_empty():
		return res
	# Fallback when a ramp floor cut splits `s` into a disconnected stub: re-pick `s` inside `g`'s connected component.
	var comp := _component_mask(g)
	var s2 := _nearest_nav_node(from_arc, rects, comp, cuts)
	if s2 >= 0 and s2 != s:
		if s2 == g:
			return _same_node_path(from_arc, to_arc, g, rects, cuts)
		res = _astar_arc(from_arc, s2, g, rects, cuts)
		if not res.is_empty():
			return res
	return out


## Start and goal snap to the same crossing `g` (they can still be 50-60 m apart: both near one big crossing): reachable.
## Straight to the goal when that line crosses no building and no floor cut (no detour back to the crossing), else via
## the crossing. Like every path here it ends at (or near) the goal; callers steer the last stretch to the goal itself.
func _same_node_path(from_arc: Vector2, to_arc: Vector2, g: int, rects: Array[Rect2], cuts: Array[Rect2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if (rects.is_empty() or not arc_seg_occluded_rects(from_arc, to_arc, rects)) \
			and (cuts.is_empty() or not seg_crosses_cuts(from_arc, to_arc, cuts)):
		out.append(to_arc)
	else:
		out.append(_graph_nodes[g])
	return out


func _astar_arc(from_arc: Vector2, s: int, g: int, rects: Array[Rect2], cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
	# Small graph (~25-60 crossings): clean deterministic A*.
	var open: Array[int] = [s]
	var came := {}
	var g_score := {s: 0.0}
	var f_score := {s: _graph_nodes[s].distance_to(_graph_nodes[g])}
	var closed := {}
	while not open.is_empty():
		var best_i := 0
		var best_f := float(f_score.get(open[0], INF))
		for k in range(1, open.size()):
			var fk := float(f_score.get(open[k], INF))
			if fk < best_f:
				best_f = fk
				best_i = k
		var cur := open[best_i]
		if cur == g:
			var rev: Array[Vector2] = []
			var node := cur
			while came.has(node):
				rev.append(_graph_nodes[node])
				node = int(came[node])
			rev.reverse()
			return _finalize_arc_path(from_arc, s, rev, rects, cuts)
		open.remove_at(best_i)
		closed[cur] = true
		for nb: int in _graph_adj[cur]:
			if closed.has(nb):
				continue
			var tent := float(g_score[cur]) + _graph_nodes[cur].distance_to(_graph_nodes[nb])
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + _graph_nodes[nb].distance_to(_graph_nodes[g])
				if not nb in open:
					open.append(nb)
	return out
