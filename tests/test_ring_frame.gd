extends TestCase
## RingFrame: radial up, floor height, arc <-> world round trips, bases.


func setup() -> void:
	var r := RingFrame.new(100.0)
	var o := Vector3.ZERO
	check(r.up_at(o).is_equal_approx(Vector3.UP), "up at the origin is +Y")
	near(r.height(o), 0.0, 1e-5, "origin is on the floor")
	near(r.height(Vector3(5, 3, 0)), 3.0, 1e-4, "height straight above the origin")
	for s in [-60.0, -10.0, 0.0, 25.0, 90.0]:
		for x in [-20.0, 0.0, 7.0]:
			var p := r.arc_to_world(x, s, 0.0)
			near(r.height(p), 0.0, 1e-4, "floor point s=%s is on the floor" % s)
			var back := r.world_to_arc(r.arc_to_world(x, s, 4.0))
			near(back.x, x, 1e-4, "x round trip")
			near(back.y, s, 1e-3, "s round trip")
			near(back.z, 4.0, 1e-4, "h round trip")
			var up := r.up_at(p)
			near(up.x, 0.0, 1e-6, "up has no axial component")
			near(up.dot(r.tangent_at(p)), 0.0, 1e-5, "up is perpendicular to the floor tangent")
			# Moving up from a floor point heads toward the axis.
			check(r.dist_to_axis(p + up) < r.dist_to_axis(p), "up points toward the axis")
	# The floor curves upward along the spin direction and is level along the axis.
	check(r.arc_to_world(0.0, 40.0).y > 1.0, "floor rises along +s")
	check(r.arc_to_world(0.0, -40.0).y > 1.0, "floor rises along -s")
	near(r.arc_to_world(30.0, 0.0).y, 0.0, 1e-6, "floor is level along x")
	var b := r.basis_at(r.arc_to_world(0.0, 30.0), Vector3(1, 0, -1))
	near(b.determinant(), 1.0, 1e-4, "basis is a rotation")
	check(b.y.is_equal_approx(r.up_at(r.arc_to_world(0.0, 30.0))), "basis Y is up")
	near(b.x.dot(b.z), 0.0, 1e-5, "basis orthogonal")
	var ba := r.basis_at_arc(20.0)
	check((-ba.z).is_equal_approx(r.tangent_at(r.arc_to_world(0.0, 20.0))), "basis_at_arc faces +s")
	finish()
