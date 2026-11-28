class_name MechRig
extends Node3D
## The mech's walking presentation: a child of a MechController that poses the MechModel every physics frame from the
## controller's motion. Feet are planted by Gait, legs are solved by LegIK, and the body bobs, dips toward a lower foot
## and leans into speed. The model is scaled by `mech_scale` (about 8 m tall at 2.0).
##
## Airborne (thrusting, falling, off a ledge for more than `AIR_DELAY`, or high above the ground at once): the feet
## hang under the hips in a relaxed tuck relative to the body, carried along with it, never left on the ground below
## (they stay above the ground when it is near). On touchdown they re-plant together (Gait.land_time) and the body
## dips by `absorb` scaled by the controller's `last_impact`.
##
## Hip twist (classic mech torso twist, inverted: the torso keeps the body facing, the legs turn): `leg_yaw` turns the
## pelvis and legs toward the ground velocity relative to the body facing, at most `twist_max` either way, easing at
## `twist_rate`. Moving backward or back-diagonally the legs keep facing roughly forward and walk backward (a reversed
## gait) rather than twisting round; the switch has hysteresis (TWIST_HYST) so input near the side line doesn't flip
## it. Below TWIST_SPEED the twist fades out and the legs come back to the body facing (the gait's settle steps
## re-plant the feet). The gait gets homes under the twisted hips, so its stride, step direction and foot clearance all
## work in the legs' frame: a strafe becomes forward or diagonal walking with full strides. Lean follows the travel
## direction, sway the planted foot in the legs' frame.
##
## Heat shutdown sag: while the controller's `shutdown` is on (a puppet's comes from its owner's snapshot, MechPuppet)
## the body slumps: it drops `sag_depth` (the knees bend deeper through the IK, the planted feet stay put), pitches
## forward `sag_pitch` and lists a little to one side, easing in on an underdamped spring over about `sag_time` (it
## overshoots, rebounds and settles); when the mech reboots it rises the same way with a short shudder. Not in the air.
## Cosmetic only: no effect on the body, collision, speeds or the gait.
##
## Per chassis: the numbers below (and Gait's) are the Strider's; another chassis' ChassisParts "rig" entries and its
## "twist_max" replace them when the model's chassis changes (apply_chassis_rig: the Bulwark has no twist, so it strafes
## by side-stepping, with longer, slower, higher steps for its long legs).
##
## Presentation only (Net LOCAL): every machine runs it from the mech's synced motion (own mech or puppet alike).

var mech_scale := 2.0
var bob := 0.1               ## body dip between steps (model units) at full speed
var lean := 0.16             ## forward lean (rad) at run speed
var sway := 0.04             ## sideways roll (rad) toward the planted foot while walking
var foot_gap := 0.65         ## least sideways gap between the feet, centre to centre (model units; times mech_scale)
var step_margin := 0.9       ## share of the leg's geometric foot lift used as the max step-up
var probe_up := 5.0          ## ground ray starts this far above a hip's ground point (m)
var probe_down := 12.0       ## and reaches this far below
var air_tuck := 0.5          ## airborne feet hang this share of the max foot lift above the standing foot level
var absorb := 0.35           ## landing dip (model units) at a landing of hard_land_speed; less for softer ones
var absorb_time := 0.1       ## seconds to the bottom of the landing dip (it recovers over about five times that)

var sag_depth := 0.42        ## heat shutdown: the body drops this far (model units; times mech_scale in metres)
var sag_pitch := 0.17        ## and pitches forward this much (rad)
var sag_roll := 0.035        ## and lists this much to one side (rad), so the slump isn't symmetric
var sag_time := 0.65         ## seconds the slump (and the reboot rise) takes to settle, overshoot included

var twist_max := deg_to_rad(90.0)    ## hip twist: the legs turn at most this far from the body facing (rad)
var twist_rate := deg_to_rad(270.0)  ## and at most this fast (rad/s)

const AIR_DELAY := 0.15      ## seconds off the floor before the legs hang (brief bumps keep the feet planted)
const TWIST_SPEED := Vector2(1.0, 3.0)   ## ground speed (m/s) where the twist starts, and where it is full
const TWIST_HYST := deg_to_rad(25.0)     ## the travel angle must pass the side line by this to swap forward / reversed
const TWIST_PICK := deg_to_rad(100.0)    ## legs at the body facing: travel beyond this angle walks reversed
const SAG_DAMP := 0.45       ## the slump spring's damping ratio (about 20 % overshoot past sag_depth)
const RISE_DAMP := 0.4       ## the reboot rise's (it overshoots above standing a little)
const SAG_PEAK := 1.3        ## the deepest the settle may reach, as a share of sag_depth (test_torso_clearance checks it)
const SHUDDER := Vector2(0.05, 15.0)   ## reboot shudder: amplitude (share of sag_depth) and frequency (Hz); fades in 0.4 s

