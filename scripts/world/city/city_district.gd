class_name CityDistrict
extends Node3D
## One generated urban district standing on a ring deck: the nodes for a CityPlan. Children:
##   Ground, Ramps, Buildings/Block<n>, Furniture, Ceiling, Strips, Backdrop   meshes (flat palette colours, one lit material)
##   Props                                                              CityProps: trees, lamps, signs, benches, bins and roof units that fall over
##   Collision                                                          a StaticBody3D: deck, sidewalks, building tiers and solids (portico, gable, skylights), ceiling
##   LightRig                                                           CityLightRig (optional): every light and the environment
## build() plans a district on its own; build_deck() builds one whole deck of a mission section (CityPlan.for_deck).
## Geometry and lighting are separate on purpose: build() never touches the rig's look, and the rig never touches a mesh.
##
## Gameplay shape = plan (seeded, checksummed) -> collision. Looks (colours, windows, clutter, furniture, backdrop) use a
## second generator seeded from plan.cosmetic_seed(): cosmetic, but still the same on every machine. The props are laid
## out from their own generator (CityProps.layout) because they are gameplay objects that move and are synced.

var plan: CityPlan
var ring: RingFrame
var rig: CityLightRig
var props: CityProps           ## the loose street props (host-arbitrated, synced): not part of geometry_digest()
var with_rig := true           ## false: bring your own lighting
var with_backdrop := true
var render_layer := 1          ## the render layers every mesh of the district is on (a stack gives each deck its own)
var strip_x := PackedFloat32Array()     ## x of every ceiling light strip, for a light rig hung elsewhere (a stack's)
var stats: Dictionary = {}     ## triangles, shapes and build time of the last build()

const SEAM := 0.06     ## facet slabs overlap by this much, so a ray down the crease between two still hits

var _digest := 0


func build(params: Dictionary = {}, given: CitySite = null) -> void:
	_build(Time.get_ticks_msec(), CityPlan.make(params, given))


## One whole deck of a mission section (CityPlan.for_deck): the same children and collision as build().
func build_deck(section: SectionPlan, deck: int, overrides: Dictionary = {}) -> void:
	_build(Time.get_ticks_msec(), CityPlan.for_deck(section, deck, overrides))


func _build(t0: int, new_plan: CityPlan) -> void:
	for c in get_children():
		if c != rig:
			remove_child(c)
			c.queue_free()
	plan = new_plan
	ring = RingFrame.new(plan.p("radius"))
	var look := RandomNumberGenerator.new()
	look.seed = plan.cosmetic_seed()
	_digest = 0
	var tris := 0

	var ground := CityGeo.new(ring)
	CityStreets.ground(ground, plan)
	tris += _add(ground, "Ground", self)
	if not plan.ramps.is_empty():
		var ramp_geo := CityGeo.new(ring)
		CityStreets.ramps(ramp_geo, plan)
		tris += _add(ramp_geo, "Ramps", self)

	var holder := Node3D.new()
	holder.name = "Buildings"
	add_child(holder)
	var per_block: Array[CityGeo] = []
	for i in plan.blocks.size():
		per_block.append(CityGeo.new(ring))
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		var geo := per_block[int(plan.lots[b["lot"]]["block"])]
		CityBuildings.build(geo, building_frame(i), core_frame(i), plan, i, look)
	if not plan.columns.is_empty():
		var cols := CityGeo.new(ring)
		for c: Dictionary in plan.columns:
			CityBuildings.column(cols, _frame_at(c["x"], c["s"]), c, plan.p("ceiling"))
		tris += _add(cols, "Columns", holder)
	for i in per_block.size():
		if not per_block[i].is_empty():
			tris += _add(per_block[i], "Block%d" % i, holder)

	props = CityProps.new()
	props.deck = plan.deck if plan.section != null else -1   # stack decks tag their prop events (CityProps.deck)
	props.setup(plan, ring)
	var furn := CityGeo.new(ring)
	CityStreets.furniture(furn, plan, props.items)
	tris += _add(furn, "Furniture", self)
	add_child(props)
	tris += props.tri_count()

	var bounds := plan.boundary()
	var walled := not bounds.is_empty()
	if walled:
		var wall_geo := CityGeo.new(ring)
		CityStreets.walls(wall_geo, plan)
		tris += _add(wall_geo, "Walls", self, false)
	# The backdrop: all round an open district, or beyond each window wall that looks out onto it.
	var open_edge := with_backdrop and not walled
	var views: Array[Rect2] = []
	if with_backdrop:
		for w: Dictionary in bounds:
			if w["backdrop"]:
				views.append(CityStreets.backdrop_edge(plan, int(w["side"])))
	var area := CityStreets.backdrop_area(plan) if open_edge else plan.extent.grow(1.0 if walled else 14.0)
	for v in views:
		area = area.merge(v)
	var ceil_geo := CityGeo.new(ring)
	var strips := CityGeo.new(ring)
	strip_x = CityStreets.ceiling(ceil_geo, strips, area, plan, look)
	tris += _add(ceil_geo, "Ceiling", self, false)
	var strip_node := strips.instance("Strips", CityPalette.strip_material())
	strip_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(strip_node)
	tris += strips.tri_count()

	if open_edge or not views.is_empty():
		var back := CityGeo.new(ring)
		if open_edge:
			CityStreets.backdrop(back, plan, look)
		for v in views:
			CityStreets.backdrop(back, plan, look, v)
		tris += _add(back, "Backdrop", self, false)

	var shapes := _build_collision()
	for g in find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).layers = render_layer

	if with_rig:
		if rig == null:
			rig = CityLightRig.new()
			add_child(rig)
		rig.setup(ring, plan.extent, plan.p("ceiling"), strip_x)
	stats = {"triangles": tris, "shapes": shapes, "buildings": plan.buildings.size(), "props": props.items.size(), "ms": Time.get_ticks_msec() - t0}


