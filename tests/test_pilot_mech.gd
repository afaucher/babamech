extends TestCase
## The mech hook for the pilot heads (docs/design/pilot-heads.md): MechModel's low-poly cockpit seats a PilotHead
## (`MechModel.pilot`) in a holder named Head_<id> at the old place and scale, idling on its own; the placeholder art has
## none; every rebuild makes a new one and frees the old. MechRig feeds it each physics frame: the neck answers the
## mech's motion (and stays bounded), turning left is a positive yaw rate, running is effort, and a fall then landing
## triggers the impact reaction.


func setup() -> void:
	timeout_sec = 90.0
	var blue := Color(0.16, 0.42, 0.85)
	# Every head: a PilotHead in the cockpit, named / placed / scaled like the static head was.
	for id: String in MechCatalog.HEAD_ORDER:
		var m := MechModel.new()
		m.configure(id, "strider", {})
		add_child(m)
		await frames(1)
		if not check(m.pilot != null, "%s: lowpoly mech has a pilot head" % id):
			m.queue_free()
			continue
		eq(m.pilot.head_id, id, "%s: the pilot head is its own rig (no fallback)" % id)
		var holder := m.find_child("Head_" + id, true, false) as Node3D
		check(holder != null and m.pilot.get_parent() == holder, "%s: the pilot sits in Head_%s" % [id, id])
		if holder != null:
			eq(str(holder.get_parent().name), "Cockpit", "%s: Head_%s is in the cockpit seat" % [id, id])
			check(holder.position.is_equal_approx(Vector3(0, -0.12, 0)), "%s: at the old place (%s)" % [id, holder.position])
			near(holder.scale.x, float(m.params["head"]) / (float(m.params["body"]) * MechMeshes.BODY_SCALE), 1e-5,
				"%s: at the old scale" % id)
		check(m.pilot.transform.is_equal_approx(Transform3D.IDENTITY), "%s: the pilot is at its holder's origin" % id)
		check(m.pilot.idle_always, "%s: idles on its own when nothing feeds it" % id)
		# The accent never recolours the pilot head.
		var before := _overrides(m.pilot)
		m.set_accent(blue)
		check(_overrides(m.pilot) == before, "%s: set_accent leaves the pilot head's materials alone" % id)
		m.queue_free()
	await frames(1)

	# Rebuilds: a new pilot each time, the old one freed, one head in the seat; the seed and the head scale follow.
	var m := MechModel.new()
	add_child(m)
	await frames(1)
	var old := m.pilot
	m.rebuild()
	check(m.pilot != null and m.pilot != old, "rebuild() makes a new pilot")
	await frames(1)
	check(not is_instance_valid(old), "rebuild() frees the old pilot")
	var seat := m.find_child("Cockpit", true, false)
	check(seat != null and seat.get_child_count() == 1 and seat.get_child(0).get_child_count() == 1,
		"one head in the seat after a rebuild")
	old = m.pilot
	m.pilot_seed = 7
	m.configure("duck", "strider", {})
	check(m.pilot != old and m.pilot.head_id == "duck", "configure() reassigns the pilot (duck)")
	eq(m.pilot.look_seed, 7, "the pilot takes pilot_seed")
	await frames(1)
	check(not is_instance_valid(old), "configure() frees the old pilot")
	m.set_lab_param("head", 1.6)
	var holder := m.find_child("Head_duck", true, false) as Node3D
	near(holder.scale.x, 1.6 / MechMeshes.BODY_SCALE, 1e-5, "the head param scales the pilot head")
	m.set_lab_param("body", 1.3)
	holder = m.find_child("Head_duck", true, false) as Node3D
	near(holder.scale.x, 1.6 / (1.3 * MechMeshes.BODY_SCALE), 1e-5, "the head scale stays absolute when the body scales")
	m.set_lab_option("art", "placeholder")
	await frames(1)
	check(m.pilot == null, "the placeholder art has no pilot head")
	check(m.find_child("Head_duck", true, false) != null, "the placeholder keeps its static head")
	m.set_lab_option("art", "lowpoly")
	check(m.pilot != null, "back to lowpoly: a pilot again")
	m.queue_free()

	# MechRig feeding it: stand, then walk / run forward, then turn left, then a fall and a landing.
	var lab := RingWalkLab.new()
	add_child(lab)
	await frames(2)
	lab.set_lab_option("mode", "stand")
	await frames(10)
	lab.bot_enabled = false
	var mech := lab.mech
	var rig := lab.rig
	lab.place_mech(-11.0, 4.0)
	mech.move_input = Vector2.ZERO
	mech.running = false
	mech.turn_input = 0.0
	await frames(60)
	var pilot := rig.model.pilot
	if not check(pilot != null, "the rig's model has a pilot"):
		lab.queue_free()
		finish()
		return
	pilot.idle_enabled = false   # exact poses: no blinks / glances
	for i in 60:
		await get_tree().physics_frame
	check(not pilot.idle_always, "MechRig turns idle_always off when it feeds the head")
	var still := _neck(pilot)
	check(still.length() < 0.15, "standing still: the neck rests (%.3f rad)" % still.length())
	var worst := 0.0
	var moved := 0.0
	var fwd_vel := 0.0
	var footfalls := 0
	var effort := false
	for frame in 180:
		mech.move_input = Vector2(0, 1)
		mech.running = frame > 90
		await get_tree().physics_frame
		var n := _neck(pilot)
		check(n.is_finite(), "neck pose finite")
		moved = maxf(moved, (n - still).length())
		worst = maxf(worst, n.length())
		var v: Vector3 = pilot._in["vel"]
		fwd_vel = minf(fwd_vel, v.z)
		if bool(pilot._in["footfall"]):
			footfalls += 1
		effort = effort or pilot.reacting("effort")
	print("walk: neck moved %.3f rad (worst %.3f), forward vel %.2f u/s, %d footfalls" % [moved, worst, fwd_vel, footfalls])
	check(moved > 0.05, "walking / running moves the neck (%.3f rad from rest)" % moved)
	check(worst < 1.5, "and keeps it bounded (%.3f rad)" % worst)
	check(fwd_vel < -mech.walk_speed / rig.mech_scale * 0.8,
		"forward is -Z in model units (%.2f u/s, walk %.2f)" % [fwd_vel, mech.walk_speed / rig.mech_scale])
	check(footfalls > 2, "walking strides send footfalls (%d)" % footfalls)
	check(effort, "running is effort")
	mech.move_input = Vector2.ZERO
	mech.running = false
	var yaw := 0.0
	for i in 40:
		mech.turn_input = -1.0   # left
		await get_tree().physics_frame
		yaw = maxf(yaw, float(pilot._in["yaw_rate"]))
	mech.turn_input = 0.0
	near(yaw, mech.turn_rate, mech.turn_rate * 0.3, "turning left feeds a positive yaw rate (%.2f rad/s)" % yaw)
	for i in 60:
		await get_tree().physics_frame

	# A fall from 6 m and the landing: the impact reaction.
	check(not pilot.reacting("impact"), "no impact before the fall")
	mech.global_position += mech.up() * 6.0
	mech.velocity = Vector3.ZERO
	var landed := -1
	var impact := false
	var air := false
	var air_impact := false
	for i in 120:
		await get_tree().physics_frame
		if not mech.grounded():
			air = true
			air_impact = air_impact or pilot.reacting("impact")
		elif air and landed < 0:
			landed = i
		if landed >= 0:
			impact = impact or pilot.reacting("impact")
			if i - landed > 20:
				break
	check(air and landed >= 0, "the mech fell and landed (frame %d, %.1f m/s)" % [landed, mech.last_impact])
	check(not air_impact, "no impact while in the air")
	check(impact, "landing triggers the impact reaction")
	lab.queue_free()
	await frames(1)
	finish()


## The pilot neck's lower + upper joint angles (rad).
func _neck(p: PilotHead) -> Vector3:
	return p.neck.low + p.neck.high


## Every MeshInstance3D under `root` and its surface override materials.
func _overrides(root: Node) -> Array:
	var out: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mm := mi as MeshInstance3D
		var row: Array = [mm.material_override]
		if mm.mesh != null:
			for s in mm.mesh.get_surface_count():
				row.append(mm.get_surface_override_material(s))
		out.append(row)
	return out
