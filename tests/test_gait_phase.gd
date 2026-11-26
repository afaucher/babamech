extends TestCase
## Gait phase (playtest: "the legs can get in sync so you wind up hopping instead of walking"). The REAL rig (MechSpawn
## mech: MechController + MechRig + Gait, each chassis' ChassisParts rig numbers) at the runner's fixed 60 Hz, on a flat
## floor, over a long scripted input sequence: start from rest, walk, walk -> run -> walk, stop / start, walk + turn,
## turn in place then walk, diagonal, strafe, slow walk, speed ramps, a thrust hop mid-walk and walking on after it.
## Then the bare Gait: a walk over curbs, and a puppet fed snapshot-stepped jittery motion (remote mechs run the same rig
## from streamed motion).
##
## Steady walking = on the ground, speed above STEADY_K of walk speed, for longer than STEADY_SEC (more than a cycle)
## without a break (the air, a stop) or a change of course (a new direction or turn: the Strider's hip twist swings
## round; changes of speed, walk <-> run and the ramps, stay in). Over steady walking, per chassis:
##   - at a walk (not running) never both feet in swing;
##   - double support (both planted) share below MAX_DOUBLE;
##   - the phase offset between the feet (when foot i lifts: time since the other lifted / time since i last lifted)
##     within 0.5 +/- PHASE_TOL, from the fourth lift of every moving stretch on (recovery within two steps of
##     each foot after each disturbance: a start, a landing, a stop, a change of course);
##   - footfalls alternate L R L R;
##   - planted feet do not slide.
## Prints per-chassis numbers (BABAMECH_GAIT_DEBUG=1 also prints every lift).

const STEADY_K := 0.4
const STEADY_SEC := 1.0
const PHASE_TOL := 0.15
const MAX_DOUBLE := 0.35
const SLIDE_SPEED := 0.3     ## m/s: a planted foot's drawn position moving (test_rig_bulwark's bound)
const DT := 1.0 / 60.0
const RECOVER_LIFTS := 3     ## lifts after a disturbance before the phase must hold: each foot's second step is in phase
const MAX_FORCED := 2       ## reach emergencies per steady sequence (a walk + turn starting can force one)

var mech: MechController
var rig: MechRig
var _floor: StaticBody3D


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_floor = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 1, 4000)
	cs.shape = box
	_floor.add_child(cs)
	_floor.position = Vector3(0, -0.5, 0)
	add_child(_floor)
	for chassis: String in ["strider", "bulwark"]:
		await _chassis(chassis)
	_curbs()
	_puppet()
	finish()


## The scripted sequence: [tag, frames, move, turn, run, thrust frames at the start].
const SEQUENCE := [
	["stand", 60, Vector2.ZERO, 0.0, false, 0],
	["walk from rest", 300, Vector2(0, 1), 0.0, false, 0],
	["run", 240, Vector2(0, 1), 0.0, true, 0],
	["run -> walk", 240, Vector2(0, 1), 0.0, false, 0],
	["stop", 50, Vector2.ZERO, 0.0, false, 0],
	["walk again", 240, Vector2(0, 1), 0.0, false, 0],
	["walk + turn", 240, Vector2(0, 1), 0.7, false, 0],
	["turn in place", 120, Vector2.ZERO, 1.0, false, 0],
	["walk after turn", 240, Vector2(0, 1), 0.0, false, 0],
	["diagonal", 240, Vector2(0.7, 0.7), 0.0, false, 0],
	["strafe", 240, Vector2(1, 0), 0.0, false, 0],
	["slow walk", 240, Vector2(0, 0.5), 0.0, false, 0],
	["ramp", 360, Vector2(0, 1), 0.0, false, 0],
	["hop", 40, Vector2(0, 1), 0.0, false, 40],
	["walk after hop", 300, Vector2(0, 1), 0.0, false, 0],
	["short stop", 12, Vector2.ZERO, 0.0, false, 0],
	["walk on", 240, Vector2(0, 1), 0.0, false, 0],
	["run again", 240, Vector2(0, 1), 0.0, true, 0],
	["stand", 60, Vector2.ZERO, 0.0, false, 0],
]


