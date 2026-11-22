class_name RingWalkLab
extends Node3D
## Lab subject "Ring walk" (S1): a strip of a ring deck (curved floor, radial gravity) with curbs, a ramp and blocks, and
## a mech walking it with procedural foot planting. A bot drives it in several patterns (or you drive it: W/S forward,
## A/D turn, Q/E strafe, Shift run) so the gait can be tuned at every speed.

const MODES := ["patrol", "speed sweep", "circle", "strafe", "turn in place", "stand", "drive"]
const STRIP_WIDTH := 60.0
const STRIP_ARC := 160.0         ## floor length along the arc (m)
const SEG := 4.0                 ## floor segment length (m)

const PARAMS := [
	{"id": "radius", "label": "Ring radius (m)", "min": 60.0, "max": 600.0, "value": 140.0},
	{"id": "speed", "label": "Bot speed (0..run)", "min": 0.0, "max": 1.0, "value": 0.45},
	{"id": "walk_speed", "label": "Walk speed (m/s)", "min": 2.0, "max": 10.0, "value": 6.0},
	{"id": "run_speed", "label": "Run speed (m/s)", "min": 6.0, "max": 20.0, "value": 13.0},
	{"id": "turn_rate", "label": "Turn rate (rad/s)", "min": 0.3, "max": 4.0, "value": 1.8},
	{"id": "step_length", "label": "Max stride (m)", "min": 1.0, "max": 5.0, "value": 2.6},
	{"id": "step_time", "label": "Step time, walk (s)", "min": 0.2, "max": 1.2, "value": 0.55},
	{"id": "run_step_time", "label": "Step time, run (s)", "min": 0.15, "max": 0.8, "value": 0.32},
	{"id": "step_height", "label": "Step lift (m)", "min": 0.1, "max": 2.0, "value": 0.8},
	{"id": "bob", "label": "Body bob", "min": 0.0, "max": 0.5, "value": 0.12},
	{"id": "lean", "label": "Lean at run (rad)", "min": 0.0, "max": 0.4, "value": 0.12},
	{"id": "crouch", "label": "Crouch", "min": 0.0, "max": 1.0, "value": 0.35},
	{"id": "scale", "label": "Mech scale", "min": 1.0, "max": 3.0, "value": 2.0},
]

var time_scale := 1.0:
	set(v):
		time_scale = v
		Engine.time_scale = maxf(v, 0.0)
var mode := "patrol"
var bot_enabled := true          ## false: leave the mech's inputs to someone else (tests)
var params: Dictionary = {}
var ring: RingFrame
var mech: MechController
var rig: MechRig

var _floor: Node3D
var _t := 0.0
var _dir := 1.0


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	ring = RingFrame.new(float(params["radius"]))
	_build_floor()
	mech = MechController.new()
	mech.name = "Mech"
	mech.ring = ring
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	shape.shape = cap
	mech.add_child(shape)
	rig = MechRig.new()
	rig.name = "Rig"
	mech.add_child(rig)
	add_child(mech)
	_apply_params()
	_place_mech(0.0)


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func lab_own_ground() -> bool:
	return true


func _place_mech(s: float) -> void:
	var p := ring.arc_to_world(0.0, s, 0.05)
	mech.global_transform = Transform3D(ring.basis_at_arc(s), p)
	mech.velocity = Vector3.ZERO
	rig.gait.reset([])


func _apply_params() -> void:
	mech.walk_speed = float(params["walk_speed"])
	mech.run_speed = float(params["run_speed"])
	mech.turn_rate = float(params["turn_rate"])
	var g := rig.gait
	g.step_length = float(params["step_length"])
	g.step_time = float(params["step_time"])
	g.run_step_time = float(params["run_step_time"])
	g.step_height = float(params["step_height"])
	rig.bob = float(params["bob"])
	rig.lean = float(params["lean"])
	rig.set_scale_factor(float(params["scale"]))
	if rig.model != null:
		rig.model.params["crouch"] = float(params["crouch"])
	# Collision capsule: from the floor up to about the hip, sized with the mech.
	var sc := float(params["scale"])
	var cap := (mech.get_child(0) as CollisionShape3D).shape as CapsuleShape3D
	cap.radius = 1.1 * sc
	cap.height = 3.2 * sc
	(mech.get_child(0) as CollisionShape3D).position = Vector3(0, cap.height * 0.5, 0)


