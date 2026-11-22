class_name MechMeshes
extends RefCounted
## The low-poly art parts of the chicken mech (docs/design/game-design.md 4.1-4.3, art/picks/): chassis pieces, leg
## segments, weapons and (MechHeadMeshes) the pilot heads. Every part is generated here with MeshKit and saved as its own
## file under res://assets/models/mech/<name>.res by tools/models/gen_mech_meshes.gd; `mesh(name)` loads the saved file
## (or builds it when the file is missing, e.g. before the first generation).
##
## Conventions (model units, the mech faces -Z, +X is its right):
##   body parts    authored in body space around their own attach point (LAYOUT gives where each goes on the body;
##                 the body's origin is 0.1 above the hip line, centred)
##   leg segments  origin at the proximal joint, hanging along -Y to the distal joint at REST_LENGTH (scale Y to fit),
##                 authored for the RIGHT leg (mirror X for the left)
##   joint caps    origin on the joint, axle along X
##   foot parts    origin where they attach, toe pointing -Z, on the ground plane y = 0
##   weapons       origin at the mount point, pointing -Z
##   heads         origin at the neck base, facing -Z
## Cosmetic only (no gameplay state).

const DIR := "res://assets/models/mech/"

# Palette (flat colour per face).
const WHITE := Color(0.91, 0.88, 0.81)
const ORANGE := Color(0.93, 0.46, 0.12)
const GREY := Color(0.45, 0.46, 0.47)
const DARK := Color(0.21, 0.22, 0.24)
const STEEL := Color(0.62, 0.62, 0.60)
const GUN := Color(0.31, 0.32, 0.34)
const BLACK := Color(0.07, 0.07, 0.08)
const AMBER := Color(1.0, 0.74, 0.22)
const TEAL := Color(0.25, 0.95, 0.85)

const BODY_PARTS := ["torso", "nose", "hatch", "back_plate", "pelvis", "shoulder_pylon", "shoulder_pod", "side_mount"]
const LEG_PARTS := ["thigh", "shin", "tarsus", "hip_cap", "knee_cap", "ankle_cap", "foot", "toe", "spur"]
## Weapon looks from the concept art. The catalog (MechCatalog.WEAPONS) decides which ones the game uses.
const WEAPONS := ["laser", "autocannon", "rockets", "flamer", "mortar", "railgun", "gatling", "swivel"]
const HEADS := ["chicken", "pickle", "corn", "dog"]

## Leg segment lengths the meshes are authored at (MechModel's default leg params).
const REST_LENGTH := {"thigh": 0.9, "shin": 1.1, "tarsus": 0.55}
## The body parts (torso, mounts, weapons) are drawn this much larger than authored, against the legs.
const BODY_SCALE := 1.2

## Where body parts sit in body space: [position, rotation (degrees)]. Right-side parts are mirrored for the left.
const LAYOUT := {
	"torso": [Vector3(0, 0, 0), Vector3.ZERO],
	"pelvis": [Vector3(0, 0, 0), Vector3.ZERO],
	"nose": [Vector3(0, 0.66, -1.0), Vector3.ZERO],
	"hatch": [Vector3(0, 1.27, -0.55), Vector3(10, 0, 0)],
	"back_plate": [Vector3(0, 1.3, 0.2), Vector3(-6, 0, 0)],
	"shoulder_pod": [Vector3(1.0, 0.98, 0.12), Vector3.ZERO],
}
## Hardpoint mount points in body space (where a weapon's origin goes).
const MOUNTS := {
	"side_l": Vector3(-1.3, 0.52, -0.3), "side_r": Vector3(1.3, 0.52, -0.3),
	"shoulder_l": Vector3(-0.86, 2.02, 0.3), "shoulder_r": Vector3(0.86, 2.02, 0.3),
	"back": Vector3(0, 1.28, 0.72),
}
## From a shoulder pylon's base to its mount point, and from a side mount's base to its mount point (right side).
const PYLON_TOP := Vector3(0.1, 0.78, 0.0)
const SIDE_REACH := Vector3(0.32, 0.0, 0.0)
## Toe layout on the foot: [root position, yaw degrees].
const TOES := [[Vector3(-0.12, 0, -0.14), 26.0], [Vector3(0, 0, -0.18), 0.0], [Vector3(0.12, 0, -0.14), -26.0]]
const SPUR_ROOT := Vector3(0, 0, 0.14)

