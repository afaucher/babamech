extends TestCase
## Hip twist (MechRig.leg_yaw): strafing turns the pelvis and legs toward the travel direction while the torso keeps
## the body facing, so a strafe is walked with full forward strides instead of a sideways shuffle. Measured on the
## ring strip under physics at walk 12 m/s x strafe 0.6 = 7.2 m/s sideways:
## - steps per second and mean step length against the old shuffle (at least 40% fewer steps, at least 2x longer);
## - the legs' yaw within 15 deg of the travel line once settled, the torso within 2 deg of the body facing;
## - planted feet never slide or turn, and in the legs' frame the feet never cross (test_gait_strafe_step rules);
## - walking backward uses a reversed gait (legs near the body facing), not a 180 deg twist;
## - standing still, the legs return to the body facing;
## - Gait.stepped reports each landed step, with strides told apart from corrections.
## Baseline (2026-11-22, measured by this test before the twist): 11.0 steps/s, mean step 1.32 m.

const BASE_STEPS_PER_S := 11.0
const BASE_STEP_LEN := 1.32

var lab: RingWalkLab
var events: Array = []


func setup() -> void:
	lab = RingWalkLab.new()
	add_child(lab)
	await frames(2)
	lab.set_lab_option("mode", "stand")
	lab.set_lab_param("strafe_scale", 0.6)
	await frames(10)
	lab.bot_enabled = false
	lab.rig.gait.stepped.connect(func(foot: int, info: Dictionary) -> void: events.append([foot, info]))
	var right := await _run("strafe right", Vector2(1, 0), 22.0, 4.0)
	var left := await _run("strafe left", Vector2(-1, 0), -22.0, 4.0)
	var sps := (right.x + left.x) * 0.5
	var mean := (right.y + left.y) * 0.5
	print("strafe 7.2 m/s: %.2f steps/s, mean step %.2f m (baseline %.2f steps/s, %.2f m)" % [sps, mean, BASE_STEPS_PER_S, BASE_STEP_LEN])
	check(sps <= BASE_STEPS_PER_S * 0.6, "strafing takes at least 40%% fewer steps (%.2f/s vs %.2f/s)" % [sps, BASE_STEPS_PER_S])
	check(mean >= BASE_STEP_LEN * 2.0, "strafing steps are at least twice as long (%.2f m vs %.2f m)" % [mean, BASE_STEP_LEN])
	check(absf(rad_to_deg(lab.rig.leg_yaw)) <= rad_to_deg(lab.rig.twist_max) + 0.01, "the twist stays within its limit")
	await _run("diagonal forward-right", Vector2(0.7, 0.7), 20.0, 3.0, false, -40.0)
	# Backward: a reversed gait. The legs' forward axis points away from the travel direction (straight back: the
	# body facing; back-right: turned left of it), never a 180 deg twist.
	await _run("backward", Vector2(0, -1), -8.0, 3.0, true, 70.0)
	check(absf(rad_to_deg(lab.rig.leg_yaw)) < 15.0, "walking backward the legs face forward (%.1f deg), not round" % rad_to_deg(lab.rig.leg_yaw))
	await _run("diagonal back-right", Vector2(0.7, -0.7), 20.0, 3.0, true, 70.0)
	# Standing still: the legs come back to the body facing.
	lab.mech.move_input = Vector2.ZERO
	for frame in 120:
		await get_tree().physics_frame
	check(absf(rad_to_deg(lab.rig.leg_yaw)) < 3.0, "standing, the legs return to the body facing (%.1f deg)" % rad_to_deg(lab.rig.leg_yaw))
	check(lab.rig.gait.stepping_count() == 0, "standing, the feet are planted")
	# Step events: one per landed step, strides and the rest told apart.
	var kinds := {}
	for e: Array in events:
		var info: Dictionary = e[1]
		kinds[info["kind"]] = int(kinds.get(info["kind"], 0)) + 1
		check(info.has("length") and info.has("weight") and info.has("pos"), "a step event carries length, weight and pos")
	print("step events by kind: %s" % kinds)
	check(int(kinds.get("stride", 0)) > 0, "walking steps are reported as strides")
	check(kinds.size() >= 2, "corrections / settles are told apart from strides (%s)" % kinds)
	lab.queue_free()
	await frames(1)
	finish()


