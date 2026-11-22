extends TestCase
## The Rocket Pod (scripts/combat/weapons/rockets.gd, scripts/combat/rocket.gd, docs/design/weapons.md §3.5): a press
## ripples 6 rockets over 0.6 s at any frame step, then reloads 4 s; 36 rockets then dry; heat per salvo; direct
## damage + splash with linear falloff; low knockback; a salvo lands as a pattern about 10 m across at 100 m; the
## corkscrew keeps its radius; same records -> same paths and impacts at any frame step and when started late; and the
## weapon_range lab fires it and shows its ammo.

const ID := "rockets"


func setup() -> void:
	_cadence()
	_ammo_and_heat()
	_damage_and_splash()
	_pattern_and_wobble()
	_determinism()
	await _lab()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 4242
	w.use_physics = false
	add_child(w)
	return w


func _dummy(w: CombatWorld, id: String, at: Vector3) -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = "light"
	d.position = at
	add_child(d)
	w.register(d)
	return d


## Hold the trigger for `secs` at step dt; returns the fire records.
func _records(dt: float, secs: float, aim: Vector3 = Vector3(0, 2, -100)) -> Array[Dictionary]:
	var m := WeaponMount.new()
	m.setup(ID, "shoulder_l", "me", 1, MechCatalog.weapon(ID))
	var out: Array[Dictionary] = []
	var t := 0.0
	var n := int(round(secs / dt))
	for i in n:
		out.append_array(m.update(dt, true, null, t, Vector3(0, 2, 0), aim))
		t += dt
	return out


func _cadence() -> void:
	check(WeaponRegistry.built(ID), "the rocket pod is built")
	var base := _records(1.0 / 60.0, 6.0)
	if not check(base.size() == 12, "two salvos in 6 s (%d rockets)" % base.size()):
		return
	near(float(base[5]["t"]) - float(base[0]["t"]), 0.5, 0.0001, "6 rockets ripple out at 10/s")
	check(float(base[5]["t"]) < 0.6, "the whole salvo leaves within 0.6 s")
	near(float(base[6]["t"]) - float(base[5]["t"]), 0.1 + 4.0, 0.0001, "then a 4 s reload")
	for dt: float in [1.0 / 23.0, 1.0 / 144.0, 0.11]:
		var r := _records(dt, 6.0)
		var same := r.size() == base.size()
		for i in mini(r.size(), base.size()):
			same = same and absf(float(r[i]["t"]) - float(base[i]["t"])) < 0.0001
		check(same, "the same shot times at dt %.4f" % dt)


func _ammo_and_heat() -> void:
	var m := WeaponMount.new()
	m.setup(ID, "shoulder_l", "me", 1, MechCatalog.weapon(ID))
	eq(m.ammo, 36, "36 rockets loaded")
	var dry := [0]
	m.dry.connect(func() -> void: dry[0] += 1)
	var h := Heat.new(10000.0, 0.0)
	var fired := 0
	var t := 0.0
	var after_one := -1.0
	for i in 60 * 40:
		fired += m.update(1.0 / 60.0, true, h, t, Vector3.ZERO, Vector3.FORWARD).size()
		t += 1.0 / 60.0
		if after_one < 0.0 and fired == 6:
			after_one = h.value
	near(after_one, 10.0, 0.001, "10 heat per salvo")
	eq(fired, 36, "6 salvos, then empty")
	eq(m.ammo, 0, "ammo at 0")
	check(dry[0] > 0, "an empty pod emits dry")
	near(h.value, 60.0, 0.001, "60 heat for 6 salvos, none for dry clicks")
	eq(m.update(0.5, true, h, t, Vector3.ZERO, Vector3.FORWARD).size(), 0, "no fire when dry")


