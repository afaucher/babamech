extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## The repair drone's self-revive and weapon rebuild across machines (2026-11-26, R2.9 / R2.1; RepairDrone SELF-REVIVE,
## WeaponRack._self_revive, PlayerTarget.heal, CombatNet "combat.drone" "s"), a real crew mission of 2 + one host bot,
## once per link (off, coast). Host A carries a repair drone; seed 19 gives the bot (pilot -1) one too.
## 1. R2.1: A's laser hardpoint is destroyed; B's puppet of A shows it destroyed. A launches its drone: A's own machine
##    rebuilds the hardpoint (the slot usable again, deselected) and B's puppet mirror shows it alive again.
## 2. A goes down: A's ordinary drone dies, ONE self-revive drone launches on A (the last charge, "self"), B gets it with
##    the flag, sees A downed, draws the scan on A's puppet, self_reviving("player1") is true on both machines; A stands up
##    with no input and self_reviving goes false on both.
## 3. The host bot goes down: its rack (CrewBot) self-revives it; B sees the bot's drone with the flag, the scan on the
##    bot's puppet, self_reviving("player-1") true then false, and the bot standing again.

const PEERS := 2
const NET_TIMEOUT := 150   # test_runner reads this literal
const SEED := 19
const REVIVE_WAIT := 9.0          ## s: rise + REVIVE_TIME (4.5) with room for snapshots

var td: MissionScene
var world: CombatWorld


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var lo := Session.local_loadout()
	lo["back"] = "repair_drone"
	Session.set_profile(Session.player_name, Session.local_head(), Session.local_chassis(), "", lo)   # A carries the drone
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	var bot := Session.add_bot("veteran")
	check(bot == -1, "the host seats a bot")
	check((BotLoadout.pick(SEED, 1, "veteran")["loadout"] as Dictionary).values().has("repair_drone"),
		"seed %d gives the bot a repair drone" % SEED)
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 40.0), "the client is ready"):
		return
	var b := int(peers_with("ready")[0])
	var me := "player%d" % Session.local_id()
	var pt := td.combat.player_target
	var rack := td.combat.rack
	var back := rack.hardpoints.find("back")
	if not check(back >= 0 and rack.weapons[back] == "repair_drone" and pt.max_hp.has("side_l"),
			"A carries the repair drone on its back and a side_l weapon"):
		return
	# 1. R2.1: the destroyed laser hardpoint, rebuilt by A's drone, seen on B's puppet.
	pt.apply_damage(PlayerTarget.WEAPON_HP, "side_l", "test")
	check(pt.is_slot_destroyed("side_l"), "A's side_l is destroyed")
	command(b, "probe", {"peer": Session.local_id(), "hp": "side_l", "want": true, "key": "probe_dead"})
	if check(await wait_reports("probe_dead", 1, 10.0), "B reports A's side_l"):
		check(bool(reported(b, "probe_dead")), "B's puppet of A shows side_l destroyed")
	check(rack.activate(back + 1), "A launches its drone")
	var d_old := world.drone_of(me)
	check(d_old != null and not d_old.is_self(), "an ordinary drone")
	check(await until(func() -> bool: return not pt.is_slot_destroyed("side_l"), 10.0), "A's drone rebuilt side_l")
	await sleep(0.1)
	check(rack.usable(1) and not rack.enabled[0], "A's laser slot is usable again, deselected")
	command(b, "probe", {"peer": Session.local_id(), "hp": "side_l", "want": false, "key": "probe_alive"})
	if check(await wait_reports("probe_alive", 1, 10.0), "B reports A's side_l again"):
		check(not bool(reported(b, "probe_alive")), "B's puppet of A shows side_l alive again (snapshot)")
	# 2. A goes down: the self-revive.
	command(b, "watch", {"id": me, "peer": Session.local_id(), "key": "watch_a"})
	await sleep(0.3)
	pt.apply_damage(pt.max_hp["torso"] * 3.0, "torso", "test")
	check(pt.disabled, "A is down")
	check(await until(func() -> bool: return world.drone_of(me) != null and world.drone_of(me).is_self(), 2.0),
		"A's self-revive drone launched")
	check(not is_instance_valid(d_old) or not d_old in world.effects, "A's ordinary drone died with its launcher")
	eq(world.drones_of(me).size(), 1, "one drone of A out")
	eq(rack.charges[back], 0, "the last charge spent")
	check(world.self_reviving(me), "A: self_reviving(%s) true" % me)
	check(await until(func() -> bool: return not pt.disabled, REVIVE_WAIT), "A stood up with no input")
	await sleep(0.3)
	check(not world.self_reviving(me), "A: self_reviving false after the revive")
	if check(await wait_reports("watch_a", 1, 20.0), "B reports A's self-revive"):
		_check_watch(reported(b, "watch_a"), "A")
	# 3. The host bot goes down.
	var cb := td.crew_bots.get(bot) as CrewBot
	if not check(cb != null and cb.rack != null, "the host runs the bot"):
		return
	var bi := cb.rack.weapons.find("repair_drone")
	if not check(bi >= 0, "the bot carries a repair drone (%s)" % str(cb.rack.weapons)):
		return
	cb.rack.charges[bi] = maxi(cb.rack.charges[bi], 1)   # (its AI may have spent charges on A)
	var bid := "player%d" % bot
	command(b, "watch", {"id": bid, "peer": bot, "key": "watch_bot"})
	await sleep(0.3)
	cb.target.invuln_left = 0.0
	cb.target.apply_damage(cb.target.max_hp["torso"] * 3.0, "torso", "test")
	check(cb.target.disabled, "the bot is down")
	check(await until(func() -> bool: return world.drone_of(bid) != null and world.drone_of(bid).is_self(), 2.0),
		"the bot's self-revive drone launched (CrewBot's rack)")
	check(world.self_reviving(bid), "A: self_reviving(%s) true" % bid)
	check(await until(func() -> bool: return not cb.target.disabled, REVIVE_WAIT), "the bot stood up")
	check(not cb.target.redeploying, "revived, not redeployed")
	if check(await wait_reports("watch_bot", 1, 20.0), "B reports the bot's self-revive"):
		_check_watch(reported(b, "watch_bot"), "the bot")
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func _check_watch(v: Dictionary, who: String) -> void:
	check(bool(v["saw_self"]), "B: %s's drone carries the self flag" % who)
	check(bool(v["saw_reviving"]), "B: self_reviving true for %s" % who)
	check(bool(v["saw_down"]), "B: saw %s downed" % who)
	check(bool(v["saw_scan"]), "B: the scan on %s's puppet" % who)
	check(bool(v["stood"]), "B: saw %s standing again" % who)
	check(not bool(v["reviving_after"]), "B: self_reviving false for %s after" % who)


