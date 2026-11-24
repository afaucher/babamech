class_name Gait
extends RefCounted
## Procedural foot planting for a biped (docs/design/vertical-slice.md S1). Each foot stays PLANTED at a fixed world
## position until it falls too far from its home spot under the hip, then steps along an arc to where its home will be
## half a step later. Stride and cadence scale with speed (the step time follows the square root of the speed share, so
## slow walks take unhurried steps and the cadence quickens toward the run), so the same rules cover a slow walk, a run
## and every speed change in between; turning moves the homes, so turning in place steps too. At most one foot steps at a time at a
## walk; at a run the next step may start once the other foot is halfway down.
##
## Sideways (strafe): the legs abduct less than they swing, and the feet must not land on each other. The sideways
## lead of a step is limited to half of (stance - foot_clearance); when the speed asks for more, the steps get
## quicker (a shuffle, down to min_step_time) instead of longer, and a target is always kept foot_clearance to its own
## side of the other foot. MechRig avoids that shuffle with the hip twist: it turns the hips (and so the homes, and the
## `right` derived from them) toward the travel direction, so a strafe is walked as forward or diagonal strides in the
## legs' frame; the shuffle rules only remain for whatever sideways share is left.
##
## Feet turn only while they swing: `facing` (world, set by the caller each update; zero = not tracked) is where the
## legs point, a planted foot keeps the "dir" it landed with and a swinging one turns toward `facing`.
##
## Step events (for audio and effects): every step that lands emits `stepped(foot, info)` and leaves the same info on
## the foot as "last": {kind, length, weight, pos}. kind "stride" = a walking step (moving, at least half the stride
## the speed asks for), "correction" = a short step while moving (re-placing a foot, a hip twist), "settle" = re-planting
## to the stance at a standstill, "land" = touching down after a fall. length = horizontal distance the foot moved (m),
## weight = length / step_length (0..1). Each foot also carries "kind" and "length" (planned) from the moment it lifts.
##
## Obstacles: a step's arc is raised so the foot clears the highest ground under its path by step_clearance (up to
## max_lift, what the leg can fold). A ledge more than max_step above or below the body's floor is a wall or a drop,
## not a foothold: the foot stays on the body's level instead.
##
## Presentation only (Net LOCAL): every machine runs it from the mech's synced motion, so it never needs sending.
## Pure math + a ground callback: no nodes, testable without physics.

## Tuned for MechController's defaults (walk 12, run 22 m/s) and the default 8 m mech: a planted foot triggers a step
## stride/2 behind its hip and lands speed * step time / 2 ahead of it. At a walk the foot must stay planted longer than
## a step takes (step_length > speed * step time, so one foot is always down); both ends must stay in the leg's reach
## (about 2.6 m ahead of the hip and 2.0 m behind it at mech scale 2).
var step_length := 4.0       ## longest stride (m): the trigger distance is half of it
var min_stride := 0.7        ## shortest stride (m)
var step_time := 0.45        ## seconds per step at a standstill
var run_step_time := 0.21    ## seconds per step at run speed
var min_step_time := 0.16    ## fastest step (s): sideways shuffles shorten the step down to this
var step_height := 1.0       ## foot lift at a full stride (m)
var run_speed := 22.0        ## speed (m/s) that counts as a full run (MechRig copies the controller's)
var land_time := 0.18        ## seconds for the feet to re-plant after landing from the air
var settle_time := 0.3       ## seconds standing still before the feet re-plant to their stance
var settle_error := 0.18     ## how far off home (m) a foot may rest after settling
var foot_clearance := 1.3    ## least sideways gap between the two feet (m, centre to centre)
var step_clearance := 0.25   ## how far a swinging foot clears the ground under its path (m)
var max_step := 1.3          ## highest ledge above / below the body's floor a foot may stand on (m)
var max_lift := 1.45         ## highest a swinging foot may rise above the line from its start to its target (m)
var overlap_k := 0.6         ## share of run_speed from which the next step may start before the other foot lands (once it
                             ## is halfway down); below it, at a walk, one foot steps at a time. 0 = always (long legs at a
                             ## speed that is a jog for their size: the Bulwark)
var reach_err := INF         ## m: a planted foot this far from its home steps at once, whatever the other foot does (the
                             ## leg's reach: at a start from standing both feet want to go together, and the one that waits
                             ## must not be left behind out of reach); INF = never forced (the Strider)

signal stepped(foot: int, info: Dictionary)

## Per foot: {pos, stepping, from, to, t, dur, lift, dir, kind, length, last}
var feet: Array = []
var facing := Vector3.ZERO   ## where the legs point (world, horizontal); zero = feet are not turned
var _still := 0.0
var _airborne := false       ## the last update was airborne: the next grounded one re-plants every foot


