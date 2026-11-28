extends TestCase
## The Wasp's pose from its motion (HoverPose, driven by MechRig for a hover model; docs/design/wasp-hover.md section 3).
## A real Wasp flown by its controller, and a PUPPET Wasp (puppet = true: no step(), fed only the streamed state the
## way MechPuppet.apply does: transform, velocity, grounded, shutdown) 40 m to the side over the same flat floor:
##  - strafing right: rolls right side down (within bank_roll), left fan tilted outward +, right fan -, inside the tilt
##    ellipse; flying forward: nose down, both fans tilted forward;
##  - rotors: idle spin hovering, faster boosting, winding down to 0 after a shutdown, idling landed;
##  - legs: dangling in flight, standing by the touchdown of a powered descent, the touchdown dip keeps the soles on the
##    ground (the model lowered), standing before the impact of a shutdown fall;
##  - every pose stays inside the ranges tests/test_clearance_wasp.gd sweeps for part intersections (tilt inside the
##    ellipse, legs 0..1; bank turns the whole hull, legs and fans together);
##  - the puppet's pose follows the owner's within a small tolerance (one physics frame of lag).

var w: MechController
var p: MechController
var wpose: HoverPose
var ppose: HoverPose
var wm: MechModel
var pm: MechModel
const SIDE := Vector3(40, 0, 0)
var _worst := {"tilt_out": 0.0, "legs_out": 0.0, "roll": 0.0, "dpup_roll": 0.0, "dpup_legs": 0.0, "dpup_spin": 0.0}


func _init() -> void:
	timeout_sec = 200.0


func setup() -> void:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 1, 600)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)
	w = MechSpawn.make("chicken", "wasp", {}, 1, "", true)
	add_child(w)
	p = MechSpawn.make("chicken", "wasp", {}, 2, "", true)
	p.puppet = true
	p.position = SIDE   # never spawned overlapping the owner (two capsules in one spot fling the live one away)
	add_child(p)
	await frames(3)
	wpose = MechSpawn.rig_of(w).hover_pose
	ppose = MechSpawn.rig_of(p).hover_pose
	wm = MechSpawn.rig_of(w).model
	pm = MechSpawn.rig_of(p).model
	check(wm.is_hover() and pm.is_hover(), "both models are the Wasp (hover)")
	_place(Vector3(0, 0.05, 0), true)
	await _run(1.0)
	check(wpose.legs > 0.95, "landed at spawn: legs standing (%.2f)" % wpose.legs)
	near(wpose.spin, wpose.spin_ground, 0.3, "landed and live: rotors idling (%.2f rev/s)" % wpose.spin)
	# Lift off and hover.
	w.climb_input = 1.0
	await _run(1.0)
	w.climb_input = 0.0
	await _run(2.0)
	check(w.altitude() > 7.0, "flying at %.1f m" % w.altitude())
	check(wpose.legs < 0.2, "in flight the legs dangle (%.2f)" % wpose.legs)
	near(wpose.spin, wpose.spin_idle, 0.4, "hovering: idle spin (%.2f)" % wpose.spin)
	# Strafe right.
	w.move_input = Vector2(1, 0)
	await _run(1.5)
	check(wpose.roll > wpose.bank_roll * 0.3, "strafing right rolls right side down (%.3f rad)" % wpose.roll)
	check(wpose.tilt_l.y > 0.0 and wpose.tilt_r.y < 0.0, "left fan tilted outward +, right fan - (%s / %s)" % [
		str(wpose.tilt_l), str(wpose.tilt_r)])
	# Forward, boosting.
	w.move_input = Vector2(0, 1)
	w.running = true
	await _run(2.0)
	check(wpose.pitch < -wpose.bank_pitch * 0.3, "flying forward pitches nose down (%.3f rad)" % wpose.pitch)
	check(wpose.tilt_l.x > 0.0 and wpose.tilt_r.x > 0.0, "both fans tilted forward (%s / %s)" % [str(wpose.tilt_l), str(wpose.tilt_r)])
	check(wpose.spin > wpose.spin_idle + 1.0, "boosting spins the rotors up (%.2f)" % wpose.spin)
	w.move_input = Vector2.ZERO
	w.running = false
	await _run(3.0)
	near(wpose.roll, 0.0, 0.02, "stopped: level again (roll)")
	near(wpose.pitch, 0.0, 0.02, "stopped: level again (pitch)")
	# Powered descent: legs standing at the touchdown, the dip keeps the soles on the ground.
	w.climb_input = -1.0
	var legs_at_touch := -1.0
	var sole_err := 0.0
	var dropped := 0.0
	for i in 600:
		await get_tree().physics_frame
		_feed()
		_track()
		if legs_at_touch < 0.0 and w.grounded():
			legs_at_touch = wpose.legs
		if legs_at_touch >= 0.0:
			sole_err = maxf(sole_err, absf(_sole_y(wm) - w.global_position.y))
			dropped = maxf(dropped, wpose.drop)
		if legs_at_touch >= 0.0 and i > 0 and wpose.legs > 0.999 and wpose.drop < 1e-3 and dropped > 0.0:
			break
	w.climb_input = 0.0
	check(legs_at_touch > 0.85, "legs standing at the touchdown (%.2f)" % legs_at_touch)
	check(dropped > 0.005, "the touchdown dips (model lowered %.3f m)" % dropped)
	check(sole_err < 0.08, "the soles stay on the ground through the dip (worst %.3f m)" % sole_err)
	await _run(1.0)
	near(wpose.legs, 1.0, 0.01, "then stands")
	near(wpose.spin, wpose.spin_ground, 0.3, "landed: rotors idling (%.2f)" % wpose.spin)
	# Shutdown at height: rotors wind down, legs stand before the impact.
	w.climb_input = 1.0
	for i in 400:
		await get_tree().physics_frame
		w.heat = 0.0
		_feed()
		_track()
		if w.global_position.y > 25.0:
			break
	w.climb_input = 0.0
	w.add_heat(w.heat_cap)
	var legs_before := 0.0
	for i in 400:
		await get_tree().physics_frame
		_feed()
		_track()
		if w.grounded():
			break
		legs_before = wpose.legs
	check(legs_before > 0.9, "a shutdown fall stands its legs before the impact (%.2f)" % legs_before)
	await _run(3.0)
	near(wpose.spin, 0.0, 1e-3, "shut down: the rotors stop")
	near(ppose.spin, 0.0, 1e-3, "the puppet's rotors stop too")
	w.reset_heat()
	print("[hover pose] worst: tilt outside ellipse %.4f, legs outside 0..1 %.4f, |roll| %.3f (bank_roll %.2f); puppet vs owner: roll %.4f, legs %.4f, spin %.3f" % [
		_worst["tilt_out"], _worst["legs_out"], _worst["roll"], wpose.bank_roll, _worst["dpup_roll"], _worst["dpup_legs"],
		_worst["dpup_spin"]])
	check(float(_worst["tilt_out"]) < 1e-4, "the fans stay inside their tilt ellipse (test_clearance_wasp sweeps it)")
	check(float(_worst["legs_out"]) < 1e-6, "the legs pose stays in 0..1 (test_clearance_wasp sweeps it)")
	check(float(_worst["roll"]) <= wpose.bank_roll + 1e-4, "the roll never passes bank_roll")
	check(float(_worst["dpup_roll"]) < 0.02, "the puppet banks as its owner (%.4f rad)" % _worst["dpup_roll"])
	# The puppet learns of the touchdown one frame late (its grounded comes from the stream), and the touchdown dip is
	# steep (bottom in 0.12 s): one frame of it is about 0.1 of the legs pose.
	check(float(_worst["dpup_legs"]) < 0.12, "the puppet's legs follow its owner's (%.4f)" % _worst["dpup_legs"])
	check(float(_worst["dpup_spin"]) < 0.3, "the puppet's rotors follow its owner's (%.3f rev/s)" % _worst["dpup_spin"])
	finish()


