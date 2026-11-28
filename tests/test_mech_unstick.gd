extends TestCase
## The stuck guard (playtest R2.25b, MechController._stuck_guard / _nudge): pushing without moving for about a second
## nudges the mech free, collision-checked (never into or through geometry), owner-side and deterministic. Flat world
## (+Y up, gravity 22), real mechs (MechSpawn.make), physics frames only.
## Cases that must get free (a nudge that moves the body within 1.5 s of being stuck, no overlap after it, the body on the
## open side of every wall face the whole time):
##  (a) a Strider walking into the apex of a V of two walls;
##  (b) a Strider walking into a doorway narrower than its capsule (3 m gap, capsule 4.4 m across);
##  (c) a ledge lip: a Strider walking diagonally along a wall into a 1.5 m lip block jutting from it across its path (taller
##      than its step-up, so a wall to its legs; with the wall it makes an inside corner);
##  (d) a Bulwark (r 3.6) walking diagonally into an inside corner;
##  (e) a hovering Wasp pushing forward and up into a recess (an overhang slab over it, a wall at the back).
## Cases that must NOT fire: walking head-on into a flat wall (3 s), standing idle (3 s), a Wasp climbing into a flat
## ceiling (3 s), and the Strider's 1.6 m step still blocks it (test_chassis_movement). Determinism: case (a) twice gives
## the same path; at 30 / 60 / 120 Hz it gets free at about the same time.

var _bodies: Array[Node] = []


func _init() -> void:
	timeout_sec = 300.0


func _box(center: Vector3, size: Vector3, yaw: float = 0.0) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.transform = Transform3D(Basis(Vector3.UP, yaw), center)
	add_child(body)
	_bodies.append(body)


func _clear() -> void:
	for b in _bodies:
		b.free()
	_bodies.clear()


func _dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


