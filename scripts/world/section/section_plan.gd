class_name SectionPlan
extends RefCounted
## The macro layout of one mission section, as plain data (no nodes): several concentric decks, each cut into a grid of
## district cells with a zone, the shared pillar grid, the transit spine, the connections between decks and the route from
## the entry down to the extraction (docs/design/mission-section.md). Generated from `params` alone with one seeded
## generator, so every machine plans the same section and `checksum()` proves it (AGENTS.md rule 4, game design 3.5).
## No building geometry: the city generator (scripts/world/city/) fills each zone region from this plan.
##
## COORDINATES. Deck k (0 = top, nearest the axis; "down" is outward) has floor radius `radius_of(k)`. Positions on a
## deck are that deck's arc coordinates (x along the axis, s along the spin direction, in metres ON THAT DECK), with
## x = 0 on the section's centre line and s = 0 at the middle of the section. Anything shared between decks (pillars,
## road lines, connectors) is stored as an ANGLE theta = s / radius, because decks are concentric: the same pillar is at
## s = theta * radius_of(k) on every deck. Rect2 is (x, s) position + size. `to_world()` places all decks around one axis.
##
## GRID. `cols` x `rows` cells. Longitudinal road lines (constant x, running along s) are indexed 0..cols, cross road
## lines (constant theta) 0..rows; the outer lines are the perimeter roads just inside the section's bulkheads. One
## longitudinal line is the transit spine (SPINE_LANES). Cell (c, r) lies between lines c, c+1 and r, r+1.
##
##   decks        [{index, radius, dir, zones: [row][col] String, regions: [{kind, cells: [Vector2i(c, r)], rect}],
##                  keep_clear: [Rect2]}]      dir = +1 / -1: the way the critical path crosses this deck along s
##   pillars      [{id, col, row, x, theta, lift, stops: [deck]}]     one per cell, on every deck, except long-span bays
##   connectors   [{id, kind: ramp | lift | shaft, role: critical | branch | shortcut, from, to, stops: [deck],
##                  vehicles, two_way, locked, x0, x1, theta0, theta1, col, row, pillar,
##                  top: {deck, i, j}, bottom: {deck, i, j}, lane, top_line, foot_line}]
##                  footprint on a deck = connector_rect(); a lift's is its platform, centred on its pillar, the same
##                  size on every stop (its stored x0..theta1 are the platform on its top stop only)
##   roads        [{axis: "s" | "x", line, kind: spine | arterial | cross | perimeter, width}]
##   entry / extraction   {deck, i, j, col, row}
##   route        {vehicle: [{deck, i, j}], mech: [{deck, col, row}], vehicle_len, mech_len}
##   boundaries   [{deck, edge: s0 | s1 | x0 | x1, kind: bulkhead | window, backdrop, gates: [{kind: portal |
##                  blast_door | collapsed, role: entry | extraction | "", axis, line, x, s, width}]}]
##                  the four walls of every deck: s0 / s1 close the ends of the arc, x0 / x1 the sides (boundary_rect)
##   hooks        [{kind: checkpoint | cordon | patrol | pylon | banner | holding | station, deck, x, s, ...}]
##
## DECK VIEW. `deck_view(k)` gathers what a geometry builder needs for one deck, in that deck's (x, s), read-only:
##   {deck, radius, clear_height, slab, extent: Rect2 (the ground inside the walls),
##    blocks [{col, row, rect, zone, region (index into decks[k].regions), pillar (id or -1)}]   row-major
##    pillars [{id, col, row, x, s, half, kind, lift}],
##    road_strips [{rect, kind: perimeter | arterial | cross | avenue | rail | ramp_lane, axis, line, lane}]
##                 blocks + strips tile the extent; strips overlap only where roads cross,
##    connectors [{id, kind, role, locked, part: hole | landing | stop, rect}]   a ramp's hole runs along its spine lane
##                 across the cross-road strips (cross streets bridge the cut): builders cut it out of every strip it
##                 intersects, or bridge it,
##    ceiling_openings [{connector, kind, rect}]   holes in the floor of the deck above, projected onto this deck,
##    keep_clear [Rect2], walls [{edge, kind, backdrop, rect, gates}]   in EDGES order}

const ZONES: Array[String] = ["urban", "park", "industrial", "open", "transit"]
## The transit spine, west to east: [lane, width]. Ramps between decks dive out of the two outer lanes.
const SPINE_LANES := [["ramp_a", 10.0], ["avenue", 18.0], ["rail", 12.0], ["ramp_b", 10.0]]
const SPINE_W := 50.0
const ARTERIAL_W := 14.0
const PERIMETER_W := 12.0
const LIFT_HALF := 14.0          ## half side of a freight-lift pillar (holds a LIFT_PLATFORM platform)
const LIFT_PLATFORM := 22.0
const PILLAR_R := {"urban": 9.0, "park": 2.5, "industrial": 5.0, "open": 3.0, "transit": 7.0, "lift": LIFT_HALF}
const PILLAR_JITTER := 6.0       ## how far a pillar may sit off its cell centre (m)
const CONNECT_CLEAR := 4.0       ## a connection keeps this far from any pillar it isn't housed in
const SHAFT_MAX := 40.0
const SHAFT_MARGIN := 6.0        ## floor left between a shaft and the roads around its cell
const VEHICLE_CLEARANCE := 6.0   ## a road passes under a ramp only where the ramp is this high
const LIFT_COST := 60.0          ## route cost of one lift ride, in metres of driving
const WALL_T := 6.0              ## thickness of a boundary wall, outside the section's ground
const EDGES: Array[String] = ["s0", "s1", "x0", "x1"]
const MIN_COL := 76.0           ## narrowest column: a spine-side or edge cell must still hold a lift pillar
const MIN_ROW := 60.0            ## shortest row on the top deck
const MIN_DECKS := 2
const MAX_DECKS := 5

const DEFAULTS := {
	"seed": 1.0, "decks": 3.0, "arc": 540.0, "width": 270.0, "radius": 400.0, "pitch": 48.0, "slab": 8.0,
	"cell": 90.0, "ramp_grade": 0.18, "shafts": 1.0, "express": 1.0,
	"w_urban": 1.0, "w_park": 0.45, "w_industrial": 0.45,
}

