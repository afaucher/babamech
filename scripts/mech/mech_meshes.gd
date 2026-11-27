class_name MechMeshes
extends RefCounted
## The low-poly art parts of the chicken mech (docs/design/game-design.md 4.1-4.3, art/picks/): chassis pieces, leg
## segments, and the registry of every Strider part, with the weapons and equipment (MechWeaponMeshes) and the pilot heads
## (MechHeadMeshes). Every part is generated with MeshKit and saved as its own file under
## res://assets/models/mech/<name>.res by tools/models/gen_mech_meshes.gd; `mesh(name)` loads the saved file (or builds it
## when the file is missing, e.g. before the first generation; PartCache). Colours: LowPolyPalette; materials:
## LowPolyMaterials.
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

const BODY_PARTS := ["torso", "nose", "hatch", "back_plate", "pelvis", "shoulder_pylon", "shoulder_pod", "side_mount"]
const LEG_PARTS := ["thigh", "shin", "tarsus", "hip_socket", "hip_cap", "knee_cap", "ankle_cap", "foot", "toe", "spur"]
## Weapon looks from the concept art. The catalog (MechCatalog.WEAPONS) decides which ones the game uses.
const WEAPONS := ["laser", "autocannon", "rockets", "missiles", "flamer", "mortar", "railgun", "gatling", "swivel", "flak"]
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
	return PartCache.mesh(DIR, part, build)


## A MeshInstance3D of a part.
static func instance(part: String) -> MeshInstance3D:
	return PartCache.instance(DIR, part, build)


## Generate a part from scratch (the generator and the staleness test use this).
static func build(part: String) -> ArrayMesh:
	var k := MeshKit.new()
	if not part.begins_with("head_"):
		k.accent_key = LowPolyPalette.ORANGE   # heads never take the accent
	if part.begins_with("head_"):
		MechHeadMeshes.build(k, part.trim_prefix("head_"))
	elif part.begins_with("weapon_"):
		MechWeaponMeshes.build(k, part.trim_prefix("weapon_"))
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
			"knee_cap": k.joint_cap(0.24, 0.27, 0.33, LowPolyPalette.DARK, LowPolyPalette.GREY, LowPolyPalette.STEEL)
			"ankle_cap": k.joint_cap(0.18, 0.2, 0.26, LowPolyPalette.DARK, LowPolyPalette.GREY, LowPolyPalette.STEEL)
			"foot": strider_foot(k)
			"toe": _toe(k)
			"spur": strider_spur(k)
	return k.commit(LowPolyMaterials.materials())


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
		return LowPolyPalette.DARK                       # the underside
	if n.y < -0.3:
		return LowPolyPalette.GREY                       # the lower belly
	if n.z > 0.9:
		return LowPolyPalette.GREY                       # the small back end cap (the nose covers the front one)
	var q := Vector2(n.x, n.y).normalized()
	if absf(q.x) > 0.6 and q.y > 0.3 and c.z > -0.9 and c.z < 0.85:
		return LowPolyPalette.ORANGE                     # the band along the upper flank / shoulder line
	if c.z > 0.32 and c.z < 0.68 and n.y > 0.75:
		return LowPolyPalette.ORANGE                     # a band across the rear deck
	return LowPolyPalette.WHITE


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
static func _torso(k: MeshKit, pad: Dictionary = ARM_PAD) -> void:
	# The egg-shaped pod.
	var rings: Array = []
	for s: Array in TORSO:
		rings.append(_torso_ring(s))
	k.loft(rings, _torso_colour)
	for side: float in [-1.0, 1.0]:
		k.glow = true
		for a: float in [72.0, 84.0]:
			k.push(_on_torso(-0.86, side * a, 0.01))
			k.box(Vector3(0.17, 0.085, 0.06), LowPolyPalette.AMBER)
			k.pop()
		k.push(_on_torso(-0.45, side * 78.0, 0.01))
		k.box(Vector3(0.26, 0.1, 0.06), LowPolyPalette.AMBER)
		k.pop()
		k.glow = false
		k.push(_on_torso(-0.86, side * 78.0, 0.0))
		k.box(Vector3(0.24, 0.3, 0.05), LowPolyPalette.DARK)
		k.pop()
		k.push(_on_torso(-0.45, side * 78.0, 0.0))
		k.box(Vector3(0.34, 0.17, 0.05), LowPolyPalette.DARK)
		k.pop()
	for side: float in [-1.0, 1.0]:
		var lo := func(a0: float, a1: float) -> Vector2: return Vector2(a0, a1) if side > 0.0 else Vector2(-a1, -a0)
		# Stepped orange shoulder plates over the flank band, ahead of and behind the shoulder pod.
		# Each sits on a slightly larger dark under-plate, which shows as a panel line round the raised plate.
		var r: Vector2 = lo.call(38.0, 72.0)
		_torso_plate(k, -0.83, -0.27, r.x, r.y, 0.02, LowPolyPalette.DARK)
		r = lo.call(42.0, 68.0)
		_torso_plate(k, -0.79, -0.31, r.x, r.y, 0.05, LowPolyPalette.ORANGE)
		r = lo.call(39.0, 70.0)
		_torso_plate(k, 0.45, 0.83, r.x, r.y, 0.02, LowPolyPalette.DARK)
		r = lo.call(43.0, 66.0)
		_torso_plate(k, 0.49, 0.79, r.x, r.y, 0.05, LowPolyPalette.ORANGE)
		# A dark waist seam between the white flank and the grey belly.
		r = lo.call(102.0, 109.0)
		_torso_plate(k, -0.9, 0.86, r.x, r.y, 0.025, LowPolyPalette.DARK)
		# Recessed light housings: a grey surround under each dark frame and a hood over each light.
		_torso_box(k, -0.86, side * 78.0, -0.01, Vector3(0.32, 0.38, 0.05), LowPolyPalette.GREY)
		_torso_box(k, -0.45, side * 78.0, -0.01, Vector3(0.42, 0.25, 0.05), LowPolyPalette.GREY)
		_torso_box(k, -0.86, side * 78.0, 0.0, Vector3(0.28, 0.035, 0.12), LowPolyPalette.DARK, Vector3(0, 0.165, -0.045))
		_torso_box(k, -0.45, side * 78.0, 0.0, Vector3(0.38, 0.035, 0.12), LowPolyPalette.DARK, Vector3(0, 0.1, -0.045))
		# An orange unit plate on the rear flank with a dark bar along its top edge.
		r = lo.call(76.0, 94.0)
		_torso_plate(k, 0.52, 0.76, r.x, r.y, 0.03, LowPolyPalette.ORANGE)
		r = lo.call(76.0, 80.0)
		_torso_plate(k, 0.52, 0.76, r.x, r.y, 0.05, LowPolyPalette.DARK)
		# A cable run along the rear deck from the back plate to the back-mount saddle.
		var c0 := _torso_at(0.28, side * 24.0)
		var c1 := _torso_at(0.42, side * 24.0)
		var c2 := _torso_at(0.56, side * 22.0)
		var pts := [(c0[0] as Vector3) + (c0[1] as Vector3) * 0.03, (c1[0] as Vector3) + (c1[1] as Vector3) * 0.035,
			(c2[0] as Vector3) + (c2[1] as Vector3) * 0.03]
		for i in pts.size() - 1:
			k.tube(pts[i], pts[i + 1], 0.035, 6, LowPolyPalette.BLACK)
	# A vent grille under the rear belly, between the thighs: a dark panel with three grey slats across it, on the keel's
	# flat bottom (162-198 degrees), where the thigh pods pass beside it, and ending ahead of z 0.7, where they swing in
	# behind the pelvis.
	_torso_plate(k, 0.34, 0.68, 162.0, 198.0, 0.02, LowPolyPalette.DARK)
	for z: float in [0.41, 0.5, 0.59]:
		_torso_plate(k, z, z + 0.045, 165.0, 195.0, 0.045, LowPolyPalette.GREY)
	# The back-mount saddle on the rear deck (MOUNTS["back"]): a dark pad, two steel rails, four bolts.
	_torso_plate(k, 0.52, 0.86, -26.0, 26.0, 0.03, LowPolyPalette.DARK)
	_torso_plate(k, 0.55, 0.83, 9.0, 16.0, 0.065, LowPolyPalette.STEEL)
	_torso_plate(k, 0.55, 0.83, -16.0, -9.0, 0.065, LowPolyPalette.STEEL)
	for z: float in [0.57, 0.81]:
		for a: float in [-21.0, 21.0]:
			_torso_box(k, z, a, 0.04, Vector3(0.06, 0.06, 0.05), LowPolyPalette.STEEL)
	_hardpoint_pads(k, pad)


