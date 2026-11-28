class_name CityDims
extends RefCounted
## The city's GAMEPLAY dimensions that the plans (CityPlan, which is checksummed; LifePlan; LifeTraffic; CityGraphs) and
## the meshers (CityStreets, CityWalls, CityBuildings) share: what a mech walks round and what a cut is snapped to. The
## meshers draw with these numbers and the plans keep things clear by them, so both read them here and a plan never
## reaches into a mesh builder. Plain constants and pure functions: no state, no randomness.

const EDGE := 1.6            ## a block's curb + furnishing band (the sidewalk's outer strip)
const HOLE_CURB := 0.5       ## curb round a floor hole: this wide and this high, solid

# --- Ceiling grid (docs/design/ceiling-and-pillars.md) -----------------------------------------------------------
# The underside of the deck above is a regular grid: girders along the arc every GIRDER_PITCH, ribs across every
# RIB_PITCH, panels of half a bay each way. An opening in the deck above is cut back to whole panels (ceiling_opening).
const RIB_PITCH := 24.0
const GIRDER_PITCH := 14.0
const PANEL_X := GIRDER_PITCH * 0.5
const PANEL_S := RIB_PITCH * 0.5
const DROP_PANEL := 5.0      ## how far a pillar's drop panel reaches past its core
const RIM := 1.6             ## width of the beam around an opening


## An opening snapped outward to whole ceiling panels: what is actually cut.
static func ceiling_opening(o: Rect2) -> Rect2:
	var x0 := floorf(o.position.x / PANEL_X) * PANEL_X
	var s0 := floorf(o.position.y / PANEL_S) * PANEL_S
	return Rect2(x0, s0, ceilf(o.end.x / PANEL_X) * PANEL_X - x0, ceilf(o.end.y / PANEL_S) * PANEL_S - s0)


# --- The spine's main road (docs/design/city-spine.md sections 2 and 3) ------------------------------------------
# Right-hand traffic, one lane each way: a car going +s drives in the -x half. The split is derived from the avenue lane's
# width (SectionPlan.lane_x("avenue")), so the same code is right at 18 m (today's plan) and 14 m (the 40 m spine):
#   | AV_EDGE | lane | centre strip | lane | AV_EDGE |
# the width between the edges split 1 : 1 : 1, the lanes capped at AV_LANE_MAX (the surplus goes to the centre strip):
#   14 m -> 1 | 4 | 4 | 4 | 1        18 m -> 1 | 4.5 | 7 | 4.5 | 1
# CityStreets draws its lines, stop lines and arrows from it and LifeTraffic drives the avenue pods on its lane centres,
# so the paint and the traffic cannot drift apart.
const AV_EDGE := 1.0
const AV_LANE_MAX := 4.5
const AV_MEDIAN_MAX := 3.0      ## the planted median's width (at most; 0.5 m of paint either side in the centre strip)
const AV_POCKET := 28.0         ## the centre strip is a left-turn pocket for this long before each junction box
const MEDIAN_CLEAR := 0.5


const ZEBRA_AT := 1.8           ## a spine (and street) zebra lies ZEBRA_AT .. ZEBRA_AT + ZEBRA_D off the junction box
const ZEBRA_D := 3.0
const TRAM_DECK := 0                ## the one deck with tram track (city-spine.md section 5)


## Whether this deck's tram strip carries track: the tram deck only, and only where the plan calls the strip "rail"
## (Missions' plan change names the strips of the other decks "verge"; a lane without a kind is "rail", as today).
static func has_track(plan: CityPlan) -> bool:
	if plan.section == null or plan.deck != TRAM_DECK:
		return false
	for r: Dictionary in plan.roads_x:
		if r["kind"] == "spine":
			for l: Dictionary in r["lanes"]:
				if str(l["lane"]) == "rail":
					return str(l.get("kind", "rail")) == "rail"
	return false


## The main road's split across avenue-lane width w: {edge, lane, centre}.
static func avenue_split(w: float) -> Dictionary:
	var rest := maxf(w - 2.0 * AV_EDGE, 0.0)
	var lane := minf(rest / 3.0, AV_LANE_MAX)
	return {"edge": AV_EDGE, "lane": lane, "centre": rest - 2.0 * lane}


## x of the two lane centres of the main road on av (x0, x1): (the +s lane, in the -x half; the -s lane, in the +x half).
static func avenue_lanes(av: Vector2) -> Vector2:
	var sp := avenue_split(av.y - av.x)
	var off := float(sp["edge"]) + float(sp["lane"]) * 0.5
	return Vector2(av.x + off, av.y - off)


