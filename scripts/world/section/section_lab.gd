class_name SectionLab
extends Node3D
## Lab subject "Mission section": a SectionPlan as a 3D block-out of all its decks (zones as coloured slabs, pillars as
## columns, ramps / lifts / shafts marked, both routes drawn) with the 2D cross-section and deck plans beside it
## (SectionMap). docs/design/mission-section.md.

const PARAMS := [
	{"id": "seed", "label": "Seed", "min": 1.0, "max": 200.0, "value": 1.0},
	{"id": "decks", "label": "Decks", "min": 2.0, "max": 5.0, "value": 3.0},
	{"id": "arc", "label": "Arc length, top deck (m)", "min": 300.0, "max": 900.0, "value": 540.0},
	{"id": "width", "label": "Axial width (m)", "min": 160.0, "max": 450.0, "value": 270.0},
	{"id": "radius", "label": "Top deck radius (m)", "min": 150.0, "max": 1200.0, "value": 400.0},
	{"id": "cell", "label": "District cell (m)", "min": 60.0, "max": 140.0, "value": 90.0},
	{"id": "ramp_grade", "label": "Ramp grade (fitted run)", "min": 0.08, "max": 0.35, "value": 0.20},
	{"id": "shafts", "label": "Shafts per deck", "min": 0.0, "max": 3.0, "value": 1.0},
	{"id": "express", "label": "Express lift (0/1)", "min": 0.0, "max": 1.0, "value": 1.0},
	{"id": "w_urban", "label": "Zone mix: urban", "min": 0.0, "max": 2.0, "value": 1.0},
	{"id": "w_park", "label": "Zone mix: park", "min": 0.0, "max": 2.0, "value": 0.45},
	{"id": "w_industrial", "label": "Zone mix: industrial", "min": 0.0, "max": 2.0, "value": 0.45},
	{"id": "cutaway", "label": "Cutaway (view only)", "min": 0.0, "max": 1.0, "value": 0.5},
]
const DECK_CHOICES := ["all", "0", "1", "2", "3", "4"]
const MAP_CHOICES := ["both", "section", "plans", "off"]
const ROUTE_CHOICES := ["both", "vehicle", "mech", "none"]
const SLICE_CHOICES := ["spine", "0", "1", "2", "3", "4", "5", "6"]
const FACET := 8.0        ## floor facet length along the arc (m)

var time_scale := 1.0     ## nothing here is animated
var params: Dictionary = {}
var plan: SectionPlan
var map: SectionMap
var show_decks := "all"
var show_map := "both"
var show_routes := "both"
var slice := "spine"

var _mesh: MeshInstance3D
var _lines: MeshInstance3D
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()


func _init() -> void:
	for q: Dictionary in PARAMS:
		params[q["id"]] = q["value"]


func _ready() -> void:
	_mesh = MeshInstance3D.new()
	_mesh.name = "Blockout"
	add_child(_mesh)
	_lines = MeshInstance3D.new()
	_lines.name = "Routes"
	add_child(_lines)
	var layer := CanvasLayer.new()
	layer.name = "MapLayer"
	add_child(layer)
	map = SectionMap.new()
	map.name = "Map"
	map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map.anchor_left = 0.55
	map.anchor_right = 1.0
	map.anchor_top = 0.0
	map.anchor_bottom = 1.0
	map.offset_left = 0.0
	map.offset_right = -8.0
	map.offset_top = 8.0
	map.offset_bottom = -36.0
	layer.add_child(map)
	rebuild()


func lab_own_ground() -> bool:
	return true


func rebuild() -> void:
	var plan_params := params.duplicate()
	plan_params.erase("cutaway")
	plan = SectionPlan.make(plan_params)
	if _mesh == null:
		return
	_begin()
	for k in plan.deck_count:
		if _shown(k):
			_build_deck(k)
	for ci in plan.connectors.size():
		_build_connector(ci)
	_build_ends()
	_mesh.mesh = _end(false)
	_begin()
	_build_routes()
	_lines.mesh = _end(true)
	map.mode = show_map if show_map != "off" else "both"
	map.visible = show_map != "off"
	map.slice = -1 if slice == "spine" else int(slice)
	map.show_routes = show_routes
	map.show_plan(plan)


