class_name MechController
extends CharacterBody3D
## The mech's body in the world: a kinematic character (no rigid bodies, so motion can be replayed) whose "up" follows
## the ring's gravity at its position (RingFrame). It turns, walks/runs and strafes from an input vector, falls along
## local gravity, and keeps its basis upright to the local floor every physics frame.
##
## Stepping up: a ledge no higher than `max_step_up` above the feet is climbed, not a wall. When a move is blocked by
## an edge that low, the body rises along local up (at `climb_speed`) and retries the move, so it rides over the edge
## instead of popping onto it. Anything taller blocks: use the thrusters. The origin is at the feet.
##
## Thrusters (S2): `thrust_input` (Space) pushes along local up at `thrust_accel` (more than gravity, so it lifts),
## costing heat. On a long fall an automatic landing burn fires as late as is safe (a "suicide burn", AUTO_LAND_ON) and
## brakes only to `auto_land_speed` (16 m/s): the touchdown is a heavy `hard_landing` (camera dip, audio, rig) but below
## PlayerTarget's fall-damage speed (20). The touchdown point is swept with the capsule's bottom under the feet and ahead
## along the ground-plane velocity (landing_distance), so roof edges and lower roofs count. Shut down (or overheating
## mid-burn) = no burn: the fall is uncushioned (leg damage, docs/design/weapons.md "Fall damage"). Heat is the primary limit: thrust, walking and running heat, the frame cools; at `heat_cap` the mech
## SHUTS DOWN (no move, no thrust), cools to `reboot_heat`, then reboots after `reboot_time`.
##
## Blocked motion: vertical velocity is reconciled with the motion move_and_slide achieved (_reconcile), a body jammed in
## the air is zeroed and nudged free (_unstick), and speed is capped at MAX_SPEED, so gravity never piles up while the
## mech cannot move (no fling, no false hard landing).
##
## Per chassis (apply_chassis, from MechCatalog's "movement" block; MechSpawn applies it on every machine): speeds, turn,
## accel, thrust, heat, landing thresholds and the capsule. The Bulwark's thrust only hops and brakes: `thrust_ceiling`
## (m above the ground under the feet) throttles the pilot's thrust so it settles there; falling, it brakes at full
## strength (the automatic burn ignores the ceiling). The Strider has none (0).
##
## Input comes from whoever drives it (player, lab bot, later the network for puppets): set `move_input`, `turn_input`,
## `running` and `thrust_input`. Weapons add heat through `add_heat()` (S4).
##
## Networking: the owner's machine runs this; position, velocity and facing (engine properties) will be streamed by the
## mech codec in S7. Remote copies will be interpolated puppets, not simulated.

var ring: RingFrame                  ## the deck this mech stands on; null = flat world (+Y up)
var walk_speed := 12.0               ## m/s
var run_speed := 22.0                ## m/s
var strafe_scale := 1.0              ## sideways speed as a fraction of forward speed (full-speed strafe for clean dodging)
var accel := 30.0                    ## m/s^2 toward the wanted velocity (walk in 0.4 s, run in 0.7 s)
var turn_rate := 1.8                 ## rad/s at full turn input
var gravity := 22.0                  ## m/s^2 along local down (mechs fall heavy)
var max_step_up := 0.0               ## highest ledge (m above the feet) the legs step onto; 0 = none
var climb_speed := 10.0              ## m/s the body rises while stepping up (keeps pace with the walk)
var thrust_accel := 34.0             ## m/s^2 along local up while thrusting (gravity is subtracted)
var air_control := 0.35              ## share of `accel` available while airborne
var thrust_heat := 24.0              ## heat per second of thrust
var walk_heat := 2.5                 ## heat/s walking at walk_speed (scales with ground speed; docs/design/weapons.md)
var run_heat := 9.0                  ## heat/s running at run_speed (lerps from walk_heat above walk_speed)
var cooling := 9.0                   ## heat shed per second
var heat_cap := 100.0                ## overheat: shutdown
var reboot_heat := 35.0              ## cooled to this, the reboot starts
var reboot_time := 1.2               ## seconds of reboot before control returns
var auto_burn := true                ## emergency burn on long falls
var safe_land_speed := 10.0          ## m/s down: landings at or below this are soft
var hard_land_speed := 18.0          ## m/s down: landings at this or more are the worst hard landing
var auto_land_speed := 16.0          ## m/s down: the automatic burn brakes a fall only to this (a heavy landing, below
                                     ## PlayerTarget.FALL_DAMAGE_SPEED 20 with headroom: tests/test_auto_land.gd)
