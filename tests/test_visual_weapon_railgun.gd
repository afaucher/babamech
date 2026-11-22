extends TestCase
## VISUAL: the Coil Railgun on the weapon range (run with .\test_runner.ps1 -Visual -TestName
## test_visual_weapon_railgun). Two shots, each just after a slug went through the 25 m dummy: the default framing
## (test_logs/shots/weapon_railgun.png: the twisted teal trail hanging along the path, the entry / exit bursts) and a
## low side view along the trail (weapon_railgun_side.png).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_railgun needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("fire", "off")
	r.set_lab_option("weapon", "railgun")
	r.set_lab_option("mass", "heavy")
	r.set_lab_option("aim", "dummy_25")
	lab.set_view("three")
	await frames(30)
	r.set_lab_option("fire", "hold")
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	check(await _just_hit(r), "a slug has just hit at the shot")
	var img := await sc.grab("weapon_railgun")
	sc.not_blank(img, view, "railgun trail and bursts")
	lab.set_view("side")
	lab._dist = 30.0
	await frames(10)
	check(await _just_hit(r), "a slug has just hit at the side shot")
	var img2 := await sc.grab("weapon_railgun_side")
	sc.not_blank(img2, view, "railgun side view")
	lab.queue_free()
	finish()


## Wait (up to 8 s) for a slug that stopped 0.16-0.3 s ago (bursts up, trail hanging).
func _just_hit(r: WeaponRangeLab) -> bool:
	for i in 480:
		await frames(1)
		for e in r.world.effects:
			if e is RailSlug:
				var s := e as RailSlug
				if s.end_time >= 0.0 and s.elapsed - s.end_time >= 0.16 and s.elapsed - s.end_time < 0.3:
					return true
	return false
