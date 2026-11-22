class_name LifeFigures
extends Node3D
## Draws the civilians (docs/design/ambient-life.md sections 9 and 10): one MultiMesh per (clothes colour, pose), no node,
## skeleton or physics body per person. A pose is a choice of mesh; "down" is the standing mesh rotated (the 0.4 s
## tip-over) and laid flat. Chunky low poly, ~40 faces a figure: box legs, box torso, block head with a hair cap, box arms,
## flat palette colour per face on CityPalette.surface_material() (no lighting, no emission). 1.8 m tall; three builds and
## two heights by instance scale. Instance transforms are in the district's local space (this node follows the district).

const IDLE := 0
const WALK_A := 1
const WALK_B := 2
const RUN_A := 3
const RUN_B := 4
const WARY := 5
const COWER := 6
const HANDS := 7
const SIT := 8
const POSES := ["idle", "walk_a", "walk_b", "run_a", "run_b", "wary", "cower", "hands_up", "sit"]
const SHIRTS := ["cream", "terracotta", "sage", "sky_blue", "metal_dark"]
const TROUSERS := ["metal_dark", "blue_grey", "concrete_dark", "asphalt_dark", "sand"]
const SKIN := "terracotta_light"
const HAIR := "trunk"
const BUILDS := [Vector3(0.9, 1.0, 0.9), Vector3(1.0, 1.0, 1.0), Vector3(1.18, 1.0, 1.12)]
const HEIGHTS := [0.94, 1.04]
const LIE_LIFT := 0.15          ## m the body rises as it lies down (half its depth)
static var HIDDEN := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0.0, -1000.0, 0.0))

var count := 0
var _variant := PackedInt32Array()     ## person -> clothes variant
var _index := PackedInt32Array()       ## person -> instance index inside its variant's multimeshes
var _scale: Array[Vector3] = []        ## person -> build x height
var _shown := PackedInt32Array()       ## person -> pose mesh shown (-1 hidden)
var _mms: Array = []                   ## variant -> pose -> MultiMesh
var _tris := 0


func net_fields() -> Dictionary:
	return {
		"count": Net.LOCAL, "_variant": Net.LOCAL, "_index": Net.LOCAL, "_scale": Net.LOCAL, "_shown": Net.LOCAL,
		"_mms": Net.LOCAL, "_tris": Net.LOCAL,
	}


func _init() -> void:
	name = "Figures"


## One instance per person in every pose mesh of its clothes variant; everyone starts hidden.
func build(people: Array, bounds: AABB) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	count = people.size()
	_variant.resize(count)
	_index.resize(count)
	_shown.resize(count)
	_scale.clear()
	var per := PackedInt32Array()
	per.resize(SHIRTS.size())
	for i in count:
		var pp: Dictionary = people[i]
		var v := int(pp["cloth"]) % SHIRTS.size()
		_variant[i] = v
		_index[i] = per[v]
		per[v] += 1
		_shown[i] = -1
		var b: Vector3 = BUILDS[int(pp["build"]) % BUILDS.size()]
		_scale.append(Vector3(b.x, b.y * float(HEIGHTS[int(pp["tall"]) % HEIGHTS.size()]), b.z))
	_mms.clear()
	_tris = 0
	var mat := CityPalette.surface_material()
	for v in SHIRTS.size():
		var row: Array = []
		for p in POSES.size():
			var geo := CityGeo.new()
			figure(geo, p, v)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = geo.commit(mat)
			mm.instance_count = per[v]
			mm.custom_aabb = bounds
			for k in per[v]:
				mm.set_instance_transform(k, HIDDEN)
			row.append(mm)
			if per[v] > 0:
				var mi := MultiMeshInstance3D.new()
				mi.name = "%s_%s" % [SHIRTS[v], POSES[p]]
				mi.multimesh = mm
				add_child(mi)
			if p == 0:
				_tris = maxi(_tris, geo.tri_count())
		_mms.append(row)


## Triangles of one figure (the standing mesh).
func figure_tris() -> int:
	return _tris


func shown(id: int) -> int:
	return _shown[id]


## Show person `id` in pose mesh `pose` at `xf` (district-local, unscaled: the person's build is applied here).
func show_pose(id: int, pose: int, xf: Transform3D) -> void:
	var v := _variant[id]
	var prev := _shown[id]
	if prev != pose and prev >= 0:
		(_mms[v][prev] as MultiMesh).set_instance_transform(_index[id], HIDDEN)
	_shown[id] = pose
	(_mms[v][pose] as MultiMesh).set_instance_transform(_index[id], Transform3D(xf.basis.scaled_local(_scale[id]), xf.origin))


func hide_person(id: int) -> void:
	var prev := _shown[id]
	if prev >= 0:
		(_mms[_variant[id]][prev] as MultiMesh).set_instance_transform(_index[id], HIDDEN)
	_shown[id] = -1


# --- Meshes ----------------------------------------------------------------------------------------------

static func _c(id: String) -> Color:
	return CityPalette.C[id]


## A box hanging from `pivot` (rotated by `rot`), `size` long downward from it, inside the frame `base`.
static func _limb(geo: CityGeo, base: Transform3D, pivot: Vector3, rot: Basis, size: Vector3, col: Color) -> void:
	geo.box(base * Transform3D(rot, pivot), Vector3(0.0, -size.y * 0.5, 0.0), size, col)


## Rotation of a limb that hangs down: `fwd` radians swung forward (toward +Z), `out` radians raised sideways (+ = away
## from the body on the +X side; pass the sign per side).
static func _swing(fwd: float, out: float = 0.0) -> Basis:
	return Basis(Vector3.BACK, out) * Basis(Vector3.RIGHT, -fwd)


