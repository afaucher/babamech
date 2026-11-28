extends NetTest
## The debrief's counters across machines (MissionStats, docs/design/debrief-stats.md; playtest R2.15 / R2.15a): a real
## crew mission of 3 processes plus a hangar bot, once per link (off, coast). Plan mode, the director held off, the
## garrison and the bot's AI idle, so only staged events count. Host A, client c1 = B (carries a repair drone), c2 = C.
## 1. Only the host has a MissionStats (clients compute nothing).
## 2. C kills a host-owned enemy (its hit decided on C, applied on the host through CombatNet): the host credits C the
##    kill and the HP actually removed. A bot kill on the host credits the bot (negative id).
## 3. C fires its weapons for a while: the host counts exactly C's fire records as its shots, and its hits.
## 4. C takes many small hits on its own machine (victim decides), partly under B's repair drone: the host's damage taken
##    for C (derived from C's snapshot stream) is within the stated bound of C's own exact total.
## 5. C goes down beside B, B's drone revives it: the host counts C's down and B's revive given.
## 6. C takes a depot core (its claim, the host's grant): the host counts C's core.
## 7. The host forces the outcome: every machine ends with the same NetMission.last_debrief (the host's numbers).

const PEERS := 3
const NET_TIMEOUT := 400   # test_runner reads this literal
const BOT_FIRE_TIMEOUT := 150.0
const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}
const DIRECTOR := {"rest_first": 100000.0, "rest_last": 100000.0, "arrival_rest": 100000.0, "quiet_cap": 100000.0,
	"scout_every": 100000.0, "call_every": 100000.0, "patrols": 0}
const TAKEN_REL := 0.03          ## the client damage-taken bound: 3 % of the exact total ...
const TAKEN_ABS := 6.0           ## ... plus this many HP (u8 quantisation over the run)

