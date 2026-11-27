extends NetTest
## The crew scale is the host's, and it eases off when a pilot leaves (AGENTS.md rule 8; user 2026-11-25: "Run it from the
## host, enforce this! And ease off when a player leaves."; MissionFlow CREW SCALE, NetMission SCALE). A crew of 3 in plan
## mode (seed 7: a defend relay), once per link. Host A, client c1 = B (stays), client c2 = C (leaves).
## 1. The launch carries the host's scale 3; every machine reports crew_scale() 3, the director's crew_n / deck cap and the
##    relay's max HP from it, and the same depot cores.
## 2. A sets the relay to a known fraction (0.4): every machine mirrors it.
## 3. C quits. At the moment B sees C gone from its roster (its local count says 2) B still plays the host's 3: the change
##    is scheduled at `at` on the shared clock.
## 4. A and B apply the new scale 2 at the SAME `at` (each records the at it applied: equal), and agree on the director's
##    crew_n, deck cap, ENGAGE_TARGET and the relay's max HP; the relay keeps its fraction (0.4) while its max HP changed;
##    depot cores unchanged.
## 5. A duplicate and a late mission.scale (an older at, a higher n) are ignored on B.

const PEERS := 3
const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}
## No director pressure for the test (no rest ends, no quiet cap): the scale, not the fight, is under test.
const DIRECTOR := {"rest_first": 100000.0, "rest_last": 100000.0, "arrival_rest": 100000.0, "quiet_cap": 100000.0}
const FRACTION := 0.4

var td: MissionScene
var gone_view: Dictionary = {}    ## B: what it saw the moment C left its roster


func run_host() -> void:
	net_timeout = 180.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	eq(int(Session.mission.params.get("scale", 0)), 3, "the launch carries the host's scale 3")
	if not await _load_and_go():
		return
	var mf := td.mission
	_kill_all()
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
	# 1. Scale 3 everywhere, from the host's value.
	var mine := _view()
	eq(int(mine["scale"]), 3, "A: crew_scale() 3")
	eq(int(mine["crew_n"]), 3, "A: the director's crew_n 3")
	for p: int in [b, c]:
		var v: Dictionary = reported(p, "ready")
		eq(int(v["scale"]), 3, "client %d: crew_scale() 3 (the host's)" % p)
		eq([int(v["crew_n"]), int(v["deck_cap"]), str(v["max_hp"]), str(v["cores"])],
			[int(mine["crew_n"]), int(mine["deck_cap"]), str(mine["max_hp"]), str(mine["cores"])],
			"client %d: crew_n, deck cap, relay max HP and depot cores agree with the host" % p)
	# 2. The relay at a known fraction.
	var rid := _relay_id()
	if not check(rid != "", "the plan has a defend relay"):
		return
	mf.set_asset_hp(rid, FRACTION)
	await sleep(1.0)
	command(b, "frac", {"id": rid})
	if check(await wait_reports("frac", 1, 15.0), "B reports the relay"):
		near(float(reported(b, "frac")), FRACTION, 0.011, "B mirrors the relay's fraction")
	var max3 := mf.asset_max_hp()
	var cores3 := str(mine["cores"])
	# 3. C leaves; B watches its roster.
	command(b, "watch", {"peer": c})
	if not check(await wait_reports("watching", 1, 15.0), "B watches"):
		return
	command(c, "leave", {})
	if not check(await until(func() -> bool: return not Session.roster.has(c), 20.0), "A drops C"):
		return
	if not check(await until(func() -> bool: return mf.crew_scale() == 2, 10.0), "A applies the new scale 2"):
		return
	# 4. A's side.
	var host_at := float(mf.scale_log[-1]["at"]) if not mf.scale_log.is_empty() else NAN
	eq(mf.scale_log.size(), 1, "A applied one change")
	if not mf.scale_log.is_empty():
		eq([int(mf.scale_log[0]["from"]), int(mf.scale_log[0]["to"]), str(mf.scale_log[0]["reason"]), int(mf.scale_log[0]["pilot"])],
			[3, 2, "leave", c], "A's change: 3 -> 2, a leave, pilot C")
		check(float(mf.scale_log[0]["t"]) >= host_at, "A applied it at or after its `at`")
	var after := _view()
	eq(int(after["crew_n"]), 2, "A: crew_n 2")
	eq(int(after["deck_cap"]), int(PacingDirector.DECK_CAP_BY_CREW[1]), "A: deck cap 16")
	near(float(after["max_hp"]), MissionFlow.ASSET_MAX_HP * float(MissionFlow.ASSET_HP_SCALE[1]), 0.01, "A: relay max HP 810")
	check(absf(float(after["max_hp"]) - max3) > 1.0, "the relay's max HP changed (%.0f -> %.0f)" % [max3, float(after["max_hp"])])
	near(float(mf.asset_hp[rid]), FRACTION, 1e-6, "A: the relay keeps its fraction")
	eq(str(after["cores"]), cores3, "A: depot cores unchanged")
	command(b, "after", {"id": rid})
	if check(await wait_reports("after", 1, 20.0), "B reports after the change"):
		var v: Dictionary = reported(b, "after")
		eq(int(v["scale"]), 2, "B: crew_scale() 2")
		eq(str(v["at"]), "%.6f" % host_at, "B applied it at the same shared-clock `at` as A")
		eq([int(v["crew_n"]), int(v["deck_cap"]), int(v["engage"]), str(v["max_hp"])],
			[int(after["crew_n"]), int(after["deck_cap"]), int(after["engage"]), str(after["max_hp"])],
			"B: crew_n, deck cap, ENGAGE_TARGET and relay max HP agree with A")
		near(float(v["frac"]), FRACTION, 0.011, "B: the relay keeps its fraction")
		eq(str(v["cores"]), cores3, "B: depot cores unchanged")
		eq(int(v["applied"]), 1, "B applied one change")
		var gv: Dictionary = v["gone"]
		eq(int(gv.get("roster", -1)), 2, "B saw C leave its roster (its local count: 2)")
		eq(int(gv.get("scale", -1)), 3, "... and still played the host's 3 then (the change waits for its `at`)")
		check(float(gv.get("t", INF)) < host_at, "... before the `at` (%.3f < %.3f)" % [float(gv.get("t", INF)), host_at])
	# 5. A duplicate and a late copy.
	var last: Dictionary = Session.mission.scales[-1] if not Session.mission.scales.is_empty() else {}
	if check(not last.is_empty(), "A kept the change it sent"):
		Session.mission.host_scale(last)
		Session.mission.host_scale({"n": 3, "at": host_at - 5.0, "from": 2, "reason": "test", "pilot": 0})
		await sleep(1.0)
		command(b, "dups", {})
		if check(await wait_reports("dups", 1, 15.0), "B reports after the duplicates"):
			var v: Dictionary = reported(b, "dups")
			eq(int(v["scale"]), 2, "B: still 2")
			eq(int(v["applied"]), 1, "B: nothing more applied")
			check(int(v["dups"]) >= 2, "B: the duplicate and the late copy counted as ignored (%d)" % int(v["dups"]))
	command(b, "finish", {})
	check(await wait_done(1, 20.0), "B is done")
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}


