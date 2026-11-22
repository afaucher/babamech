extends TestCase
## VISUAL: the neck seal (docs/design/pilot-heads.md section 4), run with
## `.\test_runner.ps1 -Visual -TestName test_pilot_neck_visual`. The duck and the chicken on a mech, frozen in the worst
## neck poses tests/test_pilot_neck_seal.gd measures (full acceleration lean, the stop, focused + a hit from behind, the
## landing squash, a hard look down), each from a low front three-quarter camera, from behind / above (side-rear: the back mounts hide the neck from
## straight behind) and from below the rim in front. Shots: test_logs/shots/pilot_neck_<head>_<pose>_<front|back|low>.png. Look for: the neck always goes down into the hatch, no
## gap between neck and collar showing light, no view into a hollow neck. A standalone shot of each head
## (pilot_neck_<head>_standalone) shows the collar plug as a neck base.

const VISUAL := true
const DT := 1.0 / 60.0

var sc: ShotCheck


func setup() -> void:
	timeout_sec = 180.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_pilot_neck_visual needs a renderer: run .\\test_runner.ps1 -Visual -TestName test_pilot_neck_visual")
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
	var cam := Camera3D.new()
	cam.fov = 24.0
	add_child(cam)
	cam.current = true
	for id: String in ["duck", "chicken"]:
		var m := MechModel.new()
		m.configure(id, "strider", {})
		add_child(m)
		await frames(2)
		m.set_process(false)
		var p := m.pilot
		p.set_process(false)
		p.idle_enabled = false
		p.idle_always = false
		p.fx_enabled = false
		var seat := m.find_child("Cockpit", true, false) as Node3D
		for pose: String in ["accel", "stop", "focused_hit", "landing", "look_down_side"]:
			p.neck.reset()
			p.clear_mood()
			p.clear_look()
			_feed(p, 1.0, {})
			_pose(p, pose)
			var c := seat.global_position
			var head := c + Vector3(0, 0.45, 0)
			cam.global_position = c + Vector3(2.3, -0.35, -4.2)
			cam.look_at(head)
			await frames(2)
			sc.not_blank(await sc.grab("pilot_neck_%s_%s_front" % [id, pose]), Rect2(0.2, 0.2, 0.6, 0.6), "%s %s" % [id, pose])
			cam.global_position = c + Vector3(-4.4, 3.2, 1.6)
			cam.look_at(c + Vector3(0, 0.35, 0))
			await frames(2)
			sc.not_blank(await sc.grab("pilot_neck_%s_%s_back" % [id, pose]), Rect2(0.2, 0.2, 0.6, 0.6), "%s %s" % [id, pose])
			cam.global_position = c + Vector3(-1.2, -0.9, -4.6)
			cam.look_at(c + Vector3(0, 0.2, 0))
			await frames(2)
			sc.not_blank(await sc.grab("pilot_neck_%s_%s_low" % [id, pose]), Rect2(0.2, 0.2, 0.6, 0.6), "%s %s" % [id, pose])
		m.queue_free()
		await frames(1)
		# Standalone: the collar plug as the neck's base (lab / crew panel view, a little below eye level).
		var h := PilotHead.make(id, 0)
		h.idle_enabled = false
		h.set_process(false)
		add_child(h)
		h.global_position = Vector3(20, 0, 0)
		cam.global_position = h.global_position + Vector3(2.6, 0.2, -4.6)
		cam.look_at(h.global_position + Vector3(0, 0.45, 0))
		await frames(2)
		sc.not_blank(await sc.grab("pilot_neck_%s_standalone" % id), Rect2(0.2, 0.2, 0.6, 0.6), "%s standalone" % id)
		h.queue_free()
		await frames(1)
	finish()


func _pose(p: PilotHead, pose: String) -> void:
	match pose:
		"accel":
			_feed(p, 0.25, {"vel": Vector3.FORWARD * 25.0})
		"stop":
			_feed(p, 0.7, {"vel": Vector3.FORWARD * 25.0})
			_feed(p, 0.22, {})
		"focused_hit":
			p.set_mood("focused")
			_feed(p, 1.5, {})
			p.react_hit(Vector3.BACK, 1.0)
			_feed(p, 0.12, {"vel": Vector3.FORWARD * 25.0})
		"landing":
			_feed(p, 0.3, {"grounded": false, "vel": Vector3(0, -20, 0)})
			_feed(p, 0.1, {"grounded": true})
		"look_down_side":
			p.look_at_point(p.global_transform * Vector3(-30, -40, -10))
			_feed(p, 0.6, {"vel": Vector3.RIGHT * 25.0})


func _feed(p: PilotHead, secs: float, state: Dictionary) -> void:
	for i in int(round(secs / DT)):
		p.feed(DT, state)
