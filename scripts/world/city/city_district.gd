class_name CityDistrict
extends Node3D
## One generated urban district standing on a ring deck: the nodes for a CityPlan. Children:
##   Ground, Ramps, Buildings/Block<n>, Furniture, Walls, Ceiling, Strips, Backdrop   meshes (flat palette colours, one lit material)
##   FarmLights                                                         a farm wall's light bars (CityPalette.farm_light_material)
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
## Collision height of a ramp parapet's end block over the ribbon (drawn CityStreets.END_H, 1.3 m). A box corner a mech
## capsule can walk round must be either low enough to step onto or taller than the capsule's straight side (the Strider's
## reaches 5.8 m): a corner whose top is in between (the 1.3 m block, the 2.5 m parapet guard, tried at 4 m too) met the
## capsule's side with contacts that Godot's capsule-box solver let it sink into and then never left, every
## move_and_slide blocked (section seed 9, deck 1, x -58 s -101; tests/test_ramp_stuck.gd). At 6.5 m the block, an
## invisible post above the drawn 1.3 m, also covers the parapet guard's end corners.
const END_GUARD := 6.5
const PORTAL_PLATE := 1.0    ## m: the back plate sealing a portal's recess (_col_walls)

var _digest := 0

## INCREMENTAL BUILD (docs/design/city-ramps-and-stack.md section 8, "Incremental build"). A build is a queue of chunks
## run in order, one per build_step(); build() / build_deck() run the same queue to the end in one call, so a stepped
## build gives exactly the same nodes, digest, stats and `look` draws. The first chunk makes the plan and queues the rest
## (their number depends on the plan). Chunk sizes below keep every chunk under ~20 ms on the dev PC.
const BUILDINGS_PER_CHUNK := 16         ## buildings meshed (into their block's CityGeo) per chunk
const BLOCKS_PER_CHUNK := 6             ## finished block meshes instanced per chunk
const SHAPE_BUILDINGS_PER_CHUNK := 60   ## buildings whose collision shapes are made per chunk
const CEILING_BAYS_PER_CHUNK := 2       ## CityStreets.ceiling_range girder bays per chunk (~4-5 ms each)
const CEILING_LINES_PER_CHUNK := 16     ## and girder lines per chunk (~0.7 ms each)
const FARM_PARTS := 2                   ## chunks per farm wall side (CityStreets.walls part / parts)

var _queue: Array = []                  ## [label, Callable] chunks of the build in progress, in order
var _qi := 0                            ## next chunk to run
var _plan_maker: Callable               ## the first chunk: returns the CityPlan
var chunk_label := ""                   ## label of the last chunk run ("buildings 2/5")
var chunk_ms := 0.0                     ## its time
var _b_us := 0                          ## usec spent in this build's chunks (stats.ms)
var _look: RandomNumberGenerator        ## the build's cosmetic generator (seeded once, drawn in chunk order)
var _tris := 0
var _per_block: Array[CityGeo] = []
var _holder: Node3D
var _body: StaticBody3D
var _cgeo: CityGeo
var _holes: Array[Rect2] = []
var _shapes := 0
var _walled := false
var _open_edge := false
var _views: Array[Rect2] = []
var _area := Rect2()                    ## the ceiling's area
var _ground_geo: CityGeo
var _ceil_geo: CityGeo
var _strip_geo: CityGeo
var _wall_geo: CityGeo
var _wall_lights: CityGeo


func build(params: Dictionary = {}, given: CitySite = null) -> void:
	build_begin(params, given)
	while not build_step():
		pass


## One whole deck of a mission section (CityPlan.for_deck): the same children and collision as build().
func build_deck(section: SectionPlan, deck: int, overrides: Dictionary = {}) -> void:
	build_deck_begin(section, deck, overrides)
	while not build_step():
		pass


## Start build() without running it: frees the old children (not the rig); build_step() does the rest.
func build_begin(params: Dictionary = {}, given: CitySite = null) -> void:
	_begin(func() -> CityPlan: return CityPlan.make(params, given))


