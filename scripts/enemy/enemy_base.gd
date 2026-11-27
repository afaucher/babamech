class_name EnemyBase
extends CombatTarget
## Shared base class for all enemies (docs/design/enemies.md): host-owned (owner_peer = 0), component HP with weak-point
## multipliers & critical kills, curved-deck RingFrame alignment & rooftop-shove falling, AI state machine with strict
## >= 0.3 s telegraphs, attack-slot arbitration via EnemySquad, diegetic hit flash / status bar, and unified Audio signals.

const STATE_IDLE := "idle"
const EXIT_SPEED_MIN := 5.0        ## m/s: a gate-bay roll-out moves at least this fast (move_speed when higher)
const STATE_PATROL := "patrol"
const STATE_ALERT := "alert"
const STATE_ENGAGE := "engage"
const STATE_FLANK := "flank"
const STATE_TELEGRAPH := "telegraph"
const STATE_FIRE := "fire"
const STATE_COOLDOWN := "cooldown"
const STATE_STAGGERED := "staggered"
const STATE_OVERHEATED := "overheated"
const STATE_DEAD := "dead"

const HIT_FLASH_TIME := 0.07
const WRECK_LINGER := 2.8
const FALL_DAMAGE_SPEED := 12.0
const FALL_DAMAGE_PER_MPS := 5.0
const ALERT_DELAY := 0.35
const RELAY_DELAY := 0.45
const NO_LOS_MORTAR_TIME := 2.5
const VEL_SMOOTH_RATE := 3.5      ## 1/s smoothing for target velocity lead (tracks steady walks, lags sharp dodges)
const MAX_LEAD_TIME := 2.0        ## s max velocity lead lookahead
const COVER_PATH_INTERVAL := 1.2  ## s throttle on 2D cover-weighted A* recompute (frame budget)
const COVER_PEEK_MIN := 3.2       ## s min bounding run before peeking to refresh LKP
const COVER_PEEK_MAX := 4.5       ## s max bounding run before peeking
const COVER_PEEK_DUR := 0.9       ## s max peek exposure before snapping back to bound
const COVER_PEEK_STEP := 4.5      ## m lateral step out toward an open sightline edge
const BASE_PERCEPTION_INTERVAL := 0.08  ## ~12.5 Hz staggered perception for base enemies (60 Hz in telegraph/fire)
const FLOOR_CUT_KEEP := 0.5             ## m a walking unit's centre keeps outside its deck's floor cuts (ramp mouths)
const FLOOR_CUT_FAR := 14.0             ## m beyond which the floor-cut guard sleeps for FLOOR_CUT_FAR_T
const FLOOR_CUT_FAR_T := 0.4            ## s (catalog max 20 m/s -> 8 m, well inside FLOOR_CUT_FAR - FLOOR_CUT_KEEP)
const STEER_RAY_INTERVAL := 0.05       ## 20 Hz obstacle & ground probe cadence while walking (60 Hz when knocked/airborne)
const AI_LOD_DIST_SQ := 150.0 * 150.0   ## > 150 m from every crew mech -> 15 Hz AI LOD (dt * 4, staggered by id)
const TRANSIT_ENTRY_R := 4.0            ## m from the ramp entry at which a transiting wave unit steps onto the ramp
const TRANSIT_EXIT_R := 5.0             ## m from the ramp exit (on the new deck) at which the transit ends
const TRANSIT_RAMP_MAX := 60.0          ## s on a ramp before giving up (stuck): back to normal pathing (seed 1's ~100 m ramps take ~20 s)
## Perception (docs/design/pacing-director.md "Perception"): an un-alerted unit notices a crew mech with a clear line to
## it (torso, else head / legs over low cover) inside its catalog `notice_range` when the mech is in its forward cone
## (`fov_deg`, around its sensor: turret / torso / helmet yaw), or in ANY direction inside NEAR_AWARE_R (x
## MOVING_AWARE_MULT while the mech walks; the whole notice range for LOUD_TIME after it fires: an 8 m mech is loud).
## Noticing takes NOTICE_MIN..NOTICE_MAX s scaled by distance (instant in the cone inside INSTANT_NOTICE_R, as before),
## then the usual ALERT_DELAY and telegraph. Idle units glance round (SCAN_HEADINGS), so a cone sweeps the block.
## Quiet comes from cover and range: no line, no notice. Every number is clamped by `sight_range` (tests / lab blind a unit).
const NEAR_AWARE_R := 60.0              ## m: a mech this close is noticed in any direction (heard / felt), with a clear line
const MOVING_AWARE_MULT := 1.5          ## a walking mech: the any-direction radius x this (90 m)
const MOVING_SPEED := 2.0               ## m/s above which a target counts as walking
const LOUD_TIME := 2.5                  ## s after a player shot during which its shooter is noticed in any direction
const INSTANT_NOTICE_R := 55.0          ## m: in the forward cone and this close, noticed at once (the old behaviour)
const NOTICE_MIN := 0.5                 ## s to notice a mech at 0 m (outside the instant case)
const NOTICE_MAX := 1.5                 ## s to notice a mech at the notice range
const IDLE_PERCEPTION_INTERVAL := 0.2   ## s between un-alerted sight checks (5 Hz, staggered; alerted units keep their rate)
const SCAN_DWELL := 1.6                 ## s an idle unit spends on each glance heading (swivel included; sees while swivelling)
const SCAN_HEADINGS := [0.0, 2.1, -2.1] ## rad from its home facing while standing: with a 150 deg cone, full circle
const SCAN_WALK_HEADINGS := [0.0, 1.0, -1.0]  ## rad from its body facing while walking a patrol
const LOS_LOW_COVER_R := 15.0           ## m: a torso ray blocked this close to either end tries head / legs (low cover)
const LOS_HEAD_UP := 2.6                ## m above a mech's torso centre (head, ~7 m off the floor)
const LOS_LEGS_DOWN := 2.3              ## m below it (legs, ~2 m)

static var los_rays := 0                ## perception sight rays cast (all enemies; tests read it to bound the cost)

signal alerted(enemy: EnemyBase, target_id: String)
signal comms_relayed(enemy: EnemyBase)
signal telegraph_started(enemy: EnemyBase, weapon_id: String, duration: float, muzzle: Vector3)
signal telegraph_cancelled(enemy: EnemyBase, reason: String)
signal weapon_fired(enemy: EnemyBase, weapon_id: String, muzzle: Vector3, aim_point: Vector3)
signal component_damaged(enemy: EnemyBase, component: String, hp_ratio: float, weak_point: bool)
signal component_destroyed(enemy: EnemyBase, component: String, at: Vector3)
signal overheated(enemy: EnemyBase)
signal rebooted(enemy: EnemyBase)
signal destroyed_enemy(enemy: EnemyBase, cause: String, at: Vector3)
signal footstep(enemy: EnemyBase, at: Vector3)

var enemy_type := "turret"
var world: CombatWorld
var squad: Node                  ## EnemySquad (typed loosely to avoid cyclic preload issues)
var ring: RingFrame              ## null on flat arenas (enemy_lab), set on curved city decks
var ai_mode := "live"            ## "live" | "idle" | "telegraph_loop" | "overheat"
var hp_scale := 1.0
var speed_scale := 1.0
var telegraph_scale := 1.0
var sight_range := 140.0
var auto_remove_wreck := false   ## true in Test Drive to clean wrecks after WRECK_LINGER; false in lab/tests
## Co-op (W4, scripts/game/enemy_sync.gd): the enemy's number in the host's manifest (NetEnemyCodec entries name it), the
## deck it spawned on (MissionRules counts alive enemies per deck), and `puppet`: a crew client's copy of a host enemy (no
## AI: CombatWorld never ticks it there; EnemySync shows it from the host's stream through the PUPPET API at the end).
var net_id := 0
var spawn_deck := 0
var wave := ""                     ## wave id from MissionPlan / PacingDirector ("" = deck garrison; Net.SPAWN)
var defend_target_id := ""         ## host-only defend objective id this wave may attack ("" = never target AssetTarget)
var puppet := false

# Owner gameplay state
var ai_state := STATE_IDLE
var _fight_state := ""             ## alerted state a stagger / overheat interrupted ("" = was not fighting; host-private)
var _dead := false
var _dead_time := 0.0
var _primary_disabled := false
var _speed_mult := 1.0
var _shot_index := 0
var _target_id := ""
var _aim_point := Vector3.ZERO
var _locked_aim := Vector3.ZERO
var _active_weapon := ""
var _telegraph_t := 0.0
var _telegraph_dur := 0.0
var _burst_left := 0
var _burst_timer := 0.0
var _cooldown := 0.0
var _alert_timer := 0.0
var _relay_timer := -1.0
var _relayed := false
var _no_los_time := 0.0
var _has_slot := false
var _has_los := false
var _patrol_points: Array[Vector2] = []
var _patrol_idx := 0
var _path_points: Array[Vector2] = []
var _path_timer := 0.0
var _flank_sign := 1.0
var _last_air_fall := 0.0
var _grounded_now := true
var _cover_mode := ""              ## "" | "bound" | "peek" (host-private inside STATE_FLANK)
var _cover_peek_cd := 0.0
var _cover_peek_left := 0.0
var _cover_peek_goal := Vector3.ZERO
var _cover_path_timer := 0.0
var _zigzag_t := 0.0
var _peek_count := 0               ## telemetry / tests: completed or started cover peeks
var revealed := false              ## sticky straggler reveal marker (synced via EnemySync "alert" state "revealed")
## Gate-bay staging (docs/design/pacing-director.md, "Staging in gate bays"; host only): a unit created inside a closed gate
## bay is `staged` (dormant: no AI, no fire, not hittable, not awake) until MissionFlow opens it with roll_out(); then it
## follows `_exit_path` (arc x, arc s, height above the floor), kinematically, after `_exit_wait` s, before its AI resumes.
var staged := false
var _exit_path: Array[Vector3] = []
var _exit_wait := 0.0
var _hunting := false              ## host-only Step 1 hunt-out active
var _hunt_t := 0.0                 ## s hunting without LOS/combat (triggers Step 2 reveal at reveal_hunt_delay_s)
var _revealed_idle_t := 0.0        ## s revealed with 0 damage dealt/taken (triggers Step 3 cull at cull_idle_s)
var _reveal_flare_cd := 0.0        ## local visual flare pulse timer
var _avoid_timer := 0.0            ## committed wall-avoidance direction timer (stops 60 Hz left/right pacing)
var _stuck_anchor := Vector3.ZERO  ## ground unstick window origin
var _stuck_t := 0.0                ## s accumulated in current travel window
var _stuck_travel := 0.0           ## m raw travel attempted in window
var _unstick_goal := Vector3.ZERO  ## nearest clear road-graph node to recover toward
var _unstick_t := 0.0              ## s remaining in active unstick recovery
# Perception / steering / AI LOD caches (A2-A6; host-private / local)
var _perc_t := 0.0
var _perc_valid := false
var _cached_target: CombatTarget = null
var _steer_ray_t := 0.0
var _cached_avoid_dir := Vector3.ZERO
var _cached_block_n := Vector3.ZERO
var _cached_slide_blocked := false
var _ground_probe_t := 0.0
var _ground_h_off := 0.0
var _has_ground_h := false
var _lod_tick := 0
var _lod_phase := 0
var _lod_dt := 0.0
var _cut_far_t := 0.0              ## s the floor-cut guard may skip (unit was > FLOOR_CUT_FAR from every cut)
# Perception: noticing (un-alerted), glance scan, what part of the target is seen (host-private)
var _notice_t := 0.0               ## s of sight accumulated on _notice_tid (alerts at the distance-scaled notice time)
var _notice_tid := ""              ## target being noticed ("" = none)
var _notice_pos := Vector3.ZERO    ## where it was seen (the sensor turns to look at it while noticing)
var _perc_last := -1.0             ## combat clock at the last sight check (-1 = none yet)
var _scan_i := 0                   ## glance heading index (SCAN_HEADINGS)
var _scan_t := 0.0                 ## s left on the current glance
var _vis_off := Vector3.ZERO       ## offset from the target's aim centre to the point seen (head / legs over low cover)
var _los_hit_d := -1.0             ## m from the eye to what blocked the last sight ray (-1 = clear)
var _seen_pos: Dictionary = {}     ## target_id -> [pos, clock]: walking speed of targets (works for crew puppets too)
# Wave cross-deck transit (host-only; set by EnemySquad._step_wave_transit when no crew stands on this unit's deck):
# walk to a ramp's entry on this deck (_transit_entry), then along the ramp to its exit on deck _transit_deck.
var _transit_deck := -1            ## deck the ramp leads to (-1 = no transit)
var _transit_entry := Vector3.ZERO ## world point on this deck's floor in front of the ramp (mouth / foot)
var _transit_exit := Vector3.ZERO  ## world point on _transit_deck's floor past the ramp's far end
var _transit_ramp := false         ## on the ramp: floor-cut guard off, walks straight to _transit_exit
var _transit_t := 0.0              ## s spent on the ramp (gives up after TRANSIT_RAMP_MAX)
var _transit_from := -1            ## deck the transit started on (reverse_transit walks back to it)

# Continuous read-only telemetry for Audio loops
var move_speed_ratio := 0.0
var turret_slew_speed := 0.0
var heat_ratio := 0.0

# Internal / cosmetic references
var _cfg: Dictionary = {}
var _comp_meta: Dictionary = {}  ## comp_id -> catalog dict
var _comp_nodes: Dictionary = {} ## comp_id -> Array[MeshInstance3D]
var _flash_timers: Dictionary = {}
var _telegraph_fx: EnemyTelegraphFx
var _status_bar: EnemyStatusBar
var _rng := RandomNumberGenerator.new()
var _built_visuals := false
var _was_shutdown := false
var _was_staggered := false
var _home_xf := Transform3D.IDENTITY
var _last_target_ref: CombatTarget = null
var _last_seen_pos := Vector3.ZERO
var _tracked_tid := ""
var _prev_target_pos := Vector3.ZERO
var _target_vel := Vector3.ZERO
var _has_prev_pos := false
var _last_hit_dir := Vector3.ZERO
var _wreck_cooled := false             ## wreck fx and motion all finished: the dead unit stops ticking
var wreck := EnemyWreckFx.new(self)     ## flames, core glow, smoke (presentation)
var _ray_query := PhysicsRayQueryParameters3D.new()  ## reused ray query (zero per-frame alloc)
# Stagger animation + the unit's seen motion (presentation only, every machine: docs in EnemyStaggerAnim / EnemyGait)
var _stagger_anim := EnemyStaggerAnim.new()
var _vis_prev := Vector3.ZERO       ## world position at the last visual update
var _vis_vel := Vector3.ZERO        ## world velocity seen by the visuals (host and puppet alike)
var _vis_has_prev := false
var _last_hit_age := 99.0           ## s since apply_hit last set _last_hit_dir on this machine
var anim_stagger_amp := 1.0         ## lab: scales the stagger animation's recoil / rock (presentation only)


