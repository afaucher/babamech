class_name EnemyDropDrone
extends EnemyBase
## Armored Carrier Drop Ship ("dropship", docs/design/enemy-troop-squads.md §6):
##   - Unarmed troop transport called in by a Scout Drone beacon (strictly capped per deck so MissionRules never soft-locks).
##   - Lean curved-deck flight interpolation (zero per-frame physics raycasts or A* calls for < 4 ms AI budget):
##       APPROACH (19-21 m up, 18 m/s) -> DESCEND (to drop_y + 11 m) -> DROP_TELEGRAPH (1.5 s, pulsing ventral bay +
##       drop-zone ring; shooting it down destroys the carried squad mid-air with 0 troopers spawned!) ->
##       DEPLOY (spawns a variable-sized fireteam of 3-5 individual EnemyTrooper units via squad.add_enemy +
##       staggered deploy_from_air) -> EXFIL (climbs to 28 m & despawns).
##   - Navigation (no clipping): each leg (in to the drop point, out to the exit point) is planned ONCE over the deck's
##     plan data (EnemySquad.deck_occluders: building tiers with heights, pillars, downtown towers; CityPlan.ramps) at the
##     lowest route height with a way (ROUTE_ALT, else ROUTE_ALT_HIGH_GAP under the ceiling); what is still in the way
##     (pillars / towers to the ceiling) is routed round over the walk graph's street crossings, then string-pulled. It
##     climbs / descends only in place (where it is, or over the drop point). The hull box is swept against the
##     collision world each step (one intersect_shape): a blocked step climbs if it can, else holds, so the hull never
##     enters geometry.
##   - Air doors (MissionWorld.air_door, high in a deck's end walls): it is created dormant in a door's recess (staged:
##     no AI but this wait, not hittable), EnemySquad orders the door open (replicated like a wave's gate), it waits for
##     `passable`, flies out level and slowly through the opening to `out` (the door held open meanwhile), then its route.
##     To leave it flies to the nearest air door's `out`, turns in, orders it open, waits, flies in to `hide` and is
##     removed there; the door closes after its hold (also if the ship was shot down in the doorway). A deck without a
##     usable door: the old in-deck appear / leave point (EnemySquad._pick_drop_zone).
##   - Self-contained cached strictly watertight placeholder meshes ("dropship_hull", "dropship_rotors", "dropship_bay")
##     that automatically defer to EnemyMeshes.instance(part) once Enemy Art Direction adds them.

signal troops_deployed(dropship: EnemyDropDrone, deployed_troopers: Array)

const PHASE_APPROACH := "approach"
const PHASE_DESCEND := "descend"
const PHASE_TELEGRAPH := "telegraph"
const PHASE_EXFIL := "exfil"
const PHASE_DOOR_OUT := "door_out"    ## in an air door's recess: waiting for it to be passable, then flying out
const PHASE_DOOR_IN := "door_in"      ## at an air door's out point: waiting for it, then flying in to be removed
const PHASE_DONE := "done"

