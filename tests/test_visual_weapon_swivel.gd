extends TestCase
## VISUAL: the Swivel Boom firing well off the mech's forward axis on the weapon range (run with .\test_runner.ps1
## -Visual). The mech on the stand is turned 70° left, so the 50 m dummy sits ~85° to its right: the boom swings out to
## the side and the twin dark slugs with thin orange tracers leave sideways from alternating barrels. Look at
## test_logs/shots/weapon_swivel.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_swivel needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "swivel")
	r.set_lab_option("mass", "heavy")
	r.set_lab_option("fire", "hold")
	var mid: TargetDummy = null
	for d in r.dummies:     # the dummy nearest 50 m out
		if mid == null or absf(d.global_position.length() - 50.0) < absf(mid.global_position.length() - 50.0):
			mid = d
	r.set_lab_option("aim", str(mid.name))
	r.mech.rotation.y = deg_to_rad(70.0)      # facing left of the lane: the target is far off its forward axis
	# Our own camera (the lab orbits a fixed focus): high behind-right of the mech along the line of fire, the look point
	# shifted left so the mech and the stream sit right of the lab panel.
	var f := (mid.global_position - r.mech.global_position) * Vector3(1, 0, 1)
	f = f.normalized()
	var right := f.cross(Vector3.UP).normalized()
	var eye := r.mech.global_position - f * 14.0 + right * 22.0 + Vector3(0, 20.0, 0)
	var look := r.mech.global_position + f * 15.0 - right * 11.0 + Vector3(0, 2.0, 0)
	var cam := Camera3D.new()
	cam.fov = 55.0
	add_child(cam)
	cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	for i in 100:
		await frames(1)
		cam.current = true
	var img := await sc.grab("weapon_swivel")
	sc.not_blank(img, Rect2(0.3, 0.05, 0.7, 0.9), "swivel stream")
	check(r.world.live_shots() >= 2, "slugs in flight at the shot (%d)" % r.world.live_shots())
	check(absf(r.mount.aim_yaw) > 60.0, "the boom is swung far off the forward axis (%.1f°)" % r.mount.aim_yaw)
	check(r.mount.hold_reason == "", "and it is firing, not holding")
	cam.queue_free()
	lab.queue_free()
	finish()
