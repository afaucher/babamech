class_name MechDiagram
extends Control
## The HUD's mech damage diagram, drawn from the REAL mech (docs/design/hud.md; options round
## docs/design/hud/grid_hud_diagram_r1.png). The HUD uses pick 3, view "front" / style "schematic" (MechHud.status_diagram);
## the other views and styles stay for the options grid and tests.
##
##   view   "front"  head-on, a little from above, mirrored so the mech's left is on the left (the pilot's frame, like
##                   the weapon rows' L / R)
##          "side"   right side, turned 20 degrees toward the front so the far-side parts peek out, legs mid-stride
##          "three"  three-quarter front view from above, legs mid-stride
##   style  "geometric"  one simple polygon (at most 6-8 corners) per part
##          "traced"     the silhouette of every component: the union of the convex hulls of its actual meshes
##          "schematic"  traced outline plus every mesh's plate seams, joint markers, the body axis and slot numbers
##
## Geometry: a MechModel (low-poly art, the given pilot head and chassis: `chassis`, the Strider by default) is built off-tree once per view and loadout, every mesh's
## vertices are projected into 2D and grouped by component (head, torso, leg_l, leg_r, one per hardpoint id), then cached.
## Each component is a separate zone tinted by its health (cyan > 2/3, amber > 1/3, red, destroyed = grey with a red
## cross). Everything stays inside the heat arc and above the panel's state text (`area()`).
##
## Use: add as a full-rect child of the status panel; set `view`, `style`, `mounted` ({hardpoint id: weapon id, "" =
## empty}) and `health` ({component id: 0..1}, missing = 1). Cosmetic: no gameplay state (net: LOCAL / presentation).

const VIEWS := ["front", "side", "three"]
const STYLES := ["geometric", "traced", "schematic"]
const VIEW_LABEL := {"front": "front", "side": "side profile", "three": "3/4"}
const STYLE_LABEL := {"geometric": "geometric", "traced": "traced", "schematic": "schematic"}
const BASE_IDS := ["head", "torso", "leg_l", "leg_r"]
const HEAD := "chicken"
const CHASSIS := "strider"   ## the default chassis (`chassis` picks the drawn one: its own parts, components, hardpoints)

## Camera per view: yaw (deg, from the mech's right side toward its front; 90 = head-on), elevation (deg), mirror
## (screen x flipped so the mech's left is on the left), stride (legs posed mid-stride so both read).
const CAMS := {
	"front": {"yaw": 90.0, "elev": 12.0, "mirror": true, "stride": false},
	"side": {"yaw": 14.0, "elev": 8.0, "mirror": false, "stride": true},
	"three": {"yaw": 50.0, "elev": 20.0, "mirror": false, "stride": true},
}
## Room left below the diagram for the state line (THRUST ...) and the heat readout (MechHud._draw_status).
const TEXT_TOP_FROM_BOTTOM := 64.0
const ARC_STROKE := 9.0

const DEMO_LOADOUT := {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "missiles",
	"back": "mortar"}
const DEMO_HEALTH := {"leg_l": 0.45, "shoulder_r": 0.0}

const BASE := Color(0.03, 0.09, 0.12, 0.92)

var view := "front":
	set(v):
		view = v if v in VIEWS else "front"
		queue_redraw()
var style := "traced":
	set(v):
		style = v if v in STYLES else "traced"
		queue_redraw()
var mounted: Dictionary = DEMO_LOADOUT.duplicate():
	set(v):
		mounted = v
		queue_redraw()
var health: Dictionary = {}:
	set(v):
		health = v
		queue_redraw()
var head := HEAD:                  ## the pilot head id (traced from its mesh)
	set(v):
		head = v if MechCatalog.HEADS.has(v) else HEAD
		queue_redraw()
var slot_of: Dictionary = {}       ## {hardpoint id: slot number} for the badges (the weapon rows' numbers)
var chassis := CHASSIS:            ## the chassis drawn (MechCatalog id): the local pilot's
	set(v):
		chassis = v if MechCatalog.CHASSIS.has(v) else CHASSIS
		queue_redraw()

static var _lay := {}       ## layout() results by view, style, loadout and panel size
static var _geo := {}       ## "view|loadout" -> projected geometry (model units, y down), see _build()
static var _font: Font