static var _cache: Dictionary = {}
static var _mats: Array = []


static func all_parts() -> Array[String]:
	var out: Array[String] = []
	out.append_array(BODY_PARTS)
	out.append_array(LEG_PARTS)
	for w: String in WEAPONS:
		out.append("weapon_" + w)
	for h: String in HEADS:
		out.append("head_" + h)
	return out


static func has_part(part: String) -> bool:
	return part in all_parts()


static func path(part: String) -> String:
	return DIR + part + ".res"


## The part's mesh: the saved file when it exists, else built now.
static func mesh(part: String) -> ArrayMesh:
	if _cache.has(part):
		return _cache[part]
	var m: ArrayMesh = null
	if ResourceLoader.exists(path(part)):
		m = load(path(part)) as ArrayMesh
	if m == null:
		m = build(part)
	_cache[part] = m
	return m


## A MeshInstance3D of a part.
static func instance(part: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = mesh(part)
	return mi


## [matte, glow]: the two shared materials (saved beside the meshes; vertex colours carry the palette).
static func materials() -> Array:
	if _mats.is_empty():
		for n: String in ["matte", "glow"]:
			var p := DIR + "mech_" + n + ".tres"
			_mats.append(load(p) if ResourceLoader.exists(p) else make_material(n == "glow"))
	return _mats


static func make_material(glow: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.8
	m.metallic_specular = 0.3
	if glow:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## Generate a part from scratch (the generator and the staleness test use this).
static func build(part: String) -> ArrayMesh:
	var k := MeshKit.new()
	if part.begins_with("head_"):
		MechHeadMeshes.build(k, part.trim_prefix("head_"))
	elif part.begins_with("weapon_"):
		_weapon(k, part.trim_prefix("weapon_"))
	else:
		match part:
			"torso": _torso(k)
			"nose": _nose(k)
			"hatch": _hatch(k)
			"back_plate": _back_plate(k)
			"pelvis": _pelvis(k)
			"shoulder_pylon": _shoulder_pylon(k)
			"shoulder_pod": k.ico(Vector3.ZERO, Vector3(0.3, 0.36, 0.38), ORANGE)
			"side_mount": _side_mount(k)
			"thigh": _thigh(k)
			"shin": _shin(k)
			"tarsus": _tarsus(k)
			"hip_cap": _cap(k, 0.26, 0.4, 0.47)
			"knee_cap": _cap(k, 0.24, 0.27, 0.33)
			"ankle_cap": _cap(k, 0.18, 0.2, 0.26)
			"foot": _foot(k)
			"toe": _toe(k)
			"spur": _spur(k)
	return k.commit(materials())


# --- Body -----------------------------------------------------------------------------------------------

## Torso sections front to back: [z, half width, half height, centre y].
const TORSO := [[-1.0, 0.46, 0.33, 0.68], [-0.78, 0.82, 0.52, 0.72], [-0.3, 1.0, 0.62, 0.76], [0.3, 1.0, 0.62, 0.78],
	[0.74, 0.82, 0.52, 0.8], [0.96, 0.48, 0.32, 0.8]]


static func _torso_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.75:
		return DARK
	if n.y < -0.3:
		return GREY
	if absf(n.z) > 0.9:
		return GREY                       # the front and back end caps
	if absf(n.x) > 0.45 and c.z > -0.8:
		return ORANGE                     # side panels
	if c.z > 0.3 and c.z < 0.75 and n.y > 0.6:
		return ORANGE                     # a band across the rear deck
	return WHITE


static func _torso(k: MeshKit) -> void:
	var rings: Array = []
	for s: Array in TORSO:
		rings.append(MeshKit.ring(Vector3(0, s[3], s[0]), s[1], s[2], 10, "z", 2.6))
	k.loft(rings, _torso_colour)
	# Amber running lights on the front quarters and the flanks (pairs).
	k.glow = true
	for side: float in [-1.0, 1.0]:
		for i in 2:
			k.push(MeshKit.xf(Vector3(side * 0.66, 0.86 - float(i) * 0.13, -0.93), Vector3(0, -side * 58.0, 0)))
			k.box(Vector3(0.17, 0.085, 0.06), AMBER)
			k.pop()
		k.box(Vector3(0.05, 0.1, 0.26), AMBER, Vector3(side * 1.0, 0.8, -0.45))
	k.glow = false
	# Dark frames behind the lights.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 0.645, 0.795, -0.915), Vector3(0, -side * 58.0, 0)))
		k.box(Vector3(0.24, 0.3, 0.05), DARK)
		k.pop()
		k.box(Vector3(0.04, 0.17, 0.34), DARK, Vector3(side * 0.985, 0.8, -0.45))


## The nose under the hatch: a snout with the sensor port and lights. Origin on the torso's front face.
static func _nose(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.1), 0.44, 0.3, 8, "z", 3.0), MeshKit.ring(Vector3(0, -0.04, -0.2), 0.36, 0.24, 8, "z", 3.0),
		MeshKit.ring(Vector3(0, -0.07, -0.34), 0.24, 0.16, 8, "z", 3.0)], [GREY, WHITE], false, true)
	# Sensor port: a dark ring with a lens.
	k.tube(Vector3(0, -0.06, -0.3), Vector3(0, -0.06, -0.4), 0.15, 8, DARK)
	k.tube(Vector3(0, -0.06, -0.4), Vector3(0, -0.06, -0.44), 0.09, 8, GUN)
	k.glow = true
	k.tube(Vector3(0, -0.06, -0.44), Vector3(0, -0.06, -0.46), 0.045, 6, AMBER)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.05, 0.04), AMBER, Vector3(side * 0.2, -0.24, -0.26))
	k.glow = false
	k.box(Vector3(0.6, 0.09, 0.2), DARK, Vector3(0, -0.25, -0.16))


