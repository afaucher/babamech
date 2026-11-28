class_name EnemyTrooper
extends EnemyBase
## Individual Exo-Trooper EnemyBase ("trooper_rifle" | "trooper_at", docs/design/enemy-troop-squads.md):
##   - Standalone EnemyBase with its own position, HP (28-30), single hit sphere, death, charred prone body,
##     target_id, net_id, spawn_deck, wave tag, and EnemySync stream entry.
##   - Coordinated loosely through an optional host-only EnemyTroopSquad controller:
##       * Independent cover-corner claiming (no two troopers stack on the same corner).
##       * Seeded per-trooper jitter (pace, reaction delay, fire cadence, aim error, idle sway, formation offset).
##       * Staggered peek-and-fire single shots (telegraph >= 0.55 s rifle / 0.85 s AT).
##       * Shared fireteam alerts, morale fallback/regroup when losses mount (overridden by deck hunt-out).
##       * Independent jump-pack ascent onto adjacent low roofs (<= 12 m) when rushed or splashed.
##       * Host-only mech stomp crush (3.0 m horizontal, 2.5 m vertical) & staggered dropship air-drop descent.
##   - Visual look: uses EnemyMeshes variant "trooper_<kit>_<n>" when present (variant 0 = squad leader), derived
##     deterministically on every machine from hash(mission_seed, target_id, "look") so zero extra net state is needed.

const TROOPER_HIT_R := 1.15
const STOMP_HORIZ_R := 3.0
const STOMP_VERT_R := 2.5
const STOMP_MIN_SPEED := 1.0
const RUSH_PANIC_DIST := 24.0
const JUMP_DURATION := 1.4
const JUMP_MAX_ROOF_H := 12.0
const JUMP_SEARCH_DIST := 14.0
const AIR_DROP_DURATION := 0.8
const COVER_QUERY_INTERVAL := 1.4
const PERCEPTION_INTERVAL := 0.065    ## ~15 Hz staggered perception raycast budget per trooper
const TROOPER_VARIANTS := 12

# Fireteam membership & role (SPAWN / LOCAL)
var fireteam: EnemyTroopSquad = null  ## host-only tactical fireteam controller
var member_idx := 0                   ## 0 = fireteam leader (cream helmet stripe variant)
var on_roof := false                  ## true when spawned on a roof or after jump-pack ascent

# Per-trooper seeded jitter (deterministic from mission_seed + target_id; never global RNG)
var _pace_mult := 1.0                 ## 0.85..1.18 movement speed variance
var _react_delay := 0.2               ## 0.08..0.42 s reaction & peek delay jitter
var _aim_error_deg := 2.0             ## 1.2..3.6 deg per-trooper aim variance
var _cd_mult := 1.0                   ## 0.85..1.25 fire cooldown variance
var _sway_phase := 0.0                ## cosmetic idle/walk bob phase
var _sway_freq := 2.2                 ## cosmetic idle/walk bob frequency
var _formation_off := Vector2.ZERO    ## loose local offset around squad objective
var _look_seed := 0                   ## cosmetic EnemyMeshes variant seed

# Visual nodes (LOCAL)
var _pivot: Node3D = null
var _body_mi: MeshInstance3D = null
var _jet_stream: LowPolyFlame.Stream = null
var _sway_t := 0.0

# Articulated near rig (docs/design/enemy-anim): EnemyMeshes.trooper_rig_part pieces posed like the civilians' rigid-part
# figures (joint angles from a few blended poses: stand / walk / crouch / peek / air / stagger), feet planted by
# EnemyGait (stride from the real ground speed), legs solved with LegIK.solve_two_bone. Beyond rig_lod_dist from the
# camera (and with no camera, unless force_rig) the whole-body mesh is drawn instead with the old cheap pose.
var _rig: Node3D = null
var _rig_parts: Dictionary = {}       ## piece -> MeshInstance3D
var _rig_on := false
var _joints: Dictionary = {}          ## EnemyMeshes.trooper_joints(variant)
var _gait := EnemyGait.new()
var _crouch := 0.0                    ## 0 standing .. 1 crouched (smoothed)
var _peek_w := 0.0                    ## 0 .. 1 stepped out to peek (smoothed)
var _air_w := 0.0                     ## 0 .. 1 legs tucked (jump pack / drop / thrown)
var _air_hold := 0.0                  ## puppet: s left of the airborne guess (it sees only the motion)
var _pose_pelvis := Vector3.ZERO      ## last posed pelvis (rig frame; tests)
var force_rig := false                ## tests: articulate even with no camera
var rig_lod_dist := 70.0              ## m: articulated within this camera distance
var anim_crouch_depth := 1.0          ## lab: how deep the crouch goes (0 = stand)
var anim_reach_scale := 1.0           ## lab: gait reach scale
var anim_lift_scale := 1.0            ## lab: step lift scale

# Individual tactical state
var _facing_yaw := 0.0                ## streamed via puppet_aim.x (quantized when still -> 2 Hz idle rate)
var _peek_frac := 0.0                 ## 0 = crouched in cover, 1 = peeking/standing (streamed via puppet_aim.y)
var _peeking := false
var _in_cover := false
var _cover_anchor := Vector3.ZERO
var _has_cover_anchor := false
var _cover_query_t := 0.0
var _scatter_cd := 0.0
var _displacing := false
var _displace_goal := Vector3.ZERO
var _displace_t := 0.0
var _retreating := false
var _has_fire_token := false

# Individual jump-pack state
var _jump_active := false
var _jump_t := 0.0
var _jump_start := Vector3.ZERO
var _jump_end := Vector3.ZERO
var _jump_roof_yaw := 0.0
var _jump_count := 0

# Individual air-drop state (supports staggered exit delay from dropship)
var _drop_active := false
var _drop_delay := 0.0
var _drop_t := 0.0
var _drop_start := Vector3.ZERO
var _drop_end := Vector3.ZERO

# Host stomp / telemetry tracking
var _player_prev_pos: Dictionary = {}
var _scatter_count := 0


func _init() -> void:
	super._init()
	enemy_type = "trooper_rifle"


