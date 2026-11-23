extends NetTest
## Enemies hear a client's fire (EnemySquad hearing, host-only) over a real crew mission of 2 in the stack, once per link
## (off, coast). The host idles every enemy but one turret E on the entry deck, which it moves about 30 m in front of the
## client's mech, facing away, with its sight cut (sight_range 1 m: only hearing can alert it).
## 1. The CLIENT fires an autocannon shell that passes about 10 m beside E (aimed past it, not at it).
## 2. The client's record reaches the host through CombatNet; the host's squad hears it and E becomes alerted there.
## 3. The client's puppet of E shows the alerted state (EnemySync streams ai_state).
## 4. No hearing ran on the client: its squad's hear_checks stays 0 and nothing is pending there (its enemies are
##    puppets; the handlers return at once off the host).

const PEERS := 2
const SEED := 11
const PASS_BY := 10.0             ## m beside E's eye the client's shot is aimed

var td: TestDrive
var world: CombatWorld
var sync: EnemySync


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var sq := td.combat.squad
	for e in sq.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client has the enemy manifest"):
		return
	var c1 := _other_peer()
	var pb: MechPuppet = td.crew_sync.puppets.get(c1)
	var k := int(td.stack.section.entry["deck"])
	var e: EnemyBase = null
	for en in sq.enemies:
		if not en.destroyed() and en.spawn_deck == k and (e == null or en.enemy_type == "turret" and e.enemy_type != "turret"):
			e = en
	if not check(pb != null and e != null, "the host has the client's puppet and an enemy on the entry deck"):
		return
	# Put E 30 m ahead of the client's mech, facing away from it, sight cut.
	var pc := pb.mech.global_position
	var up := td.stack.ring().up_at(pc)
	var fwd := td.mech.forward()
	fwd = (fwd - up * fwd.dot(up)).normalized()
	# A straight 30 m step leaves the curved floor (it ends ~30^2/2R outside it, under deck k, where the host's deck
	# re-home would move E to the sleeping deck below): drop the spot back onto deck k's floor.
	var spot := pc + fwd * 30.0
	var dr := td.stack.deck_ring(k)
	up = dr.up_at(spot)
	spot -= up * dr.height(spot)
	fwd = (fwd - up * fwd.dot(up)).normalized()
	e.global_transform = Transform3D(Basis(fwd.cross(up).normalized(), up, -fwd), spot)
	e.ground_y = spot.dot(up)
	e.sight_range = 1.0
	await sleep(1.5)                  # any idle enemy's pending comm relay runs out
	sq.known_targets.clear()
	e.ai_mode = "live"
	await sleep(0.5)
	if not check(not e.is_alerted(), "E is not alerted before the shot (%s)" % e.ai_state):
		return
	if not check(e.spawn_deck == k and sq.deck_awake(k), "E is still on the awake entry deck (deck %d)" % e.spawn_deck):
		return
	var checks0 := sq.hear_checks
	command(c1, "fire", {"eye": e.eye_world(), "n": e.net_id})
	check(await until(func() -> bool: return e.is_alerted(), 6.0), "the host's E hears the client's shot and alerts (%s)" % e.ai_state)
	check(sq.hear_checks > checks0, "the host's hearing evaluated the client's record (%d)" % (sq.hear_checks - checks0))
	check(not e.destroyed() and e.core_hp_ratio() > 0.999, "E was not hit (it heard the shot pass)")
	if check(await wait_reports("fired", 1, 15.0), "the client reports"):
		var v: Dictionary = reported(c1, "fired")
		check(bool(v["fired"]), "the client fired its shot")
		print("[hearing] client: pass-by %.1f m, puppet state %s" % [float(v["miss"]), str(v["state"])])
		check(bool(v["alerted"]), "the client's puppet of E shows the alerted state (%s)" % str(v["state"]))
		eq(int(v["hear_checks"]), 0, "no hearing ran on the client")
		eq(int(v["pending"]), 0, "nothing is pending in the client's squad")
	command(c1, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 90.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	if not check(await until(func() -> bool: return sync.has_manifest and td.combat.squad.enemies.size() > 0, 15.0),
			"the enemy manifest arrives"):
		return
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"fire":
				var eye: Vector3 = c["eye"]
				var p := CombatWorld.local_peer()
				var up := td.mech.up()
				var from := td.mech.global_position + up * 4.0
				var to_e := eye - from
				var side := to_e.cross(up).normalized()
				var aim := eye + side * PASS_BY
				var rec := Combat.fire_record(td.combat.net.local_shooter, p, "side_l", "autocannon", from, aim, world.now, 9900, 0.0)
				var fired := world.fire(rec) != null    # now: the shell is freed once it lands
				var miss := Geometry3D.get_closest_point_to_segment(eye, from, aim).distance_to(eye)
				var puppet := sync.by_net.get(int(c["n"])) as EnemyBase
				await until(func() -> bool: return puppet != null and is_instance_valid(puppet) and puppet.is_alerted(), 8.0)
				var sq := td.combat.squad
				report("fired", {"fired": fired, "miss": miss,
					"alerted": puppet != null and is_instance_valid(puppet) and puppet.is_alerted(),
					"state": puppet.ai_state if puppet != null and is_instance_valid(puppet) else "missing",
					"hear_checks": sq.hear_checks, "pending": sq.pending_hearings()})


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.enemy_sync != null and td.stack != null and td.combat.net != null,
			"the crew mission runs CombatNet and EnemySync in the stack"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	sync = td.enemy_sync
	td.combat.player_target.auto_respawn_delay = -1.0
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0)


func _other_peer() -> int:
	for en: Dictionary in Session.crew():
		if int(en["peer"]) != Session.local_id():
			return int(en["peer"])
	return -1
