class_name MechPartGallery
extends Node3D
## Lab subject: the low-poly art parts of the mech (MechMeshes), each on its own: every part laid out in rows by group
## (chassis, legs, weapons, heads), or one part alone, turning. A small marker shows the origin of each part (its pivot:
## the proximal joint of a leg segment, the mount point of a weapon, the neck base of a head).

const PARAMS := [
	{"id": "spacing", "label": "Spacing", "min": 1.5, "max": 4.0, "value": 2.4},
	{"id": "spin", "label": "Spin (rad/s)", "min": 0.0, "max": 3.0, "value": 0.5},
	{"id": "pivots", "label": "Pivot markers (0/1)", "min": 0.0, "max": 1.0, "value": 1.0},
]

var params: Dictionary = {}
var part := "all"
var time_scale := 1.0
var _spinners: Array[Node3D] = []
var _rows := 1
var _cols := 1


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_spinners.clear()
	if part != "all":
		_rows = 1
		_cols = 1
		_add(part, Vector3(0, 1.4, 0))
		return
	var groups: Array = [MechMeshes.BODY_PARTS, MechMeshes.LEG_PARTS, [], []]
	for w: String in MechMeshes.WEAPONS:
		(groups[2] as Array).append("weapon_" + w)
	for h: String in MechMeshes.HEADS:
		(groups[3] as Array).append("head_" + h)
	var sp := float(params["spacing"])
	_rows = groups.size()
	_cols = 0
	for r in groups.size():
		var g: Array = groups[r]
		_cols = maxi(_cols, g.size())
		for i in g.size():
			_add(str(g[i]), Vector3((float(i) - float(g.size() - 1) * 0.5) * sp, 1.4, (float(r) - float(_rows - 1) * 0.5) * sp))


func _add(id: String, at: Vector3) -> void:
	var holder := Node3D.new()
	holder.position = at
	add_child(holder)
	holder.add_child(MechMeshes.instance(id))
	if float(params["pivots"]) >= 0.5:
		holder.add_child(MechParts.sphere(0.04, Color(1.0, 0.1, 0.8), Vector3.ZERO, 6))
	_spinners.append(holder)
	var label := Label3D.new()
	label.text = id
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.005
	label.position = at + Vector3(0, -1.3, 0)
	add_child(label)


func _process(delta: float) -> void:
	for h in _spinners:
		h.rotation.y += float(params["spin"]) * delta * time_scale


func lab_params() -> Array:
	var out: Array = []
	for p: Dictionary in PARAMS:
		var d := p.duplicate()
		d["value"] = params[p["id"]]
		out.append(d)
	return out


func set_lab_param(id: String, v: float) -> void:
	params[id] = v
	if id != "spin":
		rebuild()


func lab_options() -> Array:
	var choices: Array = ["all"]
	choices.append_array(MechMeshes.all_parts())
	return [{"id": "part", "label": "Part", "choices": choices, "value": part}]


func set_lab_option(id: String, v: String) -> void:
	if id == "part":
		part = v if MechMeshes.has_part(v) else "all"
		rebuild()


func lab_focus() -> Vector3:
	return Vector3(0, 1.2, 0)


func lab_radius() -> float:
	return 3.0 if part != "all" else 3.0 + float(params["spacing"]) * float(maxi(_cols, _rows)) * 0.28
