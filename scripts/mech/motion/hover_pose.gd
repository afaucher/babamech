class_name HoverPose
extends RefCounted
## A hover chassis' pose from its motion (the Wasp; docs/design/wasp-hover.md section 3): MechRig hands its model to this
## every physics frame instead of running the gait (MechRig.update_pose, model.is_hover()). It reads only what every
## machine has for any mech, own or puppet: the controller's velocity (streamed), facing, grounded() (a puppet's from its
## snapshot), shutdown / can_fly() (streamed shutdown; fans_alive from step 2's streamed fan components) and altitude()
## (a physics query against this machine's world). No input, no owner-only state, so a puppet poses as its owner does.
##
## Each frame, through MechModel's hover hooks:
##  - bank (set_bank): roll into a strafe (right side down moving right), nose down moving / accelerating forward, eased;
##    level when landed or falling.
##  - fan tilt (set_fan_tilt, per fan, clamped to the model's tilt ellipse): forward with forward thrust demand, outward
##    with a strafe (left fan + / right fan - moving right), opposite forward tilts while turning.
##  - rotor spin (set_fan_spin + step_fans): spin_ground landed and live, spin_idle hovering, up to spin_max climbing /
##    boosting / accelerating, winding down to 0 shut down or with a dead fan.
##  - legs (set_legs_pose): dangling in flight with a small swing from acceleration (a damped spring), extending to stand
##    below legs_reach m of altitude; falling with the fans stopped they stand legs_flare s before the impact; landed they
##    stand, and the touchdown dips them by `bounce` (scaled by the landing speed) and back. While the legs bend landed
##    the model is lowered so the soles stay on the ground (sole heights sampled from the model's own leg pose).
## Presentation only (Net LOCAL): tuning fixed at spawn, state recomputed on every machine.

var bank_roll := 0.14        ## rad of roll at most (0.6 of it from strafing at cruise speed, 0.4 from full sideways accel)
var bank_pitch := 0.10       ## rad of nose-down at most (the same shares, forward)
var bank_rate := 5.0         ## 1/s: how fast the bank and fan tilt ease
var tilt_gain := 1.0         ## share of the fans' tilt limits used at full thrust demand
var spin_ground := 1.2       ## rev/s landed and live (idling)
var spin_idle := 3.5         ## rev/s hovering in place
var spin_max := 7.0          ## rev/s at full throttle (boost, climb)
var spin_up := 6.0           ## rev/s^2 spinning up
var spin_down := 2.5         ## rev/s^2 winding down
var legs_reach := 4.0        ## m of altitude below which the legs start to extend
var legs_rate := 3.0         ## legs pose per second (0 dangle .. 1 stand)
var legs_flare := 0.6        ## s before impact a fall with the fans stopped has its legs standing
var swing := 0.12            ## legs pose swing per full forward accel in flight
var bounce := 0.15           ## legs pose dip at a touchdown at hard_land_speed (less for softer ones, at least a third)

const ACC_EASE := 8.0        ## 1/s: smoothing of the acceleration estimate (puppet velocities step per snapshot)
const SWING_W := 9.0         ## rad/s: the leg swing spring's natural frequency
const SWING_DAMP := 0.35     ## and its damping ratio
const BOUNCE_TIME := 0.12    ## s to the bottom of the touchdown dip
const SOLE_STEPS := 10       ## sole-height table resolution over the legs pose

var roll := 0.0
var pitch := 0.0
var tilt_l := Vector2.ZERO
var tilt_r := Vector2.ZERO
var spin := 0.0
var legs := 1.0              ## the legs pose given to the model (after swing and bounce)
var drop := 0.0              ## m the model is lowered (landed, legs bending)

var _legs_base := 1.0
var _swing_x := 0.0
var _swing_v := 0.0
var _vel := Vector3.ZERO
var _acc := Vector3.ZERO
var _prev_fwd := Vector3.ZERO
var _was_grounded := true
var _land_t := INF
var _land_dip := 0.0
var _started := false
var _soles := PackedFloat32Array()