const DROP_WEAPON := "enemy_dropship_bay"
const DROP_TELEGRAPH_DUR := 1.5
const CRUISE_ALT := 20.0
const DROP_HOVER_OFFSET := 11.0
const EXFIL_ALT := 28.0
const APPROACH_SPEED := 18.0
const DESCEND_SPEED := 10.5
const EXFIL_SPEED := 16.0
const EXFIL_MAX_TIME := 90.0      ## safety cap: the exit leg is flown to its end point (it used to vanish mid-air at 4.5 s)
const HULL_SIZE := Vector3(5.2, 2.8, 6.8)
const ROUTE_ALT := 24.0           ## route height above the deck floor (clears most roofs)
const ROUTE_ALT_HIGH_GAP := 7.0   ## ...else this far under the ceiling
const CLEAR_H := 5.5              ## m kept from a building's footprint (hull half-diagonal 4.3 + margin)
const CLEAR_V := 6.0              ## m kept above a roof (hull half-height 1.4 + rooftop solids + margin)
const CLEAR_H_TIGHT := 4.5        ## second try: hull half-diagonal 4.3 + 0.2 (any heading clears)
const WAYPOINT_R := 4.0
const AIR_ORDER_LEAD := 1.0       ## s from the call to the door's open_at (its leaves start to move)
const AIR_ARRIVE_HOLD := 6.0      ## s the door stays fully open for the way out (extended while the hull is in it)
const AIR_LEAVE_HOLD := 5.0       ## s it stays open for the way in (the ship is removed inside; then it closes)
const AIR_DOOR_SPEED := 5.0       ## m/s through an opening (12 x 6 m round a 5.2 x 2.8 m hull: centred, level, slow)
const AIR_WAIT_MAX := 14.0        ## s a door may take to become passable before the ship gives up on it (fallback)
const REPLAN_STALL := 1.5         ## s held by the hull guard on a leg before it is planned again from where it is
const LINK_R := 160.0             ## m: the leg's ends link to street crossings this close

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
var _route: Array[Vector2] = []   ## arc waypoints of the current leg
var _route_alt := 0.0             ## its flight height above the deck floor
var _route_leg := 0               ## 0 none, 1 in (to the drop point), 2 out (to the exit point)
var _guard_q: PhysicsShapeQueryParameters3D = null   ## reused hull sweep query
var _guard_blocks := 0            ## telemetry / tests: steps the hull guard refused
var _descend_stall := 0.0         ## s the descent has been held by the hull guard
var _route_stall := 0.0           ## s the current leg has been held by the hull guard
var _air_in := {}                 ## the air door it arrives through {id, hide, out, facing, ...} ({}: none)
var _air_out := {}                ## the air door it leaves through ({}: none chosen / none usable)
var _air_wait := 0.0              ## s waiting at a door
var _air_open_at := 0.0           ## the door's ordered open_at (hold extensions reuse it)
var air_ordered_at := -1.0        ## telemetry / tests: world time the arrival door was ordered
var air_times := {}               ## telemetry / tests: world time of passable / out / drop / deploy / door_in / gone

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
		"_route": Net.PRIVATE, "_route_alt": Net.PRIVATE, "_route_leg": Net.PRIVATE, "_guard_q": Net.LOCAL,
		"_guard_blocks": Net.PRIVATE, "_descend_stall": Net.PRIVATE, "_route_stall": Net.PRIVATE,
		"_air_in": Net.PRIVATE, "_air_out": Net.PRIVATE, "_air_wait": Net.PRIVATE, "_air_open_at": Net.PRIVATE,
		"air_ordered_at": Net.PRIVATE, "air_times": Net.PRIVATE,
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
	_route.clear()
	_route_leg = 0
	_air_in = {}
	_air_out = {}


## Arrive through air door `door` (EnemySquad.pick_air_door): the caller placed it at door.hide; it waits there dormant.
func configure_air_arrival(door: Dictionary) -> void:
	_air_in = door.duplicate()
	_air_wait = 0.0
	_air_open_at = 0.0
	_drop_phase = PHASE_DOOR_OUT
	staged = true


