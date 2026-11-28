class_name EnemyGunship
extends EnemyFlier
## Close-Range Valkyrie Rocket Gunship ("gunship"):
##   - Aerial swoop-strafer hovering 8.5-15 m above its curved RingFrame deck (distinct from unarmed EnemyDrone).
##   - Closes from afar via low cover-skim flanking (9.5-11.5 m, 17 m/s, EnemyNav.find_cover_path) into <= 68 m range.
##   - Attack run: strafes laterally at 8.5-11 m banking into turns, telegraphs 0.70 s, fires 4-rocket alternating
##     left/right pod salvo (enemy_gunship_rockets), then breaks off laterally & climbs (15 m/s) during 3.4 s cooldown.
##   - Disarmable wing pods (95 HP -> disable_primary + 65 shock dmg + wing stub flame) & critical rear thrusters (85 HP, 1.5x).
##   - Automatically uses EnemyMeshes art parts ("gunship_hull", "gunship_pods", "gunship_thrusters") once present,
##     falling back cleanly to self-contained cached strictly watertight placeholder meshes in the meantime.

const ALT_MIN := 8.0
const ALT_ATTACK_LOW := 8.5
const ALT_ATTACK_HIGH := 11.0
const ALT_SKIM := 10.5
const ALT_BREAKOFF := 15.0
const ALT_MAX := 17.5
const CLOSE_ENGAGE_R := 68.0
const EVADE_RING_MIN := 45.0       ## a disarmed gunship circles its target between these (m)
const EVADE_RING_MAX := 70.0
const MUZZLE_L := Vector3(-1.9, -0.25, -2.1)
const MUZZLE_R := Vector3(1.9, -0.25, -2.1)

static var _placeholder_cache: Dictionary = {}

var _aim_yaw := 0.0
var _aim_pitch := 0.0
var _bank_roll := 0.0
var _breakoff_t := 0.0
var _breakoff_count := 0            ## telemetry / tests
var _salvo_rounds_fired := 0

var _pods_mi: MeshInstance3D
var _thrusters_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "gunship"
	_cruise_alt = 11.5
	# EnemyFlier contact memory: OFF for the gunship. Measured 2026-11-26 with the drone's 8 s: corner wiggle 194.5 s ->
	# 47.0 s over 52 runs, but test_wave_pursuit failed (seed 1 deck 1 shaft gunship min 69.1 m > 68 m), so it was backed
	# out (docs/design/enemy-ai-structure.md).
	contact_memory = 0.0


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"_aim_yaw": Net.OWNER, "_aim_pitch": Net.OWNER, "_bank_roll": Net.LOCAL, "_breakoff_t": Net.PRIVATE,
		"_breakoff_count": Net.PRIVATE, "_salvo_rounds_fired": Net.PRIVATE,
		"_pods_mi": Net.LOCAL, "_thrusters_mi": Net.LOCAL,
	})
	return f


func _wreck_ground_radius() -> float:
	return 1.25


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	super.configure(type_id, id, w, sq, r, seed_val, hp_mult)
	_cruise_alt = clampf(float(_cfg.get("cruise_alt", 11.5)), ALT_MIN, ALT_MAX)
	_cover_path_timer = _rng.randf_range(0.0, 0.45)


# --- Art-Direction Mesh Deferral + Self-Contained Watertight Placeholders ---------------------------------

## Cached, strictly watertight placeholder meshes matching the exact gunship geometry contract (5.6 W x 2.8 H x 6.8 L).
static func placeholder_mesh(part: String) -> ArrayMesh:
	if _placeholder_cache.has(part):
		return _placeholder_cache[part] as ArrayMesh
	var k := MeshKit.new()
	match part:
		"gunship_hull": _build_hull_mesh(k)
		"gunship_pods": _build_pods_mesh(k)
		"gunship_thrusters": _build_thrusters_mesh(k)
		_:
			k.box(Vector3.ONE, EnemyMeshes.ARMOR_DARK)
	var m := k.commit(LowPolyMaterials.materials())
	_placeholder_cache[part] = m
	return m


