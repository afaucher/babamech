extends TestCase
## Headless unit & integration tests for the Audio system (docs/design/audio.md):
##   1. 7-bus hierarchy, Master limiter, SFX compressor, and GameSettings volume/mute sync.
##   2. Deterministic PCM synthesis audit across EVERY cue in SoundBank (non-silent, no clipping, no NaN, identical hash).
##   3. Voice pooling, per-cue cooldowns, max_voices cap, priority stealing, priority ducking, and headless clock expiry.
##   4. MechAudio integration (gait footsteps + park grass detection, thrusters, emergency burn, hard landing, heat/shutdown/reboot, pilot cues).
##   5. CombatAudio integration (weapons, impacts, hit-confirms, stagger, wall slam, CityProps, EnemySquad & PlayerTarget contracts).
##   6. AudioLab contract sweep and clean loop teardown.


class MockEnemySquad extends Node:
	signal enemy_event(kind: String, enemy: Node, payload: Dictionary)

	func _init() -> void:
		add_to_group("enemy_squad")


class MockPlayerTarget extends Node:
	signal damaged(amount: float, component: String, src: String)
	signal staggered_by(src: String)
	signal player_component_destroyed(component: String)
	signal player_disabled(cause: String)

	func _init() -> void:
		add_to_group("player_target")


func setup() -> void:
	var a := get_tree().root.get_node_or_null("Audio") as AudioDirector
	if not check(a != null, "Audio autoload is an AudioDirector"):
		finish()
		return
	a.reset_state()
	a.record_events = true

	_test_buses_and_settings(a)
	_test_synth_determinism_and_quality(a)
	_test_pooling_limits_stealing_and_ducking(a)
	await _test_mech_audio(a)
	await _test_combat_props_and_enemy_contract(a)
	await _test_real_end_to_end_firefight(a)
	await _test_audio_lab(a)

	a.record_events = false
	a.reset_state()
	finish()


