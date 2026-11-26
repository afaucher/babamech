class_name BulwarkMeshes
extends RefCounted
## The Bulwark's low-poly parts (docs/design/chassis-rules.md; layout pick docs/design/chassis-concepts/
## pick_bulwark_layout_slung_hull.png "B1", legs pick_bulwark_legs_sumo.png): a squat heavy biped built like a walking tank.
## A low, deep armoured hull slung BETWEEN the legs (a wedge nose with a sloped glacis and a grille, a flat top deck, rear
## wings behind the legs, an engine block, a keel hanging between the thighs to below the hip line), and over each hip a
## big round armoured pod standing out of the hull's flank like a pauldron: the hip joint is housed under it, so from the
## front the legs hang from the flanks. The side guns are bolted to the pods' front faces on short wide yokes, low beside
## the nose; the back saddles sit on plinths on the rear wings. The pilot sits in a well behind the glacis, ringed by a
## raised armoured coaming, so only the upper head shows above the deck. The detail lives on the deck and the pods, where
## the chase camera looks (the coaming, a hatch lid, a radiator grille, deck caps, ammo boxes on the pods feeding belts to
## the guns, a rear handrail, amber running lights, orange hazard plates), with ribs, skids and a belly hatch underneath.
## Long heavy legs with forward knees in a deep sumo bend (thick thighs, big square orange knee pads, thick shins, a short
## ankle block into a heavy boot with a split toe clamp and a heel spur): they carry the hull high enough that the pilot's
## head is about at the Strider's chest (user, 2026-11-24), with the belly hanging between the thighs.
##
## Same conventions and tools as MechMeshes (model units, faces -Z, +X its right; body parts in body space around their
## attach point, drawn at BODY_SCALE; leg segments hang along -Y from the proximal joint to REST_LENGTH; joint caps on the
## joint, axle along X; foot parts on the ground; right side authored, the left mirrored). Shared palette, materials
## (MechMeshes.materials) and helpers (MechMeshes._cap, _bolt_ring). Weapons, equipment, the hatch and the pilot heads
## are the Strider's parts, named as-is (ChassisParts). Files: res://assets/models/mech/bulwark_<part>.res
## (tools/models/gen_mech_meshes.gd). Cosmetic only (no gameplay state).

const PREFIX := "bulwark_"
const BODY_PARTS := ["bulwark_torso", "bulwark_pod", "bulwark_pelvis", "bulwark_nose", "bulwark_side_mount",
	"bulwark_belly_mount"]
const LEG_PARTS := ["bulwark_thigh", "bulwark_shin", "bulwark_ankle", "bulwark_hip_socket", "bulwark_hip_cap",
	"bulwark_knee_cap", "bulwark_ankle_cap", "bulwark_boot", "bulwark_toe", "bulwark_spur"]

## Leg segment lengths the meshes are authored at (the Bulwark's default leg params). The "tarsus" is the short ankle
## block between the ankle drum and the boot.
const REST_LENGTH := {"thigh": 1.34, "shin": 1.23, "tarsus": 0.34}
## The legs' sections and joint hardware are drawn this much thicker than the first (short-legged) build, so the longer
## segments still read heavy; detail positions across a segment scale by it.
const LEG_T := 1.25
## The boot, toes and spur are drawn this much larger than authored.
const FOOT_S := 1.2
## Body parts and weapons are drawn this much larger than authored (the same as the Strider, so the shared weapons and the
## pilot keep their size).
const BODY_SCALE := 1.2
## The default stance (MechModel's "stance" param: model units between the hip pivots; ChassisParts reads it) and the hip
## pivot in body space (MechModel._hip_in_body at body scale 1, divided by BODY_SCALE).
const STANCE := 3.4
const HIP_X := STANCE * 0.5 / BODY_SCALE
const HIP_Y := -0.1 / BODY_SCALE

## The hull (body space). DECK: the flat top deck's height. HULL_HW: the hull's half width between the pods (inside the
## thighs); UPPER_Y: the upper hull's underside; the keel between the thighs goes down to KEEL_Y (below the hip line) and
## stays inside KEEL_HW. Behind the pods the upper hull flares out into wings (WING_HW) that carry the back saddles.
const DECK := 0.6
const HULL_HW := 0.98
const WING_HW := 1.3
const UPPER_Y := 0.12
const KEEL_HW := 0.76
const KEEL_Y := -0.38
## The hip pods: a 12-sided drum across X centred over the hip (POD_IN to POD_OUT, wider than the thigh and its plates),
## its axis POD_Y above the hip line, radius POD_R, its underside cut flat at POD_FLOOR (clear of the thighs: the hip ball
## and the socket cup nest into it), an orange armour cap on its outer face (to POD_CAP).
const POD_HALF := 0.46
const POD_IN := HIP_X - POD_HALF
const POD_OUT := HIP_X + POD_HALF
const POD_CAP := POD_OUT + 0.035
const POD_R := 0.54
const POD_Y := 0.36
const POD_FLOOR := 0.27
## The pilot's well: a square hole WELL_HALF either side of the hatch's centre down to WELL_FLOOR, ringed by the coaming
## (an armoured annulus COAMING_IN to COAMING_OUT, up to COAMING_TOP): only the head above the eyes' line shows over it.
const HATCH_Z := -0.12
const WELL_HALF := 0.56
const WELL_FLOOR := 0.33
const COAMING_IN := 0.72
const COAMING_OUT := 0.9
const COAMING_TOP := DECK + 0.1