var thrust_ceiling := 0.0            ## m above the ground under the feet where the pilot's thrust stops lifting (it then
                                     ## hovers there and still brakes a fall at full strength); 0 = no ceiling (Strider)
var chassis_id := "strider"          ## the MechCatalog chassis whose movement block was applied (apply_chassis)

signal hard_landing(speed: float, severity: float)   ## severity 0..1 above safe_land_speed
signal overheated
signal rebooted

var move_input := Vector2.ZERO       ## x = strafe right, y = forward; length <= 1
var turn_input := 0.0                ## -1 left .. +1 right
var running := false
var thrust_input := false

var heat := 0.0                      ## 0..heat_cap
var shutdown := false                ## overheated: no control until rebooted
var thrusting := false               ## thrust applied this step (player or emergency burn)
var emergency := false               ## the thrust this step is the automatic burn
var last_impact := 0.0               ## m/s down at the last touchdown

## Co-op (docs/networking.md, mech snapshots): the crew peer whose machine drives this mech (0 = nobody's: labs, solo
## before MechSpawn sets it). A PUPPET is another machine's mech shown here: it runs no step() (no input, no physics);
## the game (scripts/game/mech_puppet.gd) writes its transform, velocity, heat and thrust state from the owner's
## snapshots, and `puppet_grounded` stands in for the floor test, so MechRig / ThrusterFx pose it as they pose your own.
var owner_peer := 0
var puppet := false
var puppet_grounded := true          ## a puppet's grounded(): the owner's, from its snapshot

var _climbing := false               ## rising over a ledge this step (counts as grounded)
var _reboot_t := 0.0
var _was_grounded := true
var _fall_speed := 0.0               ## m/s down, last airborne step
var _wedge_t := 0.0                  ## s of consecutive wedged steps (see _unstick)
var _wedge_nudge := 0.0              ## m nudged free in this wedge episode
var _burn_throttle := 1.0            ## share of thrust_accel the automatic burn uses this step (heat scales with it)
var _thrust_share := 1.0             ## share of thrust_accel the pilot's thrust uses this step (thrust_ceiling; heat scales)
var _probe: SphereShape3D            ## the landing probe: the capsule's bottom (radius x PROBE_SHRINK); null = a ray

const MAX_SPEED := 150.0             ## m/s backstop (a 3-deck free fall is ~80, a long thrust climb less)
const RECONCILE_SLACK := 0.5         ## m/s of vertical speed the achieved motion may lag before it is cut back
const WEDGE_MIN_SINK := 0.2          ## m/s down asked of the body before a step can count as wedged
const WEDGE_SINK_SHARE := 0.4        ## share of the asked sink a wedged step makes at most
const WEDGE_TIME := 0.25             ## s of wedged steps before the velocity is zeroed and the nudge starts
const WEDGE_NUDGE_SPEED := 3.0       ## m/s the nudge moves the body
const WEDGE_NUDGE_MAX := 6.0         ## m of nudge per wedge episode (a slot it cannot leave keeps it, at rest)
## Automatic landing burn: it starts when braking to auto_land_speed by the touchdown point needs AUTO_LAND_ON of the
## full braking (thrust_accel - gravity), then throttles to exactly the braking still needed (about 95 % thrust), and
## lets go if that need drops under AUTO_LAND_OFF (the ground fell away). The rest of the braking is the margin that
## absorbs step size, a ramp rising ahead and a roof edge appearing late.
const AUTO_LAND_ON := 0.9
const AUTO_LAND_OFF := 0.5
const PROBE_SHRINK := 0.9            ## landing probe radius / capsule radius (a narrower graze slides off, no floor)
const PROBE_AHEAD_PAD := 0.3         ## s added to the burn time when looking ahead along the ground-plane velocity
const PROBE_AHEAD_MAX := 3.0         ## s, cap of the look-ahead time
## Thrust ceiling (thrust_ceiling > 0): the pilot's thrust is throttled so the body rises no faster than it could coast up
## to the ceiling, settles there (CEILING_GAIN: 1/s, how hard it holds the allowed vertical speed) and above it sinks back
## at CEILING_SINK m/s at most; falling faster than that, the thrust brakes at full strength.
const CEILING_GAIN := 6.0
const CEILING_SINK := 1.0
const CEILING_PROBE := 4.0           ## m probed past the ceiling (beyond it the ground counts as far away)


