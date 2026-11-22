class_name PilotNeck
extends RefCounted
## The pilot's neck and flair springs (docs/design/pilot-heads.md section 4): two joints (NeckLow, NeckHigh) as a damped
## spring chain, a skull squash spring, a sink / push spring (head riding lower / forward), the eyes (they move first, the
## head follows), one flair hinge (comb / husks / jelly) and N pendulums (wattles / ears) that hang under gravity and
## trail the head.
##
## Units: angles in radians, Vector3 angles as (pitch, yaw, roll) with pitch + = nose up, yaw + = to the head's left,
## roll + = top toward the head's left (-X); Basis.from_euler order YXZ. Linear acceleration in model units per s^2 in the
## head's frame (-Z forward). Looks are Vector2(yaw, pitch).
##
## Integration: semi-implicit Euler, sub-stepped to at most MAX_STEP per step, so it is stable at any frame delta; one
## call never integrates more than MAX_DELTA (a hitch beyond that is dropped). Angles are clamped to the limits and the
## velocity into a limit is zeroed; a non-finite input is treated as zero and a non-finite state resets.
## Deterministic: the same sequence of inputs and deltas gives the same state.
## Cosmetic only (Net.LOCAL).

const MAX_STEP := 1.0 / 120.0
const MAX_DELTA := 1.0
const YAW_LIMIT := deg_to_rad(70.0)
const PITCH_LIMIT := deg_to_rad(35.0)
const ROLL_LIMIT := deg_to_rad(30.0)
## Each joint's share of the total target, and of the limits (they sum to 1, so the chain never exceeds the limits).
const LOW_SHARE := 0.4
const HIGH_SHARE := 0.6
## Turn lead: the head leads the body by yaw rate x LEAD_TIME, up to LEAD_MAX; it banks BANK rad per rad/s.
const LEAD_TIME := 0.25
const LEAD_MAX := deg_to_rad(35.0)
const BANK := 0.06
const BANK_MAX := deg_to_rad(12.0)
## Eyes: they reach EYE_LIMIT off the head's own direction, follow with time constant EYE_TAU, and lead turns by EYE_LEAD.
const EYE_LIMIT := deg_to_rad(28.0)
const EYE_TAU := 0.08
const EYE_LEAD := deg_to_rad(10.0)
const ACCEL_CLAMP := 40.0
const ANG_ACC_CLAMP := 400.0
const FLAIR_LIMIT := deg_to_rad(75.0)
const PEND_LIMIT := deg_to_rad(65.0)

# --- Style (set from the head definition's `style`, PilotFace) ---
var hz := 3.5                   ## neck spring frequency (lower joint; the upper runs at hz * upper)
var damping := 0.5              ## damping ratio
var upper := 0.85               ## upper joint frequency factor (softer)
var accel_gain := 0.02          ## steady tilt in rad per unit/s^2 of acceleration
var flair_hz := 2.0
var flair_damping := 0.3
var flair_inertia := 0.5        ## how strongly flair trails head angular acceleration
var pend_hz := 2.4
var pend_damping := 0.25
var footfall_gain := 1.0        ## footfall nod strength (x PilotHead.FOOTFALL_NOD): heavier on the dog and duck
var step_deg := 0.0             ## > 0: bird saccades, the look target only jumps when it moved this many degrees
var flair_raise := Vector2(deg_to_rad(-12.0), 0.0)   ## flair hinge (pitch, roll) at flair = +1
var flair_drop := Vector2(deg_to_rad(10.0), deg_to_rad(45.0))   ## at flair = -1

# --- Inputs, set by PilotHead before each step ---
var accel := Vector3.ZERO
var yaw_rate := 0.0
var look := Vector2.ZERO        ## desired look (yaw, pitch) in the head's frame
var use_lead := true            ## turn lead applies (false while a look overrides it)
var pose := Vector3.ZERO        ## extra (pitch, yaw, roll) on the target
var pose_sink := 0.0
var pose_push := 0.0
var pose_squash := 0.0
var flair_level := 0.0          ## the flair channel, -1..1
var flair_offset := Vector2.ZERO   ## extra flair (pitch, roll) target
var pend_offset := Vector2.ZERO    ## extra pendulum (pitch, roll) target