func _init() -> void:
	super._init()
	owner_peer = 0
	team = "enemy"
	add_to_group("enemies")


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"enemy_type": Net.SPAWN, "world": Net.LOCAL, "squad": Net.LOCAL, "ring": Net.SPAWN,
		"ai_mode": Net.SPAWN, "hp_scale": Net.SPAWN, "speed_scale": Net.SPAWN, "telegraph_scale": Net.SPAWN,
		"sight_range": Net.SPAWN, "auto_remove_wreck": Net.SPAWN,
		"net_id": Net.SPAWN, "spawn_deck": Net.SPAWN, "wave": Net.SPAWN,
		"defend_target_id": Net.PRIVATE, "puppet": Net.SPAWN,
		"ai_state": Net.OWNER, "_fight_state": Net.PRIVATE, "_dead": Net.OWNER, "_dead_time": Net.PRIVATE,
		"_primary_disabled": Net.OWNER, "_speed_mult": Net.OWNER, "_shot_index": Net.OWNER,
		"_target_id": Net.OWNER, "_aim_point": Net.OWNER, "_locked_aim": Net.OWNER,
		"_active_weapon": Net.OWNER, "_telegraph_t": Net.OWNER, "_telegraph_dur": Net.OWNER,
		"_burst_left": Net.PRIVATE, "_burst_timer": Net.PRIVATE, "_cooldown": Net.PRIVATE,
		"_alert_timer": Net.PRIVATE, "_relay_timer": Net.PRIVATE, "_relayed": Net.PRIVATE,
		"_no_los_time": Net.PRIVATE, "_has_slot": Net.PRIVATE, "_has_los": Net.PRIVATE,
		"_patrol_points": Net.SPAWN, "_patrol_idx": Net.PRIVATE, "_path_points": Net.PRIVATE,
		"_path_timer": Net.PRIVATE, "_flank_sign": Net.SPAWN, "_last_air_fall": Net.PRIVATE,
		"_grounded_now": Net.PRIVATE, "_cover_mode": Net.PRIVATE, "_cover_peek_cd": Net.PRIVATE,
		"_cover_peek_left": Net.PRIVATE, "_cover_peek_goal": Net.PRIVATE, "_cover_path_timer": Net.PRIVATE,
		"_zigzag_t": Net.PRIVATE, "_peek_count": Net.PRIVATE,
		"revealed": Net.OWNER, "staged": Net.PRIVATE, "_exit_path": Net.PRIVATE, "_exit_wait": Net.PRIVATE,
		"_hunting": Net.PRIVATE, "_hunt_t": Net.PRIVATE,
		"_revealed_idle_t": Net.PRIVATE, "_reveal_flare_cd": Net.LOCAL,
		"_avoid_timer": Net.PRIVATE, "_stuck_anchor": Net.PRIVATE, "_stuck_t": Net.PRIVATE,
		"_stuck_travel": Net.PRIVATE, "_unstick_goal": Net.PRIVATE, "_unstick_t": Net.PRIVATE,
		"_perc_t": Net.PRIVATE, "_perc_valid": Net.PRIVATE, "_cached_target": Net.LOCAL,
		"_steer_ray_t": Net.PRIVATE, "_cached_avoid_dir": Net.PRIVATE, "_cached_block_n": Net.PRIVATE,
		"_cached_slide_blocked": Net.PRIVATE, "_ground_probe_t": Net.PRIVATE, "_ground_h_off": Net.PRIVATE,
		"_has_ground_h": Net.PRIVATE, "_lod_tick": Net.PRIVATE, "_lod_phase": Net.PRIVATE, "_lod_dt": Net.PRIVATE,
		"_cut_far_t": Net.PRIVATE, "_notice_t": Net.PRIVATE, "_notice_tid": Net.PRIVATE, "_notice_pos": Net.PRIVATE,
		"_perc_last": Net.PRIVATE, "_scan_i": Net.PRIVATE, "_scan_t": Net.PRIVATE, "_vis_off": Net.PRIVATE,
		"_los_hit_d": Net.PRIVATE, "_seen_pos": Net.PRIVATE, "_transit_deck": Net.PRIVATE, "_transit_entry": Net.PRIVATE,
		"_transit_exit": Net.PRIVATE, "_transit_ramp": Net.PRIVATE, "_transit_t": Net.PRIVATE,
		"_transit_from": Net.PRIVATE, "move_speed_ratio": Net.LOCAL, "turret_slew_speed": Net.LOCAL, "heat_ratio": Net.LOCAL,
		"_cfg": Net.LOCAL, "_comp_meta": Net.LOCAL, "_comp_nodes": Net.LOCAL, "_flash_timers": Net.LOCAL,
		"_telegraph_fx": Net.LOCAL, "_status_bar": Net.LOCAL, "_rng": Net.PRIVATE,
		"_built_visuals": Net.LOCAL, "_was_shutdown": Net.PRIVATE, "_was_staggered": Net.PRIVATE,
		"_home_xf": Net.SPAWN, "_last_target_ref": Net.LOCAL, "_last_seen_pos": Net.OWNER,
		"_tracked_tid": Net.PRIVATE, "_prev_target_pos": Net.PRIVATE, "_target_vel": Net.PRIVATE,
		"_has_prev_pos": Net.PRIVATE, "_last_hit_dir": Net.LOCAL, "_wreck_cooled": Net.LOCAL, "wreck": Net.LOCAL,
		"_ray_query": Net.LOCAL, "_stagger_anim": Net.LOCAL, "_vis_prev": Net.LOCAL, "_vis_vel": Net.LOCAL,
		"_vis_has_prev": Net.LOCAL, "_last_hit_age": Net.LOCAL, "anim_stagger_amp": Net.LOCAL,
	})
	return f


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	enemy_type = type_id
	target_id = id
	name = id
	world = w
	squad = sq
	ring = r
	hp_scale = maxf(hp_mult, 0.1)
	_rng.seed = hash([seed_val, id, type_id])
	_flank_sign = -1.0 if _rng.randi() % 2 == 0 else 1.0
	var id_h := hash(id)
	_lod_phase = posmod(id_h, 4)
	_lod_tick = 0
	_lod_dt = 0.0
	_perc_valid = false
	_cached_target = null
	_perc_t = _perc_stagger_offset()
	_steer_ray_t = (float(posmod(id_h, 3)) / 3.0) * STEER_RAY_INTERVAL
	_ground_probe_t = (float(posmod(id_h + 1, 3)) / 3.0) * STEER_RAY_INTERVAL
	_cached_avoid_dir = Vector3.ZERO
	_cached_block_n = Vector3.ZERO
	_cached_slide_blocked = false
	_has_ground_h = false
	_cfg = EnemyCatalog.unit(type_id)
	mass_class = str(_cfg.get("mass_class", "mech"))
	sight_range = float(_cfg.get("sight_range", 140.0))
	probe_height = float(_cfg.get("probe_height", 2.4))
	body_radius = float(_cfg.get("body_radius", 2.0))
	heat = Heat.new(float(_cfg.get("heat_cap", 60.0)), float(_cfg.get("cooling", 4.0)))
	_apply_catalog_components()


func _apply_catalog_components() -> void:
	_comp_meta.clear()
	hit_shapes.clear()
	armored = bool(_cfg.get("armored", false))     # weapons.md §3.10: flak's armor_mult applies (spawn data)
	var caps := {}
	for c: Dictionary in _cfg.get("components", []):
		var cid := str(c["id"])
		_comp_meta[cid] = c
		caps[cid] = float(c["hp"]) * hp_scale
		for sp: Dictionary in c.get("spheres", []):
			add_hit_sphere(cid, sp["center"] as Vector3, float(sp["radius"]))
	if caps.is_empty():
		caps["body"] = 100.0 * hp_scale
	set_max_hp(caps)


func _ready() -> void:
	if _cfg.is_empty():
		_cfg = EnemyCatalog.unit(enemy_type)
		_apply_catalog_components()
	_home_xf = global_transform
	if ring != null:
		up = ring.up_at(global_position)
		_ground_h_off = ring.height(global_position)
	else:
		_ground_h_off = global_position.y
	_has_ground_h = true
	ground_y = global_position.dot(up)
	if not _built_visuals:
		_build_visuals()
		_built_visuals = true
	_telegraph_fx = EnemyTelegraphFx.new()
	add_child(_telegraph_fx)
	_status_bar = EnemyStatusBar.new()
	_status_bar.position = Vector3(0.0, float(_cfg.get("bar_height", 6.2)), 0.0)
	add_child(_status_bar)


## Override in subclasses to build articulated MeshKit nodes and call _register_comp_mesh(comp_id, mi).
func _build_visuals() -> void:
	var mi := EnemyMeshes.instance("turret_base")
	add_child(mi)
	_register_comp_mesh(core_component(), mi)


func _register_comp_mesh(comp_id: String, mi: MeshInstance3D) -> void:
	if not _comp_nodes.has(comp_id):
		_comp_nodes[comp_id] = []
	(_comp_nodes[comp_id] as Array).append(mi)


func core_component() -> String:
	return str(_cfg.get("core", hp.keys()[0] if not hp.is_empty() else "body"))


func destroyed() -> bool:
	return _dead


func is_hittable() -> bool:
	return not _dead and not staged


## Gate-bay roll-out (host): wake a staged unit and walk / fly it out along `path` (arc x, arc s, height) after `wait` s;
## its AI resumes after the last point (hunting what begin_hunt_pursuit gave it).
func roll_out(path: Array[Vector3], wait: float = 0.0) -> void:
	staged = false
	_exit_path = path.duplicate()
	_exit_wait = maxf(wait, 0.0)


## One step of the roll-out (true while it runs: the AI waits). Kinematic: the path is clear by construction (the bay's
## formation lanes through the door opening), so no steering or physics.
func _step_exit(dt: float) -> bool:
	if _exit_path.is_empty():
		return false
	move_speed_ratio = 0.0
	if _exit_wait > 0.0:
		_exit_wait -= dt
		return true
	var pos := _world_pos()
	var cur := _world_to_arc2(pos)
	var h := ring.height(pos) if ring != null else pos.y
	var at := Vector3(cur.x, cur.y, h)
	var goal: Vector3 = _exit_path[0]
	var spd := maxf(float(_cfg.get("move_speed", 0.0)) * speed_scale, EXIT_SPEED_MIN)
	var to := goal - at
	var d := to.length()
	var nxt := goal
	if d <= spd * dt:
		_exit_path.pop_front()
	else:
		nxt = at + to / d * spd * dt
	var w := ring.arc_to_world(nxt.x, nxt.y, nxt.z) if ring != null else Vector3(nxt.x, nxt.z, nxt.y)
	if ring != null:
		up = ring.up_at(w)
	var f := w - pos
	f -= up * f.dot(up)
	if not is_inside_tree():
		position = w
	elif f.length_squared() > 1e-6:
		f = f.normalized()
		global_transform = Transform3D(Basis(f.cross(up).normalized(), up, -f), w)
	else:
		global_position = w
	move_speed_ratio = 1.0
	return true


func core_hp_ratio() -> float:
	var c := core_component()
	var cap := maxf(float(max_hp.get(c, 1.0)), 0.001)
	return clampf(float(hp.get(c, 0.0)) / cap, 0.0, 1.0)


## A staggered / overheated unit that was fighting is still alerted (its fight is held in _fight_state).
func is_alerted() -> bool:
	if ai_state == STATE_STAGGERED or ai_state == STATE_OVERHEATED:
		return _fight_state != ""
	return ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_TELEGRAPH, STATE_FIRE, STATE_COOLDOWN]


## Stagger / overheat (every _step_ai copy calls this instead of writing ai_state): the AI is out for a moment but
## remembers the fight it was in, so hits during it don't re-alert it and it resumes the fight afterwards.
func _hold_disabled(state: String) -> void:
	if ai_state != STATE_STAGGERED and ai_state != STATE_OVERHEATED:
		_fight_state = ai_state if is_alerted() else ""
	ai_state = state


## First thing after the stagger / overheat checks: a unit coming out of one resumes the fight it held (ALERT keeps its
## remaining reaction delay; a telegraph or burst the disable cancelled resumes as ENGAGE), or idles if it held none.
func _resume_from_disabled() -> void:
	if ai_state != STATE_STAGGERED and ai_state != STATE_OVERHEATED:
		return
	var s := _fight_state
	_fight_state = ""
	if s == "":
		ai_state = STATE_IDLE
	elif s in [STATE_ALERT, STATE_FLANK, STATE_COOLDOWN, STATE_ENGAGE]:
		ai_state = s
	else:
		ai_state = STATE_ENGAGE


## Enter STATE_ALERT, or, while staggered / overheated, hold it to resume when the unit recovers.
func _set_alert_state() -> void:
	if ai_state == STATE_STAGGERED or ai_state == STATE_OVERHEATED:
		_fight_state = STATE_ALERT
	else:
		ai_state = STATE_ALERT


func is_mobile() -> bool:
	return float(_cfg.get("move_speed", 0.0)) > 0.0


## Mark or clear sticky straggler reveal (host emits reliable EnemySync "alert" state "revealed" -> clients mirror it).
func set_revealed(on: bool = true) -> void:
	if not on:
		revealed = false
		_revealed_idle_t = 0.0
		if _telegraph_fx != null:
			_telegraph_fx.hide_reveal_flare()
		return
	if revealed or _dead:
		return
	revealed = true
	_revealed_idle_t = 0.0
	_reveal_flare_cd = 0.0
	if not puppet and Net.is_host():
		_emit_squad("alerted", {"id": target_id, "state": "revealed", "pos": _world_pos()})


## Host Step 1 hunt-out entry: push a mobile enemy out of patrol/cover toward the nearest crew mech on its deck.
func begin_hunt_pursuit(target: CombatTarget, target_pos: Vector3) -> void:
	if _dead or puppet or ai_mode != "live" or target == null or not is_instance_valid(target):
		return
	_hunting = true
	_relayed = true
	_target_id = target.target_id
	_last_target_ref = target
	_last_seen_pos = target_pos
	_aim_point = target_pos
	_cover_mode = ""
	_on_alert_perception_hint(target)
	if not is_alerted():
		ai_state = STATE_FLANK


func note_combat_activity(was_damage: bool = false) -> void:
	_hunt_t = 0.0
	if was_damage:
		_revealed_idle_t = 0.0


## Re-home this enemy onto `new_deck` after falling through a shaft/ramp or crossing between decks.
## Updates spawn_deck, ring frame, clears stale old-deck nav/targeting, and syncs to clients via EnemySync "alert".
func rehome_deck(new_deck: int, new_ring: RingFrame = null) -> void:
	if new_deck < 0 or new_deck == spawn_deck:
		return
	spawn_deck = new_deck
	if new_ring != null:
		ring = new_ring
	var pos := _world_pos()
	if ring != null:
		up = ring.up_at(pos)
		ground_y = (pos - up * ring.height(pos)).dot(up)
		_ground_h_off = ring.height(pos)
	else:
		_ground_h_off = pos.y
	_has_ground_h = true
	_ground_probe_t = 0.0
	_steer_ray_t = 0.0
	_cut_far_t = 0.0
	_cached_avoid_dir = Vector3.ZERO
	_cached_block_n = Vector3.ZERO
	_cached_slide_blocked = false
	_path_points.clear()
	_path_timer = 0.0
	_cover_path_timer = 0.0
	_cover_mode = ""
	_unstick_t = 0.0
	_stuck_t = 0.0
	_has_los = false
	_perc_valid = false
	_perc_t = 0.0
	_notice_tid = ""
	_notice_t = 0.0
	_cached_target = null
	_last_target_ref = null
	_target_id = ""
	_release_slot()
	if not _transit_ramp or new_deck != _transit_deck:
		clear_transit()   # arriving where the ramp leads keeps walking off it (_step_transit); anything else: drop it
	if not puppet and Net.is_host():
		_emit_squad("alerted", {"id": target_id, "state": "deck:%d" % new_deck, "pos": pos})


