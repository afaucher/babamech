extends TestCase
## The rig in the air (thruster lab): while hovering and while dropped from a height, the visible body stays with the
## controller (the hips within 1 m of where they ride when standing), the feet hang below the hips and above the
## ground, and on touchdown the feet re-plant on the floor without the body jumping. Guards the bug where the legs
## stayed planted on the ground and pulled the body down while the controller, camera and flames rose.


func setup() -> void:
	timeout_sec = 60.0
	var lab := ThrusterLab.new()
	add_child(lab)
	await frames(3)
	var m := lab.mech
	var ring := lab.ring
	var rig := MechSpawn.rig_of(m)
	var model := rig.model
	lab.set_lab_option("mode", "hover")
	var worst_body := 0.0
	var worst_foot_hip := -INF   # foot height above its hip (must stay below 0)
	var worst_foot_ground := INF  # foot height above the floor (must stay above 0)
	var air_frames := 0
	var top := 0.0
	for i in 240:
		await get_tree().physics_frame
		var h := ring.height(m.global_position)
		top = maxf(top, h)
		if h < 3.0:
			continue
		air_frames += 1
		var a := _air_check(m, model)
		worst_body = maxf(worst_body, a.x)
		worst_foot_hip = maxf(worst_foot_hip, a.y)
		worst_foot_ground = minf(worst_foot_ground, a.z)
	print("hover: top %.1f m, hip offset %.2f m, foot-hip %.2f m, foot above floor %.2f m" % [top, worst_body, worst_foot_hip, worst_foot_ground])
	check(top > 6.0, "hover lifts the mech (%.1f m)" % top)
	check(air_frames > 60, "it was high in the air for a while (%d frames)" % air_frames)
	check(worst_body < 1.0, "hovering: the body rides with the controller (worst hip offset %.2f m)" % worst_body)
	check(worst_foot_hip < -0.5, "hovering: the feet hang below the hips (highest %.2f m from the hip)" % worst_foot_hip)
	check(worst_foot_ground > 1.0, "hovering: the feet are off the ground (lowest %.2f m)" % worst_foot_ground)

	# Drop from 40 m (the emergency burn brakes it): in the air the same holds; after touchdown the feet are back on
	# the floor and the body dips but returns.
	lab.set_lab_option("mode", "drop test")
	lab.place(-25.0, float(lab.params["drop_height"]))   # the bot's own drop comes every 7 s
	worst_body = 0.0
	worst_foot_hip = -INF
	var fall_frames := 0
	var landed := -1
	var body_dip := 0.0
	var feet_after := INF
	for i in 400:
		await get_tree().physics_frame
		if i < 3:
			continue
		if landed < 0:
			if m.grounded():
				landed = i
			elif ring.height(m.global_position) > 2.0:
				var a := _air_check(m, model)
				fall_frames += 1
				worst_body = maxf(worst_body, a.x)
				worst_foot_hip = maxf(worst_foot_hip, a.y)
		elif i - landed < 40:
			body_dip = maxf(body_dip, _air_check(m, model).x)
		elif i - landed == 60:
			feet_after = 0.0
			for p: Vector3 in rig.gait.positions():
				feet_after = maxf(feet_after, absf(ring.height(p)))
			break
	print("drop: landed frame %d at %.1f m/s, hip offset %.2f m, foot-hip %.2f m, landing dip %.2f m, feet after %.3f m" % [landed, m.last_impact, worst_body, worst_foot_hip, body_dip, feet_after])
	check(fall_frames > 60, "the dropped mech fell for a while (%d frames)" % fall_frames)
	check(landed > 0, "the dropped mech lands (frame %d, %.1f m/s)" % [landed, m.last_impact])
	check(body_dip > 0.05, "landing: the body dips to absorb it (%.2f m)" % body_dip)
	check(worst_body < 1.0, "falling: the body rides with the controller (worst hip offset %.2f m)" % worst_body)
	check(worst_foot_hip < -0.5, "falling: the feet hang below the hips (highest %.2f m from the hip)" % worst_foot_hip)
	check(body_dip < 1.5, "landing: the body dips but stays with the controller (%.2f m)" % body_dip)
	check(feet_after < 0.1, "landing: both feet re-plant on the floor (worst %.2f m off)" % feet_after)
	lab.queue_free()
	await frames(1)
	finish()


## (how far the hips are from their standing height along up, highest foot above its hip, lowest foot above the
## floor) for the mech now, in metres.
func _air_check(m: MechController, model: MechModel) -> Vector3:
	var up := m.up()
	var body_err := 0.0
	var foot_hip := -INF
	var foot_ground := INF
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var pts := model.leg_points(i)
		var hip := model.to_global(pts["hip"])
		var rest := model.to_global(model.hip_local(side))
		body_err = maxf(body_err, absf((hip - rest).dot(up)))
		var foot := model.to_global(pts["foot"])
		foot_hip = maxf(foot_hip, (foot - hip).dot(up))
		foot_ground = minf(foot_ground, (m.ring.height(foot) if m.ring != null else foot.y))
	return Vector3(body_err, foot_hip, foot_ground)
