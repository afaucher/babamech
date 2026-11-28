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
## 3. The LAST client stands (teleports) its own mech in the hold zone for the hold: the host's hold completes from that
##    mech's streamed position and the exit door opens on every machine at the same shared-clock moment (R2.10; the same
##    road door orders everywhere, the entry door's opening at the barrier's start_at included). Then the walk-out: that
##    client in the exit bay with the host standing outside is no win; (3 peers) the other client downs itself; the host
##    walks in: "won" (a downed pilot does not block), every machine applies it and shows the MISSION COMPLETE banner.
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
			check(str(v["text"]).begins_with("Hold the exit"), "client %d's objective line (%s)" % [p, v["text"]])
			eq(str(v["waypoint"]), "EXTRACT", "client %d's HUD has the EXTRACT waypoint" % p)
	eq(rules.outcome, "", "nobody held the zone yet")

	# 3. The last client holds the zone: the exit door opens on every machine at the same shared-clock moment -------
	td.mech.global_position = td.stack.from_deck_arc(int(td.stack.section.entry["deck"]), 0.0, 0.0, 0.5)   # out of the zone
	var runner: int = _clients()[-1]
	eq(str(mf.world.source_state(MissionWorld.EXIT_ID)["state"]), "shut", "the exit door is shut before the hold is done")
	command(runner, "extract", {})
	if not check(await until(func() -> bool: return rules.exit_open(), float(PLAN["hold"]) + 15.0),
			"the host's hold completes from client %d's mech (%s)" % [runner, str(rules.state())]):
		return
	eq(rules.outcome, "", "the hold done: not won, the crew walks out")
	check(await until(func() -> bool: return bool(mf.world.source_state(MissionWorld.EXIT_ID)["passable"]),
		MissionRules.EXIT_LEAD + MissionWorld.OPENING + 2.0), "the host's exit door opens")
	await sleep(0.6)
	var host_doors := _doors()
	_ask_all("exit")
	if check(await wait_reports("exit", peers - 1, 15.0), "every client reports the exit"):
		for p in _clients():
			var v: Dictionary = reported(p, "exit")
			check(bool(v["exit_open"]), "client %d: the exit is open" % p)
			near(float(v["exit_open_at"]), float(mf.world.source_state(MissionWorld.EXIT_ID)["open_at"]), 0.001,
				"client %d's exit door opens at the host's shared-clock moment" % p)
			check(bool(v["exit_passable"]), "client %d's exit door is open" % p)
			eq(str(v["text"]), "Exit through the door", "client %d's objective line" % p)
			eq(str(v["doors"]), str(host_doors), "client %d applied the same road door orders (exit, entry)" % p)
	check(host_doors.has("door_exit:open:%.3f" % rules.exit_at), "the host's exit order at exit_at (%s)" % str(host_doors))
	if bool(mf.world.entry_door().get("ok", false)):
		check(host_doors.has("door_entry:open:%.3f" % Session.mission.start_at),
			"the entry door opened at the barrier's start_at on the host (%s)" % str(host_doors))

	# The entry door: shut by the host once nobody of the crew is in its bay / doorway; a pilot back in it reopens it.
	if host_doors.any(func(s: String) -> bool: return s.begins_with("door_entry:shut")):
		var eb := mf.world.entry_door()
		td.mech.global_position = eb["center"]
		td.mech.velocity = Vector3.ZERO
		check(await until(func() -> bool: return _doors()[-1].begins_with("door_entry:open"), 3.0),
			"the host back in the entry bay: the entry door reopens (%s)" % str(_doors()))
		check(await until(func() -> bool: return bool(mf.world.source_state(MissionWorld.ENTRY_ID)["passable"]),
			MissionWorld.WARN + MissionWorld.OPENING + MissionWorld.CLOSE + 2.0), "the reopened entry door opens")
		td.mech.global_position = td.stack.from_deck_arc(int(td.stack.section.entry["deck"]), 0.0, 0.0, 0.5)
	else:
		print("[Test] the entry door stayed open (a crew mech was in its bay all along): reopen not exercised")

	# 3b. The walk-out needs every standing pilot inside the exit bay; a downed one does not block ------------------
	var slots := mf.world.exit_bay_slots(peers)
	command(runner, "exit_bay", {"slot": peers - 1})
	if not check(await wait_reports("in_bay", 1, 15.0), "client %d walks into the exit bay" % runner):
		return
	await sleep(1.5)
	eq(rules.outcome, "", "one client inside, the host standing outside: no win")
	if peers >= 3:
		var downer: int = _clients()[0]
		command(downer, "down", {})
		check(await until(func() -> bool:
				for c: Dictionary in mf.crew_facts():
					if int(c["peer"]) == downer:
						return bool(c["downed"])
				return false, 10.0), "client %d is downed on the host" % downer)
	td.mech.global_position = slots[0].origin
	td.mech.velocity = Vector3.ZERO
	if not check(await until(func() -> bool: return rules.outcome == "won", 5.0),
			"every standing pilot inside: the host decides won (%s)" % str(mf.crew_facts())):
		return
	check(mf.end_left > 0.0, "the host shows the banner (%.2f s left)" % mf.end_left)
	await sleep(0.5)
	_ask_all("won")
	if check(await wait_reports("won", peers - 1, 15.0), "every client reports the outcome"):
		for p in _clients():
			var v: Dictionary = reported(p, "won")
			eq(str(v["outcome"]), "won", "client %d applied won" % p)
			eq(str(v["banner"]), "MISSION COMPLETE", "client %d shows the banner" % p)
			eq(str(v["doors"]), str(_doors()), "client %d applied the same road door orders by the end" % p)

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
				while not td.mission.rules.exit_open() and td.mission.rules.outcome == "" and wall() < t0 + float(PLAN["hold"]) + 12.0:
					_place(hold)
					await sleep(0.1)
			"exit_bay":
				var sl := td.mission.world.exit_bay_slots(peers)
				td.mech.global_position = sl[mini(int(c["slot"]), sl.size() - 1)].origin
				td.mech.velocity = Vector3.ZERO
				await sleep(0.3)
				report("in_bay", true)
			"down":
				td.combat.player_target.apply_damage(1.0e7, "torso", "test")
			"report":
				var hud := td.get_node_or_null("MechHud") as MechHud
				var hs: Dictionary = hud.mission_hud.state() if hud != null and hud.mission_hud != null else {}
				var r := td.mission.rules
				var es: Dictionary = td.mission.world.source_state(MissionWorld.EXIT_ID)
				report(str(c["key"]), {"plan": r.plan != null, "current": r.current(),
					"exit_open": r.exit_open(), "exit_open_at": float(es["open_at"]) if es["open_at"] != INF else -1.0,
					"exit_passable": bool(es["passable"]), "doors": str(_doors()),
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


## This machine's applied road door orders ("id:open|shut:at"), in order.
func _doors() -> Array:
	return td.mission.door_log.map(func(d: Dictionary) -> String: return "%s:%s:%.3f" % [d["id"], d["door"], float(d["at"])])


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