func _test_buses_and_settings(a: AudioDirector) -> void:
	AudioDirector.ensure_buses()
	for entry: Array in AudioDirector.BUS_TREE:
		var bname: String = entry[0]
		var parent: String = entry[1]
		var idx := AudioServer.get_bus_index(bname)
		check(idx >= 0, "bus %s exists" % bname)
		if idx >= 0:
			eq(AudioServer.get_bus_send(idx), parent, "bus %s sends to %s" % [bname, parent])
	var m_idx := AudioServer.get_bus_index(AudioDirector.BUS_MASTER)
	var s_idx := AudioServer.get_bus_index(AudioDirector.BUS_SFX)
	check(AudioDirector._has_effect(m_idx, AudioEffectLimiter), "Master bus has AudioEffectLimiter")
	check(AudioDirector._has_effect(s_idx, AudioEffectCompressor), "SFX bus has AudioEffectCompressor")

	# GameSettings.apply() drives Master, Music, SFX, and Ambience cleanly.
	var d := GameSettings.DEFAULTS.duplicate(true)
	d["sfx"] = 0.0
	d["music"] = 0.5
	GameSettings.apply(d, false)
	check(AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")), "muting sfx mutes SFX bus")
	check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Ambience")), "muting sfx mutes Ambience bus")
	check(not AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "Music stays unmuted at 0.5")
	GameSettings.apply(GameSettings.DEFAULTS.duplicate(true), false)
	check(not AudioServer.is_bus_mute(AudioServer.get_bus_index("Ambience")), "restoring defaults unmutes Ambience")


func _test_synth_determinism_and_quality(a: AudioDirector) -> void:
	var ids := SoundBank.all_ids()
	check(ids.size() >= 60, "SoundBank defines full cue palette (%d cues)" % ids.size())
	var bad_cues: Array[String] = []
	var dc_bad: Array[String] = []
	var seam_bad: Array[String] = []
	var tail_bad: Array[String] = []
	var stats_by_id: Dictionary = {}
	var max_dc := 0.0
	var max_seam := 0.0
	var max_tail_rms := 0.0
	var max_tail_last := 0.0
	var loop_count := 0
	var oneshot_count := 0
	for cid: String in ids:
		var sp := SoundBank.spec(cid)
		var wav := SoundBank.synthesize(cid)
		var st := AudioSynth.analyze(wav)
		stats_by_id[cid] = st
		var ok := wav != null and int(st["samples"]) > 100 and float(st["rms"]) > 0.005 \
			and float(st["peak"]) <= 0.985 and not bool(st["has_nan"])
		if not ok:
			bad_cues.append("%s(rms=%.4f,peak=%.4f)" % [cid, float(st["rms"]), float(st["peak"])])
		var dc := absf(float(st["mean"]))
		max_dc = maxf(max_dc, dc)
		if dc >= 0.015:
			dc_bad.append("%s(dc=%.4f)" % [cid, dc])
		if bool(sp.get("loop", false)):
			loop_count += 1
			var sd := float(st["seam_delta"])
			max_seam = maxf(max_seam, sd)
			if sd >= 0.04:
				seam_bad.append("%s(seam=%.4f)" % [cid, sd])
		else:
			oneshot_count += 1
			var tr := float(st["tail_rms"])
			var lv := absf(float(st["last"]))
			max_tail_rms = maxf(max_tail_rms, tr)
			max_tail_last = maxf(max_tail_last, lv)
			if tr >= 0.06 or lv >= 0.05:
				tail_bad.append("%s(tail_rms=%.4f,last=%.4f)" % [cid, tr, lv])
	check(bad_cues.is_empty(), "all cues valid, non-silent, unclipped, NaN-free (bad: %s)" % str(bad_cues))
	check(dc_bad.is_empty(), "all %d cues have zero DC offset < 0.015 (max %.5f; bad: %s)" % [ids.size(), max_dc, str(dc_bad)])
	check(loop_count >= 9 and seam_bad.is_empty(), "all %d loops seamless < 0.04 (max %.5f; bad: %s)" % [loop_count, max_seam, str(seam_bad)])
	check(oneshot_count >= 75 and tail_bad.is_empty(), "all %d one-shots tail-click-free < 0.06/0.05 (max rms %.4f last %.4f; bad: %s)" % [
		oneshot_count, max_tail_rms, max_tail_last, str(tail_bad)])

	# Effective loudness hierarchy (rms_db + nominal bus/cue db).
	var eff_db := func(cid: String) -> float:
		var st: Dictionary = stats_by_id[cid]
		var sp := SoundBank.spec(cid)
		return float(st["rms_db"]) + float(sp.get("db", 0.0))
	var db_mortar: float = eff_db.call("impact.explosive.large")
	var db_auto: float = eff_db.call("wpn.autocannon.fire")
	var db_laser: float = eff_db.call("wpn.laser.fire")
	var db_hover: float = eff_db.call("ui.hover")
	var db_tel_beam: float = eff_db.call("enemy.telegraph.beam")
	var db_tel_can: float = eff_db.call("enemy.telegraph.cannon")
	var db_amb: float = eff_db.call("amb.city.bed")
	check(db_mortar > db_auto and db_auto > db_hover,
		"loudness hierarchy: explosive.large (%.1f) > autocannon (%.1f) > ui.hover (%.1f)" % [db_mortar, db_auto, db_hover])
	check(db_mortar > db_laser and db_laser > db_hover,
		"loudness hierarchy: explosive.large (%.1f) > laser (%.1f) > ui.hover (%.1f)" % [db_mortar, db_laser, db_hover])
	check(db_tel_beam > db_amb + 6.0 and db_tel_can > db_amb + 6.0,
		"enemy telegraphs (beam %.1f, cannon %.1f) clearly cut above amb.city.bed (%.1f)" % [db_tel_beam, db_tel_can, db_amb])

	# Spectral separation: bass-heavy cues vs bright/alien cues (low-band energy share & zero-crossing rate).
	var bass_cues: Array[String] = ["impact.explosive.large", "wpn.mortar.fire", "mech.step.concrete"]
	var bright_cues: Array[String] = ["enemy.telegraph.beam", "wpn.laser.fire", "ui.hover"]
	var min_bass_low := 1.0
	var max_bass_zcr := 0.0
	for cid: String in bass_cues:
		var st: Dictionary = stats_by_id[cid]
		min_bass_low = minf(min_bass_low, float(st["low_ratio"]))
		max_bass_zcr = maxf(max_bass_zcr, float(st["zcr_hz"]))
	var max_bright_low := 0.0
	var min_bright_zcr := INF
	for cid: String in bright_cues:
		var st: Dictionary = stats_by_id[cid]
		max_bright_low = maxf(max_bright_low, float(st["low_ratio"]))
		min_bright_zcr = minf(min_bright_zcr, float(st["zcr_hz"]))
	check(min_bass_low > max_bright_low + 0.15,
		"spectral low-band (<400Hz) separation: bass min %.2f > bright max %.2f" % [min_bass_low, max_bright_low])
	check(max_bass_zcr < min_bright_zcr * 0.65,
		"spectral ZCR separation: bass max %.0f Hz < bright min %.0f Hz" % [max_bass_zcr, min_bright_zcr])
	print("[DSP] cues=%d max_dc=%.5f max_seam=%.5f max_tail_rms=%.4f bass_low>=%.2f bright_low<=%.2f bass_zcr<=%.0fHz bright_zcr>=%.0fHz" % [
		ids.size(), max_dc, max_seam, max_tail_rms, min_bass_low, max_bright_low, max_bass_zcr, min_bright_zcr])

	# Determinism: re-synthesizing produces byte-identical PCM.
	for cid: String in ["mech.step.concrete", "wpn.autocannon.fire", "enemy.telegraph.beam", "pilot.chicken", "music.calm"]:
		var h1 := str(AudioSynth.analyze(SoundBank.synthesize(cid))["hash"])
		var h2 := str(AudioSynth.analyze(SoundBank.synthesize(cid))["hash"])
		eq(h1, h2, "deterministic PCM hash for %s" % cid)

	# Music stems stay phase-locked (exact same sample length).
	var calm := SoundBank.synthesize("music.calm")
	var combat := SoundBank.synthesize("music.combat")
	eq(calm.data.size(), combat.data.size(), "music.calm and music.combat have identical loop length")
	eq(calm.loop_mode, AudioStreamWAV.LOOP_FORWARD, "music.calm loops forward")

	# Incremental prewarm caches without error.
	a.bank.clear_cache()
	var built := a.bank.prewarm_step(10.0)
	check(built > 0, "prewarm_step caches cues (%d built)" % built)


func _test_pooling_limits_stealing_and_ducking(a: AudioDirector) -> void:
	a.reset_state()
	# 1. Cooldown & max_voices enforcement on rapid-fire gatling.
	var accepted := 0
	for i in 60:
		if a.play_3d("wpn.gatling.fire", Vector3(0, 0, -5)) > 0:
			accepted += 1
	eq(accepted, 1, "60 same-instant gatling calls collapse to 1 via cooldown_ms")
	for i in 10:
		a.advance_clock(0.07)   # past 65 ms cooldown
		a.play_3d("wpn.gatling.fire", Vector3(0, 0, -5))
	check(a.active_for_cue("wpn.gatling.fire") <= 4, "gatling obeys max_voices=4 (%d)" % a.active_for_cue("wpn.gatling.fire"))

	# 2. Fill the 32-voice 3D pool with priority 0/1 cues, then verify priority 3 telegraph steals and cannot be stolen by priority 1.
	a.reset_state()
	var filler_cues := [
		"prop.tree.topple", "prop.metal.topple", "prop.bench.topple", "prop.bin.topple",
		"prop.tree.shove", "prop.metal.shove", "prop.bench.shove", "prop.bin.shove",
		"enemy.step", "mech.servo.turn", "impact.medium", "impact.energy",
	]
	for step_idx in 4:
		for c_idx in filler_cues.size():
			a.play_3d(filler_cues[c_idx], Vector3(float(c_idx), 0.0, -10.0))
		if step_idx < 3:
			a.advance_clock(0.055)
	eq(a.active_3d_count(), AudioDirector.POOL_3D, "3D voice pool filled to hard cap (%d)" % AudioDirector.POOL_3D)
	var tel_h := a.play_enemy_telegraph("enemy_1", "beam", Vector3(0, 2, -20), 0.6)
	check(tel_h > 0, "priority-3 enemy telegraph steals from full pool")
	eq(a.active_3d_count(), AudioDirector.POOL_3D, "3D pool never exceeds hard cap after steal")

	# Priority ducking engages while telegraph is active.
	a.advance_clock(0.10)
	check(a.duck_world_db() < -1.0, "active telegraph ducks SFX_World (%.2f dB)" % a.duck_world_db())
	check(a.duck_music_db() < -1.0, "active telegraph ducks Music (%.2f dB)" % a.duck_music_db())

	# Fill remaining 31 slots with priority 3? No, verify priority 1 cannot steal the priority 3 telegraph.
	a.play_3d("impact.small", Vector3(0, 1, -5))
	check(a.active_on_bus(AudioDirector.BUS_SFX_TELEGRAPH) >= 1, "priority-1 impact cannot steal priority-3 telegraph")

	# 3. Deterministic headless expiry reclaims all voices and releases ducking.
	a.advance_clock(3.0)
	eq(a.active_2d_count(), 0, "headless expiry reclaims all 2D voices")
	eq(a.active_3d_count(), 0, "headless expiry reclaims all 3D voices")
	near(a.duck_world_db(), 0.0, 0.05, "world ducking releases after telegraph expires")


func _test_mech_audio(a: AudioDirector) -> void:
	a.reset_state()
	a.record_events = true
	a.pilot_cues_enabled = true
	var mech := MechSpawn.make("pickle", "strider")
	add_child(mech)
	await frames(2)
	var ma := mech.get_node_or_null("Audio") as MechAudio
	if not check(ma != null, "MechSpawn.make attaches MechAudio child"):
		mech.queue_free()
		return
	var rig := MechSpawn.rig_of(mech)
	# Floor collider so mech walks on ground.
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(cs)
	add_child(floor_body)
	await frames(2)

	# Walk forward until footsteps plant.
	a.clear_events()
	mech.move_input = Vector2(0, 1)
	for i in 60:
		mech.step(1.0 / 60.0)
		rig.update_pose(1.0 / 60.0)
		ma.step(1.0 / 60.0)
		a.advance_clock(1.0 / 60.0)
	check(_has_cue(a, "mech.step.concrete"), "walking triggers concrete footsteps")
	check(_has_cue(a, "mech.servo.step"), "walking triggers leg servo cues")

	# Thruster ignition + loop + emergency burn alert.
	a.clear_events()
	mech.move_input = Vector2.ZERO
	mech.thrust_input = true
	mech.step(1.0 / 60.0)
	ma.step(1.0 / 60.0)
	check(_has_cue(a, "mech.thrust.ignite"), "thrusting triggers ignition transient")
	check(a.active_loop_count() >= 1, "thrusting starts continuous thruster loop")
	mech.emergency = true
	ma.step(1.0 / 60.0)
	check(_has_cue(a, "mech.thrust.emergency"), "emergency burn triggers alert cue")
	mech.thrust_input = false
	mech.emergency = false
	var fx := mech.get_node_or_null("Thrusters") as ThrusterFx
	if fx != null:
		fx.level = 0.0
	mech.thrusting = false
	ma.step(1.0 / 60.0)

	# Hard landing + deadpan pilot cue (and toggle check).
	a.clear_events()
	mech.hard_landing.emit(17.0, 0.85)
	check(_has_cue(a, "mech.land.hard"), "hard_landing triggers mech.land.hard")
	check(_has_cue(a, "pilot.pickle"), "severe hard landing triggers head-keyed deadpan pilot cue")
	a.clear_events()
	a.advance_clock(2.0)
	a.pilot_cues_enabled = false
	mech.hard_landing.emit(17.0, 0.85)
	check(not _has_cue(a, "pilot.pickle"), "pilot_cues_enabled=false suppresses pilot cue")
	a.pilot_cues_enabled = true

	# Heat hum (>55%), warning tick (>80%), shutdown, reboot spool & reboot chime.
	a.clear_events()
	mech.heat = 86.0
	ma.step(0.05)
	check(_has_cue(a, "mech.heat.tick"), "heat > 80% triggers warning tick")
	check(a.has_loop("mech.heat.%d" % ma.get_instance_id()), "heat > 55% runs thermal turbine loop")
	mech.add_heat(20.0)   # triggers overheated signal
	check(_has_cue(a, "mech.heat.shutdown"), "overheat triggers shutdown cue")
	mech.heat = mech.reboot_heat - 1.0
	ma.step(0.05)
	check(_has_cue(a, "mech.heat.reboot_spool"), "cooling to reboot_heat triggers reboot spool")
	mech.rebooted.emit()
	check(_has_cue(a, "mech.heat.reboot_ok"), "rebooted triggers ready chime")

	# Surface classification with a CityDistrict park block.
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 1.0})
	ma.city = city
	for b: Dictionary in city.plan.blocks:
		if str(b.get("kind", "")) == "park":
			var c: Vector2 = (b["rect"] as Rect2).get_center()
			var p := city.to_global(city.ring.arc_to_world(c.x, c.y, CityPlan.CURB_H))
			eq(ma.surface_at(p), "grass", "park block resolves to grass footstep surface")
			eq(ma.surface_at(city.to_global(city.ring.arc_to_world(c.x, c.y, 12.0))), "rooftop", "elevated point resolves to rooftop")
			break
	city.queue_free()
	mech.queue_free()
	floor_body.queue_free()
	await frames(2)


