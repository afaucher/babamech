class_name LifeTramCars
extends Node3D
## Draws one deck's tram (LifeTram) and gives its cars collision (docs/design/ambient-life.md, phase 3). Three identical
## shuttle-form cars (the approved "shuttle" silhouette, transit livery: sky-blue body, cream lower band, dark glazing
## along the whole side, a big windscreen at both ends), 3 x 9 m, 3.2 m tall: MultiMeshes per lights state (plain, hazards
## dark, hazards bright), flat palette colour per face on CityPalette.surface_material(), no emission.
## Collision: one AnimatableBody3D per car (kinematic, moved to the tram's pose every frame, no physics simulation), on
## collision layer 1 like the district's own StaticBody3D, so a mech cannot walk through a tram. The one node-per-agent
## exception in ambient life. A car wholly beyond an end wall (through a portal) is hidden.
##
## When a car's shape is on (settle(), every _tram_step, after place() for every car; docs/design/ambient-life.md "Tram
## collision and crushing"):
##   * the position rule (LifeTram.car_solid, passed to place()): solid only while wholly at least END_CLEAR m inside both
##     end walls, so it can never wedge a mech against an end wall or a portal's back plate, nor push it into the recess;
##   * a car switching ON stays off while any character body overlaps it (it passes through, never launches one);
##   * pinch: a moving solid car pressing a character body ahead of it that does not make way (advances < MAKE_WAY of the
##     car's advance over CRUSH_HOLD s: pinned against a wall, a building, a prop) switches off and passes through it;
##     so does a car reaching the END_CLEAR zone (the position rule) while pressing one. Either is a crush: the body takes
##     LifeTram.CRUSH_DAMAGE on each leg ONCE (per body, CRUSH_REPEAT s: one train pass; every car touching it in that
##     time passes through it), through the apply_damage verb of the PlayerTarget (group "player_target") whose `mech`
##     it is, on THIS machine only when that mech is not a puppet (the victim's machine decides about its own mech). An
##     enemy (host-owned) or a puppet is never damaged here. `crushed` is emitted for every crush of a non-puppet body.
## Collision is local presentation: every machine runs these rules on the same car poses; the overlap / pinch parts use
## its own bodies.

signal crushed(body: CharacterBody3D, amount: float, applied: bool)

const PLAIN := 0
const HAZARD_DARK := 1
const HAZARD_BRIGHT := 2
const RING_PTS := 20
const ROUND := 8.0             ## superellipse exponent of the cross-sections: a boxy rounded brick
const LAYER := 1               ## collision layer (the district's StaticBody3D is on layer 1)
const TOUCH := 0.3             ## m: the query box reaches this far past the car's ends ("pressing")
const CRUSH_HOLD := 0.2        ## s a moving car may press a body that does not make way before it is pinned
const MAKE_WAY := 0.3          ## a pressed body advancing less than this share of the car's advance is not making way
const CRUSH_REPEAT := 8.0      ## s: one crush per body per train pass
const PIN_GAP := 0.5           ## m: a pressed body with something solid this close ahead of it is pinned
const STEP_CLEAR := 1.0        ## m: obstacles lower than this ahead of a pressed body (curbs, steps) do not pin it
const PIN_HIGH := 4.5          ## m of the body above STEP_CLEAR checked for that obstacle
const JUMP := 0.5            ## s: a longer clock step is a jump (advance_to / restore), not motion

var bodies: Array[AnimatableBody3D] = []
var _mms: Array = []                       ## [plain, hazard dark, hazard bright] MultiMesh, LifeTram.CARS instances each
var _shown := PackedInt32Array()           ## car -> -1 hidden, else the lights state shown
var _shapes: Array[CollisionShape3D] = []
var _want := PackedByteArray()             ## car -> 1 when the position rule makes it solid (place())
var _prev := PackedVector3Array()          ## car -> its world origin at the last settle()
var _settled := false                      ## _prev / _last_t hold a previous settle()
var _last_t := 0.0                         ## life clock at the last settle()
var _press := {}                           ## body instance id -> [car, s pressed, car advance, body advance, body pos]
var _crushed_at := {}                      ## body instance id -> life clock of its last crush
var _query: PhysicsShapeQueryParameters3D
var _rids: Array[RID] = []


func net_fields() -> Dictionary:
	return {"bodies": Net.LOCAL, "_mms": Net.LOCAL, "_shown": Net.LOCAL, "_shapes": Net.LOCAL,
		# collision bookkeeping: local presentation of the shared pose, from this machine's own bodies
		"_want": Net.LOCAL, "_prev": Net.LOCAL, "_settled": Net.LOCAL, "_last_t": Net.LOCAL, "_press": Net.LOCAL,
		"_query": Net.LOCAL, "_rids": Net.LOCAL,
		"_crushed_at": Net.PRIVATE}           # decides crush damage on this machine's own mech only


