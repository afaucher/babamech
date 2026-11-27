extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Mech snapshots (co-op step 2, docs/networking.md "Mech snapshots") over a real crew, once per link (off, coast):
## - the crew launches a mission (as net_mission_case.gd); every machine has one mech per crew member, every one but its
##   own a puppet (MechController.puppet, a MechPuppet child) registered as a PlayerTarget with its owner's peer;
## - every machine drives its own mech through the same script (walk, a thrust hop, a diagonal strafe, a turn in place,
##   stand, then a forced overheat), recording its own streamed states (Session.mechs' fed samples: the owner's truth at
##   their shared-clock time) and what it shows of every puppet (MechPuppet.shown: position at its render time);
## - the host judges: each puppet, at its render time, within TOL[link] of where its owner really was at that moment
##   (owner history interpolated), facing within YAW_TOL, ends within END_TOL of the owner's final spot; heat, thrust and
##   the overheat cross (and reach the crew panel's status_source); T_SNAP packets arrive (the unreliable sequenced
##   channel) and none is over NetMechCodec.MAX_PACKET bytes;
## - damage crosses: each owner hits its own hull (DAMAGE_T: torso to HULL_AFTER) and is then downed (DOWN_T: leg_l
##   destroyed); every viewer's puppet shows `hull`, `downed` and `disable_cause` (MechPuppet), mirrors them onto the
##   puppet's PlayerTarget, and the crew panel says "disabled";
## - mount aims cross: each owner aims off to the side (manual aim) so its pivoting weapons slew; every viewer's puppet
##   carries the owner's largest barrel yaw within MOUNT_TOL.
## The scenario for test_net_snap (2) and test_net_snap_4 (a full crew). Not a test itself (no test_ prefix).

const SEED := 7
## Largest position error of a puppet at its render time against its owner's true position then (m), per link. The
## mean must stay under a quarter of it.
const TOL := {"off": 0.5, "coast": 0.8}
const YAW_TOL := 0.12              ## rad, largest heading error at render time
const END_TOL := 0.3               ## m, the puppet's last shown spot to the owner's last
const SCRIPT_END := 6.6            ## s of scripted driving after mission_go
const RECORD_END := 7.4            ## s of recording (the puppets catch up with the owners' last moves)
const DAMAGE_T := 1.0              ## s: each owner hits its own torso for DAMAGE
const DAMAGE := 100.0
const HULL_AFTER := 0.75           ## torso 400 HP - 100
const DOWN_T := 6.0                ## s: each owner loses a leg (downed, cause "leg_l")
const MOUNT_TOL := 3.0             ## deg between the owner's largest barrel yaw and the one its puppet showed

var td: MissionScene
var _t0 := 0.0


func run_host() -> void:
	net_timeout = 85.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0),
			"the crew gathers (%d of %d)" % [Session.roster.size(), peers]):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var mine := await _drive_and_record()
	if not check(await wait_reports("snap", peers - 1, 40.0), "every client reports its snapshot run"):
		return
	var all := {Session.local_id(): mine}
	for p in peers_with("snap"):
		all[p] = reported(p, "snap")
	_judge(all)
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 85.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("snap", await _drive_and_record())


## Load the test drive at start_t and wait for the barrier (mission_go). Enemies are cleared: the walk must not be
## knocked about or respawned by a turret.
func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null, "the test drive runs the crew mission with mech snapshots"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes (phase %s)" % Session.mission.phase):
		return false
	return true


