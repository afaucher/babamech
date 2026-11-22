extends NetTest
## The mission's win across a crew (W6 win side; scripts/game/mission_flow.gd, NetMission "mission.state"), over a real
## crew mission, once per link. Run with PEERS 2 (test_net_mission_flow.gd) and 3 (test_net_mission_flow_3.gd).
## 1. After mission.go, with the enemies alive, the host's rules have NOT latched their deck's clear (evaluation waits for
##    the go and the spawn); every client applied the host's state (same current objective and alive counts) and shows
##    the same objective line.
## 2. The host kills every enemy: every machine's objective becomes "extract", with an extraction waypoint on its HUD.
## 3. The LAST client walks (teleports) its own mech into the extraction zone: the host decides "won" from that mech's
##    streamed position and every machine applies it and shows the MISSION COMPLETE banner.
## 4. END_HOLD later the host ends the mission (Session.end_mission): every client hears mission.end (mission_ended,
##    the scene-change signal TestDrive goes back to the hangar on; the test's drive isn't the current scene, so it stays)
##    and the mission is over everywhere, the session still up.

const SEED := 7

var td: TestDrive
var ended_heard := ""              ## client: the reason mission_ended brought


func run_host() -> void:
	net_timeout = 120.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready"):
		return
	var mf := td.mission
	var rules := mf.rules
	var decks: Dictionary = {}
	for e in td.combat.squad.enemies:
		if is_instance_valid(e):
			decks[e.spawn_deck] = true
	check(not decks.is_empty(), "the host spawned enemies (%d)" % td.combat.squad.enemies.size())

	# 1. Gated, applied everywhere ----------------------------------------------------------------------------
	await sleep(1.2)
	check(mf.evaluations >= 2, "the host evaluates (%d)" % mf.evaluations)
	for k: int in decks:
		check(not rules.is_done("clear_%d" % k), "deck %d's clear is not done right after go while its enemies live" % k)
	check(rules.text().begins_with("Clear deck"), "the host's objective is a clear (%s)" % rules.text())
	_ask_all("start")
	if check(await wait_reports("start", peers - 1, 15.0), "every client reports its rules"):
		for p in _clients():
			var v: Dictionary = reported(p, "start")
			eq(str(v["current"]), rules.current(), "client %d has the host's current objective" % p)
			eq(str(v["left"]), str(rules.state()["left"]), "client %d has the host's alive counts" % p)
			eq(str(v["text"]), rules.text(), "client %d's HUD shows the objective line" % p)

	# 2. Every enemy down ----------------------------------------------------------------------------------------
	for e in td.combat.squad.enemies.duplicate():   # killing past MAX_WRECKS frees old wrecks from the list
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")
	if not check(await until(func() -> bool: return rules.current() == "extract", 5.0), "the host's objective turns to extraction"):
		return
	await sleep(0.6)
	_ask_all("cleared")
	if check(await wait_reports("cleared", peers - 1, 15.0), "every client reports after the clear"):
		for p in _clients():
			var v: Dictionary = reported(p, "cleared")
			eq(str(v["current"]), "extract", "client %d: extraction is the objective" % p)
			eq(str(v["text"]), "Reach the extraction portal", "client %d's objective line" % p)
			check(bool(v["waypoint"]), "client %d's HUD has the extraction waypoint" % p)
	eq(rules.outcome, "", "nobody extracted yet")

	# 3. The last client extracts ----------------------------------------------------------------------------------
	var runner: int = _clients()[-1]
	command(runner, "extract", {})
	if not check(await until(func() -> bool: return rules.outcome == "won", 10.0), "the host decides won from client %d's mech" % runner):
		return
	check(mf.end_left > 0.0, "the host shows the banner (%.2f s left)" % mf.end_left)
	await sleep(0.5)
	_ask_all("won")
	if check(await wait_reports("won", peers - 1, 15.0), "every client reports the outcome"):
		for p in _clients():
			var v: Dictionary = reported(p, "won")
			eq(str(v["outcome"]), "won", "client %d applied won" % p)
			eq(str(v["banner"]), "MISSION COMPLETE", "client %d shows the banner" % p)

	# 4. The end -------------------------------------------------------------------------------------------------
	if not check(await until(func() -> bool: return mf.ended, MissionFlow.END_HOLD + 3.0), "the host's end flow finishes"):
		return
	check(Session.mission_params().is_empty() and Session.mission.phase == NetMission.IDLE, "the host ended the mission")
	await sleep(1.0)
	_ask_all("after")
	if check(await wait_reports("after", peers - 1, 15.0), "every client reports after the end"):
		for p in _clients():
			var v: Dictionary = reported(p, "after")
			eq(str(v["ended_heard"]), MissionFlow.END_REASONS["won"], "client %d heard mission.end (Mission complete)" % p)
			check(bool(v["over"]), "client %d's mission is over" % p)
	check(Session.online() and Session.roster.size() == peers, "the crew is still together")
	for p in _clients():
		command(p, "finish", {})
	check(await wait_done(peers - 1, 20.0), "every client is done")


func run_client() -> void:
	net_timeout = 120.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	Session.mission_ended.connect(func(r: String) -> void: ended_heard = r)
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", td.mission != null)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"extract":
				var mk := td.mission.rules.marker()
				if check(not mk.is_empty(), "the client has the extraction marker"):
					td.mech.global_position = td.stack.from_deck_arc(int(mk["deck"]), float(mk["x"]), float(mk["s"]), 0.5)
					td.mech.velocity = Vector3.ZERO
			"report":
				var hud := td.get_node_or_null("MechHud") as MechHud
				var hs: Dictionary = hud.mission_hud.state() if hud != null and hud.mission_hud != null else {}
				var r := td.mission.rules
				report(str(c["key"]), {"current": r.current(), "left": str(r.state()["left"]), "outcome": r.outcome,
					"text": str(hs.get("objective", "")), "waypoint": not (hs.get("waypoint", {}) as Dictionary).is_empty(),
					"banner": str((hs.get("banner", {}) as Dictionary).get("title", "")), "ended_heard": ended_heard,
					"over": Session.mission_params().is_empty() and td.mission.ended})


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
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.mission != null and td.mission.crew and td.mission.rules != null,
			"the crew mission runs a MissionFlow with rules"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0)