func _shown(k: int) -> bool:
	return show_decks == "all" or int(show_decks) == k


# --- Block-out -------------------------------------------------------------------------------------------

func _build_deck(k: int) -> void:
	var full := plan.arc_of(k)
	var w := plan.p("width")
	# Roads: the deck slab everywhere outside the cells, cut where a ramp dives out of the spine.
	var cuts: Array[Rect2] = []
	for ci in plan.connectors.size():
		if plan.is_hole(ci, k):
			cuts.append(plan.connector_rect(ci, k))
	var lanes := {}
	for lane: Array in SectionPlan.SPINE_LANES:
		lanes[lane[0]] = plan.lane_x(lane[0])
	var bands := [[-w * 0.5, (lanes["ramp_a"] as Vector2).x, SectionMap.C_ROAD],
			[(lanes["ramp_a"] as Vector2).x, (lanes["ramp_a"] as Vector2).y, SectionMap.C_ROAD.lightened(0.08)],
			[(lanes["avenue"] as Vector2).x, (lanes["avenue"] as Vector2).y, SectionMap.C_ROAD],
			[(lanes["rail"] as Vector2).x, (lanes["rail"] as Vector2).y, SectionMap.C_RAIL if plan.lane_kind(k, "rail") == "rail" else SectionMap.C_VERGE],
			[(lanes["ramp_b"] as Vector2).x, (lanes["ramp_b"] as Vector2).y, SectionMap.C_ROAD.lightened(0.08)],
			[(lanes["ramp_b"] as Vector2).y, w * 0.5, SectionMap.C_ROAD]]
	for b: Array in bands:
		_floor(k, Rect2(float(b[0]), -full * 0.5, float(b[1]) - float(b[0]), full), -0.4, b[2], cuts)
	for r in plan.rows:
		for c in plan.cols:
			_floor(k, plan.cell_rect(k, c, r), 0.0, SectionMap.ZONE_COLORS[plan.zone(k, c, r)], cuts)
	for kc: Rect2 in plan.decks[k]["keep_clear"]:
		_frame(k, kc, 0.3, 1.0, SectionMap.C_SHAFT.darkened(0.25))
	for id in plan.pillars.size():
		var pt := plan.pillar_point(k, id)
		var rad := plan.pillar_radius(k, id)
		var style := plan.pillar_style(k, id)
		_box(k, Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0), 0.0, plan.clear_height(),
				SectionMap.C_LIFT if style == "lift" else SectionMap.C_PILLAR.darkened(0.12 if style == "urban" else 0.0))
	_build_walls(k)
	for h: Dictionary in plan.hooks:
		if int(h["deck"]) != k:
			continue
		var at := Vector2(float(h["x"]), float(h["s"]))
		match str(h["kind"]):
			"checkpoint":
				var half := 9.0 if h["size"] == "heavy" else 6.0
				_box(k, Rect2(at.x - half, at.y - 1.5, half * 2.0, 3.0), 0.0, 5.0, SectionMap.C_HOOK["checkpoint"])
			"holding":
				_frame(k, Rect2(at.x - 12.0, at.y - 12.0, 24.0, 24.0), 0.0, 6.0, SectionMap.C_HOOK["holding"])
			"cordon":
				_box(k, Rect2(at.x - 4.0, at.y - 4.0, 8.0, 8.0), 0.0, 3.0, SectionMap.C_HOOK["checkpoint"].darkened(0.3))
			"pylon":
				_box(k, Rect2(at.x - 0.8, at.y - 0.8, 1.6, 1.6), 0.0, 14.0, Color(0.75, 0.2, 0.25))


