class_name MechStage
extends SubViewportContainer
## The 3D preview beside the menus: its own SubViewport and World3D holding one mech on a turntable (the main menu,
## settings) in an observation hall before a hull window onto the ring habitat (MenuBackdrop), or, in bay mode (the
## hangar screen), the crew's mechs in their alcoves along one wall of the assault boat's vehicle bay (HangarBay,
## docs/design/hangar.md), framed from this viewport's real size (HangarBay.camera_frame) so every mech fits the
## preview at any window shape. Drag to turn (in the bay: a small orbit, clamped to HangarBay.ORBIT_MAX so it never
## swings behind the wall). Mechs are MechModel.

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
var backdrop: MenuBackdrop      ## the turntable's set: the observation hall and its hull window (hidden in the bay)
var _turntable_set: Array[Node3D] = []   ## what the bay hides (it lights itself)
var _orbit := 0.0               ## the bay camera's small drag orbit (rad, within +-HangarBay.ORBIT_MAX)
var _env: Environment
const AMBIENT := Color(0.55, 0.6, 0.7)
const BAY_BG := Color(0.11, 0.13, 0.16)
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
	e.background_color = MenuBackdrop.BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.6, 0.7)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	viewport.add_child(env)
	_env = e
	backdrop = MenuBackdrop.new()
	backdrop.own_environment = false
	viewport.add_child(backdrop)
	_turntable_set = [backdrop]
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
		n.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT
	_env.background_color = BAY_BG if on else MenuBackdrop.BG


func _process(delta: float) -> void:
	if not _drag and spin > 0.0:
		_yaw += spin * delta
	turntable.rotation.y = 0.0 if in_bay else _yaw
	if in_bay:
		var k := bay.alert_amount() if bay != null else 0.0
		_env.ambient_light_color = AMBIENT.lerp(AMBIENT_ALERT, k)
		_env.ambient_light_energy = lerpf(0.6, 0.3, k)
	else:
		_env.ambient_light_color = MenuBackdrop.AMBIENT
		_env.ambient_light_energy = MenuBackdrop.AMBIENT_ENERGY
	_place_camera()


func _place_camera() -> void:
	if in_bay:
		var vs := Vector2(viewport.size)
		camera.fov = HangarBay.FOV
		camera.keep_aspect = Camera3D.KEEP_HEIGHT
		camera.transform = bay.camera_frame(vs.x / maxf(vs.y, 1.0), _orbit)
		bay.scale_tags(camera.global_position if camera.is_inside_tree() else camera.position)
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
			_orbit = clampf(_orbit - (event as InputEventMouseMotion).relative.x * 0.004, -HangarBay.ORBIT_MAX, HangarBay.ORBIT_MAX)
		else:
			_yaw += (event as InputEventMouseMotion).relative.x * 0.01
