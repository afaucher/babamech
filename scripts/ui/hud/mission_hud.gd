class_name MissionHud
extends Control
## The mission layer of the HUD (W6, docs/design/hud.md "Mission objective"): a child of MechHud's root, same holo style.
##   top right    the objective panel (`list_panel`, the HUD's only objective panel; see PLAN MODE below)
##   anywhere     the extraction waypoint (MissionRules.marker() as a world point): a diamond with "EXTRACT" and the
##                distance, drawn over everything (it shows through decks); off screen or behind the camera it sticks
##                to the screen edge with an arrow pointing toward it (`markers`)
##   centre       the end banner, "MISSION COMPLETE" + the reason, for the hold before the mission ends (`banner`)
## PLAN MODE (the state has plan: true: every mission, the one mode; docs/design/mission-objectives.md phase 1), also:
##   top right    the same panel, structured (`panel`, MissionRules.panel() via MissionFlow, docs/design/
##                mission-objectives.md §9 "Objective panel", playtest backlog R2.13): one section per deck, every deck
##                listed, "DECK 1:" headers (the viewer's deck bright with a marker before it, the others dim), a
##                visited deck's objectives indented under it, an unvisited deck's "PROCEED TO DECK 3"; the next step
##                amber with its route hint ("RAMP DOWN 120 M"); the depot line at the end of the viewer's section;
##                fitted to PANEL_FRAC of the screen height (MissionRules.fit). Without a panel: the flat
##                MissionRules.lines(deck); no lines: the objective text
##   anywhere     objective markers (flag / defend; a found bonus reads "FLAG" / "DEFEND" like a primary) like the waypoint, and a
##                ring projected on the floor round each defend site (the world draws the flag rings and the hold zone)
##   top centre   "Reinforcements, east gate" with the seconds to the door (`alert_panel`),
##                and (SOURCE_ARROW, on: user decision 2026-11-23, with the door's own telegraph)
##                an INBOUND arrow (edge-stuck) at the source on your deck; then the zone progress bar while anyone
##                of the crew stands in an active flag / hold zone ("RAISING THE FLAG 60 %", "HOLDING THE EXIT
##                40 %", red "CONTESTED") (`zone_panel`); the ally's lines ("WORKING ON THE DOOR", R2.10) in the same
##                strip, cyan, text only (alerts with `ally`)
## DOWNED / REVIVE / RESPAWN (DownedCrew.hud_state via `downed_source`; docs/design/pacing-director.md "Downed, revive,
## respawn"), player-side only (no enemy indicators):
##   top right    a crewmate down adds a red line to the SAME objective panel ("Pickle is down: revive with a repair
##                drone" / "Pickle is down"), never cut by the panel's fitting
##   anywhere     a marker on each downed crewmate's wreck ("DOWN  Pickle  34m", edge-stuck off screen) with its revive bar
##   centre       for the downed pilot (`downed_panel`, under the crosshair): "DOWN", "Help is 34 m away" / "No repair
##                drone in the crew", the revive bar while a drone beams it, "Hold SPACE to respawn" with the hold bar;
##                then "REDEPLOYING 4 S". `demo_downed` shows fixed sample data (layout tests).
## Data, read-only, polled every frame: `source: Callable` () -> {objective: String, waypoint: {pos: Vector3, deck: int,
## label: String} or {}, banner: {title, reason, won: bool} or {}} (MissionHudModel.build(); plan mode adds plan, deck,
## lines, waves, markers, rings, zone, alerts). `from` is where the distance is measured from (the local mech; else the
## camera). `demo` shows fixed sample data (layout tests, screenshots), `demo_banner` adds the banner, `demo_plan` the
## plan-mode elements. Cosmetic: no gameplay state, nothing synced.

const OBJ_TOP := 40.0             ## the objective panel's top: below the test drive's help line (top 12)
const BANNER_SIZE := Vector2(640, 120)
const EDGE_PAD := 48.0            ## an off-screen waypoint sticks this far inside the screen edge
## The plain demo: one primary line in the flat plan list (no panel); demo_plan adds the structured panel and the rest.
const DEMO_STATE := {"objective": "Raise the flag: 60%", "plan": true, "deck": 0, "lines": ["Raise the flag: 60%"],
	"banner": {}}