func _damage_and_splash() -> void:
	var st := MechCatalog.weapon(ID)
	var w := _world()
	var target := _dummy(w, "target", Vector3(0, 0, -60))
	var side := _dummy(w, "side", Vector3(2.6, 0, -60))
	var far := _dummy(w, "far", Vector3(-9.0, 0, -60))
	var hits: Array = []
	var kick := [0.0]
	w.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		hits.append([t, h])
		if t == target:
			kick[0] = t.knock.velocity.length())
	var rec := Combat.fire_record("me", 1, "shoulder_l", ID, Vector3(0, 1.9, 0), Vector3(0, 1.9, -60), 0.0, 2, 0.0)
	w.fire(rec)
	for i in 300:
		w.advance(1.0 / 60.0)
	var direct: Hit = null
	for pair: Array in hits:
		if pair[0] == target:
			direct = pair[1]
	if check(direct != null, "the rocket hits the dummy it was aimed at"):
		near(target.total_max_hp() - target.total_hp(), float(st["damage"]), 0.001, "16 direct damage, no self splash, no falloff")
		var d := INF
		for s: Dictionary in side.world_spheres():
			d = minf(d, maxf(direct.point.distance_to(s["center"]) - float(s["radius"]), 0.0))
		var expect := float(st["splash_damage"]) * (1.0 - d / float(st["splash_radius"]))
		var got := side.total_max_hp() - side.total_hp()
		check(got > 0.0 and got < float(st["splash_damage"]), "a neighbour takes part of the splash (%.2f)" % got)
		near(got, expect, 0.01, "splash falls off linearly (%.2f m from the burst)" % d)
		near(far.total_max_hp() - far.total_hp(), 0.0, 0.0001, "nothing outside 4 m")
		check(kick[0] > 0.0 and kick[0] <= float(st["knockback"]) + 0.001, "low knockback: %.2f m/s on a light dummy" % kick[0])
		check(float(st["knockback"]) < float(MechCatalog.weapon("autocannon")["knockback"]) * 0.5, "rockets shove far less than the autocannon")
	target.free()
	side.free()
	far.free()
	w.free()


func _pattern_and_wobble() -> void:
	var w := _world()
	var aim := Vector3(0, 2, -100)
	var axis := (aim - Vector3(0, 2, 0)).normalized()
	var pts: Array[Vector3] = []
	var wob := float(MechCatalog.weapon(ID)["wobble"])
	var launches: Array[Vector3] = []
	for rec in _records(1.0 / 60.0, 0.7, aim):
		var r := w.fire(rec) as Rocket
		if not check(r != null, "a rocket record spawns a Rocket"):
			continue
		launches.append(r.flight_pos(0.0))
		# Where it crosses the 100 m plane.
		var e := 0.0
		while (r.flight_pos(e) - Vector3(0, 2, 0)).dot(axis) < 100.0 and e < 10.0:
			e += 0.002
		var p := r.flight_pos(e)
		pts.append(p - axis * (p - Vector3(0, 2, 0)).dot(axis))
		# The corkscrew: once open, the rocket stays `wobble` off its straight line, and the offset turns.
		var ok := true
		for k in 8:
			var t := 0.4 + float(k) * 0.3
			var straight := r.launch + r.dir * r.speed * t
			ok = ok and absf(r.flight_pos(t).distance_to(straight) - wob) < 0.001
		check(ok, "rocket %d corkscrews at %.1f m around its line" % [int(rec["shot_index"]), wob])
		check(r.wobble_offset(0.5).distance_to(r.wobble_offset(0.8)) > 0.1, "the wobble turns")
		near(r.flight_pos(0.0).distance_to(r.launch), 0.0, 0.0001, "it leaves its tube on the line")
	eq(pts.size(), 6, "one salvo")
	var span := 0.0
	for a in pts:
		for b in pts:
			span = maxf(span, a.distance_to(b))
	print("rocket salvo pattern at 100 m: %.2f m across" % span)
	check(span > 6.0 and span < 16.0, "the salvo lands as a pattern about 10 m across at 100 m (%.2f m)" % span)
	var tubes := 0.0
	for a in launches:
		for b in launches:
			tubes = maxf(tubes, a.distance_to(b))
	check(tubes > 0.5 and tubes < 2.0, "rockets leave from six tubes, not one point (%.2f m apart)" % tubes)
	for e in w.effects.duplicate():
		w.remove_effect(e)
	w.free()


