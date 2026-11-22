class_name PilotHeadDuck
extends PilotFace
## The duck pilot (art/picks/head_duck.png, a mallard drake), rigged: the static MechHeadMeshes duck cut into rigid pieces
## (same sections, bill, crest and girth: the constants live in MechHeadMeshes so both keep one silhouette), plus lids,
## moving pupils on a white-ringed eye, the lower bill hinged at its root with a dark mouth behind it (wide and flat, so a
## generous jaw_open reads from far away), and the crest tuft (three shards) on one hinge (the flair: raised = shards up,
## dropped = flat).
## The neck has two bends: raised flair stretches it tall, dropped flair collapses the S-bend (lower neck forward, upper
## back, head sunk; dazed also hangs the bill open). Movement style: a smooth glide (soft, well damped neck) with a nod
## per footfall. Tics: a silent quack (the bill opens twice with a head bob), a neck stretch that settles with a waggle,
## a bill preen at the shoulder.

const IRIS := Color(0.27, 0.15, 0.07)
const PUPIL := Color(0.05, 0.04, 0.03)
const MOUTH := Color(0.24, 0.07, 0.05)
## Each upper neck piece starts below its joint (hidden inside the piece below), so bending or stretching never opens a gap.
const SLEEVE := 1.06
const HIDDEN := 0.8
## Two-bend neck: lift of the upper neck at flair +1 (metres), S-bend collapse at flair -1 (degrees, lower / upper joint)
## and its sink (metres).
const NECK_TALL := 0.08
const SLUMP_LOW := -14.0
const SLUMP_HIGH := 20.0
const SLUMP_SINK := 0.03


func _init() -> void:
	id = "duck"
	var g := float(MechHeadMeshes.GIRTH.get("duck", 1.0))
	girth = Vector3(g, 1.0, g)
	flair_pieces = ["Crest"]
	jaw_open = 40.0
	style = {"hz": 3.0, "damping": 0.8, "upper": 0.8, "accel_gain": 0.016, "flair_hz": 2.6, "flair_damping": 0.35,
		"flair_inertia": 0.4, "flair_raise": Vector2(deg_to_rad(-28.0), 0.0),
		"flair_drop": Vector2(deg_to_rad(45.0), deg_to_rad(8.0))}
	# Birds blink fast; dazed, the bill hangs open.
	overrides = {"reactions": {"blink": {"a": 0.025, "h": 0.02, "r": 0.04}}, "moods": {"dazed": {"jaw": 0.55}}}
	tics = [
		# Silent quack: the bill opens twice, a head bob with each.
		{"id": "quack", "kind": "pulse", "pulses": 2, "gap": 0.02, "a": 0.06, "h": 0.08, "r": 0.1,
			"neck": Vector3(-9.0, 0.0, 0.0), "push": 0.03, "ch": {"jaw": 0.75}},
		# Neck stretch up, settling with a waggle.
		{"id": "stretch", "kind": "pulse", "a": 0.3, "h": 0.3, "r": 0.6, "neck": Vector3(12.0, 0.0, 0.0), "lift": 0.07,
			"flair": Vector2(-15.0, 0.0), "ch": {"lid": -0.2},
			"wobble": {"from": 0.6, "dur": 0.65, "hz": 4.5, "neck": Vector3(0.0, 0.0, 8.0)}},
		# Bill preen at the shoulder, nibbling.
		{"id": "preen", "kind": "pulse", "a": 0.35, "h": 0.5, "r": 0.4, "neck": Vector3(-30.0, 50.0, -18.0),
			"ch_hz": 5.0, "ch": {"jaw": 0.3, "lid": 0.45}},
	]


