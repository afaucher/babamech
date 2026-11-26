extends TestCase
## Vertical farm side walls (docs/design/city-styles.md "Side walls: vertical farm"): a section's window walls that would
## look out at a backdrop are drawn as a farm instead. Looks only: the plan checksums, the props layout and the whole
## collision are what they were with the window walls (captured from the code before the change), the farm stays inside
## the window wall's reach into the street, its sides get no backdrop, the hull window (no backdrop) is untouched, and
## the farm walls fit a triangle budget.

## Collision of whole section decks, captured from the window-wall code before the farm change: shape count and a hash
## of every shape's transform and size (see _collision_hash). Any other change to a deck's collision changes these too:
## recapture them only for a deliberate gameplay change, never for a looks change.
## Recaptured 2026-11-23: the first bridge over each ramp's cut was removed (CityPlan.BRIDGE_CLEAR), then the ramp's
## parapet end blocks were moved flush inside the ribbon (CityStreets.end_blocks: they straddled the floor hole's curb).
## Was {"1/0": [1393, 26314770], "4/1": [2070, 2398881905]}.
## Recaptured 2026-11-23 again: both decks got a downtown zone (docs/design/city-downtown.md; section 1 deck 0: one
## block, section 4 deck 1: three). Was {"1/0": [1398, 3304332043], "4/1": [2072, 1075195680]}.
## Recaptured 2026-11-23 (downtown pass 2: zones of 5 blocks on both decks, wings, alleys beside pillars). Was
## {"1/0": [1398, 1495191684], "4/1": [2053, 2059034929]}.
## 2026-11-23 (forms live: Missions switched the SectionPlan road forms on by default): these are now the decks built with
## the forms EXPLICITLY off (FORMS_OFF), where they still hold unchanged; GOLDEN_LIVE is the default (forms live) deck,
## captured 2026-11-23: 4/1 has 2 form segments whose courts / planting bands add 45 sidewalk-height boxes (the live list
## is the forms-off list with exactly those boxes inserted, asserted in _deck: the walls are untouched); 1/0's
## 4 form segments raise no ground (CityPlan.raised empty), so its collision is the same.
## Recaptured 2026-11-23 (map sealed: a portal's recess gets a back plate, CityDistrict._col_walls): 1/0 has the entry
## portal, so one shape more; with the portal plates taken out it is exactly the old capture (PRE_PLATE, asserted in
## _deck). 4/1 has no portal and is unchanged. Was 1/0 [1366, 1996002468] (forms off and live).
## Recaptured 2026-11-26 (ramp-end collision, tests/test_ramp_stuck.gd: parapets as prisms ending square to the deck,
## end blocks CityDistrict.END_GUARD tall; same shape counts). Was GOLDEN_COLLISION {"1/0": [1367, 4047391608], "4/1":
## [2030, 4209122442]}, GOLDEN_LIVE {"1/0": [1367, 4047391608], "4/1": [2075, 2245239995]}, PRE_PLATE {"1/0": [1366,
## 1996002468], "4/1": [2030, 4209122442]}.
const GOLDEN_COLLISION := {"1/0": [1367, 1339546450], "4/1": [2030, 1937480447]}
const GOLDEN_LIVE := {"1/0": [1367, 1339546450], "4/1": [2075, 2085075242]}
const PRE_PLATE := {"1/0": [1366, 3206981072], "4/1": [2030, 1937480447]}      ## forms off, portal plates left out
const FORMS_OFF := {"f_lane": 0.0, "f_pedestrian": 0.0, "f_none": 0.0}
const FARM_TRIS_PER_M := 32.0      ## budget: lit + light-bar triangles per metre of farm wall (target ~30)


func setup() -> void:
	timeout_sec = 120.0
	_goldens()
	_kinds()
	await _deck(1, 0)
	await _deck(4, 1)
	await _hull()
	finish()


## Re-captured 2026-11-23 (city variety: alleys + stand-alone road forms on by default). Was 209989488eaa0e52 /
## e4ec580da1956459 / props 7e78d4e1e3db1a61 (still the values with alleys 0, road_variety 0).
func _goldens() -> void:
	eq(CityPlan.make({"seed": 1}).checksum(), "bd1d848c575e85df", "the seed 1 plan checksum (golden)")
	eq(CityPlan.make({"seed": 1, "walls": 1.0}).checksum(), "3eb0728c9b4cffa2", "the seed 1 walled plan checksum (golden)")
	eq(CityProps.layout_checksum(CityProps.layout(CityPlan.make({"seed": 1}))), "f321076ebd6e98f1", "the seed 1 props layout (golden)")


