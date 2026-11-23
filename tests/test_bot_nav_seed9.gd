extends "res://tests/bot_nav_case.gd"
## The mission bot alone walks a whole solo mission on section seed 9 (tests/bot_nav_case.gd): no DEV travel.

const SERIAL := true   # a whole mission: run alone after the batch (no CPU contention)
const TEST_TIMEOUT := 240   # test_runner: 240 s instead of the 120 s default


func _init() -> void:
	seed_n = 9
	super()
