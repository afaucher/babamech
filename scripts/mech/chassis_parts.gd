class_name ChassisParts
extends RefCounted
## The per-chassis art table (docs/design/chassis-rules.md 1.2): which parts a chassis is built from and where they go.
## MechModel reads everything chassis-specific from here (by MechModel.chassis_id), never from MechMeshes' constants
## directly. A chassis shares a part with another only by naming it: a part named "bulwark_*" is BulwarkMeshes', any other
## name MechMeshes' (the Bulwark names the Strider's "hatch"; both name the same weapons, equipment and heads).
##
## Entry keys:
##   body_scale   body parts and weapons are drawn this much larger than authored
##   layout       role -> [position, rotation degrees] in body space (MechMeshes.LAYOUT's form)
##   mounts       hardpoint id -> mount point in body space
##   rest         leg segment rest lengths {thigh, shin, tarsus}
##   body         [[role, part], ...]: the body parts, in node order (node name = the role, capitalised)
##   mirrored     [[role, part], ...]: right-side body parts also placed mirrored on the left (layout gives the right)
##   mount_hw     mount kind -> [part, reach]: the hardware under a hardpoint of that kind (none for a kind not listed)
##   legs         role -> part for thigh, shin, tarsus, socket, hip, knee, ankle, foot
##   toes         [[part, root, yaw degrees], ...] on the foot; spur [part, root]
##   bend         the leg chain's bend sign (MechModel.leg_bend's default for the chassis)
##   params       the lab params (MechModel.PARAMS' form) with this chassis' defaults; none = MechModel.PARAMS
##   thigh_angle / shin_angle / tarsus_lean: the standing pose's angles (rad) at crouch 0 and 1 (MechModel.pose)
##   socket_tilt / socket_follow: the hip socket's lean (MechModel._seat_socket)
## Cosmetic data only (no gameplay state).

const ORDER := ["strider", "bulwark"]

static var _cache: Dictionary = {}


## The chassis' entry (the Strider's for an unknown id).
static func of(id: String) -> Dictionary:
	if not _cache.has(id):
		_cache[id] = _bulwark() if id == "bulwark" else _strider()
	return _cache[id]


static func has(id: String) -> bool:
	return id in ORDER


## A part's mesh / instance / fresh build, whichever chassis' builder owns it.
static func mesh(part: String) -> ArrayMesh:
	return BulwarkMeshes.mesh(part) if part.begins_with(BulwarkMeshes.PREFIX) else MechMeshes.mesh(part)


static func instance(part: String) -> MeshInstance3D:
	return BulwarkMeshes.instance(part) if part.begins_with(BulwarkMeshes.PREFIX) else MechMeshes.instance(part)


static func build(part: String) -> ArrayMesh:
	return BulwarkMeshes.build(part) if part.begins_with(BulwarkMeshes.PREFIX) else MechMeshes.build(part)


static func _strider() -> Dictionary:
	return {
		"body_scale": MechMeshes.BODY_SCALE,
		"layout": MechMeshes.LAYOUT,
		"mounts": MechMeshes.MOUNTS,
		"rest": MechMeshes.REST_LENGTH,
		"body": [["torso", "torso"], ["pelvis", "pelvis"], ["nose", "nose"], ["hatch", "hatch"], ["back_plate", "back_plate"]],
		"mirrored": [["shoulder_pod", "shoulder_pod"]],
		"mount_hw": {"shoulder": ["shoulder_pylon", MechMeshes.PYLON_TOP], "side": ["side_mount", MechMeshes.SIDE_REACH]},
		"legs": {"thigh": "thigh", "shin": "shin", "tarsus": "tarsus", "socket": "hip_socket", "hip": "hip_cap",
			"knee": "knee_cap", "ankle": "ankle_cap", "foot": "foot"},
		"toes": [["toe", MechMeshes.TOES[0][0], MechMeshes.TOES[0][1]], ["toe", MechMeshes.TOES[1][0], MechMeshes.TOES[1][1]],
			["toe", MechMeshes.TOES[2][0], MechMeshes.TOES[2][1]]],
		"spur": ["spur", MechMeshes.SPUR_ROOT],
		"bend": -1.0,
		"thigh_angle": Vector2(0.3, 0.95),
		"shin_angle": Vector2(0.45, 1.15),
		"tarsus_lean": Vector2(0.15, 0.5),
		"socket_tilt": 0.5236,   # MechModel.SOCKET_TILT
		"socket_follow": 0.6,    # MechModel.SOCKET_FOLLOW
	}


## The Bulwark (BulwarkMeshes): sumo legs with forward knees (bend +1), thigh / shin / a short ankle block (the "tarsus",
## kept vertical: the ankle drum stays straight above the boot), a wide stance, a deep crouch.
static func _bulwark() -> Dictionary:
	return {
		"body_scale": BulwarkMeshes.BODY_SCALE,
		"layout": BulwarkMeshes.LAYOUT,
		"mounts": BulwarkMeshes.MOUNTS,
		"rest": BulwarkMeshes.REST_LENGTH,
		"body": [["torso", "bulwark_torso"], ["pelvis", "bulwark_pelvis"], ["nose", "bulwark_nose"], ["hatch", "hatch"]],
		"mirrored": [],
		"mount_hw": {"side": ["bulwark_side_mount", BulwarkMeshes.SIDE_REACH]},
		"legs": {"thigh": "bulwark_thigh", "shin": "bulwark_shin", "tarsus": "bulwark_ankle", "socket": "bulwark_hip_socket",
			"hip": "bulwark_hip_cap", "knee": "bulwark_knee_cap", "ankle": "bulwark_ankle_cap", "foot": "bulwark_boot"},
		"toes": [["bulwark_toe", BulwarkMeshes.TOES[0][0], BulwarkMeshes.TOES[0][1]],
			["bulwark_toe", BulwarkMeshes.TOES[1][0], BulwarkMeshes.TOES[1][1]]],
		"spur": ["bulwark_spur", BulwarkMeshes.SPUR_ROOT],
		"bend": 1.0,
		"params": [
			{"id": "thigh", "label": "Thigh length", "min": 0.45, "max": 1.0, "value": 0.66},
			{"id": "shin", "label": "Shin length", "min": 0.4, "max": 1.0, "value": 0.58},
			{"id": "tarsus", "label": "Ankle length", "min": 0.15, "max": 0.5, "value": 0.22},
			{"id": "crouch", "label": "Crouch", "min": 0.0, "max": 1.0, "value": 0.6},
			{"id": "stance", "label": "Stance width", "min": 1.4, "max": 2.6, "value": 2.0},
			{"id": "body", "label": "Body scale", "min": 0.6, "max": 1.6, "value": 1.0},
			{"id": "head", "label": "Head scale", "min": 0.5, "max": 2.0, "value": 1.15},
			{"id": "gait", "label": "Walk rate (cycles/s)", "min": 0.0, "max": 2.0, "value": 0.0},
			{"id": "stride", "label": "Stride swing (rad)", "min": 0.0, "max": 0.8, "value": 0.3},
		],
		"thigh_angle": Vector2(0.45, 1.05),
		"shin_angle": Vector2(0.55, 1.25),
		"tarsus_lean": Vector2(0.0, 0.0),
		"socket_tilt": 0.5236,
		"socket_follow": 0.6,
	}
