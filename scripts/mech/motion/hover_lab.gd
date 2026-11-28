class_name HoverLab
extends Node3D
## Lab subject "hover" (Wasp hover build step 1, docs/design/wasp-hover.md): a Wasp (a draft chassis: the lab builds it
## with MechSpawn.make(..., drafts = true)) on a small flat test world (+Y up, no ring) with a 12 m block, a 30 m block, a
## 20 deg ramp and, overhead, a slab on four pillars with a square opening in it. Scripted flights or the keyboard; a label
## over the mech shows heat, state, altitude and headroom. Every flight number (MechController's hover tunables) and the
## pose driver's look numbers (HoverPose) are sliders, starting at the catalog's / HoverPose's values.
##   drive: W/S forward / back, Q/E strafe, A/D turn, Shift boost, Space climb (lifts off), Ctrl descend (lands)

const MODES := ["patrol", "strafe", "over block", "slab", "landed", "overheat", "drive"]
const GROUND := 300.0
const BLOCK12 := [Vector3(0, 6, -45), Vector3(20, 12, 20)]       ## [centre, size]
const BLOCK30 := [Vector3(-55, 15, -45), Vector3(24, 30, 24)]
const RAMP_AT := Vector3(55, 0, -30)                              ## the ramp's low edge centre; it rises toward -Z
const RAMP_SIZE := Vector3(16, 0, 34)                             ## width, -, length along the ground
const RAMP_DEG := 20.0
const SLAB_AT := Vector3(0, 40, 70)                               ## the slab's underside centre
const SLAB_SIZE := Vector2(60, 2)                                 ## side, thickness
const HOLE := 14.0                                                ## the opening's side
const PILLAR := 3.0

## Controller params: lab id -> MechController var (values: the Wasp's catalog movement block).
const CTRL_PARAMS := {"cruise": "walk_speed", "boost": "run_speed", "accel": "accel", "drag": "hover_drag",
	"brake": "hover_brake", "turn": "turn_rate", "climb": "climb_rate", "climb_accel": "climb_accel",
	"hold": "hover_height", "ahead": "hover_ahead", "walk_heat": "walk_heat", "run_heat": "run_heat",
	"cooling": "cooling", "landed_cooling": "landed_cooling", "heat_cap": "heat_cap"}
## Pose params: lab id -> HoverPose var.
const POSE_PARAMS := {"bank_roll": "bank_roll", "bank_pitch": "bank_pitch", "bank_rate": "bank_rate",
	"tilt_gain": "tilt_gain", "spin_idle": "spin_idle", "spin_max": "spin_max", "legs_reach": "legs_reach",
	"swing": "swing", "bounce": "bounce"}
const PARAMS := [
	{"id": "cruise", "label": "Cruise speed (m/s)", "min": 6.0, "max": 30.0, "value": 16.0},
	{"id": "boost", "label": "Boost speed (m/s)", "min": 8.0, "max": 40.0, "value": 24.0},
	{"id": "accel", "label": "Accel (m/s^2)", "min": 5.0, "max": 60.0, "value": 22.0},
	{"id": "drag", "label": "Drift drag (1/s)", "min": 0.0, "max": 3.0, "value": 0.6},
	{"id": "brake", "label": "Drift brake (m/s^2)", "min": 0.0, "max": 20.0, "value": 3.0},
	{"id": "turn", "label": "Turn rate (rad/s)", "min": 0.5, "max": 5.0, "value": PI / 1.2},
	{"id": "climb", "label": "Climb rate (m/s)", "min": 2.0, "max": 25.0, "value": 9.0},
	{"id": "climb_accel", "label": "Climb accel (m/s^2)", "min": 4.0, "max": 60.0, "value": 18.0},
	{"id": "hold", "label": "Lowest hold height (m)", "min": 1.0, "max": 15.0, "value": 3.0},
	{"id": "ahead", "label": "Look-ahead (s)", "min": 0.0, "max": 3.0, "value": 1.2},
	{"id": "walk_heat", "label": "Move heat at cruise (/s)", "min": 0.0, "max": 20.0, "value": 2.5},
	{"id": "run_heat", "label": "Boost / climb heat (/s)", "min": 0.0, "max": 40.0, "value": 9.0},
	{"id": "cooling", "label": "Cooling (/s)", "min": 1.0, "max": 30.0, "value": 9.0},
	{"id": "landed_cooling", "label": "Landed cooling x", "min": 1.0, "max": 4.0, "value": 1.5},
	{"id": "heat_cap", "label": "Heat cap", "min": 40.0, "max": 200.0, "value": 90.0},
	{"id": "bank_roll", "label": "Bank roll (rad)", "min": 0.0, "max": 0.4, "value": 0.14},
	{"id": "bank_pitch", "label": "Bank pitch (rad)", "min": 0.0, "max": 0.3, "value": 0.10},
	{"id": "bank_rate", "label": "Bank ease (1/s)", "min": 0.5, "max": 20.0, "value": 5.0},
	{"id": "tilt_gain", "label": "Fan tilt gain", "min": 0.0, "max": 1.5, "value": 1.0},
	{"id": "spin_idle", "label": "Rotor idle (rev/s)", "min": 0.5, "max": 8.0, "value": 3.5},
	{"id": "spin_max", "label": "Rotor full (rev/s)", "min": 1.0, "max": 12.0, "value": 7.0},
	{"id": "legs_reach", "label": "Legs extend below (m)", "min": 0.5, "max": 12.0, "value": 4.0},
	{"id": "swing", "label": "Leg swing", "min": 0.0, "max": 0.5, "value": 0.12},
	{"id": "bounce", "label": "Touchdown dip", "min": 0.0, "max": 0.5, "value": 0.15},
]