var params: Dictionary = {}
var deck_count := 0
var cols := 0
var rows := 0
var span := 0.0                    ## angle the section covers around the ring (rad)
var spine_line := 0                ## which longitudinal line is the transit spine
var col_x: Array[float] = []       ## road centre x of each longitudinal line
var row_theta: Array[float] = []   ## angle of each cross line (the outer two are the bulkheads)
var decks: Array = []
var pillars: Array = []
var connectors: Array = []
var roads: Array = []
var entry: Dictionary = {}
var extraction: Dictionary = {}
var route: Dictionary = {}
var hooks: Array = []
var boundaries: Array = []

var _rng := RandomNumberGenerator.new()
var _pillar_of: Dictionary = {}    ## cell key -> pillar id
var _omit: Dictionary = {}         ## cell key -> true: a long-span bay (no pillar on any deck)
var _lift_cells: Dictionary = {}   ## cell key -> connector index of the lift housed in that cell's pillar
var _reserved: Array = []          ## per deck: cell key -> true (transit cells fixed by the route)


func net_fields() -> Dictionary:
	return {
		"params": Net.SPAWN,     # the mission seed and planner settings: all that crosses the wire
		"deck_count": Net.LOCAL, "cols": Net.LOCAL, "rows": Net.LOCAL, "span": Net.LOCAL, "spine_line": Net.LOCAL,
		"col_x": Net.LOCAL, "row_theta": Net.LOCAL, "decks": Net.LOCAL, "pillars": Net.LOCAL, "connectors": Net.LOCAL,
		"roads": Net.LOCAL, "entry": Net.LOCAL, "extraction": Net.LOCAL, "route": Net.LOCAL, "hooks": Net.LOCAL,
		"boundaries": Net.LOCAL,
		# all of the above are recomputed from params on every machine and verified by checksum()
		"_rng": Net.LOCAL, "_pillar_of": Net.LOCAL, "_omit": Net.LOCAL, "_lift_cells": Net.LOCAL, "_reserved": Net.LOCAL,
	}


static func make(overrides: Dictionary = {}) -> SectionPlan:
	var plan := SectionPlan.new()
	plan.generate(overrides)
	return plan


func p(id: String) -> float:
	return float(params[id])


func cosmetic_seed() -> int:
	return int(p("seed")) * 6007 + 90001


# --- Geometry --------------------------------------------------------------------------------------------

func radius_of(k: int) -> float:
	return p("radius") + float(k) * p("pitch")


## Floor to ceiling on every deck (the ceiling is the underside of the deck above).
func clear_height() -> float:
	return p("pitch") - p("slab")


func s_of(k: int, theta: float) -> float:
	return theta * radius_of(k)


func theta_of(k: int, s: float) -> float:
	return s / radius_of(k)


## Length of deck k along the arc (lower decks are longer: same angle, bigger radius).
func arc_of(k: int) -> float:
	return span * radius_of(k)


func ring(k: int) -> RingFrame:
	return RingFrame.new(radius_of(k))


## Add this to RingFrame(radius_of(k)) world positions so every deck turns about the same axis. The lowest deck's floor
## passes through the world origin.
func deck_offset(k: int) -> Vector3:
	return Vector3(0.0, radius_of(deck_count - 1) - radius_of(k), 0.0)


## World position of (x, s, h) on deck k.
func to_world(k: int, x: float, s: float, h: float = 0.0) -> Vector3:
	return polar_to_world(x, s / radius_of(k), radius_of(k) - h)


## World position from the angle around the axis and the distance from it (for things that cross decks).
func polar_to_world(x: float, theta: float, r: float) -> Vector3:
	return Vector3(x, radius_of(deck_count - 1) - r * cos(theta), r * sin(theta))


func line_width(axis: String, line: int) -> float:
	if axis == "s":
		if line == spine_line:
			return SPINE_W
		return PERIMETER_W if line == 0 or line == cols else ARTERIAL_W
	return PERIMETER_W if line == 0 or line == rows else ARTERIAL_W


## Road centre of cross line j on deck k, as s (the outer two lines are roads just inside the bulkheads).
func line_s(k: int, j: int) -> float:
	var s := row_theta[j] * radius_of(k)
	if j == 0:
		return s + PERIMETER_W * 0.5
	if j == rows:
		return s - PERIMETER_W * 0.5
	return s


## Position of road crossing (i, j) on deck k.
func node_pos(k: int, i: int, j: int) -> Vector2:
	return Vector2(col_x[i], line_s(k, j))


## The x range [x0, x1] of a spine lane ("ramp_a", "avenue", "rail", "ramp_b").
func lane_x(lane: String) -> Vector2:
	var x := col_x[spine_line] - SPINE_W * 0.5
	for l: Array in SPINE_LANES:
		if l[0] == lane:
			return Vector2(x, x + float(l[1]))
		x += float(l[1])
	return Vector2(x, x)


## The buildable inside of cell (c, r) on deck k: the cell minus the roads around it.
func cell_rect(k: int, c: int, r: int) -> Rect2:
	var x0 := col_x[c] + line_width("s", c) * 0.5
	var x1 := col_x[c + 1] - line_width("s", c + 1) * 0.5
	var s0 := line_s(k, r) + line_width("x", r) * 0.5
	var s1 := line_s(k, r + 1) - line_width("x", r + 1) * 0.5
	return Rect2(x0, s0, x1 - x0, s1 - s0)


func zone(k: int, c: int, r: int) -> String:
	return str(decks[k]["zones"][r][c])


## Pillar id standing in cell (c, r), or -1 for a long-span bay.
func pillar_at(c: int, r: int) -> int:
	return int(_pillar_of.get(_key(c, r), -1))


func pillar_point(k: int, id: int) -> Vector2:
	var q: Dictionary = pillars[id]
	return Vector2(float(q["x"]), float(q["theta"]) * radius_of(k))


## What the pillar is on deck k: "lift" where a freight lift stops in it, else the zone of its cell there.
func pillar_style(k: int, id: int) -> String:
	var q: Dictionary = pillars[id]
	if q["lift"] and (q["stops"] as Array).has(k):
		return "lift"
	return zone(k, int(q["col"]), int(q["row"]))


## Half extent of the pillar's structural core on deck k (the city generator may wrap a bigger tower around it).
func pillar_radius(k: int, id: int) -> float:
	return float(PILLAR_R[pillar_style(k, id)])


