extends "res://tests/bot_obj_case.gd"
## Mission bot, plan mode, no cheats (tests/bot_obj_case.gd): the whole mission: three flags, then the extraction hold (seed 6).
## Measured 2026-11-23 after the WaveDirector changes (3 runs, 2x sim speed, bonuses off): 247.7 / 321.0 / 321.0 (the 321 s runs: downed in the hold, respawned on deck 0, walked back) s game time; after Environment's downtown zone + stand points (_plan_local): 249.0 x3. Limit ~1.75x the worst.

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 400   # test_runner: wall s (limit / 2x speed + load + slack)


func _init() -> void:
	seed_n = 6
	goal_id = ""
	expect = {"d0_p": "flag", "d1_p": "flag", "d2_p": "flag", "hold": "hold"}
	limit = 560.0
	super()
