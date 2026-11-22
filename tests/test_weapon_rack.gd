extends TestCase
## WeaponRack: slots follow the chassis hardpoint order, number presses toggle and a quick double press solos, the
## trigger fires every enabled weapon and only those, heat goes to the MechController (passive + active, shutdown stops
## fire), slots() reports ammo / ready / reloading / blocked, the guided track is automatic (on while an enabled guided
## weapon is carried and the mech can act, dot = the aim point, no heat, never on the right mouse button), and in the test
## drive the rack and the dummies exist and holding the trigger damages the dummy ahead.

const DT := 1.0 / 60.0
const LOADOUT := {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "mortar"}


func setup() -> void:
	await _rack_logic()
	await _guided_track()
	await _test_drive()
	_playable_loadout()
	await _paused_drive()
	finish()


## WeaponRegistry.playable_loadout swaps only unbuilt weapons, for the slot's default, keeps empty slots empty and the
## player's other picks, and says what it swapped. Two weapons are made "paused" explicitly (WeaponRegistry.set_disabled),
## so this doesn't depend on which weapons happen to be unbuilt.
func _playable_loadout() -> void:
	WeaponRegistry.set_disabled(["flamer", "missiles"])
	check(not WeaponRegistry.built("flamer") and WeaponRegistry.behaviour("flamer") == null, "a disabled weapon counts as unbuilt")
	var pick := {"side_l": "flamer", "side_r": "gatling", "shoulder_l": "missiles", "shoulder_r": "", "back": "mortar"}
	var r := WeaponRegistry.playable_loadout("strider", pick)
	var l: Dictionary = r["loadout"]
	var def: Dictionary = MechCatalog.chassis("strider")["default_loadout"]
	eq(str(l["side_l"]), str(def["side_l"]), "a paused flamer becomes the slot default")
	eq(str(l["shoulder_l"]), str(def["shoulder_l"]), "paused missiles become the slot default")
	eq(str(l["side_r"]), "gatling", "a built pick is kept")
	eq(str(l["back"]), "mortar", "a built pick is kept (back)")
	eq(str(l["shoulder_r"]), "", "an empty slot stays empty")
	eq((r["notes"] as Array).size(), 2, "one note per swap")
	check(str((r["notes"] as Array)[0]).contains("Flamer offline"), "the note names the paused weapon (%s)" % str((r["notes"] as Array)[0]))
	var none := WeaponRegistry.playable_loadout("strider", def)
	eq((none["notes"] as Array).size(), 0, "the default loadout needs no swap")
	eq(none["loadout"], MechCatalog.sanitize_loadout("strider", def), "and is unchanged")
	WeaponRegistry.set_disabled([])
	check(WeaponRegistry.built("flamer"), "re-enabled after the test")
	eq((WeaponRegistry.playable_loadout("strider", pick)["notes"] as Array).size(), 0, "with everything built, a real pick is kept whole")


## A saved hangar pick with paused weapons (flamer and railgun disabled for the test): the test drive flies every
## non-empty slot with a built weapon, the model carries the substitutes, the swaps are reported, and the saved settings
## are untouched.
func _paused_drive() -> void:
	WeaponRegistry.set_disabled(["flamer", "railgun"])
	var old := GameSettings.path
	GameSettings.path = "user://test_weapon_rack_paused.cfg"
	var st := GameSettings.load_settings()
	st["loadout"] = {"side_l": "flamer", "side_r": "autocannon", "shoulder_l": "railgun", "shoulder_r": "", "back": "mortar"}
	GameSettings.save_settings(st)
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(10)
	var rack := td.combat.rack
	var all_built := true
	var empties := 0
	for sl in rack.slots():
		if str(sl["weapon"]) == "":
			empties += 1
		else:
			all_built = all_built and bool(sl["built"])
	check(all_built, "every non-empty slot is built")
	eq(empties, 1, "the empty slot stays empty")
	eq(str(td.rig.model.loadout["side_l"]), "laser", "the model carries the substitute")
	eq(str(td.rig.model.loadout["side_r"]), "autocannon", "the player's other pick is kept")
	eq(td.combat.substitutions().size(), 2, "the swaps are reported (%s)" % str(td.combat.substitutions()))
	eq(str((GameSettings.load_settings()["loadout"] as Dictionary)["side_l"]), "flamer", "saved settings are untouched")
	td.queue_free()
	await frames(2)
	WeaponRegistry.set_disabled([])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
	GameSettings.path = old


