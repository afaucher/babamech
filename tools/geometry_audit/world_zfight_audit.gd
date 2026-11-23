class_name WorldZfightAudit
extends RefCounted
## Finds z-fighting candidates in drawn geometry (docs/design/city-geometry-audit.md): pairs of triangles, from different
## meshes or inside one, that are
##   (a) near-coplanar: normals within NORMAL_TOL_DEG, facing the same way (opposite-facing pairs are counted apart as
##       "back to back": with back-face culling only one of them is ever drawn from any side);
##   (b) closer than SEP_MAX along the normal, measured at the centre of their overlap (histogram 0 / <1 mm / <1 cm /
##       <2 cm / <5 cm; a FINDING is under SEP_FINDING);
##   (c) overlapping in the plane by more than AREA_EPS (exact 2D triangle-triangle clipping, not bounding boxes).
## Same colour and same material: invisible (identical flat shading) but wasted: counted as "duplicate faces".
##
## Speed: every triangle gets a key from its quantised canonical plane (normal components in NQ cells, offset in DQ
## cells), and is also filed under the neighbouring cell of any dimension it lies within tolerance of, so every close
## pair shares the home cell of its lower-numbered triangle. The (key, triangle, home) entries are packed into one int64
## each and sorted natively; inside a large cell a 2D grid in the plane finds overlapping candidates.
##
## Labels: a mesh's node name (digits dropped) plus, when the geometry was built with CityGeo.audit on, the CityGeo tag of
## the batch the triangle came from (CityGeo.tag; zero cost when audit is off). MultiMesh instances (props) count too.

const NORMAL_TOL_DEG := 1.0
const SEP_MAX := 0.05          ## pairs further apart than this are not looked at
const SEP_FINDING := 0.0195    ## a z-fighting finding is closer than this: the decal rule's 2 cm (CityStreets.DECAL_*),
                               ## less 0.5 mm of float slack (faces on the faceted deck, a slope's lines)
const AREA_EPS := 0.002        ## m^2 of overlap below which a pair only touches
const NQ := 0.04               ## normal component cell
const DQ := 0.10               ## plane offset cell (m)
const GRID := 4.0              ## 2D grid cell inside a big plane cell (m)
const BRUTE := 24              ## plane cells up to this size are checked pair by pair
const SEP_BINS := [0.00001, 0.001, 0.01, 0.02, 0.05]
const SEP_NAMES := ["0", "<1mm", "<1cm", "<2cm", "<5cm"]
const FLIP := Vector3(0.62, 0.52, 0.587)    ## canonical side of a normal (no ring normal lies near its plane)

var pos := PackedVector3Array()     ## 3 per triangle, world space
var nrm := PackedVector3Array()     ## canonical unit normal per triangle
var off := PackedFloat64Array()     ## canonical plane offset
var flp := PackedByteArray()        ## 1: the drawn normal is the opposite of the canonical one
var col := PackedColorArray()
var mat := PackedInt32Array()
var src := PackedInt32Array()       ## label id
var deck := PackedInt32Array()
var labels: Array[String] = []
var materials: Array = []
var deck_of: Callable               ## world position -> deck index (default: 0)
var arc_of: Callable                ## world position -> {deck, x, s, h} (default: none)
var region: Callable                ## world centroid -> bool: only these triangles (default: all)
var groups := {}                    ## "kind|A|B" -> group dict
var hist := {}                      ## kind -> [count per SEP_BINS], area per bin
var pairs_tested := 0
var ms := {}
var skipped: Array[String] = []     ## multimeshes left out (no instance poses headless)
var trace := ""                     ## print the first findings whose "A|B" labels contain this (debugging a group)
var _traced := 0

var _label_ids := {}
var _names := {}


func _init() -> void:
	for k: String in CityPalette.C:
		_names[(CityPalette.C[k] as Color).to_html(false)] = k


func tri_count() -> int:
	return src.size()


# --- Collecting ------------------------------------------------------------------------------------------