## A connector's footprint on deck k as a Rect2 (x, s): the hole on its upper deck, the landing below. A lift's is its
## platform, LIFT_PLATFORM square centred on its pillar, the same size on every stop: scaling its stored angles by the
## radius would stretch it past its pillar on the lower decks.
func connector_rect(ci: int, k: int) -> Rect2:
	var c: Dictionary = connectors[ci]
	if c["kind"] == "lift" and int(c["pillar"]) >= 0:
		var at := pillar_point(k, int(c["pillar"]))
		return Rect2(at.x - LIFT_PLATFORM * 0.5, at.y - LIFT_PLATFORM * 0.5, LIFT_PLATFORM, LIFT_PLATFORM)
	var r := radius_of(k)
	return Rect2(float(c["x0"]), float(c["theta0"]) * r, float(c["x1"]) - float(c["x0"]),
			(float(c["theta1"]) - float(c["theta0"])) * r)


## True where connector ci cuts an opening in deck k's floor.
func is_hole(ci: int, k: int) -> bool:
	var c: Dictionary = connectors[ci]
	return c["kind"] != "lift" and int(c["from"]) == k


func _key(c: int, r: int) -> int:
	return r * 64 + c


# --- Generation ------------------------------------------------------------------------------------------

func generate(overrides: Dictionary = {}) -> void:
	params = DEFAULTS.duplicate()
	for id: String in overrides:
		if params.has(id):
			params[id] = float(overrides[id])
	params["decks"] = float(clampi(int(round(p("decks"))), MIN_DECKS, MAX_DECKS))
	params["radius"] = maxf(p("radius"), 80.0)
	params["cell"] = clampf(p("cell"), 60.0, 200.0)
	params["slab"] = clampf(p("slab"), 2.0, 20.0)
	params["pitch"] = maxf(p("pitch"), p("slab") + 20.0)
	params["ramp_grade"] = clampf(p("ramp_grade"), 0.05, 0.5)
	params["arc"] = clampf(p("arc"), MIN_ROW * 4.0, maxf(p("radius") * 4.5, MIN_ROW * 4.0))     # at most ~260 degrees of ring
	params["width"] = maxf(p("width"), MIN_COL * 2.0)
	decks.clear()
	pillars.clear()
	connectors.clear()
	roads.clear()
	hooks.clear()
	boundaries.clear()
	_pillar_of.clear()
	_omit.clear()
	_lift_cells.clear()
	_reserved.clear()
	_rng.seed = int(p("seed")) * 2246822519 + 3266489917
	deck_count = int(p("decks"))
	_make_grid()
	for k in deck_count:
		var z := []
		for r in rows:
			var row := []
			row.resize(cols)
			row.fill("")
			z.append(row)
		decks.append({"index": k, "radius": radius_of(k), "dir": 1 if k % 2 == 0 else -1, "zones": z, "regions": [],
				"keep_clear": []})
		_reserved.append({})
	# Pillar offsets are rolled for every cell up front, so later choices never shift them.
	var jitter: Array[Vector2] = []
	for i in cols * rows:
		jitter.append(Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)))
	_place_critical()
	_place_express()
	_place_ends()
	_place_shafts()
	_make_pillars(jitter)
	for k in deck_count:
		_fill_zones(k)
		_make_regions(k)
	_make_roads()
	_make_route()
	_make_boundaries()
	_make_hooks()


func _make_grid() -> void:
	cols = clampi(int(round(p("width") / p("cell"))), 2, mini(int(p("width") / MIN_COL), 32))
	rows = clampi(int(round(p("arc") / p("cell"))), 4, maxi(int(p("arc") / MIN_ROW), 4))
	span = p("arc") / p("radius")
	var cw := p("width") / float(cols)
	spine_line = _rng.randi_range(1, cols - 1)
	col_x.clear()
	for i in cols + 1:
		var x := -p("width") * 0.5 + float(i) * cw
		if i == 0:
			x += PERIMETER_W * 0.5
		elif i == cols:
			x -= PERIMETER_W * 0.5
		col_x.append(snappedf(x, 0.01))
	row_theta.clear()
	for j in rows + 1:
		row_theta.append(-span * 0.5 + span * float(j) / float(rows))


func _dir(k: int) -> int:
	return int(decks[k]["dir"])


## The one vehicle-capable connection from every deck to the next, at the far end of that deck's crossing: a ramp out of
## the spine when one fits, else (or by choice) a freight lift in a pillar beside the spine.
func _place_critical() -> void:
	var prev := ""
	for k in deck_count - 1:
		var d := _dir(k)
		var far_row := rows - 1 if d > 0 else 0
		var top_line := rows - 1 if d > 0 else 1
		var row_len := span / float(rows) * radius_of(k)
		var need := int(ceil(p("pitch") / p("ramp_grade") / row_len))
		var fits := need <= rows - 2
		var chance := 0.5 if prev == "" else (0.3 if prev == "ramp" else 0.75)
		var roll := _rng.randf()
		var side := _rng.randi_range(0, 1)
		if fits and roll < chance:
			var lane := "ramp_a" if k % 2 == 0 else "ramp_b"
			var foot_line := top_line - d * need
			var lx := lane_x(lane)
			var col := spine_line - 1 if lane == "ramp_a" else spine_line
			var foot_row := foot_line - 1 if d > 0 else foot_line
			connectors.append(_connector("ramp", "critical", k, k + 1, {
				"lane": lane, "top_line": top_line, "foot_line": foot_line, "x0": lx.x, "x1": lx.y,
				"theta0": minf(row_theta[top_line], row_theta[foot_line]),
				"theta1": maxf(row_theta[top_line], row_theta[foot_line]),
				"col": col, "row": far_row, "foot_row": foot_row,
				"top": {"deck": k, "i": spine_line, "j": top_line},
				"bottom": {"deck": k + 1, "i": spine_line, "j": foot_line}}))
			_reserved[k][_key(col, far_row)] = true
			_reserved[k + 1][_key(col, foot_row)] = true
			prev = "ramp"
		else:
			_add_lift(spine_line - 1 + side, far_row, [k, k + 1], "critical", false)
			prev = "lift"


