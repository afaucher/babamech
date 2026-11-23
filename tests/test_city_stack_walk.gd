extends TestCase
## A real mech (MechSpawn.make: the test drive's MechController + capsule + rig) walks the multi-deck stack under physics
## (docs/design/city-ramps-and-stack.md section 8): it spawns on road at spawn_transforms(1)[0]; walks DOWN a whole ramp
## from the upper deck to the lower one (deck_at changes exactly once, never below the ramp's surface, never stuck, between
## the parapets) and back UP it; crosses a cross-street bridge over the ramp lane's floor hole without falling; walks off
## the edge of an open-air shaft and lands standing on the deck below; and stack.follow(mech) moves the active deck with it.
## Steering is the mech's own input (move_input / turn_input, as the bot pilot drives it); physics is stepped by the engine
## at the runner's fixed 60 fps, and every limit is in physics frames, never wall-clock time.

const SEED := 4                  ## section seed 4: a ramp deck 0 -> 1 (ramp_a) and 1 -> 2 (ramp_b), a shaft 0 -> 1
const STUCK_FRAMES := 120        ## 2 s at 60 Hz
const LOOK_AHEAD := 14.0         ## m: pure-pursuit steering target ahead along the path

var stack: CityStack
var sec: SectionPlan
var mech: MechController
var rig: MechRig


func _init() -> void:
	timeout_sec = 600.0   # game seconds (the runner's fixed 60 fps): set before _ready starts TestCase's timer


