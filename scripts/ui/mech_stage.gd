class_name MechStage
extends SubViewportContainer
## The 3D preview beside the menus: its own SubViewport and World3D (sky, sun, a hangar floor disc, a camera) holding one
## mech on a turntable (the main menu, settings), or, in bay mode (the hangar screen), the crew's mechs in their cradles
## inside the assault boat's vehicle bay (HangarBay, docs/design/hangar.md). Drag to turn. Mechs are MechModel.

const SPACING := 4.2

var viewport: SubViewport
var camera: Camera3D
var turntable: Node3D
var models: Array[MechModel] = []
var spin := 0.35            ## rad/s while nobody drags
var _yaw := 0.6
var _drag := false
var _last_key := ""
var bay: HangarBay              ## the hangar set, built on first use of bay mode
var in_bay := false
var _turntable_set: Array[Node3D] = []   ## the sun, rim light and floor disc (hidden in the bay, which lights itself)
var _orbit := 0.0               ## the bay camera's small drag orbit (rad)
var _env: Environment
const AMBIENT := Color(0.55, 0.6, 0.7)
const AMBIENT_ALERT := Color(0.6, 0.25, 0.22)   ## the bay's ambient turns dim red in alert


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
	_env = e
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
	var floor_rim := MechParts.cylinder(9.2, 0.06, Color(0.9, 0.48, 0.12), Vector3(0, -0.07, 0), false, -1.0, 24)
	viewport.add_child(floor_rim)
	_turntable_set = [sun, rim, floor_disc, floor_rim]
	turntable = Node3D.new()
	viewport.add_child(turntable)
	camera = Camera3D.new()
	camera.fov = 40.0
	viewport.add_child(camera)


## Show these mechs: [{head, chassis, loadout, name}]. One entry: a turntable; several: a line-up with name tags.
## `in_bay_` true puts them in the hangar bay's cradles instead (at most four).
func show_mechs(entries: Array, in_bay_: bool = false) -> void:
	var key := str(entries) + str(in_bay_)
	if key == _last_key:
		return
	_last_key = key
	for m in turntable.get_children():
		turntable.remove_child(m)
		m.queue_free()
	models.clear()
	_set_bay(in_bay_)
	if in_bay_:
		models = bay.show_crew(entries)
		spin = 0.0
		_orbit = 0.0
		_place_camera()
		return
	var n := entries.size()
	for i in n:
		var e: Dictionary = entries[i]
		var m := MechModel.new()
		m.configure(str(e.get("head", "chicken")), str(e.get("chassis", "strider")), e.get("loadout", {}) as Dictionary)
		MechAccent.apply(m, str(e.get("accent", MechAccent.DEFAULT)))
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
			tag.position = m.position + Vector3(0, HangarBay.tag_height(m), 0)
			turntable.add_child(tag)
	spin = 0.35 if n <= 1 else 0.0
	_yaw = 0.6 if n <= 1 else 0.0
	_place_camera()


## The bay's launch alert (beacons, strobes, clamps open). Only in bay mode.
func set_alert(on: bool) -> void:
	if bay != null and in_bay:
		bay.set_alert(on)


func _set_bay(on: bool) -> void:
	if on and bay == null:
		bay = HangarBay.new()
		bay.own_environment = false
		viewport.add_child(bay)
	in_bay = on
	if bay != null:
		bay.visible = on
		bay.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		if not on:
			bay.set_alert(false)
	for n in _turntable_set:
		n.visible = not on


func _process(delta: float) -> void:
	if not _drag and spin > 0.0:
		_yaw += spin * delta
	turntable.rotation.y = 0.0 if in_bay else _yaw
	var k := bay.alert_amount() if in_bay and bay != null else 0.0
	_env.ambient_light_color = AMBIENT.lerp(AMBIENT_ALERT, k)
	_env.ambient_light_energy = lerpf(0.6, 0.3, k)
	_place_camera()


func _place_camera() -> void:
	if in_bay:
		var cam: Array = HangarBay.camera_for(models.size())
		var target: Vector3 = cam[1]
		var pos: Vector3 = target + (cam[0] - target).rotated(Vector3.UP, _orbit)
		camera.fov = 50.0
		camera.transform = Transform3D(Basis.looking_at(target - pos, Vector3.UP), pos)
		return
	camera.fov = 40.0
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
		if in_bay:
			_orbit = clampf(_orbit - (event as InputEventMouseMotion).relative.x * 0.004, -0.45, 0.45)
		else:
			_yaw += (event as InputEventMouseMotion).relative.x * 0.01
