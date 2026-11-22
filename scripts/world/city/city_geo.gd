class_name CityGeo
extends RefCounted
## Flat-shaded triangle soup builder for the city: one colour and one normal per face, no textures, no indices.
## Two kinds of calls:
##   * rigid shapes in a local frame (box / prism / gable / frustum): buildings, furniture, ribs
##   * ground shapes in arc coordinates (g_rect / g_wall_* / g_quad): roads, sidewalks, markings, ceiling panels. These
##     follow the FACETED deck: the ring floor is drawn as flat facets SEG metres long, and g_point() maps (x, s, h) onto
##     those facets, so a marking laid 2 cm above the road is 2 cm above it everywhere.

const SEG := 4.0     ## facet length of the deck along the arc (m)
const PX := 1
const NX := 2
const PY := 4
const NY := 8
const PZ := 16
const NZ := 32
const ALL := 63
const NO_BOTTOM := 55     ## ALL - NY
const NO_BACK := 31       ## ALL - NZ (a box attached to a wall whose outward normal is local +Z)

var ring: RingFrame
var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var holes: Array[Rect2] = []     ## floor holes (x, s): the ground shapes (g_*) leave out whatever falls inside one


func _init(r: RingFrame = null) -> void:
	ring = r


func is_empty() -> bool:
	return verts.is_empty()


func tri_count() -> int:
	return verts.size() / 3


## A quad with corners counter-clockwise as seen from its front.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var n := (b - a).cross(d - a).normalized()
	verts.append_array(PackedVector3Array([a, c, b, a, d, c]))
	normals.append_array(PackedVector3Array([n, n, n, n, n, n]))
	colors.append_array(PackedColorArray([col, col, col, col, col, col]))


## A triangle with corners counter-clockwise as seen from its front.
func tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	verts.append_array(PackedVector3Array([a, c, b]))
	normals.append_array(PackedVector3Array([n, n, n]))
	colors.append_array(PackedColorArray([col, col, col]))


## A box in the frame `xf`. `faces` picks the sides (PX..NZ); `top` recolours the +Y face.
func box(xf: Transform3D, center: Vector3, size: Vector3, col: Color, faces: int = ALL, top: Variant = null) -> void:
	var h := size * 0.5
	var p0 := xf * (center + Vector3(-h.x, -h.y, -h.z))
	var p1 := xf * (center + Vector3(h.x, -h.y, -h.z))
	var p2 := xf * (center + Vector3(h.x, -h.y, h.z))
	var p3 := xf * (center + Vector3(-h.x, -h.y, h.z))
	var p4 := xf * (center + Vector3(-h.x, h.y, -h.z))
	var p5 := xf * (center + Vector3(h.x, h.y, -h.z))
	var p6 := xf * (center + Vector3(h.x, h.y, h.z))
	var p7 := xf * (center + Vector3(-h.x, h.y, h.z))
	if faces & PX:
		quad(p2, p1, p5, p6, col)
	if faces & NX:
		quad(p0, p3, p7, p4, col)
	if faces & PY:
		quad(p7, p6, p5, p4, col if top == null else (top as Color))
	if faces & NY:
		quad(p0, p1, p2, p3, col)
	if faces & PZ:
		quad(p3, p2, p6, p7, col)
	if faces & NZ:
		quad(p1, p0, p4, p5, col)


## An upright n-sided prism (or cone / frustum when r_top differs) standing on `base` in the frame `xf`.
## Pass `bottom` (a Color) to cap the underside (e.g. elevated tanks, overhanging roofs, toppleable props).
func prism(xf: Transform3D, base: Vector3, r: float, height: float, sides: int, col: Color, r_top: float = -1.0,
		cap: Variant = null, bottom: Variant = null) -> void:
	var rt := r if r_top < 0.0 else r_top
	var top := base + Vector3(0, height, 0)
	var cap_col: Color = col if cap == null else (cap as Color)
	for i in sides:
		var a0 := TAU * (float(i) + 0.5) / float(sides)
		var a1 := TAU * (float(i) + 1.5) / float(sides)
		var d0 := Vector3(cos(a0), 0, -sin(a0))
		var d1 := Vector3(cos(a1), 0, -sin(a1))
		if rt > 0.001:
			quad(xf * (base + d0 * r), xf * (base + d1 * r), xf * (top + d1 * rt), xf * (top + d0 * rt), col)
			tri(xf * top, xf * (top + d0 * rt), xf * (top + d1 * rt), cap_col)
		else:
			tri(xf * (base + d0 * r), xf * (base + d1 * r), xf * top, col)
		if bottom != null and r > 0.001:
			tri(xf * base, xf * (base + d1 * r), xf * (base + d0 * r), bottom as Color)