# --- Floor ------------------------------------------------------------------------------------------

func _build_floor() -> void:
	if _floor != null:
		remove_child(_floor)
		_floor.queue_free()
	_floor = Node3D.new()
	_floor.name = "Floor"
	add_child(_floor)
	var body := StaticBody3D.new()
	_floor.add_child(body)
	var n := int(STRIP_ARC / SEG)
	var seg_len := SEG * 1.02
	for i in n:
		var s := (float(i) + 0.5 - float(n) * 0.5) * SEG
		var light := (i % 2) == 0
		_slab(body, Vector3(0.0, s, -0.25), Vector3(STRIP_WIDTH, 0.5, seg_len),
				Color(0.86, 0.8, 0.68) if light else Color(0.8, 0.74, 0.62))
		_slab(body, Vector3(-STRIP_WIDTH * 0.5 + 1.0, s, 0.02), Vector3(0.3, 0.04, seg_len), Color(0.75, 0.42, 0.3), false)
	# Terrain to step on: curbs, a ramp, a raised block, scattered on the strip (arc coordinates: x, s, h).
	_slab(body, Vector3(6.0, 14.0, 0.2), Vector3(20.0, 0.4, 6.0), Color(0.62, 0.68, 0.55))     # low curb
	_slab(body, Vector3(6.0, 22.0, 0.45), Vector3(20.0, 0.9, 6.0), Color(0.58, 0.64, 0.5))     # high curb
	_slab(body, Vector3(-10.0, -24.0, 0.6), Vector3(10.0, 1.2, 12.0), Color(0.72, 0.5, 0.38))  # block
	_ramp(body, -10.0, -12.0, 12.0, 1.2, 10.0)
	for i in range(-3, 4):    # posts along the far edge, for reading the curve
		_slab(body, Vector3(STRIP_WIDTH * 0.5 - 2.0, float(i) * 22.0, 3.0), Vector3(1.0, 6.0, 1.0), Color(0.4, 0.55, 0.6))


## A box sitting on the curved floor at arc position (x, s) with its centre at height h.
func _slab(parent: StaticBody3D, at: Vector3, size: Vector3, c: Color, collide: bool = true) -> void:
	var b := ring.basis_at_arc(at.y)
	var p := ring.arc_to_world(at.x, at.y, at.z)
	var mi := MechParts.box(size, c)
	mi.transform = Transform3D(b, p)
	_floor.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.transform = mi.transform
		parent.add_child(cs)


## A ramp rising along +s from s0 to s0 + length, up to `rise`, `width` wide, at x.
func _ramp(parent: StaticBody3D, x: float, s0: float, length: float, rise: float, width: float) -> void:
	var slope := atan2(rise, length)
	var mid := s0 + length * 0.5
	var b := ring.basis_at_arc(mid) * Basis(Vector3.RIGHT, -slope)
	var p := ring.arc_to_world(x, mid, rise * 0.5 - 0.1)
	var size := Vector3(width, 0.3, sqrt(length * length + rise * rise))
	var mi := MechParts.box(size, Color(0.66, 0.6, 0.5))
	mi.transform = Transform3D(b, p)
	_floor.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = mi.transform
	parent.add_child(cs)