# --- State ---
var low := Vector3.ZERO
var low_v := Vector3.ZERO
var high := Vector3.ZERO
var high_v := Vector3.ZERO
var squash := 0.0
var squash_v := 0.0
var shift := Vector2.ZERO       ## (sink, push)
var shift_v := Vector2.ZERO
var eye := Vector2.ZERO         ## eye (yaw, pitch) relative to the head
var flair := Vector2.ZERO       ## flair hinge (pitch, roll) relative to the head
var flair_v := Vector2.ZERO
var pend: Array[Vector2] = []
var pend_v: Array[Vector2] = []
var held_look := Vector2.ZERO
var _prev_hv := Vector3.ZERO


func configure(style: Dictionary, pendulums: int) -> void:
	for k: String in style:
		if k in self:
			set(k, style[k])
	pend.resize(pendulums)
	pend_v.resize(pendulums)
	pend.fill(Vector2.ZERO)
	pend_v.fill(Vector2.ZERO)


## The whole chain's (pitch, yaw, roll).
func total() -> Vector3:
	return low + high


## Velocity impulses: (pitch, yaw, roll) rad/s on the head, rad/s on the flair and pendulums, 1/s on the squash.
func kick(ang: Vector3, flair_kick: float = 0.0, squash_kick: float = 0.0) -> void:
	ang = _finite3(ang)
	low_v += ang * 0.4
	high_v += ang * 0.6
	flair_v.x += _finite(flair_kick)
	for i in pend_v.size():
		pend_v[i].x += _finite(flair_kick) * 0.8
	squash_v += _finite(squash_kick)


func step(delta: float) -> void:
	delta = clampf(_finite(delta), 0.0, MAX_DELTA)
	if delta <= 0.0:
		return
	accel = _finite3(accel).clamp(Vector3.ONE * -ACCEL_CLAMP, Vector3.ONE * ACCEL_CLAMP)
	yaw_rate = clampf(_finite(yaw_rate), -20.0, 20.0)
	look = Vector2(_finite(look.x), _finite(look.y))
	pose = _finite3(pose)
	var n := ceili(delta / MAX_STEP)
	var h := delta / float(n)
	for i in n:
		_substep(h)
	if not _state_finite():
		reset()


func reset() -> void:
	low = Vector3.ZERO
	low_v = Vector3.ZERO
	high = Vector3.ZERO
	high_v = Vector3.ZERO
	squash = 0.0
	squash_v = 0.0
	shift = Vector2.ZERO
	shift_v = Vector2.ZERO
	eye = Vector2.ZERO
	flair = Vector2.ZERO
	flair_v = Vector2.ZERO
	pend.fill(Vector2.ZERO)
	pend_v.fill(Vector2.ZERO)
	held_look = Vector2.ZERO
	_prev_hv = Vector3.ZERO


