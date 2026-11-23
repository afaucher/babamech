extends TestCase
## The railgun slug punches through city props (docs/design/weapons.md §3.8, rail_slug.gd): on a real CityProps
## district, a slug fired along a row of five street trees / lamps topples every one of them (both kinds) and still hits
## a dummy behind them with its full damage; the same shot offset 1 m past the slug's reach leaves the row standing; a
## wall that stops the slug leaves the props behind it standing; a machine that doesn't decide the shot (another peer's
## record) knocks nothing, though its slug passes the props too and shows the debris; CombatWorld.props_on_segment lists
## the row nearest first; every prop kind is knockable by the slug (no kind it would pass by untouched). Then the same
## on a real CityStack (seed 4): a slug along a row on the lowest deck topples it and leaves the same ids on every other
## deck as they were.

const ROW := 5
const HEIGHT := 3.0      ## m above the props' feet the slug flies (over benches and bins beside the row)

var st: Dictionary


func setup() -> void:
	timeout_sec = 180.0
	st = MechCatalog.weapon("railgun")
	_every_kind_knockable()
	await _through_row()
	await _offset_misses()
	await _wall_stops()
	await _not_deciding()
	await _stack()
	finish()


func _every_kind_knockable() -> void:
	for type: String in CityPropSim.TYPES:
		check(float(CityPropSim.TYPES[type]["dv"]) <= float(st["knockback"]),
			"the slug's knockback (%.1f) topples a standing %s (threshold %.1f)" % [float(st["knockback"]), type,
			float(CityPropSim.TYPES[type]["dv"])])


func _props() -> CityProps:
	var plan := CityPlan.make({"seed": 3})
	var p := CityProps.new()
	p.setup(plan, RingFrame.new(plan.p("radius")))
	add_child(p)
	p.set_physics_process(false)
	return p


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 5
	w.use_physics = physics
	add_child(w)
	return w


## ROW consecutive standing street trees / lamps on one block edge along the axis (same arc s, 3..40 m apart in x: a row may cross a street), at
## least one of each kind, ordered by x; [] if the district has none.
static func row(p: CityProps) -> Array[int]:
	var by_s := {}
	for it: Dictionary in p.items:
		if CityPropSim.is_roof(it) or not (str(it["type"]) in ["tree", "lamp"]) or p.state_of(int(it["id"])) != CityProps.STANDING:
			continue
		var key := int(round(float(it["s"]) * 20.0))
		if not by_s.has(key):
			by_s[key] = []
		(by_s[key] as Array).append(it)
	for key: int in by_s:
		var arr: Array = by_s[key]
		arr.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["x"]) < float(y["x"]))
		for i in arr.size() - ROW + 1:
			var ok := true
			var types := {}
			for j in range(i, i + ROW):
				types[str(arr[j]["type"])] = true
				if j > i:
					var gap := float(arr[j]["x"]) - float(arr[j - 1]["x"])
					ok = ok and gap >= 3.0 and gap <= 40.0
			if ok and types.size() == 2:
				var ids: Array[int] = []
				for j in range(i, i + ROW):
					ids.append(int(arr[j]["id"]))
				return ids
	return []


static func foot(p: CityProps, id: int) -> Vector3:
	return (p.global_transform * p.transform_of(id)).origin


static func up_of(p: CityProps, id: int) -> Vector3:
	return (p.global_transform * p.transform_of(id)).basis.y.normalized()


## The shot along `ids`: [origin, aim, dir, up], `side` m sideways off the row, HEIGHT m above the feet, from 8 m before
## the first prop to 40 m past the last (also used by test_net_railgun_props).
static func line(p: CityProps, ids: Array[int], side: float = 0.0) -> Array:
	var a := foot(p, ids[0])
	var b := foot(p, ids[ids.size() - 1])
	var d := (b - a).normalized()
	var up := up_of(p, ids[0])
	var lat := d.cross(up).normalized() * side
	return [a - d * 8.0 + up * HEIGHT + lat, b + d * 40.0 + up * HEIGHT + lat, d, up]


func _line(p: CityProps, ids: Array[int], side: float = 0.0) -> Array:
	var ln := line(p, ids, side)
	for id in ids:
		var f := foot(p, id)
		var off := (f - foot(p, ids[0])) - (ln[2] as Vector3) * (f - foot(p, ids[0])).dot(ln[2])
		check(off.length() < 0.05, "prop %d stands on the row's line (%.3f m off)" % [id, off.length()])
	return ln


func _run(w: CombatWorld, seconds: float) -> void:
	for i in int(seconds * 60.0):
		w.advance(1.0 / 60.0)


func _states(p: CityProps, ids: Array) -> Array:
	return ids.map(func(id: int) -> int: return p.state_of(id))