## Waiting in a recess it still runs (only this wait); staged keeps it dormant to everything else and not hittable.
func _is_awake() -> bool:
	if staged and _drop_phase == PHASE_DOOR_OUT:
		return true
	return super._is_awake()


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
		PHASE_DOOR_OUT:
			ai_state = STATE_FLANK
			_step_door_out(dt, _space)
		PHASE_DOOR_IN:
			ai_state = STATE_FLANK
			_step_door_in(dt, _space)
		PHASE_APPROACH:
			ai_state = STATE_FLANK
			_bay_open = move_toward(_bay_open, 0.0, dt * 3.0)
			if _route_leg != 1:
				_plan_leg(1, _arc2(_drop_pos))
			if _follow_route(APPROACH_SPEED * speed_scale, dt, _space):
				_drop_phase = PHASE_DESCEND
		PHASE_DESCEND:
			ai_state = STATE_ENGAGE
			_bay_open = move_toward(_bay_open, 0.35, dt * 2.5)
			var hover_drop := _drop_pos + up * DROP_HOVER_OFFSET
			var blocks0 := _guard_blocks
			var arrived := _step_fly_to(hover_drop, DESCEND_SPEED * speed_scale, dt, false, _space, false)
			# Something under the hull (a mission flag, a prop): drop the squad from where it hovers instead of
			# sinking into it (the troopers' descent is scripted from the bay to the ground).
			_descend_stall = _descend_stall + dt if _guard_blocks > blocks0 else 0.0
			if arrived or _descend_stall >= 0.4:
				_begin_drop_telegraph()
				air_times["drop"] = world.now if world != null else 0.0
		PHASE_TELEGRAPH:
			_pitch_anim = move_toward(_pitch_anim, 0.0, dt * 4.0)
			_bay_open = move_toward(_bay_open, 1.0, dt * 2.5)
			_telegraph_t += dt
			_align_to_ring()
			if _telegraph_t >= _telegraph_dur:
				_deploy_carried_squad()
				air_times["deploy"] = world.now if world != null else 0.0
				_drop_phase = PHASE_EXFIL
				_exfil_t = 0.0
				ai_state = STATE_FLANK
		PHASE_EXFIL:
			ai_state = STATE_FLANK
			_bay_open = move_toward(_bay_open, 0.0, dt * 3.0)
			_exfil_t += dt
			if _route_leg != 2:
				_air_out = squad.pick_air_door(spawn_deck, _arc2(_world_pos()), false) \
					if squad != null and squad.has_method("pick_air_door") else {}
				_plan_leg(2, _arc2(_air_out["out"] as Vector3) if not _air_out.is_empty() else _arc2(_exfil_pos))
			var done := _follow_route(EXFIL_SPEED * speed_scale, dt, _space)
			if done and not _air_out.is_empty():
				_drop_phase = PHASE_DOOR_IN
				_air_wait = 0.0
				_air_open_at = 0.0
			elif done or _exfil_t >= EXFIL_MAX_TIME:
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


func _step_fly_to(goal_w: Vector3, spd: float, dt: float, tilt_forward: bool, space: PhysicsDirectSpaceState3D = null,
		lift_ok_when_blocked: bool = true) -> bool:
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
		var nh := clampf(ring.height(next_pos), 6.0, _ceiling_h() - HULL_SIZE.y)
		var a3 := ring.world_to_arc(next_pos)
		next_pos = ring.arc_to_world(a3.x, a3.y, nh)
	if not _hull_clear(space, next_pos):
		# The hull would enter geometry: climb straight up if that is clear, else hold (never interpenetrate).
		_guard_blocks += 1
		var lift := pos + up * minf(spd * dt, 2.0)
		var lift_ok := lift_ok_when_blocked and (ring == null or ring.height(lift) < _ceiling_h() - HULL_SIZE.y) 			and _hull_clear(space, lift)
		next_pos = lift if lift_ok else pos
		step_d = next_pos.distance_to(pos)
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
		var nb := Basis(new_f.cross(up).normalized(), up, -new_f)
		if _hull_clear(space, next_pos, nb):   # a turn that would swing the hull into a wall waits
			global_basis = nb
	if is_inside_tree():
		global_position = next_pos
	else:
		position = next_pos
	move_speed_ratio = clampf(step_d / maxf(dt, 1e-4) / maxf(APPROACH_SPEED, 0.1), 0.0, 1.0)
	var want_p := -0.18 * move_speed_ratio if tilt_forward else 0.0
	_pitch_anim = lerpf(_pitch_anim, want_p, clampf(dt * 4.0, 0.0, 1.0))
	return false


func _arc2(p: Vector3) -> Vector2:
	if ring != null:
		var a := ring.world_to_arc(p)
		return Vector2(a.x, a.y)
	return Vector2(p.x, p.z)


func _arc_world(a: Vector2, h: float) -> Vector3:
	return ring.arc_to_world(a.x, a.y, h) if ring != null else Vector3(a.x, h, a.y)


func _deck_plan() -> CityPlan:
	if squad != null and squad.has_method("deck_plan"):
		return squad.deck_plan(spawn_deck) as CityPlan
	return null


func _ceiling_h() -> float:
	var pl := _deck_plan()
	return pl.p("ceiling") if pl != null else 40.0


## True when the hull box at `at` (current facing) touches no collision geometry (mechs aside). No space: always clear.
func _hull_clear(space: PhysicsDirectSpaceState3D, at: Vector3, basis_at: Variant = null) -> bool:
	if space == null or world == null or not world.use_physics or not is_inside_tree():
		return true
	if _guard_q == null:
		var box := BoxShape3D.new()
		box.size = HULL_SIZE
		_guard_q = PhysicsShapeQueryParameters3D.new()
		_guard_q.shape = box
		_guard_q.collide_with_areas = false
	_guard_q.transform = Transform3D(basis_at if basis_at is Basis else global_basis, at)
	for hit: Dictionary in space.intersect_shape(_guard_q, 4):
		if not (hit["collider"] is CharacterBody3D):   # a mech is not a wall (the hover is above head height anyway)
			return false
	return true


