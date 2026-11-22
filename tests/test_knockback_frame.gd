extends TestCase
## Knockback in an injected ground frame (CombatTarget.up / ground_y): a dummy on a tilted deck, shoved along the
## surface, slides on its own ground plane and comes to rest; lifted off it, it falls back to that plane (along -up).

const DT := 1.0 / 60.0


func setup() -> void:
	var up := Vector3.UP.rotated(Vector3.RIGHT, 0.4)
	var along := Vector3.FORWARD.rotated(Vector3.RIGHT, 0.4)     # in the tilted plane
	var home := Vector3(3, 7, -2)
	var d := TargetDummy.new()
	d.mass_class = "light"
	d.up = up
	d.transform = Transform3D(Basis(Vector3.RIGHT, 0.4), home)
	add_child(d)
	await frames(1)
	near(d.ground_y, home.dot(up), 1e-5, "ground plane through home, along up")
	d.apply_impulse(along * 5.0, "test")
	var worst := 0.0
	for i in 120:
		d.tick(DT)
		worst = maxf(worst, absf(d.global_position.dot(up) - d.ground_y))
	check(worst < 1e-3, "shoved along the surface it stays on its ground plane (off by %.4f m)" % worst)
	check(not d.knock.moving(), "it comes to rest")
	var slid := d.global_position - home
	check(slid.length() > 1.0, "it slid (%.2f m)" % slid.length())
	check(absf(slid.normalized().dot(along)) > 0.999, "along the surface, the way it was shoved")
	# Lifted: rises off the plane, falls back along -up, and rests on it.
	var rest := d.global_position
	d.apply_impulse(up * 6.0, "test")
	var peak := 0.0
	for i in 180:
		d.tick(DT)
		peak = maxf(peak, d.global_position.dot(up) - d.ground_y)
	check(peak > 1.0, "lifted off the plane (%.2f m)" % peak)
	near(d.global_position.dot(up), d.ground_y, 1e-3, "fell back to its ground plane")
	check(d.global_position.distance_to(rest) < 1e-3, "straight back down its own up (%.4f m)" % d.global_position.distance_to(rest))
	check(not d.knock.moving(), "at rest again")
	d.queue_free()
	finish()
