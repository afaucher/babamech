class_name PilotHeadDog
extends PilotFace
## The dog pilot (art/picks/head_dog.png), rigged: the static MechHeadMeshes dog's sections as one body mesh
## (PilotFace.add_body; same snout, nose, girth and stern brow at rest), plus lids and moving pupils; the Jaw is the lower jaw bar hinged at its
## back, its top face and the snout's underside dark (the mouth shows when it drops), and a Tongue plate hidden inside it
## that slides out and droops when panting (overheated, the pant tic). mouth_curve tilts the jaw (a lopsided snarl).
## Flair = the two ears, each on two hinges (EarL / EarR at the root on the flair spring; EarTipL / EarTipR at the bend,
## hanging on a pendulum): raised they prick up and back and straighten, dropped they hang; the flair spring's roll lifts
## one ear and drops the other (the ear flick). Movement style: loose and overshooting, ears always late (a soft, under-
## damped neck; a slow flair spring). Tics: one-ear flick, 2 s pant with the tongue out, sniff, head tilt.

const FUR := Color(0.72, 0.45, 0.2)
const NOSE := Color(0.09, 0.08, 0.08)
const PUPIL := Color(0.08, 0.06, 0.05)
const MOUTH := Color(0.3, 0.08, 0.08)
const TONGUE := Color(0.86, 0.42, 0.46)
## Neck-and-skull sections [y, centre z, half width, half depth] (as MechHeadMeshes._dog).
const SECS := [[0.0, 0.08, 0.28, 0.29], [0.3, 0.06, 0.26, 0.28], [0.52, 0.0, 0.34, 0.36], [0.76, -0.01, 0.37, 0.38],
	[0.97, 0.0, 0.32, 0.33], [1.08, 0.02, 0.2, 0.22]]
## Ears: root lift (rad of hinge roll per rad of flair raise), how far they swing back, the extra droop when dropped,
## and how much the tip straightens (rad) at full raise.
const EAR_LIFT := 1.6
const EAR_BACK := 0.35
const EAR_DROOP := 0.6
const EAR_STRAIGHT := 0.75
const FLAIR_RAISE := 1.0
const FLAIR_DROP := 0.35
## Tongue: slide (metres before girth) and droop (rad) when fully out; the pant tic's envelope and jaw cycle.
const TONGUE_SLIDE := 0.15
const TONGUE_DROOP := 0.3
const PANT := Vector3(0.2, 1.6, 0.2)
const PANT_HZ := 3.0
const PANT_JAW := 0.3
const SNARL := 6.0



func _init() -> void:
	id = "dog"
	# The neck bends along its whole length, up to just under the snout.
	body_bend = Vector2(0.0, 0.48)
	var g := float(MechHeadMeshes.GIRTH.get("dog", 1.0))
	girth = Vector3(g, 1.0, g)
	pendulums = 2
	flair_pieces = ["EarL", "EarR", "EarTipL", "EarTipR", "Tongue"]
	# Loose and overshooting: a soft, under-damped neck that lags acceleration; ears on a slow, late spring.
	style = {"hz": 3.0, "damping": 0.32, "upper": 0.8, "accel_gain": 0.028, "flair_hz": 1.4, "flair_damping": 0.42,
		"flair_inertia": 1.1, "pend_hz": 2.0, "pend_damping": 0.3,
		"flair_raise": Vector2(-FLAIR_RAISE, 0.0), "flair_drop": Vector2(FLAIR_DROP, 0.0)}
	jaw_open = 30.0
	# Overheated: the mouth hangs wider and the pant is deeper (the tongue comes out with it, pose_extra).
	overrides = {"moods": {"overheated": {"jaw": 0.5}}, "poses": {"overheated": {"pant_jaw": 0.3, "pant_nod": 3.5}}}
	tics = [
		{"id": "ear_flick", "kind": "pulse", "a": 0.05, "h": 0.06, "r": 0.3, "neck": Vector3(0.0, 0.0, -3.0),
			"flair": Vector2(0.0, 55.0), "ch": {"lid": 0.15}},
		{"id": "pant", "kind": "pulse", "a": PANT.x, "h": PANT.y, "r": PANT.z, "neck": Vector3(-6.0, 0.0, 0.0),
			"ch": {"jaw": 0.3, "lid": 0.1, "brow_anger": -0.2}},
		{"id": "sniff", "kind": "shake", "dur": 0.9, "hz": 3.3, "neck": Vector3(8.0, 0.0, 0.0), "flair": Vector2(-8.0, 0.0)},
		{"id": "head_tilt", "kind": "pulse", "a": 0.25, "h": 1.0, "r": 0.4, "neck": Vector3(3.0, 0.0, 16.0),
			"flair": Vector2(-20.0, 15.0), "ch": {"brow_skew": 0.4, "brow_anger": -0.3, "brow_raise": 0.2}},
	]


