extends TestCase
## City props through CombatWorld (docs/design/city-props.md §5) with a fake props node in group "city_props": a shot
## that meets a prop stops there (nearest of targets / world / props by frac), a direct hit calls apply_impulse(id, dv
## = stats.knockback along the shot) with no damage, a target in front of a prop takes the hit instead, splash calls
## blast(point, splash radius, prop_blast / splash_knockback), the prop's colour reaches the debris, and a machine that
## doesn't decide the shot calls nothing (the shot still stops on the prop).
## STACK (integration W3): with a fake two-deck stack (each deck its own fake props, both in group "city_props", the
## UPPER deck's first) a hit / blast on the lower deck reaches the lower deck's props only and never asks the upper's; a
## shot dropping from the upper deck to the lower asks both and knocks the lower prop; a hit on the upper deck goes to
## the upper node even with the same prop id; the stack is adopted from group "city_stack" when not injected; the ring
## for a point is the stack's deck ring. Then the same on a real CityStack placed as the mission places it.


class FakeProps extends Node:
	var centre := Vector3.ZERO
	var radius := 0.6
	var color := Color(0.1, 0.8, 0.2)
	var impulses: Array = []       ## [id, dv, src]
	var blasts: Array = []         ## [point, radius, dv, src]
	var asked := 0                 ## first_hit calls

	func first_hit(a: Vector3, b: Vector3, r: float) -> Dictionary:
		asked += 1
		var f := Combat.segment_sphere(a, b, centre, radius + r)
		if f < 0.0:
			return {}
		var p := a.lerp(b, f)
		return {"id": 7, "frac": f, "point": p, "normal": (p - centre).normalized(), "color": color}

	func apply_impulse(id: int, dv: Vector3, src: String) -> void:
		impulses.append([id, dv, src])

	func blast(point: Vector3, r: float, dv: float, src: String) -> void:
		blasts.append([point, r, dv, src])


class FakeDeck extends Node3D:
	var props: Node


## Two decks about one axis parallel to X through (0, 1000, 0): deck 1 (lower, floor radius 1000) at the origin, deck 0
## (upper, radius 980) with its floor at y = 20. deck_at / ring / ring_at as CityStack's.
class FakeStack extends Node3D:
	const UPPER_R := 980.0
	const LOWER_R := 1000.0
	var decks: Array = []
	var rings: Array = []

	func make(upper: Node, lower: Node) -> void:
		for i in 2:
			var d := FakeDeck.new()
			d.position = Vector3(0, 20, 0) if i == 0 else Vector3.ZERO
			d.props = upper if i == 0 else lower
			add_child(d)
			decks.append(d)
			rings.append(CityStack.DeckRing.new(UPPER_R if i == 0 else LOWER_R, d))

	func deck_at(p: Vector3) -> int:
		return 0 if (rings[1] as RingFrame).dist_to_axis(p) <= UPPER_R + 1.0 else 1

	func ring() -> RingFrame:
		return rings[1]

	func ring_at(p: Vector3) -> RingFrame:
		return rings[deck_at(p)]


func setup() -> void:
	timeout_sec = 180.0
	await _direct("autocannon")
	await _direct("laser")
	await _direct("rockets")
	await _target_in_front()
	await _not_deciding()
	await _mortar_blast()
	await _stack_lower_hit()
	await _stack_lower_blast()
	await _stack_cross_deck()
	await _stack_upper_hit()
	await _stack_ring()
	await _real_stack()
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
	check(w.stack == null and w.city_stack() == null, "%s: no stack in the scene, none adopted" % weapon)
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
			if str(p["kind"]) == "shard" and p["mesh"] == CombatMeshes.shard(props.color):   # (a part over gives its node back)
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


# --- Stack (integration W3) ------------------------------------------------------------------------------

## A CombatWorld, a FakeStack and its two decks' fake props (both in group "city_props", the upper deck's first, so the
## old "first node in the group" lookup would pick the wrong deck). `inject`: world.stack is set (as TestDriveCombat
## does), else the stack is only in group "city_stack".
func _stack_scene(upper_at: Vector3, lower_at: Vector3, inject: bool) -> Array:
	var w := CombatWorld.new()
	w.mission_seed = 9
	w.use_physics = false
	add_child(w)
	var upper := FakeProps.new()
	upper.centre = upper_at
	upper.add_to_group("city_props")
	add_child(upper)
	var lower := FakeProps.new()
	lower.centre = lower_at
	lower.add_to_group("city_props")
	add_child(lower)
	var st := FakeStack.new()
	add_child(st)
	st.make(upper, lower)
	if inject:
		w.stack = st
	else:
		st.add_to_group("city_stack")
	w.ring = st.rings[1]     # TestDriveCombat: world.ring = td.city.ring (the deck at the origin)
	return [w, st, upper, lower]


