class_name EnemyDropDrone
extends EnemyBase
## Armored Carrier Drop Ship ("dropship", docs/design/enemy-troop-squads.md §6):
##   - Unarmed troop transport called in by a Scout Drone beacon (strictly capped per deck so MissionRules never soft-locks).
##   - Lean curved-deck flight interpolation (zero per-frame physics raycasts or A* calls for < 4 ms AI budget):
##       APPROACH (19-21 m up, 18 m/s) -> DESCEND (to drop_y + 11 m) -> DROP_TELEGRAPH (1.5 s, pulsing ventral bay +
##       drop-zone ring; shooting it down destroys the carried squad mid-air with 0 troopers spawned!) ->
##       DEPLOY (spawns a variable-sized fireteam of 3-5 individual EnemyTrooper units via squad.add_enemy +
##       staggered deploy_from_air) -> EXFIL (climbs to 28 m & despawns).
##   - Self-contained cached strictly watertight placeholder meshes ("dropship_hull", "dropship_rotors", "dropship_bay")
##     that automatically defer to EnemyMeshes.instance(part) once Enemy Art Direction adds them.

signal troops_deployed(dropship: EnemyDropDrone, deployed_troopers: Array)

const PHASE_APPROACH := "approach"
const PHASE_DESCEND := "descend"
const PHASE_TELEGRAPH := "telegraph"
const PHASE_EXFIL := "exfil"
const PHASE_DONE := "done"

const DROP_WEAPON := "enemy_dropship_bay"
const DROP_TELEGRAPH_DUR := 1.5
const CRUISE_ALT := 20.0
const DROP_HOVER_OFFSET := 11.0
const EXFIL_ALT := 28.0
const APPROACH_SPEED := 18.0
const DESCEND_SPEED := 10.5
const EXFIL_SPEED := 16.0
const EXFIL_MAX_TIME := 4.5

static var _placeholder_cache: Dictionary = {}

var _drop_phase := PHASE_APPROACH
var _drop_pos := Vector3.ZERO
var _drop_is_roof := false
var _drop_half_span := 6.0
var _exfil_pos := Vector3.ZERO
var _exfil_t := 0.0
var _deployed := false
var _deploy_seq := 0
var _pitch_anim := 0.0
var _bay_open := 0.0
var _hover_t := 0.0

var _body_pivot: Node3D
var _hull_mi: MeshInstance3D
var _rotors_mi: MeshInstance3D
var _bay_mi: MeshInstance3D


func _init() -> void:
	super._init()
	enemy_type = "dropship"


func _is_aerial_wreck() -> bool:
	return true


func _wreck_ground_radius() -> float:
	return 1.35


func _wreck_body_pivot() -> Node3D:
	return _body_pivot


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({
		"_drop_phase": Net.PRIVATE, "_drop_pos": Net.SPAWN, "_drop_is_roof": Net.SPAWN,
		"_drop_half_span": Net.SPAWN, "_exfil_pos": Net.SPAWN, "_exfil_t": Net.PRIVATE,
		"_deployed": Net.OWNER, "_deploy_seq": Net.PRIVATE, "_pitch_anim": Net.OWNER,
		"_bay_open": Net.OWNER, "_hover_t": Net.LOCAL,
		"_body_pivot": Net.LOCAL, "_hull_mi": Net.LOCAL, "_rotors_mi": Net.LOCAL, "_bay_mi": Net.LOCAL,
	})
	return f


func configure_drop(drop_pos: Vector3, drop_is_roof: bool, drop_half_span: float, exfil_pos: Vector3) -> void:
	_drop_pos = drop_pos
	_drop_is_roof = drop_is_roof
	_drop_half_span = clampf(drop_half_span, 2.2, 8.5)
	_exfil_pos = exfil_pos
	_drop_phase = PHASE_APPROACH
	_deployed = false
	_exfil_t = 0.0
	_locked_aim = drop_pos


# --- Art-Direction Mesh Deferral + Self-Contained Watertight Placeholders ---------------------------------

