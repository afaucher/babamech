class_name EnemyDrone
extends EnemyFlier
## Unarmed Standoff Patrol / Scout Drone (docs/design/enemy-tactics-and-drones.md §2):
##   - NEVER shoots back (primary_weapon = "", secondary_weapon = "").
##   - Cruises 13-17 m above its deck floor along open avenues/cross-streets, repelling away from tall buildings & pillars.
##   - Hears distant player fire (~120 m on its deck) and flies at 16 m/s to investigate and gain real visual LOS.
##   - On visual LOS: backs off to standoff orbit (90-125 m, retreating if player closes < 72 m) and fires an
##     interruptible 0.65 s Alert Beacon telegraph (kind = "beacon"). Shooting it down cancels the pull; completing it
##     calls EnemySquad.relay_beacon(..., 130 m) and re-pulses every 5.0 s while holding LOS in orbit.
##   - Zero AI on co-op puppets (inherits EnemyBase.tick puppet guard; streams pose/aim/beacon via EnemySync).
##   - Contact memory: after losing sight it keeps the contact CONTACT_MEMORY s and orbits the last seen position (no
##     instant return to patrol: that flip-flopped against the orbit when a building edge cut the sightline, so the
##     scout wiggled on the spot and never finished its beacon). A sight dropout under BEACON_DROPOUT s does not cancel
##     a beacon; the alert delay keeps counting through dropouts.
##   - Wave drones close to WAVE_CLOSE m, then orbit in their own bands inside it (WAVE_MIN..WAVE_HIGH), latched until
##     WAVE_RELEASE m, so approach and orbit never alternate on one radius.
##   - Dropships: each completed beacon asks EnemySquad.request_dropship, which allows max_drops_per_deck (1) per deck
##     per mission and one active per deck: a scout's 5 s re-pulses only re-alert the ground units.

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
const SPOTLIGHT_RANGE := 45.0
const INVESTIGATE_TIMEOUT := 7.5
const CONTACT_MEMORY := 8.0       ## s a lost contact is kept (orbiting its last seen position) before patrol resumes
const BEACON_DROPOUT := 0.35      ## s of lost sight a charging beacon survives
const WAVE_CLOSE := 74.0          ## wave drones fly the hunt path until this close...
const WAVE_RELEASE := 86.0        ## ...and stay in their close orbit until farther than this
const WAVE_MIN := 48.0            ## wave orbit: retreat inside this
const WAVE_LOW := 56.0            ## wave orbit: ease out inside this
const WAVE_HIGH := 68.0           ## wave orbit: ease in beyond this (stays inside WAVE_CLOSE)
const WAVE_IDEAL := 62.0
const FLANK_FLIP_CD := 4.0        ## s between deck-edge orbit reversals
const PATROL_CHECK := 0.5         ## s between patrol straight-line-blocked checks
const PATROL_STATION_SPAN := 22.0 ## a patrol loop smaller than this is a hover station
const ORBIT_REBLOCK := 12.0       ## a second tower block within this many s after reversing = boxed in: hold
const ORBIT_HOLD := 6.0           ## s of station keeping when boxed in

var _scan_yaw := 0.0
var _bank_pitch := 0.0
var _beacon_cd := 0.0
var _investigating := false
var _investigate_pos := Vector3.ZERO
var _investigate_t := 0.0
var _beacon_count := 0            ## telemetry / tests: completed beacon pulses
var _flank_flip_t := 0.0          ## s before the deck edge may reverse the orbit again
var _wave_close := false          ## wave drone has closed in (orbits in the wave bands until WAVE_RELEASE)
var _patrol_blocked := false      ## straight line to the patrol point crosses a tall building (fly the walk graph)
var _patrol_check_t := 0.0        ## s until the next _patrol_blocked check
var _patrol_goal_idx := -1        ## patrol index the cached check / path belong to
var _orbit_hold_t := 0.0          ## s left keeping station (orbit arc blocked by towers both ways)
var _since_block := 99.0          ## s since the orbit last ran into a full-height tower

