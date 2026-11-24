extends TestCase
## The menus navigate, the hangar saves a loadout, and solo hosting works: Play with no Steam (a test run never starts
## Steam) opens an ENet crew of one and lands on the hangar with this pilot in the crew; Leave goes back.

const PATH := "user://test_menu_settings.cfg"
const PORT := 28990


func setup() -> void:
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	Session.telemetry_dir = "user://net_tests"
	Session.set_profile("Solo", "dog", "strider")
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(2)
	eq(fe.screen, "main", "opens on the main menu")
	for b: Button in [fe.btn_play, fe.btn_join, fe.btn_settings, fe.btn_lab, fe.btn_quit]:
		check(b != null and b.visible and not b.disabled, "main menu button %s" % (b.text if b != null else "?"))
	check(fe.stage.models.size() == 1, "the preview shows one mech beside the menu")

	# Hangar offline (the solo fallback when no port is free): pick a weapon, it is saved.
	fe.show_screen("hangar")
	await frames(1)
	check(fe.chassis_pick != null and fe.weapon_picks.size() == 5, "the hangar has a chassis pick and five hardpoints")
	check(fe.stage.in_bay and fe.stage.bay != null and fe.stage.bay.visible, "the hangar shows the assault boat's bay")
	eq(fe.stage.models.size(), 1, "one mech stands in a cradle")
	eq(fe.stage.bay.state, "prep", "the bay starts in prep")
	fe.stage.set_alert(true)
	eq(fe.stage.bay.state, "alert", "launch puts the bay on alert")
	fe.stage.set_alert(false)
	await _clamps_clear(fe.stage)
	fe.show_screen("hangar")
	var pick: OptionButton = fe.weapon_picks["side_l"]
	var flamer := -1
	for i in pick.item_count:
		if pick.get_item_text(i).begins_with("Flamer"):
			flamer = i
	check(flamer > 0, "the left arm offers the flamer")
	pick.select(flamer)
	pick.item_selected.emit(flamer)
	await frames(1)
	eq(str((GameSettings.load_settings()["loadout"] as Dictionary).get("side_l", "")), "flamer", "the loadout is saved")
	check(fe.stats_label.text.contains("Weight"), "the loadout readout shows weight and heat")
	await _back_equipment(fe)
	fe.btn_leave.pressed.emit()
	await frames(1)
	eq(fe.screen, "main", "Back from the offline hangar returns to the main menu")
	check(not fe.stage.in_bay and not fe.stage.bay.visible, "the main menu is back on the turntable")

	# Solo host: Session opens a crew of one. (The menu's Play uses DEFAULT_PORT; the test uses its own port to stay
	# clear of a running game, through the same calls.)
	var port := test_port(PORT)
	check(Session.host_enet(port), "an ENet crew opens on port %d" % port)
	await frames(2)
	eq(fe.screen, "hangar", "a started session shows the hangar")
	check(Session.online() and Session.hosting, "hosting")
	eq(Session.roster.size(), 1, "a crew of one")
	eq(str(Session.local_entry().get("head", "")), "dog", "the roster carries this pilot's head")
	eq(fe.crew_list.get_child_count(), 3, "the crew list shows the pilot, the open seats and the host's bot row (Add bot)")
	check(fe.btn_add_bot != null, "the host gets Add bot (docs/design/hangar-bots.md)")
	check(fe.btn_launch != null and not fe.btn_launch.disabled, "the host can launch")
	fe.btn_leave.pressed.emit()
	await frames(3)
	check(not Session.online(), "Leave closes the crew")
	eq(fe.screen, "main", "and returns to the main menu")
	eq(Session.last_reason, NetSession.CREW_CLOSED, "the host closed it")
	fe.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()


## The bay's shoulder clamps and brace arms (HangarBay.fit_clamps) clear every crew mech's measured box: open in prep,
## mid-swing, and closed in alert (where they must also actually reach it: at most CLOSE_MAX off). A crew of four with
## the widest weapons, in the chicken-leg stance and the forward one.
const CLEAR_TOL := 0.01     ## m of overlap still counted as touching (box rounding)
const CLOSE_MAX := 0.2      ## m: a closed clamp's pad stops at most this far from the mech

