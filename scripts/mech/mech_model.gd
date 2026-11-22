class_name MechModel
extends Node3D
## The mech: a low-poly biped with reverse-jointed (chicken-style) legs, a rounded torso, a nose hatch the pilot's
## oversized head sticks out of, a back plate, and weapons on its five hardpoints. Faces -Z, origin on the ground between
## the feet. `art` picks the look: "lowpoly" (the art meshes: MechMeshes, assets/models/mech/) or "placeholder" (the
## primitive stand-in they replaced, kept for comparison); the rig, the node names and the hardpoints are the same. The SAME builder is used by the menu preview, the hangar line-up and the lab,
## so nothing can show a mech the game won't (Bridge to Friendship's rule for its character screen).
##
## Legs are posed by forward kinematics from a crouch value (thigh forward to the knee, shin back to the reverse "knee"
## (the ankle), tarsus forward to the foot), so the hip height follows from the leg lengths. The walk is a placeholder
## swing (no foot planting yet: the design wants procedural IK foot planting at all speeds).
##
## Lab subject (scripts/app/lab.gd): lab_params() / set_lab_param(), lab_options() / set_lab_option(), lab_focus().

const HULL := Color(0.48, 0.53, 0.58)
const ACCENT := Color(0.9, 0.48, 0.12)
const JOINT := Color(0.2, 0.21, 0.23)
const FWD := Vector3(0, 0, -1)

const PARAMS := [
	{"id": "thigh", "label": "Thigh length", "min": 0.5, "max": 2.0, "value": 0.9},
	{"id": "shin", "label": "Shin length", "min": 0.5, "max": 2.0, "value": 1.1},
	{"id": "tarsus", "label": "Tarsus length", "min": 0.3, "max": 1.5, "value": 0.55},
	{"id": "crouch", "label": "Crouch", "min": 0.0, "max": 1.0, "value": 0.35},
	{"id": "stance", "label": "Stance width", "min": 0.3, "max": 1.6, "value": 1.1},
	{"id": "body", "label": "Body scale", "min": 0.6, "max": 1.6, "value": 1.0},
	{"id": "head", "label": "Head scale", "min": 0.5, "max": 2.0, "value": 1.15},
	{"id": "gait", "label": "Walk rate (cycles/s)", "min": 0.0, "max": 2.0, "value": 0.0},
	{"id": "stride", "label": "Stride swing (rad)", "min": 0.0, "max": 0.8, "value": 0.4},
]

const ART_ORDER := ["lowpoly", "placeholder"]

var art := "lowpoly"
var head_id := "chicken"
var chassis_id := "strider"
var loadout: Dictionary = {}
var params: Dictionary = {}
## Seconds of idle bob / walk (the lab's speed scales it).
var time_scale := 1.0

var _t := 0.0
var _body: Node3D          ## everything above the hips (bobs, carries the head and weapons)
var _legs: Array = []      ## per side: {"side", "thigh", "shin", "tarsus", "knee", "ankle", "foot"}
var _hip_height := 0.0
var _ext_legs: Array = []              ## external (IK) leg pose, see set_external_pose()
var _ext_body_offset := Vector3.ZERO
var _ext_body_rot := Vector3.ZERO


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	if _body == null:
		rebuild()


## Set who it is and what it carries, and rebuild.
func configure(head: String, chassis: String, weapons: Dictionary) -> void:
	head_id = head if MechCatalog.HEADS.has(head) else "chicken"
	chassis_id = chassis if MechCatalog.CHASSIS.has(chassis) else "strider"
	loadout = MechCatalog.sanitize_loadout(chassis_id, weapons)
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_legs.clear()
	if loadout.is_empty():
		loadout = MechCatalog.sanitize_loadout(chassis_id, {})
	var s := float(params["body"])
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	if art == "lowpoly":
		_build_lowpoly(s)
	else:
		_build_placeholder(s)
	pose()


