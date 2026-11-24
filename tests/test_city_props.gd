extends TestCase
## The street props (scripts/world/city/city_props.gd, city_prop_sim.gd; docs/design/city-props.md): the layout is
## deterministic and checksummed, a topple ends down at the predicted pose, the same events on two managers give the same
## snapshot, a shove is short (shorter for heavier props) and stops at a wall, snapshots round-trip, a pusher driven down
## a sidewalk flattens its row and a pusher on a roof touches nothing. Roof units (docs/design/city-rooftops.md) stand
## flush on their roofs, topple and slide without leaving them, are reached by a pusher on the roof but not by one in the
## street below, and take shots and blasts. Time is driven with advance_to(), not frames.

const SMALL := {"seed": 3, "size_x": 100.0, "size_s": 110.0}

var plan: CityPlan
var ring: RingFrame


func setup() -> void:
	plan = CityPlan.make(SMALL)
	ring = RingFrame.new(plan.p("radius"))
	_layout()
	_topple()
	_two_managers()
	_shove()
	_snapshot()
	_weapons()
	_pusher()
	_decks()
	_tree_tint()
	await _grid_matches_brute_force()
	await _roof()
	finish()


## The pusher's grid query (push_candidates) knocks exactly what the old loop over every prop knocked, tick by tick: a
## scripted mech walks the furnishing bands of several blocks and back (topples, then shoves), crosses a roof with roof
## units, and (on a stack deck) walks the deck above: stand-alone seeds 1-3 and deck 1 of a section.
func _grid_matches_brute_force() -> void:
	for seed_: int in [1, 2, 3]:
		var d := CityDistrict.new()
		d.with_rig = false
		add_child(d)
		d.build({"seed": seed_, "size_x": 140.0, "size_s": 150.0})
		_compare_push(d, null, "seed %d" % seed_)
		d.queue_free()
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 2}))
	_compare_push(stack.decks[1], stack.decks[0], "stack deck 1")
	stack.queue_free()
	await frames(1)


func _compare_push(d: CityDistrict, above: CityDistrict, what: String) -> void:
	var grid := d.props
	grid.set_physics_process(false)
	var brute := CityProps.new()
	brute.deck = grid.deck
	brute.brute_force = true
	brute.setup(d.plan, d.ring)
	d.add_child(brute)
	brute.set_physics_process(false)
	var body := CharacterBody3D.new()
	add_child(body)
	grid.add_pusher(body, 2.2)
	brute.add_pusher(body, 2.2)
	# The path in this deck's arc coordinates (x, s, h) or world points (Vector3 in a 1-element array: another deck).
	var path: Array = []
	var nb := mini(d.plan.blocks.size(), 6 if above == null else 3)
	for bi in nb:
		var r: Rect2 = d.plan.blocks[bi]["rect"]
		var x := r.position.x + 1.2
		path.append(Vector3(x, r.position.y - 4.0, CityPlan.CURB_H))
		path.append(Vector3(x, r.end.y + 4.0, CityPlan.CURB_H))
		path.append(Vector3(x + 0.6, r.position.y - 4.0, CityPlan.CURB_H))   # back along it: shoves what lies there
	var roof := -1
	for it: Dictionary in grid.items:
		if CityPropSim.is_roof(it) and roof < 0:
			roof = int(it["id"])
	var points: Array[Vector3] = []
	for q: Vector3 in path:
		points.append(d.to_global(d.ring.arc_to_world(q.x, q.y, q.z)))
	if roof >= 0:
		var it: Dictionary = grid.items[roof]
		var bxf := d.building_frame(int(it["building"]))
		points.append(d.to_global(bxf * Vector3(float(it["lx"]) - 8.0, float(it["ly"]), float(it["lz"]))))
		points.append(d.to_global(bxf * Vector3(float(it["lx"]) + 8.0, float(it["ly"]), float(it["lz"]))))
	var upper_from := points.size()
	if above != null:     # the deck above, right over this deck's first block: nothing here may react
		var r0: Rect2 = d.plan.blocks[0]["rect"]
		var s_up := r0.position.y * above.plan.section.radius_of(above.plan.deck) / d.plan.section.radius_of(d.plan.deck)
		points.append(above.to_global(above.ring.arc_to_world(r0.position.x + 1.2, s_up, CityPlan.CURB_H)))
		points.append(above.to_global(above.ring.arc_to_world(r0.position.x + 1.2, s_up + 60.0, CityPlan.CURB_H)))
	var dt := 1.0 / 60.0
	var speed := 12.0       # walk speed
	var ticks := 0
	var differ := 0
	var before_upper := PackedByteArray()
	var asked_before := 0
	for i in points.size() - 1:
		if i == upper_from:
			before_upper = grid.snapshot()
			asked_before = grid._asked.size()
		var a := points[i]
		var b := points[i + 1]
		var n := maxi(int(ceil(a.distance_to(b) / (speed * dt))), 1)
		for k in n:
			var at := a.lerp(b, float(k) / float(n))
			body.global_position = at
			body.velocity = (b - a) / (float(n) * dt)
			grid.step(dt)
			brute.step(dt)
			ticks += 1
			# Same requests this tick (ids and times); the whole snapshot every 20 ticks.
			if grid._asked != brute._asked or (ticks % 20 == 0 and grid.snapshot() != brute.snapshot()):
				differ += 1
	if grid.snapshot() != brute.snapshot():
		differ += 1
	if above != null:
		check(grid.snapshot() == before_upper and grid._asked.size() == asked_before, "%s: a mech walking the deck above touches nothing here" % what)
	var knocked := grid.snapshot().size()
	print("%s: %d ticks, %d props moved, %d asked" % [what, ticks, grid._ev.size(), grid._asked.size()])
	eq(differ, 0, "%s: the grid query knocks the same props at the same tick as the loop over every prop (%d ticks)" % [what, ticks])
	check(grid._ev.size() >= 3 and knocked > 4, "%s: the path knocks props over (%d)" % [what, grid._ev.size()])
	if roof >= 0:
		check(grid._ev.has(roof), "%s: including the roof unit" % what)
	body.queue_free()
	brute.queue_free()


