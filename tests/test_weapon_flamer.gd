extends TestCase
## The Flamer (scripts/combat/weapons/flamer.gd, FlameChunk in scripts/combat/flame_stream.gd, FlamerFx, BurnFx;
## docs/design/weapons.md §3.9): 10 chunks/s at any frame step, 0.6 heat per chunk to the shooter (6/s), reach 45 m (a
## dummy at 20 and 43 m is hit, at 48 m not), the focused 5° cone (1.5 m off-axis at 30 m is hit, 6 m is not), +2.2 heat and 1.5
## damage per chunk and no shove, a mech-class dummy under the full stream shuts down in 4..9 s and reboots once the flame
## stops, walls block it, determinism (same records -> same hits at any frame step and when started late), one
## LowPolyFlame.Stream per firing mount (emitting while firing, gone after), stuck burning tongues above 50% heat only,
## and the weapon_range lab fires it.

const SHOOTER := "me"
const STEPS := [1.0 / 60.0, 1.0 / 30.0, 1.0 / 144.0, 0.11]
const MUZZLE := Vector3(0, 1.9, 0)

var st: Dictionary


func setup() -> void:
	st = MechCatalog.weapon("flamer")
	check(WeaponRegistry.built("flamer"), "the flamer is built")
	_cadence()
	_shooter_heat()
	await _reach()
	await _cone()
	await _per_chunk()
	await _shutdown()
	await _wall()
	await _wall_cap()
	await _determinism()
	await _visual_stream()
	await _lab()
	finish()


func _mount(hp: String = "side_l") -> WeaponMount:
	var m := WeaponMount.new()
	m.setup("flamer", hp, SHOOTER, 1, st)
	return m


func _drive(m: WeaponMount, seconds: float, dt: float, held: bool, t0: float = 0.0, heat: Heat = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := int(ceil(seconds / dt - 1e-9))
	for i in n:
		out.append_array(m.update(dt, held, heat, t0 + float(i) * dt, MUZZLE, Vector3(0, 1.9, -12)))
	return out


func _cadence() -> void:
	for dt: float in STEPS:
		var recs := _drive(_mount(), 3.0, dt, true)
		var first := 0
		for r in recs:
			if float(r["t"]) < 1.0 - 1e-6:
				first += 1
		eq(first, 10, "10 chunks in the first second (dt %.4f)" % dt)
		var ok := recs.size() >= 29
		for i in range(1, recs.size()):
			ok = ok and absf(float(recs[i]["t"]) - float(recs[i - 1]["t"]) - 0.1) < 1e-6
		check(ok, "chunks leave exactly 0.1 s apart (dt %.4f, %d chunks)" % [dt, recs.size()])
		near(float(recs[0]["spread"]), 5.0, 1e-6, "each chunk carries the 5° cone")


func _shooter_heat() -> void:
	var h := Heat.new(100000.0, 0.0, 0.0)
	_drive(_mount(), 10.0, 1.0 / 60.0, true, 0.0, h)
	near(h.value / 10.0, 6.0, 0.07, "a held flamer makes 6 heat/s on the shooter (%.2f)" % (h.value / 10.0))
	# The real gauge (strider: cap 100, cooling 6, +1.0 passive from the flamer): how long a cold mech can hold it.
	var c := MechCatalog.chassis("strider")
	var g := Heat.new(float(c["heat_cap"]), float(c["cooling"]), float(st["passive_heat"]))
	var m := _mount()
	var dt := 1.0 / 30.0
	var t := 0.0
	while t < 300.0 and not g.shutdown:
		g.tick(dt)
		m.update(dt, true, g, t, MUZZLE, Vector3(0, 1.9, -12))
		t += dt
	print("flamer: a cold strider holding only the flamer shuts down after %.1f s (net %+.1f heat/s)" %
		[t, 6.0 + float(st["passive_heat"]) - float(c["cooling"])])
	check(g.shutdown, "holding the flamer alone eventually overheats the shooter (%.1f s)" % t)


# --- In a world --------------------------------------------------------------------------------------

func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 777
	w.use_physics = physics
	add_child(w)
	return w


func _dummy(w: CombatWorld, id: String, at: Vector3, mass: String = "mech") -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = mass
	d.position = at
	add_child(d)
	w.register(d)
	return d


## Fire `n` chunks 0.1 s apart from MUZZLE at `to` with `spread`, let them all land; returns the hits.
func _chunks(w: CombatWorld, to: Vector3, n: int, spread: float) -> Array:
	var hits: Array = []
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: hits.append(h))
	var recs: Array[Dictionary] = []
	for i in n:
		recs.append(Combat.fire_record(SHOOTER, 1, "side_l", "flamer", MUZZLE, to, 0.1 * float(i), i, spread))
	var guard := 0
	while guard < 2000 and (not recs.is_empty() or _flying(w) > 0):
		while not recs.is_empty() and w.now >= float(recs[0]["t"]) - 1e-9:
			w.fire(recs.pop_front())
		w.advance(1.0 / 60.0)
		guard += 1
	return hits