## The torso with another arm-pad style (ARM_PAD's keys; the style grid in docs/design/hardpoints/ renders these).
static func build_torso(pad: Dictionary) -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = LowPolyPalette.ORANGE
	_torso(k, pad)
	return k.commit(LowPolyMaterials.materials())


## Only the hull volume grown for the hardpoints (arm pads, shoulder shelves, back plinth): the tests check the legs and
## the pivoting weapons against it.
static func hardpoint_pads(pad: Dictionary = ARM_PAD) -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = LowPolyPalette.ORANGE
	_hardpoint_pads(k, pad)
	return k.commit(LowPolyMaterials.materials())


# --- Hardpoint mounting surfaces --------------------------------------------------------------------------
# docs/design/hardpoints/hardpoints_before_after.png. The torso grows a flat surface under every hardpoint so the mount hardware bolts on
# instead of hanging off the egg (the hardpoints themselves, MOUNTS / PYLON_TOP / SIDE_REACH, stay put: combat, the
# weapon pivots and the hit spheres use them):
#   arm pads        a sponson out of each lower flank with a flat outer pad the side mount's disc sinks 1 cm into; its
#                   underside slopes up into the keel (room for the thighs) and its back stays ahead of where a weapon's
#                   rear swings in at full pivot
#   shoulder shelves  a flat ledge under each pylon's base plate, filling the shoulder's slope above the shoulder pod
#   back plinth     a raised deck under the back items' base plate where the rear deck falls away toward the tail

## The arm pad style: "shape" box (squared, a short flat underside before the chin) | wedge (chamfered, the underside one
## slope up into the keel) | boss (round sections), "size" the pad face's half width and how far it rises above the disc
## centre, "flare" how much further back the inner sections reach (a fairing into the flank, behind where a pivoting
## weapon's receiver swings in), "flare_fwd" the same forward (wedge only) (the disc is 0.232 round; the face always ends 0.21 below the centre, where a strafing thigh passes just under
## it, so the disc's rim shows 2 cm below the pad there).
const ARM_PAD := {"shape": "wedge", "size": 0.35, "flare": 0.12, "flare_fwd": 0.1}
## Where the pad's root section sits, buried in the flank (x); where its chin section sits, and how high the underside
## is there and at the root: the thighs swing out sideways under the pad when strafing (test_torso_clearance), so the
## underside climbs steeply from the face into the keel.
const ARM_PAD_ROOT := Vector2(0.4, 0.55)
const ARM_PAD_CHIN := Vector2(0.66, 0.5)
## The pad sits this much ahead of the disc: a weapon's receiver swings in behind the disc at full yaw.
const ARM_PAD_AFT := 0.025

static func _hardpoint_pads(k: MeshKit, pad: Dictionary) -> void:
	for side: float in [-1.0, 1.0]:
		_arm_pad(k, side, pad)
		_shoulder_shelf(k, side)
	_back_plinth(k)


