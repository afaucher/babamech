extends TestCase
## CombatWorld's broad phases (weapons.md §6.1) must not change a single hit: a seeded fuzz against straightforward
## reference implementations kept here.
##   first_hit: inside advance's effect step it rejects targets from PACKED bounds (CombatWorld _tb_*); outside it walks
##   the targets. Many random segments (zero-length to long, every hit radius) against ~50 targets on three "decks" (some
##   asleep far away, some unhittable, some with no spheres, exact duplicates for ties, teammates / enemies / neutrals),
##   random shooters and skip lists, friendly fire on and off, query true and false, with targets registering,
##   unregistering and gaining spheres in the middle of the step, moved / turned / scaled (and knocked by their own tick)
##   between steps. Every result must equal the reference's: same target, component, point, normal, frac, colour (so the
##   same tie-break between equal fracs: first target in `targets` order, first sphere).
##   splash: its bound reject (sphere cache, plain world_spheres only) must deliver the same hits in the same order with
##   the same numbers as the old loop, including a target that overrides world_spheres (as EnemyTrooper does).

const SEED := 0xF157
const STEPS := 80
const QUERIES := 70
const DECK_Y := [0.0, 22.0, 44.0]


class FuzzTarget extends CombatTarget:
	var hittable := true
	var hit_log: Array = []         ## shared: [target_id, damage, impulse, component, point] per applied hit (splash fuzz)
	var record_hits := false

	func is_hittable() -> bool:
		return hittable

	func apply_hit(h: Hit) -> void:
		if record_hits:
			hit_log.append([target_id, h.damage, h.impulse, h.component, h.point])
		else:
			super.apply_hit(h)


## A target whose world_spheres() is its own (like EnemyTrooper): splash must keep asking it.
class OverrideTarget extends FuzzTarget:
	var shift := Vector3(0.0, 1.5, 0.0)

	func world_spheres() -> Array:
		var out: Array = []
		var xf := global_transform
		for h: Dictionary in hit_shapes:
			out.append({"component": h["component"], "center": xf * ((h["center"] as Vector3) + shift), "radius": float(h["radius"]) * 1.3})
		return out


## Runs a callable inside advance's effect step (where first_hit uses the packed bounds).
class Prober extends CombatEffect:
	var body: Callable

	func advance_to(_now: float) -> void:
		if body.is_valid():
			body.call()

	func finished() -> bool:
		return false


var rng := RandomNumberGenerator.new()
var world: CombatWorld
var holders: Array[Node3D] = []
var pool: Array[FuzzTarget] = []      ## every target made (registered or not)
var hits_inside := 0
var hits_outside := 0
var ties := 0
var mism := 0
var compared := 0
var mutations := 0


func setup() -> void:
	rng.seed = SEED
	CombatWorld.verify_bounds = true
	CombatWorld.bounds_violations = 0
	await _fuzz_first_hit()
	await _fuzz_splash()
	CombatWorld.verify_bounds = OS.has_environment("BABAMECH_VERIFY_BOUNDS")
	finish()


func _make_world() -> void:
	world = CombatWorld.new()
	world.use_physics = false
	add_child(world)
	holders.clear()
	for k in DECK_Y.size():
		var h := Node3D.new()
		h.position = Vector3(0.0, DECK_Y[k], 0.0)
		add_child(h)
		holders.append(h)


func _new_target(i: int, override := false) -> FuzzTarget:
	var t: FuzzTarget = OverrideTarget.new() if override else FuzzTarget.new()
	t.target_id = "t%d" % i
	t.owner_peer = 0
	t.team = ["player", "enemy", "", "enemy", "player"][rng.randi() % 5]
	t.mass_class = ["light", "mech", "heavy", "static"][rng.randi() % 4]
	var n := rng.randi_range(0, 6) if rng.randf() > 0.06 else 0
	for s in n:
		t.add_hit_sphere("c%d" % s, Vector3(rng.randf_range(-2, 2), rng.randf_range(0, 6), rng.randf_range(-2, 2)), rng.randf_range(0.2, 2.2))
	holders[rng.randi() % holders.size()].add_child(t)
	_place(t)
	return t


func _place(t: Node3D) -> void:
	# Most targets near the play area of their deck, some far off (asleep on another part of the deck).
	var far := rng.randf() < 0.25
	var span := 160.0 if far else 18.0
	t.position = Vector3(rng.randf_range(-span, span), rng.randf_range(-0.5, 1.5), rng.randf_range(-span, span))
	t.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf_range(-PI, PI), rng.randf_range(-0.3, 0.3))
	var s := 1.0 if rng.randf() < 0.7 else rng.randf_range(0.5, 2.0)
	t.scale = Vector3(s, s, s)