func _flying(w: CombatWorld) -> int:
	var n := 0
	for e in w.effects:
		if e is FlameChunk:
			n += 1
	return n


func _reach() -> void:
	for v: Array in [[20.0, true], [43.0, true], [48.0, false]]:
		var w := _world()
		var d := _dummy(w, "d", Vector3(0, 0, -float(v[0])), "static")
		var hits := _chunks(w, Vector3(0, 1.9, -float(v[0])), 3, 0.0)
		if bool(v[1]):
			eq(hits.size(), 3, "a dummy at %d m is hit (%d of 3)" % [int(v[0]), hits.size()])
		else:
			eq(hits.size(), 0, "a dummy at %d m is out of reach (%d hits)" % [int(v[0]), hits.size()])
		d.free()
		w.free()
	await frames(1)


func _cone() -> void:
	for v: Array in [[1.5, true], [6.0, false]]:
		var w := _world()
		var d := _dummy(w, "d", Vector3(float(v[0]), 0, -30), "static")
		var hits := _chunks(w, Vector3(0, 1.9, -30), 60, float(st["spread"]))   # aimed straight down the lane
		if bool(v[1]):
			check(hits.size() >= 30, "a dummy 1.5 m off the axis at 30 m takes most of the jet (%d of 60)" % hits.size())
		else:
			eq(hits.size(), 0, "a dummy 6 m off the axis at 30 m is outside the cone (%d of 60)" % hits.size())
		d.free()
		w.free()
	await frames(1)


func _per_chunk() -> void:
	var w := _world()
	var d := _dummy(w, "d", Vector3(0, 0, -10), "light")    # light: the easiest to shove, and it must not move
	var hits := _chunks(w, Vector3(0, 1.9, -10), 1, 0.0)
	if check(hits.size() == 1, "one chunk, one hit"):
		var h: Hit = hits[0]
		near(h.heat, 2.2, 1e-6, "+2.2 heat per chunk")
		near(h.damage, 1.5, 1e-6, "1.5 damage per chunk")
		eq(h.impulse, Vector3.ZERO, "no knockback")
		eq(h.weapon, "flamer", "the hit names the flamer")
	near(d.total_hp(), 1000.0 - 1.5, 1e-4, "the dummy lost 1.5 HP")
	check(d.heat.value > 0.0 and d.heat.value <= 2.2, "the dummy took the heat (%.2f after cooling)" % d.heat.value)
	eq(d.knock.velocity, Vector3.ZERO, "and isn't moving")
	near(d.global_position.z, -10.0, 1e-6, "and stays put")
	d.free()
	w.free()
	await frames(1)


