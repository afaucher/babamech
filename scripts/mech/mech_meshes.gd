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
##   joint caps    origin on the joint, axle along X; the hip is a ball joint: hip_cap is the ball on the pivot (it
##                 goes with the thigh), hip_socket the cup over it with its strut into the pelvis (right side; it
##                 goes with the body)
##   foot parts    origin where they attach, toe pointing -Z, on the ground plane y = 0
##   weapons       origin at the mount point, pointing -Z
##   heads         origin at the neck base, facing -Z
## Cosmetic only (no gameplay state).

const DIR := "res://assets/models/mech/"

# Palette (flat colour per face).
const WHITE := Color(0.97, 0.94, 0.86)
const ORANGE := Color(0.93, 0.46, 0.12)
const GREY := Color(0.45, 0.46, 0.47)
const DARK := Color(0.21, 0.22, 0.24)
const STEEL := Color(0.62, 0.62, 0.60)
const GUN := Color(0.31, 0.32, 0.34)
const BLACK := Color(0.07, 0.07, 0.08)
const AMBER := Color(1.0, 0.74, 0.22)
const TEAL := Color(0.25, 0.95, 0.85)
const MISSILE_RED := Color(0.8, 0.16, 0.13)
const TANK := Color(0.8, 0.24, 0.1)   ## the flamer fuel tanks
const REPAIR_GREEN := Color(0.25, 1.0, 0.45)   ## the repair drone's eye and pad lights (RepairDrone.GREEN, its beams)

## Player accent colours (cosmetic): the faces built in ORANGE go to each mesh's "accent" surface, which takes the colour
## through `apply_accent` / MechModel.set_accent. Heads never take the accent. Ids in display order in ACCENT_ORDER.
const ACCENTS := {
	"orange": ORANGE,
	"blue": Color(0.16, 0.42, 0.85),
	"green": Color(0.2, 0.62, 0.3),
	"red": Color(0.8, 0.16, 0.13),
	"yellow": Color(0.95, 0.78, 0.15),
	"purple": Color(0.5, 0.3, 0.75),
}
const ACCENT_ORDER := ["orange", "blue", "green", "red", "yellow", "purple"]

const BODY_PARTS := ["torso", "nose", "hatch", "back_plate", "pelvis", "shoulder_pylon", "shoulder_pod", "side_mount"]
const LEG_PARTS := ["thigh", "shin", "tarsus", "hip_socket", "hip_cap", "knee_cap", "ankle_cap", "foot", "toe", "spur"]
## Weapon looks from the concept art. The catalog (MechCatalog.WEAPONS) decides which ones the game uses.
const WEAPONS := ["laser", "autocannon", "rockets", "missiles", "flamer", "mortar", "railgun", "gatling", "swivel"]
## Back-mount equipment looks (docs/design/back-equipment.md; MechCatalog.EQUIPMENT_ORDER), built and named like the
## weapons ("weapon_<id>", origin at the back mount): the docked drone in its cradle, the empty cradle (shown while the
## drone is out) and the flying drone alone (origin at its centre; it sits at DRONE_DOCK in the docked mesh).
const EQUIPMENT := ["repair_drone", "repair_drone_cradle", "repair_drone_flying", "radiator", "ammo_bin"]
## Where the drone's centre sits on its cradle, from the back mount (model units, before BODY_SCALE).
const DRONE_DOCK := Vector3(0, 0.31, 0.02)
const HEADS := ["chicken", "pickle", "corn", "dog", "duck"]

## Leg segment lengths the meshes are authored at (MechModel's default leg params).
const REST_LENGTH := {"thigh": 1.1, "shin": 1.1, "tarsus": 0.55}
## The body parts (torso, mounts, weapons) are drawn this much larger than authored, against the legs.
const BODY_SCALE := 1.2

## Where body parts sit in body space: [position, rotation (degrees)]. Right-side parts are mirrored for the left.
const LAYOUT := {
	"torso": [Vector3(0, 0, 0), Vector3.ZERO],
	"pelvis": [Vector3(0, 0, 0), Vector3.ZERO],
	"nose": [Vector3(0, 0.7, -1.0), Vector3.ZERO],
	"hatch": [Vector3(0, 1.69, -0.5), Vector3(-20, 0, 0)],
	"back_plate": [Vector3(0, 1.7, 0.2), Vector3(-6, 0, 0)],
	"shoulder_pod": [Vector3(0.98, 1.12, 0.12), Vector3.ZERO],
}
## Hardpoint mount points in body space (where a weapon's origin goes).
const MOUNTS := {
	"side_l": Vector3(-1.21, 0.52, -0.3), "side_r": Vector3(1.21, 0.52, -0.3),
	"shoulder_l": Vector3(-0.86, 2.16, 0.3), "shoulder_r": Vector3(0.86, 2.16, 0.3),
	"back": Vector3(0, 1.55, 0.72),
}
## From a shoulder pylon's base to its mount point, and from a side mount's base to its mount point (right side).
const PYLON_TOP := Vector3(0.1, 0.78, 0.0)
const SIDE_REACH := Vector3(0.32, 0.0, 0.0)
## Toe layout on the foot: [root position, yaw degrees].
const TOES := [[Vector3(-0.13, 0, -0.16), 27.0], [Vector3(0, 0, -0.21), 0.0], [Vector3(0.13, 0, -0.16), -27.0]]
const SPUR_ROOT := Vector3(0, 0, 0.17)

static var _cache: Dictionary = {}
static var _mats: Array = []
static var _accent_mats: Dictionary = {}   ## colour html -> accent material copy


static func all_parts() -> Array[String]:
	var out: Array[String] = []
	out.append_array(BODY_PARTS)
	out.append_array(LEG_PARTS)
	for w: String in WEAPONS:
		out.append("weapon_" + w)
	for e: String in EQUIPMENT:
		out.append("weapon_" + e)
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


## [matte, glow, accent]: the three shared materials (saved beside the meshes as mech_<kind>.tres; vertex colours carry
## the palette, and the accent material's albedo colour tints the white accent faces).
static func materials() -> Array:
	if _mats.is_empty():
		for n: String in MeshKit.SURFACES:
			var p := DIR + "mech_" + n + ".tres"
			_mats.append(load(p) if ResourceLoader.exists(p) else make_material(n))
	return _mats


