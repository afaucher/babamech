class_name BulwarkMeshes
extends RefCounted
## The Bulwark's low-poly parts (docs/design/chassis-rules.md; concept docs/design/chassis-concepts/pick_bulwark_concept.png,
## legs pick_bulwark_legs_sumo.png): a squat heavy biped. A barrel torso in the Strider's livery (white upper, orange band,
## grey belly, the nose with its lamp cluster, the round hatch the pilot's head comes out of, amber lights), widened and
## squashed, with a channel down the top front for the hatch; two side guns on Strider-style side mounts at the barrel's
## widest point; two back saddles side by side on raised plinths; sumo legs with forward knees (thick short thighs,
## big square orange knee pads, short shins, a short ankle block into a heavy boot with a split toe clamp and a heel spur).
##
## Same conventions and tools as MechMeshes (model units, faces -Z, +X its right; body parts in body space around their
## attach point, drawn at BODY_SCALE; leg segments hang along -Y from the proximal joint to REST_LENGTH; joint caps on the
## joint, axle along X; foot parts on the ground; right side authored, the left mirrored). Shared palette, materials
## (MechMeshes.materials) and helpers (MechMeshes._cap, _bolt_ring, _pad_ring). Weapons, equipment, the hatch and the
## pilot heads are the Strider's parts, named as-is (ChassisParts). Files: res://assets/models/mech/bulwark_<part>.res
## (tools/models/gen_mech_meshes.gd). Cosmetic only (no gameplay state).

const PREFIX := "bulwark_"
const BODY_PARTS := ["bulwark_torso", "bulwark_pelvis", "bulwark_nose", "bulwark_side_mount"]
const LEG_PARTS := ["bulwark_thigh", "bulwark_shin", "bulwark_ankle", "bulwark_hip_socket", "bulwark_hip_cap",
	"bulwark_knee_cap", "bulwark_ankle_cap", "bulwark_boot", "bulwark_toe", "bulwark_spur"]

## Leg segment lengths the meshes are authored at (the Bulwark's default leg params). The "tarsus" is the short ankle
## block between the ankle drum and the boot.
const REST_LENGTH := {"thigh": 0.66, "shin": 0.58, "tarsus": 0.22}
## Body parts and weapons are drawn this much larger than authored (the same as the Strider, so the shared weapons and the
## pilot keep their size).
const BODY_SCALE := 1.2

## Where body parts sit in body space (origin 0.1 above the hip line): [position, rotation (degrees)].
const LAYOUT := {
	"torso": [Vector3.ZERO, Vector3.ZERO],
	"pelvis": [Vector3.ZERO, Vector3.ZERO],
	"nose": [Vector3(0, 0.38, -0.96), Vector3.ZERO],
	"hatch": [Vector3(0, 0.75, -0.46), Vector3(-10, 0, 0)],
}
## Hardpoint mount points in body space (where a weapon's origin goes): the side guns at the barrel's widest point, the
## two back saddles side by side on the rear deck.
const MOUNTS := {
	"side_l": Vector3(-1.98, 0.55, -0.1), "side_r": Vector3(1.98, 0.55, -0.1),
	"back_l": Vector3(-0.6, 1.145, 0.42), "back_r": Vector3(0.6, 1.145, 0.42),
}
## From a side mount's base (its disc's back face sinks 1 cm into the side pad) to its mount point (right side).
const SIDE_REACH := Vector3(0.62, 0.0, 0.0)
## The side pad's flat face (x) and its half size round the mount's centre.
const SIDE_PAD_X := 1.31
const SIDE_PAD_H := 0.36
const SIDE_DISC := 0.3
## The back plinths' half width (x) round each back mount.
const PLINTH_HALF := 0.28

## Foot layout: the two toe clamps [root, yaw degrees] and the heel spur's root.
const TOES := [[Vector3(-0.155, 0, -0.32), 0.0], [Vector3(0.155, 0, -0.32), 0.0]]
const SPUR_ROOT := Vector3(0, 0, 0.28)

## The hip ball's radius and the socket cup's lathe profile [radius, y] (8 sides; test_torso_clearance_bulwark reads it).
## Ball and knee drum together (0.6) stay under the thigh's length (0.66), the knee and ankle drums under the shin's.
const HIP_BALL := 0.3
const CUP := [Vector2(0.39, 0.1), Vector2(0.37, 0.2), Vector2(0.29, 0.33), Vector2(0.15, 0.41)]
## Joint drums: [radius, half width, hub half length].
const KNEE_DRUM := Vector3(0.3, 0.28, 0.34)
const ANKLE_DRUM := Vector3(0.2, 0.2, 0.25)

static var _cache: Dictionary = {}


static func all_parts() -> Array[String]:
	var out: Array[String] = []
	out.append_array(BODY_PARTS)
	out.append_array(LEG_PARTS)
	return out


static func has_part(part: String) -> bool:
	return part in all_parts()


static func path(part: String) -> String:
	return MechMeshes.DIR + part + ".res"


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


