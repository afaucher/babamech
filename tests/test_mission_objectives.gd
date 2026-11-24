extends TestCase
## Mission objectives phase 1 in a SOLO stack drive in plan mode (TestDrive.objectives; scripts/game/mission_flow.gd,
## MissionHud; docs/design/mission-objectives.md §7, §9). Seed 7: deck 1 flag (primary), deck 2 defend, deck 3 defend,
## then the extraction hold (shortened by MissionFlow.test_plan; the director's lull / grace shortened too).
## A. LOST: the crew reaches deck 2's defend (active), the relay's HP goes to 0 -> "lost" / objective_failed, banner
##    MISSION FAILED / Objective failed, mission.end reason "Objective failed".
## B. WON: every enemy killed (direct kills, troop squads hit until destroyed); the mech stands in the deck 1 flag ring:
##    the zone bar shows, progress rises, the flag is raised in the world (MissionWorld.flag_raised) and its alarm wave is
##    ordered: open_source on the world with the order's open_at, the "Reinforcements, ..." line on the HUD. Then each
##    defend (its waves ordered and beaten; nothing spawns while antigravity's spawn_wave is missing, the director counts
##    them beaten after GRACE), then the hold: "won", banner MISSION COMPLETE.

const SEED := 7
const PLAN := {"hold": 6.0}
const DIRECTOR := {"rest_first": 1.5, "rest_last": 1.5, "arrival_rest": 1.0, "grace": 1.5, "follow_gap": 0.5}

var td: TestDrive


func _init() -> void:
	timeout_sec = 300.0


func setup() -> void:
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	await _lost()
	await _won()
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}
	finish()


func _drive() -> MissionFlow:
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = SEED
	td.objectives = true
	add_child(td)
	await frames(4)
	var mf := td.mission
	if not check(mf != null and mf.plan != null and mf.director != null and mf.world != null, "plan mode: plan, director, world"):
		return null
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	return mf


func _lost() -> void:
	var mf := await _drive()
	if mf == null:
		return
	var p := mf.plan.primary(1)
	eq(str(p.get("type", "")), "defend", "seed 7: deck 2's primary is a defend")
	_kill_all()
	await _go_to(p)
	if not check(await _until(func() -> bool: return mf.rules.obj_state(p["id"]) == "active", 5.0), "the defend is active"):
		return
	mf.set_asset_hp(p["id"], 0.0)
	if not check(await _until(func() -> bool: return mf.rules.outcome != "", 3.0), "an outcome after the relay is destroyed"):
		return
	eq(mf.rules.outcome, "lost", "the failed primary loses the mission")
	eq(mf.rules.reason, "objective_failed", "reason objective_failed")
	eq(mf.rules.text(), "Objective failed", "the objective line says so")
	var hs := mf.hud_state()
	eq(str(hs["banner"].get("title", "")), "MISSION FAILED", "banner MISSION FAILED")
	eq(str(hs["banner"].get("reason", "")), "Objective failed", "banner reason Objective failed")
	eq(mf.end_reason(), "Objective failed", "mission.end would say Objective failed")
	await _seconds(0.5)
	eq(MissionWorld.asset_level(float(mf.world._asset_hp.get(p["id"], 1.0))), 2, "the world shows the relay wrecked")
	td.queue_free()
	await frames(3)


