class_name MeshKit
extends RefCounted
## A flat-shaded low-poly mesh builder: every triangle gets its own three vertices, one face normal and one flat colour
## (vertex colours), so facets stay visible and no texture is needed. Up to three surfaces: matte (lit), glow (unshaded:
## lights and lenses, filled while `glow` is true) and accent (lit, the recolourable trim: faces whose colour matches
## `accent_key`, stored white so the accent material's albedo gives the hue), plus an optional fourth, heat (lit, filled
## while `heat` is true: the radiator's fins, which the game gives an emissive override by surface name). `commit` adds
## only non-empty surfaces and names each one ("matte", "glow", "accent", "heat"), so look surfaces up by name, not index.
##
## Shapes are added in the current transform (push / pop). Faces are wound to point away from a reference point (the
## shape's own centre for the convex primitives), so mirrored transforms are safe.
## A colour argument is a Color, or a Callable(face_centre: Vector3, normal: Vector3) -> Color in mesh space.

const SQUARE := 100.0   ## ring `power` for sharp rectangular corners

var glow := false
## Per-face brightness variation (+-), from a hash of the face position: a hand-painted low-poly touch.
var shade := 0.035
## Faces of this colour (a Color, or null for none) go to the accent surface. Not applied while `glow`.
var accent_key: Variant = null
## Faces go to the heat surface while true (lit like matte; never accent). Ignored while `glow`.
var heat := false

var _xf := Transform3D.IDENTITY
var _stack: Array[Transform3D] = []
const SURFACES := ["matte", "glow", "accent", "heat"]

var _v: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
var _n: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
var _c: Array[PackedColorArray] = [PackedColorArray(), PackedColorArray(), PackedColorArray(), PackedColorArray()]


static func xf(pos: Vector3, rot_deg: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE) -> Transform3D:
	return Transform3D(Basis.from_euler(rot_deg * PI / 180.0) * Basis.from_scale(scl), pos)


func push(t: Transform3D) -> void:
	_stack.append(_xf)
	_xf = _xf * t


func pop() -> void:
	_xf = _stack.pop_back()


func tri_count() -> int:
	return (_v[0].size() + _v[1].size() + _v[2].size() + _v[3].size()) / 3


## One triangle. With `away` (a point in the current transform's space) the face is wound to point away from it;
## without, a, b, c are taken as clockwise seen from the front (Godot's front face).
func tri(a: Vector3, b: Vector3, c: Vector3, col: Variant, away: Variant = null) -> void:
	a = _xf * a
	b = _xf * b
	c = _xf * c
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	var centre := (a + b + c) / 3.0
	var flip := false
	if away != null:
		flip = n.dot(centre - _xf * (away as Vector3)) < 0.0
	else:
		flip = _xf.basis.determinant() < 0.0
	if flip:
		var t := b
		b = c
		c = t
		n = -n
	var color: Color = col.call(centre, n) if col is Callable else col
	var s := 1 if glow else 0
	if not glow and heat:
		s = 3
	elif not glow and accent_key != null and color.is_equal_approx(accent_key as Color):
		s = 2
		color = Color.WHITE   # the accent material's albedo supplies the hue; the shade jitter below still varies facets
	if not glow and shade > 0.0:
		var h := hash(Vector3i((centre * 997.0).round())) % 1000
		color = color.lightened(shade * float(h) / 1000.0) if h % 2 == 0 else color.darkened(shade * float(h) / 1000.0)
	_v[s].append_array([a, b, c])
	_n[s].append_array([n, n, n])
	_c[s].append_array([color, color, color])


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Variant, away: Variant = null) -> void:
	tri(a, b, c, col, away)
	tri(a, c, d, col, away)


## A convex polygon (fan from its first point).
func poly(pts: PackedVector3Array, col: Variant, away: Variant = null) -> void:
	for i in range(1, pts.size() - 1):
		tri(pts[0], pts[i], pts[i + 1], col, away)


## n points of a superellipse around `c`, in the plane across `axis` ("x", "y" or "z"). power 2 = ellipse, higher =
## boxier, SQUARE = a rectangle (with n = 4). Point 0 starts half a step (phase) from the plane's first direction:
## axis z: from up toward +X; axis y: from forward (-Z) toward +X; axis x: from up toward forward.
static func ring(c: Vector3, rx: float, ry: float, n: int, axis: String = "y", power: float = 2.0, phase: float = 0.5) -> PackedVector3Array:
	var u := Vector3.RIGHT
	var v := Vector3.UP
	if axis == "y":
		v = Vector3.FORWARD
	elif axis == "x":
		u = Vector3.FORWARD
	return ring_uv(c, u * rx, v * ry, n, power, phase)