## A section across X at `x`: a rectangle z0..z1 by y0..y1 with its corners cut by `ch` (8 points), or with `round`
## an n-gon inscribed in it.
static func _pad_ring(x: float, z0: float, z1: float, y0: float, y1: float, ch: float, round: int = 0) -> PackedVector3Array:
	if round > 0:
		return MeshKit.ring_uv(Vector3(x, (y0 + y1) * 0.5, (z0 + z1) * 0.5), Vector3(0, 0, (z1 - z0) * 0.5), Vector3(0, (y1 - y0) * 0.5, 0), round)
	var out := PackedVector3Array()
	for p: Vector2 in [Vector2(z0 + ch, y1), Vector2(z1 - ch, y1), Vector2(z1, y1 - ch), Vector2(z1, y0 + ch), Vector2(z1 - ch, y0),
			Vector2(z0 + ch, y0), Vector2(z0, y0 + ch), Vector2(z0, y1 - ch)]:
		out.append(Vector3(x, p.y, p.x))
	return out


static func _pad_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.8:
		return LowPolyPalette.GREY          # the flat underside, like the belly (the steep chin stays hull white, so the pad reads as hull
		                     # against the dark keel)
	if n.y > 0.6:
		return LowPolyPalette.ORANGE        # the top, an accent block like the shoulder plates
	return LowPolyPalette.WHITE


## The arm pad on one side (+1 right): sections from the flat face (where the side mount's disc back face, at the mount
## minus SIDE_REACH minus 0.06, sinks 1 cm in) inward to a root buried in the flank.
static func _arm_pad(k: MeshKit, side: float, pad: Dictionary) -> void:
	var m: Vector3 = (MOUNTS["side_r"] as Vector3) - SIDE_REACH
	var x0 := m.x - 0.05
	var h := float(pad.get("size", 0.29))
	var shape := str(pad.get("shape", "wedge"))
	var cz := m.z
	var cy := m.y
	var yb := cy - 0.21
	var yt := cy + h
	var rx := ARM_PAD_ROOT.x
	var ry := ARM_PAD_ROOT.y
	var chx := ARM_PAD_CHIN.x
	var chy := ARM_PAD_CHIN.y
	var secs: Array = []   # [x, half z ahead, half z behind, y0, y1, chamfer]
	var rnd := 0
	var back := float(pad.get("flare", 0.12))   # how much further the inner sections reach back (a fairing into the flank)
	var fwd := float(pad.get("flare_fwd", 0.0))   # and forward (wedge only)
	match shape:
		"box":
			secs = [[x0, h, h, yb, yt, 0.04], [x0 - 0.04, h + 0.03, h + 0.03, yb + 0.03, yt + 0.03, 0.05],
				[x0 - 0.08, h + 0.03, h + 0.03, yb + 0.06, yt + 0.03, 0.05], [chx - 0.02, h + 0.06, h + 0.06 + back, chy, yt + 0.1, 0.06],
				[rx, h + 0.1, h + 0.1 + back * 1.6, ry, yt + 0.24, 0.06]]
		"boss":
			rnd = 10
			secs = [[x0, h, h, yb, yt, 0.0], [x0 - 0.04, h + 0.035, h + 0.035, yb + 0.03, yt + 0.035, 0.0],
				[chx, h + 0.07, h + 0.07 + back, chy, yt + 0.1, 0.0], [rx, h + 0.12, h + 0.12 + back * 1.6, ry, yt + 0.24, 0.0]]
		_:
			secs = [[x0, h, h, yb, yt, 0.09], [x0 - 0.04, h + 0.03, h + 0.03, yb + 0.03, yt + 0.03, 0.1],
				[chx, h + 0.06 + fwd, h + 0.06 + back, chy, yt + 0.1, 0.12], [rx, h + 0.12 + fwd * 1.6, h + 0.12 + back * 1.6, ry, yt + 0.26, 0.15]]
	var rings: Array = []
	for s: Array in secs:
		var r := _pad_ring(float(s[0]), cz - ARM_PAD_AFT - float(s[1]), cz - ARM_PAD_AFT + float(s[2]), s[3], s[4], s[5], rnd)
		for i in r.size():
			r[i] = r[i] * Vector3(side, 1, 1)
		rings.append(r)
	# The bevel band round the face dark (a panel line framing the pad), the body white / orange top / grey underside.
	var cols: Array = [LowPolyPalette.DARK]
	for i in rings.size() - 2:
		cols.append(_pad_colour)
	k.loft(rings, cols, false, true)
	k.poly(rings[0], LowPolyPalette.GREY, MeshKit.centroid(rings[1]))
	# Four steel bolts in the face's corners, outside the disc.
	var bolts := [Vector3(0, yt - 0.06, h - 0.06), Vector3(0, yb + 0.08, h - 0.06)]
	if shape == "boss":
		bolts = [Vector3(0, cy + (h - 0.05) * 0.68, (h - 0.05) * 0.72), Vector3(0, cy - 0.17, (h - 0.05) * 0.72)]
	for bp: Vector3 in bolts:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.02, 0.05, 0.05), LowPolyPalette.STEEL, Vector3(side * (x0 + 0.005), bp.y, cz + sz * bp.z))


## The ledge under a shoulder pylon's base plate (base at the shoulder mount minus PYLON_TOP; its 0.3 x 0.34 plate's
## underside at -0.05 sinks 1 cm into the ledge's top): a flat chamfered top a little larger than the plate, its outer
## face sloping in and down into the flank above the shoulder pod.
static func _shoulder_shelf(k: MeshKit, side: float) -> void:
	var b: Vector3 = (MOUNTS["shoulder_r"] as Vector3) - PYLON_TOP
	var top := b.y - 0.04
	var rings: Array = []
	for s: Array in [[top, 0.185, 0.205, 0.035], [top - 0.04, 0.2, 0.22, 0.04], [b.y - 0.36, 0.06, 0.205, 0.04]]:
		# [y, outer half x, half z, chamfer]; the inner half stays 0.2 (buried under the shoulder's dome).
		var r := PackedVector3Array()
		var y: float = s[0]
		var xo: float = s[1]
		var hz: float = s[2]
		var ch: float = s[3]
		for p: Vector2 in [Vector2(-0.2 + ch, -hz), Vector2(xo - ch, -hz), Vector2(xo, -hz + ch), Vector2(xo, hz - ch), Vector2(xo - ch, hz),
				Vector2(-0.2 + ch, hz), Vector2(-0.2, hz - ch), Vector2(-0.2, -hz + ch)]:
			r.append(Vector3(side * (b.x + p.x), y, b.z + p.y))
		rings.append(r)
	k.loft(rings, [LowPolyPalette.GREY, _shelf_colour])


