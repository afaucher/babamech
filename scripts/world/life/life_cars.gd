class_name LifeCars
extends Node3D
## Draws the driverless vehicles (docs/design/ambient-life.md sections 10 and 14): one MultiMesh per (kind, lights) —
## plain, hazards dark, hazards bright — no node or body per vehicle. Hazards (and a wreck's alarm) show big amber bars
## front and back and a band round the roof edge, swapped between dark and bright amber at 1.5 Hz. Flat palette colour per
## face on CityPalette.surface_material() (no emission: CityPalette's only emissive material is the cream ceiling strip).
## Pod: the user's pick capsule_a (LifePodVariants.adopted): a symmetric cream capsule, raked dark-teal glass at both ends,
## a centre door with a pale frame and quarter windows each side, one terracotta stripe, wheels inboard under the body
## (0.28 m clearance, dark underside), pale light bars at both ends. 3.5 x 1.85 x 1.95 m.
## Cart: a low sand flatbed with a sage hopper and a small cab, 2.6 x 1.4 x 1.6 m. A wreck is the same mesh, rolled.
## Instance transforms are in the district's local space (this node follows the district); feet on the road, nose +Z.

const KINDS := ["pod", "cart"]
const PLAIN := 0
const HAZARD_DARK := 1
const HAZARD_BRIGHT := 2
const VARIANTS := ["", "_haz", "_haz_lit"]

var _kind := PackedInt32Array()       ## vehicle -> 0 pod / 1 cart
var _index := PackedInt32Array()      ## vehicle -> instance index in its kind's multimeshes
var _shown := PackedInt32Array()      ## vehicle -> -1 hidden, else PLAIN / HAZARD_DARK / HAZARD_BRIGHT
var _mms: Array = []                  ## kind -> [plain, hazard dark, hazard bright] MultiMesh


func net_fields() -> Dictionary:
	return {"_kind": Net.LOCAL, "_index": Net.LOCAL, "_shown": Net.LOCAL, "_mms": Net.LOCAL}


func _init() -> void:
	name = "Cars"


## render_layer is set on every instance before it enters the tree (see LifeFigures.build).
func build(vehicles: Array, bounds: AABB, render_layer: int = 1) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var n := vehicles.size()
	_kind.resize(n)
	_index.resize(n)
	_shown.resize(n)
	var per := PackedInt32Array([0, 0])
	for i in n:
		var k := KINDS.find(str(vehicles[i]["kind"]))
		_kind[i] = k
		_index[i] = per[k]
		per[k] += 1
		_shown[i] = -1
	_mms.clear()
	for k in KINDS.size():
		var pair: Array = []
		for lit in 3:
			var geo := CityGeo.new()
			if k == 0:
				pod(geo, lit)
			else:
				cart(geo, lit)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = geo.commit(CityPalette.surface_material())
			mm.instance_count = per[k]
			mm.custom_aabb = bounds
			for i in per[k]:
				mm.set_instance_transform(i, LifeFigures.HIDDEN)
			pair.append(mm)
			if per[k] > 0:
				var mi := MultiMeshInstance3D.new()
				mi.name = "%s%s" % [KINDS[k], VARIANTS[lit]]
				mi.multimesh = mm
				mi.layers = render_layer
				add_child(mi)
		_mms.append(pair)


## Show vehicle vid as PLAIN, HAZARD_DARK or HAZARD_BRIGHT at xf (district-local).
func show_vehicle(vid: int, want: int, xf: Transform3D) -> void:
	var k := _kind[vid]
	var prev := _shown[vid]
	if prev >= 0 and prev != want:
		(_mms[k][prev] as MultiMesh).set_instance_transform(_index[vid], LifeFigures.HIDDEN)
	_shown[vid] = want
	(_mms[k][want] as MultiMesh).set_instance_transform(_index[vid], xf)


## Hide vehicle vid (out of everyone's draw range).
func hide_vehicle(vid: int) -> void:
	var prev := _shown[vid]
	if prev >= 0:
		(_mms[_kind[vid]][prev] as MultiMesh).set_instance_transform(_index[vid], LifeFigures.HIDDEN)
	_shown[vid] = -1


func shown(vid: int) -> int:
	return _shown[vid]


# --- Meshes ----------------------------------------------------------------------------------------------

static func _c(id: String) -> Color:
	return CityPalette.C[id]


## Amber hazard lights: bars front and back, a band round the roof edge (dark or bright amber).
static func _hazards(geo: CityGeo, half_w: float, half_l: float, roof_y: float, roof_hw: float, roof_hl: float, bright: bool,
		roof_z: float = 0.0) -> void:
	var xf := Transform3D.IDENTITY
	var amber := _c("marking_yellow") if bright else _c("terracotta_dark")
	for sz: float in [-1.0, 1.0]:
		geo.box(xf, Vector3(0.0, 0.5, sz * (half_l + 0.02)), Vector3(half_w * 1.6, 0.3, 0.12), amber)
		geo.box(xf, Vector3(0.0, roof_y, roof_z + sz * roof_hl), Vector3(roof_hw * 2.0, 0.16, 0.12), amber)
	for sx: float in [-1.0, 1.0]:
		geo.box(xf, Vector3(sx * roof_hw, roof_y, roof_z), Vector3(0.12, 0.16, roof_hl * 2.0), amber)


## The pod, either end +Z: the adopted capsule_a (user pick), built by LifePodVariants.adopted (the one source).
## `lights`: PLAIN, HAZARD_DARK or HAZARD_BRIGHT.
static func pod(geo: CityGeo, lights: int) -> void:
	LifePodVariants.adopted(geo, lights)


## The service cart, nose +Z: chassis, cab at the front, hopper on the bed.
static func cart(geo: CityGeo, lights: int) -> void:
	var xf := Transform3D.IDENTITY
	var sand := _c("sand")
	geo.box(xf, Vector3(0.0, 0.2, 0.0), Vector3(1.3, 0.24, 2.4), _c("metal_dark"))           # skirts over the wheels
	geo.box(xf, Vector3(0.0, 0.5, 0.0), Vector3(1.4, 0.36, 2.6), sand)                        # bed
	geo.box(xf, Vector3(0.0, 1.12, 0.85), Vector3(1.3, 0.88, 0.8), sand, CityGeo.ALL, _c("cream_light"))   # cab
	geo.box(xf, Vector3(0.0, 1.2, 1.26), Vector3(1.1, 0.42, 0.04), _c("glass_teal"))         # windscreen
	geo.box(xf, Vector3(0.0, 1.0, -0.45), Vector3(1.2, 0.64, 1.3), _c("sage"), CityGeo.ALL, _c("sage_dark"))   # hopper
	if lights == PLAIN:
		geo.box(xf, Vector3(0.0, 1.62, 0.85), Vector3(0.5, 0.08, 0.2), _c("tactile"))       # beacon
		geo.box(xf, Vector3(0.0, 0.5, 1.31), Vector3(0.9, 0.1, 0.03), _c("marking"))
	else:
		_hazards(geo, 0.7, 1.3, 1.6, 0.66, 0.42, lights == HAZARD_BRIGHT, 0.85)