## A twin of `src` (same transform, same spheres): equal fracs, so the tie-break shows.
func _twin(src: FuzzTarget, i: int) -> FuzzTarget:
	var t := FuzzTarget.new()
	t.target_id = "t%d" % i
	t.owner_peer = 0
	t.team = src.team
	t.mass_class = "static"
	for h: Dictionary in src.hit_shapes:
		t.add_hit_sphere(str(h["component"]) + "b", h["center"], float(h["radius"]))
	src.get_parent().add_child(t)
	t.transform = src.transform
	return t


func _seg() -> Array:
	var k := rng.randi() % DECK_Y.size()
	var y0: float = DECK_Y[k]
	var a := Vector3(rng.randf_range(-25, 25), y0 + rng.randf_range(0, 8), rng.randf_range(-25, 25))
	var pick := rng.randf()
	var b: Vector3
	if pick < 0.05:
		b = a                                            # zero length
	elif pick < 0.15:
		b = a + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * 60.0   # long
	elif pick < 0.25:
		b = Vector3(a.x + rng.randf_range(-6, 6), DECK_Y[(k + 1) % DECK_Y.size()] + rng.randf_range(0, 8), a.z + rng.randf_range(-6, 6))   # across decks
	elif pick < 0.55 and not world.targets.is_empty():
		var t: CombatTarget = world.targets[rng.randi() % world.targets.size()]   # aimed at a target (hits, near misses)
		if is_instance_valid(t) and t.is_inside_tree():
			var aim := t.global_position + Vector3(rng.randf_range(-3, 3), rng.randf_range(0, 7), rng.randf_range(-3, 3))
			a = aim + Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized() * rng.randf_range(2, 14)
			b = a + (aim - a) * rng.randf_range(0.6, 1.8)
		else:
			b = a + Vector3(8, 0, 0)
	else:
		b = a + Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 0.4), rng.randf_range(-1, 1)).normalized() * rng.randf_range(0.5, 12.0)
	return [a, b]


func _shooter() -> String:
	var p := rng.randf()
	if p < 0.2:
		return ""
	if p < 0.25:
		return "ghost"           # unknown id: no team
	return "t%d" % (rng.randi() % maxi(pool.size(), 1))


func _skip() -> Array:
	var s: Array = []
	if rng.randf() < 0.3:
		for i in rng.randi_range(1, 4):
			s.append("t%d" % (rng.randi() % maxi(pool.size(), 1)))
	return s


func _query_once(inside: bool) -> void:
	var sg := _seg()
	var r: float = [0.0, Combat.PROJECTILE_RADIUS, 0.6, 2.0][rng.randi() % 4]
	var sh := _shooter()
	var sk := _skip()
	var q := rng.randf() < 0.2
	var got := world.first_hit(sg[0], sg[1], r, sh, sk, q)
	var want := _ref_first_hit(sg[0], sg[1], r, sh, sk, q)
	compared += 1
	if not _same(got, want):
		mism += 1
		if mism <= 5:
			_fail("first_hit differs (%s): got %s want %s | a=%s b=%s r=%.3f sh=%s skip=%s query=%s" % [
				"inside" if inside else "outside", _fmt(got), _fmt(want), sg[0], sg[1], r, sh, sk, q])
	if not want.is_empty():
		if inside:
			hits_inside += 1
		else:
			hits_outside += 1


## Mutations inside the effect step that the packed bounds must notice (THE RULE allows them: no target moves).
func _mutate_inside() -> void:
	var p := rng.randf()
	if p < 0.3 and pool.size() > 0:
		var t := pool[rng.randi() % pool.size()]
		if t in world.targets:
			world.unregister(t)
		else:
			world.register(t)
		mutations += 1
	elif p < 0.5 and pool.size() > 0:
		var t := pool[rng.randi() % pool.size()]
		t.add_hit_sphere("late", Vector3(rng.randf_range(-3, 3), rng.randf_range(0, 7), rng.randf_range(-3, 3)), rng.randf_range(0.3, 2.0))
		mutations += 1
	elif p < 0.7 and pool.size() > 0:
		var t := pool[rng.randi() % pool.size()]
		t.hittable = not t.hittable
		mutations += 1
	elif p < 0.8:
		var t := _new_target(pool.size())
		pool.append(t)
		world.register(t)
		mutations += 1
	elif p < 0.85 and pool.size() > 0:
		var t := pool[rng.randi() % pool.size()]
		t.hit_shapes.clear()       # spheres removed (no epoch bump: a smaller target stays inside its packed bound)
		mutations += 1


