class_name WaspMeshes
extends RefCounted
## The Wasp's low-poly parts (docs/design/chassis-rules.md; look pick docs/design/chassis-concepts/
## pick_wasp_tandem_compact.png "A1", without its two small rear fans: user, 2026-11-25): the light hover chassis. A compact
## chunky faceted egg pod (the Strider's torso made small: orange armour bands on the flanks, a white front and top, a
## dark grey lower hull and a dark belly, amber window lights), the pilot's head out of a round hatch ring on top, a small
## upright fin behind the hatch, and two big horizontal ducted lift fans, one each side of the cockpit at shoulder level on
## short stout struts (thick faceted guard rings with three spokes and four broad paddle blades): the silhouette's two big
## ears. Each fan sits on a gimbal ball in a cup at its strut's end, so the whole fan tilts (pitch and roll) to vector
## for steering and strafing. Three light guns, each bolted on: one on a short stub wing root on each flank under the
## fans, one on a chin turret hanging under the nose. Two mini chicken legs (a hip and a knee pin joint in a clevis under
## the belly, the Strider's foot in miniature: three toes and a spur) dangle in flight and stand when landed; they are
## coloured exactly as the Strider's legs (user: "Mirror the color scheme of the other mech with chicken feet").
##
## Same conventions and tools as MechMeshes / BulwarkMeshes (model units, faces -Z, +X its right; body parts in body space,
## drawn at BODY_SCALE; right side authored, the left mirrored). The body origin is the hull's centre (MechModel holds it
## BODY_Y model units over the ground; it banks about it). The fan parts are authored in the fan's own frame (origin on
## the gimbal ball, the ring above it, the rotor at ROTOR_Y spinning about +Y); leg parts in the joint's frame (segments
## hang along -Y from their proximal pin). Weapons, the hatch and the pilot heads are the Strider's parts, named as-is
## (ChassisParts). Files: res://assets/models/mech/wasp_<part>.res (tools/models/gen_mech_meshes.gd). Cosmetic only (no
## gameplay state).

const PREFIX := "wasp_"
const BODY_PARTS := ["wasp_hull", "wasp_nose", "wasp_fin", "wasp_strut", "wasp_fan_ring", "wasp_rotor", "wasp_stub_mount",
	"wasp_chin_mount"]
const LEG_PARTS := ["wasp_hip_socket", "wasp_hip_cap", "wasp_thigh", "wasp_knee_cap", "wasp_shin", "wasp_ankle_cap",
	"wasp_foot", "wasp_toe", "wasp_spur"]

## Body parts and weapons are drawn this much larger than authored (the Strider's: the shared weapons and the pilot keep
## their size). The legs are inside the body (they bank with the hull), so they are drawn at it too.
const BODY_SCALE := 1.2
## The body origin's height over the ground (model units at body scale param 1): where the hull hangs when the legs stand
## (they put the soles on y 0). The model's origin is that ground point; in flight the controller moves the whole model.
const BODY_Y := 1.5

# --- Hull ----------------------------------------------------------------------------------------------------
## The egg's sections front to back: [z, half width, top height, bottom height, centre y] (body units). The top half is
## a flatter superellipse (TOP_POWER) than the bottom (BOT_POWER), so the hatch ring has a broad top to sit on; the nose
## underside sweeps up so the chin turret hangs high.
## Pass 2 (user, 2026-11-26: "slightly longer front to back and just a smidge wider"): the first build's stations drawn
## HULL_LS longer and HULL_WS wider, the same heights (4.13 -> 4.67 m egg, 3.55 -> 3.94 m wide at mech scale 2).
const HULL_LS := 1.13
const HULL_WS := 1.11
const HULL := [
	[-0.86 * HULL_LS, 0.26 * HULL_WS, 0.22, 0.18, 0.0],
	[-0.80 * HULL_LS, 0.50 * HULL_WS, 0.44, 0.34, 0.0],
	[-0.66 * HULL_LS, 0.64 * HULL_WS, 0.56, 0.48, 0.0],
	[-0.42 * HULL_LS, 0.72 * HULL_WS, 0.62, 0.58, 0.0],
	[-0.10 * HULL_LS, 0.74 * HULL_WS, 0.64, 0.62, 0.0],
	[0.24 * HULL_LS, 0.72 * HULL_WS, 0.63, 0.61, 0.0],
	[0.52 * HULL_LS, 0.62 * HULL_WS, 0.56, 0.54, 0.02],
	[0.74 * HULL_LS, 0.44 * HULL_WS, 0.42, 0.38, 0.04],
	[0.86 * HULL_LS, 0.20 * HULL_WS, 0.20, 0.16, 0.05]]
const HULL_SIDES := 16
const TOP_POWER := 3.0
const BOT_POWER := 2.4

## The hatch (the Strider's collar, its centre here) and the raised coaming ring it is sunk into: an armoured annulus
## COAM_IN to COAM_OUT from COAM_BOT (buried in the hull) up to COAM_TOP, the collar's foot 4 cm into it.
const HATCH_Z := -0.18
const HATCH_Y := 0.72
const COAM_IN := 0.46
const COAM_OUT := 0.58
const COAM_BOT := 0.3
const COAM_TOP := HATCH_Y - 0.06

