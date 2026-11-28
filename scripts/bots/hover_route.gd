class_name HoverRoute
extends RefCounted
## Standalone 3D hover route planner for the Wasp flying player mech (docs/design/wasp-ai.md §2, chassis-rules.md §7.2).
## Pure data over SectionPlan + per-deck CityPlan (no physics, no network state, deterministic):
##   - Same-deck direct over-roof flight whenever all crossed tiers clear `hover_ceiling` (`clear_altitude`), routing
##     laterally around full-height pillars / towers via the deck's airway graph + string-pulling.
##   - Two-way inter-deck transit through ceiling shafts / atriums (both UP and DOWN, unlike walker shafts) and ramps.
##   - Nearest safe landing surface lookup (`safe_landing_spot`: clear street/plaza OR standable roof tier) for
##     pre-overheat safe descent onto Wasp's mini-legs before heat shutdown.
##
## Coordinates: per-deck arc metres `(x, s)` plus altitude `alt` (m above that deck's floor) and `(x, theta)` matching
## `BotRoutePlanner` conventions (`theta = s / sec.radius_of(deck)`). Ready to plug into `BotRoutePlanner` / `PlayerBot`
## once Wasp's hover controller lands.

const DEFAULT_CEILING := 28.0       ## m max hover height above deck floor (below SectionPlan clear_height ~36 m)
const CRUISE_ALT := 12.0            ## m default travel altitude above deck floor
const COMBAT_ALT_LOW := 10.0        ## m lower combat hover band
const COMBAT_ALT_HIGH := 18.0       ## m upper combat hover band
const CLEAR_VERT := 4.5             ## m vertical clearance kept above crossed building roofs
const HOVER_RADIUS := 3.5           ## m horizontal safety margin around Wasp's four ducted fans
const LAND_CLEAR_R := 3.2           ## m clear footprint radius needed to land on mini-legs
const SHAFT_COST := 26.0            ## m equivalent cost for a vertical shaft transit (preferred over long ramps)
const RAMP_COST := 42.0             ## m equivalent cost for flying through a ramp slot
const PRE_OVERHEAT_HEAT := 0.78     ## heat fraction at which Wasp descends toward a safe landing spot

var sec: SectionPlan = null
var plans: Array[CityPlan] = []
var ceiling := DEFAULT_CEILING
var _obstacles: Array = []          ## per deck: Array[{rect: Rect2, h: float, tall: bool}]
var _tall_rects: Array = []         ## per deck: Array[Rect2] grown by HOVER_RADIUS (fast 2D lateral reject)
var _roof_pads: Array = []          ## per deck: Array[{rect: Rect2, h: float}] standable flat roofs for safe landing
var _nodes_deck: Array[int] = []    ## airway graph node -> deck index
var _nodes_arc: Array[Vector2] = [] ## airway graph node -> (x, s) on its deck
var _by_deck: Array = []            ## per deck: Array[int] node indices
var _adj: Array = []                ## node -> Array[{to: int, cost: float, alt: float, kind: String}]


func net_fields() -> Dictionary:
	return {
		"sec": Net.LOCAL, "plans": Net.LOCAL, "ceiling": Net.PRIVATE,
		"_obstacles": Net.PRIVATE, "_tall_rects": Net.PRIVATE, "_roof_pads": Net.PRIVATE,
		"_nodes_deck": Net.PRIVATE, "_nodes_arc": Net.PRIVATE, "_by_deck": Net.PRIVATE, "_adj": Net.PRIVATE,
	}


func setup(st: CityStack, hover_ceiling: float = DEFAULT_CEILING) -> void:
	var ps: Array[CityPlan] = []
	for d in st.decks:
		ps.append(d.plan)
	setup_plans(st.section, ps, hover_ceiling)


