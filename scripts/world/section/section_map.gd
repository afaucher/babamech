class_name SectionMap
extends Control
## The 2D view of a SectionPlan (game design 3.3: level design view and, later, the in-game map).
##   "section": the cross-section, a slice across the ring axis. Decks are concentric arcs with the top deck innermost
##              and "down" outward, so the floor curves up at both ends. Zones and pillars are those of one column
##              (`slice`); every connection and both routes are projected onto the slice.
##   "plans":   every deck unrolled flat, s across and x up, top deck first.

const ZONE_COLORS := {
	"urban": Color(0.86, 0.62, 0.47), "park": Color(0.55, 0.74, 0.5), "industrial": Color(0.56, 0.6, 0.68),
	"open": Color(0.5, 0.78, 0.92), "transit": Color(0.93, 0.78, 0.36), "": Color(0.4, 0.4, 0.4),
}
const C_ROAD := Color(0.24, 0.26, 0.29)
const C_WALK := Color(0.6, 0.6, 0.58)      ## pedestrian paving (pedestrian segments, a lane's walkways)
const C_SLAB := Color(0.42, 0.44, 0.48)
const C_PILLAR := Color(0.88, 0.88, 0.84)
const C_LIFT := Color(1.0, 0.55, 0.15)
const C_RAMP := Color(1.0, 0.72, 0.2)
const C_SHAFT := Color(0.45, 0.85, 1.0)
const C_VEHICLE := Color(1.0, 0.92, 0.25)
const C_MECH := Color(0.3, 1.0, 0.95)
const C_ENTRY := Color(0.35, 1.0, 0.45)
const C_EXIT := Color(1.0, 0.35, 0.4)
const C_WALL := {"bulkhead": Color(0.62, 0.64, 0.68), "window": Color(0.55, 0.8, 0.95, 0.75)}
## Gate kinds (SectionPlan._make_boundaries). The map is a level-design view, so it tells the crew's doors apart; the
## built doors all look the same.
const C_GATE := {"road_door": Color(0.35, 1.0, 0.45), "blast_door": Color(0.95, 0.25, 0.3), "collapsed": Color(0.55, 0.4, 0.3),
		"tram_door": Color(0.75, 0.55, 1.0)}
const C_RAIL := Color(0.36, 0.38, 0.44)
const C_VERGE := Color(0.32, 0.46, 0.3)
const C_HOOK := {"checkpoint": Color(1.0, 0.3, 0.3), "holding": Color(1.0, 1.0, 1.0), "patrol": Color(1.0, 0.45, 0.75)}

var plan: SectionPlan
var mode := "both"        ## section | plans | both
var slice := -1           ## column shown in the cross-section; -1 = the column west of the spine
var show_routes := "both" ## both | vehicle | mech | none


func show_plan(pl: SectionPlan) -> void:
	plan = pl
	queue_redraw()


func slice_col() -> int:
	if plan == null:
		return 0
	return clampi(slice, 0, plan.cols - 1) if slice >= 0 else plan.spine_line - 1


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.09, 0.11, 0.88))
	if plan == null or plan.decks.is_empty():
		return
	var pad := 10.0
	var area := Rect2(pad, pad + 16.0, size.x - pad * 2.0, size.y - pad * 2.0 - 34.0)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(pad, pad + 10.0), "seed %d   %s   %d decks  %d x %d cells   route: vehicles %.0f m, mechs %.0f m" % [
			int(plan.p("seed")), plan.checksum(), plan.deck_count, plan.cols, plan.rows,
			float(plan.route["vehicle_len"]), float(plan.route["mech_len"])], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	if mode == "section":
		_draw_section(area)
	elif mode == "plans":
		_draw_plans(area)
	else:
		var h := area.size.y * 0.42
		_draw_section(Rect2(area.position, Vector2(area.size.x, h)))
		_draw_plans(Rect2(area.position + Vector2(0, h + 8.0), Vector2(area.size.x, area.size.y - h - 8.0)))
	_draw_legend(Vector2(pad, size.y - 14.0))


# --- Cross-section ---------------------------------------------------------------------------------------

