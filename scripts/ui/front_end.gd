class_name FrontEnd
extends Control
## The menus (scenes/menu.tscn): a panel of screens on the left, the 3D mech preview (MechStage) on the right. Built in
## code, like Bridge to Friendship's screens. Screens:
##   main      Play / Host, Join, Settings, Lab, Quit; the pilot's name and head.
##   settings  name, head (live in the preview), video, audio, the simulated link. Every change is saved at once.
##   hangar    the pre-mission placeholder: the crew (name, head, chassis of every player, from the roster), chassis and
##             loadout (hardpoints, weapons with weight / passive heat / active heat), Invite, Launch (stub), Leave.
##   busy      opening / joining a crew, with Cancel.
## Play / Host: a Steam lobby (alone it is solo); without Steam an ENet crew on DEFAULT_PORT (dev: a second window's Join
## finds it). Join: the first open Steam lobby for this game and build; without Steam, ENet on 127.0.0.1.

const LAB_SCENE := "res://scenes/lab.tscn"
const LAUNCH_ALERT_TIME := 2.5   ## seconds of bay alert between Launch and the mission loading

var screen := ""
var settings: Dictionary = {}
var stage: MechStage
var panel_box: VBoxContainer
var footer: VBoxContainer       ## pinned below panel_box's scroll (the screen's main actions)
var status_label: Label
var note := ""        ## why Play went the way it did ("Steam not running: ...")
var launching := false   ## Launch pressed: the bay is in alert, the mission loads after LAUNCH_ALERT_TIME

# Buttons and fields tests drive (the current screen's; null on other screens).
var btn_play: Button
var btn_join: Button
var btn_settings: Button
var btn_lab: Button
var btn_quit: Button
var btn_back: Button
var btn_leave: Button
var btn_launch: Button
var name_edit: LineEdit
var head_pick: OptionButton
var accent_picks: Dictionary = {}   ## accent id -> Button (the swatches in Settings)
var chassis_pick: OptionButton
var weapon_picks: Dictionary = {}   ## hardpoint id -> OptionButton
var crew_list: VBoxContainer
var stats_label: Label

var _shot_path := ""
var _shot_after := 1.5
var _crew_shot_size := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	settings = GameSettings.load_settings()
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(row)
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.14, 0.97)
	sb.border_color = Color(0.9, 0.48, 0.12)
	sb.border_width_right = 3
	left.add_theme_stylebox_override("panel", sb)
	row.add_child(left)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	left.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	panel_box = VBoxContainer.new()
	panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_box.add_theme_constant_override("separation", 10)
	scroll.add_child(panel_box)
	# The screen's main actions, pinned under the scrolling part so they are always on screen (the hangar's Launch /
	# Settings / Leave crew when the crew list and notes make the panel taller than the window).
	footer = VBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", 10)
	col.add_child(footer)
	stage = MechStage.new()
	row.add_child(stage)
	status_label = Label.new()
	status_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	status_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	status_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	status_label.offset_right = -16
	status_label.offset_bottom = -10
	status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	add_child(status_label)
	add_child(BuildVersion.make_label())
	Session.status_changed.connect(_on_status)
	Session.session_started.connect(_on_session_started)
	Session.session_ended.connect(_on_session_ended)
	Session.roster_changed.connect(_on_roster_changed)
	Session.invite_received.connect(_on_invite)
	Session.mission_started.connect(_on_mission_started)
	var args := OS.get_cmdline_user_args()
	_shot_path = Boot.arg_value(args, "--menu-shot")
	if Boot.arg_value(args, "--menu-after").is_valid_float():
		_shot_after = float(Boot.arg_value(args, "--menu-after"))
	if Boot.arg_value(args, "--crew-shot") != "":
		_shot_path = Boot.arg_value(args, "--crew-shot")
		_crew_shot_size = maxi(int(Boot.arg_value(args, "--crew-size")), 1)
	var first := Boot.arg_value(args, "--menu-screen")
	if Session.online():
		first = "hangar"
	elif Session.busy():
		first = "busy"
	show_screen(first if first in ["main", "settings", "hangar", "busy"] else "main")
	if _shot_path != "":
		_take_shot.call_deferred()
	var audio := _audio()
	if audio != null and audio.music != null and DisplayServer.get_name() != "headless":
		audio.music.set_ambience("hangar")
		audio.music.set_mode("hangar")


