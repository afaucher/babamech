extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## A Bulwark's weapons across machines (docs/networking.md, weapons.md §5) over a real crew mission of 2, once per link.
## The host (A) flies a Bulwark (its profile's chassis), client c1 (B) the default Strider; friendly fire on (the default),
## world geometry off everywhere (shots meet hit spheres only: the city never blocks a line). Nothing new on the wire:
## A's rack makes fire records exactly as a Strider's, CombatNet sends them, B decides about its own mech.
## 1. B walks ahead until it is ~DIST m from A (in the side guns' arc, past the mortar's 30 m minimum, inside the
##    flamer's 45 m).
## 2. A fires one weapon of every class from the hardpoint under test, aimed at B's puppet (PHASES: each side gun with
##    every side / shoulder weapon class, the mortar from each back saddle, the belly turret's gatling and
##    autocannon when the catalog has it). Per phase: B received every A record with
##    its hardpoint id; B applied at least one of them to its own mech, each hit one of A's shots; A built no Hit and sent
##    no remote hit for B; B's own HP loss = the sum of its hits; A's puppet of B shows that loss from B's snapshot.
##    Then B repairs (its own verb on its own mech).
## 3. A launches a repair drone from back_r: B's copy names back_r.
## 4. B shoots A's back_l saddle: A (the victim) applies it on component back_l; B built no Hit on A; B's puppet of A
##    shows back_l below full (component HP for the Bulwark's back saddles rides the snapshot). A destroys its back_l:
##    its slot 3 stops; B's puppet shows back_l at 0.

const PEERS := 2
const SEED := 21
const DIST := 38.0
const BULWARK_LO := {"side_l": "autocannon", "side_r": "laser", "back_l": "mortar", "back_r": "mortar"}
## [hardpoint, weapon, trigger seconds, wait seconds after release]
const PHASES := [
	["side_l", "autocannon", 0.1, 1.2], ["side_r", "laser", 0.4, 0.8], ["side_l", "gatling", 1.0, 1.0],
	["side_r", "swivel", 0.3, 1.0], ["side_l", "rockets", 0.2, 2.0], ["side_r", "missiles", 0.2, 3.0],
	["side_l", "railgun", 1.1, 0.8], ["side_r", "flamer", 0.6, 1.6], ["side_l", "flak", 0.1, 1.0],
	["back_l", "mortar", 0.1, 3.4], ["back_r", "mortar", 0.1, 3.4],
]
const HP_TOL := 3.5                ## HP: the snapshot's component quantisation (max / 254 per component, a few hit)

var td: MissionScene
var world: CombatWorld
var net: CombatNet
var fired: Array = []              ## this machine's own fire records: {key, hp, weapon}
var got: Array = []                ## remote records that arrived: {key, hp, weapon, shooter}
var hits: Array = []               ## hit_landed: {id, dmg, shot, comp}
var remote_hits: Array = []        ## remote_hit target ids
var drones: Array = []             ## remote drone records' hardpoints