func _rack_logic() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", LOADOUT)
	var mech := MechController.new()     # not in the tree: its heat doesn't cool, so the sums are exact
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "tester", 1)
	rack.aim_point = Vector3(0, 3, -60)
	await frames(2)
	# Slot order and contents.
	eq(rack.hardpoints, ["side_l", "side_r", "shoulder_l", "shoulder_r", "back"] as Array[String], "slots follow the chassis order")
	var sl := rack.slots()
	eq(sl.size(), 5, "five slots")
	for k in ["slot", "hardpoint", "weapon", "name", "enabled", "ammo", "ammo_max", "ready", "reloading", "heat_per_shot",
			"blocked", "in_range", "hold", "built", "muzzle", "designating"]:
		check(sl[0].has(k), "slots() has `%s`" % k)
	eq(sl[1]["weapon"], "autocannon", "slot 2 is side_r's autocannon")
	eq(sl[3]["weapon"], "", "slot 4 (shoulder_r) is empty")
	eq(sl[1]["muzzle"], rack.muzzle(2), "slots() muzzle = the point the rack fires from")
	check(rack._glows[0] is ChargeGlow and rack._glows[1] == null, "the laser slot has a charge glow, the autocannon none")
	var live := world.muzzle_of({"shooter": "tester", "hardpoint": "side_l"})
	check(live.is_valid() and (live.call() as Vector3).is_equal_approx(rack.muzzle(1)), "the rack registers each slot's live muzzle")
	var hp_r := model.find_child("HP_side_r", true, false) as Node3D
	var off := (sl[1]["muzzle"] as Vector3).distance_to(hp_r.global_position)
	check(off > 0.5 and off < 6.0, "the autocannon muzzle sits ahead of its hardpoint (%.2f m)" % off)
	var hp_e := model.find_child("HP_shoulder_r", true, false) as Node3D
	check((sl[3]["muzzle"] as Vector3).distance_to(hp_e.global_position) < 1e-4, "an empty slot's muzzle is its hardpoint")
	eq(sl[2]["ammo_max"], 36, "rockets: 36 rounds")
	eq(sl[0]["ammo_max"], -1, "laser: unlimited")
	check(rack.enabled.all(func(e: bool) -> bool: return e), "all slots start enabled")
	# Toggle, slow second press = toggle again, double tap = solo, empty slot ignored.
	var changed: Array[int] = []
	rack.slot_changed.connect(func(n: int) -> void: changed.append(n))
	rack.press_slot(1, 10.0)
	check(not rack.enabled[0], "1 disables slot 1")
	rack.press_slot(1, 10.5)
	check(rack.enabled[0], "a slow second press of 1 toggles it back on")
	rack.press_slot(2, 20.0)
	rack.press_slot(2, 20.2)
	eq(rack.enabled, [false, true, false, false, false] as Array[bool], "double-tapping 2 solos slot 2")
	check(changed.size() >= 4, "slot_changed fires (%d)" % changed.size())
	rack.press_slot(4, 30.0)
	eq(rack.enabled[3], false, "an empty slot ignores its key")
	# Trigger: only the soloed autocannon fires; the others spend no heat or ammo.
	var shots := {}
	rack.fired.connect(func(n: int) -> void: shots[n] = int(shots.get(n, 0)) + 1)
	rack.set_trigger(true)
	for i in 60:
		rack.step(DT)
		world.advance(DT)
	rack.set_trigger(false)
	var ac := int(shots.get(2, 0))
	check(ac >= 2, "the autocannon fired (%d)" % ac)
	eq(shots.keys(), [2], "only the enabled slot fired")
	eq(rack.mounts[2].ammo, 36, "disabled rockets spent no ammo")
	var passive := 0.5 + 0.3 + 0.2 + 0.4
	near(mech.heat, ac * 1.5 + passive * 60 * DT, 0.05, "heat in the controller = autocannon shots + passive")
	# Rockets: solo slot 3, one salvo, ammo falls, reload cycles `ready`.
	rack.press_slot(3, 40.0)
	rack.press_slot(3, 40.1)
	eq(rack.enabled, [false, false, true, false, false] as Array[bool], "double-tapping 3 solos the rockets")
	shots.clear()
	var h0 := mech.heat
	rack.set_trigger(true)
	for i in 6:
		rack.step(DT)
	rack.set_trigger(false)
	for i in 40:
		rack.step(DT)
	eq(int(shots.get(3, 0)), 6, "one salvo of six rockets")
	eq(int(rack.slots()[2]["ammo"]), 30, "ammo fell to 30")
	check(mech.heat > h0 + 9.0, "the salvo's 10 heat went to the controller")
	check(bool(rack.slots()[2]["reloading"]), "reloading after the salvo")
	var r0 := float(rack.slots()[2]["ready"])
	check(r0 < 0.5, "ready is low right after the salvo (%.2f)" % r0)
	for i in 60 * 4:
		rack.step(DT)
	near(float(rack.slots()[2]["ready"]), 1.0, 0.001, "ready back to 1 after the reload")
	check(not bool(rack.slots()[2]["reloading"]), "reload done")
	# No guided weapon carried: the track stays off.
	check(not bool(world.designators["tester"]["on"]), "no guided weapon: the track is off")
	check(not rack.designator_on(), "designator_on() is false without a guided weapon")
	# Shutdown: nothing fires.
	for n in 5:
		rack.set_enabled(n + 1, true)
	mech.add_heat(500.0)
	check(bool(rack.heat_state()["shutdown"]), "heat_state reports the controller's shutdown")
	shots.clear()
	rack.set_trigger(true)
	for i in 30:
		rack.step(DT)
	eq(shots.size(), 0, "no fire while shut down")
	rack.set_trigger(false)
	mech.heat = 0.0          # test only: reboot the gauge
	mech.shutdown = false
	rack.step(DT)
	var hs := rack.heat_state()
	check(hs.has("heat") and hs.has("cap") and hs.has("fraction"), "heat_state fields")
	# Line of sight: a wall between the autocannon and the aim point blocks it; the mortar (arc) doesn't care.
	check(not bool(rack.slots()[1]["blocked"]), "clear line of sight")
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 30, 1)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(0, 3, -30)
	add_child(wall)
	await frames(2)
	rack.step(DT)
	check(bool(rack.slots()[1]["blocked"]), "a wall blocks the autocannon")
	check(not bool(rack.slots()[4]["blocked"]), "the mortar lobs over")
	wall.queue_free()
	await frames(2)
	rack.step(DT)
	check(not bool(rack.slots()[1]["blocked"]), "clear again without the wall")
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


