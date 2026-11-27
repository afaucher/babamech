class_name HangarAirlock
extends Node3D
## The hangar bay's shared airlock (docs/design/hangar-v2/README.md: the user picked one bay airlock over per-alcove
## doors), in the bay's left end wall where the old breaching door was. Mechs walk down the aisle in HangarBay.LANES
## lanes, through the INNER door into the chamber, park nose to tail; the inner door shuts, the chamber cycles (amber),
## the OUTER door opens (red) onto a short corridor to the docking collar, they walk out, it shuts and the chamber
## cycles back for the next group (HangarEgress drives it).
##
##   inner door   a jaw across every lane: the upper leaf rises into the wall, the lower one sinks into the floor,
##                hazard teeth along the seam; striped jambs, a lintel with the status lamp bar, amber strobes either side
##   chamber      deck with a centre line per lane, ribbed walls, ceiling glow strips, a light that turns amber while it
##                cycles
##   outer door   two leaves sliding apart sideways (along z) into the walls, its own lamp bar, a corridor behind it
## Lamp bar colours: green sealed, amber cycling (flashing), red open. Sizes from HangarBay (lane_width, door_span,
## door_height, lane_length: the catalog's chassis), nothing fixed here but trim.
##
## Flat-colour low-poly: the fixed parts are one merged MeshKit mesh (lit + glow surfaces), each moving leaf one mesh,
## each lamp bar one; one OmniLight in the chamber. Cosmetic only (no net state). Built in bay space (this node sits at
## the bay's origin).

const LAMP_SEALED := Color(0.2, 0.9, 0.35)
const LAMP_CYCLE := Color(1.0, 0.62, 0.12)
const LAMP_OPEN := Color(1.0, 0.16, 0.08)
const INTERIOR := Color(0.36, 0.39, 0.43)
const INTERIOR_DARK := Color(0.21, 0.23, 0.26)
const LEAF_T := 0.3
const TEETH := 10
const HAZARD_STRIP_DARK := Color(0.08, 0.08, 0.09)

var inner_k := 0.0                      ## 0 shut .. 1 open
var outer_k := 0.0
var inner_lamp := "sealed"              ## "sealed" | "cycle" | "open"
var outer_lamp := "sealed"
var cycling := false                    ## the chamber light turns amber
var strobes: Array[OmniLight3D] = []    ## the bay's alert strobes beside the inner door (HangarBay flashes them)

var x_in := 0.0                         ## the inner door's plane (the end wall's inner face)
var x_far := 0.0                        ## the outer door's inner face
var z0 := 0.0
var z1 := 0.0
var height := 6.0

var _upper: MeshInstance3D
var _lower: MeshInstance3D
var _outer: Array[MeshInstance3D] = []
var _inner_lamp: MeshInstance3D
var _outer_lamp: MeshInstance3D
var _light: OmniLight3D
var _t := 0.0

static var _mats: Array = []


func build() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	strobes.clear()
	_outer.clear()
	x_in = HangarBay.AIRLOCK_X
	x_far = HangarBay.chamber_far_x()
	var span := HangarBay.door_span()
	z0 = span.x
	z1 = span.y
	height = HangarBay.door_height()
	var fixed := MeshInstance3D.new()
	fixed.name = "AirlockSet"
	fixed.mesh = _set_mesh()
	fixed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fixed)
	_upper = _jaw_leaf(true)
	_lower = _jaw_leaf(false)
	for s: float in [-1.0, 1.0]:
		_outer.append(_slide_leaf(s))
	_inner_lamp = _lamp_bar(Vector3(x_in + 0.42, height + 0.55, (z0 + z1) * 0.5))
	_outer_lamp = _lamp_bar(Vector3(x_far - 0.02 + 0.2, height + 0.4, (z0 + z1) * 0.5))
	_light = OmniLight3D.new()
	_light.name = "ChamberLight"
	_light.omni_range = maxf(x_in - x_far, z1 - z0) * 0.9
	_light.position = Vector3((x_in + x_far) * 0.5, height * 0.85, (z0 + z1) * 0.5)
	add_child(_light)
	for s: float in [-1.0, 1.0]:
		var strobe := OmniLight3D.new()
		strobe.light_color = HangarBay.STROBE_AMBER
		strobe.omni_range = 9.0
		strobe.position = Vector3(x_in + 1.2, height + 0.6, (z1 if s > 0.0 else z0) + s * 1.0)
		add_child(strobe)
		strobes.append(strobe)
	reset()


func reset() -> void:
	inner_k = 0.0
	outer_k = 0.0
	inner_lamp = "sealed"
	outer_lamp = "sealed"
	cycling = false
	apply()


