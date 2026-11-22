class_name CityPropSim
extends RefCounted
## The motion of a street prop (docs/design/city-props.md), as closed-form functions of one event and the time since it.
## Nothing integrates frame by frame, so every machine that has the event computes the same pose at the same clock time,
## and a late arrival just evaluates a later age. Pure math on plain data: no nodes.
##
## Coordinates are the deck's arc coordinates (x along the axis, s along the arc), except for a ROOF prop (an item with
## `building` >= 0): its pose x / s are (x, z) in that building's flat frame (CityDistrict.building_frame), the plane of
## the roof it stands on, and its directions are in that frame too. A pose is
##   {x, s, lie, tilt, spin}   base point; lie = the direction it leans or lies, as a yaw in the (x, s) plane
##                             (direction (sin lie, cos lie)); tilt = radians from upright; spin = how far a shove has
##                             turned it about the vertical (added to its model yaw)
## An event is
##   TOPPLE  {id, kind, dir: Vector2, t0}                    falls from its layout spot away from the push
##   SHOVE   {id, kind, dir, v0, len, from: pose, t0}        slides from `from`; v0 already capped and mass-scaled, len the
##                                                           distance it really goes (cut short by a wall)
##   REST    {id, kind, pose}                                lies at `pose` (a late joiner's snapshot)

enum { STANDING, FALLING, DOWN, SLIDING }
enum { TOPPLE, SHOVE, REST }

## mass (kg), contact radius (m), height (m, before the prop's scale), fall time (s), resting tilt (deg), weapon knockback
## that topples it (m/s).
const TYPES := {
	"tree": {"mass": 1200.0, "radius": 0.6, "height": 5.6, "fall": 0.9, "rest": 78.0, "dv": 3.0},
	"lamp": {"mass": 400.0, "radius": 0.3, "height": 6.5, "fall": 0.8, "rest": 90.0, "dv": 2.0},
	"signal": {"mass": 300.0, "radius": 0.3, "height": 5.3, "fall": 0.7, "rest": 90.0, "dv": 2.0},
	"sign": {"mass": 150.0, "radius": 0.25, "height": 3.6, "fall": 0.6, "rest": 90.0, "dv": 1.5},
	"bench": {"mass": 250.0, "radius": 0.9, "height": 0.9, "fall": 0.4, "rest": 90.0, "dv": 1.5},
	"bin": {"mass": 80.0, "radius": 0.35, "height": 0.9, "fall": 0.3, "rest": 90.0, "dv": 1.0},
	# Roof units (docs/design/city-rooftops.md): they stand on a building's flat roof and stay on it.
	"water_tank": {"mass": 1800.0, "radius": 1.4, "height": 4.3, "fall": 1.0, "rest": 82.0, "dv": 4.0},
	"planter": {"mass": 900.0, "radius": 1.1, "height": 1.4, "fall": 0.6, "rest": 90.0, "dv": 3.0},
	"ac": {"mass": 600.0, "radius": 0.9, "height": 1.3, "fall": 0.5, "rest": 90.0, "dv": 2.5},
	"vent": {"mass": 120.0, "radius": 0.45, "height": 1.1, "fall": 0.4, "rest": 90.0, "dv": 1.5},
}
const TYPE_ORDER := ["tree", "lamp", "signal", "sign", "bench", "bin", "water_tank", "planter", "ac", "vent"]
const ROOF_TYPES := ["water_tank", "planter", "ac", "vent"]

const BOUNCE_DEG := 4.0        ## the one small bounce after it lands
const BOUNCE_T := 0.25
const BASE_SLIP := 0.3         ## how far the base ends up along the fall direction (m)
const FRICTION := 6.0          ## sliding deceleration (m/s^2): distance v0 a - 3 a^2
const SHOVE_MAX := 4.0         ## v0 cap (m/s): at most v0^2 / 12 = 1.33 m of slide
const SHOVE_MASS := 400.0      ## v0 scales by SHOVE_MASS / mass, at most 1
const TURN_MAX_DEG := 20.0     ## a slide turns the prop at most this far toward the push


static func spec(type: String) -> Dictionary:
	return TYPES[type]


static func rest_tilt(type: String) -> float:
	return deg_to_rad(float(TYPES[type]["rest"]))


## The speed a shove really starts at: capped, then slowed by the prop's mass (a tree barely moves, a bin skitters).
static func shove_speed(type: String, v0: float) -> float:
	return minf(maxf(v0, 0.0), SHOVE_MAX) * minf(SHOVE_MASS / float(TYPES[type]["mass"]), 1.0)