const DEMO_WAYPOINT_AT := Vector2(0.66, 0.3)    ## viewport fraction where the demo draws its waypoint (clear of the panel)
const DEMO_BANNER := {"title": "MISSION COMPLETE", "reason": "Every primary done, the crew walked out through the exit", "won": true}
const LIST_W := 340.0
const LIST_HEAD := 30.0           ## px of the list's header (deck, waves)
const LIST_LINE := 20.0           ## px per objective line (the flat list: no panel)
const LIST_MAX := 7               ## most lines shown (the flat list)
const ROW := 19.0                 ## px per row of the structured panel (headers, lines, route hints)
const PANEL_FRAC := 0.4           ## the panel never grows past this fraction of the screen height
const PANEL_TOP := 6.0            ## px above the structured panel's first row (it has no title row)
const INDENT := 16.0              ## px a deck's lines are indented under its header
const ROUTE_INDENT := 14.0        ## px a route hint is indented further under its line
const PAD := 8.0                  ## px under the last row
const ALERT_SIZE := Vector2(420, 28)
const ALERT_TOP := 118.0          ## the reinforcement line's top (82..110 is kept free)
## The INBOUND arrow toward a wave's source (screen-space, edge-stuck). ON (user decision 2026-11-23: "keep both", with
## the gate's beacon / klaxon); it points at a door, never at enemy units.
const SOURCE_ARROW := true
const ZONE_SIZE := Vector2(380, 40)
const ZONE_TOP := 154.0
const DEMO_PLAN := {"objective": "Proceed to deck 2", "plan": true, "deck": 0,
	"lines": ["Proceed to deck 2", "Clear deck 1: 0 hostiles, waves 3 / 3 (done)", "Bonus: Raise the flag: 60%",
		"Bonus: Defend the position: wave 1 / 2"],
	"waves": [3, 3], "zone": {"label": "RAISING THE FLAG", "progress": 12.0, "total": 20.0, "contested": false,
		"countdown": false, "percent": true},
	# The panel (MissionRules.panel() shape): on deck 1 of 3 with its sweep done and two bonuses found; deck 2 is the
	# next step (amber, with the way down), deck 3 unvisited.
	"panel": {"deck": 0, "decks": 3, "route_at": {}, "extra": [], "lines": [
		{"text": "Deck 1:", "role": "header", "deck": 0, "state": "", "current": true, "lead": false, "dir": 0},
		{"text": "Clear hostiles, waves 3/3", "role": "primary", "deck": 0, "state": "done", "current": false,
			"lead": false, "dir": 0},
		{"text": "Raise the flag: 60% (optional)", "role": "bonus", "deck": 0, "state": "active", "current": false,
			"lead": false, "dir": 0},
		{"text": "Defend the position: wave 1/2 (optional)", "role": "bonus", "deck": 0, "state": "known",
			"current": false, "lead": false, "dir": 0},
		{"text": "Deck 2:", "role": "header", "deck": 1, "state": "", "current": false, "lead": false, "dir": 0},
		{"text": "Proceed to deck 2", "role": "proceed", "deck": 1, "state": "", "current": false, "lead": true, "dir": 0},
		{"text": "ramp down 120 m", "role": "route", "deck": 1, "state": "", "current": false, "lead": true, "dir": 1},
		{"text": "Deck 3:", "role": "header", "deck": 2, "state": "", "current": false, "lead": false, "dir": 0},
		{"text": "Proceed to deck 3", "role": "proceed", "deck": 2, "state": "", "current": false, "lead": false,
			"dir": 0}]}}
const DEMO_MARK_AT := Vector2(0.3, 0.42)            ## viewport fraction of the demo's objective marker
const DEMO_RING := Rect2(0.42, 0.62, 0.16, 0.08)    ## viewport fraction of the demo's projected ring (an ellipse)
const DEMO_ALERT_DIR := Vector2(-1, 0.25)           ## the demo's reinforcement arrow sticks to the left edge
const DOWNED_SIZE := Vector2(460, 122)              ## the downed pilot's centre prompt
const DOWNED_Y := 150.0                             ## px below the screen centre: the prompt's centre (under the crosshair)
const DEMO_DOWNED := {"lines": ["Pickle is down: revive with a repair drone"],
	"marks": [{"demo": true, "label": "DOWN  Pickle", "revive": 0.4}],
	"prompt": {"title": "DOWN", "help": "Help is 34 m away", "revive": 0.25, "hold": 0.6, "hint": "Hold SPACE to respawn",
		"left": 0.0}}
