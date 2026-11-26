extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## A shot that hit on its deciding machine is dropped on every other machine (docs/design/weapons.md §5.1, code audit
## 2026-11 #4), over a crew of 3 (host A shoots, c1 = B, c2 = C watches), once per link. World geometry is off on every
## machine, so only hit spheres stop a shot. Positions are made to disagree on purpose, as latency / interpolation can:
## 1. ATTACKER DECIDES: a host-owned dummy T exists on the host ONLY, 40 m above B's torso on the line of an autocannon
##    shell fired straight down at B from 80 m up. On A the shell hits T (A decides it: T is host-owned, A shot it). On
##    B and C there is no T, so their copies fly on toward B. B must take nothing: A's hit reaches them (combat.hit
##    drop) and their copies end there, long before they reach B (40 m at 70 m/s = 0.57 s), with one impact at T.
## 2. VICTIM DECIDES: A has friendly fire OFF (its copy passes its puppet of B), B and C have it on; T is on the host only,
##    40 m BELOW B. B's copy hits B (B decides its own mech) and B's drop must stop A's copy before it reaches T.
## In both, exactly one thing takes the shell across the three machines, and no copy is still flying 0.45 s after the
## deciding hit.

const PEERS := 3
const NET_TIMEOUT := 150         ## three processes load a mission: past the runner's 90 s default on a busy machine
const SEED := 13
const GAP := 40.0                  ## m between the two things the shot could hit
const LINGER := 0.45               ## s after the deciding hit by which every copy must have ended

var td: TestDrive
var world: CombatWorld
var net: CombatNet
var hits: Array = []               ## hit_landed: {id, dmg, shot}
var impacts: Array = []            ## [now, point]
var copies := {}                   ## shot key -> CombatEffect (this machine's copy)
var ends := {}                     ## shot key -> end_time (flight time) once this machine's copy ended
var dummy: CombatTarget