## The hatch collar the pilot's neck comes out of. Origin at the centre of the opening.
static func _hatch(k: MeshKit) -> void:
	var n := 10
	k.lathe([Vector2(0.53, -0.1), Vector2(0.51, 0.05), Vector2(0.46, 0.1)], n, [GREY, WHITE], false, false)
	k.loft([MeshKit.ring(Vector3(0, 0.1, 0), 0.46, 0.46, n), MeshKit.ring(Vector3(0, 0.1, 0), 0.4, 0.4, n)], DARK, false, false)
	k.lathe([Vector2(0.4, 0.1), Vector2(0.4, -0.04)], n, BLACK, false, false, true)
	k.poly(MeshKit.ring(Vector3(0, -0.04, 0), 0.4, 0.4, n), BLACK, Vector3(0, -5, 0))
	# The open lid's hinge blocks at the back of the collar.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.12, 0.1, 0.12), DARK, Vector3(side * 0.2, 0.08, 0.5))


## The armoured plate behind the pilot. Origin at its base.
static func _back_plate_colour(c: Vector3, n: Vector3) -> Color:
	if n.z > 0.5:
		return GREY
	return ORANGE if c.y < 0.16 and n.z < -0.5 else WHITE


static func _back_plate(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, -0.1, 0), 0.38, 0.09, 4, "y", MeshKit.SQUARE), MeshKit.ring(Vector3(0, 0.62, 0), 0.36, 0.08, 4, "y", MeshKit.SQUARE),
		MeshKit.ring(Vector3(0, 0.98, 0.02), 0.22, 0.07, 4, "y", MeshKit.SQUARE)], _back_plate_colour)
	# Ribs on the back, bolts and a light on the front.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.08, 0.7, 0.08), DARK, Vector3(side * 0.2, 0.3, 0.1))
		k.tube(Vector3(side * 0.24, 0.5, -0.08), Vector3(side * 0.24, 0.5, -0.11), 0.04, 6, DARK)
	k.glow = true
	k.box(Vector3(0.14, 0.07, 0.04), AMBER, Vector3(0.14, 0.74, -0.09))
	k.glow = false
	k.box(Vector3(0.2, 0.12, 0.03), DARK, Vector3(0.14, 0.74, -0.075))


## The hip block under the torso, with the axle the legs hang from.
static func _pelvis(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.26, 0.02), 0.52, 0.56, 8, "y", 3.0), MeshKit.ring(Vector3(0, 0.0, 0.02), 0.42, 0.46, 8, "y", 3.0),
		MeshKit.ring(Vector3(0, -0.24, 0.02), 0.26, 0.3, 8, "y", 3.0)], [GREY, DARK])
	k.tube(Vector3(-0.7, -0.1, 0), Vector3(0.7, -0.1, 0), 0.11, 8, DARK)


