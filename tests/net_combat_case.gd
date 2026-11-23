extends NetTest
## Combat across machines (co-op step 3, docs/design/weapons.md §5, scripts/combat/combat_net.gd) over a real crew mission,
## once per link (off, coast). The host (A) is the shooter; client c1 (B) is the victim; in the 3-machine variant c2 (C)
## watches. Shots are fire records handed to the host's CombatWorld.fire (what WeaponRack does), so they go out exactly
## like a trigger's.
## 1. FIRE: an autocannon shell at the ground and a gatling batch (5 records in one step, 3° spread) appear on every
##    machine with the same weapon, origin, direction, start time t and spread draw; the shell lands at the same point.
## 2. LATE: a record 0.4 s old fast-forwards on arrival (flight time at spawn >= 0.4 s, at the host's path position).
## 3. MISSILE: with world geometry off everywhere, A's aim point sweeps 87 m sideways while a guided missile flies; on
##    every other machine the missile (steered by A's streamed aim point) stays within MISSILE_TOL of A's own and far off
##    the straight line.
## 4. HIT: B's targets get the fixture team "rival" on every machine (this case runs with friendly fire OFF everywhere,
##    `world.friendly_fire = false` at load, so steps 1-3 and 5 never clip a teammate; friendly fire itself is
##    test_net_friendly_fire), A fires a shell into B. Only B applies it, once (a duplicate event is
##    dropped); A and C build no Hit, emit no remote_hit, and show the impact. Their puppet of B loses exactly that one
##    shell's HP, because B streams its component HP in its mech snapshot (never written by A / C's combat).
## 5. HOST-OWNED: a host-owned target "net_dummy" (owner_peer 0) exists everywhere; B shoots it. B decides and sends the
##    hit; the host applies it once (a repeated hit event is dropped); B's own copy is untouched.
## Not a test itself: test_net_combat (2) and test_net_combat_3 (3) extend it.

const SEED := 7
const MISSILE_TOL := {"off": 4.0, "coast": 6.0}   ## measured max 1.5 m off, 2.2 m coast
const MISSILE_SAMPLES := [1.0, 2.0, 3.0]
const IMPACT_TOL := 0.05

var td: TestDrive
var world: CombatWorld
var net: CombatNet
var recs := {}                     ## shot key -> what arrived
var impacts: Array = []            ## [now, point]
var hits: Array = []               ## hit_landed: {id, dmg, shot}
var remote_hits: Array = []        ## remote_hit target ids
var missiles := {}                 ## shot key -> Missile
var missile_pos := {}              ## shot key -> {"1.0": Vector3, ...}
var saw_track := false             ## a remote shooter's guided track was on here
var dummy: CombatTarget
var last_remote_hit: Array = []    ## [id, Hit]