## The upright frame building i is built in: origin on the sidewalk under its centre, Y radial.
func building_frame(i: int) -> Transform3D:
	var c: Vector2 = plan.buildings[i]["center"]
	return Transform3D(CityGeo.frame_basis(ring, c.y), ring.arc_to_world(c.x, c.y, CityPlan.CURB_H))


## The frame a pillar's core is built in: on the radial line through its structural point (shared by every deck).
func core_frame(i: int) -> Transform3D:
	var b: Dictionary = plan.buildings[i]
	if not b["pillar"]:
		return building_frame(i)
	return _frame_at(b["core"]["x"], b["core"]["s"])


func _frame_at(x: float, s: float) -> Transform3D:
	return Transform3D(CityGeo.frame_basis(ring, s), ring.arc_to_world(x, s, CityPlan.CURB_H))


## A number that changes when any vertex or surface colour changes. Lighting must never move it.
func geometry_digest() -> int:
	return _digest


func set_ceiling_visible(on: bool) -> void:
	for n in ["Ceiling", "Strips"]:
		var node := get_node_or_null(n) as Node3D
		if node != null:
			node.visible = on


func set_backdrop_visible(on: bool) -> void:
	var node := get_node_or_null("Backdrop") as Node3D
	if node != null:
		node.visible = on


func _add(geo: CityGeo, node_name: String, parent: Node, shadows: bool = true) -> int:
	var mi := geo.instance(node_name)
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_digest = hash([_digest, geo.verts, geo.colors])
	return geo.tri_count()


# --- Collision -------------------------------------------------------------------------------------------

