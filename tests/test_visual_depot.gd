extends TestCase
## VISUAL: the supply depot model (docs/design/supply-depot.md "Build"; compare art/renders/depot_r1/B2_bunker_wall_*.png).
## The lab subject "depot" (scene + an 8 m mech for scale) on a sand floor. Shots in test_logs/shots/:
##   depot_chase_cap4_2     capacity 4, 2 stocked, chase framing: mech 14 m out walking up, camera ~11 m behind it
##   depot_chase_cap3_3     capacity 3, 3 stocked, same view
##   depot_far_40m          capacity 4, 2 stocked, from ~40 m (the read distance Missions asked for)
##   depot_destroyed        the wreck, same view as the chase shots
##   depot_close            capacity 4, 2 stocked, three-quarter close-up of the socket wall
##   depot_side             the +X side (emblem) and the roof marker
## Runs only under `.\test_runner.ps1 -Visual` (hidden desktop, takes the GPU lock).

const VISUAL := true

var sc: ShotCheck
var cam: Camera3D


func setup() -> void:
	timeout_sec = 180.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_depot needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var lab: Node3D = LabRegistry.make("depot")
	add_child(lab)
	var floor_k := MeshKit.new()
	floor_k.shade = 0.0
	floor_k.box(Vector3(160.0, 0.2, 160.0), Color(0.82, 0.74, 0.6), Vector3(0, -0.1, 0))
	var fl := MeshInstance3D.new()
	fl.mesh = floor_k.commit(LowPolyMaterials.materials())
	add_child(fl)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.66, 0.72, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.78, 0.77, 0.76)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.make_current()
	var focus := Vector3(0.0, 3.0, 0.0)
	# Chase framing: the mech walking up to the wall from 14 m out, the camera ~11 m behind it, a little to its right.
	var mech: Node3D = lab.get("mech")
	mech.position = Vector3(-5.5, 0.0, 14.0)
	mech.rotation = Vector3.ZERO
	var chase := Vector3(3.0, 9.0, 27.0)

	lab.call("set_lab_param", "capacity", 4.0)
	lab.call("set_lab_param", "stocked", 2.0)
	cam.look_at_from_position(chase, focus)
	await frames(8)
	var a := await sc.grab("depot_chase_cap4_2")
	sc.not_blank(a, Rect2(0.4, 0.3, 0.3, 0.4), "the depot")

	lab.call("set_lab_param", "capacity", 3.0)
	lab.call("set_lab_param", "stocked", 3.0)
	await frames(3)
	var b := await sc.grab("depot_chase_cap3_3")
	_differ(a, b, "3 of 3 differs from 2 of 4")

	lab.call("set_lab_param", "capacity", 4.0)
	lab.call("set_lab_param", "stocked", 2.0)
	mech.visible = false
	cam.look_at_from_position(Vector3(4.0, 9.0, 40.0), focus)
	await frames(3)
	await sc.grab("depot_far_40m")
	mech.visible = true

	cam.look_at_from_position(chase, focus)
	lab.call("set_lab_option", "destroyed", "on")
	await frames(3)
	var d := await sc.grab("depot_destroyed")
	_differ(a, d, "the wreck differs")
	lab.call("set_lab_option", "destroyed", "off")

	mech.position = Vector3(-8.0, 0.0, 5.0)
	mech.rotation.y = -PI * 0.35
	cam.look_at_from_position(Vector3(4.5, 4.0, 9.0), Vector3(0.0, 2.5, 1.0))
	await frames(3)
	var c := await sc.grab("depot_close")
	sc.not_blank(c, Rect2(0.3, 0.3, 0.4, 0.4), "the socket wall close")

	cam.look_at_from_position(Vector3(13.0, 7.0, 7.0), Vector3(0.0, 3.5, 0.0))
	await frames(3)
	await sc.grab("depot_side")
	finish()


## Two shots of the same view differ somewhere (a socket changing is a small patch of the frame).
func _differ(a: Image, b: Image, what: String) -> void:
	if a == null or b == null:
		return
	var changed := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.3:
				changed += 1
	check(changed >= 20, "%s (%d sampled pixels changed)" % [what, changed])
