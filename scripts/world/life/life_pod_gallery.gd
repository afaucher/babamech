class_name LifePodGallery
extends Node3D
## Lab subject `pod_gallery`: the nine candidate pod meshes (LifePodVariants) for the user to pick from, as a 3x3 on a
## patch of road (rows = body form cab / bubble / capsule, front to back; columns = stance a / b / c, left to right), each
## with a 1.8 m civilian (the civilian figure standing still) on the kerb beside its nose for scale, lit by the city "day" preset.
## Options: view (grid / single: one pod, orbit it with the lab camera), pod, angle (orbit = the lab's camera; the others
## are fixed framings: front / rear three-quarter, side, mech_eye = 9 m up and 25 m out at the chase camera's 70 deg FOV,
## i.e. how a pilot sees a pod).
##   .\run.ps1 --scene res://scenes/lab.tscn --subject pod_gallery --pods view=single,pod=cab_b,angle=side
## `--pods k=v,...` presets the options; `ui=hide` hides the lab panel (for screenshots); `shots=<dir>` renders every pod
## at front_three_quarter (podv_<id>.png) and mech_eye (podv_eye_<id>.png) into <dir>, plus both grids, then quits.

const VIEWS := ["grid", "single"]
const ANGLES := ["orbit", "front_three_quarter", "side", "rear_three_quarter", "mech_eye"]
const COL_X := 7.0                      ## grid spacing across (stances)
const ROW_Z := 9.0                      ## grid spacing front to back (forms)
const KERB_X := -1.45                   ## kerb line, on each pod's right (-X, nose +Z)
const KERB_H := 0.15
const PERSON := Vector3(-2.0, KERB_H, 1.7)

var options := {"view": "grid", "pod": "cab_a", "angle": "orbit"}
var time_scale := 1.0

var _rig: CityLightRig
var _cam: Camera3D
var _content: Node3D
var _hide_ui := false
var _shots := ""


func _init() -> void:
	name = "PodGallery"
	var arg := Boot.arg_value(OS.get_cmdline_user_args(), "--pods")
	for pair: String in arg.split(",", false):
		var kv := pair.split("=", true, 1)
		if kv.size() != 2:
			continue
		if options.has(kv[0]):
			options[kv[0]] = kv[1]
		elif kv[0] == "ui":
			_hide_ui = kv[1] == "hide"
		elif kv[0] == "shots":
			_shots = kv[1]
	_sanitize()


func _ready() -> void:
	_rig = CityLightRig.new()
	add_child(_rig)
	_rig.apply("day")
	_cam = Camera3D.new()
	_cam.name = "PodCamera"
	_cam.far = 400.0
	add_child(_cam)
	_content = Node3D.new()
	_content.name = "Pods"
	add_child(_content)
	rebuild()
	if _hide_ui or _shots != "":
		_hide_lab_ui.call_deferred()
	if _shots != "":
		_shoot_all.call_deferred()


func _sanitize() -> void:
	if not VIEWS.has(options["view"]):
		options["view"] = "grid"
	if not LifePodVariants.ids().has(options["pod"]):
		options["pod"] = "cab_a"
	if not ANGLES.has(options["angle"]):
		options["angle"] = "orbit"


func rebuild() -> void:
	if _content == null:
		return
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	var geo := CityGeo.new()
	var ext := _extent()
	geo.box(Transform3D.IDENTITY, Vector3(0.0, -0.05, 0.0), Vector3(ext.x, 0.1, ext.y), _c("asphalt"))
	if options["view"] == "single":
		_cell(geo, str(options["pod"]), Vector3.ZERO)
	else:
		var ids := LifePodVariants.ids()
		for i in ids.size():
			_cell(geo, ids[i], cell_origin(i))
	_content.add_child(geo.instance("Ground"))
	_apply_camera()


## Where pod number i (0..8, row-major: form, stance) stands in the grid.
static func cell_origin(i: int) -> Vector3:
	return Vector3((float(i % 3) - 1.0) * COL_X, 0.0, (1.0 - float(i / 3)) * ROW_Z)


func _extent() -> Vector2:
	return Vector2(70.0, 70.0) if options["view"] == "single" else Vector2(3.0 * COL_X + 60.0, 3.0 * ROW_Z + 60.0)


