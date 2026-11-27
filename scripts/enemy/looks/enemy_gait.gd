class_name EnemyGait
extends RefCounted
## Planted-foot gait for the legged enemies (EnemyStrider, EnemyTrooper): the player mech's rule (Gait,
## docs/design/vertical-slice.md S1) cut down for many small units. A foot stays PLANTED at a fixed world point until it
## falls `trigger` behind its home spot under the hip, then swings (Gait._swing's arc) to its home plus a lead along the
## travel; stride and cadence follow the unit's real ground speed (measured from its motion, so host units, co-op
## puppets, knockback slides and stagger stumbles all step the same way). Differences from Gait, for enemies:
##   - the lead is capped at what the leg reaches (`reach`), so a foot is planted for at most 2 x reach of travel; at a
##     walk the step time shrinks with speed so the other foot lands in time, at a run (RUN_K of run_speed) the steps
##     overlap and both feet are briefly in the air (a flight phase) instead of a planted foot being dragged;
##   - the ground is the unit's own floor plane (origin + up: the ring's local up, never global Y): no raycasts;
##   - two feet, no sorting, no dictionaries in the per-frame path; no step events beyond `landed` (strider audio).
## Presentation only: every field is Net.LOCAL, recomputed on every machine from the unit's motion.

const RUN_K := 0.35          ## share of run_speed from which the steps may overlap (run)

var reach := 0.6             ## m: furthest a planted foot may sit ahead of / behind its home (the leg's reach)
var step_time := 0.36        ## s per step at a standstill / slow walk
var run_step_time := 0.16    ## s per step at run_speed
var min_step_time := 0.1     ## s: the quickest step (sprint)
var run_speed := 9.0         ## m/s that counts as a full run
var lift := 0.25             ## m: foot lift at a full stride
var settle_time := 0.25      ## s standing still before the feet re-plant under the hips
var settle_error := 0.08     ## m a foot may rest off its home once settled
var clearance := 0.2         ## m: least sideways gap between the feet (centre to centre)

## Per foot (index 0 = left, 1 = right).
var pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]      ## world: where the foot is now (on the floor plane + lift)
var from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]     ## world: lift-off point of the current step
var stepping: Array[bool] = [false, false]
var t: Array[float] = [0.0, 0.0]                            ## step progress 0..1
var dur: Array[float] = [0.3, 0.3]                          ## s, this step's duration
var steps := 0               ## steps landed (tests, audio)
var landed := -1             ## foot that landed during the last update (-1 none)
var speed := 0.0             ## m/s: the last update's ground speed
var _still := 0.0
var _ready := false


func net_fields() -> Dictionary:
	return {"reach": Net.LOCAL, "step_time": Net.LOCAL, "run_step_time": Net.LOCAL, "min_step_time": Net.LOCAL,
		"run_speed": Net.LOCAL, "lift": Net.LOCAL, "settle_time": Net.LOCAL, "settle_error": Net.LOCAL,
		"clearance": Net.LOCAL, "pos": Net.LOCAL, "from": Net.LOCAL, "stepping": Net.LOCAL, "t": Net.LOCAL,
		"dur": Net.LOCAL, "steps": Net.LOCAL, "landed": Net.LOCAL, "speed": Net.LOCAL, "_still": Net.LOCAL,
		"_ready": Net.LOCAL}


## Plant both feet at their homes.
func reset(homes: Array[Vector3]) -> void:
	for i in 2:
		pos[i] = homes[i]
		from[i] = homes[i]
		stepping[i] = false
		t[i] = 0.0
	_still = 0.0
	_ready = true


func is_planted(i: int) -> bool:
	return not stepping[i]


## 0 with both feet down, up to 1 at the top of a step (body bob).
func lift_amount() -> float:
	var m := 0.0
	for i in 2:
		if stepping[i]:
			m = maxf(m, sin(PI * t[i]))
	return m


