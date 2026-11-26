extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## VISUAL: the Bulwark in play, run with .\test_runner.ps1 -Visual -TestName test_visual_bulwark. Shots (also copied to
## docs/design/chassis-concepts/ingame/): the chase view with the HUD (its damage diagram, four weapon rows), first person
## forward and looking down from the pilot's well, the chase view while thrusting (jets under the engine block), a side
## view of the jets, and the hangar with the Bulwark picked.

const VISUAL := true
const PATH := "user://test_visual_bulwark_settings.cfg"
const OUT := "res://docs/design/chassis-concepts/ingame"

var sc: ShotCheck


func setup() -> void:
	timeout_sec = 120.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_bulwark needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var was := Session.chassis_id
	Session.chassis_id = "bulwark"
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(20)
	Session.chassis_id = was
	td.drive_override = true
	td.combat.squad.clear_enemies()
	# Some damage so the diagram shows colours.
	td.combat.player_target.apply_damage(300.0, "torso", "shot")
	td.combat.player_target.apply_damage(200.0, "leg_l", "shot")
	td.combat.player_target.apply_damage(50.0, "side_r", "shot")
	for i in 60:
		td.mech.move_input = Vector2(0, 0.6)
		await get_tree().physics_frame
	td.mech.move_input = Vector2.ZERO
	await frames(30)
	await _shot("bulwark_third_person_hud")
	td.cam.set_first_person(true)
	td.cam.pitch = -0.05
	await frames(10)
	await _shot("bulwark_first_person_forward")
	td.cam.pitch = -0.9
	await frames(10)
	await _shot("bulwark_first_person_down")
	td.cam.set_first_person(false)
	td.cam.pitch = -0.12
	td.mech.thrust_input = true
	for i in 24:
		await get_tree().physics_frame
	await _shot("bulwark_thrusting")
	# A side view of the jets: the camera's look turned 90 deg (the mech keeps its facing while the drive is overridden).
	td.cam.look_dir = td.mech.forward().rotated(td.mech.up(), -1.3)
	for i in 6:
		await get_tree().physics_frame
	await _shot("bulwark_thrusting_side")
	td.mech.thrust_input = false
	td.queue_free()
	await frames(5)
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(5)
	fe.show_screen("hangar")
	fe._set_chassis("bulwark")
	fe.show_screen("hangar")
	await frames(40)
	await _shot("bulwark_hangar")
	fe.queue_free()
	await frames(2)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()


func _shot(n: String) -> void:
	var img := await sc.grab(n)
	sc.not_blank(img, Rect2(0.1, 0.1, 0.8, 0.8), n)
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, n]))
