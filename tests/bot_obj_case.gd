extends TestCase
## Shared body of test_bot_obj_*: the mission bot (MissionBot, `--bot veteran`) ALONE plays a solo stack mission in plan
## mode (objectives on) on one seed, with no cheat: no DEV travel, no DEV fast clear, no teleport, every enemy at full
## strength. It must finish `goal_id` (an objective id; "" = win the mission) within `limit` s of game time. Checked: the
## objective is done (or the outcome is "won"), the mission was not lost, no DEV jump, and the plan still has the
## objective types the test was written for (`expect`: {id: type}; a plan change that moves them fails loudly: re-scan
## the seeds, docs/design/player-ai.md "Mission bot: objectives"). Prints when each objective finished, the bot's task
## list and its stats. The sim runs at SPEED x (Engine.time_scale, as tests/bot_nav_case.gd).

var seed_n := 1
var goal_id := ""                 ## objective id to finish; "" = the mission won
var expect := {}                ## {objective id: type} the seed must still have
var limit := 300.0              ## s of game time
var bonuses := false            ## MissionBot.bonuses (off: the per-type tests stay short)
const SPEED := 2.0


static func speed() -> float:
	var v := OS.get_environment("BOT_SPEED")
	return float(v) if v.is_valid_float() and float(v) > 0.0 else SPEED


func _init() -> void:
	timeout_sec = limit + 120.0   # TestCase's Timer runs on scaled (game) time: game s, like `limit`


func setup() -> void:
	TestDrive.solo_launch = {"seed": seed_n, "mode": TestDrive.MODE_STACK, "objectives": true}
	TestDrive.bot_profile = "veteran"
	TestDrive.dev_bot_travel = false
	MissionBot.bonuses = bonuses
	CombatWorld.dev_enemy_damage = 1.0
	Engine.time_scale = speed()
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await until_loaded(td)
	if not check(td.bot != null and td.mission != null and td.mission.plan != null, "the solo plan-mode drive runs the mission bot"):
		_restore()
		finish()
		return
	var rules := td.mission.rules
	var types := {}
	for o: Dictionary in td.mission.plan.objectives:
		types[o["id"]] = o["type"]
	for id: String in expect:
		if not eq(str(types.get(id, "")), str(expect[id]), "seed %d's %s (plan %s): re-scan the seeds" % [seed_n, id, str(types)]):
			_restore()
			finish()
			return
	var done_at := {}
	var tt := 0.0
	var wall := Time.get_ticks_msec()
	var asset_min := {}
	var deaths := 0
	var was_down := false
	while tt < limit:
		await get_tree().physics_frame
		tt += Engine.time_scale / float(Engine.physics_ticks_per_second)
		var down: bool = td.combat.player_target != null and td.combat.player_target.disabled
		if down and not was_down:
			deaths += 1
			print("[Test] seed %d: the bot's mech is down at %.1f s (task %s)" % [seed_n, tt, td.bot.task_id])
		was_down = down
		for o: Dictionary in rules.objectives:
			var id := str(o["id"])
			if not done_at.has(id) and rules.obj_state(id) in ["done", "failed"]:
				done_at[id] = snappedf(tt, 0.1)
				print("[Test] seed %d: %s (%s %s) %s at %.1f s" % [seed_n, id, o["role"], o["type"], rules.obj_state(id), tt])
		for id: String in td.mission.asset_hp:
			if rules.obj_state(id) == "active":
				asset_min[id] = minf(float(asset_min.get(id, 1.0)), float(td.mission.asset_hp[id]))
		if rules.outcome != "" or (goal_id != "" and rules.obj_state(goal_id) == "done"):
			break
	var st := td.bot.stats()
	print("[Test] seed %d: goal_id '%s' outcome '%s' after %.1f s game time (%.1f s wall); deaths %d; done %s; relay min hp %s" % [seed_n,
		goal_id, rules.outcome, tt, float(Time.get_ticks_msec() - wall) / 1000.0, deaths, str(done_at), str(asset_min)])
	print("[Test] seed %d: tasks %s; deck changes %s; dev jumps %d; stuck %d; ff holds %d" % [seed_n, str(st["tasks"]),
		str(st["deck_changes"]), int(st["dev_jumps"]), int(st["stuck"]), int(st["ff_holds"])])
	if goal_id == "":
		check(rules.outcome == "won", "seed %d: the bot wins within %.0f s (state %s, bot %s)" % [seed_n, limit,
			str(rules.state()), td.bot.goal_text])
	else:
		check(rules.obj_state(goal_id) == "done", "seed %d: the bot finishes %s within %.0f s (state %s, bot %s)" % [seed_n,
			goal_id, limit, str(rules.state()), td.bot.goal_text])
	check(rules.outcome != "lost", "seed %d: the mission is not lost (%s)" % [seed_n, rules.reason])
	eq(int(st["dev_jumps"]), 0, "seed %d: no DEV travel jump" % seed_n)
	_restore()
	td.queue_free()
	await frames(2)
	finish()


func until_loaded(td: TestDrive) -> void:
	var w := 0.0
	while not td.loaded and w < 60.0:
		await get_tree().process_frame
		w += get_process_delta_time()
	await frames(4)


func _restore() -> void:
	Engine.time_scale = 1.0
	TestDrive.bot_profile = ""
	TestDrive.dev_bot_travel = false
	MissionBot.bonuses = true