## Obstacle boxes at route height `alt` (arc space, grown by CLEAR_H): building tiers whose top + CLEAR_V reaches it,
## pillars and towers (to the ceiling), park columns and ramps.
func _obstacles(alt: float, clear: float = CLEAR_H) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if squad != null and squad.has_method("deck_occluders"):
		for item: Dictionary in squad.deck_occluders(spawn_deck):
			if float(item["h"]) + CLEAR_V > alt:
				out.append((item["rect"] as Rect2).grow(clear))
	var pl := _deck_plan()
	if pl != null:
		for c: Dictionary in pl.columns:   # park tree-columns: floor to ceiling, not in the occluders
			var ch := float(c.get("half", 2.0))
			out.append(Rect2(float(c["x"]) - ch, float(c["s"]) - ch, ch * 2.0, ch * 2.0).grow(clear))
		for r: Dictionary in pl.ramps:
			var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
			var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
			out.append(Rect2(float(r["x0"]), s0, float(r["x1"]) - float(r["x0"]), s1 - s0).grow(clear))
	return out


static func _seg_clear(a: Vector2, b: Vector2, obs: Array[Rect2]) -> bool:
	return not EnemySquad._arc_seg_occluded_rects(a, b, obs)


## Plans leg `leg` from here to `goal` (arc): the lowest route height that has a way, then its waypoints.
func _plan_leg(leg: int, goal: Vector2) -> void:
	_route_leg = leg
	_route.clear()
	var from := _arc2(_world_pos())
	var high := _ceiling_h() - ROUTE_ALT_HIGH_GAP
	var alts: Array[float] = [minf(ROUTE_ALT, high), high]
	# Full clearance first, then a tight one (narrow streets between grown footprints cut the graph); the hull guard
	# still keeps the hull itself out of geometry.
	for clear: float in [CLEAR_H, CLEAR_H_TIGHT]:
		for alt: float in alts:
			var path := _route_over(from, goal, _obstacles(alt, clear))
			if not path.is_empty():
				_route_alt = alt
				_route = path
				return
	# No way at any height (should not happen): straight at the high route; the hull guard holds it at a wall.
	_route_alt = alts[1]
	_route = [goal] as Array[Vector2]


