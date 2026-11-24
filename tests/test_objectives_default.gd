extends TestCase
## Objectives are the default mission (user, 2026-11-23: "make the objectives the default when you run the game").
## GameSettings "objectives" defaults to true; MissionFlow.objectives_wanted: `--no-objectives` -> off (the old
## clear-and-extract mission), `--objectives` -> on (kept as a no-op for old scripts), else the setting; a flag overrides the
## setting. In a crew every machine plays the host's mode: TestDrive takes mission.launch params.objectives and ignores its
## own flags when crewed (checked here on the code path: a crewed TestDrive never reads --objectives / --no-objectives).


func setup() -> void:
	check(bool(GameSettings.DEFAULTS["objectives"]), "the setting defaults to objectives on")
	eq(str(GameSettings.SECTIONS["objectives"]), "crew", "it is a crew option now (no longer dev)")
	var on := {"objectives": true}
	var off := {"objectives": false}
	check(MissionFlow.objectives_wanted(PackedStringArray(), {}), "no flag, no setting: objectives")
	check(MissionFlow.objectives_wanted(PackedStringArray(), on), "setting on: objectives")
	check(not MissionFlow.objectives_wanted(PackedStringArray(), off), "setting off: the old mission")
	check(not MissionFlow.objectives_wanted(PackedStringArray(["--no-objectives"]), on), "--no-objectives overrides the setting")
	check(MissionFlow.objectives_wanted(PackedStringArray(["--objectives"]), off), "--objectives overrides the setting")
	check(not MissionFlow.objectives_wanted(PackedStringArray(["--objectives", "--no-objectives"]), on),
		"--no-objectives wins over --objectives")
	# A crewed drive follows the host's params, never its own flags (source check: the crewed branch reads params only).
	var src := FileAccess.get_file_as_string("res://scripts/game/test_drive.gd")
	check(src.contains('objectives = bool(params.get("objectives", false))'), "crewed: objectives from the host's launch params")
	check(src.contains('if not crewed and args.has("--objectives")') and src.contains("elif not crewed and plain_entry"),
		"the machine's own flags apply only when not crewed")
	finish()
