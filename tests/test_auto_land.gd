extends TestCase
## The automatic landing burn (MechController.step, `auto_burn`): a late, short "suicide burn" that brakes a fall only
## down to `auto_land_speed` (a heavy landing that still feels like one), never to a fall-damage touchdown. Flat world
## (+Y up, gravity 22), a real mech (MechSpawn.make) bound to a real PlayerTarget (the fall-damage path:
## hard_landing -> PlayerTarget.FALL_DAMAGE_SPEED 20 m/s). The mech's own physics process is off: every fall is stepped
## here, synchronously, step(1 / hz) inside one engine physics frame whose step is 1 / hz (Engine.physics_ticks_per_second),
## so move_and_slide moves by the same delta and the sweep runs in game time, never against the wall clock.
## Sweep: drop heights 5..300 m x 30 / 60 / 120 Hz x
##   flat      dropped at rest onto a floor;                run   the same with run speed (22 m/s) along the floor;
##   ramp      a 25 deg ramp, running uphill / downhill;
##   ledge     walking / running off a roof past a lower roof that appears late under the mech (gaps 2 / 8 / 20 m);
##   edge      dropped with the capsule over a roof edge (the centre ray sees the street, the feet hit the roof);
##   hot       dropped at rest with the mech already at 50 % heat.
## Then the cases where it cannot burn: shut down (no cushion, as before) and the heat cap reached mid-burn (reported).
## Asserts: every touchdown < 20 m/s with headroom (WORST <= 18), zero fall damage through PlayerTarget, and the burn is
## lighter than the old one (later start, shorter, less heat, touchdown faster than safe_land_speed). Prints the table.

const HZ := [30, 60, 120]
const HEIGHTS := [5.0, 8.0, 10.0, 15.0, 20.0, 30.0, 48.0, 60.0, 96.0, 150.0, 200.0, 300.0]
const WORST := 18.0
## The old burn (brake to safe_land_speed 10 m/s, margins x1.15 + 1 m, x1.3 + 2 m probe; measured at 60 Hz before the
## change, with this harness): drop height -> [start-of-burn altitude m, burn time s, thrust heat, touchdown m/s].
## The old burn also failed this sweep: 31.4 m/s worst (a roof edge under the capsule: its centre ray saw the street),
## 21.7 running uphill onto a ramp, 25.3 walking off a roof past a lower one.
const OLD := {48.0: [30.6, 1.62, 38.8, 10.1], 96.0: [62.6, 2.57, 61.6, 9.9], 300.0: [200.5, 5.12, 122.8, 10.3]}

var _bodies: Array[Node] = []
var mech: MechController
var pt: PlayerTarget
var _hits: Array = []
var _worst := 0.0
var _worst_at := ""
var _kind_worst := {}


func _init() -> void:
	timeout_sec = 300.0


