extends TestCase
## BULKHEAD DOORS FIT THE 40 m SPINE (R2.11a, docs/design/city-spine.md "As built: bulkhead doors"; plan data only). On
## the real section plan (spine ramp_a 10 | avenue 14 | rail 6 | ramp_b 10) of seeds 1..30, on deck 0's two arc-end walls
## (road door + tram door 1.7 m apart) and the exit deck's: for every road door (MissionWorld.door_fit, plan_bay_span,
## MissionGateDoor.leaf_pose):
## - open, both leaves stand wholly beside the clear opening (inside the wall);
## - the leaves' pocket (open leaves) never crosses another gate's opening or a tram tunnel with its plates;
## - its bunker frame stops at the middle between two openings that would overlap (reach), and the sign pier, if any,
##   stands on a side with room;
## - its staging bay (interior + PLATE) stays clear of every tram tunnel (with its plates) and of the deck's corners, is at
##   least BAY_MIN_W wide (20 m clear after MARGIN) and holds four Bulwark (r 3.6) stand slots (MissionWorld.slot_layout)
##   that each walk out along their facing clear of the door's frame and throat;
## - the wall's gates: one road door per spine end, a tram door in both deck-0 arc-end walls, none doubled.

const SEEDS := 30
const BULWARK_R := 3.6

var doors := 0
var merged := 0
var worst_clear := INF


func setup() -> void:
	for seed_ in range(1, SEEDS + 1):
		var sec := SectionPlan.make({"seed": seed_})
		var exit_k := sec.deck_count - 1
		var ks := [0] if exit_k == 0 else [0, exit_k]
		for k: int in ks:
			_deck(seed_, sec, k)
	print("[door_fit] %d road doors checked, %d beside a tram door; worst slot walk-out clearance %.2f m (Bulwark r %.1f)" % [doors, merged, worst_clear, BULWARK_R])
	check(doors > 60, "enough road doors (%d)" % doors)
	check(merged >= SEEDS, "every deck 0 entry door (and every s1 spine door not collapsed) stands beside its tram door (%d)" % merged)
	finish()


func _deck(seed_: int, sec: SectionPlan, k: int) -> void:
	var plan := CityPlan.for_deck(sec, k)
	var e := plan.extent
	for w: Dictionary in plan.boundary():
		var side := int(w["side"])
		if side < 2:
			continue
		var tag := "seed %d deck %d side %d" % [seed_, k, side]
		var gates: Array = w["gates"]
		var trams := gates.filter(func(g: Dictionary) -> bool: return str(g["kind"]) == "tram_door")
		eq(trams.size(), 1 if k == 0 else 0, "%s: %s tram door in this arc-end wall" % [tag, "one" if k == 0 else "no"])
		var spine_x := sec.lane_x("avenue")
		var on_avenue := gates.filter(func(g: Dictionary) -> bool:
			var m := (float(g["a"]) + float(g["b"])) * 0.5
			return str(g["kind"]) != "tram_door" and m > spine_x.x and m < spine_x.y)
		eq(on_avenue.size(), 1, "%s: exactly one road door on the spine's main road" % tag)
		for g: Dictionary in gates:
			if str(g["kind"]) != "blast_door":
				continue
			doors += 1
			_door(tag, plan, w, g, trams, e)