func build_pieces() -> void:
	add_piece("NeckLow", "", Vector3(0.0, 0.0, 0.08))
	add_piece("NeckHigh", "NeckLow", Vector3(0.0, 0.3, 0.06))
	add_piece("Skull", "NeckHigh", Vector3(0.0, 0.52, 0.0))
	# The body: one loft from the neck base to the crown.
	var shell := kit()
	shell.loft([_ring(SECS[0]), _ring(SECS[1]), _ring(SECS[2]), _ring(SECS[3]), _ring(SECS[4]), _ring(SECS[5])], FUR,
		false, true)
	add_neck_plug(shell, _ring(SECS[0]))
	var ks := kit()
	# Snout and nose (as the static dog), and the snout's dark underside (inside the jaw at rest).
	ks.loft([MeshKit.ring(Vector3(0, 0.64, -0.28), 0.19, 0.15, 6, "z", 2.6),
		MeshKit.ring(Vector3(0, 0.6, -0.66), 0.14, 0.11, 6, "z", 2.6)], FUR.lightened(0.08), false, true)
	ks.seg(Vector3(0, 0.68, -0.62), Vector3(0, 0.65, -0.73), Vector2(0.08, 0.06), Vector2(0.05, 0.035), 4, NOSE,
		MeshKit.SQUARE)
	ks.quad(Vector3(-0.085, 0.497, -0.32), Vector3(0.085, 0.497, -0.32), Vector3(0.085, 0.497, -0.56),
		Vector3(-0.085, 0.497, -0.56), MOUTH, Vector3(0.0, 0.6, -0.44))
	build_eye_set(ks, Vector3(0.17, 0.83, -0.325), Vector3(0.35, 0.05, -0.93), 1.15,
		{"brow": FUR.darkened(0.1), "lid": FUR.darkened(0.04), "iris": MechHeadMeshes.EYE_WHITE, "pupil": PUPIL},
		{"eye": 0.06, "pupil": 0.03})
	add_body(shell, ks)

	# The jaw bar, hinged at its back, with the inside of the mouth on top: a dark plate narrower than the snout's
	# underside, so it stays hidden at rest (the jaw bar is wider than the snout and its edges show).
	add_piece("Jaw", "Skull", Vector3(0.0, 0.47, -0.3))
	var k := kit()
	k.seg(Vector3(0, 0.47, -0.3), Vector3(0, 0.47, -0.58), Vector2(0.13, 0.035), Vector2(0.1, 0.03), 4,
		FUR.darkened(0.25), MeshKit.SQUARE)
	k.quad(Vector3(-0.075, 0.509, -0.31), Vector3(0.075, 0.509, -0.31), Vector3(0.065, 0.504, -0.57),
		Vector3(-0.065, 0.504, -0.57), MOUTH, Vector3(0.0, 0.45, -0.44))
	add_mesh("Jaw", k)
	# The tongue, inside the jaw bar until it slides out.
	add_piece("Tongue", "Jaw", Vector3(0.0, 0.474, -0.33))
	k = kit()
	k.seg(Vector3(0, 0.474, -0.33), Vector3(0, 0.474, -0.55), Vector2(0.065, 0.012), Vector2(0.055, 0.01), 3, TONGUE)
	add_mesh("Tongue", k)

	# Ears: root flap on the flair hinge, tip flap on its own hinge at the bend.
	for side: float in [-1.0, 1.0]:
		var sfx := "L" if side < 0.0 else "R"
		var root := Vector3(side * 0.3, 1.0, 0.06)
		var bend := Vector3(side * 0.5, 0.84, 0.02)
		add_piece("Ear" + sfx, "Skull", root)
		k = kit()
		k.seg(root, bend, Vector2(0.05, 0.14), Vector2(0.04, 0.17), 4, FUR.darkened(0.18), MeshKit.SQUARE, false)
		add_mesh("Ear" + sfx, k)
		add_piece("EarTip" + sfx, "Ear" + sfx, bend)
		k = kit()
		# Starts a little up the root flap, so the bend never opens a gap when the tip straightens.
		k.seg(bend + (root - bend).normalized() * 0.04, Vector3(side * 0.53, 0.46, -0.04), Vector2(0.04, 0.17), Vector2.ZERO,
			4, FUR.darkened(0.28), MeshKit.SQUARE, true)
		add_mesh("EarTip" + sfx, k)


