class_name PilotHeadPickle
extends PilotFace
## The pickle pilot (art/picks/head_pickle.png), rigged: the static MechHeadMeshes pickle's sections as one body mesh
## (PilotFace.add_body; same girth, nose, warts and stern brow at rest), plus lids, moving pupils on a white-ringed green eye, the mouth
## line split into two half bars hinged at the centre (MouthL / MouthR: mouth_curve turns the corners up / down,
## brow_skew makes it lopsided) and a lip plate under it (Jaw) that drops to show a dark mouth.
## No appendages: the flair is the whole body as jelly. The neck's flair spring drives the Skull's scale and shear
## (pose_neck): raised = stretched tall and narrow, dropped = sagging short and wide, and the low-damped spring makes it
## wobble after every head movement. Four warts ride on the pendulum spring (plus a share of the jelly), each with its
## own gain so they do not move in unison. The neck bends at the base (a blob on a stalk, not a neck), slow and heavy.
## Tics: a slow wobble that settles, a wart twitch, a long suspicious squint to one side.

const GREEN := Color(0.4, 0.55, 0.2)
const IRIS := Color(0.3, 0.42, 0.12)
const PUPIL := Color(0.06, 0.07, 0.04)
const MOUTH := Color(0.12, 0.1, 0.05)
## Body sections [y, centre z, half width, half depth] (as MechHeadMeshes._pickle).
const SECS := [[0.0, 0.0, 0.27, 0.27], [0.16, 0.0, 0.33, 0.33], [0.5, 0.0, 0.35, 0.35], [0.85, 0.0, 0.35, 0.35],
	[1.1, 0.0, 0.3, 0.3], [1.24, 0.0, 0.17, 0.17]]
## Warts [x, y, z] (as MechHeadMeshes._pickle) and their gains on the pendulum / jelly springs.
const WARTS := [[0.33, 0.95, -0.12], [-0.34, 0.6, 0.05], [0.3, 0.3, -0.16], [-0.26, 1.02, -0.2]]
const WART_PEND := [1.0, -0.8, 1.3, -1.1]
const WART_JELLY := [0.4, 0.7, -0.5, 0.9]
## Jelly: flair hinge pitch (rad) that means full stretch, height change at full stretch, shear per rad of flair roll.
const JELLY_REF := 0.35
const STRETCH := 0.14
const SHEAR := 0.55
## Mouth corners: degrees per unit of mouth_curve, and the brow_skew share that makes them lopsided.
const MOUTH_TURN := 24.0
const MOUTH_SKEW := 0.5
## The face plane is the octagon's front flat: z = -FLAT * radius.
const FLAT := 0.9239
## The lip plate slides straight down the face this far at jaw = 1 (a hinge would swing it off the flat face).
const JAW_DROP := 0.09



func _init() -> void:
	id = "pickle"
	# The stalk and the body's bottom band take the bend (the stalk's top ring halfway); from the 0.5 ring up the body is rigid.
	body_bend = Vector2(0.0, 0.32)
	var g := float(MechHeadMeshes.GIRTH.get("pickle", 1.0))
	girth = Vector3(g, 1.0, g)
	pendulums = 1
	flair_pieces = ["Wart0", "Wart1", "Wart2", "Wart3"]
	# Heavy and jelly-slow: a soft, under-damped neck that lags acceleration, a slower jelly spring that trails hard.
	style = {"hz": 2.2, "damping": 0.36, "upper": 0.8, "accel_gain": 0.03, "flair_hz": 1.3, "flair_damping": 0.45,
		"flair_inertia": 1.4, "pend_hz": 4.5, "pend_damping": 0.2,
		"flair_raise": Vector2(-JELLY_REF, 0.0), "flair_drop": Vector2(JELLY_REF, deg_to_rad(6.0))}
	squash_width = 0.6
	# Heavy lids: slower blinks.
	overrides = {"reactions": {"blink": {"a": 0.06, "h": 0.04, "r": 0.1}}}
	tics = [
		{"id": "wobble", "kind": "shake", "dur": 2.8, "hz": 1.0, "neck": Vector3(0.0, 0.0, 4.0),
			"flair": Vector2(10.0, 14.0)},
		{"id": "wart_twitch", "kind": "shake", "dur": 0.4, "hz": 8.0, "neck": Vector3.ZERO, "flair": Vector2(0.0, 3.0)},
		{"id": "squint", "kind": "pulse", "a": 0.5, "h": 1.8, "r": 0.6, "neck": Vector3(-3.0, 18.0, -4.0),
			"ch": {"lid": 0.35, "brow_anger": 0.15, "brow_skew": 0.3, "gaze_x": -0.8, "mouth_curve": -0.2}},
	]