## Stack decks: every deck's props hear every prop event; only the deck named in it acts (a missing deck is -1, a
## district on its own). Prop ids repeat across decks, so without this a knock on deck 1 would knock deck 0 too.
func _decks() -> void:
	var d0 := _props()
	var d1 := _props()
	var alone := _props()
	d0.deck = 0
	d1.deck = 1
	var id := _first(d0, "lamp")
	var ev := {"id": id, "kind": CityProps.TOPPLE, "dir": Vector2(1, 0), "t0": d0.now, "deck": 1}
	for p: CityProps in [d0, d1, alone]:
		p.receive("prop.ev", ev, false, true)
	eq(d1.state_of(id), CityProps.FALLING, "decks: a prop.ev for deck 1 topples deck 1's prop")
	eq(d0.state_of(id), CityProps.STANDING, "decks: and not deck 0's prop with the same id")
	eq(alone.state_of(id), CityProps.STANDING, "decks: nor a stand-alone district's")
	var old := ev.duplicate()
	old.erase("deck")
	var id2 := _first(d0, "tree")
	old["id"] = id2
	for p: CityProps in [d0, d1, alone]:
		p.receive("prop.ev", old, false, true)
	eq(alone.state_of(id2), CityProps.FALLING, "decks: an event with no deck is for a stand-alone district (as before)")
	check(d0.state_of(id2) == CityProps.STANDING and d1.state_of(id2) == CityProps.STANDING, "decks: and for no stack deck")
	# Host: a request for deck 1 is decided by deck 1 only.
	var id3 := _first(d0, "bench")
	if id3 < 0:
		id3 = id2 + 1
	for p: CityProps in [d0, d1]:
		p.receive("prop.req", {"id": id3, "kind": CityProps.TOPPLE, "dir": Vector2(0, 1), "v0": 0.0, "deck": 1}, true, false)
	check(d1.state_of(id3) != CityProps.STANDING and d0.state_of(id3) == CityProps.STANDING, "decks: the host decides deck 1's request on deck 1 only")
	# Sync: deck 1's snapshot restores into deck 1 only.
	var snap := d1.snapshot()
	check(snap.size() > 4, "decks: deck 1 has props down")
	var fresh1 := _props()
	fresh1.deck = 1
	var before0 := d0.snapshot()
	for p: CityProps in [d0, fresh1]:
		p.receive("prop.sync", {"bytes": snap, "deck": 1}, false, true)
	eq(fresh1.snapshot(), snap, "decks: deck 1's sync restores deck 1")
	eq(d0.snapshot(), before0, "decks: and leaves deck 0 as it was")
	check(d1.for_me({"deck": 1}) and not d0.for_me({"deck": 1}) and alone.for_me({}), "decks: for_me")
	for p: CityProps in [d0, d1, alone, fresh1]:
		p.queue_free()


