extends TestCase
## The Swivel Boom (scripts/combat/weapons/swivel.gd, docs/design/weapons.md §3.4, §4.4) and the fixed-weapon arc switch
## (Combat.FIXED_ARC_ENABLED): 4 rounds/s from alternating barrels at any frame step; rounds leave along the boom's
## current direction; a 90° snap takes 0.375 s to slew and the rounds fired meanwhile fan through the intermediate
## directions; ±120° yaw / -40°..+60° pitch, holding fire with "OUT OF ARC" outside them with the boom at the limit; the
## arc turns with the body basis (default: world -Z); damage / falloff / knockback / heat per round; determinism; the
## fixed arc (off: nothing changes; on: the autocannon holds outside its ±30° pivot range, the mortar and the swivel don't);
## WeaponRack.slots() carries the reason and turns the boom model; the weapon_range lab fires it.

const SHOOTER := "me"
const STEPS := [1.0 / 60.0, 1.0 / 30.0, 1.0 / 144.0, 0.11]
const PIVOT := Vector3(0, 2, 0)

var st: Dictionary


func setup() -> void:
	st = MechCatalog.weapon("swivel")
	Combat.FIXED_ARC_ENABLED = false
	check(WeaponRegistry.built("swivel"), "the swivel is built")
	_cadence()
	_boom_direction()
	_slew()
	_arcs()
	_rotated_body()
	_default_basis()
	_heat()
	await _damage_and_knockback()
	await _determinism()
	_fixed_arc()
	await _rack()
	await _lab()
	Combat.FIXED_ARC_ENABLED = false
	finish()


func _mount(id: String = "swivel") -> WeaponMount:
	var m := WeaponMount.new()
	m.setup(id, "side_r", SHOOTER, 1, MechCatalog.weapon(id))
	return m


## The muzzle point the firer passes for a boom pivoting at PIVOT on `body` (muzzle ahead of the hardpoint).
func _muzzle(body: Basis = Basis.IDENTITY) -> Vector3:
	return PIVOT + body * Vector3(0, 0, -float(st["muzzle"]))


## An aim point `dist` m from the pivot at body-frame yaw / pitch (deg).
func _aim(yaw: float, pitch: float = 0.0, body: Basis = Basis.IDENTITY, dist: float = 60.0) -> Vector3:
	return PIVOT + Combat.arc_dir(body, Vector2(yaw, pitch)) * dist


