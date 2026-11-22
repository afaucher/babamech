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
const MARK := 0.02           ## markings sit this far above the road
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
	var e := plan.extent
	var cuts := plan.floor_cuts()
	geo.holes = cuts
	geo.g_rect(e.position.x, e.end.x, e.position.y, e.end.y, 0.0, _c("asphalt"))
	for i in plan.roads_x.size():
		if plan.roads_x[i]["kind"] == "spine":
			_spine(geo, plan.roads_x[i], plan.roads_s)
		else:
			_road(geo, plan.roads_x[i], plan.roads_s, false)
	for j in plan.roads_s.size():
		_road(geo, plan.roads_s[j], plan.roads_x, true)
	for b: Dictionary in plan.blocks:
		_block(geo, b["rect"])
	for l: Dictionary in plan.lots:
		if l["kind"] == "open":
			_open_lot(geo, l)
	for o in cuts:
		_floor_hole(geo, o, plan.site.slab, plan.ramp_mouth(o))
	_soffits(geo, cuts, plan.site.slab)


## A rectangle on the road. `swap` false: u is x (across a road that runs along s), v is s. True: the other way round.
static func _r(geo: CityGeo, swap: bool, u0: float, u1: float, v0: float, v1: float, col: Color, h: float = MARK) -> void:
	if swap:
		geo.g_rect(v0, v1, u0, u1, h, col)
	else:
		geo.g_rect(u0, u1, v0, v1, h, col)


## `zebra` false: the crossings are drawn by the caller (the spine draws them across all its lanes at once).
static func _road(geo: CityGeo, road: Dictionary, crossings: Array, swap: bool, zebra: bool = true) -> void:
	var a: float = road["a"]
	var b: float = road["b"]
	var mid := (a + b) * 0.5
	var avenue: bool = road["kind"] == "avenue"
	var white := _c("marking")
	for j in crossings.size() - 1:
		var v0: float = crossings[j]["b"]
		var v1: float = crossings[j + 1]["a"]
		# Gutters along both curbs.
		if zebra:
			_r(geo, swap, a, a + 0.5, v0, v1, _c("asphalt_dark"), 0.012)
			_r(geo, swap, b - 0.5, b, v0, v1, _c("asphalt_dark"), 0.012)
		# Zebra crossings and stop lines at both ends.
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
			_r(geo, swap, mid - 5.2, mid + 5.2, v0, v1, _c("lane_tan"), 0.008)
			_median(geo, swap, mid - 1.5, mid + 1.5, m0 + 2.0, m1 - 2.0)
			_dashes(geo, swap, mid - 5.2, m0, m1, 3.0, 7.0, white)
			_dashes(geo, swap, mid + 5.2, m0, m1, 3.0, 7.0, white)
			_r(geo, swap, mid - 1.95, mid - 1.8, m0, m1, white)
			_r(geo, swap, mid + 1.8, mid + 1.95, m0, m1, white)
			_r(geo, swap, a + 0.9, a + 1.05, m0, m1, white)
			_r(geo, swap, b - 1.05, b - 0.9, m0, m1, white)
		else:
			# Parking strips with bay ticks, a dashed centre line.
			for k in 2:
				var p0 := a + 0.5 if k == 0 else b - 2.8
				_r(geo, swap, p0, p0 + 2.3, m0, m1, _c("asphalt_light"), 0.008)
				var edge := p0 + 2.3 if k == 0 else p0 - 0.12
				_r(geo, swap, edge, edge + 0.12, m0, m1, white)
				var t := m0
				while t <= m1 + 0.01:
					_r(geo, swap, p0, p0 + 2.3, t - 0.06, t + 0.06, white)
					t += (m1 - m0) / maxf(round((m1 - m0) / 6.0), 1.0)
			_dashes(geo, swap, mid, m0, m1, 2.5, 6.0, white)


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
		_r(geo, false, a, a + 0.5, v0, v1, _c("asphalt_dark"), 0.012)
		_r(geo, false, b - 0.5, b, v0, v1, _c("asphalt_dark"), 0.012)
		_zebra(geo, false, a, b, v0 + 1.8)
		_zebra(geo, false, a, b, v1 - 4.8)
	for lane: Dictionary in road["lanes"]:
		var la: float = lane["a"]
		var lb: float = lane["b"]
		match str(lane["lane"]):
			"avenue":
				_road(geo, {"a": la, "b": lb, "kind": "avenue"}, crossings, false, false)
			"rail":
				_rail(geo, la, lb, crossings)
			_:
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
		_r(geo, false, a + 0.6, b - 0.6, float(crossings[j]["b"]), float(crossings[j + 1]["a"]), _c("concrete_dark"), 0.01)
	var mid := (a + b) * 0.5
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
	_slope_rect(geo, r, x0 + PARAPET_W, x1 - PARAPET_W, span.x, span.y, 0.0, _c("asphalt"))
	for k: float in [-1.0, 1.0]:
		var edge := mid + k * ((x1 - x0) * 0.5 - 0.9)
		_slope_rect(geo, r, minf(edge, edge - k * 0.15), maxf(edge, edge - k * 0.15), span.x, span.y, MARK, white)
	var d := span.x + (fmod(span.y - span.x, 6.0) + 6.0 - 2.5) * 0.5
	while d + 2.5 <= span.y:
		_slope_rect(geo, r, mid - 0.08, mid + 0.08, d, d + 2.5, MARK, white)
		d += 6.0
	# Underside where it is open: the soffit between two edge beams (bottom and inner face each).
	var deep := -RAMP_THICK - BEAM_D
	_slope_rect(geo, r, x0 + BEAM_W, x1 - BEAM_W, raised.x, raised.y, -RAMP_THICK, dark, false)
	_slope_rect(geo, r, x0, x0 + BEAM_W, raised.x, raised.y, deep, concrete, false)
	_slope_rect(geo, r, x1 - BEAM_W, x1, raised.x, raised.y, deep, concrete, false)
	_slope_wall(geo, r, x0 + BEAM_W, raised.x, raised.y, deep, -RAMP_THICK, 1.0, concrete)
	_slope_wall(geo, r, x1 - BEAM_W, raised.x, raised.y, deep, -RAMP_THICK, -1.0, concrete)
	# Parapets: cap, inner face, outer face (the fascia, down past the edge beam; to the floor on the embankment).
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
	for eb in end_blocks(r, span):
		geo.box(geo.frame(eb.x, eb.y, eb.z), Vector3(0, -(END_H + 0.3) * 0.5 + END_H, 0), Vector3(END_W, END_H + 0.3, END_L), concrete, CityGeo.NO_BOTTOM, _c("curb"))
	if low.y > low.x:
		# The embankment's high end closes the space under the ribbon (and the edge beams' ends); piers carry the rest.
		geo.g_wall_s(emb, x0, x1, 0.0, PIER_MIN - RAMP_THICK, -away, concrete)
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
	for px: float in [float(r["x0"]) + PARAPET_W * 0.5, float(r["x1"]) - PARAPET_W * 0.5]:
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
		geo.g_rect(v0 + 0.3, v1 - 0.3, u0 + 0.3, u1 - 0.3, CURB + 0.01, _c("lawn"))
	else:
		geo.g_slab(u0, u1, v0, v1, 0.0, CURB, curb)
		geo.g_rect(u0 + 0.3, u1 - 0.3, v0 + 0.3, v1 - 0.3, CURB + 0.01, _c("lawn"))


