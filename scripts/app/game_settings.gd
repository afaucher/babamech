class_name GameSettings
extends RefCounted
## The player's settings, persisted in a ConfigFile (user://settings.cfg; `--settings-file` points tests and run.ps1 -Crew
## windows elsewhere). Static, no autoload: load_settings() -> Dictionary, save_settings(d), apply(d).
##
## Profile (carried in the join handshake): player_name ("" = the Steam persona), head (MechCatalog.HEADS), accent
## (MechAccent.ACCENTS id: the livery colour that replaces the safety orange; default "orange").
## Hangar (the pre-mission choice, remembered): chassis, loadout {hardpoint id: weapon id} (the current chassis'), loadouts
## {chassis id: loadout}: the loadout last flown on each other chassis (the hangar brings it back on a chassis switch).
## Video: fullscreen (else windowed), resolution ("WxH": the window's size when windowed; "" = the default window, the
## project's 1600x900; fullscreen always uses the display's resolution; resolution_list / fit_resolution below), vsync, msaa (0 off, 1 2x, 2 4x), quality (GraphicsQuality.LOW / MEDIUM / HIGH = 0 / 1 / 2, GraphicsQuality;
## -1 in DEFAULTS = never chosen: load_settings auto-detects, LOW on an integrated GPU, else HIGH), renderer (auto /
## forward_plus / gl_compatibility: GraphicsQuality.sync_renderer, takes effect at the next launch).
## Audio: master, music, sfx (0..1, linear).
## Crew: friendly_fire (default true): the crew option this machine sets when it hosts (or plays solo); remembered.
## Network: link_sim (off / coast / rough): the crew's simulated link when this machine hosts (NetSession).
## There is no mission-mode setting (user 2026-11-25: "Cut the legacy modes."): objectives are the only mode. A settings
## file from before still has crew/objectives: load_settings reads only DEFAULTS' keys, so it is ignored, and the next
## save drops it.

const DEFAULT_PATH := "user://settings.cfg"
const DEFAULTS := {
	"player_name": "",
	"head": "chicken",
	"accent": "orange",
	"chassis": "strider",
	"loadout": {},
	"loadouts": {},
	"fullscreen": false,
	"resolution": "",
	"vsync": true,
	"msaa": 1,
	"quality": -1,
	"renderer": "auto",
	"master": 0.8,
	"music": 0.7,
	"sfx": 0.8,
	"link_sim": "off",
	"friendly_fire": true,
}
## Which ConfigFile section each key lives in.
const SECTIONS := {
	"player_name": "profile", "head": "profile", "accent": "profile",
	"chassis": "hangar", "loadout": "hangar", "loadouts": "hangar",
	"fullscreen": "video", "resolution": "video", "vsync": "video", "msaa": "video", "quality": "video", "renderer": "video",
	"master": "audio", "music": "audio", "sfx": "audio",
	"link_sim": "network",
	"friendly_fire": "crew",
}
const BUSES := ["Music", "SFX"]

static var path := DEFAULT_PATH


## Every key, saved values over the defaults (a missing or broken file gives the defaults).
static func load_settings() -> Dictionary:
	var out := DEFAULTS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		out["quality"] = sanitize_quality(out["quality"])
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
	out["quality"] = sanitize_quality(out["quality"])
	out["renderer"] = GraphicsQuality.sanitize_renderer(out["renderer"])
	out["resolution"] = sanitize_resolution(out["resolution"])
	return out


## A saved quality level (0..2), or the auto-detected one for anything else (never chosen, broken).
static func sanitize_quality(v: Variant) -> int:
	if v is int and int(v) >= GraphicsQuality.LOW and int(v) <= GraphicsQuality.HIGH:
		return int(v)
	return GraphicsQuality.detect()


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
	GraphicsQuality.use_settings(d)
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
		GraphicsQuality.apply_viewport(vp.root)   # render scale + the msaa setting (off at LOW)
	if not window:
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(d["vsync"]) else DisplayServer.VSYNC_DISABLED)
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(d["fullscreen"]) else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)
	_apply_resolution(str(d.get("resolution", "")), bool(d["fullscreen"]))


# --- Resolution (playtest R2.16) -------------------------------------------------------------------------------------

