extends NetTest
## One full crew mission played by bots (MissionBot, `--bot`) on a host and a client, with the DEV aids the LAN soak uses:
## `--dev-fast-clear` (CombatWorld.dev_enemy_damage 10x) and `--dev-bot-travel` (MissionBot jumps between decks when its
## walk can't get there). Seed 4 (ramps between every deck). Checked: every deck is cleared, extraction reached and the
## mission won on the host, the same objective list on the client, and the host's end flow (MissionFlow -> mission.end)
## reaching the client. Restores the DEV statics at the end.

const PEERS := 2
const LINKS := ["off"]
const NET_TIMEOUT := 240   # test_runner: this run gets 240 s (a whole mission), not the default 90
const SEED := 4
const WIN_TIMEOUT := 170.0

var td: TestDrive


func _configure() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	TestDrive.bot_profile = "veteran"
	TestDrive.dev_bot_travel = true
	CombatWorld.dev_enemy_damage = TestDrive.DEV_FAST_CLEAR


func _restore() -> void:
	TestDrive.bot_profile = ""
	TestDrive.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0


func run_host() -> void:
	_configure()
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the crew gathers"):
		_restore()
		return
	check(Session.start_mission(SEED), "the host launches")
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
	check((st.get("done", []) as Array).has("extract"), "extraction was reached")
	check(await until(func() -> bool: return Session.mission.phase == NetMission.IDLE, 20.0),
		"the host's end flow ends the mission for the crew")
	if check(await wait_reports("mission", 1, 30.0), "the client reports its mission"):
		var theirs: Dictionary = reported(peers_with("mission")[0], "mission")
		eq(str(theirs.get("done", "")), str(st.get("done", [])), "the client saw the same objectives done")
		check(str(theirs.get("ended", "")) != "", "the client heard the mission end (%s)" % str(theirs.get("ended", "")))
		check(int(theirs.get("kills", 0)) > 0, "the client's bot saw kills (%d)" % int(theirs.get("kills", 0)))
	print("[Test] host bot: %d dev jumps" % (td.bot.dev_jumps if td.bot != null else -1))
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
	check(await until(func() -> bool: return ended[0] != "", WIN_TIMEOUT + 30.0), "the host's mission end arrives")
	var done: Array = td.mission.rules.state().get("done", []) if td.mission != null else []
	report("mission", {"done": str(done), "ended": ended[0], "kills": int(td._flow.get("kills", 0))})
	_restore()


func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
