class_name DebriefBoard
extends PanelContainer
## The debrief board shown in the hangar after a mission (playtest R2.15a, modelled on bridge-to-friendship's M19
## between-rounds board): the outcome and mission time on top, then a grid with the pilots' names across the top row
## (seat order, bots by name) and one stat per row; each row's leaders are picked out in orange (DebriefStats.leaders:
## ties all lead, nothing marked when the whole crew ties). Built from DebriefStats.table(payload); presentation only.
## FrontEnd places it over the bay, right of the menu panel; its Next button (in the menu's footer) goes to the loadout.

const LABEL_W := 210.0       ## the stat-name column
const PILOT_W := 160.0       ## each pilot's column (long names are cut with an ellipsis)
const ROW_H := 34.0
const TITLE_SIZE := 30
const NAME_SIZE := 20
const STAT_SIZE := 18
const CELL_SIZE := 20
const ORANGE := Color(0.95, 0.6, 0.2)
const TEXT := Color(0.9, 0.9, 0.88)
const DIM := Color(0.62, 0.64, 0.68)
const GONE := Color(0.48, 0.5, 0.54)    ## a pilot who left mid-mission: the column greyed

var title_label: Label
var subtitle_label: Label
var grid: GridContainer
var name_labels: Array[Label] = []      ## the top row, one per pilot
var row_labels: Array[Label] = []       ## the stat names, one per row
var left_labels: Array[Label] = []      ## the "left" marks under the names of pilots who left mid-mission
var cells: Array = []                   ## per row: Array[Label], one per pilot
var shown: Dictionary = {}              ## the table last shown


func _init() -> void:
	name = "DebriefBoard"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.115, 0.985)   # near-opaque: nothing of the bay reads through the rows
	sb.border_color = Color(0.9, 0.48, 0.12)
	sb.set_border_width_all(2)
	sb.border_width_top = 4
	sb.set_content_margin_all(26)
	sb.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP


## Show `t` (DebriefStats.table). Rebuilds every child.
func show_table(t: Dictionary) -> void:
	shown = t
	for c in get_children():
		remove_child(c)
		c.queue_free()
	name_labels.clear()
	row_labels.clear()
	left_labels.clear()
	cells.clear()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)
	title_label = _label(str(t.get("title", "")), TITLE_SIZE, ORANGE)
	title_label.name = "Title"
	col.add_child(title_label)
	subtitle_label = _label(str(t.get("subtitle", "")), 17, DIM)
	subtitle_label.name = "Subtitle"
	col.add_child(subtitle_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	col.add_child(gap)
	var columns: Array = t.get("columns", [])
	grid = GridContainer.new()
	grid.name = "Grid"
	grid.columns = 1 + columns.size()
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	col.add_child(grid)
	var corner := _label("PILOT", 14, DIM)
	corner.custom_minimum_size = Vector2(LABEL_W, ROW_H + 6)
	corner.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	grid.add_child(corner)
	for c: Dictionary in columns:
		var gone := bool(c.get("left", false))
		var head := VBoxContainer.new()
		head.add_theme_constant_override("separation", 0)
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := _label(str(c["name"]), NAME_SIZE, GONE if gone else TEXT)
		l.name = "Pilot_%d" % int(c["id"]) if int(c["id"]) >= 0 else "Bot_%d" % -int(c["id"])
		l.custom_minimum_size = Vector2(PILOT_W, ROW_H + 6)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.tooltip_text = str(c["name"]) + ("  (bot)" if bool(c.get("bot", false)) else "")
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		head.add_child(l)
		if gone:   # left mid-mission: the column stays, greyed, marked under the name
			var tag := _label("left", 14, GONE)
			tag.name = "Left"
			tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			head.add_child(tag)
			left_labels.append(tag)
		grid.add_child(head)
		name_labels.append(l)
	# A rule under the names: one thin line per column.
	for i in grid.columns:
		var rule := ColorRect.new()
		rule.color = Color(0.9, 0.48, 0.12, 0.55)
		rule.custom_minimum_size = Vector2(0, 2)
		grid.add_child(rule)
	for r: Dictionary in t.get("rows", []):
		var rl := _label(str(r["label"]), STAT_SIZE, DIM.lightened(0.15))
		rl.custom_minimum_size = Vector2(LABEL_W, ROW_H)
		rl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		grid.add_child(rl)
		row_labels.append(rl)
		var row: Array[Label] = []
		var lead: Array = r.get("lead", [])
		var texts: Array = r.get("cells", [])
		for i in columns.size():
			var on := i < lead.size() and bool(lead[i])
			var gone := bool((columns[i] as Dictionary).get("left", false))
			var cl := _label(str(texts[i]) if i < texts.size() else "-", CELL_SIZE, ORANGE if on else (GONE if gone else TEXT))
			cl.custom_minimum_size = Vector2(PILOT_W, ROW_H)
			cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			if on:
				cl.add_theme_constant_override("outline_size", 2)
				cl.add_theme_color_override("font_outline_color", Color(0.35, 0.16, 0.02))
			grid.add_child(cl)
			row.append(cl)
		cells.append(row)


## True when column `i` of row `r` is marked as a leader.
func is_lead(r: int, i: int) -> bool:
	var rows: Array = shown.get("rows", [])
	if r < 0 or r >= rows.size():
		return false
	var lead: Array = (rows[r] as Dictionary).get("lead", [])
	return i >= 0 and i < lead.size() and bool(lead[i])


static func _label(t: String, size_: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size_)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
