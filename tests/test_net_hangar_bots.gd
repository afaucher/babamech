extends NetTest
## Hangar bots (docs/design/hangar-bots.md): the host seats an AI pilot before the client joins; the client sees it in
## the crew (flag, negative pilot id, name, head, seat) and the seats left; a second bot is added, re-skilled and removed.
## The mission launches: the load barrier never waits for the bot (NetMission.members), both machines build three mechs
## and derive the same bot loadout from the seed (BotLoadout.pick); the host runs the bot (CrewBot + MissionBot) and
## streams it, the client's puppet follows the host's mech (compared at the puppet's render time); the bot fights (fire
## records reach the client as "player<id>"); damage to the bot is decided and applied on the host only, and the
## client's puppet mirrors it from the snapshots.

const PEERS := 2
const LINKS := ["off"]
const NET_TIMEOUT := 420   # test_runner reads this literal
const SEED := 7          ## the first bot picks a railgun here (BotLoadout.pick(7, 1)): its charge glows must reach the client
const MOVE_TIMEOUT := 60.0
const FIRE_TIMEOUT := 150.0
const DEPOT_TIMEOUT := 90.0

var td: MissionScene
var _hist: Array = []          ## host: [t, position] of every bot state fed to the stream (its stamp: the puppet's time base)
const TRACK_TOL := 0.5         ## m: the puppet at its render time vs the bot then (test_net_snap's off-link bound)


