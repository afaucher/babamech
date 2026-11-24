extends "res://tests/test_torso_clearance_bulwark.gd"
## The Bulwark's REAL rig in play (MechRig + Gait + LegIK on a MechSpawn mech, its ChassisParts "rig" numbers), on a flat
## floor at the runner's fixed 60 Hz step: idle, walk, run, a slow walk (half input), a diagonal, strafe right / left (a side-step: no hip twist), walk
## backward, turn in place, walk while turning, a thrust hop, a drop (the landing dip), the heat-shutdown slump and the
## reboot rise. Every frame:
##   - no foot sliding: a planted foot's drawn position (the IK's foot) stays on its plant (within SLIDE_TOL: the IK
##     reached it) and does not move while planted (SLIDE_SPEED);
##   - the hip twist stays 0 (twist_max 0: the hips hang under pods fixed to the hull);
## every SAMPLE-th frame: the legs clear the hull, pods, pelvis, knee pads and hip cups (test_torso_clearance_bulwark's
## _check on the live model); per scenario: footsteps (Gait.stepped, the audio's feed) fire while moving; strafing, the
## feet step sideways and never cross (the left foot stays left of the right one).
## Prints per-scenario numbers: steps, worst slide, worst reach error, stride, step time.

const SLIDE_TOL := 0.05       ## m: a planted foot's drawn position off its plant (an IK target out of reach)
const SLIDE_SPEED := 0.3      ## m/s: a planted foot's drawn position moving
const SAMPLE := 7             ## frames between hull clearance checks

var mech: MechController
var rig: MechRig
var _steps: Array = []


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	verbose = false
	_barrel = HC.tris(BulwarkMeshes.hull_shell(), Transform3D.IDENTITY)
	_pads = HC.tris(BulwarkMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	_pelvis = HC.tris(BulwarkMeshes.build("bulwark_pelvis"), Transform3D.IDENTITY)
	_barrel_box = HC._bounds(_barrel).grow(SKIN_MARGIN + 0.01)
	_pads_box = HC._bounds(_pads).grow(SKIN_MARGIN + 0.01)
	_pelvis_box = HC._bounds(_pelvis).grow(SKIN_MARGIN + 0.01)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 1, 600)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)
	mech = MechSpawn.make("chicken", "bulwark", {}, 1)
	add_child(mech)
	await frames(3)
	rig = MechSpawn.rig_of(mech)
	eq(rig.model.chassis_id, "bulwark", "a Bulwark")
	near(rig.twist_max, 0.0, 1e-6, "no hip twist")
	near(rig.gait.step_length, float(ChassisParts.BULWARK_RIG["gait.step_length"]), 1e-6, "the Bulwark's gait numbers")
	rig.gait.stepped.connect(func(foot: int, info: Dictionary) -> void: _steps.append([foot, info]))
	print("  hip %.2f m, max foot lift %.2f m, max step %.2f m, step-up %.2f m" % [rig.model.hip_height() * rig.mech_scale,
		rig.max_foot_lift(), rig.max_step(), mech.max_step_up])

	await _run("idle", 60, Vector2.ZERO, 0.0, false)
	await _run("walk", 200, Vector2(0, 1), 0.0, false, true)
	await _run("run", 200, Vector2(0, 1), 0.0, true, true)
	await _stand()
	await _run("slow walk", 200, Vector2(0, 0.5), 0.0, false, true)
	await _stand()
	await _run("diagonal", 160, Vector2(0.7, 0.7), 0.0, false, true)
	await _stand()
	await _run("strafe right", 160, Vector2(1, 0), 0.0, false, true, 1.0)
	await _stand()
	await _run("strafe left", 160, Vector2(-1, 0), 0.0, false, true, -1.0)
	await _stand()
	await _run("strafe run", 160, Vector2(1, 0), 0.0, true, true, 1.0)
	await _stand()
	await _run("backward", 150, Vector2(0, -1), 0.0, false, true)
	await _stand()
	await _run("turn in place", 180, Vector2.ZERO, 1.0, false, true)
	await _stand()
	await _run("walk + turn", 180, Vector2(0, 1), -1.0, false, true)
	await _stand()
	# A hop: thrust 1 s, then down onto the floor (the air pose, the touchdown).
	await _run("hop", 150, Vector2(0, 0.5), 0.0, false, false, 0.0, func(f: int) -> void: mech.thrust_input = f < 60)
	await _stand()
	# A drop: from 9 m (a ~14 m/s landing: the dip).
	mech.global_position += Vector3(0, 9.0, 0)
	await _run("drop", 120, Vector2.ZERO, 0.0, false, false)
	check(mech.last_impact > 10.0, "the drop lands hard (%.1f m/s): a landing dip" % mech.last_impact)
	# The heat shutdown slump, then the reboot rise.
	mech.add_heat(mech.heat_cap)
	await _run("slump", 150, Vector2.ZERO, 0.0, false, false, 0.0, func(_f: int) -> void: mech.heat = mech.heat_cap)
	check(rig.sag > 0.8, "slumped (sag %.2f)" % rig.sag)
	mech.heat = 0.0
	await _run("reboot", 150, Vector2.ZERO, 0.0, false, false)
	check(not mech.shutdown and absf(rig.sag) < 0.1, "rebooted and standing (sag %.2f)" % rig.sag)
	print("  worst: %s" % str(_worst))
	finish()


