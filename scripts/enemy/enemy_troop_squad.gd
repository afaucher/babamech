class_name EnemyTroopSquad
extends EnemyBase
## Grouped 4-man Exo-Trooper fireteam as one EnemyBase entity (docs/design/enemy-troop-squads.md):
##   - Components "t0".."t3" represent the 4 individual troopers (28-30 HP each); squad is destroyed() only when ALL die.
##   - Individual world_spheres() at each alive trooper's live crouched/peeking slot -> precision snipes kill 1 trooper,
##     while explosive splash damages every alive trooper within blast radius.
##   - Anti-cluster awareness: prefers 4.0-6.0 m spacing along walls/parapets; splash hits or mech rush (< 28 m) trigger
##     immediate scatter, occluded corner displacement, or a 1.4 s jump-pack ascent onto adjacent standable roofs (<= 12 m).
##   - Host-only mech stomp: player mech moving/landing within 3.0 m horizontally (2.5 m vertically) crushes troopers underfoot.
##   - Phase 2 Drop Drone hook: deploy_from_air(landing_pos, deck) performs a 0.8 s jet-drop into nearest cover.
##   - Zero wire-format changes: EnemySync streams t0..t3 HP + puppet_aim (facing yaw, peek frac) automatically.

const TROOPER_IDS: Array[String] = ["t0", "t1", "t2", "t3"]
const TROOPER_HIT_R := 1.25
const STOMP_HORIZ_R := 3.0
const STOMP_VERT_R := 2.5
const STOMP_MIN_SPEED := 1.0
const RUSH_PANIC_DIST := 28.0
const JUMP_DURATION := 1.4
const JUMP_MAX_ROOF_H := 12.0
const JUMP_SEARCH_DIST := 14.0
const AIR_DROP_DURATION := 0.8
const COVER_QUERY_INTERVAL := 1.2
const DEFAULT_SPACING := 4.8
const MAX_SPACING := 6.0

# Visual nodes per trooper (LOCAL)
var _trooper_pivots: Dictionary = {}   ## cid -> Node3D
var _trooper_meshes: Dictionary = {}   ## cid -> MeshInstance3D
var _trooper_jets: Dictionary = {}     ## cid -> LowPolyFlame.Stream (active only during jump-pack / air-drop)
var _trooper_down: Dictionary = {}     ## cid -> bool (visual downed state)

# Squad tactical & formation state
var _spacing := DEFAULT_SPACING        ## m spacing between adjacent troopers (widens to 5.5-6.0 m on scatter)
var _edge_half_span := 8.5             ## m half-width of current cover wall / rooftop parapet
var _slot_offsets: Array[Vector3] = [] ## local (x, 0, z) offsets for t0..t3
var _facing_yaw := 0.0                 ## local yaw around up (streamed via puppet_aim.x)
var _peek_frac := 0.0                  ## 0 = crouched in cover, 1 = standing/leaning out (streamed via puppet_aim.y)
var _peeking_ids: Array[String] = []   ## troopers actively peeking & firing this volley
var _volley_idx := 0
var _shooter_cursor := 0
var _on_roof := false                  ## true for troop_roof or after jump-pack ascent
var _in_cover := false
var _cover_anchor := Vector3.ZERO
var _has_cover_anchor := false
var _cover_query_t := 0.0
var _scatter_cd := 0.0
var _displacing := false
var _displace_goal := Vector3.ZERO
var _displace_t := 0.0

# Jump-pack rooftop ascent state
var _jump_active := false
var _jump_t := 0.0
var _jump_start := Vector3.ZERO
var _jump_end := Vector3.ZERO
var _jump_roof_half_span := 6.0
var _jump_roof_yaw := 0.0
var _jump_count := 0                   ## telemetry / tests

# Phase 2 air-drop descent state
var _drop_active := false
var _drop_t := 0.0
var _drop_start := Vector3.ZERO
var _drop_end := Vector3.ZERO

# Telemetry & host stomp tracking
var _player_prev_pos: Dictionary = {}  ## target_id -> Vector3 (for non-PlayerTarget mock velocity in tests)
var _stomped_count := 0
var _scatter_count := 0
var _shots_fired_total := 0


func _init() -> void:
	super._init()
	enemy_type = "troop_squad"


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"_trooper_pivots": Net.LOCAL, "_trooper_meshes": Net.LOCAL, "_trooper_jets": Net.LOCAL,
		"_trooper_down": Net.LOCAL, "_spacing": Net.PRIVATE, "_edge_half_span": Net.SPAWN,
		"_slot_offsets": Net.PRIVATE, "_facing_yaw": Net.OWNER, "_peek_frac": Net.OWNER,
		"_peeking_ids": Net.PRIVATE, "_volley_idx": Net.PRIVATE, "_shooter_cursor": Net.PRIVATE,
		"_on_roof": Net.SPAWN, "_in_cover": Net.PRIVATE, "_cover_anchor": Net.PRIVATE,
		"_has_cover_anchor": Net.PRIVATE, "_cover_query_t": Net.PRIVATE, "_scatter_cd": Net.PRIVATE,
		"_displacing": Net.PRIVATE, "_displace_goal": Net.PRIVATE, "_displace_t": Net.PRIVATE,
		"_jump_active": Net.OWNER, "_jump_t": Net.PRIVATE, "_jump_start": Net.PRIVATE,
		"_jump_end": Net.PRIVATE, "_jump_roof_half_span": Net.PRIVATE, "_jump_roof_yaw": Net.PRIVATE, "_jump_count": Net.PRIVATE,
		"_drop_active": Net.OWNER, "_drop_t": Net.PRIVATE, "_drop_start": Net.PRIVATE,
		"_drop_end": Net.PRIVATE, "_player_prev_pos": Net.PRIVATE, "_stomped_count": Net.PRIVATE,
		"_scatter_count": Net.PRIVATE, "_shots_fired_total": Net.PRIVATE,
	})
	return f


