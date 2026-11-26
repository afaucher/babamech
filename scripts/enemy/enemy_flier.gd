class_name EnemyFlier
extends EnemyBase
## What the fliers share (EnemyDrone, EnemyGunship, EnemyDropDrone; docs/design/enemy-ai-structure.md): a hover plane
## (Knockback gravity never drags them down), knockback damped back to a hover, an aerial wreck that falls, and the free
## flight step `_fly_toward` the drone and the gunship steer with:
##   - altitude hold between the class's floor and CEILING_CAP, climbing over ramps / mid-rise roofs ahead; below its
##     floor (just out of a gate bay, knocked low) it climbs at the climb rate, never snaps up, and not while something
##     is right overhead (a bay's lintel: it moves out from under it first);
##   - a soft push off tall buildings from their nearest edge (edge_repulsion);
##   - a side-step round full-height pillars / towers that keeps its side (hysteresis);
##   - keep-in steering inside its deck (_air_keep_in: each class's rule) and goal clamping (_air_steer_goal);
## plus the street-path fallback (_fly_hunt_path, _tall_line_blocked), hover station, and contact memory: after losing
## sight a flier with `contact_memory` > 0 keeps the contact that long (_contact_held: the drone orbits the last seen
## position and its alert delay counts through dropouts). The gunship's contact_memory is 0 (the rule is off for it).
## Subclasses tune the flight with the _air_* hooks (floor, descent rate, repulsion, turn rate, post-move pose).

const CEILING_CAP := 34.0
const REPEL_RANGE := 8.0          ## m from a tall building's nearest edge where repulsion starts (soft falloff)

var contact_memory := 0.0         ## s a lost contact is kept (_contact_held); 0 = no contact memory
var _contact_t := 0.0             ## s of contact memory left (contact_memory after the last sight)
var _lost_t := 0.0                ## s since sight was last held
var _hover_t := 0.0               ## presentation clock (bob / hover animation)
var _cruise_alt := 15.0
var _avoid_sign := 1.0            ## committed lateral pillar-avoidance side
var _avoid_t := 0.0               ## s remaining before the side may change
var _air_probe_t := 0.0           ## 12.5 Hz throttle for aerial ramp/obstacle ray probes
var _air_climb_alt := 0.0         ## cached ramp/roof clearance target altitude
var _air_steer_yaw := 0.0         ## cached lateral sidestep angle (rad)
var _air_spd_scale := 1.0         ## cached speed damping while climbing a steep lip
var _body_pivot: Node3D
var _hull_mi: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"contact_memory": Net.SPAWN, "_contact_t": Net.PRIVATE, "_lost_t": Net.PRIVATE, "_hover_t": Net.LOCAL,
		"_cruise_alt": Net.SPAWN, "_avoid_sign": Net.PRIVATE, "_avoid_t": Net.PRIVATE, "_air_probe_t": Net.PRIVATE,
		"_air_climb_alt": Net.PRIVATE, "_air_steer_yaw": Net.PRIVATE, "_air_spd_scale": Net.PRIVATE,
		"_body_pivot": Net.LOCAL, "_hull_mi": Net.LOCAL,
	})
	return f


func _is_aerial_wreck() -> bool:
	return true


func _wreck_body_pivot() -> Node3D:
	return _body_pivot


