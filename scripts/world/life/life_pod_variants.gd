class_name LifePodVariants
extends RefCounted
## Nine candidate meshes for the driverless city pod (docs/design/ambient-life.md; the concept is
## docs/design/ambient-life/pod_bubble_civic_s909.png), shown side by side in the lab subject `pod_gallery` so the user can
## pick one (3x3: rows = body form, columns = stance and wheels). ADOPTED (user pick, 2026-11-22): candidate 7,
## `capsule_a`. adopted(geo, lights) is the game's pod (LifeCars.pod calls it): the same builders, trimmed to <= 500
## triangles (one lighter facet on each end glass only, no dark lower split on the door glass, a straight side stripe,
## pyramid hub caps), pale light bars without a housing, and the hazard variants (amber bars in the light-bar slots at
## both ends, a short amber band on the roof). The gallery still draws the nine candidates as they were.
##   forms:   cab     - rounded upright box, raked glass nose, flat cream roof, one big door window a side (the concept)
##            bubble  - cream tub up to a belt line, a glass band above it split by four cream corner pillars, a roof cap
##            capsule - symmetrical (drives either way): raked glass at both ends, a centre door with a pale frame a side
##   stances: a - wheels tucked inboard under skirts, body 0.28 m off the road, lower wheel halves showing
##            b - four chunky wheels (0.6 m x 0.25 m, dark tyre, cream hub) in round dark arches cut into the body
##            c - wheels pushed out to the corners under separate pontoon fenders, wider track, body 0.3 m up
## Shared: 3.4 m long, about 1.8 m wide, 1.95 m tall; civic livery (cream body, one terracotta stripe, dark-teal glass as
## separate panels with one lighter facet, cream frames >= 0.12 m round every panel, a darker lower half on the side glass
## for the cabin inside), a pale light bar at both ends, dark underside. Flat colour per face (CityGeo triangle soup on
## CityPalette.surface_material(); no lighting, no emission). Origin on the road at the centre, nose +Z (as LifeCars).
## Every piece is a closed, outward-wound shell (body, panels, wheels, fenders), so a tipped wreck shows no holes.
## Static, no state, no randomness.

const FORMS := ["cab", "bubble", "capsule"]
const STANCES := ["a", "b", "c"]
const WHEEL_R := 0.30                  ## circumradius of the octagonal wheel (0.6 m across)
const WHEEL_W := 0.25
const WHEEL_SIDES := 8
const SIMPLE_SIDES := 6                ## the game pod's wheels (adopted)
const CW := 0.10                       ## width (along x) of the rounded chamfer between the body's sides and its top / ends
const GLASS_T := 0.022                 ## how far a glass panel's face stands off the body
const STRIPE_HALF := 0.055


static func ids() -> Array[String]:
	var out: Array[String] = []
	for f: String in FORMS:
		for s: String in STANCES:
			out.append("%s_%s" % [f, s])
	return out


static func build(id: String) -> ArrayMesh:
	var geo := CityGeo.new()
	draw(geo, id)
	return geo.commit(CityPalette.surface_material())


static func tri_count(id: String) -> int:
	var geo := CityGeo.new()
	draw(geo, id)
	return geo.tri_count()


## Draw pod `id` ("<form>_<stance>") into `geo`.
static func draw(geo: CityGeo, id: String) -> void:
	var parts := id.split("_")
	if parts.size() != 2 or not FORMS.has(parts[0]) or not STANCES.has(parts[1]):
		push_error("[LifePodVariants] unknown pod " + id)
		return
	var st := _stance(parts[1])
	match parts[0]:
		"cab":
			_cab(geo, st)
		"bubble":
			_bubble(geo, st)
		"capsule":
			_capsule(geo, st)
	_wheels(geo, st)
	if st["fender"]:
		_fenders(geo, st)


static func _c(id: String) -> Color:
	return CityPalette.C[id]


## The game's pod: capsule_a trimmed for the game (see the header). `lights`: 0 plain, 1 hazards dark, 2 hazards bright
## (LifeCars.PLAIN / HAZARD_DARK / HAZARD_BRIGHT). Origin on the road at the centre, either end +Z (it is symmetric).
static func adopted(geo: CityGeo, lights: int) -> void:
	var st := _stance("a")
	_capsule(geo, st, true, lights)
	_wheels(geo, st, true)