## The art meshes. Body parts sit in a "Chassis" node scaled by the body param, at MechMeshes.LAYOUT / MOUNTS.
func _build_lowpoly(s: float) -> void:
	var chassis := Node3D.new()
	chassis.name = "Chassis"
	chassis.scale = Vector3.ONE * s * MechMeshes.BODY_SCALE
	_body.add_child(chassis)
	for part: String in ["torso", "pelvis", "nose", "hatch", "back_plate"]:
		var mi := MechMeshes.instance(part)
		mi.name = part.capitalize().replace(" ", "")
		mi.position = MechMeshes.LAYOUT[part][0]
		mi.rotation_degrees = MechMeshes.LAYOUT[part][1]
		chassis.add_child(mi)
	for side: float in [-1.0, 1.0]:
		var pod := MechMeshes.instance("shoulder_pod")
		pod.name = "ShoulderPod_%s" % ("l" if side < 0.0 else "r")
		pod.position = (MechMeshes.LAYOUT["shoulder_pod"][0] as Vector3) * Vector3(side, 1, 1)
		pod.scale = Vector3(side, 1, 1)
		chassis.add_child(pod)
	# The pilot: only the head and neck stick out of the hatch.
	var seat := Node3D.new()
	seat.name = "Cockpit"
	seat.position = MechMeshes.LAYOUT["hatch"][0]
	chassis.add_child(seat)
	var head := MechParts.head(head_id, float(params["head"]) / (s * MechMeshes.BODY_SCALE))   # the head param is absolute
	head.position = Vector3(0, -0.12, 0)
	seat.add_child(head)
	# Hardpoints: the mount hardware (mirrored for the left) and the weapon.
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		var id := str(hp["id"])
		var node := Node3D.new()
		node.name = "HP_" + id
		node.position = MechMeshes.MOUNTS.get(id, Vector3.ZERO)
		chassis.add_child(node)
		var side := -1.0 if id.ends_with("_l") else 1.0
		var hw := ""
		var reach := Vector3.ZERO
		match str(hp["mount"]):
			"shoulder":
				hw = "shoulder_pylon"
				reach = MechMeshes.PYLON_TOP
			"side":
				hw = "side_mount"
				reach = MechMeshes.SIDE_REACH
		if hw != "":
			var mount := MechMeshes.instance(hw)
			mount.name = "Mount"
			mount.position = -reach * Vector3(side, 1, 1)
			mount.scale = Vector3(side, 1, 1)
			node.add_child(mount)
		var w := str(loadout.get(id, ""))
		if w != "":
			node.add_child(MechParts.weapon(w))
	# Legs: segments, joint caps and the foot (hub, three toes, spur), posed every frame.
	for side: float in [-1.0, 1.0]:
		var tag := "l" if side < 0.0 else "r"
		var leg := {"side": side}
		for part: String in ["thigh", "shin", "tarsus"]:
			var mi := MechMeshes.instance(part)
			mi.name = "%s_%s" % [part, tag]
			add_child(mi)
			leg[part] = mi
		for j: String in ["hip", "knee", "ankle"]:
			var cap := MechMeshes.instance(j + "_cap")
			cap.name = "%s_%s" % [j, tag]
			cap.scale = Vector3(side, 1, 1) * s
			add_child(cap)
			leg[j] = cap
		var foot := Node3D.new()
		foot.name = "foot_" + tag
		foot.scale = Vector3.ONE * s
		foot.add_child(MechMeshes.instance("foot"))
		for i in MechMeshes.TOES.size():
			var toe := MechMeshes.instance("toe")
			toe.name = "toe_%d" % i
			toe.position = MechMeshes.TOES[i][0]
			toe.rotation_degrees = Vector3(0, MechMeshes.TOES[i][1], 0)
			foot.add_child(toe)
		var spur := MechMeshes.instance("spur")
		spur.position = MechMeshes.SPUR_ROOT
		foot.add_child(spur)
		add_child(foot)
		leg["foot"] = foot
		_legs.append(leg)