## A raised weapon pylon (right side). Origin at its base on the torso; the weapon mounts at PYLON_TOP.
static func _shoulder_pylon(k: MeshKit) -> void:
	k.box(Vector3(0.3, 0.14, 0.34), DARK, Vector3(0, 0.02, 0))
	k.seg(Vector3(0, 0.05, 0.03), Vector3(0.1, 0.6, 0.0), Vector2(0.09, 0.12), Vector2(0.075, 0.1), 4, GREY, MeshKit.SQUARE)
	k.tube(Vector3(0.06, 0.3, 0.13), Vector3(0.1, 0.58, 0.1), 0.035, 6, STEEL)
	k.tube(Vector3(-0.04, 0.62, 0), Vector3(0.24, 0.62, 0), 0.13, 8, DARK)
	k.tube(Vector3(0.24, 0.62, 0), Vector3(0.27, 0.62, 0), 0.07, 8, GREY)
	k.box(Vector3(0.22, 0.07, 0.3), GREY, PYLON_TOP - Vector3(0, 0.05, 0))


## A side hardpoint (right side). Origin on the torso's flank; the weapon mounts at SIDE_REACH.
static func _side_mount(k: MeshKit) -> void:
	k.tube(Vector3(-0.06, 0, 0), Vector3(0.08, 0, 0), 0.22, 8, DARK)
	k.tube(Vector3(0.08, 0, 0), Vector3(0.12, 0, 0), 0.13, 8, GREY)
	k.seg(Vector3(0.1, 0, 0), SIDE_REACH, Vector2(0.07, 0.08), Vector2(0.06, 0.07), 4, GREY, MeshKit.SQUARE)
	k.box(Vector3(0.1, 0.16, 0.2), DARK, SIDE_REACH)


# --- Legs -----------------------------------------------------------------------------------------------

static func _thigh_colour(c: Vector3, n: Vector3) -> Color:
	if c.y < -0.72:
		return GREY
	if n.x < -0.75:
		return GREY                         # the inner face
	if n.x > 0.6 and c.y < -0.3 and c.z > 0.0:
		return ORANGE                       # the unit mark on the outer face
	return WHITE


## The armoured thigh pod: hip (origin) to the knee.
static func _thigh(k: MeshKit) -> void:
	var l: float = REST_LENGTH["thigh"]
	var rings: Array = []
	for s: Array in [[0.24, 0.0, 0.0, 0.2, 0.25], [0.06, 0.03, -0.02, 0.33, 0.42], [-0.36, 0.05, -0.08, 0.38, 0.5],
			[-0.7, 0.03, -0.06, 0.33, 0.42], [-l + 0.02, 0.0, 0.0, 0.2, 0.26]]:
		rings.append(MeshKit.ring(Vector3(s[1], s[0], s[2]), s[3], s[4], 8, "y", 2.5))
	k.loft(rings, _thigh_colour)


## The shin strut: knee (origin) back down to the ankle, with a ribbed front and a piston behind.
static func _shin(k: MeshKit) -> void:
	var l: float = REST_LENGTH["shin"]
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.14, 0.16), Vector2(0.11, 0.13), 4, GREY, MeshKit.SQUARE)
	for i in 5:
		k.box(Vector3(0.32, 0.075, 0.07), DARK, Vector3(0, -0.2 - float(i) * 0.13, -0.165 + float(i) * 0.006))
	k.tube(Vector3(0, -0.12, 0.26), Vector3(0, -0.5, 0.23), 0.075, 6, DARK)
	k.tube(Vector3(0, -0.5, 0.23), Vector3(0, -l + 0.1, 0.2), 0.045, 6, STEEL)
	for y: float in [-0.12, -l + 0.1]:
		k.box(Vector3(0.14, 0.11, 0.18), DARK, Vector3(0, y, 0.17))


## The tarsus: ankle (origin) forward down to the foot.
static func _tarsus(k: MeshKit) -> void:
	var l: float = REST_LENGTH["tarsus"]
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.1, 0.12), Vector2(0.12, 0.13), 4, DARK, MeshKit.SQUARE)
	k.seg(Vector3(0, -0.14, -0.13), Vector3(0, -l + 0.04, -0.15), Vector2(0.14, 0.04), Vector2(0.16, 0.05), 4, STEEL, MeshKit.SQUARE)
	k.tube(Vector3(0, -0.08, 0.16), Vector3(0, -l + 0.08, 0.17), 0.04, 5, GREY)