func _exit_tree() -> void:
	var audio := _audio()
	if audio != null and audio.music != null:
		if audio.music.ambience_mode == "hangar":
			audio.music.set_ambience("off")
		if audio.music.music_mode == "hangar":
			audio.music.set_mode("off")


func show_screen(s: String) -> void:
	screen = s
	for box: Container in [panel_box, footer]:
		for c in box.get_children():
			box.remove_child(c)
			c.queue_free()
	btn_play = null
	btn_join = null
	btn_settings = null
	btn_lab = null
	btn_quit = null
	btn_back = null
	btn_leave = null
	btn_launch = null
	name_edit = null
	head_pick = null
	accent_picks.clear()
	chassis_pick = null
	weapon_picks.clear()
	crew_list = null
	stats_label = null
	match s:
		"settings": _build_settings()
		"hangar": _build_hangar()
		"busy": _build_busy()
		_: _build_main()
	_refresh_stage()


# --- Screens ----------------------------------------------------------------------------------------

func _build_main() -> void:
	_title("BABAMECH", 56)
	_text("Co-op mech combat in a ring habitat.", 16, Color(0.7, 0.72, 0.75))
	_gap(18)
	btn_play = _button("Play / Host", _on_play)
	btn_join = _button("Join", _on_join)
	_button("Test drive", func() -> void: get_tree().change_scene_to_file(TestDrive.SCENE))
	btn_settings = _button("Settings", func() -> void: show_screen("settings"))
	btn_lab = _button("Lab", _on_lab)
	btn_quit = _button("Quit", func() -> void: get_tree().quit())
	_gap(18)
	_text("Pilot: %s   Head: %s" % [Session.display_name("Pilot"), MechCatalog.head_name(Session.local_head())], 16)
	_text("Steam: %s" % ("online" if Session.steam_available() else "not running (Play hosts over LAN, Join looks on this PC)"),
		13, Color(0.6, 0.62, 0.65))
	if Session.last_reason != "":
		_text(Session.last_reason, 15, Color(1.0, 0.6, 0.4))


func _build_settings() -> void:
	_title("Settings", 40)
	_section("Pilot")
	name_edit = LineEdit.new()
	# Empty field: show the name the crew actually sees (a run-only --net-name, the Steam persona, else "Pilot").
	name_edit.placeholder_text = Session.display_name("Steam name" if Session.steam_available() else "Pilot")
	name_edit.text = str(settings["player_name"])
	name_edit.max_length = 24
	name_edit.text_changed.connect(func(t: String) -> void: _set_profile("player_name", t.strip_edges()))
	_row("Name", name_edit)
	head_pick = _option(MechCatalog.HEAD_ORDER.map(func(h: String) -> String: return MechCatalog.head_name(h)),
		MechCatalog.HEAD_ORDER.find(Session.local_head()),
		func(i: int) -> void: _set_profile("head", MechCatalog.HEAD_ORDER[i]))
	_row("Head", head_pick)
	_row("Accent", _accent_swatches())
	_section("Video")
	_row("Fullscreen", _check(bool(settings["fullscreen"]), func(on: bool) -> void: _set_setting("fullscreen", on)))
	_row("VSync", _check(bool(settings["vsync"]), func(on: bool) -> void: _set_setting("vsync", on)))
	_row("Anti-aliasing", _option(["Off", "MSAA 2x", "MSAA 4x"], int(settings["msaa"]), func(i: int) -> void: _set_setting("msaa", i)))
	_section("Audio")
	for k in [["master", "Master"], ["music", "Music"], ["sfx", "Effects"]]:
		var key: String = k[0]
		_row(k[1], _slider(float(settings[key]), func(v: float) -> void: _set_setting(key, v)))
	_section("Network")
	var presets := ["off", "coast", "rough"]
	_row("Simulate a long link", _option(["Off", "Coast to coast", "Rough evening"], presets.find(str(settings["link_sim"])),
		func(i: int) -> void:
			_set_setting("link_sim", presets[i])
			if Session.online() and Session.hosting:
				Session.set_link(presets[i])))
	_text("Applies to crews you host.", 13, Color(0.6, 0.62, 0.65))
	_gap(12)
	btn_back = _button("Back", func() -> void: show_screen("hangar" if Session.online() else "main"))


