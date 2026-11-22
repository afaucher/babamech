extends TestCase
## Gait without physics: a body moving over a flat floor at varied speeds. Planted feet never slide, steps alternate at
## a walk, feet stay near the hips at every speed, turning in place steps, and standing still settles the feet.

const STANCE := 1.2


func setup() -> void:
	var g := Gait.new()
	g.run_speed = 13.0
	var ground := func(p: Vector3, _up: Vector3) -> Vector3: return Vector3(p.x, 0.0, p.z)
	var pos := Vector3.ZERO
	var heading := 0.0
	var dt := 1.0 / 60.0
	var max_slip := 0.0
	var both_at_walk := 0
	var steps := 0
	var max_err := 0.0
	var prev := []
	var prev_stepping := [false, false]
	# Profile: accelerate 0 -> run -> 0 over 12 s, with a turn in the middle.
	for frame in int(12.0 / dt):
		var t := float(frame) * dt
		var k := clampf(sin(t / 12.0 * PI), 0.0, 1.0)
		var speed := k * 13.0
		if t > 5.0 and t < 7.0:
			heading += 0.8 * dt
		var fwd := Vector3(-sin(heading), 0, -cos(heading))
		var vel := fwd * speed
		pos += vel * dt
		var right := fwd.cross(Vector3.UP)
		var homes := [pos - right * STANCE * 0.5, pos + right * STANCE * 0.5]
		g.update(dt, homes, Vector3.UP, vel, ground)
		for i in 2:
			var f: Dictionary = g.feet[i]
			if not prev.is_empty() and not f["stepping"] and not prev_stepping[i]:
				max_slip = maxf(max_slip, ((f["pos"] as Vector3) - (prev[i] as Vector3)).length())
			if f["stepping"] and not prev_stepping[i]:
				steps += 1
			max_err = maxf(max_err, ((f["pos"] as Vector3) - (homes[i] as Vector3)).length())
			prev_stepping[i] = f["stepping"]
		if speed < 6.0 and g.stepping_count() > 1:
			both_at_walk += 1
		prev = g.positions()
	near(max_slip, 0.0, 1e-5, "planted feet never slide")
	eq(both_at_walk, 0, "never both feet in the air at a walk")
	check(steps > 20, "it steps (%d steps)" % steps)
	check(max_err < g.step_length * 1.6, "feet stay near the hips (worst %.2f m)" % max_err)
	# Turning in place steps; standing still settles back to the stance.
	var homes0 := [pos + Vector3(-0.6, 0, 0), pos + Vector3(0.6, 0, 0)]
	g.reset(homes0)
	var turn_steps := 0
	var was := false
	for frame in 180:
		heading += 1.5 / 60.0
		var fwd := Vector3(-sin(heading), 0, -cos(heading))
		var right := fwd.cross(Vector3.UP)
		var homes := [pos - right * 0.9, pos + right * 0.9]   # wider stance: hips swing round the centre
		g.update(dt, homes, Vector3.UP, Vector3.ZERO, ground)
		var now := g.stepping_count() > 0
		if now and not was:
			turn_steps += 1
		was = now
	check(turn_steps >= 2, "turning in place steps (%d)" % turn_steps)
	var fwd2 := Vector3(-sin(heading), 0, -cos(heading))
	var right2 := fwd2.cross(Vector3.UP)
	var still := [pos - right2 * 0.9, pos + right2 * 0.9]
	for frame in 120:
		g.update(dt, still, Vector3.UP, Vector3.ZERO, ground)
	for i in 2:
		check(((g.feet[i]["pos"] as Vector3) - (still[i] as Vector3)).length() <= g.settle_error + 0.01,
				"foot %d settles home" % i)
	check(g.stepping_count() == 0, "feet planted when still")
	finish()
