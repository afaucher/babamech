extends "res://tests/bot_obj_case.gd"
## Shared body of test_bot_bulwark_*: tests/bot_obj_case.gd (the mission bot ALONE plays a solo plan-mode stack mission,
## no cheat) with the local mech a BULWARK (the heavy: 3.6 m capsule, hop-only thrust; MechCatalog "bulwark"). The chassis
## comes from the settings the test drive reads (GameSettings.path: the per-test, per-process file Boot gave this run,
## Boot.test_settings_file, so parallel runs never share one; restored after),
## with BotProfile's "bulwark" kit unless `loadout` is set. Env BULWARK_SEED overrides `seed_n` (survey runs).

var chassis := "bulwark"
var loadout := {}
var _saved_path := ""


func setup() -> void:
	var v := OS.get_environment("BULWARK_SEED")
	if v.is_valid_int():
		seed_n = int(v)
	_saved_path = GameSettings.path
	if Boot.test_settings_file == "":   # not started by Boot --run-test: still a file of this process alone
		GameSettings.path = "user://test_settings/bulwark_bot_p%d.cfg" % OS.get_process_id()
	var d := GameSettings.DEFAULTS.duplicate(true)
	d["chassis"] = chassis
	d["loadout"] = loadout if not loadout.is_empty() else BotProfile.get_loadout(chassis)
	GameSettings.save_settings(d)
	print("[Test] chassis %s, loadout %s, seed %d" % [chassis, str(d["loadout"]), seed_n])
	await super.setup()


func _restore() -> void:
	super._restore()
	if _saved_path != "":
		GameSettings.path = _saved_path
