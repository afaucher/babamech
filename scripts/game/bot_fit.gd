class_name BotFit
extends RefCounted
## Does a mech of a given chassis FIT somewhere in the BUILT world (collision, not plan data)? Static physics probes with
## the chassis' real collision capsule (MechCatalog movement capsule_radius / capsule_height), used by the mission bot to
## keep a wide chassis (the Bulwark: 3.6 m capsule) off road lines it cannot pass (BotRoutePlanner.fit_body) and by the
## Bulwark world-fit survey (tests/test_bulwark_world_fit.gd). Input-side only: nothing here changes the world or travels.
##
## A probe is the capsule standing upright on a deck (that deck's RingFrame: world positions, its own arc coordinates),
## its bottom LIFT m above the floor (curbs, the 0.2 m courts and lane bands are stepped onto, not walked round: the
## capsule's round bottom clears them at its edge), against static collision only (StaticBody3D: buildings, walls,
## parapets, pillars, masts, depots; mechs, enemies, the knockable props and moving bodies (AnimatableBody3D: trams,
## doors) are not obstacles).

const LIFT := 0.5            ## m: the capsule's bottom above the floor in a probe
const STEP := 2.0            ## m between probes along a line
const WIDTH_H: Array[float] = [1.2, 4.0, 7.5]   ## m above the floor the width rays run (legs, hull, pods / top)
const WIDTH_MAX := 30.0      ## m each way a width ray looks at most


static func radius_of(chassis: String) -> float:
	return float(MechCatalog.movement(chassis)["capsule_radius"])


static func height_of(chassis: String) -> float:
	return float(MechCatalog.movement(chassis)["capsule_height"])


## True when the capsule (radius r, height h) standing at arc (x, s) of `ring`, bottom `h0 + LIFT` above the floor, touches
## no static collision.
static func clear_at(space: PhysicsDirectSpaceState3D, ring: RingFrame, x: float, s: float, r: float, h: float = 8.0,
		h0: float = 0.0) -> bool:
	var p := ring.arc_to_world(x, s, h0 + LIFT + h * 0.5)
	var up := ring.up_at(p)
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = maxf(h, 2.0 * r)
	q.shape = cap
	var fwd := ring.tangent_at(p)
	q.transform = Transform3D(Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized(), p)
	for hit: Dictionary in space.intersect_shape(q, 8):
		if _blocks(hit.get("collider")):
			return false
	return true


## The share (0..1) of probes every STEP m from a to b (arc, deck `ring`) where the capsule does not fit, and the first
## blocked point (Vector2.INF if none).
static func line_fit(space: PhysicsDirectSpaceState3D, ring: RingFrame, a: Vector2, b: Vector2, r: float,
		h: float = 8.0) -> Dictionary:
	var n := maxi(int(ceil(a.distance_to(b) / STEP)), 1)
	var bad := 0
	var first := Vector2.INF
	for i in n + 1:
		var p := a.lerp(b, float(i) / float(n))
		if not clear_at(space, ring, p.x, p.y, r, h):
			bad += 1
			if first == Vector2.INF:
				first = p
	return {"bad": float(bad) / float(n + 1), "first": first, "probes": n + 1}


## A ramp (or any sloped way) from arc a to arc b on deck `ring`'s arc frame: at each probe the walking surface is found
## by a ray down from 4 m above the straight line between the ends' surface heights `ha` and `hb` (m above that deck's
## floor), and the capsule stands on it. Same result as line_fit, plus the
## lowest surface found ("h_min") and the probes where no surface was found ("holes").
static func slope_fit(space: PhysicsDirectSpaceState3D, ring: RingFrame, a: Vector2, b: Vector2, r: float, h: float,
		ha: float, hb: float) -> Dictionary:
	var n := maxi(int(ceil(a.distance_to(b) / STEP)), 1)
	var bad := 0
	var holes := 0
	var first := Vector2.INF
	for i in n + 1:
		var p := a.lerp(b, float(i) / float(n))
		var top := lerpf(ha, hb, float(i) / float(n)) + 4.0
		var q := PhysicsRayQueryParameters3D.create(ring.arc_to_world(p.x, p.y, top), ring.arc_to_world(p.x, p.y, top - 9.0))
		var hit := _static_ray(space, q)
		if hit.is_empty():
			holes += 1
			continue
		var sh := ring.height(hit["position"])
		if not clear_at(space, ring, p.x, p.y, r, h, sh):
			bad += 1
			if first == Vector2.INF:
				first = p
	return {"bad": float(bad) / float(n + 1), "first": first, "probes": n + 1, "holes": holes}


## The clear width (m) across direction `dir` (arc, unit) at arc point p: the least, over WIDTH_H, of the distance
## between the nearest static hits left and right (WIDTH_MAX each way when nothing is hit).
static func width_at(space: PhysicsDirectSpaceState3D, ring: RingFrame, p: Vector2, dir: Vector2, h0: float = 0.0) -> float:
	var side := Vector2(-dir.y, dir.x)
	var best := INF
	for hh: float in WIDTH_H:
		var o := ring.arc_to_world(p.x, p.y, h0 + hh)
		var w := 0.0
		for sg: float in [-1.0, 1.0]:
			var far := ring.arc_to_world(p.x + side.x * sg * WIDTH_MAX, p.y + side.y * sg * WIDTH_MAX, h0 + hh)
			var q := PhysicsRayQueryParameters3D.create(o, far)
			q.hit_from_inside = false
			var hit := _static_ray(space, q)
			w += WIDTH_MAX if hit.is_empty() else o.distance_to(hit["position"])
		best = minf(best, w)
	return best


## A ray that skips non-static colliders (mechs, enemies): re-cast past each one, at most a few times.
static func _static_ray(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D) -> Dictionary:
	var ex: Array[RID] = []
	for i in 6:
		q.exclude = ex
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return hit
		if _blocks(hit.get("collider")):
			return hit
		ex.append(hit["rid"])
	return {}


## What a probe counts as an obstacle: static collision only (an AnimatableBody3D is a StaticBody3D subclass: moving
## things such as trams and doors are left out).
static func _blocks(c: Variant) -> bool:
	return c is StaticBody3D and not c is AnimatableBody3D