## The main lift fans (right one; the left is its mirror): the gimbal ball (the tilt pivot) at FAN_PIVOT, the ring above
## it (outer radius RING_OUT, inner wall RING_IN, from RING_Y0 to RING_Y1 over the ball), three spokes on its top to a
## hub, the rotor (four paddles to BLADE_R) at ROTOR_Y spinning about the fan's +Y. FAN_TILT_MAX: the tilt the geometry
## clears (rad): pitch (forward / back thrust) and roll (strafe), as an ellipse (MechModel.set_fan_tilt clamps to it).
const FAN_PIVOT := Vector3(1.19, 0.72, 0.18)
const RING_OUT := 0.61
const RING_IN := 0.47
const RING_Y0 := 0.06
const RING_Y1 := 0.32
const ROTOR_Y := 0.16
const BLADE_R := 0.43
const SPOKE_Y := 0.23
## The guard's segment clamps: RING_SEGS dark blocks wrapping the ring's outer face (the concept's segmented duct).
const RING_SEGS := 7
const FAN_TILT_MAX := Vector2(0.35, 0.26)   ## 20 deg pitch, 15 deg roll
const RING_SIDES := 14
## The strut from the hull's upper flank (its pad at STRUT_Z, STRUT_ANGLE degrees round from up) to the cup under the
## ball.
const STRUT_Z := 0.18
const STRUT_ANGLE := 50.0
const BALL_R := 0.07

## The stub wing roots (right): a flat pad on the flank at STUB_FACE_X (centred STUB_Y, STUB_Z), the mount's bolted
## flange on it, a short wing root out STUB_REACH to the block the weapon pivots on (the Strider side mount's block).
const STUB_FACE_X := 0.83
const STUB_Y := 0.0
const STUB_Z := -0.34
const STUB_REACH := Vector3(0.48, 0.0, 0.0)
## The chin turret: a block under the nose with a flat face at CHIN_PAD_Y (centred CHIN_Z), the turntable's base plate on
## it, a bearing ring and a pintle post CHIN_DROP down into the weapon.
const CHIN_Z := -0.93
const CHIN_PAD_Y := -0.42
const CHIN_DROP := 0.4
const CHIN_REACH := Vector3(0, -CHIN_DROP, 0)

## Hardpoint mount points in body space (where a weapon's origin goes).
const MOUNTS := {
	"stub_l": Vector3(-STUB_FACE_X - STUB_REACH.x, STUB_Y, STUB_Z), "stub_r": Vector3(STUB_FACE_X + STUB_REACH.x, STUB_Y, STUB_Z),
	"chin": Vector3(0, CHIN_PAD_Y - CHIN_DROP, CHIN_Z),
}
## The nose lamp cluster's attach point on the hull's front cap.
const NOSE_AT := Vector3(0, 0.02, -0.86 * HULL_LS)
## Where body parts sit in body space: [position, rotation (degrees)]. The fin, struts and the hull are authored in body
## space (the struts for the right side; MechModel mirrors them).
const LAYOUT := {
	"torso": [Vector3.ZERO, Vector3.ZERO],
	"nose": [NOSE_AT, Vector3.ZERO],
	"hatch": [Vector3(0, HATCH_Y, HATCH_Z), Vector3.ZERO],
	"fin": [Vector3.ZERO, Vector3.ZERO],
	"strut": [Vector3.ZERO, Vector3.ZERO],
}

# --- Legs ------------------------------------------------------------------------------------------------------
## The hip pin (right leg) in body space: a clevis hangs it from a pad under the belly (its face at HIP_PAD_Y).
const HIP := Vector3(0.4, -0.76, 0.07)
const HIP_PAD_Y := -0.6
## Segment lengths (body units): the thigh from the hip pin to the knee pin, the shin from the knee to the ankle pin; the
## ankle pin sits FOOT_H over the sole.
const THIGH_L := 0.3
const SHIN_L := 0.34
const FOOT_H := 0.14
## The thigh's and the shin's thickness (pass 2: 1.35x the first build's, so the mini legs stop reading spindly): the
## thickest section across, and the shin's foot end. Rule 3.3 reads them.
const THIGH_THICK := 0.216
const SHIN_FOOT_THICK := 0.13
## Joint drums: [radius, half width, hub half length] (rule 3.3: radius >= 0.55 x the thicker segment it joins).
const HIP_DRUM := Vector3(0.12, 0.07, 0.09)
const KNEE_DRUM := Vector3(0.12, 0.08, 0.1)
const ANKLE_DRUM := Vector3(0.09, 0.06, 0.075)
## The clevis cheeks' inner faces (either side of the hip drum, its step ring and bolts).
const CLEVIS_IN := 0.13
## The two poses (rad): thigh = angle of the thigh back from straight down (the knee points back), shin = angle of the shin
## forward from straight down, foot = the sole's pitch (negative = toes down). Standing is solved (stand_angles): the
## ankle under the hip, STAND_DZ ahead of it, the sole on the ground. Dangling (pass 2, tidier): both legs in their own
## parallel planes, knees bent alike, the feet tucked a little and hanging almost level (toes only slightly down).
const DANGLE := Vector3(0.9, 1.25, -0.15)
const STAND_DZ := -0.06
## Declared joint ranges (rad), every pose between dangle and stand inside them (tests/test_clearance_wasp.gd sweeps them):
## thigh, knee bend (thigh + shin), foot pitch.
const THIGH_RANGE := Vector2(0.6, 1.0)
const KNEE_RANGE := Vector2(1.5, 2.2)
const FOOT_RANGE := Vector2(-0.7, 0.05)
## The foot: the Strider's hub, toes and spur drawn FOOT_S as large (the Strider's toe layout, scaled).
const FOOT_S := 0.56
const TOES := [[Vector3(-0.13, 0, -0.16) * FOOT_S, 27.0], [Vector3(0, 0, -0.21) * FOOT_S, 0.0], [Vector3(0.13, 0, -0.16) * FOOT_S, -27.0]]
const SPUR_ROOT := Vector3(0, 0, 0.17) * FOOT_S