var time_scale := 1.0:
	set(v):
		time_scale = v
		Engine.time_scale = maxf(v, 0.0)
var mode := "patrol"
var params: Dictionary = {}
var mech: MechController
var rig: MechRig
var hard_landings := 0
var worst_landing := 0.0

var _label: Label3D
var _t := 0.0
var _phase := 0
var _world: Node3D


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	_build_world()
	mech = MechSpawn.make("chicken", "wasp", {}, 0, "", true)
	add_child(mech)
	rig = MechSpawn.rig_of(mech)
	mech.hard_landing.connect(func(speed: float, _sev: float) -> void:
		hard_landings += 1
		worst_landing = maxf(worst_landing, speed))
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 64
	_label.pixel_size = 0.02
	_label.outline_size = 12
	_label.no_depth_test = true
	add_child(_label)
	_apply_params()
	var want := Boot.arg_value(OS.get_cmdline_user_args(), "--bot")   # e.g. --bot strafe (screenshots)
	if want in MODES:
		mode = want
	set_lab_option.call_deferred("mode", mode)


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func lab_own_ground() -> bool:
	return true


func _apply_params() -> void:
	if mech == null:
		return
	for id: String in CTRL_PARAMS:
		mech.set(CTRL_PARAMS[id], float(params[id]))
	mech.run_speed = maxf(mech.run_speed, mech.walk_speed)
	mech.heat_cap = maxf(mech.heat_cap, mech.reboot_heat + 5.0)
	for id: String in POSE_PARAMS:
		rig.hover_pose.set(POSE_PARAMS[id], float(params[id]))


## Put the mech at `at` facing `yaw` (rad about +Y, 0 = -Z), at rest; `landed` on its legs or hovering.
func place(at: Vector3, yaw: float = 0.0, landed: bool = true) -> void:
	mech.global_transform = Transform3D(Basis(Vector3.UP, yaw), at)
	mech.velocity = Vector3.ZERO
	mech.heat = 0.0
	mech.reset_heat()
	mech.set_landed(landed)
	rig.hover_pose.reset()


# --- World ------------------------------------------------------------------------------------------------------