func _chassis(chassis: String) -> void:
	mech = MechSpawn.make("chicken", chassis, {}, 1)
	add_child(mech)
	mech.global_position = Vector3(0, 0.1, 0)
	await frames(3)
	rig = MechSpawn.rig_of(mech)
	print("  %s: stance %.2f m, foot clearance %.2f m, reach_err %.2f" % [chassis,
		((rig.gait.feet[1]["pos"] as Vector3) - (rig.gait.feet[0]["pos"] as Vector3)).length(), rig.gait.foot_clearance, rig.gait.reach_err])
	var rec := Rec.new(rig.gait, mech.walk_speed * STEADY_K)
	for seg: Array in SEQUENCE:
		var tag: String = seg[0]
		var n: int = seg[1]
		mech.move_input = seg[2]
		mech.turn_input = seg[3]
		mech.running = seg[4]
		for f in n:
			mech.thrust_input = f < int(seg[5])
			if tag == "ramp":   # speed ramps: input 0.35 .. 1 and back, twice
				mech.move_input = Vector2(0, 0.675 + 0.325 * cos(float(f) / float(n) * TAU * 2.0))
			if not mech.shutdown:
				mech.heat = 0.0
			await get_tree().physics_frame
			var drawn: Array = []
			for i in 2:
				drawn.append(rig.model.to_global(rig.model.leg_points(i).get("foot", Vector3.ZERO)))
			var absorbing := rig._land_t < rig.absorb_time * 2.0
			rec.frame(DT, mech.ground_speed(), rig._airborne or not mech.grounded(), mech.ground_speed() > mech.walk_speed * 1.1, drawn, absorbing, tag,
					"%s %s" % [str((seg[2] as Vector2).normalized()), str(seg[3])])
	_report(chassis, rec, 20.0)
	mech.queue_free()
	await frames(2)


func _report(label: String, rec: Rec, min_steady: float) -> void:
	var r := rec.result()
	print("  [gait phase] %-8s steady %.1f s: both in swing at walk %d frames (%.1f%%), at run %.1f%%, double support %.1f%%, phase offset off 0.5 by mean %.3f worst %.3f (%d/%d lifts outside 0.5+/-%.2f), reach emergencies %d (other foot t >= %.2f), late recoveries %d, same-foot footfalls %d/%d, planted speed %.3f m/s" % [
		label, r["steady_sec"], r["both_walk"], 100.0 * r["both_walk_share"], 100.0 * r["both_run_share"], 100.0 * r["double_share"],
		r["phase_mean"], r["phase_worst"], r["phase_bad"], r["phase_n"], PHASE_TOL, r["forced"], r["forced_t"], r["late"], r["repeats"], r["falls"], r["slide"]])
	if r["slide"] > SLIDE_SPEED:
		print("    worst slide in: %s" % r["slide_tag"])
	if not r["bad_tags"].is_empty():
		print("    out-of-phase lifts in: %s" % str(r["bad_tags"]))
	check(r["steady_sec"] > min_steady, "%s: enough steady walking measured (%.1f s)" % [label, r["steady_sec"]])
	eq(r["both_walk"], 0, "%s: at a walk never both feet in swing (but for the reach emergency)" % label)
	check(r["forced"] <= MAX_FORCED, "%s: reach emergencies (a foot lifting while the other swings, about to leave the leg's reach) are rare: %d" % [label, r["forced"]])
	check(r["forced_t"] >= 0.75, "%s: ...and only when the other foot is nearly down (t %.2f): never a hop" % [label, r["forced_t"]])
	check(r["double_share"] <= MAX_DOUBLE, "%s: double support %.1f%% <= %.0f%%" % [label, 100.0 * r["double_share"], 100.0 * MAX_DOUBLE])
	check(r["phase_n"] > 30, "%s: phase measured (%d lifts)" % [label, r["phase_n"]])
	eq(r["phase_bad"], 0, "%s: feet half a cycle apart (worst off by %.3f)" % [label, r["phase_worst"]])
	eq(r["late"], 0, "%s: back in phase within two steps after every disturbance" % label)
	eq(r["repeats"], 0, "%s: footfalls alternate L R L R" % label)
	check(r["slide"] <= SLIDE_SPEED, "%s: planted feet do not slide (%.3f m/s)" % [label, r["slide"]])