## Host (EnemySquad._step_wave_transit): a wave unit with no crew on its deck heads for the ramp toward the crew's deck.
## `entry` is on this deck's floor in front of the ramp, `exit` on deck `to_deck`'s floor past the ramp's far end.
func set_transit(to_deck: int, entry: Vector3, exit: Vector3) -> void:
	if _transit_ramp:
		return   # already walking a ramp: finish it first
	if to_deck != _transit_deck or entry.distance_squared_to(_transit_entry) > 1.0:
		_path_points.clear()
		_path_timer = 0.0
	_transit_deck = to_deck
	_transit_from = spawn_deck
	_transit_entry = entry
	_transit_exit = exit


## Host (EnemySquad._step_wave_transit): the crew came back to the deck this unit is leaving while it walks the ramp:
## turn round and walk the ramp back to its entry on that deck (otherwise it walks the whole ramp away from the crew and
## back: seed 1 deck 1, ~70 s of a sweep after the bot respawned on deck 0 and returned). False when not on a ramp.
func reverse_transit() -> bool:
	if not _transit_ramp or _transit_from < 0:
		return false
	var back_to := _transit_from
	_transit_from = _transit_deck
	_transit_deck = back_to
	var e := _transit_entry
	_transit_entry = _transit_exit
	_transit_exit = e
	_transit_t = 0.0
	_path_points.clear()
	return true


func transit_from_deck() -> int:
	return _transit_from if _transit_deck >= 0 else -1


func transit_to_deck() -> int:
	return _transit_deck


func clear_transit() -> void:
	_transit_from = -1
	_transit_deck = -1
	_transit_ramp = false
	_transit_t = 0.0


func is_on_transit_ramp() -> bool:
	return _transit_ramp


## Cross-deck walk for a wave unit (no target on its deck): path to the ramp entry, then straight along the ramp to its
## exit on the next deck (the floor-cut guard is off on the ramp; EnemySquad re-homes the unit as it changes deck).
## Returns false when there is no transit to do (the caller patrols instead).
func _step_transit(dt: float, space: PhysicsDirectSpaceState3D) -> bool:
	if _transit_deck < 0 or not is_mobile():
		return false
	var spd := float(_cfg.get("flank_speed", _cfg.get("move_speed", 0.0))) * speed_scale * _speed_mult
	var pos := _world_pos()
	if not _transit_ramp:
		var to_e := _transit_entry - pos
		to_e -= up * to_e.dot(up)
		if to_e.length() > TRANSIT_ENTRY_R:
			ai_state = STATE_PATROL
			_move_along_plan(_transit_entry, spd, dt, space)
			return true
		_transit_ramp = true
		_transit_t = 0.0
		_path_points.clear()
	_transit_t += dt
	var to_x := _transit_exit - pos
	to_x -= up * to_x.dot(up)
	if (spawn_deck == _transit_deck and to_x.length() <= TRANSIT_EXIT_R) or _transit_t > TRANSIT_RAMP_MAX:
		clear_transit()
		_path_points.clear()
		_path_timer = 0.0
		return false
	ai_state = STATE_PATROL
	_steer_toward(_transit_exit, spd, dt, space)
	return true


func eye_world() -> Vector3:
	var h := float(_cfg.get("eye_height", 4.2))
	return global_transform * Vector3(0.0, h, 0.0) if is_inside_tree() else position + up * h


## Override in subclasses for exact articulated muzzle world position.
func muzzle_world(_weapon_id: String = "") -> Vector3:
	return eye_world() + (-global_basis.z * 2.0 if is_inside_tree() else Vector3(0, 0, -2.0))


func telegraph_orb_radius(weapon_id: String) -> float:
	match weapon_id:
		"enemy_siege_shell": return 1.35
		"enemy_beacon": return 1.20
		"enemy_rockets": return 1.15
		"enemy_mortar": return 0.95
		"enemy_lance": return 0.95
		"enemy_scatter": return 0.88
		"enemy_bolter": return 0.85
		_: return 0.62


# --- Damage, Weak Points, Heat & Destruction ---------------------------------------------------------------

func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty() or _dead:
		return
	var core := core_component()
	var c := component if (component != "" and hp.has(component)) else core
	var meta: Dictionary = _comp_meta.get(c, {})
	var mult := float(meta.get("mult", 1.0))
	var weak := bool(meta.get("weak_point", false))
	var eff := amount * mult
	var before := float(hp[c])
	if before <= 0.0 and c != core:
		var over := float(meta.get("overflow_to_core", 0.5))
		if over > 0.0:
			_damage_core_directly(eff * over, src)
		return
	hp[c] = maxf(before - eff, 0.0)
	_trigger_hit_flash(c)
	note_combat_activity(true)
	if squad != null and squad.has_method("note_deck_activity"):
		squad.note_deck_activity(spawn_deck)
	# `damaged` reports the HP actually removed (CombatTarget's contract): no overkill, nothing when nothing was removed.
	var dealt := before - float(hp[c])
	if dealt > 0.0:
		damaged.emit(dealt, c, src)
	var ratio := float(hp[c]) / maxf(float(max_hp.get(c, 1.0)), 0.001)
	component_damaged.emit(self, c, ratio, weak)
	_emit_squad("component_damaged", {"id": target_id, "component": c, "hp_ratio": ratio, "weak_point": weak, "pos": _world_pos()})
	_on_damaged_alert(src)
	if before > 0.0 and float(hp[c]) <= 0.0:
		_on_component_broken(c, meta)


func _damage_core_directly(amount: float, src: String) -> void:
	var core := core_component()
	if amount <= 0.0 or _dead or not hp.has(core):
		return
	var before := float(hp[core])
	hp[core] = maxf(before - amount, 0.0)
	_trigger_hit_flash(core)
	var dealt := before - float(hp[core])   # what the core actually lost (no overkill)
	if dealt > 0.0:
		damaged.emit(dealt, core, src)
	var ratio := float(hp[core]) / maxf(float(max_hp.get(core, 1.0)), 0.001)
	component_damaged.emit(self, core, ratio, false)
	_emit_squad("component_damaged", {"id": target_id, "component": core, "hp_ratio": ratio, "weak_point": false, "pos": _world_pos()})
	if before > 0.0 and float(hp[core]) <= 0.0:
		_kill("core")


func apply_heat(amount: float, _src: String) -> void:
	if amount <= 0.0 or _dead:
		return
	heat.add(amount)


func apply_hit(h: Hit) -> void:
	if _dead:
		return
	if h.impulse.length_squared() > 1e-6:
		_last_hit_dir = h.impulse.normalized()
		_last_hit_age = 0.0
	elif h.normal.length_squared() > 1e-6:
		_last_hit_dir = (-h.normal).normalized()
		_last_hit_age = 0.0
	var meta: Dictionary = _comp_meta.get(h.component, {})
	var heat_mult := float(meta.get("heat_mult", 1.0))
	apply_damage(h.damage, h.component, h.shooter)
	if not _dead and h.impulse != Vector3.ZERO:
		apply_impulse(h.impulse, h.shooter)
	if not _dead and h.heat > 0.0:
		apply_heat(h.heat * heat_mult, h.shooter)


func _on_component_broken(c: String, meta: Dictionary) -> void:
	var pos := _world_pos()
	component_destroyed.emit(self, c, pos)
	_emit_squad("component_destroyed", {"id": target_id, "component": c, "pos": pos})
	if c == core_component():
		_kill("core")
		return
	if bool(meta.get("critical_kill", false)):
		var cause := str(meta.get("kill_cause", "weak_point"))
		_kill(cause)
		return
	# Non-fatal component break: apply mechanical penalty, pop debris, attach socket flame + local burst.
	if float(meta.get("cripple_speed", 0.0)) > 0.0:
		_speed_mult = minf(_speed_mult, float(meta["cripple_speed"]))
	if float(meta.get("cripple_stagger", 0.0)) > 0.0:
		knock.stagger_left = maxf(knock.stagger_left, float(meta["cripple_stagger"]))
		_cancel_telegraph("stagger")
	if bool(meta.get("disable_primary", false)):
		_primary_disabled = true
		_cancel_telegraph("destroyed")
	_spawn_component_debris(c)
	_on_component_visual_broken(c)
	if world != null:
		world.spawn_impact(pos + up * probe_height, up, 2.4, EnemyMeshes.CHARRED, true)
	var shock := float(meta.get("shock_to_core", 0.0))
	if shock > 0.0 and not puppet:   # a puppet's core HP comes from the host's stream
		_damage_core_directly(shock, "shock")


func _on_component_visual_broken(_comp_id: String) -> void:
	pass


func _kill(cause: String) -> void:
	if _dead:
		return
	_dead = true
	_dead_time = 0.0
	_wreck_cooled = false
	revealed = false
	_hunting = false
	_hunt_t = 0.0
	_revealed_idle_t = 0.0
	_perc_valid = false
	_cached_target = null
	_lod_dt = 0.0
	_cancel_telegraph("destroyed")
	ai_state = STATE_DEAD
	_release_slot()
	for k: String in hp:
		hp[k] = 0.0
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()
		_telegraph_fx.hide_reveal_flare()
	if _status_bar != null:
		_status_bar.visible = false
	var pos := _world_pos()
	var exp_r := float(_cfg.get("explosion_radius", 4.0))
	var col_h := float(_cfg.get("explosion_column", 0.0))
	if world != null:
		var fx := world.spawn_impact(pos + up * (probe_height * 0.8), up, exp_r, EnemyMeshes.CHARRED, true)
		if fx != null and col_h > 0.0:
			fx.add_column(col_h)
	_spawn_death_debris(cause)
	_on_destroyed_visual()
	wreck.start(_wreck_flame_specs(), _core_rupture_pos(), _core_rupture_scale(), _looks_rng())
	_start_wreck_motion()
	if squad != null and squad.has_method("note_deck_activity"):
		squad.note_deck_activity(spawn_deck)
	if squad != null and squad.has_method("register_wreck"):
		squad.register_wreck(self)
	destroyed_enemy.emit(self, cause, pos)
	_emit_squad("destroyed", {"id": target_id, "cause": cause, "pos": pos, "radius": exp_r})


func _on_destroyed_visual() -> void:
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi):
				mi.visible = false


# --- Persistent Destruction: Pop-Off Debris & Wreck (flames, ruptured core, smoke: EnemyWreckFx) --------------

func _spawn_component_debris(_comp_id: String) -> void:
	pass


func _spawn_death_debris(_cause: String) -> void:
	pass


func _wreck_flame_specs() -> Array[Dictionary]:
	return [{
		"parent": self, "pos": _core_rupture_pos(), "dir": Vector3(0.08, 1.0, 0.05),
		"length": 3.8, "width": 0.9, "speed": 10.5, "count": 6, "root": 0.95, "duration": 7.5, "tag": "core",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, probe_height * 0.85, 0.0)


func _core_rupture_scale() -> float:
	return 1.0


func _debris_field() -> EnemyDebrisField:
	if squad != null and squad.has_method("get_debris_field"):
		return squad.get_debris_field() as EnemyDebrisField
	return null


func _looks_rng() -> RandomNumberGenerator:
	if world != null:
		return world.looks_rng
	return _rng


func _pop_part(part: String, xf: Transform3D, up_min: float, up_max: float, rad_min: float, rad_max: float,
		spin_max: float, charred: bool = false, mesh_scale: Vector3 = Vector3.ONE) -> EnemyDebris:
	var df := _debris_field()
	if df == null:
		return null
	var rng := _looks_rng()
	var up_b := ImpactFx.basis_for_normal(up)
	var ang := rng.randf_range(0.0, TAU)
	var horiz := (up_b.x * cos(ang) + up_b.z * sin(ang)).normalized()
	if _last_hit_dir.length_squared() > 1e-4:
		var flat_hit := _last_hit_dir - up * _last_hit_dir.dot(up)
		if flat_hit.length_squared() > 1e-4:
			horiz = (horiz * 0.55 + flat_hit.normalized() * 0.45).normalized()
	var vel := up * rng.randf_range(up_min, up_max) + horiz * rng.randf_range(rad_min, rad_max)
	var ang_vel := Vector3(rng.randf_range(-spin_max, spin_max), rng.randf_range(-spin_max, spin_max), rng.randf_range(-spin_max, spin_max))
	return df.spawn_chunk(part, xf, vel, ang_vel, charred, mesh_scale, ring)


func _pop_plates(origin_world: Vector3, count: int, up_min: float = 6.0, up_max: float = 11.0,
		rad_min: float = 4.0, rad_max: float = 9.0) -> void:
	var df := _debris_field()
	if df == null:
		return
	var rng := _looks_rng()
	var up_b := ImpactFx.basis_for_normal(up)
	for i in count:
		var part := "debris_plate" if i % 2 == 0 else "debris_chunk"
		var off := (up_b.x * rng.randf_range(-1.1, 1.1) + up_b.z * rng.randf_range(-1.1, 1.1) + up * rng.randf_range(-0.3, 0.7))
		var rot := Basis.from_euler(Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU)))
		var sc := Vector3.ONE * rng.randf_range(0.8, 1.25)
		_pop_part(part, Transform3D(rot, origin_world + off), up_min, up_max, rad_min, rad_max, 6.5, i % 2 == 1, sc)


func _tick_wreck_fx(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	var moving := _step_wreck_motion(dt, space)
	var fx_on := wreck.step(dt, _dead_time, _looks_rng())
	if not moving and not fx_on:
		_wreck_cooled = true


## Hook: the wreck starts moving on its own (EnemyFlier: the aerial crash). Default: it stays where it fell.
func _start_wreck_motion() -> void:
	pass


## Hook: one step of that motion, ahead of the wreck fx; true while still moving (keeps the wreck awake).
func _step_wreck_motion(_dt: float, _space: PhysicsDirectSpaceState3D) -> bool:
	return false


func has_charred_hulk() -> bool:
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi) and mi.visible:
				return true
	return false


func _trigger_hit_flash(comp_id: String) -> void:
	_flash_timers[comp_id] = HIT_FLASH_TIME
	for mi: MeshInstance3D in _comp_nodes.get(comp_id, []):
		if is_instance_valid(mi):
			mi.material_overlay = EnemyMeshes.flash_material()


func _tick_flashes(dt: float) -> void:
	for comp_id: String in _flash_timers.keys():
		var rem := float(_flash_timers[comp_id]) - dt
		if rem <= 0.0:
			_flash_timers.erase(comp_id)
			for mi: MeshInstance3D in _comp_nodes.get(comp_id, []):
				if is_instance_valid(mi):
					mi.material_overlay = null
		else:
			_flash_timers[comp_id] = rem