## Drive `input` from arc x = `x0` (s = `s0`), settle for 1.2 s, then measure `secs`. `reversed`: the legs should
## walk backward (their forward axis against the travel direction). Returns (steps per second, mean step length m).
func _run(tag: String, input: Vector2, x0: float, secs: float, reversed: bool = false, s0: float = 4.0) -> Vector2:
	lab.mech.move_input = Vector2.ZERO
	lab.place_mech(x0, s0)
	for frame in 30:
		await get_tree().physics_frame
	var mech := lab.mech
	var rig := lab.rig
	var g := rig.gait
	var was := [false, false]
	var prev: Array = [g.feet[0]["pos"], g.feet[1]["pos"]]
	var prev_dir: Array = [g.feet[0].get("dir", Vector3.ZERO), g.feet[1].get("dir", Vector3.ZERO)]
	var steps := 0
	var strides := 0
	var total_len := 0.0
	var landed := 0
	var worst_slide := 0.0
	var worst_turn := 0.0
	var worst_yaw := 0.0
	var worst_torso := 0.0
	var min_gap := INF
	var settle := int(1.2 * 60.0)
	for frame in settle + int(secs * 60.0):
		mech.move_input = input
		await get_tree().physics_frame
		var up := mech.up()
		var measuring := frame >= settle
		for i in 2:
			var f: Dictionary = g.feet[i]
			var p: Vector3 = f["pos"]
			var d: Vector3 = f.get("dir", Vector3.ZERO)
			if not f["stepping"] and not was[i] and measuring:
				worst_slide = maxf(worst_slide, (p - (prev[i] as Vector3)).length())
				worst_turn = maxf(worst_turn, rad_to_deg(d.angle_to(prev_dir[i])) if d != Vector3.ZERO else 0.0)
			if measuring and f["stepping"] and not was[i]:
				steps += 1
			if measuring and was[i] and not f["stepping"]:
				var dl: Vector3 = p - (f["from"] as Vector3)
				total_len += (dl - up * dl.dot(up)).length()
				landed += 1
				if f["kind"] == "stride":
					strides += 1
			was[i] = f["stepping"]
			prev[i] = p
			prev_dir[i] = d
		if not measuring:
			continue
		# The legs against the travel line: the travel angle from the body facing (+ = right) vs the leg yaw.
		var v := mech.velocity - up * mech.velocity.dot(up)
		var lv := mech.global_basis.orthonormalized().inverse() * v
		var a := rad_to_deg(atan2(lv.x, -lv.z))
		var want := wrapf(a + 180.0, -180.0, 180.0) if reversed else a
		worst_yaw = maxf(worst_yaw, absf(wrapf(rad_to_deg(rig.leg_yaw) - want, -180.0, 180.0)))
		# The torso keeps the body facing: its forward (-Z) against the controller's forward, around up.
		var torso := rig.model.find_child("Torso", true, false) as Node3D
		var tf := -torso.global_basis.z
		tf = (tf - up * tf.dot(up)).normalized()
		worst_torso = maxf(worst_torso, absf(rad_to_deg(mech.forward().signed_angle_to(tf, up))))
		# In the legs' frame the left foot stays left of the right one by the clearance.
		var lr := rig.model.global_basis * (MechModel.twist_basis(rig.leg_yaw) * Vector3.RIGHT)
		lr = (lr - up * lr.dot(up)).normalized()
		var gap := ((g.feet[1]["pos"] as Vector3) - (g.feet[0]["pos"] as Vector3)).dot(lr)
		min_gap = minf(min_gap, gap)
	var sps := float(steps) / secs
	var mean := total_len / maxf(float(landed), 1.0)
	var arc_end := lab.ring.world_to_arc(mech.global_position)
	print("%s: moved x %.1f s %.1f m; %.2f steps/s (%d of %d landed steps strides), mean step %.2f m, leg yaw off %.1f deg (yaw now %.1f), torso off %.2f deg, slide %.4f m, planted turn %.2f deg, gap %.2f m" % [
		tag, arc_end.x - x0, arc_end.y - s0, sps, strides, landed, mean, worst_yaw, rad_to_deg(rig.leg_yaw), worst_torso,
		worst_slide, worst_turn, min_gap])
	check(worst_yaw <= 15.0, "%s: the legs turn to within 15 deg of the travel line (worst %.1f deg)" % [tag, worst_yaw])
	check(worst_torso <= 2.0, "%s: the torso keeps the body facing (worst %.2f deg)" % [tag, worst_torso])
	check(worst_slide < 0.01, "%s: planted feet never slide (worst %.4f m/frame)" % [tag, worst_slide])
	check(worst_turn < 0.1, "%s: planted feet never turn (worst %.2f deg/frame)" % [tag, worst_turn])
	check(min_gap >= g.foot_clearance - 0.1, "%s: the feet never cross (least gap %.2f m, clearance %.2f m)" % [tag, min_gap, g.foot_clearance])
	return Vector2(sps, mean)
