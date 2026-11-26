extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## A crew member quits mid-mission (audit #1, the "leaver decoy"; CrewSync.retire on Session.peer_left), a real crew
## mission of 3 in the stack, once per link (off, coast). Host A, client c1 = B (stays), client c2 = C (leaves).
## 1. Every machine has C's puppet and its PlayerTarget registered in CombatWorld (an enemy could pick it).
## 2. C goes down (a revive target), then quits (Session.leave: its transport closes, no bye).
## 3. On A and B: C's PlayerTarget leaves CombatWorld and is freed, its puppet and mech are gone (TestDrive.mechs,
##    crew_members, crew facts), C is no longer listed as downed (no DOWN marker), and Session.mechs no longer buffers it.
## 4. A's enemies run their live AI for a few seconds: none of them holds a target owned by C, no hit lands on C, and
##    the mission keeps running (phase RUNNING, no outcome) with the crew of 2.
## 5. The host's leaver hook: TestDrive.crew_member_left(C) fires once on the host (never on B), when crew_members() no
##    longer lists C, and MissionFlow.on_member_retired(C) is called (checked through a stub MissionFlow until MissionFlow
##    has the method).

const PEERS := 3
const SEED := 11
const WATCH := 4.0                ## s of live enemy AI after the leave

var td: TestDrive
var world: CombatWorld
var leaver_hits := 0              ## hits that landed on a target owned by the leaver after it left
var left_signals: Array = []      ## [pilot id, listed in crew_members() at that moment] per crew_member_left here


## Stands in for MissionFlow's leaver hook until MissionFlow has it (never added to the tree).
class StubFlow extends MissionFlow:
	var told: Array[int] = []

	func on_member_retired(pilot_id: int) -> void:
		told.append(pilot_id)


func run_host() -> void:
	net_timeout = 120.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 40.0), "the clients are ready"):
		return
	var b := -1
	var c := -1
	for p: int in peers_with("ready"):
		var ix := int((reported(p, "ready") as Dictionary)["index"])
		if ix == 1:
			b = p
		elif ix == 2:
			c = p
	if not check(b > 0 and c > 0, "B and C known (%d, %d)" % [b, c]):
		return
	# 1. C is a target here.
	var tc: PlayerTarget = td.crew_sync.targets.get(c)
	if not check(tc != null and tc in world.targets and tc.owner_peer == c, "A has C's PlayerTarget in CombatWorld"):
		return
	var mc := td.mech_of(c)
	check(mc != null, "A has C's mech")
	# 2. C goes down, then quits.
	command(c, "down", {})
	if not check(await wait_reports("down", 1, 10.0), "C went down"):
		return
	check(await until(func() -> bool: return tc.disabled, 5.0), "A sees C downed")
	check(_listed_down(c), "A lists C as downed before it leaves")
	for e in td.combat.squad.enemies:
		if is_instance_valid(e):
			e.ai_mode = "live"
	world.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void:
		if is_instance_valid(t) and t.owner_peer == c and not td.crew_sync.targets.has(c):
			leaver_hits += 1)
	td.crew_member_left.connect(func(id: int) -> void: left_signals.append([id, _in_members(id)]))
	command(c, "leave", {})
	# 3. A retires C.
	if not check(await until(func() -> bool: return not Session.roster.has(c), 20.0), "A drops C from the roster"):
		return
	check(await until(func() -> bool: return td.crew_sync.retired.has(c), 5.0), "A retired C's mech")
	await frames(2)
	check(not is_instance_valid(tc), "C's PlayerTarget is freed on A")
	check(not is_instance_valid(mc), "C's mech is freed on A")
	check(_no_target_of(c), "no CombatWorld target on A is owned by C")
	check(not td.crew_sync.puppets.has(c) and not td.crew_sync.targets.has(c), "A's CrewSync forgot C")
	check(not td.mechs.has(c), "A's TestDrive.mechs has no C")
	check(not _in_members(c), "A's crew_members() has no C")
	eq(td.crew_members().size(), 2, "A's crew is 2")
	if td.mission != null:
		eq(td.mission.crew_facts().size(), 2, "A's crew facts list 2 pilots")
	check(not _listed_down(c), "A no longer lists C as downed")
	check(Session.mechs.buffer(c) == null, "A's Session.mechs dropped C's buffer")
	# 4. The enemies hunt for a while: nothing targets or hits C.
	var held := false
	var t0 := wall()
	while wall() - t0 < WATCH:
		await get_tree().physics_frame
		for e in td.combat.squad.enemies:
			if not is_instance_valid(e):
				continue
			var ct: Variant = e.get("_cached_target")
			if ct != null and is_instance_valid(ct) and (ct as CombatTarget).owner_peer == c:
				held = true
	check(not held, "no enemy on A holds a target owned by C")
	eq(leaver_hits, 0, "no hit landed on C after it left")
	eq(Session.mission.phase, NetMission.RUNNING, "the mission keeps running")
	eq(str(Session.mission.state.get("outcome", "")), "", "the mission has no outcome")
	# 5. The leaver hook.
	eq(left_signals.size(), 1, "crew_member_left fired once on the host")
	if not left_signals.is_empty():
		eq(int(left_signals[0][0]), c, "crew_member_left names C")
		check(not bool(left_signals[0][1]), "crew_members() no longer listed C when crew_member_left fired")
	if td.mission != null and td.mission.has_method("on_member_retired"):
		eq(td._told, [c] as Array[int], "MissionFlow.on_member_retired(C) was called once on the host")
	else:
		var real := td.mission
		var stub := StubFlow.new()
		td.mission = stub
		td._tell_mission_retired(c)
		td.mission = real
		eq(stub.told, [c] as Array[int], "the hook reaches MissionFlow.on_member_retired (stub: MissionFlow lacks it yet)")
		stub.free()
	command(b, "look", {"peer": c})
	if check(await wait_reports("look", 1, 15.0), "B reports its view"):
		var vb: Dictionary = reported(b, "look")
		check(bool(vb["retired"]), "B retired C's mech")
		check(bool(vb["target_gone"]), "B's CombatWorld has no target owned by C")
		check(bool(vb["mech_gone"]), "B's TestDrive.mechs has no C, and C's mech is freed")
		check(not bool(vb["member"]), "B's crew_members() has no C")
		check(not bool(vb["down"]), "B no longer lists C as downed")
		eq(int(vb["crew"]), 2, "B's crew is 2")
		eq(int(vb["roster"]), 2, "B's roster is 2")
		check(bool(vb["running"]), "B's mission keeps running")
		eq(int(vb["left_signals"]), 0, "B (a client) fires no crew_member_left")
		eq(int(vb["told"]), 0, "B (a client) never calls on_member_retired")
	command(b, "finish", {})
	check(await wait_done(1, 20.0), "B is done")


