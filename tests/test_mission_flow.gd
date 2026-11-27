extends TestCase
## The mission's objectives and end in a SOLO test drive, in the one mission mode (objectives: user 2026-11-25 "Cut the
## legacy modes."; scripts/game/mission_flow.gd, MissionHud). A forced all-sweep plan without reserve waves (PLAN: the
## closest to the old "clear every deck", fast) so the flow itself is what is tested:
## 1. The stack drive builds MissionFlow with the plan's MissionRules (no legacy rules); while the enemies live, the
##    current deck's sweep is NOT done (evaluation gated until they spawned), the HUD's objective panel shows its lines.
## 2. Downed in solo: no automatic respawn, no "lost" (wipe off); held SPACE respawns it (DownedRules).
## 3. Killing every enemy and standing on each deck finishes every sweep; the extraction hold becomes the objective,
##    with an EXTRACT waypoint on the HUD.
## 4. The mech in the hold zone for the hold: "won", the MISSION COMPLETE banner with the objectives' reason, and
##    END_HOLD later the end flow finishes (MissionFlow.finished; a test's drive isn't the current scene: no scene change).

const PLAN := {"primary": "sweep", "bonus_max": 0, "waves_per_deck": 0, "hold": 3.0}

var finished_with := ""


## The crew scale is the HOST's (AGENTS.md rule 8; user 2026-11-25 "Run it from the host, enforce this!"): the host derives
## it (host_crew_scale: the launch crew with its hangar bots; on a retire the members still in the crew); every machine
## reads crew_scale(), which a client takes from the launch params' `scale`, never from its own crew list (here: a
## launch crew of 3, its spawn_order 3 too, the host's scale 2 -> 2). Solo: 1. Changes are scheduled by `at`: a duplicate
## or late copy is ignored, a state's "scale" schedules like the message.
func _crew_scale() -> void:
	eq(MissionFlow.host_crew_scale([{"peer": 1}, {"peer": -1, "bot": true}, {"peer": 2}]), 3, "host: the launch crew of 3 (a bot counts)")
	eq(MissionFlow.host_crew_scale([1, 2, 3, 4, 5]), 4, "host: at most 4")
	eq(MissionFlow.host_crew_scale([]), 1, "host: at least 1")
	var crew3 := [{"peer": 1}, {"peer": 2}, {"peer": 3}]
	eq(MissionFlow.launch_scale({"crew": crew3, "scale": 2}), 2, "a launch's scale is the host's value, not its crew list's size")
	eq(MissionFlow.launch_scale({}), 1, "no launch (solo): 1")
	eq(NetMission.launch_scale(crew3), 3, "the host's launch asks MissionFlow.host_crew_scale (the one rule)")
	var td := MissionScene.new()
	td.crewed = true
	td.spawn_order = [1, 2, 3] as Array[int]   # this client's own view of the launch: 3 pilots
	var mf := MissionFlow.new()
	mf.drive = td
	mf.crew = true
	mf.init_scale({"crew": crew3, "scale": 2})
	eq(mf.crew_scale(), 2, "client: crew_scale() is the host's 2 (its spawn_order and crew list say 3)")
	near(mf.asset_max_hp(), MissionFlow.ASSET_MAX_HP * float(MissionFlow.ASSET_HP_SCALE[1]), 0.01, "the relay's HP reads it")
	mf.on_member_retired(2)
	eq(mf.crew_scale(), 2, "on_member_retired is a no-op off the host")
	mf.crew = false
	mf.init_scale({"crew": crew3, "scale": 2})
	eq(mf.crew_scale(), 1, "solo: 1 whatever the params")
	# The schedule (solo clock: now() = 0 until released).
	mf.receive_scale({"n": 3, "at": 0.0, "reason": "leave", "pilot": 5})
	eq(mf.crew_scale(), 1, "a change waits for _tick_scale")
	mf._tick_scale()
	eq(mf.crew_scale(), 3, "applied once its `at` has come (going up: accepted, warned)")
	eq(mf.scale_log.size(), 1, "logged once")
	if not mf.scale_log.is_empty():
		eq([int(mf.scale_log[0]["from"]), int(mf.scale_log[0]["to"]), str(mf.scale_log[0]["reason"]), int(mf.scale_log[0]["pilot"])],
			[1, 3, "leave", 5], "the log has from, to, reason, pilot")
	mf.receive_scale({"n": 2, "at": 0.0})
	mf.receive_scale({"n": 2, "at": -1.0})
	mf._tick_scale()
	eq(mf.crew_scale(), 3, "a duplicate (same at) and a late copy (older at) are ignored")
	eq(mf.scale_dups, 2, "both counted")
	mf.receive_scale({"n": 2, "at": 5.0})
	mf._tick_scale()
	eq(mf.crew_scale(), 3, "a change ahead on the clock waits")
	eq(mf.scale_state(), [2, 5.0], "the state carries the newest decision [n, at]")
	var wire: Variant = JSON.parse_string(JSON.stringify({"scale": mf.scale_state()}))
	var c := MissionFlow.new()
	c.drive = td
	c.crew = false
	c.init_scale({})
	c.apply_scale_state(wire["scale"])
	c._clock = 5.0
	c._tick_scale()
	eq(c.crew_scale(), 2, "a state's scale (through JSON) is applied at its `at`")
	eq(c.scale_dups, 0, "the state's copy is never counted as a duplicate")
	near(float(c.scale_at), 5.0, 1e-6, "applied at the host's at")
	c.apply_scale_state(wire["scale"])
	eq(c.scale_dups, 0, "the same state again: ignored silently")
	c.free()
	mf.free()
	td.free()
	# No reader left that sizes from a local count: the old launch-crew path is gone from MissionFlow and MissionDepots.
	for path: String in ["res://scripts/game/mission_flow.gd", "res://scripts/game/mission_depots.gd"]:
		var src := FileAccess.get_file_as_string(path)
		check(not src.contains("crew_size(") and not src.contains("launch_crew(") and not src.contains("spawn_order.size()"),
			"%s reads no local crew count (crew_size / launch_crew / spawn_order)" % path.get_file())