func run_client() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", {"index": index})
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var data: Dictionary = c.get("data", {}) if c.get("data") is Dictionary else c
		match str(c["cmd"]):
			"finish":
				return
			"probe":
				var tg := td.downed.target_of(int(data["peer"]))
				var want := bool(data["want"])
				var hp := str(data["hp"])
				await until(func() -> bool: return tg != null and tg.is_slot_destroyed(hp) == want, 6.0)
				report(str(data["key"]), tg != null and tg.is_slot_destroyed(hp))
			"watch":
				report(str(data["key"]), await _watch(str(data["id"]), int(data["peer"])))


## Watch pilot `peer` (shooter `id`) go down and self-revive on this machine.
func _watch(id: String, peer: int) -> Dictionary:
	var out := {"saw_self": false, "saw_reviving": false, "saw_down": false, "saw_scan": false, "stood": false,
		"reviving_after": true}
	var tg := td.downed.target_of(peer)
	var t := 0.0
	while t < 20.0 and tg != null:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var d := world.drone_of(id)
		if d != null and d.is_self():
			out["saw_self"] = true
			if d.beamed().has(tg):
				out["saw_scan"] = true
		if world.self_reviving(id):
			out["saw_reviving"] = true
		if tg.disabled:
			out["saw_down"] = true
		elif bool(out["saw_down"]) and not world.self_reviving(id):
			out["stood"] = true
			break
	await sleep(0.2)
	out["reviving_after"] = world.self_reviving(id)
	return out


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null and td.downed != null, "the crew mission runs with DownedCrew"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	if not check(await until(func() -> bool: return td.crew_sync.puppets.size() >= peers - 1, 10.0), "the puppets exist"):
		return false
	td.combat.squad.clear_enemies()
	return true
