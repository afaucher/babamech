extends TestCase
## Ambient life through CombatWorld (docs/design/ambient-life.md §6) with a stub node in group "ambient_life" that
## records calls: a projectile's sweeps cover its path contiguously from muzzle to impact with r = PROJECTILE_RADIUS and
## src = the shooter's peer (straight, curved rocket / missile, arcing mortar, piercing rail slug), splash calls blast
## with the splash radius, the laser and the flamer call sweep, enemy fire passes src -1, a machine that doesn't decide
## the shot calls nothing, the returned kill count changes nothing, and with no node nothing errors.

const LASER := preload("res://scripts/combat/weapons/laser.gd")


class StubLife extends Node:
	var sweeps: Array = []         ## [a, b, r, src]
	var blasts: Array = []         ## [point, radius, src]
	var kills := 0                 ## what both calls return

	func sweep(a: Vector3, b: Vector3, r: float, src: int) -> int:
		sweeps.append([a, b, r, src])
		return kills

	func blast(point: Vector3, radius: float, src: int) -> int:
		blasts.append([point, radius, src])
		return kills


func setup() -> void:
	await _straight()
	await _curved("rockets")
	await _curved("missiles")
	await _mortar()
	await _railgun()
	await _laser()
	await _flamer()
	await _enemy()
	await _not_deciding()
	await _return_value_ignored()
	await _no_node()
	finish()


func _scene(with_life: bool = true) -> Array:
	var w := CombatWorld.new()
	w.mission_seed = 11
	w.use_physics = false
	add_child(w)
	var life: StubLife = null
	if with_life:
		life = StubLife.new()
		life.add_to_group("ambient_life")
		add_child(life)
	return [w, life]


func _dummy(w: CombatWorld, at: Vector3, id: String = "d") -> TargetDummy:
	var d := TargetDummy.new()
	d.target_id = id
	d.mass_class = "light"
	d.position = at
	add_child(d)
	w.register(d)
	return d


func _run(w: CombatWorld, seconds: float) -> void:
	for i in int(seconds * 60.0):
		w.advance(1.0 / 60.0)


func _cleanup(nodes: Array) -> void:
	for n: Node in nodes:
		if n != null:
			n.free()
	await frames(1)


## The sweeps chain end to start from `from`, all with radius `r` and source `src`. Returns the last end point.
func _chain(label: String, sweeps: Array, from: Vector3, r: float, src: int) -> Vector3:
	if not check(sweeps.size() >= 1, "%s: calls sweep" % label):
		return from
	var at := from
	var gaps := 0
	var bad_r := 0
	var bad_src := 0
	for s: Array in sweeps:
		if (s[0] as Vector3).distance_to(at) > 1e-3:
			gaps += 1
		if absf(float(s[2]) - r) > 1e-5:
			bad_r += 1
		if int(s[3]) != src:
			bad_src += 1
		at = s[1]
	eq(gaps, 0, "%s: the %d sweeps are contiguous from the muzzle" % [label, sweeps.size()])
	eq(bad_r, 0, "%s: every sweep has r = %.2f" % [label, r])
	eq(bad_src, 0, "%s: every sweep has src = %d" % [label, src])
	return at


func _straight() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d := _dummy(w, Vector3(0, 0, -30))
	await frames(1)
	var o := Vector3(0, 1.9, 0)
	var p := w.fire(Combat.fire_record("me", 1, "hp", "autocannon", o, Vector3(0, 1.9, -60), w.now, 0)) as Projectile
	_run(w, 2.0)
	check(w.life() == life, "the world finds the ambient_life node by its group")
	var end := _chain("autocannon", life.sweeps, o, Combat.PROJECTILE_RADIUS, 1)
	check(p.end_time > 0.0 and end.distance_to(p.flight_pos(p.end_time)) < 1e-3,
		"autocannon: the last sweep ends at the impact (%s)" % end)
	check(d.total_hp() < d.total_max_hp(), "autocannon: the dummy behind the path still takes the hit")
	if check(life.blasts.size() == 1, "autocannon: its small splash calls blast once (%d)" % life.blasts.size()):
		near(float(life.blasts[0][1]), float(w.stats("autocannon")["splash_radius"]), 0.001, "autocannon: blast radius = splash radius")
		check((life.blasts[0][0] as Vector3).distance_to(end) < 1e-3, "autocannon: the blast is at the impact")
	await _cleanup([d, life, w])