## A shared material: kind "matte" | "glow" | "accent" | "heat" (lit like matte; the radiator's fins, which the game
## overrides with an emissive copy by surface name to show heat).
static func make_material(kind: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.8
	m.metallic_specular = 0.3
	if kind == "glow":
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	elif kind == "accent":
		m.albedo_color = ORANGE
	return m


## The accent material for a colour: the shared one for (about) ORANGE, else a tinted copy, cached per colour.
static func accent_material(color: Color) -> StandardMaterial3D:
	var base: StandardMaterial3D = materials()[2]
	if color.is_equal_approx(ORANGE):
		return base
	var key := color.to_html()
	if not _accent_mats.has(key):
		var m := base.duplicate() as StandardMaterial3D
		m.albedo_color = color
		_accent_mats[key] = m
	return _accent_mats[key]


## Recolour the accent surface of every mesh under `root` (root included). ORANGE clears the overrides (the default).
static func apply_accent(root: Node, color: Color) -> void:
	var mat: Material = null if color.is_equal_approx(ORANGE) else accent_material(color)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_name(i) == "accent":
				mi.set_surface_override_material(i, mat)


## Generate a part from scratch (the generator and the staleness test use this).
static func build(part: String) -> ArrayMesh:
	var k := MeshKit.new()
	if not part.begins_with("head_"):
		k.accent_key = ORANGE   # heads never take the accent
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
			"shoulder_pod": _shoulder_pod(k)
			"side_mount": _side_mount(k)
			"thigh": _thigh(k)
			"shin": _shin(k)
			"tarsus": _tarsus(k)
			"hip_socket": _hip_socket(k)
			"hip_cap": _hip_ball(k)
			"knee_cap": _cap(k, 0.24, 0.27, 0.33)
			"ankle_cap": _cap(k, 0.18, 0.2, 0.26)
			"foot": _foot(k)
			"toe": _toe(k)
			"spur": _spur(k)
	return k.commit(materials())


# --- Body -----------------------------------------------------------------------------------------------

## Torso sections front to back: [z, half width, half height above the centre (the dome), below it (the belly),
## centre y, belly tuck]. An egg-shaped pod: widest a little ahead of the middle, the front and back curving in over two
## sections. Below the waist the belly is tucked into a keel (BELLY_KEEL) by the last column (0 = the plain egg, 1 = the
## full keel): the flipped legs swing the thigh pods up under the body (back when walking, to the sides and the front
## when the hip twist turns them), so the lower quarters are cut back to give them room, most over the middle and the
## rear, where the underside rises toward the tail.
const TORSO := [[-1.04, 0.3, 0.26, 0.22, 0.76, 0.0], [-0.97, 0.58, 0.6, 0.44, 0.79, 0.15], [-0.8, 0.81, 0.82, 0.62, 0.83, 0.45],
	[-0.5, 0.93, 0.9, 0.75, 0.87, 1.0], [-0.1, 0.96, 0.95, 0.79, 0.89, 1.0], [0.32, 0.92, 0.9, 0.75, 0.9, 1.0],
	[0.68, 0.77, 0.74, 0.6, 0.9, 1.0], [0.9, 0.52, 0.48, 0.4, 0.88, 0.3], [0.98, 0.26, 0.24, 0.2, 0.86, 0.0]]
const TORSO_SIDES := 14
const TORSO_POWER := 2.2
## The keel the belly tucks into: the lower ring points from the bottom up (one per facet step from straight down), as
## [share of the half width out from the centre line, share of the belly depth below the centre]. A narrow flat bottom
## (still over the pelvis), a steep lower flank and a hard chine under the waist seam.
const BELLY_KEEL := [Vector2(0.13, 0.86), Vector2(0.46, 0.48), Vector2(0.71, 0.3)]


## One torso section: a superellipse ring around Z with a taller top half than bottom half, its lower half tucked toward
## BELLY_KEEL by the section's tuck. Point k sits at angle TAU * (k + 0.5) / TORSO_SIDES from up toward +X (MeshKit.ring's
## order).
static func _torso_ring(s: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var e := 2.0 / TORSO_POWER
	var tuck: float = s[5] if s.size() > 5 else 0.0
	var step := TAU / float(TORSO_SIDES)
	for k in TORSO_SIDES:
		var a := TAU * (float(k) + 0.5) / float(TORSO_SIDES)
		var su := sin(a)
		var cv := cos(a)
		var ry: float = s[2] if cv > 0.0 else s[3]
		var p := Vector3(float(s[1]) * signf(su) * pow(absf(su), e), float(s[4]) + ry * signf(cv) * pow(absf(cv), e), s[0])
		if cv < -1e-4 and tuck > 0.0:
			var kp: Vector2 = BELLY_KEEL[mini(floori(absf(a - PI) / step), BELLY_KEEL.size() - 1)]
			var keel := Vector3(signf(su) * kp.x * float(s[1]), float(s[4]) - kp.y * float(s[3]), s[0])
			p = p.lerp(keel, tuck)
		out.append(p)
	return out


## A point on the torso's faceted skin and its outward normal: [point, normal], at `z` and `angle` degrees around Z
## from up toward +X (negative = the left side). Used to seat the lights on the facets. The left side is the mirror of
## the right, so a point exactly on a facet crease takes the same facet's normal on both sides (with the hard chine
## under the waist the two facets' normals differ a lot, and a plate section there would otherwise fold over).
static func _torso_at(z: float, angle: float) -> Array:
	var am := fposmod(angle, 360.0)
	if am > 180.0:
		var r := _torso_at(z, 360.0 - am)
		return [(r[0] as Vector3) * Vector3(-1, 1, 1), (r[1] as Vector3) * Vector3(-1, 1, 1)]
	var i := 0
	while i < TORSO.size() - 2 and z > float(TORSO[i + 1][0]):
		i += 1
	var ra := _torso_ring(TORSO[i])
	var rb := _torso_ring(TORSO[i + 1])
	var t := clampf((z - float(TORSO[i][0])) / (float(TORSO[i + 1][0]) - float(TORSO[i][0])), 0.0, 1.0)
	var f := fposmod(angle, 360.0) / 360.0 * float(TORSO_SIDES) - 0.5
	var k := floori(f)
	var u := f - float(k)
	k = posmod(k, TORSO_SIDES)
	var k2 := (k + 1) % TORSO_SIDES
	var pa := ra[k].lerp(ra[k2], u)
	var pb := rb[k].lerp(rb[k2], u)
	var p := pa.lerp(pb, t)
	var n := (ra[k2] - ra[k]).lerp(rb[k2] - rb[k], t).cross(pb - pa).normalized()
	if n.dot(p - Vector3(0, float(TORSO[i][4]), z)) < 0.0:
		n = -n
	return [p, n]


## A transform on the torso skin, facing out along the facet (local -Z = the normal), pushed out by `lift`.
static func _on_torso(z: float, angle: float, lift: float) -> Transform3D:
	var pn := _torso_at(z, angle)
	var n: Vector3 = pn[1]
	return Transform3D(Basis.looking_at(n, Vector3.UP), (pn[0] as Vector3) + n * lift)


static func _torso_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.95:
		return DARK                       # the underside
	if n.y < -0.3:
		return GREY                       # the lower belly
	if n.z > 0.9:
		return GREY                       # the small back end cap (the nose covers the front one)
	var q := Vector2(n.x, n.y).normalized()
	if absf(q.x) > 0.6 and q.y > 0.3 and c.z > -0.9 and c.z < 0.85:
		return ORANGE                     # the band along the upper flank / shoulder line
	if c.z > 0.32 and c.z < 0.68 and n.y > 0.75:
		return ORANGE                     # a band across the rear deck
	return WHITE


## A plate following the torso's facets: from angle a0 to a1 (degrees round Z from up toward +X, a0 < a1; negative =
## left side) and from z0 to z1 (front to back), raised `lift` off the skin. Sections sit at a0, at every facet vertex
## in between (unless within 2.5 degrees of an end) and at a1; each section's rows are z0, every TORSO ring z in between and z1, plus a straight sunk inner
## edge, so every section is convex and the slab is a closed shell that follows the creases.
static func _torso_plate(k: MeshKit, z0: float, z1: float, a0: float, a1: float, lift: float, col: Variant) -> void:
	var zs: Array = [z0]
	for s: Array in TORSO:
		if float(s[0]) > z0 + 0.01 and float(s[0]) < z1 - 0.01:
			zs.append(float(s[0]))
	zs.append(z1)
	var n := TORSO_SIDES
	var step := 360.0 / float(n)
	var angs: Array = [a0]
	for i in range(-2 * n, 2 * n):
		var a := (float(i) + 0.5) * step
		if a > a0 + 2.5 and a < a1 - 2.5:   # a sliver section next to an end would flip its faces
			angs.append(a)
	angs.append(a1)
	var secs: Array = []
	for a: float in angs:
		var ring := PackedVector3Array()
		var p0 := _torso_at(z0, a)
		ring.append((p0[0] as Vector3) - (p0[1] as Vector3) * 0.05)
		for z: float in zs:
			var pn := _torso_at(z, a)
			ring.append((pn[0] as Vector3) + (pn[1] as Vector3) * lift)
		var p1 := _torso_at(z1, a)
		ring.append((p1[0] as Vector3) - (p1[1] as Vector3) * 0.05)
		secs.append(ring)
	# Skinned by hand rather than with k.loft: over the tucked belly a long plate's sections are no longer convex, so
	# every face is turned away from a point inside the slab level with it (halfway between the raised face and the
	# sunk inner edge, on both neighbouring sections) rather than from the middle of the whole plate, and the end caps
	# fan from their centres.
	var inset := minf(0.02, (z1 - z0) * 0.4)
	for i in secs.size() - 1:
		var sa: PackedVector3Array = secs[i]
		var sb: PackedVector3Array = secs[i + 1]
		for j in sa.size():
			var j2 := (j + 1) % sa.size()
			for t: Array in [[sa[j], sa[j2], sb[j2]], [sa[j], sb[j2], sb[j]]]:
				var zc := clampf(((t[0] as Vector3).z + (t[1] as Vector3).z + (t[2] as Vector3).z) / 3.0, z0 + inset, z1 - inset)
				var u := (zc - z0) / (z1 - z0)
				var inner := Vector3.ZERO
				for s: PackedVector3Array in [sa, sb]:
					var a: float = angs[i] if s == sa else angs[i + 1]
					var pn := _torso_at(zc, a)
					var top := (pn[0] as Vector3) + (pn[1] as Vector3) * lift
					inner += (top + s[0].lerp(s[s.size() - 1], u)) * 0.25
				k.tri(t[0], t[1], t[2], col, inner)
	for e: int in [0, secs.size() - 1]:
		var cap: PackedVector3Array = secs[e]
		var c := MeshKit.centroid(cap)
		var inner := MeshKit.centroid(secs[1 if e == 0 else secs.size() - 2])
		for j in cap.size():
			k.tri(c, cap[j], cap[(j + 1) % cap.size()], col, inner)


## A box seated on the torso skin at (z, angle), `lift` out along the facet normal (local -Z = out, local Y ~ up).
static func _torso_box(k: MeshKit, z: float, angle: float, lift: float, size: Vector3, col: Variant, off: Vector3 = Vector3.ZERO) -> void:
	k.push(_on_torso(z, angle, lift))
	k.box(size, col, off)
	k.pop()


## The torso pod: the egg-shaped shell, amber running lights in hooded grey housings, stepped orange shoulder plates on
## dark under-plates, a waist seam, a rear belly grille, orange unit plates, the back-mount saddle and cable runs.
static func _torso(k: MeshKit) -> void:
	# The egg-shaped pod.
	var rings: Array = []
	for s: Array in TORSO:
		rings.append(_torso_ring(s))
	k.loft(rings, _torso_colour)
	for side: float in [-1.0, 1.0]:
		k.glow = true
		for a: float in [72.0, 84.0]:
			k.push(_on_torso(-0.86, side * a, 0.01))
			k.box(Vector3(0.17, 0.085, 0.06), AMBER)
			k.pop()
		k.push(_on_torso(-0.45, side * 78.0, 0.01))
		k.box(Vector3(0.26, 0.1, 0.06), AMBER)
		k.pop()
		k.glow = false
		k.push(_on_torso(-0.86, side * 78.0, 0.0))
		k.box(Vector3(0.24, 0.3, 0.05), DARK)
		k.pop()
		k.push(_on_torso(-0.45, side * 78.0, 0.0))
		k.box(Vector3(0.34, 0.17, 0.05), DARK)
		k.pop()
	for side: float in [-1.0, 1.0]:
		var lo := func(a0: float, a1: float) -> Vector2: return Vector2(a0, a1) if side > 0.0 else Vector2(-a1, -a0)
		# Stepped orange shoulder plates over the flank band, ahead of and behind the shoulder pod.
		# Each sits on a slightly larger dark under-plate, which shows as a panel line round the raised plate.
		var r: Vector2 = lo.call(38.0, 72.0)
		_torso_plate(k, -0.83, -0.27, r.x, r.y, 0.02, DARK)
		r = lo.call(42.0, 68.0)
		_torso_plate(k, -0.79, -0.31, r.x, r.y, 0.05, ORANGE)
		r = lo.call(39.0, 70.0)
		_torso_plate(k, 0.45, 0.83, r.x, r.y, 0.02, DARK)
		r = lo.call(43.0, 66.0)
		_torso_plate(k, 0.49, 0.79, r.x, r.y, 0.05, ORANGE)
		# A dark waist seam between the white flank and the grey belly.
		r = lo.call(102.0, 109.0)
		_torso_plate(k, -0.9, 0.86, r.x, r.y, 0.025, DARK)
		# Recessed light housings: a grey surround under each dark frame and a hood over each light.
		_torso_box(k, -0.86, side * 78.0, -0.01, Vector3(0.32, 0.38, 0.05), GREY)
		_torso_box(k, -0.45, side * 78.0, -0.01, Vector3(0.42, 0.25, 0.05), GREY)
		_torso_box(k, -0.86, side * 78.0, 0.0, Vector3(0.28, 0.035, 0.12), DARK, Vector3(0, 0.165, -0.045))
		_torso_box(k, -0.45, side * 78.0, 0.0, Vector3(0.38, 0.035, 0.12), DARK, Vector3(0, 0.1, -0.045))
		# An orange unit plate on the rear flank with a dark bar along its top edge.
		r = lo.call(76.0, 94.0)
		_torso_plate(k, 0.52, 0.76, r.x, r.y, 0.03, ORANGE)
		r = lo.call(76.0, 80.0)
		_torso_plate(k, 0.52, 0.76, r.x, r.y, 0.05, DARK)
		# A cable run along the rear deck from the back plate to the back-mount saddle.
		var c0 := _torso_at(0.28, side * 24.0)
		var c1 := _torso_at(0.42, side * 24.0)
		var c2 := _torso_at(0.56, side * 22.0)
		var pts := [(c0[0] as Vector3) + (c0[1] as Vector3) * 0.03, (c1[0] as Vector3) + (c1[1] as Vector3) * 0.035,
			(c2[0] as Vector3) + (c2[1] as Vector3) * 0.03]
		for i in pts.size() - 1:
			k.tube(pts[i], pts[i + 1], 0.035, 6, BLACK)
	# A vent grille under the rear belly, between the thighs: a dark panel with three grey slats across it, on the keel's
	# flat bottom (162-198 degrees), where the thigh pods pass beside it, and ending ahead of z 0.7, where they swing in
	# behind the pelvis.
	_torso_plate(k, 0.34, 0.68, 162.0, 198.0, 0.02, DARK)
	for z: float in [0.41, 0.5, 0.59]:
		_torso_plate(k, z, z + 0.045, 165.0, 195.0, 0.045, GREY)
	# The back-mount saddle on the rear deck (MOUNTS["back"]): a dark pad, two steel rails, four bolts.
	_torso_plate(k, 0.52, 0.86, -26.0, 26.0, 0.03, DARK)
	_torso_plate(k, 0.55, 0.83, 9.0, 16.0, 0.065, STEEL)
	_torso_plate(k, 0.55, 0.83, -16.0, -9.0, 0.065, STEEL)
	for z: float in [0.57, 0.81]:
		for a: float in [-21.0, 21.0]:
			_torso_box(k, z, a, 0.04, Vector3(0.06, 0.06, 0.05), STEEL)


## The nose under the hatch: a snout with the sensor port (bezel, bolts, visor hood) and framed lights. Origin on the
## torso's front face.
static func _nose(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.1), 0.44, 0.3, 8, "z", 3.0), MeshKit.ring(Vector3(0, -0.04, -0.2), 0.36, 0.24, 8, "z", 3.0),
		MeshKit.ring(Vector3(0, -0.07, -0.34), 0.24, 0.16, 8, "z", 3.0)], [GREY, WHITE], false, true)
	k.tube(Vector3(0, -0.06, -0.3), Vector3(0, -0.06, -0.4), 0.15, 8, DARK)
	k.tube(Vector3(0, -0.06, -0.4), Vector3(0, -0.06, -0.44), 0.09, 8, GUN)
	k.glow = true
	k.tube(Vector3(0, -0.06, -0.44), Vector3(0, -0.06, -0.46), 0.045, 6, AMBER)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.05, 0.04), AMBER, Vector3(side * 0.2, -0.24, -0.26))
	k.glow = false
	k.box(Vector3(0.6, 0.09, 0.2), DARK, Vector3(0, -0.25, -0.16))
	# A grey bezel round the sensor with six bolts, a visor hood, a steel inner ring.
	k.tube(Vector3(0, -0.06, -0.33), Vector3(0, -0.06, -0.375), 0.19, 8, GREY)
	for i in 6:
		var a := TAU * (float(i) + 0.5) / 6.0
		k.box(Vector3(0.045, 0.045, 0.03), STEEL, Vector3(sin(a) * 0.17, -0.06 + cos(a) * 0.17, -0.385))
	k.box(Vector3(0.36, 0.045, 0.13), DARK, Vector3(0, 0.115, -0.385))
	k.tube(Vector3(0, -0.06, -0.435), Vector3(0, -0.06, -0.448), 0.068, 8, STEEL)
	# Dark frames round the amber lights, a grille of two grey slats between them on the chin.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.14, 0.085, 0.03), DARK, Vector3(side * 0.2, -0.24, -0.255))
	for y: float in [-0.228, -0.268]:
		k.box(Vector3(0.2, 0.025, 0.03), GREY, Vector3(0, y, -0.265))
	# White cheek plates on the snout's sides, a steel bolt on each.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 0.39, -0.03, -0.1), Vector3(0, side * -15.0, 0)))
		k.box(Vector3(0.035, 0.2, 0.2), WHITE)
		k.box(Vector3(0.03, 0.045, 0.045), STEEL, Vector3(side * 0.025, 0.04, 0.0))
		k.pop()


