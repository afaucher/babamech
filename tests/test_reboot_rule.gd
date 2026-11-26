extends TestCase
## The shutdown / reboot rule (MechController, 2026-11-25 audit): a mech shuts down at heat_cap; its reboot countdown runs
## only while heat is at or under reboot_heat, and heat climbing back over reboot_heat while shut down (a flamer, standing
## in fire: add_heat) RESTARTS it, so control returns after a full reboot_time spent cool enough, never early and never at
## once when the heat drops again. `rebooted` fires exactly once per reboot, on every path (the countdown and the
## reset_heat() verb: redeploy / revive). Both chassis, real mechs on a floor, real physics frames, standing still.

const DT := 1.0 / 60.0


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0, -0.5, 0)
	add_child(body)
	var x := -60.0
	for chassis: String in ["strider", "bulwark"]:
		var m := MechSpawn.make("chicken", chassis, {}, 1)
		m.global_position = Vector3(x, 0, 0)
		x += 120.0
		add_child(m)
		await frames(5)
		await _case(m)
	finish()


func _case(m: MechController) -> void:
	var tag := m.chassis_id
	var counts := {"over": 0, "boot": 0}
	m.overheated.connect(func() -> void: counts["over"] += 1)
	m.rebooted.connect(func() -> void: counts["boot"] += 1)

	# (1) Plain reboot: shut down, cool to reboot_heat, then reboot_time later control returns; one signal each.
	m.add_heat(m.heat_cap)
	check(m.shutdown, "%s: add_heat to the cap shuts it down" % tag)
	eq(counts["over"], 1, "%s: overheated fired once" % tag)
	var cool := await _frames_until_reboot(m, 30.0)
	print("[reboot] %s plain: %.2f s at or under reboot_heat %.0f before control returned (reboot_time %.2f)" % [tag, cool,
		m.reboot_heat, m.reboot_time])
	check(not m.shutdown, "%s: rebooted" % tag)
	near(cool, m.reboot_time, 2.5 * DT, "%s: the reboot took reboot_time at or under reboot_heat" % tag)
	eq(counts["boot"], 1, "%s: rebooted fired once" % tag)

	# (2) Heat climbs again mid-countdown: the countdown restarts (the full reboot_time again, not the remainder).
	m.add_heat(m.heat_cap)
	await _until(m, func() -> bool: return m.heat <= m.reboot_heat)
	for i in int(m.reboot_time * 0.6 / DT):
		await get_tree().physics_frame
	check(m.shutdown, "%s: still shut down 60 %% into the countdown" % tag)
	m.add_heat(m.reboot_heat * 0.5)   # a flamer hit lifts it back over reboot_heat
	check(m.heat > m.reboot_heat, "%s: heat back over reboot_heat (%.1f)" % [tag, m.heat])
	eq(m._reboot_t, 0.0, "%s: add_heat over reboot_heat restarted the countdown at once" % tag)
	cool = await _frames_until_reboot(m, 30.0)
	print("[reboot] %s re-heated mid-countdown: %.2f s at or under reboot_heat after it, before control returned" % [tag, cool])
	near(cool, m.reboot_time, 2.5 * DT, "%s: after re-heating, a full reboot_time again (not the 40 %% left)" % tag)
	eq(counts["boot"], 2, "%s: rebooted fired once for that reboot" % tag)

	# (3) Standing in fire: heat kept over reboot_heat for 4 s, no reboot however long it has been shut down.
	m.add_heat(m.heat_cap)
	var t := 0.0
	while t < 4.0:
		if m.heat <= m.reboot_heat + 2.0:
			m.add_heat(m.cooling * DT * 2.0)
		await get_tree().physics_frame
		t += DT
	check(m.shutdown, "%s: held over reboot_heat for 4 s, still shut down" % tag)
	eq(counts["boot"], 2, "%s: no reboot while the heat is kept up" % tag)
	cool = await _frames_until_reboot(m, 30.0)
	near(cool, m.reboot_time, 2.5 * DT, "%s: once the fire stops, a full reboot_time after cooling" % tag)
	eq(counts["boot"], 3, "%s: one more reboot" % tag)

	# (4) reset_heat() (redeploy / revive): ends a shutdown at once, heat 0, rebooted fires once; live, no signal.
	m.add_heat(m.heat_cap)
	m.reset_heat()
	check(not m.shutdown, "%s: reset_heat ends the shutdown" % tag)
	eq(m.heat, 0.0, "%s: reset_heat clears the heat" % tag)
	eq(counts["boot"], 4, "%s: reset_heat fired rebooted for the shutdown it ended" % tag)
	m.add_heat(10.0)
	m.reset_heat()
	eq(counts["boot"], 4, "%s: reset_heat on a live mech fires no rebooted" % tag)
	for i in 30:
		await get_tree().physics_frame
	eq(counts["boot"], 4, "%s: no stray reboot afterwards" % tag)
	eq(counts["over"], 4, "%s: overheated once per shutdown (4)" % tag)


## Physics frames until the mech reboots (max `limit` s); returns the seconds spent at or under reboot_heat since the
## last frame it was over it (the countdown the rule runs).
func _frames_until_reboot(m: MechController, limit: float) -> float:
	var cool := 0.0
	var t := 0.0
	while m.shutdown and t < limit:
		await get_tree().physics_frame
		t += DT
		cool = cool + DT if m.heat <= m.reboot_heat else 0.0
	return cool


func _until(m: MechController, cond: Callable, limit: float = 30.0) -> void:
	var t := 0.0
	while not cond.call() and t < limit:
		await get_tree().physics_frame
		t += DT