func _init() -> void:
	name = "Tram"


func build(bounds: AABB, render_layer: int) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	bodies.clear()
	_shapes.clear()
	_mms.clear()
	_rids.clear()
	_shown = PackedInt32Array()
	_shown.resize(LifeTram.CARS)
	_shown.fill(-1)
	_want = PackedByteArray()
	_want.resize(LifeTram.CARS)
	_prev = PackedVector3Array()
	_prev.resize(LifeTram.CARS)
	_settled = false
	_press.clear()
	_crushed_at.clear()
	var qbox := BoxShape3D.new()
	qbox.size = Vector3(LifeTram.CAR_W + 0.2, LifeTram.CAR_H - 0.6, LifeTram.CAR_L + 2.0 * TOUCH)
	_query = PhysicsShapeQueryParameters3D.new()
	_query.shape = qbox
	_query.collide_with_areas = false
	for lit in 3:
		var geo := CityGeo.new()
		car(geo, lit)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = geo.commit(CityPalette.surface_material())
		mm.instance_count = LifeTram.CARS
		mm.custom_aabb = bounds
		for i in LifeTram.CARS:
			mm.set_instance_transform(i, LifeFigures.HIDDEN)
		_mms.append(mm)
		var mi := MultiMeshInstance3D.new()
		mi.name = "car%s" % ["", "_haz", "_haz_lit"][lit]
		mi.multimesh = mm
		mi.layers = render_layer
		add_child(mi)
	for i in LifeTram.CARS:
		var body := AnimatableBody3D.new()
		body.name = "Car%d" % i
		body.sync_to_physics = false
		body.collision_layer = LAYER
		body.collision_mask = 0
		body.top_level = true
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(LifeTram.CAR_W, LifeTram.CAR_H, LifeTram.CAR_L)
		cs.shape = box
		cs.position = Vector3(0.0, LifeTram.CAR_H * 0.5 + 0.1, 0.0)
		cs.disabled = true
		body.add_child(cs)
		add_child(body)
		bodies.append(body)
		_shapes.append(cs)
		_rids.append(body.get_rid())
	_query.exclude = _rids


## Car i at `local` (deck-local, for the drawing) / `world` (for its body), in lights state `want` (-1: hidden: beyond an
## end wall; -2: not drawn (out of every viewer's range)). `solid`: the position rule (LifeTram.car_solid); settle() then
## decides its collision.
func place(i: int, want: int, local: Transform3D, world: Transform3D, solid: bool = true) -> void:
	var prev := _shown[i]
	if prev >= 0 and prev != want:
		(_mms[prev] as MultiMesh).set_instance_transform(i, LifeFigures.HIDDEN)
	_shown[i] = want
	if want >= 0:
		(_mms[want] as MultiMesh).set_instance_transform(i, local)
	_want[i] = 1 if solid and want != -1 else 0
	if bodies[i].is_inside_tree():
		bodies[i].global_transform = world
	else:
		bodies[i].transform = world


## After place() for every car, at life clock `now`: switch each car's collision (see the header).
func settle(now: float) -> void:
	var dt := now - _last_t
	var moving_clock := _settled and dt > 0.0 and dt <= JUMP
	_last_t = now
	var space: PhysicsDirectSpaceState3D = null
	if is_inside_tree() and get_world_3d() != null:
		space = get_world_3d().direct_space_state
	for i in LifeTram.CARS:
		var xf := bodies[i].global_transform if bodies[i].is_inside_tree() else bodies[i].transform
		var adv := xf.origin - _prev[i] if moving_clock else Vector3.ZERO
		_prev[i] = xf.origin
		var want := _want[i] == 1
		var shape := _shapes[i]
		if space == null:
			shape.disabled = not want
			continue
		var on := not shape.disabled
		var moving := adv.length() > 1e-4
		if not on:
			if want and _touching(i, xf, space).is_empty():
				shape.disabled = false          # nothing in it: on (never switched on around a body: no launch)
			continue
		if not moving:
			_drop_presses(i)
			if not want:
				shape.disabled = true
			continue
		var dir := adv.normalized()
		var ahead: Array[CharacterBody3D] = []
		for b: CharacterBody3D in _touching(i, xf, space):
			if (b.global_position - xf.origin).dot(dir) > LifeTram.CAR_L * 0.5:
				ahead.append(b)
		if not want:
			# Into the END_CLEAR zone (or beyond a wall) while shoving a body toward the wall: it would be squeezed there.
			shape.disabled = true
			for b in ahead:
				_crush(b, now)
			_drop_presses(i)
			continue
		var off := false
		var seen := {}
		for b in ahead:
			var id := b.get_instance_id()
			seen[id] = true
			if now - float(_crushed_at.get(id, -INF)) < CRUSH_REPEAT:
				off = true                       # crushed this pass: every car passes through it
				continue
			if _blocked(b, dir, space):
				_crush(b, now)                   # pressed against something solid right ahead of it: pinned
				off = true
				_press.erase(id)
				continue
			var e: Array = _press.get(id, [])
			if e.is_empty() or int(e[0]) != i:
				_press[id] = [i, 0.0, 0.0, 0.0, b.global_position]
				continue
			e[1] = float(e[1]) + dt
			e[2] = float(e[2]) + adv.length()
			e[3] = float(e[3]) + (b.global_position - (e[4] as Vector3)).dot(dir)
			e[4] = b.global_position
			if float(e[1]) >= CRUSH_HOLD:
				if float(e[3]) < MAKE_WAY * float(e[2]):
					_crush(b, now)
					off = true
					_press.erase(id)
				else:
					_press[id] = [i, 0.0, 0.0, 0.0, b.global_position]
		for id: int in _press.keys():
			if int(_press[id][0]) == i and not seen.has(id):
				_press.erase(id)
		if off:
			shape.disabled = true
	_settled = true


