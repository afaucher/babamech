class_name BannerMeshes
extends RefCounted
## The invader banner's meshes (docs/design/banners.md; approved look in docs/design/enemies.md §7: design "Descent",
## colouring F2c3). Flat-shaded low-poly vertex colours through MeshKit with the shared mech materials, like the probe
## placeholder it was ported from (tools/enemy_style/enemy_style_probe.gd, never loaded at runtime). Every mesh is
## built once and cached (cloth per length, the rest once). Pure looks: nothing here is gameplay state.
##
##   cloth(len)    origin at the top centre (the cross-bar), hanging down -Y, facing +Z. Three panels, the outer two
##                 folded back; a swallowtail cut up into the middle panel; field on both sides, cream border and the
##                 emblem on the front: a brick arrowhead pointing diagonally down-left with a field-coloured slit, three
##                 long cream bars trailing up-right BEHIND it. Emblem scale 0.85, centred.
##   bar()         the iron cross-bar with two wall brackets (origin = cloth origin, wall behind at -Z)
##   pole()        the free-standing pole with its arm (origin at the pole's foot, the arm along +X at ARM_H)
##   fringe()      what stays on the bar after a tear: ragged field strips and the torn top border
##   heap()        the crumpled cloth at the foot of the facade (origin on the ground, centred, spreading +-X)
##   shred()       one small torn piece (falls during the tear)

const W := 4.0                  ## m: cloth width
const H := 6.4                  ## m: cloth length to the swallowtail points (a facade banner at full size)
const POLE_LEN := 5.6           ## m: the pole-mounted variant's cloth (4.0 x 5.6)
const POLE_H := 11.2            ## m: the pole's height
const ARM_H := 10.7             ## m: the arm (the pole banner's cross-bar) above the pole's foot
const ARM_X := W * 0.5 + 0.45   ## m: the pole banner's cloth centre from the pole, along the arm
const EMBLEM_SCALE := 0.85
const FIELD := Color("3e3c3e")  ## dark slate
const SIGIL := Color("a2453a")  ## brick: the arrowhead
const SIGIL2 := Color("e8dcc0") ## cream: the three bars
const TRIM := Color("e8dcc0")   ## cream: the border
const IRON := Color("2e2e33")

static var _cache: Dictionary = {}


static func cloth(length: float = H) -> ArrayMesh:
	var key := "cloth|%.1f" % length
	if not _cache.has(key):
		_cache[key] = _cloth(snappedf(length, 0.1))
	return _cache[key]


static func bar() -> ArrayMesh:
	if not _cache.has("bar"):
		var k := MeshKit.new()
		k.box(Vector3(W + 0.4, 0.16, 0.16), IRON, Vector3.ZERO)
		for sx: float in [-1.0, 1.0]:
			k.box(Vector3(0.12, 0.12, 0.75), IRON, Vector3(sx * (W * 0.5 - 0.1), 0.0, -0.38))
			k.box(Vector3(0.24, 0.24, 0.24), IRON, Vector3(sx * (W * 0.5 + 0.25), 0.0, 0.0))
		_cache["bar"] = k.commit(LowPolyMaterials.materials())
	return _cache["bar"]


static func pole() -> ArrayMesh:
	if not _cache.has("pole"):
		var k := MeshKit.new()
		k.box(Vector3(0.28, POLE_H, 0.28), IRON, Vector3(0.0, POLE_H * 0.5, 0.0))
		k.box(Vector3(0.7, 0.4, 0.7), IRON, Vector3(0.0, 0.2, 0.0))
		k.box(Vector3(W + 1.0, 0.16, 0.16), IRON, Vector3(W * 0.5 + 0.4, ARM_H, 0.0))
		_cache["pole"] = k.commit(LowPolyMaterials.materials())
	return _cache["pole"]


## Ragged strips left on the bar: lengths fixed (no generator), the border's torn top band across.
static func fringe() -> ArrayMesh:
	if not _cache.has("fringe"):
		var k := MeshKit.new()
		var front := Vector3(0, -0.5, -5.0)
		var back := Vector3(0, -0.5, 5.0)
		var lens := [0.55, 1.1, 0.4, 0.85, 1.3, 0.5, 0.75, 0.35]
		var n := lens.size()
		var hw := W * 0.5
		for i in n:
			var x0 := -hw + W * float(i) / float(n)
			var x1 := -hw + W * float(i + 1) / float(n)
			var l: float = lens[i]
			var tip := Vector3(lerpf(x0, x1, 0.35 + 0.3 * float(i % 2)), -l, 0.02)
			var pts := PackedVector3Array([Vector3(x0, 0, 0), Vector3(x1, 0, 0), Vector3(x1, -l * 0.6, 0.01), tip,
				Vector3(x0, -l * 0.7, 0.01)])
			k.poly(pts, FIELD, front)
			k.poly(pts, FIELD, back)
		k.quad(Vector3(-hw, 0, 0.03), Vector3(hw, 0, 0.03), Vector3(hw, -0.3, 0.03), Vector3(-hw, -0.3, 0.03), TRIM, front)
		_cache["fringe"] = k.commit(LowPolyMaterials.materials())
	return _cache["fringe"]


