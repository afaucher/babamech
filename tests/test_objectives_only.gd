extends TestCase
## Objectives are the only mission mode (user 2026-11-25: "Cut the legacy modes."; it replaced test_objectives_default):
## 1. No mode setting: GameSettings has no "objectives" key; an old settings file that still has crew/objectives (false)
##    loads without error, its other crew values still read, and the next save drops the key.
## 2. No mode switch left in code: MissionScene / NetSession have no `objectives` field, MissionFlow no objectives_wanted /
##    NO_OBJECTIVES_FLAG, no LegacyClearRules class, no district mode (MODE_DISTRICT, MissionScene.launch_mode); a launch
##    carries no "objectives" param.
## 3. One rules mode: MissionRules.make(sec) without a plan evaluates the section's natural plan (no clear / extract).
## 4. The TEST-ONLY quiet fixture (QuietSectionFixture -> MissionFlow.test_quiet) is not reachable from the game: no
##    script under scripts/ outside scripts/test_support/ names the fixture, nothing outside scripts/test_support/ and
##    tests/ writes test_quiet, and scripts/app, scripts/ui and scripts/game reference no test-support class (PerfProbe,
##    the bench instrumentation, excepted: it is a timer, not a mode).
## 5. The fixture does what it says: a solo stack drive with it armed has its section, crew and garrison, and no rules,
##    plan or director; nothing is evaluated or released and no outcome comes.

const OLD_SETTINGS := "user://test_settings/objectives_only_old.cfg"


func setup() -> void:
	_settings()
	_flags()
	_rules()
	_unreachable()
	await _fixture()
	finish()


func _settings() -> void:
	check(not GameSettings.DEFAULTS.has("objectives"), "no objectives setting")
	check(not GameSettings.SECTIONS.has("objectives"), "no objectives section entry")
	var keep := GameSettings.path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://test_settings"))
	var cfg := ConfigFile.new()
	cfg.set_value("crew", "objectives", false)
	cfg.set_value("crew", "friendly_fire", false)
	cfg.set_value("profile", "head", "chicken")
	check(cfg.save(OLD_SETTINGS) == OK, "an old settings file is written")
	GameSettings.path = OLD_SETTINGS
	var d := GameSettings.load_settings()
	check(not d.has("objectives"), "the old key is not read")
	eq(bool(d["friendly_fire"]), false, "the old file's other crew value still reads")
	check(GameSettings.save_settings(d), "it saves")
	var again := ConfigFile.new()
	again.load(OLD_SETTINGS)
	check(not again.has_section_key("crew", "objectives"), "the next save drops the old key")
	GameSettings.set_value("objectives", true)   # anything still writing it: harmless
	again = ConfigFile.new()
	again.load(OLD_SETTINGS)
	check(not again.has_section_key("crew", "objectives"), "set_value on the gone key saves nothing for it")
	GameSettings.path = keep
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OLD_SETTINGS))


func _flags() -> void:
	var td := MissionScene.new()
	check(not ("objectives" in td), "MissionScene has no objectives switch")
	td.free()
	check(not ("objectives" in Session), "NetSession has no objectives switch")
	var mf := MissionFlow.new()
	check(not mf.has_method("objectives_wanted"), "MissionFlow has no objectives_wanted")
	mf.free()
	var consts: Dictionary = (load("res://scripts/game/mission_flow.gd") as GDScript).get_script_constant_map()
	check(not consts.has("NO_OBJECTIVES_FLAG"), "MissionFlow has no NO_OBJECTIVES_FLAG")
	var td_consts: Dictionary = (load("res://scripts/game/test_drive.gd") as GDScript).get_script_constant_map()
	check(not td_consts.has("MODE_DISTRICT"), "MissionScene has no district mode")
	check(not (load("res://scripts/net/net_mission.gd") as GDScript).get_script_constant_map().has("MODE_DISTRICT"),
		"NetMission has no district mode")
	eq(NetMission.clean_mode("district"), NetMission.MODE_STACK, "an old launch's district mode builds the stack")
	check(not (load("res://scripts/game/test_drive.gd") as GDScript).get_script_method_list().any(
		func(m: Dictionary) -> bool: return str(m["name"]) == "launch_mode"), "MissionScene has no launch_mode")
	check(not ProjectSettings.get_global_class_list().any(func(c: Dictionary) -> bool: return str(c["class"]) == "LegacyClearRules"),
		"no LegacyClearRules class")


func _rules() -> void:
	var sec := SectionPlan.make({"seed": 7.0, "decks": 3.0})
	var m := MissionRules.make(sec)
	check(m.plan != null, "MissionRules.make without a plan: the natural plan")
	check(m.objective("extract").is_empty() and m.objective("clear_0").is_empty(), "no clear / extract objectives")


func _unreachable() -> void:
	var files: Array[String] = []
	_collect("res://scripts", files)
	_collect("res://scenes", files)
	check(files.size() > 50, "scanned the scripts (%d files)" % files.size())
	for f: String in files:
		var src := _code(FileAccess.get_file_as_string(f))
		var support := f.begins_with("res://scripts/test_support/")
		if not support:
			check(not src.contains("QuietSectionFixture") and not src.contains("quiet_section_fixture"),
				"%s does not name the quiet fixture" % f)
			var writes := src.contains("test_quiet =") or src.contains("test_quiet=")
			check(not writes, "%s does not write MissionFlow.test_quiet" % f)
		if f.begins_with("res://scripts/app/") or f.begins_with("res://scripts/ui/") or f.begins_with("res://scripts/game/"):
			for cls: String in ["QuietSectionFixture", "TestCase", "NetTest", "LayoutCheck", "ShotCheck", "test_support/"]:
				check(not src.contains(cls), "%s references no test-support class (%s)" % [f, cls])
	for f: String in ["res://scripts/app/boot.gd", "res://scripts/app/game_settings.gd", "res://scripts/ui/front_end.gd"]:
		check(not _code(FileAccess.get_file_as_string(f)).to_lower().contains("quiet"), "%s has no quiet switch" % f)


## The code of a script without its comments (naive: from the first # on a line), so a doc mention doesn't count.
static func _code(src: String) -> String:
	var out := PackedStringArray()
	for l in src.split("\n"):
		var i := l.find("#")
		out.append(l if i < 0 else l.substr(0, i))
	return "\n".join(out)


func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
	for f in d.get_files():
		if f.ends_with(".gd") or f.ends_with(".tscn"):
			out.append(dir.path_join(f))


func _fixture() -> void:
	QuietSectionFixture.arm()
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	add_child(td)
	await frames(4)
	var mf := td.mission
	if check(mf != null and td.stack != null, "the quiet drive has its section and a MissionFlow"):
		check(mf.rules == null and mf.plan == null and mf.director == null and mf.world == null,
			"no rules, plan, director or mission world")
		check(td.enemies_spawned and td.combat.squad.enemies.size() > 0, "the garrison stands (%d)" % td.combat.squad.enemies.size())
		var n0 := td.combat.squad.enemies.size()
		for i in 90:
			await get_tree().physics_frame
		eq(mf.evaluations, 0, "nothing is evaluated")
		eq(mf.opened.size(), 0, "nothing is released")
		check(mf.end_left < 0.0 and not mf.ended, "no outcome, no end")
		check(td.combat.squad.enemies.size() <= n0, "no units arrive")
		eq((mf.hud_model.build()["objective"] as String), "", "the HUD has no objective")
	td.queue_free()
	await frames(2)
	QuietSectionFixture.disarm()
