class_name EnemyStrider
extends EnemyBase
## Hound Skirmisher (docs/design/enemies.md §1–4): light mobile bipedal patrol walker (3.8 x 4.2 x 5.2 m),
## flanks along streets/parks, relays sightings, showcases knockback/stagger/wall-slam, emits footsteps on stride.

## Legs (docs/design/enemy-anim): planted feet from EnemyGait (stride and cadence from the real ground speed), the
## three-part leg (EnemyMeshes strider_thigh / shin / foot) solved with LegIK.solve_two_bone, knee bent back.
const HIP_X := 1.18               ## hip joint x (the leg meshes hang from (+-1.18, HIP_Y, 0))
const HIP_Y := 2.6
const FOOT_X := 1.36              ## home of each foot (ground point under the ankle) in the unit frame
const FOOT_Z := -0.22
const RUN_DROP := 0.34            ## m the hips sink at a full run (longer reach)
const STEP_BOB := 0.12            ## m the hips dip between steps at a run
const KNEE_POLE := Vector3(0.0, -0.15, 1.0)   ## the knee bends back (and a touch down)

var _aim_yaw := 0.0
var _chassis_pivot: Node3D
var _chassis_mi: MeshInstance3D
var _sensor_mi: MeshInstance3D
var _leg_l: Node3D                ## whole-leg holders: shown only on the wreck
var _leg_r: Node3D
var _leg_l_mi: MeshInstance3D
var _leg_r_mi: MeshInstance3D
var _rig_l: Node3D                ## articulated legs: [thigh, shin, foot] under a mirror node (left) / plain node (right)
var _rig_r: Node3D
var _parts_l: Array[MeshInstance3D] = []
var _parts_r: Array[MeshInstance3D] = []
var _gait := EnemyGait.new()
var _hip_h := HIP_Y               ## current hip height (unit frame)
var anim_reach_scale := 1.0       ## lab: scales the gait's reach
var anim_lift_scale := 1.0        ## lab: scales the step lift


func _init() -> void:
	super._init()
	enemy_type = "strider"
	_init_gait()


func _init_gait() -> void:
	_gait.step_time = 0.42
	_gait.run_step_time = 0.24
	_gait.min_step_time = 0.15
	_gait.lift = 0.75
	_gait.clearance = 1.6
	_gait.settle_error = 0.2


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"_aim_yaw": Net.OWNER,
		"_chassis_pivot": Net.LOCAL, "_chassis_mi": Net.LOCAL, "_sensor_mi": Net.LOCAL,
		"_leg_l": Net.LOCAL, "_leg_r": Net.LOCAL, "_leg_l_mi": Net.LOCAL, "_leg_r_mi": Net.LOCAL,
		"_rig_l": Net.LOCAL, "_rig_r": Net.LOCAL, "_parts_l": Net.LOCAL, "_parts_r": Net.LOCAL, "_gait": Net.LOCAL,
		"_hip_h": Net.LOCAL, "anim_reach_scale": Net.LOCAL, "anim_lift_scale": Net.LOCAL})
	return f


func _chassis_mesh_name() -> String:
	return "strider_breacher_chassis" if enemy_type == "strider_breacher" else "strider_chassis"


func _build_visuals() -> void:
	_chassis_pivot = Node3D.new()
	_chassis_pivot.name = "ChassisPivot"
	_chassis_pivot.position = Vector3(0.0, 2.6, 0.0)
	add_child(_chassis_pivot)
	_chassis_mi = EnemyMeshes.instance(_chassis_mesh_name())
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
	_leg_l.visible = false
	_leg_r.visible = false
	_rig_l = Node3D.new()
	_rig_l.name = "LegRigL"
	_rig_l.scale = Vector3(-1.0, 1.0, 1.0)   # the right leg's parts, mirrored
	add_child(_rig_l)
	_rig_r = Node3D.new()
	_rig_r.name = "LegRigR"
	add_child(_rig_r)
	for part: String in ["strider_thigh", "strider_shin", "strider_foot"]:
		var ml := EnemyMeshes.instance(part)
		_rig_l.add_child(ml)
		_parts_l.append(ml)
		_register_comp_mesh("legs", ml)
		var mr := EnemyMeshes.instance(part)
		_rig_r.add_child(mr)
		_parts_r.append(mr)
		_register_comp_mesh("legs", mr)
	_pose_legs_rest()