## Guided missiles track the live aim point: with a `missiles` slot enabled the world's designator entry is on and its dot
## follows the aim point, disabling the slot or a shutdown turns it off, no designator heat is charged, and the rack has
## no designator control and never reads the right mouse button.
func _guided_track() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "", "side_r": "", "shoulder_l": "missiles", "shoulder_r": "", "back": ""})
	var mech := MechController.new()     # not in the tree: its heat doesn't cool, so the sums are exact
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "guide", 1)
	await frames(2)
	eq(rack.weapons[2], "missiles", "the missiles are mounted on shoulder_l")
	check(not rack.has_method("set_designator"), "no manual designator control")
	check(not ("designator" in rack), "no designator switch var")
	var src := (rack.get_script() as Script).source_code
	check(not src.contains("MOUSE_BUTTON_RIGHT"), "the rack never reads the right mouse button")
	rack.aim_point = Vector3(0, 3, -60)
	rack.step(DT)
	check(bool(world.designators["guide"]["on"]), "a guided weapon enabled: the track is on")
	eq(world.designators["guide"]["dot"], rack.aim_point, "the dot is this step's aim point")
	check(rack.designator_on(), "designator_on() agrees")
	check(bool(rack.slots()[2]["designating"]), "the missile slot reports designating")
	check(not bool(rack.slots()[0]["designating"]), "an empty slot doesn't")
	rack.aim_point = Vector3(20, 5, -90)
	rack.step(DT)
	eq(world.designators["guide"]["dot"], rack.aim_point, "the dot follows the aim point")
	# No designator heat: 60 steps of tracking cost only the missiles' passive heat.
	var h0 := mech.heat
	for i in 60:
		rack.step(DT)
	near(mech.heat - h0, 0.4 * 60 * DT, 0.001, "only passive heat while tracking (no designator heat)")
	# Disabling the missile slot turns the track off.
	rack.set_enabled(3, false)
	rack.step(DT)
	check(not bool(world.designators["guide"]["on"]), "missile slot disabled: the track is off")
	check(not bool(rack.slots()[2]["designating"]), "and the slot no longer designates")
	rack.set_enabled(3, true)
	rack.step(DT)
	check(bool(world.designators["guide"]["on"]), "re-enabled: the track is back on")
	# Shutdown turns it off.
	mech.add_heat(500.0)
	rack.step(DT)
	check(not bool(world.designators["guide"]["on"]), "no track while shut down")
	check(not bool(rack.slots()[2]["designating"]), "no designating slot while shut down")
	mech.heat = 0.0          # test only: reboot the gauge
	mech.shutdown = false
	rack.step(DT)
	check(bool(world.designators["guide"]["on"]), "back on after the reboot")
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