func _door(tag: String, plan: CityPlan, w: Dictionary, g: Dictionary, trams: Array, e: Rect2) -> void:
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	var ch := CityWalls.clear_half(g)
	var sx := MissionWorld._u_to_x(int(w["side"]))
	var fit := MissionWorld.door_fit(w, g)
	var door := MissionGateDoor.new()
	door.half = ch
	door.slide = int(fit["slide"])
	var tag2 := "%s door at %.1f (slide %d, pier %d)" % [tag, mid, door.slide, int(fit["pier"])]
	# Open leaves in wall u (each leaf `half` wide, centred on its pose's x in frame X).
	var leaves: Array[Vector2] = []
	for lp: Array in door.leaf_pose(1.0):
		var xc := float(lp[0])
		var u0 := mid + sx * (xc - ch * 0.5)
		var u1 := mid + sx * (xc + ch * 0.5)
		leaves.append(Vector2(minf(u0, u1), maxf(u0, u1)))
	for lv in leaves:
		check(lv.y <= mid - ch + 1e-3 or lv.x >= mid + ch - 1e-3, "%s: an open leaf (%.2f..%.2f) is clear of the opening (%.2f..%.2f)" % [
				tag2, lv.x, lv.y, mid - ch, mid + ch])
	var near_tram := false
	for g2: Dictionary in w["gates"]:
		if is_equal_approx(float(g2["a"]), float(g["a"])):
			continue
		var tram := str(g2["kind"]) == "tram_door"
		var pad := CityWalls.TUNNEL_PLATE if tram else 0.0
		var o := Vector2(float(g2["a"]) - pad, float(g2["b"]) + pad)
		for lv in leaves:
			check(lv.y <= o.x + 1e-3 or lv.x >= o.y - 1e-3, "%s: an open leaf (%.2f..%.2f) stays out of the %s at %.2f..%.2f" % [
					tag2, lv.x, lv.y, "tram tunnel" if tram else "next opening", o.x, o.y])
		if tram and absf((float(g2["a"]) + float(g2["b"])) * 0.5 - mid) < 20.0:
			near_tram = true
	if near_tram:
		merged += 1
		check(int(fit["slide"]) != 0, "%s: beside the tram door both leaves slide to the free side" % tag2)
		check(min(float(fit["reach_lo"]), float(fit["reach_hi"])) < INF, "%s: its frame and the tram door's meet as one pier" % tag2)
	# The staging bay (only a road door with a bay: every blast_door on an arc-end wall).
	var sp := MissionWorld.plan_bay_span(plan, w, g)
	var plate := MissionGateDoor.PLATE
	var b0 := mid + sp.x - plate          # plan_bay_span is in wall u, relative to mid-gate
	var b1 := mid + sp.y + plate
	check(sp.y - sp.x >= MissionGateDoor.BAY_MIN_W - 1e-3, "%s: the bay is %.2f m wide inside (>= %.0f)" % [tag2, sp.y - sp.x, MissionGateDoor.BAY_MIN_W])
	check(b0 >= e.position.x + 2.0 - 1e-3 and b1 <= e.end.x - 2.0 + 1e-3, "%s: the bay (%.2f..%.2f) stays 2 m inside the deck (%.2f..%.2f)" % [
			tag2, b0, b1, e.position.x, e.end.x])
	for t: Dictionary in trams:
		var o := Vector2(float(t["a"]) - CityWalls.TUNNEL_PLATE, float(t["b"]) + CityWalls.TUNNEL_PLATE)
		check(b1 <= o.x + 1e-3 or b0 >= o.y - 1e-3, "%s: the bay with its plates (%.2f..%.2f) misses the tram tunnel (%.2f..%.2f)" % [
				tag2, b0, b1, o.x, o.y])
	# Four slots (MissionWorld.slot_layout, laid out for the Bulwark's r 3.6): inside the usable bay, 7.2 m apart, each
	# walking out along its facing (straight, or aimed at a door-plane point) clear of the frame and the throat.
	var lay := MissionWorld.slot_layout(sp.x if sx > 0.0 else -sp.y, sp.y if sx > 0.0 else -sp.x, ch, ch + 0.6, 4)
	var ux0 := (sp.x if sx > 0.0 else -sp.y) + MissionGateDoor.MARGIN
	var ux1 := (sp.y if sx > 0.0 else -sp.x) - MissionGateDoor.MARGIN
	for a in lay.size():
		var sl: Dictionary = lay[a]
		var x := float(sl["x"])
		var dep := float(sl["depth"])
		check(x - BULWARK_R >= ux0 - 1e-3 and x + BULWARK_R <= ux1 + 1e-3, "%s: slot %d at x %.2f fits a Bulwark in the usable bay %.2f..%.2f" % [tag2, a, x, ux0, ux1])
		check(dep - BULWARK_R >= MissionGateDoor.USE_FROM - 1e-3 and dep + BULWARK_R <= MissionGateDoor.BAY_DEPTH - MissionGateDoor.MARGIN + 1e-3, "%s: slot %d's row %.1f fits the bay's depth (MARGIN off its back wall)" % [tag2, a, dep])
		for b in a:
			var o: Dictionary = lay[b]
			check(Vector2(x, dep).distance_to(Vector2(float(o["x"]), float(o["depth"]))) >= 2.0 * BULWARK_R - 1e-3, "%s: slots %d / %d keep two Bulwarks apart" % [tag2, a, b])
		check(float(sl["clear"]) >= BULWARK_R, "%s: slot %d (x %.2f, row %.1f, aim %s) walks out %.2f m clear of the jambs and throat (a Bulwark needs %.1f)" % [
				tag2, a, x, dep, "-" if is_nan(float(sl["aim"])) else "%.2f" % float(sl["aim"]), float(sl["clear"]), BULWARK_R])
		worst_clear = minf(worst_clear, float(sl["clear"]))
	door.free()