## A joint: a drum on the axle (radius r, half width w) with a hub on each end (out to hub).
static func _cap(k: MeshKit, r: float, w: float, hub: float) -> void:
	k.tube(Vector3(-w, 0, 0), Vector3(w, 0, 0), r, 8, DARK)
	k.tube(Vector3(-hub, 0, 0), Vector3(hub, 0, 0), r * 0.55, 8, GREY)


## The hub of the foot: the ankle socket the toes and spur hang from. Origin on the ground under the tarsus.
static func _foot(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.0), 0.24, 0.25, 6, "y"), MeshKit.ring(Vector3(0, 0.16, 0.0), 0.21, 0.22, 6, "y"),
		MeshKit.ring(Vector3(0, 0.3, 0.0), 0.13, 0.14, 6, "y")], [GREY, DARK])


## One toe: root at the origin, claw tip forward on the ground.
static func _toe(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.11, 0.06), 0.1, 0.105, 5, "z"), MeshKit.ring(Vector3(0, 0.125, -0.36), 0.12, 0.12, 5, "z"),
		MeshKit.ring(Vector3(0, 0.085, -0.66), 0.085, 0.08, 5, "z"), MeshKit.ring(Vector3(0, 0.005, -0.94), 0.0, 0.0, 5, "z")],
		[STEEL, STEEL, GREY])


## The rear spur: root at the origin, pointing back and up.
static func _spur(k: MeshKit) -> void:
	k.seg(Vector3(0, 0.11, 0.0), Vector3(0, 0.18, 0.28), Vector2(0.08, 0.085), Vector2(0.07, 0.07), 4, STEEL)
	k.seg(Vector3(0, 0.18, 0.28), Vector3(0, 0.48, 0.56), Vector2(0.07, 0.07), Vector2.ZERO, 4, GREY)


# --- Weapons --------------------------------------------------------------------------------------------