## A lift in the pillar of cell (c, r) serving `stops`. A second lift asked for in the same pillar extends the first.
func _add_lift(c: int, r: int, stops: Array, role: String, locked: bool) -> void:
	var key := _key(c, r)
	if _lift_cells.has(key):
		var old: Dictionary = connectors[int(_lift_cells[key])]
		var lo := mini(int(old["from"]), int(stops[0]))
		var hi := maxi(int(old["to"]), int(stops[-1]))
		old["from"] = lo
		old["to"] = hi
		old["stops"] = range(lo, hi + 1)
		(old["top"] as Dictionary)["deck"] = lo
		(old["bottom"] as Dictionary)["deck"] = hi
		# The first lift asked for in this pillar keeps its role and lock: a critical lift stays the open way down.
		for k: int in old["stops"]:
			_reserved[k][key] = true
		return
	# The lift opens onto the spine at cross line r (its cell's near edge), except in row 0, where line 0 is the
	# perimeter road against the bulkhead: it uses line 1 instead.
	var j := 1 if r == 0 else r
	_lift_cells[key] = connectors.size()
	connectors.append(_connector("lift", role, int(stops[0]), int(stops[-1]), {
		"col": c, "row": r, "stops": stops.duplicate(), "locked": locked,
		"top": {"deck": int(stops[0]), "i": spine_line, "j": j},
		"bottom": {"deck": int(stops[-1]), "i": spine_line, "j": j}}))
	for k: int in stops:
		_reserved[k][key] = true


func _connector(kind: String, role: String, from: int, to: int, more: Dictionary) -> Dictionary:
	var c := {"id": connectors.size(), "kind": kind, "role": role, "from": from, "to": to, "stops": [from, to],
			"vehicles": kind != "shaft", "two_way": kind != "shaft", "locked": false,
			"x0": 0.0, "x1": 0.0, "theta0": 0.0, "theta1": 0.0, "col": -1, "row": -1, "foot_row": -1, "pillar": -1,
			"top": {}, "bottom": {}, "lane": "", "top_line": -1, "foot_line": -1}
	for id: String in more:
		c[id] = more[id]
	return c


## The express freight lift: one pillar mid-section that stops on every deck. A branch, locked by the occupation until
## the crew opens it (an objective hook), so it never replaces the route down.
func _place_express() -> void:
	if p("express") < 0.5:
		return
	var c := spine_line - 1 + _rng.randi_range(0, 1)
	_add_lift(c, rows / 2, range(deck_count), "branch", true)


## Entry: the spine's portal through the bulkhead on the top deck. Extraction: the spine's portal at the far end of the
## lowest deck's crossing.
func _place_ends() -> void:
	var side := _rng.randi_range(0, 1)
	entry = {"deck": 0, "i": spine_line, "j": 0, "col": spine_line - 1 + side, "row": 0}
	_reserved[0][_key(int(entry["col"]), 0)] = true
	var last := deck_count - 1
	var d := _dir(last)
	var side2 := _rng.randi_range(0, 1)
	extraction = {"deck": last, "i": spine_line, "j": rows if d > 0 else 0, "col": spine_line - 1 + side2,
			"row": rows - 1 if d > 0 else 0}
	_reserved[last][_key(int(extraction["col"]), int(extraction["row"]))] = true


## Open-air shafts: holes a mech can drop through, mid-crossing. The cell loses its pillar on EVERY deck (a long-span
## bay), so the load path of every other column stays unbroken; two such bays never share an edge.
func _place_shafts() -> void:
	var want := clampi(int(round(p("shafts"))), 0, 4)
	for k in deck_count - 1:
		var mid: Array[int] = []
		var rest: Array[int] = []
		for r in rows:
			for c in cols:
				var key := _key(c, r)
				if _lift_cells.has(key) or _reserved[k].has(key) or _reserved[k + 1].has(key):
					continue
				var t := (float(r) + 0.5) / float(rows)
				if t >= 0.25 and t <= 0.75:
					mid.append(key)
				else:
					rest.append(key)
		_shuffle(mid)
		_shuffle(rest)
		var placed := 0
		for key: int in mid + rest:
			if placed >= want:
				break
			var c := key % 64
			var r := key / 64
			if _beside_long_span(c, r):
				continue
			var rect := cell_rect(k, c, r)
			var size := minf(SHAFT_MAX, minf(rect.size.x, rect.size.y) - SHAFT_MARGIN * 2.0)
			if size < 16.0:
				continue
			var mid_pt := rect.get_center()
			var half_t := size * 0.5 / radius_of(k)
			var th := mid_pt.y / radius_of(k)
			connectors.append(_connector("shaft", "shortcut", k, k + 1, {
				"col": c, "row": r, "x0": mid_pt.x - size * 0.5, "x1": mid_pt.x + size * 0.5,
				"theta0": th - half_t, "theta1": th + half_t}))
			_omit[key] = true
			placed += 1


func _beside_long_span(c: int, r: int) -> bool:
	for n: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nc := c + n.x
		var nr := r + n.y
		# Bounds first: _key packs (c, r) into one int, so an off-grid column would alias a cell on the next row.
		if nc >= 0 and nc < cols and nr >= 0 and nr < rows and _omit.has(_key(nc, nr)):
			return true
	return false


func _shuffle(a: Array[int]) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := a[i]
		a[i] = a[j]
		a[j] = tmp


## One pillar per cell, at the same angle and x on every deck (a continuous column from the hull to the top deck).
func _make_pillars(jitter: Array[Vector2]) -> void:
	for r in rows:
		for c in cols:
			var key := _key(c, r)
			if _omit.has(key):
				continue
			var top := cell_rect(0, c, r)     # the top deck's cells are the shortest: stay inside those
			var room := Vector2(maxf(top.size.x * 0.5 - LIFT_HALF - CONNECT_CLEAR, 0.0),
					maxf(top.size.y * 0.5 - LIFT_HALF - CONNECT_CLEAR, 0.0))
			var j := jitter[r * cols + c]
			var x := top.get_center().x + j.x * minf(PILLAR_JITTER, room.x)
			var s := top.get_center().y + j.y * minf(PILLAR_JITTER, room.y)
			var id := pillars.size()
			var q := {"id": id, "col": c, "row": r, "x": snappedf(x, 0.01), "theta": s / radius_of(0), "lift": false,
					"stops": []}
			if _lift_cells.has(key):
				var lift: Dictionary = connectors[int(_lift_cells[key])]
				q["lift"] = true
				q["stops"] = (lift["stops"] as Array).duplicate()
				lift["pillar"] = id
				var half_t := LIFT_PLATFORM * 0.5 / radius_of(int(lift["from"]))
				lift["x0"] = float(q["x"]) - LIFT_PLATFORM * 0.5
				lift["x1"] = float(q["x"]) + LIFT_PLATFORM * 0.5
				lift["theta0"] = float(q["theta"]) - half_t
				lift["theta1"] = float(q["theta"]) + half_t
			_pillar_of[key] = id
			pillars.append(q)