func _stack_lower_hit() -> void:
	# Both fake props answer at the same spot: if the upper deck's were asked it would win (asked first).
	var s := _stack_scene(Vector3(0, 1.9, -30), Vector3(0, 1.9, -30), true)
	var w: CombatWorld = s[0]
	var upper: FakeProps = s[2]
	var lower: FakeProps = s[3]
	await frames(1)
	w.fire(Combat.fire_record("me", 1, "hp", "autocannon", Vector3(0, 1.9, 0), Vector3(0, 1.9, -60), w.now, 0))
	_run(w, 2.0)
	check(w.props() == null, "stack: props() is null (no single props node)")
	check(lower.impulses.size() >= 1, "stack: a hit on the lower deck reaches the lower deck's props (%d)" % lower.impulses.size())
	eq(upper.impulses.size(), 0, "stack: and not the upper deck's")
	eq(upper.asked, 0, "stack: a shot on the lower deck never asks the upper deck's props")
	await _cleanup([s[1], upper, lower, w])


func _stack_lower_blast() -> void:
	var s := _stack_scene(Vector3(3, 1.0, -80), Vector3(3, 1.0, -80), false)
	var w: CombatWorld = s[0]
	var upper: FakeProps = s[2]
	var lower: FakeProps = s[3]
	upper.radius = 0.1
	lower.radius = 0.1
	await frames(1)
	w.advance(1.0 / 60.0)
	check(w.stack == s[1], "stack: adopted from group city_stack when not injected")
	w.fire(Combat.fire_record("me", 1, "back", "mortar", Vector3(0, 3, 0), Vector3(0, 0, -80), w.now, 0))
	_run(w, 5.0)
	eq(lower.blasts.size(), 1, "stack: a blast on the lower deck reaches the lower deck's props")
	eq(upper.blasts.size(), 0, "stack: and not the upper deck's")
	await _cleanup([s[1], upper, lower, w])


func _stack_cross_deck() -> void:
	var s := _stack_scene(Vector3(15, 21.9, 0), Vector3(0, 1.9, -30), true)
	var w: CombatWorld = s[0]
	var upper: FakeProps = s[2]
	var lower: FakeProps = s[3]
	lower.radius = 1.2
	await frames(1)
	w.fire(Combat.fire_record("me", 1, "hp", "autocannon", Vector3(0, 26, 0), Vector3(0, 1.9, -30), w.now, 0))
	_run(w, 2.0)
	check(upper.asked > 0, "stack: a shot from the upper deck asks the upper deck's props while it is there (%d)" % upper.asked)
	check(lower.impulses.size() >= 1, "stack: dropping through to the lower deck it knocks the lower deck's prop")
	eq(upper.impulses.size(), 0, "stack: the upper deck's prop (off the path) untouched")
	eq(w.deck_span(Vector3(0, 25, 0), Vector3(0, 15, 0), 0.0), Vector2i(0, 1), "stack: a chord crossing a deck boundary spans both decks")
	eq(w.deck_span(Vector3(0, 5, 0), Vector3(0, 5, -10), 0.0), Vector2i(1, 1), "stack: a chord on the lower deck spans only it")
	await _cleanup([s[1], upper, lower, w])


func _stack_upper_hit() -> void:
	var s := _stack_scene(Vector3(0, 21.9, -10), Vector3(0, 1.9, -10), true)
	var w: CombatWorld = s[0]
	var upper: FakeProps = s[2]
	var lower: FakeProps = s[3]
	await frames(1)
	var h := w.first_hit(Vector3(0, 21.9, 0), Vector3(0, 21.9, -20), 0.0, "me")
	if check(h.has("prop"), "stack: first_hit finds the upper deck's prop"):
		check(h["prop_node"] == upper, "stack: the hit names the upper deck's props node")
		w.hit_prop({"shooter": "me", "peer": 1}, {"knockback": 5.0}, h, Vector3.FORWARD)
	eq(upper.impulses.size(), 1, "stack: hit_prop calls the node the hit names (same id 7 on both decks)")
	eq(lower.impulses.size(), 0, "stack: and not the lower deck's")
	eq(lower.asked, 0, "stack: a chord on the upper deck never asks the lower deck's props")
	await _cleanup([s[1], upper, lower, w])


