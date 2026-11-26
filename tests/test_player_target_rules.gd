extends TestCase
## PlayerTarget / CombatTarget damage rules (docs/design/weapons.md §5, code audit 2026-11):
## (a) a DESTROYED weapon hardpoint keeps its hit sphere (the wrecked weapon stays on the model: no mesh is hidden), but
##     a shot that strikes it is not swallowed: the damage goes to the torso it is mounted on. The same hit spheres on
##     every machine (the owner and a puppet agree on what the shot struck); a rebuilt hardpoint takes its own damage again.
## (b) `damaged(amount, ...)` carries the HP actually removed (clamped by the component's remaining HP); nothing is
##     emitted when nothing was dealt. Base CombatTarget and PlayerTarget alike.
## (c) revive and the instant-respawn hook clear the bound mech's heat shutdown through MechController.reset_heat, so
##     `rebooted` fires (redeploy and the depot core share the same vent_heat).

const LOADOUT := {"side_l": "laser", "side_r": "swivel", "shoulder_l": "missiles", "shoulder_r": "autocannon"}


func setup() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var mech := MechSpawn.make("chicken", "strider", LOADOUT, 1)
	add_child(mech)
	var pt := PlayerTarget.new()
	add_child(pt)
	pt.bind(world, mech, MechSpawn.rig_of(mech).model, "player1", 1)
	world.register(pt)
	await frames(2)
	pt.tick(0.0)
	var dmg := []
	pt.damaged.connect(func(a: float, c: String, s: String) -> void: dmg.append([a, c, s]))

	# (a) A side shot at the left side gun.
	var c_l: Vector3 = PlayerTarget.HARDPOINT_SPHERES["side_l"]["center"]
	var a := pt.to_global(c_l + Vector3(-30.0, 0.0, 0.0))
	var b := pt.to_global(c_l)
	var h := world.first_hit(a, b, 0.0, "e1")
	eq(str(h.get("component", "")), "side_l", "a side shot strikes the side_l hardpoint sphere")
	pt.apply_damage(200.0, "side_l", "e1")
	check(pt.is_slot_destroyed("side_l"), "side_l destroyed")
	var torso0 := float(pt.hp["torso"])
	dmg.clear()
	h = world.first_hit(a, b, 0.0, "e1")
	var comp := str(h.get("component", ""))
	pt.apply_damage(50.0, comp, "e1")
	print("[pt] after side_l destroyed: shot struck %s, torso %.0f -> %.0f, damaged %s" % [comp, torso0,
		float(pt.hp["torso"]), str(dmg)])
	near(float(pt.hp["torso"]), torso0 - 50.0, 1e-4, "a shot into the wrecked side_l damages the torso it hangs on")
	check(dmg.size() == 1 and str(dmg[0][1]) == "torso" and is_equal_approx(float(dmg[0][0]), 50.0),
		"damaged reports 50 to the torso (%s)" % str(dmg))
	# A puppet's target of the same mech has the same hit spheres (it never runs apply_damage: hp comes from snapshots).
	var pmech := MechSpawn.make("chicken", "strider", LOADOUT, 2)
	pmech.puppet = true
	add_child(pmech)
	var ppt := PlayerTarget.new()
	add_child(ppt)
	ppt.bind(world, pmech, MechSpawn.rig_of(pmech).model, "player2", 2)
	var pup := MechPuppet.new()
	pup.target = ppt
	var st := NetMechState.new()
	st.comp = CrewSync.component_fractions(pt)
	pup._apply_damage(st)
	pup.free()
	check(ppt.is_slot_destroyed("side_l"), "the puppet mirrors the destroyed side_l")
	eq(ppt.hit_shapes.size(), pt.hit_shapes.size(), "owner and puppet keep the same hit spheres")
	# Rebuilt (supply depot): side_l takes its own damage again.
	pt.rebuild_destroyed(0.5, "depot")
	torso0 = float(pt.hp["torso"])
	pt.apply_damage(10.0, "side_l", "e1")
	near(float(pt.hp["side_l"]), 30.0, 1e-4, "a rebuilt side_l takes the hit itself")
	near(float(pt.hp["torso"]), torso0, 1e-4, "and the torso does not")

	# (b) Dealt, not requested.
	pt.repair_all()
	dmg.clear()
	pt.apply_damage(100.0, "side_r", "e1")          # 80 HP: 80 dealt
	pt.apply_damage(25.0, "head", "e1")
	pt.apply_damage(90.0, "head", "e1")             # 75 left: 75 dealt (and the mech goes down)
	print("[pt] damaged events: %s" % str(dmg))
	check(dmg.size() == 3, "three events (%s)" % str(dmg))
	if dmg.size() == 3:
		near(float(dmg[0][0]), 80.0, 1e-4, "overkill on a hardpoint reports the 80 HP it had")
		near(float(dmg[1][0]), 25.0, 1e-4, "a normal hit reports its amount")
		near(float(dmg[2][0]), 75.0, 1e-4, "the killing blow reports what was left")
	var ct := CombatTarget.new()
	ct.set_max_hp({"body": 50.0})
	var cd := []
	ct.damaged.connect(func(x: float, c: String, _s: String) -> void: cd.append([x, c]))
	ct.apply_damage(80.0, "body", "e1")
	ct.apply_damage(10.0, "body", "e1")
	print("[ct] damaged events: %s" % str(cd))
	check(cd.size() == 1 and is_equal_approx(float(cd[0][0]), 50.0), "CombatTarget reports 50 dealt, then nothing (%s)" % str(cd))
	ct.free()

	# (c) Revive while shut down: heat 0, shutdown cleared (and `rebooted` once Mech has reset_heat).
	var reboots := [0]
	mech.rebooted.connect(func() -> void: reboots[0] += 1)
	check(pt.disabled, "downed by the head shot")
	mech.add_heat(mech.heat_cap * 2.0)
	check(mech.shutdown, "the mech overheated")
	pt.revive("p2")
	check(not mech.shutdown and mech.heat == 0.0, "revive clears heat and shutdown")
	eq(reboots[0], 1, "revive ends the shutdown through reset_heat: rebooted fires")
	# The instant-respawn test hook clears a shutdown the same way.
	pt.auto_respawn_delay = 0.1
	pt.invuln_left = 0.0
	pt.apply_damage(500.0, "torso", "e1")
	check(pt.disabled, "downed again")
	mech.add_heat(mech.heat_cap * 2.0)
	for i in 10:
		pt.tick(0.05)
	check(not pt.disabled and not mech.shutdown and mech.heat == 0.0, "the instant respawn clears heat and shutdown")
	eq(reboots[0], 2, "and fires rebooted")
	finish()
