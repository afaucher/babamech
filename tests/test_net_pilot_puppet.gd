extends NetTest
## Teammates' pilot heads across machines (integration plan W7, docs/design/pilot-heads.md §7), host + 1 client, once per
## link. The host (B) judges what it shows of the client's (A's) mech: the puppet's head and accent are A's roster
## profile; CrewSync gave it a PilotPuppetLink; MechRig feeds its head; A's streamed overheat makes A's head overheated
## on B; A firing (a real fire record, carried by CombatNet) makes A's head on B fire / look at A's streamed aim; an enemy
## shot struck A's puppet on B (the host runs the enemies; A decides the damage, B shows the impact) flinches A's head
## on B without damaging the puppet here. A damaging its own mech (PlayerTarget.apply_damage on A, the owner's verb)
## reaches B only through A's snapshot (component HP + disabled): the HP drop flinches (no shot drawn on B: the streamed
## drop is the hit signal), low torso -> afraid, a leg lost (downed) -> pain +
## dazed, repaired -> revived, on A's head on B.
## Not covered (not built yet): the same enemy shot reaching A's machine and damaging A (enemy shots across machines,
## W4); here A damages itself on command instead.

const PEERS := 2
const SEED := 11

var td: TestDrive


func run_host() -> void:
	net_timeout = 90.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var a := 0
	for p: int in Session.roster:
		if p != Session.local_id():
			a = p
	var pp := td.crew_sync.puppets.get(a) as MechPuppet
	if not check(pp != null and pp.rig != null, "B shows A's mech as a puppet"):
		return
	var link := pp.mech.get_node_or_null("PilotLink") as PilotPuppetLink
	if not check(link != null and link.puppet == pp and link.world == td.combat.world,
			"CrewSync gave A's puppet a PilotPuppetLink bound to it and the combat world"):
		return
	_profile_checks(a, pp)
	if not check(await until(func() -> bool: return pp.shown != null and link.pilot() != null, 15.0), "A's snapshots arrive"):
		return
	var h := link.pilot()
	h.idle_enabled = false
	await sleep(0.3)
	check(Engine.get_process_frames() - h._fed_frame <= 2 and not h.idle_always, "B's MechRig feeds A's puppet head")

	command(a, "heat")
	check(await until(func() -> bool: return h.mood() == "overheated", 10.0),
		"A's streamed overheat shows on A's head on B (mood %s, heat %.2f)" % [h.mood(), float(h.inputs().get("heat", 0.0))])
	command(a, "cool")
	check(await until(func() -> bool: return pp.shown.heat < 0.3 and h.mood() != "overheated", 10.0), "A cools down on B")

	command(a, "fire")
	var saw := [false, false]
	var fired_seen := func() -> bool:
		if bool(h._in["firing"]):
			saw[0] = true
			saw[1] = saw[1] or h._look_on
		return saw[0] and saw[1]
	check(await until(fired_seen, 10.0),
		"A's fire record reaches B and A's head on B fires and looks at A's aim (firing %s, look %s)" % [saw[0], saw[1]])

	await sleep(1.0)
	var torso := pp.mech.global_position + pp.mech.up() * 4.4
	var from := torso + pp.mech.forward() * 15.0 + pp.mech.up() * 2.0
	var rec := Combat.fire_record("enemy_w7", 1, "gun", "laser", from, torso, td.combat.world.now, 1)
	rec["team"] = "enemy"
	rec["enemy"] = true
	var before := float(pp.target.hp.get("torso", 0.0))
	check(not h.reacting("flinch"), "(no flinch before the shot)")
	td.combat.world.fire(rec)
	check(h.reacting("flinch"), "an enemy shot striking A's puppet on B flinches A's head on B")
	near(float(pp.target.hp.get("torso", 0.0)), before, 1e-3, "and B applies no damage to A's puppet (A decides)")

	# A damages its own mech through its PlayerTarget's verb (the owner decides); B sees it only through A's stream.
	await sleep(1.0)
	var flinched := link.flinches
	var hp_before := pp.hull
	command(a, "hurt")
	check(await until(func() -> bool: return link.flinches > flinched, 10.0),
		"A's HP drop with no shot drawn on B, streamed, flinches A's head on B (flinches %d -> %d, hull %.2f -> %.2f)" \
			% [flinched, link.flinches, hp_before, pp.hull])
	check(await until(func() -> bool: return h.mood() == "afraid", 10.0),
		"A's low torso, streamed, shows as afraid on A's head on B (mood %s, hull %.2f)" % [h.mood(), pp.hull])
	var seen := [false, false]
	var downed_seen := func() -> bool:
		seen[0] = seen[0] or h.reacting("pain")
		return seen[0] and h.mood() == "dazed"
	var revived_seen := func() -> bool:
		seen[1] = seen[1] or h.reacting("revived")
		return seen[1] and not pp.downed and h.mood() != "afraid"
	command(a, "down")
	check(await until(downed_seen, 10.0),
		"A losing a leg (downed), streamed, hurts and dazes A's head on B (pain %s, mood %s, downed %s)" \
			% [seen[0], h.mood(), pp.downed])
	command(a, "whole")
	check(await until(revived_seen, 10.0),
		"A repaired, streamed -> revived on B (revived %s, mood %s)" % [seen[1], h.mood()])

	command(a, "end")
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
	td.drive_override = true
	var m := td.mech
	var shot := 0
	while true:
		var c := await wait_command(40.0)
		match str(c.get("cmd", "")):
			"heat":
				while commands.is_empty() and not ended:
					m.heat = 0.95 * m.heat_cap
					await get_tree().physics_frame
			"cool":
				m.heat = 0.0
				m.shutdown = false
			"fire":
				var w := td.combat.world
				for i in 6:
					shot += 1
					var o := m.global_position + m.up() * 5.0 + m.forward() * 3.0
					w.fire(Combat.fire_record("player%d" % Session.local_id(), Session.local_id(), "side_l", "laser", o,
						o + m.forward() * 60.0 + m.up() * 3.0, w.now, 900 + shot))
					await sleep(0.25)
			"hurt":
				td.combat.player_target.auto_respawn_delay = -1.0   # stay down until "whole"
				td.combat.player_target.apply_damage(340.0, "torso", "w7_test")
			"down":
				td.combat.player_target.apply_damage(250.0, "leg_l", "w7_test")
			"whole":
				td.combat.player_target.repair_all()
			_:
				return


## The puppet's head and accent are A's roster profile; B's own mech is B's.
func _profile_checks(a: int, pp: MechPuppet) -> void:
	for e: Dictionary in Session.crew():
		var p := int(e["peer"])
		var model: MechModel = pp.rig.model if p == a else td.rig.model
		var who := "A's puppet" if p == a else "B's own mech"
		check(model.pilot != null and model.pilot.head_id == str(e["head"]),
			"%s wears its roster head %s (%s)" % [who, str(e["head"]), model.pilot.head_id if model.pilot != null else "none"])
		eq(MechAccent.applied(model), str(e.get("accent", "")), "%s wears its roster accent" % who)
	check(NetTest.head_for(1) != NetTest.head_for(0) and NetTest.accent_for(1) != NetTest.accent_for(0),
		"(the two profiles differ, so a swap would show)")


## Load the test drive at start_t and wait for the barrier; no enemies (nothing but the test's own shot may hit A).
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
		"the load barrier passes (phase %s)" % Session.mission.phase)