## The hatch collar the pilot's neck comes out of, with its bolted band, rim bolts and lid hinge. Origin at the centre
## of the opening.
static func _hatch(k: MeshKit) -> void:
	var n := 10
	k.lathe([Vector2(0.53, -0.1), Vector2(0.51, 0.05), Vector2(0.46, 0.1)], n, [GREY, WHITE], false, false)
	var rim_o := MeshKit.ring(Vector3(0, 0.1, 0), 0.46, 0.46, n)
	var rim_i := MeshKit.ring(Vector3(0, 0.1, 0), 0.4, 0.4, n)
	for i in n:
		var i2 := (i + 1) % n
		k.quad(rim_o[i], rim_o[i2], rim_i[i2], rim_i[i], DARK, Vector3(0, -1, 0))
	k.lathe([Vector2(0.4, 0.1), Vector2(0.4, -0.04)], n, BLACK, false, false, true)
	k.poly(MeshKit.ring(Vector3(0, -0.04, 0), 0.4, 0.4, n), BLACK, Vector3(0, -5, 0))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.12, 0.1, 0.12), DARK, Vector3(side * 0.2, 0.08, 0.5))
	# A dark band round the collar wall with five steel bolts on it.
	k.lathe([Vector2(0.545, -0.085), Vector2(0.54, -0.02)], n, DARK)
	for i in 5:
		var a := TAU * (float(i * 2) + 1.0) / float(n) + PI / float(n)
		var dir := Vector3(sin(a), 0, -cos(a))
		if dir.z > 0.8:
			continue   # the hinge sits at the back
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.545 + Vector3(0, -0.052, 0)))
		k.box(Vector3(0.055, 0.055, 0.04), STEEL)
		k.pop()
	# Eight bolts on the rim (sunk 1.5 cm, so the rim's own faces stay the only ones at y = 0.1).
	for i in 8:
		var a := TAU * (float(i) + 0.5) / 8.0
		k.box(Vector3(0.045, 0.04, 0.045), STEEL, Vector3(sin(a) * 0.43, 0.105, -cos(a) * 0.43))
	# The lid hinge: a steel barrel between the blocks and a dark knuckle in its middle.
	k.tube(Vector3(-0.15, 0.08, 0.5), Vector3(0.15, 0.08, 0.5), 0.04, 6, STEEL)
	k.tube(Vector3(-0.05, 0.08, 0.5), Vector3(0.05, 0.08, 0.5), 0.058, 6, DARK)
	# Two orange tabs on the front of the collar.
	for side: float in [-1.0, 1.0]:
		var dir := Vector3(side * 0.6, 0, -0.8)
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.52 + Vector3(0, 0.0, 0)))
		k.box(Vector3(0.13, 0.07, 0.04), ORANGE)
		k.pop()


static func _back_plate_colour(c: Vector3, n: Vector3) -> Color:
	if n.z > 0.5:
		return GREY
	return ORANGE if c.y < 0.16 and n.z < -0.5 else WHITE


## The armoured plate behind the pilot: ribs and a vent panel on the back, edge plates and a light on the front. Origin
## at its base.
static func _back_plate(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, -0.1, 0), 0.38, 0.09, 4, "y", MeshKit.SQUARE), MeshKit.ring(Vector3(0, 0.62, 0), 0.36, 0.08, 4, "y", MeshKit.SQUARE),
		MeshKit.ring(Vector3(0, 0.98, 0.02), 0.22, 0.07, 4, "y", MeshKit.SQUARE)], _back_plate_colour)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.08, 0.7, 0.08), DARK, Vector3(side * 0.2, 0.3, 0.1))
		k.tube(Vector3(side * 0.24, 0.5, -0.08), Vector3(side * 0.24, 0.5, -0.11), 0.04, 6, DARK)
	k.glow = true
	k.box(Vector3(0.14, 0.07, 0.04), AMBER, Vector3(0.14, 0.74, -0.09))
	k.glow = false
	k.box(Vector3(0.2, 0.12, 0.03), DARK, Vector3(0.14, 0.74, -0.075))
	# A dark vent panel between the ribs with four grey slats.
	k.box(Vector3(0.3, 0.42, 0.03), DARK, Vector3(0, 0.34, 0.095))
	for i in 4:
		k.box(Vector3(0.26, 0.045, 0.035), GREY, Vector3(0, 0.19 + float(i) * 0.1, 0.11))
	# Steel bolts at both ends of each rib.
	for side: float in [-1.0, 1.0]:
		for y: float in [0.0, 0.6]:
			k.box(Vector3(0.05, 0.05, 0.04), STEEL, Vector3(side * 0.2, y, 0.145))
	# White stepped edge plates on the front.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.26, 0.035), WHITE, Vector3(side * 0.27, 0.31, -0.095))
	# A hood over the light and a round port opposite it.
	k.box(Vector3(0.22, 0.035, 0.07), DARK, Vector3(0.14, 0.815, -0.11))
	k.tube(Vector3(-0.13, 0.74, -0.07), Vector3(-0.13, 0.74, -0.115), 0.065, 8, DARK)
	k.tube(Vector3(-0.13, 0.74, -0.115), Vector3(-0.13, 0.74, -0.125), 0.035, 6, GUN)
	# An orange tag high on the back and a steel cap on the top edge.
	k.box(Vector3(0.22, 0.09, 0.03), ORANGE, Vector3(0, 0.79, 0.095))
	k.box(Vector3(0.4, 0.045, 0.16), STEEL, Vector3(0, 0.98, 0.02))


## The hip block under the torso, with the axle the legs hang from, skirt plates and rear pistons.
static func _pelvis(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.26, 0.02), 0.52, 0.56, 8, "y", 3.0), MeshKit.ring(Vector3(0, 0.0, 0.02), 0.42, 0.46, 8, "y", 3.0),
		MeshKit.ring(Vector3(0, -0.24, 0.02), 0.26, 0.3, 8, "y", 3.0)], [GREY, DARK])
	k.tube(Vector3(-0.45, -0.1, 0), Vector3(0.45, -0.1, 0), 0.12, 8, DARK)
	# Skirt plates on the lower slopes, front and back, with a tag on each (orange on the front one).
	for f: float in [-1.0, 1.0]:   # -1 = front (-Z)
		var a := Vector3(0, 0.0, 0.02 + f * 0.46)
		var b := Vector3(0, -0.24, 0.02 + f * 0.3)
		var nrm := Vector3(0, -0.16, f * 0.24).normalized()
		var at := (a + b) * 0.5 + nrm * 0.012
		k.push(Transform3D(Basis.looking_at(nrm, Vector3.UP), at))
		k.box(Vector3(0.36, 0.22, 0.035), GREY)
		k.box(Vector3(0.14, 0.07, 0.03), ORANGE if f < 0.0 else STEEL, Vector3(0, -0.02, -0.025))
		k.pop()
	# Steel axle collars where the axle leaves the block.
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.32, -0.1, 0), Vector3(side * 0.39, -0.1, 0), 0.155, 8, STEEL)
	# Two hydraulic pistons down the back, kept close to the centre line: the flipped legs bring the thigh pods' inner
	# faces to about 0.18 from it behind the block mid-stride.
	for side: float in [-1.0, 1.0]:
		var top := Vector3(side * 0.1, 0.02, 0.53)
		var bot := Vector3(side * 0.075, -0.2, 0.39)
		k.tube(top, top.lerp(bot, 0.55), 0.045, 6, DARK)
		k.tube(top.lerp(bot, 0.5), bot, 0.028, 6, STEEL)


