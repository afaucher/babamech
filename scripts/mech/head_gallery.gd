class_name HeadGallery
extends Node3D
## Lab subject: the four placeholder heads side by side (chicken, pickle, corn, dog), each on a little plinth, turning.
## For comparing head size and silhouette while art direction iterates.

const PARAMS := [
	{"id": "scale", "label": "Head scale", "min": 0.4, "max": 2.5, "value": 1.0},
	{"id": "spacing", "label": "Spacing", "min": 1.0, "max": 3.0, "value": 1.6},
	{"id": "spin", "label": "Spin (rad/s)", "min": 0.0, "max": 3.0, "value": 0.6},
]

var params: Dictionary = {}
var time_scale := 1.0
var _heads: Array[Node3D] = []


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_heads.clear()
	var n := MechCatalog.HEAD_ORDER.size()
	var sp := float(params["spacing"])
	for i in n:
		var id: String = MechCatalog.HEAD_ORDER[i]
		var x := (float(i) - float(n - 1) * 0.5) * sp
		add_child(MechParts.cylinder(0.45, 0.2, Color(0.3, 0.32, 0.35), Vector3(x, 0.1, 0), false))
		var h := MechParts.head(id, float(params["scale"]))
		h.position = Vector3(x, 0.2, 0)
		add_child(h)
		_heads.append(h)
		var label := Label3D.new()
		label.text = MechCatalog.head_name(id)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 48
		label.pixel_size = 0.005
		label.position = Vector3(x, 1.6 * float(params["scale"]) + 0.4, 0)
		add_child(label)


func _process(delta: float) -> void:
	for h in _heads:
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
	return []


func set_lab_option(_id: String, _v: String) -> void:
	pass


func lab_focus() -> Vector3:
	return Vector3(0, 0.8, 0)


func lab_radius() -> float:
	return 2.5 + float(params["spacing"]) * 2.0
