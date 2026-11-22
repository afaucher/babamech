extends TestCase
## The test drive's first-person camera (C): the same ChaseCamera moves to the pilot's eyes, drops the head's render
## layer from its cull mask (the head stays on every other view), follows the body, still resolves an aim point for the
## weapons, and C again restores the chase view behind the mech.


func setup() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(10)
	td.drive_override = true
	var cam := td.cam
	var hidden_bit := 1 << (ChaseCamera.FP_HIDDEN_LAYER - 1)
	check(not cam.first_person and cam.current, "starts in the chase view")
	check(cam.cull_mask & hidden_bit != 0, "the chase view draws the pilot head layer")
	var chase_dist := cam.global_position.distance_to(td.mech.global_position)

	# Press C (the test drive's own key handling).
	var key := InputEventKey.new()
	key.keycode = KEY_C
	key.pressed = true
	td._unhandled_input(key)
	await frames(3)
	check(cam.first_person, "C switches to first person")
	check(get_viewport().get_camera_3d() == cam, "the first-person view is the current camera")
	check(cam.cull_mask & hidden_bit == 0, "first person leaves out the pilot head layer")
	check(cam.cull_mask & 1 != 0, "first person still draws layer 1 (city, hull, weapons, legs)")

	# Sits at the pilot's eyes: in the head, ahead of the mech's centre and well above its feet.
	var model := td.rig.model
	var head := model.pilot.get_parent() as Node3D
	var up := td.mech.up()
	var to_eye := cam.global_position - td.mech.global_position
	var head_d := cam.global_position.distance_to(head.global_position)
	check(head_d < 3.0, "camera sits in the head (%.2f m from the head origin)" % head_d)
	check(to_eye.dot(up) > 4.0, "eyes are high on the mech (%.2f m)" % to_eye.dot(up))
	check(to_eye.dot(td.mech.forward()) > 0.5, "eyes are forward of the mech's centre (head out the front)")
	check(to_eye.length() < chase_dist, "closer than the chase view")
	# The head (and only the head) is on the hidden layer; weapons, hull and legs are not.
	var head_meshes := _meshes(head)
	check(head_meshes.size() > 0, "the pilot head has meshes")
	var head_ok := true
	for mi in head_meshes:
		head_ok = head_ok and mi.layers == hidden_bit
	check(head_ok, "every pilot-head mesh is on the first-person hidden layer")
	var others := 0
	var others_ok := true
	for mi in _meshes(model):
		if mi in head_meshes:
			continue
		others += 1
		others_ok = others_ok and (mi.layers & 1) != 0
	check(others > 10 and others_ok, "the rest of the mech (%d meshes) stays visible in first person" % others)
	# Nothing visible clips the near plane: no other mesh of the mech wraps the eye.
	var clipping: Array[String] = []
	for mi in _meshes(model):
		if mi in head_meshes:
			continue
		var box := mi.global_transform * mi.get_aabb()
		if box.grow(cam.near).has_point(cam.global_position):
			clipping.append(str(mi.name))
	eq(clipping, [] as Array[String], "no visible mech part encloses the eye point")

	# Follows the body: walk, and the eye stays put in the cockpit's frame.
	var seat := model.find_child("Cockpit", true, false) as Node3D
	var local0 := seat.global_transform.affine_inverse() * cam.global_position
	for i in 60:
		td.mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
	await frames(1)
	var local1 := seat.global_transform.affine_inverse() * cam.global_position
	check(local0.distance_to(local1) < 0.05, "the eye rides the cockpit through the gait (%.3f)" % local0.distance_to(local1))
	td.mech.move_input = Vector2.ZERO

	# Same mouse look, and a wider pitch range than the chase view.
	var dir0 := cam.look_dir
	cam.add_mouse(Vector2(200, 0))
	check(dir0.angle_to(cam.look_dir) > 0.3, "mouse turns the first-person view")
	cam.add_mouse(Vector2(0, 2000))
	await frames(2)
	check(cam.pitch < cam.pitch_min - 0.1, "first person can look further down (pitch %.2f)" % cam.pitch)
	cam.add_mouse(Vector2(0, -440))   # back to about -0.2 rad
	await frames(2)

	# Aim: the camera's aim point resolves in front of the view, and the rack aims there.
	var ap := cam.aim_point()
	var view := -cam.global_basis.z
	check((ap - cam.global_position).dot(view) > 1.0, "aim point resolves ahead of the first-person view")
	await frames(3)
	var rack := td.combat.rack
	check(rack.camera == cam, "the weapon rack aims with the same camera")
	check((rack.aim_point - cam.global_position).normalized().dot(view) > 0.95, "the rack's aim point is on the view ray")
	var mh := td.get_node("MechHud") as MechHud
	check(mh._camera() == cam, "the HUD projects with the first-person camera")

	# RMB zoom narrows the first-person FOV.
	var fov0 := cam.fov
	cam.zoomed = true
	await frames(20)
	check(cam.fov < fov0 - 15.0, "zoom narrows the first-person FOV (%.1f -> %.1f)" % [fov0, cam.fov])
	cam.zoomed = false
	await frames(20)

	# C again: back behind and above, the head drawn again, the chase pitch range restored.
	td._unhandled_input(key)
	await frames(3)
	check(not cam.first_person and cam.current, "C restores the chase view")
	check(cam.cull_mask & hidden_bit != 0, "the chase view draws the pilot head again")
	check(cam.pitch >= cam.pitch_min - 0.001 and cam.pitch <= cam.pitch_max + 0.001, "chase pitch range restored")
	var to_cam := cam.global_position - td.mech.global_position
	check(to_cam.dot(td.mech.up()) > 2.0 and to_cam.dot(cam.look_dir) < 0.0, "camera back behind and above the mech")
	td.queue_free()
	await frames(1)
	finish()


func _meshes(n: Node) -> Array[VisualInstance3D]:
	var out: Array[VisualInstance3D] = []
	if n is GeometryInstance3D:
		out.append(n as VisualInstance3D)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
