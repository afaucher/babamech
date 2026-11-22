extends TestCase
## City props through CombatWorld (docs/design/city-props.md §5) with a fake props node in group "city_props": a shot
## that meets a prop stops there (nearest of targets / world / props by frac), a direct hit calls apply_impulse(id, dv
## = stats.knockback along the shot) with no damage, a target in front of a prop takes the hit instead, splash calls
## blast(point, splash radius, prop_blast / splash_knockback), the prop's colour reaches the debris, and a machine that
## doesn't decide the shot calls nothing (the shot still stops on the prop).


class FakeProps extends Node:
	var centre := Vector3.ZERO
	var radius := 0.6
	var color := Color(0.1, 0.8, 0.2)
	var impulses: Array = []       ## [id, dv, src]
	var blasts: Array = []         ## [point, radius, dv, src]

	func first_hit(a: Vector3, b: Vector3, r: float) -> Dictionary:
		var f := Combat.segment_sphere(a, b, centre, radius + r)
		if f < 0.0:
			return {}
		var p := a.lerp(b, f)
		return {"id": 7, "frac": f, "point": p, "normal": (p - centre).normalized(), "color": color}

	func apply_impulse(id: int, dv: Vector3, src: String) -> void:
		impulses.append([id, dv, src])

	func blast(point: Vector3, r: float, dv: float, src: String) -> void:
		blasts.append([point, r, dv, src])


func setup() -> void:
	await _direct("autocannon")
	await _direct("laser")
	await _direct("rockets")
	await _target_in_front()
	await _not_deciding()
	await _mortar_blast()
	finish()


func _scene(prop_at: Vector3) -> Array:
	var w := CombatWorld.new()
	w.mission_seed = 9
	w.use_physics = false
	add_child(w)
	var props := FakeProps.new()
	props.centre = prop_at
	props.add_to_group("city_props")
	add_child(props)
	return [w, props]


func _dummy(w: CombatWorld, at: Vector3) -> TargetDummy:
	var d := TargetDummy.new()
	d.target_id = "d"
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
		n.free()
	await frames(1)


func _direct(weapon: String) -> void:
	var s := _scene(Vector3(0, 1.9, -30))
	var w: CombatWorld = s[0]
	var props: FakeProps = s[1]
	props.radius = 1.2       # the rockets' corkscrew and tube offsets stay inside it
	var d := _dummy(w, Vector3(0, 0, -60))
	await frames(1)
	w.advance(1.0 / 60.0)
	check(w.props() == props, "%s: the world finds the props node by its group" % weapon)
	var spawned := []
	w.child_entered_tree.connect(func(n: Node) -> void:
		if n is ImpactFx:
			spawned.append(n))
	w.fire(Combat.fire_record("me", 1, "hp", weapon, Vector3(0, 1.9, 0), Vector3(0, 1.9, -60), w.now, 0))
	_run(w, 2.0)
	near(d.total_hp(), d.total_max_hp(), 0.001, "%s: the shot stops on the prop (the dummy behind is untouched)" % weapon)
	var st := w.stats(weapon)
	if check(props.impulses.size() >= 1, "%s: a direct hit calls apply_impulse" % weapon):
		var imp: Array = props.impulses[0]
		eq(int(imp[0]), 7, "%s: on the prop's id" % weapon)
		near((imp[1] as Vector3).length(), float(st["knockback"]), 0.001, "%s: dv = stats.knockback" % weapon)
		check((imp[1] as Vector3).normalized().dot(Vector3.FORWARD) > 0.98, "%s: along the shot" % weapon)
		eq(str(imp[2]), "me", "%s: src = the shooter" % weapon)
	if weapon == "rockets":
		if check(props.blasts.size() >= 1, "rockets: the splash calls blast"):
			near(float(props.blasts[0][1]), float(st["splash_radius"]), 0.001, "rockets: blast radius = splash radius")
			near(float(props.blasts[0][2]), float(st["prop_blast"]), 0.001, "rockets: blast dv = prop_blast")
	elif weapon == "laser":
		eq(props.blasts.size(), 0, "laser: no splash")
	var shards_coloured := false
	for fx: ImpactFx in spawned:
		for p: Dictionary in fx._parts:
			if str(p["kind"]) == "shard" and (p["node"] as MeshInstance3D).mesh == CombatMeshes.shard(props.color):
				shards_coloured = true
	if weapon != "laser":      # the laser's shards are always molten orange
		check(shards_coloured, "%s: the debris takes the prop's colour" % weapon)
	await _cleanup([d, props, w])


func _target_in_front() -> void:
	var s := _scene(Vector3(0, 1.9, -50))
	var w: CombatWorld = s[0]
	var props: FakeProps = s[1]
	var d := _dummy(w, Vector3(0, 0, -30))
	await frames(1)
	w.fire(Combat.fire_record("me", 1, "hp", "autocannon", Vector3(0, 1.9, 0), Vector3(0, 1.9, -60), w.now, 0))
	_run(w, 2.0)
	check(d.total_hp() < d.total_max_hp(), "a target in front of the prop takes the hit")
	eq(props.impulses.size(), 0, "and the prop behind it doesn't")
	await _cleanup([d, props, w])


func _not_deciding() -> void:
	var s := _scene(Vector3(0, 1.9, -30))
	var w: CombatWorld = s[0]
	var props: FakeProps = s[1]
	var d := _dummy(w, Vector3(0, 0, -60))
	await frames(1)
	var p := w.fire(Combat.fire_record("other", 2, "hp", "rockets", Vector3(0, 1.9, 0), Vector3(0, 1.9, -60), w.now, 0)) as Projectile
	_run(w, 2.0)
	check(p.end_time > 0.0 and p.end_time < 1.0, "another machine's shot still stops on the prop here (%.2f s)" % p.end_time)
	eq(props.impulses.size() + props.blasts.size(), 0, "but only the deciding machine calls the prop verbs")
	await _cleanup([d, props, w])


func _mortar_blast() -> void:
	var s := _scene(Vector3(3, 1.0, -80))
	var w: CombatWorld = s[0]
	var props: FakeProps = s[1]
	props.radius = 0.1
	await frames(1)
	w.fire(Combat.fire_record("me", 1, "back", "mortar", Vector3(0, 3, 0), Vector3(0, 0, -80), w.now, 0))
	_run(w, 5.0)
	var st := w.stats("mortar")
	if check(props.blasts.size() == 1, "the mortar's splash calls blast once (%d)" % props.blasts.size()):
		near(float(props.blasts[0][1]), float(st["splash_radius"]), 0.001, "blast radius = the splash radius")
		near(float(props.blasts[0][2]), float(st["prop_blast"]), 0.001, "blast dv = prop_blast")
	await _cleanup([props, w])