const WHITE := MechMeshes.WHITE
const ORANGE := MechMeshes.ORANGE
const GREY := MechMeshes.GREY
const DARK := MechMeshes.DARK
const STEEL := MechMeshes.STEEL
const GUN := MechMeshes.GUN
const BLACK := MechMeshes.BLACK
const AMBER := MechMeshes.AMBER

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


static func build(part: String) -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = ORANGE
	match part:
		"wasp_hull": _hull(k)
		"wasp_nose": _nose(k)
		"wasp_fin": _fin(k)
		"wasp_strut": _strut(k)
		"wasp_fan_ring": _fan_ring(k)
		"wasp_rotor": _rotor(k)
		"wasp_stub_mount": _stub_mount(k)
		"wasp_chin_mount": _chin_mount(k)
		"wasp_hip_socket": _hip_socket(k)
		"wasp_hip_cap": MechMeshes._cap(k, HIP_DRUM.x, HIP_DRUM.y, HIP_DRUM.z)
		"wasp_thigh": _thigh(k)
		"wasp_knee_cap": MechMeshes._cap(k, KNEE_DRUM.x, KNEE_DRUM.y, KNEE_DRUM.z)
		"wasp_shin": _shin(k)
		"wasp_ankle_cap": MechMeshes._cap(k, ANKLE_DRUM.x, ANKLE_DRUM.y, ANKLE_DRUM.z)
		"wasp_foot": _scaled(k, FOOT_S, MechMeshes._foot)
		"wasp_toe": _scaled(k, FOOT_S, _toe)
		"wasp_spur": _scaled(k, FOOT_S, MechMeshes._spur)
	return k.commit(MechMeshes.materials())


static func _scaled(k: MeshKit, s: float, f: Callable) -> void:
	k.push(Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3.ZERO))
	f.call(k)
	k.pop()


## The hull's primary mass only (the egg and the coaming): the clearance tests keep the fans, legs and guns off it.
static func hull_shell() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = ORANGE
	k.loft(_hull_rings(), _hull_colour)
	_coaming(k)
	return k.commit(MechMeshes.materials())


## The hull volume grown for the hardpoints and joints (strut, stub, hip and chin pads).
static func hardpoint_pads() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = ORANGE
	_pads(k)
	return k.commit(MechMeshes.materials())


## The coaming alone (every pilot head clears it).
static func coaming() -> ArrayMesh:
	var k := MeshKit.new()
	k.accent_key = ORANGE
	_coaming(k)
	return k.commit(MechMeshes.materials())


# --- The hull ------------------------------------------------------------------------------------------------