func run_host() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	CombatWorld.dev_enemy_damage = 1.0
	var id := Session.add_bot("rookie")
	eq(id, -1, "the first bot's pilot id is -1")
	check(Session.is_bot(id) and not Session.roster.has(id), "the bot is in Session.bots, not the roster")
	eq(Session.seats_free(), 2, "host + bot leave two seats")
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the client joins"):
		return
	if check(await wait_reports("lobby", 1, 20.0), "the client reports its crew view"):
		var v: Dictionary = reported(peers_with("lobby")[0], "lobby")
		eq(str(v.get("bots", "")), "[-1]", "the client sees the bot")
		eq(int(v.get("bot_seat", 0)), 2, "the bot holds seat 2")
		eq(int(v.get("my_seat", 0)), 3, "the joiner took seat 3 (the bot's seat is skipped)")
		eq(str(v.get("bot_name", "")), str(Session.bots[id]["name"]), "the client sees the bot's name")
		eq(str(v.get("bot_head", "")), str(Session.bots[id]["head"]), "the client sees the bot's head")
		eq(int(v.get("free", -1)), 1, "the client sees one seat left")
	var id2 := Session.add_bot()
	eq(id2, -2, "a second bot takes slot 2")
	eq(Session.seats_free(), 0, "the crew is full (2 players + 2 bots)")
	eq(Session.add_bot(), 0, "a fifth seat is refused")
	check(Session.set_bot_skill("veteran"), "the host sets the bots' skill")
	eq(str(Session.bots[id]["skill"]), "veteran", "the skill reaches every bot")
	check(Session.remove_bot(id2), "the host removes the second bot")
	eq(Session.crew().size(), 3, "crew: host, bot, client")
	check(Session.mission.host_launch(SEED), "the host launches")
	eq(Session.remove_bot(id), false, "no bot changes during a mission")
	await _load()
	check(not Session.mission.members().has(id), "the load barrier doesn't wait for the bot")
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		return
	eq(td.mechs.size(), 3, "three mechs on the host")
	if not check(td.crew_bots.has(id), "the host runs the bot (CrewBot)"):
		return
	var cb := td.crew_bots[id] as CrewBot
	var pick := BotLoadout.pick(SEED, 1)
	eq(loadout_signature(cb.rig.model.loadout), loadout_signature(pick["loadout"]), "the bot flies its derived loadout")
	check(not cb.mech.puppet, "the bot's mech is simulated on the host")
	eq(cb.target.owner_peer, 1, "the bot's PlayerTarget is owned by the host")
	check(td.combat.world.owns(cb.target), "the host's world applies verbs to the bot")
	eq(td.crew_members().size(), 3, "crew_members lists the host, the bot and the client")
	var start := cb.mech.global_position
	check(await until(func() -> bool:
		_track(id)
		return cb.mech.global_position.distance_to(start) > 15.0, MOVE_TIMEOUT),
		"the bot walks off (%.1f m)" % cb.mech.global_position.distance_to(start))
	check(cb.ai != null, "its MissionBot runs (%s)" % (cb.ai.goal_text if cb.ai != null else "none"))
	# The client compares its puppet with the host's mech: keep the host's track while it reports.
	command(peers_with("lobby")[0], "track")
	var got := await until(func() -> bool:
		_track(id)
		return peers_with("track").size() >= 1, 20.0)
	if check(got, "the client reports its puppet track"):
		var worst := 0.0
		var sum := 0.0
		var n := 0
		for s: Variant in reported(peers_with("track")[0], "track") as Array:
			var t := float((s as Array)[0])
			var p: Vector3 = (s as Array)[1]
			if t < float(_hist[0][0]) or t > float(_hist[_hist.size() - 1][0]):
				continue   # outside the host's track
			var e := p.distance_to(_at(t))
			worst = maxf(worst, e)
			sum += e
			n += 1
		var tr: Array = reported(peers_with("track")[0], "track")
		var moved := (_at(float(tr[0][0])) as Vector3).distance_to(_at(float(tr[tr.size() - 1][0]))) if tr.size() > 1 else 0.0
		print("[Test] bot puppet track: %d samples, error at render time max %.3f m mean %.3f m, the bot moved %.1f m" % [n,
			worst, sum / maxf(n, 1), moved])
		check(moved > 4.0, "the bot moves while the client tracks it (%.1f m)" % moved)
		check(n > 30, "enough puppet samples inside the host's track (%d)" % n)
		# Compared on the stream's own clock (each fed state's stamp, as test_net_snap does): host_time() at the moment
		# the test polled was up to a step clock's ease (<= 0.25 s) off the stamp, which at the bot's 12 m/s read as 2 m.
		check(worst < TRACK_TOL, "the client's puppet follows the host's bot within %.1f m (worst %.3f m)" % [TRACK_TOL, worst])
	# Damage: the host decides (victim's owner). A verb on the host's target; the client must see it from the snapshot.
	var hull0 := float(cb.target.hp.get("torso", 0.0))
	cb.target.apply_damage(120.0, "torso", "test")
	check(float(cb.target.hp.get("torso", 0.0)) < hull0, "the host applied the damage to its bot")
	command(peers_with("lobby")[0], "damaged", {"hull": float(cb.target.hp["torso"]) / float(cb.target.max_hp["torso"])})
	# Fighting: the bot's rack fires on the host (and the records reach the client).
	var fired := [0]
	td.combat.world.fired.connect(func(r: Dictionary) -> void:
		if str(r.get("shooter", "")) == "player%d" % id:
			fired[0] += 1)
	check(await until(func() -> bool: return fired[0] > 0, FIRE_TIMEOUT), "the bot fires (%d records, %s)" % [fired[0],
		cb.ai.goal_text if cb.ai != null else ""])
	# The railgun's charge (a long charge: "combat.charge" with the bot's id) reaches the client as a glow.
	check(str(pick["loadout"]).contains("railgun"), "the test seed gives the bot a railgun (%s)" % str(pick["loadout"]))
	check(await until(func() -> bool: return int(td.combat.net.stats["charges_sent"]) > 0, FIRE_TIMEOUT),
		"the bot charges its railgun (charge events sent: %d)" % int(td.combat.net.stats["charges_sent"]))
	command(peers_with("lobby")[0], "fired")
	if check(await wait_reports("seen", 1, 40.0), "the client reports what it saw"):
		var v: Dictionary = reported(peers_with("seen")[0], "seen")
		check(bool(v.get("puppet", false)), "the client shows the bot as a puppet")
		eq(str(v.get("loadout", "")), loadout_signature(pick["loadout"]), "the client derived the same bot loadout")
		eq(str(v.get("accent", "")), str(td._bot_accents.get(id, "?")), "the client derived the same bot colour")
		check(str(td._bot_accents.get(id, "")) != str(Session.roster[1].get("accent", "")) and
			str(td._bot_accents.get(id, "")) != str(Session.roster[peers_with("seen")[0]].get("accent", "")),
			"the bot's colour differs from both players' (%s)" % str(td._bot_accents))
		eq(str(Session.bots[id].get("accent", "")), str(td._bot_accents.get(id, "?")), "the bot's crew entry carries its colour")
		eq(int(v.get("owner", 0)), 1, "the client's bot target is owned by the host")
		check(not bool(v.get("decides", true)), "the client never decides hits on the bot")
		check(bool(v.get("hull_ok", false)), "the client's puppet shows the host's damage (%s)" % str(v.get("hull", "")))
		check(int(v.get("records", 0)) > 0, "the bot's fire records reach the client (%d)" % int(v.get("records", 0)))
		check(int(v.get("charges", 0)) > 0, "the bot's railgun charge glow reaches the client (%d)" % int(v.get("charges", 0)))
	# Supply depot: the bot, badly hurt, walks to the nearest depot with cores and the host claims a core for it.
	var md: MissionDepots = td.mission.depots if td.mission != null else null
	if check(md != null, "plan mode has depots"):
		var granted := [false]
		md.bot_core_granted.connect(func(pid: int, _d: String) -> void:
			if pid == id:
				granted[0] = true)
		cb.target.repair_all()
		cb.target.apply_damage(cb.target.max_hp["torso"] * 0.7, "torso", "test")
		var near := md.nearest_with_cores(td.stack.deck_at(cb.mech.global_position), cb.mech.global_position)
		print("[Test] bot depot: nearest %s" % str(near))
		check(await until(func() -> bool: return granted[0] or cb.target.disabled, DEPOT_TIMEOUT),
			"the hurt bot walks to a depot and gets a core (visits %d, %s)" % [int(cb.ai.depot_visits), cb.ai.goal_text])
	command(peers_with("lobby")[0], "end")   # the client stays in the mission until the depot check is done
	print("[Test] bot: %s" % (str(cb.ai.stats()) if cb.ai != null else "none"))
	check(await wait_done(1, 30.0), "the client is done")


