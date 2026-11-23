extends "res://tests/bot_obj_case.gd"
## Mission bot, plan mode, no cheats (tests/bot_obj_case.gd): the deck 0 flag, down a shaft, then the deck 1 defend (seed 7: flag / defend / defend).
## Measured 2026-11-23 after the WaveDirector changes (3 runs, 2x sim speed, bonuses off): 205.3 / 149.8 / 149.8 s game time; after Environment's downtown zone + stand points (_plan_local): 173.8 x3. Limit ~1.75x the worst.

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 300   # test_runner: wall s (limit / 2x speed + load + slack)


func _init() -> void:
	seed_n = 7
	goal_id = "d1_p"
	expect = {"d0_p": "flag", "d1_p": "defend"}
	limit = 360.0
	super()
