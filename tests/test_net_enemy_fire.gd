extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Enemy fire across machines (W4 weapons side, docs/design/weapons.md §5.1) over a real crew mission of 2, once per link
## (off, coast). The host's EnemySync carries every enemy fire record in "enemy.ev"; CombatNet guards it on the client
## (CombatWorld.fire_gate). The host fires the record through CombatWorld.fire with peer 1, "enemy" true and team "enemy",
## exactly what EnemyBase._fire_one_round builds (the host's enemies are idle so nothing else shoots).
## 1. The record appears on the client with the same origin, direction and start time t.
## 2. It strikes the client's own mech: only the client applies the damage, once (src = the enemy's id); the host builds
##    no Hit on its puppet of the client and sends no remote_hit; the puppet's HP drops only through the client's snapshot.
## 3. The same record arriving again on the client is dropped (CombatNet stats enemy_dup), still one shot and one hit.
## 4. An "enemy.ev" fire item sent by the client (a non-host) is ignored by the host (nothing fires there).
## Props / ambient life from an enemy shot (peer 1) are decided by the host only (CombatWorld.decides_shot).
## 5. An enemy record fired on the client while its CombatWorld steps the targets it owns (a locally simulated enemy) is
##    refused (stats enemy_local_refused) and never flies.

const PEERS := 2
const SEED := 11
const SHOOTER := "enemy_fire_test"

var td: MissionScene
var world: CombatWorld
var net: CombatNet
var fired := {}                    ## shot key -> {origin, dir, t, n}
var damage_in: Array = []          ## [amount, component, src] on this machine's own PlayerTarget
var puppet_hits := 0               ## host: hit_landed on its puppet of the client
var remote_hits := 0


