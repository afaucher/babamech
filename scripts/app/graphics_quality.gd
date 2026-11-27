class_name GraphicsQuality
extends RefCounted
## The player's graphics quality (GameSettings "quality": LOW / MEDIUM / HIGH = 0 / 1 / 2, below; this class owns the levels)
## applied to what this machine draws (the city's per-level numbers: CityQuality.LEVELS). STRICTLY local presentation, like CityQuality: never a plan, a checksum, a roll or a hit test.
##
##   level()                  the level in force: the run-only --quality flag (Boot), else the saved setting (which
##                            auto-detects when nothing is saved: an integrated GPU gets LOW, anything else HIGH)
##   apply_viewport(vp)       the 3D render scale, MSAA and screen-space AA of one viewport (VIEWPORT below); the root
##                            viewport gets it at boot and on every change (GameSettings.apply), so menu and hangar too
##   apply_environment(env)   switches an Environment's costly extras off below HIGH (glow, SSAO, SSIL, SSR); HIGH puts
##                            back what the environment had. The city's environment is CityLightRig's (stack.set_quality)
##   notify(tree)             calls `_on_graphics_quality(level)` on every node in group "graphics_quality" (the test
##                            drive: stack.set_quality / life.set_quality), after a settings change
##   detect() / is_integrated(adapter, type)   the auto-detect rule
##
## The renderer (Forward+ / Compatibility) is a separate, restart-only choice: see renderer_* below.

const GROUP := "graphics_quality"
## The levels (saved as these ints in GameSettings "quality"; the --quality flag takes the names).
const LOW := 0
const MEDIUM := 1
const HIGH := 2
const NAMES := ["low", "medium", "high"]     ## per level
## Per level: the 3D render scale (FSR 1 upscale in Forward+ / Mobile, bilinear in Compatibility, which has no FSR),
## whether the player's MSAA setting applies (false: MSAA off) and screen-space AA (always off: the project uses none).
const VIEWPORT := [
	{"scale": 0.67, "msaa": false},   # LOW
	{"scale": 0.85, "msaa": true},    # MEDIUM
	{"scale": 1.0, "msaa": true},     # HIGH: today's settings
]
const MSAA := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]
## Adapter name fragments of integrated GPUs (lower case). Intel's discrete cards are "Arc A..." / "Arc B..." (below).
const INTEGRATED_NAMES := ["intel", "uhd graphics", "iris", "hd graphics", "radeon(tm) graphics", "radeon graphics",
		"vega 8", "vega 6", "vega 3", "adreno", "mali", "microsoft basic render", "llvmpipe", "swiftshader"]
const DISCRETE_NAMES := ["arc(tm) a", "arc a", "arc(tm) b", "arc b"]

## The run-only --quality flag (-1: none, use the setting).
static var override_level := -1
## The saved setting as last applied (-1: not loaded yet).
static var _setting := -1
## The player's MSAA setting (GameSettings "msaa", 0..2) as last applied.
static var _msaa := 1
## DEV (hidden flag --dev-pretend-integrated, Boot): treat this GPU as integrated, to exercise the first-launch relaunch
## (and the LOW auto quality) on a machine with a dedicated card.
static var pretend_integrated := false


static func clamp_level(q: int) -> int:
	return clampi(q, LOW, HIGH)


static func name_of(q: int) -> String:
	return str(NAMES[clamp_level(q)])


## The level named `n` ("low", "medium", "high"), or `fallback`.
static func from_name(n: String, fallback: int = HIGH) -> int:
	var q := NAMES.find(n.to_lower())
	return q if q >= 0 else fallback


static func level() -> int:
	if override_level >= 0:
		return GraphicsQuality.clamp_level(override_level)
	if _setting < 0:
		_setting = int(GameSettings.load_settings()["quality"])
	return GraphicsQuality.clamp_level(_setting)


## Take the settings (GameSettings.apply calls this): the quality and the MSAA setting the levels build on.
static func use_settings(d: Dictionary) -> void:
	_setting = GraphicsQuality.clamp_level(int(d.get("quality", GraphicsQuality.HIGH)))
	_msaa = clampi(int(d.get("msaa", 1)), 0, 2)


## The level an unsaved setting starts at on this machine.
static func detect() -> int:
	return GraphicsQuality.LOW if integrated_here() else GraphicsQuality.HIGH


## This machine's GPU counts as integrated (or --dev-pretend-integrated says so).
static func integrated_here() -> bool:
	return pretend_integrated or is_integrated(adapter_name(), RenderingServer.get_video_adapter_type())


static func adapter_name() -> String:
	return RenderingServer.get_video_adapter_name()


## Whether an adapter is an integrated GPU: the driver says so, or its name is a known integrated family.
static func is_integrated(adapter: String, type: int) -> bool:
	if type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU or type == RenderingDevice.DEVICE_TYPE_CPU:
		return true
	var n := adapter.to_lower()
	if n == "":
		return false
	for d: String in DISCRETE_NAMES:
		if n.contains(d):
			return false
	for i: String in INTEGRATED_NAMES:
		if n.contains(i):
			return true
	return false