func _build_collision() -> int:
	var body := StaticBody3D.new()
	body.name = "Collision"
	add_child(body)
	var geo := CityGeo.new(ring)
	var e := plan.extent.grow(14.0)
	var count := 0
	var ceiling := plan.p("ceiling")
	var holes := plan.floor_cuts()
	# Deck and ceiling: one slab per facet, the deck left open over the floor holes.
	var br := CityGeo.breaks(e.position.y, e.end.y)
	for k in br.size() - 1:
		var mid := (br[k] + br[k + 1]) * 0.5
		var length := geo.g_point(0.0, br[k]).distance_to(geo.g_point(0.0, br[k + 1]))
		for q in CityGeo.cut(Rect2(e.position.x, br[k], e.size.x, br[k + 1] - br[k]), holes):
			var piece := length * q.size.y / (br[k + 1] - br[k])
			_shape(body, geo.frame(q.get_center().x, q.get_center().y, 0.0), Vector3(0, -0.5, 0), Vector3(q.size.x, 1.0, piece + SEAM))
			count += 1
		# The ceiling, left open where the deck above has a hole.
		var spans := [[e.position.x, e.end.x]]
		for o: Rect2 in plan.site.openings:
			var hole := CityStreets.ceiling_opening(o)
			if mid < hole.position.y or mid > hole.end.y:
				continue
			var cut := []
			for sp: Array in spans:
				if hole.position.x > sp[0]:
					cut.append([sp[0], minf(sp[1], hole.position.x)])
				if hole.end.x < sp[1]:
					cut.append([maxf(sp[0], hole.end.x), sp[1]])
			spans = cut
		for sp: Array in spans:
			if sp[1] - sp[0] > 0.1:
				_shape(body, geo.frame((sp[0] + sp[1]) * 0.5, mid, ceiling), Vector3(0, 0.5, 0), Vector3(sp[1] - sp[0], 1.0, length + SEAM))
				count += 1
	# Boundary walls: solid floor to ceiling except across a portal (the way in or out), which keeps only its lintel.
	for w: Dictionary in plan.boundary():
		var side: int = w["side"]
		var across := side >= 2
		var out := 1.0 if side % 2 == 0 else -1.0
		var at: float = w["at"] + out * CityStreets.WALL_THICK * 0.5
		var thick := CityStreets.WALL_THICK
		var portals := []
		for g: Dictionary in w["gates"]:
			if g["kind"] == "portal":
				portals.append(g)
		var u0 := e.position.x if across else e.position.y
		var u1 := e.end.x if across else e.end.y
		for sp: Array in CityStreets.wall_spans(u0, u1, portals):
			count += _wall_box(body, geo, across, at, sp[0], sp[1], -1.0, ceiling + 1.0, thick)
		for g: Dictionary in portals:
			count += _wall_box(body, geo, across, at, g["a"], g["b"], g["h"], ceiling + 1.0, thick)
	# Sidewalk slabs (open over a floor hole), and the solid curb round each hole.
	var th := CityPlan.CURB_H + 0.5
	for b: Dictionary in plan.blocks:
		for q in CityGeo.cut(b["rect"], holes):
			count += _ground_box(body, geo, q, CityPlan.CURB_H - th, CityPlan.CURB_H)
	var c := CityStreets.HOLE_CURB
	for o in holes:
		var open := plan.ramp_mouth(o)
		var c0 := 0.0 if open == 3 else c
		var c1 := 0.0 if open == 2 else c
		var curbs: Array[Rect2] = [Rect2(o.position.x - c, o.position.y - c0, c, o.size.y + c0 + c1), Rect2(o.end.x, o.position.y - c0, c, o.size.y + c0 + c1)]
		if open != 3:
			curbs.append(Rect2(o.position.x, o.position.y - c, o.size.x, c))
		if open != 2:
			curbs.append(Rect2(o.position.x, o.end.y, o.size.x, c))
		for q in curbs:
			count += _ground_box(body, geo, q, 0.0, c)
	for r: Dictionary in plan.ramps:
		count += _ramp_collision(body, geo, r)
	# Building tiers.
	for i in plan.buildings.size():
		var xf := building_frame(i)
		for t: Dictionary in plan.buildings[i]["tiers"]:
			var y0: float = -1.0 if float(t["y0"]) <= 0.0 else float(t["y0"])
			var y1: float = t["y1"]
			_shape(body, xf, Vector3((t["off"] as Vector2).x, (y0 + y1) * 0.5, (t["off"] as Vector2).y),
					Vector3((t["size"] as Vector2).x, y1 - y0, (t["size"] as Vector2).y))
			count += 1
		# The plan's smaller solids (civic columns and steps, skylights) and the civic gable: the same numbers the
		# meshes are drawn from (docs/design/city-rooftops.md).
		for so: Dictionary in plan.buildings[i].get("solids", []):
			var off: Vector2 = so["off"]
			var sz: Vector2 = so["size"]
			var y0 := float(so["y0"])
			var y1 := float(so["y1"])
			if so["kind"] == "skylight":
				_convex(body, xf, skylight_points(so))
			else:
				_shape(body, xf, Vector3(off.x, (y0 + y1) * 0.5, off.y), Vector3(sz.x, y1 - y0, sz.y))
			count += 1
		if plan.buildings[i].has("gable"):
			_convex(body, CityBuildings.gable_frame(xf, plan.buildings[i]["gable"]), gable_points(plan.buildings[i]["gable"]))
			count += 1
		if plan.buildings[i]["pillar"]:
			var cs: Vector2 = plan.buildings[i]["core"]["size"]
			_shape(body, core_frame(i), Vector3(0, ceiling * 0.5, 0), Vector3(cs.x, ceiling + 2.0, cs.y))
			count += 1
	for col: Dictionary in plan.columns:
		var w := float(col["half"]) * 2.0
		var cf := _frame_at(col["x"], col["s"])
		_shape(body, cf, Vector3(0, ceiling * 0.5, 0), Vector3(w, ceiling + 2.0, w))
		_convex(body, cf, ring_points(col))      # the planted stone ring round its foot
		count += 2
	return count