## A raised weapon pylon (right side). Origin at its base on the torso; the weapon mounts at PYLON_TOP.
static func _shoulder_pylon(k: MeshKit) -> void:
	k.box(Vector3(0.3, 0.14, 0.34), DARK, Vector3(0, 0.02, 0))
	k.seg(Vector3(0, 0.05, 0.03), Vector3(0.1, 0.6, 0.0), Vector2(0.09, 0.12), Vector2(0.075, 0.1), 4, GREY, MeshKit.SQUARE)
	k.tube(Vector3(0.06, 0.3, 0.13), Vector3(0.1, 0.58, 0.1), 0.035, 6, STEEL)
	k.tube(Vector3(-0.04, 0.62, 0), Vector3(0.24, 0.62, 0), 0.13, 8, DARK)
	k.tube(Vector3(0.24, 0.62, 0), Vector3(0.27, 0.62, 0), 0.07, 8, GREY)
	k.box(Vector3(0.22, 0.07, 0.3), GREY, PYLON_TOP - Vector3(0, 0.05, 0))
	# Four bolts on the base.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.045, 0.04, 0.045), STEEL, Vector3(sx * 0.105, 0.095, sz * 0.125))
	# An orange plate on the post's front face.
	var d := Vector3(0.1, 0.55, -0.03).normalized()
	var x := d.cross(Vector3.BACK).normalized()
	var z := x.cross(d).normalized()
	k.push(Transform3D(Basis(x, d, z), Vector3(0.05, 0.31, 0.015)))
	k.box(Vector3(0.13, 0.3, 0.035), ORANGE, Vector3(0, 0, -0.118))
	k.pop()
	# The pivot hub: a steel step ring with four bolts round the grey cap.
	k.tube(Vector3(0.235, 0.62, 0), Vector3(0.258, 0.62, 0), 0.108, 8, STEEL)
	k.push(MeshKit.xf(Vector3(0, 0.62, 0)))
	_bolt_ring(k, 0.258, 0.09, 0.032, 4, 45.0)
	k.pop()
	# Mounting rails along the top plate and a clamp across each end.
	var top := PYLON_TOP
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.03, 0.28), STEEL, top + Vector3(sx * 0.06, -0.005, 0))
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.26, 0.055, 0.05), DARK, top + Vector3(0, -0.03, sz * 0.125))
	# An ammo feed stub on the outer side under the plate, a cable up the inner back edge of the post.
	k.box(Vector3(0.07, 0.08, 0.13), DARK, Vector3(0.22, 0.71, 0.07))
	var hose := [Vector3(-0.085, 0.08, 0.14), Vector3(-0.05, 0.35, 0.15), Vector3(-0.01, 0.56, 0.12)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.028, 6, BLACK)


## The shoulder pod: a 20-face ico subdivided once (80 faces) for a rounder, faceted pod, scaled per axis back to the
## ico's bounds (POD_R), with a pivot hub on the outer face (+X; the left pod is mirrored).
const POD_R := Vector3(0.3, 0.36, 0.38)


static func _shoulder_pod(k: MeshKit) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var base: Array[Vector3] = []
	for v: Vector3 in [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
			Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]:
		base.append(v.normalized())
	var faces_i := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6],
		[7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	# The ico's extent per axis (its vertices) and the subdivided one's (with the edge midpoints), to scale it back inside.
	var a_max := Vector3.ZERO
	for v in base:
		a_max = a_max.max(v.abs())
	var tris: Array = []
	var b_max := Vector3.ZERO
	for f: Array in faces_i:
		var p0: Vector3 = base[f[0]]
		var p1: Vector3 = base[f[1]]
		var p2: Vector3 = base[f[2]]
		var m01 := (p0 + p1).normalized()
		var m12 := (p1 + p2).normalized()
		var m20 := (p2 + p0).normalized()
		for tri: Array in [[p0, m01, m20], [p1, m12, m01], [p2, m20, m12], [m01, m12, m20]]:
			tris.append(tri)
			for v: Vector3 in tri:
				b_max = b_max.max(v.abs())
	var scl := POD_R * a_max / b_max
	for tri: Array in tris:
		k.tri((tri[0] as Vector3) * scl, (tri[1] as Vector3) * scl, (tri[2] as Vector3) * scl, ORANGE, Vector3.ZERO)
	# The outer pivot hub: a dark disc, a steel cap, four bolts.
	var ox := POD_R.x * a_max.x
	k.tube(Vector3(ox - 0.06, 0, 0), Vector3(ox + 0.025, 0, 0), 0.13, 8, DARK)
	k.tube(Vector3(ox + 0.015, 0, 0), Vector3(ox + 0.05, 0, 0), 0.065, 6, STEEL)
	_bolt_ring(k, ox + 0.025, 0.1, 0.035, 4, 45.0)


## A side hardpoint (right side). Origin on the torso's flank; the weapon mounts at SIDE_REACH.
static func _side_mount(k: MeshKit) -> void:
	var reach := SIDE_REACH
	k.tube(Vector3(-0.06, 0, 0), Vector3(0.08, 0, 0), 0.22, 8, DARK)
	k.tube(Vector3(0.08, 0, 0), Vector3(0.12, 0, 0), 0.13, 8, GREY)
	k.seg(Vector3(0.1, 0, 0), reach, Vector2(0.07, 0.08), Vector2(0.06, 0.07), 4, GREY, MeshKit.SQUARE)
	k.box(Vector3(0.1, 0.16, 0.2), DARK, reach)
	# An orange band round the disc's rim, a steel step ring on its face with six bolts.
	k.tube(Vector3(-0.025, 0, 0), Vector3(0.035, 0, 0), 0.232, 8, ORANGE)
	k.tube(Vector3(0.07, 0, 0), Vector3(0.1, 0, 0), 0.185, 8, STEEL)
	_bolt_ring(k, 0.1, 0.158, 0.036, 6, 30.0)
	# Steel clamp jaws on both sides of the mount block, a pivot pin through its top, an orange clamp plate under it.
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.085, 0.12, 0.035), STEEL, reach + Vector3(0, 0, sz * 0.115))
	k.tube(reach + Vector3(0, 0.0, 0), reach + Vector3(0, 0.11, 0), 0.045, 6, STEEL)
	k.box(Vector3(0.14, 0.035, 0.17), ORANGE, reach + Vector3(-0.01, -0.095, 0))
	# A cable from the disc to the block.
	var hose := [Vector3(0.06, -0.15, 0.13), Vector3(0.18, -0.08, 0.1), Vector3(0.28, -0.05, 0.08)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.026, 6, BLACK)


# --- Legs -----------------------------------------------------------------------------------------------
# The detailed leg parts (docs/design/legs-detail/README.md, adopted for every part): each part's base primitives plus
# chunky closed shells from the concept art (stepped plates, panel lines, vents, joint hubs with rings and bolts, a framed
# tread, hydraulic lines, toe knuckles, pads and claws). Every Y on the thigh, shin and tarsus is a fraction of the
# segment's REST_LENGTH (or an offset from a joint end), so the detail follows a length change; sizes across the leg stay
# absolute.

const THIGH_SIDES := 10


static func _thigh_colour(c: Vector3, n: Vector3) -> Color:
	var l: float = REST_LENGTH["thigh"]
	if c.y < -0.8 * l:
		return GREY
	if n.x < -0.75:
		return GREY                         # the inner face
	if n.x > 0.6 and c.y < -0.3333 * l and c.z > 0.0:
		return ORANGE                       # the unit mark on the outer face
	return WHITE


## The thigh pod's sections: [y, x offset, z offset, half width, half depth]. The root starts on the pivot, inside the hip
## ball; the pod widens below it (widest low and forward), so the thigh swings about the ball.
## The pod and its details were drawn on a 0.9 thigh. A longer thigh fills the pod out a little (`_thigh_full`) so it
## keeps its stocky character instead of looking stretched; the root (in the hip ball) and the knee end stay put.
const THIGH_DRAWN := 0.9


static func _thigh_full() -> float:
	return clampf(1.0 + 0.3 * (float(REST_LENGTH["thigh"]) / THIGH_DRAWN - 1.0), 0.85, 1.15)


static func _thigh_spec() -> Array:
	var l: float = REST_LENGTH["thigh"]
	var w := _thigh_full()
	return [[0.0, 0.0, 0.0, 0.15, 0.18], [-0.2222 * l, 0.02 * w, -0.03 * w, 0.31 * w, 0.38 * w],
		[-0.4444 * l, 0.05 * w, -0.09 * w, 0.42 * w, 0.5 * w], [-0.6444 * l, 0.05 * w, -0.13 * w, 0.44 * w, 0.52 * w],
		[-0.8333 * l, 0.03 * w, -0.09 * w, 0.37 * w, 0.43 * w], [-l + 0.02, 0.0, 0.0, 0.2, 0.26]]


## Rows for a thigh detail centred at y, `half` tall (absolute, so it keeps its drawn proportions on any thigh length):
## its top and bottom plus every pod ring y in between (a plate's rows must include the rings it crosses).
static func _thigh_rows(y: float, half: float) -> Array:
	var rows: Array = [y + half]
	for s: Array in _thigh_spec():
		if float(s[0]) < y + half - 0.01 and float(s[0]) > y - half + 0.01:
			rows.append(float(s[0]))
	rows.append(y - half)
	return rows


static func _thigh_rings() -> Array:
	var rings: Array = []
	for s: Array in _thigh_spec():
		rings.append(MeshKit.ring(Vector3(s[1], s[0], s[2]), s[3], s[4], THIGH_SIDES, "y", 2.4))
	return rings


## The armoured thigh pod: hip (origin) to the knee.
static func _thigh(k: MeshKit) -> void:
	var l: float = REST_LENGTH["thigh"]
	var rings := _thigh_rings()
	k.loft(rings, _thigh_colour)
	# Ring vertex k sits at TAU * (k + 0.5) / 10 from forward (-Z) toward +X: k = 2 is the outer face (+X), k = 4.5 the
	# back, k = 7 the inner face, k = 9.5 the front. Rows that cross a ring include that ring's y.
	# The stepped outer armour plate (over the orange mark) and the orange unit plate on it.
	_thigh_plate(k, rings, 1.0, 3.0, 2, [-0.2778 * l, -0.4444 * l, -0.6444 * l, -0.8333 * l], 0.032, WHITE)
	# The unit plate, bolts, panel line and vents keep their drawn size (scaled only with the pod's fullness) and sit at
	# the same share of the length.
	var w := _thigh_full()
	var mid := -0.4889 * l
	_thigh_plate(k, rings, 1.45, 2.85, 2, _thigh_rows(mid, 0.12 * w), 0.058, ORANGE)
	# Two bolts on the plate's front edge.
	for d: float in [0.135, -0.165]:
		var sp := _thigh_at(rings, mid + d * w, 1.17)
		var p: Vector3 = sp[0]
		var n: Vector3 = sp[1]
		k.tube(p + n * 0.02, p + n * 0.058, 0.032, 6, STEEL)
	# A raised panel line across the front.
	_thigh_plate(k, rings, 8.0, 11.0, 3, [mid, mid - 0.036], 0.022, DARK)
	# Three vent slats on the back.
	var vent := -0.5444 * l
	for d: float in [0.06, 0.0, -0.06]:
		var vy := vent + d * w
		_thigh_plate(k, rings, 4.0, 5.0, 1, [vy, vy - 0.032], 0.026, DARK)


## Surface point of the pod at height y and ring vertex kk (fractional, wraps) with its horizontal outward direction.
static func _thigh_at(rings: Array, y: float, kk: float) -> Array:
	var spec := _thigh_spec()
	var i := 0
	while i < spec.size() - 2 and y < float(spec[i + 1][0]):
		i += 1
	var t := clampf((float(spec[i][0]) - y) / (float(spec[i][0]) - float(spec[i + 1][0])), 0.0, 1.0)
	var f := fposmod(kk, float(THIGH_SIDES))
	var k0 := floori(f)
	var u := f - float(k0)
	var k1 := (k0 + 1) % THIGH_SIDES
	var ra: PackedVector3Array = rings[i]
	var rb: PackedVector3Array = rings[i + 1]
	var p := ra[k0].lerp(ra[k1], u).lerp(rb[k0].lerp(rb[k1], u), t)
	var c := Vector3(lerpf(spec[i][1], spec[i + 1][1], t), y, lerpf(spec[i][2], spec[i + 1][2], t))
	var n := p - c
	n.y = 0.0
	return [p, n.normalized()]


