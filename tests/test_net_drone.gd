extends NetTest
## The repair drone across machines (docs/design/back-equipment.md, scripts/combat/combat_net.gd "combat.drone") over a
## real crew mission of 2, once per link (off, coast). The host (A) launches a drone through CombatWorld.launch_drone (the
## call WeaponRack.activate makes; CombatNet sends the one event). Client c1 (B) has damaged its own mech beforehand.
## 1. B gets ONE drone with A's launch time t and shooter, and draws it at the same place as A at the same clock times
##    (samples 1.5 / 2.5 / 3.5 s into its life; both mechs stand still): it follows A's puppet on B.
## 2. B's own mech, 8 m from A (in range), is repaired by B: about 1 %/s of its max HP, every heal's src is A's shooter.
## 3. A never heals B's puppet target (A owns nothing of B: no healed signal there); A's puppet of B shows the repair only
##    through B's own snapshots (its HP goes up).
## 4. A repeated launch event is dropped on B (still one drone).
## 5. Looks (EquipmentLook): A carries the drone on its back; on B, A's puppet shows the docked drone before the launch
##    and the empty cradle while the drone is out (driven by the drone effect on B, not by A's rack).

const PEERS := 2
const SEED := 11
const SAMPLES := [1.5, 2.5, 3.5]
const POS_TOL := 1.0              ## m: the drone on B vs on A (puppet interpolation; both mechs stand still)
const DAMAGE := 200.0

var td: TestDrive
var world: CombatWorld
var net: CombatNet
var samples := {}                 ## str(s) -> Vector3: the launcher's drone position at t0 + s on this machine
var drone_t0 := NAN
var drones_seen := 0
var heals: Array = []             ## [amount, src] on this machine's own PlayerTarget
var puppet_heals := 0             ## healed signals on this machine's puppet targets (must stay 0)
var hp_after_damage := 0.0
var shown_before := ""          ## B: A's puppet back mount before the launch (EquipmentLook.shown)
var shown_out := ""             ## B: the same while A's drone is out


