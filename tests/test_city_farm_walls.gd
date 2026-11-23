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
const GOLDEN_COLLISION := {"1/0": [1398, 1495191684], "4/1": [2053, 2059034929]}
const FARM_TRIS_PER_M := 32.0      ## budget: lit + light-bar triangles per metre of farm wall (target ~30)


func setup() -> void:
	timeout_sec = 120.0
	_goldens()
	_kinds()
	await _deck(1, 0)
	await _deck(4, 1)
	await _hull()
	finish()


func _goldens() -> void:
	eq(CityPlan.make({"seed": 1}).checksum(), "209989488eaa0e52", "the seed 1 plan checksum (golden)")
	eq(CityPlan.make({"seed": 1, "walls": 1.0}).checksum(), "e4ec580da1956459", "the seed 1 walled plan checksum (golden)")
	eq(CityProps.layout_checksum(CityProps.layout(CityPlan.make({"seed": 1}))), "7e78d4e1e3db1a61", "the seed 1 props layout (golden)")


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


func _collision_hash(d: CityDistrict) -> Array:
	var h := 0
	var col := d.get_node("Collision")
	for c in col.get_children():
		var cs := c as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else (cs.shape as ConvexPolygonShape3D).points
		h = hash([h, cs.transform, sz])
	return [col.get_child_count(), h]


func _deck(seed_: int, k: int) -> void:
	var tag := "section %d deck %d" % [seed_, k]
	var d := CityDistrict.new()
	d.with_rig = false
	d.render_layer = 1 << 3
	add_child(d)
	d.build_deck(SectionPlan.make({"seed": seed_}), k)
	var plan := d.plan
	var key := "%d/%d" % [seed_, k]
	eq(_collision_hash(d), GOLDEN_COLLISION[key], tag + ": collision identical to the window walls' (count, hash)")
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