## Drive `m` for `seconds` from clock t0 at step dt (the clock passed is the step's time, as the gatling test does).
## `aim` is a Vector3 or a Callable(now) -> Vector3; `held` a bool or Callable(now) -> bool.
func _drive(m: WeaponMount, seconds: float, dt: float, held: Variant, aim: Variant, t0: float = 0.0, heat: Heat = null,
		body: Variant = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := int(ceil(seconds / dt - 1e-9))
	for i in n:
		var now := t0 + float(i) * dt
		var h: bool = held.call(now) if held is Callable else bool(held)
		var a: Vector3 = aim.call(now) if aim is Callable else aim
		var b: Basis = body if body != null else Basis.IDENTITY
		if body != null:
			m.set_body_basis(b)
		out.append_array(m.update(dt, h, heat, now, _muzzle(b), a))
	return out


func _yaw_of(rec: Dictionary, body: Basis = Basis.IDENTITY) -> float:
	return Combat.arc_angles(body, rec["dir"]).x


func _cadence() -> void:
	var base := _drive(_mount(), 3.0, 1.0 / 60.0, true, _aim(0.0))
	var first := 0
	for r in base:
		if float(r["t"]) < 1.0 - 1e-4:
			first += 1
	eq(first, 4, "4 rounds in the first second")
	var even_ok := true
	var alt_ok := true
	var piv := PIVOT
	for i in base.size():
		if i > 0:
			even_ok = even_ok and absf(float(base[i]["t"]) - float(base[i - 1]["t"]) - 0.25) < 1e-6
		var side := (base[i]["origin"] as Vector3).x - piv.x
		alt_ok = alt_ok and int(base[i]["shot_index"]) == i and absf(absf(side) - SwivelBoom.BARREL) < 1e-5 \
			and (side < 0.0) == (i % 2 == 0)
	check(even_ok, "rounds leave exactly 0.25 s apart")
	check(alt_ok, "barrels alternate: even rounds from the left (-%.2f m), odd from the right" % SwivelBoom.BARREL)
	for dt: float in STEPS:
		var r := _drive(_mount(), 3.0, dt, true, _aim(0.0))
		var same := r.size() >= base.size() - 1
		for i in mini(r.size(), base.size()):
			if float(base[i]["t"]) > 2.8:
				break
			same = same and absf(float(r[i]["t"]) - float(base[i]["t"])) < 1e-6 \
				and (r[i]["origin"] as Vector3).distance_to(base[i]["origin"]) < 1e-5
		check(same, "same round times and barrels at dt %.4f (%d vs %d)" % [dt, r.size(), base.size()])


func _boom_direction() -> void:
	var m := _mount()
	var recs := _drive(m, 1.0, 1.0 / 60.0, true, _aim(30.0, 10.0))
	var want := Combat.arc_dir(Basis.IDENTITY, Vector2(30.0, 10.0))
	near(m.aim_yaw, 30.0, 1e-4, "the boom settles on the aim yaw (%.3f)" % m.aim_yaw)
	near(m.aim_pitch, 10.0, 1e-4, "... and pitch (%.3f)" % m.aim_pitch)
	check(m.aim_dir.is_equal_approx(want), "aim_dir is the boom's world direction")
	var last: Dictionary = recs[recs.size() - 1]
	check((last["dir"] as Vector3).is_equal_approx(want), "a round leaves along the boom (%s)" % str(last["dir"]))
	var reach := (last["origin"] as Vector3) - PIVOT
	near(reach.dot(want), float(st["muzzle"]), 1e-4, "it leaves %.2f m out along the boom" % float(st["muzzle"]))
	# The first round of a fresh press at 30° leaves before the boom got there: along the boom, not at the aim point.
	var m2 := _mount()
	var r2 := _drive(m2, 0.05, 1.0 / 60.0, true, _aim(30.0))
	if check(r2.size() == 1, "a fresh press fires at once"):
		near(_yaw_of(r2[0]), 4.0, 1e-3, "the first round flies where the boom points after one step (4°), not 30° (%.3f)" % _yaw_of(r2[0]))


func _slew() -> void:
	for dt: float in STEPS:
		var m := _mount()
		var k := int(round(0.6 / dt)) + 1             # the step the aim snaps from 0° to 90°
		var ts := float(k - 1) * dt                   # that step covers (ts, ts + dt]: the slew starts at ts
		var aim := func(now: float) -> Vector3: return _aim(90.0) if now > float(k) * dt - 1e-9 else _aim(0.0)
		var recs: Array[Dictionary] = []
		var reached := -1.0
		var n := int(ceil(2.0 / dt))
		for i in n:
			var now := float(i) * dt
			recs.append_array(m.update(dt, true, null, now, _muzzle(), aim.call(now)))
			if reached < 0.0 and m.aim_yaw >= 90.0 - 1e-6:
				reached = now
		near(reached - ts, 0.375, dt + 1e-6, "a 90° snap takes ~0.375 s to slew (%.3f s, dt %.4f)" % [reached - ts, dt])
		var mid := 0
		var fan_ok := true
		for r in recs:
			var t := float(r["t"])
			var want := clampf(240.0 * (t - ts), 0.0, 90.0) if t > ts else 0.0
			fan_ok = fan_ok and absf(_yaw_of(r) - want) < 0.01
			if _yaw_of(r) > 5.0 and _yaw_of(r) < 85.0:
				mid += 1
		check(fan_ok, "every round leaves along the boom at its time (240°/s from the snap, dt %.4f)" % dt)
		check(mid >= 1, "rounds fired during the slew leave along intermediate directions (%d, dt %.4f)" % [mid, dt])


func _arcs() -> void:
	var m := _mount()
	var r := _drive(m, 1.0, 1.0 / 60.0, true, _aim(100.0))
	check(r.size() >= 3, "100° off the body's forward still fires (%d)" % r.size())
	near(m.aim_yaw, 100.0, 1e-4, "  ... the boom at 100°")
	eq(m.hold_reason, "", "  ... no hold")
	var m2 := _mount()
	var r2 := _drive(m2, 1.0, 1.0 / 60.0, true, _aim(150.0))
	eq(r2.size(), 0, "150° off: holds fire")
	eq(m2.hold_reason, Combat.OUT_OF_ARC, "  ... saying why (%s)" % m2.hold_reason)
	near(m2.aim_yaw, 120.0, 1e-4, "  ... the boom sits at the +120° limit")
	var m3 := _mount()
	_drive(m3, 1.0, 1.0 / 60.0, true, _aim(-150.0))
	near(m3.aim_yaw, -120.0, 1e-4, "-150°: the boom sits at -120°")
	# Back inside: fires again.
	check(_drive(m2, 1.0, 1.0 / 60.0, true, _aim(60.0), 1.0).size() >= 3, "back inside the arc it fires again")
	eq(m2.hold_reason, "", "  ... and the hold clears")
	for c: Array in [[50.0, true, 50.0], [70.0, false, 60.0], [-30.0, true, -30.0], [-50.0, false, -40.0]]:
		var mp := _mount()
		var rp := _drive(mp, 1.0, 1.0 / 60.0, true, _aim(0.0, c[0]))
		eq(rp.size() > 0, c[1], "pitch %+d°: %s" % [int(c[0]), "fires" if c[1] else "holds"])
		near(mp.aim_pitch, c[2], 1e-4, "  ... the boom at %+d° pitch" % int(c[2]))


func _rotated_body() -> void:
	var body := Basis(Vector3.UP, deg_to_rad(90.0)) * Basis.from_scale(Vector3.ONE * 2.0)    # faces world -X, scaled x2
	var m := _mount()
	var r := _drive(m, 1.0, 1.0 / 60.0, true, PIVOT + Vector3(0, 0, -60), 0.0, null, body)   # world -Z = the body's right
	check(r.size() >= 3, "rotated body: a world -Z aim (90° right of the body) fires")
	near(m.aim_yaw, 90.0, 1e-3, "  ... boom at +90° in the body's frame (%.3f)" % m.aim_yaw)
	if r.size() > 0:
		check((r[r.size() - 1]["dir"] as Vector3).is_equal_approx(Vector3(0, 0, -1)), "  ... rounds fly world -Z")
		var o := (r[r.size() - 1]["origin"] as Vector3) - PIVOT
		near(o.length(), Vector2(float(st["muzzle"]), SwivelBoom.BARREL).length() * 2.0, 1e-4, "  ... muzzle and barrels scale with the body")
	var m2 := _mount()
	eq(_drive(m2, 1.0, 1.0 / 60.0, true, PIVOT + Vector3(60, 0, 0), 0.0, null, body).size(), 0,
		"rotated body: world +X (behind it) holds")
	eq(m2.hold_reason, Combat.OUT_OF_ARC, "  ... OUT OF ARC")
	var m3 := _mount()
	check(_drive(m3, 1.0, 1.0 / 60.0, true, PIVOT + Vector3(-60, 0, 0), 0.0, null, body).size() >= 3, "  ... and world -X (its front) fires")


func _default_basis() -> void:
	var m := _mount()
	eq(m.body_basis, Basis.IDENTITY, "no basis supplied: identity")
	_drive(m, 0.02, 1.0 / 60.0, false, _aim(0.0))
	check(m.aim_dir.is_equal_approx(Vector3(0, 0, -1)), "the boom starts on world -Z")
	_drive(m, 1.0, 1.0 / 60.0, false, PIVOT + Vector3(-60, 0, 0))
	near(m.aim_yaw, -90.0, 1e-4, "world -X is 90° left of the default forward")
	_drive(m, 1.0, 1.0 / 60.0, false, PIVOT + Vector3(0, 0, 60))
	eq(m.hold_reason, Combat.OUT_OF_ARC, "world +Z is behind the default body")


func _heat() -> void:
	var m := _mount()
	var h := Heat.new(100000.0, 0.0, 0.0)
	var recs := _drive(m, 2.0, 1.0 / 60.0, true, _aim(0.0), 0.0, h)
	eq(recs.size(), 8, "8 rounds in 2 s")
	near(h.value, 8.0 * float(st["active_heat"]), 1e-6, "1.0 heat per round (%.2f)" % h.value)
	var h2 := Heat.new(100000.0, 0.0, 0.0)
	_drive(_mount(), 1.0, 1.0 / 60.0, true, _aim(150.0), 0.0, h2)
	near(h2.value, 0.0, 1e-9, "holding out of arc costs no heat")


# --- In a world --------------------------------------------------------------------------------------

func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = false
	add_child(w)
	return w


func _dummy(w: CombatWorld, id: String, at: Vector3, mass: String) -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = mass
	d.position = at
	add_child(d)
	w.register(d)
	return d


func _damage_and_knockback() -> void:
	var kb := float(st["knockback"])
	var g := float(MechCatalog.weapon("gatling")["knockback"])
	var ac := float(MechCatalog.weapon("autocannon")["knockback"])
	check(kb > g and kb < ac, "knockback per round %.1f sits between the gatling's %.1f and the autocannon's %.1f" % [kb, g, ac])
	for d: float in [30.0, 100.0, 150.0]:
		var w := _world()
		var t := _dummy(w, "d", Vector3(0, 0, -d), "static")
		var hits: Array = []
		w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: hits.append(h))
		var rec := Combat.fire_record(SHOOTER, 1, "side_r", "swivel", Vector3(0, 1.9, 0), Vector3(0, 1.9, -d), 0.0, 0, 0.0)
		w.fire(rec)
		for i in 200:
			w.advance(1.0 / 60.0)
		if check(hits.size() == 1, "a slug on the axis hits at %d m" % int(d)):
			var hit := hits[0] as Hit
			near(hit.damage, 12.0 * Combat.falloff(st, hit.point.distance_to(Vector3(0, 1.9, 0))), 0.02, "damage at %d m = 12 x falloff (%.2f)" % [int(d), hit.damage])
			near(hit.impulse.length(), kb, 1e-5, "  ... and a %.1f m/s shove along the flight" % kb)
		t.free()
		w.free()
	near(Combat.falloff(st, 80.0), 1.0, 1e-6, "full damage to 80 m")
	near(Combat.falloff(st, 160.0), 0.5, 1e-6, "half at 160 m")
	# A boom firing 90° off the body's forward hits a dummy there.
	var w2 := _world()
	var t2 := _dummy(w2, "side", PIVOT + Vector3(40, -1.9, 0), "heavy")
	var m := _mount()
	m.stats = w2.stats("swivel")
	var n := 0
	for i in 120:
		for r in m.update(1.0 / 60.0, true, null, w2.now, _muzzle(), t2.global_position + Vector3(0, 1.9, 0)):
			w2.fire(r)
			n += 1
		w2.advance(1.0 / 60.0)
	for i in 120:
		w2.advance(1.0 / 60.0)
	check(n >= 6 and t2.total_hp() < t2.total_max_hp(), "firing 90° to the side damages a dummy there (%d rounds, %.0f HP)" % [n, t2.total_hp()])
	t2.free()
	w2.free()
	await frames(1)


