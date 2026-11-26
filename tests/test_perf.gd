extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Inter-frame performance & stutter profiler (runs real TestDrive combat with physics, AI, weapons, props, HUD, audio).
## Measures per-frame CPU time (p50 / p95 / p99 / max) and breaks down CombatWorld/AI, WeaponRack, WorldAimMarkers,
## Audio prewarm, and warm vs. cold gameplay frames so bursty spikes are caught automatically.

const SERIAL := true   # wall-clock budget: test_runner runs it alone, after the parallel batch
const DT := 1.0 / 60.0


func setup() -> void:
	await _profile_test_drive()
	finish()


func _profile_test_drive() -> void:
	var audio := get_tree().root.get_node_or_null("Audio") as AudioDirector
	if audio != null:
		audio.silent = false   # time the live game's audio path (headless runs are silent by default: AudioDirector.silent)
		audio.bank.clear_cache()
		audio.bank.start_async_prewarm()   # exercise the exact non-blocking live-game audio path
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	if audio != null and audio.music != null:
		audio.music.set_ambience("city")
		audio.music.set_mode("calm")
	await frames(4)
	td.drive_override = true
	td.combat.rack.read_input = false
	td.combat.rack.manual_aim = true
	# The loop below steps the mech, rig, rack and CombatWorld itself (to time each): their own physics callbacks would
	# step them a second time every frame (the game at double speed, twice the shots and AI), so they are off here.
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)

	# A REPRESENTATIVE ENCOUNTER (written reason): the garrison is spread over every deck (EnemySpawner, encounter
	# sites, a 70 m safe bubble), so from the entry spawn the nearest awake enemy stands ~330 m off and nobody engages.
	# A real fight is the crew ~70 m from the entry deck's garrison, that whole deck awake (EnemySquad.deck_awake) and
	# the other decks asleep, as in a mission. Put the mech on the entry deck's road crossing nearest to 70 m from its
	# closest live enemy.
	var deck0 := td.stack.deck_at(td.mech.global_position) if td.stack != null else 0
	if td.stack != null:
		_place_near_garrison(td, deck0, 70.0)
		await frames(2)
	var me := td.combat.player_target.target_id if td.combat.player_target != null else "player1"
	# Alert enemies (from the mech's own id, so the alert lands) so AI pathing, steering, telegraphs, firing, and combat
	# effects are all active!
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0, "", me)

	var frame_ms: Array[float] = []
	var spikes: Array[String] = []
	var max_cw := 0.0
	var max_rack := 0.0
	var max_aim := 0.0
	var max_mech := 0.0
	var max_rig := 0.0
	var sum_cw := 0.0
	var sum_rack := 0.0
	var sum_aim := 0.0
	var sum_mech := 0.0
	var sum_rig := 0.0

	var mh := td.get_node_or_null("MechHud") as MechHud
	var prev_us := Time.get_ticks_usec()
	for f in 240:
		var now_us := Time.get_ticks_usec()
		var dt_wall := float(now_us - prev_us) / 1000.0
		prev_us = now_us
		if f > 2:
			frame_ms.append(dt_wall)

		# Realistic active gameplay: strafe, walk/run, thrust, aim & fire at live enemies.
		td.mech.move_input = Vector2(1.0 if (f / 40) % 2 == 0 else -1.0, 0.5)
		td.mech.running = (f % 80) > 40
		td.mech.thrust_input = (f >= 45 and f < 80) or (f >= 150 and f < 185)
		var aim_e: EnemyBase = null   # the nearest live enemy on the mech's deck
		var aim_d := INF
		for e in td.combat.enemies:
			if is_instance_valid(e) and not e.destroyed() and e.spawn_deck == deck0:
				var d := e.global_position.distance_to(td.mech.global_position)
				if d < aim_d:
					aim_d = d
					aim_e = e
		if aim_e != null:
			td.combat.rack.aim_point = aim_e.global_position + Vector3(0.0, 2.5, 0.0)
			td.combat.rack.set_trigger(f >= 20 and f < 190)
		else:
			td.combat.rack.set_trigger(false)

		# Measure each subsystem's direct CPU cost cleanly on this frame.
		var t0 := Time.get_ticks_usec()
		td.mech.step(DT)
		var t1 := Time.get_ticks_usec()
		td.rig.update_pose(DT)
		var t2 := Time.get_ticks_usec()
		td.combat.rack.step(DT)
		var t3 := Time.get_ticks_usec()
		td.combat.world.advance(DT)
		var t4 := Time.get_ticks_usec()
		if mh != null and mh.world_aim != null:
			mh.world_aim.sync()
		var t5 := Time.get_ticks_usec()

		var mech_ms := float(t1 - t0) / 1000.0
		var rig_ms := float(t2 - t1) / 1000.0
		var rack_ms := float(t3 - t2) / 1000.0
		var cw_ms := float(t4 - t3) / 1000.0
		var aim_ms := float(t5 - t4) / 1000.0

		sum_mech += mech_ms; max_mech = maxf(max_mech, mech_ms)
		sum_rig += rig_ms; max_rig = maxf(max_rig, rig_ms)
		sum_rack += rack_ms; max_rack = maxf(max_rack, rack_ms)
		sum_cw += cw_ms; max_cw = maxf(max_cw, cw_ms)
		sum_aim += aim_ms; max_aim = maxf(max_aim, aim_ms)

		if f > 2 and (dt_wall > 10.0 or cw_ms > 4.0):
			spikes.append("f=%3d wall=%5.2fms | mech=%.2f rig=%.2f rack=%.2f combat/AI=%.2f aim=%.2f | fx=%d alive=%d" % [
				f, dt_wall, mech_ms, rig_ms, rack_ms, cw_ms, aim_ms,
				td.combat.world.effects.size(), td.combat.squad.alive_count()])

		await get_tree().physics_frame

	frame_ms.sort()
	var n := frame_ms.size()
	var avg := 0.0
	for v in frame_ms:
		avg += v
	avg /= maxf(float(n), 1.0)
	print("[perf] active combat (%d frames): avg=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms" % [
		n, avg, frame_ms[n / 2], frame_ms[int(n * 0.95)], frame_ms[int(n * 0.99)], frame_ms[-1]])
	print("[perf] subsystem avg / max (ms):")
	print("  MechController:  %.3f / %.3f" % [sum_mech / 240.0, max_mech])
	print("  MechRig (IK):    %.3f / %.3f" % [sum_rig / 240.0, max_rig])
	print("  WeaponRack:      %.3f / %.3f" % [sum_rack / 240.0, max_rack])
	print("  CombatWorld+AI:  %.3f / %.3f" % [sum_cw / 240.0, max_cw])
	print("  WorldAimMarkers: %.3f / %.3f" % [sum_aim / 240.0, max_aim])
	if audio != null:
		print("[perf] Audio cache size=%d/%d" % [audio.bank._cache.size(), SoundBank.SPECS.size()])
	print("[perf] Spikes >10ms wall or >4ms AI (%d):" % spikes.size())
	for i in mini(20, spikes.size()):
		print("  " + spikes[i])

	check(max_cw < 4.0, "CombatWorld+AI stays under 4 ms/frame (max %.2f ms)" % max_cw)
	check(max_rack < 4.0, "WeaponRack stays under 4 ms/frame (max %.2f ms)" % max_rack)
	check(frame_ms[int(n * 0.95)] < 10.0, "p95 frame time stays under 10 ms (%.2f ms)" % frame_ms[int(n * 0.95)])

	if audio != null and audio.music != null:
		audio.music.set_ambience("off")
		audio.music.set_mode("off")
		audio.bank.shutdown_async()
	td.queue_free()
	await frames(2)