## True once EnemyMeshes provides a real art-direction mesh for `part` (not its 1x1x1 36-vertex fallback box).
static func has_art_mesh(part: String) -> bool:
	var m := EnemyMeshes.mesh(part)
	if m == null or m.get_surface_count() == 0:
		return false
	var aabb := m.get_aabb()
	var arrays := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if not arrays.is_empty() else PackedVector3Array()
	return verts.size() > 36 or aabb.size.length() > 2.2


## Cached, strictly watertight placeholder meshes matching the exact Drop Ship geometry contract (5.2 W x 2.8 H x 6.8 L).
static func placeholder_mesh(part: String) -> ArrayMesh:
	if _placeholder_cache.has(part):
		return _placeholder_cache[part] as ArrayMesh
	var k := MeshKit.new()
	match part:
		"dropship_hull": _build_hull_mesh(k)
		"dropship_rotors": _build_rotors_mesh(k)
		"dropship_bay": _build_bay_mesh(k)
		_:
			k.box(Vector3.ONE, EnemyMeshes.ARMOR_DARK)
	var m := k.commit(MechMeshes.materials())
	_placeholder_cache[part] = m
	return m


static func _build_hull_mesh(k: MeshKit) -> void:
	# Heavy armored twin-boom troop carrier fuselage: X [-1.4, 1.4], Y [-0.9, 1.1], Z [-3.4, 3.2].
	k.box(Vector3(2.40, 1.55, 4.40), EnemyMeshes.ARMOR_DARK, Vector3(0.0, 0.15, -0.10))
	k.box(Vector3(2.60, 0.36, 3.20), EnemyMeshes.ARMOR_PLATE, Vector3(0.0, 0.88, -0.20))
	k.box(Vector3(1.90, 0.22, 4.10), EnemyMeshes.TRIM_RED, Vector3(0.0, 1.02, -0.10))
	# Forward armored nose cockpit extending to Z = -3.4 m with glowing crimson visor strip.
	k.box(Vector3(1.85, 1.05, 1.50), EnemyMeshes.ARMOR_DARK, Vector3(0.0, -0.05, -2.65))
	k.glow = true
	k.box(Vector3(1.50, 0.28, 0.20), EnemyMeshes.OPTIC_GLOW, Vector3(0.0, 0.12, -3.38))
	k.glow = false
	# Twin heavy rear tail booms extending to Z = +3.2 m + rear dorsal stabilizer bridge.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.56, 0.72, 1.65), EnemyMeshes.ARMOR_PLATE, Vector3(side * 1.02, 0.45, 2.38))
		k.box(Vector3(0.24, 0.82, 0.95), EnemyMeshes.TRIM_RED, Vector3(side * 1.12, 0.76, 2.70))
	k.box(Vector3(2.20, 0.20, 0.75), EnemyMeshes.ARMOR_DARK, Vector3(0.0, 0.96, 2.82))
	# Cross-spar supporting the twin ducted VTOL rotor pods.
	k.box(Vector3(3.60, 0.36, 1.10), EnemyMeshes.STEEL, Vector3(0.0, 0.52, 0.0))


static func _build_rotors_mesh(k: MeshKit) -> void:
	# Twin heavy ducted VTOL rotor pods at X = +/-2.2, Y = +0.55, Z = 0.0 (critical weak point!).
	for side: float in [-1.0, 1.0]:
		var rx := side * 2.2
		k.box(Vector3(1.25, 0.72, 2.20), EnemyMeshes.ARMOR_PLATE, Vector3(rx, 0.55, 0.0))
		k.box(Vector3(1.32, 0.22, 1.60), EnemyMeshes.TRIM_RED, Vector3(rx, 0.88, 0.0))
		k.tube(Vector3(rx, 0.15, 0.0), Vector3(rx, 0.98, 0.0), 0.52, 8, EnemyMeshes.STEEL)
		k.glow = true
		k.box(Vector3(0.76, 0.16, 1.35), EnemyMeshes.VENT_GLOW, Vector3(rx, 0.12, 0.0))
		k.box(Vector3(0.72, 0.14, 1.15), EnemyMeshes.VENT_GLOW, Vector3(rx, 0.96, 0.0))
		k.glow = false


