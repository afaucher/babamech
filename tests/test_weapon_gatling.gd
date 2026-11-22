extends TestCase
## The Rotary Gatling (scripts/combat/weapons/gatling.gd, docs/design/weapons.md §3.3): spin-up before the first round,
## spin hold on a re-press, 12 rounds/s at any frame step, bloom per round up to its cap and back down, tap-fire stays
## tight, a held stream hits a mech-sized target far more often at 25 m than at 100 m, damage falloff, the constant
## shove, ~5.4 heat/s, determinism (same records -> same paths and hits at any frame step and when started late), and the
## weapon_range lab fires it.

const SHOOTER := "me"
const STEPS := [1.0 / 60.0, 1.0 / 30.0, 1.0 / 144.0, 0.11]

var st: Dictionary


func setup() -> void:
	st = MechCatalog.weapon("gatling")
	check(WeaponRegistry.built("gatling"), "the gatling is built")
	_spin_up()
	_spin_hold()
	_cadence()
	_bloom()
	_tap_fire()
	_heat()
	await _falloff()
	await _knockback()
	await _hit_fraction()
	await _determinism()
	await _lab()
	finish()


func _mount() -> WeaponMount:
	var m := WeaponMount.new()
	m.setup("gatling", "side_r", SHOOTER, 1, st)
	return m


