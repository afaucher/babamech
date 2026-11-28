extends TestCase
## The Wasp's hover branch of MechController (docs/design/wasp-hover.md section 1; build step 1). Flat world (+Y up,
## gravity 22), a real Wasp (MechSpawn.make(..., drafts = true)), real physics frames (the runner's fixed step; the
## step-rate section switches Engine.physics_ticks_per_second to 30 / 120 and back; nothing timed on the wall clock).
##  - catalog / hooks for all three chassis (can_fly, working_fans, altitude, headroom, grounded), the game gate (no
##    drafts: a Wasp request gives the Strider), the lab's defaults = the catalog's numbers;
##  - top speeds (cruise forward / strafe, boost), half-turn time, climb and descend rates, the drift stop distance;
##  - the height hold: over flat ground, over a 12 m block (rises before it, never touches its wall, comes back down,
##    bounded vertical accel, no oscillation), over a 30 m block (gets over it);
##  - no altitude cap (200 m in the open), stops under a slab without piling up speed, passes up and down through an
##    opening in it;
##  - landing and lift-off: ground, roof, a 20 deg ramp (lands, does not slide), a 60 deg face (never lands on it: slides
##    off and lands at its foot); landed it turns but does not move;
##  - heat: free hovering, move / boost / climb costs, cooling x1.5 landed;
##  - overheat at height: falls, hard_landing fires, lands, reboots, stays landed until climb input, flies again;
##  - the wedge guard (a falling Wasp jammed between two blocks);
##  - 30 / 60 / 120 Hz give the same top speed, stop distance, climb and hold within tolerance.
## Prints the movement table.

var _bodies: Array[Node] = []
var w: MechController


func _init() -> void:
	timeout_sec = 400.0