## Where body parts sit in body space (origin 0.1 above the hip line): [position, rotation (degrees)]. The hatch sits on
## the well's floor (its collar 1 cm into it), its centre HATCH_Z, behind the glacis.
const LAYOUT := {
	"torso": [Vector3.ZERO, Vector3.ZERO],
	"pelvis": [Vector3.ZERO, Vector3.ZERO],
	"pod": [Vector3.ZERO, Vector3.ZERO],
	"nose": [Vector3(0, 0.12, -1.3), Vector3.ZERO],
	"hatch": [Vector3(0, WELL_FLOOR + 0.09, HATCH_Z), Vector3.ZERO],
}
## The side guns: a flat pad on each pod's front face (its face at SIDE_FACE_Z, centred at x SIDE_X, height SIDE_Y), a
## bolted flange on it and a short wide yoke straight forward to the block the weapon pivots on (SIDE_REACH from the
## flange's face): long enough that every side and shoulder weapon pitched fully up or down keeps its tail off the pad.
## The pivot is just under the deck line, on the pod's upper front: any lower and a gun aimed fully down and in meets its
## own knee pad when the long legs fold in the heat shutdown slump (test_hardpoint_contact_bulwark).
const SIDE_X := HIP_X + 0.07
const SIDE_Y := 0.58
const SIDE_FACE_Z := -0.58
const SIDE_LEN := 0.62
const SIDE_REACH := Vector3(0, 0, -SIDE_LEN)
## The flange's half size (x, y) and the pad's round it.
const SIDE_FLANGE := Vector2(0.2, 0.15)
const SIDE_PAD := Vector2(0.23, 0.18)
## Hardpoint mount points in body space (where a weapon's origin goes): the side guns ahead of their pods, the two back
## saddles on the rear wings, outboard and well behind the hatch.
const MOUNTS := {
	"side_l": Vector3(-SIDE_X, SIDE_Y, SIDE_FACE_Z - SIDE_LEN), "side_r": Vector3(SIDE_X, SIDE_Y, SIDE_FACE_Z - SIDE_LEN),
	"back_l": Vector3(-0.9, DECK + 0.165, 0.9), "back_r": Vector3(0.9, DECK + 0.165, 0.9),
	"belly": Vector3(0, KEEL_Y - 0.5, -0.525),   # = (0, BELLY_Y, BELLY_Z): the belly turret prototype below
}
## PROTOTYPE belly turret (docs/design/bulwark-effectiveness.md; MechCatalog "belly", the user picks before it is final):
## a pintle turret under the keel's flat bottom between the two forward ribs, centred. Its base plate (BELLY_BASE across)
## sits on the keel's underside (KEEL_Y) at BELLY_Z; a neck, a wide bearing ring with an orange rim and a bolt ring, then a
## pintle post straight down into the weapon, whose origin (its pivot) hangs BELLY_DROP under the keel: low enough that
## every side weapon pitched across the hardpoint's arc keeps its top off the bearing ring. The mount part's origin is on
## the keel's underside; BELLY_REACH takes it to the weapon's origin (ChassisParts mount_hw "belly").
const BELLY_Z := -0.525
const BELLY_DROP := 0.5
const BELLY_Y := KEEL_Y - BELLY_DROP
const BELLY_REACH := Vector3(0, -BELLY_DROP, 0)
const BELLY_BASE := 0.125      ## base plate radius: between the ribs at z -0.7 and -0.35 (their faces 0.14 off the centre)
const BELLY_RING := 0.2        ## bearing ring radius (below the ribs, so it may be wider than the gap between them)
## The back plinths' half width (x) round each back mount.
const PLINTH_HALF := 0.28

## Foot layout: the two toe clamps [root, yaw degrees] and the heel spur's root.
const TOES := [[Vector3(-0.155, 0, -0.32) * FOOT_S, 0.0], [Vector3(0.155, 0, -0.32) * FOOT_S, 0.0]]
const SPUR_ROOT := Vector3(0, 0, 0.28) * FOOT_S

## The hip ball's radius and the socket cup's lathe profile [radius, y] (8 sides; test_torso_clearance_bulwark reads it).
## Ball and knee drum together (0.9) stay under the thigh's length (1.34), the knee and ankle drums under the shin's.
const HIP_BALL := 0.45
const CUP := [Vector2(0.59, 0.15), Vector2(0.556, 0.3), Vector2(0.4375, 0.5), Vector2(0.225, 0.6125)]
## Joint drums: [radius, half width, hub half length].
const KNEE_DRUM := Vector3(0.45, 0.375, 0.46)
const ANKLE_DRUM := Vector3(0.26, 0.25, 0.31)

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
		"bulwark_pod": _pod(k)
		"bulwark_pelvis": _pelvis(k)
		"bulwark_nose": _nose(k)
		"bulwark_side_mount": _side_mount(k)
		"bulwark_belly_mount": _belly_mount(k)
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


## Only the hull volume grown for the hardpoints (the side guns' pads on the pods' fronts, the back plinths): the tests
## check the legs, the pivoting weapons and the back items against it.
static func hardpoint_pads() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	_hardpoint_pads(k)
	return k.commit(MechMeshes.materials())


## The hull's primary masses only (upper hull round the well, keel, the two hip pods' drums): test_torso_clearance_bulwark
## checks the legs against it.
static func hull_shell() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	_shell(k, true)
	return k.commit(MechMeshes.materials())


## The right hip pod's drum alone (body space; the left is its mirror): the hardpoint test adds both to the hull.
static func pod_shell() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	k.loft(_pod_rings(1.0, POD_IN, POD_OUT, POD_R, POD_FLOOR), _pod_colour)
	return k.commit(MechMeshes.materials())


## The coaming round the pilot's well alone (body space): the hardpoint test keeps every pilot head off it.
static func coaming() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = MechMeshes.ORANGE
	_coaming(k)
	return k.commit(MechMeshes.materials())


# --- The slung hull ----------------------------------------------------------------------------------------

## The upper hull's sections front to back: [z, half width, bottom y, top y, top chamfer, bottom chamfer]. A narrow wedge
## nose (the side guns sit either side of it), the glacis rising straight to the deck's front edge (one plane: the top
## line through every nose station is on it), the deck between the pods, the wings flaring out behind the pods, a short
## taper at the rear. The well is cut out of it (_upper).
const UPPER := [
	[-1.5, 0.5, 0.14, 0.3, 0.05, 0.04],
	[-1.25, 0.6, 0.12, 0.45, 0.08, 0.05],
	[-1.0, 0.66, UPPER_Y, DECK, 0.1, 0.05],
	[-0.72, 0.74, UPPER_Y, DECK, 0.1, 0.05],
	[-0.45, HULL_HW, UPPER_Y, DECK, 0.1, 0.05],
	[0.46, HULL_HW, UPPER_Y, DECK, 0.1, 0.05],
	[0.6, WING_HW, UPPER_Y, DECK, 0.12, 0.05],
	[1.15, WING_HW, UPPER_Y, DECK, 0.12, 0.05],
	[1.4, 1.05, 0.2, 0.54, 0.1, 0.05]]
## The keel between the thighs (its top buried in the upper hull): the same section form.
const KEEL := [
	[-1.3, 0.5, -0.04, 0.3, 0.02, 0.08],
	[-1.05, KEEL_HW, KEEL_Y, 0.3, 0.02, 0.12],
	[0.8, KEEL_HW, KEEL_Y, 0.3, 0.02, 0.12],
	[1.15, 0.6, -0.1, 0.3, 0.02, 0.08]]
## The glacis plane: from the nose's top front edge to the deck's front edge (z, y).
const GLACIS_A := Vector2(-1.5, 0.3)
const GLACIS_B := Vector2(-1.0, DECK)