## Start build_deck() without running it.
func build_deck_begin(section: SectionPlan, deck: int, overrides: Dictionary = {}) -> void:
	_begin(func() -> CityPlan: return CityPlan.for_deck(section, deck, overrides))


## Run ONE chunk of the build in progress; true once the build is finished (and on every later call).
func build_step() -> bool:
	if _qi >= _queue.size():
		return true
	var t := Time.get_ticks_usec()
	var c: Array = _queue[_qi]
	_qi += 1
	chunk_label = c[0]
	(c[1] as Callable).call()
	var dt := Time.get_ticks_usec() - t
	_b_us += dt
	chunk_ms = float(dt) / 1000.0
	if _qi >= _queue.size():
		stats["ms"] = float(_b_us) / 1000.0
		_queue.clear()
		_qi = 0
		return true
	return false


## True when no build is in progress (plan, ring, props, stats are the last finished build's).
func build_done() -> bool:
	return _qi >= _queue.size()


## 0..1 through the build in progress (1 when done); never goes down during one build.
func build_progress() -> float:
	if _queue.is_empty():
		return 1.0
	return float(_qi) / float(_queue.size())


func _begin(maker: Callable) -> void:
	for c in get_children():
		if c != rig:
			remove_child(c)
			c.queue_free()
	_plan_maker = maker
	_queue = [["plan", _c_plan]]
	_qi = 0
	_b_us = 0
	_per_block.clear()
	_holder = null
	_body = null


func _c_plan() -> void:
	plan = _plan_maker.call()
	ring = RingFrame.new(plan.p("radius"))
	_look = RandomNumberGenerator.new()
	_look.seed = plan.cosmetic_seed()
	_digest = 0
	_tris = 0
	_shapes = 0
	# Walls, backdrop views and the ceiling's area: plan data only, needed now to know how many ceiling chunks to queue.
	var bounds := plan.boundary()
	_walled = not bounds.is_empty()
	# The backdrop: all round an open district, or beyond each window wall that looks out onto it (a farm wall is solid:
	# nothing beyond it, and the ceiling stops at the walls).
	_open_edge = with_backdrop and not _walled
	_views.clear()
	if with_backdrop:
		for w: Dictionary in bounds:
			if w["backdrop"]:
				_views.append(CityStreets.backdrop_edge(plan, int(w["side"])))
	_area = CityStreets.backdrop_area(plan) if _open_edge else plan.extent.grow(1.0 if _walled else 14.0)
	for v in _views:
		_area = _area.merge(v)
	var gp := CityStreets.ground_parts(plan)
	for part in gp:
		_queue.append(["ground %d/%d" % [part + 1, gp], _c_ground.bind(part, part == gp - 1)])
	if not plan.ramps.is_empty():
		_queue.append(["ramps", _c_ramps])
	var nb := plan.buildings.size()
	var batches := _building_batches()
	var n := batches.size()
	for j in n:
		_queue.append(["buildings %d/%d" % [j + 1, n], _c_buildings.bind(batches[j].x, batches[j].y)])
	if not plan.columns.is_empty():
		_queue.append(["columns", _c_columns])
	n = ceili(float(plan.blocks.size()) / BLOCKS_PER_CHUNK)
	for j in n:
		_queue.append(["blocks %d/%d" % [j + 1, n], _c_blocks.bind(j * BLOCKS_PER_CHUNK, mini((j + 1) * BLOCKS_PER_CHUNK, plan.blocks.size()))])
	_queue.append(["props", _c_props])
	_queue.append(["furniture", _c_furniture])
	# One wall side per chunk, a farm side in FARM_PARTS chunks along its length (its triangles are the heaviest).
	var wparts: Array = []
	for w: Dictionary in bounds:
		for p in (FARM_PARTS if w["kind"] == "farm" else 1):
			wparts.append([int(w["side"]), p, FARM_PARTS if w["kind"] == "farm" else 1])
	for i in wparts.size():
		_queue.append(["walls %d/%d" % [i + 1, wparts.size()], _c_walls.bind(wparts[i][0], wparts[i][1], wparts[i][2], i == 0, i == wparts.size() - 1)])
	_queue.append(["signs", _c_signs])      # deck lettering (CitySigns): cosmetic, not in the digest
	# Ceiling: the girder bays (panels, strip, ribs: heavy) a few per chunk, then the girder lines and openings (light).
	var steps := CityStreets.ceiling_steps(_area)
	var bays := (steps - 2) / 2
	var cuts: Array[int] = []
	for a in range(0, bays, CEILING_BAYS_PER_CHUNK):
		cuts.append(a)
	for a in range(bays, steps, CEILING_LINES_PER_CHUNK):
		cuts.append(a)
	cuts.append(steps)
	for j in cuts.size() - 1:
		_queue.append(["ceiling %d/%d" % [j + 1, cuts.size() - 1], _c_ceiling.bind(cuts[j], cuts[j + 1])])
	_queue.append(["ceiling mesh", _c_ceiling_mesh])
	_queue.append(["strips mesh", _c_strips_mesh])
	_queue.append(["backdrop", _c_backdrop])
	_queue.append(["shapes floor", _col_floor])
	_queue.append(["shapes walls", _col_walls])
	_queue.append(["shapes ramps", _col_ramps])
	n = maxi(ceili(float(nb) / SHAPE_BUILDINGS_PER_CHUNK), 1)
	for j in n:
		_queue.append(["shapes buildings %d/%d" % [j + 1, n], _col_buildings.bind(j * SHAPE_BUILDINGS_PER_CHUNK, mini((j + 1) * SHAPE_BUILDINGS_PER_CHUNK, nb))])
	_queue.append(["finish", _c_finish])