func _draw_section(area: Rect2) -> void:
	var half := plan.span * 0.5
	var r_in := plan.radius_of(0) - plan.clear_height()
	var r_out := plan.radius_of(plan.deck_count - 1) + plan.p("slab")
	# Fit the band: points are (r sin t, r cos t), y growing downward (outward).
	var w := 2.0 * r_out * sin(minf(half, PI * 0.5))
	var y0 := r_in * cos(half) if half < PI * 0.5 else r_out * cos(half)
	var y1 := r_out
	var sc := minf(area.size.x / w, area.size.y / (y1 - y0))
	var org := Vector2(area.get_center().x, area.position.y + (area.size.y - (y1 - y0) * sc) * 0.5 - y0 * sc)
	var at := func(theta: float, r: float) -> Vector2: return org + Vector2(sin(theta), cos(theta)) * r * sc
	var col := slice_col()
	for k in plan.deck_count:
		var rk := plan.radius_of(k)
		_band(at, -half, half, rk, rk + plan.p("slab"), C_SLAB)
		for r in plan.rows:
			_band(at, plan.row_theta[r], plan.row_theta[r + 1], rk - 2.5, rk, ZONE_COLORS[plan.zone(k, col, r)])
		for id in plan.pillars.size():
			var q: Dictionary = plan.pillars[id]
			if int(q["col"]) != col:
				continue
			var hw := plan.pillar_radius(k, id) / rk
			var style := plan.pillar_style(k, id)
			_band(at, float(q["theta"]) - hw, float(q["theta"]) + hw, rk - plan.clear_height(), rk, C_LIFT if style == "lift" else C_PILLAR)
	for k in plan.deck_count:
		for edge: String in ["s0", "s1"]:
			var b := plan.boundary(k, edge)
			var th := -half if edge == "s0" else half
			var wt := SectionPlan.WALL_T / plan.radius_of(k) * (-1.0 if edge == "s0" else 1.0)
			_band(at, th, th + wt, plan.radius_of(k) - plan.clear_height(), plan.radius_of(k), C_WALL[b["kind"]])
			for g: Dictionary in b["gates"]:
				if int(g["line"]) == plan.spine_line:
					_band(at, th, th + wt, plan.radius_of(k) - float(g["h"]), plan.radius_of(k), C_GATE[g["kind"]])
	for c: Dictionary in plan.connectors:
		var from := plan.radius_of(int(c["from"]))
		var to := plan.radius_of(int(c["to"]))
		match str(c["kind"]):
			"ramp":
				var t_top := float(c["run_top"])       # the slope run (inside the whole-row span)
				var t_foot := float(c["run_foot"])
				_band(at, minf(t_top, t_foot), maxf(t_top, t_foot), from, from + plan.p("slab"), Color(0.1, 0.1, 0.12))
				var pts := PackedVector2Array()
				for n in 13:
					var f := float(n) / 12.0
					pts.append(at.call(lerpf(t_top, t_foot, f), lerpf(from, to, f)))
				draw_polyline(pts, C_RAMP, 3.0, true)
			"lift":
				var th := (float(c["theta0"]) + float(c["theta1"])) * 0.5
				draw_line(at.call(th, from - 3.0), at.call(th, to - 1.0), C_LIFT if not c["locked"] else C_LIFT.darkened(0.35), 4.0, true)
				for k: int in c["stops"]:
					draw_circle(at.call(th, plan.radius_of(k) - 3.0), 3.5, C_LIFT)
			"shaft":
				_band(at, float(c["theta0"]), float(c["theta1"]), from, from + plan.p("slab"), Color(0.1, 0.1, 0.12))
				var th := (float(c["theta0"]) + float(c["theta1"])) * 0.5
				draw_line(at.call(th, from - 6.0), at.call(th, to - 8.0), C_SHAFT, 2.0, true)
				var tip: Vector2 = at.call(th, to - 3.0)
				var back: Vector2 = at.call(th, to - 11.0)
				var side := (tip - back).orthogonal().normalized() * 4.0
				draw_colored_polygon(PackedVector2Array([tip, back + side, back - side]), C_SHAFT)
	if show_routes == "both" or show_routes == "vehicle":
		var way: Array[Vector2] = []     # (theta, r)
		for wp: Dictionary in plan.route["vehicle"]:
			way.append(Vector2(plan.row_theta[int(wp["j"])], plan.radius_of(int(wp["deck"])) - 5.0))
		_polar_line(at, way, C_VEHICLE, 2.0)
	if show_routes == "both" or show_routes == "mech":
		var way: Array[Vector2] = []
		for wp: Dictionary in plan.route["mech"]:
			way.append(Vector2((plan.row_theta[int(wp["row"])] + plan.row_theta[int(wp["row"]) + 1]) * 0.5,
					plan.radius_of(int(wp["deck"])) - 10.0))
		_polar_line(at, way, C_MECH, 1.5)
	for h: Dictionary in plan.hooks:
		if h["kind"] == "checkpoint":
			var k := int(h["deck"])
			draw_circle(at.call(float(h["s"]) / plan.radius_of(k), plan.radius_of(k) - 3.0), 2.5, C_HOOK["checkpoint"])
	var e: Vector2 = at.call(plan.row_theta[int(plan.entry["j"])], plan.radius_of(0) - 8.0)
	var x: Vector2 = at.call(plan.row_theta[int(plan.extraction["j"])], plan.radius_of(int(plan.extraction["deck"])) - 8.0)
	draw_circle(e, 6.0, C_ENTRY)
	draw_circle(x, 6.0, C_EXIT)
	var font := ThemeDB.fallback_font
	draw_string(font, e + Vector2(8, 4), "IN", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_ENTRY)
	draw_string(font, x + Vector2(8, 4), "OUT", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_EXIT)
	draw_string(font, area.position + Vector2(0, 10), "cross-section, column %d (spine at line %d)" % [col, plan.spine_line],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.82, 0.86))