## An octagonal section across Z at z: half width hw, from y0 to y1, top corners cut by ct, bottom corners by cb.
static func _oct(z: float, hw: float, y0: float, y1: float, ct: float, cb: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector2 in [Vector2(-hw + ct, y1), Vector2(hw - ct, y1), Vector2(hw, y1 - ct), Vector2(hw, y0 + cb), Vector2(hw - cb, y0),
			Vector2(-hw + cb, y0), Vector2(-hw, y0 + cb), Vector2(-hw, y1 - ct)]:
		out.append(Vector3(p.x, p.y, z))
	return out


## The upper hull's section at z, interpolated between the UPPER stations: [z, hw, y0, y1, ct, cb].
static func _upper_at(z: float) -> Array:
	var i := 0
	while i < UPPER.size() - 2 and z > float(UPPER[i + 1][0]):
		i += 1
	var a: Array = UPPER[i]
	var b: Array = UPPER[i + 1]
	var t := clampf((z - float(a[0])) / (float(b[0]) - float(a[0])), 0.0, 1.0)
	var out: Array = [z]
	for j in range(1, 6):
		out.append(lerpf(float(a[j]), float(b[j]), t))
	return out


static func _sec(s: Array) -> PackedVector3Array:
	return _oct(s[0], s[1], s[2], s[3], s[4], s[5])


## A side block's section beside the well (right side; x from WELL_HALF out to the hull's flank).
static func _side_sec(s: Array, side: float) -> PackedVector3Array:
	var hw: float = s[1]
	var y0: float = s[2]
	var y1: float = s[3]
	var ct: float = s[4]
	var cb: float = s[5]
	var out := PackedVector3Array()
	for p: Vector2 in [Vector2(WELL_HALF, y1), Vector2(hw - ct, y1), Vector2(hw, y1 - ct), Vector2(hw, y0 + cb), Vector2(hw - cb, y0),
			Vector2(WELL_HALF, y0)]:
		out.append(Vector3(side * p.x, p.y, s[0]))
	return out


## White armour (the keel's flanks too, so hull and keel read as one mass), grey front and rear faces, undersides and
## the keel's lower chamfers and its bottom (the dark ribs, hatch and skids read against it).
static func _hull_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.6:
		return MechMeshes.GREY
	if absf(c.x) < KEEL_HW + 0.01 and c.y < UPPER_Y - 0.01 and n.y < -0.2:
		return MechMeshes.GREY
	if n.z < -0.9 or n.z > 0.9:
		return MechMeshes.GREY
	return MechMeshes.WHITE


## The upper hull with the pilot's well cut out of it: a loft ahead of the well, one behind it, a block either side, the
## well's floor.
static func _upper(k: MeshKit) -> void:
	var w0 := HATCH_Z - WELL_HALF
	var w1 := HATCH_Z + WELL_HALF
	var front: Array = []
	var mid: Array = [_upper_at(w0 - 0.01)]
	var rear: Array = [_sec(_upper_at(w1 - 0.01))]
	for s: Array in UPPER:
		var z: float = s[0]
		if z < w0:
			front.append(_sec(s))
		elif z < w1:
			mid.append(s)
		else:
			rear.append(_sec(s))
	front.append(_sec(_upper_at(w0 + 0.01)))
	mid.append(_upper_at(w1 + 0.01))
	k.loft(front, _hull_colour)
	k.loft(rear, _hull_colour)
	for side: float in [-1.0, 1.0]:
		var rings: Array = []
		for s: Array in mid:
			rings.append(_side_sec(s, side))
		k.loft(rings, _hull_colour)
	k.box(Vector3(2.0 * WELL_HALF + 0.02, WELL_FLOOR - UPPER_Y, w1 - w0), MechMeshes.DARK, Vector3(0, (WELL_FLOOR + UPPER_Y) * 0.5, HATCH_Z))


static func _pod_colour(_c: Vector3, n: Vector3) -> Color:
	if absf(n.x) > 0.7:
		return MechMeshes.GREY
	if n.y < -0.6:
		return MechMeshes.GREY
	return MechMeshes.WHITE


## A pod-shaped section across X at each x in [x0, x1] (side +1 right): a 12-gon of radius r round the pod's axis (a flat
## facet on top and in front), its underside cut flat at `flat`.
static func _pod_rings(side: float, x0: float, x1: float, r: float, flat: float) -> Array:
	var out: Array = []
	for x: float in [x0, x1]:
		var ring := MeshKit.ring(Vector3(side * x, POD_Y, 0), r, r, 12, "x", 2.0, 0.5)
		for i in ring.size():
			ring[i].y = maxf(ring[i].y, flat)
		out.append(ring)
	return out


## The primary masses: upper hull, keel (and with `pods` the two pod drums, which are their own part, bulwark_pod).
static func _shell(k: MeshKit, pods: bool = false) -> void:
	_upper(k)
	var keel: Array = []
	for s: Array in KEEL:
		keel.append(_sec(s))
	k.loft(keel, _hull_colour)
	if pods:
		for side: float in [-1.0, 1.0]:
			k.loft(_pod_rings(side, POD_IN, POD_OUT, POD_R, POD_FLOOR), _pod_colour)


## A ring round Y at `c`: the convex profile [(radius, y), ...] revolved with n sides, every face turned away from the
## profile's own centre (so the inner wall faces the axis).
static func _annulus(k: MeshKit, c: Vector3, prof: Array, n: int, col: Variant) -> void:
	var pc := Vector2.ZERO
	for p: Vector2 in prof:
		pc += p
	pc /= float(prof.size())
	for j in n:
		var a0 := TAU * float(j) / float(n)
		var a1 := TAU * float(j + 1) / float(n)
		var am := (a0 + a1) * 0.5
		var away := c + Vector3(sin(am) * pc.x, pc.y, cos(am) * pc.x)
		for i in prof.size():
			var p: Vector2 = prof[i]
			var q: Vector2 = prof[(i + 1) % prof.size()]
			var v := [c + Vector3(sin(a0) * p.x, p.y, cos(a0) * p.x), c + Vector3(sin(a1) * p.x, p.y, cos(a1) * p.x),
				c + Vector3(sin(a1) * q.x, q.y, cos(a1) * q.x), c + Vector3(sin(a0) * q.x, q.y, cos(a0) * q.x)]
			k.tri(v[0], v[1], v[2], col, away)
			k.tri(v[0], v[2], v[3], col, away)


static func _coaming_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.5:
		return MechMeshes.GREY
	if n.y < -0.5:
		return MechMeshes.DARK
	return MechMeshes.WHITE


## The coaming: a thick armoured ring round the well's mouth (its foot 2 cm into the deck), a sloped outer top edge.
static func _coaming(k: MeshKit) -> void:
	_annulus(k, Vector3(0, 0, HATCH_Z), [Vector2(COAMING_IN, DECK - 0.02), Vector2(COAMING_OUT, DECK - 0.02), Vector2(COAMING_OUT, DECK + 0.05),
		Vector2(COAMING_OUT - 0.07, COAMING_TOP), Vector2(COAMING_IN, COAMING_TOP)], 12, _coaming_colour)


## A transform on the glacis: x across, u (0..1) from its front edge to the deck's, lifted `lift` along its normal. Local
## +Y = the glacis normal, +Z = up the slope (toward the deck).
static func _on_glacis(x: float, u: float, lift: float) -> Transform3D:
	var d := Vector3(0, GLACIS_B.y - GLACIS_A.y, GLACIS_B.x - GLACIS_A.x).normalized()
	var n := Vector3(0, d.z, -d.y)
	var p := Vector3(x, lerpf(GLACIS_A.y, GLACIS_B.y, u), lerpf(GLACIS_A.x, GLACIS_B.x, u))
	return Transform3D(Basis(Vector3.RIGHT, n, d), p + n * lift)


static func _glacis_box(k: MeshKit, x: float, u: float, lift: float, size: Vector3, col: Variant) -> void:
	k.push(_on_glacis(x, u, lift))
	k.box(size, col)
	k.pop()


## An amber lamp in a dark frame, facing `dir`, at p.
static func _lamp(k: MeshKit, p: Vector3, dir: Vector3, w: float) -> void:
	k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), p))
	k.box(Vector3(w + 0.06, 0.12, 0.05), MechMeshes.DARK)
	k.glow = true
	k.box(Vector3(w, 0.07, 0.07), MechMeshes.AMBER, Vector3(0, -0.005, 0))
	k.glow = false
	k.pop()


