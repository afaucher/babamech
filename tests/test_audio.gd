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


## Stands in for TestDrive / ThrusterLab: the parent whose `mech` is the mech this machine pilots (MechAudio._local()).
class PilotHost extends Node3D:
	var mech: MechController


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
	await _test_mech_step_signal(a)
	await _test_remote_mech_audio(a)
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
	var host := PilotHost.new()
	add_child(host)
	var mech := MechSpawn.make("pickle", "strider")
	host.mech = mech
	host.add_child(mech)
	await frames(2)
	var ma := mech.get_node_or_null("Audio") as MechAudio
	if not check(ma != null, "MechSpawn.make attaches MechAudio child"):
		host.queue_free()
		return
	check(ma._local(), "the parent's piloted mech (TestDrive.mech) counts as the local pilot's")
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
	a.advance_clock(0.1)
	check(a.duck_world_db() < -1.0, "own overheat ducks the world (%.2f dB)" % a.duck_world_db())
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
	host.queue_free()
	floor_body.queue_free()
	await frames(2)


## Footfalls driven by Gait.stepped (MechAudio._on_stepped queues, _step_gait plays): per-kind levels, and a teammate's
## puppet (MechController.puppet) whose own gait emits the signal locally plays them on the world bus.
func _test_mech_step_signal(a: AudioDirector) -> void:
	a.reset_state()
	a.record_events = true
	var host := PilotHost.new()
	add_child(host)
	var mech := MechSpawn.make("pickle", "strider")
	host.mech = mech
	host.add_child(mech)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(cs)
	add_child(floor_body)
	await frames(2)
	var ma := mech.get_node_or_null("Audio") as MechAudio
	var rig := MechSpawn.rig_of(mech)
	if not check(ma != null and rig != null and rig.gait != null, "step-signal mech has MechAudio, rig and gait"):
		host.queue_free()
		floor_body.queue_free()
		return
	rig.set_physics_process(false)   # no real gait steps in between: only the emitted ones below
	ma.set_physics_process(false)
	await frames(10)                 # the controller settles onto the floor
	check(mech.grounded(), "step-signal mech stands on the floor")
	var g := rig.gait
	var at := mech.global_position + Vector3(1.0, 0.0, 0.5)
	ma.step(1.0 / 60.0)
	# Emit one step event, check nothing plays inside the signal, then flush with ma.step; returns the mech.step.* events.
	var emit_step := func(kind: String, w: float) -> Array:
		a.advance_clock(1.0)
		a.clear_events()
		g.stepped.emit(0, {"kind": kind, "length": w * g.step_length, "weight": w, "pos": at})
		var inside := _cues_with_prefix(a, "mech.step.").size()
		ma.step(1.0 / 60.0)
		var out := _cues_with_prefix(a, "mech.step.")
		if inside > 0:
			out.append({"cue": "played_inside_signal", "db": 0.0, "bus": ""})
		return out
	var full: Array = emit_step.call("stride", 1.0)
	eq(full.size(), 1, "a stride step plays one mech.step.* cue (after the signal, in step())")
	if full.size() == 1:
		eq(str(full[0]["bus"]), AudioDirector.BUS_SFX_PLAYER, "own mech's stride on the player bus")
		check((full[0]["pos"] as Vector3).distance_to(at) < 0.01, "stride plays at info.pos")
	var landed: Array = emit_step.call("land", 1.0)
	eq(landed.size(), 0, "a land step plays no mech.step.* cue")
	var short: Array = emit_step.call("stride", 0.3)
	if check(short.size() == 1 and full.size() == 1, "a short stride plays once"):
		check(float(short[0]["db"]) < float(full[0]["db"]) - 3.0, "a weight-0.3 stride (%.1f dB) is quieter than a full one (%.1f dB)" % [
			float(short[0]["db"]), float(full[0]["db"])])
	var corr: Array = emit_step.call("correction", 0.5)
	if check(corr.size() == 1 and full.size() == 1, "a correction step plays once"):
		check(float(corr[0]["db"]) < float(full[0]["db"]) - 6.0, "a correction (%.1f dB) is clearly quieter than a full stride (%.1f dB)" % [
			float(corr[0]["db"]), float(full[0]["db"])])
	eq((emit_step.call("settle", 0.02) as Array).size(), 0, "a negligible settle step is silent")

	# A teammate's puppet: same MechAudio, its own rig's gait steps locally from the motion written into it.
	mech.set_physics_process(false)
	mech.puppet = true
	mech.puppet_grounded = true
	var pup: Array = emit_step.call("stride", 1.0)
	if check(pup.size() == 1, "a puppet's stride plays one mech.step.* cue"):
		eq(str(pup[0]["bus"]), AudioDirector.BUS_SFX_WORLD, "a puppet's stride plays on the world bus")
	a.advance_clock(1.0)
	a.clear_events()
	var emitted := [0]
	var count_cb := func(_f: int, _i: Dictionary) -> void: emitted[0] += 1
	g.stepped.connect(count_cb)
	var dt := 1.0 / 60.0
	mech.velocity = mech.forward() * 10.0
	for i in 90:
		mech.global_position += mech.velocity * dt
		rig.update_pose(dt)
		ma.step(dt)
		a.advance_clock(dt)
	g.stepped.disconnect(count_cb)
	check(emitted[0] > 0, "a puppet's own gait emits stepped locally (%d steps)" % emitted[0])
	var walk := _cues_with_prefix(a, "mech.step.")
	check(walk.size() > 0, "a moving puppet's gait steps play footfalls (%d)" % walk.size())
	var all_world := true
	for e: Dictionary in walk:
		all_world = all_world and str(e["bus"]) == AudioDirector.BUS_SFX_WORLD
	check(all_world, "every puppet footfall is on the world bus")
	host.queue_free()
	floor_body.queue_free()
	await frames(2)


