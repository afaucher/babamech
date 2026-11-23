extends Node3D
## Review shots of a chassis at game scale (MechModel at mech scale 2, lab lighting), several views from one process:
##   .\run.ps1 --scene res://tools/models/chassis_shots.tscn --out <dir> [--chassis bulwark] [--views a,b,...]
## Run it on the hidden desktop (it draws): see docs/testing.md. Views (file <out>/<chassis>_<view>.png):
##   front34   three-quarter front          side      from the right
##   back_third_person  the chase camera's framing (ChaseCamera: 16 m behind a pivot 9.5 m up, 3.2 m right, pitch -0.18)
##   below     from the ground, looking up at the belly
##   vs_strider  side by side with the Strider, same scale, three-quarter front
##   stride    mid-stride (legs solved with LegIK: the right foot lifted and ahead, the left planted behind)
## Cosmetic tool only; quits when done.

const VIEWS := ["front34", "side", "back_third_person", "below", "vs_strider", "stride"]
const SCALE := 2.0

var _out := "res://test_logs/shots"
var _chassis := "bulwark"
var _views: Array = VIEWS
var _cam: Camera3D
var _main: MechModel
var _other: MechModel


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if Boot.arg_value(args, "--out") != "":
		_out = Boot.arg_value(args, "--out")
	if Boot.arg_value(args, "--chassis") != "":
		_chassis = Boot.arg_value(args, "--chassis")
	if Boot.arg_value(args, "--views") != "":
		_views = Array(Boot.arg_value(args, "--views").split(","))
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.72)
	e.ambient_light_energy = 0.55
	var env := WorldEnvironment.new()
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.95, 0.6, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	add_child(MechParts.box(Vector3(80, 0.1, 80), Color(0.3, 0.32, 0.34), Vector3(0, -0.05, 0)))
	var line := Color(0.4, 0.42, 0.45)
	for i in range(-20, 21):   # a 2 m grid
		add_child(MechParts.box(Vector3(80, 0.012, 0.03), line, Vector3(0, 0.005, float(i) * 2.0)))
		add_child(MechParts.box(Vector3(0.03, 0.012, 80), line, Vector3(float(i) * 2.0, 0.005, 0)))
	_main = _mech(_chassis, {"side_l": "autocannon", "side_r": "rockets", "back_l": "mortar", "back_r": "ammo_bin"})
	_other = _mech("strider", {})
	_cam = Camera3D.new()
	_cam.fov = 40.0
	add_child(_cam)
	_cam.make_current()
	_run.call_deferred()


func _mech(chassis: String, loadout: Dictionary) -> MechModel:
	var m := MechModel.new()
	m.configure("chicken", chassis, loadout)
	m.scale = Vector3.ONE * SCALE
	m.time_scale = 0.0
	add_child(m)
	return m


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out)
	var h := _main.hip_height() * SCALE
	print("chassis_shots %s: hip %.2f m" % [_chassis, h])
	for v: String in _views:
		_main.position = Vector3.ZERO
		_main.clear_external_pose()
		_other.visible = false
		var look := Vector3(0, 3.0, 0)
		var from := Vector3(9, 6, -11)
		_cam.fov = 40.0
		match v:
			"front34":
				from = Vector3(10.5, 5.5, -13.0)
				look = Vector3(0, 3.0, 0)
			"side":
				from = Vector3(19.0, 3.5, 0.0)
				look = Vector3(0, 3.0, 0)
			"back_third_person":
				_cam.fov = 70.0
				var pivot := Vector3(3.2, 9.5, 0.0)
				var dir := Vector3(0, sin(-0.18), -cos(-0.18))
				from = pivot - dir * 16.0
				look = pivot + dir * 10.0
			"below":
				from = Vector3(5.0, 0.4, -9.0)
				look = Vector3(0, 3.2, 0)
				_cam.fov = 50.0
			"vs_strider":
				_other.visible = true
				_other.position = Vector3(8.5, 0, 2.0)
				_main.position = Vector3(-4.5, 0, 0)
				from = Vector3(12.0, 8.0, -26.0)
				look = Vector3(2.0, 5.0, 0)
			"stride":
				_stride(_main)
				from = Vector3(15.0, 4.0, -9.0)
				look = Vector3(0, 2.6, 0)
		_cam.look_at_from_position(from, look, Vector3.UP)
		for i in 4:
			await RenderingServer.frame_post_draw
		var path := _out.path_join("%s_%s.png" % [_chassis, v])
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("shot %s %s" % [path, "ok" if err == OK else "error %d" % err])
	get_tree().quit()


## Mid-stride: the right foot lifted to the max foot lift and a stride ahead, the left planted a stride behind, the body
## leaning a little into the step.
static func _stride(m: MechModel) -> void:
	var l := m.leg_lengths()
	var lift := m.max_foot_lift()
	var off := Vector3(0, -0.03, 0)
	var rot := Vector3(-0.06, 0, 0.03)
	var legs: Array = []
	for side: float in [-1.0, 1.0]:
		var hip := m.hip_posed(side, off, rot)
		var foot := Vector3(m.hip_local(side).x, lift * 0.9, -0.32) if side > 0.0 else Vector3(m.hip_local(side).x, 0.0, 0.34)
		var r := LegIK.solve_leg(hip, foot, l.x, l.y, l.z, Vector3.UP, Vector3.FORWARD, m.tarsus_lean(), m.leg_bend)
		legs.append({"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"]})
	m.set_external_pose(legs, off, rot, 0.0)