func run_host() -> void:
	net_timeout = 110.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client is ready (puppets shown)"):
		return
	for p in peers_with("ready"):
		check(bool(reported(p, "ready")), "peer %d runs a CombatNet on the shared clock" % p)
	var b := _peer_named("c1")
	var c := _peer_named("c2")
	var m := td.mech
	var up := m.up()
	var fwd := m.forward()

	# 1. FIRE ------------------------------------------------------------------------------------------------
	var o1 := m.global_position + up * 4.4 + fwd * 3.0
	var r1 := _rec("side_l", "autocannon", o1, m.global_position + fwd * 40.0 - up * 0.5, 9001, 0.4)
	var n0 := impacts.size()
	world.fire(r1)
	await until(func() -> bool: return impacts.size() > n0, 3.0)
	var host_impact: Vector3 = impacts[n0][1] if impacts.size() > n0 else Vector3.INF
	check(host_impact != Vector3.INF, "the host's shell lands")
	var batch: Array[Dictionary] = []
	var host_dirs := {}
	for i in 5:
		var r := _rec("side_r", "gatling", o1 + fwd * 0.1 * i, o1 + fwd * 150.0 + up * 30.0, 9010 + i, 3.0)
		batch.append(r)
		var e := world.fire(r)
		host_dirs[Combat.shot_key(r)] = (e as Projectile).dir
	await sleep(1.2)
	var st := await _collect("fire")
	for p: int in st:
		var got: Dictionary = st[p]["recs"]
		for r: Dictionary in [r1] + batch:
			var k := Combat.shot_key(r)
			if not check(got.has(k), "peer %d got shot %s" % [p, k]):
				continue
			var g: Dictionary = got[k]
			eq(str(g["weapon"]), str(r["weapon"]), "peer %d: %s same weapon" % [p, k])
			check((g["origin"] as Vector3).is_equal_approx(r["origin"]), "peer %d: %s same origin" % [p, k])
			check((g["dir"] as Vector3).is_equal_approx(r["dir"]), "peer %d: %s same direction" % [p, k])
			eq(float(g["t"]), float(r["t"]), "peer %d: %s same start time" % [p, k])
			if host_dirs.has(k):
				check((g["pdir"] as Vector3).is_equal_approx(host_dirs[k]), "peer %d: %s same spread draw" % [p, k])
		var best := INF
		for it: Array in st[p]["impacts"]:
			best = minf(best, (it[1] as Vector3).distance_to(host_impact))
		print("[combat] peer %d: shell impact %.4f m from the host's" % [p, best])
		check(best < IMPACT_TOL, "peer %d: the shell lands where it landed on the host (%.3f m off)" % [p, best])

	# 2. LATE ------------------------------------------------------------------------------------------------
	var rl := _rec("side_l", "autocannon", o1, o1 + fwd * 100.0 + up * 25.0, 9050, 0.0)
	rl["t"] = world.now - 0.4
	world.fire(rl)
	var speed := float(world.stats("autocannon")["speed"])
	await sleep(0.4)
	st = await _collect("late")
	for p: int in st:
		var g: Dictionary = (st[p]["recs"] as Dictionary).get(Combat.shot_key(rl), {})
		if not check(not g.is_empty(), "peer %d got the late record" % p):
			continue
		var es := float(g["e_spawn"])
		print("[combat] peer %d: late record spawned %.3f s into its flight" % [p, es])
		check(es >= 0.4 - 1e-6 and es < 1.6, "peer %d: the late record started %.3f s into its flight" % [p, es])
		var want: Vector3 = (rl["origin"] as Vector3) + (rl["dir"] as Vector3) * speed * es
		check((g["pos_spawn"] as Vector3).distance_to(want) < 1e-3,
			"peer %d: fast-forwarded to the host's path position at that flight time" % p)

	# 3. MISSILE ---------------------------------------------------------------------------------------------
	_set_physics(false)
	await _all_ack("physics", false)
	var rack := td.combat.rack
	var slot := rack.hardpoints.find("shoulder_l")
	if check(slot >= 0 and rack.weapons[slot] == "missiles", "the host carries missiles on shoulder_l (NetTest.loadout_for(0))"):
		rack.manual_aim = true
		var p0 := m.global_position + fwd * 120.0 + up * 30.0
		var side := fwd.cross(up).normalized()
		var t0 := Session.host_time()
		var rm: Dictionary = {}
		while Session.host_time() - t0 < 4.2:
			var s := Session.host_time() - t0
			rack.aim_point = p0 + side * (-30.0 + 25.0 * minf(s, 3.5))
			if rm.is_empty() and s > 0.4:
				check(rack.designator_on(), "the host's guided track is on")
				rm = _rec("shoulder_l", "missiles", m.global_position + up * 7.0 + fwd * 2.0, rack.aim_point, 9100, 0.0)
				missiles[Combat.shot_key(rm)] = world.fire(rm)
			await get_tree().physics_frame
		rack.manual_aim = false
		var mk := Combat.shot_key(rm)
		var mine: Dictionary = missile_pos.get(mk, {})
		check(mine.size() == MISSILE_SAMPLES.size(), "the host sampled its missile")
		st = await _collect("missile")
		for p: int in st:
			check(bool(st[p]["saw_track"]), "peer %d mirrors the host's guided track" % p)
			var theirs: Dictionary = (st[p]["missile_pos"] as Dictionary).get(mk, {})
			if not check(theirs.size() == MISSILE_SAMPLES.size(), "peer %d sampled the host's missile" % p):
				continue
			for e: float in MISSILE_SAMPLES:
				var k := str(e)
				var d := (theirs[k] as Vector3).distance_to(mine[k])
				print("[combat] peer %d: missile at %.0f s, %.2f m from the host's (%.1f m off the straight line)" % [p, e, d, _off_line(theirs[k], rm)])
				check(d < float(MISSILE_TOL[link]), "peer %d: missile at %.0f s within %.1f m of the host's (%.2f m)" % [p, e,
					float(MISSILE_TOL[link]), d])
			var last := str(MISSILE_SAMPLES[MISSILE_SAMPLES.size() - 1])
			var off := _off_line(theirs[last], rm)
			check(off > 20.0, "peer %d: the missile followed the moving aim point (%.1f m off the straight line)" % [p, off])
		check(_off_line(mine[str(MISSILE_SAMPLES[MISSILE_SAMPLES.size() - 1])], rm) > 20.0, "the host's missile followed it too")
		world.remove_shot(mk)
		_command_all("drop", {"key": mk})
	_set_physics(true)
	await _all_ack("physics", true)

	# 4. HIT on B's mech ---------------------------------------------------------------------------------------
	_command_all("team", {"peer": b, "team": "rival"})
	_set_team(b, "rival")
	await _all_ack("team", b)
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	if check(pb != null and tb != null, "the host has B's puppet and its target"):
		var aim_b := pb.mech.global_position + pb.mech.up() * 4.4
		var to_b := (aim_b - (m.global_position + up * 4.4)).normalized()
		var ob := m.global_position + up * 4.4 + to_b * 3.0
		var rh := _rec("side_l", "autocannon", ob, aim_b, 9200, 0.0)
		var hk := Combat.shot_key(rh)
		var n1 := impacts.size()
		world.fire(rh)
		await sleep(0.3)
		Session.send_event(0, CombatNet.FIRE, {"r": [CombatNet.encode(rh)]})   # the same record again: must be dropped
		await sleep(1.2)
		var dmg := float(world.stats("autocannon")["damage"])
		st = await _collect("hit")
		var vb: Dictionary = st.get(b, {})
		if check(not vb.is_empty(), "B reported"):
			var own: Array = (vb["hits"] as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
			eq(own.size(), 1, "B applied the hit on its own mech exactly once")
			if own.size() == 1:
				eq(str(own[0]["shot"]), hk, "B's hit is A's shot")
				near(float(own[0]["dmg"]), dmg, 1e-3, "B took the shell's damage")
			near(float(vb["own_hp_lost"]), dmg, 1e-3, "B's HP went down by one shell")
			check(int((vb["stats"] as Dictionary)["dup"]) >= 1, "B dropped the duplicate record")
		for p: int in [Session.local_id()] + ([c] if c > 0 else []):
			var v: Dictionary = _state() if p == Session.local_id() else st.get(p, {})
			if not check(not v.is_empty(), "peer %d reported" % p):
				continue
			var onb: Array = (v["hits"] as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
			eq(onb.size(), 0, "peer %d built no hit on B's puppet" % p)
			check(not ("player%d" % b) in (v["remote_hits"] as Array), "peer %d sent no remote hit for B" % p)
			# The puppet's HP is B's own, streamed in B's mech snapshot (component fractions): it mirrors the one shell, no more.
			near(float((v["puppet_hp_lost"] as Dictionary).get(str(b), -1.0)), dmg, 2.0, "peer %d: its puppet of B mirrors B's streamed HP (one shell)" % p)
			var near_b := false
			for it: Array in v["impacts"]:
				if float(it[0]) >= float(rh["t"]) - 0.01 and (it[1] as Vector3).distance_to(aim_b) < 4.0:
					near_b = true
			check(near_b, "peer %d shows the impact on B" % p)
		check(impacts.size() > n1, "the host spawned the impact")

	# 5. HOST-OWNED target, shot by B ---------------------------------------------------------------------------
	var dpos := m.global_position + fwd * 20.0 + up * 4.0
	_command_all("dummy", {"pos": dpos})
	_make_dummy(dpos)
	await _all_ack("dummy", true)
	if pb != null:
		var ob2 := pb.mech.global_position + up * 4.4
		ob2 += (dpos - ob2).normalized() * 3.0
		command(b, "fire", {"hp": "side_l", "weapon": "autocannon", "origin": ob2, "target": dpos, "idx": 9300})
		await until(func() -> bool: return int(net.stats["hits_applied"]) >= 1, 5.0)
		command(b, "rehit", {})
		await sleep(0.8)
		var expect := float(world.stats("autocannon")["damage"]) * Combat.falloff(world.stats("autocannon"), ob2.distance_to(dpos))
		eq(int(net.stats["hits_applied"]), 1, "the host applied B's hit on its target once")
		check(int(net.stats["hits_dup"]) >= 1, "the host dropped the repeated hit event")
		near(_lost(dummy), expect, 0.5, "the host-owned target lost one shell's damage")
		st = await _collect("dummy")
		var vb2: Dictionary = st.get(b, {})
		if check(not vb2.is_empty(), "B reported"):
			eq((vb2["remote_hits"] as Array).count("net_dummy"), 1, "B decided the hit and sent it once")
			near(float(vb2["dummy_hp_lost"]), 0.0, 1e-6, "B's copy of the host-owned target is not written by B")
	_command_all("finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 110.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", net != null and world.clock.is_valid() and absf(world.now - Session.host_time()) < 0.25)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), _state())
			"physics":
				world.use_physics = bool(c["on"])
				report("ack_physics_%s" % str(c["on"]), true)
			"drop":
				world.remove_shot(str(c["key"]))
			"team":
				_set_team(int(c["peer"]), str(c["team"]))
				report("ack_team_%d" % int(c["peer"]), true)
			"dummy":
				_make_dummy(c["pos"])
				report("ack_dummy_true", true)
			"fire":
				world.fire(_rec(str(c["hp"]), str(c["weapon"]), c["origin"], c["target"], int(c["idx"]), 0.0))
			"rehit":
				if not last_remote_hit.is_empty():
					Session.send_event(1, CombatNet.HIT, CombatNet.encode_hit(last_remote_hit[0], last_remote_hit[1]))


