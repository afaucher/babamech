extends TestCase
## VISUAL: the Side Laser mid-beam on the weapon range (run with .\test_runner.ps1 -Visual -TestName
## test_visual_weapon_laser). Two shots: the default framing with the laser pulsing at the 25 m dummy
## (test_logs/shots/weapon_laser.png) and a low side view of the beam at the 25 m dummy (weapon_laser_side.png).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_laser needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("fire", "off")
	r.set_lab_option("weapon", "laser")
	r.set_lab_option("aim", "dummy_25")
	lab.set_view("three")
	await frames(30)
	r.set_lab_option("fire", "hold")
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	check(await _mid_beam(r), "a beam is live at the shot")
	var img := await sc.grab("weapon_laser")
	sc.not_blank(img, view, "laser mid-beam")
	r.set_lab_option("mass", "heavy")     # stays near home (a light one is shoved along the beam)
	r.set_lab_option("aim", "dummy_25")   # the dummy the side view frames
	lab.set_view("side")
	lab._dist = 30.0
	await frames(30)
	check(await _mid_beam(r), "a beam is live at the side shot")
	var img2 := await sc.grab("weapon_laser_side")
	sc.not_blank(img2, view, "laser side view")
	lab.queue_free()
	finish()


## Wait (up to 3 s) until a beam is about a third through its life.
func _mid_beam(r: WeaponRangeLab) -> bool:
	for i in 180:
		await frames(1)
		for e in r.world.effects:
			if e is Beam and (e as Beam).age >= 0.08:
				return true
	return false