## A CombatTarget the client owns whose tick fires an enemy record (what a client-side enemy AI would do).
class LocalFirer extends CombatTarget:
	var w: CombatWorld
	var rec: Dictionary
	var tries := 0

	func net_fields() -> Dictionary:
		var f := super.net_fields()
		f.merge({"w": Net.LOCAL, "rec": Net.LOCAL, "tries": Net.LOCAL})
		return f

	func tick(_dt: float, _space: PhysicsDirectSpaceState3D = null) -> void:
		if tries < 3:
			tries += 1
			var r := rec.duplicate()
			r["shot_index"] = int(r["shot_index"]) + tries
			w.fire(r)


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
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	if not check(pb != null and tb != null, "the host has the client's puppet"):
		return
	world.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void:
		if t == tb:
			puppet_hits += 1)
	world.remote_hit.connect(func(_id: String, _h: Hit) -> void: remote_hits += 1)
	var hp0 := tb.total_hp()

	# 1-2. Fire at the client's mech ---------------------------------------------------------------------------
	var fwd := td.mech.forward()
	var aim_at: Vector3 = tb.world_spheres()[0]["center"]
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var rec := Combat.fire_record(SHOOTER, 1, w, w, aim_at + fwd * 12.0, aim_at, world.now, 7700, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	var key := Combat.shot_key(rec)
	var e := world.fire(rec)
	check(e != null, "the host fires the enemy record")
	await sleep(1.2)
	# 3. The same record again (a replayed "enemy.ev" fire item).
	Session.send_event(0, EnemySync.EV, {"l": [["fire", 0, rec.duplicate()]]})
	await sleep(0.8)
	command(b, "report", {"key": "shot"})
	if check(await wait_reports("shot", 1, 10.0), "the client reports"):
		var v: Dictionary = reported(b, "shot")
		var got: Dictionary = (v["fired"] as Dictionary).get(key, {})
		if check(not got.is_empty(), "the enemy record arrived on the client"):
			check((got["origin"] as Vector3).is_equal_approx(rec["origin"]), "same origin")
			check((got["dir"] as Vector3).is_equal_approx(rec["dir"]), "same direction")
			eq(float(got["t"]), float(rec["t"]), "same start time t")
			eq(int(got["n"]), 1, "fired once on the client (the repeat was dropped)")
		var from_enemy := 0
		var amount := 0.0
		for d: Array in v["damage"]:
			if str(d[2]) == SHOOTER:
				from_enemy += 1
				amount += float(d[0])
		eq(from_enemy, 1, "the client applied the enemy shot to its own mech once (%.1f dmg)" % amount)
		check(int((v["stats"] as Dictionary)["enemy_dup"]) >= 1, "the client's CombatNet dropped the repeat")
		eq(int(v["fire_refused"]), 0, "EnemySync refused nothing")
		check(not bool(v["decides_shot"]), "the client does not decide props / life for an enemy shot")
		check(world.decides_shot(rec), "the host does")
		await sleep(0.4)
		check(tb.total_hp() < hp0 - amount * 0.5, "the host's puppet shows the damage through the snapshot (%.0f -> %.0f)" % [
			hp0, tb.total_hp()])
	eq(puppet_hits, 0, "the host built no Hit on the client's puppet")
	eq(remote_hits, 0, "and sent no remote_hit for it")

	# 4. A non-host's enemy fire item is ignored --------------------------------------------------------------
	var n_before := int(fired.size())
	command(b, "forge", {})
	if check(await wait_reports("forged", 1, 10.0), "the client sent a forged enemy record"):
		await sleep(0.8)
		eq(fired.size(), n_before, "the host fired nothing from the client's enemy record")
		eq(int(td.enemy_sync.stats["fire_recv"]), 0, "the host's EnemySync took no fire item")

	# 5. A locally simulated enemy shot on the client ----------------------------------------------------------
	command(b, "local", {})
	if check(await wait_reports("local", 1, 10.0), "the client tried a local enemy shot"):
		var v: Dictionary = reported(b, "local")
		check(int(v["refused"]) >= 1, "the client's gate refused it (%d)" % int(v["refused"]))
		eq(int(v["flew"]), 0, "and it never flew")
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
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), {"fired": fired, "damage": damage_in, "stats": net.stats,
					"fire_refused": int(td.enemy_sync.stats["fire_refused"]),
					"decides_shot": world.decides_shot({"peer": 1, "enemy": true, "team": "enemy"})})
			"forge":
				var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
				var r := Combat.fire_record(SHOOTER, 1, w, w, td.mech.global_position + Vector3.UP * 30.0,
					td.mech.global_position + Vector3.UP * 30.0 + td.mech.forward() * 50.0, world.now, 7800, 0.0)
				r["enemy"] = true
				r["team"] = "enemy"
				Session.send_event(1, EnemySync.EV, {"l": [["fire", 0, r]]})
				report("forged", true)
			"local":
				var before := int(net.stats["enemy_local_refused"])
				var n0 := fired.size()
				var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
				var f := LocalFirer.new()
				f.target_id = "local_enemy"
				f.owner_peer = Session.local_id()
				f.team = "enemy"
				f.w = world
				f.rec = Combat.fire_record("local_enemy", 1, w, w, td.mech.global_position + Vector3.UP * 40.0,
					td.mech.global_position + Vector3.UP * 40.0 + td.mech.forward() * 50.0, world.now, 7900, 0.0)
				f.rec["enemy"] = true
				f.rec["team"] = "enemy"
				add_child(f)
				world.register(f)
				await until(func() -> bool: return f.tries >= 3, 3.0)
				world.unregister(f)
				f.queue_free()
				report("local", {"refused": int(net.stats["enemy_local_refused"]) - before, "flew": fired.size() - n0})


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
	world.fired.connect(func(r: Dictionary) -> void:
		if bool(r.get("enemy", false)):
			var k := Combat.shot_key(r)
			var prev: Dictionary = fired.get(k, {})
			fired[k] = {"origin": r["origin"], "dir": r["dir"], "t": r["t"], "n": int(prev.get("n", 0)) + 1})
	td.combat.player_target.damaged.connect(func(amount: float, comp: String, src: String) -> void:
		damage_in.append([amount, comp, src]))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return await until(_puppet_shown, 10.0)


func _puppet_shown() -> bool:
	return td.crew_sync.puppets.size() == peers - 1 and (td.crew_sync.puppets.values()[0] as MechPuppet).shown != null


func _other_peer() -> int:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			return int(e["peer"])
	return -1