## The building meshing chunks [a, b) as Vector2i: BUILDINGS_PER_CHUNK buildings each, a downtown tower counting as
## TOWER_WEIGHT of them (its facade runs up to the ceiling). Without towers: every BUILDINGS_PER_CHUNK, as always.
const TOWER_WEIGHT := 4
func _building_batches() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var nb := plan.buildings.size()
	var a := 0
	var w := 0
	for i in nb:
		w += TOWER_WEIGHT if plan.buildings[i]["style"] == "tower" else 1
		if w >= BUILDINGS_PER_CHUNK:
			out.append(Vector2i(a, i + 1))
			a = i + 1
			w = 0
	if a < nb or out.is_empty():
		out.append(Vector2i(a, nb))
	return out


func _c_ground(part: int, last: bool) -> void:
	if part == 0:
		_ground_geo = CityGeo.new(ring)
	CityStreets.ground_part(_ground_geo, plan, part)
	if last:
		_tris += _add(_ground_geo, "Ground", self)
		_ground_geo = null


func _c_ramps() -> void:
	var ramp_geo := CityGeo.new(ring)
	CityStreets.ramps(ramp_geo, plan)
	_tris += _add(ramp_geo, "Ramps", self)


## Buildings a..b-1 meshed into their block's CityGeo (instanced in _c_blocks once every building is in).
func _c_buildings(a: int, b: int) -> void:
	if a == 0:
		_holder = Node3D.new()
		_holder.name = "Buildings"
		add_child(_holder)
		_per_block.clear()
		for i in plan.blocks.size():
			_per_block.append(CityGeo.new(ring))
	for i in range(a, b):
		var bd: Dictionary = plan.buildings[i]
		var geo := _per_block[int(plan.lots[bd["lot"]]["block"])]
		CityBuildings.build(geo, building_frame(i), core_frame(i), plan, i, _look)


func _c_columns() -> void:
	var cols := CityGeo.new(ring)
	for c: Dictionary in plan.columns:
		CityBuildings.column(cols, _frame_at(c["x"], c["s"]), c, plan.p("ceiling"))
	_tris += _add(cols, "Columns", _holder)