## A gable roof on a w x d rectangle centred at `base`, ridge along local Z, `rise` high. Ends closed with `end_col`.
## Pass `bottom` (a Color) to close the underside soffit when eaves overhang.
func gable(xf: Transform3D, base: Vector3, w: float, d: float, rise: float, col: Color, end_col: Color,
		bottom: Variant = null) -> void:
	var a := xf * (base + Vector3(-w * 0.5, 0, d * 0.5))
	var b := xf * (base + Vector3(w * 0.5, 0, d * 0.5))
	var c := xf * (base + Vector3(w * 0.5, 0, -d * 0.5))
	var e := xf * (base + Vector3(-w * 0.5, 0, -d * 0.5))
	var r0 := xf * (base + Vector3(0, rise, d * 0.5))
	var r1 := xf * (base + Vector3(0, rise, -d * 0.5))
	quad(b, c, r1, r0, col)
	quad(e, a, r0, r1, col)
	tri(a, b, r0, end_col)
	tri(c, e, r1, end_col)
	if bottom != null:
		quad(e, c, b, a, bottom as Color)


## Four sloped sides between a lower rectangle (half0 at y0) and an upper one (half1 at y1), both centred on `off`.
func frustum(xf: Transform3D, off: Vector3, y0: float, half0: Vector2, y1: float, half1: Vector2, col: Color) -> void:
	var lo: Array[Vector3] = []
	var hi: Array[Vector3] = []
	for k: Vector2 in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		lo.append(xf * (off + Vector3(k.x * half0.x, y0, k.y * half0.y)))
		hi.append(xf * (off + Vector3(k.x * half1.x, y1, k.y * half1.y)))
	for i in 4:
		var j := (i + 1) % 4
		quad(lo[i], lo[j], hi[j], hi[i], col)


# --- Ground (arc coordinates on the faceted deck) ---------------------------------------------------------

## World position of arc point (x, s) at height h above the FACETED floor.
func g_point(x: float, s: float, h: float = 0.0) -> Vector3:
	var k := floorf(s / SEG)
	var sa := k * SEG
	var t := (s - sa) / SEG
	if t < 1e-6:
		return ring.arc_to_world(x, sa, h)
	return ring.arc_to_world(x, sa, h).lerp(ring.arc_to_world(x, sa + SEG, h), t)


## The upright frame at arc point (x, s, h): local X = along the axis, Y = up (radial), Z = along +s.
func frame(x: float, s: float, h: float = 0.0, yaw: float = 0.0) -> Transform3D:
	return Transform3D(frame_basis(ring, s), g_point(x, s, h)) * Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO)


static func frame_basis(r: RingFrame, s: float) -> Basis:
	var th := s / r.radius
	return Basis(Vector3.RIGHT, Vector3(0.0, cos(th), -sin(th)), Vector3(0.0, sin(th), cos(th)))


## The s values where a span [s0, s1] has to break to follow the facets.
static func breaks(s0: float, s1: float) -> PackedFloat32Array:
	var out := PackedFloat32Array([s0])
	var k := floorf(s0 / SEG) + 1.0
	while k * SEG < s1 - 1e-4:
		if k * SEG > s0 + 1e-4:
			out.append(k * SEG)
		k += 1.0
	out.append(s1)
	return out


## `r` minus every rectangle in `out_of`, as non-overlapping rectangles (a hole splits a piece into up to four).
static func cut(r: Rect2, out_of: Array[Rect2]) -> Array[Rect2]:
	var parts: Array[Rect2] = [r]
	for o in out_of:
		var next: Array[Rect2] = []
		for q in parts:
			if not q.intersects(o):
				next.append(q)
				continue
			var c := q.intersection(o)
			if c.position.x > q.position.x:
				next.append(Rect2(q.position.x, q.position.y, c.position.x - q.position.x, q.size.y))
			if c.end.x < q.end.x:
				next.append(Rect2(c.end.x, q.position.y, q.end.x - c.end.x, q.size.y))
			if c.position.y > q.position.y:
				next.append(Rect2(c.position.x, q.position.y, c.size.x, c.position.y - q.position.y))
			if c.end.y < q.end.y:
				next.append(Rect2(c.position.x, c.end.y, c.size.x, q.end.y - c.end.y))
		parts = next
	return parts


## [a, b] minus the holes that a line at constant `across` passes through (strictly inside: a hole's own edge stays).
func open_spans(a: float, b: float, across: float, along_s: bool) -> Array:
	var spans := [[a, b]]
	for o in holes:
		var lo := o.position.x if along_s else o.position.y
		var hi := o.end.x if along_s else o.end.y
		if across <= lo or across >= hi:
			continue
		var c0 := o.position.y if along_s else o.position.x
		var c1 := o.end.y if along_s else o.end.x
		var next := []
		for sp: Array in spans:
			if c1 <= sp[0] or c0 >= sp[1]:
				next.append(sp)
				continue
			if c0 > sp[0]:
				next.append([sp[0], c0])
			if c1 < sp[1]:
				next.append([c1, sp[1]])
		spans = next
	return spans


