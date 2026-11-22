extends TestCase
## Gait without physics, sideways and over obstacles: strafing feet never cross the body's centre line or come
## within the foot clearance of each other; a step's arc clears a curb under its path; a ledge above max_step is a
## wall (no foot lands on it) while one below is stepped onto.

const STANCE := 2.7
const DT := 1.0 / 60.0


func setup() -> void:
	_strafe()
	_step_over()
	_walls()
	finish()


func _flat(p: Vector3, _up: Vector3) -> Vector3:
	return Vector3(p.x, 0.0, p.z)


## Strafe right then left at walk and run strafe speeds, and diagonally: gaps and sides hold, feet keep up.
func _strafe() -> void:
	var g := Gait.new()
	var pos := Vector3.ZERO
	var steps := 0
	var was := [false, false]
	# [velocity, seconds]
	for leg: Array in [[Vector3(7.2, 0, 0), 4.0], [Vector3(-7.2, 0, 0), 4.0], [Vector3(13.2, 0, 0), 3.0], [Vector3(-13.2, 0, 0), 3.0],
			[Vector3(6.0, 0, -10.0), 3.0], [Vector3(-7.2, 0, 8.0), 3.0], [Vector3.ZERO, 1.5]]:
		var want: Vector3 = leg[0]
		var vel := Vector3.ZERO
		var min_gap := INF
		var min_side := INF
		var max_err := 0.0
		for frame in int(float(leg[1]) / DT):
			vel = vel.move_toward(want, 30.0 * DT)   # the controller's acceleration
			pos += vel * DT
			var homes := [pos + Vector3(-STANCE * 0.5, 0, 0), pos + Vector3(STANCE * 0.5, 0, 0)]
			g.update(DT, homes, Vector3.UP, vel, _flat)
			var l: Vector3 = g.feet[0]["pos"]
			var r: Vector3 = g.feet[1]["pos"]
			min_gap = minf(min_gap, r.x - l.x)
			min_side = minf(min_side, minf(pos.x - l.x, r.x - pos.x))
			for i in 2:
				max_err = maxf(max_err, ((g.feet[i]["pos"] as Vector3) - (homes[i] as Vector3)).length())
				if g.feet[i]["stepping"] and not was[i]:
					steps += 1
				was[i] = g.feet[i]["stepping"]
		var tag := "moving %s" % want
		check(min_gap >= g.foot_clearance - 0.05, "%s: the feet keep their sideways gap (least %.2f m, clearance %.2f)" % [tag, min_gap, g.foot_clearance])
		check(min_side > 0.3, "%s: no foot crosses the centre line of the body (closest %.2f m)" % [tag, min_side])
		check(max_err < 3.0, "%s: the feet keep up with the hips (worst %.2f m)" % [tag, max_err])
	check(steps > 30, "strafing steps (%d)" % steps)


## A 0.9 m curb across the path (z from -6 to -12): no frame of any step dips into the ground, on or off the curb.
func _curb(p: Vector3, _up: Vector3) -> Vector3:
	return Vector3(p.x, 0.9 if p.z < -6.0 and p.z > -12.0 else 0.0, p.z)


func _step_over() -> void:
	var g := Gait.new()
	var pos := Vector3.ZERO
	var worst := INF
	var on_curb := 0
	var peak := 0.0
	for speed: float in [3.0, 6.0, 12.0, 22.0]:
		pos = Vector3.ZERO
		g.reset([])
		for frame in int(20.0 / speed / DT):
			var vel := Vector3(0, 0, -speed)
			pos += vel * DT
			var floor_y := _curb(pos, Vector3.UP).y
			var homes := [_curb(pos + Vector3(-STANCE * 0.5, 0, 0), Vector3.UP), _curb(pos + Vector3(STANCE * 0.5, 0, 0), Vector3.UP)]
			g.update(DT, homes, Vector3.UP, vel, _curb, false, Vector3(pos.x, floor_y, pos.z))
			for i in 2:
				var p: Vector3 = g.feet[i]["pos"]
				worst = minf(worst, p.y - _curb(p, Vector3.UP).y)
				peak = maxf(peak, p.y)
				if not g.feet[i]["stepping"] and p.y > 0.85:
					on_curb += 1
	check(worst > -0.02, "a swinging foot never dips into the ground or the curb edge (worst %.3f m)" % worst)
	check(on_curb > 20, "the feet step onto the 0.9 m curb (%d planted frames)" % on_curb)
	check(peak > 0.9 + g.step_clearance * 0.9, "the arc tops the curb with clearance (peak %.2f m)" % peak)
	check(peak <= 0.9 + g.max_lift + 0.01, "and stays within the leg's lift (peak %.2f m)" % peak)


## A 2.0 m ledge ahead (z < -6), above max_step: walking up to it, then standing against it, no foot lands on top.
func _ledge(p: Vector3, _up: Vector3) -> Vector3:
	return Vector3(p.x, 2.0 if p.z < -6.0 else 0.0, p.z)


func _walls() -> void:
	var g := Gait.new()
	check(g.max_step < 2.0 and g.max_step > 0.9, "max step is between the curb and the wall (%.2f m)" % g.max_step)
	var pos := Vector3.ZERO
	var highest := 0.0
	for frame in 300:
		# The body stops 1.5 m short of the wall (its capsule would), still pushing forward.
		var vel := Vector3(0, 0, -12.0)
		if pos.z > -4.5:
			pos += vel * DT
		var homes := [Vector3(pos.x - STANCE * 0.5, 0, pos.z), Vector3(pos.x + STANCE * 0.5, 0, pos.z)]
		g.update(DT, homes, Vector3.UP, vel, _ledge, false, Vector3(pos.x, 0, pos.z))
		for i in 2:
			if not g.feet[i]["stepping"]:
				highest = maxf(highest, (g.feet[i]["pos"] as Vector3).y)
	check(highest < 0.05, "no foot plants on a ledge above max step (highest %.2f m)" % highest)
