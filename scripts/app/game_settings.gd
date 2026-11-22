class_name GameSettings
extends RefCounted
## The player's settings, persisted in a ConfigFile (user://settings.cfg; `--settings-file` points tests and run.ps1 -Crew
## windows elsewhere). Static, no autoload: load_settings() -> Dictionary, save_settings(d), apply(d).
##
## Profile (carried in the join handshake): player_name ("" = the Steam persona), head (MechCatalog.HEADS), accent
## (MechAccent.ACCENTS id: the livery colour that replaces the safety orange; default "orange").
## Hangar (the pre-mission choice, remembered): chassis, loadout {hardpoint id: weapon id}.
## Video: fullscreen, vsync, msaa (0 off, 1 2x, 2 4x). Audio: master, music, sfx (0..1, linear).
## Network: link_sim (off / coast / rough): the crew's simulated link when this machine hosts (NetSession).

const DEFAULT_PATH := "user://settings.cfg"
const DEFAULTS := {
	"player_name": "",
	"head": "chicken",
	"accent": "orange",
	"chassis": "strider",
	"loadout": {},
	"fullscreen": false,
	"vsync": true,
	"msaa": 1,
	"master": 0.8,
	"music": 0.7,
	"sfx": 0.8,
	"link_sim": "off",
}
## Which ConfigFile section each key lives in.
const SECTIONS := {
	"player_name": "profile", "head": "profile", "accent": "profile",
	"chassis": "hangar", "loadout": "hangar",
	"fullscreen": "video", "vsync": "video", "msaa": "video",
	"master": "audio", "music": "audio", "sfx": "audio",
	"link_sim": "network",
}
const BUSES := ["Music", "SFX"]

static var path := DEFAULT_PATH


## Every key, saved values over the defaults (a missing or broken file gives the defaults).
static func load_settings() -> Dictionary:
	var out := DEFAULTS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return out
	for k: String in DEFAULTS:
		var v: Variant = cfg.get_value(SECTIONS[k], k, DEFAULTS[k])
		if typeof(v) == typeof(DEFAULTS[k]) or (DEFAULTS[k] is float and v is int):
			out[k] = v
	if not MechCatalog.HEADS.has(str(out["head"])):
		out["head"] = DEFAULTS["head"]
	out["accent"] = MechAccent.sanitize(str(out["accent"]))
	if not MechCatalog.CHASSIS.has(str(out["chassis"])):
		out["chassis"] = DEFAULTS["chassis"]
	return out


static func save_settings(d: Dictionary) -> bool:
	var cfg := ConfigFile.new()
	for k: String in DEFAULTS:
		cfg.set_value(SECTIONS[k], k, d.get(k, DEFAULTS[k]))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := cfg.save(path)
	if err != OK:
		push_warning("[Settings] could not save %s (error %d)" % [path, err])
	return err == OK


## Change one key and save.
static func set_value(key: String, value: Variant) -> Dictionary:
	var d := load_settings()
	d[key] = value
	save_settings(d)
	return d


## Push video and audio settings to the engine. `window` false leaves the window alone (screenshots, tests).
static func apply(d: Dictionary, window: bool = true) -> void:
	_ensure_buses()
	var music_lin := float(d["music"])
	var sfx_lin := float(d["sfx"])
	_set_bus("Master", float(d["master"]))
	_set_bus("Music", music_lin)
	_set_bus("SFX", sfx_lin)
	_set_bus("Ambience", sfx_lin * AudioDirector.AMBIENCE_TRIM_LINEAR if sfx_lin > 0.001 else 0.0)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var audio := tree.root.get_node_or_null("Audio") as AudioDirector
		if audio != null:
			audio.sync_user_volumes(music_lin, sfx_lin)
	if DisplayServer.get_name() == "headless":
		return
	var vp := tree
	if vp != null:
		vp.root.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][clampi(int(d["msaa"]), 0, 2)]
	if not window:
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(d["vsync"]) else DisplayServer.VSYNC_DISABLED)
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(d["fullscreen"]) else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)


static func _ensure_buses() -> void:
	AudioDirector.ensure_buses()
	for b: String in BUSES:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, b)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")


static func _set_bus(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(i, linear <= 0.001)