## Fixed records into a world at step dt, each fired `late` s after its time: {shot key: [dir, pos at 0.4 s], key/hit: point}.
func _replay(recs: Array[Dictionary], dt: float, late: float) -> Dictionary:
	var w := _world()
	var t := _dummy(w, "wide", PIVOT + Vector3(30, -1.9, -30), "static")
	var out := {}
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: out[h.shot + "/hit"] = h.point)
	var pending := recs.duplicate()
	var guard := 0
	while (not pending.is_empty() or w.live_shots() > 0) and guard < 5000:
		while not pending.is_empty() and w.now >= float(pending[0]["t"]) + late - 1e-9:
			var r: Dictionary = pending.pop_front()
			var p := w.fire(r) as Projectile
			out[Combat.shot_key(r)] = [p.dir, p.flight_pos(0.4)]
		w.advance(dt)
		guard += 1
	t.free()
	w.free()
	return out


func _determinism() -> void:
	# A snap from straight ahead to 45° right mid-stream: the records carry the fan.
	var aim := func(now: float) -> Vector3: return _aim(45.0, 0.0, Basis.IDENTITY, 42.4) if now >= 0.6 else _aim(0.0)
	var recs := _drive(_mount(), 2.5, 1.0 / 60.0, true, aim)
	var base := _replay(recs, 1.0 / 60.0, 0.0)
	var nhit := 0
	for k: String in base:
		if k.ends_with("/hit"):
			nhit += 1
	check(nhit > 2, "the replayed stream hits the wide dummy (%d)" % nhit)
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.35], [1.0 / 60.0, 0.8]]:
		var r := _replay(recs, v[0], v[1])
		var same: bool = r.size() == base.size()
		for k: String in base:
			if not r.has(k):
				same = false
			elif k.ends_with("/hit"):
				same = same and (r[k] as Vector3).distance_to(base[k]) < 0.001
			else:
				same = same and (r[k][0] as Vector3).is_equal_approx(base[k][0]) and (r[k][1] as Vector3).is_equal_approx(base[k][1])
		check(same, "same paths and hits for every round (dt %.4f, %.2f s late)" % [v[0], v[1]])
	await frames(1)


