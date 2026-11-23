extends "res://tests/bot_nav_case.gd"
## The mission bot alone walks a whole solo mission on section seed 4 (ramps between every deck) with RAMPS ONLY
## (MissionBot.ramps_only: no shaft drops, no glides; tests/bot_nav_case.gd): in at each ramp's mouth on the lane
## centre, down between the parapets, out past the foot. No DEV travel.

const SERIAL := true   # a whole mission: run alone after the batch (no CPU contention)
const TEST_TIMEOUT := 240   # test_runner: 240 s instead of the 120 s default


func _init() -> void:
	seed_n = 4
	ramps_only = true
	super()