## Every visible mesh and multimesh under `root` (root included).
func add_node(root: Node) -> void:
	var t := Time.get_ticks_msec()
	var list: Array[Node] = [root]
	list.append_array(root.find_children("*", "GeometryInstance3D", true, false))
	for n in list:
		if n is MeshInstance3D and (n as MeshInstance3D).is_visible_in_tree() and (n as MeshInstance3D).mesh != null:
			_add_mesh_instance(n as MeshInstance3D)
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).is_visible_in_tree() and (n as MultiMeshInstance3D).multimesh != null:
			_add_multimesh(n as MultiMeshInstance3D)
	ms["collect"] = float(ms.get("collect", 0.0)) + float(Time.get_ticks_msec() - t)


static func node_label(n: Node) -> String:
	var parts: Array[String] = []
	var cur := n
	for i in 2:
		if cur == null or cur is CityDistrict or cur is CityStack or cur.get_parent() == null:
			break
		var nm := ""
		for ch in str(cur.name):
			if not ch.is_valid_int():
				nm += ch
		parts.push_front(nm)
		cur = cur.get_parent()
	return "/".join(parts)


func _label(s: String) -> int:
	if not _label_ids.has(s):
		_label_ids[s] = labels.size()
		labels.append(s)
	return int(_label_ids[s])


func _material(m: Material) -> int:
	var i := materials.find(m)
	if i < 0:
		materials.append(m)
		i = materials.size() - 1
	return i


func _add_mesh_instance(mi: MeshInstance3D) -> void:
	var base := node_label(mi)
	var tags: Variant = mi.get_meta("audit_tags") if mi.has_meta("audit_tags") else null
	for s in mi.mesh.get_surface_count():
		var m := mi.get_active_material(s)
		_add_surface(mi.mesh, s, [mi.global_transform], [Color.WHITE], false, base, tags if s == 0 else null, _material(m), m)


func _add_multimesh(mmi: MultiMeshInstance3D) -> void:
	var mm := mmi.multimesh
	if mm.mesh == null:
		return
	var n := mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
	var xfs: Array[Transform3D] = []
	var cols: Array[Color] = []
	# Headless, the rendering server is a dummy and MultiMesh.get_instance_transform() answers identity: take a street
	# prop's pose from CityProps itself (the instance its slot maps to); any other multimesh whose instances all sit at
	# the origin is skipped (counted in `skipped`).
	var local: Array = []
	local.resize(n)
	var props := mmi.get_parent() as CityProps
	if props != null:
		var k := props._mms.find(mm)
		for it: Dictionary in props.items:
			var slot: Array = props._slot[int(it["id"])]
			if int(slot[0]) == k and int(slot[1]) < n:
				local[int(slot[1])] = props.transform_of(int(it["id"]))
	var at_origin := 0
	for i in n:
		var xf: Transform3D = local[i] if local[i] != null else mm.get_instance_transform(i)
		if local[i] == null and xf == Transform3D.IDENTITY:
			at_origin += 1
		xfs.append(mmi.global_transform * xf)
		cols.append(mm.get_instance_color(i) if mm.use_colors else Color.WHITE)
	if n > 1 and at_origin == n:
		skipped.append("%s (%d instances, no poses headless)" % [node_label(mmi), n])
		return
	var base := node_label(mmi)
	for s in mm.mesh.get_surface_count():
		var m := mmi.material_override if mmi.material_override != null else mm.mesh.surface_get_material(s)
		_add_surface(mm.mesh, s, xfs, cols, mm.use_colors, base, null, _material(m), m)