func _through_row() -> void:
	var p := _props()
	var w := _world()
	await frames(1)
	var ids := row(p)
	if not check(ids.size() == ROW, "the district has a row of %d street trees and lamps (%s)" % [ROW, ids]):
		w.free()
		p.free()
		return
	var ln := _line(p, ids)
	var listed := w.props_on_segment(ln[0], ln[1], Combat.PROJECTILE_RADIUS)
	var listed_ids := listed.map(func(h: Dictionary) -> int: return int(h["prop"]))
	for id in ids:
		check(id in listed_ids, "props_on_segment lists prop %d on the line (%s)" % [id, listed_ids])
	var sorted := true
	for i in range(1, listed.size()):
		sorted = sorted and float(listed[i]["frac"]) >= float(listed[i - 1]["frac"])
		check(listed[i]["prop_node"] == p, "and names the props node")
	check(sorted, "nearest first")
	var dummy := TargetDummy.new()
	dummy.target_id = "behind"
	dummy.mass_class = "light"
	add_child(dummy)
	dummy.global_position = foot(p, ids[ROW - 1]) + (ln[2] as Vector3) * 15.0 + (ln[3] as Vector3) * (HEIGHT - 1.9)
	w.register(dummy)
	var hits: Array = []
	w.hit_landed.connect(func(_t: CombatTarget, h: Hit) -> void: hits.append(h))
	var fx := [0]
	w.child_entered_tree.connect(func(n: Node) -> void:
		if n is ImpactFx:
			fx[0] += 1)
	w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", ln[0], ln[1], w.now, 0))
	_run(w, 1.0)
	for id in ids:
		check(p.state_of(id) != CityProps.STANDING, "the slug topples the %s %d on its path" % [p.items[id]["type"], id])
		var lie := CityPropSim.dir_of(float(p.pose_of(id)["lie"]))
		check(lie.length() > 0.5, "prop %d has a fall direction" % id)
	if check(hits.size() == 1, "the slug still reaches the dummy behind the row (%d hits)" % hits.size()):
		near((hits[0] as Hit).damage, float(st["damage"]), 1e-4, "with its full damage (props take none of it)")
	check(fx[0] >= ROW + 1, "a debris burst at each prop plus the hit (%d)" % fx[0])
	w.free()
	dummy.free()
	p.free()
	await frames(1)


func _offset_misses() -> void:
	var p := _props()
	var w := _world()
	await frames(1)
	var ids := row(p)
	if ids.size() == ROW:
		var reach := Combat.PROJECTILE_RADIUS + float(CityPropSim.TYPES["tree"]["radius"])
		var ln := _line(p, ids, reach + 1.0)
		w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", ln[0], ln[1], w.now, 0))
		_run(w, 1.0)
		for id in ids:
			eq(p.state_of(id), CityProps.STANDING, "a slug passing 1 m beyond its reach leaves %s %d standing" % [p.items[id]["type"], id])
	w.free()
	p.free()
	await frames(1)


func _wall_stops() -> void:
	var p := _props()
	var w := _world(true)
	var ids := row(p)
	if ids.size() != ROW:
		w.free()
		p.free()
		return
	var ln := _line(p, ids)
	var d: Vector3 = ln[2]
	var up: Vector3 = ln[3]
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 10, 0.5)
	cs.shape = box
	wall.add_child(cs)
	add_child(wall)
	var mid := (foot(p, ids[1]) + foot(p, ids[2])) * 0.5 + up * HEIGHT
	wall.global_transform = Transform3D(Basis.looking_at(d, up), mid)
	await frames(3)
	var slug := w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", ln[0], ln[1], w.now, 0)) as RailSlug
	_run(w, 1.0)
	check(slug.end_time >= 0.0, "the wall stops the slug")
	for i in ROW:
		if i < 2:
			check(p.state_of(ids[i]) != CityProps.STANDING, "prop %d before the wall topples" % ids[i])
		else:
			eq(p.state_of(ids[i]), CityProps.STANDING, "prop %d behind the wall stays standing" % ids[i])
	w.free()
	wall.free()
	p.free()
	await frames(1)


func _not_deciding() -> void:
	var p := _props()
	var w := _world()
	await frames(1)
	var ids := row(p)
	if ids.size() == ROW:
		var ln := _line(p, ids)
		var fx := [0]
		w.child_entered_tree.connect(func(n: Node) -> void:
			if n is ImpactFx:
				fx[0] += 1)
		var slug := w.fire(Combat.fire_record("other", 2, "shoulder_l", "railgun", ln[0], ln[1], w.now, 0)) as RailSlug
		_run(w, 1.0)
		for id in ids:
			eq(p.state_of(id), CityProps.STANDING, "another machine's slug knocks nothing here (%d)" % id)
		var past := (foot(p, ids[ROW - 1]) - (ln[0] as Vector3)).length()
		check(slug.end_time < 0.0 or slug.flight_dist(slug.end_time) > past, "but it still flies past the props")
		check(fx[0] >= ROW, "and shows the debris at each (%d)" % fx[0])
	w.free()
	p.free()
	await frames(1)


func _stack() -> void:
	var stack := CityStack.new()
	add_child(stack)
	var sec := SectionPlan.make({"seed": 4.0})
	stack.build(sec)
	stack.position = -sec.deck_offset(int(sec.entry["deck"]))
	for d in stack.decks:
		d.props.set_physics_process(false)
	var w := _world()
	w.stack = stack
	await frames(1)
	var last := stack.decks.size() - 1
	var p: CityProps = stack.decks[last].props
	var ids := row(p)
	if check(ids.size() == ROW, "stack: the lowest deck has a row (%s)" % [ids]):
		var others := {}
		for k in last:
			others[k] = _states(stack.decks[k].props, ids.filter(func(id: int) -> bool: return id < stack.decks[k].props.items.size()))
		var ln := _line(p, ids)
		eq(w.deck_span(ln[0], ln[1], Combat.PROJECTILE_RADIUS), Vector2i(last, last), "stack: the slug's path spans only the lowest deck")
		w.fire(Combat.fire_record("me", 1, "shoulder_l", "railgun", ln[0], ln[1], w.now, 0))
		_run(w, 1.0)
		for id in ids:
			check(p.state_of(id) != CityProps.STANDING, "stack: the slug topples prop %d on the lowest deck" % id)
		for k: int in others:
			var kp: CityProps = stack.decks[k].props
			eq(_states(kp, ids.filter(func(id: int) -> bool: return id < kp.items.size())), others[k], "stack: deck %d's props with those ids left as they were" % k)
	w.free()
	stack.queue_free()
	await frames(1)