## Authority (scripts/net/net.gd): presentation only, recomputed on every machine from the mech's motion (own mech or
## puppet); the tuning is fixed at spawn.
func net_fields() -> Dictionary:
	return {"step_length": Net.SPAWN, "min_stride": Net.SPAWN, "step_time": Net.SPAWN, "run_step_time": Net.SPAWN,
		"min_step_time": Net.SPAWN, "step_height": Net.SPAWN, "run_speed": Net.SPAWN, "land_time": Net.SPAWN,
		"settle_time": Net.SPAWN, "settle_error": Net.SPAWN, "foot_clearance": Net.SPAWN, "step_clearance": Net.SPAWN,
		"max_step": Net.SPAWN, "max_lift": Net.SPAWN, "overlap_k": Net.SPAWN, "reach_err": Net.SPAWN, "feet": Net.LOCAL, "facing": Net.LOCAL, "_still": Net.LOCAL,
		"_airborne": Net.LOCAL}


## Plant every foot at its home.
func reset(homes: Array) -> void:
	feet.clear()
	_airborne = false
	for h: Vector3 in homes:
		feet.append({"pos": h, "stepping": false, "from": h, "to": h, "t": 0.0, "dur": step_time, "lift": 0.0,
				"dir": facing, "dir_from": facing, "kind": "settle", "length": 0.0, "last": {}})
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
## `ground`: Callable(point: Vector3, up: Vector3) -> Vector3, the ground under a point. `airborne`: the feet hang at
## `homes`, which the caller then passes as points under the hips relative to the body (MechRig), not on the ground;
## the first grounded update after that re-plants every foot over `land_time`.
## `floor_ref`: a point on the floor the body stands on (Vector3), for the max_step rule; null = no rule.
func update(delta: float, homes: Array, up: Vector3, vel: Vector3, ground: Callable, airborne: bool = false,
		floor_ref: Variant = null) -> void:
	if feet.size() != homes.size():
		reset(homes)
	var flat := vel - up * vel.dot(up)
	var speed := flat.length()
	var k := clampf(speed / run_speed, 0.0, 1.0)
	var dur := lerpf(step_time, run_step_time, sqrt(k))
	var lead := flat * dur * 0.5
	# Sideways: limit the lead so the feet keep their gap; step quicker rather than further.
	var right := Vector3.ZERO
	var side_trigger := INF   # a foot this far sideways from its home steps, whatever the stride
	var shuffle := false
	if feet.size() == 2:
		var across: Vector3 = (homes[1] as Vector3) - (homes[0] as Vector3)
		across -= up * across.dot(up)
		if across.length() > 1e-4:
			right = across.normalized()
			var max_side := maxf((across.length() - foot_clearance) * 0.5, 0.0)
			side_trigger = maxf(max_side * 0.6, 0.2)
			var side_lead := absf(lead.dot(right))
			# A foot is left behind by its lead and again by its own swing: about 0.9 of a step's sideways travel.
			if side_lead * 1.8 > max_side and side_lead > 1e-5:
				shuffle = true
				var quick := clampf(dur * max_side / (side_lead * 1.8), min_step_time, dur)
				lead *= quick / dur
				dur = quick
				side_lead = absf(lead.dot(right))
				if side_lead > max_side:
					lead -= right * lead.dot(right) * (1.0 - max_side / side_lead)
	var stride := clampf(speed * dur * 2.0, min_stride, step_length)
	var trigger := stride * 0.5
	if shuffle:   # step as soon as the foot is a lead behind, or it would trail into the other foot
		trigger = minf(trigger, maxf(lead.length() * 0.6, 0.2))
	var moving := speed > 0.25
	_still = 0.0 if moving else _still + delta
	if airborne:
		_airborne = true
		for i in feet.size():
			var f: Dictionary = feet[i]
			f["stepping"] = false
			f["t"] = 0.0
			if facing.length_squared() > 1e-6:
				f["dir"] = facing   # hanging feet point with the legs
			if ((f["pos"] as Vector3) - (homes[i] as Vector3)).length() > step_length * 3.0:
				f["pos"] = homes[i]   # placed / thrown far: hang at once
			else:
				f["pos"] = (f["pos"] as Vector3).lerp(homes[i], clampf(delta * 8.0, 0.0, 1.0))
		return
	if _airborne:   # touchdown: every foot reaches down from where it hung to its foothold, together
		_airborne = false
		for i in feet.size():
			var f: Dictionary = feet[i]
			f["stepping"] = true
			f["t"] = 0.0
			f["dur"] = land_time
			f["from"] = f["pos"]
			f["to"] = _target(i, homes[i], lead, up, ground, right, floor_ref)
			f["lift"] = 0.0
			f["tight"] = 0.0
			_lift_off(f, "land", up)
	# Feet furthest from home get first pick of the step. Moving sideways, the foot on the side the body is moving
	# toward goes first: the body is closing on it, while the other one is only left behind.
	var centre := Vector3.ZERO
	for h: Vector3 in homes:
		centre += h / float(homes.size())
	var urgency := func(i: int) -> float:
		return _err(i, homes, up) + (0.5 if ((homes[i] as Vector3) - centre).dot(lead) > 0.05 else 0.0)
	var order: Array = range(feet.size())
	order.sort_custom(func(a: int, b: int) -> bool: return urgency.call(a) > urgency.call(b))
	for i: int in order:
		var f: Dictionary = feet[i]
		var target := _target(i, homes[i], lead, up, ground, right, floor_ref)
		if f["stepping"]:
			f["t"] = float(f["t"]) + delta / float(f["dur"])
			if absf((target - (f["to"] as Vector3)).dot(up)) > 0.1:   # the target changed level mid-step: redo the arc
				var redo := _lift_for(f["from"], target, up, ground)
				f["lift"] = maxf(float(f["lift"]), redo.x)
				f["tight"] = maxf(float(f.get("tight", 0.0)), redo.y)
			f["to"] = target
			_turn(f, up)
			if float(f["t"]) >= 1.0:
				f["stepping"] = false
				f["t"] = 0.0
				f["pos"] = target
				_landed(i, f, up)
			else:
				f["pos"] = _swing(f["from"], target, up, float(f["lift"]), float(f["t"]), float(f.get("tight", 0.0)))
			continue
		var err := _err(i, homes, up)
		if err > step_length * 3.0:   # teleported / knocked far: re-plant at once
			f["pos"] = target
			continue
		var want := err > trigger or (_still > settle_time and err > settle_error)
		var crowding := false   # this foot is well inside its home, toward the other foot: step now
		if moving and right != Vector3.ZERO:
			var side := ((f["pos"] as Vector3) - (homes[i] as Vector3)).dot(right)
			want = want or absf(side) > side_trigger
			crowding = side * (1.0 if i == 0 else -1.0) > side_trigger * 0.5
			want = want or crowding
		if want and (_may_step(i, k, shuffle, crowding) or err > reach_err):
			f["stepping"] = true
			f["t"] = 0.0
			f["dur"] = dur
			f["from"] = f["pos"]
			f["to"] = target
			var arc := _lift_for(f["pos"], target, up, ground)
			f["lift"] = arc.x
			f["tight"] = arc.y
			var planned := _flat_dist(f["from"], target, up)
			_lift_off(f, "settle" if not moving else ("stride" if planned >= maxf(stride * 0.5, min_stride) else "correction"), up)


