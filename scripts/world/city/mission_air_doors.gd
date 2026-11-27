class_name MissionAirDoors
extends RefCounted
## Air doors (docs/design/city-ramps-and-stack.md "Air doors"): the high hangar doors for dropships in a deck's end walls,
## laid out from the deck's CityPlan alone (static: no state, no network, no randomness). The same on every machine and in
## the load checksum (CityStack.checksum joins checksum()). MissionWorld builds and runs the doors (_c_air, air_door); this
## file only says where they go and how big they are.

const SILL := 21.0       ## m: an air door's opening bottom above the deck floor at its wall ...
const HEAD := 27.0       ## ... and top
const W := 12.0          ## m: its clear width (a dropship's hull 5.2 m + margins)
const DEPTH := 14.0      ## m: its recess from the wall plane to the back wall
const ROOM_H := 6.5      ## m: the recess's roof (6.25 m clear under its light bar)
const CORRIDOR := 40.0   ## m of straight flight into the deck that must be clear (spot)
const MARGIN := 1.6      ## m either side of the opening in that corridor
const TIER_MAX := 20.0   ## m: a building taller than this blocks the corridor


## The sizes that make a MissionGateDoor an air door (before build()).
static func config(door: MissionGateDoor) -> void:
	door.air = true
	door.sill = SILL
	door.bay_depth = DEPTH
	door.room_h = ROOM_H
	door.jamb = 1.4
	door.butt = 0.8
	door.frame_out = 1.8
	door.lintel_h = 1.8


## Half the width an air door takes on its wall (frame, recess and plates, + 0.5 m).
static func half() -> float:
	return maxf(W * 0.5 + 1.4 + 0.8 + 0.4, W * 0.5 + 1.0 + MissionGateDoor.PLATE) + 0.5


## The CityWalls "mission_air" hole of an air door at `c`: the opening (left out of the wall's face) and its frame's rect
## (posts, fins, racks, light bars stop round it).
static func hole(c: float) -> Dictionary:
	var wo := W * 0.5 + 0.6
	var f := W * 0.5 + 1.4 + 0.8 + 0.4
	return {"a": c - wo, "b": c + wo, "y0": SILL, "y1": HEAD, "fa": c - f, "fb": c + f,
			"fy0": SILL - MissionGateDoor.AIR_LEDGE_T - 0.3, "fy1": HEAD + 1.8 + 0.3}


## Keep-outs that the deck's lettering must fit inside (CitySigns: looks), so that air doors never depend on it. The
## dependency points from looks to gameplay: tests/test_air_doors.gd checks every sign against these and every door.
const GATE_SIGN_HALF := 6.5    ## m either side of a gate's centre line, at any height over it: its over-gate deck sign
const RAMP_SIGN_REACH := 5.0   ## m past each end of a ramp, along it, over its width + 2 m: its hung way-finding sign


## Every air door of a deck from its plan alone: [{side, c, wall}] (wall: the plan.boundary() entry), one per end wall
## (side 2, then 3) where spot finds a spot. The same on every machine; in the load checksum (checksum).
static func doors(plan: CityPlan) -> Array:
	var out := []
	for w: Dictionary in plan.boundary():
		if int(w["side"]) < 2:
			continue
		var c := spot(plan, w)
		if not is_nan(c):
			out.append({"side": int(w["side"]), "c": c, "wall": w})
	return out


## The air doors of a deck as a checksum (sides and positions to the millimetre): CityStack.checksum joins it.
static func checksum(plan: CityPlan) -> String:
	var buf := StreamPeerBuffer.new()
	for ad: Dictionary in doors(plan):
		buf.put_8(int(ad["side"]))
		buf.put_32(int(round(float(ad["c"]) * 1000.0)))
	return buf.data_array.hex_encode() if buf.data_array.size() > 0 else "-"


