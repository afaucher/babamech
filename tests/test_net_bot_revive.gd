extends NetTest
## A hangar bot revives a downed crewmate (MissionBot REVIVE; DownedCrew / DownedRules, docs/design/pacing-director.md
## §4). A host alone in its crew (online, no joiner) seats one veteran bot; seed 19 gives it a repair drone
## (BotLoadout.pick(19, 1)). After the barrier, the host's own mech (nobody flies it, so it never holds SPACE to respawn)
## is knocked down near the bot: the bot must go to it, launch its drone and stand it up (the host's PlayerTarget no longer
## disabled, the bot's `revives` 1) within REVIVE_TIMEOUT s.
## Then the decline case: the bot is hurt under its survival_hp, live enemies are moved next to the host's mech and the
## mech is knocked down again: the bot must decline (revive_declines, a "decline" entry) and not set off.

const PEERS := 1
const LINKS := ["off"]
const NET_TIMEOUT := 200   # test_runner reads this literal
const SEED := 19
const REVIVE_TIMEOUT := 60.0

var td: MissionScene


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var id := Session.add_bot("veteran")
	check(id == -1, "the host seats a bot")
	var pick := BotLoadout.pick(SEED, 1, "veteran")
	if not check((pick["loadout"] as Dictionary).values().has(DownedRules.REVIVER), "seed %d gives the bot a repair drone (%s)"
			% [SEED, str(pick["loadout"])]):
		return
	check(Session.mission.host_launch(SEED), "the host launches")
	await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0)
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		return
	var cb := td.crew_bots.get(id) as CrewBot
	if not check(cb != null and td.downed != null, "the host runs the bot and the downed layer"):
		return
	await until(func() -> bool: return cb.ai != null, 5.0)
	var host_pt := td.combat.player_target
	var me := MechSpawn.owner_of(td.mech)
	# The bot stays near: knock the host down beside it (the crew spawns together).
	host_pt.apply_damage(host_pt.max_hp["torso"] * 3.0, "torso", "test")
	check(host_pt.disabled, "the host's mech is down")
	check(td.downed.can_revive(id), "the bot can revive (drone with a charge)")
	var stood := await until(func() -> bool: return not host_pt.disabled, REVIVE_TIMEOUT)
	print("[Test] revive: %s" % str(cb.ai.revive_log))
	check(stood, "the bot stands the host up within %.0f s (log %s, mode %s)" % [REVIVE_TIMEOUT, str(cb.ai.revive_log), cb.ai.mode])
	await until(func() -> bool: return cb.ai.revives > 0, 3.0)
	eq(cb.ai.revives, 1, "the revive counts")
	# Decline: the bot low, enemies at the wreck.
	await until(func() -> bool: return cb.ai._rv_peer == 0, 5.0)
	cb.target.apply_damage(cb.target.max_hp["torso"] * 0.7, "torso", "test")
	var moved := 0
	for e: Variant in td.combat.squad.enemies:
		if moved >= 3 or not cb.ai._live(e):
			continue
		var en := e as EnemyBase
		en.global_position = td.mech.global_position + Vector3(12.0 + 6.0 * moved, 0.0, 8.0)
		en.spawn_deck = td.stack.deck_at(td.mech.global_position)
		moved += 1
	check(moved >= MissionBot.REVIVE_HOT_LOW, "enemies moved next to the host's mech (%d)" % moved)
	var declines0 := cb.ai.revive_declines
	await sleep(DownedRules.REVIVE_INVULN + 0.5)   # a revived mech can't be hurt for a moment
	host_pt.apply_damage(host_pt.max_hp["torso"] * 3.0, "torso", "test")
	check(host_pt.disabled, "the host's mech is down again")
	check(await until(func() -> bool: return cb.ai.revive_declines > declines0, 5.0),
		"the low bot declines the hot wreck (log %s)" % str(cb.ai.revive_log))
	eq(cb.ai._rv_peer, 0, "it doesn't set off for it")
	print("[Test] bot: %s" % str(cb.ai.stats()))
	print("[Test] host pilot %d" % me)