func setup() -> void:
	var strider := MechSpawn.make("chicken", "strider", {}, 1)
	add_child(strider)
	var bulwark := MechSpawn.make("chicken", "bulwark", {}, 2)
	add_child(bulwark)
	var wasp := MechSpawn.make("chicken", "wasp", {}, 3, "", true)
	add_child(wasp)
	for m: MechController in [strider, bulwark, wasp]:
		m.global_position = Vector3(0, -500, 0)   # parked under the world (no floor there yet: they fall, unused)
	await frames(2)
	# (a) V.
	var a1 := await _case_v(strider)
	_report("a V apex (Strider)", a1)
	# Determinism: the same push twice in a row (Godot's contact solver leaves mm-level differences in where the capsule
	# rests against the walls, so the end is compared to 2 cm; the stuck rule and the nudges themselves have no randomness).
	var a2 := await _case_v(strider)
	var a3 := await _case_v(strider)
	check(absf(float(a2["freed"]) - float(a3["freed"])) < 0.02 and a2["nudges"] == a3["nudges"]
		and (a2["end"] as Vector3).distance_to(a3["end"]) < 0.02,
		"deterministic: the same push twice frees at the same moment with the same nudges (%.3f / %.3f s, %d / %d, ends %s / %s)" % [
		a2["freed"], a3["freed"], a2["nudges"], a3["nudges"], str(a2["end"]), str(a3["end"])])
	# (b) Doorway.
	_report("b doorway 3 m (Strider)", await _case(strider, [[Vector3(-6.5, 4, -10), Vector3(10, 8, 2)],
		[Vector3(6.5, 4, -10), Vector3(10, 8, 2)]], [[Vector3(0, 0, -9), Vector3(0, 0, 1)]], Vector3(0, 0, 0), Vector2(0, 1)))
	# (c) Ledge lip: a wall along x = -6 and a 1.5 m lip block jutting from it at z = -10.
	_report("c ledge lip (Strider)", await _case(strider, [[Vector3(-6.5, 4, -10), Vector3(1, 8, 40)],
		[Vector3(-4.0, 0.75, -10.5), Vector3(4, 1.5, 1)]],
		[[Vector3(-6, 0, 0), Vector3(1, 0, 0)], [Vector3(0, 0, -10), Vector3(0, 0, 1)]], Vector3(-3, 0, 0),
		Vector2(-0.45, 0.9)))
	# (d) Bulwark in a corner.
	_report("d corner (Bulwark)", await _case(bulwark, [[Vector3(0, 4, -10.5), Vector3(40, 8, 1)],
		[Vector3(-10.5, 4, 0), Vector3(1, 8, 40)]],
		[[Vector3(0, 0, -10), Vector3(0, 0, 1)], [Vector3(-10, 0, 0), Vector3(1, 0, 0)]], Vector3(0, 0, 0),
		Vector2(-0.707, 0.707)))
	# (e) Wasp into a recess: slab underside at 7 m over z -20..-10, back wall at z -20.
	_report("e recess (Wasp)", await _case(wasp, [[Vector3(0, 7.5, -15), Vector3(20, 1, 10)],
		[Vector3(0, 5, -20.5), Vector3(20, 10, 1)]],
		[[Vector3(0, 0, -20), Vector3(0, 0, 1)], [Vector3(0, 7.0 - 2.2, -15), Vector3(0, -1, 0), -10.0]], Vector3(0, 1.5, -12),
		Vector2(0, 1), 1.0))
	# Must not fire.
	var flat := await _case(strider, [[Vector3(0, 4, -10.5), Vector3(40, 8, 1)]], [[Vector3(0, 0, -10), Vector3(0, 0, 1)]],
		Vector3(0, 0, 0), Vector2(0, 1), 0.0, 3.0, false)
	eq(int(flat["nudges"]), 0, "walking head-on into a flat wall for 3 s: no nudge")
	check(float(flat["stuck_at"]) >= 0.0, "(it did reach the wall and stop)")
	var idle := await _case(strider, [], [], Vector3(0, 0, 0), Vector2.ZERO, 0.0, 3.0, false)
	eq(int(idle["nudges"]), 0, "standing idle: no nudge")
	var ceil := await _case(wasp, [[Vector3(0, 7.5, 0), Vector3(30, 1, 30)]], [[Vector3(0, 7.0 - 2.2, 0), Vector3(0, -1, 0)]],
		Vector3(0, 1.0, 0), Vector2.ZERO, 1.0, 3.0, false)
	eq(int(ceil["nudges"]), 0, "a Wasp climbing into a flat ceiling: no nudge")
	# Step rates.
	var ticks := Engine.physics_ticks_per_second
	var at := {}
	for hz: int in [30, 60, 120]:
		Engine.physics_ticks_per_second = hz
		await frames(3)
		at[hz] = await _case_v(strider)
		print("[unstick rate] %3d Hz: stuck at %.2f s, freed at %.2f s, end %s" % [hz, at[hz]["stuck_at"], at[hz]["freed"],
			str(at[hz]["end"])])
	Engine.physics_ticks_per_second = ticks
	await frames(3)
	for hz: int in [30, 120]:
		near(float(at[hz]["freed"]) - float(at[hz]["stuck_at"]), float(at[60]["freed"]) - float(at[60]["stuck_at"]), 0.1,
			"%d Hz frees after the same time stuck as 60 Hz" % hz)
	finish()


func _case_v(m: MechController) -> Dictionary:
	# Two 20 m walls at +-45 deg meeting at (0, 0, -10), the V opening toward the mech at the origin.
	var apex := Vector3(0, 0, -10)
	var walls: Array = []
	var planes: Array = []
	for s: float in [-1.0, 1.0]:
		var d := Vector3(s * 0.7071, 0, 0.7071)
		var n := Vector3(-s * 0.7071, 0, 0.7071)
		var c := apex + d * 10.0 - n * 0.5 + d * 0.5
		walls.append([c + Vector3(0, 4, 0), Vector3(1, 8, 21), s * PI * 0.25])
		planes.append([c + n * 0.5, n])
	return await _case(m, walls, planes, Vector3(0, 0, 0), Vector2(0, 1))