# --- Bot --------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if mech == null or not bot_enabled:
		return
	_t += delta
	var sp := float(params["speed"])
	var arc := ring.world_to_arc(mech.global_position)
	mech.running = false
	mech.move_input = Vector2.ZERO
	mech.turn_input = 0.0
	var want := sp * mech.run_speed   # wanted m/s, expressed through walk/run and input length
	var fwd := _input_for_speed(want)
	match mode:
		"patrol":
			# Walk along the arc; turn around near the ends, steering back toward the centre line.
			if (arc.y > STRIP_ARC * 0.38 and _dir > 0.0) or (arc.y < -STRIP_ARC * 0.38 and _dir < 0.0):
				_dir = -_dir
			_steer_toward_arc(Vector3(clampf(arc.x, -12.0, 12.0) * 0.5, arc.y + _dir * 20.0, 0.0), arc)
			mech.move_input = Vector2(0.0, fwd)
		"speed sweep":
			var k := 0.5 - 0.5 * cos(_t * TAU / 10.0)   # 0 -> 1 -> 0 over 10 s
			if (arc.y > STRIP_ARC * 0.38 and _dir > 0.0) or (arc.y < -STRIP_ARC * 0.38 and _dir < 0.0):
				_dir = -_dir
			_steer_toward_arc(Vector3(0.0, arc.y + _dir * 20.0, 0.0), arc)
			mech.move_input = Vector2(0.0, _input_for_speed(k * mech.run_speed))
		"circle":
			mech.move_input = Vector2(0.0, fwd)
			mech.turn_input = 0.45
		"strafe":
			mech.move_input = Vector2(fwd * (1.0 if fmod(_t, 6.0) < 3.0 else -1.0), 0.0)
		"turn in place":
			mech.turn_input = sign(sin(_t * 0.6)) * clampf(sp * 2.0, 0.2, 1.0)
		"stand":
			pass
		"drive":
			var mv := Vector2.ZERO
			if Input.is_physical_key_pressed(KEY_W): mv.y += 1.0
			if Input.is_physical_key_pressed(KEY_S): mv.y -= 1.0
			if Input.is_physical_key_pressed(KEY_E): mv.x += 1.0
			if Input.is_physical_key_pressed(KEY_Q): mv.x -= 1.0
			if Input.is_physical_key_pressed(KEY_A): mech.turn_input -= 1.0
			if Input.is_physical_key_pressed(KEY_D): mech.turn_input += 1.0
			mech.running = Input.is_physical_key_pressed(KEY_SHIFT)
			mech.move_input = mv
	# Fell off the strip: put it back.
	if absf(arc.x) > STRIP_WIDTH * 0.5 + 4.0 or arc.z < -20.0 or absf(arc.y) > STRIP_ARC * 0.5 + 4.0:
		_place_mech(0.0)


## Input length (and run flag) that gives `v` m/s.
func _input_for_speed(v: float) -> float:
	if v <= mech.walk_speed:
		return v / mech.walk_speed
	mech.running = true
	return clampf(v / mech.run_speed, 0.0, 1.0)


func _steer_toward_arc(goal: Vector3, here: Vector3) -> void:
	var gp := ring.arc_to_world(goal.x, goal.y, 0.0)
	var up := mech.up()
	var to := gp - mech.global_position
	to -= up * to.dot(up)
	if to.length_squared() < 1e-4:
		return
	var ang := mech.forward().signed_angle_to(to.normalized(), up)
	mech.turn_input = clampf(-ang * 2.0, -1.0, 1.0)


# --- Lab contract -----------------------------------------------------------------------------------

func lab_params() -> Array:
	var out: Array = []
	for p: Dictionary in PARAMS:
		var d := p.duplicate()
		d["value"] = params[p["id"]]
		out.append(d)
	return out


func set_lab_param(id: String, v: float) -> void:
	params[id] = v
	if id == "radius":
		ring.radius = maxf(v, 1.0)
		_build_floor()
		_place_mech(0.0)
	else:
		_apply_params()


func lab_options() -> Array:
	var head := rig.model.head_id if rig != null and rig.model != null else "chicken"
	return [
		{"id": "mode", "label": "Bot", "choices": MODES, "value": mode},
		{"id": "head", "label": "Head", "choices": MechCatalog.HEAD_ORDER, "value": head},
	]


func set_lab_option(id: String, v: String) -> void:
	if id == "mode" and v in MODES:
		mode = v
		_t = 0.0
	elif id == "head" and rig != null and rig.model != null:
		rig.model.configure(v, rig.model.chassis_id, rig.model.loadout)


func lab_focus() -> Vector3:
	if mech == null:
		return Vector3(0, 4, 0)
	return mech.global_position + mech.up() * 3.0 * float(params["scale"])


func lab_radius() -> float:
	return 7.0 * float(params["scale"])
