extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## A Strider and a Bulwark damage, down and revive each other across machines (docs/networking.md: the victim decides
## hits on its own mech; component HP rides the mech snapshot as fractions of the owner's per-chassis max), a real crew
## mission of 2, once per link. Host A flies a Strider with a repair drone on its back, client B a Bulwark with one on
## back_r. World geometry off (shots meet hit spheres only).
## 1. B stands beside A. A fires autocannon shells at B's hull: B (the victim) applies them to its own Bulwark (900 HP
##    hull), A builds no Hit on B's puppet; after the snapshots A's puppet of B shows B's own component fractions.
## 2. B fires at A: A applies them to its own Strider, B builds none; B's puppet of A agrees with A.
## 3. B goes down (Bulwark as victim): A sees it downed and can revive; A's drone revives B on B's own machine once,
##    nobody else applies anything; fractions agree.
## 4. A goes down; B (a Bulwark with the drone on back_r) is a reviver for A, launches it, and A's own machine revives A
##    once; fractions agree.

const PEERS := 2
const SEED := 31
const HP_TOL := 0.012             ## component fraction: one snapshot step (1/254) plus rounding
const LIFE := 6.0                 ## s: the drones' life here (both machines)
const SIDE := 10.0                ## m: B stands this far to A's right
const A_LO := {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "", "shoulder_r": "", "back": "repair_drone"}
const B_LO := {"side_l": "autocannon", "side_r": "autocannon", "back_l": "mortar", "back_r": "repair_drone"}

var td: TestDrive
var world: CombatWorld
var net: CombatNet
var hits: Array = []              ## hit_landed here: {id, dmg, comp, shooter}
var revives := 0                  ## player_revived on this machine's OWN target
var puppet_revives := 0           ## player_revived on a puppet target here (must stay 0)