## Drive a mount for `seconds` from clock time `t0` at step `dt`; `held` is a Callable(t) -> bool or a bool. Returns the
## fire records (the clock passed to update is the step's start, as the lab does).
func _drive(m: WeaponMount, seconds: float, dt: float, held: Variant, t0: float = 0.0, heat: Heat = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := int(ceil(seconds / dt - 1e-9))
	for i in n:
		var now := t0 + float(i) * dt
		var h: bool = held.call(now) if held is Callable else bool(held)
		out.append_array(m.update(dt, h, heat, now, Vector3.ZERO, Vector3(0, 0, -50)))
	return out


func _spin_up() -> void:
	for dt: float in STEPS:
		var recs := _drive(_mount(), 1.0, dt, true)
		if check(recs.size() > 0, "held 1 s: it fires (dt %.4f)" % dt):
			near(float(recs[0]["t"]), float(st["spin_up"]), 1e-6, "the first round leaves after the 0.6 s spin-up (dt %.4f)" % dt)
	var m := _mount()
	eq(_drive(m, 0.55, 1.0 / 60.0, true).size(), 0, "no round during the spin-up")
	check(m.spin > 0.8 and m.spin < 1.0, "the barrels are spinning up (%.2f)" % m.spin)


func _spin_hold() -> void:
	# Release for 0.5 s (inside the 1 s hold): a re-press fires at once.
	var m := _mount()
	_drive(m, 1.0, 1.0 / 60.0, true)
	_drive(m, 0.5, 1.0 / 60.0, false, 1.0)
	var again := _drive(m, 0.3, 1.0 / 60.0, true, 1.5)
	if check(again.size() > 0, "re-press inside the hold fires"):
		check(float(again[0]["t"]) - 1.5 < 0.001, "  ... at once (%.3f s)" % (float(again[0]["t"]) - 1.5))
	# Release for 1.3 s: the hold ran out 0.3 s ago, the barrels lost half their speed: 0.3 s to spin back.
	var m2 := _mount()
	_drive(m2, 1.0, 1.0 / 120.0, true)
	_drive(m2, 1.3, 1.0 / 120.0, false, 1.0)
	near(m2.spin, 0.5, 0.01, "past the hold the spin decays (%.3f)" % m2.spin)
	var r2 := _drive(m2, 1.0, 1.0 / 120.0, true, 2.3)
	if check(r2.size() > 0, "re-press after a partial spin-down fires"):
		near(float(r2[0]["t"]) - 2.3, 0.3, 0.01, "  ... after spinning back up the lost half")
	# Release for 2.5 s: fully stopped, the full 0.6 s again.
	var m3 := _mount()
	_drive(m3, 1.0, 1.0 / 60.0, true)
	_drive(m3, 2.5, 1.0 / 60.0, false, 1.0)
	near(m3.spin, 0.0, 0.0001, "after hold + spin-down the barrels stop")
	var r3 := _drive(m3, 1.0, 1.0 / 60.0, true, 3.5)
	if check(r3.size() > 0, "a cold re-press fires"):
		near(float(r3[0]["t"]) - 3.5, 0.6, 0.0001, "  ... after the full spin-up")


func _cadence() -> void:
	var base := _drive(_mount(), 5.0, 1.0 / 60.0, true)
	var n := 0
	for r in base:
		if float(r["t"]) < 1.6 - 1e-4:
			n += 1
	eq(n, 12, "12 rounds in the first second of fire")
	var ok := true
	for i in range(1, base.size()):
		ok = ok and absf(float(base[i]["t"]) - float(base[i - 1]["t"]) - 1.0 / 12.0) < 1e-6
	check(ok, "rounds leave exactly 1/12 s apart")
	for dt: float in STEPS:
		var r := _drive(_mount(), 5.0, dt, true)
		var same := r.size() >= base.size() - 2
		for i in mini(r.size(), base.size()):
			if float(base[i]["t"]) > 4.8:
				break
			same = same and absf(float(r[i]["t"]) - float(base[i]["t"])) < 1e-6 and int(r[i]["shot_index"]) == i \
				and absf(float(r[i]["spread"]) - float(base[i]["spread"])) < 1e-6
		check(same, "same shot times and spreads at dt %.4f (%d vs %d rounds)" % [dt, r.size(), base.size()])


func _bloom() -> void:
	var m := _mount()
	var recs := _drive(m, 2.5, 1.0 / 60.0, true)
	var lo := float(st["spread"])
	var hi := float(st["spread_max"])
	near(float(recs[0]["spread"]), lo, 1e-6, "the first round flies at the 1.2° base cone")
	near(float(recs[1]["spread"]), lo + float(st["bloom"]), 1e-6, "+0.25° per round")
	near(float(recs[5]["spread"]), lo + 5.0 * float(st["bloom"]), 1e-6, "+0.25° per round (6th)")
	var cap := true
	for r in recs:
		cap = cap and float(r["spread"]) <= hi + 1e-6
	check(cap, "the cone never passes 4.0°")
	near(float(recs[recs.size() - 1]["spread"]), hi, 1e-6, "a held stream sits at 4.0°")
	near(float(recs[12]["spread"]), hi, 1e-6, "capped from the 13th round")
	# Recovery: 3°/s once the trigger is released.
	_drive(m, 0.5, 1.0 / 60.0, false, 2.5)
	near(m.bloom, (hi - lo) - 0.5 * float(st["bloom_recover"]), 0.001, "bloom recovers 3°/s (%.3f)" % m.bloom)
	_drive(m, 0.5, 1.0 / 60.0, false, 3.0)
	near(m.bloom, 0.0, 0.0001, "and is gone after ~0.93 s")


func _tap_fire() -> void:
	# Spin up, then single-round taps every 0.35 s, then 3-round bursts every 0.6 s: both stay near the base cone.
	var dt := 1.0 / 60.0
	var m := _mount()
	_drive(m, 0.62, dt, true)
	var taps := _drive(m, 3.0, dt, func(t: float) -> bool: return fmod(t - 0.62 + 1e-6, 0.35) < dt * 0.5, 0.62)
	var worst := 0.0
	for r in taps:
		worst = maxf(worst, float(r["spread"]))
	check(taps.size() >= 7, "single taps fire one round each (%d)" % taps.size())
	near(worst, float(st["spread"]), 0.001, "single taps stay at 1.2° (worst %.2f°)" % worst)
	var bursts := _drive(m, 3.0, dt, func(t: float) -> bool: return fmod(t - 3.62 + 1e-6, 0.6) < 0.25 - 1e-4, 3.62)
	var worst2 := 0.0
	for r in bursts:
		worst2 = maxf(worst2, float(r["spread"]))
	check(bursts.size() >= 12, "short bursts fire (%d rounds)" % bursts.size())
	check(worst2 <= float(st["spread"]) + 3.0 * float(st["bloom"]) + 1e-6, "short bursts stay under 2° (worst %.2f°)" % worst2)


func _heat() -> void:
	var m := _mount()
	var h := Heat.new(100000.0, 0.0, 0.0)
	_drive(m, 2.0, 1.0 / 60.0, true, 0.0, h)
	var h2 := h.value
	_drive(m, 10.0, 1.0 / 60.0, true, 2.0, h)
	near((h.value - h2) / 10.0, 5.4, 0.06, "a held gatling makes 5.4 heat/s (%.2f)" % ((h.value - h2) / 10.0))


# --- In a world --------------------------------------------------------------------------------------

func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 4242
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


## A mech-sized target (the strider at game scale: legs, pelvis, torso, head), static so it holds still.
func _mech_target(w: CombatWorld, at: Vector3) -> CombatTarget:
	var t := CombatTarget.new()
	t.target_id = "mech"
	t.mass_class = "static"
	t.set_max_hp({"body": 100000.0})
	t.add_hit_sphere("body", Vector3(-0.9, 1.8, 0), 0.8)
	t.add_hit_sphere("body", Vector3(0.9, 1.8, 0), 0.8)
	t.add_hit_sphere("body", Vector3(0, 3.4, 0), 1.0)
	t.add_hit_sphere("body", Vector3(0, 4.6, 0), 1.5)
	t.add_hit_sphere("body", Vector3(0, 6.1, 0), 0.6)
	t.position = at
	add_child(t)
	w.register(t)
	return t


## Hold the trigger for `seconds` into world `w` from `from` at `to`, then let the rounds land. Returns the records.
func _stream(w: CombatWorld, seconds: float, from: Vector3, to: Vector3, dt: float = 1.0 / 60.0) -> Array[Dictionary]:
	var m := _mount()
	m.stats = w.stats("gatling")
	var recs: Array[Dictionary] = []
	var n := int(ceil(seconds / dt))
	for i in n:
		for r in m.update(dt, true, null, w.now, from, to):
			recs.append(r)
			w.fire(r)
		w.advance(dt)
	var guard := 0
	while w.live_shots() > 0 and guard < 1000:
		w.advance(dt)
		guard += 1
	return recs


func _falloff() -> void:
	for d: float in [30.0, 100.0, 160.0, 195.0]:
		var w := _world()
		var t := _dummy(w, "d", Vector3(0, 0, -d), "static")
		var hits: Array = []
		w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: hits.append(h))
		w.fire(Combat.fire_record(SHOOTER, 1, "side_r", "gatling", Vector3(0, 1.9, 0), Vector3(0, 1.9, -d), 0.0, 0, 0.0))
		for i in 200:
			w.advance(1.0 / 60.0)
		if check(hits.size() == 1, "a round on the axis hits at %d m" % int(d)):
			var dist := (hits[0] as Hit).point.length()
			near((hits[0] as Hit).damage, 6.0 * Combat.falloff(st, dist), 0.001,
				"damage at %d m = 6 x falloff = %.2f" % [int(d), (hits[0] as Hit).damage])
		t.free()
		w.free()
	near(Combat.falloff(st, 60.0), 1.0, 1e-6, "full damage to 60 m")
	near(Combat.falloff(st, 200.0), 0.5, 1e-6, "half damage at 200 m")
	await frames(1)