func _props() -> CityProps:
	var p := CityProps.new()
	p.setup(plan, ring)
	add_child(p)
	p.set_physics_process(false)
	return p


## Tree colour jitter (CityPalette.tree_tint, docs/design/city-variety.md "Tree colour"): trees of one district differ in
## foliage colour, a tree keeps its tint across two builds and through a topple (standing / falling / down / shoved), every
## tinted leaf green stays within the documented ranges (and in the green family), trunks barely move, untinted props
## keep plain drawing, and the layout (checksum) and triangle count are what they were.
func _tree_tint() -> void:
	var before := CityProps.layout_checksum(CityProps.layout(plan))
	var a := _props()
	var b := _props()
	eq(CityProps.layout_checksum(a.items), before, "tree tint: the layout checksum is unchanged")
	eq(a.tri_count(), b.tri_count(), "tree tint: same triangles from two builds")
	var trees: Array[int] = []
	for it: Dictionary in a.items:
		if it["type"] == "tree":
			trees.append(int(it["id"]))
	check(trees.size() >= 4, "tree tint: the district has trees (%d)" % trees.size())
	var shades := {}
	var leaves := [CityPalette.C["leaf_dark"], CityPalette.C["leaf"], CityPalette.C["leaf_light"]]
	var trunk: Color = CityPalette.C["trunk"]
	check(not CityPalette.is_leaf(trunk) and not CityPalette.is_leaf(CityPalette.C["cream_light"]), "tree tint: trunk and planter box are not leaf")
	var worst := Vector3.ZERO
	for id in trees:
		var m := a.tint_of(id)
		eq(m, b.tint_of(id), "tree tint: tree %d has the same tint in two builds" % id)
		eq(m, CityProps.tree_tint(plan.cosmetic_seed(), id), "tree tint: tree %d drawn with its own tint" % id)
		shades[m.to_html()] = true
		for base: Color in leaves:
			check(CityPalette.is_leaf(base), "tree tint: leaf green %s is leaf" % base.to_html())
			var c := CityPalette.tree_shade(base, m)
			var dh := absf(wrapf(c.h - base.h, -0.5, 0.5))
			var ds := absf(c.s / base.s - 1.0)
			var dv := absf(c.v / base.v - 1.0)
			worst = Vector3(maxf(worst.x, dh), maxf(worst.y, ds), maxf(worst.z, dv))
			# One multiplier for all greens: the documented ranges hold for "leaf" exactly, the others within 25 %.
			check(dh <= CityPalette.TREE_HUE * 1.25 + 1e-4 and ds <= CityPalette.TREE_SAT * 1.25 + 0.01
					and dv <= CityPalette.TREE_VAL * 1.25 + 1e-4, "tree tint: tree %d %s within range (dh %.3f ds %.3f dv %.3f)" % [id, base.to_html(), dh, ds, dv])
			check(c.h > 0.2 and c.h < 0.42 and CityPalette.is_leaf(c), "tree tint: tree %d stays green (hue %.3f)" % [id, c.h])
		var tc := CityPalette.tree_shade(trunk, m)
		check(absf(tc.v / trunk.v - 1.0) <= CityPalette.TREE_TRUNK_VAL + 1e-4 and absf(tc.h - trunk.h) < 1e-3, "tree tint: trunk %d barely moves" % id)
	print("tree tint: %d trees, %d shades, worst dh %.3f ds %.3f dv %.3f" % [trees.size(), shades.size(), worst.x, worst.y, worst.z])
	check(shades.size() >= trees.size() * 3 / 4,"tree tint: trees differ in foliage colour (%d shades for %d trees)" % [shades.size(), trees.size()])
	check(a.tint_of(trees[0]) != a.tint_of(trees[1]), "tree tint: two trees of one district differ")
	# Through every state of one tree: the same instance, the same tint.
	var id0 := trees[0]
	var m0 := a.tint_of(id0)
	a.request(id0, CityProps.TOPPLE, Vector2(1, 0))
	a.advance_to(0.4)
	eq(a.state_of(id0), CityProps.FALLING, "tree tint: falling")
	eq(a.tint_of(id0), m0, "tree tint: the falling tree keeps its tint")
	a.advance_to(5.0)
	eq(a.state_of(id0), CityProps.DOWN, "tree tint: down")
	eq(a.tint_of(id0), m0, "tree tint: the fallen tree keeps its tint")
	a.request(id0, CityProps.SHOVE, Vector2(0, 1), 6.0)
	a.advance_to(5.1)
	eq(a.tint_of(id0), m0, "tree tint: the shoved tree keeps its tint")
	a.restore(a.snapshot())
	eq(a.tint_of(id0), m0, "tree tint: after a snapshot round trip")
	var lamp := _first(a, "lamp")
	eq(a.tint_of(lamp), Color(1, 1, 1, 1), "tree tint: a lamp is not tinted")
	a.queue_free()
	b.queue_free()