var td: MissionScene
var world: CombatWorld
var taken := 0.0                 ## client: exact damage on this machine's own mech (PlayerTarget.damaged)
var my_shots := 0                ## client: this pilot's own fire records
var my_hits: Dictionary = {}     ## client: shot keys of this pilot's hits on enemies (remote_hit)


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	var bot := Session.add_bot("average")
	check(bot < 0, "the host seats a hangar bot (%d)" % bot)
	await frames(5)
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for id: int in td.crew_bots:
		var cb := td.crew_bots[id] as CrewBot
		cb.process_mode = Node.PROCESS_MODE_DISABLED
		if cb.ai != null:
			cb.ai.process_mode = Node.PROCESS_MODE_DISABLED
		if cb.rack != null:
			cb.rack.set_trigger(false)
			cb.rack.process_mode = Node.PROCESS_MODE_DISABLED
	if not check(await wait_reports("ready", peers - 1, 40.0), "the clients are ready"):
		return
	var b := -1
	var c := -1
	for p: int in peers_with("ready"):
		var ix := int((reported(p, "ready") as Dictionary)["index"])
		if ix == 1:
			b = p
		elif ix == 2:
			c = p
	var ms := td.mission.stats
	if not check(ms != null and b > 0 and c > 0, "the host has MissionStats; B and C known"):
		return
	for p: int in [b, c]:
		check(not bool((reported(p, "ready") as Dictionary)["stats"]), "client %d has no MissionStats (computes nothing)" % p)
	eq(ms.pilots.map(func(e: Dictionary) -> int: return int(e["id"])), Session.crew().map(func(e: Dictionary) -> int: return int(e["peer"])),
		"the pilot list is the crew in seat order, the bot included")

	# 2. C kills an enemy; the host's bot kills another.
	var es: Array = []
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed() and e.is_hittable():
			es.append(e)
	if not check(es.size() >= 2, "two live enemies"):
		return
	var ec: EnemyBase = es[0]
	var hp_c := ec.total_hp()
	var core_c := float(ec.hp[ec.core_component()])
	command(c, "kill", {"id": ec.target_id})
	check(await until(func() -> bool: return ec.destroyed(), 10.0), "C's hit killed the enemy on the host")
	eq(ms.value(c, "kills"), 1, "the host credits C the kill")
	var dd := float(ms.value(c, "damage_dealt"))
	check(dd >= core_c - 0.01 and dd <= hp_c + 0.01, "C's damage dealt is the HP actually removed (%.1f; core %.1f, total %.1f)" % [dd, core_c, hp_c])
	var eb: EnemyBase = es[1]
	var bot_rack: WeaponRack = (td.crew_bots[bot] as CrewBot).rack
	var hb := lethal_shot(world, bot_rack, "player%d" % bot, 1, eb, 99999)   # a real fire record, then its lethal hit
	world.deliver(eb, hb)
	eq(ms.value(bot, "kills"), 1, "a bot's kill credits the bot")
	eq(ms.value(bot, "shots"), 1, "the bot's fire record is its shot")
	eq(ms.value(bot, "hits"), 1, "and its lethal hit is one hit")

	# 3. C fires.
	command(c, "fire", {"s": 3.0})
	if check(await wait_reports("fire", 1, 15.0), "C fired"):
		await sleep(1.5)   # the last records reach the host; shots in flight land or miss
		var f: Dictionary = reported(c, "fire")
		print("[stats] %s: C fired %d records (%d hits on C), the host counts shots %d hits %d" % [link, int(f["shots"]),
			int(f["hits"]), int(ms.value(c, "shots")), int(ms.value(c, "hits"))])
		check(int(f["shots"]) > 0, "C fired records (%d)" % int(f["shots"]))
		eq(int(ms.value(c, "shots")), int(f["shots"]), "the host counts exactly C's fire records as its shots")
		eq(int(ms.value(c, "hits")), int(f["hits"]), "and C's hits on enemies")

	# 4 + 5. C stands beside B; B's drone out; C takes many small hits under it, then goes down and is revived.
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	command(c, "near", {"to": pb.mech.global_position + pb.mech.global_basis.x * 6.0})
	check(await wait_reports("near", 1, 10.0), "C moved beside B")
	await sleep(0.5)
	command(c, "chip", {"n": 30, "every": 0.07})
	if check(await wait_reports("chip", 1, 15.0), "C took hits alone"):
		pass
	command(b, "launch", {})
	check(await wait_reports("launch", 1, 10.0) and bool(reported(b, "launch")), "B launched its drone")
	await sleep(2.0)
	command(c, "chip2", {"n": 40, "every": 0.05})
	check(await wait_reports("chip2", 1, 15.0), "C took hits under B's drone")
	var tc: PlayerTarget = td.crew_sync.targets.get(c)
	command(c, "down", {})
	check(await wait_reports("down", 1, 10.0), "C went down")
	check(await until(func() -> bool: return tc.disabled, 5.0), "the host sees C down")
	check(await until(func() -> bool: return not tc.disabled, 15.0), "the host sees C revived")
	await sleep(1.0)
	eq(ms.value(c, "downs"), 1, "the host counts C's down")
	eq(ms.value(b, "revives"), 1, "the host credits B the revive given (its drone's beam)")
	eq(ms.value(c, "self_revives"), 0, "not a self-revive")

	# 6. A core.
	var dp := td.mission.depots
	var did := str(dp.cores_left.keys()[0]) if dp != null and not dp.cores_left.is_empty() else ""
	if check(did != "", "the plan has a depot"):
		command(c, "core", {"id": did, "to": dp.depot_pos(did)})
		check(await wait_reports("core", 1, 20.0), "C reports its core claim")
		check(await until(func() -> bool: return int(ms.value(c, "cores")) == 1, 10.0), "the host counts C's core (%s)" % str(reported(c, "core")))

	# 6b. The bot fights for real (AI, rack, CombatNet): every record of its rack is a shot on its row, hits <= shots.
	var bot_records := [0]
	world.fired.connect(func(r: Dictionary) -> void:
		if str(r.get("shooter", "")) == "player%d" % bot and r.has("shot_index"):
			bot_records[0] += 1)
	var shots0 := int(ms.value(bot, "shots"))
	var dd0 := float(ms.value(bot, "damage_dealt"))
	var cbot := td.crew_bots[bot] as CrewBot
	# The bot starts on the open deck: B and C stand parked in the entry bay's front row all test, and a bot in the
	# back row cannot walk out past two mechs that never move (an owner move: the host owns its bots).
	cbot.mech.global_position = td.stack.from_deck_arc(int(td.stack.section.entry["deck"]), 0.0, 0.0, 0.5)
	cbot.mech.velocity = Vector3.ZERO
	cbot.process_mode = Node.PROCESS_MODE_INHERIT
	if cbot.ai != null:
		cbot.ai.process_mode = Node.PROCESS_MODE_INHERIT
	cbot.rack.process_mode = Node.PROCESS_MODE_INHERIT
	if check(await until(func() -> bool: return bot_records[0] >= 3, BOT_FIRE_TIMEOUT), "the bot fires in the live mission (%d records)" % bot_records[0]):
		await sleep(3.0)
		cbot.process_mode = Node.PROCESS_MODE_DISABLED
		if cbot.ai != null:
			cbot.ai.process_mode = Node.PROCESS_MODE_DISABLED
		cbot.rack.set_trigger(false)
		cbot.rack.process_mode = Node.PROCESS_MODE_DISABLED
		await sleep(2.0)
		print("[stats] %s: the live bot fired %d records: shots %d hits %d damage %.1f kills %d" % [link, bot_records[0],
			int(ms.value(bot, "shots")) - shots0, int(ms.value(bot, "hits")), float(ms.value(bot, "damage_dealt")) - dd0,
			int(ms.value(bot, "kills"))])
		eq(int(ms.value(bot, "shots")) - shots0, bot_records[0], "every live bot record counts on the bot's row (player%d)" % bot)
		check(int(ms.value(bot, "hits")) <= int(ms.value(bot, "shots")), "the bot's hits <= shots")
		if int(ms.value(bot, "hits")) > 1:
			check(float(ms.value(bot, "damage_dealt")) > dd0, "the bot's live hits deal damage on its row")

	# 4 (check). Damage taken.
	command(c, "taken", {})
	if check(await wait_reports("taken", 1, 10.0), "C reports its exact damage taken"):
		await sleep(0.5)
		var exact := float(reported(c, "taken"))
		var got := float(ms.value(c, "damage_taken"))
		var bound := TAKEN_REL * exact + TAKEN_ABS
		print("[stats] %s: C's damage taken exact %.1f, host-derived %.1f (error %.2f, bound %.2f)" % [link, exact, got, got - exact, bound])
		check(absf(got - exact) <= bound, "the host's damage taken for C (%.1f) is within %.1f of C's own %.1f" % [got, bound, exact])

	# 7. The outcome.
	td.mission.rules.outcome = "won"
	td.mission.rules.reason = "objectives"
	check(await until(func() -> bool: return not NetMission.last_debrief.is_empty(), MissionFlow.END_HOLD + 6.0), "the host ends with a debrief")
	print("[stats] %s: debrief %s" % [link, JSON.stringify(NetMission.last_debrief)])
	if check(await wait_reports("debrief", peers - 1, 15.0), "every client reports its debrief"):
		for p: int in [b, c]:
			eq(reported(p, "debrief"), NetMission.last_debrief, "client %d's debrief is exactly the host's" % p)
			var got: Dictionary = reported(p, "order")
			var want := _expected_order(NetMission.last_debrief)
			for id: String in (got.get("stats", {}) as Dictionary):
				eq(got["stats"][id], want, "client %d received pilot %s's keys in the board's order" % [p, id])
			eq(got.get("labels", []), want.slice(9), "client %d received labels in the board's order" % p)
	for id: Variant in (NetMission.last_debrief.get("stats", {}) as Dictionary):
		var r: Dictionary = NetMission.last_debrief["stats"][id]
		check(int(r.get("hits", 0)) <= int(r.get("shots", 0)), "pilot %s: hits <= shots in the debrief (%s / %s)" % [id, r.get("hits"), r.get("shots")])
	var row: Dictionary = (NetMission.last_debrief.get("stats", {}) as Dictionary).get(str(bot), {})
	# The staged kill plus whatever the live bot killed in 6b: the row carries the host's count exactly.
	check(int(row.get("kills", -1)) >= 1, "the bot's row (negative id, string key) carries its kill (%s)" % str(row.get("kills")))
	eq(int(row.get("kills", -1)), int(ms.value(bot, "kills")), "the bot's row matches the host's count of its kills")
	for p: int in [b, c]:
		command(p, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}