static func _weapon(k: MeshKit, id: String) -> void:
	match id:
		"autocannon":
			k.box(Vector3(0.28, 0.3, 0.62), GUN, Vector3(0, 0, 0.06))
			k.box(Vector3(0.2, 0.14, 0.32), DARK, Vector3(0, 0.2, 0.12))
			k.box(Vector3(0.34, 0.12, 0.2), DARK, Vector3(0, -0.02, 0.02))
			k.tube(Vector3(0, 0.02, -0.25), Vector3(0, 0.02, -0.62), 0.1, 8, GUN)
			k.tube(Vector3(0, 0.02, -0.62), Vector3(0, 0.02, -1.3), 0.062, 8, DARK)
			k.tube(Vector3(0, 0.02, -1.3), Vector3(0, 0.02, -1.46), 0.095, 8, GUN)
			k.tube(Vector3(0, 0.02, -1.46), Vector3(0, 0.02, -1.465), 0.055, 6, BLACK)
		"rockets":
			k.box(Vector3(0.7, 0.5, 0.62), GUN, Vector3(0, 0.04, -0.02))
			k.box(Vector3(0.74, 0.08, 0.5), DARK, Vector3(0, 0.3, -0.02))
			k.box(Vector3(0.5, 0.3, 0.08), DARK, Vector3(0, 0.04, 0.32))
			for ix in 3:
				for iy in 2:
					var p := Vector3((float(ix) - 1.0) * 0.215, -0.07 + float(iy) * 0.22, -0.33)
					k.tube(p, p + Vector3(0, 0, -0.035), 0.09, 8, BLACK)
					k.tube(p + Vector3(0, 0, -0.03), p + Vector3(0, 0, -0.13), 0.055, 6, WHITE, 0.0)
		"laser":
			k.tube(Vector3(0, 0, 0.36), Vector3(0, 0, -0.3), 0.13, 8, GUN)
			k.box(Vector3(0.2, 0.2, 0.16), DARK, Vector3(0, 0, 0.4))
			for i in 3:
				k.box(Vector3(0.05, 0.1, 0.12), DARK, Vector3(0, 0.15, 0.2 - float(i) * 0.17))
			k.tube(Vector3(0, 0, -0.3), Vector3(0, 0, -0.84), 0.065, 8, STEEL)
			k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -1.04), 0.13, 8, GUN)
			k.glow = true
			k.tube(Vector3(0, 0, -1.04), Vector3(0, 0, -1.07), 0.1, 8, TEAL, 0.06)
			k.glow = false
		"flamer":
			k.ico(Vector3(0, 0.1, 0.16), Vector3(0.17, 0.2, 0.2), Color(0.8, 0.24, 0.1))
			k.ico(Vector3(0, -0.12, 0.2), Vector3(0.12, 0.13, 0.15), Color(0.8, 0.24, 0.1))
			k.box(Vector3(0.16, 0.2, 0.3), GUN, Vector3(0, 0, -0.08))
			k.tube(Vector3(0, 0, -0.2), Vector3(0, 0, -0.62), 0.055, 8, DARK)
			k.tube(Vector3(0, 0, -0.62), Vector3(0, 0, -0.84), 0.06, 8, GUN, 0.12)
			k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -0.845), 0.09, 8, BLACK)
			k.glow = true
			k.box(Vector3(0.04, 0.04, 0.06), AMBER, Vector3(0, -0.11, -0.8))
			k.glow = false
		"mortar":
			var a := Vector3(0, 0.12, 0.14)
			var b := Vector3(0, 1.22, -0.3)
			var d := (b - a).normalized()
			k.box(Vector3(0.56, 0.16, 0.5), DARK, Vector3(0, 0.02, 0.04))
			k.tube(Vector3(-0.26, 0.24, 0.08), Vector3(0.26, 0.24, 0.08), 0.1, 8, GUN)
			k.tube(a, b, 0.16, 8, GUN)
			k.tube(b - d * 0.16, b + d * 0.02, 0.2, 8, DARK)
			k.tube(b + d * 0.02, b + d * 0.025, 0.13, 8, BLACK)
			k.box(Vector3(0.1, 0.34, 0.1), STEEL, Vector3(0, 0.3, -0.16))
		"railgun":
			k.box(Vector3(0.32, 0.36, 0.72), GUN, Vector3(0, 0, 0.12))
			k.box(Vector3(0.22, 0.12, 0.4), DARK, Vector3(0, 0.22, 0.16))
			for side: float in [-1.0, 1.0]:
				k.seg(Vector3(side * 0.07, 0, -0.24), Vector3(side * 0.07, 0, -2.05), Vector2(0.03, 0.085), Vector2(0.03, 0.07), 4, STEEL, MeshKit.SQUARE)
			for i in 8:
				var z := -0.42 - float(i) * 0.2
				k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.07), 0.15, 8, DARK)
			k.glow = true
			k.box(Vector3(0.05, 0.05, 0.3), TEAL, Vector3(0.165, 0.05, 0.1))
			k.glow = false
		"gatling":
			k.tube(Vector3(0, 0, 0.34), Vector3(0, 0, -0.22), 0.18, 8, GUN)
			k.box(Vector3(0.22, 0.26, 0.3), DARK, Vector3(0, -0.2, 0.12))
			for i in 6:
				var ang := TAU * float(i) / 6.0
				var o := Vector3(cos(ang), sin(ang), 0) * 0.095
				k.tube(o + Vector3(0, 0, -0.22), o + Vector3(0, 0, -1.02), 0.036, 5, STEEL)
			k.tube(Vector3(0, 0, -0.5), Vector3(0, 0, -0.56), 0.145, 8, DARK)
			k.tube(Vector3(0, 0, -0.9), Vector3(0, 0, -0.96), 0.145, 8, DARK)
		"swivel":
			k.ico(Vector3.ZERO, Vector3(0.13, 0.13, 0.13), DARK)
			k.seg(Vector3.ZERO, Vector3(0, -0.08, -0.5), Vector2(0.05, 0.06), Vector2(0.045, 0.055), 4, GREY, MeshKit.SQUARE)
			k.tube(Vector3(-0.09, -0.08, -0.5), Vector3(0.09, -0.08, -0.5), 0.08, 8, DARK)
			k.box(Vector3(0.2, 0.2, 0.44), GUN, Vector3(0, -0.08, -0.68))
			k.box(Vector3(0.12, 0.1, 0.2), ORANGE, Vector3(0, 0.06, -0.62))
			for side: float in [-1.0, 1.0]:
				k.tube(Vector3(side * 0.05, -0.08, -0.9), Vector3(side * 0.05, -0.08, -1.25), 0.034, 6, DARK)
