extends TestCase
## Enemy fixes from the 2026-11 code audit (docs/code-audit-2026-11.md), headless, no physics:
## 1. Fight memory through a stagger / overheat (EnemyBase._hold_disabled / _resume_from_disabled): a fighting unit stays
##    alerted while staggered or overheated, hits then do not re-alert it (no second "alerted" event, the alert delay is
##    not restarted), and it resumes its fight afterwards; an un-alerted unit hit while staggered alerts once and keeps
##    that alert (with its reaction delay) for when it recovers.
## 2. A trooper firing from cover on its peek line (EnemyTrooper._telegraph_has_line): the >= 0.3 s telegraph completes
##    and the shot follows; the base used to cancel it on the first tick (no sight line of its own behind cover).
## 4. Dropship troopers never hunt a defend relay (EnemyDropDrone._deploy_carried_squad): the nearest crew mech, or none.
## 5. Gunship obstacle push (EnemyGunship._tall_obstacle_repulsion): the drone's rule (EnemyDrone.edge_repulsion), from
##    the nearest edge with a soft falloff, not from the building's centre with a hard margin.
## (3, pruned attack slots, is in test_attack_slots.)

const DT := 1.0 / 60.0


## A rifle trooper whose own sight line is always blocked (it stands behind cover) but whose peek line is clear.
class PeekTrooper extends EnemyTrooper:
	func _acquire_target(space: PhysicsDirectSpaceState3D) -> CombatTarget:
		var t := super._acquire_target(space)
		_has_los = false
		return t

	func _has_peek_los(_target_pos: Vector3) -> bool:
		return true


## Stub squad that only answers deck_occluders (the gunship's obstacle push reads nothing else).
class OccSquad extends Node:
	var occ: Array = []

	func deck_occluders(_deck: int = -1) -> Array:
		return occ


func setup() -> void:
	await _stagger_keeps_the_fight()
	await _overheat_keeps_the_fight()
	await _unalerted_hit_while_staggered()
	await _trooper_fires_from_cover()
	await _dropship_troops_skip_relay()
	_gunship_edge_repulsion()
	await _damaged_reports_true_hp()
	finish()


## 6. EnemyBase.damaged reports the HP actually removed (CombatTarget / PlayerTarget's contract): a killing blow on a
## part reports what the part had, a hit on a destroyed part reports only what the core really lost (overflow), a hit
## on a dead enemy reports nothing. How much damage is applied, the part break and the alert stay as they were.
func _damaged_reports_true_hp() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, 300))
	var g := EnemyGunship.new()
	g.configure("gunship", "dmg_gs", w, sq, null, 5)
	g.position = Vector3(0, 11.5, 0)
	sq.add_enemy(g)
	await frames(1)
	var ev: Array = []
	g.damaged.connect(func(a: float, c: String, s: String) -> void: ev.append([a, c, s]))
	g.hp["pods"] = 100.0
	var mult := float(g._comp_meta["pods"].get("mult", 1.0))
	var hull0 := float(g.hp["hull"])
	g.apply_damage(150.0 / mult, "pods", "player1")   # 150 effective on a 100 HP part
	var pods_ev := ev.filter(func(e: Array) -> bool: return str(e[1]) == "pods")
	eq(pods_ev.size(), 1, "one pods event")
	if pods_ev.size() == 1:
		near(float(pods_ev[0][0]), 100.0, 1e-4, "a 150 hit on a 100 HP part reports 100 (got %.1f)" % float(pods_ev[0][0]))
	near(float(g.hp["pods"]), 0.0, 1e-6, "the part is destroyed")
	check(g._primary_disabled, "the break still disarms it")
	check(g.is_alerted(), "the hit still alerts it toward the shooter")
	var hull_ev := ev.filter(func(e: Array) -> bool: return str(e[1]) == "hull")
	var hull_lost := hull0 - float(g.hp["hull"])
	near(float(hull_ev.reduce(func(acc: float, e: Array) -> float: return acc + float(e[0]), 0.0)), hull_lost, 1e-4,
		"the break's shock to the hull reports what the hull lost (%.1f)" % hull_lost)
	# A hit on the destroyed part: only the core's real loss, clamped when the core has less left.
	ev.clear()
	g.hp["hull"] = 5.0
	g.apply_damage(400.0, "pods", "player1")
	eq(ev.size(), 1, "a hit on a destroyed part emits only the core's event (%s)" % str(ev))
	if ev.size() == 1:
		eq(str(ev[0][1]), "hull", "on the core")
		near(float(ev[0][0]), 5.0, 1e-4, "reporting what the core actually lost (got %.1f)" % float(ev[0][0]))
	check(g.destroyed(), "and that kills it as before")
	ev.clear()
	g.apply_damage(50.0, "hull", "player1")
	g.apply_damage(50.0, "pods", "player1")
	eq(ev.size(), 0, "a hit on a dead enemy emits nothing")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 91
	w.use_physics = false
	add_child(w)
	return w


