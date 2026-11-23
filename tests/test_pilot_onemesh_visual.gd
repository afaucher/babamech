extends TestCase
## VISUAL: a TEAMMATE'S pilot head is one continuous mesh (docs/design/pilot-heads.md section 2, "One mesh"; user bug
## 2026-11-22 "you can see a neck seam when the head moves around in multiplayer on the other player"). Run with
## `.\test_runner.ps1 -Visual -TestName test_pilot_onemesh_visual`.
## Each head sits on a real puppet mech, driven exactly as on a teammate's machine minus the socket: MechSpawn mech +
## MechPuppet (owned by peer 2) fed NetMechStates through MechPuppet.apply at the 30 Hz send rate (a new state every other
## 60 Hz physics frame, not interpolated: the steppiest input a puppet can get), the real MechRig feeding the head and a
## PilotPuppetLink (stream flinches, the designator look). At each pose the puppet is frozen and shot close up on the
## neck from a teammate's front three-quarter view (and in profile, "_side", and from above behind the shoulder, "_high"):
##   turn      mid-turn at 2.5 rad/s with the designator on, looking hard to the side
##   flinch    0.1 s after a streamed left-leg drop of 50 % (flinch away + look toward), while running
##   lean      0.2 s after a full-run stop, focused (designator), with a back hit stacked
##   teleport  2 frames after a respawn jump (position + heading flip, velocity reset)
## Shots: test_logs/shots/pilot_onemesh_<head>_<pose>[_side|_high].png. Look for: neck and skull one surface, no crack, step or
## light between the neck rings, no edge of one piece standing proud of another.

const VISUAL := true
const STEP := 2                    ## physics frames per streamed state (60 Hz / 30 Hz)

var sc: ShotCheck
var cam: Camera3D
var st := NetMechState.new()


func setup() -> void:
	timeout_sec = 240.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_pilot_onemesh_visual needs a renderer: run .\\test_runner.ps1 -Visual -TestName test_pilot_onemesh_visual")
		finish()
		return
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)
	cam = Camera3D.new()
	cam.fov = 26.0
	add_child(cam)
	cam.current = true
	var world := CombatWorld.new()
	world.use_physics = false
	add_child(world)
	for id: String in PilotHead.ids():
		await _head(id, world)
	finish()


func _head(id: String, world: CombatWorld) -> void:
	var mech := MechSpawn.make(id, "strider", {}, 2, "red")
	add_child(mech)
	await frames(1)
	var pp := MechPuppet.new()
	pp.name = "Puppet"
	pp.bind(mech, 2)
	mech.add_child(pp)
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, pp.rig.model, "player2", 2)
	world.register(pt)
	pp.target = pt
	var link := PilotPuppetLink.new()
	link.name = "PilotLink"
	mech.add_child(link)
	link.bind_puppet(pp, world)
	for pose: String in ["turn", "flinch", "lean", "teleport"]:
		st = NetMechState.new()
		st.yaw = PI
		st.grounded = true
		st.comp = _comp(pt, {})
		await _run(pp, 90, func(_i: int) -> void: pass)
		var h := link.pilot()
		h.idle_enabled = false
		h.fx_enabled = false
		h.neck.reset()
		await _run(pp, 30, func(_i: int) -> void: pass)
		match pose:
			"turn":
				st.designator = true
				await _run(pp, 50, func(i: int) -> void:
					st.yaw = PI + 2.5 * float(i) / 60.0
					st.aim = st.pos + Vector3(-60.0, 2.0, 10.0))
			"flinch":
				await _run(pp, 40, func(_i: int) -> void: st.vel = Vector3(0, 0, -22.0))
				st.comp = _comp(pt, {"leg_l": 0.5})
				await _run(pp, 6, func(_i: int) -> void: st.vel = Vector3(0, 0, -22.0))
			"lean":
				st.designator = true
				st.aim = st.pos + Vector3(0, 0, -80)
				await _run(pp, 60, func(_i: int) -> void: st.vel = Vector3(0, 0, -22.0))
				st.vel = Vector3.ZERO
				h.react_hit(Vector3.BACK, 0.4)
				await _run(pp, 12, func(_i: int) -> void: pass)
			"teleport":
				await _run(pp, 40, func(_i: int) -> void: st.vel = Vector3(0, 0, -22.0))
				st.pos += Vector3(30, 0, 30)
				st.yaw = 0.0
				st.vel = Vector3.ZERO
				st.tp = (st.tp + 1) % 16
				await _run(pp, 2, func(_i: int) -> void: pass)
		_freeze(mech, pp, link, h, false)
		for view: String in ["front", "side", "high"]:
			_frame(h, mech, view)
			await frames(2)
			var shot := "pilot_onemesh_%s_%s" % [id, pose] + ("" if view == "front" else "_" + view)
			sc.not_blank(await sc.grab(shot), Rect2(0.2, 0.2, 0.6, 0.6), "%s %s %s" % [id, pose, view])
		_freeze(mech, pp, link, h, true)
		st.designator = false
	link.unbind()
	world.unregister(pt)
	pt.queue_free()
	mech.queue_free()
	await frames(2)


## n physics frames, a new streamed state every STEP frames (`f(i)` edits it first).
func _run(pp: MechPuppet, n: int, f: Callable) -> void:
	for i in n:
		if i % STEP == 0:
			f.call(i)
			st.pos += st.vel * float(STEP) / 60.0
			pp.apply(st)
			pp.shown = st
			if pp.target != null:
				pp.target.global_transform = pp.mech.global_transform
				pp.target.up = pp.mech.up()
		await get_tree().physics_frame


func _freeze(mech: MechController, pp: MechPuppet, link: PilotPuppetLink, h: PilotHead, on: bool) -> void:
	pp.rig.set_physics_process(on)
	pp.set_physics_process(on)
	link.set_physics_process(on)
	mech.set_physics_process(on)
	h.set_process(on)


## A teammate's view, close on the neck: "front" three-quarter a little below the head, "side" in profile from the
## mech's right, "high" from above and behind the shoulder (looking down the neck into the hatch).
func _frame(h: PilotHead, mech: MechController, view: String) -> void:
	var s := h.global_basis.get_scale().x
	var neck := h.global_transform * Vector3(0, 0.4, 0)
	var b := mech.global_basis.orthonormalized()
	var dir := Vector3(1.5, -0.15, -2.2)
	match view:
		"side":
			dir = Vector3(2.0, 0.25, -0.3)
		"high":
			dir = Vector3(1.2, 1.6, 1.0)
	cam.global_position = neck + b * dir.normalized() * 3.6 * s
	cam.look_at(neck, mech.up())


func _comp(pt: PlayerTarget, over: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for c: String in NetMechCodec.COMPONENTS:
		out.append(float(over.get(c, 1.0)) if pt.max_hp.has(c) else -1.0)
	return out