static func instance(part: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = mesh(part)
	return mi


## Generate a part from scratch (the generator and the staleness test use this).
static func build(part: String) -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	match part:
		"bulwark_torso": _torso(k)
		"bulwark_pelvis": _pelvis(k)
		"bulwark_nose": _nose(k)
		"bulwark_side_mount": _side_mount(k)
		"bulwark_thigh": _thigh(k)
		"bulwark_shin": _shin(k)
		"bulwark_ankle": _ankle(k)
		"bulwark_hip_socket": _hip_socket(k)
		"bulwark_hip_cap": _hip_ball(k)
		"bulwark_knee_cap": _knee(k)
		"bulwark_ankle_cap": MechMeshes._cap(k, ANKLE_DRUM.x, ANKLE_DRUM.y, ANKLE_DRUM.z)
		"bulwark_boot": _boot(k)
		"bulwark_toe": _toe(k)
		"bulwark_spur": _spur(k)
	return k.commit(MechMeshes.materials())


## Only the hull volume grown for the hardpoints (side pads, back plinths): the tests check the legs, the pivoting
## weapons and the back items against it.
static func hardpoint_pads() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	_hardpoint_pads(k)
	return k.commit(MechMeshes.materials())


# --- Barrel torso ------------------------------------------------------------------------------------------

## Sections front to back: [z, half width, half height above the centre, below it, centre y, belly tuck, top notch].
## A wide squat barrel, widest at y ~0.55 (the side mounts). Below the waist the belly tucks into KEEL, a shallow flat
## underside at y ~0.17 everywhere over the hip circle: the forward-leaning thighs' upper backs rise ~0.15 above the
## hip line, and the hip twist swings them under the front and back of the barrel too, so the pelvis block (round, inside
## the hip circle) shows below the barrel instead of a deep belly. The front sections' top centre is notched
## down into a channel the hatch sits in, so the barrel's shoulders rise beside the pilot (the concept's cockpit recess)
## while the pilot's head stays low enough for a 7 m mech.
const TORSO := [
	[-0.97, 0.66, 0.24, 0.22, 0.50, 0.0, 0.0],
	[-0.89, 1.00, 0.38, 0.28, 0.51, 0.3, 0.17],
	[-0.70, 1.17, 0.48, 0.32, 0.52, 0.8, 0.29],
	[-0.40, 1.24, 0.54, 0.33, 0.52, 1.0, 0.31],
	[-0.05, 1.26, 0.56, 0.33, 0.52, 1.0, 0.14],
	[0.30, 1.24, 0.55, 0.33, 0.52, 1.0, 0.0],
	[0.60, 1.12, 0.48, 0.32, 0.51, 1.0, 0.0],
	[0.80, 0.86, 0.36, 0.28, 0.50, 0.5, 0.0],
	[0.89, 0.50, 0.20, 0.18, 0.49, 0.0, 0.0]]
const TORSO_SIDES := 16
const TORSO_POWER := 2.6
## The keel the belly tucks into, from the bottom up (one per facet step from straight down): [share of the half width
## out from the centre line, share of the belly depth below the centre].
const KEEL := [Vector2(0.3, 1.0), Vector2(0.62, 0.88), Vector2(0.85, 0.6), Vector2(0.98, 0.25)]


## One section ring (TORSO_SIDES points from up toward +X, MeshKit.ring's order).
static func _ring(s: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var e := 2.0 / TORSO_POWER
	var tuck: float = s[5]
	var notch: float = s[6]
	var step := TAU / float(TORSO_SIDES)
	for k in TORSO_SIDES:
		var a := TAU * (float(k) + 0.5) / float(TORSO_SIDES)
		var su := sin(a)
		var cv := cos(a)
		var ry: float = s[2] if cv > 0.0 else s[3]
		var p := Vector3(float(s[1]) * signf(su) * pow(absf(su), e), float(s[4]) + ry * signf(cv) * pow(absf(cv), e), s[0])
		if cv < -1e-4 and tuck > 0.0:
			var kp: Vector2 = KEEL[mini(floori(absf(a - PI) / step), KEEL.size() - 1)]
			p = p.lerp(Vector3(signf(su) * kp.x * float(s[1]), float(s[4]) - kp.y * float(s[3]), s[0]), tuck)
		if cv > 0.0 and notch > 0.0:
			var from_up := minf(a, TAU - a)
			p.y -= notch * (1.0 if from_up < step else (0.3 if from_up < 2.0 * step else 0.0))
		out.append(p)
	return out


static func _rings() -> Array:
	var rings: Array = []
	for s: Array in TORSO:
		rings.append(_ring(s))
	return rings


## Skin rings with one consistent winding (the notched and keeled rings are not convex, so faces cannot be turned away
## from a centre point): the orientation is taken once from a face on the convex flank, the end caps fan from their
## centres (the end rings are convex).
static func _skin(k: MeshKit, rings: Array, col: Variant) -> void:
	var n := (rings[0] as PackedVector3Array).size()
	var ra: PackedVector3Array = rings[rings.size() / 2]
	var rb: PackedVector3Array = rings[rings.size() / 2 + 1]
	var kr := n / 4
	var nr := (rb[(kr + 1) % n] - ra[kr]).cross(ra[(kr + 1) % n] - ra[kr])
	var axis := Vector3(0, (ra[kr].y + ra[(kr + n / 2) % n].y) * 0.5, ra[kr].z)
	var sgn := 1.0 if nr.dot(ra[kr] - axis) > 0.0 else -1.0
	for i in rings.size() - 1:
		var a: PackedVector3Array = rings[i]
		var b: PackedVector3Array = rings[i + 1]
		for j in n:
			var j2 := (j + 1) % n
			for t: Array in [[a[j], a[j2], b[j2]], [a[j], b[j2], b[j]]]:
				var p0: Vector3 = t[0]
				var p1: Vector3 = t[1]
				var p2: Vector3 = t[2]
				var fn := (p2 - p0).cross(p1 - p0)
				if fn.length_squared() < 1e-12:
					continue
				var c := (p0 + p1 + p2) / 3.0
				k.tri(p0, p1, p2, col, c - fn.normalized() * sgn * 0.01)
	for e: int in [0, rings.size() - 1]:
		var cap: PackedVector3Array = rings[e]
		var cc := MeshKit.centroid(cap)
		var inner := MeshKit.centroid(rings[1 if e == 0 else rings.size() - 2])
		for j in n:
			k.tri(cc, cap[j], cap[(j + 1) % n], col, inner)


## A point on the barrel's faceted skin and its outward normal: [point, normal], at `z` and `angle` degrees round Z from
## up toward +X (negative = the left side, the mirror of the right).
static func _torso_at(z: float, angle: float) -> Array:
	var am := fposmod(angle, 360.0)
	if am > 180.0:
		var r := _torso_at(z, 360.0 - am)
		return [(r[0] as Vector3) * Vector3(-1, 1, 1), (r[1] as Vector3) * Vector3(-1, 1, 1)]
	var i := 0
	while i < TORSO.size() - 2 and z > float(TORSO[i + 1][0]):
		i += 1
	var ra := _ring(TORSO[i])
	var rb := _ring(TORSO[i + 1])
	var t := clampf((z - float(TORSO[i][0])) / (float(TORSO[i + 1][0]) - float(TORSO[i][0])), 0.0, 1.0)
	var f := am / 360.0 * float(TORSO_SIDES) - 0.5
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


static func _on_torso(z: float, angle: float, lift: float) -> Transform3D:
	var pn := _torso_at(z, angle)
	var n: Vector3 = pn[1]
	return Transform3D(Basis.looking_at(n, Vector3.UP), (pn[0] as Vector3) + n * lift)


static func _torso_box(k: MeshKit, z: float, angle: float, lift: float, size: Vector3, col: Variant, off: Vector3 = Vector3.ZERO) -> void:
	k.push(_on_torso(z, angle, lift))
	k.box(size, col, off)
	k.pop()


## A plate following the barrel's facets from angle a0 to a1 (a0 < a1) and z0 to z1, raised `lift` (MechMeshes'
## _torso_plate on this barrel: sections at the ends and every facet vertex between, rows at every section z between,
## a sunk straight inner edge, faces turned from a point inside the slab level with them).
static func _plate(k: MeshKit, z0: float, z1: float, a0: float, a1: float, lift: float, col: Variant) -> void:
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
		if a > a0 + 2.5 and a < a1 - 2.5:
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


## White top, an orange band along the upper flanks, a white front face and waist, a grey belly, a dark underside.
static func _torso_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.9:
		return MechMeshes.DARK
	if n.y < -0.35:
		return MechMeshes.GREY
	if absf(n.z) > 0.85:
		return MechMeshes.GREY                 # the end caps (the nose covers the front one)
	if absf(c.x) < 0.42 and n.y > 0.5:
		return MechMeshes.WHITE                # the top centre stripe and the hatch channel
	var q := Vector2(n.x, n.y).normalized()
	if c.z > -0.78 and c.z < 0.75 and q.y > 0.12 and absf(q.x) > 0.3:
		return MechMeshes.ORANGE               # the shoulders
	return MechMeshes.WHITE


## The barrel: the shell, the hatch housing, front lamp clusters, stepped orange shoulder plates, a waist seam, a belly
## grille, the side pads and the back plinths.
static func _torso(k: MeshKit) -> void:
	_skin(k, _rings(), _torso_colour)
	# The hatch housing: a flat-topped dark well under the hatch collar (rule 2.3: the collar seats on a flat face), its
	# bottom buried in the barrel.
	var hx: Array = LAYOUT["hatch"]
	k.push(MeshKit.xf(hx[0], hx[1]))
	k.tube(Vector3(0, -0.42, 0), Vector3(0, -0.085, 0), 0.55, 12, MechMeshes.DARK)
	k.pop()
	for side: float in [-1.0, 1.0]:
		var lo := func(a0: float, a1: float) -> Vector2: return Vector2(a0, a1) if side > 0.0 else Vector2(-a1, -a0)
		# Front lamp clusters: two amber lamps in hooded dark frames on a grey surround, each front flank.
		for a: float in [62.0, 80.0]:
			_torso_box(k, -0.84, side * a, -0.01, Vector3(0.3, 0.24, 0.05), MechMeshes.GREY)
			_torso_box(k, -0.84, side * a, 0.0, Vector3(0.24, 0.17, 0.05), MechMeshes.DARK)
			_torso_box(k, -0.84, side * a, 0.0, Vector3(0.27, 0.035, 0.12), MechMeshes.DARK, Vector3(0, 0.1, -0.045))
			k.glow = true
			_torso_box(k, -0.84, side * a, 0.01, Vector3(0.19, 0.085, 0.06), MechMeshes.AMBER)
			k.glow = false
		# Stepped orange shoulder plates on dark under-plates, ahead of and behind the side pad.
		var r: Vector2 = lo.call(34.0, 62.0)
		_plate(k, -0.66, -0.46, r.x, r.y, 0.02, MechMeshes.DARK)
		r = lo.call(37.0, 59.0)
		_plate(k, -0.64, -0.48, r.x, r.y, 0.05, MechMeshes.ORANGE)
		r = lo.call(46.0, 70.0)
		_plate(k, 0.3, 0.64, r.x, r.y, 0.02, MechMeshes.DARK)
		r = lo.call(49.0, 67.0)
		_plate(k, 0.33, 0.61, r.x, r.y, 0.05, MechMeshes.ORANGE)
		# A dark waist seam between the white flank and the grey belly.
		r = lo.call(92.0, 100.0)
		_plate(k, -0.86, 0.82, r.x, r.y, 0.025, MechMeshes.DARK)
		# A running light on the rear flank.
		_torso_box(k, 0.5, side * 84.0, -0.01, Vector3(0.36, 0.16, 0.05), MechMeshes.GREY)
		_torso_box(k, 0.5, side * 84.0, 0.0, Vector3(0.3, 0.035, 0.12), MechMeshes.DARK, Vector3(0, 0.07, -0.045))
		k.glow = true
		_torso_box(k, 0.5, side * 84.0, 0.005, Vector3(0.24, 0.07, 0.06), MechMeshes.AMBER)
		k.glow = false
	# A vent grille on the flat belly behind the pelvis: a dark panel with three grey slats.
	_plate(k, 0.34, 0.66, 170.0, 190.0, 0.02, MechMeshes.DARK)
	for z: float in [0.4, 0.49, 0.58]:
		_plate(k, z, z + 0.045, 172.0, 188.0, 0.045, MechMeshes.GREY)
	_hardpoint_pads(k)


# --- Hardpoint mounting surfaces ----------------------------------------------------------------------------

static func _hardpoint_pads(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		_side_pad(k, side)
		_plinth(k, side)


static func _pad_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y < -0.8:
		return MechMeshes.GREY
	if n.y > 0.6:
		return MechMeshes.ORANGE
	return MechMeshes.WHITE


## The side pad (one side, +1 right): a boss out of the flank at the barrel's widest point with a flat outer face the side
## mount's disc sinks 1 cm into, its root buried in the barrel; the underside climbs into the flank (the thighs pass under
## it when the legs twist).
static func _side_pad(k: MeshKit, side: float) -> void:
	var m: Vector3 = (MOUNTS["side_r"] as Vector3) - SIDE_REACH
	var cz := m.z
	var cy := m.y
	var h := SIDE_PAD_H
	var x0 := SIDE_PAD_X
	# [x, half z ahead, half z behind, y0, y1, chamfer]
	var secs := [[x0, h, h, cy - h, cy + h, 0.09], [x0 - 0.04, h + 0.03, h + 0.03, cy - h + 0.03, cy + h + 0.02, 0.1],
		[1.15, h + 0.06, h + 0.1, cy - 0.27, cy + 0.33, 0.12], [0.78, h + 0.12, h + 0.2, cy - 0.25, cy + 0.3, 0.14]]
	var rings: Array = []
	for s: Array in secs:
		var r := MechMeshes._pad_ring(float(s[0]), cz - float(s[1]), cz + float(s[2]), s[3], s[4], s[5])
		for i in r.size():
			r[i] = r[i] * Vector3(side, 1, 1)
		rings.append(r)
	k.loft(rings, [MechMeshes.DARK, _pad_colour, _pad_colour], false, true)
	k.poly(rings[0], MechMeshes.GREY, MeshKit.centroid(rings[1]))
	# Four steel bolts in the face's corners, outside the disc.
	for by: float in [cy + h - 0.07, cy - h + 0.07]:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.02, 0.05, 0.05), MechMeshes.STEEL, Vector3(side * (x0 + 0.005), by, cz + sz * (h - 0.07)))


static func _plinth_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.9:
		return MechMeshes.DARK
	if n.z > 0.3:
		return MechMeshes.GREY
	return MechMeshes.WHITE


## The raised plinth under one back saddle (MOUNTS["back_*"]; the equipment base plate's underside is at -0.04, the
## mortar's at -0.06): a flat dark top 0.5 cm under the plate, a chamfered rear edge, a rear face sloping forward into the
## barrel, white sides with an accent stripe, two steel rails on top. Its bottom is buried in the deck.
static func _plinth(k: MeshKit, side: float) -> void:
	var mb: Vector3 = (MOUNTS["back_r"] as Vector3) * Vector3(side, 1, 1)
	var top := mb.y - 0.045
	var prof := [Vector2(-0.22, top), Vector2(0.28, top), Vector2(0.31, top - 0.035), Vector2(0.24, top - 0.48), Vector2(-0.22, top - 0.36)]
	var rings: Array = []
	for sx: float in [-1.0, 1.0]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(mb.x + sx * PLINTH_HALF, p.y, mb.z + p.x))
		rings.append(r)
	k.loft(rings, _plinth_colour)
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.02, 0.36), MechMeshes.STEEL, Vector3(mb.x + sx * 0.12, top + 0.001, mb.z + 0.06))
		k.box(Vector3(0.02, 0.05, 0.3), MechMeshes.ORANGE, Vector3(mb.x + sx * (PLINTH_HALF + 0.006), top - 0.08, mb.z + 0.04))