func _first(p: CityProps, type: String) -> int:
	for it: Dictionary in p.items:
		if it["type"] == type:
			return int(it["id"])
	return -1


func _layout() -> void:
	var a := CityProps.layout(plan)
	var b := CityProps.layout(CityPlan.make(SMALL))
	eq(CityProps.layout_checksum(a), CityProps.layout_checksum(b), "same plan, same layout checksum")
	check(CityProps.layout_checksum(a) != CityProps.layout_checksum(CityProps.layout(CityPlan.make({"seed": 4, "size_x": 100.0, "size_s": 110.0}))),
			"another seed, another layout")
	var counts := {}
	for i in a.size():
		eq(int(a[i]["id"]), i, "ids are layout indices")
		counts[a[i]["type"]] = int(counts.get(a[i]["type"], 0)) + 1
	print("props: %d %s" % [a.size(), str(counts)])
	for t: String in CityPropSim.TYPE_ORDER:
		if not CityPropSim.ROOF_TYPES.has(t):      # roof units: seed 1 in _roof (this small district has few roofs)
			check(int(counts.get(t, 0)) > 0, "the layout has %s props" % t)
	eq(int(counts.get("sign", 0)), plan.blocks.size() * 4, "a sign post per block edge")
	# Nothing stands in a building, and the pits sit under the street trees.
	for it: Dictionary in a:
		if CityPropSim.is_roof(it):
			continue      # roof units stand on buildings (tested in _roof and test_city)
		for bld: Dictionary in plan.buildings:
			var r := Rect2((bld["center"] as Vector2) - (bld["size"] as Vector2) * 0.5, bld["size"])
			check(not r.has_point(Vector2(it["x"], it["s"])), "prop %d (%s) stands inside a building" % [it["id"], it["type"]])
		if it["pit"]:
			eq(it["type"], "tree", "only trees have pits")


func _topple() -> void:
	var p := _props()
	var id := _first(p, "lamp")
	var it: Dictionary = p.items[id]
	eq(p.state_of(id), CityProps.STANDING, "a prop starts standing")
	p.request(id, CityProps.TOPPLE, Vector2(1, 0))
	eq(p.state_of(id), CityProps.FALLING, "a topple request offline is decided at once")
	p.advance_to(0.4)
	var mid := p.pose_of(id)
	check(float(mid["tilt"]) > 0.05 and float(mid["tilt"]) < PI * 0.5, "half way through the fall it leans (%.2f rad)" % mid["tilt"])
	p.advance_to(0.8 + 0.25 + 0.01)
	eq(p.state_of(id), CityProps.DOWN, "after the fall and the bounce it is down")
	var rest := p.pose_of(id)
	near(rest["x"], float(it["x"]) + 0.3, 1e-4, "the base ends 0.3 m along the push")
	near(rest["s"], float(it["s"]), 1e-4, "and not sideways")
	near(rest["tilt"], PI * 0.5, 1e-4, "a lamp lies flat")
	near(rest["lie"], PI * 0.5, 1e-4, "along +x")
	near(rest["h"], CityPlan.CURB_H, 1e-4, "on the sidewalk")
	var tip := p.transform_of(id) * Vector3(0, 6.5, 0)
	var tip_arc := ring.world_to_arc(tip)
	check(tip_arc.x > float(it["x"]) + 6.0 and absf(tip_arc.z - CityPlan.CURB_H) < 0.5, "its top lies on the ground along +x (%s)" % tip_arc)
	p.request(id, CityProps.TOPPLE, Vector2(0, 1))
	eq(p.state_of(id), CityProps.DOWN, "a fallen prop does not topple again")
	var tree := _first(p, "tree")
	p.request(tree, CityProps.TOPPLE, Vector2(0, -1))
	p.advance_to(5.0)
	near(p.pose_of(tree)["tilt"], deg_to_rad(78.0), 1e-4, "a tree rests on its canopy at 78 deg")
	p.queue_free()