## A civic gable as a convex prism in its own frame (CityBuildings.gable_frame): the eaves rectangle and the ridge.
static func gable_points(g: Dictionary) -> PackedVector3Array:
	var hw := float(g["w"]) * 0.5
	var hd := float(g["d"]) * 0.5
	var rise := float(g["rise"])
	return PackedVector3Array([Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd), Vector3(hw, 0, hd), Vector3(-hw, 0, hd),
			Vector3(0, rise, -hd), Vector3(0, rise, hd)])


## A skylight's solid part, its concrete curb, as a box in the building frame (its glass ridge, 0.7 m more, is drawn only:
## a ridge or a hip there wedged the mech's capsule, while a 0.4 m curb is walked onto from any side).
static func skylight_points(so: Dictionary) -> PackedVector3Array:
	var off: Vector2 = so["off"]
	var h: Vector2 = (so["size"] as Vector2) * 0.5
	var out := PackedVector3Array()
	for k: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		out.append(Vector3(off.x + k.x * h.x, float(so["y0"]) - 0.1, off.y + k.y * h.y))
		out.append(Vector3(off.x + k.x * h.x, float(so["y1"]), off.y + k.y * h.y))
	return out


## A park column's planted ring as the octagonal prism it is drawn as (CityBuildings.column), in the column's frame.
static func ring_points(col: Dictionary) -> PackedVector3Array:
	var r := float(col["ring_r"])
	var out := PackedVector3Array()
	for i in 8:
		var a := TAU * (float(i) + 0.5) / 8.0
		var d := Vector3(cos(a), 0, -sin(a)) * r
		out.append(d + Vector3(0, -1.0, 0))
		out.append(d + Vector3(0, float(col["ring_h"]), 0))
	return out


