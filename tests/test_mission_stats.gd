extends TestCase
## The debrief's counters (MissionStats, docs/design/debrief-stats.md; playtest R2.15 / R2.15a) in a SOLO stack drive:
## staged events through the real paths (CombatWorld.deliver -> EnemyBase.apply_hit -> damaged / destroyed_enemy /
## hit_landed; PlayerTarget's own verbs for damage, down, revive, redeploy; MissionDepots._take_grant for a core; the
## CombatWorld.fired / hit_landed signals for shots and hits; MissionStats.take_snapshot for a client pilot's HP stream),
## then the outcome: the debrief is built ONCE at the outcome, has Engine's shape exactly (NetMission DEBRIEF v1: string
## ids, seat order, a negative bot id, numbers only, flat keys, labels), and solo calls Session.mission.end with it
## (NetMission.last_debrief). A stand-in bot (pilot -1) and a stand-in client pilot (2) are added to the pilot list: solo
## has neither, but their paths are the same (shooter "player-1", a puppet PlayerTarget + snapshots).

const PLAN := {"primary": "sweep", "bonus_max": 0, "waves_per_deck": 0, "hold": 3.0}

var td: MissionScene
var mf: MissionFlow
var ms: MissionStats


func setup() -> void:
	MissionFlow.test_plan = PLAN
	NetMission.clear_debrief()
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	add_child(td)
	await frames(4)
	mf = td.mission
	if check(mf != null and mf.stats != null and not mf.crew, "the solo drive has its MissionStats (host / solo only)"):
		td.drive_override = true
		td.mech.move_input = Vector2.ZERO
		for e in td.combat.squad.enemies:
			e.ai_mode = "idle"
		ms = mf.stats
		ms.set_pilots([{"id": 1, "name": "Solo"}, {"id": 2, "name": "Client"}, {"id": -1, "name": "Bot Bishop"}])
		await frames(2)
		_kills_and_damage()
		_shots_and_hits()
		await _owned_pilot()
		_client_pilot()
		_core()
		await _outcome()
	td.queue_free()
	await frames(2)
	MissionFlow.test_plan = {}
	NetMission.clear_debrief()
	finish()


func _enemies(n: int) -> Array:
	var out: Array = []
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed() and e.is_hittable():
			out.append(e)
			if out.size() >= n:
				break
	return out


var _shot_n := 0

func _hit(e: EnemyBase, shooter: String, dmg: float, comp: String = "") -> Hit:
	var h := Hit.new()
	h.damage = dmg
	h.component = comp if comp != "" else e.core_component()
	h.shooter = shooter
	h.weapon = "autocannon"
	_shot_n += 1
	h.shot = "%s/side_l/%d" % [shooter, 9000 + _shot_n]
	td.combat.world.deliver(e, h)
	return h


func _kills_and_damage() -> void:
	for pair: Array in [["trooper_at", "trooper"], ["turret_sniper", "turret"], ["strider_breacher", "strider"], ["dropship", "drone"],
			["tank", "tank"], ["gunship", "gunship"], ["mystery", "other"]]:
		eq(MissionStats.kind_group(str(pair[0])), str(pair[1]), "kill kind of %s" % pair[0])
	var es := _enemies(3)
	if not check(es.size() == 3, "three live enemies to stage on"):
		return
	var a: EnemyBase = es[0]
	var core := a.core_component()
	var core_hp := float(a.hp[core])
	# A small hit first (true HP removed), then an overkill hit: damage dealt is the HP it had, never more.
	var before_total := a.total_hp()
	_hit(a, "player1", 1.0, core)
	var removed1 := before_total - a.total_hp()
	_hit(a, "player1", 1.0e6, core)
	check(a.destroyed(), "the local pilot's overkill hit kills the enemy")
	near(float(ms.value(1, "damage_dealt")), core_hp, 0.01,
		"damage dealt = the HP actually removed (%.1f + rest of %.1f), overkill not counted" % [removed1, core_hp])
	eq(ms.value(1, "kills"), 1, "the kill is the local pilot's")
	var kind := "kills_" + MissionStats.kind_group(a.enemy_type)
	eq(ms.value(1, kind), 1, "and counted by kind (%s)" % kind)
	# A bot's kill (shooter player-1: a host bot's records / hits carry it).
	var b: EnemyBase = es[1]
	_hit(b, "player-1", 1.0e6)
	eq(ms.value(-1, "kills"), 1, "a kill by the bot credits the bot (negative id)")
	check(float(ms.value(-1, "damage_dealt")) > 0.0, "and its damage dealt")
	# No pilot source: the enemy is killed by a fall / enemy fire: nobody.
	var c: EnemyBase = es[2]
	c.apply_damage(1.0e7, c.core_component(), "fall")
	eq(int(ms.value(1, "kills")) + int(ms.value(-1, "kills")) + int(ms.value(2, "kills")), 2, "a kill with no pilot source credits nobody")
	# Hits on a wreck add nothing.
	var dd := float(ms.value(1, "damage_dealt"))
	_hit(a, "player1", 50.0)
	near(float(ms.value(1, "damage_dealt")), dd, 1e-6, "a hit on a wreck deals nothing")
	ms._hit_shots.clear()


