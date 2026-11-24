extends TestCase
## Thrusters (S2) in the thruster lab: lift off, climb onto a tower, the emergency burn softens a long drop (and without
## it the landing is hard), holding thrust overheats into a shutdown that cools and reboots, and the flames show.


func setup() -> void:
	timeout_sec = 120.0
	var lab := ThrusterLab.new()
	add_child(lab)
	await frames(3)
	var m := lab.mech
	var ring := lab.ring
	lab.bot_enabled = false
	# Lift off.
	lab.place(-20.0, 0.05)
	await frames(20)
	for i in 60:
		m.thrust_input = true
		await get_tree().physics_frame
	m.thrust_input = false
	check(ring.height(m.global_position) > 4.0, "thrust lifts the mech (%.1f m)" % ring.height(m.global_position))
	check(m.heat > 0.0, "thrust makes heat")
	var fx := m.get_node("Thrusters") as ThrusterFx
	check(fx.level > 0.5, "flames show while thrusting")
	for i in 240:
		await get_tree().physics_frame
	check(m.grounded(), "falls back down")
	# Emergency burn: a 60 m drop is softened.
	m.heat = 0.0
	m.auto_burn = true
	lab.place(-25.0, 60.0)
	var burned := false
	for i in 600:
		await get_tree().physics_frame
		burned = burned or m.emergency
		if m.grounded() and i > 30:
			break
	check(burned, "the emergency burn fired")
	# A late burn down to auto_land_speed: a heavy landing (above safe_land_speed), never a damaging one.
	check(m.last_impact <= m.auto_land_speed + 2.0, "landing softened to about auto_land_speed (%.1f m/s)" % m.last_impact)
	check(m.last_impact < PlayerTarget.FALL_DAMAGE_SPEED, "no fall damage speed (%.1f m/s)" % m.last_impact)
	# Without it, the same drop is a hard landing.
	m.heat = 0.0
	m.auto_burn = false
	lab.hard_landings = 0
	lab.place(-25.0, 60.0)
	for i in 600:
		await get_tree().physics_frame
		if m.grounded() and i > 30:
			break
	check(lab.hard_landings >= 1 and m.last_impact > m.safe_land_speed, "hard landing without the burn (%.1f m/s)" % m.last_impact)
	m.auto_burn = true
	# Climb onto the 9 m tower with the bot.
	lab.bot_enabled = true
	lab.set_lab_option("mode", "climb towers")
	var top := 0.0
	for i in 900:
		await get_tree().physics_frame
		if m.grounded():
			top = maxf(top, ring.height(m.global_position))
		if top > 8.5:
			break
	check(top > 8.5, "climbed onto a tower with the thrusters (stood at %.1f m)" % top)
	# Overheat: hold thrust until shutdown, then it cools and reboots.
	lab.set_lab_option("mode", "overheat")
	var shut := false
	for i in 900:
		await get_tree().physics_frame
		if m.shutdown:
			shut = true
			break
	check(shut, "holding thrust overheats into a shutdown")
	check(not m.thrusting, "no thrust while shut down")
	lab.bot_enabled = false
	m.thrust_input = false
	var back := false
	for i in 1800:
		await get_tree().physics_frame
		if not m.shutdown:
			back = true
			break
	check(back, "cools down and reboots")
	# Every bot mode runs.
	lab.bot_enabled = true
	for md: String in ThrusterLab.MODES:
		lab.set_lab_option("mode", md)
		await frames(30)
	lab.queue_free()
	await frames(1)
	finish()