## The primitive stand-in (boxes, spheres, cylinders).
func _build_placeholder(s: float) -> void:
	# Pelvis, torso pod, armour plates.
	_body.add_child(MechParts.box(Vector3(1.0, 0.35, 0.8) * s, JOINT, Vector3(0, 0, 0)))
	var torso := MechParts.box(Vector3(1.5, 0.95, 1.7) * s, HULL, Vector3(0, 0.6 * s, 0.1 * s))
	torso.name = "Torso"
	_body.add_child(torso)
	_body.add_child(MechParts.box(Vector3(1.55, 0.12, 1.2) * s, ACCENT, Vector3(0, 1.12 * s, 0.25 * s)))
	# Nose cockpit: a lower snout forward of the torso, the canopy, the pilot's head inside it.
	var nose := MechParts.box(Vector3(1.0, 0.6, 1.1) * s, HULL.lightened(0.1), Vector3(0, 0.35 * s, -1.2 * s))
	nose.name = "Nose"
	_body.add_child(nose)
	_body.add_child(MechParts.box(Vector3(1.04, 0.1, 0.3) * s, ACCENT, Vector3(0, 0.1 * s, -1.65 * s)))
	var seat := Node3D.new()
	seat.name = "Cockpit"
	seat.position = Vector3(0, 0.62 * s, -1.2 * s)
	_body.add_child(seat)
	seat.add_child(MechParts.head(head_id, float(params["head"]), false))
	var canopy := MechParts.sphere(0.62 * s, Color(0.6, 0.85, 1.0), Vector3(0, 0.25 * s, 0), 12, 0.22)
	canopy.name = "Canopy"
	canopy.scale = Vector3(1.0, 0.75, 1.0)
	seat.add_child(canopy)
	# Hardpoints (named after the chassis' ids) with their weapons.
	var mounts := {
		"side_l": Vector3(-0.95, 0.45, -0.2), "side_r": Vector3(0.95, 0.45, -0.2),
		"shoulder_l": Vector3(-0.6, 1.3, 0.2), "shoulder_r": Vector3(0.6, 1.3, 0.2),
		"back": Vector3(0, 1.2, 0.85),
	}
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		var node := Node3D.new()
		node.name = "HP_" + str(hp["id"])
		node.position = (mounts.get(hp["id"], Vector3.ZERO) as Vector3) * s
		_body.add_child(node)
		if str(hp["mount"]) == "side":
			node.add_child(MechParts.box(Vector3(0.3, 0.7, 0.35) * s, HULL.darkened(0.15), Vector3(0, 0.1, 0)))
		var w := str(loadout.get(hp["id"], ""))
		if w != "":
			var gun := MechParts.weapon(w, false)
			gun.scale = Vector3.ONE * s
			gun.position = Vector3(0, -0.2 * s, 0) if str(hp["mount"]) == "side" else Vector3.ZERO
			node.add_child(gun)
	# Legs: one set of segments per side, posed every frame.
	for side in [-1.0, 1.0]:
		var leg := {"side": side}
		for part in ["thigh", "shin", "tarsus"]:
			var mi := MechParts.unit_box(HULL if part != "shin" else HULL.darkened(0.1))
			mi.name = "%s_%s" % [part, "l" if side < 0.0 else "r"]
			add_child(mi)
			leg[part] = mi
		for j in ["knee", "ankle"]:
			var js := MechParts.sphere(0.17 * s, JOINT, Vector3.ZERO, 8)
			add_child(js)
			leg[j] = js
		var foot := Node3D.new()
		foot.name = "foot_%s" % ("l" if side < 0.0 else "r")
		for i in 3:
			var toe := MechParts.box(Vector3(0.12, 0.08, 0.55) * s, JOINT, Vector3((float(i) - 1.0) * 0.16 * s, 0.04, -0.25 * s))
			toe.rotation.y = (1.0 - float(i)) * 0.35
			foot.add_child(toe)
		foot.add_child(MechParts.box(Vector3(0.1, 0.08, 0.35) * s, JOINT, Vector3(0, 0.04, 0.2 * s)))
		add_child(foot)
		leg["foot"] = foot
		_legs.append(leg)