func _events() -> Array:
	var a := CityProps.layout(plan)
	var ids := []
	for it: Dictionary in a:
		if it["type"] in ["lamp", "bin", "bench"] and ids.size() < 3:
			ids.append(int(it["id"]))
	return [
		{"id": ids[0], "kind": CityPropSim.TOPPLE, "dir": Vector2(0.6, 0.8), "t0": 1.0},
		{"id": ids[1], "kind": CityPropSim.TOPPLE, "dir": Vector2(-1, 0), "t0": 1.5},
		{"id": ids[2], "kind": CityPropSim.TOPPLE, "dir": Vector2(0, 1), "t0": 9.0},
	]


func _two_managers() -> void:
	var a := _props()
	var b := _props()
	for ev: Dictionary in _events():
		a.apply_event(ev)
	b.advance_to(20.0)      # b gets them late: they fast-forward
	for ev: Dictionary in _events():
		b.apply_event(ev)
	a.advance_to(20.0)
	eq(a.snapshot().hex_encode(), b.snapshot().hex_encode(), "the same events on two managers give the same snapshot")
	a.advance_to(9.3)
	b.advance_to(9.3)
	eq(a.state_of(_events()[2]["id"]), CityProps.FALLING, "mid-fall at 9.3")
	eq(a.snapshot().hex_encode(), b.snapshot().hex_encode(), "a moving prop is written at its rest pose")
	a.queue_free()
	b.queue_free()


func _shove() -> void:
	var p := _props()
	var lamp := _first(p, "lamp")
	var tree := _first(p, "tree")
	var bin := _first(p, "bin")
	var t := 0.0
	var moved := {}
	for id: int in [lamp, tree, bin]:
		p.request(id, CityProps.TOPPLE, Vector2(1, 0))
		t += 3.0
		p.advance_to(t)
		var before := p.pose_of(id)
		# A way with nothing in it for 2 m, so only the cap and the mass decide the distance.
		var along := Vector2(0, 1)
		for d: Vector2 in [Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0)]:
			if CityPropSim.slide_length(plan, Vector2(before["x"], before["s"]), d, 2.0, 1.0) >= 2.0:
				along = d
				break
		p.request(id, CityProps.SHOVE, along, 10.0)
		eq(p.state_of(id), CityProps.SLIDING, "%s: a fallen prop slides when shoved" % p.items[id]["type"])
		t += 3.0
		p.advance_to(t)
		eq(p.state_of(id), CityProps.DOWN, "and comes to rest")
		var after := p.pose_of(id)
		moved[id] = Vector2(after["x"], after["s"]).distance_to(Vector2(before["x"], before["s"]))
		var turn := absf(wrapf(float(after["lie"]) - float(before["lie"]), -PI, PI))
		check(turn <= deg_to_rad(20.0) + 1e-4, "it turns at most 20 deg (%.1f)" % rad_to_deg(turn))
	print("shove 10 m/s: lamp %.2f m, tree %.2f m, bin %.2f m" % [moved[lamp], moved[tree], moved[bin]])
	check(float(moved[lamp]) <= 4.0 * 4.0 / 12.0 + 1e-3 and float(moved[lamp]) > 1.0, "a shove is short: capped at 1.33 m (%.2f)" % moved[lamp])
	check(float(moved[tree]) < float(moved[lamp]) * 0.5, "a tree goes less far than a lamp")
	check(float(moved[bin]) >= float(moved[lamp]) - 1e-3, "a bin goes at least as far")
	# A wall stops the slide: start 0.5 m (plus the radius) short of a building, push into it.
	var bld: Dictionary = plan.buildings[0]
	var c: Vector2 = bld["center"]
	var size: Vector2 = bld["size"]
	var from := Vector2(c.x - size.x * 0.5 - 0.3 - 0.5, c.y)
	near(CityPropSim.slide_length(plan, from, Vector2(1, 0), 1.3, 0.3), 0.5, 1e-3, "the slide stops at the building's wall")
	near(CityPropSim.slide_length(plan, from, Vector2(-1, 0), 1.3, 0.3), 1.3, 1e-3, "and runs its course away from it")
	var edge := Vector2(plan.extent.end.x - 0.3 - 0.2, 0.0)
	near(CityPropSim.slide_length(plan, edge, Vector2(1, 0), 1.3, 0.3), 0.2, 1e-3, "and at the map's edge")
	p.queue_free()


