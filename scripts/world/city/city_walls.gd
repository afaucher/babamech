class_name CityWalls
extends RefCounted
## The map's boundary walls (CityPlan.boundary()) as flat-colour meshes: bulkheads, window walls, farm walls, the gates
## cut into them and the air-door holes MissionWorld asks for. Static builders, the same on every machine; their
## cosmetic generators are seeded per side and part. CityDistrict builds the walls' collision from the same plan data
## (wall_spans, WALL_THICK, GATE_RECESS). The mission's openings still arrive as plan meta ("mission_doors",
## "mission_air", set by CityStack.setup_mission).

const WALL_THICK := 6.0
const GATE_RECESS := 6.0     ## m from the wall plane to the back of a portal's recess (CityDistrict seals it there)
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
static func build(geo: CityGeo, plan: CityPlan, lights: CityGeo = null, only_side: int = -1, part: int = 0, parts: int = 1) -> void:
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
		var holes := _air_holes(plan, side)
		geo.tag("wall." + str(w["kind"]))
		if lights != null:
			lights.tag("farm_light")
		if w["kind"] == "farm":
			_farm_wall(geo, lights, across, at, inward, u0, u1, h, gates, farm_look, part, parts, holes)
			if part > 0:
				continue      # the gates are part 0's
		elif w["kind"] == "bulkhead":
			var pitch := CityStreets.GIRDER_PITCH if across else CityStreets.RIB_PITCH * 0.5
			var u := floorf(u0 / pitch) * pitch
			var i := 0
			while u < u1:
				var col := CityPalette.c("ceil_b") if i % 2 == 0 else CityPalette.c("ceil_a")
				for sp: Array in wall_spans(maxf(u, u0), minf(u + pitch, u1), gates):
					_wface_holed(geo, across, at, sp[0], sp[1], 0.0, h, inward, col, holes)
				if _in_gate(gates, maxf(u, u0)) < 0:
					for yy: Array in _air_cut(holes, maxf(u, u0) - 0.8, maxf(u, u0) + 0.8, 0.0, h):
						_wpost(geo, across, at, inward, maxf(u, u0), 0.7, (float(yy[0]) + float(yy[1])) * 0.5, Vector3(1.6, float(yy[1]) - float(yy[0]), 1.4), CityPalette.c("rib"))
				u += pitch
				i += 1
			for g: Dictionary in gates:
				_wface(geo, across, at, g["a"], g["b"], g["h"], h, inward, CityPalette.c("ceil_b"))
			_wbox(geo, across, at, inward, u0, u1, 0.9, 16.0, Vector2(1.8, 1.2), CityPalette.c("concrete_dark"))
			for sp: Array in spans:
				_wbox(geo, across, at, inward, sp[0], sp[1], 0.5, 1.0, Vector2(1.0, 2.0), CityPalette.c("concrete"))
		else:
			var cream := CityPalette.c("cream_light")
			for sp: Array in spans:
				_wface(geo, across, at, sp[0], sp[1], 0.0, HULL_SILL, inward, CityPalette.c("concrete"))
				if not w["backdrop"]:
					_wface(geo, across, at, sp[0], sp[1], HULL_SILL, h, inward, CityPalette.c("sky_blue"))
				_wface(geo, across, at + inward * 0.5, sp[0], sp[1], HULL_SILL - 0.6, HULL_SILL + 0.4, inward, cream)
				_wrect(geo, across, at, inward, 0.5, sp[0], sp[1], HULL_SILL + 0.4, cream, true)
				_wrect(geo, across, at, inward, 0.5, sp[0], sp[1], HULL_SILL - 0.6, cream, false)
				var t := HULL_SILL + (h - HULL_SILL) / 3.0
				while t < h - 1.0:
					_wface(geo, across, at + inward * 0.25, sp[0], sp[1], t - 0.3, t + 0.3, inward, cream)
					_wrect(geo, across, at, inward, 0.25, sp[0], sp[1], t + 0.3, cream, true)
					_wrect(geo, across, at, inward, 0.25, sp[0], sp[1], t - 0.3, cream, false)
					t += (h - HULL_SILL) / 3.0
				var u := ceilf(sp[0] / CityStreets.RIB_PITCH * 2.0) * CityStreets.RIB_PITCH * 0.5
				while u <= sp[1]:
					_wpost(geo, across, at, inward, u, 0.4, (HULL_SILL + h) * 0.5, Vector3(0.9, h - HULL_SILL, 0.8), cream)
					u += CityStreets.RIB_PITCH * 0.5
			for g: Dictionary in gates:
				_wface(geo, across, at, g["a"], g["b"], g["h"], h, inward, CityPalette.c("concrete"))
		# A mission's wave door (MissionWorld) stands in this gate as its own node: no baked leaf there (plan meta
		# "mission_doors": {"<side>:<a>": true}, set only by CityStack.setup_mission; absent = unchanged).
		var doors: Dictionary = plan.get_meta("mission_doors", {})
		geo.tag("wall.gate")
		for g: Dictionary in gates:
			if not doors.is_empty() and doors.has("%d:%.2f" % [side, float(g["a"])]):
				g["leaf"] = false
				g["frame"] = false      # its bunker frame (MissionGateDoor) replaces the hazard portal
			_gate(geo, across, at, inward, g, look)


