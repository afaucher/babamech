extends NetTest
## Supply depots across a crew of 3 (host + 2 clients), once per link (docs/design/pacing-director.md §2;
## scripts/game/mission_depots.gd, NetMission "DEPOTS"). Seed 7, plan mode.
## 1. Every machine has the same depots at the same snapped sites, facing the same way, with 3 cores (1 per pilot x 3).
## 2. A client out of range claims: denied "range", nothing changes anywhere.
## 3. The host takes deck 1 depot's cores down to ONE (its own claims); both clients stand in range and claim the LAST
##    core at the same moment -> exactly one grant and one deny "empty"; cores_left 0 on all three machines; the effect
##    applied once, on the winner only.
## 4. The host re-sends that grant (a duplicate, same seq): every client ignores it (no second effect, counted dup).
## 4b. A hangar bot (pilot < 0, run by the host; its AI parked for the test): damaged, standing at a second depot, it takes
##    a core through the depot code (the host's stand timer + claim_for); every client sees the grant (cores_left, lit
##    sockets, last grant to pilot -1). Then a human client and the bot claim a third depot's LAST core together ->
##    exactly one grant, cores_left 0 on every machine.
## 5. The state a barrier latecomer gets (Session.mission_state()'s "depots", what mission.go carries) has the cores.

const PEERS := 3   ## + one hangar bot: 4 pilots, so 4 cores per depot
const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}

var td: TestDrive


