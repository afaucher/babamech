extends TestCase
## The test drive builds a city, spawns the mech on the avenue, and the mech walks under driven input with the chase
## camera behind and above it; the HUD fills the screen; a new seed rebuilds and respawns.


func setup() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(10)
	check(td.city.plan != null and td.city.plan.buildings.size() > 10, "a city was generated")
	var ring := td.city.ring
	var h0 := ring.height(td.mech.global_position)
	check(absf(h0) < 1.5, "mech spawned on the street (height %.2f)" % h0)
	check(td.mech.max_step_up > 0.3, "step-up set from the leg geometry")
	td.drive_override = true
	var start := ring.world_to_arc(td.mech.global_position)
	for i in 180:
		td.mech.move_input = Vector2(0, 1)
		td.mech.running = i > 60
		td.mech.turn_input = 0.0
		await get_tree().physics_frame
	var end := ring.world_to_arc(td.mech.global_position)
	check(absf(end.y - start.y) + absf(end.x - start.x) > 15.0, "mech walked along the avenue (%.1f m)" % (absf(end.y - start.y)))
	var down := td.mech.grounded()
	for i in 30:   # at run speed a crest in the street can lift it off for a moment: it must be back down soon
		if down:
			break
		await get_tree().physics_frame
		down = td.mech.grounded()
	check(down, "still on the ground")
	await frames(2)
	# Camera: behind (opposite the look direction) and above the mech.
	var up := td.mech.up()
	var to_cam := td.cam.global_position - td.mech.global_position
	check(to_cam.dot(up) > 2.0, "camera above the mech")
	check(to_cam.dot(td.cam.look_dir) < 0.0, "camera behind the mech")
	# Mouse look turns the camera, and the mech follows it.
	td.drive_override = false
	td.cam.add_mouse(Vector2(400, 0))
	check(td.cam.yaw_error() > 0.3, "camera yawed right of the mech")
	for i in 120:
		await get_tree().physics_frame
	check(absf(td.cam.yaw_error()) < 0.1, "mech turned to face the look direction (%.2f rad off)" % td.cam.yaw_error())
	# HUD layout: its root fills the viewport.
	var root := td.get_node("Hud/HudRoot") as Control
	var vp := get_viewport().get_visible_rect().size
	check(root.size.x >= vp.x - 1.0 and root.size.y >= vp.y - 1.0, "HUD fills the screen (%s vs %s)" % [root.size, vp])
	eq(MechAccent.applied(td.rig.model), Session.local_accent(), "the driven mech wears the player's accent")
	# The mech HUD found its sources and shows one row per hardpoint from the weapon rack.
	var mh := td.get_node("MechHud") as MechHud
	check(mh != null and mh.mech == td.mech and mh.rack == td.combat.rack and mh.camera == td.cam, "the mech HUD is bound")
	eq(mh.rows.size(), td.combat.rack.slots().size(), "the mech HUD has a row per weapon slot")
	near(float(mh.heat()["fraction"]), td.mech.heat / td.mech.heat_cap, 0.001, "the mech HUD reads the mech's heat")
	# Full-speed strafe, RMB camera zoom, and depth-tested 3D world aim markers.
	near(td.mech.strafe_scale, 1.0, 0.001, "strafe speed matches forward walk/run speed")
	check(mh.world_aim != null and mh.world_aim._aim_root.visible, "3D WorldAimMarkers active in live TestDrive")
	var aim_mat := mh.world_aim._aim_ring.material_override as StandardMaterial3D
	check(aim_mat != null and not aim_mat.no_depth_test, "3D WorldAimMarkers are depth-tested (occluded by cover)")
	td.drive_override = true
	var fov0 := td.cam.fov
	td.cam.zoomed = true
	await frames(20)
	check(td.cam.fov < fov0 - 15.0 and td.cam.zoom_amount > 0.5, "RMB zoom narrows camera FOV (%.1f -> %.1f)" % [fov0, td.cam.fov])
	td.cam.zoomed = false
	# Ceiling collision: thrust straight up into the 40 m ceiling -> neither mech head nor camera penetrates it.
	var ceil_h := td.city.plan.p("ceiling")
	td.mech.heat_cap = 10000.0
	td.mech.move_input = Vector2.ZERO
	td.mech.thrust_input = true
	for _i in 240:
		await get_tree().physics_frame
	var mech_top := ring.height(td.mech.global_position) + 8.0
	var cam_h := ring.height(td.cam.global_position)
	check(mech_top <= ceil_h + 0.5, "mech stops cleanly at ceiling (top %.2f m vs %.1f m)" % [mech_top, ceil_h])
	check(cam_h < ceil_h - 0.1, "ChaseCamera stays strictly below ceiling (%.2f m vs %.1f m)" % [cam_h, ceil_h])
	td.mech.thrust_input = false
	# New city.
	var cs := td.city.plan.checksum()
	td.build_city(td.seed_value + 1)
	await frames(3)
	check(td.city.plan.checksum() != cs, "a new seed builds a different city")
	check(absf(ring.height(td.mech.global_position)) < 1.5, "respawned on the street")
	td.queue_free()
	await frames(1)
	finish()
