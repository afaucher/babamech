extends TestCase
## The multi-deck stack and the ramps between decks (scripts/world/city/city_stack.gd, docs/design/city-ramps-and-stack.md):
## every deck of a section builds in one scene about one axis, the checksum is stable, every ramp has a top part on its
## upper deck and a bottom part on its lower deck that meet, a mech can walk down a ramp with no gap or step, its
## parapets and underside are solid, deck_at / ring / entry_transform / props_at answer for the right deck, each deck is
## lit only by its own lights and the daylight follows the active deck, and props work on a moved and rotated district.

const SEEDS := [1, 2, 3, 4, 5]


func setup() -> void:
	timeout_sec = 240.0
	for seed_: int in SEEDS:
		_plans(seed_)
	for seed_: int in SEEDS:
		await _stack(seed_)
	await _props_moved()
	await _roof_props_stack()
	await _lab()
	finish()


## The lab's stack site: the deck slider moves the active deck, the ramp camera stands on the ramp's upper deck, and a
## section with no ramp (seed 9) falls back to the avenue view.
func _lab() -> void:
	var lab := CityLab.new()
	lab.options["site"] = "stack"
	lab.params["seed"] = 4.0
	add_child(lab)
	check(lab.stack != null and lab.stack.decks.size() == 3, "the lab builds the stack")
	lab.set_lab_param("deck", 2.0)
	eq(lab.stack.active_deck, 2, "the deck slider picks the active deck")
	check(lab.district == lab.stack.decks[2], "and the deck on show")
	for cam: String in CityLab.CAMERAS:
		lab.set_lab_option("camera", cam)
	lab.set_lab_param("deck", 0.0)
	lab.set_lab_option("camera", "ramp")
	var cam := get_viewport().get_camera_3d()
	var top := -1
	for ci in lab.stack.section.connectors.size():
		if lab.stack.section.connectors[ci]["kind"] == "ramp" and top < 0:
			top = int(lab.stack.section.connectors[ci]["from"])
	eq(lab.stack.deck_at(cam.global_position), top, "the ramp camera stands on the first ramp's upper deck")
	for low_cam: String in ["ramp_foot", "ramp_under"]:
		lab.set_lab_option("camera", low_cam)
		eq(lab.stack.deck_at(cam.global_position), top + 1, "the %s camera stands on the first ramp's lower deck" % low_cam)
		eq(lab.stack.active_deck, top + 1, "and makes it the active deck")
		var d := lab.stack.decks[top + 1]
		near(d.ring.height(d.to_local(cam.global_position)), 9.0, 0.05, "at a cockpit's height")
	lab.set_lab_option("camera", "shaft")
	check(get_viewport().get_camera_3d() == cam, "the shaft camera is the lab's own")
	lab.params["seed"] = 9.0
	lab.rebuild()
	lab.set_lab_option("camera", "avenue")
	var avenue := cam.global_transform
	lab.set_lab_option("camera", "ramp")
	check(cam.global_transform.is_equal_approx(avenue), "with no ramp the ramp camera falls back to the avenue")
	lab.queue_free()
	await frames(1)