func _init() -> void:
	name = "MechDiagram"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	paint(self, size, view, style, mounted, health, head, slot_of, chassis)


# --- Layout --------------------------------------------------------------------------------------------------------

## The heat arc's centre and radius for a status panel of `panel` size (same numbers as MechHud._draw_status).
static func arc(panel: Vector2) -> Dictionary:
	return {"centre": Vector2(panel.x * 0.5, panel.y * 0.47), "r": minf(panel.x, panel.y) * 0.44}


## Where the diagram may draw: inside the heat arc's inner edge, above the state text.
static func area(panel: Vector2) -> Rect2:
	var a := arc(panel)
	var c: Vector2 = a["centre"]
	var ri := float(a["r"]) - ARC_STROKE * 0.5 - 4.0
	var top := c.y - ri
	var bottom := panel.y - TEXT_TOP_FROM_BOTTOM
	return Rect2(c.x - ri, top, ri * 2.0, bottom - top)


## Every component id the diagram shows for a loadout: head, torso, both legs and every hardpoint of the chassis.
static func component_ids(_loadout: Dictionary = {}, chassis_: String = CHASSIS) -> Array[String]:
	var out: Array[String] = []
	out.assign(BASE_IDS)
	for hp: Dictionary in MechCatalog.chassis(chassis_)["hardpoints"]:
		out.append(str(hp["id"]))
	return out


## The zones in panel pixels: {component id: Array[PackedVector2Array]} (what takes that component's colour).
static func zones(view_: String, style_: String, loadout: Dictionary, panel: Vector2, head_: String = HEAD,
		chassis_: String = CHASSIS) -> Dictionary:
	var lay := layout(view_, style_, loadout, panel, head_, chassis_)
	var out := {}
	for it: Dictionary in lay["items"]:
		var id := str(it["id"])
		if not out.has(id):
			out[id] = []
		(out[id] as Array).append_array(it["polys"])
	return out


## The drawable items, fitted into the panel: {items: [{id, polys, seams, depth}], joints: [{id, pos}], axis: [a, b],
## ground: y, tags: {hardpoint id: pos}, xf: Transform2D}.
static func layout(view_: String, style_: String, loadout: Dictionary, panel: Vector2, head_: String = HEAD,
		chassis_: String = CHASSIS) -> Dictionary:
	var key := "%s|%s|%s|%s|%s|%s" % [view_, style_, str(MechCatalog.sanitize_loadout(chassis_, loadout)), str(panel), head_,
		chassis_]
	if not _lay.has(key):
		_lay[key] = _layout(view_, style_, loadout, panel, head_, chassis_)
	return _lay[key]


static func _layout(view_: String, style_: String, loadout: Dictionary, panel: Vector2, head_: String,
		chassis_: String = CHASSIS) -> Dictionary:
	var g := geometry(view_, loadout, head_, chassis_)
	var items: Array = []
	match style_:
		"geometric":
			for grp: Dictionary in g["groups"]:
				if grp["minor"]:
					continue
				var n := 8 if grp["id"] == "head" else (5 if str(grp["name"]).begins_with("foot") else 6)
				items.append({"id": grp["id"], "polys": [simplify(grp["hull"], n)], "seams": [], "depth": grp["depth"],
					"weapon": grp["weapon"]})
		_:
			for comp: Dictionary in g["comps"]:
				var seams: Array = comp["hulls"] if style_ == "schematic" and comp["id"] != "head" else []
				items.append({"id": comp["id"], "polys": comp["union"], "seams": seams,
					"depth": comp["depth"], "weapon": true})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["depth"]) > float(b["depth"]))
	# Fit: the bounding box into area(), then shrink until every point is inside the arc's inner circle.
	var pts := PackedVector2Array()
	for it: Dictionary in items:
		for p: PackedVector2Array in it["polys"]:
			pts.append_array(p)
	var bb := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bb = bb.expand(p)
	var ar := area(panel)
	var a := arc(panel)
	var ri := float(a["r"]) - ARC_STROKE * 0.5 - 4.0
	var s := minf(ar.size.x / bb.size.x, ar.size.y / bb.size.y)
	var xf := Transform2D()
	for _i in 12:
		var off := ar.get_center() - bb.get_center() * s
		xf = Transform2D(0.0, Vector2(s, s), 0.0, off)
		var worst := 0.0
		for p in pts:
			worst = maxf(worst, ((xf * p) - (a["centre"] as Vector2)).length() / ri)
		if worst <= 1.0:
			break
		s /= worst * 1.01
	var out_items: Array = []
	for it: Dictionary in items:
		var polys: Array = []
		for p: PackedVector2Array in it["polys"]:
			polys.append(xf * p)
		var seams: Array = []
		for p: PackedVector2Array in it["seams"]:
			seams.append(xf * p)
		out_items.append({"id": it["id"], "polys": polys, "seams": seams, "depth": it["depth"], "weapon": it["weapon"]})
	var joints: Array = []
	for j: Dictionary in g["joints"]:
		joints.append({"id": j["id"], "pos": xf * (j["pos"] as Vector2), "kind": j["kind"]})
	var tags := {}
	for k: String in g["tags"]:
		tags[k] = xf * (g["tags"][k] as Vector2)
	var eyes: Array = []
	for e: Vector2 in g["eyes"]:
		eyes.append(xf * e)
	var badges := _badges(out_items, tags, [xf * (g["axis"][0] as Vector2), xf * (g["axis"][1] as Vector2)], a["centre"], ri,
		area(panel).end.y)
	return {"items": out_items, "joints": joints, "axis": [xf * (g["axis"][0] as Vector2), xf * (g["axis"][1] as Vector2)],
		"ground": (xf * Vector2(0, float(g["ground"]))).y, "tags": tags, "xf": xf, "scale": s, "ghosts": _ghosts(out_items), "eyes": eyes, "badges": badges,
		"area": area(panel), "arc_c": a["centre"], "arc_ri": ri}


