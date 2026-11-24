extends TestCase
## The Coil Railgun (scripts/combat/weapons/railgun.gd, RailSlug; docs/design/weapons.md §3.8): the 1 s charge then the
## slug at an exact time at any frame step, the 4 s cycle, 30 heat a shot, an early release cancels for 10 heat; 200
## damage with no falloff at 50 and 350 m and nothing past 400 m; pierces three targets in a line (200 / 150 / 112.5),
## each hit once, a fourth untouched; stops at a wall; knockback Δv 14 (a light target flies and staggers, a mech-class
## one staggers); determinism (same record -> same hits at any frame step and when started late); the trail hangs
## stats.trail s after the slug stops, then the node is freed; the charge glow grows in steps; one railgun per mech;
## the weapon_range lab fires it in "single" and "hold". AMMO: 18 rounds (27 with the ammo bin), one spent per slug,
## none on a cancelled charge; dry, no charge starts (no glow, no cancel heat) and the rack's UNUSABLE rule deselects the
## slot (hold EMPTY) until WeaponRack.refill_ammo (a supply depot's core) loads it again; slots() carries the count.

const FROM := Vector3(0, 1.9, 0)

var st: Dictionary


func setup() -> void:
	st = MechCatalog.weapon("railgun")
	check(WeaponRegistry.built("railgun"), "the railgun is built")
	near(float(st["knockback"]), 14.0, 0.0001, "the catalog knockback is 14 (weapons.md §3)")
	_cadence()
	_cancel()
	_shutdown_release()
	_glow()
	_damage()
	_pierce()
	await _wall()
	_knockback()
	_determinism()
	_one_per_mech()
	_ammo()
	await _rack_ammo()
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


func _slugs(w: CombatWorld) -> Array:
	return w.effects.filter(func(e: CombatEffect) -> bool: return e is RailSlug)


## Hold (or follow `pattern(t)`) for `secs` at step `dt`. Returns the shot times; heat in `h`.
func _hold(dt: float, secs: float, h: Heat, pattern: Callable = Callable()) -> Array[float]:
	var m := WeaponMount.new()
	m.setup("railgun", "shoulder_l", "me", 1, st)
	var times: Array[float] = []
	var t := 0.0
	for i in int(round(secs / dt)):
		t += dt
		var held := true if not pattern.is_valid() else bool(pattern.call(t))
		for r in m.update(dt, held, h, t, Vector3.ZERO, Vector3(0, 0, -50)):
			times.append(float(r["t"]))
	return times


func _cadence() -> void:
	near(float(st["charge"]), 1.0, 0.0001, "the charge is 1.0 s")
	near(1.0 / float(st["rate"]), 4.0, 0.0001, "the cycle is 4 s")
	near(float(st["active_heat"]), 30.0, 0.0001, "30 heat a shot")
	var h := Heat.new(1000.0, 0.0)
	var base := _hold(1.0 / 60.0, 9.5, h)
	eq(base.size(), 3, "9.5 s held: slugs at 1, 5, 9 (%s)" % [base])
	for i in mini(base.size(), 3):
		near(base[i], 1.0 + 4.0 * float(i), 0.0001, "slug %d at %.0f s" % [i, 1.0 + 4.0 * float(i)])
	near(h.value, 90.0, 0.0001, "three full shots cost 3 x 30 heat (%.2f)" % h.value)
	eq(_hold(1.0 / 60.0, 0.98, null).size(), 0, "no slug before the charge completes")
	for dt: float in [1.0 / 30.0, 1.0 / 144.0, 0.11]:
		var times := _hold(dt, 9.5, null)
		eq(times.size(), 3, "3 slugs at dt %.4f" % dt)
		for i in mini(times.size(), base.size()):
			near(times[i], base[i], 0.0001, "slug %d at the same time at dt %.4f (%.5f)" % [i, dt, times[i]])


