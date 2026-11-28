extends NetTest
## A bot leaves a self-reviving crewmate alone (playtest R2.6 with R2.9; MissionBot _self_reviving, WeaponRack
## SELF-REVIVE, CombatWorld.self_reviving). A host alone in its crew (online, no joiner) seats a veteran and a brawler
## bot; seed 35 gives both a repair drone (BotLoadout.pick). After the barrier bot -2 is knocked down beside bot -1 (the
## crew spawns together): its own drone launches and stands it up. Bot -1, who could revive it, must never set off for
## it (no "go" entry for -2 in its revive_log, revive_self_skips counting the skip), and bot -2 must not redeploy.

const PEERS := 1
const LINKS := ["off"]
const NET_TIMEOUT := 150   # test_runner reads this literal
const SEED := 35
const SELF_TIMEOUT := 12.0  ## s for the self-revive (rise 0.5 + 4 s of beam, with margin)

var td: MissionScene


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var a_id := Session.add_bot("veteran")
	var b_id := Session.add_bot("brawler")
	check(a_id == -1 and b_id == -2, "the host seats two bots")
	var pa := BotLoadout.pick(SEED, 1, "veteran")["loadout"] as Dictionary
	var pb := BotLoadout.pick(SEED, 2, "brawler")["loadout"] as Dictionary
	if not check(pa.values().has(DownedRules.REVIVER) and pb.values().has(DownedRules.REVIVER),
			"seed %d: both bots carry a repair drone (%s / %s)" % [SEED, str(pa), str(pb)]):
		return
	check(Session.mission.host_launch(SEED), "the host launches")
	await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0)
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		return
	var ca := td.crew_bots.get(a_id) as CrewBot
	var cb := td.crew_bots.get(b_id) as CrewBot
	if not check(ca != null and cb != null and td.downed != null, "the host runs both bots and the downed layer"):
		return
	await until(func() -> bool: return ca.ai != null and cb.ai != null, 5.0)
	await sleep(1.0)
	var world := td.combat.world
	var pid := "player%d" % b_id
	check(td.downed.can_revive(a_id), "bot -1 can revive")
	cb.target.apply_damage(float(cb.target.max_hp["torso"]) * 3.0, "torso", "test")
	check(cb.target.disabled, "bot -2 is down")
	check(await until(func() -> bool: return world.self_reviving(pid), 2.0), "bot -2's own drone launches to revive it")
	var redeployed := [false]
	var stood := await until(func() -> bool:
		if cb.target.redeploying:
			redeployed[0] = true
		return not cb.target.disabled, SELF_TIMEOUT)
	print("[Test] self-revive: stood %s, bot -1 log %s, skips %d" % [str(stood), str(ca.ai.revive_log), ca.ai.revive_self_skips])
	check(stood, "bot -2 stands up on its own drone within %.0f s" % SELF_TIMEOUT)
	check(not redeployed[0], "bot -2 never redeploys")
	var went := false
	for e: Dictionary in ca.ai.revive_log:
		if int(e["peer"]) == b_id and str(e["kind"]) == "go":
			went = true
	check(not went, "bot -1 never sets off to revive the self-reviving bot -2 (log %s)" % str(ca.ai.revive_log))
	check(ca.ai.revive_self_skips > 0, "bot -1 saw the wreck and left it to its own drone (%d)" % ca.ai.revive_self_skips)
	eq(ca.ai.revives, 0, "bot -1 counts no revive")