func is_mobile() -> bool:
	return not on_roof and float(_cfg.get("move_speed", 0.0)) > 0.0


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"fireteam": Net.LOCAL, "member_idx": Net.SPAWN, "on_roof": Net.SPAWN,
		"_pace_mult": Net.PRIVATE, "_react_delay": Net.PRIVATE, "_aim_error_deg": Net.PRIVATE,
		"_cd_mult": Net.PRIVATE, "_sway_phase": Net.LOCAL, "_sway_freq": Net.LOCAL,
		"_formation_off": Net.PRIVATE, "_look_seed": Net.LOCAL,
		"_pivot": Net.LOCAL, "_body_mi": Net.LOCAL, "_jet_stream": Net.LOCAL, "_sway_t": Net.LOCAL,
		"_facing_yaw": Net.OWNER, "_peek_frac": Net.OWNER, "_peeking": Net.PRIVATE,
		"_in_cover": Net.PRIVATE, "_cover_anchor": Net.PRIVATE, "_has_cover_anchor": Net.PRIVATE,
		"_cover_query_t": Net.PRIVATE, "_scatter_cd": Net.PRIVATE, "_displacing": Net.PRIVATE,
		"_displace_goal": Net.PRIVATE, "_displace_t": Net.PRIVATE, "_retreating": Net.PRIVATE,
		"_has_fire_token": Net.PRIVATE,
		"_jump_active": Net.OWNER, "_jump_t": Net.PRIVATE, "_jump_start": Net.PRIVATE,
		"_jump_end": Net.PRIVATE, "_jump_roof_yaw": Net.PRIVATE, "_jump_count": Net.PRIVATE,
		"_drop_active": Net.OWNER, "_drop_delay": Net.PRIVATE, "_drop_t": Net.PRIVATE,
		"_drop_start": Net.PRIVATE, "_drop_end": Net.PRIVATE,
		"_player_prev_pos": Net.PRIVATE, "_scatter_count": Net.PRIVATE,
		"_rig": Net.LOCAL, "_rig_parts": Net.LOCAL, "_rig_on": Net.LOCAL, "_joints": Net.LOCAL, "_gait": Net.LOCAL,
		"_crouch": Net.LOCAL, "_peek_w": Net.LOCAL, "_air_w": Net.LOCAL, "_air_hold": Net.LOCAL,
		"_pose_pelvis": Net.LOCAL, "force_rig": Net.LOCAL, "rig_lod_dist": Net.LOCAL,
		"anim_crouch_depth": Net.LOCAL, "anim_reach_scale": Net.LOCAL, "anim_lift_scale": Net.LOCAL,
	})
	return f


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	super.configure(type_id, id, w, sq, r, seed_val, hp_mult)
	_init_jitter(seed_val)


func _init_jitter(seed_val: int) -> void:
	var jrng := RandomNumberGenerator.new()
	jrng.seed = hash([seed_val, target_id, "trooper_jitter_v1"])
	_pace_mult = jrng.randf_range(0.85, 1.18)
	_react_delay = jrng.randf_range(0.08, 0.42)
	_aim_error_deg = jrng.randf_range(1.2, 3.6)
	_cd_mult = jrng.randf_range(0.85, 1.25)
	_perc_t = jrng.randf_range(0.0, PERCEPTION_INTERVAL)
	_cover_query_t = jrng.randf_range(0.05, 0.45)
	var ang := jrng.randf_range(0.0, TAU)
	var rad := jrng.randf_range(3.5, 8.5)
	_formation_off = Vector2(cos(ang) * rad, sin(ang) * rad)
	# Separate cosmetic looks stream (AGENTS.md rule 4: looks never consume gameplay RNG).
	var lrng := RandomNumberGenerator.new()
	lrng.seed = hash([seed_val, target_id, "trooper_look_v1"])
	_sway_phase = lrng.randf_range(0.0, TAU)
	_sway_freq = lrng.randf_range(1.7, 2.9)
	_look_seed = int(lrng.randi())


func attach_fireteam(ft: EnemyTroopSquad, idx: int = 0) -> void:
	if fireteam != null and fireteam != ft:
		fireteam.remove_member(self)
	fireteam = ft
	member_idx = idx
	if fireteam != null:
		fireteam.add_member(self)


func _trooper_kit() -> String:
	return "at" if enemy_type == "trooper_at" else "rifle"


func _mesh_part_id() -> String:
	var kit := _trooper_kit()
	# Variant 0 = fireteam leader (cream helmet stripe); other troopers pick from 1..TROOPER_VARIANTS-1 deterministically.
	var seed_i := 0 if member_idx == 0 else (1 + posmod(_look_seed, maxi(EnemyMeshes.TROOPER_VARIANTS - 1, 1)))
	return EnemyMeshes.trooper_part(kit, seed_i)


func _build_visuals() -> void:
	_pivot = Node3D.new()
	_pivot.name = "TrooperPivot"
	add_child(_pivot)
	heat_look.optic_heat = 1.0   # few troopers carry fins (jump-pack vents only): the visor carries the heat ramp too
	var mi := EnemyMeshes.instance(_mesh_part_id())
	mi.name = "Body"
	_pivot.add_child(mi)
	_body_mi = mi
	_register_comp_mesh("body", mi)
	# The near rig: the same variant in pieces (identical look), hidden until the camera is close.
	var kit := _trooper_kit()
	var n := int(EnemyMeshes.trooper_id(_mesh_part_id())[1])
	_joints = EnemyMeshes.trooper_joints(n)
	_rig = Node3D.new()
	_rig.name = "Rig"
	_rig.visible = false
	_pivot.add_child(_rig)
	for pc: String in EnemyMeshes.TROOPER_PIECES:
		var pm := EnemyMeshes.instance(EnemyMeshes.trooper_rig_part(kit, n, pc))
		pm.name = pc
		_rig.add_child(pm)
		_rig_parts[pc] = pm
		_register_comp_mesh("body", pm)
	_gait.reach = 0.45
	_gait.step_time = 0.34
	_gait.run_step_time = 0.2
	_gait.min_step_time = 0.1
	_gait.lift = 0.22
	_gait.clearance = 0.24
	_gait.settle_error = 0.07
	_gait.settle_time = 0.2


## Hit sphere tracks crouched vs peeking height so peeking troopers expose a taller profile.
func world_spheres() -> Array[Dictionary]:
	if _dead:
		return []
	var xf := global_transform if is_inside_tree() else transform
	var pf := 1.0 if (_jump_active or _drop_active or _displacing or _peeking or _peek_frac > 0.3) else 0.0
	var h_center := lerpf(1.15, 1.72, pf)
	var lean_z := -0.85 * pf if (ai_state in [STATE_TELEGRAPH, STATE_FIRE] or (puppet and _peek_frac > 0.3)) else 0.0
	return [{
		"component": "body",
		"center": xf * Vector3(0.0, h_center, lean_z),
		"radius": TROOPER_HIT_R,
	}]


