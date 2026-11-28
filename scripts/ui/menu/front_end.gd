class_name FrontEnd
extends Control
## The menus (scenes/menu.tscn): a panel of screens on the left, the 3D mech preview (MechStage) on the right. Built in
## code, like Bridge to Friendship's screens. Screens:
##   main      Play / Host, Join, Settings, Lab, Quit; the pilot's name and head.
##   settings  name, head (live in the preview), video (display mode, window resolution, ...), audio, the simulated
##             link. Every change is saved at once and applied live.
##   hangar    the pre-mission placeholder: the crew (name, head, chassis of every player, from the roster), chassis and
##             loadout (hardpoints, weapons with weight / passive heat / active heat), Invite, Launch (stub), Leave.
##   debrief   (playtest R2.15a) back from a mission with a debrief (NetMission.last_debrief, the host's numbers): the
##             hangar with the debrief board over the bay (DebriefBoard: pilots across the top, a stat per row); Next goes
##             to the loadout (the hangar screen) for the next mission. `--menu-screen debrief` shows a stub board.
##   busy      opening / joining a crew, with Cancel.
## Play / Host: a Steam lobby (alone it is solo); without Steam an ENet crew on DEFAULT_PORT (dev: a second window's Join
## finds it). Join: the first open Steam lobby for this game and build; without Steam, ENet on 127.0.0.1.
## Type (playtest R2.16): the panel's base text is FONT (18 px on the 1600x900 canvas, so about 22 px at 1080p and 29 at
## 1440p under canvas_items stretch), notes NOTE_FONT, section heads SECTION_FONT; nothing smaller than NOTE_FONT.

const LAB_SCENE := "res://scenes/lab.tscn"
const LAUNCH_ALERT_TIME := 2.5   ## seconds of bay alert between Launch and the mission loading
const PANEL_W := 560.0           ## the menu panel's width (the bay preview takes the rest)
const FONT := 18                 ## the panel's base text: rows, pickers, crew lines
const NOTE_FONT := 15            ## notes and hints (the smallest text in the menu)
const SECTION_FONT := 16         ## section heads (CREW, MECH, LOADOUT, ...)
const ROW_LABEL_W := 190.0       ## the label column of a settings / loadout row
const ROW_H := 40.0              ## the height of a picker row

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
var quality_pick: OptionButton       ## Settings: graphics quality Low / Medium / High (GraphicsQuality)
var renderer_pick: OptionButton      ## Settings: renderer Auto / Forward+ / Compatibility (next launch)
var quality_note: Label              ## Settings: the detected GPU and the renderer note
var btn_restart: Button              ## Settings: restart now (only while a renderer change is pending, exported builds)
var accent_picks: Dictionary = {}   ## accent id -> Button (the swatches in Settings)
var chassis_pick: OptionButton
var weapon_picks: Dictionary = {}   ## hardpoint id -> OptionButton
var crew_list: VBoxContainer
## Hangar, host online (docs/design/hangar-bots.md): seat an AI pilot, its skill (crew-wide), remove one (bot id -> Button).
var btn_add_bot: Button
var bot_skill_pick: OptionButton
var bot_remove: Dictionary = {}
var ff_check: CheckBox               ## Hangar: the crew's friendly fire (host / solo edit it; a client sees the host's)
var stats_label: Label
var display_pick: OptionButton       ## Settings: Windowed / Fullscreen (GameSettings "fullscreen")
var resolution_pick: OptionButton    ## Settings: the window size (GameSettings "resolution"; item 0 = the default window)
var resolution_ids: Array = []       ## per resolution_pick item: the saved "WxH" string ("" = default)
## Debrief (R2.15a): the board over the bay, its layer, and Next (to the loadout). Null on other screens.
var debrief_layer: Control
var debrief_board: DebriefBoard
var btn_next: Button
## A Steam invite waiting for an answer (Session.pending_invite): a modal over the whole menu naming the inviter, with
## Accept (leave whatever this is and join) and Decline. Null when none is shown.
var invite_prompt: Control
var invite_label: Label
var btn_invite_accept: Button
var btn_invite_decline: Button

