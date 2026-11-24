extends TestCase
## Back-mount equipment (docs/design/back-equipment.md): the catalog carries repair_drone / radiator / ammo_bin on the
## back slot only (not as hangar weapons); the radiator sheds +3 heat/s; the ammo bin adds +50 % to limited-ammo weapons,
## rounded up to a whole salvo; the repair drone slot is a selectable slot (deselected by default, key 5 toggles, double
## tap solos, soloing another deselects it), a fresh trigger press with it selected launches exactly one drone (15 heat)
## and deselects it; 2 charges, one out at a time; it circles its launcher 5 m out (one turn per 6 s, the same on two
## worlds from one record), lives 60 s, then flies home to the dock in 1.5 s; it repairs 1 %/s of max HP only on targets
## this machine owns within 15 m of the LAUNCHER (horizontal), most damaged component first, never a destroyed component
## or a downed mech; beams / ring only while it repairs someone; it dies at once with its launcher. slots() reports
## equipment / passive / active_left / hint. CombatTarget.heal is the verb.
## Looks (EquipmentLook, RepairDrone): the flying drone uses the Mech session's mesh (placeholder when the part is
## missing) and leaves from the dock on the back mount; the back mount shows the empty cradle while a drone is alive
## (also on its way home), docked again after (also after the last charge, on the owner and on a remote machine), and the
## swap survives a MechModel rebuild; the radiator's "heat" surface gets an emissive material that brightens with heat.

const DT := 1.0 / 60.0


func setup() -> void:
	_catalog()
	_heal_verb()
	await _radiator()
	await _ammo_bin()
	await _drone()
	await _activate_direct()
	await _orbit_shared()
	await _passive_key()
	await _drone_looks()
	await _remote_cradle()
	await _radiator_glow()
	finish()


func _catalog() -> void:
	for id: String in ["repair_drone", "radiator", "ammo_bin"]:
		check(MechCatalog.is_equipment(id), "%s is equipment" % id)
		eq(MechCatalog.weapon(id)["mounts"], ["back"], "%s mounts on the back only" % id)
		check(not id in MechCatalog.WEAPON_ORDER, "%s is not a hangar weapon (WEAPON_ORDER)" % id)
		check(not id in MechCatalog.weapons_for("back"), "%s is not in weapons_for(back)" % id)
	eq(MechCatalog.equipment_for("back"), ["repair_drone", "radiator", "ammo_bin"] as Array[String], "equipment_for(back)")
	eq(MechCatalog.equipment_for("side").size(), 0, "no equipment on a side mount")
	check(not MechCatalog.is_equipment("mortar") and not MechCatalog.is_equipment(""), "weapons are not equipment")
	near(float(MechCatalog.weapon("repair_drone")["weight"]), 6.0, 1e-6, "drone 6 t")
	near(float(MechCatalog.weapon("radiator")["weight"]), 5.0, 1e-6, "radiator 5 t")
	near(float(MechCatalog.weapon("ammo_bin")["weight"]), 6.0, 1e-6, "ammo bin 6 t")
	var l := MechCatalog.sanitize_loadout("strider", {"side_l": "radiator", "back": "repair_drone"})
	eq(str(l["back"]), "repair_drone", "sanitize keeps equipment on the back")
	eq(str(l["side_l"]), "", "sanitize empties equipment on a side hardpoint")
	var st := MechCatalog.loadout_stats("strider", {"side_l": "laser", "back": "ammo_bin"})
	near(float(st["weight"]), 4.0 + 6.0, 1e-6, "loadout_stats counts the equipment weight")
	var pl := WeaponRegistry.playable_loadout("strider", {"side_l": "laser", "back": "radiator"})
	eq(str(pl["loadout"]["back"]), "radiator", "playable_loadout keeps equipment (no 'offline' swap)")
	eq((pl["notes"] as Array).size(), 0, "and reports no swap")
	check(CombatNet.decode(["back", "repair_drone", Vector3.ZERO, Vector3.FORWARD, Vector3.FORWARD, 0.0, 1, 0.0], 2).is_empty(),
		"a fire record naming equipment is refused")