# --- Zones -----------------------------------------------------------------------------------------------

## Zone every cell of deck k. Fixed first: transit where the route enters, leaves or changes deck; open air where a
## shaft is cut; a park where a shaft from above lands. The rest is rolled along the crossing, so the deck paces as
## tight city on arrival -> open ground in the middle -> the transit chokepoint at the way down.
func _fill_zones(k: int) -> void:
	var z: Array = decks[k]["zones"]
	for key: int in _reserved[k]:
		z[key / 64][key % 64] = "transit"
	for ci in connectors.size():
		var cn: Dictionary = connectors[ci]
		if cn["kind"] != "shaft":
			continue
		var c := int(cn["col"])
		var r := int(cn["row"])
		if int(cn["from"]) == k:
			z[r][c] = "open"
		elif int(cn["to"]) == k:
			if z[r][c] == "":
				z[r][c] = "park"
			(decks[k]["keep_clear"] as Array).append(connector_rect(ci, k).grow(4.0))
	var d := _dir(k)
	for step in rows:
		var r := step if d > 0 else rows - 1 - step
		var t := (float(step) + 0.5) / float(rows)      # 0 at arrival, 1 at the way down
		for c in cols:
			if z[r][c] != "":
				continue
			var w := {"urban": p("w_urban") * (1.6 if t < 0.35 else 1.0),
					"park": p("w_park") * (2.0 if t >= 0.3 and t <= 0.75 else 0.5),
					"industrial": p("w_industrial") * (0.6 + 0.4 * float(k)) * (1.6 if c == 0 or c == cols - 1 else 1.0)}
			for n: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nc := c + n.x
				var nr := r + n.y
				if nc < 0 or nc >= cols or nr < 0 or nr >= rows:
					continue
				var nz := str(z[nr][nc])
				if w.has(nz):
					w[nz] = float(w[nz]) * 1.9          # districts clump
				if nz == "open":
					w["park"] = float(w["park"]) * 1.9   # green around a shaft
				if _lift_cells.has(_key(nc, nr)):
					w["industrial"] = float(w["industrial"]) * 1.5     # freight yards by the lifts
			z[r][c] = _roll(w)
	# Recreation between the key areas: every deck gets at least one park when parks are wanted at all.
	if p("w_park") > 0.001 and not _has_zone(k, "park"):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for r in rows:
			for c in cols:
				if z[r][c] != "urban" and z[r][c] != "industrial":
					continue
				var dist := absf(float(r) + 0.5 - float(rows) * 0.5) + absf(float(c) + 0.5 - float(cols) * 0.5) * 0.1
				if dist < best_d:
					best_d = dist
					best = Vector2i(c, r)
		if best.x >= 0:
			z[best.y][best.x] = "park"


func _roll(w: Dictionary) -> String:
	var total := 0.0
	for id: String in w:
		total += maxf(float(w[id]), 0.0)
	if total <= 0.0001:
		return "urban"
	var x := _rng.randf() * total
	for id: String in w:
		x -= maxf(float(w[id]), 0.0)
		if x <= 0.0:
			return id
	return "urban"


func _has_zone(k: int, kind: String) -> bool:
	for row: Array in decks[k]["zones"]:
		if row.has(kind):
			return true
	return false


## Regions: neighbouring cells of one zone joined into a district (what the city generator fills in one go).
func _make_regions(k: int) -> void:
	var seen := {}
	var out := []
	for r in rows:
		for c in cols:
			if seen.has(_key(c, r)):
				continue
			var kind := zone(k, c, r)
			var cells: Array[Vector2i] = []
			var stack: Array[Vector2i] = [Vector2i(c, r)]
			seen[_key(c, r)] = true
			var rect := cell_rect(k, c, r)
			while not stack.is_empty():
				var cell: Vector2i = stack.pop_back()
				cells.append(cell)
				rect = rect.merge(cell_rect(k, cell.x, cell.y))
				for n: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var q := cell + n
					if q.x < 0 or q.x >= cols or q.y < 0 or q.y >= rows or seen.has(_key(q.x, q.y)):
						continue
					if zone(k, q.x, q.y) == kind:
						seen[_key(q.x, q.y)] = true
						stack.append(q)
			cells.sort()
			out.append({"kind": kind, "cells": cells, "rect": rect})
	decks[k]["regions"] = out


func _make_roads() -> void:
	for i in cols + 1:
		var kind := "spine" if i == spine_line else ("perimeter" if i == 0 or i == cols else "arterial")
		roads.append({"axis": "s", "line": i, "kind": kind, "width": line_width("s", i)})
	for j in rows + 1:
		roads.append({"axis": "x", "line": j, "kind": "perimeter" if j == 0 or j == rows else "cross",
				"width": line_width("x", j)})


# --- Graphs and the route --------------------------------------------------------------------------------

func node_id(k: int, i: int, j: int) -> int:
	return (k * (rows + 1) + j) * (cols + 1) + i


func node_of(id: int) -> Dictionary:
	var per := (rows + 1) * (cols + 1)
	return {"deck": id / per, "i": id % (cols + 1), "j": (id % per) / (cols + 1)}


func cell_id(k: int, c: int, r: int) -> int:
	return (k * rows + r) * cols + c


func cell_of(id: int) -> Dictionary:
	return {"deck": id / (rows * cols), "col": id % cols, "row": (id % (rows * cols)) / cols}


## What vehicles (and civilians on foot) can use: the road grid of every deck plus ramps and lifts. Adjacency list:
## node id -> [[other, cost, connector id or -1]]. `locked` adds the locked connectors (the express lift).
func road_graph(locked: bool = true) -> Array:
	var adj := []
	adj.resize(deck_count * (rows + 1) * (cols + 1))
	for i in adj.size():
		adj[i] = []
	for k in deck_count:
		for j in rows + 1:
			for i in cols + 1:
				if j < rows:
					_link(adj, node_id(k, i, j), node_id(k, i, j + 1), absf(line_s(k, j + 1) - line_s(k, j)), -1)
				if i < cols and not _crossing_blocked(k, i, j):
					_link(adj, node_id(k, i, j), node_id(k, i + 1, j), col_x[i + 1] - col_x[i], -1)
	for c: Dictionary in connectors:
		if not c["vehicles"] or (c["locked"] and not locked):
			continue
		if c["kind"] == "ramp":
			var a: Dictionary = c["top"]
			var b: Dictionary = c["bottom"]
			_link(adj, node_id(a["deck"], a["i"], a["j"]), node_id(b["deck"], b["i"], b["j"]),
					(float(c["theta1"]) - float(c["theta0"])) * radius_of(int(c["from"])), int(c["id"]))
		else:
			var st: Array = c["stops"]
			for n in st.size() - 1:
				_link(adj, node_id(st[n], c["top"]["i"], c["top"]["j"]), node_id(st[n + 1], c["top"]["i"], c["top"]["j"]),
						LIFT_COST, int(c["id"]))
	return adj