static func _build_hull_mesh(k: MeshKit) -> void:
	# Sleek armored forward-swept attack gunship fuselage (z = -3.4..+3.4 m).
	k.loft([
		MeshKit.ring(Vector3(0.0, 0.15, 3.30), 0.72, 0.42, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, 0.12, 1.40), 1.38, 0.88, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, 0.05, -0.80), 1.48, 0.92, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, -0.10, -2.65), 0.92, 0.56, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, -0.22, -3.40), 0.44, 0.28, 6, "z", 2.8),
	], [EnemyMeshes.ARMOR_DARK, EnemyMeshes.ARMOR_PLATE, EnemyMeshes.ARMOR_DARK, EnemyMeshes.ARMOR_PLATE])
	# Bold crimson nose & dorsal spine trim + armored cockpit visor glow.
	k.box(Vector3(1.10, 0.22, 3.60), EnemyMeshes.TRIM_RED, Vector3(0.0, 0.96, 0.0))
	k.box(Vector3(1.18, 0.44, 1.35), EnemyMeshes.ARMOR_DARK, Vector3(0.0, 0.52, -1.75))
	k.glow = true
	k.box(Vector3(1.02, 0.24, 0.22), EnemyMeshes.OPTIC_GLOW, Vector3(0.0, 0.44, -2.42))
	k.glow = false
	# Swept armored stub wings (span 5.2 m) + twin canted dorsal tail stabilizers (peaks y = +1.4 m -> 2.8 m H).
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 1.85, 0.18, -0.35), Vector3(0.0, side * 12.0, -side * 8.0)))
		k.box(Vector3(1.75, 0.28, 1.55), EnemyMeshes.ARMOR_PLATE)
		k.box(Vector3(1.45, 0.12, 0.46), EnemyMeshes.TRIM_RED, Vector3(0.0, 0.16, -0.32))
		k.pop()
		k.push(MeshKit.xf(Vector3(side * 0.85, 0.92, 2.55), Vector3(-16.0, 0.0, -side * 22.0)))
		k.box(Vector3(0.18, 1.15, 1.10), EnemyMeshes.ARMOR_DARK)
		k.box(Vector3(0.22, 0.26, 0.85), EnemyMeshes.TRIM_RED, Vector3(0.0, 0.35, 0.05))
		k.pop()
	# Chin target sensor turret under nose.
	k.box(Vector3(0.76, 0.42, 0.88), EnemyMeshes.STEEL, Vector3(0.0, -0.68, -2.05))


static func _build_pods_mesh(k: MeshKit) -> void:
	# Twin underslung wing rocket pods at (+/-1.9, -0.2, -0.8) with muzzles at (+/-1.9, -0.25, -2.1).
	for side: float in [-1.0, 1.0]:
		var px := side * 1.9
		k.box(Vector3(0.95, 0.88, 2.35), EnemyMeshes.ARMOR_DARK, Vector3(px, -0.20, -0.85))
		k.box(Vector3(1.02, 0.24, 1.65), EnemyMeshes.TRIM_RED, Vector3(px, -0.18, -0.80))
		k.box(Vector3(0.32, 0.36, 1.10), EnemyMeshes.STEEL, Vector3(side * 1.55, 0.15, -0.75))
		# 4 forward launch tubes per pod.
		for r in 2:
			for c in 2:
				var ox := px + (float(c) - 0.5) * 0.40
				var oy := -0.25 + (float(r) - 0.5) * 0.36
				k.tube(Vector3(ox, oy, -1.80), Vector3(ox, oy, -2.14), 0.13, 6, EnemyMeshes.STEEL)
		k.glow = true
		k.box(Vector3(0.45, 0.12, 0.10), EnemyMeshes.OPTIC_GLOW, Vector3(px, 0.26, -2.04))
		k.glow = false


static func _build_thrusters_mesh(k: MeshKit) -> void:
	# Twin rear ducted-fan VTOL thruster nacelles at (+/-2.2, 0.45, 1.1) — critical weak point!
	for side: float in [-1.0, 1.0]:
		var tx := side * 2.2
		k.box(Vector3(1.15, 0.30, 0.90), EnemyMeshes.STEEL, Vector3(side * 1.50, 0.42, 1.10))
		k.box(Vector3(1.05, 0.95, 2.15), EnemyMeshes.ARMOR_PLATE, Vector3(tx, 0.45, 1.10))
		k.box(Vector3(1.10, 0.24, 1.45), EnemyMeshes.TRIM_RED, Vector3(tx, 0.78, 1.10))
		k.tube(Vector3(tx, 0.45, 1.85), Vector3(tx, 0.45, 2.38), 0.38, 8, EnemyMeshes.STEEL)
		k.glow = true
		k.box(Vector3(0.66, 0.56, 0.18), EnemyMeshes.VENT_GLOW, Vector3(tx, 0.45, 2.40))
		k.box(Vector3(0.62, 0.14, 0.95), EnemyMeshes.VENT_GLOW, Vector3(tx, -0.05, 1.10))
		k.glow = false