func _fuzz_first_hit() -> void:
	_make_world()
	for i in 44:
		var t := _new_target(pool.size())
		pool.append(t)
	for i in 6:                    # exact twins: ties
		var src := pool[rng.randi() % 44]
		pool.append(_twin(src, pool.size()))
	for t in pool:
		world.register(t)
	var pr := Prober.new()
	pr.body = func() -> void:
		for k in QUERIES:
			if rng.randf() < 0.08:
				_mutate_inside()
			_query_once(true)
	world.add_child(pr)
	world.effects.append(pr)
	await frames(1)
	for step in STEPS:
		world.friendly_fire = rng.randf() < 0.5
		# Between steps (outside the window) targets may move any way: placed again, turned, scaled, decks shifted, and
		# knocked (their own tick moves them inside advance's target step, before the window).
		for t in pool:
			if rng.randf() < 0.35:
				_place(t)
			if rng.randf() < 0.2 and t.mass_class != "static":
				t.apply_impulse(Vector3(rng.randf_range(-20, 20), rng.randf_range(0, 6), rng.randf_range(-20, 20)), "fuzz")
		if rng.randf() < 0.3:
			holders[rng.randi() % holders.size()].position.x += rng.randf_range(-4, 4)
		for k in (10 if rng.randf() < 0.6 else 0):    # outside the window: the plain path (refreshes caches; not every step)
			_query_once(false)
		world.advance(1.0 / 60.0)   # inside: the packed path (the Prober queries)
	print("[first_hit fuzz] %d queries, %d hits inside the step, %d outside, %d mutations inside, %d ties in the reference, %d mismatches, %d bound violations" % [
		compared, hits_inside, hits_outside, mutations, ties, mism, CombatWorld.bounds_violations])
	eq(mism, 0, "first_hit: packed and plain paths equal the reference on every query")
	eq(CombatWorld.bounds_violations, 0, "no packed reject the live target would not make")
	check(hits_inside > 200 and hits_outside > 40, "the fuzz hits plenty of targets (%d inside, %d outside)" % [hits_inside, hits_outside])
	check(mutations > 20, "targets registered / unregistered / grew spheres inside the step (%d)" % mutations)
	world.queue_free()
	for h in holders:
		h.queue_free()
	pool.clear()
	await frames(2)


## Reference first_hit over targets only (no physics, no props in this scene): every sphere of every target, no broad phase.
func _ref_first_hit(a: Vector3, b: Vector3, r: float, shooter: String, skip: Array, query: bool) -> Dictionary:
	var best := {}
	var best_f := 2.0
	var sh_team := world._team_of(shooter)
	for t in world.targets:
		if not is_instance_valid(t) or not t.is_hittable() or t.target_id == shooter or t.target_id in skip:
			continue
		if _ref_spared(sh_team, t, shooter, query):
			continue
		for s: Dictionary in t.world_spheres():
			var c: Vector3 = s["center"]
			var f := Combat.segment_sphere(a, b, c, float(s["radius"]) + r)
			if f >= 0.0 and f < best_f:
				var p := a.lerp(b, f)
				best_f = f
				best = {"target": t, "component": s["component"], "point": p, "normal": (p - c).normalized(), "frac": f,
					"color": MechMeshes.GREY}
			elif f >= 0.0 and f == best_f:
				ties += 1
	return best


## weapons.md §4.6, written out again: a query passes every same-team target; a shot passes its shooter, and a same-team
## target unless it is a "player" shot with friendly fire on.
func _ref_spared(sh_team: String, t: CombatTarget, shooter: String, query: bool) -> bool:
	if query:
		return sh_team != "" and t.team == sh_team
	if shooter != "" and t.target_id == shooter:
		return true
	if sh_team == "" or t.team != sh_team:
		return false
	return not (world.friendly_fire and sh_team == "player")


func _same(x: Dictionary, y: Dictionary) -> bool:
	if x.is_empty() or y.is_empty():
		return x.is_empty() and y.is_empty()
	return x["target"] == y["target"] and str(x["component"]) == str(y["component"]) and x["point"] == y["point"] \
		and x["normal"] == y["normal"] and float(x["frac"]) == float(y["frac"]) and x["color"] == y["color"]