func _test_combat_props_and_enemy_contract(a: AudioDirector) -> void:
	a.reset_state()
	a.record_events = true
	var world := CombatWorld.new()
	world.use_physics = false
	add_child(world)
	var ca := CombatAudio.new()
	add_child(ca)
	ca.bind(world, null, null, "player1")

	# Register a TargetDummy and test fire, hit-confirm, stagger, slam, kill.
	var dummy := TargetDummy.new()
	dummy.target_id = "dummy_1"
	dummy.mass_class = "light"
	dummy.set_max_hp({"torso": 40.0})
	dummy.position = Vector3(0, 0, -20)
	add_child(dummy)
	world.register(dummy)
	ca.step(0.05)

	a.clear_events()
	var rec := Combat.fire_record("player1", 1, "side_r", "autocannon", Vector3(0, 2, 0), Vector3(0, 2, -20), world.now, 0, 0.0)
	world.fire(rec)
	check(_has_cue(a, "wpn.autocannon.fire"), "CombatWorld.fired triggers weapon audio")
	var enemy_rec := Combat.fire_record("enemy_1", 1, "gun", "autocannon", Vector3(0, 2, -20), Vector3(0, 2, 0), world.now, 0, 0.0)
	enemy_rec["enemy"] = true
	a.advance_clock(0.1)
	world.fire(enemy_rec)
	check(_has_cue(a, "enemy.fire.accent"), "enemy fire record layers alien accent")

	# Hit-confirm, component break & kill.
	a.clear_events()
	var h := Hit.new()
	h.damage = 50.0
	h.component = "torso"
	h.shooter = "player1"
	h.point = Vector3(0, 2, -20)
	world.deliver(dummy, h)
	check(_has_cue(a, "combat.hit.tick"), "local shooter hit triggers hit-confirm tick")
	check(_has_cue(a, "combat.hit.break"), "zeroing component HP triggers component break cue")
	check(_has_cue(a, "combat.kill"), "destroying target triggers kill cue")
	dummy.staggered_by.emit("player1")
	check(_has_cue(a, "combat.stagger"), "staggered_by triggers stagger cue")
	dummy.slammed.emit(12.0, 28.0)
	check(_has_cue(a, "combat.wall_slam"), "slammed triggers wall slam cue")

	# Impact scaling.
	a.clear_events()
	world.spawn_impact(Vector3(0, 1, -20), Vector3.UP, 6.0, MechMeshes.GREY, true)
	check(_has_cue(a, "impact.explosive.large"), "large explosive impact triggers impact.explosive.large")

	# CityProps signal hook.
	var city := CityDistrict.new()
	city.with_rig = false
	city.with_backdrop = false
	add_child(city)
	city.build({"seed": 2.0})
	ca.bind_props(city.props)
	a.clear_events()
	for it: Dictionary in city.props.items:
		if str(it["type"]) == "tree":
			city.props.request(int(it["id"]), CityPropSim.TOPPLE, Vector2(1, 0))
			break
	check(_has_cue(a, "prop.tree.topple"), "CityProps topple triggers prop.tree.topple")

	# Unified EnemySquad & PlayerTarget signal contract (auto-discovered via groups!).
	var sq := MockEnemySquad.new()
	add_child(sq)
	var pt := MockPlayerTarget.new()
	add_child(pt)
	ca._scan_t = 0.0
	ca.step(0.05)
	eq(ca.squad, sq, "CombatAudio auto-discovers EnemySquad via group enemy_squad")
	eq(ca.player_target, pt, "CombatAudio auto-discovers PlayerTarget via group player_target")

	a.advance_clock(0.2)
	a.clear_events()
	sq.enemy_event.emit("telegraph_started", sq, {"id": "e1", "weapon": "laser", "kind": "beam", "pos": Vector3(0, 2, -25), "target_pos": Vector3.ZERO, "duration": 0.6})
	check(_has_cue(a, "enemy.telegraph.beam"), "EnemySquad physical weapon charge telegraph plays enemy.telegraph.beam")
	sq.enemy_event.emit("telegraph_cancelled", sq, {"id": "e1", "reason": "staggered"})
	eq(a.active_on_bus(AudioDirector.BUS_SFX_TELEGRAPH), 0, "telegraph_cancelled stops active telegraph immediately")
	a.clear_events()
	sq.enemy_event.emit("telegraph_started", sq, {"id": "d1", "weapon": "enemy_beacon", "kind": "beacon", "pos": Vector3(0, 12, -45), "target_pos": Vector3.ZERO, "duration": 0.65})
	check(_has_cue(a, "enemy.alert.relay"), "Scout Drone Alert Beacon keeps its physical support-call siren")
	a.clear_events()
	sq.enemy_event.emit("telegraph_started", sq, {"id": "t1", "weapon": "enemy_troop_rifle", "kind": "troop_rifle", "pos": Vector3(0, 2, -25), "target_pos": Vector3.ZERO, "duration": 0.55})
	check(not _has_prefix(a, "enemy.telegraph."), "non-charging rifle does not play non-diegetic warning sound")
	sq.enemy_event.emit("alerted", sq, {"id": "e1", "state": "spotted", "pos": Vector3(0, 2, -25)})
	check(not _has_cue(a, "enemy.alert.spotted"), "regular alerted(spotted) does not play non-diegetic warning chime")
	sq.enemy_event.emit("alerted", sq, {"id": "e1", "state": "revealed", "pos": Vector3(0, 2, -25)})
	check(not _has_cue(a, "ui.hangar.alert"), "revealed straggler does not play non-diegetic 2D HUD beep")
	sq.enemy_event.emit("component_damaged", sq, {"id": "e1", "component": "core", "hp_ratio": 0.5, "weak_point": true, "pos": Vector3(0, 2, -25)})
	check(_has_cue(a, "combat.hit.weak"), "EnemySquad weak_point hit plays combat.hit.weak")
	sq.enemy_event.emit("overheated", sq, {"id": "e1", "pos": Vector3(0, 2, -25)})
	check(_has_cue(a, "enemy.overheat"), "EnemySquad overheated plays enemy.overheat")
	sq.enemy_event.emit("destroyed", sq, {"id": "e1", "cause": "hp", "pos": Vector3(0, 2, -25), "radius": 5.0})
	check(_has_cue(a, "enemy.destroyed"), "EnemySquad destroyed plays enemy.destroyed")
	sq.enemy_event.emit("footstep", sq, {"id": "e1", "pos": Vector3(0, 0, -15)})
	check(_has_cue(a, "enemy.step"), "EnemySquad footstep plays enemy.step")

	a.clear_events()
	pt.damaged.emit(20.0, "torso", "e1")
	pt.player_component_destroyed.emit("side_l")
	pt.player_disabled.emit("head")
	check(_has_cue(a, "combat.player.damaged"), "PlayerTarget damaged plays combat.player.damaged")
	check(_has_cue(a, "combat.player.part_lost"), "PlayerTarget component destroyed plays combat.player.part_lost")
	check(_has_cue(a, "combat.player.disabled"), "PlayerTarget disabled plays combat.player.disabled")

	sq.queue_free()
	pt.queue_free()
	city.queue_free()
	dummy.queue_free()
	ca.queue_free()
	world.queue_free()
	await frames(2)


