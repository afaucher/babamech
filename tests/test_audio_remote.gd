extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Audio for remote events (W8; scripts/audio/combat_audio.gd) over a real crew mission of 2, once per link (off, coast).
## Cues are read from the Audio autoload's recorder (AudioDirector.record_events / recent_events). On the client (B), which
## fired none of them, the host's (A's)
## 1. player fire record (replayed by CombatNet) plays its weapon cue at the record's origin (world bus, not the local
##    player's), and the shell's impact plays an impact cue at the impact point;
## 2. enemy fire record (EnemySync) plays the weapon cue + the enemy accent at its origin;
## 3. repair drone launch (CombatNet "combat.drone") plays the launch cue at the drone, by A's puppet;
## 4. prop_moved from a NON-entry deck's CityProps is heard (CombatAudio binds every deck of the stack).
## Every positional cue is checked against the event's point, and to be away from the listener (the camera).

const PEERS := 2
const SEED := 11
const POS_TOL := 0.05

var td: MissionScene
var world: CombatWorld
var impacts: Array = []            ## [point] on this machine
var drone_launch_pos := Vector3.INF ## where player1's drone was at its launch here


func _audio() -> AudioDirector:
	return get_tree().root.get_node_or_null("Audio") as AudioDirector


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client is ready"):
		return
	var b := _other_peer()
	var m := td.mech
	var up := m.up()
	var fwd := m.forward()
	var side := fwd.cross(up).normalized()

	command(b, "clear", {})
	await wait_reports("cleared", 1, 10.0)
	# 1. Player record + impact.
	var o1 := m.global_position + up * 4.4 + fwd * 3.0
	var r1 := Combat.fire_record("player1", 1, "side_l", "autocannon", o1, m.global_position + fwd * 30.0 - up * 0.5, world.now, 9301, 0.0)
	var n0 := impacts.size()
	world.fire(r1)
	await until(func() -> bool: return impacts.size() > n0, 3.0)
	var imp: Vector3 = impacts[n0] if impacts.size() > n0 else Vector3.INF
	# 2. Enemy record (aimed up and away: it hits nothing).
	var o2 := m.global_position + up * 12.0 - side * 20.0 + fwd * 15.0
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var r2 := Combat.fire_record("enemy_audio", 1, w, w, o2, o2 + up * 40.0 + fwd * 10.0, world.now, 9302, 0.0)
	r2["enemy"] = true
	r2["team"] = "enemy"
	world.fire(r2)
	await sleep(0.3)
	# 3. Drone.
	var d := world.launch_drone({"shooter": "player1", "peer": 1, "hardpoint": "back", "weapon": "repair_drone", "t": world.now})
	await sleep(1.0)
	command(b, "report", {"key": "cues"})
	if check(await wait_reports("cues", 1, 10.0), "B reports its cues"):
		var v: Dictionary = reported(b, "cues")
		var ev: Array = v["events"]
		var cam: Vector3 = v["listener"]
		_cue_at(ev, "wpn.autocannon.fire", o1, cam, "B: A's autocannon at the record origin")
		check(_bus_of(ev, "wpn.autocannon.fire", o1) == AudioDirector.BUS_SFX_WORLD, "on the world bus (not B's own player bus)")
		if check(imp != Vector3.INF, "the shell landed on A"):
			var best := INF
			for e: Dictionary in ev:
				if str(e["cue"]).begins_with("impact.") and str(e["kind"]) != "2d":
					best = minf(best, (e["pos"] as Vector3).distance_to(imp))
			check(best < 0.1, "B: an impact cue at A's impact point (%.3f m)" % best)
		_cue_at(ev, "wpn.%s.fire" % w if SoundBank.has_cue("wpn.%s.fire" % w) else "wpn.autocannon.fire", o2, cam,
			"B: the enemy shot's weapon cue at its origin")
		_cue_at(ev, "enemy.fire.accent", o2, cam, "B: the enemy accent at its origin")
		var dp: Vector3 = v["drone_pos"]
		var best_d := INF
		for e: Dictionary in ev:
			if str(e["cue"]) == "mech.thrust.ignite":
				best_d = minf(best_d, (e["pos"] as Vector3).distance_to(dp))
		check(best_d < 0.5, "B: the drone launch cue at the drone (%.3f m)" % best_d)
		check(bool(v["decks_bound"]), "B: every deck's props are bound (%s)" % str(v["decks_info"]))
		check(bool(v["prop_heard"]), "B: a prop moving on a non-entry deck is heard at its position")
	check(d != null, "A launched a drone")

	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 90.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	_audio().clear_events()
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"clear":
				_audio().clear_events()
				report("cleared", true)
			"report":
				var events := _audio().recent_events.duplicate()
				var info := _decks_info()
				var heard := await _prop_check()
				var cam := get_viewport().get_camera_3d()
				report(str(c["key"]), {"events": events, "drone_pos": drone_launch_pos,
					"listener": cam.global_position if cam != null else Vector3.ZERO, "decks_bound": bool(info["ok"]),
					"decks_info": info, "prop_heard": heard})