func _c_blocks(a: int, b: int) -> void:
	for i in range(a, b):
		if not _per_block[i].is_empty():
			_tris += _add(_per_block[i], "Block%d" % i, _holder)
		_per_block[i] = null      # its mesh is committed: let the CityGeo go


func _c_props() -> void:
	props = CityProps.new()
	props.deck = plan.deck if plan.section != null else -1   # stack decks tag their prop events (CityProps.deck)
	props.setup(plan, ring)


func _c_furniture() -> void:
	var furn := CityGeo.new(ring)
	CityStreets.furniture(furn, plan, props.items)
	var bulbs := CityGeo.new(ring)
	if not plan.forms.is_empty():
		CityStreets.string_lights(furn, bulbs, plan)
	_tris += _add(furn, "Furniture", self)
	if not bulbs.is_empty():
		# Pedestrian streets' string lights: emissive bulbs (the farm walls' warm light material), no Light3D, no shadows.
		var lights := bulbs.instance("StringLights", CityPalette.farm_light_material())
		lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lights.layers = render_layer
		add_child(lights)
		_digest = hash([_digest, bulbs.verts])
		_tris += bulbs.tri_count()
	for g in props.find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).layers = render_layer      # props is not in the tree yet
	add_child(props)
	_tris += props.tri_count()


## Wall `side` into the walls' geos; the last side instances them (Walls, and FarmLights when a farm wall has bars).
func _c_walls(side: int, part: int, parts: int, first: bool, last: bool) -> void:
	if first:
		_wall_geo = CityGeo.new(ring)
		_wall_lights = CityGeo.new(ring)
	CityStreets.walls(_wall_geo, plan, _wall_lights, side, part, parts)
	if not last:
		return
	var lights := _wall_lights
	_tris += _add(_wall_geo, "Walls", self, false)
	_wall_geo = null
	_wall_lights = null
	# A farm wall's light bars: the ceiling strips' emissive material (the rig owns its glow), no Light3D, no shadows.
	if not lights.is_empty():
		var bars := lights.instance("FarmLights", CityPalette.farm_light_material())
		bars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bars.layers = render_layer      # before it enters the tree (see _c_finish)
		add_child(bars)
		_digest = hash([_digest, lights.verts])
		_tris += lights.tri_count()


## Deck lettering (CitySigns, docs/design/city-signs.md): node "DeckSigns" in the current CitySigns.style. Cosmetic: kept
## out of geometry_digest() and stats.triangles (its own stats.sign_triangles), so switching the look moves nothing else.
var sign_tris := 0
func _c_signs() -> void:
	sign_tris = 0
	var mi := CitySigns.build_node(plan, ring, render_layer)      # layers set before it enters the tree
	if mi != null:
		add_child(mi)
		sign_tris = int(mi.get_meta("tris", 0))


## Rebuild the lettering alone (after CitySigns.style changed): the rest of the district is untouched.
func rebuild_signs() -> void:
	if plan == null or not build_done():
		return
	var old := get_node_or_null("DeckSigns")
	if old != null:
		remove_child(old)
		old.queue_free()
	_c_signs()
	stats["sign_triangles"] = sign_tris


## Ceiling steps a..b-1 (CityStreets.ceiling_range) into the ceiling and strip geos; _c_ceiling_mesh instances them.
func _c_ceiling(a: int, b: int) -> void:
	if a == 0:
		_ceil_geo = CityGeo.new(ring)
		_strip_geo = CityGeo.new(ring)
		strip_x = PackedFloat32Array()
	strip_x.append_array(CityStreets.ceiling_range(_ceil_geo, _strip_geo, _area, plan, _look, a, b))


func _c_ceiling_mesh() -> void:
	_tris += _add(_ceil_geo, "Ceiling", self, false)
	_ceil_geo = null


func _c_strips_mesh() -> void:
	var strip_node := _strip_geo.instance("Strips", CityPalette.strip_material())
	strip_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	strip_node.layers = render_layer
	add_child(strip_node)
	_tris += _strip_geo.tri_count()
	_strip_geo = null