func _heal_verb() -> void:
	var t := CombatTarget.new()
	t.set_max_hp({"a": 100.0, "b": 100.0, "c": 50.0})
	t.apply_damage(60.0, "a", "x")      # a 40 / 100
	t.apply_damage(30.0, "b", "x")      # b 70 / 100
	t.apply_damage(50.0, "c", "x")      # c destroyed
	var got: Array = []
	t.healed.connect(func(amt: float, comp: String, _src: String) -> void: got.append([comp, amt]))
	near(t.heal(10.0, "drone"), 10.0, 1e-6, "heal returns what it restored")
	near(float(t.hp["a"]), 50.0, 1e-6, "the most damaged component first")
	near(float(t.hp["b"]), 70.0, 1e-6, "the others untouched")
	near(t.heal(45.0, "drone"), 45.0, 1e-6, "a bigger heal")
	check(float(t.hp["a"]) > float(t.hp["b"]) - 1e-3 or absf(float(t.hp["a"]) / 100.0 - float(t.hp["b"]) / 100.0) < 0.01,
		"it evens out by fraction (a %.1f, b %.1f)" % [float(t.hp["a"]), float(t.hp["b"])])
	eq(float(t.hp["c"]), 0.0, "a destroyed component is never restored")
	var left := t.heal(1000.0, "drone")
	near(float(t.hp["a"]) + float(t.hp["b"]), 200.0, 1e-6, "overflow fills the rest and stops at max")
	check(left < 1000.0, "returns only what fitted (%.1f)" % left)
	check(got.size() >= 2 and str(got[0][0]) == "a", "healed signal per component")
	near(t.heal(5.0, "drone"), 0.0, 1e-6, "nothing to restore at full HP")
	var dead := CombatTarget.new()
	dead.set_max_hp({"body": 10.0})
	dead.apply_damage(10.0, "body", "x")
	near(dead.heal(5.0, "drone"), 0.0, 1e-6, "a destroyed target is not restored")
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	pt.apply_damage(50.0, "torso", "x")
	near(pt.heal(10.0, "drone"), 10.0, 1e-6, "PlayerTarget takes the base heal as is")
	pt.apply_damage(100.0, "head", "x")
	check(pt.disabled, "head destroyed: downed")
	near(pt.heal(10.0, "drone"), 0.0, 1e-6, "a downed PlayerTarget is not restored (revive is a separate verb)")
	t.free()
	dead.free()
	pt.free()


## A rack on an off-tree MechController (its heat doesn't cool by itself, so the sums are exact).
func _rack(loadout: Dictionary, id: String) -> Dictionary:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", loadout)
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, id, 1)
	rack.aim_point = Vector3(0, 3, -60)
	await frames(2)
	return {"world": world, "model": model, "mech": mech, "rack": rack}


func _free(r: Dictionary) -> void:
	(r["rack"] as Node).queue_free()
	(r["model"] as Node).queue_free()
	(r["world"] as Node).queue_free()
	(r["mech"] as Node).free()
	await frames(1)


func _radiator() -> void:
	var r := await _rack({"back": "radiator"}, "rad")
	var rack: WeaponRack = r["rack"]
	var mech: MechController = r["mech"]
	near(rack.cooling_bonus, 3.0, 1e-6, "radiator: cooling bonus 3 /s")
	mech.heat = 50.0
	for i in 60:
		rack.step(DT)
	near(mech.heat, 47.0, 0.01, "60 steps of 1/60 s shed 3 heat")
	mech.heat = 0.5
	for i in 60:
		rack.step(DT)
	near(mech.heat, 0.0, 1e-6, "never below zero")
	await _free(r)
	var r2 := await _rack({"back": "mortar"}, "norad")
	(r2["mech"] as MechController).heat = 50.0
	for i in 60:
		(r2["rack"] as WeaponRack).step(DT)
	near((r2["mech"] as MechController).heat, 50.0 + 0.4, 0.01, "without it: only the mortar's passive heat")
	await _free(r2)


func _ammo_bin() -> void:
	eq(WeaponRack.bonus_ammo(36, 6, 0.5), 54, "rockets 36 -> 54")
	eq(WeaponRack.bonus_ammo(18, 3, 0.5), 27, "missiles 18 -> 27")
	eq(WeaponRack.bonus_ammo(3, 1, 0.5), 5, "mortar 3 -> 4.5 -> 5")
	eq(WeaponRack.bonus_ammo(10, 6, 0.5), 18, "15 rounds up to a whole salvo of 6: 18")
	eq(WeaponRack.bonus_ammo(-1, 1, 0.5), -1, "unlimited stays unlimited")
	eq(WeaponRack.bonus_ammo(36, 6, 0.0), 36, "no bonus: unchanged")
	var r := await _rack({"side_l": "laser", "shoulder_l": "rockets", "shoulder_r": "missiles", "back": "ammo_bin"}, "bin")
	var rack: WeaponRack = r["rack"]
	var sl := rack.slots()
	eq(int(sl[2]["ammo"]), 54, "rocket pod loaded with 54")
	eq(int(sl[2]["ammo_max"]), 54, "ammo_max 54")
	eq(int(sl[3]["ammo"]), 27, "missiles loaded with 27")
	eq(int(sl[0]["ammo_max"]), -1, "the laser stays unlimited")
	check(bool(sl[4]["equipment"]) and bool(sl[4]["passive"]), "the bin's slot is passive equipment")
	await _free(r)
	var r2 := await _rack({"shoulder_l": "rockets", "back": "mortar"}, "nobin")
	eq(int((r2["rack"] as WeaponRack).slots()[1 + 1]["ammo"]), 36, "without the bin: 36 rockets")
	eq(int((r2["rack"] as WeaponRack).slots()[4]["ammo"]), 3, "and 3 mortar shells")
	await _free(r2)