func apply(dt: float = 0.0) -> void:
	_t += dt
	if _upper == null:
		return
	var ei := inner_k * inner_k * (3.0 - 2.0 * inner_k)
	var travel := (height * 0.5 + 0.15) * ei
	_upper.position.y = travel
	_lower.position.y = -travel
	var eo := outer_k * outer_k * (3.0 - 2.0 * outer_k)
	var slide := ((z1 - z0) * 0.5 + 0.1) * eo
	_outer[0].position.z = -slide
	_outer[1].position.z = slide
	_inner_lamp.material_override = MechParts.mat(_lamp_colour(inner_lamp), 1.0, true)
	_outer_lamp.material_override = MechParts.mat(_lamp_colour(outer_lamp), 1.0, true)
	var lit := ei > 0.02 or eo > 0.02 or cycling
	_light.visible = lit
	_light.light_color = LAMP_CYCLE if cycling else HangarBay.WORK_LIGHT
	_light.light_energy = 2.2 if cycling else 1.8 * maxf(ei, eo)


func _lamp_colour(state: String) -> Color:
	match state:
		"cycle": return LAMP_CYCLE if fmod(_t * 3.0, 1.0) < 0.6 else LAMP_CYCLE.darkened(0.6)
		"open": return LAMP_OPEN
	return LAMP_SEALED


## The moving leaves' boxes in bay space (tests: no mech passes a door that is still in the way).
func inner_boxes() -> Array[AABB]:
	return [HangarBay.mesh_box(_upper, self), HangarBay.mesh_box(_lower, self)]


func outer_boxes() -> Array[AABB]:
	return [HangarBay.mesh_box(_outer[0], self), HangarBay.mesh_box(_outer[1], self)]


func _lamp_bar(at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.24, (z1 - z0) * 0.5)
	mi.mesh = bm
	mi.position = at
	add_child(mi)
	return mi


## A leaf of the inner jaw door: across the whole opening (into the wall's slot either side), half its height.
func _jaw_leaf(upper: bool) -> MeshInstance3D:
	var k := MeshKit.new()
	var w := z1 - z0 + 0.3
	var zc := (z0 + z1) * 0.5
	var x := x_in - HangarBay.END_WALL * 0.5
	var mid := height * 0.5
	var lo := mid if upper else -0.2
	var hi := height + 0.2 if upper else mid
	var face := x + LEAF_T * 0.5
	var win := Vector2.ZERO           # the upper leaf's viewing window (y from, to): the cycle shows through it
	if upper:
		win = Vector2(mid + 0.75, hi - 0.75)
		# The leaf as a frame round the window: rails under and over it, mullions across it.
		k.box(Vector3(LEAF_T, win.x - lo, w), HangarBay.GUNMETAL_LIGHT, Vector3(x, (lo + win.x) * 0.5, zc))
		k.box(Vector3(LEAF_T, hi - win.y, w), HangarBay.GUNMETAL_LIGHT, Vector3(x, (win.y + hi) * 0.5, zc))
		var panes := 2 * HangarBay.LANES
		for m in panes + 1:
			var mz := z0 + (z1 - z0) * float(m) / float(panes)
			k.box(Vector3(LEAF_T, win.y - win.x, 0.3 if m % panes != 0 else 0.45), HangarBay.GUNMETAL_LIGHT, Vector3(x, (win.x + win.y) * 0.5, clampf(mz, z0 - 0.075, z1 + 0.075)))
		k.box(Vector3(0.06, 0.12, z1 - z0), HAZARD_STRIP_DARK, Vector3(face + 0.03, win.x - 0.12, zc))
	else:
		k.box(Vector3(LEAF_T, hi - lo, w), HangarBay.GUNMETAL_LIGHT, Vector3(x, (lo + hi) * 0.5, zc))
		for r in 2:
			var ry := lerpf(lo + 0.6, hi - 0.6, (float(r) + 0.5) / 2.0)
			k.box(Vector3(0.08, 0.18, w - 0.8), HangarBay.GUNMETAL_DARK, Vector3(face + 0.04, ry, zc))
	var tw := (z1 - z0) / float(TEETH * 2)
	for i in TEETH * 2:
		if (i % 2 == 0) != upper:
			continue
		var tz := z0 + tw * (float(i) + 0.5)
		k.box(Vector3(0.1, 0.5, tw * 0.92), HangarBay.HAZARD_YELLOW, Vector3(face + 0.05, mid - 0.25 if upper else mid + 0.25, tz))
	k.box(Vector3(0.06, 0.2, z1 - z0), HangarBay.HAZARD_BLACK, Vector3(face + 0.03, mid + 0.35 if upper else mid - 0.35, zc))
	var mi := _add(k, "InnerUpper" if upper else "InnerLower")
	if upper:
		var glass := MeshInstance3D.new()
		glass.name = "Window"
		var gm := BoxMesh.new()
		gm.size = Vector3(0.04, win.y - win.x, z1 - z0)
		glass.mesh = gm
		glass.position = Vector3(x, (win.x + win.y) * 0.5, zc)
		glass.material_override = _glass()
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.add_child(glass)
	return mi