func net_fields() -> Dictionary:
	return {"bank_roll": Net.SPAWN, "bank_pitch": Net.SPAWN, "bank_rate": Net.SPAWN, "tilt_gain": Net.SPAWN,
		"spin_ground": Net.SPAWN, "spin_idle": Net.SPAWN, "spin_max": Net.SPAWN, "spin_up": Net.SPAWN,
		"spin_down": Net.SPAWN, "legs_reach": Net.SPAWN, "legs_rate": Net.SPAWN, "legs_flare": Net.SPAWN,
		"swing": Net.SPAWN, "bounce": Net.SPAWN,
		"roll": Net.LOCAL, "pitch": Net.LOCAL, "tilt_l": Net.LOCAL, "tilt_r": Net.LOCAL, "spin": Net.LOCAL,
		"legs": Net.LOCAL, "drop": Net.LOCAL, "_legs_base": Net.LOCAL, "_swing_x": Net.LOCAL, "_swing_v": Net.LOCAL,
		"_vel": Net.LOCAL, "_acc": Net.LOCAL, "_prev_fwd": Net.LOCAL, "_was_grounded": Net.LOCAL, "_land_t": Net.LOCAL,
		"_land_dip": Net.LOCAL, "_started": Net.LOCAL, "_soles": Net.LOCAL}


## Forget the motion history (a teleport, a respawn, a lab reset): the next update starts from the body's state.
func reset() -> void:
	_started = false
	_land_t = INF
	_swing_x = 0.0
	_swing_v = 0.0


