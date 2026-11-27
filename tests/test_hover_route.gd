extends TestCase
## Verification of standalone 3D HoverRoute planner for Wasp (docs/design/wasp-ai.md §2, chassis-rules.md §7.2):
##   1. Same-deck over-roof direct flight (raises altitude by CLEAR_VERT over crossed roofs).
##   2. Lateral tower / pillar avoidance (never flies through full-height pillars or towers above ceiling).
##   3. Two-way multi-deck routing across real SectionPlan seeds 1..4 (both down and up, using shafts & ramps).
##   4. Pre-overheat safe landing spot (clear street or standable roof) + desired_altitude rules.


func setup() -> void:
	_test_over_roof_and_tower_avoidance()
	_test_multi_deck_two_way_routes()
	_test_safe_landing_and_altitude()
	finish()


func _test_over_roof_and_tower_avoidance() -> void:
	var sec := SectionPlan.make({"seed": 1.0})
	var plans: Array[CityPlan] = []
	for k in sec.deck_count:
		plans.append(CityPlan.for_deck(sec, k))
	var hr := HoverRoute.new()
	hr.setup_plans(sec, plans)
	var p0 := plans[0]

	# 1. Pick a low/mid-rise non-pillar building on deck 0 and verify clear_altitude clears its roof directly!
	var tested_over := false
	for b: Dictionary in p0.buildings:
		if bool(b.get("pillar", false)):
			continue
		var tiers: Array = b.get("tiers", [])
		if tiers.is_empty():
			continue
		var top_h := float((tiers[tiers.size() - 1] as Dictionary)["y1"]) + CityPlan.CURB_H
		if top_h + HoverRoute.CLEAR_VERT > hr.ceiling:
			continue
		var c: Vector2 = b["center"]
		var a := c + Vector2(-24.0, 0.0)
		var g := c + Vector2(24.0, 0.0)
		var alt := hr.clear_altitude(0, a, g, HoverRoute.CRUISE_ALT)
		if alt > 0.0:
			check(alt >= top_h + HoverRoute.CLEAR_VERT - 0.01,
				"over-roof flight clears building roof (alt=%.1f >= top+clear=%.1f)" % [alt, top_h + HoverRoute.CLEAR_VERT])
			var route := hr.plan(0, a, 0, g, HoverRoute.CRUISE_ALT)
			eq(route.size(), 1, "clear over-roof segment uses a single direct leg")
			tested_over = true
			break
	check(tested_over, "verified direct over-roof clearance on seed 1 deck 0")

	# 2. Pick a full-height pillar building and verify clear_altitude rejects it and plan() routes cleanly around it!
	var tested_pillar := false
	for b: Dictionary in p0.buildings:
		if not bool(b.get("pillar", false)):
			continue
		var core: Dictionary = b["core"]
		var cc := Vector2(float(core["x"]), float(core["s"]))
		var a := cc + Vector2(-36.0, 0.0)
		var g := cc + Vector2(36.0, 0.0)
		if not p0.extent.grow(-8.0).has_point(a) or not p0.extent.grow(-8.0).has_point(g):
			continue
		check(hr.clear_altitude(0, a, g) < 0.0, "direct segment through full-height pillar is rejected (-1)")
		var route := hr.plan(0, a, 0, g)
		check(route.size() >= 2, "plan() routes around full-height pillar in >= 2 legs (got %d)" % route.size())
		# Every planned same-deck fly leg must clear all tall obstacles!
		var prev := a
		for wp: Dictionary in route:
			var nxt: Vector2 = wp["arc"]
			check(hr.clear_altitude(0, prev, nxt, HoverRoute.CRUISE_ALT) > 0.0 or prev.distance_to(nxt) < 1.0,
				"planned pillar-avoidance leg clears tall obstacles")
			prev = nxt
		tested_pillar = true
		break
	check(tested_pillar, "verified full-height pillar lateral avoidance on seed 1 deck 0")


func _test_multi_deck_two_way_routes() -> void:
	var saw_shaft_up := false
	var saw_shaft_down := false
	for s_val in [1, 2, 3, 4]:
		var sec := SectionPlan.make({"seed": float(s_val)})
		var plans: Array[CityPlan] = []
		for k in sec.deck_count:
			plans.append(CityPlan.for_deck(sec, k))
		var hr := HoverRoute.new()
		hr.setup_plans(sec, plans)
		var a0 := SectionEncounters.arrival(sec, 0)
		var p_top := Vector2(float(a0["x"]), float(a0["s"]))
		var last_k := sec.deck_count - 1
		var al := SectionEncounters.arrival(sec, last_k)
		var p_bot := Vector2(float(al["x"]), float(al["s"]))

		# Down: deck 0 -> bottom deck.
		var down := hr.plan(0, p_top, last_k, p_bot)
		check(not down.is_empty(), "seed %d: hover route found from deck 0 down to deck %d (%d wps)" % [s_val, last_k, down.size()])
		if not down.is_empty():
			eq(int(down[down.size() - 1]["deck"]), last_k, "seed %d: down route arrives on deck %d" % [s_val, last_k])
			for wp: Dictionary in down:
				if str(wp["kind"]) == "shaft_down":
					saw_shaft_down = true

		# Up: bottom deck -> deck 0 (flying Wasp can climb shafts & ramps upward!).
		var up_r := hr.plan(last_k, p_bot, 0, p_top)
		check(not up_r.is_empty(), "seed %d: hover route found from deck %d up to deck 0 (%d wps)" % [s_val, last_k, up_r.size()])
		if not up_r.is_empty():
			eq(int(up_r[up_r.size() - 1]["deck"]), 0, "seed %d: up route arrives on deck 0" % s_val)
			for wp: Dictionary in up_r:
				if str(wp["kind"]) == "shaft_up":
					saw_shaft_up = true

	check(saw_shaft_down or saw_shaft_up, "multi-seed routes exercised vertical shaft transit (down=%s up=%s)" % [
		str(saw_shaft_down), str(saw_shaft_up)])


func _test_safe_landing_and_altitude() -> void:
	var sec := SectionPlan.make({"seed": 1.0})
	var plans: Array[CityPlan] = []
	for k in sec.deck_count:
		plans.append(CityPlan.for_deck(sec, k))
	var hr := HoverRoute.new()
	hr.setup_plans(sec, plans)
	var a0 := SectionEncounters.arrival(sec, 0)
	var street_pt := Vector2(float(a0["x"]), float(a0["s"]))

	var spot := hr.safe_landing_spot(0, street_pt)
	check(bool(spot["found"]), "safe_landing_spot finds a valid landing point near arrival")
	check(str(spot["kind"]) in ["street", "roof"], "landing spot kind is street or roof (%s)" % str(spot["kind"]))

	# Normal flight holds requested altitude; pre-overheat (>= 0.78) descends toward landing surface; fan-loss = 0.0.
	var normal_alt := hr.desired_altitude(0, street_pt, 16.0, 0.30, true)
	near(normal_alt, 16.0, 0.01, "cool Wasp holds desired combat altitude 16 m")
	var hot_alt := hr.desired_altitude(0, street_pt, 16.0, 0.82, true)
	check(hot_alt < 8.0, "pre-overheat Wasp (heat 0.82) descends toward safe surface (alt=%.1f m)" % hot_alt)
	var downed_alt := hr.desired_altitude(0, street_pt, 16.0, 0.20, false)
	near(downed_alt, 0.0, 0.01, "Wasp with < 3 working fans (can_fly=false) commands 0 m altitude")
