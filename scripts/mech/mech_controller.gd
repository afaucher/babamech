class_name MechController
extends CharacterBody3D
## The mech's body in the world: a kinematic character (no rigid bodies, so motion can be replayed) whose "up" follows
## the ring's gravity at its position (RingFrame). It turns, walks/runs and strafes from an input vector, falls along
## local gravity, and keeps its basis upright to the local floor every physics frame.
##
## Input comes from whoever drives it (player, lab bot, later the network for puppets): set `move_input`, `turn_input`
## and `running`. Thrusters, heat and damage come in later milestones (docs/design/vertical-slice.md S2+).
##
## Networking: the owner's machine runs this; position, velocity and facing (engine properties) will be streamed by the
## mech codec in S7. Remote copies will be interpolated puppets, not simulated.

var ring: RingFrame                  ## the deck this mech stands on; null = flat world (+Y up)
var walk_speed := 6.0                ## m/s
var run_speed := 13.0                ## m/s
var accel := 18.0                    ## m/s^2 toward the wanted velocity
var turn_rate := 1.8                 ## rad/s at full turn input
var gravity := 22.0                  ## m/s^2 along local down (mechs fall heavy)

var move_input := Vector2.ZERO       ## x = strafe right, y = forward; length <= 1
var turn_input := 0.0                ## -1 left .. +1 right
var running := false


func net_fields() -> Dictionary:
	return {
		"ring": Net.SPAWN, "walk_speed": Net.SPAWN, "run_speed": Net.SPAWN, "accel": Net.SPAWN,
		"turn_rate": Net.SPAWN, "gravity": Net.SPAWN,
		"move_input": Net.PRIVATE, "turn_input": Net.PRIVATE, "running": Net.PRIVATE,
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


func _physics_process(delta: float) -> void:
	step(delta)


## One physics step (public so tests can drive it).
func step(delta: float) -> void:
	var u := up()
	up_direction = u
	# Keep the body upright to the local floor, keeping its heading, then turn about local up.
	var f := forward() - u * forward().dot(u)
	if f.length_squared() < 1e-8:
		f = (ring.basis_at(global_position) if ring != null else Basis.IDENTITY) * Vector3.FORWARD
	f = f.normalized().rotated(u, -turn_input * turn_rate * delta)
	global_basis = Basis(f.cross(u), u, -f)
	# Wanted velocity along the floor.
	var wish := f * move_input.y + f.cross(u) * move_input.x
	if wish.length() > 1.0:
		wish = wish.normalized()
	var top := run_speed if running else walk_speed
	var vert := u * velocity.dot(u)
	var flat := velocity - vert
	flat = flat.move_toward(wish * top, accel * delta)
	if is_on_floor():
		vert = Vector3.ZERO
	else:
		vert -= u * gravity * delta
	velocity = flat + vert
	move_and_slide()