## Character bodies overlapping car i's box (reaching TOUCH past its ends; from 0.4 m above its floor, clear of curbs).
func _touching(i: int, xf: Transform3D, space: PhysicsDirectSpaceState3D) -> Array[CharacterBody3D]:
	var out: Array[CharacterBody3D] = []
	_query.transform = xf * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.4 + (LifeTram.CAR_H - 0.6) * 0.5, 0.0))
	for hit: Dictionary in space.intersect_shape(_query, 32):
		var b := hit.get("collider") as CharacterBody3D
		if b != null and not out.has(b):
			out.append(b)
	return out


## Whether body b cannot move PIN_GAP m along `dir`: its own collision shape, lifted STEP_CLEAR m (curbs and steps it
## would climb do not count), cast against everything it collides with but the cars. Physics would otherwise squeeze a
## pinned capsule through the obstacle or out of the gap.
func _blocked(b: CharacterBody3D, dir: Vector3, space: PhysicsDirectSpaceState3D) -> bool:
	var cs: CollisionShape3D = null
	for c in b.get_children():
		if c is CollisionShape3D and not (c as CollisionShape3D).disabled and (c as CollisionShape3D).shape != null:
			cs = c
			break
	if cs == null:
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	var lift := STEP_CLEAR
	var gap := PIN_GAP
	q.shape = cs.shape
	if cs.shape is CapsuleShape3D:
		# Slimmer (a wall it only brushes along the track does not pin it) and at most PIN_HIGH m tall above the lift (an
		# overhang above that does not either). The trimmed radius is added back to the distance cast.
		var src := cs.shape as CapsuleShape3D
		var cap := CapsuleShape3D.new()
		cap.radius = src.radius * 0.9
		cap.height = clampf(src.height - STEP_CLEAR, cap.radius * 2.0, PIN_HIGH)
		q.shape = cap
		lift = STEP_CLEAR + cap.height * 0.5 - src.height * 0.5
		gap += src.radius * 0.1
	q.collision_mask = b.collision_mask
	var ex: Array[RID] = _rids.duplicate()
	ex.append(b.get_rid())
	q.exclude = ex
	q.transform = Transform3D(Basis.IDENTITY, b.up_direction * lift) * cs.global_transform
	q.motion = dir * gap
	var r := space.cast_motion(q)
	return r.size() >= 1 and float(r[0]) < 1.0


func _drop_presses(i: int) -> void:
	for id: int in _press.keys():
		if int(_press[id][0]) == i:
			_press.erase(id)


## A car pinned body b: crush damage once per train pass, on this machine only for its own (non-puppet) mech.
func _crush(b: CharacterBody3D, now: float) -> void:
	var id := b.get_instance_id()
	if now - float(_crushed_at.get(id, -INF)) < CRUSH_REPEAT:
		return
	if _crushed_at.size() > 32:
		for k: int in _crushed_at.keys():
			if now - float(_crushed_at[k]) >= CRUSH_REPEAT:
				_crushed_at.erase(k)
	_crushed_at[id] = now
	if b.get("puppet") == true:
		return                                   # another machine's mech: its owner decides
	var applied := false
	for n: Node in get_tree().get_nodes_in_group("player_target"):
		if n.get("mech") == b and n.has_method("apply_damage"):
			n.call("apply_damage", LifeTram.CRUSH_DAMAGE, "leg_l", "crush")
			n.call("apply_damage", LifeTram.CRUSH_DAMAGE, "leg_r", "crush")
			applied = true
			break
	crushed.emit(b, LifeTram.CRUSH_DAMAGE, applied)