# --- Body parts ---------------------------------------------------------------------------------------------

## The hip block under the barrel with the axle the legs hang from (hip pivots at x +-0.833, y -0.083 in body space at
## the default stance), skirt plates and steel collars.
static func _pelvis(k: MeshKit) -> void:
	var hy := -0.1 / BODY_SCALE
	k.loft([MeshKit.ring(Vector3(0, 0.3, 0.0), 0.42, 0.42, 10, "y", 2.4), MeshKit.ring(Vector3(0, 0.02, 0.0), 0.42, 0.42, 10, "y", 2.4),
		MeshKit.ring(Vector3(0, -0.22, 0.0), 0.3, 0.3, 10, "y", 2.4)], [MechMeshes.DARK, MechMeshes.DARK])
	k.tube(Vector3(-0.6, hy, 0), Vector3(0.6, hy, 0), 0.1, 8, MechMeshes.DARK)   # ends just inside the hip balls (inner edge 0.583)
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.4, hy, 0), Vector3(side * 0.47, hy, 0), 0.18, 8, MechMeshes.STEEL)
	# Skirt plates on the lower slopes, front and back, a tag on each (orange in front).
	for f: float in [-1.0, 1.0]:
		var a := Vector3(0, 0.02, f * 0.42)
		var b := Vector3(0, -0.22, f * 0.3)
		var nrm := Vector3(0, -0.12, f * 0.24).normalized()
		k.push(Transform3D(Basis.looking_at(nrm, Vector3.UP), (a + b) * 0.5 + nrm * 0.012))
		k.box(Vector3(0.36, 0.2, 0.035), MechMeshes.GREY)
		k.box(Vector3(0.14, 0.07, 0.03), MechMeshes.ORANGE if f < 0.0 else MechMeshes.STEEL, Vector3(0, -0.02, -0.025))
		k.pop()