static func _shelf_colour(_c: Vector3, n: Vector3) -> Color:
	return LowPolyPalette.GREY if n.y > 0.6 else LowPolyPalette.WHITE


## The plinth under the back items (MOUNTS["back"]; the equipment base plate's underside is at -0.04, the mortar's at
## -0.06): a flat dark top 0.5 cm under the plate from the deck back to the tail, a chamfered rear edge and a face sloping
## forward into the tail cap, white sides with an accent stripe, two steel rails on top.
static func _back_plinth(k: MeshKit) -> void:
	var mb: Vector3 = MOUNTS["back"]
	var top := mb.y - 0.045
	var prof := [Vector2(-0.12, top), Vector2(0.25, top), Vector2(0.28, top - 0.035), Vector2(0.21, top - 0.45), Vector2(-0.12, top - 0.1)]
	var rings: Array = []
	for sx: float in [-1.0, 1.0]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(sx * 0.27, p.y, mb.z + p.x))
		rings.append(r)
	k.loft(rings, _plinth_colour)
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.015, 0.3), LowPolyPalette.STEEL, Vector3(sx * 0.12, top + 0.003, mb.z + 0.09))
		k.box(Vector3(0.012, 0.05, 0.22), LowPolyPalette.ORANGE, Vector3(sx * 0.274, top - 0.07, mb.z + 0.1))


static func _plinth_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.9:
		return LowPolyPalette.DARK
	if n.z > 0.3:
		return LowPolyPalette.GREY
	return LowPolyPalette.WHITE


## The nose under the hatch: a snout with the sensor port (bezel, bolts, visor hood) and framed lights. Origin on the
## torso's front face.
static func _nose(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.1), 0.44, 0.3, 8, "z", 3.0), MeshKit.ring(Vector3(0, -0.04, -0.2), 0.36, 0.24, 8, "z", 3.0),
		MeshKit.ring(Vector3(0, -0.07, -0.34), 0.24, 0.16, 8, "z", 3.0)], [LowPolyPalette.GREY, LowPolyPalette.WHITE], false, true)
	k.tube(Vector3(0, -0.06, -0.3), Vector3(0, -0.06, -0.4), 0.15, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0, -0.06, -0.4), Vector3(0, -0.06, -0.44), 0.09, 8, LowPolyPalette.GUN)
	k.glow = true
	k.tube(Vector3(0, -0.06, -0.44), Vector3(0, -0.06, -0.46), 0.045, 6, LowPolyPalette.AMBER)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.05, 0.04), LowPolyPalette.AMBER, Vector3(side * 0.2, -0.24, -0.26))
	k.glow = false
	k.box(Vector3(0.6, 0.09, 0.2), LowPolyPalette.DARK, Vector3(0, -0.25, -0.16))
	# A grey bezel round the sensor with six bolts, a visor hood, a steel inner ring.
	k.tube(Vector3(0, -0.06, -0.33), Vector3(0, -0.06, -0.375), 0.19, 8, LowPolyPalette.GREY)
	for i in 6:
		var a := TAU * (float(i) + 0.5) / 6.0
		k.box(Vector3(0.045, 0.045, 0.03), LowPolyPalette.STEEL, Vector3(sin(a) * 0.17, -0.06 + cos(a) * 0.17, -0.385))
	k.box(Vector3(0.36, 0.045, 0.13), LowPolyPalette.DARK, Vector3(0, 0.115, -0.385))
	k.tube(Vector3(0, -0.06, -0.435), Vector3(0, -0.06, -0.448), 0.068, 8, LowPolyPalette.STEEL)
	# Dark frames round the amber lights, a grille of two grey slats between them on the chin.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.14, 0.085, 0.03), LowPolyPalette.DARK, Vector3(side * 0.2, -0.24, -0.255))
	for y: float in [-0.228, -0.268]:
		k.box(Vector3(0.2, 0.025, 0.03), LowPolyPalette.GREY, Vector3(0, y, -0.265))
	# White cheek plates on the snout's sides, a steel bolt on each.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 0.39, -0.03, -0.1), Vector3(0, side * -15.0, 0)))
		k.box(Vector3(0.035, 0.2, 0.2), LowPolyPalette.WHITE)
		k.box(Vector3(0.03, 0.045, 0.045), LowPolyPalette.STEEL, Vector3(side * 0.025, 0.04, 0.0))
		k.pop()


## The hatch collar the pilot's neck comes out of, with its bolted band, rim bolts and lid hinge. Origin at the centre
## of the opening.
static func _hatch(k: MeshKit) -> void:
	var n := 10
	k.lathe([Vector2(0.53, -0.1), Vector2(0.51, 0.05), Vector2(0.46, 0.1)], n, [LowPolyPalette.GREY, LowPolyPalette.WHITE], false, false)
	var rim_o := MeshKit.ring(Vector3(0, 0.1, 0), 0.46, 0.46, n)
	var rim_i := MeshKit.ring(Vector3(0, 0.1, 0), 0.4, 0.4, n)
	for i in n:
		var i2 := (i + 1) % n
		k.quad(rim_o[i], rim_o[i2], rim_i[i2], rim_i[i], LowPolyPalette.DARK, Vector3(0, -1, 0))
	k.lathe([Vector2(0.4, 0.1), Vector2(0.4, -0.04)], n, LowPolyPalette.BLACK, false, false, true)
	k.poly(MeshKit.ring(Vector3(0, -0.04, 0), 0.4, 0.4, n), LowPolyPalette.BLACK, Vector3(0, -5, 0))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.12, 0.1, 0.12), LowPolyPalette.DARK, Vector3(side * 0.2, 0.08, 0.5))
	# A dark band round the collar wall with five steel bolts on it.
	k.lathe([Vector2(0.545, -0.085), Vector2(0.54, -0.02)], n, LowPolyPalette.DARK)
	for i in 5:
		var a := TAU * (float(i * 2) + 1.0) / float(n) + PI / float(n)
		var dir := Vector3(sin(a), 0, -cos(a))
		if dir.z > 0.8:
			continue   # the hinge sits at the back
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.545 + Vector3(0, -0.052, 0)))
		k.box(Vector3(0.055, 0.055, 0.04), LowPolyPalette.STEEL)
		k.pop()
	# Eight bolts on the rim (sunk 1.5 cm, so the rim's own faces stay the only ones at y = 0.1).
	for i in 8:
		var a := TAU * (float(i) + 0.5) / 8.0
		k.box(Vector3(0.045, 0.04, 0.045), LowPolyPalette.STEEL, Vector3(sin(a) * 0.43, 0.105, -cos(a) * 0.43))
	# The lid hinge: a steel barrel between the blocks and a dark knuckle in its middle.
	k.tube(Vector3(-0.15, 0.08, 0.5), Vector3(0.15, 0.08, 0.5), 0.04, 6, LowPolyPalette.STEEL)
	k.tube(Vector3(-0.05, 0.08, 0.5), Vector3(0.05, 0.08, 0.5), 0.058, 6, LowPolyPalette.DARK)
	# Two orange tabs on the front of the collar.
	for side: float in [-1.0, 1.0]:
		var dir := Vector3(side * 0.6, 0, -0.8)
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.52 + Vector3(0, 0.0, 0)))
		k.box(Vector3(0.13, 0.07, 0.04), LowPolyPalette.ORANGE)
		k.pop()


