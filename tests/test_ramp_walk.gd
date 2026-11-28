extends TestCase
## RAMP ENDS ON THE PLAN'S SLOPE RUN (R2.17, 2026-11-27; docs/design/city-spine.md "Ramp ends"). The plan fits every
## ramp's slope inside its whole-row span, clear of the junction boxes (SectionPlan connector run_top / run_foot); the
## floor cut, the drawn ribbon and the collision must all start and end there, or the ramp's mouth is a lip in the floor
## slab (the bug: CityPlan sloped from the cross line centre while the cut started at the run: a strider never got back
## onto deck 0, tests/test_wave_pursuit). On the real stack of section seeds 1, 2, 4, 9, for every ramp:
## - data: every CityPlan ramp part carries the plan's run (sec.ramp_run), its top part's s_top is the floor cut's open
##   mouth edge, the bottom part's s_foot the run's foot, the drawn ribbon (CityStreets.ramp_span) ends there, and both
##   ends lie outside every junction box (the metres past the box are printed);
## - physics, no lip / no gap: rays down the lane's centre line across the mouth (upper deck) and the foot (lower deck)
##   hit the floor (h 0) before the run and the ramp's own surface on it, everywhere within 0.15 m;
## - physics, walking: a real Strider and a real Bulwark (MechSpawn: MechController, capsule, step-up; stepped by hand,
##   deterministic) walk from 20 m before the mouth on the upper deck down the ramp to 16 m past its foot on the lower deck,
##   and back up: they get there, are never stuck 2 s, never sink under the slope, change deck exactly once.

const SEEDS := [1, 2, 4, 9]
const DT := 1.0 / 60.0
const LOOK_AHEAD := 12.0
const STUCK_STEPS := 120
const MAX_STEPS := 7200
const PROFILE_TOL := 0.15

var stack: CityStack
var sec: SectionPlan
var min_clear := INF
var legs := 0


func _init() -> void:
	timeout_sec = 600.0


func setup() -> void:
	for seed_: int in SEEDS:
		await _section(seed_)
	print("[ramp_walk] %d legs walked; slope ends at least %.2f m past the nearest junction box" % [legs, min_clear])
	check(legs >= 16, "enough ramp legs walked (%d)" % legs)
	finish()


func _section(seed_: int) -> void:
	sec = SectionPlan.make({"seed": seed_})
	stack = CityStack.new()
	add_child(stack)
	stack.build(sec)
	for d in stack.decks:
		d.props.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for ci in sec.connectors.size():
		if sec.connectors[ci]["kind"] != "ramp":
			continue
		_data(seed_, ci)
		_profile(seed_, ci)
	for chassis: String in ["strider", "bulwark"]:
		var m := MechSpawn.make("chicken", chassis)
		add_child(m)
		await get_tree().physics_frame
		m.set_physics_process(false)
		m.ring = stack.ring()
		for ci in sec.connectors.size():
			if sec.connectors[ci]["kind"] == "ramp":
				_walk(seed_, ci, m, chassis)
		m.queue_free()
		await get_tree().physics_frame
	stack.queue_free()
	await frames(2)


func _part(k: int, ci: int, role: String) -> Dictionary:
	for r: Dictionary in stack.decks[k].plan.ramps:
		if int(r["connector"]) == ci and r["role"] == role:
			return r
	return {}


## Distance from s to the nearest junction box on deck k's plan (negative inside one).
func _box_clear(plan: CityPlan, s: float) -> float:
	var clear := INF
	for cr: Dictionary in plan.roads_s:
		clear = minf(clear, maxf(float(cr["a"]) - s, s - float(cr["b"])))
	return clear


