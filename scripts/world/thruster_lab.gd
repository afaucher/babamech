class_name ThrusterLab
extends Node3D
## Lab subject "Thrusters" (S2): a ring-deck strip with a row of towers of rising height and gaps between them, and a
## mech that hops, climbs, hovers, overheats and is dropped from a height to test the emergency burn and hard landings.
## A label over the mech shows heat, state and the last landing speed. The "Chassis" option rebuilds the mech as another
## chassis (MechCatalog.CHASSIS_ORDER) and loads its movement numbers into the params (the Bulwark's hop ceiling).
##   drive: W/S forward/back, A/D turn, Q/E strafe, Shift run, Space thrust

const MODES := ["climb towers", "hop", "hover", "drop test", "overheat", "stand", "drive"]
const STRIP_WIDTH := 50.0
const STRIP_ARC := 220.0
const SEG := 4.0
## Towers along +s: [s centre, height m]. Gaps of 8 m between 16 m wide towers.
const TOWERS := [[20.0, 4.0], [44.0, 9.0], [68.0, 15.0], [92.0, 22.0], [116.0, 12.0]]
const TOWER_SIZE := Vector2(16.0, 16.0)
## Hover mode turns the mech this far (radians, about local up) off the strip, so the lab's side view sees its back
## three-quarter on and both thruster jets apart, instead of one hiding the other.
const HOVER_YAW := -0.6

const PARAMS := [
	{"id": "thrust_accel", "label": "Thrust (m/s^2)", "min": 24.0, "max": 60.0, "value": 34.0},
	{"id": "gravity", "label": "Gravity (m/s^2)", "min": 9.0, "max": 30.0, "value": 22.0},
	{"id": "air_control", "label": "Air control", "min": 0.0, "max": 1.0, "value": 0.35},
	{"id": "thrust_heat", "label": "Thrust heat (/s)", "min": 5.0, "max": 60.0, "value": 24.0},
	{"id": "cooling", "label": "Cooling (/s)", "min": 2.0, "max": 30.0, "value": 9.0},
	{"id": "safe_land", "label": "Safe landing (m/s)", "min": 4.0, "max": 20.0, "value": 10.0},
	{"id": "hard_land", "label": "Worst landing (m/s)", "min": 10.0, "max": 40.0, "value": 18.0},
	{"id": "auto_burn", "label": "Emergency burn (0/1)", "min": 0.0, "max": 1.0, "value": 1.0},
	{"id": "auto_land", "label": "Auto-burn landing (m/s)", "min": 8.0, "max": 19.0, "value": 16.0},
	{"id": "drop_height", "label": "Drop test height (m)", "min": 5.0, "max": 120.0, "value": 40.0},
	{"id": "hover_height", "label": "Hover height (m)", "min": 3.0, "max": 30.0, "value": 10.0},
	{"id": "thrust_ceiling", "label": "Hop ceiling (m, 0 off)", "min": 0.0, "max": 20.0, "value": 0.0},
]
## Params loaded from the chassis' movement block when the chassis changes: param id -> MechController var.
const CHASSIS_PARAMS := {"thrust_accel": "thrust_accel", "air_control": "air_control", "thrust_heat": "thrust_heat",
	"cooling": "cooling", "safe_land": "safe_land_speed", "hard_land": "hard_land_speed", "auto_land": "auto_land_speed",
	"thrust_ceiling": "thrust_ceiling"}

var time_scale := 1.0:
	set(v):
		time_scale = v
		Engine.time_scale = maxf(v, 0.0)
var mode := "climb towers"
var chassis := "strider"
var bot_enabled := true
var params: Dictionary = {}
var ring: RingFrame
var mech: MechController
var hard_landings := 0             ## count since the mode started (tests)
var worst_landing := 0.0

var _label: Label3D
var _t := 0.0
var _floor: Node3D


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	ring = RingFrame.new(220.0)
	_build_floor()
	_make_mech()
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 64
	_label.pixel_size = 0.02
	_label.outline_size = 12
	_label.no_depth_test = true
	add_child(_label)
	_apply_params()
	place(0.0, 0.05)
	var want := Boot.arg_value(OS.get_cmdline_user_args(), "--bot")   # e.g. --bot hover (screenshots)
	if want in MODES:
		mode = want   # now, so the lab's Bot drop-down (built right after this) shows it
		set_lab_option.call_deferred("mode", want)


func _make_mech() -> void:
	mech = MechSpawn.make("chicken", chassis)
	mech.ring = ring
	add_child(mech)
	mech.hard_landing.connect(func(speed: float, _sev: float) -> void:
		hard_landings += 1
		worst_landing = maxf(worst_landing, speed))


## Rebuild the mech as chassis `id`, its movement numbers in the params.
func _set_chassis(id: String) -> void:
	if not MechCatalog.CHASSIS.has(id):
		return
	chassis = id
	var mv := MechCatalog.movement(id)
	for p: String in CHASSIS_PARAMS:
		params[p] = float(mv[CHASSIS_PARAMS[p]])
	if mech != null:
		remove_child(mech)
		mech.queue_free()
	_make_mech()
	_apply_params()


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func lab_own_ground() -> bool:
	return true


## Put the mech at arc position s, height h, facing +s (turned `yaw` radians about local up), at rest.
func place(s: float, h: float, yaw: float = 0.0) -> void:
	var b := ring.basis_at_arc(s)
	mech.global_transform = Transform3D(b.rotated(b.y.normalized(), yaw), ring.arc_to_world(0.0, s, h))
	mech.velocity = Vector3.ZERO
	MechSpawn.rig_of(mech).gait.reset([])