func setup_plans(section: SectionPlan, deck_plans: Array[CityPlan], hover_ceiling: float = DEFAULT_CEILING) -> void:
	sec = section
	plans = deck_plans.duplicate()
	var max_c := sec.clear_height() - 5.0 if sec != null else DEFAULT_CEILING
	ceiling = clampf(hover_ceiling, 10.0, maxf(max_c, 12.0))
	_obstacles.clear()
	_tall_rects.clear()
	_roof_pads.clear()
	_nodes_deck.clear()
	_nodes_arc.clear()
	_by_deck.clear()
	_adj.clear()
	var n := plans.size()
	for k in n:
		_obstacles.append([])
		_tall_rects.append([] as Array[Rect2])
		_roof_pads.append([])
		_by_deck.append([] as Array[int])
		_extract_deck_geometry(k, plans[k])
		_build_deck_airways(k, plans[k])
	if sec != null:
		_build_interdeck_links()


func _extract_deck_geometry(k: int, p: CityPlan) -> void:
	if p == null:
		return
	var obs: Array = _obstacles[k]
	var talls: Array[Rect2] = _tall_rects[k]
	var pads: Array = _roof_pads[k]
	for b: Dictionary in p.buildings:
		var bc: Vector2 = b["center"]
		var has_pillar := bool(b.get("pillar", false))
		var p_rect := Rect2()
		if has_pillar:
			var core: Dictionary = b["core"]
			var csz: Vector2 = core["size"]
			var cc := Vector2(float(core["x"]), float(core["s"]))
			p_rect = Rect2(cc - csz * 0.5, csz)
			obs.append({"rect": p_rect, "h": 99.0, "tall": true})
			talls.append(p_rect.grow(HOVER_RADIUS))
		var tiers: Array = b.get("tiers", [])
		for ti in tiers.size():
			var t: Dictionary = tiers[ti]
			var y1 := float(t["y1"]) + CityPlan.CURB_H
			var sz: Vector2 = t["size"]
			var tc := bc + (t["off"] as Vector2)
			var rr := Rect2(tc - sz * 0.5, sz)
			var is_tall := (y1 + CLEAR_VERT) > ceiling
			obs.append({"rect": rr, "h": y1, "tall": is_tall})
			if is_tall:
				talls.append(rr.grow(HOVER_RADIUS))
			# Top standable flat roof (not a plant bulkhead, fits mini-legs, clear of pillar shaft).
			if ti == tiers.size() - 1 and bool(t.get("stand", true)) and str(t.get("kind", "")) != "plant":
				if sz.x >= LAND_CLEAR_R * 2.4 and sz.y >= LAND_CLEAR_R * 2.4 and y1 + 3.0 <= ceiling:
					if not has_pillar or not p_rect.grow(LAND_CLEAR_R).has_point(tc):
						pads.append({"rect": rr, "h": y1})
	for col: Dictionary in p.columns:
		var half := float(col["half"])
		var cc := Vector2(float(col["x"]), float(col["s"]))
		var cr := Rect2(cc - Vector2.ONE * half, Vector2.ONE * (half * 2.0))
		obs.append({"rect": cr, "h": 99.0, "tall": true})
		talls.append(cr.grow(HOVER_RADIUS))


func _add_node(k: int, arc: Vector2) -> int:
	# Merge near-duplicate nodes on the same deck (within 3 m) to keep the airway graph compact.
	for idx: int in _by_deck[k]:
		if _nodes_arc[idx].distance_squared_to(arc) <= 9.0:
			return idx
	var id := _nodes_arc.size()
	_nodes_deck.append(k)
	_nodes_arc.append(arc)
	_adj.append([])
	(_by_deck[k] as Array).append(id)
	return id


func _add_edge(a: int, b: int, cost: float, alt: float, kind: String) -> void:
	if a == b or a < 0 or b < 0:
		return
	(_adj[a] as Array).append({"to": b, "cost": cost, "alt": alt, "kind": kind})