var model: MechModel
var gait := Gait.new()
var leg_yaw := 0.0           ## hip twist now (rad, + = legs turned toward the body's right)
var reached_fraction := 1.0  ## legs whose IK target was in reach last frame (diagnostics, tests)
## Co-op puppets: the owner's leg_yaw from its snapshots, used instead of the twist computed here (NAN = compute it).
var twist_override := NAN
var sag := 0.0               ## the shutdown slump now: 0 standing, 1 slumped (overshoots past either end while easing)
## A hover chassis (the Wasp: model.is_hover()) has no gait: update_pose hands the model to this instead (bank, fan tilt,
## rotor spin, legs from the motion; scripts/mech/motion/hover_pose.gd).
var hover_pose := HoverPose.new()

var _body: MechController
var _air_time := 0.0
var _airborne := false
var _prev_xf := Transform3D.IDENTITY   ## the model's global transform last frame (carries hanging feet)
var _land_t := INF                     ## seconds since touchdown
var _land_depth := 0.0                 ## this landing's dip (model units)
var _reversed := false                 ## the legs walk backward (travel more than ~90 deg from the body facing)
var _pilot_facing := Vector3.ZERO      ## the body's facing last frame (the pilot head's yaw rate)
var _pilot_steps: Array = [{}, {}]     ## each foot's last landed step info last frame (the pilot head's footfall)
var _sag_v := 0.0                      ## the slump spring's velocity (share of sag_depth per second)
var _rise_t := INF                     ## seconds since the reboot rise began (the shudder)
var _rig_chassis := "strider"          ## the chassis whose rig numbers are applied (apply_chassis_rig; the vars' initial
                                       ## values are the Strider's, so a Strider never re-applies them over a lab's tuning)

## Per-chassis rig numbers (ChassisParts "rig": {rig var or "gait.<Gait var>": value}, plus "twist_max"): applied over
## these defaults, which are the Strider's (the vars' own initial values above and Gait's), whenever the model's chassis
## changes (update_pose checks it), so a respawn, a puppet, the hangar and the lab all pose a chassis the same way.
const RIG_KEYS := ["bob", "lean", "sway", "foot_gap", "step_margin", "air_tuck", "absorb", "absorb_time", "sag_depth",
	"sag_pitch", "sag_roll", "sag_time", "twist_max", "twist_rate"]
const GAIT_KEYS := ["step_length", "min_stride", "step_time", "run_step_time", "min_step_time", "step_height", "land_time",
	"settle_time", "settle_error", "step_clearance", "overlap_k", "reach_err"]
static var _defaults: Dictionary = {}


## Authority (scripts/net/net.gd): presentation, recomputed on every machine from the mech's motion, except `leg_yaw`,
## which the owner streams (NetMechCodec) so a puppet's legs turn exactly as its owner's; the tuning is fixed at spawn.
func net_fields() -> Dictionary:
	return {"mech_scale": Net.SPAWN, "bob": Net.SPAWN, "lean": Net.SPAWN, "sway": Net.SPAWN, "foot_gap": Net.SPAWN,
		"step_margin": Net.SPAWN, "probe_up": Net.SPAWN, "probe_down": Net.SPAWN, "air_tuck": Net.SPAWN,
		"absorb": Net.SPAWN, "absorb_time": Net.SPAWN, "twist_max": Net.SPAWN, "twist_rate": Net.SPAWN,
		"sag_depth": Net.SPAWN, "sag_pitch": Net.SPAWN, "sag_roll": Net.SPAWN, "sag_time": Net.SPAWN,
		"model": Net.LOCAL, "gait": Net.LOCAL, "leg_yaw": Net.OWNER, "reached_fraction": Net.LOCAL,
		"twist_override": Net.LOCAL, "sag": Net.LOCAL, "_body": Net.LOCAL, "_air_time": Net.LOCAL, "_airborne": Net.LOCAL,
		"_prev_xf": Net.LOCAL, "_land_t": Net.LOCAL, "_land_depth": Net.LOCAL, "_reversed": Net.LOCAL,
		"_pilot_facing": Net.LOCAL, "_pilot_steps": Net.LOCAL, "_sag_v": Net.LOCAL, "_rise_t": Net.LOCAL,
		"_rig_chassis": Net.LOCAL, "hover_pose": Net.LOCAL}