# --- Shared ----------------------------------------------------------------------------------------------

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
	world.friendly_fire = false     # this case's shots must never clip a teammate (B is hit as team "rival", step 4)
	net = td.combat.net
	net.remote_fired.connect(_on_remote_fired)
	world.impact_spawned.connect(func(p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append([world.now, p]))
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: hits.append({"id": t.target_id, "dmg": h.damage, "shot": h.shot}))
	world.remote_hit.connect(func(id: String, h: Hit) -> void:
		remote_hits.append(id)
		last_remote_hit = [id, h])
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return check(await until(_puppets_shown, 10.0), "every puppet is shown")


func _puppets_shown() -> bool:
	for p: int in td.crew_sync.puppets:
		if (td.crew_sync.puppets[p] as MechPuppet).shown == null:
			return false
	return td.crew_sync.puppets.size() == peers - 1


func _physics_process(_delta: float) -> void:
	if world == null:
		return
	for k: String in missiles:
		var e: Variant = missiles[k]
		if not is_instance_valid(e) or not (e is Missile):
			continue
		if not missile_pos.has(k):
			missile_pos[k] = {}
		for s: float in MISSILE_SAMPLES:
			if not (missile_pos[k] as Dictionary).has(str(s)) and float((e as Missile).steps()) * Missile.STEP >= s + 1e-6:
				missile_pos[k][str(s)] = (e as Missile).flight_pos(s)
	for sh: String in world.designators:
		if sh != net.local_shooter and bool((world.designators[sh] as Dictionary).get("on", false)):
			saw_track = true


