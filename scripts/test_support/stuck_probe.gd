class_name StuckProbe
extends RefCounted
## TESTS ONLY. Does a real mech get pinned at a spot? (tests/test_ramp_stuck.gd, tests/test_collision_survey.gd,
## docs/design/collision-survey.md.) A real MechController (MechSpawn: its capsule, move_and_slide settings and step-up)
## is stepped by hand (deterministic, no physics frames needed against static colliders): put at a start point, walked
## into a target (a corner) for APPROACH steps (the bot's way in), stopped, and from where it rests driven DRIVE steps each
## way along the given arc directions and back toward its start. Progress of at least MOVED m along a way counts as free;
## a spot is CORNERED when the mech is free fewer than FREE_MIN ways (a corner blocks at most 2 of 4 axis ways; a dead-end
## nook blocks 3), and PINNED when, cornered, it cannot even walk back toward where it came from.
##
## Arc coordinates are the deck's (RingFrame.world_to_arc: x along the axis, s along the floor, h up from the floor).
## corners(shape) lists the vertical convex corners of a box or convex collision shape in those coordinates (what the
## survey walks into).

const DT := 1.0 / 60.0
const SETTLE := 10           ## steps standing still after placing, and after the approach
const APPROACH := 60         ## steps walking into the target
const DRIVE := 30            ## steps driven each way from the resting point
const LAND := 240            ## steps at most waiting for a mech that walked off an edge to land
const MOVED := 0.5           ## m along a way that counts as progress
const FREE_MIN := 2          ## ways a mech must be free in (of 4)
const TOP_REACH := 2.5       ## m: a convex shape's corner counts the points this close as its top (corners())

var mech: MechController
var rk: RingFrame


func _init(m: MechController, ring_frame: RingFrame) -> void:
	mech = m
	rk = ring_frame
	mech.ring = ring_frame


