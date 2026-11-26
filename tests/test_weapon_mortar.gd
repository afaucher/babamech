extends TestCase
## The Back Mortar (weapons.md §3.7; scripts/combat/weapons/mortar.gd, mortar_shell.gd): flight time vs range, the arc
## lands on the aim point (within scatter) over an obstacle that blocks the straight line, the 30 m minimum and 250 m
## maximum refuse to fire (and say why), scatter grows with range and stays bounded, direct + splash damage with linear
## falloff, radial knockback with lift, detonation on a ceiling / wall in the way, the telegraph ring for the whole
## flight, cadence and heat, determinism (frame step, late start) and the weapon_range lab firing it.

const ORIGIN := Vector3(0, 4.0, 0)


func setup() -> void:
	_flight_time()
	_range_gate()
	_scatter()
	_cadence_and_heat()
	await _damage_and_knockback()
	await _telegraph()
	await _determinism()
	await _over_obstacle()
	await _ceiling_and_wall()
	await _lab()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 31
	w.use_physics = physics
	add_child(w)
	return w


func _dummy(w: CombatWorld, id: String, at: Vector3, mass: String = "light") -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = mass
	d.position = at
	add_child(d)
	w.register(d)
	return d


func _block(size: Vector3, at: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	b.position = at
	add_child(b)
	return b


func _rec(target: Vector3, shot: int = 0, t: float = 0.0) -> Dictionary:
	return Combat.fire_record("me", 1, "back", "mortar", ORIGIN, target, t, shot)


## Advance until every effect is done; returns the impact points (shake signal) in order.
func _run(w: CombatWorld, dt: float = 1.0 / 60.0, max_s: float = 20.0) -> Array:
	var impacts: Array = []
	var cb := func(_s: float, p: Vector3) -> void: impacts.append(p)
	w.shake.connect(cb)
	var t := 0.0
	while w.live_shots() > 0 and t < max_s:
		w.advance(dt)
		t += dt
	w.shake.disconnect(cb)
	return impacts


func _flight_time() -> void:
	var st := MechCatalog.weapon("mortar")
	var w := _world()
	for r: float in [30.0, 100.0, 250.0]:
		var target := Vector3(0, 0, -r)
		var s := w.fire(_rec(target)) as MortarShell
		if not check(s != null, "the mortar fires a MortarShell"):
			continue
		near(s.flight_time, 2.0 + r / 100.0, 0.001, "flight time at %d m is 2 s + 1 s / 100 m" % int(r))
		near(s.flight_time, MortarShell.flight_time_for(st, r), 0.0001, "flight time from the catalog at %d m" % int(r))
		check(s.flight_pos(0.0).is_equal_approx(ORIGIN), "the arc starts at the muzzle (%d m)" % int(r))
		check(s.flight_pos(s.flight_time).distance_to(s.landing) < 0.001, "the arc ends at the landing point (%d m)" % int(r))
		var peak := s.flight_pos(s.flight_time * 0.5)
		near(peak.y - (ORIGIN.y + s.landing.y) * 0.5, s.apex_h, 0.001, "apex above the chord (%d m)" % int(r))
		check(peak.y < 40.0, "the apex stays under a 40 m ceiling (%.1f m at %d m)" % [peak.y, int(r)])
		near(s.gravity(), 8.0 * s.apex_h / (s.flight_time * s.flight_time), 0.0001, "gravity matches the flight time")
		# A parabola: constant vertical acceleration = -gravity.
		var e := s.flight_time * 0.3
		var hh := 0.01
		var acc := (s.flight_pos(e + hh).y - 2.0 * s.flight_pos(e).y + s.flight_pos(e - hh).y) / (hh * hh)
		near(acc, -s.gravity(), 0.05, "constant gravity along the arc (%d m)" % int(r))
		check(s.flight_dir(s.flight_time).y < -0.3, "it comes down steeply (%d m)" % int(r))
		w.remove_effect(s)
	w.free()


func _mount(st: Dictionary) -> WeaponMount:
	var m := WeaponMount.new()
	m.setup("mortar", "back", "me", 1, st)
	return m


func _range_gate() -> void:
	var st := MechCatalog.weapon("mortar")
	var h := Heat.new(1000.0, 0.0)
	var m := _mount(st)
	eq(m.update(0.1, true, h, 0.0, ORIGIN, Vector3(0, 0, -20)).size(), 0, "inside 30 m the mortar does not fire")
	check(m.hold_reason.begins_with("TOO CLOSE"), "and says why: " + m.hold_reason)
	near(h.value, 0.0, 0.0001, "no heat for a refused shot")
	eq(m.update(0.1, true, h, 0.1, ORIGIN, Vector3(0, 0, -29.5)).size(), 0, "29.5 m is still too close")
	eq(m.update(0.1, true, h, 0.2, ORIGIN, Vector3(0, 0, -300)).size(), 0, "past 250 m the mortar does not fire")
	check(m.hold_reason.begins_with("OUT OF RANGE"), "and says why: " + m.hold_reason)
	eq(m.shot_index, 0, "no shots counted")
	eq(m.update(0.1, true, h, 0.3, ORIGIN, Vector3(0, 0, -30.5)).size(), 1, "30.5 m fires")
	eq(m.hold_reason, "", "no hold reason in range")
	var m2 := _mount(st)
	eq(m2.update(0.1, true, h, 0.0, ORIGIN, Vector3(0, 30, -249)).size(), 1, "range is horizontal: 249 m out, 30 m up fires")


func _scatter() -> void:
	var st := MechCatalog.weapon("mortar")
	var w := _world()
	var prev := -1.0
	for r: float in [30.0, 100.0, 175.0, 250.0]:
		var target := Vector3(0, 0, -r)
		var bound := MortarShell.scatter_for(st, r)
		var worst := 0.0
		var ok := true
		for i in 80:
			var s := w.fire(_rec(target, i)) as MortarShell
			var off := Vector2(s.landing.x - target.x, s.landing.z - target.z).length()
			ok = ok and off <= bound + 0.0001 and is_equal_approx(s.landing.y, target.y)
			worst = maxf(worst, off)
			w.remove_effect(s)
		check(ok, "scatter at %d m stays within %.2f m (worst %.2f)" % [int(r), bound, worst])
		check(worst > prev or r == 30.0, "scatter grows with range (%.2f m at %d m)" % [worst, int(r)])
		prev = worst
		if r == 30.0:
			near(worst, 0.0, 0.0001, "no scatter at the minimum range")
		if r == 250.0:
			near(bound, 3.0, 0.0001, "3 m scatter radius at 250 m")
			check(worst > 2.0, "shots really use the 3 m radius (%.2f)" % worst)
	var a := w.fire(_rec(Vector3(0, 0, -200), 5)) as MortarShell
	var b := w.fire(_rec(Vector3(0, 0, -200), 5)) as MortarShell
	var c := w.fire(_rec(Vector3(0, 0, -200), 6)) as MortarShell
	check(a.landing.is_equal_approx(b.landing), "the same shot draws the same scatter")
	check(not a.landing.is_equal_approx(c.landing), "the next shot draws another")
	w.free()


func _cadence_and_heat() -> void:
	var st := MechCatalog.weapon("mortar")
	var h := Heat.new(1000.0, 0.0)
	var m := _mount(st)
	var times: Array[float] = []
	var t := 0.0
	for i in 60 * 20:
		for r in m.update(1.0 / 60.0, true, h, t, ORIGIN, Vector3(0, 0, -120)):
			times.append(float(r["t"]))
		t += 1.0 / 60.0
	eq(int(st["ammo"]), 6, "6 shells a mission")
	eq(times.size(), 6, "one shell per 3.5 s until the 6 shells are gone (20 s held)")
	if times.size() >= 6:
		near(times[2] - times[1], 3.5, 0.002, "3.5 s between shells")
		near(times[5] - times[0], 5.0 * 3.5, 0.002, "the sixth shell 17.5 s after the first")
	near(h.value, 6.0 * 18.0, 0.001, "18 heat a shell")
	eq(m.ammo, 0, "out of shells")


func _damage_and_knockback() -> void:
	var w := _world()
	w.overrides["mortar"] = {"scatter_max": 0.0}
	var st := w.stats("mortar")
	var hit := _dummy(w, "hit", Vector3(0, 0, -100))
	var near4 := _dummy(w, "near4", Vector3(4.0, 0, -100))
	var near6 := _dummy(w, "near6", Vector3(0, 0, -106.5))
	var far := _dummy(w, "far", Vector3(-14.0, 0, -100))
	await frames(1)
	var hits := {}
	w.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: hits[t.target_id] = h)
	w.fire(_rec(Vector3(0, 1.9, -100)))
	var impacts := _run(w, 1.0 / 60.0)
	eq(impacts.size(), 1, "one explosion")
	if not check(hits.has("hit"), "the aimed-at dummy takes a direct hit"):
		_free([hit, near4, near6, far, w])
		return
	var dh: Hit = hits["hit"]
	near(dh.damage, 80.0, 0.001, "80 direct damage")
	near(hit.total_max_hp() - hit.total_hp(), 80.0, 0.001, "the direct hit takes no extra splash")
	near(dh.impulse.y, float(st["splash_lift"]), 0.001, "direct hit lifts the target")
	near(Vector2(dh.impulse.x, dh.impulse.z).length(), 4.0, 0.001, "4.0 radial knockback on the direct hit")
	var blast: Vector3 = dh.point
	for d: TargetDummy in [near4, near6]:
		var best := INF
		var centre := Vector3.ZERO
		for s: Dictionary in d.hit_shapes:      # where it stood when the shell burst (it has been thrown since)
			var c: Vector3 = d.home + (s["center"] as Vector3)
			var dd := maxf(blast.distance_to(c) - float(s["radius"]), 0.0)
			if dd < best:
				best = dd
				centre = c
		var k := 1.0 - best / 8.0
		if not check(hits.has(d.target_id), "%s inside the 8 m splash is hit" % d.target_id):
			continue
		var sh: Hit = hits[d.target_id]
		near(sh.damage, 50.0 * k, 0.001, "%s splash falls off linearly (%.1f at %.2f m)" % [d.target_id, sh.damage, best])
		var out := centre - blast
		out.y = 0.0
		var hor := Vector3(sh.impulse.x, 0, sh.impulse.z)
		check(hor.normalized().dot(out.normalized()) > 0.999, "%s is pushed away from the blast" % d.target_id)
		near(hor.length(), 4.0 * k, 0.001, "%s radial Δv 4.0 × falloff" % d.target_id)
		near(sh.impulse.y, 3.0 * k, 0.001, "%s lifted by splash_lift × falloff" % d.target_id)
	check((hits["near4"] as Hit).damage > (hits["near6"] as Hit).damage, "nearer takes more splash")
	check((hits["near4"] as Hit).impulse.x > 0.0, "the +X neighbour flies +X")
	check(not hits.has("far"), "14 m away: no splash")
	near(far.total_hp(), far.total_max_hp(), 0.0, "the far dummy is untouched")
	for i in 30:
		w.advance(1.0 / 60.0)
	check(near4.global_position.y > 0.01 or near4.knock.velocity.y != 0.0 or near4.global_position.x > 4.0, "the neighbour got thrown")
	_free([hit, near4, near6, far, w])
	await frames(1)


