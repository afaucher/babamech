extends TestCase
## VISUAL: the weapon range mid-fire really draws shells, trails and impacts (run with .\test_runner.ps1 -Visual).
## Two shots: the default framing while the autocannon hammers the 25 m dummy, and a low view down the lane at the
## 50 m dummy. Look at test_logs/shots/weapon_range_*.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_range needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("aim", "dummy_25")
	r.set_lab_option("designator", "hold")
	r.set_lab_param("rate", 6.0)
	lab.set_view("three")
	await frames(100)
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	var img := await sc.grab("weapon_range_fire")
	sc.not_blank(img, view, "weapon range mid-fire")
	check(r.world.live_shots() > 0, "shells in flight at the shot")
	r.set_lab_option("aim", "dummy_50")
	r.set_lab_option("designator", "off")
	lab.set_view("side")
	lab._dist = 30.0
	await frames(75)
	var img2 := await sc.grab("weapon_range_side")
	sc.not_blank(img2, view, "weapon range side view")
	lab.queue_free()
	finish()