func _process(delta: float) -> void:
	_t += delta * time_scale
	pose()


## Leg segment lengths in model units: (thigh, shin, tarsus).
func leg_lengths() -> Vector3:
	var s := float(params["body"])
	return Vector3(float(params["thigh"]), float(params["shin"]), float(params["tarsus"])) * s


## The tarsus' lean forward of straight down (radians) for the current crouch.
func tarsus_lean() -> float:
	return lerpf(0.15, 0.5, float(params["crouch"]))


## Where hip `side` (-1 left, +1 right) sits in model space when standing, before any body offset.
func hip_local(side: float) -> Vector3:
	return Vector3(side * float(params["stance"]) * 0.5 * float(params["body"]), _hip_height, 0.0)


## Drive the legs from outside (procedural IK: MechRig). `legs`: per side (left, right) {hip, knee, ankle, foot} in model
## space; `body_offset` / `body_rot` move the body from its standing pose. Overrides the built-in walk until cleared.
func set_external_pose(legs: Array, body_offset: Vector3, body_rot: Vector3) -> void:
	_ext_legs = legs
	_ext_body_offset = body_offset
	_ext_body_rot = body_rot
	pose()


func clear_external_pose() -> void:
	_ext_legs = []
	pose()


## Place the body and legs for the current time and params.
func pose() -> void:
	if _body == null:
		return
	var s := float(params["body"])
	var c := float(params["crouch"])
	var lt := float(params["thigh"]) * s
	var ls := float(params["shin"]) * s
	var lm := float(params["tarsus"]) * s
	var a_t := lerpf(0.3, 0.95, c)     # thigh: forward of straight down
	var a_s := -lerpf(0.45, 1.15, c)   # shin: back (the reverse joint)
	var a_m := tarsus_lean()           # tarsus: forward again
	_hip_height = lt * cos(a_t) + ls * cos(a_s) + lm * cos(a_m)
	if _ext_legs.size() == _legs.size() and not _legs.is_empty():
		_pose_external(s)
		return
	var gait := float(params["gait"])
	var walking := gait > 0.0
	var phase := _t * TAU * gait
	var bob := (absf(sin(phase)) * 0.08 * s) if walking else sin(_t * 1.6) * 0.02 * s
	var hip_y := _hip_height + bob
	_body.position = Vector3(0, hip_y + 0.1 * s, 0)
	_body.rotation = Vector3(0.03 * sin(phase * 2.0) if walking else 0.0, 0.0, 0.04 * sin(phase) if walking else 0.0)
	var stride := float(params["stride"])
	var w := float(params["stance"]) * 0.5 * s
	for leg: Dictionary in _legs:
		var side := float(leg["side"])
		var lp := phase + (PI if side > 0.0 else 0.0)
		var swing := stride * sin(lp) if walking else 0.0
		var lift := maxf(0.0, cos(lp)) * 0.35 if walking else 0.0   # fold the leg while it swings forward
		var hip := Vector3(side * w, hip_y, 0)
		var knee := hip + _dir(a_t + swing + lift) * lt
		var ankle := knee + _dir(a_s + swing - lift * 1.4) * ls
		var foot := ankle + _dir(a_m + swing + lift * 0.6) * lm
		_place_leg(leg, hip, knee, ankle, foot, s)