func net_fields() -> Dictionary:
	return {
		"ring": Net.SPAWN, "walk_speed": Net.SPAWN, "run_speed": Net.SPAWN, "strafe_scale": Net.SPAWN, "accel": Net.SPAWN,
		"turn_rate": Net.SPAWN, "gravity": Net.SPAWN, "max_step_up": Net.SPAWN, "climb_speed": Net.SPAWN,
		"thrust_accel": Net.SPAWN, "air_control": Net.SPAWN, "thrust_heat": Net.SPAWN, "cooling": Net.SPAWN,
		"walk_heat": Net.SPAWN, "run_heat": Net.SPAWN,
		"heat_cap": Net.SPAWN, "reboot_heat": Net.SPAWN, "reboot_time": Net.SPAWN, "auto_burn": Net.SPAWN,
		"safe_land_speed": Net.SPAWN, "hard_land_speed": Net.SPAWN, "auto_land_speed": Net.SPAWN,
		"thrust_ceiling": Net.SPAWN, "chassis_id": Net.SPAWN, "_thrust_share": Net.PRIVATE,
		"move_input": Net.PRIVATE, "turn_input": Net.PRIVATE, "running": Net.PRIVATE, "thrust_input": Net.PRIVATE,
		"heat": Net.OWNER, "shutdown": Net.OWNER, "thrusting": Net.OWNER, "emergency": Net.OWNER,
		"last_impact": Net.OWNER, "puppet_grounded": Net.OWNER,
		"owner_peer": Net.SPAWN, "puppet": Net.SPAWN,
		"_climbing": Net.PRIVATE, "_reboot_t": Net.PRIVATE, "_was_grounded": Net.PRIVATE, "_fall_speed": Net.PRIVATE,
		"_wedge_t": Net.PRIVATE, "_wedge_nudge": Net.PRIVATE, "_burn_throttle": Net.PRIVATE, "_probe": Net.LOCAL,
	}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_snap_length = 1.2
	floor_max_angle = deg_to_rad(50.0)
	floor_stop_on_slope = true
	floor_constant_speed = true


## Take chassis `id`'s movement numbers (MechCatalog.movement: speeds, turn, accel, thrust, heat, landing thresholds,
## heat_cap / cooling) and size the collision capsule (a CollisionShape3D child holding a CapsuleShape3D, its bottom at the
## feet) to the chassis' capsule_radius / capsule_height. Every machine applies it at spawn from the crew entry's chassis
## (MechSpawn.make), so puppets carry the same numbers and nothing extra is streamed.
func apply_chassis(id: String) -> void:
	chassis_id = id if MechCatalog.CHASSIS.has(id) else "strider"
	var mv := MechCatalog.movement(chassis_id)
	for k: String in MechCatalog.MOVEMENT_KEYS:
		set(k, float(mv[k]))
	heat_cap = float(mv["heat_cap"])
	cooling = float(mv["cooling"])
	for c in get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			var cap := (c as CollisionShape3D).shape as CapsuleShape3D
			cap.radius = float(mv["capsule_radius"])
			cap.height = float(mv["capsule_height"])
			(c as CollisionShape3D).position = Vector3(0, cap.height * 0.5, 0)
			_probe = null   # the landing probe follows the capsule's radius
			break


func up() -> Vector3:
	return ring.up_at(global_position) if ring != null else Vector3.UP


func forward() -> Vector3:
	return -global_basis.z


## Speed along the local floor.
func ground_speed() -> float:
	var u := up()
	return (velocity - u * velocity.dot(u)).length()


## On the floor, or stepping up onto a ledge.
func grounded() -> bool:
	if puppet:
		return puppet_grounded
	return is_on_floor() or _climbing