static func ring_uv(c: Vector3, u: Vector3, v: Vector3, n: int, power: float = 2.0, phase: float = 0.5) -> PackedVector3Array:
	var out := PackedVector3Array()
	var e := 2.0 / power
	for k in n:
		var a := TAU * (float(k) + phase) / float(n)
		var su := sin(a)
		var cv := cos(a)
		out.append(c + u * (signf(su) * pow(absf(su), e)) + v * (signf(cv) * pow(absf(cv), e)))
	return out


static func centroid(pts: PackedVector3Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / float(maxi(pts.size(), 1))


## Skin a row of rings (same point count each). `col` may also be an Array with one colour per band. `flip` turns the
## skin inside out (the inner wall of a rim).
func loft(rings: Array, col: Variant, cap_a: bool = true, cap_b: bool = true, flip: bool = false) -> void:
	var cents: Array[Vector3] = []
	for r: PackedVector3Array in rings:
		cents.append(centroid(r))
	for i in rings.size() - 1:
		var a: PackedVector3Array = rings[i]
		var b: PackedVector3Array = rings[i + 1]
		var mid := (cents[i] + cents[i + 1]) * 0.5
		var band: Variant = col
		if col is Array:
			band = (col as Array)[mini(i, (col as Array).size() - 1)]
		var n := a.size()
		for k in n:
			var k2 := (k + 1) % n
			for t: Array in [[a[k], a[k2], b[k2]], [a[k], b[k2], b[k]]]:
				var away := mid
				if flip:   # mirror the reference point through the face, so the face points at the axis
					var fc: Vector3 = (t[0] + t[1] + t[2]) / 3.0
					away = fc * 2.0 - mid
				tri(t[0], t[1], t[2], band, away)
	if rings.size() < 2:
		return
	var first: Variant = col
	var last: Variant = col
	if col is Array:
		first = (col as Array)[0]
		last = (col as Array)[(col as Array).size() - 1]
	if cap_a:
		poly(rings[0], first, cents[1])
	if cap_b:
		poly(rings[rings.size() - 1], last, cents[rings.size() - 2])


## A straight piece from a to b: an n-sided section of half-sizes ra at a and rb at b (Vector2.ZERO = a point).
## The section's x is the model's right (up, when the piece runs along X); its y is across both.
func seg(a: Vector3, b: Vector3, ra: Vector2, rb: Vector2, n: int, col: Variant, power: float = 2.0, caps: bool = true,
		phase: float = 0.5) -> void:
	var d := (b - a).normalized()
	var xr := Vector3.RIGHT if absf(d.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP
	var z := xr.cross(d).normalized()
	var x := d.cross(z).normalized()
	loft([ring_uv(a, x * ra.x, z * ra.y, n, power, phase), ring_uv(b, x * rb.x, z * rb.y, n, power, phase)], col, caps, caps)


## A round tube from a to b.
func tube(a: Vector3, b: Vector3, r: float, n: int, col: Variant, r_end: float = -1.0) -> void:
	var re := r if r_end < 0.0 else r_end
	seg(a, b, Vector2(r, r), Vector2(re, re), n, col)


func box(size: Vector3, col: Variant, pos: Vector3 = Vector3.ZERO) -> void:
	var h := size * 0.5
	loft([ring(pos - Vector3(0, h.y, 0), h.x, h.z, 4, "y", SQUARE), ring(pos + Vector3(0, h.y, 0), h.x, h.z, 4, "y", SQUARE)], col)


## Revolve a profile of (radius, y) points around Y with n sides.
func lathe(profile: Array, n: int, col: Variant, cap_a: bool = true, cap_b: bool = true, flip: bool = false) -> void:
	var rings: Array = []
	for p: Vector2 in profile:
		rings.append(ring(Vector3(0, p.y, 0), p.x, p.x, n, "y"))
	loft(rings, col, cap_a, cap_b, flip)


## A 20-face ball (icosahedron), stretched by `radius`.
func ico(centre: Vector3, radius: Vector3, col: Variant) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var p: Array[Vector3] = []
	for v: Vector3 in [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
			Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]:
		p.append(centre + v.normalized() * radius)
	for f: Array in [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
			[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]:
		tri(p[f[0]], p[f[1]], p[f[2]], col, centre)


## The mesh: the matte, glow, accent and heat surfaces that have faces, in that order, each named after its kind.
## `mats` = [matte, glow, accent(, heat)] materials (heat falls back to matte when only three are given).
func commit(mats: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for s in SURFACES.size():
		if _v[s].is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _v[s]
		arrays[Mesh.ARRAY_NORMAL] = _n[s]
		arrays[Mesh.ARRAY_COLOR] = _c[s]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var i := mesh.get_surface_count() - 1
		mesh.surface_set_material(i, mats[s] if s < mats.size() else mats[0])
		mesh.surface_set_name(i, SURFACES[s])
	return mesh