func _pose_external(s: float) -> void:
	_body.position = Vector3(0, _hip_height + 0.1 * s, 0) + _ext_body_offset
	_body.rotation = _ext_body_rot
	for i in _legs.size():
		var leg: Dictionary = _legs[i]
		var p: Dictionary = _ext_legs[i]
		var hip: Vector3 = p["hip"]
		var knee: Vector3 = p["knee"]
		var ankle: Vector3 = p["ankle"]
		var foot: Vector3 = p["foot"]
		_place_leg(leg, hip, knee, ankle, foot, s)


## Put one leg's segments, joint caps and foot on its four joint points (model space).
func _place_leg(leg: Dictionary, hip: Vector3, knee: Vector3, ankle: Vector3, foot: Vector3, s: float) -> void:
	leg["points"] = {"hip": hip, "knee": knee, "ankle": ankle, "foot": foot}
	if art == "lowpoly":
		var mirror := float(leg["side"]) < 0.0
		MechParts.aim(leg["thigh"], hip, knee, MechMeshes.REST_LENGTH["thigh"], s, mirror)
		MechParts.aim(leg["shin"], knee, ankle, MechMeshes.REST_LENGTH["shin"], s, mirror)
		MechParts.aim(leg["tarsus"], ankle, foot, MechMeshes.REST_LENGTH["tarsus"], s, mirror)
		(leg["hip"] as Node3D).position = hip
	else:
		MechParts.span(leg["thigh"], hip, knee, 0.32 * s, 0.4 * s)
		MechParts.span(leg["shin"], knee, ankle, 0.24 * s, 0.3 * s)
		MechParts.span(leg["tarsus"], ankle, foot, 0.16 * s)
	(leg["knee"] as Node3D).position = knee
	(leg["ankle"] as Node3D).position = ankle
	(leg["foot"] as Node3D).position = foot


## The joint points leg `i` (0 left, 1 right) was last posed on, in model space: {hip, knee, ankle, foot}.
func leg_points(i: int) -> Dictionary:
	return (_legs[i] as Dictionary).get("points", {}) if i >= 0 and i < _legs.size() else {}


## A unit direction in the leg's plane, `a` radians forward of straight down.
static func _dir(a: float) -> Vector3:
	return Vector3(0, -cos(a), 0) + FWD * sin(a)


func hip_height() -> float:
	return _hip_height


# --- Lab subject --------------------------------------------------------------------------------------

func lab_params() -> Array:
	var out: Array = []
	for p: Dictionary in PARAMS:
		var d := p.duplicate()
		d["value"] = params[p["id"]]
		out.append(d)
	return out


func set_lab_param(id: String, v: float) -> void:
	params[id] = v
	if id in ["body", "head"]:
		rebuild()
	else:
		pose()


func lab_options() -> Array:
	var out: Array = [
		{"id": "art", "label": "Art", "choices": ART_ORDER, "value": art},
		{"id": "head", "label": "Head", "choices": MechCatalog.HEAD_ORDER, "value": head_id},
		{"id": "chassis", "label": "Chassis", "choices": MechCatalog.CHASSIS_ORDER, "value": chassis_id},
	]
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		var choices: Array = [""]
		choices.append_array(MechCatalog.weapons_for(str(hp["mount"])))
		out.append({"id": "hp:" + str(hp["id"]), "label": str(hp["label"]), "choices": choices, "value": str(loadout.get(hp["id"], ""))})
	return out


func set_lab_option(id: String, v: String) -> void:
	if id == "art":
		art = v if v in ART_ORDER else "lowpoly"
		rebuild()
	elif id == "head":
		configure(v, chassis_id, loadout)
	elif id == "chassis":
		configure(head_id, v, loadout)
	elif id.begins_with("hp:"):
		var l := loadout.duplicate()
		l[id.trim_prefix("hp:")] = v
		configure(head_id, chassis_id, l)


func lab_focus() -> Vector3:
	return Vector3(0, _hip_height * 0.9, 0)


func lab_radius() -> float:
	return 3.0 + _hip_height