## The wide nose under the hatch: a snout with the sensor port (bezel, bolts, visor hood) and two lamps each side.
## Origin on the barrel's front face.
static func _nose(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.0, 0.14), 0.6, 0.3, 8, "z", 3.0), MeshKit.ring(Vector3(0, -0.03, -0.13), 0.52, 0.25, 8, "z", 3.0),
		MeshKit.ring(Vector3(0, -0.05, -0.26), 0.38, 0.17, 8, "z", 3.0)], [MechMeshes.GREY, MechMeshes.WHITE])
	var c := Vector3(0, -0.05, 0)
	k.tube(c + Vector3(0, 0, -0.24), c + Vector3(0, 0, -0.33), 0.14, 8, MechMeshes.DARK)
	k.tube(c + Vector3(0, 0, -0.33), c + Vector3(0, 0, -0.37), 0.085, 8, MechMeshes.GUN)
	k.glow = true
	k.tube(c + Vector3(0, 0, -0.37), c + Vector3(0, 0, -0.39), 0.045, 6, MechMeshes.AMBER)
	for side: float in [-1.0, 1.0]:
		for x: float in [0.2, 0.31]:
			k.box(Vector3(0.08, 0.05, 0.04), MechMeshes.AMBER, Vector3(side * x, -0.16, -0.27))
	k.glow = false
	# A grey bezel round the sensor with six bolts, a visor hood, dark frames round the lamps, a grille between them.
	k.tube(c + Vector3(0, 0, -0.27), c + Vector3(0, 0, -0.31), 0.18, 8, MechMeshes.GREY)
	for i in 6:
		var a := TAU * (float(i) + 0.5) / 6.0
		k.box(Vector3(0.04, 0.04, 0.03), MechMeshes.STEEL, c + Vector3(sin(a) * 0.16, cos(a) * 0.16, -0.32))
	k.box(Vector3(0.34, 0.045, 0.13), MechMeshes.DARK, c + Vector3(0, 0.165, -0.3))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.24, 0.08, 0.03), MechMeshes.DARK, Vector3(side * 0.255, -0.16, -0.255))
	for y: float in [-0.215, -0.245]:
		k.box(Vector3(0.12, 0.02, 0.03), MechMeshes.GREY, Vector3(0, y, -0.25))
	# White cheek plates with a steel bolt each.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 0.53, -0.03, -0.05), Vector3(0, side * -18.0, 0)))
		k.box(Vector3(0.035, 0.22, 0.24), MechMeshes.WHITE)
		k.box(Vector3(0.03, 0.045, 0.045), MechMeshes.STEEL, Vector3(side * 0.025, 0.05, 0.0))
		k.pop()