func _stand() -> void:
	await _run("", 60, Vector2.ZERO, 0.0, false, false)


## Drive `frames_n` physics frames with the inputs; check sliding and twist every frame and the hull clearance every
## SAMPLE-th. `moving`: footsteps must fire. `side` (+1 right, -1 left): a strafe: the feet must step sideways.
func _run(tag: String, frames_n: int, mv: Vector2, turn: float, run: bool, moving: bool = false, side: float = 0.0,
		each: Callable = Callable()) -> void:
	mech.move_input = mv
	mech.turn_input = turn
	mech.running = run
	mech.thrust_input = false
	_steps.clear()
	var worst_slide := 0.0
	var worst_speed := 0.0
	var worst_reach := 0.0
	var crossed := 0.0
	var last := [Vector3.INF, Vector3.INF]
	var prev_plant := [Vector3.INF, Vector3.INF]
	var min_reached := 1.0
	for f in frames_n:
		if each.is_valid():
			each.call(f)
		if mech.heat < mech.heat_cap * 0.9 and not mech.shutdown:
			mech.heat = 0.0   # keep it from overheating (the slump scenario forces it)
		await get_tree().physics_frame
		if tag == "":
			continue
		var air := not mech.grounded()
		min_reached = minf(min_reached, rig.reached_fraction)
		for i in 2:
			var foot: Dictionary = rig.gait.feet[i]
			var drawn := rig.model.to_global(rig.model.leg_points(i).get("foot", Vector3.ZERO))
			var plant: Vector3 = foot["pos"]
			if foot["stepping"] or air or rig._airborne or rig._land_t < rig.absorb_time * 2.0:
				last[i] = Vector3.INF
				continue
			var off := Vector2(drawn.x - plant.x, drawn.z - plant.z).length()
			worst_reach = maxf(worst_reach, off)
			if plant.is_equal_approx(prev_plant[i]) and last[i] != Vector3.INF:
				worst_speed = maxf(worst_speed, (drawn - (last[i] as Vector3)).length() * 60.0)
			last[i] = drawn
			prev_plant[i] = plant
			worst_slide = maxf(worst_slide, off)
			if off > 0.3 and OS.has_environment("BABAMECH_RIG_DEBUG"):
				var hl := mech.global_basis.inverse() * (plant - mech.global_position)
				print("    %s f%d foot %d off %.2f plant(body) %s other stepping %s t %.2f speed %.2f" % [tag, f, i, off, str(hl),
					rig.gait.feet[1 - i]["stepping"], float(rig.gait.feet[1 - i]["t"]), mech.ground_speed()])
		if side != 0.0:   # the feet never cross: left foot left of the right one, along the body's right
			var r := mech.global_basis.x
			var gap := ((rig.gait.feet[1]["pos"] as Vector3) - (rig.gait.feet[0]["pos"] as Vector3)).dot(r)
			crossed = minf(crossed, gap) if crossed != 0.0 else gap
		check(absf(rig.leg_yaw) < 1e-4, "%s: no hip twist (%.4f)" % [tag, rig.leg_yaw])
		if f % SAMPLE == SAMPLE - 1:
			_check(rig.model, "%s f%d" % [tag, f], true)
			if OS.has_environment("BABAMECH_RIG_DEBUG"):
				var fl := []
				for i in 2:
					var lp: Dictionary = rig.model.leg_points(i)
					fl.append("foot %s knee %s stepping %s" % [str((lp["foot"] - lp["hip"]).snapped(Vector3.ONE * 0.01)), str((lp["knee"] - lp["hip"]).snapped(Vector3.ONE * 0.01)), rig.gait.feet[i]["stepping"]])
				print("    %s f%d %s" % [tag, f, str(fl)])
	if tag == "":
		return
	var strides := 0
	var mean_len := 0.0
	var side_steps := 0
	for s: Array in _steps:
		var info: Dictionary = s[1]
		if str(info["kind"]) == "stride":
			strides += 1
			mean_len += float(info["length"])
	if strides > 0:
		mean_len /= float(strides)
	print("  [rig] %-14s steps %3d (strides %d, mean %.2f m)  slide %.3f m  planted speed %.3f m/s  reached min %.2f  feet gap min %.2f" % [
		tag, _steps.size(), strides, mean_len, worst_slide, worst_speed, min_reached, crossed])
	check(worst_slide <= SLIDE_TOL, "%s: planted feet stay on their plants (worst %.3f m)" % [tag, worst_slide])
	check(worst_speed <= SLIDE_SPEED, "%s: planted feet do not slide (worst %.3f m/s)" % [tag, worst_speed])
	if moving:
		check(_steps.size() >= 2, "%s: footsteps fire (Gait.stepped: %d)" % [tag, _steps.size()])
	if side != 0.0:
		check(crossed > rig.gait.foot_clearance * 0.5, "%s: the feet never cross (least gap %.2f m)" % [tag, crossed])