func _drone() -> void:
	var r := await _rack({"side_l": "laser", "back": "repair_drone"}, "medic")
	var world: CombatWorld = r["world"]
	var rack: WeaponRack = r["rack"]
	var mech: MechController = r["mech"]
	mech.position = Vector3(0, 0, 0)
	var me := PlayerTarget.new()
	me.auto_respawn_delay = -1.0
	add_child(me)
	me.bind(world, mech, r["model"], "medic", 1)
	world.register(me)
	# slots() before launch: deselected by default.
	var s5: Dictionary = rack.slots()[4]
	for k in ["equipment", "passive", "active_left", "hint"]:
		check(s5.has(k) and rack.slots()[0].has(k) and rack.slots()[1].has(k), "slots() has `%s` on every slot" % k)
	check(bool(s5["equipment"]) and not bool(s5["passive"]), "slot 5: active equipment")
	check(not rack.enabled[4] and not bool(s5["enabled"]), "the drone slot starts deselected")
	check(rack.enabled[0], "the laser starts selected (weapons keep their default)")
	eq(str(s5["hint"]), "PRESS 5", "hint: PRESS 5 while deselected")
	eq(str(rack.slots()[0]["hint"]), "", "a weapon has no hint")
	eq(int(s5["ammo"]), 2, "two drones")
	eq(int(s5["ammo_max"]), 2, "of two")
	near(float(s5["ready"]), 1.0, 1e-6, "ready to launch")
	near(float(s5["active_left"]), 0.0, 1e-6, "none out")
	check(bool(s5["built"]) and bool(s5["usable"]), "built and usable")
	check(not bool(rack.slots()[0]["equipment"]), "the laser slot is not equipment")
	# The trigger while deselected launches nothing.
	var weapons_fired: Array = []
	world.fired.connect(func(rec: Dictionary) -> void: weapons_fired.append(str(rec["weapon"])))
	rack.set_trigger(true)
	for i in 90:
		rack.step(DT)
		world.advance(DT)
	rack.set_trigger(false)
	rack.step(DT)
	check(world.drone_of("medic") == null, "the trigger with the drone deselected launches nothing")
	eq(rack.charges[4], 2, "and spends no charge")
	check(not "repair_drone" in weapons_fired, "no fire record for the equipment")
	check(weapons_fired.has("laser"), "the laser fired")
	# Key 5 selects, key 5 again deselects; the key alone never launches.
	rack.press_slot(5, 10.0)
	check(rack.enabled[4] and bool(rack.slots()[4]["enabled"]), "key 5 selects the drone slot")
	eq(str(rack.slots()[4]["hint"]), "CLICK TO LAUNCH", "hint: CLICK TO LAUNCH while selected")
	rack.press_slot(5, 11.0)
	check(not rack.enabled[4], "key 5 again deselects it")
	check(world.drone_of("medic") == null and rack.charges[4] == 2, "the key alone launches nothing")
	# Solo / double tap like a weapon slot.
	rack.press_slot(5, 12.0)
	rack.press_slot(5, 12.1)
	eq(rack.enabled, [false, false, false, false, true] as Array[bool], "a double tap on 5 solos the drone slot")
	rack.press_slot(1, 13.0)
	rack.press_slot(1, 13.1)
	eq(rack.enabled, [true, false, false, false, false] as Array[bool], "soloing the laser deselects the drone slot")
	rack.set_enabled(5, true)
	check(rack.enabled[4], "set_enabled selects it")
	rack.set_enabled(5, false)
	check(not rack.enabled[4], "set_enabled deselects it")
	check(world.drone_of("medic") == null, "still nothing launched")
	# The trigger while selected: exactly one drone, 15 heat, the slot deselects itself.
	rack.set_enabled(1, false)
	rack.set_enabled(5, true)
	mech.heat = 0.0
	var h0 := mech.heat
	var passive := float(MechCatalog.weapon("laser").get("passive_heat", 0.0)) * DT
	rack.set_trigger(true)
	rack.step(DT)
	var d := world.drone_of("medic")
	if not check(d != null, "the trigger launched the drone"):
		await _free(r)
		return
	near(mech.heat - h0, 15.0 + passive, 1e-3, "the launch cost 15 heat")
	eq(rack.charges[4], 1, "one drone left")
	check(not rack.enabled[4], "the slot deselected itself after the launch")
	world.advance(DT)
	for i in 60:                                   # keep holding: no second launch
		rack.step(DT)
		world.advance(DT)
	check(world.drone_of("medic") == d and rack.charges[4] == 1, "holding the trigger does not launch a second drone")
	rack.set_trigger(false)
	s5 = rack.slots()[4]
	eq(int(s5["ammo"]), 1, "slots() ammo = drones left")
	near(float(s5["ready"]), 0.0, 1e-6, "not ready while a drone is out")
	eq(str(s5["hold"]), "DRONE OUT", "hold says why")
	eq(str(s5["hint"]), "", "no hint while the drone is out")
	check(float(s5["active_left"]) > 58.0, "active_left counts down from 60 (%.2f)" % float(s5["active_left"]))
	rack.press_slot(5, 30.0)                       # selected while out: a pull does nothing (one at a time)
	eq(str(rack.slots()[4]["hint"]), "", "selected while out: still no hint")
	rack.set_trigger(true)
	_run(rack, world, DT)
	rack.set_trigger(false)
	eq(rack.charges[4], 1, "one at a time: a pull while it is out does nothing")
	check(world.drone_of("medic") == d, "still the same drone")
	rack.set_enabled(5, false)
	# Orbit: 5 m out at hover height, one turn per 6 s.
	var hover_h := RepairDrone.back_height() + 6.0
	_run(rack, world, 0.5)
	var u := Vector3.UP
	near(d.orbit_distance(), 5.0, 0.05, "circles 5 m out from the launcher (%.3f)" % d.orbit_distance())
	near(d.pos.dot(u), hover_h, 0.05, "at the hover height, 6 m above the back mount (%.2f)" % d.pos.dot(u))
	var p1 := d.pos
	_run(rack, world, 1.5)
	var p2 := d.pos
	var a1 := Vector2(p1.x, p1.z)
	var a2 := Vector2(p2.x, p2.z)
	near(absf(a1.angle_to(a2)), PI * 0.5, 0.06, "a quarter turn in 1.5 s (%.3f rad)" % absf(a1.angle_to(a2)))
	_run(rack, world, 4.5)
	near(d.pos.distance_to(p1), 0.0, 0.05, "one full turn in 6 s: back where it was")
	check(d.beamed().is_empty() and not d.ring_shown(), "the launcher at full HP: no beam, no ring")
	# Follows the launcher (smoothed centre).
	mech.position = Vector3(10, 0, 0)
	_run(rack, world, 3.0)
	near(d.orbit_distance(), 5.0, 0.1, "after the launcher walked: still circling it 5 m out (%.3f)" % d.orbit_distance())
	me.position = mech.position
	# Repair: 1 %/s of max HP, most damaged first, never a destroyed component; green only now.
	me.apply_damage(200.0, "torso", "x")      # torso 0.5
	me.apply_damage(20.0, "leg_l", "x")       # leg 0.9
	me.apply_damage(80.0, "side_l", "x")      # the laser hardpoint destroyed
	var torso0 := float(me.hp["torso"])
	var leg0 := float(me.hp["leg_l"])
	var rate := 0.01 * me.total_max_hp()
	_run(rack, world, 1.0)
	print("[equipment] repaired %.3f HP in 1 s (want %.3f)" % [float(me.hp["torso"]) - torso0, rate])
	near(float(me.hp["torso"]) - torso0, rate, rate * 0.05, "1 %% of max HP per second into the torso (%.2f)" % rate)
	near(float(me.hp["leg_l"]), leg0, 1e-6, "the less damaged leg waits")
	eq(float(me.hp["side_l"]), 0.0, "the destroyed hardpoint stays destroyed")
	check(d.beamed().has(me), "a beam points at the damaged mech")
	check(d.ring_shown(), "the ground ring shows while it repairs")
	eq(d.scans_shown(), d.beamed().size(), "one scan look per repaired target")
	var fit := d.scan_fit(me)
	check(float(fit["h"]) > 1.0 and float(fit["r"]) > 0.5, "the scan fits the mech (h %.2f, r %.2f)" % [fit["h"], fit["r"]])
	var sf0 := d.scan_fraction(d.t0 + 0.4)
	near(d.scan_fraction(d.t0 + 0.4), sf0, 0.0, "the scan height is a pure function of the clock")
	near(d.scan_fraction(d.t0 + RepairDrone.SCAN_PERIOD + 0.4), sf0, 1e-6, "the scan repeats every SCAN_PERIOD")
	check(absf(d.scan_fraction(d.t0 + RepairDrone.SCAN_PERIOD * 0.5) - RepairDrone.SCAN_HI) < 1e-6
		and absf(d.scan_fraction(d.t0) - RepairDrone.SCAN_LO) < 1e-6, "it travels the body bottom to top and back")
	# Only targets this machine owns, not enemies, only within 15 m of the LAUNCHER horizontally.
	var remote := _target(world, "remote", 2, "player", mech.position + Vector3(4, 0, 0))
	var enemy := _target(world, "foe", 0, "enemy", mech.position + Vector3(-4, 0, 0))
	var far := _target(world, "far", 0, "", mech.position + Vector3(16, 0, 0))
	var high := _target(world, "high", 0, "", mech.position + Vector3(0, -30, 14))
	var dir := d.pos - mech.position
	dir.y = 0.0
	dir = dir.normalized()
	var opp := _target(world, "opposite", 0, "", mech.position - dir * 14.0)        # 14 m from the launcher, ~19 from the drone
	var by_drone := _target(world, "by_drone", 0, "", mech.position + dir * 16.0)   # 16 m from the launcher, ~11 from the drone
	var hp0 := {}
	for t: CombatTarget in [remote, enemy, far, high, opp, by_drone]:
		hp0[t.target_id] = t.total_hp()
	_run(rack, world, 0.1)
	check(opp.total_hp() > float(hp0["opposite"]), "14 m from the launcher on the far side of the orbit: repaired")
	near(by_drone.total_hp(), float(hp0["by_drone"]), 1e-6, "16 m from the launcher (11 m from the drone): not repaired")
	_run(rack, world, 0.9)
	near(remote.total_hp(), float(hp0["remote"]), 1e-6, "another machine's mech is not healed here")
	near(enemy.total_hp(), float(hp0["foe"]), 1e-6, "an enemy is not healed")
	near(far.total_hp(), float(hp0["far"]), 1e-6, "a target 16 m away is not healed")
	check(high.total_hp() > float(hp0["high"]) + 1.0, "a target 14 m across (30 m below) is: the radius is horizontal")
	check(d.beamed().has(remote), "the remote mech in range, below full: a beam (its owner repairs it)")
	check(not d.beamed().has(enemy), "no beam to an enemy")
	check(not d.beamed().has(by_drone), "no beam out of range")
	for t: Node in [remote, enemy, far, high, opp, by_drone]:
		world.unregister(t as CombatTarget)
		t.queue_free()
	# Everyone full: idle orbit, nothing green, no early return.
	me.repair_all()
	_run(rack, world, 0.2)
	check(d.beamed().is_empty() and not d.ring_shown(), "everyone full: no beam, no ring")
	eq(d.scans_shown(), 0, "everyone full: no scan")
	check(d.active(), "and no early return")
	me.apply_damage(100.0, "torso", "x")
	# 60 s life, then home to the dock.
	_run(rack, world, 60.0 - d.age() - 0.05)
	check(d.active(), "still repairing just before 60 s")
	_run(rack, world, 0.1)
	check(not d.active() and d.returning(), "after 60 s: flying home")
	near(float(rack.slots()[4]["active_left"]), 0.0, 1e-6, "active_left 0")
	eq(str(rack.slots()[4]["hold"]), "DRONE OUT", "hold DRONE OUT until it docks")
	var torso1 := float(me.hp["torso"])
	_run(rack, world, 0.5)
	near(float(me.hp["torso"]), torso1, 1e-6, "no repair on the way home")
	check(d.beamed().is_empty() and not d.ring_shown(), "nothing green on the way home (the launcher is damaged)")
	eq(d.scans_shown(), 0, "no scan on the way home")
	var dock := world.equipment_look.dock(world, "medic", "back")
	var steps := 0
	while d in world.effects and steps < 200:
		_run(rack, world, DT)
		steps += 1
	check(not d in world.effects, "removed once docked")
	var home := world.now - (d.t0 + d.life())
	near(home, float(MechCatalog.weapon("repair_drone")["dock"]), 2.0 * DT, "home in `dock` s (%.3f)" % home)
	if dock.has("pos"):
		near(d.pos.distance_to(dock["pos"]), 0.0, 0.02, "it ends at the dock (%s vs %s)" % [d.pos, dock["pos"]])
	near(float(rack.slots()[4]["ready"]), 1.0, 1e-6, "ready again: the second drone")
	eq(str(rack.slots()[4]["hint"]), "PRESS 5", "deselected after its launch: PRESS 5")
	# Second and last drone; dies with the launcher at once.
	rack.set_enabled(5, true)
	rack.set_trigger(true)
	_run(rack, world, DT)
	rack.set_trigger(false)
	var d2 := world.drone_of("medic")
	check(d2 != null and d2 != d, "the second drone launched")
	eq(rack.charges[4], 0, "no drones left")
	check(not rack.enabled[4] and not bool(rack.slots()[4]["usable"]), "no charges: deselected and unusable")
	_run(rack, world, 1.0)
	me.apply_damage(200.0, "head", "x")
	check(me.disabled, "the launcher is downed")
	_run(rack, world, DT)
	check(d2 == null or not d2 in world.effects, "the drone dies with its launcher: removed at once (no return)")
	me.repair_all()
	_run(rack, world, 0.2)
	rack.press_slot(5, 200.0)
	check(not rack.enabled[4], "no charges: its key can't select it")
	rack.set_enabled(5, true)
	check(not rack.enabled[4], "nor set_enabled")
	check(rack.activate(5) == false and world.drone_of("medic") == null, "no charges: nothing launches")
	eq(str(rack.slots()[4]["hold"]), "EMPTY", "hold EMPTY")
	eq(str(rack.slots()[4]["hint"]), "", "no hint when empty")
	near(float(rack.slots()[4]["ready"]), 0.0, 1e-6, "not ready when empty")
	print("[equipment] drone section done")
	me.queue_free()
	await _free(r)