func _build_hangar() -> void:
	_title("Hangar", 40)
	_text("Pre-mission: pick your mech and loadout.", 15, Color(0.7, 0.72, 0.75))
	_section("Crew")
	crew_list = VBoxContainer.new()
	panel_box.add_child(crew_list)
	_fill_crew()
	_section("Mech")
	chassis_pick = _option(MechCatalog.CHASSIS_ORDER.map(func(c: String) -> String: return str(MechCatalog.chassis(c)["name"])),
		MechCatalog.CHASSIS_ORDER.find(str(settings["chassis"])),
		func(i: int) -> void:
			_set_profile("chassis", MechCatalog.CHASSIS_ORDER[i])
			show_screen("hangar"))
	_row("Chassis", chassis_pick)
	_text(str(MechCatalog.chassis(str(settings["chassis"]))["blurb"]), 13, Color(0.6, 0.62, 0.65))
	_section("Loadout")
	var loadout := _loadout()
	for hp: Dictionary in MechCatalog.chassis(str(settings["chassis"]))["hardpoints"]:
		var ids: Array = [""]
		ids.append_array(MechCatalog.weapons_for(str(hp["mount"])))
		var labels: Array = ids.map(func(w: String) -> String: return "(empty)" if w == "" else _weapon_label(w))
		var hp_id := str(hp["id"])
		var pick := _option(labels, ids.find(str(loadout.get(hp_id, ""))), func(i: int) -> void:
			var l := _loadout()
			var chosen := str(ids[i])
			l[hp_id] = chosen
			_set_setting("loadout", l)
			_push_profile()
			_update_stats()
			_refresh_stage()
			_play_mount_sfx(chosen))
		weapon_picks[hp_id] = pick
		_row(str(hp["label"]), pick)
	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 14)
	panel_box.add_child(stats_label)
	_update_stats()
	if note != "":
		_text(note, 13, Color(1.0, 0.75, 0.4))
	var client := Session.online() and not Session.hosting
	btn_launch = _button("Waiting for the host to launch" if client else "Launch mission", _on_launch, footer)
	btn_launch.disabled = client
	if Session.can_invite():
		_button("Invite crew (Steam)", func() -> void: Session.invite_crew(), footer)
	_button("Settings", func() -> void: show_screen("settings"), footer)
	btn_leave = _button("Leave crew" if Session.online() else "Back", _on_leave, footer)


func _build_busy() -> void:
	_title("Crew", 40)
	_text("Working on it...", 18)
	_button("Cancel", func() -> void:
		Session.leave()
		show_screen("main"))


# --- Actions ----------------------------------------------------------------------------------------

func _on_play() -> void:
	note = ""
	if Session.steam_available():
		Session.host_steam()
	else:
		note = "Steam not running: hosting over LAN on port %d." % NetSession.DEFAULT_PORT
		if not Session.host_enet(NetSession.DEFAULT_PORT):
			note = "Steam not running and port %d is taken: solo, offline." % NetSession.DEFAULT_PORT
			show_screen("hangar")
			return
	if Session.busy():
		show_screen("busy")


func _on_join() -> void:
	note = ""
	if Session.steam_available():
		Session.join_first()
	else:
		note = "Steam not running: joined over LAN (127.0.0.1)."
		Session.join_enet("127.0.0.1", NetSession.DEFAULT_PORT)
	if Session.busy():
		show_screen("busy")


func _on_lab() -> void:
	get_tree().change_scene_to_file(LAB_SCENE)


