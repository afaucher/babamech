extends TestCase
## The weapon_range lab end to end: the autocannon fires from its hardpoint, shells fly, a dummy loses HP and moves,
## the designator shows, sliders override the catalog for the session, and an unbuilt weapon mounts without firing.
## "single" fire mode fires one shot per tap for spin-up (gatling) and charge (laser) weapons too; the laser shows its
## charge glow and its beam follows the live muzzle; projectile weapons get a muzzle flash.


func setup() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		finish()
		return
	add_child(lab)
	await frames(2)
	lab.set_lab_option("mass", "light")
	lab.set_lab_option("aim", "dummy_25")
	lab.set_lab_option("fire", "hold")
	lab.set_lab_option("designator", "hold")
	var d := lab.aim_dummy()
	var home := d.global_position
	var shells := 0
	for i in 90:
		await frames(1)
		shells = maxi(shells, lab.world.live_shots())
	check(shells > 0, "shells are in flight")
	check(lab.mount.shot_index >= 3, "the autocannon fired (%d shots)" % lab.mount.shot_index)
	check(d.total_hp() < d.total_max_hp(), "the 25 m dummy lost HP (%.1f)" % d.total_hp())
	check(d.global_position.distance_to(home) > 0.05, "the dummy got shoved (%.2f m)" % d.global_position.distance_to(home))
	check(lab._beam.visible, "the designator beam shows")
	check(bool(lab.world.designators[WeaponRangeLab.SHOOTER]["on"]), "the designator state is on")
	var muzzle := lab.muzzle()
	check(muzzle.y > 1.0 and muzzle.z < 0.0, "shots leave from the hardpoint, ahead of it (%s)" % muzzle)
	# Lab overrides: a rate slider changes the mount's cadence, only for this session.
	lab.set_lab_param("rate", 10.0)
	near(float(lab.mount.stats["rate"]), 10.0, 0.0001, "the rate slider reaches the mount")
	near(float(MechCatalog.weapon("autocannon")["rate"]), 2.5, 0.0001, "the catalog is untouched")
	await frames(60)
	check(lab.heat.value > 5.0, "at 10 shots/s the shooter heats up past its cooling (%.1f)" % lab.heat.value)
	# Time scale 0 freezes the range.
	lab.time_scale = 0.0
	var n := lab.mount.shot_index
	var now := lab.world.now
	await frames(10)
	eq(lab.mount.shot_index, n, "paused: no shots")
	near(lab.world.now, now, 0.0, "paused: the combat clock stops")
	lab.time_scale = 1.0
	lab.set_lab_option("weapon", "laser")
	eq(lab.hardpoint, "side_r", "the side hardpoint takes the laser")
	_single_and_looks(lab)
	# An unbuilt weapon mounts and holds fire (made unbuilt explicitly with WeaponRegistry.set_disabled, since soon every
	# catalog weapon is built).
	WeaponRegistry.set_disabled(["swivel"])
	lab.set_lab_option("weapon", "swivel")
	await frames(30)
	check(not lab.mount.built(), "a disabled weapon mounts unbuilt")
	eq(lab.mount.shot_index, 0, "an unbuilt weapon: no shots")
	WeaponRegistry.set_disabled([])
	lab.set_lab_option("weapon", "railgun")
	check(lab.hardpoint.begins_with("shoulder"), "picking the railgun moves to a shoulder hardpoint (%s)" % lab.hardpoint)
	lab.queue_free()
	finish()


## Driven by hand (time_scale 0 keeps _physics_process out of it).
func _single_and_looks(lab: WeaponRangeLab) -> void:
	lab.time_scale = 0.0
	var dt := 1.0 / 60.0
	for w: String in ["laser", "gatling", "rockets"]:
		lab.set_lab_option("weapon", w)
		lab.set_lab_option("fire", "single")
		var glow := false
		var follows := false
		var flash := false
		for i in int(3.2 / dt):
			lab.step(dt)
			glow = glow or lab._glow.visible
			for e in lab.world.effects.duplicate():
				if e is MuzzleFlash:
					flash = true
				if e is Beam and i % 7 == 0 and not follows:
					lab.mech.position.x += 0.5      # the stand moves under a live beam: its start follows the muzzle
					lab.step(dt)
					follows = ((e as Beam).a as Vector3).distance_to(lab.muzzle()) < 0.01
					lab.mech.position.x -= 0.5
		var n := lab.mount.shot_index
		match w:
			"laser":
				check(n >= 3 and n <= 4, "single: the laser pulses once per tap (%d in 3.2 s)" % n)
				check(glow, "the laser's charge glow shows while it charges")
				check(follows, "the laser beam follows the live muzzle")
			"gatling":
				check(n >= 3 and n <= 5, "single: the gatling spins up and fires one round per tap (%d in 3.2 s)" % n)
				check(flash, "the gatling has a muzzle flash")
				check(not glow, "no charge glow on a gun")
			"rockets":
				eq(n, 6, "single: one tap, one six-rocket salvo (then the reload)")
	lab.set_lab_option("fire", "hold")
	lab.time_scale = 1.0