## THE AIR DOOR PLACEMENT RULE (plan data only: the same on every machine, and in the load checksum). On end wall w
## (side 2 / 3) of the deck planned by `plan`, the spot `c` (along the wall, arc x) nearest the avenue's centre line (0
## without a section; candidates every 0.5 m, + before -) such that:
##   - the door's width (half() each side) stays 4 m inside the wall's ends;
##   - it stays 1 m clear of every gate's staging bay footprint (MissionWorld.bay_half + its plates) and any gate's span;
##   - its frame's rect stays 1 m clear of the band kept over every gate for its deck sign (GATE_SIGN_HALF);
##   - the flight corridor (the opening +- MARGIN, CORRIDOR m straight into the deck) crosses no building taller
##     than TIER_MAX, no pillar core, park column, ramp (+2 m, and RAMP_SIGN_REACH past its ends for its hung sign),
##     nor ceiling opening;
##   - the ceiling leaves 4 m over the lintel.
## NAN when no spot passes. (Until 2026-11-25 the rule read the cosmetic CitySigns layout itself: side signs beside the
## gates and hung ramp / shaft signs, so a sign constant moved wall cuts with no checksum change.)
## A ramp's rect in the flight corridor rule: the ramp grown 2 m, and RAMP_SIGN_REACH past both ends for its hung sign.
static func ramp_keep_out(rp: Dictionary) -> Rect2:
	var a0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
	var a1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
	return Rect2(float(rp["x0"]), a0, float(rp["x1"]) - float(rp["x0"]), a1 - a0).grow_individual(2.0, RAMP_SIGN_REACH, 2.0, RAMP_SIGN_REACH)


static func spot(plan: CityPlan, w: Dictionary) -> float:
	var hole := hole(0.0)
	if plan.p("ceiling") < float(hole["fy1"]) + 4.0:
		return NAN
	var side := int(w["side"])
	var at := float(w["at"])
	var inward := -1.0 if side % 2 == 0 else 1.0
	var e := plan.extent
	var hw := half()
	var lo := e.position.x + 4.0 + hw
	var hi := e.end.x - 4.0 - hw
	var blocked: Array = []       # [u0, u1] the door's centre may not fall in
	for g: Dictionary in w["gates"]:
		var mid := (float(g["a"]) + float(g["b"])) * 0.5
		var r := maxf(MissionWorld.plan_bay_half(plan, w, g), (float(g["b"]) - float(g["a"])) * 0.5) + MissionGateDoor.PLATE + 1.0
		blocked.append([mid - r - hw, mid + r + hw])
		blocked.append([mid - GATE_SIGN_HALF - 1.0 + float(hole["fa"]), mid + GATE_SIGN_HALF + 1.0 + float(hole["fb"])])
	# The corridor's blockers, as arc rects.
	var s0 := minf(at, at + inward * CORRIDOR)
	var band := Rect2(e.position.x, s0, e.size.x, CORRIDOR)
	var rects: Array[Rect2] = []
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		var sz: Vector2 = b.get("size", Vector2.ZERO)
		if sz.x > 0.0 and plan.top_of(i) > TIER_MAX:
			rects.append(Rect2((b["center"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			rects.append(Rect2(Vector2(float(b["core"]["x"]), float(b["core"]["s"])) - cs * 0.5, cs))
	for col: Dictionary in plan.columns:
		var hc := float(col["half"]) + 1.0
		rects.append(Rect2(float(col["x"]) - hc, float(col["s"]) - hc, hc * 2.0, hc * 2.0))
	for rp: Dictionary in plan.ramps:
		rects.append(ramp_keep_out(rp))
	for o: Rect2 in plan.site.openings:
		rects.append(CityStreets.ceiling_opening(o))
	var near: Array[Rect2] = []
	for r in rects:
		if r.intersects(band):
			near.append(r)
	var centre := 0.0
	if plan.section != null:
		var av := plan.section.lane_x("avenue")
		centre = (av.x + av.y) * 0.5
	var n := int(ceilf(e.size.x / 0.5))
	for k in n * 2 + 1:
		var off := float((k + 1) / 2) * 0.5 * (1.0 if k % 2 == 1 else -1.0)
		var c := centre + off
		if c < lo or c > hi:
			continue
		var ok := true
		for bl: Array in blocked:
			if c > float(bl[0]) and c < float(bl[1]):
				ok = false
				break
		if not ok:
			continue
		var cor := Rect2(c - W * 0.5 - MARGIN, s0, W + MARGIN * 2.0, CORRIDOR)
		for r in near:
			if r.intersects(cor):
				ok = false
				break
		if ok:
			return c
	return NAN
