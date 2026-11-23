extends TestCase
## NOT part of -TestAll (the name has no "test_" prefix): a repeatable headless micro-benchmark of CombatWorld's effects
## under test_perf's combat load. Same scene, same encounter, same inputs, same 240 frames as tests/test_perf.gd (the mech
## on the entry deck's road crossing ~70 m from its garrison, that deck alerted from the player target's id, aiming at the
## nearest live enemy on the deck; mech / rig / combat physics callbacks off because the loop steps them), but with
## CombatWorld.profiling on around the test's own rack.step / world.advance calls, so every effect's advance_to is timed
## and grouped by script, plus the hot calls (first_hit, shot_ray, spawn_impact, splash's impact_from and fire's fired
## signals with their listeners, the targets' AI tick). Prints "[fxbench]" lines: per key, ms per frame avg / max and calls
## per frame; "[fxbench-call]" lines: per key, microseconds per CALL (median / p95 / max over every call of the run).
## Always passes. Run it several times and compare medians (tools/fx_bench/run_fx_bench.ps1).

const DT := 1.0 / 60.0
const FRAMES := 240
const RACK_SPIKE_MS := 1.5    ## rack.step frames slower than this print their phase breakdown ("[fxbench] rack spike")
const LOADOUT := {"side_l": "gatling", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "missiles", "back": "mortar"}
## Keys whose per-call samples ("[fxbench-call]") are printed (CombatWorld.prof_samples, profiling only).
const CALL_KEYS := ["first_hit", "spawn_impact", "si.surface", "si.wall", "si.setup", "shot_ray", "splash", "fx:ImpactFx"]


func setup() -> void:
	await _bench()
	finish()


