extends TestCase
## Guided Missiles (scripts/combat/weapons/missiles.gd, scripts/combat/missile.gd, scripts/combat/missile_laser.gd,
## docs/design/weapons.md §3.6): a press launches 3 over 0.9 s at any frame step, then 5 s reload; 18 then dry; heat per
## salvo. Each missile steers toward world.designators[shooter].dot while `on` (at most 120°/s, 35 -> 55 m/s) and flies
## straight while off; it bends onto a target 40° off, follows a moved dot, self-destructs at 9 s, hits for direct +
## splash damage; same designator samples -> same path at any frame step; the laser line lives while missiles fly with
## the track on; a WeaponRack guides them to its aim point; the weapon_range lab fires them.

const ID := "missiles"
const DT := 1.0 / 60.0
const ORIGIN := Vector3(0, 2, 0)


func setup() -> void:
	_cadence()
	_ammo_and_heat()
	_bend_and_hit()
	_follow_moved_dot()
	_track_off_and_toggles()
	_limits()
	_self_destruct()
	_damage_and_splash()
	_determinism()
	_laser_line()
	await _rack()
	await _lab()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 777
	w.use_physics = false
	add_child(w)
	return w


func _dummy(w: CombatWorld, id: String, at: Vector3, mass := "light") -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = mass
	d.position = at
	add_child(d)
	w.register(d)
	return d


func _free(w: CombatWorld, nodes: Array = []) -> void:
	for e in w.effects.duplicate():
		w.remove_effect(e)
	for n: Node in nodes:
		n.free()
	w.free()


## A missile record launched from ORIGIN `yaw_deg` off the line to `at` (+ = to the left).
func _rec(at: Vector3, yaw_deg: float, idx := 0, t := 0.0) -> Dictionary:
	var d := (at - ORIGIN).normalized().rotated(Vector3.UP, deg_to_rad(yaw_deg))
	return Combat.fire_record("me", 1, "shoulder_l", ID, ORIGIN, ORIGIN + d * 10.0, t, idx, 0.0)


func _des(w: CombatWorld, on: bool, dot: Vector3) -> void:
	w.designators["me"] = {"on": on, "dot": dot}


## Hold the trigger for `secs` at step dt; returns the fire records.
func _records(dt: float, secs: float) -> Array[Dictionary]:
	var m := WeaponMount.new()
	m.setup(ID, "shoulder_l", "me", 1, MechCatalog.weapon(ID))
	var out: Array[Dictionary] = []
	var t := 0.0
	for i in int(round(secs / dt)):
		out.append_array(m.update(dt, true, null, t, ORIGIN, Vector3(0, 2, -100)))
		t += dt
	return out


func _cadence() -> void:
	check(WeaponRegistry.built(ID), "guided missiles are built")
	var base := _records(DT, 7.0)
	if not eq(base.size(), 6, "two salvos in 7 s"):
		return
	var gap := 1.0 / float(MechCatalog.weapon(ID)["rate"])
	near(float(base[2]["t"]) - float(base[0]["t"]), 2.0 * gap, 0.0001, "3 missiles ripple out")
	check(float(base[2]["t"]) + gap <= 0.9 + 0.001, "the salvo takes 0.9 s")
	near(float(base[3]["t"]) - float(base[2]["t"]), gap + 5.0, 0.0001, "then a 5 s reload")
	for dt: float in [1.0 / 30.0, 1.0 / 144.0, 0.11]:
		var r := _records(dt, 7.0)
		var same := r.size() == base.size()
		for i in mini(r.size(), base.size()):
			same = same and absf(float(r[i]["t"]) - float(base[i]["t"])) < 0.0001
		check(same, "the same launch times at dt %.4f" % dt)


func _ammo_and_heat() -> void:
	var m := WeaponMount.new()
	m.setup(ID, "shoulder_l", "me", 1, MechCatalog.weapon(ID))
	eq(m.ammo, 18, "18 missiles loaded")
	var dry := [0]
	m.dry.connect(func() -> void: dry[0] += 1)
	var h := Heat.new(10000.0, 0.0)
	var fired := 0
	var t := 0.0
	var after_one := -1.0
	for i in 60 * 45:
		fired += m.update(DT, true, h, t, Vector3.ZERO, Vector3.FORWARD).size()
		t += DT
		if after_one < 0.0 and fired == 3:
			after_one = h.value
	near(after_one, 8.0, 0.001, "8 heat per salvo")
	eq(fired, 18, "6 salvos, then empty")
	eq(m.ammo, 0, "ammo at 0")
	check(dry[0] > 0, "an empty launcher emits dry")
	near(h.value, 48.0, 0.001, "48 heat for 6 salvos")


