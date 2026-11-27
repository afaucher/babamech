class_name PlayerBot
extends Node
## Fair, input-only Player AI pilot (docs/design/player-ai.md §2).
## Drives a real MechController + WeaponRack + PlayerTarget strictly through human inputs:
##   mech.move_input, mech.turn_input, mech.running, mech.thrust_input
##   rack.aim_point, rack.set_trigger(), rack.set_enabled()
## Never teleports, never writes transforms/velocity/heat directly, never wallhacks, and uses
## only its private seeded RandomNumberGenerator (zero global randomness).

const HOP_ROOF_MARGIN := 0.3   ## m under a hop-only chassis' MechCatalog.bot_hop_height a roof must be to stay a vantage (bind)
const STATE_EXPLORE := "explore"
const STATE_ADVANCE := "advance"
const STATE_ENGAGE := "engage"
const STATE_DODGE := "dodge"
const STATE_CLIMB_ROOF := "climb_roof"
const STATE_TAKE_COVER := "take_cover"
const STATE_SHUTDOWN := "shutdown"
const STATE_DISABLED := "disabled"

const SIGHT_RANGE := 175.0
const MEMORY_DECAY := 18.0
const EYE_HEIGHT := 6.5
const SPHERE_REACH := 30.0         ## m: no enemy hit sphere lies farther than this from the unit's origin (range prefilter)
const LOS_REFRESH := 1.0 / 12.0    ## s between two sight casts to the same enemy (_los_refreshed)
const WP_REFRESH := 0.2            ## s a weak point's "unoccluded" answer is reused (_wp_unoccluded)
const TELEGRAPH_SAME_EPS := 0.15   ## s: a telegraph whose start moved more than this is a new instance (_telegraph_is_new)
const SEEN_TTL := 10.0             ## s a telegraph record outlives its last sighting (longer than any telegraph)

signal dodge_triggered(threat_kind: String, with_hop: bool)

# Config (Net.SPAWN)
var profile_id := "average"
var bot_id := "bot1"
var bot_seed := 1
var auto_step := true

# Scene references (Net.LOCAL)
var mech: MechController
var rack: WeaponRack
var target: PlayerTarget
var world: CombatWorld
var squad: EnemySquad
var city_plan: CityPlan
var ring: RingFrame
var cam: ChaseCamera
var bot_squad: PlayerBotSquad
var _nav: BotNavigator
var _profile: Dictionary = {}

# Internal brain state (Net.PRIVATE)
var ai_state := STATE_EXPLORE
var _rng := RandomNumberGenerator.new()
var _sim_t := 0.0
var _aim_dir := Vector3.FORWARD
var _aim_init := false
var _aim_err := Vector2.ZERO            ## OU angular aim drift (yaw, pitch) in radians
var _memory: Dictionary = {}            ## enemy_id -> {enemy, pos, last_seen_t, has_los, est_vel, ready_at, prev_pos, prev_t}
var _los_cache: Dictionary = {}         ## enemy_id -> [next cast at _sim_t, last answer] (_los_refreshed)
var _wp_cache: Dictionary = {}          ## "enemy_id|component" -> [valid until _sim_t, unoccluded] (_wp_unoccluded)
var _threat_queue: Array[Dictionary] = []   ## [{key, trigger_t, kind, origin, landing, is_mortar}]
var _seen_telegraphs: Dictionary = {}   ## enemy_id -> {shot, start, tel_t, seen_t}: the telegraph instance last reacted to (_telegraph_is_new)
var _seen_mortars: Dictionary = {}      ## effect key -> true, dropped once the shell leaves world.effects
var _dodge_left := 0.0
var _dodge_dir := Vector3.ZERO
var _dodge_hop_left := 0.0
var _strafe_sign := 1.0
var _strafe_flip_t := 2.0
var _overheat_wait := false
var _current_enemy: EnemyBase
var _active_roof: Dictionary = {}
var _roof_cd := 0.0
var _roof_climb_t := 0.0
var _cover_pt := Vector3(NAN, NAN, NAN)
var _cover_left := 0.0
var _cover_cd := 0.0
var _last_damage_t := -999.0
var _last_damage_src := ""
var _pending_dodge_checks: Array[Dictionary] = []   ## [{resolve_t, dmg_at_start}]
var _total_dmg_seen := 0.0

# Public diagnostics (Net.LOCAL)
var dodges_attempted := 0
var dodges_clean := 0
var last_nav_goal := Vector3.ZERO
var last_aim_world := Vector3.ZERO
## The enemy the layer above wants dead first (MissionBot: a hunted blocker of a flag / hold zone), "" = none. Weighs in
## _choose_target only while it is in sight (PRIORITY_BONUS), so the bot never fixates on what it cannot hit.
var priority_id := ""
const PRIORITY_BONUS := 70.0


func net_fields() -> Dictionary:
	return {
		"profile_id": Net.SPAWN, "bot_id": Net.SPAWN, "bot_seed": Net.SPAWN, "auto_step": Net.SPAWN,
		"mech": Net.LOCAL, "rack": Net.LOCAL, "target": Net.LOCAL, "world": Net.LOCAL,
		"squad": Net.LOCAL, "city_plan": Net.LOCAL, "ring": Net.LOCAL, "cam": Net.LOCAL,
		"bot_squad": Net.LOCAL, "_nav": Net.LOCAL, "_profile": Net.LOCAL,
		"ai_state": Net.PRIVATE, "_rng": Net.PRIVATE, "_sim_t": Net.PRIVATE,
		"_aim_dir": Net.PRIVATE, "_aim_init": Net.PRIVATE, "_aim_err": Net.PRIVATE,
		"_memory": Net.PRIVATE, "_los_cache": Net.PRIVATE, "_wp_cache": Net.PRIVATE, "_threat_queue": Net.PRIVATE, "_seen_telegraphs": Net.PRIVATE,
		"_seen_mortars": Net.PRIVATE, "_dodge_left": Net.PRIVATE, "_dodge_dir": Net.PRIVATE,
		"_dodge_hop_left": Net.PRIVATE, "_strafe_sign": Net.PRIVATE, "_strafe_flip_t": Net.PRIVATE,
		"_overheat_wait": Net.PRIVATE, "_current_enemy": Net.LOCAL, "_active_roof": Net.PRIVATE,
		"_roof_cd": Net.PRIVATE, "_roof_climb_t": Net.PRIVATE, "_cover_pt": Net.PRIVATE,
		"_cover_left": Net.PRIVATE, "_cover_cd": Net.PRIVATE, "_last_damage_t": Net.PRIVATE,
		"_last_damage_src": Net.PRIVATE, "_pending_dodge_checks": Net.PRIVATE, "_total_dmg_seen": Net.PRIVATE,
		"dodges_attempted": Net.LOCAL, "dodges_clean": Net.LOCAL,
		"last_nav_goal": Net.LOCAL, "last_aim_world": Net.LOCAL, "priority_id": Net.PRIVATE,
	}


