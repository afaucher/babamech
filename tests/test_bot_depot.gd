extends TestCase
## A LIVE mission bot (MissionBot, veteran, solo plan mode) uses a supply depot (MissionDepots; docs/design/
## pacing-director.md §2): right after the start its mech is hurt (torso to 35 %, a weapon pod destroyed), so
## MissionDepots.needs_core_of holds while it travels; it must walk to the nearest depot with cores on its deck, stand in
## claim range and get a core through the normal claim (MissionDepots.applied), within LIMIT s of game time; afterwards
## the torso is repaired and the pod rebuilt. (test_net_depot covers the claim rules with the AI detached.)

const SERIAL := true
const SEED := 7
const LIMIT := 90.0
const SPEED := 2.0


func _init() -> void:
	timeout_sec = LIMIT + 120.0


func setup() -> void:
	MissionScene.solo_launch = {"seed": SEED, "mode": MissionScene.MODE_STACK}
	MissionScene.bot_profile = "veteran"
	MissionScene.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	Engine.time_scale = SPEED
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	var w := 0.0
	while not td.loaded and w < 60.0:
		await get_tree().process_frame
		w += get_process_delta_time()
	await frames(4)
	var md: MissionDepots = td.mission.depots if td.mission != null else null
	if not check(td.bot != null and md != null, "the solo plan-mode drive runs the bot and has depots"):
		_end(td)
		return
	var pt := td.combat.player_target
	var k := td.stack.deck_at(td.mech.global_position)
	var near := md.nearest_with_cores(k, td.mech.global_position)
	if not check(not near.is_empty() and float(near["dist"]) < MissionBot.DEPOT_RANGE,
			"a depot with cores within reach on the start deck (%s)" % str(near)):
		_end(td)
		return
	pt.apply_damage(pt.max_hp["torso"] * 0.65, "torso", "test")
	pt.apply_damage(pt.max_hp["side_l"] * 2.0, "side_l", "test")
	check(MissionDepots.needs_core_of(pt, td.combat.rack), "the hurt mech needs a core")
	var torso0 := float(pt.hp["torso"])
	var tt := 0.0
	while tt < LIMIT and md.applied == 0 and not pt.disabled:
		await get_tree().physics_frame
		tt += Engine.time_scale / float(Engine.physics_ticks_per_second)
	print("[Test] depot: core after %.1f s game time; bot %s" % [tt, str(td.bot.stats())])
	check(int(td.bot.depot_visits) > 0, "the bot set off for a depot (%d)" % int(td.bot.depot_visits))
	if check(md.applied > 0, "the bot got a core within %.0f s (%.1f s, mode %s, %s)" % [LIMIT, tt, td.bot.mode, td.bot.goal_text]):
		check(float(pt.hp["torso"]) > torso0, "the core repaired the torso (%.0f -> %.0f)" % [torso0, float(pt.hp["torso"])])
		check(float(pt.hp["side_l"]) > 0.0, "the core rebuilt the destroyed pod")
	_end(td)


func _end(td: MissionScene) -> void:
	Engine.time_scale = 1.0
	MissionScene.bot_profile = ""
	td.queue_free()
	await frames(2)
	finish()