static func _hull_ring(s: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for k in HULL_SIDES:
		var a := TAU * (float(k) + 0.5) / float(HULL_SIDES)
		var su := sin(a)
		var cv := cos(a)
		var e := 2.0 / (TOP_POWER if cv > 0.0 else BOT_POWER)
		var ry: float = s[2] if cv > 0.0 else s[3]
		out.append(Vector3(float(s[1]) * signf(su) * pow(absf(su), e), float(s[4]) + ry * signf(cv) * pow(absf(cv), e), s[0]))
	return out


static func _hull_rings() -> Array:
	var rings: Array = []
	for s: Array in HULL:
		rings.append(_hull_ring(s))
	return rings


## A point on the hull's faceted skin and its outward normal: [point, normal] at z and `angle` degrees round Z from up
## toward +X (negative = left; the left is the mirror of the right).
static func hull_at(z: float, angle: float) -> Array:
	var am := fposmod(angle, 360.0)
	if am > 180.0:
		var r := hull_at(z, 360.0 - am)
		return [(r[0] as Vector3) * Vector3(-1, 1, 1), (r[1] as Vector3) * Vector3(-1, 1, 1)]
	var i := 0
	while i < HULL.size() - 2 and z > float(HULL[i + 1][0]):
		i += 1
	var ra := _hull_ring(HULL[i])
	var rb := _hull_ring(HULL[i + 1])
	var t := clampf((z - float(HULL[i][0])) / (float(HULL[i + 1][0]) - float(HULL[i][0])), 0.0, 1.0)
	var f := am / 360.0 * float(HULL_SIDES) - 0.5
	var k := floori(f)
	var u := f - float(k)
	k = posmod(k, HULL_SIDES)
	var k2 := (k + 1) % HULL_SIDES
	var pa := ra[k].lerp(ra[k2], u)
	var pb := rb[k].lerp(rb[k2], u)
	var p := pa.lerp(pb, t)
	var n := (ra[k2] - ra[k]).lerp(rb[k2] - rb[k], t).cross(pb - pa).normalized()
	if n.dot(p - Vector3(0, float(HULL[i][4]), z)) < 0.0:
		n = -n
	return [p, n]


## A frame on the hull skin at (z, angle): local -Z along the facet normal, pushed out `lift`.
static func _on_hull(z: float, angle: float, lift: float) -> Transform3D:
	var pn := hull_at(z, angle)
	var n: Vector3 = pn[1]
	return Transform3D(Basis.looking_at(n, Vector3.UP if absf(n.y) < 0.95 else Vector3.FORWARD), (pn[0] as Vector3) + n * lift)


static func _hull_box(k: MeshKit, z: float, angle: float, lift: float, size: Vector3, col: Variant) -> void:
	k.push(_on_hull(z, angle, lift))
	k.box(size, col)
	k.pop()


## The A1 egg's read (pass 2): a dark belly, dark grey only for the lower hull, a grey tail cap; broad orange armour on the
## flanks and shoulders, wrapping round onto the front's sides; white for the top round the hatch and a centre panel down
## the front.
static func _hull_colour(c: Vector3, n: Vector3) -> Color:
	if n.y < -0.75:
		return DARK
	if n.z < -0.55 and absf(n.x) < 0.36:
		return WHITE   # the white centre panel runs down the front to the nose's lamp cluster
	if n.y < -0.42:
		return GREY
	if n.z > 0.85:
		return GREY
	if absf(n.x) > 0.36 and c.z < 0.8 * HULL_LS:
		return ORANGE
	return WHITE


static func _coaming_colour(_c: Vector3, n: Vector3) -> Color:
	if n.y > 0.5:
		return GREY
	if n.y < -0.5:
		return DARK
	return WHITE


static func _coaming(k: MeshKit) -> void:
	BulwarkMeshes._annulus(k, Vector3(0, 0, HATCH_Z), [Vector2(COAM_IN, COAM_BOT), Vector2(COAM_OUT, COAM_BOT),
		Vector2(COAM_OUT, COAM_TOP - 0.035), Vector2(COAM_OUT - 0.04, COAM_TOP), Vector2(COAM_IN, COAM_TOP)], 16, _coaming_colour)


## An amber window light in a dark frame on the hull skin.
static func _window(k: MeshKit, z: float, angle: float, w: float, h: float) -> void:
	_hull_box(k, z, angle, 0.0, Vector3(w + 0.05, h + 0.05, 0.05), DARK)
	k.glow = true
	_hull_box(k, z, angle, 0.012, Vector3(w, h, 0.05), AMBER)
	k.glow = false


static func _hull(k: MeshKit) -> void:
	k.loft(_hull_rings(), _hull_colour)
	_coaming(k)
	for side: float in [-1.0, 1.0]:
		# The window lights: two stacked on each front flank, a long one on the rear flank.
		var ls := HULL_LS
		_window(k, -0.62 * ls, side * 62.0, 0.12, 0.07)
		_window(k, -0.62 * ls, side * 78.0, 0.12, 0.07)
		_window(k, 0.42 * ls, side * 74.0, 0.16, 0.06)
		# A dark seam between the orange armour and the grey lower hull, a grey vent behind the stub pad.
		_hull_box(k, 0.0, side * 113.0, 0.0, Vector3(1.0, 0.04, 0.05), DARK)
		_hull_box(k, 0.1 * ls, side * 92.0, 0.0, Vector3(0.18, 0.12, 0.05), GREY)
		for z: float in [0.06, 0.1, 0.14]:
			_hull_box(k, z * ls, side * 92.0, 0.01, Vector3(0.025, 0.1, 0.05), DARK)
		# Tail lights.
		k.glow = true
		_hull_box(k, 0.8 * ls, side * 50.0, 0.01, Vector3(0.08, 0.05, 0.05), AMBER)
		k.glow = false
		_hull_box(k, 0.8 * ls, side * 50.0, 0.0, Vector3(0.12, 0.09, 0.05), DARK)
	# The round port on the white front, in a grey bezel; a dark grille on the tail cap.
	k.push(_on_hull(-0.7 * HULL_LS, 0.0, 0.0))
	k.tube(Vector3(0, 0, 0.02), Vector3(0, 0, -0.025), 0.12, 8, GREY)
	k.tube(Vector3(0, 0, 0.0), Vector3(0, 0, -0.04), 0.085, 8, DARK)
	k.pop()
	_hull_box(k, 0.82 * HULL_LS, 180.0 - 30.0, 0.0, Vector3(0.14, 0.1, 0.05), DARK)
	_hull_box(k, 0.82 * HULL_LS, 180.0 + 30.0, 0.0, Vector3(0.14, 0.1, 0.05), DARK)
	# The belly: a dark access plate, two ribs, an amber belly light.
	_hull_box(k, 0.44, 180.0, 0.0, Vector3(0.36, 0.3, 0.05), BLACK)
	for z: float in [-0.3, 0.62]:
		_hull_box(k, z, 180.0, 0.0, Vector3(0.5, 0.06, 0.06), GREY)
	k.glow = true
	_hull_box(k, -0.55, 180.0, 0.01, Vector3(0.12, 0.05, 0.05), AMBER)
	k.glow = false
	_pads(k)


# --- Hardpoint and joint pads --------------------------------------------------------------------------------

## A frame whose +Z is `n` (the pad face's outward normal) with +Y toward `up`, at p.
static func pad_frame(p: Vector3, n: Vector3, up: Vector3) -> Transform3D:
	var x := up.cross(n).normalized()
	var y := n.cross(x)
	return Transform3D(Basis(x, y, n), p)


## A chamfered pad: a flat face at p facing n (half sizes `half`, across x and y of pad_frame), its body `depth` deep into
## the hull, a dark face and grey sides.
static func _pad(k: MeshKit, p: Vector3, n: Vector3, up: Vector3, half: Vector2, depth: float) -> void:
	var col := func(_c: Vector3, nn: Vector3) -> Color: return DARK if nn.dot(n) > 0.9 else GREY
	k.push(pad_frame(p, n, up))
	k.loft([BulwarkMeshes._zring(-depth, half.x + 0.015, -half.y - 0.015, half.y + 0.015, 0.03),
		BulwarkMeshes._zring(0.0, half.x, -half.y, half.y, 0.03)], col)
	k.pop()


## The strut's pad face (right): [point, normal].
static func strut_seat() -> Array:
	var pn := hull_at(STRUT_Z, STRUT_ANGLE)
	var n: Vector3 = pn[1]
	return [(pn[0] as Vector3) + n * 0.03, n]


static func _pads(k: MeshKit) -> void:
	var ss := strut_seat()
	for side: float in [-1.0, 1.0]:
		var m := Vector3(side, 1, 1)
		_pad(k, (ss[0] as Vector3) * m, (ss[1] as Vector3) * m, Vector3.FORWARD, Vector2(0.11, 0.11), 0.16)
		_pad(k, Vector3(side * STUB_FACE_X, STUB_Y, STUB_Z), Vector3(side, 0, 0), Vector3.UP, Vector2(0.17, 0.13), 0.16)
		_pad(k, Vector3(side * HIP.x, HIP_PAD_Y, HIP.z), Vector3.DOWN, Vector3.FORWARD, Vector2(0.19, 0.14), 0.12)
	_pad(k, Vector3(0, CHIN_PAD_Y, CHIN_Z), Vector3.DOWN, Vector3.FORWARD, Vector2(0.13, 0.13), 0.18)


# --- Body parts ----------------------------------------------------------------------------------------------

## The nose (origin on the hull's front cap): a grey housing with the sensor port (bezel, bolts, amber lens), two amber
## lamps each side and a visor hood: the family's nose.
static func _nose(k: MeshKit) -> void:
	k.loft([BulwarkMeshes._oct(0.03, 0.2, -0.11, 0.11, 0.035, 0.035), BulwarkMeshes._oct(-0.06, 0.17, -0.09, 0.09, 0.035, 0.035)], GREY)
	var c := Vector3(0, 0.0, -0.06)
	k.tube(c, c + Vector3(0, 0, -0.04), 0.075, 8, DARK)
	k.tube(c + Vector3(0, 0, -0.04), c + Vector3(0, 0, -0.065), 0.048, 8, GUN)
	k.glow = true
	k.tube(c + Vector3(0, 0, -0.065), c + Vector3(0, 0, -0.085), 0.028, 6, AMBER)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.045, 0.035, 0.03), AMBER, Vector3(side * 0.125, -0.03, -0.07))
	k.glow = false
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.06, 0.025), DARK, Vector3(side * 0.125, -0.03, -0.065))
	for i in 6:
		var a := TAU * (float(i) + 0.5) / 6.0
		k.box(Vector3(0.025, 0.025, 0.025), STEEL, c + Vector3(sin(a) * 0.085, cos(a) * 0.085, -0.005))
	k.box(Vector3(0.2, 0.03, 0.06), DARK, c + Vector3(0, 0.095, -0.01))