## Bare Gait over curbs (0.5 m up / down every 9 m) at a walk, Strider and Bulwark numbers.
func _curbs() -> void:
	for chassis: String in ["strider", "bulwark"]:
		var g := _gait_for(chassis)
		var walk := 12.0 if chassis == "strider" else 8.0
		var stance := 2.7 if chassis == "strider" else 6.8   # the hips' spread at mech scale 2
		var ground := func(p: Vector3, _up: Vector3) -> Vector3:
			return Vector3(p.x, 0.5 if fposmod(-p.z, 18.0) > 9.0 else 0.0, p.z)
		var rec := Rec.new(g, walk * STEADY_K)
		var pos := Vector3.ZERO
		var vel := Vector3.ZERO
		for frame in int(20.0 / DT):
			var want := Vector3(0, 0, -walk) if frame < int(18.0 / DT) else Vector3.ZERO
			vel = vel.move_toward(want, 20.0 * DT)
			pos += vel * DT
			var base: Vector3 = ground.call(pos, Vector3.UP)
			var homes := [Vector3(pos.x - stance * 0.5, 0, pos.z), Vector3(pos.x + stance * 0.5, 0, pos.z)]
			for i in 2:
				homes[i] = ground.call(homes[i], Vector3.UP)
			g.update(DT, homes, Vector3.UP, vel, ground, false, base)
			rec.frame(DT, vel.length(), false, false, g.positions(), false, "curbs")
		_report("%s curbs" % chassis, rec, 12.0)


## A puppet: the motion arrives as 20 Hz snapshots (velocity held between them, with jitter) while the body moves
## smoothly: walk, run, walk with turns.
func _puppet() -> void:
	for chassis: String in ["strider", "bulwark"]:
		var g := _gait_for(chassis)
		var walk := 12.0 if chassis == "strider" else 8.0
		var run := 22.0 if chassis == "strider" else 14.0
		var stance := 2.7 if chassis == "strider" else 6.8   # the hips' spread at mech scale 2
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var flat := func(p: Vector3, _up: Vector3) -> Vector3: return Vector3(p.x, 0.0, p.z)
		var rec := Rec.new(g, walk * STEADY_K)
		var pos := Vector3.ZERO
		var heading := 0.0
		var vel := Vector3.ZERO
		var snap_vel := Vector3.ZERO
		for frame in int(30.0 / DT):
			var t := float(frame) * DT
			var top := run if t > 10.0 and t < 16.0 else walk
			if t > 20.0 and t < 25.0:
				heading += 0.6 * DT
			var fwd := Vector3(-sin(heading), 0, -cos(heading))
			vel = vel.move_toward(fwd * (top if t < 28.0 else 0.0), 25.0 * DT)
			pos += vel * DT
			if frame % 3 == 0:   # a snapshot: the streamed velocity, a little off
				snap_vel = vel * rng.randf_range(0.9, 1.1) + Vector3(rng.randf_range(-0.4, 0.4), 0, rng.randf_range(-0.4, 0.4))
			var right := fwd.cross(Vector3.UP)
			var homes := [pos - right * stance * 0.5, pos + right * stance * 0.5]
			g.facing = fwd
			g.update(DT, homes, Vector3.UP, snap_vel, flat)
			rec.frame(DT, vel.length(), false, vel.length() > walk * 1.1, g.positions(), false, "puppet", str(t > 20.0 and t < 25.0))
		_report("%s puppet" % chassis, rec, 20.0)


func _gait_for(chassis: String) -> Gait:
	var g := Gait.new()
	g.run_speed = 22.0 if chassis == "strider" else 14.0
	if chassis == "bulwark":
		for k: String in ChassisParts.BULWARK_RIG:
			if k.begins_with("gait."):
				g.set(k.trim_prefix("gait."), ChassisParts.BULWARK_RIG[k])
		g.foot_clearance = float(ChassisParts.BULWARK_RIG["foot_gap"]) * 2.0
	return g


