class_name BannerPlan
extends RefCounted
## Where one deck's invader banners hang, as plain data (docs/design/banners.md). Deterministic from the deck's CityPlan
## (checksummed by the load barrier: CityStack.checksum) and the mission seed, through one generator seeded from both
## (AGENTS rule 4), so every machine places the same banners with the same ids. No nodes, no looks.
##
## make(plan, seed) -> [banner]: banner = {id, kind: "wall" | "pole", x, s (arc point of the cross-bar's centre on the
## deck), top (the bar's height above the floor), len (cloth length), n: Vector2 (the way the cloth faces, in (x, s)),
## bi (building index, -1 for a pole), src: "hook" | "scatter" | "plaza"}. ids are the array indices.
##
## RULES. Facade spots: ground tiers (y0 <= 1.5 m) at least MIN_FACADE tall, every FACE_STEP m along each side with 1 m to
## spare at each end; the ground in front must be a road or an open lot (plaza, park) with nothing built OPEN_CLEAR m out;
## never on the building's front side over its door (DOOR_CLEAR of the face's middle), never within CUT_CLEAR of a floor
## cut (ramp mouths, shafts, holes) or a ramp, nor on ground the site keeps clear, never within GATE_CLEAR of a
## checkpoint / cordon hook, never within EDGE_CLEAR of the deck's edge (boundary gates). Picks: at each section
## `banner` hook (transit regions) 2-3 facades nearest it (HOOK_RADIUS), then a scatter preferring civic buildings and
## facades on the spine / arterials / plazas, up to a total of 6-9 facades + 1-2 pole banners on plazas, never more than
## PER_DECK_MAX, at least SPACING apart, spread over buildings (a new building first, at most 2 per building).

const SPACING := 9.0
const PER_DECK_MAX := 10
const FACE_STEP := 7.0
const MIN_FACADE := 7.0
const OUT := 0.7                ## m: the bar stands this far off the wall
const OPEN_CLEAR := 6.0
const DOOR_CLEAR := 3.6         ## m: half the banner (2.0) + the widest door's half (1.5) + slack
const CUT_CLEAR := 4.0
const GATE_CLEAR := 12.0
const EDGE_CLEAR := 8.0
const HOOK_RADIUS := 45.0
const POLE_CLEAR := 2.6         ## m round the pole and round the cloth's centre
const PER_BUILDING := 2


