class_name LoadingScreen
extends CanvasLayer
## The mission loading screen (docs/design/hud.md "Loading screen"): one OPAQUE layer over everything (above the HUD and
## ShaderWarmup's own overlay) from the first frame of the mission scene until the mission starts, then a FADE fade-out.
## MissionScene puts it up first thing in _ready, before anything is built, so no frame shows the city being built, the
## camera or the HUD; it comes down at mission_go (crew) or when the solo load and warm-up are done. The 3D viewport keeps
## rendering underneath (ShaderWarmup needs its meshes drawn): this only draws on top. It processes ALWAYS (a solo
## warm-up pauses the tree) and never touches input or the session: MissionScene's keepalive and Session polling go on.
##
## Shows, in the HUD's holo style (MechHud colours, MechHud.draw_glass) on a dark backdrop:
##   - the title and the mission ("Section 57036"), then the section (set_section: deck count, entry / extraction deck,
##     ramps / lifts / shafts) or "Charting the section..." before its plan is known;
##   - a progress bar and a phase line (set_phase): PHASES maps each phase to its share of the bar;
##   - in a crew, the crew list (crew_source: [{peer, name, head, accent, status: "ready" | "loading", local}]) with ready
##     ticks; the phase "crew" says how many are ready;
##   - a rotating tip line.
## Also covers scene changes: leaving the mission (phase "leave") puts one up, sets `handoff` and changes scene a frame
## later; the menu sees `handoff` and puts one up in its own _ready, faded out once the hangar has drawn (FrontEnd).
## Cosmetic and local: no state, no rolls (the first tip comes from the mission seed, then they rotate in order).

const LAYER := 125              ## above MechHud (5) and ShaderWarmup.OVERLAY_LAYER (120)
const FADE := 0.3               ## s of fade-out when the mission starts
const BG := Color(0.018, 0.03, 0.042)
const GRID := 48.0              ## backdrop grid step (px)
const COLUMN_W := 760.0         ## the centre column
const COLUMN_TOP := 0.17        ## its top, as a fraction of the screen height
const BAR_H := 22.0
const ROW_H := 40.0
const TIP_EVERY := 6.0          ## s per tip
const TITLE := "BABAMECH"

## phase -> [bar from, bar to, label]. The bar is from + (to - from) * the phase's own fraction.
const PHASES := {
	"chart": [0.0, 0.02, "Starting up"],
	"shaders_pre": [0.0, 0.05, "Preparing shaders"],
	"build": [0.05, 0.78, "Building the station"],
	"populate": [0.78, 0.88, "Populating the decks"],
	"shaders": [0.88, 1.0, "Preparing shaders"],
	"crew": [1.0, 1.0, "Waiting for crew"],
	"ready": [1.0, 1.0, "Ready"],
	"leave": [1.0, 1.0, "Returning to the hangar"],
	"launch": [0.0, 0.0, "Launching"],
}
const TIPS := [
	"Clear every deck, then reach the extraction portal.",
	"Shift runs. Space burns the thrusters: jump, hover, brake.",
	"Ramps and freight lifts link the decks.",
	"Weapons heat up. Watch the heat bar before you hold the trigger.",
	"Keys 1-5 pick a weapon. RMB zooms.",
	"A downed crewmate can be revived. Stay close.",
	"C switches between the chase and the cockpit view.",
	"Enemies stay on their own deck. Clear them one deck at a time.",
	"Enemy wind-ups flash before they fire: step out of the line.",
	"F1 shows the controls. Esc goes back to the hangar.",
]

## Tests (--run-test) take the screen down at once instead of fading it (a visual test shoots a few frames in), unless
## one sets this.
static var fade_in_tests := false
## A mission scene is being left behind a loading screen: the next scene (the menu) puts one up first and fades it.
static var handoff := false
## The text the handoff screen shows (the phase label).
static var handoff_phase := "leave"

## Returns the crew rows to show ([{peer, name, head, accent, status, local}]); empty / invalid = no crew list (solo).
var crew_source: Callable
var phase := "chart"
var fraction := 0.0              ## 0..1 within the phase
var progress := 0.0              ## 0..1 of the whole bar (from phase + fraction)
var shown := 0.0                 ## the bar as drawn (eases toward `progress`, never back)
var fading := false
var root: Control
var backdrop: Control
var column: VBoxContainer
var title_label: Label
var mission_label: Label
var section_label: Label
## The crew's friendly fire option (MissionScene.friendly_fire): appended to the section line ("Friendly fire on / off").
var friendly_fire := true
var card: PanelContainer
var phase_label: Label
var percent_label: Label
var bar: Bar
var crew_box: VBoxContainer
var crew_header: Label
var tip_label: Label
var rows: Array = []             ## the crew rows as last shown
signal gone()

