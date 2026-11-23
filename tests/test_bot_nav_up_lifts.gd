extends "res://tests/bot_nav_up_case.gd"
## Seed 9 (lifts only, no ramp up): from deck 2 to deck 1 by DEV travel, with its [Flow] note (tests/bot_nav_up_case.gd).

const SERIAL := true   # a bot run: alone after the batch
const TEST_TIMEOUT := 240


func _init() -> void:
	seed_n = 9
	dev = true
	expect_by = "dev travel"
	super()