## The hull: shell, coaming, glacis, deck kit, engine block, underside, hardpoint pads.
static func _torso(k: MeshKit) -> void:
	_shell(k)
	_coaming(k)
	_glacis(k)
	_deck(k)
	_rear(k)
	_belly(k)
	_hardpoint_pads(k)


## The right hip pod (body space; MechModel mirrors it for the left): the white drum (its outer rim left showing round the
## cap), a dark step ring, the orange armour cap (the accent surface), a dark hub with four bolts, a rear amber light, and
## on its flat top an ammo box feeding a belt down the pod's front to the side gun's flange, and two caps.
static func _pod(k: MeshKit) -> void:
	k.loft(_pod_rings(1.0, POD_IN, POD_OUT, POD_R, POD_FLOOR), _pod_colour)
	k.loft(_pod_rings(1.0, POD_OUT - 0.01, POD_OUT + 0.012, POD_R - 0.07, POD_FLOOR + 0.03), MechMeshes.DARK)
	k.loft(_pod_rings(1.0, POD_OUT + 0.01, POD_CAP, POD_R - 0.11, POD_FLOOR + 0.06), MechMeshes.ORANGE)
	k.tube(Vector3(POD_CAP - 0.01, POD_Y, 0), Vector3(POD_CAP + 0.02, POD_Y, 0), 0.11, 8, MechMeshes.DARK)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		k.box(Vector3(0.03, 0.05, 0.05), MechMeshes.STEEL, Vector3(POD_CAP + 0.005, POD_Y + cos(a) * 0.2, sin(a) * 0.2))
	_lamp(k, Vector3(HIP_X, POD_Y + 0.1, POD_R * 0.966 + 0.025), Vector3(0, 0, 1), 0.14)
	var top := POD_Y + POD_R * cos(PI / 12.0)
	k.box(Vector3(0.3, 0.15, 0.2), MechMeshes.GUN, Vector3(HIP_X + 0.04, top + 0.065, 0.0))
	k.box(Vector3(0.32, 0.03, 0.22), MechMeshes.ORANGE, Vector3(HIP_X + 0.04, top + 0.14, 0.0))
	for x: float in [HIP_X - 0.26, HIP_X + 0.3]:
		k.tube(Vector3(x, top - 0.01, 0.0), Vector3(x, top + 0.05, 0.0), 0.06, 6, MechMeshes.GREY)
	var r := POD_R + 0.03
	var belt := [Vector3(HIP_X + 0.07, top + 0.06, -0.11), Vector3(HIP_X + 0.07, POD_Y + r * cos(PI / 6.0), -r * sin(PI / 6.0)),
		Vector3(HIP_X + 0.07, POD_Y + r * cos(PI / 3.0), -r * sin(PI / 3.0)), Vector3(SIDE_X - 0.05, SIDE_Y + SIDE_FLANGE.y + 0.01, SIDE_FACE_Z - 0.03)]
	for i in belt.size() - 1:
		var a: Vector3 = belt[i]
		var b: Vector3 = belt[i + 1]
		var nl := maxi(1, roundi(a.distance_to(b) / 0.09))
		for j in nl:
			var p := a.lerp(b, (float(j) + 0.5) / float(nl))
			k.push(Transform3D(Basis.looking_at((b - a).normalized(), Vector3.UP if absf((b - a).normalized().y) < 0.9 else Vector3.BACK), p))
			k.box(Vector3(0.1, 0.04, 0.035), MechMeshes.STEEL if j % 2 == 0 else MechMeshes.GUN)
			k.pop()


## The glacis: the radiator grille (a dark well, grey slats), orange hazard plates at its corners, the headlight pair low
## on the nose's front face, a dark seam under the deck's front edge.
static func _glacis(k: MeshKit) -> void:
	_glacis_box(k, 0.0, 0.45, 0.0, Vector3(0.66, 0.05, 0.42), MechMeshes.GREY)
	_glacis_box(k, 0.0, 0.45, 0.01, Vector3(0.56, 0.05, 0.34), MechMeshes.BLACK)
	for u: float in [0.32, 0.45, 0.58]:
		_glacis_box(k, 0.0, u, 0.025, Vector3(0.52, 0.04, 0.045), MechMeshes.GREY)
	for side: float in [-1.0, 1.0]:
		_glacis_box(k, side * 0.45, 0.55, 0.005, Vector3(0.14, 0.04, 0.3), MechMeshes.ORANGE)
		_lamp(k, Vector3(side * 0.28, 0.22, -1.5), Vector3(0, 0, -1), 0.13)
	k.box(Vector3(0.9, 0.03, 0.04), MechMeshes.DARK, Vector3(0, 0.255, -1.5))