## Only the drawing (the bodies keep following the tram).
func set_drawn(on: bool) -> void:
	for c in get_children():
		if c is MultiMeshInstance3D:
			(c as MultiMeshInstance3D).visible = on


func shown(i: int) -> int:
	return _shown[i]


# --- Mesh ------------------------------------------------------------------------------------------------

## A rounded loft along +Y: rings [y, half x, half z, colour of the band above], superellipse cross-sections.
static func _loft(geo: CityGeo, rings: Array, cap_top: Color, cap_bottom: Color) -> void:
	var ring_pts: Array = []
	for r: Array in rings:
		var pts: Array[Vector3] = []
		for k in RING_PTS:
			var a := TAU * (float(k) + 0.5) / float(RING_PTS)
			var c := cos(a)
			var s := sin(a)
			pts.append(Vector3(signf(s) * pow(absf(s), 2.0 / ROUND) * float(r[1]), float(r[0]),
					signf(c) * pow(absf(c), 2.0 / ROUND) * float(r[2])))
		ring_pts.append(pts)
	for i in rings.size() - 1:
		var lo: Array = ring_pts[i]
		var hi: Array = ring_pts[i + 1]
		for k in RING_PTS:
			var j := (k + 1) % RING_PTS
			geo.quad(lo[k], lo[j], hi[j], hi[k], rings[i][3])
	var top: Array = ring_pts[-1]
	var bot: Array = ring_pts[0]
	var ct := Vector3(0.0, float(rings[-1][0]), 0.0)
	var cb := Vector3(0.0, float(rings[0][0]), 0.0)
	for k in RING_PTS:
		var j := (k + 1) % RING_PTS
		geo.tri(ct, top[k], top[j], cap_top)
		geo.tri(cb, bot[j], bot[k], cap_bottom)


## One tram car, 3 x 9 m, 3.2 m tall, symmetric (either end leads), floor at y = 0. `lights`: PLAIN, HAZARD_DARK or
## HAZARD_BRIGHT.
static func car(geo: CityGeo, lights: int) -> void:
	var blue := CityPalette.c("sky_blue")
	var cream := CityPalette.c("cream_light")
	var glass := CityPalette.c("glass_dark")
	var hw := LifeTram.CAR_W * 0.5
	var hl := LifeTram.CAR_L * 0.5
	_loft(geo, [
		[0.30, hw - 0.2, hl - 0.2, CityPalette.c("metal_dark")],
		[0.55, hw, hl, blue],
		[0.92, hw, hl, cream],
		[1.22, hw, hl, blue],
		[2.70, hw - 0.02, hl - 0.04, blue],
		[3.04, hw - 0.14, hl - 0.2, blue],
		[3.20, hw - 0.4, hl - 0.5, blue],
	], blue, CityPalette.c("metal_dark"))
	var xf := Transform3D.IDENTITY
	# Glazing along both sides: four windows and a double door in the middle (door glass down to the step).
	for sx: float in [-1.0, 1.0]:
		for z: Array in [[-3.6, -2.4], [-2.2, -0.9], [0.9, 2.2], [2.4, 3.6]]:
			geo.box(xf, Vector3(sx * (hw + 0.01), 1.95, (float(z[0]) + float(z[1])) * 0.5), Vector3(0.05, 1.2, float(z[1]) - float(z[0])), glass)
		for z: float in [-0.36, 0.36]:
			geo.box(xf, Vector3(sx * (hw + 0.01), 1.55, z), Vector3(0.05, 2.0, 0.64), glass)
		geo.box(xf, Vector3(sx * (hw + 0.015), 1.55, 0.0), Vector3(0.05, 2.06, 0.06), CityPalette.c("blue_grey"))     # door seam
	# A big windscreen and a light bar at both ends.
	for sz: float in [-1.0, 1.0]:
		geo.box(xf, Vector3(0.0, 1.95, sz * (hl + 0.0)), Vector3(2.0, 1.3, 0.06), glass)
		if lights == PLAIN:
			geo.box(xf, Vector3(0.0, 0.74, sz * (hl + 0.01)), Vector3(1.6, 0.12, 0.05), CityPalette.c("marking"))
			geo.box(xf, Vector3(0.0, 2.78, sz * (hl - 0.05)), Vector3(1.1, 0.12, 0.08), CityPalette.c("marking"))   # destination strip
	# Roof unit.
	geo.box(xf, Vector3(0.0, 3.32, 0.0), Vector3(1.6, 0.26, 3.2), CityPalette.c("blue_grey"))
	if lights != PLAIN:
		LifeCars._hazards(geo, hw, hl, 3.1, hw - 0.3, hl - 0.6, lights == HAZARD_BRIGHT)