## Boundary walls, in pieces one cell long so the cutaway only removes what it must. A bulkhead is a solid wall; a
## window wall is a sill and a lintel with the ring beyond showing between them. Gates are coloured slabs in the wall.
func _build_walls(k: int) -> void:
	var top := plan.clear_height()
	for edge in SectionPlan.EDGES:
		var b := plan.boundary(k, edge)
		var r := plan.boundary_rect(k, edge)
		var along_x := edge.begins_with("s")
		var n := plan.cols if along_x else plan.rows
		for i in n:
			var piece := Rect2(r.position.x + r.size.x * float(i) / float(n), r.position.y, r.size.x / float(n), r.size.y)
			if not along_x:
				piece = Rect2(r.position.x, r.position.y + r.size.y * float(i) / float(n), r.size.x, r.size.y / float(n))
			if b["kind"] == "window":
				_box(k, piece, 0.0, 5.0, SectionMap.C_WALL["bulkhead"])
				_box(k, piece, top - 5.0, top, SectionMap.C_WALL["bulkhead"])
			else:
				_box(k, piece, 0.0, top, SectionMap.C_WALL["bulkhead"].darkened(0.1 if i % 2 == 0 else 0.0))
		for g: Dictionary in b["gates"]:
			var gw := float(g["width"]) * 0.5
			var gr := Rect2(float(g["x"]) - gw, float(g["s"]) - (0.0 if edge == "s0" else 1.0), gw * 2.0, 1.0)
			if not along_x:
				gr = Rect2(float(g["x"]) - (0.0 if edge == "x0" else 1.0), float(g["s"]) - gw, 1.0, gw * 2.0)
			_box(k, gr, 0.0, float(g["h"]), SectionMap.C_GATE[g["kind"]])


func _build_connector(ci: int) -> void:
	var c: Dictionary = plan.connectors[ci]
	var from := int(c["from"])
	var to := int(c["to"])
	match str(c["kind"]):
		"ramp":
			if not (_shown(from) or _shown(to)):
				return
			var t_top := float(c["run_top"])       # the slope run, inside the whole-row span (R2.17)
			var t_foot := float(c["run_foot"])
			var n := maxi(8, int(ceil(absf(t_top - t_foot) * plan.radius_of(from) / FACET)))
			for i in n:
				var f0 := float(i) / float(n)
				var f1 := float(i + 1) / float(n)
				var a0 := lerpf(t_top, t_foot, f0)
				var a1 := lerpf(t_top, t_foot, f1)
				var r0 := lerpf(plan.radius_of(from), plan.radius_of(to), f0)
				var r1 := lerpf(plan.radius_of(from), plan.radius_of(to), f1)
				_quad(plan.polar_to_world(float(c["x0"]), a0, r0), plan.polar_to_world(float(c["x1"]), a0, r0),
						plan.polar_to_world(float(c["x1"]), a1, r1), plan.polar_to_world(float(c["x0"]), a1, r1),
						SectionMap.C_RAMP if i % 2 == 0 else SectionMap.C_RAMP.darkened(0.15))
		"lift":
			for k: int in c["stops"]:
				if _shown(k):      # the platform's stop: a pad in front of the lift pillar, toward the spine
					var pt := plan.pillar_point(k, int(c["pillar"]))
					var toward := signf(plan.col_x[plan.spine_line] - pt.x)
					_box(k, Rect2(pt.x + toward * SectionPlan.LIFT_HALF - (0.0 if toward > 0.0 else 8.0), pt.y - 11.0, 8.0, 22.0),
							0.0, 1.0, SectionMap.C_LIFT.darkened(0.3 if c["locked"] else 0.0))
		"shaft":
			if _shown(from):
				_frame(from, plan.connector_rect(ci, from), 0.0, 1.6, SectionMap.C_SHAFT)


func _build_ends() -> void:
	var e := plan.node_pos(0, plan.entry["i"], plan.entry["j"])
	if _shown(0):
		_box(0, Rect2(e.x - 3.0, e.y - 3.0, 6.0, 6.0), 0.0, 30.0, SectionMap.C_ENTRY)
	var k := int(plan.extraction["deck"])
	var x := plan.node_pos(k, plan.extraction["i"], plan.extraction["j"])
	if _shown(k):
		_box(k, Rect2(x.x - 3.0, x.y - 3.0, 6.0, 6.0), 0.0, 30.0, SectionMap.C_EXIT)


