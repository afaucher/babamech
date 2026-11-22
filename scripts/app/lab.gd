class_name Lab
extends Node3D
## The lab (scenes/lab.tscn), modelled on flap's bird lab: one subject at a time from LabRegistry on a floor grid, its
## tunable params as sliders and its options as drop-downs (built from the subject's lab contract), an orbit camera with
## named views, pause / speed for anything animated, reset to defaults.
##   .\lab.ps1 [subject] [-View side|front|three|top]
##   .\run.ps1 --scene res://scenes/lab.tscn [--subject <id>] [--view <v>] [--shot <png> [--shot-after <s>]]
## Keys: Up/Down subject, Space pause, R reset params, V next view, -/= speed, Esc back to the menu; drag to orbit,
## wheel to zoom.

const VIEWS := {
	"three": Vector2(0.75, 0.35),   # (yaw, pitch) radians; yaw 0 = in front (the mech faces -Z)
	"front": Vector2(0.0, 0.12),
	"side": Vector2(PI / 2.0, 0.1),
	"top": Vector2(0.0, 1.45),
}
const VIEW_ORDER := ["three", "front", "side", "top"]

var subject: Node3D
var subject_id := ""
var view := "three"
var speed := 1.0
var paused := false
var cam: Camera3D

var _defaults: Dictionary = {}     ## param id -> default (the subject's values when it was made)
var _yaw := 0.75
var _pitch := 0.35
var _dist := 8.0
var _drag := false
var _ui: VBoxContainer
var _subject_pick: OptionButton
var _params_box: VBoxContainer
var _speed_label: Label
var _status: Label
var _lab_floor: Node3D               ## the grid floor; hidden for subjects with their own ground (lab_own_ground())


func _ready() -> void:
	_build_world()
	_build_ui()
	var args := OS.get_cmdline_user_args()
	var want := Boot.arg_value(args, "--subject")
	var v := Boot.arg_value(args, "--view")
	if VIEWS.has(v):
		view = v
	pick(want if LabRegistry.find(want).size() > 0 else str(LabRegistry.SUBJECTS[0]["id"]))
	# --opt <id>=<value> / --param <id>=<value> (repeatable): preset the subject for a screenshot.
	for i in args.size() - 1:
		var kv := args[i + 1].split("=")
		if kv.size() == 2 and subject != null:
			if args[i] == "--opt":
				subject.set_lab_option(kv[0], kv[1])
			elif args[i] == "--param" and kv[1].is_valid_float():
				subject.set_lab_param(kv[0], float(kv[1]))
	if args.has("--opt") or args.has("--param"):
		_rebuild_params()
		_dist = float(subject.lab_radius()) * 2.0
	var shot := Boot.arg_value(args, "--shot")
	if shot != "":
		var after := float(Boot.arg_value(args, "--shot-after")) if Boot.arg_value(args, "--shot-after").is_valid_float() else 1.5
		_shot.call_deferred(shot, after)


## Show subject `id` (defaults restored).
func pick(id: String) -> void:
	if subject != null:
		remove_child(subject)
		subject.queue_free()
	subject_id = id
	subject = LabRegistry.make(id)
	if subject == null:
		push_error("[Lab] unknown subject " + id)
		return
	add_child(subject)
	if _lab_floor != null:
		_lab_floor.visible = not (subject.has_method("lab_own_ground") and subject.lab_own_ground())
	_defaults.clear()
	for p: Dictionary in subject.lab_params():
		_defaults[p["id"]] = float(p["value"])
	_dist = float(subject.lab_radius()) * 2.0
	set_view(view)
	_apply_time()
	var i := LabRegistry.ids().find(id)
	if _subject_pick != null and _subject_pick.selected != i:
		_subject_pick.select(i)
	_rebuild_params()


func set_view(v: String) -> void:
	view = v
	_yaw = (VIEWS[v] as Vector2).x
	_pitch = (VIEWS[v] as Vector2).y
	_place_camera()


func reset_params() -> void:
	for id: String in _defaults:
		subject.set_lab_param(id, _defaults[id])
	_rebuild_params()


func set_speed(v: float) -> void:
	speed = clampf(v, 0.05, 4.0)
	_apply_time()


func toggle_pause() -> void:
	paused = not paused
	_apply_time()


func _apply_time() -> void:
	if subject != null and "time_scale" in subject:
		subject.set("time_scale", 0.0 if paused else speed)
	if _speed_label != null:
		_speed_label.text = "Speed %.2fx%s" % [speed, "  (paused)" if paused else ""]


func _process(_delta: float) -> void:
	_place_camera()
	if _status != null and subject != null:
		_status.text = "%s   view: %s   %s" % [subject_id, view, "paused" if paused else "%.2fx" % speed]


func _place_camera() -> void:
	if cam == null or subject == null:
		return
	var target: Vector3 = subject.lab_focus()
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), -cos(_yaw) * cos(_pitch))
	var pos := target + dir * _dist
	var up := Vector3.UP if absf(_pitch) < 1.5 else Vector3(0, 0, -1)
	cam.transform = Transform3D(Basis.looking_at(target - pos, up), pos)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist * 0.9, 1.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.1, 80.0)
	elif e is InputEventMouseMotion and _drag:
		var mm := e as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch + mm.relative.y * 0.008, -0.2, 1.5)
	elif e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		var ids := LabRegistry.ids()
		match (e as InputEventKey).keycode:
			KEY_SPACE: toggle_pause()
			KEY_R: reset_params()
			KEY_V: set_view(VIEW_ORDER[(VIEW_ORDER.find(view) + 1) % VIEW_ORDER.size()])
			KEY_MINUS: set_speed(speed * 0.5)
			KEY_EQUAL: set_speed(speed * 2.0)
			KEY_UP: pick(ids[(ids.find(subject_id) - 1 + ids.size()) % ids.size()])
			KEY_DOWN: pick(ids[(ids.find(subject_id) + 1) % ids.size()])
			KEY_ESCAPE: _back()