func setup() -> void:
	sec = SectionPlan.make({"seed": SEED})
	stack = CityStack.new()
	add_child(stack)
	stack.build(sec)
	for d in stack.decks:
		d.props.set_physics_process(false)   # not about props: keep them still (and the run cheap)
	mech = MechSpawn.make()
	mech.ring = stack.ring()
	add_child(mech)
	rig = MechSpawn.rig_of(mech)
	await frames(2)
	print("mech: max_step_up %.3f, capsule r %.2f, floor_max_angle %.1f deg, snap %.2f" % [mech.max_step_up,
			((mech.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D).radius, rad_to_deg(mech.floor_max_angle), mech.floor_snap_length])
	await _spawn()
	for ci in sec.connectors.size():
		if sec.connectors[ci]["kind"] == "ramp":
			await _headroom(ci)
			await _ramp(ci)
			await _parapets(ci)
	await _bridge()
	await _shaft()
	stack.follow(null)
	finish()


# --- Moving the mech -------------------------------------------------------------------------------------------

func _place(at: Vector3, facing: Vector3) -> void:
	var u := stack.ring().up_at(at)
	mech.global_transform = Transform3D(stack.ring().basis_at(at, facing), at + u * 0.3)
	mech.velocity = Vector3.ZERO
	mech.move_input = Vector2.ZERO
	mech.turn_input = 0.0
	rig.gait.reset([])
	await frames(30)


## Turn toward `target` (in the floor plane) and walk: the bot's way (full turn input past ~15 degrees off).
func _steer(target: Vector3) -> void:
	var u := mech.up()
	var f := mech.forward() - u * mech.forward().dot(u)
	var to := target - mech.global_position
	to -= u * to.dot(u)
	if to.length() < 0.5 or f.length() < 1e-4:
		mech.move_input = Vector2.ZERO
		return
	var ang := f.normalized().signed_angle_to(to.normalized(), u)    # + = target to the left
	mech.turn_input = clampf(-ang * 4.0, -1.0, 1.0)
	mech.move_input = Vector2(0.0, 1.0 if absf(ang) < 0.6 else 0.25)


func _theta(p: Vector3) -> float:
	return stack.ring().angle(p)


func _r(p: Vector3) -> float:
	return stack.ring().dist_to_axis(p)


## Walk along x = `x` from angle th_a to th_b (around the shared axis), staying `follow_r`'s distance from the axis
## (the steering target is at the mech's own radius). `watch` is called every physics frame with the mech's (theta, r, x)
## and returns nothing; the walk ends past th_b or after `max_frames`. Returns {frames, stuck_max, done}.
func _walk_arc(x: float, th_a: float, th_b: float, max_frames: int, watch: Callable) -> Dictionary:
	var dir := signf(th_b - th_a)
	var stuck := 0
	var stuck_max := 0
	var n := 0
	var done := false
	while n < max_frames:
		var p := mech.global_position
		var th := _theta(p)
		if (th - th_b) * dir >= 0.0:
			done = true
			break
		var r := _r(p)
		_steer(sec.polar_to_world(x, th + dir * LOOK_AHEAD / r, r))
		await get_tree().physics_frame
		n += 1
		watch.call(_theta(mech.global_position), _r(mech.global_position), mech.global_position.x)
		if mech.ground_speed() < 1.0:
			stuck += 1
			stuck_max = maxi(stuck_max, stuck)
		else:
			stuck = 0
	mech.move_input = Vector2.ZERO
	mech.turn_input = 0.0
	return {"frames": n, "stuck_max": stuck_max, "done": done}


## Wait until the mech is down and still for a moment; true if it is grounded.
func _settle(max_frames: int = 180) -> bool:
	mech.move_input = Vector2.ZERO
	var on := 0
	for i in max_frames:
		await get_tree().physics_frame
		on = on + 1 if mech.grounded() else 0
		if on >= 20:
			return true
	return mech.grounded()


func _deck_h(k: int, p: Vector3) -> float:
	return sec.radius_of(k) - _r(p)


# --- The checks ------------------------------------------------------------------------------------------------

func _spawn() -> void:
	var xf := stack.spawn_transforms(1)[0]
	mech.global_transform = xf
	mech.velocity = Vector3.ZERO
	rig.gait.reset([])
	var down := await _settle()
	var k := int(sec.entry["deck"])
	var a := stack.to_deck_arc(mech.global_position)
	var av := sec.lane_x("avenue")
	check(down, "the mech is grounded at the spawn")
	eq(int(a["deck"]), k, "on the entry deck")
	check(absf(float(a["h"])) < 0.3, "standing on the road (%.2f m above the floor)" % float(a["h"]))
	check(float(a["x"]) > av.x and float(a["x"]) < av.y, "on the avenue lane (x %.1f)" % float(a["x"]))


## Down the whole ramp from its top cross line on the upper deck to past its foot on the lower deck, then back up.
func _ramp(ci: int) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var top := int(cn["from"])
	var low := int(cn["to"])
	var x0 := float(cn["x0"])
	var x1 := float(cn["x1"])
	var mid := (x0 + x1) * 0.5
	var th_top := float(sec.row_theta[int(cn["top_line"])])
	var th_foot := float(sec.row_theta[int(cn["foot_line"])])
	var down := signf(th_foot - th_top)
	var pitch := sec.p("pitch")
	var r_low := sec.radius_of(low)
	var what := "ramp %d (deck %d -> %d, %s)" % [ci, top, low, cn["lane"]]
	var th_start := th_top - down * 22.0 / sec.radius_of(top)
	var th_end := th_foot + down * 16.0 / r_low
	# The ramp's surface, as distance from the axis, at angle th (clamped to the decks at both ends).
	var surface := func(th: float) -> float:
		var t := clampf((th - th_top) / (th_foot - th_top), 0.0, 1.0)
		return r_low - pitch * (1.0 - t)
	for leg: String in ["down", "up"]:
		var a := th_start if leg == "down" else th_end
		var b := th_end if leg == "down" else th_start
		var k_from := top if leg == "down" else low
		var k_to := low if leg == "down" else top
		var tag := "%s %s" % [what, leg]
		print("start %s" % tag)
		var start := sec.polar_to_world(mid, a, sec.radius_of(k_from))
		var ahead := sec.polar_to_world(mid, a + signf(b - a) * 0.01, sec.radius_of(k_from))
		await _place(start, ahead - start)
		stack.follow(mech)
		await frames(20)
		eq(stack.active_deck, k_from, "%s: follow() makes the start deck active" % tag)
		var st := {"decks": [stack.deck_at(mech.global_position)], "below": 0.0, "above": 0.0, "x_lo": INF, "x_hi": -INF,
				"air": 0, "air_max": 0, "air_run": 0, "r_first": _r(mech.global_position), "rise": 0.0, "r_prev": _r(mech.global_position)}
		var watch := func(th: float, r: float, x: float) -> void:
			var k := stack.deck_at(mech.global_position)
			if k != int(st["decks"][-1]):
				st["decks"].append(k)
			var on_ramp := (th - th_top) * down > 0.0 and (th - th_foot) * down < 0.0
			if on_ramp:
				var srf: float = surface.call(th)
				st["below"] = maxf(float(st["below"]), r - srf)      # > 0: under the ramp's surface
				st["above"] = maxf(float(st["above"]), srf - r)      # > 0: off the surface (in the air)
				st["x_lo"] = minf(float(st["x_lo"]), x)
				st["x_hi"] = maxf(float(st["x_hi"]), x)
			# Going the wrong way in height (down: r should grow; up: shrink), summed: a blip is fine, a climb is not.
			var dr := r - float(st["r_prev"])
			st["rise"] = float(st["rise"]) + maxf(-dr if leg == "down" else dr, 0.0)
			st["r_prev"] = r
			if mech.grounded():
				st["air_run"] = 0
			else:
				st["air"] = int(st["air"]) + 1
				st["air_run"] = int(st["air_run"]) + 1
				st["air_max"] = maxi(int(st["air_max"]), int(st["air_run"]))
		var res: Dictionary = await _walk_arc(mid, a, b, 2400, watch)
		var standing := await _settle()
		var end_k := stack.deck_at(mech.global_position)
		var end_h := _deck_h(k_to, mech.global_position)
		print("%s: %d frames (%.1f s), decks %s, worst below surface %.2f m, worst above %.2f m, x %.2f..%.2f (parapets %.1f..%.1f), airborne %d frames (longest %d), stuck %d frames, wrong-way %.2f m, end h %.2f" % [
				tag, res["frames"], float(res["frames"]) / 60.0, str(st["decks"]), st["below"], st["above"], st["x_lo"], st["x_hi"],
				x0 + CityStreets.PARAPET_W, x1 - CityStreets.PARAPET_W, st["air"], st["air_max"], res["stuck_max"], st["rise"], end_h])
		check(res["done"], "%s: the mech gets to the other end (%d frames)" % [tag, res["frames"]])
		eq(st["decks"], [k_from, k_to], "%s: deck_at changes exactly once, %d -> %d" % [tag, k_from, k_to])
		check(float(st["below"]) < 0.5, "%s: never falls through the ramp (worst %.2f m under its surface)" % [tag, st["below"]])
		check(int(res["stuck_max"]) <= STUCK_FRAMES, "%s: never stuck longer than 2 s (%d frames)" % [tag, res["stuck_max"]])
		check(int(st["air_max"]) < 30, "%s: stays on the slope (longest airborne %d frames)" % [tag, st["air_max"]])
		check(float(st["rise"]) < 2.0, "%s: height changes one way overall (%.2f m the other way)" % [tag, st["rise"]])
		check(float(st["x_lo"]) > x0 + CityStreets.PARAPET_W and float(st["x_hi"]) < x1 - CityStreets.PARAPET_W,
				"%s: stays between the parapets (x %.2f..%.2f)" % [tag, st["x_lo"], st["x_hi"]])
		check(standing and end_k == k_to and absf(end_h) < 0.4, "%s: stands on deck %d's road at the end (deck %d, h %.2f)" % [tag, k_to, end_k, end_h])
		for i in 20:
			await get_tree().process_frame
		eq(stack.active_deck, k_to, "%s: follow() switched the active deck to %d" % [tag, k_to])
		check(stack.rig.sun.light_cull_mask == CityLightRig.ALWAYS | CityStack.deck_layer(k_to), "%s: and the daylight with it" % tag)


## Headroom down the whole ramp (CityPlan.BRIDGE_CLEAR): the mech's own capsule (radius, height), standing 0.3 m above
## the ramp's surface on its centre line, every 2 m from 20 m before the top line to 10 m past the foot line, touches no
## collision shape of the stack (the first cross road past the head used to bridge the cut ~7 m above the ramp: a mech
## walked through the drawn slab, whose collision is only its top 1 m). The mech itself is moved out of the way.
func _headroom(ci: int) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var mid := (float(cn["x0"]) + float(cn["x1"])) * 0.5
	var th_top := float(sec.row_theta[int(cn["top_line"])])
	var th_foot := float(sec.row_theta[int(cn["foot_line"])])
	var r_low := sec.radius_of(int(cn["to"]))
	var pitch := sec.p("pitch")
	var cap0 := (mech.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	var cap := CapsuleShape3D.new()
	cap.radius = cap0.radius
	cap.height = cap0.height
	mech.global_position = sec.polar_to_world(0.0, 0.0, 10.0)     # near the axis: out of every deck
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := mech.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.exclude = [mech.get_rid()]
	var span := absf(th_foot - th_top) * r_low
	var n := int(ceil((span + 30.0) / 2.0))
	var hits := 0
	var first := ""
	var up_k := int(cn["from"])
	var up_cuts := stack.decks[up_k].plan.floor_cuts()
	var slab_hits := 0
	var worst := 0.0
	for i in n + 1:
		var arc := -20.0 + float(i) * 2.0
		var th := th_top + signf(th_foot - th_top) * arc / r_low
		var t := clampf((th - th_top) / (th_foot - th_top), 0.0, 1.0)
		var srf := r_low - pitch * (1.0 - t)
		var foot := sec.polar_to_world(mid, th, srf - 0.3)
		var up := stack.ring().up_at(foot)
		q.transform = Transform3D(stack.ring().basis_at(foot, Vector3.RIGHT.cross(up)), foot + up * (cap.height * 0.5))
		var res := space.intersect_shape(q, 4)
		if not res.is_empty():
			hits += 1
			if first == "":
				first = "%.0f m from the top line (t %.2f)" % [arc, t]
		# The drawn slab of the upper deck (a bridge is the whole slab, `slab` deep; its collision is only the top 1 m):
		# where the upper floor is not cut over the ramp, the capsule's top must stay under the slab's bottom.
		var top_p := foot + up * cap.height
		var ua := stack.decks[up_k].ring.world_to_arc(stack.decks[up_k].to_local(top_p))
		if ua.z < 0.0 and ua.z > -sec.p("slab") - 0.01:
			var floor_cut := false
			for o in up_cuts:
				floor_cut = floor_cut or o.has_point(Vector2(mid, ua.y))
			if not floor_cut:
				slab_hits += 1
				worst = minf(worst, -sec.p("slab") - ua.z)
	print("ramp %d headroom: %d capsule poses, %d touching collision, %d inside a drawn bridge slab (worst %.2f m into it)%s" % [
			ci, n + 1, hits, slab_hits, -worst, (", first at " + first) if hits > 0 else ""])
	eq(hits, 0, "ramp %d: the mech's capsule clears every collision shape above the ramp, top to foot" % ci)
	eq(slab_hits, 0, "ramp %d: and passes under every bridge's drawn slab (worst %.2f m into it)" % [ci, -worst])


## Halfway down the ramp, strafing hard into each parapet for 2 s (walk, then run): the 1 m parapet holds the mech on
## the ribbon (the legs step up to max_step_up, 1.25 m, so this is the case to watch).
func _parapets(ci: int) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var x0 := float(cn["x0"])
	var x1 := float(cn["x1"])
	var th_top := float(sec.row_theta[int(cn["top_line"])])
	var th_foot := float(sec.row_theta[int(cn["foot_line"])])
	var r_low := sec.radius_of(int(cn["to"]))
	var pitch := sec.p("pitch")
	var cap := ((mech.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D).radius
	for t: float in [0.3, 0.7]:
		var th := lerpf(th_top, th_foot, t)
		var srf := r_low - pitch * (1.0 - t)
		var mid := (x0 + x1) * 0.5
		var at := sec.polar_to_world(mid, th, srf)
		await _place(at, sec.polar_to_world(mid, th + signf(th_foot - th_top) * 0.01, srf) - at)
		for side: float in [-1.0, 1.0]:
			var right := mech.forward().cross(mech.up())
			var sgn := signf(right.x) * side          # strafe input that moves toward x0 (side -1) or x1 (+1)
			var x_lo := INF
			var x_hi := -INF
			var worst := 0.0
			for i in 240:
				mech.move_input = Vector2(sgn, 0.0)
				mech.running = i >= 120
				mech.turn_input = 0.0
				await get_tree().physics_frame
				x_lo = minf(x_lo, mech.global_position.x)
				x_hi = maxf(x_hi, mech.global_position.x)
				worst = maxf(worst, absf(_r(mech.global_position) - (r_low - pitch * (1.0 - clampf((_theta(mech.global_position) - th_top) / (th_foot - th_top), 0.0, 1.0)))))
			mech.move_input = Vector2.ZERO
			mech.running = false
			var tag := "ramp %d at t=%.1f, strafing toward x%d" % [ci, t, 0 if side < 0.0 else 1]
			print("%s: x %.2f..%.2f (inner parapet faces %.2f / %.2f, capsule r %.1f), worst off the slope %.2f m" % [tag, x_lo, x_hi,
					x0 + CityStreets.PARAPET_W, x1 - CityStreets.PARAPET_W, cap, worst])
			check(x_lo >= x0 + CityStreets.PARAPET_W + cap - 0.2 and x_hi <= x1 - CityStreets.PARAPET_W - cap + 0.2,
					"%s: the parapet stops the mech (x %.2f..%.2f)" % [tag, x_lo, x_hi])
			check(worst < 0.6, "%s: and it stays on the ribbon (%.2f m off the slope)" % [tag, worst])
			await _place(at, sec.polar_to_world(mid, th + signf(th_foot - th_top) * 0.01, srf) - at)


## Across a cross road that bridges the ramp lane's floor hole on the ramp's upper deck: the mech stays on the deck.
func _bridge() -> void:
	var found := {}
	for k in stack.decks.size():
		var plan := stack.decks[k].plan
		var cuts := plan.floor_cuts()
		for road: Dictionary in plan.roads_s:
			for o in cuts:
				if o.size.x > 12.0 or not found.is_empty():
					continue
				# A cut that ends at this road's edge on one side and another cut that starts at its other edge.
				var before := absf(o.end.y - float(road["a"])) < 0.01
				var other := false
				for o2 in cuts:
					other = other or (absf(o2.position.y - float(road["b"])) < 0.01 and absf(o2.position.x - o.position.x) < 0.01)
				if before and other:
					found = {"deck": k, "s": (float(road["a"]) + float(road["b"])) * 0.5, "x0": o.position.x, "x1": o.end.x}
	if not check(not found.is_empty(), "the section has a cross road bridging a floor hole"):
		return
	var k: int = found["deck"]
	var s: float = found["s"]
	var tag := "bridge on deck %d at s %.1f over x %.0f..%.0f" % [k, s, found["x0"], found["x1"]]
	var xa := float(found["x0"]) - 14.0
	var xb := float(found["x1"]) + 10.0
	await _place(stack.from_deck_arc(k, xa, s, 0.0), stack.from_deck_arc(k, xb, s, 0.0) - stack.from_deck_arc(k, xa, s, 0.0))
	var lowest := 0.0
	var n := 0
	while n < 600 and float(stack.to_deck_arc(mech.global_position)["x"]) < xb:
		var a := stack.to_deck_arc(mech.global_position)
		_steer(stack.from_deck_arc(k, float(a["x"]) + LOOK_AHEAD, s, 0.0))
		await get_tree().physics_frame
		n += 1
		lowest = minf(lowest, _deck_h(k, mech.global_position))
	mech.move_input = Vector2.ZERO
	var a := stack.to_deck_arc(mech.global_position)
	print("%s: %d frames, lowest %.2f m, end x %.1f, deck %d" % [tag, n, lowest, a["x"], a["deck"]])
	check(float(a["x"]) >= xb, "%s: the mech crosses (x %.1f of %.1f)" % [tag, a["x"], xb])
	check(lowest > -0.5 and int(a["deck"]) == k, "%s: and never drops (lowest %.2f m, deck %d)" % [tag, lowest, a["deck"]])


## Off the edge of the first open-air shaft: walk from the cross road before it straight into it; the mech drops to the
## deck below (the drop link), lands and stands; follow() moves the active deck down with it.
func _shaft() -> void:
	var ci := -1
	for i in sec.connectors.size():
		if sec.connectors[i]["kind"] == "shaft" and ci < 0:
			ci = i
	if not check(ci >= 0, "the section has an open-air shaft"):
		return
	var cn: Dictionary = sec.connectors[ci]
	var k := int(cn["from"])
	var rect := sec.connector_rect(ci, k)
	var plan := stack.decks[k].plan
	# The nearest cross road edge before the shaft along -s.
	var s_road := -INF
	for road: Dictionary in plan.roads_s:
		if float(road["b"]) <= rect.position.y:
			s_road = maxf(s_road, float(road["b"]))
	var x := rect.get_center().x
	var tag := "shaft %d (deck %d -> %d)" % [ci, k, int(cn["to"])]
	var start := stack.from_deck_arc(k, x, s_road - 4.0, 0.0)
	await _place(start, stack.from_deck_arc(k, x, rect.get_center().y, 0.0) - start)
	stack.follow(mech)
	await frames(20)
	eq(stack.active_deck, k, "%s: follow() makes deck %d active" % [tag, k])
	var hard := [0.0]
	var on_hard := func(speed: float, _sev: float) -> void: hard[0] = maxf(float(hard[0]), speed)
	mech.hard_landing.connect(on_hard)
	var n := 0
	var fell := false
	while n < 900:
		var a := stack.to_deck_arc(mech.global_position)
		if int(a["deck"]) != k:
			fell = true
		if fell and mech.grounded():
			break
		_steer(stack.from_deck_arc(int(a["deck"]), x, float(a["s"]) + LOOK_AHEAD, 0.0) if not fell else mech.global_position + mech.forward())
		if fell:
			mech.move_input = Vector2.ZERO
		await get_tree().physics_frame
		n += 1
	var standing := await _settle()
	mech.hard_landing.disconnect(on_hard)
	var a := stack.to_deck_arc(mech.global_position)
	print("%s: %d frames to land, deck %d, h %.2f, last impact %.1f m/s, hard landing %.1f m/s" % [tag, n, a["deck"], a["h"], mech.last_impact, hard[0]])
	check(fell, "%s: the mech walks over the curb into the shaft and drops" % tag)
	check(standing and int(a["deck"]) == int(cn["to"]), "%s: it lands and stands on deck %d (deck %d)" % [tag, int(cn["to"]), a["deck"]])
	check(float(a["h"]) > -0.3 and float(a["h"]) < CityPlan.CURB_H + 0.5, "%s: on the floor (h %.2f)" % [tag, a["h"]])
	for i in 20:
		await get_tree().process_frame
	eq(stack.active_deck, int(cn["to"]), "%s: follow() switched the active deck down" % tag)