## A plate following the pod's facets: from vertex k0 to k1 in `steps` sections, across the rows `ys` (top to bottom),
## raised `lift` off the surface. Each section is convex (the raised rows plus a straight sunk inner edge), so the slab is
## a closed shell.
static func _thigh_plate(k: MeshKit, rings: Array, k0: float, k1: float, steps: int, ys: Array, lift: float, col: Variant) -> void:
	var secs: Array = []
	for j in steps + 1:
		var kk := lerpf(k0, k1, float(j) / float(steps))
		var ring := PackedVector3Array()
		var top := _thigh_at(rings, float(ys[0]), kk)
		var bot := _thigh_at(rings, float(ys[ys.size() - 1]), kk)
		ring.append((top[0] as Vector3) - (top[1] as Vector3) * 0.05)
		for y: float in ys:
			var s := _thigh_at(rings, y, kk)
			ring.append((s[0] as Vector3) + (s[1] as Vector3) * lift)
		ring.append((bot[0] as Vector3) - (bot[1] as Vector3) * 0.05)
		secs.append(ring)
	k.loft(secs, col)


## The shin strut: knee (origin) back down to the ankle, with a ribbed front framed by rails, a piston behind and a
## hydraulic hose down the outer side.
static func _shin(k: MeshKit) -> void:
	var l: float = REST_LENGTH["shin"]
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.14, 0.16), Vector2(0.11, 0.13), 4, GREY, MeshKit.SQUARE)
	for i in 5:
		k.box(Vector3(0.32, 0.075, 0.07), DARK, Vector3(0, -(0.1818 + float(i) * 0.1182) * l, -0.165 + float(i) * 0.006))
	var top := -0.1091 * l
	var bot := -l + 0.1
	var pa := Vector3(0, top, 0.26)
	var pb := Vector3(0, -0.4545 * l, 0.23)
	k.tube(pa, pb, 0.075, 6, DARK)
	k.tube(pb, Vector3(0, bot, 0.2), 0.045, 6, STEEL)
	for y: float in [top, bot]:
		k.box(Vector3(0.14, 0.11, 0.18), DARK, Vector3(0, y, 0.17))
	# Steel rails framing the tread.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.6 * l, 0.06), STEEL, Vector3(side * 0.177, -0.4182 * l, -0.16))
	# An orange band on the piston's cylinder.
	k.tube(pa.lerp(pb, 0.72), pa.lerp(pb, 0.9), 0.088, 6, ORANGE)
	# Clevis pins through the piston's end blocks.
	for y: float in [top, bot]:
		k.tube(Vector3(-0.1, y, 0.19), Vector3(0.1, y, 0.19), 0.036, 6, STEEL)
	# A hydraulic hose down the outer side, from the knee block to the ankle block.
	var hose := [Vector3(0.08, -0.0727 * l, 0.2), Vector3(0.175, -0.2545 * l, 0.07), Vector3(0.165, -0.7455 * l, 0.05),
		Vector3(0.08, -l + 0.12, 0.17)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.026, 6, BLACK)


## The tarsus: ankle (origin) forward down to the foot.
static func _tarsus(k: MeshKit) -> void:
	var l: float = REST_LENGTH["tarsus"]
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.1, 0.12), Vector2(0.12, 0.13), 4, DARK, MeshKit.SQUARE)
	var y0 := -0.2545 * l
	var y1 := -l + 0.04
	k.seg(Vector3(0, y0, -0.13), Vector3(0, y1, -0.15), Vector2(0.14, 0.04), Vector2(0.16, 0.05), 4, STEEL, MeshKit.SQUARE)
	var ra := Vector3(0, -0.1455 * l, 0.16)
	var rb := Vector3(0, -l + 0.08, 0.17)
	k.tube(ra, rb, 0.04, 5, GREY)
	# Two tread ribs across the front plate (centred on its front face), a clamp on the rear line, an orange tag on the
	# outer side.
	for f: float in [0.4545, 0.6909]:
		var t := (y0 + f * l) / (y0 - y1)
		k.box(Vector3(0.3, 0.05, 0.04), DARK, Vector3(0, -f * l, lerpf(-0.17, -0.2, t)))
	k.tube(ra.lerp(rb, 0.4), ra.lerp(rb, 0.55), 0.064, 6, DARK)
	k.box(Vector3(0.03, 0.13, 0.1), ORANGE, Vector3(0.122, -0.5455 * l, 0.01))


## The hip ball: a faceted sphere centred on the pivot.
const HIP_BALL := 0.3


static func _hip_ball(k: MeshKit) -> void:
	var profile: Array = []
	for i in 6:
		var a := PI * float(i) / 5.0
		profile.append(Vector2(sin(a) * HIP_BALL, cos(a) * HIP_BALL))
	profile.reverse()
	k.lathe(profile, 8, [STEEL, STEEL, WHITE, STEEL, STEEL], false, false)
	# The outer hub (+X): a dark disc sunk into the ball, a steel cap and four bolts. It stays below the socket's rim
	# (y < 0.1) so the ball still swivels inside the cup.
	k.tube(Vector3(0.24, 0, 0), Vector3(0.312, 0, 0), 0.1, 8, DARK)
	k.tube(Vector3(0.3, 0, 0), Vector3(0.336, 0, 0), 0.052, 6, STEEL)
	_bolt_ring(k, 0.312, 0.078, 0.03, 4, 0.0)


## The hip socket (right side): a cup over the top of the ball, and the strut that carries it into the pelvis.
static func _hip_socket(k: MeshKit) -> void:
	k.lathe([Vector2(0.37, 0.1), Vector2(0.35, 0.19), Vector2(0.27, 0.31), Vector2(0.13, 0.39)], 8, [GREY, DARK, DARK], true, true)
	k.seg(Vector3(-0.12, 0.3, 0), Vector3(-0.78, 0.44, 0), Vector2(0.12, 0.17), Vector2(0.15, 0.22), 4, DARK, MeshKit.SQUARE)
	k.tube(Vector3(0, 0.39, 0), Vector3(0, 0.44, 0), 0.08, 6, GREY)
	# A steel ring round the cup's shoulder and four bolts on the rim (the strut is buried in the pelvis).
	k.lathe([Vector2(0.362, 0.2), Vector2(0.338, 0.25)], 8, STEEL)
	for a: float in [0.0, 90.0, 180.0, 270.0]:
		var dir := Vector3(sin(deg_to_rad(a)), 0, -cos(deg_to_rad(a)))
		if dir.x < -0.5:
			dir = Vector3(-0.7, 0, -0.7).normalized()   # the strut covers the inner side: put that bolt front-inner
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.37 + Vector3(0, 0.145, 0)))
		k.box(Vector3(0.05, 0.05, 0.05), STEEL)
		k.pop()


## A joint: a drum on the axle (radius r, half width w) with a hub on each end (out to hub), and a concentric step ring
## on the outer end of the drum with four bolts round the hub.
static func _cap(k: MeshKit, r: float, w: float, hub: float) -> void:
	k.tube(Vector3(-w, 0, 0), Vector3(w, 0, 0), r, 8, DARK)
	k.tube(Vector3(-hub, 0, 0), Vector3(hub, 0, 0), r * 0.55, 8, GREY)
	var ring_r := r * 0.8
	var face := w + r * 0.12
	k.tube(Vector3(w - 0.01, 0, 0), Vector3(face, 0, 0), ring_r, 8, STEEL)
	_bolt_ring(k, face, (r * 0.55 + ring_r) * 0.5, maxf(r * 0.16, 0.026), 4, 45.0)


## `n` square bolt heads on a face across +X at x, on a circle of radius `rad`, size `s` (half sunk into the face).
static func _bolt_ring(k: MeshKit, x: float, rad: float, s: float, n: int, phase_deg: float) -> void:
	for i in n:
		var a := deg_to_rad(phase_deg + 360.0 * float(i) / float(n))
		k.box(Vector3(s, s, s), STEEL, Vector3(x + s * 0.2, cos(a) * rad, sin(a) * rad))


## The hub of the foot: the ankle socket the toes and spur hang from. Origin on the ground under the tarsus.
static func _foot(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.0), 0.3, 0.31, 6, "y"), MeshKit.ring(Vector3(0, 0.18, 0.0), 0.26, 0.27, 6, "y"),
		MeshKit.ring(Vector3(0, 0.33, 0.0), 0.15, 0.16, 6, "y")], [GREY, DARK])
	# A steel band round the waist and a steel collar on top (same hexagon as the hub).
	k.loft([MeshKit.ring(Vector3(0, 0.15, 0.0), 0.282, 0.292, 6, "y"), MeshKit.ring(Vector3(0, 0.205, 0.0), 0.272, 0.282, 6, "y")], STEEL)
	k.loft([MeshKit.ring(Vector3(0, 0.3, 0.0), 0.19, 0.2, 6, "y"), MeshKit.ring(Vector3(0, 0.36, 0.0), 0.17, 0.18, 6, "y")], STEEL)


## One toe: root at the origin, claw tip forward on the ground. Long and chunky, with two knuckle bands, a dark claw
## sheath and a dark pad under the root (each ring's lowest point, at the bottom of the pentagon, stays on y >= 0).
static func _toe(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.135, 0.06), 0.125, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.16, -0.32), 0.15, 0.155, 5, "z"),
		MeshKit.ring(Vector3(0, 0.14, -0.5), 0.13, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.1, -0.8), 0.1, 0.095, 5, "z"),
		MeshKit.ring(Vector3(0, 0.005, -1.12), 0.0, 0.0, 5, "z")], [STEEL, STEEL, STEEL, GREY])
	k.loft([MeshKit.ring(Vector3(0, 0.172, -0.3), 0.168, 0.168, 5, "z"), MeshKit.ring(Vector3(0, 0.17, -0.36), 0.166, 0.166, 5, "z")], DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.136, -0.6), 0.134, 0.133, 5, "z"), MeshKit.ring(Vector3(0, 0.131, -0.65), 0.13, 0.129, 5, "z")], DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.112, -0.78), 0.11, 0.108, 5, "z"), MeshKit.ring(Vector3(0, 0.01, -1.14), 0.0, 0.0, 5, "z")], GUN)
	k.box(Vector3(0.15, 0.03, 0.26), DARK, Vector3(0, 0.017, -0.12))


## The rear spur: root at the origin, pointing back and up, with a clamp block near the root and a dark collar at the bend.
static func _spur(k: MeshKit) -> void:
	k.seg(Vector3(0, 0.13, 0.0), Vector3(0, 0.22, 0.35), Vector2(0.1, 0.105), Vector2(0.087, 0.087), 4, STEEL)
	k.seg(Vector3(0, 0.22, 0.35), Vector3(0, 0.6, 0.7), Vector2(0.087, 0.087), Vector2.ZERO, 4, GREY)
	k.push(Transform3D(Basis(Vector3.RIGHT, -atan2(0.09, 0.35)), Vector3(0, 0.18, 0.2)))
	k.box(Vector3(0.23, 0.2, 0.07), DARK)
	k.pop()
	var d := Vector3(0, 0.38, 0.35).normalized()
	k.seg(Vector3(0, 0.22, 0.35) - d * 0.03, Vector3(0, 0.22, 0.35) + d * 0.07, Vector2(0.125, 0.125), Vector2(0.12, 0.12), 4, DARK)