var _t := 0.0
var _tip := 0
var _tip_t := 0.0
var _crew_t := 0.0


## The progress bar: glass, a segmented cyan fill and a sheen sweeping along it while it works.
class Bar extends Control:
	var value := 0.0
	var t := 0.0

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.02, 0.06, 0.08, 0.9), true)
		MechHud.draw_glass(self, r)   # first: its glass fill would dim the bar drawn under it
		var inner := r.grow(-4.0)
		var w := inner.size.x * clampf(value, 0.0, 1.0)
		if w > 0.5:
			draw_rect(Rect2(inner.position, Vector2(w, inner.size.y)), Color(MechHud.CYAN, 0.85), true)
			draw_rect(Rect2(inner.position, Vector2(w, inner.size.y * 0.35)), Color(1, 1, 1, 0.18), true)
			var sx := fmod(t * 0.45, 1.3) * inner.size.x - 60.0   # the sheen
			var s0 := clampf(sx, inner.position.x, inner.position.x + w)
			var s1 := clampf(sx + 60.0, inner.position.x, inner.position.x + w)
			if s1 > s0:
				draw_rect(Rect2(Vector2(s0, inner.position.y), Vector2(s1 - s0, inner.size.y)), Color(1, 1, 1, 0.22), true)
		var seg := 12.0   # segment gaps over the fill and the track alike
		var x := inner.position.x + seg
		while x < inner.end.x:
			draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Color(0.02, 0.06, 0.08, 0.9), 2.0)
			x += seg


## One crew member: a hex in its accent colour, its name and head, and LOADING (pulsing) or READY with a tick.
class CrewRow extends Control:
	var entry: Dictionary = {}
	var t := 0.0

	func _draw() -> void:
		var f := ThemeDB.fallback_font
		var r := Rect2(Vector2.ZERO, size)
		var ready_ := str(entry.get("status", "")) == "ready"
		draw_rect(r, Color(MechHud.GLASS, 0.35), true)
		draw_line(Vector2(0, size.y - 1), Vector2(size.x, size.y - 1), Color(MechHud.EDGE, 0.25), 1.0)
		var c := Vector2(22, size.y * 0.5)
		var hex := PackedVector2Array()
		for i in 7:
			var a := TAU * float(i) / 6.0 + PI / 6.0
			hex.append(c + Vector2(cos(a), sin(a)) * 11.0)
		draw_colored_polygon(hex.slice(0, 6), MechAccent.color(str(entry.get("accent", MechAccent.DEFAULT))))
		draw_polyline(hex, Color(MechHud.WHITE, 0.8), 1.5)
		var name_ := str(entry.get("name", "?"))
		if bool(entry.get("local", false)):
			name_ += "  (you)"
		draw_string(f, Vector2(44, size.y * 0.5 + 7), name_, HORIZONTAL_ALIGNMENT_LEFT, size.x * 0.45, 20, MechHud.WHITE)
		draw_string(f, Vector2(44 + size.x * 0.45, size.y * 0.5 + 6), str(entry.get("head", "")).capitalize(),
			HORIZONTAL_ALIGNMENT_LEFT, size.x * 0.25, 15, MechHud.DIM)
		var right := size.x - 14.0
		if ready_:
			draw_string(f, Vector2(right - 120, size.y * 0.5 + 6), "READY", HORIZONTAL_ALIGNMENT_RIGHT, 92, 16, MechHud.GREEN)
			var o := Vector2(right - 18, size.y * 0.5)
			draw_polyline(PackedVector2Array([o + Vector2(-7, 0), o + Vector2(-2, 6), o + Vector2(8, -7)]), MechHud.GREEN, 3.0)
		else:
			var a := 0.55 + 0.45 * sin(t * 5.0)
			var dots := ".".repeat(1 + int(t * 2.5) % 3)
			draw_string(f, Vector2(right - 120, size.y * 0.5 + 6), "LOADING", HORIZONTAL_ALIGNMENT_RIGHT, 92, 16,
				Color(MechHud.AMBER, a))
			draw_string(f, Vector2(right - 26, size.y * 0.5 + 6), dots, HORIZONTAL_ALIGNMENT_LEFT, 30, 16, Color(MechHud.AMBER, a))


## Put a loading screen up on `parent` (it builds itself in _ready, so it is up before the parent's next line runs).
static func cover(parent: Node) -> LoadingScreen:
	var ls := LoadingScreen.new()
	ls.name = "LoadingScreen"
	parent.add_child(ls)
	return ls