func run_client() -> void:
	net_timeout = 180.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	var v := _view()
	v["index"] = index
	report("ready", v)
	while true:
		var c := await wait_command(120.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var mf := td.mission
		match str(c["cmd"]):
			"finish":
				MissionFlow.test_plan = {}
				MissionFlow.test_director = {}
				return
			"leave":
				await sleep(0.2)
				Session.leave()
				MissionFlow.test_plan = {}
				MissionFlow.test_director = {}
				return
			"frac":
				await until(func() -> bool: return absf(float(mf.asset_hp.get(str(c["id"]), 1.0)) - FRACTION) < 0.011, 5.0)
				report("frac", float(mf.asset_hp.get(str(c["id"]), -1.0)))
			"watch":
				var who := int(c["peer"])
				Session.peer_left.connect(func(p: int) -> void:
					if p == who and gone_view.is_empty():
						gone_view = {"roster": Session.roster.size(), "scale": mf.crew_scale(), "t": Session.host_time()})
				report("watching", true)
			"after":
				await until(func() -> bool: return mf.crew_scale() == 2, 10.0)
				var a := _view()
				a["at"] = "%.6f" % float(mf.scale_at)
				a["frac"] = float(mf.asset_hp.get(str(c["id"]), -1.0))
				a["applied"] = mf.scale_log.size()
				a["gone"] = gone_view
				report("after", a)
			"dups":
				report("dups", {"scale": mf.crew_scale(), "applied": mf.scale_log.size(), "dups": mf.scale_dups})


## This machine's scale-dependent reads.
func _view() -> Dictionary:
	var mf := td.mission
	var cores := {}
	if mf.depots != null:
		for id: String in mf.depots.cores_max:
			cores[id] = int(mf.depots.cores_max[id])
	return {"scale": mf.crew_scale(), "crew_n": mf.director.crew_n, "deck_cap": int(mf.director.options["deck_cap"]),
		"engage": mf.director.engage_target(), "max_hp": "%.2f" % mf.asset_max_hp(), "cores": str(cores),
		"local": Session.roster.size()}


func _relay_id() -> String:
	for o: Dictionary in td.mission.plan.objectives:
		if str(o["type"]) == "defend":
			return str(o["id"])
	return ""


func _kill_all() -> void:
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.mission != null and td.mission.director != null, "the crew mission runs in plan mode"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.player_target.auto_respawn_delay = -1.0
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return check(await until(func() -> bool: return td.crew_sync.puppets.size() >= peers - 1, 10.0), "the puppets exist")