static func _build_bay_mesh(k: MeshKit) -> void:
	# Ventral armored troop bay at X [-1.1, 1.1], Y [-1.25, -0.55], Z [-1.2, 1.4].
	k.box(Vector3(2.15, 0.68, 2.55), EnemyMeshes.ARMOR_DARK, Vector3(0.0, -0.90, 0.10))
	k.box(Vector3(1.85, 0.18, 2.20), EnemyMeshes.STEEL, Vector3(0.0, -1.18, 0.10))
	k.glow = true
	k.box(Vector3(1.40, 0.10, 1.60), EnemyMeshes.VENT_GLOW, Vector3(0.0, -1.24, 0.10))
	k.glow = false


static func _make_part_instance(part: String) -> MeshInstance3D:
	if has_art_mesh(part):
		return EnemyMeshes.instance(part)
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = placeholder_mesh(part)
	return mi


func _build_visuals() -> void:
	_body_pivot = Node3D.new()
	_body_pivot.name = "BodyPivot"
	add_child(_body_pivot)
	_hull_mi = _make_part_instance("dropship_hull")
	_body_pivot.add_child(_hull_mi)
	_register_comp_mesh("hull", _hull_mi)
	_rotors_mi = _make_part_instance("dropship_rotors")
	_body_pivot.add_child(_rotors_mi)
	_register_comp_mesh("rotors", _rotors_mi)
	_bay_mi = _make_part_instance("dropship_bay")
	_body_pivot.add_child(_bay_mi)
	_register_comp_mesh("hull", _bay_mi)


func muzzle_world(_weapon_id: String = "") -> Vector3:
	if _body_pivot != null and _body_pivot.is_inside_tree():
		return _body_pivot.global_transform * Vector3(0.0, -1.2, 0.1)
	return _world_pos() - up * 1.2


func puppet_aim() -> Vector2:
	return Vector2(_pitch_anim, _bay_open)


func set_puppet_aim(a: Vector2) -> void:
	_pitch_anim = a.x
	_bay_open = clampf(a.y, 0.0, 1.0)


func _update_dynamic_ground(pos: Vector3, _space: PhysicsDirectSpaceState3D) -> void:
	ground_y = pos.dot(up)


## Unarmed troop carrier: never fires weapons!
func _choose_weapon(_target_pos: Vector3) -> String:
	return ""


func _fire_one_round(_st: Dictionary) -> void:
	pass


# --- Lean Flight State Machine (Approach -> Descend -> 1.5 s Telegraph -> Deploy -> Exfil & Despawn) ------

func _step_ai(dt: float, _space: PhysicsDirectSpaceState3D) -> void:
	move_speed_ratio = 0.0
	turret_slew_speed = 0.0
	if knock.moving():
		knock.velocity = knock.velocity.move_toward(Vector3.ZERO, 10.0 * dt)

	if ai_mode == "idle":
		ai_state = STATE_IDLE
		_pitch_anim = move_toward(_pitch_anim, 0.0, dt * 3.0)
		_bay_open = move_toward(_bay_open, 0.0, dt * 3.0)
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
		_align_to_ring()
		return

	# If not configured with a drop zone (e.g., EnemyLab preset), default to hovering directly below spawn.
	if _drop_pos == Vector3.ZERO and _exfil_pos == Vector3.ZERO and _drop_phase == PHASE_APPROACH:
		var p0 := _world_pos()
		var floor_p := p0 - up * (ring.height(p0) if ring != null else p0.y)
		_drop_pos = floor_p
		_exfil_pos = p0 + (-global_basis.z if is_inside_tree() else Vector3.FORWARD) * 80.0 + up * 10.0

	match _drop_phase:
		PHASE_APPROACH:
			ai_state = STATE_FLANK
			_bay_open = move_toward(_bay_open, 0.0, dt * 3.0)
			var hover_top := _drop_pos + up * maxf(CRUISE_ALT - _drop_height(), DROP_HOVER_OFFSET + 4.0)
			var arrived := _step_fly_to(hover_top, APPROACH_SPEED * speed_scale, dt, true)
			if arrived:
				_drop_phase = PHASE_DESCEND
		PHASE_DESCEND:
			ai_state = STATE_ENGAGE
			_bay_open = move_toward(_bay_open, 0.35, dt * 2.5)
			var hover_drop := _drop_pos + up * DROP_HOVER_OFFSET
			var arrived := _step_fly_to(hover_drop, DESCEND_SPEED * speed_scale, dt, false)
			if arrived:
				_begin_drop_telegraph()
		PHASE_TELEGRAPH:
			_pitch_anim = move_toward(_pitch_anim, 0.0, dt * 4.0)
			_bay_open = move_toward(_bay_open, 1.0, dt * 2.5)
			_telegraph_t += dt
			_align_to_ring()
			if _telegraph_t >= _telegraph_dur:
				_deploy_carried_squad()
				_drop_phase = PHASE_EXFIL
				_exfil_t = 0.0
				ai_state = STATE_FLANK
		PHASE_EXFIL:
			ai_state = STATE_FLANK
			_bay_open = move_toward(_bay_open, 0.0, dt * 3.0)
			_exfil_t += dt
			var exfil_goal := _exfil_target_world()
			var done := _step_fly_to(exfil_goal, EXFIL_SPEED * speed_scale, dt, true)
			if done or _exfil_t >= EXFIL_MAX_TIME:
				_finish_exfil()