## Advance by dt. `homes`: the floor point under each hip now (world). `up`: the unit's up. `vel`: its velocity
## (world). `origin`: a point on its floor (the unit's feet). `airborne`: the feet hang at the homes (the caller passes
## points under the hips at hang height) and re-plant on the first grounded update.
func update(dt: float, homes: Array[Vector3], up: Vector3, vel: Vector3, origin: Vector3, airborne: bool = false) -> void:
	landed = -1
	if not _ready:
		reset(homes)
	var flat := vel - up * vel.dot(up)
	speed = flat.length()
	if airborne:
		for i in 2:
			stepping[i] = false
			t[i] = 0.0
			pos[i] = pos[i].lerp(homes[i], clampf(dt * 14.0, 0.0, 1.0))
		_ready = false   # touch down: plant at the homes next update
		return
	var k := clampf(speed / maxf(run_speed, 0.1), 0.0, 1.0)
	var span := reach * 2.0
	var d := lerpf(step_time, run_step_time, sqrt(k))
	if speed > 0.05 and k < RUN_K:
		d = minf(d, 0.9 * span / speed)   # walking, a foot waits for the other to land: it must land before this one
	d = maxf(d, min_step_time)            # passes its reach behind the hip (running, the steps overlap: flight)
	var dir := flat / speed if speed > 1e-4 else Vector3.ZERO
	var lead := dir * minf(speed * d * 0.5, reach)
	var trigger := maxf(minf(speed * d, span) * 0.5, reach * 0.35) if speed > 0.25 else reach
	var moving := speed > 0.25
	_still = 0.0 if moving else _still + dt
	var right := homes[1] - homes[0]
	right -= up * right.dot(up)
	var gap0 := right.length()
	right = right / gap0 if gap0 > 1e-4 else Vector3.ZERO
	# The foot further from home goes first.
	var e0 := _err(0, homes, up)
	var e1 := _err(1, homes, up)
	var first := 0 if e0 >= e1 else 1
	for n in 2:
		var i := first if n == 0 else 1 - first
		var target := _target(i, homes[i] + lead, up, origin, right)
		if stepping[i]:
			t[i] += dt / dur[i]
			if t[i] >= 1.0:
				stepping[i] = false
				t[i] = 0.0
				pos[i] = target
				steps += 1
				landed = i
			else:
				pos[i] = Gait._swing(from[i], target, up, lift * clampf(from[i].distance_to(target) / span, 0.3, 1.0),
					t[i], 0.0)
			continue
		var err := e0 if i == 0 else e1
		if err > span * 4.0:   # teleported / spawned / thrown: re-plant at once
			pos[i] = target
			continue
		var want := err > trigger or (_still > settle_time and err > settle_error)
		# Past the leg's reach: lift now whatever the other foot does (a planted foot is never dragged). A shove far
		# past it (knockback) is caught with a quick step; otherwise, if the other foot is early in its swing, this
		# step swings longer so the two drift back to alternating instead of locking into a hop.
		var shoved := err > span * 1.6
		var past := moving and err > reach * 1.05
		if (want and _may_step(i, k)) or shoved or past:
			stepping[i] = true
			t[i] = 0.0
			if shoved:
				dur[i] = min_step_time * 1.5
			elif not moving:
				dur[i] = maxf(step_time * 0.8, min_step_time)
			elif stepping[1 - i] and t[1 - i] < 0.5:
				dur[i] = d * (1.0 + (0.5 - t[1 - i]) * 2.0)
			else:
				dur[i] = d
			from[i] = pos[i]


## A limb's frame from its direction (joint toward its far end) and the bend pole: y up the limb, z away from the pole.
static func limb_frame(dir: Vector3, pole: Vector3) -> Basis:
	var y := -dir.normalized()
	var z := -(pole - y * pole.dot(y))
	if z.length_squared() < 1e-8:
		z = Vector3.BACK
	z = z.normalized()
	return Basis(y.cross(z), y, z)


## The rotation that carries a limb authored along `rest_dir` (bent toward `rest_pole`) to `dir` (bent toward `pole`).
static func limb_basis(dir: Vector3, pole: Vector3, rest_dir: Vector3, rest_pole: Vector3) -> Basis:
	return limb_frame(dir, pole) * limb_frame(rest_dir, rest_pole).transposed()


## Horizontal distance of foot i from its home.
func _err(i: int, homes: Array[Vector3], up: Vector3) -> float:
	var v := pos[i] - homes[i]
	return (v - up * v.dot(up)).length()


## Where foot i lands: on the floor plane, never closer than `clearance` to the other foot sideways.
func _target(i: int, want: Vector3, up: Vector3, origin: Vector3, right: Vector3) -> Vector3:
	var p := want - up * (want - origin).dot(up)
	if right != Vector3.ZERO:
		var j := 1 - i
		var other := pos[j] if not stepping[j] else pos[j]
		var sgn := -1.0 if i == 0 else 1.0
		var gap := (p - other).dot(right) * sgn
		if gap < clearance:
			p += right * sgn * (clearance - gap)
	return p


## At a walk a foot waits for the other to land; at a run it may go once the other is halfway through its step.
func _may_step(i: int, run_k: float) -> bool:
	var j := 1 - i
	if not stepping[j]:
		return true
	return run_k >= RUN_K and t[j] >= 0.5
