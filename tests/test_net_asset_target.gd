extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Mission assets across machines (docs/design/weapons.md §5 "Mission assets") over a real crew mission of 2, once per
## link (off, coast). Both machines MissionCombat.add_asset("relay", node) at the same point (the host sends it); the
## drive's combat `_drive` is pointed at a stand-in with a stub `mission` (damage_asset recorder) on both machines.
## 1. Enemy fire (the host fires an enemy record, as EnemyBase._fire_one_round builds it; EnemySync carries it to the
##    client) on the asset: the host's stub gets damage_asset exactly once with the weapon's damage; the client's nothing,
##    and the client sends no remote hit for it.
## 2. The host pushes its HP to both machines with set_hp (standing in for MissionFlow's state stream): both show the same
##    hp_fraction().
## 3. The client's own shot at the asset (friendly fire on) is decided on the client and arrives on the host once through
##    "combat.hit": the host's stub gets one damage_asset, the client's none.

const PEERS := 2
const SEED := 13
const ID := "relay"
const MAX := 600.0


class StubMission extends Node:
	var calls: Array = []

	func damage_asset(id: String, amount: float) -> void:
		calls.append([id, amount])


class StubDrive extends Node:
	var mission: Node = null


var td: MissionScene
var world: CombatWorld
var net: CombatNet
var stub: StubMission
var asset: AssetTarget
var remote_hits := 0


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client is ready"):
		return
	var b := _other_peer()
	var up := Vector3.UP
	var at := td.mech.global_position + td.mech.forward() * 14.0 + up * 4.0
	_add(at)
	command(b, "add", {"at": [at.x, at.y, at.z]})
	if not check(await wait_reports("added", 1, 10.0), "the client added the asset"):
		return
	check(world.friendly_fire, "friendly fire is on in this mission")
	var c := at + up * 3.0

	# 1. Enemy fire on the asset -------------------------------------------------------------------------------
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var dmg := float(world.stats(w).get("damage", 0.0))
	var rec := Combat.fire_record("enemy_asset_test", 1, w, w, c + up * 9.0, c, world.now, 8100, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	check(world.fire(rec) != null, "the host fires the enemy record")
	await sleep(1.5)
	eq(stub.calls.size(), 1, "the host's mission got damage_asset once for the enemy hit")
	if stub.calls.size() == 1:
		eq(str(stub.calls[0][0]), ID, "with the asset id")
		near(float(stub.calls[0][1]), dmg, 0.01, "with the weapon's damage")
	command(b, "report", {"key": "after_enemy"})
	if check(await wait_reports("after_enemy", 1, 10.0), "the client reports"):
		var v: Dictionary = reported(b, "after_enemy")
		eq(int(v["calls"]), 0, "the client's mission got nothing")
		eq(int(v["remote_hits"]), 0, "the client sent no remote hit for the enemy shot")
		check(int(v["enemy_fired"]) >= 1, "the enemy record reached the client (it drew the shot)")

	# 2. The host's HP to both machines ------------------------------------------------------------------------
	var hp := MAX - dmg
	asset.set_hp(hp, MAX)
	command(b, "hp", {"v": hp, "max": MAX})
	if check(await wait_reports("hp", 1, 10.0), "the client applied the HP"):
		near(float(reported(b, "hp")), asset.hp_fraction(), 1e-5, "both machines show the same hp_fraction (%.3f)" %
			asset.hp_fraction())

	# 3. The client's own shot -------------------------------------------------------------------------------
	stub.calls.clear()
	var applied0 := int(net.stats["hits_applied"])
	command(b, "shoot", {"at": [c.x, c.y, c.z]})
	if check(await wait_reports("shot", 1, 10.0), "the client fired"):
		await sleep(1.5)
		eq(stub.calls.size(), 1, "the client's shot reached the host's mission once (combat.hit)")
		eq(int(net.stats["hits_applied"]) - applied0, 1, "CombatNet applied it once on the host")
		command(b, "report", {"key": "after_shot"})
		if check(await wait_reports("after_shot", 1, 10.0), "the client reports again"):
			var v: Dictionary = reported(b, "after_shot")
			eq(int(v["calls"]), 0, "the client's mission still got nothing")
			check(int(v["hits_sent"]) >= 1, "the client sent the hit to the host")
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 90.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	var enemy_fired := [0]
	world.fired.connect(func(r: Dictionary) -> void:
		if str(r.get("shooter", "")) == "enemy_asset_test":
			enemy_fired[0] += 1)
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"add":
				var a: Array = c["at"]
				_add(Vector3(float(a[0]), float(a[1]), float(a[2])))
				report("added", true)
			"report":
				report(str(c["key"]), {"calls": stub.calls.size(), "remote_hits": remote_hits,
					"enemy_fired": enemy_fired[0], "hits_sent": int(net.stats["hits_sent"])})
			"hp":
				asset.set_hp(float(c["v"]), float(c["max"]))
				report("hp", asset.hp_fraction())
			"shoot":
				var a: Array = c["at"]
				var at := Vector3(float(a[0]), float(a[1]), float(a[2]))
				var me := Session.local_id()
				var r := Combat.fire_record("player%d" % me, me, "side_r", "autocannon", at + Vector3.UP * 9.0, at,
					world.now, 8200, 0.0)
				world.fire(r)
				report("shot", true)


func _add(at: Vector3) -> void:
	var site := Node3D.new()
	site.name = "AssetSite"
	add_child(site)
	site.global_position = at
	asset = td.combat.add_asset(ID, site, 2.5, 6.0)
	check(asset != null and asset.target_id == "asset_relay", "add_asset made asset_relay")


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null and td.enemy_sync != null,
			"the crew mission runs CombatNet and EnemySync"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	net = td.combat.net
	# The mission stand-in: add_asset's handler reads `_drive.mission` per hit.
	var drive := StubDrive.new()
	stub = StubMission.new()
	drive.mission = stub
	add_child(drive)
	drive.add_child(stub)
	td.combat._drive = drive
	world.remote_hit.connect(func(id: String, _h: Hit) -> void:
		if id == "asset_" + ID:
			remote_hits += 1)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return true


func _other_peer() -> int:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			return int(e["peer"])
	return -1