func _drop_height() -> float:
	if ring != null:
		return ring.height(_drop_pos)
	return _drop_pos.y


func _exfil_target_world() -> Vector3:
	if ring != null:
		var a := ring.world_to_arc(_exfil_pos)
		return ring.arc_to_world(a.x, a.y, EXFIL_ALT)
	return Vector3(_exfil_pos.x, EXFIL_ALT, _exfil_pos.z)


func _step_fly_to(goal_w: Vector3, spd: float, dt: float, tilt_forward: bool) -> bool:
	var pos := _world_pos()
	var diff := goal_w - pos
	var dist := diff.length()
	if dist <= 1.2:
		if is_inside_tree():
			global_position = goal_w
		else:
			position = goal_w
		if ring != null:
			up = ring.up_at(goal_w)
		ground_y = goal_w.dot(up)
		_pitch_anim = move_toward(_pitch_anim, 0.0, dt * 4.0)
		_align_to_ring()
		return true
	var step_d := minf(spd * dt, dist)
	var next_pos := pos + (diff / dist) * step_d
	if ring != null:
		up = ring.up_at(next_pos)
		var nh := clampf(ring.height(next_pos), 6.0, 34.0)
		var a3 := ring.world_to_arc(next_pos)
		next_pos = ring.arc_to_world(a3.x, a3.y, nh)
	ground_y = next_pos.dot(up)
	var horiz := diff - up * diff.dot(up)
	if horiz.length_squared() > 0.25 and is_inside_tree():
		var want_f := horiz.normalized()
		var cur_f := (-global_basis.z)
		cur_f = (cur_f - up * cur_f.dot(up)).normalized()
		if cur_f.length_squared() < 1e-6:
			cur_f = want_f
		var max_turn := float(_cfg.get("turn_rate", 1.8)) * dt
		var ang := cur_f.signed_angle_to(want_f, up)
		var new_f := cur_f.rotated(up, clampf(ang, -max_turn, max_turn)).normalized()
		global_basis = Basis(new_f.cross(up).normalized(), up, -new_f)
	if is_inside_tree():
		global_position = next_pos
	else:
		position = next_pos
	move_speed_ratio = clampf(step_d / maxf(dt, 1e-4) / maxf(APPROACH_SPEED, 0.1), 0.0, 1.0)
	var want_p := -0.18 * move_speed_ratio if tilt_forward else 0.0
	_pitch_anim = lerpf(_pitch_anim, want_p, clampf(dt * 4.0, 0.0, 1.0))
	return false


