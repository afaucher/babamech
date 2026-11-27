class_name PilotHeadChicken
extends PilotFace
## The chicken pilot (art/picks/head_chicken.png), rigged: the static MechHeadMeshes chicken's sections as one body mesh
## bent by the neck joints (PilotFace.add_body; same girth and stern brow at rest), plus lids, moving pupils on a dark eye, a hinged lower beak with a dark
## mouth behind it, the comb on one hinge (the flair) and two wattle pendulums. Movement style: snappy and stepped (bird
## saccades: the look only jumps once it moved step_deg, on a stiff neck). The reference head for PilotFace's contract.

const WHITE := Color(0.93, 0.9, 0.83)
const RED := Color(0.78, 0.17, 0.14)
const BEAK := Color(0.95, 0.69, 0.14)
const IRIS := Color(0.3, 0.16, 0.07)
const PUPIL := Color(0.05, 0.04, 0.03)
const MOUTH := Color(0.26, 0.06, 0.05)
## Neck-and-skull sections [y, centre z, half width, half depth] (as MechHeadMeshes._chicken).
const SECS := [[0.0, 0.06, 0.3, 0.31], [0.3, 0.05, 0.24, 0.26], [0.55, 0.0, 0.27, 0.3], [0.76, -0.03, 0.31, 0.35],
	[0.96, -0.02, 0.29, 0.32], [1.1, 0.02, 0.19, 0.21]]
## Degrees the lower beak twists per unit of mouth_curve (smirk / grim set).
const MOUTH_TILT := 14.0


func _init() -> void:
	id = "chicken"
	# The neck bends along its whole length (base to the skull), so its inner side never folds up.
	body_bend = Vector2(0.0, 0.55)
	var g := float(MechHeadMeshes.GIRTH.get("chicken", 1.0))
	girth = Vector3(g, 1.0, g)
	pendulums = 2
	# Seen from 10+ m: a wide beak gape and a clear lopsided beak set read where a small one doesn't.
	jaw_open = 40.0
	flair_pieces = ["Comb", "WattleL", "WattleR"]
	style = {"hz": 4.6, "damping": 0.6, "upper": 0.9, "step_deg": 7.0, "flair_hz": 2.2, "flair_damping": 0.28,
		"pend_hz": 2.6, "pend_damping": 0.22, "flair_raise": Vector2(deg_to_rad(-14.0), 0.0),
		"flair_drop": Vector2(deg_to_rad(12.0), deg_to_rad(50.0))}
	# Birds blink fast.
	overrides = {"reactions": {"blink": {"a": 0.025, "h": 0.02, "r": 0.04}}}
	tics = [
		{"id": "saccade", "kind": "steps", "steps": 4, "step_time": 0.35, "yaw": 35.0, "pitch": 10.0},
		{"id": "peck", "kind": "pulse", "a": 0.07, "h": 0.05, "r": 0.2, "neck": Vector3(-30.0, 0.0, 0.0), "push": 0.1,
			"flair": Vector2(-20.0, 0.0), "ch": {"lid": 0.3}},
		{"id": "comb_shake", "kind": "shake", "dur": 0.7, "hz": 7.0, "neck": Vector3(0.0, 0.0, 5.0),
			"flair": Vector2(0.0, 28.0)},
	]