## Where each hardpoint's slot badge goes: out from the body axis past its mount, clear of the pilot's head, the other
## badges and the heat arc (the first free spot of a small fan of candidates). {hardpoint id: centre}.
static func _badges(items: Array, tags: Dictionary, axis: Array, arc_c: Vector2, ri: float, bottom: float) -> Dictionary:
	const R := 6.0
	var head: Array = []
	for it: Dictionary in items:
		if it["id"] == "head":
			head.append_array(it["polys"])
	var out := {}
	var placed: Array = []
	for hid: String in tags:
		var tp: Vector2 = tags[hid]
		var dir := (tp - (axis[0] as Vector2).lerp(axis[1], 0.45)).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.UP
		var best := tp + dir * 13.0
		var found := false
		for dist: float in [13.0, 17.0, 22.0, 28.0]:
			for deg: float in [0.0, 30.0, -30.0, 60.0, -60.0, 90.0, -90.0]:
				var p := tp + dir.rotated(deg_to_rad(deg)) * dist
				if p.distance_to(arc_c) > ri - R - 1.0 or p.y > bottom - R:
					continue
				var ok := true
				for q: Vector2 in placed:
					ok = ok and p.distance_to(q) > R * 2.2
				for hp_: PackedVector2Array in head:
					for k in 9:
						var probe := p if k == 8 else p + Vector2.RIGHT.rotated(TAU * k / 8.0) * (R + 1.0)
						ok = ok and not Geometry2D.is_point_in_polygon(probe, hp_)
				if ok:
					best = p
					found = true
					break
			if found:
				break
		out[hid] = best
		placed.append(best)
	return out


## Hardpoints that nearer parts hide for the most part (the back mortar seen from the front, a far-side weapon seen
## from the side): {id: true}. paint() redraws them on top as a dashed outline so every zone stays readable.
static func _ghosts(items: Array) -> Dictionary:
	var total := {}
	var seen := {}
	for i in items.size():
		var it: Dictionary = items[i]
		var id := str(it["id"])
		if id in BASE_IDS:
			continue
		for p: PackedVector2Array in it["polys"]:
			var vis: Array = [p]
			for k in range(i + 1, items.size()):
				for q: PackedVector2Array in (items[k] as Dictionary)["polys"]:
					var nv: Array = []
					for v: PackedVector2Array in vis:
						nv.append_array(Geometry2D.clip_polygons(v, q))
					vis = nv
			total[id] = float(total.get(id, 0.0)) + absf(_signed_area(p))
			var a := 0.0
			for v: PackedVector2Array in vis:
				a += _signed_area(v) * (-1.0 if Geometry2D.is_polygon_clockwise(v) != Geometry2D.is_polygon_clockwise(p) else 1.0)
			seen[id] = float(seen.get(id, 0.0)) + absf(a)
	var out := {}
	for id: String in total:
		if float(seen[id]) < 0.5 * float(total[id]):
			out[id] = true
	return out