func _curved(weapon: String) -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d := _dummy(w, Vector3(0, 0, -40))
	await frames(1)
	var p := w.fire(Combat.fire_record("me", 1, "hp", weapon, Vector3(0, 1.9, 0), Vector3(0, 1.9, -40), w.now, 0)) as Projectile
	_run(w, 4.0)
	var end := _chain(weapon, life.sweeps, p.flight_pos(0.0), Combat.PROJECTILE_RADIUS, 1)
	check(p.end_time > 0.0 and end.distance_to(p.flight_pos(p.end_time)) < 0.05,
		"%s: the last sweep ends where it detonated" % weapon)
	var st := w.stats(weapon)
	if check(life.blasts.size() == 1, "%s: the splash calls blast once (%d)" % [weapon, life.blasts.size()]):
		near(float(life.blasts[0][1]), float(st["splash_radius"]), 0.001, "%s: blast radius = splash radius" % weapon)
		eq(int(life.blasts[0][2]), 1, "%s: blast src = the shooter's peer" % weapon)
		check((life.blasts[0][0] as Vector3).distance_to(end) < 0.05, "%s: the blast is at the end of the path" % weapon)
	await _cleanup([d, life, w])


func _mortar() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	await frames(1)
	var p := w.fire(Combat.fire_record("me", 1, "back", "mortar", Vector3(0, 3, 0), Vector3(0, 0, -80), w.now, 0)) as MortarShell
	_run(w, 6.0)
	var end := _chain("mortar", life.sweeps, p.flight_pos(0.0), Combat.PROJECTILE_RADIUS, 1)
	check(end.distance_to(p.flight_pos(p.flight_time)) < 1e-3, "mortar: the sweeps follow the arc to the landing point")
	var st := w.stats("mortar")
	if check(life.blasts.size() == 1, "mortar: the splash calls blast once (%d)" % life.blasts.size()):
		near(float(life.blasts[0][1]), float(st["splash_radius"]), 0.001, "mortar: blast radius = splash radius")
	await _cleanup([life, w])


func _railgun() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d1 := _dummy(w, Vector3(0, 0, -20), "d1")
	var d2 := _dummy(w, Vector3(0, 0, -40), "d2")
	await frames(1)
	var o := Vector3(0, 1.9, 0)
	var p := w.fire(Combat.fire_record("me", 1, "hp", "railgun", o, Vector3(0, 1.9, -60), w.now, 0)) as Projectile
	_run(w, 3.0)
	var end := _chain("railgun", life.sweeps, o, Combat.PROJECTILE_RADIUS, 1)
	check(d1.total_hp() < d1.total_max_hp() and d2.total_hp() < d2.total_max_hp(), "railgun: the slug pierces both dummies")
	check(end.z < -40.0, "railgun: the sweeps carry on through the pierced targets (end z %.1f)" % end.z)
	check(end.distance_to(p.flight_pos(p.end_time)) < 1e-3, "railgun: the last sweep ends where the slug stopped")
	await _cleanup([d1, d2, life, w])


func _laser() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d := _dummy(w, Vector3(0, 0, -30))
	await frames(1)
	var o := Vector3(0, 1.9, 0)
	var rec := Combat.fire_record("me", 1, "hp", "laser", o, Vector3(0, 1.9, -60), w.now, 0)
	var tr := LASER.trace(w, rec, w.stats("laser"))     # before the pulse shoves the dummy
	w.fire(rec)
	_run(w, 0.5)
	if check(life.sweeps.size() == 1, "laser: one sweep per pulse (%d)" % life.sweeps.size()):
		var sw: Array = life.sweeps[0]
		check((sw[0] as Vector3).distance_to(o) < 1e-4, "laser: the sweep starts at the muzzle")
		check((sw[1] as Vector3).distance_to(tr["to"]) < 1e-3 and (tr["to"] as Vector3).z > -30.0,
			"laser: and ends at the beam's end (on the dummy)")
		eq(life.blasts.size(), 0, "laser: no splash, no blast")
		near(float(sw[2]), LASER.RAY_RADIUS, 1e-5, "laser: r = the ray radius")
		eq(int(sw[3]), 1, "laser: src = the shooter's peer")
	check(d.total_hp() < d.total_max_hp(), "laser: the dummy still takes the pulse")
	await _cleanup([d, life, w])


func _flamer() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	await frames(1)
	var o := Vector3(0, 1.9, 0)
	var c := w.fire(Combat.fire_record("me", 1, "hp", "flamer", o, Vector3(0, 1.9, -60), w.now, 0)) as FlameChunk
	_run(w, 2.0)
	if check(life.sweeps.size() >= 2, "flamer: the chunk calls sweep along its flight (%d)" % life.sweeps.size()):
		var at := o
		var gaps := 0
		var grows := true
		var last_r := 0.0
		for sw: Array in life.sweeps:
			if (sw[0] as Vector3).distance_to(at) > 1e-3:
				gaps += 1
			if float(sw[2]) < last_r - 1e-6:
				grows = false
			last_r = float(sw[2])
			at = sw[1]
			eq(int(sw[3]), 1, "flamer: src = the shooter's peer")
		eq(gaps, 0, "flamer: the chunk's sweeps are contiguous from the muzzle")
		check(grows, "flamer: the sweep radius grows along the stream")
		near(last_r, c.hit_radius(c.travel), 1e-4, "flamer: the last sweep has the stream's radius at its end")
		check(at.distance_to(c.flight_pos(c.max_time)) < 1e-3, "flamer: the sweeps reach the end of the stream")
	await _cleanup([life, w])