static func _back_plate_colour(c: Vector3, n: Vector3) -> Color:
	if n.z > 0.5:
		return LowPolyPalette.GREY
	return LowPolyPalette.ORANGE if c.y < 0.16 and n.z < -0.5 else LowPolyPalette.WHITE


## The armoured plate behind the pilot: ribs and a vent panel on the back, edge plates and a light on the front. Origin
## at its base.
static func _back_plate(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, -0.1, 0), 0.38, 0.09, 4, "y", MeshKit.SQUARE), MeshKit.ring(Vector3(0, 0.62, 0), 0.36, 0.08, 4, "y", MeshKit.SQUARE),
		MeshKit.ring(Vector3(0, 0.98, 0.02), 0.22, 0.07, 4, "y", MeshKit.SQUARE)], _back_plate_colour)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.08, 0.7, 0.08), LowPolyPalette.DARK, Vector3(side * 0.2, 0.3, 0.1))
		k.tube(Vector3(side * 0.24, 0.5, -0.08), Vector3(side * 0.24, 0.5, -0.11), 0.04, 6, LowPolyPalette.DARK)
	k.glow = true
	k.box(Vector3(0.14, 0.07, 0.04), LowPolyPalette.AMBER, Vector3(0.14, 0.74, -0.09))
	k.glow = false
	k.box(Vector3(0.2, 0.12, 0.03), LowPolyPalette.DARK, Vector3(0.14, 0.74, -0.075))
	# A dark vent panel between the ribs with four grey slats.
	k.box(Vector3(0.3, 0.42, 0.03), LowPolyPalette.DARK, Vector3(0, 0.34, 0.095))
	for i in 4:
		k.box(Vector3(0.26, 0.045, 0.035), LowPolyPalette.GREY, Vector3(0, 0.19 + float(i) * 0.1, 0.11))
	# Steel bolts at both ends of each rib.
	for side: float in [-1.0, 1.0]:
		for y: float in [0.0, 0.6]:
			k.box(Vector3(0.05, 0.05, 0.04), LowPolyPalette.STEEL, Vector3(side * 0.2, y, 0.145))
	# White stepped edge plates on the front.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.26, 0.035), LowPolyPalette.WHITE, Vector3(side * 0.27, 0.31, -0.095))
	# A hood over the light and a round port opposite it.
	k.box(Vector3(0.22, 0.035, 0.07), LowPolyPalette.DARK, Vector3(0.14, 0.815, -0.11))
	k.tube(Vector3(-0.13, 0.74, -0.07), Vector3(-0.13, 0.74, -0.115), 0.065, 8, LowPolyPalette.DARK)
	k.tube(Vector3(-0.13, 0.74, -0.115), Vector3(-0.13, 0.74, -0.125), 0.035, 6, LowPolyPalette.GUN)
	# An orange tag high on the back and a steel cap on the top edge.
	k.box(Vector3(0.22, 0.09, 0.03), LowPolyPalette.ORANGE, Vector3(0, 0.79, 0.095))
	k.box(Vector3(0.4, 0.045, 0.16), LowPolyPalette.STEEL, Vector3(0, 0.98, 0.02))


## The hip block under the torso, with the axle the legs hang from, skirt plates and rear pistons.
static func _pelvis(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.26, 0.02), 0.52, 0.56, 8, "y", 3.0), MeshKit.ring(Vector3(0, 0.0, 0.02), 0.42, 0.46, 8, "y", 3.0),
		MeshKit.ring(Vector3(0, -0.24, 0.02), 0.26, 0.3, 8, "y", 3.0)], [LowPolyPalette.GREY, LowPolyPalette.DARK])
	k.tube(Vector3(-0.45, -0.1, 0), Vector3(0.45, -0.1, 0), 0.12, 8, LowPolyPalette.DARK)
	# Skirt plates on the lower slopes, front and back, with a tag on each (orange on the front one).
	for f: float in [-1.0, 1.0]:   # -1 = front (-Z)
		var a := Vector3(0, 0.0, 0.02 + f * 0.46)
		var b := Vector3(0, -0.24, 0.02 + f * 0.3)
		var nrm := Vector3(0, -0.16, f * 0.24).normalized()
		var at := (a + b) * 0.5 + nrm * 0.012
		k.push(Transform3D(Basis.looking_at(nrm, Vector3.UP), at))
		k.box(Vector3(0.36, 0.22, 0.035), LowPolyPalette.GREY)
		k.box(Vector3(0.14, 0.07, 0.03), LowPolyPalette.ORANGE if f < 0.0 else LowPolyPalette.STEEL, Vector3(0, -0.02, -0.025))
		k.pop()
	# Steel axle collars where the axle leaves the block.
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.32, -0.1, 0), Vector3(side * 0.39, -0.1, 0), 0.155, 8, LowPolyPalette.STEEL)
	# Two hydraulic pistons down the back, kept close to the centre line: the flipped legs bring the thigh pods' inner
	# faces to about 0.18 from it behind the block mid-stride.
	for side: float in [-1.0, 1.0]:
		var top := Vector3(side * 0.1, 0.02, 0.53)
		var bot := Vector3(side * 0.075, -0.2, 0.39)
		k.tube(top, top.lerp(bot, 0.55), 0.045, 6, LowPolyPalette.DARK)
		k.tube(top.lerp(bot, 0.5), bot, 0.028, 6, LowPolyPalette.STEEL)


