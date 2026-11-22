extends TestCase
## VISUAL: readability at distance (weapons.md §4.2: slow projectiles you can see stream out, growing as they travel,
## clear trails). Every projectile weapon fires from the weapon_range stand at the 50 m and the 100 m dummy; the shot is
## taken from behind and above the mech while the first projectile is about two thirds of the way there, lab panel and
## readouts hidden. The lab's own clock is stopped and stepped here at 1/60 s, so the frames are the same on every run.
## Look at test_logs/shots/weapon_dist_<weapon>_<50|100>.png (run with .\test_runner.ps1 -Visual).

const VISUAL := true
const WEAPONS := ["autocannon", "gatling", "swivel", "rockets", "missiles", "mortar", "railgun"]
const DT := 1.0 / 60.0

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_distance needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	lab.set_view("three")
	lab.set_process(false)       # the lab re-places its camera every frame: stop that for these shots
	for c in lab.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = false
	r.time_scale = 0.0           # stepped by hand below
	for w: String in WEAPONS:
		for dist: int in [50, 100]:
			for e: CombatEffect in r.world.effects.duplicate():     # only this weapon's shots in the frame
				r.world.remove_effect(e)
			r.set_lab_option("weapon", w)
			r.set_lab_option("aim", "dummy_%d" % dist)
			r.set_lab_option("fire", "hold")
			var target := r.aim_point()
			# Behind and above the mech's right shoulder (higher than the test drive's chase camera so the mech's own
			# body doesn't hide the lane), 70° FOV like ChaseCamera, looking along the lane at the aimed dummy.
			var lane := Vector3(target.x, 0, target.z).normalized()
			var right := lane.cross(Vector3.UP).normalized()
			var eye := -lane * 16.0 + right * 7.0 + Vector3(0, 19.0, 0)
			lab.cam.fov = 70.0
			lab.cam.global_transform = Transform3D(Basis.looking_at(target * 0.55 - eye, Vector3.UP), eye)
			for l in r.find_children("*", "Label3D", true, false):     # HP / heat readouts off: only the shots
				(l as Label3D).visible = false
			var p := await _fly_to(r, float(dist) * 0.65)
			await frames(2)
			var img := await sc.grab("weapon_dist_%s_%d" % [w, dist])
			sc.not_blank(img, Rect2(0.0, 0.0, 1.0, 1.0), "%s at %d m" % [w, dist])
			check(p != null, "%s: a projectile in flight toward the %d m dummy" % [w, dist])
			r.set_lab_option("fire", "off")
	lab.queue_free()
	finish()


## Step the range until a projectile in flight has flown `d` m (or 6 s pass). Returns it.
func _fly_to(r: WeaponRangeLab, d: float) -> Projectile:
	for i in 360:
		r.step(DT)
		for e in r.world.effects:
			var pr := e as Projectile
			if pr != null and pr.end_time < 0.0 and (pr.flight_pos(pr.elapsed) - pr.origin).length() >= d:
				return pr
		if i % 6 == 0:
			await frames(1)    # let the renderer keep up (trails, puffs)
	return null