func _data(seed_: int, ci: int) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var top := int(cn["from"])
	var low := int(cn["to"])
	var tag := "seed %d ramp %d (deck %d -> %d)" % [seed_, ci, top, low]
	var pt := _part(top, ci, "top")
	var pb := _part(low, ci, "bottom")
	if not check(not pt.is_empty() and not pb.is_empty(), "%s: both parts on their decks" % tag):
		return
	var plan_t := stack.decks[top].plan
	var plan_b := stack.decks[low].plan
	var run_t := sec.ramp_run(ci, top)
	var run_b := sec.ramp_run(ci, low)
	near(float(pt["run_top"]), run_t.x, 1e-3, "%s: the top part carries the plan's run start" % tag)
	near(float(pt["run_foot"]), run_t.y, 1e-3, "%s: and its foot" % tag)
	near(float(pb["run_foot"]), run_b.y, 1e-3, "%s: the bottom part carries the plan's run foot" % tag)
	near(float(pt["s_top"]), run_t.x, 1e-3, "%s: the slope starts at the run's top" % tag)
	near(float(pb["s_foot"]), run_b.y, 1e-3, "%s: and lands at the run's foot" % tag)
	# The floor cut's open mouth edge is the slope's start.
	var mouth := INF
	for o in plan_t.floor_cuts():
		if absf(o.position.x - float(cn["x0"])) > 0.01 or absf(o.end.x - float(cn["x1"])) > 0.01:
			continue
		if plan_t.ramp_mouth(o) >= 0:
			mouth = o.end.y if plan_t.ramp_mouth(o) == 2 else o.position.y
	near(mouth, float(pt["s_top"]), 0.01, "%s: the floor cut opens exactly where the slope starts" % tag)
	var drawn_t := CityStreets.ramp_span(pt, plan_t.site.slab, true)
	var drawn_b := CityStreets.ramp_span(pb, plan_b.site.slab, true)
	check(absf(drawn_t.x - float(pt["s_top"])) < 1e-3 or absf(drawn_t.y - float(pt["s_top"])) < 1e-3, "%s: the drawn ribbon starts at the mouth" % tag)
	check(absf(drawn_b.x - float(pb["s_foot"])) < 1e-3 or absf(drawn_b.y - float(pb["s_foot"])) < 1e-3, "%s: and ends at the foot" % tag)
	var ct := _box_clear(plan_t, float(pt["s_top"]))
	var cf := _box_clear(plan_b, float(pb["s_foot"]))
	print("%s: slope ends %.2f m past the top box, %.2f m short of the foot box" % [tag, ct, cf])
	min_clear = minf(min_clear, minf(ct, cf))
	check(ct > 0.5 and cf > 0.5, "%s: both slope ends lie outside the junction boxes (%.2f / %.2f m)" % [tag, ct, cf])


## Rays down the lane's centre across one end: floor (h 0) outside the run, the ramp's surface on it.
func _profile(seed_: int, ci: int) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var mid := (float(cn["x0"]) + float(cn["x1"])) * 0.5
	var space := get_viewport().world_3d.direct_space_state
	for end: String in ["mouth", "foot"]:
		var k := int(cn["from"]) if end == "mouth" else int(cn["to"])
		var r := _part(k, ci, "top" if end == "mouth" else "bottom")
		if r.is_empty():
			continue
		var d := stack.decks[k]
		var edge := float(r["s_top"]) if end == "mouth" else float(r["s_foot"])
		var inward := signf(float(r["s_foot"]) - float(r["s_top"])) * (1.0 if end == "mouth" else -1.0)   # into the run
		var worst := 0.0
		var where := ""
		for i in 41:
			var off := -6.0 + float(i) * 0.4      # < 0: outside the run
			if absf(off) < 0.3:
				continue
			var s := edge + inward * off
			var from := stack.from_deck_arc(k, mid, s, 6.0)
			var to := stack.from_deck_arc(k, mid, s, -12.0)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
			var want := 0.0 if off < 0.0 else CityPlan.ramp_height(r, s)
			var got := -INF
			if not hit.is_empty():
				got = d.ring.world_to_arc(d.to_local(hit["position"])).z
			if absf(got - want) > worst:
				worst = absf(got - want)
				where = "%.1f m %s the run (h %.2f, want %.2f)" % [absf(off), "inside" if off > 0.0 else "before", got, want]
		check(worst <= PROFILE_TOL, "seed %d ramp %d %s on deck %d: the solid surface follows floor then slope, no lip or gap (worst %.2f m at %s)" % [
				seed_, ci, end, k, worst, where])


