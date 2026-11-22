extends NetTest
## The crew mission in the multi-deck city stack (W2, docs/networking.md "Mission"), over a real crew, once per link:
## - the host launches in stack mode (Session.start_mission(seed, NetMission.MODE_STACK)): the launch carries the mode;
## - every machine builds the stack (TestDrive.stack), the load barrier compares CityStack.checksum(), and every machine
##   lands on the host's seed, mode and stack checksum (and the same entry transform);
## - each machine's own mech spawns on the entry road: at TestDrive.entry_spawn(entry, entry deck, seat, n), within a few
##   metres of CityStack.entry_transform(), on the entry deck (CityStack.deck_at), inside that deck's plan, standing on
##   the floor (grounded, height ~0) after a couple of seconds, and no two mechs overlap (the host compares every pair of
##   the owners' true positions).
## - Session.broadcast_event (host relay): every machine broadcasts once; every machine hears each other machine's exactly
##   once, named by its real sender (a client's reaches the other clients through the host).
## - ambient life (W5): every machine has exactly one AmbientLife (td.life, group "ambient_life") over the stack, with the
##   host's civilian / vehicle ids and the same tally after the settle.
## The scenario for test_net_stack (2) and test_net_stack_3 (3: the second row of the crew layout). Not a test itself.

const SEED := 23
const SETTLE := 2.0          ## s after mission_go before each machine reports where its mech stands
const SPAWN_TOL := 0.75      ## m between the mech and its entry_spawn() slot after settling
const MIN_GAP := 4.4         ## m between any two mechs (the capsule is 4.4 m across)

var td: TestDrive
var heard: Dictionary = {}   ## broadcast_event: sender peer -> times heard (each one's data names its sender)


func run_host() -> void:
	net_timeout = 85.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0),
			"the crew gathers (%d of %d)" % [Session.roster.size(), peers]):
		return
	check(Session.start_mission(SEED, NetMission.MODE_STACK), "the host launches the mission in the stack")
	eq(str(Session.mission_params().get("mode", "")), NetMission.MODE_STACK, "the launch carries the stack mode")
	if not await _load_and_go():
		return
	var mine := await _where()
	_judge_one(mine, "the host")
	mine["heard"] = await _broadcast()
	_judge_heard(mine, "the host")
	if not check(await wait_reports("stack", peers - 1, 40.0), "every client reports its stack"):
		return
	var all: Array[Dictionary] = [mine]
	for p in peers_with("stack"):
		var theirs: Dictionary = reported(p, "stack")
		all.append(theirs)
		_judge_one(theirs, "peer %d" % p)
		_judge_heard(theirs, "peer %d" % p)
		eq(int(theirs["seed"]), SEED, "peer %d built the mission seed" % p)
		eq(str(theirs["mode"]), NetMission.MODE_STACK, "peer %d built the stack" % p)
		eq(str(theirs["checksum"]), str(mine["checksum"]), "peer %d has the host's stack checksum" % p)
		check((theirs["entry"] as Vector3).distance_to(mine["entry"] as Vector3) < 0.01, "peer %d has the host's entry transform" % p)
		eq(int(theirs["lives"]), 1, "peer %d runs exactly one AmbientLife" % p)
		eq(str(theirs["life"]), str(mine["life"]), "peer %d has the host's civilian and vehicle ids" % p)
		eq(str(theirs["tally"]), str(mine["tally"]), "peer %d has the host's life tally" % p)
	eq(int(mine["seed"]), SEED, "the host built the mission seed")
	eq(int(mine["lives"]), 1, "the host runs exactly one AmbientLife")
	check(str(mine["life"]).length() > 4, "the stack has civilians")
	eq(int(mine["decks"]) > 1, true, "the stack has several decks (%d)" % int(mine["decks"]))
	for i in all.size():
		for j in range(i + 1, all.size()):
			var a: Vector3 = all[i]["pos"]
			var b: Vector3 = all[j]["pos"]
			check(a.distance_to(b) >= MIN_GAP, "mechs of peers %d and %d don't overlap (%.2f m apart)"
				% [int(all[i]["peer"]), int(all[j]["peer"]), a.distance_to(b)])
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 85.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	eq(str(Session.mission_params().get("mode", "")), NetMission.MODE_STACK, "the launch carries the stack mode")
	if not await _load_and_go():
		return
	var r := await _where()
	r["heard"] = await _broadcast()
	report("stack", r)


