class_name EnemyDrone
extends EnemyBase
## Unarmed Standoff Patrol / Scout Drone (docs/design/enemy-tactics-and-drones.md §2):
##   - NEVER shoots back (primary_weapon = "", secondary_weapon = "").
##   - Cruises 13-17 m above its deck floor along open avenues/cross-streets, repelling away from tall buildings & pillars.
##   - Hears distant player fire (~120 m on its deck) and flies at 16 m/s to investigate and gain real visual LOS.
##   - On visual LOS: backs off to standoff orbit (90-125 m, retreating if player closes < 72 m) and fires an
##     interruptible 0.65 s Alert Beacon telegraph (kind = "beacon"). Shooting it down cancels the pull; completing it
##     calls EnemySquad.relay_beacon(..., 130 m) and re-pulses every 5.0 s while holding LOS in orbit.
##   - Zero AI on co-op puppets (inherits EnemyBase.tick puppet guard; streams pose/aim/beacon via EnemySync).

const BEACON_WEAPON := "enemy_beacon"
const BEACON_DURATION := 0.65
const BEACON_COOLDOWN := 5.0
const BEACON_RADIUS := 130.0
const STANDOFF_MIN := 72.0
const STANDOFF_LOW := 90.0
const STANDOFF_HIGH := 125.0
const STANDOFF_IDEAL := 105.0
const ALT_MIN := 13.0
const ALT_MAX := 17.5
const INVESTIGATE_TIMEOUT := 7.5

var _scan_yaw := 0.0
var _bank_pitch := 0.0
var _hover_t := 0.0
var _cruise_alt := 15.0
var _beacon_cd := 0.0
var _investigating := false
var _investigate_pos := Vector3.ZERO
var _investigate_t := 0.0
var _beacon_count := 0            ## telemetry / tests: completed beacon pulses

var _body_pivot: Node3D
var _hull_mi: MeshInstance3D
var _optic_mi: MeshInstance3D
var _cone_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "drone"


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"_scan_yaw": Net.OWNER, "_bank_pitch": Net.OWNER, "_hover_t": Net.LOCAL,
		"_cruise_alt": Net.SPAWN, "_beacon_cd": Net.PRIVATE, "_investigating": Net.PRIVATE,
		"_investigate_pos": Net.PRIVATE, "_investigate_t": Net.PRIVATE, "_beacon_count": Net.PRIVATE,
		"_body_pivot": Net.LOCAL, "_hull_mi": Net.LOCAL, "_optic_mi": Net.LOCAL, "_cone_mi": Net.LOCAL,
	})
	return f


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	super.configure(type_id, id, w, sq, r, seed_val, hp_mult)
	_cruise_alt = clampf(float(_cfg.get("cruise_alt", 15.0)), ALT_MIN, ALT_MAX)


func _build_visuals() -> void:
	_body_pivot = Node3D.new()
	_body_pivot.name = "BodyPivot"
	add_child(_body_pivot)
	_hull_mi = EnemyMeshes.instance("drone_hull")
	_body_pivot.add_child(_hull_mi)
	_register_comp_mesh("hull", _hull_mi)
	_optic_mi = EnemyMeshes.instance("drone_optic")
	_optic_mi.position = Vector3(0.0, -0.35, -0.55)
	_body_pivot.add_child(_optic_mi)
	_register_comp_mesh("optic", _optic_mi)
	_cone_mi = EnemyMeshes.instance("drone_cone")
	_cone_mi.position = Vector3(0.0, -0.45, -0.55)
	_cone_mi.rotation = Vector3(deg_to_rad(36.0), 0.0, 0.0)
	_cone_mi.material_override = EnemyMeshes.scanner_material()
	_cone_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_body_pivot.add_child(_cone_mi)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	return global_transform * Vector3(0.0, 0.75, 0.0) if is_inside_tree() else position + up * 0.75


func puppet_aim() -> Vector2:
	return Vector2(_scan_yaw, _bank_pitch)


func set_puppet_aim(a: Vector2) -> void:
	_scan_yaw = a.x
	_bank_pitch = a.y