## The Strider's rig and gait numbers (a fresh MechRig / Gait's), once.
static func defaults() -> Dictionary:
	if _defaults.is_empty():
		var r := MechRig.new()
		for k: String in RIG_KEYS:
			_defaults[k] = r.get(k)
		for k: String in GAIT_KEYS:
			_defaults["gait." + k] = r.gait.get(k)
		r.free()
	return _defaults


## Pose chassis `id`: the defaults (the Strider's), then its ChassisParts "rig" entries and its "twist_max". The feet
## re-plant at the next update.
func apply_chassis_rig(id: String) -> void:
	_rig_chassis = id
	var pa := ChassisParts.of(id)
	var over: Dictionary = pa.get("rig", {})
	var d := defaults()
	for k: String in d:
		var v: Variant = over.get(k, d[k])
		if k.begins_with("gait."):
			gait.set(k.trim_prefix("gait."), v)
		else:
			set(k, v)
	if pa.has("twist_max"):
		twist_max = float(pa["twist_max"])
	leg_yaw = clampf(leg_yaw, -twist_max, twist_max)
	gait.reset([])


## Apply the model's chassis' rig numbers if they are not the ones in use.
func sync_chassis() -> void:
	if model != null and model.chassis_id != _rig_chassis:
		apply_chassis_rig(model.chassis_id)


func _ready() -> void:
	_body = get_parent() as MechController
	model = MechModel.new()
	model.name = "Model"
	add_child(model)
	model.scale = Vector3.ONE * mech_scale
	model.time_scale = 0.0   # the model's own idle bob is off; this rig drives it
	process_physics_priority = 10   # after the controller has moved this frame


func set_scale_factor(v: float) -> void:
	mech_scale = v
	if model != null:
		model.scale = Vector3.ONE * v
	gait.reset([])


func _physics_process(delta: float) -> void:
	if PerfProbe.on:   # bench instrumentation (tests/bench_bot_perf.gd), off in play
		var t0 := Time.get_ticks_usec()
		update_pose(delta)
		var bot := _body != null and str(_body.name).begins_with("Mech_bot")
		PerfProbe.add("mech.rig.bot" if bot else "mech.rig.other", Time.get_ticks_usec() - t0)
		return
	update_pose(delta)