## A side gun mount (right side): the Strider's side mount scaled up for the heavier guns (it also takes the shoulder
## weapons): a disc on the side pad with an orange rim and a bolted step ring, a square arm out to the mount block the
## weapon pivots on (weapon origin = SIDE_REACH), clamp jaws, a pivot pin, a brace under the arm, a cable.
static func _side_mount(k: MeshKit) -> void:
	var reach := SIDE_REACH
	k.tube(Vector3(-0.06, 0, 0), Vector3(0.1, 0, 0), SIDE_DISC, 10, MechMeshes.DARK)
	k.tube(Vector3(-0.03, 0, 0), Vector3(0.04, 0, 0), SIDE_DISC + 0.015, 10, MechMeshes.ORANGE)
	k.tube(Vector3(0.09, 0, 0), Vector3(0.13, 0, 0), 0.24, 10, MechMeshes.STEEL)
	MechMeshes._bolt_ring(k, 0.13, 0.2, 0.04, 8, 22.5)
	k.tube(Vector3(0.12, 0, 0), Vector3(0.2, 0, 0), 0.15, 8, MechMeshes.GREY)
	k.seg(Vector3(0.18, 0, 0), reach - Vector3(0.05, 0, 0), Vector2(0.1, 0.12), Vector2(0.085, 0.1), 4, MechMeshes.GREY, MeshKit.SQUARE)
	k.box(Vector3(0.14, 0.24, 0.28), MechMeshes.DARK, reach)
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.16, 0.035), MechMeshes.STEEL, reach + Vector3(0, 0, sz * 0.155))
	k.tube(reach, reach + Vector3(0, 0.15, 0), 0.05, 6, MechMeshes.STEEL)
	k.box(Vector3(0.16, 0.035, 0.22), MechMeshes.ORANGE, reach + Vector3(-0.01, -0.135, 0))
	# A brace from the disc's lower rim to the underside of the block (rigid: one part).
	k.seg(Vector3(0.1, -0.2, 0), reach + Vector3(-0.05, -0.1, 0), Vector2(0.05, 0.06), Vector2(0.045, 0.055), 4, MechMeshes.DARK, MeshKit.SQUARE)
	var hose := [Vector3(0.08, -0.2, 0.17), Vector3(0.26, -0.1, 0.14), Vector3(0.44, -0.08, 0.12)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.03, 6, MechMeshes.BLACK)