## Aerial drones hover above the deck floor; hold current hover plane so Knockback gravity never drags an idle/flying drone down.
func _update_dynamic_ground(pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	ground_y = pos.dot(up)


## Hearing hook (Weapons' nearby-fire pass + 120 m drone hearing radius): investigate gunfire WITHOUT blindly alerting
## ground defenders before establishing real visual LOS!
func hear_fire(shooter: CombatTarget) -> void:
	if _dead or puppet or ai_mode != "live" or shooter == null or not is_instance_valid(shooter):
		return
	if _has_los:
		return
	_investigate_pos = _target_aim_center(shooter)
	_investigating = true
	_investigate_t = INVESTIGATE_TIMEOUT
	_last_target_ref = shooter
	_target_id = shooter.target_id
	_last_seen_pos = _investigate_pos
	_aim_point = _investigate_pos
	if not is_alerted():
		ai_state = STATE_ALERT
		_alert_timer = 0.15
		_relay_timer = -1.0   # drones never blindly ground-relay on sound; they fly to LOS and fire their Beacon!
		alerted.emit(self, shooter.target_id)
		_emit_squad("alerted", {"id": target_id, "state": "spotted", "pos": _world_pos()})


func _on_damaged_alert(src: String) -> void:
	if _dead or puppet or ai_mode == "idle":
		return
	if world != null:
		for t: CombatTarget in world.targets:
			if is_instance_valid(t) and t.target_id == src and t.team != team:
				hear_fire(t)
				return


## Unarmed: never shoots weapons (only fires interruptible Alert Beacons).
func _choose_weapon(_target_pos: Vector3) -> String:
	return ""


func _fire_one_round(_st: Dictionary) -> void:
	pass


## Override AI state machine cleanly for aerial recon, gunfire investigation, standoff orbit, and 0.65 s Alert Beacon.
func _step_ai(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if _beacon_cd > 0.0:
		_beacon_cd = maxf(_beacon_cd - dt, 0.0)
	# Damp airborne knockback velocity smoothly back to zero so light hits cause a crisp tumble then recovery.
	if knock.moving():
		knock.velocity = knock.velocity.move_toward(Vector3.ZERO, 14.0 * dt)

	if ai_mode == "idle":
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	if ai_mode == "overheat" or heat.shutdown:
		if ai_mode == "overheat" and not heat.shutdown:
			heat.add(heat.cap)
		ai_state = STATE_OVERHEATED
		_cancel_telegraph("overheat")
		_align_to_ring()
		return
	if knock.staggered():
		ai_state = STATE_STAGGERED
		_cancel_telegraph("stagger")
		_align_to_ring()
		return

	# Visual perception (wide 160 deg belly scanner).
	var target := _acquire_visual_target(space)
	if target == null:
		_has_los = false
		if ai_state == STATE_TELEGRAPH:
			_cancel_telegraph("lost_los")
			ai_state = STATE_FLANK if _investigating else STATE_PATROL
		if _investigating:
			_step_investigate(dt, space)
		else:
			if ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_COOLDOWN]:
				_emit_squad("alerted", {"id": target_id, "state": "lost", "pos": _world_pos()})
			_step_drone_patrol(dt, space)
		return

	# Real visual LOS contact!
	_has_los = true
	_investigating = false
	_target_id = target.target_id
	_last_target_ref = target
	var target_pos := _target_aim_center(target)
	_last_seen_pos = target_pos
	_aim_point = target_pos
	_no_los_time = 0.0

	if not is_alerted():
		ai_state = STATE_ALERT
		_alert_timer = 0.15
		_relay_timer = -1.0
		alerted.emit(self, target.target_id)
		_emit_squad("alerted", {"id": target_id, "state": "spotted", "pos": _world_pos()})

	# Always maintain standoff orbit even while charging the Alert Beacon!
	_step_standoff_orbit(dt, target_pos, space)

	if ai_state == STATE_ALERT:
		_alert_timer -= dt
		if _alert_timer <= 0.0:
			ai_state = STATE_FLANK
		return

	if ai_state == STATE_TELEGRAPH:
		_telegraph_t += dt
		_locked_aim = target_pos
		if _telegraph_t >= _telegraph_dur:
			_complete_beacon(target, target_pos)
		return

	# Trigger interruptible 0.65 s Alert Beacon when cooldown is ready.
	if _beacon_cd <= 0.0:
		_begin_beacon(target_pos)


func _acquire_visual_target(space: PhysicsDirectSpaceState3D) -> CombatTarget:
	if world == null:
		return null
	var eye := eye_world()
	var eff_range := sight_range if (is_alerted() or _investigating or ai_mode == "telegraph_loop") \
		else minf(sight_range, float(_cfg.get("patrol_sight_range", 115.0)))
	var fov_cos := cos(deg_to_rad(float(_cfg.get("fov_deg", 160.0)) * 0.5))
	var fwd := -global_basis.z if is_inside_tree() else Vector3.FORWARD
	var best: CombatTarget = null
	var best_d := eff_range
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t == self or not t.is_hittable():
			continue
		if t.team == team or t.team == "":
			continue
		if squad != null and squad.has_method("on_deck") and not squad.on_deck(t.global_position, spawn_deck):
			continue
		var tp := _target_aim_center(t)
		var d := eye.distance_to(tp)
		if d > eff_range:
			continue
		var flat_to := (tp - eye)
		flat_to -= up * flat_to.dot(up)
		var in_fov := is_alerted() or _investigating or ai_mode == "telegraph_loop" \
			or flat_to.length_squared() < 1e-4 or fwd.dot(flat_to.normalized()) >= fov_cos
		if in_fov and _check_los(eye, tp, space) and d < best_d:
			best = t
			best_d = d
	return best


func _begin_beacon(target_pos: Vector3) -> void:
	_active_weapon = BEACON_WEAPON
	_telegraph_dur = maxf(BEACON_DURATION * telegraph_scale, EnemyCatalog.MIN_TELEGRAPH)
	_telegraph_t = 0.0
	_locked_aim = target_pos
	ai_state = STATE_TELEGRAPH
	var pos := muzzle_world(BEACON_WEAPON)
	telegraph_started.emit(self, BEACON_WEAPON, _telegraph_dur, pos)
	_emit_squad("telegraph_started", {
		"id": target_id, "weapon": BEACON_WEAPON, "kind": "beacon",
		"pos": pos, "target_pos": target_pos, "duration": _telegraph_dur,
	})


func _complete_beacon(target: CombatTarget, target_pos: Vector3) -> void:
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	_beacon_cd = BEACON_COOLDOWN
	_beacon_count += 1
	ai_state = STATE_FLANK
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()
		_telegraph_fx.trigger_relay_ring(_world_pos(), up)
	comms_relayed.emit(self)
	if squad != null and squad.has_method("relay_beacon"):
		squad.relay_beacon(_world_pos(), target, target_pos, spawn_deck, BEACON_RADIUS)


func _step_drone_patrol(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if _patrol_points.is_empty():
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	ai_state = STATE_PATROL
	var goal_arc := _patrol_points[_patrol_idx % _patrol_points.size()]
	var goal_w := _arc_to_world_alt(goal_arc, _cruise_alt)
	if _world_pos().distance_to(goal_w) < 7.0:
		_patrol_idx = (_patrol_idx + 1) % _patrol_points.size()
		goal_w = _arc_to_world_alt(_patrol_points[_patrol_idx], _cruise_alt)
	_fly_toward(goal_w, _cruise_alt, float(_cfg.get("move_speed", 12.5)) * speed_scale, dt, space)


func _step_investigate(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	ai_state = STATE_FLANK
	_investigate_t -= dt
	var pos := _world_pos()
	var to_inv := _investigate_pos - pos
	to_inv -= up * to_inv.dot(up)
	if _investigate_t <= 0.0 or to_inv.length() < 34.0:
		_investigating = false
		ai_state = STATE_PATROL
		return
	_fly_toward(_investigate_pos, 15.5, float(_cfg.get("flank_speed", 16.0)) * speed_scale, dt, space)


func _step_standoff_orbit(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var pos := _world_pos()
	var away := pos - target_pos
	away -= up * away.dot(up)
	var dist := away.length()
	var radial := away / dist if dist > 0.1 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var tangent := radial.cross(up).normalized() * _flank_sign
	var dir := Vector3.ZERO
	var spd := float(_cfg.get("flank_speed", 16.0)) * speed_scale
	var alt := 16.0
	if dist < STANDOFF_MIN:
		# Player closed inside 72 m: actively retreat while maintaining angled sightline!
		dir = (radial * 0.88 + tangent * 0.42).normalized()
		alt = 16.8
	elif dist < STANDOFF_LOW:
		dir = (radial * 0.48 + tangent * 0.88).normalized()
		spd *= 0.92
		alt = 16.0
	elif dist > STANDOFF_HIGH:
		dir = (-radial * 0.55 + tangent * 0.84).normalized()
		spd *= 0.90
		alt = 15.0
	else:
		# Sweet spot (90-125 m): smooth tangential standoff orbit circling the firefight.
		var bias := clampf((STANDOFF_IDEAL - dist) / 25.0, -0.25, 0.25)
		dir = (tangent + radial * bias).normalized()
		spd *= 0.84
		alt = 15.5
	_fly_toward(pos + dir * 24.0, alt, spd, dt, space, target_pos)


func _fly_toward(goal_w: Vector3, want_alt: float, spd: float, dt: float, space: PhysicsDirectSpaceState3D,
		look_target: Vector3 = Vector3(NAN, NAN, NAN)) -> void:
	var pos := _world_pos()
	if ring != null:
		up = ring.up_at(pos)
	var to_g := goal_w - pos
	to_g -= up * to_g.dot(up)
	var dir := to_g.normalized() if to_g.length_squared() > 0.25 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	# 2D arc-space repulsion from tall buildings (> 12.5 m) & pillar cores so drones cruise cleanly over avenues.
	var cur_arc := _world_to_arc2(pos)
	var rep := _tall_obstacle_repulsion(cur_arc)
	if rep.length_squared() > 1e-4:
		var rep_w := _arc_dir_to_world(pos, rep)
		dir = (dir + rep_w * 1.8).normalized()
	# Keep inside district walls cleanly and flip orbit sign near boundary.
	if squad != null and squad.get("plan") != null:
		var ext: Rect2 = (squad.get("plan") as CityPlan).extent.grow(-10.0)
		if not ext.has_point(cur_arc):
			var center_w := _arc_to_world_alt(ext.get_center(), want_alt)
			var inward := center_w - pos
			inward -= up * inward.dot(up)
			if inward.length_squared() > 1e-4:
				dir = (dir * 0.35 + inward.normalized() * 0.95).normalized()
				_flank_sign = -_flank_sign
	# Short physics obstacle whisker at current altitude (lift or slide around tall roofs/pillars).
	var target_alt := clampf(want_alt, ALT_MIN, ALT_MAX)
	if space != null and world != null and world.use_physics:
		var look_d := body_radius + 6.0
		if _ray_blocked(space, pos, pos + dir * look_d):
			var left_d := dir.rotated(up, 0.85)
			var right_d := dir.rotated(up, -0.85)
			if not _ray_blocked(space, pos, pos + left_d * look_d):
				dir = left_d
			elif not _ray_blocked(space, pos, pos + right_d * look_d):
				dir = right_d
			else:
				dir = dir.rotated(up, _flank_sign * 1.4)
				_flank_sign = -_flank_sign
			target_alt = ALT_MAX
	var step_h := dir * spd * dt
	var cur_alt := ring.height(pos) if ring != null else pos.y
	var d_alt := clampf(target_alt - cur_alt, -6.5 * dt, 6.5 * dt)
	var next_pos := pos + step_h + up * d_alt
	if ring != null:
		up = ring.up_at(next_pos)
		var nh := clampf(ring.height(next_pos), ALT_MIN - 1.0, ALT_MAX + 1.5)
		var a3 := ring.world_to_arc(next_pos)
		next_pos = ring.arc_to_world(a3.x, a3.y, nh)
	else:
		next_pos.y = clampf(next_pos.y, ALT_MIN - 1.0, ALT_MAX + 1.5)
	# Orient forward toward look_target (when orbiting) or flight direction.
	var want_fwd := dir
	if not is_nan(look_target.x):
		var lt := look_target - next_pos
		lt -= up * lt.dot(up)
		if lt.length_squared() > 1e-4:
			want_fwd = lt.normalized()
	var cur_fwd := (-global_basis.z) if is_inside_tree() else Vector3.FORWARD
	cur_fwd = (cur_fwd - up * cur_fwd.dot(up)).normalized()
	if cur_fwd.length_squared() < 1e-6:
		cur_fwd = want_fwd
	var turn_max := float(_cfg.get("turn_rate", 3.4)) * dt
	var ang := cur_fwd.signed_angle_to(want_fwd, up)
	var new_fwd := cur_fwd.rotated(up, clampf(ang, -turn_max, turn_max)).normalized()
	if is_inside_tree():
		global_position = next_pos
		global_basis = Basis(new_fwd.cross(up).normalized(), up, -new_fwd)
	else:
		position = next_pos
	var max_s := maxf(float(_cfg.get("flank_speed", 16.0)), 0.1)
	move_speed_ratio = clampf(step_h.length() / maxf(dt, 1e-4) / max_s, 0.0, 1.0)
	_bank_pitch = clampf(-0.22 * move_speed_ratio, -0.30, 0.30)


func _tall_obstacle_repulsion(arc2: Vector2) -> Vector2:
	if squad == null or not squad.has_method("deck_occluders"):
		return Vector2.ZERO
	var occs: Array = squad.deck_occluders(spawn_deck)
	var rep := Vector2.ZERO
	var margin := 4.0
	for item: Dictionary in occs:
		if float(item["h"]) < ALT_MIN - 0.5:
			continue
		var r: Rect2 = (item["rect"] as Rect2).grow(margin)
		if not r.has_point(arc2):
			continue
		var c := r.get_center()
		var d := arc2 - c
		if d.length_squared() > 1e-4:
			rep += d.normalized()
	return rep


func _arc_dir_to_world(at: Vector3, d2: Vector2) -> Vector3:
	if ring == null:
		return Vector3(d2.x, 0.0, d2.y).normalized()
	var t_s := ring.tangent_at(at)
	var t_x := Vector3.RIGHT
	var v := t_x * d2.x + t_s * d2.y
	v -= up * v.dot(up)
	return v.normalized() if v.length_squared() > 1e-6 else Vector3.ZERO


func _arc_to_world_alt(arc2: Vector2, alt: float) -> Vector3:
	if ring != null:
		return ring.arc_to_world(arc2.x, arc2.y, alt)
	return Vector3(arc2.x, alt, arc2.y)


func _update_visuals(dt: float) -> void:
	_hover_t += dt
	if not puppet:
		_scan_yaw = sin(_hover_t * 2.1) * 0.45 if not is_alerted() else 0.0
	if _body_pivot != null:
		var bob := sin(_hover_t * 3.8) * 0.22
		_body_pivot.position.y = bob
		_body_pivot.rotation = Vector3(_bank_pitch, _scan_yaw, sin(_hover_t * 2.4) * 0.06)
	if _cone_mi != null:
		_cone_mi.visible = not _dead and not heat.shutdown
	if _telegraph_fx != null:
		if ai_state == STATE_TELEGRAPH and _telegraph_dur > 0.0:
			var frac := clampf(_telegraph_t / _telegraph_dur, 0.0, 1.0)
			_telegraph_fx.show_beacon_flare(muzzle_world(BEACON_WEAPON), up, frac, dt)
		else:
			_telegraph_fx.hide_telegraph()
			_telegraph_fx.tick_only(dt)
	if _status_bar != null:
		var tag := "OVERHEAT" if heat.shutdown else ("STAGGER" if knock.staggered() else "")
		_status_bar.refresh(core_hp_ratio(), heat_ratio, is_alerted(), ai_state == STATE_TELEGRAPH, tag, _dead, dt)


func _spawn_death_debris(_cause: String) -> void:
	var xf := global_transform if is_inside_tree() else Transform3D(Basis.IDENTITY, _world_pos())
	# Pop off charred falling core + optic chunk + armor plates so the downed drone crashes onto the deck below!
	_pop_part("drone_hull", xf, 1.5, 4.0, 3.5, 6.5, 5.5, true)
	if _optic_mi != null:
		var oxf := _optic_mi.global_transform if _optic_mi.is_inside_tree() else xf
		_pop_part("drone_optic", oxf, 4.5, 8.0, 4.0, 7.5, 6.8, false)
	_pop_plates(_world_pos(), 2, 3.5, 6.5, 4.0, 7.5)


func _on_destroyed_visual() -> void:
	if _hull_mi != null:
		_hull_mi.visible = false
	if _optic_mi != null:
		_optic_mi.visible = false
	if _cone_mi != null:
		_cone_mi.visible = false


func _start_wreck_fx() -> void:
	# Downed aerial drone falls as debris chunks onto the street/roof; don't leave a floating flame mid-air!
	_clear_flames()
	_clear_smoke()
	_wreck_cooled = true


func _on_reset_visual() -> void:
	_scan_yaw = 0.0
	_bank_pitch = 0.0
	_beacon_cd = 0.0
	_investigating = false
	_investigate_t = 0.0
	_beacon_count = 0
	if _hull_mi != null:
		_hull_mi.visible = true
	if _optic_mi != null:
		_optic_mi.visible = true
	if _cone_mi != null:
		_cone_mi.visible = true
	if _body_pivot != null:
		_body_pivot.position = Vector3.ZERO
		_body_pivot.rotation = Vector3.ZERO
