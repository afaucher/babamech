class_name LifePlan
extends RefCounted
## Ambient life as plain data (docs/design/ambient-life.md sections 3 and 8): everything the civilians of one CityPlan need,
## derived from the plan and its seed alone, so every machine builds the same and checksum() proves it.
##
##   nodes / edges       the sidewalk walk graph: a walkway lane round every block (WALK_IN in from the curb), with the
##                       doors and benches as nodes on it, and a zebra crossing between facing block corners at every
##                       junction. edges: [a, b, kind (WALK | CROSS), junction, axis, length]
##   doors               one per building front that faces a street: [{id, building, at (on the facade), node, block}]
##   benches             the street benches of CityPropLayout.layout: [{id, prop, at, yaw, node}]
##   junctions           [{id, at, phase}]: a fixed signal cycle on the shared clock, offset per junction. Axis 0 = the
##                       crossings that walk along x (across a road running along s), axis 1 = along s.
##   people              [{id, period, phase, speed, cloth, build, tall}]
##
## The timetable is closed form: time is cut into slots of `period` s per person; in slot k the person leaves a door picked
## from (seed, id, k), walks the sidewalks to another door (crossing only on green, waiting at the corner otherwise),
## sometimes stopping at a bench for 20-60 s on the way, and is indoors the rest of the slot. calm_pose(id, t) is a pure
## function of (seed, id, t). No person ever senses another in calm state.
## Arc coordinates throughout (x along the axis, s along the arc), like CityPlan.

const WALK := 0
const WAIT := 1
const SIT := 2
const CROSS := 3

const WALK_IN := 3.0          ## walkway lane, metres in from the curb (the walkway is 1.6..4.0)
const DOOR_OUT := 0.3         ## a door point stands this far out of the facade
const CYCLE := 60.0           ## s, one signal cycle at every junction
const GREEN := 22.0           ## s of walk signal per axis per cycle (axis 1 starts half a cycle after axis 0); the rest
                              ## of each half (8 s) is all-walk-red: the turn phase for vehicles (LifeTraffic)
const CROSS_COST := 4.0       ## m added to a crossing when routing (people avoid needless zigzags)
const PEOPLE_DEFAULT := 24    ## for the 220 x 240 m district, scaled by area
const PEOPLE_CAP := 60
const RIDERS := 8             ## pod passengers who can get out, on top of the people cap
const LEG := 11               ## floats per timetable leg: t0 t1 ax as bx bs kind d0 heading na nb

var plan: CityPlan
var seed := 0
var count := 0
var nodes := PackedVector2Array()
var edges: Array = []
var adj: Array = []           ## node -> Array of edge indices
var doors: Array = []
var benches: Array = []
var junctions: Array = []
var people: Array = []
var riders: Array = []        ## pod passengers (see _build_people)
## Section mode only (phase 3; the tram on the top deck only since R2.11, elsewhere tram null and rail_edges empty): the deck's tram (its timetable decides when people may cross the rail lane) and the
## crossings over the spine. A spine crossing runs along a cross street's line (not the zebra beside the junction, which
## would cross the ramp-lane floor cuts and the rail lane away from a cross street) in three pieces: the ramp_a lane
## (junction -1: no signal, no traffic), the avenue (the spine junction's walk signal) and the rail + ramp_b lanes
## (junction -1, an entry in rail_edges: started only when the tram's timetable keeps it 40 m clear for the whole piece).
var tram: LifeTram
var rail_edges: Dictionary = {}   ## edge index -> s of its cross line

var _edge_at: Dictionary = {}     ## Vector2i(min node, max node) -> edge index
var _trees: Dictionary = {}       ## root node -> [dist PackedFloat32Array, prev PackedInt32Array] (memo)
var _trips: Dictionary = {}       ## Vector2i(id, slot) -> trip (memo)
var _block_rects: Array[Rect2] = []
var _cuts: Array[Rect2] = []      ## section mode: the floor cuts, grown by the curb and a person (nobody walks in one)
var _split: Dictionary = {}       ## section mode: Vector2i(corner a, corner b) of a cross-street crossing -> the node the
                                  ## spine crossing leaves it from
## Crowd spacing (docs/design/ambient-life.md "Crowd spacing"): all derived from the plan, the timetable and the person's
## id, so every machine computes the same with no messages.
var _props: Array = []            ## street-level props [Vector2 at, radius] (standing slots keep clear of them)
var _foot: Array[Rect2] = []      ## building footprints
var _node_slots: Dictionary = {}  ## node -> {next node -> PackedVector2Array standing slots} (memo, whole node at once)
var _bench_slots: Dictionary = {} ## bench -> [seats PackedVector2Array (2), standing PackedVector2Array] (memo)
var _index: Dictionary = {}       ## index window -> {group key (Vector3i) -> Array of [t0, id], sorted} (memo)
var _index_wip: Dictionary = {}   ## index window being built ahead -> [people done PackedByteArray, groups so far]
var _wishes: Dictionary = {}      ## Vector2i(id, slot) -> the wished trip, before the bench capacity (memo)
var _wish_index: Dictionary = {}  ## index window -> {bench -> [[arrival, id]] sorted}: who wishes to stop there (memo)
var _wish_wip: Dictionary = {}    ## ... being built ahead
var _obst: Dictionary = {}        ## Vector2i 4 m cell -> [[kind, data...]] what a standing slot keeps clear of (memo)
var _open_lots: Array = []        ## the open lots (parks, plazas, gardens)


func net_fields() -> Dictionary:
	return {
		"plan": Net.SPAWN, "seed": Net.SPAWN, "count": Net.SPAWN,     # the mission seed and the people param
		# derived from the plan on every machine, verified by checksum()
		"nodes": Net.LOCAL, "edges": Net.LOCAL, "adj": Net.LOCAL, "doors": Net.LOCAL, "benches": Net.LOCAL,
		"junctions": Net.LOCAL, "people": Net.LOCAL, "riders": Net.LOCAL, "tram": Net.LOCAL, "rail_edges": Net.LOCAL,
		"_edge_at": Net.LOCAL, "_trees": Net.LOCAL, "_trips": Net.LOCAL, "_block_rects": Net.LOCAL, "_cuts": Net.LOCAL,
		"_split": Net.LOCAL,
		# crowd spacing: pure functions of the plan / timetable, the same on every machine
		"_props": Net.LOCAL, "_foot": Net.LOCAL, "_node_slots": Net.LOCAL, "_bench_slots": Net.LOCAL, "_index": Net.LOCAL,
		"_index_wip": Net.LOCAL, "_obst": Net.LOCAL, "_open_lots": Net.LOCAL, "_wishes": Net.LOCAL, "_wish_index": Net.LOCAL,
		"_wish_wip": Net.LOCAL,
	}


## `people` < 0: PEOPLE_DEFAULT scaled by the district's area. Always capped at PEOPLE_CAP (`cap`: only the crowd lab
## passes a higher one, through AmbientLife.debug_people_cap; the game never does).
static func make(p: CityPlan, people_count: int = -1, cap: int = PEOPLE_CAP) -> LifePlan:
	var lp := LifePlan.new()
	lp.build(p, people_count, cap)
	return lp


static func default_count(p: CityPlan) -> int:
	return clampi(int(round(float(PEOPLE_DEFAULT) * p.p("size_x") * p.p("size_s") / (220.0 * 240.0))), 1, PEOPLE_CAP)