# --- Legs ---------------------------------------------------------------------------------------------------

## Thick boxy thigh pod: [y, x offset, z offset (+ = back), half width, half depth], drawn on a 0.66 thigh (y scales with
## the length): narrow necks inside the hip ball and the knee drum, a big block between.
const THIGH := [[0.0, 0.0, 0.0, 0.15, 0.17], [-0.1, 0.0, 0.0, 0.26, 0.28], [-0.26, 0.02, 0.02, 0.34, 0.36],
	[-0.42, 0.02, 0.01, 0.33, 0.35], [-0.55, 0.0, 0.0, 0.25, 0.27], [-0.64, 0.0, 0.0, 0.16, 0.18]]
## The shin, drawn on 0.58: carried forward of the knee-ankle line (z offset < 0), so its back stays thin (it passes the
## hip ball when the leg folds) and its front is thick under the knee pad.
const SHIN := [[0.0, 0.0, -0.04, 0.17, 0.19], [-0.1, 0.0, -0.08, 0.25, 0.24], [-0.3, 0.0, -0.08, 0.24, 0.22],
	[-0.46, 0.0, -0.05, 0.2, 0.19], [-0.56, 0.0, -0.02, 0.13, 0.14]]
const THIGH_DRAWN := 0.66
const SHIN_DRAWN := 0.58
const LEG_POWER := 3.2


static func _seg_rings(spec: Array, rest: float, drawn: float) -> Array:
	var rings: Array = []
	for s: Array in spec:
		var y := float(s[0]) * rest / drawn
		rings.append(MeshKit.ring(Vector3(s[1], y, s[2]), s[3], s[4], 8, "y", LEG_POWER))
	return rings


static func _thigh_colour(c: Vector3, n: Vector3) -> Color:
	if n.x < -0.75 or (c.y < -0.48 * float(REST_LENGTH["thigh"]) / THIGH_DRAWN and n.y < -0.3):
		return MechMeshes.GREY
	return MechMeshes.WHITE