const DEMO_DOWN_AT := Vector2(0.62, 0.38)           ## viewport fraction of the demo's downed-crewmate marker

var source: Callable
var from: Node3D
var demo := false
var demo_banner := false
var demo_plan := false
var downed_source: Callable       ## () -> {lines, marks, prompt} (DownedCrew.hud_state), invalid = nothing downed
var demo_downed := false
var downed_panel: Control
var _down: Dictionary = {}

var banner: Control
var markers: Control
var list_panel: Control
var alert_panel: Control
var zone_panel: Control
var _font: Font
var _state: Dictionary = {}
var _mark := ">"                  ## the viewer's deck header marker: U+25B6 when the HUD font has it (current_mark, _ready)


func _init() -> void:
	name = "MissionHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_mark = current_mark(_font)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	markers = MechHud.canvas("Markers", _draw_markers)
	add_child(markers)
	markers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banner = MechHud.canvas("Banner", _draw_banner)
	add_child(banner)
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	banner.offset_left = -BANNER_SIZE.x * 0.5
	banner.offset_right = BANNER_SIZE.x * 0.5
	banner.offset_top = -BANNER_SIZE.y * 0.5 - 140.0   # above the crosshair
	banner.offset_bottom = BANNER_SIZE.y * 0.5 - 140.0
	list_panel = MechHud.canvas("ObjectiveList", _draw_list)
	add_child(list_panel)
	list_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	list_panel.offset_left = -MechHud.MARGIN - LIST_W
	list_panel.offset_right = -MechHud.MARGIN
	list_panel.offset_top = OBJ_TOP
	list_panel.offset_bottom = OBJ_TOP + LIST_HEAD + LIST_LINE
	alert_panel = MechHud.canvas("Reinforcements", _draw_alert)
	add_child(alert_panel)
	_top_strip(alert_panel, ALERT_SIZE, ALERT_TOP)
	zone_panel = MechHud.canvas("ZoneProgress", _draw_zone)
	add_child(zone_panel)
	_top_strip(zone_panel, ZONE_SIZE, ZONE_TOP)
	downed_panel = MechHud.canvas("DownedPrompt", _draw_downed)
	add_child(downed_panel)
	downed_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	downed_panel.offset_left = -DOWNED_SIZE.x * 0.5
	downed_panel.offset_right = DOWNED_SIZE.x * 0.5
	downed_panel.offset_top = DOWNED_Y - DOWNED_SIZE.y * 0.5
	downed_panel.offset_bottom = DOWNED_Y + DOWNED_SIZE.y * 0.5
	_refresh()


## The most structured-panel rows that fit a screen `height` px tall within PANEL_FRAC (padding included).
static func max_rows(height: float) -> int:
	return maxi(int(floor((height * PANEL_FRAC - PANEL_TOP - PAD) / ROW)), 3)


## The viewer's deck header marker: the solid right triangle (U+25B6) when `font` draws it, else ">". Decided once, in
## _ready.
static func current_mark(font: Font) -> String:
	return String.chr(0x25B6) if font != null and font.has_char(0x25B6) else ">"


## The panel's rows fitted to `limit` rows (MissionRules.fit: every header kept, the depot line at the end of the
## viewer's section, never cut).
static func panel_rows(pn: Dictionary, limit: int) -> Array:
	return MissionRules.fit(pn, limit)


static func _row(text: String, role: String) -> Dictionary:
	return {"text": text, "role": role, "deck": -1, "state": "", "current": false, "lead": false, "dir": 0}


## The structured panel now (plan mode, MissionFlow's `panel`), {} when there is none (the flat list is drawn then).
func panel() -> Dictionary:
	if not bool(_state.get("plan", false)):
		return {}
	var pn: Variant = _state.get("panel", {})
	return pn if pn is Dictionary else {}


## The objective panel's top: OBJ_TOP when the screen is wide enough for it beside the centre strips, else under them.
static func list_top(width: float) -> float:
	if width * 0.5 - ALERT_SIZE.x * 0.5 >= LIST_W + MechHud.MARGIN + 8.0:
		return OBJ_TOP
	return ZONE_TOP + ZONE_SIZE.y + 8.0