## The enemy this bot is fighting, or null. Untyped: it may already be freed (callers check is_instance_valid).
func current_target() -> Variant:
	return _current_enemy


## True when enemy `eid` is remembered and in line of sight now.
func sees(eid: String) -> bool:
	return _memory.has(eid) and bool((_memory[eid] as Dictionary).get("has_los", false))


func configure(profile: String = "average", seed_val: int = 1, id: String = "bot1") -> void:
	profile_id = profile if BotProfile.has_profile(profile) else "average"
	bot_seed = seed_val
	bot_id = id
	_profile = BotProfile.get_profile(profile_id)
	_rng.seed = hash([bot_seed, bot_id, profile_id])
	_strafe_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
	_strafe_flip_t = _rng.randf_range(float(_profile["strafe_flip_min_s"]), float(_profile["strafe_flip_max_s"]))


func bind(m: MechController, r: WeaponRack, pt: PlayerTarget, w: CombatWorld, sq: EnemySquad = null,
		plan: CityPlan = null, rf: RingFrame = null, camera: ChaseCamera = null) -> void:
	mech = m
	rack = r
	target = pt
	world = w
	squad = sq
	city_plan = plan
	ring = rf
	cam = camera
	if _profile.is_empty():
		configure(profile_id, bot_seed, bot_id)
	if rack != null:
		rack.read_input = false
		rack.manual_aim = true
	if target != null and not target.damaged.is_connected(_on_player_damaged):
		target.damaged.connect(_on_player_damaged)
	_nav = BotNavigator.new()
	_nav.setup(city_plan, ring, _rng)
	if mech != null and MechCatalog.bot_hop_height(mech.chassis_id) > 0.0:
		_nav.drop_roofs_above(MechCatalog.bot_hop_height(mech.chassis_id) - HOP_ROOF_MARGIN)   # a hop-only chassis: only the roofs it can hop onto
	_reset_runtime()


func set_arena_roofs(roofs: Array[Dictionary]) -> void:
	if _nav != null:
		_nav.set_arena_roofs(roofs)


func _reset_runtime() -> void:
	_sim_t = 0.0
	_aim_init = false
	_aim_err = Vector2.ZERO
	_memory.clear()
	_los_cache.clear()
	_wp_cache.clear()
	_threat_queue.clear()
	_seen_telegraphs.clear()
	_seen_mortars.clear()
	_dodge_left = 0.0
	_dodge_hop_left = 0.0
	_overheat_wait = false
	_current_enemy = null
	_active_roof = {}
	_roof_cd = 0.0
	_roof_climb_t = 0.0
	_cover_pt = Vector3(NAN, NAN, NAN)
	_cover_left = 0.0
	_cover_cd = 0.0
	_last_damage_t = -999.0
	_last_damage_src = ""
	_pending_dodge_checks.clear()
	_total_dmg_seen = 0.0
	dodges_attempted = 0
	dodges_clean = 0
	ai_state = STATE_EXPLORE
	if mech != null and mech.is_inside_tree():
		_nav.reset_stuck(mech.global_position)


func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


func step(dt: float) -> void:
	if dt <= 0.0 or mech == null or not is_instance_valid(mech) or not mech.is_inside_tree():
		return
	_sim_t += dt
	if _roof_cd > 0.0:
		_roof_cd = maxf(_roof_cd - dt, 0.0)
	if _cover_cd > 0.0:
		_cover_cd = maxf(_cover_cd - dt, 0.0)
	_resolve_dodge_checks()

	if target != null and target.disabled:
		ai_state = STATE_DISABLED
		_clear_inputs()
		return
	if mech.shutdown:
		ai_state = STATE_SHUTDOWN
		_overheat_wait = true
		_clear_inputs()
		return

	if not _aim_init:
		_aim_dir = mech.forward()
		_aim_init = true

	var sp := world.space() if world != null else null
	var pf := PerfProbe.on   # bench instrumentation (tests/bench_bot_perf.gd): per-phase timers, off in play
	var ta := Time.get_ticks_usec() if pf else 0
	_sense(dt, sp)
	var tb := Time.get_ticks_usec() if pf else 0
	_update_threats(dt, sp)
	_current_enemy = _choose_target()
	var tc := Time.get_ticks_usec() if pf else 0
	_update_tactics(dt, sp)
	var td := Time.get_ticks_usec() if pf else 0
	_update_movement(dt, sp)
	var te := Time.get_ticks_usec() if pf else 0
	_update_aim_and_weapons(dt, sp)
	if pf:
		var tf := Time.get_ticks_usec()
		PerfProbe.add("bot.pb.sense", tb - ta)
		PerfProbe.add("bot.pb.threats", tc - tb)
		PerfProbe.add("bot.pb.tactics", td - tc)
		PerfProbe.add("bot.pb.move", te - td)
		PerfProbe.add("bot.pb.aim", tf - te)
		PerfProbe.add("bot.player", tf - ta)


func _clear_inputs() -> void:
	if mech != null:
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
	if rack != null:
		rack.set_trigger(false)


func _on_player_damaged(amount: float, _component: String, src: String) -> void:
	_total_dmg_seen += amount
	_last_damage_t = _sim_t
	_last_damage_src = src
	# Alert bot to attacker after human reaction delay (no instant 180 snap).
	if world == null or src == "":
		return
	for t: CombatTarget in world.targets:
		if is_instance_valid(t) and t is EnemyBase and t.target_id == src and not (t as EnemyBase).destroyed():
			var e := t as EnemyBase
			if not _memory.has(e.target_id):
				var p := _enemy_core_pos(e)
				_memory[e.target_id] = {
					"enemy": e, "pos": p, "last_seen_t": _sim_t, "has_los": false,
					"est_vel": Vector3.ZERO, "ready_at": _sim_t + _sample_reaction(),
					"prev_pos": p, "prev_t": _sim_t,
				}
			break


# --- 1. Honest Perception & LKP Memory -------------------------------------------------------------------