func run_host() -> void:
	net_timeout = 80.0
	var lo := Session.local_loadout()
	lo["back"] = "repair_drone"
	Session.set_profile(Session.player_name, Session.local_head(), Session.local_chassis(), "", lo)   # A carries the drone
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client is ready"):
		return
	var b := _other_peer()
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	if not check(pb != null, "the host has B's puppet"):
		return
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	var flat := pb.mech.global_position - td.mech.global_position
	flat -= td.mech.up() * flat.dot(td.mech.up())
	print("[drone] B stands %.2f m (horizontal) from A" % flat.length())
	check(flat.length() < 14.0, "B stands within the drone's 15 m of A (%.2f m)" % flat.length())
	command(b, "damage", {})
	if not check(await wait_reports("damaged", 1, 10.0), "B damaged its own mech"):
		return
	await sleep(0.5)                                 # B's snapshots carry the damage to A's puppet
	var puppet_hp0 := tb.total_hp()
	var rec := {"shooter": net.local_shooter, "peer": Session.local_id(), "hardpoint": "back", "weapon": "repair_drone",
		"t": world.now}
	var d := world.launch_drone(rec)
	if not check(d != null, "the host's drone launched"):
		return
	await sleep(0.3)
	Session.send_event(0, CombatNet.DRONE, {"t": float(rec["t"]), "hp": "back"})   # the same launch again: dropped
	await until(func() -> bool: return samples.size() == SAMPLES.size(), 6.0)
	await sleep(0.4)
	command(b, "report", {"key": "drone"})
	if not check(await wait_reports("drone", 1, 10.0), "B reports"):
		return
	var v: Dictionary = reported(b, "drone")
	var elapsed := world.now - float(rec["t"])
	# 1. One drone, same t, same place.
	eq(int(v["drones_seen"]), 1, "B launched exactly one drone")
	near(float(v["t0"]), float(rec["t"]), 1e-4, "B's drone has A's launch time")
	check(int((v["stats"] as Dictionary)["drones_dup"]) >= 1, "B dropped the repeated launch event")
	eq(int((v["stats"] as Dictionary)["drones_recv"]), 1, "B received one launch")
	eq(int(net.stats["drones_sent"]), 1, "A sent one launch event")
	var theirs: Dictionary = v["samples"]
	for s: float in SAMPLES:
		var k := str(s)
		if not check(samples.has(k) and theirs.has(k), "both sampled the drone at %.1f s" % s):
			continue
		var off := (theirs[k] as Vector3).distance_to(samples[k])
		print("[drone] %s: at %.1f s the drone on B is %.3f m from A's" % [link, s, off])
		check(off < POS_TOL, "the drone on B is where it is on A at %.1f s (%.3f m)" % [s, off])
	# 2. B repaired its own mech, about 1 %/s.
	var gained := float(v["hp_now"]) - float(v["hp_after_damage"])
	var rate := 0.01 * float(v["max_hp"])
	print("[drone] %s: B repaired %.2f HP in %.2f s since launch (1 %%/s = %.2f HP/s)" % [link, gained, elapsed, rate])
	check(gained > rate * (elapsed - 1.5) and gained <= rate * elapsed + 0.5,
		"B's mech gained about 1 %%/s (%.2f HP in %.2f s)" % [gained, elapsed])
	check(int(v["heals"]) > 0 and bool(v["heal_src_ok"]), "B's heals came from A's drone")
	eq(int(v["puppet_heals"]), 0, "B healed no puppet")
	# 5. A's puppet on B: docked before, the empty cradle while the drone is out.
	eq(str(v["back"]), "repair_drone", "A's puppet on B carries the repair drone")
	eq(str(v["shown_before"]), "docked", "on B, A's puppet showed the docked drone before the launch")
	eq(str(v["shown_out"]), "cradle", "on B, A's puppet shows the empty cradle while the drone is out")
	# 3. A wrote nothing of B's.
	eq(puppet_heals, 0, "A never healed B's puppet target")
	check(not world.owns(tb), "A does not own B's target")
	eq(heals.size(), 0, "A's own mech (undamaged) was not healed")
	await sleep(0.3)
	check(tb.total_hp() > puppet_hp0 + rate * 0.5, "A's puppet of B shows the repair through B's snapshots (%.1f -> %.1f)" % [
		puppet_hp0, tb.total_hp()])
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 80.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", net != null and world.clock.is_valid())
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"damage":
				td.combat.player_target.apply_damage(DAMAGE, "torso", "test")
				hp_after_damage = td.combat.player_target.total_hp()
				shown_before = world.equipment_look.shown("player1")
				report("damaged", hp_after_damage)
			"report":
				var src_ok := true
				for h: Array in heals:
					src_ok = src_ok and str(h[1]) == "player1"
				report(str(c["key"]), {"drones_seen": drones_seen, "t0": drone_t0, "samples": samples,
					"hp_after_damage": hp_after_damage, "hp_now": td.combat.player_target.total_hp(),
					"max_hp": td.combat.player_target.total_max_hp(), "heals": heals.size(), "heal_src_ok": src_ok,
					"puppet_heals": puppet_heals, "stats": net.stats, "shown_before": shown_before,
					"shown_out": shown_out, "back": _puppet_back()})


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null, "the crew mission runs CombatNet"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	net = td.combat.net
	world.drone_launched.connect(_on_drone)
	td.combat.player_target.healed.connect(_on_healed)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	if not check(await until(_puppet_shown, 10.0), "the puppet is shown"):
		return false
	for p: int in td.crew_sync.targets:
		(td.crew_sync.targets[p] as PlayerTarget).healed.connect(_on_puppet_healed)
	return true


func _puppet_shown() -> bool:
	return td.crew_sync.puppets.size() == peers - 1 and (td.crew_sync.puppets.values()[0] as MechPuppet).shown != null


func _on_drone(rec: Dictionary, _d: RepairDrone) -> void:
	if str(rec["shooter"]) == "player1":
		drones_seen += 1
		drone_t0 = float(rec["t"])


func _on_healed(a: float, _c: String, s: String) -> void:
	heals.append([a, s])


func _on_puppet_healed(_a: float, _c: String, _s: String) -> void:
	puppet_heals += 1


func _physics_process(_delta: float) -> void:
	if world == null:
		return
	var d := world.drone_of("player1")
	if d == null:
		return
	for s: float in SAMPLES:
		if not samples.has(str(s)) and world.now >= d.t0 + s:
			samples[str(s)] = d.pos
	if d.active() and world.now >= d.t0 + 1.0:
		shown_out = world.equipment_look.shown("player1")


## The back weapon of the crew puppet of peer 1 on this machine ("" on the host / when there is none).
func _puppet_back() -> String:
	var pp: MechPuppet = td.crew_sync.puppets.get(1) if td != null and td.crew_sync != null else null
	if pp == null or pp.rig == null or pp.rig.model == null:
		return ""
	return str(pp.rig.model.loadout.get("back", ""))


func _other_peer() -> int:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			return int(e["peer"])
	return -1