## A mech-class dummy at 15 m under the full stream: overheats in 4..9 s, burning tongues above half heat, reboots after.
func _shutdown() -> void:
	var w := _world()
	var d := _dummy(w, "hot", Vector3(0, 0, -15), "mech")
	var m := _mount()
	m.stats = w.stats("flamer")
	var dt := 1.0 / 60.0
	var t_over := -1.0
	var t_half := -1.0
	var burn_ok := true
	var shown := 0
	while w.now < 15.0 and t_over < 0.0:
		for r in m.update(dt, true, null, w.now, MUZZLE, Vector3(0, 1.9, -15)):
			w.fire(r)
		w.advance(dt)
		var b := d.get_node_or_null("BurnFx") as BurnFx
		var n := b.showing() if b != null else 0
		if d.heat.fraction() > BurnFx.ON_AT + 0.03:
			if t_half < 0.0:
				t_half = w.now
			shown = maxi(shown, n)
		elif d.heat.fraction() < BurnFx.ON_AT - 0.03:
			burn_ok = burn_ok and n == 0
		if d.heat.shutdown:
			t_over = w.now
	print("flamer: mech dummy over half heat at %.2f s, shut down at %.2f s" % [t_half, t_over])
	check(t_over >= 4.0 and t_over <= 9.0, "a mech-class dummy under the full stream shuts down in 4..9 s (%.2f s)" % t_over)
	check(burn_ok, "no stuck flames below half heat")
	check(shown >= 2 and shown <= 4, "2-4 burning tongues on it above half heat (%d)" % shown)
	near(d.global_position.z, -15.0, 1e-6, "the stream never shoved it")
	# Let go: the flame stops, the dummy cools, the stuck flames go, then it reboots.
	var t_stop := w.now
	var t_cool := -1.0
	var t_reboot := -1.0
	while w.now < t_stop + 20.0 and t_reboot < 0.0:
		for r in m.update(dt, false, null, w.now, MUZZLE, Vector3(0, 1.9, -15)):
			w.fire(r)
		w.advance(dt)
		var b := d.get_node("BurnFx") as BurnFx
		if t_cool < 0.0 and d.heat.fraction() < BurnFx.ON_AT - 0.01:
			t_cool = w.now
			eq(b.showing(), 0, "below half heat the stuck flames are gone")
		if not d.heat.shutdown:
			t_reboot = w.now
	check(t_reboot > 0.0, "it reboots after the flame stops (%.1f s later)" % (t_reboot - t_stop))
	d.free()
	w.free()
	await frames(1)


func _wall() -> void:
	var w := _world(true)
	var d := _dummy(w, "behind", Vector3(0, 0, -10), "static")
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(12, 8, 0.5)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0, 2, -6)
	add_child(body)
	await frames(3)
	var hits := _chunks(w, Vector3(0, 1.9, -10), 20, float(st["spread"]))
	eq(hits.size(), 0, "a wall between stops every chunk (%d hits)" % hits.size())
	body.position = Vector3(0, 2, -30)
	await frames(3)
	var w2_hits := _chunks(w, Vector3(0, 1.9, -10), 20, float(st["spread"]))
	check(w2_hits.size() >= 10, "with the wall moved away the stream lands (%d of 20)" % w2_hits.size())
	body.free()
	d.free()
	w.free()
	await frames(1)