## Every section window with a backdrop is a farm with none; nothing else changes kind.
func _kinds() -> void:
	var farms := 0
	for seed_ in [1, 2, 3, 4, 5, 6]:
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			for w: Dictionary in CityPlan.for_deck(sec, k).boundary():
				var src := sec.boundary(k, CityPlan.SIDE_EDGE[int(w["side"])])
				var farm: bool = src["kind"] == "window" and bool(src["backdrop"])
				eq(str(w["kind"]), "farm" if farm else str(src["kind"]), "section %d deck %d side %d kind" % [seed_, k, w["side"]])
				check(not bool(w["backdrop"]), "section %d deck %d side %d: no backdrop beyond any wall now" % [seed_, k, w["side"]])
				farms += 1 if farm else 0
	check(farms > 10, "the sections have farm walls (%d)" % farms)


## [shape count, hash]; with `skip_plates`, [count, hash, plates] leaving out the portal back plates (a box
## PORTAL_PLATE + 0.1 thick across the arc, more than GATE_RECESS - 0.5 m past an end of the extent).
func _collision_hash(d: CityDistrict, skip_plates: bool = false) -> Array:
	var h := 0
	var n := 0
	var plates := 0
	var e := d.plan.extent
	var col := d.get_node("Collision")
	for c in col.get_children():
		var cs := c as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else (cs.shape as ConvexPolygonShape3D).points
		if skip_plates and sz is Vector3 and absf((sz as Vector3).z - (CityDistrict.PORTAL_PLATE + 0.1)) < 0.001:
			var s := d.ring.world_to_arc(cs.transform.origin).y
			if s > e.end.y + CityStreets.GATE_RECESS - 0.5 or s < e.position.y - CityStreets.GATE_RECESS + 0.5:
				plates += 1
				continue
		h = hash([h, cs.transform, sz])
		n += 1
	return [n, h, plates] if skip_plates else [n, h]


func _shape_list(d: CityDistrict) -> Array:
	var out := []
	for c in d.get_node("Collision").get_children():
		var cs := c as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else (cs.shape as ConvexPolygonShape3D).points
		out.append(hash([cs.transform, sz]))
	return out


