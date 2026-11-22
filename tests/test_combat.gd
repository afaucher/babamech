extends TestCase
## The combat foundation (scripts/combat/, docs/design/weapons.md): deterministic shots (same record + seed -> same
## spread, path and impact at any frame step, and when started late), damage + falloff, splash, knockback per mass
## class, friction, stagger, wall slam, the heat gauge (overheat shutdown / reboot), WeaponMount cooldown + ammo + salvo,
## and the catalog (every weapon has every stat; sanitize_loadout enforces mounts and max_per_mech).


func setup() -> void:
	_catalog()
	_maths()
	_heat()
	_knockback()
	_mount()
	await _determinism()
	await _damage_and_splash()
	await _wall_slam()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
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


func _catalog() -> void:
	for id in ["laser", "autocannon", "rockets", "flamer", "mortar", "gatling", "swivel", "missiles", "railgun"]:
		var w := MechCatalog.weapon(id)
		if not check(not w.is_empty(), "weapon %s is in the catalog" % id):
			continue
		for k: String in MechCatalog.WEAPON_STATS:
			check(w.has(k), "weapon %s has %s" % [id, k])
	eq(int(MechCatalog.weapon("railgun").get("max_per_mech", 0)), 1, "one railgun per mech")
	var l := MechCatalog.sanitize_loadout("strider", {"shoulder_l": "railgun", "shoulder_r": "railgun", "side_l": "railgun"})
	eq(str(l["shoulder_l"]), "railgun", "the first railgun stays")
	eq(str(l["shoulder_r"]), "", "a second railgun is emptied")
	eq(str(l["side_l"]), "", "a railgun doesn't fit a side mount")
	var l2 := MechCatalog.sanitize_loadout("strider", {"shoulder_l": "autocannon", "side_r": "autocannon"})
	eq(str(l2["shoulder_l"]) + str(l2["side_r"]), "autocannonautocannon", "the autocannon fits shoulder and side, twice")
	for id: String in MechCatalog.WEAPON_ORDER:
		check(MechCatalog.WEAPONS.has(id), "WEAPON_ORDER names a catalog weapon: " + id)
	check(WeaponRegistry.built("autocannon"), "the autocannon is built")
	check(WeaponRegistry.behaviour("no_such_weapon") == null, "an unbuilt weapon has no behaviour")


func _maths() -> void:
	var st := MechCatalog.weapon("autocannon")
	near(Combat.falloff(st, 50.0), 1.0, 0.0001, "full damage inside falloff_start")
	near(Combat.falloff(st, 170.0), 0.8, 0.0001, "halfway down the falloff")
	near(Combat.falloff(st, 400.0), 0.6, 0.0001, "falloff_min at and past range")
	near(Combat.growth_scale(1.0, 3.0, 120.0, 0.0), 1.0, 0.0001, "growth starts at s0")
	near(Combat.growth_scale(1.0, 3.0, 120.0, 500.0), 3.0, 0.0001, "growth reaches g past d_full")
	near(Combat.segment_sphere(Vector3(0, 0, 0), Vector3(0, 0, -10), Vector3(0, 0, -5), 1.0), 0.4, 0.0001, "segment meets sphere")
	check(Combat.segment_sphere(Vector3(3, 0, 0), Vector3(3, 0, -10), Vector3(0, 0, -5), 1.0) < 0.0, "segment misses sphere")
	var a := Combat.spread_dir(Vector3.FORWARD, 0.4, Combat.shot_rng(1, "s", "hp", 3))
	var b := Combat.spread_dir(Vector3.FORWARD, 0.4, Combat.shot_rng(1, "s", "hp", 3))
	var c := Combat.spread_dir(Vector3.FORWARD, 0.4, Combat.shot_rng(1, "s", "hp", 4))
	check(a.is_equal_approx(b), "the same shot draws the same spread")
	check(not a.is_equal_approx(c), "the next shot draws another")
	check(rad_to_deg(a.angle_to(Vector3.FORWARD)) <= 0.4001, "spread stays inside the cone")