static func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5


# --- Geometry from the real model ------------------------------------------------------------------------------------

## Projected geometry for a view and loadout (model units, screen axes: x right, y down), cached:
##   groups: [{id, name, hull, depth, minor, weapon}]   one per part (a mesh or a small subtree: a foot, a weapon)
##   comps:  [{id, union: [poly], hulls: [poly], depth}] per component: the union of its meshes' hulls, and the hulls
##   joints: [{id, kind, pos}]  hip / knee / ankle / foot per leg;  axis: [top, bottom];  ground: y;  tags: {hp: pos}
static func geometry(view_: String, loadout: Dictionary, head_: String = HEAD, chassis_: String = CHASSIS) -> Dictionary:
	var key := "%s|%s|%s|%s" % [view_, str(MechCatalog.sanitize_loadout(chassis_, loadout)), head_, chassis_]
	if not _geo.has(key):
		_geo[key] = _build(view_, loadout, head_, chassis_)
	return _geo[key]


static func _basis(view_: String) -> Array:
	var cam: Dictionary = CAMS.get(view_, CAMS["front"])
	var yaw := deg_to_rad(float(cam["yaw"]))
	var el := deg_to_rad(float(cam["elev"]))
	# Camera direction (from the mech toward the camera): yaw 0 = on the mech's right (+X), 90 = in front (-Z).
	var d := Vector3(cos(el) * cos(yaw), sin(el), -cos(el) * sin(yaw))
	var f := -d
	var r := f.cross(Vector3.UP).normalized()
	var u := r.cross(f).normalized()
	if bool(cam["mirror"]):
		r = -r
	return [r, u, f]


