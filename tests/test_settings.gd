extends TestCase
## Settings persist: defaults from a missing file, every key round-trips through the file, bad values fall back, and the
## settings screen saves what the player changes (name, head) and hands it to the session (the join handshake's profile).

const PATH := "user://test_settings.cfg"


func setup() -> void:
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	var d := GameSettings.load_settings()
	eq(d, GameSettings.DEFAULTS, "a missing file gives the defaults")

	d["player_name"] = "Clucky"
	d["head"] = "corn"
	d["fullscreen"] = true
	d["msaa"] = 2
	d["sfx"] = 0.25
	d["link_sim"] = "coast"
	d["loadout"] = {"side_l": "flamer"}
	check(GameSettings.save_settings(d), "saves")
	var back := GameSettings.load_settings()
	for k: String in ["player_name", "head", "fullscreen", "msaa", "link_sim", "loadout"]:
		eq(back[k], d[k], "%s round-trips" % k)
	near(float(back["sfx"]), 0.25, 0.0001, "sfx round-trips")

	GameSettings.set_value("head", "toaster")
	eq(str(GameSettings.load_settings()["head"]), "chicken", "an unknown head falls back to chicken")
	# Accent colour: defaults to the livery's safety orange, persists, unknown ids fall back.
	eq(str(GameSettings.DEFAULTS["accent"]), "orange", "the default accent is orange")
	check(MechAccent.color("orange").is_equal_approx(MechMeshes.ORANGE), "the default accent is exactly the baked orange")
	GameSettings.set_value("accent", "green")
	eq(str(GameSettings.load_settings()["accent"]), "green", "the accent round-trips")
	GameSettings.set_value("accent", "plaid")
	eq(str(GameSettings.load_settings()["accent"]), "orange", "an unknown accent falls back to orange")

	# The settings screen.
	GameSettings.save_settings(GameSettings.DEFAULTS.duplicate(true))
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(2)
	fe.btn_settings.pressed.emit()
	await frames(1)
	eq(fe.screen, "settings", "Settings opens the settings screen")
	fe.name_edit.text_changed.emit("Pickle Rick")
	fe.head_pick.select(1)
	fe.head_pick.item_selected.emit(1)
	await frames(1)
	var saved := GameSettings.load_settings()
	eq(str(saved["player_name"]), "Pickle Rick", "the name is saved as it is typed")
	eq(str(saved["head"]), "pickle", "the head is saved when picked")
	eq(Session.player_name, "Pickle Rick", "the session carries the new name")
	eq(Session.local_head(), "pickle", "the session carries the new head")
	var stage_head := fe.stage.models[0].head_id if fe.stage.models.size() > 0 else ""
	eq(stage_head, "pickle", "the preview shows the new head")
	# Accent swatches: one per colour, the default marked; picking one saves it, the session carries it, the preview
	# mech's orange faces turn that colour; picking orange again puts the baked look back.
	eq(fe.accent_picks.size(), MechAccent.ORDER.size(), "a swatch per accent colour")
	eq(Session.local_accent(), "orange", "the session starts with the default accent")
	eq(MechAccent.applied(fe.stage.models[0]), "orange", "the preview starts in orange")
	(fe.accent_picks["blue"] as Button).pressed.emit()
	await frames(1)
	eq(str(GameSettings.load_settings()["accent"]), "blue", "the accent is saved when picked")
	eq(Session.local_accent(), "blue", "the session carries the new accent")
	eq(MechAccent.applied(fe.stage.models[0]), "blue", "the preview mech shows the new accent")
	(fe.accent_picks["orange"] as Button).pressed.emit()
	await frames(1)
	eq(MechAccent.applied(fe.stage.models[0]), "orange", "orange again: the baked colours are back")
	fe.btn_back.pressed.emit()
	await frames(1)
	eq(fe.screen, "main", "Back returns to the main menu")
	fe.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()