# --- Weapons --------------------------------------------------------------------------------------------
# One builder per weapon, each with the details from the concept art (art/picks/, art/renders/mech_r8/): muzzle brakes,
# recoil sleeves, cooling slots, ammo boxes, lugs, bolts, hinge cheeks, pistons, cables, coloured bands.

static func _weapon(k: MeshKit, id: String) -> void:
	match id:
		"laser": _weapon_laser(k)
		"autocannon": _weapon_autocannon(k)
		"rockets": _tube_pod(k, WHITE, false)
		"missiles": _weapon_missiles(k)
		"flamer": _weapon_flamer(k)
		"mortar": _weapon_mortar(k)
		"railgun": _weapon_railgun(k)
		"gatling": _weapon_gatling(k)
		"swivel": _weapon_swivel(k)
		"repair_drone":
			_drone_cradle(k)
			k.push(MeshKit.xf(DRONE_DOCK))
			_drone(k)
			k.pop()
		"repair_drone_cradle": _drone_cradle(k)
		"repair_drone_flying": _drone(k)
		"radiator": _equip_radiator(k)
		"ammo_bin": _equip_ammo_bin(k)


static func _weapon_autocannon(k: MeshKit) -> void:
	k.box(Vector3(0.28, 0.3, 0.62), GUN, Vector3(0, 0, 0.06))
	k.box(Vector3(0.2, 0.14, 0.32), DARK, Vector3(0, 0.2, 0.12))
	k.box(Vector3(0.34, 0.12, 0.2), DARK, Vector3(0, -0.02, 0.02))
	k.tube(Vector3(0, 0.02, -0.25), Vector3(0, 0.02, -0.62), 0.1, 8, GUN)
	k.tube(Vector3(0, 0.02, -0.62), Vector3(0, 0.02, -1.3), 0.062, 8, DARK)
	k.tube(Vector3(0, 0.02, -1.3), Vector3(0, 0.02, -1.46), 0.095, 8, GUN)
	k.tube(Vector3(0, 0.02, -1.46), Vector3(0, 0.02, -1.465), 0.055, 6, BLACK)
	# Stepped side armour with two cooling slots each (rear half of the receiver).
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.2, 0.24), GREY, Vector3(s * 0.15, 0.0, 0.24))
		for i in 2:
			k.box(Vector3(0.02, 0.035, 0.18), BLACK, Vector3(s * 0.167, 0.04 - float(i) * 0.08, 0.24))
	# Top block: two bolts and a rear sight box.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.03, 0.04), STEEL, Vector3(s * 0.065, 0.285, 0.24))
	k.box(Vector3(0.08, 0.05, 0.1), GREY, Vector3(0, 0.29, 0.02))
	# Orange breech band, recoil sleeve, muzzle-brake side vents.
	k.tube(Vector3(0, 0.02, -0.3), Vector3(0, 0.02, -0.37), 0.106, 8, ORANGE)
	k.tube(Vector3(0, 0.02, -0.62), Vector3(0, 0.02, -0.8), 0.08, 6, STEEL)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.05, 0.1), BLACK, Vector3(s * 0.085, 0.02, -1.38))
	# Side ammo box with a dark lid (left side).
	k.box(Vector3(0.08, 0.12, 0.18), GREY, Vector3(-0.15, -0.08, 0.27))
	k.box(Vector3(0.09, 0.025, 0.19), DARK, Vector3(-0.15, -0.015, 0.27))


## The box launcher shared by "rockets" and "missiles": a 3x2 grid of tubes with warhead tips of `tip` in a raised frame,
## lugs on the top plate, stepped side panels and a rear cable conduit. `missiles` leaves room for the designator and
## drops the orange side stripes (the missiles have their red band).
static func _tube_pod(k: MeshKit, tip: Color, missiles: bool) -> void:
	k.box(Vector3(0.7, 0.5, 0.62), GUN, Vector3(0, 0.04, -0.02))
	k.box(Vector3(0.74, 0.08, 0.5), DARK, Vector3(0, 0.3, -0.02))
	k.box(Vector3(0.5, 0.3, 0.08), DARK, Vector3(0, 0.04, 0.32))
	for ix in 3:
		for iy in 2:
			var p := Vector3((float(ix) - 1.0) * 0.215, -0.07 + float(iy) * 0.22, -0.33)
			k.tube(p, p + Vector3(0, 0, -0.035), 0.09, 8, BLACK)
			k.tube(p + Vector3(0, 0, -0.03), p + Vector3(0, 0, -0.13), 0.055, 6, tip, 0.0)
	# A raised frame around the launcher face, and a divider between the two rows.
	k.box(Vector3(0.7, 0.045, 0.05), GREY, Vector3(0, 0.267, -0.35))
	k.box(Vector3(0.7, 0.045, 0.05), GREY, Vector3(0, -0.187, -0.35))
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.045, 0.41, 0.05), GREY, Vector3(s * 0.327, 0.04, -0.35))
	k.box(Vector3(0.62, 0.03, 0.04), GREY, Vector3(0, 0.04, -0.35))
	# Lugs on the top plate (the missile pod's front-right one makes room for the designator).
	for at: Vector3 in [Vector3(-0.27, 0.36, -0.18), Vector3(0.27, 0.36, -0.18), Vector3(-0.27, 0.36, 0.14), Vector3(0.27, 0.36, 0.14)]:
		if missiles and at.x > 0.0 and at.z < 0.0:
			continue
		k.box(Vector3(0.08, 0.05, 0.08), DARK, at)
	# Stepped side panels with two screws each, and an orange stripe above (rockets only).
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.025, 0.26, 0.34), GREY, Vector3(s * 0.355, 0.0, -0.02))
		k.box(Vector3(0.02, 0.04, 0.04), STEEL, Vector3(s * 0.37, 0.09, -0.15))
		k.box(Vector3(0.02, 0.04, 0.04), STEEL, Vector3(s * 0.37, -0.09, 0.11))
		if not missiles:
			k.box(Vector3(0.025, 0.06, 0.4), ORANGE, Vector3(s * 0.357, 0.19, -0.02))
	# Rear cable conduit from the back box down into the mount.
	k.tube(Vector3(0.16, 0.02, 0.37), Vector3(0.16, -0.17, 0.31), 0.03, 6, BLACK)


## Same pod as the rockets, told apart by red warheads, a red band and a laser designator in a boxed housing.
static func _weapon_missiles(k: MeshKit) -> void:
	_tube_pod(k, MISSILE_RED, true)
	k.box(Vector3(0.72, 0.52, 0.07), MISSILE_RED, Vector3(0, 0.04, -0.2))
	k.tube(Vector3(0.24, 0.385, -0.16), Vector3(0.24, 0.385, -0.36), 0.045, 6, DARK)
	k.glow = true
	k.tube(Vector3(0.24, 0.385, -0.36), Vector3(0.24, 0.385, -0.366), 0.03, 6, TEAL)
	k.glow = false
	# The designator housing with a square lens hood.
	k.box(Vector3(0.12, 0.08, 0.16), GUN, Vector3(0.24, 0.38, -0.2))
	k.seg(Vector3(0.24, 0.385, -0.31), Vector3(0.24, 0.385, -0.35), Vector2(0.06, 0.06), Vector2(0.065, 0.065), 4, DARK, MeshKit.SQUARE)


static func _weapon_laser(k: MeshKit) -> void:
	k.tube(Vector3(0, 0, 0.36), Vector3(0, 0, -0.3), 0.13, 8, GUN)
	k.box(Vector3(0.2, 0.2, 0.16), DARK, Vector3(0, 0, 0.4))
	for i in 3:
		k.box(Vector3(0.05, 0.1, 0.12), DARK, Vector3(0, 0.15, 0.2 - float(i) * 0.17))
	k.tube(Vector3(0, 0, -0.3), Vector3(0, 0, -0.84), 0.065, 8, STEEL)
	k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -1.04), 0.13, 8, GUN)
	k.glow = true
	k.tube(Vector3(0, 0, -1.04), Vector3(0, 0, -1.07), 0.1, 8, TEAL, 0.06)
	k.glow = false
	# Orange band and steel bezel behind the lens (f_laser).
	k.tube(Vector3(0, 0, -0.88), Vector3(0, 0, -0.95), 0.137, 8, ORANGE)
	k.tube(Vector3(0, 0, -1.0), Vector3(0, 0, -1.04), 0.137, 8, STEEL)
	# Heat-sink rings on the emitter.
	for i in 3:
		var z := -0.42 - float(i) * 0.14
		k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.045), 0.098, 6, DARK)
	# Underslung capacitor with a cable to the rear box.
	k.box(Vector3(0.12, 0.08, 0.34), DARK, Vector3(0, -0.12, 0.04))
	k.seg(Vector3(0.06, -0.08, 0.47), Vector3(0.05, -0.14, 0.22), Vector2(0.022, 0.022), Vector2(0.022, 0.022), 6, BLACK)
	# Front sight block and four bolts on the rear face.
	k.box(Vector3(0.06, 0.05, 0.12), GREY, Vector3(0, 0.15, -0.22))
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			k.box(Vector3(0.04, 0.04, 0.03), STEEL, Vector3(sx * 0.06, sy * 0.06, 0.49))


static func _weapon_flamer(k: MeshKit) -> void:
	k.ico(Vector3(0, 0.1, 0.16), Vector3(0.17, 0.2, 0.2), TANK)
	k.ico(Vector3(0, -0.12, 0.2), Vector3(0.12, 0.13, 0.15), TANK)
	k.box(Vector3(0.16, 0.2, 0.3), GUN, Vector3(0, 0, -0.08))
	k.tube(Vector3(0, 0, -0.2), Vector3(0, 0, -0.62), 0.055, 8, DARK)
	k.tube(Vector3(0, 0, -0.62), Vector3(0, 0, -0.84), 0.06, 8, GUN, 0.12)
	k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -0.845), 0.09, 8, BLACK)
	k.glow = true
	k.box(Vector3(0.04, 0.04, 0.06), AMBER, Vector3(0, -0.11, -0.8))
	k.glow = false
	# Straps round both tanks.
	k.seg(Vector3(0, 0.1, 0.13), Vector3(0, 0.1, 0.19), Vector2(0.168, 0.198), Vector2(0.168, 0.198), 8, DARK)
	k.seg(Vector3(0, -0.12, 0.175), Vector3(0, -0.12, 0.225), Vector2(0.118, 0.128), Vector2(0.118, 0.128), 8, DARK)
	# Valve with a handwheel on the big tank.
	k.tube(Vector3(0, 0.24, 0.16), Vector3(0, 0.29, 0.16), 0.03, 6, STEEL)
	k.box(Vector3(0.1, 0.025, 0.1), DARK, Vector3(0, 0.29, 0.16))
	# Fuel hose from the small tank under the body into the nozzle block.
	k.seg(Vector3(0.05, -0.2, 0.12), Vector3(0.05, -0.17, -0.06), Vector2(0.028, 0.028), Vector2(0.028, 0.028), 6, BLACK)
	k.seg(Vector3(0.05, -0.17, -0.06), Vector3(0.04, -0.08, -0.2), Vector2(0.028, 0.028), Vector2(0.028, 0.028), 6, BLACK)
	# Pilot-light shroud round the amber flame, heat bands on the nozzle, an orange stripe on the body.
	k.box(Vector3(0.07, 0.06, 0.13), GUN, Vector3(0, -0.11, -0.71))
	k.tube(Vector3(0, 0, -0.44), Vector3(0, 0, -0.48), 0.072, 6, STEEL)
	k.tube(Vector3(0, 0, -0.66), Vector3(0, 0, -0.7), 0.085, 6, STEEL)
	k.box(Vector3(0.17, 0.05, 0.22), ORANGE, Vector3(0, 0.06, -0.1))