func _fixed_arc() -> void:
	var dt := 1.0 / 60.0
	Combat.FIXED_ARC_ENABLED = false
	var ac := _mount("autocannon")
	check(_drive(ac, 1.0, dt, true, _aim(90.0)).size() > 0, "arc switch OFF (default): the autocannon fires 90° off")
	eq(ac.hold_reason, "", "  ... with no hold")
	Combat.FIXED_ARC_ENABLED = true
	var ac2 := _mount("autocannon")
	eq(_drive(ac2, 1.0, dt, true, _aim(90.0)).size(), 0, "arc switch ON: the autocannon holds 90° off")
	eq(ac2.hold_reason, Combat.OUT_OF_ARC, "  ... with OUT OF ARC")
	check(_drive(ac2, 1.0, dt, true, _aim(20.0), 1.0).size() > 0, "  ... fires at 20°")
	eq(ac2.hold_reason, "", "  ... and the hold clears")
	eq(_drive(_mount("autocannon"), 1.0, dt, true, _aim(0.0, 50.0)).size(), 0, "  ... holds 50° up (limit +%d°)" % int(Combat.FIXED_ARC_PITCH_UP))
	check(_drive(_mount("autocannon"), 1.0, dt, true, _aim(0.0, -40.0)).size() > 0, "  ... fires 40° down (limit -%d°)" % int(Combat.FIXED_ARC_PITCH_DOWN))
	eq(_drive(_mount("autocannon"), 1.0, dt, true, _aim(0.0, -60.0)).size(), 0, "  ... holds 60° down")
	var turned := Basis(Vector3.UP, deg_to_rad(90.0))
	var ac3 := _mount("autocannon")
	ac3.set_body_basis(turned)
	check(ac3.update(dt, true, null, 0.0, PIVOT, PIVOT + Vector3(-60, 0, 0)).size() > 0, "  ... the arc turns with the body (world -X ahead of it)")
	var mo := _mount("mortar")
	check(_drive(mo, 0.5, dt, true, _aim(90.0, 0.0, Basis.IDENTITY, 100.0)).size() > 0, "  ... the mortar ignores it (fires 90° off)")
	check(mo.hold_reason == "", "  ... no hold on the mortar")
	check(_drive(_mount(), 1.0, dt, true, _aim(90.0)).size() > 0, "  ... the swivel still fires 90° off")
	Combat.FIXED_ARC_ENABLED = false
	var ac4 := _mount("autocannon")
	check(_drive(ac4, 1.0, dt, true, _aim(90.0)).size() > 0, "switch back OFF: the autocannon fires 90° off again")