func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "World"
	add_child(_world)
	var body := StaticBody3D.new()
	_world.add_child(body)
	_box(body, Vector3(0, -0.5, 0), Vector3(GROUND, 1, GROUND), Color(0.8, 0.76, 0.66))
	_box(null, Vector3(0, 0.02, 0), Vector3(10, 0.04, 10), Color(0.95, 0.62, 0.2))   # the pad
	_box(body, BLOCK12[0], BLOCK12[1], Color(0.62, 0.68, 0.55))
	_box(body, BLOCK30[0], BLOCK30[1], Color(0.55, 0.66, 0.72))
	_ramp(body)
	# The slab overhead: four plates round a square opening, on four pillars.
	var side := SLAB_SIZE.x
	var th := SLAB_SIZE.y
	var y := SLAB_AT.y + th * 0.5
	var w := (side - HOLE) * 0.5
	var c := Color(0.72, 0.62, 0.5)
	_box(body, SLAB_AT + Vector3(0, th * 0.5, -(HOLE + w) * 0.5), Vector3(side, th, w), c)
	_box(body, SLAB_AT + Vector3(0, th * 0.5, (HOLE + w) * 0.5), Vector3(side, th, w), c)
	_box(body, Vector3(SLAB_AT.x - (HOLE + w) * 0.5, y, SLAB_AT.z), Vector3(w, th, HOLE), c)
	_box(body, Vector3(SLAB_AT.x + (HOLE + w) * 0.5, y, SLAB_AT.z), Vector3(w, th, HOLE), c)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var p := SLAB_AT + Vector3(sx, 0, sz) * (side * 0.5 - PILLAR)
			_box(body, Vector3(p.x, SLAB_AT.y * 0.5, p.z), Vector3(PILLAR, SLAB_AT.y, PILLAR), c.darkened(0.2))
	# Height marks on the blocks' near faces.
	for b: Array in [BLOCK12, BLOCK30]:
		var at: Vector3 = b[0]
		var sz: Vector3 = b[1]
		_box(null, Vector3(at.x, sz.y - 0.3, at.z + sz.z * 0.5 + 0.05), Vector3(sz.x, 0.6, 0.1), Color(0.95, 0.5, 0.12))


func _box(parent: StaticBody3D, at: Vector3, size: Vector3, c: Color) -> void:
	var mi := MechParts.box(size, c)
	mi.position = at
	_world.add_child(mi)
	if parent != null:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.position = at
		parent.add_child(cs)


## A wedge: its low edge on the ground at RAMP_AT, rising RAMP_DEG toward -Z over RAMP_SIZE.z, with a vertical back face.
func _ramp(parent: StaticBody3D) -> void:
	var hw := RAMP_SIZE.x * 0.5
	var l := RAMP_SIZE.z
	var h := l * tan(deg_to_rad(RAMP_DEG))
	var o := RAMP_AT
	var a0 := o + Vector3(-hw, 0, 0)
	var a1 := o + Vector3(hw, 0, 0)
	var b0 := o + Vector3(-hw, 0, -l)
	var b1 := o + Vector3(hw, 0, -l)
	var t0 := o + Vector3(-hw, h, -l)
	var t1 := o + Vector3(hw, h, -l)
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([a0, a1, b0, b1, t0, t1])
	var cs := CollisionShape3D.new()
	cs.shape = shape
	parent.add_child(cs)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri: Array in [[a0, t0, t1], [a0, t1, a1], [b0, t1, t0], [b0, b1, t1], [a0, b0, t0], [a1, t1, b1]]:
		for p: Vector3 in tri:
			st.add_vertex(p)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = MechParts.mat(Color(0.86, 0.55, 0.42))
	_world.add_child(mi)


func ramp_height() -> float:
	return RAMP_SIZE.z * tan(deg_to_rad(RAMP_DEG))


