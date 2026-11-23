extends "res://tests/bot_nav_case.gd"
## The mission bot alone walks a whole solo mission on section seed 4 (tests/bot_nav_case.gd): no DEV travel.

const SERIAL := true   # a whole mission (60-100 s wall at --fixed-fps): run alone after the batch so CPU contention cannot push it past the 120 s timeout


func _init() -> void:
	seed_n = 4
	super()