## A raised weapon pylon (right side). Origin at its base on the torso; the weapon mounts at PYLON_TOP.
static func _shoulder_pylon(k: MeshKit) -> void:
	k.box(Vector3(0.3, 0.14, 0.34), LowPolyPalette.DARK, Vector3(0, 0.02, 0))
	k.seg(Vector3(0, 0.05, 0.03), Vector3(0.1, 0.6, 0.0), Vector2(0.09, 0.12), Vector2(0.075, 0.1), 4, LowPolyPalette.GREY, MeshKit.SQUARE)
	k.tube(Vector3(0.06, 0.3, 0.13), Vector3(0.1, 0.58, 0.1), 0.035, 6, LowPolyPalette.STEEL)
	k.tube(Vector3(-0.04, 0.62, 0), Vector3(0.24, 0.62, 0), 0.13, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0.24, 0.62, 0), Vector3(0.27, 0.62, 0), 0.07, 8, LowPolyPalette.GREY)
	k.box(Vector3(0.22, 0.07, 0.3), LowPolyPalette.GREY, PYLON_TOP - Vector3(0, 0.05, 0))
	# Four bolts on the base.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.045, 0.04, 0.045), LowPolyPalette.STEEL, Vector3(sx * 0.105, 0.095, sz * 0.125))
	# An orange plate on the post's front face.
	var d := Vector3(0.1, 0.55, -0.03).normalized()
	var x := d.cross(Vector3.BACK).normalized()
	var z := x.cross(d).normalized()
	k.push(Transform3D(Basis(x, d, z), Vector3(0.05, 0.31, 0.015)))
	k.box(Vector3(0.13, 0.3, 0.035), LowPolyPalette.ORANGE, Vector3(0, 0, -0.118))
	k.pop()
	# The pivot hub: a steel step ring with four bolts round the grey cap.
	k.tube(Vector3(0.235, 0.62, 0), Vector3(0.258, 0.62, 0), 0.108, 8, LowPolyPalette.STEEL)
	k.push(MeshKit.xf(Vector3(0, 0.62, 0)))
	k.bolt_ring(0.258, 0.09, 0.032, 4, 45.0, LowPolyPalette.STEEL)
	k.pop()
	# Mounting rails along the top plate and a clamp across each end.
	var top := PYLON_TOP
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.03, 0.28), LowPolyPalette.STEEL, top + Vector3(sx * 0.06, -0.005, 0))
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.26, 0.055, 0.05), LowPolyPalette.DARK, top + Vector3(0, -0.03, sz * 0.125))
	# An ammo feed stub on the outer side under the plate, a cable up the inner back edge of the post.
	k.box(Vector3(0.07, 0.08, 0.13), LowPolyPalette.DARK, Vector3(0.22, 0.71, 0.07))
	var hose := [Vector3(-0.085, 0.08, 0.14), Vector3(-0.05, 0.35, 0.15), Vector3(-0.01, 0.56, 0.12)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.028, 6, LowPolyPalette.BLACK)


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
		k.tri((tri[0] as Vector3) * scl, (tri[1] as Vector3) * scl, (tri[2] as Vector3) * scl, LowPolyPalette.ORANGE, Vector3.ZERO)
	# The outer pivot hub: a dark disc, a steel cap, four bolts.
	var ox := POD_R.x * a_max.x
	k.tube(Vector3(ox - 0.06, 0, 0), Vector3(ox + 0.025, 0, 0), 0.13, 8, LowPolyPalette.DARK)
	k.tube(Vector3(ox + 0.015, 0, 0), Vector3(ox + 0.05, 0, 0), 0.065, 6, LowPolyPalette.STEEL)
	k.bolt_ring(ox + 0.025, 0.1, 0.035, 4, 45.0, LowPolyPalette.STEEL)