## activate(n) launches regardless of selection (tests / bots).
func _activate_direct() -> void:
	var r := await _rack({"back": "repair_drone"}, "direct")
	var rack: WeaponRack = r["rack"]
	check(not rack.enabled[4], "deselected")
	check(rack.activate(5), "activate(5) launches while deselected")
	check((r["world"] as CombatWorld).drone_of("direct") != null, "the drone is out")
	eq(rack.charges[4], 1, "one charge spent")
	check(not rack.activate(5), "activate refuses a second while one is out")
	await _free(r)


## Two worlds, the same launch record and clock, different step sizes: the drone is at the same place (the orbit angle
## is a pure function of the clock).
func _orbit_shared() -> void:
	var worlds: Array = []
	var anchors: Array = []
	for k in 2:
		var w := CombatWorld.new()
		w.use_physics = false
		add_child(w)
		var a := Node3D.new()
		add_child(a)
		a.position = Vector3(3, 0, -2)
		var af := a
		w.set_anchor("orb", func() -> Node3D: return af)
		w.advance(0.25)
		worlds.append(w)
		anchors.append(a)
	var rec := {"shooter": "orb", "peer": 3, "hardpoint": "back", "weapon": "repair_drone", "t": 0.1}
	var da := (worlds[0] as CombatWorld).launch_drone(rec)
	var db := (worlds[1] as CombatWorld).launch_drone(rec)
	if not check(da != null and db != null, "both worlds launched"):
		return
	var worst := 0.0
	for i in 40:                                     # world A in 1/60 s steps, world B in 0.1 s steps, compared at 0.1 s marks
		for j in 6:
			(worlds[0] as CombatWorld).advance(0.1 / 6.0)
		(worlds[1] as CombatWorld).advance(0.1)
		if da.age() > 1.0:
			worst = maxf(worst, da.pos.distance_to(db.pos))
	print("[equipment] two worlds: worst drone offset %.4f m" % worst)
	check(worst < 0.01, "the same record and clock: the same orbit on both (%.4f m)" % worst)
	near(da.orbit_distance(), 5.0, 0.01, "5 m out")
	for n: Node in worlds + anchors:
		n.queue_free()
	await frames(1)