## A horizontal-ish quad with a height at each corner: (x0,s0) (x0,s1) (x1,s1) (x1,s0).
static func _up_quad(geo: CityGeo, x0: float, x1: float, s0: float, s1: float, h00: float, h01: float, h11: float, h10: float, col: Color) -> void:
	geo.g_quad(Vector3(x0, s0, h00), Vector3(x0, s1, h01), Vector3(x1, s1, h11), Vector3(x1, s0, h10), col)


static func _both(geo: CityGeo, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	geo.g_tri(a, b, c, col)
	geo.g_tri(a, c, b, col)


## A block: the raised sidewalk slab with its curb, furnishing band and corner ramps.
static func _block(geo: CityGeo, r: Rect2) -> void:
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


static func _open_lot(geo: CityGeo, l: Dictionary) -> void:
	var r: Rect2 = (l["rect"] as Rect2).grow(-0.6)
	var h := CURB + 0.02
	match str(l["open"]):
		"garden":
			geo.g_slab(r.position.x, r.end.x, r.position.y, r.end.y, CURB, CURB + 0.25, _c("curb"))
			geo.g_rect(r.position.x + 0.3, r.end.x - 0.3, r.position.y + 0.3, r.end.y - 0.3, CURB + 0.26, _c("lawn"))
		"plaza":
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("plaza"))
			var n := maxi(int(r.size.y / 4.0), 1)
			for i in n:
				if i % 2 == 0:
					var a := r.position.y + r.size.y * float(i) / float(n)
					geo.g_rect(r.position.x + 0.6, r.end.x - 0.6, a + 0.3, a + r.size.y / float(n) - 0.3, h + 0.01, _c("plaza_alt"))
		"court":
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("asphalt_light"))
			var x := r.position.x + 2.6
			while x < r.end.x - 1.0:
				geo.g_rect(x - 0.06, x + 0.06, r.position.y + 0.5, r.position.y + 5.0, h + 0.01, _c("marking"))
				geo.g_rect(x - 0.06, x + 0.06, r.end.y - 5.0, r.end.y - 0.5, h + 0.01, _c("marking"))
				x += 2.6
		"park":
			geo.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, _c("lawn"))
			var c := r.get_center()
			geo.g_rect(c.x - 1.5, c.x + 1.5, r.position.y, r.end.y, h + 0.01, _c("plaza"))
			geo.g_rect(r.position.x, r.end.x, c.y - 1.5, c.y + 1.5, h + 0.01, _c("plaza"))
			geo.g_rect(c.x - 5.0, c.x + 5.0, c.y - 5.0, c.y + 5.0, h + 0.012, _c("plaza"))