func _build_routes() -> void:
	if show_routes == "both" or show_routes == "vehicle":
		var pts: Array[Vector3] = []     # (x, theta, r)
		for wp: Dictionary in plan.route["vehicle"]:
			var k := int(wp["deck"])
			var np := plan.node_pos(k, wp["i"], wp["j"])
			pts.append(Vector3(np.x, np.y / plan.radius_of(k), plan.radius_of(k) - 2.0))
		_ribbon(pts, 2.2, SectionMap.C_VEHICLE)
	if show_routes == "both" or show_routes == "mech":
		var pts: Array[Vector3] = []
		for wp: Dictionary in plan.route["mech"]:
			var k := int(wp["deck"])
			var cp := plan.cell_rect(k, wp["col"], wp["row"]).get_center()
			pts.append(Vector3(cp.x, cp.y / plan.radius_of(k), plan.radius_of(k) - 6.0))
		_ribbon(pts, 1.4, SectionMap.C_MECH)


## A flat ribbon through points given as (x, theta, r), bending with the ring between them.
func _ribbon(pts: Array[Vector3], half_w: float, col: Color) -> void:
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var length := Vector2(b.x - a.x, (b.y - a.y) * a.z).length() + absf(b.z - a.z)
		var n := maxi(1, int(ceil(length / FACET)))
		for s in n:
			var p0 := a.lerp(b, float(s) / float(n))
			var p1 := a.lerp(b, float(s + 1) / float(n))
			var w0 := plan.polar_to_world(p0.x, p0.y, p0.z)
			var w1 := plan.polar_to_world(p1.x, p1.y, p1.z)
			var up := Vector3(0.0, cos(p0.y), -sin(p0.y))
			var side := (w1 - w0).cross(up)
			if side.length_squared() < 1e-6:
				side = Vector3.RIGHT      # straight up or down (a lift): face the ribbon along the axis
			side = side.normalized() * half_w
			_quad(w0 - side, w0 + side, w1 + side, w1 - side, col)


# --- Geometry --------------------------------------------------------------------------------------------

func _begin() -> void:
	_verts = PackedVector3Array()
	_normals = PackedVector3Array()
	_colors = PackedColorArray()