func _won() -> void:
	var mf := await _drive()
	if mf == null:
		return
	var rules := mf.rules
	check(td.mission_checksum().ends_with("/" + mf.plan.checksum()), "the barrier checksum joins the plan's")
	eq(rules.text(), "Raise the flag: 0%", "the headline is deck 1's flag")
	var hud := td.get_node_or_null("MechHud") as MechHud
	var gar := _garrison()
	print("objectives: garrison per deck at the start %s (share %s)" % [str(gar), str(mf.plan.pool(0)["garrison"])])
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave != "":
			check(false, "only the garrison stands at the start (%s has wave %s)" % [e.name, e.wave])
			break
	check(int(gar[0]) > 0, "deck 1 has a garrison")
	_kill_all()
	await _seconds(0.6)

	# Deck 1: the flag ----------------------------------------------------------------------------------------------
	var flag := mf.plan.primary(0)
	await _go_to(flag)
	if not check(await _until(func() -> bool: return rules.obj_progress(flag["id"]) >= 2.0, 8.0), "flag progress rises in the ring"):
		return
	if hud != null:
		var hs := hud.mission_hud.state()
		check(bool(hs.get("plan", false)), "the HUD is in plan mode")
		check(hud.mission_hud.list_panel.visible, "the objective list shows")
		check((hs.get("lines", []) as Array).size() >= 1 and str(hs["lines"][0]).begins_with("Raise the flag"),
			"the first line is the flag (%s)" % str(hs.get("lines", [])))
		check(hud.mission_hud.zone_panel.visible and str(hs["zone"].get("label", "")) == "RAISING THE FLAG", "the zone bar shows")
	eq(str(mf._pushed.get("zone:" + flag["id"], "")), "ours", "the world's flag ring is ours")
	# The capture brings its wave at once (step start, playtest 2026-11-23): ordered while the flag is still rising.
	var wid := ""
	var fid := ""
	for w: Dictionary in mf.plan.pool(0)["reserve"]:
		if str(w["for"]) == str(flag["id"]):
			fid = str(w["id"])
	var fo := {}
	for o0: Dictionary in mf.opened:
		if str(o0["wave"]) == fid:
			fo = o0
	if check(not fo.is_empty() and rules.obj_state(flag["id"]) == "active", "the flag's group (%s) is ordered when the capture starts (orders %s)" % [fid, str(mf.opened)]):
		var o: Dictionary = fo
		wid = str(o["wave"])
		var src := mf.plan.source(o["source"])
		var fs: Dictionary = rules.objective(flag["id"])["site"]
		var sd := Vector2(float(src["x"]), float(src["s"])).distance_to(Vector2(float(fs["x"]), float(fs["s"])))
		print("objectives: flag wave %s from %s, %.0f m from the flag site" % [wid, o["source"], sd])
		check(sd >= PacingDirector.MIN_SOURCE_DIST, "its source is >= 60 m from the (snapped) flag site (%.0f m)" % sd)
		if str(src.get("kind", "")) in ["gate", "lift"]:
			near(float(mf.world.source_state(o["source"])["open_at"]), float(o["open_at"]), 0.001, "the door opens at the order's open_at")
		if hud != null:
			await frames(2)
			check(hud.mission_hud.alert_panel.visible, "the reinforcement line shows")
			var al: Array = hud.mission_hud.state().get("alerts", [])
			check(not al.is_empty() and str(al[-1]["text"]).begins_with("Reinforcements, "), "it names the source (%s)" % str(al))
		# The wave really arrives at its door while the crew holds the flag (antigravity's EnemySpawner.spawn_wave).
		if check(await _until(func() -> bool: return _wave_units(wid) > 0, float(o["open_at"]) - mf.now() + 4.0),
				"wave %s spawned at its door" % wid):
			print("objectives: wave %s arrived with %d units during the capture" % [wid, _wave_units(wid)])
		check(mf.unspawned.is_empty(), "no wave fell back to the stub (%s)" % str(mf.unspawned))
	if not check(await _until(func() -> bool: return rules.obj_state(flag["id"]) == "done", 30.0, true), "the flag is raised"):
		return
	await _seconds(0.5)
	check(mf.world.flag_raised(flag["id"]), "the world raised the flag")
	if wid != "":
		check(mf.director.status(wid) == "released", "the flag's wave stays delivered after the capture")


	# Decks 2 and 3: the defends -------------------------------------------------------------------------------------
	for k in [1, 2]:
		var d := mf.plan.primary(k)
		await _go_to(d)
		if not check(await _until(func() -> bool: return rules.obj_state(d["id"]) == "done", 90.0, true),
				"deck %d's defend is done (%s, waves %s)" % [k + 1, rules.obj_state(d["id"]), str(mf.director.objective_waves().get(d["id"], {}))]):
			return
	var wv: Array = mf.director.state()["waves"]
	check(int(wv[1][0]) >= 2, "deck 2 released its waves (%s)" % str(wv))

	# The hold -----------------------------------------------------------------------------------------------------
	var h := mf.plan.objective("hold")
	var c: Vector2 = (h["params"]["zone"] as Rect2).get_center()
	td.mech.global_position = td.stack.from_deck_arc(int(h["deck"]), c.x, c.y, 0.5)
	td.mech.velocity = Vector3.ZERO
	if not check(await _until(func() -> bool: return rules.outcome != "", 30.0, true), "the hold ends the mission"):
		return
	eq(rules.outcome, "won", "won (%s)" % str(rules.state()))
	await _seconds(0.3)
	eq(str(mf.hud_state()["banner"].get("title", "")), "MISSION COMPLETE", "banner MISSION COMPLETE")
	check(float(mf.world.portal_progress) >= 0.99, "the portal is fully charged")
	print("objectives: %d wave orders, unspawned (stub) %s" % [mf.opened.size(), str(mf.unspawned)])
	var order := {"wave": "d1_w2", "deck": 1, "source": "d1_gate_s0_1", "open_at": 1234.56, "max_units": 8}
	print("objectives: sizes (var_to_bytes) mission.state %d B, mission.wave order %d B, JSON state %d chars" % [
		var_to_bytes(mf.plan_state()).size(), var_to_bytes({"order": order}).size(), JSON.stringify(mf.plan_state()).length()])
	td.queue_free()
	await frames(3)


func _go_to(o: Dictionary) -> void:
	var site: Dictionary = td.mission.rules.objective(o["id"])["site"]
	td.mech.global_position = td.stack.from_deck_arc(int(o["deck"]), float(site["x"]), float(site["s"]), 0.5)
	td.mech.velocity = Vector3.ZERO
	await _seconds(0.3)


func _wave_units(id: String) -> int:
	var n := 0
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave == id:
			n += 1
	return n


func _garrison() -> Array:
	var out := [0, 0, 0]
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave == "" and e.spawn_deck < out.size():
			out[e.spawn_deck] += 1
	return out


func _kill_all() -> void:
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


## Wait up to `s` mission seconds for `f`; `kill` keeps the decks empty meanwhile (anything a wave spawns).
func _until(f: Callable, s: float, kill: bool = false) -> bool:
	for i in ceili(s * Engine.physics_ticks_per_second):
		if f.call():
			return true
		if kill and i % 30 == 0:
			_kill_all()
		await get_tree().physics_frame
	return f.call()


func _seconds(s: float) -> void:
	for i in ceili(s * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