## A foot lifts off for a step of `kind`: remember where it points now, so it can turn toward `facing` in the swing.
func _lift_off(f: Dictionary, kind: String, up: Vector3) -> void:
	f["kind"] = kind
	f["length"] = _flat_dist(f["from"], f["to"], up)
	var d: Vector3 = f.get("dir", Vector3.ZERO)
	f["dir_from"] = d if d.length_squared() > 1e-6 else facing


## A swinging foot turns from where it pointed at lift-off toward `facing`, over the step.
func _turn(f: Dictionary, up: Vector3) -> void:
	if facing.length_squared() < 1e-6:
		return
	var a: Vector3 = f.get("dir_from", facing)
	if a.length_squared() < 1e-6:
		a = facing
	var b := facing
	var ang := a.signed_angle_to(b, up)
	f["dir"] = a.rotated(up.normalized(), ang * _smooth(float(f["t"])))


## A step landed: the foot points where the legs do, and the step event goes out.
func _landed(i: int, f: Dictionary, up: Vector3) -> void:
	if facing.length_squared() > 1e-6:
		f["dir"] = facing
	var length := _flat_dist(f["from"], f["pos"], up)
	var info := {"kind": f.get("kind", "correction"), "length": length, "weight": clampf(length / maxf(step_length, 0.01), 0.0, 1.0),
			"pos": f["pos"]}
	f["last"] = info
	stepped.emit(i, info)


static func _flat_dist(a: Vector3, b: Vector3, up: Vector3) -> float:
	var d := b - a
	return (d - up * d.dot(up)).length()