## The figure in pose `pose`, clothes variant `v`, feet at the origin, facing +Z.
static func figure(geo: CityGeo, pose: int, v: int) -> void:
	var shirt := _c(SHIRTS[v])
	var legs := _c(TROUSERS[v])
	var skin := _c(SKIN)
	var hair := _c(HAIR)
	var leg := Vector3(0.18, 0.86, 0.21)
	var arm := Vector3(0.13, 0.64, 0.14)
	var hip := 0.86
	var lean := 0.0          # upper body forward (radians, about the hips)
	var leg_l := Basis.IDENTITY
	var leg_r := Basis.IDENTITY
	var arm_l := _swing(0.0, 0.06)
	var arm_r := _swing(0.0, -0.06)
	var head_down := 0.0
	match pose:
		WALK_A, WALK_B:
			var k := 1.0 if pose == WALK_A else -1.0
			leg_l = _swing(0.38 * k)
			leg_r = _swing(-0.38 * k)
			arm_l = _swing(-0.35 * k, 0.08)
			arm_r = _swing(0.35 * k, -0.08)
		RUN_A, RUN_B:
			var k := 1.0 if pose == RUN_A else -1.0
			lean = 0.3
			leg_l = _swing(0.75 * k)
			leg_r = _swing(-0.6 * k)
			arm_l = _swing(0.35, 2.55)      # both arms up in a V
			arm_r = _swing(0.35, -2.55)
		WARY:
			lean = -0.12
			leg_l = _swing(0.22)
			leg_r = _swing(-0.18)
			arm_l = _swing(1.25, 0.3)       # forearms up in front, warding off
			arm_r = _swing(1.25, -0.3)
		HANDS:
			arm_l = _swing(0.0, 2.95)
			arm_r = _swing(0.0, -2.95)
		COWER:
			hip = 0.48
			leg = Vector3(0.2, 0.5, 0.24)
			leg_l = _swing(0.45, 0.25)
			leg_r = _swing(0.45, -0.25)
			lean = 0.7
			head_down = 0.5
			arm_l = _swing(2.85, -0.3)      # folded over the head, hands meeting above it
			arm_r = _swing(2.85, 0.3)
		SIT:
			_sitting(geo, shirt, legs, skin, hair)
			return
	var base := Transform3D.IDENTITY
	_limb(geo, base, Vector3(0.11, hip, 0.0), leg_l, leg, legs)
	_limb(geo, base, Vector3(-0.11, hip, 0.0), leg_r, leg, legs)
	var upper := Transform3D(Basis(Vector3.RIGHT, lean), Vector3(0.0, hip, 0.0))
	_upper(geo, upper, arm_l, arm_r, arm, shirt, skin, hair, head_down)


## Torso, head and arms in the frame `upper` (origin at the hips, Y up the spine).
static func _upper(geo: CityGeo, upper: Transform3D, arm_l: Basis, arm_r: Basis, arm: Vector3, shirt: Color, skin: Color,
		hair: Color, head_down: float = 0.0) -> void:
	geo.box(upper, Vector3(0.0, 0.31, 0.0), Vector3(0.48, 0.64, 0.27), shirt)
	var head := upper * Transform3D(Basis(Vector3.RIGHT, head_down), Vector3(0.0, 0.66, 0.0))
	geo.box(head, Vector3(0.0, 0.15, 0.01), Vector3(0.27, 0.29, 0.27), skin)
	geo.box(head, Vector3(0.0, 0.27, -0.03), Vector3(0.29, 0.09, 0.27), hair)
	_limb(geo, upper, Vector3(0.31, 0.6, 0.0), arm_l, arm, shirt)
	_limb(geo, upper, Vector3(-0.31, 0.6, 0.0), arm_r, arm, shirt)


## Sitting on a bench seat (0.5 m) at the origin, knees forward, hands on the lap.
static func _sitting(geo: CityGeo, shirt: Color, legs: Color, skin: Color, hair: Color) -> void:
	var base := Transform3D.IDENTITY
	for x: float in [0.11, -0.11]:
		_limb(geo, base, Vector3(x, 0.52, -0.05), Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.18, 0.46, 0.2), legs)   # thigh
		_limb(geo, base, Vector3(x, 0.52, 0.38), Basis.IDENTITY, Vector3(0.17, 0.52, 0.2), legs)                       # shin
	var upper := Transform3D(Basis(Vector3.RIGHT, -0.08), Vector3(0.0, 0.5, -0.08))
	_upper(geo, upper, _swing(0.55, 0.05), _swing(0.55, -0.05), Vector3(0.13, 0.62, 0.14), shirt, skin, hair)


## A body tipping over: `frame` is the upright floor frame at its feet (no heading), `dir` the fall direction in that
## frame (unit, level), `f` 0..1 of the fall, `yaw` its heading. The pivot is the feet; it rises by half its depth as it
## lies flat so it rests on the ground instead of in it.
static func tip(frame: Transform3D, dir: Vector3, f: float, yaw: float) -> Transform3D:
	var angle := PI * 0.5 * f * f          # falls slowly, then fast
	var axis := Vector3.UP.cross(dir)
	if axis.length_squared() < 1e-8:
		axis = Vector3.RIGHT
	var lean := Basis(axis.normalized(), angle)
	return Transform3D(frame.basis * lean * Basis(Vector3.UP, yaw), frame.origin + frame.basis.y * LIE_LIFT * sin(angle))