## The road crossing of deck `k` (CityPlan.road_graph: open street) whose distance to the nearest live enemy of that
## deck is closest to `want` m; the mech goes there, keeping its heading.
func _place_near_garrison(td: TestDrive, k: int, want: float) -> void:
	var nodes: Array = td.stack.decks[k].plan.road_graph()["nodes"]
	var best := td.mech.global_position
	var best_err := INF
	var best_d := INF
	for n: Vector2 in nodes:
		var p := td.stack.from_deck_arc(k, n.x, n.y, CityPlan.CURB_H + 0.3)
		var dmin := INF
		for e in td.combat.enemies:
			if is_instance_valid(e) and not e.destroyed() and e.spawn_deck == k:
				dmin = minf(dmin, p.distance_to(e.global_position))
		if absf(dmin - want) < best_err:
			best_err = absf(dmin - want)
			best = p
			best_d = dmin
	var xf := td.mech.global_transform
	xf.origin = best
	td.mech.global_transform = xf
	td.mech.velocity = Vector3.ZERO
	td.rig.gait.reset([])
	var awake := 0
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed() and td.combat.squad.deck_awake(e.spawn_deck):
			awake += 1
	print("[perf] encounter: deck %d crossing %.0f m from its nearest enemy; %d of %d enemies on that deck, %d awake" % [k,
		best_d, _on_deck(td, k), td.combat.enemies.size(), awake])


func _on_deck(td: TestDrive, k: int) -> int:
	var n := 0
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed() and e.spawn_deck == k:
			n += 1
	return n