## The small upright fin on the back behind the hatch (body space): a swept slab, white with an orange tip, its foot buried
## in the hull, an amber light on its trailing edge.
static func _fin(k: MeshKit) -> void:
	# Pass 2: taller and thicker, further back on the longer hull, so it shows over the hull behind the head in the chase
	# view.
	var prof := [Vector2(0.4, 0.44), Vector2(0.84, 0.44), Vector2(0.84, 1.18), Vector2(0.72, 1.24), Vector2(0.48, 0.66)]
	var rings: Array = []
	for x: float in [-0.05, 0.05]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(x, p.y, p.x))
		rings.append(r)
	k.loft(rings, func(c: Vector3, _n: Vector3) -> Color: return ORANGE if c.y > 1.04 else WHITE)
	k.box(Vector3(0.12, 0.09, 0.06), DARK, Vector3(0, 1.0, 0.845))
	k.glow = true
	k.box(Vector3(0.07, 0.055, 0.03), AMBER, Vector3(0, 1.0, 0.87))
	k.glow = false
	k.box(Vector3(0.14, 0.06, 0.36), GREY, Vector3(0, 0.5, 0.64))
	for y: float in [0.72, 0.86]:   # two dark panel lines across the fin
		k.box(Vector3(0.11, 0.025, 0.2), DARK, Vector3(0, y, 0.72))