func build_pieces() -> void:
	# The neck bends at the base: NeckLow is the stalk, NeckHigh a bare joint, the Skull (the jelly) everything above it.
	add_piece("NeckLow", "", Vector3.ZERO)
	add_piece("NeckHigh", "NeckLow", Vector3(0.0, 0.16, 0.0))
	add_piece("Skull", "NeckHigh", Vector3(0.0, 0.16, 0.0))
	# The body: one loft, stalk to crown.
	var shell := kit()
	shell.loft([_ring(SECS[0]), _ring(SECS[1]), _ring(SECS[2]), _ring(SECS[3]), _ring(SECS[4]), _ring(SECS[5])], _colour,
		false, true)
	add_neck_plug(shell, _ring(SECS[0]))
	var ks := kit()
	build_eye_set(ks, Vector3(0.14, 0.7, -0.325), Vector3(0.3, 0.0, -0.95), 1.2,
		{"brow": GREEN.lightened(0.12), "lid": GREEN.darkened(0.06), "iris": IRIS, "pupil": PUPIL, "white": MechHeadMeshes.EYE_WHITE},
		{"eye": 0.046, "pupil": 0.024})
	# Nose.
	ks.seg(Vector3(0, 0.66, -0.33), Vector3(0, 0.56, -0.45), Vector2(0.03, 0.03), Vector2(0.07, 0.05), 4,
		GREEN.lightened(0.08), 2.0, true, 0.0)
	# The dark mouth on the face plane, hidden behind the lip plate at rest.
	var mouth := PackedVector3Array()
	for p: Vector2 in [Vector2(-0.1, 0.38), Vector2(0.1, 0.38), Vector2(0.1, 0.29), Vector2(-0.1, 0.29)]:
		mouth.append(Vector3(p.x, p.y, -_face_r(SECS, p.y) * FLAT - 0.004))
	ks.poly(mouth, MOUTH, Vector3(0.0, 0.33, 0.0))
	add_body(shell, ks)

	# Mouth line: two half bars hinged at the centre (the static bar, split).
	var k: MeshKit
	for side: float in [-1.0, 1.0]:
		var n := "MouthL" if side < 0.0 else "MouthR"
		add_piece(n, "Skull", Vector3(0.0, 0.4, -0.335))
		k = kit()
		var a := Vector3(-0.13, 0.4, -0.335) if side < 0.0 else Vector3(0.0, 0.4, -0.335)
		k.seg(a, a + Vector3(0.13, 0.0, 0.0), Vector2(0.02, 0.03), Vector2(0.02, 0.03), 3, GREEN.darkened(0.45))
		add_mesh(n, k)

	# Lip plate under the mouth: it slides down the flat face (pose_extra) instead of hinging.
	add_piece("Jaw", "Skull", Vector3(0.0, 0.385, -0.334))
	k = kit()
	k.seg(Vector3(-0.11, 0.335, -0.334), Vector3(0.11, 0.335, -0.334), Vector2(0.05, 0.007), Vector2(0.05, 0.007), 4,
		GREEN.darkened(0.04), MeshKit.SQUARE)
	add_mesh("Jaw", k)

	# Warts, each on its own little hinge at its base.
	for i in WARTS.size():
		var w: Array = WARTS[i]
		var p := Vector3(w[0], w[1], w[2])
		add_piece("Wart%d" % i, "Skull", p)
		k = kit()
		k.seg(p, p + Vector3(w[0], 0, w[2]).normalized() * 0.08, Vector2(0.05, 0.05), Vector2.ZERO, 3, GREEN.lightened(0.1),
			2.0, false)
		add_mesh("Wart%d" % i, k)


## The jelly body: the standard two joints, then the Skull scaled (stretch / sag, volume kept) and sheared by the flair
## spring, times the landing squash.
func pose_neck(neck: PilotNeck) -> void:
	pose_neck_joints(neck.low, neck.high, neck.shift.x, neck.shift.y)
	var s := clampf(-neck.flair.x / JELLY_REF, -1.6, 1.6)
	var sy := 1.0 + STRETCH * s
	var sxz := 1.0 / sqrt(sy)
	var sq := neck.squash
	sy *= 1.0 - sq
	sxz *= 1.0 + sq * squash_width
	var shear := -neck.flair.y * SHEAR
	set_pose("Skull", Basis(Vector3(sxz, 0.0, 0.0), Vector3(shear, sy, 0.0), Vector3(0.0, 0.0, sxz)))


func pose_flair(_ch: Dictionary, neck: PilotNeck, extra: Dictionary) -> void:
	var t := float(extra.get("time", 0.0))
	var p: Vector2 = neck.pend[0] if neck.pend.size() > 0 else Vector2.ZERO
	p -= Vector2(deg_to_rad(-8.0) * float(rest["mouth_curve"]), 0.0)   # PilotHead's mouth_curve offset, zero at rest
	var jelly := neck.flair
	var twitch := 0.0
	var age := _tic_age("wart_twitch", t)
	if age >= 0.0:
		twitch = sin(TAU * 7.0 * age) * exp(-age * 5.0) * 0.7
	var which := posmod((head as PilotHead).look_seed if head is PilotHead else 0, WARTS.size())
	for i in WARTS.size():
		var w: Array = WARTS[i]
		var dir := Vector3(w[0], 0, w[2]).normalized()
		var tangent := Vector3.UP.cross(dir).normalized()
		var a := p * float(WART_PEND[i]) + jelly * float(WART_JELLY[i])
		if i == which:
			a.x += twitch
		set_pose("Wart%d" % i, Basis(tangent, a.x * 0.6) * Basis(Vector3.UP, a.y * 0.6))


## Mouth corners from mouth_curve (lopsided with brow_skew); the lip plate slides down with jaw.
func pose_extra(ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	var mc := float(ch["mouth_curve"]) - float(rest["mouth_curve"])
	var skew := float(ch["brow_skew"]) - float(rest["brow_skew"])
	var left := deg_to_rad(MOUTH_TURN) * (mc + skew * MOUTH_SKEW)
	var right := deg_to_rad(MOUTH_TURN) * (mc - skew * MOUTH_SKEW)
	set_pose("MouthL", Basis(Vector3.BACK, -left))
	set_pose("MouthR", Basis(Vector3.BACK, right))
	set_pose("Jaw", Basis.IDENTITY, Vector3(0.0, -JAW_DROP * clampf(float(ch["jaw"]), 0.0, 1.0), 0.0))


static func _colour(c: Vector3, n: Vector3) -> Color:
	return MechHeadMeshes.pickle_colour(c, n)


static func _ring(s: Array, scale: float = 1.0) -> PackedVector3Array:
	return MeshKit.ring(Vector3(0, s[0], s[1]), float(s[2]) * scale, float(s[3]) * scale, 8, "y", 2.0)