func _on_damaged_alert(src: String) -> void:
	if _dead or ai_mode == "idle":
		return
	if not is_alerted() and world != null:
		for t: CombatTarget in world.targets:
			if is_instance_valid(t) and t.target_id == src and t.team != team:
				_enter_alert(t, "spotted")
				return


# --- Tick (Host-owned simulation + local presentation) ----------------------------------------------------

func _perception_interval() -> float:
	return BASE_PERCEPTION_INTERVAL


func _perc_stagger_offset() -> float:
	var iv := _perception_interval()
	return iv * (0.25 + 0.125 * float(posmod(hash(target_id), 8)))


## Sight-check interval now: alerted (or telegraph_loop) units keep their own fast rate; un-alerted ones look at 5 Hz.
func _perc_interval_now() -> float:
	if is_alerted() or ai_mode != "live":
		return _perception_interval()
	return maxf(IDLE_PERCEPTION_INTERVAL, _perception_interval())


## Yaw of the sensor relative to the body (turret / torso / helmet): the forward cone points this way. Override.
func _sensor_yaw() -> float:
	return 0.0


## World direction of the sensor's forward cone.
func _sensor_fwd() -> Vector3:
	var y := _sensor_yaw()
	var local := Vector3(-sin(y), 0.0, -cos(y))
	if not is_inside_tree():
		return local
	return (global_basis * local).normalized()


## Idle glance (no target, not alerted): look toward what is being noticed, else swivel through SCAN_HEADINGS (from the
## home facing while standing, the body facing while walking) so a forward cone sweeps the block. Diegetic: the turret
## / torso / helmet visibly turns. Uses each class's own _track_aim (its slew rate).
func _idle_scan(dt: float) -> void:
	if ai_mode != "live" or not is_inside_tree() or is_alerted():
		return
	var look := _notice_pos
	if _notice_tid == "":
		var walking := move_speed_ratio > 0.1
		_scan_t -= dt
		if _scan_t <= 0.0:
			_scan_t = SCAN_DWELL
			_scan_i = (_scan_i + 1) % SCAN_HEADINGS.size()
		var hd: float = float((SCAN_WALK_HEADINGS if walking else SCAN_HEADINGS)[_scan_i % SCAN_HEADINGS.size()])
		var ref := (-global_basis.z) if walking else (-_home_xf.basis.z)
		ref -= up * ref.dot(up)
		if ref.length_squared() < 1e-6:
			return
		look = eye_world() + ref.normalized().rotated(up, hd) * 40.0
	_track_aim(look, dt)


func _on_alert_perception_hint(target: CombatTarget) -> void:
	if target != null and is_instance_valid(target) and _cached_target == null:
		_cached_target = target
		_perc_valid = true
	_perc_t = minf(_perc_t, _perc_stagger_offset())


## True when this enemy should tick: its deck has a standing crew mech (deck_awake), or it is a wave unit (waves never
## sleep), or (garrison) it belongs to an active defend whose target relay is live.
func _is_awake() -> bool:
	if staged:
		return false   # waiting in a closed gate bay (dormant until the door is passable)
	if squad == null or not squad.has_method("deck_awake"):
		return true
	if squad.deck_awake(spawn_deck):
		return true
	if wave != "":
		return true   # wave units hunt the crew from spawn until dead: never asleep (cross decks via _step_transit)
	if defend_target_id != "" and squad.has_method("is_defend_asset_live"):
		return bool(squad.is_defend_asset_live(defend_target_id))
	return false


# --- Public API for other systems (squad, spawner, bots, logs): they use these, never the private state ----------

## The id of the target this enemy is fighting ("" = none; owner state).
func current_target_id() -> String:
	return _target_id


## True when this enemy ticks (see _is_awake).
func is_awake() -> bool:
	return _is_awake()


## True while this enemy sees its current target (owner-private: meaningful on the owning machine only).
func has_los() -> bool:
	return _has_los


## The current shot's number (one per shot, kept across a cancelled telegraph).
func shot_index() -> int:
	return _shot_index


## The weapon of the current shot ("" between shots).
func active_weapon() -> String:
	return _active_weapon


## Seconds into the current telegraph.
func telegraph_elapsed() -> float:
	return _telegraph_t


## The catalog entry (EnemyCatalog.unit) this enemy was configured from. Read only.
func unit_cfg() -> Dictionary:
	return _cfg


## World-space aim centre of `t` (zero allocation; the point this enemy aims at).
func target_aim_center(t: CombatTarget) -> Vector3:
	return _target_aim_center(t)


## Kills this enemy outright with `cause` (squad culls: "fell_out", "timeout"). Owner only.
func despawn(cause: String) -> void:
	_kill(cause)


## Spawner: this enemy gets no meshes (headless / skip_meshes); marks its visuals as already built.
func skip_visuals() -> void:
	_built_visuals = true


## Host-only straggler hunt (EnemySquad step 1): true while hunting.
func is_hunting() -> bool:
	return _hunting


## Starts the hunt (no-op when already hunting): the hunt timer starts at 0.
func start_hunt() -> void:
	if not _hunting:
		_hunting = true
		_hunt_t = 0.0


## Step 2: advances the hunt timer by `dt` (reset while the target is in sight). True when it reaches `delay` s.
func step_hunt(dt: float, delay: float) -> bool:
	if _has_los:
		_hunt_t = 0.0
		return false
	_hunt_t += dt
	return _hunt_t >= delay


## Step 3: advances the time spent revealed by `dt`. True when it reaches `cull` s.
func step_revealed_idle(dt: float, cull: float) -> bool:
	_revealed_idle_t += dt
	return _revealed_idle_t >= cull


func _can_lod_throttle() -> bool:
	return not _has_los and ai_state != STATE_TELEGRAPH and ai_state != STATE_FIRE \
		and not knock.moving() and _grounded_now and enemy_type != "dropship" \
		and ai_mode == "live" and not _transit_ramp


func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	if puppet:   # co-op (W4): a client's copy has no AI; it is only shown
		puppet_tick(dt)
		return
	if _dead:
		if not _flash_timers.is_empty():
			_tick_flashes(dt)
		if _wreck_cooled and not auto_remove_wreck:
			return
		_dead_time += dt
		if _telegraph_fx != null:
			_telegraph_fx.tick_only(dt)
		if auto_remove_wreck and _dead_time >= WRECK_LINGER:
			if squad != null and squad.has_method("remove_enemy"):
				squad.remove_enemy(self)
			if world != null:
				world.unregister(self)
			queue_free()
			return
		if not _wreck_cooled:
			_tick_wreck_fx(dt, space)
		return
	if not _is_awake():
		return   # stack (W4): no crew mech on this deck (and not an active defend wave): it sleeps

	# A6 AI LOD: awake enemies > 150 m from every standing crew mech tick at 15 Hz (dt * 4, staggered by id).
	# Never throttled while alerted with LOS, telegraphing/firing, knocked/airborne, or for dropships.
	var eff_dt := dt
	var pos := _world_pos()
	if _can_lod_throttle() and squad != null and squad.has_method("min_crew_dist_sq"):
		var d2 := float(squad.min_crew_dist_sq(pos, spawn_deck))
		# A wave unit awake on a deck with no crew (d2 < 0 in a stack) is far from everyone too: 15 Hz.
		if d2 > AI_LOD_DIST_SQ or (d2 < 0.0 and wave != "" and squad.deck_of.is_valid()):
			_lod_dt += dt
			_lod_tick += 1
			if (_lod_tick & 3) != _lod_phase:
				return
			eff_dt = _lod_dt
			_lod_dt = 0.0
		elif _lod_dt > 0.0:
			eff_dt += _lod_dt
			_lod_dt = 0.0
	elif _lod_dt > 0.0:
		eff_dt += _lod_dt
		_lod_dt = 0.0

	_tick_flashes(eff_dt)
	_perc_t -= eff_dt
	_steer_ray_t -= eff_dt
	_ground_probe_t -= eff_dt

	# Update curved-deck local frame & ground plane BEFORE knockback step so rooftop shoves fall naturally!
	if ring != null:
		up = ring.up_at(pos)
	_update_dynamic_ground(pos, space)

	var prev_vu := knock.velocity.dot(up)
	var was_air := not _grounded_now
	super.tick(eff_dt, space)
	pos = _world_pos()
	if ring != null:
		up = ring.up_at(pos)
	_grounded_now = pos.dot(up) <= ground_y + 0.08
	if not _grounded_now:
		_last_air_fall = maxf(_last_air_fall, -knock.velocity.dot(up))
	elif was_air:
		var impact_v := maxf(_last_air_fall, -prev_vu)
		if impact_v > FALL_DAMAGE_SPEED:
			_damage_core_directly((impact_v - FALL_DAMAGE_SPEED) * FALL_DAMAGE_PER_MPS, "fall")
		_last_air_fall = 0.0

	# Track overheat / reboot transitions for signals.
	heat_ratio = heat.fraction()
	if heat.shutdown and not _was_shutdown:
		_was_shutdown = true
		_cancel_telegraph("overheat")
		_release_slot()
		overheated.emit(self)
		_emit_squad("overheated", {"id": target_id, "pos": pos})
	elif not heat.shutdown and _was_shutdown:
		_was_shutdown = false
		rebooted.emit(self)
		_emit_squad("rebooted", {"id": target_id, "pos": pos})

	# Track stagger transitions.
	var stag := knock.staggered()
	if stag and not _was_staggered:
		_was_staggered = true
		_cancel_telegraph("stagger")
		_release_slot()
	elif not stag and _was_staggered:
		_was_staggered = false

	# Step AI only when alive.
	if not _dead:
		if not _step_exit(eff_dt):
			_step_ai(eff_dt, space)
		if CombatWorld.profiling:
			var tv := Time.get_ticks_usec()
			_update_visuals(eff_dt)
			CombatWorld.prof_add("ai.visuals", Time.get_ticks_usec() - tv)
		else:
			_update_visuals(eff_dt)
		wreck.step_flames(eff_dt)