func _test_drive() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(10)
	if not check(td.combat != null and td.combat.rack != null, "the test drive has a weapon rack"):
		td.queue_free()
		return
	var rack := td.combat.rack
	eq(rack.slot_count(), 5, "five slots on the strider")
	check(td.combat.enemies.size() >= 3, "test drive spawns seeded enemies (%d)" % td.combat.enemies.size())
	check(td.combat.player_target != null and td.combat.squad != null, "test drive binds player_target and enemy squad")
	var ring := td.city.ring
	var e := td.combat.enemies[0]
	check(absf(ring.height(e.global_position)) < 1.5, "%s stands on the avenue ahead (h %.2f)" % [e.name, ring.height(e.global_position)])
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var built := false
	for s in rack.slots():
		built = built or bool(s["built"])
	if not check(built, "the loadout has a built weapon"):
		td.queue_free()
		return
	rack.read_input = false
	rack.manual_aim = true
	rack.aim_point = (e.world_spheres()[0]["center"] as Vector3)
	var hp0 := e.total_hp()
	var heat0 := td.mech.heat
	rack.set_trigger(true)
	var peak := 0.0
	for i in 150:
		if is_instance_valid(e) and not e.destroyed():
			rack.aim_point = (e.world_spheres()[0]["center"] as Vector3)
		await frames(1)
		peak = maxf(peak, td.mech.heat)
	rack.set_trigger(false)
	var damaged_or_dead := (not is_instance_valid(e)) or e.destroyed() or e.total_hp() < hp0
	check(damaged_or_dead, "holding the trigger damaged or destroyed the vanguard enemy")
	check(peak > heat0 + 5.0, "firing heated the mech (peak %.1f)" % peak)
	td.queue_free()
	await frames(1)