func _c_backdrop() -> void:
	if _open_edge or not _views.is_empty():
		var back := CityGeo.new(ring)
		if _open_edge:
			CityStreets.backdrop(back, plan, _look)
		for v in _views:
			CityStreets.backdrop(back, plan, _look, v)
		_tris += _add(back, "Backdrop", self, false)


func _c_finish() -> void:
	# Every mesh got render_layer when it was made, before entering the tree: changing `layers` on an in-tree instance
	# while lights exist (a rebuild under a stack whose rig keeps its fills) leaves stale light pairings on Forward+
	# ("indexing did not unpair geometries from light"). This pass only catches a node made without it (a no-op otherwise).
	for g in find_children("*", "GeometryInstance3D", true, false):
		if (g as GeometryInstance3D).layers != render_layer:
			(g as GeometryInstance3D).layers = render_layer
	if with_rig:
		if rig == null:
			rig = CityLightRig.new()
			add_child(rig)
		rig.setup(ring, plan.extent, plan.p("ceiling"), strip_x)
	stats = {"triangles": _tris, "shapes": _shapes, "buildings": plan.buildings.size(), "props": props.items.size(), "ms": float(_b_us) / 1000.0,
			"sign_triangles": sign_tris}
	_per_block.clear()
	_cgeo = null


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
	mi.layers = render_layer      # before it enters the tree (see _c_finish)
	parent.add_child(mi)
	_digest = hash([_digest, geo.verts, geo.colors])
	return geo.tri_count()


# --- Collision -------------------------------------------------------------------------------------------

## The collision is made in chunks, in this order (the shapes' order under Collision is the same as one pass):
## _col_floor (deck and ceiling slabs), _col_walls (boundary walls, sidewalks, hole curbs), _col_ramps, _col_buildings
## (in batches, the last one adds the park columns). Each adds its count to _shapes.
func _col_floor() -> void:
	_body = StaticBody3D.new()
	_body.name = "Collision"
	add_child(_body)
	_cgeo = CityGeo.new(ring)
	_holes = plan.floor_cuts()
	var body := _body
	var geo := _cgeo
	var e := plan.extent.grow(14.0)
	var count := 0
	var ceiling := plan.p("ceiling")
	var holes := _holes
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
	_shapes += count


func _col_walls() -> void:
	var body := _body
	var geo := _cgeo
	var e := plan.extent.grow(14.0)
	var count := 0
	var ceiling := plan.p("ceiling")
	var holes := _holes
	# Boundary walls: solid floor to ceiling except across a portal (the way in or out), which keeps its lintel and is
	# closed behind by a plate at the back of its drawn recess (a mech steps into the recess, no further).
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
			# The portal's recess is sealed where it is drawn (CityStreets._recess, GATE_RECESS deep): a back plate there,
			# PORTAL_PLATE thick, reaching a little into the recess and past its sides and roof so no seam opens. The
			# recess's sides and roof are the wall slab beside the gate and the lintel (the recess is no deeper than the wall).
			var back := float(w["at"]) + out * (CityStreets.GATE_RECESS - 0.05 + PORTAL_PLATE * 0.5)
			count += _wall_box(body, geo, across, back, float(g["a"]) - 1.0, float(g["b"]) + 1.0, -1.0, float(g["h"]) + 1.0, PORTAL_PLATE + 0.1)
	# Sidewalk slabs (open over a floor hole), and the solid curb round each hole.
	var th := CityPlan.CURB_H + 0.5
	for b: Dictionary in plan.blocks:
		for q in CityGeo.cut(b["rect"], holes):
			count += _ground_box(body, geo, q, CityPlan.CURB_H - th, CityPlan.CURB_H)
	# Ground a road form raises to the sidewalk (a superblock's court, a lane's planting bands: CityPlan.raised).
	for rq: Dictionary in plan.raised:
		for q in CityGeo.cut(rq["rect"], holes):
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
	_shapes += count


func _col_ramps() -> void:
	for r: Dictionary in plan.ramps:
		_shapes += _ramp_collision(_body, _cgeo, r)


