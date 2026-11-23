extends "res://tests/bot_obj_case.gd"
## Mission bot, plan mode, no cheats (tests/bot_obj_case.gd): flag on deck 0 (seed 6: flag / flag / flag).
## Measured 2026-11-23 after the WaveDirector changes (3 runs, 2x sim speed, bonuses off): 38.6 / 38.6 / 38.6 s game time; after Environment's downtown zone + stand points (_plan_local): 38.6 x3. Limit ~1.75x the worst.

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 180   # test_runner: wall s (limit / 2x speed + load + slack)


func _init() -> void:
	seed_n = 6
	goal_id = "d0_p"
	expect = {"d0_p": "flag"}
	limit = 70.0
	super()