## Fly `m` with the designator from `des.call(now)` ({on, dot}) until it ends or `secs` pass.
func _run(w: CombatWorld, m: Missile, des: Callable, secs: float, dt := DT) -> void:
	var guard := 0
	while m.end_time < 0.0 and guard < int(secs / dt) + 2:
		var d: Dictionary = des.call(w.now)
		_des(w, d["on"], d["dot"])
		w.advance(dt)
		guard += 1


func _bend_and_hit() -> void:
	var w := _world()
	var target := _dummy(w, "target", Vector3(0, 0, -60))
	var dot := target.global_position + Vector3(0, 1.9, 0)
	var hit := [false]
	w.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void: hit[0] = hit[0] or t == target)
	_des(w, true, dot)
	var m := w.fire(_rec(dot, 40.0)) as Missile
	if not check(m != null, "a missile record spawns a Missile"):
		_free(w, [target])
		return
	near(rad_to_deg(m.flight_dir(0.0).angle_to((dot - ORIGIN).normalized())), 40.0, 0.5, "launched 40° off the target")
	_run(w, m, func(_t: float) -> Dictionary: return {"on": true, "dot": dot}, 6.0)
	check(hit[0], "it bends onto the target and hits it (ended at %.2f s)" % m.end_time)
	_free(w, [target])


func _follow_moved_dot() -> void:
	var w := _world()
	var a := Vector3(0, 2, -80)
	var b := Vector3(45, 6, -70)
	var m := w.fire(_rec(a, 0.0)) as Missile
	var closest := [INF]
	var guard := 0
	while m.end_time < 0.0 and guard < 400:
		_des(w, true, a if w.now < 0.8 else b)
		w.advance(DT)
		closest[0] = minf(closest[0], m.flight_pos(m.elapsed).distance_to(b))
		guard += 1
	check(closest[0] < 1.5, "after the dot moves the missile flies through the new point (closest %.2f m)" % closest[0])
	_free(w)


func _track_off_and_toggles() -> void:
	# Off from launch: straight, misses.
	var w := _world()
	var target := _dummy(w, "target", Vector3(0, 0, -60))
	var dot := target.global_position + Vector3(0, 1.9, 0)
	var hit := [false]
	w.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void: hit[0] = hit[0] or t == target)
	_des(w, false, dot)
	var m := w.fire(_rec(dot, 40.0)) as Missile
	_run(w, m, func(_t: float) -> Dictionary: return {"on": false, "dot": dot}, 3.0)
	check(not hit[0], "track off: it misses")
	check(m.flight_dir(2.5).is_equal_approx(m.flight_dir(0.0)), "track off: the heading never changes")
	near(m.flight_speed(2.5), 35.0, 0.001, "track off: no acceleration")
	_free(w, [target])
	# On, dropped at 0.5 s, back on at 1.5 s.
	w = _world()
	var side := Vector3(60, 2, -60)
	m = w.fire(_rec(Vector3(0, 2, -80), 0.0)) as Missile
	_run(w, m, func(t: float) -> Dictionary: return {"on": t < 0.5 or t >= 1.5, "dot": side if t < 1.0 else Vector3(-60, 2, -90)}, 2.0)
	var h_drop := m.flight_dir(0.55)
	check(m.flight_dir(0.2).angle_to(m.flight_dir(0.45)) > deg_to_rad(10.0), "tracking: the heading turns toward the dot")
	var straight := true
	for k in 8:
		straight = straight and m.flight_dir(0.55 + 0.1 * float(k)).is_equal_approx(h_drop)
	check(straight, "track dropped: straight on from the heading it had")
	check(m.flight_dir(1.45).is_equal_approx(h_drop), "still straight just before the track comes back")
	check(m.flight_dir(1.9).angle_to(h_drop) > deg_to_rad(10.0), "track back on: it steers again")
	_free(w)


func _limits() -> void:
	var w := _world()
	var m := w.fire(_rec(Vector3(0, 2, -80), 0.0)) as Missile
	# A dot that jumps around: the turn rate still caps the heading change.
	_run(w, m, func(t: float) -> Dictionary:
		return {"on": true, "dot": Vector3(80, 2, 10) if fmod(t, 1.0) < 0.5 else Vector3(-80, 30, -20)}, 3.0)
	var worst := 0.0
	var top := 0.0
	for k in m.steps():
		worst = maxf(worst, m._head[k].angle_to(m._head[k + 1]))
		top = maxf(top, m._spd[k + 1])
	check(rad_to_deg(worst) <= 120.0 * DT + 1e-3, "turn rate never above 120°/s (%.3f° per step)" % rad_to_deg(worst))
	near(m._spd[0], 35.0, 0.001, "launch speed 35 m/s")
	near(m.flight_speed(0.5), 45.0, 0.4, "accelerating while tracking (%.1f m/s at 0.5 s)" % m.flight_speed(0.5))
	near(m.flight_speed(2.0), 55.0, 0.001, "55 m/s top speed")
	check(top <= 55.0 + 1e-4, "never faster than 55 m/s")
	_free(w)