## Waypoints from a to b avoiding obs: straight if clear, else A* over the deck's street crossings (walk graph) with
## clear links, string-pulled. [] when there is no way.
func _route_over(a: Vector2, b: Vector2, obs_in: Array[Rect2]) -> Array[Vector2]:
	# A box holding either end (only its clearance margin can: the hull guard keeps the hull outside the geometry) is
	# shrunk to its footprint + the hull's half-width, or left out if even that holds the end: else nothing could leave
	# or reach that end (and leaving it out whole sent a replan from beside a column straight through it).
	var obs: Array[Rect2] = []
	for r: Rect2 in obs_in:
		if not r.has_point(a) and not r.has_point(b):
			obs.append(r)
			continue
		var core := r.grow(-(CLEAR_H_TIGHT - HULL_SIZE.x * 0.5 - 0.1)) if r.size.x > 2.0 * CLEAR_H_TIGHT else r
		if core.size.x > 0.0 and core.size.y > 0.0 and not core.has_point(a) and not core.has_point(b):
			obs.append(core)
	if _seg_clear(a, b, obs):
		return [b] as Array[Vector2]
	var nodes: Array[Vector2] = []
	var adj: Array = []
	var graphs: Variant = squad.get("_deck_graphs") if squad != null else null
	if graphs is Dictionary and (graphs as Dictionary).has(spawn_deck):
		nodes = (graphs as Dictionary)[spawn_deck][0]
		adj = (graphs as Dictionary)[spawn_deck][1]
	elif squad != null and squad.get("_graph_nodes") != null:
		nodes = squad.get("_graph_nodes")
		adj = squad.get("_graph_adj")
	var n := nodes.size()
	if n == 0:
		return [] as Array[Vector2]
	# Ids: 0..n-1 crossings, n = start, n + 1 = goal.
	var pos: Array[Vector2] = nodes.duplicate()
	pos.append(a)
	pos.append(b)
	var links: Array = []
	links.resize(n + 2)
	for i in n + 2:
		links[i] = []
	for i in n:
		for j: int in adj[i]:
			if j > i and _seg_clear(nodes[i], nodes[j], obs):
				(links[i] as Array).append(j)
				(links[j] as Array).append(i)
	for end_i: int in [n, n + 1]:
		var p: Vector2 = pos[end_i]
		var cand: Array = []
		for i in n:
			var d := p.distance_to(nodes[i])
			if d <= LINK_R:
				cand.append([d, i])
		cand.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]) or (float(x[0]) == float(y[0]) and int(x[1]) < int(y[1])))
		var linked := 0
		for c: Array in cand:
			if _seg_clear(p, nodes[int(c[1])], obs):
				(links[end_i] as Array).append(int(c[1]))
				(links[int(c[1])] as Array).append(end_i)
				linked += 1
				if linked >= 4:
					break
	# A* (deterministic: ties broken by the lower id).
	var g := PackedFloat32Array()
	g.resize(n + 2)
	g.fill(INF)
	var came := PackedInt32Array()
	came.resize(n + 2)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n + 2)
	g[n] = 0.0
	var open: Array[int] = [n]
	while not open.is_empty():
		var bi := 0
		var bf := INF
		for k in open.size():
			var id := open[k]
			var fv := g[id] + pos[id].distance_to(b)
			if fv < bf or (fv == bf and id < open[bi]):
				bf = fv
				bi = k
		var cur := open[bi]
		open.remove_at(bi)
		if cur == n + 1:
			break
		closed[cur] = 1
		for nb: int in links[cur]:
			if closed[nb] == 1:
				continue
			var ng := g[cur] + pos[cur].distance_to(pos[nb])
			if ng < g[nb]:
				g[nb] = ng
				came[nb] = cur
				if not open.has(nb):
					open.append(nb)
	if came[n + 1] < 0:
		return [] as Array[Vector2]
	var chain: Array[Vector2] = []
	var c_id := n + 1
	while c_id != n and c_id >= 0:
		chain.push_front(pos[c_id])
		c_id = came[c_id]
	# String-pull: from each point jump to the farthest later point in clear line.
	var out: Array[Vector2] = []
	var here := a
	var i0 := 0
	while i0 < chain.size():
		var far := i0
		for j in range(chain.size() - 1, i0, -1):
			if _seg_clear(here, chain[j], obs):
				far = j
				break
		out.append(chain[far])
		here = chain[far]
		i0 = far + 1
	return out


## Flies the current leg: first to the route height in place, then waypoint by waypoint. True past the last one.
func _follow_route(spd: float, dt: float, space: PhysicsDirectSpaceState3D) -> bool:
	var pos := _world_pos()
	var h := ring.height(pos) if ring != null else pos.y
	var here := _arc2(pos)
	if absf(h - _route_alt) > 0.8:
		_step_fly_to(_arc_world(here, _route_alt), spd * 0.6, dt, false, space)
		return false
	while not _route.is_empty() and here.distance_to(_route[0]) <= WAYPOINT_R:
		_route.pop_front()
	if _route.is_empty():
		return true
	var blocks0 := _guard_blocks
	_step_fly_to(_arc_world(_route[0], _route_alt), spd, dt, true, space)
	_route_stall = _route_stall + dt if _guard_blocks > blocks0 else 0.0
	if _route_stall >= REPLAN_STALL:
		# Held at something the plan data did not show: plan the leg again from here (at most every REPLAN_STALL s).
		_route_stall = 0.0
		_plan_leg(_route_leg, _arc2(_drop_pos) if _route_leg == 1 else _arc2(_exfil_pos))
	return false