func build(p: CityPlan, people_count: int = -1, cap: int = PEOPLE_CAP) -> void:
	plan = p
	seed = int(p.p("seed")) * 15485863 + 7
	count = clampi(people_count if people_count >= 0 else default_count(p), 0, maxi(cap, 0))
	nodes.clear()
	edges.clear()
	adj.clear()
	doors.clear()
	benches.clear()
	junctions.clear()
	people.clear()
	riders.clear()
	_edge_at.clear()
	_trees.clear()
	_trips.clear()
	_block_rects.clear()
	rail_edges.clear()
	_cuts.clear()
	_split.clear()
	_props.clear()
	_foot.clear()
	_node_slots.clear()
	_bench_slots.clear()
	_index.clear()
	_index_wip.clear()
	_wishes.clear()
	_wish_index.clear()
	_wish_wip.clear()
	_obst.clear()
	_open_lots.clear()
	tram = null
	for b: Dictionary in p.blocks:
		_block_rects.append(b["rect"])
	for b: Dictionary in p.buildings:
		if not (b["tiers"] as Array).is_empty():
			_foot.append(Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"]))
	if p.section != null:
		tram = LifeTram.make(p, h(9100, p.deck))
		for o in p.floor_cuts():
			_cuts.append(o.grow(CityDims.HOLE_CURB + 0.4))
	_build_junctions()
	_build_graph()
	if tram == null:
		rail_edges.clear()       # no tram on this deck (only a section's top deck has one): no rail crossing rule
	_build_people()


# --- Hashing ---------------------------------------------------------------------------------------------

static func mix(x: int) -> int:
	x = (x ^ (x >> 30)) * -4658895280553007687
	x = (x ^ (x >> 27)) * -7723592293110705685
	return x ^ (x >> 31)


## A deterministic number in [0, 1) from the seed and up to three ints.
func h(a: int, b: int = 0, c: int = 0) -> float:
	return float(mix(seed * 1000003 + mix(a * 7919 + mix(b * 104729 + mix(c + 31)))) & 0xFFFFFF) / 16777216.0


# --- Junctions -------------------------------------------------------------------------------------------

func _build_junctions() -> void:
	var ns := plan.roads_s.size()
	for i in plan.roads_x.size():
		for j in ns:
			var id := i * ns + j
			junctions.append({"id": id, "phase": h(9001, id) * CYCLE,
					"at": Vector2((float(plan.roads_x[i]["a"]) + float(plan.roads_x[i]["b"])) * 0.5,
							(float(plan.roads_s[j]["a"]) + float(plan.roads_s[j]["b"])) * 0.5)})


## Whether the crossings of `axis` at junction `j` show walk at time t.
func green(j: int, axis: int, t: float) -> bool:
	return fposmod(t - float(junctions[j]["phase"]) - float(axis) * CYCLE * 0.5, CYCLE) < GREEN


## The earliest time >= t at which a crossing of `axis` at `j` that takes `need` seconds fits inside one walk signal.
func next_green(j: int, axis: int, t: float, need: float) -> float:
	need = minf(need, GREEN)
	var u := fposmod(t - float(junctions[j]["phase"]) - float(axis) * CYCLE * 0.5, CYCLE)
	if u + need <= GREEN:
		return t
	return t + (CYCLE - u)


## Whether junction `j` is in a turn phase (no walk signal on either axis) at time t.
func all_red(j: int, t: float) -> bool:
	return fposmod(t - float(junctions[j]["phase"]), CYCLE * 0.5) >= GREEN


## The earliest time >= t at which a movement of `need` seconds fits inside one turn phase of junction `j`.
func next_all_red(j: int, t: float, need: float) -> float:
	var half := CYCLE * 0.5
	need = minf(need, half - GREEN)
	var u := fposmod(t - float(junctions[j]["phase"]), half)
	if u >= GREEN and u + need <= half:
		return t
	if u < GREEN:
		return t + (GREEN - u)
	return t + (half - u) + GREEN


## Building footprints (read-only view).
func foot() -> Array[Rect2]:
	return _foot


## Section mode: the grown floor cuts (read-only view).
func cuts() -> Array[Rect2]:
	return _cuts


func junction_near(at: Vector2) -> int:
	var bi := 0
	var bd := INF
	for j in junctions.size():
		var d := (junctions[j]["at"] as Vector2).distance_squared_to(at)
		if d < bd:
			bd = d
			bi = j
	return bi


# --- Graph -----------------------------------------------------------------------------------------------

func _add_node(at: Vector2) -> int:
	nodes.append(at)
	adj.append([])
	return nodes.size() - 1


func _add_edge(a: int, b: int, kind: int, junction: int = -1, axis: int = -1) -> void:
	if a == b:
		return
	var key := Vector2i(mini(a, b), maxi(a, b))
	if _edge_at.has(key):
		return
	if not _cuts.is_empty() and _hits(_cuts, nodes[a], nodes[b]):
		return          # section mode: no way across a floor cut (a ramp's hole, a shaft)
	var e := edges.size()
	edges.append([a, b, kind, junction, axis, nodes[a].distance_to(nodes[b])])
	_edge_at[key] = e
	(adj[a] as Array).append(e)
	(adj[b] as Array).append(e)


## Whether the segment a -> b passes through any of the rects (sampled every 0.5 m).
static func _hits(rects: Array[Rect2], a: Vector2, b: Vector2) -> bool:
	var n := maxi(int(ceil(a.distance_to(b) / 0.5)), 1)
	for k in n + 1:
		var p := a.lerp(b, float(k) / float(n))
		for r in rects:
			if r.has_point(p):
				return true
	return false


## The edge between two nodes, or -1.
func edge_between(a: int, b: int) -> int:
	return int(_edge_at.get(Vector2i(mini(a, b), maxi(a, b)), -1))


## The walkway lane rectangle of a block.
static func lane_rect(block_rect: Rect2) -> Rect2:
	return block_rect.grow(-WALK_IN)


## The point on side `side` of lane rect L closest to `at`, and the position along that side (from its low corner).
static func _on_side(lane: Rect2, side: int, at: Vector2) -> Vector2:
	match side:
		0: return Vector2(lane.end.x, clampf(at.y, lane.position.y, lane.end.y))
		1: return Vector2(lane.position.x, clampf(at.y, lane.position.y, lane.end.y))
		2: return Vector2(clampf(at.x, lane.position.x, lane.end.x), lane.end.y)
	return Vector2(clampf(at.x, lane.position.x, lane.end.x), lane.position.y)


func _build_graph() -> void:
	var by_cell := {}
	var corners: Array = []          # block -> [c0 (-x-s), c1 (+x-s), c2 (+x+s), c3 (-x+s)]
	var side_pts: Array = []         # block -> side -> [[t, node]]
	for bi in plan.blocks.size():
		var b: Dictionary = plan.blocks[bi]
		by_cell[Vector2i(int(b["ix"]), int(b["is"]))] = bi
		var lane := lane_rect(b["rect"])
		corners.append([_add_node(lane.position), _add_node(Vector2(lane.end.x, lane.position.y)),
				_add_node(lane.end), _add_node(Vector2(lane.position.x, lane.end.y))])
		side_pts.append([[], [], [], []])
	# Doors: the middle of every street-facing front, on its facade.
	for i in plan.buildings.size():
		var bld: Dictionary = plan.buildings[i]
		var lot: Dictionary = plan.lots[int(bld["lot"])]
		if int(lot["front"]) < 0 or (bld["tiers"] as Array).is_empty():
			continue
		var side := int(lot["front"])
		var bi := int(lot["block"])
		var c: Vector2 = bld["center"]
		var half: Vector2 = (bld["size"] as Vector2) * 0.5
		var n: Vector2 = CityPlan.SIDE_N[side]
		var at := c + Vector2(n.x * (half.x + DOOR_OUT), n.y * (half.y + DOOR_OUT))
		var lane := lane_rect(plan.blocks[bi]["rect"])
		var on := _on_side(lane, side, at)
		var node := _add_node(on)
		(side_pts[bi][side] as Array).append([_along(lane, side, on), node])
		doors.append({"id": doors.size(), "building": i, "at": at, "node": node, "block": bi, "side": side})
	# Benches: the street benches in the furnishing band (node on the lane), the park benches round the fountain (node on
	# the park's paved ring, reached by the park paths) and plaza benches (node on the lane of a street side of the plaza
	# whose straight way in misses the planter).
	var park_ring := {}            # lot index -> [ring nodes N E S W, chord midpoints (+x+s, +x-s, -x-s, -x+s)]
	for it: Dictionary in CityPropLayout.layout(plan):
		if int(it.get("building", -1)) >= 0:      # roof props are not on the street
			continue
		if it["type"] != "bench":
			_props.append([Vector2(it["x"], it["s"]), float(PROP_R.get(it["type"], 0.5)) * (1.5 if it.get("pit", false) else 1.0)])
			continue
		var at := Vector2(it["x"], it["s"])
		for bi in plan.blocks.size():
			var r: Rect2 = plan.blocks[bi]["rect"]
			if not r.has_point(at):
				continue
			var d: Array[float] = [r.end.x - at.x, at.x - r.position.x, r.end.y - at.y, at.y - r.position.y]
			var side := 0
			for k in 4:
				if d[k] < d[side]:
					side = k
			var node := -1
			var kind := "street"
			if d[side] <= 2.0:
				var lane := lane_rect(r)
				var on := _on_side(lane, side, at)
				node = _add_node(on)
				(side_pts[bi][side] as Array).append([_along(lane, side, on), node])
			else:
				var li := _lot_at(at)
				if li < 0:
					break
				var lot: Dictionary = plan.lots[li]
				if lot["open"] == "park":
					kind = "park"
					if not park_ring.has(li):
						park_ring[li] = _park_paths(li, bi, side_pts)
					var c := (lot["rect"] as Rect2).get_center()
					var q := at - c
					var mids: Array = park_ring[li][1]
					node = int(mids[(0 if q.y >= 0.0 else 1) if q.x >= 0.0 else (2 if q.y < 0.0 else 3)])
				elif lot["open"] == "plaza":
					kind = "plaza"
					node = _plaza_way(li, bi, at, side_pts)
				if node < 0:
					break
			benches.append({"id": benches.size(), "prop": int(it["id"]), "at": at, "yaw": float(it["yaw"]), "node": node,
					"slide": (h(7001, benches.size()) - 0.5) * 1.0, "kind": kind})
			break
	# Section mode: where the ways over the spine meet the lanes of the blocks beside it (on the drawn zebras).
	var spine_ways: Array = _spine_zebras(by_cell, side_pts) if plan.section != null else []
	# The lane round each block, through its doors and benches.
	for bi in plan.blocks.size():
		var c: Array = corners[bi]
		var ends := [[c[1], c[2]], [c[0], c[3]], [c[3], c[2]], [c[0], c[1]]]      # low -> high end of each side
		for side in 4:
			var pts: Array = side_pts[bi][side]
			pts.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0] or (m[0] == n[0] and m[1] < n[1]))
			var prev := int(ends[side][0])
			for q: Array in pts:
				_add_edge(prev, int(q[1]), WALK)
				prev = int(q[1])
			_add_edge(prev, int(ends[side][1]), WALK)
	# Section mode: the crossings over the spine, on its zebras.
	var spine_line := -1
	if plan.section != null:
		spine_line = plan.section.spine_line
		_spine_crossings(spine_ways)
	# Zebra crossings between facing corners of neighbouring blocks.
	for bi in plan.blocks.size():
		var b: Dictionary = plan.blocks[bi]
		var cell := Vector2i(int(b["ix"]), int(b["is"]))
		var c: Array = corners[bi]
		# Across a pedestrian street or a superblock's court (CityPlan road forms, docs/design/city-variety.md) no vehicle
		# passes: the crossing has no signal (junction -1), people cross when they get there.
		if by_cell.has(cell + Vector2i(1, 0)) and cell.x != spine_line - 1:     # (not across the spine: see above)
			var o: Array = corners[int(by_cell[cell + Vector2i(1, 0)])]
			var free := not plan.seg_drives("s", cell.x + 1, cell.y)
			_crossing(int(c[1]), int(o[0]), 0, free)
			_crossing(int(c[2]), int(o[3]), 0, free)
		if by_cell.has(cell + Vector2i(0, 1)):
			var o: Array = corners[int(by_cell[cell + Vector2i(0, 1)])]
			var free := not plan.seg_drives("x", cell.y + 1, cell.x)
			_crossing(int(c[3]), int(o[0]), 1, free)
			_crossing(int(c[2]), int(o[1]), 1, free)