static func lie_of(dir: Vector2) -> float:
	return atan2(dir.x, dir.y)


static func dir_of(lie: float) -> Vector2:
	return Vector2(sin(lie), cos(lie))


## How long the event's motion lasts.
static func duration(ev: Dictionary, type: String) -> float:
	match int(ev["kind"]):
		TOPPLE:
			return float(TYPES[type]["fall"]) + BOUNCE_T
		SHOVE:
			return _slide_time(float(ev["v0"]), float(ev["len"]))
	return 0.0


## Time to slide `length` from speed v0 (v0 / 6 when it runs its full course).
static func _slide_time(v0: float, length: float) -> float:
	if v0 <= 0.0:
		return 0.0
	var disc := maxf(v0 * v0 - 4.0 * (FRICTION * 0.5) * length, 0.0)
	return (v0 - sqrt(disc)) / FRICTION


## The standing pose of a layout item.
static func standing(item: Dictionary) -> Dictionary:
	var b := base_of(item)
	return {"x": b.x, "s": b.y, "lie": 0.0, "tilt": 0.0, "spin": 0.0}


## Where the item stands in its own plane: (x, s) on the deck, or (lx, lz) on its roof.
static func base_of(item: Dictionary) -> Vector2:
	if is_roof(item):
		return Vector2(float(item["lx"]), float(item["lz"]))
	return Vector2(float(item["x"]), float(item["s"]))


static func is_roof(item: Dictionary) -> bool:
	return int(item.get("building", -1)) >= 0


## The pose `a` seconds after the event (clamped to its course: a negative age is its start, a late one its rest).
static func pose_at(ev: Dictionary, item: Dictionary, a: float) -> Dictionary:
	var type := str(item["type"])
	match int(ev["kind"]):
		TOPPLE:
			var fall := float(TYPES[type]["fall"])
			var rest := rest_tilt(type)
			var dir: Vector2 = ev["dir"]
			var f := clampf(a / fall, 0.0, 1.0)
			var tilt := rest * f * f      # accelerates like a falling pole
			if a > fall:
				tilt = rest - deg_to_rad(BOUNCE_DEG) * sin(PI * clampf((a - fall) / BOUNCE_T, 0.0, 1.0))
			var base := base_of(item) + dir * BASE_SLIP * f * f
			return {"x": base.x, "s": base.y, "lie": lie_of(dir), "tilt": tilt, "spin": 0.0}
		SHOVE:
			var from: Dictionary = ev["from"]
			var dir: Vector2 = ev["dir"]
			var v0 := float(ev["v0"])
			var length := float(ev["len"])
			var t := clampf(a, 0.0, _slide_time(v0, length))
			var d := minf(v0 * t - FRICTION * 0.5 * t * t, length)
			var frac := d / length if length > 1e-6 else 1.0
			var turn := _turn_toward(float(from["lie"]), lie_of(dir)) * frac
			return {"x": float(from["x"]) + dir.x * d, "s": float(from["s"]) + dir.y * d, "lie": float(from["lie"]) + turn,
					"tilt": float(from["tilt"]), "spin": float(from["spin"]) + turn}
		REST:
			return (ev["pose"] as Dictionary).duplicate()
	return standing(item)


static func end_pose(ev: Dictionary, item: Dictionary) -> Dictionary:
	return pose_at(ev, item, duration(ev, str(item["type"])) + 1.0)


## The state at clock time `now` given the prop's last event (null: never touched).
static func state_at(ev: Variant, type: String, now: float) -> int:
	if ev == null:
		return STANDING
	var e: Dictionary = ev
	var kind := int(e["kind"])
	if kind == REST or now >= float(e["t0"]) + duration(e, type):
		return DOWN
	return FALLING if kind == TOPPLE else SLIDING


## The turn (radians) that brings a lying prop's long axis toward the push axis, capped at TURN_MAX_DEG. A lying pole
## has no front, so it turns toward whichever end of the push axis is nearer.
static func _turn_toward(lie: float, push: float) -> float:
	var diff := wrapf(push - lie, -PI * 0.5, PI * 0.5)
	var cap := deg_to_rad(TURN_MAX_DEG)
	return clampf(diff, -cap, cap)


# --- The world a prop slides in --------------------------------------------------------------------------

