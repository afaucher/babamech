extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Two chassis in one crew (host + 1 client, once per link): the host flies a Strider, the client joins in one (the
## handshake's default) and switches to a Bulwark with its own loadout in the hangar (sys.profile): the host's roster and
## the client's own copy of it show the change. Then the crew launches; on EVERY machine each crew member's mech has the
## right chassis (controller movement numbers, collision capsule, model), the same loadout as on its owner's machine, and
## the other machine's mech is a puppet. Both owners drive the same script (walk, side-step, turn in place, walk back,
## stand) and the host judges every puppet at its render time against where its owner really was then (NetSnap's
## tolerances), so the slow wide Bulwark's snapshots track like the Strider's. Nothing new is streamed: the chassis rides
## the crew entry, each machine builds the same mech from it (MechSpawn.make -> MechController.apply_chassis).

const PEERS := 2
const SEED := 11
const TOL := {"off": 0.5, "coast": 0.8}   ## m, as net_snap_case.gd
const YAW_TOL := 0.12
const END_TOL := 0.3
const SCRIPT_END := 5.0
const RECORD_END := 5.8
## The client's Bulwark loadout (not its default: the side guns take a shoulder weapon, the back two items).
const BULWARK_LOADOUT := {"side_l": "rockets", "side_r": "autocannon", "back_l": "mortar", "back_r": "ammo_bin"}
const SNAP := preload("res://tests/net_snap_case.gd")

var td: TestDrive
var _t0 := 0.0


func run_host() -> void:
	net_timeout = 85.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	var client := 0
	for p: int in Session.roster:
		if p != 1:
			client = p
	var want := MechCatalog.sanitize_loadout("bulwark", BULWARK_LOADOUT)
	check(await until(func() -> bool: return str(Session.roster[client].get("chassis", "")) == "bulwark", 20.0),
		"the client's switch to the Bulwark reaches the host's roster")
	eq(NetTest.loadout_signature(Session.roster[client].get("loadout", {}) as Dictionary), NetTest.loadout_signature(want),
		"with the client's Bulwark loadout")
	eq(str(Session.roster[1]["chassis"]), "strider", "the host stays in a Strider")
	if not check(await wait_reports("roster", 1, 20.0), "the client sees its change in the roster"):
		return
	eq(str(reported(client, "roster")), "bulwark", "the client's own roster copy shows its Bulwark")
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var mine := await _drive_and_record()
	if not check(await wait_reports("run", 1, 40.0), "the client reports its run"):
		return
	var all := {Session.local_id(): mine, client: reported(client, "run")}
	_judge(all, client)
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 85.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	eq(Session.local_chassis(), NetSession.DEFAULT_CHASSIS, "joined in the default chassis")
	# The hangar switch (FrontEnd._set_chassis does this): the new chassis and its loadout, sent as sys.profile.
	Session.set_profile(Session.player_name, Session.local_head(), "bulwark", Session.local_accent(),
		MechCatalog.sanitize_loadout("bulwark", BULWARK_LOADOUT))
	await until(func() -> bool: return str(Session.local_entry().get("chassis", "")) == "bulwark", 15.0)
	report("roster", str(Session.local_entry().get("chassis", "")))
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("run", await _drive_and_record())


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null, "the test drive runs the crew mission"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	return check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
		"the load barrier passes")