static func make(plan: CityPlan, seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 7919 + (plan.deck + 1) * 104729 + 0xBA22
	var hooks: Array = []
	var gates: Array[Vector2] = []
	if plan.section != null:
		for hk: Dictionary in plan.section.hooks:
			if int(hk.get("deck", -1)) != plan.deck:
				continue
			var at := Vector2(float(hk["x"]), float(hk["s"]))
			match str(hk["kind"]):
				"banner":
					hooks.append(at)
				"checkpoint", "cordon":
					gates.append(at)
	var blk := _Blockers.new(plan)
	var cands := facade_spots(plan, blk, gates)
	var picked: Array = []
	var per_b: Dictionary = {}
	# 1. Around every banner hook: the 2-3 nearest facades.
	for h: Vector2 in hooks:
		var near: Array = []
		for c: Dictionary in cands:
			var d := Vector2(c["x"], c["s"]).distance_to(h)
			if d <= HOOK_RADIUS:
				near.append([d + rng.randf() * 4.0, c])
		near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		var want := 2 + rng.randi_range(0, 1)
		var got := 0
		for pass_i in 2:
			for e: Array in near:
				if got >= want or picked.size() >= PER_DECK_MAX - 1:
					break
				if _ok(e[1], picked, per_b, pass_i == 0):
					_take(e[1], "hook", picked, per_b)
					got += 1
	# 2. The seeded scatter: civic / spine / arterial / plaza facades first, then the rest.
	var poles_want := 1 + rng.randi_range(0, 1)
	var facades_want := rng.randi_range(6, 9)
	var order := cands.duplicate()
	for i in range(order.size() - 1, 0, -1):     # Fisher-Yates with the seeded generator
		var j := rng.randi_range(0, i)
		var t: Variant = order[i]
		order[i] = order[j]
		order[j] = t
	var keyed: Array = []
	for i in order.size():
		keyed.append([int(order[i]["prio"]), i, order[i]])
	keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for pass_i in 2:
		for e: Array in keyed:
			if picked.size() >= mini(facades_want, PER_DECK_MAX - poles_want):
				break
			if _ok(e[2], picked, per_b, pass_i == 0):
				_take(e[2], "scatter", picked, per_b)
	# 3. Pole banners on plazas, the ones nearest a banner hook (else the deck's middle) first.
	var spots := pole_spots(plan, blk, gates)
	var ref: Array = hooks if not hooks.is_empty() else [Vector2.ZERO]
	var ps: Array = []
	for p: Dictionary in spots:
		var best := INF
		for h: Vector2 in ref:
			best = minf(best, Vector2(p["x"], p["s"]).distance_to(h))
		ps.append([best + rng.randf() * 6.0, p])
	ps.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var poles := 0
	for e: Array in ps:
		if poles >= poles_want or picked.size() >= PER_DECK_MAX:
			break
		if _ok(e[1], picked, per_b, false):
			_take(e[1], "plaza", picked, per_b)
			poles += 1
	for i in picked.size():
		picked[i]["id"] = i
		picked[i].erase("prio")
	return picked


static func _ok(c: Dictionary, picked: Array, per_b: Dictionary, new_building: bool) -> bool:
	if bool(c.get("used", false)):
		return false
	var bi := int(c["bi"])
	if bi >= 0 and int(per_b.get(bi, 0)) >= (1 if new_building else PER_BUILDING):
		return false
	var at := Vector2(c["x"], c["s"])
	for p: Dictionary in picked:
		if p == c or at.distance_to(Vector2(p["x"], p["s"])) < SPACING:
			return false
	return true


static func _take(c: Dictionary, src: String, picked: Array, per_b: Dictionary) -> void:
	var b := c.duplicate()
	b["src"] = src
	picked.append(b)
	c["used"] = true    # never picked twice (the duplicate is what is kept)
	var bi := int(b["bi"])
	if bi >= 0:
		per_b[bi] = int(per_b.get(bi, 0)) + 1


## Every facade spot that passes the rules, in a fixed order (buildings, sides, steps).
static func facade_spots(plan: CityPlan, blk: _Blockers = null, gates: Array[Vector2] = []) -> Array:
	if blk == null:
		blk = _Blockers.new(plan)
	var out: Array = []
	var inner := plan.extent.grow(-EDGE_CLEAR)
	for bi in plan.buildings.size():
		var b: Dictionary = plan.buildings[bi]
		if bool(b.get("pillar", false)):
			continue
		var c: Vector2 = b["center"]
		var style := str(b.get("style", ""))
		for t: Dictionary in b.get("tiers", []):
			if float(t["y0"]) > 1.5 or float(t["y1"]) < MIN_FACADE:
				continue
			var off: Vector2 = t["off"]
			var sz: Vector2 = t["size"]
			for side in 4:
				var n: Vector2 = CityPlan.SIDE_N[side]
				var along := Vector2(absf(n.y), absf(n.x))
				var span := along.x * sz.x + along.y * sz.y
				if span < BannerMeshes.W + 2.0:
					continue
				var steps := maxi(int((span - BannerMeshes.W - 2.0) / FACE_STEP), 0)
				for i in steps + 1:
					var u := (float(i) - float(steps) * 0.5) * FACE_STEP
					if side == int(b.get("front", -1)) and absf(u) < DOOR_CLEAR:
						continue
					var face := c + off + Vector2(n.x * sz.x, n.y * sz.y) * 0.5 + along * u
					if not inner.has_point(face):
						continue
					var ahead := face + n * (CityPlan.SIDEWALK + 3.0)
					var front_kind := blk.ground_kind(ahead)
					if front_kind == "":
						continue
					if not blk.clear(face + n * OPEN_CLEAR, 1.0):
						continue
					if blk.near_cut(face + n * 3.0, CUT_CLEAR + BannerMeshes.W * 0.5) or not plan.clear_at(face + n * 2.0):
						continue
					var gate := false
					for g: Vector2 in gates:
						if face.distance_to(g) < GATE_CLEAR:
							gate = true
							break
					if gate:
						continue
					var top := minf(float(t["y1"]) - 0.8, BannerMeshes.H + 4.0)
					var at := face + n * OUT
					var prio := 0 if (style == "civic" or front_kind in ["spine", "arterial", "plaza"]) else 1
					out.append({"kind": "wall", "x": at.x, "s": at.y, "top": top,
						"len": clampf(top - 1.6, 4.8, BannerMeshes.H), "n": n, "bi": bi, "prio": prio})
			break
	return out


## Plaza spots for a pole banner: the middle of every plaza lot that is clear round the pole and round the cloth (which
## hangs ARM_X along +x), faces the nearer side across s.
static func pole_spots(plan: CityPlan, blk: _Blockers = null, gates: Array[Vector2] = []) -> Array:
	if blk == null:
		blk = _Blockers.new(plan)
	var out: Array = []
	var inner := plan.extent.grow(-EDGE_CLEAR)
	for l: Dictionary in plan.lots:
		if str(l.get("open", "")) != "plaza":
			continue
		var r: Rect2 = l["rect"]
		if r.size.x < 7.0 or r.size.y < 5.0:
			continue
		# The cloth faces the deck's middle across s; the arm runs along the cloth's own +X (arc +x facing +s, -x facing -s).
		var n := Vector2(0, 1) if r.get_center().y < 0.0 else Vector2(0, -1)
		var p := r.get_center() - Vector2(BannerMeshes.ARM_X * 0.5 * n.y, 0.0)
		var cl := p + Vector2(BannerMeshes.ARM_X * n.y, 0.0)
		if not inner.has_point(p) or not blk.clear(p, POLE_CLEAR) or not blk.clear(cl, POLE_CLEAR):
			continue
		if not plan.clear_at(p) or not plan.clear_at(cl) or blk.near_cut(p, CUT_CLEAR) or blk.near_cut(cl, CUT_CLEAR):
			continue
		if blk.ground_kind(p) in ["spine", "arterial", "cross", "perimeter", "avenue", "street"]:
			continue
		var gate := false
		for g: Vector2 in gates:
			if p.distance_to(g) < GATE_CLEAR:
				gate = true
		if gate:
			continue
		out.append({"kind": "pole", "x": p.x, "s": p.y, "top": BannerMeshes.ARM_H, "len": BannerMeshes.POLE_LEN, "n": n,
			"bi": -1, "prio": 0})
	return out


## The placement as a short hash (tests; a barrier could join it, but it is already implied by the plan + seed).
static func checksum(list: Array) -> String:
	var s := ""
	for b: Dictionary in list:
		s += "%d|%s|%.2f|%.2f|%.2f|%.2f|%s;" % [int(b["id"]), str(b["kind"]), float(b["x"]), float(b["s"]), float(b["top"]),
			float(b["len"]), str(b["n"])]
	return s.sha256_text().substr(0, 16)


## Blocker queries over one plan, with a coarse grid of tier boxes so the facade scan stays cheap.
class _Blockers:
	const CELL := 24.0
	var plan: CityPlan
	var grid: Dictionary = {}       ## Vector2i -> [Rect2]
	var cuts: Array[Rect2] = []
	var ramps: Array[Rect2] = []

	func _init(p: CityPlan) -> void:
		plan = p
		for b: Dictionary in p.buildings:
			var c: Vector2 = b["center"]
			for t: Dictionary in b.get("tiers", []):
				var sz: Vector2 = t["size"]
				_add(Rect2(c + (t["off"] as Vector2) - sz * 0.5, sz))
			if bool(b.get("pillar", false)) and b.has("core"):
				var core: Dictionary = b["core"]
				var cs: Vector2 = core["size"]
				_add(Rect2(Vector2(float(core["x"]), float(core["s"])) - cs * 0.5, cs))
		for col: Dictionary in p.columns:
			var h := float(col["half"])
			_add(Rect2(float(col["x"]) - h, float(col["s"]) - h, h * 2.0, h * 2.0))
		if p.site != null:
			cuts = p.floor_cuts()
		for r: Dictionary in p.ramps:
			var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
			var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
			ramps.append(Rect2(float(r["x0"]), s0, float(r["x1"]) - float(r["x0"]), s1 - s0))

	func _add(r: Rect2) -> void:
		var a := Vector2i(floori(r.position.x / CELL), floori(r.position.y / CELL))
		var b := Vector2i(floori(r.end.x / CELL), floori(r.end.y / CELL))
		for i in range(a.x, b.x + 1):
			for j in range(a.y, b.y + 1):
				var k := Vector2i(i, j)
				if not grid.has(k):
					grid[k] = []
				grid[k].append(r)

	## Nothing built within `radius` of the point (any height).
	func clear(pt: Vector2, radius: float) -> bool:
		var a := Vector2i(floori((pt.x - radius) / CELL), floori((pt.y - radius) / CELL))
		var b := Vector2i(floori((pt.x + radius) / CELL), floori((pt.y + radius) / CELL))
		for i in range(a.x, b.x + 1):
			for j in range(a.y, b.y + 1):
				for r: Rect2 in grid.get(Vector2i(i, j), []):
					if r.grow(radius).has_point(pt):
						return false
		return true

	func near_cut(pt: Vector2, radius: float) -> bool:
		for o in cuts:
			if o.grow(radius).has_point(pt):
				return true
		for o in ramps:
			if o.grow(radius).has_point(pt):
				return true
		return false

	## What the ground at the point is: a road strip's kind, "plaza" / "park" / ... for an open lot, "" otherwise.
	func ground_kind(pt: Vector2) -> String:
		for r: Dictionary in plan.roads_x:
			if pt.x >= float(r["a"]) and pt.x <= float(r["b"]):
				return str(r.get("kind", "street"))
		for r: Dictionary in plan.roads_s:
			if pt.y >= float(r["a"]) and pt.y <= float(r["b"]):
				return str(r.get("kind", "street"))
		for l: Dictionary in plan.lots:
			if str(l.get("kind", "")) == "open" and (l["rect"] as Rect2).has_point(pt):
				return str(l.get("open", "open"))
		return ""
