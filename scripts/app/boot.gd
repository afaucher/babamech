class_name Boot
extends Node
## Entry point (from cast). A plain run opens the MENU (front end). Command-line options (after `--`):
##   --run-test <name>     run res://tests/<name>.gd and quit (test_runner.ps1)
##   --scene <res path>    open a specific scene instead of the menu (the lab: res://scenes/lab.tscn)
##   --settings-file <p>   read and write settings at this path instead of user://settings.cfg (tests, run.ps1 -Crew)
##   --quality <q>         low | medium | high: the graphics quality for this run, over the saved setting (not saved)
##   --head <id>           play this head for this run without saving it (run.ps1 -Crew gives each window its own)
##   --menu-shot <png>     save a screenshot of the menu after --menu-after seconds (default 1.5) and quit
##   --menu-screen <s>     open the menu on main | settings | hangar
##   --crew-shot <png>     (run.ps1 -Crew -ShotDir) save a screenshot once --crew-size players are in, then quit
##   --seed <N>            the mission seed: the test drive's city (solo, default 1), and the Launch (host or solo; without
##                         it the Launch rolls a fresh random seed and broadcasts it)
##   --stack / --district  the mission's city: the multi-deck section stack (the default) or one city district (the
##                         pre-stack test drive); the host's Launch sends it with the seed (TestDrive.launch_mode)
##   --no-renderer-relaunch  this process is the first launch's Compatibility relaunch (GraphicsQuality): don't again
##   --dev-pretend-integrated  DEV, hidden: treat the GPU as integrated (exercises that relaunch and the LOW auto quality)
##   --net-host, --net-join <ip[:port]>, --net-port <P>, --net-link <preset>, --net-name <name>
##                         online dev flags (NetSession); the menu opens on the hangar once the crew is up.

const MENU_SCENE := "res://scenes/menu.tscn"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--run-test")
	if i >= 0 and i + 1 < args.size():
		_run_test(args[i + 1])
		return
	var file := arg_value(args, "--settings-file")
	if file != "":
		GameSettings.path = file
	GraphicsQuality.override_level = quality_flag(args)
	GraphicsQuality.pretend_integrated = args.has(GraphicsQuality.PRETEND_FLAG)
	var settings := GameSettings.load_settings()
	# First launch on an integrated GPU in an exported build: write override.cfg and start again as Compatibility, once.
	if GraphicsQuality.first_launch_relaunch(str(settings["renderer"])):
		get_tree().quit()
		return
	GameSettings.apply(settings, not args.has("--menu-shot") and not args.has("--crew-shot"))
	var renderer_note := GraphicsQuality.sync_renderer(str(settings["renderer"]))   # override.cfg for the next launch
	print("[Graphics] %s, quality %s%s, renderer %s%s" % [GraphicsQuality.adapter_note(), CityQuality.name_of(GraphicsQuality.level()),
		" (--quality)" if GraphicsQuality.override_level >= 0 else "", GraphicsQuality.renderer_current(),
		(": " + renderer_note) if renderer_note != "" else ""])
	# The profile goes into the session before NetSession's dev flags open a crew with it (they run deferred).
	var head := arg_value(args, "--head")
	var accent := arg_value(args, "--accent")   # run-only, like --head (run.ps1 -Crew gives each window its own)
	Session.set_profile(str(settings["player_name"]), head if MechCatalog.HEADS.has(head) else str(settings["head"]),
		str(settings["chassis"]), accent if MechMeshes.ACCENTS.has(accent) else str(settings["accent"]),
		settings["loadout"] as Dictionary)
	get_tree().change_scene_to_file.call_deferred(route(args))


## The scene a command line opens.
static func route(args: PackedStringArray) -> String:
	var explicit := arg_value(args, "--scene")
	return explicit if explicit != "" else MENU_SCENE


## The --quality flag's level (CityQuality.LOW / MEDIUM / HIGH), or -1 (none or unknown).
static func quality_flag(args: PackedStringArray) -> int:
	var v := arg_value(args, "--quality")
	return CityQuality.from_name(v, -1) if v != "" else -1


## The value after `key`, or "".
static func arg_value(args: PackedStringArray, key: String) -> String:
	var i := args.find(key)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return ""


func _run_test(test_name: String) -> void:
	var path := "res://tests/%s.gd" % test_name
	if not ResourceLoader.exists(path):
		push_error("No such test: " + path)
		print(">>> [TEST FAILED] %s <<<" % test_name)
		get_tree().quit(2)
		return
	var script: GDScript = load(path)
	if script == null or not script.can_instantiate():
		push_error("Test failed to load (parse error?): " + path)
		print(">>> [TEST FAILED] %s <<<" % test_name)
		get_tree().quit(3)
		return
	var t: Node = script.new()
	t.name = test_name
	get_tree().root.add_child.call_deferred(t)