func _shots_and_hits() -> void:
	var w := td.combat.world
	var s0 := int(ms.value(1, "shots"))
	var h0 := int(ms.value(1, "hits"))
	var es := _enemies(2)
	if not check(es.size() == 2, "two live enemies for the hits"):
		return
	# Single shot: one record, one hit.
	var r1 := {"shooter": "player1", "peer": 1, "hardpoint": "side_l", "weapon": "autocannon", "shot_index": 1}
	w.fired.emit(r1)
	var h := Hit.new()
	h.shooter = "player1"
	h.shot = Combat.shot_key(r1)
	w.hit_landed.emit(es[0], h)
	# Burst (rockets): three records, two land; one of them splashes two enemies: still one hit for that shot.
	for i in 3:
		w.fired.emit({"shooter": "player1", "peer": 1, "hardpoint": "side_r", "weapon": "rockets", "shot_index": 10 + i})
	for i in 2:
		var hb := Hit.new()
		hb.shooter = "player1"
		hb.shot = "player1/side_r/%d" % (10 + i)
		w.hit_landed.emit(es[0], hb)
		if i == 0:
			w.hit_landed.emit(es[1], hb)
	# Beam (laser): one record per pulse; two pulses, one lands.
	for i in 2:
		w.fired.emit({"shooter": "player1", "peer": 1, "hardpoint": "back", "weapon": "laser", "shot_index": 20 + i})
	var hl := Hit.new()
	hl.shooter = "player1"
	hl.shot = "player1/back/20"
	w.hit_landed.emit(es[1], hl)
	# Not shots: enemy fire, a record without a shot index; not hits: a pilot hit on a crewmate.
	w.fired.emit({"shooter": "player1", "peer": 1, "hardpoint": "x", "weapon": "enemy_cannon", "shot_index": 1, "enemy": true})
	w.fired.emit({"shooter": "player1", "weapon": "autocannon"})
	var hp := Hit.new()
	hp.shooter = "player1"
	hp.shot = "player1/side_l/77"
	w.hit_landed.emit(td.combat.player_target, hp)
	eq(int(ms.value(1, "shots")) - s0, 6, "shots: 1 single + 3 burst rounds + 2 laser pulses (one fire record each)")
	eq(int(ms.value(1, "hits")) - h0, 4, "hits: one per shot that landed on an enemy (a splash on two counts once)")
	w.fired.emit({"shooter": "player-1", "peer": 1, "hardpoint": "side_l", "weapon": "autocannon", "shot_index": 3})
	check(int(ms.value(-1, "shots")) >= 1, "the bot's records count as its shots")
	# A hit without a fire record (a staged hit) never counts; a hit that overtakes its record counts when it arrives.
	var h1 := int(ms.value(1, "hits"))
	var lone := Hit.new()
	lone.shooter = "player1"
	lone.shot = "player1/side_l/555"
	w.hit_landed.emit(es[0], lone)
	eq(int(ms.value(1, "hits")), h1, "a hit with no fire record is not a hit")
	var early := Hit.new()
	early.shooter = "player1"
	early.shot = "player1/side_l/556"
	w.hit_landed.emit(es[0], early)
	eq(int(ms.value(1, "hits")), h1, "a hit before its record waits")
	w.fired.emit({"shooter": "player1", "peer": 1, "hardpoint": "side_l", "weapon": "autocannon", "shot_index": 556})
	eq(int(ms.value(1, "hits")), h1 + 1, "and counts when its record arrives")