## The capsule's radius (m).
func radius() -> float:
	return ((mech.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D).radius


## The resting place of the capsule at arc (x, s) when looking down from height `from_h`: just above the first surface a
## ray down hits (a static or animatable body), Vector3.INF where nothing is hit or the capsule does not fit there.
func stand(x: float, s: float, from_h: float) -> Vector3:
	var space := mech.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(rk.arc_to_world(x, s, from_h), rk.arc_to_world(x, s, from_h - 60.0))
	q.exclude = [mech.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty() or not (hit["collider"] is StaticBody3D or hit["collider"] is AnimatableBody3D):
		return Vector3.INF
	var p: Vector3 = hit["position"] + rk.up_at(hit["position"]) * 0.3
	if not fits(p):
		return Vector3.INF
	return p


## True when the mech's capsule standing at world point p touches nothing.
func fits(p: Vector3) -> bool:
	var cs := mech.get_node("Shape") as CollisionShape3D
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cs.shape
	var u := rk.up_at(p)
	var fwd := rk.tangent_at(p)
	sq.transform = Transform3D(Basis(fwd.cross(u), u, -fwd), p + u * cs.position.y)
	sq.exclude = [mech.get_rid()]
	return mech.get_world_3d().direct_space_state.intersect_shape(sq, 1).is_empty()


## Walk from `start` (world, from stand()) toward arc point `target` (x, s), rest, then drive along each of `ways` (arc
## unit directions), and back toward the start. {rest, rest_arc, moves: {way index | "back": m}, free: int, cornered,
## pinned, fell: bool} (see the end of the function; fell: walked off an edge and still falling, not measured).
func probe(start: Vector3, target: Vector2, ways: Array) -> Dictionary:
	place(start)
	for i in SETTLE:
		mech.step(DT)
	var a := rk.world_to_arc(mech.global_position)
	var to := target - Vector2(a.x, a.y)
	if to.length() > 0.3:
		face(to)
		mech.move_input = Vector2(0, 1)
		for i in APPROACH:
			mech.step(DT)
	mech.move_input = Vector2.ZERO
	for i in SETTLE:
		mech.step(DT)
	# Let a mech that walked off an edge land (up to LAND steps); one held up in the air (no motion) is measured as it is.
	var n := 0
	while not mech.grounded() and n < LAND:
		var before := mech.global_position
		mech.step(DT)
		n += 1
		if mech.global_position.distance_to(before) < 0.001:
			break
	if not mech.grounded() and mech.velocity.dot(rk.up_at(mech.global_position)) < -1.0:
		return {"rest": mech.global_position, "rest_arc": rk.world_to_arc(mech.global_position), "moves": {}, "free": 4,
				"cornered": false, "pinned": false, "fell": true}
	var rest := mech.global_position
	var moves := {}
	var free := 0
	var ra := rk.world_to_arc(rest)
	var sa := rk.world_to_arc(start)
	var back := Vector2(sa.x - ra.x, sa.y - ra.y)
	var all_ways := ways.duplicate()
	if back.length() > 0.3:
		all_ways.append(back.normalized())
	var back_prog := 0.0
	for wi in all_ways.size():
		var dv: Vector2 = all_ways[wi]
		place(rest)
		var a0 := rk.world_to_arc(rest)
		face(dv)
		mech.move_input = Vector2(0, 1)
		for i in DRIVE:
			mech.step(DT)
		mech.move_input = Vector2.ZERO
		var a1 := rk.world_to_arc(mech.global_position)
		var prog := (a1.x - a0.x) * dv.x + (a1.y - a0.y) * dv.y
		if wi >= ways.size():
			back_prog = prog
			moves["back"] = snappedf(prog, 0.01)
			continue
		moves[wi] = snappedf(prog, 0.01)
		if prog > MOVED:
			free += 1
	# Cornered: free fewer than FREE_MIN of `ways` (also a dead-end nook). Pinned: cornered AND it cannot even go back the
	# way it came (or it never moved off the start).
	var cornered := free < FREE_MIN
	var pinned := cornered and (back.length() <= 0.3 or back_prog <= MOVED)
	return {"rest": rest, "rest_arc": ra, "moves": moves, "free": free, "cornered": cornered, "pinned": pinned,
			"fell": false}


## Put the mech at world point p, upright to the deck, still, cool, with no wedge or climb in progress.
func place(p: Vector3) -> void:
	var u := rk.up_at(p)
	var fwd := rk.tangent_at(p)
	mech.global_transform = Transform3D(Basis(fwd.cross(u), u, -fwd), p)
	mech.velocity = Vector3.ZERO
	mech.move_input = Vector2.ZERO
	mech.thrust_input = false
	mech.heat = 0.0
	mech.shutdown = false
	mech._wedge_t = 0.0
	mech._wedge_nudge = 0.0
	mech._climbing = false


## Turn the mech to face arc direction dv (x along the ring's axis, s along the floor).
func face(dv: Vector2) -> void:
	var p := mech.global_position
	var u := rk.up_at(p)
	var fwd := Vector3.RIGHT * dv.x + rk.tangent_at(p) * dv.y
	fwd = (fwd - u * fwd.dot(u)).normalized()
	mech.global_basis = Basis(fwd.cross(u), u, -fwd)


## The vertical convex corners of collision shape cs (a box or a convex polygon; others give none) in deck arc
## coordinates: [{at: Vector2 (x, s), top: float, bot: float, u: Vector2, v: Vector2}], u and v the outward normals (arc,
## unit) of the two side faces meeting there. A corner is where the footprint's hull turns by more than 25 degrees.
static func corners(cs: CollisionShape3D, ring_frame: RingFrame) -> Array:
	var pts := PackedVector3Array()
	var xf := cs.global_transform
	if cs.shape is BoxShape3D:
		var h := (cs.shape as BoxShape3D).size * 0.5
		for k in 8:
			pts.append(xf * Vector3(h.x * (1 if k & 1 else -1), h.y * (1 if k & 2 else -1), h.z * (1 if k & 4 else -1)))
	elif cs.shape is ConvexPolygonShape3D:
		for p: Vector3 in (cs.shape as ConvexPolygonShape3D).points:
			pts.append(xf * p)
	else:
		return []
	var arc: Array[Vector3] = []
	var flat := PackedVector2Array()
	for p in pts:
		var a := ring_frame.world_to_arc(p)
		arc.append(a)
		flat.append(Vector2(a.x, a.y))
	var hull := Geometry2D.convex_hull(flat)      # closed: last == first, counter-clockwise
	if hull.size() < 4:
		return []
	hull.remove_at(hull.size() - 1)
	# Merge hull points closer than 5 cm (a box's top and bottom corner project onto one point).
	var merged := PackedVector2Array()
	for p in hull:
		if merged.is_empty() or merged[merged.size() - 1].distance_to(p) > 0.05:
			merged.append(p)
	if merged.size() > 2 and merged[0].distance_to(merged[merged.size() - 1]) <= 0.05:
		merged.remove_at(merged.size() - 1)
	var n := merged.size()
	if n < 3:
		return []
	var area := 0.0
	for i in n:
		area += merged[i].cross(merged[(i + 1) % n])
	var ccw := area > 0.0
	var out := []
	for i in n:
		var p := merged[i]
		var e0 := (p - merged[(i - 1 + n) % n]).normalized()
		var e1 := (merged[(i + 1) % n] - p).normalized()
		if absf(e0.angle_to(e1)) < deg_to_rad(25.0):
			continue
		# Outward normal of an edge: to the right of a counter-clockwise walk.
		var n0 := Vector2(e0.y, -e0.x) if ccw else Vector2(-e0.y, e0.x)
		var n1 := Vector2(e1.y, -e1.x) if ccw else Vector2(-e1.y, e1.x)
		# A box's corner is as tall as the box. A convex shape's may lean (a buttress, a parapet's end): its top is the
		# highest point within a capsule's reach (TOP_REACH) of the corner.
		var reach := 0.3 if cs.shape is BoxShape3D else TOP_REACH
		var top := -INF
		var bot := INF
		for a: Vector3 in arc:
			var dd := Vector2(a.x, a.y).distance_to(p)
			if dd < reach:
				top = maxf(top, a.z)
			if dd < 0.3:
				bot = minf(bot, a.z)
		if top == -INF or bot == INF:
			continue
		out.append({"at": p, "top": top, "bot": bot, "u": n0, "v": n1})
	return out
