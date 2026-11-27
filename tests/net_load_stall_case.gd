extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## A slow client's mission load (the UHD 620 LAN bug: CityStack.build blocked the laptop's main thread ~7.8 s, ENet's
## default peer timeout dropped it at ~5.8 s of silence and it went back to the menu with "The host left").
## The client blocks its main thread STALL_MS right in the mission's _ready (MissionScene.test_stall_ms: OS.delay_msec, no
## transport servicing at all), before its build.
## - test_net_load_stall: STALL_MS (12 s) is past ENet's old 5 s minimum and past CLIENT_SILENCE (10 s), well under the
##   load timeout: the client still lands in the mission, the crew stays at 2 the whole time, nobody is dropped.
## - test_net_load_stall_slow (`slow = true`): the load timeout is shortened to SLOW_TIMEOUT on both machines, so the
##   stall outlasts it: the host sends the client out with LOAD_SLOW and says so (crew_note, telemetry); the client's
##   session ends with that reason (not "The host left") and Session.last_reason (what the menu shows) carries it.
## Not a test itself: test_net_load_stall*.gd extend it by path and declare PEERS.

const SEED := 11
const STALL_MS := 12000
const SLOW_TIMEOUT := 4.0

var slow := false
var td: MissionScene


func _configure() -> void:
	net_timeout = 110.0
	MissionScene.stepped_load = true   # the game's load: the stack and life over frames, mission.ready after both
	if slow:
		Session.mission.load_timeout = SLOW_TIMEOUT
		expect_end = NetSession.LOAD_SLOW


func run_host() -> void:
	_configure()
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the crew gathers"):
		return
	var min_crew := [2]
	var notes: Array[String] = []
	Session.roster_changed.connect(func() -> void: min_crew[0] = mini(min_crew[0], Session.roster.size()))
	Session.crew_note.connect(func(t: String) -> void: notes.append(t))
	check(Session.mission.host_launch(SEED), "the host launches")
	# Reliable traffic to the stalled client the whole time (the real bug: unacked reliable resends hit ENet's limit).
	var chatter := [true]
	_chatter(chatter)
	await _load()
	if slow:
		check(await until(func() -> bool: return Session.roster.size() == 1, 40.0), "the stalled client is sent out")
		eq(Session.mission.slow.size(), 1, "the host noted one member that didn't load in time")
		check(notes.any(func(t: String) -> bool: return t.contains(NetSession.LOAD_SLOW)),
			"the host is told why (%s)" % str(notes))
		check(Session.telemetry == null or Array(Session.telemetry.notes).any(func(n: String) -> bool: return n.contains(NetSession.LOAD_SLOW)),
			"telemetry carries the reason")
		check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 20.0),
			"the host's mission goes on without it")
		chatter[0] = false
		# Stay until the sent-out client has had the refusal (it closes its side once it has; the host drops the link a
		# grace after hearing it again): quitting now would close the link inside its stall and lose the reason.
		var gone := await until(func() -> bool: return Session._refused.is_empty(), 40.0)
		check(gone, "the sent-out client's link is closed after it heard why")
		return
	var go := await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 60.0)
	if not check(go, "the load barrier passes despite the client's %d ms stall (phase %s)" % [STALL_MS, Session.mission.phase]):
		return
	eq(min_crew[0], 2, "the crew never dropped below 2")
	eq(notes.size(), 0, "nobody was dropped (%s)" % str(notes))
	eq(Session.mission.slow.size(), 0, "nobody was sent out for loading slowly")
	check(int(Session.mission.build_ms.get(_client_peer(), 0)) >= STALL_MS, "the client's build time includes its stall (%s ms)" % str(Session.mission.build_ms))
	if not check(await wait_reports("mission", 1, 30.0), "the client reports its mission"):
		return
	var theirs: Dictionary = reported(_client_peer(), "mission")
	eq(str(theirs.get("phase", "")), NetMission.RUNNING, "the client is in the mission")
	eq(int(theirs.get("crew", 0)), 2, "the client still sees a crew of 2")
	eq(str(theirs.get("checksum", "")), td.mission_checksum(), "the client built the host's city")
	chatter[0] = false
	Session.mission.end()
	check(await wait_done(1, 30.0), "the client is done")


## Host: a reliable event to the crew every 0.25 s while `on[0]`.
func _chatter(on: Array) -> void:
	while on[0] and Session.online():
		Session.send_event(0, "probe.chatter", {"t": Session.host_time()})
		await sleep(0.25)


func run_client() -> void:
	_configure()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	MissionScene.test_stall_ms = STALL_MS
	await _load()
	MissionScene.test_stall_ms = 0
	if slow:
		check(await until(func() -> bool: return ended, 40.0), "the stalled client is sent out")
		eq(ended_reason, NetSession.LOAD_SLOW, "it is told why")
		eq(Session.last_reason, NetSession.LOAD_SLOW, "the menu will show the real reason")
		return
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0),
			"the load barrier passes here (phase %s, online %s, reason '%s')" % [Session.mission.phase, Session.online(), Session.last_reason]):
		return
	report("mission", {"phase": Session.mission.phase, "crew": Session.roster.size(), "checksum": td.mission_checksum()})
	await until(func() -> bool: return Session.mission.phase == NetMission.IDLE or ended, 30.0)


## Wait for start_t on the shared clock, then load the mission (the test drive) as the hangar would.
func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	check(td.loading or slow or td.combat != null, "the stepped load is under way (or done)")
	await until(func() -> bool: return not td.loading or not is_instance_valid(td), 60.0)
	if is_instance_valid(td) and td.stack != null:
		print("[Test] stack built in %s ms, longest chunk %s ms, %s chunks" % [str(td.stack.stats.get("ms")),
			str(td.stack.stats.get("max_chunk_ms")), str(td.stack.stats.get("chunks"))])


func _client_peer() -> int:
	for p: int in Session.roster:
		if p != 1:
			return p
	return 0