## The crumpled cloth on the ground: a few flattened lumps of field with folds of brick and cream showing.
static func heap() -> ArrayMesh:
	if not _cache.has("heap"):
		var k := MeshKit.new()
		k.ico(Vector3(-0.7, 0.18, 0.1), Vector3(1.1, 0.3, 0.7), FIELD)
		k.ico(Vector3(0.6, 0.22, -0.05), Vector3(1.0, 0.38, 0.75), FIELD)
		k.ico(Vector3(0.05, 0.36, 0.15), Vector3(0.7, 0.32, 0.55), FIELD)
		k.ico(Vector3(1.45, 0.1, 0.35), Vector3(0.55, 0.16, 0.45), FIELD)
		# Folds showing the front: a brick flap and a cream edge, flat on the lumps.
		k.poly(PackedVector3Array([Vector3(-0.2, 0.62, -0.05), Vector3(0.55, 0.58, 0.25), Vector3(0.3, 0.46, 0.6),
			Vector3(-0.35, 0.5, 0.42)]), SIGIL, Vector3(0, -2, 0))
		k.poly(PackedVector3Array([Vector3(-1.6, 0.2, 0.55), Vector3(-0.4, 0.33, 0.66), Vector3(-0.35, 0.28, 0.82),
			Vector3(-1.55, 0.14, 0.72)]), TRIM, Vector3(0, -2, 0))
		k.poly(PackedVector3Array([Vector3(0.9, 0.5, 0.3), Vector3(1.4, 0.36, 0.5), Vector3(1.3, 0.3, 0.62),
			Vector3(0.85, 0.44, 0.45)]), SIGIL2, Vector3(0, -2, 0))
		_cache["heap"] = k.commit(LowPolyMaterials.materials())
	return _cache["heap"]


static func shred() -> ArrayMesh:
	if not _cache.has("shred"):
		var k := MeshKit.new()
		var pts := PackedVector3Array([Vector3(-0.28, 0.2, 0), Vector3(0.3, 0.16, 0), Vector3(0.22, -0.2, 0),
			Vector3(-0.05, -0.12, 0), Vector3(-0.3, -0.22, 0)])
		k.poly(pts, FIELD, Vector3(0, 0, -1))
		k.poly(pts, FIELD, Vector3(0, 0, 1))
		k.quad(Vector3(-0.28, 0.2, 0.01), Vector3(0.3, 0.16, 0.01), Vector3(0.3, 0.08, 0.01), Vector3(-0.28, 0.12, 0.01),
			TRIM, Vector3(0, 0, -1))
		_cache["shred"] = k.commit(LowPolyMaterials.materials())
	return _cache["shred"]


