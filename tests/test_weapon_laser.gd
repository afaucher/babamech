extends TestCase
## The Side Laser (scripts/combat/weapons/laser.gd, Beam; docs/design/weapons.md §3.1): the charge delay before the
## pulse, the 1 / rate cadence at any frame rate, heat per pulse, damage with falloff at 40 / 80 / 115 / 150 m and
## nothing past range, knockback per mass class, world geometry blocks it, determinism (same record -> same hit point at
## any frame step and when started late; the beam shows for beam_time), and the weapon_range lab fires it at fanned-out
## dummies that each have a clear line and a wall behind.

var st: Dictionary


func setup() -> void:
	st = MechCatalog.weapon("laser")
	check(WeaponRegistry.built("laser"), "the laser is built")
	_cadence()
	_damage()
	_knockback()
	await _blocked()
	_determinism()
	await _lab()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 5
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


func _beams(w: CombatWorld) -> Array:
	return w.effects.filter(func(e: CombatEffect) -> bool: return e is Beam)


## Hold the trigger for `secs` at step `dt` (time passed = the end of each step). Returns the shot times; heat in `h`.
func _hold(dt: float, secs: float, h: Heat, pattern: Callable = Callable()) -> Array[float]:
	var m := WeaponMount.new()
	m.setup("laser", "side_l", "me", 1, st)
	var times: Array[float] = []
	var t := 0.0
	for i in int(round(secs / dt)):
		t += dt
		var held := true if not pattern.is_valid() else bool(pattern.call(t))
		for r in m.update(dt, held, h, t, Vector3.ZERO, Vector3(0, 0, -50)):
			times.append(float(r["t"]))
	return times


func _cadence() -> void:
	var charge := float(st["charge"])
	var cycle := 1.0 / float(st["rate"])
	near(charge, 0.15, 0.0001, "the charge is 0.15 s")
	near(cycle, 1.25, 0.0001, "the cycle is 1.25 s")
	var h := Heat.new(1000.0, 0.0)
	var base := _hold(1.0 / 60.0, 3.0, h)
	eq(base.size(), 3, "3 s held: pulses at 0.15, 1.40, 2.65 (%s)" % [base])
	if base.size() == 3:
		near(base[0], charge, 0.0001, "the first pulse waits for the charge")
		near(base[1] - base[0], cycle, 0.0001, "the cycle includes the charge")
		near(base[2] - base[1], cycle, 0.0001, "the cadence holds")
	near(h.value, 3.0 * float(st["active_heat"]), 0.0001, "9 heat per pulse")
	near(float(st["active_heat"]), 9.0, 0.0001, "the catalog says 9 heat a pulse")
	eq(_hold(1.0 / 60.0, 0.13, null).size(), 0, "no pulse before the charge completes")
	for dt: float in [1.0 / 30.0, 0.05, 1.0 / 144.0, 0.07]:
		var times := _hold(dt, 3.0, null)
		eq(times.size(), 3, "3 pulses at dt %.4f" % dt)
		for i in mini(times.size(), base.size()):
			near(times[i], base[i], 0.0001, "pulse %d at the same time at dt %.4f" % [i, dt])
	# Releasing before the charge completes cancels it: a re-press charges from zero.
	var tap := _hold(1.0 / 60.0, 1.0, null, func(t: float) -> bool: return t <= 0.1 or t > 0.5)
	eq(tap.size(), 1, "an early release fires nothing; the re-press fires once")
	if tap.size() == 1:
		near(tap[0], 0.5 + charge, 0.0001, "the re-press charges the full 0.15 s (%.4f)" % tap[0])


func _pulse(w: CombatWorld, dist: float, index: int = 0) -> Array:
	var hits: Array = []
	var cb := func(_t: CombatTarget, hh: Hit) -> void: hits.append(hh)
	w.hit_landed.connect(cb)
	w.fire(Combat.fire_record("me", 1, "side_l", "laser", Vector3(0, 1.9, 0), Vector3(0, 1.9, -dist), w.now, index))
	w.hit_landed.disconnect(cb)
	return hits