## yb: underside height; wz / wx: axle z and wheel-centre x; hw: body half width; arch: wheel arches cut into the body.
static func _stance(s: String) -> Dictionary:
	match s:
		"a":
			return {"id": s, "yb": 0.28, "wz": 1.08, "wx": 0.70, "hw": 0.90, "arch": false, "fender": false}
		"b":
			return {"id": s, "yb": 0.30, "wz": 1.10, "wx": 0.79, "hw": 0.90, "arch": true, "fender": false}
	return {"id": s, "yb": 0.30, "wz": 1.22, "wx": 0.95, "hw": 0.84, "arch": false, "fender": true}


# --- Forms -----------------------------------------------------------------------------------------------

## Profile helper: [point (z, y), colour of the edge from this point to the next], counter-clockwise with z right, y up
## (nose first, over the roof to the tail, back along the underside).
static func _p(z: float, y: float, col: String) -> Array:
	return [Vector2(z, y), _c(col)]


## The underside from the tail corner to the nose corner (both excluded), with an arch over each wheel when cut.
static func _underside(st: Dictionary) -> Array:
	var out: Array = []
	if not st["arch"]:
		return out
	var r := 0.40
	var yc := WHEEL_R * cos(PI / WHEEL_SIDES)
	for zc: float in [-float(st["wz"]), float(st["wz"])]:
		for k in 5:
			var a := PI * (1.0 - float(k) / 4.0)
			out.append(_p(zc + r * cos(a), maxf(yc + r * sin(a), float(st["yb"])), "metal_dark"))
	return out


static func _cab(geo: CityGeo, st: Dictionary) -> void:
	var yb: float = st["yb"]
	var prof: Array = [
		_p(1.58, yb, "cream"), _p(1.70, yb + 0.14, "cream"), _p(1.73, 0.60, "terracotta"),
		_p(1.73, 0.72, "cream"), _p(1.70, 0.95, "cream"), _p(1.55, 1.02, "cream"),   # bonnet lip
		_p(0.95, 1.83, "cream"), _p(0.72, 1.94, "cream"), _p(-0.95, 1.95, "cream"),  # screen, roof
		_p(-1.36, 1.89, "cream"), _p(-1.66, 1.10, "cream"), _p(-1.72, 0.72, "terracotta"),  # rear window
		_p(-1.72, 0.60, "cream"), _p(-1.69, yb + 0.14, "cream"), _p(-1.56, yb, "metal_dark"),
	]
	prof.append_array(_underside(st))
	var hw: float = st["hw"]
	_body(geo, prof, hw, 0.16, 0.05, 0.20)
	# glass: windscreen, rear window, one big door window a side (pale frame like the concept)
	_seg_glass(geo, Vector2(1.55, 1.02), Vector2(0.95, 1.83), hw - 0.16, 0.12, 0.14, 0.12)
	_seg_glass(geo, Vector2(-1.36, 1.89), Vector2(-1.66, 1.10), hw - 0.16, 0.12, 0.14, 0.18)
	var door := PackedVector2Array([Vector2(-0.80, 0.98), Vector2(0.80, 0.98), Vector2(1.04, 1.30),
			Vector2(0.72, 1.58), Vector2(-0.80, 1.58)])
	for s: float in [-1.0, 1.0]:
		_side_frame(geo, s, hw, door, 0.05)
		_side_glass(geo, s, hw, door, 1.24, true)
	_stripes(geo, st, hw, -1.62, 1.62)
	_light_bars(geo, 0.84, 1.715, -1.72)