func _slab(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = center
	add_child(body)
	_bodies.append(body)
	return body


## A wedge whose low edge is on the floor at `o` (centre), rising `deg` toward -Z over `run` m of ground, `width` wide.
func _wedge_ramp(o: Vector3, width: float, run: float, deg: float) -> void:
	var hw := width * 0.5
	var h := run * tan(deg_to_rad(deg))
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([o + Vector3(-hw, 0, 0), o + Vector3(hw, 0, 0), o + Vector3(-hw, 0, -run),
		o + Vector3(hw, 0, -run), o + Vector3(-hw, h, -run), o + Vector3(hw, h, -run)])
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	_bodies.append(body)


func _dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


func _steps(sec: float) -> int:
	return int(round(sec / _dt()))


func _inputs(mv: Vector2 = Vector2.ZERO, climb: float = 0.0, run: bool = false, turn: float = 0.0) -> void:
	w.move_input = mv
	w.climb_input = climb
	w.running = run
	w.turn_input = turn


func _place(at: Vector3, landed: bool, yaw: float = 0.0) -> void:
	_inputs()
	w.global_transform = Transform3D(Basis(Vector3.UP, yaw), at)
	w.velocity = Vector3.ZERO
	w.reset_heat()
	w.heat = 0.0
	w.fans_alive = 2
	w.set_landed(landed)
	await frames(2)
	w.velocity = Vector3.ZERO


func setup() -> void:
	_slab(Vector3(0, -0.5, 0), Vector3(800, 1, 800))
	w = MechSpawn.make("chicken", "wasp", {}, 1, "", true)
	add_child(w)
	var strider := MechSpawn.make("chicken", "strider", {}, 2)
	add_child(strider)
	var bulwark := MechSpawn.make("chicken", "bulwark", {}, 3)
	add_child(bulwark)
	var gate := MechSpawn.make("chicken", "wasp", {}, 4)   # the game's path: no drafts
	add_child(gate)
	strider.global_position = Vector3(-350, 0, 350)
	bulwark.global_position = Vector3(-330, 0, 350)
	gate.global_position = Vector3(-310, 0, 350)
	w.global_position = Vector3(0, 0, 0)
	await frames(5)
	_hooks(strider, bulwark, gate)
	var table := {}
	table.merge(await _speeds())
	table.merge(await _hold_and_blocks())
	await _ceiling()
	await _landings()
	await _heat()
	await _overheat()
	await _wedge()
	table["rates"] = await _rates()
	print("[hover] cruise %.2f  strafe %.2f  boost %.2f m/s  half turn %.2f s  climb %.2f  descend %.2f m/s" % [
		table["cruise"], table["strafe"], table["boost"], table["turn_t"], table["climb"], table["descend"]])
	print("[hover] drift stop from cruise: %.1f m in %.2f s (speed after 0.25 s %.1f m/s); from boost %.1f m" % [
		table["stop_d"], table["stop_t"], table["stop_v025"], table["stop_boost"]])
	print("[hover] hold over flat %.2f m (err %.3f); over 12 m block: lowest clearance at the edge %.2f m, settles to %.2f m, max vertical accel %.1f m/s^2" % [
		table["hold"], table["hold_err"], table["edge_clear"], table["settle"], table["vacc"]])
	for b in _bodies:
		b.queue_free()
	finish()


# --- Hooks ------------------------------------------------------------------------------------------------------

func _hooks(strider: MechController, bulwark: MechController, gate: MechController) -> void:
	eq(w.chassis_id, "wasp", "the Wasp's controller (drafts)")
	check(w.hover_mode, "the Wasp flies (catalog move == hover)")
	eq(MechSpawn.rig_of(w).model.chassis_id, "wasp", "and its model")
	var cap := (w.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	near(cap.radius, 2.2, 1e-4, "Wasp capsule radius 2.2")
	near(cap.height, 5.0, 1e-4, "Wasp capsule height 5")
	near(w.heat_cap, 90.0, 1e-6, "Wasp heat cap 90")
	near(w.cooling, 9.0, 1e-6, "Wasp cooling 9")
	var mv := MechCatalog.movement("wasp", true)
	for k: String in MechCatalog.MOVEMENT_KEYS + MechCatalog.HOVER_KEYS:
		near(float(w.get(k)), float(mv[k]), 1e-6, "Wasp %s from the catalog" % k)
	# The game's gate: without drafts a Wasp request is a Strider, controller and model.
	eq(gate.chassis_id, "strider", "MechSpawn without drafts gives the Strider for the Wasp")
	check(not gate.hover_mode, "and it walks")
	eq(MechSpawn.rig_of(gate).model.chassis_id, "strider", "and its model is the Strider")
	check(not MechCatalog.CHASSIS.has("wasp") and not "wasp" in MechCatalog.CHASSIS_ORDER, "the Wasp is still a draft")
	# The lab's sliders start at the catalog's numbers.
	for p: Dictionary in HoverLab.PARAMS:
		var id := str(p["id"])
		if HoverLab.CTRL_PARAMS.has(id):
			var k := str(HoverLab.CTRL_PARAMS[id])
			var cv := float(mv[k]) if mv.has(k) else float(w.get(k))
			near(float(p["value"]), cv, 1e-4, "lab %s starts at the catalog's %s" % [id, k])
		elif HoverLab.POSE_PARAMS.has(id):
			near(float(p["value"]), float(MechSpawn.rig_of(w).hover_pose.get(str(HoverLab.POSE_PARAMS[id]))), 1e-4,
				"lab %s starts at HoverPose's value" % id)
	# Hooks for all three.
	check(w.grounded(), "a Wasp spawned on the floor is landed")
	check(w.can_fly(), "Wasp can_fly")
	eq(w.working_fans(), 2, "Wasp working_fans 2")
	near(w.altitude(), 0.0, 0.1, "landed Wasp altitude ~0")
	near(w.headroom(), MechController.HEADROOM_MAX, 1e-3, "open sky: headroom is HEADROOM_MAX")
	w.fans_alive = 1
	check(not w.can_fly() and w.working_fans() == 1, "one fan: cannot fly")
	w.fans_alive = 2
	for m: MechController in [strider, bulwark]:
		check(not m.can_fly(), "%s can_fly false" % m.chassis_id)
		eq(m.working_fans(), 0, "%s working_fans 0" % m.chassis_id)
		near(m.altitude(), 0.0, 0.15, "%s altitude ~0 standing" % m.chassis_id)
		near(m.headroom(), MechController.HEADROOM_MAX, 1e-3, "%s headroom in the open" % m.chassis_id)
		check(m.grounded(), "%s grounded" % m.chassis_id)
		m.climb_input = 1.0   # ignored by a biped
	await frames(20)
	for m: MechController in [strider, bulwark]:
		check(m.grounded() and m.global_position.y < 0.2, "%s ignores climb_input" % m.chassis_id)
		m.climb_input = 0.0
	w.add_heat(w.heat_cap)
	check(not w.can_fly(), "shut down: cannot fly")
	w.reset_heat()


# --- Speeds -------------------------------------------------------------------------------------------------------

func _top(mv: Vector2, run: bool) -> float:
	await _place(Vector3(0, 6, 200), false)
	_inputs(mv, 0.0, run)
	var v := 0.0
	var n := _steps(4.0)
	for i in n:
		await get_tree().physics_frame
		w.heat = 0.0
		if i > n - _steps(0.6):
			v = maxf(v, w.ground_speed())
	_inputs()
	return v


func _speeds() -> Dictionary:
	var r := {}
	r["cruise"] = await _top(Vector2(0, 1), false)
	r["strafe"] = await _top(Vector2(1, 0), false)
	r["boost"] = await _top(Vector2(0, 1), true)
	near(r["cruise"], 16.0, 0.3, "cruise 16 m/s (%.2f)" % r["cruise"])
	near(r["strafe"], 16.0, 0.3, "strafe at full speed 16 m/s (%.2f)" % r["strafe"])
	near(r["boost"], 24.0, 0.4, "boost 24 m/s (%.2f)" % r["boost"])
	# Half turn.
	await _place(Vector3(0, 6, 200), false)
	_inputs(Vector2.ZERO, 0.0, false, 1.0)
	var turned := 0.0
	var prev := w.forward()
	var t := 0.0
	for i in _steps(5.0):
		await get_tree().physics_frame
		t += _dt()
		turned += absf(prev.signed_angle_to(w.forward(), Vector3.UP))
		prev = w.forward()
		if turned >= PI:
			break
	r["turn_t"] = t
	near(t, 1.2, 0.05, "half turn in ~1.2 s (%.2f)" % t)
	# Climb (from landed: lift-off) and descend rates.
	await _place(Vector3(-150, 0.05, -150), true)
	_inputs(Vector2.ZERO, 1.0)
	var y0 := 0.0
	var lifted := -1.0
	t = 0.0
	for i in _steps(4.0):
		await get_tree().physics_frame
		t += _dt()
		w.heat = 0.0
		if lifted < 0.0 and not w.grounded():
			lifted = t
		if absf(t - 2.0) < _dt() * 0.5:
			y0 = w.global_position.y
	r["climb"] = (w.global_position.y - y0) / 2.0
	check(lifted >= 0.0 and lifted < 0.1, "climb input lifts it off at once (%.3f s)" % lifted)
	near(r["climb"], 9.0, 0.15, "climbs at 9 m/s (%.2f)" % r["climb"])
	var top_y := w.global_position.y
	_inputs(Vector2.ZERO, -1.0)
	for i in _steps(1.5):
		await get_tree().physics_frame
	var y1 := w.global_position.y
	for i in _steps(1.0):
		await get_tree().physics_frame
	r["descend"] = y1 - w.global_position.y
	near(r["descend"], 9.0, 0.15, "descends at 9 m/s (%.2f, from %.0f m)" % [r["descend"], top_y])
	# Drift stop from cruise and from boost.
	var st := await _stop_from(false)
	r["stop_d"] = st["d"]
	r["stop_t"] = st["t"]
	r["stop_v025"] = st["v025"]
	r["stop_boost"] = (await _stop_from(true))["d"]
	check(float(r["stop_v025"]) > 12.0, "it drifts: 0.25 s after letting go it still makes %.1f m/s" % r["stop_v025"])
	check(float(r["stop_d"]) > 10.0 and float(r["stop_d"]) < 22.0, "stops from cruise within 10..22 m (%.1f)" % r["stop_d"])
	check(float(r["stop_t"]) < 3.5, "and within 3.5 s (%.2f)" % r["stop_t"])
	return r


func _stop_from(run: bool) -> Dictionary:
	await _place(Vector3(100, 6, 300), false)
	_inputs(Vector2(0, 1), 0.0, run)
	for i in _steps(4.0):
		await get_tree().physics_frame
		w.heat = 0.0
	_inputs()
	var p0 := w.global_position
	var t := 0.0
	var v025 := 0.0
	for i in _steps(8.0):
		await get_tree().physics_frame
		t += _dt()
		if v025 == 0.0 and t >= 0.25:
			v025 = w.ground_speed()
		if w.ground_speed() < 0.05:
			break
	var d := w.global_position - p0
	return {"d": Vector2(d.x, d.z).length(), "t": t, "v025": v025}


# --- Height hold ------------------------------------------------------------------------------------------------

func _hold_and_blocks() -> Dictionary:
	var r := {}
	# Over flat ground: released at 7 m, moving.
	await _place(Vector3(-100, 7, 300), false)
	_inputs(Vector2(0, 1))
	var err := 0.0
	for i in _steps(5.0):
		await get_tree().physics_frame
		w.heat = 0.0
		if i > _steps(1.5):
			err = maxf(err, absf(w.altitude() - 7.0))
	r["hold"] = w.altitude()
	r["hold_err"] = err
	check(err < 0.15, "holds 7 m over flat ground while flying (worst error %.3f m)" % err)
	# Released low: it rises to hover_height.
	await _place(Vector3(-100, 1.0, 300), false)
	for i in _steps(3.0):
		await get_tree().physics_frame
	near(w.altitude(), w.hover_height, 0.15, "released at 1 m it rises to the lowest hold, %.1f m (%.2f)" % [w.hover_height, w.altitude()])
	# Over a 12 m block (20 m deep) at cruise, holding 5 m.
	var blk := _slab(Vector3(150, 6, 120), Vector3(30, 12, 20))   # near face at z 130
	await _place(Vector3(150, 5, 210), false)
	_inputs(Vector2(0, 1))
	var prev_vs := 0.0
	var vacc := 0.0
	var edge := INF
	var hit_wall := false
	var over_ok := true
	var ys: Array[float] = []
	for i in _steps(12.0):
		await get_tree().physics_frame
		w.heat = 0.0
		var p := w.global_position
		var vs := w.velocity.y
		if i > 2:
			vacc = maxf(vacc, absf(vs - prev_vs) / _dt())
		prev_vs = vs
		if p.z < 130.0 + 2.2 and p.z > 110.0 - 2.2:   # the capsule over the block
			edge = minf(edge, p.y - 12.0)
		for c in w.get_slide_collision_count():
			if w.get_slide_collision(c).get_collider() == blk:
				hit_wall = true
		if p.z < 75.0:
			ys.append(p.y)
	r["edge_clear"] = edge
	r["vacc"] = vacc
	check(not hit_wall, "flies over the 12 m block without touching it")
	check(edge > 1.0, "clears the block's top by %.2f m all the way over (the capsule's edge over its rim included)" % edge)
	check(vacc <= w.climb_accel * 1.05 + 0.5, "vertical accel bounded by climb_accel (max %.1f m/s^2)" % vacc)
	# After it: back down to 5 m, no oscillation (vertical speed changes sign at most once in the settle).
	var sign_flips := 0
	for i in range(2, ys.size()):
		var a := ys[i - 1] - ys[i - 2]
		var b := ys[i] - ys[i - 1]
		if absf(a) > 1e-3 and absf(b) > 1e-3 and signf(a) != signf(b):
			sign_flips += 1
	r["settle"] = w.altitude()
	near(w.altitude(), 5.0, 0.3, "back at its 5 m hold after the block (%.2f)" % w.altitude())
	check(sign_flips <= 1, "settles without oscillating (%d sign flips)" % sign_flips)
	over_ok = over_ok and w.global_position.z < 75.0
	check(over_ok, "and passed it")
	# Over a 30 m block: gets over it (it may brush the face: it cannot climb 25 m in its look-ahead).
	_slab(Vector3(300, 15, 120), Vector3(30, 30, 24))
	await _place(Vector3(300, 5, 210), false)
	_inputs(Vector2(0, 1))
	var vmax := 0.0
	var over30 := false
	for i in _steps(12.0):
		await get_tree().physics_frame
		w.heat = 0.0
		vmax = maxf(vmax, w.velocity.length())
		if w.global_position.z < 108.0 - 2.2 and w.global_position.y > 30.0:
			over30 = true
	check(over30, "gets over a 30 m block (z %.0f, y %.1f)" % [w.global_position.z, w.global_position.y])
	check(vmax < w.walk_speed + w.climb_rate + 1.0, "no speed spike on the way (max %.1f)" % vmax)
	_inputs()
	return r


# --- Ceiling ------------------------------------------------------------------------------------------------------

func _ceiling() -> void:
	# No cap: 200 m in the open.
	await _place(Vector3(-150, 0.05, -150), true)
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(30.0):
		await get_tree().physics_frame
		w.heat = 0.0
		if w.global_position.y > 205.0:
			break
	check(w.global_position.y > 200.0, "no altitude cap: climbs to 200 m in the open (%.0f)" % w.global_position.y)
	near(w.altitude(), w.global_position.y, 0.5, "altitude reads the floor 200 m down (%.1f)" % w.altitude())
	_inputs()
	for i in _steps(2.0):
		await get_tree().physics_frame
	var y := w.global_position.y
	for i in _steps(2.0):
		await get_tree().physics_frame
	near(w.global_position.y, y, 0.2, "and holds there")
	# A slab at 40 m (2 thick) with a 14 m opening centred on (-150, 150).
	var c := Vector3(-150, 41, 150)
	var side := 60.0
	var hole := 14.0
	var wd := (side - hole) * 0.5
	_slab(c + Vector3(0, 0, -(hole + wd) * 0.5), Vector3(side, 2, wd))
	_slab(c + Vector3(0, 0, (hole + wd) * 0.5), Vector3(side, 2, wd))
	_slab(c + Vector3(-(hole + wd) * 0.5, 0, 0), Vector3(wd, 2, hole))
	_slab(c + Vector3((hole + wd) * 0.5, 0, 0), Vector3(wd, 2, hole))
	# Under the solid part: stops under it, no speed piles up, and the hold does not push into it.
	await _place(Vector3(-150 + 20, 0.05, 150), true)
	near(w.headroom(), 40.0 - 5.0, 0.3, "headroom under the slab (%.2f)" % w.headroom())
	_inputs(Vector2.ZERO, 1.0)
	var vmax := 0.0
	for i in _steps(8.0):
		await get_tree().physics_frame
		w.heat = 0.0
		if i > _steps(6.0):
			vmax = maxf(vmax, absf(w.velocity.y))
	var top := w.global_position.y + 5.0
	check(top > 39.5 and top <= 40.05, "stops under the slab (capsule top %.2f, slab at 40)" % top)
	check(vmax < 0.6, "no vertical speed piles up against it (%.2f)" % vmax)
	check(w.headroom() < 0.5, "headroom ~0 against it (%.2f)" % w.headroom())
	_inputs()
	for i in _steps(3.0):
		await get_tree().physics_frame
	var top2 := w.global_position.y + 5.0
	check(top2 < 40.0 - 0.2 and top2 > 38.5, "released, it holds just under the slab (top %.2f)" % top2)
	# Through the opening: up, hold above, back down, land on the floor.
	await _place(Vector3(-150, 0.05, 150), true)
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(10.0):
		await get_tree().physics_frame
		w.heat = 0.0
		if w.global_position.y > 50.0:
			break
	check(w.global_position.y > 50.0, "climbs up through the opening (feet at %.1f m)" % w.global_position.y)
	_inputs()
	for i in _steps(2.0):
		await get_tree().physics_frame
	check(w.global_position.y > 42.0 and not w.grounded(), "holds above the slab (%.1f)" % w.global_position.y)
	near(w.headroom(), MechController.HEADROOM_MAX, 1e-3, "open sky above the slab")
	_inputs(Vector2.ZERO, -1.0)
	for i in _steps(15.0):
		await get_tree().physics_frame
		if w.grounded():
			break
	check(w.grounded() and w.global_position.y < 0.3, "descends back through the opening and lands on the floor (%.2f)" % w.global_position.y)
	_inputs()


# --- Landing ------------------------------------------------------------------------------------------------------

## Descend (climb -1) from where it is until landed; {landed, impact, t}.
func _descend(limit: float = 15.0) -> Dictionary:
	_inputs(Vector2.ZERO, -1.0)
	var t := 0.0
	var hard := [0]
	var cb := func(_s: float, _v: float) -> void: hard[0] += 1
	w.hard_landing.connect(cb)
	for i in _steps(limit):
		await get_tree().physics_frame
		t += _dt()
		if w.grounded():
			break
	w.hard_landing.disconnect(cb)
	_inputs()
	return {"landed": w.grounded(), "impact": w.last_impact, "t": t, "hard": hard[0]}


func _landings() -> void:
	# Ground.
	await _place(Vector3(200, 12, -200), false)
	var g := await _descend()
	check(g["landed"], "lands on the ground")
	check(float(g["impact"]) < 3.5 and int(g["hard"]) == 0, "gently (%.2f m/s, no hard landing)" % g["impact"])
	near(w.velocity.length(), 0.0, 1e-4, "landed: zero velocity")
	# Landed: turns, does not move.
	var p0 := w.global_position
	var f0 := w.forward()
	_inputs(Vector2(0.7, 0.7), 0.0, true, 1.0)
	for i in _steps(2.0):
		await get_tree().physics_frame
	check((w.global_position - p0).length() < 0.05, "landed it does not translate (%.3f m)" % (w.global_position - p0).length())
	check(absf(f0.signed_angle_to(w.forward(), Vector3.UP)) > 0.5, "landed it turns")
	check(w.grounded(), "move input does not lift it off")
	# Lift off.
	_inputs(Vector2.ZERO, 1.0)
	await frames(3)
	check(not w.grounded() and w.global_position.y > p0.y + 0.01, "climb input lifts it off")
	# Roof (a 12 m block).
	_slab(Vector3(-300, 6, 200), Vector3(30, 12, 30))
	await _place(Vector3(-300, 20, 200), false)
	var roof := await _descend()
	check(roof["landed"] and absf(w.global_position.y - 12.0) < 0.3, "lands on a roof (%.2f)" % w.global_position.y)
	check(float(roof["impact"]) < 3.5, "gently (%.2f m/s)" % roof["impact"])
	_inputs(Vector2.ZERO, 1.0)
	await frames(5)
	check(not w.grounded(), "lifts off a roof")
	# A 20 deg ramp: lands and stays put.
	_wedge_ramp(Vector3(-300, 0, -50), 20.0, 40.0, 20.0)
	var rx := Vector3(-300, 0, -70)   # 20 m up the ramp: surface at ~7.3 m
	await _place(rx + Vector3(0, 14, 0), false)
	var rmp := await _descend()
	check(rmp["landed"], "lands on a 20 deg ramp (feet %.2f m)" % w.global_position.y)
	var rp := w.global_position
	for i in _steps(2.0):
		await get_tree().physics_frame
	check((w.global_position - rp).length() < 0.05, "and does not slide on it (%.3f m)" % (w.global_position - rp).length())
	_inputs(Vector2.ZERO, 1.0)
	await frames(5)
	check(not w.grounded(), "lifts off the ramp")
	# A 60 deg face: never lands on it; slides off and lands at its foot.
	_wedge_ramp(Vector3(300, 0, -50), 20.0, 10.0, 60.0)   # 17.3 m tall over 10 m
	await _place(Vector3(300, 22, -56), false)
	_inputs(Vector2.ZERO, -1.0)
	var on_face := false
	for i in _steps(12.0):
		await get_tree().physics_frame
		if w.grounded():
			on_face = on_face or w.global_position.y > 0.5
			break
	check(w.grounded(), "descending onto a 60 deg face it ends up landed")
	check(not on_face and w.global_position.y < 0.5, "on the floor at its foot, not on the face (feet %.2f m)" % w.global_position.y)
	_inputs()


# --- Heat ---------------------------------------------------------------------------------------------------------

func _heat() -> void:
	await _place(Vector3(-200, 6, -300), false)
	for i in _steps(1.0):
		await get_tree().physics_frame
	near(w.move_heat_rate(), 0.0, 1e-6, "hovering in place costs nothing")
	w.heat = 40.0
	for i in _steps(1.0):
		await get_tree().physics_frame
	near(w.heat, 40.0 - w.cooling, 0.3, "flying it cools at the catalog rate (%.2f)" % w.heat)
	_inputs(Vector2(0, 1))
	for i in _steps(3.0):
		await get_tree().physics_frame
	near(w.move_heat_rate(), w.walk_heat, 0.1, "cruising costs walk_heat (%.2f)" % w.move_heat_rate())
	_inputs(Vector2(0, 1), 0.0, true)
	for i in _steps(3.0):
		await get_tree().physics_frame
	near(w.move_heat_rate(), w.run_heat, 0.15, "boosting costs run_heat (%.2f)" % w.move_heat_rate())
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(2.0):
		await get_tree().physics_frame
	near(w.move_heat_rate(), w.run_heat, 0.15, "a full climb costs run_heat (%.2f)" % w.move_heat_rate())
	_inputs(Vector2.ZERO, -1.0)
	for i in _steps(0.5):
		await get_tree().physics_frame
	near(w.move_heat_rate(), 0.0, 1e-6, "descending costs nothing")
	# Heat really accumulates: boost + climb against cooling 9 with a hot frame (add_heat of a gun's passive load).
	await _place(Vector3(-200, 0.05, -300), true)
	w.heat = 60.0
	for i in _steps(1.0):
		await get_tree().physics_frame
	near(w.heat, 60.0 - w.cooling * w.landed_cooling, 0.3, "landed it cools x%.1f (%.2f)" % [w.landed_cooling, w.heat])
	near(w.move_heat_rate(), 0.0, 1e-6, "landed costs nothing")


# --- Overheat -----------------------------------------------------------------------------------------------------

func _overheat() -> void:
	await _place(Vector3(200, 0.05, 300), true)
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(6.0):
		await get_tree().physics_frame
		w.heat = 0.0
		if w.global_position.y > 30.0:
			break
	var hard: Array = []
	var ev := {"over": 0, "reboot": 0}
	var cb_h := func(s: float, _v: float) -> void: hard.append(s)
	var cb_o := func() -> void: ev["over"] += 1
	var cb_r := func() -> void: ev["reboot"] += 1
	w.hard_landing.connect(cb_h)
	w.overheated.connect(cb_o)
	w.rebooted.connect(cb_r)
	w.add_heat(w.heat_cap)
	check(w.shutdown and int(ev["over"]) == 1, "overheated at %.0f m: shut down" % w.global_position.y)
	var landed_t := -1.0
	var t := 0.0
	for i in _steps(6.0):
		await get_tree().physics_frame
		t += _dt()
		if landed_t < 0.0 and w.grounded():
			landed_t = t
			break
	check(landed_t > 0.0, "it falls onto its legs (%.2f s)" % landed_t)
	check(hard.size() == 1 and float(hard[0]) > 20.0, "hard_landing fires on touchdown (%s m/s)" % str(hard))
	check(w.shutdown, "still shut down on the ground")
	# Climb held while shut down: stays down until the reboot, then lifts at once.
	_inputs(Vector2.ZERO, 1.0)
	var rebooted_t := -1.0
	var lift_t := -1.0
	t = 0.0
	for i in _steps(20.0):
		await get_tree().physics_frame
		t += _dt()
		if rebooted_t < 0.0:
			check(w.grounded(), "landed while shut down (t %.2f)" % t) if w.shutdown else null
			if not w.shutdown:
				rebooted_t = t
		elif lift_t < 0.0 and not w.grounded():
			lift_t = t
			break
	check(int(ev["reboot"]) == 1 and rebooted_t > 0.0, "rebooted by the normal rule (%.1f s)" % rebooted_t)
	check(lift_t > 0.0 and lift_t - rebooted_t < 0.1, "climb held through the reboot lifts it off at once")
	# Released after the reboot without climb input: stays landed.
	await _place(Vector3(200, 0.05, 300), true)
	w.add_heat(w.heat_cap)
	for i in _steps(20.0):
		await get_tree().physics_frame
		if not w.shutdown:
			break
	for i in _steps(1.0):
		await get_tree().physics_frame
	check(not w.shutdown and w.grounded(), "rebooted with no input it stays landed")
	w.hard_landing.disconnect(cb_h)
	w.overheated.disconnect(cb_o)
	w.rebooted.disconnect(cb_r)
	_inputs()


# --- Wedge --------------------------------------------------------------------------------------------------------

func _wedge() -> void:
	var gap := 2.2 * 2.0 * 0.6
	var base := Vector3(0, 0, -300)
	_slab(base + Vector3(-gap * 0.5 - 5.0, 3.0, 0), Vector3(10, 6, 40))
	_slab(base + Vector3(gap * 0.5 + 5.0, 3.0, 0), Vector3(10, 6, 40))
	await _place(base + Vector3(0, 1.0, 0), false)
	w.add_heat(w.heat_cap)   # fans stopped: it falls into the slot
	var landings: Array = []
	var cb := func(s: float, _v: float) -> void: landings.append(s)
	w.hard_landing.connect(cb)
	var vmax := 0.0
	var settled := -1
	for i in _steps(6.0):
		await get_tree().physics_frame
		vmax = maxf(vmax, w.velocity.length())
		if settled < 0 and w.grounded() and w._wedge_t == 0.0:
			settled = i
	w.hard_landing.disconnect(cb)
	print("[hover wedge] gap %.1f m: vmax %.2f m/s, settled at step %d, feet %.2f m, landings %s" % [gap, vmax, settled,
		w.global_position.y, str(landings)])
	check(vmax < 10.0, "wedged Wasp: speed stays bounded (%.2f)" % vmax)
	check(landings.is_empty(), "wedged Wasp: no hard landing")
	check(settled >= 0, "wedged Wasp: at rest on its legs or nudged free")
	w.reset_heat()
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(2.0):
		await get_tree().physics_frame
	check(w.global_position.y > 8.0, "rebooted, it climbs out (%.1f m)" % w.global_position.y)
	_inputs()


# --- Step rates ---------------------------------------------------------------------------------------------------

func _profile() -> Dictionary:
	var r := {}
	r["top"] = await _top(Vector2(0, 1), false)
	r["stop"] = (await _stop_from(false))["d"]
	await _place(Vector3(-50, 0.05, -350), true)
	_inputs(Vector2.ZERO, 1.0)
	for i in _steps(2.0):
		await get_tree().physics_frame
		w.heat = 0.0
	r["climb2"] = w.global_position.y
	_inputs()
	for i in _steps(3.0):
		await get_tree().physics_frame
	r["hold"] = w.global_position.y
	r["hold_over"] = r["hold"] - r["climb2"]
	return r


func _rates() -> Dictionary:
	var out := {}
	var ticks := Engine.physics_ticks_per_second
	for hz: int in [60, 30, 120]:
		Engine.physics_ticks_per_second = hz
		await frames(4)
		out[hz] = await _profile()
		print("[hover rate] %3d Hz: cruise %.2f  stop %.2f m  climb 2 s %.2f m  holds at %.2f m" % [hz, out[hz]["top"],
			out[hz]["stop"], out[hz]["climb2"], out[hz]["hold"]])
	Engine.physics_ticks_per_second = ticks
	await frames(4)
	for hz: int in [30, 120]:
		near(out[hz]["top"], out[60]["top"], 0.3, "%d Hz cruise matches 60 Hz" % hz)
		near(out[hz]["stop"], out[60]["stop"], 1.0, "%d Hz stop distance matches 60 Hz" % hz)
		near(out[hz]["climb2"], out[60]["climb2"], 0.6, "%d Hz climb matches 60 Hz" % hz)
		near(out[hz]["hold"], out[60]["hold"], 0.4, "%d Hz hold height matches 60 Hz" % hz)
	return out