func _physics_process(delta: float) -> void:
	if puppet:
		return   # another machine's mech: posed from its snapshots, never simulated here
	if PerfProbe.on:   # bench instrumentation (tests/bench_bot_perf.gd), off in play
		var t0 := Time.get_ticks_usec()
		step(delta)
		PerfProbe.add("mech.ctrl.bot" if str(name).begins_with("Mech_bot") else "mech.ctrl.local", Time.get_ticks_usec() - t0)
		return
	step(delta)


## One physics step (public so tests can drive it).
func step(delta: float) -> void:
	var u := up()
	up_direction = u
	var live := not shutdown
	# Keep the body upright to the local floor, keeping its heading, then turn about local up.
	var f := forward() - u * forward().dot(u)
	if f.length_squared() < 1e-8:
		f = (ring.basis_at(global_position) if ring != null else Basis.IDENTITY) * Vector3.FORWARD
	f = f.normalized().rotated(u, -(turn_input if live else 0.0) * turn_rate * delta)
	global_basis = Basis(f.cross(u), u, -f)
	# Wanted velocity along the floor.
	var mv := move_input if live else Vector2.ZERO
	var wish := f * mv.y + f.cross(u) * mv.x * strafe_scale
	if wish.length() > 1.0:
		wish = wish.normalized()
	var top := run_speed if running else walk_speed
	var vert := u * velocity.dot(u)
	var flat := velocity - vert
	var on_ground := grounded()
	flat = flat.move_toward(wish * top, accel * (1.0 if on_ground else air_control) * delta)
	# Thrust: the pilot's, or the automatic landing burn on a long fall (a late "suicide burn" down to auto_land_speed:
	# AUTO_LAND_ON / AUTO_LAND_OFF above).
	var vs := velocity.dot(u)
	var was_burning := emergency
	emergency = false
	_burn_throttle = 1.0
	if live and auto_burn and not on_ground and not thrust_input and -vs > auto_land_speed:
		var brake := maxf(thrust_accel - gravity, 0.1)
		var excess := vs * vs - auto_land_speed * auto_land_speed
		var start_dist := excess / (2.0 * brake * AUTO_LAND_ON)
		var ahead := clampf((-vs - auto_land_speed) / (brake * AUTO_LAND_ON) + PROBE_AHEAD_PAD, 0.0, PROBE_AHEAD_MAX)
		var d := landing_distance(start_dist * 2.5 + 4.0, flat * ahead)   # nothing in range: need < AUTO_LAND_OFF, no burn
		var need := excess / (2.0 * maxf(d, 0.01))   # m/s^2 of braking that reaches auto_land_speed at the touchdown
		if need >= brake * (AUTO_LAND_OFF if was_burning else AUTO_LAND_ON):
			emergency = true
			_burn_throttle = clampf((need + gravity) / maxf(thrust_accel, 0.1), 0.0, 1.0)
	thrusting = live and (thrust_input or emergency)
	_thrust_share = 1.0
	if thrusting and not emergency and thrust_ceiling > 0.0:
		# The hop ceiling: rise no faster than a coast up to thrust_ceiling allows, hold it there, sink back above it;
		# a fall faster than CEILING_SINK gets the full thrust (it brakes).
		var h := ground_distance(thrust_ceiling + CEILING_PROBE)
		var allow := sqrt(2.0 * gravity * maxf(thrust_ceiling - h, 0.0)) - minf(maxf(h - thrust_ceiling, 0.0), CEILING_SINK)
		_thrust_share = clampf((gravity + CEILING_GAIN * (allow - vs)) / maxf(thrust_accel, 0.1), 0.0, 1.0)
	if thrusting:
		vert += u * thrust_accel * (_burn_throttle if emergency else _thrust_share) * delta
		if on_ground:
			_climbing = false   # lift off: leave the floor this step
	if on_ground and not thrusting:
		vert = Vector3.ZERO
	else:
		vert -= u * gravity * delta
	velocity = flat + vert
	var want := flat
	var p0 := global_position
	var vs0 := velocity.dot(u)
	move_and_slide()
	var moved := global_position - p0
	_reconcile(u, moved, delta)
	_climbing = _step_up(u, want, delta)
	_unstick(u, vs0, moved, delta)
	velocity = velocity.limit_length(MAX_SPEED)
	_update_heat(delta)
	_check_landing(u)


