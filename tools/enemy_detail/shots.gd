extends Node
## Enemy detail render shots (docs/design/enemy-detail/), now of the adopted EnemyMeshes (the A/B builder is gone). Whole
## units built by EnemySpawner (AI idle) in the day-lit seeded CityDistrict. Run on the hidden desktop via
## tools/enemy_detail/shots.ps1.
##   --shots lineup,close   lineup: four groups at ~20 m, 3/4 (<out>/adopted_lineup<n>.png), the aircraft hovering;
##                          close: gunship and dropship alone, hovering, from above-front and below-rear 3/4
##                          (<out>/close_<unit>_<view>.png)
##   --out <dir>            default res://test_logs/enemy_detail
## Prints "[edetail]" lines and quits.

const SETTLE := 20
const LINEUPS := [
	{"units": ["turret", "turret_sniper", "turret_missile"], "spacing": 7.5},
	{"units": ["strider", "tank", "strider_breacher"], "spacing": 9.5, "dist": 21.0},
	{"units": ["troop_squad", "drone", "troop_roof"], "spacing": 11.0},
	{"units": ["gunship", "dropship"], "spacing": 8.5, "dist": 19.0, "look_h": 4.5},
]
const HOVER := {"drone": 4.0, "gunship": 5.0, "dropship": 5.5}
const LINEUP_YAW := PI - 0.6
## Close-up views: eye offset from the unit (arc dx, ds, dh) for a unit turned to CLOSE_YAW.
const CLOSE_VIEWS := {"above": Vector3(0.0, -8.5, 4.3), "below": Vector3(0.0, 8.5, -3.4)}
const CLOSE_YAW := PI - 0.7

var _args: PackedStringArray
var _out := ""
var _cam: Camera3D
var _world: CombatWorld
var _squad: EnemySquad
var _district: CityDistrict
var _centre := Vector2.ZERO


func _ready() -> void:
	_run.call_deferred()


func _say(s: String) -> void:
	print("[edetail] " + s)


func _arg(key: String, def: String) -> String:
	var v := Boot.arg_value(_args, key)
	return v if v != "" else def


func _run() -> void:
	_args = OS.get_cmdline_user_args()
	_out = _arg("--out", "res://test_logs/enemy_detail")
	if _out.begins_with("res://") or _out.begins_with("user://"):
		_out = ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_cam = Camera3D.new()
	_cam.far = 1500.0
	add_child(_cam)
	_cam.make_current()
	_build_city()
	var which := _arg("--shots", "lineup,close").split(",", false)
	if "lineup" in which:
		for gi in LINEUPS.size():
			var g: Dictionary = LINEUPS[gi]
			await _clear()
			var units: Array = g["units"]
			var n := units.size()
			for i in n:
				var x := _centre.x - (float(i) - float(n - 1) * 0.5) * float(g["spacing"])
				_spawn(units[i], x, _centre.y, float(HOVER.get(units[i], 0.0)), LINEUP_YAW)
			await _settle()
			var dist := float(g.get("dist", 18.0))
			var lh := float(g.get("look_h", 2.2))
			_place_camera(Vector3(0.0, -dist * 0.95, lh + dist * 0.4), Vector3(0.0, 0.0, lh), 50.0)
			await _save("adopted_lineup%d" % (gi + 1))
	if "close" in which:
		for u: String in ["gunship", "dropship"]:
			await _clear()
			var h := float(HOVER[u])
			_spawn(u, _centre.x, _centre.y, h, CLOSE_YAW)
			await _settle()
			for view: String in CLOSE_VIEWS:
				var off: Vector3 = CLOSE_VIEWS[view]
				_place_camera(Vector3(off.x, off.y, h + off.z), Vector3(0.0, 0.0, h), 50.0)
				await _save("close_%s_%s" % [u, view])
	_say("done")
	get_tree().quit()


func _save(name: String) -> void:
	for i in SETTLE:
		await get_tree().process_frame
	var img := get_tree().root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	img.save_png(path)
	_say("saved " + path)


func _build_city() -> void:
	GraphicsQuality.apply_viewport(get_tree().root, GraphicsQuality.HIGH)
	_district = CityDistrict.new()
	_district.name = "District"
	add_child(_district)
	_district.build({"seed": int(_arg("--seed", "7")), "walls": 1.0})
	_district.set_ceiling_visible(true)
	_district.set_backdrop_visible(true)
	if _district.rig != null:
		_district.rig.apply("day")
		_district.rig.set_quality(GraphicsQuality.HIGH)
	var plan := _district.plan
	var av := plan.avenue_x()
	var best_s := 0.0
	var best_d := INF
	var mid_s := plan.extent.get_center().y
	for r: Dictionary in plan.roads_s:
		if str(r.get("kind", "")) == "perimeter":
			continue
		var s := (float(r["a"]) + float(r["b"])) * 0.5
		if absf(s - mid_s) < best_d:
			best_d = absf(s - mid_s)
			best_s = s
	_centre = Vector2((av.x + av.y) * 0.5, best_s)
	_world = CombatWorld.new()
	_world.name = "CombatWorld"
	_world.mission_seed = 42
	add_child(_world)
	_squad = EnemySquad.new()
	_squad.name = "Squad"
	add_child(_squad)
	_squad.setup(_world, _district.plan, _district.ring)


func _clear() -> void:
	_squad.clear_enemies()
	await get_tree().process_frame


func _settle() -> void:
	for i in 20:
		_world.advance(1.0 / 60.0)
		await get_tree().process_frame


func _arc_xf(x: float, s: float, h: float, yaw: float) -> Transform3D:
	var ring := _district.ring
	var base_b := ring.basis_at_arc(s)
	return Transform3D(Basis(base_b.y, yaw) * base_b, ring.arc_to_world(x, s, h))


func _spawn(type_id: String, x: float, s: float, h: float, yaw: float) -> void:
	var e := EnemySpawner.make_enemy(type_id)
	e.configure(type_id, "ed_" + type_id + str(_squad.enemies.size()), _world, _squad, _district.ring, 42)
	e.ai_mode = "idle"
	e.transform = _arc_xf(x, s, h, yaw)
	e.up = _district.ring.up_at(e.position)
	_squad.add_enemy(e)


func _place_camera(eye: Vector3, tgt: Vector3, fov: float) -> void:
	var ring := _district.ring
	var p := ring.arc_to_world(_centre.x + eye.x, _centre.y + eye.y, eye.z)
	var q := ring.arc_to_world(_centre.x + tgt.x, _centre.y + tgt.y, tgt.z)
	_cam.fov = fov
	_cam.global_transform = Transform3D(Basis.looking_at(q - p, ring.up_at(p)), p)
	_cam.make_current()