## Only the mech this machine pilots plays cockpit cues (docs/coordination 2026-11-23 audio fix). A host-run bot (a
## non-puppet mech that is not the parent's `mech`, like a CrewBot's on TestDrive), a mech nobody marked, and a puppet
## (even one forced is_local) are REMOTE: no 2D / player-bus / telegraph-bus cue, no pilot voice, no heat duck; their
## steps, thrusters, landings and power-down play 3D on SFX_World at the mech.
func _test_remote_mech_audio(a: AudioDirector) -> void:
	a.reset_state()
	a.record_events = true
	a.pilot_cues_enabled = true
	var host := PilotHost.new()
	add_child(host)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(cs)
	add_child(floor_body)
	var mine := MechSpawn.make("pickle", "strider", {}, 1)
	host.mech = mine
	host.add_child(mine)
	var bot := MechSpawn.make("corn", "strider", {}, 1)      # host-run bot: same owner peer as mine, not host.mech
	bot.position = Vector3(20, 0, 0)
	host.add_child(bot)
	var stray := MechSpawn.make("dog", "strider")           # nobody marked it (its parent has no `mech`)
	stray.position = Vector3(-20, 0, 0)
	add_child(stray)
	var pup := MechSpawn.make("chicken", "strider", {}, 2)  # a teammate's puppet
	pup.position = Vector3(0, 0, 20)
	host.add_child(pup)
	await frames(2)
	var all: Array[MechController] = [mine, bot, stray, pup]
	for m: MechController in all:
		MechSpawn.rig_of(m).set_physics_process(false)
		(m.get_node("Audio") as MechAudio).set_physics_process(false)
	await frames(10)   # settle onto the floor
	for m: MechController in all:
		m.set_physics_process(false)
	pup.puppet = true
	pup.puppet_grounded = true
	var pup_ma := pup.get_node("Audio") as MechAudio
	pup_ma.is_local = true   # a puppet is never local, even when forced
	check((mine.get_node("Audio") as MechAudio)._local(), "remote test: the piloted mech is local")
	for m: MechController in [bot, stray, pup]:
		var label := str(m.name) + (" (bot)" if m == bot else (" (unmarked)" if m == stray else " (puppet)"))
		check(not (m.get_node("Audio") as MechAudio)._local(), "%s is not local" % label)
		await _check_remote_mech(a, m, label)
	# The local pilot's mech still gets its cockpit cues (after the remote ones: its heat duck would mask theirs).
	var ma := mine.get_node("Audio") as MechAudio
	a.advance_clock(1.0)
	a.clear_events()
	mine.heat = mine.heat_cap * 0.86
	ma.step(0.05)
	check(_has_cue(a, "mech.heat.tick"), "own mech: heat > 80% still ticks")
	a.advance_clock(0.1)
	check(a.duck_world_db() < -1.0, "own mech: high heat still ducks the world (%.2f dB)" % a.duck_world_db())
	mine.heat = 0.0
	ma.step(0.05)
	a.advance_clock(1.0)
	a.clear_events()
	mine.thrusting = true
	mine.emergency = true
	ma.step(1.0 / 60.0)
	check(_kinds(a, "mech.thrust.emergency").has("2d"), "own mech: emergency burn alert is 2D")
	var ign := _events(a, "mech.thrust.ignite")
	check(ign.size() == 1 and str(ign[0]["bus"]) == AudioDirector.BUS_SFX_PLAYER, "own mech: ignition on the player bus")
	mine.thrusting = false
	mine.emergency = false
	(mine.get_node("Thrusters") as ThrusterFx).level = 0.0
	ma.step(1.0 / 60.0)
	host.queue_free()
	stray.queue_free()
	floor_body.queue_free()
	await frames(2)
	a.reset_state()
	a.record_events = true