func update_pose(delta: float) -> void:
	if _body == null or model == null:
		return
	sync_chassis()
	if model.is_hover():
		hover_pose.update(delta, _body, model)   # no gait, no IK: the hover chassis poses from its motion
		return
	var up := _body.up()
	var vel := _body.velocity
	var on_floor := _body.grounded()
	_air_time = 0.0 if on_floor else _air_time + delta
	var flat := vel - up * vel.dot(up)
	var travel := _update_twist(delta, flat, _air_time <= AIR_DELAY)   # body-local travel direction (zero when standing)
	var tw := MechModel.twist_basis(leg_yaw)
	gait.facing = (model.global_basis * (tw * Vector3.FORWARD)).normalized()
	var homes: Array = []
	var high := INF   # how far the body is above the ground under its hips, beyond standing (m)
	for side: float in [-1.0, 1.0]:
		var hip := model.to_global(tw * model.hip_local(side))
		var g := ground_under(hip, up)
		homes.append(g)
		high = minf(high, (hip - g).dot(up) - model.hip_local(side).y * mech_scale)
	gait.run_speed = _body.run_speed
	gait.foot_clearance = foot_gap * mech_scale
	gait.max_lift = max_foot_lift()
	gait.max_step = max_step()
	var airborne := not on_floor and (_air_time > AIR_DELAY or high > max_step() + 0.5)
	if airborne:
		# Feet hang under the hips, relative to the body: carry them with it, then ease toward the tuck.
		if _airborne:
			var carry := model.global_transform * _prev_xf.affine_inverse()
			for f: Dictionary in gait.feet:
				f["pos"] = carry * (f["pos"] as Vector3)
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var hang := model.to_global(hang_local(side))
			var over := ((homes[i] as Vector3) - hang).dot(up)   # ground above the hanging foot
			# Never below the ground when it is near; ground far above the foot is not a foothold (the body is under
			# a ledge, or off the deck where ground_under falls back to the ring floor).
			if over <= 0.0 or over > max_step():
				homes[i] = hang
	elif _airborne:
		_land_t = 0.0
		var hard := maxf(_body.hard_land_speed, 0.1)
		_land_depth = absorb * clampf(_body.last_impact / hard, 0.0, 1.0)
	_airborne = airborne
	_prev_xf = model.global_transform
	gait.update(delta, homes, up, vel, ground_under, airborne, _body.global_position)
	var k := clampf(flat.length() / maxf(_body.run_speed, 0.1), 0.0, 1.0)
	var feet_l: Array = []
	var dirs_l: Array = []
	var inv := model.global_basis.inverse()
	for f: Dictionary in gait.feet:
		feet_l.append(model.to_local(f["pos"]))
		var d: Vector3 = f.get("dir", Vector3.ZERO)
		dirs_l.append(inv * d if d.length_squared() > 1e-6 else Vector3.ZERO)
	# Body: dip toward the lower foot (stepping down a curb, never more than a step), bob between steps, lean into
	# speed, roll over the planted foot, absorb a landing. In the air: none of the ground terms.
	var dip := 0.0
	if _land_t < absorb_time * 8.0:
		var x := _land_t / maxf(absorb_time, 0.01)
		dip = _land_depth * x * exp(1.0 - x)   # down fast, back up slowly
		_land_t += delta
	var offset := Vector3(0.0, -dip, 0.0)
	if not airborne:
		var low := minf(0.0, minf((feet_l[0] as Vector3).y, (feet_l[1] as Vector3).y))
		low = maxf(low, -max_step() / mech_scale)
		offset.y += low * 0.7 - bob * k * (1.0 - gait.lift_amount())
	var planted_side := 0.0
	if gait.feet.size() == 2:
		planted_side = (-1.0 if not gait.feet[0]["stepping"] else 0.0) + (1.0 if not gait.feet[1]["stepping"] else 0.0)
	# Lean into the travel direction (about its right), roll over the planted foot (about the legs' forward). Small
	# angles: the two rotation vectors add up as the body's euler rotation (both horizontal, so no yaw).
	var go := travel if travel != Vector3.ZERO else Vector3.FORWARD
	var leg_fwd := tw * Vector3.FORWARD
	var rot := go.cross(Vector3.UP) * (-lean * k) + leg_fwd * (sway * planted_side * minf(k * 3.0, 1.0))
	# Heat shutdown: slump (the feet stay planted; only the body and so the hips move).
	_update_sag(delta, _body.shutdown and not airborne)
	offset += sag_offset()
	rot += sag_rot()
	var lengths := model.leg_lengths()
	var legs: Array = []
	var reached := 0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip := model.hip_posed(side, offset, rot, leg_yaw)   # the hips ride the pelvis: lean, sway and twist with it
		var r := LegIK.solve_leg(hip, feet_l[i], lengths.x, lengths.y, lengths.z, Vector3.UP, leg_fwd,
				model.tarsus_lean(), model.leg_bend)
		if r["reached"]:
			reached += 1
		legs.append({"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"], "foot_dir": dirs_l[i]})
	reached_fraction = float(reached) / 2.0
	model.set_external_pose(legs, offset, rot, leg_yaw)
	# The pilot's head: motion in the hull's frame (model units), turning (+ = left), landings, effort, foot plants.
	if model.pilot != null:
		var hull := _body.global_basis.orthonormalized()
		var facing := _body.forward() - up * _body.forward().dot(up)
		var yaw_rate := 0.0
		if delta > 0.0 and _pilot_facing.length_squared() > 1e-6 and facing.length_squared() > 1e-6:
			yaw_rate = _pilot_facing.signed_angle_to(facing, up) / delta
		_pilot_facing = facing
		var footfall := false
		for i in mini(gait.feet.size(), 2):
			var last: Dictionary = gait.feet[i].get("last", {})
			if not is_same(last, _pilot_steps[i]) and str(last.get("kind", "")) == "stride":
				footfall = true
			_pilot_steps[i] = last
		model.pilot.idle_always = false
		model.pilot.feed(delta, {"vel": hull.inverse() * vel / mech_scale, "yaw_rate": yaw_rate, "grounded": on_floor,
			"effort": (_body.running and flat.length() > 1.0) or _body._climbing, "footfall": footfall})