## Launch. In a crew only the host's counts: Session.start_mission sends the seed to the crew and every machine (this one
## too) hears mission_started, plays the bay alert and loads the mission at the same moment on the shared clock. Solo
## (offline) this machine just plays the alert and loads the test drive. No mission yet: the test drive is it.
func _on_launch() -> void:
	if launching:
		return
	if Session.online():
		if Session.hosting:
			Session.start_mission(_mission_seed())
		return
	_play_launch(LAUNCH_ALERT_TIME)


## The mission seed: --seed for this run, else 1 (the test drive's own default).
static func _mission_seed() -> int:
	var s := Boot.arg_value(OS.get_cmdline_user_args(), "--seed")
	return int(s) if s.is_valid_int() else 1


func _on_mission_started(_params: Dictionary) -> void:
	_play_launch(Session.mission.seconds_to_load())


## The bay goes to launch alert (docs/design/hangar.md), then the mission loads after `delay` seconds.
func _play_launch(delay: float) -> void:
	if launching:
		return
	launching = true
	if btn_launch == null or not is_instance_valid(btn_launch):
		show_screen("hangar")
	btn_launch.disabled = true
	btn_launch.text = "Launching..."
	stage.set_alert(true)
	var audio := _audio()
	if audio != null:
		audio.play_2d("ui.hangar.alert", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)
	await get_tree().create_timer(maxf(delay, 0.0)).timeout
	if is_inside_tree() and launching:
		get_tree().change_scene_to_file(TestDrive.SCENE)


func _on_leave() -> void:
	if Session.online():
		Session.leave()
	show_screen("main")


func _on_session_started(_as_host: bool) -> void:
	show_screen("hangar")


func _on_session_ended(_reason: String) -> void:
	if launching:
		launching = false
		stage.set_alert(false)
		show_screen("main")
		return
	if screen == "hangar" or screen == "busy":
		show_screen("main")


func _on_roster_changed() -> void:
	if screen == "hangar" and crew_list != null:
		_fill_crew()
	_refresh_stage()


func _on_invite(_lobby_id: int, _inviter: String) -> void:
	Session.accept_invite()
	show_screen("busy")


func _on_status(text: String) -> void:
	status_label.text = text


## Name / head / accent / chassis: saved, and the session (and so the crew) hears about it.
func _set_profile(key: String, value: Variant) -> void:
	_set_setting(key, value)
	# The session's name is the saved one unless a run-only name (--net-name) replaced it: keep that one. Same for a
	# run-only accent (--accent): the session keeps it until the player picks one here.
	var name_ := str(settings["player_name"]) if key == "player_name" else Session.player_name
	var accent := str(settings["accent"]) if key == "accent" else Session.local_accent()
	Session.set_profile(name_, str(settings["head"]), str(settings["chassis"]), accent, _loadout())
	_refresh_stage()
	_mark_accent()


## The accent swatches: one square button per MechAccent colour, the picked one outlined in white.
func _accent_swatches() -> Control:
	accent_picks.clear()
	var box := HFlowContainer.new()
	box.add_theme_constant_override("h_separation", 6)
	box.add_theme_constant_override("v_separation", 6)
	for id: String in MechAccent.ORDER:
		var b := Button.new()
		b.name = "Accent_" + id
		b.tooltip_text = MechAccent.display_name(id)
		b.custom_minimum_size = Vector2(30, 30)
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(func() -> void:
			_play_ui("ui.click")
			_set_profile("accent", id))
		box.add_child(b)
		accent_picks[id] = b
	_mark_accent()
	return box


func _mark_accent() -> void:
	var current := Session.local_accent()
	for id: String in accent_picks:
		var b: Button = accent_picks[id]
		if not is_instance_valid(b):
			continue
		var on := id == current
		for st: String in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = MechAccent.color(id).lightened(0.12 if st == "hover" else 0.0)
			sb.set_corner_radius_all(4)
			sb.set_border_width_all(3 if on else (1 if st == "hover" or st == "focus" else 0))
			sb.border_color = Color.WHITE if on else Color(1, 1, 1, 0.5)
			b.add_theme_stylebox_override(st, sb)