func _sense(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	if world == null:
		return
	var up := mech.up()
	var eye := mech.global_position + up * EYE_HEIGHT
	var excl := [mech.get_rid()]
	var vel_rate := float(_profile["vel_track_rate"])

	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or not (t is EnemyBase):
			continue
		var e := t as EnemyBase
		if e.destroyed() or e.team != "enemy":
			_memory.erase(e.target_id)
			_los_cache.erase(e.target_id)
			continue
		# Cheap range test on the origin first (perf): every hit sphere lies within SPHERE_REACH of it, so a unit this far
		# out is past SIGHT_RANGE whatever its core sphere is; world_spheres() is only built for the ones that may be in.
		var od2 := eye.distance_squared_to(e.global_position)
		if od2 > (SIGHT_RANGE + SPHERE_REACH) * (SIGHT_RANGE + SPHERE_REACH):
			if _memory.has(e.target_id):
				(_memory[e.target_id] as Dictionary)["has_los"] = false
			continue
		var fresh := is_instance_valid(_current_enemy) and _current_enemy == e   # the current target is cast every frame (_los_refreshed)
		# Surely in range and the held sight answer is "blocked": the occluded branch below needs no core position.
		if not fresh and od2 < (SIGHT_RANGE - SPHERE_REACH) * (SIGHT_RANGE - SPHERE_REACH) and _los_held_blocked(e.target_id):
			if _memory.has(e.target_id):
				var mb: Dictionary = _memory[e.target_id]
				mb["has_los"] = false
				mb["est_vel"] = (mb["est_vel"] as Vector3).lerp(Vector3.ZERO, clampf(dt * 3.0, 0.0, 1.0))
			continue
		var core_p := _enemy_core_pos(e)
		var dist := eye.distance_to(core_p)
		if dist > SIGHT_RANGE:
			if _memory.has(e.target_id):
				(_memory[e.target_id] as Dictionary)["has_los"] = false
			continue
		var has_los := _los_refreshed(e.target_id, eye, core_p, sp, excl, fresh)
		if has_los:
			if bot_squad != null:
				bot_squad.report_sighting(self, e, core_p, _sim_t)
			if not _memory.has(e.target_id):
				_memory[e.target_id] = {
					"enemy": e, "pos": core_p, "last_seen_t": _sim_t, "has_los": true,
					"est_vel": Vector3.ZERO, "ready_at": _sim_t + _sample_reaction(),
					"prev_pos": core_p, "prev_t": _sim_t,
				}
			else:
				var m: Dictionary = _memory[e.target_id]
				var elapsed := _sim_t - float(m["prev_t"])
				if elapsed > 1e-4:
					var raw_v := (core_p - (m["prev_pos"] as Vector3)) / elapsed
					if raw_v.length() > 45.0:
						raw_v = Vector3.ZERO
					m["est_vel"] = (m["est_vel"] as Vector3).lerp(raw_v, clampf(dt * vel_rate, 0.0, 1.0))
				m["pos"] = core_p
				m["prev_pos"] = core_p
				m["prev_t"] = _sim_t
				m["last_seen_t"] = _sim_t
				m["has_los"] = true
		elif _memory.has(e.target_id):
			var m: Dictionary = _memory[e.target_id]
			m["has_los"] = false
			m["est_vel"] = (m["est_vel"] as Vector3).lerp(Vector3.ZERO, clampf(dt * 3.0, 0.0, 1.0))

	# Receive delayed voice callouts from squadmates (honest LKP only; still requires personal LOS to fire direct).
	if bot_squad != null:
		for c: Dictionary in bot_squad.shared_contacts_for(self, _sim_t):
			var ce: EnemyBase = c["enemy"]
			var ceid := ce.target_id
			var cpos: Vector3 = c["pos"]
			if not _memory.has(ceid):
				_memory[ceid] = {
					"enemy": ce, "pos": cpos, "last_seen_t": _sim_t, "has_los": false,
					"est_vel": Vector3.ZERO, "ready_at": _sim_t + _sample_reaction(),
					"prev_pos": cpos, "prev_t": _sim_t,
				}
			elif not bool((_memory[ceid] as Dictionary)["has_los"]):
				var cm: Dictionary = _memory[ceid]
				cm["pos"] = cpos
				cm["last_seen_t"] = maxf(float(cm["last_seen_t"]), float(c["seen_t"]))

	# Units freed without a destroyed() frame (despawned) leave cache keys behind: drop the caches now and then.
	if _los_cache.size() > 256:
		_los_cache.clear()
	if _wp_cache.size() > 256:
		_wp_cache.clear()
	# Expire stale / dead memories.
	for eid: String in _memory.keys():
		var m: Dictionary = _memory[eid]
		var e: Variant = m.get("enemy")
		if e == null or not is_instance_valid(e) or (e as EnemyBase).destroyed() or _sim_t - float(m["last_seen_t"]) > MEMORY_DECAY:
			_memory.erase(eid)


## True when _los_refreshed would return a held "blocked" answer for `eid` this frame (no cast due).
func _los_held_blocked(eid: String) -> bool:
	var c: Variant = _los_cache.get(eid)
	return c != null and _sim_t < float((c as Array)[0]) and not bool((c as Array)[1])


## The sight line to enemy `eid`, re-cast at most every LOS_REFRESH s (perf: 20+ enemies in range per bot made the
## per-frame casts the bot's largest cost). Each enemy gets a seeded phase so the casts spread over the frames; between
## casts the last answer holds. A first sighting is cast at once, and so is the bot's current target every frame
## (`fresh`): what it shoots at is always judged on this frame's line.
func _los_refreshed(eid: String, from: Vector3, to: Vector3, sp: PhysicsDirectSpaceState3D, excl: Array,
		fresh: bool = false) -> bool:
	var c: Variant = _los_cache.get(eid)
	if not fresh and c != null and _sim_t < float((c as Array)[0]):
		return bool((c as Array)[1])
	var v := _has_los(from, to, sp, excl)
	var phase := 1.0
	if c == null:   # first cast: a per-(bot, enemy) phase in [0.25, 1] staggers the next casts of a crowd seen together
		phase = 0.25 + 0.75 * float(hash(eid + "|" + bot_id) & 0xFFFF) / 65535.0
	_los_cache[eid] = [_sim_t + LOS_REFRESH * phase, v]
	return v


func _has_los(from: Vector3, to: Vector3, sp: PhysicsDirectSpaceState3D, excl: Array) -> bool:
	if sp == null:
		return true
	var d := from.distance_to(to)
	if d < 2.0:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = excl
	if PerfProbe.on:
		PerfProbe.count("ray.pb.los")   # bench instrumentation (tests/bench_bot_perf.gd)
	var h := sp.intersect_ray(q)
	return h.is_empty() or from.distance_to(h["position"] as Vector3) >= d - 2.6


# --- 2. Threat & Telegraph Monitor (Reaction-Delayed) ----------------------------------------------------

func _update_threats(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	if _dodge_left > 0.0:
		_dodge_left = maxf(_dodge_left - dt, 0.0)
	if _dodge_hop_left > 0.0:
		_dodge_hop_left = maxf(_dodge_hop_left - dt, 0.0)

	# Detect visible enemy telegraphs.
	for eid: String in _memory:
		var m: Dictionary = _memory[eid]
		if not bool(m["has_los"]):
			continue
		var e: EnemyBase = m["enemy"]
		if e.ai_state == EnemyBase.STATE_TELEGRAPH:
			var tkey := "%s:%d" % [eid, e.shot_index()]
			if _telegraph_is_new(eid, e):
				_threat_queue.append({
					"key": tkey,
					"trigger_t": _sim_t + _sample_reaction(),
					"kind": e.active_weapon(),
					"origin": e.muzzle_world(e.active_weapon()),
					"landing": Vector3.ZERO,
					"is_mortar": e.active_weapon() == "enemy_mortar",
				})

	# Detect incoming enemy MortarShell ground-ring telegraphs (visible to any player on the ground).
	if world != null:
		var pos := mech.global_position
		var live_mortars := {}
		for eff: CombatEffect in world.effects:
			if eff is MortarShell:
				var ms := eff as MortarShell
				if not bool(ms.record.get("enemy", false)):
					continue
				var mk := ms.key()
				live_mortars[mk] = true
				if _seen_mortars.has(mk):
					continue
				var rad := float(ms.stats.get("splash_radius", 6.5))
				if pos.distance_to(ms.landing) <= rad + 7.5:
					_seen_mortars[mk] = true
					_threat_queue.append({
						"key": mk,
						"trigger_t": _sim_t + _sample_reaction(),
						"kind": "enemy_mortar",
						"origin": ms.origin,
						"landing": ms.landing,
						"is_mortar": true,
					})
		# A landed shell never comes back: forget its key.
		for mk: String in _seen_mortars.keys():
			if not live_mortars.has(mk):
				_seen_mortars.erase(mk)
	_prune_seen_telegraphs()

	# Process due threats once reaction delay elapses.
	var keep: Array[Dictionary] = []
	var up := mech.up()
	var heat_frac := mech.heat / maxf(mech.heat_cap, 1.0)
	for th: Dictionary in _threat_queue:
		if _sim_t < float(th["trigger_t"]):
			keep.append(th)
			continue
		var is_mortar := bool(th["is_mortar"])
		var chance := clampf(float(_profile["dodge_chance"]) + (0.15 if is_mortar else 0.0), 0.0, 0.98)
		if _rng.randf() > chance:
			continue
		var pos := mech.global_position
		var dodge_v := Vector3.ZERO
		if is_mortar:
			var away := pos - (th["landing"] as Vector3)
			away -= up * away.dot(up)
			dodge_v = away.normalized() if away.length_squared() > 0.25 else mech.forward().cross(up).normalized() * _strafe_sign
		else:
			var from_e := pos - (th["origin"] as Vector3)
			from_e -= up * from_e.dot(up)
			var perp := from_e.normalized().cross(up) if from_e.length_squared() > 0.25 else mech.forward().cross(up)
			# Reverse current strafe direction to break enemy partial velocity lead!
			_strafe_sign = -_strafe_sign
			dodge_v = perp * _strafe_sign
			# If chosen dodge side is immediately walled, flip to the clear side.
			if sp != null:
				var excl := [mech.get_rid()]
				var c := pos + up * 3.8
				var q1 := PhysicsRayQueryParameters3D.create(c, c + dodge_v * 9.0)
				q1.exclude = excl
				if not sp.intersect_ray(q1).is_empty():
					dodge_v = -dodge_v
					_strafe_sign = -_strafe_sign
		_dodge_dir = dodge_v.normalized()
		_dodge_left = float(_profile["dodge_duration_s"]) * (1.25 if is_mortar else 1.0)
		var heavy := str(th["kind"]) in ["enemy_siege_shell", "enemy_mortar"]
		var with_hop := heavy and heat_frac < 0.65 and _rng.randf() < float(_profile["hop_on_heavy"])
		if with_hop:
			_dodge_hop_left = 0.34
		dodges_attempted += 1
		_pending_dodge_checks.append({"resolve_t": _sim_t + 1.5, "dmg_at_start": _total_dmg_seen})
		dodge_triggered.emit(str(th["kind"]), with_hop)
	_threat_queue = keep


## True once per telegraph instance of `e`. An enemy that cancels a telegraph (lost sight) and starts another keeps
## its `_shot_index`, so the instance is told apart by its start (bot time minus the enemy's elapsed telegraph time):
## a timer that went backwards or a start that moved more than TELEGRAPH_SAME_EPS is a new telegraph.
func _telegraph_is_new(eid: String, e: EnemyBase) -> bool:
	var tel_t := e.telegraph_elapsed()
	var start := _sim_t - tel_t
	var prev: Dictionary = _seen_telegraphs.get(eid, {})
	var fresh := prev.is_empty() or int(prev["shot"]) != e.shot_index() \
			or tel_t < float(prev["tel_t"]) - 0.0001 or absf(start - float(prev["start"])) > TELEGRAPH_SAME_EPS
	_seen_telegraphs[eid] = {"shot": e.shot_index(), "start": start, "tel_t": tel_t, "seen_t": _sim_t}
	return fresh


## Drops telegraph records not refreshed for SEEN_TTL (dead, freed or long-unseen enemies).
func _prune_seen_telegraphs() -> void:
	for eid: String in _seen_telegraphs.keys():
		if _sim_t - float(_seen_telegraphs[eid]["seen_t"]) > SEEN_TTL:
			_seen_telegraphs.erase(eid)


func _resolve_dodge_checks() -> void:
	if _pending_dodge_checks.is_empty():
		return
	var keep: Array[Dictionary] = []
	for dc: Dictionary in _pending_dodge_checks:
		if _sim_t >= float(dc["resolve_t"]):
			if _total_dmg_seen <= float(dc["dmg_at_start"]) + 0.01:
				dodges_clean += 1
		else:
			keep.append(dc)
	_pending_dodge_checks = keep


# --- 3. Target Selection & Tactical State Machine --------------------------------------------------------

func _choose_target() -> EnemyBase:
	var best: EnemyBase = null
	var best_score := -INF
	var pos := mech.global_position
	for eid: String in _memory:
		var m: Dictionary = _memory[eid]
		if _sim_t < float(m["ready_at"]):
			continue
		var e: EnemyBase = m["enemy"]
		if not is_instance_valid(e) or e.destroyed():
			continue
		var dist := pos.distance_to(m["pos"] as Vector3)
		var score := 120.0 - dist
		if bool(m["has_los"]):
			score += 45.0
		if e.ai_state == EnemyBase.STATE_TELEGRAPH:
			score += 24.0   # prioritize interrupting/killing an active threat
		if e.enemy_type == "turret":
			score += 12.0   # turrets have lethal bolters & low gun weak-point HP
		elif e.enemy_type == "strider" and dist < 45.0:
			score += 16.0   # close flanker pressure
		if e == _current_enemy:
			score += 18.0   # target hysteresis so bot finishes kills cleanly
		if priority_id != "" and e.target_id == priority_id and bool(m["has_los"]):
			score += PRIORITY_BONUS
		if bot_squad != null and e.target_id == bot_squad.primary_target_id:
			score += bot_squad.focus_fire_bias * 28.0
		if score > best_score:
			best_score = score
			best = e
	return best


func _update_tactics(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	var heat_frac := mech.heat / maxf(mech.heat_cap, 1.0)
	if heat_frac >= float(_profile["heat_stop"]):
		_overheat_wait = true
	elif heat_frac <= float(_profile["heat_resume"]):
		_overheat_wait = false

	if _dodge_left > 0.0:
		ai_state = STATE_DODGE
		return

	if _current_enemy == null:
		_active_roof = {}
		_cover_left = 0.0
		ai_state = STATE_EXPLORE
		return

	var mem: Dictionary = _memory.get(_current_enemy.target_id, {})
	var has_los := bool(mem.get("has_los", false))
	var en_pos: Vector3 = mem.get("pos", _enemy_core_pos(_current_enemy))
	var my_h := _nav.height_of(mech.global_position)

	# Continue an active rooftop climb until reached, aborted, or timed out.
	if not _active_roof.is_empty():
		_roof_climb_t += dt
		if _roof_climb_t > 7.5 or heat_frac >= 0.80:
			_active_roof = {}
			_roof_cd = 7.0
			_roof_climb_t = 0.0
		else:
			ai_state = STATE_CLIMB_ROOF
			return

	# Check whether to climb a nearby rooftop vantage (especially vs Tank to melt rear/top vents!).
	if _roof_cd <= 0.0 and my_h < 5.0 and heat_frac < 0.55 and _current_enemy.enemy_type in ["tank", "turret"]:
		var rc := float(_profile["rooftop_chance"])
		var urgent_roof := _current_enemy.enemy_type == "tank" and rc >= 0.75
		if rc > 0.0 and (urgent_roof or _rng.randf() < rc * dt * 2.5):
			var efwd := -_current_enemy.global_basis.z if _current_enemy.is_inside_tree() else Vector3.FORWARD
			var perch := _nav.find_rooftop_vantage(mech.global_position, en_pos, efwd, _current_enemy.enemy_type, 46.0)
			if not perch.is_empty():
				_active_roof = perch
				_roof_climb_t = 0.0
				ai_state = STATE_CLIMB_ROOF
				return
			elif urgent_roof:
				_roof_cd = 2.0

	# Continue active cover duck (cooling / wounded / mortar counter-battery).
	if _cover_left > 0.0:
		_cover_left -= dt
		if not _overheat_wait and _min_core_hp_frac() > 0.65:
			_cover_left = 0.0
		else:
			ai_state = STATE_TAKE_COVER
			return

	# Consider taking cover if hot or wounded against a heavy/turret threat.
	var want_cover := (_overheat_wait or _min_core_hp_frac() < 0.50) and _current_enemy.enemy_type in ["tank", "turret"]
	if want_cover and _cover_cd <= 0.0 and float(_profile["use_cover_chance"]) > 0.0 and has_los:
		_cover_cd = 6.0
		if _rng.randf() < float(_profile["use_cover_chance"]):
			var cp := _nav.find_cover_point(mech, _current_enemy.eye_world(), sp)
			if not is_nan(cp.x):
				_cover_pt = cp
				_cover_left = 3.2
				ai_state = STATE_TAKE_COVER
				return

	if not has_los:
		ai_state = STATE_ADVANCE
	else:
		ai_state = STATE_ENGAGE


# --- 4. Movement & Input Projection ----------------------------------------------------------------------

func _update_movement(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	var up := mech.up()
	var pos := mech.global_position
	var wish_w := Vector3.ZERO
	var want_run := false
	var want_thrust := false
	var move_scale := 1.0
	var turn_target_dir := _aim_dir

	match ai_state:
		STATE_DODGE:
			wish_w = _nav.avoid_obstacles(mech, _dodge_dir, sp, up)
			want_run = bool(_profile["run_on_dodge"])
			want_thrust = _dodge_hop_left > 0.0
			last_nav_goal = pos + wish_w * 12.0

		STATE_CLIMB_ROOF:
			var heat_frac := mech.heat / maxf(mech.heat_cap, 1.0)
			var res := _nav.step_rooftop_climb(mech, _active_roof, up, heat_frac)
			if bool(res["reached"]) or bool(res["aborted"]):
				_active_roof = {}
				_roof_cd = 8.0
				_roof_climb_t = 0.0
				ai_state = STATE_ENGAGE
			else:
				wish_w = res["dir"] as Vector3
				want_thrust = bool(res["thrust"])
				want_run = bool(res["running"])
				last_nav_goal = _active_roof["center_w"] as Vector3
				if wish_w.length_squared() > 0.1 and _current_enemy == null:
					turn_target_dir = wish_w

		STATE_TAKE_COVER:
			if not is_nan(_cover_pt.x) and pos.distance_to(_cover_pt) > 3.5:
				var st := _nav.steer_to(mech, _cover_pt, dt, sp, false)
				wish_w = st["dir"] as Vector3
				want_run = bool(_profile["run_on_advance"])
				want_thrust = bool(st["thrust"])
				last_nav_goal = _cover_pt
			else:
				wish_w = Vector3.ZERO
				last_nav_goal = pos

		STATE_EXPLORE:
			var goal := _nav.next_explore_goal(pos)
			if goal.distance_to(pos) > 3.0:
				var st := _nav.steer_to(mech, goal, dt, sp, true)
				wish_w = st["dir"] as Vector3
				want_run = bool(_profile["run_on_advance"])
				want_thrust = bool(st["thrust"])
				last_nav_goal = st["waypoint"] as Vector3
				if wish_w.length_squared() > 0.05:
					turn_target_dir = wish_w
			else:
				# Flat arena with no road graph and no spotted enemies yet: rotate slowly to scan.
				turn_target_dir = mech.forward().rotated(up, 0.8)
				last_nav_goal = pos

		STATE_ADVANCE:
			var mem: Dictionary = _memory.get(_current_enemy.target_id, {})
			var lkp: Vector3 = mem.get("pos", _enemy_core_pos(_current_enemy))
			# If Veteran has a ready mortar and is at safe indirect range, slow/pause briefly to lob over cover.
			var dist := pos.distance_to(lkp)
			var mortar_ready := bool(_profile["use_mortar"]) and dist >= 34.0 and dist <= 200.0 and _has_ready_mortar()
			if mortar_ready and profile_id == "veteran" and _current_enemy.enemy_type in ["tank", "turret"]:
				wish_w = Vector3.ZERO
				last_nav_goal = pos
			else:
				var st := _nav.steer_to(mech, lkp, dt, sp, true)
				wish_w = st["dir"] as Vector3
				want_run = bool(_profile["run_on_advance"])
				want_thrust = bool(st["thrust"])
				last_nav_goal = st["waypoint"] as Vector3
				if wish_w.length_squared() > 0.05:
					turn_target_dir = wish_w

		STATE_ENGAGE:
			var mem: Dictionary = _memory.get(_current_enemy.target_id, {})
			var en_pos: Vector3 = mem.get("pos", _enemy_core_pos(_current_enemy))
			var to_e := en_pos - pos
			to_e -= up * to_e.dot(up)
			var dist := to_e.length()
			var fwd_e := to_e.normalized() if dist > 0.1 else mech.forward()
			var side_e := fwd_e.cross(up).normalized()
			var pref := float(_profile["preferred_range"])
			var min_r := float(_profile["min_range"])
			var max_r := float(_profile["max_range"])
			var on_roof := _nav.height_of(pos) >= 5.0

			_strafe_flip_t -= dt
			if _strafe_flip_t <= 0.0:
				_strafe_sign = -_strafe_sign
				_strafe_flip_t = _rng.randf_range(float(_profile["strafe_flip_min_s"]), float(_profile["strafe_flip_max_s"]))

			if on_roof:
				# Stay safely on the rooftop deck while strafing gently (don't walk off ledge blindly).
				var roof_strafe := side_e * _strafe_sign
				if sp != null and _ledge_ahead(pos, roof_strafe, up, sp):
					_strafe_sign = -_strafe_sign
					roof_strafe = -roof_strafe
					if _ledge_ahead(pos, roof_strafe, up, sp):
						roof_strafe = Vector3.ZERO
				wish_w = roof_strafe
				move_scale = 0.45
			else:
				var radial := 0.0
				if dist > max_r:
					radial = 0.85
					want_run = bool(_profile["run_on_advance"])
				elif dist > pref + 8.0:
					radial = 0.45
				elif dist < min_r:
					radial = -0.75
				var raw_move := fwd_e * radial + side_e * _strafe_sign
				if bot_squad != null:
					# Spread around the pocket at assigned flank sector & avoid stacking in one splash radius.
					var flank_a := bot_squad.flank_angle_for(self)
					if absf(flank_a) > 0.05:
						var want_from_e := (-fwd_e).rotated(up, flank_a)
						var desired_pos := en_pos + want_from_e * pref
						var to_flank := desired_pos - pos
						to_flank -= up * to_flank.dot(up)
						if to_flank.length() > 6.0:
							raw_move += to_flank.normalized() * 0.55
					var sep := bot_squad.separation_vector(self, up)
					raw_move += sep * 1.15
					var lof := bot_squad.friendly_in_line_of_fire(self, pos + up * EYE_HEIGHT, en_pos, up)
					if bool(lof["blocked"]):
						raw_move += (lof["sidestep"] as Vector3) * 1.6
				if raw_move.length_squared() > 1e-4:
					wish_w = _nav.avoid_obstacles(mech, raw_move.normalized(), sp, up)
				move_scale = float(_profile["walk_strafe_scale"])
			last_nav_goal = pos + wish_w * 10.0

	if bot_squad != null and ai_state in [STATE_EXPLORE, STATE_ADVANCE]:
		var sep_nav := bot_squad.separation_vector(self, up)
		if sep_nav.length_squared() > 0.01:
			wish_w = (wish_w + sep_nav * 0.85).normalized()

	# Project world-space wish direction onto MechController's local (right, forward) inputs.
	var mf := mech.forward()
	var mr := mf.cross(up).normalized()
	wish_w -= up * wish_w.dot(up)
	if wish_w.length_squared() > 1e-4:
		var wn := wish_w.normalized() * clampf(move_scale, 0.0, 1.0)
		mech.move_input = Vector2(wn.dot(mr), wn.dot(mf)).limit_length(1.0)
	else:
		mech.move_input = Vector2.ZERO
	mech.running = want_run
	mech.thrust_input = want_thrust

	# Turn body toward target/aim heading (identical gain to MissionScene._physics_process).
	var td := turn_target_dir - up * turn_target_dir.dot(up)
	if td.length_squared() > 1e-5:
		var yaw_err := -mf.signed_angle_to(td.normalized(), up)
		mech.turn_input = clampf(yaw_err * 4.0, -1.0, 1.0)
	else:
		mech.turn_input = 0.0


func _ledge_ahead(pos: Vector3, dir: Vector3, up: Vector3, sp: PhysicsDirectSpaceState3D) -> bool:
	var probe := pos + dir.normalized() * 3.8
	var q := PhysicsRayQueryParameters3D.create(probe + up * 1.5, probe - up * 4.0)
	q.exclude = [mech.get_rid()]
	return sp.intersect_ray(q).is_empty()


# --- 5. Aim Slew/OU Drift & Weapon Rack Scheduler --------------------------------------------------------

func _update_aim_and_weapons(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	if rack == null:
		return
	var up := mech.up()
	var eye := mech.global_position + up * EYE_HEIGHT

	if _current_enemy == null or not is_instance_valid(_current_enemy) or _current_enemy.destroyed():
		rack.set_trigger(false)
		# Gently return aim forward along body facing while exploring.
		_slew_aim_toward(mech.forward(), dt, up)
		last_aim_world = eye + _aim_dir * 80.0
		rack.aim_point = last_aim_world
		_sync_camera(up)
		return

	var mem: Dictionary = _memory.get(_current_enemy.target_id, {})
	var has_los := bool(mem.get("has_los", false))
	var base_target := _pick_aim_point(_current_enemy, mem, eye, has_los)
	var dist := eye.distance_to(base_target)

	# Apply imperfect ballistic lead for moving targets based on profile lead_skill.
	var est_vel: Vector3 = mem.get("est_vel", Vector3.ZERO)
	var lead_skill := float(_profile["lead_skill"])
	var lead_pos := base_target
	if has_los and lead_skill > 0.01 and est_vel.length_squared() > 0.16:
		var proj_spd := _dominant_projectile_speed()
		if proj_spd > 1.0:
			var flight_t := minf(dist / proj_spd, 1.8)
			lead_pos = base_target + est_vel * (flight_t * lead_skill)

	var desired_dir := (lead_pos - eye).normalized()
	_slew_aim_toward(desired_dir, dt, up)

	# Continuous seeded Ornstein-Uhlenbeck angular aim drift (realistic hand wobble).
	var err_rad := deg_to_rad(float(_profile["aim_error_deg"]))
	var theta := float(_profile["aim_drift_hz"]) * TAU
	var decay := exp(-theta * dt)
	var sigma := err_rad * sqrt(maxf(1.0 - decay * decay, 0.0))
	_aim_err.x = _aim_err.x * decay + _rand_normal() * sigma
	_aim_err.y = _aim_err.y * decay + _rand_normal() * sigma

	var flat_aim := (_aim_dir - up * _aim_dir.dot(up))
	var aim_right := flat_aim.normalized().cross(up).normalized() if flat_aim.length_squared() > 1e-5 else mech.forward().cross(up).normalized()
	var noisy_dir := _aim_dir.rotated(up, _aim_err.x).rotated(aim_right, _aim_err.y).normalized()

	# Place aim_point at target distance along noisy ray (or world surface hit if shorter while no LOS).
	var aim_w := eye + noisy_dir * dist
	if not has_los and sp != null:
		# Mortar over cover: aim directly at the remembered LKP + small error so arc lands on target.
		aim_w = base_target + aim_right * (_aim_err.x * dist * 0.5)
	last_aim_world = aim_w
	rack.aim_point = aim_w
	_sync_camera(up)

	# Reserve heat for thrusters while actively climbing onto a rooftop vantage.
	if ai_state == STATE_CLIMB_ROOF:
		rack.set_trigger(false)
		return

	# Schedule weapon slots using the read-only WeaponRack HUD contract.
	var slots := rack.slots()
	var heat := rack.heat_state()
	var cur_heat := float(heat["heat"])
	var heat_cap := maxf(float(heat["cap"]), 1.0)
	var heat_limit := float(_profile["heat_stop"]) * heat_cap
	var target_hp := _current_enemy.total_hp()
	var wait_on_t := bool(_profile["wait_on_target"])
	var shed := bool(_profile["per_slot_heat_shed"])
	var aim_angle_deg := rad_to_deg(_aim_dir.angle_to(desired_dir))

	var friendly_blocked := false
	if bot_squad != null and has_los:
		friendly_blocked = bool(bot_squad.friendly_in_line_of_fire(self, eye, aim_w, up)["blocked"])

	# First pass: determine tactical eligibility per slot.
	var eligible: Array[Dictionary] = []
	for s: Dictionary in slots:
		var slot_n := int(s["slot"])
		var wid := str(s["weapon"])
		if wid == "" or not bool(s["built"]) or int(s["ammo"]) == 0 or str(s["hold"]) != "":
			rack.set_enabled(slot_n, false)
			continue
		var st := world.stats(wid) if world != null else MechCatalog.weapon(wid)
		var kind := str(st.get("kind", ""))
		var is_mortar := kind == "arc"
		if not bool(s["in_range"]):
			rack.set_enabled(slot_n, false)
			continue
		if is_mortar:
			if not bool(_profile["use_mortar"]):
				rack.set_enabled(slot_n, false)
				continue
			if target_hp < float(_profile["mortar_min_hp"]):
				rack.set_enabled(slot_n, false)
				continue
			# Mortar is strongest against static turrets, slow tanks, or targets behind cover.
			if has_los and _current_enemy.enemy_type == "strider" and profile_id != "rookie":
				rack.set_enabled(slot_n, false)
				continue
		else:
			if not has_los or bool(s["blocked"]) or friendly_blocked:
				rack.set_enabled(slot_n, false)
				continue
			# Don't waste direct-fire shots when the mech is facing far away from the target.
			if aim_angle_deg > 24.0:
				rack.set_enabled(slot_n, false)
				continue
			# Ammo discipline for limited-ammo salvo weapons (rockets, missiles).
			if int(s["ammo_max"]) > 0:
				if target_hp < float(_profile["ammo_save_min_hp"]):
					rack.set_enabled(slot_n, false)
					continue
				if wid == "rockets" and dist > float(_profile["rocket_max_range"]):
					rack.set_enabled(slot_n, false)
					continue
			# Respect barrel pivot alignment on high-heat / limited-ammo weapons.
			if wait_on_t and (int(s["ammo_max"]) > 0 or float(s["heat_per_shot"]) >= 8.0):
				if not bool(s["on_target"]) and aim_angle_deg > 10.0:
					rack.set_enabled(slot_n, false)
					continue
		eligible.append({"slot": slot_n, "weapon": wid, "heat": float(s["heat_per_shot"]), "ready": float(s["ready"]),
			"is_mortar": is_mortar, "damage": float(st.get("damage", 10.0))})

	# Second pass: heat discipline.
	var want_fire := false
	if _overheat_wait and not shed:
		for e: Dictionary in eligible:
			rack.set_enabled(int(e["slot"]), false)
	else:
		# Sort eligible slots by heat ascending so low-heat sustained weapons (AC/Gatling) stay on when running warm.
		eligible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["heat"]) < float(b["heat"]))
		var projected := cur_heat
		for e: Dictionary in eligible:
			var sn := int(e["slot"])
			var h_cost := float(e["heat"])
			var allow := true
			if _overheat_wait:
				# While cooling down from high heat, only keep very cool sustained weapons if well below cap.
				allow = shed and h_cost <= 2.0 and cur_heat < heat_cap * 0.78
			elif shed and projected + h_cost > heat_limit:
				allow = false
			rack.set_enabled(sn, allow)
			if allow:
				projected += h_cost
				want_fire = true

	rack.set_trigger(want_fire)


func _pick_aim_point(e: EnemyBase, mem: Dictionary, eye: Vector3, has_los: bool) -> Vector3:
	if not has_los:
		return mem.get("pos", _enemy_core_pos(e)) as Vector3
	var spheres := e.world_spheres()
	if spheres.is_empty():
		return _enemy_core_pos(e)
	var core_center: Vector3 = spheres[0]["center"]

	# Decide whether this profile goes for weak points / legs.
	var wp_prio := float(_profile["weak_point_priority"])
	if e.enemy_type == "strider" and float(_profile["prefer_legs_on_strider"]) > wp_prio:
		for s: Dictionary in spheres:
			if str(s["component"]) == "legs" and float(e.hp.get("legs", 0.0)) > 0.0:
				return s["center"] as Vector3

	if wp_prio > 0.01:
		var wp_id := ""
		match e.enemy_type:
			"turret": wp_id = "gun"
			"strider": wp_id = "sensor"
			"tank": wp_id = "vents"
		if wp_id != "" and float(e.hp.get(wp_id, 0.0)) > 0.0:
			var wp_center := _sphere_center(spheres, wp_id)
			if not is_nan(wp_center.x) and _wp_unoccluded(eye, wp_center, e, wp_id):
				# Deterministic per-target decision modulated by profile priority.
				var roll := fposmod(float(hash([bot_seed, e.target_id, int(_sim_t * 0.5)])) * 0.000001, 1.0)
				if wp_prio >= 0.85 or roll < wp_prio:
					return wp_center
		# For a tank seen from the front (vents occluded by hull), Veteran targets turret to strip Siege Cannon.
		if e.enemy_type == "tank" and wp_prio >= 0.75 and float(e.hp.get("turret", 0.0)) > 0.0:
			var tc := _sphere_center(spheres, "turret")
			if not is_nan(tc.x) and _wp_unoccluded(eye, tc, e, "turret"):
				return tc
	return core_center


## _component_unoccluded, reused for WP_REFRESH s per (enemy, component) (perf: a world.first_hit per frame per bot).
func _wp_unoccluded(eye: Vector3, pt: Vector3, e: EnemyBase, want_comp: String) -> bool:
	var key := e.target_id + "|" + want_comp
	var c: Variant = _wp_cache.get(key)
	if c != null and _sim_t < float((c as Array)[0]):
		return bool((c as Array)[1])
	var v := _component_unoccluded(eye, pt, e, want_comp)
	_wp_cache[key] = [_sim_t + WP_REFRESH, v]
	return v


## Verify a direct ray from `eye` to `pt` reaches `want_comp` on `e` first (not occluded by hull/walls).
func _component_unoccluded(eye: Vector3, pt: Vector3, e: EnemyBase, want_comp: String) -> bool:
	if world == null:
		return true
	var shooter_id := rack.shooter if rack != null else bot_id
	var dir := (pt - eye).normalized()
	var h := world.first_hit(eye, pt + dir * 2.0, 0.0, shooter_id)
	return not h.is_empty() and h.get("target") == e and str(h.get("component", "")) == want_comp


func _sphere_center(spheres: Array, comp_id: String) -> Vector3:
	for s: Dictionary in spheres:
		if str(s["component"]) == comp_id:
			return s["center"] as Vector3
	return Vector3(NAN, NAN, NAN)


func _slew_aim_toward(want: Vector3, dt: float, up: Vector3) -> void:
	if want.length_squared() < 1e-6:
		return
	var target_d := want.normalized()
	# Clamp pitch to ChaseCamera human bounds [-1.0, 0.55] rad.
	var sin_p := clampf(target_d.dot(up), sin(-1.0), sin(0.55))
	var flat := target_d - up * target_d.dot(up)
	if flat.length_squared() > 1e-6:
		target_d = (flat.normalized() * sqrt(maxf(1.0 - sin_p * sin_p, 0.0)) + up * sin_p).normalized()
	var max_step := deg_to_rad(float(_profile["aim_slew_deg_s"])) * dt
	var ang := _aim_dir.angle_to(target_d)
	if ang <= max_step or ang < 1e-5:
		_aim_dir = target_d
	else:
		var axis := _aim_dir.cross(target_d)
		if axis.length_squared() < 1e-8:
			axis = up
		_aim_dir = _aim_dir.rotated(axis.normalized(), max_step).normalized()


func _sync_camera(up: Vector3) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	var flat := _aim_dir - up * _aim_dir.dot(up)
	if flat.length_squared() > 1e-5:
		cam.look_dir = flat.normalized()
	cam.pitch = clampf(asin(clampf(_aim_dir.dot(up), -0.99, 0.99)), cam.pitch_min, cam.pitch_max)


func _dominant_projectile_speed() -> float:
	if rack == null:
		return 70.0
	var best_spd := 0.0
	for s: Dictionary in rack.slots():
		var wid := str(s["weapon"])
		if wid == "" or not bool(s["built"]) or int(s["ammo"]) == 0:
			continue
		var st := world.stats(wid) if world != null else MechCatalog.weapon(wid)
		var spd := float(st.get("speed", 0.0))
		if spd > 1.0 and (best_spd == 0.0 or spd < best_spd):
			best_spd = spd
	return best_spd if best_spd > 0.0 else 70.0


func _has_ready_mortar() -> bool:
	if rack == null:
		return false
	for s: Dictionary in rack.slots():
		if str(s["weapon"]) == "mortar" and bool(s["built"]) and str(s["hold"]) == "" and float(s["ready"]) >= 0.95:
			return true
	return false


func _min_core_hp_frac() -> float:
	if target == null:
		return 1.0
	var fracs := target.component_fractions()
	var lo := 1.0
	for c: String in PlayerTarget.CORE_COMPONENTS:
		if fracs.has(c):
			lo = minf(lo, float(fracs[c]))
	return lo


## Where the bot looks at an enemy: the first hit sphere whose component still has HP (a destroyed part, e.g. a broken
## turret gun, hides nothing), else the first sphere, else 3 m above its feet. world_spheres() may be empty with
## hit_shapes set (EnemyTrooper returns [] once dead), so the list is checked, not hit_shapes alone.
## (Engine edit 2026-11-22, self-reviewed 2026-11-23: empty-list guard added; callers only pass live, valid enemies.)
func _enemy_core_pos(e: EnemyBase) -> Vector3:
	var ws: Array = e.world_spheres() if e.hit_shapes.size() > 0 else []
	for s: Dictionary in ws:
		if float(e.hp.get(s["component"], 1.0)) > 0.0:
			return s["center"] as Vector3
	if not ws.is_empty():
		return (ws[0] as Dictionary)["center"] as Vector3
	return e.global_position + e.up * 3.0


func _sample_reaction() -> float:
	var base := float(_profile["reaction_s"])
	var jit := float(_profile["reaction_jitter_s"])
	return maxf(base + _rng.randf_range(-jit, jit), 0.05)


func _rand_normal() -> float:
	var u1 := maxf(_rng.randf(), 1e-6)
	var u2 := _rng.randf()
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


func debug_state() -> Dictionary:
	return {
		"state": ai_state,
		"profile": profile_id,
		"target_id": _current_enemy.target_id if _current_enemy != null and is_instance_valid(_current_enemy) else "",
		"aim": last_aim_world,
		"nav_goal": last_nav_goal,
		"dodge_dir": _dodge_dir if _dodge_left > 0.0 else Vector3.ZERO,
		"roof_goal": _active_roof.get("center_w", Vector3(NAN, NAN, NAN)),
		"stuck_recoveries": _nav.stuck_recoveries if _nav != null else 0,
		"dodges_attempted": dodges_attempted,
		"dodges_clean": dodges_clean,
		"memory_count": _memory.size(),
	}