## The open lot containing `at`, or -1.
func _lot_at(at: Vector2) -> int:
	for li in plan.lots.size():
		if plan.lots[li]["kind"] == "open" and (plan.lots[li]["rect"] as Rect2).has_point(at):
			return li
	return -1


const PARK_RING := 5.5         ## m, the paved ring round the park fountain (radius 3.4) the paths meet


## The park's paths: a node on the lane in the middle of each side, a straight path in to a ring round the fountain.
## Returns [ring nodes N E S W, chord midpoints in the quadrants (+x+s, +x-s, -x-s, -x+s)].
func _park_paths(li: int, bi: int, side_pts: Array) -> Array:
	var c := (plan.lots[li]["rect"] as Rect2).get_center()
	var lane := lane_rect(plan.blocks[bi]["rect"])
	var ring := [_add_node(c + Vector2(0, PARK_RING)), _add_node(c + Vector2(PARK_RING, 0)), _add_node(c + Vector2(0, -PARK_RING)),
			_add_node(c + Vector2(-PARK_RING, 0))]
	var h2 := PARK_RING * 0.5
	var mids := [_add_node(c + Vector2(h2, h2)), _add_node(c + Vector2(h2, -h2)), _add_node(c + Vector2(-h2, -h2)), _add_node(c + Vector2(-h2, h2))]
	# ring N -> (+x+s) -> E -> (+x-s) -> S -> (-x-s) -> W -> (-x+s) -> N
	_add_edge(ring[0], mids[0], WALK)
	_add_edge(mids[0], ring[1], WALK)
	_add_edge(ring[1], mids[1], WALK)
	_add_edge(mids[1], ring[2], WALK)
	_add_edge(ring[2], mids[2], WALK)
	_add_edge(mids[2], ring[3], WALK)
	_add_edge(ring[3], mids[3], WALK)
	_add_edge(mids[3], ring[0], WALK)
	# side 0 (+x) meets ring E, 1 (-x) W, 2 (+s) N, 3 (-s) S
	var meet := [ring[1], ring[3], ring[0], ring[2]]
	for side in 4:
		var on := _on_side(lane, side, c)
		var n := _add_node(on)
		(side_pts[bi][side] as Array).append([_along(lane, side, on), n])
		_add_edge(n, int(meet[side]), WALK)
	return [ring, mids]


## A plaza bench's way in: the lane point of the nearest street side of its plaza whose straight line to the seat misses
## the planter and every building. Returns that new lane node, or -1.
func _plaza_way(li: int, bi: int, at: Vector2, side_pts: Array) -> int:
	var lot: Dictionary = plan.lots[li]
	var r: Rect2 = lot["rect"]
	var inner := r.grow(-2.0)
	var pl := Vector2(minf(inner.size.x * 0.5, 4.0), minf(inner.size.y * 0.5, 4.0))
	var planter := Rect2(inner.get_center() - pl * 0.5, pl).grow(0.6)
	var lane := lane_rect(plan.blocks[bi]["rect"])
	var best := -1
	var best_d := INF
	var best_on := Vector2.ZERO
	for side in 4:
		if not (lot["faces"] as Array)[side]:
			continue
		var on := _on_side(lane, side, at)
		if _segment_hits(planter, on, at) or (not _cuts.is_empty() and _hits(_cuts, on, at)):
			continue
		var blocked := false
		for b: Dictionary in plan.buildings:
			var fp := Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"])
			if _segment_hits(fp, on, at):
				blocked = true
				break
		if not blocked and on.distance_to(at) < best_d:
			best_d = on.distance_to(at)
			best = side
			best_on = on
	if best < 0:
		return -1
	var n := _add_node(best_on)
	(side_pts[bi][best] as Array).append([_along(lane, best, best_on), n])
	return n


static func _segment_hits(r: Rect2, a: Vector2, b: Vector2) -> bool:
	for k in 9:
		if r.has_point(a.lerp(b, float(k) / 8.0)):
			return true
	return false


## Section mode: for every inner cross line, a way over the spine on one of the zebras CityStreets draws beside that
## junction (city-spine.md section 3: the one on the +s side, else the one on the -s side when the +s one would cross a
## floor cut or kept-clear ground), from the spine-side lane of the block on one side to the block on the other: a node
## on each of those lanes (into side_pts, before the lanes are joined up). Returns [[m_a, m_b, s, junction]].
func _spine_zebras(by_cell: Dictionary, side_pts: Array) -> Array:
	var out := []
	var sl := plan.section.spine_line
	if sl <= 0 or sl >= plan.roads_x.size() - 1:
		return out
	var avoid: Array[Rect2] = _cuts.duplicate()
	for k in plan.site.keep_clear:
		avoid.append((k as Rect2).grow(0.4))
	var ns := plan.roads_s.size()
	var mid_z := CityDims.ZEBRA_AT + CityDims.ZEBRA_D * 0.5
	for j in range(1, ns - 1):
		var road: Dictionary = plan.roads_s[j]
		# [the row of the blocks beside the zebra, its s]: the +s zebra first.
		for side: Array in [[j, float(road["b"]) + mid_z], [j - 1, float(road["a"]) - mid_z]]:
			var ca := Vector2i(sl - 1, int(side[0]))
			var cb := Vector2i(sl, int(side[0]))
			if not by_cell.has(ca) or not by_cell.has(cb):
				continue
			var la := lane_rect(plan.blocks[int(by_cell[ca])]["rect"])
			var lb := lane_rect(plan.blocks[int(by_cell[cb])]["rect"])
			var sz := float(side[1])
			if sz < la.position.y or sz > la.end.y or sz < lb.position.y or sz > lb.end.y:
				continue
			if _hits(avoid, Vector2(la.end.x, sz), Vector2(lb.position.x, sz)):
				continue
			var m_a := _add_node(Vector2(la.end.x, sz))
			var m_b := _add_node(Vector2(lb.position.x, sz))
			(side_pts[int(by_cell[ca])][0] as Array).append([_along(la, 0, Vector2(la.end.x, sz)), m_a])
			(side_pts[int(by_cell[cb])][1] as Array).append([_along(lb, 1, Vector2(lb.position.x, sz)), m_b])
			out.append([m_a, m_b, sz, j])
			break
	return out


## The ways over the spine (_spine_zebras) in three pieces: ramp_a (no signal), the main road (the spine junction's walk
## signal) and the tram strip + ramp_b (the tram rule, rail_edges, only on the deck with track: CityDims.has_track).
func _spine_crossings(ways: Array) -> void:
	var av := plan.avenue_x()
	var ns := plan.roads_s.size()
	var sl := plan.section.spine_line
	var track := CityDims.has_track(plan)
	for wy: Array in ways:
		var sz := float(wy[2])
		var p1 := _add_node(Vector2(av.x, sz))
		var p2 := _add_node(Vector2(av.y, sz))
		_add_edge(int(wy[0]), p1, CROSS, -1, 0)
		_add_edge(p1, p2, CROSS, sl * ns + int(wy[3]), 0)
		_add_edge(p2, int(wy[1]), CROSS, -1, 0)
		var e := edge_between(p2, int(wy[1]))
		if e >= 0 and track:
			rail_edges[e] = sz


func _crossing(a: int, b: int, axis: int, free: bool = false) -> void:
	var m := int(_split.get(Vector2i(mini(a, b), maxi(a, b)), -1))
	if m >= 0:
		var j := -1 if free else _crossing_junction(a, b, axis)
		_add_edge(a, m, CROSS, j, axis)
		_add_edge(m, b, CROSS, j, axis)
		return
	_add_edge(a, b, CROSS, -1 if free else _crossing_junction(a, b, axis), axis)


## The junction a crossing between nodes a and b belongs to.
func _crossing_junction(a: int, b: int, axis: int) -> int:
	var mid := (nodes[a] + nodes[b]) * 0.5
	# The junction this crossing belongs to: on the road it crosses, at the cross road nearest to it.
	var j := -1
	var ns := plan.roads_s.size()
	if axis == 0:
		for i in plan.roads_x.size():
			if mid.x >= float(plan.roads_x[i]["a"]) and mid.x <= float(plan.roads_x[i]["b"]):
				var best := 0
				for k in ns:
					var cs := (float(plan.roads_s[k]["a"]) + float(plan.roads_s[k]["b"])) * 0.5
					var bs := (float(plan.roads_s[best]["a"]) + float(plan.roads_s[best]["b"])) * 0.5
					if absf(cs - mid.y) < absf(bs - mid.y):
						best = k
				j = i * ns + best
	else:
		for k in ns:
			if mid.y >= float(plan.roads_s[k]["a"]) and mid.y <= float(plan.roads_s[k]["b"]):
				var best := 0
				for i in plan.roads_x.size():
					var cx := (float(plan.roads_x[i]["a"]) + float(plan.roads_x[i]["b"])) * 0.5
					var bx := (float(plan.roads_x[best]["a"]) + float(plan.roads_x[best]["b"])) * 0.5
					if absf(cx - mid.x) < absf(bx - mid.x):
						best = i
				j = best * ns + k
	if j < 0:
		j = junction_near(mid)
	return j


static func _along(lane: Rect2, side: int, on: Vector2) -> float:
	return on.y - lane.position.y if side < 2 else on.x - lane.position.x