func _substep(h: float) -> void:
	# Where the head wants to point: the look (+ turn lead), held in steps for a bird.
	var lead := clampf(yaw_rate * LEAD_TIME, -LEAD_MAX, LEAD_MAX) if use_lead else 0.0
	var want := Vector2(clampf(look.x + lead, -YAW_LIMIT, YAW_LIMIT), clampf(look.y, -PITCH_LIMIT, PITCH_LIMIT))
	if step_deg <= 0.0 or (want - held_look).length() > deg_to_rad(step_deg):
		held_look = want
	var bank := clampf(yaw_rate * BANK, -BANK_MAX, BANK_MAX)
	var target := Vector3(held_look.y + pose.x, held_look.x + pose.y, bank + pose.z)
	var lim := Vector3(PITCH_LIMIT, YAW_LIMIT, ROLL_LIMIT)
	target = target.clamp(-lim, lim)
	# Acceleration tips the head the other way: forward (-Z) pitches it back, rightward rolls its top left.
	var inertial := Vector3(-accel.z, 0.0, accel.x) * accel_gain
	var w := TAU * hz
	var wu := w * upper
	var a_low := (target * LOW_SHARE - low) * w * w - low_v * 2.0 * damping * w + inertial * 0.6 * w * w
	var a_high := (target * HIGH_SHARE - high) * wu * wu - high_v * 2.0 * damping * wu + inertial * wu * wu
	low_v += a_low * h
	high_v += a_high * h
	low += low_v * h
	high += high_v * h
	_clamp_joint(true, lim * LOW_SHARE)
	_clamp_joint(false, lim * HIGH_SHARE)
	var hv := low_v + high_v
	var ang_acc := ((hv - _prev_hv) / h).clamp(Vector3.ONE * -ANG_ACC_CLAMP, Vector3.ONE * ANG_ACC_CLAMP)
	_prev_hv = hv
	# Skull squash (landing, bob) and the sink / push shift.
	var ws := TAU * 4.0
	var sq_target := pose_squash + clampf(accel.y * 0.004, -0.1, 0.15)
	squash_v += ((sq_target - squash) * ws * ws - squash_v * 2.0 * 0.35 * ws) * h
	squash = clampf(squash + squash_v * h, -0.15, 0.3)
	var wm := TAU * 3.0
	shift_v += ((Vector2(pose_sink, pose_push) - shift) * wm * wm - shift_v * 2.0 * 0.7 * wm) * h
	shift = (shift + shift_v * h).clamp(Vector2(-0.1, -0.15), Vector2(0.25, 0.15))
	# Eyes first: they cover what the head has not turned yet, and lead turns a little.
	var tot := total()
	var eye_lead := signf(yaw_rate) * EYE_LEAD * minf(absf(yaw_rate), 1.0)
	var eye_want := Vector2(look.x + lead + eye_lead - tot.y, look.y - tot.x)
	eye_want = eye_want.clamp(-Vector2.ONE * EYE_LIMIT, Vector2.ONE * EYE_LIMIT)
	eye += (eye_want - eye) * (1.0 - exp(-h / EYE_TAU))
	# Flair: a looser spring toward its level, trailing the head's angular acceleration and the body's acceleration.
	var f_target := flair_raise * maxf(flair_level, 0.0) + flair_drop * maxf(-flair_level, 0.0) + flair_offset
	var wf := TAU * flair_hz
	var trail := Vector2(-ang_acc.x, -ang_acc.z - ang_acc.y * 0.5) * flair_inertia
	trail += Vector2(-accel.z, accel.x) * accel_gain * wf * wf
	flair_v += ((f_target - flair) * wf * wf - flair_v * 2.0 * flair_damping * wf + trail) * h
	flair = (flair + flair_v * h).clamp(-Vector2.ONE * FLAIR_LIMIT, Vector2.ONE * FLAIR_LIMIT)
	# Pendulums hang straight down in the world: their target cancels the head's own pitch and roll.
	var wp := TAU * pend_hz
	var hang := Vector2(-tot.x, -tot.z) + pend_offset
	for i in pend.size():
		var pv := pend_v[i]
		pv += ((hang - pend[i]) * wp * wp - pv * 2.0 * pend_damping * wp + trail * 1.2) * h
		pend_v[i] = pv
		pend[i] = (pend[i] + pv * h).clamp(-Vector2.ONE * PEND_LIMIT, Vector2.ONE * PEND_LIMIT)


func _clamp_joint(is_low: bool, lim: Vector3) -> void:
	var x := low if is_low else high
	var v := low_v if is_low else high_v
	for a in 3:
		if x[a] > lim[a]:
			x[a] = lim[a]
			v[a] = minf(v[a], 0.0)
		elif x[a] < -lim[a]:
			x[a] = -lim[a]
			v[a] = maxf(v[a], 0.0)
	if is_low:
		low = x
		low_v = v
	else:
		high = x
		high_v = v


func _state_finite() -> bool:
	for v: Vector3 in [low, low_v, high, high_v]:
		if not v.is_finite():
			return false
	for v: Vector2 in [shift, shift_v, eye, flair, flair_v]:
		if not v.is_finite():
			return false
	for v: Vector2 in pend:
		if not v.is_finite():
			return false
	return is_finite(squash) and is_finite(squash_v)


static func _finite(x: float) -> float:
	return x if is_finite(x) else 0.0


static func _finite3(v: Vector3) -> Vector3:
	return v if v.is_finite() else Vector3.ZERO