func pose_flair(_ch: Dictionary, neck: PilotNeck, _extra: Dictionary) -> void:
	var rest_pend := Vector2(deg_to_rad(-8.0) * float(rest["mouth_curve"]), 0.0)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var sfx := "L" if i == 0 else "R"
		# Lift in flair-raise units: + pricked, - hanging; the roll lifts the left ear and drops the right.
		var lift := (-neck.flair.x - side * neck.flair.y) / FLAIR_RAISE
		var up := maxf(lift, 0.0)
		var down := maxf(-lift * FLAIR_RAISE / FLAIR_DROP, 0.0)
		var root_roll := side * (up * EAR_LIFT - down * EAR_DROOP * 0.5)
		set_pose("Ear" + sfx, Basis(Vector3.RIGHT, up * EAR_BACK) * Basis(Vector3.BACK, root_roll))
		# The tip straightens as the ear rises; otherwise it hangs from the bend on its pendulum.
		var p: Vector2 = (neck.pend[i] if i < neck.pend.size() else Vector2.ZERO) - rest_pend
		var hang := 1.0 - clampf(up, 0.0, 1.0)
		var tip_roll := side * (minf(up, 1.2) * EAR_STRAIGHT + down * EAR_DROOP * 0.4) + p.y * hang
		set_pose("EarTip" + sfx, Basis(Vector3.RIGHT, p.x * hang) * Basis(Vector3.BACK, tip_roll))


## The jaw (with the pant tic's cycle), tilted by mouth_curve; the tongue out when overheated or panting.
func pose_extra(ch: Dictionary, _neck: PilotNeck, extra: Dictionary) -> void:
	var t := float(extra.get("time", 0.0))
	var jaw := clampf(float(ch["jaw"]), 0.0, 1.0)
	var pant := 0.0
	var age := _tic_age("pant", t)
	if age >= 0.0:
		pant = PilotExpressions.envelope(age, PANT.x, PANT.y, PANT.z)
		jaw += pant * PANT_JAW * (0.5 + 0.5 * sin(TAU * PANT_HZ * age))
	var mc := float(ch["mouth_curve"]) - float(rest["mouth_curve"])
	set_pose("Jaw", Basis(Vector3.FORWARD, deg_to_rad(SNARL) * mc)
		* Basis(Vector3.RIGHT, -deg_to_rad(jaw_open) * clampf(jaw, 0.0, 1.0)))
	var hot := smoothstep(0.7, 0.95, float(ch["flush"])) * smoothstep(0.15, 0.35, float(ch["jaw"]))
	var tongue := maxf(hot, pant)
	set_pose("Tongue", Basis(Vector3.RIGHT, -TONGUE_DROOP * tongue), Vector3(0.0, 0.0, -TONGUE_SLIDE * girth.z * tongue))



static func _ring(s: Array, scale: float = 1.0) -> PackedVector3Array:
	return MeshKit.ring(Vector3(0, s[0], s[1]), float(s[2]) * scale, float(s[3]) * scale, 8, "y", 2.2)