## Shortest-path tree rooted at node `root` (memo): [dist, prev], prev[n] = the next node from n toward the root.
func tree(root: int) -> Array:
	if _trees.has(root):
		return _trees[root]
	var n := nodes.size()
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var done := PackedByteArray()
	done.resize(n)
	dist[root] = 0.0
	var hd: Array[float] = [0.0]
	var hn: Array[int] = [root]
	while not hn.is_empty():
		# pop the minimum
		var u: int = hn[0]
		var du: float = hd[0]
		var last := hn.size() - 1
		hn[0] = hn[last]
		hd[0] = hd[last]
		hn.resize(last)
		hd.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			if l >= hn.size():
				break
			var m := l
			if l + 1 < hn.size() and (hd[l + 1] < hd[l] or (hd[l + 1] == hd[l] and hn[l + 1] < hn[l])):
				m = l + 1
			if hd[m] < hd[i] or (hd[m] == hd[i] and hn[m] < hn[i]):
				var td := hd[i]
				var tn := hn[i]
				hd[i] = hd[m]
				hn[i] = hn[m]
				hd[m] = td
				hn[m] = tn
				i = m
			else:
				break
		if done[u] == 1 or du > dist[u]:
			continue
		done[u] = 1
		for e: int in adj[u]:
			var ed: Array = edges[e]
			var v: int = int(ed[1]) if int(ed[0]) == u else int(ed[0])
			var w := float(ed[5]) + (CROSS_COST if int(ed[2]) == CROSS else 0.0)
			if du + w < dist[v] - 1e-5 or (absf(du + w - dist[v]) <= 1e-5 and u < prev[v]):
				dist[v] = du + w
				prev[v] = u
				# push
				hd.append(du + w)
				hn.append(v)
				var c := hn.size() - 1
				while c > 0:
					var pa := (c - 1) / 2
					if hd[c] < hd[pa] or (hd[c] == hd[pa] and hn[c] < hn[pa]):
						var td := hd[c]
						var tn := hn[c]
						hd[c] = hd[pa]
						hn[c] = hn[pa]
						hd[pa] = td
						hn[pa] = tn
						c = pa
					else:
						break
	var out := [dist, prev]
	_trees[root] = out
	return out


## Build the trees rooted at the door nodes of doors i with i % parts == part (not built yet). The same trees as when
## they are built on demand.
func warm_trees(part: int, parts: int) -> void:
	for i in range(part, doors.size(), parts):
		tree(int(doors[i]["node"]))


## Lay out the standing slots of the crossing nodes and benches with i % parts == part (the same whenever laid out).
func warm_slots(part: int, parts: int) -> void:
	for b in range(part, benches.size(), parts):
		bench_slots(b)
	var k := 0
	for u in nodes.size():
		if _has_cross(u):
			if k % parts == part:
				wait_slots_all(u)
			k += 1


## Nodes from `from` to `root` (both included), following the tree rooted at `root`. Empty if unreachable.
func chain(from: int, root: int) -> PackedInt32Array:
	var t := tree(root)
	var prev: PackedInt32Array = t[1]
	var out := PackedInt32Array([from])
	var n := from
	var guard := nodes.size() + 1
	while n != root:
		n = prev[n]
		if n < 0 or guard <= 0:
			return PackedInt32Array()
		guard -= 1
		out.append(n)
	return out


## Routing cost from node `n` to node `root` (INF if unreachable).
func cost(n: int, root: int) -> float:
	return float((tree(root)[0] as PackedFloat32Array)[n])


# --- Ground ----------------------------------------------------------------------------------------------

## Height of the walking surface at (x, s): the sidewalk (curb height) on a block, sloping down the corner ramp in the
## 1.6 m nearest the curb, the road (0) elsewhere.
func ground_h(x: float, s: float) -> float:
	var best := -INF
	for r in _block_rects:
		var d := minf(minf(x - r.position.x, r.end.x - x), minf(s - r.position.y, r.end.y - s))
		best = maxf(best, d)
	if best <= 0.0:
		return 0.0
	return CityPlan.CURB_H * clampf(best / CityDims.EDGE, 0.0, 1.0)


## The crossing whose zebra band covers (x, s): {edge, junction, axis}, or {} (tests use it).
func crossing_at(x: float, s: float, slack: float = 0.3) -> Dictionary:
	var p := Vector2(x, s)
	for e in edges.size():
		var ed: Array = edges[e]
		if int(ed[2]) != CROSS:
			continue
		var a := nodes[int(ed[0])]
		var b := nodes[int(ed[1])]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		if q.distance_to(p) <= 1.5 + slack:
			return {"edge": e, "junction": int(ed[3]), "axis": int(ed[4])}
	return {}


# --- People and timetables -------------------------------------------------------------------------------

func _build_people() -> void:
	var look := RandomNumberGenerator.new()
	look.seed = plan.cosmetic_seed() + 4049
	for id in count:
		var period := 110.0 + 70.0 * h(id, 1)
		people.append({"id": id, "period": period, "phase": h(id, 2) * period, "speed": 1.25 + 0.3 * h(id, 3),
				"cloth": look.randi_range(0, 4), "build": look.randi_range(0, 2), "tall": look.randi_range(0, 1)})
	# The riders: pod passengers who get out in a firefight (ids count .. count + RIDERS - 1). No timetable: unseen until
	# a pod lets them out (LifeCrowd.spawn_rider).
	for k in RIDERS:
		riders.append({"id": count + k, "period": 1.0, "phase": 0.0, "speed": 1.25 + 0.3 * h(count + k, 3),
				"cloth": look.randi_range(0, 4), "build": look.randi_range(0, 2), "tall": look.randi_range(0, 1)})


## Everyone who can be drawn: the timetabled people, then the riders.
func total() -> int:
	return count + RIDERS


func person(id: int) -> Dictionary:
	return people[id] if id < count else riders[id - count]


## The graph node nearest to `at` (straight line).
func nearest_node(at: Vector2) -> int:
	var best := -1
	var bd := INF
	for n in nodes.size():
		var d := nodes[n].distance_squared_to(at)
		if d < bd:
			bd = d
			best = n
	return best


func slot_of(id: int, t: float) -> int:
	var pp: Dictionary = people[id]
	return int(floor((t - float(pp["phase"])) / float(pp["period"])))


## The trip of person `id` in slot k (memo): {legs: PackedFloat64Array, n, t_start, t_end, door_a, door_d, bench}.
func trip(id: int, k: int) -> Dictionary:
	var key := Vector2i(id, k)
	if _trips.has(key):
		return _trips[key]
	if _trips.size() > 4000:
		_trips.clear()
	var out := _bench_cap(id, k, wish(id, k))
	out["id"] = id
	_trips[key] = out
	return out


## The trip person id wishes for in slot k (memo), before the bench capacity: its bench stop, if any, may be dropped
## (trip()), the rest is the same.
func wish(id: int, k: int) -> Dictionary:
	var key := Vector2i(id, k)
	if _wishes.has(key):
		return _wishes[key]
	if _wishes.size() > 4000:
		_wishes.clear()
	var out := _plan_trip(id, k)
	out["id"] = id
	_wishes[key] = out
	return out


## Crowd spacing at benches: a bench takes 1 sitter and bench_cap(b) - 1 standers by it per INDEX_W window parity. The
## first who wish to stop there in a window (by arrival, then id: a pure function of everyone's wished trips, which do
## not depend on each other) stop; the others walk on to their door without stopping (the same door, the same start).
func _bench_cap(id: int, k: int, w_tr: Dictionary) -> Dictionary:
	var b := int(w_tr["bench"])
	if b < 0:
		return w_tr
	var legs: PackedFloat64Array = w_tr["legs"]
	var t_sit := INF
	for i in int(w_tr["n"]):
		if int(legs[i * LEG + 6]) == SIT:
			t_sit = legs[i * LEG]
			break
	if t_sit == INF:
		return w_tr
	var w := floori(t_sit / INDEX_W)
	var arr: Array = _bench_wishes(w).get(b, [])
	var r := 0
	for i in arr.size():
		if int(arr[i][1]) == id:
			r = i
			break
	if r < bench_cap(b):
		return w_tr
	var pp: Dictionary = people[id]
	var a := int(w_tr["door_a"])
	var d := int(w_tr["door_d"])
	var walk := _legs(id, k, a, d, -1, float(pp["speed"]), legs[0])
	if walk.size() == 0 or walk[walk.size() - LEG + 1] > float(pp["phase"]) + float(k + 1) * float(pp["period"]) - 2.0:
		return w_tr       # (never: a walk without the stop is shorter)
	return _finish_trip(walk, a, d, -1)


## How many may stop at bench b in one window: the sitter and the standing slots of one parity (at most 7).
func bench_cap(b: int) -> int:
	return 1 + mini((bench_slots(b)[1] as PackedVector2Array).size() / 2, 6)


## Who wishes to stop at each bench in index window w: {bench -> [[arrival, id]] sorted} (memo; built ahead like _groups).
func _bench_wishes(w: int) -> Dictionary:
	if _wish_index.has(w):
		return _wish_index[w]
	while not warm_index(w, count, 0, 1, true):
		pass
	return _wish_index[w]


func _plan_trip(id: int, k: int) -> Dictionary:
	var pp: Dictionary = people[id]
	var period := float(pp["period"])
	var t_slot := float(pp["phase"]) + float(k) * period
	var speed := float(pp["speed"])
	if doors.size() < 2:
		var d0 := 0 if doors.is_empty() else 0
		return {"legs": PackedFloat64Array(), "n": 0, "t_start": INF, "t_end": INF, "door_a": d0, "door_d": d0, "bench": -1}
	var a := int(h(id, k, 11) * doors.size()) % doors.size()
	var na: int = doors[a]["node"]
	var ta := tree(na)
	var dist_a: PackedFloat32Array = ta[0]
	var t0 := t_slot + 2.0 + h(id, k, 13) * period * 0.3     # leaves the door this long into the slot
	var budget := t_slot + period - 2.0                      # and must be in again by then
	var tries: Array[int] = []
	for c in 8:
		var d := int(h(id, k, 20 + c) * doors.size()) % doors.size()
		var dd := dist_a[int(doors[d]["node"])]
		if d != a and dd >= 25.0 and dd <= 150.0:
			tries.append(d)
	# Fallback: the nearest other door (always fits).
	var near := -1
	for d in doors.size():
		if d == a:
			continue
		var dd := dist_a[int(doors[d]["node"])]
		if dd < INF and (near < 0 or dd < dist_a[int(doors[near]["node"])]):
			near = d
	if near >= 0:
		tries.append(near)
	var want_bench := h(id, k, 12) < 0.35 and not benches.is_empty()
	for d: int in tries:
		var bench := -1
		if want_bench:
			bench = _bench_between(na, int(doors[d]["node"]))
		var legs := _legs(id, k, a, d, bench, speed, t0)
		if legs.size() > 0 and legs[legs.size() - LEG + 1] <= budget:
			return _finish_trip(legs, a, d, bench)
		if bench >= 0:
			legs = _legs(id, k, a, d, -1, speed, t0)
			if legs.size() > 0 and legs[legs.size() - LEG + 1] <= budget:
				return _finish_trip(legs, a, d, -1)
	return {"legs": PackedFloat64Array(), "n": 0, "t_start": INF, "t_end": INF, "door_a": a, "door_d": a, "bench": -1}


