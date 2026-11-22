class_name LifePlan
extends RefCounted
## Ambient life as plain data (docs/design/ambient-life.md sections 3 and 8): everything the civilians of one CityPlan need,
## derived from the plan and its seed alone, so every machine builds the same and checksum() proves it.
##
##   nodes / edges       the sidewalk walk graph: a walkway lane round every block (WALK_IN in from the curb), with the
##                       doors and benches as nodes on it, and a zebra crossing between facing block corners at every
##                       junction. edges: [a, b, kind (WALK | CROSS), junction, axis, length]
##   doors               one per building front that faces a street: [{id, building, at (on the facade), node, block}]
##   benches             the street benches of CityProps.layout: [{id, prop, at, yaw, node}]
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

var _edge_at: Dictionary = {}     ## Vector2i(min node, max node) -> edge index
var _trees: Dictionary = {}       ## root node -> [dist PackedFloat32Array, prev PackedInt32Array] (memo)
var _trips: Dictionary = {}       ## Vector2i(id, slot) -> trip (memo)
var _block_rects: Array[Rect2] = []


func net_fields() -> Dictionary:
	return {
		"plan": Net.SPAWN, "seed": Net.SPAWN, "count": Net.SPAWN,     # the mission seed and the people param
		# derived from the plan on every machine, verified by checksum()
		"nodes": Net.LOCAL, "edges": Net.LOCAL, "adj": Net.LOCAL, "doors": Net.LOCAL, "benches": Net.LOCAL,
		"junctions": Net.LOCAL, "people": Net.LOCAL, "riders": Net.LOCAL,
		"_edge_at": Net.LOCAL, "_trees": Net.LOCAL, "_trips": Net.LOCAL, "_block_rects": Net.LOCAL,
	}


## `people` < 0: PEOPLE_DEFAULT scaled by the district's area. Always capped at PEOPLE_CAP.
static func make(p: CityPlan, people_count: int = -1) -> LifePlan:
	var lp := LifePlan.new()
	lp.build(p, people_count)
	return lp


static func default_count(p: CityPlan) -> int:
	return clampi(int(round(float(PEOPLE_DEFAULT) * p.p("size_x") * p.p("size_s") / (220.0 * 240.0))), 1, PEOPLE_CAP)


func build(p: CityPlan, people_count: int = -1) -> void:
	plan = p
	seed = int(p.p("seed")) * 15485863 + 7
	count = clampi(people_count if people_count >= 0 else default_count(p), 0, PEOPLE_CAP)
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
	for b: Dictionary in p.blocks:
		_block_rects.append(b["rect"])
	_build_junctions()
	_build_graph()
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


func _junction_near(at: Vector2) -> int:
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
	var e := edges.size()
	edges.append([a, b, kind, junction, axis, nodes[a].distance_to(nodes[b])])
	_edge_at[key] = e
	(adj[a] as Array).append(e)
	(adj[b] as Array).append(e)


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
	for it: Dictionary in CityProps.layout(plan):
		if it["type"] != "bench" or int(it.get("building", -1)) >= 0:      # roof props are not on the street
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
	# Zebra crossings between facing corners of neighbouring blocks.
	for bi in plan.blocks.size():
		var b: Dictionary = plan.blocks[bi]
		var cell := Vector2i(int(b["ix"]), int(b["is"]))
		var c: Array = corners[bi]
		if by_cell.has(cell + Vector2i(1, 0)):
			var o: Array = corners[int(by_cell[cell + Vector2i(1, 0)])]
			_crossing(int(c[1]), int(o[0]), 0)
			_crossing(int(c[2]), int(o[3]), 0)
		if by_cell.has(cell + Vector2i(0, 1)):
			var o: Array = corners[int(by_cell[cell + Vector2i(0, 1)])]
			_crossing(int(c[3]), int(o[0]), 1)
			_crossing(int(c[2]), int(o[1]), 1)


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
		if _segment_hits(planter, on, at):
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


func _crossing(a: int, b: int, axis: int) -> void:
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
		j = _junction_near(mid)
	_add_edge(a, b, CROSS, j, axis)


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
	return CityPlan.CURB_H * clampf(best / CityStreets.EDGE, 0.0, 1.0)


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
	var out := _plan_trip(id, k)
	_trips[key] = out
	return out


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
			var go := next_green(int(ed[3]), int(ed[4]), float(st[0]), dur)
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
	var o := lo * LEG
	var t0 := legs[o]
	var t1 := legs[o + 1]
	var f := clampf((t - t0) / maxf(t1 - t0, 1e-6), 0.0, 1.0)
	var x := lerpf(legs[o + 2], legs[o + 4], f)
	var s := lerpf(legs[o + 3], legs[o + 5], f)
	var kind := int(legs[o + 6])
	var length := Vector2(legs[o + 4] - legs[o + 2], legs[o + 5] - legs[o + 3]).length()
	return {"x": x, "s": s, "h": ground_h(x, s) if kind == CROSS else CityPlan.CURB_H, "heading": legs[o + 8],
			"state": STATE_NAMES[kind], "visible": true, "dist": legs[o + 7] + length * f,
			"na": int(legs[o + 9]), "nb": int(legs[o + 10]), "door": -1}


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
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