## The thigh: hip (origin) forward-down to the knee. A white armoured block, a raised front plate, a dark unit plate on
## the outer face, a hydraulic piston behind it (rigid on the thigh), bolts.
static func _thigh(k: MeshKit) -> void:
	var f := float(REST_LENGTH["thigh"]) / THIGH_DRAWN
	k.loft(_seg_rings(THIGH, float(REST_LENGTH["thigh"]), THIGH_DRAWN), _thigh_colour)
	k.box(Vector3(0.3, 0.2 * f, 0.04), MechMeshes.WHITE, Vector3(0.02, -0.34 * f, -0.335))
	k.box(Vector3(0.2, 0.03, 0.03), MechMeshes.DARK, Vector3(0.02, -0.22 * f, -0.33))
	k.box(Vector3(0.04, 0.2 * f, 0.24), MechMeshes.DARK, Vector3(0.355, -0.34 * f, 0.0))
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.04, 0.04), MechMeshes.STEEL, Vector3(0.38, -0.27 * f, sz * 0.09))
	# The piston behind: cylinder, rod and two end blocks on the back face.
	var pa := Vector3(0, -0.13 * f, 0.4)
	var pb := Vector3(0, -0.52 * f, 0.385)
	k.box(Vector3(0.12, 0.08, 0.14), MechMeshes.DARK, Vector3(0, pa.y, 0.34))
	k.box(Vector3(0.12, 0.08, 0.16), MechMeshes.DARK, Vector3(0, pb.y, 0.33))
	k.tube(pa, pa.lerp(pb, 0.6), 0.058, 6, MechMeshes.DARK)
	k.tube(pa.lerp(pb, 0.55), pb, 0.034, 6, MechMeshes.STEEL)
	k.tube(pa.lerp(pb, 0.3), pa.lerp(pb, 0.42), 0.068, 6, MechMeshes.GREY)


## The shin: knee (origin) back-down to the ankle, ribs down the front and a hose on the outer side.
static func _shin(k: MeshKit) -> void:
	var l: float = REST_LENGTH["shin"]
	var f := l / SHIN_DRAWN
	k.loft(_seg_rings(SHIN, l, SHIN_DRAWN), [MechMeshes.GREY, MechMeshes.GREY, MechMeshes.WHITE, MechMeshes.GREY])
	# Ribs down the front, a hose down the outer side.
	for y: float in [-0.36, -0.43]:
		k.box(Vector3(0.3, 0.045, 0.04), MechMeshes.DARK, Vector3(0, y * f, -0.29 + (y + 0.36) * 0.5))
	var hose := [Vector3(0.2, -0.1, 0.1), Vector3(0.255, -0.27 * f, 0.03), Vector3(0.21, -0.47 * f, 0.03)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.03, 6, MechMeshes.BLACK)


## The knee pad's box in the knee cap's frame (MechModel keeps the cap upright with the hip twist: it faces the legs'
## forward whatever the thigh and shin do): [min, max]. test_torso_clearance_bulwark keeps the shin out of it.
const KNEE_PAD := [Vector3(-0.28, -0.26, -0.53), Vector3(0.28, 0.22, -0.35)]


## The knee: a light grey drum on the axle (dark hubs, a bolted step ring) and the big square orange knee pad in front of
## it, facing forward, on a dark backing plate held by two straps from the hubs (the accent surface, rule 6.5).
static func _knee(k: MeshKit) -> void:
	var r := KNEE_DRUM.x
	var w := KNEE_DRUM.y
	k.tube(Vector3(-w, 0, 0), Vector3(w, 0, 0), r, 10, MechMeshes.GREY)
	k.tube(Vector3(-KNEE_DRUM.z, 0, 0), Vector3(KNEE_DRUM.z, 0, 0), r * 0.55, 8, MechMeshes.DARK)
	k.tube(Vector3(w - 0.01, 0, 0), Vector3(w + 0.035, 0, 0), r * 0.8, 10, MechMeshes.STEEL)
	MechMeshes._bolt_ring(k, w + 0.035, r * 0.68, 0.045, 5, 18.0)
	var lo: Vector3 = KNEE_PAD[0]
	var hi: Vector3 = KNEE_PAD[1]
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.12, 0.38), MechMeshes.DARK, Vector3(sx * 0.31, 0.0, -0.19))
	k.box(Vector3(0.52, 0.44, 0.05), MechMeshes.DARK, Vector3(0, (lo.y + hi.y) * 0.5, hi.z - 0.025))
	k.loft([_zring(hi.z - 0.03, hi.x, lo.y, hi.y, 0.06), _zring(lo.z + 0.05, hi.x, lo.y, hi.y, 0.06),
		_zring(lo.z, hi.x - 0.06, lo.y + 0.05, hi.y - 0.05, 0.05)], MechMeshes.ORANGE)
	for sx: float in [-1.0, 1.0]:
		for y: float in [lo.y + 0.08, hi.y - 0.08]:
			k.box(Vector3(0.035, 0.035, 0.03), MechMeshes.STEEL, Vector3(sx * 0.16, y, lo.z - 0.005))


## The short ankle block from the ankle drum (origin) down into the boot.
static func _ankle(k: MeshKit) -> void:
	var l: float = REST_LENGTH["tarsus"]
	k.seg(Vector3.ZERO, Vector3(0, -l + 0.03, 0), Vector2(0.14, 0.16), Vector2(0.14, 0.16), 4, MechMeshes.DARK, MeshKit.SQUARE)
	k.seg(Vector3(0, -0.06, 0), Vector3(0, -0.1, 0), Vector2(0.155, 0.175), Vector2(0.155, 0.175), 4, MechMeshes.STEEL, MeshKit.SQUARE)