func _deck(seed_: int, k: int) -> void:
	var tag := "section %d deck %d" % [seed_, k]
	var d := CityDistrict.new()
	d.with_rig = false
	d.render_layer = 1 << 3
	add_child(d)
	d.build_deck(SectionPlan.make({"seed": seed_}), k)
	var plan := d.plan
	var key := "%d/%d" % [seed_, k]
	var off_sp := FORMS_OFF.duplicate()
	off_sp["seed"] = seed_
	var o := CityDistrict.new()
	o.with_rig = false
	add_child(o)
	o.build_deck(SectionPlan.make(off_sp), k)
	eq(_collision_hash(o), GOLDEN_COLLISION[key], tag + " (forms off): collision identical to the window walls' (count, hash)")
	var portals := 0
	for w: Dictionary in o.plan.boundary():
		for g: Dictionary in w["gates"]:
			portals += 1 if str(g["kind"]) == "portal" else 0
	var pre := _collision_hash(o, true)
	eq([pre[0], pre[1]], PRE_PLATE[key], tag + " (forms off): without the portal back plates, the collision before the map was sealed")
	eq(pre[2], portals, tag + ": one back plate per portal (%d)" % portals)
	eq(_collision_hash(d), GOLDEN_LIVE[key], tag + " (forms live): collision as captured (count, hash)")
	# The road forms only add the ground they raise (CityPlan.raised: courts, planting bands), as one run of boxes after
	# the sidewalks; every other shape (walls, gates, buildings, ramps) is the forms-off deck's, in the same order.
	var so := _shape_list(o)
	var sl := _shape_list(d)
	var n_raised := 0
	for rq: Dictionary in plan.raised:
		for q in CityGeo.cut(rq["rect"], plan.floor_cuts()):
			n_raised += CityGeo.breaks(q.position.y, q.end.y).size() - 1
	var i := 0
	while i < so.size() and i < sl.size() and so[i] == sl[i]:
		i += 1
	eq(sl.size(), so.size() + n_raised, tag + ": the forms add exactly their raised ground boxes (%d)" % n_raised)
	check(sl.slice(i + n_raised) == so.slice(i), tag + ": with forms live every other shape is the forms-off deck's (walls untouched)")
	o.queue_free()
	check(d.get_node_or_null("Backdrop") == null, tag + ": no backdrop (every window wall here is a farm)")
	var lights := d.get_node_or_null("FarmLights") as MeshInstance3D
	check(lights != null, tag + ": the farm's light bars")
	if lights != null:
		eq(lights.layers, d.render_layer, tag + ": light bars on the deck's render layer")
		eq(lights.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, tag + ": light bars cast no shadow")
		eq(lights.material_override if lights.material_override != null else lights.mesh.surface_get_material(0), CityPalette.farm_light_material(),
				tag + ": light bars use the warm farm light material")
	var e := plan.extent
	var h := plan.p("ceiling")
	# Farm geometry: inside the window wall's reach into the street (FARM_REACH), and no more triangles than the budget.
	var walls := d.get_node("Walls") as MeshInstance3D
	var farm_len := 0.0
	var farm_walls := []
	for w: Dictionary in plan.boundary():
		if w["kind"] == "farm":
			farm_walls.append(w)
			farm_len += e.size.x if int(w["side"]) >= 2 else e.size.y
	check(not farm_walls.is_empty(), tag + ": has farm walls")
	var verts: PackedVector3Array = walls.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var n_near := 0
	var worst := -INF
	for v in verts:
		var a := d.ring.world_to_arc(v)
		if a.z > h - 0.2 or a.z < -0.5:
			continue
		for w: Dictionary in farm_walls:
			var side := int(w["side"])
			var across := side >= 2
			var inward := -1.0 if side % 2 == 0 else 1.0
			var u := a.x if across else a.y
			var off := ((a.y if across else a.x) - float(w["at"])) * inward     # + into the map
			var u0 := e.position.x if across else e.position.y
			var u1 := e.end.x if across else e.end.y
			if off < -CityStreets.FARM_RECESS - 0.05 or off > 3.0 or u < u0 + 3.0 or u > u1 - 3.0:
				continue
			var by_gate := false
			for g: Dictionary in w["gates"]:
				if u > float(g["a"]) - 3.0 and u < float(g["b"]) + 3.0:
					by_gate = true
			if by_gate:
				continue
			n_near += 1
			worst = maxf(worst, off)
	check(n_near > 1000, tag + ": farm vertices found (%d)" % n_near)
	check(worst <= CityStreets.FARM_REACH + 0.02, tag + ": the farm reaches %.2f m into the street (window wall: %.2f)" % [worst, CityStreets.FARM_REACH])
	# Triangle budget for the farm walls (the walls mesh also holds the bulkheads: count a farm-only deck's walls).
	var tris := walls.mesh.get_faces().size() / 3 + (lights.mesh.get_faces().size() / 3 if lights != null else 0)
	print("%s: farm %.0f m, walls + bars %d triangles, deck %d triangles" % [tag, farm_len, tris, int(d.stats["triangles"])])
	if farm_walls.size() == 4:
		check(float(tris) <= farm_len * FARM_TRIS_PER_M, tag + ": farm walls within budget (%d <= %.0f)" % [tris, farm_len * FARM_TRIS_PER_M])
	# A ray at mech height into a farm wall stops on the wall plane, as at a window wall.
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var w0: Dictionary = farm_walls[0]
	var side0 := int(w0["side"])
	var across0 := side0 >= 2
	var in0 := -1.0 if side0 % 2 == 0 else 1.0
	var at0 := float(w0["at"])
	for sp: Array in CityStreets.wall_spans((e.position.x if across0 else e.position.y) + 5.0, (e.end.x if across0 else e.end.y) - 5.0, w0["gates"]):
		var um := (float(sp[0]) + float(sp[1])) * 0.5
		for y: float in [2.0, 8.0, 20.0]:
			var p := d.ring.arc_to_world(um, at0 + in0 * 6.0, y) if across0 else d.ring.arc_to_world(at0 + in0 * 6.0, um, y)
			var q := d.ring.arc_to_world(um, at0 - in0 * 3.0, y) if across0 else d.ring.arc_to_world(at0 - in0 * 3.0, um, y)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p, q))
			check(not hit.is_empty(), tag + ": the farm wall is solid at %.0f m" % y)
			if not hit.is_empty():
				near(p.distance_to(hit["position"]), 6.0, 0.1, tag + ": the farm wall's collision is on the wall plane")
		break
	d.queue_free()
	await frames(1)


## The hull's window wall (a district on its own with walls: no backdrop behind it) stays a window wall.
func _hull() -> void:
	var plan := CityPlan.make({"seed": 1, "walls": 1.0})
	for w: Dictionary in plan.boundary():
		eq(str(w["kind"]), "bulkhead" if int(w["side"]) >= 2 else "window", "hull walls: side %d unchanged" % w["side"])
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": 1, "walls": 1.0})
	check(d.get_node_or_null("FarmLights") == null, "hull walls: no farm light bars")
	d.queue_free()
	await frames(1)
