extends TestCase
## A mech jammed where it cannot move must not pile up velocity (MechController._reconcile / _unstick). Godot's grounded
## move_and_slide clears velocity only on a floor: a capsule pushed into two faces it cannot depenetrate from stays put
## while gravity kept adding ~22 m/s every second (a bot run on seed 3 reached 5767 m/s), which would fling the mech or
## land it "hard" (leg damage) once free. Flat world (+Y up, gravity 22), a real mech (MechSpawn.make), every limit in
## physics frames:
## (a) wedge: the capsule (r 2.2) between two 6 m blocks 2 m apart, feet 1 m above the floor, overlapping both faces,
##     emergency burn off (a shut-down mech has none; before the fix: 22 m/s more every second): speed stays bounded, no hard_landing, it is nudged free (out on top) and can then walk;
## (b) control: a 30 m free fall onto the floor still lands hard at the free-fall speed (sqrt(2 g h), ~36 m/s), and so
##     does the same fall grazing a wall it walks into;
## (c) a puppet placed in the same wedge is never simulated (stays put, velocity untouched).

const GAP := 2.0
const BLOCK_H := 6.0
const FALL_H := 30.0

var _bodies: Array[Node] = []


func _slab(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = center
	add_child(body)
	_bodies.append(body)


func _clear() -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()


func setup() -> void:
	var mech := MechSpawn.make("chicken", "strider", {}, 1)
	add_child(mech)
	var landings: Array = []
	mech.hard_landing.connect(func(speed: float, sev: float) -> void: landings.append([speed, sev]))
	await frames(2)
	print("mech: capsule r %.2f, gravity %.1f, max_step_up %.2f" % [((mech.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D).radius,
		mech.gravity, mech.max_step_up])

	# (a) The wedge.
	_slab(Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	_slab(Vector3(-GAP * 0.5 - 5.0, BLOCK_H * 0.5, 0), Vector3(10, BLOCK_H, 40))
	_slab(Vector3(GAP * 0.5 + 5.0, BLOCK_H * 0.5, 0), Vector3(10, BLOCK_H, 40))
	await frames(2)
	_reset(mech, Vector3(0, 1.0, 0))
	mech.auto_burn = false   # as when shut down: the emergency burn would hide the runaway (it held it near 10 m/s)
	var vmax := 0.0
	var free_at := -1
	for f in 600:
		await get_tree().physics_frame
		vmax = maxf(vmax, mech.velocity.length())
		if free_at < 0 and mech.global_position.y >= BLOCK_H - 0.3:
			free_at = f
		if free_at >= 0 and f > free_at + 60:
			break
	print("[wedge] vmax %.2f m/s, out on top at frame %d, at %s, grounded %s, landings %s" % [vmax, free_at,
		str(mech.global_position), mech.grounded(), str(landings)])
	check(vmax < 10.0, "wedged: speed stays bounded (max %.2f m/s)" % vmax)
	check(landings.is_empty(), "wedged: no hard_landing (%s)" % str(landings))
	check(free_at >= 0 and free_at <= 240, "wedged: nudged free within 4 s (frame %d)" % free_at)
	check(mech.velocity.length() < 10.0, "freed: no fling (%.2f m/s)" % mech.velocity.length())
	# Then it walks: along the gap's line (+z), over the block tops.
	var p0 := mech.global_position
	mech.move_input = Vector2(0, 1)
	for f in 120:
		await get_tree().physics_frame
		vmax = maxf(vmax, mech.velocity.length())
	mech.move_input = Vector2.ZERO
	mech.auto_burn = true
	var walked := (mech.global_position - p0).length()
	print("[wedge] walked %.1f m in 2 s, vmax %.2f, landings %s" % [walked, vmax, str(landings)])
	check(walked > 6.0, "freed: it walks away (%.1f m in 2 s)" % walked)
	check(landings.is_empty(), "no hard_landing walking out (%s)" % str(landings))

	# (c) A puppet in the same wedge is posed by snapshots only: nothing here moves it or touches its velocity.
	var pup := MechSpawn.make("chicken", "strider", {}, 2)
	pup.puppet = true
	add_child(pup)
	await frames(2)
	pup.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.0, -10.0))
	pup.velocity = Vector3(0, -3.0, 0)
	for f in 60:
		await get_tree().physics_frame
	near(pup.global_position.distance_to(Vector3(0, 1.0, -10.0)), 0.0, 1e-4, "a puppet is not simulated (stays put)")
	near(pup.velocity.y, -3.0, 1e-4, "a puppet's velocity is the snapshot's")
	pup.queue_free()
	_clear()
	await frames(2)

	# (b) Control: a legit 30 m fall still lands hard at free-fall speed.
	_slab(Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	await frames(2)
	var expect := sqrt(2.0 * mech.gravity * FALL_H)
	var hit := await _fall(mech, landings, Vector3(0, FALL_H, 0), Vector2.ZERO)
	print("[fall] open air: %s (free fall %.1f)" % [str(hit), expect])
	check(hit.size() == 1, "a real fall emits one hard_landing (%s)" % str(hit))
	if hit.size() == 1:
		near(float(hit[0][0]), expect, 1.5, "landing speed is the free-fall speed")
		near(float(hit[0][1]), 1.0, 1e-3, "and the worst severity")
	# Grazing a wall it walks into all the way down: the wall must not eat the fall speed.
	_slab(Vector3(3.5, FALL_H * 0.5, 0), Vector3(1, FALL_H + 4.0, 40))
	await frames(2)
	hit = await _fall(mech, landings, Vector3(0, FALL_H, 0), Vector2(1, 0))
	print("[fall] along a wall: %s" % str(hit))
	check(hit.size() == 1, "a fall along a wall emits one hard_landing (%s)" % str(hit))
	if hit.size() == 1:
		near(float(hit[0][0]), expect, 1.5, "landing speed along the wall is the free-fall speed")
	_clear()
	finish()


func _reset(mech: MechController, at: Vector3) -> void:
	mech.global_transform = Transform3D(Basis.IDENTITY, at)
	mech.velocity = Vector3.ZERO
	mech.move_input = Vector2.ZERO
	mech.thrust_input = false
	mech.heat = 0.0
	mech.shutdown = false


## Drop from `at` with the emergency burn off, holding `input`; the hard landings it made.
func _fall(mech: MechController, landings: Array, at: Vector3, input: Vector2) -> Array:
	_reset(mech, at)
	mech.auto_burn = false
	mech.move_input = input
	landings.clear()
	for f in 300:
		await get_tree().physics_frame
		if mech.grounded() and f > 10:
			break
	for f in 5:
		await get_tree().physics_frame
	mech.move_input = Vector2.ZERO
	mech.auto_burn = true
	return landings.duplicate()
