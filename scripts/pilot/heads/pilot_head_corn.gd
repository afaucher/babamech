class_name PilotHeadCorn
extends PilotFace
## The corn pilot (art/picks/head_corn.png), rigged: the static MechHeadMeshes corn's sections as one body mesh
## (PilotFace.add_body; same kernel banding, girth, nose and stern brow at rest), plus lids, moving pupils, the mouth line split into two half bars
## hinged at the centre (MouthL / MouthR: mouth_curve turns the corners up / down, brow_skew makes it lopsided) and a lip
## plate under it (Jaw) that drops to show a dark mouth.
## Flair = the five husk leaves, each on a hinge at its base (Husk0..4, round the ring from the head's right): raised they
## flare outward like hackles, dropped they droop and close in; the flair spring's roll leans them sideways, so they trail
## every head movement. Movement style: stiff and upright (a stiff, well damped neck); the husks do the moving.
## Tics: a husk rustle (the leaves shiver one after another round the ring), a kernel-pop twitch, a look up at the
## ceiling lights.

const YELLOW := Color(0.97, 0.8, 0.25)
const HUSK := Color(0.36, 0.56, 0.2)
const PUPIL := Color(0.08, 0.06, 0.05)
const MOUTH := Color(0.2, 0.09, 0.03)
## Cob sections [y, centre z, half width, half depth] (as MechHeadMeshes._corn).
const SECS := [[0.0, 0.0, 0.2, 0.2], [0.2, 0.0, 0.32, 0.32], [0.5, 0.0, 0.34, 0.34], [0.82, 0.0, 0.31, 0.31],
	[1.08, 0.0, 0.23, 0.23], [1.26, 0.0, 0.11, 0.11]]
const HUSKS := 5
## Husk hinge: radians of flare per radian of flair pitch, the most they close in (they would cut into the cob), and the
## sideways lean per radian of flair roll.
const FLARE := 0.7
const CLOSE_MAX := 0.26
const LEAN := 0.8
## Rustle: each leaf starts RUSTLE_STEP after the one before, shivers at RUSTLE_HZ.
const RUSTLE_STEP := 0.12
const RUSTLE_HZ := 11.0
const RUSTLE_RAD := 0.2
const MOUTH_TURN := 24.0
const MOUTH_SKEW := 0.5
const FLAT := 0.9239
## The lip plate slides straight down the face this far at jaw = 1 (a hinge would swing it off the flat face).
const JAW_DROP := 0.085

var _tic := ""
var _tic_t0 := 0.0
var _dirs: Array[Vector3] = []


func _init() -> void:
	id = "corn"
	# The stalk and the cob's bottom band take the bend (the stalk's top ring halfway); from the 0.5 ring up the cob is rigid.
	body_bend = Vector2(0.0, 0.4)
	var g := float(MechHeadMeshes.GIRTH.get("corn", 1.0))
	girth = Vector3(g, 1.0, g)
	flair_pieces = []
	for i in HUSKS:
		flair_pieces.append("Husk%d" % i)
	# Stiff and upright: a quick, well damped neck that barely tips with acceleration; loose husks that trail hard.
	style = {"hz": 5.0, "damping": 0.8, "upper": 0.95, "accel_gain": 0.012, "flair_hz": 2.4, "flair_damping": 0.26,
		"flair_inertia": 1.0, "flair_raise": Vector2(-0.5, 0.0), "flair_drop": Vector2(0.32, deg_to_rad(10.0))}
	squash_width = 0.4
	tics = [
		{"id": "husk_rustle", "kind": "shake", "dur": 1.0, "hz": 6.0, "neck": Vector3.ZERO, "flair": Vector2(0.0, 5.0)},
		{"id": "kernel_pop", "kind": "pulse", "a": 0.03, "h": 0.05, "r": 0.3, "neck": Vector3(6.0, 0.0, -5.0), "push": 0.02,
			"flair": Vector2(-15.0, 0.0), "ch": {"brow_raise": 0.5, "lid": -0.3, "pupil_size": -0.3}},
		{"id": "look_up", "kind": "pulse", "a": 0.5, "h": 1.4, "r": 0.6, "neck": Vector3(24.0, 0.0, 0.0),
			"ch": {"gaze_y": 0.7, "brow_raise": 0.35, "brow_anger": -0.2}},
	]