func _apply_params() -> void:
	mech.thrust_accel = float(params["thrust_accel"])
	mech.gravity = float(params["gravity"])
	mech.air_control = float(params["air_control"])
	mech.thrust_heat = float(params["thrust_heat"])
	mech.cooling = float(params["cooling"])
	mech.safe_land_speed = float(params["safe_land"])
	mech.hard_land_speed = maxf(float(params["hard_land"]), float(params["safe_land"]) + 1.0)
	mech.auto_burn = float(params["auto_burn"]) >= 0.5
	mech.auto_land_speed = float(params["auto_land"])
	mech.thrust_ceiling = float(params["thrust_ceiling"])


# --- Floor ------------------------------------------------------------------------------------------

func _build_floor() -> void:
	_floor = Node3D.new()
	_floor.name = "Floor"
	add_child(_floor)
	var body := StaticBody3D.new()
	_floor.add_child(body)
	var n := int(STRIP_ARC / SEG)
	for i in n:
		var s := (float(i) + 0.5) * SEG - 40.0
		_slab(body, Vector3(0.0, s, -0.25), Vector3(STRIP_WIDTH, 0.5, SEG * 1.02),
				Color(0.86, 0.8, 0.68) if i % 2 == 0 else Color(0.8, 0.74, 0.62))
	var cols := [Color(0.62, 0.68, 0.55), Color(0.86, 0.55, 0.42), Color(0.78, 0.76, 0.66), Color(0.55, 0.66, 0.72), Color(0.72, 0.62, 0.5)]
	for i in TOWERS.size():
		var t: Array = TOWERS[i]
		_slab(body, Vector3(0.0, t[0], float(t[1]) * 0.5), Vector3(TOWER_SIZE.x, t[1], TOWER_SIZE.y), cols[i % cols.size()])
		# A height mark on the front face.
		_slab(null, Vector3(0.0, float(t[0]) - TOWER_SIZE.y * 0.5 - 0.05, float(t[1]) - 0.3), Vector3(TOWER_SIZE.x, 0.6, 0.1), Color(0.95, 0.5, 0.12))


func _slab(parent: StaticBody3D, at: Vector3, size: Vector3, c: Color) -> void:
	var mi := MechParts.box(size, c)
	mi.transform = Transform3D(ring.basis_at_arc(at.y), ring.arc_to_world(at.x, at.y, at.z))
	_floor.add_child(mi)
	if parent != null:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.transform = mi.transform
		parent.add_child(cs)


## Height of the ground (floor or tower top) at arc position s.
func ground_height_at(s: float) -> float:
	for t: Array in TOWERS:
		if absf(s - float(t[0])) <= TOWER_SIZE.y * 0.5:
			return float(t[1])
	return 0.0


# --- Bot --------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if mech == null:
		return
	_t += delta
	var arc := ring.world_to_arc(mech.global_position)
	if bot_enabled:
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
		match mode:
			"climb towers":
				# Walk along +s; thrust when the next tower top is above what the legs can step onto; restart at the end.
				mech.move_input = Vector2(0, 1)
				var ahead := ground_height_at(arc.y + 10.0)
				var here := arc.z
				if ahead - here > mech.max_step_up * 0.9 or (not mech.grounded() and arc.z < ahead + 2.0 and ahead > 0.0):
					mech.thrust_input = true
				if arc.y > 130.0:
					place(0.0, 0.05)
			"hop":
				mech.move_input = Vector2(0, 0.6)
				mech.thrust_input = fmod(_t, 2.5) < 0.6
				if arc.y > 10.0:
					place(-30.0, 0.05)
			"hover":
				var target := float(params["hover_height"])
				var vs := mech.velocity.dot(mech.up())
				mech.thrust_input = arc.z + vs * 0.4 < target
			"drop test":
				if fmod(_t, 7.0) < delta:
					place(-25.0, float(params["drop_height"]))
			"overheat":
				mech.thrust_input = not mech.shutdown
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
				mech.thrust_input = Input.is_physical_key_pressed(KEY_SPACE)
				mech.move_input = mv
	if absf(arc.x) > STRIP_WIDTH * 0.5 + 6.0 or arc.z < -30.0 or arc.y < -45.0 or arc.y > STRIP_ARC - 40.0:
		place(0.0, 0.05)


func _process(_delta: float) -> void:
	if mech == null or _label == null:
		return
	var state := "SHUTDOWN" if mech.shutdown else ("EMERGENCY BURN" if mech.emergency else ("THRUST" if mech.thrusting else ""))
	_label.text = "heat %d%%  %s\nheight %.1f m   last landing %.1f m/s" % [int(100.0 * mech.heat / mech.heat_cap), state,
			ring.height(mech.global_position), mech.last_impact]
	_label.modulate = Color(1, 0.35, 0.25) if mech.shutdown else (Color(1, 0.75, 0.3) if mech.thrusting else Color(1, 1, 1))
	_label.global_position = mech.global_position + mech.up() * 16.0


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
	_apply_params()


func lab_options() -> Array:
	return [{"id": "mode", "label": "Bot", "choices": MODES, "value": mode},
		{"id": "chassis", "label": "Chassis", "choices": MechCatalog.CHASSIS_ORDER, "value": chassis}]


func set_lab_option(id: String, v: String) -> void:
	if id == "chassis" and v != chassis:
		_set_chassis(v)
		set_lab_option("mode", mode)
		return
	if id == "mode" and v in MODES:
		mode = v
		_t = 0.0
		hard_landings = 0
		worst_landing = 0.0
		mech.heat = 0.0
		mech.shutdown = false
		place(0.0 if v != "hop" else -30.0, 0.05, HOVER_YAW if v == "hover" else 0.0)


func lab_focus() -> Vector3:
	if mech == null:
		return Vector3(0, 6, 0)
	return mech.global_position + mech.up() * 6.0


func lab_radius() -> float:
	return 22.0
