class_name EnemyTurret
extends EnemyBase
## Enforcer Turret (docs/design/enemies.md §1–4): static fortified gun emplacement (4.8 x 4.8 x 5.6 m),
## yaw/pitch tracking with aim-kick barrel recoil and twin-barrel heavy plasma bolter bursts.

var _yaw := 0.0
var _pitch := 0.0
var _barrel_side := 1.0
var _base_mi: MeshInstance3D
var _turret_pivot: Node3D
var _gun_pivot: Node3D
var _gun_mi: MeshInstance3D
var _wreck_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "turret"


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"_yaw": Net.OWNER, "_pitch": Net.OWNER, "_barrel_side": Net.PRIVATE,
		"_base_mi": Net.LOCAL, "_turret_pivot": Net.LOCAL, "_gun_pivot": Net.LOCAL,
		"_gun_mi": Net.LOCAL, "_wreck_mi": Net.LOCAL})
	return f


func _gun_mesh_name() -> String:
	match enemy_type:
		"turret_sniper": return "turret_sniper_gun"
		"turret_missile": return "turret_missile_gun"
		_: return "turret_gun"


func _build_visuals() -> void:
	_base_mi = EnemyMeshes.instance("turret_base")
	add_child(_base_mi)
	_register_comp_mesh("base", _base_mi)
	_turret_pivot = Node3D.new()
	_turret_pivot.name = "TurretPivot"
	_turret_pivot.position = Vector3(0.0, 2.2, 0.0)
	add_child(_turret_pivot)
	_gun_pivot = Node3D.new()
	_gun_pivot.name = "GunPivot"
	_turret_pivot.add_child(_gun_pivot)
	_gun_mi = EnemyMeshes.instance(_gun_mesh_name())
	_gun_pivot.add_child(_gun_mi)
	_register_comp_mesh("gun", _gun_mi)
	_wreck_mi = EnemyMeshes.instance("turret_gun_wreck")
	_wreck_mi.visible = false
	_turret_pivot.add_child(_wreck_mi)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	if _gun_pivot != null and _gun_pivot.is_inside_tree():
		match enemy_type:
			"turret_sniper":
				return _gun_pivot.global_transform * Vector3(0.0, 1.05, -5.48)
			"turret_missile":
				return _gun_pivot.global_transform * Vector3(_barrel_side * 1.95, 1.45, -1.60)
			_:
				return _gun_pivot.global_transform * Vector3(_barrel_side * 0.78, 1.05, -3.86)
	return super.muzzle_world()


func _fire_one_round(st: Dictionary) -> void:
	super._fire_one_round(st)
	_barrel_side = -_barrel_side


func _max_aim_pitch() -> float:
	return deg_to_rad(62.0)


func _track_aim(target_pos: Vector3, dt: float) -> float:
	if _turret_pivot == null or not is_inside_tree():
		return 0.0
	var local_t := global_transform.affine_inverse() * target_pos
	var rel := local_t - _turret_pivot.position - Vector3(0.0, 1.05, 0.0)
	var want_yaw := atan2(-rel.x, -rel.z)
	var horiz := maxf(Vector2(rel.x, rel.z).length(), 0.01)
	var raw_pitch := atan2(rel.y, horiz)
	var want_pitch := clampf(raw_pitch, deg_to_rad(-38.0), _max_aim_pitch())
	var slew := float(_cfg.get("slew_rate", 2.4)) * dt
	var dy := wrapf(want_yaw - _yaw, -PI, PI)
	var step_y := clampf(dy, -slew, slew)
	_yaw = wrapf(_yaw + step_y, -PI, PI)
	var dp := want_pitch - _pitch
	var step_p := clampf(dp, -slew, slew)
	_pitch += step_p
	turret_slew_speed = (absf(step_y) + absf(step_p)) / maxf(dt, 1e-4)
	_apply_turret_pose()
	return absf(wrapf(want_yaw - _yaw, -PI, PI)) + absf(raw_pitch - _pitch)


func _sensor_yaw() -> float:   # perception: the forward cone follows the gun, which glances round while idle
	return _yaw


func puppet_aim() -> Vector2:   # co-op puppet (W4)
	return Vector2(_yaw, _pitch)


func set_puppet_aim(a: Vector2) -> void:
	_yaw = a.x
	_pitch = a.y


func _update_visuals(dt: float) -> void:
	super._update_visuals(dt)
	_apply_turret_pose()


func _apply_turret_pose() -> void:
	if _turret_pivot == null or _gun_pivot == null:
		return
	var droop := deg_to_rad(-24.0) if heat.shutdown else 0.0
	var kick_rad := deg_to_rad(minf(aim_kick * 0.45, 22.0))
	_turret_pivot.rotation.y = _yaw
	_gun_pivot.rotation.x = _pitch + droop + kick_rad


func _spawn_death_debris(_cause: String) -> void:
	if _gun_mi != null:
		var gxf := _gun_mi.global_transform if _gun_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 2.2)
		_pop_part(_gun_mesh_name(), gxf, 9.5, 12.8, 4.5, 7.5, 4.2, false)
	_pop_plates(_world_pos() + up * 2.6, 2, 6.5, 10.5, 4.0, 8.0)


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 2.55, 0.0)


func _core_rupture_scale() -> float:
	return 1.05


func _wreck_flame_specs() -> Array[Dictionary]:
	return [
		{"parent": self, "pos": Vector3(0.0, 2.75, 0.0), "dir": Vector3(0.08, 1.0, 0.08),
			"length": 4.4, "width": 1.0, "speed": 11.0, "count": 6, "root": 1.1, "duration": 7.8, "tag": "pedestal"},
	]


func _on_destroyed_visual() -> void:
	if _base_mi != null:
		_base_mi.visible = true
		_base_mi.material_override = EnemyMeshes.charred_material()
	if _gun_mi != null:
		_gun_mi.visible = false
	if _wreck_mi != null:
		_wreck_mi.visible = true


func _on_reset_visual() -> void:
	_yaw = 0.0
	_pitch = 0.0
	if _base_mi != null:
		_base_mi.material_override = null
	if _gun_mi != null:
		_gun_mi.visible = true
	if _wreck_mi != null:
		_wreck_mi.visible = false
	_apply_turret_pose()