func _begin_drop_telegraph() -> void:
	_drop_phase = PHASE_TELEGRAPH
	_active_weapon = DROP_WEAPON
	_telegraph_dur = maxf(DROP_TELEGRAPH_DUR * telegraph_scale, EnemyCatalog.MIN_TELEGRAPH)
	_telegraph_t = 0.0
	_locked_aim = _drop_pos
	ai_state = STATE_TELEGRAPH
	var bay_w := muzzle_world(DROP_WEAPON)
	telegraph_started.emit(self, DROP_WEAPON, _telegraph_dur, bay_w)
	_emit_squad("telegraph_started", {
		"id": target_id, "weapon": DROP_WEAPON, "kind": "dropship",
		"pos": bay_w, "target_pos": _drop_pos, "duration": _telegraph_dur,
	})


func _deploy_carried_squad() -> void:
	_telegraph_t = 0.0
	_telegraph_dur = 0.0
	if _telegraph_fx != null:
		_telegraph_fx.hide_telegraph()
	if _deployed or _dead or puppet or not Net.is_host():
		return
	_deployed = true
	_deploy_seq += 1
	if squad == null or not squad.has_method("add_enemy"):
		return
	var seed_v := world.mission_seed if world != null else 1
	var drng := RandomNumberGenerator.new()
	drng.seed = hash([seed_v, target_id, _deploy_seq, "drop_fireteam_v1"])
	var comp := EnemyTroopSquad.roll_composition(drng, "light" if _drop_is_roof else "medium", _drop_is_roof, 4 if _drop_is_roof else 5)
	var ft_id := "%s_drop_%d" % [target_id, _deploy_seq]
	var ft := EnemyTroopSquad.make(ft_id, spawn_deck, _drop_pos, _drop_is_roof)
	if squad.has_method("register_fireteam"):
		squad.register_fireteam(ft)
	var offsets := EnemyTroopSquad.member_arc_offsets(drng, comp.size(), _drop_is_roof, _drop_half_span)
	var d_plan: CityPlan = squad.deck_plan(spawn_deck) if squad.has_method("deck_plan") else null
	var base_b := global_basis if is_inside_tree() else Basis.IDENTITY
	var drop_arc := ring.world_to_arc(_drop_pos) if ring != null else Vector3(_drop_pos.x, _drop_pos.z, _drop_pos.y)
	# Find nearest standing crew mech on this deck so dropped street troopers start actively hunting!
	var best_p: CombatTarget = null
	var best_d := INF
	if not _drop_is_roof and world != null:
		for t: CombatTarget in world.targets:
			if not is_instance_valid(t) or t.team != "player" or not t.is_hittable():
				continue
			if squad.has_method("on_deck") and not squad.on_deck(t.global_position, spawn_deck):
				continue
			var d := _drop_pos.distance_squared_to(t.global_position)
			if d < best_d:
				best_d = d
				best_p = t
	var spawned: Array[EnemyTrooper] = []
	for i in comp.size():
		var stype := comp[i]
		var tr := EnemySpawner.make_enemy(stype) as EnemyTrooper
		if tr == null:
			continue
		var sid := "%s_t%d" % [ft_id, i]
		tr.configure(stype, sid, world, squad, ring, seed_v + _deploy_seq * 17 + i)
		tr.spawn_deck = spawn_deck
		tr.wave = wave
		tr.on_roof = _drop_is_roof
		tr.auto_remove_wreck = auto_remove_wreck
		tr.attach_fireteam(ft, i)
		var off2 := offsets[i] if i < offsets.size() else Vector2.ZERO
		var land_w := _drop_pos
		if ring != null:
			var cand_arc := Vector2(drop_arc.x + off2.x, drop_arc.y + off2.y)
			if d_plan != null and not EnemySpawner.clear_of_buildings(d_plan, cand_arc, 1.4, drop_arc.z + (0.2 if _drop_is_roof else 0.0)):
				cand_arc = Vector2(drop_arc.x, drop_arc.y)
			land_w = ring.arc_to_world(cand_arc.x, cand_arc.y, drop_arc.z)
		else:
			land_w = _drop_pos + Vector3(off2.x, 0.0, off2.y)
		tr.up = up
		tr.transform = Transform3D(base_b, _drop_pos + up * (8.5 + float(i) * 0.35))
		squad.add_enemy(tr)
		var stagger := float(i) * 0.11 + drng.randf_range(0.0, 0.06)
		tr.deploy_from_air(land_w, spawn_deck, stagger)
		if best_p != null:
			tr.hear_fire(best_p)
			tr.begin_hunt_pursuit(best_p, best_p.global_position)
		spawned.append(tr)
	if squad.has_method("note_deck_activity"):
		squad.note_deck_activity(spawn_deck)
	troops_deployed.emit(self, spawned)