## "Intel(R) UHD Graphics 620 (integrated)" for the settings note.
static func adapter_note() -> String:
	var n := adapter_name()
	if n == "":
		return "GPU unknown"
	return "%s (%s)" % [n, "integrated" if is_integrated(n, RenderingServer.get_video_adapter_type())
		else ("dedicated, pretending integrated" if pretend_integrated else "dedicated")]


static func apply_viewport(vp: Viewport, q: int = -1) -> void:
	if vp == null:
		return
	if q < 0:
		q = level()
	var lv: Dictionary = VIEWPORT[GraphicsQuality.clamp_level(q)]
	var s := float(lv["scale"])
	vp.scaling_3d_scale = s
	if s >= 0.999:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr_available() else Viewport.SCALING_3D_MODE_BILINEAR
	vp.msaa_3d = MSAA[_msaa] if bool(lv["msaa"]) else Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false


## FSR 1 runs in the RenderingDevice renderers (Forward+, Mobile), not in Compatibility.
static func fsr_available() -> bool:
	return RenderingServer.get_current_rendering_method() in ["forward_plus", "mobile"]


static func apply_environment(env: Environment, q: int = -1) -> void:
	if env == null:
		return
	if q < 0:
		q = level()
	if not env.has_meta("gq_orig"):
		env.set_meta("gq_orig", {"glow": env.glow_enabled, "ssao": env.ssao_enabled, "ssil": env.ssil_enabled,
				"ssr": env.ssr_enabled})
	var orig: Dictionary = env.get_meta("gq_orig")
	var q_ := GraphicsQuality.clamp_level(q)
	env.glow_enabled = bool(orig["glow"]) and q_ >= GraphicsQuality.MEDIUM
	env.ssao_enabled = bool(orig["ssao"]) and q_ >= GraphicsQuality.HIGH
	env.ssil_enabled = bool(orig["ssil"]) and q_ >= GraphicsQuality.HIGH
	env.ssr_enabled = bool(orig["ssr"]) and q_ >= GraphicsQuality.HIGH


## After the player changes the setting: take it, apply it to the root viewport (not headless) and tell the group.
static func apply_settings(d: Dictionary, tree: SceneTree) -> void:
	use_settings(d)
	if tree != null and DisplayServer.get_name() != "headless":
		apply_viewport(tree.root)
	notify(tree)


static func notify(tree: SceneTree) -> void:
	if tree != null:
		tree.call_group(GROUP, "_on_graphics_quality", level())


# --- Renderer (restart only) -------------------------------------------------------------------------------------------
## GameSettings "renderer": "auto" (Compatibility on an integrated GPU, else Forward+), "forward_plus" or
## "gl_compatibility". Godot picks its renderer before any script runs, so a change takes effect at the next launch: the
## choice is written to `override.cfg` NEXT TO THE EXECUTABLE (Godot reads it at startup, over project.godot), only the
## one key rendering/renderer/rendering_method (Forward+ erases it, so project.godot governs again). Exported builds only:
## a dev run's override.cfg would sit in the project folder and change every other session's runs and tests (use
## `run.ps1 --rendering-method gl_compatibility` there). A `--rendering-method` command-line option beats the file, so a
## player stuck on a broken renderer can start with `--rendering-method forward_plus` (or delete override.cfg).

const RENDERERS := ["auto", "forward_plus", "gl_compatibility"]
const RENDERER_KEY := "renderer/rendering_method"


static func sanitize_renderer(v: Variant) -> String:
	return str(v) if str(v) in RENDERERS else "auto"


## The renderer a setting asks for on this machine ("forward_plus" or "gl_compatibility").
static func renderer_wanted(setting: String) -> String:
	match sanitize_renderer(setting):
		"forward_plus":
			return "forward_plus"
		"gl_compatibility":
			return "gl_compatibility"
	return "gl_compatibility" if detect() == GraphicsQuality.LOW else "forward_plus"


static func renderer_label(method: String) -> String:
	return "Compatibility" if method == "gl_compatibility" else "Forward+"


## The renderer running now.
static func renderer_current() -> String:
	return RenderingServer.get_current_rendering_method()


## Whether this build may write override.cfg (an exported build, not a dev run from the project folder).
static func can_switch_renderer() -> bool:
	return OS.has_feature("template")


static func override_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join("override.cfg")


