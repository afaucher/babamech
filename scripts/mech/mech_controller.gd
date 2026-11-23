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
## costing heat. On a long fall an automatic emergency burn fires when the ground is closer than the braking distance;
## it is only an emergency system, so a long drop can still end in a hard landing (`hard_landing` signal: PlayerTarget
## turns it into leg damage, docs/design/weapons.md "Fall damage"; shut down = no burn). Heat is the primary limit: thrust, walking and running heat, the frame cools; at `heat_cap` the mech
## SHUTS DOWN (no move, no thrust), cools to `reboot_heat`, then reboots after `reboot_time`.
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


func net_fields() -> Dictionary:
	return {
		"ring": Net.SPAWN, "walk_speed": Net.SPAWN, "run_speed": Net.SPAWN, "strafe_scale": Net.SPAWN, "accel": Net.SPAWN,
		"turn_rate": Net.SPAWN, "gravity": Net.SPAWN, "max_step_up": Net.SPAWN, "climb_speed": Net.SPAWN,
		"thrust_accel": Net.SPAWN, "air_control": Net.SPAWN, "thrust_heat": Net.SPAWN, "cooling": Net.SPAWN,
		"walk_heat": Net.SPAWN, "run_heat": Net.SPAWN,
		"heat_cap": Net.SPAWN, "reboot_heat": Net.SPAWN, "reboot_time": Net.SPAWN, "auto_burn": Net.SPAWN,
		"safe_land_speed": Net.SPAWN, "hard_land_speed": Net.SPAWN,
		"move_input": Net.PRIVATE, "turn_input": Net.PRIVATE, "running": Net.PRIVATE, "thrust_input": Net.PRIVATE,
		"heat": Net.OWNER, "shutdown": Net.OWNER, "thrusting": Net.OWNER, "emergency": Net.OWNER,
		"last_impact": Net.OWNER, "puppet_grounded": Net.OWNER,
		"owner_peer": Net.SPAWN, "puppet": Net.SPAWN,
		"_climbing": Net.PRIVATE, "_reboot_t": Net.PRIVATE, "_was_grounded": Net.PRIVATE, "_fall_speed": Net.PRIVATE,
	}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_snap_length = 1.2
	floor_max_angle = deg_to_rad(50.0)
	floor_stop_on_slope = true
	floor_constant_speed = true


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
	# Thrust: the pilot's, or the emergency burn on a long fall.
	var vs := velocity.dot(u)
	emergency = false
	if live and auto_burn and not on_ground and not thrust_input and -vs > safe_land_speed:
		var brake := maxf(thrust_accel - gravity, 0.1)
		var stop_dist := (vs * vs - safe_land_speed * safe_land_speed) / (2.0 * brake)
		emergency = ground_distance(stop_dist * 1.3 + 2.0) < stop_dist * 1.15 + 1.0
	thrusting = live and (thrust_input or emergency)
	if thrusting:
		vert += u * thrust_accel * delta
		if on_ground:
			_climbing = false   # lift off: leave the floor this step
	if on_ground and not thrusting:
		vert = Vector3.ZERO
	else:
		vert -= u * gravity * delta
	velocity = flat + vert
	var want := flat
	move_and_slide()
	_climbing = _step_up(u, want, delta)
	_update_heat(delta)
	_check_landing(u)


## Heat from outside (weapons fire, flamers): pushes toward shutdown.
func add_heat(amount: float) -> void:
	heat = clampf(heat + amount, 0.0, heat_cap)
	if heat >= heat_cap and not shutdown:
		_overheat()


func _update_heat(delta: float) -> void:
	if thrusting:
		heat += thrust_heat * delta
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


## Distance down to the ground along local gravity (up to `max_dist`; max_dist when nothing is there).
func ground_distance(max_dist: float = 200.0) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return max_dist
	var u := up()
	var q := PhysicsRayQueryParameters3D.create(global_position + u * 0.2, global_position - u * max_dist)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return max_dist
	return maxf(((hit["position"] as Vector3) - global_position).dot(-u), 0.0)


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