func _build_deck_airways(k: int, p: CityPlan) -> void:
	if p == null:
		return
	var rg := CityGraphs.road_graph(p)
	var rnodes: Array = rg.get("nodes", [])
	var map: Array[int] = []
	map.resize(rnodes.size())
	for i in rnodes.size():
		map[i] = _add_node(k, rnodes[i] as Vector2)
	for ed: Array in rg.get("edges", []):
		var ia := map[int(ed[0])]
		var ib := map[int(ed[1])]
		var alt := clear_altitude(k, _nodes_arc[ia], _nodes_arc[ib], CRUISE_ALT)
		if alt > 0.0:
			var d := _nodes_arc[ia].distance_to(_nodes_arc[ib])
			_add_edge(ia, ib, d, alt, "fly")
			_add_edge(ib, ia, d, alt, "fly")


func _build_interdeck_links() -> void:
	var n := plans.size()
	for ci in sec.connectors.size():
		var cn: Dictionary = sec.connectors[ci]
		var kind := str(cn.get("kind", ""))
		if kind == "shaft":
			# Two-way vertical shaft / atrium transit: Wasp can climb UP or descend DOWN between any adjacent
			# decks connected by this open shaft (and stop on any intermediate deck along an atrium!).
			var k_top := int(cn["from"])
			var hole := sec.connector_rect(ci, k_top)
			var c_top := hole.get_center()
			var th := c_top.y / sec.radius_of(k_top)
			# Walk down through stacked shaft openings until the first solid deck below.
			var chain_decks: Array[int] = [k_top]
			var j := k_top + 1
			while j < n:
				chain_decks.append(j)
				var pt_j := Vector2(c_top.x, th * sec.radius_of(j))
				if not _in_floor_cut(j, pt_j, 0.5):
					break
				j += 1
			var chain_nodes: Array[int] = []
			for dk in chain_decks:
				var pt := Vector2(c_top.x, th * sec.radius_of(dk))
				var nid := _add_node(dk, pt)
				_link_node_to_deck(dk, nid)
				chain_nodes.append(nid)
			for idx in chain_nodes.size() - 1:
				var u := chain_nodes[idx]
				var v := chain_nodes[idx + 1]
				_add_edge(u, v, SHAFT_COST, CRUISE_ALT, "shaft_down")
				_add_edge(v, u, SHAFT_COST + 4.0, CRUISE_ALT, "shaft_up")
		elif kind == "ramp":
			var fk := int(cn["from"])
			var tk := int(cn["to"])
			if fk < 0 or fk >= n or tk < 0 or tk >= n:
				continue
			var lx := sec.lane_x(str(cn["lane"]))
			var xc := (lx.x + lx.y) * 0.5
			var s_top := sec.ramp_run(ci, fk).x     # the slope's ends (SectionPlan.ramp_run), not the cross lines
			var s_foot := sec.ramp_run(ci, tk).y
			var a := _add_node(fk, Vector2(xc, s_top))
			var b := _add_node(tk, Vector2(xc, s_foot))
			_link_node_to_deck(fk, a)
			_link_node_to_deck(tk, b)
			var r_cost := absf(s_top - s_foot) + RAMP_COST
			_add_edge(a, b, r_cost, CRUISE_ALT, "ramp_fly")
			_add_edge(b, a, r_cost + 4.0, CRUISE_ALT, "ramp_fly")


func _link_node_to_deck(k: int, nid: int) -> void:
	var p := _nodes_arc[nid]
	var cands: Array = []
	for other: int in _by_deck[k]:
		if other == nid:
			continue
		var d := p.distance_to(_nodes_arc[other])
		if d <= 180.0:
			cands.append([d, other])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var linked := 0
	for item: Array in cands:
		var other := int(item[1])
		var alt := clear_altitude(k, p, _nodes_arc[other], CRUISE_ALT)
		if alt > 0.0:
			var d := float(item[0])
			_add_edge(nid, other, d, alt, "fly")
			_add_edge(other, nid, d, alt, "fly")
			linked += 1
			if linked >= 4:
				break


