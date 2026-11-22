class_name ChaseCamera
extends Camera3D
## Over-the-shoulder camera for a mech on the ring deck. The mouse moves the camera's own yaw and pitch (the look
## direction); the mech turns toward that yaw at its own turn rate, so the view is free but the body is heavy. "Up" is the
## ring's radial up at the mech, and the look direction is carried along the curve every frame. A ray from the pivot keeps
## the camera out of walls.
##
## First person (toggle_first_person(), the C key in the test drive): the same camera moves to the pilot's eyes in the
## head that sticks out of the hatch, rigidly following the body (gait bob, landing dip) with the same look_dir / pitch,
## so aim_point(), the HUD and the weapons keep using it unchanged. The local pilot's head is put on render layer
## FP_HIDDEN_LAYER and this camera's cull mask drops that layer while in first person: only this view loses it (other
## cameras and lights keep it; a remote crew view sees the head as usual). Weapons, legs and the hull stay visible.
##
## Presentation + local input only (Net LOCAL / PRIVATE): never streamed; the mech's facing is what gets synced.

var target: MechController
var sensitivity := 0.0025          ## radians per mouse pixel
var pitch := -0.18                 ## radians, negative looks down
var pitch_min := -1.0
var pitch_max := 0.55
var distance := 16.0               ## metres behind the pivot
var height := 9.5                  ## pivot height above the mech's feet
var shoulder := 3.2                ## pivot offset to the right
var base_fov := 70.0               ## default wide FOV (deg)
var zoom_fov := 32.0               ## RMB zoomed FOV (deg)
var zoom_distance := 12.5          ## metres behind the pivot while zoomed
var zoom_shoulder := 3.6           ## slight right offset while zoomed for a clear sightline past the head
var zoom_sensitivity := 0.45       ## mouse sensitivity scale at full zoom
var zoom_rate := 12.0              ## zoom blend speed (1/s)
var zoomed := false                ## true while holding RMB zoom
var zoom_amount := 0.0             ## 0..1 current smooth zoom blend
var collide_margin := 0.75
var anchor_height := 4.0           ## m above mech feet (strictly inside torso capsule) where camera collision probes start
var smooth := 14.0                 ## position follow rate (1/s); 0 = rigid

var first_person := false         ## true: the view is from the pilot's eyes (toggle_first_person)
var fp_fov := 78.0                 ## first-person FOV (deg)
var fp_zoom_fov := 30.0            ## first-person RMB zoomed FOV (deg)
var fp_pitch_min := -1.3           ## first person can look further down (at the legs) and up
var fp_pitch_max := 1.1
var fp_forward := 0.1              ## m the eye point sits forward of the pupils (clear of the hidden face)

## The render layer (1-based) of the local pilot's head; the first-person cull mask leaves it out.
const FP_HIDDEN_LAYER := 20

var look_dir := Vector3.FORWARD    ## world direction of the camera's yaw, kept in the local floor plane
var _pos := Vector3.ZERO
var _cur_boom := 16.0              ## current smoothed boom length (snaps in immediately on wall/ceiling hit, eases out)
var _init_done := false
var _eye_local := Vector3.ZERO     ## the eye point in the cockpit's local frame (from the pilot's pupils, see _eye_frame)
var _eye_pilot_id := 0             ## instance id of the PilotHead _eye_local and the hidden layer were taken from


func _ready() -> void:
	fov = base_fov
	far = 3000.0


## Snap behind the target, looking where it faces.
func reset_behind() -> void:
	if target == null:
		return
	look_dir = target.forward()
	zoomed = false
	zoom_amount = 0.0
	fov = base_fov
	_init_done = false


func add_mouse(rel: Vector2) -> void:
	if target == null:
		return
	var sens := sensitivity * lerpf(1.0, zoom_sensitivity, zoom_amount)
	look_dir = look_dir.rotated(target.up(), -rel.x * sens)
	pitch = clampf(pitch - rel.y * sens, fp_pitch_min if first_person else pitch_min,
		fp_pitch_max if first_person else pitch_max)


## Switch between the chase view and the pilot's eyes. Keeps the look direction; the chase pitch range is restored on
## the way out. Purely local (nothing synced).
func set_first_person(on: bool) -> void:
	first_person = on
	_eye_pilot_id = 0   # re-find the eyes and re-tag the head
	cull_mask = _cull_for_mode()
	if not on:
		pitch = clampf(pitch, pitch_min, pitch_max)
		_init_done = false   # snap the boom back behind instead of sliding out of the head
	fov = lerpf(fp_fov if on else base_fov, fp_zoom_fov if on else zoom_fov, zoom_amount)


func toggle_first_person() -> void:
	set_first_person(not first_person)


func _cull_for_mode() -> int:
	var all := 0xFFFFF   # the 20 render layers
	return all & ~(1 << (FP_HIDDEN_LAYER - 1)) if first_person else all


## The target's model (MechSpawn mechs: Rig/Model), or null.
func _model() -> MechModel:
	if target == null:
		return null
	var rig := target.get_node_or_null("Rig") as MechRig
	return rig.model if rig != null else null


## The cockpit node (follows the body: gait bob, lean, landing dip), or null.
func _cockpit() -> Node3D:
	var m := _model()
	return m.find_child("Cockpit", true, false) as Node3D if m != null else null