func muzzle_world(_weapon_id: String = "") -> Vector3:
	var xf := global_transform if is_inside_tree() else transform
	var lean_z := -0.85 if _peeking or ai_state in [STATE_TELEGRAPH, STATE_FIRE] else 0.0
	var off := Vector3(0.42, 1.88, -1.52 + lean_z) if enemy_type == "trooper_at" else Vector3(0.22, 1.42, -1.48 + lean_z)
	return xf * off


func _sensor_yaw() -> float:   # perception: the forward cone follows the helmet, which glances round while idle
	return _facing_yaw


## Quantize yaw slightly when crouched/still so EnemySync drops idle troopers to 2 Hz keep-alive!
func puppet_aim() -> Vector2:
	var q_yaw := snappedf(_facing_yaw, 0.08)
	var pf := 1.0 if (_peeking or _jump_active or _drop_active or ai_state in [STATE_TELEGRAPH, STATE_FIRE]) else 0.0
	return Vector2(q_yaw, pf)


func set_puppet_aim(a: Vector2) -> void:
	_facing_yaw = a.x
	_peek_frac = clampf(a.y, 0.0, 1.0)
	_peeking = _peek_frac > 0.3


# --- Damage, Splash Scatter & Clean Charred Prone Body ----------------------------------------------------

func apply_hit(h: Hit) -> void:
	var was_alive := not _dead
	super.apply_hit(h)
	if was_alive and not _dead and not puppet and Net.is_host():
		var wst: Dictionary = world.stats(h.weapon) if world != null else {}
		var is_explosive := bool(wst.get("explosive", false)) or float(wst.get("splash_radius", 0.0)) > 0.0
		if is_explosive or h.impulse.length_squared() >= 4.0:
			_on_splash_panic(h.point)


func _kill(cause: String) -> void:
	if _dead:
		return
	_release_fire_token()
	_stop_jump_jet()
	_jump_active = false
	_drop_active = false
	var threat_pos := _last_seen_pos if _last_seen_pos != Vector3.ZERO else _world_pos()
	super._kill(cause)
	if fireteam != null:
		fireteam.on_member_killed(self, threat_pos)


func _wreck_flame_specs() -> Array:
	return []   # small infantry bodies don't erupt into towering tank fires


func _core_rupture_scale() -> float:
	return 0.25


func _on_destroyed_visual() -> void:
	_set_rig(false)
	if _pivot != null and is_instance_valid(_pivot):
		_pivot.scale = Vector3.ONE
		var fall_yaw := float(posmod(_look_seed, 360)) * PI / 180.0
		_pivot.rotation = Vector3(PI * 0.48, fall_yaw * 0.25, 0.0)
		_pivot.position = Vector3(0.0, 0.26, 0.0)
	if _body_mi != null and is_instance_valid(_body_mi):
		_body_mi.material_override = EnemyMeshes.charred_material()


func _on_reset_visual() -> void:
	if _pivot != null and is_instance_valid(_pivot):
		_pivot.scale = Vector3.ONE
		_pivot.rotation = Vector3.ZERO
		_pivot.position = Vector3.ZERO
	if _body_mi != null and is_instance_valid(_body_mi):
		_body_mi.material_override = null
	_rig_on = not _rig_on   # base reset showed every mesh: re-apply the LOD choice
	_set_rig(not _rig_on)
	_gait = _new_gait_like(_gait)
	_crouch = 0.0
	_peek_w = 0.0
	_air_w = 0.0
	_stop_jump_jet()


# --- Dropship Air-Drop Entry (Staggered Per-Trooper Descent) ----------------------------------------------

func deploy_from_air(landing_pos: Vector3, deck: int = 0, exit_delay: float = 0.0) -> void:
	spawn_deck = deck
	_drop_start = _world_pos()
	_drop_end = landing_pos
	_drop_delay = maxf(exit_delay, 0.0)
	_drop_t = 0.0
	_drop_active = true
	_in_cover = false
	_has_cover_anchor = false
	_peeking = true
	_peek_frac = 1.0
	ai_state = STATE_FLANK
	if _drop_delay <= 0.0:
		_start_jump_jet()


# --- Fireteam Alert & Morale Callbacks --------------------------------------------------------------------

func receive_fireteam_alert(target: CombatTarget, target_pos: Vector3) -> void:
	if _dead or puppet or ai_mode != "live" or target == null or not is_instance_valid(target):
		return
	_last_target_ref = target
	_last_seen_pos = target_pos
	_aim_point = target_pos
	_on_alert_perception_hint(target)
	if not is_alerted():
		_relayed = true
		_enter_alert(target, "relay")
		_alert_timer = ALERT_DELAY + _react_delay


func on_squadmate_down(_dead_buddy: EnemyBase, threat_pos: Vector3, broken: bool) -> void:
	if _dead or puppet or ai_mode != "live":
		return
	if _last_seen_pos == Vector3.ZERO:
		_last_seen_pos = threat_pos
	if broken and not on_roof and not _hunting:
		_retreating = true
		_displacing = true
		_displace_t = 3.5 + _react_delay
		_release_claimed_cover()
		var pos := _world_pos()
		var away := pos - threat_pos
		away -= up * away.dot(up)
		var dir := away.normalized() if away.length_squared() > 1e-4 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
		var want := pos + dir * (22.0 + _pace_mult * 8.0)
		var corner := _find_independent_cover(want, threat_pos)
		_displace_goal = corner if not is_nan(corner.x) else want
		ai_state = STATE_FLANK
	elif _scatter_cd <= 0.0 and not on_roof and not _hunting:
		# Brief duck/reposition on buddy death so survivors look reactive, not frozen.
		_scatter_cd = 3.0 + _react_delay
		_peeking = false
		_peek_frac = 0.0


# --- Host Tick, Stomp Crush & Individual AI ---------------------------------------------------------------

func _perception_interval() -> float:
	return PERCEPTION_INTERVAL


func _can_lod_throttle() -> bool:
	return not _drop_active and not _jump_active and super._can_lod_throttle()


func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	if _dead:
		super.tick(dt, space)
		return
	if _drop_active:
		_step_air_drop(dt)
		_update_visuals(dt)
		return
	if _jump_active:
		_step_jump_pack(dt)
		_update_visuals(dt)
		return
	# A1: skip timers & stomp scan completely when asleep (deck empty AND not an active defend wave).
	if not puppet and not _is_awake():
		return
	if _scatter_cd > 0.0:
		_scatter_cd = maxf(_scatter_cd - dt, 0.0)
	super.tick(dt, space)
	if not _dead and not puppet and Net.is_host() and _lod_dt == 0.0:
		_check_mech_stomp(dt)