static func _build(view_: String, loadout: Dictionary, head_: String, chassis_: String = CHASSIS) -> Dictionary:
	var m := MechModel.new()
	m.art = "lowpoly"
	m.configure(head_, chassis_, loadout)
	if bool((CAMS.get(view_, CAMS["front"]) as Dictionary)["stride"]):
		m.params["gait"] = 1.0
		m._process(0.25)   # a quarter cycle: one leg forward, the other back, neither lifted
	var b := _basis(view_)
	var r: Vector3 = b[0]
	var u: Vector3 = b[1]
	var f: Vector3 = b[2]
	var proj := func(p: Vector3) -> Vector2: return Vector2(p.dot(r), -p.dot(u))
	var meshes: Array = []   # {id, group, pts, depth}
	_walk(m, Transform3D.IDENTITY, "torso", "", meshes, r, u, f)
	# Groups (parts) and components.
	var groups := {}
	var order: Array = []
	var comps := {}
	for me: Dictionary in meshes:
		var gk := "%s/%s" % [me["id"], me["group"]]
		if not groups.has(gk):
			groups[gk] = {"id": me["id"], "name": me["group"], "pts": PackedVector2Array(), "dsum": 0.0, "n": 0}
			order.append(gk)
		var grp: Dictionary = groups[gk]
		grp["pts"] = (grp["pts"] as PackedVector2Array) + (me["pts"] as PackedVector2Array)
		grp["dsum"] = float(grp["dsum"]) + float(me["depth"])
		grp["n"] = int(grp["n"]) + 1
		var hull := _hull(me["pts"])
		if hull.size() < 3:
			continue
		if not comps.has(me["id"]):
			comps[me["id"]] = {"id": me["id"], "hulls": [], "dsum": 0.0, "n": 0}
		var c: Dictionary = comps[me["id"]]
		(c["hulls"] as Array).append(hull)
		c["dsum"] = float(c["dsum"]) + float(me["depth"])
		c["n"] = int(c["n"]) + 1
	var out_groups: Array = []
	for gk: String in order:
		var grp: Dictionary = groups[gk]
		var hull := _hull(grp["pts"])
		if hull.size() < 3:
			continue
		var nm := str(grp["name"])
		var minor := nm == "eye" or nm.begins_with("hip_") or nm.begins_with("knee_") or nm.begins_with("ankle_") \
			or nm.begins_with("socket_") or nm == "Pelvis" or nm == "Hatch"
		out_groups.append({"id": grp["id"], "name": nm, "hull": hull, "depth": float(grp["dsum"]) / int(grp["n"]),
			"minor": minor, "weapon": not nm.ends_with(":mount")})
	# A hardpoint with no hardware and no weapon (an empty back mount) still gets a zone: a small square at its mount.
	for hp: Dictionary in MechCatalog.chassis(chassis_)["hardpoints"]:
		var hid := str(hp["id"])
		if comps.has(hid):
			continue
		var node := m.find_child("HP_" + hid, true, false) as Node3D
		if node == null:
			continue
		var t := Transform3D.IDENTITY
		var walker: Node = node
		while walker != null and walker != m:
			if walker is Node3D:
				t = (walker as Node3D).transform * t
			walker = walker.get_parent()
		var cpos: Vector2 = proj.call(t.origin)
		var e := 0.16
		var sq := PackedVector2Array([cpos + Vector2(-e, -e), cpos + Vector2(e, -e), cpos + Vector2(e, e), cpos + Vector2(-e, e)])
		var dep := t.origin.dot(f)
		comps[hid] = {"id": hid, "hulls": [sq], "dsum": dep, "n": 1}
		out_groups.append({"id": hid, "name": hid + ":mount", "hull": sq, "depth": dep, "minor": false, "weapon": false})
	var out_comps: Array = []
	for id: String in comps:
		var c: Dictionary = comps[id]
		out_comps.append({"id": id, "union": _union(c["hulls"]), "hulls": c["hulls"], "depth": float(c["dsum"]) / int(c["n"])})
	# Joints, axis, ground, hardpoint tags.
	var joints: Array = []
	for i in 2:
		var lp := m.leg_points(i)
		var id := "leg_l" if i == 0 else "leg_r"
		for k: String in ["hip", "knee", "ankle", "foot"]:
			if lp.has(k):
				joints.append({"id": id, "kind": k, "pos": proj.call(lp[k] as Vector3)})
	var top := m.hip_height() + 3.2
	var tags := {}
	for hp: Dictionary in MechCatalog.chassis(chassis_)["hardpoints"]:
		var hid := str(hp["id"])
		var pts := PackedVector2Array()
		for grp: Dictionary in out_groups:
			if grp["id"] == hid:
				pts.append_array(grp["hull"])
		if not pts.is_empty():
			var bb := Rect2(pts[0], Vector2.ZERO)
			for p in pts:
				bb = bb.expand(p)
			tags[hid] = bb.get_center()
	var eyes: Array = []   # the pilot's pupils: a face cue on the head's clean silhouette
	for me: Dictionary in meshes:
		if me["group"] == "eye":
			var cen := Vector2.ZERO
			for q: Vector2 in me["pts"]:
				cen += q
			eyes.append(cen / (me["pts"] as PackedVector2Array).size())
	m.free()
	return {"eyes": eyes, "groups": out_groups, "comps": out_comps, "joints": joints,
		"axis": [proj.call(Vector3(0, top, 0)), proj.call(Vector3.ZERO)], "ground": proj.call(Vector3.ZERO).y, "tags": tags}


## Collect every visible mesh under `n` (model space via `xf`), projected, tagged with its component and part group.
static func _walk(n: Node, xf: Transform3D, comp: String, group: String, out: Array, r: Vector3, u: Vector3, f: Vector3) -> void:
	var t := xf
	var nm := str(n.name)
	if n is Node3D:
		if not (n as Node3D).visible:
			return
		if n.get_parent() != null:
			t = xf * (n as Node3D).transform
	if nm.begins_with("Head_"):
		comp = "head"
		group = "head"
	elif comp == "head" and nm.begins_with("Pupil"):
		group = "eye"
	elif nm.begins_with("HP_"):
		comp = nm.substr(3)
		group = comp
	elif comp.begins_with("side_") or comp.begins_with("shoulder_") or comp.begins_with("back"):   # back, back_l, back_r
		if group == comp:
			group = comp + (":mount" if nm == "Mount" else ":weapon")
	elif comp != "head":
		for part: String in ["thigh_", "shin_", "tarsus_", "hip_", "knee_", "ankle_", "foot_", "socket_"]:
			if nm.begins_with(part) and (nm.ends_with("_l") or nm.ends_with("_r")) and group == "":
				comp = "leg_" + nm.right(1)
				group = nm
		if comp == "torso" and group == "" and nm in ["Torso", "Pelvis", "Nose", "Hatch", "BackPlate", "ShoulderPod_l", "ShoulderPod_r",
				"Pod_l", "Pod_r"]:
			group = nm
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var faces := (n as MeshInstance3D).mesh.get_faces()
		var seen := {}
		var pts := PackedVector2Array()
		var dsum := 0.0
		for v in faces:
			var p := t * v
			var q := Vector2(p.dot(r), -p.dot(u))
			var k := Vector2i(roundi(q.x * 400.0), roundi(q.y * 400.0))
			if seen.has(k):
				continue
			seen[k] = true
			pts.append(q)
			dsum += p.dot(f)
		if pts.size() >= 3:
			out.append({"id": comp, "group": group if group != "" else comp, "pts": pts, "depth": dsum / pts.size()})
	for c in n.get_children():
		_walk(c, t, comp, group, out, r, u, f)


