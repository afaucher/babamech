extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Multi-process co-op verification of playtest enemy upgrades over ENet localhost (host + 1 client):
##   (a) When host reveals an enemy (`set_revealed(true)`), EnemySync's existing reliable "alert" event replicates
##       `revealed == true` and emits `stragglers_revealed` on the client puppet with ZERO wire-format changes.
##   (b) When host kills an airborne EnemyDrone (~15 m altitude), the client puppet's charred wreck runs the same
##       deterministic falling-wreck physics and settles flush on the floor (< 2.5 m) instead of floating mid-air!
##   (c) Overheat look (R2.27): a host unit overheats and reboots; the client's puppet shows the shutdown look (optics
##       dark, slumped, fins hot within 0.1 of the host's heat) and the reboot (lights back, upright), and its squad
##       emits "overheated" / "rebooted" exactly once each (CombatAudio's cues), on both machines.

const PEERS := 2
const LINKS := ["off"]
const SEED := 11

var td: MissionScene
var world: CombatWorld
var sync: EnemySync
var revealed_events: Array[String] = []
var heat_events: Dictionary = {}   ## "overheated|<id>" / "rebooted|<id>" -> count (squad events on this machine)


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 30.0), "client received enemy manifest"):
		return

	# Find a turret (for reveal test) and an airborne drone (for falling aerial wreck test).
	var turret: EnemyBase = null
	var drone: EnemyFlier = null
	for e in td.combat.squad.enemies:
		if turret == null and e.enemy_type.begins_with("turret"):
			turret = e
		if drone == null and e.enemy_type == "drone":
			drone = e

	# (a) Host calls set_revealed(true) on turret -> verify client puppet sets revealed == true & emits stragglers_revealed.
	if check(turret != null, "encounter has a turret to reveal"):
		turret.set_revealed(true)
		check(turret.revealed, "host turret marked revealed")
		check(turret.target_id in revealed_events, "host emitted stragglers_revealed for turret")
		await sleep(0.8)
		var st := await _collect("revealed")
		for p: int in st:
			var rev_map: Dictionary = st[p]["revealed"]
			var rev_evs: Array = st[p]["rev_events"]
			check(bool(rev_map.get(turret.target_id, false)), "peer %d puppet mirrored revealed == true" % p)
			check(turret.target_id in rev_evs, "peer %d emitted stragglers_revealed for %s" % [p, turret.target_id])

	# (b) Host kills airborne drone (~15 m altitude) -> verify BOTH host and client drone wrecks fall to floor (< 2.5 m)!
	if check(drone != null, "encounter has an airborne drone to shoot down"):
		var d_ring := td.stack.deck_ring(drone.spawn_deck)
		var h_before := d_ring.height(drone.global_position)
		check(h_before >= 10.0, "host drone starts aloft before kill (h=%.1f m)" % h_before)
		drone.apply_damage(999.0, "hull", "player1")
		check(drone.destroyed(), "host killed airborne drone")
		await sleep(3.2)
		var h_host := d_ring.height(drone.global_position)
		check(not drone._wreck_falling, "host drone wreck finished falling")
		check(h_host < 2.5, "host drone wreck landed on floor/roof (h=%.2f m)" % h_host)
		var st2 := await _collect("wreck_landed")
		for p: int in st2:
			var d_dead: bool = bool((st2[p]["dead"] as Dictionary).get(drone.target_id, false))
			var d_h: float = float((st2[p]["heights"] as Dictionary).get(drone.target_id, 99.0))
			var d_falling: bool = bool((st2[p]["falling"] as Dictionary).get(drone.target_id, true))
			check(d_dead, "peer %d drone puppet is destroyed" % p)
			check(not d_falling, "peer %d drone wreck finished falling" % p)
			check(d_h < 2.5, "peer %d drone puppet wreck landed on floor/roof instead of floating (h=%.2f m)" % [p, d_h])

	await _overheat_cycle()
	_command_all("finish", {})
	check(await wait_done(peers - 1, 20.0), "client finished cleanly")