## The pilot's eye point in world space (first person sits here); the mech's head height as a fallback.
func eye_position() -> Vector3:
	var seat := _cockpit()
	if seat == null:
		return target.global_position + target.up() * height if target != null else global_position
	_eye_frame(seat)
	return seat.global_transform * _eye_local


## When the pilot head is new (first use, or the model rebuilt it): take the eye point from its pupils (in the cockpit's
## frame, so later idle glances and neck sway do not shake the view) and put the head on FP_HIDDEN_LAYER.
func _eye_frame(seat: Node3D) -> void:
	var m := _model()
	var pilot: PilotHead = m.pilot if m != null else null
	var pid := pilot.get_instance_id() if pilot != null else -1
	if pid == _eye_pilot_id:
		return
	_eye_pilot_id = pid
	var holder := pilot.get_parent() as Node3D if pilot != null else null
	if holder == null:   # the placeholder art: its head is the cockpit's child
		_eye_local = Vector3(0, 0.6, -0.3)
		hide_from_first_person(seat)
		return
	var l := pilot.piece("PupilL")
	var r := pilot.piece("PupilR")
	var eye_world := (l.global_position + r.global_position) * 0.5 if l != null and r != null 		else holder.global_transform * Vector3(0, 0.8, -0.3)
	var fwd := -seat.global_basis.z.normalized()
	_eye_local = seat.global_transform.affine_inverse() * (eye_world + fwd * fp_forward)
	hide_from_first_person(holder)


## Put every mesh under `node` on FP_HIDDEN_LAYER only (seen by every camera except a first-person one).
static func hide_from_first_person(node: Node) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = 1 << (FP_HIDDEN_LAYER - 1)
	for c in node.get_children():
		hide_from_first_person(c)


## Signed angle (rad) from the mech's facing to the camera's yaw, about local up: + means the camera looks right.
func yaw_error() -> float:
	if target == null:
		return 0.0
	return -target.forward().signed_angle_to(look_dir, target.up())


## Where the crosshair points: the first thing hit along the view ray (or a far point).
func aim_point(max_dist: float = 800.0) -> Vector3:
	var from := global_position
	var to := from - global_basis.z * max_dist
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		if target != null:
			q.exclude = [target.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]
	return to


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var want_z := 1.0 if zoomed else 0.0
	zoom_amount = lerpf(zoom_amount, want_z, clampf(delta * zoom_rate, 0.0, 1.0)) if zoom_rate > 0.0 else want_z
	fov = lerpf(fp_fov if first_person else base_fov, fp_zoom_fov if first_person else zoom_fov, zoom_amount)
	var up := target.up()
	# Carry the look direction along the curve: keep it in the local floor plane.
	look_dir = look_dir - up * look_dir.dot(up)
	if look_dir.length_squared() < 1e-6:
		look_dir = target.forward()
	look_dir = look_dir.normalized()
	var right := look_dir.cross(up).normalized()
	var view := (look_dir * cos(pitch) + up * sin(pitch)).normalized()
	if first_person:   # rigid on the pilot's eyes: the body's bob and lean carry the view
		global_transform = Transform3D(Basis.looking_at(view, up), eye_position())
		return
	var cur_shoulder := lerpf(shoulder, zoom_shoulder, zoom_amount)
	var cur_dist := lerpf(distance, zoom_distance, zoom_amount)
	# Two-stage collision from inside the mech's torso capsule so neither pivot nor camera can poke through the ceiling or walls.
	var anchor := target.global_position + up * anchor_height
	var pivot := target.global_position + up * height + right * cur_shoulder
	var space := get_world_3d().direct_space_state
	var boom_hit := false
	if space != null:
		# Stage 1: anchor -> pivot (keeps shoulder/head offset strictly under the ceiling and out of side walls).
		var q1 := PhysicsRayQueryParameters3D.create(anchor, pivot)
		q1.exclude = [target.get_rid()]
		var h1 := space.intersect_ray(q1)
		if not h1.is_empty():
			boom_hit = true
			var d1 := (pivot - anchor).normalized()
			var n1 := (h1["normal"] as Vector3).normalized()
			pivot = (h1["position"] as Vector3) - d1 * collide_margin + n1 * 0.25
		# Stage 2: clamped pivot -> desired boom position.
		var raw_want := pivot - view * cur_dist
		var q2 := PhysicsRayQueryParameters3D.create(pivot, raw_want)
		q2.exclude = [target.get_rid()]
		var h2 := space.intersect_ray(q2)
		if not h2.is_empty():
			boom_hit = true
			var n2 := (h2["normal"] as Vector3).normalized()
			var hit_d := pivot.distance_to((h2["position"] as Vector3) + view * collide_margin + n2 * 0.25)
			cur_dist = clampf(hit_d, 0.5, cur_dist)
	# Snap inward immediately on collision (never lag outside a ceiling/wall); smooth outward recovery.
	if not _init_done or smooth <= 0.0 or boom_hit or cur_dist < _cur_boom:
		_cur_boom = cur_dist
	else:
		_cur_boom = lerpf(_cur_boom, cur_dist, clampf(delta * smooth, 0.0, 1.0))
	var want := pivot - view * _cur_boom
	if not _init_done or smooth <= 0.0 or boom_hit:
		_pos = want
		_init_done = true
	else:
		_pos = _pos.lerp(want, clampf(delta * smooth, 0.0, 1.0))
	global_transform = Transform3D(Basis.looking_at(view, up), _pos)
