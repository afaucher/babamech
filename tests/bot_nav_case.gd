extends TestCase
## Shared body of test_bot_nav_seed*: the mission bot (MissionBot, `--bot veteran`) ALONE in a solo stack mission on one
## seed, `--dev-fast-clear` on (CombatWorld.dev_enemy_damage 10x), `--dev-bot-travel` OFF: it has to WALK the whole
## mission through BotRoutePlanner's routes (ramps, shafts, glides over atriums). The real objectives mode (the only
## one) with a forced all-sweep plan (PLAN: every deck a sweep, the closest to the old "clear every deck", no reserve
## waves, a 3 s hold at the extraction portal). Checked within LIMIT s of game time:
## the mission is won, every deck was stood on, the hold is done, no DEV jump happened and every deck
## change was planned (ramp / shaft / glide, no "unplanned"). Prints per objective the time it finished and every deck
## change with how (the report's per-seed numbers), and no trap: no roof escape over TRAP_MAX s, no pushing without getting
## 2 m anywhere over twice that. Test speed: the drones and striders die at the start (`thin`), the sim runs at SPEED x.
## Restores the DEV statics and the time scale.

var seed_n := 4
var limit := 400.0
var ramps_only := false    ## plan with ramps only (MissionBot.ramps_only): every deck change must be a ramp
var thin := true           ## kill the drones and striders at the start (test speed; see setup)
const TRAP_MAX := 6.0      ## s: the longest roof escape allowed (and twice that pushing against something)
const PLAN := {"primary": "sweep", "bonus_max": 0, "waves_per_deck": 0, "hold": 3.0}   ## MissionFlow.test_plan


## Test speed: the sim runs at SPEED x (Engine.time_scale; physics steps of SPEED/60 s). 2x keeps the walking, ramps,
## drops and glides working (checked at 1x and 2x on seeds 4 and 9); BOT_SPEED=1 in the environment runs at full fidelity.
## Real 60 Hz mech physics on ramps and shafts is what test_city_stack_walk covers.
const SPEED := 2.0


static func speed() -> float:
	var v := OS.get_environment("BOT_SPEED")
	return float(v) if v.is_valid_float() and float(v) > 0.0 else SPEED


func _init() -> void:
	timeout_sec = limit + 60.0


func setup() -> void:
	MissionScene.solo_launch = {"seed": seed_n, "mode": MissionScene.MODE_STACK}
	MissionScene.bot_profile = "veteran"
	MissionScene.dev_bot_travel = false
	MissionFlow.test_plan = PLAN
	MissionBot.ramps_only = ramps_only
	CombatWorld.dev_enemy_damage = MissionScene.DEV_FAST_CLEAR
	Engine.time_scale = speed()
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(4)
	if not check(td.bot != null and td.mission != null and td.stack != null and td.mission.plan != null,
			"the solo stack drive runs the mission bot on the plan"):
		_restore()
		finish()
		return
	if thin:
		# Test speed: the easy mobile enemies (drones, striders) go at once; the hard cases stay on every deck (turrets and
		# troopers on roofs, troop squads in cover, tanks), which is where the walking, vantage and roof logic is tested.
		var gone := 0
		for e in td.combat.squad.enemies.duplicate():
			if is_instance_valid(e) and (str(e.name).contains("drone") or str(e.name).contains("strider")):
				e.apply_damage(1.0e7, e.core_component(), "test")
				gone += 1
		print("[Test] seed %d: thinned out %d mobile enemies" % [seed_n, gone])
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
		tt += Engine.time_scale / float(Engine.physics_ticks_per_second)
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
	print("[Test] seed %d: deck changes %s; by %s; dev jumps %d; stuck checks %d; blocked edges %d; plans %d; roof_max %.1f s; stall_max %.1f s" % [seed_n,
		str(st["deck_changes"]), str(st["by"]), int(st["dev_jumps"]), int(st["stuck"]), int(st["blocked"]), int(st["replans"]),
		float(st["roof_max"]), float(st["stall_max"])])
	check(rules.outcome == "won", "seed %d: the bot wins the mission within %.0f s (state %s, bot %s)" % [seed_n, limit,
		str(rules.state()), td.bot.goal_text])
	check((rules.state().get("done", []) as Array).has("hold"), "seed %d: the extraction hold is done" % seed_n)
	check(stood.size() == n, "seed %d: it stood on every deck (%s of %d)" % [seed_n, str(stood.keys()), n])
	eq(int(st["dev_jumps"]), 0, "seed %d: no DEV travel jump" % seed_n)
	check(float(st["roof_max"]) <= TRAP_MAX, "seed %d: never on a roof longer than %.0f s (longest %.1f s)" % [seed_n, TRAP_MAX,
		float(st["roof_max"])])
	check(float(st["stall_max"]) <= TRAP_MAX * 2.0, "seed %d: never pushing without getting anywhere longer than %.0f s (longest %.1f s)" % [
		seed_n, TRAP_MAX * 2.0, float(st["stall_max"])])
	eq(int((st["by"] as Dictionary).get("unplanned", 0)), 0, "seed %d: every deck change was planned (%s)" % [seed_n, str(st["by"])])
	if ramps_only:
		eq(int((st["by"] as Dictionary).get("ramp", 0)), n - 1, "seed %d: down every deck by ramp (%s)" % [seed_n, str(st["by"])])
	_restore()
	finish()


func _restore() -> void:
	Engine.time_scale = 1.0
	MissionScene.bot_profile = ""
	MissionScene.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	MissionBot.ramps_only = false
	MissionFlow.test_plan = {}