## Plan level: ramp parts on the right decks, meeting in world space; the spine gate spans the whole spine.
func _plans(seed_: int) -> void:
	var sec := SectionPlan.make({"seed": seed_})
	var plans: Array[CityPlan] = []
	for k in sec.deck_count:
		plans.append(CityPlan.for_deck(sec, k))
	var slab := sec.p("slab")
	for ci in sec.connectors.size():
		var cn: Dictionary = sec.connectors[ci]
		if cn["kind"] != "ramp":
			continue
		var top := _part(plans[int(cn["from"])], ci, "top")
		var bottom := _part(plans[int(cn["to"])], ci, "bottom")
		var what := "section %d ramp %d->%d" % [seed_, cn["from"], cn["to"]]
		if not check(not top.is_empty() and not bottom.is_empty(), "%s: a top part on its upper deck and a bottom part on its lower deck" % what):
			continue
		near(top["h_top"], 0.0, 1e-4, "%s: the top starts flush with the road" % what)
		near(top["h_foot"], -(slab + 1.0), 1e-4, "%s: the top part ends 1 m under the slab" % what)
		near(bottom["h_top"], sec.clear_height(), 1e-4, "%s: the bottom part comes out of the ceiling" % what)
		near(bottom["h_foot"], 0.0, 1e-4, "%s: the foot meets the road" % what)
		# Where they meet (the lower deck's ceiling), both parts are at the same world point.
		var mid := (float(cn["x0"]) + float(cn["x1"])) * 0.5
		var on_top := sec.to_world(int(cn["from"]), mid, CityPlan.ramp_s(top, -slab), -slab)
		var on_bottom := sec.to_world(int(cn["to"]), mid, float(bottom["s_top"]), float(bottom["h_top"]))
		check(on_top.distance_to(on_bottom) < 0.1, "%s: the parts meet (%.3f m apart)" % [what, on_top.distance_to(on_bottom)])
		var foot := sec.to_world(int(cn["from"]), mid, CityPlan.ramp_s(top, -(slab + 1.0)), -(slab + 1.0))
		var foot_b := sec.to_world(int(cn["to"]), mid, CityPlan.ramp_s(bottom, sec.clear_height() - 1.0), sec.clear_height() - 1.0)
		check(foot.distance_to(foot_b) < 0.1, "%s: and agree at the top part's end too" % what)
		var mouth := 0
		for o in plans[int(cn["from"])].floor_cuts():
			if plans[int(cn["from"])].ramp_mouth(o) >= 0:
				mouth += 1
		check(mouth >= 1, "%s: the floor is open across the ramp's top" % what)
		var length := absf(float(cn["theta1"]) - float(cn["theta0"]))
		print("%s (%s): %.0f m on the upper deck, %.0f m on the lower, grade %.3f / %.3f" % [what, cn["lane"], length * sec.radius_of(int(cn["from"])),
				length * sec.radius_of(int(cn["to"])), sec.p("pitch") / (length * sec.radius_of(int(cn["from"]))), sec.p("pitch") / (length * sec.radius_of(int(cn["to"])))])
	for k in sec.deck_count:
		for w: Dictionary in plans[k].boundary():
			for g: Dictionary in w["gates"]:
				if float(g["h"]) >= 14.0:
					near(g["a"], sec.lane_x("ramp_a").x, 0.01, "section %d deck %d: the spine gate starts at the first ramp lane" % [seed_, k])
					near(g["b"], sec.lane_x("ramp_b").y, 0.01, "section %d deck %d: the spine gate ends at the last ramp lane" % [seed_, k])


func _part(plan: CityPlan, ci: int, role: String) -> Dictionary:
	for r: Dictionary in plan.ramps:
		if int(r["connector"]) == ci and r["role"] == role:
			return r
	return {}


func _stack(seed_: int) -> void:
	var sec := SectionPlan.make({"seed": seed_})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	var what := "section %d" % seed_
	eq(stack.decks.size(), sec.deck_count, "%s: a district per deck" % what)
	var plans: Array[CityPlan] = []
	for k in stack.decks.size():
		var d := stack.decks[k]
		eq(d.name, "Deck%d" % k, "%s: deck %d is named" % [what, k])
		check(d.position.is_equal_approx(sec.deck_offset(k)), "%s: deck %d sits at its offset" % [what, k])
		check(d.get_node_or_null("Ground") != null and d.get_node_or_null("Collision") != null, "%s: deck %d is built" % [what, k])
		eq(d.get_node_or_null("Ramps") != null, not d.plan.ramps.is_empty(), "%s: deck %d draws its ramps" % [what, k])
		plans.append(CityPlan.for_deck(sec, k))
	eq(stack.checksum(), CityStack.sum_of(sec, plans), "%s: same inputs, same stack checksum" % what)
	check(stack.checksum() != CityStack.sum_of(SectionPlan.make({"seed": seed_ + 100}), plans), "%s: another section, another checksum" % what)
	print("%s stack: %s" % [what, str(stack.stats)])
	await frames(2)
	for ci in sec.connectors.size():
		if sec.connectors[ci]["kind"] == "ramp":
			_walk(stack, ci, "%s ramp %d" % [what, ci])
	_queries(stack, what)
	_lighting(stack, what)
	stack.queue_free()
	await frames(1)


