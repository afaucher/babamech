extends NetTest
## The mission's win across a crew, in the one mission mode (objectives: user 2026-11-25 "Cut the legacy modes.";
## scripts/mission/mission_flow.gd, NetMission "mission.state"), over a real crew mission, once per link. Run with PEERS 2
## (test_net_mission_flow.gd) and 3 (test_net_mission_flow_3.gd). Every machine forces the same all-sweep plan without
## reserve waves (PLAN: MissionFlow.test_plan, part of the plan's checksum), so the crew flow itself is what is tested
## (the plan's waves, flags and defends across a crew: test_net_objectives*).
## 1. After mission.go, with the enemies alive, the host's rules have NOT finished deck 1's sweep (evaluation waits for
##    the go and the spawn); every client applied the host's state (same current objective and alive counts) and shows
##    the same objective line.
## 2. The host kills every enemy and stands its mech on each deck: every sweep is done and every machine's objective
##    becomes the extraction hold, with the EXTRACT waypoint on its HUD.
## 3. The LAST client stands (teleports) its own mech in the hold zone for the hold: the host decides "won" from that
##    mech's streamed position and every machine applies it and shows the MISSION COMPLETE banner.
## 4. END_HOLD later the host ends the mission (Session.mission.end): every client hears mission.end (mission_ended,
##    the scene-change signal MissionScene goes back to the hangar on; the test's drive isn't the current scene, so it stays)
##    and the mission is over everywhere, the session still up.

const SEED := 7
const PLAN := {"primary": "sweep", "bonus_max": 0, "waves_per_deck": 0, "hold": 3.0}

var td: MissionScene
var ended_heard := ""              ## client: the reason mission_ended brought
var _spot := 0                     ## _place: the sweep spot tried now
var _placed := false               ## _place teleported the mech last call


func run_host() -> void:
	net_timeout = 150.0
	MissionFlow.test_plan = PLAN
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready"):
		return
	var mf := td.mission
	var rules := mf.rules
	check(td.combat.squad.enemies.size() > 0, "the host spawned enemies (%d)" % td.combat.squad.enemies.size())
	var first := str(mf.plan.primary(0)["id"])

	# 1. Gated, applied everywhere ----------------------------------------------------------------------------
	await sleep(1.2)
	check(mf.evaluations >= 2, "the host evaluates (%d)" % mf.evaluations)
	check(rules.obj_state(first) != "done", "deck 1's primary is not done right after go while its enemies live")
	_ask_all("start")
	if check(await wait_reports("start", peers - 1, 15.0), "every client reports its rules"):
		for p in _clients():
			var v: Dictionary = reported(p, "start")
			check(bool(v["plan"]), "client %d runs the plan's rules" % p)
			eq(str(v["current"]), rules.current(), "client %d has the host's current objective" % p)
			eq(str(v["left"]), str(rules.state()["left"]), "client %d has the host's alive counts" % p)
			eq(str(v["text"]), rules.text(), "client %d's HUD shows the objective line" % p)

	# 2. Every enemy down, every deck stood on ---------------------------------------------------------------------
	for k in mf.plan.deck_count:
		var o: Dictionary = mf.plan.primary(k)
		var id := str(o["id"])
		var t0 := wall()
		while rules.obj_state(id) != "done" and wall() < t0 + 30.0:
			_place(o)
			_kill_all()
			await sleep(0.1)
		if not check(rules.obj_state(id) == "done", "%s (%s, deck %d) done (%s; host mech at %s, crew facts %s)" % [id,
				o["type"], k + 1, rules.obj_state(id), str(td.stack.to_deck_arc(td.mech.global_position)), str(mf.crew_facts())]):
			return
	if not check(await until(func() -> bool: return rules.current() == "hold", 5.0), "the host's objective turns to the hold"):
		return
	await sleep(0.6)
	_ask_all("cleared")
	if check(await wait_reports("cleared", peers - 1, 15.0), "every client reports after the sweeps"):
		for p in _clients():
			var v: Dictionary = reported(p, "cleared")
			eq(str(v["current"]), "hold", "client %d: the hold is the objective" % p)
			check(str(v["text"]).begins_with("Hold the extraction portal"), "client %d's objective line (%s)" % [p, v["text"]])
			eq(str(v["waypoint"]), "EXTRACT", "client %d's HUD has the EXTRACT waypoint" % p)
	eq(rules.outcome, "", "nobody held the portal yet")

	# 3. The last client holds the portal -------------------------------------------------------------------------
	td.mech.global_position = td.stack.from_deck_arc(int(td.stack.section.entry["deck"]), 0.0, 0.0, 0.5)   # out of the zone
	var runner: int = _clients()[-1]
	command(runner, "extract", {})
	if not check(await until(func() -> bool: return rules.outcome == "won", float(PLAN["hold"]) + 15.0),
			"the host decides won from client %d's mech (%s)" % [runner, str(rules.state())]):
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
	check(Session.mission.params.is_empty() and Session.mission.phase == NetMission.IDLE, "the host ended the mission")
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
	MissionFlow.test_plan = {}