## Where foot i should land: its home plus the lead, on the ground; not on a ledge beyond max_step from the body's
## floor (shorten the lead, then stay on the body's level); never closer than foot_clearance to the other foot.
func _target(i: int, home: Vector3, lead: Vector3, up: Vector3, ground: Callable, right: Vector3, floor_ref: Variant) -> Vector3:
	var t: Vector3 = ground.call(home + lead, up)
	if floor_ref != null:
		var ref: Vector3 = floor_ref
		for shrink: float in [0.5, 0.0]:
			if absf((t - ref).dot(up)) <= max_step:
				break
			t = ground.call(home + lead * shrink, up)
		var h := (t - ref).dot(up)
		if absf(h) > max_step:
			t -= up * (h - clampf(h, -max_step, max_step))
	if right != Vector3.ZERO:
		var other: Dictionary = feet[1 - i]
		var sgn := -1.0 if i == 0 else 1.0
		var gap := (t - (other["pos"] as Vector3)).dot(right) * sgn
		if other["stepping"]:   # clear of where it is and of where it is going
			gap = minf(gap, (t - (other["to"] as Vector3)).dot(right) * sgn)
		if gap < foot_clearance:
			var moved := t + right * sgn * (foot_clearance - gap)
			var g: Vector3 = ground.call(moved, up)
			t = g if absf((g - t).dot(up)) <= max_step else moved
	return t


## Where a swinging foot is at step time t (0..1). On level ground (tight 0) it travels along the floor for the whole
## step. Over a change of level or an obstacle (tight 1) it travels in the middle of the step only (SWING_MARGIN off
## each end) and changes level outside that: up early when the target is higher, down late when it is lower, so it
## rises before it reaches the edge of a curb and drops after it has passed one. The lift arc rides on top.
const SWING_MARGIN := 0.2
const SWING_LEVEL := 0.3   ## share of the step spent changing level


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func _level(dh: float, t: float) -> float:
	return _smooth(t / SWING_LEVEL) if dh > 0.0 else _smooth((t - (1.0 - SWING_LEVEL)) / SWING_LEVEL)


static func _swing(from: Vector3, to: Vector3, up: Vector3, lift: float, t: float, tight: float) -> Vector3:
	var d := to - from
	var dh := d.dot(up)
	var along := d - up * dh
	var m := SWING_MARGIN * tight
	var level := lerpf(_smooth(t), _level(dh, t), tight)
	return from + along * _smooth((t - m) / (1.0 - 2.0 * m)) + up * (dh * level + lift * sin(PI * t))


## The arc for a step, as (lift, tight): the lift of the stride itself, raised until the foot clears the ground under
## its path by step_clearance; tight = 1 when the path changes level or crosses an obstacle (see _swing). The ground
## is sampled along the path; each sample also answers for its neighbours, so an edge between two samples is cleared
## from its lower side.
func _lift_for(from: Vector3, to: Vector3, up: Vector3, ground: Callable) -> Vector2:
	var d := to - from
	var dist := d.length()
	var lift := step_height * clampf(dist / step_length, 0.25, 1.0)
	if dist <= 0.3:
		return Vector2(minf(lift, max_lift), 0.0)
	var dh := d.dot(up)
	var us: Array[float] = [0.03, 0.15, 0.3, 0.5, 0.7, 0.85, 0.97]
	var hs: Array[float] = []
	var rough := absf(dh) > 0.15
	for u in us:
		var g: Vector3 = ground.call(from + d * u, up)
		var h := (g - from).dot(up)
		hs.append(h)
		rough = rough or absf(h - dh * u) > 0.15
	if not rough:
		return Vector2(minf(lift, max_lift), 0.0)
	var m := SWING_MARGIN
	for i in us.size():
		var need := maxf(hs[i], maxf(hs[maxi(i - 1, 0)], hs[mini(i + 1, us.size() - 1)])) + step_clearance
		var t := m + (1.0 - 2.0 * m) * (0.5 - sin(asin(1.0 - 2.0 * us[i]) / 3.0))   # when the foot is at us[i]
		lift = maxf(lift, (need - dh * _level(dh, t)) / sin(PI * t))
	return Vector2(minf(lift, max_lift), 1.0)


## Horizontal distance (along the local floor) of foot i from its home.
func _err(i: int, homes: Array, up: Vector3) -> float:
	var d: Vector3 = (feet[i]["pos"] as Vector3) - (homes[i] as Vector3)
	return (d - up * d.dot(up)).length()


func _may_step(i: int, run_k: float, shuffle: bool = false, crowding: bool = false) -> bool:
	for j in feet.size():
		if j == i or not feet[j]["stepping"]:
			continue
		# At a walk, wait for the other foot to land; at a run or in a sideways shuffle, overlap once it is halfway down.
		# A foot crowding the other one may go as soon as that one is a quarter through.
		if crowding and float(feet[j]["t"]) >= 0.25:
			continue
		if (run_k < overlap_k and not shuffle) or float(feet[j]["t"]) < 0.5:
			return false
	return true