func _build_visuals() -> void:
	_body_pivot = Node3D.new()
	_body_pivot.name = "BodyPivot"
	add_child(_body_pivot)
	_hull_mi = _make_part_instance("gunship_hull", placeholder_mesh)
	_body_pivot.add_child(_hull_mi)
	_register_comp_mesh("hull", _hull_mi)
	_pods_mi = _make_part_instance("gunship_pods", placeholder_mesh)
	_body_pivot.add_child(_pods_mi)
	_register_comp_mesh("pods", _pods_mi)
	_thrusters_mi = _make_part_instance("gunship_thrusters", placeholder_mesh)
	_body_pivot.add_child(_thrusters_mi)
	_register_comp_mesh("thrusters", _thrusters_mi)


func telegraph_orb_radius(_weapon_id: String) -> float:
	return 1.05


func muzzle_world(_weapon_id: String = "") -> Vector3:
	var local_m := MUZZLE_L if (_shot_index % 2 == 0) else MUZZLE_R
	if _body_pivot != null and _body_pivot.is_inside_tree():
		return _body_pivot.global_transform * local_m
	if is_inside_tree():
		return global_transform * local_m
	return position + local_m


func puppet_aim() -> Vector2:
	return Vector2(_aim_yaw, _aim_pitch)


func set_puppet_aim(a: Vector2) -> void:
	_aim_yaw = a.x
	_aim_pitch = a.y


# --- EnemyBase state-machine hooks: cover-skim approach, swoop-strafe salvo, break-off & disarmed evasion ---------

func _air_timers(dt: float) -> void:
	_tick_cooldown(dt)
	if _breakoff_t > 0.0:
		_breakoff_t = maxf(_breakoff_t - dt, 0.0)
	_tick_relay(dt)


func _air_knock_damp() -> float:
	return 12.0


func _ai_idle_pose(dt: float) -> void:
	_aim_pitch = move_toward(_aim_pitch, 0.0, dt * 3.0)
	_bank_roll = move_toward(_bank_roll, 0.0, dt * 3.0)


func _on_ai_disabled(reason: String) -> void:
	_cancel_telegraph(reason)
	_release_slot()


func _aims_at_seen_part() -> bool:
	return false   # the hull's aim centre (rockets: splash)


