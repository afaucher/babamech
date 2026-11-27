extends TestCase
## Shot drops in one CombatWorld (docs/design/weapons.md §5.1; the crew side is tests/test_net_shot_drop.gd):
## 1. shot_decided fires once when a projectile STOPS on a target this machine decides, with the stop point; not for a
##    target it doesn't decide (another peer's mech), not at range, and for a piercing slug only at its last pierce.
## 2. drop_shot ends a flying copy at the reported point: one impact there, nothing hit further along, the shot leaves the
##    key map once freed; a repeat or a drop after the copy's own hit changes nothing (1, then 0).
## 3. A dropped rocket detonates once at the point: one impact, splash once on a bystander there.
## 4. A drop that arrives before its record waits for it (-1) and ends the copy at spawn; one older than
##    EARLY_DROP_LIFE is forgotten; remember = false stores nothing.

const DT := 1.0 / 60.0


func setup() -> void:
	_decided()
	_rail()
	_drop_plain()
	_drop_rocket()
	_early()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 99
	w.use_physics = false
	add_child(w)
	return w


func _target(w: CombatWorld, id: String, at: Vector3, r: float = 1.0, owner: int = 0) -> CombatTarget:
	var t := CombatTarget.new()
	t.target_id = id
	t.owner_peer = owner
	t.mass_class = "static"
	t.set_max_hp({"body": 100000.0})
	t.add_hit_sphere("body", Vector3.ZERO, r)
	add_child(t)
	t.global_position = at
	w.register(t)
	return t


func _rec(weapon: String, idx: int, t: float = 0.0, to := Vector3(0, 2, -50)) -> Dictionary:
	return Combat.fire_record("player1", 1, "side_l", weapon, Vector3(0, 2, 0), to, t, idx, 0.0)


func _run(w: CombatWorld, secs: float) -> void:
	for i in int(ceil(secs / DT)):
		w.advance(DT)


static func _lost(t: CombatTarget) -> float:
	return float(t.max_hp["body"]) - float(t.hp.get("body", 0.0))


func _decided() -> void:
	var w := _world()
	var got: Array = []
	w.shot_decided.connect(func(rec: Dictionary, p: Vector3, _n: Vector3, _c: Color) -> void: got.append([Combat.shot_key(rec), p]))
	_target(w, "near", Vector3(0, 2, -20))
	var r := _rec("autocannon", 1)
	w.fire(r)
	_run(w, 1.0)
	eq(got.size(), 1, "decided: one stop on a host-owned target hit by our shot")
	if got.size() == 1:
		eq(str(got[0][0]), Combat.shot_key(r), "decided: it names the shot")
		check(absf((got[0][1] as Vector3).z + 18.8) < 0.05, "decided: at the stop point (%s)" % str(got[0][1]))
	got.clear()
	w.fire(_rec("autocannon", 2, w.now, Vector3(0, 60, -50)))     # nothing on its line: range
	_run(w, 4.0)
	eq(got.size(), 0, "decided: nothing at the range end")
	_target(w, "theirs", Vector3(10, 2, -20), 1.0, 2)             # a remote peer's mech: its owner decides
	w.fire(Combat.fire_record("player1", 1, "side_l", "autocannon", Vector3(10, 2, 0), Vector3(10, 2, -50), w.now, 3, 0.0))
	_run(w, 1.0)
	eq(got.size(), 0, "decided: nothing for a hit this machine doesn't decide")
	w.queue_free()


func _rail() -> void:
	var w := _world()
	var got: Array = []
	w.shot_decided.connect(func(rec: Dictionary, p: Vector3, _n: Vector3, _c: Color) -> void: got.append(p))
	var pierce := int(w.stats("railgun").get("pierce", 3))
	for i in pierce:
		_target(w, "t%d" % i, Vector3(0, 2, -20.0 - 10.0 * i))
	w.fire(_rec("railgun", 1))
	_run(w, 0.5)
	eq(got.size(), 1, "rail: one stop, in the %d-th target" % pierce)
	if got.size() == 1:
		check(absf((got[0] as Vector3).z - (-20.0 - 10.0 * (pierce - 1) + 1.2)) < 0.1, "rail: at the last pierce (%s)" % str(got[0]))
	got.clear()
	var w2 := _world()
	w2.shot_decided.connect(func(_rec: Dictionary, p: Vector3, _n: Vector3, _c: Color) -> void: got.append(p))
	_target(w2, "only", Vector3(0, 2, -20))
	w2.fire(_rec("railgun", 1))
	_run(w2, 2.5)
	eq(got.size(), 0, "rail: a slug that pierces everything it meets is never announced")
	w.queue_free()
	w2.queue_free()