func run_host() -> void:
	net_timeout = 220.0
	MissionFlow.test_plan = PLAN
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	var bot_id := Session.add_bot()
	check(bot_id < 0, "a hangar bot joins the crew (pilot %d)" % bot_id)
	Session.objectives = true
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var dp := td.mission.depots
	var id := str(td.mission.plan.deck_depots(0)[0]["id"])
	eq(int(dp.cores_max[id]), peers + 1, "cores = 1 per pilot at mission start, the bot included")
	var cb := td.crew_bots.get(bot_id) as CrewBot
	if not check(cb != null, "the host runs the bot"):
		return
	if cb.ai != null:   # parked: the test moves it (the depot code, not its AI, takes cores)
		cb.ai.queue_free()
		cb.ai = null
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready"):
		return
	for p in _clients():
		eq(str(reported(p, "ready")), str(_sites()), "client %d: the same depots, sites and cores" % p)
	_kill_all()
	# 2. Out of range.
	var cl := _clients()
	command(cl[0], "claim_far", {"id": id})
	if check(await wait_reports("far", 1, 15.0), "the far claim is answered"):
		eq(str(reported(cl[0], "far")), "range", "a claim from out of range is denied: range")
	eq(int(dp.cores_left[id]), peers + 1, "nothing taken")
	# 3. The host takes cores until one is left (one grant per 5 s per pilot: it waits out its own cooldown).
	td.mech.global_position = _stand_pos(dp, id, 3.0, -1.0)
	td.mech.velocity = Vector3.ZERO
	while int(dp.cores_left[id]) > 1:
		_kill_all()
		var before := int(dp.cores_left[id])
		dp.claim_now(id)
		if int(dp.cores_left[id]) == before:
			await sleep(0.5)    # cooldown: try again
	td.mech.global_position = _stand_pos(dp, id, 30.0, -1.0)   # off, so it doesn't take the last one itself
	await sleep(0.3)
	for p in cl:
		command(p, "stand", {"id": id})
	if not check(await wait_reports("standing", cl.size(), 15.0), "both clients stand at the depot"):
		return
	await sleep(0.6)   # their puppets reach the spot here
	for p in cl:
		command(p, "claim", {"id": id})
	if check(await wait_reports("claimed", cl.size(), 15.0), "both claims answered"):
		var kinds := []
		var winner := -1
		for p in cl:
			var r: Dictionary = reported(p, "claimed")
			kinds.append(str(r["kind"]))
			if str(r["kind"]) == "grant":
				winner = p
				eq(int(r["applied"]), 1, "the winner applied the effect once")
			else:
				eq(str(r["reason"]), "empty", "the loser is denied: empty")
				eq(int(r["applied"]), 0, "the loser applied nothing")
		kinds.sort()
		eq(kinds, ["deny", "grant"], "exactly one grant and one deny")
		eq(int(dp.cores_left[id]), 0, "host: cores_left 0")
		await sleep(0.8)
		_ask_all("after")
		if check(await wait_reports("after", cl.size(), 15.0), "every client reports after"):
			for p in cl:
				var r: Dictionary = reported(p, "after")
				eq(int(r["left"]), 0, "client %d: cores_left 0" % p)
				eq(int(r["applied"]), 1 if p == winner else 0, "client %d: effect count" % p)
		# 4. A duplicate grant.
		var last: Dictionary = {}
		for peer: int in dp._answered:
			if int(peer) == winner:
				last = dp._answered[peer]["data"]
		if check(not last.is_empty(), "the host has the winner's grant"):
			Session.send_depot_grant(last, 0)
			await sleep(0.8)
			_ask_all("dup")
			if check(await wait_reports("dup", cl.size(), 15.0), "every client reports after the duplicate"):
				for p in cl:
					var r: Dictionary = reported(p, "dup")
					eq(int(r["applied"]), 1 if p == winner else 0, "client %d: the duplicate grant applied nothing" % p)
					check(int(r["dups"]) >= 1, "client %d: counted the duplicate" % p)
	# 4b. The hangar bot takes cores through the depot code.
	eq(dp.claim_for(bot_id, id), "empty", "claim_for(bot) on the empty depot: denied empty (keyed by pilot id, no wire send)")
	var others: Array[String] = []
	for d: Dictionary in td.mission.plan.depots:
		if dp.has_cores(str(d["id"])):
			others.append(str(d["id"]))
	if check(others.size() >= 2, "two more depots with cores (%s)" % [others]):
		var id3 := others[0]
		var id2 := others[1]
		cb.target.apply_damage(300.0, "torso", "test")
		cb.target.apply_damage(150.0, "leg_l", "test")
		check(dp.needs_core(bot_id), "the damaged bot needs a core")
		var left3 := int(dp.cores_left[id3])
		cb.mech.global_position = _stand_pos(dp, id3, 3.0, -1.0)
		cb.mech.velocity = Vector3.ZERO
		if check(await until(func() -> bool:
				_kill_all()
				return int(dp.cores_left[id3]) == left3 - 1, 6.0), "the bot takes a core of %s" % id3):
			eq(int(dp.last_grant.get("peer", 0)), bot_id, "the grant went to the bot")
			check(not dp.needs_core(bot_id) or cb.target.total_hp() / cb.target.total_max_hp() < MissionDepots.BOT_NEED_STRUCTURE,
				"the core repaired the bot's own mech")
			await sleep(0.8)
			for p in cl:
				command(p, "botcheck", {"id": id3})
			if check(await wait_reports("botcheck", cl.size(), 15.0), "every client reports the bot's grant"):
				for p in cl:
					eq(str(reported(p, "botcheck")), str([left3 - 1, left3 - 1, bot_id]),
						"client %d: cores_left, lit sockets and the grant's pilot" % p)
		# A human and the bot claim the LAST core of id2 together.
		dp.cores_left[id2] = 1      # host authority: the state below carries it
		await sleep(5.5)            # the bot's 5 s per-pilot limit since its last core
		cb.target.apply_damage(100.0, "torso", "test")
		cb.target.apply_damage(150.0, "leg_r", "test")
		check(dp.needs_core(bot_id), "the bot needs a core again")
		var n0 := dp.records.size()
		# Both start their 2 s stand timers at about the same moment (the client's command is one link delay behind).
		reports_clear("raced")
		command(cl[0], "stand_race", {"id": id2})
		await sleep(0.05)
		cb.mech.global_position = _stand_pos(dp, id2, 3.0, -1.0)
		cb.mech.velocity = Vector3.ZERO
		await until(func() -> bool: return int(dp.cores_left[id2]) == 0, 8.0)
		if check(await wait_reports("raced", 1, 15.0), "the human's stand is over"):
			await sleep(1.0)
			var mine2 := dp.records.slice(n0).filter(func(r: Dictionary) -> bool: return str(r["depot"]) == id2)
			var g2 := mine2.filter(func(r: Dictionary) -> bool: return str(r["kind"]) == "grant")
			var d2 := mine2.filter(func(r: Dictionary) -> bool: return str(r["kind"]) == "deny")
			print("[Test] last-core race: host records %s; client %s" % [mine2, reported(cl[0], "raced")])
			eq(g2.size(), 1, "exactly one grant for the last core (%s)" % [g2])
			var human: Dictionary = reported(cl[0], "raced")
			check(d2.size() <= 1, "at most the one other claim, denied (the loser may see the empty depot before its timer ends)")
			for r: Dictionary in d2:
				eq(str(r["reason"]), "empty", "the loser is denied: empty")
			if g2.size() == 1:
				var won_human := int(g2[0].get("peer", 0)) != bot_id
				eq(str(human.get("kind", "")) == "grant", won_human, "the human's answer agrees with the host (%s)" % [human])
			eq(int(dp.cores_left[id2]), 0, "host: cores_left 0")
			reports_clear("botcheck")
			for p in cl:
				command(p, "botcheck", {"id": id2})
			if check(await wait_reports("botcheck", cl.size(), 15.0), "every client reports the race"):
				for p in cl:
					eq(int((str_to_var(str(reported(p, "botcheck"))) as Array)[0]), 0, "client %d: cores_left 0" % p)
	# 5. The latecomer's state.
	await sleep(0.6)
	var st: Dictionary = Session.mission_state().get("depots", {})
	eq(st.get(id, []), [0, 1], "mission.state (what mission.go carries) has the depot empty and standing")
	_ask_all("late")
	if check(await wait_reports("late", cl.size(), 15.0), "every client reports the latecomer state"):
		for p in cl:
			eq(str(reported(p, "late")), str([0, 1]), "client %d: a fresh MissionDepots from that state agrees" % p)
	for p in cl:
		command(p, "finish", {})
	check(await wait_done(peers - 1, 20.0), "every client is done")
	Session.objectives = false
	MissionFlow.test_plan = {}