func muzzle_world(_weapon_id: String = "") -> Vector3:
	if _chassis_pivot != null and _chassis_pivot.is_inside_tree():
		var z := -2.58 if enemy_type == "strider_breacher" else -2.5
		return _chassis_pivot.global_transform * Vector3(0.0, 0.48, z)
	return super.muzzle_world()


func _max_aim_pitch() -> float:
	return deg_to_rad(52.0)


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


func _sensor_yaw() -> float:   # perception: the forward cone follows the torso (and the hull turns past +-45 deg)
	return _aim_yaw


func puppet_aim() -> Vector2:   # co-op puppet (W4)
	return Vector2(_aim_yaw, 0.0)


func set_puppet_aim(a: Vector2) -> void:
	_aim_yaw = a.x


func _update_visuals(dt: float) -> void:
	super._update_visuals(dt)
	if _chassis_pivot == null or _dead:
		return
	var sa := _stagger_anim
	var amp := anim_stagger_amp
	var run_speed := maxf(float(_cfg.get("flank_speed", 13.5)), 1.0)
	var spd := _vis_vel.length()
	var k := clampf(spd / run_speed, 0.0, 1.0) if _grounded_now or puppet else 0.0
	# Body: hips sink with speed (longer reach) and dip between steps; the stagger knocks them along the push and down;
	# shutdown slumps them.
	var shift := sa.push * (0.55 * sa.stumble * amp)
	_hip_h = HIP_Y - RUN_DROP * k - STEP_BOB * k * (1.0 - _gait.lift_amount()) - 0.3 * sa.k * amp \
		- (0.35 if heat.shutdown else 0.0)
	_step_legs(dt, shift)
	var tilt := Basis.IDENTITY
	var axis := Vector3.UP.cross(sa.push)
	if sa.active and axis.length_squared() > 1e-6:
		tilt = Basis(axis.normalized(), (0.34 * sa.k + 0.06 * sa.shake) * amp)
	var droop := deg_to_rad(-22.0) if heat.shutdown else 0.0
	var aim_y := _aim_yaw + (0.55 * sa.aim_off * sa.side + 0.16 * sa.shake) * amp
	var aim_p := -0.12 * move_speed_ratio + droop - 0.3 * sa.aim_off * amp
	_chassis_pivot.position = Vector3(shift.x, _hip_h, shift.z)
	_chassis_pivot.basis = tilt * Basis.from_euler(Vector3(aim_p, aim_y, 0.0))
	if _sensor_mi != null:   # the sensor head takes a knock with the hit and shakes it off
		_sensor_mi.rotation = Vector3(0.45 * sa.k * amp, 0.5 * sa.shake * amp, -0.3 * sa.k * sa.side * amp)


