extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Downed, revive, respawn across machines (DownedRules, PlayerTarget, RepairDrone's revive beam, the mech snapshot's
## downed / redeploying / revive / aid fields: NetMechCodec), a real crew mission of 3, once per link (off, coast).
## Host A, client c1 = B (carries a repair drone), client c2 = C (goes down).
## 1. C walks up beside B and goes down: every machine sees C's downed flag (its puppet target on A and B), A's and B's
##    DownedCrew list C in downed_crew() with a "DOWN  <name>" marker on the wreck, and B (a reviver) reads the
##    "<name> is down: revive with a repair drone" line; the host's crew facts and pacing facts see C downed.
## 2. B launches its drone (WeaponRack.activate, CombatNet's one event): C's OWN machine revives C exactly once (its
##    player_revived), nobody else applies anything (no revive signal on A's or B's puppet of C), and after the snapshots
##    every machine agrees on C's component HP (within one snapshot step).
## 3. Once B's drone has flown home, C goes down again and holds the respawn key: A sees C redeploying (puppet flag, crew
##    facts redeploying, pacing facts disabled), then C stands at its respawn point FULLY restored (R2.12: every
##    component at 100 %, incl. the weapon hardpoint C destroyed before going down: its weapon is usable again on C's own
##    rack), and A and B agree with C on its position and its component HP (structure rides C's mech snapshot, so every
##    machine sees the rebuilt hardpoint). AMMO is not replicated (WeaponMount.ammo is the owner's, never in the
##    snapshot: a puppet shows only the barrel pose), so only C's own rack is checked for the refill.

const PEERS := 3
const SEED := 11
const POS_TOL := 1.0              ## m: a puppet vs its owner (both standing still)
const HP_TOL := 0.012             ## component fraction: one snapshot step (1/254) plus rounding
const LIFE := 8.0                 ## s: the drone's life here (overrides the catalog's 60 on every machine)

var td: MissionScene
var world: CombatWorld
var revives := 0                  ## player_revived on this machine's OWN target
var puppet_revives := 0           ## player_revived on any puppet target here (must stay 0)
var respawns := 0


func run_host() -> void:
	net_timeout = 120.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 40.0), "the clients are ready"):
		return
	var b := -1
	var c := -1
	for p: int in peers_with("ready"):
		var ix := int((reported(p, "ready") as Dictionary)["index"])
		if ix == 1:
			b = p
		elif ix == 2:
			c = p
	if not check(b > 0 and c > 0, "B and C known (%d, %d)" % [b, c]):
		return
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var pc: MechPuppet = td.crew_sync.puppets.get(c)
	var tc: PlayerTarget = td.crew_sync.targets.get(c)
	if not check(pb != null and pc != null and tc != null, "the host has B's and C's puppets"):
		return
	tc.player_revived.connect(func(_by: String, _t: float) -> void: puppet_revives += 1)
	# 1. C goes down beside B.
	command(c, "near", {"to": pb.mech.global_position + pb.mech.global_basis.x * 6.0})
	if not check(await wait_reports("near", 1, 10.0), "C moved beside B"):
		return
	await sleep(0.6)
	check(pc.mech.global_position.distance_to(pb.mech.global_position) < 12.0, "C stands within the drone's reach of B")
	command(c, "down", {})
	if not check(await wait_reports("down", 1, 10.0), "C went down"):
		return
	check(await until(func() -> bool: return tc.disabled, 5.0), "A sees C downed (puppet target)")
	var dc := td.downed
	var listed := false
	for e: Dictionary in dc.downed_crew():
		listed = listed or (int(e["peer"]) == c and (e["pos"] as Vector3).distance_to(pc.mech.global_position) < 0.5)
	check(listed, "A's downed_crew() lists C at its wreck")
	var marks: Array = dc.hud_state()["marks"]
	check(marks.size() == 1 and str((marks[0] as Dictionary)["label"]).begins_with("DOWN  "), "A shows one DOWN marker (%s)" % [marks])
	var cf := _fact_of(c)
	check(bool(cf.get("downed", false)) and not bool(cf.get("redeploying", true)), "the host's crew facts: C downed (%s)" % [cf])
	var pf := _pacing_of(c)
	check(bool(pf.get("disabled", false)) and not bool(pf.get("engaged", true)), "the host's pacing facts: C disabled, not engaged (%s)" % [pf])
	command(b, "look", {"peer": c})
	if check(await wait_reports("look", 1, 10.0), "B reports its view"):
		var vb: Dictionary = reported(b, "look")
		check(bool(vb["downed"]), "B sees C downed")
		check(bool(vb["listed"]), "B's downed_crew() lists C")
		check(str(vb["line"]).ends_with("is down: revive with a repair drone"), "B reads the revive line (%s)" % vb["line"])
		check(bool(vb["can"]), "B can revive (a drone with charges)")
	# 2. B revives C.
	command(b, "launch", {})
	if not check(await wait_reports("launch", 1, 10.0), "B launched its drone"):
		return
	check(bool(reported(b, "launch")), "B's drone is out")
	check(await until(func() -> bool: return not tc.disabled, 12.0), "A sees C revived")
	await sleep(0.8)
	command(c, "state", {"key": "revived"})
	command(b, "state", {"key": "revived", "peer": c})
	if check(await wait_reports("revived", 2, 10.0), "B and C report after the revive"):
		var vc: Dictionary = reported(c, "revived")
		var vbb: Dictionary = reported(b, "revived")
		eq(int(vc["revives"]), 1, "C's own machine applied the revive exactly once")
		eq(int(vc["respawns"]), 0, "and no respawn")
		eq(int(vbb["puppet_revives"]), 0, "B applied nothing to C (no revive on its puppet target)")
		eq(puppet_revives, 0, "A applied nothing to C")
		check(float((vc["hp"] as Dictionary)["head"]) >= DownedRules.REVIVE_STRUCTURE - HP_TOL, "C stands with its head rebuilt")
		_agree(vc["hp"] as Dictionary, tc, "A after the revive")
		_agree_dict(vc["hp"] as Dictionary, vbb["hp"] as Dictionary, "B after the revive")
	# 3. B's drone (life shortened to LIFE s on every machine) flies home; C goes down again and holds to respawn.
	check(await until(func() -> bool: return world.drone_of("player%d" % b) == null, LIFE + 6.0), "B's drone flew home")
	await sleep(0.5)
	command(c, "down", {"hold": true, "break": "side_l"})
	check(await until(func() -> bool: return tc.redeploying, 8.0), "A sees C redeploying after the hold")
	cf = _fact_of(c)
	check(bool(cf.get("downed", false)) and bool(cf.get("redeploying", false)), "the host's crew facts: C redeploying (%s)" % [cf])
	pf = _pacing_of(c)
	check(bool(pf.get("disabled", false)), "the host's pacing facts: C still out (%s)" % [pf])
	check(td.downed.downed_crew().is_empty(), "a redeploying pilot is not revivable (no marker)")
	check(await until(func() -> bool: return not tc.disabled, DownedRules.RESPAWN_PENALTY + 4.0), "A sees C respawned")
	await sleep(0.8)
	command(c, "state", {"key": "respawned"})
	command(b, "state", {"key": "respawned", "peer": c})
	if check(await wait_reports("respawned", 2, 10.0), "B and C report after the respawn"):
		var vc2: Dictionary = reported(c, "respawned")
		var vb2: Dictionary = reported(b, "respawned")
		eq(int(vc2["respawns"]), 1, "C respawned once")
		for k: String in (vc2["hp"] as Dictionary):
			near(float(vc2["hp"][k]), 1.0, 0.01, "C's %s at full (R2.12)" % k)
		check((vc2["hp"] as Dictionary).has("side_l"), "C's snapshot carries the side_l hardpoint")
		check(bool(vc2.get("side_l_usable", false)), "C's own rack: the rebuilt side_l weapon is usable again")
		check(bool(vc2.get("ammo_full", false)), "C's own rack: every limited-ammo weapon full (%s)" % str(vc2.get("ammo", [])))
		_agree(vc2["hp"] as Dictionary, tc, "A after the respawn")
		_agree_dict(vc2["hp"] as Dictionary, vb2["hp"] as Dictionary, "B after the respawn")
		var off_a := pc.mech.global_position.distance_to(vc2["pos"] as Vector3)
		var off_b := (vb2["pos"] as Vector3).distance_to(vc2["pos"] as Vector3)
		print("[downed] %s: C respawned at %s; A's puppet %.2f m off, B's %.2f m off" % [link, vc2["pos"], off_a, off_b])
		check(off_a < POS_TOL, "A agrees on C's position (%.2f m)" % off_a)
		check(off_b < POS_TOL, "B agrees on C's position (%.2f m)" % off_b)
	for p: int in [b, c]:
		command(p, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 120.0
	if index == 1:
		var lo := Session.local_loadout()
		lo["back"] = "repair_drone"
		Session.set_profile(Session.player_name, Session.local_head(), Session.local_chassis(), "", lo)
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	report("ready", {"index": index})
	while true:
		var c := await wait_command(90.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		var data: Dictionary = c.get("data", {}) if c.get("data") is Dictionary else c
		match str(c["cmd"]):
			"finish":
				return
			"near":
				var to: Vector3 = data["to"]
				var up := td.mech.up()
				td.mech.global_position = to + up * 1.0
				td.mech.velocity = Vector3.ZERO
				MechSpawn.rig_of(td.mech).gait.reset([])
				await sleep(0.4)
				report("near", td.mech.global_position)
			"down":
				var pt := td.combat.player_target
				var brk := str(data.get("break", ""))
				if brk != "":
					for i in td.combat.rack.slot_count():   # R2.12: empty every limited-ammo weapon too
						var wm := td.combat.rack.mounts[i] as WeaponMount
						if wm != null and td.combat.rack.ammo_max[i] >= 0:
							wm.ammo = 0
					pt.apply_damage(1000.0, brk, "test")
				pt.apply_damage(300.0, "torso", "test")
				pt.apply_damage(1000.0, "head", "test")
				pt.respawn_held = bool(data.get("hold", false))
				report("down", pt.disabled)
				if pt.respawn_held:
					await until(func() -> bool: return pt.redeploying, DownedRules.RESPAWN_HOLD + 3.0)
					pt.respawn_held = false
			"look":
				var p := int(data["peer"])
				var tg := td.downed.target_of(p)
				await until(func() -> bool: return tg != null and tg.disabled, 3.0)   # the host forwards C's snapshot
				var listed := false
				for e: Dictionary in td.downed.downed_crew():
					listed = listed or int(e["peer"]) == p
				var lines: Array = td.downed.hud_state()["lines"]
				report("look", {"downed": tg != null and tg.disabled, "listed": listed,
					"line": str(lines[0]) if not lines.is_empty() else "", "can": td.downed.can_revive(Session.local_id())})
			"launch":
				var rack := td.combat.rack
				var n := rack.hardpoints.find("back") + 1
				var ok := n > 0 and rack.activate(n)
				report("launch", ok and world.drone_of(rack.shooter) != null)
			"state":
				var p2 := int(data.get("peer", Session.local_id()))
				var tg2 := td.downed.target_of(p2)
				var m2 := td.mech if p2 == Session.local_id() else td.mech_of(p2)
				var rk := td.combat.rack
				var ammo: Array = []
				var full := true
				for i in rk.slot_count():
					var wm2 := rk.mounts[i] as WeaponMount
					if wm2 != null and rk.ammo_max[i] >= 0:
						ammo.append([rk.weapons[i], wm2.ammo, rk.ammo_max[i]])
						full = full and wm2.ammo == rk.ammo_max[i]
				var sl := rk.hardpoints.find("side_l") + 1
				report(str(data["key"]), {"revives": revives, "respawns": respawns, "puppet_revives": puppet_revives,
					"hp": tg2.component_fractions() if tg2 != null else {}, "pos": m2.global_position if m2 != null else Vector3.ZERO,
					"side_l_usable": sl > 0 and rk.usable(sl), "ammo": ammo, "ammo_full": full})


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.crew_sync != null and td.combat.net != null and td.downed != null, "the crew mission runs with DownedCrew"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	world.overrides["repair_drone"] = {"life": LIFE}
	td.combat.player_target.player_revived.connect(func(_by: String, _t: float) -> void: revives += 1)
	td.combat.player_target.player_respawned.connect(func(_t: float, _held: bool) -> void: respawns += 1)
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	if not check(await until(func() -> bool: return td.crew_sync.puppets.size() == peers - 1, 10.0), "the puppets exist"):
		return false
	for p: int in td.crew_sync.targets:
		(td.crew_sync.targets[p] as PlayerTarget).player_revived.connect(func(_by: String, _t: float) -> void: puppet_revives += 1)
	td.combat.squad.clear_enemies()
	return true


func _fact_of(peer: int) -> Dictionary:
	if td.mission == null:
		return {}
	for f: Dictionary in td.mission.crew_facts():
		if int(f["peer"]) == peer:
			return f
	return {}


## The host's pacing facts for peer (PacingFacts.collect over every pilot, as MissionFlow feeds the director).
func _pacing_of(peer: int) -> Dictionary:
	if td.mission == null:
		return {}
	var crew_f := td.mission.crew_facts()
	var members: Array = td.crew_members()
	var pilots: Array = []
	for i in mini(members.size(), crew_f.size()):
		pilots.append({"peer": crew_f[i]["peer"], "target": td.downed.target_of(int(crew_f[i]["peer"])),
			"mech": members[i]["mech"], "deck": crew_f[i]["deck"], "downed": crew_f[i]["downed"]})
	var pacing := PacingFacts.new()
	pacing.bind(world, func() -> float: return world.now)
	var pf: Dictionary = pacing.collect(pilots, td.stack, [], td.stack.decks.size())
	return (pf.get("pilots", {}) as Dictionary).get(str(peer), {})


func _agree(theirs: Dictionary, t: PlayerTarget, tag: String) -> void:
	var mine := t.component_fractions()
	for k: String in theirs:
		near(float(mine.get(k, -1.0)), float(theirs[k]), HP_TOL, "%s: %s agrees" % [tag, k])


func _agree_dict(theirs: Dictionary, mine: Dictionary, tag: String) -> void:
	for k: String in theirs:
		near(float(mine.get(k, -1.0)), float(theirs[k]), HP_TOL, "%s: %s agrees" % [tag, k])