static func _bubble(geo: CityGeo, st: Dictionary) -> void:
	var yb: float = st["yb"]
	var hw: float = st["hw"]
	var tub: Array = [
		_p(1.58, yb, "cream"), _p(1.70, yb + 0.14, "cream"), _p(1.74, 0.60, "terracotta"),
		_p(1.74, 0.72, "cream"), _p(1.70, 0.88, "cream"), _p(1.54, 0.98, "cream"),
		_p(-1.54, 0.98, "cream"), _p(-1.70, 0.88, "cream"), _p(-1.74, 0.72, "terracotta"),
		_p(-1.74, 0.60, "cream"), _p(-1.70, yb + 0.14, "cream"), _p(-1.58, yb, "metal_dark"),
	]
	tub.append_array(_underside(st))
	_body(geo, tub, hw, 0.08, 0.05, 0.05)
	# cabin on the tub, set in from its sides (the belt ledge): a steep glass band all round, split by four wide
	# corner chamfers (the cream pillars), under a sloped cream roof cap
	var gw := hw - 0.10
	var house: Array = [
		_p(1.46, 0.92, "cream"), _p(1.14, 1.60, "cream"), _p(0.66, 1.95, "cream"), _p(-0.66, 1.95, "cream"),
		_p(-1.14, 1.60, "cream"), _p(-1.46, 0.92, "cream"),
	]
	_body(geo, house, gw, 0.16, 0.0, 0.14)
	var ga := Vector2(1.46, 0.92)
	var gb := Vector2(1.14, 1.60)
	var glen := ga.distance_to(gb)
	var m_lo := glen * (1.06 - 0.92) / 0.68
	var m_hi := glen * (1.60 - 1.47) / 0.68
	_seg_glass(geo, ga, gb, gw - 0.16, 0.03, m_lo, m_hi)
	_seg_glass(geo, Vector2(-1.14, 1.60), Vector2(-1.46, 0.92), gw - 0.16, 0.03, m_hi, m_lo)
	var band := PackedVector2Array([Vector2(-1.22, 1.06), Vector2(1.22, 1.06), Vector2(1.01, 1.46),
			Vector2(-1.01, 1.46)])
	for s: float in [-1.0, 1.0]:
		_side_glass(geo, s, gw, band, 1.20, true)
	_stripes(geo, st, hw, -1.64, 1.64)
	_light_bars(geo, 0.80, 1.72, -1.72)


static func _capsule(geo: CityGeo, st: Dictionary, game: bool = false, lights: int = 0) -> void:
	var yb: float = st["yb"]
	var hw: float = st["hw"]
	var prof: Array = [
		_p(1.62, yb, "cream"), _p(1.72, yb + 0.14, "cream"), _p(1.75, 0.60, "terracotta"),
		_p(1.75, 0.72, "cream"), _p(1.70, 0.88, "cream"), _p(1.58, 0.98, "cream"),
		_p(0.78, 1.86, "cream"), _p(0.50, 1.95, "cream"), _p(-0.50, 1.95, "cream"),
		_p(-0.78, 1.86, "cream"), _p(-1.58, 0.98, "cream"), _p(-1.70, 0.88, "cream"),
		_p(-1.75, 0.72, "terracotta"), _p(-1.75, 0.60, "cream"), _p(-1.72, yb + 0.14, "cream"),
		_p(-1.62, yb, "metal_dark"),
	]
	prof.append_array(_underside(st))
	_body(geo, prof, hw, 0.16, 0.05, 0.20)
	# long raked glass at both ends: it drives either way
	_seg_glass(geo, Vector2(1.58, 0.98), Vector2(0.78, 1.86), hw - 0.16, 0.12, 0.14, 0.14)
	_seg_glass(geo, Vector2(-0.78, 1.86), Vector2(-1.58, 0.98), hw - 0.16, 0.12, 0.14, 0.14)
	var door := PackedVector2Array([Vector2(-0.50, 0.46), Vector2(0.50, 0.46), Vector2(0.50, 1.52),
			Vector2(0.40, 1.63), Vector2(-0.40, 1.63), Vector2(-0.50, 1.52)])
	var panel := PackedVector2Array([Vector2(-0.42, 0.54), Vector2(0.42, 0.54), Vector2(0.42, 1.48),
			Vector2(0.34, 1.55), Vector2(-0.34, 1.55), Vector2(-0.42, 1.48)])
	var glass := PackedVector2Array([Vector2(-0.33, 0.96), Vector2(0.33, 0.96), Vector2(0.33, 1.42),
			Vector2(0.26, 1.48), Vector2(-0.26, 1.48), Vector2(-0.33, 1.42)])
	var quarter := PackedVector2Array([Vector2(0.64, 1.04), Vector2(1.10, 1.04), Vector2(0.70, 1.52),
			Vector2(0.64, 1.52)])
	var quarter_r := PackedVector2Array()
	for k in range(quarter.size() - 1, -1, -1):
		quarter_r.append(Vector2(-quarter[k].x, quarter[k].y))
	for s: float in [-1.0, 1.0]:
		var o := Vector3(s * hw, 0.0, 0.0)
		var n := Vector3(s, 0.0, 0.0)
		_plate(geo, o, Vector3.BACK, Vector3.UP, n, door, -0.01, 0.016, [[door, _c("marking")]])
		_plate(geo, o, Vector3.BACK, Vector3.UP, n, panel, 0.0, 0.024, [[panel, _c("cream")]])
		_side_glass(geo, s, hw, glass, -1.0 if game else 1.20, not game, 0.012)
		_side_glass(geo, s, hw, quarter, -1.0, false)
		_side_glass(geo, s, hw, quarter_r, -1.0, false)
	_stripes(geo, st, hw, -1.62, 1.62, game)
	if game:
		_game_lights(geo, lights)
	else:
		_light_bars(geo, 0.80, 1.72, -1.72)


