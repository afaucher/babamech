extends NetTest
## The shared mission start (co-op step 1, docs/networking.md "Mission"), over a real crew, once per link (off, coast):
## - the crew gathers; the host launches (Session.start_mission): mission_started fires on every machine, the crew is
##   "mission", a second launch is refused;
## - every machine loads the test drive at start_t on the shared clock, on the host's seed, and reports its checksum;
##   the barrier passes (mission_go) and every machine lands on the same seed and city checksum;
## - every machine has one mech per crew member, owned by that member's peer, wearing its head / accent / loadout
##   (the loadout from the profile: NetTest.loadout_for), the local one driven and released after the barrier;
## - the host ends the mission: every client hears mission_ended and the crew is back in "lobby".
## The scenario for test_net_mission (2), test_net_mission_4 (a full crew) and test_net_mission_desync (3, one client
## perturbs its checksum). Not a test itself (no test_ prefix): each of those extends this file by path and declares its
## own `const PEERS` (a subclass can't redeclare a parent's constant, and the runner reads PEERS from the test's source).

const SEED := 7

## Processes that join the crew (the variants: 4, or 3 with one sent out).
var crew_size := 2
## Index of the client that perturbs its checksum and must be sent out (-1 = none).
var desync_index := -1
## The city the host launches: the stack (the only one).
var mission_mode := NetMission.MODE_STACK
var td: TestDrive


func _configure() -> void:
	crew_size = peers


func run_host() -> void:
	_configure()
	if not check(await until(func() -> bool: return Session.roster.size() == crew_size, 30.0),
			"the crew gathers (%d of %d)" % [Session.roster.size(), crew_size]):
		return
	var started := [false]
	Session.mission_started.connect(func(_p: Dictionary) -> void: started[0] = true)
	# The one mission mode (objectives).
	check(Session.start_mission(SEED, mission_mode), "the host launches the mission (%s)" % mission_mode)
	check(not Session.mission_params().has("objectives"), "the launch carries no mode switch (objectives are the only mode)")
	check(started[0], "mission_started fires on the host too")
	check(not Session.start_mission(SEED + 1), "a second launch while one is under way is refused")
	eq(Session.crew_state, "mission", "the crew is on a mission")
	eq((Session.mission_params()["crew"] as Array).size(), crew_size, "the launch carries the whole crew")
	eq(Session.mission_params().get("friendly_fire", null), true, "the default launch carries friendly fire on")
	for e: Dictionary in Session.crew():
		var i := 0 if int(e["peer"]) == 1 else int(str(e["name"]).trim_prefix("c"))
		eq(loadout_signature(e["loadout"] as Dictionary), loadout_signature(loadout_for(i)), "%s's roster entry carries its loadout" % str(e["name"]))
	await _load()
	var go := await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0)
	if not check(go, "the load barrier passes (phase %s)" % Session.mission.phase):
		return
	var expected := crew_size
	if desync_index > 0:
		expected -= 1
		eq(Session.mission.desyncs.size(), 1, "the host found one desync")
		if not Session.mission.desyncs.is_empty():
			eq(str(Session.mission.desyncs[0]["name"]), "c%d" % desync_index, "the perturbed client is the one sent out")
		check(Session.telemetry == null or Array(Session.telemetry.notes).any(func(n: String) -> bool: return n.contains("DESYNC")),
			"the desync is noted in telemetry")
		check(await until(func() -> bool: return Session.roster.size() == expected, 10.0), "the desynced client is out of the crew")
	check(not td._held, "the host's mech is released after the barrier")
	var mine := _summary()
	eq(int(mine["seed"]), SEED, "the host built the mission seed")
	eq(str(mine["mode"]), str(Session.mission_params().get("mode", "")), "the host built the launched city mode")
	eq(str(mine["mechs"]), _expected_mechs(), "the host spawned one mech per crew member with its owner, head, accent and loadout")
	check(bool(mine["local_driven"]), "the host drives its own mech")
	eq(mine["friendly_fire"], true, "the host's test drive has friendly fire on (the default)")
	if not check(await wait_reports("mission", expected - 1, 40.0), "every client reports its mission"):
		return
	for p in peers_with("mission"):
		var theirs: Dictionary = reported(p, "mission")
		eq(int(theirs["seed"]), SEED, "peer %d built the mission seed" % p)
		eq(str(theirs["checksum"]), str(mine["checksum"]), "peer %d has the host's city checksum" % p)
		eq(str(theirs["mode"]), str(mine["mode"]), "peer %d built the same kind of city (%s)" % [p, str(mine["mode"])])
		eq(str(theirs["crew_state"]), "mission", "peer %d knows the crew is on a mission" % p)
		eq(str(theirs["mechs"]), str(mine["mechs"]), "peer %d has the same mechs (owners, heads, accents, loadouts)" % p)
		check(bool(theirs["local_driven"]), "peer %d drives its own mech" % p)
		eq(theirs.get("friendly_fire", null), true, "peer %d's test drive has friendly fire on (the default)" % p)
		check(not bool(theirs["held"]), "peer %d's mech was released" % p)
	if desync_index > 0:
		check(await until(func() -> bool: return Session.refusals.any(func(r: Dictionary) -> bool: return str(r["reason"]) == NetSession.ON_MISSION), 30.0),
			"the sent-out client trying to come back mid-mission is refused (%s)" % NetSession.ON_MISSION)
	Session.end_mission()
	eq(Session.crew_state, "lobby", "the host's crew is back in the lobby")
	check(await wait_reports("ended", expected - 1, 20.0), "every client hears the mission end")
	for p in peers_with("ended"):
		eq(str(reported(p, "ended")), "lobby", "peer %d is back in the lobby" % p)
	check(await wait_done(expected - 1, 20.0), "the clients are done")