func _cancel() -> void:
	var h := Heat.new(1000.0, 0.0)
	eq(_hold(1.0 / 60.0, 2.0, h, func(t: float) -> bool: return t <= 0.5).size(), 0, "an early release fires nothing")
	near(h.value, 10.0, 0.0001, "an early release costs cancel_heat 10 (%.2f)" % h.value)
	var h2 := Heat.new(1000.0, 0.0)
	var re := _hold(1.0 / 60.0, 4.0, h2, func(t: float) -> bool: return t <= 0.5 or t > 2.0)
	eq(re.size(), 1, "the re-press fires once")
	if re.size() == 1:
		near(re[0], 3.0, 0.0001, "the re-press charges the full 1 s (%.4f)" % re[0])
	near(h2.value, 40.0, 0.0001, "cancel 10 + shot 30 (%.2f)" % h2.value)
	var h3 := Heat.new(1000.0, 0.0)
	eq(_hold(1.0 / 60.0, 3.0, h3, func(t: float) -> bool: return t <= 1.3).size(), 1, "a held charge fires")
	near(h3.value, 30.0, 0.0001, "releasing after the shot costs nothing more (%.2f)" % h3.value)
	var h4 := Heat.new(1000.0, 0.0)
	_hold(1.0 / 60.0, 3.0, h4, func(_t: float) -> bool: return false)
	near(h4.value, 0.0, 0.0001, "an idle trigger costs nothing")


## A shutdown is not a cancel: a full charge held while the mech is shut down (it can't fire) and then released costs
## nothing, and neither does releasing a part charge during the shutdown.
func _shutdown_release() -> void:
	var h := Heat.new(100.0, 0.0)
	h.add(100.0)
	h.value = 70.0     # cooling, still shut down (reboot at 40): a cancel would show above the cap clamp
	check(h.shutdown, "the gauge is shut down")
	var m := WeaponMount.new()
	m.setup("railgun", "shoulder_l", "me", 1, st)
	var shots := 0
	var t := 0.0
	var dt := 1.0 / 60.0
	for i in 150:      # 1.5 s held: the charge fills, no slug (shut down), then 1 s released
		t += dt
		shots += m.update(dt, t <= 1.5, h, t, Vector3.ZERO, Vector3(0, 0, -50)).size()
		if i == 80:
			check(m.charge >= float(st["charge"]), "the full charge is held during the shutdown (%.2f)" % m.charge)
	for i in 60:
		t += dt
		shots += m.update(dt, false, h, t, Vector3.ZERO, Vector3(0, 0, -50)).size()
	eq(shots, 0, "nothing fires while shut down")
	near(h.value, 70.0, 0.0001, "releasing a full charge during the shutdown costs no cancel heat (%.2f)" % h.value)
	var m2 := WeaponMount.new()
	m2.setup("railgun", "shoulder_l", "me", 1, st)
	var h2 := Heat.new(100.0, 0.0)
	h2.add(50.0)
	t = 0.0
	for i in 30:       # half a charge, then the mech shuts down (something else heats it), then the release
		t += dt
		m2.update(dt, true, h2, t, Vector3.ZERO, Vector3(0, 0, -50))
	h2.add(50.0)
	h2.value = 70.0
	m2.update(dt, false, h2, t + dt, Vector3.ZERO, Vector3(0, 0, -50))
	near(h2.value, 70.0, 0.0001, "releasing a part charge while shut down costs no cancel heat (%.2f)" % h2.value)


func _glow() -> void:
	var m := WeaponMount.new()
	m.setup("railgun", "shoulder_l", "me", 1, st)
	eq(int(st.get("charge_steps", 0)), 4, "four coils")
	for v: Array in [[0.0, 0.0], [0.01, 0.25], [0.3, 0.25], [0.5, 0.5], [0.74, 0.5], [0.8, 0.75], [1.0, 1.0]]:
		m.charge = v[0]
		near(ChargeGlow.fraction(m), v[1], 0.0001, "the glow at %.2f s of charge shows %.2f (the coils light one by one)" % [v[0], v[1]])
	var lm := WeaponMount.new()
	lm.setup("laser", "side_l", "me", 1, MechCatalog.weapon("laser"))
	lm.charge = float(lm.stats["charge"]) * 0.3
	near(ChargeGlow.fraction(lm), 0.3, 0.0001, "the laser's glow stays smooth")


## Fire one slug from FROM toward -Z at w.now; advance until no slug is live. Returns the hits [{id, damage, point}].
func _shoot(w: CombatWorld, dt: float = 1.0 / 60.0, index: int = 0) -> Array:
	var hits: Array = []
	var cb := func(t: CombatTarget, hh: Hit) -> void: hits.append({"id": t.target_id, "damage": hh.damage, "point": hh.point})
	w.hit_landed.connect(cb)
	w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", FROM, FROM + Vector3(0, 0, -100), w.now, index))
	var guard := 0
	while not _slugs(w).is_empty() and guard < 2000:
		w.advance(dt)
		guard += 1
	w.hit_landed.disconnect(cb)
	return hits