## Heat, overheat, reboot, thrusters, emergency, landings and a footfall of a remote mech `m`.
func _check_remote_mech(a: AudioDirector, m: MechController, label: String) -> void:
	var ma := m.get_node("Audio") as MechAudio
	var at := m.global_position
	a.reset_state()
	a.record_events = true
	a.clear_events()
	var leaks: Array = []   ## cues of this remote mech on 2D / SFX_Player / SFX_Telegraph (must stay empty)
	m.heat = m.heat_cap * 0.9
	for i in 6:
		ma.step(0.05)
		a.advance_clock(0.05)
	check(not _has_prefix(a, "mech.heat."), "%s: heat > 80%% plays no heat loop / tick" % label)
	check(not a.has_loop("mech.heat.%d" % ma.get_instance_id()), "%s: no cockpit heat loop" % label)
	near(a.duck_world_db(), 0.0, 0.05, "%s: high heat does not duck the world" % label)
	_take_leaks(a, leaks)
	m.overheated.emit()
	for i in 4:
		ma.step(0.05)
		a.advance_clock(0.05)
	var sd := _events(a, "mech.heat.shutdown")
	var sd_ok := true
	for e: Dictionary in sd:
		sd_ok = sd_ok and str(e["kind"]) == "3d" and str(e["bus"]) == AudioDirector.BUS_SFX_WORLD \
			and (e["pos"] as Vector3).distance_to(at) < 0.5
	check(sd_ok, "%s: overheat power-down (if any) is 3D on the world bus at the mech (%d)" % [label, sd.size()])
	check(not _has_prefix(a, "pilot."), "%s: overheat plays no pilot voice" % label)
	near(a.duck_world_db(), 0.0, 0.05, "%s: overheat does not duck the world" % label)
	m.heat = m.reboot_heat - 1.0
	ma.step(0.05)
	m.rebooted.emit()
	check(not _has_cue(a, "mech.heat.reboot_spool") and not _has_cue(a, "mech.heat.reboot_ok"),
		"%s: no cockpit reboot spool / chime" % label)
	m.heat = 0.0
	a.advance_clock(1.0)
	_take_leaks(a, leaks)
	m.thrusting = true
	m.emergency = true
	ma.step(1.0 / 60.0)
	check(not _has_cue(a, "mech.thrust.emergency"), "%s: no emergency-burn alarm" % label)
	var ign := _events(a, "mech.thrust.ignite")
	check(ign.size() == 1 and str(ign[0]["kind"]) == "3d" and str(ign[0]["bus"]) == AudioDirector.BUS_SFX_WORLD
		and (ign[0]["pos"] as Vector3).distance_to(at) < 0.5, "%s: ignition is 3D on the world bus at the mech" % label)
	var lp := _events(a, "mech.thrust.loop")
	check(lp.size() == 1 and str(lp[0]["bus"]) == AudioDirector.BUS_SFX_WORLD and (lp[0]["pos"] as Vector3).distance_to(at) < 0.5,
		"%s: thruster loop on the world bus at the mech" % label)
	m.thrusting = false
	m.emergency = false
	(m.get_node("Thrusters") as ThrusterFx).level = 0.0
	ma.step(1.0 / 60.0)
	a.advance_clock(1.0)
	_take_leaks(a, leaks)
	m.hard_landing.emit(17.0, 0.85)
	var hl := _events(a, "mech.land.hard")
	check(hl.size() == 1 and str(hl[0]["kind"]) == "3d" and str(hl[0]["bus"]) == AudioDirector.BUS_SFX_WORLD,
		"%s: hard landing is 3D on the world bus" % label)
	check(not _has_prefix(a, "pilot."), "%s: hard landing plays no pilot voice" % label)
	_take_leaks(a, leaks)
	var foot := at + Vector3(1.0, 0.0, 0.5)
	var g := MechSpawn.rig_of(m).gait
	if g != null and m.grounded():
		g.stepped.emit(0, {"kind": "stride", "length": g.step_length, "weight": 1.0, "pos": foot})
		ma.step(1.0 / 60.0)
		var st := _cues_with_prefix(a, "mech.step.")
		check(st.size() == 1 and str(st[0]["kind"]) == "3d" and str(st[0]["bus"]) == AudioDirector.BUS_SFX_WORLD
			and (st[0]["pos"] as Vector3).distance_to(foot) < 0.01, "%s: footfall is 3D on the world bus at the foot" % label)
	else:
		check(false, "%s: grounded with a gait for the footfall check" % label)
	_take_leaks(a, leaks)
	check(leaks.is_empty(), "%s: no cue on 2D / player bus / telegraph bus all along (%s)" % [label, str(leaks)])
	await frames(1)


