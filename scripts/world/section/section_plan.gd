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
##                  HOP-ONLY RULE (validate()): every deck k+1 is reachable from deck k without a lift or a glide, by an
##                  unlocked ramp or a shaft whose drop lands on k+1's floor: walkable_down(k) / walkable_down_connector(k)
##                  (walkable_up(k): a ramp; not enforced). Plans that break it are repaired (walk_repairs), no others.
##   roads       [{axis: "s" | "x", line, kind: spine | arterial | cross | perimeter, width}]
##   forms        per deck: {segment key: street | lane | pedestrian | none}: what stands in each road SEGMENT's strip
##                  (one stretch of a line between neighbouring crossings = one road-graph edge; key = seg_key(axis,
##                  line, index)). Geometry never moves with a form. Read through segment_form / line_segments /
##                  segments / carriageway (section "Road segments"). Rolled last from a generator of its own.
##   entry / extraction   {deck, i, j, col, row}
##   route        {vehicle: [{deck, i, j}], mech: [{deck, col, row}], vehicle_len, mech_len}   vehicle: over the segments
##                  vehicles keep (road_graph), so it avoids pedestrian / none segments and unbridged ramp cuts
##   boundaries   [{deck, edge: s0 | s1 | x0 | x1, kind: bulkhead | window, backdrop, gates: [{kind: portal |
##                  blast_door | collapsed, role: entry | extraction | "", axis, line, x, s, width}]}]
##                  the four walls of every deck: s0 / s1 close the ends of the arc, x0 / x1 the sides (boundary_rect)
##   hooks        [{kind: checkpoint | cordon | patrol | pylon | banner | holding | station, deck, x, s, ...}]
##
## DECK VIEW. `deck_view(k)` gathers what a geometry builder needs for one deck, in that deck's (x, s), read-only:
##   {deck, radius, clear_height, slab, extent: Rect2 (the ground inside the walls),
##    blocks [{col, row, rect, zone, region (index into decks[k].regions), pillar (id or -1)}]   row-major
##    pillars [{id, col, row, x, s, half, kind, lift}],
##    road_strips [{rect, kind: perimeter | arterial | cross | avenue | rail | ramp_lane, axis, line, lane, index, form}]
##                 one per road segment (the spine's split per lane), crossing centre to crossing centre; blocks +
##                 strips tile the extent; strips overlap only where roads cross,
##    connectors [{id, kind, role, locked, part: hole | landing | stop, rect}]   a ramp's hole runs along its spine lane
##                 across the cross-road strips (cross streets bridge the cut, except at bridge_lines: there the cut runs
##                 on under the road and the segment is `blocked`): builders cut it out of every strip it intersects,
##                 or bridge it,
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
const SAFE_RADIUS := 70.0        ## encounter sites closer than this to a deck's arrival get no enemies (§16)
const FIRST_CONTACT_DIST := 110.0   ## how far past the arrival the first enemy group waits, along the avenue (§16)
const FIRST_CONTACT_SHARE := 0.4    ## ... but at most this fraction of the deck's arrival -> departure distance along s
const MERGE_DIST := 40.0        ## encounter sites closer than this are one place (the more specific kind wins)
## Encounter site kinds, most specific first: on a merge the earlier kind names the site (encounter_sites).
const SITE_PRIORITY: Array[String] = ["extraction", "departure", "checkpoint", "shaft_exit", "branch_landing", "holding",
		"station", "patrol", "cordon", "first_contact"]
const SITE_WEIGHT := {"light": 1.0, "medium": 2.0, "heavy": 4.0}

## A cross road bridges a ramp's cut only where a mech walking down the ramp clears the bridge's underside by this much
## (CityPlan.BRIDGE_CLEAR: mech 8 m + 1.5 m); elsewhere the cut runs on under the road and nothing drives across it.
const BRIDGE_CLEARANCE := 9.5
## Road segment forms (what stands in a segment's reserved strip; the strip itself never moves).
const FORMS: Array[String] = ["street", "lane", "pedestrian", "none"]
## Carriageway width of each form; -1 = the road line's own width.
const FORM_WIDTH := {"street": -1.0, "lane": 8.0, "pedestrian": 0.0, "none": 0.0}
const FORM_CLUSTER := 3.0        ## a lane / pedestrian segment after one of the same form along its line: chance x this
const CUT_TOUCH := 1.0           ## a segment this close to a floor cut / connector footprint stays a street

