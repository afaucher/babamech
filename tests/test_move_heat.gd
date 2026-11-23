extends TestCase
## Movement heat (docs/design/weapons.md "Movement heat"): walking and running heat the mech from its actual ground
## speed (walk_heat at walk_speed, lerping to run_heat at run_speed), only on the ground, live, under its own power.
## Standing, airborne (thrust has its own heat), a knockback slide with no input, shutdown and a puppet add nothing.
## Flat world (+Y up) on one big floor; the mech is stepped by hand (physics processing off) so long runs are fast.

const PASSIVE := 1.4   ## the default loadout's passive heat/s (laser 0.5 + autocannon 0.3 + rockets 0.2 + mortar 0.4)

var _dt := 1.0 / 60.0


func setup() -> void:
	timeout_sec = 120.0
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	var floor_body := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	fs.shape = box
	floor_body.add_child(fs)
	floor_body.position = Vector3(0, -1, 0)
	add_child(floor_body)
	await frames(2)

	var m := await _mech()
	var wh := m.walk_heat
	var rh := m.run_heat
	check(wh > 0.0 and rh > wh, "walk_heat %.2f > 0 and run_heat %.2f > walk_heat" % [wh, rh])

	# Standing: no movement heat; with cooling it only falls.
	m.cooling = 0.0
	m.heat = 50.0
	await _steps(m, 120)
	near(m.heat, 50.0, 0.001, "standing adds no heat")
	m.cooling = 9.0
	await _steps(m, 60)
	check(m.heat < 50.0 - 8.0, "standing with cooling only cools (%.2f)" % m.heat)

	# Walking at full speed: walk_heat /s.
	var walk := await _rate(m, Vector2(0, 1), false)
	near(walk, wh, wh * 0.05, "walking at full speed adds walk_heat /s")
	near(m.ground_speed(), m.walk_speed, 0.3, "walking at walk_speed")
	# Half walk speed: half.
	var half := await _rate(m, Vector2(0, 0.5), false)
	near(half, wh * 0.5, wh * 0.05, "half walk speed adds half walk_heat")
	# Running: run_heat /s, faster than walking.
	var run := await _rate(m, Vector2(0, 1), true)
	near(run, rh, rh * 0.05, "running at full speed adds run_heat /s")
	near(m.ground_speed(), m.run_speed, 0.4, "running at run_speed")
	check(run > walk * 2.0, "running heats faster than walking (%.2f vs %.2f)" % [run, walk])
	# Rate function at the breakpoints.
	m.move_input = Vector2(0, 1)
	m.velocity = Vector3(0, 0, -(m.walk_speed + m.run_speed) * 0.5)
	near(m.move_heat_rate(), (wh + rh) * 0.5, 0.05, "midway between walk and run speed lerps")
	m.velocity = Vector3(0, 0, -m.run_speed * 2.0)
	near(m.move_heat_rate(), rh, 0.001, "above run_speed clamps to run_heat")
	m.move_input = Vector2.ZERO
	m.running = false
	m.velocity = Vector3.ZERO
	m.queue_free()

	# Knockback slide with no input: nothing.
	m = await _mech()
	m.cooling = 0.0
	m.velocity = Vector3(0, 0, -18.0)
	m.step(_dt)
	check(m.ground_speed() > 10.0, "sliding (%.1f m/s)" % m.ground_speed())
	m.heat = 0.0
	await _steps(m, 30)
	near(m.heat, 0.0, 0.001, "a knockback slide with no input adds no heat")

	# Shut down: nothing, even with input.
	m.shutdown = true
	m.heat = 60.0
	m.move_input = Vector2(0, 1)
	m.running = true
	m.velocity = Vector3(0, 0, -15.0)
	await _steps(m, 60)
	near(m.heat, 60.0, 0.001, "shut down adds no movement heat")
	m.queue_free()

	# Airborne: no movement heat while falling with input; thrust heat unchanged.
	m = await _mech(Vector3(0, 300, 0))
	m.cooling = 0.0
	m.auto_burn = false
	m.move_input = Vector2(0, 1)
	m.running = true
	m.step(_dt)
	m.heat = 0.0
	await _steps(m, 60)
	check(not m.grounded(), "still airborne")
	near(m.heat, 0.0, 0.001, "airborne with move input adds no movement heat")
	m.thrust_input = true
	await _steps(m, 60)
	near(m.heat, m.thrust_heat * 60.0 * _dt, 0.01, "thrust heat unchanged in the air (only thrust_heat)")
	m.queue_free()

	# Real cooling: a walking mech with the default loadout's passive heat still cools.
	m = await _mech()
	m.move_input = Vector2(0, 1)
	await _steps(m, 60)
	m.heat = 50.0
	for i in 120:
		m.add_heat(PASSIVE * _dt)
		m.step(_dt)
		if i % 20 == 0:
			await get_tree().physics_frame
	var net_walk := (m.heat - 50.0) / (120.0 * _dt)
	print("net heat walking with passive %.1f, cooling %.1f: %.2f /s" % [PASSIVE, m.cooling, net_walk])
	check(net_walk <= -1.5, "walking with a default loadout still cools at >= 1.5 /s (%.2f)" % net_walk)
	m.queue_free()

	# Running from cold with the default passive reaches shutdown in the expected window, then reboots.
	m = await _mech()
	m.move_input = Vector2(0, 1)
	m.running = true
	var net_run := m.run_heat + PASSIVE - m.cooling
	check(net_run > 0.0, "running with a default loadout heats (%.2f /s)" % net_run)
	var expect := m.heat_cap / maxf(net_run, 0.01)
	var t := 0.0
	var shut := false
	while t < expect * 1.5:
		m.add_heat(PASSIVE * _dt)
		m.step(_dt)
		t += _dt
		if m.shutdown:
			shut = true
			break
		if int(t / _dt) % 200 == 0:
			await get_tree().physics_frame
	print("running to shutdown: %.1f s (expected ~%.1f s at +%.2f /s)" % [t, expect, net_run])
	check(shut, "running overheats into a shutdown")
	check(t > expect * 0.9 and t < expect * 1.25, "shutdown after %.1f s, expected %.1f-%.1f" % [t, expect * 0.9, expect * 1.25])
	m.move_input = Vector2.ZERO
	m.running = false
	var back := 0.0
	while m.shutdown and back < 30.0:
		m.add_heat(PASSIVE * _dt)
		m.step(_dt)
		back += _dt
		if int(back / _dt) % 200 == 0:
			await get_tree().physics_frame
	check(not m.shutdown, "reboots after the run shutdown (%.1f s)" % back)
	check(back < 15.0, "reboot in reasonable time (%.1f s)" % back)
	m.queue_free()

	# A puppet's controller adds no movement heat on its own (it runs no step(); its heat comes from snapshots).
	m = await _mech()
	m.puppet = true
	m.puppet_grounded = true
	m.cooling = 0.0
	m.heat = 40.0
	m.move_input = Vector2(0, 1)
	m.running = true
	m.velocity = Vector3(0, 0, -20.0)
	m.set_physics_process(true)
	await frames(30)
	near(m.heat, 40.0, 0.001, "a puppet's physics adds no movement heat")
	near(m.move_heat_rate(), 0.0, 0.001, "a puppet's move_heat_rate is 0")
	m.queue_free()
	await frames(1)
	finish()


func _mech(at: Vector3 = Vector3(0, 0.05, 0)) -> MechController:
	var m := MechController.new()
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 1.1
	cap.height = 4.0
	shape.shape = cap
	shape.position = Vector3(0, 2.0, 0)
	m.add_child(shape)
	add_child(m)
	m.set_physics_process(false)
	m.global_position = at
	await frames(1)
	for i in 10:
		m.step(_dt)
	return m


func _steps(m: MechController, n: int) -> void:
	for i in n:
		m.step(_dt)
		if i % 20 == 19:
			await get_tree().physics_frame


## Movement heat/s at steady speed for this input (cooling off): accelerate 1.5 s, then measure 2 s.
func _rate(m: MechController, input: Vector2, run: bool) -> float:
	m.cooling = 0.0
	m.move_input = input
	m.running = run
	await _steps(m, int(1.5 / _dt))
	m.heat = 0.0
	var n := int(2.0 / _dt)
	await _steps(m, n)
	return m.heat / (n * _dt)