func _heat() -> void:
	var h := Heat.new(100.0, 6.0, 1.0)
	h.add(50.0)
	h.tick(1.0)
	near(h.value, 45.0, 0.001, "cooling minus passive")
	var tripped := [false]
	h.overheated.connect(func() -> void: tripped[0] = true)
	h.add(80.0)
	check(h.shutdown and tripped[0] and not h.can_act(), "reaching the cap shuts down")
	near(h.value, 100.0, 0.001, "heat stops at the cap")
	var t := 0.0
	while h.shutdown and t < 60.0:
		h.tick(0.1)
		t += 0.1
	check(not h.shutdown, "it reboots after cooling")
	near(h.value, 100.0 * Heat.REBOOT_AT, 0.6, "reboots at REBOOT_AT of the cap")
	near(t, (100.0 - 100.0 * Heat.REBOOT_AT) / 5.0, 0.15, "shutdown lasts until it has cooled")


func _knockback() -> void:
	# Mass classes.
	for m: String in Combat.MASS:
		var t := CombatTarget.new()
		t.mass_class = m
		t.apply_impulse(Vector3(0, 0, -4.0), "test")
		near(t.knock.velocity.length(), 4.0 * float(Combat.MASS[m]), 0.0001, "knockback x mass for %s" % m)
		if m == "static":
			near(t.aim_kick, 4.0 * Combat.AIM_KICK_DEG, 0.0001, "a static target takes aim kick")
			t.tick(0.1)
			near(t.aim_kick, 12.0 - Combat.AIM_KICK_RECOVER * 0.1, 0.0001, "aim kick recovers")
		t.free()
	# Friction: SLIDE_FRICTION for the hit-slide window, then FRICTION: 4 m/s slides d1 + v1² / 2a and stops.
	var k := Knockback.new()
	k.add(Vector3(4, 0, 0))
	var pos := Vector3.ZERO
	for i in 90:
		pos = k.step(1.0 / 60.0, pos, 0.0)["position"]
	near(k.velocity.length(), 0.0, 0.0001, "friction stops it")
	var v1 := 4.0 - Combat.SLIDE_FRICTION * Combat.HIT_SLIDE_TIME
	var slide := (4.0 + v1) * 0.5 * Combat.HIT_SLIDE_TIME + v1 * v1 / (2.0 * Combat.FRICTION)
	near(pos.x, slide, 0.08, "it slides through the hit-slide, then v^2 / 2a (%.2f m)" % slide)
	var k2 := Knockback.new()
	k2.add(Vector3(4, 0, 0))
	k2.step(Combat.HIT_SLIDE_TIME + 0.01, Vector3.ZERO, 0.0)
	var v_before := k2.velocity.length()
	k2.step(0.1, Vector3.ZERO, 0.0)
	near(v_before - k2.velocity.length(), Combat.FRICTION * 0.1, 0.0001, "past the hit-slide, full ground friction")
	# Stagger: >= 6 m/s inside 0.5 s.
	var s := Knockback.new()
	check(not s.add(Vector3(3, 0, 0)), "3 m/s doesn't stagger")
	s.step(0.2, Vector3.ZERO, 0.0)
	check(s.add(Vector3(3, 0, 0)), "6 m/s within 0.5 s staggers")
	near(s.stagger_left, Combat.STAGGER_TIME, 0.0001, "stagger lasts STAGGER_TIME")
	var s2 := Knockback.new()
	s2.add(Vector3(3, 0, 0))
	s2.step(0.6, Vector3.ZERO, 0.0)
	check(not s2.add(Vector3(3, 0, 0)), "the same Δv spread over more than 0.5 s doesn't")
	var t2 := CombatTarget.new()
	t2.mass_class = "light"
	t2.apply_impulse(Vector3(7, 0, 0), "x")
	check(not t2.can_act(), "a staggered target can't act")
	t2.free()