## The look stops at walls too: with a wall 8 m ahead the Stream's max_length is ~8 m and no tongue shows beyond it.
func _wall_cap() -> void:
	var w := _world(true)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(14, 8, 0.5)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0, 2, -8.25)     # front face at 8 m
	add_child(body)
	await frames(3)
	var m := _mount()
	var dt := 1.0 / 60.0
	var past := 0.0
	var fx: FlamerFx = null
	for i in 90:
		for r in m.update(dt, true, null, w.now, MUZZLE, Vector3(0, 1.9, -12)):
			w.fire(r)
		w.advance(dt)
		var f := _fxs(w)
		fx = f[0] if not f.is_empty() else null
		if fx == null or i < 60:
			continue
		for n in fx.stream.get_children():
			var mi := n as MeshInstance3D
			if mi != null and mi.visible and mi.mesh != LowPolyFlame.jet():
				var tip := mi.global_transform * Vector3(0, -1.0, 0)
				past = maxf(past, -tip.z - 8.0)
	if check(fx != null, "the Stream is live in front of the wall"):
		near(fx.stream.max_length, 8.0, 0.05, "the Stream is capped at the wall (%.2f m)" % fx.stream.max_length)
	check(past < 0.25, "no tongue shows beyond the wall (worst %.2f m past it)" % past)
	body.position = Vector3(0, 2, -60)     # out past the 45 m reach
	await frames(3)
	for i in 3:
		for r in m.update(dt, true, null, w.now, MUZZLE, Vector3(0, 1.9, -12)):
			w.fire(r)
		w.advance(dt)
	if fx != null and is_instance_valid(fx):
		check(is_inf(fx.stream.max_length), "with the wall gone the cap is off (%.2f)" % fx.stream.max_length)
	body.free()
	w.free()
	await frames(1)


func _replay(recs: Array[Dictionary], dt: float, late: float) -> Dictionary:
	var w := _world()
	var t := _dummy(w, "rep", Vector3(2.4, 0, -30), "static")
	var out := {}
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: out[h.shot] = h.point)
	var pending := recs.duplicate()
	var guard := 0
	while (not pending.is_empty() or _flying(w) > 0) and guard < 5000:
		while not pending.is_empty() and w.now >= float(pending[0]["t"]) + late - 1e-9:
			w.fire(pending.pop_front())
		w.advance(dt)
		guard += 1
	t.free()
	w.free()
	return out


func _determinism() -> void:
	var recs := _drive(_mount(), 3.0, 1.0 / 60.0, true)
	var base := _replay(recs, 1.0 / 60.0, 0.0)
	check(base.size() > 5 and base.size() < recs.size(), "part of the cone hits the off-axis target (%d of %d)" % [base.size(), recs.size()])
	for v: Array in [[1.0 / 30.0, 0.0], [1.0 / 144.0, 0.0], [0.11, 0.0], [1.0 / 60.0, 0.35], [1.0 / 60.0, 0.8]]:
		var r := _replay(recs, v[0], v[1])
		var same: bool = r.size() == base.size()
		for k: String in base:
			same = same and r.has(k) and (r[k] as Vector3).distance_to(base[k]) < 0.001
		check(same, "same hits for every chunk (dt %.4f, %.2f s late: %d vs %d)" % [v[0], v[1], r.size(), base.size()])
	await frames(1)


func _fxs(w: CombatWorld) -> Array:
	var out: Array = []
	for e in w.effects:
		if e is FlamerFx:
			out.append(e)
	return out


