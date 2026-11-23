class_name MissionHud
extends Control
## The mission layer of the HUD (W6, docs/design/hud.md "Mission objective"): a child of MechHud's root, same holo style.
##   top centre   the objective line (MissionRules.text(): "Clear deck 1: 5 hostiles left", "Reach the extraction
##                portal"), in a glass strip under the help line (`objective_panel`)
##   anywhere     the extraction waypoint (MissionRules.marker() as a world point): a diamond with "EXTRACT" and the
##                distance, drawn over everything (it shows through decks); off screen or behind the camera it sticks
##                to the screen edge with an arrow pointing toward it (`markers`)
##   centre       the end banner, "MISSION COMPLETE" + the reason, for the hold before the mission ends (`banner`)
## PLAN MODE (the state has plan: true; docs/design/mission-objectives.md phase 1), also:
##   top right    the objective list of your deck (`list_panel`): "DECK n OBJECTIVES" + "WAVES 2 / 3", then
##                MissionRules.lines(deck) (primary first, bonuses once found, "(done)" / "(failed)")
##   anywhere     objective markers (flag / defend; "? FLAG" for a found bonus not yet started) like the waypoint, and a
##                ring projected on the floor round each defend site (the world draws the flag rings and the hold zone)
##   top centre   under the objective line: "Reinforcements, east gate" with the seconds to the door (`alert_panel`),
##                and (SOURCE_ARROW, on: user decision 2026-11-23, with the door's own telegraph)
##                an INBOUND arrow (edge-stuck) at the source on your deck; then the zone progress bar while anyone
##                of the crew stands in an active flag / hold zone ("RAISING THE FLAG 12 / 20 S", "HOLDING THE PORTAL
##                42 S", red "CONTESTED") (`zone_panel`)
## Data, read-only, polled every frame: `source: Callable` () -> {objective: String, waypoint: {pos: Vector3, deck: int,
## label: String} or {}, banner: {title, reason, won: bool} or {}} (MissionFlow.hud_state(); plan mode adds plan, deck,
## lines, waves, markers, rings, zone, alerts). `from` is where the distance is measured from (the local mech; else the
## camera). `demo` shows fixed sample data (layout tests, screenshots), `demo_banner` adds the banner, `demo_plan` the
## plan-mode elements. Cosmetic: no gameplay state, nothing synced.

const OBJ_SIZE := Vector2(520, 34)
const OBJ_TOP := 40.0             ## below the test drive's help line (top 12)
const BANNER_SIZE := Vector2(640, 120)
const EDGE_PAD := 48.0            ## an off-screen waypoint sticks this far inside the screen edge
const DEMO_STATE := {"objective": "Clear deck 2: 5 hostiles left", "banner": {}}
const DEMO_WAYPOINT_AT := Vector2(0.76, 0.2)    ## viewport fraction where the demo draws its waypoint
const DEMO_BANNER := {"title": "MISSION COMPLETE", "reason": "Every deck cleared, the crew reached extraction", "won": true}
const LIST_W := 300.0
const LIST_HEAD := 30.0           ## px of the list's header (deck, waves)
const LIST_LINE := 20.0           ## px per objective line
const LIST_MAX := 7               ## most lines shown
const ALERT_SIZE := Vector2(420, 28)
const ALERT_TOP := 118.0          ## a row under the objective line (82..110 is kept free)
## The INBOUND arrow toward a wave's source (screen-space, edge-stuck). ON (user decision 2026-11-23: "keep both", with
## the gate's beacon / klaxon); it points at a door, never at enemy units.
const SOURCE_ARROW := true
const ZONE_SIZE := Vector2(380, 40)
const ZONE_TOP := 154.0
const DEMO_PLAN := {"objective": "Raise the flag: 12 / 20 s", "plan": true, "deck": 0,
	"lines": ["Raise the flag: 12 / 20 s", "Bonus: Defend the position: wave 1 / 2", "Bonus: Raise the flag: 20 / 20 s (done)"],
	"waves": [1, 3], "zone": {"label": "RAISING THE FLAG", "progress": 12.0, "total": 20.0, "contested": false, "countdown": false}}
const DEMO_MARK_AT := Vector2(0.3, 0.42)            ## viewport fraction of the demo's objective marker
const DEMO_RING := Rect2(0.42, 0.62, 0.16, 0.08)    ## viewport fraction of the demo's projected ring (an ellipse)
const DEMO_ALERT_DIR := Vector2(-1, 0.25)           ## the demo's reinforcement arrow sticks to the left edge