func _check_mech_stomp(dt: float) -> void:
	if world == null or _dead or _jump_active or _drop_active:
		return
	var my_pos := _world_pos()
	if squad != null and squad.has_method("min_crew_dist_sq"):
		var cd2 := float(squad.min_crew_dist_sq(my_pos, spawn_deck))
		if cd2 >= 0.0 and cd2 > 225.0:
			return   # no standing crew mech within 15 m: skip target loop & prev-pos tracking
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or (t is AssetTarget) or not t.is_hittable():
			continue
		if squad != null and squad.has_method("on_deck") and not squad.on_deck(t.global_position, spawn_deck):
			continue
		var mp := t.global_position
		var speed := 0.0
		if t is PlayerTarget and (t as PlayerTarget).mech != null:
			speed = (t as PlayerTarget).mech.velocity.length()
		else:
			if _player_prev_pos.has(t.target_id) and dt > 1e-5:
				speed = mp.distance_to(_player_prev_pos[t.target_id] as Vector3) / dt
			_player_prev_pos[t.target_id] = mp
		if speed < STOMP_MIN_SPEED:
			continue
		var dvec := my_pos - mp
		var v_off := absf(dvec.dot(up))
		var h_off := (dvec - up * dvec.dot(up)).length()
		if h_off <= STOMP_HORIZ_R and v_off <= STOMP_VERT_R:
			if world != null:
				world.spawn_impact(my_pos + up * 0.4, up, 1.8, EnemyMeshes.CHARRED, true)
			_kill("crushed")
			return


# EnemyBase state-machine hooks (docs/design/enemy-ai-structure.md): the trooper's peek pose, fire token and fireteam.

func _ai_idle_pose(_dt: float) -> void:
	_peeking = false
	_peek_frac = 0.0


func _on_ai_disabled(_reason: String) -> void:
	_peeking = false
	_peek_frac = 0.0
	_release_fire_token()


func _on_target_dropped(_dt: float) -> void:
	_peeking = false
	_peek_frac = 0.0


func _on_spotted(target: CombatTarget, target_pos: Vector3) -> void:
	_alert_timer = ALERT_DELAY + _react_delay
	if fireteam != null:
		fireteam.share_alert(self, target, target_pos)