## The legs: gait homes under the hips (unit frame -> world on the unit's own floor plane), then each leg solved to its
## planted / swinging foot. `shift`: the body's offset in the unit frame (stagger), which the homes follow.
func _step_legs(dt: float, shift: Vector3) -> void:
	if _rig_l == null or not is_inside_tree():
		return
	var xf := global_transform
	var l1 := EnemyMeshes.STRIDER_KNEE.length()
	var l2 := (EnemyMeshes.STRIDER_ANKLE - EnemyMeshes.STRIDER_KNEE).length()
	var ankle_h := EnemyMeshes.STRIDER_ANKLE.y - EnemyMeshes.STRIDER_SOLE
	var vert := _hip_h - ankle_h
	var reach_h := sqrt(maxf(pow((l1 + l2) * 0.97, 2.0) - vert * vert, 0.0))
	_gait.reach = clampf(reach_h * 0.85 * anim_reach_scale, 0.4, 2.2)
	_gait.run_speed = maxf(float(_cfg.get("flank_speed", 13.5)), 1.0)
	_gait.lift = 0.75 * anim_lift_scale
	var homes: Array[Vector3] = [xf * Vector3(-FOOT_X + shift.x, 0.0, FOOT_Z + shift.z),
		xf * Vector3(FOOT_X + shift.x, 0.0, FOOT_Z + shift.z)]
	var air := not _grounded_now and not puppet
	if air:
		for i in 2:
			homes[i] = xf * Vector3((-1.0 if i == 0 else 1.0) * FOOT_X + shift.x, _hip_h - 2.2, FOOT_Z * 0.5 + shift.z)
	_gait.update(dt, homes, up, _vis_vel, xf.origin, air)
	if _gait.landed >= 0 and _gait.speed > 0.6:
		var fp := _gait.pos[_gait.landed]
		footstep.emit(self, fp)
		_emit_squad("footstep", {"id": target_id, "pos": fp})
	var inv := xf.affine_inverse()
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var foot := inv * _gait.pos[i]
		# Canonical right-leg space: the left leg's targets mirrored across x (its rig node mirrors back).
		var hip := Vector3(HIP_X + shift.x * side, _hip_h, shift.z)
		var target := Vector3(foot.x * side, foot.y + ankle_h, foot.z)
		_pose_leg(_parts_l if i == 0 else _parts_r, hip, target, l1, l2)


func _pose_leg(parts: Array[MeshInstance3D], hip: Vector3, ankle_want: Vector3, l1: float, l2: float) -> void:
	if parts.size() < 3:
		return
	var kn0 := EnemyMeshes.STRIDER_KNEE
	var an0 := EnemyMeshes.STRIDER_ANKLE
	var r := LegIK.solve_two_bone(hip, ankle_want, l1, l2, KNEE_POLE)
	var knee: Vector3 = r["joint"]
	var ankle: Vector3 = r["end"]
	var bt := EnemyGait.limb_basis(knee - hip, KNEE_POLE, kn0, KNEE_POLE)
	parts[0].transform = Transform3D(bt, hip)
	var bs := EnemyGait.limb_basis(ankle - knee, KNEE_POLE, an0 - kn0, KNEE_POLE)
	parts[1].transform = Transform3D(bs, knee - bs * kn0)
	parts[2].transform = Transform3D(Basis.IDENTITY, ankle - an0)


func _pose_legs_rest() -> void:
	for parts: Array[MeshInstance3D] in [_parts_l, _parts_r]:
		for i in parts.size():
			parts[i].transform = Transform3D(Basis.IDENTITY, Vector3(HIP_X, HIP_Y, 0.0))


func _spawn_component_debris(comp_id: String) -> void:
	if comp_id == "legs":
		_pop_plates(_world_pos() + up * 2.2, 2, 5.5, 8.5, 3.5, 6.5)
		wreck.attach_flame(_chassis_pivot, Vector3(0.85, -0.15, 0.15), Vector3(0.42, 0.88, 0.18),
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
		_leg_l.visible = true
		_leg_l.position = Vector3(-0.9, 0.75, 0.4)
		_leg_l.rotation = Vector3(deg_to_rad(-72.0), deg_to_rad(25.0), deg_to_rad(-28.0))
	if _rig_l != null and _rig_r != null:
		_rig_l.visible = false
		_rig_r.visible = false


func _on_reset_visual() -> void:
	_aim_yaw = 0.0
	_gait = EnemyGait.new()
	_init_gait()
	_hip_h = HIP_Y
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
		_leg_l.visible = false
		_leg_r.visible = false
	if _rig_l != null and _rig_r != null:
		_rig_l.visible = true
		_rig_r.visible = true
		_pose_legs_rest()
	if _sensor_mi != null:
		_sensor_mi.rotation = Vector3.ZERO