## Build `walls` ([centre, size, yaw?]) on a floor, put `m` at `start` facing -Z (landed for a Wasp unless `climb` > 0),
## push `input` (and `climb`) for `secs`. `planes` ([point, normal toward the open side]) must keep the capsule's axis on
## their open side (a third element: only while the body's z is below it). {stuck_at: s of the first stuck step (slow while pushing; -1 none), freed: s of the first nudge that
## moved it (-1 none), nudges, end}. With `expect_free` it asserts the nudge, its timing and that nothing overlaps after.
func _case(m: MechController, walls: Array, planes: Array, start: Vector3, input: Vector2, climb: float = 0.0,
		secs: float = 4.0, expect_free: bool = true) -> Dictionary:
	_clear()
	_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	for w: Array in walls:
		_box(w[0], w[1], float(w[2]) if w.size() > 2 else 0.0)
	m.move_input = Vector2.ZERO
	m.climb_input = 0.0
	m.running = false
	m.turn_input = 0.0
	m.global_transform = Transform3D(Basis.IDENTITY, start)
	m.velocity = Vector3.ZERO
	m.reset_heat()
	m.heat = 0.0
	m.set_landed(climb <= 0.0 and start.y < 0.5)
	await frames(3)
	m.velocity = Vector3.ZERO
	var n0 := m.unstuck_count
	m.move_input = input
	m.climb_input = climb
	var t := 0.0
	var stuck_at := -1.0
	var freed := -1.0
	var crossed := ""
	var depth_after := 0.0
	var cap := ((m.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D)
	var prev := m.global_position
	for i in int(round(secs / _dt())):
		await get_tree().physics_frame
		t += _dt()
		m.heat = 0.0
		var p := m.global_position
		if stuck_at < 0.0 and t > 0.1 and (input.length() > 0.0 or climb != 0.0) \
				and (p - prev).length() / _dt() < 0.5:
			stuck_at = t
		if freed < 0.0 and m.unstuck_count > n0:
			freed = t
			depth_after = float(m._overlap(Vector3.ZERO)["depth"])
		for pl: Array in planes:
			if pl.size() > 2 and p.z > float(pl[2]):
				continue   # this face only counts while the body is over / under it (z below the bound)
			var n: Vector3 = pl[1]
			for k: float in [cap.radius, cap.height - cap.radius]:   # the capsule's axis ends
				if (p + Vector3.UP * k - (pl[0] as Vector3)).dot(n) < -0.05 and crossed == "":
					crossed = "past the face at %s (t %.2f, at %s)" % [str(pl[0]), t, str(p)]
		prev = p
	m.move_input = Vector2.ZERO
	m.climb_input = 0.0
	var r := {"stuck_at": stuck_at, "freed": freed, "nudges": m.unstuck_count - n0, "end": m.global_position,
		"crossed": crossed, "depth": depth_after}
	if expect_free:
		check(crossed == "", "%s: stays on the open side of every wall (%s)" % [m.chassis_id, crossed])
	return r


func _report(label: String, r: Dictionary) -> void:
	print("[unstick] %-24s stuck at %.2f s, freed at %.2f s (%d nudges), overlap after %.3f m, end %s %s" % [label,
		r["stuck_at"], r["freed"], r["nudges"], r["depth"], str(r["end"]), r["crossed"]])
	check(float(r["freed"]) > 0.0, "%s: nudged free" % label)
	check(float(r["stuck_at"]) < 0.0 or float(r["freed"]) - float(r["stuck_at"]) <= 1.5,
		"%s: within 1.5 s of being stuck (%.2f s)" % [label, float(r["freed"]) - float(r["stuck_at"])])
	check(float(r["depth"]) < 0.05, "%s: no overlap after the nudge (%.3f m)" % [label, r["depth"]])
	check(r["crossed"] == "", "%s: never beyond a wall face" % label)