## The loadout changed: the session (and so the crew) hears about it, with the rest of the profile unchanged.
func _push_profile() -> void:
	Session.set_profile(Session.player_name, Session.local_head(), str(settings["chassis"]), Session.local_accent(), _loadout())


func _set_setting(key: String, value: Variant) -> void:
	settings = GameSettings.set_value(key, value)
	if key in ["fullscreen", "vsync", "msaa", "master", "music", "sfx"]:
		GameSettings.apply(settings)


func _loadout() -> Dictionary:
	return MechCatalog.sanitize_loadout(str(settings["chassis"]), settings["loadout"] as Dictionary)


func _weapon_label(w: String) -> String:
	var d := MechCatalog.weapon(w)
	return "%s  (%.0ft, %.1f heat/s, %.0f per shot)" % [d["name"], d["weight"], d["passive_heat"], d["active_heat"]]


func _update_stats() -> void:
	if stats_label == null:
		return
	var st := MechCatalog.loadout_stats(str(settings["chassis"]), _loadout())
	stats_label.text = "Weapons %d   Weight %.0f / %.0f t%s\nPassive heat %.1f/s vs cooling %.1f/s (net %+.1f)\nHottest shot %.0f of %.0f heat capacity" % [
		st["weapons"], st["weight"], st["max_weight"], "  OVERWEIGHT" if st["overweight"] else "",
		st["passive_heat"], st["cooling"], st["net_cooling"], st["peak_heat"], st["heat_cap"]]


func _fill_crew() -> void:
	for c in crew_list.get_children():
		crew_list.remove_child(c)
		c.queue_free()
	var entries := _crew_entries()
	for e: Dictionary in entries:
		var l := Label.new()
		l.text = "%d  %s   %s head, %s%s" % [int(e["seat"]), str(e["name"]), MechCatalog.head_name(str(e["head"])),
			str(MechCatalog.chassis(str(e["chassis"]))["name"]), "   (you)" if bool(e.get("you", false)) else ""]
		l.add_theme_font_size_override("font_size", 16)
		crew_list.add_child(l)
	if Session.online():
		var free := NetSession.MAX_CREW - entries.size()
		if free > 0:
			_text_into(crew_list, "%d seat%s open" % [free, "" if free == 1 else "s"], 13, Color(0.6, 0.62, 0.65))


## The crew as the hangar shows it: the roster online, else just this player.
func _crew_entries() -> Array:
	if not Session.online():
		return [{"seat": 1, "name": Session.display_name("Pilot"), "head": Session.local_head(), "chassis": Session.local_chassis(),
			"accent": Session.local_accent(), "you": true}]
	var out: Array = []
	for e: Dictionary in Session.crew():
		var d := e.duplicate()
		d["you"] = int(e["peer"]) == Session.local_id()
		out.append(d)
	return out


func _refresh_stage() -> void:
	if stage == null:
		return
	if screen == "hangar":
		var mechs: Array = []
		for e: Dictionary in _crew_entries():
			mechs.append({"head": e["head"], "chassis": e["chassis"], "name": e["name"], "accent": e.get("accent", MechAccent.DEFAULT),
				"loadout": _loadout() if bool(e.get("you", false)) else {}})
		stage.show_mechs(mechs, true)
	else:
		stage.show_mechs([{"head": Session.local_head(), "chassis": Session.local_chassis(), "loadout": _loadout(), "name": "",
			"accent": Session.local_accent()}])


func _take_shot() -> void:
	if _crew_shot_size > 0:
		while Session.roster.size() < _crew_shot_size:
			await get_tree().create_timer(0.25).timeout
	await get_tree().create_timer(_shot_after).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	print("shot %s %s" % [_shot_path, "ok" if err == OK else "error %d" % err])
	if _crew_shot_size > 1:
		# Stay in the crew a moment so the other windows still see this pilot when they take their own shot.
		await get_tree().create_timer(4.0).timeout
	get_tree().quit()


# --- Widgets ----------------------------------------------------------------------------------------

func _title(t: String, size_: int) -> void:
	var l := _text(t, size_)
	l.add_theme_color_override("font_color", Color(0.95, 0.6, 0.2))