func _on_remote_fired(rec: Dictionary, e: CombatEffect) -> void:
	var info := {"weapon": rec["weapon"], "origin": rec["origin"], "dir": rec["dir"], "t": rec["t"], "e_spawn": world.now - float(rec["t"]),
		"pdir": Vector3.ZERO, "pos_spawn": Vector3.ZERO}
	if e is Projectile:
		info["pdir"] = (e as Projectile).dir
		info["pos_spawn"] = (e as Projectile).flight_pos((e as Projectile).elapsed)
		info["e_spawn"] = (e as Projectile).elapsed
	if e is Missile:
		missiles[Combat.shot_key(rec)] = e
	recs[Combat.shot_key(rec)] = info


func _rec(hp: String, weapon: String, origin: Vector3, target: Vector3, idx: int, spread: float) -> Dictionary:
	var p := CombatWorld.local_peer()
	return Combat.fire_record("player%d" % p, p, hp, weapon, origin, target, world.now, idx, spread)


func _state() -> Dictionary:
	var lost := {}
	for p: int in td.crew_sync.targets:
		lost[str(p)] = _lost(td.crew_sync.targets[p])
	return {"recs": recs, "impacts": impacts, "hits": hits, "remote_hits": remote_hits, "missile_pos": missile_pos,
		"saw_track": saw_track, "own_hp_lost": _lost(td.combat.player_target), "puppet_hp_lost": lost,
		"dummy_hp_lost": _lost(dummy) if dummy != null else -1.0, "stats": net.stats}


