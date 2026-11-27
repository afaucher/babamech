extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## W9 perf budget: a full crew of 4 in the mission scene (the stack once W2 is in, else the district), measured in ONE
## process. The host opens a session alone and launches a real crew mission (Session.mission.host_launch), so the test drive
## runs exactly as in co-op: CrewSync, CombatNet, the shared clock, Session.mechs streaming. Three more crew mechs are
## then added as PUPPETS through the real path: MechSpawn.make(..., peer) with `puppet` on, then CrewSync.setup again with
## all four seats (it gives each a MechPuppet and a PlayerTarget and calls Session.mechs.begin), and every 1/30 s a
## synthetic snapshot per puppet (a NetMechState walking up and down the entry road) is pushed into its
## Session.mechs.buffer(peer) as if it had just arrived: the wire / codec are the only part not exercised (no peers in
## one process). The local mech walks, runs, thrusts and fires every weapon at live, alerted enemies (as test_perf).
##
## Measured: wall time between physics frames under --fixed-fps 60 (headless: CPU only, no GPU), p50 / p95 / p99 / max,
## three passes in one process: a discarded warm-up (the first shots / impacts / effects spike to 80-120 ms), the drive
## solo, then the same with the 3 puppets added. Budgets:
##   - crew p95 under BUDGET_P95 (11 ms). A 60 Hz frame is 16.7 ms and this measures CPU only: the renderer needs its
##     share of the same frame, so a full crew's simulation (4 rigs + IK + gait, combat, enemies, props, HUD, audio,
##     net bridges) must leave about a third of it free. Single-player test_perf asserts p95 < 10 ms.
##   - the 3 puppets add under PUPPET_BUDGET (4.5 ms) per frame on average (1.5 ms a puppet).
## Measured 2026-11-22 (stack, 3 runs while other sessions ran test batches, CPU ~40-70 %): solo p95 5.2-6.1 ms; crew
## p50 6.4-6.9 ms, p95 7.8-8.5 ms, p99 15.8-17.8 ms, max 59-68 ms (one spike right after the puppets are added); the
## puppets cost +2.0-3.0 ms avg (about 0.7-1 ms each).
##
## Engine added `--offline-crew N` / MissionScene.offline_crew (idle puppets in a solo drive). Not used here on purpose:
## those puppets get no CrewSync / Session.mechs stream, which is the cost this test measures.

const SERIAL := true   # wall-clock budget: test_runner runs it alone, after the parallel batch
const SEED := 11
const PORT := 28390
const FRAMES := 300
const WALL_TIMEOUT := 90.0
const WARMUP := 30
const BUDGET_P95 := 11.0           ## ms, crew of 4 (see the header for why)
const PUPPETS := 3
const PUPPET_BUDGET := 4.5         ## ms, average added by the 3 puppets (rig, IK, gait, fx, audio, targets)
const SNAP_DT := 1.0 / 30.0        ## the stream's send rate (NetMechStream.SEND_RATE)
const LEG := 3.0                   ## s each way up / down the road for the synthetic puppets

var td: MissionScene
var _base: Dictionary = {}         ## peer -> [deck-local start transform]


var _t0_usec := 0


func setup() -> void:
	# The TestCase timer runs on game time, which races ahead of the wall clock under --fixed-fps while this waits for the
	# session's wall-clock moments (start_t): watch the wall clock instead (_process), as NetTest does.
	for c in get_children():
		if c is Timer:
			(c as Timer).stop()
	_t0_usec = Time.get_ticks_usec()
	await _run()
	finish()


func _process(_delta: float) -> void:
	if _t0_usec > 0 and Time.get_ticks_usec() - _t0_usec > int(WALL_TIMEOUT * 1e6):
		_t0_usec = 0
		_fail("timed out after %.0f s (wall clock)" % WALL_TIMEOUT)
		finish()