func _ai_telegraph(dt: float, target: CombatTarget, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_peeking = true
	_peek_frac = 1.0
	super._ai_telegraph(dt, target, target_pos, space)


func _ai_fire(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_peeking = true
	_peek_frac = 1.0
	super._ai_fire(dt, target_pos, space)


func _max_aim_pitch() -> float:
	return deg_to_rad(70.0)


func _ai_engage(dt: float, target: CombatTarget, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	# Tactical cover / flank / morale / jump-pack decision.
	_step_trooper_movement(dt, target_pos, space)
	if _jump_active:
		return

	var track_err := _track_aim(target_pos, dt)
	var w_id := str(_cfg.get("primary_weapon", ""))
	var dist := _world_pos().distance_to(target_pos)
	var can_reach := w_id != "" and dist <= float(EnemyCatalog.weapon(w_id).get("range", 150.0)) \
		and _target_elevation(target_pos) <= _max_aim_pitch()
	var fire_los := _has_los or (_in_cover and _has_peek_los(target_pos))
	if can_reach and fire_los and _cooldown <= 0.0 and track_err < 0.35 and not _displacing:
		var now := world.now if world != null else 0.0
		var ft_ok := fireteam == null or fireteam.can_claim_fire(target_id, now)
		if ft_ok and _request_slot(target.target_id):
			if fireteam != null:
				fireteam.claim_fire(target_id, now)
				_has_fire_token = true
			_peeking = true
			_peek_frac = 1.0
			_begin_telegraph(w_id, target_pos)
			return

	# Crouch behind cover between shots.
	_peeking = false
	_peek_frac = 0.0


func _burst_interval(st: Dictionary) -> float:
	return float(st.get("burst_interval", 0.0))


func _burst_cooldown(st: Dictionary) -> float:
	return float(st.get("burst_cooldown", 2.6)) * _cd_mult + _react_delay * 0.6


func _on_burst_done() -> void:
	_release_fire_token()
	_peeking = false
	_peek_frac = 0.0


func _extra_spread(st: Dictionary) -> float:
	return float(st.get("spread", 1.4)) + aim_kick + _aim_error_deg


func _pellets(_st: Dictionary) -> int:
	return 1   # single aimed shots


func _cancel_telegraph(reason: String) -> void:
	super._cancel_telegraph(reason)
	_release_fire_token()


func _release_fire_token() -> void:
	if _has_fire_token and fireteam != null:
		fireteam.release_fire(target_id)
	_has_fire_token = false


func _release_claimed_cover() -> void:
	if _has_cover_anchor and fireteam != null:
		fireteam.release_cover(target_id)
	_has_cover_anchor = false
	_in_cover = false


func rehome_deck(new_deck: int, new_ring: RingFrame = null) -> void:
	_release_claimed_cover()
	on_roof = false
	super.rehome_deck(new_deck, new_ring)


## A telegraph started from cover on the peek line keeps going while that line holds (base _step_telegraph would
## otherwise cancel it on the first tick, since _has_los is false behind cover, and the trooper would never fire).
func _telegraph_has_line(live_pos: Vector3) -> bool:
	return _has_los or (_in_cover and _has_peek_los(live_pos))


func _has_peek_los(target_pos: Vector3) -> bool:
	if _has_los:
		return true
	if _nav() == null:
		return false
	var my_arc := _world_to_arc2(_world_pos())
	var th_arc := _world_to_arc2(target_pos)
	var to_t := (th_arc - my_arc).normalized()
	var side := Vector2(-to_t.y, to_t.x)
	return (not bool(_nav().arc_segment_occluded(my_arc + side * 3.5, th_arc, spawn_deck))) \
		or (not bool(_nav().arc_segment_occluded(my_arc - side * 3.5, th_arc, spawn_deck)))


func _step_trooper_movement(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var pos := _world_pos()
	var dist := pos.distance_to(target_pos)
	if on_roof:
		_in_cover = true
		ai_state = STATE_ENGAGE if _cooldown <= 0.0 else STATE_COOLDOWN
		_align_to_ring()
		return
	var spd := float(_cfg.get("move_speed", 6.8)) * speed_scale * _speed_mult * _pace_mult
	var flank_spd := float(_cfg.get("flank_speed", 8.8)) * speed_scale * _speed_mult * _pace_mult
	# Wave pursuit & last-enemy hunt override cover camping until inside active combat range (<= 65 m with LOS)!
	if _hunting and (not _has_los or (wave != "" and dist > 65.0)):
		_retreating = false
		_displacing = false
		_release_claimed_cover()
		ai_state = STATE_FLANK
		_move_along_plan(target_pos, flank_spd, dt, space)
		return
	# Mech rushing close on the ground: individual scatter or jump-pack onto low adjacent roof!
	# Skip ground-rush panic when an airborne target (e.g. hovering Wasp) is > 8 m overhead.
	if dist < RUSH_PANIC_DIST and (target_pos - pos).dot(up) <= 8.0 and _scatter_cd <= 0.0:
		_trigger_scatter_or_jump(target_pos, space)
		if _jump_active:
			return
	if _displacing:
		_displace_t -= dt
		if _displace_t <= 0.0 or pos.distance_to(_displace_goal) < 3.5:
			_displacing = false
			_retreating = false
			_in_cover = true
			_has_cover_anchor = true
			_cover_anchor = pos
			if fireteam != null:
				fireteam.claim_cover(target_id, pos)
		else:
			ai_state = STATE_FLANK
			_move_along_cover_plan(_displace_goal, flank_spd, EnemyCatalog.engage_range(enemy_type), dt, space)
			return
	# Periodically seek an unclaimed nearby building corner near our loose formation slot.
	_cover_query_t -= dt
	if not _has_cover_anchor and _cover_query_t <= 0.0:
		_cover_query_t = COVER_QUERY_INTERVAL + _react_delay * 0.5
		var search_origin := pos
		if fireteam != null and fireteam.anchor_pos != Vector3.ZERO and pos.distance_to(fireteam.anchor_pos) > 22.0:
			search_origin = pos.lerp(fireteam.anchor_pos, 0.35)
		var corner := _find_independent_cover(search_origin, target_pos)
		if not is_nan(corner.x):
			_cover_anchor = corner
			_has_cover_anchor = true
			if fireteam != null:
				fireteam.claim_cover(target_id, corner)
	if _has_cover_anchor and pos.distance_to(_cover_anchor) > 3.2:
		_in_cover = false
		ai_state = STATE_FLANK
		_steer_with_separation(_cover_anchor, spd, dt, space)
		return
	if dist > EnemyCatalog.engage_range(enemy_type) or (not _has_los and not _has_peek_los(target_pos)):
		_release_claimed_cover()
		ai_state = STATE_FLANK
		var goal := _loose_goal_near(target_pos)
		_move_along_cover_plan(goal, flank_spd, EnemyCatalog.engage_range(enemy_type), dt, space)
		return
	_in_cover = true
	ai_state = STATE_ENGAGE if _cooldown <= 0.0 else STATE_COOLDOWN
	_align_to_ring()


func _loose_goal_near(target_pos: Vector3) -> Vector3:
	if ring != null:
		var a := ring.world_to_arc(target_pos)
		return ring.arc_to_world(a.x + _formation_off.x, a.y + _formation_off.y, CityPlan.CURB_H)
	return target_pos + Vector3(_formation_off.x, 0.0, _formation_off.y)


func _steer_with_separation(goal: Vector3, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	var eff_goal := goal
	if fireteam != null:
		var sep := fireteam.separation_vector(self, up)
		if sep.length_squared() > 1e-4:
			eff_goal = goal + sep * 4.5
	_steer_toward(eff_goal, spd, dt, space)


func _find_independent_cover(origin_pos: Vector3, threat_pos: Vector3) -> Vector3:
	if _nav() == null:
		return Vector3(NAN, NAN, NAN)
	var occs: Array = _nav().deck_occluders(spawn_deck)
	if occs.is_empty():
		return Vector3(NAN, NAN, NAN)
	var d_plan: CityPlan = squad.deck_plan(spawn_deck) if squad.has_method("deck_plan") else (squad.get("plan") as CityPlan)
	var my_arc := _world_to_arc2(origin_pos)
	var th_arc := _world_to_arc2(threat_pos)
	var pref_arc := my_arc + _formation_off * 0.45
	var best_w := Vector3(NAN, NAN, NAN)
	var best_score := INF
	for item: Dictionary in occs:
		var r: Rect2 = item["rect"]
		if r.get_center().distance_to(my_arc) > 68.0:
			continue
		var corners: Array[Vector2] = [
			Vector2(r.position.x - 2.2, r.position.y - 2.2),
			Vector2(r.end.x + 2.2, r.position.y - 2.2),
			Vector2(r.position.x - 2.2, r.end.y + 2.2),
			Vector2(r.end.x + 2.2, r.end.y + 2.2),
		]
		for c_pt in corners:
			if d_plan != null and not EnemySpawner.clear_of_buildings(d_plan, c_pt, 1.8, 0.0):
				continue
			var d_me := my_arc.distance_to(c_pt)
			if d_me > 56.0:
				continue
			if c_pt.distance_to(th_arc) < RUSH_PANIC_DIST:
				continue
			if not _nav().arc_segment_occluded(c_pt, th_arc, spawn_deck):
				continue
			var cw := _arc_to_world_pos(c_pt)
			if fireteam != null and fireteam.is_cover_taken(cw, target_id):
				continue
			var to_th := (th_arc - c_pt).normalized()
			var side := Vector2(-to_th.y, to_th.x)
			var peek_open: bool = (not bool(_nav().arc_segment_occluded(c_pt + side * 3.5, th_arc, spawn_deck))) \
				or (not bool(_nav().arc_segment_occluded(c_pt - side * 3.5, th_arc, spawn_deck)))
			# Slight preference toward each trooper's own seeded offset so squadmates fan out naturally!
			var score := d_me * 0.7 + pref_arc.distance_to(c_pt) * 0.35 + (0.0 if peek_open else 20.0)
			if score < best_score:
				best_score = score
				best_w = cw
	return best_w


func _on_splash_panic(blast_pos: Vector3) -> void:
	if _dead or puppet or not Net.is_host() or on_roof:
		return
	if _scatter_cd <= 0.0:
		_trigger_scatter_or_jump(blast_pos, world.space() if world != null else null)


func _trigger_scatter_or_jump(threat_pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	_scatter_cd = 5.0 + _react_delay * 2.0
	_scatter_count += 1
	if ai_state == STATE_TELEGRAPH:
		_cancel_telegraph("scatter")
		_release_slot()
	_release_claimed_cover()
	# 1. Try independent jump-pack ascent onto an adjacent standable low roof (<= 12 m, kind != "plant").
	var roof := _find_jumpable_roof(_world_pos(), threat_pos)
	if not roof.is_empty():
		_start_jump_pack(roof["pos"] as Vector3, float(roof["yaw"]))
		return
	# 2. Otherwise displace away from threat toward an unclaimed occluded cover corner.
	var pos := _world_pos()
	var away := pos - threat_pos
	away -= up * away.dot(up)
	var dir := away.normalized() if away.length_squared() > 1e-4 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var want := pos + dir * (22.0 + _pace_mult * 6.0)
	var corner := _find_independent_cover(want, threat_pos)
	_displace_goal = corner if not is_nan(corner.x) else want
	_displacing = true
	_displace_t = 3.8 + _react_delay
	ai_state = STATE_FLANK


func _find_jumpable_roof(pos: Vector3, threat_pos: Vector3) -> Dictionary:
	if on_roof or squad == null:
		return {}
	var p: CityPlan = squad.deck_plan(spawn_deck) if squad.has_method("deck_plan") else (squad.get("plan") as CityPlan)
	if p == null or ring == null:
		return {}
	var my_arc := _world_to_arc2(pos)
	var th_arc := _world_to_arc2(threat_pos)
	var best := {}
	var best_d := JUMP_SEARCH_DIST
	for b: Dictionary in p.buildings:
		if bool(b.get("pillar", false)):
			continue
		var bc: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			if not bool(t.get("stand", false)) or str(t.get("kind", "")) == "plant":
				continue
			var y1 := float(t["y1"])
			if y1 < 3.0 or y1 > JUMP_MAX_ROOF_H:
				continue
			var sz: Vector2 = t["size"]
			if minf(sz.x, sz.y) < 5.0:
				continue
			var off: Vector2 = t["off"]
			var tc := bc + off
			var half := sz * 0.5
			var clamped := Vector2(clampf(my_arc.x, tc.x - half.x, tc.x + half.x), clampf(my_arc.y, tc.y - half.y, tc.y + half.y))
			var edge_d := my_arc.distance_to(clamped)
			if edge_d > best_d:
				continue
			var to_th := th_arc - tc
			var land_off := off
			var ryaw := 0.0
			# Small seeded lateral offset along parapet so two jumping troopers never land on top of each other.
			var lat_j := clampf(_formation_off.x * 0.25, -2.5, 2.5)
			if absf(to_th.x) >= absf(to_th.y):
				var sx := 1.0 if to_th.x >= 0.0 else -1.0
				land_off.x += sx * maxf(half.x - 0.9, 0.4)
				land_off.y += clampf(lat_j, -maxf(half.y - 1.2, 0.0), maxf(half.y - 1.2, 0.0))
				ryaw = -PI * 0.5 if sx > 0.0 else PI * 0.5
			else:
				var sy := 1.0 if to_th.y >= 0.0 else -1.0
				land_off.y += sy * maxf(half.y - 0.9, 0.4)
				land_off.x += clampf(lat_j, -maxf(half.x - 1.2, 0.0), maxf(half.x - 1.2, 0.0))
				ryaw = 0.0 if sy > 0.0 else PI
			var land_arc := bc + land_off
			if not EnemySpawner.clear_of_buildings(p, land_arc, 1.4, y1 + CityPlan.CURB_H + 0.2):
				continue
			var bxf := Transform3D(CityGeo.frame_basis(ring, bc.y), ring.arc_to_world(bc.x, bc.y, CityPlan.CURB_H))
			var land_w := bxf * Vector3(land_off.x, y1, land_off.y)
			if fireteam != null and fireteam.is_cover_taken(land_w, target_id, 2.4):
				continue
			best_d = edge_d
			best = {"pos": land_w, "yaw": ryaw}
	return best


func _start_jump_pack(dest_w: Vector3, roof_yaw: float) -> void:
	_jump_start = _world_pos()
	_jump_end = dest_w
	_jump_roof_yaw = roof_yaw
	_jump_t = 0.0
	_jump_active = true
	_jump_count += 1
	_displacing = false
	ai_state = STATE_FLANK
	_start_jump_jet()


func _step_jump_pack(dt: float) -> void:
	_jump_t += dt
	var u := clampf(_jump_t / JUMP_DURATION, 0.0, 1.0)
	var arc_lift := sin(u * PI) * 4.0
	var p := _jump_start.lerp(_jump_end, u) + up * arc_lift
	if ring != null:
		up = ring.up_at(p)
	ground_y = p.dot(up)
	if is_inside_tree():
		global_position = p
	else:
		position = p
	_align_to_ring()
	if _jet_stream != null and is_instance_valid(_jet_stream):
		_jet_stream.advance(dt)
	move_speed_ratio = 1.0
	if u >= 1.0:
		_jump_active = false
		on_roof = true
		_in_cover = true
		if ring != null and is_inside_tree():
			var a := ring.world_to_arc(p)
			var base_b := ring.basis_at_arc(a.y)
			global_basis = Basis(base_b.y, _jump_roof_yaw) * base_b
			_facing_yaw = 0.0
		if fireteam != null:
			fireteam.claim_cover(target_id, p)
		_stop_jump_jet()
		ai_state = STATE_ENGAGE


func _step_air_drop(dt: float) -> void:
	if _drop_delay > 0.0:
		_drop_delay -= dt
		if _drop_delay <= 0.0:
			_start_jump_jet()
		return
	_drop_t += dt
	var u := clampf(_drop_t / AIR_DROP_DURATION, 0.0, 1.0)
	var ease_u := 1.0 - pow(1.0 - u, 2.0)
	var p := _drop_start.lerp(_drop_end, ease_u)
	if ring != null:
		up = ring.up_at(p)
	ground_y = p.dot(up)
	if is_inside_tree():
		global_position = p
	else:
		position = p
	_align_to_ring()
	if _jet_stream != null and is_instance_valid(_jet_stream):
		_jet_stream.advance(dt)
	move_speed_ratio = 1.0 - ease_u
	if u >= 1.0:
		_drop_active = false
		_stop_jump_jet()
		_has_cover_anchor = false
		_cover_query_t = 0.05 + _react_delay * 0.4
		ai_state = STATE_ENGAGE


func _start_jump_jet() -> void:
	_stop_jump_jet()
	if _pivot == null or not is_instance_valid(_pivot):
		return
	var st := LowPolyFlame.Stream.new()
	st.name = "JumpJet"
	st.position = Vector3(0.0, 0.95, 0.42)
	st.length = 1.5
	st.width = 0.30
	st.speed = 9.0
	st.count = 4
	st.spread = 0.14
	st.root = 0.45
	st.jitter_seed = hash([target_id, _jump_count, "jet"])
	st.manual = true
	st.emitting = true
	_pivot.add_child(st)
	st.rebuild()
	_jet_stream = st


func _stop_jump_jet() -> void:
	if _jet_stream != null and is_instance_valid(_jet_stream):
		_jet_stream.emitting = false
		_jet_stream.queue_free()
	_jet_stream = null


# --- Aiming & Cosmetic Per-Trooper Idle/Walk Sway ---------------------------------------------------------

func _track_aim(target_pos: Vector3, dt: float) -> float:
	if not is_inside_tree():
		return 0.0
	var to_t := target_pos - _world_pos()
	to_t -= up * to_t.dot(up)
	if to_t.length_squared() < 1e-4:
		return 0.0
	var local_d := global_basis.inverse() * to_t.normalized()
	var want_yaw := atan2(-local_d.x, -local_d.z)
	var diff := wrapf(want_yaw - _facing_yaw, -PI, PI)
	var rate := float(_cfg.get("slew_rate", 5.0))
	var step_a := clampf(diff, -rate * dt, rate * dt)
	_facing_yaw = wrapf(_facing_yaw + step_a, -PI, PI)
	turret_slew_speed = absf(step_a) / maxf(dt, 1e-4)
	return absf(diff)


func _update_visuals(dt: float) -> void:
	super._update_visuals(dt)
	if _dead or _pivot == null or not is_instance_valid(_pivot):
		return
	_sway_t += dt
	var peek_on := _peeking or ai_state in [STATE_TELEGRAPH, STATE_FIRE] or (puppet and _peek_frac > 0.3)
	var standing := _jump_active or _drop_active or _displacing or _peeking or _peek_frac > 0.3 \
		or move_speed_ratio > 0.1 or _vis_vel.length() > 0.8 or _stagger_anim.active
	# Heat shutdown (heat_look): sinks into a crouch and slumps forward over it (the pivot only: world_spheres unchanged).
	var slump_p := -0.35 * heat_look.slump
	if heat_look.shut and not (_jump_active or _drop_active):
		standing = false
		peek_on = false
	var near := _want_rig()
	if near != _rig_on:
		_set_rig(near)
	if _rig_on:
		_pivot.position = Vector3.ZERO
		_pivot.scale = Vector3.ONE
		_pivot.rotation = Vector3(slump_p, _facing_yaw, 0.0)
		_pose_rig(dt, standing, peek_on)
		return
	# Far LOD: the whole-body mesh with the cheap pose (crouch squash, peek lean, walk bob).
	var target_sy := 1.0 if standing else 0.62
	_pivot.scale.y = lerpf(_pivot.scale.y, target_sy, clampf(dt * 10.0, 0.0, 1.0))
	var bob := sin(_sway_t * (_sway_freq * 3.2 if move_speed_ratio > 0.1 else _sway_freq) + _sway_phase)
	var tilt_z := bob * (0.06 if move_speed_ratio > 0.1 else 0.025)
	var lean_z := -0.75 if peek_on else 0.0
	_pivot.position = Vector3(0.0, maxf(bob, 0.0) * 0.09 if move_speed_ratio > 0.1 else 0.0, lean_z)
	_pivot.rotation = Vector3(slump_p, _facing_yaw, tilt_z)


## Articulated within rig_lod_dist of the camera (10 % hysteresis); with no camera only when force_rig.
func _want_rig() -> bool:
	if force_rig:
		return true
	if not is_inside_tree():
		return false
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var d := rig_lod_dist * (1.1 if _rig_on else 1.0)
	return cam.global_position.distance_squared_to(_world_pos()) < d * d


func _set_rig(on: bool) -> void:
	_rig_on = on
	if _rig != null and is_instance_valid(_rig):
		_rig.visible = on
	if _body_mi != null and is_instance_valid(_body_mi):
		_body_mi.visible = not on
	if on:
		_gait = _new_gait_like(_gait)   # plant afresh under the hips
		if _pivot != null:
			_pivot.scale = Vector3.ONE


func _new_gait_like(g: EnemyGait) -> EnemyGait:
	var n := EnemyGait.new()
	for f: String in ["reach", "step_time", "run_step_time", "min_step_time", "run_speed", "lift", "settle_time",
			"settle_error", "clearance"]:
		n.set(f, g.get(f))
	return n


## Pose the rig for this frame. Joint angles blend a few poses (the civilians' approach: rigid parts, posed by angles,
## stride from the distance walked), with the feet from EnemyGait so a planted foot never slides:
##   stand (hips a hair down, weapon at the ready) / walk-run (hips sink with speed, bob over the steps, lean in) /
##   crouch (hips down and back, knees bent over planted feet, torso forward, head up, weapon braced low) /
##   peek (stepped 0.85 m forward out of cover, where muzzle_world / world_spheres put the shot and the hit sphere) /
##   air (legs tucked under the hips) / stagger (EnemyStaggerAnim: recoil along the push, head knock, stumble steps,
##   weapon droop and swing, then the shake-off and the weapon back on aim).
func _pose_rig(dt: float, standing: bool, peek_on: bool) -> void:
	if _rig == null or not is_instance_valid(_rig) or _joints.is_empty() or not is_inside_tree():
		return
	var j := _joints
	var hip_y := float(j["hip_y"])
	var sa := _stagger_anim
	var amp := anim_stagger_amp
	# Airborne: exact on the host; a puppet guesses from its vertical motion (held through the jump's apex).
	var air := false
	if puppet:
		var vu := absf(_vis_vel.dot(up))
		_air_hold = 0.3 if vu > 1.5 else maxf(_air_hold - dt, 0.0)
		air = _air_hold > 0.0
	else:
		air = _jump_active or _drop_active or not _grounded_now
	var a_cr := 1.0 - exp(-dt * 7.0)
	_crouch += ((0.0 if standing else anim_crouch_depth) - _crouch) * a_cr
	_peek_w += ((1.0 if peek_on and not air else 0.0) - _peek_w) * (1.0 - exp(-dt * 9.0))
	_air_w += ((1.0 if air else 0.0) - _air_w) * (1.0 - exp(-dt * 10.0))
	var c := _crouch
	var run := maxf(float(_cfg.get("flank_speed", 8.8)) * _pace_mult, 1.0)
	var spd := _vis_vel.length()
	var k := clampf(spd / run, 0.0, 1.0) * (1.0 - _air_w)
	var shift := sa.push * (0.3 * sa.stumble * amp)
	# Pelvis (rig frame: feet at the origin, facing -Z).
	var drop := 0.03 + 0.12 * k + 0.05 * k * (1.0 - _gait.lift_amount()) + (hip_y - 0.5) * c + 0.1 * sa.k * amp
	var pelvis := Vector3(shift.x, hip_y - drop, 0.13 * c - 0.85 * _peek_w + shift.z)
	_pose_pelvis = pelvis
	# Feet: homes under the hips (a braced, wider stance in the crouch), following the peek step and the stumble.
	var lx := float(j["leg_x"])
	var feet_z := -0.85 * _peek_w + shift.z
	var home_l := [Vector3(-(lx + 0.05 * c) + shift.x, 0.0, feet_z - 0.14 * c),
		Vector3(lx + 0.05 * c + shift.x, 0.0, feet_z + 0.1 * c)]
	var rxf := _rig.global_transform
	var homes: Array[Vector3] = []
	for i in 2:
		var h: Vector3 = home_l[i]
		if _air_w > 0.5:
			h = Vector3(h.x, hip_y - 0.62, 0.12)
		homes.append(rxf * h)
	var l1 := float(j["thigh"])
	var l2 := float(j["shin"])
	var ankle_y := float(j["ankle_y"])
	var vert := pelvis.y - ankle_y
	_gait.reach = clampf(sqrt(maxf(pow((l1 + l2) * 0.98, 2.0) - vert * vert, 0.0)) * 0.9 * anim_reach_scale, 0.12, 0.7)
	_gait.run_speed = run
	_gait.lift = 0.22 * anim_lift_scale
	_gait.update(dt, homes, up, _vis_vel, rxf.origin, _air_w > 0.5)
	# Torso: lean into speed and into the crouch, recoil along the push, shake it off.
	var lean := 0.1 * k + 0.5 * c
	var axis := Vector3.UP.cross(sa.push)
	var tilt := Basis(axis.normalized(), (0.5 * sa.k + 0.08 * sa.shake) * amp) \
		if sa.active and axis.length_squared() > 1e-6 else Basis.IDENTITY
	var rt := tilt * Basis(Vector3.UP, 0.18 * sa.shake * amp) * Basis(Vector3.RIGHT, -lean)
	var p0 := Vector3(0.0, hip_y, 0.0)
	var torso_xf := Transform3D(rt, pelvis - rt * p0)
	(_rig_parts["torso"] as Node3D).transform = torso_xf
	# Head: kept looking forward over the lean, knocked with the hit, shaken in the recovery.
	var n0 := Vector3(0.0, float(j["neck_y"]), 0.0)
	var rh := rt * Basis(Vector3.RIGHT, lean * 0.75 + 0.1 * c) * Basis(Vector3.UP, 0.5 * sa.shake * amp)
	if sa.active and axis.length_squared() > 1e-6:
		rh = Basis(axis.normalized(), 0.45 * sa.k * amp) * rh
	(_rig_parts["head"] as Node3D).transform = Transform3D(rh, torso_xf * n0 - rh * n0)
	# Arms + weapon: level over the lean (braced a touch low in the crouch), knocked off aim by the stagger.
	var s0 := Vector3(0.0, float(j["shoulder_y"]), 0.0)
	var aim_p := lean * 0.9 - 0.1 * c * (1.0 - _peek_w) - 0.75 * sa.aim_off * amp
	var aim_y := (0.5 * sa.aim_off * sa.side + 0.12 * sa.shake) * amp
	var ra := rt * Basis(Vector3.UP, aim_y) * Basis(Vector3.RIGHT, aim_p)
	(_rig_parts["arms"] as Node3D).transform = Transform3D(ra, torso_xf * s0 - ra * s0)
	if _jet_stream != null and is_instance_valid(_jet_stream):
		_jet_stream.position = torso_xf * Vector3(0.0, 0.98, 0.42)
	# Legs: each solved from its hip to its gait foot, knee forward (splayed a little in the crouch).
	var inv := rxf.affine_inverse()
	for i in 2:
		var sd := -1.0 if i == 0 else 1.0
		var tag := "_l" if i == 0 else "_r"
		var hip := pelvis + Vector3(sd * lx, 0.0, 0.0)
		var foot := inv * _gait.pos[i]
		var ankle_want := Vector3(foot.x, foot.y + ankle_y, foot.z)
		var pole := Vector3(sd * 0.2 * c, 0.0, -1.0)
		var r := LegIK.solve_two_bone(hip, ankle_want, l1, l2, pole)
		var knee: Vector3 = r["joint"]
		var ankle: Vector3 = r["end"]
		var h0 := Vector3(sd * lx, hip_y, 0.0)
		var k0 := Vector3(sd * lx, float(j["knee_y"]), 0.0)
		var a0 := Vector3(sd * lx, ankle_y, 0.0)
		var bt := EnemyGait.limb_basis(knee - hip, pole, Vector3.DOWN, Vector3.FORWARD)
		(_rig_parts["thigh" + tag] as Node3D).transform = Transform3D(bt, hip - bt * h0)
		var bs := EnemyGait.limb_basis(ankle - knee, pole, Vector3.DOWN, Vector3.FORWARD)
		(_rig_parts["shin" + tag] as Node3D).transform = Transform3D(bs, knee - bs * k0)
		(_rig_parts["boot" + tag] as Node3D).transform = Transform3D(Basis.IDENTITY, ankle - a0)


## Rig-frame point of a piece's local point (tests / shots): e.g. the visual muzzle.
func rig_point(piece: String, p: Vector3) -> Vector3:
	if not _rig_parts.has(piece):
		return p
	return (_rig_parts[piece] as Node3D).transform * p


## The visual muzzle in world space (the kit's muzzle point carried by the arms piece).
func visual_muzzle() -> Vector3:
	var m := Vector3(0.42, 1.88, -1.52) if enemy_type == "trooper_at" else Vector3(0.22, 1.4, -1.48)
	if not _rig_on or _rig == null or not _rig.is_inside_tree():
		return global_transform * m if is_inside_tree() else m
	return _rig.global_transform * rig_point("arms", m)