var source: Callable
var from: Node3D
var demo := false
var demo_banner := false
var demo_plan := false

var objective_panel: Control
var banner: Control
var markers: Control
var list_panel: Control
var alert_panel: Control
var zone_panel: Control
var _font: Font
var _state: Dictionary = {}


func _init() -> void:
	name = "MissionHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	markers = _canvas("Markers", _draw_markers)
	add_child(markers)
	markers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	objective_panel = _canvas("Objective", _draw_objective)
	add_child(objective_panel)
	objective_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	objective_panel.offset_left = -OBJ_SIZE.x * 0.5
	objective_panel.offset_right = OBJ_SIZE.x * 0.5
	objective_panel.offset_top = OBJ_TOP
	objective_panel.offset_bottom = OBJ_TOP + OBJ_SIZE.y
	banner = _canvas("Banner", _draw_banner)
	add_child(banner)
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	banner.offset_left = -BANNER_SIZE.x * 0.5
	banner.offset_right = BANNER_SIZE.x * 0.5
	banner.offset_top = -BANNER_SIZE.y * 0.5 - 140.0   # above the crosshair
	banner.offset_bottom = BANNER_SIZE.y * 0.5 - 140.0
	list_panel = _canvas("ObjectiveList", _draw_list)
	add_child(list_panel)
	list_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	list_panel.offset_left = -MechHud.MARGIN - LIST_W
	list_panel.offset_right = -MechHud.MARGIN
	list_panel.offset_top = OBJ_TOP
	list_panel.offset_bottom = OBJ_TOP + LIST_HEAD + LIST_LINE
	alert_panel = _canvas("Reinforcements", _draw_alert)
	add_child(alert_panel)
	_top_strip(alert_panel, ALERT_SIZE, ALERT_TOP)
	zone_panel = _canvas("ZoneProgress", _draw_zone)
	add_child(zone_panel)
	_top_strip(zone_panel, ZONE_SIZE, ZONE_TOP)
	_refresh()


## The objective list's top: level with the objective line when the screen is wide enough for both side by side, else
## under the centre strips (4:3).
static func list_top(width: float) -> float:
	if width * 0.5 - OBJ_SIZE.x * 0.5 >= LIST_W + MechHud.MARGIN + 8.0:
		return OBJ_TOP
	return ZONE_TOP + ZONE_SIZE.y + 8.0


func _top_strip(c: Control, sz: Vector2, top: float) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	c.offset_left = -sz.x * 0.5
	c.offset_right = sz.x * 0.5
	c.offset_top = top
	c.offset_bottom = top + sz.y


func _canvas(n: String, painter: Callable) -> Control:
	var c := Control.new()
	c.name = n
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func() -> void: painter.call(c))
	return c


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	_state = state()
	if objective_panel == null:
		return
	objective_panel.visible = str(_state.get("objective", "")) != ""
	banner.visible = not (_state.get("banner", {}) as Dictionary).is_empty()
	var planned := bool(_state.get("plan", false))
	var lines: Array = _state.get("lines", [])
	list_panel.visible = planned
	list_panel.offset_top = list_top(get_viewport_rect().size.x)
	list_panel.offset_bottom = list_panel.offset_top + LIST_HEAD + LIST_LINE * float(clampi(lines.size(), 1, LIST_MAX)) + 6.0
	alert_panel.visible = planned and not (_state.get("alerts", []) as Array).is_empty()
	zone_panel.visible = planned and not (_state.get("zone", {}) as Dictionary).is_empty()
	objective_panel.queue_redraw()
	banner.queue_redraw()
	markers.queue_redraw()
	list_panel.queue_redraw()
	alert_panel.queue_redraw()
	zone_panel.queue_redraw()


## What is drawn now (see the header).
func state() -> Dictionary:
	if demo:
		var d := DEMO_STATE.duplicate(true)
		d["waypoint"] = {"demo": true, "label": "EXTRACT"}
		if demo_banner:
			d["banner"] = DEMO_BANNER
		if demo_plan:
			d.merge(DEMO_PLAN.duplicate(true), true)
			d["markers"] = [{"demo": true, "label": "? DEFEND", "role": "bonus", "state": "known", "kind": "defend"}]
			d["rings"] = [{"demo": true}]
			d["alerts"] = [{"text": "Reinforcements, east gate", "pos": null, "left": 4.0, "demo": true}]
		return d
	if source.is_valid():
		var v: Variant = source.call()
		if v is Dictionary:
			return v
	return {"objective": "", "waypoint": {}, "banner": {}}