func _drop_plain() -> void:
	var w := _world()
	var far := _target(w, "far", Vector3(0, 2, -60))
	var impacts: Array = []
	w.impact_spawned.connect(func(p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append(p))
	var r := _rec("autocannon", 7)
	var k := Combat.shot_key(r)
	var e := w.fire(r) as Projectile
	_run(w, 0.3)
	check(w.shot(k) == e, "plain: the live shot is found by its key")
	var at := Vector3(0, 2, -25)
	eq(w.drop_shot(k, at, Vector3.BACK), 1, "plain: the flying copy is dropped")
	check(e.end_time >= 0.0, "plain: it ended")
	eq(impacts.size(), 1, "plain: one impact")
	if impacts.size() == 1:
		check((impacts[0] as Vector3).is_equal_approx(at), "plain: at the reported point")
	eq(w.drop_shot(k, at, Vector3.BACK), 0, "plain: a repeat changes nothing")
	_run(w, 2.0)
	eq(impacts.size(), 1, "plain: no second impact")
	near(_lost(far), 0.0, 1e-6, "plain: nothing further along is hit")
	check(w.shot(k) == null, "plain: the key map lets go once the shot is gone")
	# A copy that already hit something keeps its own result.
	var r2 := _rec("autocannon", 8, w.now)
	w.fire(r2)
	_run(w, 1.5)
	var lost := _lost(far)
	check(lost > 0.0, "plain: an undisturbed shot hits the far target")
	var n := impacts.size()
	var res := w.drop_shot(Combat.shot_key(r2), at, Vector3.BACK, LowPolyPalette.GREY, false)
	eq(res, 0, "plain: a drop after the copy's own hit is ignored")
	eq(impacts.size(), n, "plain: no extra impact from it")
	near(_lost(far), lost, 1e-6, "plain: nothing applied again")
	w.queue_free()


func _drop_rocket() -> void:
	var w := _world()
	w.overrides["rockets"] = {"wobble": 0.0, "spread": 0.0}
	var at := Vector3(0, 2, -15)
	var by := _target(w, "by", at + Vector3(2.0, 0, 0), 0.5)
	var far := _target(w, "far", Vector3(0, 2, -60))
	var impacts := [0]
	w.impact_spawned.connect(func(_p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts[0] += 1)
	var splashes := [0]
	w.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void:
		if t == by:
			splashes[0] += 1)
	var r := _rec("rockets", 3)
	w.fire(r)
	_run(w, 0.2)
	eq(w.drop_shot(Combat.shot_key(r), at, Vector3.BACK), 1, "rocket: dropped in flight")
	_run(w, 3.0)
	eq(impacts[0], 1, "rocket: one detonation")
	eq(splashes[0], 1, "rocket: the bystander at the point takes splash once")
	near(_lost(far), 0.0, 1e-6, "rocket: nothing further along is hit")
	w.queue_free()


func _early() -> void:
	var w := _world()
	var far := _target(w, "far", Vector3(0, 2, -40))
	var impacts: Array = []
	w.impact_spawned.connect(func(p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts.append(p))
	_run(w, 0.1)
	var r := _rec("autocannon", 11, w.now)
	var k := Combat.shot_key(r)
	eq(w.drop_shot(k, Vector3(0, 2, -5), Vector3.BACK, LowPolyPalette.GREY, false), 0, "early: remember = false keeps nothing")
	eq(w.drop_shot(k, Vector3(0, 2, -5), Vector3.BACK), -1, "early: a drop before its record waits")
	var e := w.fire(r) as Projectile
	check(e != null and e.end_time >= 0.0, "early: the record arriving later ends at once")
	eq(impacts.size(), 1, "early: one impact, at the point")
	_run(w, 1.5)
	near(_lost(far), 0.0, 1e-6, "early: nothing further along is hit")
	var r2 := _rec("autocannon", 12, w.now)
	eq(w.drop_shot(Combat.shot_key(r2), Vector3(0, 2, -5), Vector3.BACK), -1, "early: another waits")
	_run(w, CombatWorld.EARLY_DROP_LIFE + 0.2)
	r2["t"] = w.now
	var e2 := w.fire(r2) as Projectile
	check(e2 != null and e2.end_time < 0.0, "early: a drop older than EARLY_DROP_LIFE is forgotten")
	w.queue_free()
