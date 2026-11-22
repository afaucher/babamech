extends TestCase
## Thruster flames (ThrusterFx) while thrusting, in the mech's own frame (+Y local up, -Z forward, +Z behind): both jets
## show (a LowPolyFlame.Stream each), each nozzle sits below and behind its hip AS POSED (the rig moves the body, and in the air it dips it toward
## the feet, so a standing-pose anchor floated the flames metres above the visible mech), and each jet points down,
## leans back, and is long enough to read from the chase camera. Off when the thrust stops.

func setup() -> void:
	var lab := ThrusterLab.new()
	add_child(lab)
	await frames(3)
	lab.bot_enabled = false
	var m := lab.mech
	var fx := m.get_node("Thrusters") as ThrusterFx
	lab.place(-20.0, 0.05)
	await frames(20)
	check(not fx.jet(-1.0).visible and not fx.jet(1.0).visible, "no flames standing still")
	m.thrust_input = true
	# Just lifted off, then well up in the air (the rig has the body dipped toward the feet by then).
	for phase: Array in [["lift-off", 8], ["airborne", 50]]:
		for i in int(phase[1]):
			await get_tree().process_frame
		_check_jets(m, fx, str(phase[0]))
	m.thrust_input = false
	for i in 40:
		await get_tree().process_frame
	check(not fx.jet(-1.0).visible and not fx.jet(1.0).visible, "flames go out when the thrust stops (level %.2f)" % fx.level)
	lab.queue_free()
	await frames(1)
	finish()


func _check_jets(m: MechController, fx: ThrusterFx, when: String) -> void:
	check(m.thrusting, "%s: thrusting" % when)
	check(fx.level > 0.9, "%s: flame level up (%.2f)" % [when, fx.level])
	var model := MechSpawn.rig_of(m).model
	var to_local := m.global_transform.affine_inverse()
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var j := fx.jet(side)
		var tag := "%s %s jet" % [when, "left" if side < 0.0 else "right"]
		check(j.visible, "%s shows" % tag)
		var hip := to_local * model.to_global(model.leg_points(i)["hip"])
		var noz := to_local * j.global_position
		var st := fx.stream(side)
		check(st.active(), "%s stream has tongues in flight" % tag)
		var tip := to_local * (j.global_transform * Vector3(0.0, -st.length, 0.0))
		var dir := (tip - noz).normalized()
		check(noz.y < hip.y, "%s: nozzle below the hip (nozzle %.2f, hip %.2f m)" % [tag, noz.y, hip.y])
		check(noz.y > hip.y - 1.5, "%s: nozzle at the hips, not lower (nozzle %.2f, hip %.2f m)" % [tag, noz.y, hip.y])
		check(noz.z > hip.z + 1.0, "%s: nozzle behind the body (z %.2f, hip z %.2f)" % [tag, noz.z, hip.z])
		check(noz.distance_to(hip) < 3.0, "%s: nozzle on the posed hips (%.2f m away)" % [tag, noz.distance_to(hip)])
		check(signf(noz.x) == side, "%s: on its own side (x %.2f)" % [tag, noz.x])
		check(dir.y < -0.8, "%s: points down (dir %s)" % [tag, dir])
		check(dir.z > 0.2, "%s: leans back (dir %s)" % [tag, dir])
		check(dir.x * side >= 0.0 and absf(dir.x) < 0.3, "%s: splays slightly outward, not across (dir %s)" % [tag, dir])
		check(noz.y - tip.y > 3.0, "%s: long enough to read (%.1f m)" % [tag, noz.y - tip.y])
		check(tip.z > noz.z, "%s: tip behind the nozzle" % tag)
