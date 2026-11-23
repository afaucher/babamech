class_name CityStreets
extends RefCounted
## Everything between the buildings, as flat-shaded geometry on the faceted ring deck: the deck, road surfaces and
## markings, gutters, curbs, sidewalks with corner ramps, open lots and the park, fixed street furniture and the prop shapes, the ceiling (underside
## of the next deck: panels, ribs, girders, light strips) and a low-detail backdrop past the district's edge.
## Cross-section of a street, from the centre line out:
##   lane | parking strip | gutter (dark, 0.5) | curb (pale, 0.3, +0.2 m) | furnishing band (trees, lamps; 1.3) |
##   walkway (2.4) | building line
## At every corner the curb drops in a ramp lined up with the crosswalk.

const CURB := CityPlan.CURB_H
const EDGE := 1.6            ## curb + furnishing band
const RAMP_A := 2.1          ## ramp span along the block edge, measured from the corner
const RAMP_B := 4.5
## DECALS (docs/design/city-geometry-audit.md): flat patches and markings without collision lie on their surface in
## fixed layers 2 cm apart, never closer (closer than that, two flat-shaded faces of different colours shimmer at game
## distances; tools/geometry_audit/ checks it):
##   layer 1 DECAL_PATCH  patches on the bare surface: gutters, the avenue's tan lane, parking strips, rail ballast, a
##                        median's lawn, an open lot's surface (on the sidewalk)
##   layer 2 DECAL_LINE   markings over layer 1 or the surface: lines, dashes, zebras, stop lines, parking ticks, a ramp's
##                        lines, the gate's hazard stripes; an open lot's paths and court lines
##   layer 3 DECAL_TOP    over everything: the mission's zone rings (MissionProps, 0.06), a park's central square
const DECAL_PATCH := 0.02
const DECAL_LINE := 0.04
const DECAL_TOP := 0.06
const MARK := DECAL_LINE     ## markings sit this far above the road
const RIB_PITCH := 24.0
const GIRDER_PITCH := 14.0
const BACK_S := 150.0        ## backdrop reach along the arc, each way
const BACK_X := 120.0
const HOLE_CURB := 0.5       ## curb round a floor hole: this wide and this high, solid
const HOLE_RAIL := 1.2       ## railing on that curb (no collision)
const RAIL_GAUGE := 1.435
const TREE_LEAVES := [["leaf_dark", "leaf", "leaf_light"], ["leaf_dark", "leaf_dark", "leaf"], ["leaf", "leaf_light", "leaf_light"]]


static func _c(id: String) -> Color:
	return CityPalette.C[id]


# --- Ground ----------------------------------------------------------------------------------------------

## Everything on the deck's surface. The floor holes are left out of all of it (CityGeo.holes) and edged afterwards.
static func ground(geo: CityGeo, plan: CityPlan) -> void:
	for part in ground_parts(plan):
		ground_part(geo, plan, part)


## ground() split into ground_parts(plan) calls, made in order 0, 1, ... into the same geo (CityDistrict's incremental
## build): the same triangles in the same order as one call. 0: the asphalt; then one part per road along s (roads_x);
## then the cross roads; the blocks; open lots, the floor holes' edges and their soffits.
static func ground_parts(plan: CityPlan) -> int:
	return plan.roads_x.size() + 4


static func ground_part(geo: CityGeo, plan: CityPlan, part: int) -> void:
	var nx := plan.roads_x.size()
	if part == 0:
		var e := plan.extent
		geo.holes = plan.floor_cuts()
		geo.tag("deck")
		geo.g_rect(e.position.x, e.end.x, e.position.y, e.end.y, 0.0, _c("asphalt"))
	elif part <= nx:
		var i := part - 1
		if plan.roads_x[i]["kind"] == "spine":
			_spine(geo, plan.roads_x[i], plan.roads_s)
		else:
			_road(geo, plan.roads_x[i], plan.roads_s, false, true, _line_forms(plan, "s", i))
	elif part == nx + 1:
		for j in plan.roads_s.size():
			_road(geo, plan.roads_s[j], plan.roads_x, true, true, _line_forms(plan, "x", j))
	elif part == nx + 2:
		geo.tag("block")
		for bi in plan.blocks.size():
			if plan.forms.is_empty():
				_block(geo, plan.blocks[bi]["rect"])
			else:
				var flush: Array[bool] = []
				for side in 4:
					flush.append(plan.block_side_form(bi, side) == "none")
				_block(geo, plan.blocks[bi]["rect"], flush)
		if not plan.raised.is_empty():
			geo.tag("form.raised")
			for q: Dictionary in plan.raised:
				_raised(geo, q)
	elif part == nx + 3:
		var cuts := geo.holes
		geo.tag("open_lot")
		for l: Dictionary in plan.lots:
			if l["kind"] == "open":
				_open_lot(geo, l)
		# Downtown: a plaza base's ground, a pillar's plaza, an arcade's gallery floor (looks only: CityPlan `paving`).
		geo.tag("dt_paving")
		for b: Dictionary in plan.buildings:
			for r: Rect2 in b.get("paving", []):
				_plaza_paving(geo, r.grow(-0.6))
		geo.tag("alley")
		for a: Dictionary in plan.alleys:
			_alley(geo, a)
		geo.tag("floor_hole")
		for o in cuts:
			_floor_hole(geo, o, plan.site.slab, plan.ramp_mouth(o))
		geo.tag("soffit")
		_soffits(geo, cuts, plan.site.slab)


## A rectangle on the road. `swap` false: u is x (across a road that runs along s), v is s. True: the other way round.
static func _r(geo: CityGeo, swap: bool, u0: float, u1: float, v0: float, v1: float, col: Color, h: float = MARK) -> void:
	if swap:
		geo.g_rect(v0, v1, u0, u1, h, col)
	else:
		geo.g_rect(u0, u1, v0, v1, h, col)


## The forms of the segments of road `line` along `axis` (CityPlan.seg_form), [] when every one is a street.
static func _line_forms(plan: CityPlan, axis: String, line: int) -> Array:
	if plan.forms.is_empty():
		return []
	var out := []
	var n := (plan.roads_s.size() if axis == "s" else plan.roads_x.size()) - 1
	for index in n:
		out.append(plan.seg_form(axis, line, index))
	return out


