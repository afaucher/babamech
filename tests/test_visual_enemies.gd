extends TestCase
## VISUAL: enemy silhouettes, scale vs. 8 m player mech, palette contrast in sunlit city, active telegraphs,
## and Test Drive rooftop overview looking down onto occupied streets/parks (50-120 m visibility check).
## Runs only under `.\test_runner.ps1 -Visual`.

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_enemies needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.68, 0.80, 0.90)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.95, 0.92, 0.86)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 32, 0)
	sun.light_energy = 1.25
	add_child(sun)

	# 1. Showcase lineup: 8 m player mech beside Skirmisher, Turret, and Siege Tank.
	var lab := EnemyLab.new()
	add_child(lab)
	var cam := Camera3D.new()
	cam.fov = 52.0
	add_child(cam)
	cam.current = true
	await frames(8)
	lab.set_lab_option("debug_overlay", "off")
	cam.look_at_from_position(Vector3(2.0, 9.5, 23.0), Vector3(1.0, 3.2, 0.0), Vector3.UP)
	await frames(10)
	var img_show := await sc.grab("enemies_showcase")
	sc.not_blank(img_show, Rect2(0.05, 0.1, 0.9, 0.8), "enemies showcase lineup")

	# 1b. Close-up hitbox overlay check (hit spheres aligned against meshes).
	lab.set_lab_option("debug_overlay", "on")
	cam.look_at_from_position(Vector3(4.0, 7.5, 19.0), Vector3(4.0, 3.0, 0.0), Vector3.UP)
	await frames(8)
	var img_hb := await sc.grab("enemies_hitboxes")
	sc.not_blank(img_hb, Rect2(0.05, 0.1, 0.9, 0.8), "enemies hitbox alignment overlay")

	# 1c. Live damage states: turret overheated & drooping, skirmisher damaged & staggered, tank with turret blown off.
	lab.set_lab_option("debug_overlay", "off")
	for en in lab.squad.enemies:
		if en.enemy_type == "turret":
			en.apply_heat(80.0, "visual")
		elif en.enemy_type == "strider":
			en.apply_damage(25.0, "chassis", "visual")
			en.apply_impulse(Vector3(0.0, 0.0, -7.0), "visual")
		elif en.enemy_type == "tank":
			en.apply_damage(80.0, "turret", "visual")
	for _i in 12:
		await get_tree().physics_frame
	cam.look_at_from_position(Vector3(3.5, 8.0, 21.0), Vector3(3.5, 3.0, 0.0), Vector3.UP)
	await frames(6)
	var img_dmg := await sc.grab("enemies_damage_states")
	sc.not_blank(img_dmg, Rect2(0.05, 0.1, 0.9, 0.8), "enemies live damage states")

	# 1d. Persistent wrecks, turret toss, hull flames & ember scorch: reset showcase, blow up Tank & Skirmisher.
	lab._rebuild()
	await frames(4)
	for en in lab.squad.enemies:
		if en.enemy_type == "tank":
			var th := Hit.new()
			th.damage = 250.0
			th.component = "vents"
			th.impulse = Vector3(-5.0, 0.0, 6.0)
			th.shooter = "visual"
			en.apply_hit(th)
		elif en.enemy_type == "strider":
			var sh := Hit.new()
			sh.damage = 120.0
			sh.component = "sensor"
			sh.impulse = Vector3(3.0, 0.0, 5.0)
			sh.shooter = "visual"
			en.apply_hit(sh)
	# Step ~1.5 s so tossed tank turret and severed strider parts bounce & settle nearby while flames & ember scorch roar.
	for _i in 90:
		lab.step(1.0 / 60.0)
	# Fresh nearby ground blast so the upgraded glowing ember polygon + rubble pebbles read crisply in foreground.
	lab.world.spawn_impact(Vector3(4.0, 0.2, 5.5), Vector3.UP, 3.8, CityPalette.c("asphalt"), true)
	lab.world.advance(0.18)
	cam.look_at_from_position(Vector3(4.5, 10.5, 22.5), Vector3(4.5, 2.4, 0.5), Vector3.UP)
	await frames(4)
	var img_wrecks := await sc.grab("enemies_wrecks")
	sc.not_blank(img_wrecks, Rect2(0.05, 0.1, 0.9, 0.8), "enemies persistent wrecks, turret toss, flames & ember scorch")

	# 2. Skirmish view: active squad, rooftop turret, telegraphs & projectiles + debug overlay off.
	lab.set_lab_option("preset", "skirmish")
	lab.set_lab_option("ai_mode", "live")
	lab.set_lab_option("debug_overlay", "off")
	cam.look_at_from_position(Vector3(26.0, 18.0, 18.0), Vector3(-2.0, 4.0, -32.0), Vector3.UP)
	for _i in 65:
		await get_tree().physics_frame
	var img_skirm := await sc.grab("enemies_skirmish")
	sc.not_blank(img_skirm, Rect2(0.05, 0.1, 0.9, 0.8), "enemies skirmish combat")

	lab.queue_free()
	cam.queue_free()
	sun.queue_free()
	env.queue_free()
	await frames(4)

	# 3. Test Drive rooftop vantage looking down the occupied avenue (matches user screenshot perspective).
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(12)
	td.drive_override = true
	var ring := td.city.ring
	var roof_cam := Camera3D.new()
	roof_cam.fov = 60.0
	add_child(roof_cam)
	roof_cam.current = true
	var from := ring.arc_to_world(-14.0, 14.0, 18.0)
	var look_at_pt := ring.arc_to_world(0.0, 62.0, 3.0)
	roof_cam.look_at_from_position(from, look_at_pt, ring.up_at(from))
	await frames(12)
	var img_city := await sc.grab("enemies_test_drive_rooftop")
	sc.not_blank(img_city, Rect2(0.05, 0.1, 0.9, 0.8), "enemies in sunlit Test Drive city from rooftop")
	roof_cam.queue_free()
	td.queue_free()
	await frames(2)
	finish()
