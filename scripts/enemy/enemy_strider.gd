class_name EnemyStrider
extends EnemyBase
## Hound Skirmisher (docs/design/enemies.md §1–4): light mobile bipedal patrol walker (3.8 x 4.2 x 5.2 m),
## flanks along streets/parks, relays sightings, showcases knockback/stagger/wall-slam, emits footsteps on stride.

const STRIDE_RATE := 7.2          ## rad/s of leg swing at full speed

var _stride_phase := 0.0
var _last_step_half := 0
var _aim_yaw := 0.0
var _chassis_pivot: Node3D
var _chassis_mi: MeshInstance3D
var _sensor_mi: MeshInstance3D
var _leg_l: Node3D
var _leg_r: Node3D
var _leg_l_mi: MeshInstance3D
var _leg_r_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "strider"


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"_stride_phase": Net.LOCAL, "_last_step_half": Net.LOCAL, "_aim_yaw": Net.OWNER,
		"_chassis_pivot": Net.LOCAL, "_chassis_mi": Net.LOCAL, "_sensor_mi": Net.LOCAL,
		"_leg_l": Net.LOCAL, "_leg_r": Net.LOCAL, "_leg_l_mi": Net.LOCAL, "_leg_r_mi": Net.LOCAL})
	return f


func _build_visuals() -> void:
	_chassis_pivot = Node3D.new()
	_chassis_pivot.name = "ChassisPivot"
	_chassis_pivot.position = Vector3(0.0, 2.6, 0.0)
	add_child(_chassis_pivot)
	_chassis_mi = EnemyMeshes.instance("strider_chassis")
	_chassis_pivot.add_child(_chassis_mi)
	_register_comp_mesh("chassis", _chassis_mi)
	_sensor_mi = EnemyMeshes.instance("strider_sensor")
	_sensor_mi.position = Vector3(0.0, 1.7, -1.2)
	_chassis_pivot.add_child(_sensor_mi)
	_register_comp_mesh("sensor", _sensor_mi)
	_leg_l = Node3D.new()
	_leg_l.name = "LegL"
	_leg_l.position = Vector3(-1.18, 2.6, 0.0)
	add_child(_leg_l)
	_leg_l_mi = EnemyMeshes.instance("strider_leg")
	_leg_l_mi.scale = Vector3(-1.0, 1.0, 1.0)
	_leg_l.add_child(_leg_l_mi)
	_register_comp_mesh("legs", _leg_l_mi)
	_leg_r = Node3D.new()
	_leg_r.name = "LegR"
	_leg_r.position = Vector3(1.18, 2.6, 0.0)
	add_child(_leg_r)
	_leg_r_mi = EnemyMeshes.instance("strider_leg")
	_leg_r.add_child(_leg_r_mi)
	_register_comp_mesh("legs", _leg_r_mi)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	if _chassis_pivot != null and _chassis_pivot.is_inside_tree():
		return _chassis_pivot.global_transform * Vector3(0.0, 0.48, -2.5)
	return super.muzzle_world()


func _track_aim(target_pos: Vector3, dt: float) -> float:
	if not is_inside_tree():
		return 0.0
	var local_t := global_transform.affine_inverse() * target_pos
	var want_yaw := atan2(-local_t.x, -local_t.z)
	var slew := float(_cfg.get("slew_rate", 3.6)) * dt
	# Strider can yaw its upper torso +-45 deg while strafing/flanking, and rotates hull when beyond.
	var clamped_want := clampf(want_yaw, -0.78, 0.78)
	var dy := clamped_want - _aim_yaw
	var step_y := clampf(dy, -slew, slew)
	_aim_yaw += step_y
	turret_slew_speed = absf(step_y) / maxf(dt, 1e-4)
	if absf(want_yaw) > 0.65 and move_speed_ratio < 0.1:
		var turn := clampf(want_yaw, -float(_cfg.get("turn_rate", 3.0)) * dt, float(_cfg.get("turn_rate", 3.0)) * dt)
		var f := (-global_basis.z).rotated(up, turn).normalized()
		global_basis = Basis(f.cross(up).normalized(), up, -f)
	return absf(want_yaw - _aim_yaw)


func puppet_aim() -> Vector2:   # co-op puppet (W4)
	return Vector2(_aim_yaw, 0.0)


func set_puppet_aim(a: Vector2) -> void:
	_aim_yaw = a.x


