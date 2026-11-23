extends NetTest
## A crew of two bots (MissionBot, `--bot`) plays a whole plan-mode mission (objectives on) on a host and a client, with no
## cheat: no DEV travel, no DEV fast clear. Seed 6 (three flag primaries, then the extraction hold). Each bot reads the
## mission from its own machine's rules (the client's are the host's replicated state) and they split by peer id: the
## host's bot (lowest id) anchors the zone, the client's escorts. Checked: the mission is won on the host, the client saw
## the same objectives done and heard the end, both bots took the same task list and the client's bot escorted. Friendly
## fire is on: MissionBot holds the trigger while the teammate is near the line of fire (stats "ff_holds", printed).
## Restores the statics at the end.

const PEERS := 2
const LINKS := ["off"]
const NET_TIMEOUT := 620   # test_runner reads this literal: WIN_TIMEOUT + 80 (load, end flow, slack). Update both together.
const SEED := 6
const WIN_TIMEOUT := 540.0   # measured 2026-11-23: won 247.5 s, later 271.4 s, then 318.1 s wall after the barrier as layouts grew (real time); ~1.7x. docs/design/player-ai.md §9.6

var td: TestDrive


func _configure() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	TestDrive.bot_profile = "veteran"
	TestDrive.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	MissionBot.bonuses = false


func _restore() -> void:
	TestDrive.bot_profile = ""
	TestDrive.dev_bot_travel = false
	MissionBot.bonuses = true
	Session.objectives = false


func run_host() -> void:
	_configure()
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the crew gathers"):
		_restore()
		return
	Session.objectives = true
	check(Session.start_mission(SEED), "the host launches")
	await _load()
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		_restore()
		return
	if not check(td.mission != null and td.mission.plan != null, "plan mode runs"):
		_restore()
		return
	var types: Array = []
	for k in td.mission.plan.deck_count:
		types.append(str(td.mission.plan.primary(k)["type"]))
	eq(types, ["flag", "flag", "flag"], "seed 6's primaries (re-scan the seeds if this moved)")
	var t0 := Time.get_ticks_msec()
	var won := await until(func() -> bool: return td.mission != null and td.mission.rules.outcome == "won", WIN_TIMEOUT)
	var st := td.mission.rules.state() if td.mission != null else {}
	print("[Test] host: won %s after %.1f s wall; state %s; bot %s" % [str(won), float(Time.get_ticks_msec() - t0) / 1000.0,
		str(st), str(td.bot.stats()) if td.bot != null else "none"])
	if not check(won, "the bots win the mission within %.0f s (state %s, bot %s)" % [WIN_TIMEOUT, str(st),
			td.bot.goal_text if td.bot != null else "none"]):
		_restore()
		return
	check((st.get("done", []) as Array).has("hold"), "the extraction hold was done")
	var my_tasks := _task_ids()
	check(await until(func() -> bool: return Session.mission.phase == NetMission.IDLE, 20.0),
		"the host's end flow ends the mission for the crew")
	if check(await wait_reports("mission", 1, 30.0), "the client reports its mission"):
		var theirs: Dictionary = reported(peers_with("mission")[0], "mission")
		eq(str(theirs.get("done", "")), str(st.get("done", [])), "the client saw the same objectives done")
		check(str(theirs.get("ended", "")) != "", "the client heard the mission end (%s)" % str(theirs.get("ended", "")))
		eq(str(theirs.get("tasks", "")), str(my_tasks), "both bots worked the same task list")
		eq(str(theirs.get("role", "")), "escort", "the client's bot escorted")
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
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the launch arrives"):
		_restore()
		return
	await _load()
	var roles := {}
	var t0 := Time.get_ticks_msec()
	while ended[0] == "" and float(Time.get_ticks_msec() - t0) / 1000.0 < WIN_TIMEOUT + 30.0:
		await sleep(1.0)
		if td.bot != null and td.bot.role != "":
			roles[td.bot.role] = true
	var done: Array = td.mission.rules.state().get("done", []) if td.mission != null else []
	print("[Test] client bot: %s, roles %s" % [str(td.bot.stats()) if td.bot != null else "none", str(roles.keys())])
	report("mission", {"done": str(done), "ended": ended[0], "tasks": str(_task_ids()),
		"role": "escort" if roles.has("escort") else str(roles.keys())})
	_restore()


func _task_ids() -> Array:
	var out: Array = []
	if td != null and td.bot != null:
		for e: Dictionary in td.bot.task_log:
			out.append(e["id"])
	return out


func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