## The project's window (project.godot viewport size): what "" (the default) gives a window.
const DEFAULT_WINDOW := Vector2i(1600, 900)
## The smallest window offered or accepted (below it the menu's 1600x900 canvas shrinks past readable).
const MIN_WINDOW := Vector2i(1024, 576)
## Common window sizes; resolution_list keeps the ones that fit the screen, plus the screen's own size.
const RESOLUTIONS := [Vector2i(1024, 576), Vector2i(1024, 768), Vector2i(1280, 720), Vector2i(1280, 800),
	Vector2i(1280, 1024), Vector2i(1366, 768), Vector2i(1440, 900), Vector2i(1600, 900), Vector2i(1680, 1050),
	Vector2i(1920, 1080), Vector2i(1920, 1200), Vector2i(2560, 1080), Vector2i(2560, 1440), Vector2i(2560, 1600),
	Vector2i(3440, 1440), Vector2i(3840, 2160)]
## The screen used when the display reports none (headless, a test): a 1080p screen.
const FALLBACK_SCREEN := Vector2i(1920, 1080)

## The resolution last applied to the window in this process ("" = never changed: the window as launched).
static var _applied_res := ""


## The size of the screen the window is on (FALLBACK_SCREEN when the display reports nothing usable).
static func screen_size() -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return FALLBACK_SCREEN
	var s := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	return s if s.x >= MIN_WINDOW.x and s.y >= MIN_WINDOW.y else FALLBACK_SCREEN


## The window sizes offered on a `screen`-sized display, smallest first: RESOLUTIONS that fit it, plus the screen itself.
static func resolution_list(screen: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r: Vector2i in RESOLUTIONS:
		if r.x <= screen.x and r.y <= screen.y:
			out.append(r)
	if screen.x >= MIN_WINDOW.x and screen.y >= MIN_WINDOW.y and not out.has(screen):
		out.append(screen)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y or (a.x * a.y == b.x * b.y and a.x < b.x))
	return out


static func resolution_id(r: Vector2i) -> String:
	return "%dx%d" % [r.x, r.y]


static func resolution_label(r: Vector2i) -> String:
	return "%d x %d" % [r.x, r.y]


## "1920x1080" -> Vector2i(1920, 1080); anything else (or smaller than MIN_WINDOW) -> Vector2i.ZERO.
static func parse_resolution(s: String) -> Vector2i:
	var parts := s.to_lower().split("x")
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() or not parts[1].strip_edges().is_valid_int():
		return Vector2i.ZERO
	var r := Vector2i(int(parts[0]), int(parts[1]))
	return r if r.x >= MIN_WINDOW.x and r.y >= MIN_WINDOW.y and r.x <= 16384 and r.y <= 16384 else Vector2i.ZERO


## A saved resolution: a valid "WxH" (normalised), else "" (the default window). Whether it fits the screen is decided
## when applied (fit_resolution): the screen may differ next launch.
static func sanitize_resolution(v: Variant) -> String:
	if not (v is String):
		return ""
	var r := parse_resolution(v)
	return resolution_id(r) if r != Vector2i.ZERO else ""


## The window size for resolution `res` on a `screen`: the saved size when it fits; too big for this screen -> the
## largest listed size that fits; "" or broken -> DEFAULT_WINDOW (also shrunk to fit). Never larger than the screen.
static func fit_resolution(res: String, screen: Vector2i) -> Vector2i:
	var want := parse_resolution(res)
	if want == Vector2i.ZERO:
		want = DEFAULT_WINDOW
	if want.x <= screen.x and want.y <= screen.y:
		return want
	var best := MIN_WINDOW
	for r: Vector2i in resolution_list(screen):
		if r.x <= want.x and r.y <= want.y and r.x * r.y > best.x * best.y and r != screen:
			best = r   # not the screen's own size: a window that big has its title bar off screen
	return best


## Size and centre the window for the saved resolution (windowed only; fullscreen keeps the display's resolution). Only
## when the setting differs from the last one applied in this process, so a launch with the default leaves the window as
## the command line made it (run.ps1 -Crew windows) and only a change in Settings resizes it.
static func _apply_resolution(res: String, fullscreen: bool) -> void:
	if fullscreen or res == _applied_res:
		return
	_applied_res = res
	var screen := screen_size()
	var size := fit_resolution(res, screen)
	var cur := DisplayServer.window_get_current_screen()
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(DisplayServer.screen_get_position(cur) + (screen - size) / 2)


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
