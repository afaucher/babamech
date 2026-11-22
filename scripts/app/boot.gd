class_name Boot
extends Node
## Entry point (from cast). A plain run opens the MENU (front end). Command-line options (after `--`):
##   --run-test <name>     run res://tests/<name>.gd and quit (test_runner.ps1)
##   --scene <res path>    open a specific scene instead of the menu (the lab: res://scenes/lab.tscn)
##   --settings-file <p>   read and write settings at this path instead of user://settings.cfg (tests, run.ps1 -Crew)
##   --head <id>           play this head for this run without saving it (run.ps1 -Crew gives each window its own)
##   --menu-shot <png>     save a screenshot of the menu after --menu-after seconds (default 1.5) and quit
##   --menu-screen <s>     open the menu on main | settings | hangar
##   --crew-shot <png>     (run.ps1 -Crew -ShotDir) save a screenshot once --crew-size players are in, then quit
##   --seed <N>            the mission seed: the test drive's city (solo), and the host's Launch in a crew (default 1)
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
	var settings := GameSettings.load_settings()
	GameSettings.apply(settings, not args.has("--menu-shot") and not args.has("--crew-shot"))
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