## Drive the local mech through the script while recording; returns this machine's report.
func _drive_and_record() -> Dictionary:
	td.drive_override = true
	var m := td.mech
	_t0 = Session.host_time()
	var sgn := -1.0 if index % 2 == 0 else 1.0
	var own := PackedFloat32Array()
	var obs := {}                      # peer -> PackedFloat32Array of [render_t, x, y, z, yaw, heat, thrusting, shutdown]
	var last_own := -1.0
	var last_obs := {}
	var heated := false
	var hit := false
	var downed := false
	var max_own_mount := 0.0
	var dmg := {}                      # peer -> [min hull, downed seen, cause, max |mount yaw|]
	var pt := td.combat.player_target
	pt.auto_respawn_delay = -1.0       # stay downed: the respawn would teleport the mech mid-recording
	td.combat.rack.manual_aim = true
	var max_own_heat := 0.0
	var own_thrust := false
	while true:
		var e := Session.host_time() - _t0
		if e > RECORD_END:
			break
		var mv := Vector2.ZERO
		var turn := 0.0
		var thrust := false
		if e < 2.0:
			mv = Vector2(0, 1)
		elif e < 2.7:
			mv = Vector2(0, 1)
			thrust = true
		elif e < 3.7:
			mv = Vector2(sgn * 0.7, 0.7)
		elif e < 4.7:
			turn = 1.0
		if e >= DAMAGE_T and not hit:
			hit = true
			pt.apply_damage(DAMAGE, "torso", "test")
		if e >= DOWN_T and not downed:
			downed = true
			pt.apply_damage(PlayerTarget.COMPONENT_HP["leg_l"] + 1.0, "leg_l", "test")
		var right := m.global_basis.x
		td.combat.rack.aim_point = m.global_position + m.up() * 4.0 + m.forward() * 30.0 + right * 30.0 * sgn
		for v: float in CrewSync.mount_aims(td.combat.rack):
			max_own_mount = maxf(max_own_mount, absf(v))
		if e >= 5.5 and not heated:
			heated = true
			m.add_heat(m.heat_cap)
		m.move_input = mv
		m.turn_input = turn
		m.running = false
		m.thrust_input = thrust and e < SCRIPT_END
		var fed: NetMechState = Session.mechs.local_state()
		if fed != null and fed.t > last_own:
			last_own = fed.t
			own.append_array([fed.t - _t0, fed.pos.x, fed.pos.y, fed.pos.z, fed.yaw])
			max_own_heat = maxf(max_own_heat, fed.heat)
			own_thrust = own_thrust or fed.thrusting
		for p: int in td.crew_sync.puppets:
			var pp: MechPuppet = td.crew_sync.puppets[p]
			if pp.shown == null or pp.shown.t <= float(last_obs.get(p, -1e9)):
				continue
			last_obs[p] = pp.shown.t
			var d: Array = dmg.get(p, [1.0, false, "", 0.0])
			d[0] = minf(float(d[0]), pp.hull)
			d[1] = bool(d[1]) or pp.downed
			if pp.disable_cause != "":
				d[2] = pp.disable_cause
			for v: float in pp.shown.mount_aim:
				d[3] = maxf(float(d[3]), absf(v))
			dmg[p] = d
			if not obs.has(p):
				obs[p] = []   # an Array (a reference): appending to a Packed array read out of a Dictionary changes a copy
			var at := pp.mech.global_position
			var yaw := CrewSync.heading_of(pp.mech.ring, at, pp.mech.forward())
			(obs[p] as Array).append_array([pp.shown.t - _t0, at.x, at.y, at.z, yaw, pp.mech.heat / pp.mech.heat_cap,
				1.0 if pp.mech.thrusting else 0.0, 1.0 if pp.mech.shutdown else 0.0])
		await get_tree().physics_frame
	var out := _summary(own, obs, max_own_heat, own_thrust)
	var mirrored := {}
	for p: int in td.crew_sync.puppets:
		var pp: MechPuppet = td.crew_sync.puppets[p]
		mirrored[str(p)] = pp.target != null and pp.target.disabled and pp.target.disable_cause == "leg_l" \
			and absf(float(pp.target.hp["torso"]) - HULL_AFTER * PlayerTarget.COMPONENT_HP["torso"]) < 4.0
	var dmg_s := {}
	for p: int in dmg:
		dmg_s[str(p)] = dmg[p]
	out["dmg"] = dmg_s
	out["mirrored"] = mirrored
	out["own_mount"] = max_own_mount
	return out