func build_pieces() -> void:
	add_piece("NeckLow", "", Vector3(0.0, 0.0, 0.06))
	add_piece("NeckHigh", "NeckLow", Vector3(0.0, 0.3, 0.05))
	add_piece("Skull", "NeckHigh", Vector3(0.0, 0.55, 0.0))
	# The body: one loft from the neck base to the crown (a ring at each joint and one inside the upper bend).
	var shell := kit()
	shell.loft([_ring(SECS[0]), _ring(SECS[1]), _ring(_lerp_sec(SECS[1], SECS[2], 0.42)), _ring(SECS[2]), _ring(SECS[3]),
		_ring(SECS[4]), _ring(SECS[5])], WHITE, false, true)
	add_neck_plug(shell, _ring(SECS[0]))
	var ks := kit()
	# Upper beak, and the dark mouth behind the lower one.
	ks.seg(Vector3(0, 0.8, -0.28), Vector3(0, 0.69, -0.68), Vector2(0.13, 0.095), Vector2.ZERO, 4, BEAK, 2.0, false, 0.0)
	ks.seg(Vector3(0, 0.715, -0.27), Vector3(0, 0.69, -0.52), Vector2(0.06, 0.03), Vector2.ZERO, 4, MOUTH, 2.0, false, 0.0)
	build_eye_set(ks, Vector3(0.2, 0.86, -0.275), Vector3(0.6, 0.05, -0.8), 1.1,
		{"brow": WHITE.darkened(0.12), "lid": WHITE.darkened(0.04), "iris": IRIS, "pupil": PUPIL},
		{"eye": 0.062, "pupil": 0.03})
	add_body(shell, ks)

	# Lower beak on its hinge.
	add_piece("Jaw", "Skull", Vector3(0.0, 0.72, -0.28))
	var k := kit()
	k.seg(Vector3(0, 0.71, -0.28), Vector3(0, 0.66, -0.55), Vector2(0.09, 0.05), Vector2.ZERO, 4, BEAK.darkened(0.2), 2.0,
		false, 0.0)
	add_mesh("Jaw", k)

	# Comb: four red spikes on one hinge along the crown.
	add_piece("Comb", "Skull", Vector3(0.0, 1.03, 0.0))
	k = kit()
	for s: Array in [[-0.2, 0.22, -0.1], [-0.07, 0.36, -0.05], [0.08, 0.38, 0.03], [0.21, 0.26, 0.1]]:
		k.seg(Vector3(0, 1.03, s[0]), Vector3(0, 1.08 + s[1], s[0] + s[2]), Vector2(0.06, 0.1), Vector2.ZERO, 4, RED, 2.0,
			false, 0.0)
	add_mesh("Comb", k)

	# Wattles: two red drops hanging from under the beak (single watertight loft per wattle).
	for side: float in [-1.0, 1.0]:
		var n := "WattleL" if side < 0.0 else "WattleR"
		var top := Vector3(side * 0.05, 0.68, -0.31)
		var mid := Vector3(side * 0.08, 0.46, -0.35)
		var bot := Vector3(side * 0.08, 0.3, -0.33)
		add_piece(n, "Skull", top)
		k = kit()
		k.loft([MeshKit.ring(top, 0.0, 0.0, 4, "y", 2.0, 0.0), MeshKit.ring(mid, 0.07, 0.07, 4, "y", 2.0, 0.0),
			MeshKit.ring(bot, 0.0, 0.0, 4, "y", 2.0, 0.0)], [RED, RED.darkened(0.12)], false, false)
		add_mesh(n, k)


func pose_flair(_ch: Dictionary, neck: PilotNeck, _extra: Dictionary) -> void:
	set_pose("Comb", Basis.from_euler(Vector3(neck.flair.x, 0.0, neck.flair.y)))
	for i in 2:
		var p: Vector2 = neck.pend[i] if i < neck.pend.size() else Vector2.ZERO
		set_pose("WattleL" if i == 0 else "WattleR", Basis.from_euler(Vector3(p.x, 0.0, p.y)))


## No mouth corners on a beak: mouth_curve tilts the lower beak to one side (lopsided smirk / grim set).
func pose_extra(ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	var mc := float(ch["mouth_curve"]) - float(rest["mouth_curve"])
	var open := deg_to_rad(jaw_open) * clampf(float(ch["jaw"]), 0.0, 1.0)
	set_pose("Jaw", Basis(Vector3.FORWARD, deg_to_rad(MOUTH_TILT) * mc) * Basis(Vector3.RIGHT, -open))


static func _ring(s: Array, scale: float = 1.0) -> PackedVector3Array:
	return MeshKit.ring(Vector3(0, s[0], s[1]), float(s[2]) * scale, float(s[3]) * scale, 8, "y", 2.2)