## (c) An awake finned unit on the host overheats, then reboots; every client's puppet shows the look and hears it once.
func _overheat_cycle() -> void:
	var u: EnemyBase = null
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed() and td.combat.squad.deck_awake(e.spawn_deck) 				and (e is EnemyTurret or e is EnemyStrider or e is EnemyTank):
			u = e
			break
	if not check(u != null, "an awake turret / strider / tank to overheat"):
		return
	var id := u.target_id
	u.heat.add(u.heat.cap)
	await sleep(1.2)
	check(u.heat_look.shut and u.heat_look.slump > 0.85, "host %s shows the shutdown look" % id)
	eq(int(heat_events.get("overheated|" + id, 0)), 1, "host squad emitted 'overheated' once for %s" % id)
	var host_heat := u.heat.fraction()
	var st := await _collect("ov_on")
	for p: int in st:
		var lk: Dictionary = (st[p]["looks"] as Dictionary).get(id, {})
		print("  overheat %s: host heat %.2f, peer %d look %s" % [id, host_heat, p, lk])
		check(bool(lk.get("shut", false)), "peer %d puppet %s is shut down" % [p, id])
		check(float(lk.get("lights", 1.0)) <= 0.01, "peer %d puppet %s optics dark (%.2f)" % [p, id, float(lk.get("lights", 1.0))])
		check(float(lk.get("slump", 0.0)) > 0.85, "peer %d puppet %s slumped (%.2f)" % [p, id, float(lk.get("slump", 0.0))])
		check(absf(float(lk.get("glow", -1.0)) - host_heat) < 0.1,
			"peer %d puppet %s fins in the host's band (%.2f vs host %.2f)" % [p, id, float(lk.get("glow", -1.0)), host_heat])
		eq(int((st[p]["heat_events"] as Dictionary).get("overheated|" + id, 0)), 1,
			"peer %d squad emitted 'overheated' once for %s" % [p, id])
	u.heat.value = u.heat.cap * (Heat.REBOOT_AT - 0.05)
	await sleep(1.6)
	check(not u.heat_look.shut and absf(u.heat_look.slump) < 0.05, "host %s rebooted and upright" % id)
	eq(int(heat_events.get("rebooted|" + id, 0)), 1, "host squad emitted 'rebooted' once for %s" % id)
	host_heat = u.heat.fraction()
	var st2 := await _collect("ov_off")
	for p: int in st2:
		var lk: Dictionary = (st2[p]["looks"] as Dictionary).get(id, {})
		print("  reboot %s: host heat %.2f, peer %d look %s" % [id, host_heat, p, lk])
		check(not bool(lk.get("shut", true)), "peer %d puppet %s rebooted" % [p, id])
		check(float(lk.get("lights", 0.0)) >= 0.99, "peer %d puppet %s lights back on" % [p, id])
		check(absf(float(lk.get("slump", 1.0))) < 0.05, "peer %d puppet %s upright again" % [p, id])
		check(absf(float(lk.get("glow", -1.0)) - host_heat) < 0.1,
			"peer %d puppet %s fins in the host's band after the reboot (%.2f vs %.2f)" % [p, id, float(lk.get("glow", -1.0)), host_heat])
		var evs: Dictionary = st2[p]["heat_events"]
		eq(int(evs.get("rebooted|" + id, 0)), 1, "peer %d squad emitted 'rebooted' once for %s" % [p, id])
		eq(int(evs.get("overheated|" + id, 0)), 1, "peer %d still one 'overheated' for %s" % [p, id])


func run_client() -> void:
	net_timeout = 90.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "mission launch arrives"):
		return
	if not await _load_and_go():
		return
	if not check(await until(func() -> bool: return sync.has_manifest and td.combat.squad.enemies.size() > 0, 15.0),
			"enemy manifest arrives"):
		return
	await sleep(0.5)
	report("ready", {"count": td.combat.squad.enemies.size()})
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "next host command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), _state())


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t on shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.enemy_sync != null and td.stack != null, "crew mission runs EnemySync in stack"):
		return false
	td.drive_override = true
	world = td.combat.world
	sync = td.enemy_sync
	td.combat.squad.enemy_event.connect(func(kind: String, enemy: Node, _payload: Dictionary) -> void:
		if (kind == "overheated" or kind == "rebooted") and enemy is EnemyBase:
			var k := kind + "|" + (enemy as EnemyBase).target_id
			heat_events[k] = int(heat_events.get(k, 0)) + 1
	)
	td.combat.squad.stragglers_revealed.connect(func(_deck: int, units: Array) -> void:
		for u in units:
			if u is EnemyBase:
				revealed_events.append((u as EnemyBase).target_id)
	)
	return check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
		"load barrier passes")


func _state() -> Dictionary:
	var rev := {}
	var dead := {}
	var heights := {}
	var falling := {}
	var looks := {}
	for e in td.combat.squad.enemies:
		if not is_instance_valid(e):
			continue
		var r := td.stack.deck_ring(e.spawn_deck)
		rev[e.target_id] = e.revealed
		dead[e.target_id] = e.destroyed()
		heights[e.target_id] = r.height(e.global_position)
		falling[e.target_id] = e is EnemyFlier and (e as EnemyFlier)._wreck_falling
		looks[e.target_id] = {"shut": e.heat_look.shut, "lights": e.heat_look.shown_lights(), "slump": e.heat_look.slump,
			"glow": e.heat_look.shown_heat()}
	return {"revealed": rev, "rev_events": revealed_events.duplicate(), "dead": dead, "heights": heights, "falling": falling,
		"looks": looks, "heat_events": heat_events.duplicate()}


func _command_all(cmd: String, data: Dictionary) -> void:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != 1:
			command(int(e["peer"]), cmd, data)


func _collect(key: String) -> Dictionary:
	_command_all("report", {"key": key})
	await wait_reports(key, peers - 1, 15.0)
	var out := {}
	for p in peers_with(key):
		out[p] = reported(p, key)
	return out