func _add_surface(mesh: Mesh, s: int, xfs: Array, tints: Array, tinted: bool, base: String, tags: Variant, mid: int, m: Material) -> void:
	var arr := mesh.surface_get_arrays(s)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var c: Variant = arr[Mesh.ARRAY_COLOR]
	var has_c := c is PackedColorArray and (c as PackedColorArray).size() == v.size()
	var idx: Variant = arr[Mesh.ARRAY_INDEX]
	var use_idx := idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty()
	var nt := ((idx as PackedInt32Array).size() if use_idx else v.size()) / 3
	var albedo := Color.WHITE
	if m is BaseMaterial3D:
		albedo = (m as BaseMaterial3D).albedo_color
	var starts := PackedInt32Array()
	var names := PackedStringArray()
	if tags is Array and (tags as Array).size() == 2:
		starts = tags[0]
		names = tags[1]
	var tag_ids := PackedInt32Array()
	for nm in names:
		tag_ids.append(_label(base + ":" + nm))
	var plain := _label(base)
	for xi in xfs.size():
		var xf: Transform3D = xfs[xi]
		var tint: Color = tints[xi]
		var ti := -1
		for t in nt:
			while ti + 1 < starts.size() and starts[ti + 1] <= t:
				ti += 1
			var i0 := (idx as PackedInt32Array)[t * 3] if use_idx else t * 3
			var i1 := (idx as PackedInt32Array)[t * 3 + 1] if use_idx else t * 3 + 1
			var i2 := (idx as PackedInt32Array)[t * 3 + 2] if use_idx else t * 3 + 2
			var a := xf * v[i0]
			var b := xf * v[i1]
			var e := xf * v[i2]
			var cr := (e - a).cross(b - a)      # Godot's front face is clockwise: this is the drawn normal
			var l := cr.length()
			if l < 1e-7:
				continue
			if region.is_valid() and not region.call((a + b + e) / 3.0):
				continue
			var n := cr / l
			var d := float(n.dot(a))
			var f := 0
			if n.dot(FLIP) < 0.0:
				n = -n
				d = -d
				f = 1
			pos.append(a)
			pos.append(b)
			pos.append(e)
			nrm.append(n)
			off.append(d)
			flp.append(f)
			var cc: Color = (c as PackedColorArray)[i0] if has_c else albedo
			if tinted:
				cc *= tint
			col.append(cc)
			mat.append(mid)
			src.append(tag_ids[ti] if ti >= 0 else plain)
			deck.append(int(deck_of.call((a + b + e) / 3.0)) if deck_of.is_valid() else 0)


# --- Finding pairs ---------------------------------------------------------------------------------------

## Runs the search over every triangle collected (or only those on deck `only_deck` >= 0).
func run(only_deck: int = -1) -> void:
	var t0 := Time.get_ticks_msec()
	groups.clear()
	hist.clear()
	pairs_tested = 0
	var fn := sin(deg_to_rad(NORMAL_TOL_DEG)) / NQ
	var fd := SEP_MAX / DQ
	var ent := PackedInt64Array()
	var n := src.size()
	for t in n:
		if only_deck >= 0 and deck[t] != only_deck:
			continue
		var nv := nrm[t]
		var q := [nv.x / NQ, nv.y / NQ, nv.z / NQ, off[t] / DQ]
		var opts := []
		for k in 4:
			var base := floori(q[k])
			var fr: float = q[k] - float(base)
			var tol := fn if k < 3 else fd
			var o := [base]
			if fr < tol:
				o.append(base - 1)
			if fr > 1.0 - tol:
				o.append(base + 1)
			opts.append(o)
		for x: int in opts[0]:
			for y: int in opts[1]:
				for z: int in opts[2]:
					for w: int in opts[3]:
						var home := 1 if (x == opts[0][0] and y == opts[1][0] and z == opts[2][0] and w == opts[3][0]) else 0
						var key := ((x + 32) & 63) | (((y + 32) & 63) << 6) | (((z + 32) & 63) << 12) | (((w + 8192) & 16383) << 18)
						ent.append((key << 22) | (t << 1) | home)
	ent.sort()
	ms["keys"] = float(Time.get_ticks_msec() - t0)
	var t1 := Time.get_ticks_msec()
	var i := 0
	var m := ent.size()
	while i < m:
		var key := ent[i] >> 22
		var j := i + 1
		while j < m and (ent[j] >> 22) == key:
			j += 1
		if j - i >= 2:
			_cell(ent, i, j)
		i = j
	ms["pairs"] = float(Time.get_ticks_msec() - t1)