func _snapshot() -> void:
	var a := _props()
	for ev: Dictionary in _events():
		a.apply_event(ev)
	a.advance_to(12.0)
	var id: int = _events()[0]["id"]
	a.request(id, CityProps.SHOVE, Vector2(0, 1), 3.0)
	var bytes := a.snapshot()
	var b := _props()
	b.restore(bytes)
	eq(b.snapshot().hex_encode(), bytes.hex_encode(), "a restored snapshot snapshots the same")
	a.advance_to(30.0)
	for ev: Dictionary in _events():
		var k: int = ev["id"]
		eq(b.state_of(k), CityProps.DOWN, "restored props are down")
		near(b.pose_of(k)["x"], a.pose_of(k)["x"], 1e-4, "at the same x")
		near(b.pose_of(k)["s"], a.pose_of(k)["s"], 1e-4, "and s")
		near(b.pose_of(k)["lie"], a.pose_of(k)["lie"], 1e-4, "lying the same way")
	b.restore(PackedByteArray())
	eq(b.state_of(id), CityProps.STANDING, "an empty snapshot stands everything up")
	eq(b.snapshot().size(), 4, "and snapshots as empty")
	a.queue_free()
	b.queue_free()


func _weapons() -> void:
	var p := _props()
	var id := _first(p, "lamp")
	var it: Dictionary = p.items[id]
	var at := ring.arc_to_world(it["x"], it["s"], 2.0)
	var side := ring.arc_to_world(float(it["x"]) - 3.0, it["s"], 2.0)
	var hit := p.first_hit(side, at + (at - side), 0.1)
	check(not hit.is_empty() and int(hit.get("id", -1)) == id, "a shot along the street stops on the lamp (%s)" % str(hit))
	if not hit.is_empty():
		check(float(hit["frac"]) > 0.4 and float(hit["frac"]) < 0.5, "at its near side (frac %.3f)" % hit["frac"])
	p.apply_impulse(id, Vector3(1.0, 0, 0), "test")
	eq(p.state_of(id), CityProps.STANDING, "a knock under the threshold leaves it standing")
	p.apply_impulse(id, Vector3(2.5, 0, 0), "test")
	eq(p.state_of(id), CityProps.FALLING, "a knock at the threshold topples it")
	p.advance_to(3.0)
	near(p.pose_of(id)["lie"], PI * 0.5, 1e-3, "away from the shot")
	var bin := _first(p, "bin")
	var b: Dictionary = p.items[bin]
	p.blast(ring.arc_to_world(float(b["x"]) + 1.0, b["s"], 0.5), 6.0, 5.0, "test")
	eq(p.state_of(bin), CityProps.FALLING, "a blast nearby topples a bin")
	p.advance_to(6.0)
	check(float(p.pose_of(bin)["x"]) < float(b["x"]), "away from the blast")
	p.queue_free()


## A pusher driven down the furnishing band of the first block's -x edge at a mech's walk.
func _drive(p: CityProps, h: float) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	add_child(body)
	p.add_pusher(body, 1.4)
	var r: Rect2 = plan.blocks[0]["rect"]
	var x := r.position.x + 1.0
	var s := r.position.y - 3.0
	var dt := 1.0 / 60.0
	while s < r.end.y + 3.0:
		var pos := ring.arc_to_world(x, s, h)
		body.global_position = pos
		body.velocity = ring.tangent_at(pos) * 12.0
		p.step(dt)
		s += 12.0 * dt
	return body