func _fmt(h: Dictionary) -> String:
	if h.is_empty():
		return "{}"
	var t: CombatTarget = h["target"]
	return "{%s %s frac=%.9f}" % [t.target_id if t != null else "world", h["component"], float(h["frac"])]


# --- splash -------------------------------------------------------------------------------------------------------

func _fuzz_splash() -> void:
	_make_world()
	var hits: Array = []
	for i in 40:
		var t := _new_target(pool.size(), i % 7 == 3)     # every 7th overrides world_spheres
		t.record_hits = true
		t.hit_log = hits
		pool.append(t)
		world.register(t)
	await frames(1)
	var cases := 0
	var delivered := 0
	var bad := 0
	for step in 300:
		world.friendly_fire = rng.randf() < 0.5
		if rng.randf() < 0.3:
			_place(pool[rng.randi() % pool.size()])
		if rng.randf() < 0.1:
			var t := pool[rng.randi() % pool.size()]
			t.hittable = not t.hittable
		var k := rng.randi() % DECK_Y.size()
		var point := Vector3(rng.randf_range(-22, 22), DECK_Y[k] + rng.randf_range(0, 6), rng.randf_range(-22, 22))
		if rng.randf() < 0.4 and not world.targets.is_empty():
			point = world.targets[rng.randi() % world.targets.size()].global_position + Vector3(rng.randf_range(-4, 4), rng.randf_range(0, 6), rng.randf_range(-4, 4))
		var st := {"splash_radius": rng.randf_range(0.5, 12.0), "splash_damage": rng.randf_range(10, 200),
			"splash_knockback": rng.randf_range(0, 12), "splash_lift": rng.randf_range(0, 4)}
		var sh := _shooter()
		var rec := {"shooter": sh, "team": ["player", "enemy", ""][rng.randi() % 3], "peer": 1, "weapon": "fuzz", "t": 0.0,
			"hardpoint": "h", "shot_index": step}
		var ex: CombatTarget = pool[rng.randi() % pool.size()] if rng.randf() < 0.3 else null
		var want := _ref_splash(rec, st, point, ex)
		hits.clear()
		world.splash(rec, st, point, ex)
		cases += 1
		delivered += hits.size()
		if not _same_log(hits, want):
			bad += 1
			if bad <= 5:
				_fail("splash differs at %s r=%.2f: got %s want %s" % [point, float(st["splash_radius"]), str(hits), str(want)])
	print("[splash fuzz] %d splashes, %d hits delivered, %d mismatches" % [cases, delivered, bad])
	eq(bad, 0, "splash: the same hits, in the same order, with the same numbers as the reference")
	check(delivered > 100, "the splash fuzz delivers plenty of hits (%d)" % delivered)
	world.queue_free()
	for h in holders:
		h.queue_free()
	pool.clear()
	await frames(2)


## The old splash loop (every target's world_spheres, no broad phase) as the hits it would deliver.
func _ref_splash(record: Dictionary, st: Dictionary, point: Vector3, exclude: CombatTarget) -> Array:
	var out: Array = []
	var rad := float(st["splash_radius"])
	var dmg := float(st["splash_damage"])
	var sh := str(record["shooter"])
	var sh_team := world._team_of(sh, str(record["team"]))
	for t in world.targets:
		if t == exclude or not is_instance_valid(t) or not t.is_hittable():
			continue
		if _ref_spared(sh_team, t, sh, false):
			continue
		var best := INF
		var comp := ""
		var centre: Vector3 = t.global_position
		for s: Dictionary in t.world_spheres():
			var d := maxf(point.distance_to(s["center"]) - float(s["radius"]), 0.0)
			if d < best:
				best = d
				comp = s["component"]
				centre = s["center"]
		if best > rad:
			continue
		var k := 1.0 - best / rad
		var o: Vector3 = centre - point
		o -= t.up * o.dot(t.up)
		var imp: Vector3 = (o.normalized() * float(st["splash_knockback"]) + t.up * float(st["splash_lift"])) * k
		out.append([t.target_id, dmg * k, imp, comp, point])
	return out


func _same_log(x: Array, y: Array) -> bool:
	if x.size() != y.size():
		return false
	for i in x.size():
		var a: Array = x[i]
		var b: Array = y[i]
		if str(a[0]) != str(b[0]) or float(a[1]) != float(b[1]) or a[2] != b[2] or str(a[3]) != str(b[3]) or a[4] != b[4]:
			return false
	return true
