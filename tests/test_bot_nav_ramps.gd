extends "res://tests/bot_nav_case.gd"
## The mission bot alone walks a whole solo mission on section seed 4 (ramps between every deck) with RAMPS ONLY
## (MissionBot.ramps_only: no shaft drops, no glides; tests/bot_nav_case.gd): in at each ramp's mouth on the lane
## centre, down between the parapets, out past the foot. No DEV travel.

const SERIAL := true   # a whole mission (60-100 s wall at --fixed-fps): run alone after the batch so CPU contention cannot push it past the 120 s timeout


func _init() -> void:
	seed_n = 4
	ramps_only = true
	super()