func _cell(ground: CityGeo, id: String, at: Vector3) -> void:
	# kerb and a strip of pavement on the pod's right, the person waiting on it
	var xf := Transform3D(Basis.IDENTITY, at)
	ground.box(xf, Vector3(KERB_X - 0.08, KERB_H * 0.5, 0.0), Vector3(0.16, KERB_H, 8.0), _c("curb"))
	ground.box(xf, Vector3(KERB_X - 0.16 - 0.9, KERB_H * 0.5, 0.0), Vector3(1.8, KERB_H, 8.0), _c("sidewalk"))
	ground.box(xf, Vector3(0.0, 0.004, -2.6), Vector3(1.6, 0.008, 0.12), _c("marking"))   # a stop line behind it
	var pod := MeshInstance3D.new()
	pod.name = "Pod_" + id
	pod.mesh = LifePodVariants.build(id)
	pod.position = at
	_content.add_child(pod)
	var fig := CityGeo.new()
	LifeAnimRig.static_figure(fig, 0)
	var person := fig.instance("Person_" + id)
	person.position = at + PERSON
	person.rotation.y = 0.7
	_content.add_child(person)


func _hide_lab_ui() -> void:
	var p := get_parent()
	if p == null:
		return
	for c in p.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = false


# --- Cameras ---------------------------------------------------------------------------------------------

## [azimuth deg from the nose (+Z) toward +X, elevation deg, distance m, fov deg, focus offset] for one pod.
static func framing(angle: String) -> Array:
	match angle:
		"side":
			return [90.0, 6.0, 7.4, 30.0, Vector3(0.0, 0.95, 0.3)]
		"rear_three_quarter":
			return [140.0, 12.0, 7.2, 30.0, Vector3(-0.3, 0.95, 0.0)]
		"mech_eye":
			return [40.0, rad_to_deg(asin(9.0 / 25.0)), 25.0, 70.0, Vector3(0.0, 0.9, 0.0)]
	return [40.0, 12.0, 6.9, 30.0, Vector3(-0.55, 0.95, 0.45)]


func _apply_camera() -> void:
	if _cam == null:
		return
	if options["angle"] == "orbit":
		if _cam.current:
			_cam.clear_current(true)
		return
	var f := framing(str(options["angle"]))
	var focus: Vector3 = f[4]
	var dist: float = f[2]
	if options["view"] == "grid":
		focus = Vector3(0.0, 0.9, 0.0)
		dist = dist * (3.4 if options["angle"] != "mech_eye" else 1.6)
	var az := deg_to_rad(float(f[0]))
	var el := deg_to_rad(float(f[1]))
	var dir := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	_cam.fov = float(f[3])
	var pos := focus + dir * dist
	_cam.transform = Transform3D(Basis.looking_at(focus - pos, Vector3.UP), pos)
	_cam.make_current()


func _shoot_all() -> void:
	DirAccess.make_dir_recursive_absolute(_shots)
	await get_tree().create_timer(1.0).timeout
	for id in LifePodVariants.ids():
		for ang: String in ["front_three_quarter", "mech_eye"]:
			options["view"] = "single"
			options["pod"] = id
			options["angle"] = ang
			rebuild()
			await _snap("%s/podv_%s%s.png" % [_shots, "eye_" if ang == "mech_eye" else "", id])
	for ang: String in ["front_three_quarter", "mech_eye"]:
		options["view"] = "grid"
		options["angle"] = ang
		rebuild()
		await _snap("%s/pod_gallery_grid_%s.png" % [_shots, ang])
	get_tree().quit()


func _snap(path: String) -> void:
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("shot %s %s" % [path, "ok" if err == OK else "error %d" % err])


static func _c(id: String) -> Color:
	return CityPalette.C[id]


# --- Lab contract ----------------------------------------------------------------------------------------

func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true


func lab_params() -> Array:
	return []


func set_lab_param(_id: String, _value: float) -> void:
	pass


func lab_options() -> Array:
	return [
		{"id": "view", "label": "View", "choices": VIEWS, "value": options["view"]},
		{"id": "pod", "label": "Pod (single view)", "choices": LifePodVariants.ids(), "value": options["pod"]},
		{"id": "angle", "label": "Camera angle", "choices": ANGLES, "value": options["angle"]},
	]


func set_lab_option(id: String, value: String) -> void:
	if not options.has(id):
		return
	options[id] = value
	_sanitize()
	if id == "angle":
		_apply_camera()
	else:
		rebuild()


func lab_focus() -> Vector3:
	return Vector3(0.0, 1.0, 0.0)


func lab_radius() -> float:
	return 3.6 if options["view"] == "single" else 14.0


## The pods face +Z; the lab's preset views look at a subject's -Z front, so turn them half a turn.
func lab_view_yaw() -> float:
	return PI
