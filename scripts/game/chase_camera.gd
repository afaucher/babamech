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
## Clearance fit (CameraClearance, see its header): the pivot moves right and/or up by what the local mech carries, so
## its own weapons stay off the crosshair (playtest: a right-shoulder missile pod covered it). The mounted meshes are
## measured when the loadout / chassis / model changes (a signature checked every `fit_check` s, never every frame), the
## fit runs on a worker thread and is cached per loadout, and the camera blends to the new offset at `fit_blend_rate`.
## The fit is a small grid over pitch and the body's yaw lag (yaw_error()); each frame only looks it up (bilinear).
## A loadout that clears at the default offsets gets exactly (0, 0): the view is unchanged. `fit_extra` is the offset
## applied this frame; `fit_clearance = false` turns it off.
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

var fit_clearance := true          ## fit the pivot to the mounted loadout (CameraClearance)
var fit_check := 0.5               ## s between loadout signature checks
var fit_blend_rate := 2.5          ## 1/s: blend from the old fit to a new one (smoothstep)
var clear_fit: Dictionary = {}     ## the current CameraClearance.fit() result ({} = the default offsets)
var fit_extra := Vector2.ZERO      ## pivot offset applied this frame: (extra shoulder m, extra height m)

var look_dir := Vector3.FORWARD    ## world direction of the camera's yaw, kept in the local floor plane
var _pos := Vector3.ZERO
var _cur_boom := 16.0              ## current smoothed boom length (snaps in immediately on wall/ceiling hit, eases out)
var _init_done := false
var _eye_local := Vector3.ZERO     ## the eye point in the cockpit's local frame (from the pilot's pupils, see _eye_frame)
var _eye_pilot_id := 0             ## instance id of the PilotHead _eye_local and the hidden layer were taken from
var _fit_prev: Dictionary = {}     ## the fit being blended away from
var _fit_t := 1.0                  ## 0..1 blend _fit_prev -> clear_fit
var _fit_sig := ""                 ## loadout signature the current fit was made for
var _fit_check_t := 0.0            ## s until the next signature check
var _fit_task := -1                ## WorkerThreadPool task running a fit, -1 = none
var _fit_job: Dictionary = {}      ## that task's input / output
var _fit_snap := true              ## the next fit to land snaps in (fresh target / respawn) instead of blending

## Fits per loadout (chassis, head, loadout, body / head scale, camera numbers): a respawn with the same loadout reuses it.
static var _fit_cache: Dictionary = {}

## Per-chassis framing over the defaults above (the Strider's: none listed = the vars' own values), applied when the
## target's chassis changes (apply_framing). The Bulwark is 9.3 m wide (the Strider 4.8) with its side guns 3.6 m out
## at deck height: on the Strider's boom the right gun sat under the crosshair and the clearance fit shifted the pivot
## 1.5-3.1 m right at rest (up to 4.4 m looking down). Its boom is higher, longer and as far out as its right edge (the
## Strider's crosshair sits at its right edge too): every loadout clears at rest with no shift, at most 3.1 m looking
## straight down (test_camera_clearance prints the shifts). Its collision probe starts in the hull (5 m: inside the
## 3.6 m capsule, above the belly).
const CHASSIS_FRAMING := {
	"bulwark": {"height": 11.0, "distance": 18.0, "shoulder": 4.5, "zoom_distance": 14.0, "zoom_shoulder": 4.9,
		"anchor_height": 5.0},
}
const FRAMING_KEYS := ["height", "distance", "shoulder", "zoom_distance", "zoom_shoulder", "anchor_height"]
var framed_chassis := ""             ## the chassis whose framing is applied ("" = none yet)
var _base_framing: Dictionary = {}   ## the FRAMING_KEYS values before any chassis framing (restored for the Strider)


## A camera config (CameraClearance.config_of's form) for a chassis: a default camera's numbers with its framing.
static func framing_config(chassis_id: String) -> Dictionary:
	var cam := ChaseCamera.new()
	cam.apply_framing(chassis_id)
	var cfg := CameraClearance.config_of(cam)
	cam.free()
	return cfg


## Use a chassis' framing (CHASSIS_FRAMING over the values the camera had before the first call).
func apply_framing(chassis_id: String) -> void:
	if _base_framing.is_empty():
		for k: String in FRAMING_KEYS:
			_base_framing[k] = get(k)
	var over: Dictionary = CHASSIS_FRAMING.get(chassis_id, {})
	for k: String in FRAMING_KEYS:
		set(k, over.get(k, _base_framing[k]))
	framed_chassis = chassis_id


func _ready() -> void:
	fov = base_fov
	far = 3000.0


func _exit_tree() -> void:
	if _fit_task >= 0:   # never leave a worker writing into a freed camera's job
		WorkerThreadPool.wait_for_task_completion(_fit_task)
		_fit_task = -1