func run_host() -> void:
	net_timeout = 150.0
	Session.set_profile("host", head_for(0), "bulwark", accent_for(0), BULWARK_LO)
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	eq(td.rig.model.chassis_id, "bulwark", "the host flies a Bulwark")
	var ids: Array[String] = []
	for h: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		ids.append(str(h["id"]))
	eq(td.combat.rack.hardpoints, ids, "its rack has one slot per Bulwark hardpoint (%s)" % str(ids))
	# The belly turret (when the catalog has it): two of its weapon classes too.
	var phases: Array = PHASES.duplicate()
	if "belly" in ids:
		phases.append_array([["belly", "gatling", 1.0, 1.0], ["belly", "autocannon", 0.1, 1.2]])
	var b := -1
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			b = int(e["peer"])
	var st := await _collect(b, "chassis")
	eq(str(st.get("puppet_chassis", "")), "bulwark", "B's puppet of A is a Bulwark")
	# 1. B walks ahead.
	command(b, "advance", {})
	if not check(await wait_reports("ack_advance", 1, 20.0), "B walked ahead"):
		return
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	if not check(pb != null and tb != null, "A has B's puppet and its target"):
		return
	await sleep(0.4)
	var m := td.mech
	print("[bulwark] B is %.1f m from A" % m.global_position.distance_to(pb.mech.global_position))
	var rack := td.combat.rack
	rack.read_input = false
	rack.manual_aim = true
	# 2. Every weapon class from the hardpoint under test.
	for pi in phases.size():
		var ph: Array = phases[pi]
		var hp := str(ph[0])
		var w := str(ph[1])
		var lo: Dictionary = BULWARK_LO.duplicate()
		lo[hp] = w
		td.rig.model.configure(td.rig.model.head_id, "bulwark", lo)
		rack.rebuild()
		for i in rack.slot_count():
			rack.set_enabled(i + 1, rack.hardpoints[i] == hp)
			# The rebuilt mounts count shots from 0 again: keep this phase's shot keys apart from the last one's (a
			# mid-mission loadout change is a test device; in the game the loadout is fixed at launch).
			if rack.mounts[i] != null:
				(rack.mounts[i] as WeaponMount).shot_index = 1000 * (pi + 1)
		m.heat = 0.0
		var n0 := fired.size()
		var nh := hits.size()
		var nr := remote_hits.size()
		var lost0 := _lost(tb)
		var t := 0.0
		var aim_b := func() -> Vector3: return pb.mech.global_position + pb.mech.up() * 4.4
		while t < float(ph[2]) + float(ph[3]):
			rack.aim_point = aim_b.call()
			rack.set_trigger(t < float(ph[2]))
			m.move_input = Vector2.ZERO
			await get_tree().physics_frame
			t += get_physics_process_delta_time()
		rack.set_trigger(false)
		var mine := fired.slice(n0).filter(func(f: Dictionary) -> bool: return f["hp"] == hp and f["weapon"] == w)
		var keys := mine.map(func(f: Dictionary) -> String: return str(f["key"]))
		if not check(mine.size() > 0, "%s/%s: A's Bulwark fired (%s)" % [hp, w, str(rack.slots()[rack.hardpoints.find(hp)]["hold"])]):
			continue
		await sleep(0.5)                         # B's snapshot carrying its HP
		var v := await _collect(b, "ph_%s_%s" % [hp, w])
		var b_got: Array = (v.get("got", []) as Array).filter(func(g: Dictionary) -> bool: return str(g["key"]) in keys)
		eq(b_got.size(), keys.size(), "%s/%s: B received every record (%d of %d)" % [hp, w, b_got.size(), keys.size()])
		check(b_got.all(func(g: Dictionary) -> bool: return g["hp"] == hp and g["weapon"] == w), "%s/%s: with its hardpoint and weapon" % [hp, w])
		var own: Array = (v.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
		check(own.size() > 0, "%s/%s: B applied A's shot to its own mech (%d hits)" % [hp, w, own.size()])
		check(own.all(func(h: Dictionary) -> bool: return str(h["shot"]) in keys), "%s/%s: every hit on B is one of A's shots" % [hp, w])
		var sum := 0.0
		for h: Dictionary in own:
			sum += float(h["dmg"])
		near(float(v.get("own_lost", -1.0)), sum, 0.01, "%s/%s: B's HP loss is the sum of its hits (%.1f)" % [hp, w, sum])
		var a_on_b := hits.slice(nh).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
		eq(a_on_b.size(), 0, "%s/%s: A built no Hit on B's puppet" % [hp, w])
		check(not ("player%d" % b) in remote_hits.slice(nr), "%s/%s: A sent no remote hit for B" % [hp, w])
		near(_lost(tb) - lost0, float(v.get("own_lost", -1.0)), HP_TOL, "%s/%s: A's puppet of B mirrors B's own HP loss" % [hp, w])
		command(b, "repair", {"k": "%s_%s" % [hp, w]})
		check(await wait_reports("ack_repair_%s_%s" % [hp, w], 1, 10.0), "B repaired")
		await sleep(0.4)
	# 3. Repair drone from back_r.
	var lo2: Dictionary = BULWARK_LO.duplicate()
	lo2["back_r"] = "repair_drone"
	td.rig.model.configure(td.rig.model.head_id, "bulwark", lo2)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(rack.activate(4), "A launches its back_r repair drone")
	await sleep(0.8)
	var vd := await _collect(b, "drone")
	check("back_r" in (vd.get("drones", []) as Array), "B's copy of the drone names back_r (%s)" % str(vd.get("drones", [])))
	# 4. B shoots A's back_l saddle.
	td.rig.model.configure(td.rig.model.head_id, "bulwark", BULWARK_LO)
	# Recall A's drone: since 2026-11-26 (R2.1) a drone rebuilds a destroyed weapon hardpoint, which would undo the
	# destroyed back_l this part checks.
	for dr: RepairDrone in td.combat.world.drones_of(net.local_shooter):
		td.combat.world.remove_effect(dr)
	await sleep(0.4)
	var pt := td.combat.player_target
	check(pt.hp.has("back_l"), "A's own mech has a back_l component")
	var nh2 := hits.size()
	var bl: Vector3 = m.global_transform * (PlayerTarget.hardpoint_spheres("bulwark")["back_l"]["center"] as Vector3)
	command(b, "fire", {"target": bl, "idx": 9500})
	await until(func() -> bool: return hits.slice(nh2).any(func(h: Dictionary) -> bool: return str(h["comp"]) == "back_l"), 5.0)
	var on_bl := hits.slice(nh2).filter(func(h: Dictionary) -> bool: return str(h["id"]) == net.local_shooter and str(h["comp"]) == "back_l")
	eq(on_bl.size(), 1, "A applied B's shell on its own back_l once")
	await sleep(0.6)
	var v4 := await _collect(b, "back")
	check(float((v4.get("puppet_comp", {}) as Dictionary).get("back_l", 1.0)) < 0.99,
		"B's puppet of A shows back_l damaged (%s)" % str(v4.get("puppet_comp", {})))
	eq((v4.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == net.local_shooter).size(), 0,
		"B built no Hit on A's puppet")
	pt.apply_damage(PlayerTarget.WEAPON_HP * 2.0, "back_l", "test")
	check(pt.is_slot_destroyed("back_l"), "A's back_l destroyed")
	for i in rack.slot_count():
		rack.set_enabled(i + 1, true)
	var n5 := fired.size()
	rack.aim_point = pb.mech.global_position + pb.mech.up() * 4.4
	rack.set_trigger(true)
	await sleep(0.5)
	rack.set_trigger(false)
	eq(fired.slice(n5).filter(func(f: Dictionary) -> bool: return f["hp"] == "back_l").size(), 0, "A's destroyed back_l mortar stops firing")
	check(fired.slice(n5).filter(func(f: Dictionary) -> bool: return f["hp"] == "back_r").size() > 0, "its back_r mortar keeps firing")
	await sleep(0.6)
	var v5 := await _collect(b, "destroyed")
	near(float((v5.get("puppet_comp", {}) as Dictionary).get("back_l", 1.0)), 0.0, 0.01, "B's puppet of A shows back_l destroyed")
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 150.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), _state())
			"advance":
				await _advance()
				report("ack_advance", true)
			"repair":
				td.combat.player_target.repair_all()
				hits.clear()                 # each phase reports its own hits and arrivals
				got.clear()
				report("ack_repair_%s" % str(c["k"]), true)
			"fire":
				var o := td.mech.global_position + td.mech.up() * 4.4
				o += ((c["target"] as Vector3) - o).normalized() * 3.0
				var p := CombatWorld.local_peer()
				world.fire(Combat.fire_record("player%d" % p, p, "side_l", "autocannon", o, c["target"], world.now, int(c["idx"]), 0.0))