func _test_real_end_to_end_firefight(a: AudioDirector) -> void:
	# Zero-mock end-to-end integration test: real CombatWorld, MechSpawn (with MechAudio), PlayerTarget, WeaponRack,
	# EnemySquad, EnemyTurret, EnemyStrider, and CombatAudio running a real firefight.
	a.reset_state()
	a.record_events = true
	var world := CombatWorld.new()
	world.name = "RealWorld"
	world.mission_seed = 7
	world.use_physics = false
	add_child(world)

	# Ground collider so the real MechController stays standing on y = 0 during physics frames.
	var floor_body := StaticBody3D.new()
	var floor_cs := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(200.0, 1.0, 200.0)
	floor_cs.shape = floor_box
	floor_cs.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(floor_cs)
	add_child(floor_body)

	var loadout := {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "mortar"}
	var mech := MechSpawn.make("chicken", "strider", loadout)
	add_child(mech)
	await frames(2)
	var rig := MechSpawn.rig_of(mech)
	var ma := mech.get_node_or_null("Audio") as MechAudio

	var pt := PlayerTarget.new()
	add_child(pt)
	pt.bind(world, mech, rig.model, "player1", 1)
	world.register(pt)

	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.read_input = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, rig.model, null, "player1", 1)

	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(world)

	var turret := EnemyTurret.new()
	turret.configure("turret", "e_turret", world, sq, null, 7)
	turret.position = Vector3(0.0, 0.0, -34.0)
	turret.rotation.y = PI       # face +Z toward the player mech at origin
	sq.add_enemy(turret)

	var strider := EnemyStrider.new()
	strider.configure("strider", "e_strider", world, sq, null, 7, 2.0)   # 2x HP so first laser staggers before kill
	strider.position = Vector3(9.0, 0.0, -30.0)
	strider.rotation.y = PI      # face +Z toward the player mech at origin
	sq.add_enemy(strider)

	var ca := CombatAudio.new()
	add_child(ca)
	ca.bind(world, rack, null, "player1")
	ca.bind_squad(sq)
	ca.bind_player_target(pt)
	await frames(2)

	# Phase 1: Real enemies spot player -> telegraph -> fire -> hit real PlayerTarget.
	a.clear_events()
	var dt := 1.0 / 60.0
	var got_player_hit := false
	for i in 300:
		world.advance(dt)
		ca.step(dt)
		if ma != null:
			ma.step(dt)
		a.advance_clock(dt)
		if _has_cue(a, "combat.player.damaged") and _has_prefix(a, "enemy.telegraph."):
			got_player_hit = true
			break
	check(not _has_cue(a, "enemy.alert.spotted"), "E2E real enemies omit non-diegetic spotted chime")
	check(_has_prefix(a, "enemy.telegraph."), "E2E real enemy plays >=0.3s physical weapon charge cue")
	check(_has_cue(a, "enemy.fire.accent"), "E2E real enemy fire layers alien accent")
	check(got_player_hit, "E2E real enemy projectile hits PlayerTarget -> combat.player.damaged")
	check(_has_prefix(a, "impact."), "E2E real enemy impact triggers impact.* audio")

	# Phase 2: Player fires real WeaponRack (laser + autocannon) back at real EnemyStrider until staggered & destroyed.
	a.clear_events()
	rack.set_enabled(1, true)    # side_l: laser (high knockback -> stagger)
	rack.set_enabled(2, true)    # side_r: autocannon
	rack.set_enabled(3, false)
	rack.set_enabled(5, false)
	rack.set_trigger(true)
	for i in 480:
		if not strider.destroyed():
			rack.aim_point = strider.global_position + Vector3(0.0, 2.5, 0.0)
		rack.step(dt)
		world.advance(dt)
		ca.step(dt)
		if ma != null:
			ma.step(dt)
		a.advance_clock(dt)
		if strider.destroyed() and (_has_cue(a, "combat.kill") or _has_cue(a, "enemy.destroyed")):
			break
	rack.set_trigger(false)
	check(strider.destroyed(), "E2E real player weapons destroy real EnemyStrider")
	check(_has_cue(a, "wpn.laser.fire") or _has_cue(a, "wpn.autocannon.fire"), "E2E real player WeaponRack triggers weapon fire audio")
	check(_has_cue(a, "combat.hit.tick") or _has_cue(a, "combat.hit.weak"), "E2E real hit on EnemyStrider triggers hit-confirm audio")
	check(_has_cue(a, "combat.stagger"), "E2E real laser/autocannon stagger on EnemyStrider triggers combat.stagger")
	check(_has_cue(a, "combat.kill") or _has_cue(a, "enemy.destroyed"), "E2E real EnemyStrider kill triggers kill/destroyed audio")
	check(_has_prefix(a, "impact."), "E2E real player hits trigger impact.* audio")

	ca.queue_free()
	sq.queue_free()
	rack.queue_free()
	pt.queue_free()
	mech.queue_free()
	floor_body.queue_free()
	world.queue_free()
	await frames(2)


func _test_audio_lab(a: AudioDirector) -> void:
	a.reset_state()
	a.record_events = true
	var lab := AudioLab.new()
	add_child(lab)
	await frames(2)
	check(lab.lab_params().size() >= 6, "AudioLab exposes tunable params")
	check(lab.lab_options().size() >= 6, "AudioLab exposes soundboard options")
	for p: Dictionary in lab.lab_params():
		lab.set_lab_param(str(p["id"]), float(p["max"]))
		lab.set_lab_param(str(p["id"]), float(p["min"]))
	lab.set_lab_option("telegraph", "cannon")
	lab.trigger_now()
	check(_has_cue(a, "enemy.telegraph.cannon"), "AudioLab auditions enemy telegraph")
	lab.queue_free()
	await frames(2)
	eq(a.active_loop_count(), 0, "AudioLab frees all active loops on exit")


static func _has_cue(a: AudioDirector, cue_id: String) -> bool:
	for ev: Dictionary in a.recent_events:
		if str(ev["cue"]) == cue_id:
			return true
	return false


static func _has_prefix(a: AudioDirector, prefix: String) -> bool:
	for ev: Dictionary in a.recent_events:
		if str(ev["cue"]).begins_with(prefix):
			return true
	return false