func _text(t: String, size_: int, col: Color = Color(0.9, 0.9, 0.88)) -> Label:
	return _text_into(panel_box, t, size_, col)


func _text_into(box: Container, t: String, size_: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size_)
	l.add_theme_color_override("font_color", col)
	box.add_child(l)
	return l


func _section(t: String) -> void:
	_gap(6)
	_text(t.to_upper(), 14, Color(0.9, 0.48, 0.12))


func _gap(h: int) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	panel_box.add_child(c)


func _button(t: String, cb: Callable, box: Container = null) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(0, 48)
	b.add_theme_font_size_override("font_size", 20)
	var is_back := t in ["Back", "Cancel", "Leave crew", "Quit"]
	b.mouse_entered.connect(func() -> void: _play_ui("ui.hover"))
	b.pressed.connect(func() -> void:
		_play_ui("ui.back" if is_back else "ui.click")
		cb.call())
	(box if box != null else panel_box).add_child(b)
	return b


func _row(label: String, w: Control) -> void:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(170, 0)
	h.add_child(l)
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(w)
	panel_box.add_child(h)


func _option(labels: Array, selected: int, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	for t: Variant in labels:
		o.add_item(str(t))
	o.select(maxi(selected, 0))
	o.mouse_entered.connect(func() -> void: _play_ui("ui.hover"))
	o.item_selected.connect(func(i: int) -> void:
		_play_ui("ui.click")
		cb.call(i))
	return o


func _check(on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.button_pressed = on
	# The default theme's unchecked box is near-black on the dark panel: draw our own, outlined when off, orange when on.
	for k: String in ["unchecked", "unchecked_disabled"]:
		c.add_theme_icon_override(k, _box_icon(false))
	for k: String in ["checked", "checked_disabled"]:
		c.add_theme_icon_override(k, _box_icon(true))
	c.mouse_entered.connect(func() -> void: _play_ui("ui.hover"))
	c.toggled.connect(func(v: bool) -> void:
		_play_ui("ui.click" if v else "ui.back")
		cb.call(v))
	return c


static var _box_icons: Dictionary = {}


## A 20 px checkbox icon: a light outline (off), or an orange box with a white tick (on). Cached.
static func _box_icon(on: bool) -> Texture2D:
	if _box_icons.has(on):
		return _box_icons[on]
	var n := 20
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var edge := Color(0.95, 0.6, 0.2) if on else Color(0.78, 0.8, 0.84)
	for i in n:
		for j in n:
			var border := i < 2 or j < 2 or i >= n - 2 or j >= n - 2
			if border:
				img.set_pixel(i, j, edge)
			elif on:
				img.set_pixel(i, j, Color(0.9, 0.48, 0.12))
	if on:   # the tick: a short stroke down-right, then a long one up-right
		for t in 12:
			var p := Vector2(5, 10).lerp(Vector2(8, 14), t / 5.0) if t < 6 else Vector2(8, 14).lerp(Vector2(15, 5), (t - 6) / 5.0)
			for d: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
				img.set_pixelv(Vector2i(p) + d, Color.WHITE)
	_box_icons[on] = ImageTexture.create_from_image(img)
	return _box_icons[on]


func _slider(v: float, cb: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = v
	s.value_changed.connect(func(val: float) -> void:
		_play_ui("ui.slider", 0.9 + val * 0.25)
		cb.call(val))
	return s


func _play_ui(cue_id: String, pitch: float = 1.0) -> void:
	var a := _audio()
	if a != null:
		a.play_ui(cue_id, pitch)


func _play_mount_sfx(weapon_id: String) -> void:
	var a := _audio()
	if a == null:
		return
	if weapon_id == "":
		a.play_ui("ui.hangar.unmount")
		return
	var w := float(MechCatalog.weapon(weapon_id).get("weight", 6.0))
	# Heavier weapons bolt on with a beefier, lower clunk.
	a.play_ui("ui.hangar.mount", clampf(1.12 - w * 0.025, 0.72, 1.12))


func _audio() -> AudioDirector:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Audio") as AudioDirector
