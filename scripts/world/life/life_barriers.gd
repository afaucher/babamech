class_name LifeBarriers
extends RefCounted
## The checkpoint dressing of a section deck (docs/design/ambient-life.md, phase 3), from the section plan's
## checkpoint hooks. Cosmetic: no collision. Flat palette colour per face, built once per deck into one mesh.
##   checkpoint "heavy"  closes the road at its cross line: two striped barrier arms meeting in the middle of the road
##                       (the avenue lane when the hook is on the spine) and a low booth at each end of them. Vehicles
##                       whose loop turns at that junction stop CHECK_STOP s at its stop line (LifeTraffic).
##   checkpoint "light"  one booth on the sidewalk corner beside the junction; stops nothing.
## The plan's `cordon` hooks (in front of sealed blast doors) get no dressing: the yellow-banded cordon blocks were
## removed 2026-11-26 by user decision.

const ARM_H := 1.0
const BOOTH := Vector3(1.5, 2.3, 1.5)


## What stands where: [{kind: heavy | light, x, s, a, b (span across the road)}].
static func items(plan: CityPlan) -> Array:
	var out: Array = []
	var sec := plan.section
	if sec == null:
		return out
	for hk: Dictionary in sec.hooks:
		if int(hk["deck"]) != plan.deck:
			continue
		var x := float(hk["x"])
		var s := float(hk["s"])
		if hk["kind"] == "checkpoint":
			var span := _road_span(plan, x)
			var line := _cross_line(plan, s)
			out.append({"kind": str(hk.get("size", "light")), "x": x, "s": line, "a": span.x, "b": span.y})
	return out


## The x range a heavy checkpoint closes: the avenue lane when x is on it, else the longitudinal road containing x.
static func _road_span(plan: CityPlan, x: float) -> Vector2:
	var av := plan.avenue_x()
	if x >= av.x and x <= av.y:
		return av
	for r: Dictionary in plan.roads_x:
		if x >= float(r["a"]) and x <= float(r["b"]):
			return Vector2(float(r["a"]), float(r["b"]))
	return Vector2(x - 6.0, x + 6.0)


## The centre s of the cross road nearest to s.
static func _cross_line(plan: CityPlan, s: float) -> float:
	var best := s
	var bd := INF
	for r: Dictionary in plan.roads_s:
		var c := (float(r["a"]) + float(r["b"])) * 0.5
		if absf(c - s) < bd:
			bd = absf(c - s)
			best = c
	return best


## The cross road (roads_s entry) whose centre is nearest to s.
static func _cross_road(plan: CityPlan, s: float) -> Dictionary:
	var best: Dictionary = plan.roads_s[0]
	for r: Dictionary in plan.roads_s:
		if absf((float(r["a"]) + float(r["b"])) * 0.5 - s) < absf((float(best["a"]) + float(best["b"])) * 0.5 - s):
			best = r
	return best


## Everything in items(plan), into `geo` (deck-local, on the road).
static func build(geo: CityGeo, plan: CityPlan) -> void:
	for it: Dictionary in items(plan):
		match str(it["kind"]):
			"heavy":
				var a := float(it["a"])
				var b := float(it["b"])
				var s := float(it["s"])
				var mid := (a + b) * 0.5
				_booth(geo, geo.frame(a + BOOTH.x * 0.5 + 0.2, s, 0.0))
				_booth(geo, geo.frame(b - BOOTH.x * 0.5 - 0.2, s, 0.0))
				_arm(geo, a + BOOTH.x + 0.4, mid - 0.1, s)
				_arm(geo, b - BOOTH.x - 0.4, mid + 0.1, s)
			"light":
				var road := _cross_road(plan, float(it["s"]))
				var bx := float(it["b"]) + 1.6
				for r: Dictionary in plan.roads_x:          # beside the whole road (the spine's edge, not its avenue lane)
					if float(it["x"]) >= float(r["a"]) and float(it["x"]) <= float(r["b"]):
						bx = float(r["b"]) + 1.6
				var bs := float(road["b"]) + 1.6
				_booth(geo, geo.frame(bx, bs, CityPlan.CURB_H))


## A low guard booth: cream walls, a dark window band all round, a terracotta roof slab.
static func _booth(geo: CityGeo, xf: Transform3D) -> void:
	geo.box(xf, Vector3(0.0, 0.05, 0.0), Vector3(BOOTH.x + 0.2, 0.1, BOOTH.z + 0.2), CityPalette.c("concrete_dark"))
	geo.box(xf, Vector3(0.0, 0.55, 0.0), Vector3(BOOTH.x, 0.9, BOOTH.z), CityPalette.c("cream"))
	geo.box(xf, Vector3(0.0, 1.4, 0.0), Vector3(BOOTH.x - 0.04, 0.8, BOOTH.z - 0.04), CityPalette.c("glass_dark"))
	geo.box(xf, Vector3(0.0, 1.95, 0.0), Vector3(BOOTH.x, 0.3, BOOTH.z), CityPalette.c("cream"))
	geo.box(xf, Vector3(0.0, 2.2, 0.0), Vector3(BOOTH.x + 0.3, 0.2, BOOTH.z + 0.3), CityPalette.c("terracotta"))


## A barrier arm across the road from x0 (its post) to x1 at s: red and white stripes, 0.8 m each.
static func _arm(geo: CityGeo, x0: float, x1: float, s: float) -> void:
	var post := geo.frame(x0, s, 0.0)
	geo.box(post, Vector3(0.0, (ARM_H + 0.15) * 0.5, 0.0), Vector3(0.3, ARM_H + 0.15, 0.3), CityPalette.c("metal_dark"))
	var dir := signf(x1 - x0)
	var length := absf(x1 - x0)
	var n := maxi(int(round(length / 0.8)), 1)
	var piece := length / float(n)
	for i in n:
		var xc := x0 + dir * (piece * (float(i) + 0.5))
		geo.box(geo.frame(xc, s, 0.0), Vector3(0.0, ARM_H, 0.0), Vector3(piece, 0.14, 0.14),
				CityPalette.c("terracotta") if i % 2 == 0 else CityPalette.c("marking"))
	geo.box(geo.frame(x1, s, 0.0), Vector3(0.0, (ARM_H - 0.07) * 0.5, 0.0), Vector3(0.08, ARM_H - 0.07, 0.08), CityPalette.c("metal_dark"))