func _damage() -> void:
	for dist: float in [50.0, 350.0]:
		var w := _world()
		var d := _dummy(w, "d", Vector3(0, 0, -dist), "heavy")
		var hits := _shoot(w)
		if check(hits.size() == 1, "the slug hits the dummy at %d m" % int(dist)):
			near(float(hits[0]["damage"]), 200.0, 0.0001, "200 damage at %d m (no falloff)" % int(dist))
			near(d.total_max_hp() - d.total_hp(), 200.0, 0.0001, "the dummy at %d m lost 200 HP" % int(dist))
		d.free()
		w.free()
	var w2 := _world()
	var far := _dummy(w2, "far", Vector3(0, 0, -402.0))
	eq(_shoot(w2).size(), 0, "nothing past 400 m")
	eq(far.total_hp(), far.total_max_hp(), "the far dummy keeps its HP")
	far.free()
	w2.free()


func _pierce() -> void:
	var w := _world()
	var ds: Array[TargetDummy] = []
	for i in 4:
		ds.append(_dummy(w, "d%d" % i, Vector3(0, 0, -30.0 - 10.0 * i), "heavy"))
	var impacts := [0]
	w.impact_spawned.connect(func(_p: Vector3, _r: float, _x: bool, _e: bool) -> void: impacts[0] += 1)
	var hits := _shoot(w)
	eq(hits.size(), 3, "three targets hit (%d)" % hits.size())
	var want := [200.0, 150.0, 112.5]
	var ids := {}
	for i in mini(hits.size(), 3):
		eq(str(hits[i]["id"]), "d%d" % i, "hit %d is d%d, in order" % [i, i])
		near(float(hits[i]["damage"]), want[i], 0.0001, "d%d takes %.1f" % [i, want[i]])
		near(ds[i].total_max_hp() - ds[i].total_hp(), want[i], 0.0001, "d%d lost %.1f HP" % [i, want[i]])
		ids[str(hits[i]["id"])] = int(ids.get(str(hits[i]["id"]), 0)) + 1
	for k: String in ids:
		eq(int(ids[k]), 1, "%s is hit once" % k)
	eq(ds[3].total_hp(), ds[3].total_max_hp(), "the fourth in line is untouched: the slug stopped in the third")
	eq(impacts[0], 5, "an entry burst on each of 3 targets + an exit burst on the 2 pierced (%d)" % impacts[0])
	for d in ds:
		d.free()
	w.free()
	# The trail hangs stats.trail s after the slug stops, then the node is freed.
	var w3 := _world()
	var d3 := _dummy(w3, "t", Vector3(0, 0, -40), "static")
	w3.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", FROM, FROM + Vector3(0, 0, -100), 0.0, 0))
	var slug := _slugs(w3)[0] as RailSlug
	var dt := 1.0 / 60.0
	var stopped := -1.0
	var gone := -1.0
	var drawn_late := false
	var guard := 0
	while gone < 0.0 and guard < 600:
		w3.advance(dt)
		guard += 1
		if stopped < 0.0 and slug.end_time >= 0.0:
			stopped = slug.end_time
		if stopped >= 0.0 and w3.now - stopped > 1.2 and w3.now - stopped < 1.4 and is_instance_valid(slug) and slug in w3.effects:
			drawn_late = drawn_late or slug.trail_drawn()
		if not slug in w3.effects:
			gone = w3.now
	check(stopped > 0.0, "the slug stopped in the target")
	near(gone - stopped, float(st["trail"]), dt + 0.0001, "the trail node lives %.2f s after the stop (%.3f)" % [float(st["trail"]), gone - stopped])
	check(drawn_late, "the trail still draws 1.3 s after the stop")
	near(float(st["trail"]), 1.5, 0.0001, "the trail hangs 1.5 s")
	d3.free()
	w3.free()


func _wall() -> void:
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
	w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", FROM, FROM + Vector3(0, 0, -100), w.now, 0))
	var slug := _slugs(w)[0] as RailSlug
	var hits := [0]
	w.hit_landed.connect(func(_t: CombatTarget, _h: Hit) -> void: hits[0] += 1)
	for i in 30:
		w.advance(1.0 / 60.0)
	eq(hits[0], 0, "the wall stops the slug")
	eq(d.total_hp(), d.total_max_hp(), "the dummy behind the wall keeps its HP")
	check(slug.end_time >= 0.0, "the slug ended")
	if slug.end_time >= 0.0:
		near(slug.flight_pos(slug.end_time).z, -19.5, 0.05, "at the wall face")
	check(w.effects.filter(func(e: CombatEffect) -> bool: return e is ImpactFx).size() == 1, "one impact on the wall")
	d.free()
	wall.free()
	w.free()