func build_pieces() -> void:
	var secs: Array = MechHeadMeshes.DUCK_SECS
	var green: Callable = MechHeadMeshes._duck_green
	# Lower neck: brown chest band and the white ring.
	add_piece("NeckLow", "", Vector3(0.0, 0.0, 0.07))
	var k := kit()
	k.loft([_ring(secs[0]), _ring(secs[1]), _ring(secs[2])], [MechHeadMeshes.DUCK_BROWN, MechHeadMeshes.DUCK_RING],
		false, false)
	add_neck_plug(k, _ring(secs[0]))
	add_mesh("NeckLow", k)

	# Upper neck: starts hidden inside the ring, so it can stretch up without a gap.
	add_piece("NeckHigh", "NeckLow", Vector3(0.0, 0.18, 0.045))
	k = kit()
	k.loft([_ring(_lerp_sec(secs[0], secs[1], 0.06), HIDDEN), _ring(secs[3])], green, false, false)
	add_mesh("NeckHigh", k)

	add_piece("Skull", "NeckHigh", Vector3(0.0, 0.44, 0.03))
	var ks := kit()
	ks.loft([_ring(_lerp_sec(secs[2], secs[3], 0.4), SLEEVE), _ring(secs[4]), _ring(secs[5]), _ring(secs[6])], green,
		false, true)
	# Upper bill, nostrils, and the dark mouth behind the lower bill.
	MechHeadMeshes.duck_bill(ks, MechHeadMeshes.DUCK_BILL_UP, 6, MechHeadMeshes.DUCK_BILL)
	MechHeadMeshes.duck_nostrils(ks)
	ks.seg(Vector3(0, 0.695, -0.22), Vector3(0, 0.68, -0.56), Vector2(0.11, 0.04), Vector2.ZERO, 4, MOUTH, 2.0, false, 0.0)
	build_eye_set(ks, MechHeadMeshes.DUCK_EYE, MechHeadMeshes.DUCK_EYE_OUT, 1.1,
		{"brow": MechHeadMeshes.DUCK_BROW, "lid": MechHeadMeshes.DUCK_GREEN, "iris": IRIS, "pupil": PUPIL,
			"white": MechHeadMeshes.EYE_WHITE},
		{"eye": 0.05, "pupil": 0.026})
	add_mesh("Skull", ks)

	# Lower bill, hinged at the bill root.
	add_piece("Jaw", "Skull", Vector3(0.0, 0.7, -0.24))
	k = kit()
	MechHeadMeshes.duck_bill(k, MechHeadMeshes.DUCK_BILL_LOW, 4, MechHeadMeshes.DUCK_BILL.darkened(0.18))
	add_mesh("Jaw", k)

	# Crest tuft: three shards on one hinge at the back of the crown.
	add_piece("Crest", "Skull", Vector3(0.0, 1.02, 0.12))
	k = kit()
	for c: Array in MechHeadMeshes.DUCK_CREST:
		MechHeadMeshes.duck_shard(k, c[0], c[1], MechHeadMeshes.DUCK_GREEN.darkened(0.15))
	add_mesh("Crest", k)


## The two-bend neck: the standard joints, plus tall (flair raised) / collapsed S-bend (flair dropped). The tics' lift and
## waggle come through the standard neck (PilotIdle "lift" / "wobble").
func pose_neck(neck: PilotNeck) -> void:
	var tall := maxf(neck.flair_level, 0.0)
	var slump := maxf(-neck.flair_level, 0.0)
	var low := neck.low + Vector3(deg_to_rad(SLUMP_LOW) * slump, 0.0, 0.0)
	var high := neck.high + Vector3(deg_to_rad(SLUMP_HIGH) * slump, 0.0, 0.0)
	pose_neck_joints(low, high, neck.shift.x + SLUMP_SINK * slump, neck.shift.y, Vector3(0.0, NECK_TALL * tall, 0.0))
	var sq := neck.squash
	set_pose("Skull", Basis.from_scale(Vector3(1.0 + sq * squash_width, 1.0 - sq, 1.0 + sq * squash_width)))


func pose_flair(_ch: Dictionary, neck: PilotNeck, _extra: Dictionary) -> void:
	set_pose("Crest", Basis.from_euler(Vector3(neck.flair.x, 0.0, neck.flair.y)))


## The bill: mouth_curve tilts the lower bill to one side (no mouth corners on a bill); the jaw channel (moods, the
## quack and preen tics) opens it.
func pose_extra(ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	var open := clampf(float(ch["jaw"]), 0.0, 1.0)
	var mc := float(ch["mouth_curve"]) - float(rest["mouth_curve"])
	set_pose("Jaw", Basis(Vector3.FORWARD, deg_to_rad(6.0) * mc) * Basis(Vector3.RIGHT, -deg_to_rad(jaw_open) * open))


static func _ring(s: Array, scale: float = 1.0) -> PackedVector3Array:
	return MeshKit.ring(Vector3(0, s[0], s[1]), float(s[2]) * scale, float(s[3]) * scale, 8, "y", 2.2)


static func _lerp_sec(a: Array, b: Array, y: float) -> Array:
	var t := (y - float(a[0])) / (float(b[0]) - float(a[0]))
	var out := []
	for i in 4:
		out.append(lerpf(float(a[i]), float(b[i]), t))
	return out
