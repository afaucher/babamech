extends "res://tests/bot_nav_up_case.gd"
## Seed 4 (ramps): from deck 2 back up to deck 1 by ramp, no DEV travel (tests/bot_nav_up_case.gd).

const SERIAL := true   # a bot run: alone after the batch
const TEST_TIMEOUT := 240


func _init() -> void:
	seed_n = 4
	super()
