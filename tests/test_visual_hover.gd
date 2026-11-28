extends TestCase
## VISUAL: the hover lab (Wasp hover build step 1), run with .\test_runner.ps1 -Visual -TestName test_visual_hover. Three
## shots of the pose driver (HoverPose), also copied to docs/design/chassis-concepts/build/: hovering in a strafe (legs
## dangling, banked, fans tilted), hovering over the 12 m block, and landed on its legs.

const VISUAL := true
const OUT := "res://docs/design/chassis-concepts/build"

var sc: ShotCheck
var lab: HoverLab
var cam: Camera3D


func setup() -> void:
	timeout_sec = 120.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_hover needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.72, 0.82)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.75, 0.8)
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0)
	sun.shadow_enabled = true
	add_child(sun)
	lab = HoverLab.new()
	add_child(lab)
	cam = Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.current = true
	await frames(5)
	lab.set_lab_option("mode", "strafe")
	await _fly(0.7)   # strafing right from rest, still accelerating: banked into it at the shot
	await _shot("wasp_hover_strafe", Vector3(-6, 3, -16))
	lab.set_lab_option("mode", "over block")
	await _fly(2.5)
	await _shot("wasp_hover_block", Vector3(-20, 2, 18))
	lab.set_lab_option("mode", "landed")
	await _fly(2.0)
	await _shot("wasp_hover_landed", Vector3(9, 3, -14))
	lab.queue_free()
	await frames(2)
	finish()


func _fly(sec: float) -> void:
	for i in int(sec * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


## Look at the mech from `off` (m, world) relative to it.
func _shot(n: String, off: Vector3) -> void:
	var at := lab.mech.global_position + Vector3.UP * 3.0
	cam.global_position = at + off
	cam.look_at(at, Vector3.UP)
	await frames(2)
	var img := await sc.grab(n)
	sc.not_blank(img, Rect2(0.2, 0.2, 0.6, 0.6), n)
	if img != null:
		img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, n]))