func _top_strip(c: Control, sz: Vector2, top: float) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	c.offset_left = -sz.x * 0.5
	c.offset_right = sz.x * 0.5
	c.offset_top = top
	c.offset_bottom = top + sz.y


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	_state = state()
	_down = downed_state()
	if list_panel == null:
		return
	downed_panel.visible = not (_down.get("prompt", {}) as Dictionary).is_empty()
	downed_panel.queue_redraw()
	banner.visible = not (_state.get("banner", {}) as Dictionary).is_empty()
	var planned := bool(_state.get("plan", false))
	var lines := shown_lines()
	list_panel.visible = not lines.is_empty()
	list_panel.offset_top = list_top(get_viewport_rect().size.x)
	if not panel().is_empty():
		list_panel.offset_bottom = list_panel.offset_top + PANEL_TOP + ROW * float(maxi(lines.size(), 1)) + PAD
	else:
		list_panel.offset_bottom = list_panel.offset_top + LIST_HEAD + LIST_LINE * float(clampi(lines.size(), 1, LIST_MAX)) + 6.0
	alert_panel.visible = planned and not (_state.get("alerts", []) as Array).is_empty()
	zone_panel.visible = planned and not (_state.get("zone", {}) as Dictionary).is_empty()
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
			d["markers"] = [{"demo": true, "label": "DEFEND", "role": "bonus", "state": "known", "kind": "defend"}]

			d["rings"] = [{"demo": true}]
			d["alerts"] = [{"text": "Reinforcements, east gate", "pos": null, "left": 4.0, "demo": true}]
		return d
	if source.is_valid():
		var v: Variant = source.call()
		if v is Dictionary:
			return v
	return {"objective": "", "waypoint": {}, "banner": {}}


## The downed / revive state drawn now (see the header): {lines, marks, prompt}.
func downed_state() -> Dictionary:
	if demo_downed:
		return DEMO_DOWNED.duplicate(true)
	if downed_source.is_valid():
		var v: Variant = downed_source.call()
		if v is Dictionary:
			return v
	return {}


## The crew lines for the objective panel ("Pickle is down: revive with a repair drone").
func crew_lines() -> Array:
	return (_down.get("lines", []) as Array).duplicate()


## Where each downed crewmate's marker is drawn now: [{at, on_screen, dist, label, revive, dir?}].
func downed_points() -> Array:
	var out: Array = []
	var vs := get_viewport_rect().size
	var cam := get_viewport().get_camera_3d()
	for m: Variant in _down.get("marks", []):
		var md: Dictionary = m
		if bool(md.get("demo", false)):
			out.append({"at": vs * DEMO_DOWN_AT, "on_screen": true, "dist": 34.0, "label": md["label"],
				"revive": md.get("revive", 0.0)})
			continue
		if cam == null or not (md.get("pos") is Vector3):
			continue
		var o := screen_point(cam, md["pos"], vs, EDGE_PAD)
		o["dist"] = _origin(cam).distance_to(md["pos"])
		o["label"] = md.get("label", "")
		o["revive"] = md.get("revive", 0.0)
		out.append(o)
	return out


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


## The objective panel's lines now: with a panel, the text of its fitted rows (panel_rows); without one,
## MissionRules.lines(your deck), else the objective text alone; then the crew lines; [] when there is nothing to show
## (no plan: TEST-ONLY quiet fixture, only crew lines).
func shown_lines() -> Array:
	var lines: Array = []
	var pn := panel()
	if not pn.is_empty():
		for r: Dictionary in shown_rows():
			lines.append(str(r["text"]))
		return lines
	if bool(_state.get("plan", false)):
		lines = (_state.get("lines", []) as Array).duplicate()
		if lines.is_empty() and str(_state.get("objective", "")) != "":
			lines = [str(_state.get("objective", ""))]
	var crew := crew_lines()
	if not crew.is_empty():   # the crew lines are never cut: the objective lines make room
		lines = lines.slice(0, maxi(LIST_MAX - crew.size(), 0)) + crew
	return lines


## The structured panel's rows as drawn now (panel_rows fitted to this screen, room kept for the crew lines, which come
## last, after every deck section, as rows of role "crew"), [] without a panel.
func shown_rows() -> Array:
	var pn := panel()
	if pn.is_empty():
		return []
	var crew := crew_lines()
	var rows := panel_rows(pn, max_rows(get_viewport_rect().size.y) - crew.size())
	if rows.is_empty() and str(_state.get("objective", "")) != "":
		rows = [_row(str(_state.get("objective", "")), "primary")]
	for l: Variant in crew:
		rows.append(_row(str(l), "crew"))
	return rows


# --- Drawing ---------------------------------------------------------------------------------------------------