## The right fan strut (body space): a bolted flange on its pad on the hull's upper flank, a stout square arm out and up
## to the cup the fan's gimbal ball sits in (a dark cup with a steel rim), a hydraulic line along it.
static func _strut(k: MeshKit) -> void:
	var ss := strut_seat()
	var p: Vector3 = ss[0]
	var n: Vector3 = ss[1]
	k.push(pad_frame(p, n, Vector3.FORWARD))
	k.box(Vector3(0.2, 0.2, 0.05), DARK, Vector3(0, 0, 0.015))
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			k.box(Vector3(0.035, 0.035, 0.03), STEEL, Vector3(sx * 0.07, sy * 0.07, 0.045))
	k.pop()
	var cup := FAN_PIVOT + Vector3(0, -0.035, 0)
	var e := FAN_PIVOT + Vector3(0, -0.11, 0)
	k.seg(p + n * 0.02, e, Vector2(0.065, 0.06), Vector2(0.055, 0.055), 4, GREY, MeshKit.SQUARE)
	k.tube(e + Vector3(0, -0.03, 0), cup, 0.09, 8, DARK)
	k.tube(cup + Vector3(0, -0.03, 0), cup, 0.1, 8, STEEL)
	k.box(Vector3(0.1, 0.03, 0.08), ORANGE, (p + e) * 0.5 + Vector3(0, 0.065, 0))
	var hose := [p + n * 0.05 + Vector3(0, 0, 0.07), (p + e) * 0.5 + Vector3(0, 0.0, 0.075), e + Vector3(-0.04, 0.0, 0.07)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.016, 6, BLACK)


static func _ring_colour(c: Vector3, n: Vector3) -> Color:
	if Vector2(n.x, n.z).dot(Vector2(-c.x, -c.z)) > 0.1 and absf(n.y) < 0.5:
		return DARK   # the duct's inner wall
	return GREY


## The main fan (its own frame: origin on the gimbal ball): the gimbal ball, a motor housing up to the rotor, the thick
## faceted guard ring with chamfered edges and the accent band round its outer face (the Wasp's team-colour read, rule
## 6.5), lugs on its rim, three broad spokes across its top to a hub over the rotor.
static func _fan_ring(k: MeshKit) -> void:
	k.ico(Vector3.ZERO, Vector3.ONE * BALL_R, STEEL)
	k.tube(Vector3(0, 0.03, 0), Vector3(0, 0.13, 0), 0.085, 8, GREY)
	k.tube(Vector3(0, 0.06, 0), Vector3(0, 0.085, 0), 0.095, 8, STEEL)
	var y0 := RING_Y0
	var y1 := RING_Y1
	BulwarkMeshes._annulus(k, Vector3.ZERO, [Vector2(RING_IN, y0), Vector2(RING_OUT - 0.03, y0), Vector2(RING_OUT, y0 + 0.04),
		Vector2(RING_OUT, y1 - 0.04), Vector2(RING_OUT - 0.03, y1), Vector2(RING_IN, y1)], RING_SIDES, _ring_colour)
	var ym := (y0 + y1) * 0.5
	BulwarkMeshes._annulus(k, Vector3.ZERO, [Vector2(RING_OUT - 0.04, ym - 0.045), Vector2(RING_OUT + 0.018, ym - 0.045),
		Vector2(RING_OUT + 0.018, ym + 0.045), Vector2(RING_OUT - 0.04, ym + 0.045)], RING_SIDES, ORANGE)
	# The segment clamps: dark blocks wrapping the ring's outer face over the band, top to bottom (the concept's segmented
	# guard), between the spokes.
	for i in RING_SEGS:
		var a := TAU * (float(i) + 0.5) / float(RING_SEGS)
		var r := RING_OUT
		k.push(Transform3D(Basis(Vector3.UP, a), Vector3(sin(a) * r, ym, cos(a) * r)))
		k.box(Vector3(0.09, y1 - y0 + 0.02, 0.06), DARK)
		k.pop()
	# Three spokes to the hub over the rotor.
	for i in 3:
		var a := TAU * float(i) / 3.0 + PI / 6.0
		k.push(Transform3D(Basis(Vector3.UP, a), Vector3.ZERO))
		k.box(Vector3(0.07, 0.04, RING_IN - 0.05), GREY, Vector3(0, SPOKE_Y + 0.02, (RING_IN + 0.08) * 0.5))
		k.pop()
	k.tube(Vector3(0, 0.19, 0), Vector3(0, 0.28, 0), 0.075, 8, DARK)
	k.tube(Vector3(0, 0.27, 0), Vector3(0, 0.3, 0), 0.05, 8, STEEL)


## The rotor (frame: its hub's centre, spinning about +Y): a dark hub with a steel cap under it and four broad pitched
## paddle blades with white tips (so the spin reads).
static func _rotor(k: MeshKit) -> void:
	k.tube(Vector3(0, -0.045, 0), Vector3(0, 0.045, 0), 0.1, 8, DARK)
	k.tube(Vector3(0, -0.07, 0), Vector3(0, -0.04, 0), 0.06, 8, STEEL)
	for i in 4:
		var a := TAU * float(i) / 4.0
		k.push(Transform3D(Basis(Vector3.UP, a) * Basis(Vector3.RIGHT, 0.21), Vector3.ZERO))
		k.seg(Vector3(0.08, 0, 0), Vector3(BLADE_R - 0.06, 0, 0), Vector2(0.015, 0.08), Vector2(0.015, 0.07), 4, STEEL, MeshKit.SQUARE)
		k.seg(Vector3(BLADE_R - 0.07, 0, 0), Vector3(BLADE_R, 0, 0), Vector2(0.017, 0.072), Vector2(0.017, 0.058), 4, WHITE, MeshKit.SQUARE)
		k.pop()