var _optic_mi: MeshInstance3D
var _cone_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "drone"
	contact_memory = CONTACT_MEMORY


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"_scan_yaw": Net.OWNER, "_bank_pitch": Net.OWNER, "_beacon_cd": Net.PRIVATE, "_investigating": Net.PRIVATE,
		"_investigate_pos": Net.PRIVATE, "_investigate_t": Net.PRIVATE, "_beacon_count": Net.PRIVATE,
		"_flank_flip_t": Net.PRIVATE, "_wave_close": Net.PRIVATE,
		"_patrol_blocked": Net.PRIVATE, "_patrol_check_t": Net.PRIVATE, "_patrol_goal_idx": Net.PRIVATE,
		"_orbit_hold_t": Net.PRIVATE, "_since_block": Net.PRIVATE,
		"_optic_mi": Net.LOCAL, "_cone_mi": Net.LOCAL,
	})
	return f


func _wreck_ground_radius() -> float:
	return 0.75


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
	_cone_mi.visible = false
	_body_pivot.add_child(_cone_mi)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	return global_transform * Vector3(0.0, 0.75, 0.0) if is_inside_tree() else position + up * 0.75


func puppet_aim() -> Vector2:
	return Vector2(_scan_yaw, _bank_pitch)


func set_puppet_aim(a: Vector2) -> void:
	_scan_yaw = a.x
	_bank_pitch = a.y


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
		_set_alert_state()
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


# --- EnemyBase state-machine hooks: aerial recon, gunfire investigation, standoff orbit, 0.65 s Alert Beacon ---------

func _air_timers(dt: float) -> void:
	if _beacon_cd > 0.0:
		_beacon_cd = maxf(_beacon_cd - dt, 0.0)


func _air_knock_damp() -> float:
	return 14.0


func _on_ai_disabled(reason: String) -> void:
	_cancel_telegraph(reason)


func _ai_perceive(space: PhysicsDirectSpaceState3D) -> CombatTarget:
	return _acquire_visual_target(space)


## The drone's live step (replaces the base one): contact memory, hunt / investigate / patrol, then the standoff orbit
## and the beacon while it sees its contact.
func _ai_live(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	# Visual perception (wide 160 deg belly scanner).
	var target := _ai_perceive(space)
	if target == null:
		_has_los = false
		_lost_t += dt
		var keep := _contact_held()
		if ai_state == STATE_TELEGRAPH:
			if keep and _lost_t <= BEACON_DROPOUT:
				# A brief dropout (a building edge flicking across the sightline) does not cancel the beacon.
				_contact_t = maxf(_contact_t - dt, 0.0)
				_step_standoff_orbit(dt, _last_seen_pos, space)
				_telegraph_t += dt
				if _telegraph_t >= _telegraph_dur:
					_complete_beacon(_last_target_ref, _last_seen_pos)
				return
			_cancel_telegraph("lost_los")
			ai_state = STATE_FLANK if (_investigating or _hunting or keep) else STATE_PATROL
		if keep:
			# Contact memory: keep the contact and orbit where it was last seen (no snap back to patrol).
			_contact_t = maxf(_contact_t - dt, 0.0)
			if ai_state == STATE_ALERT:
				_alert_timer -= dt   # the alert delay counts through dropouts
				if _alert_timer <= 0.0:
					ai_state = STATE_FLANK
			elif not is_alerted():
				ai_state = STATE_FLANK
			_step_standoff_orbit(dt, _last_seen_pos, space)
			return
		_contact_t = 0.0
		if _hunting:
			var hunt_pos := Vector3.ZERO
			var b_entry := _board_entry()
			if not b_entry.is_empty():
				hunt_pos = b_entry["pos"] as Vector3
			elif defend_target_id != "" and squad != null and squad.has_method("live_defend_asset"):
				var relay := squad.live_defend_asset(defend_target_id) as AssetTarget
				if relay != null:
					hunt_pos = _target_aim_center(relay)
			if hunt_pos != Vector3.ZERO:
				ai_state = STATE_FLANK
				_fly_hunt_path(hunt_pos, _cruise_alt, float(_cfg.get("flank_speed", 16.0)) * speed_scale, dt, space)
				return
		if _investigating:
			_step_investigate(dt, space)
		else:
			if ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_COOLDOWN]:
				_emit_squad("alerted", {"id": target_id, "state": "lost", "pos": _world_pos()})
			_step_drone_patrol(dt, space)
		return

	# Real visual LOS contact!
	_has_los = true
	_contact_seen()
	_hunt_t = 0.0
	if squad != null and squad.has_method("note_deck_activity"):
		squad.note_deck_activity(spawn_deck)
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
	var force_scan := (ai_state == STATE_TELEGRAPH) or not _perc_valid or _perc_t <= 0.0 \
		or (_cached_target != null and (not is_instance_valid(_cached_target) or not _cached_target.is_hittable()))
	if not force_scan:
		return _cached_target
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	var was_valid := _perc_valid
	_perc_valid = true
	_perc_t = _perception_interval() if was_valid else _perc_stagger_offset()
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
		if (t is AssetTarget) and not _can_target_asset(t as AssetTarget):
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
		if in_fov and _check_los(eye, tp, space, t) and d < best_d:
			best = t
			best_d = d
	_cached_target = best
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.acquire", Time.get_ticks_usec() - t0)
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
	if squad != null and squad.has_method("request_dropship"):
		squad.request_dropship(target_pos, spawn_deck)