func _passive_key() -> void:
	var r := await _rack({"side_l": "laser", "back": "radiator"}, "fins")
	var rack: WeaponRack = r["rack"]
	var s5: Dictionary = rack.slots()[4]
	check(bool(s5["equipment"]) and bool(s5["passive"]), "radiator: passive equipment")
	eq(int(s5["ammo"]), -1, "no charges")
	eq(str(s5["hold"]), "PASSIVE", "hold PASSIVE")
	near(float(s5["ready"]), 1.0, 1e-6, "always ready")
	check(not rack.activate(5), "activate() refuses a passive")
	check(rack.enabled[4] and bool(s5["enabled"]), "a passive is always enabled")
	eq(str(s5["hint"]), "", "a passive has no hint")
	rack.press_slot(5, 1.0)
	check(rack.enabled[4] and (r["world"] as CombatWorld).drone_of("fins") == null, "its key does nothing")
	rack.set_enabled(5, false)
	check(rack.enabled[4], "set_enabled can't switch a passive off")
	rack.press_slot(1, 2.0)
	rack.press_slot(1, 2.1)
	check(rack.enabled[4], "soloing another slot leaves a passive on")
	rack.set_enabled(1, true)
	rack.press_slot(1, 3.0)
	rack.press_slot(5, 3.1)
	rack.press_slot(1, 3.2)
	check(rack.enabled[0], "a press of a passive's key breaks a pending double tap (slot 1 toggled back on)")
	await _free(r)