func _enemy() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d := _dummy(w, Vector3(0, 0, -30))
	d.team = "player"
	await frames(1)
	for weapon: String in ["enemy_bolter", "enemy_siege_shell"]:
		life.sweeps.clear()
		life.blasts.clear()
		var o := Vector3(0, 1.9, 0)
		# As EnemyBase._fire_one_round builds it: peer 1 (host-owned), "enemy", team "enemy".
		var rec := Combat.fire_record("turret", 1, weapon, weapon, o, Vector3(0, 1.9, -30), w.now, 0)
		rec["enemy"] = true
		rec["team"] = "enemy"
		var p := w.fire(rec) as Projectile
		_run(w, 3.0)
		_chain(weapon, life.sweeps, p.flight_pos(0.0), Combat.PROJECTILE_RADIUS, -1)
		if weapon == "enemy_siege_shell" and check(life.blasts.size() == 1, "%s: blast once" % weapon):
			eq(int(life.blasts[0][2]), -1, "%s: blast src = -1 for enemy fire" % weapon)
	await _cleanup([d, life, w])


func _not_deciding() -> void:
	var s := _scene()
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	var d := _dummy(w, Vector3(0, 0, -30))
	await frames(1)
	for weapon: String in ["rockets", "laser", "flamer"]:
		w.fire(Combat.fire_record("other", 2, "hp", weapon, Vector3(0, 1.9, 0), Vector3(0, 1.9, -30), w.now, 0))
	_run(w, 3.0)
	eq(life.sweeps.size() + life.blasts.size(), 0, "another machine's shots call nothing here (the shooter's machine decides)")
	await _cleanup([d, life, w])


## Fire the same shots into a scene and return what they did: [end times..., dummy hp].
func _outcome(with_life: bool, kills: int) -> Array:
	var s := _scene(with_life)
	var w: CombatWorld = s[0]
	var life: StubLife = s[1]
	if life != null:
		life.kills = kills
	var d := _dummy(w, Vector3(0, 0, -30))
	await frames(1)
	var out := []
	var shots := []
	for i in 4:
		var weapon: String = ["autocannon", "rockets", "railgun", "mortar"][i]
		var to := Vector3(0, 0, -30) if weapon == "mortar" else Vector3(0, 1.9, -30)
		shots.append(w.fire(Combat.fire_record("me", 1, "hp%d" % i, weapon, Vector3(0, 1.9, 0), to, w.now, 0)))
	w.fire(Combat.fire_record("me", 1, "hl", "laser", Vector3(0, 1.9, 0), Vector3(0, 1.9, -30), w.now, 0))
	var chunk := w.fire(Combat.fire_record("me", 1, "hf", "flamer", Vector3(0, 1.9, 0), Vector3(0, 1.9, -30), w.now, 0))
	_run(w, 6.0)
	for p: Projectile in shots:
		out.append(p.end_time)
	out.append((chunk as FlameChunk).end_time)
	out.append(d.total_hp())
	if life != null:
		check(life.sweeps.size() > 0 and life.blasts.size() > 0, "the stub was called (kills = %d)" % kills)
	await _cleanup([d, life, w])
	return out


func _return_value_ignored() -> void:
	var a: Array = await _outcome(true, 0)
	var b: Array = await _outcome(true, 9)
	var c: Array = await _outcome(false, 0)
	var same_ab := true
	var same_ac := true
	for i in a.size():
		same_ab = same_ab and absf(float(a[i]) - float(b[i])) < 1e-5
		same_ac = same_ac and absf(float(a[i]) - float(c[i])) < 1e-5
	check(same_ab, "a returned kill count changes no shot (%s vs %s)" % [a, b])
	check(same_ac, "and shots are the same with no ambient_life node (%s vs %s)" % [a, c])


func _no_node() -> void:
	var s := _scene(false)
	var w: CombatWorld = s[0]
	await frames(1)
	for weapon: String in MechCatalog.WEAPON_ORDER:
		w.fire(Combat.fire_record("me", 1, "hp", weapon, Vector3(0, 1.9, 0), Vector3(0, 0, -50), w.now, 0))
	_run(w, 6.0)
	check(w.life() == null, "no ambient_life node: life() is null and every weapon fired without it")
	await _cleanup([w])