func _in_floor_cut(k: int, pt: Vector2, grow: float = 0.0) -> bool:
	if k < 0 or k >= plans.size() or plans[k] == null or plans[k].site == null:
		return false
	for r: Rect2 in plans[k].floor_cuts():
		if r.grow(grow).has_point(pt):
			return true
	return false


## Minimum safe flight altitude above deck `deck` to fly straight from `a` to `b` (`>= min_alt`), clearing all crossed
## building roofs by `CLEAR_VERT`. Returns -1.0 if the segment intersects a full-height pillar/tower above `ceiling`.
func clear_altitude(deck: int, a: Vector2, b: Vector2, min_alt: float = CRUISE_ALT) -> float:
	if deck < 0 or deck >= _obstacles.size():
		return min_alt
	var alt := clampf(min_alt, 4.0, ceiling)
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * (HOVER_RADIUS + 0.5)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * (HOVER_RADIUS + 0.5)
	for tr: Rect2 in _tall_rects[deck]:
		if hi.x < tr.position.x or lo.x > tr.end.x or hi.y < tr.position.y or lo.y > tr.end.y:
			continue
		if _seg_hits_rect(a, b, tr):
			return -1.0
	for item: Dictionary in _obstacles[deck]:
		if bool(item["tall"]):
			continue
		var need := float(item["h"]) + CLEAR_VERT
		if need <= alt:
			continue
		var r: Rect2 = (item["rect"] as Rect2).grow(HOVER_RADIUS)
		if hi.x < r.position.x or lo.x > r.end.x or hi.y < r.position.y or lo.y > r.end.y:
			continue
		if _seg_hits_rect(a, b, r):
			if need > ceiling:
				return -1.0
			alt = need
	return alt


## Plan a 3D hover route from `(from_deck, from_arc)` to `(to_deck, to_arc)`.
## Returns Array[{deck: int, arc: Vector2, xt: Vector2, alt: float, kind: String}]. Empty if unreachable.
func plan(from_deck: int, from_arc: Vector2, to_deck: int, to_arc: Vector2,
		cruise_alt: float = CRUISE_ALT) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if from_deck < 0 or from_deck >= plans.size() or to_deck < 0 or to_deck >= plans.size():
		return out
	# Same-deck fast path: fly straight over roofs whenever no full-height pillar/tower blocks the line!
	if from_deck == to_deck:
		var direct_alt := clear_altitude(from_deck, from_arc, to_arc, cruise_alt)
		if direct_alt > 0.0:
			out.append(_wp(from_deck, to_arc, direct_alt, "fly"))
			return out
	# Multi-deck or tower-avoidance A* over the airway graph.
	var starts := _attach_points(from_deck, from_arc, cruise_alt)
	var goals := _attach_points(to_deck, to_arc, cruise_alt)
	if starts.is_empty() or goals.is_empty():
		return out
	var goal_map := {}   # node_id -> {cost, alt}
	for g_item: Dictionary in goals:
		goal_map[int(g_item["node"])] = g_item
	var open: Array[int] = []
	var g_score := {}
	var f_score := {}
	var came := {}       # node_id -> {prev: int, alt: float, kind: String}
	var closed := {}
	for s_item: Dictionary in starts:
		var nid := int(s_item["node"])
		var sc := float(s_item["cost"])
		g_score[nid] = sc
		f_score[nid] = sc + _heuristic(nid, to_deck, to_arc)
		came[nid] = {"prev": -1, "alt": float(s_item["alt"]), "kind": "fly"}
		open.append(nid)
	var best_goal := -1
	var best_total := INF
	while not open.is_empty():
		var bi := 0
		var bf := float(f_score.get(open[0], INF))
		for i in range(1, open.size()):
			var fi := float(f_score.get(open[i], INF))
			if fi < bf:
				bf = fi
				bi = i
		var cur := open[bi]
		if bf >= best_total:
			break
		open.remove_at(bi)
		if closed.has(cur):
			continue
		closed[cur] = true
		if goal_map.has(cur):
			var tot := float(g_score[cur]) + float((goal_map[cur] as Dictionary)["cost"])
			if tot < best_total:
				best_total = tot
				best_goal = cur
		for ed: Dictionary in _adj[cur]:
			var nb := int(ed["to"])
			if closed.has(nb):
				continue
			var tent := float(g_score[cur]) + float(ed["cost"])
			if tent < float(g_score.get(nb, INF)):
				g_score[nb] = tent
				f_score[nb] = tent + _heuristic(nb, to_deck, to_arc)
				came[nb] = {"prev": cur, "alt": maxf(float(ed["alt"]), cruise_alt), "kind": str(ed["kind"])}
				if not (nb in open):
					open.append(nb)
	if best_goal < 0:
		return out
	# Reconstruct waypoint list.
	var rev: Array[Dictionary] = []
	var g_entry: Dictionary = goal_map[best_goal]
	rev.append(_wp(to_deck, to_arc, maxf(float(g_entry["alt"]), cruise_alt), "fly"))
	var cur_n := best_goal
	while cur_n >= 0:
		var cinfo: Dictionary = came[cur_n]
		rev.append(_wp(_nodes_deck[cur_n], _nodes_arc[cur_n], float(cinfo["alt"]), str(cinfo["kind"])))
		cur_n = int(cinfo["prev"])
	rev.reverse()
	return _simplify_route(from_deck, from_arc, rev, cruise_alt)