## Append the recorded cues that are 2D or on SFX_Player / SFX_Telegraph to `leaks`, then clear the recorder.
static func _take_leaks(a: AudioDirector, leaks: Array) -> void:
	for e: Dictionary in a.recent_events:
		if str(e["kind"]) == "2d" or str(e["bus"]) in [AudioDirector.BUS_SFX_PLAYER, AudioDirector.BUS_SFX_TELEGRAPH]:
			leaks.append(str(e["cue"]))
	a.clear_events()


static func _events(a: AudioDirector, cue_id: String) -> Array:
	var out: Array = []
	for ev: Dictionary in a.recent_events:
		if str(ev["cue"]) == cue_id:
			out.append(ev)
	return out


static func _kinds(a: AudioDirector, cue_id: String) -> Array:
	var out: Array = []
	for ev: Dictionary in _events(a, cue_id):
		out.append(str(ev["kind"]))
	return out


static func _cues_with_prefix(a: AudioDirector, prefix: String) -> Array:
	var out: Array = []
	for ev: Dictionary in a.recent_events:
		if str(ev["cue"]).begins_with(prefix):
			out.append(ev)
	return out


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
	var own_fire := _events(a, "wpn.autocannon.fire")
	check(own_fire.size() == 1 and str(own_fire[0]["bus"]) == AudioDirector.BUS_SFX_PLAYER,
		"the local shooter's fire stays on the player bus")
	# A teammate's and a host-run bot's fire: 3D on the world bus at the record's origin.
	for sh: Array in [["player2", 2], ["player-1", 1]]:
		a.advance_clock(0.3)
		a.clear_events()
		var o := Vector3(12, 3, -4)
		world.fire(Combat.fire_record(str(sh[0]), int(sh[1]), "side_r", "autocannon", o, Vector3(12, 3, -30), world.now, 0, 0.0))
		var rf := _events(a, "wpn.autocannon.fire")
		check(rf.size() == 1 and str(rf[0]["kind"]) == "3d" and str(rf[0]["bus"]) == AudioDirector.BUS_SFX_WORLD
			and (rf[0]["pos"] as Vector3).distance_to(o) < 0.01, "%s's fire is 3D on the world bus at its origin" % str(sh[0]))
	a.clear_events()
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
	# A teammate's hit: no hit-confirm in this pilot's ears.
	var dummy2 := TargetDummy.new()
	dummy2.target_id = "dummy_2"
	dummy2.set_max_hp({"torso": 400.0})
	dummy2.position = Vector3(5, 0, -20)
	add_child(dummy2)
	world.register(dummy2)
	ca.step(0.05)
	a.advance_clock(0.5)
	a.clear_events()
	var h2 := Hit.new()
	h2.damage = 10.0
	h2.component = "torso"
	h2.shooter = "player2"
	h2.point = Vector3(5, 2, -20)
	world.deliver(dummy2, h2)
	check(not _has_cue(a, "combat.hit.tick"), "a teammate's hit plays no hit-confirm tick here")
	world.unregister(dummy2)
	dummy2.queue_free()
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
	# Squad hit-confirms carry no shooter: they play (2D, player bus) only for an enemy this pilot just hit.
	var dmg_e1 := {"id": "e1", "component": "core", "hp_ratio": 0.5, "weak_point": true, "pos": Vector3(0, 2, -25)}
	sq.enemy_event.emit("component_damaged", sq, dmg_e1)
	sq.enemy_event.emit("component_destroyed", sq, {"id": "e1", "component": "core", "pos": Vector3(0, 2, -25)})
	ca.step(0.05)
	check(not _has_cue(a, "combat.hit.weak"), "a squad weak-point hit nobody here made plays no hit-confirm")
	check(not _kinds(a, "combat.hit.break").has("2d"), "a squad component break nobody here made plays no 2D break")
	check(_kinds(a, "combat.hit.break").has("3d"), "a squad component break still plays 3D at the enemy")
	var lh := Hit.new()
	lh.shooter = "player1"
	lh.damage = 5.0
	world.remote_hit.emit("e1", lh)   # this machine's shot on a host-owned enemy
	a.advance_clock(0.3)
	sq.enemy_event.emit("component_damaged", sq, dmg_e1)
	check(not _has_cue(a, "combat.hit.weak"), "the squad hit-confirm waits for step()")
	ca.step(0.05)
	check(_has_cue(a, "combat.hit.weak"), "EnemySquad weak_point hit by this pilot plays combat.hit.weak")
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