## Fly one salvo with frame step dt, the world starting `late` s after the first rocket left. Per rocket: a mid-flight
## sample, the flight time it ended and where.
func _fly(recs: Array[Dictionary], dt: float, late: float) -> Array:
	var w := _world()
	var d := _dummy(w, "d", Vector3(0.5, 0, -70))
	d.mass_class = "static"      # knockback integrates with the frame step: keep the target still to compare flights
	w.now = late
	var rockets: Array = []
	var out: Array = []
	var i := 0
	var guard := 0
	while (i < recs.size() or w.live_shots() > 0) and guard < 5000:
		while i < recs.size() and float(recs[i]["t"]) <= w.now:
			rockets.append(w.fire(recs[i]))
			i += 1
		w.advance(dt)
		guard += 1
		if i >= recs.size() and w.live_shots() == 0:
			break
	for r: Rocket in rockets:
		out.append({"mid": r.flight_pos(1.0), "end": r.end_time, "at": r.flight_pos(r.end_time)})
	out.append({"damage": d.total_max_hp() - d.total_hp()})
	d.free()
	w.free()
	return out


func _determinism() -> void:
	var recs := _records(1.0 / 60.0, 0.7, Vector3(0.5, 1.9, -70))
	var base := _fly(recs, 1.0 / 60.0, 0.0)
	var hit_some := false
	for k in base.size() - 1:
		hit_some = hit_some or float(base[k]["end"]) < 70.0 / 45.0 + 0.2
	check(hit_some, "some rockets hit the dummy at 70 m")
	check(float(base[-1]["damage"]) > 0.0, "the dummy takes damage (%.1f)" % float(base[-1]["damage"]))
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.35], [1.0 / 60.0, 0.9]]:
		var r := _fly(recs, v[0], v[1])
		var tag := "dt %.4f, started %.2f s late" % [v[0], v[1]]
		if not eq(r.size(), base.size(), "every rocket flies (%s)" % tag):
			continue
		var same_path := true
		var same_end := true
		for k in base.size() - 1:
			same_path = same_path and (r[k]["mid"] as Vector3).is_equal_approx(base[k]["mid"])
			same_end = same_end and absf(float(r[k]["end"]) - float(base[k]["end"])) < 0.0001 \
				and (r[k]["at"] as Vector3).distance_to(base[k]["at"]) < 0.001
		check(same_path, "same paths (%s)" % tag)
		if not check(same_end, "same impact times and points (%s)" % tag):
			for k in base.size() - 1:
				print("  %d: %.5f %s vs %.5f %s" % [k, float(base[k]["end"]), base[k]["at"], float(r[k]["end"]), r[k]["at"]])
		near(float(r[-1]["damage"]), float(base[-1]["damage"]), 0.001, "same damage (%s)" % tag)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.time_scale = 0.0          # drive the lab clock by hand
	lab.set_lab_option("weapon", ID)
	check(lab.hardpoint.begins_with("shoulder"), "the pod goes on a shoulder (%s)" % lab.hardpoint)
	var best: TargetDummy = null
	for d in lab.dummies:        # the dummy nearest 25 m, wherever the layout puts it
		if best == null or absf(d.global_position.length() - 25.0) < absf(best.global_position.length() - 25.0):
			best = d
	lab.set_lab_option("aim", str(best.name))
	lab.set_lab_option("fire", "hold")
	var most := 0
	for i in 90:
		lab.step(1.0 / 60.0)
		var n := 0
		for e in lab.world.effects:
			if e is Rocket and (e as Rocket).end_time < 0.0:
				n += 1
		most = maxi(most, n)
	eq(lab.mount.shot_index, 6, "the lab fired one salvo")
	check(most >= 3, "rockets in flight together (%d)" % most)
	check(best.total_hp() < best.total_max_hp(), "the aimed dummy got hit (%.0f HP)" % best.total_hp())
	check(lab._heat_label.text.contains("AMMO 30 / 36"), "the shooter shows its ammo: " + lab._heat_label.text.replace("\n", " | "))
	for i in 40 * 10:
		lab.step(0.1)
	eq(lab.mount.ammo, 0, "the lab pod runs dry")
	check(lab._heat_label.text.contains("DRY"), "the label says DRY")
	lab.set_lab_option("fire", "hold")
	eq(lab.mount.ammo, 36, "an option change (the reset path) refills it")
	lab.queue_free()
	await frames(1)
