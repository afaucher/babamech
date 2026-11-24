extends TestCase
## NOT part of -TestAll (no "test_" prefix): the HOST's per-frame CPU cost in a crew mission with N hangar bots and no
## clients (the playtest setup: one human + 3 bots). Run it with tools/bot_perf/run_bot_perf.ps1 (0 vs 3 bots, same seed,
## several runs). Headless, --fixed-fps 60: every frame is one process frame + one physics tick, back to back, so the wall
## time between frames is the CPU cost (rendering is not measured).
##
## The host opens a session alone, seats BOT_PERF_BOTS bots (Session.add_bot, skill BOT_PERF_SKILL), launches the stack
## mission on BOT_PERF_SEED and waits for mission_go; the bots then play the mission (CrewBot + MissionBot + PlayerBot),
## the local mech walks / strafes / fires every weapon at the nearest live enemy (as test_perf_coop). After WARM frames,
## FRAMES frames are measured with PerfProbe.on (scripts/test_support/perf_probe.gd: flag-guarded timers in the bot,
## mech, rig, combat and crew-sync scripts) and CombatWorld.profiling (targets.tick vs effects). Probe nodes at physics
## priorities between the game's bands time each band of the physics frame:
##   brains  -20 / -19  (TestDriveBotPilot -> PlayerBot.step, MissionBot)
##   racks   -10        (CrewBot: the bots' WeaponRack.step)
##   main      0        (every MechController incl. move_and_slide, TestDrive, TestDriveCombat: local rack + CombatWorld)
##   puppets 5..7, rigs 10 (MechRig: gait, IK, model pose; every mech)
##   post   20..41      (MechAudio, CrewSync sampling, EnemySync, MissionFlow, depots)
## plus the process frame and the physics server step as the rest of the wall frame.
## Prints "[botperf] key avg= p95= max= calls/frame=" lines. Always passes.

const SEED := 11
const PORT := 28394
const DT := 1.0 / 60.0

var td: TestDrive
var _probe_t: Dictionary = {}      ## probe priority -> usec stamp this frame
var _rows: Dictionary = {}         ## key -> PackedFloat32Array (ms per frame) / calls per frame under "n:" + key
var _t0_usec := 0
var _wall_timeout := 600.0


class Probe extends Node:
	var stamp: Callable
	var prio := 0

	func _ready() -> void:
		process_physics_priority = prio
		process_priority = prio   # the first / last probe also bracket the process frame (keys +-100000)

	func _physics_process(_d: float) -> void:
		stamp.call(prio, Time.get_ticks_usec())

	func _process(_d: float) -> void:
		if absi(prio) == 1000:
			stamp.call(prio * 100, Time.get_ticks_usec())


func setup() -> void:
	for c in get_children():
		if c is Timer:
			(c as Timer).stop()
	_t0_usec = Time.get_ticks_usec()
	await _run()
	PerfProbe.on = false
	CombatWorld.profiling = false
	finish()


func _process(_delta: float) -> void:
	if _t0_usec > 0 and Time.get_ticks_usec() - _t0_usec > int(_wall_timeout * 1e6):
		_t0_usec = 0
		_fail("timed out after %.0f s (wall clock)" % _wall_timeout)
		finish()


func _env_i(k: String, d: int) -> int:
	var v := OS.get_environment(k)
	return int(v) if v != "" else d