## Down the ramp's centre line every 4 m: always something under foot, falling steadily, no step over 0.8 m. Then its
## parapets and its underside.
func _walk(stack: CityStack, ci: int, what: String) -> void:
	var sec := stack.section
	var cn: Dictionary = sec.connectors[ci]
	var space := stack.get_world_3d().direct_space_state
	var axis := stack.ring()
	var th0 := float(sec.row_theta[int(cn["top_line"])])
	var th1 := float(sec.row_theta[int(cn["foot_line"])])
	var r_low := sec.radius_of(int(cn["to"]))
	var pitch := sec.p("pitch")
	var x0 := float(cn["x0"])
	var x1 := float(cn["x1"])
	var mid := (x0 + x1) * 0.5
	var n := int(ceil(absf(th1 - th0) * sec.radius_of(int(cn["from"])) / 4.0))
	var last := -INF
	var gaps := 0
	var worst := 0.0
	for i in n + 1:
		var t := float(i) / float(n)
		var th := lerpf(th0, th1, t)
		var r := r_low - pitch * (1.0 - t)       # the ramp's surface, as distance from the axis
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(sec.polar_to_world(mid, th, r - 3.0), sec.polar_to_world(mid, th, r + 3.0)))
		if hit.is_empty():
			gaps += 1
			continue
		var at := axis.dist_to_axis(hit["position"])
		check(absf(at - r) < 0.15, "%s: at t=%.2f the surface is on the slope (%.2f m off)" % [what, t, at - r])
		if last > -INF:
			check(at >= last - 0.02, "%s: the surface falls steadily at t=%.2f" % [what, t])
			worst = maxf(worst, at - last)
		last = at
	eq(gaps, 0, "%s: no gap under the ramp's centre line" % what)
	check(worst <= 0.8, "%s: no step over 0.8 m (worst %.2f)" % [what, worst])
	# Parapets: a ray down each parapet line lands on its top.
	for px: float in [x0 + CityStreets.PARAPET_W * 0.5, x1 - CityStreets.PARAPET_W * 0.5]:
		for t: float in [0.1, 0.35, 0.6, 0.85]:
			var th := lerpf(th0, th1, t)
			var r := r_low - pitch * (1.0 - t) - CityStreets.PARAPET_H
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(sec.polar_to_world(px, th, r - 2.0), sec.polar_to_world(px, th, r + 0.5)))
			check(not hit.is_empty() and absf(axis.dist_to_axis(hit["position"]) - r) < 0.15, "%s: the parapet at x=%.2f t=%.2f is solid" % [what, px, t])
	# Underside: from the lower deck's road straight up where the ramp is 15 m up (beside the piers).
	var tu := 1.0 - 15.0 / pitch
	var thu := lerpf(th0, th1, tu)
	var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(sec.polar_to_world(x0 + 2.0, thu, r_low - 0.5), sec.polar_to_world(x0 + 2.0, thu, r_low - 30.0)))
	check(not up.is_empty() and absf(axis.dist_to_axis(up["position"]) - (r_low - 15.0 + CityStreets.RAMP_THICK)) < 0.3,
			"%s: a ray up from the road under the ramp hits its underside" % what)
	_underside(stack, ci, what)