func run_host() -> void:
	net_timeout = 120.0
	Session.set_profile("host", head_for(0), "strider", accent_for(0), A_LO)
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var b := -1
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			b = int(e["peer"])
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	if not check(pb != null and tb != null, "A has B's puppet and target"):
		return
	eq(td.rig.model.chassis_id, "strider", "A flies a Strider")
	eq(tb.chassis, "bulwark", "A's copy of B's target is a Bulwark")
	near(float(tb.max_hp.get("torso", 0.0)), 900.0, 1e-6, "with the Bulwark's 900 HP hull")
	check(tb.max_hp.has("back_r") and not tb.max_hp.has("back"), "and its back_r component")
	# 1. A shoots B's hull.
	command(b, "near", {"to": td.mech.global_position + td.mech.global_basis.x * SIDE})
	if not check(await wait_reports("near", 1, 10.0), "B stands beside A"):
		return
	await sleep(0.6)
	var n0 := hits.size()
	var me := net.local_shooter
	var aim: Vector3 = pb.mech.global_position + pb.mech.up() * 5.0
	for i in 4:
		var o := td.mech.global_position + td.mech.up() * 5.0
		o += (aim - o).normalized() * 3.0
		world.fire(Combat.fire_record(me, Session.local_id(), "side_r", "autocannon", o, aim, world.now, 8000 + i, 0.0))
		await sleep(0.15)
	await sleep(1.0)
	eq(hits.slice(n0).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b).size(), 0,
		"A built no Hit on B's puppet")
	var v1 := await _collect(b, "hit_b")
	var on_b: Array = (v1.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
	check(on_b.size() > 0, "B applied A's shells to its own Bulwark (%d hits, parts %s)" % [on_b.size(), str(on_b.map(func(h: Dictionary) -> String: return str(h["comp"])))])
	check(float((v1["hp"] as Dictionary).get("torso", 1.0)) < 1.0, "B's hull took damage (%.3f)" % float((v1["hp"] as Dictionary).get("torso", 1.0)))
	_agree(v1["hp"] as Dictionary, tb, "A's puppet of B")
	# 2. B shoots A.
	var pt := td.combat.player_target
	var a_hits0 := hits.size()
	command(b, "fire", {"target": td.mech.global_position + td.mech.up() * 4.4})
	check(await wait_reports("fire", 1, 10.0), "B fired")
	await sleep(1.2)
	var mine := hits.slice(a_hits0).filter(func(h: Dictionary) -> bool: return str(h["id"]) == me)
	check(mine.size() > 0, "A applied B's shells to its own Strider (%d)" % mine.size())
	var v2 := await _collect(b, "hit_a")
	eq((v2.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == me).size(), 0,
		"B built no Hit on A's puppet")
	_agree_dict(pt.component_fractions(), v2.get("puppet_hp", {}) as Dictionary, "B's puppet of A")
	# 3. B goes down (Bulwark as victim); A revives it.
	command(b, "down", {})
	check(await wait_reports("down", 1, 10.0), "B went down")
	check(await until(func() -> bool: return tb.disabled, 5.0), "A sees B downed")
	check(td.downed.can_revive(Session.local_id()), "A (a Strider with a drone) can revive")
	var n := td.combat.rack.hardpoints.find("back") + 1
	check(n > 0 and td.combat.rack.activate(n), "A launches its drone")
	check(await until(func() -> bool: return not tb.disabled, 12.0), "A sees B revived")
	# (the drone keeps repairing 1 %/s while it flies: compare once it is home)
	check(await until(func() -> bool: return world.drone_of(me) == null, LIFE + 6.0), "A's drone flew home")
	await sleep(0.8)
	var v3 := await _collect(b, "revived_b")
	eq(int(v3["revives"]), 1, "B's own machine revived B once")
	eq(int(v3["puppet_revives"]), 0, "B applied nothing to A's puppet")
	eq(puppet_revives, 0, "A applied nothing to B (its puppet target)")
	_agree(v3["hp"] as Dictionary, tb, "A after B's revive")
	# 4. A goes down; B (the Bulwark, drone on back_r) revives A.
	pt.apply_damage(1000.0, "head", "test")
	check(pt.disabled, "A is down")
	check(td.downed.can_revive(b), "A's DownedCrew: B (a Bulwark with a back_r drone) can revive")
	command(b, "launch", {})
	check(await wait_reports("launch", 1, 10.0), "B launched")
	check(bool(reported(b, "launch")), "B's back_r drone is out")
	check(await until(func() -> bool: return not pt.disabled, 12.0), "A revived by B's drone")
	eq(revives, 1, "A's own machine applied the revive once")
	check(await until(func() -> bool: return world.drone_of("player%d" % b) == null, LIFE + 6.0), "B's drone flew home")
	await sleep(0.8)
	var v4 := await _collect(b, "revived_a")
	_agree_dict(pt.component_fractions(), v4.get("puppet_hp", {}) as Dictionary, "B's puppet of A after the revive")
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 120.0
	Session.set_profile(Session.player_name, Session.local_head(), "bulwark", "", B_LO)
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	check(td.rig.model.chassis_id == "bulwark" and td.combat.player_target.chassis == "bulwark", "B flies a Bulwark")
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var data: Dictionary = c.get("data", {}) if c.get("data") is Dictionary else c
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), _state())
			"near":
				td.mech.global_position = (data["to"] as Vector3) + td.mech.up() * 1.0
				td.mech.velocity = Vector3.ZERO
				MechSpawn.rig_of(td.mech).gait.reset([])
				await sleep(0.4)
				report("near", td.mech.global_position)
			"fire":
				var p := CombatWorld.local_peer()
				for i in 4:
					var o := td.mech.global_position + td.mech.up() * 6.4
					o += ((data["target"] as Vector3) - o).normalized() * 4.0
					world.fire(Combat.fire_record("player%d" % p, p, "side_l", "autocannon", o, data["target"], world.now, 9000 + i, 0.0))
					await sleep(0.15)
				report("fire", true)
			"down":
				td.combat.player_target.apply_damage(1000.0, "head", "test")
				report("down", td.combat.player_target.disabled)
			"launch":
				var rack := td.combat.rack
				var n := rack.hardpoints.find("back_r") + 1
				var ok := n > 0 and rack.activate(n)
				report("launch", ok and world.drone_of(rack.shooter) != null)


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null and td.downed != null, "the crew mission runs"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	world.use_physics = false
	world.overrides["repair_drone"] = {"life": LIFE}
	net = td.combat.net
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		hits.append({"id": t.target_id, "dmg": h.damage, "comp": h.component, "shooter": h.shooter}))
	td.combat.player_target.player_revived.connect(func(_by: String, _t: float) -> void: revives += 1)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	if not check(await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1 and _shown(), 10.0), "the puppet is shown"):
		return false
	for p: int in td.crew_sync.targets:
		(td.crew_sync.targets[p] as PlayerTarget).player_revived.connect(func(_by: String, _t: float) -> void: puppet_revives += 1)
	td.combat.squad.clear_enemies()
	return true


func _shown() -> bool:
	for p: int in td.crew_sync.puppets:
		if (td.crew_sync.puppets[p] as MechPuppet).shown == null:
			return false
	return true


func _state() -> Dictionary:
	var php := {}
	for p: int in td.crew_sync.targets:
		php = (td.crew_sync.targets[p] as PlayerTarget).component_fractions()
	return {"hits": hits, "hp": td.combat.player_target.component_fractions(), "puppet_hp": php, "revives": revives,
		"puppet_revives": puppet_revives}


func _collect(p: int, key: String) -> Dictionary:
	command(p, "report", {"key": key})
	check(await wait_reports(key, 1, 15.0), "the client reports %s" % key)
	return reported(p, key) if p in peers_with(key) else {}


func _agree(theirs: Dictionary, t: PlayerTarget, tag: String) -> void:
	_agree_dict(theirs, t.component_fractions(), tag)


func _agree_dict(theirs: Dictionary, mine: Dictionary, tag: String) -> void:
	check(not theirs.is_empty(), "%s: the owner's components arrived" % tag)
	for k: String in theirs:
		near(float(mine.get(k, -1.0)), float(theirs[k]), HP_TOL, "%s: %s agrees" % [tag, k])