# --- Furniture -------------------------------------------------------------------------------------------
# Only what cannot move: tree pits under the street trees, plaza planters, the park fountain. Trees, lamps, signal poles,
# signs, benches and bins are CityProps (they fall over), placed by CityProps.layout(); the shapes below are their
# prototypes, drawn upright at the origin of `xf`.

## `items` is CityProps.layout(plan): a pit goes under every street tree, so pits and trees always line up.
static func furniture(geo: CityGeo, plan: CityPlan, items: Array) -> void:
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
	var holes: Array[Rect2] = []
	for o: Rect2 in plan.site.openings:
		holes.append(ceiling_opening(o))
	var pads: Array[Rect2] = []       # drop panels: no strip runs through a pillar's head
	for q: Dictionary in plan.site.pillars:
		var m := float(q["half"]) + DROP_PANEL
		pads.append(Rect2(float(q["x"]) - m, float(q["s"]) - m, m * 2.0, m * 2.0))
	for i in nx:
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
					geo.g_rect(px, px + PANEL_X, ps, ps + PANEL_S, height, tone, false)
					if rng.randf() < 0.035:      # an access hatch into the deck above
						var cx := px + PANEL_X * 0.5 + 1.2
						var cs := ps + PANEL_S * 0.5
						geo.g_rect(cx - 1.5, cx + 1.5, cs - 1.5, cs + 1.5, height - 0.04, _c("metal_dark"), false)
						geo.g_rect(cx - 1.2, cx + 1.2, cs - 1.2, cs + 1.2, height - 0.07, _c("concrete_dark"), false)
			# The light strip in this bay: one long line hung just below the ribs, in facet-long pieces.
			var br := CityGeo.breaks(rs, rs + RIB_PITCH)
			for k in br.size() - 1:
				var mid := (br[k] + br[k + 1]) * 0.5
				if _in_any(holes, mid_x, mid) or _in_any(pads, mid_x, mid):
					continue
				var length := (br[k + 1] - br[k]) * 1.005
				strips.box(geo.frame(mid_x, mid, height - 1.25), Vector3.ZERO, Vector3(1.3, 0.3, length), _c("strip"))
				geo.box(geo.frame(mid_x, mid, height - 0.55), Vector3.ZERO, Vector3(0.5, 1.1, length), rib)
			# Ribs across, one piece per girder bay so an opening can interrupt them.
			for e in 2:
				if (e == 1 and j < ns - 1) or _in_any(holes, mid_x, rs + RIB_PITCH * float(e)):
					continue
				geo.box(geo.frame(mid_x, rs + RIB_PITCH * float(e), height - 0.3), Vector3.ZERO, Vector3(GIRDER_PITCH, 1.0, 1.2), rib)
	for i in nx + 1:
		var gx := x0 + float(i) * GIRDER_PITCH
		for j in ns:
			for half in 2:      # two pieces per bay so the girder follows the curve
				var mid := s0 + (float(j) + 0.25 + 0.5 * float(half)) * RIB_PITCH
				if _in_any(holes, gx, mid):
					continue
				geo.box(geo.frame(gx, mid, height - 0.7), Vector3.ZERO, Vector3(1.5, 2.2, RIB_PITCH * 0.505), rib)
				if i % 2 == 0 and not _in_any(pads, gx + 1.7, mid):      # service duct
					geo.box(geo.frame(gx + 1.7, mid, height - 1.5), Vector3.ZERO, Vector3(1.1, 0.8, RIB_PITCH * 0.505), _c("metal"))
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
static func walls(geo: CityGeo, plan: CityPlan) -> void:
	var e := plan.extent
	var h := plan.p("ceiling")
	var look := RandomNumberGenerator.new()
	look.seed = plan.cosmetic_seed() + 31
	for w: Dictionary in plan.boundary():
		var side: int = w["side"]
		var across := side >= 2
		var at: float = w["at"]
		var inward := -1.0 if side % 2 == 0 else 1.0
		var u0 := e.position.x if across else e.position.y
		var u1 := e.end.x if across else e.end.y
		var gates: Array = w["gates"]
		var spans := wall_spans(u0, u1, gates)
		if w["kind"] == "bulkhead":
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
		for g: Dictionary in gates:
			_gate(geo, across, at, inward, g, look)


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