func _owned_pilot() -> void:
	var pt := td.combat.player_target
	pt.apply_damage(40.0, "leg_l", "e5")
	pt.apply_damage(30.0, "torso", "fall")
	near(float(ms.value(1, "damage_taken")), 70.0, 0.001, "damage taken on a host-owned pilot: exact (any source)")
	var low := 100.0 * pt.total_hp() / pt.total_max_hp()
	near(float(ms.value(1, "hp_min")), low, 0.01, "hp_min follows the total structure")
	pt.heal(50.0, "player2")
	near(float(ms.value(1, "damage_taken")), 70.0, 0.001, "a repair is not negative damage")
	# Down, revived by the bot (a revive GIVEN by -1).
	pt.apply_damage(1.0e5, "head", "e5")
	check(pt.disabled, "downed")
	eq(ms.value(1, "downs"), 1, "one down")
	await frames(3)
	pt.revive("player-1")
	eq(ms.value(-1, "revives"), 1, "the reviver (the bot) is credited")
	check(float(ms.value(1, "time_down")) >= 0.0, "time down counted")
	pt.invuln_left = 0.0
	# Down, self-revived (its own drone: by = its own target id): not a revive given.
	pt.apply_damage(1.0e5, "head", "e5")
	pt.revive(pt.target_id)
	eq(ms.value(1, "self_revives"), 1, "a self-revive counts as self_revives")
	eq(ms.value(1, "revives"), 0, "and never as a revive given")
	pt.invuln_left = 0.0
	# Down, redeployed (a death).
	pt.apply_damage(1.0e5, "head", "e5")
	pt.start_redeploy()
	pt._finish_redeploy()
	eq(ms.value(1, "downs"), 3, "three downs")
	eq(ms.value(1, "redeploys"), 1, "one redeploy")
	pt.invuln_left = 0.0


func _client_pilot() -> void:
	var pt := PlayerTarget.new()   # stands in for the puppet's target (its max HP per component)
	pt.name = "StatsPuppetTarget"
	add_child(pt)
	ms.watch_remote(2, pt)
	var n := NetMechCodec.COMPONENTS.size()
	var comp := PackedFloat32Array()
	comp.resize(n)
	for i in n:
		comp[i] = 1.0 if pt.max_hp.has(NetMechCodec.COMPONENTS[i]) else -1.0
	var ti := NetMechCodec.COMPONENTS.find("torso")
	var hi := NetMechCodec.COMPONENTS.find("head")
	var tmax := float(pt.max_hp["torso"])
	var hmax := float(pt.max_hp["head"])
	ms.take_snapshot(2, comp, false, false)
	comp[ti] = 0.75
	ms.take_snapshot(2, comp, false, false)
	comp[ti] = 0.80   # repaired a bit
	ms.take_snapshot(2, comp, false, false)
	comp[ti] = 0.50
	ms.take_snapshot(2, comp, false, false)
	near(float(ms.value(2, "damage_taken")), tmax * 0.55, 0.01, "client damage taken = sum of HP decreases between snapshots (repairs not subtracted)")
	# Down (head destroyed), revived by pilot 1's drone (the host saw its beam).
	comp[hi] = 0.0
	ms.take_snapshot(2, comp, true, false)
	eq(ms.value(2, "downs"), 1, "the client's downed edge is a down")
	ms._beam[2] = [1, mf.now()]
	comp[hi] = DownedRules.REVIVE_STRUCTURE
	comp[ti] = maxf(comp[ti], DownedRules.REVIVE_STRUCTURE)
	ms.take_snapshot(2, comp, false, false)
	eq(ms.value(1, "revives"), 1, "the client's stand-up is a revive given by the beaming pilot")
	near(float(ms.value(2, "damage_taken")), tmax * 0.55 + hmax, 0.01, "the head's loss counted, the revive's rebuild not")
	# Down and redeploy: full HP again, no damage, a redeploy.
	comp[hi] = 0.0
	ms.take_snapshot(2, comp, true, false)
	ms.take_snapshot(2, comp, true, true)
	for i in n:
		if comp[i] >= 0.0:
			comp[i] = 1.0
	ms.take_snapshot(2, comp, false, false)
	eq(ms.value(2, "redeploys"), 1, "the client's redeploy")
	eq(ms.value(2, "downs"), 2, "two downs")
	# A self-revive (its own drone was beaming it).
	comp[hi] = 0.0
	ms.take_snapshot(2, comp, true, false)
	ms._beam[2] = [2, mf.now()]
	comp[hi] = 1.0
	ms.take_snapshot(2, comp, false, false)
	eq(ms.value(2, "self_revives"), 1, "the client's self-revive")
	eq(ms.value(2, "revives"), 0, "is not a revive given")
	var tot := 0.0
	var mx := 0.0
	for c: String in pt.max_hp:
		mx += float(pt.max_hp[c])
	tot = mx - hmax - (tmax * 0.5)
	near(float(ms.value(2, "hp_min")), 100.0 * tot / mx, 0.01, "client hp_min from the stream (the down's snapshot)")


func _core() -> void:
	var dp := mf.depots
	if not check(dp != null and not dp.cores_left.is_empty(), "the plan has depots"):
		return
	var id := str(dp.cores_left.keys()[0])
	dp._take_grant({"depot": id, "peer": -1, "seq": 900, "cores_left": 3})
	dp._take_grant({"depot": id, "peer": -1, "seq": 900, "cores_left": 3})   # a duplicate: not a second core
	dp._take_grant({"depot": id, "peer": 1, "seq": 901, "cores_left": 2})
	eq(ms.value(-1, "cores"), 1, "a core granted to the bot, once")
	eq(ms.value(1, "cores"), 1, "a core granted to the local pilot")