func _draw_markers(c: Control) -> void:
	if bool(_state.get("plan", false)):
		_draw_plan_marks(c)
	_draw_downed_marks(c)
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


## A downed crewmate's marker: a red cross in a ring, "DOWN  name  34m", the revive bar under it while a drone beams it.
func _draw_downed_marks(c: Control) -> void:
	for m: Dictionary in downed_points():
		var at: Vector2 = m["at"]
		var col := MechHud.RED
		var r := 10.0
		c.draw_arc(at, r, 0.0, TAU, 20, col, 2.0, true)
		c.draw_line(at + Vector2(-5, 0), at + Vector2(5, 0), col, 3.0)
		c.draw_line(at + Vector2(0, -5), at + Vector2(0, 5), col, 3.0)
		if not bool(m["on_screen"]) and m.has("dir"):
			draw_edge_arrow(c, at, m["dir"], r, col)
		_label(c, at, r, "%s  %dm" % [str(m["label"]), roundi(float(m["dist"]))], col)
		var rv := float(m.get("revive", 0.0))
		if rv > 0.0:
			var bar := Rect2(at + Vector2(-40, r + 22.0), Vector2(80, 4))
			if bar.end.y > c.size.y - 4.0:
				bar.position.y = at.y - r - 26.0
			c.draw_rect(bar, Color(MechHud.GREEN, 0.25), true)
			c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(rv, 0.0, 1.0), bar.size.y)), MechHud.GREEN, true)


## The downed pilot's centre prompt: "DOWN" + the help line + the revive bar (while beamed) + the hold hint and its bar;
## "REDEPLOYING  4 S" during the penalty.
func _draw_downed(c: Control) -> void:
	var p: Dictionary = _down.get("prompt", {})
	if p.is_empty():
		return
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	var redeploy := str(p.get("title", "")) == "REDEPLOYING"
	var col := MechHud.AMBER if redeploy else MechHud.RED
	c.draw_rect(Rect2(Vector2(0, 0), Vector2(r.size.x, 3)), col, true)
	var title := str(p.get("title", ""))
	if redeploy:
		title += "  %d S" % ceili(maxf(float(p.get("left", 0.0)), 0.0))
	c.draw_string_outline(_font, Vector2(0, 34), title, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 28, 4, Color(0, 0, 0, 0.7))
	c.draw_string(_font, Vector2(0, 34), title, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 28, col)
	if redeploy:
		c.draw_string(_font, Vector2(0, 62), "BACK IN THE FIGHT AT THE DECK ENTRY", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 13,
			MechHud.WHITE)
		return
	c.draw_string(_font, Vector2(0, 58), str(p.get("help", "")).to_upper(), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 14,
		MechHud.WHITE)
	var rv := float(p.get("revive", 0.0))
	if rv > 0.0:
		var rb := Rect2(Vector2(40, 66), Vector2(r.size.x - 80, 5))
		c.draw_rect(rb, Color(MechHud.GREEN, 0.25), true)
		c.draw_rect(Rect2(rb.position, Vector2(rb.size.x * clampf(rv, 0.0, 1.0), rb.size.y)), MechHud.GREEN, true)
	c.draw_string(_font, Vector2(0, 94), str(p.get("hint", "")).to_upper(), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 13,
		MechHud.AMBER)
	var hb := Rect2(Vector2(40, 104), Vector2(r.size.x - 80, 8))
	c.draw_rect(hb, Color(MechHud.AMBER, 0.2), true)
	c.draw_rect(Rect2(hb.position, Vector2(hb.size.x * clampf(float(p.get("hold", 0.0)), 0.0, 1.0), hb.size.y)),
		MechHud.AMBER, true)


func _label(c: Control, at: Vector2, r: float, text: String, col: Color) -> void:
	var tw := 150.0
	var ty := at.y + r + 16.0
	if ty > c.size.y - 8.0:
		ty = at.y - r - 8.0
	var x := clampf(at.x - tw * 0.5, 4.0, maxf(c.size.x - tw - 4.0, 4.0))
	c.draw_string_outline(_font, Vector2(x, ty), text, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, 4, Color(0, 0, 0, 0.8))
	c.draw_string(_font, Vector2(x, ty), text, HORIZONTAL_ALIGNMENT_CENTER, tw, 13, col)