func _visual_stream() -> void:
	var w := _world()
	var ml := _mount("side_l")
	var mr := _mount("side_r")
	var muz := Vector3(3, 2, 1)
	w.set_muzzle(SHOOTER, "side_l", func() -> Vector3: return muz)
	var dt := 1.0 / 60.0
	var counts := {}
	var lit := true
	var active := false
	for i in 90:
		for r in ml.update(dt, true, null, w.now, MUZZLE, Vector3(0, 1.9, -12)):
			w.fire(r)
		for r in mr.update(dt, i < 45, null, w.now, MUZZLE, Vector3(0, 1.9, -12)):
			w.fire(r)
		w.advance(dt)
		counts[_fxs(w).size()] = true
		for fx: FlamerFx in _fxs(w):
			if fx.mount_key.ends_with("side_l"):
				lit = lit and fx.emitting()
				active = active or fx.stream.active()
	check(counts.has(2) and not counts.has(3), "one Stream per firing mount (%s)" % str(counts.keys()))
	check(lit, "the left mount's Stream emits all the time it fires")
	check(active, "its tongues show")
	var left: FlamerFx = null
	var right: FlamerFx = null
	for fx: FlamerFx in _fxs(w):
		if fx.mount_key.ends_with("side_l"):
			left = fx
		else:
			right = fx
	if check(left != null, "the left Stream is live"):
		eq(left.get_child_count(), 1, "one Stream node, no per-chunk nodes")
		check(left.stream is LowPolyFlame.Stream, "it is a LowPolyFlame.Stream")
		check(left.stream.global_position.distance_to(muz) < 1e-4, "it sits at the live muzzle")
		check((-left.stream.global_basis.y).normalized().dot((Vector3(0, 1.9, -12) - MUZZLE).normalized()) > 0.999,
			"its -Y points along the aim")
		near(left.stream.length, 45.0, 1e-6, "it is 45 m long")
		near(left.stream.spread, tan(deg_to_rad(5.0)), 1e-6, "its spread matches the 5° cone")
	if right != null:
		check(not right.emitting(), "the right mount stopped emitting after its last chunk")
	var chunks := _flying(w)
	check(chunks > 0, "the chunks themselves are effects (%d)" % chunks)
	# Release: the flame stops, the tongues in flight finish, the Streams go.
	for i in 150:
		ml.update(dt, false, null, w.now, MUZZLE, Vector3(0, 1.9, -12))
		w.advance(dt)
		if i == 20 and left != null and is_instance_valid(left):
			check(not left.emitting(), "stopped emitting shortly after the last chunk")
	eq(_fxs(w).size(), 0, "the Streams are gone once the flame has burnt out")
	w.free()
	await frames(1)


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.set_lab_option("weapon", "flamer")
	lab.set_lab_option("mass", "mech")
	lab.set_lab_option("fire", "hold")
	lab.set_lab_option("aim", "dummy_25")
	var d := lab.aim_dummy()     # the 25 m dummy: well inside the 45 m reach
	check(lab.mount.built(), "the flamer is built in the lab")
	var fx := 0
	for i in 120:
		await frames(1)
		fx = maxi(fx, _fxs(lab.world).size())
	check(lab.mount.shot_index >= 8, "the lab flamer fired (%d chunks)" % lab.mount.shot_index)
	eq(fx, 1, "one Stream for the lab mount")
	check(d.total_hp() < d.total_max_hp(), "the 25 m dummy lost HP (%.1f)" % d.total_hp())
	check(d.heat.value > 5.0, "and heated up (%.1f)" % d.heat.value)
	check(lab.heat.value > 0.0, "the lab shows the shooter heating (%.1f)" % lab.heat.value)
	# A wall 8 m out across the line of fire: the dummy behind it stops heating, the Stream is capped at the wall.
	var from := lab.muzzle()
	var along := (lab.aim_point() - from)
	var flat := Vector3(along.x, 0, along.z).normalized()
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(9, 7, 0.4)
	cs.shape = box
	wall.add_child(cs)
	add_child(wall)
	wall.global_transform = Transform3D(Basis.looking_at(flat, Vector3.UP), Vector3(from.x, 3.5, from.z) + flat * 8.2)
	await frames(30)
	var h0 := d.heat.value
	var hp0 := d.total_hp()
	await frames(60)
	check(d.heat.value < h0 and is_equal_approx(d.total_hp(), hp0),
		"behind a wall the dummy cools and takes nothing (heat %.1f -> %.1f, hp %.1f -> %.1f)" % [h0, d.heat.value, hp0, d.total_hp()])
	var f := _fxs(lab.world)
	if check(not f.is_empty(), "the lab Stream is live at the wall"):
		var cap := (f[0] as FlamerFx).stream.max_length
		var exp := (from.distance_to(lab.aim_point())) * 8.0 / Vector2(along.x, along.z).length()     # 8 m out (the wall face) along the tilted aim
		near(cap, exp, 0.3, "the lab Stream is capped at the wall face (%.2f m, %.2f expected)" % [cap, exp])
	wall.free()
	lab.queue_free()
	await frames(1)