func _stack_ring() -> void:
	var s := _stack_scene(Vector3(50, 0, 0), Vector3(50, 0, 0), true)
	var w: CombatWorld = s[0]
	var st: FakeStack = s[1]
	await frames(1)
	var p := Vector3(0, 23, -5)
	check(w.ring_at(p) == st.rings[0], "stack: ring_at a point on the upper deck is the upper deck's ring")
	check(w.ring_at(Vector3(0, 2, 0)) == st.rings[1], "stack: and on the lower deck the lower's")
	var surf := w.surface_below(p, w.up_at(p), 5.0)
	if check(not surf.is_empty(), "stack: surface_below finds the upper deck's floor without physics"):
		near(float((surf["point"] as Vector3).y), 20.0, 0.05, "stack: at y = 20")
	w.stack = null
	check(w.surface_below(p, Vector3.UP, 5.0).is_empty(), "no stack: the world's own ring (the lower deck) sees no floor 5 m below")
	await _cleanup([st, s[2], s[3], w])


## A real CityStack (seed 4) placed as the mission places it (entry deck through the origin): a shot across a prop on the
## lowest deck and a blast beside one on the top deck reach those decks' CityProps, and the same id on the other decks
## is left as it was.
func _real_stack() -> void:
	var stack := CityStack.new()
	add_child(stack)
	var sec := SectionPlan.make({"seed": 4.0})
	stack.build(sec)
	stack.position = -sec.deck_offset(int(sec.entry["deck"]))
	for d in stack.decks:
		d.props.set_physics_process(false)
	var w := CombatWorld.new()
	w.use_physics = false
	add_child(w)
	w.stack = stack
	await frames(1)
	var rec := {"shooter": "me", "peer": 1}
	var last := stack.decks.size() - 1
	var id := _standing_street_prop(stack.decks[last].props)
	if check(id >= 0, "real stack: the lowest deck has a street prop"):
		var d := stack.decks[last]
		var others := _states(stack, id, last)
		var xf := d.global_transform * d.props.transform_of(id)
		var hgt := float(CityPropSim.TYPES[d.props.items[id]["type"]]["height"])
		var mid := xf * Vector3(0, hgt * 0.5, 0)
		var side := xf.basis.x.normalized()
		var h := w.first_hit(mid + side * 2.0, mid - side * 2.0, 0.05, "me")
		if check(h.has("prop") and h["prop_node"] == d.props, "real stack: first_hit names the lowest deck's props (%s)" % str(h.get("prop_node"))):
			eq(int(h["prop"]), id, "real stack: on that prop")
			w.hit_prop(rec, {"knockback": 100.0}, h, -side)
			eq(d.props.state_of(id), CityProps.FALLING, "real stack: hit_prop topples it on its deck")
			_same_states(stack, id, others)
	var id0 := _standing_street_prop(stack.decks[0].props)
	if check(id0 >= 0, "real stack: the top deck has a street prop"):
		var d0 := stack.decks[0]
		var others0 := _states(stack, id0, 0)
		var bx := d0.global_transform * d0.props.transform_of(id0)
		w.splash(rec, {"splash_radius": 3.0, "prop_blast": 40.0}, bx * Vector3(0.8, 0.5, 0))
		eq(d0.props.state_of(id0), CityProps.FALLING, "real stack: a blast on the top deck topples its prop")
		_same_states(stack, id0, others0)
	w.free()
	stack.queue_free()
	await frames(1)


func _standing_street_prop(p: CityProps) -> int:
	for it: Dictionary in p.items:
		if not CityPropSim.is_roof(it) and p.state_of(int(it["id"])) == CityProps.STANDING:
			return int(it["id"])
	return -1


## Deck -> state of prop `id` on every deck but `skip` that has it.
func _states(stack: CityStack, id: int, skip: int) -> Dictionary:
	var out := {}
	for k in stack.decks.size():
		if k != skip and id < stack.decks[k].props.items.size():
			out[k] = stack.decks[k].props.state_of(id)
	return out


func _same_states(stack: CityStack, id: int, before: Dictionary) -> void:
	for k: int in before:
		eq(stack.decks[k].props.state_of(id), int(before[k]), "real stack: prop %d on deck %d left as it was" % [id, k])