# --- Air doors (MissionWorld) ------------------------------------------------------------------------------
# An air door is an opening high on an end wall (MissionWorld, docs/design/city-ramps-and-stack.md "Air doors"). Plan meta
# "mission_air" = {side: [{a, b, y0, y1, fa, fb, fy0, fy1}]}, set only by CityStack.setup_mission: the opening a..b along
# the wall, y0..y1 up (left out of the wall's face and a farm's backing), and its frame's rect fa..fb, fy0..fy1 (posts,
# fins, racks and light bars stop round it). Absent: nothing changes.

static func _air_holes(plan: CityPlan, side: int) -> Array:
	var m: Dictionary = plan.get_meta("mission_air", {})
	return m.get(side, [])


## A wall face u0..u1, h0..h1 less the air openings in it (pieces left, right, below and above each).
static func _wface_holed(geo: CityGeo, across: bool, at: float, u0: float, u1: float, h0: float, h1: float, inward: float, col: Color,
		holes: Array) -> void:
	var pieces := [[u0, u1, h0, h1]]
	for ho: Dictionary in holes:
		var next := []
		for p: Array in pieces:
			var ha := float(ho["a"])
			var hb := float(ho["b"])
			if hb <= p[0] or ha >= p[1] or float(ho["y1"]) <= p[2] or float(ho["y0"]) >= p[3]:
				next.append(p)
				continue
			if ha > p[0]:
				next.append([p[0], ha, p[2], p[3]])
			if hb < p[1]:
				next.append([hb, p[1], p[2], p[3]])
			var m0 := maxf(p[0], ha)
			var m1 := minf(p[1], hb)
			if float(ho["y0"]) > p[2]:
				next.append([m0, m1, p[2], float(ho["y0"])])
			if float(ho["y1"]) < p[3]:
				next.append([m0, m1, float(ho["y1"]), p[3]])
		pieces = next
	for p: Array in pieces:
		_wface(geo, across, at, p[0], p[1], p[2], p[3], inward, col)


