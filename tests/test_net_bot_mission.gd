extends NetTest
## One full crew mission played by bots (MissionBot, `--bot`) on a host and a client, with the DEV aids the LAN soak uses:
## `--dev-fast-clear` (CombatWorld.dev_enemy_damage 10x) and `--dev-bot-travel` (MissionBot jumps between decks when its
## walk can't get there). Seed 4 (ramps between every deck). The real objectives mode (the only one) with a forced
## all-sweep plan (PLAN: every deck a sweep, no reserve waves, a 3 s hold, set on both machines: it joins the plan
## checksum). Checked: every deck's sweep done, the extraction hold done and the mission won on the host, the same objective list on the client, and the host's end flow (MissionFlow -> mission.end)
## reaching the client. Restores the DEV statics at the end.

const PEERS := 2
const LINKS := ["off"]
const NET_TIMEOUT := 700   # test_runner: this run gets 700 s (a whole mission), not the default 90. Keep = WIN_TIMEOUT + 80
#                            (load ~15 s, the end flow, slack): the runner reads this literal, so update both together.
const SEED := 4
const WIN_TIMEOUT := 620.0   # re-measured 2026-11-23 (Engine subagent): won at ~332 s with one death (respawn on deck 0 +
#                              a DEV jump back); a -TestAll run was still walking to extraction at 400 s (464 m left,
#                              ~415 s). Slower clears since the hunt / reveal tuning and the plan-mode waves; ~1.5x the
#                              worst. Was 400 (measured 2026-11-22: dev travel on 213 s, off ~275 s). Re-measure when it
#                              gets close: the test prints both bots' stats.

const PLAN := {"primary": "sweep", "bonus_max": 0, "waves_per_deck": 0, "hold": 3.0}   ## MissionFlow.test_plan

var td: MissionScene


func _configure() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	MissionScene.bot_profile = "veteran"
	MissionScene.dev_bot_travel = OS.get_environment("BABAMECH_BOT_DEV_TRAVEL") != "0"   # "0": walk only (MissionBot routes)
	CombatWorld.dev_enemy_damage = MissionScene.DEV_FAST_CLEAR
	MissionFlow.test_plan = PLAN


func _restore() -> void:
	MissionScene.bot_profile = ""
	MissionScene.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	MissionFlow.test_plan = {}


func run_host() -> void:
	_configure()
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the crew gathers"):
		_restore()
		return
	check(Session.mission.host_launch(SEED), "the host launches")
	await _load()
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		_restore()
		return
	var won := await until(func() -> bool: return td.mission != null and td.mission.rules.outcome == "won", WIN_TIMEOUT)
	var st := td.mission.rules.state() if td.mission != null else {}
	if not check(won, "the bots win the mission within %.0f s (state %s, bot %s)" % [WIN_TIMEOUT, str(st),
			td.bot.goal_text if td.bot != null else "none"]):
		_restore()
		return
	eq(str(st.get("current", "?")), "", "every objective is done (%s)" % str(st.get("done", [])))
	var sweeps := 0
	for o: Dictionary in td.mission.plan.objectives:
		if str(o["type"]) == "sweep" and (st.get("done", []) as Array).has(o["id"]):
			sweeps += 1
	var want := td.mission.plan.primary_types().count("sweep")
	check(want > 0 and sweeps == want, "every deck's sweep is done (%d of %d; primaries %s)" % [sweeps, want,
		str(td.mission.plan.primary_types())])
	check((st.get("done", []) as Array).has("hold"), "the extraction hold is done")
	check(await until(func() -> bool: return Session.mission.phase == NetMission.IDLE, 20.0),
		"the host's end flow ends the mission for the crew")
	if check(await wait_reports("mission", 1, 30.0), "the client reports its mission"):
		var theirs: Dictionary = reported(peers_with("mission")[0], "mission")
		eq(str(theirs.get("done", "")), str(st.get("done", [])), "the client saw the same objectives done")
		check(str(theirs.get("ended", "")) != "", "the client heard the mission end (%s)" % str(theirs.get("ended", "")))
		check(int(theirs.get("kills", 0)) > 0, "the client's bot saw kills (%d)" % int(theirs.get("kills", 0)))
	print("[Test] host bot: %s" % (str(td.bot.stats()) if td.bot != null else "none"))
	_restore()
	check(await wait_done(1, 20.0), "the client is done")


func run_client() -> void:
	_configure()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		_restore()
		return
	var ended := [""]
	Session.mission_ended.connect(func(r: String) -> void: ended[0] = r)
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the launch arrives"):
		_restore()
		return
	await _load()
	check(await until(func() -> bool: return ended[0] != "", WIN_TIMEOUT + 30.0), "the host's mission end arrives")
	var done: Array = td.mission.rules.state().get("done", []) if td.mission != null else []
	print("[Test] client bot: %s" % (str(td.bot.stats()) if td.bot != null else "none"))
	report("mission", {"done": str(done), "ended": ended[0], "kills": int(td._flow.get("kills", 0))})
	_restore()


func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