func _summary(own: PackedFloat32Array, obs: Dictionary, max_own_heat: float, own_thrust: bool) -> Dictionary:
	var hud := td.get_node_or_null("MechHud") as MechHud
	var panel_states := {}
	var targets := {}
	for p: int in td.crew_sync.puppets:
		panel_states[str(p)] = str(hud.crew_panel.status(p)["state"]) if hud != null and hud.crew_panel != null else "no panel"
	for t: CombatTarget in td.combat.world.targets:
		if t is PlayerTarget and (t as PlayerTarget).mech != null and (t as PlayerTarget).mech.puppet:
			targets[str(MechSpawn.owner_of((t as PlayerTarget).mech))] = t.owner_peer
	var puppets := 0
	for p: int in td.mechs:
		var m: MechController = td.mechs[p]
		if m.puppet and m.get_node_or_null("Puppet") is MechPuppet and m.owner_peer == p:
			puppets += 1
	var obs_s := {}
	for p: int in obs:
		obs_s[str(p)] = PackedFloat32Array(obs[p] as Array)
	var ts: Array = Session.wire.type_stats.get(NetWire.T_SNAP, [0, 0, 0])
	return {"own": own, "obs": obs_s, "max_heat": max_own_heat, "thrust": own_thrust, "mechs": td.mechs.size(),
		"puppets": puppets, "targets": targets, "panel": panel_states, "stats": Session.mechs.stats.duplicate(),
		"wire_snap": ts, "delays": _delays()}


func _delays() -> Dictionary:
	var out := {}
	for p in Session.mechs.puppet_peers():
		out[str(p)] = Session.mechs.delay_of(p)
	return out


## The owner's position and yaw at time t (linear between its recorded samples); [] outside its history.
static func _owner_at(own: PackedFloat32Array, t: float) -> Array:
	var n := own.size() / 5
	if n < 2 or t < own[0] or t > own[(n - 1) * 5]:
		return []
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if own[mid * 5] <= t:
			lo = mid
		else:
			hi = mid
	var ta := own[lo * 5]
	var tb := own[hi * 5]
	var u := clampf((t - ta) / maxf(tb - ta, 1e-5), 0.0, 1.0)
	var a := Vector3(own[lo * 5 + 1], own[lo * 5 + 2], own[lo * 5 + 3])
	var b := Vector3(own[hi * 5 + 1], own[hi * 5 + 2], own[hi * 5 + 3])
	return [a.lerp(b, u), lerp_angle(own[lo * 5 + 4], own[hi * 5 + 4], u)]