func _clamps_clear(stage: MechStage) -> void:
	var wide := {"side_l": "autocannon", "side_r": "gatling", "shoulder_l": "railgun", "shoulder_r": "missiles", "back": "mortar"}
	var heads := MechCatalog.HEAD_ORDER
	var entries: Array = []
	for i in 4:
		entries.append({"head": heads[i % heads.size()], "chassis": "strider", "name": "P%d" % (i + 1),
			"loadout": wide if i % 2 == 0 else {}})
	stage.show_mechs(entries, true)
	await frames(2)
	var bay := stage.bay
	for bend: float in [-1.0, 1.0]:
		for m in bay.models:
			m.leg_bend = bend
			m.rebuild()
		bay.fit_clamps()
		var legs := "chicken" if bend < 0.0 else "forward"
		for phase: String in ["prep", "mid", "alert"]:
			bay.set_alert(phase != "prep")
			bay._alert_k = {"prep": 0.0, "mid": 0.5, "alert": 1.0}[phase]
			bay._apply_lights()
			await frames(2)
			var worst := INF
			var widest := 0.0
			for i in 4:
				worst = minf(worst, bay.clamp_clearance(i))
				for g: float in bay.pad_gaps(i):
					widest = maxf(widest, g)
			check(worst > -CLEAR_TOL, "bay %s legs, %s: clamps and brace arms clear the mechs (closest %.3f m)" % [legs, phase, worst])
			if phase == "alert":
				check(widest <= CLOSE_MAX, "bay %s legs, alert: every clamp closes onto its mech (farthest %.3f m)" % [legs, widest])
			print("clamp clearance %s %s: closest mesh %.3f m, farthest pad %.3f m" % [legs, phase, worst, widest])
	bay.set_alert(false)
	bay._alert_k = 0.0
	bay._apply_lights()


## Back-mount equipment in the hangar (docs/design/back-equipment.md): the back slot offers the mortar AND every
## equipment item; picking the radiator is saved, reaches the session's profile, and raises the cooling shown by its
## cooling_bonus (MechCatalog.loadout_stats does not count it; FrontEnd.hangar_stats does).
func _back_equipment(fe: FrontEnd) -> void:
	var back: OptionButton = fe.weapon_picks["back"]
	var texts: Array[String] = []
	for i in back.item_count:
		texts.append(back.get_item_text(i))
	check(texts.any(func(t: String) -> bool: return t.begins_with("Mortar")), "the back slot still offers the mortar")
	for id: String in MechCatalog.equipment_for("back"):
		var nm := str(MechCatalog.weapon(id)["name"])
		check(texts.any(func(t: String) -> bool: return t.begins_with(nm)), "the back slot offers %s" % nm)
	check(texts.any(func(t: String) -> bool: return t.contains("key 5")), "the active drone's label names its key")
	check(texts.any(func(t: String) -> bool: return t.contains("passive")), "passive equipment is labelled passive")
	var chassis := str(fe.settings["chassis"])
	var before := FrontEnd.hangar_stats(chassis, fe._loadout())
	var rad := texts.find(texts.filter(func(t: String) -> bool: return t.begins_with("Radiator"))[0])
	back.select(rad)
	back.item_selected.emit(rad)
	await frames(1)
	eq(str((GameSettings.load_settings()["loadout"] as Dictionary).get("back", "")), "radiator", "the radiator pick is saved")
	eq(str(Session.local_loadout().get("back", "")), "radiator", "the radiator survives Session.set_profile / clean_loadout")
	var after := FrontEnd.hangar_stats(chassis, fe._loadout())
	var bonus := float(MechCatalog.weapon("radiator")["cooling_bonus"])
	near(float(after["cooling"]), float(MechCatalog.chassis(chassis)["cooling"]) + bonus, 0.001, "the radiator adds its cooling_bonus")
	check(float(after["cooling"]) > float(before["cooling"]), "the shown cooling rises with the radiator")
	check(fe.stats_label.text.contains("cooling %.1f/s" % float(after["cooling"])), "the readout shows the raised cooling")
	near(float(MechCatalog.loadout_stats(chassis, fe._loadout())["cooling"]), float(MechCatalog.chassis(chassis)["cooling"]),
		0.001, "(the catalog's loadout_stats leaves cooling at the chassis value)")