## Snap behind the target, looking where it faces.
func reset_behind() -> void:
	if target == null:
		return
	look_dir = target.forward()
	zoomed = false
	zoom_amount = 0.0
	fov = base_fov
	_init_done = false
	_fit_check_t = 0.0   # re-check the loadout now (a respawn may bring a new mech)
	_fit_snap = true


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
	var fm := _model()
	if fm != null and fm.chassis_id != framed_chassis and (framed_chassis != "" or fm.chassis_id != "strider"):
		apply_framing(fm.chassis_id)   # a Strider from the start keeps the vars as set (labs / tests tune them)
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
		_fit_update(delta)
		global_transform = Transform3D(Basis.looking_at(view, up), eye_position())
		return
	fit_extra = _fit_offset(delta)
	var cur_shoulder := lerpf(shoulder, zoom_shoulder, zoom_amount) + fit_extra.x
	var cur_dist := lerpf(distance, zoom_distance, zoom_amount)
	# Two-stage collision from inside the mech's torso capsule so neither pivot nor camera can poke through the ceiling or walls.
	var anchor := target.global_position + up * anchor_height
	var pivot := target.global_position + up * (height + fit_extra.y) + right * cur_shoulder
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


# --- Clearance fit (CameraClearance) -----------------------------------------------------------------------------

## The pivot offset for this frame: the fit's grid at the current pitch and body yaw lag, blended from the previous fit.
func _fit_offset(delta: float) -> Vector2:
	_fit_update(delta)
	if not fit_clearance:
		return Vector2.ZERO
	var lag := rad_to_deg(yaw_error())
	var now := CameraClearance.extra_at(clear_fit, pitch, lag) if not clear_fit.is_empty() else Vector2.ZERO
	if _fit_t >= 1.0:
		return now
	var was := CameraClearance.extra_at(_fit_prev, pitch, lag) if not _fit_prev.is_empty() else Vector2.ZERO
	return was.lerp(now, smoothstep(0.0, 1.0, _fit_t))


## Advance the blend, collect a finished worker fit, and every `fit_check` s compare the loadout signature (a changed
## loadout / chassis / rebuilt model / removed weapon mesh starts a new fit: from the cache, else on a worker thread).
func _fit_update(delta: float) -> void:
	_fit_t = minf(_fit_t + delta * fit_blend_rate, 1.0)
	if _fit_task >= 0:
		if not WorkerThreadPool.is_task_completed(_fit_task):
			return
		WorkerThreadPool.wait_for_task_completion(_fit_task)
		_fit_task = -1
		var r: Dictionary = _fit_job.get("out", {})
		_fit_cache[_fit_job["key"]] = r
		if str(_fit_job["sig"]) == _fit_sig:
			_set_fit(r)
		_fit_job = {}
	_fit_check_t -= delta
	if _fit_check_t > 0.0 or not fit_clearance:
		return
	_fit_check_t = fit_check
	var m := _model()
	var sig := _loadout_sig(m)
	if sig == _fit_sig:
		return
	_fit_sig = sig
	if m == null:
		_set_fit({})
		return
	var cfg := CameraClearance.config_of(self)
	var key := "%s|%s|%s|%s|%s|%d" % [m.chassis_id, m.head_id, str(m.loadout), str([m.params.get("body"), m.params.get("head")]),
		str(cfg), _visible_meshes(m)]
	if _fit_cache.has(key):
		_set_fit(_fit_cache[key])
		return
	var job := {"sil": CameraClearance.capture(m, mech_frame()), "cfg": cfg, "key": key, "sig": sig, "out": {}}
	_fit_job = job
	_fit_task = WorkerThreadPool.add_task(func() -> void:
		(job["out"] as Dictionary).merge(CameraClearance.fit(job["sil"], job["cfg"])), false, "camera clearance fit")


## True while a fit is being computed on the worker thread.
func fit_pending() -> bool:
	return _fit_task >= 0


## Switch to a new fit: blend from what is applied now (or snap after a reset / for the first fit).
func _set_fit(r: Dictionary) -> void:
	if _fit_snap or not _init_done:
		_fit_prev = {}
		_fit_t = 1.0
	else:
		_fit_prev = clear_fit
		_fit_t = 0.0
	_fit_snap = false
	clear_fit = r


## The mech's body frame (origin at its feet, x = right, y = up, z = back): what CameraClearance measures in.
func mech_frame() -> Transform3D:
	if target == null:
		return Transform3D.IDENTITY
	var up := target.up()
	var fwd := target.forward()
	fwd = (fwd - up * fwd.dot(up)).normalized()
	return Transform3D(Basis(fwd.cross(up).normalized(), up, -fwd), target.global_position)


## What the fit depends on: the model (and its rebuilt body), chassis, head, loadout, scale and the visible meshes.
func _loadout_sig(m: MechModel) -> String:
	if m == null:
		return "none"
	var body := m.get_node_or_null("Body")
	return "%d|%d|%s|%s|%s|%s|%d" % [m.get_instance_id(), body.get_instance_id() if body != null else 0, m.chassis_id,
		m.head_id, str(m.loadout), str([m.params.get("body"), m.params.get("head")]), _visible_meshes(m)]


## Visible MeshInstance3Ds under `n` (a hidden branch counts none).
static func _visible_meshes(n: Node) -> int:
	if n is Node3D and not (n as Node3D).visible:
		return 0
	var c := 1 if n is MeshInstance3D else 0
	for k in n.get_children():
		c += _visible_meshes(k)
	return c
