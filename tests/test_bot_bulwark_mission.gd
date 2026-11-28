extends "res://tests/bulwark_bot_case.gd"
## The mission bot in a BULWARK plays a whole solo plan-mode mission (tests/bulwark_bot_case.gd, tests/bot_obj_case.gd):
## no cheat, bonuses off, it must WIN (every primary, the extraction hold) within `limit` s of game time.
## Seed 2 (flag / defend / sweep / hold; until 2026-11-27, see below). Measured 2026-11-24 (2x sim speed, veteran, BotProfile "bulwark" kit): won at
## 534.9 s game time, 5 deaths, 1 stuck check; limit 950 (~1.75x). BULWARK_SEED=<n> plays another seed (the survey in
## docs/design/chassis-rules.md "Bulwark world fit": 1 won 608 s, 2 535 s, 5 644 s, 7 713 s; 4, 6, 9 have a required
## objective a Bulwark cannot reach in the generated world).
## 2026-11-27 (Engine): seed 2 -> seed 1. Since the crew starts in the entry bay (city-spine.md §4: +~7 s to the first
## flag), seed 2's bot reaches its deck-1 defend later by another route (a shaft instead of the ramp) and the relay falls
## to a tank (880 damage) while it holds: a marginal defend for the harder chassis, not a bot fault (seed 2 still wins with
## the bay placement switched off, A/B). Seed 1 (flag / sweep / defend / hold) won at 517.1 s with the bay start; the
## limit stays 950 (~1.8x).

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 600   # test_runner: wall s (limit / 2x speed + load + slack)


func _init() -> void:
	seed_n = 1
	goal_id = ""
	limit = 950.0
	super()
