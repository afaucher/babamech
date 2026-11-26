extends TestCase
## Per-chassis movement (MechCatalog "movement", MechController.apply_chassis, MechSpawn). Flat world (+Y up, gravity 22),
## real mechs (MechSpawn.make), real physics frames (the runner's fixed 60 Hz step; nothing timed on the wall clock).
## (1) Golden: the Strider's numbers are exactly today's (the controller's defaults, its capsule, its step-up, its rig and
##     gait numbers), and a bare MechController's defaults are the Strider's catalog block.
## (2) The Bulwark measured against its targets: walk / run / strafe top speeds, the side-step strafe (no hip twist),
##     time to turn 180 deg (about 1 / 0.61 of the Strider's), time to walk speed, a climb from cold limited by heat alone
##     (no hop ceiling since 2026-11-25: ~1.9 s of burn to shutdown, ~20 m peak; a 12 m roof yes with real heat, a 30 m
##     roof no; the Strider climbs both), step-up (1.6 m climbs, 2.0 m does not), a 100 m drop under the fall-damage speed
##     (the full sweep: test_auto_land_bulwark), and the wedge (jammed between two blocks: bounded speed, nudged free).
## Prints a table of both chassis.

## Today's Strider (before the per-chassis block existed): every controller tunable, the capsule and the step-up.
const GOLDEN := {"walk_speed": 12.0, "run_speed": 22.0, "strafe_scale": 1.0, "accel": 30.0, "turn_rate": 1.8, "gravity": 22.0,
	"climb_speed": 10.0, "thrust_accel": 34.0, "air_control": 0.35, "thrust_heat": 24.0, "walk_heat": 2.5, "run_heat": 9.0,
	"cooling": 9.0, "heat_cap": 100.0, "reboot_heat": 35.0, "reboot_time": 1.2, "auto_burn": true, "safe_land_speed": 10.0,
	"hard_land_speed": 18.0, "auto_land_speed": 16.0, "auto_burn_heat": 24.0}
const GOLDEN_CAPSULE := Vector2(2.2, 8.0)
const GOLDEN_STEP_UP := 1.2464            ## m, the Strider's max_step_up (rig.max_step() of its legs), measured before
## The Strider's rig / gait numbers (MechRig / Gait initial values).
const GOLDEN_RIG := {"bob": 0.1, "lean": 0.16, "sway": 0.04, "foot_gap": 0.65, "step_margin": 0.9, "air_tuck": 0.5,
	"absorb": 0.35, "absorb_time": 0.1, "sag_depth": 0.42, "sag_pitch": 0.17, "sag_roll": 0.035, "sag_time": 0.65,
	"twist_max": PI * 0.5, "twist_rate": PI * 1.5, "gait.step_length": 4.0, "gait.min_stride": 0.7, "gait.step_time": 0.45,
	"gait.run_step_time": 0.21, "gait.min_step_time": 0.16, "gait.step_height": 1.0, "gait.land_time": 0.18,
	"gait.settle_time": 0.3, "gait.settle_error": 0.18, "gait.step_clearance": 0.25, "gait.overlap_k": 0.6, "gait.reach_err": INF}

var _bodies: Array[Node] = []
var _table := {}