func _judge(all: Dictionary) -> void:
	var tol: float = TOL.get(link, TOL["coast"])
	var crew := all.size()
	for viewer: int in all:
		var r: Dictionary = all[viewer]
		eq(int(r["mechs"]), peers, "peer %d has one mech per crew member" % viewer)
		eq(int(r["puppets"]), peers - 1, "peer %d shows every other mech as a puppet, owned by its peer" % viewer)
		var st: Dictionary = r["stats"]
		check(int(st["in_packets"]) > 0, "peer %d received snapshots" % viewer)
		check(int(st["out_max"]) <= NetMechCodec.MAX_PACKET, "peer %d's largest snapshot packet is %d bytes (budget %d)" %
			[viewer, int(st["out_max"]), NetMechCodec.MAX_PACKET])
		check(int((r["wire_snap"] as Array)[0]) > 0, "peer %d's snapshots came on the unreliable sequenced channel (T_SNAP)" % viewer)
		check(float(r["max_heat"]) > 0.9 and bool(r["thrust"]), "peer %d's own mech thrust and overheated" % viewer)
		print("[snap] peer %d: out %d packets, max %d B, in %d packets / %d entries, refused %d, forwarded %d, delays %s" %
			[viewer, int(st["out_packets"]), int(st["out_max"]), int(st["in_packets"]), int(st["in_entries"]), int(st["in_refused"]),
			int(st["forwarded"]), str(r["delays"])])
		for ps: String in r["obs"]:
			var owner := int(ps)
			if not all.has(owner):
				continue
			var own: PackedFloat32Array = (all[owner] as Dictionary)["own"]
			var ob: PackedFloat32Array = (r["obs"] as Dictionary)[ps]
			var n := ob.size() / 8
			var worst := 0.0
			var worst_t := 0.0
			var sum := 0.0
			var count := 0
			var worst_yaw := 0.0
			var max_heat := 0.0
			var thrust_seen := false
			var shutdown_seen := false
			for i in n:
				var t := ob[i * 8]
				var o := _owner_at(own, t)
				max_heat = maxf(max_heat, ob[i * 8 + 5])
				thrust_seen = thrust_seen or ob[i * 8 + 6] > 0.5
				shutdown_seen = shutdown_seen or ob[i * 8 + 7] > 0.5
				if o.is_empty():
					continue
				var d := Vector3(ob[i * 8 + 1], ob[i * 8 + 2], ob[i * 8 + 3]).distance_to(o[0])
				if d > worst:
					worst_t = t
				worst = maxf(worst, d)
				sum += d
				count += 1
				worst_yaw = maxf(worst_yaw, absf(angle_difference(ob[i * 8 + 4], float(o[1]))))
			var mean := sum / maxf(count, 1)
			var on := own.size() / 5
			var end_err := INF
			if n > 0 and on > 0:
				end_err = Vector3(ob[(n - 1) * 8 + 1], ob[(n - 1) * 8 + 2], ob[(n - 1) * 8 + 3]).distance_to(
					Vector3(own[(on - 1) * 5 + 1], own[(on - 1) * 5 + 2], own[(on - 1) * 5 + 3]))
			print("[snap] link %s: peer %d sees peer %d: %d samples, error at render time max %.3f m mean %.3f m, yaw max %.3f rad, end %.3f m (worst at %.2f s)" %
				[link, viewer, owner, count, worst, mean, worst_yaw, end_err, worst_t])
			if OS.has_environment("BABAMECH_SNAP_DEBUG"):
				for i in n:
					if absf(ob[i * 8] - worst_t) < 0.12:
						var o2 := _owner_at(own, ob[i * 8])
						print("  t %.3f shown %s owner %s" % [ob[i * 8], Vector3(ob[i * 8 + 1], ob[i * 8 + 2], ob[i * 8 + 3]), o2[0] if not o2.is_empty() else "-"])
				for j in own.size() / 5:
					if absf(own[j * 5] - worst_t) < 0.12:
						print("  own t %.3f %s" % [own[j * 5], Vector3(own[j * 5 + 1], own[j * 5 + 2], own[j * 5 + 3])])
			check(count > 150, "peer %d showed peer %d's puppet through the drive (%d samples)" % [viewer, owner, count])
			check(worst < tol, "peer %d's puppet of peer %d stays within %.2f m of its owner at render time (max %.3f)" % [viewer, owner, tol, worst])
			check(mean < tol * 0.25, "peer %d's puppet of peer %d: mean error %.3f m under %.3f" % [viewer, owner, mean, tol * 0.25])
			check(worst_yaw < YAW_TOL, "peer %d's puppet of peer %d faces its owner's way (max %.3f rad)" % [viewer, owner, worst_yaw])
			check(end_err < END_TOL, "peer %d's puppet of peer %d ends at its owner's spot (%.3f m)" % [viewer, owner, end_err])
			check(max_heat > 0.9 and thrust_seen and shutdown_seen,
				"peer %d sees peer %d's heat (max %.2f), thrust (%s) and overheat (%s)" % [viewer, owner, max_heat, thrust_seen, shutdown_seen])
			eq(str((r["panel"] as Dictionary).get(ps, "")), "disabled", "peer %d's crew panel shows peer %d downed" % [viewer, owner])
			var d: Array = (r["dmg"] as Dictionary).get(ps, [1.0, false, "", 0.0])
			near(float(d[0]), HULL_AFTER, 0.02, "peer %d sees peer %d's hull HP (%.3f)" % [viewer, owner, float(d[0])])
			check(bool(d[1]), "peer %d sees peer %d downed" % [viewer, owner])
			eq(str(d[2]), "leg_l", "peer %d sees why peer %d is down" % [viewer, owner])
			check(bool((r["mirrored"] as Dictionary).get(ps, false)), "peer %d's PlayerTarget of peer %d mirrors its owner's damage" % [viewer, owner])
			var own_mount := float((all[owner] as Dictionary)["own_mount"])
			print("[snap] peer %d sees peer %d's largest barrel yaw %.1f deg (owner %.1f)" % [viewer, owner, float(d[3]), own_mount])
			if own_mount > 5.0:
				near(float(d[3]), own_mount, MOUNT_TOL, "peer %d sees peer %d's barrel aim" % [viewer, owner])
			eq(int((r["targets"] as Dictionary).get(ps, 0)), owner, "peer %d registered peer %d's puppet as a PlayerTarget owned by it" % [viewer, owner])
	check(crew == peers, "every machine reported (%d of %d)" % [crew, peers])