func _rack() -> void:
	var world := CombatWorld.new()
	world.use_physics = false
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "autocannon", "side_r": "swivel", "shoulder_l": "", "shoulder_r": "", "back": ""})
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "racker", 1)
	await frames(2)
	var hp := model.find_child("HP_side_r", true, false) as Node3D
	var fwd := -hp.global_basis.z.normalized()
	var right := hp.global_basis.x.normalized()
	var at := hp.global_position
	# 90° to the right: the swivel fires, the autocannon too while the switch is off.
	rack.aim_point = at + right * 50.0
	rack.set_trigger(true)
	var fired := {}
	rack.fired.connect(func(slot: int) -> void: fired[slot] = int(fired.get(slot, 0)) + 1)
	for i in 60:
		rack.step(DT_RACK)
	check(int(fired.get(2, 0)) >= 3, "rack: the swivel fires 90° right (%d)" % int(fired.get(2, 0)))
	check(int(fired.get(1, 0)) >= 1, "rack: switch off, the autocannon fires 90° off too")
	var boom := hp.get_node_or_null(SwivelBoom.WEAPON_NODE) as Node3D
	if check(boom != null, "the mounted boom model is found"):
		var looks := -boom.global_basis.z.normalized()
		check(looks.dot(right) > 0.99, "the boom model turned to its aim (dot %.3f)" % looks.dot(right))
	# Behind: the swivel holds with the reason in slots().
	rack.aim_point = at - fwd * 50.0
	for i in 30:
		rack.step(DT_RACK)
	var sl := rack.slots()
	eq(str(sl[1]["hold"]), Combat.OUT_OF_ARC, "slots(): the swivel's hold reason behind the mech")
	# Switch on, 90° right: the autocannon holds, the swivel fires.
	Combat.FIXED_ARC_ENABLED = true
	rack.aim_point = at + right * 50.0
	fired.clear()
	for i in 60:
		rack.step(DT_RACK)
	sl = rack.slots()
	eq(str(sl[0]["hold"]), Combat.OUT_OF_ARC, "slots(): arc on, the autocannon holds 90° off")
	eq(int(fired.get(1, 0)), 0, "  ... and doesn't fire")
	eq(str(sl[1]["hold"]), "", "  ... while the swivel doesn't hold")
	check(int(fired.get(2, 0)) >= 3, "  ... and fires")
	# Turn the mech: the arc follows it (aim ahead of the turned body).
	model.rotation.y = deg_to_rad(90.0)
	rack.aim_point = hp.global_position + (-hp.global_basis.z.normalized()) * 50.0
	for i in 10:
		rack.step(DT_RACK)
	eq(str(rack.slots()[0]["hold"]), "", "turned mech: the arc follows the body")
	Combat.FIXED_ARC_ENABLED = false
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