func _free(nodes: Array) -> void:
	for n: Node in nodes:
		if is_instance_valid(n):
			n.free()


func _telegraph() -> void:
	var w := _world()
	var s := w.fire(_rec(Vector3(10, 0, -60))) as MortarShell
	check(s.flight_time >= 2.0, "the telegraph lasts at least 2 s (%.2f)" % s.flight_time)
	var always := true
	var closing := true
	var last := INF
	var steps := 0
	while s.end_time < 0.0 and steps < 600:
		always = always and s.telegraph_visible() and s._ring_inner.visible and s._ring_outer.visible
		var r := s._ring_inner.global_transform.basis.get_scale().x
		closing = closing and r <= last + 0.0001
		var at := s._ring_inner.global_position
		always = always and Vector2(at.x - s.landing.x, at.z - s.landing.z).length() < 0.001
		last = r
		w.advance(1.0 / 60.0)
		steps += 1
	check(always, "the ground ring shows at the landing point for the whole flight")
	check(closing, "the ring closes as the shell falls")
	near(steps / 60.0, s.flight_time, 0.05, "the flight lasted its flight time (%.2f s)" % (steps / 60.0))
	check(last < 1.5, "the ring has closed by impact (%.2f m)" % last)
	check(not s._ring_inner.visible and not s._ring_outer.visible, "the ring goes at impact")
	var fx: ImpactFx = null
	for e in w.effects:
		if e is ImpactFx:
			fx = e
	if check(fx != null, "the impact spawns an ImpactFx"):
		near(fx.radius, 6.0, 0.001, "impact R 6 m")
		check(fx.column > 10.0, "with a tall column (%.1f m)" % fx.column)
		w.advance(0.15)
		check(fx.visible_parts("column") > 0, "the column shows")
		check(fx.visible_parts("tongue") > 0, "flame tongues show")
	w.free()
	await frames(1)