func run_client() -> void:
	_configure()
	if desync_index > 0 and index == desync_index:
		expect_end = NetSession.DESYNC
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	var ended_mission := [false]
	Session.mission_ended.connect(func(_r: String) -> void: ended_mission[0] = true)
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	eq(int(Session.mission_params()["seed"]), SEED, "the launch carries the seed")
	eq(str(Session.mission_params()["mode"]), mission_mode, "the launch carries the city mode")
	eq(Session.crew_state, "mission", "the crew is on a mission here too")
	if index == desync_index:
		Session.mission.checksum_salt = "-perturbed"
	await _load()
	if index == desync_index:
		check(await until(func() -> bool: return ended, 30.0), "the desynced client is sent out")
		eq(ended_reason, NetSession.DESYNC, "it is told why (%s)" % NetSession.DESYNC)
		ended = false
		var again := await connect_client(3)
		eq(again, NetSession.ON_MISSION, "coming back mid-mission is refused")
		return
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0),
			"the load barrier passes here (phase %s)" % Session.mission.phase):
		return
	report("mission", _summary())
	check(await until(func() -> bool: return ended_mission[0], 30.0), "the host's mission end arrives")
	report("ended", Session.crew_state)


## Wait for start_t on the shared clock, then load the mission (the test drive) as the hangar would.
func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	check(td.crewed, "the test drive runs the crew mission")


## What this machine built: seed, checksum, crew state, and its mechs as one string (spawn order; a member sent out or
## gone has no mech any more: CrewSync.retire, so spawn_order, the launch crew, lists it without one).
func _summary() -> Dictionary:
	var parts: PackedStringArray = []
	for p: int in td.spawn_order:
		var m := td.mech_of(p)
		if m == null:
			continue
		var model := MechSpawn.rig_of(m).model
		parts.append("%d:%d:%s:%s:%s" % [p, MechSpawn.owner_of(m), model.head_id, MechAccent.applied(model), loadout_signature(model.loadout)])
	return {"seed": td.seed_value, "checksum": td.mission_checksum(), "mode": td.city_mode, "crew_state": Session.crew_state, "mechs": ";".join(parts),
		"local_driven": td.mech != null and MechSpawn.owner_of(td.mech) == Session.local_id() and td.cam.target == td.mech,
		"held": td._held, "friendly_fire": td.friendly_fire}


## The mechs the launch's crew should give, in seat order (members still in the crew: a leaver's mech is retired).
func _expected_mechs() -> String:
	var crew := (Session.mission_params()["crew"] as Array).duplicate()
	crew.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seat"]) < int(b["seat"]))
	var parts: PackedStringArray = []
	for e: Dictionary in crew:
		if not Session.has_member(int(e["peer"])):
			continue
		var l: Dictionary = WeaponRegistry.playable_loadout(str(e["chassis"]), e["loadout"] as Dictionary)["loadout"]
		parts.append("%d:%d:%s:%s:%s" % [int(e["peer"]), int(e["peer"]), str(e["head"]), str(e["accent"]), loadout_signature(l)])
	return ";".join(parts)