## Building tiers, solids, gables and pillar cores of buildings a..b-1; the last batch adds the park columns too.
func _col_buildings(a: int, b: int) -> void:
	var body := _body
	var count := 0
	var ceiling := plan.p("ceiling")
	for i in range(a, b):
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
	if b >= plan.buildings.size():
		for col: Dictionary in plan.columns:
			var w := float(col["half"]) * 2.0
			var cf := _frame_at(col["x"], col["s"])
			_shape(body, cf, Vector3(0, ceiling * 0.5, 0), Vector3(w, ceiling + 2.0, w))
			_convex(body, cf, ring_points(col))      # the planted stone ring round its foot
			count += 2
	_shapes += count


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
## down to the floor along the embankment), one convex prism per parapet (PARAPET_GUARD tall, over the drawn 1 m) and one
## box per edge beam, so neighbouring pieces meet with no step; the parapets' end blocks (END_GUARD tall); per pier its
## plinth, shaft, cross-head and cross beam.
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
		# Parapet ends: square to the deck (as drawn), not square to the slope. A box tilted to the slope ended in a face
		# leaning PARAPET_GUARD * slope out past the ramp's end (0.4 m at a 9 deg foot), an invisible overhang whose
		# corner pinned a mech capsule walking into it from beside the foot against the floor (section seed 9, deck 1,
		# x -58 s -101: no move in any direction). Each piece overlaps its neighbour by SEAM (as before), not past the
		# ramp's own two ends.
		var da := 0.0 if k == 0 else SEAM * 0.5
		var db := 0.0 if k == br.size() - 2 else SEAM * 0.5
		for side: float in [-1.0, 1.0]:
			# Taller than drawn (PARAPET_GUARD): a mech would step over the 1 m parapet.
			var xo := x0 if side < 0.0 else x1
			var xi := xo - side * CityStreets.PARAPET_W
			_convex(body, Transform3D.IDENTITY, _parapet_points(geo, xo, xi, br[k], br[k + 1], ha, hb, da, db))
			if not on_bank:      # the edge beam under the soffit
				_shape(body, xf, Vector3(side * ((x1 - x0) - CityStreets.BEAM_W) * 0.5, -CityStreets.RAMP_THICK - CityStreets.BEAM_D * 0.5, 0),
						Vector3(CityStreets.BEAM_W, CityStreets.BEAM_D, length))
				count += 1
		count += 3
	# The parapets' end blocks, and each pier: plinth, shaft, cross-head (with its haunch) and the cross beam.
	# An end block's collision is END_GUARD tall (invisible above the drawn END_H), so it also swallows the parapet's end.
	for eb in CityStreets.end_blocks(r, span):
		var bh := END_GUARD + 0.3
		_shape(body, geo.frame(eb.x, eb.y, eb.z), Vector3(0, END_GUARD - bh * 0.5, 0), Vector3(CityStreets.END_W, bh, CityStreets.END_L))
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


## One facet piece of a ramp parapet (x from xo to xi, s from sa to sb, ribbon heights ha / hb there) as a convex prism
## PARAPET_GUARD tall over the ribbon, its ends square to the faceted deck like the drawn parapet's, each end pushed out
## along the slope by da / db (the SEAM overlap with the next piece; 0 at the ramp's own ends, flush with the drawn end).
static func _parapet_points(geo: CityGeo, xo: float, xi: float, sa: float, sb: float, ha: float, hb: float, da: float,
		db: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for xx: float in [xo, xi]:
		var a := geo.g_point(xx, sa, ha)
		var b := geo.g_point(xx, sb, hb)
		var along := (b - a).normalized()
		var ua := geo.g_point(xx, sa, ha + CityStreets.PARAPET_GUARD) - a
		var ub := geo.g_point(xx, sb, hb + CityStreets.PARAPET_GUARD) - b
		a -= along * da
		b += along * db
		out.append_array([a, a + ua, b, b + ub])
	return out


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