func _knockback() -> void:
	var w := _world()
	var d := _dummy(w, "kb", Vector3(0, 0, -25), "heavy")    # heavy: a light one is shoved out of the fixed aim line
	var home := d.global_position
	var dv := [0.0, 0]
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void:
		dv[0] += h.impulse.length()
		dv[1] += 1)
	_stream(w, 3.0, Vector3(0, 1.9, 0), Vector3(0, 1.9, -25))
	check(int(dv[1]) > 15, "the stream lands on the 25 m dummy (%d rounds)" % int(dv[1]))
	var kb := float(MechCatalog.weapon("gatling")["knockback"])
	near(float(dv[0]), kb * float(dv[1]), 0.001, "every round shoves %.1f m/s (total %.1f)" % [kb, float(dv[0])])
	check(d.global_position.z < home.z - 0.05, "the constant shove pushes it back (%.2f m)" % (home.z - d.global_position.z))
	var h := Hit.new()
	h.impulse = Vector3(0, 0, -float(st["knockback"]))
	var t := CombatTarget.new()
	t.mass_class = "mech"
	t.apply_hit(h)
	near(t.knock.velocity.length(), float(st["knockback"]) * 0.5, 1e-6, "a mech takes half a round's shove")
	t.free()
	d.free()
	w.free()
	await frames(1)