## What this machine built for every crew member: {peer: [controller chassis, model chassis, loadout, walk speed,
## capsule radius, step-up, puppet]}.
func _mechs() -> Dictionary:
	var out := {}
	for p: int in td.mechs:
		var m: MechController = td.mechs[p]
		var model := MechSpawn.rig_of(m).model
		var cap := (m.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
		out[str(p)] = [m.chassis_id, model.chassis_id, NetTest.loadout_signature(model.loadout), m.walk_speed, cap.radius,
			snappedf(m.max_step_up, 0.001), m.puppet]
	return out


func _drive_and_record() -> Dictionary:
	td.drive_override = true
	var m := td.mech
	_t0 = Session.host_time()
	var own := PackedFloat32Array()
	var obs := {}
	var last_own := -1.0
	var last_obs := {}
	td.combat.player_target.auto_respawn_delay = -1.0
	while true:
		var e := Session.host_time() - _t0
		if e > RECORD_END:
			break
		var mv := Vector2.ZERO
		var turn := 0.0
		if e < 1.8:
			mv = Vector2(0, 1)
		elif e < 2.8:
			mv = Vector2(1, 0)          # the Bulwark side-steps
		elif e < 3.8:
			turn = 1.0
		elif e < 4.6:
			mv = Vector2(0, -1)
		m.move_input = mv if e < SCRIPT_END else Vector2.ZERO
		m.turn_input = turn
		m.running = false
		m.thrust_input = false
		m.heat = 0.0
		var fed: NetMechState = Session.mechs.local_state()
		if fed != null and fed.t > last_own:
			last_own = fed.t
			own.append_array([fed.t - _t0, fed.pos.x, fed.pos.y, fed.pos.z, fed.yaw])
		for p: int in td.crew_sync.puppets:
			var pp: MechPuppet = td.crew_sync.puppets[p]
			if pp.shown == null or pp.shown.t <= float(last_obs.get(p, -1e9)):
				continue
			last_obs[p] = pp.shown.t
			if not obs.has(p):
				obs[p] = []
			var at := pp.mech.global_position
			(obs[p] as Array).append_array([pp.shown.t - _t0, at.x, at.y, at.z, CrewSync.heading_of(pp.mech.ring, at, pp.mech.forward())])
		await get_tree().physics_frame
	var obs_s := {}
	for p: int in obs:
		obs_s[str(p)] = PackedFloat32Array(obs[p] as Array)
	return {"own": own, "obs": obs_s, "mechs": _mechs(), "me": Session.local_id()}


func _judge(all: Dictionary, client: int) -> void:
	var expect := {"1": "strider", str(client): "bulwark"}
	var tol: float = TOL.get(link, TOL["coast"])
	for viewer: int in all:
		var r: Dictionary = all[viewer]
		var ms: Dictionary = r["mechs"]
		eq(ms.size(), peers, "peer %d built one mech per crew member" % viewer)
		for ps: String in expect:
			var mine: Array = (all[int(ps)] as Dictionary)["mechs"][ps]   # the owner's own mech
			var seen: Array = ms.get(ps, [])
			if not check(seen.size() == 7, "peer %d built peer %s's mech" % [viewer, ps]):
				continue
			print("[chassis] peer %d sees peer %s: %s" % [viewer, ps, str(seen)])
			eq(str(seen[0]), expect[ps], "peer %d: peer %s's controller is a %s" % [viewer, ps, expect[ps]])
			eq(str(seen[1]), expect[ps], "peer %d: peer %s's model is a %s" % [viewer, ps, expect[ps]])
			eq(str(seen[2]), str(mine[2]), "peer %d: peer %s's loadout is its owner's" % [viewer, ps])
			near(float(seen[3]), float(MechCatalog.movement(expect[ps])["walk_speed"]), 1e-6, "peer %d: peer %s's movement numbers" % [viewer, ps])
			near(float(seen[4]), float(MechCatalog.movement(expect[ps])["capsule_radius"]), 1e-6, "peer %d: peer %s's capsule" % [viewer, ps])
			near(float(seen[5]), float(mine[5]), 1e-3, "peer %d: peer %s's step-up is its owner's" % [viewer, ps])
			eq(bool(seen[6]), int(ps) != viewer, "peer %d: peer %s's mech is %s" % [viewer, ps, "a puppet" if int(ps) != viewer else "its own"])
		for ps: String in r["obs"]:
			var owner := int(ps)
			if not all.has(owner):
				continue
			var own: PackedFloat32Array = (all[owner] as Dictionary)["own"]
			var ob: PackedFloat32Array = (r["obs"] as Dictionary)[ps]
			var n := ob.size() / 5
			var worst := 0.0
			var sum := 0.0
			var count := 0
			var worst_yaw := 0.0
			for i in n:
				var o := SNAP._owner_at(own, ob[i * 5])
				if o.is_empty():
					continue
				var d := Vector3(ob[i * 5 + 1], ob[i * 5 + 2], ob[i * 5 + 3]).distance_to(o[0])
				worst = maxf(worst, d)
				sum += d
				count += 1
				worst_yaw = maxf(worst_yaw, absf(angle_difference(ob[i * 5 + 4], float(o[1]))))
			var on := own.size() / 5
			var end_err := INF
			if n > 0 and on > 0:
				end_err = Vector3(ob[(n - 1) * 5 + 1], ob[(n - 1) * 5 + 2], ob[(n - 1) * 5 + 3]).distance_to(
					Vector3(own[(on - 1) * 5 + 1], own[(on - 1) * 5 + 2], own[(on - 1) * 5 + 3]))
			var mean := sum / maxf(count, 1)
			print("[chassis] link %s: peer %d sees peer %d (%s): %d samples, max %.3f m mean %.3f m, yaw %.3f rad, end %.3f m" % [
				link, viewer, owner, expect.get(ps, "?"), count, worst, mean, worst_yaw, end_err])
			check(count > 120, "peer %d showed peer %d's puppet through the drive (%d samples)" % [viewer, owner, count])
			check(worst < tol, "peer %d's puppet of peer %d within %.2f m at render time (max %.3f)" % [viewer, owner, tol, worst])
			check(mean < tol * 0.25, "peer %d's puppet of peer %d: mean %.3f m" % [viewer, owner, mean])
			check(worst_yaw < YAW_TOL, "peer %d's puppet of peer %d faces its owner's way (%.3f rad)" % [viewer, owner, worst_yaw])
			check(end_err < END_TOL, "peer %d's puppet of peer %d ends at its owner's spot (%.3f m)" % [viewer, owner, end_err])