func configure(type_id: String, id: String, w: CombatWorld, sq: Node = null, r: RingFrame = null,
		seed_val: int = 1, hp_mult: float = 1.0) -> void:
	super.configure(type_id, id, w, sq, r, seed_val, hp_mult)
	_on_roof = (type_id == "troop_roof")
	_edge_half_span = 8.5 if not _on_roof else 6.5
	_spacing = DEFAULT_SPACING
	_rebuild_slots()


func set_formation_spacing(spacing_m: float, half_span: float = -1.0) -> void:
	if half_span > 0.0:
		_edge_half_span = half_span
	_spacing = clampf(spacing_m, 1.2, MAX_SPACING)
	_rebuild_slots()
	_sync_trooper_transforms(0.0)


func _rebuild_slots() -> void:
	_slot_offsets.clear()
	var max_step := (_edge_half_span * 2.0) / 3.0 if _edge_half_span > 1.5 else 1.4
	var eff := minf(_spacing, max_step)
	var depths: Array[float] = [0.0, 0.35, -0.25, 0.20]
	for i in TROOPER_IDS.size():
		var x := (float(i) - 1.5) * eff
		var z := depths[i] if not _on_roof else 0.0
		_slot_offsets.append(Vector3(x, 0.0, z))
	_clamp_slots_to_clear_space()


## Pull any trooper slot that would clip inside a building wall, upper roof tier, or pillar cleanly toward the anchor.
func _clamp_slots_to_clear_space() -> void:
	if squad == null or ring == null or not is_inside_tree():
		return
	var p: CityPlan = squad.get("plan") as CityPlan
	if p == null:
		return
	var xf := global_transform
	for i in _slot_offsets.size():
		var base := _slot_offsets[i]
		var best := Vector3.ZERO
		for frac: float in [1.0, 0.7, 0.45, 0.22, 0.0]:
			var cand := Vector3(base.x * frac, 0.0, base.z * frac)
			var w_p := xf * cand
			var a := ring.world_to_arc(w_p)
			if EnemySpawner.clear_of_buildings(p, Vector2(a.x, a.y), 0.9, a.z + 0.25):
				best = cand
				break
		_slot_offsets[i] = best


func _trooper_mesh_name() -> String:
	return "trooper_at" if enemy_type == "troop_roof" else "trooper_rifle"


func _ready() -> void:
	super._ready()
	_rebuild_slots()
	_sync_trooper_transforms(0.0)


func _build_visuals() -> void:
	_trooper_pivots.clear()
	_trooper_meshes.clear()
	_trooper_down.clear()
	if _slot_offsets.is_empty():
		_rebuild_slots()
	var mname := _trooper_mesh_name()
	for i in TROOPER_IDS.size():
		var cid := TROOPER_IDS[i]
		var piv := Node3D.new()
		piv.name = "Trooper_%s" % cid
		piv.position = _slot_offsets[i]
		add_child(piv)
		var mi := EnemyMeshes.instance(mname)
		piv.add_child(mi)
		_trooper_pivots[cid] = piv
		_trooper_meshes[cid] = mi
		_trooper_down[cid] = false
		_register_comp_mesh(cid, mi)
	_sync_trooper_transforms(0.0)


func alive_troopers() -> Array[String]:
	var out: Array[String] = []
	for cid in TROOPER_IDS:
		if float(hp.get(cid, 0.0)) > 0.0:
			out.append(cid)
	return out


func alive_trooper_count() -> int:
	var n := 0
	for cid in TROOPER_IDS:
		if float(hp.get(cid, 0.0)) > 0.0:
			n += 1
	return n


func core_hp_ratio() -> float:
	var tot_max := 0.0
	for k: String in max_hp:
		tot_max += float(max_hp[k])
	if tot_max <= 0.001:
		return 0.0
	return clampf(total_hp() / tot_max, 0.0, 1.0)


## Live hit spheres ONLY for alive troopers at their current crouched / peeking world positions.
## Ordered with actively peeking & center troopers first so callers inspecting [0] target exposed shooters cleanly.
func world_spheres() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _dead:
		return out
	if _slot_offsets.is_empty():
		_rebuild_slots()
	var xf := global_transform if is_inside_tree() else transform
	var order: Array[int] = []
	for cid in _peeking_ids:
		var idx := TROOPER_IDS.find(cid)
		if idx >= 0 and not idx in order:
			order.append(idx)
	for idx in [1, 2, 0, 3]:
		if not idx in order:
			order.append(idx)
	for i in order:
		var cid := TROOPER_IDS[i]
		if float(hp.get(cid, 0.0)) <= 0.0:
			continue
		var lp := _trooper_local_pos(i, cid)
		var pf := _trooper_peek_amount(cid)
		var h_center := lerpf(1.20, 1.75, pf)
		out.append({
			"component": cid,
			"center": xf * (lp + Vector3(0.0, h_center, 0.0)),
			"radius": TROOPER_HIT_R,
		})
	return out


func _trooper_peek_amount(cid: String) -> float:
	if _jump_active or _drop_active or _displacing:
		return 1.0
	if puppet:
		return _peek_frac
	if _peeking_ids.is_empty():
		return _peek_frac if ai_state in [STATE_TELEGRAPH, STATE_FIRE] else 0.0
	return _peek_frac if cid in _peeking_ids else 0.0