func run_client() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if index == 1:
		var lo := Session.local_loadout()
		lo["back"] = "repair_drone"
		Session.set_profile(Session.player_name, Session.local_head(), Session.local_chassis(), "", lo)
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	var me := "player%d" % Session.local_id()
	td.combat.player_target.damaged.connect(func(a: float, _c: String, _s: String) -> void: taken += a)
	world.fired.connect(func(r: Dictionary) -> void:
		if str(r.get("shooter", "")) == me and r.has("hardpoint") and r.has("shot_index") and not bool(r.get("enemy", false)):
			my_shots += 1)
	world.remote_hit.connect(func(tid: String, h: Hit) -> void:
		if h.shooter == me and _is_enemy(tid):
			my_hits[h.shot] = true)
	report("ready", {"index": index, "stats": td.mission.stats != null or td.mission.get_node_or_null("MissionStats") != null})
	while true:
		var cm := await wait_command(120.0)
		if not check(not cm.is_empty(), "the host's next command arrives"):
			return
		var data: Dictionary = cm
		match str(cm["cmd"]):
			"finish":
				return
			"kill":
				var t := _target(str(data["id"]))
				if t is EnemyBase:
					world.deliver(t, lethal_shot(world, td.combat.rack, me, Session.local_id(), t as EnemyBase, 88888))
				report("kill", t != null)
			"fire":
				var rk := td.combat.rack
				rk.read_input = false   # the mouse poll would clear the trigger every step
				for i in rk.slot_count():
					if not rk._is_equipment(i):
						rk.set_enabled(i + 1, true)
				rk.set_trigger(true)
				await sleep(float(data["s"]))
				rk.set_trigger(false)
				await sleep(2.0)   # every shot resolved here (misses fly out, hits sent)
				report("fire", {"shots": my_shots, "hits": my_hits.size()})
			"near":
				var to: Vector3 = data["to"]
				td.mech.global_position = to + td.mech.up() * 1.0
				td.mech.velocity = Vector3.ZERO
				MechSpawn.rig_of(td.mech).gait.reset([])
				await sleep(0.4)
				report("near", true)
			"chip", "chip2":
				var pt := td.combat.player_target
				var comps := ["torso", "leg_l", "leg_r", "side_l", "side_r"]
				var rng := RandomNumberGenerator.new()
				rng.seed = 1234 + index
				for i in int(data["n"]):
					pt.apply_damage(rng.randf_range(1.5, 9.0), comps[i % comps.size()], "test")
					await sleep(float(data["every"]))
				report(str(cm["cmd"]), true)
			"launch":
				var rack := td.combat.rack
				var n := rack.hardpoints.find("back") + 1
				report("launch", n > 0 and rack.activate(n))
			"down":
				var pt2 := td.combat.player_target
				pt2.apply_damage(1000.0, "head", "test")
				report("down", pt2.disabled)
			"core":
				var to2: Vector3 = data["to"]
				td.mech.global_position = to2 + td.mech.up() * 1.0
				td.mech.velocity = Vector3.ZERO
				MechSpawn.rig_of(td.mech).gait.reset([])
				await sleep(0.6)
				var dp := td.mission.depots
				dp.claim_now(str(data["id"]))
				await until(func() -> bool: return int(dp.last_grant.get("peer", 0)) == Session.local_id(), 5.0)
				report("core", dp.last_grant)
			"taken":
				await sleep(0.3)
				report("taken", taken)


