class_name MechModel
extends Node3D
## The mech: a low-poly biped with reverse-jointed (chicken-style) legs, a rounded torso, a nose hatch the pilot's
## oversized head sticks out of, a back plate, and weapons on its five hardpoints. Faces -Z, origin on the ground between
## the feet. `art` picks the look: "lowpoly" (the art meshes: MechMeshes, assets/models/mech/) or "placeholder" (the
## primitive stand-in they replaced, kept for comparison); the rig, the node names and the hardpoints are the same. The SAME builder is used by the menu preview, the hangar line-up and the lab,
## so nothing can show a mech the game won't (Bridge to Friendship's rule for its character screen).
##
## `chassis_id` picks the chassis (MechCatalog.CHASSIS / ChassisParts): its parts, layout, mounts, leg rest lengths, pose
## angles and lab params all come from ChassisParts.of(chassis_id) (parts()). configure() with a different chassis also
## resets the leg params and leg_bend to that chassis' defaults. "strider" (default): the description above; "bulwark":
## the heavy gun platform (BulwarkMeshes: a low wide hull slung between two hip pods, the pilot in a well on its deck,
## long forward-knee legs, two side guns, two back mounts).
##
## Legs are posed by forward kinematics from a crouch value (with the default `leg_bend` -1: thigh back to the knee,
## shin forward to the ankle, tarsus back to the foot; +1 is the same chain mirrored fore-aft), so the hip height
## follows from the leg lengths. The walk is a placeholder
## swing (no foot planting yet: the design wants procedural IK foot planting at all speeds).
##
## Hip twist (set_external_pose's `leg_yaw`, driven by MechRig): the pelvis, the hip sockets and the legs turn about
## the body's vertical axis through the hip line while the torso, weapons and cockpit keep facing -Z.
##
## Lab subject (scripts/app/lab.gd): lab_params() / set_lab_param(), lab_options() / set_lab_option(), lab_focus().

const HULL := Color(0.48, 0.53, 0.58)
const JOINT := Color(0.2, 0.21, 0.23)
const FWD := Vector3(0, 0, -1)