func _trooper_local_pos(idx: int, cid: String) -> Vector3:
	var base := _slot_offsets[idx] if idx < _slot_offsets.size() else Vector3.ZERO
	var pf := _trooper_peek_amount(cid)
	# When peeking, lean forward along -Z past the cover edge (0.65 m on roof parapet so troopers stay on deck!).
	var max_lean := 0.65 if _on_roof else 1.35
	var lean_z := -max_lean * pf if (ai_state in [STATE_TELEGRAPH, STATE_FIRE] or (puppet and _peek_frac > 0.1)) else 0.0
	return base + Vector3(0.0, 0.0, lean_z)


func trooper_world_pos(cid: String) -> Vector3:
	var idx := TROOPER_IDS.find(cid)
	if idx < 0:
		return _world_pos()
	var xf := global_transform if is_inside_tree() else transform
	return xf * _trooper_local_pos(idx, cid)


func _trooper_muzzle_world(cid: String) -> Vector3:
	var idx := TROOPER_IDS.find(cid)
	if idx < 0:
		return eye_world()
	var xf := global_transform if is_inside_tree() else transform
	var lp := _trooper_local_pos(idx, cid)
	var m_off := Vector3(0.42, 1.88, -1.52) if enemy_type == "troop_roof" else Vector3(0.22, 1.42, -1.48)
	return xf * (lp + m_off)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	if not _peeking_ids.is_empty():
		var ci := clampi(_volley_idx, 0, _peeking_ids.size() - 1)
		var cid := _peeking_ids[ci]
		if float(hp.get(cid, 0.0)) > 0.0:
			return _trooper_muzzle_world(cid)
	var alive := alive_troopers()
	if not alive.is_empty():
		return _trooper_muzzle_world(alive[0])
	return eye_world()


func puppet_aim() -> Vector2:
	return Vector2(_facing_yaw, _peek_frac)


func set_puppet_aim(a: Vector2) -> void:
	_facing_yaw = a.x
	_peek_frac = clampf(a.y, 0.0, 1.0)


# --- Damage, Per-Trooper Splash Distribution & Clean Charred Downed Pose -----------------------------------

func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty() or _dead:
		return
	var c := component
	if c == "" or not hp.has(c) or float(hp[c]) <= 0.0:
		var alive := alive_troopers()
		if alive.is_empty():
			return
		c = alive[0]
	var before := float(hp[c])
	if before <= 0.0:
		return
	hp[c] = maxf(before - amount, 0.0)
	_trigger_hit_flash(c)
	damaged.emit(amount, c, src)
	var ratio := float(hp[c]) / maxf(float(max_hp.get(c, 1.0)), 0.001)
	component_damaged.emit(self, c, ratio, false)
	_emit_squad("component_damaged", {"id": target_id, "component": c, "hp_ratio": ratio, "weak_point": false, "pos": trooper_world_pos(c)})
	_on_damaged_alert(src)
	if before > 0.0 and float(hp[c]) <= 0.0:
		_on_component_broken(c, _comp_meta.get(c, {}))


func apply_hit(h: Hit) -> void:
	if _dead or h == null:
		return
	if h.impulse.length_squared() > 1e-6:
		_last_hit_dir = h.impulse.normalized()
	elif h.normal.length_squared() > 1e-6:
		_last_hit_dir = (-h.normal).normalized()
	var wst := world.stats(h.weapon) if (world != null and h.weapon != "") else {}
	var blast_r := float(wst.get("splash_radius", 0.0))
	var blast_dmg := float(wst.get("splash_damage", 0.0))
	var is_splash := (h.normal.length_squared() < 1e-6 and blast_r > 0.0) or h.component == ""
	if blast_r > 0.0:
		# Snapshot live trooper spheres before applying damage so one blast hits every clustered trooper inside radius!
		var snap := world_spheres()
		if is_splash:
			var hit_any := false
			for sp: Dictionary in snap:
				var cid := str(sp["component"])
				var d := maxf(h.point.distance_to(sp["center"] as Vector3) - float(sp["radius"]), 0.0)
				if d > blast_r:
					continue
				hit_any = true
				var dmg := h.damage if cid == h.component else maxf(blast_dmg, h.damage) * (1.0 - d / blast_r)
				apply_damage(dmg, cid, h.shooter)
			if not hit_any and h.damage > 0.0:
				apply_damage(h.damage, h.component, h.shooter)
		else:
			# Direct hit by an explosive weapon: direct trooper takes h.damage, nearby squadmates take blast falloff.
			apply_damage(h.damage, h.component, h.shooter)
			if blast_dmg > 0.0:
				for sp: Dictionary in snap:
					var cid := str(sp["component"])
					if cid == h.component or float(hp.get(cid, 0.0)) <= 0.0:
						continue
					var d := maxf(h.point.distance_to(sp["center"] as Vector3) - float(sp["radius"]), 0.0)
					if d <= blast_r:
						apply_damage(blast_dmg * (1.0 - d / blast_r), cid, h.shooter)
		if not _dead:
			_on_splash_panic(h.point)
	else:
		apply_damage(h.damage, h.component, h.shooter)
	if not _dead and h.heat > 0.0:
		apply_heat(h.heat, h.shooter)


func _on_component_broken(c: String, _meta: Dictionary) -> void:
	var tpos := trooper_world_pos(c)
	component_destroyed.emit(self, c, tpos)
	_emit_squad("component_destroyed", {"id": target_id, "component": c, "pos": tpos})
	_knock_down_trooper(c)
	if world != null:
		world.spawn_impact(tpos + up * 0.9, up, 1.35, EnemyMeshes.CHARRED, false)
	if c in _peeking_ids:
		_peeking_ids.erase(c)
		if _peeking_ids.is_empty() and ai_state in [STATE_TELEGRAPH, STATE_FIRE]:
			_cancel_telegraph("destroyed")
			_release_slot()
			ai_state = STATE_COOLDOWN
			_cooldown = 1.6
	if alive_trooper_count() <= 0:
		_kill("squad_wiped")