func _run() -> void:
	var n_bots := _env_i("BOT_PERF_BOTS", 3)
	var seed_v := _env_i("BOT_PERF_SEED", SEED)
	var frames_n := _env_i("BOT_PERF_FRAMES", 1800)
	var warm := _env_i("BOT_PERF_WARM", 300)
	var skill := OS.get_environment("BOT_PERF_SKILL") if OS.get_environment("BOT_PERF_SKILL") != "" else "veteran"
	var local_ai := OS.get_environment("BOT_PERF_LOCAL") == "idle"
	Session.telemetry_enabled = false
	Session.set_profile("perf", NetTest.head_for(0), NetSession.DEFAULT_CHASSIS, NetTest.accent_for(0), NetTest.loadout_for(0))
	var port := test_port(PORT)
	if not check(Session.host_enet(port), "the host opens port %d" % port):
		return
	for i in n_bots:
		check(Session.add_bot(skill) < 0, "bot %d seated" % (i + 1))
	if not check(Session.start_mission(seed_v), "the host launches a crew mission"):
		return
	await _until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0)
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(await _until(func() -> bool: return td.loaded, 60.0), "the mission load finishes"):
		return
	if not check(await _until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 30.0),
			"the load barrier passes"):
		return
	eq(td.crew_bots.size(), n_bots, "the host runs %d bots" % n_bots)
	td.drive_override = true
	td.combat.rack.read_input = false
	td.combat.rack.manual_aim = true
	for p: int in [-1000, -15, -5, 3, 15, 25, 1000]:
		var pr := Probe.new()
		pr.prio = p
		pr.stamp = func(k: int, us: int) -> void: _probe_t[k] = us
		pr.name = "BotPerfProbe_%d" % (p + 2000)
		get_tree().root.add_child(pr)
	# Windowed runs (no --headless; run_bot_perf.ps1 -Windowed under the GPU lock): vsync off so the wall frame is the
	# real cost, and the viewport's measured render times (CPU submit / GPU) next to the draw counters.
	var windowed := DisplayServer.get_name() != "headless"
	var vp_rid := get_viewport().get_viewport_rid()
	if windowed:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	print("[botperf] seed %d, bots %d (%s), warm %d, frames %d, local %s, %s" % [seed_v, n_bots, skill, warm, frames_n,
		"idle" if local_ai else "fighting", "windowed" if windowed else "headless"])
	var prev_start := 0
	var last_end := 0
	var enemies_sum := 0.0
	var fx_sum := 0.0
	var modes: Dictionary = {}
	for f in warm + frames_n:
		var on := f >= warm
		PerfProbe.on = on
		CombatWorld.profiling = on
		_drive_local(f, local_ai)
		await get_tree().physics_frame
		if not on:
			PerfProbe.take()
			continue
		var s := int(_probe_t.get(-1000, 0))
		if prev_start > 0 and s > prev_start:
			_add("frame.wall", float(s - prev_start) / 1000.0)
			# Between the last probe of the previous physics frame and this frame's first: physics server step + the
			# process frame (+ the main loop).
			_add("gap.server+process", float(s - last_end) / 1000.0)
			# The previous iteration's process frame (every node's _process: HUD, life, net stream, ...), and the rest of
			# the gap: the physics server step (bodies, broadphase) + main loop.
			var pa := int(_probe_t.get(-100000, 0))
			var pb := int(_probe_t.get(100000, 0))
			if pb > pa and pa > last_end:
				_add("frame.process", float(pb - pa) / 1000.0)
				_add("gap.server(rest)", float((s - last_end) - (pb - pa)) / 1000.0)
		prev_start = s
		last_end = int(_probe_t.get(1000, 0))
		_band("band.brains(-20,-19)", -1000, -15)
		_band("band.bot_racks(-10)", -15, -5)
		_band("band.main(0)", -5, 3)
		_band("band.rigs(5..10)", 3, 15)
		_band("band.post(20)", 15, 25)
		_band("band.late(30..41)", 25, 1000)
		_add("perf.time_process", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_add("perf.time_physics", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		if windowed:
			_add("render.draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), false)
			_add("render.objects", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), false)
			_add("render.primitives_k", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0, false)
			_add("render.cpu_ms", RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
				+ RenderingServer.get_frame_setup_time_cpu())
			_add("render.gpu_ms", RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
		_add("perf.active_bodies", Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), false)
		_add("perf.collision_pairs", Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS), false)
		var tk := PerfProbe.take()
		var acc: Dictionary = tk[0]
		var cnt: Dictionary = tk[1]
		for k: String in ["bot.mission", "bot.player", "bot.pb.sense", "bot.pb.threats", "bot.pb.tactics", "bot.pb.move",
				"bot.pb.aim", "bot.route_plan", "bot.rack", "mech.ctrl.bot", "mech.ctrl.local", "mech.rig.bot", "mech.rig.other",
				"combat.rack.local", "combat.advance", "combat.net_post", "net.sample.local", "net.sample.bots",
				"main.combat_log", "main.city_props", "main.combat_audio", "proc.model_pose", "bot.fire_guard"]:
			_add(k, float(acc.get(k, 0)) / 1000.0)
			_cnt(k, int(cnt.get(k, 0)))
		_add("ray.pb.los", float(cnt.get("ray.pb.los", 0)), false)
		var fx_us := 0
		for k: String in CombatWorld.prof:
			if k.begins_with("fx:"):
				fx_us += int(CombatWorld.prof[k])
		_add("combat.targets_tick(enemy AI+targets)", float(CombatWorld.prof.get("targets.tick", 0)) / 1000.0)
		_add("combat.effects", float(fx_us) / 1000.0)
		_add("combat.advanced_emit", float(CombatWorld.prof.get("advanced.emit", 0)) / 1000.0)
		CombatWorld.prof.clear()
		CombatWorld.prof_samples.clear()
		enemies_sum += td.combat.squad.alive_count() if td.combat.squad != null else 0
		fx_sum += td.combat.world.effects.size()
		for id: int in td.crew_bots:
			var cb := td.crew_bots[id] as CrewBot
			var m := cb.ai.mode if cb.ai != null else "none"
			modes[m] = int(modes.get(m, 0)) + 1
	PerfProbe.on = false
	CombatWorld.profiling = false
	print("[botperf] enemies alive avg %.1f, effects avg %.1f, bot modes (bot-frames) %s" % [enemies_sum / frames_n,
		fx_sum / frames_n, str(modes)])
	for id: int in td.crew_bots:
		var cb := td.crew_bots[id] as CrewBot
		if cb.ai != null:
			var st := cb.ai.stats()
			print("[botperf] bot %d: replans %s, goal %s" % [id, str(st.get("replans", "?")), cb.ai.goal_text])
	_codec_bench()
	_report()
	Session.end_mission()
	td.queue_free()
	await frames(2)
	Session.leave()


## The local mech: test_perf_coop's walk / strafe / run pattern, firing every weapon at the nearest live enemy.
func _drive_local(f: int, idle: bool) -> void:
	var m := td.mech
	if idle:
		m.move_input = Vector2.ZERO
		td.combat.rack.set_trigger(false)
		return
	m.move_input = Vector2(0.4 if (f / 50) % 2 == 0 else -0.4, 1.0 if (f / 90) % 2 == 0 else -1.0)
	m.running = (f % 80) > 40
	var best: EnemyBase = null
	var bd := INF
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed():
			var d := e.global_position.distance_squared_to(m.global_position)
			if d < bd:
				bd = d
				best = e
	if best != null:
		td.combat.rack.aim_point = best.global_position + Vector3(0.0, 2.5, 0.0)
	else:
		td.combat.rack.aim_point = m.global_position + m.forward() * 40.0 + m.up() * 3.0
	td.combat.rack.set_trigger((f % 240) < 180)


func _band(key: String, a: int, b: int, pre: bool = false) -> void:
	if pre:
		return
	if _probe_t.has(a) and _probe_t.has(b):
		_add(key, float(int(_probe_t[b]) - int(_probe_t[a])) / 1000.0)


func _add(key: String, v: float, _ms: bool = true) -> void:
	if not _rows.has(key):
		_rows[key] = []
	(_rows[key] as Array).append(v)


func _cnt(key: String, n: int) -> void:
	var k := "n:" + key
	if not _rows.has(k):
		_rows[k] = []
	(_rows[k] as Array).append(float(n))


## What streaming the crew would cost with clients: NetMechCodec.encode of 4 states (host + 3 bots), per call.
func _codec_bench() -> void:
	var states: Array[NetMechState] = []
	var seats := {}
	for i in 4:
		var st := NetMechState.new()
		st.peer = 1 if i == 0 else -i
		st.pos = Vector3(i, 0, i)
		st.aim = Vector3(0, 0, 40)
		seats[st.peer] = i + 1
		states.append(st)
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		NetMechCodec.encode(states, seats, 1.0)
	print("[botperf] codec: encode 4 states %.1f us per call (x30 Hz x clients)" % (float(Time.get_ticks_usec() - t0) / 1000.0))


func _report() -> void:
	var keys := _rows.keys()
	keys.sort()
	for k: String in keys:
		if k.begins_with("n:"):
			continue
		var a: Array = (_rows[k] as Array).duplicate()
		a.sort()
		var n := a.size()
		if n == 0:
			continue
		var sum := 0.0
		for v in a:
			sum += v
		var calls := ""
		if _rows.has("n:" + k):
			var c := 0.0
			for v: float in (_rows["n:" + k] as Array):
				c += v
			calls = " calls/frame=%.2f" % (c / float(n))
		print("[botperf] %-40s avg=%8.3f p95=%8.3f max=%8.3f%s" % [k, sum / n, a[int(n * 0.95)], a[n - 1], calls])


func _until(cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_usec() + int(timeout_s * 1e6)
	while not bool(cond.call()):
		if Time.get_ticks_usec() > end:
			return false
		await get_tree().process_frame
	return true