## The bench that adds the least walking between two nodes (at most 50 m extra), or -1.
func _bench_between(na: int, nd: int) -> int:
	var direct := cost(na, nd)
	var best := -1
	var best_c := direct + 50.0
	var da: PackedFloat32Array = tree(na)[0]
	var dd: PackedFloat32Array = tree(nd)[0]
	for b in benches.size():
		var n: int = benches[b]["node"]
		var c := da[n] + dd[n]
		if c < best_c:
			best_c = c
			best = b
	return best


func _finish_trip(legs: PackedFloat64Array, a: int, d: int, bench: int) -> Dictionary:
	return {"legs": legs, "n": legs.size() / LEG, "t_start": legs[0], "t_end": legs[legs.size() - LEG + 1], "door_a": a,
			"door_d": d, "bench": bench}


## Timetable legs from time t0 (shared clock): door a -> (bench) -> door d, waiting at corners for the walk signal.
func _legs(id: int, k: int, a: int, d: int, bench: int, speed: float, t0: float) -> PackedFloat64Array:
	var out: Array = []
	var na: int = doors[a]["node"]
	var nd: int = doors[d]["node"]
	var st := [t0, 0.0]         # [t, distance walked]
	_leg(out, st, doors[a]["at"], nodes[na], WALK, speed, -1, na)
	if bench >= 0:
		var nb: int = benches[bench]["node"]
		if not _walk_chain(out, st, chain(na, nb), speed):
			return PackedFloat64Array()
		var seat := _seat(bench)
		_leg(out, st, nodes[nb], seat, WALK, speed, nb, -1)
		var sit := 20.0 + 40.0 * h(id, k, 14)
		_hold(out, st, seat, sit, SIT, float(benches[bench]["yaw"]), nb)
		_leg(out, st, seat, nodes[nb], WALK, speed, -1, nb)
		if not _walk_chain(out, st, chain(nb, nd), speed):
			return PackedFloat64Array()
	else:
		if not _walk_chain(out, st, chain(na, nd), speed):
			return PackedFloat64Array()
	_leg(out, st, nodes[nd], doors[d]["at"], WALK, speed, nd, -1)
	return PackedFloat64Array(out)


## Where a sitter's feet go on bench b (in front of the seat, slid along it a little).
func _seat(b: int) -> Vector2:
	var yaw := float(benches[b]["yaw"])
	var fwd := Vector2(sin(yaw), cos(yaw))
	var side := Vector2(fwd.y, -fwd.x)
	return (benches[b]["at"] as Vector2) + fwd * 0.05 + side * float(benches[b]["slide"])


func _walk_chain(out: Array, st: Array, ch: PackedInt32Array, speed: float) -> bool:
	if ch.is_empty():
		return false
	for i in ch.size() - 1:
		var u := ch[i]
		var v := ch[i + 1]
		var e := edge_between(u, v)
		if e < 0:
			return false
		var ed: Array = edges[e]
		if int(ed[2]) == CROSS:
			var dur := float(ed[5]) / speed
			var go := float(st[0])
			if rail_edges.has(e):
				go = tram.next_clear(float(rail_edges[e]), go, dur)
			elif int(ed[3]) >= 0:
				go = next_green(int(ed[3]), int(ed[4]), go, dur)
			if go > float(st[0]) + 1e-6:
				var dir := nodes[v] - nodes[u]
				_hold(out, st, nodes[u], go - float(st[0]), WAIT, atan2(dir.x, dir.y), u)
			_leg(out, st, nodes[u], nodes[v], CROSS, speed, u, v)
		else:
			_leg(out, st, nodes[u], nodes[v], WALK, speed, u, v)
	return true


func _leg(out: Array, st: Array, a: Vector2, b: Vector2, kind: int, speed: float, na: int, nb: int) -> void:
	var length := a.distance_to(b)
	if length < 1e-4:
		return
	var t0 := float(st[0])
	var t1 := t0 + length / speed
	var dir := b - a
	out.append_array([t0, t1, a.x, a.y, b.x, b.y, kind, float(st[1]), atan2(dir.x, dir.y), na, nb])
	st[0] = t1
	st[1] = float(st[1]) + length


func _hold(out: Array, st: Array, at: Vector2, dur: float, kind: int, heading: float, node: int) -> void:
	if dur <= 1e-6:
		return
	var t0 := float(st[0])
	out.append_array([t0, t0 + dur, at.x, at.y, at.x, at.y, kind, float(st[1]), heading, node, node])
	st[0] = t0 + dur


## The timetable pose of person `id` at time t: {x, s, h, heading, state (walk | wait | sit | cross | indoor), visible,
## dist (walked so far, for the stride), na, nb (graph nodes either side, -1 off the graph), door}.
func calm_pose(id: int, t: float) -> Dictionary:
	return pose_in_trip(trip(id, slot_of(id, t)), t)


const STATE_NAMES := ["walk", "wait", "sit", "cross"]


func pose_in_trip(tr: Dictionary, t: float) -> Dictionary:
	var n := int(tr["n"])
	if n == 0 or t < float(tr["t_start"]) or t >= float(tr["t_end"]):
		var door := int(tr["door_a"]) if n == 0 or t < float(tr["t_start"]) else int(tr["door_d"])
		var at: Vector2 = doors[door]["at"] if not doors.is_empty() else Vector2.ZERO
		return {"x": at.x, "s": at.y, "h": CityPlan.CURB_H, "heading": 0.0, "state": "indoor", "visible": false, "dist": 0.0,
				"na": -1, "nb": -1, "door": door}
	var legs: PackedFloat64Array = tr["legs"]
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if legs[mid * LEG] <= t:
			lo = mid
		else:
			hi = mid - 1
	if not tr.has("J"):
		_spread(tr)
	var o := lo * LEG
	var t0 := legs[o]
	var t1 := legs[o + 1]
	var f := clampf((t - t0) / maxf(t1 - t0, 1e-6), 0.0, 1.0)
	var J: PackedVector2Array = tr["J"]
	var kind := int(legs[o + 6])
	var at := J[lo]
	var walked: float = (tr["D"] as PackedFloat64Array)[lo]
	if kind == WALK or kind == CROSS:
		var to_hold := lo + 1 < n and (int(legs[o + LEG + 6]) == WAIT or int(legs[o + LEG + 6]) == SIT)
		var turn := LANE_TURN
		if kind == CROSS and rail_edges.has(edge_between(int(legs[o + 9]), int(legs[o + 10]))):
			turn = RAIL_TURN
		at = _walk_point(int(tr.get("id", 0)), lo, legs, o, J[lo], J[lo + 1], f, to_hold, turn)
		walked += J[lo].distance_to(at)
	var st: String = STATE_NAMES[kind]
	if (tr["ST"] as PackedByteArray)[lo] == 1:
		st = "wait"            # a bench's overflow: stands by it instead of sitting
	return {"x": at.x, "s": at.y, "h": CityPlan.CURB_H if kind == WALK else ground_h(at.x, at.y),
			"heading": (tr["H"] as PackedFloat32Array)[lo], "state": st, "visible": true, "dist": walked,
			"na": int(legs[o + 9]), "nb": int(legs[o + 10]), "door": -1}


# --- Crowd spacing -----------------------------------------------------------------------------------------
# docs/design/ambient-life.md "Crowd spacing". The timetable's legs (times, nodes) are unchanged; only where a person stands
# and walks is spread out, as pure functions of the plan, the timetable and the id (no messages, the same everywhere):
#   * walking: a lane offset to the right of the walking direction, one of LANES (by the id; after a green, by the rank in
#     that green's group), mitred at corners so the path stays continuous, changed within LANE_TURN m of a leg's start,
#     plus a seeded surge / lag along each leg (SURGE) so two walkers on one lane at one speed do not stay merged;
#   * waiting for a crossing: a standing slot of that crossing at that corner (laid out once per node, on the sidewalk,
#     clear of props, buildings and the road, at least SLOT_GAP apart), the slot index = the rank of the person's arrival
#     among everyone the timetable has waiting for the same green there (earliest arrival takes the front slot); the
#     group crosses from its slots on CROSS_LANES by rank (within the zebra band);
#   * benches: two seats; whoever arrives first in an INDEX_W window sits on the window parity's seat, later arrivals
#     stand by the bench at standing slots of that parity (windows of one parity never overlap: a sit lasts <= 60 s).

const PROP_R := {"tree": 0.6, "lamp": 0.35, "bin": 0.45, "signal": 0.35, "sign": 0.3}   ## m, prop clearance radius
const SLOT_GAP := 0.9         ## m between standing slots
const SLOT_CAP := 32          ## standing slots per crossing (overflow reuses them modulo: reported by the spacing test)
const LANES := [-0.9, -0.45, 0.0, 0.45, 0.9]   ## m, walking lane offsets to the right of the walking direction
const CROSS_LAT := 1.6        ## m, the most a crossing is walked off its centre line (the zebra band is 3 m)
const NARROW_LAT := 0.45      ## m, the same off the sidewalk (section mode: the pieces over the spine, the rail lane)
## m, the lines a green's waiting group crosses on (by rank: the first ones spread widest apart)
const CROSS_LANES := [0.0, 0.8, -0.8, 1.6, -1.6, 0.4, -0.4, 1.2, -1.2]
const INDEX_W := 60.0         ## s, hold index window (also the bench parity window)
const WALKWAY := Vector2(1.7, 3.95)   ## m from the curb: where a sidewalk slot may stand (beyond the furnishing band)


