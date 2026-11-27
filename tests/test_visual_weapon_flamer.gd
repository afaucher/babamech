extends TestCase
## VISUAL: the Flamer on the weapon range (run with .\test_runner.ps1 -Visual -TestName test_visual_weapon_flamer). A
## side view of the mech holding the flame on the 25 m dummy until it is over half heat: one long focused jet of chunky
## low-poly fire (one LowPolyFlame.Stream, 45 m reach, 5 deg cone) should reach across and splash on the dummy, with
## burning tongues stuck on it (test_logs/shots/weapon_flamer.png); then a wall goes up ~8 m out and the flame splats
## against it (weapon_flamer_wall.png).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_flamer needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "flamer")
	r.set_lab_option("mass", "mech")
	r.set_lab_option("aim", "dummy_25")
	r.set_lab_option("fire", "hold")
	var d := r.aim_dummy()
	# A side view across the line from the muzzle to the dummy (our own camera: the lab orbits a fixed focus).
	var from := r.muzzle()
	var to := d.global_position + Vector3(0, 1.9, 0)
	var mid := (from + to) * 0.5
	var along := (to - from).normalized()
	var side := along.cross(Vector3.UP).normalized()
	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.global_transform = Transform3D(Basis.looking_at(-side + Vector3(0, -0.1, 0), Vector3.UP), mid + side * 30.0 - along * 6.0 + Vector3(0, 3.0, 0))
	cam.current = true
	var burning := false
	for i in 600:
		await frames(1)
		cam.current = true
		var b := d.get_node_or_null("BurnFx") as BurnFx
		if b != null and b.showing() >= 2 and d.heat.fraction() > 0.6:
			burning = true
			break
	check(burning, "the dummy is burning at the shot (heat %.0f)" % d.heat.value)
	var fx: FlamerFx = null
	for e in r.world.effects:
		if e is FlamerFx:
			fx = e
	check(fx != null and fx.emitting() and fx.stream.active(), "the flame is lit at the shot")
	var img := await sc.grab("weapon_flamer")
	sc.not_blank(img, Rect2(0.2, 0.2, 0.6, 0.6), "a long flame jet on the 25 m dummy")
	# Second shot: a wall ~8 m out across the line of fire; the flame splats against it instead of flying through.
	var flat := Vector3(along.x, 0, along.z).normalized()
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(9, 7, 0.4)
	cs.shape = box
	wall.add_child(cs)
	var k := MeshKit.new()
	k.box(box.size, Color(0.52, 0.5, 0.46))
	var wm := MeshInstance3D.new()
	wm.mesh = k.commit(LowPolyMaterials.materials())
	wall.add_child(wm)
	add_child(wall)
	wall.global_transform = Transform3D(Basis.looking_at(flat, Vector3.UP), Vector3(from.x, 3.5, from.z) + flat * 8.2)
	for i in 90:
		await frames(1)
		cam.current = true
	check(fx != null and is_instance_valid(fx) and fx.stream.max_length < 9.0,
		"the flame is capped at the wall (%.2f m)" % (fx.stream.max_length if fx != null and is_instance_valid(fx) else -1.0))
	var img2 := await sc.grab("weapon_flamer_wall")
	sc.not_blank(img2, Rect2(0.2, 0.2, 0.6, 0.6), "flame splashing on a wall")
	wall.queue_free()
	cam.queue_free()
	lab.queue_free()
	finish()