var _shot_path := ""
var _shot_after := 1.5
var _crew_shot_size := 0
## The hangar's bot skill picker (rookie / average / veteran / brawler). One switch: false hides it (bots then play the
## default skill) if the profiles turn out not to differ in missions.
const SHOW_BOT_SKILL := true


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
	left.custom_minimum_size = Vector2(PANEL_W, 0)
	var type := Theme.new()   # the panel's base text size (R2.16): every row, picker and checkbox without its own
	type.default_font_size = FONT
	left.theme = type
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
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	panel_box = VBoxContainer.new()
	panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_box.add_theme_constant_override("separation", 12)
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
	Session.crew_opts_changed.connect(_on_crew_opts)
	if not Session.is_client():
		Session.set_friendly_fire(bool(settings["friendly_fire"]))   # the crew this machine hosts (or solo) uses its choice
	CrewAuto.ensure(get_tree())   # --auto-launch / --auto-relaunch / --auto-quit, and the clients' hangar heartbeat
	var args := OS.get_cmdline_user_args()
	_shot_path = Boot.arg_value(args, "--menu-shot")
	if Boot.arg_value(args, "--menu-after").is_valid_float():
		_shot_after = float(Boot.arg_value(args, "--menu-after"))
	if Boot.arg_value(args, "--crew-shot") != "":
		_shot_path = Boot.arg_value(args, "--crew-shot")
		_crew_shot_size = maxi(int(Boot.arg_value(args, "--crew-size")), 1)
	var first := Boot.arg_value(args, "--menu-screen")
	if next_screen != "":   # a solo mission that ended asked to come back to the hangar
		first = next_screen
		next_screen = ""
	if Session.online():
		first = "hangar"
	elif Session.busy():
		first = "busy"
	# Back from a mission with a debrief (the host's, or solo's): the hangar opens on the board.
	if first == "hangar" and not NetMission.last_debrief.is_empty():
		first = "debrief"
	if first == "debrief" and NetMission.last_debrief.is_empty():
		NetMission.last_debrief = NetMission.clean_debrief(DebriefStats.stub(_crew_entries_for_stub()))   # --menu-screen debrief
	show_screen(first if first in ["main", "settings", "hangar", "debrief", "busy"] else "main")
	if LoadingScreen.handoff:   # back from a mission: its loading screen hands over to this one, which fades out
		LoadingScreen.handoff = false
		var cover := LoadingScreen.cover(self)
		cover.set_phase(LoadingScreen.handoff_phase)
		_uncover_later(cover)
	if not Session.pending_invite.is_empty():   # an invite that came while a mission ran: ask now
		show_invite_prompt(str(Session.pending_invite.get("inviter", "")))
	if _shot_path != "":
		_take_shot.call_deferred()
	var audio := AudioDirector.of(self)
	if audio != null and audio.music != null and DisplayServer.get_name() != "headless":
		audio.music.set_ambience("hangar")
		audio.music.set_mode("hangar")


func _exit_tree() -> void:
	var audio := AudioDirector.of(self)
	if audio != null and audio.music != null:
		if audio.music.ambience_mode == "hangar":
			audio.music.set_ambience("off")
		if audio.music.music_mode == "hangar":
			audio.music.set_mode("off")


