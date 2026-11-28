extends NetTest
## A hangar bot being helped (playtest R2.6; BotAid, MissionBot _drone_leash, DownedRules). A host alone in its crew
## (online, no joiner) seats two veteran bots; seed 19 gives bot -1 a repair drone and bot -2 none (BotLoadout.pick).
## 1. LEASH: bot -1 is held still (its CrewBot runs no AI: inputs zeroed) and launches its drone; bot -2 is hurt. While
##    the drone repairs it, bot -2 must stay within the drone's radius of bot -1 (it keeps fighting and walking: the
##    leash only stops it leaving, so leash_t grows as its objective pulls it away). Once repaired in full it is free.
## 2. WAIT: bot -2 walks off while bot -1 is still held, past WALK_OFF m; it is knocked down there and bot -1's AI is
##    given back HOLD_AFTER s later. Bot -2 must not redeploy past the old fixed DownedRules.BOT_REVIVE_WAIT while bot -1
##    comes, and bot -1 must stand it up (bot -1 `revives` 1, bot -2 never redeploying) within REVIVE_TIMEOUT s.

const PEERS := 1
const LINKS := ["off"]
const NET_TIMEOUT := 220   # test_runner reads this literal
const SEED := 19
const LEASH_WATCH := 12.0  ## s bot -2 is watched while the drone repairs it
const WALK_OFF := 70.0     ## m bot -2 walks away from the held bot -1 before it is knocked down
const WALK_TIMEOUT := 60.0
const REVIVE_TIMEOUT := 70.0
const HOLD_AFTER := 5.0    ## s bot -1 stays held after bot -2 goes down (inside BotAid.WAIT_GRACE)

var td: MissionScene


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var a_id := Session.add_bot("veteran")
	var b_id := Session.add_bot("veteran")
	check(a_id == -1 and b_id == -2, "the host seats two bots")
	var pa := BotLoadout.pick(SEED, 1, "veteran")["loadout"] as Dictionary
	var pb := BotLoadout.pick(SEED, 2, "veteran")["loadout"] as Dictionary
	if not check(pa.values().has(DownedRules.REVIVER) and not pb.values().has(DownedRules.REVIVER),
			"seed %d: bot -1 carries a repair drone, bot -2 none (%s / %s)" % [SEED, str(pa), str(pb)]):
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
	var world := td.combat.world
	var a_ai := ca.ai
	ca.ai = null   # held: CrewBot zeroes its inputs while it has no AI
	# 1. LEASH
	var slot := -1
	for i in ca.rack.slot_count():
		if ca.rack.weapons[i] == DownedRules.REVIVER and ca.rack.can_launch(i):
			slot = i
	if not check(slot >= 0 and ca.rack.activate(slot + 1), "bot -1 launches its drone"):
		return
	var d := world.drone_of("player%d" % a_id)
	check(d != null, "the drone is out")
	for c: String in ["torso", "leg_l", "leg_r"]:
		cb.target.apply_damage(float(cb.target.max_hp[c]) * 0.6, c, "test")
	check(not cb.target.disabled and RepairDrone.repairable(cb.target), "bot -2 is hurt, standing")
	await until(func() -> bool: return d.repairing(), 3.0)
	var r := BotAid.radius_of(d)
	var worst := 0.0
	var watched := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(LEASH_WATCH * 1000.0):
		await get_tree().physics_frame
		if d.repairing() and RepairDrone.repairable(cb.target):
			worst = maxf(worst, d.reach_to(cb.mech.global_position))
			watched += 1.0 / Engine.physics_ticks_per_second
	print("[Test] leash: worst %.1f m of %.0f, held %.1f s of %.1f s watched (mode %s)" % [worst, r, cb.ai.leash_t, watched,
		cb.ai.mode])
	check(watched > LEASH_WATCH * 0.8, "the drone repaired bot -2 throughout (%.1f s)" % watched)
	check(worst <= r, "bot -2 stayed within the drone's %.0f m while repaired (farthest %.1f m)" % [r, worst])
	check(cb.ai.leash_t > 0.0, "the leash held it back at least once (its objective pulls it away)")
	# 2. WAIT: free bot -2 (repaired), let it walk off from the held bot -1.
	cb.target.repair_all()
	var far := func() -> float: return cb.mech.global_position.distance_to(ca.mech.global_position)
	if not check(await until(func() -> bool: return float(far.call()) > WALK_OFF, WALK_TIMEOUT),
			"bot -2 walks %.0f m away once repaired (%.0f m, mode %s)" % [WALK_OFF, float(far.call()), cb.ai.mode]):
		return
	cb.target.apply_damage(float(cb.target.max_hp["torso"]) * 3.0, "torso", "test")
	check(cb.target.disabled, "bot -2 is down %.0f m from bot -1" % float(far.call()))
	check(td.downed.can_revive(a_id), "bot -1 can revive (a charge left or its drone on duty)")
	t0 = Time.get_ticks_msec()
	await sleep(HOLD_AFTER)   # bot -1 still held a moment: it sets off late, so the walk runs past the old fixed wait
	check(cb.target.disabled and not cb.target.redeploying, "bot -2 still waits while bot -1 is held (%.0f s)" % HOLD_AFTER)
	ca.ai = a_ai   # bot -1 flies again: it should come
	var redeployed := [false]
	var stood := false
	while Time.get_ticks_msec() - t0 < int(REVIVE_TIMEOUT * 1000.0):
		await get_tree().physics_frame
		if cb.target.redeploying:
			redeployed[0] = true
			break
		if not cb.target.disabled:
			stood = true
			break
	var waited := (Time.get_ticks_msec() - t0) / 1000.0
	print("[Test] wait: %.1f s, verdict %s, bot -1 log %s, mode %s" % [waited, cb.ai.aid.verdict if cb.ai.aid != null else "?",
		str(a_ai.revive_log), a_ai.mode])
	check(not redeployed[0], "bot -2 waits for the reviver instead of redeploying (after %.1f s, verdict %s)" % [waited,
		cb.ai.aid.verdict if cb.ai.aid != null else "?"])
	check(waited > DownedRules.BOT_REVIVE_WAIT, "it waited past the old fixed %.0f s (%.1f s)" % [DownedRules.BOT_REVIVE_WAIT,
		waited])
	check(stood, "bot -1 stands bot -2 up within %.0f s (%.1f s)" % [REVIVE_TIMEOUT, waited])
	await until(func() -> bool: return a_ai.revives > 0, 3.0)
	eq(a_ai.revives, 1, "bot -1's revive counts")
	print("[Test] bot -1: %s" % str(a_ai.stats()))