func _update_visuals(dt: float) -> void:
	super._update_visuals(dt)
	if _chassis_pivot == null:
		return
	var moving := move_speed_ratio > 0.05 and _grounded_now
	if moving:
		_stride_phase += dt * STRIDE_RATE * (0.45 + 0.75 * move_speed_ratio)
		var half_idx := int(floor(_stride_phase / PI))
		if half_idx != _last_step_half:
			_last_step_half = half_idx
			var pos := _world_pos()
			footstep.emit(self, pos)
			_emit_squad("footstep", {"id": target_id, "pos": pos})
	var swing := sin(_stride_phase) * 0.48 * move_speed_ratio if moving else 0.0
	var bob := absf(cos(_stride_phase)) * 0.22 * move_speed_ratio if moving else 0.0
	var droop := deg_to_rad(-22.0) if heat.shutdown else (deg_to_rad(14.0) if knock.staggered() else 0.0)
	_chassis_pivot.position.y = 2.6 - bob - (0.35 if heat.shutdown else 0.0)
	_chassis_pivot.rotation = Vector3(-0.12 * move_speed_ratio + droop, _aim_yaw, 0.0)
	if _leg_l != null and _leg_r != null:
		_leg_l.rotation.x = swing
		_leg_r.rotation.x = -swing


func _spawn_component_debris(comp_id: String) -> void:
	if comp_id == "legs":
		_pop_plates(_world_pos() + up * 2.2, 2, 5.5, 8.5, 3.5, 6.5)
		_attach_flame_stream(_chassis_pivot, Vector3(0.85, -0.15, 0.15), Vector3(0.42, 0.88, 0.18),
			2.5, 0.58, 9.5, 5, 0.7, 0.0, "leg_socket")


func _spawn_death_debris(_cause: String) -> void:
	if _sensor_mi != null:
		var sxf := _sensor_mi.global_transform if _sensor_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 4.3)
		_pop_part("strider_sensor", sxf, 9.0, 12.2, 4.5, 7.8, 5.8, false)
	if _leg_r_mi != null:
		var lxf := _leg_r_mi.global_transform if _leg_r_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 2.6)
		_pop_part("strider_leg", lxf, 7.2, 10.5, 4.5, 8.2, 4.8, false)
	_pop_plates(_world_pos() + up * 3.0, 2, 6.0, 10.0, 4.0, 8.0)


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 1.35, 0.0)


func _core_rupture_scale() -> float:
	return 0.85


func _wreck_flame_specs() -> Array[Dictionary]:
	return [
		{"parent": self, "pos": Vector3(0.0, 1.45, 0.0), "dir": Vector3(-0.12, 1.0, 0.08),
			"length": 3.8, "width": 0.9, "speed": 10.5, "count": 6, "root": 0.95, "duration": 7.0, "tag": "chassis_core"},
	]


func _on_destroyed_visual() -> void:
	if _sensor_mi != null:
		_sensor_mi.visible = false
	if _leg_r_mi != null:
		_leg_r_mi.visible = false
	if _chassis_mi != null:
		_chassis_mi.visible = true
		_chassis_mi.material_override = EnemyMeshes.charred_material()
	if _leg_l_mi != null:
		_leg_l_mi.visible = true
		_leg_l_mi.material_override = EnemyMeshes.charred_material()
	if _chassis_pivot != null:
		_chassis_pivot.position = Vector3(0.0, 0.95, 0.0)
		_chassis_pivot.rotation = Vector3(deg_to_rad(32.0), _aim_yaw, deg_to_rad(-62.0))
	if _leg_l != null:
		_leg_l.position = Vector3(-0.9, 0.75, 0.4)
		_leg_l.rotation = Vector3(deg_to_rad(-72.0), deg_to_rad(25.0), deg_to_rad(-28.0))


func _on_reset_visual() -> void:
	_stride_phase = 0.0
	_last_step_half = 0
	_aim_yaw = 0.0
	if _chassis_mi != null:
		_chassis_mi.material_override = null
	if _leg_l_mi != null:
		_leg_l_mi.material_override = null
	if _chassis_pivot != null:
		_chassis_pivot.position = Vector3(0.0, 2.6, 0.0)
		_chassis_pivot.rotation = Vector3.ZERO
	if _leg_l != null and _leg_r != null:
		_leg_l.position = Vector3(-1.18, 2.6, 0.0)
		_leg_l.rotation = Vector3.ZERO
		_leg_r.position = Vector3(1.18, 2.6, 0.0)
		_leg_r.rotation = Vector3.ZERO