func show_screen(s: String) -> void:
	if s == "hangar" and screen != "hangar":
		FlowLog.say("hangar entered", "crew %d" % Session.roster.size() if Session.online() else "solo")
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
	btn_add_bot = null
	bot_skill_pick = null
	bot_remove.clear()
	ff_check = null
	stats_label = null
	display_pick = null
	resolution_pick = null
	resolution_ids = []
	btn_next = null
	if s != "debrief":
		_close_debrief()
	match s:
		"settings": _build_settings()
		"hangar": _build_hangar()
		"debrief": _build_debrief()
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
	_button("Test drive", func() -> void: get_tree().change_scene_to_file(MissionScene.SCENE))
	btn_settings = _button("Settings", func() -> void: show_screen("settings"))
	btn_lab = _button("Lab", _on_lab)
	btn_quit = _button("Quit", func() -> void: get_tree().quit())
	_gap(18)
	_text("Pilot: %s   Head: %s" % [Session.display_name("Pilot"), MechCatalog.head_name(Session.local_head())], 16)
	_text("Steam: %s" % ("online" if Session.steam_available() else "not running (Play hosts over LAN, Join looks on this PC)"),
		NOTE_FONT, Color(0.6, 0.62, 0.65))
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
	display_pick = _option(["Windowed", "Fullscreen"], 1 if bool(settings["fullscreen"]) else 0, func(i: int) -> void:
		_set_setting("fullscreen", i == 1)
		_mark_resolution())
	_row("Display", display_pick)
	resolution_ids = [""]
	var res_labels: Array = ["Default window (%s)" % GameSettings.resolution_label(GameSettings.DEFAULT_WINDOW)]
	for r: Vector2i in GameSettings.resolution_list(GameSettings.screen_size()):
		resolution_ids.append(GameSettings.resolution_id(r))
		res_labels.append(GameSettings.resolution_label(r))
	resolution_pick = _option(res_labels, maxi(resolution_ids.find(str(settings["resolution"])), 0), func(i: int) -> void:
		_set_setting("resolution", str(resolution_ids[i])))
	_row("Resolution", resolution_pick)
	_mark_resolution()
	_row("VSync", _check(bool(settings["vsync"]), func(on: bool) -> void: _set_setting("vsync", on)))
	_row("Anti-aliasing", _option(["Off", "MSAA 2x", "MSAA 4x"], int(settings["msaa"]), func(i: int) -> void: _set_setting("msaa", i)))
	quality_pick = _option(["Low", "Medium", "High"], int(settings["quality"]), func(i: int) -> void:
		_set_setting("quality", i)
		GraphicsQuality.apply_settings(settings, get_tree())
		_update_graphics_note())
	_row("Graphics quality", quality_pick)
	var auto_label := "Auto (%s)" % GraphicsQuality.renderer_label(GraphicsQuality.renderer_wanted("auto"))
	renderer_pick = _option([auto_label, "Forward+", "Compatibility"],
		GraphicsQuality.RENDERERS.find(str(settings["renderer"])), func(i: int) -> void:
			_set_setting("renderer", GraphicsQuality.RENDERERS[i])
			_update_graphics_note())
	_row("Renderer", renderer_pick)
	quality_note = _text("", NOTE_FONT, Color(0.6, 0.62, 0.65))
	quality_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn_restart = _button("Restart now", func() -> void: GraphicsQuality.restart(get_tree()))
	_update_graphics_note()
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
	_text("Applies to crews you host.", NOTE_FONT, Color(0.6, 0.62, 0.65))
	_gap(12)
	btn_back = _button("Back", func() -> void: show_screen("hangar" if Session.online() else "main"))


## The settings note under the graphics rows: the GPU (and what auto picks for it), the renderer state; Restart now only
## while the next launch's renderer differs from this one's and this build can switch.
func _update_graphics_note() -> void:
	if quality_note == null or not is_instance_valid(quality_note):
		return
	var lines := ["GPU: %s. Auto: %s quality, %s." % [GraphicsQuality.adapter_note(), GraphicsQuality.name_of(GraphicsQuality.detect()).capitalize(),
		GraphicsQuality.renderer_label(GraphicsQuality.renderer_wanted("auto"))]]
	if GraphicsQuality.override_level >= 0:
		lines.append("This run: --quality %s." % GraphicsQuality.name_of(GraphicsQuality.override_level))
	var r := GraphicsQuality.sync_renderer(str(settings["renderer"]))
	lines.append("Renderer now: %s.%s" % [GraphicsQuality.renderer_label(GraphicsQuality.renderer_current()), (" " + r) if r != "" else ""])
	quality_note.text = "\n".join(lines)
	if btn_restart != null and is_instance_valid(btn_restart):
		btn_restart.visible = GraphicsQuality.can_switch_renderer() \
			and GraphicsQuality.renderer_wanted(str(settings["renderer"])) != GraphicsQuality.renderer_current()