func run_host() -> void:
	net_timeout = 140.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready"):
		return
	var b := _peer_named("c1")
	var c := _peer_named("c2")
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	if not check(pb != null and b > 0 and c > 0, "the host has B's puppet"):
		return
	world.use_physics = false
	_command_all("physics", {"on": false})
	await _all_ack("physics")
	var up := pb.mech.up()
	var aim_b := pb.mech.global_position + up * 4.4
	var speed := float(world.stats("autocannon")["speed"])

	# 1. ATTACKER DECIDES ------------------------------------------------------------------------------------------
	_make_dummy(aim_b + up * GAP)
	var r1 := _rec("side_l", aim_b + up * GAP * 2.0, aim_b, 9701)
	var k1 := Combat.shot_key(r1)
	_track(k1, world.fire(r1))
	var t_hit1 := (GAP - 1.7) / speed            # T's sphere (1.5 m + the 0.2 m shot radius) is met above its centre
	await sleep(2.0)
	var v1 := await _collect("one")
	var on_t := hits.filter(func(h: Dictionary) -> bool: return str(h["shot"]) == k1)
	eq(on_t.size(), 1, "1: the host applied the shell to T once")
	check(_lost(dummy) > 0.0, "1: T lost HP on the host")
	var total1 := on_t.size()
	for p: int in [b, c]:
		var v: Dictionary = v1.get(p, {})
		if not check(not v.is_empty(), "1: peer %d reported" % p):
			continue
		var mine := (v["hits"] as Array).filter(func(h: Dictionary) -> bool: return str(h["shot"]) == k1)
		total1 += mine.size()
		var e := float((v["ends"] as Dictionary).get(k1, -1.0))
		print("[drop] 1: peer %d's copy ended at flight time %.3f s (T at %.3f s, B at %.3f s)" % [p, e, t_hit1, GAP * 2.0 / speed])
		check(e >= 0.0, "1: peer %d's copy ended" % p)
		check(e < t_hit1 + LINGER, "1: peer %d's copy ended within %.2f s of A's hit on T (at %.3f s)" % [p, LINGER, e])
		var near_t := 0
		var near_b := 0
		for it: Array in v["impacts"]:
			if float(it[0]) < float(r1["t"]) - 0.01:
				continue
			print("[drop] 1: peer %d impact at %s, %.2f m from T's point, %.2f m from B" % [p, str(it[1]),
				(it[1] as Vector3).distance_to(aim_b + up * (GAP + 1.7)), (it[1] as Vector3).distance_to(aim_b)])
			if (it[1] as Vector3).distance_to(aim_b + up * (GAP + 1.7)) < 2.5:
				near_t += 1
			if (it[1] as Vector3).distance_to(aim_b) < 8.0:
				near_b += 1
		eq(near_t, 1, "1: peer %d shows the impact at T's point once" % p)
		eq(near_b, 0, "1: peer %d shows no impact on B" % p)
	near(float((v1.get(b, {}) as Dictionary).get("own_hp_lost", -1.0)), 0.0, 1e-6, "1: B's mech took nothing")
	eq(total1, 1, "1: exactly one thing took the shell across the crew")
	_remove_dummy()

	# 2. VICTIM DECIDES ---------------------------------------------------------------------------------------------
	world.friendly_fire = false
	_make_dummy(aim_b - up * GAP)
	var r2 := _rec("side_l", aim_b + up * GAP, aim_b - up * GAP * 2.0, 9702)
	var k2 := Combat.shot_key(r2)
	var b_lost0 := float((v1.get(b, {}) as Dictionary).get("own_hp_lost", 0.0))
	_track(k2, world.fire(r2))
	await sleep(2.6)
	var v2 := await _collect("two")
	var on_t2 := hits.filter(func(h: Dictionary) -> bool: return str(h["shot"]) == k2)
	eq(on_t2.size(), 0, "2: the host applied nothing to T")
	near(_lost(dummy), 0.0, 1e-6, "2: T is untouched")
	var vb: Dictionary = v2.get(b, {})
	var total2 := on_t2.size()
	if check(not vb.is_empty(), "2: B reported"):
		var own := (vb["hits"] as Array).filter(func(h: Dictionary) -> bool: return str(h["shot"]) == k2)
		eq(own.size(), 1, "2: B applied the shell to its own mech once")
		total2 += own.size()
		check(float(vb["own_hp_lost"]) > b_lost0, "2: B's HP went down")
	var vc: Dictionary = v2.get(c, {})
	if check(not vc.is_empty(), "2: C reported"):
		total2 += (vc["hits"] as Array).filter(func(h: Dictionary) -> bool: return str(h["shot"]) == k2).size()
	var t_hit2 := (GAP - 2.0) / speed
	var e2 := float(ends.get(k2, -1.0))
	print("[drop] 2: the host's copy ended at flight time %.3f s (B at ~%.3f s, T at %.3f s)" % [e2, t_hit2, GAP * 2.0 / speed])
	check(e2 >= 0.0 and e2 < GAP * 2.0 / speed - 0.1, "2: the host's copy ended before reaching T (%.3f s)" % e2)
	check(e2 < t_hit2 + LINGER + 0.1, "2: the host's copy ended within ~%.2f s of B's hit (%.3f s)" % [LINGER, e2])
	eq(total2, 1, "2: exactly one thing took the shell across the crew")
	_command_all("finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 140.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	net.remote_fired.connect(func(rec: Dictionary, e: CombatEffect) -> void: _track(Combat.shot_key(rec), e))
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"physics":
				world.use_physics = bool(c["on"])
				report("ack_physics", true)
			"report":
				report(str(c["key"]), {"hits": hits, "impacts": impacts, "ends": ends, "own_hp_lost": _lost(td.combat.player_target)})


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null, "the crew mission runs CombatNet"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	world = td.combat.world
	net = td.combat.net
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: hits.append({"id": t.target_id, "dmg": h.damage, "shot": h.shot}))
	world.impact_spawned.connect(func(p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append([world.now, p]))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return check(await until(func() -> bool:
		for p: int in td.crew_sync.puppets:
			if (td.crew_sync.puppets[p] as MechPuppet).shown == null:
				return false
		return td.crew_sync.puppets.size() == peers - 1, 10.0), "every puppet is shown")


func _physics_process(_delta: float) -> void:
	for k: String in copies:
		if ends.has(k):
			continue
		var e: Variant = copies[k]
		if not is_instance_valid(e) or not (e is Projectile):
			continue
		if (e as Projectile).end_time >= 0.0:
			ends[k] = (e as Projectile).end_time


func _track(k: String, e: CombatEffect) -> void:
	if e != null:
		copies[k] = e


func _rec(hp: String, origin: Vector3, target: Vector3, idx: int) -> Dictionary:
	var p := CombatWorld.local_peer()
	return Combat.fire_record("player%d" % p, p, hp, "autocannon", origin, target, world.now, idx, 0.0)


func _make_dummy(pos: Vector3) -> void:
	dummy = CombatTarget.new()
	dummy.target_id = "drop_dummy"
	dummy.owner_peer = 0
	dummy.mass_class = "static"
	dummy.set_max_hp({"body": 1000.0})
	dummy.add_hit_sphere("body", Vector3.ZERO, 1.5)
	add_child(dummy)
	dummy.global_position = pos
	world.register(dummy)


func _remove_dummy() -> void:
	if dummy != null:
		world.unregister(dummy)
		dummy.queue_free()
		dummy = null


func _command_all(cmd: String, data: Dictionary) -> void:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id() and int(e["peer"]) > 0:
			command(int(e["peer"]), cmd, data)


func _all_ack(what: String) -> bool:
	return check(await wait_reports("ack_" + what, peers - 1, 15.0), "every client acknowledged " + what)


func _collect(key: String) -> Dictionary:
	_command_all("report", {"key": key})
	check(await wait_reports(key, peers - 1, 15.0), "every client reports " + key)
	var out := {}
	for p in peers_with(key):
		out[p] = reported(p, key)
	return out


func _peer_named(n: String) -> int:
	for e: Dictionary in Session.crew():
		if str(e["name"]) == n:
			return int(e["peer"])
	return -1


static func _lost(t: CombatTarget) -> float:
	if t == null or not is_instance_valid(t):
		return 0.0
	var s := 0.0
	for k: String in t.max_hp:
		s += float(t.max_hp[k]) - float(t.hp.get(k, 0.0))
	return s