func _knockback() -> void:
	var res := {}
	for m: String in ["light", "mech", "heavy"]:
		var w := _world()
		var d := _dummy(w, "kb", Vector3(0, 0, -25), m)
		var home := d.global_position
		var stag := [false]
		d.staggered_by.connect(func(_s: String) -> void: stag[0] = true)
		_shoot(w)
		var guard := 0
		while d.knock.moving() and guard < 1200:
			w.advance(1.0 / 60.0)
			guard += 1
		res[m] = {"slid": d.global_position.distance_to(home), "stagger": stag[0]}
		print("railgun knockback %-6s slid %6.2f m  stagger %s" % [m, res[m]["slid"], res[m]["stagger"]])
		d.free()
		w.free()
	check(res["light"]["slid"] >= 10.0, "a light target flies >= 10 m (%.2f)" % res["light"]["slid"])
	check(res["light"]["stagger"], "a light target is staggered")
	check(res["mech"]["stagger"], "a mech-class target is staggered (Δv 7 >= %.1f)" % Combat.STAGGER_DV)
	check(res["mech"]["slid"] < res["light"]["slid"] * 0.6, "a mech-class target slides much less (%.2f)" % res["mech"]["slid"])
	check(res["heavy"]["slid"] < res["mech"]["slid"], "heavy moves less than mech")


## One slug through three dummies (slightly off line), stepped at `dt`, the record started `late` s before now.
func _run(dt: float, late: float) -> Array:
	var w := _world()
	var ds: Array[TargetDummy] = []
	for i in 3:
		ds.append(_dummy(w, "r%d" % i, Vector3(0.3 * float(i) - 0.3, 0, -60.0 - 15.0 * i), "heavy"))
	var hits: Array = []
	w.hit_landed.connect(func(t: CombatTarget, hh: Hit) -> void: hits.append({"id": t.target_id, "damage": hh.damage, "point": hh.point}))
	w.now = 10.0 + late
	w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", Vector3(-1.2, 3.0, 0), Vector3(0.2, 1.9, -90), 10.0, 4))
	var guard := 0
	while not _slugs(w).is_empty() and guard < 3000:
		w.advance(dt)
		guard += 1
	for d in ds:
		d.free()
	w.free()
	return hits


func _determinism() -> void:
	var base := _run(1.0 / 60.0, 0.0)
	eq(base.size(), 3, "the slug pierces all three (%d)" % base.size())
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.1], [1.0 / 60.0, 0.33]]:
		var r := _run(v[0], v[1])
		var tag := "dt %.4f, started %.2f s late" % [v[0], v[1]]
		eq(r.size(), base.size(), "same hit count (%s)" % tag)
		for i in mini(r.size(), base.size()):
			eq(str(r[i]["id"]), str(base[i]["id"]), "hit %d same target (%s)" % [i, tag])
			check((r[i]["point"] as Vector3).distance_to(base[i]["point"]) < 0.0001, "hit %d same point (%s)" % [i, tag])
			near(float(r[i]["damage"]), float(base[i]["damage"]), 0.0001, "hit %d same damage (%s)" % [i, tag])


func _one_per_mech() -> void:
	var l := MechCatalog.sanitize_loadout("strider", {"shoulder_l": "railgun", "shoulder_r": "railgun", "back": "mortar"})
	var n := 0
	for k: String in l:
		if str(l[k]) == "railgun":
			n += 1
	eq(n, 1, "sanitize_loadout keeps one railgun (%s)" % str(l))
	eq(str(l["shoulder_l"]), "railgun", "the first one stays")