func _walk(seed_: int, ci: int, m: MechController, chassis: String) -> void:
	var cn: Dictionary = sec.connectors[ci]
	var top := int(cn["from"])
	var low := int(cn["to"])
	var mid := (float(cn["x0"]) + float(cn["x1"])) * 0.5
	var th_top := float(cn["run_top"])
	var th_foot := float(cn["run_foot"])
	var down := signf(th_foot - th_top)
	var pitch := sec.p("pitch")
	var r_low := sec.radius_of(low)
	var th_start := th_top - down * 20.0 / sec.radius_of(top)
	var th_end := th_foot + down * 16.0 / r_low
	var rf := stack.ring()
	for leg: String in ["down", "up"]:
		var a := th_start if leg == "down" else th_end
		var b := th_end if leg == "down" else th_start
		var k_from := top if leg == "down" else low
		var k_to := low if leg == "down" else top
		var tag := "seed %d ramp %d %s %s" % [seed_, ci, chassis, leg]
		var dir := signf(b - a)
		var p0 := sec.polar_to_world(mid, a, sec.radius_of(k_from) - 0.3)
		var u := rf.up_at(p0)
		var fwd := sec.polar_to_world(mid, a + dir * 0.01, sec.radius_of(k_from)) - sec.polar_to_world(mid, a, sec.radius_of(k_from))
		m.global_transform = Transform3D(rf.basis_at(p0, fwd), p0)
		m.velocity = Vector3.ZERO
		m.move_input = Vector2.ZERO
		m.turn_input = 0.0
		m.heat = 0.0
		for i in 10:
			m.step(DT)
		var decks := [stack.deck_at(m.global_position)]
		var below := 0.0
		var stuck := 0
		var stuck_max := 0
		var done := false
		var n := 0
		while n < MAX_STEPS:
			var p := m.global_position
			var th := rf.angle(p)
			if (th - b) * dir >= 0.0:
				done = true
				break
			var r := rf.dist_to_axis(p)
			var target := sec.polar_to_world(mid, th + dir * LOOK_AHEAD / r, r)
			var up := rf.up_at(p)
			var to := target - p
			to -= up * to.dot(up)
			m.global_basis = rf.basis_at(p, to)
			m.move_input = Vector2(0, 1)
			m.heat = 0.0
			m.step(DT)
			n += 1
			var k := stack.deck_at(m.global_position)
			if k != int(decks[-1]):
				decks.append(k)
			var th2 := rf.angle(m.global_position)
			if (th2 - th_top) * down > 0.0 and (th2 - th_foot) * down < 0.0:
				var srf := r_low - pitch * (1.0 - (th2 - th_top) / (th_foot - th_top))
				below = maxf(below, rf.dist_to_axis(m.global_position) - srf)
			if m.ground_speed() < 1.0:
				stuck += 1
				stuck_max = maxi(stuck_max, stuck)
			else:
				stuck = 0
		m.move_input = Vector2.ZERO
		legs += 1
		var end_k := stack.deck_at(m.global_position)
		var end_h := sec.radius_of(k_to) - rf.dist_to_axis(m.global_position)
		print("%s: %d steps, decks %s, worst under the slope %.2f m, stuck %d, end deck %d h %.2f" % [tag, n, str(decks), below, stuck_max, end_k, end_h])
		check(done, "%s: gets to the other end (%d steps, stopped at deck %d h %.2f)" % [tag, n, end_k, end_h])
		eq(decks, [k_from, k_to], "%s: deck changes exactly once" % tag)
		check(stuck_max <= STUCK_STEPS, "%s: never stuck 2 s (%d steps)" % [tag, stuck_max])
		check(below < 0.5, "%s: never under the slope (%.2f m)" % [tag, below])
