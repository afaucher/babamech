extends TestCase
## LegIK: bone lengths hold, the knee bends toward the pole (forward, or back with bend -1: MechModel.leg_bend), the
## ankle sits on the other side of the foot (the reverse joint), and out-of-reach targets clamp.


func setup() -> void:
	var up := Vector3.UP
	var fwd := Vector3.FORWARD
	var lt := 1.1
	var ls := 1.25
	var lm := 0.8
	var lean := 0.3
	var hip := Vector3(0.4, 2.4, 0)
	for bend: float in [1.0, -1.0]:
		for foot in [Vector3(0.4, 0, 0), Vector3(0.4, 0, -0.9), Vector3(0.4, 0.3, 0.8), Vector3(0.6, -0.2, -0.3)]:
			var r := LegIK.solve_leg(hip, foot, lt, ls, lm, up, fwd, lean, bend)
			var tag := "bend %+d, foot %s" % [int(bend), foot]
			check(r["reached"], tag + " reachable")
			near(((r["knee"] as Vector3) - hip).length(), lt, 1e-3, tag + " thigh length")
			near(((r["ankle"] as Vector3) - (r["knee"] as Vector3)).length(), ls, 1e-3, tag + " shin length")
			near(((r["foot"] as Vector3) - (r["ankle"] as Vector3)).length(), lm, 1e-3, tag + " tarsus length")
			check(((r["foot"] as Vector3) - foot).length() < 1e-3, tag + " foot lands on target")
			# Knee on the bend side of the hip->ankle line; ankle on the other side of the foot (the reverse "knee").
			var mid := (hip + (r["ankle"] as Vector3)) * 0.5
			check(((r["knee"] as Vector3) - mid).dot(fwd) * bend > 0.0, tag + " knee bends along the bend")
			check(((r["ankle"] as Vector3) - foot).dot(fwd) * bend < 0.0, tag + " ankle sits against the bend from the foot")
	# The default is bend +1 (callers that don't pass it keep the old leg).
	var d := LegIK.solve_leg(hip, Vector3(0.4, 0, 0), lt, ls, lm, up, fwd, lean)
	check(((d["knee"] as Vector3) - hip).dot(fwd) > 0.0, "default bend: knee forward")
	var far := LegIK.solve_leg(hip, Vector3(0.4, -6.0, 0), lt, ls, lm, up, fwd, lean)
	check(not far["reached"], "a far target is not reached")
	near(((far["ankle"] as Vector3) - hip).length(), (lt + ls) * 0.9999, 1e-3, "clamped to full reach")
	near(((far["knee"] as Vector3) - hip).length(), lt, 1e-3, "thigh length when clamped")
	var tb := LegIK.solve_two_bone(Vector3.ZERO, Vector3(0, -1, 0), 1.0, 1.0, Vector3(0, 0, -1))
	check((tb["joint"] as Vector3).z < 0.0, "two-bone joint bends toward the pole")
	finish()
