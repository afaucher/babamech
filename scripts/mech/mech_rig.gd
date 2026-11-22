class_name MechRig
extends Node3D
## The mech's walking presentation: a child of a MechController that poses the MechModel every physics frame from the
## controller's motion. Feet are planted by Gait, legs are solved by LegIK, and the body bobs, dips toward a lower foot
## and leans into speed. The model is scaled by `mech_scale` (about 8 m tall at 2.0).
##
## Presentation only (Net LOCAL): every machine runs it from the mech's synced motion (own mech or puppet alike).

var mech_scale := 2.0
var bob := 0.12              ## body dip between steps (model units) at full speed
var lean := 0.12             ## forward lean (rad) at run speed
var sway := 0.04             ## sideways roll (rad) toward the planted foot while walking
var probe_up := 5.0          ## ground ray starts this far above a hip's ground point (m)
var probe_down := 12.0       ## and reaches this far below

var model: MechModel
var gait := Gait.new()
var reached_fraction := 1.0  ## legs whose IK target was in reach last frame (diagnostics, tests)

var _body: MechController
var _air_time := 0.0


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
	update_pose(delta)


func update_pose(delta: float) -> void:
	if _body == null or model == null:
		return
	var up := _body.up()
	var vel := _body.velocity
	_air_time = 0.0 if _body.is_on_floor() else _air_time + delta
	var homes: Array = []
	for side: float in [-1.0, 1.0]:
		homes.append(ground_under(model.to_global(model.hip_local(side)), up))
	gait.run_speed = _body.run_speed
	gait.update(delta, homes, up, vel, ground_under, _air_time > 0.15)
	var flat := vel - up * vel.dot(up)
	var k := clampf(flat.length() / maxf(_body.run_speed, 0.1), 0.0, 1.0)
	var feet_l: Array = []
	for p: Vector3 in gait.positions():
		feet_l.append(model.to_local(p))
	# Body: dip toward the lower foot (stepping down a curb), bob between steps, lean into speed, roll over the
	# planted foot.
	var low := minf(0.0, minf((feet_l[0] as Vector3).y, (feet_l[1] as Vector3).y))
	var offset := Vector3(0.0, low * 0.7 - bob * k * (1.0 - gait.lift_amount()), 0.0)
	var planted_side := 0.0
	if gait.feet.size() == 2:
		planted_side = (-1.0 if not gait.feet[0]["stepping"] else 0.0) + (1.0 if not gait.feet[1]["stepping"] else 0.0)
	var rot := Vector3(-lean * k, 0.0, -sway * planted_side * minf(k * 3.0, 1.0))
	var lengths := model.leg_lengths()
	var legs: Array = []
	var reached := 0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip := model.hip_local(side) + offset
		var r := LegIK.solve_leg(hip, feet_l[i], lengths.x, lengths.y, lengths.z, Vector3.UP, Vector3.FORWARD,
				model.tarsus_lean())
		if r["reached"]:
			reached += 1
		legs.append({"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"]})
	reached_fraction = float(reached) / 2.0
	model.set_external_pose(legs, offset, rot)


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
