class_name LifeFigures
extends Node3D
## Draws the civilians (docs/design/ambient-life.md sections 9 and 10, "Civilian animation: as built"): ONE MultiMesh
## per deck, no node, skeleton or physics body per person. Every instance is the jointed figure of LifeAnimRig, posed in
## life_anim_limbs.gdshader from its custom data (motion, start time, seed, clothes, turn, distance / fall direction:
## LifeAnimRig.pack), written only when that person's motion changes or a turn starts; the clock is one material uniform
## (set_clock, once a frame). Per frame the CPU writes one transform per visible person (place), as before. Clothes are
## the instance's colour slots (5 sets), builds and heights the instance scale. Instance transforms are in the district's
## local space (this node follows the district).

const SHIRTS := ["cream", "terracotta", "sage", "sky_blue", "metal_dark"]
const TROUSERS := ["metal_dark", "blue_grey", "concrete_dark", "asphalt_dark", "sand"]
const SKIN := "terracotta_light"
const HAIR := "trunk"
const BUILDS := [Vector3(0.9, 1.0, 0.9), Vector3(1.0, 1.0, 1.0), Vector3(1.18, 1.0, 1.12)]
const HEIGHTS := [0.94, 1.04]
const LIE_LIFT := 0.15          ## m the body rises as it lies down (half its depth): pose_of's tipped transform
const EPOCH_STEP := 4096.0      ## s: the shader's clock and start times are relative to a multiple of this (float32)
static var HIDDEN := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0.0, -1000.0, 0.0))

var count := 0
var custom_writes := 0                  ## custom data writes since build (tests: only on motion changes / turns)
var _cloth := PackedInt32Array()        ## person -> clothes set
var _seed := PackedFloat32Array()       ## person -> animation seed 0..1 (from the plan's hash of the id)
var _scale: Array[Vector3] = []         ## person -> build x height
var _shown := PackedInt32Array()        ## person -> motion shown (-1 hidden)
var _custom := PackedColorArray()       ## person -> custom data last written
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _epoch := NAN
var _shadows := true
var _tris := 0


func net_fields() -> Dictionary:
	return {
		"count": Net.LOCAL, "custom_writes": Net.LOCAL, "_cloth": Net.LOCAL, "_seed": Net.LOCAL, "_scale": Net.LOCAL,
		"_shown": Net.LOCAL, "_custom": Net.LOCAL, "_mm": Net.LOCAL, "_mmi": Net.LOCAL, "_mat": Net.LOCAL,
		"_epoch": Net.LOCAL, "_shadows": Net.LOCAL, "_tris": Net.LOCAL,
	}


func _init() -> void:
	name = "Figures"


## One instance per person (index = the person's id); everyone starts hidden. `seeds`: one 0..1 per person (the plan's
## hash; empty: a hash of the index). render_layer is set on the instance before it enters the tree (changing `layers`
## on an in-tree instance while lights exist leaves stale light pairings in Forward+).
func build(people: Array, bounds: AABB, render_layer: int = 1, seeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	count = people.size()
	custom_writes = 0
	_cloth.resize(count)
	_seed.resize(count)
	_shown.resize(count)
	_custom.resize(count)
	_scale.clear()
	for i in count:
		var pp: Dictionary = people[i]
		_cloth[i] = int(pp["cloth"]) % SHIRTS.size()
		_seed[i] = seeds[i] if i < seeds.size() else fposmod(sin(float(i) * 12.9898) * 43758.5453, 1.0)
		_shown[i] = -1
		_custom[i] = Color(-1.0, 0.0, 0.0, 0.0)
		var b: Vector3 = BUILDS[int(pp["build"]) % BUILDS.size()]
		_scale.append(Vector3(b.x, b.y * float(HEIGHTS[int(pp["tall"]) % HEIGHTS.size()]), b.z))
	_epoch = NAN
	if _mat == null:
		_mat = LifeAnimRig.material()
	var mesh := LifeAnimRig.build_mesh()
	_tris = mesh.get_faces().size() / 3
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = mesh
	_mm.instance_count = count
	_mm.custom_aabb = bounds
	for k in count:
		_mm.set_instance_transform(k, HIDDEN)
		_mm.set_instance_custom_data(k, Color(0.0, 0.0, 0.0, 0.0))
	_mmi = null
	if count > 0:
		_mmi = MultiMeshInstance3D.new()
		_mmi.name = "People"
		_mmi.multimesh = _mm
		_mmi.material_override = _mat
		_mmi.layers = render_layer
		_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mmi)


## Triangles of one figure.
func figure_tris() -> int:
	return _tris


## Draw calls (MultiMeshInstances) this node makes.
func mesh_count() -> int:
	return get_child_count()


## The motion person `id` is drawn in (LifeAnimRig motion id), -1 hidden.
func shown(id: int) -> int:
	return _shown[id]


## The custom data last written for `id` (LifeAnimRig.unpack reads it).
func custom_of(id: int) -> Color:
	return _custom[id]


## The life clock, once a frame (and before any set_motion on a fresh build): the shader's anim_time.
func set_clock(t: float) -> void:
	if is_nan(_epoch):
		_epoch = floorf(t / EPOCH_STEP) * EPOCH_STEP
	if _mat != null:
		_mat.set_shader_parameter("anim_time", t - _epoch)


## Real shadows from the posed figure (the shadow pass runs the same vertex function): on at HIGH / MEDIUM, off at LOW.
func set_shadows(on: bool) -> void:
	_shadows = on
	if _mmi != null:
		_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func shadows() -> bool:
	return _shadows


## Person `id` animates `motion` from life-clock time t0 (see LifeAnimRig.pack). Written only when it differs from what
## the instance holds; returns whether it wrote.
func set_motion(id: int, motion: int, prev: int, t0: float, turn: float, speed: float, param: float, talk: bool) -> bool:
	if is_nan(_epoch):
		_epoch = floorf(t0 / EPOCH_STEP) * EPOCH_STEP
	var c := LifeAnimRig.pack(motion, prev, _cloth[id], talk, turn, t0 - _epoch, speed, _seed[id], param)
	if c == _custom[id]:
		return false
	_custom[id] = c
	custom_writes += 1
	_mm.set_instance_custom_data(id, c)
	return true


## Show person `id` at `xf` (district-local, unscaled: the person's build is applied here) in motion `motion`.
func place(id: int, motion: int, xf: Transform3D) -> void:
	_shown[id] = motion
	_mm.set_instance_transform(id, Transform3D(xf.basis.scaled_local(_scale[id]), xf.origin))


func hide_person(id: int) -> void:
	if _shown[id] >= 0:
		_mm.set_instance_transform(id, HIDDEN)
	_shown[id] = -1


## A body tipping over: `frame` is the upright floor frame at its feet (no heading), `dir` the fall direction in that
## frame (unit, level), `f` 0..1 of the fall, `yaw` its heading. The pivot is the feet; it rises by half its depth as it
## lies flat so it rests on the ground instead of in it. (AmbientLife.pose_of's transform of the dead; the drawn fall
## is the shader's.)
static func tip(frame: Transform3D, dir: Vector3, f: float, yaw: float) -> Transform3D:
	var angle := PI * 0.5 * f * f          # falls slowly, then fast
	var axis := Vector3.UP.cross(dir)
	if axis.length_squared() < 1e-8:
		axis = Vector3.RIGHT
	var lean := Basis(axis.normalized(), angle)
	return Transform3D(frame.basis * lean * Basis(Vector3.UP, yaw), frame.origin + frame.basis.y * LIE_LIFT * sin(angle))