func _simplify_route(start_deck: int, start_arc: Vector2, raw: Array[Dictionary], cruise_alt: float) -> Array[Dictionary]:
	if raw.size() <= 1:
		return raw
	var out: Array[Dictionary] = []
	var cur_deck := start_deck
	var cur_arc := start_arc
	var i := 0
	while i < raw.size():
		# Never collapse inter-deck transitions (shaft_up / shaft_down / ramp_fly).
		if str(raw[i]["kind"]) != "fly" or int(raw[i]["deck"]) != cur_deck:
			out.append(raw[i])
			cur_deck = int(raw[i]["deck"])
			cur_arc = raw[i]["arc"] as Vector2
			i += 1
			continue
		# String-pull: skip intermediate same-deck "fly" nodes if a direct line clears all tall obstacles!
		var furthest := i
		var best_alt := float(raw[i]["alt"])
		var j := i + 1
		while j < raw.size() and str(raw[j]["kind"]) == "fly" and int(raw[j]["deck"]) == cur_deck:
			var cand_alt := clear_altitude(cur_deck, cur_arc, raw[j]["arc"] as Vector2, cruise_alt)
			if cand_alt > 0.0:
				furthest = j
				best_alt = cand_alt
			j += 1
		var chosen := raw[furthest].duplicate()
		chosen["alt"] = best_alt
		out.append(chosen)
		cur_arc = chosen["arc"] as Vector2
		i = furthest + 1
	return out


func _attach_points(deck: int, arc: Vector2, cruise_alt: float) -> Array[Dictionary]:
	var cands: Array = []
	for nid: int in _by_deck[deck]:
		var d := arc.distance_to(_nodes_arc[nid])
		cands.append([d, nid])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var out: Array[Dictionary] = []
	for item: Array in cands:
		var nid := int(item[1])
		var alt := clear_altitude(deck, arc, _nodes_arc[nid], cruise_alt)
		if alt > 0.0:
			out.append({"node": nid, "cost": float(item[0]), "alt": alt})
			if out.size() >= 6:
				break
	# Fallback if standing right inside a pillar's clearance margin: attach to closest airway node.
	if out.is_empty() and not cands.is_empty():
		out.append({"node": int((cands[0] as Array)[1]), "cost": float((cands[0] as Array)[0]) + 10.0, "alt": cruise_alt})
	return out