## Per-frame recorder: lifts, footfalls, support, phase.
class Rec:
	var gait: Gait
	var thr: float
	var t := 0.0
	var run_t := 0.0          # seconds of the current moving stretch
	var lifts_in_run := 0
	var last_lift := [-1.0, -1.0]
	var prev_stepping := [false, false]
	var prev_plant: Array = [Vector3.INF, Vector3.INF]
	var prev_drawn: Array = [Vector3.INF, Vector3.INF]
	var steady_frames := 0
	var walk_frames := 0
	var run_frames := 0
	var both_walk := 0
	var both_run := 0
	var double := 0
	var phases: Array = []
	var phase_bad := 0
	var late := 0
	var bad_tags := {}
	var falls := 0
	var repeats := 0
	var last_fall := -1
	var slide := 0.0
	var slide_tag := ""
	var forced := 0
	var _course := ""
	var forced_t := 1.0
	var _steady := false

	func _init(g: Gait, threshold: float) -> void:
		gait = g
		thr = threshold
		g.stepped.connect(_on_step)

	func _on_step(foot: int, info: Dictionary) -> void:
		if not _steady or str(info["kind"]) == "land" or str(info["kind"]) == "settle":
			last_fall = -1 if not _steady else last_fall
			return
		falls += 1
		if foot == last_fall:
			repeats += 1
		last_fall = foot

	func frame(dt: float, speed: float, air: bool, running: bool, drawn: Array, absorbing: bool, tag: String,
			course: String = "") -> void:
		t += dt
		var moving := speed > thr and not air
		if course != _course:   # a change of course (not of speed) is a disturbance: steady again a cycle later
			_course = course
			run_t = 0.0
			lifts_in_run = 0
		if moving:
			run_t += dt
		else:
			run_t = 0.0
			lifts_in_run = 0
			last_lift = [-1.0, -1.0]
		_steady = moving and run_t > STEADY_SEC
		var s := [bool(gait.feet[0]["stepping"]), bool(gait.feet[1]["stepping"])]
		for i in 2:
			if s[i] and not prev_stepping[i] and moving:
				lifts_in_run += 1
				var j := 1 - i
				if s[j] and not running and not _steady:
					lifts_in_run = 1   # a lift over the other's swing while settling in (the hips swivelling): it restarts

				if _steady and s[j] and gait.feet[i].get("forced", false):
					forced += 1
					forced_t = minf(forced_t, float(gait.feet[j]["t"]))
				if OS.has_environment("BABAMECH_GAIT_DEBUG") and s[j]:
					print("      OVERLAP %s t %.2f foot %d lifts (%s, %.2f m) other t %.2f kind %s speed %.1f run %s" % [tag, t, i,
						gait.feet[i]["kind"], float(gait.feet[i]["length"]), float(gait.feet[j]["t"]), gait.feet[j]["kind"], speed, running])
				if last_lift[i] >= 0.0 and last_lift[j] > last_lift[i]:
					var ph: float = (t - float(last_lift[j])) / (t - float(last_lift[i]))
					if OS.has_environment("BABAMECH_GAIT_DEBUG"):
						print("      %s t %.2f foot %d phase %.3f speed %.1f lift#%d" % [tag, t, i, ph, speed, lifts_in_run])
					if _steady or lifts_in_run > RECOVER_LIFTS:
						phases.append(ph)
						if absf(ph - 0.5) > PHASE_TOL:
							phase_bad += 1
							bad_tags[tag] = int(bad_tags.get(tag, 0)) + 1
							if not _steady:
								late += 1
				last_lift[i] = t
		if _steady:
			steady_frames += 1
			if running:
				run_frames += 1
				if s[0] and s[1]:
					both_run += 1
			else:
				walk_frames += 1
				if s[0] and s[1] and not gait.feet[0].get("forced", false) and not gait.feet[1].get("forced", false):
					both_walk += 1
			if not s[0] and not s[1]:
				double += 1
		for i in 2:
			var plant: Vector3 = gait.feet[i]["pos"]
			if not s[i] and not prev_stepping[i] and not air and not absorbing and plant.is_equal_approx(prev_plant[i]) \
					and prev_drawn[i] != Vector3.INF:
				var v := ((drawn[i] as Vector3) - (prev_drawn[i] as Vector3)).length() / dt
				if v > slide:
					slide = v
					slide_tag = tag
			prev_plant[i] = plant
			prev_drawn[i] = drawn[i]
		prev_stepping = s

	func result() -> Dictionary:
		var mean := 0.0
		var worst := 0.0
		for p: float in phases:
			mean += absf(p - 0.5)
			worst = maxf(worst, absf(p - 0.5))
		if not phases.is_empty():
			mean /= float(phases.size())
		return {"steady_sec": float(steady_frames) * DT, "both_walk": both_walk,
			"both_walk_share": float(both_walk) / maxf(float(walk_frames), 1.0),
			"both_run_share": float(both_run) / maxf(float(run_frames), 1.0),
			"double_share": float(double) / maxf(float(steady_frames), 1.0), "phase_mean": mean, "phase_worst": worst,
			"phase_n": phases.size(), "phase_bad": phase_bad, "late": late, "bad_tags": bad_tags, "repeats": repeats, "falls": falls,
			"slide": slide, "slide_tag": slide_tag, "forced": forced, "forced_t": forced_t}