func _run() -> void:
	Session.telemetry_enabled = false
	Session.set_profile("perf", NetTest.head_for(0), NetSession.DEFAULT_CHASSIS, NetTest.accent_for(0), NetTest.loadout_for(0))
	var port := test_port(PORT)
	if not check(Session.host_enet(port), "the host opens port %d" % port):
		return
	if not check(Session.mission.host_launch(SEED), "the host launches a crew mission"):
		return
	await _until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0)
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	# A crew mission loads stepped (the stack and life over frames): measure only once it is fully set up.
	if not check(await _until(func() -> bool: return td.loaded, 30.0), "the mission load finishes"):
		return
	if not check(td.crewed and td.crew_sync != null, "the test drive runs the crew mission"):
		return
	if not check(await _until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 20.0),
			"the load barrier passes"):
		return
	var where := "stack" if td.get("stack") != null else "district"
	td.drive_override = true
	td.combat.rack.read_input = false
	td.combat.rack.manual_aim = true
	# A discarded pass first (first shots, impacts and effects warm caches: 80-120 ms spikes otherwise), then the same drive
	# alone (same process, same moment's machine load): the crew's cost is the difference.
	await _measure("%s, warm-up (discarded)" % where)
	var solo := await _measure("%s, solo (1 mech)" % where)
	var seats := _add_puppets()
	td.crew_sync.setup(td, seats)
	await frames(2)
	eq(td.mechs.size(), PUPPETS + 1, "four crew mechs in the mission")
	eq(td.crew_sync.puppets.size(), PUPPETS, "three of them puppets (MechPuppet + PlayerTarget)")
	eq(Session.mechs.puppet_peers().size(), PUPPETS, "Session.mechs has a buffer per puppet")
	var crew := await _measure("%s, crew (%d mechs, %d puppets)" % [where, td.mechs.size(), td.crew_sync.puppets.size()])
	print("[perf-coop] the 3 puppets cost p50 %+.2f ms, p95 %+.2f ms, avg %+.2f ms per frame" %
		[crew["p50"] - solo["p50"], crew["p95"] - solo["p95"], crew["avg"] - solo["avg"]])
	for p: int in td.crew_sync.puppets:
		check((td.crew_sync.puppets[p] as MechPuppet).shown != null, "puppet %d was shown from its stream" % p)
	check(float(crew["err"]) < 0.5, "each puppet follows its synthetic stream (max %.3f m)" % float(crew["err"]))
	check(float(crew["p95"]) < BUDGET_P95, "p95 frame time with a crew of 4 stays under %.1f ms (%.2f ms)" % [BUDGET_P95, float(crew["p95"])])
	check(float(crew["avg"]) - float(solo["avg"]) < PUPPET_BUDGET, "the 3 puppets add under %.1f ms per frame on average (%+.2f ms)" %
		[PUPPET_BUDGET, float(crew["avg"]) - float(solo["avg"])])
	await _finish_mission()


## FRAMES physics frames of active play (the local mech walks / strafes / runs / thrusts and fires every weapon at the
## first live enemy, enemies alerted; every puppet fed its synthetic stream at 30 Hz). Returns avg / p50 / p95 / p99 / max
## frame ms and the largest puppet error against its stream.
func _measure(label: String) -> Dictionary:
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0, "", "player1")
	var frame_ms: Array[float] = []
	var next_snap := 0.0
	var t0 := Session.host_time()
	var max_puppet_err := 0.0
	var prev_us := Time.get_ticks_usec()
	for f in FRAMES:
		var now_us := Time.get_ticks_usec()
		if f >= WARMUP:
			frame_ms.append(float(now_us - prev_us) / 1000.0)
		prev_us = now_us
		var m := td.mech
		m.move_input = Vector2(0.4 if (f / 50) % 2 == 0 else -0.4, 1.0 if (f / 90) % 2 == 0 else -1.0)
		m.running = (f % 80) > 40
		m.thrust_input = (f >= 45 and f < 80) or (f >= 180 and f < 215)
		var aim_e: EnemyBase = null
		for e in td.combat.enemies:
			if is_instance_valid(e) and not e.destroyed():
				aim_e = e
				break
		if aim_e != null:
			td.combat.rack.aim_point = aim_e.global_position + Vector3(0.0, 2.5, 0.0)
		else:
			td.combat.rack.aim_point = m.global_position + m.forward() * 40.0 + m.up() * 3.0
		td.combat.rack.set_trigger(f >= 20 and f < 250)
		var now := Session.host_time()
		if now >= next_snap:
			next_snap = now + SNAP_DT
			for p: int in td.crew_sync.puppets:
				Session.mechs.buffer(p).push(_synthetic(p, now - t0, now), now)
		await get_tree().physics_frame
		for p: int in td.crew_sync.puppets:
			var pp: MechPuppet = td.crew_sync.puppets[p]
			if pp.shown != null and pp.shown.t >= t0:   # (before the first sample it holds that sample)
				max_puppet_err = maxf(max_puppet_err, pp.mech.global_position.distance_to(_synthetic(p, pp.shown.t - t0, 0.0).pos))
	td.combat.rack.set_trigger(false)
	frame_ms.sort()
	var n := frame_ms.size()
	var avg := 0.0
	for v in frame_ms:
		avg += v
	avg /= maxf(float(n), 1.0)
	var r := {"avg": avg, "p50": frame_ms[n / 2], "p95": frame_ms[int(n * 0.95)], "p99": frame_ms[int(n * 0.99)], "max": frame_ms[-1],
		"err": max_puppet_err}
	print("[perf-coop] %s, %d frames: avg %.2f ms, p50 %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.2f ms; enemies alive %d, effects %d" %
		[label, n, avg, r["p50"], r["p95"], r["p99"], r["max"], td.combat.squad.alive_count(), td.combat.world.effects.size()])
	return r


