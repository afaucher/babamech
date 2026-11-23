extends TestCase
## Heat shutdown sag (MechRig.sag_*), under physics on the ring strip, stepped by physics frames (no wall clock): a
## standing mech forced into shutdown slumps: its body drops sag_depth (overshooting a little, never past SAG_PEAK) and
## pitches forward, the planted feet do not move, the hips stay on the pelvis, the legs stay in reach and no more folded
## than a step's fold, and the controller's body does not move (cosmetic only). On reboot it rises back to standing. A
## puppet (MechPuppet.apply from a snapshot whose `shutdown` flag is on, as a remote crew mech gets it) sags the same.

const FRAMES := 90   ## 1.5 s at 60 Hz: the slump / rise settles in about sag_time (0.65 s)


func setup() -> void:
	var lab := RingWalkLab.new()
	add_child(lab)
	await frames(2)
	lab.set_lab_option("mode", "stand")   # the bot zeroes the inputs; then it lets go
	await _physics(5)
	lab.bot_enabled = false
	lab.place_mech(0.0, 6.0)
	await _physics(60)
	var mech := lab.mech
	var rig := lab.rig
	var model := rig.model
	var body := model.find_child("Body", true, false) as Node3D
	var sc := rig.mech_scale
	var stand_y := body.position.y
	var stand_pitch := body.rotation.x
	var feet0 := rig.gait.positions()
	var at0 := mech.global_position
	var fold_min := 0.45 * (model.leg_lengths().x + model.leg_lengths().y)   # Model.max_foot_lift's fold

	# Owner path: the lab holds the controller in shutdown.
	lab.set_lab_option("shutdown", "on")
	var deep := 0.0
	var drift := 0.0
	var worst_hip := 0.0
	var reach := 1.0
	var fold := INF
	for i in FRAMES:
		await get_tree().physics_frame
		deep = maxf(deep, stand_y - body.position.y)
		var feet := rig.gait.positions()
		for k in 2:
			drift = maxf(drift, (feet[k] as Vector3).distance_to(feet0[k]))
		worst_hip = maxf(worst_hip, _hip_error(rig, body))
		reach = minf(reach, rig.reached_fraction)
		for k in 2:
			var lp := model.leg_points(k)
			fold = minf(fold, ((lp["ankle"] as Vector3) - (lp["hip"] as Vector3)).length())
	var drop := stand_y - body.position.y
	print("  slump: drop %.3f units (%.2f m), deepest %.3f (x%.2f), pitch %+.3f rad, feet drift %.3f m, hip error %.4f, fold %.2f (min %.2f)"
			% [drop, drop * sc, deep, deep / rig.sag_depth, body.rotation.x - stand_pitch, drift, worst_hip, fold, fold_min])
	check(mech.shutdown, "the controller is in shutdown")
	near(drop, rig.sag_depth, 0.02, "the body drops by sag_depth (%.3f units = %.2f m)" % [drop, drop * sc])
	check(deep > rig.sag_depth * 1.05, "it overshoots into the slump and settles back (deepest x%.2f)" % (deep / rig.sag_depth))
	check(deep <= rig.sag_depth * MechRig.SAG_PEAK, "never deeper than SAG_PEAK of sag_depth (test_torso_clearance's pose)")
	near(body.rotation.x - stand_pitch, -rig.sag_pitch, 0.02, "the body pitches forward by sag_pitch")
	check(drift < 0.05, "the planted feet stay put (drift %.3f m)" % drift)
	check(worst_hip < 0.001, "the hip pivots stay on the pelvis (worst %.4f)" % worst_hip)
	check(reach >= 1.0, "both legs reach their feet all through the slump")
	check(fold > fold_min, "the legs fold no deeper than a step's fold (hip-ankle %.2f > %.2f)" % [fold, fold_min])
	check(mech.global_position.distance_to(at0) < 0.01, "the controller's body did not move (cosmetic only)")
	var slumped_y := body.position.y

	# Reboot: rises back to standing (overshooting a little above it on the way).
	lab.set_lab_option("shutdown", "off")
	var high := -INF
	for i in FRAMES:
		await get_tree().physics_frame
		high = maxf(high, body.position.y - stand_y)
		worst_hip = maxf(worst_hip, _hip_error(rig, body))
	print("  rise: back to %+.4f of standing, overshoot %+.3f units" % [body.position.y - stand_y, high])
	check(not mech.shutdown, "rebooted")
	near(body.position.y, stand_y, 0.005, "the body is back at its standing height")
	near(body.rotation.x, stand_pitch, 0.005, "and upright again")
	check(high > 0.0 and high < rig.sag_depth * 0.5, "the rise overshoots a little above standing (%.3f units)" % high)
	check(worst_hip < 0.001, "hips on the pelvis through the rise")

	# Puppet path: the remote mech gets `shutdown` in its snapshot (NetMechCodec FLAG_SHUTDOWN) and MechPuppet writes it.
	var pup := MechPuppet.new()
	pup.bind(mech, 2)
	var st := NetMechState.new()
	st.pos = mech.global_position
	st.yaw = CrewSync.heading_of(mech.ring, mech.global_position, mech.forward())
	st.grounded = true
	st.shutdown = true
	st.heat = 1.0
	for i in FRAMES:
		pup.apply(st)
		await get_tree().physics_frame
	var p_drop := stand_y - body.position.y
	print("  puppet slump: drop %.3f units" % p_drop)
	near(p_drop, stand_y - slumped_y, 0.005, "the puppet sags the same as the owner's mech")
	st.shutdown = false
	st.heat = 0.2
	for i in FRAMES:
		pup.apply(st)
		await get_tree().physics_frame
	near(body.position.y, stand_y, 0.005, "and the puppet rises back on reboot")
	pup.free()
	lab.queue_free()
	await frames(1)
	finish()


func _physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## How far the hip pivots are from the pelvis' own points (test_ring_step's check).
func _hip_error(rig: MechRig, body: Node3D) -> float:
	var model := rig.model
	var worst := 0.0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var on_pelvis := body.transform * (MechModel.twist_basis(rig.leg_yaw) * Vector3(side * float(model.params["stance"]) * 0.5, -0.1, 0.0))
		worst = maxf(worst, on_pelvis.distance_to(model.leg_points(i)["hip"]))
	return worst
