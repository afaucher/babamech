extends TestCase
## The mech walks the curved ring strip under physics: it stays on the floor, its up follows the ring's radial gravity,
## it covers ground at walk and run, and the leg IK keeps its feet in reach.


func setup() -> void:
	var lab := RingWalkLab.new()
	add_child(lab)
	await frames(2)
	var mech := lab.mech
	var ring := lab.ring
	# Walk along +s at ~walk speed for 4 s.
	lab.set_lab_option("mode", "stand")
	await frames(30)
	lab.bot_enabled = false
	near(ring.height(mech.global_position), 0.0, 0.3, "standing on the floor")
	var start := ring.world_to_arc(mech.global_position)
	var worst_up := 1.0
	var worst_reach := 1.0
	var max_h := 0.0
	var off_floor := 0
	for frame in 240:
		mech.move_input = Vector2(0, 1)
		mech.running = frame > 120
		await get_tree().physics_frame
		worst_up = minf(worst_up, mech.global_basis.y.dot(ring.up_at(mech.global_position)))
		worst_reach = minf(worst_reach, lab.rig.reached_fraction)
		max_h = maxf(max_h, ring.height(mech.global_position))
		if not mech.is_on_floor():
			off_floor += 1
	var end := ring.world_to_arc(mech.global_position)
	var moved := absf(end.y - start.y) + absf(end.x - start.x)
	check(moved > 25.0, "covered ground along the arc (%.1f m)" % moved)
	check(worst_up > 0.999, "body up follows radial gravity (worst dot %.5f)" % worst_up)
	check(worst_reach >= 0.5, "IK kept at least one foot in reach every frame")
	check(off_floor < 30, "stays grounded on the curve (%d frames off)" % off_floor)
	check(lab.rig.gait.feet.size() == 2, "two feet planted")
	# Every lab bot mode runs without errors.
	lab.bot_enabled = true
	for m: String in RingWalkLab.MODES:
		lab.set_lab_option("mode", m)
		await frames(20)
	lab.queue_free()
	await frames(1)
	finish()