func _mock_player(w: CombatWorld, at: Vector3, id: String = "player1") -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = id
	p.owner_peer = 1
	p.team = "player"
	p.mass_class = "mech"
	p.set_max_hp({"torso": 1.0e6})
	p.add_hit_sphere("torso", Vector3(0, 4.0, 0), 2.0)
	p.position = at
	add_child(p)
	w.register(p)
	return p


func _strider(w: CombatWorld, sq: EnemySquad, id: String, at: Vector3) -> EnemyStrider:
	var s := EnemyStrider.new()
	s.configure("strider", id, w, sq, null, 3)
	s.position = at
	sq.add_enemy(s)
	return s


## Counts the unit's "alerted" squad events with state spotted / relay (the reliable net message + music bump).
func _count_alerts(sq: EnemySquad, e: EnemyBase) -> Array:
	var n := [0]
	sq.enemy_event.connect(func(kind: String, who: Node, pay: Dictionary) -> void:
		if who == e and kind == "alerted" and str(pay.get("state", "")) in ["spotted", "relay"]:
			n[0] += 1)
	return n


func _hit(e: EnemyBase) -> void:
	e.apply_damage(1.0, "", "player1")


func _stagger_keeps_the_fight() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, -45))
	var s := _strider(w, sq, "fm_stagger", Vector3.ZERO)
	var alerts := _count_alerts(sq, s)
	await frames(1)
	# Notice the mech, then sit in the alert delay for a few ticks.
	for _i in 240:
		w.advance(DT)
		if s.ai_state == EnemyBase.STATE_ALERT:
			break
	for _i in 3:
		w.advance(DT)
	eq(s.ai_state, EnemyBase.STATE_ALERT, "the strider spots the mech (alert delay running)")
	eq(alerts[0], 1, "one alert")
	s.knock.stagger_left = 1.0
	w.advance(DT)
	eq(s.ai_state, EnemyBase.STATE_STAGGERED, "staggered mid-alert")
	check(s.is_alerted(), "a staggered unit that was alerted is still alerted")
	var timer := s._alert_timer
	_hit(s)
	_hit(s)
	w.advance(DT)
	_hit(s)
	eq(alerts[0], 1, "hits while staggered do not re-alert it (alerts %d)" % alerts[0])
	near(s._alert_timer, timer, 1e-6, "hits while staggered do not restart the alert delay")
	# Recovers into its alert, then engages, without a second alert.
	var after: Array = []
	for _i in 150:
		w.advance(DT)
		if not s.knock.staggered() and not (s.ai_state in after):
			after.append(s.ai_state)
	check(not (EnemyBase.STATE_IDLE in after) and not (EnemyBase.STATE_PATROL in after),
		"after the stagger it resumes its fight, never idles / patrols (%s)" % str(after))
	check(after.size() > 0 and after[0] == EnemyBase.STATE_ALERT, "it resumes the alert it held (%s)" % str(after))
	eq(alerts[0], 1, "still one alert after the stagger")
	# Now fighting (past the alert): stagger again, hits, recovery: no alert state, no new alert.
	check(s.is_alerted() and s.ai_state != EnemyBase.STATE_ALERT, "fighting before the second stagger (%s)" % s.ai_state)
	s.knock.stagger_left = 0.8
	w.advance(DT)
	_hit(s)
	_hit(s)
	check(s.is_alerted(), "fighting and staggered: still alerted")
	var states: Array = []
	for _i in 90:
		w.advance(DT)
		if not s.knock.staggered() and not (s.ai_state in states):
			states.append(s.ai_state)
	check(not (EnemyBase.STATE_ALERT in states) and not (EnemyBase.STATE_IDLE in states) and not (EnemyBase.STATE_PATROL in states),
		"a fighting unit comes out of a stagger fighting, without replaying the alert (%s)" % str(states))
	eq(s._target_id, p.target_id, "it keeps its target")
	eq(alerts[0], 1, "one alert in all")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _overheat_keeps_the_fight() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, -45))
	var s := _strider(w, sq, "fm_heat", Vector3.ZERO)
	var alerts := _count_alerts(sq, s)
	await frames(1)
	for _i in 60:
		w.advance(DT)
	check(s.is_alerted() and s.ai_state != EnemyBase.STATE_ALERT, "fighting (%s)" % s.ai_state)
	s.heat.add(s.heat.cap * 2.0)
	w.advance(DT)
	eq(s.ai_state, EnemyBase.STATE_OVERHEATED, "overheated")
	check(s.is_alerted(), "an overheated unit that was fighting is still alerted")
	_hit(s)
	_hit(s)
	eq(alerts[0], 1, "hits while overheated do not re-alert it (alerts %d)" % alerts[0])
	var states: Array = []
	var t := 0.0
	while t < 30.0 and (s.heat.shutdown or states.size() < 3):
		w.advance(DT)
		t += DT
		if not s.heat.shutdown and not (s.ai_state in states):
			states.append(s.ai_state)
	check(not s.heat.shutdown, "it reboots (%.1f s)" % t)
	check(not (EnemyBase.STATE_ALERT in states) and not (EnemyBase.STATE_IDLE in states) and not (EnemyBase.STATE_PATROL in states),
		"after the reboot it resumes its fight (%s)" % str(states))
	eq(alerts[0], 1, "one alert in all")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _unalerted_hit_while_staggered() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, 90))   # behind it, past its notice range: not seen
	var s := _strider(w, sq, "fm_cold", Vector3.ZERO)
	var alerts := _count_alerts(sq, s)
	await frames(1)
	for _i in 3:
		w.advance(DT)
	check(not s.is_alerted(), "not alerted yet (%s)" % s.ai_state)
	s.knock.stagger_left = 1.0
	w.advance(DT)
	eq(s.ai_state, EnemyBase.STATE_STAGGERED, "staggered while un-alerted")
	check(not s.is_alerted(), "a staggered unit that was not fighting is not alerted")
	_hit(s)
	eq(alerts[0], 1, "the first hit alerts it")
	check(s.is_alerted(), "alerted while still staggered")
	w.advance(DT)
	_hit(s)
	w.advance(DT)
	_hit(s)
	eq(alerts[0], 1, "later hits do not alert it again (alerts %d)" % alerts[0])
	while s.knock.staggered():
		w.advance(DT)
	w.advance(DT)
	eq(s.ai_state, EnemyBase.STATE_ALERT, "it comes out of the stagger in the alert the hit gave it")
	eq(s._target_id, p.target_id, "toward its shooter")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _trooper_fires_from_cover() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mock_player(w, Vector3(0, 0, -40))
	var tr := PeekTrooper.new()
	tr.configure("trooper_rifle", "peek_tr", w, sq, null, 4)
	tr.on_roof = true   # holds its cover spot (no displacement): fires over the parapet on its peek line
	sq.add_enemy(tr)
	var started: Array = []
	var cancelled: Array = []
	var fired: Array = []
	sq.enemy_event.connect(func(kind: String, who: Node, pay: Dictionary) -> void:
		if who != tr:
			return
		if kind == "telegraph_started":
			started.append([w.now, float(pay.get("duration", 0.0))])
		elif kind == "telegraph_cancelled":
			cancelled.append(str(pay.get("reason", "")))
		elif kind == "weapon_fired":
			fired.append(w.now))
	await frames(1)
	for _i in 600:
		w.advance(DT)
	print("[Test] peek trooper: telegraphs %d, cancelled %s, shots %d" % [started.size(), str(cancelled), fired.size()])
	check(started.size() >= 1, "the trooper in cover starts a telegraph on its peek line (%d)" % started.size())
	eq(cancelled.size(), 0, "its telegraphs are never cancelled by the cover logic (%s)" % str(cancelled))
	check(fired.size() >= 1, "it fires from cover (%d shots)" % fired.size())
	if not started.is_empty() and not fired.is_empty():
		var t0 := float(started[0][0])
		check(float(started[0][1]) >= EnemyCatalog.MIN_TELEGRAPH - 1e-4, "telegraph >= 0.3 s (%.2f)" % float(started[0][1]))
		check(float(fired[0]) - t0 >= float(started[0][1]) - DT * 1.5,
			"the first shot comes after the full telegraph (%.2f s after its start, telegraph %.2f s)" % [
			float(fired[0]) - t0, float(started[0][1])])
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _dropship_troops_skip_relay() -> void:
	for with_crew in [true, false]:
		var w := _world()
		var sq := EnemySquad.new()
		add_child(sq)
		sq.setup(w)
		var relay := AssetTarget.new("d0_relay", 2.5, 6.0)
		relay.position = Vector3(3.0, 0, -45.0)   # right at the drop
		add_child(relay)
		w.register(relay)
		var p: CombatTarget = _mock_player(w, Vector3(0.0, 0.0, 10.0), "crew_far") if with_crew else null
		var ds := EnemyDropDrone.new()
		ds.configure("dropship", "drop_relay_%s" % str(with_crew), w, sq, null, 9)
		ds.wave = "w_alarm"
		ds.position = Vector3(0.0, 11.5, -45.0)
		ds.configure_drop(Vector3(0.0, 0.0, -45.0), false, 6.0, Vector3(25.0, 28.0, -85.0))
		sq.add_enemy(ds)
		var dep := [null]
		ds.troops_deployed.connect(func(_d: EnemyDropDrone, ts: Array) -> void: dep[0] = ts)
		await frames(1)
		for _i in 300:
			w.advance(DT)
			if dep[0] != null:
				break
		var ts: Array = dep[0] if dep[0] is Array else []
		check(ts.size() >= 3, "the dropship deploys its troopers (%d)" % ts.size())
		var on_relay := 0
		var on_crew := 0
		for t in ts:
			var tr := t as EnemyTrooper
			if tr._last_target_ref == relay or tr._target_id == relay.target_id:
				on_relay += 1
			if p != null and tr._last_target_ref == p:
				on_crew += 1
		eq(on_relay, 0, "no dropped trooper hunts the defend relay (crew %s)" % str(with_crew))
		if with_crew:
			eq(on_crew, ts.size(), "they hunt the crew mech, farther than the relay (%d of %d)" % [on_crew, ts.size()])
		if p != null:
			p.queue_free()
		relay.queue_free()
		sq.queue_free()
		w.queue_free()
		await frames(1)