## Under the bottom part, seen from the lower deck: wherever the ramp is more than 6 m up, a ray straight up from the road
## hits its collision (the soffit, or an edge beam) at the right height and crosses a downward face of its mesh (no
## see-through); every pier is solid across and stands clear of the cross roads; between two high piers a mech walks under.
func _underside(stack: CityStack, ci: int, what: String) -> void:
	var cn: Dictionary = stack.section.connectors[ci]
	var low := stack.decks[int(cn["to"])]
	var r := _part(low.plan, ci, "bottom")
	if not check(not r.is_empty(), "%s: the lower deck has the bottom part" % what):
		return
	var space := stack.get_world_3d().direct_space_state
	var x0 := float(r["x0"])
	var x1 := float(r["x1"])
	var mid := (x0 + x1) * 0.5
	var piers := CityStreets.pier_s(r, low.plan)
	check(piers.size() >= 4, "%s: a row of piers under the ramp (%d)" % [what, piers.size()])
	var at := func(x: float, s: float, h: float) -> Vector3: return low.to_global(low.ring.arc_to_world(x, s, h))
	var height := func(p: Vector3) -> float: return low.ring.height(low.to_local(p))
	# Rays up: under an edge beam, the middle of the soffit, the other edge beam.
	var tris := _mesh_tris(low.get_node("Ramps") as MeshInstance3D)
	var s_a := CityPlan.ramp_s(r, 6.0)
	var s_b := CityPlan.ramp_s(r, float(r["h_top"]) - 0.5)
	var n := 12
	var solid_misses := 0
	var see_through := 0
	var rays := 0
	for i in n + 1:
		var s := lerpf(s_a, s_b, float(i) / float(n))
		var by_pier := false
		for p in piers:
			by_pier = by_pier or absf(p - s) < CityStreets.CROSS_L
		if by_pier:
			continue
		var h := CityPlan.ramp_height(r, s)
		for x: float in [x0 + CityStreets.BEAM_W * 0.5, mid, x1 - CityStreets.BEAM_W * 0.5]:
			var want := h - CityStreets.RAMP_THICK - (CityStreets.BEAM_D if x != mid else 0.0)
			var a: Vector3 = at.call(x, s, 0.3)
			var b: Vector3 = at.call(x, s, h + 0.5)
			rays += 1
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b))
			if hit.is_empty() or absf(float(height.call(hit["position"])) - want) > 0.3:
				solid_misses += 1
			if not _crosses_face(tris, a, b):
				see_through += 1
	check(rays >= 18, "%s: enough rays up under the ramp (%d)" % [what, rays])
	eq(solid_misses, 0, "%s: every ray up from the road under the ramp hits the soffit or an edge beam" % what)
	eq(see_through, 0, "%s: and crosses a downward face of the ramp's mesh (no see-through)" % what)
	# Piers: solid across at 4 m, clear of every cross road.
	var hollow := 0
	var on_road := 0
	for p in piers:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at.call(mid - 4.0, p, 4.0), at.call(mid + 4.0, p, 4.0)))
		if hit.is_empty():
			hollow += 1
		for road: Dictionary in low.plan.roads_s:
			if p + CityStreets.PIER_W * 0.5 > float(road["a"]) - 1.0 and p - CityStreets.PIER_W * 0.5 < float(road["b"]) + 1.0:
				on_road += 1
	eq(hollow, 0, "%s: every pier is solid" % what)
	eq(on_road, 0, "%s: no pier stands on a cross road or its crossing" % what)
	# Between two piers with the ramp well over a mech's height: open underneath at 1 m and at 9 m.
	var tested := false
	for k in piers.size() - 1:
		var s := (piers[k] + piers[k + 1]) * 0.5
		if CityPlan.ramp_height(r, s) < 16.0 or tested:
			continue
		tested = true
		for h: float in [1.0, 9.0]:
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at.call(x0 - 4.0, s, h), at.call(x1 + 4.0, s, h)))
			check(hit.is_empty(), "%s: a mech walks under the ramp between piers (nothing across at %.0f m)" % [what, h])
	check(tested, "%s: a span high enough to walk under" % what)


## The triangles of a mesh instance in world space, as flat [a, b, c, normal, ...].
func _mesh_tris(mi: MeshInstance3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var xf := mi.global_transform
	for si in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in range(0, v.size() - 2, 3):
			out.append_array([xf * v[i], xf * v[i + 1], xf * v[i + 2], xf.basis * nn[i]])
	return out


## Whether the segment a -> b passes through a triangle that faces back toward a.
func _crosses_face(tris: Array[Vector3], a: Vector3, b: Vector3) -> bool:
	var dir := b - a
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)) - Vector3.ONE * 0.5
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)) + Vector3.ONE * 0.5
	for i in range(0, tris.size(), 4):
		var p := tris[i]
		if p.x < lo.x - 6.0 or p.x > hi.x + 6.0 or p.z < lo.z - 6.0 or p.z > hi.z + 6.0 or p.y < lo.y - 6.0 or p.y > hi.y + 6.0:
			continue
		if tris[i + 3].dot(dir) < 0.0 and Geometry3D.segment_intersects_triangle(a, b, p, tris[i + 1], tris[i + 2]) != null:
			return true
	return false