func _step_drone_patrol(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if _patrol_points.is_empty():
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	ai_state = STATE_PATROL
	# A loop too small to fly (every point within PATROL_STATION_SPAN, e.g. a wave unit's spawn spot) is a station: it
	# hovers over its centre instead of bouncing between points closer than the arrival radius allows.
	var lo := _patrol_points[0]
	var hi := _patrol_points[0]
	for p: Vector2 in _patrol_points:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	if (hi - lo).length() < PATROL_STATION_SPAN:
		var c_w := _arc_to_world_alt((lo + hi) * 0.5, _cruise_alt)
		var to_c := c_w - _world_pos()
		to_c -= up * to_c.dot(up)
		if to_c.length() > 3.0:
			_fly_toward(c_w, _cruise_alt, float(_cfg.get("move_speed", 12.5)) * speed_scale * clampf(to_c.length() / 12.0, 0.25, 1.0), dt, space)
		else:
			_hover_station(_cruise_alt, dt, Vector3(NAN, NAN, NAN))
		return
	var goal_arc := _patrol_points[_patrol_idx % _patrol_points.size()]
	var goal_w := _arc_to_world_alt(goal_arc, _cruise_alt)
	var diff := goal_w - _world_pos()
	diff -= up * diff.dot(up)
	if diff.length() < 7.5:
		_patrol_idx = (_patrol_idx + 1) % _patrol_points.size()
		goal_w = _arc_to_world_alt(_patrol_points[_patrol_idx], _cruise_alt)
	var spd := float(_cfg.get("move_speed", 12.5)) * speed_scale
	# A straight line through a tall building (after an orbit or a hunt left the route) is flown on the walk graph.
	# The path is planned ONCE when the line is found blocked and followed to its end without replanning (a replan
	# from each new position, or re-testing the line every check, changed the first waypoint under it: back and forth).
	var gi := _patrol_idx % _patrol_points.size()
	if gi != _patrol_goal_idx:
		_patrol_goal_idx = gi
		_patrol_blocked = false
		_patrol_check_t = 0.0
	var here := _world_to_arc2(_world_pos())
	if not _patrol_blocked:
		_patrol_check_t -= dt
		if _patrol_check_t <= 0.0:
			_patrol_check_t = PATROL_CHECK
			if _tall_line_blocked(here, _patrol_points[gi]) and squad != null and squad.has_method("find_arc_path"):
				_path_points = squad.find_arc_path(here, _patrol_points[gi], spawn_deck)
				_path_timer = 0.0   # a hunt that takes over replans at once instead of flying this route
				_patrol_blocked = not _path_points.is_empty()
				if not _patrol_blocked:
					_patrol_check_t = PATROL_CHECK * 6.0   # no route: fly straight a while before asking again
	var steer := goal_w
	if _patrol_blocked:
		while not _path_points.is_empty() and here.distance_to(_path_points[0]) < 9.0:
			_path_points.pop_front()
		if _path_points.is_empty():
			_patrol_blocked = false   # route flown: straight to the point (re-tested at the next check)
		else:
			steer = _arc_to_world_alt(_path_points[0], _cruise_alt)
	_fly_toward(steer, _cruise_alt, spd, dt, space)


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
	# While holding (_orbit_hold_t: its arc is blocked by towers both ways) it keeps station: radial moves only.
	var tan_k := 0.0 if _orbit_hold_t > 0.0 else 1.0
	var tangent := radial.cross(up).normalized() * _flank_sign * tan_k
	var spd := float(_cfg.get("flank_speed", 16.0)) * speed_scale
	var b_min := STANDOFF_MIN
	var b_low := STANDOFF_LOW
	var b_high := STANDOFF_HIGH
	var b_ideal := STANDOFF_IDEAL
	if wave != "":
		# Wave drones close inside active combat range (<= WAVE_CLOSE) and then orbit in their own bands, all inside
		# it, latched until WAVE_RELEASE: the old 90-125 m bands pushed them straight back out past 74 m, so approach
		# and orbit alternated every frame on the 74 m line.
		if dist <= WAVE_CLOSE:
			_wave_close = true
		elif dist > WAVE_RELEASE:
			_wave_close = false
		if not _wave_close:
			_fly_hunt_path(target_pos, 15.0, spd, dt, space)
			return
		b_min = WAVE_MIN
		b_low = WAVE_LOW
		b_high = WAVE_HIGH
		b_ideal = WAVE_IDEAL
	var raw := Vector3.ZERO
	var alt := 16.0
	if dist < b_min:
		# Player closed inside the inner band: actively retreat while maintaining angled sightline!
		raw = radial * 0.88 + tangent * 0.42
		alt = 16.8
	elif dist < b_low:
		raw = radial * 0.48 + tangent * 0.88
		spd *= 0.92
	elif dist > b_high:
		raw = -radial * 0.55 + tangent * 0.84
		spd *= 0.90
		alt = 15.0
	else:
		# Sweet spot: smooth tangential standoff orbit circling the firefight.
		var bias := clampf((b_ideal - dist) / ((b_high - b_low) * 0.5), -0.25, 0.25)
		raw = tangent + radial * bias
		spd *= 0.84
		alt = 15.5
	var rl := raw.length()
	if rl < 1e-3:
		_hover_station(alt, dt, target_pos)
		return
	spd *= minf(rl, 1.0)
	_fly_toward(pos + raw / rl * 24.0, alt, spd, dt, space, target_pos)


# --- EnemyFlier flight hooks (the drone's tuning of _fly_toward) ---------------------------------------------------

func _air_alt_min() -> float:
	return ALT_MIN


func _air_low_floor() -> float:
	return ALT_MIN - 1.0


func _air_descend_rate() -> float:
	return 6.5


func _air_repel_weight() -> float:
	return 1.8


func _repel_min_h(cur_alt: float) -> float:
	return maxf(ALT_MIN, cur_alt) - 1.5


func _air_turn_default() -> float:
	return 3.4


func _air_speed_default() -> float:
	return 16.0


func _air_fly_timers(dt: float) -> void:
	super._air_fly_timers(dt)
	if _flank_flip_t > 0.0:
		_flank_flip_t = maxf(_flank_flip_t - dt, 0.0)
	if _orbit_hold_t > 0.0:
		_orbit_hold_t = maxf(_orbit_hold_t - dt, 0.0)
	_since_block = minf(_since_block + dt, 99.0)


## Keep inside own deck's district walls and flip the orbit sign near the boundary.
func _air_keep_in(pos: Vector3, cur_arc: Vector2, dir: Vector3, _want_alt: float) -> Vector3:
	var d_plan := _air_deck_plan()
	if d_plan != null:
		var ext: Rect2 = d_plan.extent.grow(-10.0)
		if not ext.has_point(cur_arc):
			# Back across the edge it crossed (straight in, not toward the deck centre: near a deck end the centre
			# lies along the edge, and that push dragged a patrol away from its point at the edge, back and forth).
			var in_arc := Vector2(clampf(cur_arc.x, ext.position.x, ext.end.x), clampf(cur_arc.y, ext.position.y, ext.end.y)) - cur_arc
			var inward := _arc_dir_to_world(pos, in_arc) if in_arc.length_squared() > 1e-6 else Vector3.ZERO
			if inward.length_squared() > 1e-4:
				dir = (dir * 0.35 + inward.normalized() * 0.95).normalized()
				# Reverse the orbit at most once per FLANK_FLIP_CD: flipping on every tick outside made a drone
				# pressed against the edge bounce in and out and slide back and forth along it.
				if _flank_flip_t <= 0.0:
					_flank_sign = -_flank_sign
					_flank_flip_t = FLANK_FLIP_CD
	return dir


## Orbiting (look_target set) into a full-height tower: go round the other way instead of pressing on (the side-step and
## the orbit tangent took turns at the wall, holding the drone in place). Blocked again soon after reversing = boxed in
## between towers: keep station a while (no pacing).
func _on_air_wall(hit_d: float, look_target: Vector3) -> void:
	if not is_nan(look_target.x) and hit_d < 12.0 and _orbit_hold_t <= 0.0:
		if _since_block < ORBIT_REBLOCK:
			_orbit_hold_t = ORBIT_HOLD
		elif _flank_flip_t <= 0.0:
			_flank_sign = -_flank_sign
			_flank_flip_t = FLANK_FLIP_CD
		_since_block = 0.0


func _air_after_move(_dir: Vector3, _new_fwd: Vector3, _dt: float) -> void:
	_bank_pitch = clampf(-0.22 * move_speed_ratio, -0.30, 0.30)


func _on_air_hunt_path() -> void:
	_patrol_goal_idx = -1   # back on patrol later: re-plan from wherever the hunt left it


func _update_visuals(dt: float) -> void:
	_hover_t += dt
	if not puppet:
		_scan_yaw = sin(_hover_t * 2.1) * 0.45 if not is_alerted() else 0.0
	if _body_pivot != null:
		var bob := sin(_hover_t * 3.8) * 0.22
		_body_pivot.position.y = bob
		_body_pivot.rotation = Vector3(_bank_pitch, _scan_yaw, sin(_hover_t * 2.4) * 0.06)
		_step_stagger_anim(dt)   # stagger: the hull rocks away from the hit and settles (EnemyStaggerAnim)
		_body_pivot.basis = stagger_rock_basis(0.35 * anim_stagger_amp) * _body_pivot.basis
	_update_spotlight()
	if _telegraph_fx != null:
		if ai_state == STATE_TELEGRAPH and _telegraph_dur > 0.0:
			var frac := clampf(_telegraph_t / _telegraph_dur, 0.0, 1.0)
			_telegraph_fx.show_beacon_flare(muzzle_world(BEACON_WEAPON), up, frac, dt)
		else:
			_telegraph_fx.hide_telegraph()
			_telegraph_fx.tick_only(dt)
		_update_reveal_fx(dt)
	if _status_bar != null:
		var tag := "OVERHEAT" if heat.shutdown else ("STAGGER" if knock.staggered() else "")
		_status_bar.refresh(core_hp_ratio(), heat_ratio, is_alerted(), ai_state == STATE_TELEGRAPH, tag, _dead, dt, revealed)


## Show the belly spotlight ONLY when alerted and locking onto a nearby player mech (<= 45 m), aimed directly at it!
func _update_spotlight() -> void:
	if _cone_mi == null or not is_instance_valid(_cone_mi):
		return
	var allow := not _dead and not heat.shutdown and is_alerted() and world != null
	if allow:
		if puppet:
			allow = ai_state in [STATE_ENGAGE, STATE_TELEGRAPH, STATE_FLANK]
		else:
			allow = _has_los
	if not allow:
		_cone_mi.visible = false
		return
	var origin := _cone_mi.global_position if _cone_mi.is_inside_tree() else _world_pos()
	var best_t: CombatTarget = null
	var best_d2 := SPOTLIGHT_RANGE * SPOTLIGHT_RANGE
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or not t.is_hittable() or not t.is_inside_tree():
			continue
		if squad != null and squad.has_method("on_deck") and not squad.on_deck(t.global_position, spawn_deck):
			continue
		var tp := _target_aim_center(t)
		var d2 := origin.distance_squared_to(tp)
		if d2 <= best_d2:
			best_d2 = d2
			best_t = t
	if best_t == null:
		_cone_mi.visible = false
		return
	_cone_mi.visible = true
	if _cone_mi.is_inside_tree():
		var aim_p := _target_aim_center(best_t)
		var to_p := aim_p - origin
		var dist := to_p.length()
		if dist > 0.25:
			# drone_cone extends from origin along local -Y -> set +Y = -aim_dir so cone points directly at player!
			var y_ax := -(to_p / dist)
			var ref := up if absf(y_ax.dot(up)) < 0.95 else Vector3.RIGHT
			var x_ax := ref.cross(y_ax).normalized()
			var z_ax := x_ax.cross(y_ax).normalized()
			var len_scale := clampf(dist / 10.5, 0.85, 2.0)
			_cone_mi.global_basis = Basis(x_ax, y_ax, z_ax) * Basis.from_scale(Vector3(1.0, len_scale, 1.0))


func _spawn_death_debris(_cause: String) -> void:
	var xf := global_transform if is_inside_tree() else Transform3D(Basis.IDENTITY, _world_pos())
	if _optic_mi != null:
		var oxf := _optic_mi.global_transform if _optic_mi.is_inside_tree() else xf
		_pop_part("drone_optic", oxf, 4.5, 8.0, 4.0, 7.5, 6.8, false)
	_pop_plates(_world_pos(), 2, 3.5, 6.5, 4.0, 7.5)


func _on_destroyed_visual() -> void:
	if _hull_mi != null and is_instance_valid(_hull_mi):
		_hull_mi.visible = true
		_hull_mi.material_override = EnemyMeshes.charred_material()
	if _optic_mi != null and is_instance_valid(_optic_mi):
		_optic_mi.visible = false
	if _cone_mi != null and is_instance_valid(_cone_mi):
		_cone_mi.visible = false


func _wreck_flame_specs() -> Array[Dictionary]:
	return [{
		"parent": _body_pivot if _body_pivot != null else self,
		"pos": Vector3(0.0, 0.18, 0.0), "dir": Vector3(0.08, 1.0, 0.06),
		"length": 2.6, "width": 0.68, "speed": 10.0, "count": 5, "root": 0.72, "duration": 6.5, "tag": "drone_core",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 0.1, 0.0)


func _core_rupture_scale() -> float:
	return 0.65


func _on_reset_visual() -> void:
	_scan_yaw = 0.0
	_bank_pitch = 0.0
	_beacon_cd = 0.0
	_investigating = false
	_investigate_t = 0.0
	_beacon_count = 0
	_avoid_t = 0.0
	_air_probe_t = 0.0
	_air_climb_alt = 0.0
	_air_steer_yaw = 0.0
	_air_spd_scale = 1.0
	_contact_t = 0.0
	_lost_t = 0.0
	_flank_flip_t = 0.0
	_wave_close = false
	_patrol_blocked = false
	_patrol_check_t = 0.0
	_patrol_goal_idx = -1
	_orbit_hold_t = 0.0
	_since_block = 99.0
	if _hull_mi != null:
		_hull_mi.visible = true
		_hull_mi.material_override = null
		_hull_mi.material_overlay = null
	if _optic_mi != null:
		_optic_mi.visible = true
	if _cone_mi != null:
		_cone_mi.visible = false
	if _body_pivot != null:
		_body_pivot.position = Vector3.ZERO
		_body_pivot.rotation = Vector3.ZERO
