extends TestCase
## VISUAL: pivoting direct-fire weapons (weapons.md §4.4; run with .\test_runner.ps1 -Visual -TestName
## test_visual_weapon_pivot). A mech beside the weapon range carries a laser (side_l), an autocannon (side_r), a rocket
## pod (shoulder_l) and a second autocannon (shoulder_r), all firing through a WeaponRack. Shot 1: a dummy close ahead
## and low, the guns pitched down at it, tracers leaving along the barrels: test_logs/shots/weapon_pivot.png. Shot 2:
## the same mech aiming level at a far point, for comparison: test_logs/shots/weapon_pivot_level.png. The lab panel is
## hidden; a side view so the pitch reads.

const VISUAL := true
const AT := Vector3(-30, 0, 6)        ## the mech's feet, left of the range

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_pivot needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("fire", "off")
	for c in lab.find_children("*", "CanvasLayer", true, false):
		(c as CanvasLayer).visible = false
	var model := MechModel.new()
	model.scale = Vector3.ONE * WeaponRangeLab.MECH_SCALE
	model.position = AT
	r.add_child(model)
	model.configure("chicken", "strider", {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets",
		"shoulder_r": "autocannon", "back": ""})
	var dummy := TargetDummy.new()
	dummy.name = "pivot_dummy"
	dummy.target_id = "pivot_dummy"
	dummy.mass_class = "static"
	dummy.position = AT + Vector3(0.5, 0, -10.0)
	r.add_child(dummy)
	r.world.register(dummy)
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.manual_aim = true
	r.add_child(rack)
	rack.bind(r.world, mech, model, null, "pivot_mech", 1)
	rack.aim_point = dummy.global_position + Vector3(0, 0.9, 0)    # close and low
	rack.set_trigger(true)
	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	var eye := AT + Vector3(24.0, 9.0, -3.0)
	var look := AT + Vector3(0.0, 4.6, -4.5)
	cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	for i in 70:
		await frames(1)
		cam.current = true
		mech.heat = 0.0             # keep firing: no shutdown in the shot
		if dummy.total_hp() < dummy.total_max_hp() * 0.3:
			dummy.reset_dummy()
	var img := await sc.grab("weapon_pivot")
	sc.not_blank(img, Rect2(0.2, 0.1, 0.7, 0.8), "pivoted mech")
	var down := 0
	for m: Variant in rack.mounts:
		if m != null and (m as WeaponMount).aim_pitch < -15.0:
			down += 1
	eq(down, 4, "all four guns are pitched down at the close low target")
	check(r.world.live_shots() >= 1, "shots in flight at the shot (%d)" % r.world.live_shots())
	# Level, far: the same mech aims at a point at shoulder height 120 m ahead.
	var hp := model.find_child("HP_shoulder_r", true, false) as Node3D
	rack.aim_point = Vector3(AT.x, hp.global_position.y, AT.z - 120.0)
	for i in 50:
		await frames(1)
		cam.current = true
		mech.heat = 0.0
	var img2 := await sc.grab("weapon_pivot_level")
	sc.not_blank(img2, Rect2(0.2, 0.1, 0.7, 0.8), "level mech")
	for m: Variant in rack.mounts:
		if m != null:
			check(absf((m as WeaponMount).aim_pitch) < 6.0, "level: %s nearly level (%.1f°)" % [(m as WeaponMount).weapon_id, (m as WeaponMount).aim_pitch])
	rack.set_trigger(false)
	rack.queue_free()
	cam.queue_free()
	lab.queue_free()
	await frames(1)
	mech.free()
	finish()