func _row(p: CityProps) -> Array:
	var r: Rect2 = plan.blocks[0]["rect"]
	var out := []
	for it: Dictionary in p.items:
		if absf(float(it["x"]) - (r.position.x + 0.95)) < 0.01 and float(it["s"]) > r.position.y and float(it["s"]) < r.end.y:
			out.append(int(it["id"]))
	return out


func _pusher() -> void:
	var p := _props()
	var row := _row(p)
	check(row.size() >= 3, "the first block's -x edge has a row of trees and lamps (%d)" % row.size())
	var body := _drive(p, CityPlan.CURB_H)
	for id: int in row:
		check(p.state_of(id) != CityProps.STANDING, "the pusher toppled %s %d" % [p.items[id]["type"], id])
	p.advance_to(p.now + 5.0)
	for id: int in row:
		check(float(p.pose_of(id)["s"]) > float(p.items[id]["s"]), "%d fell along the pusher's way" % id)
	body.queue_free()
	p.queue_free()
	var q := _props()
	var roof := _drive(q, 12.0)
	for id: int in _row(q):
		eq(q.state_of(id), CityProps.STANDING, "a pusher on a roof leaves %d standing" % id)
	roof.queue_free()
	q.queue_free()


# --- Roof units ------------------------------------------------------------------------------------------

## Re-captured 2026-11-23 (city variety: alley bins, road-form furniture; alleys + road forms on by default). Was
## 7e78d4e1e3db1a61 (still the layout with alleys 0, road_variety 0).
const GOLDEN_LAYOUT := "f321076ebd6e98f1"     ## CityProps.layout_checksum of the seed 1 plan (golden: changes it everywhere)


