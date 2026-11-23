extends TestCase
## Settings persist: defaults from a missing file, every key round-trips through the file, bad values fall back, and the
## settings screen saves what the player changes (name, head) and hands it to the session (the join handshake's profile).

const PATH := "user://test_settings.cfg"


func setup() -> void:
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	var d := GameSettings.load_settings()
	var want := GameSettings.DEFAULTS.duplicate(true)
	want["quality"] = GraphicsQuality.detect()   # never chosen: auto-detected (LOW on an integrated GPU, else HIGH)
	eq(d, want, "a missing file gives the defaults (quality auto-detected)")
	eq(int(GameSettings.DEFAULTS["quality"]), -1, "the quality default is 'never chosen'")
	check(int(d["quality"]) in [CityQuality.LOW, CityQuality.HIGH], "auto-detect picks LOW or HIGH")

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

	# Graphics quality: persists, broken values fall back to the auto-detected level, the --quality flag beats it.
	GameSettings.set_value("quality", CityQuality.MEDIUM)
	eq(int(GameSettings.load_settings()["quality"]), CityQuality.MEDIUM, "quality round-trips")
	GameSettings.set_value("quality", CityQuality.LOW)
	eq(int(GameSettings.load_settings()["quality"]), CityQuality.LOW, "quality LOW round-trips")
	for bad: Variant in [7, -3, "high", 1.5]:
		GameSettings.set_value("quality", bad)
		eq(int(GameSettings.load_settings()["quality"]), GraphicsQuality.detect(), "quality %s falls back to auto" % str(bad))
	GameSettings.set_value("quality", CityQuality.LOW)
	GraphicsQuality.use_settings(GameSettings.load_settings())
	eq(GraphicsQuality.level(), CityQuality.LOW, "level() follows the setting")
	eq(Boot.quality_flag(PackedStringArray(["--quality", "high"])), CityQuality.HIGH, "--quality high")
	eq(Boot.quality_flag(PackedStringArray(["--quality", "Medium"])), CityQuality.MEDIUM, "--quality Medium")
	eq(Boot.quality_flag(PackedStringArray(["--quality", "ultra"])), -1, "an unknown --quality is ignored")
	eq(Boot.quality_flag(PackedStringArray([])), -1, "no --quality flag")
	GraphicsQuality.override_level = Boot.quality_flag(PackedStringArray(["--quality", "high"]))
	eq(GraphicsQuality.level(), CityQuality.HIGH, "the flag overrides the saved LOW")
	eq(int(GameSettings.load_settings()["quality"]), CityQuality.LOW, "the flag is not saved")
	GraphicsQuality.override_level = -1
	eq(GraphicsQuality.level(), CityQuality.LOW, "without the flag the setting is back")
	# Renderer: auto by default, persists, unknown values fall back to auto.
	GameSettings.set_value("renderer", "gl_compatibility")
	eq(str(GameSettings.load_settings()["renderer"]), "gl_compatibility", "renderer round-trips")
	GameSettings.set_value("renderer", "vulkan9")
	eq(str(GameSettings.load_settings()["renderer"]), "auto", "an unknown renderer falls back to auto")

	GameSettings.set_value("head", "toaster")
	eq(str(GameSettings.load_settings()["head"]), "chicken", "an unknown head falls back to chicken")
	# Accent colour: defaults to the livery's safety orange, persists, unknown ids fall back.
	eq(str(GameSettings.DEFAULTS["accent"]), "orange", "the default accent is orange")
	check(MechAccent.color("orange").is_equal_approx(MechMeshes.ORANGE), "the default accent is exactly the baked orange")
	GameSettings.set_value("accent", "green")
	eq(str(GameSettings.load_settings()["accent"]), "green", "the accent round-trips")
	GameSettings.set_value("accent", "plaid")
	eq(str(GameSettings.load_settings()["accent"]), "orange", "an unknown accent falls back to orange")

	# Crew option friendly fire: on by default, persists.
	eq(GameSettings.DEFAULTS["friendly_fire"], true, "friendly fire defaults to on")
	eq(GameSettings.SECTIONS["friendly_fire"], "crew", "friendly fire lives in the crew section")
	GameSettings.set_value("friendly_fire", false)
	eq(GameSettings.load_settings()["friendly_fire"], false, "friendly fire off round-trips")
	GameSettings.set_value("friendly_fire", "maybe")
	eq(GameSettings.load_settings()["friendly_fire"], true, "a broken friendly fire value falls back to on")

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
	# The graphics rows: picking a level saves it and level() follows; the note names the GPU.
	check(fe.quality_pick != null and fe.renderer_pick != null, "the settings screen has quality and renderer rows")
	fe.quality_pick.select(CityQuality.MEDIUM)
	fe.quality_pick.item_selected.emit(CityQuality.MEDIUM)
	await frames(1)
	eq(int(GameSettings.load_settings()["quality"]), CityQuality.MEDIUM, "the quality is saved when picked")
	eq(GraphicsQuality.level(), CityQuality.MEDIUM, "level() follows the picked quality")
	check(fe.quality_note.text.contains("GPU:"), "the note shows the detected GPU (%s)" % fe.quality_note.text)
	fe.renderer_pick.select(2)
	fe.renderer_pick.item_selected.emit(2)
	await frames(1)
	eq(str(GameSettings.load_settings()["renderer"]), "gl_compatibility", "the renderer is saved when picked")
	check(not fe.btn_restart.visible, "no Restart now in a dev run (override.cfg is for exported builds)")
	fe.btn_back.pressed.emit()
	await frames(1)
	eq(fe.screen, "main", "Back returns to the main menu")
	# The hangar's friendly fire box (solo): on from the settings, editable; unticking saves it and sets the session's
	# option, and the solo launch carries it.
	fe.show_screen("hangar")
	await frames(1)
	check(fe.ff_check != null and fe.ff_check.button_pressed and not fe.ff_check.disabled, "solo: friendly fire on, editable")
	fe.ff_check.button_pressed = false
	await frames(1)
	eq(GameSettings.load_settings()["friendly_fire"], false, "unticking friendly fire saves it")
	eq(Session.friendly_fire, false, "and sets the session's crew option")
	eq(fe.ff_check.text, "Off", "the box says Off")
	fe.ff_check.button_pressed = true
	await frames(1)
	eq(GameSettings.load_settings()["friendly_fire"], true, "ticking it again saves it")
	eq(Session.friendly_fire, true, "and the session follows")
	fe.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()