## Ease leg_yaw toward the travel direction (see the header); returns the travel direction in body space (unit,
## horizontal; zero below the twist's start speed). In the air the legs turn back to the body facing (they hang under
## the torso, and the thruster nozzles on the hips point the way the body does).
func _update_twist(delta: float, flat: Vector3, on_ground: bool = true) -> Vector3:
	var speed := flat.length()
	var target := 0.0
	var travel := Vector3.ZERO
	if speed > 0.05:
		travel = _body.global_basis.orthonormalized().inverse() * (flat / speed)
		travel = Vector3(travel.x, 0.0, travel.z).normalized()
	if on_ground and speed > TWIST_SPEED.x and travel != Vector3.ZERO:
		var a := atan2(travel.x, -travel.z)   # travel angle from the body facing, + = toward its right
		if absf(leg_yaw) < 0.02:
			_reversed = absf(a) > TWIST_PICK   # legs at the body facing: pick afresh
		elif _reversed and absf(a) < PI * 0.5 - TWIST_HYST:
			_reversed = false
		elif not _reversed and absf(a) > PI * 0.5 + TWIST_HYST:
			_reversed = true
		var t := wrapf(a + PI, -PI, PI) if _reversed else a
		target = clampf(t, -twist_max, twist_max) * smoothstep(TWIST_SPEED.x, TWIST_SPEED.y, speed)
	leg_yaw = twist_override if not is_nan(twist_override) else move_toward(leg_yaw, target, twist_rate * delta)
	return travel if speed > TWIST_SPEED.x * 0.5 else Vector3.ZERO


## Ease `sag` toward 1 (slumped) or 0 on an underdamped spring that settles in about sag_time; a rise starts the
## reboot shudder.
func _update_sag(delta: float, slumped: bool) -> void:
	var target := 1.0 if slumped else 0.0
	if not slumped and sag > 0.5 and _rise_t == INF:
		_rise_t = 0.0   # the reboot: rising from the slump
	elif slumped:
		_rise_t = INF
	if _rise_t != INF:
		_rise_t += delta
		if _rise_t > 0.6:
			_rise_t = INF
	if absf(sag - target) < 1e-4 and absf(_sag_v) < 1e-3:
		sag = target
		_sag_v = 0.0
		return
	var damp := SAG_DAMP if slumped else RISE_DAMP
	# Natural frequency for the first peak at about 0.55 of sag_time.
	var w := PI / (maxf(sag_time, 0.05) * 0.55 * sqrt(1.0 - damp * damp))
	var n := maxi(1, ceili(delta * w / 0.25))   # sub-steps keep the spring stable at big deltas
	var h := delta / float(n)
	for i in n:
		_sag_v += (w * w * (target - sag) - 2.0 * damp * w * _sag_v) * h
		sag += _sag_v * h


## The slump's body offset now (model units; zero standing): down by sag_depth, plus the reboot shudder.
func sag_offset() -> Vector3:
	var y := -sag_depth * sag
	if _rise_t != INF:
		y += sag_depth * SHUDDER.x * sin(_rise_t * TAU * SHUDDER.y) * exp(-_rise_t * 8.0)
	return Vector3(0.0, y, 0.0)


## The slump's body rotation now (rad, added to the body's euler rotation): forward pitch and a list to one side.
func sag_rot() -> Vector3:
	var r := Vector3(-sag_pitch * sag, 0.0, sag_roll * sag)
	if _rise_t != INF:
		r.z += sag_roll * 0.6 * sin(_rise_t * TAU * SHUDDER.y * 0.8 + 1.0) * exp(-_rise_t * 8.0)
	return r


## Where foot `side` hangs in the air, in model space: under its hip, tucked up by air_tuck of the max lift.
func hang_local(side: float) -> Vector3:
	var hip := model.hip_local(side)
	return MechModel.twist_basis(leg_yaw) * Vector3(hip.x, model.max_foot_lift() * air_tuck, -0.05)


## How high a foot can lift before the leg folds too far (m, world): the top of a step's arc.
func max_foot_lift() -> float:
	return model.max_foot_lift() * mech_scale if model != null else 0.0


## The highest ledge the legs step onto (m, world): a share of the foot lift. Taller is a wall.
func max_step() -> float:
	return max_foot_lift() * step_margin


## The ground under point p along local down (physics ray; falls back to the ring floor or y = 0).
func ground_under(p: Vector3, up: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(p + up * probe_up, p - up * probe_down)
		if _body != null:
			q.exclude = [_body.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]
	if _body != null and _body.ring != null:
		return p - up * _body.ring.height(p)
	return Vector3(p.x, 0.0, p.z)