## A stub mount (right side; origin on the stub pad's face, the weapon's origin STUB_REACH straight out): a bolted dark
## flange with an orange rim, a short flat wing root out to the block the weapon pivots on (the Strider side mount's block,
## jaws, pivot pin and plate), a cable.
static func _stub_mount(k: MeshKit) -> void:
	var reach := STUB_REACH
	k.box(Vector3(0.05, 0.24, 0.3), DARK, Vector3(0.015, 0, 0))
	k.box(Vector3(0.03, 0.27, 0.33), ORANGE, Vector3(0.01, 0, 0))
	for sy: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.03, 0.035, 0.035), STEEL, Vector3(0.045, sy * 0.085, sz * 0.11))
	k.seg(Vector3(0.03, 0, 0), reach - Vector3(0.04, 0, 0), Vector2(0.06, 0.13), Vector2(0.045, 0.095), 4, GREY, MeshKit.SQUARE)
	k.box(Vector3(0.1, 0.16, 0.2), DARK, reach)
	for sz: float in [-1.0, 1.0]:
		k.box(Vector3(0.085, 0.12, 0.035), STEEL, reach + Vector3(0, 0, sz * 0.115))
	k.tube(reach, reach + Vector3(0, 0.11, 0), 0.045, 6, STEEL)
	k.box(Vector3(0.14, 0.035, 0.17), ORANGE, reach + Vector3(-0.01, -0.095, 0))
	var hose := [Vector3(0.05, -0.1, 0.13), Vector3(0.16, -0.07, 0.1), Vector3(0.26, -0.05, 0.08)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.02, 6, BLACK)


## The chin turret (origin on the chin pad's face, the weapon's origin CHIN_REACH straight down): a dark base plate sunk
## 5 mm into the pad with four bolts, a grey bearing ring with an orange rim, a steel pintle post down into the weapon with
## a dark collar and an end cap (finished when the hardpoint is empty), a feed cable.
static func _chin_mount(k: MeshKit) -> void:
	k.tube(Vector3(0, 0.005, 0), Vector3(0, -0.035, 0), 0.12, 8, DARK)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		k.box(Vector3(0.025, 0.025, 0.025), STEEL, Vector3(sin(a) * 0.095, -0.04, cos(a) * 0.095))
	k.tube(Vector3(0, -0.035, 0), Vector3(0, -0.085, 0), 0.14, 10, GREY)
	k.tube(Vector3(0, -0.045, 0), Vector3(0, -0.075, 0), 0.155, 10, ORANGE)
	var end := CHIN_REACH.y + 0.07
	k.tube(Vector3(0, -0.085, 0), Vector3(0, end, 0), 0.045, 8, STEEL)
	k.tube(Vector3(0, -0.085, 0), Vector3(0, -0.115, 0), 0.07, 8, DARK)
	k.tube(Vector3(0, end + 0.02, 0), Vector3(0, end, 0), 0.06, 8, DARK)
	var hose := [Vector3(-0.12, -0.07, 0.07), Vector3(-0.09, -0.15, 0.08), Vector3(-0.045, -0.2, 0.05)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.018, 6, BLACK)


# --- Legs (coloured as the Strider's: MechMeshes._thigh / _shin / _hip_socket / _cap / _foot / _toe / _spur) -----

## The hip clevis (right leg; origin on the hip pin): a grey top plate on the belly pad (sunk 5 mm into it) with four steel
## bolts, two dark cheeks hanging either side of the hip drum, a steel axle through them with caps.
static func _hip_socket(k: MeshKit) -> void:
	var top := HIP_PAD_Y - HIP.y
	k.box(Vector3(0.38, 0.04, 0.28), GREY, Vector3(0, top - 0.015, 0))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.03, 0.03, 0.03), STEEL, Vector3(sx * 0.165, top - 0.04, sz * 0.1))
		var x := sx * (CLEVIS_IN + 0.02)
		k.box(Vector3(0.04, top + 0.08, 0.26), DARK, Vector3(x, (top - 0.08) * 0.5, 0))
		k.tube(Vector3(x + sx * 0.02, 0, 0), Vector3(x + sx * 0.04, 0, 0), 0.06, 8, STEEL)
	k.tube(Vector3(-(CLEVIS_IN + 0.04), 0, 0), Vector3(CLEVIS_IN + 0.04, 0, 0), 0.03, 6, STEEL)


static func _thigh_colour(c: Vector3, n: Vector3) -> Color:
	if c.y < -0.8 * THIGH_L:
		return GREY
	if n.x < -0.75:
		return GREY                         # the inner face
	if n.x > 0.6 and c.y < -0.3333 * THIGH_L and c.z > 0.0:
		return ORANGE                       # the unit mark on the outer face
	return WHITE


## The thigh: hip pin (origin) down to the knee pin: a white armoured pod (grey inner face and lower end, the orange unit
## mark and plate on the outer face), a dark panel line across the front, steel bolts. Pass 2: 1.35x thicker
## (THIGH_THICK across its biggest section).
static func _thigh(k: MeshKit) -> void:
	var l := THIGH_L
	var spec := [[0.0, 0.068, 0.074], [-0.05, 0.095, 0.1], [-0.15, 0.1, 0.108], [-0.24, 0.088, 0.095], [-l + 0.01, 0.06, 0.068]]
	var rings: Array = []
	for s: Array in spec:
		rings.append(MeshKit.ring(Vector3(0, s[0], 0), s[1], s[2], 8, "y", 2.4))
	k.loft(rings, _thigh_colour)
	k.box(Vector3(0.03, 0.12, 0.1), ORANGE, Vector3(0.106, -0.15, 0.0))
	for y: float in [-0.1, -0.2]:
		k.box(Vector3(0.025, 0.025, 0.025), STEEL, Vector3(0.123, y, 0.035))
	k.box(Vector3(0.15, 0.025, 0.03), DARK, Vector3(0, -0.12, -0.106))