func _damage() -> void:
	for dist: float in [40.0, 80.0, 115.0, 150.0]:
		var w := _world()
		var d := _dummy(w, "d", Vector3(0, 0, -dist))
		var hits := _pulse(w, dist)
		if check(hits.size() == 1, "the pulse hits the dummy at %d m" % int(dist)):
			var hd := Vector3(0, 1.9, 0).distance_to((hits[0] as Hit).point)
			var want := 55.0 * Combat.falloff(st, hd)
			near(d.total_max_hp() - d.total_hp(), want, 0.001, "damage at %d m (hit at %.2f m): %.2f" % [int(dist), hd, want])
			if dist <= 80.0:
				near(want, 55.0, 0.001, "full damage inside 80 m")
			elif dist >= 150.0:
				near(want, 27.5, 0.6, "about half damage at range")
			else:
				check(want < 55.0 and want > 27.5, "falling off between 80 and 150 m (%.2f)" % want)
		var b := _beams(w)
		if check(b.size() == 1, "one beam at %d m" % int(dist)) and hits.size() == 1:
			check(((b[0] as Beam).b as Vector3).distance_to((hits[0] as Hit).point) < 0.001, "the beam ends at the hit")
		d.free()
		w.free()
	var w2 := _world()
	var far := _dummy(w2, "far", Vector3(0, 0, -152.5))
	eq(_pulse(w2, 152.5).size(), 0, "nothing past 150 m")
	eq(far.total_hp(), far.total_max_hp(), "the far dummy keeps its HP")
	var bb := _beams(w2)
	if check(bb.size() == 1, "a miss still draws a beam"):
		near(((bb[0] as Beam).a as Vector3).distance_to((bb[0] as Beam).b), 150.0, 0.001, "a miss draws the full 150 m")
	far.free()
	w2.free()


func _knockback() -> void:
	for m: String in Combat.MASS_ORDER:
		var w := _world()
		var d := _dummy(w, "kb", Vector3(0, 0, -30), m)
		_pulse(w, 30.0)
		var f := float(Combat.MASS[m])
		var kb := float(MechCatalog.weapon("laser")["knockback"])
		if m == "static":
			near(d.aim_kick, kb * Combat.AIM_KICK_DEG, 0.001, "a static target takes Δv x 3 deg of aim kick")
		else:
			near(d.knock.velocity.z, -kb * f, 0.001, "knockback %.1f x %.2f on a %s target" % [kb, f, m])
			near(d.knock.velocity.x, 0.0, 0.001, "along the beam (%s)" % m)
		d.free()
		w.free()


func _blocked() -> void:
	var w := _world(true)
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 6, 1)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(0, 3, -20)
	add_child(wall)
	var d := _dummy(w, "behind", Vector3(0, 0, -40))
	await frames(3)
	var n := w.effects.size()
	var hits := _pulse(w, 40.0)
	eq(hits.size(), 0, "the wall blocks the beam")
	eq(d.total_hp(), d.total_max_hp(), "the dummy behind the wall keeps its HP")
	var b := _beams(w)
	if check(b.size() == 1, "the blocked pulse draws a beam"):
		near(((b[0] as Beam).b as Vector3).z, -19.5, 0.01, "the beam stops at the wall face")
	check(w.effects.filter(func(e: CombatEffect) -> bool: return e is ImpactFx).size() == 1, "an impact on the wall")
	check(w.effects.size() > n + 1, "beam + impact are live")
	d.free()
	wall.free()
	w.free()


