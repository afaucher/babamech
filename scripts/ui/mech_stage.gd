class_name MechStage
extends SubViewportContainer
## The 3D preview beside the menus: its own SubViewport and World3D (sky, sun, a hangar floor disc, a camera) holding one
## mech on a turntable (the main menu, settings) or the crew's mechs in a line-up with name tags (the hangar). Drag to turn.
## Mechs are MechModel, the game's own builder.

const SPACING := 4.2

var viewport: SubViewport
var camera: Camera3D
var turntable: Node3D
var models: Array[MechModel] = []
var spin := 0.35            ## rad/s while nobody drags
var _yaw := 0.6
var _drag := false
var _last_key := ""


func _init() -> void:
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.size = Vector2i(960, 900)
	add_child(viewport)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.11, 0.13, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.6, 0.7)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	viewport.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.7, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	viewport.add_child(sun)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-4, 6, 5)
	rim.light_color = Color(1.0, 0.7, 0.4)
	rim.light_energy = 2.0
	rim.omni_range = 18.0
	viewport.add_child(rim)
	var floor_disc := MechParts.cylinder(9.0, 0.1, Color(0.22, 0.24, 0.27), Vector3(0, -0.05, 0), false, -1.0, 24)
	viewport.add_child(floor_disc)
	viewport.add_child(MechParts.cylinder(9.2, 0.06, Color(0.9, 0.48, 0.12), Vector3(0, -0.07, 0), false, -1.0, 24))
	turntable = Node3D.new()
	viewport.add_child(turntable)
	camera = Camera3D.new()
	camera.fov = 40.0
	viewport.add_child(camera)


## Show these mechs: [{head, chassis, loadout, name}]. One entry: a turntable; several: a line-up with name tags.
func show_mechs(entries: Array) -> void:
	var key := str(entries)
	if key == _last_key:
		return
	_last_key = key
	for m in turntable.get_children():
		turntable.remove_child(m)
		m.queue_free()
	models.clear()
	var n := entries.size()
	for i in n:
		var e: Dictionary = entries[i]
		var m := MechModel.new()
		m.configure(str(e.get("head", "chicken")), str(e.get("chassis", "strider")), e.get("loadout", {}) as Dictionary)
		m.position = Vector3((float(i) - float(n - 1) * 0.5) * SPACING, 0, 0)
		if n > 1:
			m.rotation.y = PI * 0.12 * (float(i) - float(n - 1) * 0.5)
		turntable.add_child(m)
		models.append(m)
		if n > 1 or str(e.get("name", "")) != "":
			var tag := Label3D.new()
			tag.text = str(e.get("name", ""))
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.font_size = 64
			tag.pixel_size = 0.006
			tag.outline_size = 12
			tag.position = m.position + Vector3(0, 5.6, 0)
			turntable.add_child(tag)
	spin = 0.35 if n <= 1 else 0.0
	_yaw = 0.6 if n <= 1 else 0.0
	_place_camera()


func _process(delta: float) -> void:
	if not _drag and spin > 0.0:
		_yaw += spin * delta
	turntable.rotation.y = _yaw
	_place_camera()


func _place_camera() -> void:
	var n := maxi(models.size(), 1)
	var dist := 10.5 + SPACING * 1.15 * float(n - 1)
	var target := Vector3(0, 2.4, 0)
	# The mechs face -Z, so the camera stands on the -Z side, a little to the right and above.
	var pos := target + Vector3(0.25 * dist, 0.25 * dist, -dist)
	camera.transform = Transform3D(Basis.looking_at(target - pos, Vector3.UP), pos)   # (works before the node is in a tree)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = (event as InputEventMouseButton).pressed
	elif event is InputEventMouseMotion and _drag:
		_yaw += (event as InputEventMouseMotion).relative.x * 0.01