const LANE_TURN := 2.5        ## m: a walker changes lane over the first this many metres of a leg
const RAIL_TURN := 0.4        ## m: the same on a rail piece (inside the rail lane a walker keeps its +-NARROW_LAT line;
                              ## the step to / from a waiting slot happens on the lane's edge, where the slot stands)
const SURGE := 0.8            ## m: a walker's seeded surge / lag along a leg (so two on one lane at one speed part)


## Where person id is on leg i (legs offset o) at fraction f, from its joints J0 -> J1: the lane offset (the joints'
## sideways part) is reached within LANE_TURN m (of the end instead when the leg ends in a standing slot: `to_hold`), the along part follows the leg, and the person surges ahead or lags by up
## to SURGE m mid-leg (sin(pi f): the leg's start and end times are kept).
func _walk_point(id: int, i: int, legs: PackedFloat64Array, o: int, j0: Vector2, j1: Vector2, f: float, to_hold: bool = false,
		turn: float = LANE_TURN) -> Vector2:
	var b0 := Vector2(legs[o + 2], legs[o + 3])
	var b1 := Vector2(legs[o + 4], legs[o + 5])
	var length := b0.distance_to(b1)
	if length < 1e-3:
		return j0.lerp(j1, f)
	var d := (b1 - b0) / length
	var r := _right(d)
	var o0 := j0 - b0
	var o1 := j1 - b1
	var g := smoothstep(0.0, 1.0, clampf(f * length / turn, 0.0, 1.0))
	if to_hold:      # stepping into a standing slot: keep the lane until the last `turn` m (not across a corner early)
		g = 1.0 - smoothstep(0.0, 1.0, clampf((1.0 - f) * length / turn, 0.0, 1.0))
	var fs := f + minf(SURGE, length * 0.08) / length * sin(PI * f) * (2.0 * h(id, i, 66) - 1.0)
	return b0.lerp(b1, fs) + r * lerpf(o0.dot(r), o1.dot(r), g) + d * lerpf(o0.dot(d), o1.dot(d), fs)


## A rectangle that holds every pose of trip tr (indoors at its doors included): its legs' points grown by the most its
## joints stand off them (x 1.5: a walked point mixes a joint's sideways and along parts), or by MAX_OFF before the
## joints are worked out. LifeCrowd skips people whose box misses a threat (conservative: never changes a result).
const MAX_OFF := 11.0         ## m: no joint stands further than this off its leg (slots <= 7.4 m from their node, x 1.5)

func trip_box(tr: Dictionary) -> Rect2:
	if tr.has("box"):
		return tr["box"]
	var n := int(tr["n"])
	var legs: PackedFloat64Array = tr["legs"]
	var box := Rect2(Vector2(legs[2], legs[3]), Vector2.ZERO)
	for i in n:
		var o := i * LEG
		box = box.expand(Vector2(legs[o + 2], legs[o + 3])).expand(Vector2(legs[o + 4], legs[o + 5]))
	var grow := MAX_OFF
	if tr.has("J"):
		var J: PackedVector2Array = tr["J"]
		var off := 0.0
		for j in n + 1:
			var base := Vector2(legs[j * LEG + 2], legs[j * LEG + 3]) if j < n else Vector2(legs[(n - 1) * LEG + 4], legs[(n - 1) * LEG + 5])
			off = maxf(off, J[j].distance_to(base))
			if j > 0:
				off = maxf(off, J[j].distance_to(Vector2(legs[(j - 1) * LEG + 4], legs[(j - 1) * LEG + 5])))
		grow = off * 1.5 + 0.1
		tr["box"] = box.grow(grow)
		return tr["box"]
	return box.grow(grow)


func lane_of(id: int) -> float:
	return float(LANES[int(h(id, 61) * LANES.size()) % LANES.size()])


static func _right(d: Vector2) -> Vector2:
	return Vector2(d.y, -d.x)


## The joint between two walked directions offset `lat` to the right: the mitre point (offset from the node).
static func miter(d_in: Vector2, d_out: Vector2, lat: float) -> Vector2:
	var ra := _right(d_in)
	var rb := _right(d_out)
	var c := ra.dot(rb)
	if c < -0.3:
		return rb * lat
	return (ra + rb) * (lat / (1.0 + c))


## Distance from (x, s) to the curb of the block it stands on (-1 if on no block).
func _curb_dist(p: Vector2) -> float:
	var best := -1.0
	for r in _block_rects:
		if r.has_point(p):
			best = maxf(best, minf(minf(p.x - r.position.x, r.end.x - p.x), minf(p.y - r.position.y, r.end.y - p.y)))
	return best


## Along door d's facade, on the side of `r` (a door leg can leave its facade at a slant: its lane point is clamped to the
## lane; offsetting across the slant would put the person inside the building).
func _door_side(d: int, r: Vector2) -> Vector2:
	if d < 0 or d >= doors.size():
		return r
	var n: Vector2 = CityPlan.SIDE_N[int(doors[d]["side"])]
	var t := _right(n)
	return t if t.dot(r) >= 0.0 else -t


## Whether node n stands on a sidewalk's walkway (else: in a road, a median, a park or a plaza).
func _on_walk(n: int) -> bool:
	return n >= 0 and _curb_dist(nodes[n]) >= WALKWAY.x - 0.01


## Whether a person may stand at p. sidewalk: on the walkway band of a block; else anywhere off a building / cut (a node in
## a road median, a park or a plaza). Never in a building, a floor cut, a prop, or a park fountain / plaza planter.
func standable(p: Vector2, sidewalk: bool) -> bool:
	if sidewalk:
		var cd := _curb_dist(p)
		if cd < WALKWAY.x or cd > WALKWAY.y:
			return false
	for r in _cuts:
		if r.has_point(p):
			return false
	if plan.extent.size.x > 0.0 and not plan.extent.grow(-0.5).has_point(p):
		return false
	if plan.section != null:
		var rl := plan.section.lane_x("rail")
		if p.x > rl.x + 0.3 and p.x < rl.y - 0.3:
			return false            # never wait in the rail lane
	if _obst.is_empty():
		_build_obst()
	for ob: Array in _obst.get(Vector2i(floori(p.x / OBST_CELL), floori(p.y / OBST_CELL)), []):
		match int(ob[0]):
			0:       # a building footprint (grown)
				if (ob[1] as Rect2).has_point(p):
					return false
			1:       # a prop
				if (ob[1] as Vector2).distance_to(p) < float(ob[2]):
					return false
			2:       # a bench
				var q := p - (ob[1] as Vector2)
				var fwd: Vector2 = ob[2]
				if absf(q.dot(fwd)) < 0.6 and absf(q.dot(_right(fwd))) < 1.2:
					return false
	for lot: Dictionary in _open_lots:
		if not (lot["rect"] as Rect2).has_point(p):
			continue
		var c := (lot["rect"] as Rect2).grow(-2.0).get_center()
		if lot["open"] == "park" and p.distance_to(c) < 3.4 + 0.5:
			return false
		if lot["open"] == "plaza":
			var inner := (lot["rect"] as Rect2).grow(-2.0)
			var pl := Vector2(minf(inner.size.x * 0.5, 4.0), minf(inner.size.y * 0.5, 4.0))
			if Rect2(inner.get_center() - pl * 0.5, pl).grow(0.5).has_point(p):
				return false
		if lot["open"] == "garden":
			return false
	return true


const OBST_CELL := 4.0        ## m, the cells of _obst


func _obst_add(box: Rect2, ob: Array) -> void:
	for cx in range(floori(box.position.x / OBST_CELL), floori(box.end.x / OBST_CELL) + 1):
		for cy in range(floori(box.position.y / OBST_CELL), floori(box.end.y / OBST_CELL) + 1):
			var c := Vector2i(cx, cy)
			if not _obst.has(c):
				_obst[c] = []
			(_obst[c] as Array).append(ob)


func _build_obst() -> void:
	for r in _foot:
		_obst_add(r.grow(0.35), [0, r.grow(0.35)])
	for pr: Array in _props:
		var rad := float(pr[1]) + 0.3
		_obst_add(Rect2(pr[0] as Vector2, Vector2.ZERO).grow(rad), [1, pr[0], rad])
	for b: Dictionary in benches:
		var yaw := float(b["yaw"])
		_obst_add(Rect2(b["at"] as Vector2, Vector2.ZERO).grow(1.4), [2, b["at"], Vector2(sin(yaw), cos(yaw))])
	if _obst.is_empty():
		_obst[Vector2i(1 << 20, 1 << 20)] = []      # built (nothing in it)
	for lot: Dictionary in plan.lots:
		if lot["kind"] == "open":
			_open_lots.append(lot)


func _far_enough(p: Vector2, taken: PackedVector2Array, gap: float) -> bool:
	for q in taken:
		if q.distance_to(p) < gap - 1e-4:
			return false
	return true


## The standing slots at node u for the crossing to node v (laid out for every crossing at u at once, so the result does
## not depend on which was asked first).
func wait_slots(u: int, v: int) -> PackedVector2Array:
	if not _node_slots.has(u):
		_node_slots[u] = _layout_node(u)
	return (_node_slots[u] as Dictionary).get(v, PackedVector2Array())


