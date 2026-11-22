extends TestCase
## VISUAL: the Rotary Gatling mid-stream on the weapon range (run with .\test_runner.ps1 -Visual). A view from behind
## and above the mech down the lane while a held stream fans out toward the dummy nearest 100 m: the dotted line of
## yellow-white darts and their tracers should spread into a cone. Look at test_logs/shots/weapon_gatling.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_gatling needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "gatling")
	r.set_lab_option("mass", "heavy")
	r.set_lab_option("fire", "hold")
	var far: TargetDummy = null
	for d in r.dummies:     # the dummy nearest 100 m out (positions may change: found by distance)
		if far == null or absf(d.global_position.length() - 100.0) < absf(far.global_position.length() - 100.0):
			far = d
	r.set_lab_option("aim", str(far.name))
	# Low behind the mech, zoomed down the lane so the fan spreads across the frame (the lab orbits its subject's lab_focus()).
	lab._yaw = PI - 0.3
	lab._pitch = 0.2
	lab._dist = 30.0
	lab.cam.fov = 30.0   # zoomed down the lane: the 4° cone takes real screen angle
	await frames(110)
	var img := await sc.grab("weapon_gatling")
	sc.not_blank(img, Rect2(0.3, 0.05, 0.7, 0.9), "gatling stream")
	check(r.world.live_shots() >= 8, "a stream of darts in flight at the shot (%d)" % r.world.live_shots())
	check(r.mount.bloom > 2.0, "the cone has bloomed (%.2f° extra)" % r.mount.bloom)
	lab.queue_free()
	finish()