static func _testing() -> bool:
	return OS.get_cmdline_user_args().has("--run-test")


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop = Control.new()
	backdrop.name = "Backdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.draw.connect(_draw_backdrop)
	column = VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 10)
	root.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	column.anchor_top = COLUMN_TOP   # a fixed top: the column grows down when the crew list comes, nothing jumps
	column.offset_top = 0.0
	column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	column.grow_vertical = Control.GROW_DIRECTION_END
	column.custom_minimum_size = Vector2(COLUMN_W, 0)
	title_label = _label("Title", TITLE, 64, MechHud.CYAN)
	title_label.add_theme_constant_override("outline_size", 0)
	mission_label = _label("Mission", "", 30, MechHud.WHITE)
	section_label = _label("Section", "Charting the section...", 18, MechHud.DIM)
	section_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 26)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(gap)
	card = PanelContainer.new()
	card.name = "Card"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxEmpty.new()
	sb.set_content_margin_all(20)
	card.add_theme_stylebox_override("panel", sb)
	column.add_child(card)
	card.draw.connect(func() -> void: MechHud.draw_glass(card, Rect2(Vector2.ZERO, card.size)))
	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 10)
	card.add_child(inner)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(line)
	phase_label = Label.new()
	phase_label.name = "Phase"
	phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_label.add_theme_font_size_override("font_size", 22)
	phase_label.add_theme_color_override("font_color", MechHud.WHITE)
	line.add_child(phase_label)
	percent_label = Label.new()
	percent_label.name = "Percent"
	percent_label.add_theme_font_size_override("font_size", 22)
	percent_label.add_theme_color_override("font_color", MechHud.CYAN)
	line.add_child(percent_label)
	bar = Bar.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(bar)
	crew_box = VBoxContainer.new()
	crew_box.name = "Crew"
	crew_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crew_box.add_theme_constant_override("separation", 4)
	crew_box.visible = false
	inner.add_child(crew_box)
	crew_header = Label.new()
	crew_header.name = "CrewHeader"
	crew_header.text = "CREW"
	crew_header.add_theme_font_size_override("font_size", 15)
	crew_header.add_theme_color_override("font_color", MechHud.DIM)
	crew_box.add_child(crew_header)
	tip_label = Label.new()
	tip_label.name = "Tip"
	tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip_label.add_theme_font_size_override("font_size", 18)
	tip_label.add_theme_color_override("font_color", Color(MechHud.DIM, 0.95))
	tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(tip_label)
	tip_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	tip_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	tip_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	tip_label.offset_bottom = -48
	tip_label.custom_minimum_size = Vector2(COLUMN_W, 0)
	_show_tip()
	set_phase(phase, 0.0)


func _label(nm: String, text: String, size_: int, col: Color) -> Label:
	var l := Label.new()
	l.name = nm
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size_)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(l)
	return l


## The mission line: "Section 57036"; the first tip follows from the seed. `mode` is always the stack (kept for callers).
func set_mission(seed_value: int, _mode: String = NetMission.MODE_STACK) -> void:
	mission_label.text = "Section %d" % seed_value
	_tip = absi(seed_value) % TIPS.size()
	_show_tip()


## The section line from its plan: decks, entry and extraction deck, how the decks connect.
func set_section(sec: SectionPlan) -> void:
	section_label.text = section_text(sec) + _ff_suffix()


func _ff_suffix() -> String:
	return "  ·  Friendly fire %s" % ("on" if friendly_fire else "off")


## "4 decks · entry deck 1 · extraction deck 4 · 3 ramps, 2 lifts" (decks counted from 1 at the top).
static func section_text(sec: SectionPlan) -> String:
	if sec == null:
		return "Charting the section..."
	var parts: PackedStringArray = ["%d deck%s" % [sec.deck_count, "" if sec.deck_count == 1 else "s"]]
	if sec.entry.has("deck"):
		parts.append("entry deck %d" % (int(sec.entry["deck"]) + 1))
	if sec.extraction.has("deck"):
		parts.append("extraction deck %d" % (int(sec.extraction["deck"]) + 1))
	var kinds := {}
	for c: Variant in sec.connectors:
		var k := str((c as Dictionary).get("kind", ""))
		kinds[k] = int(kinds.get(k, 0)) + 1
	var links: PackedStringArray = []
	for k: String in ["ramp", "lift", "shaft"]:
		var n := int(kinds.get(k, 0))
		if n > 0:
			links.append("%d %s%s" % [n, k, "" if n == 1 else "s"])
	if not links.is_empty():
		parts.append(", ".join(links))
	return "  ·  ".join(parts)


## Move to `phase_id` (a PHASES key) at `f` (0..1) through it. The bar never goes back.
func set_phase(phase_id: String, f: float = 0.0) -> void:
	phase = phase_id if PHASES.has(phase_id) else phase
	fraction = clampf(f, 0.0, 1.0)
	var ph: Array = PHASES[phase]
	progress = maxf(progress, lerpf(float(ph[0]), float(ph[1]), fraction))
	if phase == "leave" or phase == "launch":
		shown = progress
	_refresh_text()