const PARAMS := [
	{"id": "thigh", "label": "Thigh length", "min": 0.5, "max": 2.0, "value": 1.1},
	{"id": "shin", "label": "Shin length", "min": 0.5, "max": 2.0, "value": 1.1},
	{"id": "tarsus", "label": "Tarsus length", "min": 0.3, "max": 1.5, "value": 0.55},
	{"id": "crouch", "label": "Crouch", "min": 0.0, "max": 1.0, "value": 0.475},
	{"id": "stance", "label": "Stance width", "min": 0.3, "max": 2.0, "value": 1.35},
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
## The player's accent colour (cosmetic): tints the low-poly parts' accent surfaces (MechMeshes.apply_accent) and the
## placeholder's trim. Set with set_accent().
var accent: Color = MechMeshes.ORANGE
## The pilot's expressive head in the cockpit (low-poly art only; null for the placeholder). Rebuilt (a new node) on
## every rebuild(). `pilot_seed`: its look seed (idle blinks / glances; e.g. the roster slot), set before configure().
var pilot: PilotHead
var pilot_seed := 0
## Which way the leg chain bends (cosmetic, every machine uses the same default): -1 = the "real chicken walk" (thigh
## back-down from the hip to a knee pointing BACK, shin forward-down to the ankle, tarsus leaning back to the foot);
## +1 = the old leg (knee forward, ankle back). The whole chain is mirrored fore-aft about the hip, the segment meshes
## included (their front/back detail mirrors with the bend); the feet, toes and spur keep their facing. Hip height,
## foot lift and step-up do not depend on it. Read by the FK pose here and by MechRig's IK (LegIK.solve_leg's bend).
var leg_bend := -1.0
const BEND_ORDER := ["chicken", "forward"]   ## lab option "legs": leg_bend -1, +1

var _t := 0.0
var _body: Node3D          ## everything above the hips (bobs, carries the head and weapons)
var _legs: Array = []      ## per side: {"side", "thigh", "shin", "tarsus", "knee", "ankle", "foot"}
var _hip_height := 0.0
var _ext_legs: Array = []              ## external (IK) leg pose, see set_external_pose()
var _ext_body_offset := Vector3.ZERO
var _ext_body_rot := Vector3.ZERO
var _leg_yaw := 0.0                    ## hip twist (rad, + = legs turned toward the body's right), see set_external_pose()
var _pelvis: Node3D                    ## the pelvis mesh (or the placeholder's pelvis box): turns with the legs


## Authority (scripts/net/net.gd): who it is (head, chassis, loadout, accent, leg shape) is fixed at spawn from the crew
## entry; the pose is presentation, recomputed on every machine (MechRig drives it from the mech's motion).
func net_fields() -> Dictionary:
	return {"art": Net.LOCAL, "head_id": Net.SPAWN, "chassis_id": Net.SPAWN, "loadout": Net.SPAWN, "params": Net.SPAWN,
		"time_scale": Net.LOCAL, "accent": Net.SPAWN, "pilot": Net.LOCAL, "pilot_seed": Net.LOCAL, "leg_bend": Net.SPAWN,
		"_t": Net.LOCAL, "_body": Net.LOCAL, "_legs": Net.LOCAL, "_hip_height": Net.LOCAL, "_ext_legs": Net.LOCAL,
		"_ext_body_offset": Net.LOCAL, "_ext_body_rot": Net.LOCAL, "_leg_yaw": Net.LOCAL, "_pelvis": Net.LOCAL}


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	if _body == null:
		rebuild()


## Set who it is and what it carries, and rebuild.
func configure(head: String, chassis: String, weapons: Dictionary) -> void:
	head_id = head if MechCatalog.HEADS.has(head) else "chicken"
	var prev := chassis_id
	chassis_id = chassis if MechCatalog.CHASSIS.has(chassis) and ChassisParts.has(chassis) else "strider"
	if chassis_id != prev:
		_apply_chassis_defaults()
	loadout = MechCatalog.sanitize_loadout(chassis_id, weapons)
	rebuild()


## The chassis' art data (ChassisParts: parts, layout, mounts, rest lengths, pose angles, lab params).
func parts() -> Dictionary:
	return ChassisParts.of(chassis_id)


## The lab params with the chassis' defaults and ranges (MechModel.PARAMS for the Strider).
func param_specs() -> Array:
	return parts().get("params", PARAMS)


## A new chassis brings its own leg shape: its default leg params and bend (body and head scale, walk rate stay).
func _apply_chassis_defaults() -> void:
	for p: Dictionary in param_specs():
		if not str(p["id"]) in ["body", "head", "gait"]:
			params[p["id"]] = p["value"]
	leg_bend = float(parts()["bend"])


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_legs.clear()
	_pelvis = null
	pilot = null
	if loadout.is_empty():
		loadout = MechCatalog.sanitize_loadout(chassis_id, {})
	var s := float(params["body"])
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	if art == "lowpoly":
		_build_lowpoly(s)
		MechMeshes.apply_accent(self, accent)
	else:
		_build_placeholder(s)
	pose()


## Recolour the accent (no rebuild for the low-poly art; the placeholder bakes it into its trim boxes, so it rebuilds).
func set_accent(c: Color) -> void:
	accent = c
	if _body == null:
		return
	if art == "lowpoly":
		MechMeshes.apply_accent(self, accent)
	else:
		rebuild()


## The art meshes, from the chassis' entry in ChassisParts (parts()). Body parts sit in a "Chassis" node scaled by the
## body param, at its layout / mounts. Node names are the same on every chassis (Torso, Pelvis, Nose, Hatch, Cockpit,
## HP_<id>, thigh_l / shin_l / tarsus_l, socket_l, hip_l / knee_l / ankle_l, foot_l, ...).
func _build_lowpoly(s: float) -> void:
	var pa := parts()
	var layout: Dictionary = pa["layout"]
	var bs := float(pa["body_scale"])
	var chassis := Node3D.new()
	chassis.name = "Chassis"
	chassis.scale = Vector3.ONE * s * bs
	_body.add_child(chassis)
	for rp: Array in pa["body"]:
		var role := str(rp[0])
		var mi := ChassisParts.instance(str(rp[1]))
		mi.name = role.capitalize().replace(" ", "")
		mi.position = layout[role][0]
		mi.rotation_degrees = layout[role][1]
		chassis.add_child(mi)
		if role == "pelvis":
			_pelvis = mi
	for rp: Array in pa["mirrored"]:
		var role := str(rp[0])
		for side: float in [-1.0, 1.0]:
			var pod := ChassisParts.instance(str(rp[1]))
			pod.name = "%s_%s" % [role.capitalize().replace(" ", ""), "l" if side < 0.0 else "r"]
			pod.position = (layout[role][0] as Vector3) * Vector3(side, 1, 1)
			pod.scale = Vector3(side, 1, 1)
			chassis.add_child(pod)
	# The pilot: only the head and neck stick out of the hatch.
	var seat := Node3D.new()
	seat.name = "Cockpit"
	seat.position = layout["hatch"][0]
	chassis.add_child(seat)
	var head := Node3D.new()   # the expressive pilot head (PilotHead), in a holder named like the static head was
	head.name = "Head_" + head_id
	head.scale = Vector3.ONE * float(params["head"]) / (s * bs)   # the head param is absolute
	head.position = Vector3(0, -0.12, 0)
	seat.add_child(head)
	pilot = PilotHead.make(head_id, pilot_seed)
	pilot.idle_always = true   # idles on its own (menu, hangar, lab); MechRig turns it off when it feeds the head
	head.add_child(pilot)
	# Hardpoints: the mount hardware (mirrored for the left) and the weapon.
	var mounts: Dictionary = pa["mounts"]
	var mount_hw: Dictionary = pa["mount_hw"]
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		var id := str(hp["id"])
		var node := Node3D.new()
		node.name = "HP_" + id
		node.position = mounts.get(id, Vector3.ZERO)
		chassis.add_child(node)
		var side := -1.0 if id.ends_with("_l") else 1.0
		if mount_hw.has(str(hp["mount"])):
			var hw: Array = mount_hw[str(hp["mount"])]
			var mount := ChassisParts.instance(str(hw[0]))
			mount.name = "Mount"
			mount.position = -(hw[1] as Vector3) * Vector3(side, 1, 1)
			mount.scale = Vector3(side, 1, 1)
			node.add_child(mount)
		var w := str(loadout.get(id, ""))
		if w != "":
			node.add_child(MechParts.weapon(w))
	# Legs: segments, joint caps and the foot (hub or boot, toes, spur), posed every frame.
	var lp: Dictionary = pa["legs"]
	for side: float in [-1.0, 1.0]:
		var tag := "l" if side < 0.0 else "r"
		var leg := {"side": side}
		for part: String in ["thigh", "shin", "tarsus"]:
			var mi := ChassisParts.instance(str(lp[part]))
			mi.name = "%s_%s" % [part, tag]
			add_child(mi)
			leg[part] = mi
		# The hip is a ball joint: the socket is part of the pelvis (it rides the body), the ball sits on the pivot.
		var socket := ChassisParts.instance(str(lp["socket"]))
		socket.name = "socket_" + tag
		socket.scale = Vector3(side, 1, 1) * s
		_body.add_child(socket)
		leg["socket"] = socket
		for j: String in ["hip", "knee", "ankle"]:
			var cap := ChassisParts.instance(str(lp[j]))
			cap.name = "%s_%s" % [j, tag]
			cap.scale = Vector3(side, 1, 1) * s
			add_child(cap)
			leg[j] = cap
		var foot := Node3D.new()
		foot.name = "foot_" + tag
		foot.scale = Vector3.ONE * s
		foot.add_child(ChassisParts.instance(str(lp["foot"])))
		var toes: Array = pa["toes"]
		for i in toes.size():
			var toe := ChassisParts.instance(str(toes[i][0]))
			toe.name = "toe_%d" % i
			toe.position = toes[i][1]
			toe.rotation_degrees = Vector3(0, toes[i][2], 0)
			foot.add_child(toe)
		var spur := ChassisParts.instance(str(pa["spur"][0]))
		spur.name = "spur"
		spur.position = pa["spur"][1]
		foot.add_child(spur)
		add_child(foot)
		leg["foot"] = foot
		_legs.append(leg)


## The primitive stand-in (boxes, spheres, cylinders).
func _build_placeholder(s: float) -> void:
	# Pelvis, torso pod, armour plates.
	_pelvis = MechParts.box(Vector3(1.0, 0.35, 0.8) * s, JOINT, Vector3(0, 0, 0))
	_body.add_child(_pelvis)
	var torso := MechParts.box(Vector3(1.5, 0.95, 1.7) * s, HULL, Vector3(0, 0.6 * s, 0.1 * s))
	torso.name = "Torso"
	_body.add_child(torso)
	_body.add_child(MechParts.box(Vector3(1.55, 0.12, 1.2) * s, accent, Vector3(0, 1.12 * s, 0.25 * s)))
	# Nose cockpit: a lower snout forward of the torso, the canopy, the pilot's head inside it.
	var nose := MechParts.box(Vector3(1.0, 0.6, 1.1) * s, HULL.lightened(0.1), Vector3(0, 0.35 * s, -1.2 * s))
	nose.name = "Nose"
	_body.add_child(nose)
	_body.add_child(MechParts.box(Vector3(1.04, 0.1, 0.3) * s, accent, Vector3(0, 0.1 * s, -1.65 * s)))
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
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	pose()
	if PerfProbe.on:
		PerfProbe.add("proc.model_pose", Time.get_ticks_usec() - pp0)


## Leg segment lengths in model units: (thigh, shin, tarsus).
func leg_lengths() -> Vector3:
	var s := float(params["body"])
	return Vector3(float(params["thigh"]), float(params["shin"]), float(params["tarsus"])) * s


## The tarsus' lean forward of straight down (radians) for the current crouch.
func tarsus_lean() -> float:
	var tl: Vector2 = parts()["tarsus_lean"]
	return lerpf(tl.x, tl.y, float(params["crouch"]))


## Where hip `side` (-1 left, +1 right) sits in model space when standing, before any body offset.
func hip_local(side: float) -> Vector3:
	return Vector3(side * float(params["stance"]) * 0.5 * float(params["body"]), _hip_height, 0.0)


## Hip `side`'s pivot in model space with the body moved by `body_offset` and turned by `body_rot` (radians, the
## body node's own rotation) from its standing pose: the hips are part of the pelvis, so they move with it.
## `leg_yaw`: the hip twist (rad, + = toward the body's right), turning the hip line about the body's vertical axis.
func hip_posed(side: float, body_offset: Vector3, body_rot: Vector3, leg_yaw: float = 0.0) -> Vector3:
	return _body_rest() + body_offset + Basis.from_euler(body_rot) * (twist_basis(leg_yaw) * _hip_in_body(side))


## The rotation of the hip twist `leg_yaw` (rad, + = toward the body's right) about the model's up.
static func twist_basis(leg_yaw: float) -> Basis:
	return Basis(Vector3.UP, -leg_yaw)


## The body node's standing position (its origin is 0.1 above the hip line), and a hip pivot relative to it.
func _body_rest() -> Vector3:
	return Vector3(0, _hip_height + 0.1 * float(params["body"]), 0)


func _hip_in_body(side: float) -> Vector3:
	var s := float(params["body"])
	return Vector3(side * float(params["stance"]) * 0.5 * s, -0.1 * s, 0.0)


## How far a foot can lift straight up from standing before the leg folds past `fold` (the hip-to-ankle distance as
## a share of thigh + shin), in model units. The gait's step arc and the max step-up come from this.
func max_foot_lift(fold: float = 0.45) -> float:
	var l := leg_lengths()
	return maxf(_hip_height - l.z * cos(tarsus_lean()) - fold * (l.x + l.y), 0.0)


## Drive the legs from outside (procedural IK: MechRig). `legs`: per side (left, right) {hip, knee, ankle, foot} in model
## space; `body_offset` / `body_rot` move the body from its standing pose. Overrides the built-in walk until cleared.
## `leg_yaw`: the hip twist (rad, + = toward the body's right): the pelvis, sockets, knee planes and joint caps turn by
## it. A leg may carry "foot_dir" (model space, horizontal): where that foot's toes point (default: the legs' forward).
func set_external_pose(legs: Array, body_offset: Vector3, body_rot: Vector3, leg_yaw: float = 0.0) -> void:
	_ext_legs = legs
	_ext_body_offset = body_offset
	_ext_body_rot = body_rot
	_leg_yaw = leg_yaw
	pose()


func clear_external_pose() -> void:
	_ext_legs = []
	_leg_yaw = 0.0
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
	var b := _bend()
	var pa := parts()
	var ta: Vector2 = pa["thigh_angle"]
	var sa: Vector2 = pa["shin_angle"]
	var a_t := lerpf(ta.x, ta.y, c) * b     # thigh: forward of straight down (back when flipped)
	var a_s := -lerpf(sa.x, sa.y, c) * b    # shin: back (the reverse joint; forward when flipped)
	var a_m := tarsus_lean() * b            # tarsus: forward again (back when flipped)
	_hip_height = lt * cos(a_t) + ls * cos(a_s) + lm * cos(a_m)
	var external := _ext_legs.size() == _legs.size() and not _legs.is_empty()
	var tw := twist_basis(_leg_yaw if external else 0.0)
	if _pelvis != null:   # the pelvis turns about the hip line's centre (the body's vertical axis)
		if art == "lowpoly":
			var rest: Array = pa["layout"]["pelvis"]
			_pelvis.transform = Transform3D(tw * Basis.from_euler((rest[1] as Vector3) * (PI / 180.0)), tw * (rest[0] as Vector3))
		else:
			_pelvis.basis = tw
	for leg: Dictionary in _legs:
		if leg.has("socket"):
			var side := float(leg["side"])
			var socket := leg["socket"] as Node3D
			socket.transform = Transform3D(tw * Basis.from_scale(Vector3(side, 1, 1) * s), tw * _hip_in_body(side))
	if external:
		_pose_external(s)
		return
	var gait := float(params["gait"])
	var walking := gait > 0.0
	var phase := _t * TAU * gait
	var bob := (absf(sin(phase)) * 0.08 * s) if walking else sin(_t * 1.6) * 0.02 * s
	_body.position = _body_rest() + Vector3(0, bob, 0)
	_body.rotation = Vector3(0.03 * sin(phase * 2.0) if walking else 0.0, 0.0, 0.04 * sin(phase) if walking else 0.0)
	var stride := float(params["stride"])
	for leg: Dictionary in _legs:
		var side := float(leg["side"])
		var lp := phase + (PI if side > 0.0 else 0.0)
		var swing := stride * sin(lp) if walking else 0.0
		var lift := (maxf(0.0, cos(lp)) * 0.35 if walking else 0.0) * b   # fold the leg while it swings forward
		var hip := hip_posed(side, Vector3(0, bob, 0), _body.rotation)
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
		_place_leg(leg, hip, knee, ankle, foot, s, _leg_yaw, p.get("foot_dir", Vector3.ZERO))


## Put one leg's segments, joint caps and foot on its four joint points (model space). `leg_yaw`: the hip twist (the
## knee plane and the caps turn with it); `foot_dir`: where the toes point (model space; zero = the legs' forward).
func _place_leg(leg: Dictionary, hip: Vector3, knee: Vector3, ankle: Vector3, foot: Vector3, s: float,
		leg_yaw: float = 0.0, foot_dir: Vector3 = Vector3.ZERO) -> void:
	leg["points"] = {"hip": hip, "knee": knee, "ankle": ankle, "foot": foot}
	var side := float(leg["side"])
	var tw := twist_basis(leg_yaw)
	var foot_yaw := -leg_yaw
	if Vector2(foot_dir.x, foot_dir.z).length_squared() > 1e-6:
		foot_yaw = atan2(-foot_dir.x, -foot_dir.z)   # the turn about +Y that brings -Z onto foot_dir
	if art == "lowpoly":
		var mirror := side < 0.0
		var right := tw * Vector3.RIGHT
		var b := _bend()   # flipped: the segments and caps are mirrored front-to-back too (their detail follows the bend)
		var rest: Dictionary = parts()["rest"]
		_aim(leg["thigh"], hip, knee, rest["thigh"], s, mirror, right, b)
		_aim(leg["shin"], knee, ankle, rest["shin"], s, mirror, right, b)
		_aim(leg["tarsus"], ankle, foot, rest["tarsus"], s, mirror, right, b)
		var cap_basis := tw * Basis.from_scale(Vector3(side, 1, b) * s)
		(leg["hip"] as Node3D).transform = Transform3D(cap_basis, hip)
		(leg["knee"] as Node3D).transform = Transform3D(cap_basis, knee)
		(leg["ankle"] as Node3D).transform = Transform3D(cap_basis, ankle)
		(leg["foot"] as Node3D).transform = Transform3D(Basis(Vector3.UP, foot_yaw).scaled(Vector3.ONE * s), foot)
		_seat_socket(leg, hip, knee, tw, s)
		return
	MechParts.span(leg["thigh"], hip, knee, 0.32 * s, 0.4 * s)
	MechParts.span(leg["shin"], knee, ankle, 0.24 * s, 0.3 * s)
	MechParts.span(leg["tarsus"], ankle, foot, 0.16 * s)
	(leg["knee"] as Node3D).position = knee
	(leg["ankle"] as Node3D).position = ankle
	(leg["foot"] as Node3D).transform = Transform3D(Basis(Vector3.UP, foot_yaw), foot)


## The hip socket's cup leans away from the thigh: SOCKET_TILT forward of upright in the standing pose (back with the
## old knee-forward leg), plus SOCKET_FOLLOW of the thigh's fore-aft swing from there. A fixed tilt alone cannot clear
## both ends of the swing (the thigh pod flares wide right under the ball, so swung fully back its upper end rises
## into the back of the cup, swung forward into the front); riding along with a share of the swing clears both.
## It pitches about the hip's own left-right axis: the pivot stays on the hip and the strut stays buried in the pelvis.
const SOCKET_TILT := 0.5236     ## 30 degrees
const SOCKET_FOLLOW := 0.6


func _seat_socket(leg: Dictionary, hip: Vector3, knee: Vector3, tw: Basis, s: float) -> void:
	if not leg.has("socket"):
		return
	var b := _bend()
	var d := tw.inverse() * (_body.transform.basis.orthonormalized().inverse() * (knee - hip))
	var pa := parts()
	var ta: Vector2 = pa["thigh_angle"]
	var pitch := atan2(d.z, -d.y)                                  # the thigh, + = back from straight down
	var rest := -lerpf(ta.x, ta.y, float(params["crouch"])) * b    # its standing pitch (pose()'s a_t)
	var tilt := b * float(pa["socket_tilt"]) - float(pa["socket_follow"]) * (pitch - rest)   # about +X: negative leans the cup forward
	var side := float(leg["side"])
	(leg["socket"] as Node3D).transform = Transform3D(tw * Basis(Vector3.RIGHT, tilt) * Basis.from_scale(Vector3(side, 1, 1) * s),
			tw * _hip_in_body(side))


## MechParts.aim with the leg's own right (the hip twist turns it): a low-poly segment from joint `a` down to `b`,
## stretched to fit, scaled `s` across, mirrored in X for the left leg. With right = +X it is MechParts.aim.
## `bend` < 0 also mirrors it in its own Z (front-to-back, the flipped leg: MechModel.leg_bend).
static func _aim(node: Node3D, a: Vector3, b: Vector3, rest: float, s: float, mirror: bool, right: Vector3,
		bend: float = 1.0) -> void:
	var d := a - b
	var length := maxf(d.length(), 0.001)
	var y := d / length
	var x := (right - y * y.dot(right)).normalized()
	var z := x.cross(y)
	node.transform = Transform3D(Basis(x * (-s if mirror else s), y * (length / rest), z * (-s if bend < 0.0 else s)), a)


## leg_bend as a clean sign (+1 or -1).
func _bend() -> float:
	return -1.0 if leg_bend < 0.0 else 1.0


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
	for p: Dictionary in param_specs():
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
		{"id": "chassis", "label": "Chassis", "choices": ChassisParts.ORDER, "value": chassis_id},   # the lab shows every built chassis
		{"id": "accent", "label": "Accent", "choices": MechMeshes.ACCENT_ORDER, "value": _accent_id()},
		{"id": "legs", "label": "Leg bend", "choices": BEND_ORDER, "value": bend_id()},
	]
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		var choices: Array = [""]
		choices.append_array(MechCatalog.items_for(hp))   # weapons, then back equipment (repair_drone, radiator, ammo_bin)
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
	elif id == "accent":
		set_accent(MechMeshes.ACCENTS.get(v, MechMeshes.ORANGE))
	elif id == "legs":
		set_bend_id(v)
	elif id.begins_with("hp:"):
		var l := loadout.duplicate()
		l[id.trim_prefix("hp:")] = v
		configure(head_id, chassis_id, l)


## The lab's name for leg_bend ("chicken" = -1, "forward" = +1), and setting it by that name.
func bend_id() -> String:
	return "forward" if leg_bend > 0.0 else "chicken"


func set_bend_id(v: String) -> void:
	leg_bend = 1.0 if v == "forward" else -1.0
	pose()


## The ACCENTS id of the current accent colour ("orange" when it is not one of them).
func _accent_id() -> String:
	for id: String in MechMeshes.ACCENT_ORDER:
		if (MechMeshes.ACCENTS[id] as Color).is_equal_approx(accent):
			return id
	return "orange"


func lab_focus() -> Vector3:
	return Vector3(0, _hip_height * 0.9, 0)


func lab_radius() -> float:
	return 3.0 + _hip_height
