extends TestCase
## The cross roads that bridge a ramp's cut in the floor of the deck it leaves (docs/design/city-ramps-and-stack.md,
## "Bridges over a ramp"). A bridge is the full slab (its underside `slab` m under the road); the ramp passes under it.
## Rule (CityPlan.BRIDGE_CLEAR): no bridge where the clear height between the ramp's surface and the bridge's underside,
## along the ramp's centre line, is under a mech's height + 1.5 m. The first cross road past the ramp's head always
## breaks it (about 7 m: a mech walked through the drawn slab), so the cut runs on under it and that road ends at the
## cut's curb and railing on both sides. For section seeds 1-8, every ramp, both directions along the arc:
##   - every cross road over the cut that is still a bridge has the clearance, every removed one lacks it;
##   - the road graph (CityPlan.road_graph: enemies, bots) has no edge across a floor cut;
##   - the removed road's ends get the cut's curb on both sides (the long sides of the merged cut), and the plan's
##     clear_at() is false on the removed stretch (props, spawns, life stay off it).
## Prints the clearance table.

const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8]


func setup() -> void:
	var rows := 0
	var removed := 0
	var dirs := {}
	print("[bridges] seed deck ramp dir line  from_head_m  clear_m  bridge")
	for seed_: int in SEEDS:
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var cuts := plan.floor_cuts()
			for r: Dictionary in plan.ramps:
				if r["role"] != "top":
					continue
				var ci := int(r["connector"])
				var hole := sec.connector_rect(ci, k)
				var top := float(r["s_top"])
				var down := signf(float(r["s_foot"]) - top)
				dirs[down] = true
				var mid := (float(r["x0"]) + float(r["x1"])) * 0.5
				for j in plan.roads_s.size():
					var road: Dictionary = plan.roads_s[j]
					var a := float(road["a"])
					var b := float(road["b"])
					var c := (a + b) * 0.5
					if c <= hole.position.y + 1.0 or c >= hole.end.y - 1.0 or absf(c - top) < 1.0:
						continue      # not over the cut (the head's own cross road is the ramp's mouth)
					var near := a if down > 0.0 else b
					var clear := CityPlan.bridge_clearance(r, near, plan.site.slab)
					var bridged := true
					for o in cuts:
						if o.has_point(Vector2(mid, c)):
							bridged = false
					rows += 1
					print("[bridges] %4d %4d %4d %3d %4d %11.1f %8.2f  %s" % [seed_, k, ci, int(down), j, absf(near - top), clear,
							"yes" if bridged else "REMOVED"])
					if bridged:
						check(clear >= CityPlan.BRIDGE_CLEAR, "seed %d deck %d ramp %d: the bridge at line %d has %.2f m under it (< %.1f)" % [
								seed_, k, ci, j, clear, CityPlan.BRIDGE_CLEAR])
					else:
						removed += 1
						check(clear < CityPlan.BRIDGE_CLEAR, "seed %d deck %d ramp %d: line %d removed though %.2f m clear" % [seed_, k, ci, j, clear])
						check(not plan.clear_at(Vector2(mid, c)), "nothing may stand on the removed stretch")
						# The road ends at the cut's long sides: the curb runs on along x0 - curb and x1 + curb there.
						var on_curb := false
						for o in cuts:
							if o.has_point(Vector2(mid, c)) and o.position.y < a and o.end.y > b:
								on_curb = true
						check(on_curb, "seed %d line %d: the cut runs on under the removed road (its curb lines both ends)" % [seed_, j])
			_graph_clear_of_cuts(plan, cuts, seed_, k)
	print("[bridges] %d cross roads over ramp cuts, %d removed" % [rows, removed])
	check(rows > 0, "the section seeds have ramps")
	check(removed > 0, "the first bridge past a ramp's head is removed")
	check(dirs.size() == 2, "ramps run both ways along the arc in seeds 1-8")
	finish()


## No edge of the road graph crosses the inside of a floor cut (an edge may run along a cut's edge: a ramp's mouth).
func _graph_clear_of_cuts(plan: CityPlan, cuts: Array[Rect2], seed_: int, k: int) -> void:
	var g := CityGraphs.road_graph(plan)
	for ed: Array in g["edges"]:
		var p: Vector2 = g["nodes"][int(ed[0])]
		var q: Vector2 = g["nodes"][int(ed[1])]
		for o in cuts:
			var inner := o.grow(-0.5)
			if inner.size.x <= 0.0 or inner.size.y <= 0.0:
				continue
			var n := maxi(int(ceil(p.distance_to(q))), 1)
			var hit := false
			for i in n + 1:
				if inner.has_point(p.lerp(q, float(i) / float(n))):
					hit = true
					break
			if hit:
				check(false, "seed %d deck %d: road graph edge %s-%s crosses a floor cut %s" % [seed_, k, str(p), str(q), str(o)])