## Pose `model` (a hover MechModel, MechRig's) for `body`'s motion this frame.
func update(delta: float, body: MechController, model: MechModel) -> void:
	if body == null or model == null or delta <= 0.0:
		return
	var up := body.up()
	var hull := body.global_basis.orthonormalized()
	var v := body.velocity
	var fwd := body.forward() - up * body.forward().dot(up)
	var grounded := body.grounded()
	if not _started:
		_started = true
		_vel = v
		_acc = Vector3.ZERO
		_prev_fwd = fwd
		_was_grounded = grounded
		legs = 1.0 if grounded else 0.0
		_legs_base = legs
		spin = spin_ground if grounded and body.can_fly() else (spin_idle if body.can_fly() else 0.0)
	_acc = _acc.lerp((v - _vel) / delta, 1.0 - exp(-ACC_EASE * delta))
	_vel = v
	var yaw_rate := 0.0   # rad/s, + = turning left
	if _prev_fwd.length_squared() > 1e-6 and fwd.length_squared() > 1e-6:
		yaw_rate = _prev_fwd.signed_angle_to(fwd, up) / delta
	_prev_fwd = fwd
	var lv := hull.inverse() * v          # x right, y up, z back
	var la := hull.inverse() * _acc
	var live := body.can_fly()
	var flying := live and not grounded
	var top := maxf(body.run_speed, 0.1)
	var acc_ref := maxf(body.accel, 0.1)
	var side := 0.0
	var fore := 0.0
	var turn := 0.0
	if flying:
		var cruise := maxf(body.walk_speed, 0.1)   # the bank is full at cruise speed plus acceleration (boost clamps)
		side = clampf(0.6 * lv.x / cruise + 0.4 * la.x / acc_ref, -1.0, 1.0)
		fore = clampf(-0.6 * lv.z / cruise - 0.4 * la.z / acc_ref, -1.0, 1.0)
		turn = clampf(-yaw_rate / maxf(body.turn_rate, 0.1), -1.0, 1.0)   # + = turning right
	var k := 1.0 - exp(-bank_rate * delta)
	# Bank: + roll = right side down (moving right), + pitch = nose up (so forward is nose down).
	roll = lerpf(roll, bank_roll * side, k)
	pitch = lerpf(pitch, -bank_pitch * fore, k)
	model.set_bank(roll, pitch)
	# Fans: tilt.x forward (+ thrusts forward), tilt.y outward (strafing right: left +, right -); a turn right tilts the
	# left fan forward and the right one back.
	var tm := model.clamp_fan_tilt(Vector2(1e3, 0.0)).x   # the forward limit (the ellipse's x semi-axis)
	var ts := model.clamp_fan_tilt(Vector2(0.0, 1e3)).y   # the sideways limit
	var want_l := model.clamp_fan_tilt(Vector2((fore + 0.5 * turn) * tm, side * ts) * tilt_gain)
	var want_r := model.clamp_fan_tilt(Vector2((fore - 0.5 * turn) * tm, -side * ts) * tilt_gain)
	tilt_l = tilt_l.lerp(want_l, k)
	tilt_r = tilt_r.lerp(want_r, k)
	model.set_fan_tilt(tilt_l, -1)
	model.set_fan_tilt(tilt_r, 1)
	# Rotors: throttle from speed, climb and acceleration.
	var vs := v.dot(up)
	var target := 0.0
	if live:
		if grounded:
			target = spin_ground
		else:
			var flat := (v - up * vs).length()
			var thr := clampf(maxf(flat / top, maxf(vs, 0.0) / maxf(body.climb_rate, 0.1)), 0.0, 1.0)
			thr = maxf(thr, clampf(_acc.length() / acc_ref, 0.0, 1.0) * 0.5)
			target = lerpf(spin_idle, spin_max, thr)
	spin = move_toward(spin, target, (spin_up if target > spin else spin_down) * delta)
	model.set_fan_spin(spin)
	model.step_fans(delta)
	# Legs.
	if grounded and not _was_grounded:
		_land_t = 0.0
		var hard := maxf(body.hard_land_speed, 0.1)
		_land_dip = bounce * clampf(maxf(body.last_impact / hard, 0.34), 0.0, 1.0)
	_was_grounded = grounded
	var alt := 0.0 if grounded else body.altitude()
	var stand := 1.0
	if not grounded:
		stand = 1.0 - smoothstep(0.3, maxf(legs_reach, 0.31), alt)
		if not live and -vs > 0.5 and alt / -vs < legs_flare:
			stand = 1.0   # falling with the fans stopped: brace before the impact
	_legs_base = move_toward(_legs_base, stand, legs_rate * delta * (2.0 if grounded else 1.0))
	# Swing: a damped spring pushed by forward acceleration, faded out as the legs stand.
	var drive := (-la.z / acc_ref) * swing if flying else 0.0
	var w := SWING_W
	_swing_v += (w * w * (drive - _swing_x) - 2.0 * SWING_DAMP * w * _swing_v) * delta
	_swing_x += _swing_v * delta
	var out := _legs_base + _swing_x * (1.0 - _legs_base)
	if _land_t < BOUNCE_TIME * 8.0:
		var x := _land_t / BOUNCE_TIME
		out -= _land_dip * x * exp(1.0 - x)   # down fast, back up slowly
		_land_t += delta
	legs = clampf(out, 0.0, 1.0)
	model.set_legs_pose(legs)
	# Landed with the legs bending: lower the model so the soles stay on the ground.
	drop = 0.0
	if grounded:
		drop = maxf(sole_height(model, legs) - sole_height(model, 1.0), 0.0) * model.scale.y
	model.position = Vector3(0.0, -drop, 0.0)


## The soles' height over the model's origin (model units) with the legs at pose `t`, unbanked: a table sampled once from
## the model's own leg pose (WaspMeshes.leg_angles through MechModel's hover nodes), interpolated.
func sole_height(model: MechModel, t: float) -> float:
	if _soles.is_empty():
		_soles = _sample_soles(model)
	if _soles.is_empty():
		return 0.0
	var x := clampf(t, 0.0, 1.0) * SOLE_STEPS
	var i := mini(int(floor(x)), SOLE_STEPS - 1)
	return lerpf(_soles[i], _soles[i + 1], x - float(i))


static func _sample_soles(model: MechModel) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var foot := model.find_child("foot_r", true, false) as Node3D
	if foot == null:
		return out
	var keep_legs := model.legs_pose()
	var keep_bank: Vector2 = model._bank
	model.set_bank(0.0, 0.0)
	for i in SOLE_STEPS + 1:
		model.set_legs_pose(float(i) / SOLE_STEPS)
		out.append(_rel(foot, model).origin.y)
	model.set_bank(keep_bank.x, keep_bank.y)
	model.set_legs_pose(keep_legs)
	return out


## `node`'s transform relative to its ancestor `root` (no scene tree needed).
static func _rel(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