func build_pieces() -> void:
	# The neck bends at the base: NeckLow is the stalk end, NeckHigh a bare joint, the Skull the cob above it.
	add_piece("NeckLow", "", Vector3.ZERO)
	add_piece("NeckHigh", "NeckLow", Vector3(0.0, 0.2, 0.0))
	add_piece("Skull", "NeckHigh", Vector3(0.0, 0.2, 0.0))
	# The body: one loft, stalk end to the cob's tip.
	var shell := kit()
	shell.loft([_ring(SECS[0]), _ring(SECS[1]), _ring(SECS[2]), _ring(SECS[3]), _ring(SECS[4]), _ring(SECS[5])], _colour,
		false, true)
	add_neck_plug(shell, _ring(SECS[0]))
	var ks := kit()
	build_eye_set(ks, Vector3(0.13, 0.66, -0.32), Vector3(0.3, 0.0, -0.95), 1.15,
		{"brow": HUSK, "lid": YELLOW.darkened(0.08), "iris": MechHeadMeshes.EYE_WHITE, "pupil": PUPIL},
		{"eye": 0.06, "pupil": 0.03})
	ks.seg(Vector3(0, 0.62, -0.33), Vector3(0, 0.52, -0.44), Vector2(0.03, 0.03), Vector2(0.07, 0.05), 4,
		YELLOW.darkened(0.08), 2.0, true, 0.0)
	var mouth := PackedVector3Array()
	for p: Vector2 in [Vector2(-0.1, 0.36), Vector2(0.1, 0.36), Vector2(0.1, 0.275), Vector2(-0.1, 0.275)]:
		mouth.append(Vector3(p.x, p.y, -_face_r(p.y) * FLAT - 0.004))
	ks.poly(mouth, MOUTH, Vector3(0.0, 0.32, 0.0))
	add_body(shell, ks)

	var k: MeshKit
	for side: float in [-1.0, 1.0]:
		var n := "MouthL" if side < 0.0 else "MouthR"
		add_piece(n, "Skull", Vector3(0.0, 0.38, -0.33))
		k = kit()
		var a := Vector3(-0.12, 0.38, -0.33) if side < 0.0 else Vector3(0.0, 0.38, -0.33)
		k.seg(a, a + Vector3(0.12, 0.0, 0.0), Vector2(0.02, 0.03), Vector2(0.02, 0.03), 3, YELLOW.darkened(0.5))
		add_mesh(n, k)

	# Lip plate under the mouth: it slides down the flat face (pose_extra) instead of hinging.
	add_piece("Jaw", "Skull", Vector3(0.0, 0.363, -0.323))
	k = kit()
	k.seg(Vector3(-0.11, 0.317, -0.323), Vector3(0.11, 0.317, -0.323), Vector2(0.046, 0.007), Vector2(0.046, 0.007), 4,
		YELLOW.darkened(0.06), MeshKit.SQUARE)
	add_mesh("Jaw", k)

	# Husk leaves (as the static corn), each on a hinge at its base.
	for i in HUSKS:
		var ang := TAU * (float(i) + 1.0) / 6.0
		var d := Vector3(sin(ang), 0, -cos(ang))
		_dirs.append(d)
		var side := Vector3(d.z, 0, -d.x)
		var base := d * 0.24
		var mid := d * 0.46 + Vector3(0, 0.36, 0)
		var tip := d * 0.6 + Vector3(0, 0.8, 0)
		var core := Vector3(0, 0.4, 0)
		add_piece("Husk%d" % i, "Skull", base)
		k = kit()
		for sgn: float in [-1.0, 1.0]:
			var edge := d * 0.36 + side * 0.22 * sgn + Vector3(0, 0.34, 0)
			k.tri(base, edge, mid, HUSK, core)
			k.tri(edge, tip, mid, HUSK.darkened(0.12), core)
			k.tri(base, edge, tip, HUSK.darkened(0.3), core + d * 2.0)
		add_mesh("Husk%d" % i, k)


func pose_flair(_ch: Dictionary, neck: PilotNeck, extra: Dictionary) -> void:
	var t := float(extra.get("time", 0.0))
	var age := _tic_age("husk_rustle", t)
	for i in HUSKS:
		var d := _dirs[i]
		var open := -neck.flair.x * FLARE - neck.flair.y * d.x * 0.5
		var lean := neck.flair.y * LEAN
		if age >= 0.0:
			var e := PilotExpressions.envelope(age - float(i) * RUSTLE_STEP, 0.04, 0.12, 0.2)
			open += e * sin(TAU * RUSTLE_HZ * age) * RUSTLE_RAD
			lean += e * cos(TAU * RUSTLE_HZ * age) * RUSTLE_RAD * 0.5
		if open < 0.0:
			open = -CLOSE_MAX * tanh(-open / CLOSE_MAX)
		# Flare = the tip away from the cob: about UP x d. Lean = about the leaf's own outward axis.
		set_pose("Husk%d" % i, Basis(d, lean) * Basis(Vector3.UP.cross(d).normalized(), open))


func pose_extra(ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	var mc := float(ch["mouth_curve"]) - float(rest["mouth_curve"])
	var skew := float(ch["brow_skew"]) - float(rest["brow_skew"])
	set_pose("MouthL", Basis(Vector3.BACK, -deg_to_rad(MOUTH_TURN) * (mc + skew * MOUTH_SKEW)))
	set_pose("MouthR", Basis(Vector3.BACK, deg_to_rad(MOUTH_TURN) * (mc - skew * MOUTH_SKEW)))
	set_pose("Jaw", Basis.IDENTITY, Vector3(0.0, -JAW_DROP * clampf(float(ch["jaw"]), 0.0, 1.0), 0.0))


func _tic_age(want: String, t: float) -> float:
	var ph := head as PilotHead
	var tic := ph.idle.tic_id if ph != null and ph.idle_enabled else ""
	if tic != _tic:
		_tic = tic
		_tic_t0 = t
	return t - _tic_t0 if tic != "" and tic == want else -1.0


static func _face_r(y: float) -> float:
	for i in SECS.size() - 1:
		var a: Array = SECS[i]
		var b: Array = SECS[i + 1]
		if y <= float(b[0]):
			return lerpf(float(a[3]), float(b[3]), (y - float(a[0])) / (float(b[0]) - float(a[0])))
	return float(SECS[SECS.size() - 1][3])


static func _colour(c: Vector3, n: Vector3) -> Color:
	return MechHeadMeshes._corn_colour(c, n)


static func _ring(s: Array, scale: float = 1.0) -> PackedVector3Array:
	return MeshKit.ring(Vector3(0, s[0], s[1]), float(s[2]) * scale, float(s[3]) * scale, 8, "y", 2.0)


static func _lerp_sec(a: Array, b: Array, y: float) -> Array:
	var t := (y - float(a[0])) / (float(b[0]) - float(a[0]))
	var out := []
	for i in 4:
		out.append(lerpf(float(a[i]), float(b[i]), t))
	return out