## A ramp coming down from the deck above blocks the cross road where it is too low to drive under (at its foot).
func _crossing_blocked(k: int, i: int, j: int) -> bool:
	for c: Dictionary in connectors:
		if c["kind"] != "ramp" or int(c["to"]) != k:
			continue
		if i != (spine_line - 1 if c["lane"] == "ramp_a" else spine_line):
			continue
		var n := absi(int(c["top_line"]) - int(c["foot_line"]))
		var h := clear_height() * float(absi(j - int(c["foot_line"]))) / float(n)
		var inside := (j - int(c["foot_line"])) * (int(c["top_line"]) - int(c["foot_line"])) >= 0 and absi(j - int(c["foot_line"])) <= n
		if inside and h < VEHICLE_CLEARANCE:
			return true
	return false


## What a mech can use: every cell of every deck (walk, jump), ramps, lifts, and shafts as one-way drops.
func mech_graph(locked: bool = false) -> Array:
	var adj := []
	adj.resize(deck_count * rows * cols)
	for i in adj.size():
		adj[i] = []
	for k in deck_count:
		for r in rows:
			for c in cols:
				var here := cell_rect(k, c, r).get_center()
				if c + 1 < cols:
					_link(adj, cell_id(k, c, r), cell_id(k, c + 1, r), cell_rect(k, c + 1, r).get_center().distance_to(here), -1)
				if r + 1 < rows:
					_link(adj, cell_id(k, c, r), cell_id(k, c, r + 1), cell_rect(k, c, r + 1).get_center().distance_to(here), -1)
	for c: Dictionary in connectors:
		if c["locked"] and not locked:
			continue
		var col := int(c["col"])
		var row := int(c["row"])
		match str(c["kind"]):
			"ramp":
				_link(adj, cell_id(c["from"], col, row), cell_id(c["to"], col, c["foot_row"]),
						(float(c["theta1"]) - float(c["theta0"])) * radius_of(int(c["from"])), int(c["id"]))
			"lift":
				var st: Array = c["stops"]
				for n in st.size() - 1:
					_link(adj, cell_id(st[n], col, row), cell_id(st[n + 1], col, row), LIFT_COST, int(c["id"]))
			"shaft":
				(adj[cell_id(c["from"], col, row)] as Array).append([cell_id(c["to"], col, row), 25.0, int(c["id"])])
	return adj


func _link(adj: Array, a: int, b: int, cost: float, via: int) -> void:
	(adj[a] as Array).append([b, cost, via])
	(adj[b] as Array).append([a, cost, via])


## Shortest distances from `start` over an adjacency list: {dist: [float] (INF = unreachable), prev: [int]}.
static func walk(adj: Array, start: int) -> Dictionary:
	var dist: Array[float] = []
	var prev: Array[int] = []
	var done: Array[bool] = []
	dist.resize(adj.size())
	prev.resize(adj.size())
	done.resize(adj.size())
	dist.fill(INF)
	prev.fill(-1)
	done.fill(false)
	dist[start] = 0.0
	while true:
		var u := -1
		var best := INF
		for i in adj.size():
			if not done[i] and dist[i] < best:
				best = dist[i]
				u = i
		if u < 0:
			break
		done[u] = true
		for e: Array in adj[u]:
			var v: int = e[0]
			if dist[u] + float(e[1]) < dist[v]:
				dist[v] = dist[u] + float(e[1])
				prev[v] = u
	return {"dist": dist, "prev": prev}


static func path_to(found: Dictionary, target: int) -> Array[int]:
	var out: Array[int] = []
	if (found["dist"] as Array)[target] == INF:
		return out
	var at := target
	while at >= 0:
		out.append(at)
		at = (found["prev"] as Array)[at]
	out.reverse()
	return out


func entry_node() -> int:
	return node_id(0, int(entry["i"]), int(entry["j"]))


func extraction_node() -> int:
	return node_id(int(extraction["deck"]), int(extraction["i"]), int(extraction["j"]))


func entry_cell() -> int:
	return cell_id(0, int(entry["col"]), int(entry["row"]))


func extraction_cell() -> int:
	return cell_id(int(extraction["deck"]), int(extraction["col"]), int(extraction["row"]))


## The planned route: for vehicles along roads, ramps and unlocked lifts; for mechs the shortest way, shafts included.
func _make_route() -> void:
	var v := walk(road_graph(false), entry_node())
	var vp: Array = []
	for id in path_to(v, extraction_node()):
		vp.append(node_of(id))
	var m := walk(mech_graph(false), entry_cell())
	var mp: Array = []
	for id in path_to(m, extraction_cell()):
		mp.append(cell_of(id))
	route = {"vehicle": vp, "mech": mp, "vehicle_len": float((v["dist"] as Array)[extraction_node()]),
			"mech_len": float((m["dist"] as Array)[extraction_cell()])}


# --- Boundaries ------------------------------------------------------------------------------------------