func _layout_node(u: int) -> Dictionary:
	var at := nodes[u]
	var outs: Array = []           # [v, dir]
	var es: Array = (adj[u] as Array).duplicate()
	es.sort()
	for e: int in es:
		var ed: Array = edges[e]
		if int(ed[2]) != CROSS:
			continue
		var v := int(ed[1]) if int(ed[0]) == u else int(ed[0])
		outs.append([v, (nodes[v] - at).normalized()])
	var sidewalk := _curb_dist(at) >= WALKWAY.x - 0.01
	var rail_node := false
	for e: int in adj[u]:
		rail_node = rail_node or rail_edges.has(e)
	var lists: Array = []
	for o: Array in outs:
		var d: Vector2 = o[1]
		var q := _right(d)
		var other := Vector2.ZERO
		for o2: Array in outs:
			if o2 != o:
				other += o2[1] as Vector2
		var cands: Array = []          # [score, point]
		var rail := rail_edges.has(edge_between(u, int(o[0])))
		for row in 3:
			var a := 0.9 - 0.9 * float(row)
			if not sidewalk and a > 0.0:
				continue           # a node in the road: never step out into the lane ahead
			if rail_node and a != 0.0:
				continue           # beside the rail lane: only on the lane's edge line (behind / ahead is a lane)
			for i in 16:
				if rail and i > 0:
					break          # the rail lane: waiters line up on the crossing's line (the tram passes 1.5 m away)
				var b := 0.45 + 0.9 * float(i) + (0.45 if row % 2 == 1 else 0.0)
				for sg: float in [1.0, -1.0]:
					var lat := b * sg if not rail else 0.45 * sg
					if rail_node and not rail:
						lat = (0.45 + 0.9 * float(i) + 0.9) * sg     # along the edge line, clear of the rail crossing's own pair
					var toward := other.length_squared() > 1e-6 and (q * lat).dot(other) > 0.0
					var score := absf(lat) + 0.6 * float(row) + (3.0 if toward else 0.0) + (0.01 if sg < 0.0 else 0.0)
					cands.append([score, at + d * a + q * lat])
		cands.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0])
		lists.append(cands)
	# Slots already laid out nearby are kept clear of: benches' seats and standing slots, and the slots of crossing nodes
	# with a lower index (laid out first, recursively: the result never depends on which node was asked first).
	var taken := PackedVector2Array()
	if not outs.is_empty():
		for b in benches.size():
			if (benches[b]["at"] as Vector2).distance_to(at) < 14.0:
				var bs := bench_slots(b)
				taken.append_array(bs[0])
				taken.append_array(bs[1])
		for m in u:
			if nodes[m].distance_to(at) < 16.0 and _has_cross(m):
				for v2: int in wait_slots_all(m):
					taken.append_array((_node_slots[m] as Dictionary)[v2])
	var out := {}
	var pos: Array[int] = []
	for o: Array in outs:
		out[int(o[0])] = PackedVector2Array()
		pos.append(0)
	var any := true
	while any:
		any = false
		for i in outs.size():
			var mine: PackedVector2Array = out[int(outs[i][0])]
			if mine.size() >= SLOT_CAP:
				continue
			var cands: Array = lists[i]
			while pos[i] < cands.size():
				var p: Vector2 = cands[pos[i]][1]
				pos[i] += 1
				if standable(p, sidewalk) and _far_enough(p, taken, SLOT_GAP):
					taken.append(p)
					mine.append(p)
					out[int(outs[i][0])] = mine
					any = true
					break
	return out


func _has_cross(m: int) -> bool:
	for e: int in adj[m]:
		if int(edges[e][2]) == CROSS:
			return true
	return false


## The far nodes of node m's crossings (its slots laid out).
func wait_slots_all(m: int) -> Array:
	if not _node_slots.has(m):
		_node_slots[m] = _layout_node(m)
	return (_node_slots[m] as Dictionary).keys()


## Bench b's seats (2, a person's feet in front of the seat) and standing slots (by it, facing it), clear of the benches
## with a lower index nearby.
func bench_slots(b: int) -> Array:
	if _bench_slots.has(b):
		return _bench_slots[b]
	var bench: Dictionary = benches[b]
	var at: Vector2 = bench["at"]
	var yaw := float(bench["yaw"])
	var fwd := Vector2(sin(yaw), cos(yaw))
	var side := _right(fwd)
	var seats := PackedVector2Array([at + fwd * 0.05 - side * 0.5, at + fwd * 0.05 + side * 0.5])
	var sidewalk := str(bench.get("kind", "street")) == "street"
	var cands: Array = []
	for f: float in [1.05, 1.95, 2.85, -1.05, -1.95]:
		for i in 7:
			var lat: float = [0.0, -0.95, 0.95, -1.9, 1.9, -2.85, 2.85][i]
			var p := at + fwd * f + side * lat
			cands.append([absf(f - 1.05) + absf(lat) * 0.8 + (3.0 if f < 0.0 else 0.0), p])
	for sg: float in [-1.0, 1.0]:
		cands.append([1.6, at + side * (1.55 * sg) + fwd * 0.2])
	cands.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0])
	var taken := seats.duplicate()
	for o in b:
		if (benches[o]["at"] as Vector2).distance_to(at) < 8.0:
			var ob := bench_slots(o)
			taken.append_array(ob[0])
			taken.append_array(ob[1])
	var stand := PackedVector2Array()
	for c: Array in cands:
		var p: Vector2 = c[1]
		if standable(p, sidewalk) and _far_enough(p, taken, SLOT_GAP):
			taken.append(p)
			stand.append(p)
	_bench_slots[b] = [seats, stand]
	return _bench_slots[b]


## The hold groups (waits for a crossing, bench visits) whose deciding time falls in index window w: {key -> [[t0, id]]}.
## A wait's key is (node, crossing's far node, green time in ms: everyone waiting for one green at one corner); a rail
## crossing's waits end at different times, so its key is (node, far node, -1 - window) with slots split by parity. A bench
## visit's key is (-1 - bench, window of arrival, -2).
func _groups(w: int) -> Dictionary:
	if _index.has(w):
		return _index[w]
	while not warm_index(w, count):
		pass
	return _index[w]


## Add up to n more people's holds to index window w (built ahead of need, a few people a frame, so the window is ready
## before anyone stands in it; the result does not depend on the order). Returns whether the window is complete.
func warm_index(w: int, n: int, part: int = 0, parts: int = 1, wishes: bool = false) -> bool:
	var index := _wish_index if wishes else _index
	var wips := _wish_wip if wishes else _index_wip
	if index.has(w):
		return true
	if not wips.has(w):
		var done := PackedByteArray()
		done.resize(count)
		wips[w] = [done, {}, 0]
	var wip: Array = wips[w]
	var done: PackedByteArray = wip[0]
	var g: Dictionary = wip[1]
	var left := n
	var id := part
	while id < count and left > 0:
		if done[id] == 0:
			if wishes:
				_wish_person(w, id, g)
			else:
				_index_person(w, id, g)
			done[id] = 1
			wip[2] = int(wip[2]) + 1
			left -= 1
		id += parts
	wip[0] = done
	if int(wip[2]) < count:
		return false
	for key: Variant in g:
		(g[key] as Array).sort_custom(func(m: Array, o: Array) -> bool: return m[0] < o[0] or (m[0] == o[0] and m[1] < o[1]))
	wips.erase(w)
	if index.size() > 24:            # forget the oldest windows (rebuilt the same if ever asked again)
		var keys := index.keys()
		keys.sort()
		for k in keys.size() - 16:
			index.erase(keys[k])
	index[w] = g
	return true


func _wish_person(w: int, id: int, g: Dictionary) -> void:
	var a := float(w) * INDEX_W
	var b := a + INDEX_W
	for k in range(slot_of(id, a), slot_of(id, b - 1e-6) + 1):
		var tr := wish(id, k)
		var bench := int(tr["bench"])
		if bench < 0:
			continue
		var legs: PackedFloat64Array = tr["legs"]
		for i in int(tr["n"]):
			if int(legs[i * LEG + 6]) == SIT:
				if floori(legs[i * LEG] / INDEX_W) == w:
					if not g.has(bench):
						g[bench] = []
					(g[bench] as Array).append([legs[i * LEG], id])
				break


const AHEAD := 6              ## index windows built ahead: a trip planned now holds up to ~3 minutes ahead (4 windows),
                              ## the 2 more are built a person a frame while nothing needs them yet

## Build ahead: the index windows a pose may need from time t on, at most n people a call. AmbientLife calls it every frame; setup calls it per part.
func warm_ahead(t: float, n: int, part: int = 0, parts: int = 1) -> void:
	var w0 := floori(t / INDEX_W)
	for w in range(w0, w0 + AHEAD):
		for wishes: bool in [true, false]:       # the bench wishes first: the trips (and so the holds) depend on them
			if not (_wish_index if wishes else _index).has(w):
				warm_index(w, n, part, parts, wishes)
				if parts == 1:
					return


func _index_person(w: int, id: int, g: Dictionary) -> void:
	var a := float(w) * INDEX_W
	var b := a + INDEX_W
	for k in range(slot_of(id, a), slot_of(id, b - 1e-6) + 1):
		var tr := trip(id, k)
		var n := int(tr["n"])
		if n == 0:
			continue
		var legs: PackedFloat64Array = tr["legs"]
		for i in n:
			var o := i * LEG
			var kind := int(legs[o + 6])
			var key := Vector3i.ZERO
			if kind == WAIT and i + 1 < n:
				var t1 := legs[o + 1]
				if floori(t1 / INDEX_W) != w:
					continue
				var u := int(legs[o + 9])
				var v := int(legs[(i + 1) * LEG + 10])
				var e := edge_between(u, v)
				key = Vector3i(u, v, -1 - w) if rail_edges.has(e) else Vector3i(u, v, int(round(t1 * 1000.0)))
			elif kind == SIT:
				if floori(legs[o] / INDEX_W) != w:
					continue
				key = Vector3i(-1 - int(tr["bench"]), w, -2)
			else:
				continue
			if not g.has(key):
				g[key] = []
			(g[key] as Array).append([legs[o], id])


func _rank(key: Vector3i, w: int, id: int) -> int:
	var arr: Array = _groups(w).get(key, [])
	for i in arr.size():
		if int(arr[i][1]) == id:
			return i
	return 0