## Where the waypoint is drawn now: {at: screen point, on_screen: bool, dist: m} or {} (none / no camera).
func waypoint_screen() -> Dictionary:
	var wp: Dictionary = _state.get("waypoint", {})
	if wp.is_empty():
		return {}
	var vs := get_viewport_rect().size
	if bool(wp.get("demo", false)):
		return {"at": vs * DEMO_WAYPOINT_AT, "on_screen": true, "dist": 184.0}
	var cam := get_viewport().get_camera_3d()
	if cam == null or not (wp.get("pos") is Vector3):
		return {}
	var p: Vector3 = wp["pos"]
	var origin := from.global_position if from != null and is_instance_valid(from) and from.is_inside_tree() else cam.global_position
	var out := screen_point(cam, p, vs, EDGE_PAD)
	out["dist"] = origin.distance_to(p)
	return out


## Where a world point `p` is drawn on a `vs`-sized screen: {at, on_screen: true} inside the screen less `pad`, else
## (off screen or behind the camera) stuck to that inner rectangle on the line from the centre toward it (mirrored when
## behind), with `dir` the unit direction of the edge arrow.
static func screen_point(cam: Camera3D, p: Vector3, vs: Vector2, pad: float) -> Dictionary:
	var behind := cam.is_position_behind(p)
	var sp := cam.unproject_position(p)
	var inner := Rect2(Vector2(pad, pad), vs - Vector2(pad, pad) * 2.0)
	if not behind and inner.has_point(sp):
		return {"at": sp, "on_screen": true}
	var c := vs * 0.5
	var dir := (sp - c) * (-1.0 if behind else 1.0)
	if dir.length() < 1.0:
		dir = Vector2(0, 1)
	var half := inner.size * 0.5
	var k := minf(half.x / maxf(absf(dir.x), 1e-4), half.y / maxf(absf(dir.y), 1e-4))
	return {"at": c + dir * k, "on_screen": false, "dir": dir.normalized()}


# --- Drawing ---------------------------------------------------------------------------------------------------

func _draw_objective(c: Control) -> void:
	var t := str(_state.get("objective", ""))
	if t == "":
		return
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	c.draw_rect(Rect2(Vector2(0, 0), Vector2(4, r.size.y)), MechHud.AMBER, true)
	c.draw_string(_font, Vector2(14, r.size.y * 0.5 - 3), "OBJECTIVE", HORIZONTAL_ALIGNMENT_LEFT, 90, 10, MechHud.DIM)
	c.draw_string(_font, Vector2(14, r.size.y * 0.5 + 10), t.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24, 15,
		MechHud.WHITE)


func _draw_markers(c: Control) -> void:
	if bool(_state.get("plan", false)):
		_draw_plan_marks(c)
	var w := waypoint_screen()
	if w.is_empty():
		return
	var at: Vector2 = w["at"]
	var col := MechHud.AMBER
	var r := 11.0
	var dia := PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0), at + Vector2(0, -r)])
	c.draw_colored_polygon(dia.slice(0, 4), Color(col, 0.25))
	c.draw_polyline(dia, col, 2.0, true)
	c.draw_circle(at, 2.5, col)
	if not bool(w["on_screen"]) and w.has("dir"):
		draw_edge_arrow(c, at, w["dir"], r, col)
	var label := "%s  %dm" % [str((_state.get("waypoint", {}) as Dictionary).get("label", "EXTRACT")), roundi(float(w["dist"]))]
	var tw := 140.0
	var ty := at.y + r + 16.0
	if ty > c.size.y - 8.0:
		ty = at.y - r - 8.0
	c.draw_string_outline(_font, Vector2(at.x - tw * 0.5, ty), label, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, 4, Color(0, 0, 0, 0.8))
	c.draw_string(_font, Vector2(at.x - tw * 0.5, ty), label, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, col)


## The off-screen arrow beside a marker of radius `r` at `at`, pointing along `d` (unit).
static func draw_edge_arrow(c: Control, at: Vector2, d: Vector2, r: float, col: Color) -> void:
	var tip := at + d * (r + 12.0)
	var side := Vector2(-d.y, d.x) * 6.0
	c.draw_colored_polygon(PackedVector2Array([tip, tip - d * 9.0 + side, tip - d * 9.0 - side]), col)