## The deck: the hatch lid behind the coaming, a radiator grille between the back saddles, front lamp boxes and caps on
## the deck's front corners, a rear handrail, running lights on the deck edges, hazard plates on the wings.
static func _deck(k: MeshKit) -> void:
	# The hatch lid, swung open and leaning back behind the coaming, on a hinge block.
	var hinge := HATCH_Z + COAMING_OUT + 0.05
	k.box(Vector3(0.36, 0.08, 0.1), MechMeshes.DARK, Vector3(0, DECK + 0.03, hinge))
	k.push(MeshKit.xf(Vector3(0, DECK + 0.05, hinge + 0.02), Vector3(-65, 0, 0)))
	k.tube(Vector3(0, 0.0, 0.0), Vector3(0, 0.05, 0.0), 0.24, 8, MechMeshes.WHITE)
	k.tube(Vector3(0, 0.04, 0.0), Vector3(0, 0.07, 0.0), 0.15, 8, MechMeshes.ORANGE)
	k.pop()
	# The radiator grille on the rear deck, between the back saddles.
	k.box(Vector3(0.5, 0.03, 0.4), MechMeshes.GREY, Vector3(0, DECK + 0.005, 1.0))
	k.box(Vector3(0.42, 0.03, 0.32), MechMeshes.BLACK, Vector3(0, DECK + 0.012, 1.0))
	for z: float in [0.9, 1.0, 1.1]:
		k.box(Vector3(0.38, 0.03, 0.04), MechMeshes.GREY, Vector3(0, DECK + 0.025, z))
	# A low handrail across the rear deck's back edge.
	for x: float in [-0.5, 0.0, 0.5]:
		k.box(Vector3(0.03, 0.1, 0.03), MechMeshes.STEEL, Vector3(x, DECK + 0.04, 1.2))
	k.tube(Vector3(-0.52, DECK + 0.09, 1.2), Vector3(0.52, DECK + 0.09, 1.2), 0.022, 6, MechMeshes.STEEL)
	for side: float in [-1.0, 1.0]:
		# A front box with an amber lamp and a deck cap at each front corner, ahead of the coaming.
		k.box(Vector3(0.24, 0.12, 0.16), MechMeshes.GREY, Vector3(side * 0.4, DECK + 0.05, -0.95))
		_lamp(k, Vector3(side * 0.4, DECK + 0.06, -1.035), Vector3(0, 0, -1), 0.12)
		k.tube(Vector3(side * 0.12, DECK - 0.01, -0.96), Vector3(side * 0.12, DECK + 0.05, -0.96), 0.06, 6, MechMeshes.GREY)
		k.box(Vector3(0.05, 0.03, 0.05), MechMeshes.DARK, Vector3(side * 0.12, DECK + 0.055, -0.96))
		# Running lights on the deck's top edge chamfer, at the front corners and the wings' rear corners.
		for z: float in [-0.86, 1.05]:
			var s := _upper_at(z)
			var hw: float = s[1]
			k.push(Transform3D(Basis.looking_at(Vector3(side, 1, 0).normalized(), Vector3.UP), Vector3(side * (hw - 0.05), DECK - 0.05, z)))
			k.glow = true
			k.box(Vector3(0.18, 0.05, 0.04), MechMeshes.AMBER)
			k.glow = false
			k.pop()
		# An orange hazard plate on each wing's flank.
		k.box(Vector3(0.04, 0.14, 0.26), MechMeshes.ORANGE, Vector3(side * WING_HW, (UPPER_Y + DECK) * 0.5, 0.85))


## The rear: an engine block on the back face with a grille and two exhaust stacks.
static func _rear(k: MeshKit) -> void:
	k.loft([_oct(1.35, 0.6, 0.26, 0.5, 0.06, 0.04), _oct(1.56, 0.56, 0.28, 0.48, 0.06, 0.04)], MechMeshes.GREY)
	k.box(Vector3(0.8, 0.14, 0.04), MechMeshes.BLACK, Vector3(0, 0.38, 1.565))
	for y: float in [0.34, 0.38, 0.42]:
		k.box(Vector3(0.76, 0.025, 0.05), MechMeshes.GREY, Vector3(0, y, 1.575))
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.4, 0.45, 1.42), Vector3(side * 0.42, 0.7, 1.52), 0.07, 6, MechMeshes.DARK)
		k.tube(Vector3(side * 0.42, 0.68, 1.51), Vector3(side * 0.425, 0.73, 1.53), 0.085, 6, MechMeshes.GUN)


## The underside: two skid rails along the keel's flat bottom, three ribs across it, a belly hatch with a handle, a dim
## amber belly light.
static func _belly(k: MeshKit) -> void:
	var y := KEEL_Y
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.07, 0.06, 1.5), MechMeshes.DARK, Vector3(side * 0.5, y - 0.02, -0.12))
	for z: float in [-0.7, -0.35, 0.55]:
		k.box(Vector3(0.86, 0.04, 0.07), MechMeshes.DARK, Vector3(0, y - 0.012, z))
	k.box(Vector3(0.44, 0.03, 0.4), MechMeshes.BLACK, Vector3(0, y - 0.008, 0.1))
	k.box(Vector3(0.2, 0.03, 0.04), MechMeshes.STEEL, Vector3(0, y - 0.03, 0.22))
	k.glow = true
	k.box(Vector3(0.14, 0.03, 0.08), MechMeshes.AMBER, Vector3(0, y - 0.01, -0.95))
	k.glow = false


# --- Hardpoint mounting surfaces ----------------------------------------------------------------------------

static func _hardpoint_pads(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		_side_pad(k, side)
		_plinth(k, side)


static func _pad_colour(_c: Vector3, n: Vector3) -> Color:
	if n.z < -0.8:
		return MechMeshes.DARK
	return MechMeshes.GREY


## The side gun's pad (one side, +1 right): a chamfered block on the pod's front face, its flat dark face (SIDE_FACE_Z)
## the flange sinks 1 cm into (its bolts hold it), its back buried in the pod.
static func _side_pad(k: MeshKit, side: float) -> void:
	k.push(Transform3D(Basis.IDENTITY, Vector3(side * SIDE_X, 0, 0)))
	k.loft([_zring(SIDE_FACE_Z + 0.34, SIDE_PAD.x + 0.01, SIDE_Y - SIDE_PAD.y - 0.01, SIDE_Y + SIDE_PAD.y + 0.01, 0.06),
		_zring(SIDE_FACE_Z + 0.03, SIDE_PAD.x + 0.01, SIDE_Y - SIDE_PAD.y - 0.01, SIDE_Y + SIDE_PAD.y + 0.01, 0.06),
		_zring(SIDE_FACE_Z, SIDE_PAD.x, SIDE_Y - SIDE_PAD.y, SIDE_Y + SIDE_PAD.y, 0.05)], _pad_colour)
	k.pop()


static func _plinth_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.9:
		return MechMeshes.DARK
	if n.z > 0.3:
		return MechMeshes.GREY
	return MechMeshes.WHITE


## The raised plinth under one back saddle (MOUNTS["back_*"]; the equipment base plate's underside is at -0.04, the
## mortar's at -0.06): a flat dark top 0.5 cm under the plate, a chamfered rear edge, a rear face sloping forward into the
## deck, white sides with an accent stripe, two steel rails on top. Its bottom is buried in the wing.
static func _plinth(k: MeshKit, side: float) -> void:
	var mb: Vector3 = (MOUNTS["back_r"] as Vector3) * Vector3(side, 1, 1)
	var top := mb.y - 0.045
	var prof := [Vector2(-0.22, top), Vector2(0.28, top), Vector2(0.31, top - 0.035), Vector2(0.26, top - 0.24), Vector2(-0.22, top - 0.2)]
	var rings: Array = []
	for sx: float in [-1.0, 1.0]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(mb.x + sx * PLINTH_HALF, p.y, mb.z + p.x))
		rings.append(r)
	k.loft(rings, _plinth_colour)
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.02, 0.36), MechMeshes.STEEL, Vector3(mb.x + sx * 0.12, top + 0.001, mb.z + 0.06))
		k.box(Vector3(0.02, 0.05, 0.3), MechMeshes.ORANGE, Vector3(mb.x + sx * (PLINTH_HALF + 0.006), top - 0.06, mb.z + 0.04))


