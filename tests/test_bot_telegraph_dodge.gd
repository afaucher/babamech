extends TestCase
## PlayerBot's telegraph bookkeeping (code audit 2026-11): every telegraph INSTANCE gets its own reaction roll. An enemy
## that cancels a telegraph (lost sight) and starts another keeps its _shot_index, so the old "enemy:shot" key blocked
## the second dodge. Also: the per-enemy records are pruned SEEN_TTL after the last sighting (they used to grow forever).
## Drives PlayerBot._telegraph_is_new / _prune_seen_telegraphs directly with a bare EnemyBase (no scene, no physics).

const DT := 1.0 / 60.0


func setup() -> void:
	var bot := PlayerBot.new()
	var e := EnemyBase.new()
	e._shot_index = 3

	# First telegraph: new once, then the same instance for its whole wind-up.
	_tick(bot, e, 0.0)
	check(bot._telegraph_is_new("e1", e), "first telegraph is new")
	for i in 30:
		_tick(bot, e, DT)
		check(not bot._telegraph_is_new("e1", e), "same telegraph frame %d is not new" % i)

	# Cancelled (lost sight: the timer resets, no shot fired), restarted 1 s later, seen every frame: new again.
	bot._sim_t += 1.0
	e._telegraph_t = 0.0
	check(bot._telegraph_is_new("e1", e), "restarted telegraph (same shot index, timer reset) is new")
	_tick(bot, e, DT)
	check(not bot._telegraph_is_new("e1", e), "restarted telegraph seen again is not new")

	# Restart seen only after a sight gap longer than its own elapsed time (timer looks larger): its start moved, new.
	bot._sim_t += 3.0
	e._telegraph_t = 0.4
	check(bot._telegraph_is_new("e1", e), "restart seen late (start moved) is new")

	# Same instance re-seen after a short gap (sight blinked, enemy kept winding up): not new.
	bot._sim_t += 0.5
	e._telegraph_t += 0.5
	check(not bot._telegraph_is_new("e1", e), "same telegraph after a sight gap is not new")

	# It fired (shot index moved) and telegraphs again: new.
	e._shot_index = 4
	_tick(bot, e, DT)
	check(bot._telegraph_is_new("e1", e), "telegraph after a shot is new")

	# A second enemy is tracked on its own.
	var e2 := EnemyBase.new()
	e2._shot_index = 3
	e2._telegraph_t = e._telegraph_t
	check(bot._telegraph_is_new("e2", e2), "another enemy's telegraph is new")
	eq(bot._seen_telegraphs.size(), 2, "one record per enemy")

	# Records age out SEEN_TTL after their last sighting; a fresh one stays.
	bot._sim_t += PlayerBot.SEEN_TTL + 0.1
	e._telegraph_t = 0.0
	bot._telegraph_is_new("e1", e)
	bot._prune_seen_telegraphs()
	check(bot._seen_telegraphs.has("e1"), "recently seen record kept")
	check(not bot._seen_telegraphs.has("e2"), "stale record pruned")
	eq(bot._seen_telegraphs.size(), 1, "seen-set does not grow")

	e.free()
	e2.free()
	bot.free()
	finish()


func _tick(bot: PlayerBot, e: EnemyBase, dt: float) -> void:
	bot._sim_t += dt
	e._telegraph_t += dt