func _cell(ent: PackedInt64Array, i0: int, i1: int) -> void:
	var tris := PackedInt32Array()
	var homes := PackedByteArray()
	var any_home := false
	for e in range(i0, i1):
		tris.append(int((ent[e] >> 1) & 0x1FFFFF))
		homes.append(int(ent[e] & 1))
		any_home = any_home or (ent[e] & 1) == 1
	if not any_home:
		return
	var m := tris.size()
	_cur = tris
	if m <= BRUTE:
		for a in m:
			if homes[a] == 0:
				continue
			for b in m:
				if tris[b] > tris[a]:
					_pair(tris[a], tris[b])
		return
	# A 2D grid in the plane of the cell.
	var nv := nrm[tris[0]]
	var u := nv.cross(Vector3.RIGHT if absf(nv.x) < 0.9 else Vector3.UP).normalized()
	var w := nv.cross(u)
	var lo := PackedVector2Array()
	var hi := PackedVector2Array()
	var grid := {}
	for a in m:
		var t := tris[a]
		var p0 := Vector2(u.dot(pos[t * 3]), w.dot(pos[t * 3]))
		var p1 := Vector2(u.dot(pos[t * 3 + 1]), w.dot(pos[t * 3 + 1]))
		var p2 := Vector2(u.dot(pos[t * 3 + 2]), w.dot(pos[t * 3 + 2]))
		var l := Vector2(minf(p0.x, minf(p1.x, p2.x)), minf(p0.y, minf(p1.y, p2.y)))
		var h := Vector2(maxf(p0.x, maxf(p1.x, p2.x)), maxf(p0.y, maxf(p1.y, p2.y)))
		lo.append(l)
		hi.append(h)
		for gx in range(floori(l.x / GRID), floori(h.x / GRID) + 1):
			for gy in range(floori(l.y / GRID), floori(h.y / GRID) + 1):
				var g := Vector2i(gx, gy)
				if not grid.has(g):
					grid[g] = PackedInt32Array()
				var arr: PackedInt32Array = grid[g]
				arr.append(a)
				grid[g] = arr
	var stamp := PackedInt32Array()
	stamp.resize(m)
	stamp.fill(-1)
	for a in m:
		if homes[a] == 0:
			continue
		var l := lo[a]
		var h := hi[a]
		for gx in range(floori(l.x / GRID), floori(h.x / GRID) + 1):
			for gy in range(floori(l.y / GRID), floori(h.y / GRID) + 1):
				var g := Vector2i(gx, gy)
				if not grid.has(g):
					continue
				for b: int in grid[g]:
					if stamp[b] == a or tris[b] <= tris[a]:
						continue
					stamp[b] = a
					if lo[b].x > h.x + 0.01 or hi[b].x < l.x - 0.01 or lo[b].y > h.y + 0.01 or hi[b].y < l.y - 0.01:
						continue
					_pair(tris[a], tris[b])


var _cos_tol := cos(deg_to_rad(NORMAL_TOL_DEG))
var _cur := PackedInt32Array()      ## the plane cell being searched


## True when a triangle of the current cell facing the other way covers `at` (within SEP_FINDING of its plane): the
## pair lies flat against the back of another surface, i.e. inside a solid (a facade slab's back face on its wall, a
## wall's buttress back face on the wall's plane). Seen only from inside a building or behind a boundary wall, where no
## camera goes (both are solid collision): kind "buried".
func _against_back(a: int, at: Vector3) -> bool:
	var na := nrm[a]
	var u := na.cross(Vector3.RIGHT if absf(na.x) < 0.9 else Vector3.UP).normalized()
	var w := na.cross(u)
	var p := Vector2(u.dot(at), w.dot(at))
	for c in _cur:
		if flp[c] == flp[a] or nrm[c].dot(na) < _cos_tol:
			continue
		if absf(nrm[c].dot(at) - off[c]) > SEP_FINDING:
			continue
		var c0 := Vector2(u.dot(pos[c * 3]), w.dot(pos[c * 3]))
		var c1 := Vector2(u.dot(pos[c * 3 + 1]), w.dot(pos[c * 3 + 1]))
		var c2 := Vector2(u.dot(pos[c * 3 + 2]), w.dot(pos[c * 3 + 2]))
		var d0 := (c1 - c0).cross(p - c0)
		var d1 := (c2 - c1).cross(p - c1)
		var d2 := (c0 - c2).cross(p - c2)
		if (d0 >= 0.0 and d1 >= 0.0 and d2 >= 0.0) or (d0 <= 0.0 and d1 <= 0.0 and d2 <= 0.0):
			return true
	return false