func _ai_search(dt: float, lkp: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_step_air_search(dt, lkp, space)


func _ai_wander(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	_step_air_patrol(dt, space)   # no idle glance: it patrols facing its flight


func _ai_telegraph(dt: float, target: CombatTarget, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	# Continue a shallow attack strafe while locking rockets!
	_step_attack_strafe(dt, target_pos, 0.65, space)
	super._ai_telegraph(dt, target, target_pos, space)


func _ai_fire(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_step_attack_strafe(dt, target_pos, 0.55, space)
	var prev_left := _burst_left
	_step_firing(dt)
	if prev_left > _burst_left:
		_salvo_rounds_fired += 1
	if _burst_left <= 0 and ai_state == STATE_COOLDOWN:
		# Break off laterally & climb on every completed rocket salvo!
		_flank_sign = -_flank_sign
		_breakoff_t = maxf(_cooldown, 2.2)
		_breakoff_count += 1


func _ai_engage(dt: float, target: CombatTarget, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	# Disarmed (wing pods shot off): evade & orbit high without firing.
	if _primary_disabled:
		ai_state = STATE_FLANK
		_step_breakoff(dt, target_pos, space, true)
		return

	# Post-salvo break-off climb during cooldown.
	if _breakoff_t > 0.0 and ai_mode == "live":
		ai_state = STATE_COOLDOWN
		_step_breakoff(dt, target_pos, space, false)
		return

	var pos := _world_pos()
	var dist := pos.distance_to(target_pos)
	# Contact memory (EnemyFlier, when contact_memory > 0): a short sight dropout (a building edge cutting the line) keeps
	# the attack strafe round the last known position instead of switching to the cover-skim approach and back.
	if not (_has_los or _contact_held()) or dist > CLOSE_ENGAGE_R:
		# Low cover-skim approach (9.5-11.5 m, 17 m/s) flanking tall blocks via find_cover_path!
		ai_state = STATE_FLANK
		_step_cover_skim(dt, target_pos, space)
	else:
		# Close-range attack pass (24-68 m, 8.5-11 m alt, banking strafe).
		ai_state = STATE_ENGAGE
		_step_attack_strafe(dt, target_pos, 1.0, space)

	var aim_err := _track_gunship_aim(target_pos, dt)
	var w_id := _choose_weapon(target_pos) if dist <= CLOSE_ENGAGE_R else ""
	if w_id != "" and _cooldown <= 0.0 and aim_err < 0.36:
		if _request_slot(target.target_id):
			_begin_telegraph(w_id, target_pos)


func _step_air_patrol(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if _patrol_points.is_empty():
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	ai_state = STATE_PATROL
	var goal_arc := _patrol_points[_patrol_idx % _patrol_points.size()]
	var goal_w := _arc_to_world_alt(goal_arc, _cruise_alt)
	var diff := goal_w - _world_pos()
	diff -= up * diff.dot(up)
	if diff.length() < 8.5:
		_patrol_idx = (_patrol_idx + 1) % _patrol_points.size()
		goal_w = _arc_to_world_alt(_patrol_points[_patrol_idx], _cruise_alt)
	_fly_toward(goal_w, _cruise_alt, float(_cfg.get("move_speed", 11.5)) * speed_scale, dt, space)


func _step_air_search(dt: float, lkp: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	ai_state = STATE_FLANK
	if _world_pos().distance_to(lkp) > 18.0:
		_step_cover_skim(dt, lkp, space)
	else:
		_align_to_ring()


func _step_cover_skim(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_cover_path_timer -= dt
	if _cover_path_timer <= 0.0 and squad != null:
		if _hunting and _nav() != null:
			_cover_path_timer = 2.0
			_path_points = _nav().find_arc_path(_world_to_arc2(_world_pos()), _world_to_arc2(target_pos), spawn_deck)
		elif _nav() != null:
			if not squad.has_method("claim_cover_repath") or squad.claim_cover_repath():
				_cover_path_timer = COVER_PATH_INTERVAL
				var cur_arc := _world_to_arc2(_world_pos())
				var goal_arc := _world_to_arc2(target_pos)
				_path_points = _nav().find_cover_path(cur_arc, goal_arc, goal_arc, spawn_deck, CLOSE_ENGAGE_R)
			else:
				_cover_path_timer = 0.05
	var steer_goal := target_pos
	# A flier flies straight at the goal, over the roofs in the way (skim height raised to clear the tallest of them),
	# unless something it cannot clear under the ceiling cap (a tower / pillar) is in the way: then the street path.
	# The street path (the walkers' graph) starts at the crossing nearest to it, often behind it: it took a gunship that
	# had lost sight of a mech on the deck's edge street round a block, 99-124 m out, past its 88 m rockets
	# (test_wave_pursuit, seed 1 deck 1 shaft source).
	var here := _world_to_arc2(_world_pos())
	var skim_alt := _skim_clear_alt(here, _world_to_arc2(target_pos))
	if skim_alt > 0.0:
		_path_points.clear()
		skim_alt = _air_match_target_alt(target_pos, skim_alt, 2.0)
	else:
		skim_alt = _air_match_target_alt(target_pos, ALT_SKIM, 2.0)
	while not _path_points.is_empty():
		var wp := _arc_to_world_alt(_path_points[0], skim_alt)
		var off := wp - _world_pos()
		off -= up * off.dot(up)   # horizontal: a gunship above skim height never got within 8.5 m of a waypoint in 3D
		if off.length() < 8.5:
			_path_points.pop_front()
		else:
			steer_goal = wp
			break
	var spd := float(_cfg.get("flank_speed", 17.0)) * speed_scale * _speed_mult
	_fly_toward(steer_goal, skim_alt, spd, dt, space, target_pos)


## Height to fly arc segment a-b straight: ALT_SKIM when nothing tall is in the way, else 5 m over the tallest roof it
## crosses (footprints grown 3 m); -1 when that would pass CEILING_CAP - 3 (a tower / pillar): take the street path.
func _skim_clear_alt(a: Vector2, b: Vector2) -> float:
	var alt := ALT_SKIM
	if _nav() == null:
		return alt
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(4.0, 4.0)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(4.0, 4.0)
	for item: Dictionary in _nav().deck_occluders(spawn_deck):
		var h := float(item["h"])
		if h < ALT_SKIM - 2.0 or h + 5.0 <= alt:
			continue
		var r: Rect2 = item["rect"]
		if hi.x < r.position.x or lo.x > r.end.x or hi.y < r.position.y or lo.y > r.end.y:
			continue
		if EnemyNav.segment_hits_rect(a, b, r.grow(3.0)):
			if h + 5.0 > CEILING_CAP - 3.0:
				return -1.0
			alt = h + 5.0
	return alt


func _step_attack_strafe(dt: float, target_pos: Vector3, spd_mult: float, space: PhysicsDirectSpaceState3D) -> void:
	var pos := _world_pos()
	var to_t := target_pos - pos
	to_t -= up * to_t.dot(up)
	var dist := to_t.length()
	var fwd := to_t / dist if dist > 0.1 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var side := fwd.cross(up).normalized() * _flank_sign
	var pref := float(_cfg.get("preferred_range", 48.0))
	var min_r := float(_cfg.get("min_range", 24.0))
	var radial_w := 0.0
	if dist < min_r:
		radial_w = -0.70
	elif dist > pref + 8.0:
		radial_w = 0.45
	else:
		radial_w = clampf((dist - pref) / 28.0, -0.35, 0.35)
	var dir := (side * 0.88 + fwd * radial_w).normalized()
	var base_alt := lerpf(ALT_ATTACK_LOW, ALT_ATTACK_HIGH, 0.5 + 0.5 * sin(_hover_t * 1.4))
	var want_alt := _air_match_target_alt(target_pos, base_alt, 2.5)
	var spd := 13.0 * spd_mult * speed_scale * _speed_mult
	_fly_toward(pos + dir * 24.0, want_alt, spd, dt, space, target_pos)


func _step_breakoff(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D, evasive: bool) -> void:
	var pos := _world_pos()
	var away := pos - target_pos
	away -= up * away.dot(up)
	var dist := away.length()
	var radial := away / dist if dist > 0.1 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var tangent := radial.cross(up).normalized() * _flank_sign
	var rad_w := 0.72 if (evasive and dist < 60.0) else 0.45
	# An armed break-off is lateral, inside its rockets' reach: past CLOSE_ENGAGE_R + 8 m it curves back in instead of
	# opening the range further (it used to end 100-125 m out, beyond its 88 m rockets, on every salvo).
	if not evasive and dist > CLOSE_ENGAGE_R + 8.0:
		rad_w = -0.35
	# A disarmed gunship (pods shot off) evades in a ring round its target, not away from it: its old 0.45 outward
	# weight flew it to the far end of the deck, 400 m out and out of sight, where no one could finish it and a sweep
	# never ended (seed 4 deck 0, d0_w1 gunship at 8 % hull). Ring: out under EVADE_RING_MIN, level to EVADE_RING_MAX,
	# back in beyond it.
	if evasive:
		if dist < EVADE_RING_MIN:
			rad_w = 0.72
		elif dist <= EVADE_RING_MAX:
			rad_w = 0.0
		else:
			rad_w = -0.4
	var dir := (tangent * 0.85 + radial * rad_w).normalized()
	var alt := ALT_BREAKOFF + (1.2 if evasive else 0.0)
	var spd := 15.0 * speed_scale * _speed_mult
	_fly_toward(pos + dir * 26.0, alt, spd, dt, space, target_pos if not evasive else Vector3(NAN, NAN, NAN))


# --- EnemyFlier flight hooks (the gunship's tuning of _fly_toward) -------------------------------------------------

func _air_alt_min() -> float:
	return ALT_MIN


func _air_low_floor() -> float:
	return ALT_MIN - 0.5


func _air_descend_rate() -> float:
	return 7.5


func _air_repel_weight() -> float:
	return 2.0


## The drone's rule (nearest edge, soft falloff over EnemyFlier.REPEL_RANGE): the old push from the building's centre with
## a hard 5.2 m margin pointed along the wall at a corner and switched on / off, so the gunship wiggled there.
func _repel_min_h(cur_alt: float) -> float:
	return cur_alt - 2.0


func _air_turn_default() -> float:
	return 2.2


func _air_speed_default() -> float:
	return 17.0


## A goal in the 12 m strip along the deck's wall (a mech on the edge street) is steered for at its nearest point inside
## the keep-in rect: aiming past the rect made the keep-in push back every frame and the gunship stalled on the rect's
## edge, short of its attack range (seed 1 deck 2: 76 m from a mech at x 129, rect edge x 123).
func _air_steer_goal(goal_w: Vector3) -> Vector3:
	var gp: CityPlan = squad.deck_plan(spawn_deck) if (squad != null and squad.has_method("deck_plan")) else null
	if gp != null and ring != null:
		var ga := ring.world_to_arc(goal_w)
		var gx: Rect2 = gp.extent.grow(-12.5)
		var gin := Vector2(clampf(ga.x, gx.position.x, gx.end.x), clampf(ga.y, gx.position.y, gx.end.y))
		if gin.distance_squared_to(Vector2(ga.x, ga.y)) > 0.01:
			goal_w = ring.arc_to_world(gin.x, gin.y, ga.z)
	return goal_w


## Keep inside own deck's district boundary (pushed toward the deck centre) and reverse the strafe direction near walls.
func _air_keep_in(pos: Vector3, cur_arc: Vector2, dir: Vector3, want_alt: float) -> Vector3:
	var d_plan := _air_deck_plan()
	if d_plan != null:
		var ext: Rect2 = d_plan.extent.grow(-12.0)
		if not ext.has_point(cur_arc):
			var cw := _arc_to_world_alt(ext.get_center(), want_alt)
			var inward := cw - pos
			inward -= up * inward.dot(up)
			if inward.length_squared() > 1e-4:
				dir = (dir * 0.30 + inward.normalized() * 0.95).normalized()
				_flank_sign = -_flank_sign
	return dir


## Visual banking into the lateral strafe direction.
func _air_after_move(dir: Vector3, new_fwd: Vector3, dt: float) -> void:
	var right_v := new_fwd.cross(up).normalized()
	var lat := dir.dot(right_v)
	var want_roll := clampf(-lat * 0.42 * move_speed_ratio, -0.45, 0.45)
	_bank_roll = lerpf(_bank_roll, want_roll, clampf(dt * 5.0, 0.0, 1.0))


func _track_gunship_aim(target_pos: Vector3, dt: float) -> float:
	if not is_inside_tree():
		return 0.0
	var to_t := target_pos - global_position
	var flat := to_t - up * to_t.dot(up)
	if flat.length_squared() < 1e-4:
		return 0.0
	var cur_fwd := (-global_basis.z)
	cur_fwd = (cur_fwd - up * cur_fwd.dot(up)).normalized()
	if cur_fwd.length_squared() < 1e-6:
		cur_fwd = flat.normalized()
	var want_fwd := flat.normalized()
	var yaw_err := cur_fwd.signed_angle_to(want_fwd, up)
	var max_slew := float(_cfg.get("slew_rate", 2.8)) * dt
	var step_y := clampf(yaw_err, -max_slew, max_slew)
	var new_fwd := cur_fwd.rotated(up, step_y).normalized()
	global_basis = Basis(new_fwd.cross(up).normalized(), up, -new_fwd)
	_aim_yaw = atan2(new_fwd.x, new_fwd.z)
	var horiz := flat.length()
	var want_pitch := clampf(atan2(to_t.dot(up), maxf(horiz, 1.0)), -0.55, 0.35)
	_aim_pitch = lerpf(_aim_pitch, want_pitch, clampf(dt * 5.5, 0.0, 1.0))
	turret_slew_speed = absf(step_y) / maxf(dt, 1e-4)
	return absf(yaw_err)


func _track_aim(target_pos: Vector3, dt: float) -> float:
	return _track_gunship_aim(target_pos, dt)


## The gunship's arc-to-world direction (an arc-space offset carried through the ring), not the flier's x / tangent basis.
func _arc_dir_to_world(pos: Vector3, arc_dir: Vector2) -> Vector3:
	if ring != null:
		var a := ring.world_to_arc(pos)
		var p2 := ring.arc_to_world(a.x + arc_dir.x, a.y + arc_dir.y, a.z)
		var d := p2 - pos
		d -= up * d.dot(up)
		return d.normalized() if d.length_squared() > 1e-6 else Vector3.ZERO
	return Vector3(arc_dir.x, 0.0, arc_dir.y).normalized()


# --- Component Break, Visual Update & Wreck FX ------------------------------------------------------------

func _on_component_visual_broken(comp_id: String) -> void:
	if comp_id == "pods":
		if _pods_mi != null and is_instance_valid(_pods_mi):
			_pods_mi.visible = false
		if _body_pivot != null and is_instance_valid(_body_pivot):
			wreck.attach_flame(_body_pivot, Vector3(1.75, -0.15, -0.8), Vector3(0.45, 0.85, 0.3),
				2.4, 0.55, 10.0, 5, 0.65, -1.0, "pods_stub")


func _spawn_component_debris(comp_id: String) -> void:
	if comp_id == "pods" and _body_pivot != null and _body_pivot.is_inside_tree():
		_pop_plates(_body_pivot.global_transform * Vector3(-1.9, -0.2, -0.8), 2, 2.0, 6.0, 4.0, 8.5)
		_pop_plates(_body_pivot.global_transform * Vector3(1.9, -0.2, -0.8), 2, 2.0, 6.0, 4.0, 8.5)


func _spawn_death_debris(_cause: String) -> void:
	var at := _world_pos()
	_pop_plates(at, 6, 3.0, 8.0, 5.0, 11.0)


func _on_destroyed_visual() -> void:
	if _pods_mi != null and is_instance_valid(_pods_mi):
		_pods_mi.visible = false
	if _thrusters_mi != null and is_instance_valid(_thrusters_mi):
		_thrusters_mi.visible = false
	if _hull_mi != null and is_instance_valid(_hull_mi):
		_hull_mi.visible = true
		_hull_mi.material_override = EnemyMeshes.charred_material()
	if _body_pivot != null and is_instance_valid(_body_pivot):
		_body_pivot.rotation = Vector3(-0.32, 0.2, 0.45)


func _wreck_flame_specs() -> Array[Dictionary]:
	return [{
		"parent": _body_pivot if _body_pivot != null else self,
		"pos": Vector3(0.0, 0.25, 0.5), "dir": Vector3(0.12, 1.0, 0.10),
		"length": 4.2, "width": 1.05, "speed": 11.5, "count": 6, "root": 0.95, "duration": 8.0, "tag": "gunship_core",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 0.15, 0.4)


func _core_rupture_scale() -> float:
	return 1.15


func _update_visuals(dt: float) -> void:
	_hover_t += dt
	if _body_pivot != null and is_instance_valid(_body_pivot):
		# Shut down (heat_look, stepped in super): the bob dies, nose-down sag and wobble (pivot only).
		var sh := heat_look.flier_offsets(0.8)
		var calm := 1.0 - clampf(heat_look.slump, 0.0, 1.0)
		_body_pivot.position.y = sin(_hover_t * 2.8) * 0.22 * calm + sh.x
		_body_pivot.rotation = Vector3(_aim_pitch - sh.y, 0.0, _bank_roll + sh.z)
	super._update_visuals(dt)
	if _body_pivot != null and is_instance_valid(_body_pivot):   # stagger: the hull rocks away from the hit, settles
		_body_pivot.basis = stagger_rock_basis(0.18 * anim_stagger_amp) * _body_pivot.basis


func debug_info() -> Dictionary:
	var d := super.debug_info()
	d["breakoff_t"] = _breakoff_t
	d["breakoff_count"] = _breakoff_count
	d["primary_disabled"] = _primary_disabled
	d["salvo_rounds"] = _salvo_rounds_fired
	return d


func _on_reset_visual() -> void:
	_aim_yaw = 0.0
	_aim_pitch = 0.0
	_bank_roll = 0.0
	_breakoff_t = 0.0
	_breakoff_count = 0
	_salvo_rounds_fired = 0
	_avoid_t = 0.0
	_air_probe_t = 0.0
	_air_climb_alt = 0.0
	_air_steer_yaw = 0.0
	_air_spd_scale = 1.0
	if _body_pivot != null and is_instance_valid(_body_pivot):
		_body_pivot.position = Vector3.ZERO
		_body_pivot.rotation = Vector3.ZERO
	for mi: MeshInstance3D in [_hull_mi, _pods_mi, _thrusters_mi]:
		if mi != null and is_instance_valid(mi):
			mi.visible = true
			mi.material_override = null
			mi.material_overlay = null