## Velocity along local up must match the motion move_and_slide achieved. In grounded mode Godot only clears velocity on
## a floor (and slides it on a ceiling): against walls, or when the capsule is jammed into two faces it cannot depenetrate
## from, the motion is blocked but `velocity` keeps whatever gravity / thrust added, so it grew ~22 m/s every second while
## the mech stood still (5767 m/s seen on a bot run) and would fling it, or land it "hard", once free. With contacts this
## step, a vertical speed the body did not actually make is cut back to the achieved one (never past zero).
func _reconcile(u: Vector3, moved: Vector3, delta: float) -> void:
	if delta <= 0.0 or get_slide_collision_count() == 0:
		return
	var vs := velocity.dot(u)
	var real := moved.dot(u) / delta
	if vs < 0.0 and real > vs + RECONCILE_SLACK:
		velocity += u * (minf(real, 0.0) - vs)
	elif vs > 0.0 and real < vs - RECONCILE_SLACK:
		velocity += u * (maxf(real, 0.0) - vs)


## Wedged: airborne by our reckoning (not grounded, not thrusting), touching something, asked to sink (vs0 below
## -WEDGE_MIN_SINK) and making less than WEDGE_SINK_SHARE of it, every step for WEDGE_TIME. A free fall, a fall grazing a
## wall and a slide down any wall steeper than floor_max_angle all make most of their sink (sin^2 50 deg = 0.59), so only
## a body held up by faces it is not standing on counts (the capsule can jitter sideways there: Godot's depenetration
## pushes it back and forth). Its velocity is phantom (zeroed: no fling, no hard landing from it), and it is nudged free
## along the summed contact normals tilted up (straight up when they cancel, as between two faces), at WEDGE_NUDGE_SPEED,
## at most WEDGE_NUDGE_MAX m per episode. Deterministic; owner only (puppets run no step()).
func _unstick(u: Vector3, vs0: float, moved: Vector3, delta: float) -> void:
	var n := get_slide_collision_count()
	var blocked := not grounded() and not thrusting and n > 0 and delta > 0.0 and vs0 < -WEDGE_MIN_SINK \
		and moved.dot(u) / delta > vs0 * WEDGE_SINK_SHARE
	if not blocked:
		_wedge_t = 0.0
		_wedge_nudge = 0.0
		return
	_wedge_t += delta
	if _wedge_t < WEDGE_TIME:
		return
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	if _wedge_nudge >= WEDGE_NUDGE_MAX:
		return
	var sum := Vector3.ZERO
	for i in n:
		sum += get_slide_collision(i).get_normal()
	var dir := (sum.normalized() + u).normalized() if sum.length() > 0.5 else u
	var stepd := minf(WEDGE_NUDGE_SPEED * delta, WEDGE_NUDGE_MAX - _wedge_nudge)
	global_position += dir * stepd
	_wedge_nudge += stepd


## Heat from outside (weapons fire, flamers): pushes toward shutdown.
func add_heat(amount: float) -> void:
	heat = clampf(heat + amount, 0.0, heat_cap)
	if heat >= heat_cap and not shutdown:
		_overheat()


func _update_heat(delta: float) -> void:
	if thrusting:
		heat += thrust_heat * (_burn_throttle if emergency else _thrust_share) * delta
	heat += move_heat_rate() * delta
	heat = maxf(heat - cooling * delta, 0.0)
	if heat >= heat_cap and not shutdown:
		heat = heat_cap
		_overheat()
	elif shutdown and heat <= reboot_heat:
		_reboot_t += delta
		if _reboot_t >= reboot_time:
			shutdown = false
			rebooted.emit()
	heat = minf(heat, heat_cap)