## A ramp part a mech can walk: per facet piece one box tilted to the slope with its top face on the ribbon (reaching
## down to the floor along the embankment), one per parapet (PARAPET_GUARD tall, over the drawn 1 m) and one per edge beam, so neighbouring pieces meet with no
## step; the parapets' end blocks; per pier its plinth, shaft, cross-head and cross beam.
func _ramp_collision(body: StaticBody3D, geo: CityGeo, r: Dictionary) -> int:
	var span := CityStreets.ramp_span(r, plan.site.slab)
	var x0 := float(r["x0"])
	var x1 := float(r["x1"])
	var mid := (x0 + x1) * 0.5
	var br := CityGeo.breaks(span.x, span.y)
	var emb := CityStreets.embankment_s(r)
	if not is_nan(emb) and emb > span.x and emb < span.y:
		br.append(emb)
		br.sort()
	var count := 0
	for k in br.size() - 1:
		var ha := CityPlan.ramp_height(r, br[k])
		var hb := CityPlan.ramp_height(r, br[k + 1])
		var a := geo.g_point(mid, br[k], ha)
		var b := geo.g_point(mid, br[k + 1], hb)
		var z := (b - a).normalized()
		var y := z.cross(Vector3.RIGHT)
		var xf := Transform3D(Basis(Vector3.RIGHT, y, z), (a + b) * 0.5)
		var length := a.distance_to(b) + SEAM
		var thick := CityStreets.RAMP_THICK
		var on_bank := not is_nan(emb) and maxf(ha, hb) <= CityStreets.PIER_MIN + 0.01
		if on_bank:
			thick = maxf(ha, hb) + 0.5
		_shape(body, xf, Vector3(0, -thick * 0.5, 0), Vector3(x1 - x0, thick, length))
		for side: float in [-1.0, 1.0]:
			# Taller than drawn (PARAPET_GUARD): a mech would step over the 1 m parapet.
			_shape(body, xf, Vector3(side * ((x1 - x0) - CityStreets.PARAPET_W) * 0.5, CityStreets.PARAPET_GUARD * 0.5, 0),
					Vector3(CityStreets.PARAPET_W, CityStreets.PARAPET_GUARD, length))
			if not on_bank:      # the edge beam under the soffit
				_shape(body, xf, Vector3(side * ((x1 - x0) - CityStreets.BEAM_W) * 0.5, -CityStreets.RAMP_THICK - CityStreets.BEAM_D * 0.5, 0),
						Vector3(CityStreets.BEAM_W, CityStreets.BEAM_D, length))
				count += 1
		count += 3
	# The parapets' end blocks, and each pier: plinth, shaft, cross-head (with its haunch) and the cross beam.
	for eb in CityStreets.end_blocks(r, span):
		var bh := CityStreets.END_H + 0.3
		_shape(body, geo.frame(eb.x, eb.y, eb.z), Vector3(0, CityStreets.END_H - bh * 0.5, 0), Vector3(CityStreets.END_W, bh, CityStreets.END_L))
		count += 1
	for s in CityStreets.pier_s(r, plan):
		var hp := CityStreets.pier_heights(r, s)
		var f := geo.frame(mid, s, 0.0)
		var pw := CityStreets.PLINTH_W
		_shape(body, f, Vector3(0, CityStreets.PLINTH_H * 0.5, 0), Vector3(pw, CityStreets.PLINTH_H, pw))
		var top := float(hp["cap_bot"])
		_shape(body, f, Vector3(0, top * 0.5, 0), Vector3(CityStreets.PIER_W, top, CityStreets.PIER_W))
		var cap0 := float(hp["cap_bot"]) - CityStreets.HAUNCH * 0.5      # the haunch's upper half counts as cap
		_shape(body, f, Vector3(0, (cap0 + float(hp["cap_top"])) * 0.5, 0), Vector3(CityStreets.CAP_W, float(hp["cap_top"]) - cap0, CityStreets.CAP_L))
		_shape(body, CityStreets.ramp_frame(geo, r, mid, s, -CityStreets.RAMP_THICK), Vector3(0, -CityStreets.CROSS_D * 0.5, 0),
				Vector3(x1 - x0 - 0.1, CityStreets.CROSS_D, CityStreets.CROSS_L))
		count += 4
	return count


## A box over the ground rectangle `r` from height y0 to y1, one piece per facet.
func _ground_box(body: StaticBody3D, geo: CityGeo, r: Rect2, y0: float, y1: float) -> int:
	var br := CityGeo.breaks(r.position.y, r.end.y)
	for k in br.size() - 1:
		_shape(body, geo.frame(r.get_center().x, (br[k] + br[k + 1]) * 0.5, y1), Vector3(0, (y0 - y1) * 0.5, 0),
				Vector3(r.size.x, y1 - y0, br[k + 1] - br[k] + SEAM))
	return br.size() - 1


## A slab of wall centred on `at` from u0 to u1 along it and y0 to y1 up: one box across the arc, facet boxes along it.
func _wall_box(body: StaticBody3D, geo: CityGeo, across: bool, at: float, u0: float, u1: float, y0: float, y1: float, thick: float) -> int:
	if u1 - u0 < 0.1:
		return 0
	if across:
		_shape(body, geo.frame((u0 + u1) * 0.5, at, (y0 + y1) * 0.5), Vector3.ZERO, Vector3(u1 - u0, y1 - y0, thick))
		return 1
	var br := CityGeo.breaks(u0, u1)
	for k in br.size() - 1:
		_shape(body, geo.frame(at, (br[k] + br[k + 1]) * 0.5, (y0 + y1) * 0.5), Vector3.ZERO, Vector3(thick, y1 - y0, br[k + 1] - br[k] + SEAM))
	return br.size() - 1


func _convex(body: StaticBody3D, xf: Transform3D, points: PackedVector3Array) -> void:
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	cs.shape = shape
	cs.transform = xf
	body.add_child(cs)


func _shape(body: StaticBody3D, xf: Transform3D, center: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = xf * Transform3D(Basis.IDENTITY, center)
	body.add_child(cs)