func _mount() -> void:
	var st := MechCatalog.weapon("autocannon")
	var h := Heat.new(100.0, 0.0)
	var m := WeaponMount.new()
	m.setup("autocannon", "side_r", "me", 1, st)
	var shots := 0
	var t := 0.0
	for i in 120:     # 2 s held at 60 Hz
		shots += m.update(1.0 / 60.0, true, h, t, Vector3.ZERO, Vector3(0, 0, -50)).size()
		t += 1.0 / 60.0
	eq(shots, 5, "2.5 shots/s for 2 s (first shot at once)")
	near(h.value, 5.0 * float(st["active_heat"]), 0.001, "active heat per shot")
	eq(m.shot_index, 5, "shot index counts")
	# Frame-rate independence: the same shots at 20 Hz, with the same times.
	var m2 := WeaponMount.new()
	m2.setup("autocannon", "side_r", "me", 1, st)
	var times: Array[float] = []
	t = 0.0
	for i in 40:
		t += 0.05
		for r in m2.update(0.05, true, null, t, Vector3.ZERO, Vector3(0, 0, -50)):
			times.append(float(r["t"]))
	eq(times.size(), 5, "5 shots at 20 Hz too")
	if times.size() >= 3:
		near(times[2] - times[1], 0.4, 0.0001, "shot times keep the cadence at any frame rate")
	# Shutdown blocks fire.
	var hot := Heat.new(100.0, 0.0)
	hot.add(100.0)
	var m3 := WeaponMount.new()
	m3.setup("autocannon", "side_r", "me", 1, st)
	eq(m3.update(0.1, true, hot, 0.0, Vector3.ZERO, Vector3.FORWARD).size(), 0, "no fire while shut down")
	# Ammo, salvo, reload (rockets: 6-shot salvo at 10/s, 4 s reload, 36 rounds). The rockets aren't built: give the mount
	# the default behaviour to test the cadence alone.
	var r := WeaponMount.new()
	r.setup("rockets", "shoulder_l", "me", 1, MechCatalog.weapon("rockets"))
	r.behaviour = WeaponBehaviour.new()
	var dry := [0]
	r.dry.connect(func() -> void: dry[0] += 1)
	var rh := Heat.new(1000.0, 0.0)
	var fired := 0
	var first_salvo := 0
	t = 0.0
	for i in 60 * 40:
		var n := r.update(1.0 / 60.0, true, rh, t, Vector3.ZERO, Vector3.FORWARD).size()
		fired += n
		t += 1.0 / 60.0
		if t <= 1.0:
			first_salvo += n
	eq(first_salvo, 6, "a press ripples one salvo of 6 in the first second")
	eq(fired, 36, "36 rockets, then empty")
	eq(r.ammo, 0, "ammo runs out")
	check(dry[0] > 0, "an empty weapon clicks dry")
	near(rh.value, 6.0 * float(MechCatalog.weapon("rockets")["active_heat"]), 0.001, "active heat per salvo")
	var u := WeaponMount.new()
	u.setup("no_such_weapon", "side_l", "me", 1, MechCatalog.weapon("laser"))
	eq(u.update(0.5, true, null, 0.0, Vector3.ZERO, Vector3.FORWARD).size(), 0, "an unbuilt weapon doesn't fire")


## Fly one autocannon shot at a dummy with frame step `dt`, starting `late` s after it left. Returns the dummy's damage,
## the shot's direction, its impact point and a mid-flight sample.
func _fly(dt: float, late: float) -> Dictionary:
	var w := _world()
	var d := _dummy(w, "d", Vector3(1.0, 0, -60))
	var rec := Combat.fire_record("me", 1, "side_r", "autocannon", Vector3(0, 1.9, 0), Vector3(1.0, 1.9, -60), 0.0, 9,
		float(MechCatalog.weapon("autocannon")["spread"]))
	w.now = late
	var p := w.fire(rec) as Projectile
	var out := {"dir": p.dir, "mid": p.flight_pos(0.5)}
	var hits: Array = []
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: hits.append(h))
	var guard := 0
	while w.live_shots() > 0 and guard < 2000:
		w.advance(dt)
		guard += 1
	out["damage"] = d.total_max_hp() - d.total_hp()
	out["point"] = (hits[0] as Hit).point if hits.size() > 0 else Vector3.INF
	out["hits"] = hits.size()
	d.free()
	w.free()
	return out


