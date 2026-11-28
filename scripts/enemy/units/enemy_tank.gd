class_name EnemyTank
extends EnemyBase
## Bastion Siege Tank (docs/design/enemies.md §1–4): heavy armored assault vehicle (6.8 x 9.6 x 5.4 m),
## independent slewing turret, glowing rear/top radiator `vents` weak point (rooftop reward), primary siege cannon
## and cover-flushing arc mortar when the player hides out of LOS.

var _turret_yaw := 0.0
var _turret_popped := false
var _hull_mi: MeshInstance3D
var _vents_mi: MeshInstance3D
var _turret_pivot: Node3D
var _turret_mi: MeshInstance3D
var _turret_wreck_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "tank"


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"_turret_yaw": Net.OWNER, "_turret_popped": Net.LOCAL, "_hull_mi": Net.LOCAL, "_vents_mi": Net.LOCAL,
		"_turret_pivot": Net.LOCAL, "_turret_mi": Net.LOCAL, "_turret_wreck_mi": Net.LOCAL})
	return f


func _build_visuals() -> void:
	_hull_mi = EnemyMeshes.instance("tank_hull")
	add_child(_hull_mi)
	_register_comp_mesh("hull", _hull_mi)
	_vents_mi = EnemyMeshes.instance("tank_vents")
	_vents_mi.position = Vector3(0.0, 2.75, 3.1)
	add_child(_vents_mi)
	_register_comp_mesh("vents", _vents_mi)
	_turret_pivot = Node3D.new()
	_turret_pivot.name = "TurretPivot"
	_turret_pivot.position = Vector3(0.0, 2.7, -0.3)
	add_child(_turret_pivot)
	_turret_mi = EnemyMeshes.instance("tank_turret")
	_turret_pivot.add_child(_turret_mi)
	_register_comp_mesh("turret", _turret_mi)
	_turret_wreck_mi = EnemyMeshes.instance("tank_turret_wreck")
	_turret_wreck_mi.visible = false
	_turret_pivot.add_child(_turret_wreck_mi)


func muzzle_world(weapon_id: String = "") -> Vector3:
	if _turret_pivot != null and _turret_pivot.is_inside_tree():
		if weapon_id == "enemy_mortar":
			return _turret_pivot.global_transform * Vector3(1.05, 2.95, 0.52)
		return _turret_pivot.global_transform * Vector3(0.0, 1.0, -6.48)
	return super.muzzle_world(weapon_id)


func _max_aim_pitch() -> float:
	return deg_to_rad(32.0)


func _track_aim(target_pos: Vector3, dt: float) -> float:
	if _turret_pivot == null or not is_inside_tree():
		return 0.0
	var local_t := global_transform.affine_inverse() * target_pos
	var rel := local_t - _turret_pivot.position
	var want_yaw := atan2(-rel.x, -rel.z)
	var slew := float(_cfg.get("slew_rate", 1.4)) * dt
	var dy := wrapf(want_yaw - _turret_yaw, -PI, PI)
	var step_y := clampf(dy, -slew, slew)
	_turret_yaw = wrapf(_turret_yaw + step_y, -PI, PI)
	turret_slew_speed = absf(step_y) / maxf(dt, 1e-4)
	_turret_pivot.rotation.y = _turret_yaw
	return absf(wrapf(want_yaw - _turret_yaw, -PI, PI))


func _sensor_yaw() -> float:   # perception: the forward cone follows the turret, which glances round while idle
	return _turret_yaw


func puppet_aim() -> Vector2:   # co-op puppet (W4)
	return Vector2(_turret_yaw, 0.0)


func set_puppet_aim(a: Vector2) -> void:
	_turret_yaw = a.x