func _heuristic(nid: int, to_deck: int, to_arc: Vector2) -> float:
	var dk := _nodes_deck[nid]
	var a := _nodes_arc[nid]
	if dk == to_deck:
		return a.distance_to(to_arc)
	var a_on_to := Vector2(a.x, (a.y / sec.radius_of(dk)) * sec.radius_of(to_deck)) if sec != null else a
	return a_on_to.distance_to(to_arc) + absf(float(dk - to_deck)) * SHAFT_COST


func _wp(deck: int, arc: Vector2, alt: float, kind: String) -> Dictionary:
	var th := arc.y / sec.radius_of(deck) if sec != null else arc.y
	return {"deck": deck, "arc": arc, "xt": Vector2(arc.x, th), "alt": alt, "kind": kind}


## Nearest unobstructed landing spot on `deck` for pre-overheat descent onto Wasp's mini-legs:
## prefers a flat standable roof right underneath (minimal drop) or a clear street/plaza spot.
## Returns {found: bool, arc: Vector2, surface_h: float, kind: "roof" | "street"}.
func safe_landing_spot(deck: int, near_arc: Vector2, max_search_r: float = 48.0) -> Dictionary:
	if deck < 0 or deck >= plans.size() or plans[deck] == null:
		return {"found": false, "arc": near_arc, "surface_h": 0.0, "kind": "street"}
	var p := plans[deck]
	var best_found := false
	var best_arc := near_arc
	var best_h := CityPlan.CURB_H
	var best_kind := "street"
	var best_d := INF
	# 1. Check flat standable rooftops within `max_search_r` (often directly beneath a hovering Wasp!).
	for pad: Dictionary in _roof_pads[deck]:
		var r: Rect2 = pad["rect"]
		var inner := r.grow(-LAND_CLEAR_R)
		if inner.size.x <= 0.0 or inner.size.y <= 0.0:
			continue
		var clamped := Vector2(clampf(near_arc.x, inner.position.x, inner.end.x),
			clampf(near_arc.y, inner.position.y, inner.end.y))
		var d := near_arc.distance_to(clamped)
		if d <= max_search_r and d < best_d:
			best_d = d
			best_found = true
			best_arc = clamped
			best_h = float(pad["h"])
			best_kind = "roof"
	# 2. Check clear street / plaza ground directly below or in expanding rings.
	if _is_clear_street(p, near_arc):
		if 0.0 < best_d:
			return {"found": true, "arc": near_arc, "surface_h": CityPlan.CURB_H, "kind": "street"}
	for ring_r: float in [6.0, 12.0, 20.0, 30.0, 42.0]:
		if ring_r > max_search_r or ring_r >= best_d:
			break
		for k in 8:
			var ang := float(k) * (TAU / 8.0)
			var cand := near_arc + Vector2(cos(ang), sin(ang)) * ring_r
			if _is_clear_street(p, cand):
				best_d = ring_r
				best_found = true
				best_arc = cand
				best_h = CityPlan.CURB_H
				best_kind = "street"
				break
	return {"found": best_found, "arc": best_arc, "surface_h": best_h, "kind": best_kind}


func _is_clear_street(p: CityPlan, pt: Vector2) -> bool:
	if not p.extent.grow(-maxf(LAND_CLEAR_R + 1.5, 4.0)).has_point(pt):
		return false
	if not EnemySpawner.clear_of_buildings(p, pt, LAND_CLEAR_R, 0.0):
		return false
	return EnemySpawner._clear_of_ramps(p, pt, LAND_CLEAR_R)


## Recommended target altitude (m above deck floor) combining route/combat goal, pre-overheat descent, and fan loss.
func desired_altitude(deck: int, cur_arc: Vector2, goal_alt: float, heat_frac: float, can_fly: bool) -> float:
	if not can_fly:
		return 0.0
	if heat_frac >= PRE_OVERHEAT_HEAT:
		var spot := safe_landing_spot(deck, cur_arc, 24.0)
		var surf := float(spot["surface_h"]) if bool(spot["found"]) else CityPlan.CURB_H
		return surf + 2.5
	return clampf(goal_alt, 4.0, ceiling)


static func _seg_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
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