static func _cloth(h: float) -> ArrayMesh:
	var k := MeshKit.new()
	var hw := W * 0.5
	var mw := hw * 0.62         # middle panel half width
	var fold := -0.22           # outer edges set back
	var notch := 1.4 * h / H    # swallowtail: the cut rises this far into the middle panel
	var front := Vector3(0.0, -h * 0.5, -5.0)   # "away" point behind the cloth: faces point +Z
	var back := Vector3(0.0, -h * 0.5, 5.0)
	var e := 0.025
	var sides := [
		[Vector3(-hw, 0, fold), Vector3(-mw, 0, 0), Vector3(-mw, -h, 0), Vector3(-hw, -h, fold)],
		[Vector3(mw, 0, 0), Vector3(hw, 0, fold), Vector3(hw, -h, fold), Vector3(mw, -h, 0)],
	]
	for pn: Array in sides:
		k.quad(pn[0], pn[1], pn[2], pn[3], FIELD, front)
		k.quad(pn[0], pn[1], pn[2], pn[3], FIELD, back)
	for sx: float in [-1.0, 1.0]:
		var half := PackedVector3Array([Vector3(0, 0, 0), Vector3(sx * mw, 0, 0), Vector3(sx * mw, -h, 0), Vector3(0, -h + notch, 0)])
		k.poly(half, FIELD, front)
		k.poly(half, FIELD, back)
	# Border: the top band, the outer edges, the side panels' bottoms and both edges of the notch.
	var bw := 0.16
	for sx: float in [-1.0, 1.0]:
		var o0 := Vector3(sx * hw, 0, fold + e)
		var m0 := Vector3(sx * mw, 0, e)
		k.quad(o0, m0, m0 + Vector3(0, -0.32, 0), o0 + Vector3(0, -0.32, 0), TRIM, front)
		var i0 := Vector3(sx * (hw - bw), 0, fold * (hw - bw - mw) / (hw - mw) + e)
		k.quad(o0, i0, i0 + Vector3(0, -h, 0), o0 + Vector3(0, -h, 0), TRIM, front)
		var b0 := Vector3(sx * hw, -h, fold + e)
		var b1 := Vector3(sx * mw, -h, e)
		k.quad(b0, b1, b1 + Vector3(0, bw, 0), b0 + Vector3(0, bw, 0), TRIM, front)
		var n1 := Vector3(0, -h + notch, e)
		k.quad(b1, n1, n1 + Vector3(0, bw * 1.3, 0), b1 + Vector3(0, bw * 1.1, 0), TRIM, front)
	k.quad(Vector3(-mw, 0, e), Vector3(mw, 0, e), Vector3(mw, -0.32, e), Vector3(-mw, -0.32, e), TRIM, front)
	# Emblem "Descent": laid out in 2D on the cloth (x right as seen from the front, y up), clipped at the folds and
	# lifted onto each panel's plane. Bars first (under the arrowhead), then the head, then the slit on top.
	var d := Vector2(-0.68, -0.73).normalized()      # arrow direction: down-left, about 47 degrees
	var pv := Vector2(-d.y, d.x)
	var bk := Vector2(0.0, -h * 0.42)
	var a_len := 1.9
	var a_half := 1.2
	var tip_pt := bk + d * a_len
	var polys := []
	var bar_w := 0.26
	for i in 3:
		var v := (float(i) - 1.0) * 0.42
		var s0 := a_len / 3.0
		var s1 := -(2.2 if i == 1 else 1.9)
		var c0 := bk + pv * v
		polys.append([[c0 + d * s0 + pv * bar_w * 0.5, c0 + d * s0 - pv * bar_w * 0.5, c0 + d * s1 - pv * bar_w * 0.5,
				c0 + d * s1 + pv * bar_w * 0.5], SIGIL2, e * 2.0])
	polys.append([[bk + pv * a_half, bk - pv * a_half, tip_pt], SIGIL, e * 3.0])
	polys.append([[bk + pv * 0.07, bk - pv * 0.07, bk + d * (a_len - 0.2)], FIELD, e * 4.0])
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for pl: Array in polys:
		for q: Vector2 in pl[0]:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var mid_box := (lo + hi) * 0.5
	var place := Vector2(0.0, mid_box.y)
	for pl: Array in polys:
		var pts := []
		for q: Vector2 in pl[0]:
			pts.append(place + (q - mid_box) * EMBLEM_SCALE)
		_emblem_poly(k, pts, pl[1], front, hw, mw, fold, pl[2])
	return k.commit(LowPolyMaterials.materials())


static func _emblem_poly(k: MeshKit, pts: Array, col: Color, away: Vector3, hw: float, mw: float, fold: float, lift: float) -> void:
	for band: Vector2 in [Vector2(-INF, -mw), Vector2(-mw, mw), Vector2(mw, INF)]:
		var piece := _clip_x(_clip_x(pts, band.x, true), band.y, false)
		if piece.size() < 3:
			continue
		var out := PackedVector3Array()
		for q: Vector2 in piece:
			var z := 0.0
			if absf(q.x) > mw:
				z = fold * (absf(q.x) - mw) / (hw - mw)
			out.append(Vector3(q.x, q.y, z + lift))
		k.poly(out, col, away)


## Sutherland-Hodgman against one vertical line: keep x >= x0 (keep_greater) or x <= x0.
static func _clip_x(pts: Array, x0: float, keep_greater: bool) -> Array:
	if is_inf(x0):
		return pts
	var out := []
	for i in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		var ina := (a.x >= x0) if keep_greater else (a.x <= x0)
		var inb := (b.x >= x0) if keep_greater else (b.x <= x0)
		if ina:
			out.append(a)
		if ina != inb:
			var t := (x0 - a.x) / (b.x - a.x)
			out.append(a.lerp(b, t))
	return out