func _bench() -> void:
	# A fixed, projectile-heavy loadout in a settings file of its own, so runs compare (test_perf flies whatever the player
	# last chose in the hangar).
	# FX_BENCH_LOADOUT=user (run_fx_bench.ps1 -UserLoadout): fly the player's saved loadout instead, as test_perf does.
	var saved_path := GameSettings.path
	if OS.get_environment("FX_BENCH_LOADOUT") != "user":
		GameSettings.path = "user://bench_combat_fx_settings.cfg"
		var cfg := ConfigFile.new()
		cfg.set_value("hangar", "chassis", "strider")
		cfg.set_value("hangar", "loadout", LOADOUT)
		cfg.save(GameSettings.path)
	var audio := get_tree().root.get_node_or_null("Audio") as AudioDirector
	if audio != null:
		audio.bank.clear_cache()
		audio.bank.start_async_prewarm()
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	if audio != null and audio.music != null:
		audio.music.set_ambience("city")
		audio.music.set_mode("calm")
	await frames(4)
	print("[fxbench] loadout: %s | mesh pool %d" % [str(td.combat.rack.weapons), int(td.combat.world.get("_mesh_pool_n") if "_mesh_pool_n" in td.combat.world else -1)])
	td.drive_override = true
	td.combat.rack.read_input = false
	td.combat.rack.manual_aim = true
	# As test_perf: the loop steps mech, rig, rack and CombatWorld itself, so their own physics callbacks are off.
	td.mech.set_physics_process(false)
	td.rig.set_physics_process(false)
	td.combat.set_physics_process(false)
	# As test_perf: the encounter is the entry deck's garrison from ~70 m (see test_perf's written reason).
	var deck0 := td.stack.deck_at(td.mech.global_position) if td.stack != null else 0
	if td.stack != null:
		_place_near_garrison(td, deck0, 70.0)
		await frames(2)
	var me := td.combat.player_target.target_id if td.combat.player_target != null else "player1"
	for e in td.combat.enemies:
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0, "", me)
	print("[fxbench] targets registered: %d" % td.combat.world.targets.size())

	_time_listeners(td.combat.world.fired, "fired>")
	var sums: Dictionary = {}     # "world:key" / "rack:key" -> total usec
	var maxs: Dictionary = {}     # -> max usec in one frame
	var cnts: Dictionary = {}     # -> total calls
	var calls: Dictionary = {}    # key -> PackedInt32Array of usec per call (both scopes)
	var cw_max := 0.0
	var cw_sum := 0.0
	var cw_all: Array[float] = []
	var fx_live_max := 0
	var fx_live_sum := 0
	var live_by: Dictionary = {}
	var rk_sum := 0.0
	var rk_all: Array[float] = []
	var rk_spikes: Array[String] = []
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var has_samples := true       # CombatWorld.prof_samples (per-call usec while profiling)
	for f in FRAMES:
		td.mech.move_input = Vector2(1.0 if (f / 40) % 2 == 0 else -1.0, 0.5)
		td.mech.running = (f % 80) > 40
		td.mech.thrust_input = (f >= 45 and f < 80) or (f >= 150 and f < 185)
		var aim_e: EnemyBase = null   # the nearest live enemy on the mech's deck (as test_perf)
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
		td.mech.step(DT)
		td.rig.update_pose(DT)
		CombatWorld.profiling = true
		CombatWorld.prof.clear()
		if has_samples:
			CombatWorld.prof_samples.clear()
		var t2 := Time.get_ticks_usec()
		td.combat.rack.step(DT)
		var rk := float(Time.get_ticks_usec() - t2) / 1000.0
		rk_sum += rk
		rk_all.append(rk)
		if rk > RACK_SPIKE_MS:
			var parts: Array[String] = []
			for k: String in CombatWorld.prof:
				if not k.begins_with("n:") and int(CombatWorld.prof[k]) >= 100:
					parts.append("%s=%.2f(x%d)" % [k, float(CombatWorld.prof[k]) / 1000.0, int(CombatWorld.prof.get("n:" + k, 0))])
			rk_spikes.append("f=%3d rack=%.2fms fx=%d nodes=%d | %s" % [f, rk, td.combat.world.effects.size(),
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), " ".join(parts)])
		_fold("rack", CombatWorld.prof, sums, maxs, cnts)
		CombatWorld.prof.clear()
		var t3 := Time.get_ticks_usec()
		td.combat.world.advance(DT)
		var cw := float(Time.get_ticks_usec() - t3) / 1000.0
		_fold("world", CombatWorld.prof, sums, maxs, cnts)
		CombatWorld.profiling = false
		CombatWorld.prof.clear()
		if has_samples:
			for k: String in CombatWorld.prof_samples:
				var arr: PackedInt32Array = calls.get(k, PackedInt32Array())   # packed arrays copy on write: store back
				arr.append_array(CombatWorld.prof_samples[k])
				calls[k] = arr
			CombatWorld.prof_samples.clear()
		cw_sum += cw
		cw_max = maxf(cw_max, cw)
		cw_all.append(cw)
		var n := td.combat.world.effects.size()
		fx_live_sum += n
		fx_live_max = maxi(fx_live_max, n)
		for e in td.combat.world.effects:
			var s: Script = e.get_script()
			var k: String = s.get_global_name() if s != null else "?"
			live_by[k] = int(live_by.get(k, 0)) + 1
		await get_tree().physics_frame
	CombatWorld.profiling = false
	cw_all.sort()
	print("[fxbench] CombatWorld.advance (test call): avg=%.3f p50=%.3f p95=%.3f max=%.3f ms | live effects avg=%.1f max=%d | nodes +%d" % [
		cw_sum / FRAMES, cw_all[FRAMES / 2], cw_all[int(FRAMES * 0.95)], cw_max, float(fx_live_sum) / FRAMES, fx_live_max,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT) - nodes0)])
	rk_all.sort()
	print("[fxbench] WeaponRack.step (test call): avg=%.3f p50=%.3f p95=%.3f max=%.3f ms" % [rk_sum / FRAMES,
		rk_all[FRAMES / 2], rk_all[int(FRAMES * 0.95)], rk_all[-1]])
	for s in rk_spikes:
		print("[fxbench] rack spike " + s)
	var keys := sums.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return int(sums[a]) > int(sums[b]))
	for k: String in keys:
		print("[fxbench] %-34s avg=%7.3f ms  max=%7.3f ms  calls/frame=%7.2f" % [k, float(sums[k]) / 1000.0 / FRAMES,
			float(maxs[k]) / 1000.0, float(cnts.get(k, 0)) / FRAMES])
	for k: String in CALL_KEYS:
		var v: PackedInt32Array = calls.get(k, PackedInt32Array())
		if v.is_empty():
			continue
		v.sort()
		print("[fxbench-call] %-20s med=%7d us  p95=%7d us  max=%7d us  calls=%d" % [k, v[v.size() / 2], v[int(v.size() * 0.95)],
			v[v.size() - 1], v.size()])
	var lk := live_by.keys()
	lk.sort()
	var parts: Array[String] = []
	for k: String in lk:
		parts.append("%s=%.1f" % [k, float(live_by[k]) / FRAMES])
	print("[fxbench] live per frame: " + ", ".join(parts))
	if audio != null and audio.music != null:
		audio.music.set_ambience("off")
		audio.music.set_mode("off")
		audio.bank.shutdown_async()
	td.queue_free()
	await frames(2)
	GameSettings.path = saved_path


## test_perf's placement: the road crossing of deck `k` whose distance to the nearest live enemy of that deck is closest
## to `want` m; the mech goes there, keeping its heading.
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
	print("[fxbench] encounter: deck %d crossing %.0f m from its nearest enemy" % [k, best_d])


## Re-connect every listener of `sig` (same order) through a wrapper that times it into CombatWorld.prof as
## "<prefix><script>.<method>" while profiling (bench only: the listeners still run exactly once per emit).
func _time_listeners(sig: Signal, prefix: String) -> void:
	for c: Dictionary in sig.get_connections():
		var cb: Callable = c["callable"]
		var o := cb.get_object()
		var s: Script = o.get_script() if o != null else null
		var key: String = prefix + (s.get_global_name() if s != null and s.get_global_name() != "" else str(o)) + "." + str(cb.get_method())
		sig.disconnect(cb)
		sig.connect(func(a: Variant) -> void:
			if not CombatWorld.profiling:
				cb.call(a)
				return
			var t := Time.get_ticks_usec()
			cb.call(a)
			CombatWorld.prof_add(key, Time.get_ticks_usec() - t))


func _fold(scope: String, prof: Dictionary, sums: Dictionary, maxs: Dictionary, cnts: Dictionary) -> void:
	for k: String in prof:
		if k.begins_with("n:"):
			continue
		var key := scope + ":" + k
		var us := int(prof[k])
		sums[key] = int(sums.get(key, 0)) + us
		maxs[key] = maxi(int(maxs.get(key, 0)), us)
		cnts[key] = int(cnts.get(key, 0)) + int(prof.get("n:" + k, 0))