## The shin strut: knee pin (origin) down to the ankle: a grey square strut with dark ribs down its front framed by steel
## rails, a dark piston cylinder behind with an orange band and a steel rod, a black hose down the outer side. Pass 2:
## 1.35x thicker (SHIN_FOOT_THICK at its foot end).
static func _shin(k: MeshKit) -> void:
	var l := SHIN_L
	k.seg(Vector3.ZERO, Vector3(0, -l, 0), Vector2(0.068, 0.078), Vector2(0.054, 0.065), 4, GREY, MeshKit.SQUARE)
	for i in 3:
		k.box(Vector3(0.13, 0.03, 0.035), DARK, Vector3(0, -(0.1 + float(i) * 0.07), -0.074 + float(i) * 0.003))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.025, 0.22, 0.03), STEEL, Vector3(side * 0.072, -0.17, -0.072))
	var pa := Vector3(0, -0.06, 0.1)
	var pb := Vector3(0, -0.18, 0.093)
	k.tube(pa, pb, 0.034, 6, DARK)
	k.tube(pb, Vector3(0, -l + 0.07, 0.082), 0.022, 6, STEEL)
	k.tube(pa.lerp(pb, 0.7), pa.lerp(pb, 0.9), 0.041, 6, ORANGE)
	k.box(Vector3(0.07, 0.045, 0.06), DARK, pa + Vector3(0, 0.0, -0.012))
	var hose := [Vector3(0.068, -0.03, 0.055), Vector3(0.08, -0.15, 0.03), Vector3(0.066, -l + 0.07, 0.04)]
	for i in hose.size() - 1:
		k.tube(hose[i], hose[i + 1], 0.013, 6, BLACK)


## One toe (drawn at the Strider's size, FOOT_S applied by build): MechMeshes._toe's shape and colours (steel, a grey tip,
## dark knuckle bands, a gun-metal claw, a dark pad), the pad made thick enough to survive the scale (rule 6.7).
static func _toe(k: MeshKit) -> void:
	k.loft([MeshKit.ring(Vector3(0, 0.135, 0.06), 0.125, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.16, -0.32), 0.15, 0.155, 5, "z"),
		MeshKit.ring(Vector3(0, 0.14, -0.5), 0.13, 0.13, 5, "z"), MeshKit.ring(Vector3(0, 0.1, -0.8), 0.1, 0.095, 5, "z"),
		MeshKit.ring(Vector3(0, 0.005, -1.12), 0.0, 0.0, 5, "z")], [STEEL, STEEL, STEEL, GREY])
	k.loft([MeshKit.ring(Vector3(0, 0.172, -0.3), 0.168, 0.168, 5, "z"), MeshKit.ring(Vector3(0, 0.17, -0.36), 0.166, 0.166, 5, "z")], DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.136, -0.6), 0.134, 0.133, 5, "z"), MeshKit.ring(Vector3(0, 0.131, -0.65), 0.13, 0.129, 5, "z")], DARK)
	k.loft([MeshKit.ring(Vector3(0, 0.112, -0.78), 0.11, 0.108, 5, "z"), MeshKit.ring(Vector3(0, 0.01, -1.14), 0.0, 0.0, 5, "z")], GUN)
	k.box(Vector3(0.15, 0.065, 0.26), DARK, Vector3(0, 0.0345, -0.12))


## The standing pose's joint angles: Vector2(thigh, shin) (rad, DANGLE's convention) that put the ankle pin STAND_DZ ahead
## of the hip and FOOT_H over the ground (the model's origin, BODY_Y under the body origin), the knee pointing back.
static func stand_angles() -> Vector2:
	var ground := -BODY_Y / BODY_SCALE
	var ankle := Vector2(HIP.z + STAND_DZ, ground + FOOT_H)   # (z, y)
	var hip := Vector2(HIP.z, HIP.y)
	var d := ankle - hip
	var dist := d.length()
	var t := THIGH_L
	var s := SHIN_L
	var alpha := acos(clampf((t * t + dist * dist - s * s) / (2.0 * t * dist), -1.0, 1.0))
	var line := atan2(d.x, -d.y)                       # the hip-to-ankle line, + = back of straight down
	var thigh := line + alpha                          # the knee goes back
	var knee := hip + Vector2(t * sin(thigh), -t * cos(thigh))
	var sd := ankle - knee
	return Vector2(thigh, atan2(-sd.x, -sd.y))         # the shin, + = forward of straight down


## The leg's joint angles at pose t (0 dangle .. 1 stand): Vector3(thigh, shin, foot pitch).
static func leg_angles(t: float) -> Vector3:
	var st := stand_angles()
	var u := clampf(t, 0.0, 1.0)
	return Vector3(lerpf(DANGLE.x, st.x, u), lerpf(DANGLE.y, st.y, u), lerpf(DANGLE.z, 0.0, u))