func _update_visuals(dt: float) -> void:
	super._update_visuals(dt)
	if _dead:
		return
	# Stagger (EnemyStaggerAnim): the hull rocks on its suspension away from the hit and settles; the turret is thrown
	# off aim (swung and nosed up), then swings back onto it.
	var sa := _stagger_anim
	var rock := stagger_rock_basis(0.07 * anim_stagger_amp)
	if _hull_mi != null:
		_hull_mi.transform = Transform3D(rock, Vector3.ZERO)
	if _vents_mi != null:
		_vents_mi.transform = Transform3D(rock, rock * Vector3(0.0, 2.75, 3.1))
	if _turret_pivot != null:
		var off_y := (0.35 * sa.aim_off * sa.side + 0.1 * sa.shake) * anim_stagger_amp
		var off_p := 0.12 * sa.aim_off * anim_stagger_amp
		var pitch := deg_to_rad(-12.0) * heat_look.slump   # heat shutdown: the barrel droops (eased, heat_look)
		_turret_pivot.transform = Transform3D(rock * Basis.from_euler(Vector3(pitch + off_p, _turret_yaw + off_y, 0.0)),
			rock * Vector3(0.0, 2.7, -0.3))


func _spawn_component_debris(comp_id: String) -> void:
	if comp_id == "turret" and not _turret_popped:
		_turret_popped = true
		var txf := _turret_mi.global_transform if _turret_mi != null and _turret_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 2.7)
		_pop_part("tank_turret", txf, 11.5, 14.8, 3.8, 6.8, 3.2, false)
		_pop_plates(txf.origin + up * 0.8, 2, 7.0, 11.0, 4.5, 8.5)
		wreck.attach_flame(_turret_pivot, Vector3(0.0, 0.78, 0.0), Vector3(0.12, 1.0, -0.08),
			4.2, 1.05, 11.0, 6, 1.1, 0.0, "turret_socket")
		wreck.spawn_core_glow(_core_rupture_pos(), _core_rupture_scale(), false)


func _spawn_death_debris(_cause: String) -> void:
	if not _turret_popped:
		_turret_popped = true
		var txf := _turret_mi.global_transform if _turret_mi != null and _turret_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 2.7)
		_pop_part("tank_turret", txf, 12.5, 15.8, 4.5, 7.8, 3.6, false)
	if _vents_mi != null:
		var vxf := _vents_mi.global_transform if _vents_mi.is_inside_tree() else Transform3D(global_basis, _world_pos() + up * 2.75)
		_pop_part("tank_vents", vxf, 8.5, 12.0, 4.0, 7.5, 4.5, false)
	_pop_plates(_world_pos() + up * 2.8, 3, 7.0, 12.5, 5.0, 10.0)


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 3.15, -0.3)


func _core_rupture_scale() -> float:
	return 1.35


func _wreck_flame_specs() -> Array[Dictionary]:
	return [
		{"parent": self, "pos": Vector3(0.0, 3.35, -0.3), "dir": Vector3(0.10, 1.0, -0.06),
			"length": 5.8, "width": 1.35, "speed": 11.5, "count": 7, "root": 1.35, "duration": 9.0, "tag": "hull_core"},
		{"parent": self, "pos": Vector3(0.0, 2.95, 3.0), "dir": Vector3(-0.14, 1.0, 0.16),
			"length": 3.4, "width": 0.85, "speed": 10.0, "count": 5, "root": 0.85, "duration": 7.2, "tag": "vents"},
	]


func _on_component_visual_broken(comp_id: String) -> void:
	if comp_id == "turret":
		if _turret_mi != null:
			_turret_mi.visible = false
		if _turret_wreck_mi != null:
			_turret_wreck_mi.visible = true


func _on_destroyed_visual() -> void:
	if _hull_mi != null:
		_hull_mi.visible = true
		_hull_mi.material_override = EnemyMeshes.charred_material()
		_hull_mi.rotation_degrees = Vector3(2.4, 0.0, -4.2)
		_hull_mi.position = Vector3(0.0, -0.14, 0.0)
	if _turret_mi != null:
		_turret_mi.visible = false
	if _vents_mi != null:
		_vents_mi.visible = false
	if _turret_wreck_mi != null:
		_turret_wreck_mi.visible = true


func _on_reset_visual() -> void:
	_turret_yaw = 0.0
	_turret_popped = false
	if _hull_mi != null:
		_hull_mi.material_override = null
		_hull_mi.rotation = Vector3.ZERO
		_hull_mi.position = Vector3.ZERO
	if _turret_mi != null:
		_turret_mi.visible = true
	if _vents_mi != null:
		_vents_mi.visible = true
	if _turret_wreck_mi != null:
		_turret_wreck_mi.visible = false
	if _turret_pivot != null:
		_turret_pivot.rotation = Vector3.ZERO