## The section is an arc segment of the ring, walled on all four sides on every deck. A wall is a structural BULKHEAD
## (solid: the city is built up to it) or a pressure wall with WINDOWS onto the rest of the habitat (the low-detail ring
## beyond is the backdrop, so the curve still reads). Where a road meets a wall there is a gate: the PORTAL the crew
## enters or leaves by, a BLAST DOOR the occupiers have sealed, or a COLLAPSED transit tunnel. Roads without a gate end
## at the perimeter road that runs along the inside of every wall.
func _make_boundaries() -> void:
	for k in deck_count:
		for edge in EDGES:
			var arc_end := edge.begins_with("s")
			var j_end := 0 if edge == "s0" else rows
			var is_entry: bool = arc_end and k == 0 and int(entry["j"]) == j_end
			var is_exit: bool = arc_end and k == int(extraction["deck"]) and int(extraction["j"]) == j_end
			# The ends of the arc are where the ring's curve shows, so they are windows more often than the sides.
			# The walls the crew passes through are always bulkheads: a gate in a solid wall.
			var window := _rng.randf() < (0.65 if arc_end else 0.25) and not is_entry and not is_exit
			var gates := []
			if arc_end:
				for i in range(1, cols):
					var at := node_pos(k, i, j_end)
					var kind := "blast_door"
					var role := ""
					var roll := _rng.randf()
					if i == spine_line:
						if is_entry or is_exit:
							kind = "portal"
							role = "entry" if is_entry else "extraction"
						elif roll < 0.4:
							kind = "collapsed"
					gates.append({"kind": kind, "role": role, "axis": "s", "line": i, "x": at.x,
							"s": row_theta[j_end] * radius_of(k), "width": line_width("s", i)})
			else:
				var i_end := 0 if edge == "x0" else cols
				for j in range(1, rows):
					if _rng.randf() >= 0.3:
						continue       # most cross streets just end at the perimeter road
					gates.append({"kind": "blast_door", "role": "", "axis": "x", "line": j,
							"x": p("width") * (-0.5 if i_end == 0 else 0.5), "s": line_s(k, j), "width": line_width("x", j)})
			boundaries.append({"deck": k, "edge": edge, "kind": "window" if window else "bulkhead", "backdrop": window,
					"gates": gates})


func boundary(k: int, edge: String) -> Dictionary:
	return boundaries[k * 4 + EDGES.find(edge)]


## The wall of `edge` on deck k as a Rect2 (x, s): WALL_T thick, just outside the section's ground, floor to ceiling.
func boundary_rect(k: int, edge: String) -> Rect2:
	var w := p("width")
	var a := arc_of(k)
	match edge:
		"s0": return Rect2(-w * 0.5 - WALL_T, -a * 0.5 - WALL_T, w + WALL_T * 2.0, WALL_T)
		"s1": return Rect2(-w * 0.5 - WALL_T, a * 0.5, w + WALL_T * 2.0, WALL_T)
		"x0": return Rect2(-w * 0.5 - WALL_T, -a * 0.5, WALL_T, a)
	return Rect2(w * 0.5, -a * 0.5, WALL_T, a)


# --- Deck view -------------------------------------------------------------------------------------------

## Everything a geometry builder needs for deck k, in that deck's (x, s) (shape in the header). Read-only: it rolls
## nothing and changes nothing, so building geometry can never shift the plan or its checksum.
func deck_view(k: int) -> Dictionary:
	var w := p("width")
	var a := arc_of(k)
	var extent := Rect2(-w * 0.5, -a * 0.5, w, a)
	var region_of := {}      # cell key -> index of its region on this deck
	var regions: Array = decks[k]["regions"]
	for ri in regions.size():
		for cell: Vector2i in regions[ri]["cells"]:
			region_of[_key(cell.x, cell.y)] = ri
	var blocks := []
	for r in rows:
		for c in cols:
			blocks.append({"col": c, "row": r, "rect": cell_rect(k, c, r), "zone": zone(k, c, r),
					"region": int(region_of.get(_key(c, r), -1)), "pillar": pillar_at(c, r)})
	var pils := []
	for q: Dictionary in pillars:
		var id := int(q["id"])
		var pt := pillar_point(k, id)
		var kind := pillar_style(k, id)
		pils.append({"id": id, "col": int(q["col"]), "row": int(q["row"]), "x": pt.x, "s": pt.y,
				"half": pillar_radius(k, id), "kind": kind, "lift": kind == "lift"})
	var cons := []
	for ci in connectors.size():
		var cn: Dictionary = connectors[ci]
		var part := ""
		if cn["kind"] == "lift":
			if (cn["stops"] as Array).has(k):
				part = "stop"
		elif int(cn["from"]) == k:
			part = "hole"
		elif int(cn["to"]) == k:
			part = "landing"
		if part != "":
			cons.append({"id": int(cn["id"]), "kind": str(cn["kind"]), "role": str(cn["role"]), "locked": bool(cn["locked"]),
					"part": part, "rect": connector_rect(ci, k)})
	# The deck above's floor holes are this deck's ceiling openings: same angles, so connector_rect at this radius.
	var openings := []
	if k > 0:
		for ci in connectors.size():
			if is_hole(ci, k - 1):
				openings.append({"connector": ci, "kind": str(connectors[ci]["kind"]), "rect": connector_rect(ci, k)})
	var walls := []
	for edge in EDGES:
		var b := boundary(k, edge)
		walls.append({"edge": edge, "kind": str(b["kind"]), "backdrop": bool(b["backdrop"]), "rect": boundary_rect(k, edge),
				"gates": (b["gates"] as Array).duplicate(true)})
	return {"deck": k, "radius": radius_of(k), "clear_height": clear_height(), "slab": p("slab"), "extent": extent,
			"blocks": blocks, "pillars": pils, "road_strips": _road_strips(k, extent), "connectors": cons,
			"ceiling_openings": openings, "keep_clear": (decks[k]["keep_clear"] as Array).duplicate(), "walls": walls}


## The road surface of deck k as strips: longitudinal lines run the whole arc, cross lines the whole width, and the
## spine is split into its lanes (ramps, avenue and rail are built differently).
func _road_strips(k: int, extent: Rect2) -> Array:
	var out := []
	for i in cols + 1:
		if i == spine_line:
			for l: Array in SPINE_LANES:
				var lx := lane_x(str(l[0]))
				var kind := "ramp_lane" if str(l[0]).begins_with("ramp") else str(l[0])
				out.append({"rect": Rect2(lx.x, extent.position.y, lx.y - lx.x, extent.size.y), "kind": kind, "axis": "s",
						"line": i, "lane": str(l[0])})
			continue
		var hw := line_width("s", i) * 0.5
		out.append({"rect": Rect2(col_x[i] - hw, extent.position.y, hw * 2.0, extent.size.y),
				"kind": "perimeter" if i == 0 or i == cols else "arterial", "axis": "s", "line": i, "lane": ""})
	for j in rows + 1:
		var hw := line_width("x", j) * 0.5
		out.append({"rect": Rect2(extent.position.x, line_s(k, j) - hw, extent.size.x, hw * 2.0),
				"kind": "perimeter" if j == 0 or j == rows else "cross", "axis": "x", "line": j, "lane": ""})
	return out


# --- Hooks for the gameplay passes ------------------------------------------------------------------------

