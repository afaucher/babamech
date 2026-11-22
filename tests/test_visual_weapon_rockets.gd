extends TestCase
## VISUAL: the rocket pod mid-salvo on the weapon range really draws rockets (white, orange nose, amber exhaust cone),
## chains of grey low-poly smoke puffs and explosions (run with .\test_runner.ps1 -Visual).
## Look at test_logs/shots/weapon_rockets.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_rockets needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "rockets")
	var best: TargetDummy = null
	for d in r.dummies:          # the dummy nearest 50 m, wherever the layout puts it
		if best == null or absf(d.global_position.length() - 50.0) < absf(best.global_position.length() - 50.0):
			best = d
	r.set_lab_option("aim", str(best.name))
	r.set_lab_option("fire", "hold")
	lab.set_view("three")
	# Frame the lane from its right side, the flight running left to right into the 50 m dummy, so the rockets, their
	# puff chains and the bursts all sit right of the lab panel.
	# The lab re-places its camera every frame: stop that for this shot.
	lab.set_process(false)
	var target := best.global_position
	var lane := Vector3(target.x, 0, target.z).normalized()
	var right := lane.cross(Vector3.UP).normalized()
	var dist := Vector3(target.x, 0, target.z).length()
	var eye := lane * dist * 0.45 + right * 19.0 + Vector3(0, 7.0, 0)
	var look := lane * dist * 0.62 + Vector3(0, 2.5, 0) - right * 2.0
	lab.cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	# Mid-salvo: the first rockets have burst on the 50 m dummy, the last ones are still in flight trailing smoke.
	var guard := 0
	while guard < 600:
		await frames(1)
		guard += 1
		var bursts := 0
		var flying := 0
		for e in r.world.effects:
			if e is ImpactFx:
				bursts += 1
			elif e is Rocket and (e as Rocket).end_time < 0.0:
				flying += 1
		if bursts >= 1 and flying >= 2:
			break
	await frames(4)
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	var img := await sc.grab("weapon_rockets")
	sc.not_blank(img, view, "rocket salvo mid-flight")
	var flying_now := 0
	for e in r.world.effects:
		if e is Rocket and (e as Rocket).end_time < 0.0:
			flying_now += 1
	check(flying_now > 0, "rockets in flight at the shot (%d)" % flying_now)
	lab.queue_free()
	finish()