func _gunship_edge_repulsion() -> void:
	var occ := [{"rect": Rect2(0.0, 0.0, 40.0, 20.0), "h": 30.0}]
	var stub := OccSquad.new()
	stub.occ = occ
	add_child(stub)
	var g := EnemyGunship.new()
	g.configure("gunship", "rep_gs", null, null, null, 1)
	g.squad = stub
	var alt := 10.0
	# Beside the long wall near its end: pushed straight off the wall, not diagonally off the centre.
	var r_end := g._tall_obstacle_repulsion(Vector2(36.0, -3.0), alt)
	check(r_end.length() > 0.1 and r_end.normalized().dot(Vector2(0.0, -1.0)) > 0.99,
		"near a wall's end the gunship is pushed straight off the wall (%s)" % str(r_end))
	# Soft falloff: no step anywhere across the range, strong at the wall, nothing past REPEL_RANGE.
	var worst := 0.0
	var prev := g._tall_obstacle_repulsion(Vector2(20.0, -0.5), alt)
	var d := 0.6
	while d < EnemyDrone.REPEL_RANGE + 2.0:
		var cur := g._tall_obstacle_repulsion(Vector2(20.0, -d), alt)
		worst = maxf(worst, (cur - prev).length())
		prev = cur
		d += 0.1
	check(worst < 0.05, "the push fades smoothly with distance (largest step %.3f per 0.1 m)" % worst)
	check(g._tall_obstacle_repulsion(Vector2(20.0, -1.0), alt).length() > 0.7, "strong right at the wall")
	check(g._tall_obstacle_repulsion(Vector2(20.0, -EnemyDrone.REPEL_RANGE - 0.1), alt).length() < 1e-6,
		"none past REPEL_RANGE")
	# The same rule as the drone (one shared function).
	for a: Vector2 in [Vector2(-3.0, -3.0), Vector2(41.5, 10.0), Vector2(20.0, 23.0), Vector2(5.0, 5.0)]:
		var gr := g._tall_obstacle_repulsion(a, alt)
		var dr := EnemyDrone.edge_repulsion(occ, a, alt - 2.0)
		check(gr.distance_to(dr) < 1e-6, "gunship and drone push alike at %s (%s vs %s)" % [str(a), str(gr), str(dr)])
	g.free()
	stub.queue_free()