const DT_RACK := 1.0 / 60.0


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	var has_arcs := false
	for o: Dictionary in lab.lab_options():
		has_arcs = has_arcs or str(o["id"]) == "arcs"
	check(has_arcs, "the lab has the Fixed arcs option")
	lab.set_lab_option("weapon", "swivel")
	lab.set_lab_option("mass", "heavy")
	lab.set_lab_option("fire", "hold")
	check(lab.hardpoint.begins_with("side"), "the swivel goes on a side hardpoint (%s)" % lab.hardpoint)
	lab.mech.rotation.y = deg_to_rad(70.0)      # dummies well off the mech's forward axis
	var d := lab.aim_dummy()
	for i in 150:
		await frames(1)
	check(lab.mount.shot_index >= 6, "the lab swivel fired off-axis (%d rounds)" % lab.mount.shot_index)
	check(absf(lab.mount.aim_yaw) > 40.0, "  ... the boom swung well off the forward axis (%.1f°)" % lab.mount.aim_yaw)
	check(d.total_hp() < d.total_max_hp(), "  ... and hit the dummy (%.1f HP)" % d.total_hp())
	lab.set_lab_option("arcs", "on")
	check(Combat.FIXED_ARC_ENABLED, "the lab option turns the switch on")
	lab.set_lab_option("weapon", "autocannon")
	lab.mech.rotation.y = deg_to_rad(70.0)
	for i in 20:
		await frames(1)
	eq(lab.mount.hold_reason, Combat.OUT_OF_ARC, "lab, arcs on: the autocannon holds off-axis")
	lab.set_lab_option("arcs", "off")
	check(not Combat.FIXED_ARC_ENABLED, "  ... and off again")
	lab.queue_free()
	await frames(1)