## A line through (theta, r) points that follows the ring between them.
func _polar_line(at: Callable, way: Array[Vector2], colr: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in way.size():
		if i > 0:
			var n := maxi(1, int(ceil(absf(way[i].x - way[i - 1].x) / 0.04)))
			for s in range(1, n):
				var mid := way[i - 1].lerp(way[i], float(s) / float(n))
				pts.append(at.call(mid.x, mid.y))
		pts.append(at.call(way[i].x, way[i].y))
	if pts.size() >= 2:
		draw_polyline(pts, colr, width, true)


## A filled piece of ring between two angles and two radii.
func _band(at: Callable, t0: float, t1: float, r0: float, r1: float, colr: Color) -> void:
	var n := maxi(2, int(ceil(absf(t1 - t0) / 0.04)))
	var pts := PackedVector2Array()
	for i in n + 1:
		pts.append(at.call(lerpf(t0, t1, float(i) / float(n)), r0))
	for i in n + 1:
		pts.append(at.call(lerpf(t1, t0, float(i) / float(n)), r1))
	draw_colored_polygon(pts, colr)


# --- Deck plans ------------------------------------------------------------------------------------------

func _draw_plans(area: Rect2) -> void:
	var n := plan.deck_count
	var gap := 6.0
	var each := (area.size.y - gap * float(n - 1)) / float(n)
	var longest := plan.arc_of(n - 1)
	var sc := minf(area.size.x / longest, each / plan.p("width"))
	var font := ThemeDB.fallback_font
	for k in n:
		var mid := Vector2(area.get_center().x, area.position.y + (each + gap) * float(k) + each * 0.5)
		# s runs right, x runs up (so the section reads like the cross-section above it).
		var at := func(x: float, s: float) -> Vector2: return mid + Vector2(s, -x) * sc
		var full := plan.arc_of(k)
		_rect(at, Rect2(-plan.p("width") * 0.5, -full * 0.5, plan.p("width"), full), C_ROAD)
		var rail := plan.lane_x("rail")
		_rect(at, Rect2(rail.x, -full * 0.5, rail.y - rail.x, full), C_RAIL if plan.lane_kind(k, "rail") == "rail" else C_VERGE)
		for edge in SectionPlan.EDGES:
			var b := plan.boundary(k, edge)
			_rect(at, plan.boundary_rect(k, edge), C_WALL[b["kind"]])
			for g: Dictionary in b["gates"]:
				var gw := float(g["width"]) * 0.5
				var wt := SectionPlan.WALL_T
				var gr := Rect2(float(g["x"]) - gw, float(g["s"]) - (wt if edge == "s0" else 0.0), gw * 2.0, wt)
				if g["axis"] == "x":
					gr = Rect2(float(g["x"]) - (wt if edge == "x0" else 0.0), float(g["s"]) - gw, wt, gw * 2.0)
				_rect(at, gr.grow(1.0), C_GATE[g["kind"]])
		for r in plan.rows:
			for c in plan.cols:
				_rect(at, plan.cell_rect(k, c, r), ZONE_COLORS[plan.zone(k, c, r)])
		_draw_forms(at, k)
		for kc: Rect2 in plan.decks[k]["keep_clear"]:
			_outline(at, kc, C_SHAFT.darkened(0.2))
		for ci in plan.connectors.size():
			var c: Dictionary = plan.connectors[ci]
			var touches := (c["stops"] as Array).has(k)
			if not touches:
				continue
			var rect := plan.connector_rect(ci, k)
			match str(c["kind"]):
				"ramp":
					_rect(at, rect, Color(0.08, 0.08, 0.1) if int(c["from"]) == k else C_RAMP.darkened(0.45))
					var run := plan.ramp_run(ci, k)
					var a: Vector2 = at.call(rect.get_center().x, run.x)
					var b: Vector2 = at.call(rect.get_center().x, run.y)
					draw_line(a, b, C_RAMP, 2.0, true)
					draw_circle(b if int(c["to"]) == k else a, 3.0, C_RAMP)
				"shaft":
					if int(c["from"]) == k:
						_rect(at, rect, Color(0.08, 0.08, 0.1))
						_outline(at, rect, C_SHAFT)
		for id in plan.pillars.size():
			var pt := plan.pillar_point(k, id)
			var style := plan.pillar_style(k, id)
			var rad := plan.pillar_radius(k, id)
			_rect(at, Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0), C_LIFT if style == "lift" else C_PILLAR)
		if show_routes == "both" or show_routes == "vehicle":
			var pts := PackedVector2Array()
			for wp: Dictionary in plan.route["vehicle"]:
				if int(wp["deck"]) == k:
					var np := plan.node_pos(k, wp["i"], wp["j"])
					pts.append(at.call(np.x, np.y))
			if pts.size() >= 2:
				draw_polyline(pts, C_VEHICLE, 2.0, true)
		if show_routes == "both" or show_routes == "mech":
			var pts := PackedVector2Array()
			for wp: Dictionary in plan.route["mech"]:
				if int(wp["deck"]) == k:
					var cp := plan.cell_rect(k, wp["col"], wp["row"]).get_center()
					pts.append(at.call(cp.x, cp.y))
			if pts.size() >= 2:
				draw_polyline(pts, C_MECH, 1.5, true)
			elif pts.size() == 1:
				draw_circle(pts[0], 2.5, C_MECH)
		for h: Dictionary in plan.hooks:
			if int(h["deck"]) != k or not C_HOOK.has(h["kind"]):
				continue
			var hp: Vector2 = at.call(float(h["x"]), float(h["s"]))
			if h["kind"] == "patrol":
				var loop := PackedVector2Array()
				for q: Vector2 in h["loop"]:
					loop.append(at.call(q.x, q.y))
				loop.append(loop[0])
				draw_polyline(loop, C_HOOK["patrol"], 1.0, true)
			elif h["kind"] == "holding":
				draw_arc(hp, 5.0, 0.0, TAU, 16, C_HOOK["holding"], 1.5, true)
			else:
				draw_circle(hp, 3.0, C_HOOK["checkpoint"])
		if k == 0:
			var np := plan.node_pos(0, plan.entry["i"], plan.entry["j"])
			draw_circle(at.call(np.x, np.y), 5.0, C_ENTRY)
		if k == int(plan.extraction["deck"]):
			var np := plan.node_pos(k, plan.extraction["i"], plan.extraction["j"])
			draw_circle(at.call(np.x, np.y), 5.0, C_EXIT)
		draw_string(font, Vector2(area.position.x, mid.y - each * 0.5 + 11.0), "deck %d  %s" % [k, "->" if int(plan.decks[k]["dir"]) > 0 else "<-"],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


## Road segment forms on a deck plan: a lane is a narrow carriageway with walkways, a pedestrian segment a light dotted
## path, a `none` segment is not drawn (its strip takes the zone colour: one superblock); a ramp cut with no bridge, red.
func _draw_forms(at: Callable, k: int) -> void:
	for sg: Dictionary in plan.segments(k):
		var inner: Rect2 = sg["inner"]
		var along_s: bool = sg["axis"] == "s"
		match str(sg["form"]):
			"none":
				var line := int(sg["line"])
				var side := line if line < (plan.cols if along_s else plan.rows) else line - 1
				var cell := Vector2i(side, int(sg["index"])) if along_s else Vector2i(int(sg["index"]), side)
				_rect(at, inner, ZONE_COLORS[plan.zone(k, cell.x, cell.y)])
			"pedestrian":
				_rect(at, inner, C_WALK)
				var mid := inner.get_center()
				var a: Vector2 = at.call(mid.x, inner.position.y) if along_s else at.call(inner.position.x, mid.y)
				var b: Vector2 = at.call(mid.x, inner.end.y) if along_s else at.call(inner.end.x, mid.y)
				draw_dashed_line(a, b, C_ROAD, 1.0, 3.0)
			"lane":
				_rect(at, inner, C_WALK)
				var w := float(SectionPlan.FORM_WIDTH["lane"])
				var lane := Rect2(inner.get_center().x - w * 0.5, inner.position.y, w, inner.size.y) if along_s \
						else Rect2(inner.position.x, inner.get_center().y - w * 0.5, inner.size.x, w)
				_rect(at, lane, C_ROAD)
		if sg["blocked"] == "bridge":
			_outline(at, inner, C_EXIT)


func _rect(at: Callable, r: Rect2, colr: Color) -> void:
	var a: Vector2 = at.call(r.position.x, r.position.y)
	var b: Vector2 = at.call(r.end.x, r.end.y)
	draw_rect(Rect2(a, b - a).abs(), colr)


func _outline(at: Callable, r: Rect2, colr: Color) -> void:
	var a: Vector2 = at.call(r.position.x, r.position.y)
	var b: Vector2 = at.call(r.end.x, r.end.y)
	draw_rect(Rect2(a, b - a).abs(), colr, false, 1.5)


func _draw_legend(at: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var x := at.x
	var items := [["urban", ZONE_COLORS["urban"]], ["park", ZONE_COLORS["park"]], ["industrial", ZONE_COLORS["industrial"]],
			["open air", ZONE_COLORS["open"]], ["transit", ZONE_COLORS["transit"]], ["pillar", C_PILLAR], ["lift", C_LIFT],
			["ramp", C_RAMP], ["shaft", C_SHAFT], ["vehicles", C_VEHICLE], ["mechs", C_MECH], ["checkpoint", C_HOOK["checkpoint"]],
			["patrol", C_HOOK["patrol"]], ["civilians", C_HOOK["holding"]], ["pedestrian", C_WALK], ["wall", C_WALL["bulkhead"]], ["window", C_WALL["window"]],
			["road door", C_GATE["blast_door"]], ["entry / exit", C_GATE["road_door"]], ["collapsed", C_GATE["collapsed"]],
			["tram door", C_GATE["tram_door"]], ["verge", C_VERGE]]
	for it: Array in items:
		draw_rect(Rect2(x, at.y - 8.0, 9.0, 9.0), it[1])
		draw_string(font, Vector2(x + 12.0, at.y + 1.0), str(it[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.87, 0.9))
		x += 18.0 + font.get_string_size(str(it[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