const DEFAULTS := {
	"seed": 1.0, "decks": 3.0, "arc": 540.0, "width": 270.0, "radius": 400.0, "pitch": 48.0, "slab": 8.0,
	"cell": 90.0, "ramp_grade": 0.18, "shafts": 1.0, "express": 1.0,
	"w_urban": 1.0, "w_park": 0.45, "w_industrial": 0.45,
	# Road segment forms: share of the minor segments rolled lane / pedestrian / none (the rest stay streets). Live since
	# 2026-11-23 (the city draws them); 0 / 0 / 0 makes every segment a street.
	"f_lane": 0.20, "f_pedestrian": 0.15, "f_none": 0.08,
	"bridge_rule": 1.0,      # 1: no road across a ramp's cut where a mech would not fit under the bridge (bridge_lines)
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
var forms: Array = []              ## per deck: segment key (seg_key) -> form, for every road segment of the deck
var repair_stats := {}             ## {rolled, repaired, stubs}: how many minor segments forms() rolled / gave back to street
var walk_repairs: Array = []       ## [{deck, how: ramp | restack | shaft, connector}]: what _ensure_walkable_down changed

var _rng := RandomNumberGenerator.new()
var _minor: Array = []             ## per deck: segment key -> true where the form was rolled (not a forced street)
var _cut: Array = []               ## per deck: segment key -> "bridge" | "foot": a cross segment no vehicle drives over
                                   ## (a "foot" is still walked: mechs and enemies keep it in the city graph)
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
		"boundaries": Net.LOCAL, "forms": Net.LOCAL,
		# all of the above are recomputed from params on every machine and verified by checksum()
		"repair_stats": Net.LOCAL, "walk_repairs": Net.LOCAL,
		"_rng": Net.LOCAL, "_pillar_of": Net.LOCAL, "_omit": Net.LOCAL, "_lift_cells": Net.LOCAL, "_reserved": Net.LOCAL,
		"_minor": Net.LOCAL, "_cut": Net.LOCAL,
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
	for id: String in ["f_lane", "f_pedestrian", "f_none"]:
		params[id] = clampf(p(id), 0.0, 1.0)
	forms.clear()
	_minor.clear()
	_cut.clear()
	repair_stats = {}
	walk_repairs = []
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
	_ensure_walkable_down()   # adds nothing (and rolls nothing) where every deck is already walkable from the one above
	_make_pillars(jitter)
	for k in deck_count:
		_fill_zones(k)
		_make_regions(k)
	_make_roads()
	_make_cuts()
	_make_route()          # every segment a street here: the route forms() keeps a street
	_make_boundaries()
	_make_hooks()
	# Segment forms come last, from a generator of their own: nothing rolled above moves for any seed.
	_make_forms()
	_make_route()          # the vehicle route again, over the segments vehicles keep (it may lengthen); mechs: unchanged


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
		var spec := _ramp_at(k, _ramp_lane(k))
		var fits := not spec.is_empty()
		var chance := 0.5 if prev == "" else (0.3 if prev == "ramp" else 0.75)
		var roll := _rng.randf()
		var side := _rng.randi_range(0, 1)
		if fits and roll < chance:
			_add_ramp(k, spec, "critical")
			prev = "ramp"
		else:
			_add_lift(spine_line - 1 + side, far_row, [k, k + 1], "critical", false)
			prev = "lift"


## The spine lane the ramp from deck k dives out of: they alternate, so a ramp's foot and the next ramp's head never
## share a lane on the deck between them.
func _ramp_lane(k: int) -> String:
	return "ramp_a" if k % 2 == 0 else "ramp_b"


## The ramp from deck k down to k+1 in spine lane `lane`, at the far end of deck k's crossing (where a critical ramp
## goes), no steeper than ramp_grade: the connector fields, or {} when the grid has no room for its run.
func _ramp_at(k: int, lane: String) -> Dictionary:
	var d := _dir(k)
	var far_row := rows - 1 if d > 0 else 0
	var top_line := rows - 1 if d > 0 else 1
	var row_len := span / float(rows) * radius_of(k)
	var need := int(ceil(p("pitch") / p("ramp_grade") / row_len))
	if need > rows - 2:
		return {}
	var foot_line := top_line - d * need
	var lx := lane_x(lane)
	var col := spine_line - 1 if lane == "ramp_a" else spine_line
	var foot_row := foot_line - 1 if d > 0 else foot_line
	return {"lane": lane, "top_line": top_line, "foot_line": foot_line, "x0": lx.x, "x1": lx.y,
			"theta0": minf(row_theta[top_line], row_theta[foot_line]),
			"theta1": maxf(row_theta[top_line], row_theta[foot_line]),
			"col": col, "row": far_row, "foot_row": foot_row,
			"top": {"deck": k, "i": spine_line, "j": top_line},
			"bottom": {"deck": k + 1, "i": spine_line, "j": foot_line}}


## Append the ramp `spec` (_ramp_at) from deck k; its head and foot cells become transit (stations).
func _add_ramp(k: int, spec: Dictionary, role: String) -> int:
	connectors.append(_connector("ramp", role, k, k + 1, spec))
	_reserved[k][_key(int(spec["col"]), int(spec["row"]))] = true
	_reserved[k + 1][_key(int(spec["col"]), int(spec["foot_row"]))] = true
	return connectors.size() - 1


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
			var more := _shaft_at(k, c, r)
			if more.is_empty():
				continue
			connectors.append(_connector("shaft", "shortcut", k, k + 1, more))
			_omit[key] = true
			placed += 1


## The shaft fields for cell (c, r) of deck k (the hole centred in the cell, SHAFT_MARGIN off its roads, at most
## SHAFT_MAX), or {} when the cell is too small for one.
func _shaft_at(k: int, c: int, r: int) -> Dictionary:
	var rect := cell_rect(k, c, r)
	var size := minf(SHAFT_MAX, minf(rect.size.x, rect.size.y) - SHAFT_MARGIN * 2.0)
	if size < 16.0:
		return {}
	var mid_pt := rect.get_center()
	var half_t := size * 0.5 / radius_of(k)
	var th := mid_pt.y / radius_of(k)
	return {"col": c, "row": r, "x0": mid_pt.x - size * 0.5, "x1": mid_pt.x + size * 0.5,
			"theta0": th - half_t, "theta1": th + half_t}


# --- The hop-only rule -------------------------------------------------------------------------------------
# Every deck k+1 is reachable from deck k by a mech that walks, hops at most 6 m and cannot glide (the Bulwark), with no
# lift (they do not carry mechs yet): down an unlocked ramp, or off the edge of a shaft from deck k whose drop lands on
# deck k+1's floor (one deck, `pitch` m: the automatic landing burn makes it a heavy landing, below fall damage). A shaft
# whose landing is itself a hole in deck k+1 (a stacked atrium: the next shaft down in the same cell) drops on to k+2:
# only a glide over the lower hole reaches deck k+1 that way. Walking UP needs a ramp (shafts are one way): see
# walkable_up(); not enforced (about half the deck pairs have none: docs/design/mission-section.md).

## The connector a hop-only mech takes from deck k down to k+1, or -1: an unlocked ramp k -> k+1 first (the lowest id),
## else the lowest-id shaft from deck k whose drop lands on deck k+1's floor.
func walkable_down_connector(k: int) -> int:
	var shaft := -1
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		if c["locked"] or int(c["from"]) != k or int(c["to"]) != k + 1:
			continue
		if c["kind"] == "ramp":
			return ci
		if c["kind"] == "shaft" and shaft < 0 and shaft_lands(ci):
			shaft = ci
	return shaft


## True when a hop-only mech can get from deck k down to deck k+1 without a lift or a glide (walkable_down_connector).
func walkable_down(k: int) -> bool:
	return walkable_down_connector(k) >= 0


## The connector a walking mech takes from deck k+1 back UP to deck k, or -1: an unlocked ramp k -> k+1 (shafts are one
## way, lifts do not carry mechs yet).
func walkable_up_connector(k: int) -> int:
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		if c["kind"] == "ramp" and not c["locked"] and int(c["from"]) == k and int(c["to"]) == k + 1:
			return ci
	return -1


func walkable_up(k: int) -> bool:
	return walkable_up_connector(k) >= 0


## What breaks the plan's hard rules, as readable lines ([] = valid): today the hop-only rule (walkable_down on every
## pair of adjacent decks). For the city and mission sides to assert.
func validate() -> Array[String]:
	var out: Array[String] = []
	for k in deck_count - 1:
		if not walkable_down(k):
			out.append("deck %d is not walkable from deck %d (no ramp, no shaft landing on its floor)" % [k + 1, k])
	return out


## True when shaft ci's drop lands on the floor of the deck below: its landing overlaps no hole in that deck.
func shaft_lands(ci: int) -> bool:
	var k := int(connectors[ci]["to"])
	var land := connector_rect(ci, k)
	for h in connectors.size():
		if h != ci and is_hole(h, k) and connector_rect(h, k).intersects(land):
			return false
	return true


## Guarantee the hop-only rule by construction, touching only the deck pairs that break it (every other plan stays
## byte-identical; nothing here rolls the generator). Per broken pair k, in order: a ramp k -> k+1 where a critical ramp
## goes (its spine lane, else the other one) that becomes the pair's critical connector (the lift it replaces turns
## branch); else the shaft under the stacked atrium moves to another cell, so the drop lands on deck k+1; else a shaft
## from deck k is cut where one fits.
func _ensure_walkable_down() -> void:
	for k in deck_count - 1:
		if walkable_down(k):
			continue
		var ci := _repair_ramp(k)
		if ci >= 0:
			walk_repairs.append({"deck": k, "how": "ramp", "connector": ci})
			continue
		ci = _restack_shaft(k)
		if ci >= 0:
			walk_repairs.append({"deck": k, "how": "restack", "connector": ci})
			continue
		ci = _repair_shaft(k)
		if ci >= 0:
			walk_repairs.append({"deck": k, "how": "shaft", "connector": ci})


func _repair_ramp(k: int) -> int:
	var lanes := [_ramp_lane(k), "ramp_b" if _ramp_lane(k) == "ramp_a" else "ramp_a"]
	for lane: String in lanes:
		var spec := _ramp_at(k, lane)
		if spec.is_empty() or not _ramp_room(k, spec):
			continue
		# The lift it replaces as the way down becomes a branch (when it serves only this pair: a lift merged into one
		# pillar with another critical lift stays critical, and _critical_between prefers the ramp).
		for c: Dictionary in connectors:
			if c["kind"] == "lift" and c["role"] == "critical" and int(c["from"]) == k and int(c["to"]) == k + 1:
				c["role"] = "branch"
		return _add_ramp(k, spec, "critical")
	return -1


## A ramp `spec` from deck k has room: no other ramp's footprint on either of its decks, and its head / foot cell (a
## station) is not cut by a shaft on that deck.
func _ramp_room(k: int, spec: Dictionary) -> bool:
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		if c["kind"] == "ramp":
			for dk in [k, k + 1]:
				if (c["stops"] as Array).has(dk) and _ramp_rect(spec, dk).intersects(connector_rect(ci, dk)):
					return false
		elif c["kind"] == "shaft":
			if int(c["from"]) == k and int(c["col"]) == int(spec["col"]) and int(c["row"]) == int(spec["row"]):
				return false
			if int(c["from"]) == k + 1 and int(c["col"]) == int(spec["col"]) and int(c["row"]) == int(spec["foot_row"]):
				return false
	return true


func _ramp_rect(spec: Dictionary, k: int) -> Rect2:
	var r := radius_of(k)
	return Rect2(float(spec["x0"]), float(spec["theta0"]) * r, float(spec["x1"]) - float(spec["x0"]),
			(float(spec["theta1"]) - float(spec["theta0"])) * r)


## Move the shaft of deck k+1 that a shaft from deck k drops into to another free cell (first free cell in the middle
## half of the crossing, then the rest, grid order): its id. -1 when there is no such shaft or no free cell.
func _restack_shaft(k: int) -> int:
	for ci in connectors.size():
		var top: Dictionary = connectors[ci]
		if top["kind"] != "shaft" or int(top["from"]) != k:
			continue
		var land := connector_rect(ci, k + 1)
		for h in connectors.size():
			var low: Dictionary = connectors[h]
			if low["kind"] != "shaft" or int(low["from"]) != k + 1 or not connector_rect(h, k + 1).intersects(land):
				continue
			var cell := _free_shaft_cell(k + 1)
			if cell.x < 0:
				continue
			var old_key := _key(int(low["col"]), int(low["row"]))
			var more := _shaft_at(k + 1, cell.x, cell.y)
			for id: String in more:
				low[id] = more[id]
			_omit[_key(cell.x, cell.y)] = true
			# The old cell keeps its long-span bay only while another shaft is still cut there (the one above, usually).
			var still := false
			for c: Dictionary in connectors:
				still = still or (c["kind"] == "shaft" and _key(int(c["col"]), int(c["row"])) == old_key)
			if not still:
				_omit.erase(old_key)
			return h
	return -1


## Cut a new shaft from deck k in a free cell: its id, or -1.
func _repair_shaft(k: int) -> int:
	var cell := _free_shaft_cell(k)
	if cell.x < 0:
		return -1
	connectors.append(_connector("shaft", "shortcut", k, k + 1, _shaft_at(k, cell.x, cell.y)))
	_omit[_key(cell.x, cell.y)] = true
	return connectors.size() - 1


## A cell for a shaft from deck k under _place_shafts' rules (no lift, not a station on k or k+1, no long-span bay
## beside it, big enough) that also stacks with no shaft above or below it, so its drop lands and nothing drops into it:
## the first in grid order in the middle half of the crossing, then the rest. Vector2i(-1, -1) if none.
func _free_shaft_cell(k: int) -> Vector2i:
	var stacked := {}
	for c: Dictionary in connectors:
		if c["kind"] == "shaft":
			stacked[_key(int(c["col"]), int(c["row"]))] = true
	for pass_ in 2:
		for r in rows:
			var t := (float(r) + 0.5) / float(rows)
			if (t >= 0.25 and t <= 0.75) != (pass_ == 0):
				continue
			for c in cols:
				var key := _key(c, r)
				if _lift_cells.has(key) or _reserved[k].has(key) or _reserved[k + 1].has(key) or stacked.has(key):
					continue
				if _beside_long_span(c, r) or _shaft_at(k, c, r).is_empty():
					continue
				return Vector2i(c, r)
	return Vector2i(-1, -1)


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


## What vehicles can use: the road segments of every deck vehicles keep (`street` and `lane`; not `pedestrian` / `none`,
## not across a ramp's cut where no bridge is (bridge_lines), not under a ramp's foot) plus ramps and lifts. Adjacency
## list: node id -> [[other, cost, connector id or -1]]. `locked` adds the locked connectors (the express lift).
func road_graph(locked: bool = true) -> Array:
	var adj := []
	adj.resize(deck_count * (rows + 1) * (cols + 1))
	for i in adj.size():
		adj[i] = []
	for k in deck_count:
		for j in rows + 1:
			for i in cols + 1:
				if j < rows and _drives(k, "s", i, j):
					_link(adj, node_id(k, i, j), node_id(k, i, j + 1), absf(line_s(k, j + 1) - line_s(k, j)), -1)
				if i < cols and _drives(k, "x", j, i):
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


## The cross lines of ramp ci's upper (`from`) deck with no bridge over its cut: strictly between its head and foot,
## where a mech walking down would not clear the road's underside (BRIDGE_CLEARANCE, measured on the ramp's centre line at
## the road's edge nearer the head). Empty for anything but a ramp, or with param bridge_rule 0. Default grade: exactly
## the first line past the head. (Never changes anything stored: the vehicle route keeps to the spine there.)
func bridge_lines(ci: int) -> Array[int]:
	var out: Array[int] = []
	var c: Dictionary = connectors[ci]
	if c["kind"] != "ramp" or p("bridge_rule") < 0.5:
		return out
	var k := int(c["from"])
	var top := int(c["top_line"])
	var foot := int(c["foot_line"])
	var s_top := line_s(k, top)
	var run := absf(line_s(k, foot) - s_top)
	for j in range(mini(top, foot) + 1, maxi(top, foot)):
		var d := absf(line_s(k, j) - s_top) - line_width("x", j) * 0.5
		if p("pitch") * d / run - p("slab") < BRIDGE_CLEARANCE:
			out.append(j)
	return out


## The cross segment of a ramp's lane: (spine_line - 1 <-> spine_line) for ramp_a, (spine_line <-> spine_line + 1) for B.
func _lane_index(c: Dictionary) -> int:
	return spine_line - 1 if c["lane"] == "ramp_a" else spine_line


## Which cross segments vehicles cannot cross whatever their form: over a ramp's cut with no bridge, under a ramp's foot.
func _make_cuts() -> void:
	for k in deck_count:
		var cut := {}
		for j in rows + 1:
			for i in cols:
				if _crossing_blocked(k, i, j):
					cut[seg_key("x", j, i)] = "foot"
		_cut.append(cut)
	for ci in connectors.size():
		for j in bridge_lines(ci):
			_cut[int(connectors[ci]["from"])][seg_key("x", j, _lane_index(connectors[ci]))] = "bridge"


# --- Road segments ---------------------------------------------------------------------------------------
# A SEGMENT is one stretch of a road line between two neighbouring crossings on one deck (an edge of the road graph):
# axis "s" line i index j runs from node (i, j) to (i, j + 1); axis "x" line j index i from (i, j) to (i + 1, j). Its
# FORM says what stands in its reserved strip (the strip never moves): street, lane (narrow, vehicles), pedestrian (no
# vehicles), none (no street: the two blocks either side are one superblock). Spine, perimeter, gate, checkpoint / cordon,
# ramp head / foot, lift lobby, floor-cut and vehicle-route segments are always streets; the rest (minor) are rolled from
# a generator of their own, then repaired so vehicles still reach everything (_make_forms).

## Key of a segment within its deck (forms[k]): axis bit * 65536 + line * 256 + index.
func seg_key(axis: String, line: int, index: int) -> int:
	return (65536 if axis == "x" else 0) + line * 256 + index


func _seg_count(axis: String) -> int:
	return rows if axis == "s" else cols


func _seg_lines(axis: String) -> int:
	return cols + 1 if axis == "s" else rows + 1


func _seg_nodes(k: int, axis: String, line: int, index: int) -> Vector2i:
	if axis == "s":
		return Vector2i(node_id(k, line, index), node_id(k, line, index + 1))
	return Vector2i(node_id(k, index, line), node_id(k, index + 1, line))


## The segment between two neighbouring road nodes: {deck, axis, line, index}, or {} if they are not neighbours.
func _seg_between(a: int, b: int) -> Dictionary:
	var n := deck_count * (rows + 1) * (cols + 1)
	if a < 0 or b < 0 or a >= n or b >= n:
		return {}
	var na := node_of(a)
	var nb := node_of(b)
	if int(na["deck"]) != int(nb["deck"]):
		return {}
	if na["i"] == nb["i"] and absi(int(na["j"]) - int(nb["j"])) == 1:
		return {"deck": na["deck"], "axis": "s", "line": int(na["i"]), "index": mini(na["j"], nb["j"])}
	if na["j"] == nb["j"] and absi(int(na["i"]) - int(nb["i"])) == 1:
		return {"deck": na["deck"], "axis": "x", "line": int(na["j"]), "index": mini(na["i"], nb["i"])}
	return {}


## A segment's strip on deck k: the line's width across, crossing centre to crossing centre along (out to the deck's
## edge at the ends), so the segments of a line tile its whole strip (deck_view road_strips).
func seg_rect(k: int, axis: String, line: int, index: int) -> Rect2:
	var hw := line_width(axis, line) * 0.5
	if axis == "s":
		var s0 := -arc_of(k) * 0.5 if index == 0 else line_s(k, index)
		var s1 := arc_of(k) * 0.5 if index == rows - 1 else line_s(k, index + 1)
		return Rect2(col_x[line] - hw, s0, hw * 2.0, s1 - s0)
	var x0 := -p("width") * 0.5 if index == 0 else col_x[index]
	var x1 := p("width") * 0.5 if index == cols - 1 else col_x[index + 1]
	return Rect2(x0, line_s(k, line) - hw, x1 - x0, hw * 2.0)


## The part of a segment's strip strictly between its two crossings (what a `none` segment gives to the superblock).
func seg_inner(k: int, axis: String, line: int, index: int) -> Rect2:
	var hw := line_width(axis, line) * 0.5
	if axis == "s":
		var s0 := line_s(k, index) + line_width("x", index) * 0.5
		var s1 := line_s(k, index + 1) - line_width("x", index + 1) * 0.5
		return Rect2(col_x[line] - hw, s0, hw * 2.0, s1 - s0)
	var x0 := col_x[index] + line_width("s", index) * 0.5
	var x1 := col_x[index + 1] - line_width("s", index + 1) * 0.5
	return Rect2(x0, line_s(k, line) - hw, x1 - x0, hw * 2.0)


## The cells a segment separates (one for a perimeter segment).
func _seg_cells(axis: String, line: int, index: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for side in [line - 1, line]:
		var cell := Vector2i(side, index) if axis == "s" else Vector2i(index, side)
		if cell.x >= 0 and cell.x < cols and cell.y >= 0 and cell.y < rows:
			out.append(cell)
	return out


func _form_of(k: int, axis: String, line: int, index: int) -> String:
	if k < 0 or k >= forms.size():
		return "street"
	return str((forms[k] as Dictionary).get(seg_key(axis, line, index), "street"))


## Vehicles drive this segment: its form keeps them and no ramp cut / foot is in the way.
func _drives(k: int, axis: String, line: int, index: int) -> bool:
	if axis == "x" and k < _cut.size() and (_cut[k] as Dictionary).has(seg_key(axis, line, index)):
		return false
	var f := _form_of(k, axis, line, index)
	return f == "street" or f == "lane"


## Form of the segment between neighbouring road nodes a and b on deck k (node ids as in road_graph, either order):
## street | lane | pedestrian | none; "" when a and b are not neighbours on deck k.
func segment_form(k: int, a: int, b: int) -> String:
	var sg := _seg_between(a, b)
	if sg.is_empty() or int(sg["deck"]) != k:
		return ""
	return _form_of(k, sg["axis"], sg["line"], sg["index"])


## Carriageway width of the segment a..b (FORM_WIDTH; a street is its line's width), 0 when not neighbours.
func carriageway(k: int, a: int, b: int) -> float:
	var sg := _seg_between(a, b)
	if sg.is_empty() or int(sg["deck"]) != k:
		return 0.0
	var w := float(FORM_WIDTH[_form_of(k, sg["axis"], sg["line"], sg["index"])])
	return line_width(sg["axis"], sg["line"]) if w < 0.0 else w


func _seg_dict(k: int, axis: String, line: int, index: int) -> Dictionary:
	var ab := _seg_nodes(k, axis, line, index)
	var key := seg_key(axis, line, index)
	return {"axis": axis, "line": line, "index": index, "a": ab.x, "b": ab.y, "form": _form_of(k, axis, line, index),
			"rect": seg_rect(k, axis, line, index), "inner": seg_inner(k, axis, line, index),
			"minor": k < _minor.size() and (_minor[k] as Dictionary).has(key),
			"blocked": str((_cut[k] as Dictionary).get(key, "")) if k < _cut.size() else ""}


## The segments of one road line on deck k, in order: [{axis, line, index, a, b, form, rect, inner, minor, blocked}].
## rect tiles the line's strip; inner is the stretch between the crossings; blocked: "" | "bridge" (a ramp's cut runs
## under, no bridge) | "foot" (a ramp's foot comes down on it): no vehicle drives across, whatever the form (a foot
## segment is still walked by mechs and enemies).
func line_segments(k: int, axis: String, line: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in _seg_count(axis):
		out.append(_seg_dict(k, axis, line, index))
	return out


## Every road segment of deck k (axis "s" lines first, then "x"; same shape as line_segments).
func segments(k: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for axis: String in ["s", "x"]:
		for line in _seg_lines(axis):
			out.append_array(line_segments(k, axis, line))
	return out


## Segments that stay streets whatever is rolled: per deck, segment key -> true.
func _forced_streets() -> Array:
	var out := []
	for k in deck_count:
		out.append({})
	var force := func(k: int, axis: String, line: int, index: int) -> void:
		if line >= 0 and line < _seg_lines(axis) and index >= 0 and index < _seg_count(axis):
			out[k][seg_key(axis, line, index)] = true
	var force_node := func(k: int, i: int, j: int) -> void:
		force.call(k, "s", i, j - 1)
		force.call(k, "s", i, j)
		force.call(k, "x", j, i - 1)
		force.call(k, "x", j, i)
	var force_touching := func(k: int, area: Rect2) -> void:
		for axis: String in ["s", "x"]:
			for line in _seg_lines(axis):
				for index in _seg_count(axis):
					if seg_rect(k, axis, line, index).intersects(area, true):
						force.call(k, axis, line, index)
	for k in deck_count:
		# The spine and the perimeter.
		for j in rows:
			for i: int in [0, spine_line, cols]:
				force.call(k, "s", i, j)
		for i in cols:
			force.call(k, "x", 0, i)
			force.call(k, "x", rows, i)
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		match str(c["kind"]):
			"ramp":
				# Head and foot: every segment at the spine's node and its neighbours on those cross lines.
				for i in [spine_line - 1, spine_line, spine_line + 1]:
					force_node.call(int(c["from"]), i, int(c["top_line"]))
					force_node.call(int(c["to"]), i, int(c["foot_line"]))
			"lift":
				# The lobby: the roads around the lift's cell and every segment at its spine node, on every stop.
				var cc := int(c["col"])
				var rr := int(c["row"])
				for k: int in c["stops"]:
					force.call(k, "x", rr, cc)
					force.call(k, "x", rr + 1, cc)
					force.call(k, "s", cc, rr)
					force.call(k, "s", cc + 1, rr)
					force_node.call(k, int(c["top"]["i"]), int(c["top"]["j"]))
		# Floor cuts and footprints (ramp cut / viaduct, shaft opening / landing, lift platform), upper and lower ends.
		var on: Array = c["stops"] if c["kind"] == "lift" else [int(c["from"]), int(c["to"])]
		for k: int in on:
			force_touching.call(k, connector_rect(ci, k).grow(CUT_TOUCH))
	# Gates: every segment ending at a door, portal or collapsed tunnel in a wall.
	for b: Dictionary in boundaries:
		var k := int(b["deck"])
		for g: Dictionary in b["gates"]:
			if g["axis"] == "s":
				force_node.call(k, int(g["line"]), 0 if b["edge"] == "s0" else rows)
			else:
				force_node.call(k, 0 if b["edge"] == "x0" else cols, int(g["line"]))
	# Checkpoints and cordons: the segments their spot stands on (all of them where it is a crossing).
	for h: Dictionary in hooks:
		if h["kind"] == "checkpoint" or h["kind"] == "cordon":
			var pt := Vector2(float(h["x"]), float(h["s"]))
			force_touching.call(int(h["deck"]), Rect2(pt, Vector2.ZERO).grow(CUT_TOUCH))
	# The vehicle route as planned with every segment a street.
	var way: Array = route["vehicle"]
	for n in range(1, way.size()):
		var a: Dictionary = way[n - 1]
		var b: Dictionary = way[n]
		if int(a["deck"]) != int(b["deck"]):
			continue
		var sg := _seg_between(node_id(a["deck"], a["i"], a["j"]), node_id(b["deck"], b["i"], b["j"]))
		if not sg.is_empty():
			force.call(int(sg["deck"]), sg["axis"], sg["line"], sg["index"])
	return out


## True where cell (c, r) of deck k holds a connector's footprint or is a connector's own cell there.
func _cell_has_connector(k: int, cell: Vector2i) -> bool:
	var rect := cell_rect(k, cell.x, cell.y)
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		var on: Array = c["stops"] if c["kind"] == "lift" else [int(c["from"]), int(c["to"])]
		if not on.has(k):
			continue
		var row := int(c["foot_row"]) if c["kind"] == "ramp" and int(c["to"]) == k else int(c["row"])
		if Vector2i(int(c["col"]), row) == cell or connector_rect(ci, k).intersects(rect):
			return true
	return false


## Roll every minor segment's form (own generator), then repair: vehicles keep one connected network over every node with
## a vehicle segment (entry and extraction on it, both ways), every cell keeps a vehicle side, and no crossing is left
## with exactly one drawn segment (a stub street). Repairs turn pedestrian / none segments back into streets.
func _make_forms() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(p("seed")) * 2654435761 + 1442695041
	var forced := _forced_streets()
	var rolled := 0
	for k in deck_count:
		var f := {}
		var minor := {}
		forms.append(f)
		_minor.append(minor)
		for axis: String in ["s", "x"]:
			for line in _seg_lines(axis):
				for index in _seg_count(axis):
					var key := seg_key(axis, line, index)
					if (forced[k] as Dictionary).has(key):
						f[key] = "street"
						continue
					minor[key] = true
					rolled += 1
					f[key] = _roll_form(rng, k, axis, line, index, str(f.get(seg_key(axis, line, index - 1), "street")))
	# A restored stub can strand a street behind pedestrian segments, and a repair can make a stub: until both hold.
	var repaired := 0
	var stubs := 0
	while true:
		repaired += _repair_forms()
		var more := _restore_stubs()
		stubs += more
		if more == 0:
			break
	repair_stats = {"rolled": rolled, "repaired": repaired, "stubs": stubs}


func _roll_form(rng: RandomNumberGenerator, k: int, axis: String, line: int, index: int, prev: String) -> String:
	var fl := p("f_lane")
	var fp := p("f_pedestrian")
	var fn := p("f_none")
	var st := maxf(1.0 - fl - fp - fn, 0.0)
	var zs := []
	var holds := false
	for cell in _seg_cells(axis, line, index):
		zs.append(zone(k, cell.x, cell.y))
		holds = holds or _cell_has_connector(k, cell)
	if zs.has("park") or zs.has("transit"):
		fp *= 2.0
	if zs.count("industrial") == zs.size():
		fn *= 2.0
	if zs.has("park") or zs.has("open") or zs.has("transit") or holds:
		fn = 0.0                       # a superblock only joins built blocks, never over a connector's cell
	if zs.count("urban") == zs.size():
		fl *= 1.5
	if prev == "pedestrian":
		fp *= FORM_CLUSTER
	elif prev == "lane":
		fl *= FORM_CLUSTER
	var x := rng.randf() * (st + fl + fp + fn)     # always one roll per minor segment
	if x < fl:
		return "lane"
	if x < fl + fp:
		return "pedestrian"
	if x < fl + fp + fn:
		return "none"
	return "street"


func _uf_find(parent: PackedInt32Array, a: int) -> int:
	while parent[a] != a:
		parent[a] = parent[parent[a]]
		a = parent[a]
	return a


func _uf_join(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)


## Greedy repair (deterministic): while a guarantee fails, the pedestrian / none segment whose return to street fixes the
## most (stranded vehicle nodes + cells without a vehicle side; ties: lowest deck, axis, line, index) becomes a street.
## Returns how many segments it gave back.
func _repair_forms() -> int:
	var segs := []        # [deck, axis, line, index, a, b, cell ids]
	for k in deck_count:
		for axis: String in ["s", "x"]:
			for line in _seg_lines(axis):
				for index in _seg_count(axis):
					var ab := _seg_nodes(k, axis, line, index)
					var cells := []
					for cell in _seg_cells(axis, line, index):
						cells.append(cell_id(k, cell.x, cell.y))
					segs.append([k, axis, line, index, ab.x, ab.y, cells])
	var n_nodes := deck_count * (rows + 1) * (cols + 1)
	var restored := 0
	while true:
		var parent := PackedInt32Array()
		parent.resize(n_nodes)
		for i in n_nodes:
			parent[i] = i
		var deg := PackedInt32Array()
		deg.resize(n_nodes)
		var sides := PackedInt32Array()
		sides.resize(deck_count * rows * cols)
		for sg: Array in segs:
			if _drives(sg[0], sg[1], sg[2], sg[3]):
				_uf_join(parent, sg[4], sg[5])
				deg[sg[4]] += 1
				deg[sg[5]] += 1
				for cid: int in sg[6]:
					sides[cid] += 1
		for c: Dictionary in connectors:
			if not c["vehicles"] or c["locked"]:
				continue
			if c["kind"] == "ramp":
				_uf_join(parent, node_id(c["top"]["deck"], c["top"]["i"], c["top"]["j"]),
						node_id(c["bottom"]["deck"], c["bottom"]["i"], c["bottom"]["j"]))
			else:
				var st: Array = c["stops"]
				for m in st.size() - 1:
					_uf_join(parent, node_id(st[m], c["top"]["i"], c["top"]["j"]), node_id(st[m + 1], c["top"]["i"], c["top"]["j"]))
		var main := _uf_find(parent, entry_node())
		var cnt := {}       # component root -> nodes with a vehicle segment in it
		var bad := 0
		for i in n_nodes:
			if deg[i] > 0:
				var r := _uf_find(parent, i)
				cnt[r] = int(cnt.get(r, 0)) + 1
				if r != main:
					bad += 1
		if _uf_find(parent, extraction_node()) != main:
			bad += 1
		for cid in sides.size():
			if sides[cid] == 0:
				bad += 1
		if bad == 0:
			break
		var best := -1
		var best_fix := 0
		var fallback := -1
		for si in segs.size():
			var sg: Array = segs[si]
			var form := _form_of(sg[0], sg[1], sg[2], sg[3])
			if form != "pedestrian" and form != "none":
				continue
			if sg[1] == "x" and (_cut[sg[0]] as Dictionary).has(seg_key("x", sg[2], sg[3])):
				continue
			var fix := 0
			for cid: int in sg[6]:
				if sides[cid] == 0:
					fix += 1
			var ra := _uf_find(parent, sg[4])
			var rb := _uf_find(parent, sg[5])
			var before := (int(cnt.get(ra, 0)) if ra != main else 0) + (int(cnt.get(rb, 0)) if rb != main and rb != ra else 0)
			var joined := int(cnt.get(ra, 0)) + (int(cnt.get(rb, 0)) if rb != ra else 0) + (1 if deg[sg[4]] == 0 else 0) + (1 if deg[sg[5]] == 0 else 0)
			var after := 0 if ra == main or rb == main else joined
			fix += before - after
			if fix > best_fix:
				best_fix = fix
				best = si
			# Nothing fixes in one step (a stranded part two segments away): grow it toward the rest, lowest first.
			if fallback < 0 and ra != rb and ((ra != main and cnt.has(ra)) or (rb != main and cnt.has(rb))):
				fallback = si
		if best < 0:
			best = fallback
		if best < 0:
			# Last resort, never expected: the first pedestrian / none segment left.
			for si in segs.size():
				var form := _form_of(segs[si][0], segs[si][1], segs[si][2], segs[si][3])
				if form == "pedestrian" or form == "none":
					best = si
					break
		if best < 0:
			break
		var pick: Array = segs[best]
		forms[pick[0]][seg_key(pick[1], pick[2], pick[3])] = "street"
		restored += 1
	return restored


## No stub streets: a crossing whose drawn (not `none`) segments number exactly one gets its `none` segments back as
## streets, lowest first, until it has two. Repeats until no crossing is a stub. Returns how many it gave back.
func _restore_stubs() -> int:
	var restored := 0
	var changed := true
	while changed:
		changed = false
		for k in deck_count:
			for j in rows + 1:
				for i in cols + 1:
					var drawn := 0
					var nones := []
					for sg: Array in _node_segs(i, j):
						if _form_of(k, sg[0], sg[1], sg[2]) == "none":
							nones.append(sg)
						else:
							drawn += 1
					if drawn != 1 or nones.is_empty():
						continue
					while drawn < 2 and not nones.is_empty():
						var sg: Array = nones.pop_front()
						forms[k][seg_key(sg[0], sg[1], sg[2])] = "street"
						drawn += 1
						restored += 1
					changed = true
	return restored


## The segments meeting at crossing (i, j), as [axis, line, index], in seg order (s before x, lower line / index first).
func _node_segs(i: int, j: int) -> Array:
	var out := []
	if j > 0:
		out.append(["s", i, j - 1])
	if j < rows:
		out.append(["s", i, j])
	if i > 0:
		out.append(["x", j, i - 1])
	if i < cols:
		out.append(["x", j, i])
	return out


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


## The road surface of deck k as strips, one per road segment (seg_rect: crossing centre to crossing centre, so a line's
## strips run its whole length); the spine's segments are split into its lanes (ramps, avenue and rail are built
## differently). Each strip carries its segment's `index` and `form` (a `none` strip's ground belongs to the superblock).
func _road_strips(k: int, extent: Rect2) -> Array:
	var out := []
	for i in cols + 1:
		for j in rows:
			var r := seg_rect(k, "s", i, j)
			var form := _form_of(k, "s", i, j)
			if i == spine_line:
				for l: Array in SPINE_LANES:
					var lx := lane_x(str(l[0]))
					var kind := "ramp_lane" if str(l[0]).begins_with("ramp") else str(l[0])
					out.append({"rect": Rect2(lx.x, r.position.y, lx.y - lx.x, r.size.y), "kind": kind, "axis": "s",
							"line": i, "lane": str(l[0]), "index": j, "form": form})
				continue
			out.append({"rect": r, "kind": "perimeter" if i == 0 or i == cols else "arterial", "axis": "s", "line": i,
					"lane": "", "index": j, "form": form})
	for j in rows + 1:
		for i in cols:
			out.append({"rect": seg_rect(k, "x", j, i), "kind": "perimeter" if j == 0 or j == rows else "cross", "axis": "x",
					"line": j, "lane": "", "index": i, "form": _form_of(k, "x", j, i)})
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


# --- Encounters (derived) ---------------------------------------------------------------------------------
# The crossing of each deck as the enemy spawner sees it (docs/design/mission-section.md §16). Pure reads of the plan:
# no rolls, no stored state, so they can never shift generation or checksum(), and every machine derives the same list.

## Where the crew first sets foot on deck k following the critical path: {deck, kind: portal | ramp | lift | shaft, x, s,
## connector (id, -1 for the portal)}, in deck k's (x, s). Deck 0: the entry road node on the avenue's centre (where
## CityStack.entry_transform puts the crew). Below: the landing of the critical connector down from deck k-1 (a ramp's
## foot end on deck k, a lift's platform centre).
func arrival(k: int) -> Dictionary:
	if k <= 0:
		return _end_point(0, "portal", -1, _avenue_mid(), line_s(0, int(entry["j"])))
	var ci := _critical_between(k - 1)
	if ci < 0:
		return _end_point(k, "portal", -1, _avenue_mid(), 0.0)
	var c: Dictionary = connectors[ci]
	var rect := connector_rect(ci, k)
	if c["kind"] == "ramp":
		return _end_point(k, "ramp", ci, rect.get_center().x, row_theta[int(c["foot_line"])] * radius_of(k))
	return _end_point(k, str(c["kind"]), ci, rect.get_center().x, rect.get_center().y)


## Where the crew leaves deck k: same shape as arrival(), kind ramp | lift | portal. The head of the critical connector
## down from deck k (a ramp's top end of its cut on deck k, a lift's platform centre); on the lowest deck the extraction
## road node, on the avenue's centre like the entry (kind "portal", connector -1).
func departure(k: int) -> Dictionary:
	if k >= deck_count - 1:
		var last := deck_count - 1
		return _end_point(last, "portal", -1, _avenue_mid(), line_s(last, int(extraction["j"])))
	var ci := _critical_between(k)
	if ci < 0:
		return _end_point(k, "portal", -1, _avenue_mid(), 0.0)
	var c: Dictionary = connectors[ci]
	var rect := connector_rect(ci, k)
	if c["kind"] == "ramp":
		return _end_point(k, "ramp", ci, rect.get_center().x, row_theta[int(c["top_line"])] * radius_of(k))
	return _end_point(k, str(c["kind"]), ci, rect.get_center().x, rect.get_center().y)


## The places on deck k worth an enemy group, by `progress` ascending: [{deck, kind, x, s, progress, dist, weight, share,
## safe}] (+ connector and size on a checkpoint, loop on a patrol, connector on a departure). Kinds: first_contact (a
## synthetic site on the avenue, FIRST_CONTACT_DIST past the arrival), checkpoint / station / patrol / holding / cordon
## (from hooks), shaft_exit (landing under a shaft from above), branch_landing (stop of a non-critical connector, e.g. the
## locked express lift), departure (departure(k)) or, on the lowest deck, extraction. Sites closer than MERGE_DIST are one
## (heavier weight, kind by SITE_PRIORITY). progress: 0..1 projection on arrival -> departure; dist: metres from the
## arrival; safe: dist < SAFE_RADIUS (nothing spawns there, share 0); share: the site's fraction of the deck's enemy budget
## (weight 1 / 2 / 4 x (0.6 + 0.8 x progress), normalised over the non-safe sites).
func encounter_sites(k: int) -> Array[Dictionary]:
	var a := arrival(k)
	var d := departure(k)
	var av := Vector2(float(a["x"]), float(a["s"]))
	var dv := Vector2(float(d["x"]), float(d["s"]))
	var raw: Array[Dictionary] = []
	# First contact: up the avenue toward the way down, short enough to stay in the first third of the crossing.
	var along := dv.y - av.y
	var dir := signf(along) if absf(along) > 1.0 else float(_dir(k))
	var reach := minf(FIRST_CONTACT_DIST, absf(along) * FIRST_CONTACT_SHARE)
	raw.append({"kind": "first_contact", "x": _avenue_mid(), "s": av.y + dir * reach, "weight": "light"})
	for h: Dictionary in hooks:
		if int(h["deck"]) != k:
			continue
		match str(h["kind"]):
			"checkpoint":
				raw.append({"kind": "checkpoint", "x": float(h["x"]), "s": float(h["s"]), "weight": str(h["size"]),
						"connector": int(h["connector"]), "size": str(h["size"])})
			"station", "cordon":
				raw.append({"kind": str(h["kind"]), "x": float(h["x"]), "s": float(h["s"]), "weight": "light"})
			"patrol":
				raw.append({"kind": "patrol", "x": float(h["x"]), "s": float(h["s"]), "weight": "light",
						"loop": (h["loop"] as Array).duplicate()})
			"holding":
				raw.append({"kind": "holding", "x": float(h["x"]), "s": float(h["s"]), "weight": "medium"})
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		var mid := connector_rect(ci, k).get_center()
		if c["kind"] == "shaft":
			if int(c["to"]) == k:
				raw.append({"kind": "shaft_exit", "x": mid.x, "s": mid.y, "weight": "medium"})
		elif c["role"] != "critical" and (c["stops"] as Array).has(k):
			raw.append({"kind": "branch_landing", "x": mid.x, "s": mid.y, "weight": "medium"})
	raw.append({"kind": "extraction" if k == deck_count - 1 else "departure", "x": dv.x, "s": dv.y, "weight": "heavy",
			"connector": int(d["connector"])})
	# Merge: most specific first; a site within MERGE_DIST of one already kept folds into it.
	var order := range(raw.size())
	order.sort_custom(func(i: int, j: int) -> bool:
		var pi := SITE_PRIORITY.find(str(raw[i]["kind"]))
		var pj := SITE_PRIORITY.find(str(raw[j]["kind"]))
		return pi < pj or (pi == pj and i < j))
	var w := p("width")
	var arc := arc_of(k)
	var kept: Array[Dictionary] = []
	for i: int in order:
		var site: Dictionary = raw[i]
		site["x"] = clampf(float(site["x"]), -w * 0.5, w * 0.5)
		site["s"] = clampf(float(site["s"]), -arc * 0.5, arc * 0.5)
		var at := Vector2(float(site["x"]), float(site["s"]))
		var into := -1
		var best := MERGE_DIST
		for n in kept.size():
			var gap := at.distance_to(Vector2(float(kept[n]["x"]), float(kept[n]["s"])))
			if gap < best:
				best = gap
				into = n
		if into < 0:
			kept.append(site)
		elif SITE_WEIGHT[site["weight"]] > SITE_WEIGHT[kept[into]["weight"]]:
			kept[into]["weight"] = site["weight"]
	# Place every site on the crossing, then split the budget.
	var axis := dv - av
	var len2 := axis.length_squared()
	var total := 0.0
	for site in kept:
		var at := Vector2(float(site["x"]), float(site["s"]))
		site["deck"] = k
		site["dist"] = at.distance_to(av)
		site["progress"] = clampf((at - av).dot(axis) / len2, 0.0, 1.0) if len2 > 1.0 else 0.0
		site["safe"] = float(site["dist"]) < SAFE_RADIUS
		site["share"] = 0.0 if site["safe"] else float(SITE_WEIGHT[site["weight"]]) * (0.6 + 0.8 * float(site["progress"]))
		total += float(site["share"])
	for site in kept:
		site["share"] = float(site["share"]) / total if total > 0.0 else 0.0
	kept.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if x["progress"] != y["progress"]:
			return x["progress"] < y["progress"]
		if x["dist"] != y["dist"]:
			return x["dist"] < y["dist"]
		return SITE_PRIORITY.find(str(x["kind"])) < SITE_PRIORITY.find(str(y["kind"])))
	return kept


## The critical (route) connector that takes the crew from deck k down to deck k+1, or -1: one that starts on deck k
## (a ramp first: a ramp added by the hop-only repair can share its pair with a lift merged into another's pillar), else
## one passing deck k.
func _critical_between(k: int) -> int:
	var any := -1
	var here := -1
	for ci in connectors.size():
		var c: Dictionary = connectors[ci]
		if c["role"] != "critical" or c["kind"] == "shaft" or int(c["from"]) > k or int(c["to"]) < k + 1:
			continue
		if int(c["from"]) == k:
			if c["kind"] == "ramp":
				return ci
			if here < 0:
				here = ci
		if any < 0:
			any = ci
	return here if here >= 0 else any


func _avenue_mid() -> float:
	var av := lane_x("avenue")
	return (av.x + av.y) * 0.5


func _end_point(k: int, kind: String, ci: int, x: float, s: float) -> Dictionary:
	var half := arc_of(k) * 0.5
	return {"deck": k, "kind": kind, "x": clampf(x, -p("width") * 0.5, p("width") * 0.5), "s": clampf(s, -half, half),
			"connector": ci}


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
	# Segment forms: only the segments that are not streets, so an all-street plan hashes as it did before forms.
	for k in forms.size():
		for axis: String in ["s", "x"]:
			for line in _seg_lines(axis):
				for index in _seg_count(axis):
					var f := FORMS.find(_form_of(k, axis, line, index))
					if f > 0:
						buf.put_32(seg_key(axis, line, index) + k * 1048576)
						buf.put_8(f)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))     # millimetres: immune to float formatting
