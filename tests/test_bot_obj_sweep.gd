extends "res://tests/bot_obj_case.gd"
## Mission bot, plan mode, no cheats (tests/bot_obj_case.gd): the deck 0 sweep with its waves (seed 4: sweep / flag / flag).
## Measured 2026-11-23 after the WaveDirector changes (3 runs, 2x sim speed, bonuses off): 117.0 / 117.0 / 117.0 s game time; after Environment's downtown zone + stand points (_plan_local): 111.7 x3. After the hole guard + hold survival (and the day's layouts): 153.8 x3; limit 270 (~1.75x).

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 240   # test_runner: wall s (limit / 2x speed + load + slack)


func _init() -> void:
	seed_n = 4
	goal_id = "d0_p"
	expect = {"d0_p": "sweep"}
	limit = 270.0
	super()
