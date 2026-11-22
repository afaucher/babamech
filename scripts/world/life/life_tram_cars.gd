class_name LifeTramCars
extends Node3D
## Draws one deck's tram (LifeTram) and gives its cars collision (docs/design/ambient-life.md, phase 3). Three identical
## shuttle-form cars (the approved "shuttle" silhouette, transit livery: sky-blue body, cream lower band, dark glazing
## along the whole side, a big windscreen at both ends), 3 x 9 m, 3.2 m tall: MultiMeshes per lights state (plain, hazards
## dark, hazards bright), flat palette colour per face on CityPalette.surface_material(), no emission.
## Collision: one AnimatableBody3D per car (kinematic, moved to the tram's pose every frame, no physics simulation), on
## collision layer 1 like the district's own StaticBody3D, so a mech cannot walk through a tram. The one node-per-agent
## exception in ambient life. A car wholly beyond an end wall (through a portal) is hidden and its shape disabled.

const PLAIN := 0
const HAZARD_DARK := 1
const HAZARD_BRIGHT := 2
const RING_PTS := 20
const ROUND := 8.0             ## superellipse exponent of the cross-sections: a boxy rounded brick
const LAYER := 1               ## collision layer (the district's StaticBody3D is on layer 1)

var bodies: Array[AnimatableBody3D] = []
var _mms: Array = []                       ## [plain, hazard dark, hazard bright] MultiMesh, LifeTram.CARS instances each
var _shown := PackedInt32Array()           ## car -> -1 hidden, else the lights state shown
var _shapes: Array[CollisionShape3D] = []


func net_fields() -> Dictionary:
	return {"bodies": Net.LOCAL, "_mms": Net.LOCAL, "_shown": Net.LOCAL, "_shapes": Net.LOCAL}


func _init() -> void:
	name = "Tram"


func build(bounds: AABB, render_layer: int) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	bodies.clear()
	_shapes.clear()
	_mms.clear()
	_shown = PackedInt32Array()
	_shown.resize(LifeTram.CARS)
	_shown.fill(-1)
	for lit in 3:
		var geo := CityGeo.new()
		car(geo, lit)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = geo.commit(CityPalette.surface_material())
		mm.instance_count = LifeTram.CARS
		mm.custom_aabb = bounds
		for i in LifeTram.CARS:
			mm.set_instance_transform(i, LifeFigures.HIDDEN)
		_mms.append(mm)
		var mi := MultiMeshInstance3D.new()
		mi.name = "car%s" % ["", "_haz", "_haz_lit"][lit]
		mi.multimesh = mm
		mi.layers = render_layer
		add_child(mi)
	for i in LifeTram.CARS:
		var body := AnimatableBody3D.new()
		body.name = "Car%d" % i
		body.sync_to_physics = false
		body.collision_layer = LAYER
		body.collision_mask = 0
		body.top_level = true
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(LifeTram.CAR_W, LifeTram.CAR_H, LifeTram.CAR_L)
		cs.shape = box
		cs.position = Vector3(0.0, LifeTram.CAR_H * 0.5 + 0.1, 0.0)
		cs.disabled = true
		body.add_child(cs)
		add_child(body)
		bodies.append(body)
		_shapes.append(cs)


## Car i at `local` (deck-local, for the drawing) / `world` (for its body), in lights state `want` (-1: hidden, its
## collision off: beyond an end wall; -2: not drawn (out of every viewer's range), collision on).
func place(i: int, want: int, local: Transform3D, world: Transform3D) -> void:
	var prev := _shown[i]
	if prev >= 0 and prev != want:
		(_mms[prev] as MultiMesh).set_instance_transform(i, LifeFigures.HIDDEN)
	_shown[i] = want
	if want >= 0:
		(_mms[want] as MultiMesh).set_instance_transform(i, local)
	var off := want == -1
	if _shapes[i].disabled != off:
		_shapes[i].disabled = off
	if bodies[i].is_inside_tree():
		bodies[i].global_transform = world
	else:
		bodies[i].transform = world


## Only the drawing (the bodies keep following the tram).
func set_drawn(on: bool) -> void:
	for c in get_children():
		if c is MultiMeshInstance3D:
			(c as MultiMeshInstance3D).visible = on


func shown(i: int) -> int:
	return _shown[i]


# --- Mesh ------------------------------------------------------------------------------------------------