## Leave as the game does: the host ends the mission, the scene goes, the session closes.
func _finish_mission() -> void:
	Session.mission.end()
	td.queue_free()
	await frames(2)
	Session.leave()


## Three more crew mechs (peers 9001..9003, seats 2..4) as puppets, placed on the entry road away from the local mech
## (rows behind it); returns the seats for every crew mech (the local one too) for CrewSync.setup.
func _add_puppets() -> Dictionary:
	var local := Session.local_id()
	var seats := {local: int(Session.local_entry().get("seat", 1))}
	var entry := td.mech.global_transform
	if td.get("stack") != null:
		entry = (td.get("stack") as CityStack).entry_transform()
	for i in PUPPETS:
		var peer := 9001 + i
		var chassis := NetSession.DEFAULT_CHASSIS
		var m := MechSpawn.make(NetTest.head_for(i + 1), chassis,
			WeaponRegistry.playable_loadout(chassis, NetTest.loadout_for(i + 1))["loadout"], peer, NetTest.accent_for(i + 1))
		m.name = "Mech_p%d" % peer
		m.puppet = true
		td.add_child(m)
		m.ring = td.city.ring
		var ma := m.get_node_or_null("Audio") as MechAudio
		if ma != null:
			ma.city = td.city
		# Rows 10 / 10 / 20 m along the road from the local mech, columns 4 m either side (MissionScene's crew layout).
		var xf := MissionScene.entry_spawn(entry, td.city, i + 2, 6)
		m.global_transform = xf
		td.mechs[peer] = m
		seats[peer] = i + 2
		var deck_xf := td.city.global_transform
		var lo := deck_xf.affine_inverse() * xf
		_base[peer] = [td.city.ring.world_to_arc(lo.origin), signf((-lo.basis.z).dot(td.city.ring.tangent_at(lo.origin)))]
	return seats


## A synthetic owner snapshot for puppet `p` at `e` s into the run: walking up the road LEG s, back LEG s, at walk speed,
## on the deck (arc coordinates of the entry deck, so it follows the curve), facing the way it goes.
func _synthetic(p: int, e: float, stamp: float) -> NetMechState:
	var b: Array = _base[p]
	var a: Vector3 = b[0]
	var ahead: float = b[1]
	var speed := td.mech.walk_speed
	var ph := fposmod(e, 2.0 * LEG)
	var dist := speed * (ph if ph < LEG else 2.0 * LEG - ph)
	var dir_sign := 1.0 if ph < LEG else -1.0
	var ring := td.city.ring
	var deck_xf := td.city.global_transform
	var lp := ring.arc_to_world(a.x, a.y + ahead * dist, a.z)
	var st := NetMechState.new()
	st.peer = p
	st.t = stamp
	st.pos = deck_xf * lp
	var dir := deck_xf.basis * (ring.tangent_at(lp) * ahead * dir_sign)
	st.vel = dir * speed
	st.yaw = CrewSync.heading_of(td.mech.ring, st.pos, dir)
	st.heat = 0.3
	st.grounded = true
	st.aim = st.pos + dir * 40.0
	return st


## Wait (frame by frame) until cond() is true; false after timeout_s seconds of WALL time (the session clock is wall time).
func _until(cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_usec() + int(timeout_s * 1e6)
	while not bool(cond.call()):
		if Time.get_ticks_usec() > end:
			return false
		await get_tree().process_frame
	return true