func _queries(stack: CityStack, what: String) -> void:
	var sec := stack.section
	near(stack.ring().radius, sec.radius_of(sec.deck_count - 1), 0.001, "%s: ring() is the lowest deck's frame" % what)
	for k in stack.decks.size():
		var d := stack.decks[k]
		var s := sec.line_s(k, 2) + 20.0
		for h: float in [0.0, 2.0, sec.clear_height() - 1.0]:
			eq(stack.deck_at(d.to_global(d.ring.arc_to_world(-100.0, s, h))), k, "%s: a point %.0f m above deck %d is on it" % [what, h, k])
		var p := d.to_global(d.ring.arc_to_world(30.0, s, 5.0))
		check(stack.ring().up_at(p).is_equal_approx(d.ring.up_at(d.to_local(p))), "%s: ring() gives deck %d's up" % [what, k])
		check(stack.props_at(p) == d.props, "%s: props_at on deck %d is that deck's props" % [what, k])
		check(d.props.is_in_group("city_props"), "%s: deck %d's props are in the city_props group" % [what, k])
	check(stack.is_in_group("city_stack"), "%s: the stack is in its group" % what)
	var xf := stack.entry_transform()
	var k0 := int(sec.entry["deck"])
	eq(stack.deck_at(xf.origin), k0, "%s: the entry is on the entry deck" % what)
	var d0 := stack.decks[k0]
	var local := d0.to_local(xf.origin)
	near(d0.ring.height(local), 0.3, 0.01, "%s: the entry is 0.3 m above the floor" % what)
	var av := sec.lane_x("avenue")
	check(local.x > av.x and local.x < av.y, "%s: the entry is on the avenue lane" % what)
	var ahead := d0.ring.world_to_arc(d0.to_local(xf.origin - xf.basis.z * 5.0)).y - d0.ring.world_to_arc(local).y
	check(ahead * (1.0 if int(sec.entry["j"]) == 0 else -1.0) > 4.0, "%s: the entry faces into the map" % what)
	var down := stack.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(xf.origin, xf.origin - xf.basis.y * 2.0))
	check(not down.is_empty(), "%s: solid ground under the entry" % what)


func _lighting(stack: CityStack, what: String) -> void:
	var sec := stack.section
	var digests: Array[int] = []
	for k in stack.decks.size():
		digests.append(stack.decks[k].geometry_digest())
		var wrong := 0
		for g in stack.decks[k].find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).layers != CityStack.deck_layer(k):
				wrong += 1
		eq(wrong, 0, "%s: every mesh of deck %d is on its layer" % [what, k])
	var per_deck := {}
	for l: OmniLight3D in stack.rig.get_node("Fills").get_children():
		var k := -1
		for j in stack.decks.size():
			if l.light_cull_mask == 1 | CityStack.deck_layer(j):
				k = j
		if not check(k >= 0, "%s: a fill light lights one deck's layer" % what):
			continue
		per_deck[k] = int(per_deck.get(k, 0)) + 1
		var r := stack.ring().dist_to_axis(l.global_position)
		check(r < sec.radius_of(k) and r > sec.radius_of(k) - sec.clear_height(), "%s: deck %d's fill hangs in deck %d" % [what, k, k])
		check(l.omni_range <= sec.p("pitch") * 0.9 + 0.001, "%s: a fill's range stays inside its deck" % what)
	eq(per_deck.size(), stack.decks.size(), "%s: every deck has its fill lights" % what)
	for k in stack.decks.size():
		for id in CityLightRig.preset_ids():
			stack.set_active_deck(k)
			stack.rig.apply(id)
			eq(stack.rig.sun.light_cull_mask, 1 | CityStack.deck_layer(k), "%s: the daylight lights layer 1 and deck %d" % [what, k])
			eq(stack.rig.sun.shadow_caster_mask, 1 | CityStack.deck_layer(k), "%s: and takes shadows from them only" % what)
	for k in stack.decks.size():
		eq(stack.decks[k].geometry_digest(), digests[k], "%s: relighting leaves deck %d's geometry alone" % [what, k])