static func _lost(t: CombatTarget) -> float:
	var s := 0.0
	for k: String in t.max_hp:
		s += float(t.max_hp[k]) - float(t.hp.get(k, 0.0))
	return s


func _set_team(peer: int, team: String) -> void:
	if peer == Session.local_id():
		td.combat.player_target.team = team
	elif td.crew_sync.targets.has(peer):
		(td.crew_sync.targets[peer] as PlayerTarget).team = team


func _make_dummy(pos: Vector3) -> void:
	dummy = CombatTarget.new()
	dummy.target_id = "net_dummy"
	dummy.owner_peer = 0
	dummy.mass_class = "static"
	dummy.set_max_hp({"body": 1000.0})
	dummy.add_hit_sphere("body", Vector3.ZERO, 1.5)
	add_child(dummy)
	dummy.global_position = pos
	world.register(dummy)


func _set_physics(on: bool) -> void:
	world.use_physics = on
	_command_all("physics", {"on": on})


func _command_all(cmd: String, data: Dictionary) -> void:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			command(int(e["peer"]), cmd, data)


func _all_ack(what: String, v: Variant) -> bool:
	return check(await wait_reports("ack_%s_%s" % [what, str(v)], peers - 1, 15.0), "every client acknowledged %s %s" % [what, str(v)])


## Ask every client for its state under `key`: peer -> state.
func _collect(key: String) -> Dictionary:
	_command_all("report", {"key": key})
	check(await wait_reports(key, peers - 1, 15.0), "every client reports %s" % key)
	var out := {}
	for p in peers_with(key):
		out[p] = reported(p, key)
	return out


func _peer_named(n: String) -> int:
	for e: Dictionary in Session.crew():
		if str(e["name"]) == n:
			return int(e["peer"])
	return -1


## Distance of `p` from the record's straight line (origin along dir).
static func _off_line(p: Vector3, rec: Dictionary) -> float:
	var o: Vector3 = rec["origin"]
	var d: Vector3 = (rec["dir"] as Vector3).normalized()
	var v := p - o
	return (v - d * v.dot(d)).length()