func _ammo() -> void:
	eq(int(st["ammo"]), 18, "18 rounds (weapons.md §3.8)")
	eq(WeaponRack.bonus_ammo(int(st["ammo"]), int(st["salvo"]), 0.5), 27, "27 with the ammo bin")
	var m := WeaponMount.new()
	m.setup("railgun", "shoulder_l", "me", 1, st)
	eq(m.ammo, 18, "a mount loads 18")
	var h := Heat.new(100000.0, 0.0)
	var dt := 1.0 / 60.0
	var t := 0.0
	var shots := 0
	# A cancelled charge spends nothing.
	for i in 30:
		t += dt
		shots += m.update(dt, true, h, t, Vector3.ZERO, Vector3(0, 0, -50)).size()
	t += dt
	m.update(dt, false, h, t, Vector3.ZERO, Vector3(0, 0, -50))
	eq(shots, 0, "half a charge: no slug")
	eq(m.ammo, 18, "a cancelled charge spends no round")
	# Held: 18 slugs over 18 cycles, then dry.
	for i in int(80.0 / dt):
		t += dt
		shots += m.update(dt, true, h, t, Vector3.ZERO, Vector3(0, 0, -50)).size()
	eq(shots, 18, "held 80 s: 18 slugs, then nothing")
	eq(m.ammo, 0, "ammo at 0")
	near(h.value, 10.0 + 18.0 * 30.0, 1e-3, "heat: one cancel + 18 shots, nothing while dry (%.1f)" % h.value)
	near(m.charge, 0.0, 1e-9, "dry: no charge builds while held")
	near(ChargeGlow.fraction(m), 0.0, 1e-9, "dry: no glow")
	var h0 := h.value
	t += dt
	m.update(dt, false, h, t, Vector3.ZERO, Vector3(0, 0, -50))
	near(h.value, h0, 1e-9, "dry: releasing costs no cancel heat")


## The rack: slots() carries the count (27/27 with the bin); the last round deselects the slot (EMPTY); a refill loads
## 27 again and leaves it deselected until its key.
func _rack_ammo() -> void:
	var world := CombatWorld.new()
	world.use_physics = false
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"shoulder_l": "railgun", "back": "ammo_bin"})
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "railrack", 1)
	rack.aim_point = Vector3(0, 3, -60)
	await frames(2)
	var n := rack.hardpoints.find("shoulder_l") + 1
	if not check(n > 0, "the rack has shoulder_l"):
		return
	var sl: Dictionary = rack.slots()[n - 1]
	eq(str(sl["weapon"]), "railgun", "the slot holds the railgun")
	eq(int(sl["ammo"]), 27, "slots(): 27 rounds with the bin")
	eq(int(sl["ammo_max"]), 27, "slots(): of 27")
	var fired := [0]
	rack.fired.connect(func(_n: int) -> void: fired[0] += 1)
	rack.mounts[n - 1].ammo = 1
	rack.set_trigger(true)
	for i in int(6.0 / (1.0 / 60.0)):
		rack.step(1.0 / 60.0)
		world.advance(1.0 / 60.0)
	rack.set_trigger(false)
	rack.step(1.0 / 60.0)
	eq(fired[0], 1, "the last round fires once")
	sl = rack.slots()[n - 1]
	eq(int(sl["ammo"]), 0, "slots(): 0 rounds")
	check(not rack.enabled[n - 1] and not bool(sl["usable"]), "dry: deselected and unusable")
	eq(str(sl["hold"]), "EMPTY", "dry: hold EMPTY")
	near(rack.mounts[n - 1].charge, 0.0, 1e-9, "dry: no charge held")
	eq(rack.refill_ammo(), 1, "a depot core refills the railgun")
	sl = rack.slots()[n - 1]
	eq(int(sl["ammo"]), 27, "refilled to 27")
	check(bool(sl["usable"]) and not rack.enabled[n - 1], "refilled: usable, still deselected until its key")
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	add_child(lab)
	await frames(3)
	lab.set_lab_option("fire", "off")
	lab.set_lab_option("weapon", "railgun")
	lab.set_lab_option("mass", "heavy")
	lab.set_lab_option("aim", "dummy_50")
	check(lab.hardpoint.begins_with("shoulder"), "the railgun mounts on a shoulder (%s)" % lab.hardpoint)
	for mode: String in ["single", "hold"]:
		var d := lab.aim_dummy()
		d.reset_dummy()
		var n := lab.mount.shot_index
		lab.set_lab_option("fire", mode)
		var slugs := 0
		var glow := false
		for i in 400:
			await frames(1)
			slugs = maxi(slugs, _slugs(lab.world).size())
			glow = glow or lab.mount.charge > 0.0
			if lab.mount.shot_index > n and d.total_hp() < d.total_max_hp():
				break
		check(glow, "%s: the railgun charges" % mode)
		check(lab.mount.shot_index > n, "%s: the lab fired the railgun" % mode)
		check(slugs > 0, "%s: a slug flew" % mode)
		check(d.total_hp() < d.total_max_hp(), "%s: dummy_50 lost HP (%.1f)" % [mode, d.total_hp()])
		lab.set_lab_option("fire", "off")
		await frames(2)
	lab.queue_free()
	await frames(1)