## Fliers hold their hover plane so Knockback gravity never drags an idle / flying one down.
func _update_dynamic_ground(pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	ground_y = pos.dot(up)


## True once EnemyMeshes provides a real art-direction mesh for `part` (not its 1x1x1 36-vertex unknown fallback box).
static func has_art_mesh(part: String) -> bool:
	var m := EnemyMeshes.mesh(part)
	if m == null or m.get_surface_count() == 0:
		return false
	var aabb := m.get_aabb()
	var arrays := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if not arrays.is_empty() else PackedVector3Array()
	return verts.size() > 36 or aabb.size.length() > 2.2


# --- State-machine hooks ------------------------------------------------------------------------------------

## The class's own timers (_air_timers), then airborne knockback damped back to a hover (a crisp tumble, then recovery).
func _ai_timers(dt: float) -> void:
	_air_timers(dt)
	if knock.moving():
		knock.velocity = knock.velocity.move_toward(Vector3.ZERO, _air_knock_damp() * dt)


## Hook: per-class timers ahead of the knockback damping (default: none).
func _air_timers(_dt: float) -> void:
	pass


## Hook: m/s^2 the knockback velocity is damped by.
func _air_knock_damp() -> float:
	return 12.0


## Match an airborne target's altitude (up to CEILING_CAP) when it hovers above `base_alt` (docs/design/wasp-ai.md §1.4).
func _air_match_target_alt(target_pos: Vector3, base_alt: float, offset: float = 2.0) -> float:
	var t_alt := ring.height(target_pos) if ring != null else target_pos.y
	return clampf(maxf(base_alt, t_alt + offset), _air_alt_min(), CEILING_CAP)


# --- Contact memory -----------------------------------------------------------------------------------------

## The base state machine's target bookkeeping, plus the contact memory: refilled while seen, running down while not.
func _ai_note_target(target: CombatTarget, dt: float) -> Vector3:
	var target_pos := super._ai_note_target(target, dt)
	if _has_los:
		_contact_seen()
	else:
		_contact_lost(dt)
	return target_pos


## No target at all this tick: the contact memory runs down too.
func _on_target_dropped(dt: float) -> void:
	_contact_lost(dt)


## Sight not held this tick: count the dropout, spend memory.
func _contact_lost(dt: float) -> void:
	_lost_t += dt
	_contact_t = maxf(_contact_t - dt, 0.0)


## Sight held this tick: the memory is full again.
func _contact_seen() -> void:
	_lost_t = 0.0
	_contact_t = contact_memory


## Contact memory holds while time is left and the contact still exists, can be hit and is on this flier's deck.
func _contact_held() -> bool:
	return _contact_t > 0.0 and _contact_valid()


func _contact_valid() -> bool:
	var t := _last_target_ref
	if t == null or not is_instance_valid(t) or not t.is_hittable() or t.team == team:
		return false
	if squad != null and squad.has_method("on_deck") and not squad.on_deck(t.global_position if t.is_inside_tree() else t.position, spawn_deck):
		return false
	return true


# --- Flight --------------------------------------------------------------------------------------------------

## Hooks tuning _fly_toward: the altitude floor, the low-exit floor, the descent rate, the tall-building push, the
## catalog defaults for turn rate and top speed.
func _air_alt_min() -> float:
	return 8.0


func _air_low_floor() -> float:
	return _air_alt_min() - 0.5


func _air_descend_rate() -> float:
	return 7.5


func _air_repel_weight() -> float:
	return 2.0


func _repel_min_h(cur_alt: float) -> float:
	return cur_alt - 2.0


func _air_turn_default() -> float:
	return 2.2


func _air_speed_default() -> float:
	return 17.0


## Hook: timers _fly_toward counts down (default: the avoid side's commitment).
func _air_fly_timers(dt: float) -> void:
	if _avoid_t > 0.0:
		_avoid_t = maxf(_avoid_t - dt, 0.0)


## Hook: the goal actually steered for (default: the goal).
func _air_steer_goal(goal_w: Vector3) -> Vector3:
	return goal_w


## Hook: keep-in steering inside the deck: returns the direction (default: unchanged).
func _air_keep_in(_pos: Vector3, _cur_arc: Vector2, dir: Vector3, _want_alt: float) -> Vector3:
	return dir


## Hook: the forward ray hit something it cannot climb over (hit_d m ahead), before the side-step is chosen.
func _on_air_wall(_hit_d: float, _look_target: Vector3) -> void:
	pass


## Hook: after the move: the pose (bank / pitch) for the step just flown.
func _air_after_move(_dir: Vector3, _new_fwd: Vector3, _dt: float) -> void:
	pass


## The deck plan this flier keeps inside (null on flat arenas).
func _air_deck_plan() -> CityPlan:
	return squad.deck_plan(spawn_deck) if (squad != null and squad.has_method("deck_plan")) else (squad.get("plan") as CityPlan if squad != null else null)


## One flight step toward goal_w at want_alt (above the deck floor), facing look_target when given (else the flight).
func _fly_toward(goal_w: Vector3, want_alt: float, spd: float, dt: float, space: PhysicsDirectSpaceState3D,
		look_target: Vector3 = Vector3(NAN, NAN, NAN)) -> void:
	var pos := _world_pos()
	if ring != null:
		up = ring.up_at(pos)
	_air_fly_timers(dt)
	goal_w = _air_steer_goal(goal_w)
	var to_g := goal_w - pos
	to_g -= up * to_g.dot(up)
	var dir := to_g.normalized() if to_g.length_squared() > 0.25 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var cur_alt := ring.height(pos) if ring != null else pos.y
	# 2D arc-space repulsion from tall buildings & pillar cores so fliers cruise cleanly over the avenues.
	var cur_arc := _world_to_arc2(pos)
	var rep := _tall_obstacle_repulsion(cur_arc, cur_alt)
	if rep.length_squared() > 1e-4:
		var rep_w := _arc_dir_to_world(pos, rep)
		dir = (dir + rep_w * _air_repel_weight()).normalized()
	dir = _air_keep_in(pos, cur_arc, dir, want_alt)
	# Ramp / raised-geometry obstacle probing (throttled to 12.5 Hz, reused _ray_query, 0 allocations):
	# climb cleanly over rising ramps/roofs up to CEILING_CAP; only sidestep full-height pillars/towers!
	var alt_min := _air_alt_min()
	var target_alt := clampf(want_alt, alt_min, CEILING_CAP)
	var eff_spd := spd
	var climb_over := false
	if space != null and world != null and world.use_physics:
		_air_probe_t -= dt
		if _air_probe_t <= 0.0:
			_air_probe_t = 0.08
			_air_climb_alt = 0.0
			_air_steer_yaw = 0.0
			_air_spd_scale = 1.0
			# 1. Forward-downward slope/ramp ray to detect rising ramp decks or mid-rise roofs ahead.
			_ray_query.from = pos + dir * 10.0 + up * 4.0
			_ray_query.to = pos + dir * 10.0 - up * 16.0
			var rh := space.intersect_ray(_ray_query)
			if not rh.is_empty():
				var hit_p: Vector3 = rh["position"]
				var ground_ahead := ring.height(hit_p) if ring != null else hit_p.y
				var want_clear := ground_ahead + 5.5
				if want_clear > target_alt and want_clear <= CEILING_CAP:
					if not _air_ray_hit(space, pos + up * 7.0, pos + up * 7.0 + dir * 16.0):
						_air_climb_alt = clampf(want_clear, alt_min, CEILING_CAP)
			# 2. Forward obstacle ray (16 m): any solid (ramp deck, parapet, building, pillar).
			_ray_query.from = pos
			_ray_query.to = pos + dir * 16.0
			var fh := space.intersect_ray(_ray_query)
			if not fh.is_empty():
				var hit_d := pos.distance_to(fh["position"] as Vector3)
				var high_blocked := _air_ray_hit(space, pos + up * 7.0, pos + up * 7.0 + dir * 16.0)
				if not high_blocked and cur_alt + 6.0 <= CEILING_CAP:
					_air_climb_alt = clampf(maxf(_air_climb_alt, cur_alt + 6.5), alt_min, CEILING_CAP)
					if hit_d < body_radius + 4.5:
						_air_spd_scale = 0.45
				else:
					# Full-height pillar or tower reaching the ceiling: commit a lateral avoid side for 1.5 s.
					_on_air_wall(hit_d, look_target)
					if _avoid_t <= 0.0:
						var left_d := dir.rotated(up, 0.85)
						var right_d := dir.rotated(up, -0.85)
						var lb := _air_ray_hit(space, pos, pos + left_d * 14.0)
						var rb := _air_ray_hit(space, pos, pos + right_d * 14.0)
						# Hysteresis: change side only when the committed side is blocked and the other is open;
						# both open / both blocked keeps the side (flipping every 1.5 s there was a wiggle).
						if not lb and rb:
							_avoid_sign = 1.0
						elif not rb and lb:
							_avoid_sign = -1.0
						_avoid_t = 1.5
					_air_steer_yaw = _avoid_sign * 0.95
		if _air_climb_alt > target_alt:
			target_alt = _air_climb_alt
			climb_over = true
		if absf(_air_steer_yaw) > 0.01:
			dir = dir.rotated(up, _air_steer_yaw)
		eff_spd *= _air_spd_scale
	var step_h := dir * eff_spd * dt
	var descend := _air_descend_rate()
	var climb_rate := 12.5 if (climb_over or target_alt > cur_alt + 1.0) else descend
	var d_alt := clampf(target_alt - cur_alt, -descend * dt, climb_rate * dt)
	# Below the floor height (just out of a gate bay, or knocked low) it climbs at the climb rate, never snaps up, and
	# not while something is right overhead (a bay's lintel): it moves out from under it first.
	var low_floor := _air_low_floor()
	if cur_alt < low_floor - 0.05:
		if d_alt > 0.0 and space != null and _air_ray_hit(space, pos, pos + up * 6.0):
			d_alt = 0.0
		low_floor = minf(low_floor, cur_alt + maxf(d_alt, 0.0))
	var next_pos := pos + step_h + up * d_alt
	if ring != null:
		up = ring.up_at(next_pos)
		var nh := clampf(ring.height(next_pos), low_floor, CEILING_CAP)
		var a3 := ring.world_to_arc(next_pos)
		next_pos = ring.arc_to_world(a3.x, a3.y, nh)
	else:
		next_pos.y = clampf(next_pos.y, low_floor, CEILING_CAP)
	# Orient forward toward look_target (when orbiting / attacking) or the flight direction.
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
	var turn_max := float(_cfg.get("turn_rate", _air_turn_default())) * dt
	var ang := cur_fwd.signed_angle_to(want_fwd, up)
	var new_fwd := cur_fwd.rotated(up, clampf(ang, -turn_max, turn_max)).normalized()
	if is_inside_tree():
		global_position = next_pos
		global_basis = Basis(new_fwd.cross(up).normalized(), up, -new_fwd)
	else:
		position = next_pos
	var max_s := maxf(float(_cfg.get("flank_speed", _air_speed_default())), 0.1)
	move_speed_ratio = clampf(step_h.length() / maxf(dt, 1e-4) / max_s, 0.0, 1.0)
	_air_after_move(dir, new_fwd, dt)


## Hold position (keeping altitude and facing look_target): _fly_toward at zero speed.
func _hover_station(alt: float, dt: float, look_target: Vector3) -> void:
	_fly_toward(_world_pos() - global_basis.z * 24.0, alt, 0.0, dt, null, look_target)


## Fly the street path (walk graph, replanned every 2.5 s) to goal_w at want_alt.
func _fly_hunt_path(goal_w: Vector3, want_alt: float, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	_on_air_hunt_path()
	_path_timer -= dt
	if (_path_points.is_empty() or _path_timer <= 0.0) and squad != null and squad.has_method("find_arc_path"):
		_path_timer = 2.5
		_path_points = squad.find_arc_path(_world_to_arc2(_world_pos()), _world_to_arc2(goal_w), spawn_deck)
	var steer_goal := goal_w
	while not _path_points.is_empty():
		var wp := _arc_to_world_alt(_path_points[0], want_alt)
		var diff := wp - _world_pos()
		diff -= up * diff.dot(up)
		if diff.length() < 9.0:
			_path_points.pop_front()
		else:
			steer_goal = wp
			break
	_fly_toward(steer_goal, want_alt, spd, dt, space)


## Hook: a street-path flight step is starting (the drone forgets its planned patrol route).
func _on_air_hunt_path() -> void:
	pass


## True when arc segment a-b crosses a building tall enough to stop this flier at its floor height.
func _tall_line_blocked(a: Vector2, b: Vector2) -> bool:
	if squad == null or not squad.has_method("deck_occluders"):
		return false
	var min_h := _air_alt_min() - 1.5
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	for item: Dictionary in squad.deck_occluders(spawn_deck):
		if float(item["h"]) < min_h:
			continue
		var r: Rect2 = item["rect"]
		if hi.x < r.position.x or lo.x > r.end.x or hi.y < r.position.y or lo.y > r.end.y:
			continue
		if EnemySquad._segment_hits_rect(a, b, r):
			return true
	return false


func _air_ray_hit(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	_ray_query.from = a
	_ray_query.to = b
	return not space.intersect_ray(_ray_query).is_empty()


func _tall_obstacle_repulsion(arc2: Vector2, cur_alt: float) -> Vector2:
	if squad == null or not squad.has_method("deck_occluders"):
		return Vector2.ZERO
	return edge_repulsion(squad.deck_occluders(spawn_deck), arc2, _repel_min_h(cur_alt))


## Arc-space push off the occluders (EnemySquad.deck_occluders items {rect, h}) at least `min_h` tall: away from each
## one's NEAREST EDGE with a soft falloff (full at the wall, zero at REPEL_RANGE). It used to push from the centre of a
## rect grown by a hard margin: the push switched on / off across that margin and pointed along the wall near a corner,
## so a flier held there by its goal jittered in place.
static func edge_repulsion(occs: Array, arc2: Vector2, min_h: float) -> Vector2:
	var rep := Vector2.ZERO
	for item: Dictionary in occs:
		if float(item["h"]) < min_h:
			continue
		var r: Rect2 = item["rect"]
		if arc2.x < r.position.x - REPEL_RANGE or arc2.x > r.end.x + REPEL_RANGE \
				or arc2.y < r.position.y - REPEL_RANGE or arc2.y > r.end.y + REPEL_RANGE:
			continue
		var cp := Vector2(clampf(arc2.x, r.position.x, r.end.x), clampf(arc2.y, r.position.y, r.end.y))
		var d := arc2 - cp
		var dl := d.length()
		if dl >= REPEL_RANGE:
			continue
		if dl < 1e-3:
			# Inside the footprint: straight out through the nearest side, full strength.
			var gaps := [arc2.x - r.position.x, r.end.x - arc2.x, arc2.y - r.position.y, r.end.y - arc2.y]
			var outs := [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
			var bi := 0
			for i in 4:
				if float(gaps[i]) < float(gaps[bi]):
					bi = i
			rep += outs[bi] as Vector2
			continue
		var w := 1.0 - dl / REPEL_RANGE
		rep += d / dl * (w * w)
	return rep


## World direction (in the local floor plane) of arc-space direction d2 at `at`: the deck's x / tangent basis.
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