func _pair(a: int, b: int) -> void:
	var na := nrm[a]
	var nb := nrm[b]
	if na.dot(nb) < _cos_tol:
		return
	var da := off[a]
	var b0 := pos[b * 3]
	var b1 := pos[b * 3 + 1]
	var b2 := pos[b * 3 + 2]
	var e0 := na.dot(b0) - da
	var e1 := na.dot(b1) - da
	var e2 := na.dot(b2) - da
	if (e0 > SEP_MAX and e1 > SEP_MAX and e2 > SEP_MAX) or (e0 < -SEP_MAX and e1 < -SEP_MAX and e2 < -SEP_MAX):
		return
	pairs_tested += 1
	var u := na.cross(Vector3.RIGHT if absf(na.x) < 0.9 else Vector3.UP).normalized()
	var w := na.cross(u)
	var a0 := pos[a * 3]
	var a1 := pos[a * 3 + 1]
	var a2 := pos[a * 3 + 2]
	var pa := [Vector2(u.dot(a0), w.dot(a0)), Vector2(u.dot(a1), w.dot(a1)), Vector2(u.dot(a2), w.dot(a2))]
	if (pa[1] - pa[0]).cross(pa[2] - pa[0]) < 0.0:
		pa = [pa[0], pa[2], pa[1]]
	var poly := PackedVector2Array([Vector2(u.dot(b0), w.dot(b0)), Vector2(u.dot(b1), w.dot(b1)), Vector2(u.dot(b2), w.dot(b2))])
	for k in 3:
		poly = _clip(poly, pa[k], pa[(k + 1) % 3])
		if poly.size() < 3:
			return
	var area := 0.0
	var cx := 0.0
	var cy := 0.0
	for k in poly.size():
		var p: Vector2 = poly[k]
		var q: Vector2 = poly[(k + 1) % poly.size()]
		var cr := p.cross(q)
		area += cr
		cx += (p.x + q.x) * cr
		cy += (p.y + q.y) * cr
	area *= 0.5
	if absf(area) < AREA_EPS:
		return
	var c2 := Vector2(cx, cy) / (6.0 * area)
	var at := u * c2.x + w * c2.y + na * da
	var sep := absf(nb.dot(at) - off[b])
	if sep > SEP_MAX:
		return
	_record(a, b, absf(area), sep, at)


