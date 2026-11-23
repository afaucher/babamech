extends Node
## Trooper look-variant shots (docs/design/enemy-detail/trooper_variants_*.png, trooper_squads.png): EnemyMeshes trooper
## variant meshes placed directly (no EnemySquad / AI) in the day-lit seeded CityDistrict. Run on the hidden desktop via
## tools/enemy_detail/trooper_shots.ps1.
##   --shots variants,squads   variants: every rifle variant alone, close front and rear three-quarter
##                             (<out>/var_<part>_<front|rear>.png); squads: two mixed squads of 5 (rifle + AT, seeds from
##                             EnemyMeshes.trooper_squad_seeds, one trooper crouched each) seen from chase-cam height at
##                             ~20 m and ~40 m (<out>/squads_<20|40>.png)
##   --out <dir>               default res://test_logs/enemy_detail
## Prints "[tshots]" lines and quits.

const SETTLE := 20
const YAW_FRONT := PI - 0.65
const SQUADS := [
	{"seed": 101, "x": -5.0, "kits": ["rifle", "rifle", "rifle", "at", "rifle"]},
	{"seed": 58, "x": 5.0, "kits": ["rifle", "at", "rifle", "rifle", "at"]},
]
## Slot layout inside a squad: (dx, ds, yaw offset, crouched).
const SLOTS := [[0.0, 0.0, 0.0, false], [-1.9, 0.9, 0.35, false], [1.9, 0.7, -0.3, true], [-1.1, -1.3, 0.6, false],
	[1.2, -1.1, -0.5, false]]

var _args: PackedStringArray
var _out := ""
var _cam: Camera3D
var _district: CityDistrict
var _centre := Vector2.ZERO
var _props: Array[Node3D] = []


func _ready() -> void:
	_run.call_deferred()


func _say(s: String) -> void:
	print("[tshots] " + s)


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
	var which := _arg("--shots", "variants,squads").split(",", false)
	if "variants" in which:
		for n in EnemyMeshes.TROOPER_VARIANTS:
			var part := EnemyMeshes.trooper_part("rifle", n)
			for view: String in ["front", "rear"]:
				_clear()
				_put(part, 0.0, 0.0, YAW_FRONT if view == "front" else YAW_FRONT + PI + 0.9, false)
				_place_camera(Vector3(0.0, -4.4, 1.75), Vector3(0.0, 0.0, 1.22), 40.0)
				await _save("var_%s_%s" % [part, view])
	if "squads" in which:
		_clear()
		for sq: Dictionary in SQUADS:
			var seeds := EnemyMeshes.trooper_squad_seeds(int(sq["seed"]), SLOTS.size())
			var names: Array[String] = []
			for i in SLOTS.size():
				var sl: Array = SLOTS[i]
				var part := EnemyMeshes.trooper_part(sq["kits"][i], seeds[i])
				names.append(part)
				_put(part, float(sq["x"]) + float(sl[0]), float(sl[1]), PI + float(sl[2]), bool(sl[3]))
			_say("squad seed %d: %s" % [sq["seed"], ", ".join(names)])
		for d: float in [20.0, 40.0]:
			# Chase cam: fov 70, eye ~9.5 m up (ChaseCamera height), looking down at the squads.
			_place_camera(Vector3(0.0, -d, 9.5), Vector3(0.0, 0.0, 1.2), 70.0, d)
			await _save("squads_%d" % int(d))
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
	GraphicsQuality.apply_viewport(get_tree().root, CityQuality.HIGH)
	_district = CityDistrict.new()
	_district.name = "District"
	add_child(_district)
	_district.build({"seed": int(_arg("--seed", "7")), "walls": 1.0})
	_district.set_ceiling_visible(true)
	_district.set_backdrop_visible(true)
	if _district.rig != null:
		_district.rig.apply("day")
		_district.rig.set_quality(CityQuality.HIGH)
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


func _clear() -> void:
	for p in _props:
		p.queue_free()
	_props.clear()


## A trooper mesh at arc offset (dx, ds) from the centre, turned `yaw`; crouched = the squad's pivot Y scale 0.58.
func _put(part: String, dx: float, ds: float, yaw: float, crouched: bool) -> void:
	var ring := _district.ring
	var s := _centre.y + ds
	var base_b := ring.basis_at_arc(s)
	var piv := Node3D.new()
	add_child(piv)
	piv.global_transform = Transform3D(Basis(base_b.y, yaw) * base_b, ring.arc_to_world(_centre.x + dx, s, 0.0))
	var mi := EnemyMeshes.instance(part)
	if crouched:
		mi.scale = Vector3(1.0, 0.58, 1.0)
	piv.add_child(mi)
	_props.append(piv)


## `ground` > 0: put the eye exactly that far from the target along the ground (true metres; the arc offset only sets the
## direction), at the eye's height above the target's floor.
func _place_camera(eye: Vector3, tgt: Vector3, fov: float, ground: float = 0.0) -> void:
	var ring := _district.ring
	var p := ring.arc_to_world(_centre.x + eye.x, _centre.y + eye.y, eye.z)
	var q := ring.arc_to_world(_centre.x + tgt.x, _centre.y + tgt.y, tgt.z)
	if ground > 0.0:
		var up := ring.up_at(q)
		var flat := (p - q) - up * (p - q).dot(up)
		p = q + flat.normalized() * ground + up * (eye.z - tgt.z)
		_say("camera %.1f m from the squads (ground %.1f m)" % [p.distance_to(q), ground])
	_cam.fov = fov
	_cam.global_transform = Transform3D(Basis.looking_at(q - p, ring.up_at(p)), p)
	_cam.make_current()