## A side hardpoint (right side). Origin on the torso's flank; the weapon mounts at SIDE_REACH.
static func _side_mount(k: MeshKit) -> void:
	var reach := SIDE_REACH
	k.tube(Vector3(-0.06, 0, 0), Vector3(0.08, 0, 0), 0.22, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0.08, 0, 0), Vector3(0.12, 0, 0), 0.13, 8, LowPolyPalette.GREY)
	k.seg(Vector3(0.1, 0, 0), reach, Vector2(0.07, 0.08), Vector2(0.06, 0.07), 4, LowPolyPalette.GREY, MeshKit.SQUARE)
	k.box(Vector3(0.1, 0.16, 0.2), LowPolyPalette.DARK, reach)
	# An orange band round the disc's rim, a steel step ring on its face with six bolts.
	k.tube(Vector3(-0.025, 0, 0), Vector3(0.035, 0, 0), 0.232, 8, LowPolyPalette.ORANGE)
	k.tube(Vector3(0.07, 0, 0), Vector3(0.1, 0, 0), 0.185, 8, LowPolyPalette.STEEL)
	k.bolt_ring(0.1, 0.158, 0.036, 6, 30.0, LowPolyPalette.STEEL)
	# Steel clamp jaws on both sides of the mount block, a pivot pin through its top, an orange clamp plate under it.
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.085, 0.12, 0.035), LowPolyPalette.STEEL, reach + Vector3(0, 0, sz * 0.115))
	k.tube(reach + Vector3(0, 0.0, 0), reach + Vector3(0, 0.11, 0), 0.045, 6, LowPolyPalette.STEEL)
	k.box(Vector3(0.14, 0.035, 0.17), LowPolyPalette.ORANGE, reach + Vector3(-0.01, -0.095, 0))
	# A cable from the disc to the block.
	var hose := [Vector3(0.06, -0.15, 0.13), Vector3(0.18, -0.08, 0.1), Vector3(0.28, -0.05, 0.08)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.026, 6, LowPolyPalette.BLACK)


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
		return LowPolyPalette.GREY
	if n.x < -0.75:
		return LowPolyPalette.GREY                         # the inner face
	if n.x > 0.6 and c.y < -0.3333 * l and c.z > 0.0:
		return LowPolyPalette.ORANGE                       # the unit mark on the outer face
	return LowPolyPalette.WHITE


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
	_thigh_plate(k, rings, 1.0, 3.0, 2, [-0.2778 * l, -0.4444 * l, -0.6444 * l, -0.8333 * l], 0.032, LowPolyPalette.WHITE)
	# The unit plate, bolts, panel line and vents keep their drawn size (scaled only with the pod's fullness) and sit at
	# the same share of the length.
	var w := _thigh_full()
	var mid := -0.4889 * l
	_thigh_plate(k, rings, 1.45, 2.85, 2, _thigh_rows(mid, 0.12 * w), 0.058, LowPolyPalette.ORANGE)
	# Two bolts on the plate's front edge.
	for d: float in [0.135, -0.165]:
		var sp := _thigh_at(rings, mid + d * w, 1.17)
		var p: Vector3 = sp[0]
		var n: Vector3 = sp[1]
		k.tube(p + n * 0.02, p + n * 0.058, 0.032, 6, LowPolyPalette.STEEL)
	# A raised panel line across the front.
	_thigh_plate(k, rings, 8.0, 11.0, 3, [mid, mid - 0.036], 0.022, LowPolyPalette.DARK)
	# Three vent slats on the back.
	var vent := -0.5444 * l
	for d: float in [0.06, 0.0, -0.06]:
		var vy := vent + d * w
		_thigh_plate(k, rings, 4.0, 5.0, 1, [vy, vy - 0.032], 0.026, LowPolyPalette.DARK)


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
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.14, 0.16), Vector2(0.11, 0.13), 4, LowPolyPalette.GREY, MeshKit.SQUARE)
	for i in 5:
		k.box(Vector3(0.32, 0.075, 0.07), LowPolyPalette.DARK, Vector3(0, -(0.1818 + float(i) * 0.1182) * l, -0.165 + float(i) * 0.006))
	var top := -0.1091 * l
	var bot := -l + 0.1
	var pa := Vector3(0, top, 0.26)
	var pb := Vector3(0, -0.4545 * l, 0.23)
	k.tube(pa, pb, 0.075, 6, LowPolyPalette.DARK)
	k.tube(pb, Vector3(0, bot, 0.2), 0.045, 6, LowPolyPalette.STEEL)
	for y: float in [top, bot]:
		k.box(Vector3(0.14, 0.11, 0.18), LowPolyPalette.DARK, Vector3(0, y, 0.17))
	# Steel rails framing the tread.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.6 * l, 0.06), LowPolyPalette.STEEL, Vector3(side * 0.177, -0.4182 * l, -0.16))
	# An orange band on the piston's cylinder.
	k.tube(pa.lerp(pb, 0.72), pa.lerp(pb, 0.9), 0.088, 6, LowPolyPalette.ORANGE)
	# Clevis pins through the piston's end blocks.
	for y: float in [top, bot]:
		k.tube(Vector3(-0.1, y, 0.19), Vector3(0.1, y, 0.19), 0.036, 6, LowPolyPalette.STEEL)
	# A hydraulic hose down the outer side, from the knee block to the ankle block.
	var hose := [Vector3(0.08, -0.0727 * l, 0.2), Vector3(0.175, -0.2545 * l, 0.07), Vector3(0.165, -0.7455 * l, 0.05),
		Vector3(0.08, -l + 0.12, 0.17)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.026, 6, LowPolyPalette.BLACK)


## The tarsus: ankle (origin) forward down to the foot.
static func _tarsus(k: MeshKit) -> void:
	var l: float = REST_LENGTH["tarsus"]
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.1, 0.12), Vector2(0.12, 0.13), 4, LowPolyPalette.DARK, MeshKit.SQUARE)
	var y0 := -0.2545 * l
	var y1 := -l + 0.04
	k.seg(Vector3(0, y0, -0.13), Vector3(0, y1, -0.15), Vector2(0.14, 0.04), Vector2(0.16, 0.05), 4, LowPolyPalette.STEEL, MeshKit.SQUARE)
	var ra := Vector3(0, -0.1455 * l, 0.16)
	var rb := Vector3(0, -l + 0.08, 0.17)
	k.tube(ra, rb, 0.04, 5, LowPolyPalette.GREY)
	# Two tread ribs across the front plate (centred on its front face), a clamp on the rear line, an orange tag on the
	# outer side.
	for f: float in [0.4545, 0.6909]:
		var t := (y0 + f * l) / (y0 - y1)
		k.box(Vector3(0.3, 0.05, 0.04), LowPolyPalette.DARK, Vector3(0, -f * l, lerpf(-0.17, -0.2, t)))
	k.tube(ra.lerp(rb, 0.4), ra.lerp(rb, 0.55), 0.064, 6, LowPolyPalette.DARK)
	k.box(Vector3(0.03, 0.13, 0.1), LowPolyPalette.ORANGE, Vector3(0.122, -0.5455 * l, 0.01))


## The hip ball: a faceted sphere centred on the pivot.
const HIP_BALL := 0.3


