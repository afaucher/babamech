extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Friendly fire across machines (docs/design/weapons.md §4.6, §5.1) over a real crew mission of 2, once per link. The
## host (A) shoots client c1 (B), both team "player". No new message: A's fire record is simulated on B's machine, and
## B decides about its own mech (CombatWorld.decides), exactly as for enemy fire.
## 1. ON (world.friendly_fire true on both machines): A fires an autocannon shell into B's mech. On B, B's own
##    PlayerTarget takes the hit exactly once (hit_landed on player<B>, A's shot key, the shell's damage). On A, nothing
##    is applied (no hit_landed, no remote_hit for player<B>), the impact is drawn on the puppet, and the puppet's HP
##    drops by that one shell only through B's streamed snapshot.
## 2. OFF (false on both): A fires the same kind of shell into B. B loses nothing more on either machine, no Hit anywhere.

const PEERS := 2
const SEED := 11

var td: TestDrive
var world: CombatWorld
var hits: Array = []               ## hit_landed: {id, dmg, shot}
var remote_hits: Array = []        ## remote_hit target ids
var impacts: Array = []            ## [now, point]


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	if not check(await wait_reports("ready", peers - 1, 30.0), "the client is ready (puppet shown)"):
		return
	var b := -1
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			b = int(e["peer"])
	var pb: MechPuppet = td.crew_sync.puppets.get(b)
	var tb: PlayerTarget = td.crew_sync.targets.get(b)
	if not check(pb != null and tb != null, "the host has B's puppet and its target"):
		return
	check(tb.team == "player" and td.combat.player_target.team == "player", "both mechs are team player")
	var dmg := float(world.stats("autocannon")["damage"])

	# 1. ON -----------------------------------------------------------------------------------------------------
	_set_ff(b, true)
	check(await wait_reports("ack_ff_true", 1, 15.0), "B set friendly fire on")
	var rh := _shot_at(pb, 9400)
	var n1 := impacts.size()
	world.fire(rh)
	await sleep(1.5)
	var v1 := await _collect(b, "on")
	var own: Array = (v1.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
	eq(own.size(), 1, "on: B applied A's shell to its own mech exactly once")
	if own.size() == 1:
		eq(str(own[0]["shot"]), Combat.shot_key(rh), "on: B's hit is A's shot")
		near(float(own[0]["dmg"]), dmg, 1e-3, "on: B took the shell's damage")
	near(float(v1.get("own_hp_lost", -1.0)), dmg, 1e-3, "on: B's own HP went down by one shell (decided by B)")
	var mine: Array = hits.filter(func(h: Dictionary) -> bool: return str(h["id"]) == "player%d" % b)
	eq(mine.size(), 0, "on: A built no Hit on B's puppet")
	check(not ("player%d" % b) in remote_hits, "on: A sent no remote hit for B")
	var aim_b := pb.mech.global_position + pb.mech.up() * 4.4
	var drawn := false
	for i in range(n1, impacts.size()):
		if (impacts[i][1] as Vector3).distance_to(aim_b) < 4.0:
			drawn = true
	check(drawn, "on: A draws the impact on B's puppet")
	check(await until(func() -> bool: return absf(_lost(tb) - dmg) < 2.0, 5.0),
		"on: A's puppet of B shows the loss through B's streamed HP (%.1f, want %.1f)" % [_lost(tb), dmg])
	var puppet_lost := _lost(tb)
	var b_lost := float(v1.get("own_hp_lost", 0.0))

	# 2. OFF ----------------------------------------------------------------------------------------------------
	_set_ff(b, false)
	check(await wait_reports("ack_ff_false", 1, 15.0), "B set friendly fire off")
	var hits_before := hits.size()
	var rh2 := _shot_at(pb, 9401)
	world.fire(rh2)
	await sleep(1.5)
	var v2 := await _collect(b, "off")
	var own2: Array = (v2.get("hits", []) as Array).filter(func(h: Dictionary) -> bool: return str(h["shot"]) == Combat.shot_key(rh2))
	eq(own2.size(), 0, "off: B applied nothing from A's second shell")
	near(float(v2.get("own_hp_lost", -1.0)), b_lost, 1e-6, "off: B's own HP is unchanged")
	eq(hits.size(), hits_before, "off: A applied nothing either")
	check(not ("player%d" % b) in remote_hits, "off: A sent no remote hit for B")
	await sleep(0.5)
	near(_lost(tb), puppet_lost, 1e-3, "off: A's puppet of B shows no further loss")
	command(b, "finish", {})
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
	report("ready", true)
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"ff":
				world.friendly_fire = bool(c["on"])
				report("ack_ff_%s" % str(bool(c["on"])), true)
			"report":
				report(str(c["key"]), {"hits": hits, "remote_hits": remote_hits, "own_hp_lost": _lost(td.combat.player_target)})


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
	world = td.combat.world
	check(world.friendly_fire, "friendly fire is on by default in a crew mission")
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: hits.append({"id": t.target_id, "dmg": h.damage, "shot": h.shot}))
	world.remote_hit.connect(func(id: String, _h: Hit) -> void: remote_hits.append(id))
	world.impact_spawned.connect(func(p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append([world.now, p]))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return check(await until(func() -> bool:
		for p: int in td.crew_sync.puppets:
			if (td.crew_sync.puppets[p] as MechPuppet).shown == null:
				return false
		return td.crew_sync.puppets.size() == peers - 1, 10.0), "every puppet is shown")


## An autocannon record from just in front of the host's mech into the puppet's torso.
func _shot_at(pb: MechPuppet, idx: int) -> Dictionary:
	var m := td.mech
	var up := m.up()
	var aim := pb.mech.global_position + pb.mech.up() * 4.4
	var from := m.global_position + up * 4.4
	var o := from + (aim - from).normalized() * 3.0
	var p := CombatWorld.local_peer()
	return Combat.fire_record("player%d" % p, p, "side_l", "autocannon", o, aim, world.now, idx, 0.0)


func _set_ff(b: int, on: bool) -> void:
	world.friendly_fire = on
	command(b, "ff", {"on": on})


func _collect(b: int, key: String) -> Dictionary:
	command(b, "report", {"key": key})
	check(await wait_reports(key, 1, 15.0), "B reports %s" % key)
	var v: Variant = reported(b, key)
	return v if v is Dictionary else {}


static func _lost(t: CombatTarget) -> float:
	var s := 0.0
	for k: String in t.max_hp:
		s += float(t.max_hp[k]) - float(t.hp.get(k, 0.0))
	return s
