extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## VISUAL: the test drive in first person (C), run with .\test_runner.ps1 -Visual -TestName test_visual_first_person.
## Walks a little, then grabs the view looking forward and pitched down at the legs / weapons. Look at
## test_logs/shots/first_person_forward.png and first_person_down.png (the pilot head must not show; no hull part should
## fill the view or clip the near plane).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_first_person needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(10)
	td.drive_override = true
	td.cam.set_first_person(true)
	td.cam.pitch = -0.05
	for i in 90:   # walk a few steps so the gait bob and the legs are mid-stride
		td.mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
	td.mech.move_input = Vector2.ZERO
	await frames(5)
	var fwd := await sc.grab("first_person_forward")
	sc.not_blank(fwd, Rect2(0.1, 0.1, 0.8, 0.8), "first person, looking forward")
	td.cam.pitch = td.cam.fp_pitch_min
	await frames(5)
	var down := await sc.grab("first_person_down")
	sc.not_blank(down, Rect2(0.1, 0.1, 0.8, 0.8), "first person, looking down at the legs")
	td.queue_free()
	await frames(1)
	finish()