static func _hip_ball(k: MeshKit) -> void:
	var profile: Array = []
	for i in 6:
		var a := PI * float(i) / 5.0
		profile.append(Vector2(sin(a) * HIP_BALL, cos(a) * HIP_BALL))
	profile.reverse()
	k.lathe(profile, 8, [LowPolyPalette.STEEL, LowPolyPalette.STEEL, LowPolyPalette.WHITE, LowPolyPalette.STEEL, LowPolyPalette.STEEL], false, false)
	# The outer hub (+X): a dark disc sunk into the ball, a steel cap and four bolts. It stays below the socket's rim
	# (y < 0.1) so the ball still swivels inside the cup.
	k.tube(Vector3(0.24, 0, 0), Vector3(0.312, 0, 0), 0.1, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0.3, 0, 0), Vector3(0.336, 0, 0), 0.052, 6, LowPolyPalette.STEEL)
	k.bolt_ring(0.312, 0.078, 0.03, 4, 0.0, LowPolyPalette.STEEL)


## The hip socket (right side): a cup over the top of the ball, and the strut that carries it into the pelvis.
static func _hip_socket(k: MeshKit) -> void:
	k.lathe([Vector2(0.37, 0.1), Vector2(0.35, 0.19), Vector2(0.27, 0.31), Vector2(0.13, 0.39)], 8, [LowPolyPalette.GREY, LowPolyPalette.DARK, LowPolyPalette.DARK], true, true)
	k.seg(Vector3(-0.12, 0.3, 0), Vector3(-0.78, 0.44, 0), Vector2(0.12, 0.17), Vector2(0.15, 0.22), 4, LowPolyPalette.DARK, MeshKit.SQUARE)
	k.tube(Vector3(0, 0.39, 0), Vector3(0, 0.44, 0), 0.08, 6, LowPolyPalette.GREY)
	# A steel ring round the cup's shoulder and four bolts on the rim (the strut is buried in the pelvis).
	k.lathe([Vector2(0.362, 0.2), Vector2(0.338, 0.25)], 8, LowPolyPalette.STEEL)
	for a: float in [0.0, 90.0, 180.0, 270.0]:
		var dir := Vector3(sin(deg_to_rad(a)), 0, -cos(deg_to_rad(a)))
		if dir.x < -0.5:
			dir = Vector3(-0.7, 0, -0.7).normalized()   # the strut covers the inner side: put that bolt front-inner
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.37 + Vector3(0, 0.145, 0)))
		k.box(Vector3(0.05, 0.05, 0.05), LowPolyPalette.STEEL)
		k.pop()


## The hub of the foot: the ankle socket the toes and spur hang from. Origin on the ground under the tarsus.
static func strider_foot(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.0), 0.3, 0.31, 6, "y"), MeshKit.ring(Vector3(0, 0.18, 0.0), 0.26, 0.27, 6, "y"),
		MeshKit.ring(Vector3(0, 0.33, 0.0), 0.15, 0.16, 6, "y")], [LowPolyPalette.GREY, LowPolyPalette.DARK])
	# A steel band round the waist and a steel collar on top (same hexagon as the hub).
	k.loft([MeshKit.ring(Vector3(0, 0.15, 0.0), 0.282, 0.292, 6, "y"), MeshKit.ring(Vector3(0, 0.205, 0.0), 0.272, 0.282, 6, "y")], LowPolyPalette.STEEL)
	k.loft([MeshKit.ring(Vector3(0, 0.3, 0.0), 0.19, 0.2, 6, "y"), MeshKit.ring(Vector3(0, 0.36, 0.0), 0.17, 0.18, 6, "y")], LowPolyPalette.STEEL)


## One toe: root at the origin, claw tip forward on the ground. Long and chunky, with two knuckle bands, a dark claw
## sheath and a dark pad under the root (each ring's lowest point, at the bottom of the pentagon, stays on y >= 0).
static func _toe(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.135, 0.06), 0.125, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.16, -0.32), 0.15, 0.155, 5, "z"),
		MeshKit.ring(Vector3(0, 0.14, -0.5), 0.13, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.1, -0.8), 0.1, 0.095, 5, "z"),
		MeshKit.ring(Vector3(0, 0.005, -1.12), 0.0, 0.0, 5, "z")], [LowPolyPalette.STEEL, LowPolyPalette.STEEL, LowPolyPalette.STEEL, LowPolyPalette.GREY])
	k.loft([MeshKit.ring(Vector3(0, 0.172, -0.3), 0.168, 0.168, 5, "z"), MeshKit.ring(Vector3(0, 0.17, -0.36), 0.166, 0.166, 5, "z")], LowPolyPalette.DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.136, -0.6), 0.134, 0.133, 5, "z"), MeshKit.ring(Vector3(0, 0.131, -0.65), 0.13, 0.129, 5, "z")], LowPolyPalette.DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.112, -0.78), 0.11, 0.108, 5, "z"), MeshKit.ring(Vector3(0, 0.01, -1.14), 0.0, 0.0, 5, "z")], LowPolyPalette.GUN)
	k.box(Vector3(0.15, 0.03, 0.26), LowPolyPalette.DARK, Vector3(0, 0.017, -0.12))


## The rear spur: root at the origin, pointing back and up, with a clamp block near the root and a dark collar at the bend.
static func strider_spur(k: MeshKit) -> void:
	k.seg(Vector3(0, 0.13, 0.0), Vector3(0, 0.22, 0.35), Vector2(0.1, 0.105), Vector2(0.087, 0.087), 4, LowPolyPalette.STEEL)
	k.seg(Vector3(0, 0.22, 0.35), Vector3(0, 0.6, 0.7), Vector2(0.087, 0.087), Vector2.ZERO, 4, LowPolyPalette.GREY)
	k.push(Transform3D(Basis(Vector3.RIGHT, -atan2(0.09, 0.35)), Vector3(0, 0.18, 0.2)))
	k.box(Vector3(0.23, 0.2, 0.07), LowPolyPalette.DARK)
	k.pop()
	var d := Vector3(0, 0.38, 0.35).normalized()
	k.seg(Vector3(0, 0.22, 0.35) - d * 0.03, Vector3(0, 0.22, 0.35) + d * 0.07, Vector2(0.125, 0.125), Vector2(0.12, 0.12), 4, LowPolyPalette.DARK)