## A base plate with trunnions and a barrel angled up and forward from `a` to the muzzle at `b`.
static func _weapon_mortar(k: MeshKit) -> void:
	var a := Vector3(0, 0.12, 0.14)
	var b := Vector3(0, 1.22, -0.3)
	var d := (b - a).normalized()
	k.box(Vector3(0.56, 0.16, 0.5), DARK, Vector3(0, 0.02, 0.04))
	k.tube(Vector3(-0.26, 0.24, 0.08), Vector3(0.26, 0.24, 0.08), 0.1, 8, GUN)
	k.tube(a, b, 0.16, 8, GUN)
	k.tube(b - d * 0.16, b + d * 0.02, 0.2, 8, DARK)
	k.tube(b + d * 0.02, b + d * 0.025, 0.13, 8, BLACK)
	k.box(Vector3(0.1, 0.34, 0.1), STEEL, Vector3(0, 0.3, -0.16))
	# A square clamp round the barrel (d_mortar) with a bolt each side.
	var at := func(t: float) -> Vector3: return a.lerp(b, t)
	k.seg(at.call(0.56), at.call(0.64), Vector2(0.2, 0.2), Vector2(0.2, 0.2), 4, GUN, MeshKit.SQUARE)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.05, 0.06, 0.06), STEEL, (at.call(0.6) as Vector3) + Vector3(s * 0.215, 0, 0))
	# Hydraulic pistons from the base up both sides of the barrel.
	for s: float in [-1.0, 1.0]:
		var foot := Vector3(s * 0.19, 0.1, -0.12)
		var top: Vector3 = (at.call(0.42) as Vector3) + Vector3(s * 0.17, 0, 0)
		k.tube(foot, foot.lerp(top, 0.55), 0.05, 6, DARK)
		k.tube(foot.lerp(top, 0.5), top, 0.032, 6, STEEL)
	# Trunnion caps, an orange band below the muzzle, a front step on the base.
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.25, 0.24, 0.08), Vector3(s * 0.29, 0.24, 0.08), 0.13, 6, DARK)
	k.tube(at.call(0.76), at.call(0.8), 0.168, 8, ORANGE)
	k.box(Vector3(0.48, 0.06, 0.1), GREY, Vector3(0, 0.0, -0.25))


static func _weapon_railgun(k: MeshKit) -> void:
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
	# Seven thinner steel coils between the dark ones (g_railgun's tight coil pack).
	for i in 7:
		var z := -0.555 - float(i) * 0.2
		k.tube(Vector3(0, 0, z + 0.02), Vector3(0, 0, z - 0.02), 0.125, 8, STEEL)
	# Muzzle collar round the rails.
	k.seg(Vector3(0, 0, -1.93), Vector3(0, 0, -2.0), Vector2(0.13, 0.13), Vector2(0.13, 0.13), 4, DARK, MeshKit.SQUARE)
	# Four teal charge cells on the receiver's top shelf (the four charge steps).
	k.glow = true
	for i in 4:
		k.box(Vector3(0.04, 0.025, 0.06), TEAL, Vector3(-0.135, 0.19, -0.16 + float(i) * 0.1))
	k.glow = false
	# Side capacitor with cooling slots (left), cable conduits to the coil pack, orange band, butt plate.
	k.box(Vector3(0.04, 0.22, 0.4), GREY, Vector3(-0.175, -0.03, 0.18))
	for i in 3:
		k.box(Vector3(0.02, 0.03, 0.3), BLACK, Vector3(-0.195, 0.04 - float(i) * 0.07, 0.18))
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.06, 0.2, -0.04), Vector3(s * 0.06, 0.12, -0.42), 0.025, 6, BLACK)
	k.box(Vector3(0.33, 0.37, 0.05), ORANGE, Vector3(0, 0, -0.19))
	k.box(Vector3(0.26, 0.28, 0.05), DARK, Vector3(0, -0.01, 0.5))


static func _weapon_gatling(k: MeshKit) -> void:
	k.tube(Vector3(0, 0, 0.34), Vector3(0, 0, -0.22), 0.18, 8, GUN)
	k.box(Vector3(0.22, 0.26, 0.3), DARK, Vector3(0, -0.2, 0.12))
	for i in 6:
		var ang := TAU * float(i) / 6.0
		var o := Vector3(cos(ang), sin(ang), 0) * 0.095
		k.tube(o + Vector3(0, 0, -0.22), o + Vector3(0, 0, -1.02), 0.036, 5, STEEL)
	k.tube(Vector3(0, 0, -0.5), Vector3(0, 0, -0.56), 0.145, 8, DARK)
	k.tube(Vector3(0, 0, -0.9), Vector3(0, 0, -0.96), 0.145, 8, DARK)
	# Red ammo box with a lid and a feed chute into the housing (e_hipgatling).
	k.box(Vector3(0.1, 0.18, 0.22), MISSILE_RED, Vector3(0.14, -0.22, 0.12))
	k.box(Vector3(0.11, 0.03, 0.23), DARK, Vector3(0.14, -0.12, 0.12))
	k.seg(Vector3(0.14, -0.12, 0.02), Vector3(0.11, -0.05, -0.15), Vector2(0.035, 0.045), Vector2(0.035, 0.045), 4, DARK, MeshKit.SQUARE)
	# Rear barrel collar and the spindle.
	k.tube(Vector3(0, 0, -0.22), Vector3(0, 0, -0.29), 0.15, 6, STEEL)
	k.tube(Vector3(0, 0, -0.29), Vector3(0, 0, -1.0), 0.04, 6, BLACK)
	# Cooling bands on the motor housing, an orange band at its front, a carry handle on top.
	for i in 3:
		var z := 0.27 - float(i) * 0.08
		k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.035), 0.19, 8, DARK)
	k.tube(Vector3(0, 0, -0.14), Vector3(0, 0, -0.2), 0.188, 8, ORANGE)
	for z: float in [0.2, -0.06]:
		k.box(Vector3(0.04, 0.05, 0.04), DARK, Vector3(0, 0.19, z))
	k.box(Vector3(0.045, 0.03, 0.32), STEEL, Vector3(0, 0.215, 0.07))


## A ball pivot at the origin (the boom turns about it at runtime, scripts/combat/weapons/swivel.gd), a boom out to an
## elbow and a twin-barrel gun box.
static func _weapon_swivel(k: MeshKit) -> void:
	k.ico(Vector3.ZERO, Vector3(0.13, 0.13, 0.13), DARK)
	k.seg(Vector3.ZERO, Vector3(0, -0.08, -0.5), Vector2(0.05, 0.06), Vector2(0.045, 0.055), 4, GREY, MeshKit.SQUARE)
	k.tube(Vector3(-0.09, -0.08, -0.5), Vector3(0.09, -0.08, -0.5), 0.08, 8, DARK)
	k.box(Vector3(0.2, 0.2, 0.44), GUN, Vector3(0, -0.08, -0.68))
	k.box(Vector3(0.12, 0.1, 0.2), ORANGE, Vector3(0, 0.06, -0.62))
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.05, -0.08, -0.9), Vector3(side * 0.05, -0.08, -1.25), 0.034, 6, DARK)
	# Hinge cheeks on the boom's elbow (h_booms), a hydraulic piston under the boom, a cable along its top.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.12, 0.12), GREY, Vector3(s * 0.105, -0.08, -0.5))
	k.tube(Vector3(0, -0.1, -0.06), Vector3(0, -0.13, -0.26), 0.035, 6, DARK)
	k.tube(Vector3(0, -0.125, -0.24), Vector3(0, -0.155, -0.44), 0.022, 6, STEEL)
	k.seg(Vector3(0.03, 0.07, -0.04), Vector3(0.03, 0.035, -0.5), Vector2(0.02, 0.02), Vector2(0.02, 0.02), 6, BLACK)
	# Vent slots down both sides of the gun box, a front face plate, muzzle shrouds.
	for s: float in [-1.0, 1.0]:
		for i in 2:
			k.box(Vector3(0.02, 0.03, 0.18), BLACK, Vector3(s * 0.104, -0.04 - float(i) * 0.07, -0.72))
		k.tube(Vector3(s * 0.05, -0.08, -0.91), Vector3(s * 0.05, -0.08, -1.0), 0.05, 6, GUN)
	k.box(Vector3(0.21, 0.21, 0.03), DARK, Vector3(0, -0.08, -0.9))


# --- Back-mount equipment -------------------------------------------------------------------------------
# docs/design/back-equipment.md. Origin at MOUNTS["back"], like the mortar. The rear deck under the mount slopes down
# toward the tail (about 0.15 above the mount 0.2 ahead of it, 0.3 below it 0.2 behind it), so every item stands on the
# mortar's base plate with two braces down to the deck behind. Kept inside |x| < 0.45 (the shoulder weapons' inner
# faces are at 0.51), behind z -0.33 (the back plate's rear face is at -0.375) and lower than the mortar's muzzle.

## The shared base plate (the mortar's footprint) on a wedge that fills the gap down to the falling deck behind it.
static func _back_base(k: MeshKit, bolts: bool) -> void:
	k.box(Vector3(0.5, 0.12, 0.44), DARK, Vector3(0, 0.02, 0.04))
	var prof := [Vector2(-0.06, -0.03), Vector2(0.25, -0.03), Vector2(0.25, -0.4), Vector2(0.2, -0.42), Vector2(0.04, -0.19)]
	var rings: Array = []
	for s: float in [-1.0, 1.0]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(s * 0.19, p.y, p.x))
		rings.append(r)
	k.loft(rings, GUN)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.02, 0.16, 0.12), DARK, Vector3(s * 0.195, -0.14, 0.18))
		k.box(Vector3(0.03, 0.04, 0.04), STEEL, Vector3(s * 0.2, -0.06, 0.18))
	if bolts:
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				k.box(Vector3(0.045, 0.035, 0.045), STEEL, Vector3(sx * 0.2, 0.09, 0.04 + sz * 0.17))