## One shell at a dummy 180 m out (with scatter), frame step dt, started `late` s after it left.
func _fly(dt: float, late: float) -> Dictionary:
	var w := _world()
	var d := _dummy(w, "d", Vector3(1.0, 0, -180))
	w.now = late
	var s := w.fire(_rec(Vector3(1.0, 1.9, -180), 4)) as MortarShell
	var out := {"landing": s.landing, "mid": s.flight_pos(1.3)}
	var impacts := _run(w, dt)
	out["impact"] = impacts[0] if impacts.size() > 0 else Vector3.INF
	out["end"] = s.end_time if is_instance_valid(s) else -1.0
	out["damage"] = d.total_max_hp() - d.total_hp()
	d.free()
	w.free()
	return out


func _determinism() -> void:
	var base := _fly(1.0 / 60.0, 0.0)
	check(float(base["damage"]) > 0.0, "the 180 m shell hurts the dummy (%.1f)" % float(base["damage"]))
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.13, 0.0], [1.0 / 60.0, 0.9], [1.0 / 60.0, 3.2]]:
		var r := _fly(v[0], v[1])
		var tag := "dt %.4f, %.2f s late" % [v[0], v[1]]
		check((r["landing"] as Vector3).is_equal_approx(base["landing"]), "same landing point (%s)" % tag)
		check((r["mid"] as Vector3).is_equal_approx(base["mid"]), "same arc (%s)" % tag)
		check((r["impact"] as Vector3).distance_to(base["impact"]) < 0.0005, "same impact (%s): %s vs %s" % [tag, r["impact"], base["impact"]])
		near(float(r["damage"]), float(base["damage"]), 0.0001, "same damage (%s)" % tag)
	await frames(1)


