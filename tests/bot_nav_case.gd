extends TestCase
## Shared body of test_bot_nav_seed*: the mission bot (MissionBot, `--bot veteran`) ALONE in a solo stack mission on one
## seed, `--dev-fast-clear` on (CombatWorld.dev_enemy_damage 10x), `--dev-bot-travel` OFF: it has to WALK the whole
## mission through BotRoutePlanner's routes (ramps, shafts, glides over atriums). Checked within LIMIT s of game time:
## the mission is won, every deck was stood on, the extraction objective is done, no DEV jump happened and every deck
## change was planned (ramp / shaft / glide, no "unplanned"). Prints per objective the time it finished and every deck
## change with how (the report's per-seed numbers). Restores the DEV statics.

var seed_n := 4
var limit := 400.0
var ramps_only := false    ## plan with ramps only (MissionBot.ramps_only): every deck change must be a ramp


func _init() -> void:
	timeout_sec = limit + 60.0


func setup() -> void:
	TestDrive.solo_launch = {"seed": seed_n, "mode": TestDrive.MODE_STACK}
	TestDrive.bot_profile = "veteran"
	TestDrive.dev_bot_travel = false
	MissionBot.ramps_only = ramps_only
	CombatWorld.dev_enemy_damage = TestDrive.DEV_FAST_CLEAR
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(4)
	if not check(td.bot != null and td.mission != null and td.stack != null, "the solo stack drive runs the mission bot"):
		_restore()
		finish()
		return
	var rules := td.mission.rules
	var n := td.stack.decks.size()
	var stood := {}
	var cur := rules.current()
	var started := 0.0
	var times: Array[String] = []
	var tt := 0.0
	var wall := Time.get_ticks_msec()
	while tt < limit:
		await get_tree().physics_frame
		tt += 1.0 / float(Engine.physics_ticks_per_second)
		if td.mech.is_on_floor():
			stood[td.stack.deck_at(td.mech.global_position)] = true
		var c := rules.current()
		if c != cur:
			times.append("%s %.0f s (+%.0f)" % [cur, tt, tt - started])
			print("[Test] seed %d: %s done at %.1f s (%.1f s for it)" % [seed_n, cur, tt, tt - started])
			started = tt
			cur = c
		if rules.outcome != "":
			if cur != "":
				times.append("%s %.0f s (+%.0f)" % [cur, tt, tt - started])
			break
	var st := td.bot.stats()
	if rules.outcome != "won":
		for e in td.combat.squad.enemies:
			if is_instance_valid(e) and not e.destroyed():
				var a := td.stack.to_deck_arc(e.global_position)
				var parts := []
				for s: Dictionary in e.world_spheres():
					var sa := td.stack.to_deck_arc(s["center"])
					parts.append("%s hp %.0f at x %.0f s %.0f h %.1f" % [s["component"], float(e.hp.get(s["component"], -1.0)),
						float(sa["x"]), float(sa["s"]), float(sa["h"])])
				print("[Test] left: %s deck %d x %.0f s %.0f h %.1f ai %s | %s" % [e.name, int(a["deck"]), float(a["x"]),
					float(a["s"]), float(a["h"]), e.ai_state, ", ".join(parts)])
	print("[Test] seed %d: outcome '%s' after %.1f s game time (%.1f s wall); objectives %s" % [seed_n, rules.outcome, tt,
		float(Time.get_ticks_msec() - wall) / 1000.0, ", ".join(times)])
	print("[Test] seed %d: deck changes %s; by %s; dev jumps %d; stuck checks %d; blocked edges %d; plans %d" % [seed_n,
		str(st["deck_changes"]), str(st["by"]), int(st["dev_jumps"]), int(st["stuck"]), int(st["blocked"]), int(st["replans"])])
	check(rules.outcome == "won", "seed %d: the bot wins the mission within %.0f s (state %s, bot %s)" % [seed_n, limit,
		str(rules.state()), td.bot.goal_text])
	check((rules.state().get("done", []) as Array).has("extract"), "seed %d: extraction reached" % seed_n)
	check(stood.size() == n, "seed %d: it stood on every deck (%s of %d)" % [seed_n, str(stood.keys()), n])
	eq(int(st["dev_jumps"]), 0, "seed %d: no DEV travel jump" % seed_n)
	eq(int((st["by"] as Dictionary).get("unplanned", 0)), 0, "seed %d: every deck change was planned (%s)" % [seed_n, str(st["by"])])
	if ramps_only:
		eq(int((st["by"] as Dictionary).get("ramp", 0)), n - 1, "seed %d: down every deck by ramp (%s)" % [seed_n, str(st["by"])])
	_restore()
	finish()


func _restore() -> void:
	TestDrive.bot_profile = ""
	TestDrive.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	MissionBot.ramps_only = false