## The drone mesh in flight, the dock launch, the cradle swap on launch / return / last charge, a rebuilt model, and the
## placeholder fallback.
func _drone_looks() -> void:
	var r := await _rack({"side_l": "laser", "back": "repair_drone"}, "looks")
	var world: CombatWorld = r["world"]
	var rack: WeaponRack = r["rack"]
	var model: MechModel = r["model"]
	model.set_accent(Color(0.2, 0.8, 0.9))
	world.advance(DT)
	var look := world.equipment_look
	eq(look.shown("looks"), "docked", "before launch the back mount shows the docked drone")
	var mi := _mount_mi(model, "repair_drone")
	check(mi != null and mi.mesh == MechMeshes.mesh("weapon_repair_drone"), "the mount carries weapon_repair_drone")
	var dock := look.dock(world, "looks", "back")
	check(dock.has("pos"), "the dock is found on HP_back")
	rack.activate(5)
	var d := world.drone_of("looks")
	if not check(d != null and mi != null and dock.has("pos"), "launched"):
		await _free(r)
		return
	eq(look.shown("looks"), "cradle", "on launch: the empty cradle at once")
	check(mi.mesh == MechMeshes.mesh("weapon_repair_drone_cradle"), "the mount mesh is weapon_repair_drone_cradle")
	check(d.flying_mesh, "the flying drone uses the Mech mesh")
	var body := d.get_node_or_null("weapon_repair_drone_flying") as MeshInstance3D
	check(body != null and body.mesh == MechMeshes.mesh("weapon_repair_drone_flying"), "body = weapon_repair_drone_flying")
	if body != null:
		var accent_ok := false
		for i in body.mesh.get_surface_count():
			if (body.mesh as ArrayMesh).surface_get_name(i) == "accent":
				var m := body.get_surface_override_material(i) as StandardMaterial3D
				accent_ok = m != null and m.albedo_color.is_equal_approx(model.accent)
		check(accent_ok, "the flying drone takes the launcher's accent")
	near(d.pos.distance_to(dock["pos"]), 0.0, 0.05, "launch starts at the dock (%s vs %s)" % [d.pos, dock["pos"]])
	_run(rack, world, 1.0)
	if body != null:
		near(body.scale.x, RepairDrone.FLY_SCALE, 1e-3, "full size once risen")
	(r["mech"] as MechController).position = Vector3(12, 0, 0)
	var yaw0 := d.yaw
	_run(rack, world, 1.0)
	check(absf(angle_difference(yaw0, d.yaw)) > 0.2, "it turns toward travel (yaw %.2f -> %.2f)" % [yaw0, d.yaw])
	# A loadout rebuild while the drone is out: the new node shows the cradle too.
	model.rebuild()
	world.advance(DT)
	var mi2 := _mount_mi(model, "repair_drone")
	check(mi2 != null and mi2 != mi and mi2.mesh == MechMeshes.mesh("weapon_repair_drone_cradle"),
		"after MechModel.rebuild the swap re-applies to the new node")
	# Home: the cradle stays empty on the way, the drone shrinks toward the mount's scale, then docked again.
	_run(rack, world, 60.0 + 0.75 - d.age())
	check(d.returning(), "flying home")
	eq(look.shown("looks"), "cradle", "on its way home: still the empty cradle")
	if body != null:
		check(body.scale.x < RepairDrone.FLY_SCALE - 0.1 and body.scale.x > float(dock["scale"]),
			"shrinking toward the docked size (%.2f)" % body.scale.x)
	_run(rack, world, 0.75 + 2.0 * DT)
	check(world.drone_of("looks") == null, "the first drone is docked and gone")
	var dock2 := look.dock(world, "looks", "back")
	near(d.pos.distance_to(dock2["pos"]), 0.0, 0.02, "it landed on the dock")
	eq(look.shown("looks"), "docked", "docked again")
	check(mi2 != null and mi2.mesh == MechMeshes.mesh("weapon_repair_drone"), "the mount mesh is back to weapon_repair_drone")
	# Last charge: empty cradle while out, docked again after (it came home).
	rack.activate(5)
	eq(rack.charges[4], 0, "the last drone")
	eq(look.shown("looks"), "cradle", "last drone out: cradle")
	_run(rack, world, 60.0 + 1.5 + 0.2)
	check(world.drone_of("looks") == null, "the last drone is gone")
	eq(look.shown("looks"), "docked", "no charges left: the drone is docked again (it came home)")
	eq(str(rack.slots()[4]["hold"]), "EMPTY", "and the HUD says EMPTY")
	await _free(r)
	# Fallback: a missing flying part draws the placeholder quad.
	var keep := RepairDrone.flying_id
	RepairDrone.flying_id = "no_such_part"
	var r2 := await _rack({"back": "repair_drone"}, "fallback")
	(r2["rack"] as WeaponRack).activate(5)
	var d2 := (r2["world"] as CombatWorld).drone_of("fallback")
	check(d2 != null and not d2.flying_mesh and d2.get_child_count() > 4, "missing part: the placeholder drone (rotors)")
	RepairDrone.flying_id = keep
	await _free(r2)