## The planted median of the main road on spine segment v0..v1 (between two junction boxes) as a Rect2, or an empty Rect2
## where the two left-turn pockets leave no room. Prop layout and prop physics read it (CityPropLayout, CityPropSim).
static func avenue_median(av: Vector2, v0: float, v1: float) -> Rect2:
	var sp := avenue_split(av.y - av.x)
	var w := minf(float(sp["centre"]) - 2.0 * MEDIAN_CLEAR, AV_MEDIAN_MAX)
	var m0 := v0 + AV_POCKET
	var m1 := v1 - AV_POCKET
	if w <= 0.5 or m1 - m0 < 6.0:
		return Rect2()
	var mid := (av.x + av.y) * 0.5
	return Rect2(mid - w * 0.5, m0, w, m1 - m0)


## The planted verge of the tram strip a..b on spine segment v0..v1 (a deck without track), or an empty Rect2: clear of
## the zebras and stop lines at both ends (the walkers cross there).
static func verge_rect(a: float, b: float, v0: float, v1: float) -> Rect2:
	var s0 := v0 + 7.0
	var s1 := v1 - 7.0
	if s1 - s0 < 6.0:
		return Rect2()
	return Rect2(a + 0.5, s0, b - a - 1.0, s1 - s0)


## Every raised planted strip on the spine of this deck (medians, verges: curb high, no collision), for the props that
## stand or lie on them (CityPropLayout, CityPropSim). [] off a section.
static func spine_planted(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if plan.section == null:
		return out
	var av := plan.section.lane_x("avenue")
	var rail := plan.section.lane_x("rail")
	var track := has_track(plan)
	for j in plan.roads_s.size() - 1:
		var v0 := float(plan.roads_s[j]["b"])
		var v1 := float(plan.roads_s[j + 1]["a"])
		var m := avenue_median(av, v0, v1)
		if m.has_area():
			out.append(m)
		if not track:
			var g := verge_rect(rail.x, rail.y, v0, v1)
			if g.has_area():
				out.append(g)
	return out


const LIFT_DOOR_W := 10.0        ## the freight lift door's width (CityBuildings._pillar)


## The keep-clear aprons in front of the freight lift doors that face the spine (sidewalk between the door and the curb,
## the door's width), as Rect2s: CityStreets paints them, CityPropLayout keeps props off them. [] off a section.
static func lift_aprons(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if plan.section == null:
		return out
	var sl := plan.section.spine_line
	for b: Dictionary in plan.buildings:
		if not b["pillar"] or str(b["core"]["kind"]) != "lift":
			continue
		var front := int(b["front"])
		var blk: Dictionary = plan.blocks[int(plan.lots[int(b["lot"])]["block"])]
		if not ((front == 0 and int(blk["ix"]) == sl - 1) or (front == 1 and int(blk["ix"]) == sl)):
			continue
		var cs: Vector2 = b["core"]["size"]
		var face := float(b["core"]["x"]) + (cs.x * 0.5 if front == 0 else -cs.x * 0.5)
		var r: Rect2 = blk["rect"]
		var curb := r.end.x - 0.3 if front == 0 else r.position.x + 0.3
		if absf(curb - face) < 1.0:
			continue
		var s := float(b["core"]["s"])
		out.append(Rect2(minf(face, curb), s - LIFT_DOOR_W * 0.5, absf(curb - face), LIFT_DOOR_W))
	return out


# --- Ramp slope runs (playtest R2.17, city-spine.md "Ramp ends") --------------------------------------------------
# The plan fits every ramp's slope inside its whole-row span, clear of the junction boxes at both ends (SectionPlan
# connector run_top / run_foot, angles). CityPlan._make_ramps builds every ramp part on that run (its s_top / s_foot lie
# on it, and it carries the run itself as run_top / run_foot in the deck's s), so the plan's fields decide: no inset of
# our own. The floor cut (SectionPlan.connector_rect via CitySite), the ribbon, the collision and the walk graph all
# start and end on it.


## The slope run of ramp part `r` (a CityPlan.ramps entry) in this deck's s: Vector2(s where the whole ramp leaves its
## top, s where it reaches its foot), both ends of the WHOLE ramp (top and bottom parts share it). From the part's
## run_top / run_foot; a part without them (built by hand) gives the run its heights imply.
static func ramp_run(plan: CityPlan, r: Dictionary) -> Vector2:
	if r.has("run_top") and r.has("run_foot"):
		return Vector2(float(r["run_top"]), float(r["run_foot"]))
	var tt := _ramp_t(plan, r)
	var s_at := func(t: float) -> float:
		return lerpf(float(r["s_top"]), float(r["s_foot"]), (t - tt.x) / (tt.y - tt.x))
	return Vector2(s_at.call(0.0), s_at.call(1.0))


## Where ramp part r starts and ends along its whole ramp, t 0 (top line) .. 1 (foot line): from its heights, since the
## height over the lower floor is pitch * (1 - t) (CityPlan._make_ramps).
static func _ramp_t(plan: CityPlan, r: Dictionary) -> Vector2:
	var pitch := plan.section.p("pitch") if plan.section != null else 48.0
	var lower := pitch if r["role"] == "top" else 0.0
	return Vector2(1.0 - (float(r["h_top"]) + lower) / pitch, 1.0 - (float(r["h_foot"]) + lower) / pitch)