func _self_destruct() -> void:
	var w := _world()
	var bursts: Array = []
	w.impact_spawned.connect(func(p: Vector3, r: float, ex: bool, _en: bool) -> void: bursts.append([p, r, ex]))
	var m := w.fire(_rec(Vector3(0, 60, -80), 0.0)) as Missile
	_run(w, m, func(_t: float) -> Dictionary: return {"on": false, "dot": Vector3.ZERO}, 12.0)
	near(m.end_time, 9.0, 0.0001, "self-destructs at 9 s")
	if check(bursts.size() == 1, "with its explosion"):
		check(bool(bursts[0][2]) and absf(float(bursts[0][1]) - 3.0) < 0.001, "an explosive 3 m burst")
		check((bursts[0][0] as Vector3).distance_to(m.flight_pos(9.0)) < 0.01, "where it was")
	w.advance(1.5)
	eq(w.live_shots(), 0, "then it is gone")
	_free(w)


func _damage_and_splash() -> void:
	var st := MechCatalog.weapon(ID)
	var w := _world()
	var target := _dummy(w, "target", Vector3(0, 0, -50))
	var side := _dummy(w, "side", Vector3(2.8, 0, -50))
	var dot := target.global_position + Vector3(0, 1.9, 0)
	var direct: Array = [null]
	w.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		if t == target and direct[0] == null:
			direct[0] = h)
	var m := w.fire(_rec(dot, 15.0)) as Missile
	_run(w, m, func(_t: float) -> Dictionary: return {"on": true, "dot": dot}, 5.0)
	if check(direct[0] != null, "a guided missile hits its target"):
		var h: Hit = direct[0]
		near(target.total_max_hp() - target.total_hp(), float(st["damage"]), 0.001, "30 direct damage, no self splash")
		var d := INF
		for s: Dictionary in side.world_spheres():
			d = minf(d, maxf(h.point.distance_to(s["center"]) - float(s["radius"]), 0.0))
		var got := side.total_max_hp() - side.total_hp()
		near(got, float(st["splash_damage"]) * maxf(1.0 - d / float(st["splash_radius"]), 0.0), 0.01,
			"the neighbour takes linear splash (%.2f at %.2f m)" % [got, d])
		check(got > 0.0, "splash reaches the neighbour")
	_free(w, [target, side])


## Fly one missile with frame step dt, started `late` s after launch, designator from des(t). Samples + end.
func _fly(dt: float, late: float, des: Callable) -> Dictionary:
	var w := _world()
	var d := _dummy(w, "d", Vector3(30, 0, -70), "static")
	w.now = late
	_des(w, true, Vector3.ZERO)
	var dd: Dictionary = des.call(w.now)
	_des(w, dd["on"], dd["dot"])
	var m := w.fire(_rec(Vector3(0, 2, -70), 0.0)) as Missile
	_run(w, m, des, 6.0, dt)
	var out := {"p1": m.flight_pos(m.end_time * 0.5), "p2": m.flight_pos(m.end_time * 0.9), "end": m.end_time, "at": m.flight_pos(m.end_time),
		"damage": d.total_max_hp() - d.total_hp()}
	_free(w, [d])
	return out


func _same(a: Dictionary, b: Dictionary) -> bool:
	return (a["p1"] as Vector3).distance_to(b["p1"]) < 0.001 and (a["p2"] as Vector3).distance_to(b["p2"]) < 0.001 \
		and absf(float(a["end"]) - float(b["end"])) < 0.0001 and (a["at"] as Vector3).distance_to(b["at"]) < 0.001


func _determinism() -> void:
	var dot := Vector3(30, 1.9, -70)
	var steady := func(_t: float) -> Dictionary: return {"on": true, "dot": dot}
	var base := _fly(DT, 0.0, steady)
	check(float(base["damage"]) > 0.0, "the steered missile hits the off-axis dummy (%.1f)" % float(base["damage"]))
	for dt: float in [1.0 / 30.0, 1.0 / 144.0, 0.11]:
		var r := _fly(dt, 0.0, steady)
		if not check(_same(r, base), "same path and impact at dt %.4f" % dt):
			print("  base %s vs %s" % [base, r])
	# A designator that drops at 1.0 s and comes back at 2.0 s (the same samples on every step grid that hits those times).
	var toggled := func(t: float) -> Dictionary:
		return {"on": t < 1.0 - 1e-6 or t >= 2.0 - 1e-6, "dot": Vector3(-40, 2, -40) if t < 1.0 - 1e-6 else dot}
	var tb := _fly(DT, 0.0, toggled)
	for dt: float in [1.0 / 30.0, 1.0 / 144.0]:
		check(_same(_fly(dt, 0.0, toggled), tb), "same path with the track toggled at dt %.4f" % dt)
	# Late start with a steady designator: the fast-forward gives the same path.
	check(_same(_fly(DT, 0.4, steady), base), "same path when started 0.4 s late (steady track)")