func _update_dynamic_ground(pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	if mass_factor() <= 0.0:
		return
	var urgent := knock.moving() or not _grounded_now
	# Standing grounded units do not shift vertically; skip redundant downward raycast until moving or knocked.
	if not urgent and move_speed_ratio <= 0.001:
		return
	# A5: throttle walking ground probes to 20 Hz (reuse cached height offset); stay full 60 Hz while knocked/airborne.
	if not urgent and _has_ground_h and _ground_probe_t > 0.0:
		if ring != null:
			ground_y = pos.dot(up) + (_ground_h_off - ring.height(pos))
		else:
			ground_y = _ground_h_off
		return
	_ground_probe_t = 0.0 if urgent else STEER_RAY_INTERVAL
	var g := _probe_ground_point(pos, space)
	if not is_nan(g.x):
		ground_y = g.dot(up)
		_ground_h_off = ring.height(g) if ring != null else g.y
		_has_ground_h = true
	elif ring != null:
		ground_y = (pos - up * ring.height(pos)).dot(up)
		_ground_h_off = 0.0
		_has_ground_h = true


func _probe_ground_point(pos: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	if space != null:
		_ray_query.from = pos + up * 1.8
		_ray_query.to = pos - up * 56.0
		var h := space.intersect_ray(_ray_query)
		if not h.is_empty():
			return h["position"] as Vector3
	if ring != null:
		return pos - up * ring.height(pos)
	return Vector3(pos.x, 0.0, pos.z)


# --- AI State Machine -------------------------------------------------------------------------------------
# ONE state machine for every enemy (docs/design/enemy-ai-structure.md). _step_ai is the template: subclasses override
# the hooks it calls, never _step_ai itself. Per tick:
#   _ai_timers -> ai_mode idle (_ai_idle_pose) | overheat / shutdown / stagger (_hold_disabled, _on_ai_disabled) ->
#   _resume_from_disabled -> _ai_live.
# _ai_live (ground units and the gunship; the drone and the dropship replace it with their own live step):
#   ramp transit -> _ai_perceive -> no target: _ai_no_target (_on_target_dropped, _ai_search | _ai_wander)
#   -> _ai_note_target -> IDLE / PATROL: _enter_alert + _on_spotted | ALERT: delay + _track_aim
#   | TELEGRAPH: _ai_telegraph | FIRE: _ai_fire | else _ai_engage.

func _step_ai(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	_ai_timers(dt)
	if ai_mode == "idle":
		ai_state = STATE_IDLE
		_ai_idle_pose(dt)
		_align_to_ring()
		return
	if ai_mode == "overheat" or heat.shutdown:
		if ai_mode == "overheat" and not heat.shutdown:
			heat.add(heat.cap)
		_hold_disabled(STATE_OVERHEATED)
		_on_ai_disabled("overheat")
		_align_to_ring()
		return
	if knock.staggered():
		_hold_disabled(STATE_STAGGERED)
		_on_ai_disabled("stagger")
		_align_to_ring()
		return
	_resume_from_disabled()
	_ai_live(dt, space)


## Hook: the per-tick timers, before anything else (default: the fire cooldown, then the squad relay).
func _ai_timers(dt: float) -> void:
	_tick_cooldown(dt)
	_tick_relay(dt)


func _tick_cooldown(dt: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(_cooldown - dt, 0.0)


func _tick_relay(dt: float) -> void:
	if _relay_timer >= 0.0:
		_relay_timer -= dt
		if _relay_timer <= 0.0:
			_relay_timer = -1.0
			_fire_comms_relay()


## Hook: ai_mode "idle" (after ai_state = IDLE, before the ring alignment): settle the pose.
func _ai_idle_pose(_dt: float) -> void:
	pass


## Hook: overheated / staggered this tick (after _hold_disabled, before the ring alignment); reason "overheat" | "stagger".
func _on_ai_disabled(_reason: String) -> void:
	pass


## Hook: the live AI step (not idle, not disabled). Ground units and the gunship use this one; the drone and the dropship
## replace it.
func _ai_live(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if _transit_ramp and _step_transit(dt, space):
		return   # walking a ramp to the crew's deck: finish it before anything else
	# Perception: check LOS to opposing targets (or shared squad target board).
	var target := _ai_perceive(space)
	if target == null:
		_ai_no_target(dt, space)
		return
	var target_pos := _ai_note_target(target, dt)
	# Alert reaction delay before engaging.
	if ai_state in [STATE_IDLE, STATE_PATROL]:
		_enter_alert(target, "spotted")
		_on_spotted(target, target_pos)
		return
	if ai_state == STATE_ALERT:
		_alert_timer -= dt
		_track_aim(target_pos, dt)
		if _alert_timer <= 0.0:
			ai_state = STATE_ENGAGE
		return
	if ai_state == STATE_TELEGRAPH:
		_ai_telegraph(dt, target, target_pos, space)
		return
	if ai_state == STATE_FIRE:
		_ai_fire(dt, target_pos, space)
		return
	_ai_engage(dt, target, target_pos, space)


## Hook: who this unit sees / tracks this tick (null: nobody). Default: the perception rules (_acquire_target).
func _ai_perceive(space: PhysicsDirectSpaceState3D) -> CombatTarget:
	return _acquire_target(space)


## No target this tick: drop the line, the telegraph and the slot, then search the board's last known position or wander.
func _ai_no_target(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	_has_los = false
	_no_los_time = 0.0
	_cover_mode = ""
	_on_target_dropped(dt)
	_cancel_telegraph("lost_los")
	_release_slot()
	var board_entry: Dictionary = _board_entry() if is_alerted() else {}
	if not board_entry.is_empty():
		_ai_search(dt, board_entry["pos"] as Vector3, space)
	else:
		if ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_COOLDOWN]:
			_emit_squad("alerted", {"id": target_id, "state": "lost", "pos": _world_pos()})
		_ai_wander(dt, space)


## Hook: the target was just dropped (before the telegraph is cancelled).
func _on_target_dropped(_dt: float) -> void:
	pass


## Hook: alerted, no target, the squad board knows where one was: go and look.
func _ai_search(dt: float, lkp: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	_step_search(dt, lkp, space)


## Hook: nothing known: a wave walks to the crew's deck, else patrol, and glance round.
func _ai_wander(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if not _step_transit(dt, space):
		_step_patrol(dt, space)
	_idle_scan(dt)


## The target's bookkeeping for this tick (seen: its live position; else the last known one); returns where to aim.
func _ai_note_target(target: CombatTarget, dt: float) -> Vector3:
	_target_id = target.target_id
	_last_target_ref = target
	var target_pos := Vector3.ZERO
	if _has_los:
		# the part seen (head / legs over low cover)
		target_pos = _target_aim_center(target) + _vis_off if _aims_at_seen_part() else _target_aim_center(target)
		_last_seen_pos = target_pos
		_update_target_velocity(target, target_pos, dt)
		_no_los_time = 0.0
		_hunt_t = 0.0
		if squad != null and squad.has_method("note_deck_activity"):
			squad.note_deck_activity(spawn_deck)
		if _relayed and squad != null and squad.has_method("report_sighting"):
			squad.report_sighting(self, target, target_pos)
	else:
		# TRUE LKP MEMORY (zero wallhack): when LOS is lost, aim/move/mortar ONLY at the frozen shared LKP
		# (or a defend wave's own known objective relay position when pushing an active defend).
		if target is AssetTarget:
			target_pos = _target_aim_center(target)
			_last_seen_pos = target_pos
		else:
			var b_entry := _board_entry()
			if not b_entry.is_empty():
				target_pos = b_entry["pos"] as Vector3
			else:
				target_pos = _last_seen_pos
		_target_vel = Vector3.ZERO
		_has_prev_pos = false
		_no_los_time += dt
	_aim_point = target_pos
	return target_pos


## Hook: aim at the part of the target actually seen (head / legs over low cover), not only its centre.
func _aims_at_seen_part() -> bool:
	return true


## Hook: just alerted by seeing `target` (after _enter_alert).
func _on_spotted(_target: CombatTarget, _target_pos: Vector3) -> void:
	pass


## Hook: one tick of a telegraph wind-up.
func _ai_telegraph(dt: float, target: CombatTarget, target_pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	_step_telegraph(dt, target, target_pos)


## Hook: one tick of a burst.
func _ai_fire(dt: float, _target_pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	_step_firing(dt)


## Hook: engaged, not telegraphing / firing: move, track and start a telegraph when the weapon, cooldown and slot allow.
func _ai_engage(dt: float, target: CombatTarget, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	# Reposition / flank while tracking target & waiting for cooldown + attack slot.
	_step_engage_movement(dt, target_pos, space)
	var track_err := _track_aim(target_pos, dt)
	var w_id := _choose_weapon(target_pos)
	if w_id != "" and _cooldown <= 0.0 and (track_err < 0.28 or w_id == "enemy_mortar"):
		if _request_slot(target.target_id):
			_begin_telegraph(w_id, target_pos)


func _enter_alert(target: CombatTarget, reason_state: String) -> void:
	if is_alerted():
		return
	_set_alert_state()
	_target_id = target.target_id
	_alert_timer = ALERT_DELAY
	_on_alert_perception_hint(target)
	if reason_state == "spotted" and not _relayed:
		_relay_timer = RELAY_DELAY
	alerted.emit(self, target.target_id)
	_emit_squad("alerted", {"id": target_id, "state": reason_state, "pos": _world_pos()})


## Called by EnemySquad when a squadmate finishes its 0.45 s comm relay.
func receive_squad_alert(target: CombatTarget) -> void:
	if _dead or puppet or is_alerted() or ai_mode == "idle":
		return
	_relayed = true
	_enter_alert(target, "relay")


## Called by EnemySquad's hearing (host / solo only) when player fire passed, landed or hit a squadmate near this enemy:
## like a damage alert (_on_damaged_alert), it alerts toward `shooter` with "spotted" (so its own 0.45 s relay runs), and
## it puts the shooter's position on the squad board as the heard position, so the AI turns toward it (turret slew /
## hull turn / search) even with no line of sight. Only live AI hears.
func hear_fire(shooter: CombatTarget) -> void:
	if _dead or puppet or is_alerted() or ai_mode != "live" or shooter == null or not is_instance_valid(shooter):
		return
	_last_target_ref = shooter
	_last_seen_pos = _target_aim_center(shooter)
	_aim_point = _last_seen_pos
	if squad != null and squad.has_method("report_sighting"):
		squad.report_sighting(self, shooter, _last_seen_pos)
	_enter_alert(shooter, "spotted")


func _fire_comms_relay() -> void:
	if _dead or _relayed:
		return
	_relayed = true
	if _telegraph_fx != null:
		_telegraph_fx.trigger_relay_ring(eye_world(), up)
	comms_relayed.emit(self)
	if squad != null:
		if _last_target_ref != null and is_instance_valid(_last_target_ref) and squad.has_method("report_sighting"):
			squad.report_sighting(self, _last_target_ref, _last_seen_pos)
		if squad.has_method("relay_alert_from"):
			squad.relay_alert_from(self, _target_id)


## Upper elevation angle (rad) this chassis can aim above its local floor plane (docs/design/wasp-ai.md §1.2).
func _max_aim_pitch() -> float:
	return deg_to_rad(65.0)


func _target_elevation(target_pos: Vector3) -> float:
	var d := target_pos - eye_world()
	var vert := d.dot(up)
	var horiz := (d - up * vert).length()
	return atan2(vert, maxf(horiz, 0.01))


func _target_is_airborne(target_pos: Vector3) -> bool:
	var h_deck := ring.height(target_pos) if ring != null else target_pos.y
	var h_above_me := (target_pos - _world_pos()).dot(up)
	return h_deck > 10.0 and h_above_me > 8.0


func _choose_weapon(target_pos: Vector3) -> String:
	var dist := _world_pos().distance_to(target_pos)
	var prim := str(_cfg.get("primary_weapon", ""))
	if prim != "" and not _primary_disabled and _has_los:
		var pst := EnemyCatalog.weapon(prim)
		if dist <= float(pst.get("range", 160.0)) and _target_elevation(target_pos) <= _max_aim_pitch():
			return prim
	var sec := str(_cfg.get("secondary_weapon", ""))
	if sec != "" and not _has_los and _no_los_time >= NO_LOS_MORTAR_TIME:
		if sec == "enemy_mortar" and _target_is_airborne(target_pos):
			return ""
		var sst := EnemyCatalog.weapon(sec)
		if dist >= float(sst.get("min_range", 30.0)) and dist <= float(sst.get("range", 175.0)):
			return sec
	return ""


func _begin_telegraph(weapon_id: String, target_pos: Vector3) -> void:
	_active_weapon = weapon_id
	_telegraph_dur = EnemyCatalog.telegraph_duration(weapon_id, telegraph_scale)
	_telegraph_t = 0.0
	_locked_aim = _lead_aim_point(weapon_id, target_pos, _telegraph_dur)
	ai_state = STATE_TELEGRAPH
	var st := EnemyCatalog.weapon(weapon_id)
	var muz := muzzle_world(weapon_id)
	telegraph_started.emit(self, weapon_id, _telegraph_dur, muz)
	_emit_squad("telegraph_started", {
		"id": target_id, "weapon": weapon_id, "kind": str(st.get("telegraph_kind", "cannon")),
		"pos": muz, "target_pos": _locked_aim, "duration": _telegraph_dur,
	})


## The line a direct-fire telegraph needs to keep going (default: the unit's own sight line). The trooper overrides it
## to accept its peek line from cover, the same line it was allowed to start the telegraph on.
func _telegraph_has_line(_live_pos: Vector3) -> bool:
	return _has_los


func _step_telegraph(dt: float, _target: CombatTarget, live_pos: Vector3) -> void:
	if _active_weapon != "enemy_mortar" and ai_mode != "telegraph_loop" and not _telegraph_has_line(live_pos):
		_cancel_telegraph("lost_los")
		_release_slot()
		ai_state = STATE_ENGAGE
		return
	_telegraph_t += dt
	var st := EnemyCatalog.weapon(_active_weapon)
	var lock_share := float(st.get("lock_share", 0.6))
	if _telegraph_t < _telegraph_dur * lock_share:
		var rem_tele := maxf(_telegraph_dur - _telegraph_t, 0.0)
		_locked_aim = _lead_aim_point(_active_weapon, live_pos, rem_tele)
		_track_aim(_locked_aim, dt)
	else:
		_track_aim(_locked_aim, dt)
	if _telegraph_t >= _telegraph_dur:
		ai_state = STATE_FIRE
		_burst_left = maxi(int(st.get("burst", 1)), 1)
		_burst_timer = 0.0
		heat.add(float(st.get("self_heat", 10.0)))


func _update_target_velocity(target: CombatTarget, live_pos: Vector3, dt: float) -> void:
	if dt <= 1e-5:
		return
	var raw_v := Vector3.ZERO
	if target is PlayerTarget and (target as PlayerTarget).mech != null:
		raw_v = (target as PlayerTarget).mech.velocity
	elif _has_prev_pos and _tracked_tid == target.target_id:
		raw_v = (live_pos - _prev_target_pos) / dt
		if raw_v.length() > 60.0:
			raw_v = Vector3.ZERO
			_target_vel = Vector3.ZERO
	else:
		_target_vel = Vector3.ZERO
	var alpha := clampf(dt * VEL_SMOOTH_RATE, 0.0, 1.0)
	_target_vel = _target_vel.lerp(raw_v, alpha)
	_tracked_tid = target.target_id
	_prev_target_pos = live_pos
	_has_prev_pos = true


## Partial 3D velocity lead for direct-fire weapons (damped vertical 0.65x for climbing/diving fliers),
## floor-plane lead for arc mortars; never extrapolates an unseen LKP (docs/design/wasp-ai.md §1.1).
func _lead_aim_point(weapon_id: String, base_pos: Vector3, rem_tele: float) -> Vector3:
	if not _has_los:
		return base_pos
	var st := EnemyCatalog.weapon(weapon_id)
	var lf := float(st.get("lead_factor", 0.0))
	if lf <= 0.0 or _target_vel.length_squared() < 0.04:
		return base_pos
	var v_up := _target_vel.dot(up)
	var flat_v := _target_vel - up * v_up
	var is_arc := str(st.get("kind", "")) == "arc"
	var lead_v := flat_v if is_arc else (flat_v + up * (v_up * 0.65))
	var muz := muzzle_world(weapon_id)
	var dist := muz.distance_to(base_pos)
	var flight_t := 0.0
	if is_arc:
		flight_t = MortarShell.flight_time_for(st, dist)
	else:
		flight_t = dist / maxf(float(st.get("speed", 50.0)), 1.0)
	var lead_t := minf(rem_tele + flight_t, MAX_LEAD_TIME) * lf
	return base_pos + lead_v * lead_t


func _step_firing(dt: float) -> void:
	var st := EnemyCatalog.weapon(_active_weapon)
	_burst_timer -= dt
	if _burst_timer <= 0.0 and _burst_left > 0:
		_fire_one_round(st)
		_burst_left -= 1
		_burst_timer = _burst_interval(st)
	if _burst_left <= 0:
		_cooldown = _burst_cooldown(st)
		_release_slot()
		_on_burst_done()
		ai_state = STATE_COOLDOWN if ai_mode == "live" else STATE_ENGAGE


## Hooks for the burst: the gap between rounds, the cooldown after the burst, what to drop when it ends.
func _burst_interval(st: Dictionary) -> float:
	return float(st.get("burst_interval", 0.15))


func _burst_cooldown(st: Dictionary) -> float:
	return float(st.get("burst_cooldown", 2.0))


func _on_burst_done() -> void:
	pass


## Hooks for a round: extra spread (deg) on top of the record's, and the pellet count (a fan when > 1).
func _extra_spread(st: Dictionary) -> float:
	return float(st.get("spread", 0.0)) + aim_kick   # static aim kick throws turret shots visibly off target


func _pellets(st: Dictionary) -> int:
	return maxi(int(st.get("pellets", 1)), 1)


func _fire_one_round(st: Dictionary) -> void:
	if world == null or puppet or not Net.is_host():   # co-op (W4): only the host's enemies fire
		return
	var muz := muzzle_world(_active_weapon)
	var aim := _locked_aim
	var extra_spread := _extra_spread(st)
	var pellets := _pellets(st)
	if pellets <= 1:
		var rec := Combat.fire_record(target_id, 1, _active_weapon, _active_weapon, muz, aim, world.now, _shot_index, extra_spread)
		rec["enemy"] = true
		rec["team"] = team
		_shot_index += 1
		world.fire(rec)
	else:
		# Multi-pellet horizontal fan (e.g., enemy_scatter 5-pellet 7.5 deg spread): each pellet replicates via world.fire.
		var fan_deg := float(st.get("fan_deg", 7.5))
		var diff := aim - muz
		var dist := maxf(diff.length(), 1.0)
		var base_dir := diff / dist
		for pi in pellets:
			var frac := (float(pi) / float(pellets - 1)) - 0.5
			var ang := deg_to_rad(fan_deg * frac)
			var p_aim := muz + base_dir.rotated(up, ang) * dist
			var rec := Combat.fire_record(target_id, 1, _active_weapon, _active_weapon, muz, p_aim, world.now, _shot_index, extra_spread)
			rec["enemy"] = true
			rec["team"] = team
			_shot_index += 1
			world.fire(rec)
	weapon_fired.emit(self, _active_weapon, muz, aim)
	_emit_squad("weapon_fired", {"id": target_id, "weapon": _active_weapon, "pos": muz, "aim_point": aim})
	note_combat_activity(false)
	if squad != null and squad.has_method("note_deck_activity"):
		squad.note_deck_activity(spawn_deck)


func _cancel_telegraph(reason: String) -> void:
	if ai_state == STATE_TELEGRAPH:
		telegraph_cancelled.emit(self, reason)
		_emit_squad("telegraph_cancelled", {"id": target_id, "reason": reason})
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	_burst_left = 0
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()


func _request_slot(tid: String) -> bool:
	if _has_slot:
		return true
	if squad == null or not squad.has_method("request_attack_slot"):
		_has_slot = true
		return true
	var prio := float(_cfg.get("slot_priority", 1.0))
	_has_slot = bool(squad.request_attack_slot(target_id, tid, prio))
	return _has_slot


## EnemySquad took this unit's attack slot away (EnemySquad._revoke_slot: pruned or removed): it holds none now.
func slot_revoked() -> void:
	_has_slot = false
	if ai_state == STATE_TELEGRAPH or ai_state == STATE_FIRE:   # no shot without a real slot
		_cancel_telegraph("slot")
		ai_state = STATE_ENGAGE


func _release_slot() -> void:
	if not _has_slot:
		return
	_has_slot = false
	if squad != null and squad.has_method("release_attack_slot"):
		squad.release_attack_slot(target_id)


# --- Perception & Movement Helpers ------------------------------------------------------------------------

## Defend relay (AssetTarget) targeting rule (Missions):
##   - A defend wave (defend_target_id != "") may attack ONLY its own defend relay (alongside crew mechs).
##   - Garrisons and all other waves NEVER target AssetTargets in missions/gameplay (whenever a deck/plan or any crew
##     mech exists). Standalone asset-only unit tests without a mission or crew still let a test turret acquire it.
func _can_target_asset(t: AssetTarget) -> bool:
	if defend_target_id != "":
		return t.asset_id == defend_target_id
	if wave != "":
		return false
	if squad != null and (squad.deck_of.is_valid() or squad.plan != null):
		return false
	if world != null:
		for other: CombatTarget in world.targets:
			if is_instance_valid(other) and other.team == "player" and not (other is AssetTarget):
				return false
	return true


func _acquire_target(space: PhysicsDirectSpaceState3D) -> CombatTarget:
	if world == null:
		return null
	# A2/A3: staggered 12.5-15 Hz perception (keeps cadence when nothing was seen via _perc_valid);
	# full 60 Hz during STATE_TELEGRAPH / STATE_FIRE / telegraph_loop so LOS breaks cancel cleanly.
	var force_scan := (ai_state == STATE_TELEGRAPH) or (ai_state == STATE_FIRE) or (ai_mode == "telegraph_loop") \
		or not _perc_valid or _perc_t <= 0.0 \
		or (_cached_target != null and (not is_instance_valid(_cached_target) or not _cached_target.is_hittable()))
	if not force_scan:
		return _cached_target
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	var was_valid := _perc_valid
	_perc_valid = true
	_perc_t = _perc_interval_now() if was_valid else _perc_stagger_offset()
	var now := world.now
	var elapsed := clampf(now - _perc_last, 0.0, 0.5) if _perc_last >= 0.0 else 0.0
	_perc_last = now
	var eye := eye_world()
	var best: CombatTarget = null
	var alerted_now := is_alerted() or ai_mode == "telegraph_loop"
	# Alerted: tracks anything with a line inside sight_range, any direction. Un-alerted: the notice rules (header).
	var notice_r := minf(sight_range, float(_cfg.get("notice_range", _cfg.get("patrol_sight_range", 65.0))))
	var eff_range := sight_range if alerted_now else notice_r
	var eff_range_sq := eff_range * eff_range
	var best_d2 := eff_range_sq
	var best_need := 0.0
	var best_off := Vector3.ZERO
	var best_pos := Vector3.ZERO
	var fov_cos := cos(deg_to_rad(float(_cfg.get("fov_deg", 150.0)) * 0.5))
	var fwd := _sensor_fwd()
	var near_r := minf(NEAR_AWARE_R, notice_r)
	var has_deck := squad != null and squad.has_method("on_deck")
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t == self or not t.is_hittable():
			continue
		if t.team == team or t.team == "":
			continue
		if (t is AssetTarget) and not _can_target_asset(t as AssetTarget):
			continue
		if has_deck and not squad.on_deck(t.global_position, spawn_deck):
			continue   # stack (W4): only targets on this enemy's own deck
		var tp := _target_aim_center(t)
		var d2 := eye.distance_squared_to(tp)
		if d2 > eff_range_sq or d2 > best_d2:
			continue
		var need := 0.0
		if not alerted_now:
			var d := sqrt(d2)
			var in_cone := fwd.dot((tp - eye) / maxf(d, 0.01)) >= fov_cos
			if not in_cone:
				var omni_r := near_r
				if _loud(t):
					omni_r = notice_r
				elif _target_speed(t) > MOVING_SPEED:
					omni_r = minf(near_r * MOVING_AWARE_MULT, notice_r)
				if d > omni_r:
					continue
			if not in_cone or d > INSTANT_NOTICE_R:
				need = lerpf(NOTICE_MIN, NOTICE_MAX, clampf(d / maxf(notice_r, 1.0), 0.0, 1.0))
		var off := _sight_offset(eye, t, tp, space)
		if is_nan(off.x):
			continue
		best = t
		best_d2 = d2
		best_need = need
		best_off = off
		best_pos = tp + off
	if best != null and best_need > 0.0:
		# Noticing (un-alerted): keep a clear line for the distance-scaled notice time before alerting. The sensor turns to
		# look meanwhile (_idle_scan); losing the line bleeds it off.
		if _notice_tid == best.target_id:
			_notice_t += elapsed
		else:
			_notice_tid = best.target_id
			_notice_t = 0.0
		_notice_pos = best_pos
		if _notice_t + 1e-4 < best_need:
			_perc_t = minf(_perc_t, maxf(best_need - _notice_t, 0.05))
			best = null
	elif best == null and _notice_tid != "":
		_notice_t = maxf(_notice_t - elapsed, 0.0)
		if _notice_t <= 0.0:
			_notice_tid = ""
	if best != null:
		_notice_tid = ""
		_notice_t = 0.0
		_vis_off = best_off
		_has_los = true
		_cached_target = best
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.acquire", Time.get_ticks_usec() - t0)
		return best
	# Fall back to shared squad target board only once this unit is alerted (prevents bypassing comm relay delay).
	_has_los = false
	var fallback: CombatTarget = null
	if is_alerted():
		var entry := _board_entry()
		if not entry.is_empty():
			var bt: Variant = entry.get("target")
			if bt != null and is_instance_valid(bt) and (bt as CombatTarget).is_hittable():
				if not (bt is AssetTarget) or _can_target_asset(bt as AssetTarget):
					fallback = bt as CombatTarget
	# Defend waves whose defend objective is active always know their target relay's location, so they keep
	# pushing onto the relay even if the crew leaves the deck or the wave spawned > sight_range from the relay.
	if fallback == null and defend_target_id != "" and squad != null and squad.has_method("live_defend_asset"):
		var relay := squad.live_defend_asset(defend_target_id) as AssetTarget
		if relay != null and (not has_deck or squad.on_deck(relay.global_position, spawn_deck)):
			fallback = relay
			_last_seen_pos = _target_aim_center(relay)
	_cached_target = fallback
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.acquire", Time.get_ticks_usec() - t0)
	return fallback


func _board_entry() -> Dictionary:
	if squad != null and squad.has_method("best_known_target"):
		return squad.best_known_target(_world_pos(), spawn_deck)
	return {}


## A4: zero-allocation world-space aim center using CombatTarget's cached sphere array.
func _target_aim_center(t: CombatTarget) -> Vector3:
	if t.hit_shapes.size() > 0:
		var xf := t.global_transform if t.is_inside_tree() else t.transform
		if t.wc_rev != t.shapes_rev or t.wc_xf != xf or t.wc_n != t.hit_shapes.size():
			t.refresh_world_cache(xf)
		if t.wc_n > 0:
			return t.wc_centers[0]
	return (t.global_position if t.is_inside_tree() else t.position) + t.up * 3.5


func _check_los(from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D, target: CombatTarget = null) -> bool:
	_los_hit_d = -1.0
	if space == null or not world.use_physics:
		return true
	var d := from.distance_to(to)
	if d < 2.0:
		return true
	los_rays += 1
	_ray_query.from = from
	_ray_query.to = to
	var excl := false
	if target is AssetTarget and (target as AssetTarget).mech != null and is_instance_valid((target as AssetTarget).mech):
		_ray_query.exclude = [(target as AssetTarget).mech.get_rid()]
		excl = true
	var h := space.intersect_ray(_ray_query)
	if excl:
		_ray_query.exclude = []
	if h.is_empty():
		return true
	var hd := from.distance_to(h["position"] as Vector3)
	# the ray reached the target's own body (a mech's capsule: 2.2 m Strider -> 2.6, the Bulwark's 3.6 -> 4.0) or close
	var reach := (target as PlayerTarget).body_radius + 0.4 if target is PlayerTarget else 2.6
	if hd >= d - reach:
		return true
	_los_hit_d = hd
	return false


## Clear line from `eye` to target `t` (aim centre `tp`): Vector3.ZERO when its torso is seen, the offset to its head or
## legs when only those are (low cover: a 2 m wall hides a trooper's view of a torso but not of an 8 m mech's head), NAN
## when blocked. The extra rays are cast only for a mech whose torso ray was blocked near either end (low cover), not
## behind a building in mid-street, which keeps the cost at one ray per target per check in the usual cases.
func _sight_offset(eye: Vector3, t: CombatTarget, tp: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	if _check_los(eye, tp, space, t):
		return Vector3.ZERO
	var no := Vector3(NAN, NAN, NAN)
	if t.mass_class != "mech" or _los_hit_d < 0.0:
		return no
	var d := eye.distance_to(tp)
	if _los_hit_d > LOS_LOW_COVER_R and _los_hit_d < d - LOS_LOW_COVER_R:
		return no
	var u := t.up
	# a player mech's own head / legs offsets (its chassis: PlayerTarget.CHASSIS_SIGHT; the Strider's are these constants)
	var offs: Array = (t as PlayerTarget).sight_offsets() if t is PlayerTarget else [u * LOS_HEAD_UP, -u * LOS_LEGS_DOWN]
	for off: Vector3 in offs:
		if _check_los(eye, tp + off, space, t):
			return off
	return no


## True for LOUD_TIME s after target `t` fired (EnemySquad hearing records every player shot's shooter).
func _loud(t: CombatTarget) -> bool:
	return squad != null and squad.has_method("fired_recently") and bool(squad.fired_recently(t.target_id, LOUD_TIME))


## Target speed over the floor from its positions between sight checks (m/s; 0 until it was seen twice).
func _target_speed(t: CombatTarget) -> float:
	var p := t.global_position if t.is_inside_tree() else t.position
	var now := world.now if world != null else 0.0
	var prev: Variant = _seen_pos.get(t.target_id)
	var spd := 0.0
	if prev is Array and now - float(prev[1]) > 1.0:
		_seen_pos[t.target_id] = [p, now]   # stale baseline: start again (the next check, 0.2 s on, measures)
	elif prev is Array and now - float(prev[1]) > 0.04:
		var dp: Vector3 = p - (prev[0] as Vector3)
		dp -= t.up * dp.dot(t.up)
		spd = dp.length() / (now - float(prev[1]))
		_seen_pos[t.target_id] = [p, now]
	elif not (prev is Array):
		_seen_pos[t.target_id] = [p, now]
	return spd


func _step_patrol(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if float(_cfg.get("move_speed", 0.0)) <= 0.0 or _patrol_points.is_empty():
		ai_state = STATE_IDLE
		_align_to_ring()
		return
	ai_state = STATE_PATROL
	var goal_arc := _patrol_points[_patrol_idx % _patrol_points.size()]
	var goal_w := _arc_to_world_pos(goal_arc)
	if _world_pos().distance_to(goal_w) < 4.5:
		_patrol_idx = (_patrol_idx + 1) % _patrol_points.size()
		goal_w = _arc_to_world_pos(_patrol_points[_patrol_idx])
	_steer_toward(goal_w, float(_cfg["move_speed"]) * 0.6 * speed_scale * _speed_mult, dt, space)


func _step_search(dt: float, lkp: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var spd := float(_cfg.get("move_speed", 0.0))
	if spd <= 0.0:
		_track_aim(lkp, dt)
		return
	if _world_pos().distance_to(lkp) > 10.0:
		_move_along_plan(lkp, spd * 0.85 * speed_scale * _speed_mult, dt, space)
	else:
		_align_to_ring()


func _step_engage_movement(dt: float, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	var base_spd := float(_cfg.get("move_speed", 0.0))
	if base_spd <= 0.0:
		_align_to_ring()
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.engage_move", Time.get_ticks_usec() - t0)
		return
	var pos := _world_pos()
	var dist := pos.distance_to(target_pos)
	var engage_r := EnemyCatalog.engage_range(enemy_type)
	# Phase C Cover-Bounding (docs/design/enemy-tactics-and-drones.md §4): mobile ground units outside their effective
	# weapon range advance via occluded side streets with periodic short peeks to refresh LKP instead of jogging down open lanes.
	# While hunting straggler-mode (_hunting), leave cover and push straight toward the player!
	if not _hunting and (dist > engage_r or (_cover_mode != "" and dist > engage_r * 0.95)):
		_step_cover_bound(dt, pos, target_pos, engage_r, base_spd, space)
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.engage_move", Time.get_ticks_usec() - t0)
		return
	_cover_mode = ""
	var pref := float(_cfg.get("preferred_range", 45.0))
	var min_r := float(_cfg.get("min_range", 16.0))
	if not _has_los or (_hunting and wave != "" and dist > 68.0):
		ai_state = STATE_FLANK
		_move_along_plan(target_pos, float(_cfg.get("flank_speed", base_spd)) * speed_scale * _speed_mult, dt, space)
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.engage_move", Time.get_ticks_usec() - t0)
		return
	if dist > pref * 1.25:
		ai_state = STATE_ENGAGE
		_move_along_plan(target_pos, base_spd * speed_scale * _speed_mult, dt, space)
	elif dist < min_r or _target_elevation(target_pos) > _max_aim_pitch() - deg_to_rad(5.0):
		# Back away when too close OR when an airborne target hovers inside our overhead pitch dead zone.
		ai_state = STATE_FLANK
		var away := (pos - target_pos)
		away -= up * away.dot(up)
		var back_dir := away.normalized() if away.length_squared() > 1e-4 else (global_basis.z if is_inside_tree() else Vector3.BACK)
		var dest := pos + back_dir * 14.0
		_steer_toward(dest, base_spd * 0.8 * speed_scale * _speed_mult, dt, space)
	elif enemy_type.begins_with("strider"):
		# Light skirmishers & breachers orbit/flank laterally instead of standing still in the street.
		ai_state = STATE_FLANK
		var to_t := target_pos - pos
		to_t -= up * to_t.dot(up)
		if to_t.length_squared() > 1e-4:
			var side := to_t.normalized().cross(up) * _flank_sign
			_steer_toward(pos + side * 12.0, float(_cfg.get("flank_speed", base_spd)) * 0.72 * speed_scale * _speed_mult, dt, space)
	else:
		ai_state = STATE_ENGAGE
		_align_to_ring()
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.engage_move", Time.get_ticks_usec() - t0)


func _step_cover_bound(dt: float, pos: Vector3, target_pos: Vector3, engage_r: float, base_spd: float,
		space: PhysicsDirectSpaceState3D) -> void:
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	ai_state = STATE_FLANK
	var flank_spd := float(_cfg.get("flank_speed", base_spd)) * speed_scale * _speed_mult
	if _cover_mode == "":
		_cover_mode = "bound"
		_cover_peek_cd = _rng.randf_range(COVER_PEEK_MIN, COVER_PEEK_MAX)
		_cover_path_timer = 0.0
	if _cover_mode == "peek":
		if _has_los:
			# Real physics LOS reacquired target: snap back to BOUND immediately with fresh LKP!
			_cover_mode = "bound"
			_cover_peek_cd = _rng.randf_range(COVER_PEEK_MIN, COVER_PEEK_MAX)
			_cover_path_timer = 0.0
			_path_points.clear()
		else:
			_cover_peek_left -= dt
			if _cover_peek_left <= 0.0:
				_cover_mode = "bound"
				_cover_peek_cd = _rng.randf_range(COVER_PEEK_MIN, COVER_PEEK_MAX)
				_cover_path_timer = 0.0
			else:
				_steer_toward(_cover_peek_goal, base_spd * 0.85 * speed_scale * _speed_mult, dt, space)
				if CombatWorld.profiling:
					CombatWorld.prof_add("ai.cover_bound", Time.get_ticks_usec() - t0)
				return
	# BOUND mode: sprint along cover-weighted road graph, peeking periodically if LOS has gone stale.
	_cover_peek_cd -= dt
	if _cover_peek_cd <= 0.0 and not _has_los and _no_los_time >= 2.5:
		_cover_mode = "peek"
		_cover_peek_left = COVER_PEEK_DUR
		_peek_count += 1
		_cover_peek_goal = _pick_peek_point(pos, target_pos, space)
		_steer_toward(_cover_peek_goal, base_spd * 0.85 * speed_scale * _speed_mult, dt, space)
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.cover_bound", Time.get_ticks_usec() - t0)
		return
	_move_along_cover_plan(target_pos, flank_spd, engage_r, dt, space)
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.cover_bound", Time.get_ticks_usec() - t0)


func _move_along_cover_plan(goal_w: Vector3, spd: float, engage_r: float, dt: float,
		space: PhysicsDirectSpaceState3D) -> void:
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	_cover_path_timer -= dt
	if _cover_path_timer <= 0.0 and _nav() != null:
		if not squad.has_method("claim_cover_repath") or squad.claim_cover_repath():
			_cover_path_timer = COVER_PATH_INTERVAL
			var cur_arc := _world_to_arc2(_world_pos())
			var goal_arc := _world_to_arc2(goal_w)
			_path_points = _nav().find_cover_path(cur_arc, goal_arc, goal_arc, spawn_deck, engage_r)
		else:
			_cover_path_timer = 0.05
	var steer_goal := Vector3.ZERO
	var has_wp := false
	while not _path_points.is_empty():
		var wp := _arc_to_world_pos(_path_points[0])
		if _world_pos().distance_to(wp) < 6.0:
			_path_points.pop_front()
		else:
			steer_goal = wp
			has_wp = true
			break
	if not has_wp:
		# Open-ground / flat-arena fallback: lateral zigzag approach so flankers never jog straight down fire lanes.
		_zigzag_t += dt
		if _zigzag_t >= 2.4:
			_zigzag_t = 0.0
			_flank_sign = -_flank_sign
		var pos := _world_pos()
		var to_t := goal_w - pos
		to_t -= up * to_t.dot(up)
		if to_t.length_squared() > 1e-4:
			var fwd := to_t.normalized()
			var side := fwd.cross(up) * _flank_sign
			steer_goal = pos + (fwd * 0.72 + side * 0.69).normalized() * 14.0
		else:
			steer_goal = goal_w
	_steer_toward(steer_goal, spd, dt, space)
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.cover_plan", Time.get_ticks_usec() - t0)


func _pick_peek_point(pos: Vector3, target_pos: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	var to_t := target_pos - pos
	to_t -= up * to_t.dot(up)
	if to_t.length_squared() < 1e-4:
		return pos
	var side := to_t.normalized().cross(up)
	var cands: Array[Vector3] = [
		pos + side * _flank_sign * COVER_PEEK_STEP,
		pos - side * _flank_sign * COVER_PEEK_STEP,
	]
	if not _path_points.is_empty():
		var nxt := _arc_to_world_pos(_path_points[0])
		if pos.distance_to(nxt) <= 16.0:
			cands.append(nxt)
	var eye_o := pos + up * probe_height
	var t_arc := _world_to_arc2(target_pos)
	var fallback := pos
	var has_fallback := false
	for cand: Vector3 in cands:
		if space != null and world != null and world.use_physics:
			if _ray_blocked(space, eye_o, cand + up * probe_height):
				continue
		if not has_fallback:
			fallback = cand
			has_fallback = true
		if _nav() != null:
			if not _nav().arc_segment_occluded(_world_to_arc2(cand), t_arc, spawn_deck):
				return cand
	return fallback


func _move_along_plan(goal_w: Vector3, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	# Wave units spawned inside a hidden gate recess behind the boundary wall must step out through exit_pt
	# (_patrol_points[0]) BEFORE starting road-graph A* so they never clip diagonally into the boundary wall!
	if wave != "" and not _patrol_points.is_empty() and squad != null and squad.has_method("deck_plan"):
		var dp: CityPlan = squad.deck_plan(spawn_deck)
		if dp != null:
			var cur_arc := _world_to_arc2(_world_pos())
			if not dp.extent.grow(-4.0).has_point(cur_arc):
				var exit_w := _arc_to_world_pos(_patrol_points[0])
				if _world_pos().distance_to(exit_w) > 3.5:
					_steer_toward(exit_w, spd, dt, space)
					return
	_path_timer -= dt
	if (_path_points.is_empty() or _path_timer <= 0.0) and _nav() != null:
		_path_timer = 2.5
		_path_points = _nav().find_arc_path(_world_to_arc2(_world_pos()), _world_to_arc2(goal_w), spawn_deck)
	var steer_goal := goal_w
	while not _path_points.is_empty():
		var wp := _arc_to_world_pos(_path_points[0])
		if _world_pos().distance_to(wp) < 6.5:
			_path_points.pop_front()
		else:
			steer_goal = wp
			break
	_steer_toward(steer_goal, spd, dt, space)


func _steer_toward(goal_w: Vector3, spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if spd <= 0.05 or knock.moving() or not _grounded_now:
		_align_to_ring()
		return
	var t0 := Time.get_ticks_usec() if CombatWorld.profiling else 0
	if _avoid_timer > 0.0:
		_avoid_timer = maxf(_avoid_timer - dt, 0.0)
	var pos := _world_pos()
	if _unstick_t > 0.0:
		_unstick_t = maxf(_unstick_t - dt, 0.0)
		if pos.distance_to(_unstick_goal) < 3.5:
			_unstick_t = 0.0
		else:
			goal_w = _unstick_goal
	var to_g := goal_w - pos
	to_g -= up * to_g.dot(up)
	if to_g.length_squared() < 0.25:
		_stuck_t = 0.0
		_stuck_travel = 0.0
		_align_to_ring()
		if CombatWorld.profiling:
			CombatWorld.prof_add("ai.steer", Time.get_ticks_usec() - t0)
		return
	var dir := to_g.normalized()
	# Soft sibling separation.
	if squad != null and squad.has_method("separation_vector"):
		var sep: Vector3 = squad.separation_vector(self)
		sep -= up * sep.dot(up)
		dir = (dir + sep * 1.4).normalized()
	# A5: 20 Hz throttled obstacle/slide/ground rays with cached wall normal & ground height (staggered per enemy).
	var has_phys := space != null and world != null and world.use_physics
	var do_ray := has_phys and _steer_ray_t <= 0.0
	var fwd_hit_n := Vector3.ZERO
	if do_ray:
		_steer_ray_t = STEER_RAY_INTERVAL
		var look_d := body_radius + 4.5
		fwd_hit_n = _ground_hit_normal(space, pos, dir, look_d, true)
		if fwd_hit_n != Vector3.ZERO:
			var left_d := dir.rotated(up, 0.75)
			var right_d := dir.rotated(up, -0.75)
			var lb := _ground_hit_normal(space, pos, left_d, look_d, false) != Vector3.ZERO
			var rb := _ground_hit_normal(space, pos, right_d, look_d, false) != Vector3.ZERO
			if not lb and rb:
				dir = left_d
				_flank_sign = 1.0
				_avoid_timer = 1.2
			elif not rb and lb:
				dir = right_d
				_flank_sign = -1.0
				_avoid_timer = 1.2
			else:
				# Broad building facade: slide cleanly along wall tangent (+ slight push away from wall) instead of pacing!
				var wall_n := fwd_hit_n - up * fwd_hit_n.dot(up)
				wall_n = wall_n.normalized() if wall_n.length_squared() > 1e-4 else -dir
				var tan_dir := (wall_n.cross(up).normalized() * _flank_sign + wall_n * 0.18).normalized()
				if _ground_hit_normal(space, pos, tan_dir, body_radius + 2.2, false) != Vector3.ZERO:
					if _avoid_timer <= 0.0:
						_flank_sign = -_flank_sign
						_avoid_timer = 1.2
					tan_dir = (wall_n.cross(up).normalized() * _flank_sign + wall_n * 0.18).normalized()
				elif _avoid_timer <= 0.0:
					_avoid_timer = 1.2
				dir = tan_dir
			_cached_avoid_dir = dir
		else:
			_cached_avoid_dir = Vector3.ZERO
	elif has_phys and _avoid_timer > 0.0 and _cached_avoid_dir != Vector3.ZERO:
		var cd := _cached_avoid_dir - up * _cached_avoid_dir.dot(up)
		if cd.length_squared() > 1e-4:
			dir = cd.normalized()
	# Turn hull smoothly toward move direction in local tangent plane.
	var cur_fwd := (-global_basis.z) if is_inside_tree() else Vector3.FORWARD
	cur_fwd = (cur_fwd - up * cur_fwd.dot(up)).normalized()
	if cur_fwd.length_squared() < 1e-6:
		cur_fwd = dir
	var turn_max := float(_cfg.get("turn_rate", 2.0)) * dt
	var signed_ang := cur_fwd.signed_angle_to(dir, up)
	var new_fwd := cur_fwd.rotated(up, clampf(signed_ang, -turn_max, turn_max)).normalized()
	var move_align := clampf(cur_fwd.dot(dir), 0.25, 1.0)
	var step_vec := new_fwd * spd * move_align * dt
	# Check immediate collision before advancing (reuses cached wall normal between 20 Hz probes; skips redundant ray when forward look was clear).
	if has_phys:
		var block_n := Vector3.ZERO
		if do_ray:
			if fwd_hit_n == Vector3.ZERO and new_fwd.dot(dir) > 0.96:
				block_n = Vector3.ZERO
			else:
				block_n = _ground_hit_normal(space, pos, new_fwd, body_radius + step_vec.length() + 0.4, true)
			_cached_block_n = block_n
			_cached_slide_blocked = false
		else:
			block_n = _cached_block_n
		if block_n != Vector3.ZERO:
			var wn := block_n - up * block_n.dot(up)
			if wn.length_squared() > 1e-4:
				wn = wn.normalized()
				var into := step_vec.dot(wn)
				if into < 0.0:
					step_vec -= wn * into
				if step_vec.length_squared() > 1e-6:
					if do_ray:
						var slide_d := step_vec.normalized()
						_cached_slide_blocked = _ground_hit_normal(space, pos, slide_d, body_radius + step_vec.length() + 0.35, false) != Vector3.ZERO
					if _cached_slide_blocked:
						step_vec = Vector3.ZERO
			else:
				step_vec = Vector3.ZERO
	step_vec = _keep_out_of_floor_cuts(pos, step_vec, dt)
	var next_pos := pos + step_vec
	if ring != null:
		up = ring.up_at(next_pos)
	if not has_phys or do_ray or not _has_ground_h:
		var g := _probe_ground_point(next_pos, space)
		if not is_nan(g.x):
			# Prevent mobile ground units from walking straight up tall walls (> 1.6 m step).
			var dh := (g - next_pos).dot(up)
			if dh <= 1.6 and dh >= -4.0:
				next_pos = g
				_ground_h_off = ring.height(g) if ring != null else g.y
				_has_ground_h = true
			elif dh > 1.6:
				next_pos = pos
				step_vec = Vector3.ZERO
		if has_phys:
			_ground_probe_t = STEER_RAY_INTERVAL
	else:
		# Between 20 Hz probes, track the curved ring surface smoothly at the cached ground height offset.
		if ring != null:
			next_pos += up * (_ground_h_off - ring.height(next_pos))
		else:
			next_pos.y = _ground_h_off
	# Ground unstick detector (host-only): recover cleanly if pacing/wedged (< 1.8 m net travel in 3.5 s) or inside a building.
	next_pos = _check_ground_unstick(next_pos, step_vec, dt)
	ground_y = next_pos.dot(up)
	if is_inside_tree():
		global_position = next_pos
		var flat_f := (new_fwd - up * new_fwd.dot(up)).normalized()
		if flat_f.length_squared() > 1e-6:
			global_basis = Basis(flat_f.cross(up).normalized(), up, -flat_f)
	else:
		position = next_pos
	var max_s := maxf(float(_cfg.get("flank_speed", _cfg.get("move_speed", 1.0))), 0.1)
	move_speed_ratio = clampf(step_vec.length() / maxf(dt, 1e-4) / max_s, 0.0, 1.0)
	if CombatWorld.profiling:
		CombatWorld.prof_add("ai.steer", Time.get_ticks_usec() - t0)


## A ground unit standing on its deck's floor never steps into a floor cut (a ramp mouth has no railing, so without this
## a unit cutting a corner walks down the ramp, is re-homed to the deck below and sleeps there). The step slides along
## the cut's edge instead (cuts are axis-aligned in arc space; arc x is world x). A unit already inside a cut (knocked
## onto a ramp) moves freely so it can walk out.
func _keep_out_of_floor_cuts(pos: Vector3, step_vec: Vector3, dt: float) -> Vector3:
	if _transit_ramp:
		return step_vec   # a wave unit walking a ramp to the next deck on purpose (_step_transit)
	if _cut_far_t > 0.0:
		_cut_far_t -= dt   # known to be well clear of every cut: skip (cheap path for most frames)
		return step_vec
	if ring == null or squad == null or step_vec.length_squared() < 1e-8 or _nav() == null:
		return step_vec
	var cuts: Array[Rect2] = _nav().deck_cuts(spawn_deck)
	if cuts.is_empty():
		_cut_far_t = 1.0
		return step_vec
	var a := _world_to_arc2(pos)
	var tan := ring.tangent_at(pos)
	var dx := step_vec.x
	var ds := step_vec.dot(tan)
	var nxt := a + Vector2(dx, ds)
	var hit := -1
	var far := true
	for i in cuts.size():
		var o: Rect2 = cuts[i].grow(FLOOR_CUT_KEEP)
		if o.has_point(a):
			return step_vec   # already inside (on a ramp): let it walk out
		if hit < 0 and o.has_point(nxt):
			hit = i
		if far and o.grow(FLOOR_CUT_FAR).has_point(a):
			far = false
	if hit < 0:
		if far:
			_cut_far_t = FLOOR_CUT_FAR_T   # a walker covers < FLOOR_CUT_FAR in this time
		return step_vec
	var o2: Rect2 = cuts[hit].grow(FLOOR_CUT_KEEP)
	if not o2.has_point(Vector2(a.x + dx, a.y)):
		return Vector3(dx, 0.0, 0.0)          # slide along x (across the cut's end)
	if not o2.has_point(Vector2(a.x, a.y + ds)):
		return tan * ds                        # slide along s (beside the cut)
	return Vector3.ZERO


func _ground_hit_normal(space: PhysicsDirectSpaceState3D, pos: Vector3, d: Vector3, dist: float, check_low: bool = true) -> Vector3:
	var c_hi := pos + up * probe_height
	_ray_query.from = c_hi
	_ray_query.to = c_hi + d * dist
	var h := space.intersect_ray(_ray_query)
	if not h.is_empty():
		var n: Vector3 = h["normal"]
		if absf(n.dot(up)) < 0.72:
			return n
	if check_low and probe_height > 1.1:
		var c_lo := pos + up * 0.8
		_ray_query.from = c_lo
		_ray_query.to = c_lo + d * dist
		var h2 := space.intersect_ray(_ray_query)
		if not h2.is_empty():
			var n2: Vector3 = h2["normal"]
			if absf(n2.dot(up)) < 0.72:
				return n2
	return Vector3.ZERO


func _check_ground_unstick(next_pos: Vector3, step_vec: Vector3, dt: float) -> Vector3:
	if puppet or not Net.is_host():
		return next_pos
	if _stuck_t <= 0.0:
		_stuck_anchor = next_pos
	_stuck_t += dt
	_stuck_travel += step_vec.length()
	if _stuck_t >= 2.8:
		var inside_b := false
		if squad != null and squad.has_method("deck_plan") and not _transit_ramp:   # a ramp is not "inside a building" while transiting
			var d_plan: CityPlan = squad.deck_plan(spawn_deck)
			if d_plan != null:
				var h_cur := ring.height(next_pos) if ring != null else next_pos.y
				var a2 := _world_to_arc2(next_pos)
				if h_cur < 2.0 and (not EnemySpawner.clear_of_buildings(d_plan, a2, 0.5, 0.0) or not EnemySpawner._clear_of_ramps(d_plan, a2, 0.5)):
					inside_b = true
		var net_d := next_pos.distance_to(_stuck_anchor)
		if inside_b or net_d < 1.8:
			if _path_points.size() >= 2:
				_path_points.pop_front()
			else:
				_path_points.clear()
				_path_timer = 0.0
			_cover_path_timer = 0.0
			_flank_sign = -_flank_sign
			_avoid_timer = 1.2
			_steer_ray_t = 0.0
			_ground_probe_t = 0.0
			_cached_avoid_dir = Vector3.ZERO
			_cached_block_n = Vector3.ZERO
			_cached_slide_blocked = false
			if _nav() != null and not _transit_ramp:
				var rp: Vector2 = _nav().nearest_road_point(_world_to_arc2(next_pos), spawn_deck, 8.0)
				if not is_nan(rp.x):
					_unstick_goal = _arc_to_world_pos(rp)
					_unstick_t = 2.6
					if inside_b:
						var escape := _unstick_goal - next_pos
						escape -= up * escape.dot(up)
						if escape.length_squared() > 1e-4:
							next_pos += escape.normalized() * minf(2.5, escape.length())
		_stuck_t = 0.0
		_stuck_travel = 0.0
		_stuck_anchor = next_pos
	return next_pos


func _ray_blocked(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	_ray_query.from = a
	_ray_query.to = b
	var h := space.intersect_ray(_ray_query)
	return not h.is_empty() and absf((h["normal"] as Vector3).dot(up)) < 0.72


func _align_to_ring() -> void:
	if not is_inside_tree():
		return
	var f := -global_basis.z
	f -= up * f.dot(up)
	if f.length_squared() < 1e-6:
		f = ring.tangent_at(global_position) if ring != null else Vector3.FORWARD
	f = f.normalized()
	global_basis = Basis(f.cross(up).normalized(), up, -f)


## Subclasses override to slew turret / head and return angular aim error (rad).
func _track_aim(_target_pos: Vector3, _dt: float) -> float:
	return 0.0


func _update_reveal_fx(dt: float) -> void:
	if _telegraph_fx == null:
		return
	if revealed and not _dead:
		_telegraph_fx.show_reveal_flare(eye_world(), up, dt)
	else:
		_telegraph_fx.hide_reveal_flare()


func _update_visuals(dt: float) -> void:
	_step_stagger_anim(dt)
	if _telegraph_fx != null:
		if ai_state == STATE_TELEGRAPH and _telegraph_dur > 0.0:
			var frac := clampf(_telegraph_t / _telegraph_dur, 0.0, 1.0)
			var st := EnemyCatalog.weapon(_active_weapon)
			var locked := frac >= float(st.get("lock_share", 0.6))
			var show_beam := _active_weapon != "enemy_mortar"
			_telegraph_fx.show_telegraph(muzzle_world(_active_weapon), _locked_aim, frac, locked,
				telegraph_orb_radius(_active_weapon), show_beam, dt)
		else:
			_telegraph_fx.hide_telegraph()
			_telegraph_fx.tick_only(dt)
		_update_reveal_fx(dt)
	if _status_bar != null:
		var tag := "OVERHEAT" if heat.shutdown else ("STAGGER" if knock.staggered() else "")
		_status_bar.refresh(core_hp_ratio(), heat_ratio, is_alerted(), ai_state == STATE_TELEGRAPH, tag, _dead, dt, revealed)


## The stagger animation's step (base _update_visuals calls it; units that don't call super call it themselves): the
## unit's seen velocity, then the timeline over the mechanical window (exact here on the host, guessed on a puppet). The
## push direction: the last hit's impulse on this machine if fresh, else the knockback velocity (host) or the slide the
## puppet sees, else straight back.
func _step_stagger_anim(dt: float) -> void:
	var p := _world_pos()
	if _vis_has_prev and dt > 1e-5:
		var v := (p - _vis_prev) / dt
		_vis_vel = v if v.length_squared() < 2500.0 else _vis_vel   # a teleport (spawn, rehome) is not motion
	_vis_prev = p
	_vis_has_prev = true
	_last_hit_age += dt
	var flagged := knock.staggered() and not _dead
	if not flagged and not _stagger_anim.active:
		return
	var push_w := Vector3.ZERO
	if _last_hit_age < 0.35 and _last_hit_dir.length_squared() > 1e-4:
		push_w = _last_hit_dir
	elif not puppet and knock.velocity.length_squared() > 0.25:
		push_w = knock.velocity
	elif _vis_vel.length_squared() > 1.0:
		push_w = _vis_vel
	push_w -= up * push_w.dot(up)
	var push_l := global_basis.inverse() * push_w if is_inside_tree() and push_w.length_squared() > 1e-6 else Vector3.ZERO
	_stagger_anim.step(dt, flagged, -1.0 if puppet else knock.stagger_left, push_l, puppet)


## The stagger rock for units without legs: a tilt about the axis across the push (the top leans with the hit),
## `amp` rad at full rock. Identity at rest.
func stagger_rock_basis(amp: float) -> Basis:
	var a := _stagger_anim
	if not a.active:
		return Basis.IDENTITY
	var axis := Vector3.UP.cross(a.push)
	if axis.length_squared() < 1e-6:
		return Basis.IDENTITY
	return Basis(axis.normalized(), amp * a.rock)


## The squad's path service (EnemySquad.nav), or null without one (no squad, or a test stub without it).
func _nav() -> EnemyNav:
	return squad.get("nav") as EnemyNav if squad != null else null


func _world_pos() -> Vector3:
	return global_position if is_inside_tree() else position


func _world_to_arc2(p: Vector3) -> Vector2:
	return RingFrame.world_to_arc2(ring, p)


func _arc_to_world_pos(arc2: Vector2) -> Vector3:
	if ring != null:
		return ring.arc_to_world(arc2.x, arc2.y, CityPlan.CURB_H)
	return Vector3(arc2.x, 0.0, arc2.y)


func _emit_squad(kind: String, payload: Dictionary) -> void:
	if squad != null and squad.has_method("emit_enemy_event"):
		squad.emit_enemy_event(kind, self, payload)


func set_patrol_points(pts: Array[Vector2]) -> void:
	_patrol_points = pts.duplicate()
	_patrol_idx = 0


func debug_info() -> Dictionary:
	return {
		"id": target_id, "type": enemy_type, "state": ai_state, "hp": total_hp(), "core_hp": float(hp.get(core_component(), 0.0)),
		"heat": heat.value, "has_los": _has_los, "has_slot": _has_slot, "aim": _aim_point, "locked_aim": _locked_aim,
		"path": _path_points, "dead": _dead, "cover_mode": _cover_mode, "peek_count": _peek_count,
		"revealed": revealed, "hunting": _hunting,
	}


func reset_enemy() -> void:
	_dead = false
	_dead_time = 0.0
	_primary_disabled = false
	_speed_mult = 1.0
	_relayed = false
	_relay_timer = -1.0
	_no_los_time = 0.0
	_cooldown = 0.0
	_cover_mode = ""
	_cover_peek_cd = 0.0
	_cover_peek_left = 0.0
	_cover_peek_goal = Vector3.ZERO
	_cover_path_timer = 0.0
	_zigzag_t = 0.0
	_peek_count = 0
	revealed = false
	_hunting = false
	_hunt_t = 0.0
	_revealed_idle_t = 0.0
	_reveal_flare_cd = 0.0
	_avoid_timer = 0.0
	_stuck_anchor = Vector3.ZERO
	_stuck_t = 0.0
	_stuck_travel = 0.0
	_unstick_goal = Vector3.ZERO
	_unstick_t = 0.0
	_perc_valid = false
	_perc_t = 0.0
	_cached_target = null
	_steer_ray_t = 0.0
	_cut_far_t = 0.0
	clear_transit()
	_cached_avoid_dir = Vector3.ZERO
	_cached_block_n = Vector3.ZERO
	_cached_slide_blocked = false
	_ground_probe_t = 0.0
	_has_ground_h = false
	_lod_tick = 0
	_lod_dt = 0.0
	_target_vel = Vector3.ZERO
	_has_prev_pos = false
	_last_seen_pos = Vector3.ZERO
	_last_hit_dir = Vector3.ZERO
	_last_hit_age = 99.0
	_stagger_anim.reset()
	_vis_has_prev = false
	_vis_vel = Vector3.ZERO
	wreck.clear()
	_wreck_cooled = false
	_cancel_telegraph("reset")
	_release_slot()
	ai_state = STATE_IDLE
	_apply_catalog_components()
	reset_state()
	if is_inside_tree():
		global_transform = _home_xf
	for arr: Array in _comp_nodes.values():
		for mi: MeshInstance3D in arr:
			if is_instance_valid(mi):
				mi.visible = true
				mi.material_overlay = null
				mi.material_override = null
	_on_reset_visual()


func _on_reset_visual() -> void:
	pass


# --- Co-op PUPPET (W4; scripts/game/enemy_sync.gd) ---------------------------------------------------------------
# The host reads puppet_state() from its real enemy; a crew client writes it into its copy (`puppet` true) with
# puppet_apply(), replays discrete changes with puppet_telegraph / puppet_break / puppet_kill, and runs the
# presentation with puppet_tick() (hit flashes, telegraph, status bar, stride, wreck fx). No AI, no verbs.

## The enemy's OWNER state the puppets need: {state, aim (Vector2: subclass turret / torso yaw, pitch), heat (0..1),
## shutdown, stagger, kick (aim_kick deg), lock (the locked aim point, world), dead, hp (PackedFloat32Array: each
## component's fraction, comp_order() order)}.
func puppet_state() -> Dictionary:
	var fr := PackedFloat32Array()
	for c in comp_order():
		fr.append(clampf(float(hp.get(c, 0.0)) / maxf(float(max_hp.get(c, 1.0)), 0.001), 0.0, 1.0))
	return {"state": ai_state, "aim": puppet_aim(), "heat": heat.fraction(), "shutdown": heat.shutdown,
		"stagger": knock.staggered(), "kick": aim_kick, "lock": _locked_aim, "dead": _dead, "hp": fr}


## Component ids in catalog order (the order puppet_state's hp fractions use).
func comp_order() -> Array[String]:
	var out: Array[String] = []
	for c: Dictionary in _cfg.get("components", []):
		out.append(str(c["id"]))
	if out.is_empty():
		out.append_array(hp.keys())
	return out


## Subclasses: the aim pose (turret yaw / pitch, torso yaw) as a Vector2, and setting it on a puppet.
func puppet_aim() -> Vector2:
	return Vector2.ZERO


func set_puppet_aim(_a: Vector2) -> void:
	pass


## Puppet: the host's streamed state (puppet_state's keys; "move" / "slew" are derived by the caller from the motion).
## A component whose HP went down flashes.
func puppet_apply(st: Dictionary) -> void:
	if _dead:
		return
	ai_state = str(st.get("state", ai_state))
	set_puppet_aim(st.get("aim", Vector2.ZERO) as Vector2)
	heat.value = float(st.get("heat", 0.0)) * heat.cap
	heat.shutdown = bool(st.get("shutdown", false))
	heat_ratio = float(st.get("heat", 0.0))
	knock.stagger_left = 0.2 if bool(st.get("stagger", false)) else 0.0
	aim_kick = float(st.get("kick", 0.0))
	move_speed_ratio = float(st.get("move", 0.0))
	turret_slew_speed = float(st.get("slew", 0.0))
	if st.has("lock"):
		_locked_aim = st["lock"] as Vector3
	var fr: PackedFloat32Array = st.get("hp", PackedFloat32Array())
	var order := comp_order()
	for i in mini(fr.size(), order.size()):
		var c := order[i]
		var v := fr[i] * float(max_hp.get(c, 0.0))
		if v < float(hp.get(c, 0.0)) - 0.01:
			_trigger_hit_flash(c)
		hp[c] = v


## Puppet: a telegraph of `weapon_id` running for `elapsed` of its `dur` s (the host's start on the shared clock),
## toward `lock` (world). puppet_telegraph_end() stops showing it (fired, or cancelled).
func puppet_telegraph(weapon_id: String, elapsed: float, dur: float, lock: Vector3) -> void:
	if _dead:
		return
	_active_weapon = weapon_id
	_telegraph_dur = maxf(dur, 0.01)
	_telegraph_t = clampf(elapsed, 0.0, _telegraph_dur)
	_locked_aim = lock
	ai_state = STATE_TELEGRAPH


func puppet_telegraph_end() -> void:
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	if ai_state == STATE_TELEGRAPH:
		ai_state = STATE_ENGAGE
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()


## Puppet: the host's component `c` broke: the same pop-off debris, flame, impact and signals (a core / critical break
## kills it here too, as on the host).
func puppet_break(c: String) -> void:
	if _dead or not hp.has(c):
		return
	hp[c] = 0.0
	_on_component_broken(c, _comp_meta.get(c, {}))


## Puppet: the host's enemy was destroyed: the same explosion, debris (looks generator) and wreck.
func puppet_kill(cause: String) -> void:
	_kill(cause)


## Puppet presentation step (instead of tick(), which only the host runs).
func puppet_tick(dt: float) -> void:
	_tick_flashes(dt)
	if _dead:
		if _wreck_cooled:
			return
		_dead_time += dt
		if _telegraph_fx != null:
			_telegraph_fx.tick_only(dt)
		_tick_wreck_fx(dt)
		return
	if ring != null:
		up = ring.up_at(_world_pos())
	_update_visuals(dt)
	wreck.step_flames(dt)
