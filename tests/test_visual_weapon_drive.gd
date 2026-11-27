extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## VISUAL: the test drive firing its default loadout through WeaponRack (run with .\test_runner.ps1 -Visual). The rack's
## input reading is off; the test aims at the nearest live enemy (or 60 m ahead) and holds the trigger, then grabs the
## chase camera's view mid-fire. Look at test_logs/shots/weapon_drive.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_drive needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(10)
	var rack := td.combat.rack
	rack.read_input = false
	rack.manual_aim = true
	for f in 150:
		var aim := td.mech.global_position - td.mech.global_basis.z * 60.0 + Vector3(0, 3, 0)
		var best := INF
		for e in td.combat.enemies:
			if is_instance_valid(e) and not e.destroyed():
				var d := td.mech.global_position.distance_to(e.global_position)
				if d < best and d < 150.0:
					best = d
					aim = e.global_position + Vector3(0, 2.5, 0)
		rack.aim_point = aim
		rack.set_trigger(true)
		await frames(1)
	var img := await sc.grab("weapon_drive")
	sc.not_blank(img, Rect2(0.1, 0.1, 0.8, 0.8), "test drive firing")
	var fired := 0
	for m in rack.mounts:
		if m != null:
			fired += (m as WeaponMount).shot_index
	check(fired > 0, "the rack fired in the test drive (%d shots)" % fired)
	rack.set_trigger(false)
	td.queue_free()
	finish()