## `zebra` false: the crossings are drawn by the caller (the spine draws them across all its lanes at once). `forms`: the
## form of each segment (city-variety.md; [] = all streets): a lane, a pedestrian street or nothing (a superblock's court,
## drawn with the blocks) instead of the street.
static func _road(geo: CityGeo, road: Dictionary, crossings: Array, swap: bool, zebra: bool = true, forms: Array = []) -> void:
	var a: float = road["a"]
	var b: float = road["b"]
	var mid := (a + b) * 0.5
	var avenue: bool = road["kind"] == "avenue"
	var white := _c("marking")
	for j in crossings.size() - 1:
		var v0: float = crossings[j]["b"]
		var v1: float = crossings[j + 1]["a"]
		var form: String = forms[j] if j < forms.size() else "street"
		if form != "street":
			_form_segment(geo, form, a, b, v0, v1, swap)
			continue
		# Gutters along both curbs.
		if zebra:
			geo.tag("road.gutter")
			_r(geo, swap, a, a + 0.5, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
			_r(geo, swap, b - 0.5, b, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
		# Zebra crossings and stop lines at both ends.
		geo.tag("road.zebra_stop")
		for end in 2:
			if zebra:
				_zebra(geo, swap, a, b, v0 + 1.8 if end == 0 else v1 - 4.8)
			var s0 := v0 + 5.6 if end == 0 else v1 - 6.0
			var low_half := (end == 0) == swap
			if low_half:
				_r(geo, swap, a + 0.5, mid - (1.7 if avenue else 0.1), s0, s0 + 0.4, white)
			else:
				_r(geo, swap, mid + (1.7 if avenue else 0.1), b - 0.5, s0, s0 + 0.4, white)
		var m0 := v0 + 7.0
		var m1 := v1 - 7.0
		if m1 - m0 < 4.0:
			continue
		if avenue:
			# Tan centre carriageway, a planted median, dashed lane lines, solid edge lines.
			geo.tag("road.lane_tan")
			_r(geo, swap, mid - 5.2, mid + 5.2, v0, v1, _c("lane_tan"), DECAL_PATCH)
			geo.tag("road.median")
			_median(geo, swap, mid - 1.5, mid + 1.5, m0 + 2.0, m1 - 2.0)
			geo.tag("road.lines")
			_dashes(geo, swap, mid - 5.2, m0, m1, 3.0, 7.0, white)
			_dashes(geo, swap, mid + 5.2, m0, m1, 3.0, 7.0, white)
			_r(geo, swap, mid - 1.95, mid - 1.8, m0, m1, white)
			_r(geo, swap, mid + 1.8, mid + 1.95, m0, m1, white)
			_r(geo, swap, a + 0.9, a + 1.05, m0, m1, white)
			_r(geo, swap, b - 1.05, b - 0.9, m0, m1, white)
		else:
			# Parking strips with bay ticks, a dashed centre line.
			geo.tag("road.parking")
			for k in 2:
				var p0 := a + 0.5 if k == 0 else b - 2.8
				_r(geo, swap, p0, p0 + 2.3, m0, m1, _c("asphalt_light"), DECAL_PATCH)
				var edge := p0 + 2.3 if k == 0 else p0 - 0.12
				_r(geo, swap, edge, edge + 0.12, m0, m1, white)
				var t := m0
				while t <= m1 + 0.01:
					_r(geo, swap, p0, p0 + 2.3, t - 0.06, t + 0.06, white)
					t += (m1 - m0) / maxf(round((m1 - m0) / 6.0), 1.0)
			geo.tag("road.lines")
			_dashes(geo, swap, mid, m0, m1, 2.5, 6.0, white)


## One segment of a road (a..b across, v0..v1 between its crossings) in a form other than a street (city-variety.md):
##   lane        an 8 m one-lane carriageway in the middle of the strip: gutters, solid edge lines, a zebra and a stop line
##               at each end (vehicles pass), no parking, no centre line; the raised planting bands beside it are drawn
##               with the blocks (CityPlan.raised)
##   pedestrian  paved in the plaza colour over the whole strip with bands across it, no gutters, no zebras, no stop lines
##               (no vehicles); the blocks' curbs stay as its one low step
##   none        nothing: the superblock's court covers it (drawn with the blocks)
static func _form_segment(geo: CityGeo, form: String, a: float, b: float, v0: float, v1: float, swap: bool) -> void:
	var white := _c("marking")
	var mid := (a + b) * 0.5
	match form:
		"lane":
			var la := mid - CityPlan.LANE_W * 0.5
			var lb := mid + CityPlan.LANE_W * 0.5
			geo.tag("road.gutter")
			_r(geo, swap, la, la + 0.5, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
			_r(geo, swap, lb - 0.5, lb, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
			geo.tag("road.zebra_stop")
			_zebra(geo, swap, la - 0.4, lb + 0.4, v0 + 1.8)
			_zebra(geo, swap, la - 0.4, lb + 0.4, v1 - 4.8)
			_r(geo, swap, la + 0.5, lb - 0.5, v0 + 5.6, v0 + 6.0, white)
			_r(geo, swap, la + 0.5, lb - 0.5, v1 - 6.0, v1 - 5.6, white)
			var m0 := v0 + 7.0
			var m1 := v1 - 7.0
			if m1 - m0 >= 4.0:
				geo.tag("road.lines")
				_r(geo, swap, la + 0.75, la + 0.9, m0, m1, white)
				_r(geo, swap, lb - 0.9, lb - 0.75, m0, m1, white)
		"pedestrian":
			geo.tag("road.pedestrian")
			_r(geo, swap, a, b, v0, v1, _c("plaza"), DECAL_PATCH)
			var n := maxi(int((v1 - v0) / 4.0), 1)
			for i in n:
				if i % 2 == 0:
					var c0 := v0 + (v1 - v0) * float(i) / float(n)
					_r(geo, swap, a + 0.6, b - 0.6, c0 + 0.3, c0 + (v1 - v0) / float(n) - 0.3, _c("plaza_alt"), DECAL_LINE)
		_:
			pass


## Ground a road form raises to the sidewalk (CityPlan.raised; solid, CityDistrict._col_walls): a superblock's court
## (sidewalk-level paving across the strip, a curb face where it meets each crossing, nothing where it joins the blocks)
## or a lane's planting band (a curb on the carriageway side and the ends, planting on top).
static func _raised(geo: CityGeo, q: Dictionary) -> void:
	var r: Rect2 = q["rect"]
	var along_s := int(q["seg"]) < 65536          # the segment's road runs along s
	var curb := _c("curb")
	var c := 0.3
	if q["kind"] == "court":
		if along_s:
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.position.y + c, CURB, curb)
			geo.g_rect(r.position.x, r.end.x, r.end.y - c, r.end.y, CURB, curb)
			geo.g_rect(r.position.x, r.end.x, r.position.y + c, r.end.y - c, CURB, _c("sidewalk"))
			geo.g_wall_s(r.position.y, r.position.x, r.end.x, 0.0, CURB, -1.0, curb)
			geo.g_wall_s(r.end.y, r.position.x, r.end.x, 0.0, CURB, 1.0, curb)
		else:
			geo.g_rect(r.position.x, r.position.x + c, r.position.y, r.end.y, CURB, curb)
			geo.g_rect(r.end.x - c, r.end.x, r.position.y, r.end.y, CURB, curb)
			geo.g_rect(r.position.x + c, r.end.x - c, r.position.y, r.end.y, CURB, _c("sidewalk"))
			geo.g_wall_x(r.position.x, r.position.y, r.end.y, 0.0, CURB, -1.0, curb)
			geo.g_wall_x(r.end.x, r.position.y, r.end.y, 0.0, CURB, 1.0, curb)
		_plaza_paving(geo, r.grow(-1.2))
		return
	# A band: the carriageway is on its high side (side 0) or its low side (side 1), across the road.
	var low := int(q.get("side", 0)) == 1
	if along_s:
		var xc := r.position.x if low else r.end.x
		var xi := r.position.x + c if low else r.end.x - c
		geo.g_rect(minf(xc, xi), maxf(xc, xi), r.position.y, r.end.y, CURB, curb)
		geo.g_rect(r.position.x + (c if low else 0.0), r.end.x - (0.0 if low else c), r.position.y, r.end.y, CURB, _c("planting"))
		geo.g_wall_x(xc, r.position.y, r.end.y, 0.0, CURB, -1.0 if low else 1.0, curb)
		geo.g_wall_s(r.position.y, r.position.x, r.end.x, 0.0, CURB, -1.0, curb)
		geo.g_wall_s(r.end.y, r.position.x, r.end.x, 0.0, CURB, 1.0, curb)
	else:
		var sc := r.position.y if low else r.end.y
		var si := r.position.y + c if low else r.end.y - c
		geo.g_rect(r.position.x, r.end.x, minf(sc, si), maxf(sc, si), CURB, curb)
		geo.g_rect(r.position.x, r.end.x, r.position.y + (c if low else 0.0), r.end.y - (0.0 if low else c), CURB, _c("planting"))
		geo.g_wall_s(sc, r.position.x, r.end.x, 0.0, CURB, -1.0 if low else 1.0, curb)
		geo.g_wall_x(r.position.x, r.position.y, r.end.y, 0.0, CURB, -1.0, curb)
		geo.g_wall_x(r.end.x, r.position.y, r.end.y, 0.0, CURB, 1.0, curb)


static func _zebra(geo: CityGeo, swap: bool, a: float, b: float, c0: float) -> void:
	var u := a + 0.9
	while u + 0.55 <= b - 0.9:
		_r(geo, swap, u, u + 0.55, c0, c0 + 3.0, _c("marking"))
		u += 1.1


## The transit spine (section mode), lanes side by side: the avenue (today's avenue look fitted to its lane), the rail
## (ballast, two tracks on sleepers, running on through the crossings) and the two ramp lanes (plain, edge lines). Its
## zebra crossings span the whole spine.
static func _spine(geo: CityGeo, road: Dictionary, crossings: Array) -> void:
	var a: float = road["a"]
	var b: float = road["b"]
	var white := _c("marking")
	for j in crossings.size() - 1:
		var v0: float = crossings[j]["b"]
		var v1: float = crossings[j + 1]["a"]
		geo.tag("spine.gutter")
		_r(geo, false, a, a + 0.5, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
		_r(geo, false, b - 0.5, b, v0, v1, _c("asphalt_dark"), DECAL_PATCH)
		geo.tag("spine.zebra")
		_zebra(geo, false, a, b, v0 + 1.8)
		_zebra(geo, false, a, b, v1 - 4.8)
	for lane: Dictionary in road["lanes"]:
		var la: float = lane["a"]
		var lb: float = lane["b"]
		match str(lane["lane"]):
			"avenue":
				_road(geo, {"a": la, "b": lb, "kind": "avenue"}, crossings, false, false)
			"rail":
				geo.tag("spine.rail")
				_rail(geo, la, lb, crossings)
			_:
				geo.tag("spine.ramp_lane")
				for j in crossings.size() - 1:
					var m0: float = float(crossings[j]["b"]) + 7.0
					var m1: float = float(crossings[j + 1]["a"]) - 7.0
					if m1 - m0 >= 4.0:
						_r(geo, false, la + 0.6, la + 0.75, m0, m1, white)
						_r(geo, false, lb - 0.75, lb - 0.6, m0, m1, white)


static func _rail(geo: CityGeo, a: float, b: float, crossings: Array) -> void:
	var s0: float = crossings[0]["a"]
	var s1: float = crossings[-1]["b"]
	for j in crossings.size() - 1:
		_r(geo, false, a + 0.6, b - 0.6, float(crossings[j]["b"]), float(crossings[j + 1]["a"]), _c("concrete_dark"), DECAL_PATCH)
	var mid := (a + b) * 0.5
	geo.tag("spine.rail_track")
	for track: float in [mid - (b - a) * 0.25, mid + (b - a) * 0.25]:
		var s := s0 + 1.0
		while s < s1:
			if not geo.in_hole(track, s):
				geo.box(geo.frame(track, s, 0.0), Vector3(0, 0.06, 0), Vector3(2.6, 0.12, 0.25), _c("trunk"), CityGeo.NO_BOTTOM)
			s += 2.0
		for k: float in [-1.0, 1.0]:
			var x := track + k * RAIL_GAUGE * 0.5
			for sp: Array in geo.open_spans(s0, s1, x, true):
				var br := CityGeo.breaks(sp[0], sp[1])
				for i in br.size() - 1:
					geo.box(geo.frame(x, (br[i] + br[i + 1]) * 0.5, 0.12), Vector3(0, 0.075, 0), Vector3(0.1, 0.15, br[i + 1] - br[i]),
							_c("metal_dark"), CityGeo.NO_BOTTOM)


## The edge of a hole in this deck's floor: the cut face of the slab going down, a solid curb round it and a railing on
## the curb. Nothing is drawn below: the deck beneath is another district. `open` is a side (2: +s, 3: -s) left without
## curb and railing: a ramp's top, where it leaves the road.
static func _floor_hole(geo: CityGeo, o: Rect2, slab: float, open: int = -1) -> void:
	var cut := _c("concrete")
	var curb := _c("curb")
	var metal := _c("metal_dark")
	var x0 := o.position.x
	var x1 := o.end.x
	var s0 := o.position.y
	var s1 := o.end.y
	var c := HOLE_CURB
	var c0 := 0.0 if open == 3 else c      # how far the long sides reach past each end
	var c1 := 0.0 if open == 2 else c
	geo.g_wall_x(x0, s0, s1, -slab, 0.0, 1.0, cut)
	geo.g_wall_x(x1, s0, s1, -slab, 0.0, -1.0, cut)
	geo.g_wall_s(s0, x0, x1, -slab, 0.0, 1.0, cut)
	geo.g_wall_s(s1, x0, x1, -slab, 0.0, -1.0, cut)
	geo.g_slab(x0 - c, x0, s0 - c0, s1 + c1, 0.0, c, curb)
	geo.g_slab(x1, x1 + c, s0 - c0, s1 + c1, 0.0, c, curb)
	if open != 3:
		geo.g_slab(x0, x1, s0 - c, s0, 0.0, c, curb)
	if open != 2:
		geo.g_slab(x0, x1, s1, s1 + c, 0.0, c, curb)
	# Railing: posts every 4 m round the curb's centre line, one top rail (facet-long pieces along the arc).
	var top := c + HOLE_RAIL
	var rx0 := x0 - c * 0.5
	var rx1 := x1 + c * 0.5
	var rs0 := s0 - c0 * 0.5
	var rs1 := s1 + c1 * 0.5
	for x: float in [rx0, rx1]:
		var n := maxi(int(ceil((rs1 - rs0) / 4.0)), 1)
		for i in n + 1:
			geo.box(geo.frame(x, rs0 + (rs1 - rs0) * float(i) / float(n), c), Vector3(0, HOLE_RAIL * 0.5, 0), Vector3(0.12, HOLE_RAIL, 0.12), metal)
		var br := CityGeo.breaks(rs0, rs1)
		for i in br.size() - 1:
			geo.box(geo.frame(x, (br[i] + br[i + 1]) * 0.5, top), Vector3.ZERO, Vector3(0.1, 0.1, br[i + 1] - br[i]), metal)
	for sv: float in [rs0, rs1]:
		if (open == 3 and sv == rs0) or (open == 2 and sv == rs1):
			continue
		var n := maxi(int(ceil((rx1 - rx0) / 4.0)), 1)
		for i in range(1, n):
			geo.box(geo.frame(rx0 + (rx1 - rx0) * float(i) / float(n), sv, c), Vector3(0, HOLE_RAIL * 0.5, 0), Vector3(0.12, HOLE_RAIL, 0.12), metal)
		geo.box(geo.frame((rx0 + rx1) * 0.5, sv, top), Vector3.ZERO, Vector3(rx1 - rx0, 0.1, 0.1), metal)


## The underside of the slab round each floor hole, as far as the ceiling of the deck beneath is cut back to whole panels
## (and under the cross roads that bridge a ramp's cut): what that deck sees up through its ceiling opening. A few
## centimetres above that ceiling's plane, so where the two overlap the ceiling is in front.
static func _soffits(geo: CityGeo, cuts: Array[Rect2], slab: float) -> void:
	var done: Array[Rect2] = cuts.duplicate()
	for o in cuts:
		for q in CityGeo.cut(o.grow(maxf(PANEL_X, PANEL_S)), done):
			geo.g_rect(q.position.x, q.end.x, q.position.y, q.end.y, 0.05 - slab, _c("concrete_dark"), false)
			done.append(q)


# --- Ramps -----------------------------------------------------------------------------------------------
# A ramp between decks (CityPlan.ramps): a 10 m ribbon falling along its spine lane, asphalt with edge lines and a
# dashed centre line, 1 m thick, a solid parapet down each side. Its top part leaves the upper deck flush with the
# cross road at its top line and dives through the floor; its bottom part comes down out of the lower deck's ceiling on
# piers, then on an embankment, and meets the road flush at its foot line. Drawn in facet-long pieces that follow the
# slope, so the ribbon's surface is the same plane the collision boxes put their tops on.

const RAMP_THICK := 1.0
const PARAPET_H := 1.0
## Collision height of a ramp parapet above the ribbon. The drawn parapet is PARAPET_H, but a mech's legs step onto any
## edge up to MechRig.max_step() (1.25 m with the current legs), so a 1 m collision box was stepped over and the mech fell
## off the ramp's side (tests/test_city_stack_walk.gd). Above PARAPET_H the box is invisible; 2.5 m keeps a margin for
## longer legs (the capsule touches it at 2.2 m, its radius, well over any step).
const PARAPET_GUARD := 2.5
const PARAPET_W := 0.5
const PIER_PITCH := 24.0
const PIER_MIN := 3.0        ## lower than this the ribbon stands on a solid embankment instead of piers
const PIER_W := 2.0
const PIER_CLEAR := 3.0      ## a pier's face stays this far off a cross road's edge (its crosswalk, its corners)
const BEAM_W := 1.2          ## the two edge beams under the ribbon: this wide, hanging this far below the soffit
const BEAM_D := 1.0
const CROSS_D := 1.3         ## the cross beam at a pier: this deep below the soffit, this long along the ramp
const CROSS_L := 2.6
const CAP_W := 6.5           ## the cross-head on a pier: across the ramp, along it, tall, and the haunch below it
const CAP_L := 2.2
const CAP_H := 1.0
const HAUNCH := 0.8
const PLINTH_W := 3.2
const PLINTH_H := 0.5
const END_W := 0.8           ## the block that ends a parapet where the ramp meets the road
const END_L := 1.2
const END_H := 1.3


## The s range of ramp part `r` as [low, high]. `drawn`: the top part's visible end is where it passes the ceiling of the
## deck beneath (the bottom part takes over there), so the two never draw the same stretch twice.
static func ramp_span(r: Dictionary, slab: float, drawn: bool = false) -> Vector2:
	var a := float(r["s_top"])
	var b := float(r["s_foot"])
	if drawn and r["role"] == "top":
		b = CityPlan.ramp_s(r, -slab)
	return Vector2(minf(a, b), maxf(a, b))


## Where the embankment starts (the bottom part's s at PIER_MIN), or NAN for a top part.
static func embankment_s(r: Dictionary) -> float:
	return CityPlan.ramp_s(r, PIER_MIN) if r["role"] == "bottom" else NAN


## The piers under a bottom part. The cross roads it passes over split the raised stretch into spans; in each span the
## piers are spread evenly about PIER_PITCH apart, with one at each end that a cross road closes (so every cross road
## is spanned by a pair of piers PIER_CLEAR off its edges) and none at the embankment's end (its end wall carries the
## ribbon). The last span runs on toward the ceiling at PIER_PITCH while the ribbon is 2 m or more below it.
static func pier_s(r: Dictionary, plan: CityPlan) -> Array[float]:
	var out: Array[float] = []
	if r["role"] != "bottom":
		return out
	var foot := float(r["s_foot"])
	var up := signf(float(r["s_top"]) - foot)
	var u0 := (embankment_s(r) - foot) * up      # u: distance up the ramp from its foot
	var u_end := (CityPlan.ramp_s(r, float(r["h_top"]) - 2.0) - foot) * up
	var m := PIER_CLEAR + PIER_W * 0.5
	var blocked: Array[Vector2] = []       # cross roads (plus clearance) in u, sorted
	for road: Dictionary in plan.roads_s:
		var a := (float(road["a"]) - foot) * up
		var b := (float(road["b"]) - foot) * up
		blocked.append(Vector2(minf(a, b) - m, maxf(a, b) + m))
	blocked.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	var us: Array[float] = []
	var lo := u0
	var lo_closed := false                 # the embankment's end wall needs no pier
	for bl in blocked:
		if bl.y <= lo:
			continue
		if bl.x >= u_end:
			break
		if bl.x > lo:
			_spread(us, lo, bl.x, lo_closed)
		lo = maxf(lo, bl.y)
		lo_closed = true
	var u := lo if lo_closed else lo + PIER_PITCH
	while u <= u_end + 0.01:
		us.append(u)
		u += PIER_PITCH
	for v in us:
		if CityPlan.ramp_height(r, foot + v * up) > PIER_MIN:
			out.append(foot + v * up)
	return out


## Piers spread evenly over [a, b] about PIER_PITCH apart: one at b (a cross road's edge), one at a only if `at_a`.
static func _spread(out: Array[float], a: float, b: float, at_a: bool) -> void:
	var n := maxi(int(round((b - a) / PIER_PITCH)), 1)
	for i in range(0 if at_a else 1, n + 1):
		out.append(a + (b - a) * float(i) / float(n))


## The heights of the pier at s under ramp part `r` (above the lower floor): the cross beam's bottom at the pier's
## centre line, the cap's top and bottom, and the haunch's bottom (where the 2 x 2 m shaft ends).
static func pier_heights(r: Dictionary, s: float) -> Dictionary:
	var cross := CityPlan.ramp_height(r, s) - RAMP_THICK - CROSS_D
	var cap_top := cross + 0.2           # into the cross beam, which slopes with the ribbon
	return {"cross": cross, "cap_top": cap_top, "cap_bot": cap_top - CAP_H, "shaft_top": cap_top - CAP_H - HAUNCH}


## A frame on the ramp's surface (plus dh) at (x, s): X along the ring's axis, Z down the slope toward +s, Y square to it.
static func ramp_frame(geo: CityGeo, r: Dictionary, x: float, s: float, dh: float = 0.0) -> Transform3D:
	var a := geo.g_point(x, s - 0.5, CityPlan.ramp_height(r, s - 0.5) + dh)
	var b := geo.g_point(x, s + 0.5, CityPlan.ramp_height(r, s + 0.5) + dh)
	var z := (b - a).normalized()
	return Transform3D(Basis(Vector3.RIGHT, z.cross(Vector3.RIGHT), z), geo.g_point(x, s, CityPlan.ramp_height(r, s) + dh))


static func ramps(geo: CityGeo, plan: CityPlan) -> void:
	for r: Dictionary in plan.ramps:
		_ramp(geo, plan, r)


static func _ramp(geo: CityGeo, plan: CityPlan, r: Dictionary) -> void:
	var span := ramp_span(r, plan.site.slab, true)
	var x0 := float(r["x0"])
	var x1 := float(r["x1"])
	var mid := (x0 + x1) * 0.5
	var concrete := _c("concrete")
	var dark := _c("concrete_dark")
	var white := _c("marking")
	var emb := embankment_s(r)
	# The stretch on piers (open underneath) and the stretch on the embankment (sides down to the floor).
	var raised := span
	var low := Vector2.ZERO
	if not is_nan(emb):
		if float(r["s_foot"]) < float(r["s_top"]):
			low = Vector2(span.x, emb)
			raised = Vector2(emb, span.y)
		else:
			low = Vector2(emb, span.y)
			raised = Vector2(span.x, emb)
	geo.tag("ramp.ribbon")
	_slope_rect(geo, r, x0 + PARAPET_W, x1 - PARAPET_W, span.x, span.y, 0.0, _c("asphalt"))
	geo.tag("ramp.lines")
	for k: float in [-1.0, 1.0]:
		var edge := mid + k * ((x1 - x0) * 0.5 - 0.9)
		_slope_rect(geo, r, minf(edge, edge - k * 0.15), maxf(edge, edge - k * 0.15), span.x, span.y, MARK, white)
	var d := span.x + (fmod(span.y - span.x, 6.0) + 6.0 - 2.5) * 0.5
	while d + 2.5 <= span.y:
		_slope_rect(geo, r, mid - 0.08, mid + 0.08, d, d + 2.5, MARK, white)
		d += 6.0
	# Underside where it is open: the soffit between two edge beams (bottom and inner face each).
	var deep := -RAMP_THICK - BEAM_D
	geo.tag("ramp.soffit_beams")
	_slope_rect(geo, r, x0 + BEAM_W, x1 - BEAM_W, raised.x, raised.y, -RAMP_THICK, dark, false)
	_slope_rect(geo, r, x0, x0 + BEAM_W, raised.x, raised.y, deep, concrete, false)
	_slope_rect(geo, r, x1 - BEAM_W, x1, raised.x, raised.y, deep, concrete, false)
	_slope_wall(geo, r, x0 + BEAM_W, raised.x, raised.y, deep, -RAMP_THICK, 1.0, concrete)
	_slope_wall(geo, r, x1 - BEAM_W, raised.x, raised.y, deep, -RAMP_THICK, -1.0, concrete)
	# Parapets: cap, inner face, outer face (the fascia, down past the edge beam; to the floor on the embankment).
	geo.tag("ramp.parapet")
	for side in 2:
		var out_x := x0 if side == 0 else x1
		var in_x := x0 + PARAPET_W if side == 0 else x1 - PARAPET_W
		var sgn := -1.0 if side == 0 else 1.0
		_slope_rect(geo, r, minf(out_x, in_x), maxf(out_x, in_x), span.x, span.y, PARAPET_H, _c("curb"))
		_slope_wall(geo, r, in_x, span.x, span.y, 0.0, PARAPET_H, -sgn, concrete)
		_slope_wall(geo, r, out_x, raised.x, raised.y, deep, PARAPET_H, sgn, concrete)
		if low.y > low.x:
			_slope_wall(geo, r, out_x, low.x, low.y, -RAMP_THICK, PARAPET_H, sgn, concrete, true)
	# The parapets' ends where the ramp meets a road (its top on the upper deck, its foot on the lower): a short block
	# a little wider and taller than the parapet, standing on the ribbon.
	var end_s := float(r["s_top"]) if r["role"] == "top" else float(r["s_foot"])
	var away := 1.0 if end_s > (span.x + span.y) * 0.5 else -1.0
	geo.tag("ramp.end_block")
	for eb in end_blocks(r, span):
		geo.box(geo.frame(eb.x, eb.y, eb.z), Vector3(0, -(END_H + 0.3) * 0.5 + END_H, 0), Vector3(END_W, END_H + 0.3, END_L), concrete, CityGeo.NO_BOTTOM, _c("curb"))
	if low.y > low.x:
		# The embankment's high end closes the space under the ribbon (and the edge beams' ends); piers carry the rest.
		geo.tag("ramp.embankment_end")
		geo.g_wall_s(emb, x0, x1, 0.0, PIER_MIN - RAMP_THICK, -away, concrete)
		geo.tag("ramp.pier")
		for s in pier_s(r, plan):
			_pier(geo, r, mid, x1 - x0, s)


## Where the two parapet end blocks of ramp part `r` stand, as arc points (x, s, h): on the higher end of the ribbon
## under them, END_L long, ending at the road end.
static func end_blocks(r: Dictionary, span: Vector2) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var end_s := float(r["s_top"]) if r["role"] == "top" else float(r["s_foot"])
	var away := 1.0 if end_s > (span.x + span.y) * 0.5 else -1.0
	var bs := end_s - away * END_L * 0.5
	var bh := maxf(CityPlan.ramp_height(r, end_s), CityPlan.ramp_height(r, end_s - away * END_L))
	# Flush with the ramp's sides (not straddling them): centred on the parapet, a block 0.8 m wide stuck 0.15 m out over
	# the floor hole's curb, and its end face lay in the plane of the curb's end face (z-fighting at the ramp's head).
	for px: float in [float(r["x0"]) + END_W * 0.5, float(r["x1"]) - END_W * 0.5]:
		out.append(Vector3(px, bs, bh))
	return out


## One pier at s: a plinth on the floor, the 2 x 2 m shaft, a haunch widening into the cross-head, and the cross beam
## under the soffit that the cross-head carries (spanning the edge beams, a little deeper than them).
static func _pier(geo: CityGeo, r: Dictionary, mid: float, width: float, s: float) -> void:
	var concrete := _c("concrete")
	var dark := _c("concrete_dark")
	var hp := pier_heights(r, s)
	var f := geo.frame(mid, s, 0.0)
	geo.box(f, Vector3(0, PLINTH_H * 0.5, 0), Vector3(PLINTH_W, PLINTH_H, PLINTH_W), dark, CityGeo.NO_BOTTOM)
	var shaft := float(hp["shaft_top"]) - PLINTH_H
	geo.box(f, Vector3(0, PLINTH_H + shaft * 0.5, 0), Vector3(PIER_W, shaft, PIER_W), concrete, CityGeo.ALL - CityGeo.NY - CityGeo.PY)
	geo.frustum(f, Vector3.ZERO, float(hp["shaft_top"]), Vector2(PIER_W, PIER_W) * 0.5, float(hp["cap_bot"]), Vector2(CAP_W, CAP_L) * 0.5, concrete)
	geo.box(f, Vector3(0, float(hp["cap_bot"]) + CAP_H * 0.5, 0), Vector3(CAP_W, CAP_H, CAP_L), concrete, CityGeo.ALL - CityGeo.PY)
	geo.box(ramp_frame(geo, r, mid, s, -RAMP_THICK), Vector3(0, -CROSS_D * 0.5, 0), Vector3(width - 0.1, CROSS_D, CROSS_L), dark,
			CityGeo.ALL - CityGeo.PY)


## A strip on the ramp from u0 to u1 across and s0 to s1 along, dh above its surface, in facet-long pieces.
static func _slope_rect(geo: CityGeo, r: Dictionary, u0: float, u1: float, s0: float, s1: float, dh: float, col: Color, up: bool = true) -> void:
	var br := CityGeo.breaks(s0, s1)
	for i in br.size() - 1:
		var ha := CityPlan.ramp_height(r, br[i]) + dh
		var hb := CityPlan.ramp_height(r, br[i + 1]) + dh
		var p0 := geo.g_point(u0, br[i], ha)
		var p1 := geo.g_point(u1, br[i], ha)
		var p2 := geo.g_point(u1, br[i + 1], hb)
		var p3 := geo.g_point(u0, br[i + 1], hb)
		if up:
			geo.quad(p0, p3, p2, p1, col)
		else:
			geo.quad(p0, p1, p2, p3, col)


## A face along the ramp at constant x from d0 to d1 relative to its surface (from the floor instead, `ground`), facing
## +x (sgn > 0) or -x.
static func _slope_wall(geo: CityGeo, r: Dictionary, x: float, s0: float, s1: float, d0: float, d1: float, sgn: float, col: Color, ground: bool = false) -> void:
	var br := CityGeo.breaks(s0, s1)
	for i in br.size() - 1:
		var ha := CityPlan.ramp_height(r, br[i])
		var hb := CityPlan.ramp_height(r, br[i + 1])
		var a := geo.g_point(x, br[i], 0.0 if ground else ha + d0)
		var c := geo.g_point(x, br[i + 1], 0.0 if ground else hb + d0)
		var d := geo.g_point(x, br[i + 1], hb + d1)
		var e := geo.g_point(x, br[i], ha + d1)
		if sgn > 0.0:
			geo.quad(c, a, e, d, col)
		else:
			geo.quad(a, c, d, e, col)


static func _dashes(geo: CityGeo, swap: bool, u: float, v0: float, v1: float, length: float, pitch: float, col: Color) -> void:
	var v := v0 + (fmod(v1 - v0, pitch) + pitch - length) * 0.5
	while v + length <= v1:
		_r(geo, swap, u - 0.08, u + 0.08, v, v + length, col)
		v += pitch


static func _median(geo: CityGeo, swap: bool, u0: float, u1: float, v0: float, v1: float) -> void:
	if v1 - v0 < 6.0:
		return
	var curb := _c("curb")
	if swap:
		geo.g_slab(v0, v1, u0, u1, 0.0, CURB, curb)
		geo.g_rect(v0 + 0.3, v1 - 0.3, u0 + 0.3, u1 - 0.3, CURB + DECAL_PATCH, _c("lawn"))
	else:
		geo.g_slab(u0, u1, v0, v1, 0.0, CURB, curb)
		geo.g_rect(u0 + 0.3, u1 - 0.3, v0 + 0.3, v1 - 0.3, CURB + DECAL_PATCH, _c("lawn"))


## A horizontal-ish quad with a height at each corner: (x0,s0) (x0,s1) (x1,s1) (x1,s0).
static func _up_quad(geo: CityGeo, x0: float, x1: float, s0: float, s1: float, h00: float, h01: float, h11: float, h10: float, col: Color) -> void:
	geo.g_quad(Vector3(x0, s0, h00), Vector3(x0, s1, h01), Vector3(x1, s1, h11), Vector3(x1, s0, h10), col)


static func _both(geo: CityGeo, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	geo.g_tri(a, b, c, col)
	geo.g_tri(a, c, b, col)


## A block: the raised sidewalk slab with its curb, furnishing band and corner ramps. `flush` (by CityPlan side, may be
## empty): edges that meet a superblock's court at the same height, drawn as plain sidewalk (no curb, band or ramps).
static func _block(geo: CityGeo, r: Rect2, flush: Array[bool] = []) -> void:
	var x0 := r.position.x
	var x1 := r.end.x
	var s0 := r.position.y
	var s1 := r.end.y
	var walk := _c("sidewalk")
	var band := _c("sidewalk_band")
	var curb := _c("curb")
	var tactile := _c("tactile")
	geo.g_rect(x0 + EDGE, x1 - EDGE, s0 + EDGE, s1 - EDGE, CURB, walk)
	# Corner pads.
	for cx: float in [x0, x1 - EDGE]:
		for cs: float in [s0, s1 - EDGE]:
			geo.g_rect(cx, cx + EDGE, cs, cs + EDGE, CURB, curb)
	geo.g_wall_x(x0, s0, s0 + EDGE, 0.0, CURB, -1.0, curb)
	geo.g_wall_x(x0, s1 - EDGE, s1, 0.0, CURB, -1.0, curb)
	geo.g_wall_x(x1, s0, s0 + EDGE, 0.0, CURB, 1.0, curb)
	geo.g_wall_x(x1, s1 - EDGE, s1, 0.0, CURB, 1.0, curb)
	geo.g_wall_s(s0, x0, x0 + EDGE, 0.0, CURB, -1.0, curb)
	geo.g_wall_s(s0, x1 - EDGE, x1, 0.0, CURB, -1.0, curb)
	geo.g_wall_s(s1, x0, x0 + EDGE, 0.0, CURB, 1.0, curb)
	geo.g_wall_s(s1, x1 - EDGE, x1, 0.0, CURB, 1.0, curb)
	var low := 0.03
	# Edges at constant x (they run along s).
	for side in 2:
		var xo := x0 if side == 0 else x1                    # outer (curb) line
		var xi := x0 + EDGE if side == 0 else x1 - EDGE      # inner line
		var xc := x0 + 0.3 if side == 0 else x1 - 0.3        # curb / band line
		var sgn := -1.0 if side == 0 else 1.0
		if not flush.is_empty() and flush[1 if side == 0 else 0]:
			geo.g_rect(minf(xi, xo), maxf(xi, xo), s0 + EDGE, s1 - EDGE, CURB, walk)
			continue
		var spans := [[s0 + EDGE, s0 + RAMP_A, false], [s0 + RAMP_A, s0 + RAMP_B, true], [s0 + RAMP_B, s1 - RAMP_B, false],
				[s1 - RAMP_B, s1 - RAMP_A, true], [s1 - RAMP_A, s1 - EDGE, false]]
		for sp: Array in spans:
			var a: float = sp[0]
			var b: float = sp[1]
			if sp[2]:
				if side == 0:
					_up_quad(geo, xo, xi, a, b, low, low, CURB, CURB, tactile)
				else:
					_up_quad(geo, xi, xo, a, b, CURB, CURB, low, low, tactile)
				geo.g_wall_x(xo, a, b, 0.0, low, sgn, curb)
				for se: float in [a, b]:
					_both(geo, Vector3(xi, se, CURB), Vector3(xo, se, CURB), Vector3(xo, se, low), curb)
			else:
				geo.g_rect(minf(xi, xc), maxf(xi, xc), a, b, CURB, band)
				geo.g_rect(minf(xo, xc), maxf(xo, xc), a, b, CURB, curb)
				geo.g_wall_x(xo, a, b, 0.0, CURB, sgn, curb)
	# Edges at constant s (they run along x).
	for side in 2:
		var so := s0 if side == 0 else s1
		var si := s0 + EDGE if side == 0 else s1 - EDGE
		var sc := s0 + 0.3 if side == 0 else s1 - 0.3
		var sgn := -1.0 if side == 0 else 1.0
		if not flush.is_empty() and flush[3 if side == 0 else 2]:
			geo.g_rect(x0 + EDGE, x1 - EDGE, minf(si, so), maxf(si, so), CURB, walk)
			continue
		var spans := [[x0 + EDGE, x0 + RAMP_A, false], [x0 + RAMP_A, x0 + RAMP_B, true], [x0 + RAMP_B, x1 - RAMP_B, false],
				[x1 - RAMP_B, x1 - RAMP_A, true], [x1 - RAMP_A, x1 - EDGE, false]]
		for sp: Array in spans:
			var a: float = sp[0]
			var b: float = sp[1]
			if sp[2]:
				if side == 0:
					_up_quad(geo, a, b, so, si, low, CURB, CURB, low, tactile)
				else:
					_up_quad(geo, a, b, si, so, CURB, low, low, CURB, tactile)
				geo.g_wall_s(so, a, b, 0.0, low, sgn, curb)
				for xe: float in [a, b]:
					_both(geo, Vector3(xe, si, CURB), Vector3(xe, so, CURB), Vector3(xe, so, low), curb)
			else:
				geo.g_rect(a, b, minf(si, sc), maxf(si, sc), CURB, band)
				geo.g_rect(a, b, minf(so, sc), maxf(so, sc), CURB, curb)
				geo.g_wall_s(so, a, b, 0.0, CURB, sgn, curb)


## Plaza paving over rectangle r of the sidewalk: the surface (decal layer 1) and bands across it (layer 2).
static func _plaza_paving(geo: CityGeo, r: Rect2) -> void:
	var h := CURB + DECAL_PATCH
	geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("plaza"))
	var n := maxi(int(r.size.y / 4.0), 1)
	for i in n:
		if i % 2 == 0:
			var a := r.position.y + r.size.y * float(i) / float(n)
			geo.g_rect(r.position.x + 0.6, r.end.x - 0.6, a + 0.3, a + r.size.y / float(n) - 0.3, h + DECAL_PATCH, _c("plaza_alt"))


## A service alley on the block's sidewalk slab (CityPlan.alleys): darker service paving (decal layer 1) with a dark
## edge band each side and a drain line down the middle with a grate every 6 m (layer 2). No curb, walkway or trees.
static func _alley(geo: CityGeo, a: Dictionary) -> void:
	var r: Rect2 = a["rect"]
	var h := CURB + DECAL_PATCH
	var along := int(a["axis"])
	geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("service"))
	var hl := CURB + DECAL_LINE
	if along == 0:
		var c := r.get_center().y
		geo.g_rect(r.position.x, r.end.x, r.position.y, r.position.y + 0.6, hl, _c("service_dark"))
		geo.g_rect(r.position.x, r.end.x, r.end.y - 0.6, r.end.y, hl, _c("service_dark"))
		geo.g_rect(r.position.x + 0.5, r.end.x - 0.5, c - 0.15, c + 0.15, hl, _c("drain"))
		var x := r.position.x + 3.0
		while x < r.end.x - 2.0:
			geo.g_rect(x - 0.4, x + 0.4, c - 0.4, c - 0.15, hl, _c("drain"))
			geo.g_rect(x - 0.4, x + 0.4, c + 0.15, c + 0.4, hl, _c("drain"))
			x += 6.0
	else:
		var c := r.get_center().x
		geo.g_rect(r.position.x, r.position.x + 0.6, r.position.y, r.end.y, hl, _c("service_dark"))
		geo.g_rect(r.end.x - 0.6, r.end.x, r.position.y, r.end.y, hl, _c("service_dark"))
		geo.g_rect(c - 0.15, c + 0.15, r.position.y + 0.5, r.end.y - 0.5, hl, _c("drain"))
		var s := r.position.y + 3.0
		while s < r.end.y - 2.0:
			geo.g_rect(c - 0.4, c - 0.15, s - 0.4, s + 0.4, hl, _c("drain"))
			geo.g_rect(c + 0.15, c + 0.4, s - 0.4, s + 0.4, hl, _c("drain"))
			s += 6.0


static func _open_lot(geo: CityGeo, l: Dictionary) -> void:
	var r: Rect2 = (l["rect"] as Rect2).grow(-0.6)
	var h := CURB + DECAL_PATCH
	match str(l["open"]):
		"garden":
			geo.g_slab(r.position.x, r.end.x, r.position.y, r.end.y, CURB, CURB + 0.25, _c("curb"))
			geo.g_rect(r.position.x + 0.3, r.end.x - 0.3, r.position.y + 0.3, r.end.y - 0.3, CURB + 0.25 + DECAL_PATCH, _c("lawn"))
		"plaza":
			_plaza_paving(geo, r)
		"court":
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("asphalt_light"))
			var x := r.position.x + 2.6
			while x < r.end.x - 1.0:
				geo.g_rect(x - 0.06, x + 0.06, r.position.y + 0.5, r.position.y + 5.0, h + DECAL_PATCH, _c("marking"))
				geo.g_rect(x - 0.06, x + 0.06, r.end.y - 5.0, r.end.y - 0.5, h + DECAL_PATCH, _c("marking"))
				x += 2.6
		"park":
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("lawn"))
			var c := r.get_center()
			geo.g_rect(c.x - 1.5, c.x + 1.5, r.position.y, r.end.y, h + DECAL_PATCH, _c("plaza"))
			geo.g_rect(r.position.x, r.end.x, c.y - 1.5, c.y + 1.5, h + DECAL_PATCH, _c("plaza"))
			geo.g_rect(c.x - 5.0, c.x + 5.0, c.y - 5.0, c.y + 5.0, h + DECAL_LINE, _c("plaza"))


# --- Furniture -------------------------------------------------------------------------------------------
# Only what cannot move: tree pits under the street trees, plaza planters, the park fountain. Trees, lamps, signal poles,
# signs, benches and bins are CityProps (they fall over), placed by CityProps.layout(); the shapes below are their
# prototypes, drawn upright at the origin of `xf`.

## `items` is CityProps.layout(plan): a pit goes under every street tree, so pits and trees always line up.
static func furniture(geo: CityGeo, plan: CityPlan, items: Array) -> void:
	geo.tag("furniture")
	for it: Dictionary in items:
		if it["pit"]:
			geo.box(geo.frame(it["x"], it["s"], CURB), Vector3(0, 0.1, 0), Vector3(1.5, 0.2, 1.5), _c("curb"), CityGeo.NO_BOTTOM, _c("soil"))
	for l: Dictionary in plan.lots:
		if l["kind"] != "open":
			continue
		var r: Rect2 = (l["rect"] as Rect2).grow(-2.0)
		if r.size.x < 1.0 or r.size.y < 1.0:
			continue
		var c := r.get_center()
		if not plan.clear_at(c):
			continue
		match str(l["open"]):
			"plaza":
				geo.box(geo.frame(c.x, c.y, CURB), Vector3(0, 0.35, 0), Vector3(minf(r.size.x * 0.5, 4.0), 0.7, minf(r.size.y * 0.5, 4.0)), _c("cream_light"), CityGeo.NO_BOTTOM, _c("soil"))
			"park":
				# A fountain where the paths cross.
				var f := geo.frame(c.x, c.y, CURB)
				geo.prism(f, Vector3.ZERO, 3.4, 0.6, 8, _c("cream_light"), 3.4, _c("water"))
				geo.prism(f, Vector3(0, 0.6, 0), 0.7, 1.6, 6, _c("cream_light"), 0.4)
				geo.prism(f, Vector3(0, 2.2, 0), 1.3, 0.25, 8, _c("cream_light"), 1.3, _c("water"), _c("cream_light"))
	# A downtown plaza base's planters (CityPlan `planters`: fixed, looks only, like an open plaza's).
	for b: Dictionary in plan.buildings:
		for pl: Array in b.get("planters", []):
			var at: Vector2 = pl[0]
			var sz: Vector2 = pl[1]
			if plan.clear_at(at):
				geo.box(geo.frame(at.x, at.y, CURB), Vector3(0, 0.35, 0), Vector3(sz.x, 0.7, sz.y), _c("cream_light"), CityGeo.NO_BOTTOM, _c("soil"))


## String lights over every pedestrian street (city-variety.md): slim posts just inside the strip's edges, zig-zagging
## from side to side every STRING_PITCH, with a sagging wire between their tops (into `geo`) and bulbs along it (into
## `bulbs`, which takes the emissive farm-light material: no Light3D). Fixed looks, no collision.
const STRING_PITCH := 10.0
const STRING_H := 6.2
static func string_lights(geo: CityGeo, bulbs: CityGeo, plan: CityPlan) -> void:
	var keys := plan.forms.keys()
	keys.sort()
	var metal := _c("metal_dark")
	for k: int in keys:
		if str(plan.forms[k]) != "pedestrian":
			continue
		var along_s := k < 65536
		var r := plan.seg_inner("s" if along_s else "x", (k % 65536) / 256, k % 256)
		var a := 1 if along_s else 0
		var length := r.size[a]
		var n := maxi(int((length - 14.0) / STRING_PITCH), 1)
		var tops: Array[Vector3] = []
		geo.tag("form.string_lights")
		bulbs.tag("form.bulbs")
		for i in n + 1:
			var p := Vector2.ZERO
			p[a] = r.position[a] + 7.0 + (length - 14.0) * float(i) / float(n)
			p[1 - a] = r.position[1 - a] + 0.8 if i % 2 == 0 else r.end[1 - a] - 0.8
			var f := geo.frame(p.x, p.y, 0.0)
			geo.prism(f, Vector3.ZERO, 0.1, STRING_H, 6, metal, 0.07, null, metal)
			tops.append(Vector3(p.x, p.y, STRING_H - 0.1))
		for i in tops.size() - 1:
			var steps := 6
			var prev := geo.g_point(tops[i].x, tops[i].y, tops[i].z)
			for st in range(1, steps + 1):
				var t := float(st) / float(steps)
				var q := tops[i].lerp(tops[i + 1], t)
				var sag := 1.1 * 4.0 * t * (1.0 - t)
				var cur := geo.g_point(q.x, q.y, q.z - sag)
				var d := cur - prev
				if d.length() > 0.01:
					var basis := Basis.looking_at(d.normalized(), Vector3.UP if absf(d.normalized().y) < 0.95 else Vector3.RIGHT)
					geo.box(Transform3D(basis, (prev + cur) * 0.5), Vector3.ZERO, Vector3(0.04, 0.04, d.length()), metal)
				if st < steps:
					bulbs.box(Transform3D(Basis.IDENTITY, cur - Vector3(0, 0.12, 0)), Vector3.ZERO, Vector3(0.2, 0.2, 0.2), _c("bulb"))
				prev = cur


## A chunky low-poly tree: trunk and three stacked canopy shapes, in one of TREE_LEAVES' colourings.
## Closed underneath (trunk base + overhanging lower canopy) so walking beneath or toppling never reveals a hole.
static func tree(geo: CityGeo, xf: Transform3D, variant: int) -> void:
	var leaf: Array = TREE_LEAVES[variant]
	geo.prism(xf, Vector3.ZERO, 0.22, 2.6, 5, _c("trunk"), 0.16, null, _c("trunk"))
	geo.prism(xf, Vector3(0, 2.2, 0), 1.25, 1.1, 6, _c(leaf[0]), 1.75, _c(leaf[0]), _c(leaf[0]))
	geo.prism(xf, Vector3(0, 3.3, 0), 1.75, 1.2, 6, _c(leaf[1]), 1.2, _c(leaf[1]))
	geo.prism(xf, Vector3(0, 4.5, 0), 1.2, 1.1, 6, _c(leaf[2]), 0.0)


## A street lamp; its arm reaches along local +Z (toward the road). Closed underneath: it can be knocked over.
static func lamp(geo: CityGeo, xf: Transform3D) -> void:
	geo.prism(xf, Vector3.ZERO, 0.2, 0.9, 6, _c("metal_dark"), 0.13, null, _c("metal_dark"))
	geo.prism(xf, Vector3(0, 0.9, 0), 0.11, 5.6, 6, _c("metal_dark"), 0.09)
	geo.box(xf, Vector3(0, 6.45, 0.8), Vector3(0.14, 0.14, 1.9), _c("metal_dark"))
	geo.box(xf, Vector3(0, 6.36, 1.5), Vector3(0.42, 0.16, 0.95), _c("cream_light"))


## A bench facing local +Z. Closed underneath: it can be knocked over.
static func bench(geo: CityGeo, xf: Transform3D) -> void:
	geo.box(xf, Vector3(0, 0.45, 0), Vector3(1.9, 0.1, 0.55), _c("trunk"))
	geo.box(xf, Vector3(0, 0.8, -0.27), Vector3(1.9, 0.45, 0.08), _c("trunk"))
	for x: float in [-0.8, 0.8]:
		geo.box(xf, Vector3(x, 0.22, 0), Vector3(0.1, 0.44, 0.5), _c("metal_dark"), CityGeo.ALL)


static func signal_pole(geo: CityGeo, xf: Transform3D) -> void:
	geo.prism(xf, Vector3.ZERO, 0.12, 4.2, 6, _c("metal_dark"), 0.1, null, _c("metal_dark"))
	geo.box(xf, Vector3(0, 4.7, 0), Vector3(0.45, 1.2, 0.4), _c("metal_dark"))
	var lights := ["terracotta", "marking_yellow", "leaf"]
	for i in 3:
		geo.box(xf, Vector3(0, 5.05 - 0.35 * float(i), 0.22), Vector3(0.24, 0.24, 0.06), _c(lights[i]))


## A street-name sign post: a pole with two blades crossed on top.
static func sign_post(geo: CityGeo, xf: Transform3D) -> void:
	geo.prism(xf, Vector3.ZERO, 0.07, 3.2, 5, _c("metal_dark"), 0.06, null, _c("metal_dark"))
	geo.box(xf, Vector3(0, 3.1, 0.35), Vector3(0.05, 0.28, 0.9), _c("sage_dark"))
	geo.box(xf, Vector3(0.35, 3.42, 0), Vector3(0.9, 0.28, 0.05), _c("sage_dark"))
	geo.box(xf, Vector3(0, 3.62, 0), Vector3(0.12, 0.08, 0.12), _c("metal_dark"))


## A litter bin. Closed underneath: it can be knocked over.
static func bin(geo: CityGeo, xf: Transform3D) -> void:
	geo.box(xf, Vector3(0, 0.45, 0), Vector3(0.55, 0.9, 0.55), _c("sage_dark"), CityGeo.ALL, _c("metal_dark"))


# --- Ceiling ---------------------------------------------------------------------------------------------
# The underside of the deck above (docs/design/ceiling-and-pillars.md). A regular grid: girders along the arc every
# GIRDER_PITCH, ribs across every RIB_PITCH, panels of half a bay each way in three tones, one long light strip down
# the middle of each girder bay, a service duct beside every other girder, a few access hatches. Pillars meet it in a
# drop panel (CityBuildings.capital), where the strips stop. Where the deck above has a hole the ceiling is cut back to
# whole panels, and you see the thickness of the slab, a rim beam and a rim light.

const PANEL_X := GIRDER_PITCH * 0.5
const PANEL_S := RIB_PITCH * 0.5
const DROP_PANEL := 5.0      ## how far a pillar's drop panel reaches past its core
const RIM := 1.6             ## width of the beam around an opening
const RIM_DROP := 2.4


## An opening snapped outward to whole ceiling panels: what is actually cut.
static func ceiling_opening(o: Rect2) -> Rect2:
	var x0 := floorf(o.position.x / PANEL_X) * PANEL_X
	var s0 := floorf(o.position.y / PANEL_S) * PANEL_S
	return Rect2(x0, s0, ceilf(o.end.x / PANEL_X) * PANEL_X - x0, ceilf(o.end.y / PANEL_S) * PANEL_S - s0)


static func _in_any(rects: Array[Rect2], x: float, s: float) -> bool:
	for r in rects:
		if r.has_point(Vector2(x, s)):
			return true
	return false


## Builds the ceiling over `area`. The strips go to their own geometry (they take the emissive material). Returns the
## strips' x positions, for the light rig.
static func ceiling(geo: CityGeo, strips: CityGeo, area: Rect2, plan: CityPlan, rng: RandomNumberGenerator) -> PackedFloat32Array:
	return ceiling_range(geo, strips, area, plan, rng, 0, ceiling_steps(area))


## How many steps ceiling_range() splits the ceiling over `area` into: one per girder bay (panels, strip, ribs), one per
## girder line (girder, duct), one for the openings' edges.
static func ceiling_steps(area: Rect2) -> int:
	var x0 := floorf(area.position.x / GIRDER_PITCH) * GIRDER_PITCH
	var x1 := ceilf(area.end.x / GIRDER_PITCH) * GIRDER_PITCH
	var nx := int(round((x1 - x0) / GIRDER_PITCH))
	return nx + (nx + 1) + 1


## Steps [from, to) of ceiling() (CityDistrict's incremental build): calling it over consecutive ranges into the same
## geos with the same rng gives exactly one ceiling() call's triangles, order and rng draws. Returns the strips' x
## positions of the bays in the range (concatenate them).
static func ceiling_range(geo: CityGeo, strips: CityGeo, area: Rect2, plan: CityPlan, rng: RandomNumberGenerator, from: int, to: int) -> PackedFloat32Array:
	var height := plan.p("ceiling")
	var x0 := floorf(area.position.x / GIRDER_PITCH) * GIRDER_PITCH
	var x1 := ceilf(area.end.x / GIRDER_PITCH) * GIRDER_PITCH
	var s0 := floorf(area.position.y / RIB_PITCH) * RIB_PITCH
	var s1 := ceilf(area.end.y / RIB_PITCH) * RIB_PITCH
	var tones := [_c("ceil_a"), _c("ceil_b"), _c("ceil_c")]
	var nx := int(round((x1 - x0) / GIRDER_PITCH))
	var ns := int(round((s1 - s0) / RIB_PITCH))
	var strip_x := PackedFloat32Array()
	var rib := _c("rib")
	var walled := plan.p("walls") >= 0.5      # CityPlan.boundary() is non-empty: the ceiling's strips stop at the walls
	var holes: Array[Rect2] = []
	for o: Rect2 in plan.site.openings:
		holes.append(ceiling_opening(o))
	var pads := plan.ceiling_heads()     # drop panels: no strip runs through a pillar's (or a downtown tower's) head
	for i in range(clampi(from, 0, nx), clampi(to, 0, nx)):
		var gx := x0 + float(i) * GIRDER_PITCH
		var mid_x := gx + PANEL_X
		strip_x.append(mid_x)
		for j in ns:
			var rs := s0 + float(j) * RIB_PITCH
			for a in 2:
				for b in 2:
					var px := gx + PANEL_X * float(a)
					var ps := rs + PANEL_S * float(b)
					if _in_any(holes, px + PANEL_X * 0.5, ps + PANEL_S * 0.5):
						continue
					var tone: Color = tones[(i * 2 + a + (j * 2 + b) * 2 + (i * j) % 2) % 3]
					geo.tag("ceil.panel")
					geo.g_rect(px, px + PANEL_X, ps, ps + PANEL_S, height, tone, false)
					if rng.randf() < 0.035:      # an access hatch into the deck above
						geo.tag("ceil.hatch")
						var cx := px + PANEL_X * 0.5 + 1.2
						var cs := ps + PANEL_S * 0.5
						geo.g_rect(cx - 1.5, cx + 1.5, cs - 1.5, cs + 1.5, height - 0.04, _c("metal_dark"), false)
						geo.g_rect(cx - 1.2, cx + 1.2, cs - 1.2, cs + 1.2, height - 0.07, _c("concrete_dark"), false)
			# The light strip in this bay: one long line hung just below the ribs, in facet-long pieces.
			var br := CityGeo.breaks(rs, rs + RIB_PITCH)
			geo.tag("ceil.strip_rib")
			strips.tag("strip")
			for k in br.size() - 1:
				var sa := br[k]
				var sb := br[k + 1]
				# Inside the boundary walls only: a piece running on into a wall ended a hair (0.5 mm) from a farm fin's face.
				if walled:
					if mid_x < plan.extent.position.x or mid_x > plan.extent.end.x:
						continue
					sa = maxf(sa, plan.extent.position.y)
					sb = minf(sb, plan.extent.end.y)
					if sb - sa < 0.1:
						continue
				var mid := (sa + sb) * 0.5
				if _in_any(holes, mid_x, mid) or _in_any(pads, mid_x, mid):
					continue
				var length := (sb - sa) * 1.005
				strips.box(geo.frame(mid_x, mid, height - 1.25), Vector3.ZERO, Vector3(1.3, 0.3, length), _c("strip"))
				geo.box(geo.frame(mid_x, mid, height - 0.55), Vector3.ZERO, Vector3(0.5, 1.1, length), rib)
			# Ribs across, one piece per girder bay so an opening can interrupt them.
			geo.tag("ceil.rib")
			for e in 2:
				var rib_s := rs + RIB_PITCH * float(e)
				if (e == 1 and j < ns - 1) or _in_any(holes, mid_x, rib_s):
					continue
				# A rib ending at an opening's edge has no end face there: it lay in the plane of the opening's inside face
				# (and of the cut face of the floor hole above), which covers it.
				var ends := CityGeo.ALL
				if _in_any(holes, gx + GIRDER_PITCH + 0.5, rib_s):
					ends -= CityGeo.PX
				if _in_any(holes, gx - 0.5, rib_s):
					ends -= CityGeo.NX
				geo.box(geo.frame(mid_x, rib_s, height - 0.3), Vector3.ZERO, Vector3(GIRDER_PITCH, 1.0, 1.2), rib, ends)
	for i in range(clampi(from - nx, 0, nx + 1), clampi(to - nx, 0, nx + 1)):
		var gx := x0 + float(i) * GIRDER_PITCH
		for j in ns:
			for half in 2:      # two pieces per bay so the girder follows the curve
				var mid := s0 + (float(j) + 0.25 + 0.5 * float(half)) * RIB_PITCH
				if _in_any(holes, gx, mid):
					continue
				geo.tag("ceil.girder")
				geo.box(geo.frame(gx, mid, height - 0.7), Vector3.ZERO, Vector3(1.5, 2.2, RIB_PITCH * 0.505), rib)
				if i % 2 == 0 and not _in_any(pads, gx + 1.7, mid):      # service duct
					geo.tag("ceil.duct")
					geo.box(geo.frame(gx + 1.7, mid, height - 1.5), Vector3.ZERO, Vector3(1.1, 0.8, RIB_PITCH * 0.505), _c("metal"))
	if from <= 2 * nx + 1 and to > 2 * nx + 1:
		geo.tag("ceil.opening")
		strips.tag("rim_light")
		for hole in holes:
			_opening(geo, strips, hole, height, plan.site.slab)
	return strip_x


## The edge of a hole in the ceiling: the cut face of the slab above, a rim beam hanging below it, a rim light.
static func _opening(geo: CityGeo, strips: CityGeo, o: Rect2, h: float, slab: float) -> void:
	var cut := _c("concrete")
	var beam := _c("concrete_dark")
	var lo := h - RIM_DROP
	var hi := h + slab
	var x0 := o.position.x
	var x1 := o.end.x
	var s0 := o.position.y
	var s1 := o.end.y
	# Inside faces, from the bottom of the rim beam up through the slab.
	geo.g_wall_x(x0, s0, s1, lo, hi, 1.0, cut)
	geo.g_wall_x(x1, s0, s1, lo, hi, -1.0, cut)
	geo.g_wall_s(s0, x0, x1, lo, hi, 1.0, cut)
	geo.g_wall_s(s1, x0, x1, lo, hi, -1.0, cut)
	# Rim beam: underside and outer faces.
	geo.g_rect(x0 - RIM, x0, s0 - RIM, s1 + RIM, lo, beam, false)
	geo.g_rect(x1, x1 + RIM, s0 - RIM, s1 + RIM, lo, beam, false)
	geo.g_rect(x0, x1, s0 - RIM, s0, lo, beam, false)
	geo.g_rect(x0, x1, s1, s1 + RIM, lo, beam, false)
	geo.g_wall_x(x0 - RIM, s0 - RIM, s1 + RIM, lo, h, -1.0, beam)
	geo.g_wall_x(x1 + RIM, s0 - RIM, s1 + RIM, lo, h, 1.0, beam)
	geo.g_wall_s(s0 - RIM, x0 - RIM, x1 + RIM, lo, h, -1.0, beam)
	geo.g_wall_s(s1 + RIM, x0 - RIM, x1 + RIM, lo, h, 1.0, beam)
	# Rim light under the beam.
	var m := RIM * 0.5
	strips.g_rect(x0 - m - 0.3, x0 - m + 0.3, s0 - m, s1 + m, lo - 0.03, _c("strip"), false)
	strips.g_rect(x1 + m - 0.3, x1 + m + 0.3, s0 - m, s1 + m, lo - 0.03, _c("strip"), false)
	strips.g_rect(x0 - m, x1 + m, s0 - m - 0.3, s0 - m + 0.3, lo - 0.03, _c("strip"), false)
	strips.g_rect(x0 - m, x1 + m, s1 + m - 0.3, s1 + m + 0.3, lo - 0.03, _c("strip"), false)


# --- Boundary walls --------------------------------------------------------------------------------------

const WALL_THICK := 6.0
const HULL_SILL := 8.0       ## solid base of the hull's window wall


## The map's edge (CityPlan.boundary()): bulkheads (panels between buttress fins, a gallery band) and window walls (a
## solid sill, then a lattice of mullions and transoms; glazed when nothing is meant to be seen through it, open frames
## when a backdrop lies beyond). Either kind stands on any side: across the arc it is one flat plane, along the arc it
## follows the facets. Gates cut the wall. Same palette, same lit material: the light rig treats them like any surface.
## Farm walls (_farm_wall) put their glowing light bars into `lights` (drawn with the strip material) when given.
## `only_side` >= 0 draws that side alone (CityDistrict builds one side per chunk); each side has its own cosmetic
## generators, so the result does not depend on how the sides are split. A farm side can be split further along its
## length (`part` of `parts`, each with its own generator; parts > 0 draw only their share of the farm's bays, fins and
## racks; part 0 draws everything else).
static func walls(geo: CityGeo, plan: CityPlan, lights: CityGeo = null, only_side: int = -1, part: int = 0, parts: int = 1) -> void:
	var e := plan.extent
	var h := plan.p("ceiling")
	var look := RandomNumberGenerator.new()
	var farm_look := RandomNumberGenerator.new()
	for w: Dictionary in plan.boundary():
		var side: int = w["side"]
		if only_side >= 0 and side != only_side:
			continue
		if part > 0 and w["kind"] != "farm":
			continue
		look.seed = plan.cosmetic_seed() + 31 + side * 1009
		farm_look.seed = plan.cosmetic_seed() + 37 + side * 1013 + part * 7919
		var across := side >= 2
		var at: float = w["at"]
		var inward := -1.0 if side % 2 == 0 else 1.0
		var u0 := e.position.x if across else e.position.y
		var u1 := e.end.x if across else e.end.y
		var gates: Array = w["gates"]
		var spans := wall_spans(u0, u1, gates)
		geo.tag("wall." + str(w["kind"]))
		if lights != null:
			lights.tag("farm_light")
		if w["kind"] == "farm":
			_farm_wall(geo, lights, across, at, inward, u0, u1, h, gates, farm_look, part, parts)
			if part > 0:
				continue      # the gates are part 0's
		elif w["kind"] == "bulkhead":
			var pitch := GIRDER_PITCH if across else RIB_PITCH * 0.5
			var u := floorf(u0 / pitch) * pitch
			var i := 0
			while u < u1:
				var col := _c("ceil_b") if i % 2 == 0 else _c("ceil_a")
				for sp: Array in wall_spans(maxf(u, u0), minf(u + pitch, u1), gates):
					_wface(geo, across, at, sp[0], sp[1], 0.0, h, inward, col)
				if _in_gate(gates, maxf(u, u0)) < 0:
					_wpost(geo, across, at, inward, maxf(u, u0), 0.7, h * 0.5, Vector3(1.6, h, 1.4), _c("rib"))
				u += pitch
				i += 1
			for g: Dictionary in gates:
				_wface(geo, across, at, g["a"], g["b"], g["h"], h, inward, _c("ceil_b"))
			_wbox(geo, across, at, inward, u0, u1, 0.9, 16.0, Vector2(1.8, 1.2), _c("concrete_dark"))
			for sp: Array in spans:
				_wbox(geo, across, at, inward, sp[0], sp[1], 0.5, 1.0, Vector2(1.0, 2.0), _c("concrete"))
		else:
			var cream := _c("cream_light")
			for sp: Array in spans:
				_wface(geo, across, at, sp[0], sp[1], 0.0, HULL_SILL, inward, _c("concrete"))
				if not w["backdrop"]:
					_wface(geo, across, at, sp[0], sp[1], HULL_SILL, h, inward, _c("sky_blue"))
				_wface(geo, across, at + inward * 0.5, sp[0], sp[1], HULL_SILL - 0.6, HULL_SILL + 0.4, inward, cream)
				_wrect(geo, across, at, inward, 0.5, sp[0], sp[1], HULL_SILL + 0.4, cream, true)
				_wrect(geo, across, at, inward, 0.5, sp[0], sp[1], HULL_SILL - 0.6, cream, false)
				var t := HULL_SILL + (h - HULL_SILL) / 3.0
				while t < h - 1.0:
					_wface(geo, across, at + inward * 0.25, sp[0], sp[1], t - 0.3, t + 0.3, inward, cream)
					_wrect(geo, across, at, inward, 0.25, sp[0], sp[1], t + 0.3, cream, true)
					_wrect(geo, across, at, inward, 0.25, sp[0], sp[1], t - 0.3, cream, false)
					t += (h - HULL_SILL) / 3.0
				var u := ceilf(sp[0] / RIB_PITCH * 2.0) * RIB_PITCH * 0.5
				while u <= sp[1]:
					_wpost(geo, across, at, inward, u, 0.4, (HULL_SILL + h) * 0.5, Vector3(0.9, h - HULL_SILL, 0.8), cream)
					u += RIB_PITCH * 0.5
			for g: Dictionary in gates:
				_wface(geo, across, at, g["a"], g["b"], g["h"], h, inward, _c("concrete"))
		# A mission's wave door (MissionWorld) stands in this gate as its own node: no baked leaf there (plan meta
		# "mission_doors": {"<side>:<a>": true}, set only by CityStack.setup_mission; absent = unchanged).
		var doors: Dictionary = plan.get_meta("mission_doors", {})
		geo.tag("wall.gate")
		for g: Dictionary in gates:
			if not doors.is_empty() and doors.has("%d:%.2f" % [side, float(g["a"])]):
				g["leaf"] = false
			_gate(geo, across, at, inward, g, look)


# --- Farm wall ---------------------------------------------------------------------------------------------
# A vertical farm instead of a window onto a backdrop (docs/design/city-styles.md "Side walls: vertical farm"). The
# solid backing stands FARM_RECESS behind the wall plane, inside the wall's collision slab, so the fins, racks and leaves
# fill that recess and stick out into the street no further than the window wall's mullions did (FARM_REACH). Collision
# is the wall's flat slab, the same for every kind (CityDistrict._col_walls).
const FARM_RECESS := 1.6       ## backing this far behind the wall plane
const FARM_REACH := 0.8        ## nothing below the haunches comes further into the map than this (the window posts' face)
const FARM_PITCH_S := 8.0      ## fin pitch on a wall along the arc (a third of RIB_PITCH)
const FARM_PITCH_X := 7.0      ## and across it (half GIRDER_PITCH)
const FARM_FIN_W := 1.1
const FARM_FIN_D0 := 0.6       ## fin face in front of the wall plane at the floor ...
const FARM_FIN_D1 := 0.15      ## ... leaning back to this under the haunch ...
const FARM_HAUNCH := 4.5       ## ... which flares out again over the top this many metres
const FARM_HAUNCH_D := 0.75
const FARM_PLINTH := 2.6       ## plinth band at the base: this tall, its face this far out
const FARM_PLINTH_D := 0.25
const FARM_COL_HALF := 2.6     ## half the width a rack and its leaves take (about two thirds of a bay)
const FARM_TUFT_STEP := 2.05   ## one big leaf tuft per this much rack height (a medium and a small one every few rows)
const FARM_BARS := [0.36, 0.58, 0.8]    ## light bar heights, fractions of the ceiling height
const FARM_BAR_H := 0.35       ## light bar: this tall, this deep, standing this far proud of the fin faces on brackets
const FARM_BAR_D := 0.3
const FARM_BAR_GAP := 0.12
const FARM_LEAVES := ["farm_leaf_dark", "farm_leaf", "farm_leaf", "farm_leaf_light"]


## The frame at point u of a wall: local X along it, Y up, +Z into the map, origin on the wall plane at the floor.
static func _wframe(geo: CityGeo, across: bool, at: float, inward: float, u: float, y: float = 0.0) -> Transform3D:
	if across:
		return geo.frame(u, at, y, 0.0 if inward > 0.0 else PI)
	return geo.frame(at, u, y, PI * 0.5 if inward > 0.0 else -PI * 0.5)


## Where the farm starts above the floor over [ua, ub]: on top of a gate's portal frame (its lintel) where it overlaps
## one, else at the floor.
static func _farm_floor(gates: Array, ua: float, ub: float) -> float:
	var y := 0.0
	for g: Dictionary in gates:
		if ub > float(g["a"]) - 1.2 and ua < float(g["b"]) + 1.2:
			y = maxf(y, float(g["h"]) + 1.6)
	return y


## The fin face's distance in front of the wall plane at height y.
static func _fin_front(y: float, h: float) -> float:
	var y1 := h - FARM_HAUNCH
	if y <= y1:
		return lerpf(FARM_FIN_D0, FARM_FIN_D1, clampf(y / y1, 0.0, 1.0))
	return lerpf(FARM_FIN_D1, FARM_HAUNCH_D, (y - y1) / FARM_HAUNCH)


static func _farm_wall(geo: CityGeo, lights: CityGeo, across: bool, at: float, inward: float, u0: float, u1: float, h: float,
		gates: Array, look: RandomNumberGenerator, part: int = 0, parts: int = 1) -> void:
	var r := FARM_RECESS
	var ux := inward if across else -inward       # local +X of _wframe is +u (1) or -u (-1)
	var pitch := FARM_PITCH_X if across else FARM_PITCH_S
	var fin := _c("farm_fin")
	var back := _c("farm_backing")
	var spans := wall_spans(u0, u1, gates) if part == 0 else []
	# This part's share of the bays, fins and racks (by where each one starts / stands): [wa, wb), the last part to u1.
	var wa := -INF if part == 0 else u0 + (u1 - u0) * float(part) / float(parts)
	var wb := INF if part == parts - 1 else u0 + (u1 - u0) * float(part + 1) / float(parts)
	# Backing: floor to ceiling, above a gate from its lintel up; a ledge on the lintel; cheeks closing the recess at the
	# wall's ends and beside each gate (part 0).
	for sp: Array in spans:
		_wface(geo, across, at - inward * r, sp[0], sp[1], 0.0, h, inward, back)
		var y_a := 0.0 if is_equal_approx(float(sp[0]), u0) else _gate_top(gates, sp[0])
		var y_b := 0.0 if is_equal_approx(float(sp[1]), u1) else _gate_top(gates, sp[1])
		_farm_cheek(geo, across, at, inward, ux, sp[0], 1.0, h if y_a == 0.0 else y_a, back)
		_farm_cheek(geo, across, at, inward, ux, sp[1], -1.0, h if y_b == 0.0 else y_b, back)
	for g: Dictionary in (gates if part == 0 else []):
		var top := float(g["h"]) + 1.6
		_wface(geo, across, at - inward * r, g["a"], g["b"], top, h, inward, back)
		_wrect(geo, across, at - inward * r, inward, r, g["a"], g["b"], top, fin, true)
	# Bays: plinth, feed pipes and the top beam per bay piece (the plinth and pipes stop at gates), light bars across all.
	var k := floorf(u0 / pitch)
	while k * pitch < u1 - 0.01:
		var pa := maxf(k * pitch, u0)
		var pb := minf((k + 1.0) * pitch, u1)
		k += 1.0
		if pb - pa < 0.05 or pa < wa or pa >= wb:
			continue
		_farm_band(geo, across, at, inward, ux, pa, pb, h - 1.4, h, -r, 0.5, fin, CityGeo.PZ | CityGeo.NY)
		for sp: Array in wall_spans(pa, pb, gates):
			var ends := 0
			if is_equal_approx(float(sp[0]), u0) or _gate_top(gates, sp[0]) > 0.0:
				ends |= CityGeo.NX if ux > 0.0 else CityGeo.PX
			if is_equal_approx(float(sp[1]), u1) or _gate_top(gates, sp[1]) > 0.0:
				ends |= CityGeo.PX if ux > 0.0 else CityGeo.NX
			_farm_band(geo, across, at, inward, ux, sp[0], sp[1], -0.3, FARM_PLINTH, -r, FARM_PLINTH_D, fin, CityGeo.PZ | CityGeo.PY | ends)
			for py: float in [0.7, 1.55]:
				_farm_band(geo, across, at, inward, ux, sp[0], sp[1], py - 0.2, py + 0.2, FARM_PLINTH_D, FARM_PLINTH_D + 0.4,
						_c("farm_pipe"), CityGeo.PZ | CityGeo.PY)
		if lights != null:
			# Each bar: one straight box in a constant plane just proud of the fin faces, one piece per deck facet on a
			# wall along the arc (so it follows the facets like everything else), front and underside only.
			for f: float in FARM_BARS:
				var y := h * f
				var z0 := _fin_front(y, h) + FARM_BAR_GAP
				for sp: Array in _bar_spans(pa, pb, gates, y):
					var br := PackedFloat32Array([sp[0], sp[1]]) if across else CityGeo.breaks(sp[0], sp[1])
					for j in br.size() - 1:
						_farm_band(lights, across, at, inward, ux, br[j], br[j + 1], y - FARM_BAR_H * 0.5, y + FARM_BAR_H * 0.5,
								z0, z0 + FARM_BAR_D, _c("strip"), CityGeo.PZ | CityGeo.NY)
	# Fins: every pitch, plus one at each end of the wall.
	var fins: Array[float] = [u0 + FARM_FIN_W * 0.5, u1 - FARM_FIN_W * 0.5]
	k = ceilf(u0 / pitch)
	while k * pitch < u1:
		var u := k * pitch
		k += 1.0
		if absf(u - fins[0]) > 2.0 and absf(u - fins[1]) > 2.0:
			fins.append(u)
	for u in fins:
		if u < wa or u >= wb:
			continue
		var y0 := _farm_floor(gates, u - FARM_FIN_W * 0.5, u + FARM_FIN_W * 0.5)
		var ff := _wframe(geo, across, at, inward, u)
		_farm_fin(geo, ff, y0, h, fin)
		# A short dark bracket from the fin face to each light bar that runs past it.
		if lights != null:
			for f: float in FARM_BARS:
				var y := h * f
				if y > y0 + 0.5 and not _bar_spans(u - 0.05, u + 0.05, gates, y).is_empty():
					var d0 := _fin_front(y, h)
					geo.box(ff, Vector3(0, y, d0 + FARM_BAR_GAP * 0.5), Vector3(0.3, 0.22, FARM_BAR_GAP + 0.06), _c("metal_dark"),
							CityGeo.PX | CityGeo.NX | CityGeo.NY)
	# Racks: one per bay, in the middle, wherever it fits clear of the ends.
	k = floorf(u0 / pitch)
	while k * pitch < u1:
		var uc := (k + 0.5) * pitch
		k += 1.0
		if uc - FARM_COL_HALF < u0 + FARM_FIN_W or uc + FARM_COL_HALF > u1 - FARM_FIN_W or uc < wa or uc >= wb:
			continue
		var yb := _farm_floor(gates, uc - FARM_COL_HALF, uc + FARM_COL_HALF)
		_farm_rack(geo, _wframe(geo, across, at, inward, uc), yb if yb > 0.0 else FARM_PLINTH, h - 2.2, yb == 0.0, look)


## The top of the gate whose edge is at u (its lintel), 0 if no gate edge is there.
static func _gate_top(gates: Array, u: float) -> float:
	for g: Dictionary in gates:
		if is_equal_approx(float(g["a"]), u) or is_equal_approx(float(g["b"]), u):
			return float(g["h"]) + 1.6
	return 0.0


## [pa, pb] where a light bar at height y runs: everywhere but across a gate's opening and frame below its lintel.
static func _bar_spans(pa: float, pb: float, gates: Array, y: float) -> Array:
	var cut := []
	for g: Dictionary in gates:
		if y < float(g["h"]) + 1.6:
			cut.append({"a": float(g["a"]) - 1.2, "b": float(g["b"]) + 1.2})
	return wall_spans(pa, pb, cut)


## A straight band along the wall from ua to ub (one piece: a bay at most), from y0 to y1 up and z0 to z1 out from the
## wall plane (+ into the map). `faces` as CityGeo.box, in the frame at its middle.
static func _farm_band(geo: CityGeo, across: bool, at: float, inward: float, _ux: float, ua: float, ub: float, y0: float, y1: float,
		z0: float, z1: float, col: Color, faces: int) -> void:
	var f := _wframe(geo, across, at, inward, (ua + ub) * 0.5)
	geo.box(f, Vector3(0, (y0 + y1) * 0.5, (z0 + z1) * 0.5), Vector3(ub - ua + 0.04, y1 - y0, z1 - z0), col, faces)


## A side wall of the recess at u, from the backing to the wall plane, floor to y1, facing +u (dir 1) or -u (dir -1).
static func _farm_cheek(geo: CityGeo, across: bool, at: float, inward: float, ux: float, u: float, dir: float, y1: float, col: Color) -> void:
	var f := _wframe(geo, across, at, inward, u)
	var r := FARM_RECESS
	if dir * ux > 0.0:
		geo.quad(f * Vector3(0, 0, 0), f * Vector3(0, 0, -r), f * Vector3(0, y1, -r), f * Vector3(0, y1, 0), col)
	else:
		geo.quad(f * Vector3(0, 0, -r), f * Vector3(0, 0, 0), f * Vector3(0, y1, 0), f * Vector3(0, y1, -r), col)


## A buttress fin in frame f from y0 to the ceiling: back on the backing, face leaning back from FARM_FIN_D0 to
## FARM_FIN_D1, then a haunch flaring out to the ceiling. Face and two sides (12 triangles), plus two big plain details
## on the face so it is not a blank plane at mech eye height: a darker kick plate at its foot and a dark service channel
## up its middle (4 triangles).
static func _farm_fin(geo: CityGeo, f: Transform3D, y0: float, h: float, col: Color) -> void:
	var y1 := h - FARM_HAUNCH
	if y1 - y0 > 4.0:
		var e := DECAL_PATCH      # just proud of the face (the decal rule: 2 cm; was 1.5 cm)
		var k1 := y0 + 1.4
		geo.quad(f * Vector3(-FARM_FIN_W * 0.5, y0, _fin_front(y0, h) + e), f * Vector3(FARM_FIN_W * 0.5, y0, _fin_front(y0, h) + e),
				f * Vector3(FARM_FIN_W * 0.5, k1, _fin_front(k1, h) + e), f * Vector3(-FARM_FIN_W * 0.5, k1, _fin_front(k1, h) + e), _c("concrete_dark"))
		var c0 := k1 + 0.8
		var c1 := y1 - 0.8
		geo.quad(f * Vector3(-0.17, c0, _fin_front(c0, h) + e), f * Vector3(0.17, c0, _fin_front(c0, h) + e),
				f * Vector3(0.17, c1, _fin_front(c1, h) + e), f * Vector3(-0.17, c1, _fin_front(c1, h) + e), _c("farm_backing"))
	var hw := FARM_FIN_W * 0.5
	var r := FARM_RECESS
	var ys: Array[float] = [y0, maxf(h - FARM_HAUNCH, y0), h]
	for i in 2:
		var ya := ys[i]
		var yb := ys[i + 1]
		if yb - ya < 0.01:
			continue
		var da := _fin_front(ya, h)
		var db := _fin_front(yb, h)
		geo.quad(f * Vector3(-hw, ya, da), f * Vector3(hw, ya, da), f * Vector3(hw, yb, db), f * Vector3(-hw, yb, db), col)
		geo.quad(f * Vector3(hw, ya, da), f * Vector3(hw, ya, -r), f * Vector3(hw, yb, -r), f * Vector3(hw, yb, db), col)
		geo.quad(f * Vector3(-hw, ya, -r), f * Vector3(-hw, ya, da), f * Vector3(-hw, yb, db), f * Vector3(-hw, yb, -r), col)


## A hydroponic rack in frame f from yb to yt: a planter at its foot (with a feed riser from the pipes when it stands on
## the plinth), a pale spine, a hood at the top, and big faceted leaf tufts up its face in two or three greens.
static func _farm_rack(geo: CityGeo, f: Transform3D, yb: float, yt: float, riser: bool, look: RandomNumberGenerator) -> void:
	var r := FARM_RECESS
	var rack := _c("farm_rack")
	var side_faces := CityGeo.PX | CityGeo.NX | CityGeo.PZ
	var wide := FARM_COL_HALF * 2.0 - 0.6
	geo.box(f, Vector3(0, yb + 0.6, (-r + 0.35) * 0.5), Vector3(wide, 1.2, r + 0.35), _c("farm_planter"), side_faces | CityGeo.PY)
	if riser:
		geo.box(f, Vector3(1.6, (1.55 + yb + 0.4) * 0.5, 0.5), Vector3(0.34, yb + 0.4 - 1.55, 0.34), _c("farm_pipe"), side_faces)
	# The green core: from far the rack reads as one solid column of leaves, the tufts give it facets up close.
	geo.box(f, Vector3(0, (yb + 1.2 + yt) * 0.5, -r + 0.45), Vector3(wide - 1.2, yt - yb - 1.2, 0.9), _c("farm_leaf_dark"), side_faces)
	geo.box(f, Vector3(0, yt + 0.25, (-r + 0.1) * 0.5), Vector3(wide, 0.5, r + 0.1), rack, side_faces | CityGeo.NY)
	# Leaf mass: overlapping tufts of three sizes, a big one per row swapping sides, a medium one on the other side every
	# other row and a small one tucked in every third, each jittered in size, turn, offset and depth, so the column reads
	# as one lumpy mass rather than a stack of identical pyramids.
	var zb := -r + 0.92
	var y := yb + 1.2 + FARM_TUFT_STEP * 0.5
	var i := 0
	while y < yt - 0.6:
		var s := 1.0 if i % 2 == 0 else -1.0
		_tuft(geo, f, look, Vector2(s * 0.8, y), Vector2(2.05, 1.65), zb, 0.9)
		if i % 2 == 1:
			_tuft(geo, f, look, Vector2(-s * 1.3, y + 0.7), Vector2(1.4, 1.2), zb + 0.08, 0.7)
		elif i % 3 == 0:
			_tuft(geo, f, look, Vector2(-s * 1.0, y - 0.5), Vector2(0.95, 0.8), zb + 0.14, 0.55)
		y += FARM_TUFT_STEP
		i += 1


## One leaf tuft on a rack's face: an irregular pentagon at depth zb in frame f around c (rack-local x, height), radii
## up to `size`, with its tip pushed out up to `out` metres: five faceted triangles, a seeded green.
static func _tuft(geo: CityGeo, f: Transform3D, look: RandomNumberGenerator, c: Vector2, size: Vector2, zb: float, out: float) -> void:
	var k := look.randf_range(0.78, 1.0)
	var cx := c.x + look.randf_range(-0.25, 0.25)
	var cy := c.y + look.randf_range(-0.25, 0.25)
	var col := _c(FARM_LEAVES[look.randi_range(0, FARM_LEAVES.size() - 1)])
	var z := zb + look.randf_range(-0.04, 0.06)
	var apex := f * Vector3(cx + look.randf_range(-0.3, 0.3) * k, cy + look.randf_range(-0.15, 0.3) * k, z + out * look.randf_range(0.7, 1.0))
	var a0 := look.randf_range(0.0, TAU)
	var rim: Array[Vector3] = []
	for j in 5:
		var a := a0 + TAU * float(j) / 5.0 + look.randf_range(-0.3, 0.3)
		var m := look.randf_range(0.7, 1.0) * k
		rim.append(f * Vector3(cx + cos(a) * size.x * m, cy + sin(a) * size.y * m, z))
	for j in 5:
		geo.tri(rim[j], rim[(j + 1) % 5], apex, col)


## [u0, u1] minus the gate openings.
static func wall_spans(u0: float, u1: float, gates: Array) -> Array:
	var spans := [[u0, u1]]
	for g: Dictionary in gates:
		var next := []
		for sp: Array in spans:
			if float(g["b"]) <= sp[0] or float(g["a"]) >= sp[1]:
				next.append(sp)
				continue
			if float(g["a"]) > sp[0]:
				next.append([sp[0], float(g["a"])])
			if float(g["b"]) < sp[1]:
				next.append([float(g["b"]), sp[1]])
		spans = next
	return spans


static func _in_gate(gates: Array, u: float) -> int:
	for i in gates.size():
		if u > float(gates[i]["a"]) and u < float(gates[i]["b"]):
			return i
	return -1


## A wall face from u0 to u1 along the wall at `at`, facing into the map.
static func _wface(geo: CityGeo, across: bool, at: float, u0: float, u1: float, h0: float, h1: float, inward: float, col: Color) -> void:
	if across:
		geo.g_wall_s(at, u0, u1, h0, h1, inward, col)
	else:
		geo.g_wall_x(at, u0, u1, h0, h1, inward, col)


## A level strip on the wall, from the wall plane `depth` into the map.
static func _wrect(geo: CityGeo, across: bool, at: float, inward: float, depth: float, u0: float, u1: float, hgt: float, col: Color, up: bool) -> void:
	var d0 := minf(at, at + inward * depth)
	var d1 := maxf(at, at + inward * depth)
	if across:
		geo.g_rect(u0, u1, d0, d1, hgt, col, up)
	else:
		geo.g_rect(d0, d1, u0, u1, hgt, col, up)


## A box at one point u of the wall, `d` in from it at height y. size = (along the wall, up, into the map).
static func _wpost(geo: CityGeo, across: bool, at: float, inward: float, u: float, d: float, y: float, size: Vector3, col: Color) -> void:
	if across:
		geo.box(geo.frame(u, at + inward * d, y), Vector3.ZERO, Vector3(size.x, size.y, size.z), col)
	else:
		geo.box(geo.frame(at + inward * d, u, y), Vector3.ZERO, Vector3(size.z, size.y, size.x), col)


## A long box along the wall from u0 to u1 (facet-long pieces on a wall along the arc). size = (into the map, up).
static func _wbox(geo: CityGeo, across: bool, at: float, inward: float, u0: float, u1: float, d: float, y: float, size: Vector2, col: Color) -> void:
	if across:
		geo.box(geo.frame((u0 + u1) * 0.5, at + inward * d, y), Vector3.ZERO, Vector3(u1 - u0, size.y, size.x), col)
		return
	var br := CityGeo.breaks(u0, u1)
	for i in br.size() - 1:
		geo.box(geo.frame(at + inward * d, (br[i] + br[i + 1]) * 0.5, y), Vector3.ZERO, Vector3(size.x, size.y, br[i + 1] - br[i]), col)


## A gate in the wall, in a frame whose local +Z points into the map: a hazard portal round the opening, and behind it
## the sealed door leaves (blast_door), a dark recess, the way in or out (portal), or a recess choked with rubble
## (collapsed).
static func _gate(geo: CityGeo, across: bool, at: float, inward: float, g: Dictionary, look: RandomNumberGenerator) -> void:
	var ga: float = g["a"]
	var gb: float = g["b"]
	var gh: float = g["h"]
	var mid := (ga + gb) * 0.5
	var half := (gb - ga) * 0.5 - 0.6
	var f: Transform3D
	if across:
		f = geo.frame(mid, at, 0.0, 0.0 if inward > 0.0 else PI)
	else:
		f = geo.frame(at, mid, 0.0, PI * 0.5 if inward > 0.0 else -PI * 0.5)
	var kind := str(g["kind"])
	if kind == "blast_door":
		if g.get("leaf", true):      # false: a MissionWorld door node stands here instead
			geo.box(f, Vector3(0, gh * 0.5, 0.5), Vector3(half * 2.0, gh, 1.0), _c("metal_dark"), CityGeo.NO_BACK)
			geo.box(f, Vector3(0, gh * 0.5, 1.05), Vector3(0.5, gh, 0.12), _c("metal"), CityGeo.NO_BACK)
			for k: float in [-1.0, 1.0]:
				geo.box(f, Vector3(k * half * 0.5, gh * 0.55, 1.03), Vector3(half * 0.6, 1.0, 0.1), _c("marking_yellow"), CityGeo.NO_BACK)
		# A hatched keep-clear box on the road in front of the gate.
		var n := int(half * 2.0 / 2.0)
		for k in n:
			var gx := ga + 0.6 + (float(k) + 0.25) * (half * 2.0 / float(n))
			_wrect(geo, across, at + inward * 1.5, inward, 5.0, gx, gx + 0.5, MARK, _c("marking_yellow"), true)
	else:
		_recess(geo, f, half + 0.6, gh, 6.0, _c("glass_dark") if kind == "portal" else _c("concrete_dark"))
	if kind == "collapsed":
		var count := look.randi_range(8, 12)
		for i in count:
			var size := Vector3(look.randf_range(2.5, 6.0), look.randf_range(1.5, 4.0), look.randf_range(2.0, 5.0))
			var pos := Vector3(look.randf_range(-half + 1.5, half - 1.5), look.randf_range(0.5, gh * 0.7), look.randf_range(-4.0, 1.0))
			var tilt := Basis.from_euler(Vector3(look.randf_range(-0.5, 0.5), look.randf_range(-PI, PI), look.randf_range(-0.5, 0.5)))
			geo.box(f * Transform3D(tilt, pos), Vector3.ZERO, size, _c("concrete") if i % 2 == 0 else _c("concrete_dark"))
	for k: float in [-1.0, 1.0]:
		geo.box(f, Vector3(k * (half + 0.9), (gh + 1.6) * 0.5, 0.9), Vector3(1.8, gh + 1.6, 1.8), _c("tactile"), CityGeo.NO_BACK)
	geo.box(f, Vector3(0, gh + 0.8, 0.9), Vector3(half * 2.0 + 3.6, 1.6, 1.8), _c("tactile"), CityGeo.NO_BACK)


## The inside of a box behind a gate opening (local -Z is out of the map), faces turned inward: back, sides, top, floor.
static func _recess(geo: CityGeo, f: Transform3D, w: float, gh: float, depth: float, col: Color) -> void:
	var d := -depth
	var fl := 0.02
	geo.quad(f * Vector3(-w, 0, d), f * Vector3(w, 0, d), f * Vector3(w, gh, d), f * Vector3(-w, gh, d), col)
	geo.quad(f * Vector3(-w, 0, 0), f * Vector3(-w, 0, d), f * Vector3(-w, gh, d), f * Vector3(-w, gh, 0), col)
	geo.quad(f * Vector3(w, 0, d), f * Vector3(w, 0, 0), f * Vector3(w, gh, 0), f * Vector3(w, gh, d), col)
	geo.quad(f * Vector3(-w, gh, 0), f * Vector3(-w, gh, d), f * Vector3(w, gh, d), f * Vector3(w, gh, 0), col)
	geo.quad(f * Vector3(-w, fl, 0), f * Vector3(w, fl, 0), f * Vector3(w, fl, d), f * Vector3(-w, fl, d), col)


# --- Backdrop --------------------------------------------------------------------------------------------

## What lies past the district: more deck, the avenue climbing on, and plain blocks in hazy colours. No detail, no
## collision: scenery for the curved horizon.
static func backdrop_area(plan: CityPlan) -> Rect2:
	var e := plan.extent
	return Rect2(e.position.x - BACK_X, e.position.y - BACK_S, e.size.x + BACK_X * 2.0, e.size.y + BACK_S * 2.0)


## The backdrop beyond one side only (a window wall's view): the extent pushed out past that side.
static func backdrop_edge(plan: CityPlan, side: int) -> Rect2:
	var e := plan.extent
	match side:
		0: return Rect2(e.position.x, e.position.y, e.size.x + BACK_X, e.size.y)
		1: return Rect2(e.position.x - BACK_X, e.position.y, e.size.x + BACK_X, e.size.y)
		2: return Rect2(e.position.x, e.position.y, e.size.x, e.size.y + BACK_S)
	return Rect2(e.position.x, e.position.y - BACK_S, e.size.x, e.size.y + BACK_S)


## Fills `area` (default: all round the district) outside the extent.
static func backdrop(geo: CityGeo, plan: CityPlan, rng: RandomNumberGenerator, area: Rect2 = Rect2()) -> void:
	var e := plan.extent
	if not area.has_area():
		area = backdrop_area(plan)
	var ground := _c("sidewalk_band")
	var h := -0.02
	_back_rect(geo, area.position.x, area.end.x, area.position.y, e.position.y, h, ground)
	_back_rect(geo, area.position.x, area.end.x, e.end.y, area.end.y, h, ground)
	_back_rect(geo, area.position.x, e.position.x, e.position.y, e.end.y, h, ground)
	_back_rect(geo, e.end.x, area.end.x, e.position.y, e.end.y, h, ground)
	# The avenue carries on up the curve, and the cross streets run on out to the sides.
	var av := plan.avenue_x()
	var av_mid := (av.x + av.y) * 0.5
	for road: Dictionary in plan.roads_x:
		_back_rect(geo, float(road["a"]), float(road["b"]), area.position.y, e.position.y, 0.0, _c("asphalt"))
		_back_rect(geo, float(road["a"]), float(road["b"]), e.end.y, area.end.y, 0.0, _c("asphalt"))
		if road["kind"] == "avenue" or road["kind"] == "spine":
			_back_rect(geo, av_mid - 5.2, av_mid + 5.2, area.position.y, e.position.y, 0.01, _c("lane_tan"))
			_back_rect(geo, av_mid - 5.2, av_mid + 5.2, e.end.y, area.end.y, 0.01, _c("lane_tan"))
	for road: Dictionary in plan.roads_s:
		_back_rect(geo, area.position.x, e.position.x, float(road["a"]), float(road["b"]), 0.0, _c("asphalt"))
		_back_rect(geo, e.end.x, area.end.x, float(road["a"]), float(road["b"]), 0.0, _c("asphalt"))
	# Far blocks: one plain box per cell of a coarse grid, kept off the roads.
	var far := ["far_a", "far_b", "far_c", "far_d", "far_a"]
	var cell := 24.0
	var radius := plan.p("radius")
	var top := plan.stand_limit()
	var x := area.position.x + cell * 0.5
	while x < area.end.x:
		var s := area.position.y + cell * 0.5
		while s < area.end.y:
			var inside := e.grow(2.0).has_point(Vector2(x, s))
			var on_road := false
			for road: Dictionary in plan.roads_x:
				if x + cell * 0.4 > float(road["a"]) and x - cell * 0.4 < float(road["b"]):
					on_road = true
			if not inside and not e.grow(cell * 0.45).has_point(Vector2(x, s)):
				for road: Dictionary in plan.roads_s:
					if s + cell * 0.4 > float(road["a"]) and s - cell * 0.4 < float(road["b"]) and (x < e.position.x or x > e.end.x):
						on_road = true
			var roll := rng.randf()
			var height := rng.randf_range(7.0, top)
			var w := rng.randf_range(0.55, 0.8) * cell
			var d := rng.randf_range(0.55, 0.8) * cell * (radius - height) / radius
			var col := _c(far[rng.randi_range(0, far.size() - 1)])
			if not inside and not on_road and not e.grow(cell * 0.45).has_point(Vector2(x, s)) and roll < 0.85:
				geo.box(geo.frame(x, s, 0.0), Vector3(0, height * 0.5 - 0.5, 0), Vector3(w, height + 1.0, d), col, CityGeo.NO_BOTTOM, _c("roof"))
			s += cell
		x += cell


static func _back_rect(geo: CityGeo, x0: float, x1: float, s0: float, s1: float, h: float, col: Color) -> void:
	if x1 - x0 > 0.01 and s1 - s0 > 0.01:
		geo.g_rect(x0, x1, s0, s1, h, col)