## A leaf of the outer door: half the opening's width, sliding along z (s: -1 toward z0, +1 toward z1).
func _slide_leaf(s: float) -> MeshInstance3D:
	var k := MeshKit.new()
	var half := (z1 - z0) * 0.5
	var zc := (z0 + z1) * 0.5 + s * half * 0.5
	var x := x_far - HangarBay.END_WALL * 0.5
	k.box(Vector3(LEAF_T, height + 0.2, half + 0.15), HangarBay.GUNMETAL, Vector3(x, (height + 0.2) * 0.5, zc))
	for i in int(height / 0.5):
		k.box(Vector3(0.06, 0.25, 0.16), HangarBay.HAZARD_YELLOW if i % 2 == 0 else HangarBay.HAZARD_BLACK,
			Vector3(x + LEAF_T * 0.5 + 0.03, 0.5 * (float(i) + 0.5), (z0 + z1) * 0.5 + s * 0.08))
	k.box(Vector3(0.06, 0.18, half - 0.6), HangarBay.GUNMETAL_DARK, Vector3(x + LEAF_T * 0.5 + 0.03, height * 0.5, zc))
	return _add(k, "OuterL" if s < 0.0 else "OuterR")


func _add(k: MeshKit, nm: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = k.commit(_materials())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## The fixed parts: the end wall around the inner door, its frame, the chamber, the outer door's wall, the corridor.
func _set_mesh() -> ArrayMesh:
	var k := MeshKit.new()
	var t := HangarBay.END_WALL
	var top := HangarBay.HEIGHT
	var near := HangarBay.NEAR_Z
	var back := HangarBay.WALL_Z - 0.6
	var zc := (z0 + z1) * 0.5
	var w := z1 - z0
	# The end wall with the opening (the bay's shell leaves the left wall to this): before, after and above the doors.
	for seg: Vector2 in [Vector2(back, z0), Vector2(z1, near + 0.6)]:
		k.box(Vector3(t, top, seg.y - seg.x), HangarBay.GUNMETAL, Vector3(x_in - t * 0.5, top * 0.5, (seg.x + seg.y) * 0.5))
	k.box(Vector3(t, top - height, w), HangarBay.GUNMETAL, Vector3(x_in - t * 0.5, (height + top) * 0.5, zc))
	k.box(Vector3(0.25, 0.5, near - z1), HangarBay.HAZARD_YELLOW, Vector3(x_in + 0.12, 0.25, (z1 + near) * 0.5))
	k.box(Vector3(0.25, 0.5, z0 - back), HangarBay.HAZARD_YELLOW, Vector3(x_in + 0.12, 0.25, (back + z0) * 0.5))
	# The inner door's frame: striped jambs, a lintel with the lamp bar's housing, hazard chevrons on the deck before it.
	for zj: float in [z0 - 0.2, z1 + 0.2]:
		k.box(Vector3(0.4, height + 0.4, 0.4), HangarBay.GUNMETAL_LIGHT, Vector3(x_in + 0.2, (height + 0.4) * 0.5, zj))
		for i in int(height / 0.6):
			if i % 2 == 0:
				k.box(Vector3(0.42, 0.3, 0.42), HangarBay.HAZARD_YELLOW, Vector3(x_in + 0.2, 0.6 * (float(i) + 0.5), zj))
	k.box(Vector3(0.5, 0.6, w + 1.2), HangarBay.GUNMETAL_LIGHT, Vector3(x_in + 0.25, height + 0.3, zc))
	k.box(Vector3(0.24, 0.4, w * 0.5 + 0.3), HangarBay.HAZARD_BLACK, Vector3(x_in + 0.32, height + 0.55, zc))
	var n := int(w / 0.8)
	for i in n:
		var cz := z0 + w / float(n) * (float(i) + 0.5)
		k.box(Vector3(2.0, 0.03, w / float(n) * 0.5), HangarBay.HAZARD_YELLOW, Vector3(x_in + 1.2, 0.015, cz))
	# Pipes along the end wall over the door.
	for p in 3:
		k.tube(Vector3(x_in + 0.2 + float(p % 2) * 0.12, height + 1.1 + float(p) * 0.3, z0 - 1.5),
			Vector3(x_in + 0.2 + float(p % 2) * 0.12, height + 1.1 + float(p) * 0.3, z1 + 1.5), 0.1, 6,
			[HangarBay.GUNMETAL_DARK, HangarBay.BRASS, HangarBay.GUNMETAL_LIGHT][p])
	# The chamber: floor, side walls (ribbed), ceiling.
	var c0 := x_in - t
	var clen := c0 - x_far
	var cx := (c0 + x_far) * 0.5
	var ch := height + 0.8
	k.box(Vector3(clen, 0.3, w + 1.2), INTERIOR_DARK, Vector3(cx, -0.15, zc))
	for zw: float in [z0 - 0.45, z1 + 0.45]:
		k.box(Vector3(clen, ch, 0.3), INTERIOR, Vector3(cx, ch * 0.5, zw))
		var rx := c0 - 0.8
		while rx > x_far + 0.5:
			k.box(Vector3(0.3, ch, 0.2), INTERIOR_DARK, Vector3(rx, ch * 0.5, zw + (0.2 if zw < zc else -0.2)))
			rx -= 1.6
	k.box(Vector3(clen, 0.3, w + 1.2), INTERIOR_DARK, Vector3(cx, ch + 0.15, zc))
	# The outer door's wall (around its opening) and frame; the corridor beyond it, closed at its end.
	k.box(Vector3(t, ch + 0.3 - height, w + 1.2), INTERIOR, Vector3(x_far - t * 0.5, (height + ch + 0.3) * 0.5, zc))
	for zj: float in [z0 - 0.3, z1 + 0.3]:
		k.box(Vector3(t, height, 0.6), INTERIOR, Vector3(x_far - t * 0.5, height * 0.5, zj))
	var x_end := HangarBay.corridor_end_x()
	var cor := x_far - t - x_end
	var corx := (x_far - t + x_end) * 0.5
	k.box(Vector3(cor, 0.3, w + 1.2), Color(0.1, 0.11, 0.12), Vector3(corx, -0.15, zc))
	for zw: float in [z0 - 0.45, z1 + 0.45]:
		k.box(Vector3(cor, ch, 0.3), Color(0.15, 0.16, 0.18), Vector3(corx, ch * 0.5, zw))
	k.box(Vector3(cor, 0.3, w + 1.2), Color(0.1, 0.11, 0.12), Vector3(corx, ch + 0.15, zc))
	k.box(Vector3(0.3, ch, w + 1.2), Color(0.12, 0.13, 0.14), Vector3(x_end - 0.15, ch * 0.5, zc))
	# Lane centre lines on the chamber deck (yellow), glow strips on the ceiling and low on the walls, the corridor's
	# guide lights.
	for lane in HangarBay.LANES:
		k.box(Vector3(clen - 0.6, 0.02, 0.16), HangarBay.HAZARD_YELLOW, Vector3(cx, 0.012, HangarBay.lane_z(lane)))
	k.glow = true
	for lane in HangarBay.LANES:
		k.box(Vector3(clen - 1.0, 0.06, 0.3), HangarBay.WORK_LIGHT, Vector3(cx, ch - 0.04, HangarBay.lane_z(lane)))
		var gx := x_far - t - 0.6
		while gx > x_end + 0.6:
			k.box(Vector3(0.5, 0.02, 0.3), Color(0.55, 0.8, 1.0), Vector3(gx, 0.012, HangarBay.lane_z(lane)))
			gx -= 1.2
	for zw: float in [z0 - 0.28, z1 + 0.28]:
		k.box(Vector3(clen - 1.0, 0.12, 0.06), Color(0.55, 0.8, 1.0), Vector3(cx, 0.6, zw))
	k.glow = false
	return k.commit(_materials())


static var _glass_mat: StandardMaterial3D


## The inner door's window: faintly blue, mostly clear (the chamber's light and the outer door show through it).
static func _glass() -> StandardMaterial3D:
	if _glass_mat == null:
		_glass_mat = StandardMaterial3D.new()
		_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glass_mat.albedo_color = Color(0.45, 0.65, 0.8, 0.18)
		_glass_mat.roughness = 0.1
		_glass_mat.metallic_specular = 0.8
	return _glass_mat


static func _materials() -> Array:
	if _mats.is_empty():
		var matte := StandardMaterial3D.new()
		matte.vertex_color_use_as_albedo = true
		matte.vertex_color_is_srgb = true
		matte.roughness = 0.8
		var glow := StandardMaterial3D.new()
		glow.vertex_color_use_as_albedo = true
		glow.vertex_color_is_srgb = true
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mats = [matte, glow, matte]
	return _mats
