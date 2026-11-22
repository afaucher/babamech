class_name Gait
extends RefCounted
## Procedural foot planting for a biped (docs/design/vertical-slice.md S1). Each foot stays PLANTED at a fixed world
## position until it falls too far from its home spot under the hip, then steps along an arc to where its home will be
## half a step later. Stride and cadence scale with speed, so the same rules cover a slow walk, a run and every speed
## change in between; turning moves the homes, so turning in place steps too. At most one foot steps at a time at a
## walk; at a run the next step may start once the other foot is halfway down.
##
## Presentation only (Net LOCAL): every machine runs it from the mech's synced motion, so it never needs sending.
## Pure math + a ground callback: no nodes, testable without physics.

var step_length := 2.6       ## longest stride (m), reached at run speed
var min_stride := 0.7        ## shortest stride (m)
var step_time := 0.55        ## seconds per step at a standstill/walk
var run_step_time := 0.32    ## seconds per step at run speed
var step_height := 0.8       ## foot lift at a full stride (m)
var run_speed := 13.0        ## speed (m/s) that counts as a full run
var settle_time := 0.3       ## seconds standing still before the feet re-plant to their stance
var settle_error := 0.18     ## how far off home (m) a foot may rest after settling

## Per foot: {pos, stepping, from, to, t, dur, lift}
var feet: Array = []
var _still := 0.0


## Plant every foot at its home.
func reset(homes: Array) -> void:
	feet.clear()
	for h: Vector3 in homes:
		feet.append({"pos": h, "stepping": false, "from": h, "to": h, "t": 0.0, "dur": step_time, "lift": 0.0})
	_still = 0.0


func positions() -> Array:
	var out: Array = []
	for f: Dictionary in feet:
		out.append(f["pos"])
	return out


func stepping_count() -> int:
	var n := 0
	for f: Dictionary in feet:
		if f["stepping"]:
			n += 1
	return n


## 0 when every foot is planted, up to 1 at the top of a step's arc (for body bob).
func lift_amount() -> float:
	var m := 0.0
	for f: Dictionary in feet:
		if f["stepping"]:
			m = maxf(m, sin(PI * float(f["t"])))
	return m


## Advance by `delta`. `homes`: the ground point under each hip now (world). `up`: local up. `vel`: body velocity.
## `ground`: Callable(point: Vector3, up: Vector3) -> Vector3, the ground under a point. `airborne`: feet hang.
func update(delta: float, homes: Array, up: Vector3, vel: Vector3, ground: Callable, airborne: bool = false) -> void:
	if feet.size() != homes.size():
		reset(homes)
	var flat := vel - up * vel.dot(up)
	var speed := flat.length()
	var k := clampf(speed / run_speed, 0.0, 1.0)
	var dur := lerpf(step_time, run_step_time, k)
	var stride := clampf(speed * dur * 2.0, min_stride, step_length)
	var trigger := stride * 0.5
	var moving := speed > 0.25
	_still = 0.0 if moving else _still + delta
	if airborne:
		for i in feet.size():
			var f: Dictionary = feet[i]
			f["stepping"] = false
			f["pos"] = (f["pos"] as Vector3).lerp(homes[i], clampf(delta * 8.0, 0.0, 1.0))
		return
	# Feet furthest from home get first pick of the step.
	var order: Array = range(feet.size())
	order.sort_custom(func(a: int, b: int) -> bool: return _err(a, homes, up) > _err(b, homes, up))
	for i: int in order:
		var f: Dictionary = feet[i]
		var target: Vector3 = ground.call((homes[i] as Vector3) + flat * dur * 0.5, up)
		if f["stepping"]:
			f["t"] = float(f["t"]) + delta / float(f["dur"])
			f["to"] = target
			if float(f["t"]) >= 1.0:
				f["stepping"] = false
				f["t"] = 0.0
				f["pos"] = target
			else:
				var t := float(f["t"])
				var e := t * t * (3.0 - 2.0 * t)
				f["pos"] = (f["from"] as Vector3).lerp(target, e) + up * float(f["lift"]) * sin(PI * t)
			continue
		var err := _err(i, homes, up)
		if err > step_length * 3.0:   # teleported / knocked far: re-plant at once
			f["pos"] = target
			continue
		var want := err > trigger or (_still > settle_time and err > settle_error)
		if want and _may_step(i, k):
			f["stepping"] = true
			f["t"] = 0.0
			f["dur"] = dur
			f["from"] = f["pos"]
			f["to"] = target
			var dist := ((f["pos"] as Vector3) - target).length()
			f["lift"] = step_height * clampf(dist / step_length, 0.25, 1.0)


## Horizontal distance (along the local floor) of foot i from its home.
func _err(i: int, homes: Array, up: Vector3) -> float:
	var d: Vector3 = (feet[i]["pos"] as Vector3) - (homes[i] as Vector3)
	return (d - up * d.dot(up)).length()


func _may_step(i: int, run_k: float) -> bool:
	for j in feet.size():
		if j == i or not feet[j]["stepping"]:
			continue
		# At a walk, wait for the other foot to land; at a run, overlap once it is halfway down.
		if run_k < 0.6 or float(feet[j]["t"]) < 0.5:
			return false
	return true