## An octagonal section across Z at z: half width hw, from y0 to y1, corners cut by ch.
static func _zring(z: float, hw: float, y0: float, y1: float, ch: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector2 in [Vector2(-hw + ch, y1), Vector2(hw - ch, y1), Vector2(hw, y1 - ch), Vector2(hw, y0 + ch), Vector2(hw - ch, y0),
			Vector2(-hw + ch, y0), Vector2(-hw, y0 + ch), Vector2(-hw, y1 - ch)]:
		out.append(Vector3(p.x, p.y, z))
	return out


## The hip ball: a faceted sphere on the pivot, with a hub on its outer face (+X).
static func _hip_ball(k: MeshKit) -> void:
	var profile: Array = []
	for i in 6:
		var a := PI * float(i) / 5.0
		profile.append(Vector2(sin(a) * HIP_BALL, cos(a) * HIP_BALL))
	profile.reverse()
	k.lathe(profile, 8, [MechMeshes.STEEL, MechMeshes.STEEL, MechMeshes.WHITE, MechMeshes.STEEL, MechMeshes.STEEL], false, false)
	k.tube(Vector3(HIP_BALL - 0.06, 0, 0), Vector3(HIP_BALL + 0.012, 0, 0), 0.1, 8, MechMeshes.DARK)
	k.tube(Vector3(HIP_BALL, 0, 0), Vector3(HIP_BALL + 0.036, 0, 0), 0.052, 6, MechMeshes.STEEL)
	MechMeshes._bolt_ring(k, HIP_BALL + 0.012, 0.078, 0.03, 4, 0.0)


## The hip socket (right side): a cup over the top of the ball, the strut that carries it into the pelvis.
static func _hip_socket(k: MeshKit) -> void:
	k.lathe(CUP, 8, [MechMeshes.GREY, MechMeshes.DARK, MechMeshes.DARK], true, true)
	k.seg(Vector3(-0.13, 0.31, 0), Vector3(-0.62, 0.46, 0), Vector2(0.14, 0.18), Vector2(0.17, 0.24), 4, MechMeshes.DARK, MeshKit.SQUARE)
	k.tube(Vector3(0, 0.41, 0), Vector3(0, 0.46, 0), 0.085, 6, MechMeshes.GREY)
	k.lathe([Vector2(0.382, 0.21), Vector2(0.36, 0.26)], 8, MechMeshes.STEEL)
	for a: float in [0.0, 90.0, 180.0, 270.0]:
		var dir := Vector3(sin(deg_to_rad(a)), 0, -cos(deg_to_rad(a)))
		if dir.x < -0.5:
			dir = Vector3(-0.7, 0, -0.7).normalized()
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), dir * 0.39 + Vector3(0, 0.15, 0)))
		k.box(Vector3(0.055, 0.055, 0.055), MechMeshes.STEEL)
		k.pop()


static func _boot_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.7:
		return MechMeshes.GREY
	return MechMeshes.DARK


## The boot: origin on the ground under the ankle drum (which sits half sunk in its top). A heavy dark block with grey
## top plates, a steel toe plate, side armour and a sole tread.
static func _boot(k: MeshKit) -> void:
	k.loft([_zring(0.3, 0.27, 0.0, 0.16, 0.05), _zring(0.12, 0.31, 0.0, 0.24, 0.07), _zring(-0.12, 0.32, 0.0, 0.24, 0.07),
		_zring(-0.34, 0.3, 0.0, 0.15, 0.05)], _boot_colour)
	# White side armour plates (rule 6.3: a step, not a colour change), a steel plate across the front, a dark sole band.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.13, 0.36), MechMeshes.WHITE, Vector3(side * 0.322, 0.11, -0.0))
		k.box(Vector3(0.03, 0.04, 0.04), MechMeshes.STEEL, Vector3(side * 0.34, 0.11, 0.12))
	k.box(Vector3(0.46, 0.08, 0.04), MechMeshes.STEEL, Vector3(0, 0.1, -0.33))
	k.box(Vector3(0.62, 0.04, 0.62), MechMeshes.BLACK, Vector3(0, 0.019, -0.02))


## One toe of the split clamp: root at the origin (sunk into the boot's front), its blunt nose forward on the ground.
static func _toe(k: MeshKit) -> void:
	k.loft([_zring(0.02, 0.125, 0.0, 0.17, 0.04), _zring(-0.18, 0.125, 0.0, 0.15, 0.04), _zring(-0.28, 0.1, 0.0, 0.085, 0.03)],
		[MechMeshes.GREY, MechMeshes.STEEL])
	k.loft([_zring(-0.06, 0.135, 0.005, 0.175, 0.045), _zring(-0.1, 0.135, 0.005, 0.172, 0.045)], MechMeshes.DARK)
	k.box(Vector3(0.2, 0.03, 0.16), MechMeshes.BLACK, Vector3(0, 0.014, -0.12))


## The heel spur: root at the origin on the boot's back, a dark clamp, a steel wedge up and back to a point.
static func _spur(k: MeshKit) -> void:
	k.box(Vector3(0.24, 0.14, 0.08), MechMeshes.DARK, Vector3(0, 0.1, 0.0))
	k.seg(Vector3(0, 0.08, -0.02), Vector3(0, 0.17, 0.16), Vector2(0.09, 0.07), Vector2(0.075, 0.06), 4, MechMeshes.STEEL)
	k.seg(Vector3(0, 0.17, 0.16), Vector3(0, 0.36, 0.28), Vector2(0.075, 0.06), Vector2.ZERO, 4, MechMeshes.GREY)