# --- Body parts ---------------------------------------------------------------------------------------------

## The hip axle the legs hang from (hip pivots at x +-HIP_X, y HIP_Y in body space at the default stance): through the
## keel, its ends inside the hip balls, steel collars where it leaves the keel.
static func _pelvis(k: MeshKit) -> void:
	var ball := HIP_BALL / BODY_SCALE
	var end := HIP_X - ball + 0.05
	k.tube(Vector3(-end, HIP_Y, 0), Vector3(end, HIP_Y, 0), 0.1, 8, MechMeshes.DARK)
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * (KEEL_HW - 0.02), HIP_Y, 0), Vector3(side * (KEEL_HW + 0.04), HIP_Y, 0), 0.16, 8, MechMeshes.STEEL)


## The chin sensor housing on the keel's front face (origin on it): a grey block with the sensor port (bezel, bolts, visor
## hood) and two amber lamps each side, the family's nose.
static func _nose(k: MeshKit) -> void:
	k.loft([_oct(0.02, 0.4, -0.14, 0.14, 0.04, 0.04), _oct(-0.1, 0.36, -0.12, 0.12, 0.04, 0.04)], MechMeshes.GREY)
	var c := Vector3(0, 0.0, -0.1)
	k.tube(c, c + Vector3(0, 0, -0.06), 0.11, 8, MechMeshes.DARK)
	k.tube(c + Vector3(0, 0, -0.06), c + Vector3(0, 0, -0.09), 0.07, 8, MechMeshes.GUN)
	k.glow = true
	k.tube(c + Vector3(0, 0, -0.09), c + Vector3(0, 0, -0.11), 0.04, 6, MechMeshes.AMBER)
	for side: float in [-1.0, 1.0]:
		for x: float in [0.19, 0.29]:
			k.box(Vector3(0.07, 0.05, 0.04), MechMeshes.AMBER, Vector3(side * x, -0.04, -0.115))
	k.glow = false
	for i in 6:
		var a := TAU * (float(i) + 0.5) / 6.0
		k.box(Vector3(0.035, 0.035, 0.03), MechMeshes.STEEL, c + Vector3(sin(a) * 0.125, cos(a) * 0.125, -0.01))
	k.box(Vector3(0.3, 0.04, 0.09), MechMeshes.DARK, c + Vector3(0, 0.13, -0.02))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.22, 0.08, 0.03), MechMeshes.DARK, Vector3(side * 0.24, -0.04, -0.1))


## A side gun mount (right side; origin on the pod pad's face, the weapon's origin SIDE_REACH straight ahead): a bolted
## dark flange with an orange rim, a short wide square yoke forward to the block the weapon pivots on, clamp jaws, a
## vertical pivot pin, an orange collar under the block, two braces under the yoke, a cable.
static func _side_mount(k: MeshKit) -> void:
	var reach := SIDE_REACH
	var f := SIDE_FLANGE
	k.box(Vector3(2.0 * f.x, 2.0 * f.y, 0.06), MechMeshes.DARK, Vector3(0, 0, -0.02))
	k.box(Vector3(2.0 * f.x + 0.03, 2.0 * f.y + 0.03, 0.025), MechMeshes.ORANGE, Vector3(0, 0, -0.015))
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			k.box(Vector3(0.04, 0.04, 0.03), MechMeshes.STEEL, Vector3(sx * (f.x - 0.04), sy * (f.y - 0.04), -0.055))
	k.seg(Vector3(0, 0, -0.04), reach + Vector3(0, 0, 0.12), Vector2(0.15, 0.13), Vector2(0.13, 0.11), 4, MechMeshes.GREY, MeshKit.SQUARE)
	k.box(Vector3(0.24, 0.14, 0.28), MechMeshes.DARK, reach)
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.1, 0.16), MechMeshes.STEEL, reach + Vector3(sx * 0.135, 0, 0))
	k.tube(reach - Vector3(0, 0.1, 0), reach + Vector3(0, 0.09, 0), 0.05, 6, MechMeshes.STEEL)
	k.box(Vector3(0.22, 0.035, 0.22), MechMeshes.ORANGE, reach + Vector3(0, -0.085, 0))
	for sx: float in [-1.0, 1.0]:
		k.seg(Vector3(sx * 0.12, -f.y + 0.03, -0.05), Vector3(sx * 0.06, -0.1, reach.z * 0.6), Vector2(0.035, 0.035), Vector2(0.03, 0.03), 4,
			MechMeshes.DARK, MeshKit.SQUARE)
	var hose := [Vector3(-0.17, 0.1, -0.06), Vector3(-0.17, 0.08, -0.25), Vector3(-0.15, 0.06, -0.42)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.03, 6, MechMeshes.BLACK)


## PROTOTYPE: the belly turret's pintle mount (origin on the keel's flat underside at the turret's centre; the weapon's
## origin BELLY_REACH straight below): a dark base plate sunk 5 mm into the keel with four bolts, a short neck, the
## bearing ring (grey drum, orange rim, a ring of bolts on its underside), a steel pintle post down into the weapon with a
## dark collar and an end cap (finished when the hardpoint is empty), a feed cable from the ring to the post.
static func _belly_mount(k: MeshKit) -> void:
	var b := BELLY_BASE
	k.tube(Vector3(0, 0.005, 0), Vector3(0, -0.05, 0), b, 8, MechMeshes.DARK)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		k.box(Vector3(0.03, 0.02, 0.03), MechMeshes.STEEL, Vector3(sin(a) * (b - 0.03), -0.058, cos(a) * (b - 0.03)))
	k.tube(Vector3(0, -0.05, 0), Vector3(0, -0.09, 0), 0.08, 8, MechMeshes.GREY)
	var r := BELLY_RING
	k.tube(Vector3(0, -0.09, 0), Vector3(0, -0.15, 0), r, 10, MechMeshes.GREY)
	k.tube(Vector3(0, -0.1, 0), Vector3(0, -0.135, 0), r + 0.015, 10, MechMeshes.ORANGE)
	for i in 6:
		var a := TAU * float(i) / 6.0
		k.box(Vector3(0.03, 0.02, 0.03), MechMeshes.STEEL, Vector3(sin(a) * (r - 0.04), -0.158, cos(a) * (r - 0.04)))
	var end := BELLY_REACH.y + 0.08
	k.tube(Vector3(0, -0.15, 0), Vector3(0, end, 0), 0.055, 8, MechMeshes.STEEL)
	k.tube(Vector3(0, -0.15, 0), Vector3(0, -0.2, 0), 0.085, 8, MechMeshes.DARK)
	k.tube(Vector3(0, end + 0.02, 0), Vector3(0, end, 0), 0.075, 8, MechMeshes.DARK)
	var hose := [Vector3(-0.15, -0.13, 0.08), Vector3(-0.12, -0.24, 0.1), Vector3(-0.06, -0.32, 0.07)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.025, 6, MechMeshes.BLACK)