## The renderer an override.cfg asks for ("" = none: project.godot's Forward+).
static func read_override(path: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return ""
	return str(cfg.get_value("rendering", RENDERER_KEY, ""))


## Write `method` into the override.cfg at `path`, keeping any other keys there (Forward+: erase ours; an emptied file
## is removed). True when the file now asks for `method`.
static func write_override(path: String, method: String) -> bool:
	var cfg := ConfigFile.new()
	var had := cfg.load(path) == OK
	if method == "forward_plus":
		if not had or not cfg.has_section_key("rendering", RENDERER_KEY):
			return true
		cfg.erase_section_key("rendering", RENDERER_KEY)
		if cfg.get_sections().is_empty():
			return DirAccess.remove_absolute(path) == OK
	else:
		cfg.set_value("rendering", RENDERER_KEY, method)
	var err := cfg.save(path)
	if err != OK:
		push_warning("[Graphics] could not write %s (error %d)" % [path, err])
	return err == OK


## Make the next launch use what the setting asks for (boot and the settings screen call this). Returns a note for the
## player ("" when nothing is pending).
static func sync_renderer(setting: String) -> String:
	var want := renderer_wanted(setting)
	if not can_switch_renderer():
		if want != renderer_current():
			return "%s wanted: dev runs switch with --rendering-method %s." % [renderer_label(want), want]
		return ""
	var path := override_path()
	var file_wants := read_override(path)
	if (file_wants if file_wants != "" else "forward_plus") != want and not write_override(path, want):
		return "Could not write %s: start with --rendering-method %s." % [path, want]
	if want != renderer_current():
		return "%s after a restart." % renderer_label(want)
	return ""


## FIRST-LAUNCH RELAUNCH. Without it the first launch on a weak laptop runs Forward+ (override.cfg only counts from the
## next start). So at boot, before the menu, a launch that would switch on its own ("auto" setting, Compatibility wanted,
## Forward+ running, no renderer in override.cfg yet) writes override.cfg and starts itself again once, with the same
## command line plus NO_RELAUNCH_FLAG (the loop guard), then quits. Never in dev runs (no override.cfg there), headless
## runs or tests (Boot returns for --run-test first), nor when the command line names a renderer itself.
## Steam: a game Steam started is the process Steam tracks (playtime, overlay injection, the "running" state, steam_api's
## pipe to the client). A child it starts and then leaves would be an untracked process (no overlay, Steam showing the
## game as closed), and OS.set_restart_on_exit is the same child process. So a Steam launch does not relaunch: it writes
## override.cfg and the settings note says "Compatibility after a restart" (the next launch is Compatibility).

const NO_RELAUNCH_FLAG := "--no-renderer-relaunch"
const PRETEND_FLAG := "--dev-pretend-integrated"


## Started by the Steam client (its launch environment, or an invite's +connect_lobby).
static func launched_by_steam(all_args: PackedStringArray) -> bool:
	if all_args.has("+connect_lobby"):
		return true
	for k: String in ["SteamClientLaunch", "SteamGameId", "SteamOverlayGameId"]:
		if OS.get_environment(k) != "":
			return true
	return false


## Why this launch must not relaunch itself ("" = it should). `exported` / `headless` / `steam` are passed in for tests.
static func relaunch_block(setting: String, user_args: PackedStringArray, all_args: PackedStringArray, exported: bool,
		headless: bool, steam: bool, override_wants: String, current: String) -> String:
	if not exported:
		return "dev run"
	if headless:
		return "headless"
	if user_args.has(NO_RELAUNCH_FLAG):
		return "already relaunched"
	if user_args.has("--run-test"):
		return "test"
	if sanitize_renderer(setting) != "auto":
		return "renderer set to %s" % setting
	if override_wants != "":
		return "override.cfg already asks for %s" % override_wants
	if all_args.has("--rendering-method") or all_args.has("--rendering-driver"):
		return "renderer on the command line"
	if renderer_wanted(setting) != "gl_compatibility" or current == "gl_compatibility":
		return "no switch needed"
	if steam:
		return "started by Steam"
	return ""


## Boot calls this first. True: a Compatibility copy of the game was started; quit now.
static func first_launch_relaunch(setting: String) -> bool:
	var user_args := OS.get_cmdline_user_args()
	var engine_args := OS.get_cmdline_args()
	var path := override_path()
	var why := relaunch_block(setting, user_args, engine_args, can_switch_renderer(), DisplayServer.get_name() == "headless",
		launched_by_steam(engine_args), read_override(path), renderer_current())
	if why != "":
		if why == "started by Steam":
			print("[Graphics] integrated GPU on Forward+, started by Steam: no relaunch, Compatibility from the next launch")
		return false
	if not write_override(path, "gl_compatibility"):
		print("[Graphics] integrated GPU on Forward+: could not write %s, no relaunch" % path)
		return false
	# get_cmdline_args() is the engine's part, get_cmdline_user_args() what followed "--": put both back.
	var args := PackedStringArray(engine_args)
	args.append("--")
	args.append_array(user_args)
	args.append(NO_RELAUNCH_FLAG)
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		print("[Graphics] integrated GPU on Forward+: relaunch failed, Compatibility from the next launch")
		return false
	print("[Graphics] integrated GPU on Forward+ (%s): wrote %s, relaunched as Compatibility (pid %d) %s" % [adapter_name(), path,
		pid, " ".join(args)])
	return true


## Quit and start again with the same command line (the new renderer from override.cfg). OS.get_cmdline_args() stops at
## `--`: the user args after it (--settings, --net-name, ...) are put back.
static func restart(tree: SceneTree) -> void:
	OS.set_restart_on_exit(true, restart_args(OS.get_cmdline_args(), OS.get_cmdline_user_args()))
	tree.quit()


## The command line for restart(): the engine args, then `--` and the user args when there are any.
static func restart_args(engine_args: PackedStringArray, user_args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray(engine_args)
	if not user_args.is_empty():
		out.append("--")
		out.append_array(user_args)
	return out