## In the recess: dormant until the door is passable (ordered by EnemySquad.request_dropship), then out along the door's
## axis to its `out` point at AIR_DOOR_SPEED, the door held open meanwhile; then the planned route.
func _step_door_out(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	var id := str(_air_in.get("id", ""))
	var st: Dictionary = squad.air_door_state(id) if squad != null and squad.has_method("air_door_state") else {}
	_air_wait += dt
	if staged:
		if bool(st.get("passable", false)):
			staged = false
			_air_open_at = float(st.get("open_at", 0.0))
			air_times["passable"] = world.now if world != null else 0.0
		elif _air_wait >= AIR_WAIT_MAX or str(st.get("state", "")) == "sealed" or st.is_empty():
			# The door never opened (sealed, gone): the old in-deck appear point.
			staged = false
			_air_in = {}
			var p0 := _exfil_pos
			if ring != null:
				var a := ring.world_to_arc(p0)
				p0 = ring.arc_to_world(a.x, a.y, CRUISE_ALT)
			global_position = p0
			_drop_phase = PHASE_APPROACH
			return
		else:
			_align_to_ring()
			return
	_hold_door(id, st)
	var out_w: Vector3 = _air_in["out"]
	if _step_fly_to(out_w, AIR_DOOR_SPEED * speed_scale, dt, false, space, false):
		air_times["out"] = world.now if world != null else 0.0
		_drop_phase = PHASE_APPROACH
		_route_leg = 0


## At a door's `out` point: turn in, order it open, wait for passable, fly in to `hide`, then gone (the door closes after
## its hold).
func _step_door_in(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	var id := str(_air_out.get("id", ""))
	var out_w: Vector3 = _air_out["out"]
	var hide_w: Vector3 = _air_out["hide"]
	_air_wait += dt
	if _air_open_at <= 0.0:
		# First reach the out point exactly (mid opening height), then face the door.
		if not _step_fly_to(out_w, AIR_DOOR_SPEED * speed_scale, dt, false, space, false):
			return
		var into := -(_air_out["facing"] as Vector3)
		into = (into - up * into.dot(up)).normalized()
		if not _turn_to(into, dt, space):
			return
		_air_open_at = (world.now if world != null else 0.0) + AIR_ORDER_LEAD
		air_times["door_in"] = world.now if world != null else 0.0
		if squad != null and squad.has_method("order_air_door"):
			squad.order_air_door(id, spawn_deck, _air_open_at, AIR_LEAVE_HOLD)
		_air_wait = 0.0
		return
	var st: Dictionary = squad.air_door_state(id) if squad != null and squad.has_method("air_door_state") else {}
	if not bool(st.get("passable", false)):
		if _air_wait >= AIR_WAIT_MAX or str(st.get("state", "")) == "sealed":
			_finish_exfil()   # the door never opened: leave as before (removed where it is)
		else:
			_align_to_ring()
		return
	_hold_door(id, st)
	if _step_fly_to(hide_w, AIR_DOOR_SPEED * speed_scale, dt, false, space, false):
		air_times["gone"] = world.now if world != null else 0.0
		_finish_exfil()


## Keeps door `id` open until the hull has had AIR_DOOR_CLEAR s more (re-orders it with the same open_at: only the hold
## grows), checked about once a second.
func _hold_door(id: String, st: Dictionary) -> void:
	if squad == null or not squad.has_method("order_air_door") or world == null:
		return
	var close_at := float(st.get("close_at", INF))
	if close_at - world.now < 3.0:
		var oa := float(st.get("open_at", _air_open_at))
		squad.order_air_door(id, spawn_deck, oa, (world.now + 5.0) - oa - 3.0)


## Turns toward horizontal direction `want` at the catalog turn rate (hull guarded). True once aligned.
func _turn_to(want: Vector3, dt: float, space: PhysicsDirectSpaceState3D) -> bool:
	if not is_inside_tree():
		return true
	var cur := -global_basis.z
	cur = (cur - up * cur.dot(up)).normalized()
	var ang := cur.signed_angle_to(want, up)
	if absf(ang) < 0.03:
		return true
	var step := clampf(ang, -float(_cfg.get("turn_rate", 1.8)) * dt, float(_cfg.get("turn_rate", 1.8)) * dt)
	var nf := cur.rotated(up, step).normalized()
	var nb := Basis(nf.cross(up).normalized(), up, -nf)
	if _hull_clear(space, global_position, nb):
		global_basis = nb
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
	_route.clear()
	_route_leg = 0
	_guard_blocks = 0
	_descend_stall = 0.0
	_route_stall = 0.0
	_air_in = {}
	_air_out = {}
	_air_wait = 0.0
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