# --- Flights ----------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if mech == null:
		return
	_t += delta
	var p := mech.global_position
	mech.move_input = Vector2.ZERO
	mech.turn_input = 0.0
	mech.running = false
	mech.climb_input = 0.0
	match mode:
		"patrol":
			# Lift off, fly out over the 12 m block, turn round, fly back, land on the pad, rest.
			match _phase:
				0:
					mech.climb_input = 1.0
					if mech.altitude() > 6.0:
						_next()
				1:
					mech.move_input = Vector2(0, 1)
					if p.z < -95.0:
						_next()
				2:
					mech.turn_input = 1.0
					if mech.forward().z > 0.98:
						_next()
				3:
					mech.move_input = Vector2(0, 1)
					if p.z > -2.0:
						_next()
				4:
					mech.climb_input = -1.0
					if mech.grounded():
						_next()
				5:
					mech.turn_input = 1.0 if mech.forward().z > -0.98 else 0.0
					if _t > 2.5:
						_phase = 0
						_t = 0.0
		"strafe":
			mech.move_input = Vector2(1.0 if fmod(_t, 5.0) < 2.5 else -1.0, 0.0)
			if mech.grounded() or mech.altitude() < 5.0:
				mech.climb_input = 1.0
		"over block":
			mech.move_input = Vector2(0.15 * sin(_t * 0.7), 0.0)
		"slab":
			match _phase:
				0:
					mech.climb_input = 1.0
					if p.y > SLAB_AT.y + SLAB_SIZE.y + 6.0:
						_next()
				1:
					if _t > 2.0:
						_next()
				2:
					mech.climb_input = -1.0
					if mech.grounded():
						_next()
				3:
					if _t > 2.0:
						_phase = 0
						_t = 0.0
		"landed":
			pass
		"overheat":
			match _phase:
				0:
					mech.climb_input = 1.0
					if p.y > 25.0:
						mech.add_heat(mech.heat_cap)
						_next()
				1:
					if not mech.shutdown and mech.grounded():
						_next()
				2:
					if _t > 1.5:
						_phase = 0
						_t = 0.0
		"drive":
			var mv := Vector2.ZERO
			if Input.is_physical_key_pressed(KEY_W): mv.y += 1.0
			if Input.is_physical_key_pressed(KEY_S): mv.y -= 1.0
			if Input.is_physical_key_pressed(KEY_E): mv.x += 1.0
			if Input.is_physical_key_pressed(KEY_Q): mv.x -= 1.0
			if Input.is_physical_key_pressed(KEY_A): mech.turn_input -= 1.0
			if Input.is_physical_key_pressed(KEY_D): mech.turn_input += 1.0
			mech.running = Input.is_physical_key_pressed(KEY_SHIFT)
			mech.climb_input = (1.0 if Input.is_physical_key_pressed(KEY_SPACE) else 0.0) \
				- (1.0 if Input.is_physical_key_pressed(KEY_CTRL) else 0.0)
			mech.move_input = mv.limit_length(1.0)
	if absf(p.x) > GROUND * 0.5 + 10.0 or absf(p.z) > GROUND * 0.5 + 10.0 or p.y < -20.0:
		set_lab_option("mode", mode)


func _next() -> void:
	_phase += 1
	_t = 0.0


func _process(_delta: float) -> void:
	if mech == null or _label == null:
		return
	var state := "SHUTDOWN" if mech.shutdown else ("LANDED" if mech.grounded() else "FLYING")
	var room := mech.headroom()
	_label.text = "heat %d%%  %s\naltitude %.1f m   headroom %s   speed %.1f m/s" % [int(100.0 * mech.heat / mech.heat_cap),
		state, mech.altitude(), "open" if room >= MechController.HEADROOM_MAX else "%.1f m" % room, mech.velocity.length()]
	_label.modulate = Color(1, 0.35, 0.25) if mech.shutdown else Color(1, 1, 1)
	_label.global_position = mech.global_position + Vector3.UP * 11.0


# --- Lab contract -----------------------------------------------------------------------------------------------

func lab_params() -> Array:
	return LabRegistry.param_rows(PARAMS, params)


func set_lab_param(id: String, v: float) -> void:
	params[id] = v
	_apply_params()


func lab_options() -> Array:
	return [{"id": "mode", "label": "Flight", "choices": MODES, "value": mode}]


func set_lab_option(id: String, v: String) -> void:
	if id != "mode" or not v in MODES or mech == null:
		return
	mode = v
	_t = 0.0
	_phase = 0
	hard_landings = 0
	worst_landing = 0.0
	match v:
		"strafe":
			place(Vector3(20, 6, 20), 0.0, false)
		"over block":
			var b: Vector3 = BLOCK12[0]
			place(Vector3(b.x, (BLOCK12[1] as Vector3).y + mech.hover_height + 2.0, b.z), 0.6, false)
		"slab":
			place(Vector3(SLAB_AT.x, 0.05, SLAB_AT.z), 0.0, true)
		_:
			place(Vector3(0, 0.05, 0), 0.0, true)


func lab_focus() -> Vector3:
	if mech == null:
		return Vector3(0, 4, 0)
	return mech.global_position + Vector3.UP * 3.0


func lab_radius() -> float:
	return 24.0