## One row of the panel at baseline y. A header: "DECK 2:", the viewer's deck bright with the marker before it, the
## others dim. A deck's lines indented: the primary white, a bonus dimmer cyan, done green, failed red, the next step
## (`lead`: the proceed row, or a primary the crew must go back to) amber, a proceed row that is not the next step dim, a
## summary dim; lines of other decks than the viewer's (`here`) a little dimmer (amber stays). A route hint small,
## indented under its line, amber. The depot line indented, white; the crew lines red, flush left.
func _draw_row(c: Control, r: Dictionary, y: float, here: int) -> void:
	var w := c.size.x - 24.0
	var role := str(r["role"])
	var st := str(r.get("state", ""))
	var lead := bool(r.get("lead", false))
	var col := MechHud.WHITE
	var fs := 12
	var x := 12.0
	var t := str(r["text"]).to_upper()
	match role:
		"header":
			if bool(r.get("current", false)):
				c.draw_string(_font, Vector2(x, y), _mark, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MechHud.AMBER)
				x += _font.get_string_size(_mark + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
				fs = 13
			else:
				col = MechHud.DIM
		"route":
			col = MechHud.AMBER
			fs = 11
			x += INDENT + ROUTE_INDENT
		"crew":
			col = MechHud.RED
		"extra":
			x += INDENT
		"proceed", "summary":
			col = MechHud.AMBER if lead else MechHud.DIM
			x += INDENT
		_:
			x += INDENT
			if st == "done":
				col = MechHud.GREEN if role != "bonus" else Color(MechHud.GREEN, 0.7)
			elif st == "failed":
				col = MechHud.RED
			elif lead:
				col = MechHud.AMBER
			elif role == "bonus":
				col = Color(MechHud.CYAN, 0.72)
	if role != "header" and role != "crew" and role != "extra" and not lead and int(r.get("deck", here)) != here:
		col = Color(col, col.a * 0.8)
	var room := w - (x - 12.0)
	while fs > 9 and _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
		fs -= 1   # a long line shrinks a little rather than run past the panel
	c.draw_string(_font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, room, fs, col)


func _draw_list(c: Control) -> void:
	var pn := panel()
	if not pn.is_empty():
		var rect := Rect2(Vector2.ZERO, c.size)
		MechHud.draw_glass(c, rect)
		c.draw_rect(Rect2(Vector2(rect.size.x - 4, 0), Vector2(4, rect.size.y)), MechHud.AMBER, true)
		var here := int(pn.get("deck", 0))
		var ry := PANEL_TOP + 14.0
		for r: Dictionary in shown_rows():
			_draw_row(c, r, ry, here)
			ry += ROW
		return
	var lines := shown_lines()
	if lines.is_empty():
		return
	var r := Rect2(Vector2.ZERO, c.size)
	MechHud.draw_glass(c, r)
	c.draw_rect(Rect2(Vector2(r.size.x - 4, 0), Vector2(4, r.size.y)), MechHud.AMBER, true)
	var head := "DECK %d OBJECTIVES" % (int(_state.get("deck", 0)) + 1)
	c.draw_string(_font, Vector2(12, 20), head, HORIZONTAL_ALIGNMENT_LEFT, 200, 11, MechHud.DIM)
	var wv: Array = _state.get("waves", [])
	if wv.size() > 1 and int(wv[1]) > 0:
		c.draw_string(_font, Vector2(r.size.x - 132, 20), "WAVES %d / %d" % [int(wv[0]), int(wv[1])], HORIZONTAL_ALIGNMENT_RIGHT,
			116, 11, MechHud.AMBER)
	var y := LIST_HEAD + 12.0
	var crew := crew_lines()
	for i in mini(lines.size(), LIST_MAX):
		var t := str(lines[i])
		var col := MechHud.WHITE
		if crew.has(t):
			col = MechHud.RED
		elif t.ends_with("(done)"):
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
	var col := MechHud.CYAN if bool(a.get("ally", false)) else MechHud.RED   # the ally's line: a friend, not a threat
	c.draw_rect(Rect2(Vector2(0, 0), Vector2(4, r.size.y)), col, true)
	var left := float(a.get("left", 0.0))
	var t := str(a.get("text", "")).to_upper()
	if left > 0.0:
		t += "  %ds" % ceili(left)
	c.draw_string(_font, Vector2(14, r.size.y * 0.5 + 5), t, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 24, 14, col)


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
	if bool(z.get("percent", false)):
		right = "%d%%" % MissionRules.flag_percent(prog, tot, false)
	elif bool(z.get("countdown", false)):
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