func run_client() -> void:
	net_timeout = 120.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", {"index": index})
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var data: Dictionary = c.get("data", {}) if c.get("data") is Dictionary else c
		match str(c["cmd"]):
			"finish":
				return
			"down":
				var pt := td.combat.player_target
				pt.apply_damage(300.0, "torso", "test")
				pt.apply_damage(1000.0, "head", "test")
				await sleep(0.5)   # a few snapshots carry the downed flag out
				report("down", pt.disabled)
			"leave":
				await sleep(0.2)
				Session.leave()
				return
			"look":
				var p := int(data["peer"])
				await until(func() -> bool: return td.crew_sync.retired.has(p), 10.0)
				await frames(2)
				report("look", {"retired": td.crew_sync.retired.has(p), "target_gone": _no_target_of(p),
					"mech_gone": not td.mechs.has(p) and not td.crew_sync.puppets.has(p), "member": _in_members(p),
					"down": _listed_down(p), "crew": td.crew_members().size(), "roster": Session.roster.size(),
					"running": Session.mission.phase == NetMission.RUNNING, "left_signals": left_signals.size(),
					"told": td._told.size()})


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.downed != null, "the crew mission runs with CrewSync"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	td.combat.player_target.auto_respawn_delay = -1.0
	if not is_host():
		td.crew_member_left.connect(func(id: int) -> void: left_signals.append([id, _in_members(id)]))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	if not check(await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0), "the puppets exist"):
		return false
	# Nobody shoots the crew before the leave (the host turns the AI back on for step 4).
	for e in td.combat.squad.enemies:
		if is_instance_valid(e):
			e.ai_mode = "idle"
	return true


func _no_target_of(peer: int) -> bool:
	for t in world.targets:
		if is_instance_valid(t) and t is PlayerTarget and (t as PlayerTarget).owner_peer == peer:
			return false
	return true


func _in_members(peer: int) -> bool:
	for m: Dictionary in td.crew_members():
		if int(m["peer"]) == peer:
			return true
	return false


func _listed_down(peer: int) -> bool:
	for e: Dictionary in td.downed.downed_crew():
		if int(e["peer"]) == peer:
			return true
	return false