## Where trip tr's holds stand and the walked joints between its legs: tr["J"] (n + 1 points, leg i runs J[i] -> J[i+1];
## a hold has J[i] == J[i+1]), "D" (metres walked at each leg's start), "H" (headings), "ST" (1: a bench visit standing).
func _spread(tr: Dictionary) -> void:
	var n := int(tr["n"])
	var legs: PackedFloat64Array = tr["legs"]
	var id := int(tr.get("id", 0))
	var lat := lane_of(id)
	var J := PackedVector2Array()
	J.resize(n + 1)
	var H := PackedFloat32Array()
	H.resize(n)
	var ST := PackedByteArray()
	ST.resize(n)
	var hold := PackedVector2Array()       # per leg: the hold's spot (holds only)
	hold.resize(n)
	var is_hold := PackedByteArray()
	is_hold.resize(n)
	var wait_rank := PackedInt32Array()     # per leg: a wait's lane index after it (-1 otherwise)
	wait_rank.resize(n)
	wait_rank.fill(-1)
	var cross_rank := PackedInt32Array()    # per leg: a wait's rank in its group (-1 otherwise)
	cross_rank.resize(n)
	cross_rank.fill(-1)
	for i in n:
		var o := i * LEG
		var kind := int(legs[o + 6])
		H[i] = legs[o + 8]
		if kind == WAIT:
			is_hold[i] = 1
			var u := int(legs[o + 9])
			var spot := Vector2(legs[o + 2], legs[o + 3])
			if i + 1 < n:
				var v := int(legs[(i + 1) * LEG + 10])
				var t1 := legs[o + 1]
				var w := floori(t1 / INDEX_W)
				var rail := rail_edges.has(edge_between(u, v))
				var key := Vector3i(u, v, -1 - w) if rail else Vector3i(u, v, int(round(t1 * 1000.0)))
				var r := _rank(key, w, id)
				var si := r * 2 + (posmod(w, 2)) if rail else r
				# the lane walked on after this green: consecutive ranks of one group get different lanes, and the
				# group's first lane comes from its key (so rank 0 of every group is not on the same lane)
				wait_rank[i] = r + int(h(key.x, key.y, key.z) * LANES.size())
				cross_rank[i] = r
				var sl := wait_slots(u, v)
				if not sl.is_empty():
					spot = sl[si % sl.size()]
			hold[i] = spot
		elif kind == SIT:
			is_hold[i] = 1
			var bi := int(tr["bench"])
			var spot := Vector2(legs[o + 2], legs[o + 3])
			if bi >= 0:
				var w := floori(legs[o] / INDEX_W)
				var r := _rank(Vector3i(-1 - bi, w, -2), w, id)
				var par := posmod(w, 2)
				var bs := bench_slots(bi)
				if r == 0:
					spot = (bs[0] as PackedVector2Array)[par]
				else:
					var stand: PackedVector2Array = bs[1]
					if not stand.is_empty():
						spot = stand[((r - 1) * 2 + par) % stand.size()]
						ST[i] = 1
						var to := (benches[bi]["at"] as Vector2) - spot
						H[i] = atan2(to.x, to.y)
			hold[i] = spot
	var dirs := PackedVector2Array()
	dirs.resize(n)
	for i in n:
		var o := i * LEG
		dirs[i] = Vector2(legs[o + 4] - legs[o + 2], legs[o + 5] - legs[o + 3]).normalized()
	var cross_lat := 0.0
	for j in n + 1:
		# after a wait, the person walks on in a lane given by its slot rank (people leaving one green together spread)
		if j > 0 and wait_rank[j - 1] >= 0:
			lat = float(LANES[wait_rank[j - 1] % LANES.size()])
		var prev := j - 1
		var next := j
		var base := Vector2(legs[j * LEG + 2], legs[j * LEG + 3]) if j < n else Vector2(legs[(n - 1) * LEG + 4], legs[(n - 1) * LEG + 5])
		if next < n and is_hold[next] == 1:
			J[j] = hold[next]
		elif prev >= 0 and is_hold[prev] == 1:
			J[j] = hold[prev]
		elif prev >= 0 and int(legs[prev * LEG + 6]) == CROSS:
			J[j] = base + _right(dirs[prev]) * cross_lat
		elif prev < 0:
			J[j] = base + _door_side(int(tr["door_a"]), _right(dirs[next])) * lat
		elif next >= n:
			J[j] = base + _door_side(int(tr["door_d"]), _right(dirs[prev])) * lat
		else:
			J[j] = base + miter(dirs[prev], dirs[next], lat)
		if next < n and int(legs[next * LEG + 6]) == CROSS:
			var wide := CROSS_LAT if _on_walk(int(legs[next * LEG + 9])) and _on_walk(int(legs[next * LEG + 10])) else NARROW_LAT
			if prev >= 0 and cross_rank[prev] >= 0:
				cross_lat = float(CROSS_LANES[cross_rank[prev] % CROSS_LANES.size()]) * wide / CROSS_LAT
			else:
				cross_lat = clampf((J[j] - base).dot(_right(dirs[next])), -wide, wide)
	var D := PackedFloat64Array()
	D.resize(n + 1)
	D[0] = legs[7] if n > 0 else 0.0
	for i in n:
		D[i + 1] = D[i] + J[i].distance_to(J[i + 1])
		if is_hold[i] == 0 and J[i].distance_squared_to(J[i + 1]) > 1e-8:
			var dv := J[i + 1] - J[i]
			H[i] = atan2(dv.x, dv.y)
	tr["J"] = J
	tr["D"] = D
	tr["H"] = H
	tr["ST"] = ST
	trip_box(tr)         # while the joints are at hand (LifeCrowd's threat filter reads it)


# --- Routes for panic --------------------------------------------------------------------------------------

## A path from point p (on the edge between nodes na and nb, either may be -1) to door d:
## {pts: PackedVector2Array, kinds: PackedByteArray (per segment), nodes: PackedInt32Array (per point, -1 off graph),
##  cum: PackedFloat32Array, length}. Empty pts if unreachable.
func route(p: Vector2, na: int, nb: int, d: int) -> Dictionary:
	var root: int = doors[d]["node"]
	var start := -1
	var best := INF
	for n: int in [na, nb]:
		if n < 0:
			continue
		var c := p.distance_to(nodes[n]) + cost(n, root)
		if c < best - 1e-6:
			best = c
			start = n
	var pts := PackedVector2Array([p])
	var kinds := PackedByteArray()
	var ids := PackedInt32Array([-1])
	if start < 0:
		return {"pts": PackedVector2Array(), "kinds": kinds, "nodes": ids, "cum": PackedFloat32Array(), "length": 0.0}
	var e0 := edge_between(na, nb) if na >= 0 and nb >= 0 else -1
	pts.append(nodes[start])
	kinds.append(int(edges[e0][2]) if e0 >= 0 else WALK)
	ids.append(start)
	var ch := chain(start, root)
	for i in range(1, ch.size()):
		var e := edge_between(ch[i - 1], ch[i])
		pts.append(nodes[ch[i]])
		kinds.append(int(edges[e][2]) if e >= 0 else WALK)
		ids.append(ch[i])
	pts.append(doors[d]["at"])
	kinds.append(WALK)
	ids.append(-1)
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	return {"pts": pts, "kinds": kinds, "nodes": ids, "cum": cum, "length": cum[cum.size() - 1]}


## Routing cost from p (between na and nb) to door d.
func cost_to_door(p: Vector2, na: int, nb: int, d: int) -> float:
	var root: int = doors[d]["node"]
	var best := INF
	for n: int in [na, nb]:
		if n >= 0:
			best = minf(best, p.distance_to(nodes[n]) + cost(n, root))
	return best + nodes[root].distance_to(doors[d]["at"])


## The nearest door within `reach` metres (straight line) by walking cost, skipping doors closer to `away` than p is
## (unless `away` is null) by adding `penalty`. -1 if none within `max_cost`.
func pick_door(p: Vector2, na: int, nb: int, reach: float, max_cost: float, away: Variant = null, penalty: float = 30.0) -> int:
	var best := -1
	var best_c := INF
	for d in doors.size():
		var at: Vector2 = doors[d]["at"]
		if at.distance_to(p) > reach:
			continue
		var c := cost_to_door(p, na, nb, d)
		if c > max_cost:
			continue
		if away != null and at.distance_to(away as Vector2) < p.distance_to(away as Vector2):
			c += penalty
		if c < best_c - 1e-6:
			best_c = c
			best = d
	return best


## Point at distance u along a route: [Vector2, segment index].
static func along(rt: Dictionary, u: float) -> Array:
	var pts: PackedVector2Array = rt["pts"]
	var cum: PackedFloat32Array = rt["cum"]
	if pts.size() < 2:
		return [pts[0] if pts.size() > 0 else Vector2.ZERO, 0]
	var lo := 0
	var hi := pts.size() - 2
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if cum[mid] <= u:
			lo = mid
		else:
			hi = mid - 1
	var seg := cum[lo + 1] - cum[lo]
	var f := clampf((u - cum[lo]) / maxf(seg, 1e-6), 0.0, 1.0)
	return [pts[lo].lerp(pts[lo + 1], f), lo]


# --- Checksum --------------------------------------------------------------------------------------------

func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	buf.put_utf8_string(plan.checksum())
	buf.put_32(count)
	for n in nodes:
		buf.put_32(int(round(n.x * 1000.0)))
		buf.put_32(int(round(n.y * 1000.0)))
	for ed: Array in edges:
		buf.put_32(int(ed[0]))
		buf.put_32(int(ed[1]))
		buf.put_8(int(ed[2]))
		buf.put_32(int(ed[3]))
	for d: Dictionary in doors:
		buf.put_32(int(d["building"]))
		buf.put_32(int(round((d["at"] as Vector2).x * 1000.0)))
		buf.put_32(int(round((d["at"] as Vector2).y * 1000.0)))
	for b: Dictionary in benches:
		buf.put_32(int(b["prop"]))
	for j: Dictionary in junctions:
		buf.put_32(int(round(float(j["phase"]) * 1000.0)))
	for pp: Dictionary in people:
		for key: String in ["period", "phase", "speed"]:
			buf.put_32(int(round(float(pp[key]) * 1000.0)))
	if tram != null:          # section mode only (the stand-alone checksum is unchanged)
		buf.put_utf8_string(tram.checksum())
		var keys := rail_edges.keys()
		keys.sort()
		for e: int in keys:
			buf.put_32(e)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