## A closed flat ring (a rotor guard): outer and inner walls, top and bottom faces, around Y at `c`, from y0 to y1.
static func _band(k: MeshKit, c: Vector3, r_out: float, r_in: float, y0: float, y1: float, n: int, col: Color) -> void:
	var ob := MeshKit.ring(c + Vector3(0, y0, 0), r_out, r_out, n)
	var ot := MeshKit.ring(c + Vector3(0, y1, 0), r_out, r_out, n)
	var ib := MeshKit.ring(c + Vector3(0, y0, 0), r_in, r_in, n)
	var it := MeshKit.ring(c + Vector3(0, y1, 0), r_in, r_in, n)
	var mid := c + Vector3(0, (y0 + y1) * 0.5, 0)
	for i in n:
		var j := (i + 1) % n
		k.quad(ob[i], ob[j], ot[j], ot[i], col, mid)
		var out := (ib[i] + ib[j]) * 0.5 - c
		out.y = 0.0
		k.quad(ib[i], ib[j], it[j], it[i], col, (ib[i] + it[j]) * 0.5 + out.normalized())
		k.quad(ot[i], ot[j], it[j], it[i], col, mid - Vector3(0, 1, 0))
		k.quad(ob[i], ob[j], ib[j], ib[i], col, mid + Vector3(0, 1, 0))


## The repair drone alone, origin at its centre, facing -Z: a boxy hull in the accent colour with a white top deck and a
## green repair cross on it, a green sensor eye in a bezel on the nose, four diagonal arms out to motors with dark rotor
## discs (a blade across each) inside white guard rings, and two landing skids (their soles at y -0.145).
static func _drone(k: MeshKit) -> void:
	k.box(Vector3(0.28, 0.11, 0.34), ORANGE)
	k.box(Vector3(0.22, 0.04, 0.26), WHITE, Vector3(0, 0.07, 0.02))
	k.box(Vector3(0.22, 0.05, 0.28), DARK, Vector3(0, -0.07, 0.0))
	# The nose: a dark visor block, a bezel and the green eye.
	k.box(Vector3(0.18, 0.08, 0.04), DARK, Vector3(0, 0.0, -0.18))
	k.tube(Vector3(0, 0, -0.19), Vector3(0, 0, -0.215), 0.05, 6, GUN)
	k.glow = true
	k.tube(Vector3(0, 0, -0.213), Vector3(0, 0, -0.223), 0.034, 6, REPAIR_GREEN)
	# The repair cross on the top deck, and a tail light.
	k.box(Vector3(0.13, 0.012, 0.04), REPAIR_GREEN, Vector3(0, 0.095, 0.03))
	k.box(Vector3(0.04, 0.012, 0.13), REPAIR_GREEN, Vector3(0, 0.095, 0.03))
	k.box(Vector3(0.08, 0.025, 0.012), REPAIR_GREEN, Vector3(0, 0.0, 0.175))
	k.glow = false
	# Arms, motors, rotors, guards.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var hub := Vector3(sx * 0.23, 0.0, sz * 0.23)
			var dir := Vector3(sx, 0, sz).normalized()
			k.seg(Vector3(sx * 0.1, 0.0, sz * 0.1), hub + dir * 0.135, Vector2(0.026, 0.02), Vector2(0.022, 0.018), 4, GREY, MeshKit.SQUARE)
			k.tube(hub - Vector3(0, 0.035, 0), hub + Vector3(0, 0.04, 0), 0.038, 6, DARK)
			k.tube(hub + Vector3(0, 0.04, 0), hub + Vector3(0, 0.048, 0), 0.112, 8, GUN)
			k.push(MeshKit.xf(hub + Vector3(0, 0.054, 0), Vector3(0, 45.0 * sx * sz, 0)))
			k.box(Vector3(0.21, 0.01, 0.03), BLACK)
			k.pop()
			_band(k, hub, 0.135, 0.12, 0.012, 0.062, 8, WHITE)
	# Skids: two deep rails under the belly.
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.024, 0.05, 0.3), STEEL, Vector3(sx * 0.1, -0.12, 0.0))


## The drone's launch cradle on the back mount (the docked mesh without the drone): the base plate, a pedestal and a pad
## (top at y 0.165, where the skids land) with an H mark, two clamp jaws that grip the hull's sides, an accent lip with
## two green status lights on the rear edge, and a cable from the pad down into the deck.
static func _drone_cradle(k: MeshKit) -> void:
	_back_base(k, false)
	k.box(Vector3(0.3, 0.06, 0.3), GUN, Vector3(0, 0.1, 0.02))
	k.box(Vector3(0.56, 0.05, 0.56), GREY, Vector3(0, 0.14, 0.02))
	# The H on the pad.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.008, 0.2), WHITE, Vector3(s * 0.07, 0.168, 0.02))
	k.box(Vector3(0.105, 0.008, 0.035), WHITE, Vector3(0, 0.168, 0.02))
	# Clamp jaws on both sides: an upright, a jaw reaching in over the hull's side, a hinge pin.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.17, 0.09), STEEL, Vector3(s * 0.215, 0.245, 0.02))
		k.box(Vector3(0.09, 0.045, 0.09), DARK, Vector3(s * 0.175, 0.31, 0.02))
		k.tube(Vector3(s * 0.215, 0.2, -0.04), Vector3(s * 0.215, 0.2, 0.08), 0.022, 6, DARK)
	# The rear lip in the accent colour, with two green status lights.
	k.box(Vector3(0.5, 0.06, 0.035), ORANGE, Vector3(0, 0.15, 0.315))
	k.glow = true
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.05, 0.025, 0.012), REPAIR_GREEN, Vector3(s * 0.17, 0.155, 0.337))
	k.glow = false
	# The charge cable from under the pad down into the deck.
	var cable := [Vector3(0.2, 0.12, 0.24), Vector3(0.24, 0.02, 0.3), Vector3(0.22, -0.3, 0.27)]
	for i in cable.size() - 1:
		k.tube(cable[i], cable[i + 1], 0.024, 6, BLACK)


## Radiator fins: seven tall flat fins across the mount (on the "heat" surface, which the game makes glow with heat;
## edge on to the camera behind, broadside from the sides) on a header box, a manifold pipe through them with accent end
## caps, two tie bars through their rear halves, and two coolant pipes forward into the back plate's rear face.
static func _equip_radiator(k: MeshKit) -> void:
	_back_base(k, true)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.05, 0.2), DARK, Vector3(s * 0.15, 0.1, 0.02))
	k.box(Vector3(0.6, 0.1, 0.34), GUN, Vector3(0, 0.17, 0.02))
	# The fins: chamfered plates stepping down and in toward the sides, so the side view shows their nested edges.
	k.heat = true
	for i in 7:
		var x := (float(i) - 3.0) * 0.08
		var a := absf(float(i) - 3.0) / 3.0
		var top := 0.86 - 0.3 * a
		var zf := -0.17 + 0.12 * a
		var zb := 0.21 - 0.1 * a
		var prof := [Vector2(zf, 0.22), Vector2(zb, 0.22), Vector2(zb, top - 0.1), Vector2(zb - 0.08, top), Vector2(zf + 0.08, top),
			Vector2(zf, top - 0.08)]
		var rings: Array = []
		for side: float in [-1.0, 1.0]:
			var r := PackedVector3Array()
			for p: Vector2 in prof:
				r.append(Vector3(x + side * 0.011, p.y, p.x))
			rings.append(r)
		k.loft(rings, STEEL)
	k.heat = false
	# The manifold through the fins with accent end caps, two tie bars through the rear halves.
	k.tube(Vector3(-0.3, 0.5, 0.03), Vector3(0.3, 0.5, 0.03), 0.045, 8, GUN)
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.29, 0.5, 0.03), Vector3(s * 0.33, 0.5, 0.03), 0.065, 8, ORANGE)
	for y: float in [0.34, 0.47]:
		k.box(Vector3(0.5, 0.035, 0.035), GREY, Vector3(0, y, 0.08))
	# Coolant pipes from the header's sides forward into the back plate, with collars where they enter.
	for s: float in [-1.0, 1.0]:
		var pts := [Vector3(s * 0.27, 0.17, -0.08), Vector3(s * 0.33, 0.23, -0.2), Vector3(s * 0.33, 0.3, -0.45)]
		for i in pts.size() - 1:
			k.tube(pts[i], pts[i + 1], 0.032, 6, STEEL)
		k.tube(Vector3(s * 0.33, 0.29, -0.36), Vector3(s * 0.33, 0.3, -0.41), 0.05, 6, DARK)
	# A heat gauge (amber) in a dark frame and an accent plate on the header's rear face.
	k.box(Vector3(0.1, 0.06, 0.02), DARK, Vector3(0.16, 0.17, 0.195))
	k.glow = true
	k.box(Vector3(0.07, 0.03, 0.012), AMBER, Vector3(0.16, 0.17, 0.207))
	k.glow = false
	k.box(Vector3(0.2, 0.05, 0.02), ORANGE, Vector3(-0.12, 0.17, 0.195))


## Ammo bin: a ribbed magazine crate with a lid and a carry handle, two latches and a hazard stripe (accent with black
## slats) on the rear face, accent unit plates on the sides, and a segmented feed chute from its right side curving down
## into the deck toward the body.
static func _equip_ammo_bin(k: MeshKit) -> void:
	_back_base(k, false)
	k.box(Vector3(0.58, 0.42, 0.48), GUN, Vector3(0, 0.31, 0.04))
	for z: float in [-0.14, 0.04, 0.22]:
		k.box(Vector3(0.62, 0.44, 0.04), GREY, Vector3(0, 0.31, z))
	k.box(Vector3(0.6, 0.05, 0.5), DARK, Vector3(0, 0.545, 0.04))
	# The carry handle on the lid.
	k.box(Vector3(0.22, 0.025, 0.04), STEEL, Vector3(0, 0.615, 0.1))
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.025, 0.05, 0.025), STEEL, Vector3(s * 0.1, 0.59, 0.1))
	# Latches over the lid's rear edge.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.07, 0.12, 0.03), STEEL, Vector3(s * 0.17, 0.49, 0.295))
		k.box(Vector3(0.05, 0.03, 0.04), DARK, Vector3(s * 0.17, 0.455, 0.315))
	# The hazard stripe: an accent band with four black diagonal slats.
	k.box(Vector3(0.5, 0.09, 0.02), ORANGE, Vector3(0, 0.2, 0.29))
	for i in 4:
		k.push(MeshKit.xf(Vector3(-0.18 + float(i) * 0.12, 0.2, 0.302), Vector3(0, 0, 45.0)))
		k.box(Vector3(0.026, 0.095, 0.012), BLACK)
		k.pop()
	# Accent unit plates on both sides, between the rear ribs.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.02, 0.12, 0.12), ORANGE, Vector3(s * 0.295, 0.38, 0.13))
	# The feed chute: an outlet on the right side, three square segments curving down into the deck, steel collars.
	k.box(Vector3(0.05, 0.14, 0.16), DARK, Vector3(0.31, 0.3, -0.06))
	var pts := [Vector3(0.3, 0.3, -0.06), Vector3(0.35, 0.27, -0.08), Vector3(0.375, 0.16, -0.1), Vector3(0.375, -0.02, -0.12)]
	for i in pts.size() - 1:
		k.seg(pts[i], pts[i + 1], Vector2(0.04, 0.055), Vector2(0.04, 0.055), 4, DARK, MeshKit.SQUARE)
	for i: int in [1, 2]:
		var d: Vector3 = ((pts[i + 1] as Vector3) - (pts[i - 1] as Vector3)).normalized()
		k.seg((pts[i] as Vector3) - d * 0.02, (pts[i] as Vector3) + d * 0.02, Vector2(0.05, 0.066), Vector2(0.05, 0.066), 4, STEEL, MeshKit.SQUARE)
