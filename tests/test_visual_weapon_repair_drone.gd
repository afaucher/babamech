extends TestCase
## VISUAL: back-mount equipment on the weapon range stand (run with .\test_runner.ps1 -Visual -TestName
## test_visual_weapon_repair_drone).
## 1. The repair drone (the Mech session's flying mesh in the lab mech's accent) over the stand, repairing the damaged lab
##    mech and the repair dummy beside it: its green beams and the faint 15 m ground ring; the back mount shows the empty
##    cradle while it is out. Shots: test_logs/shots/weapon_repair_drone.png (wide) and weapon_repair_drone_close.png
##    (from behind: the drone above the empty cradle).
## 2. The radiator fins glowing near overheat, seen from behind the mech. Shot: test_logs/shots/weapon_radiator_hot.png.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_repair_drone needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("fire", "off")
	r.set_lab_option("weapon", "repair_drone")
	eq(r.hardpoint, "back", "the drone moves to the back hardpoint")
	r.set_lab_option("repair", "damaged")
	lab.set_view("three")
	lab._dist = 38.0
	await frames(10)
	r.set_lab_option("fire", "hold")
	await frames(150)
	check(r.drone != null and is_instance_valid(r.drone) and r.drone.active(), "a drone is out")
	if r.drone != null and is_instance_valid(r.drone):
		check(r.drone.flying_mesh, "drawn with the flying drone mesh")
		check(r.drone.beamed().size() >= 2, "beams to the lab mech and the repair dummy (%d)" % r.drone.beamed().size())
		check(r.drone.healed_total > 0.0, "it repairs (%.1f HP)" % r.drone.healed_total)
	eq(r.world.equipment_look.shown(WeaponRangeLab.SHOOTER), "cradle", "the back mount shows the empty cradle")
	var img := await sc.grab("weapon_repair_drone")
	sc.not_blank(img, Rect2(0.3, 0.05, 0.7, 0.9), "repair drone")
	# 1b. Close, from behind: the drone above and the empty cradle on the back mount.
	lab._yaw = PI + 0.35
	lab._pitch = 0.15
	lab._dist = 24.0
	lab._place_camera()
	await frames(4)
	var img_c := await sc.grab("weapon_repair_drone_close")
	sc.not_blank(img_c, Rect2(0.3, 0.05, 0.7, 0.9), "repair drone close")
	# 2. Radiator near overheat, from behind.
	r.set_lab_option("fire", "off")
	r.set_lab_option("weapon", "radiator")
	eq(r.hardpoint, "back", "the radiator is on the back hardpoint")
	r.heat.value = 0.95 * r.heat.cap
	lab._yaw = PI - 0.7
	lab._pitch = 0.3
	lab._dist = 9.0
	lab._place_camera()
	await frames(10)
	r.heat.value = 0.95 * r.heat.cap
	await frames(3)
	var mat := r.world.equipment_look.glow_material(WeaponRangeLab.SHOOTER)
	check(mat != null and mat.emission_energy_multiplier > 1.5, "the fins glow hot (energy %.2f)" % (
		mat.emission_energy_multiplier if mat != null else -1.0))
	var img2 := await sc.grab("weapon_radiator_hot")
	sc.not_blank(img2, Rect2(0.3, 0.1, 0.5, 0.8), "radiator hot")
	lab.queue_free()
	finish()