func _build_hangar() -> void:
	_title("Hangar", 40)
	_text("Pre-mission: pick your mech and loadout.", 17, Color(0.7, 0.72, 0.75))
	_section("Crew")
	crew_list = VBoxContainer.new()
	panel_box.add_child(crew_list)
	_fill_crew()
	var client_ff := Session.online() and not Session.hosting
	ff_check = _check(Session.friendly_fire if client_ff else bool(settings["friendly_fire"]), func(v: bool) -> void:
		_set_setting("friendly_fire", v)
		Session.set_friendly_fire(v)
		_mark_friendly_fire())
	ff_check.name = "FriendlyFire"
	ff_check.disabled = client_ff
	ff_check.tooltip_text = "The host's choice for the whole crew." if client_ff else "Your shots can hurt your crew."
	_row("Friendly fire", ff_check)
	_mark_friendly_fire()
	_section("Mech")
	chassis_pick = _option(MechCatalog.CHASSIS_ORDER.map(func(c: String) -> String: return str(MechCatalog.chassis(c)["name"])),
		MechCatalog.CHASSIS_ORDER.find(str(settings["chassis"])),
		func(i: int) -> void:
			_set_chassis(str(MechCatalog.CHASSIS_ORDER[i]))
			show_screen("hangar"))
	_row("Chassis", chassis_pick)
	_text(str(MechCatalog.chassis(str(settings["chassis"]))["blurb"]), NOTE_FONT, Color(0.6, 0.62, 0.65))
	_section("Loadout")
	var loadout := _loadout()
	for hp: Dictionary in MechCatalog.chassis(str(settings["chassis"]))["hardpoints"]:
		var ids: Array = [""]
		# Every weapon then equipment item the hardpoint takes, over all its mount kinds (the Bulwark's side guns take side
		# and shoulder weapons; back-mount equipment: docs/design/back-equipment.md).
		ids.append_array(MechCatalog.items_for(hp))
		var hp_id := str(hp["id"])
		var key := MechCatalog.slot_key(str(settings["chassis"]), hp_id)   # its key in play (the Bulwark's back mounts: 3, 4)
		var labels: Array = ids.map(func(w: String) -> String: return "(empty)" if w == "" else _weapon_label(w, key))
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
	_gap(4)
	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 16)
	stats_label.add_theme_constant_override("line_spacing", 4)
	stats_label.add_theme_color_override("font_color", Color(0.82, 0.84, 0.86))
	panel_box.add_child(stats_label)
	_update_stats()
	if note != "":
		_text(note, NOTE_FONT, Color(1.0, 0.75, 0.4))
	var client := Session.online() and not Session.hosting
	btn_launch = _button("Waiting for the host to launch" if client else "Launch mission", _on_launch, footer)
	btn_launch.disabled = client
	if Session.can_invite():
		_button("Invite crew (Steam)", func() -> void: Session.invite_crew(), footer)
	_button("Settings", func() -> void: show_screen("settings"), footer)
	btn_leave = _button("Leave crew" if Session.online() else "Back", _on_leave, footer)


## The debrief (R2.15a): the menu panel names the outcome and holds Next; the board stands over the bay.
func _build_debrief() -> void:
	var t := DebriefStats.table(NetMission.last_debrief)
	_title("Debrief", 40)   # the outcome and time are on the board only
	_text("Highlighted: the crew's best in that row.", NOTE_FONT, Color(0.6, 0.62, 0.65))
	_text("Next takes the crew back to the loadout for the next mission.", NOTE_FONT, Color(0.6, 0.62, 0.65))
	btn_next = _button("Next: loadout", _on_debrief_next, footer)
	btn_next.name = "Next"
	if debrief_layer == null or not is_instance_valid(debrief_layer):
		debrief_layer = MarginContainer.new()
		debrief_layer.name = "DebriefLayer"
		debrief_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(debrief_layer)
		debrief_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		debrief_layer.add_theme_constant_override("margin_left", int(PANEL_W) + 28)
		for side in ["right", "top", "bottom"]:
			debrief_layer.add_theme_constant_override("margin_" + side, 28)
		debrief_board = DebriefBoard.new()
		debrief_board.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		debrief_board.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		debrief_layer.add_child(debrief_board)
		move_child(debrief_layer, status_label.get_index())   # under the status line and the invite prompt
	debrief_board.show_table(t)


