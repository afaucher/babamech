extends NetTest
## The flak's proximity fuse across machines (docs/design/weapons.md §3.10, §5), over a crew of 2, once per link. A
## host-owned airborne target "flak_dummy" (owner_peer 0, 20 m up, 60 m ahead of the host) exists on both machines. The
## client (B) fires one flak record past it, 4 m from its hull (a near miss inside the 6 m fuse), through its own
## CombatWorld.fire, so CombatNet sends it like a trigger's. Every machine simulates the shell and its fuse against its own
## view: B (the attacker) decides the hit on the host-owned target and sends one combat.hit; the host applies it ONCE and
## builds no Hit of its own; B's copy is never written by B. Both machines draw a fuse burst beside the target.
## The test dummy is a plain CombatTarget with no HP stream, so "both agree" is checked as: the host's HP loss equals the
## damage B decided and sent (one splash share, the falloff at B's burst point), and both bursts sit at the same point.

const PEERS := 2
const SEED := 11
const MISS := 4.0                    ## m from the target's hull
const BURST_TOL := 0.25              ## m between the two machines' burst points

var td: TestDrive
var world: CombatWorld
var net: CombatNet
var dummy: CombatTarget
var bursts: Array = []               ## [kind, point, fused_by] of every FlakShell that ended here
var remote_hits: Array = []          ## [id, damage]
var local_hits: Array = []           ## [id, damage] hit_landed here
var _shells: Array = []


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client is ready"):
		return
	var b := -1
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			b = int(e["peer"])
	var m := td.mech
	var up := m.up()
	var fwd := m.forward()
	var dpos := m.global_position + fwd * 60.0 + up * 20.0
	command(b, "dummy", {"pos": dpos})
	_make_dummy(dpos)
	if not check(await wait_reports("ack_dummy", 1, 15.0), "the client made the dummy"):
		return
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	if not check(pb != null, "the host has B's puppet"):
		return
	var centre := dpos
	var ob := pb.mech.global_position + up * 4.4
	var line := (centre - ob).normalized()
	var side := line.cross(up).normalized()
	var aim := centre + side * (1.5 + MISS)          # the dummy's sphere is 1.5 m: the path passes MISS m off its hull
	ob += (aim - ob).normalized() * 3.0
	command(b, "fire", {"origin": ob, "target": aim, "idx": 9400})
	await until(func() -> bool: return int(net.stats["hits_applied"]) >= 1, 6.0)
	await sleep(1.5)
	eq(int(net.stats["hits_applied"]), 1, "the host applied B's flak hit once")
	var lost := _lost(dummy)
	check(lost > 0.0, "the airborne target lost HP on the host (%.3f)" % lost)
	var mine := local_hits.filter(func(h: Array) -> bool: return str(h[0]) == "flak_dummy")
	eq(mine.size(), 1, "one hit_landed on the host (the applied remote hit), no Hit of the host's own")
	command(b, "report", {"key": "state"})
	if not check(await wait_reports("state", 1, 15.0), "B reports"):
		return
	var vb: Dictionary = reported(b, "state")
	var sent: Array = (vb["remote_hits"] as Array).filter(func(h: Array) -> bool: return str(h[0]) == "flak_dummy")
	eq(sent.size(), 1, "B decided the hit and sent it once")
	if sent.size() == 1:
		near(lost, float(sent[0][1]), 1e-3, "the host's HP loss is exactly the damage B decided (one splash share)")
		var expect_max := float(MechCatalog.weapon("flak")["splash_damage"]) * (1.0 - (MISS - 0.5) / 8.0)
		check(float(sent[0][1]) > 0.0 and float(sent[0][1]) < expect_max + 1.0, "a near-miss splash share (%.2f)" % float(sent[0][1]))
	near(float(vb["dummy_lost"]), 0.0, 1e-6, "B's copy of the host-owned target is not written by B")
	var hb := _fused()
	var bb: Array = (vb["bursts"] as Array).filter(func(x: Array) -> bool: return str(x[0]) == FlakShell.BURST_FUSE and str(x[2]) == "flak_dummy")
	check(not hb.is_empty(), "the host drew a fuse burst beside the target")
	check(not bb.is_empty(), "B drew a fuse burst beside the target")
	if not hb.is_empty() and not bb.is_empty():
		var d := (hb[0][1] as Vector3).distance_to(bb[0][1])
		print("[flak] burst points %.4f m apart (%s)" % [d, link])
		check(d < BURST_TOL, "both machines burst at the same point (%.3f m apart)" % d)
		check((hb[0][1] as Vector3).distance_to(centre) < 1.5 + 6.0 + 0.5, "beside the target (%.2f m from its centre)" % (hb[0][1] as Vector3).distance_to(centre))
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 90.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", net != null and world.clock.is_valid())
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"dummy":
				_make_dummy(c["pos"])
				report("ack_dummy", true)
			"fire":
				var p := CombatWorld.local_peer()
				var rec := Combat.fire_record("player%d" % p, p, "side_r", "flak", c["origin"], c["target"], world.now, int(c["idx"]), 0.0)
				world.fire(rec)
			"report":
				report(str(c["key"]), {"remote_hits": remote_hits, "bursts": bursts, "dummy_lost": _lost(dummy) if dummy != null else -1.0})


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
	world.friendly_fire = false      # the shell must not fuse on the other mech
	world.use_physics = false        # nothing of the city between B and the target: only the fuse is under test
	world.skip_props = true
	net = td.combat.net
	world.child_entered_tree.connect(func(n: Node) -> void:
		if n is FlakShell:
			_shells.append(n))
	world.remote_hit.connect(func(id: String, h: Hit) -> void: remote_hits.append([id, h.damage]))
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: local_hits.append([t.target_id, h.damage]))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return true


func _physics_process(_delta: float) -> void:
	for s: Variant in _shells.duplicate():
		if not is_instance_valid(s):
			_shells.erase(s)
			continue
		var f := s as FlakShell
		if f.end_time >= 0.0:
			bursts.append([f.burst, f.burst_point, f.fused_by])
			_shells.erase(s)


func _fused() -> Array:
	return bursts.filter(func(x: Array) -> bool: return str(x[0]) == FlakShell.BURST_FUSE and str(x[2]) == "flak_dummy")


func _make_dummy(pos: Vector3) -> void:
	dummy = CombatTarget.new()
	dummy.target_id = "flak_dummy"
	dummy.owner_peer = 0
	dummy.team = "enemy"
	dummy.mass_class = "static"
	dummy.set_max_hp({"body": 1000.0})
	dummy.add_hit_sphere("body", Vector3.ZERO, 1.5)
	add_child(dummy)
	dummy.global_position = pos
	world.register(dummy)


static func _lost(t: CombatTarget) -> float:
	var s := 0.0
	for k: String in t.max_hp:
		s += float(t.max_hp[k]) - float(t.hp.get(k, 0.0))
	return s
