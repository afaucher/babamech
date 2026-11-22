class_name MissionHud
extends Control
## The mission layer of the HUD (W6, docs/design/hud.md "Mission objective"): a child of MechHud's root, same holo style.
##   top centre   the objective line (MissionRules.text(): "Clear deck 1: 5 hostiles left", "Reach the extraction
##                portal"), in a glass strip under the help line (`objective_panel`)
##   anywhere     the extraction waypoint (MissionRules.marker() as a world point): a diamond with "EXTRACT" and the
##                distance, drawn over everything (it shows through decks); off screen or behind the camera it sticks
##                to the screen edge with an arrow pointing toward it (`markers`)
##   centre       the end banner, "MISSION COMPLETE" + the reason, for the hold before the mission ends (`banner`)
## Data, read-only, polled every frame: `source: Callable` () -> {objective: String, waypoint: {pos: Vector3, deck: int,
## label: String} or {}, banner: {title, reason, won: bool} or {}} (MissionFlow.hud_state()). `from` is where the
## distance is measured from (the local mech; else the camera). `demo` shows fixed sample data (layout tests,
## screenshots), `demo_banner` adds the banner. Cosmetic: no gameplay state, nothing synced.

const OBJ_SIZE := Vector2(520, 34)
const OBJ_TOP := 40.0             ## below the test drive's help line (top 12)
const BANNER_SIZE := Vector2(640, 120)
const EDGE_PAD := 48.0            ## an off-screen waypoint sticks this far inside the screen edge
const DEMO_STATE := {"objective": "Clear deck 2: 5 hostiles left", "banner": {}}
const DEMO_WAYPOINT_AT := Vector2(0.76, 0.2)    ## viewport fraction where the demo draws its waypoint
const DEMO_BANNER := {"title": "MISSION COMPLETE", "reason": "Every deck cleared, the crew reached extraction", "won": true}

var source: Callable
var from: Node3D
var demo := false
var demo_banner := false

var objective_panel: Control
var banner: Control
var markers: Control
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
	_refresh()


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
	objective_panel.queue_redraw()
	banner.queue_redraw()
	markers.queue_redraw()


## What is drawn now (see the header).
func state() -> Dictionary:
	if demo:
		var d := DEMO_STATE.duplicate(true)
		d["waypoint"] = {"demo": true, "label": "EXTRACT"}
		if demo_banner:
			d["banner"] = DEMO_BANNER
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
	var dist := origin.distance_to(p)
	var behind := cam.is_position_behind(p)
	var sp := cam.unproject_position(p)
	var inner := Rect2(Vector2(EDGE_PAD, EDGE_PAD), vs - Vector2(EDGE_PAD, EDGE_PAD) * 2.0)
	if not behind and inner.has_point(sp):
		return {"at": sp, "on_screen": true, "dist": dist}
	# Off screen: from the centre toward it (mirrored when behind), clamped to the inner rectangle.
	var c := vs * 0.5
	var dir := (sp - c) * (-1.0 if behind else 1.0)
	if dir.length() < 1.0:
		dir = Vector2(0, 1)
	var half := inner.size * 0.5
	var k := minf(half.x / maxf(absf(dir.x), 1e-4), half.y / maxf(absf(dir.y), 1e-4))
	return {"at": c + dir * k, "on_screen": false, "dist": dist, "dir": dir.normalized()}


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
		var d: Vector2 = w["dir"]
		var tip := at + d * (r + 12.0)
		var side := Vector2(-d.y, d.x) * 6.0
		c.draw_colored_polygon(PackedVector2Array([tip, tip - d * 9.0 + side, tip - d * 9.0 - side]), col)
	var label := "%s  %dm" % [str((_state.get("waypoint", {}) as Dictionary).get("label", "EXTRACT")), roundi(float(w["dist"]))]
	var tw := 140.0
	var ty := at.y + r + 16.0
	if ty > c.size.y - 8.0:
		ty = at.y - r - 8.0
	c.draw_string_outline(_font, Vector2(at.x - tw * 0.5, ty), label, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, 4, Color(0, 0, 0, 0.8))
	c.draw_string(_font, Vector2(at.x - tw * 0.5, ty), label, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, col)


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