func _place(at: Vector3, landed: bool) -> void:
	w.global_transform = Transform3D(Basis.IDENTITY, at)
	w.velocity = Vector3.ZERO
	w.set_landed(landed)
	wpose.reset()
	ppose.reset()
	_feed()


## The puppet gets what the snapshot carries (MechPuppet.apply): transform, velocity, grounded, shutdown, heat.
func _feed() -> void:
	p.global_transform = Transform3D(w.global_basis, w.global_position + SIDE)
	p.velocity = w.velocity
	p.puppet_grounded = w.grounded()
	p.shutdown = w.shutdown
	p.heat = w.heat


func _track() -> void:
	for t: Vector2 in [wpose.tilt_l, wpose.tilt_r]:
		_worst["tilt_out"] = maxf(float(_worst["tilt_out"]), (wm.clamp_fan_tilt(t) - t).length())
	_worst["legs_out"] = maxf(float(_worst["legs_out"]), maxf(-wpose.legs, wpose.legs - 1.0))
	_worst["roll"] = maxf(float(_worst["roll"]), absf(wpose.roll))
	_worst["dpup_roll"] = maxf(float(_worst["dpup_roll"]), absf(wpose.roll - ppose.roll))
	_worst["dpup_legs"] = maxf(float(_worst["dpup_legs"]), absf(wpose.legs - ppose.legs))
	_worst["dpup_spin"] = maxf(float(_worst["dpup_spin"]), absf(wpose.spin - ppose.spin))


func _run(sec: float) -> void:
	for i in int(round(sec * Engine.physics_ticks_per_second)):
		await get_tree().physics_frame
		w.heat = minf(w.heat, w.heat_cap * 0.5) if not w.shutdown else w.heat
		_feed()
		_track()


## The lower sole's world height (the feet nodes' origins are the soles).
func _sole_y(m: MechModel) -> float:
	var y := INF
	for tag: String in ["l", "r"]:
		var f := m.find_child("foot_" + tag, true, false) as Node3D
		if f != null:
			y = minf(y, f.global_position.y)
	return y