## CityProps on a district that is moved and turned: first_hit, blast and a pusher work in world space.
func _props_moved() -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	d.transform = Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.RIGHT, 0.2), Vector3(40.0, -20.0, 15.0))
	add_child(d)
	d.build({"seed": 3, "size_x": 100.0, "size_s": 110.0})
	var p := d.props
	p.set_physics_process(false)
	var lamps: Array[int] = []
	for it: Dictionary in p.items:
		if it["type"] == "lamp":
			lamps.append(int(it["id"]))
	var foot := func(id: int) -> Vector3: return d.global_transform * p.transform_of(id).origin
	var head := func(id: int) -> Vector3: return d.global_transform * (p.transform_of(id) * Vector3(0, 5.0, 0))
	# A shot across a lamp at mid height hits it, at a point on its capsule.
	var a: int = lamps[0]
	var f: Vector3 = foot.call(a)
	var up: Vector3 = ((head.call(a) as Vector3) - f).normalized()
	var side := up.cross(d.global_transform.basis.x).normalized()
	var hit := p.first_hit(f + up * 3.0 + side * 2.0, f + up * 3.0 - side * 2.0, 0.05)
	check(not hit.is_empty() and int(hit["id"]) == a, "first_hit finds the lamp on a moved district (%s)" % str(hit))
	if not hit.is_empty():
		var on_axis := Geometry3D.get_closest_point_to_segment(hit["point"], f, head.call(a))
		check((hit["point"] as Vector3).distance_to(on_axis) < float(CityPropSim.TYPES["lamp"]["radius"]) + 0.1, "the hit point is on the lamp in world space")
	# A blast at another lamp's foot topples it.
	var b: int = lamps[lamps.size() / 2]
	p.blast((foot.call(b) as Vector3) + up * 1.0, 3.0, 40.0, "test")
	eq(p.state_of(b), CityProps.FALLING, "a blast in world space topples the lamp")
	# A pusher walking through a third lamp knocks it over.
	var c: int = lamps[-1]
	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = foot.call(c)
	var it_c: Dictionary = p.items[c]
	body.velocity = d.global_transform.basis * (CityGeo.frame_basis(d.ring, float(it_c["s"])).z * 5.0)
	p.add_pusher(body, 1.5)
	p.step(0.016)
	eq(p.state_of(c), CityProps.FALLING, "a pusher in world space topples the lamp it walks into")
	body.queue_free()
	_roof_hits(d, "moved district")
	d.queue_free()
	await frames(1)


## Roof units on an upper deck of a stack (offset from the origin): shots and blasts in world space reach them.
func _roof_props_stack() -> void:
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 4}))
	for k in stack.decks.size():
		stack.decks[k].props.set_physics_process(false)
	var top := stack.decks[0]
	check(top.position.length() > 1.0, "deck 0 is offset from the origin")
	_roof_hits(top, "stack 4 deck 0")
	eq(stack.props_at(top.global_transform * top.props.transform_of(_roof_first(top.props)).origin), top.props, "props_at finds a roof unit's deck")
	stack.queue_free()
	await frames(1)


func _roof_first(p: CityProps) -> int:
	for it: Dictionary in p.items:
		if CityPropSim.is_roof(it) and it["type"] != "vent":
			return int(it["id"])
	return -1


## A shot across the first roof unit stops on it (at a point on its capsule); a blast beside the last (maybe the same)
## topples it and it stays on its roof.
func _roof_hits(d: CityDistrict, what: String) -> void:
	var p := d.props
	var ids: Array[int] = []
	for it: Dictionary in p.items:
		if CityPropSim.is_roof(it):
			ids.append(int(it["id"]))
	if not check(ids.size() >= 1, "%s: has roof units (%d)" % [what, ids.size()]):
		return
	var a := ids[0]
	var xf := d.global_transform * p.transform_of(a)
	var h := float(CityPropSim.TYPES[p.items[a]["type"]]["height"])
	var mid := xf * Vector3(0, h * 0.5, 0)
	var side := (xf.basis.z).normalized()
	var hit := p.first_hit(mid + side * 2.0, mid - side * 2.0, 0.05)
	check(not hit.is_empty() and int(hit["id"]) == a, "%s: first_hit finds a roof unit in world space (%s)" % [what, str(hit)])
	if not hit.is_empty():
		var on_axis := Geometry3D.get_closest_point_to_segment(hit["point"], xf.origin, xf * Vector3(0, h, 0))
		check((hit["point"] as Vector3).distance_to(on_axis) < float(CityPropSim.TYPES[p.items[a]["type"]]["radius"]) + 0.1, "%s: on its capsule" % what)
	var b := ids[ids.size() - 1]
	var bx := d.global_transform * p.transform_of(b)
	p.blast(bx * Vector3(0.8, 0.5, 0), 3.0, 40.0, "test")
	eq(p.state_of(b), CityProps.FALLING, "%s: a blast in world space topples a roof unit" % what)
	p.advance_to(p.now + 5.0)
	var it_b: Dictionary = p.items[b]
	var lp: Vector3 = d.building_frame(int(it_b["building"])).affine_inverse() * p.transform_of(b).origin
	near(lp.y, float(it_b["ly"]), 0.02, "%s: and it lies on its roof" % what)