## Plan mode: where each objective marker is drawn now: [{at, on_screen, dist, label, role, dir?}].
func objective_points() -> Array:
	var out: Array = []
	var vs := get_viewport_rect().size
	var cam := get_viewport().get_camera_3d()
	for m: Variant in _state.get("markers", []):
		var md: Dictionary = m
		if bool(md.get("demo", false)):
			out.append({"at": vs * DEMO_MARK_AT, "on_screen": true, "dist": 96.0, "label": md["label"], "role": md["role"]})
			continue
		if cam == null or not (md.get("pos") is Vector3):
			continue
		var p: Vector3 = md["pos"]
		var o := screen_point(cam, p, vs, EDGE_PAD)
		o["dist"] = _origin(cam).distance_to(p)
		o["label"] = md.get("label", "")
		o["role"] = md.get("role", "primary")
		out.append(o)
	return out


## Plan mode: the reinforcement arrows on your deck: [{at, on_screen, dir?, left}].
func alert_points() -> Array:
	var out: Array = []
	if not SOURCE_ARROW:
		return out
	var vs := get_viewport_rect().size
	var cam := get_viewport().get_camera_3d()
	for a: Variant in _state.get("alerts", []):
		var ad: Dictionary = a
		if bool(ad.get("demo", false)):
			var inner := vs * 0.5 - Vector2(EDGE_PAD, EDGE_PAD)
			var d := DEMO_ALERT_DIR.normalized()
			var k := minf(inner.x / absf(d.x), inner.y / maxf(absf(d.y), 1e-4))
			out.append({"at": vs * 0.5 + d * k, "on_screen": false, "dir": d, "left": ad["left"]})
			continue
		if cam == null or not (ad.get("pos") is Vector3):
			continue
		var o := screen_point(cam, ad["pos"], vs, EDGE_PAD)
		o["left"] = ad.get("left", 0.0)
		out.append(o)
	return out


## Plan mode: each projected ring as screen polylines (points behind the camera split it).
func ring_lines() -> Array:
	var out: Array = []
	var vs := get_viewport_rect().size
	var cam := get_viewport().get_camera_3d()
	for r: Variant in _state.get("rings", []):
		if r is Dictionary and bool((r as Dictionary).get("demo", false)):
			var line := PackedVector2Array()
			var c := (DEMO_RING.position + DEMO_RING.size * 0.5) * vs
			var h := DEMO_RING.size * 0.5 * vs
			for i in 41:
				var a := TAU * float(i) / 40.0
				line.append(c + Vector2(cos(a) * h.x, sin(a) * h.y))
			out.append(line)
			continue
		if cam == null or not (r is PackedVector3Array):
			continue
		var cur := PackedVector2Array()
		for p: Vector3 in r:
			if cam.is_position_behind(p):
				if cur.size() > 1:
					out.append(cur)
				cur = PackedVector2Array()
				continue
			cur.append(cam.unproject_position(p))
		if cur.size() > 1:
			out.append(cur)
	return out


func _origin(cam: Camera3D) -> Vector3:
	return from.global_position if from != null and is_instance_valid(from) and from.is_inside_tree() else cam.global_position


func _draw_plan_marks(c: Control) -> void:
	for line: PackedVector2Array in ring_lines():
		c.draw_polyline(line, Color(MechHud.AMBER, 0.75), 2.0, true)
	for m: Dictionary in objective_points():
		var at: Vector2 = m["at"]
		var col := MechHud.AMBER if m["role"] == "primary" else MechHud.CYAN
		var r := 9.0
		var sq := PackedVector2Array([at + Vector2(-r, -r), at + Vector2(r, -r), at + Vector2(r, r), at + Vector2(-r, r),
			at + Vector2(-r, -r)])
		c.draw_colored_polygon(sq.slice(0, 4), Color(col, 0.22))
		c.draw_polyline(sq, col, 2.0, true)
		if not bool(m["on_screen"]) and m.has("dir"):
			draw_edge_arrow(c, at, m["dir"], r, col)
		_label(c, at, r, "%s  %dm" % [str(m["label"]), roundi(float(m["dist"]))], col)
	for a: Dictionary in alert_points():
		var at: Vector2 = a["at"]
		var col := MechHud.RED
		var r := 10.0
		var tri := PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, r * 0.8), at + Vector2(-r, r * 0.8), at + Vector2(0, -r)])
		c.draw_colored_polygon(tri.slice(0, 3), Color(col, 0.3))
		c.draw_polyline(tri, col, 2.0, true)
		if not bool(a["on_screen"]) and a.has("dir"):
			draw_edge_arrow(c, at, a["dir"], r, col)
		var left := float(a.get("left", 0.0))
		_label(c, at, r, ("INBOUND %ds" % ceili(left)) if left > 0.0 else "INBOUND", col)