func _knock_down_trooper(cid: String) -> void:
	_trooper_down[cid] = true
	var piv: Node3D = _trooper_pivots.get(cid)
	var mi: MeshInstance3D = _trooper_meshes.get(cid)
	if piv != null and is_instance_valid(piv):
		var idx := maxi(TROOPER_IDS.find(cid), 0)
		var base := _slot_offsets[idx] if idx < _slot_offsets.size() else Vector3.ZERO
		piv.position = base + Vector3(0.0, 0.28, 0.0)
		piv.scale = Vector3.ONE
		piv.rotation = Vector3(-PI * 0.47, (float(idx) - 1.5) * 0.45, 0.0)
	if mi != null and is_instance_valid(mi):
		mi.visible = true
		mi.material_override = EnemyMeshes.charred_material()
		mi.material_overlay = null


func _on_destroyed_visual() -> void:
	for cid in TROOPER_IDS:
		_knock_down_trooper(cid)
	_stop_jump_jets()


func _wreck_flame_specs() -> Array[Dictionary]:
	# Small scorched-equipment flicker on squad wipe (clean stylized defeat, no big tank inferno).
	return [{
		"parent": self, "pos": Vector3(0.0, 0.4, 0.0), "dir": Vector3(0.04, 1.0, 0.02),
		"length": 1.6, "width": 0.45, "speed": 7.5, "count": 4, "root": 0.5, "duration": 4.0, "tag": "troop_wipe",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 0.35, 0.0)


func _core_rupture_scale() -> float:
	return 0.42


# --- Phase 2 Hook: Air Deployment -------------------------------------------------------------------------

## Phase 2 Drop Drone entry point: starts troopers in a 0.8 s controlled jet-drop descending onto `landing_pos`,
## fanning out into nearest cover on touchdown.
func deploy_from_air(landing_pos: Vector3, deck: int) -> void:
	spawn_deck = deck
	if ring != null:
		up = ring.up_at(landing_pos)
	_drop_end = landing_pos
	_drop_start = landing_pos + up * 11.0
	_drop_t = 0.0
	_drop_active = true
	ai_state = STATE_ALERT
	_alert_timer = 0.15
	if is_inside_tree():
		global_position = _drop_start
	else:
		position = _drop_start
	ground_y = _drop_start.dot(up)
	_start_jump_jets()


# --- AI State Machine: Stomp, Jump-Pack Ascent, Air-Drop, Cover-Peeking & Scatter --------------------------

func _update_dynamic_ground(pos: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	if _jump_active or _drop_active:
		ground_y = pos.dot(up)
		return
	super._update_dynamic_ground(pos, space)


func _step_ai(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if _cooldown > 0.0:
		_cooldown = maxf(_cooldown - dt, 0.0)
	if _scatter_cd > 0.0:
		_scatter_cd = maxf(_scatter_cd - dt, 0.0)
	if _relay_timer >= 0.0:
		_relay_timer -= dt
		if _relay_timer <= 0.0:
			_relay_timer = -1.0
			_fire_comms_relay()

	# Host-only mech stomp check (runs even if idle/staggered so walking over troopers always crushes them!).
	if not puppet and Net.is_host():
		_check_mech_stomp(dt)
		if _dead:
			return

	# Air-drop descent (Phase 2 Drop Drone deployment).
	if _drop_active:
		_step_air_drop(dt)
		return

	# Coordinated jump-pack rooftop ascent.
	if _jump_active:
		_step_jump_pack(dt)
		return

	if ai_mode == "idle":
		ai_state = STATE_IDLE
		_peek_frac = move_toward(_peek_frac, 0.0, dt * 4.0)
		_align_to_ring()
		return
	if ai_mode == "overheat" or heat.shutdown:
		if ai_mode == "overheat" and not heat.shutdown:
			heat.add(heat.cap)
		ai_state = STATE_OVERHEATED
		_peek_frac = move_toward(_peek_frac, 0.0, dt * 5.0)
		_align_to_ring()
		return
	if knock.staggered():
		ai_state = STATE_STAGGERED
		_peek_frac = move_toward(_peek_frac, 0.0, dt * 5.0)
		_align_to_ring()
		return

	var target := _acquire_target(space)
	if target == null:
		_has_los = false
		_no_los_time = 0.0
		_peeking_ids.clear()
		_peek_frac = move_toward(_peek_frac, 0.0, dt * 4.0)
		_cancel_telegraph("lost_los")
		_release_slot()
		var board_entry: Dictionary = _board_entry() if is_alerted() else {}
		if not board_entry.is_empty():
			_step_search(dt, board_entry["pos"] as Vector3, space)
		else:
			if ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK, STATE_COOLDOWN]:
				_emit_squad("alerted", {"id": target_id, "state": "lost", "pos": _world_pos()})
			_step_patrol(dt, space)
		return

	_target_id = target.target_id
	_last_target_ref = target
	var target_pos := Vector3.ZERO
	if _has_los:
		target_pos = _target_aim_center(target)
		_last_seen_pos = target_pos
		_update_target_velocity(target, target_pos, dt)
		_no_los_time = 0.0
		if _relayed and squad != null and squad.has_method("report_sighting"):
			squad.report_sighting(self, target, target_pos)
	else:
		var b_entry := _board_entry()
		target_pos = (b_entry["pos"] as Vector3) if not b_entry.is_empty() else _last_seen_pos
		_target_vel = Vector3.ZERO
		_has_prev_pos = false
		_no_los_time += dt
	_aim_point = target_pos

	if ai_state in [STATE_IDLE, STATE_PATROL]:
		_enter_alert(target, "spotted")
		return
	if ai_state == STATE_ALERT:
		_alert_timer -= dt
		_face_target(target_pos, dt)
		if _alert_timer <= 0.0:
			ai_state = STATE_ENGAGE
		return

	# Check mech rush panic (< 28 m) for street squads -> scatter or jump-pack onto low roof!
	var pos := _world_pos()
	var dist := pos.distance_to(target_pos)
	if not _on_roof and _scatter_cd <= 0.0 and dist < RUSH_PANIC_DIST and ai_mode == "live":
		_trigger_scatter_or_jump(target_pos, space)
		if _jump_active:
			return

	# Active telegraph wind-up: peeking troopers rise & lean out with bright muzzle glints.
	if ai_state == STATE_TELEGRAPH:
		_peek_frac = move_toward(_peek_frac, 1.0, dt * 6.0)
		_step_troop_telegraph(dt, target, target_pos)
		return

	# Active staggered single-shot volley (1 shot per peeking trooper).
	if ai_state == STATE_FIRE:
		_peek_frac = 1.0
		_step_troop_firing(dt)
		return

	# In cover / displacing / reloading: crouch back behind cover edge or parapet!
	_peek_frac = move_toward(_peek_frac, 0.0, dt * 5.0)
	_step_troop_movement(dt, target_pos, dist, space)
	_face_target(target_pos, dt)

	# When settled in cover (or on roof parapet) and cooldown ready, request attack slot to peek & fire!
	var w_id := _choose_troop_weapon(target_pos, dist)
	if w_id != "" and _cooldown <= 0.0 and not _displacing:
		if _request_slot(target.target_id):
			_begin_troop_telegraph(w_id, target_pos)


func _choose_troop_weapon(target_pos: Vector3, dist: float) -> String:
	var prim := str(_cfg.get("primary_weapon", ""))
	if prim == "" or alive_trooper_count() <= 0:
		return ""
	var pst := EnemyCatalog.weapon(prim)
	if dist > float(pst.get("range", 150.0)):
		return ""
	# A squad in corner cover or crouched behind a roof parapet can peek out to fire if either currently has LOS
	# OR its peeking eye position (+1.6 m up / 1.4 m lean-out) has clear LOS!
	if _has_los or _has_peek_los(target_pos):
		return prim
	return ""


func _has_peek_los(target_pos: Vector3) -> bool:
	if world == null or not world.use_physics:
		return true
	var sp := world.space()
	if sp == null:
		return true
	var xf := global_transform if is_inside_tree() else transform
	var peek_eye := xf * Vector3(0.0, 2.0, -1.4)
	return _check_los(peek_eye, target_pos, sp)


func _pick_peeking_shooters() -> Array[String]:
	var alive := alive_troopers()
	var want := mini(alive.size(), maxi(int(_cfg.get("max_shooters", 3)), 1))
	var out: Array[String] = []
	for i in want:
		var cid := alive[(_shooter_cursor + i) % alive.size()]
		out.append(cid)
	_shooter_cursor = (_shooter_cursor + 1) % maxi(alive.size(), 1)
	return out


func _begin_troop_telegraph(weapon_id: String, target_pos: Vector3) -> void:
	_peeking_ids = _pick_peeking_shooters()
	_volley_idx = 0
	if _peeking_ids.is_empty():
		_release_slot()
		return
	_begin_telegraph(weapon_id, target_pos)


func _step_troop_telegraph(dt: float, _target: CombatTarget, live_pos: Vector3) -> void:
	if _peeking_ids.is_empty():
		_cancel_telegraph("destroyed")
		_release_slot()
		ai_state = STATE_COOLDOWN
		return
	_telegraph_t += dt
	var st := EnemyCatalog.weapon(_active_weapon)
	var lock_share := float(st.get("lock_share", 0.5))
	if _telegraph_t < _telegraph_dur * lock_share:
		var rem := maxf(_telegraph_dur - _telegraph_t, 0.0)
		_locked_aim = _lead_aim_point(_active_weapon, live_pos, rem)
	_face_target(_locked_aim, dt)
	if _telegraph_t >= _telegraph_dur:
		ai_state = STATE_FIRE
		_burst_left = _peeking_ids.size()
		_volley_idx = 0
		_burst_timer = 0.0
		heat.add(float(st.get("self_heat", 6.0)))


func _step_troop_firing(dt: float) -> void:
	var st := EnemyCatalog.weapon(_active_weapon)
	_burst_timer -= dt
	if _burst_timer <= 0.0 and _burst_left > 0:
		if _volley_idx < _peeking_ids.size():
			var cid := _peeking_ids[_volley_idx]
			if float(hp.get(cid, 0.0)) > 0.0:
				_fire_trooper_round(cid, st)
		_volley_idx += 1
		_burst_left -= 1
		_burst_timer = float(st.get("burst_interval", 0.14))
	if _burst_left <= 0:
		_peeking_ids.clear()
		_cooldown = float(st.get("burst_cooldown", 3.2))
		_release_slot()
		ai_state = STATE_COOLDOWN if ai_mode == "live" else STATE_ENGAGE


func _fire_trooper_round(cid: String, st: Dictionary) -> void:
	if world == null or puppet or not Net.is_host():
		return
	var muz := _trooper_muzzle_world(cid)
	var aim := _locked_aim
	var extra_spread := float(st.get("spread", 1.4)) + aim_kick
	var rec := Combat.fire_record(target_id, 1, _active_weapon, _active_weapon, muz, aim, world.now, _shot_index, extra_spread)
	rec["enemy"] = true
	rec["team"] = team
	_shot_index += 1
	_shots_fired_total += 1
	world.fire(rec)
	weapon_fired.emit(self, _active_weapon, muz, aim)
	_emit_squad("weapon_fired", {"id": target_id, "weapon": _active_weapon, "pos": muz, "aim_point": aim})


# --- Cover Anchor, Anti-Cluster Scatter & Rooftop Jump-Pack Hop -------------------------------------------

func _step_troop_movement(dt: float, target_pos: Vector3, dist: float, space: PhysicsDirectSpaceState3D) -> void:
	if _on_roof or float(_cfg.get("move_speed", 0.0)) <= 0.0:
		_in_cover = true
		_align_to_ring()
		return
	var pos := _world_pos()
	var spd := float(_cfg.get("move_speed", 6.5)) * speed_scale * _speed_mult
	var flank_spd := float(_cfg.get("flank_speed", 8.2)) * speed_scale * _speed_mult
	if _displacing:
		_displace_t -= dt
		if _displace_t <= 0.0 or pos.distance_to(_displace_goal) < 4.5:
			_displacing = false
			_in_cover = true
			_has_cover_anchor = true
			_cover_anchor = pos
		else:
			ai_state = STATE_FLANK
			_move_along_cover_plan(_displace_goal, flank_spd, EnemyCatalog.engage_range(enemy_type), dt, space)
			return
	# Periodically seek a nearby occluded building corner if not yet settled in cover.
	_cover_query_t -= dt
	if not _has_cover_anchor and _cover_query_t <= 0.0:
		_cover_query_t = COVER_QUERY_INTERVAL
		var anchor := _find_corner_cover(pos, target_pos)
		if not is_nan(anchor.x):
			_cover_anchor = anchor
			_has_cover_anchor = true
	if _has_cover_anchor and pos.distance_to(_cover_anchor) > 4.0:
		_in_cover = false
		ai_state = STATE_FLANK
		_steer_toward(_cover_anchor, spd, dt, space)
		return
	if dist > EnemyCatalog.engage_range(enemy_type) or (not _has_los and not _has_peek_los(target_pos)):
		_in_cover = false
		_has_cover_anchor = false
		ai_state = STATE_FLANK
		_move_along_cover_plan(target_pos, flank_spd, EnemyCatalog.engage_range(enemy_type), dt, space)
		return
	if not _in_cover:
		_in_cover = true
		_rebuild_slots()
	ai_state = STATE_ENGAGE if _cooldown <= 0.0 else STATE_COOLDOWN
	_align_to_ring()


func _find_corner_cover(pos: Vector3, threat_pos: Vector3) -> Vector3:
	if squad == null or not squad.has_method("deck_occluders"):
		return Vector3(NAN, NAN, NAN)
	var occs: Array = squad.deck_occluders(spawn_deck)
	if occs.is_empty():
		return Vector3(NAN, NAN, NAN)
	var my_arc := _world_to_arc2(pos)
	var th_arc := _world_to_arc2(threat_pos)
	var best_arc := Vector2(NAN, NAN)
	var best_score := INF
	for item: Dictionary in occs:
		var r: Rect2 = item["rect"]
		if r.get_center().distance_to(my_arc) > 65.0:
			continue
		var corners: Array[Vector2] = [
			Vector2(r.position.x - 2.4, r.position.y - 2.4),
			Vector2(r.end.x + 2.4, r.position.y - 2.4),
			Vector2(r.position.x - 2.4, r.end.y + 2.4),
			Vector2(r.end.x + 2.4, r.end.y + 2.4),
		]
		for c_pt in corners:
			var d_me := my_arc.distance_to(c_pt)
			if d_me > 52.0:
				continue
			if c_pt.distance_to(th_arc) < RUSH_PANIC_DIST:
				continue
			if not squad.arc_segment_occluded(c_pt, th_arc, spawn_deck):
				continue
			# Check that leaning 3.5 m sideways out of this corner exposes a firing sightline!
			var to_th := (th_arc - c_pt).normalized()
			var side := Vector2(-to_th.y, to_th.x)
			var peek_open: bool = (not bool(squad.arc_segment_occluded(c_pt + side * 3.5, th_arc, spawn_deck))) \
				or (not bool(squad.arc_segment_occluded(c_pt - side * 3.5, th_arc, spawn_deck)))
			var score := d_me + (0.0 if peek_open else 22.0)
			if score < best_score:
				best_score = score
				best_arc = c_pt
	if is_nan(best_arc.x):
		return Vector3(NAN, NAN, NAN)
	return _arc_to_world_pos(best_arc)


func _on_splash_panic(blast_pos: Vector3) -> void:
	if _dead or puppet or not Net.is_host():
		return
	# Widen anti-cluster spacing immediately for surviving troopers!
	_spacing = minf(MAX_SPACING, maxf(_spacing + 1.4, 5.2))
	_rebuild_slots()
	_scatter_count += 1
	if _on_roof:
		_sync_trooper_transforms(0.0)
		return
	if _scatter_cd <= 0.0:
		_trigger_scatter_or_jump(blast_pos, world.space() if world != null else null)


func _trigger_scatter_or_jump(threat_pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	_scatter_cd = 5.5
	_scatter_count += 1
	_spacing = minf(MAX_SPACING, maxf(_spacing + 1.0, 5.4))
	_rebuild_slots()
	if ai_state == STATE_TELEGRAPH:
		_cancel_telegraph("scatter")
		_release_slot()
	# 1. Try jump-pack ascent onto an adjacent standable low/mid roof (<= 12 m, kind != "plant")!
	var roof := _find_jumpable_roof(_world_pos(), threat_pos)
	if not roof.is_empty():
		_start_jump_pack(roof["pos"] as Vector3, float(roof["half_span"]), float(roof["yaw"]))
		return
	# 2. Otherwise displace away from threat toward the next occluded cover corner.
	var pos := _world_pos()
	var away := pos - threat_pos
	away -= up * away.dot(up)
	var dir := away.normalized() if away.length_squared() > 1e-4 else (-global_basis.z if is_inside_tree() else Vector3.FORWARD)
	var want := pos + dir * 26.0
	var corner := _find_corner_cover(want, threat_pos)
	_displace_goal = corner if not is_nan(corner.x) else want
	_displacing = true
	_displace_t = 4.2
	_has_cover_anchor = false
	_in_cover = false
	ai_state = STATE_FLANK


func _find_jumpable_roof(pos: Vector3, threat_pos: Vector3) -> Dictionary:
	if _on_roof or squad == null:
		return {}
	var p: CityPlan = squad.get("plan") as CityPlan
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
			if minf(sz.x, sz.y) < 6.0:
				continue
			var off: Vector2 = t["off"]
			var tc := bc + off
			var half := sz * 0.5
			# Distance from squad to building tier footprint perimeter in 2D arc space.
			var clamped := Vector2(clampf(my_arc.x, tc.x - half.x, tc.x + half.x), clampf(my_arc.y, tc.y - half.y, tc.y + half.y))
			var edge_d := my_arc.distance_to(clamped)
			if edge_d > best_d:
				continue
			# Pick the roof parapet position facing threat_pos, 0.9 m inset from the lip!
			var to_th := th_arc - tc
			var land_off := off
			var span := half.x - 1.2
			var ryaw := 0.0
			if absf(to_th.x) >= absf(to_th.y):
				var sx := 1.0 if to_th.x >= 0.0 else -1.0
				land_off.x += sx * maxf(half.x - 0.9, 0.4)
				ryaw = -PI * 0.5 if sx > 0.0 else PI * 0.5
				span = maxf(half.y - 1.2, 2.0)
			else:
				var sy := 1.0 if to_th.y >= 0.0 else -1.0
				land_off.y += sy * maxf(half.y - 0.9, 0.4)
				ryaw = 0.0 if sy > 0.0 else PI
				span = maxf(half.x - 1.2, 2.0)
			var land_arc := bc + land_off
			if not EnemySpawner.clear_of_buildings(p, land_arc, EnemySpawner.TROOP_CLEAR, y1 + CityPlan.CURB_H + 0.2):
				continue
			var bxf := Transform3D(CityGeo.frame_basis(ring, bc.y), ring.arc_to_world(bc.x, bc.y, CityPlan.CURB_H))
			var land_w := bxf * Vector3(land_off.x, y1, land_off.y)
			best_d = edge_d
			best = {"pos": land_w, "half_span": span, "yaw": ryaw}
	return best


func _start_jump_pack(dest_w: Vector3, roof_half_span: float, roof_yaw: float = 0.0) -> void:
	_jump_start = _world_pos()
	_jump_end = dest_w
	_jump_roof_half_span = clampf(roof_half_span, 2.5, 9.0)
	_jump_roof_yaw = roof_yaw
	_jump_t = 0.0
	_jump_active = true
	_jump_count += 1
	_displacing = false
	ai_state = STATE_FLANK
	_start_jump_jets()


func _step_jump_pack(dt: float) -> void:
	_jump_t += dt
	var u := clampf(_jump_t / JUMP_DURATION, 0.0, 1.0)
	var arc_lift := sin(u * PI) * 4.2
	var p := _jump_start.lerp(_jump_end, u) + up * arc_lift
	if ring != null:
		up = ring.up_at(p)
	ground_y = p.dot(up)
	if is_inside_tree():
		global_position = p
	else:
		position = p
	_align_to_ring()
	_tick_jump_jets(dt)
	move_speed_ratio = 1.0
	if u >= 1.0:
		_jump_active = false
		_on_roof = true
		_in_cover = true
		_edge_half_span = _jump_roof_half_span
		if ring != null and is_inside_tree():
			var a := ring.world_to_arc(p)
			var base_b := ring.basis_at_arc(a.y)
			global_basis = Basis(base_b.y, _jump_roof_yaw) * base_b
			_facing_yaw = 0.0
		_rebuild_slots()
		_stop_jump_jets()
		ai_state = STATE_ENGAGE


func _step_air_drop(dt: float) -> void:
	_drop_t += dt
	var u := clampf(_drop_t / AIR_DROP_DURATION, 0.0, 1.0)
	# Smooth ease-out landing deceleration.
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
	_tick_jump_jets(dt)
	move_speed_ratio = 1.0 - ease_u
	if u >= 1.0:
		_drop_active = false
		_stop_jump_jets()
		_has_cover_anchor = false
		_cover_query_t = 0.0
		ai_state = STATE_ENGAGE


func _start_jump_jets() -> void:
	_stop_jump_jets()
	for cid in alive_troopers():
		var piv: Node3D = _trooper_pivots.get(cid)
		if piv == null or not is_instance_valid(piv):
			continue
		var st := LowPolyFlame.Stream.new()
		st.name = "JumpJet_%s" % cid
		st.position = Vector3(0.0, 0.95, 0.42)
		st.length = 1.6
		st.width = 0.32
		st.speed = 9.0
		st.count = 4
		st.spread = 0.14
		st.root = 0.45
		st.jitter_seed = hash([target_id, cid, _jump_count])
		st.manual = true
		st.emitting = true
		piv.add_child(st)
		st.rebuild()
		_trooper_jets[cid] = st


func _tick_jump_jets(dt: float) -> void:
	for st: LowPolyFlame.Stream in _trooper_jets.values():
		if is_instance_valid(st):
			st.advance(dt)


func _stop_jump_jets() -> void:
	for st: LowPolyFlame.Stream in _trooper_jets.values():
		if is_instance_valid(st):
			st.queue_free()
	_trooper_jets.clear()


# --- Host-Only Mech Stomp ---------------------------------------------------------------------------------

func _check_mech_stomp(dt: float) -> void:
	if world == null or _jump_active or _drop_active:
		return
	var stomped_any := false
	var stomp_origin := Vector3.ZERO
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or not t.is_hittable():
			continue
		var tp := t.global_position if t.is_inside_tree() else t.position
		var vel := Vector3.ZERO
		if t is PlayerTarget and (t as PlayerTarget).mech != null:
			vel = (t as PlayerTarget).mech.velocity
		elif _player_prev_pos.has(t.target_id) and dt > 1e-5:
			vel = (tp - (_player_prev_pos[t.target_id] as Vector3)) / dt
		_player_prev_pos[t.target_id] = tp
		var moving := vel.length() > STOMP_MIN_SPEED or vel.dot(up) < -0.5
		if not moving:
			continue
		for cid in alive_troopers():
			var tr_p := trooper_world_pos(cid)
			var diff := tr_p - tp
			var vert := absf(diff.dot(up))
			var horiz := (diff - up * diff.dot(up)).length()
			if horiz <= STOMP_HORIZ_R and vert <= STOMP_VERT_R:
				apply_damage(999.0, cid, t.target_id)
				_stomped_count += 1
				stomped_any = true
				stomp_origin = tp
	if stomped_any and not _dead:
		_on_splash_panic(stomp_origin)


# --- Facing & Visual Sync ---------------------------------------------------------------------------------

func _face_target(target_pos: Vector3, dt: float) -> void:
	if not is_inside_tree():
		return
	var to_t := target_pos - global_position
	to_t -= up * to_t.dot(up)
	if to_t.length_squared() < 1e-4:
		return
	var want_f := to_t.normalized()
	var cur_f := (-global_basis.z)
	cur_f = (cur_f - up * cur_f.dot(up)).normalized()
	if cur_f.length_squared() < 1e-6:
		cur_f = want_f
	var max_turn := float(_cfg.get("turn_rate", 4.0)) * dt
	var ang := cur_f.signed_angle_to(want_f, up)
	if _on_roof:
		# Keep the 4-trooper parapet line anchored on the roof edge; turn each individual trooper toward the target!
		var step_a := clampf(ang - _facing_yaw, -max_turn, max_turn)
		_facing_yaw = wrapf(_facing_yaw + step_a, -PI, PI)
		turret_slew_speed = absf(step_a) / maxf(dt, 1e-4)
		return
	var new_f := cur_f.rotated(up, clampf(ang, -max_turn, max_turn)).normalized()
	global_basis = Basis(new_f.cross(up).normalized(), up, -new_f)
	_facing_yaw = 0.0
	turret_slew_speed = absf(ang) / maxf(dt, 1e-4)


func _update_visuals(dt: float) -> void:
	_sync_trooper_transforms(dt)
	super._update_visuals(dt)


func _sync_trooper_transforms(dt: float) -> void:
	for i in TROOPER_IDS.size():
		var cid := TROOPER_IDS[i]
		var alive := float(hp.get(cid, 0.0)) > 0.0
		if not alive:
			if not bool(_trooper_down.get(cid, false)):
				_knock_down_trooper(cid)
			continue
		var piv: Node3D = _trooper_pivots.get(cid)
		if piv == null or not is_instance_valid(piv):
			continue
		var lp := _trooper_local_pos(i, cid)
		var pf := _trooper_peek_amount(cid)
		if dt > 0.0:
			piv.position = piv.position.lerp(lp, clampf(dt * 12.0, 0.0, 1.0))
		else:
			piv.position = lp
		piv.rotation = Vector3(0.0, _facing_yaw if _on_roof else 0.0, 0.0)
		# Crouched behind cover/parapet (0.58 scale Y) vs upright/leaning out to fire (1.0 scale Y).
		piv.scale = Vector3(1.0, lerpf(0.58, 1.0, pf), 1.0)


func puppet_apply(st: Dictionary) -> void:
	super.puppet_apply(st)
	for cid in TROOPER_IDS:
		if float(hp.get(cid, 0.0)) <= 0.0 and not bool(_trooper_down.get(cid, false)):
			_knock_down_trooper(cid)


func debug_info() -> Dictionary:
	var d := super.debug_info()
	d["alive_troopers"] = alive_trooper_count()
	d["spacing"] = _spacing
	d["peek_frac"] = _peek_frac
	d["on_roof"] = _on_roof
	d["in_cover"] = _in_cover
	d["jump_count"] = _jump_count
	d["stomped_count"] = _stomped_count
	d["scatter_count"] = _scatter_count
	return d


func _on_reset_visual() -> void:
	_trooper_down.clear()
	_peeking_ids.clear()
	_peek_frac = 0.0
	_jump_active = false
	_drop_active = false
	_displacing = false
	_has_cover_anchor = false
	_in_cover = false
	_spacing = DEFAULT_SPACING
	_on_roof = (enemy_type == "troop_roof")
	_stomped_count = 0
	_scatter_count = 0
	_jump_count = 0
	_shots_fired_total = 0
	_stop_jump_jets()
	_rebuild_slots()
	for cid in TROOPER_IDS:
		_trooper_down[cid] = false
	_sync_trooper_transforms(0.0)