# --- Legs ---------------------------------------------------------------------------------------------------

## Thick boxy thigh pod: [y, x offset, z offset (+ = back), half width, half depth], drawn on a 1.34 thigh (y scales with
## the length): narrow necks inside the hip ball and the knee drum, a long big block between (its 0.40 half depth keeps
## the hip ball and knee drum at 0.55 x its thickness, rule 3.3).
const THIGH := [[0.0, 0.0, 0.0, 0.2, 0.22], [-0.18, 0.0, 0.0, 0.33, 0.35], [-0.45, 0.0, 0.0, 0.39, 0.4],
	[-0.85, 0.0, 0.0, 0.38, 0.39], [-1.12, 0.0, 0.0, 0.31, 0.33], [-1.32, 0.0, 0.0, 0.2, 0.22]]
## The shin, drawn on 1.23: carried forward of the knee-ankle line (z offset < 0), so its back stays thin (it passes the
## hip ball when the leg folds) and its front is thick under the knee pad; wide across, so it reads heavy from behind.
const SHIN := [[0.0, 0.0, -0.05, 0.225, 0.25], [-0.2, 0.0, -0.11, 0.37, 0.31], [-0.6, 0.0, -0.11, 0.36, 0.29],
	[-0.98, 0.0, -0.075, 0.3, 0.24], [-1.2, 0.0, -0.025, 0.2, 0.19]]
const THIGH_DRAWN := 1.34
const SHIN_DRAWN := 1.23
const LEG_POWER := 3.2
## The thigh's widest reach across X from its axis, its outer plate and bolts included (test_mech_parts: the thighs hang
## outside the keel, the pods cover them).
const THIGH_HW := 0.39
const THIGH_PLATES_HW := 0.47


static func _seg_rings(spec: Array, rest: float, drawn: float) -> Array:
	var rings: Array = []
	for s: Array in spec:
		var y := float(s[0]) * rest / drawn
		rings.append(MeshKit.ring(Vector3(s[1], y, s[2]), s[3], s[4], 8, "y", LEG_POWER))
	return rings


static func _thigh_colour(c: Vector3, n: Vector3) -> Color:
	if n.x < -0.75 or (c.y < -0.62 * float(REST_LENGTH["thigh"]) and n.y < -0.3):
		return MechMeshes.GREY
	return MechMeshes.WHITE


## The thigh: hip (origin) forward-down to the knee. A white armoured block, a raised front plate, a dark unit plate on
## the outer face, a hydraulic piston behind it (rigid on the thigh), bolts.
static func _thigh(k: MeshKit) -> void:
	var l := float(REST_LENGTH["thigh"])
	var t := LEG_T
	k.loft(_seg_rings(THIGH, l, THIGH_DRAWN), _thigh_colour)
	# The front plate (two stacked plates down the long thigh) with a dark seam, the outer unit plate and its bolts.
	for y: float in [-0.5, -0.8]:
		k.box(Vector3(0.36, 0.26, 0.06), MechMeshes.WHITE, Vector3(0.025, y * l / THIGH_DRAWN, -0.415))
	k.box(Vector3(0.26, 0.035, 0.035), MechMeshes.DARK, Vector3(0.025, -0.3 * l / THIGH_DRAWN, -0.4))
	k.box(Vector3(0.05, 0.42, 0.3), MechMeshes.DARK, Vector3(0.405, -0.66 * l / THIGH_DRAWN, 0.0))
	for sz: float in [-1.0, 1.0]:
		for y: float in [-0.5, -0.82]:
			k.box(Vector3(0.04, 0.05, 0.05), MechMeshes.STEEL, Vector3(0.44, y * l / THIGH_DRAWN, sz * 0.11))
	# The piston behind: cylinder, rod and two end blocks on the back face.
	var pa := Vector3(0, -0.26 * l / THIGH_DRAWN, 0.46)
	var pb := Vector3(0, -1.03 * l / THIGH_DRAWN, 0.44)
	k.box(Vector3(0.12 * t, 0.1, 0.14 * t), MechMeshes.DARK, Vector3(0, pa.y, 0.39))
	k.box(Vector3(0.12 * t, 0.1, 0.16 * t), MechMeshes.DARK, Vector3(0, pb.y, 0.375))
	k.tube(pa, pa.lerp(pb, 0.6), 0.058 * t, 6, MechMeshes.DARK)
	k.tube(pa.lerp(pb, 0.55), pb, 0.034 * t, 6, MechMeshes.STEEL)
	k.tube(pa.lerp(pb, 0.3), pa.lerp(pb, 0.42), 0.068 * t, 6, MechMeshes.GREY)


## The shin: knee (origin) back-down to the ankle, ribs down the front and a hose on the outer side.
static func _shin(k: MeshKit) -> void:
	var l: float = REST_LENGTH["shin"]
	var f := l / SHIN_DRAWN
	k.loft(_seg_rings(SHIN, l, SHIN_DRAWN), [MechMeshes.GREY, MechMeshes.GREY, MechMeshes.WHITE, MechMeshes.GREY])
	# Ribs down the front, a hose down the outer side.
	for i in 3:
		var y := (-0.7 - 0.1 * float(i)) * f
		var front := -0.11 - 0.29 + (y + 0.6) / -0.38 * 0.085   # the front face between the -0.6 and -0.98 rings
		k.box(Vector3(0.4, 0.05, 0.05), MechMeshes.DARK, Vector3(0, y, front + 0.012))
	var hose := [Vector3(0.3, -0.2, 0.12), Vector3(0.375, -0.56 * f, 0.04), Vector3(0.315, -0.97 * f, 0.04)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.03, 6, MechMeshes.BLACK)