## One pulse at a dummy, stepped at `dt`, the record started `late` s before `now`. Returns the hit point, damage and how
## long the beam stayed.
func _run(dt: float, late: float) -> Dictionary:
	var w := _world()
	var d := _dummy(w, "d", Vector3(0.6, 0, -60))
	var hits: Array = []
	w.hit_landed.connect(func(_t: CombatTarget, hh: Hit) -> void: hits.append(hh))
	w.now = 10.0 + late
	w.fire(Combat.fire_record("me", 1, "side_l", "laser", Vector3(-1.2, 3.0, 0), Vector3(0.6, 1.9, -60), 10.0, 4))
	var shown := 0.0 if _beams(w).is_empty() else late
	var guard := 0
	while not _beams(w).is_empty() and guard < 1000:
		w.advance(dt)
		if not _beams(w).is_empty():
			shown = w.now - 10.0
		guard += 1
	var out := {"point": (hits[0] as Hit).point if hits.size() == 1 else Vector3.INF, "hits": hits.size(),
		"damage": d.total_max_hp() - d.total_hp(), "shown": shown}
	d.free()
	w.free()
	return out


func _determinism() -> void:
	var base := _run(1.0 / 60.0, 0.0)
	eq(int(base["hits"]), 1, "the pulse hits once")
	near(float(base["shown"]), float(st["beam_time"]), 1.0 / 60.0 + 0.0001, "the beam shows for beam_time (%.3f s)" % float(base["shown"]))
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.1], [1.0 / 60.0, 0.5]]:
		var r := _run(v[0], v[1])
		var tag := "dt %.4f, started %.2f s late" % [v[0], v[1]]
		eq(int(r["hits"]), 1, "one hit (%s)" % tag)
		check((r["point"] as Vector3).distance_to(base["point"]) < 0.0001, "same hit point (%s): %s vs %s" % [tag, r["point"], base["point"]])
		near(float(r["damage"]), float(base["damage"]), 0.0001, "same damage (%s)" % tag)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	add_child(lab)
	await frames(3)
	lab.set_lab_option("fire", "off")
	lab.set_lab_option("weapon", "laser")
	lab.set_lab_option("mass", "heavy")
	var guard := 0
	while lab.world.live_shots() > 0 and guard < 400:     # the default autocannon's shells still in flight
		await frames(1)
		guard += 1
	lab.set_lab_option("fire", "hold")
	eq(lab.hardpoint, "side_r", "the laser mounts on a side hardpoint")
	# Every dummy in range takes a pulse (a clear line from the side hardpoint: the fan).
	for dist in [25, 50, 100]:
		lab.set_lab_option("aim", "dummy_%d" % dist)
		var d := lab.aim_dummy()
		var beams := 0
		for i in 40:
			await frames(1)
			beams = maxi(beams, _beams(lab.world).size())
		check(lab.mount.shot_index >= 1, "the lab fired the laser at dummy_%d" % dist)
		check(beams > 0, "a beam showed toward dummy_%d" % dist)
		check(d.total_hp() < d.total_max_hp(), "dummy_%d lost HP (%.1f)" % [dist, d.total_hp()])
		for other in lab.dummies:
			if other != d:
				eq(other.total_hp(), other.total_max_hp(), "only dummy_%d was hit, not %s" % [dist, other.name])
	# Nothing stands between the stand and any dummy, from either side hardpoint, and a wall stands behind each.
	await frames(2)
	for hp: String in ["side_l", "side_r"]:
		lab.set_lab_option("hardpoint", hp)
		for d in lab.dummies:
			var from := lab.muzzle()
			var to := d.global_position + Vector3(0, 1.9, 0)
			var h := lab.world.first_hit(from, to, 0.2, WeaponRangeLab.SHOOTER)
			check(not h.is_empty() and h["target"] == d, "%s has a clear line to %s" % [hp, d.name])
	for i in lab.dummies.size():
		var d := lab.dummies[i]
		var c := d.global_position + Vector3(0, 1.9, 0)
		var h := lab.world.first_hit(c, c + WeaponRangeLab.dummy_dir(i) * 10.0, 0.0, "", [d.target_id])
		check(not h.is_empty() and h["target"] == null, "a wall behind %s" % d.name)
		if not h.is_empty():
			near(c.distance_to(h["point"]), WeaponRangeLab.WALL_BEHIND, 0.05, "the wall is %.0f m behind %s" % [WeaponRangeLab.WALL_BEHIND, d.name])
	lab.queue_free()
	await frames(1)