## Every deck's CityProps is connected to CombatAudio's prop_moved handler.
func _decks_info() -> Dictionary:
	var st := world.city_stack()
	if st == null:
		return {"ok": false, "why": "no stack"}
	var n := (st.get("decks") as Array).size()
	var bound := 0
	for k in n:
		var pr := world.deck_props(k)
		if pr != null and pr.is_connected("prop_moved", Callable(td.combat_audio, "_on_prop_moved")):
			bound += 1
	return {"ok": n > 1 and bound == n, "decks": n, "bound": bound}


## Emit a prop_moved on a deck other than the entry's, 6 m from this mech: the cue plays there.
func _prop_check() -> bool:
	var st := world.city_stack()
	if st == null:
		return false
	var entry := int(td.stack.section.entry["deck"])
	var n := (st.get("decks") as Array).size()
	var k := (entry + 1) % n
	var pr := world.deck_props(k)
	if pr == null:
		return false
	var at := td.mech.global_position + td.mech.forward() * 6.0 + td.mech.up() * 1.0
	_audio().clear_events()
	pr.emit_signal("prop_moved", 1, "tree", CityPropSim.TOPPLE, at, 3.0)
	await frames(1)
	for e: Dictionary in _audio().recent_events:
		if str(e["cue"]) == "prop.tree.topple" and (e["pos"] as Vector3).distance_to(at) < POS_TOL:
			return true
	return false


func _cue_at(ev: Array, cue: String, at: Vector3, listener: Vector3, msg: String) -> void:
	var best := INF
	for e: Dictionary in ev:
		if str(e["cue"]) == cue and str(e["kind"]) != "2d":
			best = minf(best, (e["pos"] as Vector3).distance_to(at))
	check(best < POS_TOL and at.distance_to(listener) > 1.0, "%s (%.3f m off; %.1f m from the listener)" % [
		msg, best, at.distance_to(listener)])


func _bus_of(ev: Array, cue: String, at: Vector3) -> String:
	for e: Dictionary in ev:
		if str(e["cue"]) == cue and (e["pos"] as Vector3).distance_to(at) < POS_TOL:
			return str(e["bus"])
	return ""


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.combat.net != null and td.combat_audio != null and _audio() != null,
			"the crew mission runs CombatNet and CombatAudio"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	world.drone_launched.connect(func(r: Dictionary, dr: RepairDrone) -> void:
		if str(r.get("shooter", "")) == "player1" and dr != null:
			drone_launch_pos = dr.pos)
	world.impact_spawned.connect(func(pt: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append(pt))
	_audio().record_events = true
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return await until(_puppet_shown, 10.0)


func _puppet_shown() -> bool:
	return td.crew_sync.puppets.size() == peers - 1 and (td.crew_sync.puppets.values()[0] as MechPuppet).shown != null


func _other_peer() -> int:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			return int(e["peer"])
	return -1