static func _c(id: String) -> Color:
	return CityPalette.C[id]


## A rounded loft along +Y: rings [y, half x, half z, colour of the band above], superellipse cross-sections.
static func _loft(geo: CityGeo, rings: Array, cap_top: Color, cap_bottom: Color) -> void:
	var ring_pts: Array = []
	for r: Array in rings:
		var pts: Array[Vector3] = []
		for k in RING_PTS:
			var a := TAU * (float(k) + 0.5) / float(RING_PTS)
			var c := cos(a)
			var s := sin(a)
			pts.append(Vector3(signf(s) * pow(absf(s), 2.0 / ROUND) * float(r[1]), float(r[0]),
					signf(c) * pow(absf(c), 2.0 / ROUND) * float(r[2])))
		ring_pts.append(pts)
	for i in rings.size() - 1:
		var lo: Array = ring_pts[i]
		var hi: Array = ring_pts[i + 1]
		for k in RING_PTS:
			var j := (k + 1) % RING_PTS
			geo.quad(lo[k], lo[j], hi[j], hi[k], rings[i][3])
	var top: Array = ring_pts[-1]
	var bot: Array = ring_pts[0]
	var ct := Vector3(0.0, float(rings[-1][0]), 0.0)
	var cb := Vector3(0.0, float(rings[0][0]), 0.0)
	for k in RING_PTS:
		var j := (k + 1) % RING_PTS
		geo.tri(ct, top[k], top[j], cap_top)
		geo.tri(cb, bot[j], bot[k], cap_bottom)


## One tram car, 3 x 9 m, 3.2 m tall, symmetric (either end leads), floor at y = 0. `lights`: PLAIN, HAZARD_DARK or
## HAZARD_BRIGHT.
static func car(geo: CityGeo, lights: int) -> void:
	var blue := _c("sky_blue")
	var cream := _c("cream_light")
	var glass := _c("glass_dark")
	var hw := LifeTram.CAR_W * 0.5
	var hl := LifeTram.CAR_L * 0.5
	_loft(geo, [
		[0.30, hw - 0.2, hl - 0.2, _c("metal_dark")],
		[0.55, hw, hl, blue],
		[0.92, hw, hl, cream],
		[1.22, hw, hl, blue],
		[2.70, hw - 0.02, hl - 0.04, blue],
		[3.04, hw - 0.14, hl - 0.2, blue],
		[3.20, hw - 0.4, hl - 0.5, blue],
	], blue, _c("metal_dark"))
	var xf := Transform3D.IDENTITY
	# Glazing along both sides: four windows and a double door in the middle (door glass down to the step).
	for sx: float in [-1.0, 1.0]:
		for z: Array in [[-3.6, -2.4], [-2.2, -0.9], [0.9, 2.2], [2.4, 3.6]]:
			geo.box(xf, Vector3(sx * (hw + 0.01), 1.95, (float(z[0]) + float(z[1])) * 0.5), Vector3(0.05, 1.2, float(z[1]) - float(z[0])), glass)
		for z: float in [-0.36, 0.36]:
			geo.box(xf, Vector3(sx * (hw + 0.01), 1.55, z), Vector3(0.05, 2.0, 0.64), glass)
		geo.box(xf, Vector3(sx * (hw + 0.015), 1.55, 0.0), Vector3(0.05, 2.06, 0.06), _c("blue_grey"))     # door seam
	# A big windscreen and a light bar at both ends.
	for sz: float in [-1.0, 1.0]:
		geo.box(xf, Vector3(0.0, 1.95, sz * (hl + 0.0)), Vector3(2.0, 1.3, 0.06), glass)
		if lights == PLAIN:
			geo.box(xf, Vector3(0.0, 0.74, sz * (hl + 0.01)), Vector3(1.6, 0.12, 0.05), _c("marking"))
			geo.box(xf, Vector3(0.0, 2.78, sz * (hl - 0.05)), Vector3(1.1, 0.12, 0.08), _c("marking"))   # destination strip
	# Roof unit.
	geo.box(xf, Vector3(0.0, 3.32, 0.0), Vector3(1.6, 0.26, 3.2), _c("blue_grey"))
	if lights != PLAIN:
		LifeCars._hazards(geo, hw, hl, 3.1, hw - 0.3, hl - 0.6, lights == HAZARD_BRIGHT)