func run_client() -> void:
	net_timeout = 220.0
	MissionFlow.test_plan = PLAN
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", str(_sites()))
	var dp := td.mission.depots
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var id := str(c.get("id", ""))
		match str(c["cmd"]):
			"finish":
				MissionFlow.test_plan = {}
				return
			"stand_race":
				# Stand in range and let the 2 s timer claim (it may not, if the host's grant to the bot arrives first).
				td.mech.global_position = _stand_pos(dp, id, 3.0, 1.0, true)
				td.mech.velocity = Vector3.ZERO
				td.mech.move_input = Vector2.ZERO
				var n := dp.records.size()
				await until(func() -> bool: return dp.records.size() > n and dp._inflight.is_empty() 					and str(dp.records[-1]["kind"]) != "claim", 5.0)
				var r: Dictionary = dp.records[-1] if dp.records.size() > n and str(dp.records[-1]["kind"]) != "claim" else {}
				report("raced", {"kind": str(r.get("kind", "")), "reason": str(r.get("reason", ""))})
			"botcheck":
				var nd := dp.nodes.get(id) as SupplyDepot
				report("botcheck", str([int(dp.cores_left[id]), nd.lit_cells() if nd != null else -1, int(dp.last_grant.get("peer", 0))]))
			"claim_far":
				td.mech.global_position = _stand_pos(dp, id, 25.0, 1.0)
				td.mech.velocity = Vector3.ZERO
				await sleep(0.5)
				var n := dp.records.size()
				dp.claim_now(id)
				await until(func() -> bool: return dp.records.size() > n + 1 or dp._inflight.is_empty(), 5.0)
				report("far", str(dp.records[-1].get("reason", dp.records[-1].get("kind", ""))))
			"stand":
				# Each client on its own side of the footprint, 3 m out (inside CLAIM_RANGE), facing the claim race.
				td.mech.global_position = _stand_pos(dp, id, 3.0, 1.0 if index == 1 else -1.0, index == 1)
				td.mech.velocity = Vector3.ZERO
				td.mech.move_input = Vector2.ZERO
				report("standing", true)
			"claim":
				var n := dp.records.size()
				dp.claim_now(id)
				await until(func() -> bool: return dp._inflight.is_empty(), 8.0)
				var r: Dictionary = dp.records[-1] if dp.records.size() > n else {}
				report("claimed", {"kind": str(r.get("kind", "")), "reason": str(r.get("reason", "")), "applied": dp.applied})
			"report":
				var key := str(c["key"])
				var did := str(td.mission.plan.deck_depots(0)[0]["id"])
				match key:
					"late":
						var fresh := MissionDepots.new()
						fresh.cores_left = {did: -1}
						fresh.alive = {did: false}
						fresh.apply_state(Session.mission_state().get("depots", {}))
						report(key, str([int(fresh.cores_left[did]), 1 if fresh.alive[did] else 0]))
						fresh.free()
					"bot":
						var lg := dp.last_grant
						report(key, str([str(lg.get("depot", "")), int(lg.get("peer", 0)), int(lg.get("seq", 0)),
							int(dp.cores_left.get(str(lg.get("depot", "")), -99))]))
					_:
						report(key, {"left": int(dp.cores_left[did]), "applied": dp.applied, "dups": dp.dup_grants})


## A point `gap` m out from depot `id`'s footprint, on its +s (side 1) or -s (side -1) face, or its +x face (`x_side`).
func _stand_pos(dp: MissionDepots, id: String, gap: float, side: float, x_side: bool = false) -> Vector3:
	var st: Dictionary = dp.sites[id]
	var x := float(st["x"])
	var s := float(st["s"])
	var half := SupplyDepot.footprint_half(int(st.get("face", 0)))
	if x_side:
		x += (half.x + gap) * side
	else:
		s += (half.y + gap) * side
	return td.stack.from_deck_arc(int(st["deck"]), x, s, float(st.get("h", 0.0)) + 0.5)


## Forget every client's report under `key` (to wait for a fresh round).
func reports_clear(key: String) -> void:
	for p: int in reports:
		(reports[p] as Dictionary).erase(key)


func _sites() -> Array:
	var dp := td.mission.depots
	var out: Array = []
	for d: Dictionary in td.mission.plan.depots:
		var id := str(d["id"])
		var st: Dictionary = dp.sites[id]
		out.append([id, int(st["deck"]), snappedf(float(st["x"]), 0.01), snappedf(float(st["s"]), 0.01), int(dp.cores_max[id]),
			int(st["face"])])
	return out


func _kill_all() -> void:
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


func _ask_all(key: String) -> void:
	for p in _clients():
		command(p, "report", {"key": key})


func _clients() -> Array[int]:
	var out: Array[int] = []
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id() and not bool(e.get("bot", false)):   # the players (not the bot)
			out.append(int(e["peer"]))
	return out


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.objectives and td.mission != null and td.mission.depots != null, "the crew mission has depots"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return await until(func() -> bool: return td.crew_sync.puppets.size() >= peers - 1, 10.0)   # clients also have the bot's puppet