func _init() -> void:
	timeout_sec = 240.0


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
	_slab(Vector3(0, -0.5, 0), Vector3(800, 1, 800))
	var strider := MechSpawn.make("chicken", "strider", {}, 1)
	add_child(strider)
	var bulwark := MechSpawn.make("chicken", "bulwark", {}, 2)
	add_child(bulwark)
	await frames(3)
	_golden(strider)
	eq(bulwark.chassis_id, "bulwark", "the Bulwark's controller took its chassis")
	eq(MechSpawn.rig_of(bulwark).model.chassis_id, "bulwark", "and its model")
	near(MechSpawn.rig_of(bulwark).twist_max, 0.0, 1e-6, "the Bulwark's rig has no hip twist (ChassisParts twist_max)")
	var bcap := _capsule(bulwark)
	near(bcap.x, 3.6, 1e-4, "the Bulwark's capsule radius")
	near(bcap.y, 8.0, 1e-4, "the Bulwark's capsule height")
	check(bcap.y >= bcap.x * 2.0, "a capsule is at least as tall as it is wide")
	near(bulwark.max_step_up, 1.63, 0.05, "the Bulwark steps up %.3f m (its legs: ~1.63)" % bulwark.max_step_up)
	near(bulwark.heat_cap, 130.0, 1e-6, "the Bulwark's heat cap (catalog)")
	near(bulwark.cooling, 12.0, 1e-6, "the Bulwark's cooling (catalog)")
	bulwark.global_position = _home_of(bulwark)   # out of the Strider's way
	strider.global_position = _home_of(strider)
	await frames(2)

	for m: MechController in [strider, bulwark]:
		var r := {}
		r["walk"] = await _top_speed(m, Vector2(0, 1), false)
		r["run"] = await _top_speed(m, Vector2(0, 1), true)
		r["strafe"] = await _top_speed(m, Vector2(1, 0), false)
		r["walk_t"] = await _time_to(m, m.walk_speed * 0.95)
		r["turn_t"] = await _turn_time(m)
		r["hop"] = await _hop(m)
		var c := await _climb_cold(m)
		r["shut_t"] = c["shut_t"]
		r["shut_h"] = c["shut_h"]
		r["peak_cold"] = c["peak"]
		_table[m.chassis_id] = r
		print("[move] %-8s walk %.2f  run %.2f  strafe %.2f m/s  to walk %.2f s  turn 180 %.2f s  hop peak %.2f m" % [m.chassis_id,
			r["walk"], r["run"], r["strafe"], r["walk_t"], r["turn_t"], r["hop"]])
		print("[move] %-8s thrust heat %.0f /s (auto burn %.0f), cooling %.0f, cap %.0f: from cold, shutdown after %.2f s of burn at %.1f m, peak %.1f m" % [
			m.chassis_id, m.thrust_heat, m.auto_burn_heat, m.cooling, m.heat_cap, c["shut_t"], c["shut_h"], c["peak"]])
	var s: Dictionary = _table["strider"]
	var b: Dictionary = _table["bulwark"]
	near(float(s["walk"]), 12.0, 0.2, "Strider walks 12")
	near(float(s["run"]), 22.0, 0.3, "Strider runs 22")
	near(float(b["walk"]), 8.0, 0.2, "Bulwark walks ~8")
	near(float(b["run"]), 14.0, 0.3, "Bulwark runs ~14")
	near(float(b["strafe"]), 6.4, 0.2, "Bulwark side-steps at 0.8 of its walk")
	var turn_ratio := float(s["turn_t"]) / float(b["turn_t"])
	near(turn_ratio, 0.61, 0.04, "the Bulwark turns at ~61 %% of the Strider's rate (%.2f)" % turn_ratio)
	check(float(b["walk_t"]) > float(s["walk_t"]) * 1.3, "the Bulwark picks up speed slower than the Strider (%.2f vs %.2f s)" % [
		b["walk_t"], s["walk_t"]])
	check(float(b["hop"]) > 20.0, "no hop ceiling: the Bulwark's thrust (heat held at 0) climbs freely (%.1f m in 3 s)" % b["hop"])
	check(float(s["hop"]) > 20.0, "the Strider's thrust still climbs freely (%.1f m in the same burn)" % s["hop"])
	# Heat is the limit: from cold the Bulwark burns ~1.9 s (heat 80 /s - cooling 12 into 130), the Strider ~6.7 s.
	check(float(b["shut_t"]) > 1.7 and float(b["shut_t"]) < 2.2, "a cold Bulwark burns %.2f s before it shuts down (1.7..2.2)" % b["shut_t"])
	check(float(b["peak_cold"]) > 16.0 and float(b["peak_cold"]) < 24.0, "a cold Bulwark's one-burn peak is %.1f m (16..24)" % b["peak_cold"])
	check(float(s["shut_t"]) > 6.0, "a cold Strider burns %.2f s before it shuts down (unchanged ~6.7)" % s["shut_t"])

	# Roofs from cold with real heat (thrust up a wall, then forward onto the top): 6 and 12 m yes, 30 m no.
	var roof6 := await _climb_onto(bulwark, 6.0)
	check(roof6["on_top"] and not roof6["shut"], "the Bulwark climbs onto a 6 m ledge (heat %.0f)" % roof6["heat"])
	var roof12 := await _climb_onto(bulwark, 12.0)
	check(roof12["on_top"] and not roof12["shut"], "the Bulwark climbs onto a 12 m roof, pushing its heat (heat %.0f of %.0f)" % [
		roof12["heat"], bulwark.heat_cap])
	check(float(roof12["heat"]) > float(roof6["heat"]), "the 12 m roof costs more heat than the 6 m ledge")
	var roof30 := await _climb_onto(bulwark, 30.0)
	check(not roof30["on_top"], "the Bulwark cannot reach a 30 m roof from cold (it overheats first: shut %s)" % roof30["shut"])
	var s30 := await _climb_onto(strider, 30.0)
	check(s30["on_top"] and not s30["shut"], "the Strider climbs onto a 30 m roof from cold (heat %.0f)" % s30["heat"])
	# Step-up from the legs.
	check(await _step_onto(bulwark, 1.6), "the Bulwark walks up a 1.6 m step")
	check(not await _step_onto(bulwark, 2.0), "a 2.0 m step blocks the Bulwark")
	check(await _step_onto(strider, 1.2), "the Strider still walks up a 1.2 m step")
	check(not await _step_onto(strider, 1.6), "a 1.6 m step still blocks the Strider")
	# A long drop with the automatic landing burn.
	var drop := await _drop(bulwark, 100.0)
	check(drop < 18.0, "a 100 m drop lands the Bulwark under the fall-damage speed (%.2f m/s)" % drop)
	await _wedge(bulwark)
	_clear()
	finish()