func _determinism() -> void:
	var base := _fly(1.0 / 60.0, 0.0)
	eq(int(base["hits"]), 1, "the shell hits the dummy")
	near(float(base["damage"]), 22.0, 0.001, "full direct damage inside falloff_start (no self splash)")
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.35], [1.0 / 60.0, 0.75]]:
		var r := _fly(v[0], v[1])
		var tag := "dt %.4f, started %.2f s late" % [v[0], v[1]]
		check((r["dir"] as Vector3).is_equal_approx(base["dir"]), "same spread (%s)" % tag)
		check((r["mid"] as Vector3).is_equal_approx(base["mid"]), "same path (%s)" % tag)
		check((r["point"] as Vector3).distance_to(base["point"]) < 0.0005, "same impact point (%s): %s vs %s" % [tag, r["point"], base["point"]])
		near(float(r["damage"]), float(base["damage"]), 0.0001, "same damage (%s)" % tag)
	await frames(1)


func _damage_and_splash() -> void:
	var w := _world()
	var far := _dummy(w, "far", Vector3(0, 0, -170))
	var near_ := _dummy(w, "near", Vector3(2.0, 0, -170))
	var rec := Combat.fire_record("me", 1, "side_r", "autocannon", Vector3(0, 1.9, 0), Vector3(0, 1.9, -170), 0.0, 1, 0.0)
	w.fire(rec)
	for i in 300:
		w.advance(1.0 / 60.0)
	var st := MechCatalog.weapon("autocannon")
	near(far.total_max_hp() - far.total_hp(), 22.0 * Combat.falloff(st, 169.0), 0.3, "damage falls off with distance")
	var splashed := near_.total_max_hp() - near_.total_hp()
	check(splashed > 0.0 and splashed < float(st["splash_damage"]), "a neighbour inside the splash radius takes part of the splash (%.2f)" % splashed)
	check(far.knock.velocity.length() > 0.0 or far.global_position.z < -170.0, "the direct hit shoves the target")
	# Knockback along the shot, per mass class, through the verb.
	for m: String in ["light", "mech", "heavy"]:
		var t := _dummy(w, "kb_" + m, Vector3(0, 0, 0), m)
		var h := Hit.new()
		h.impulse = Vector3(0, 0, -float(st["knockback"]))
		t.apply_hit(h)
		near(t.knock.velocity.z, -float(st["knockback"]) * float(Combat.MASS[m]), 0.0001, "autocannon Δv on a %s target" % m)
		t.free()
	far.free()
	near_.free()
	w.free()
	await frames(1)


func _wall_slam() -> void:
	var w := _world(true)
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 6, 1)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(0, 3, -6)
	add_child(wall)
	var d := _dummy(w, "slam", Vector3.ZERO)
	await frames(3)
	var slams: Array = []
	d.slammed.connect(func(sp: float, dmg: float) -> void: slams.append([sp, dmg]))
	d.apply_impulse(Vector3(0, 0, -15.0), "test")
	for i in 120:
		w.advance(1.0 / 60.0)
	if check(slams.size() == 1, "the dummy slams into the wall once (%d)" % slams.size()):
		var sp := float(slams[0][0])
		# Friction: SLIDE_FRICTION for HIT_SLIDE_TIME s after the shove, then FRICTION.
		var gap := 6.0 - 0.5 - d.body_radius
		var v1 := 15.0 - Combat.SLIDE_FRICTION * Combat.HIT_SLIDE_TIME
		var d1 := (15.0 + v1) * 0.5 * Combat.HIT_SLIDE_TIME
		var expect := sqrt(15.0 * 15.0 - 2.0 * Combat.SLIDE_FRICTION * gap) if gap <= d1 else sqrt(v1 * v1 - 2.0 * Combat.FRICTION * (gap - d1))
		near(sp, expect, 0.6, "slam speed after friction")
		near(float(slams[0][1]), (sp - Combat.SLAM_SPEED) * Combat.SLAM_DAMAGE, 0.001, "4 damage per m/s over 5")
		near(d.total_max_hp() - d.total_hp(), float(slams[0][1]), 0.001, "the slam damage lands on the dummy")
	check(d.global_position.z > -6.0 + 0.5, "the wall stops it (z %.2f)" % d.global_position.z)
	near(d.knock.velocity.length(), 0.0, 0.01, "it stops at the wall")
	d.free()
	wall.free()
	w.free()