## The knee pad's box in the knee cap's frame (MechModel keeps the cap upright with the hip twist: it faces the legs'
## forward whatever the thigh and shin do): [min, max]. test_torso_clearance_bulwark keeps the shin out of it.
const KNEE_PAD := [Vector3(-0.375, -0.35, -0.75), Vector3(0.375, 0.3, -0.51)]


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
	var t := LEG_T
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.05, 0.15, 0.55), MechMeshes.DARK, Vector3(sx * 0.4125, 0.0, -0.2625))
	k.box(Vector3(0.775, 0.6, 0.06), MechMeshes.DARK, Vector3(0, (lo.y + hi.y) * 0.5, hi.z - 0.03))
	k.loft([_zring(hi.z - 0.035, hi.x, lo.y, hi.y, 0.075), _zring(lo.z + 0.06, hi.x, lo.y, hi.y, 0.075),
		_zring(lo.z, hi.x - 0.075, lo.y + 0.06, hi.y - 0.06, 0.06)], MechMeshes.ORANGE)
	for sx: float in [-1.0, 1.0]:
		for y: float in [lo.y + 0.1, hi.y - 0.1]:
			k.box(Vector3(0.035, 0.035, 0.03) * t, MechMeshes.STEEL, Vector3(sx * 0.2, y, lo.z - 0.005))


## The short ankle block from the ankle drum (origin) down into the boot.
static func _ankle(k: MeshKit) -> void:
	var l: float = REST_LENGTH["tarsus"]
	k.seg(Vector3.ZERO, Vector3(0, -l + 0.03, 0), Vector2(0.18, 0.2), Vector2(0.18, 0.2), 4, MechMeshes.DARK, MeshKit.SQUARE)
	k.seg(Vector3(0, -0.08, 0), Vector3(0, -0.13, 0), Vector2(0.195, 0.215), Vector2(0.195, 0.215), 4, MechMeshes.STEEL, MeshKit.SQUARE)


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
	var t := LEG_T
	k.tube(Vector3(HIP_BALL - 0.07, 0, 0), Vector3(HIP_BALL + 0.015, 0, 0), 0.1 * t, 8, MechMeshes.DARK)
	k.tube(Vector3(HIP_BALL, 0, 0), Vector3(HIP_BALL + 0.045, 0, 0), 0.052 * t, 6, MechMeshes.STEEL)
	MechMeshes._bolt_ring(k, HIP_BALL + 0.015, 0.078 * t, 0.035, 4, 0.0)


## The hip socket (right side): a cup over the top of the ball (CUP), the strut that carries it into the pelvis. The
## strut and the fittings are the first build's, drawn LEG_T larger; the strut is kept short of the pilot's well.
static func _hip_socket(k: MeshKit) -> void:
	k.lathe(CUP, 8, [MechMeshes.GREY, MechMeshes.DARK, MechMeshes.DARK], true, true)
	var t := LEG_T
	k.seg(Vector3(-0.16, 0.37, 0) * t, Vector3(-0.56, 0.48, 0) * t, Vector2(0.16, 0.2) * t, Vector2(0.19, 0.26) * t, 4, MechMeshes.DARK, MeshKit.SQUARE)
	k.tube(Vector3(0, 0.48, 0) * t, Vector3(0, 0.54, 0) * t, 0.1 * t, 6, MechMeshes.GREY)
	k.lathe([Vector2(0.458, 0.25) * t, Vector2(0.432, 0.31) * t], 8, MechMeshes.STEEL)
	for a: float in [0.0, 90.0, 180.0, 270.0]:
		var dir := Vector3(sin(deg_to_rad(a)), 0, -cos(deg_to_rad(a)))
		if dir.x < -0.5:
			dir = Vector3(-0.7, 0, -0.7).normalized()
		k.push(Transform3D(Basis.looking_at(dir, Vector3.UP), (dir * 0.468 + Vector3(0, 0.18, 0)) * t))
		k.box(Vector3(0.055, 0.055, 0.055) * t, MechMeshes.STEEL)
		k.pop()


static func _boot_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.7:
		return MechMeshes.GREY
	return MechMeshes.DARK


## The boot (drawn FOOT_S larger): origin on the ground under the ankle drum (which sits half sunk in its top). A heavy dark block with grey
## top plates, a steel toe plate, side armour and a sole tread.
static func _boot(k: MeshKit) -> void:
	k.push(Transform3D(Basis.from_scale(Vector3.ONE * FOOT_S), Vector3.ZERO))
	k.loft([_zring(0.3, 0.27, 0.0, 0.16, 0.05), _zring(0.12, 0.31, 0.0, 0.24, 0.07), _zring(-0.12, 0.32, 0.0, 0.24, 0.07),
		_zring(-0.34, 0.3, 0.0, 0.15, 0.05)], _boot_colour)
	# White side armour plates (rule 6.3: a step, not a colour change), a steel plate across the front, a dark sole band.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.13, 0.36), MechMeshes.WHITE, Vector3(side * 0.322, 0.11, -0.0))
		k.box(Vector3(0.03, 0.04, 0.04), MechMeshes.STEEL, Vector3(side * 0.34, 0.11, 0.12))
	k.box(Vector3(0.46, 0.08, 0.04), MechMeshes.STEEL, Vector3(0, 0.1, -0.33))
	k.box(Vector3(0.62, 0.04, 0.62), MechMeshes.BLACK, Vector3(0, 0.019, -0.02))
	k.pop()


## One toe of the split clamp: root at the origin (sunk into the boot's front), its blunt nose forward on the ground.
static func _toe(k: MeshKit) -> void:
	k.push(Transform3D(Basis.from_scale(Vector3.ONE * FOOT_S), Vector3.ZERO))
	k.loft([_zring(0.02, 0.125, 0.0, 0.17, 0.04), _zring(-0.18, 0.125, 0.0, 0.15, 0.04), _zring(-0.28, 0.1, 0.0, 0.085, 0.03)],
		[MechMeshes.GREY, MechMeshes.STEEL])
	k.loft([_zring(-0.06, 0.135, 0.005, 0.175, 0.045), _zring(-0.1, 0.135, 0.005, 0.172, 0.045)], MechMeshes.DARK)
	k.box(Vector3(0.2, 0.03, 0.16), MechMeshes.BLACK, Vector3(0, 0.014, -0.12))
	k.pop()


## The heel spur: root at the origin on the boot's back, a dark clamp, a steel wedge up and back to a point.
static func _spur(k: MeshKit) -> void:
	k.push(Transform3D(Basis.from_scale(Vector3.ONE * FOOT_S), Vector3.ZERO))
	k.box(Vector3(0.24, 0.14, 0.08), MechMeshes.DARK, Vector3(0, 0.1, 0.0))
	k.seg(Vector3(0, 0.08, -0.02), Vector3(0, 0.17, 0.16), Vector2(0.09, 0.07), Vector2(0.075, 0.06), 4, MechMeshes.STEEL)
	k.seg(Vector3(0, 0.17, 0.16), Vector3(0, 0.36, 0.28), Vector2(0.075, 0.06), Vector2.ZERO, 4, MechMeshes.GREY)
	k.pop()