func _hit_fraction() -> void:
	var frac := {}
	for dist: float in [25.0, 100.0]:
		var w := _world()
		var t := _mech_target(w, Vector3(0, 0, -dist))
		var keys := {}
		w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: keys[h.shot] = true)
		var recs := _stream(w, 3.0, Vector3(0, 4.4, 0), Vector3(0, 4.4, -dist))
		frac[dist] = float(keys.size()) / maxf(float(recs.size()), 1.0)
		print("gatling: %d m, %d rounds, %d hits (%.0f%%)" % [int(dist), recs.size(), keys.size(), 100.0 * float(frac[dist])])
		t.free()
		w.free()
	check(float(frac[25.0]) > 0.75, "a 3 s stream mostly hits a mech at 25 m (%.0f%%)" % (100.0 * float(frac[25.0])))
	check(float(frac[100.0]) < 0.35, "at 100 m most of it misses (%.0f%%)" % (100.0 * float(frac[100.0])))
	check(float(frac[25.0]) > 3.0 * float(frac[100.0]), "near hits far more often than far")
	await frames(1)


## One run of fixed records into a world at step dt, each record fired `late` s after its time: {shot key: [dir, hit point]}.
func _replay(recs: Array[Dictionary], dt: float, late: float) -> Dictionary:
	var w := _world()
	var t := _mech_target(w, Vector3(0.5, -4.4, -60))   # torso on the drive's aim line (y 0)
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
	var recs := _drive(_mount(), 2.0, 1.0 / 60.0, true)
	var base := _replay(recs, 1.0 / 60.0, 0.0)
	var nhit := 0
	for k: String in base:
		if k.ends_with("/hit"):
			nhit += 1
	check(nhit > 3, "the replayed stream hits the 60 m target (%d)" % nhit)
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.35], [1.0 / 60.0, 0.8]]:
		var r := _replay(recs, v[0], v[1])
		var tag := "dt %.4f, %.2f s late" % [v[0], v[1]]
		var same: bool = r.size() == base.size()
		for k: String in base:
			if not r.has(k):
				same = false
			elif k.ends_with("/hit"):
				same = same and (r[k] as Vector3).distance_to(base[k]) < 0.001
			else:
				same = same and (r[k][0] as Vector3).is_equal_approx(base[k][0]) and (r[k][1] as Vector3).is_equal_approx(base[k][1])
		check(same, "same paths and hits for every round (%s)" % tag)
	await frames(1)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.set_lab_option("weapon", "gatling")
	lab.set_lab_option("mass", "heavy")
	lab.set_lab_option("fire", "hold")
	var nearest: TargetDummy = null
	for d in lab.dummies:
		if nearest == null or d.global_position.length() < nearest.global_position.length():
			nearest = d
	lab.set_lab_option("aim", str(nearest.name))
	var d := lab.aim_dummy()
	eq(d, nearest, "aiming at the nearest dummy (%s)" % nearest.name)
	check(lab.mount.built(), "the gatling is built in the lab")
	var shots := 0
	for i in 120:
		await frames(1)
		shots = maxi(shots, lab.world.live_shots())
	check(lab.mount.shot_index >= 8, "the lab gatling fired (%d rounds)" % lab.mount.shot_index)
	check(shots >= 3, "a stream of darts in flight (%d at once)" % shots)
	check(d.total_hp() < d.total_max_hp(), "the nearest dummy lost HP (%.1f)" % d.total_hp())
	check(lab.mount.spin >= 1.0, "the barrels are at speed")
	lab.queue_free()
	await frames(1)