func _golden(m: MechController) -> void:
	eq(m.chassis_id, "strider", "the Strider's controller")
	for k: String in GOLDEN:
		var v: Variant = m.get(k)
		if GOLDEN[k] is bool:
			eq(v, GOLDEN[k], "Strider %s unchanged" % k)
		else:
			near(float(v), float(GOLDEN[k]), 1e-6, "Strider %s unchanged" % k)
	var bare := MechController.new()
	var mv := MechCatalog.movement("strider")
	for k: String in MechCatalog.MOVEMENT_KEYS + ["heat_cap", "cooling"]:
		near(float(bare.get(k)), float(mv[k]), 1e-6, "a bare controller's %s is the Strider's catalog value" % k)
	bare.free()
	var cap := _capsule(m)
	near(cap.x, GOLDEN_CAPSULE.x, 1e-6, "Strider capsule radius unchanged")
	near(cap.y, GOLDEN_CAPSULE.y, 1e-6, "Strider capsule height unchanged")
	near((m.get_node("Shape") as Node3D).position.y, GOLDEN_CAPSULE.y * 0.5, 1e-6, "Strider capsule bottom at the feet")
	near(m.max_step_up, GOLDEN_STEP_UP, 1e-3, "Strider step-up unchanged (%.4f)" % m.max_step_up)
	var rig := MechSpawn.rig_of(m)
	for k: String in GOLDEN_RIG:
		var v: Variant = rig.gait.get(k.trim_prefix("gait.")) if k.begins_with("gait.") else rig.get(k)
		near(float(v), float(GOLDEN_RIG[k]), 1e-6, "Strider rig %s unchanged" % k)


## Each mech's own patch of floor (the Bulwark's at +150, the Strider's at -150; a floor much bigger than 800 m breaks
## Godot's shape casts, so the landing probe would see nothing): every measurement starts there.
func _home_of(m: MechController) -> Vector3:
	return Vector3(150, 0, 150) if m.chassis_id == "bulwark" else Vector3(-150, 0, -150)