func setup() -> void:
	var world := CombatWorld.new()
	add_child(world)
	mech = MechSpawn.make("chicken", chassis_under_test(), {}, 1)
	add_child(mech)
	pt = PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, MechSpawn.rig_of(mech).model, "player1", 1)
	world.register(pt)
	pt.damaged.connect(func(amount: float, component: String, src: String) -> void: _hits.append([amount, component, src]))
	await frames(2)
	mech.set_physics_process(false)   # stepped here
	print("[auto] thrust %.0f gravity %.0f thrust_heat %.0f cooling %.0f safe_land %.0f auto_land %s" % [mech.thrust_accel,
		mech.gravity, mech.thrust_heat, mech.cooling, mech.safe_land_speed, str(mech.get("auto_land_speed"))])

	# Representative falls (60 Hz) against the old numbers (the Strider's: another chassis brakes with its own thrust).
	print("[auto] drop | start alt (old/new) | burn s (old/new) | heat (old/new) | touchdown m/s (old/new)")
	for h: float in (OLD if chassis_under_test() == "strider" else {}):
		var r := await _fall("flat", h, 60, {})
		var o: Array = OLD[h]
		print("[auto] %5.0f m | %6.1f / %6.1f | %5.2f / %5.2f | %6.1f / %6.1f | %5.1f / %5.1f" % [h, o[0], r["alt"], o[1],
			r["burn"], o[2], r["heat"], o[3], r["impact"]])
		check(float(r["alt"]) < float(o[0]), "%.0f m: the burn starts later (%.1f < %.1f m)" % [h, r["alt"], o[0]])
		check(float(r["burn"]) < float(o[1]), "%.0f m: the burn is shorter (%.2f < %.2f s)" % [h, r["burn"], o[1]])
		check(float(r["heat"]) < float(o[2]), "%.0f m: the burn costs less heat (%.1f < %.1f)" % [h, r["heat"], o[2]])
		check(float(r["impact"]) > mech.safe_land_speed, "%.0f m: touchdown is heavier than a soft landing (%.1f m/s)" % [h, r["impact"]])

	# The sweep.
	for hz: int in HZ:
		for h: float in HEIGHTS:
			await _fall("flat", h, hz, {})
			await _fall("run", h, hz, {})
			await _fall("ramp", h, hz, {"dir": 1.0})
			await _fall("ramp", h, hz, {"dir": -1.0})
			await _fall("edge", h, hz, {})
			if h <= 96.0:
				await _fall("hot", h, hz, {})
		for dh: float in [5.0, 10.0, 20.0, 48.0, 96.0]:
			for gap: float in [2.0, 8.0, 20.0]:
				for spd: float in [12.0, 22.0]:
					await _fall("ledge", dh, hz, {"gap": gap, "speed": spd})
	print("[auto] worst touchdown %.2f m/s (%s); by scenario %s" % [_worst, _worst_at, str(_kind_worst)])
	check(_worst <= WORST, "worst touchdown %.2f m/s <= %.0f (%s)" % [_worst, WORST, _worst_at])

	# Cannot burn: shut down, a fall is uncushioned (as before: the free-fall speed, fall damage).
	var r := await _fall("flat", 30.0, 60, {"shut": true}, false)
	print("[auto] shut down, 30 m: touchdown %.1f m/s, burn %.2f s, hits %d" % [r["impact"], r["burn"], _hits.size()])
	check(float(r["burn"]) == 0.0, "no burn while shut down")
	check(float(r["impact"]) > 30.0, "an uncushioned fall lands at the free-fall speed (%.1f)" % r["impact"])
	# Heat cap reached mid-burn (300 m from 90 % heat): the shutdown ends the burn, the rest of the fall is uncushioned.
	# Compared with braking all the way to safe_land_speed (about the old burn: its x1.15 margin ~ 1 / AUTO_LAND_ON), the
	# later burn has cooled longer when it starts and falls for less time, so it is never the harder crash.
	for heat0: float in [50.0, 75.0, 90.0]:
		r = await _fall("hot", 300.0, 60, {"heat": heat0}, false)
		var land := mech.auto_land_speed
		mech.auto_land_speed = mech.safe_land_speed
		var o := await _fall("hot", 300.0, 60, {"heat": heat0}, false)
		mech.auto_land_speed = land
		print("[auto] 300 m from heat %.0f: start alt %.1f, burn %.2f s, touchdown %.1f m/s, shut down %s (braking to %.0f: %.1f m/s, shut down %s)" % [
			heat0, r["alt"], r["burn"], r["impact"], str(r["shut"]), mech.safe_land_speed, o["impact"], str(o["shut"])])
		if o["shut"]:
			# (A burn that completes without shutting down and without damage is never the harder crash.)
			check(float(r["impact"]) <= float(o["impact"]) + 0.5 or (not r["shut"] and int(r["hits"]) == 0),
				"heat %.0f: the later burn is no harder a crash (%.1f vs %.1f)" % [
				heat0, r["impact"], o["impact"]])
		else:
			check(not r["shut"] and int(r["hits"]) == 0,"heat %.0f: the burn that completed before still completes, no damage" % heat0)
	pt.repair_all()
	Engine.physics_ticks_per_second = 60
	_clear()
	await frames(2)
	finish()


## The chassis swept (test_auto_land_bulwark overrides it).
func chassis_under_test() -> String:
	return "strider"


func _slab(center: Vector3, size: Vector3, rot_z: float = 0.0) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.transform = Transform3D(Basis(Vector3.BACK, rot_z), center)
	add_child(body)
	_bodies.append(body)


func _clear() -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()


