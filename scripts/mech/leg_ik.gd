class_name LegIK
extends RefCounted
## Inverse kinematics for the chicken-style leg (thigh, shin, tarsus). Pure math, any space (pass consistent vectors).
##
## The leg reads like a bird's: the thigh reaches FORWARD to a hidden knee, the shin runs BACK down to the ankle (the
## visible "reverse knee"), and the tarsus leans forward again to the foot. The tarsus keeps a fixed lean from the
## local up, which turns the three-bone chain into a two-bone solve from the hip to the ankle, bent toward `fwd`.


## Two-bone solve: the joint between bones of length l1 and l2 for a chain from `root` toward `target`, bent toward
## `pole`. A target out of reach is clamped onto the reachable shell along the same direction.
## Returns {joint, end, reached}.
static func solve_two_bone(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Dictionary:
	var to := target - root
	var d := to.length()
	var dir := to / d if d > 1e-6 else Vector3.DOWN
	var d_min := absf(l1 - l2) + 1e-4
	var d_max := (l1 + l2) * 0.9999
	var dc := clampf(d, d_min, d_max)
	var a := (l1 * l1 - l2 * l2 + dc * dc) / (2.0 * dc)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var bend := pole - dir * pole.dot(dir)
	if bend.length_squared() < 1e-10:
		bend = dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.UP)
	bend = bend.normalized()
	return {"joint": root + dir * a + bend * h, "end": root + dir * dc, "reached": d >= d_min and d <= d_max}


## The whole leg: hip and wanted foot position, segment lengths, the leg's local up and forward, and the tarsus lean
## (radians forward of straight down, ankle to foot). Returns {knee, ankle, foot, reached}; `foot` differs from the
## input only when the target was out of reach.
static func solve_leg(hip: Vector3, foot: Vector3, thigh: float, shin: float, tarsus: float, up: Vector3,
		fwd: Vector3, tarsus_lean: float) -> Dictionary:
	var ankle_want := foot + up * (tarsus * cos(tarsus_lean)) - fwd * (tarsus * sin(tarsus_lean))
	var r := solve_two_bone(hip, ankle_want, thigh, shin, fwd)
	var ankle: Vector3 = r["end"]
	return {"knee": r["joint"], "ankle": ankle, "foot": ankle + (foot - ankle_want), "reached": r["reached"]}
