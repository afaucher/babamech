extends TestCase
## VISUAL: enemy animation frame strips (docs/design/enemy-anim/): a strider and a trooper walking past a fixed camera
## over a 1 m grid (planted feet stay on their grid squares), a stagger sequence (hit, stumble, recovery, rest) for the
## strider and the trooper, and the trooper standing vs crouched (rifle and AT kits). Runs only under
## `.\test_runner.ps1 -Visual -TestName test_visual_enemy_anim`; shots go to test_logs/shots/enemy_anim_*.png.

const VISUAL := true
const DT := 1.0 / 60.0

var sc: ShotCheck
var cam: Camera3D
var world: CombatWorld


func setup() -> void:
	timeout_sec = 240.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_enemy_anim needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	_stage()
	await _walk_strip("strider", 9.5, Vector3(0.0, 2.6, 10.5), 2.2, 0.1, "strider_walk")
	await _walk_strip("trooper_rifle", 5.0, Vector3(0.0, 1.0, 4.6), 0.9, 0.07, "trooper_walk")
	await _stagger_strip("strider", Vector3(-11.0, 4.0, 5.0), Vector3(0.0, 2.4, 0.0), "strider_stagger")
	await _stagger_strip("trooper_rifle", Vector3(-4.6, 1.7, 2.2), Vector3(0.0, 1.0, 0.0), "trooper_stagger")
	await _crouch_pair()
	finish()


func _stage() -> void:
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
	sun.shadow_enabled = true
	add_child(sun)
	# Floor with a 1 m grid: planted feet visibly stay on their squares from frame to frame.
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80.0, 80.0)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.62, 0.6, 0.56)
	floor_mi.material_override = fm
	add_child(floor_mi)
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.36, 0.35, 0.33)
	for i in range(-40, 41):
		for axis in 2:
			var b := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(80.0, 0.01, 0.03) if axis == 0 else Vector3(0.03, 0.01, 80.0)
			b.mesh = bm
			b.material_override = lm
			b.position = Vector3(0.0, 0.005, float(i)) if axis == 0 else Vector3(float(i), 0.005, 0.0)
			add_child(b)
	cam = Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.current = true
	world = CombatWorld.new()
	world.mission_seed = 42
	add_child(world)


func _spawn(type_id: String, id: String, puppet: bool, at: Vector3, yaw: float) -> EnemyBase:
	var e: EnemyBase
	if type_id.begins_with("strider"):
		e = EnemyStrider.new()
	else:
		e = EnemyTrooper.new()
		(e as EnemyTrooper).force_rig = true
	e.configure(type_id, id, world, null, null, 7)
	e.puppet = puppet
	e.ai_mode = "idle"
	e.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	add_child(e)
	world.register(e)
	return e


## A puppet walking along +X past a fixed side camera: 6 frames `gap` s apart.
func _walk_strip(type_id: String, speed: float, cam_off: Vector3, look_y: float, gap: float, tag: String) -> void:
	var e := _spawn(type_id, tag, true, Vector3(-3.0 * speed * gap, 0.0, 0.0), -PI * 0.5)
	await frames(2)
	for _i in 60:   # get into stride before the strip starts
		e.global_position += Vector3(speed * DT, 0.0, 0.0)
		e.puppet_tick(DT)
	var mid := e.global_position + Vector3(speed * gap * 2.5, 0.0, 0.0)
	cam.look_at_from_position(mid + cam_off, mid + Vector3(0.0, look_y, 0.0), Vector3.UP)
	var per := maxi(int(round(gap / DT)), 1)
	for n in 6:
		var img := await sc.grab("enemy_anim_%s_%d" % [tag, n])
		sc.not_blank(img, Rect2(0.1, 0.1, 0.8, 0.8), "%s frame %d" % [tag, n])
		for _i in per:
			e.global_position += Vector3(speed * DT, 0.0, 0.0)
			e.puppet_tick(DT)
	e.queue_free()
	await frames(2)


## A host unit knocked back and to its right: hit, stumble, recovery, rest (the camera follows it; the grid shows the
## knockback slide and the stumble steps).
func _stagger_strip(type_id: String, cam_off: Vector3, look_off: Vector3, tag: String) -> void:
	var e := _spawn(type_id, tag, false, Vector3.ZERO, 0.0)
	await frames(2)
	for _i in 90:
		world.advance(DT)
	var p := e.global_position
	cam.look_at_from_position(p + cam_off, p + look_off, Vector3.UP)
	var img0 := await sc.grab("enemy_anim_%s_0" % tag)
	sc.not_blank(img0, Rect2(0.1, 0.1, 0.8, 0.8), "%s before" % tag)
	e.apply_impulse(e.global_basis * Vector3(3.5, 0.0, 7.5), "visual")
	var t := 0.0
	var marks := [0.05, 0.18, 0.33, 0.45, 0.54, 0.9]
	for n in marks.size():
		while t < float(marks[n]):
			world.advance(DT)
			t += DT
		var q := e.global_position
		cam.look_at_from_position(q + cam_off, q + look_off, Vector3.UP)
		var img := await sc.grab("enemy_anim_%s_%d" % [tag, n + 1])
		sc.not_blank(img, Rect2(0.1, 0.1, 0.8, 0.8), "%s at %.2f s" % [tag, t])
	e.queue_free()
	await frames(2)


## Rifle and AT troopers, each standing (peeking: stepped forward) beside a crouched twin, seen in profile (facing -X).
func _crouch_pair() -> void:
	var units: Array[EnemyTrooper] = []
	var z := 0.0
	for kit: String in ["trooper_rifle", "trooper_at"]:
		var x := -1.0
		for crouch in 2:
			var e := _spawn(kit, "%s_pose_%d" % [kit, crouch], true, Vector3(x, 0.0, z), PI * 0.5) as EnemyTrooper
			e.set_puppet_aim(Vector2(0.0, 0.0 if crouch == 1 else 1.0))
			units.append(e)
			x += 2.4
		z -= 30.0
	await frames(2)
	for _i in 90:
		for e in units:
			e.puppet_tick(DT)
	var n := 0
	for kz: float in [0.0, -30.0]:
		var kit_tag := "rifle" if n == 0 else "at"
		cam.look_at_from_position(Vector3(0.0, 1.3, kz + 5.4), Vector3(0.0, 1.0, kz), Vector3.UP)
		var img := await sc.grab("enemy_anim_trooper_%s_stand_crouch" % kit_tag)
		sc.not_blank(img, Rect2(0.1, 0.1, 0.8, 0.8), "%s standing vs crouched, profile" % kit_tag)
		cam.look_at_from_position(Vector3(-4.0, 1.6, kz + 3.6), Vector3(0.0, 0.9, kz), Vector3.UP)
		var img2 := await sc.grab("enemy_anim_trooper_%s_stand_crouch_34" % kit_tag)
		sc.not_blank(img2, Rect2(0.1, 0.1, 0.8, 0.8), "%s standing vs crouched, 3/4" % kit_tag)
		n += 1
	for e in units:
		e.queue_free()
	await frames(2)