## What is left of a vertical span y0..y1 of something standing across ua..ub after the air doors' frame rects: [[ya, yb]].
static func _air_cut(holes: Array, ua: float, ub: float, y0: float, y1: float) -> Array:
	var out := [[y0, y1]]
	for ho: Dictionary in holes:
		if ub <= float(ho["fa"]) or ua >= float(ho["fb"]):
			continue
		var next := []
		for r: Array in out:
			if r[1] <= float(ho["fy0"]) or r[0] >= float(ho["fy1"]):
				next.append(r)
				continue
			if r[0] < float(ho["fy0"]):
				next.append([r[0], float(ho["fy0"])])
			if r[1] > float(ho["fy1"]):
				next.append([float(ho["fy1"]), r[1]])
		out = next
	return out


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
		gates: Array, look: RandomNumberGenerator, part: int = 0, parts: int = 1, holes: Array = []) -> void:
	var r := FARM_RECESS
	var ux := inward if across else -inward       # local +X of _wframe is +u (1) or -u (-1)
	var pitch := FARM_PITCH_X if across else FARM_PITCH_S
	var fin := CityPalette.c("farm_fin")
	var back := CityPalette.c("farm_backing")
	var spans := wall_spans(u0, u1, gates) if part == 0 else []
	# This part's share of the bays, fins and racks (by where each one starts / stands): [wa, wb), the last part to u1.
	var wa := -INF if part == 0 else u0 + (u1 - u0) * float(part) / float(parts)
	var wb := INF if part == parts - 1 else u0 + (u1 - u0) * float(part + 1) / float(parts)
	# Backing: floor to ceiling, above a gate from its lintel up; a ledge on the lintel; cheeks closing the recess at the
	# wall's ends and beside each gate (part 0).
	for sp: Array in spans:
		_wface_holed(geo, across, at - inward * r, sp[0], sp[1], 0.0, h, inward, back, holes)
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
						CityPalette.c("farm_pipe"), CityGeo.PZ | CityGeo.PY)
		if lights != null:
			# Each bar: one straight box in a constant plane just proud of the fin faces, one piece per deck facet on a
			# wall along the arc (so it follows the facets like everything else), front and underside only.
			for f: float in FARM_BARS:
				var y := h * f
				var z0 := _fin_front(y, h) + FARM_BAR_GAP
				for sp: Array in _bar_spans(pa, pb, gates, y, holes):
					var br := PackedFloat32Array([sp[0], sp[1]]) if across else CityGeo.breaks(sp[0], sp[1])
					for j in br.size() - 1:
						_farm_band(lights, across, at, inward, ux, br[j], br[j + 1], y - FARM_BAR_H * 0.5, y + FARM_BAR_H * 0.5,
								z0, z0 + FARM_BAR_D, CityPalette.c("strip"), CityGeo.PZ | CityGeo.NY)
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
		var fin_cut := _air_cut(holes, u - FARM_FIN_W * 0.5, u + FARM_FIN_W * 0.5, y0, h)
		if fin_cut.size() == 1 and is_equal_approx(float(fin_cut[0][1]), h):
			_farm_fin(geo, ff, float(fin_cut[0][0]), h, fin)
		else:
			for yy: Array in fin_cut:       # an air door's frame splits the fin: a stub under it, the rest from over it
				if is_equal_approx(float(yy[1]), h):
					_farm_fin(geo, ff, float(yy[0]), h, fin)
				else:
					_farm_fin_stub(geo, ff, float(yy[0]), float(yy[1]), h, fin)
		# A short dark bracket from the fin face to each light bar that runs past it.
		if lights != null:
			for f: float in FARM_BARS:
				var y := h * f
				if y > y0 + 0.5 and not _bar_spans(u - 0.05, u + 0.05, gates, y, holes).is_empty():
					var d0 := _fin_front(y, h)
					geo.box(ff, Vector3(0, y, d0 + FARM_BAR_GAP * 0.5), Vector3(0.3, 0.22, FARM_BAR_GAP + 0.06), CityPalette.c("metal_dark"),
							CityGeo.PX | CityGeo.NX | CityGeo.NY)
	# Racks: one per bay, in the middle, wherever it fits clear of the ends.
	k = floorf(u0 / pitch)
	while k * pitch < u1:
		var uc := (k + 0.5) * pitch
		k += 1.0
		if uc - FARM_COL_HALF < u0 + FARM_FIN_W or uc + FARM_COL_HALF > u1 - FARM_FIN_W or uc < wa or uc >= wb:
			continue
		var yb := _farm_floor(gates, uc - FARM_COL_HALF, uc + FARM_COL_HALF)
		var rb := yb if yb > 0.0 else FARM_PLINTH
		for yy: Array in _air_cut(holes, uc - FARM_COL_HALF, uc + FARM_COL_HALF, rb, h - 2.2):
			var ya := float(yy[0])
			var ye := float(yy[1]) - (0.0 if is_equal_approx(float(yy[1]), h - 2.2) else 0.5)
			if ye - ya > 3.0:       # an air door's frame splits the rack: one under it, one over it
				_farm_rack(geo, _wframe(geo, across, at, inward, uc), ya, ye, yb == 0.0 and is_equal_approx(ya, rb), look)


