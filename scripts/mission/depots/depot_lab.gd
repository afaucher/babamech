extends Node3D
## Lab subject "depot" (scripts/app/lab_registry.gd): the supply depot model (docs/design/supply-depot.md "Build") as
## the game instances it (scenes/props/supply_depot_kiosk.tscn), with an 8 m player mech beside it for scale. Sliders:
## cores stocked and capacity (set_cores). Options: roof marker, destroyed. Action: take a core (core_taken + set_cores).

const SCENE := "res://scenes/props/supply_depot_kiosk.tscn"

var time_scale := 1.0
var params := {"stocked": 2.0, "capacity": 4.0}
var options := {"marker": "on", "destroyed": "off"}
var kiosk: DepotKiosk
var mech: MechModel


func _ready() -> void:
	kiosk = (load(SCENE) as PackedScene).instantiate() as DepotKiosk
	add_child(kiosk)
	mech = MechModel.new()
	mech.scale = Vector3.ONE * 2.0
	mech.position = Vector3(-8.0, 0.0, 5.0)
	mech.rotation.y = -PI * 0.35   # facing the socket wall from its front-left
	add_child(mech)
	mech.configure("chicken", "strider", {})
	_apply()


func _process(_delta: float) -> void:
	if kiosk != null:
		kiosk.time_scale = time_scale


func _apply() -> void:
	kiosk.set_cores(int(round(params["stocked"])), int(round(params["capacity"])))
	kiosk.set_marker(options["marker"] == "on")
	kiosk.set_destroyed(options["destroyed"] == "on")


func lab_params() -> Array:
	return [
		{"id": "stocked", "label": "Cores stocked", "min": 0.0, "max": float(DepotKiosk.SOCKETS), "value": params["stocked"]},
		{"id": "capacity", "label": "Capacity", "min": 1.0, "max": float(DepotKiosk.SOCKETS), "value": params["capacity"]},
	]


func set_lab_param(id: String, value: float) -> void:
	params[id] = value
	_apply()


func lab_options() -> Array:
	return [
		{"id": "marker", "label": "Roof marker", "choices": ["on", "off"], "value": options["marker"]},
		{"id": "destroyed", "label": "Destroyed", "choices": ["off", "on"], "value": options["destroyed"]},
	]


func set_lab_option(id: String, value: String) -> void:
	options[id] = value
	_apply()


func lab_actions() -> Array:
	return [{"id": "take", "label": "Take a core"}, {"id": "refill", "label": "Refill"}]


func do_lab_action(id: String) -> void:
	match id:
		"take":
			var n := kiosk.stocked_count()
			if n > 0:
				kiosk.core_taken(n - 1)
				params["stocked"] = float(n - 1)
				_apply()
		"refill":
			params["stocked"] = params["capacity"]
			_apply()


func lab_focus() -> Vector3:
	return Vector3(-1.5, 3.0, 1.0)


func lab_radius() -> float:
	return 18.0