func setup() -> void:
	_crew_scale()
	MissionFlow.test_plan = PLAN
	await _flow()
	MissionFlow.test_plan = {}
	finish()


func _flow() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	add_child(td)
	await frames(4)
	var mf := td.mission
	if not check(mf != null and mf.rules != null and mf.plan != null and not mf.crew, "the solo stack drive runs the plan"):
		return
	check(mf.rules != null and mf.rules.plan != null, "the plan's rules")
	mf.finished.connect(func(o: String) -> void: finished_with = o)
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var rules := mf.rules
	var types: Array = []
	for k in mf.plan.deck_count:
		types.append(str(mf.plan.primary(k)["type"]))
	print("[Test] primaries %s" % str(types))
	check(not types.has("defend"), "the forced plan has no defend primary (%s)" % str(types))
	check(td.enemies_spawned, "the enemies spawned")
	var decks: Dictionary = {}
	for e in td.combat.squad.enemies:
		if is_instance_valid(e):
			decks[e.spawn_deck] = true
	check(not decks.is_empty(), "there are enemies (%d)" % td.combat.squad.enemies.size())
	await _seconds(0.8)
	check(mf.evaluations >= 2, "solo evaluates locally (%d)" % mf.evaluations)
	var first: Dictionary = mf.plan.primary(0)
	check(rules.obj_state(str(first["id"])) != "done", "deck 1's primary is not done while its enemies live")
	eq(rules.outcome, "", "no outcome yet")
	var hud := td.get_node_or_null("MechHud") as MechHud
	if check(hud != null and hud.mission_hud != null, "the HUD has the mission layer"):
		await frames(2)
		eq(str(hud.mission_hud.state()["objective"]), rules.text(), "the HUD's objective is rules.text()")
		check(hud.mission_hud.list_panel.visible, "the objective panel (top right) shows")
		check(not hud.mission_hud.shown_lines().is_empty(), "the objective panel has lines (%s)" % str(hud.mission_hud.shown_lines()))
		check(not hud.mission_hud.banner.visible, "no banner yet")

	# 2. Downed (DownedRules, user decision 2026-11-24): no automatic respawn, no loss; holding the respawn key brings
	# it back after the hold + the redeploy penalty.
	var pt := td.combat.player_target
	pt.apply_damage(5000.0, "head", "test")
	check(pt.disabled, "the mech is downed")
	check(pt.auto_respawn_delay < 0.0, "no automatic respawn")
	await _seconds(2.0)
	check(pt.disabled, "still downed 2 s later")
	eq(rules.outcome, "", "being downed loses nothing")
	pt.respawn_held = true
	await _seconds(DownedRules.RESPAWN_HOLD + 0.2)
	pt.respawn_held = false
	await _seconds(DownedRules.RESPAWN_PENALTY + 0.3)
	check(not pt.disabled, "it respawned after the hold and the penalty")
	eq(rules.outcome, "", "still nothing lost")

	# 3. Every enemy down, then every deck's primary on its deck.
	for e in td.combat.squad.enemies.duplicate():   # killing past MAX_WRECKS frees old wrecks from the list
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")
	for k in mf.plan.deck_count:
		var o: Dictionary = mf.plan.primary(k)
		var id := str(o["id"])
		var t0 := mf.now()
		while rules.obj_state(id) != "done" and mf.now() < t0 + 40.0:
			_place(td, mf, o)
			_kill_all(td)
			await _seconds(0.1)
		if not check(rules.obj_state(id) == "done", "%s (%s, deck %d) done (state %s)" % [id, o["type"], k + 1, rules.obj_state(id)]):
			return
	await _seconds(0.5)
	eq(rules.current(), "hold", "every primary done: the extraction hold is the objective")
	check(rules.text().begins_with("Hold the extraction portal"), "the objective line says so (%s)" % rules.text())
	var mk := rules.marker()
	if not check(not mk.is_empty(), "the rules give the hold's marker"):
		return
	if hud != null:
		await frames(2)
		var wp: Dictionary = hud.mission_hud.state()["waypoint"]
		eq(str(wp.get("label", "")), "EXTRACT", "the HUD has the EXTRACT waypoint")

	# 4. Into the hold zone for the hold: won.
	var hold: Dictionary = mf.plan.objective("hold")
	var t1 := mf.now()
	while rules.outcome == "" and mf.now() < t1 + float(PLAN["hold"]) + 10.0:
		_place(td, mf, hold)
		_kill_all(td)
		await _seconds(0.1)
	eq(rules.outcome, "won", "holding the portal wins (%s)" % str(rules.state()))
	var hs := mf.hud_model.build()
	eq(str((hs["banner"] as Dictionary).get("reason", "")), MissionHudModel.REASONS["objectives"], "the objectives' reason")
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


## Stand the mech on objective o (a sweep: its deck's arrival; a flag: its site; the hold: its zone's centre).
func _place(td: MissionScene, mf: MissionFlow, o: Dictionary) -> void:
	var k := int(o["deck"])
	var ro := mf.rules.objective(o["id"])
	var at := Vector2(float(ro["site"]["x"]), float(ro["site"]["s"]))
	if str(o["type"]) == "hold":
		at = (ro["zone"] as Rect2).get_center()
	elif str(o["type"]) == "sweep":
		var arr: Dictionary = SectionEncounters.arrival(td.stack.section, k)
		at = Vector2(float(arr["x"]), float(arr["s"]))
	var here := td.stack.to_deck_arc(td.mech.global_position)
	if int(here["deck"]) != k or Vector2(float(here["x"]), float(here["s"])).distance_to(at) > 5.0:
		td.mech.global_position = td.stack.from_deck_arc(k, at.x, at.y, 0.5)
		td.mech.velocity = Vector3.ZERO


func _kill_all(td: MissionScene) -> void:
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


func _seconds(s: float) -> void:
	for i in ceili(s * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