## How far a prop of `radius` can slide from `from` along `dir` (unit) before it meets a building footprint or the map's
## edge, up to `want`. A footprint the prop already overlaps does not stop it (it can only slide out).
static func slide_length(plan: CityPlan, from: Vector2, dir: Vector2, want: float, radius: float) -> float:
	var length := want
	var inner := plan.extent.grow(-radius)
	var out := _exit_t(inner, from, dir)
	if out >= 0.0:
		length = minf(length, out)
	for b: Dictionary in plan.buildings:
		var size: Vector2 = b["size"]
		var r := Rect2((b["center"] as Vector2) - size * 0.5, size).grow(radius)
		if r.has_point(from):
			continue
		var t := _enter_t(r, from, dir)
		if t >= 0.0:
			length = minf(length, t)
	return maxf(length, 0.0)


## How far a roof prop of `radius` can slide from `from` along `dir` (unit, roof plane) inside `area` (its tier, the
## roof's edge) before it meets one of `blockers` (what stands on the roof), up to `want`: it stops at the edge, it never
## falls off. A blocker it already overlaps does not stop it.
static func slide_in(area: Rect2, blockers: Array, from: Vector2, dir: Vector2, want: float, radius: float) -> float:
	var length := want
	var inner := area.grow(-radius)
	for k in 2:      # to the inset edge it moves toward (0 if it is already on or past it)
		if dir[k] > 1e-9:
			length = minf(length, maxf((inner.end[k] - from[k]) / dir[k], 0.0))
		elif dir[k] < -1e-9:
			length = minf(length, maxf((inner.position[k] - from[k]) / dir[k], 0.0))
	for q: Rect2 in blockers:
		var r := q.grow(radius)
		if r.has_point(from):
			continue
		var t := _enter_t(r, from, dir)
		if t >= 0.0:
			length = minf(length, t)
	return maxf(length, 0.0)


## Where the ray from `p` along `d` first enters `r` (slab test), or -1 if it never does.
static func _enter_t(r: Rect2, p: Vector2, d: Vector2) -> float:
	var t0 := -INF
	var t1 := INF
	for k in 2:
		var lo := r.position[k]
		var hi := r.end[k]
		if absf(d[k]) < 1e-9:
			if p[k] < lo or p[k] > hi:
				return -1.0
			continue
		var a := (lo - p[k]) / d[k]
		var b := (hi - p[k]) / d[k]
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	if t0 > t1 or t1 < 0.0:
		return -1.0
	return maxf(t0, 0.0)


## Where the ray from `p` (inside `r`) along `d` leaves it, or -1 when `p` is already outside.
static func _exit_t(r: Rect2, p: Vector2, d: Vector2) -> float:
	if not r.has_point(p):
		return -1.0
	var t := INF
	for k in 2:
		if d[k] > 1e-9:
			t = minf(t, (r.end[k] - p[k]) / d[k])
		elif d[k] < -1e-9:
			t = minf(t, (r.position[k] - p[k]) / d[k])
	return t


## The raised floors a prop can lie on: [{rect, h}]. Sidewalk blocks and avenue medians at the curb, garden beds and
## plaza planters above it; everywhere else is road at 0.
static func floor_rects(plan: CityPlan) -> Array:
	var out: Array = []
	for b: Dictionary in plan.blocks:
		out.append({"rect": b["rect"], "h": CityPlan.CURB_H})
	var av := plan.avenue_x()
	for road: Dictionary in plan.roads_x:
		if road["kind"] != "avenue" and road["kind"] != "spine":
			continue
		var mid := (av.x + av.y) * 0.5
		for j in plan.roads_s.size() - 1:
			var v0 := float(plan.roads_s[j]["b"]) + 9.0
			var v1 := float(plan.roads_s[j + 1]["a"]) - 9.0
			if v1 - v0 >= 6.0:
				out.append({"rect": Rect2(mid - 1.5, v0, 3.0, v1 - v0), "h": CityPlan.CURB_H})
	for l: Dictionary in plan.lots:
		if l["kind"] != "open":
			continue
		match str(l["open"]):
			"garden":
				out.append({"rect": (l["rect"] as Rect2).grow(-0.6), "h": CityPlan.CURB_H + 0.25})
			"plaza":
				var r := (l["rect"] as Rect2).grow(-2.0)
				if r.size.x >= 1.0 and r.size.y >= 1.0 and plan.clear_at(r.get_center()):
					var half := Vector2(minf(r.size.x * 0.5, 4.0), minf(r.size.y * 0.5, 4.0)) * 0.5
					out.append({"rect": Rect2(r.get_center() - half, half * 2.0), "h": CityPlan.CURB_H + 0.7})
	return out


static func floor_at(rects: Array, x: float, s: float) -> float:
	var h := 0.0
	for f: Dictionary in rects:
		if (f["rect"] as Rect2).has_point(Vector2(x, s)):
			h = maxf(h, float(f["h"]))
	return h