## Heat/s from walking / running now: from the actual ground speed, only on the ground, live, not thrusting and with
## move input (a knockback slide or a ride with no input adds nothing). Walk: walk_heat * v / walk_speed; above it lerps
## to run_heat at run_speed, clamped there. Owner only (a puppet runs no step()).
func move_heat_rate() -> float:
	if puppet or shutdown or thrusting or move_input.length_squared() < 1e-4 or not grounded():
		return 0.0
	var v := ground_speed()
	if v <= walk_speed:
		return walk_heat * v / maxf(walk_speed, 0.01)
	return lerpf(walk_heat, run_heat, clampf((v - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0))


func _overheat() -> void:
	shutdown = true
	_reboot_t = 0.0
	thrusting = false
	overheated.emit()


func _check_landing(u: Vector3) -> void:
	var g := grounded()
	if not g:
		_fall_speed = maxf(-velocity.dot(u), 0.0)
	elif not _was_grounded:
		last_impact = _fall_speed
		if _fall_speed > safe_land_speed:
			var sev := clampf((_fall_speed - safe_land_speed) / maxf(hard_land_speed - safe_land_speed, 0.1), 0.0, 1.0)
			hard_landing.emit(_fall_speed, sev)
		_fall_speed = 0.0
	_was_grounded = g


## Distance down along local gravity to where the feet would touch (up to `max_dist`; max_dist when nothing is there).
## Swept with the capsule's own bottom (a sphere of its radius x PROBE_SHRINK) from `from` (default: the feet), so a
## roof edge under the capsule but beside its centre counts, and a slope reads where the body meets it; a ray when the
## mech has no capsule.
func ground_distance(max_dist: float = 200.0, from: Variant = null) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return max_dist
	var u := up()
	var p: Vector3 = global_position if from == null else from
	var probe := _landing_probe()
	if probe == null:
		var q := PhysicsRayQueryParameters3D.create(p + u * 0.2, p - u * max_dist)
		q.exclude = [get_rid()]
		q.collision_mask = collision_mask
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return max_dist
		return maxf(((hit["position"] as Vector3) - p).dot(-u), 0.0)
	var lift := probe.radius + 0.2
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = probe
	sq.transform = Transform3D(Basis.IDENTITY, p + u * lift)
	sq.motion = -u * (max_dist + 0.2)
	sq.exclude = [get_rid()]
	sq.collision_mask = collision_mask
	var res := space.cast_motion(sq)
	if res.is_empty() or float(res[0]) >= 1.0:
		return max_dist
	return maxf(float(res[0]) * (max_dist + 0.2) - 0.2, 0.0)


## The nearest touchdown distance (ground_distance) under the feet and under where the mech will be along `ahead` (its
## ground-plane velocity x the look-ahead time): a lower roof it is about to pass over counts before it is underneath.
## The look-ahead stops at a wall in the way (swept at the probe's height), so it never probes from inside a building.
func landing_distance(max_dist: float, ahead: Vector3 = Vector3.ZERO) -> float:
	var d := ground_distance(max_dist)
	var probe := _landing_probe()
	if ahead.length() < 1.0 or probe == null or not is_inside_tree():
		return d
	var space := get_world_3d().direct_space_state
	var u := up()
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = probe
	sq.transform = Transform3D(Basis.IDENTITY, global_position + u * (probe.radius + 0.2))
	sq.motion = ahead
	sq.exclude = [get_rid()]
	sq.collision_mask = collision_mask
	var res := space.cast_motion(sq)
	var reach := ahead * (float(res[0]) if not res.is_empty() else 1.0)
	for k in [1.0 / 3.0, 2.0 / 3.0, 1.0]:
		d = minf(d, ground_distance(max_dist, global_position + reach * k))
	return d


func _landing_probe() -> SphereShape3D:
	if _probe == null:
		for c in get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
				_probe = SphereShape3D.new()
				_probe.radius = ((c as CollisionShape3D).shape as CapsuleShape3D).radius * PROBE_SHRINK
				break
	return _probe


## After a blocked move: if what blocked it is an edge within max_step_up of the feet, rise and retry. True if it did.
func _step_up(u: Vector3, want: Vector3, delta: float) -> bool:
	if max_step_up <= 0.0 or want.length() < 0.2:
		return false
	var dir := want.normalized()
	var floor_cos := cos(floor_max_angle)
	var low_edge := false
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var n := c.get_normal()
		if n.dot(u) >= floor_cos or n.dot(dir) > -0.1:
			continue   # a floor, or not in the way
		var h := (c.get_position() - global_position).dot(u)
		if h > max_step_up:
			return false   # a wall
		if h > 0.02:
			low_edge = true
	if not low_edge:
		return false
	var rise := move_and_collide(u * climb_speed * delta)
	if rise != null and rise.get_travel().length() < 1e-4:
		return false   # no headroom
	move_and_collide(want * delta)
	velocity = want
	return true