## The game pod's lights: a pale bar in each end's slot (no housing), or amber bars there and a short amber band on the
## roof for hazards (dark or bright).
static func _game_lights(geo: CityGeo, lights: int) -> void:
	var xf := Transform3D.IDENTITY
	if lights == 0:
		for z: float in [1.735, -1.735]:
			geo.box(xf, Vector3(0.0, 0.80, z), Vector3(0.98, 0.09, 0.05), _c("marking"))
		return
	var amber := _c("marking_yellow") if lights == 2 else _c("terracotta_dark")
	for z: float in [1.735, -1.735]:
		geo.box(xf, Vector3(0.0, 0.80, z), Vector3(1.12, 0.16, 0.06), amber)
	geo.box(xf, Vector3(0.0, 1.95, 0.0), Vector3(1.1, 0.08, 1.0), amber)


# --- Shared pieces ---------------------------------------------------------------------------------------

## A triangle wound so its face points along `hint` (CityGeo.tri wants counter-clockwise seen from the front).
static func _t(geo: CityGeo, a: Vector3, b: Vector3, c: Vector3, col: Color, hint: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	if n.dot(hint) < 0.0:
		geo.tri(a, c, b, col)
	else:
		geo.tri(a, b, c, col)


static func _q(geo: CityGeo, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, hint: Vector3) -> void:
	_t(geo, a, b, c, col, hint)
	_t(geo, a, c, d, col, hint)


## Outward normal (in the z-y plane, as Vector2(z, y)) of a counter-clockwise polygon's edge a -> b.
static func _out2(a: Vector2, b: Vector2) -> Vector2:
	var d := (b - a).normalized()
	return Vector2(d.y, -d.x)


static func _signed_area(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


## A body piece extruded across x from a side profile (z, y): four slices (side face, rounded chamfer, chamfer, side
## face). The flat side faces are the profile shrunk by a per-vertex inset that grows with height (ins_lo below the belt,
## ins_hi at the roof), so the roof edge is rounder than the skirt. Edge colours run right across the car (stripes at the
## nose and tail, dark underside); the side faces are cream.
static func _body(geo: CityGeo, prof: Array, hw: float, cw: float, ins_lo: float, ins_hi: float, y_lo: float = 1.1,
		y_hi: float = 1.8) -> void:
	var pts := PackedVector2Array()
	var cols: Array[Color] = []
	for e: Array in prof:
		pts.append(e[0])
		cols.append(e[1])
	var n := pts.size()
	if _signed_area(pts) <= 0.0:
		push_error("[LifePodVariants] profile is not counter-clockwise")
	var inset := PackedVector2Array()
	for i in n:
		var a := pts[(i - 1 + n) % n]
		var b := pts[i]
		var c := pts[(i + 1) % n]
		var n1 := _out2(a, b)
		var n2 := _out2(b, c)
		var bis := (n1 + n2)
		var amount := lerpf(ins_lo, ins_hi, clampf((b.y - y_lo) / (y_hi - y_lo), 0.0, 1.0))
		if bis.length() < 1e-4 or amount <= 0.0:
			inset.append(b)
			continue
		bis = bis.normalized()
		inset.append(b - bis * amount / maxf(bis.dot(n1), 0.35))
	var slices := [[-hw, inset], [-(hw - cw), pts], [hw - cw, pts], [hw, inset]]
	for s in 3:
		var x0: float = slices[s][0]
		var x1: float = slices[s + 1][0]
		var p0: PackedVector2Array = slices[s][1]
		var p1: PackedVector2Array = slices[s + 1][1]
		for i in n:
			var j := (i + 1) % n
			var o := _out2(pts[i], pts[j])
			var hint := Vector3(0.0, o.y, o.x)
			_q(geo, Vector3(x0, p0[i].y, p0[i].x), Vector3(x0, p0[j].y, p0[j].x), Vector3(x1, p1[j].y, p1[j].x),
					Vector3(x1, p1[i].y, p1[i].x), cols[i], hint)
	var tris := Geometry2D.triangulate_polygon(inset)
	var cream := _c("cream")
	for sx: float in [-hw, hw]:
		for k in range(0, tris.size(), 3):
			var a := inset[tris[k]]
			var b := inset[tris[k + 1]]
			var c := inset[tris[k + 2]]
			_t(geo, Vector3(sx, a.y, a.x), Vector3(sx, b.y, b.x), Vector3(sx, c.y, c.x), cream, Vector3(signf(sx), 0, 0))


## A closed plate on the plane (origin o, axes u / v, outward normal nrm): `outline` (2D, any convex or concave simple
## polygon) between offsets t0 (back, may sink into the body) and t1 (face). `pieces`: [[polygon, colour], ...] that tile
## the face; their corners must lie on the outline's corners (split points included in `outline`).
static func _plate(geo: CityGeo, o: Vector3, u: Vector3, v: Vector3, nrm: Vector3, outline: PackedVector2Array,
		t0: float, t1: float, pieces: Array) -> void:
	var to3 := func(p: Vector2, t: float) -> Vector3: return o + u * p.x + v * p.y + nrm * t
	for pc: Array in pieces:
		var poly: PackedVector2Array = pc[0]
		var tris := Geometry2D.triangulate_polygon(poly)
		for k in range(0, tris.size(), 3):
			_t(geo, to3.call(poly[tris[k]], t1), to3.call(poly[tris[k + 1]], t1), to3.call(poly[tris[k + 2]], t1),
					pc[1], nrm)
	var back_col: Color = pieces[0][1]
	var tb := Geometry2D.triangulate_polygon(outline)
	for k in range(0, tb.size(), 3):
		_t(geo, to3.call(outline[tb[k]], t0), to3.call(outline[tb[k + 1]], t0), to3.call(outline[tb[k + 2]], t0),
				back_col, -nrm)
	var ccw := _signed_area(outline) > 0.0
	var m := outline.size()
	for i in m:
		var a := outline[i]
		var b := outline[(i + 1) % m]
		var d := (b - a).normalized()
		var out := Vector2(d.y, -d.x) if ccw else Vector2(-d.y, d.x)
		var hint: Vector3 = u * out.x + v * out.y
		var rim_col: Color = back_col
		for pc: Array in pieces:          # the rim takes the colour of the face piece above it
			var poly: PackedVector2Array = pc[0]
			if Geometry2D.is_point_in_polygon((a + b) * 0.5 - out * 0.002, poly):
				rim_col = pc[1]
		_q(geo, to3.call(a, t0), to3.call(b, t0), to3.call(b, t1), to3.call(a, t1), rim_col, hint)


## Points where a horizontal line y = h crosses the polygon's edges, inserted in order (so a split along it leaves no
## T-junction on the rim). Crossing points are computed from the lower end of each edge, the same way as in _clip.
static func _with_cut(poly: PackedVector2Array, h: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		out.append(a)
		if (a.y - h) * (b.y - h) < 0.0:
			out.append(_cross_at(a, b, h))
	return out


static func _cross_at(a: Vector2, b: Vector2, h: float) -> Vector2:
	var lo := a if a.y < b.y else b
	var hi := b if a.y < b.y else a
	return lo + (hi - lo) * ((h - lo.y) / (hi.y - lo.y))


## The part of convex polygon `poly` below (below = true) or above the line y = h.
static func _clip(poly: PackedVector2Array, h: float, below: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var ain := a.y <= h + 1e-6 if below else a.y >= h - 1e-6
		var bin := b.y <= h + 1e-6 if below else b.y >= h - 1e-6
		if ain:
			out.append(a)
		if ain != bin and absf(a.y - h) > 1e-6 and absf(b.y - h) > 1e-6:
			out.append(_cross_at(a, b, h))
	return out


## The lighter facet on a glass panel: a slanted band across its upper part, clipped to the panel shrunk by `margin`.
static func _glint_poly(poly: PackedVector2Array, margin: float, flip: bool) -> PackedVector2Array:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var w := hi.x - lo.x
	var h := hi.y - lo.y
	var x0 := lo.x + w * 0.52
	var band := PackedVector2Array([Vector2(x0, hi.y + 1.0), Vector2(x0 + w * 0.16, hi.y + 1.0),
			Vector2(x0 + w * 0.16 - h * 0.9, lo.y - 1.0), Vector2(x0 - h * 0.9, lo.y - 1.0)])
	if flip:
		for k in band.size():
			band[k].x = lo.x + hi.x - band[k].x
	var shrunk := Geometry2D.offset_polygon(poly, -margin, Geometry2D.JOIN_MITER)
	if shrunk.is_empty():
		return PackedVector2Array()
	var parts := Geometry2D.intersect_polygons(shrunk[0], band)
	return parts[0] if not parts.is_empty() else PackedVector2Array()


## A glass panel on the plane: dark-teal face (dark lower part below y = split when split > 0, for the cabin inside),
## one lighter facet standing a little off it when `glint`.
static func _glass(geo: CityGeo, o: Vector3, u: Vector3, v: Vector3, nrm: Vector3, poly: PackedVector2Array,
		split: float, glint: bool, flip_glint: bool, t0: float = -0.01, t1: float = GLASS_T) -> void:
	var teal := _c("glass_teal")
	if split > 0.0:
		var outline := _with_cut(poly, split)
		_plate(geo, o, u, v, nrm, outline, t0, t1, [[_clip(outline, split, true), _c("glass_dark")],
				[_clip(outline, split, false), teal]])
	else:
		_plate(geo, o, u, v, nrm, poly, t0, t1, [[poly, teal]])
	if glint:
		var g := _glint_poly(poly, 0.05, flip_glint)
		if g.size() >= 3:
			_plate(geo, o, u, v, nrm, g, t1 - 0.004, t1 + 0.006, [[g, _c("glass_blue")]])


## Glass on the flat side face x = side * hw, polygon in (z, y).
static func _side_glass(geo: CityGeo, side: float, hw: float, poly: PackedVector2Array, split: float, glint: bool,
		lift: float = 0.0) -> void:
	_glass(geo, Vector3(side * hw, 0.0, 0.0), Vector3.BACK, Vector3.UP, Vector3(side, 0.0, 0.0), poly, split, glint,
			side < 0.0, -0.01 + lift, GLASS_T + lift)


## A pale frame round a side opening: the opening grown by `pad`, just under the glass.
static func _side_frame(geo: CityGeo, side: float, hw: float, poly: PackedVector2Array, pad: float) -> void:
	var grown := Geometry2D.offset_polygon(poly, pad, Geometry2D.JOIN_MITER)
	if grown.is_empty():
		return
	var g: PackedVector2Array = grown[0]
	_plate(geo, Vector3(side * hw, 0.0, 0.0), Vector3.BACK, Vector3.UP, Vector3(side, 0.0, 0.0), g, -0.01, 0.016,
			[[g, _c("marking")]])


## Glass across a straight profile edge a -> b (a windscreen or rear window): `half` = half its width at the bottom (it
## narrows by `taper` toward the top), `m0` / `m1` = body-colour margins along the edge at a and at b.
static func _seg_glass(geo: CityGeo, a: Vector2, b: Vector2, half: float, taper: float, m0: float, m1: float) -> void:
	var len := a.distance_to(b)
	var d := (b - a) / len
	var o2 := _out2(a, b)
	var o := Vector3(0.0, a.y, a.x)
	var v := Vector3(0.0, d.y, d.x)
	var nrm := Vector3(0.0, o2.y, o2.x)
	var w := half - 0.04
	var lo_y := a.y < b.y
	var t_bot := m0 if lo_y else len - m1
	var t_top := len - m1 if lo_y else m0
	var w_bot := w
	var w_top := w - taper
	var poly := PackedVector2Array([Vector2(-w_bot, t_bot), Vector2(w_bot, t_bot), Vector2(w_top, t_top),
			Vector2(-w_top, t_top)])
	if _signed_area(poly) < 0.0:
		poly.reverse()
	_glass(geo, o, Vector3.RIGHT, v, nrm, poly, -1.0, true, false)


## The terracotta stripe along both sides at the height of the nose / tail band, sweeping up over cut wheel arches.
static func _stripes(geo: CityGeo, st: Dictionary, hw: float, z0: float, z1: float, straight: bool = false) -> void:
	var zs: Array[float] = []
	var ys: Array[float] = []
	if st["arch"]:
		var wz: float = st["wz"]
		for e: Vector2 in [Vector2(z0, 0.66), Vector2(-wz, 0.845), Vector2(-wz + 0.6, 0.70), Vector2(wz - 0.6, 0.70),
				Vector2(wz, 0.845), Vector2(z1, 0.66)]:
			zs.append(e.x)
			ys.append(e.y)
	elif straight:
		zs.assign([z0, z1])
		ys.assign([0.66, 0.66])
	else:
		zs.assign([z0, 0.0, z1])
		ys.assign([0.66, 0.66, 0.66])
	var poly := PackedVector2Array()
	for i in zs.size():
		poly.append(Vector2(zs[i], ys[i] - STRIPE_HALF))
	for i in range(zs.size() - 1, -1, -1):
		poly.append(Vector2(zs[i], ys[i] + STRIPE_HALF))
	if _signed_area(poly) < 0.0:
		poly.reverse()
	for s: float in [-1.0, 1.0]:
		_plate(geo, Vector3(s * hw, 0.0, 0.0), Vector3.BACK, Vector3.UP, Vector3(s, 0.0, 0.0), poly, -0.01, 0.008,
				[[poly, _c("terracotta")]])


## Pale light bars set into the nose (z_front) and the tail (z_back) at height y.
static func _light_bars(geo: CityGeo, y: float, z_front: float, z_back: float) -> void:
	var xf := Transform3D.IDENTITY
	for z: float in [z_front, z_back]:
		geo.box(xf, Vector3(0.0, y, z), Vector3(1.10, 0.14, 0.06), _c("glass_dark"))     # housing
		geo.box(xf, Vector3(0.0, y, z + signf(z) * 0.02), Vector3(0.98, 0.08, 0.06), _c("marking"))


## Four octagonal wheels on axles along x, flat side down on the road: dark tyre, cream hub cap standing out.
static func _wheels(geo: CityGeo, st: Dictionary, simple: bool = false) -> void:
	var yc := WHEEL_R * cos(PI / (SIMPLE_SIDES if simple else WHEEL_SIDES))
	for sz: float in [-1.0, 1.0]:
		for sx: float in [-1.0, 1.0]:
			_wheel(geo, Vector3(sx * float(st["wx"]), yc, sz * float(st["wz"])), sx, simple)


## `simple`: a hexagonal tyre with a flat outer face and a low three-sided pyramid hub cap on it (the game pod's budget)
## instead of the octagon with a stepped hub.
static func _wheel(geo: CityGeo, c: Vector3, side: float, simple: bool = false) -> void:
	var sides := SIMPLE_SIDES if simple else WHEEL_SIDES
	var tyre := _c("metal_dark")
	var hub := _c("curb")
	var x_in := c.x - side * WHEEL_W * 0.5
	var x_out := c.x + side * WHEEL_W * 0.5
	var ring_in: Array[Vector3] = []
	var ring_out: Array[Vector3] = []
	var ring_hub: Array[Vector3] = []
	for k in sides:
		var a := TAU * (float(k) + 0.5) / float(sides)
		var r := Vector3(0.0, -cos(a), sin(a))
		ring_in.append(Vector3(x_in, c.y, c.z) + r * WHEEL_R)
		ring_out.append(Vector3(x_out, c.y, c.z) + r * WHEEL_R)
		ring_hub.append(Vector3(x_out + side * 0.03, c.y, c.z) + r * 0.17)
	var sx := Vector3(side, 0.0, 0.0)
	if simple:
		for k in sides:
			var j := (k + 1) % sides
			var mid := (ring_in[k] + ring_in[j]) * 0.5 - Vector3(x_in, c.y, c.z)
			_q(geo, ring_in[k], ring_in[j], ring_out[j], ring_out[k], tyre, mid)
			if k > 0 and k < sides - 1:
				_t(geo, ring_in[0], ring_in[k], ring_in[k + 1], tyre, -sx)
				_t(geo, ring_out[0], ring_out[k], ring_out[k + 1], tyre, sx)
		# hub cap: a three-sided pyramid standing on the outer face (closed: its base faces into the tyre)
		var hc := Vector3(x_out, c.y, c.z)
		var base: Array[Vector3] = []
		for k in 3:
			var a := TAU * float(k) / 3.0
			base.append(hc + Vector3(0.0, cos(a), sin(a)) * 0.16)
		var apex := hc + sx * 0.05
		for k in 3:
			var j := (k + 1) % 3
			var m := (base[k] + base[j]) * 0.5 - hc
			_t(geo, base[k], base[j], apex, hub, m + sx * 0.5)
		_t(geo, base[0], base[1], base[2], hub, -sx)
		return
	for k in WHEEL_SIDES:
		var j := (k + 1) % WHEEL_SIDES
		var mid := (ring_in[k] + ring_in[j]) * 0.5 - Vector3(x_in, c.y, c.z)
		_q(geo, ring_in[k], ring_in[j], ring_out[j], ring_out[k], tyre, mid)
		_q(geo, ring_out[k], ring_out[j], ring_hub[j], ring_hub[k], tyre, sx)
		if k > 0 and k < WHEEL_SIDES - 1:
			_t(geo, ring_in[0], ring_in[k], ring_in[k + 1], tyre, -sx)
			_t(geo, ring_hub[0], ring_hub[k], ring_hub[k + 1], hub, sx)


## Stance c: a pontoon fender over each wheel, a thick arc of body colour standing out past the body side.
static func _fenders(geo: CityGeo, st: Dictionary) -> void:
	var yc := WHEEL_R * cos(PI / WHEEL_SIDES)
	var cream := _c("cream")
	var dark := _c("metal_dark")
	for sz: float in [-1.0, 1.0]:
		var zc := sz * float(st["wz"])
		var poly := PackedVector2Array()
		for k in 5:
			var a := PI * float(k) / 4.0
			poly.append(Vector2(zc + 0.45 * cos(a), yc + 0.45 * sin(a)))
		for k in range(4, -1, -1):
			var a := PI * float(k) / 4.0
			poly.append(Vector2(zc + 0.36 * cos(a), yc + 0.36 * sin(a)))
		var m := poly.size()
		for sx: float in [-1.0, 1.0]:
			var xa := sx * 0.80
			var xb := sx * 1.10
			for i in m:
				var j := (i + 1) % m
				var o := _out2(poly[i], poly[j])
				var col := dark if i >= 5 else cream          # inner arc (over the tyre) dark, the ends cream
				if i == 4 or i == m - 1:
					col = cream
				_q(geo, Vector3(xa, poly[i].y, poly[i].x), Vector3(xa, poly[j].y, poly[j].x),
						Vector3(xb, poly[j].y, poly[j].x), Vector3(xb, poly[i].y, poly[i].x), col, Vector3(0.0, o.y, o.x))
			var tris := Geometry2D.triangulate_polygon(poly)
			for x: float in [xa, xb]:
				for k in range(0, tris.size(), 3):
					var p0 := poly[tris[k]]
					var p1 := poly[tris[k + 1]]
					var p2 := poly[tris[k + 2]]
					_t(geo, Vector3(x, p0.y, p0.x), Vector3(x, p1.y, p1.x), Vector3(x, p2.y, p2.x), cream,
							Vector3(signf(x - sx * 0.95), 0.0, 0.0))