func _on_debrief_next() -> void:
	NetMission.clear_debrief()
	show_screen("hangar")


func _close_debrief() -> void:
	if debrief_layer != null and is_instance_valid(debrief_layer):
		debrief_layer.queue_free()
	debrief_layer = null
	debrief_board = null


## The crew a stub debrief names (--menu-screen debrief): the roster online, else this pilot plus a demo crew with a bot.
func _crew_entries_for_stub() -> Array:
	if Session.online():
		return Session.crew()
	return [{"peer": 1, "name": Session.display_name("Pilot")}, {"peer": 2, "name": "Ripley"},
		{"peer": 3, "name": "Vasquez"}, {"peer": -1, "name": "Bishop"}]


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


## Launch. In a crew only the host's counts: Session.mission.host_launch sends the seed and the city mode to the crew and every
## machine (this one too) hears mission_started, plays the bay alert and loads the mission at the same moment on the
## shared clock. Solo (offline) this machine plays the alert and loads the test drive with the same seed + mode
## (MissionScene.solo_launch). No mission yet: the test drive is it.
func _on_launch() -> void:
	if launching:
		return
	var args := OS.get_cmdline_user_args()
	if Session.online():
		if Session.hosting:
			Session.mission.host_launch(mission_seed(args), MissionScene.MODE_STACK)
		return
	MissionScene.solo_launch = {"seed": mission_seed(args), "mode": MissionScene.MODE_STACK,
		"friendly_fire": bool(settings["friendly_fire"])}
	_play_launch(LAUNCH_ALERT_TIME)


## The mission seed: --seed for this run, else a fresh random one. The roll is a launch-only generator seeded from the
## clock (not a gameplay roll: AGENTS.md rule 4); the seed is then broadcast in the launch, so every machine builds
## from the same number.
static func mission_seed(args: PackedStringArray) -> int:
	var s := Boot.arg_value(args, "--seed")
	if s.is_valid_int():
		return int(s)
	var pick := RandomNumberGenerator.new()
	pick.seed = Time.get_ticks_usec() ^ int(Time.get_unix_time_from_system() * 1000.0)
	return pick.randi_range(1, 999999)


func _on_mission_started(_params: Dictionary) -> void:
	_play_launch(Session.mission.seconds_to_load())


## The bay goes to launch alert (docs/design/hangar.md), then the mission loads after `delay` seconds.
func _play_launch(delay: float) -> void:
	if launching:
		return
	launching = true
	NetMission.clear_debrief()
	if btn_launch == null or not is_instance_valid(btn_launch):
		show_screen("hangar")
	btn_launch.disabled = true
	btn_launch.text = "Launching..."
	stage.set_alert(true, delay)   # the egress (docs/design/hangar-v2/README.md); it plays on over the load (HangarHandoff)
	var audio := AudioDirector.of(self)
	if audio != null:
		audio.play_2d("ui.hangar.alert", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)
	await get_tree().create_timer(maxf(delay, 0.0)).timeout
	if is_inside_tree() and launching:
		# The mission's loading screen, already up here and drawn, so the scene change (a blocking load) shows it, not a
		# frozen bay; the mission scene puts its own up in its first line.
		if HangarHandoff.wanted(stage):
			HangarHandoff.carry(stage)   # the egress keeps playing over the mission's loading screen
		var cover := LoadingScreen.cover(self)
		var seed_value := int(Session.mission.params.get("seed", 0)) if Session.online() else int(MissionScene.solo_launch.get("seed", 0))
		if seed_value > 0:
			cover.set_mission(seed_value, str(Session.mission.params.get("mode", "")) if Session.online() else str(MissionScene.solo_launch.get("mode", "")))
		cover.set_phase("launch")
		await get_tree().process_frame
		await get_tree().process_frame
		if is_inside_tree() and launching:
			get_tree().change_scene_to_file(MissionScene.SCENE)