func _roof() -> void:
	var p1 := CityPlan.make({"seed": 1})
	eq(CityProps.layout_checksum(CityProps.layout(p1)), GOLDEN_LAYOUT, "the seed 1 props layout checksum (golden)")
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": 1})
	var p := d.props
	p.set_physics_process(false)
	var counts := {}
	var street_ids := 0
	for it: Dictionary in p.items:
		if not CityPropSim.is_roof(it):
			street_ids += 1
			check(street_ids - 1 == int(it["id"]), "street props come first, their ids unchanged")
			continue
		counts[it["type"]] = int(counts.get(it["type"], 0)) + 1
		# Flush on the flat roof: the base is the spot in the building's frame, on the curved deck.
		var bxf := d.building_frame(int(it["building"]))
		var want := bxf * Vector3(it["lx"], it["ly"], it["lz"])
		var got := p.transform_of(int(it["id"])).origin
		check(got.distance_to(want) < 0.02, "roof prop %d sits flush on its roof (%.3f m off)" % [it["id"], got.distance_to(want)])
		var up := (p.transform_of(int(it["id"])).basis.y).normalized()
		check(up.dot((bxf.basis.y).normalized()) > 0.9999, "roof prop %d stands upright to its roof" % it["id"])
	print("roof props: %s" % str(counts))
	for t: String in CityPropSim.ROOF_TYPES:
		check(int(counts.get(t, 0)) > 0, "seed 1 has %s roof props" % t)
	# Topple and shove one hard toward the roof's edge, again and again: it keeps the roof's height and stays inside.
	var tank := _roof_first(p, "ac")
	var it: Dictionary = p.items[tank]
	var bi := int(it["building"])
	var ti := int(it["tier"])
	var area := d.plan.roof_rect(bi, ti)
	var radius := float(CityPropSim.TYPES["ac"]["radius"])
	var t := 1.0
	var stop := 0.0
	p.advance_to(t)
	p.request(tank, CityProps.TOPPLE, Vector2(1, 0))
	for k in 30:
		t += 3.0
		p.advance_to(t)
		var pose := p.pose_of(tank)
		near(float(pose["h"]), float(it["h"]), 1e-4, "a roof prop keeps its roof's height (%d)" % k)
		var lp: Vector3 = d.building_frame(bi).affine_inverse() * p.transform_of(tank).origin
		near(lp.y, float(it["ly"]), 0.02, "and lies on the roof, not in the street (%d)" % k)
		check(area.grow(-radius + 0.01).has_point(Vector2(pose["x"], pose["s"])), "and stays inside its tier (%d)" % k)
		if k == 0:
			stop = float(pose["x"]) + CityPropSim.slide_in(area, d.plan.roof_blockers(bi, ti), Vector2(pose["x"], pose["s"]), Vector2(1, 0), 1000.0, radius)
		p.request(tank, CityProps.SHOVE, Vector2(1, 0), 40.0)
	var last := p.pose_of(tank)
	near(float(last["x"]), stop, 0.05, "shoved again and again it stops at the roof's edge or what stands on it (edge at %.2f)" % (area.end.x - radius))
	# A light vent on a 6.5 m shop roof: a pusher in the street right under it leaves it, one on the roof topples it.
	var vent := -1
	for q: Dictionary in p.items:
		if CityPropSim.is_roof(q) and q["type"] == "vent" and d.plan.buildings[int(q["building"])]["style"] == "shops":
			vent = int(q["id"])
			break
	if check(vent >= 0, "seed 1 has a vent on a shop roof"):
		var v: Dictionary = p.items[vent]
		var vb := d.building_frame(int(v["building"]))
		var body := CharacterBody3D.new()
		add_child(body)
		p.add_pusher(body, 2.2)
		var street := d.ring.arc_to_world(v["x"], v["s"], CityPlan.CURB_H)
		body.global_position = street
		body.velocity = vb.basis.x * 6.0
		p.step(0.02)
		eq(p.state_of(vent), CityProps.STANDING, "a mech in the street under a 6.5 m shop does not reach its roof props")
		body.global_position = vb * Vector3(float(v["lx"]) - 1.0, float(v["ly"]), float(v["lz"]))
		p.step(0.3)
		check(p.state_of(vent) != CityProps.STANDING, "a mech on the roof topples them")
		p.advance_to(p.now + 3.0)
		near(float(p.pose_of(vent)["x"]), float(v["lx"]) + CityPropSim.BASE_SLIP, 0.02, "away from it, along the roof (+x)")
		body.queue_free()
	# Weapons: a shot across a roof unit stops on it, a blast topples one.
	var ac := _roof_first(p, "water_tank")
	var a: Dictionary = p.items[ac]
	var axf := d.building_frame(int(a["building"]))
	var mid := axf * Vector3(float(a["lx"]), float(a["ly"]) + 2.5, float(a["lz"]))
	var hit := p.first_hit(mid + axf.basis.z * 5.0, mid - axf.basis.z * 5.0, 0.1)
	check(not hit.is_empty() and int(hit["id"]) == ac, "a shot across a roof water tank stops on it (%s)" % str(hit))
	var planter := _roof_first(p, "planter")
	var pl: Dictionary = p.items[planter]
	var pxf := d.building_frame(int(pl["building"]))
	p.blast(pxf * Vector3(float(pl["lx"]) + 1.5, float(pl["ly"]) + 0.5, float(pl["lz"])), 4.0, 30.0, "test")
	eq(p.state_of(planter), CityProps.FALLING, "a blast on a roof topples a planter")
	p.advance_to(p.now + 3.0)
	check(float(p.pose_of(planter)["x"]) < float(pl["lx"]), "away from the blast")
	near(float(p.pose_of(planter)["h"]), float(pl["h"]), 1e-4, "and it stays on its roof")
	# A snapshot round-trips roof poses (roof-local x / s on the same wire).
	var q2 := CityProps.new()
	q2.setup(d.plan, d.ring)
	add_child(q2)
	q2.set_physics_process(false)
	q2.restore(p.snapshot())
	eq(q2.snapshot().hex_encode(), p.snapshot().hex_encode(), "a snapshot with roof props restores the same")
	check(q2.transform_of(tank).origin.distance_to(p.transform_of(tank).origin) < 1e-3, "the restored tank lies where it lay")
	q2.queue_free()
	d.queue_free()
	await frames(1)


func _roof_first(p: CityProps, type: String) -> int:
	for it: Dictionary in p.items:
		if CityPropSim.is_roof(it) and it["type"] == type:
			return int(it["id"])
	return -1