func _over_obstacle() -> void:
	var w := _world(true)
	var ground := _block(Vector3(60, 1, 260), Vector3(0, -0.5, -100))
	var wall := _block(Vector3(40, 12, 3), Vector3(0, 6, -50))
	await frames(3)
	var target := Vector3(0, 0, -110)
	var straight := w.first_hit(ORIGIN, target, 0.0)
	check(not straight.is_empty() and straight["target"] == null, "the wall blocks the straight line")
	var s := w.fire(_rec(target, 2)) as MortarShell
	var impacts := _run(w)
	if check(impacts.size() == 1, "one impact"):
		var p: Vector3 = impacts[0]
		var off := Vector2(p.x - target.x, p.z - target.z).length()
		check(off <= MortarShell.scatter_for(w.stats("mortar"), 110.0) + 0.3, "it lands on the aim point over the wall (%.2f m off)" % off)
		near(p.y, 0.0, 0.3, "on the ground")
		near(s.end_time if is_instance_valid(s) else s.flight_time, s.flight_time, 0.05, "after its full flight")
	ground.free()
	wall.free()
	w.free()
	await frames(1)


func _ceiling_and_wall() -> void:
	# A ceiling slab under the arc's apex: the shell bursts on its underside.
	var w := _world(true)
	var ground := _block(Vector3(60, 1, 260), Vector3(0, -0.5, -100))
	var slab := _block(Vector3(40, 1, 100), Vector3(0, 13.0, -50))
	await frames(3)
	var s := w.fire(_rec(Vector3(0, 0, -100), 1)) as MortarShell
	var ft := s.flight_time
	var impacts := _run(w)
	if check(impacts.size() == 1, "one impact under the ceiling"):
		near((impacts[0] as Vector3).y, 12.5, 0.35, "it detonates on the ceiling's underside (y %.2f)" % (impacts[0] as Vector3).y)
		check(s.end_time < ft * 0.8, "well before its flight time (%.2f of %.2f s)" % [s.end_time, ft])
	slab.free()
	# A tall wall in the way: the shell bursts on its face.
	var tall := _block(Vector3(40, 40, 2), Vector3(0, 20, -70))
	await frames(3)
	var s2 := w.fire(_rec(Vector3(0, 0, -100), 2)) as MortarShell
	var imp2 := _run(w)
	if check(imp2.size() == 1, "one impact on the wall"):
		near((imp2[0] as Vector3).z, -69.0, 0.35, "it detonates on the wall's face (z %.2f)" % (imp2[0] as Vector3).z)
		check(s2.end_time < s2.flight_time, "before landing")
	tall.free()
	ground.free()
	w.free()
	await frames(1)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.set_lab_option("weapon", "mortar")
	eq(lab.hardpoint, "back", "the mortar goes on the back hardpoint")
	lab.set_lab_option("fire", "hold")
	# Find the dummies by distance (the lab's layout may change): one inside 30 m, one in range.
	var close: TargetDummy = null
	var mid: TargetDummy = null
	var m := lab.muzzle()
	for d in lab.dummies:
		var dist := MortarShell.horizontal(m, d.global_position)
		if dist < 30.0 and close == null:
			close = d
		elif dist > 40.0 and dist < 130.0 and mid == null:
			mid = d
	if close != null:
		lab.set_lab_option("aim", close.name)
		for i in 20:
			lab.step(1.0 / 60.0)
		eq(lab.mount.shot_index, 0, "aimed inside 30 m (%s): no shot" % close.name)
		check(lab._heat_label.text.contains("TOO CLOSE"), "the lab says why: " + lab._heat_label.text.replace("\n", " | "))
	if check(mid != null, "a dummy in mortar range"):
		lab.set_lab_option("aim", mid.name)
		var hp0 := mid.total_hp()
		var shells := 0
		for i in 60 * 6:
			lab.step(1.0 / 60.0)
			shells = maxi(shells, lab.world.live_shots())
		check(lab.mount.shot_index >= 1, "the mortar fired in the lab (%d)" % lab.mount.shot_index)
		check(shells > 0, "a shell flew")
		check(mid.total_hp() < hp0, "the target took the shell (%.0f -> %.0f)" % [hp0, mid.total_hp()])
	lab.queue_free()
	await frames(1)