## Broadcast once and wait to hear everyone else's (2 s at most): {sender: count} with a mismatch counted as -100.
func _broadcast() -> Dictionary:
	await sleep(0.3)   # every machine is listening (connected at load)
	Session.broadcast_event("probe.bcast", {"peer": Session.local_id()})
	await until(func() -> bool: return heard.size() >= peers - 1, 4.0)
	await sleep(0.3)   # a duplicate would show up here
	var out := {}
	for p: int in heard:
		out[str(p)] = heard[p]
	return out


func _judge_heard(r: Dictionary, who: String) -> void:
	var h: Dictionary = r["heard"]
	eq(h.size(), peers - 1, "%s heard every other machine's broadcast (%s)" % [who, str(h)])
	for k: String in h:
		eq(int(h[k]), 1, "%s heard peer %s's broadcast once, from its real sender" % [who, k])


## Load the test drive at start_t and wait for the barrier. Enemies are cleared: nothing may push a mech off its spot.
func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	Session.event_received.connect(func(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
		if kind == "probe.bcast":
			heard[from] = int(heard.get(from, 0)) + (1 if int(data.get("peer", -1)) == from else -100))
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.stack != null and td.city != null, "the crew mission builds the stack (td.city = entry deck)"):
		return false
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes (phase %s)" % Session.mission.phase):
		return false
	return true


## Where this machine's own mech stands after SETTLE seconds, with what it built.
func _where() -> Dictionary:
	await sleep(SETTLE)
	var st := td.stack
	var k := int(st.section.entry["deck"])
	var entry := st.entry_transform()
	var seat := td.spawn_order.find(Session.local_id())
	var slot := td.crew_spawn(seat, td.spawn_order.size())
	var p := td.mech.global_position
	var arc := td.city.ring.world_to_arc(td.city.to_local(p))
	return {"peer": Session.local_id(), "seed": td.seed_value, "mode": td.city_mode, "checksum": td.mission_checksum(),
		"decks": st.decks.size(), "entry": entry.origin, "pos": p, "slot": slot.origin,
		"from_entry": p.distance_to(entry.origin), "deck": st.deck_at(p), "entry_deck": k,
		"in_plan": td.city.plan.extent.has_point(Vector2(arc.x, arc.y)), "height": arc.z,
		"grounded": td.mech.grounded(), "is_city": td.city == st.decks[k],
		"life": str(td.life.ids()) + "|" + str(td.life.vehicle_ids()) if td.life != null else "",
		"tally": str(td.life.tally()) if td.life != null else "",
		"lives": get_tree().get_nodes_in_group("ambient_life").size()}


func _judge_one(r: Dictionary, who: String) -> void:
	check((r["pos"] as Vector3).distance_to(r["slot"] as Vector3) < SPAWN_TOL, "%s's mech stands in its entry slot (%.2f m off)"
		% [who, (r["pos"] as Vector3).distance_to(r["slot"] as Vector3)])
	check(float(r["from_entry"]) < 16.0, "%s's mech is on the entry road (%.1f m from the entry)" % [who, float(r["from_entry"])])
	eq(int(r["deck"]), int(r["entry_deck"]), "%s's mech is on the entry deck" % who)
	check(bool(r["in_plan"]), "%s's mech is inside the entry deck's plan" % who)
	check(absf(float(r["height"])) < 1.0, "%s's mech stands on the floor (height %.2f)" % [who, float(r["height"])])
	check(bool(r["grounded"]), "%s's mech is grounded" % who)
	check(bool(r["is_city"]), "%s: td.city is the stack's entry deck" % who)