func _capsule(m: MechController) -> Vector2:
	var c := (m.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	return Vector2(c.radius, c.height)


func _stop(m: MechController) -> void:
	m.move_input = Vector2.ZERO
	m.turn_input = 0.0
	m.running = false
	m.thrust_input = false
	m.velocity = Vector3.ZERO
	m.heat = 0.0
	m.shutdown = false


func _place(m: MechController, at: Vector3) -> void:
	_stop(m)
	m.global_transform = Transform3D(Basis.IDENTITY, at)
	await frames(2)


## Ground speed after 4 s holding `input`.
func _top_speed(m: MechController, input: Vector2, run: bool) -> float:
	await _place(m, _home_of(m))
	m.move_input = input
	m.running = run
	var v := 0.0
	for f in 240:
		await get_tree().physics_frame
		m.heat = 0.0
		if f > 200:
			v = maxf(v, m.ground_speed())
	_stop(m)
	await frames(30)
	return v


## Seconds from rest to `speed` walking forward.
func _time_to(m: MechController, speed: float) -> float:
	await _place(m, _home_of(m))
	m.move_input = Vector2(0, 1)
	var t := 0.0
	for f in 300:
		await get_tree().physics_frame
		t += 1.0 / 60.0
		if m.ground_speed() >= speed:
			break
	_stop(m)
	await frames(30)
	return t


## Seconds to turn 180 deg in place at full turn input.
func _turn_time(m: MechController) -> float:
	await _place(m, _home_of(m))
	var f0 := m.forward()
	m.turn_input = 1.0
	var turned := 0.0
	var prev := f0
	var t := 0.0
	for f in 600:
		await get_tree().physics_frame
		t += 1.0 / 60.0
		turned += absf(prev.signed_angle_to(m.forward(), Vector3.UP))
		prev = m.forward()
		if turned >= PI:
			break
	_stop(m)
	await frames(10)
	return t


## The feet's peak height above the floor holding thrust from rest for 3 s (heat kept low so it never shuts down).
func _hop(m: MechController) -> float:
	await _place(m, _home_of(m))
	m.thrust_input = true
	var peak := 0.0
	for f in 180:
		await get_tree().physics_frame
		m.heat = 0.0
		peak = maxf(peak, m.global_position.y)
	m.thrust_input = false
	for f in 400:
		await get_tree().physics_frame
		if m.grounded() and f > 5:
			break
	_stop(m)
	await frames(20)
	return peak


## From cold on the floor, thrust held until the heat cap shuts it down: {shut_t: s of burn, shut_h: m up then, peak m}.
func _climb_cold(m: MechController) -> Dictionary:
	await _place(m, _home_of(m))
	m.thrust_input = true
	var t := 0.0
	var peak := 0.0
	var shut_t := -1.0
	var shut_h := 0.0
	for f in 1200:
		await get_tree().physics_frame
		t += 1.0 / 60.0
		peak = maxf(peak, m.global_position.y - _home_of(m).y)
		if m.shutdown and shut_t < 0.0:
			shut_t = t
			shut_h = m.global_position.y - _home_of(m).y
			m.thrust_input = false
		if shut_t >= 0.0 and m.grounded():
			break
	_stop(m)
	await frames(10)
	return {"shut_t": shut_t, "shut_h": shut_h, "peak": peak}


## From cold, the feet 1 m from a block `h` tall: forward held, thrust held until the feet clear the top by 1 m (or the
## mech shuts down), then forward alone. {on_top, shut (it overheated on the way), heat at the end}.
func _climb_onto(m: MechController, h: float) -> Dictionary:
	var base := _home_of(m) + Vector3(0, 0, 60)
	var r := _capsule(m).x
	_slab(base + Vector3(0, h * 0.5, -20.0 - r - 1.0), Vector3(60, h, 40))   # its near face 1 m ahead of the capsule
	await _place(m, base)
	m.move_input = Vector2(0, 1)
	var on_top := false
	var shut := false
	for f in 600:
		m.thrust_input = not m.shutdown and m.global_position.y < base.y + h + 1.0
		await get_tree().physics_frame
		shut = shut or m.shutdown
		if m.grounded() and m.global_position.y > base.y + h - 0.3:
			on_top = true
			break
		if f > 30 and m.grounded() and m.global_position.y < base.y + 0.5:
			break   # back on the floor
	var heat := m.heat
	print("[move] %s climbs at a %.0f m block from cold: on top %s, shut down %s, heat %.0f" % [m.chassis_id, h, on_top, shut, heat])
	_stop(m)
	var b: Node = _bodies.pop_back()
	b.queue_free()
	await _place(m, _home_of(m))
	return {"on_top": on_top, "shut": shut, "heat": heat}


## Walk at a step `h` tall; true when it ends on top.
func _step_onto(m: MechController, h: float) -> bool:
	var base := _home_of(m) + Vector3(0, 0, -60)
	_slab(base + Vector3(0, h * 0.5, -30), Vector3(40, h, 40))   # near face 10 m ahead
	await _place(m, base + Vector3(0, 0, 10))
	m.move_input = Vector2(0, 1)
	for f in 240:
		m.heat = 0.0
		await get_tree().physics_frame
	var y := m.global_position.y
	print("[move] %s at a %.1f m step: feet at %.2f m (step-up %.2f)" % [m.chassis_id, h, y, m.max_step_up])
	_stop(m)
	var b: Node = _bodies.pop_back()
	b.queue_free()
	await _place(m, base + Vector3(0, 0, 10))
	return y > h - 0.2


## Drop from `h` with the automatic burn; the touchdown speed.
func _drop(m: MechController, h: float) -> float:
	await _place(m, _home_of(m) + Vector3(0, h, 0))
	for f in 900:
		await get_tree().physics_frame
		if m.grounded() and f > 10:
			break
	print("[move] %s dropped %.0f m: touchdown %.2f m/s, heat %.1f" % [m.chassis_id, h, m.last_impact, m.heat])
	var v := m.last_impact
	_stop(m)
	return v


## Jammed between two blocks closer than the capsule is wide, feet 1 m up, no burn: bounded speed, nudged free, walks.
func _wedge(m: MechController) -> void:
	var r := _capsule(m).x
	var gap := r * 2.0 * 0.6
	var base := Vector3(-150, 0, 150)
	_slab(base + Vector3(-gap * 0.5 - 5.0, 3.0, 0), Vector3(10, 6, 40))
	_slab(base + Vector3(gap * 0.5 + 5.0, 3.0, 0), Vector3(10, 6, 40))
	await _place(m, base + Vector3(0, 1.0, 0))
	m.auto_burn = false
	var landings: Array = []
	var cb := func(speed: float, _sev: float) -> void: landings.append(speed)
	m.hard_landing.connect(cb)
	var vmax := 0.0
	var free_at := -1
	for f in 600:
		await get_tree().physics_frame
		vmax = maxf(vmax, m.velocity.length())
		if free_at < 0 and m.grounded() and m._wedge_t == 0.0:
			free_at = f   # nudged out on top, or up onto the two edges (the 7.2 m capsule bridges a 4.3 m gap)

		if free_at >= 0 and f > free_at + 60:
			break
	print("[wedge] %s gap %.1f m: vmax %.2f m/s, free at frame %d, landings %s" % [m.chassis_id, gap, vmax, free_at, str(landings)])
	check(vmax < 10.0, "wedged Bulwark: speed stays bounded (%.2f)" % vmax)
	check(landings.is_empty(), "wedged Bulwark: no hard landing")
	check(free_at >= 0 and free_at <= 240, "wedged Bulwark: nudged free and standing within 4 s (frame %d)" % free_at)
	var p0 := m.global_position
	m.move_input = Vector2(0, 1)
	for f in 120:
		await get_tree().physics_frame
	var walked := (m.global_position - p0).length()
	check(walked > 4.0, "freed Bulwark walks away (%.1f m in 2 s)" % walked)
	m.hard_landing.disconnect(cb)
	m.auto_burn = true
	_stop(m)
