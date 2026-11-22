class_name LifeBarriers
extends RefCounted
## The checkpoint and cordon dressing of a section deck (docs/design/ambient-life.md, phase 3), from the section plan's
## hooks. Cosmetic: no collision in this phase. Flat palette colour per face, built once per deck into one mesh.
##   checkpoint "heavy"  closes the road at its cross line: two striped barrier arms meeting in the middle of the road
##                       (the avenue lane when the hook is on the spine) and a low booth at each end of them. Vehicles
##                       whose loop turns at that junction stop CHECK_STOP s at its stop line (LifeTraffic).
##   checkpoint "light"  one booth on the sidewalk corner beside the junction; stops nothing.
##   cordon              a line of concrete barrier blocks across the sealed gate, in front of it.

const ARM_H := 1.0
const BOOTH := Vector3(1.5, 2.3, 1.5)
const BLOCK := Vector3(2.0, 0.85, 0.6)     ## a barrier block: length, height, depth
const BLOCK_PITCH := 2.4


## What stands where: [{kind: heavy | light | cordon, x, s, a, b (span across the road, or along the wall), along_s}].
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
			out.append({"kind": str(hk.get("size", "light")), "x": x, "s": line, "a": span.x, "b": span.y, "along_s": false})
		elif hk["kind"] == "cordon":
			var e := plan.extent
			var to_s := minf(absf(s - e.position.y), absf(e.end.y - s))
			var to_x := minf(absf(x - e.position.x), absf(e.end.x - x))
			var along_s := to_x < to_s          # a side wall: the line runs along s
			var half := 7.0
			var best := INF
			for w: Dictionary in plan.boundary():
				var side := int(w["side"])
				if (side < 2) != along_s:
					continue
				for g: Dictionary in w["gates"]:
					var mid := (float(g["a"]) + float(g["b"])) * 0.5
					var d := absf(mid - (s if along_s else x))
					if d < best:
						best = d
						half = (float(g["b"]) - float(g["a"])) * 0.5
			var c := s if along_s else x
			out.append({"kind": "cordon", "x": x, "s": s, "a": c - half, "b": c + half, "along_s": along_s})
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


static func _c(id: String) -> Color:
	return CityPalette.C[id]


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
			"cordon":
				var along_s: bool = it["along_s"]
				var a := float(it["a"])
				var b := float(it["b"])
				var n := maxi(int(floor((b - a) / BLOCK_PITCH)), 1)
				for i in n + 1:
					var u := lerpf(a, b, float(i) / float(n))
					var xf := geo.frame(float(it["x"]), u, 0.0, PI * 0.5) if along_s else geo.frame(u, float(it["s"]), 0.0, 0.0)
					_block(geo, xf)


## A low guard booth: cream walls, a dark window band all round, a terracotta roof slab.
static func _booth(geo: CityGeo, xf: Transform3D) -> void:
	geo.box(xf, Vector3(0.0, 0.05, 0.0), Vector3(BOOTH.x + 0.2, 0.1, BOOTH.z + 0.2), _c("concrete_dark"))
	geo.box(xf, Vector3(0.0, 0.55, 0.0), Vector3(BOOTH.x, 0.9, BOOTH.z), _c("cream"))
	geo.box(xf, Vector3(0.0, 1.4, 0.0), Vector3(BOOTH.x - 0.04, 0.8, BOOTH.z - 0.04), _c("glass_dark"))
	geo.box(xf, Vector3(0.0, 1.95, 0.0), Vector3(BOOTH.x, 0.3, BOOTH.z), _c("cream"))
	geo.box(xf, Vector3(0.0, 2.2, 0.0), Vector3(BOOTH.x + 0.3, 0.2, BOOTH.z + 0.3), _c("terracotta"))


## A barrier arm across the road from x0 (its post) to x1 at s: red and white stripes, 0.8 m each.
static func _arm(geo: CityGeo, x0: float, x1: float, s: float) -> void:
	var post := geo.frame(x0, s, 0.0)
	geo.box(post, Vector3(0.0, (ARM_H + 0.15) * 0.5, 0.0), Vector3(0.3, ARM_H + 0.15, 0.3), _c("metal_dark"))
	var dir := signf(x1 - x0)
	var length := absf(x1 - x0)
	var n := maxi(int(round(length / 0.8)), 1)
	var piece := length / float(n)
	for i in n:
		var xc := x0 + dir * (piece * (float(i) + 0.5))
		geo.box(geo.frame(xc, s, 0.0), Vector3(0.0, ARM_H, 0.0), Vector3(piece, 0.14, 0.14),
				_c("terracotta") if i % 2 == 0 else _c("marking"))
	geo.box(geo.frame(x1, s, 0.0), Vector3(0.0, (ARM_H - 0.07) * 0.5, 0.0), Vector3(0.08, ARM_H - 0.07, 0.08), _c("metal_dark"))


## A concrete barrier block, a yellow band near its top (local X along the line).
static func _block(geo: CityGeo, xf: Transform3D) -> void:
	geo.box(xf, Vector3(0.0, 0.2, 0.0), Vector3(BLOCK.x, 0.4, BLOCK.z), _c("concrete"))
	geo.box(xf, Vector3(0.0, 0.55, 0.0), Vector3(BLOCK.x, 0.3, BLOCK.z * 0.7), _c("concrete"))
	geo.box(xf, Vector3(0.0, 0.775, 0.0), Vector3(BLOCK.x, 0.15, BLOCK.z * 0.5), _c("marking_yellow"))