func _back() -> void:
	get_tree().change_scene_to_file(Boot.MENU_SCENE)


# --- World ------------------------------------------------------------------------------------------

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.72)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.95, 0.6, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	_lab_floor = Node3D.new()
	_lab_floor.name = "LabFloor"
	add_child(_lab_floor)
	var ground := MechParts.box(Vector3(40, 0.1, 40), Color(0.3, 0.32, 0.34), Vector3(0, -0.05, 0))
	_lab_floor.add_child(ground)
	var line := Color(0.4, 0.42, 0.45)
	for i in range(-10, 11):
		_lab_floor.add_child(MechParts.box(Vector3(40, 0.012, 0.02), line, Vector3(0, 0.005, float(i) * 2.0)))
		_lab_floor.add_child(MechParts.box(Vector3(0.02, 0.012, 40), line, Vector3(float(i) * 2.0, 0.005, 0)))
	# A 1 m marker and the forward arrow (-Z), for scale.
	_lab_floor.add_child(MechParts.box(Vector3(0.1, 1.0, 0.1), Color(0.9, 0.48, 0.12), Vector3(3.0, 0.5, 0)))
	_lab_floor.add_child(MechParts.box(Vector3(0.08, 0.02, 1.5), Color(0.3, 0.7, 1.0), Vector3(0, 0.02, -2.5)))
	cam = Camera3D.new()
	cam.fov = 45.0
	add_child(cam)


# --- UI ---------------------------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	layer.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	_ui = VBoxContainer.new()
	_ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_ui)
	var title := Label.new()
	title.text = "LAB"
	title.add_theme_font_size_override("font_size", 28)
	_ui.add_child(title)
	_subject_pick = OptionButton.new()
	for s: Dictionary in LabRegistry.SUBJECTS:
		_subject_pick.add_item(str(s["label"]))
	_subject_pick.item_selected.connect(func(i: int) -> void: pick(LabRegistry.ids()[i]))
	_ui.add_child(_subject_pick)
	var views := HBoxContainer.new()
	for v: String in VIEW_ORDER:
		var b := Button.new()
		b.text = v
		b.pressed.connect(set_view.bind(v))
		views.add_child(b)
	_ui.add_child(views)
	var time := HBoxContainer.new()
	var pause := Button.new()
	pause.text = "Pause"
	pause.pressed.connect(toggle_pause)
	time.add_child(pause)
	var slower := Button.new()
	slower.text = "-"
	slower.pressed.connect(func() -> void: set_speed(speed * 0.5))
	time.add_child(slower)
	var faster := Button.new()
	faster.text = "+"
	faster.pressed.connect(func() -> void: set_speed(speed * 2.0))
	time.add_child(faster)
	_speed_label = Label.new()
	time.add_child(_speed_label)
	_ui.add_child(time)
	var reset := Button.new()
	reset.text = "Reset params"
	reset.pressed.connect(reset_params)
	_ui.add_child(reset)
	_params_box = VBoxContainer.new()
	_ui.add_child(_params_box)
	var back := Button.new()
	back.text = "Back to menu"
	back.pressed.connect(_back)
	_ui.add_child(back)
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_status.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_status.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_status.offset_right = -12
	_status.offset_bottom = -8
	layer.add_child(_status)


func _rebuild_params() -> void:
	if _params_box == null or subject == null:
		return
	for c in _params_box.get_children():
		_params_box.remove_child(c)
		c.queue_free()
	for o: Dictionary in subject.lab_options():
		var l := Label.new()
		l.text = str(o["label"])
		_params_box.add_child(l)
		var ob := OptionButton.new()
		var choices: Array = o["choices"]
		for ch: Variant in choices:
			ob.add_item("(none)" if str(ch) == "" else str(ch))
		ob.select(maxi(choices.find(o["value"]), 0))
		var oid := str(o["id"])
		ob.item_selected.connect(func(i: int) -> void:
			subject.set_lab_option(oid, str(choices[i]))
			_rebuild_params.call_deferred())
		_params_box.add_child(ob)
	for p: Dictionary in subject.lab_params():
		var l := Label.new()
		var pid := str(p["id"])
		var plabel := str(p["label"])
		l.text = "%s: %.2f" % [plabel, float(p["value"])]
		_params_box.add_child(l)
		var s := HSlider.new()
		s.min_value = float(p["min"])
		s.max_value = float(p["max"])
		s.step = (s.max_value - s.min_value) / 200.0
		s.value = float(p["value"])
		s.value_changed.connect(func(v: float) -> void:
			subject.set_lab_param(pid, v)
			l.text = "%s: %.2f" % [plabel, v])
		_params_box.add_child(s)


func _shot(path: String, after: float) -> void:
	await get_tree().create_timer(after).timeout
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("shot %s %s" % [path, "ok" if err == OK else "error %d" % err])
	get_tree().quit()