func _outcome() -> void:
	mf.rules.outcome = "won"
	mf.rules.reason = "objectives"
	var t0 := mf.now()
	while mf.end_left < 0.0 and mf.now() < t0 + 5.0:
		await get_tree().physics_frame
	if not check(not mf.debrief.is_empty(), "the debrief is built at the outcome"):
		return
	var d := mf.debrief
	check(ms.frozen, "the counters froze at the outcome")
	var k0 := int(ms.value(1, "kills"))
	var es := _enemies(1)
	if not es.is_empty():
		_hit(es[0], "player1", 1.0e6)
	eq(int(ms.value(1, "kills")), k0, "nothing counts after the outcome")
	check(ms.finish("lost", "x") == d, "a second finish returns the same payload (built once)")
	eq(d.keys(), ["v", "outcome", "reason", "time", "pilots", "stats", "labels"], "the payload's keys")
	eq(int(d["v"]), 1, "v 1")
	eq(str(d["outcome"]), "won", "outcome")
	eq(str(d["reason"]), mf.end_reason(), "reason = end_reason()")
	check(d["time"] is float and float(d["time"]) > 0.0, "time in mission s (%s)" % str(d["time"]))
	eq((d["pilots"] as Array).map(func(p: Dictionary) -> int: return int(p["id"])), [1, 2, -1], "pilots in seat order, the bot's negative id")
	check((d["pilots"] as Array).all(func(p: Dictionary) -> bool: return p["id"] is int and p["name"] is String), "pilot entries: int id, name")
	eq((d["stats"] as Dictionary).keys(), ["1", "2", "-1"], "stats keyed by string ids")
	var core_keys := ["kills", "damage_dealt", "damage_taken", "shots", "hits", "revives", "downs", "cores", "hp_min"]
	for id: String in d["stats"]:
		var row: Dictionary = d["stats"][id]
		for k: String in core_keys:
			check(row.has(k), "pilot %s has %s" % [id, k])
		for k: String in row:
			check(row[k] is int or row[k] is float, "pilot %s: %s is a number (flat, no nested dict)" % [id, k])
		check(float(row["hp_min"]) >= 0.0 and float(row["hp_min"]) <= 100.0, "hp_min within 0..100")
		check(int(row["hits"]) <= int(row["shots"]), "pilot %s: hits (%d) <= shots (%d)" % [id, int(row["hits"]), int(row["shots"])])
	for k: String in (d["labels"] as Dictionary):
		check(not core_keys.has(k), "labels only for extra keys (%s)" % k)
	check((d["labels"] as Dictionary).has("self_revives"), "a label for self_revives")
	_key_order(d, "as built")
	# The end flow: solo hands it to Session.mission.end, NetMission keeps it (cleaned: what the board reads).
	var t1 := mf.now()
	while not mf.ended and mf.now() < t1 + MissionFlow.END_HOLD + 2.0:
		await get_tree().physics_frame
	check(mf.ended, "the end flow finished")
	eq((NetMission.last_debrief.get("pilots", []) as Array).size(), 3, "solo end kept the debrief (NetMission.last_debrief)")
	eq((NetMission.last_debrief["stats"] as Dictionary).get("1", {}).get("kills", -1), d["stats"]["1"]["kills"], "the kept debrief carries the host's numbers")
	var board := DebriefStats.table(NetMission.last_debrief)
	eq((board["columns"] as Array).size(), 3, "the board has a column per pilot")


## The order the board reads: each row = the nine, then kills_<kind> (trooper, strider, tank, gunship, drone, turret, other;
## only kinds present), then self_revives, redeploys, time_down; `labels` = those extras in the same order.
static func expected_order(d: Dictionary) -> Array:
	var present := {}
	for id: String in d["stats"]:
		for k: String in d["stats"][id]:
			present[k] = true
	var out: Array = MissionStats.CORE.duplicate()
	for g: String in ["trooper", "strider", "tank", "gunship", "drone", "turret", "other"]:
		if present.has("kills_" + g):
			out.append("kills_" + g)
	out.append_array(["self_revives", "redeploys", "time_down"])
	return out


func _key_order(d: Dictionary, tag: String) -> void:
	var want := expected_order(d)
	check(want.size() > 12, "%s: some kill kinds present (%s)" % [tag, str(want)])
	for id: String in d["stats"]:
		eq((d["stats"][id] as Dictionary).keys(), want, "%s: pilot %s's keys in the board's order" % [tag, id])
	eq((d["labels"] as Dictionary).keys(), want.slice(9), "%s: labels list the extras in the board's order" % tag)
