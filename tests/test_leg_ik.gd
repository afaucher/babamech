extends TestCase
## LegIK: bone lengths hold, the knee bends toward the pole (forward), the ankle sits behind the foot (reverse joint),
## and out-of-reach targets clamp.


func setup() -> void:
	var up := Vector3.UP
	var fwd := Vector3.FORWARD
	var lt := 1.1
	var ls := 1.25
	var lm := 0.8
	var lean := 0.3
	var hip := Vector3(0.4, 2.4, 0)
	for foot in [Vector3(0.4, 0, 0), Vector3(0.4, 0, -0.9), Vector3(0.4, 0.3, 0.8), Vector3(0.6, -0.2, -0.3)]:
		var r := LegIK.solve_leg(hip, foot, lt, ls, lm, up, fwd, lean)
		check(r["reached"], "foot %s reachable" % foot)
		near(((r["knee"] as Vector3) - hip).length(), lt, 1e-3, "thigh length")
		near(((r["ankle"] as Vector3) - (r["knee"] as Vector3)).length(), ls, 1e-3, "shin length")
		near(((r["foot"] as Vector3) - (r["ankle"] as Vector3)).length(), lm, 1e-3, "tarsus length")
		check(((r["foot"] as Vector3) - foot).length() < 1e-3, "foot lands on target")
		# Knee in front of the hip->ankle line; ankle behind the foot (the reverse "knee").
		var mid := (hip + (r["ankle"] as Vector3)) * 0.5
		check(((r["knee"] as Vector3) - mid).dot(fwd) > 0.0, "knee bends forward")
		check(((r["ankle"] as Vector3) - foot).dot(fwd) < 0.0, "ankle sits behind the foot")
	var far := LegIK.solve_leg(hip, Vector3(0.4, -6.0, 0), lt, ls, lm, up, fwd, lean)
	check(not far["reached"], "a far target is not reached")
	near(((far["ankle"] as Vector3) - hip).length(), (lt + ls) * 0.9999, 1e-3, "clamped to full reach")
	near(((far["knee"] as Vector3) - hip).length(), lt, 1e-3, "thigh length when clamped")
	var tb := LegIK.solve_two_bone(Vector3.ZERO, Vector3(0, -1, 0), 1.0, 1.0, Vector3(0, 0, -1))
	check((tb["joint"] as Vector3).z < 0.0, "two-bone joint bends toward the pole")
	finish()
