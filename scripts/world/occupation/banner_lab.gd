extends Node3D
## Lab subject "banners" (scripts/app/lab_registry.gd): the invader banner close up (docs/design/banners.md). A plain
## facade with a wall banner on its cross-bar and a pole banner beside it, built from the game's own parts
## (OccupationBanners.make_parts, BannerMeshes). Sliders: the wall banner's cloth length and a scrub through the tear
## (0 = whole; past the fall it lies as the heap). Actions: play the tear, reset.

const WALL_TOP := 10.4            ## m: the wall banner's bar above the ground (a tall ground tier)

var time_scale := 1.0
var params := {"cloth_len": BannerMeshes.H, "tear_t": 0.0}
var options := {"show": "both"}
var _wall: Dictionary = {}
var _pole: Dictionary = {}
var _wall_root: Node3D
var _pole_root: Node3D
var _play := -1.0                 ## s into a played tear (-1: scrubbed by the slider)


func _ready() -> void:
	var k := MeshKit.new()
	k.box(Vector3(14.0, 13.0, 1.0), Color("c9b48f"), Vector3(0.0, 6.5, -0.5))      # the facade (terracotta-sand)
	k.box(Vector3(14.0, 0.2, 4.0), Color("9a958c"), Vector3(0.0, 0.1, 2.0))        # the sidewalk
	var wall := MeshInstance3D.new()
	wall.name = "Facade"
	wall.mesh = k.commit(LowPolyMaterials.materials())
	add_child(wall)
	_rebuild()


func _rebuild() -> void:
	for n: Node3D in [_wall_root, _pole_root]:
		if n != null:
			n.queue_free()
	_wall_root = Node3D.new()
	_wall_root.name = "WallBanner"
	_wall_root.position = Vector3(-2.5, WALL_TOP + 0.2, BannerPlan.OUT)
	var bar := OccupationBanners._mi("Bar", BannerMeshes.bar(), 1, true)
	_wall_root.add_child(bar)
	var a := Node3D.new()
	a.name = "Anchor"
	_wall_root.add_child(a)
	_wall = OccupationBanners.make_parts(a, 0, 0, float(params["cloth_len"]), WALL_TOP, 1)
	add_child(_wall_root)
	_pole_root = Node3D.new()
	_pole_root.name = "PoleBanner"
	_pole_root.position = Vector3(2.0, 0.2, 6.0)
	_pole_root.add_child(OccupationBanners._mi("Pole", BannerMeshes.pole(), 1, true))
	var pa := Node3D.new()
	pa.name = "Anchor"
	pa.position = Vector3(BannerMeshes.ARM_X, BannerMeshes.ARM_H, 0.12)
	_pole_root.add_child(pa)
	_pole = OccupationBanners.make_parts(pa, 0, 1, BannerMeshes.POLE_LEN, BannerMeshes.ARM_H, 1)
	add_child(_pole_root)
	_apply_show()
	_pose(float(params["tear_t"]))


func _apply_show() -> void:
	_wall_root.visible = options["show"] != "pole"
	_pole_root.visible = options["show"] != "wall"


func _pose(e: float) -> void:
	for n: Dictionary in [_wall, _pole]:
		(n["fringe"] as MeshInstance3D).visible = e > 0.0
		OccupationBanners.pose_tear(n, e if e < OccupationBanners.FALL * 1.3 else INF, 0, int((n["target"] as BannerTarget).banner_id))


func _process(delta: float) -> void:
	if _play >= 0.0:
		_play += delta * time_scale
		_pose(_play)
		if _play > OccupationBanners.FALL * 1.3:
			_play = -1.0


func lab_params() -> Array:
	return [
		{"id": "cloth_len", "label": "Wall cloth length (m)", "min": 4.8, "max": BannerMeshes.H, "value": params["cloth_len"]},
		{"id": "tear_t", "label": "Tear (s after it begins)", "min": 0.0, "max": 1.6, "value": params["tear_t"]},
	]


func set_lab_param(id: String, value: float) -> void:
	params[id] = value
	if id == "cloth_len":
		_rebuild()
	else:
		_play = -1.0
		_pose(value)


func lab_options() -> Array:
	return [{"id": "show", "label": "Show", "choices": ["both", "wall", "pole"], "value": options["show"]}]


func set_lab_option(id: String, value: String) -> void:
	options[id] = value
	_apply_show()


func lab_actions() -> Array:
	return [{"id": "tear", "label": "Play the tear"}, {"id": "reset", "label": "Reset"}]


func do_lab_action(id: String) -> void:
	match id:
		"tear":
			_play = 0.0
		"reset":
			_play = -1.0
			params["tear_t"] = 0.0
			_pose(0.0)


func lab_focus() -> Vector3:
	return Vector3(0.0, 6.5, 2.0)


func lab_radius() -> float:
	return 20.0