func after_end() -> void:
	pass


func _is_enemy(tid: String) -> bool:
	return _target(tid) is EnemyBase


func _target(tid: String) -> CombatTarget:
	for t in world.targets:
		if is_instance_valid(t) and t.target_id == tid:
			return t
	return null


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.mission != null, "the crew mission runs"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	world.overrides["repair_drone"] = {"life": 30.0}
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	if is_host():
		for e in td.combat.squad.enemies:
			e.ai_mode = "idle"
		td.combat.squad.enemy_spawned.connect(func(e: EnemyBase) -> void: e.ai_mode = "idle")
	else:
		# The debrief arrives with the host's mission.end: report it when it does.
		Session.mission_ended.connect(func(_r: String) -> void:
			# The key ORDER as received (a report's dictionary may not keep it: send it as arrays).
			var ko := {}
			for id: Variant in (NetMission.last_debrief.get("stats", {}) as Dictionary):
				ko[str(id)] = (NetMission.last_debrief["stats"][id] as Dictionary).keys()
			report("order", {"stats": ko, "labels": (NetMission.last_debrief.get("labels", {}) as Dictionary).keys()})
			report("debrief", NetMission.last_debrief.duplicate(true)))
	return true


static func _expected_order(d: Dictionary) -> Array:
	var present := {}
	for id: Variant in d["stats"]:
		for k: Variant in d["stats"][id]:
			present[str(k)] = true
	var out: Array = MissionStats.CORE.duplicate()
	for g: String in ["trooper", "strider", "tank", "gunship", "drone", "turret", "other"]:
		if present.has("kills_" + g):
			out.append("kills_" + g)
	out.append_array(["self_revives", "redeploys", "time_down"])
	return out


## A real fire record for `shooter` (its rack's first weapon, aimed at `e`) through CombatWorld.fire (CombatNet sends a
## client's to the host), and the lethal Hit for that same shot key (the test's way to be sure it kills).
static func lethal_shot(w: CombatWorld, rack: WeaponRack, shooter: String, peer: int, e: EnemyBase, index: int) -> Hit:
	var i := 0
	while i < rack.slot_count() - 1 and (str(rack.weapons[i]) == "" or rack._is_equipment(i)):
		i += 1
	var aim := e.global_position + e.up * 2.0
	var rec := Combat.fire_record(shooter, peer, str(rack.hardpoints[i]), str(rack.weapons[i]), rack.muzzle(i + 1), aim, w.now, index)
	w.fire(rec)
	var h := Hit.new()
	h.damage = 1.0e6
	h.component = e.core_component()
	h.shooter = shooter
	h.weapon = str(rack.weapons[i])
	h.shot = Combat.shot_key(rec)
	return h