func phase_text() -> String:
	var t := str((PHASES[phase] as Array)[2])
	if phase == "crew" and not rows.is_empty():
		var n := rows.filter(func(e: Dictionary) -> bool: return str(e.get("status", "")) == "ready").size()
		t += "  %d / %d ready" % [n, rows.size()]
	elif phase != "ready":
		t += "..."
	return t


func _refresh_text() -> void:
	if phase_label == null:
		return
	phase_label.text = phase_text()
	percent_label.text = "%d%%" % clampi(int(shown * 100.0 + 0.001), 0, 100)
	percent_label.visible = phase != "leave" and phase != "launch"
	bar.visible = percent_label.visible


## Read the crew rows now (crew_source) and rebuild the list.
func refresh_crew() -> void:
	var now: Array = []
	if crew_source.is_valid():
		now = crew_source.call()
	rows = now
	crew_box.visible = not rows.is_empty()
	var have := crew_box.get_child_count() - 1
	for i in range(have, rows.size()):
		var r := CrewRow.new()
		r.name = "Member%d" % i
		r.custom_minimum_size = Vector2(0, ROW_H)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crew_box.add_child(r)
	for i in range(crew_box.get_child_count() - 1, rows.size(), -1):
		var old := crew_box.get_child(i)
		crew_box.remove_child(old)
		old.queue_free()
	for i in rows.size():
		var r := crew_box.get_child(i + 1) as CrewRow
		r.entry = rows[i]


## The crew row controls (tests).
func crew_rows() -> Array[Control]:
	var out: Array[Control] = []
	if crew_box == null:
		return out
	for i in range(1, crew_box.get_child_count()):
		out.append(crew_box.get_child(i) as Control)
	return out


## Fully up (opaque, not fading).
func covering() -> bool:
	return is_inside_tree() and visible and not fading and root != null and root.modulate.a >= 0.999


## Take the screen down: a FADE fade-out (at once under tests unless fade_in_tests), then free. `gone` fires at the end.
func finish(fade: float = FADE) -> void:
	if fading:
		return
	fading = true
	if fade <= 0.0 or (_testing() and not fade_in_tests) or not is_inside_tree():
		_done()
		return
	set_phase("ready", 1.0)
	shown = 1.0
	_refresh_text()
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(root, "modulate:a", 0.0, fade)
	tw.tween_callback(_done)


func _done() -> void:
	gone.emit()
	queue_free()


func _show_tip() -> void:
	if tip_label != null:
		tip_label.text = TIPS[_tip % TIPS.size()]


func _process(delta: float) -> void:
	_t += delta
	_tip_t += delta
	if _tip_t >= TIP_EVERY:
		_tip_t = 0.0
		_tip += 1
		_show_tip()
	_crew_t -= delta
	if _crew_t <= 0.0:
		_crew_t = 0.1
		refresh_crew()
	shown = minf(progress, shown + maxf(progress - shown, 0.02) * minf(delta * 6.0, 1.0))
	bar.value = shown
	bar.t = _t
	bar.queue_redraw()
	for r: Control in crew_rows():
		(r as CrewRow).t = _t
		r.queue_redraw()
	_refresh_text()
	backdrop.queue_redraw()


## The backdrop: near-black blue, a faint holo grid drifting slowly, a cyan horizon line behind the title and a vignette.
func _draw_backdrop() -> void:
	var s := backdrop.size
	backdrop.draw_rect(Rect2(Vector2.ZERO, s), BG, true)
	var off := fmod(_t * 6.0, GRID)
	var g := Color(MechHud.CYAN, 0.045)
	var x := -off
	while x < s.x:
		backdrop.draw_line(Vector2(x, 0), Vector2(x, s.y), g, 1.0)
		x += GRID
	var y := -off
	while y < s.y:
		backdrop.draw_line(Vector2(0, y), Vector2(s.x, y), g, 1.0)
		y += GRID
	var hy := column.get_global_rect().position.y - 18.0 if column != null else s.y * 0.3
	backdrop.draw_line(Vector2(s.x * 0.15, hy), Vector2(s.x * 0.85, hy), Color(MechHud.CYAN, 0.25), 1.0)
	var scan := fmod(_t * 90.0, s.y + 200.0) - 100.0   # a slow scan band
	backdrop.draw_rect(Rect2(0, scan, s.x, 3), Color(MechHud.CYAN, 0.035), true)
	for i in 6:   # vignette: darker bands toward the edges
		var k := float(i) * 28.0
		var a := 0.07
		backdrop.draw_rect(Rect2(k, k, s.x - 2.0 * k, s.y - 2.0 * k), Color(0, 0, 0, a), false, 28.0)
