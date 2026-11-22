extends TestCase
## Under physics on the ring strip: the hip pivots stay on the pelvis while the body leans and sways, the body climbs
## a curb below the max step-up and is stopped by a block above it, and strafing keeps the feet apart and in reach.


func setup() -> void:
	var lab := RingWalkLab.new()
	add_child(lab)
	await frames(2)
	var mech := lab.mech
	var ring := lab.ring
	var rig := lab.rig
	lab.set_lab_option("mode", "stand")
	await frames(20)
	lab.bot_enabled = false
	var step := rig.max_step()
	check(step > 0.9 and step < 1.6, "max step-up from the leg geometry: %.2f m (foot lift %.2f m)" % [step, rig.max_foot_lift()])
	near(mech.max_step_up, step, 0.001, "the body climbs what the legs can step onto")

	# Which way is forward along the arc?
	lab.place_mech(-20.0, 0.0)
	await frames(10)
	var s0 := ring.world_to_arc(mech.global_position).y
	for frame in 30:
		mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
	var dir := signf(ring.world_to_arc(mech.global_position).y - s0)
	check(dir != 0.0, "it walks along the arc")

	# Hips on the pelvis: run (the body leans and sways), compare each hip pivot with the pelvis' own point.
	var model := rig.model
	var body := model.find_child("Body", true, false) as Node3D
	var worst_hip := 0.0
	var leaned := 0.0
	mech.running = true
	for frame in 90:
		mech.move_input = Vector2(0.3, 1)
		mech.turn_input = 0.3
		await get_tree().physics_frame
		leaned = maxf(leaned, absf(body.rotation.x) + absf(body.rotation.z))
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			# (turned by the hip twist: the pelvis yaws under the body with the legs, MechRig.leg_yaw)
			var on_pelvis := body.transform * (MechModel.twist_basis(rig.leg_yaw) * Vector3(side * float(model.params["stance"]) * 0.5, -0.1, 0.0))
			worst_hip = maxf(worst_hip, on_pelvis.distance_to(model.leg_points(i)["hip"]))
			var socket := model.find_child("socket_%s" % ("l" if i == 0 else "r"), true, false) as Node3D
			worst_hip = maxf(worst_hip, (body.transform * socket.position).distance_to(model.leg_points(i)["hip"]))
	check(leaned > 0.05, "the body leaned while running (%.2f rad)" % leaned)
	check(worst_hip < 0.001, "the hip pivots stay on the pelvis under lean and sway (worst %.4f)" % worst_hip)
	mech.running = false
	mech.turn_input = 0.0

	# Climb the 0.9 m curb (x 6, s 19..25) from 9 m before it.
	lab.place_mech(10.0, 22.0 - dir * 12.0)
	await frames(15)
	var top := 0.0
	var reach := 1.0
	for frame in 300:
		mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
		var a := ring.world_to_arc(mech.global_position)
		if absf(a.y - 22.0) < 1.5:
			top = maxf(top, a.z)
		reach = minf(reach, rig.reached_fraction)
	check(top > 0.8, "it steps up onto the 0.9 m curb (height on top %.2f m)" % top)
	check(reach >= 0.5, "with a leg in reach all the way")

	# The 1.6 m block (x -22, s 26..34) is above the max step: it stops the mech.
	lab.place_mech(-22.0, 30.0 - dir * 12.0)
	await frames(15)
	var high := 0.0
	var feet_high := 0.0
	for frame in 300:
		mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
		high = maxf(high, ring.world_to_arc(mech.global_position).z)
		for p: Vector3 in rig.gait.positions():
			feet_high = maxf(feet_high, ring.height(p))
	var at := ring.world_to_arc(mech.global_position)
	check(high < 0.4, "it does not climb the 1.6 m block (highest %.2f m)" % high)
	check((30.0 - at.y) * dir > 4.0, "the block stops it (%.1f m short of its centre)" % ((30.0 - at.y) * dir))
	check(feet_high < step + 0.3, "no foot lands on top of it (highest foot %.2f m)" % feet_high)

	# Strafe on open floor: the feet keep their gap, on their own sides (of the legs' frame: the hip twist turns the
	# legs toward the travel direction), and in reach. Start near the left edge: at
	# walk then run strafe speed the mech covers about 30 m to the right before it turns back.
	lab.place_mech(-15.0, 6.0)
	await frames(20)
	var min_gap := INF
	var min_side := INF
	reach = 1.0
	for frame in 360:
		mech.move_input = Vector2(1.0 if frame < 180 else -1.0, 0)
		mech.running = frame % 180 > 90
		await get_tree().physics_frame
		var right := (mech.global_basis * (MechModel.twist_basis(rig.leg_yaw) * Vector3.RIGHT)).normalized()   # the legs' right
		var feet := rig.gait.positions()
		var l := ((feet[0] as Vector3) - mech.global_position).dot(right)
		var r := ((feet[1] as Vector3) - mech.global_position).dot(right)
		min_gap = minf(min_gap, r - l)
		min_side = minf(min_side, minf(-l, r))
		reach = minf(reach, rig.reached_fraction)
	check(min_gap >= rig.gait.foot_clearance - 0.1, "strafing feet keep their gap (least %.2f m, clearance %.2f)" % [min_gap, rig.gait.foot_clearance])
	check(min_side > 0.2, "and stay on their own side of the body (closest %.2f m)" % min_side)
	check(reach >= 0.5, "with a leg in reach")
	lab.queue_free()
	await frames(1)
	finish()