static func _hull(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return PackedVector2Array()
	var h := Geometry2D.convex_hull(pts)
	if h.size() > 1 and h[0].is_equal_approx(h[h.size() - 1]):
		h.remove_at(h.size() - 1)
	return h


## The union of convex polygons (outer outlines only; holes dropped).
static func _union(polys: Array) -> Array:
	var acc: Array = []
	for p: PackedVector2Array in polys:
		var cur := p
		var i := 0
		while i < acc.size():
			var merged := Geometry2D.merge_polygons(cur, acc[i])
			var outer: Array = []
			for q: PackedVector2Array in merged:
				if not Geometry2D.is_polygon_clockwise(q):
					outer.append(q)
			if outer.size() == 1 and merged.size() >= 1 and _overlaps(cur, acc[i]):
				cur = outer[0]
				acc.remove_at(i)
				i = 0
				continue
			i += 1
		acc.append(cur)
	return acc


static func _overlaps(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	return not Geometry2D.intersect_polygons(a, b).is_empty()


## Reduce a convex polygon to at most `n` corners by dropping the corner whose triangle is smallest (Visvalingam).
static func simplify(poly: PackedVector2Array, n: int) -> PackedVector2Array:
	var p := poly.duplicate()
	while p.size() > n:
		var best := 0
		var best_a := INF
		for i in p.size():
			var a := p[(i - 1 + p.size()) % p.size()]
			var b := p[i]
			var c := p[(i + 1) % p.size()]
			var area_ := absf((b - a).cross(c - a))
			if area_ < best_a:
				best_a = area_
				best = i
		p.remove_at(best)
	return p


# --- Drawing -------------------------------------------------------------------------------------------------------

static func hp_col(v: float) -> Color:
	if v <= 0.0:
		return MechHud.GREY
	if v < 0.34:
		return MechHud.RED
	if v < 0.67:
		return MechHud.AMBER
	return MechHud.CYAN


## Draw the diagram into canvas item `c` for a status panel of `panel` size.
## `head_`: the pilot head id (its silhouette is traced); `slot_of`: {hardpoint id: slot number} for the badges (the
## weapon rows' numbers; default: the chassis' hardpoint order, 1-n).
static func paint(c: CanvasItem, panel: Vector2, view_: String, style_: String, loadout: Dictionary, hp: Dictionary,
		head_: String = HEAD, slot_of: Dictionary = {}, chassis_: String = CHASSIS) -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var lay := layout(view_, style_, loadout, panel, head_, chassis_)
	var schematic := style_ == "schematic"
	var geometric := style_ == "geometric"
	# Ground line and body axis (schematic: dashed construction lines; others: a faint ground tick).
	var axis: Array = lay["axis"]
	var gy := float(lay["ground"])
	var cx := (axis[1] as Vector2).x
	if schematic:
		c.draw_dashed_line(axis[0], axis[1], Color(MechHud.CYAN, 0.28), 1.0, 3.0)
		c.draw_line(Vector2(cx - 62, gy + 2), Vector2(cx + 62, gy + 2), Color(MechHud.CYAN, 0.4), 1.0)
		for k in 7:
			var x := cx - 60.0 + k * 20.0
			c.draw_line(Vector2(x, gy + 2), Vector2(x - 4, gy + 6), Color(MechHud.CYAN, 0.3), 1.0)
	else:
		c.draw_line(Vector2(cx - 48, gy + 2), Vector2(cx + 48, gy + 2), Color(MechHud.CYAN, 0.25), 1.0)
	for it: Dictionary in lay["items"]:
		var id := str(it["id"])
		var is_hp := not (id in BASE_IDS)
		var empty := is_hp and str(loadout.get(id, "")) == ""
		var v := float(hp.get(id, 1.0))
		var col := hp_col(v)
		if empty:
			# An empty hardpoint: only its mount hardware, as a dim outline (the weapon part of the zone is absent).
			for p: PackedVector2Array in it["polys"]:
				c.draw_colored_polygon(p, BASE)
				_outline(c, p, Color(MechHud.DIM, 0.6), 1.0, true)
			continue
		var tint := 0.2 if geometric else (0.26 if not schematic else 0.12)
		for p: PackedVector2Array in it["polys"]:
			if p.size() < 3:
				continue
			c.draw_colored_polygon(p, BASE)
			c.draw_colored_polygon(p, Color(col, tint if v > 0.0 else 0.12))
		for p: PackedVector2Array in it["seams"]:
			_outline(c, p, Color(col, 0.42), 1.0)
		var w := (1.5 if not schematic else 1.3) + (0.6 if id == "head" else 0.0)   # the pilot's head reads first
		for p: PackedVector2Array in it["polys"]:
			if p.size() >= 3:
				_outline(c, p, Color(BASE, 1.0), w + 2.5)   # a dark gap where this part covers the one behind it
				_outline(c, p, MechHud.RED if v <= 0.0 else col, w)
	# Hidden hardpoints: their outline again on top, dashed, so the zone reads through what covers it (never across the
	# pilot's head: the head reads first).
	var head_polys: Array = []
	for it: Dictionary in lay["items"]:
		if it["id"] == "head":
			head_polys.append_array(it["polys"])
	for it: Dictionary in lay["items"]:
		var gid := str(it["id"])
		if not (lay["ghosts"] as Dictionary).has(gid) or str(loadout.get(gid, "")) == "":
			continue
		var gcol := Color(MechHud.RED if float(hp.get(gid, 1.0)) <= 0.0 else hp_col(float(hp.get(gid, 1.0))), 0.8)
		for p: PackedVector2Array in it["polys"]:
			var line := p.duplicate()
			line.append(p[0])
			var parts: Array = [line]
			for hpoly: PackedVector2Array in head_polys:
				var nxt: Array = []
				for l: PackedVector2Array in parts:
					nxt.append_array(Geometry2D.clip_polyline_with_polygon(l, hpoly))
				parts = nxt
			for l: PackedVector2Array in parts:
				for i in l.size() - 1:
					c.draw_dashed_line(l[i], l[i + 1], gcol, 1.0, 2.0)
	# The pilot's eyes on the head (schematic and traced): the face cue that makes it read as a head, not a turret.
	if not geometric:
		var hc := hp_col(float(hp.get("head", 1.0)))
		for e: Vector2 in lay["eyes"]:
			c.draw_circle(e, 1.7, hc)
	# Destroyed components: a red cross over the zone (drawn on top of everything).
	var zs := {}
	for it: Dictionary in lay["items"]:
		var id := str(it["id"])
		if not zs.has(id):
			zs[id] = []
		(zs[id] as Array).append_array(it["polys"])
	for id: String in zs:
		if float(hp.get(id, 1.0)) > 0.0 or (not (id in BASE_IDS) and str(loadout.get(id, "")) == ""):
			continue
		var bb := _bounds(zs[id])
		bb = bb.grow(1.0)
		c.draw_line(bb.position, bb.end, MechHud.RED, 1.8, true)
		c.draw_line(Vector2(bb.end.x, bb.position.y), Vector2(bb.position.x, bb.end.y), MechHud.RED, 1.8, true)
	if schematic:
		# Joint markers on the legs, slot numbers by the hardpoints.
		for j: Dictionary in lay["joints"]:
			var jc := hp_col(float(hp.get(str(j["id"]), 1.0)))
			var pos: Vector2 = j["pos"]
			if str(j["kind"]) == "foot":
				c.draw_line(pos + Vector2(-3, 0), pos + Vector2(3, 0), jc, 1.0)
				continue
			c.draw_circle(pos, 2.6, BASE)
			c.draw_arc(pos, 2.6, 0.0, TAU, 12, jc, 1.0, true)
			c.draw_circle(pos, 0.9, jc)
		var slot := 1
		for hpd: Dictionary in MechCatalog.chassis(chassis_)["hardpoints"]:
			var hid := str(hpd["id"])
			var num := int(slot_of.get(hid, slot))
			if (lay["badges"] as Dictionary).has(hid):
				var tp: Vector2 = lay["tags"][hid]
				var lp: Vector2 = lay["badges"][hid]
				if (lay["ghosts"] as Dictionary).has(hid) and lp.distance_to(tp) > 9.0:   # a leader to a hidden mount
					c.draw_dashed_line(tp + (lp - tp).normalized() * 2.0, lp - (lp - tp).normalized() * 6.0,
						Color(MechHud.CYAN, 0.45), 1.0, 2.0)
				var hv := float(hp.get(hid, 1.0))
				var tc := (MechHud.RED if hv <= 0.0 else hp_col(hv)) if str(loadout.get(hid, "")) != "" else MechHud.DIM
				c.draw_circle(lp, 6.0, Color(BASE, 1.0))
				c.draw_arc(lp, 6.0, 0.0, TAU, 16, Color(tc, 0.8), 1.0, true)
				c.draw_string(_font, lp + Vector2(-6, 3.5), str(num), HORIZONTAL_ALIGNMENT_CENTER, 12, 10, tc)
			slot += 1


static func _outline(c: CanvasItem, p: PackedVector2Array, col: Color, w: float, dashed: bool = false) -> void:
	if p.size() < 2:
		return
	if dashed:
		for i in p.size():
			c.draw_dashed_line(p[i], p[(i + 1) % p.size()], col, w, 2.0)
		return
	var closed := p.duplicate()
	closed.append(p[0])
	c.draw_polyline(closed, col, w, true)


static func _bounds(polys: Array) -> Rect2:
	var bb := Rect2()
	var first := true
	for p: PackedVector2Array in polys:
		for q in p:
			if first:
				bb = Rect2(q, Vector2.ZERO)
				first = false
			else:
				bb = bb.expand(q)
	return bb


# --- The status panel frame (for previews and the visual test) -------------------------------------------------------

## The status panel without its diagram, as MechHud._draw_status draws it: glass, heat arc, ticks, HEAT n%, heat / cap
## and the state line. Lets the options be judged inside the real frame before the HUD adopts one.
static func paint_frame(c: CanvasItem, panel: Vector2, heat_f: float, heat_cap: float, state: String) -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	MechHud.draw_glass(c as Control, Rect2(Vector2.ZERO, panel))
	var a := arc(panel)
	var centre: Vector2 = a["centre"]
	var r := float(a["r"])
	var a0 := deg_to_rad(135.0)
	var a1 := deg_to_rad(405.0)
	c.draw_arc(centre, r, a0, a1, 64, Color(MechHud.CYAN, 0.18), ARC_STROKE, true)
	var hc := MechHud.CYAN if heat_f < 0.6 else (MechHud.AMBER if heat_f < 0.85 else MechHud.RED)
	c.draw_arc(centre, r, a0, lerpf(a0, a1, heat_f), 64, hc, ARC_STROKE, true)
	for k in 11:
		var ang := lerpf(a0, a1, float(k) / 10.0)
		var dir := Vector2(cos(ang), sin(ang))
		c.draw_line(centre + dir * (r + 7.0), centre + dir * (r + 11.0 + (3.0 if k % 5 == 0 else 0.0)), Color(MechHud.CYAN, 0.6), 1.2)
	c.draw_string(_font, Vector2(0, panel.y - 30), "HEAT %d%%" % roundi(heat_f * 100.0), HORIZONTAL_ALIGNMENT_CENTER, panel.x, 16,
		hc if heat_f >= 0.6 else MechHud.WHITE)
	c.draw_string(_font, Vector2(0, panel.y - 13), "%d / %d" % [roundi(heat_f * heat_cap), roundi(heat_cap)],
		HORIZONTAL_ALIGNMENT_CENTER, panel.x, 11, MechHud.DIM)
	if state != "":
		c.draw_string(_font, Vector2(0, panel.y - 50), state, HORIZONTAL_ALIGNMENT_CENTER, panel.x, 13, MechHud.CYAN)