## Take a handed-over loading screen down once the menu has drawn a few frames behind it.
func _uncover_later(cover: LoadingScreen) -> void:
	for i in 3:
		await get_tree().process_frame
	if is_instance_valid(cover):
		cover.finish()


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
	if screen in ["hangar", "debrief", "busy"]:
		show_screen("main")


func _on_roster_changed() -> void:
	if screen == "hangar" and crew_list != null:
		_fill_crew()
	_refresh_stage()


## The host's crew option changed (a client hears sys.crew_opts): the hangar's box follows it.
func _on_crew_opts() -> void:
	if ff_check != null and is_instance_valid(ff_check):
		ff_check.set_pressed_no_signal(Session.friendly_fire)
		_mark_friendly_fire()


## "On" / "Off" next to the friendly fire box (plus "(host)" on a client: read-only).
func _mark_friendly_fire() -> void:
	if ff_check == null or not is_instance_valid(ff_check):
		return
	ff_check.text = ("On" if ff_check.button_pressed else "Off") + ("   (host's choice)" if ff_check.disabled else "")


func _on_invite(_lobby_id: int, inviter: String) -> void:
	show_invite_prompt(inviter)


## Ask about the pending invite (docs: NetSession INVITES): who invited, and what accepting does to the current crew.
func show_invite_prompt(inviter: String) -> void:
	_close_invite_prompt()
	var who := inviter if inviter != "" else "A Steam friend"
	var shade := ColorRect.new()
	shade.name = "InvitePrompt"
	shade.color = Color(0.0, 0.0, 0.0, 0.55)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.name = "Center"
	shade.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.14, 0.98)
	sb.border_color = Color(0.9, 0.48, 0.12)
	sb.set_border_width_all(3)
	sb.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)
	var title := Label.new()
	title.text = "Crew invite"
	title.add_theme_font_size_override("font_size", 26)
	col.add_child(title)
	invite_label = Label.new()
	invite_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	invite_label.add_theme_font_size_override("font_size", 20)
	var leaving := ""
	if Session.online():
		leaving = "\nAccepting leaves your current crew."
	elif Session.busy():
		leaving = "\nAccepting stops opening or joining a crew."
	invite_label.text = "%s invited you to their crew.%s" % [who, leaving]
	col.add_child(invite_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	col.add_child(row)
	btn_invite_accept = _button("Accept", _accept_invite, row)
	btn_invite_decline = _button("Decline", _decline_invite, row)
	for b: Button in [btn_invite_accept, btn_invite_decline]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	invite_prompt = shade


func _accept_invite() -> void:
	_close_invite_prompt()
	if Session.accept_invite():
		show_screen("busy")


func _decline_invite() -> void:
	_close_invite_prompt()
	Session.decline_invite()


func _close_invite_prompt() -> void:
	if invite_prompt != null and is_instance_valid(invite_prompt):
		invite_prompt.queue_free()
	invite_prompt = null
	invite_label = null
	btn_invite_accept = null
	btn_invite_decline = null


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


## A new chassis: the loadout flown on the old one is remembered for it ("loadouts", per chassis), the new one's
## remembered loadout comes back ({} = its default), made valid for its hardpoints, and the crew hears about it.
func _set_chassis(id: String) -> void:
	var old := str(settings["chassis"])
	if id == old:
		return
	var memo: Dictionary = (settings.get("loadouts", {}) as Dictionary).duplicate()
	memo[old] = _loadout()
	_set_setting("loadouts", memo)
	_set_setting("loadout", MechCatalog.sanitize_loadout(id, memo.get(id, {}) as Dictionary))
	_set_profile("chassis", id)
	_update_stats()


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
	if key in ["fullscreen", "resolution", "vsync", "msaa", "master", "music", "sfx"]:
		GameSettings.apply(settings)


## The resolution picker only sizes a window: in fullscreen the display's own resolution is used, so it greys out.
func _mark_resolution() -> void:
	if resolution_pick == null or not is_instance_valid(resolution_pick):
		return
	var full := bool(settings["fullscreen"])
	resolution_pick.disabled = full
	resolution_pick.tooltip_text = "Fullscreen uses the display's resolution." if full else "The window's size."


func _loadout() -> Dictionary:
	return MechCatalog.sanitize_loadout(str(settings["chassis"]), settings["loadout"] as Dictionary)


static func _weapon_label(w: String, key: int = 5) -> String:
	var d := MechCatalog.weapon(w)
	if MechCatalog.is_equipment(w):
		if str(d.get("equipment", "")) == "passive":
			return "%s  (%.0ft, passive: %s)" % [d["name"], d["weight"], str(d.get("note", "")).trim_prefix("Passive: ").trim_suffix(".")]
		return "%s  (%.0ft, key %d, %.0f heat per use, %d per mission)" % [d["name"], d["weight"], key, d["active_heat"],
			int(d.get("charges", 0))]
	return "%s  (%.0ft, %.1f heat/s, %.0f per shot)" % [d["name"], d["weight"], d["passive_heat"], d["active_heat"]]


## loadout_stats with the equipment's cooling bonus (the radiator, loadout_stats' `cooling_bonus`) added to cooling:
## loadout_stats keeps cooling at the chassis value, WeaponRack adds the bonus in play, so the hangar shows the same cooling.
static func hangar_stats(chassis_id: String, loadout: Dictionary) -> Dictionary:
	var st := MechCatalog.loadout_stats(chassis_id, loadout)
	var bonus := float(st["cooling_bonus"])
	st["cooling"] = float(st["cooling"]) + bonus
	st["net_cooling"] = float(st["net_cooling"]) + bonus
	return st


func _update_stats() -> void:
	if stats_label == null:
		return
	var st := hangar_stats(str(settings["chassis"]), _loadout())
	stats_label.text = "Weight %.0f / %.0f t, %d weapons%s\nPassive heat %.1f/s vs cooling %.1f/s (net %+.1f)\nHottest shot %.0f of %.0f heat capacity" % [
		st["weight"], st["max_weight"], st["weapons"], "   OVERWEIGHT" if st["overweight"] else "",
		st["passive_heat"], st["cooling"], st["net_cooling"], st["peak_heat"], st["heat_cap"]]


func _fill_crew() -> void:
	for c in crew_list.get_children():
		crew_list.remove_child(c)
		c.queue_free()
	btn_add_bot = null
	bot_skill_pick = null
	bot_remove.clear()
	var entries := _crew_entries()
	var host_lobby := _can_seat_bots()
	for e: Dictionary in entries:
		var l := Label.new()
		var bot := bool(e.get("bot", false))
		if bot:   # its mech is picked at launch from the mission seed (BotLoadout)
			l.text = "%d  %s   %s head, bot (%s), picks its mech at launch" % [int(e["seat"]), str(e["name"]),
				MechCatalog.head_name(str(e["head"])), str(e.get("skill", NetSession.BOT_SKILL))]
		else:
			l.text = "%d  %s   %s head, %s%s" % [int(e["seat"]), str(e["name"]), MechCatalog.head_name(str(e["head"])),
				str(MechCatalog.chassis(str(e["chassis"]))["name"]), "   (you)" if bool(e.get("you", false)) else ""]
		l.add_theme_font_size_override("font_size", FONT)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if bot and host_lobby:
			var row := HBoxContainer.new()
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
			var id := int(e["peer"])
			var rm := Button.new()
			rm.name = "RemoveBot%d" % -id
			rm.text = "Remove"
			rm.pressed.connect(func() -> void:
				_play_ui("ui.back")
				Session.remove_bot(id))
			row.add_child(rm)
			bot_remove[id] = rm
			crew_list.add_child(row)
		else:
			crew_list.add_child(l)
	if Session.online():
		var free := NetSession.MAX_CREW - entries.size()
		if free > 0:
			_text_into(crew_list, "%d seat%s open" % [free, "" if free == 1 else "s"], NOTE_FONT, Color(0.6, 0.62, 0.65))
	if host_lobby:
		var row2 := HBoxContainer.new()
		btn_add_bot = Button.new()
		btn_add_bot.name = "AddBot"
		btn_add_bot.text = "Add bot"
		btn_add_bot.disabled = Session.seats_free() <= 0
		btn_add_bot.tooltip_text = "Seat an AI pilot. It picks its own mech and loadout at launch."
		btn_add_bot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn_add_bot.pressed.connect(func() -> void:
			_play_ui("ui.click")
			Session.add_bot(Session.bot_skill))
		row2.add_child(btn_add_bot)
		if SHOW_BOT_SKILL:
			bot_skill_pick = OptionButton.new()
			bot_skill_pick.name = "BotSkill"
			for k: String in NetSession.BOT_SKILLS:
				bot_skill_pick.add_item(k.capitalize())
			bot_skill_pick.select(maxi(NetSession.BOT_SKILLS.find(Session.bot_skill), 0))
			bot_skill_pick.tooltip_text = "How well the bots play (every bot)."
			bot_skill_pick.item_selected.connect(func(i: int) -> void: Session.set_bot_skill(str(NetSession.BOT_SKILLS[i])))
			row2.add_child(bot_skill_pick)
		crew_list.add_child(row2)


## Only the host of an online crew, in the hangar before launch, seats bots.
func _can_seat_bots() -> bool:
	return Session.online() and Session.hosting and Session.crew_state == "lobby"


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
	if screen == "hangar" or screen == "debrief":
		var mechs: Array = []
		for e: Dictionary in _crew_entries():
			mechs.append({"head": e["head"], "chassis": e["chassis"], "name": e["name"], "accent": e.get("accent", MechAccent.DEFAULT),
				"loadout": _loadout() if bool(e.get("you", false)) else e.get("loadout", {})})
		stage.show_mechs(mechs, true)
		if stage.bay != null:
			stage.bay.show_tags(screen != "debrief")   # the board names the pilots; the tags would show behind it
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
	_gap(10)
	_text(t.to_upper(), SECTION_FONT, Color(0.9, 0.48, 0.12))


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
	l.custom_minimum_size = Vector2(ROW_LABEL_W, ROW_H)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.8, 0.82, 0.85))
	h.add_theme_constant_override("separation", 10)
	h.add_child(l)
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(w)
	panel_box.add_child(h)


func _option(labels: Array, selected: int, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	# Long item labels (equipment notes) must not widen the menu panel: the button keeps the panel's width and clips its
	# text (the popup list still shows each item in full). Without this the hangar panel grew to ~910 px and squeezed the bay.
	o.fit_to_longest_item = false
	o.custom_minimum_size = Vector2(0, ROW_H)
	o.clip_text = true
	o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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


## The screen the next menu opens on ("" = the usual: hangar online, else main). A solo mission that ended (MissionScene,
## MissionFlow) sets "hangar"; consumed by _ready.
static var next_screen := ""
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
	var a := AudioDirector.of(self)
	if a != null:
		a.play_ui(cue_id, pitch)


func _play_mount_sfx(weapon_id: String) -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	if weapon_id == "":
		a.play_ui("ui.hangar.unmount")
		return
	var w := float(MechCatalog.weapon(weapon_id).get("weight", 6.0))
	# Heavier weapons bolt on with a beefier, lower clunk.
	a.play_ui("ui.hangar.mount", clampf(1.12 - w * 0.025, 0.72, 1.12))