func _finish_exfil() -> void:
	_drop_phase = PHASE_DONE
	if squad != null and squad.has_method("remove_enemy"):
		squad.remove_enemy(self)
	if world != null:
		world.unregister(self)
	queue_free()


# --- Visuals & Destruction --------------------------------------------------------------------------------

func _update_visuals(dt: float) -> void:
	_hover_t += dt
	if _body_pivot != null and is_instance_valid(_body_pivot):
		_body_pivot.position.y = sin(_hover_t * 2.4) * 0.18
		_body_pivot.rotation = Vector3(_pitch_anim, 0.0, 0.0)
	if _bay_mi != null and is_instance_valid(_bay_mi):
		_bay_mi.position.y = -0.35 * _bay_open
	if _telegraph_fx != null:
		if ai_state == STATE_TELEGRAPH and _telegraph_dur > 0.0:
			var frac := clampf(_telegraph_t / _telegraph_dur, 0.0, 1.0)
			_telegraph_fx.show_drop_ring(muzzle_world(DROP_WEAPON), _locked_aim, up, frac, dt)
		else:
			_telegraph_fx.hide_telegraph()
			_telegraph_fx.tick_only(dt)
		_update_reveal_fx(dt)
	if _status_bar != null:
		var tag := "DROP" if ai_state == STATE_TELEGRAPH else ("OVERHEAT" if heat.shutdown else "")
		_status_bar.refresh(core_hp_ratio(), heat_ratio, true, ai_state == STATE_TELEGRAPH, tag, _dead, dt, revealed)


func _spawn_death_debris(_cause: String) -> void:
	_pop_plates(_world_pos(), 7, 3.0, 9.0, 5.0, 12.0)


func _on_destroyed_visual() -> void:
	if _rotors_mi != null and is_instance_valid(_rotors_mi):
		_rotors_mi.visible = false
	if _bay_mi != null and is_instance_valid(_bay_mi):
		_bay_mi.visible = false
	if _hull_mi != null and is_instance_valid(_hull_mi):
		_hull_mi.visible = true
		_hull_mi.material_override = EnemyMeshes.charred_material()
	if _body_pivot != null and is_instance_valid(_body_pivot):
		_body_pivot.rotation = Vector3(0.35, 0.25, -0.42)


func _wreck_flame_specs() -> Array[Dictionary]:
	return [{
		"parent": _body_pivot if _body_pivot != null else self,
		"pos": Vector3(0.0, 0.2, 0.0), "dir": Vector3(0.08, 1.0, 0.06),
		"length": 4.8, "width": 1.2, "speed": 11.5, "count": 6, "root": 1.05, "duration": 8.5, "tag": "dropship_core",
	}]


func _core_rupture_pos() -> Vector3:
	return Vector3(0.0, 0.1, 0.0)


func _core_rupture_scale() -> float:
	return 1.35


func debug_info() -> Dictionary:
	var d := super.debug_info()
	d["drop_phase"] = _drop_phase
	d["deployed"] = _deployed
	d["drop_pos"] = _drop_pos
	return d


func _on_reset_visual() -> void:
	_drop_phase = PHASE_APPROACH
	_deployed = false
	_exfil_t = 0.0
	_pitch_anim = 0.0
	_bay_open = 0.0
	if _body_pivot != null and is_instance_valid(_body_pivot):
		_body_pivot.position = Vector3.ZERO
		_body_pivot.rotation = Vector3.ZERO
	if _bay_mi != null and is_instance_valid(_bay_mi):
		_bay_mi.position = Vector3.ZERO
	for mi: MeshInstance3D in [_hull_mi, _rotors_mi, _bay_mi]:
		if mi != null and is_instance_valid(mi):
			mi.visible = true
			mi.material_override = null
			mi.material_overlay = null