func _make_hooks() -> void:
	# Checkpoints hold the chokepoints: the head of every way down, and the locked express lift on every deck.
	for c: Dictionary in connectors:
		if c["kind"] == "shaft":
			continue
		if c["role"] == "critical":
			var a: Dictionary = c["top"]
			var st: Array = c["stops"]
			for n in st.size() - 1:      # at the upper end of every deck change it serves
				var at := node_pos(st[n], a["i"], a["j"])
				hooks.append({"kind": "checkpoint", "deck": int(st[n]), "x": at.x, "s": at.y, "connector": int(c["id"]), "size": "heavy"})
		else:
			for k: int in c["stops"]:
				var at := node_pos(k, c["top"]["i"], c["top"]["j"])
				hooks.append({"kind": "checkpoint", "deck": k, "x": at.x, "s": at.y, "connector": int(c["id"]), "size": "light"})
	# A cordon in front of every sealed door: the occupiers hold their side of the wall.
	for b: Dictionary in boundaries:
		for g: Dictionary in b["gates"]:
			if g["kind"] == "blast_door":
				var inset := PERIMETER_W * 0.5
				var gx := clampf(float(g["x"]), -p("width") * 0.5 + inset, p("width") * 0.5 - inset)
				var half := arc_of(int(b["deck"])) * 0.5 - inset
				hooks.append({"kind": "cordon", "deck": int(b["deck"]), "x": gx, "s": clampf(float(g["s"]), -half, half)})
	var on_route := {}
	for w: Dictionary in route["mech"]:
		on_route[cell_id(w["deck"], w["col"], w["row"])] = true
	for k in deck_count:
		# Stations and banners: every transit cell is a station front, the natural place for the occupier's signage.
		for reg: Dictionary in decks[k]["regions"]:
			var mid: Vector2 = (reg["rect"] as Rect2).get_center()
			if reg["kind"] == "transit":
				hooks.append({"kind": "station", "deck": k, "x": mid.x, "s": mid.y})
				hooks.append({"kind": "banner", "deck": k, "x": mid.x, "s": mid.y})
			elif reg["kind"] == "park":
				# A patrol loops the roads around each park (long sightlines: they see you coming).
				var cells: Array = reg["cells"]
				var lo: Vector2i = cells[0]
				var hi: Vector2i = cells[0]
				for cell: Vector2i in cells:
					lo = Vector2i(mini(lo.x, cell.x), mini(lo.y, cell.y))
					hi = Vector2i(maxi(hi.x, cell.x), maxi(hi.y, cell.y))
				hooks.append({"kind": "patrol", "deck": k, "x": mid.x, "s": mid.y, "loop": [
					node_pos(k, lo.x, lo.y), node_pos(k, hi.x + 1, lo.y), node_pos(k, hi.x + 1, hi.y + 1), node_pos(k, lo.x, hi.y + 1)]})
		# Surveillance pylons line the spine at every other cross road.
		for j in range(1, rows, 2):
			hooks.append({"kind": "pylon", "deck": k, "x": col_x[spine_line], "s": line_s(k, j)})
		# Civilians are held off the route: the built-up cell farthest from it (an optional branch worth the detour).
		var best := -1
		var best_d := -1.0
		for r in rows:
			for c in cols:
				if zone(k, c, r) != "urban" and zone(k, c, r) != "industrial":
					continue
				var near := INF
				for w: Dictionary in route["mech"]:
					if int(w["deck"]) == k:
						near = minf(near, absf(float(c - int(w["col"]))) + absf(float(r - int(w["row"]))))
				if near != INF and near > best_d:
					best_d = near
					best = cell_id(k, c, r)
		if best >= 0:
			var cell := cell_of(best)
			var mid := cell_rect(k, cell["col"], cell["row"]).get_center()
			hooks.append({"kind": "holding", "deck": k, "x": mid.x, "s": mid.y, "col": int(cell["col"]), "row": int(cell["row"])})


# --- Checksum --------------------------------------------------------------------------------------------

## Hex digest of everything in the plan. Equal on two machines = the same section.
func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	for v in [deck_count, cols, rows, spine_line]:
		buf.put_32(v)
	_put(buf, [p("radius"), p("pitch"), p("slab"), span * 1000.0])
	_put(buf, col_x)
	for t in row_theta:
		_put(buf, [t * 1000.0])     # micro-radians
	for dk: Dictionary in decks:
		for row: Array in dk["zones"]:
			for z: String in row:
				buf.put_8(ZONES.find(z))
		for r: Rect2 in dk["keep_clear"]:
			_put(buf, [r.position.x, r.position.y, r.size.x, r.size.y])
	for q: Dictionary in pillars:
		buf.put_32(int(q["col"]) + int(q["row"]) * 64)
		_put(buf, [q["x"], float(q["theta"]) * 1000.0])
		for k: int in q["stops"]:
			buf.put_8(k)
	for c: Dictionary in connectors:
		buf.put_utf8_string("%s:%s:%s" % [c["kind"], c["role"], c["lane"]])
		for v in [c["from"], c["to"], c["col"], c["row"], c["foot_row"], c["pillar"], c["top_line"], c["foot_line"]]:
			buf.put_32(int(v))
		buf.put_8((1 if c["vehicles"] else 0) + (2 if c["two_way"] else 0) + (4 if c["locked"] else 0))
		_put(buf, [c["x0"], c["x1"], float(c["theta0"]) * 1000.0, float(c["theta1"]) * 1000.0])
	for w: Dictionary in route["vehicle"]:
		buf.put_32(node_id(w["deck"], w["i"], w["j"]))
	for w: Dictionary in route["mech"]:
		buf.put_32(cell_id(w["deck"], w["col"], w["row"]))
	for h: Dictionary in hooks:
		buf.put_utf8_string(str(h["kind"]))
		buf.put_8(int(h["deck"]))
		_put(buf, [h["x"], h["s"]])
	for b: Dictionary in boundaries:
		buf.put_utf8_string("%s:%s" % [b["edge"], b["kind"]])
		for g: Dictionary in b["gates"]:
			buf.put_utf8_string("%s:%s:%s" % [g["kind"], g["role"], g["axis"]])
			buf.put_32(int(g["line"]))
	for e: Dictionary in [entry, extraction]:
		for v in [e["deck"], e["i"], e["j"], e["col"], e["row"]]:
			buf.put_32(int(v))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))     # millimetres: immune to float formatting