# --- Shared ----------------------------------------------------------------------------------------------

func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null, "the crew mission runs CombatNet"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	world = td.combat.world
	world.use_physics = false        # the city never blocks a line: this is about the weapons and the wire
	net = td.combat.net
	world.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == net.local_shooter:
			fired.append({"key": Combat.shot_key(rec), "hp": str(rec["hardpoint"]), "weapon": str(rec["weapon"])}))
	net.remote_fired.connect(func(rec: Dictionary, _e: CombatEffect) -> void:
		got.append({"key": Combat.shot_key(rec), "hp": str(rec["hardpoint"]), "weapon": str(rec["weapon"]), "shooter": str(rec["shooter"])}))
	net.remote_drone.connect(func(rec: Dictionary, _d: RepairDrone) -> void: drones.append(str(rec.get("hardpoint", ""))))
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		hits.append({"id": t.target_id, "dmg": h.damage, "shot": h.shot, "comp": h.component}))
	world.remote_hit.connect(func(id: String, _h: Hit) -> void: remote_hits.append(id))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return check(await until(_puppets_shown, 10.0), "every puppet is shown")


func _puppets_shown() -> bool:
	for p: int in td.crew_sync.puppets:
		if (td.crew_sync.puppets[p] as MechPuppet).shown == null:
			return false
	return td.crew_sync.puppets.size() == peers - 1


## B: walk straight ahead until DIST m from A's puppet (at most 6 s), then stop.
func _advance() -> void:
	var a: MechPuppet = null
	for p: int in td.crew_sync.puppets:
		a = td.crew_sync.puppets[p]
	var t := 0.0
	while t < 6.0 and a != null and td.mech.global_position.distance_to(a.mech.global_position) < DIST:
		td.mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	td.mech.move_input = Vector2.ZERO
	for i in 30:
		await get_tree().physics_frame


func _state() -> Dictionary:
	var pc := {}
	var chassis := ""
	for p: int in td.crew_sync.puppets:
		var pp: MechPuppet = td.crew_sync.puppets[p]
		pc = pp.components.duplicate()
		if pp.rig != null and pp.rig.model != null:
			chassis = pp.rig.model.chassis_id
	return {"got": got, "hits": hits, "own_lost": _lost(td.combat.player_target), "puppet_comp": pc, "puppet_chassis": chassis,
		"drones": drones}


static func _lost(t: CombatTarget) -> float:
	var s := 0.0
	for k: String in t.max_hp:
		s += float(t.max_hp[k]) - float(t.hp.get(k, 0.0))
	return s


func _collect(p: int, key: String) -> Dictionary:
	command(p, "report", {"key": key})
	check(await wait_reports(key, 1, 15.0), "the client reports %s" % key)
	return reported(p, key) if p in peers_with(key) else {}