func _label(c: Control, at: Vector2, r: float, text: String, col: Color) -> void:
	var tw := 150.0
	var ty := at.y + r + 16.0
	if ty > c.size.y - 8.0:
		ty = at.y - r - 8.0
	var x := clampf(at.x - tw * 0.5, 4.0, maxf(c.size.x - tw - 4.0, 4.0))
	c.draw_string_outline(_font, Vector2(x, ty), text, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, 4, Color(0, 0, 0, 0.8))
	c.draw_string(_font, Vector2(x, ty), text, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, col)


func _draw_list(c: Control) -> void:
	if not bool(_state.get("plan", false)):
		return
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	c.draw_rect(Rect2(Vector2(r.size.x - 4, 0), Vector2(4, r.size.y)), MechHud.AMBER, true)
	c.draw_string(_font, Vector2(12, 20), "DECK %d OBJECTIVES" % (int(_state.get("deck", 0)) + 1), HORIZONTAL_ALIGNMENT_LEFT,
		200, 11, MechHud.DIM)
	var wv: Array = _state.get("waves", [])
	if wv.size() > 1 and int(wv[1]) > 0:
		c.draw_string(_font, Vector2(r.size.x - 132, 20), "WAVES %d / %d" % [int(wv[0]), int(wv[1])], HORIZONTAL_ALIGNMENT_RIGHT,
			116, 11, MechHud.AMBER)
	var lines: Array = _state.get("lines", [])
	var y := LIST_HEAD + 12.0
	for i in mini(lines.size(), LIST_MAX):
		var t := str(lines[i])
		var col := MechHud.WHITE
		if t.ends_with("(done)"):
			col = MechHud.GREEN
		elif t.ends_with("(failed)"):
			col = MechHud.RED
		elif t.begins_with("Bonus: "):
			col = MechHud.CYAN
		c.draw_string(_font, Vector2(12, y), t.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24, 12, col)
		y += LIST_LINE


func _draw_alert(c: Control) -> void:
	var al: Array = _state.get("alerts", [])
	if al.is_empty():
		return
	var a: Dictionary = al[-1]
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	c.draw_rect(Rect2(Vector2(0, 0), Vector2(4, r.size.y)), MechHud.RED, true)
	var left := float(a.get("left", 0.0))
	var t := str(a.get("text", "")).to_upper()
	if left > 0.0:
		t += "  %ds" % ceili(left)
	c.draw_string(_font, Vector2(14, r.size.y * 0.5 + 5), t, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24, 14, MechHud.RED)


func _draw_zone(c: Control) -> void:
	var z: Dictionary = _state.get("zone", {})
	if z.is_empty():
		return
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	var contested := bool(z.get("contested", false))
	var col := MechHud.RED if contested else MechHud.AMBER
	var prog := float(z.get("progress", 0.0))
	var tot := maxf(float(z.get("total", 1.0)), 0.001)
	var right := "%d / %d S" % [int(prog), int(round(tot))]
	if bool(z.get("countdown", false)):
		right = "%d S" % int(ceil(maxf(tot - prog, 0.0) - 0.001))
	var label := "CONTESTED" if contested else str(z.get("label", ""))
	c.draw_string(_font, Vector2(12, 16), label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 120, 12, col)
	c.draw_string(_font, Vector2(r.size.x - 112, 16), right, HORIZONTAL_ALIGNMENT_RIGHT, 100, 12, MechHud.WHITE)
	var bar := Rect2(Vector2(12, 24), Vector2(r.size.x - 24, 8))
	c.draw_rect(bar, Color(col, 0.2), true)
	c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(prog / tot, 0.0, 1.0), bar.size.y)), col, true)


func _draw_banner(c: Control) -> void:
	var b: Dictionary = _state.get("banner", {})
	if b.is_empty():
		return
	var r := Rect2(Vector2.ZERO, c.size)
	var col := MechHud.GREEN if bool(b.get("won", false)) else MechHud.RED
	MechHud.draw_glass(c, r)
	c.draw_rect(Rect2(Vector2(0, 0), Vector2(r.size.x, 3)), col, true)
	c.draw_rect(Rect2(Vector2(0, r.size.y - 3), Vector2(r.size.x, 3)), col, true)
	c.draw_string(_font, Vector2(0, r.size.y * 0.5 + 6), str(b.get("title", "")), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 38, col)
	c.draw_string(_font, Vector2(0, r.size.y * 0.5 + 36), str(b.get("reason", "")), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 14,
		MechHud.WHITE)