func _end(unshaded: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if _verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if unshaded else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mesh.surface_set_material(0, mat)
	return mesh


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var n := (b - a).cross(d - a).normalized()
	_verts.append_array(PackedVector3Array([a, b, c, a, c, d]))
	_normals.append_array(PackedVector3Array([n, n, n, n, n, n]))
	_colors.append_array(PackedColorArray([col, col, col, col, col, col]))


## A piece of deck k's floor at height h, faceted along the arc, minus the holes in `cuts`.
func _floor(k: int, r: Rect2, h: float, col: Color, cuts: Array[Rect2]) -> void:
	r = _clip(k, r)
	if r.size.x <= 0.01:
		return
	for cut in cuts:
		var hole := cut.intersection(r)
		if hole.size.x > 0.01 and hole.size.y > 0.01:
			# Split around the hole: the strips before and after it along s, then the two beside it.
			var pieces := [
				Rect2(r.position.x, r.position.y, r.size.x, hole.position.y - r.position.y),
				Rect2(r.position.x, hole.end.y, r.size.x, r.end.y - hole.end.y),
				Rect2(r.position.x, hole.position.y, hole.position.x - r.position.x, hole.size.y),
				Rect2(hole.end.x, hole.position.y, r.end.x - hole.end.x, hole.size.y)]
			for piece: Rect2 in pieces:
				if piece.size.x > 0.01 and piece.size.y > 0.01:
					_floor(k, piece, h, col, cuts)
			return
	var n := maxi(1, int(ceil(r.size.y / FACET)))
	for i in n:
		var s0 := r.position.y + r.size.y * float(i) / float(n)
		var s1 := r.position.y + r.size.y * float(i + 1) / float(n)
		_quad(plan.to_world(k, r.position.x, s0, h), plan.to_world(k, r.end.x, s0, h),
				plan.to_world(k, r.end.x, s1, h), plan.to_world(k, r.position.x, s1, h), col)


## A box standing on deck k over the (x, s) rect, from height h0 to h1 (its walls are radial).
func _box(k: int, r: Rect2, h0: float, h1: float, col: Color) -> void:
	if _clip(k, r).size.x < r.size.x - 0.01:
		return        # a box the cutaway would slice is left out whole
	var p := PackedVector3Array()
	for h in [h0, h1]:
		p.append(plan.to_world(k, r.position.x, r.position.y, h))
		p.append(plan.to_world(k, r.end.x, r.position.y, h))
		p.append(plan.to_world(k, r.end.x, r.end.y, h))
		p.append(plan.to_world(k, r.position.x, r.end.y, h))
	_quad(p[4], p[5], p[6], p[7], col)
	for i in 4:
		var j := (i + 1) % 4
		_quad(p[i], p[j], p[j + 4], p[i + 4], col.darkened(0.12 if i % 2 == 0 else 0.22))


## The cutaway: with all decks shown, each deck above the lowest is cut back along the axis in steps, so the decks below
## show past its edge like a staircase. Returns the part of r that is kept.
func _clip(k: int, r: Rect2) -> Rect2:
	var cut := float(params["cutaway"])
	if show_decks != "all" or cut <= 0.001:
		return r
	var w := plan.p("width")
	var edge := w * 0.5 - cut * w * float(plan.deck_count - 1 - k) / float(plan.deck_count)
	if r.end.x <= edge:
		return r
	return Rect2(r.position.x, r.position.y, maxf(edge - r.position.x, 0.0), r.size.y)


## A low wall around the (x, s) rect: marks a shaft's rim or a keep-clear landing.
func _frame(k: int, r: Rect2, h0: float, h1: float, col: Color) -> void:
	var t := 1.0
	_box(k, Rect2(r.position.x, r.position.y, r.size.x, t), h0, h1, col)
	_box(k, Rect2(r.position.x, r.end.y - t, r.size.x, t), h0, h1, col)
	_box(k, Rect2(r.position.x, r.position.y, t, r.size.y), h0, h1, col)
	_box(k, Rect2(r.end.x - t, r.position.y, t, r.size.y), h0, h1, col)


# --- Lab contract ----------------------------------------------------------------------------------------

func lab_params() -> Array:
	var out: Array = []
	for q: Dictionary in PARAMS:
		var d := q.duplicate()
		d["value"] = params[q["id"]]
		out.append(d)
	return out


func set_lab_param(id: String, v: float) -> void:
	if not params.has(id):
		return
	params[id] = v
	rebuild()


func lab_options() -> Array:
	return [
		{"id": "decks", "label": "Decks shown", "choices": DECK_CHOICES, "value": show_decks},
		{"id": "map", "label": "2D map", "choices": MAP_CHOICES, "value": show_map},
		{"id": "routes", "label": "Routes", "choices": ROUTE_CHOICES, "value": show_routes},
		{"id": "slice", "label": "Cross-section column", "choices": SLICE_CHOICES, "value": slice},
	]


func set_lab_option(id: String, v: String) -> void:
	if id == "decks" and v in DECK_CHOICES:
		show_decks = v
	elif id == "map" and v in MAP_CHOICES:
		show_map = v
	elif id == "routes" and v in ROUTE_CHOICES:
		show_routes = v
	elif id == "slice" and v in SLICE_CHOICES:
		slice = v
	else:
		return
	rebuild()


func lab_focus() -> Vector3:
	if plan == null:
		return Vector3.ZERO
	var k := clampi(int(show_decks), 0, plan.deck_count - 1) if show_decks != "all" else plan.deck_count / 2
	return plan.to_world(k, 0.0, 0.0, 0.0)


func lab_radius() -> float:
	if plan == null:
		return 300.0
	return maxf(plan.arc_of(plan.deck_count - 1), plan.p("width")) * 0.5
