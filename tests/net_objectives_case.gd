extends NetTest
## Mission objectives phase 1 across a crew (the one mission mode, the plan;
## scripts/game/mission_flow.gd, NetMission "mission.wave" / "mission.state"), once per link. Run with PEERS 2
## (test_net_objectives.gd) and 3 (test_net_objectives_3.gd). Seed 7 (deck 1: a flag primary).
## 1. Every machine runs plan mode from the launch params; the barrier passed with the plan's checksum joined.
## 2. The host kills every enemy; the LAST client stands its mech in deck 1's flag ring: the host's rules count the
##    flag's progress from that mech's streamed position; mid-way every client shows the zone bar and a rising progress.
##    The flag's wave is ordered when the capture starts: mid-way every client shows the reinforcement line.
## 3. The flag is raised (its wave was ordered at the start). Every machine has the same objective states / progress, the same
##    wave counters (director.state()), the same wave orders and called open_source with the same open_at for each (its
##    MissionWorld schedule agrees), and raised the flag in its world.

const SEED := 7
const PLAN := {"hold": 6.0}
const DIRECTOR := {"rest_first": 1.5, "rest_last": 1.5, "arrival_rest": 1.0, "grace": 1.5}

var td: MissionScene


func run_host() -> void:
	net_timeout = 150.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	# Objectives are the only mode (legacy modes cut 2026-11-26): the launch no longer carries a mode switch; it does
	# carry the host's crew scale.
	check(not Session.mission.params.has("objectives"), "the launch carries no objectives switch (the only mode)")
	check(int(Session.mission.params.get("scale", 0)) == peers, "the launch carries the host's crew scale")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready"):
		return
	var mf := td.mission
	for p in _clients():
		var v: Dictionary = reported(p, "ready")
		check(bool(v["plan"]), "client %d runs plan mode" % p)
		eq(str(v["plan_sum"]), mf.plan.checksum(), "client %d has the host's plan" % p)

	# 2. Kill everything, the last client to the flag -----------------------------------------------------------------
	_kill_all()
	var flag := mf.plan.primary(0)
	eq(str(flag.get("type", "")), "flag", "seed 7's deck 1 primary is a flag")
	var runner: int = _clients()[-1]
	command(runner, "flag", {"id": flag["id"]})
	if not check(await until(func() -> bool:
			_kill_all()
			return mf.rules.obj_progress(flag["id"]) >= 4.0, 20.0), "the host counts the flag from client %d's mech" % runner):
		return
	_ask_all("mid")
	if check(await wait_reports("mid", peers - 1, 15.0), "every client reports mid-flag"):
		for p in _clients():
			var v: Dictionary = reported(p, "mid")
			eq(str(v["state"].get(flag["id"], "")), "active", "client %d: the flag is active" % p)
			check(float(v["progress"].get(flag["id"], 0.0)) >= 2.0, "client %d: progress rises (%s)" % [p, str(v["progress"])])
			check(bool(v["zone_bar"]), "client %d: the zone bar shows" % p)
			# The capture brings its wave at once (step start): every client shows the reinforcement line mid-flag.
			check(bool(v["alert"]), "client %d shows the reinforcement line during the capture" % p)
	check(not mf.opened.is_empty(), "the flag's wave is ordered while the flag is rising")

	# 3. Raised, the flag's wave everywhere ---------------------------------------------------------------------------
	if not check(await until(func() -> bool:
			_kill_all()
			return mf.rules.obj_state(flag["id"]) == "done" and not mf.opened.is_empty(), 40.0), "the flag is raised and its wave ordered"):
		return
	# The alarm wave arrives on the host (spawn_wave at open_at) and reaches every client through EnemySync, tagged.
	var o0: Dictionary = mf.opened[0]
	var wid := str(o0["wave"])
	if check(await until(func() -> bool: return _wave_units(wid) > 0, float(o0["open_at"]) - Session.host_time() + 4.0),
			"wave %s spawns on the host" % wid):
		await sleep(1.0)
		var hn := _wave_units(wid)
		_ask_all("wave")
		if check(await wait_reports("wave", peers - 1, 15.0), "every client reports the wave"):
			for p in _clients():
				var v: Dictionary = reported(p, "wave")
				check(int(v["units"].get(wid, 0)) > 0, "client %d sees wave %s's units (%s, host %d)" % [p, wid, str(v["units"]), hn])
	_kill_all()
	await sleep(1.0)
	var mine := _summary()
	check((mine["opened"] as Array).size() >= 1, "the host opened a door (%s)" % str(mine["opened"]))
	_ask_all("raised")
	if check(await wait_reports("raised", peers - 1, 15.0), "every client reports after the flag"):
		for p in _clients():
			var v: Dictionary = reported(p, "raised")
			eq(str(v["state"]), str(mine["state"]), "client %d: same objective states" % p)
			eq(str(v["progress"]), str(mine["progress"]), "client %d: same objective progress" % p)
			eq(str(v["waves"]), str(mine["waves"]), "client %d: same wave counters" % p)
			eq(str(v["opened"]), str(mine["opened"]), "client %d: same open_source calls (wave, source, open_at)" % p)
			eq(str(v["doors"]), str(mine["doors"]), "client %d: same door schedules in the world" % p)
			check(bool(v["flag_up"]), "client %d raised the flag in its world" % p)
	check(bool(mine["flag_up"]), "the host raised the flag in its world")
	for p in _clients():
		command(p, "finish", {})
	check(await wait_done(peers - 1, 20.0), "every client is done")
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}