static func _clip(poly: PackedVector2Array, a: Vector2, b: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	var ab := b - a
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		var sp := ab.cross(p - a)
		var sq := ab.cross(q - a)
		if sp >= 0.0:
			out.append(p)
		if (sp >= 0.0) != (sq >= 0.0):
			out.append(p + (q - p) * (sp / (sp - sq)))
	return out


## kind: "finding" (same facing, different colour or material, closer than SEP_FINDING), "near" (same, SEP_FINDING to
## SEP_MAX: listed, not failed), "duplicate" (same facing, same colour and material), "back" (back to back).
func _record(a: int, b: int, area: float, sep: float, at: Vector3) -> void:
	var kind := "back"
	if flp[a] == flp[b]:
		if col[a].is_equal_approx(col[b]) and mat[a] == mat[b]:
			kind = "duplicate"
		else:
			kind = "finding" if sep < SEP_FINDING else "near"
			if kind == "finding" and _against_back(a, at):
				kind = "buried"
	if not hist.has(kind):
		hist[kind] = [[0, 0, 0, 0, 0], [0.0, 0.0, 0.0, 0.0, 0.0]]
	for k in SEP_BINS.size():
		if sep < SEP_BINS[k]:
			var hc: Array = hist[kind][0]
			var ha: Array = hist[kind][1]
			hc[k] = int(hc[k]) + 1
			ha[k] = float(ha[k]) + area
			break
	var la := labels[src[a]]
	var lb := labels[src[b]]
	var ca := _cname(col[a])
	var cb := _cname(col[b])
	if la > lb or (la == lb and ca > cb):
		var tl := la
		la = lb
		lb = tl
		var tc := ca
		ca = cb
		cb = tc
	if trace != "" and kind == "finding" and (la + "|" + lb).contains(trace) and _traced < 12:
		_traced += 1
		print("[zfight] trace %s|%s %s/%s sep %.4f area %.3f at %s  A %s n %s  B %s n %s" % [la, lb, ca, cb, sep, area, str(at),
				str([pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2]]), str(nrm[a] * (-1.0 if flp[a] else 1.0)),
				str([pos[b * 3], pos[b * 3 + 1], pos[b * 3 + 2]]), str(nrm[b] * (-1.0 if flp[b] else 1.0))])
	var key := "%s|%s|%s" % [kind, la, lb]
	if not groups.has(key):
		groups[key] = {"kind": kind, "a": la, "b": lb, "count": 0, "area": 0.0, "sep_min": INF, "sep_max": 0.0, "ex_area": -1.0,
				"ex_at": Vector3.ZERO, "cols": {}, "decks": {}}
	var g: Dictionary = groups[key]
	g["count"] = int(g["count"]) + 1
	g["area"] = float(g["area"]) + area
	g["sep_min"] = minf(float(g["sep_min"]), sep)
	g["sep_max"] = maxf(float(g["sep_max"]), sep)
	(g["cols"] as Dictionary)["%s/%s" % [ca, cb]] = true
	(g["decks"] as Dictionary)[deck[a]] = true
	if area > float(g["ex_area"]):
		g["ex_area"] = area
		g["ex_at"] = at
		g["ex_sep"] = sep


func _cname(c: Color) -> String:
	return str(_names.get(c.to_html(false), "#" + c.to_html(false)))


# --- Results ---------------------------------------------------------------------------------------------

## Groups of one kind, largest total area first.
func sorted_groups(kind: String) -> Array:
	var out := []
	for k: String in groups:
		if groups[k]["kind"] == kind:
			out.append(groups[k])
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["area"]) > float(q["area"]))
	return out


func total(kind: String) -> Vector2:
	var c := 0
	var a := 0.0
	for g: Dictionary in sorted_groups(kind):
		c += int(g["count"])
		a += float(g["area"])
	return Vector2(c, a)


func describe(g: Dictionary) -> String:
	var at: Vector3 = g["ex_at"]
	var where := "world (%.1f, %.1f, %.1f)" % [at.x, at.y, at.z]
	if arc_of.is_valid():
		var ac: Dictionary = arc_of.call(at)
		where += " deck %d arc x %.1f s %.1f h %.2f" % [int(ac["deck"]), float(ac["x"]), float(ac["s"]), float(ac["h"])]
	return "%-9s %6d pairs %9.2f m2  sep %.4f-%.4f m  %s  <->  %s  [%s]  e.g. %s" % [g["kind"], int(g["count"]), float(g["area"]),
			float(g["sep_min"]), float(g["sep_max"]), g["a"], g["b"], ", ".join(PackedStringArray((g["cols"] as Dictionary).keys())), where]


func report(limit: int = 40) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("triangles %d, pairs tested %d, ms %s" % [tri_count(), pairs_tested, str(ms)])
	if not skipped.is_empty():
		out.append("skipped (no poses headless): " + ", ".join(PackedStringArray(skipped)))
	for kind: String in ["finding", "near", "buried", "duplicate", "back"]:
		var tt := total(kind)
		out.append("== %s: %d pairs, %.2f m2, %d groups" % [kind, int(tt.x), tt.y, sorted_groups(kind).size()])
		if hist.has(kind):
			var line := "   separation histogram:"
			for k in SEP_BINS.size():
				line += "  %s %d (%.1f m2)" % [SEP_NAMES[k], int(hist[kind][0][k]), float(hist[kind][1][k])]
			out.append(line)
		var shown := 0
		for g: Dictionary in sorted_groups(kind):
			if shown >= limit:
				break
			out.append("   " + describe(g))
			shown += 1
	return out