## The top of the gate whose edge is at u (its lintel), 0 if no gate edge is there.
static func _gate_top(gates: Array, u: float) -> float:
	for g: Dictionary in gates:
		if is_equal_approx(float(g["a"]), u) or is_equal_approx(float(g["b"]), u):
			return float(g["h"]) + 1.6
	return 0.0


## [pa, pb] where a light bar at height y runs: everywhere but across a gate's opening and frame below its lintel.
static func _bar_spans(pa: float, pb: float, gates: Array, y: float, holes: Array = []) -> Array:
	var cut := []
	for g: Dictionary in gates:
		if y < float(g["h"]) + 1.6:
			cut.append({"a": float(g["a"]) - 1.2, "b": float(g["b"]) + 1.2})
	for ho: Dictionary in holes:      # an air door's frame (MissionWorld)
		if y + FARM_BAR_H > float(ho["fy0"]) and y - FARM_BAR_H < float(ho["fy1"]):
			cut.append({"a": float(ho["fa"]), "b": float(ho["fb"])})
	return wall_spans(pa, pb, cut)


## The lower piece of a fin an air door's frame cuts (frame f, y0 .. y1, all under the haunch): face, sides, a flat top.
static func _farm_fin_stub(geo: CityGeo, f: Transform3D, y0: float, y1: float, h: float, col: Color) -> void:
	if y1 - y0 < 0.05:
		return
	var hw := FARM_FIN_W * 0.5
	var r := FARM_RECESS
	var da := _fin_front(y0, h)
	var db := _fin_front(y1, h)
	geo.quad(f * Vector3(-hw, y0, da), f * Vector3(hw, y0, da), f * Vector3(hw, y1, db), f * Vector3(-hw, y1, db), col)
	geo.quad(f * Vector3(hw, y0, da), f * Vector3(hw, y0, -r), f * Vector3(hw, y1, -r), f * Vector3(hw, y1, db), col)
	geo.quad(f * Vector3(-hw, y0, -r), f * Vector3(-hw, y0, da), f * Vector3(-hw, y1, db), f * Vector3(-hw, y1, -r), col)
	geo.quad(f * Vector3(-hw, y1, db), f * Vector3(hw, y1, db), f * Vector3(hw, y1, -r), f * Vector3(-hw, y1, -r), col)


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
		var e := CityStreets.DECAL_PATCH      # just proud of the face (the decal rule: 2 cm; was 1.5 cm)
		var k1 := y0 + 1.4
		geo.quad(f * Vector3(-FARM_FIN_W * 0.5, y0, _fin_front(y0, h) + e), f * Vector3(FARM_FIN_W * 0.5, y0, _fin_front(y0, h) + e),
				f * Vector3(FARM_FIN_W * 0.5, k1, _fin_front(k1, h) + e), f * Vector3(-FARM_FIN_W * 0.5, k1, _fin_front(k1, h) + e), CityPalette.c("concrete_dark"))
		var c0 := k1 + 0.8
		var c1 := y1 - 0.8
		geo.quad(f * Vector3(-0.17, c0, _fin_front(c0, h) + e), f * Vector3(0.17, c0, _fin_front(c0, h) + e),
				f * Vector3(0.17, c1, _fin_front(c1, h) + e), f * Vector3(-0.17, c1, _fin_front(c1, h) + e), CityPalette.c("farm_backing"))
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
	var rack := CityPalette.c("farm_rack")
	var side_faces := CityGeo.PX | CityGeo.NX | CityGeo.PZ
	var wide := FARM_COL_HALF * 2.0 - 0.6
	geo.box(f, Vector3(0, yb + 0.6, (-r + 0.35) * 0.5), Vector3(wide, 1.2, r + 0.35), CityPalette.c("farm_planter"), side_faces | CityGeo.PY)
	if riser:
		geo.box(f, Vector3(1.6, (1.55 + yb + 0.4) * 0.5, 0.5), Vector3(0.34, yb + 0.4 - 1.55, 0.34), CityPalette.c("farm_pipe"), side_faces)
	# The green core: from far the rack reads as one solid column of leaves, the tufts give it facets up close.
	geo.box(f, Vector3(0, (yb + 1.2 + yt) * 0.5, -r + 0.45), Vector3(wide - 1.2, yt - yb - 1.2, 0.9), CityPalette.c("farm_leaf_dark"), side_faces)
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
	var col := CityPalette.c(FARM_LEAVES[look.randi_range(0, FARM_LEAVES.size() - 1)])
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
## the sealed door leaves (blast_door, and collapsed: since the 2026-11-23 playtest a collapsed gate is built as a plain
## shut blast door, no rubble; its kind in the plan is unchanged), or a dark recess, the way in or out (portal).
static func _gate(geo: CityGeo, across: bool, at: float, inward: float, g: Dictionary, _look: RandomNumberGenerator) -> void:
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
	if kind == "blast_door" or kind == "collapsed":
		if g.get("leaf", true):      # false: a MissionWorld door node stands here instead
			geo.box(f, Vector3(0, gh * 0.5, 0.5), Vector3(half * 2.0, gh, 1.0), CityPalette.c("metal_dark"), CityGeo.NO_BACK)
			geo.box(f, Vector3(0, gh * 0.5, 1.05), Vector3(0.5, gh, 0.12), CityPalette.c("metal"), CityGeo.NO_BACK)
			for k: float in [-1.0, 1.0]:
				geo.box(f, Vector3(k * half * 0.5, gh * 0.55, 1.03), Vector3(half * 0.6, 1.0, 0.1), CityPalette.c("marking_yellow"), CityGeo.NO_BACK)
		# A hatched keep-clear box on the road in front of the gate.
		var n := int(half * 2.0 / 2.0)
		for k in n:
			var gx := ga + 0.6 + (float(k) + 0.25) * (half * 2.0 / float(n))
			_wrect(geo, across, at + inward * 1.5, inward, 5.0, gx, gx + 0.5, CityStreets.MARK, CityPalette.c("marking_yellow"), true)
	else:
		_recess(geo, f, half + 0.6, gh, GATE_RECESS, CityPalette.c("glass_dark"))
	if not g.get("frame", true):    # a MissionWorld door draws its own frame
		return
	for k: float in [-1.0, 1.0]:
		geo.box(f, Vector3(k * (half + 0.9), (gh + 1.6) * 0.5, 0.9), Vector3(1.8, gh + 1.6, 1.8), CityPalette.c("tactile"), CityGeo.NO_BACK)
	geo.box(f, Vector3(0, gh + 0.8, 0.9), Vector3(half * 2.0 + 3.6, 1.6, 1.8), CityPalette.c("tactile"), CityGeo.NO_BACK)


## The inside of a box behind a gate opening (local -Z is out of the map), faces turned inward: back, sides, top, floor.
static func _recess(geo: CityGeo, f: Transform3D, w: float, gh: float, depth: float, col: Color) -> void:
	var d := -depth
	var fl := 0.02
	geo.quad(f * Vector3(-w, 0, d), f * Vector3(w, 0, d), f * Vector3(w, gh, d), f * Vector3(-w, gh, d), col)
	geo.quad(f * Vector3(-w, 0, 0), f * Vector3(-w, 0, d), f * Vector3(-w, gh, d), f * Vector3(-w, gh, 0), col)
	geo.quad(f * Vector3(w, 0, d), f * Vector3(w, 0, 0), f * Vector3(w, gh, 0), f * Vector3(w, gh, d), col)
	geo.quad(f * Vector3(-w, gh, 0), f * Vector3(-w, gh, d), f * Vector3(w, gh, d), f * Vector3(w, gh, 0), col)
	geo.quad(f * Vector3(-w, fl, 0), f * Vector3(w, fl, 0), f * Vector3(w, fl, d), f * Vector3(-w, fl, d), col)