func run_client() -> void:
	net_timeout = 150.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", {"plan": td.mission.plan != null, "plan_sum": td.mission.plan.checksum() if td.mission.plan != null else ""})
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				MissionFlow.test_plan = {}
				MissionFlow.test_director = {}
				return
			"flag":
				var o := td.mission.rules.objective(str(c["data"]["id"]) if c.has("data") else str(c.get("id", "")))
				if check(not o.is_empty(), "the client knows the flag"):
					td.mech.global_position = td.stack.from_deck_arc(int(o["deck"]), float(o["site"]["x"]), float(o["site"]["s"]), 0.5)
					td.mech.velocity = Vector3.ZERO
			"report":
				var s := _summary()
				var hud := td.get_node_or_null("MechHud") as MechHud
				s["zone_bar"] = hud != null and hud.mission_hud.zone_panel.visible
				s["alert"] = hud != null and hud.mission_hud.alert_panel.visible
				var units := {}
				for e in td.combat.squad.enemies:
					if is_instance_valid(e) and e.wave != "":
						units[e.wave] = int(units.get(e.wave, 0)) + 1
				s["units"] = units
				report(str(c["key"]), s)


## What every machine compares: objective states and progress, wave counters, the open_source calls, the doors.
func _summary() -> Dictionary:
	var mf := td.mission
	var st := {}
	var pr := {}
	for o: Dictionary in mf.rules.objectives:
		st[o["id"]] = mf.rules.obj_state(o["id"])
		pr[o["id"]] = snappedf(mf.rules.obj_progress(o["id"]), 0.1)
	var opened: Array = []
	var doors := {}
	for e: Dictionary in mf.opened:
		opened.append([e["wave"], e["source"], snappedf(float(e["open_at"]), 0.001)])
		var ss := mf.world.source_state(e["source"])
		doors[e["source"]] = snappedf(float(ss["open_at"]), 0.001) if float(ss["open_at"]) < INF else -1.0
	var flag := mf.plan.primary(0)
	return {"state": st, "progress": pr, "waves": mf.director.state()["waves"], "opened": opened, "doors": doors,
		"flag_up": mf.world.flag_raised(flag["id"])}


func _wave_units(id: String) -> int:
	var n := 0
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave == id:
			n += 1
	return n


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
		if int(e["peer"]) != Session.local_id():
			out.append(int(e["peer"]))
	return out


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.mission != null and td.mission.plan != null and td.mission.world != null,
			"the crew mission runs plan mode"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes (plan checksum joined)"):
		return false
	return await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0)
