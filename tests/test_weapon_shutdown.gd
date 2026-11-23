extends TestCase
## Heat shutdown and the weapons (weapons.md §4.7): while the MechController is shut down every tracking barrel (pivoting
## weapons, the swivel) stops following the aim point and eases to WeaponMount.park_pose (yaw 0, pitch -12, clamped to
## its limits) at PARK_SLEW °/s, then holds exactly; nothing fires, no active heat, no charge glow (a charge itself is
## held through the shutdown: test_weapon_railgun), no guided track; slots() says hold SHUTDOWN, in_range / on_target /
## designating false; selection is kept. On reboot the barrels slew back at their normal rate (no snap) and firing
## resumes; no slot fires twice on either edge. The
## mortar (fixed) doesn't move. The weapon_range lab parks the same way (its mount runs the same update).

const DT := 1.0 / 60.0
const LOADOUT := {"side_l": "laser", "side_r": "swivel", "shoulder_l": "missiles", "shoulder_r": "autocannon", "back": "mortar"}
const TRACKING := [0, 1, 2, 3]     ## slot indices whose barrels track (laser, swivel, missiles, autocannon)


func setup() -> void:
	await _shutdown_rack()
	await _lab_parks()
	finish()


func _shutdown_rack() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", LOADOUT)
	var mech := MechController.new()     # not in the tree: no cooling, no auto reboot (the test reboots it)
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "shut", 1)
	await frames(2)
	var shots := {}
	rack.fired.connect(func(n: int) -> void: shots[n] = int(shots.get(n, 0)) + 1)
	# Track and fire at an off-centre aim point.
	rack.aim_point = Vector3(25, 6, -60)
	rack.set_trigger(true)
	for i in 90:
		rack.step(DT)
		world.advance(DT)
	for n in [1, 3, 4]:
		check(int(shots.get(n, 0)) > 0, "slot %d fired before the shutdown (%d)" % [n, int(shots.get(n, 0))])
	for i: int in TRACKING:
		check(rack.mounts[i].aim_yaw > 5.0, "slot %d tracks the off-centre aim (yaw %.1f)" % [i + 1, rack.mounts[i].aim_yaw])
	check(rack.designator_on(), "the guided track is on before the shutdown")
	var mortar_yp := Vector2(rack.mounts[4].aim_yaw, rack.mounts[4].aim_pitch)
	var sel := rack.enabled.duplicate()
	# Shutdown with the trigger still held.
	mech.add_heat(500.0)
	check(mech.shutdown, "the mech is shut down")
	var heat0 := mech.heat
	var passive := 0.0
	for w: String in LOADOUT.values():
		passive += float(MechCatalog.weapon(w).get("passive_heat", 0.0))
	var prev: Array[Vector2] = []
	var park: Array[Vector2] = []
	for i: int in TRACKING:
		prev.append(Vector2(rack.mounts[i].aim_yaw, rack.mounts[i].aim_pitch))
		park.append(rack.mounts[i].park_pose())
		eq(park[park.size() - 1], Vector2(0.0, -12.0), "slot %d parks at yaw 0 / pitch -12 (within its limits)" % [i + 1])
	var need := 0.0
	for k in TRACKING.size():
		need = maxf(need, prev[k].distance_to(park[k]) / WeaponMount.PARK_SLEW)
	shots.clear()
	var toward_aim := false
	var too_fast := false
	var glow := 0.0
	var frames_n := int(ceil(need / DT)) + 30
	for f in frames_n:
		rack.aim_point = Vector3(-40.0 + 2.0 * f, 2.0 + 0.3 * f, -50)     # the aim keeps moving: the barrels ignore it
		rack.step(DT)
		world.advance(DT)
		var g := rack._glows[0] as ChargeGlow      # the laser's glow node (its charge may be held: hidden, not lost)
		glow = maxf(glow, g.frac if g.visible else 0.0)
		for k in TRACKING.size():
			var m: WeaponMount = rack.mounts[TRACKING[k]]
			var cur := Vector2(m.aim_yaw, m.aim_pitch)
			if cur.distance_to(park[k]) > prev[k].distance_to(park[k]) + 1e-4:
				toward_aim = true
			if cur.distance_to(prev[k]) > WeaponMount.PARK_SLEW * DT + 1e-3:
				too_fast = true
			prev[k] = cur
	eq(shots.size(), 0, "nothing fires while shut down, trigger held (%s)" % str(shots))
	check(not toward_aim, "no barrel moves away from its parked pose (the moving aim point is ignored)")
	check(not too_fast, "barrels park at the limp rate (<= %.0f deg/s)" % WeaponMount.PARK_SLEW)
	check(mech.heat - heat0 <= passive * frames_n * DT + 0.05, "no active weapon heat while shut down (+%.2f, passive at most %.2f)"
		% [mech.heat - heat0, passive * frames_n * DT])
	near(glow, 0.0, 1e-6, "no laser charge glow while shut down")
	for k in TRACKING.size():
		var m: WeaponMount = rack.mounts[TRACKING[k]]
		check(Vector2(m.aim_yaw, m.aim_pitch).is_equal_approx(park[k]), "slot %d reached its park within %.2f s (%.2f, %.2f)" %
			[TRACKING[k] + 1, need, m.aim_yaw, m.aim_pitch])
	eq(Vector2(rack.mounts[4].aim_yaw, rack.mounts[4].aim_pitch), mortar_yp, "the fixed mortar doesn't move")
	# Holds exactly.
	var held := []
	for k in TRACKING.size():
		held.append(Vector2(rack.mounts[TRACKING[k]].aim_yaw, rack.mounts[TRACKING[k]].aim_pitch))
	for f in 30:
		rack.aim_point = Vector3(30.0 - 2.0 * f, 8.0, -40)
		rack.step(DT)
	var still := true
	for k in TRACKING.size():
		still = still and Vector2(rack.mounts[TRACKING[k]].aim_yaw, rack.mounts[TRACKING[k]].aim_pitch) == held[k]
	check(still, "parked barrels hold exactly")
	check(not rack.designator_on() and not bool(world.designators["shut"]["on"]), "no guided track while shut down")
	for s: Dictionary in rack.slots():
		if bool(s["equipment"]) or str(s["weapon"]) == "":
			continue
		eq(str(s["hold"]), "SHUTDOWN", "slot %d: hold SHUTDOWN" % int(s["slot"]))
		check(not bool(s["in_range"]) and not bool(s["on_target"]) and not bool(s["designating"]),
			"slot %d: no in_range / on_target / designating while shut down" % int(s["slot"]))
	eq(rack.enabled, sel, "selection kept through the shutdown")
	# Reboot (test only), trigger still held: slews back at the normal rate, fires again, nothing twice on the edge.
	rack.aim_point = Vector3(25, 6, -60)
	mech.heat = 0.0
	mech.shutdown = false
	var before: Array[Vector2] = []
	for i: int in TRACKING:
		before.append(Vector2(rack.mounts[i].aim_yaw, rack.mounts[i].aim_pitch))
	shots.clear()
	rack.step(DT)
	world.advance(DT)
	for n: int in shots:
		check(int(shots[n]) <= 1, "slot %d fires at most once on the reboot frame (%d)" % [n, int(shots[n])])
	check(rack.designator_on() and bool(world.designators["shut"]["on"]), "the guided track is back on the reboot step")
	for k in TRACKING.size():
		var i: int = TRACKING[k]
		var m: WeaponMount = rack.mounts[i]
		var moved := Vector2(m.aim_yaw, m.aim_pitch).distance_to(before[k])
		var slew := float(m.stats.get("slew", Combat.PIVOT_SLEW))
		check(moved > 1e-3 and moved <= slew * DT + 1e-3, "slot %d slews back from the park at its normal rate (%.2f deg in one step, max %.2f)" %
			[i + 1, moved, slew * DT])
		check(m.aim_yaw < 5.0, "slot %d doesn't snap to the aim on reboot (yaw %.1f)" % [i + 1, m.aim_yaw])
	for s: Dictionary in rack.slots():
		if not bool(s["equipment"]) and str(s["weapon"]) != "":
			check(str(s["hold"]) != "SHUTDOWN", "slot %d: no SHUTDOWN hold after the reboot (%s)" % [int(s["slot"]), str(s["hold"])])
	shots.clear()
	for f in 240:              # past the missiles' 5 s reload from their pre-shutdown salvo
		mech.heat = 0.0        # test only: this mech doesn't cool (not in the tree); keep it out of a second shutdown
		rack.step(DT)
		world.advance(DT)
	for n in [1, 3, 4]:
		var mm: WeaponMount = rack.mounts[n - 1]
		check(int(shots.get(n, 0)) > 0, "slot %d fires again after the reboot (%d; ammo %d cd %.2f salvo %d hold '%s' heat %.0f)" % [n,
			int(shots.get(n, 0)), mm.ammo, mm.cooldown, mm.salvo_left, mm.hold_reason, mech.heat])
	for i: int in TRACKING:
		check(rack.mounts[i].aim_yaw > 5.0, "slot %d tracks again (yaw %.1f)" % [i + 1, rack.mounts[i].aim_yaw])
	check(rack.designator_on(), "the guided track is back")
	rack.set_trigger(false)
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


## A bare WeaponMount driven as the lab drives it (a Heat): shut down, it parks; rebooted, it tracks.
func _lab_parks() -> void:
	var m := WeaponMount.new()
	m.setup("autocannon", "side_r", "lab", 1, MechCatalog.weapon("autocannon"))
	var heat := Heat.new(100.0, 0.0)
	var aim := Vector3(30, 0, -60)
	for i in 60:
		m.update(DT, false, heat, i * DT, Vector3.ZERO, aim)
	check(m.aim_yaw > 20.0, "the lab mount tracks (yaw %.1f)" % m.aim_yaw)
	heat.add(200.0)
	check(not heat.can_act(), "the lab heat is shut down")
	for i in 120:
		m.update(DT, true, heat, 1.0 + i * DT, Vector3.ZERO, aim)
	check(Vector2(m.aim_yaw, m.aim_pitch).is_equal_approx(Vector2(0, -12)), "the lab mount parks (%.2f, %.2f)" % [m.aim_yaw, m.aim_pitch])
	eq(m.hold_reason, Combat.SHUTDOWN, "the lab readout says SHUTDOWN")