func _laser_line() -> void:
	var w := _world()
	var dot := Vector3(10, 2, -80)
	w.set_muzzle("me", "shoulder_l", func() -> Vector3: return ORIGIN + Vector3(0.3, 0.4, 0))
	_des(w, true, dot)
	var a := w.fire(_rec(dot, 0.0, 0)) as Missile
	w.advance(0.3)
	var b := w.fire(_rec(dot, 0.0, 1, w.now)) as Missile
	var lasers := w.effects.filter(func(e: CombatEffect) -> bool: return e is MissileLaser)
	eq(lasers.size(), 1, "one laser line per shooter + hardpoint, not per missile")
	if lasers.is_empty():
		_free(w)
		return
	var l: MissileLaser = lasers[0]
	w.advance(DT)
	check(l.shown and l._beam.visible and l._dot.visible, "the line and dot show while missiles fly with the track on")
	check((l.points()[0] as Vector3).distance_to(ORIGIN + Vector3(0.3, 0.4, 0)) < 0.001, "from the live launcher muzzle")
	check((l.points()[1] as Vector3).distance_to(dot) < 0.001, "to the dot")
	_des(w, false, dot)
	w.advance(DT)
	check(not l.shown and not l._beam.visible, "track off: no line")
	_des(w, true, dot + Vector3(5, 0, 0))
	w.advance(DT)
	check(l.shown and (l.points()[1] as Vector3).distance_to(dot + Vector3(5, 0, 0)) < 0.001, "back on, following the dot")
	var guard := 0
	while (a.end_time < 0.0 or b.end_time < 0.0) and guard < 600:
		w.advance(DT)
		guard += 1
	w.advance(DT)
	check(w.effects.filter(func(e: CombatEffect) -> bool: return e is MissileLaser).is_empty(), "gone after the last missile")
	_free(w)


## A WeaponRack with missiles on shoulder_l: its missiles go where its aim point goes.
func _rack() -> void:
	var world := _world()
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "", "side_r": "", "shoulder_l": ID, "shoulder_r": "", "back": ""})
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "racker", 1)
	await frames(2)
	var first := _dummy(world, "first", Vector3(-6, 0, -55))
	var second := _dummy(world, "second", Vector3(22, 0, -45))
	var hit_second := [0]
	var hit_first := [0]
	world.hit_landed.connect(func(t: CombatTarget, _h: Hit) -> void:
		if t == second: hit_second[0] += 1
		if t == first: hit_first[0] += 1)
	rack.aim_point = first.global_position + Vector3(0, 1.9, 0)
	rack.set_trigger(true)
	for i in 240:
		if i == 6:
			rack.set_trigger(false)
		if i == 18:
			rack.aim_point = second.global_position + Vector3(0, 1.9, 0)    # re-aim mid-flight
		rack.step(DT)
		world.advance(DT)
	eq(rack.mounts[2].shot_index, 3, "one salvo left shoulder_l")
	eq(hit_second[0], 3, "every missile follows the rack's new aim point to the second dummy")
	eq(hit_first[0], 0, "none goes to the first aim point")
	rack.queue_free()
	model.queue_free()
	_free(world, [first, second])
	mech.free()
	await frames(1)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.time_scale = 0.0
	lab.set_lab_option("weapon", ID)
	check(lab.hardpoint.begins_with("shoulder"), "missiles go on a shoulder (%s)" % lab.hardpoint)
	var best: TargetDummy = null
	for d in lab.dummies:
		if best == null or absf(d.global_position.length() - 50.0) < absf(best.global_position.length() - 50.0):
			best = d
	lab.set_lab_option("aim", str(best.name))
	lab.set_lab_option("designator", "hold")
	lab.set_lab_option("fire", "single")
	var shown := false
	var flying := 0
	for i in 200:
		lab.step(DT)
		var n := 0
		for e in lab.world.effects:
			if e is Missile and (e as Missile).end_time < 0.0:
				n += 1
			if e is MissileLaser and (e as MissileLaser).shown:
				shown = true
		flying = maxi(flying, n)
	check(lab.mount.shot_index >= 3, "the lab fired a salvo (%d)" % lab.mount.shot_index)
	check(flying >= 2, "missiles in flight together (%d)" % flying)
	check(shown, "the lab shows the laser line")
	check(not lab._beam.visible, "the lab's own designator preview gives way to the missile line")
	check(best.total_hp() < best.total_max_hp(), "the aimed dummy got hit (%.0f HP)" % best.total_hp())
	check(lab._heat_label.text.contains("AMMO"), "the label shows ammo")
	lab.queue_free()
	await frames(1)
