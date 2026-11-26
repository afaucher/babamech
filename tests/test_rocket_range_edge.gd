extends TestCase
## A rocket whose contact falls on its last swept chord, at (or within float error of) max range, detonates ONCE (code
## audit 2026-11: Rocket.advance_to took a contact at end_time >= max_time - 1e-6 for the range air burst and ran
## on_expire after on_hit). Counted: impacts spawned and splash hits on a bystander inside the splash radius. Also: a
## rocket that meets nothing still air-bursts once at range, and a plain Projectile (autocannon) at the same edge
## lands once.

const RANGE := 100.0


func setup() -> void:
	for gap: float in [1e-5, 1e-7, 0.0]:
		_edge("rockets", gap)
	_edge("missiles", 1e-5)
	_edge("missiles", 0.0)
	_edge("autocannon", 1e-5)
	_air_burst()
	finish()


func _world(id: String) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = false
	w.overrides[id] = {"wobble": 0.0, "range": RANGE, "spread": 0.0, "lifetime": RANGE / 35.0}
	add_child(w)
	return w


func _target(w: CombatWorld, id: String, at: Vector3, r: float) -> CombatTarget:
	var t := CombatTarget.new()
	t.target_id = id
	t.owner_peer = 0
	t.mass_class = "static"
	t.set_max_hp({"body": 10000.0})
	t.add_hit_sphere("body", Vector3.ZERO, r)
	add_child(t)
	t.global_position = at
	w.register(t)
	return t


## A target whose (inflated) sphere starts `gap` m short of max range on the rocket's line, a bystander 2 m to its side.
func _edge(id: String, gap: float) -> void:
	var w := _world(id)
	var rec := Combat.fire_record("me", 1, "shoulder_l", id, Vector3(0, 2, 0), Vector3(0, 2, -50), 0.0, 0, 0.0)
	var e := w.fire(rec) as Projectile
	if not check(e != null, "%s fires" % id):
		w.queue_free()
		return
	var start := e.flight_pos(0.0)
	var fwd := e.flight_dir(0.0)
	var dist := 0.0
	if e is Missile:
		dist = (e as Missile).flight_dist(e.max_time)
		fwd = (e.flight_pos(e.max_time) - start).normalized()
	else:
		dist = e.speed * e.max_time
	var r := 1.0
	var c := start + fwd * (dist - gap + Combat.PROJECTILE_RADIUS + r)
	var t := _target(w, "edge", c, r)
	var side := _target(w, "side", c + fwd.cross(Vector3.UP).normalized() * (float(w.stats(id).get("splash_radius", 4.0)) * 0.5 + 0.5), 0.5)
	var impacts := [0]
	var on_side := [0]
	var on_t := [0]
	w.impact_spawned.connect(func(_p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts[0] += 1)
	w.hit_landed.connect(func(tg: CombatTarget, _h: Hit) -> void:
		if tg == side:
			on_side[0] += 1
		elif tg == t:
			on_t[0] += 1)
	for i in int(ceil((e.max_time + 1.0) * 60.0)):
		w.advance(1.0 / 60.0)
	var splashes := float(w.stats(id).get("splash_radius", 0.0)) > 0.0
	print("[edge] %s gap %s: end %.7f of max %.7f, impacts %d, hits on target %d, splash on bystander %d" % [id, str(gap),
		e.end_time if is_instance_valid(e) else -1.0, e.max_time if is_instance_valid(e) else -1.0, impacts[0], on_t[0], on_side[0]])
	eq(on_t[0], 1, "%s gap %s: the target is hit once" % [id, str(gap)])
	eq(impacts[0], 1, "%s gap %s: one impact effect" % [id, str(gap)])
	if splashes:
		eq(on_side[0], 1, "%s gap %s: the bystander takes splash once" % [id, str(gap)])
	w.queue_free()


func _air_burst() -> void:
	var w := _world("rockets")
	var side := _target(w, "side", Vector3(0, 2, -RANGE) + Vector3(0, 0, 0) + Vector3(2.5, 0, 0), 0.5)
	var impacts := [0]
	var on_side := [0]
	w.impact_spawned.connect(func(_p: Vector3, _r: float, _x: bool, _en: bool) -> void: impacts[0] += 1)
	w.hit_landed.connect(func(_tg: CombatTarget, _h: Hit) -> void: on_side[0] += 1)
	var rec := Combat.fire_record("me", 1, "shoulder_l", "rockets", Vector3(0, 2, 0), Vector3(0, 2, -50), 0.0, 0, 0.0)
	w.fire(rec)
	for i in 60 * 4:
		w.advance(1.0 / 60.0)
	eq(impacts[0], 1, "a rocket that meets nothing air-bursts once at range")
	eq(on_side[0], 1, "its air burst splashes a bystander once")
	w.queue_free()
