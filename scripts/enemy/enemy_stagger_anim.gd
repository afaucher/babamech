class_name EnemyStaggerAnim
extends RefCounted
## The stagger as an animation (presentation only; the mechanics are Knockback.stagger_left / CombatTarget.can_act and
## are not touched): a timeline laid over the unit's mechanical stagger window, sampled as a few channels each unit maps
## onto its own parts.
##   hit      0 .. HIT_T s       the recoil snaps in away from the hit (overshoots a little)
##   stumble  .. window - R       body knocked back and off balance, aim lost (legged units step to catch the body)
##   recover  last R s            shake-off (head / torso shake), feet re-plant, the weapon comes back up onto aim
## R = min(REC_T, window * REC_SHARE). Channels (all 0 at rest, so every unit ends exactly at its normal pose):
##   k        recoil envelope 0..1 (+ a small overshoot right after the hit)
##   stumble  0..1 body knocked off its stance (legged units shift their hips / homes along `push`)
##   aim_off  0..1 how far the weapon / sensor is off aim (overshoots slightly negative as it comes back up)
##   shake    -1..1 the shake-off oscillation (only during the recovery)
##   rock     -1..1 a damped rock for units without legs (tank, drones), settling to 0 by the end of the window
##   push     unit-local horizontal unit vector: the way the hit pushed the unit (its recoil leans this way)
## The host knows the window exactly (Knockback.stagger_left); a co-op puppet only gets the staggered flag, so it guesses
## Combat.STAGGER_TIME, holds the stumble while the flag stays up past its guess (a leg-cripple stagger is longer), and
## plays the recovery quickly when the flag drops early. All fields Net.LOCAL.

const HIT_T := 0.1          ## s: the recoil snaps in
const REC_T := 0.3          ## s: longest recovery
const REC_SHARE := 0.45     ## recovery is at most this share of the window
const MIN_REC := 0.12       ## s: a recovery forced early (puppet saw the flag drop) still takes this long

var active := false
var t := 0.0                ## s since the stagger began
var window := 0.6           ## s: the mechanical window (exact on the host, guessed on a puppet)
var rec_start := 0.33       ## s: when the recovery begins
var push := Vector3.BACK
var side := 1.0             ## shake / swing sign (from the hit side)
var k := 0.0
var stumble := 0.0
var aim_off := 0.0
var shake := 0.0
var rock := 0.0
var rec_u := 0.0
var _flag := false


func net_fields() -> Dictionary:
	return {"active": Net.LOCAL, "t": Net.LOCAL, "window": Net.LOCAL, "rec_start": Net.LOCAL, "push": Net.LOCAL,
		"side": Net.LOCAL, "k": Net.LOCAL, "stumble": Net.LOCAL, "aim_off": Net.LOCAL, "shake": Net.LOCAL,
		"rock": Net.LOCAL, "rec_u": Net.LOCAL, "_flag": Net.LOCAL}


func reset() -> void:
	active = false
	t = 0.0
	_flag = false
	k = 0.0
	stumble = 0.0
	aim_off = 0.0
	shake = 0.0
	rock = 0.0
	rec_u = 0.0


static func rec_len(w: float) -> float:
	return minf(REC_T, w * REC_SHARE)


## Advance by dt. `flagged`: staggered now. `remaining`: the exact seconds left (host), or < 0 when unknown (puppet).
## `push_local`: the hit's push direction in the unit's frame (horizontal; zero = unknown, the unit recoils backward),
## read at the onset and refined while `refine` (a puppet measuring its knockback slide).
func step(dt: float, flagged: bool, remaining: float, push_local: Vector3, refine: bool = false) -> void:
	if flagged and not _flag:
		active = true
		t = 0.0
		window = remaining if remaining > 0.0 else Combat.STAGGER_TIME
		rec_start = window - rec_len(window)
		_set_push(push_local)
	elif active and refine and t < HIT_T * 1.5 and push_local.length_squared() > 1e-4:
		_set_push(push_local)
	_flag = flagged
	if not active:
		_zero()
		return
	t += dt
	if flagged:
		if remaining >= 0.0:
			window = t + remaining                     # host: exact (a cripple stagger may extend it)
			rec_start = window - rec_len(window)
		elif t > rec_start:                            # puppet: still flagged past the guess: hold the stumble
			window = maxf(window, t + rec_len(window))
			rec_start = t
	elif t < window:                                   # the flag dropped (host: on time; puppet: maybe early)
		if t < rec_start:
			rec_start = t
			window = t + MIN_REC
		window = minf(window, maxf(t, rec_start + MIN_REC))
	if t >= window and not flagged:
		active = false
		_zero()
		return
	_sample()


func _set_push(p: Vector3) -> void:
	var f := Vector3(p.x, 0.0, p.z)
	push = f.normalized() if f.length_squared() > 1e-6 else Vector3.BACK
	side = 1.0 if push.x >= 0.0 else -1.0


func _zero() -> void:
	k = 0.0
	stumble = 0.0
	aim_off = 0.0
	shake = 0.0
	rock = 0.0
	rec_u = 0.0


static func _sm(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


func _sample() -> void:
	var r := maxf(window - rec_start, 1e-3)
	rec_u = clampf((t - rec_start) / r, 0.0, 1.0)
	var hit := _sm(t / HIT_T)
	var over := 0.3 * _sm((t - HIT_T * 0.5) / HIT_T) * (1.0 - _sm((t - HIT_T * 1.5) / (HIT_T * 1.5)))
	var sag := 0.25 * _sm((t - HIT_T) / maxf(rec_start - HIT_T, 0.05))   # the recoil eases off a little in the stumble
	var out := 1.0 - _sm(rec_u)
	k = hit * (1.0 + over - sag) * out
	stumble = hit * out
	# The weapon comes back up with a little overshoot past the aim (aim_off dips below 0), settling to 0.
	var y := rec_u - 1.0
	var back := 1.0 + 2.70158 * y * y * y + 1.70158 * y * y   # ease-out-back: 0 -> 1, peaks ~1.1
	aim_off = _sm(t / (HIT_T * 1.5)) * (1.0 - back)
	if rec_u >= 1.0:
		aim_off = 0.0
	shake = sin(rec_u * 2.0 * TAU) * sin(PI * rec_u) * side if rec_u > 0.0 else 0.0
	rock = hit * cos(TAU * t * 1.8) * exp(-t * 2.5) * out + 0.35 * shake
