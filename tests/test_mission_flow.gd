extends TestCase
## The mission's objective and end in a SOLO test drive (W6 win side; scripts/game/mission_flow.gd, MissionHud):
## 1. The stack drive builds MissionFlow with MissionRules from its section; while the enemies live, their deck's clear
##    objective is NOT done (evaluation gated until they spawned), the HUD's objective line shows rules.text().
## 2. Downed in solo: auto-respawn as before and no "lost" (no crew-wipe loss for now).
## 3. Killing every enemy turns the objective to "Reach the extraction portal" with an extraction waypoint on the HUD.
## 4. The mech in the extraction zone: "won", the MISSION COMPLETE banner, and END_HOLD later the end flow finishes
##    (MissionFlow.finished; a test's drive isn't the current scene, so no scene change happens here).

var finished_with := ""


func setup() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	add_child(td)
	await frames(4)
	var mf := td.mission
	if not check(mf != null and mf.rules != null and not mf.crew, "the solo stack drive runs a MissionFlow with rules"):
		finish()
		return
	mf.finished.connect(func(o: String) -> void: finished_with = o)
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var rules := mf.rules
	check(td.enemies_spawned, "the enemies spawned")
	var decks: Dictionary = {}
	for e in td.combat.squad.enemies:
		if is_instance_valid(e):
			decks[e.spawn_deck] = true
	check(not decks.is_empty(), "there are enemies (%d)" % td.combat.squad.enemies.size())
	await _seconds(0.8)
	check(mf.evaluations >= 2, "solo evaluates locally (%d)" % mf.evaluations)
	for k: int in decks:
		check(not rules.is_done("clear_%d" % k), "deck %d is not cleared while its enemies live" % k)
	check(rules.text().begins_with("Clear deck"), "the objective is a clear: %s" % rules.text())
	eq(rules.outcome, "", "no outcome yet")
	var hud := td.get_node_or_null("MechHud") as MechHud
	if check(hud != null and hud.mission_hud != null, "the HUD has the mission layer"):
		await frames(2)
		eq(str(hud.mission_hud.state()["objective"]), rules.text(), "the HUD's objective line is rules.text()")
		check(hud.mission_hud.objective_panel.visible, "the objective line shows")
		check(not hud.mission_hud.banner.visible, "no banner yet")

	# 2. Downed: auto-respawn, no loss.
	var pt := td.combat.player_target
	pt.apply_damage(5000.0, "head", "test")
	check(pt.disabled, "the mech is downed")
	check(pt.auto_respawn_delay >= 0.0, "solo keeps the auto-respawn")
	await _seconds(pt.auto_respawn_delay + 1.0)
	check(not pt.disabled, "it respawned")
	eq(rules.outcome, "", "being downed loses nothing")

	# 3. Every enemy down.
	for e in td.combat.squad.enemies.duplicate():   # killing past MAX_WRECKS frees old wrecks from the list
		if is_instance_valid(e) and not e.destroyed():
			# A troop squad is one EnemyBase with a component per trooper: the core hit downs one trooper, so hit until
			# it is destroyed (bounded).
			for _i in 12:
				if e.destroyed():
					break
				e.apply_damage(1.0e7, e.core_component(), "test")
	await _seconds(0.8)
	eq(rules.current(), "extract", "every deck cleared: extraction is the objective")
	eq(rules.text(), "Reach the extraction portal", "the objective line says so")
	var mk := rules.marker()
	if not check(not mk.is_empty(), "the rules give an extraction marker"):
		finish()
		return
	if hud != null:
		await frames(2)
		check(not (hud.mission_hud.state()["waypoint"] as Dictionary).is_empty(), "the HUD has the extraction waypoint")
		var ws := hud.mission_hud.waypoint_screen()
		check(not ws.is_empty() and float(ws["dist"]) > 1.0, "the waypoint is placed on screen with a distance (%s)" % str(ws))

	# 4. Into the zone: won.
	td.mech.global_position = td.stack.from_deck_arc(int(mk["deck"]), float(mk["x"]), float(mk["s"]), 0.5)
	td.mech.velocity = Vector3.ZERO
	await _seconds(0.8)
	eq(rules.outcome, "won", "the mech in the extraction zone wins (%s)" % str(rules.state()))
	if hud != null:
		await frames(2)
		check(hud.mission_hud.banner.visible, "the banner shows")
		eq(str((hud.mission_hud.state()["banner"] as Dictionary).get("title", "")), "MISSION COMPLETE", "it says MISSION COMPLETE")
	check(mf.end_left > 0.0 and not mf.ended, "the banner holds before the end")
	await _seconds(MissionFlow.END_HOLD + 0.5)
	check(mf.ended, "the end flow finished after the hold")
	eq(finished_with, "won", "finished(won)")
	eq(FrontEnd.next_screen, "", "a drive that isn't the current scene doesn't leave")
	td.queue_free()
	await frames(2)
	finish()


func _seconds(s: float) -> void:
	for i in ceili(s * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