## A shooter with no rack here (a crew puppet on another machine): the cradle follows the drone effect only (empty while
## it is alive, docked again after each return, also after the last charge).
func _remote_cradle() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"back": "repair_drone"})
	world.set_anchor("player7", func() -> Node3D: return model)
	world.advance(DT)
	var look := world.equipment_look
	eq(look.shown("player7"), "docked", "remote: docked before any launch")
	for k in 2:
		world.launch_drone({"shooter": "player7", "peer": 7, "hardpoint": "back", "weapon": "repair_drone", "t": world.now})
		eq(look.shown("player7"), "cradle", "remote launch %d: cradle" % (k + 1))
		for i in int((60.0 + 0.7) / 0.1):
			world.advance(0.1)
		eq(look.shown("player7"), "cradle", "remote drone %d on its way home: cradle" % (k + 1))
		for i in int((0.8 + 0.2) / 0.1):
			world.advance(0.1)
		eq(look.shown("player7"), "docked", "remote drone %d home: docked" % (k + 1))
	world.queue_free()
	model.queue_free()
	await frames(1)


## The radiator's "heat" surface glows with the mech's heat; one material, rewritten only on a real change.
func _radiator_glow() -> void:
	var r := await _rack({"back": "radiator"}, "hot")
	var world: CombatWorld = r["world"]
	var mech: MechController = r["mech"]
	var model: MechModel = r["model"]
	mech.heat = 0.0
	world.advance(DT)
	var mat := world.equipment_look.glow_material("hot")
	var mi := _mount_mi(model, "radiator")
	if not check(mat != null and mi != null, "the radiator has a glow material"):
		await _free(r)
		return
	var surf := -1
	for i in mi.mesh.get_surface_count():
		if (mi.mesh as ArrayMesh).surface_get_name(i) == "heat":
			surf = i
	check(surf >= 0 and mi.get_surface_override_material(surf) == mat, "set on the surface named heat")
	near(mat.emission_energy_multiplier, 0.0, 1e-6, "dark when cold")
	var cold := _lum(mat)
	mech.heat = 0.5 * mech.heat_cap
	world.advance(DT)
	var warm := _lum(mat)
	mech.heat = 0.97 * mech.heat_cap
	world.advance(DT)
	var hot := _lum(mat)
	check(cold < warm and warm < hot, "emission rises with heat (%.3f < %.3f < %.3f)" % [cold, warm, hot])
	check(mat.emission.r > mat.emission.g * 2.0, "red-hot near overheat (%s)" % mat.emission)
	mech.heat = 0.975 * mech.heat_cap
	world.advance(DT)
	near(_lum(mat), hot, 1e-6, "a tiny change does not rewrite the material")
	check(world.equipment_look.glow_material("hot") == mat, "one material per mech")
	mech.heat = 0.0
	world.advance(DT)
	near(mat.emission_energy_multiplier, 0.0, 1e-6, "dark again once cooled")
	await _free(r)


func _lum(mat: StandardMaterial3D) -> float:
	return mat.emission.get_luminance() * mat.emission_energy_multiplier


## The MeshInstance3D MechModel mounted for equipment `id` (HP_back/Weapon_<id>/...), or null.
func _mount_mi(model: MechModel, id: String) -> MeshInstance3D:
	var hp := model.find_child("HP_back", true, false)
	var wn := hp.get_node_or_null("Weapon_" + id) if hp != null else null
	if wn == null:
		return null
	for c in wn.get_children():
		if c is MeshInstance3D:
			return c
	return null


func _run(rack: WeaponRack, world: CombatWorld, secs: float) -> void:
	var n := maxi(int(round(secs / DT)), 1)
	for i in n:
		rack.step(DT)
		world.advance(DT)


func _target(world: CombatWorld, id: String, peer: int, team: String, at: Vector3) -> CombatTarget:
	var t := CombatTarget.new()
	t.target_id = id
	t.owner_peer = peer
	t.team = team
	t.mass_class = "static"
	t.set_max_hp({"body": 1000.0})
	t.add_hit_sphere("body", Vector3(0, 2, 0), 1.0)
	t.apply_damage(500.0, "body", "x")
	add_child(t)
	t.position = at
	world.register(t)
	return t