func run_client() -> void:
	net_timeout = 150.0
	MissionFlow.test_plan = PLAN
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	Session.mission_ended.connect(func(r: String) -> void: ended_heard = r)
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
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
				MissionFlow.test_plan = {}
				return
			"extract":
				var hold: Dictionary = td.mission.plan.objective("hold")
				var t0 := wall()
				while td.mission.rules.outcome == "" and wall() < t0 + float(PLAN["hold"]) + 12.0:
					_place(hold)
					await sleep(0.1)
			"report":
				var hud := td.get_node_or_null("MechHud") as MechHud
				var hs: Dictionary = hud.mission_hud.state() if hud != null and hud.mission_hud != null else {}
				var r := td.mission.rules
				report(str(c["key"]), {"plan": r.plan != null, "current": r.current(),
					"left": str(r.state()["left"]), "outcome": r.outcome, "text": str(hs.get("objective", "")),
					"waypoint": str((hs.get("waypoint", {}) as Dictionary).get("label", "")),
					"banner": str((hs.get("banner", {}) as Dictionary).get("title", "")), "ended_heard": ended_heard,
					"over": Session.mission.params.is_empty() and td.mission.ended})


## Stand this machine's mech on objective o (a sweep: its deck's arrival; a flag: its site; the hold: its zone's centre).
func _place(o: Dictionary) -> void:
	var k := int(o["deck"])
	var ro := td.mission.rules.objective(o["id"])
	var at := Vector2(float(ro["site"]["x"]), float(ro["site"]["s"]))
	if str(o["type"]) == "hold":
		at = (ro["zone"] as Rect2).get_center()
	elif str(o["type"]) == "sweep":   # anywhere standing on the deck: its arrival or a spine point (the next one when a
		var arr: Dictionary = SectionEncounters.arrival(td.stack.section, k)   # spot drops the mech off the deck, e.g. inside a building)
		var sx: float = td.stack.section.col_x[td.stack.section.spine_line]
		var cands := [Vector2(float(arr["x"]), float(arr["s"])), Vector2(sx, 0.0), Vector2(sx, 60.0), Vector2(sx, -60.0),
			Vector2(sx, 120.0), Vector2(sx, -120.0), at]
		at = cands[_spot % cands.size()]
	var here := td.stack.to_deck_arc(td.mech.global_position)
	if int(here["deck"]) != k or Vector2(float(here["x"]), float(here["s"])).distance_to(at) > 5.0:
		if _placed and str(o["type"]) == "sweep":
			_spot += 1   # placed here last time and it did not stay: try the next spot
			_placed = false
			_place(o)
			return
		td.mech.global_position = td.stack.from_deck_arc(k, at.x, at.y, 0.5)
		td.mech.velocity = Vector3.ZERO
		_placed = true
	else:
		_placed = false


## Host: every enemy down (lethal hits on the host's own enemies; the clients' puppets follow).
func _kill_all() -> void:
	for e in td.combat.squad.enemies.duplicate():   # killing past MAX_WRECKS frees old wrecks from the list
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
	if not check(td.crewed and td.mission != null and td.mission.crew and td.mission.plan != null,
			"the crew mission runs a MissionFlow with the plan"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0)