func in_hole(x: float, s: float) -> bool:
	for o in holes:
		if x > o.position.x and x < o.end.x and s > o.position.y and s < o.end.y:
			return true
	return false


## A horizontal rectangle at height h. `up` false faces it down (ceilings).
func g_rect(x0: float, x1: float, s0: float, s1: float, h: float, col: Color, up: bool = true) -> void:
	if holes.is_empty():
		_g_rect(x0, x1, s0, s1, h, col, up)
		return
	for q in cut(Rect2(x0, s0, x1 - x0, s1 - s0).abs(), holes):
		_g_rect(q.position.x, q.end.x, q.position.y, q.end.y, h, col, up)


func _g_rect(x0: float, x1: float, s0: float, s1: float, h: float, col: Color, up: bool) -> void:
	var b := breaks(s0, s1)
	for i in b.size() - 1:
		var p0 := g_point(x0, b[i], h)
		var p1 := g_point(x1, b[i], h)
		var p2 := g_point(x1, b[i + 1], h)
		var p3 := g_point(x0, b[i + 1], h)
		if up:
			quad(p0, p3, p2, p1, col)
		else:
			quad(p0, p1, p2, p3, col)


## A vertical face at constant x from h0 to h1, facing +x (sgn > 0) or -x.
func g_wall_x(x: float, s0: float, s1: float, h0: float, h1: float, sgn: float, col: Color) -> void:
	if not holes.is_empty():
		for sp: Array in open_spans(s0, s1, x, true):
			_g_wall_x(x, sp[0], sp[1], h0, h1, sgn, col)
		return
	_g_wall_x(x, s0, s1, h0, h1, sgn, col)


func _g_wall_x(x: float, s0: float, s1: float, h0: float, h1: float, sgn: float, col: Color) -> void:
	var b := breaks(s0, s1)
	for i in b.size() - 1:
		var a := g_point(x, b[i], h0)
		var c := g_point(x, b[i + 1], h0)
		var d := g_point(x, b[i + 1], h1)
		var e := g_point(x, b[i], h1)
		if sgn > 0.0:
			quad(c, a, e, d, col)
		else:
			quad(a, c, d, e, col)


## A vertical face at constant s from h0 to h1, facing +s (sgn > 0) or -s.
func g_wall_s(s: float, x0: float, x1: float, h0: float, h1: float, sgn: float, col: Color) -> void:
	if not holes.is_empty():
		for sp: Array in open_spans(x0, x1, s, false):
			_g_wall_s(s, sp[0], sp[1], h0, h1, sgn, col)
		return
	_g_wall_s(s, x0, x1, h0, h1, sgn, col)


func _g_wall_s(s: float, x0: float, x1: float, h0: float, h1: float, sgn: float, col: Color) -> void:
	var a := g_point(x0, s, h0)
	var c := g_point(x1, s, h0)
	var d := g_point(x1, s, h1)
	var e := g_point(x0, s, h1)
	if sgn > 0.0:
		quad(a, c, d, e, col)
	else:
		quad(c, a, e, d, col)


## A raised slab: top at h1 plus its four sides down to h0.
func g_slab(x0: float, x1: float, s0: float, s1: float, h0: float, h1: float, col: Color, side: Variant = null) -> void:
	var sc: Color = col if side == null else (side as Color)
	g_rect(x0, x1, s0, s1, h1, col)
	g_wall_x(x1, s0, s1, h0, h1, 1.0, sc)
	g_wall_x(x0, s0, s1, h0, h1, -1.0, sc)
	g_wall_s(s1, x0, x1, h0, h1, 1.0, sc)
	g_wall_s(s0, x0, x1, h0, h1, -1.0, sc)


## A small free quad given as arc points Vector3(x, s, h), counter-clockwise seen from its front. Not split at facets:
## keep it short along s.
func g_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var m := (a + b + c + d) * 0.25
	if not holes.is_empty() and in_hole(m.x, m.y):
		return
	quad(g_point(a.x, a.y, a.z), g_point(b.x, b.y, b.z), g_point(c.x, c.y, c.z), g_point(d.x, d.y, d.z), col)


func g_tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var m := (a + b + c) / 3.0
	if not holes.is_empty() and in_hole(m.x, m.y):
		return
	tri(g_point(a.x, a.y, a.z), g_point(b.x, b.y, b.z), g_point(c.x, c.y, c.z), col)


# --- Output ----------------------------------------------------------------------------------------------

func commit(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material if material != null else CityPalette.surface_material())
	return mesh


func instance(node_name: String, material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = commit(material)
	return mi