## Record bot `id`'s newest fed snapshot state (its stamp and position) once.
func _track(id: int) -> void:
	var st := Session.mechs.owned_state(id)
	if st != null and (_hist.is_empty() or st.t > float(_hist[_hist.size() - 1][0])):
		_hist.append([st.t, st.pos])


## The host's bot position at host time t (linear between the two samples around t; the nearest outside them).
func _at(t: float) -> Vector3:
	if _hist.is_empty():
		return Vector3.INF
	if t <= float(_hist[0][0]):
		return _hist[0][1]
	for i in range(1, _hist.size()):
		var t1 := float(_hist[i][0])
		if t <= t1:
			var t0 := float(_hist[i - 1][0])
			var f := (t - t0) / maxf(t1 - t0, 1e-6)
			return (_hist[i - 1][1] as Vector3).lerp(_hist[i][1] as Vector3, f)
	return _hist[_hist.size() - 1][1]


func run_client() -> void:
	net_timeout = float(NET_TIMEOUT) - 5.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return Session.bots.size() == 1, 10.0), "the bot is in the welcome / roster")
	var b: Dictionary = Session.bots.get(-1, {})
	report("lobby", {"bots": str(Session.bot_ids()), "bot_seat": int(b.get("seat", 0)), "my_seat": int(Session.local_entry().get("seat", 0)),
		"bot_name": str(b.get("name", "")), "bot_head": str(b.get("head", "")), "free": Session.seats_free()})
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 60.0), "the launch arrives"):
		return
	check(not Session.mission.params["crew"].filter(func(e: Dictionary) -> bool: return bool(e.get("bot", false))).is_empty(),
		"the launch crew carries the bot")
	await _load()
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING, 40.0), "the barrier passes"):
		return
	var records := [0]
	td.combat.net.remote_fired.connect(func(r: Dictionary, _e: CombatEffect) -> void:
		if str(r.get("shooter", "")) == "player-1":
			records[0] += 1)
	var pp := td.crew_sync.puppets.get(-1) as MechPuppet
	if not check(pp != null, "the client has a puppet for the bot"):
		return
	var cmd := await wait_command(MOVE_TIMEOUT + 20.0)
	eq(str(cmd.get("cmd", "")), "track", "the host asks for the track")
	var track: Array = []
	var until_t := wall() + 4.0
	while wall() < until_t:
		await get_tree().physics_frame
		if pp.shown != null:
			track.append([pp.shown.t, pp.mech.global_position])
	report("track", track)
	cmd = await wait_command(20.0)
	eq(str(cmd.get("cmd", "")), "damaged", "the host damaged the bot")
	var want := float(cmd.get("hull", 1.0))
	var hull_ok := await until(func() -> bool: return absf(pp.hull - want) < 0.02, 5.0)
	var pt := td.crew_sync.targets.get(-1) as PlayerTarget
	cmd = await wait_command(2.0 * FIRE_TIMEOUT + 10.0)
	eq(str(cmd.get("cmd", "")), "fired", "the host saw the bot fire")
	await until(func() -> bool: return records[0] > 0 and int(td.combat.net.stats["charges_recv"]) > 0, 5.0)
	report("seen", {"puppet": pp.mech.puppet, "accent": str(td._bot_accents.get(-1, "")), "loadout": loadout_signature(pp.rig.model.loadout),
		"owner": pt.owner_peer if pt != null else 0,
		"decides": td.combat.world.decides(pt, Session.local_id()) if pt != null else true,
		"hull_ok": hull_ok, "hull": "%.2f vs %.2f" % [pp.hull, want], "records": records[0],
		"charges": int(td.combat.net.stats["charges_recv"])})
	cmd = await wait_command(DEPOT_TIMEOUT + 30.0)
	eq(str(cmd.get("cmd", "")), "end", "the host finished its checks")


func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await until(func() -> bool: return td.loaded, 30.0)
