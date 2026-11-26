extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Heat shutdown parks the weapons on every machine (weapons.md §4.7), over a crew of 2, once per link. Every machine aims
## its own mech's weapons off to the side (manual aim), overheats at SHUT_T while its aim point keeps sweeping, and is
## rebooted (test only) at REBOOT_T. Each machine records its own streamed mount aims (CrewSync.mount_aims) and what its
## puppet of the other shows (MechPuppet.shown.mount_aim, at render time). The host judges:
## - before the shutdown a barrel turns off-centre (owner and puppet);
## - in the parked window every tracking mount is at WeaponMount.park_pose (0, -12) within MOUNT_TOL (owner's streamed
##   angles and the puppet's), a non-tracking slot stays (0, 0), although the aim keeps moving;
## - after the reboot a barrel turns off-centre again (puppet).

const PEERS := 2
const SEED := 11
const SHUT_T := 1.5                ## s after mission_go: overheat
const PARKED_FROM := 3.6           ## s: render time from which every barrel must be parked (limp 40 deg/s + delay)
const REBOOT_T := 5.0              ## s: reboot (owner time)
const TRACK_FROM := 6.0            ## s: render time by which the puppet tracks again
const END_T := 6.8
const MOUNT_TOL := 1.6             ## deg: one NetMechCodec.MOUNT_UNIT step plus rounding

var td: TestDrive


func run_host() -> void:
	net_timeout = 70.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0),
			"the crew gathers (%d of %d)" % [Session.roster.size(), peers]):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var mine := await _run()
	if not check(await wait_reports("shut", peers - 1, 40.0), "the client reports"):
		return
	var all := {Session.local_id(): mine}
	for p in peers_with("shut"):
		all[p] = reported(p, "shut")
	_judge(all)
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 70.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("shut", await _run())


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null, "the test drive runs the crew mission with mech snapshots"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	return check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
		"the load barrier passes (phase %s)" % Session.mission.phase)


## Classify a 10-value mount_aim: [max |yaw|, every pair parked (park_pose) or at rest (0, 0) within MOUNT_TOL, any parked].
static func _classify(a: PackedFloat32Array) -> Array:
	var mx := 0.0
	var ok := true
	var any := false
	for i in a.size() / 2:
		var yp := Vector2(a[i * 2], a[i * 2 + 1])
		mx = maxf(mx, absf(yp.x))
		var parked := yp.distance_to(Vector2(WeaponMount.PARK_YAW, WeaponMount.PARK_PITCH)) <= MOUNT_TOL
		any = any or parked
		ok = ok and (parked or yp.length() <= 1e-3)
	return [mx, ok, any]


func _run() -> Dictionary:
	td.drive_override = true
	var m := td.mech
	var rack := td.combat.rack
	rack.manual_aim = true
	td.combat.player_target.auto_respawn_delay = -1.0
	var t0 := Session.host_time()
	var sgn := -1.0 if index % 2 == 0 else 1.0
	var shut := false
	var rebooted := false
	var r := {"own_pre": 0.0, "own_park_ok": true, "own_park_n": 0, "own_park_any": false, "pup_pre": 0.0,
		"pup_park_ok": true, "pup_park_n": 0, "pup_park_any": false, "pup_post": 0.0, "pup_shut": false, "worst": ""}
	var last_t := -1e9
	while true:
		var e := Session.host_time() - t0
		if e > END_T:
			break
		m.move_input = Vector2.ZERO
		var right := m.global_basis.x
		var sweep := sin(e * 3.0) * 20.0 if shut and not rebooted else 0.0      # the aim keeps moving while shut down
		rack.aim_point = m.global_position + m.up() * 4.0 + m.forward() * 30.0 + right * (30.0 * sgn + sweep)
		if e >= SHUT_T and not shut:
			shut = true
			m.add_heat(m.heat_cap)
		if shut and not rebooted and m.heat < m.heat_cap:
			m.add_heat(m.heat_cap)          # keep it shut down until REBOOT_T (no early reboot from cooling)
		if e >= REBOOT_T and not rebooted:
			rebooted = true
			m.heat = 0.0                    # test only: reboot now
			m.shutdown = false
		var own := _classify(CrewSync.mount_aims(rack))
		if e < SHUT_T:
			r["own_pre"] = maxf(float(r["own_pre"]), float(own[0]))
		elif e >= PARKED_FROM - 0.3 and e < REBOOT_T:
			r["own_park_n"] = int(r["own_park_n"]) + 1
			r["own_park_ok"] = bool(r["own_park_ok"]) and bool(own[1])
			r["own_park_any"] = bool(r["own_park_any"]) or bool(own[2])
		for p: int in td.crew_sync.puppets:
			var pp: MechPuppet = td.crew_sync.puppets[p]
			if pp.shown == null or pp.shown.t <= last_t:
				continue
			last_t = pp.shown.t
			var rt := pp.shown.t - t0
			var c := _classify(pp.shown.mount_aim)
			r["pup_shut"] = bool(r["pup_shut"]) or pp.mech.shutdown
			if rt < SHUT_T:
				r["pup_pre"] = maxf(float(r["pup_pre"]), float(c[0]))
			elif rt >= PARKED_FROM and rt < REBOOT_T - 0.15:     # (render time is interpolated across the reboot edge)
				r["pup_park_n"] = int(r["pup_park_n"]) + 1
				r["pup_park_any"] = bool(r["pup_park_any"]) or bool(c[2])
				if not bool(c[1]):
					r["pup_park_ok"] = false
					r["worst"] = "t %.2f %s" % [rt, str(pp.shown.mount_aim)]
			elif rt >= TRACK_FROM:
				r["pup_post"] = maxf(float(r["pup_post"]), float(c[0]))
		await get_tree().physics_frame
	return r


func _judge(all: Dictionary) -> void:
	for viewer: int in all:
		var r: Dictionary = all[viewer]
		print("[shut] link %s peer %d: %s" % [link, viewer, str(r)])
		check(float(r["own_pre"]) > 5.0, "peer %d's own barrels track off-centre before the shutdown (%.1f deg)" % [viewer, float(r["own_pre"])])
		check(int(r["own_park_n"]) > 20 and bool(r["own_park_ok"]) and bool(r["own_park_any"]),
			"peer %d streams the parked angles while shut down (%d samples)" % [viewer, int(r["own_park_n"])])
		check(bool(r["pup_shut"]), "peer %d sees the other's shutdown" % viewer)
		check(float(r["pup_pre"]) > 5.0, "peer %d's puppet barrels track off-centre before the shutdown (%.1f deg)" % [viewer, float(r["pup_pre"])])
		check(int(r["pup_park_n"]) > 20 and bool(r["pup_park_ok"]) and bool(r["pup_park_any"]),
			"peer %d's puppet barrels park and stay parked while the owner's aim moves (%d samples; %s)" %
			[viewer, int(r["pup_park_n"]), str(r["worst"])])
		check(float(r["pup_post"]) > 5.0, "peer %d's puppet barrels track again after the reboot (%.1f deg)" % [viewer, float(r["pup_post"])])
	check(all.size() == peers, "every machine reported (%d of %d)" % [all.size(), peers])
