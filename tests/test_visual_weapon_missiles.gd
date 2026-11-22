extends TestCase
## VISUAL: guided missiles on the weapon range, launched off to the side of a dummy and visibly curving onto it, with
## the red laser line from the launcher to the dot (run with .\test_runner.ps1 -Visual).
## Look at test_logs/shots/weapon_missiles.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_missiles needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "missiles")
	var best: TargetDummy = null
	for d in r.dummies:          # the dummy nearest 50 m
		if best == null or absf(d.global_position.length() - 50.0) < absf(best.global_position.length() - 50.0):
			best = d
	r.set_lab_option("aim", str(best.name))
	r.set_lab_option("designator", "hold")
	r.set_lab_option("fire", "off")
	lab.set_view("three")
	lab.set_process(false)       # the lab re-places its camera every frame: stop that for this shot
	var target := best.global_position
	var lane := Vector3(target.x, 0, target.z).normalized()
	var right := lane.cross(Vector3.UP).normalized()
	var dist := Vector3(target.x, 0, target.z).length()
	# Launch the salvo by hand, 70° off the lane to the left, so the missiles visibly bend onto the dummy.
	var from := r.muzzle()
	var aim := target + Vector3(0, 1.9, 0)
	var off := (aim - from).normalized().rotated(Vector3.UP, deg_to_rad(70.0))
	for i in 3:
		r.world.fire(Combat.fire_record(WeaponRangeLab.SHOOTER, 1, r.hardpoint, "missiles", from, from + off * 10.0,
			r.world.now, i, 0.0))
		await frames(12)
	# High behind the shooter, looking down the lane (shifted so the lane sits right of the lab panel).
	var eye := -lane * 14.0 + Vector3(0, 34.0, 0) - right * 9.0
	var look := lane * dist * 0.55 - right * 9.0
	lab.cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	# The first missile mid-curve.
	var guard := 0
	var first: Missile = null
	while guard < 600:
		await frames(1)
		guard += 1
		for e in r.world.effects:
			if e is Missile and first == null:
				first = e
		if first != null and first.elapsed > 0.9:
			break
	await frames(2)
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	var img := await sc.grab("weapon_missiles")
	sc.not_blank(img, view, "missiles curving toward the dummy")
	var flying := 0
	var shown := false
	for e in r.world.effects:
		if e is Missile and (e as Missile).end_time < 0.0:
			flying += 1
		if e is MissileLaser and (e as MissileLaser).shown:
			shown = true
	check(flying > 0, "missiles in flight at the shot (%d)" % flying)
	check(shown, "the laser line is shown at the shot")
	lab.queue_free()
	finish()