## Build `kind` for drop height `h`, run one fall at `hz`; {alt (start-of-burn altitude above the touchdown point), burn
## (s), heat (thrust heat spent), impact (m/s), shut}. `strict` asserts the touchdown and no damage.
func _fall(kind: String, h: float, hz: int, o: Dictionary, strict: bool = true) -> Dictionary:
	_clear()
	await frames(1)
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var run := false
	var heat0 := 0.0
	var t_ff := sqrt(2.0 * h / mech.gravity)
	match kind:
		"flat", "hot":
			_slab(Vector3(0, -1, 0), Vector3(400, 2, 400))
			pos = Vector3(0, h, 0)
			heat0 = float(o.get("heat", 50.0)) if kind == "hot" else 0.0
		"run":
			_slab(Vector3(0, -1, 0), Vector3(800, 2, 200))
			pos = Vector3(-22.0 * t_ff - 10.0, h, 0)
			vel = Vector3(22, 0, 0)
			run = true
		"ramp":
			# A 25 deg ramp rising toward +x, its top surface through the origin; land near x = 0 from about h above it.
			var a := deg_to_rad(25.0)
			var n := Vector3(-sin(a), cos(a), 0)
			_slab(-n * 2.0, Vector3(1400, 4, 200), a)
			var d: float = o["dir"]
			pos = Vector3(-d * 22.0 * t_ff, 0, 0)
			pos.y = h + pos.x * tan(a)   # h above the ramp under the start
			vel = Vector3(22.0 * d, 0, 0)
			run = true
		"edge":
			# A 40 m building whose roof edge (x = 0) the capsule (r 2.2) overlaps by 1 m; the street below.
			_slab(Vector3(0, -1, 0), Vector3(400, 2, 400))
			_slab(Vector3(30, 20, 0), Vector3(60, 40, 60))
			pos = Vector3(-1.2, 40.0 + h, 0)
		"ledge":
			# Roof A (top y = top) ends at x = 0; roof B (h lower) starts at x = gap; the street 40 m under B.
			var top := h + 40.0
			_slab(Vector3(0, -1, 0), Vector3(600, 2, 200))
			_slab(Vector3(-30, top * 0.5, 0), Vector3(60, top, 60))
			var gap: float = o["gap"]
			_slab(Vector3(gap + 75.0, 20, 0), Vector3(150, 40, 60))
			pos = Vector3(-4.0, top + 0.02, 0)
			vel = Vector3(float(o["speed"]), 0, 0)
			run = float(o["speed"]) > 15.0
	Engine.physics_ticks_per_second = hz
	await frames(2)
	var dt := 1.0 / float(hz)
	near(get_physics_process_delta_time(), dt, 1e-6, "the engine physics step is 1/%d" % hz)
	pt.repair_all()
	_hits.clear()
	mech.global_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5) if vel.x >= 0.0 else Basis(Vector3.UP, PI * 0.5), pos)
	mech.velocity = vel
	mech.move_input = Vector2(0, 1) if vel.length() > 0.1 else Vector2.ZERO
	mech.running = run
	mech.thrust_input = false
	mech.shutdown = false
	mech.heat = heat0
	mech.last_impact = 0.0
	if o.get("shut", false):
		mech.add_heat(mech.heat_cap)
	var burn_y := INF
	var burn := 0.0
	var heat := 0.0
	var airborne := false
	var steps := int(30.0 * hz)
	for i in steps:
		var h0 := mech.heat
		mech.step(dt)
		if mech.emergency:
			if burn_y == INF:
				burn_y = mech.global_position.y
			burn += dt
			heat += mech.heat - h0 + mech.cooling * dt
		if not mech.grounded():
			airborne = true
		elif airborne:
			break
	var land_y := mech.global_position.y
	var r := {"alt": (burn_y - land_y) if burn_y != INF else 0.0, "burn": burn, "heat": heat, "impact": mech.last_impact,
		"shut": mech.shutdown, "hits": _hits.size()}
	mech.move_input = Vector2.ZERO
	mech.running = false
	var tag := "%s %s%.0f m @%d Hz" % [kind, "" if o.is_empty() else str(o) + " ", h, hz]
	if strict:
		check(airborne and mech.grounded(), "%s: landed" % tag)
		check(_hits.is_empty(), "%s: no fall damage (%.1f m/s, %s)" % [tag, mech.last_impact, str(_hits)])
		if mech.last_impact > _worst:
			_worst = mech.last_impact
			_worst_at = tag
		_kind_worst[kind] = maxf(float(_kind_worst.get(kind, 0.0)), mech.last_impact)
		if mech.last_impact > 17.0:
			print("[auto] %s: touchdown %.2f m/s, burn %.2f s from %.1f m, heat %.1f" % [tag, r["impact"], burn, r["alt"], heat])
	return r
