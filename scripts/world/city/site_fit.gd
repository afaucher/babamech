class_name SiteFit
extends RefCounted
## Where mission pieces may stand: the SNAP RULE (a site moved to clear ground), the FIT RULE (a site the widest mech can
## reach: the fit mask and its queries) and the DEPOT SITES (keep-out, widest-mech fit, facing). Gameplay rules from plan
## data only (the deck's CityPlan, its section, the props' initial layout, the mission plan and the mission world's
## snapped sites): the same answer on every machine. Pure: no clock, no state of its own beyond caches (the fit mask on
## the plan's "site_fit_mask" meta, the offset tables), no network, no randomness. Callers: MissionWorld (flag, relay
## sites), MissionDepots (depot sites), DownedCrew / DownedRules (seats), CityPlan.

# --- Plan queries ----------------------------------------------------------------------------------------------------------

## Height of the walking surface at (x, s): curb height on a block (sidewalk, plaza, park), else the road.
static func ground_h(plan: CityPlan, pt: Vector2) -> float:
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).has_point(pt):
			return CityPlan.CURB_H
	return 0.0


static func in_rects(rects: Array, pt: Vector2, grow: float = 0.0) -> bool:
	for r: Rect2 in rects:
		if r.grow(grow).has_point(pt):
			return true
	return false


## Building footprints on a plan (the footprint of every building, and a pillar's core), as Rect2.
static func plan_blockers(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for b: Dictionary in plan.buildings:
		var sz: Vector2 = b.get("size", Vector2.ZERO)
		if sz.x > 0.0 and not (b["pillar"] and (b["tiers"] as Array).is_empty()):
			out.append(Rect2((b["center"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			var cc := Vector2(float(b["core"]["x"]), float(b["core"]["s"]))
			out.append(Rect2(cc - cs * 0.5, cs))
	return out


# --- Site snapping ---------------------------------------------------------------------------------------------------------

const SNAP_STEP := 1.0        ## m between candidate points
const ROAD_COST := 6.0        ## m a road point counts further away than a sidewalk / plaza point (prefer the latter)
const WALL_MARGIN := 4.0      ## m kept between a placed piece's disc and the boundary walls

## The SNAP RULE (the same on every machine: plan data and the props' initial layout only). Candidates: `site` and every
## point of a SNAP_STEP grid centred on it within `reach` (the snap distance: MissionWorld.snap_reach); each scored by its distance from the site, plus ROAD_COST when
## it is not on a block (sidewalk, plaza, park). In score order (ties: smaller s, then smaller x), the first CLEAR point
## wins: a disc of `clear_r` round it is inside the walls (WALL_MARGIN 4 m to spare), clear of every building footprint and pillar core,
## floor cut (+ its curb), ramp, park column, kept-clear rect, prop (its radius), the ground in front of every wall gate (gate_aprons), the rail lane and the avenue's median, and
## `avoid` ([[Vector2, radius]]: pieces placed before it, e.g. the mast a chained defend relay stands beside).
## Returns {x, s, h (ground height there), snapped: moved off the site, ok: a clear point was found}; when none is, the
## site itself with ok = false.
static func snap(d: CityDistrict, site: Vector2, reach: float, clear_r: float, avoid: Array = []) -> Dictionary:
	var plan := d.plan
	var cx := _snap_ctx(d, site, reach, clear_r)
	var blockers: Array[Rect2] = cx["blockers"]
	var cuts: Array[Rect2] = cx["cuts"]
	var items: Array = cx["items"]
	var blocks: Array[Rect2] = cx["blocks"]
	var inner: Rect2 = cx["inner"]
	# Nearest first: a candidate's score is at least its distance, so once the distance passes the best score found
	# nothing later can win; among equal scores the smaller s, then x (the same pick as sorting every candidate).
	var best := []
	for off: Vector2 in _offsets(reach):
		var dist := off.length()
		if not best.is_empty() and dist > float(best[0]) + 1e-9:
			break
		var pt := site + off
		var cost := dist + (0.0 if in_rects(blocks, pt) else ROAD_COST)
		var key := [cost, pt.y, pt.x]
		if not best.is_empty() and key >= best:
			continue
		if inner.has_point(pt) and clear_at(d, pt, clear_r, blockers, cuts, avoid, items, cx["aprons"]):
			best = key
	if best.is_empty():
		return {"x": site.x, "s": site.y, "h": ground_h(plan, site), "snapped": false, "ok": false}
	var at := Vector2(float(best[2]), float(best[1]))
	return {"x": at.x, "s": at.y, "h": ground_h(plan, at), "snapped": not at.is_equal_approx(site), "ok": true}


## What snap checks a candidate against, kept to what can touch a candidate's disc within `reach` of `site` (the same
## answer, far fewer checks over a 45 m reach): {blockers, cuts, items, blocks, inner, aprons}.
static func _snap_ctx(d: CityDistrict, site: Vector2, reach: float, clear_r: float) -> Dictionary:
	var plan := d.plan
	var area := Rect2(site, Vector2.ZERO).grow(reach + clear_r + 1.0)
	var blockers: Array[Rect2] = []
	for b in plan_blockers(plan):
		if b.intersects(area):
			blockers.append(b)
	var cuts: Array[Rect2] = []
	for o in plan.floor_cuts():
		if o.grow(CityStreets.HOLE_CURB + 1.0).intersects(area):
			cuts.append(o)
	var items := []
	if d.props != null:
		for it: Dictionary in d.props.items:
			if area.grow(3.0).has_point(Vector2(float(it["x"]), float(it["s"]))):
				items.append(it)
	var blocks: Array[Rect2] = []
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).intersects(area):
			blocks.append(b["rect"])
	return {"blockers": blockers, "cuts": cuts, "items": items, "blocks": blocks, "aprons": gate_aprons(plan),
			"inner": plan.extent.grow(-(clear_r + WALL_MARGIN))}


# --- The fit rule: a snapped objective site the widest mech can reach ----------------------------------------------------

const FIT_MARGIN := 0.5        ## m added to CityPlan.MECH_R_MAX: the disc that must get through (a corridor >= 8.2 m)
const FIT_GOAL := 0.9          ## the disc's centre must get within this share of the objective's radius of the site
const FIT_CELL := 1.0          ## m: the reachability grid's cell
const FIT_FALLBACK := 2.0      ## x the snap reach: how far the road-side fallback looks when nothing in reach fits

## The fit radius: the widest player capsule plus the margin.
static func fit_r() -> float:
	return CityPlan.MECH_R_MAX + FIT_MARGIN


## THE FIT RULE (MissionWorld's flag, defend relay sites; plan data only, the same on every machine; opt-in: snap
## itself is unchanged for every other caller). First the old rule (snap). Its pick stands when a disc of fit_r()
## gets from the deck's walk graph (FitMask) to within FIT_GOAL x `obj_r` of it: then the result is snap's,
## byte for byte, plus fit = true, moved_for_fit = false. Otherwise, among the candidates snap would accept (inside
## `reach`, clear), in snap's order (score, then s, then x), the first that the disc reaches wins. If none does, the
## nearest clear ROAD point (not on a block) within FIT_FALLBACK x reach that it reaches (nearest first, ties smaller s
## then x). If even that fails, snap's pick with fit = false. Adds keys: fit, moved_for_fit.
static func snap_fit(d: CityDistrict, site: Vector2, reach: float, clear_r: float, avoid: Array, obj_r: float) -> Dictionary:
	var plan := d.plan
	var out := snap(d, site, reach, clear_r, avoid)
	var fm := mask(plan)
	var goal_r := obj_r * FIT_GOAL
	var q := fm.query(avoid, goal_r)
	var old_at := Vector2(float(out["x"]), float(out["s"]))
	if q.reaches(old_at):
		out["fit"] = true
		out["moved_for_fit"] = false
		return out
	var cx := _snap_ctx(d, site, reach, clear_r)
	var keyed := []
	for off: Vector2 in _offsets(reach):
		var pt := site + off
		keyed.append([off.length() + (0.0 if in_rects(cx["blocks"], pt) else ROAD_COST), pt.y, pt.x])
	keyed.sort()
	var picked := Vector2.INF
	for key: Array in keyed:
		var pt := Vector2(float(key[2]), float(key[1]))
		if (cx["inner"] as Rect2).has_point(pt) and clear_at(d, pt, clear_r, cx["blockers"], cx["cuts"], avoid, cx["items"], cx["aprons"]) \
				and q.reaches(pt):
			picked = pt
			break
	if picked == Vector2.INF:
		var far := reach * FIT_FALLBACK
		var fx := _snap_ctx(d, site, far, clear_r)
		for off: Vector2 in _offsets(far):
			var pt := site + off
			if in_rects(fx["blocks"], pt):
				continue
			if (fx["inner"] as Rect2).has_point(pt) and clear_at(d, pt, clear_r, fx["blockers"], fx["cuts"], avoid, fx["items"], fx["aprons"]) \
					and q.reaches(pt):
				picked = pt
				break
	if picked == Vector2.INF:
		out["fit"] = false
		out["moved_for_fit"] = false
		return out
	return {"x": picked.x, "s": picked.y, "h": ground_h(plan, picked), "snapped": not picked.is_equal_approx(site), "ok": true,
			"fit": true, "moved_for_fit": true}


## Plan `plan`'s reachability mask for the fit disc (cached on the plan: plan data only, built once per deck).
static func mask(plan: CityPlan) -> FitMask:
	var key := "site_fit_mask"
	if plan.has_meta(key):
		var m: FitMask = plan.get_meta(key)
		if m != null and is_equal_approx(m.r, fit_r()):
			return m
	var m := FitMask.new()
	m.build(plan, fit_r())
	plan.set_meta(key, m)
	return m


## Whether plan `plan` already has its fit mask built (MissionWorld builds it in its own setup chunk).
static func has_mask(plan: CityPlan) -> bool:
	return plan.has_meta("site_fit_mask")


## Where a disc of radius `r` (the fit disc) can stand on a deck and where it can get to, from plan data: a FIT_CELL grid
## over the extent. A cell is FREE when the disc centred on it touches nothing a mech cannot walk through below
## CityPlan.MECH_TOP (CityPlan.court_open's obstacles): building tiers and solids lower than MECH_TOP and higher than a
## step (STEP_H), pillar cores, park columns (their ring), floor cuts (+ their curb), ramps (+ 0.5 m parapet), and it stays
## r inside the walls. Sidewalks, curbs, raised courts and street props (knockable) are walkable. SEED cells are free cells on
## the walk graph's edges (CityGraphs.walk_graph(): every road, pedestrian street and open court). query(avoid, goal_r)
## answers whether a point's goal disc touches a cell connected (4-neighbour, through free cells clear of the `avoid` discs)
## to a seed.
class FitMask extends RefCounted:
	var r := 0.0
	var origin := Vector2.ZERO
	var cell := FIT_CELL
	var nx := 0
	var ns := 0
	var free := PackedByteArray()    ## 1: the disc fits there (static obstacles)
	var seeds := PackedByteArray()   ## 1: a free cell on a walk-graph edge
	var build_ms := 0.0
	var graph_ms := 0.0              ## of which CityPlan.walk_graph()

	func build(plan: CityPlan, radius: float) -> void:
		var t0 := Time.get_ticks_usec()
		r = radius
		var e := plan.extent
		origin = e.position
		nx = int(ceilf(e.size.x / cell))
		ns = int(ceilf(e.size.y / cell))
		free.resize(nx * ns)
		free.fill(1)
		# The walls: the centre stays r inside the extent.
		var inner := e.grow(-r)
		var x_lo := origin.x - 10.0
		var x_hi := origin.x + float(nx) * cell + 10.0
		for j in ns:
			var cy := origin.y + (float(j) + 0.5) * cell
			if cy <= inner.position.y or cy >= inner.end.y:
				_block_span(j, x_lo, x_hi)
				continue
			_block_span(j, x_lo, inner.position.x + 1e-4)    # centres at or outside the inner edge
			_block_span(j, inner.end.x - 1e-4, x_hi)
		var step_h := CityPlan.STEP_H
		var top := CityPlan.MECH_TOP
		for bi in plan.buildings.size():
			var b: Dictionary = plan.buildings[bi]
			for t: Dictionary in b["tiers"]:
				if float(t["y0"]) < top and float(t["y1"]) > step_h:
					block_rect(plan.tier_rect(bi, t), 0.0)
			for so: Dictionary in b.get("solids", []):
				if float(so["y0"]) < top and float(so["y1"]) > step_h:
					var sz: Vector2 = so["size"]
					block_rect(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz), 0.0)
			if b["pillar"]:
				var cs: Vector2 = b["core"]["size"]
				block_rect(Rect2(Vector2(float(b["core"]["x"]), float(b["core"]["s"])) - cs * 0.5, cs), 0.0)
		for col: Dictionary in plan.columns:
			block_disc(Vector2(float(col["x"]), float(col["s"])), maxf(float(col.get("ring_r", 0.0)), float(col["half"])))
		if plan.site != null:
			for o in plan.floor_cuts():
				block_rect(o, CityStreets.HOLE_CURB)
		for rp: Dictionary in plan.ramps:
			var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
			var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
			block_rect(Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0), 0.5)
		# Seeds: along every walk-graph edge, every half metre.
		seeds.resize(nx * ns)
		seeds.fill(0)
		var tg := Time.get_ticks_usec()
		var g := CityGraphs.walk_graph(plan)
		graph_ms = float(Time.get_ticks_usec() - tg) / 1000.0
		var nodes: Array = g["nodes"]
		for ed: Array in g["edges"]:
			var a: Vector2 = nodes[int(ed[0])]
			var bb: Vector2 = nodes[int(ed[1])]
			var n := maxi(int(ceilf(a.distance_to(bb) / 0.5)), 1)
			for k in n + 1:
				var c := index_of(a.lerp(bb, float(k) / float(n)))
				if c >= 0 and free[c] == 1:
					seeds[c] = 1
		build_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	## The cell under point p (-1 off the grid).
	func index_of(p: Vector2) -> int:
		var i := int(floorf((p.x - origin.x) / cell))
		var j := int(floorf((p.y - origin.y) / cell))
		if i < 0 or j < 0 or i >= nx or j >= ns:
			return -1
		return j * nx + i

	func centre(c: int) -> Vector2:
		return origin + Vector2(float(c % nx) + 0.5, float(c / nx) + 0.5) * cell

	## Mark every cell whose centre is closer than r to rect q (grown by `grow`) as blocked: row by row, exact.
	func block_rect(q0: Rect2, grow: float) -> void:
		var q := q0.grow(grow)
		var j0 := maxi(int(floorf((q.position.y - r - origin.y) / cell - 0.5)), 0)
		var j1 := mini(int(ceilf((q.end.y + r - origin.y) / cell - 0.5)), ns - 1)
		for j in range(j0, j1 + 1):
			var cy := origin.y + (float(j) + 0.5) * cell
			var dy := maxf(maxf(q.position.y - cy, cy - q.end.y), 0.0)
			if dy >= r:
				continue
			var ext := sqrt(r * r - dy * dy)
			_block_span(j, q.position.x - ext, q.end.x + ext)

	## Mark every cell whose centre is closer than rad + r to c as blocked.
	func block_disc(c: Vector2, rad: float) -> void:
		var rr := rad + r
		var j0 := maxi(int(floorf((c.y - rr - origin.y) / cell - 0.5)), 0)
		var j1 := mini(int(ceilf((c.y + rr - origin.y) / cell - 0.5)), ns - 1)
		for j in range(j0, j1 + 1):
			var dy := absf(origin.y + (float(j) + 0.5) * cell - c.y)
			if dy >= rr:
				continue
			var ext := sqrt(rr * rr - dy * dy)
			_block_span(j, c.x - ext, c.x + ext)

	# Row j: the cells whose centre lies strictly between x0 and x1.
	func _block_span(j: int, x0: float, x1: float) -> void:
		var i0 := maxi(int(floorf((x0 - origin.x) / cell - 0.5)) + 1, 0)
		var i1 := mini(int(ceilf((x1 - origin.x) / cell - 0.5)) - 1, nx - 1)
		var row := j * nx
		for i in range(i0, i1 + 1):
			free[row + i] = 0

	## A query for one snap call: `avoid` ([[Vector2, radius]], the pieces already standing) block the disc too.
	func query(avoid: Array, goal_r: float) -> FitQuery:
		var fq := FitQuery.new()
		fq.m = self
		fq.avoid = avoid
		fq.goal_r = goal_r
		fq.dead.resize(nx * ns)
		fq.dead.fill(0)
		fq.seen.resize(nx * ns)
		fq.seen.fill(0)
		var n := int(ceilf(goal_r / cell)) + 1
		for dj in range(-n, n + 1):
			for di in range(-n, n + 1):
				fq.disc.append(Vector2i(di, dj))
		return fq


## One snap call's reachability questions on a FitMask (see FitMask.query). reaches(pt): some cell whose centre is within
## goal_r of pt is connected to a seed. Cells found to belong to seedless regions are remembered for the rest of the call.
class FitQuery extends RefCounted:
	var m: FitMask
	var avoid: Array = []
	var goal_r := 0.0
	var disc: Array[Vector2i] = []
	var dead := PackedByteArray()     ## 1: in a region with no seed (explored)
	var seen := PackedInt32Array()    ## BFS stamp per cell
	var stamp := 0
	var cells_visited := 0            ## total BFS work (cells) in this query, for the cost report

	func _open(c: int) -> bool:
		if m.free[c] == 0 or dead[c] == 1:
			return false
		if not avoid.is_empty():
			var p := m.centre(c)
			for av: Array in avoid:
				var rr := float(av[1]) + m.r
				if (av[0] as Vector2).distance_squared_to(p) < rr * rr:
					return false
		return true

	func reaches(pt: Vector2) -> bool:
		stamp += 1
		var q := PackedInt32Array()
		var head := 0
		var ci := int(floorf((pt.x - m.origin.x) / m.cell))
		var cj := int(floorf((pt.y - m.origin.y) / m.cell))
		var g2 := goal_r * goal_r
		for o in disc:
			var i := ci + o.x
			var j := cj + o.y
			if i < 0 or j < 0 or i >= m.nx or j >= m.ns:
				continue
			var c := j * m.nx + i
			if seen[c] == stamp or m.centre(c).distance_squared_to(pt) > g2:
				continue
			seen[c] = stamp
			if not _open(c):
				continue
			if m.seeds[c] == 1:
				return true
			q.append(c)
		while head < q.size():
			var c := q[head]
			head += 1
			cells_visited += 1
			var i := c % m.nx
			for nb: int in [c - 1 if i > 0 else -1, c + 1 if i < m.nx - 1 else -1, c - m.nx, c + m.nx]:
				if nb < 0 or nb >= m.free.size() or seen[nb] == stamp:
					continue
				seen[nb] = stamp
				if not _open(nb):
					continue
				if m.seeds[nb] == 1:
					return true
				q.append(nb)
		# No seed anywhere connected: every cell reached is in a seedless region.
		for c in q:
			dead[c] = 1
		return false


## Every SNAP_STEP grid offset within `reach`, nearest first (ties: smaller y, then x); cached per reach.
static var _offset_cache: Dictionary = {}

static func _offsets(reach: float) -> Array:
	if not _offset_cache.has(reach):
		var keyed := []
		var n := int(floor(reach / SNAP_STEP))
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var off := Vector2(float(i), float(j)) * SNAP_STEP
				if off.length() <= reach + 0.001:
					keyed.append([off.length(), off.y, off.x])
		keyed.sort()
		var out := []
		for k: Array in keyed:
			out.append(Vector2(float(k[2]), float(k[1])))
		_offset_cache[reach] = out
	return _offset_cache[reach]


## Whether a disc of radius r at pt is clear ground (see snap).
## `aprons`: gate_aprons(plan) when the caller has it already (the same answer, computed once).
static func clear_at(d: CityDistrict, pt: Vector2, r: float, blockers: Array[Rect2], cuts: Array[Rect2], avoid: Array = [],
		items: Variant = null, aprons: Variant = null) -> bool:
	var plan := d.plan
	for av: Array in avoid:      # [Vector2, radius]: pieces already placed (a defend relay beside its flag's mast)
		if (av[0] as Vector2).distance_to(pt) < float(av[1]) + r:
			return false
	var box := Rect2(pt - Vector2(r, r), Vector2(r, r) * 2.0)
	for b in blockers:
		if b.intersects(box):
			return false
	for o in cuts:
		if o.grow(CityStreets.HOLE_CURB + 0.5).intersects(box):
			return false
	for k: Rect2 in plan.site.keep_clear:
		if k.intersects(box):
			return false
	for ap: Rect2 in (aprons if aprons != null else gate_aprons(plan)):
		if ap.intersects(box):
			return false
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(2.0).intersects(box):
			return false
	for col: Dictionary in plan.columns:
		if Vector2(float(col["x"]), float(col["s"])).distance_to(pt) < float(col["half"]) + 2.0 + r:
			return false
	if plan.section != null:
		var rail := plan.section.lane_x("rail")
		if pt.x + r > rail.x and pt.x - r < rail.y:
			return false
		var av := plan.section.lane_x("avenue")
		if absf(pt.x - (av.x + av.y) * 0.5) < 1.5 + r:
			return false
	var props: Array = items if items != null else (d.props.items if d.props != null else [])
	for it: Dictionary in props:
		var pr := float(CityPropSim.TYPES[it["type"]]["radius"])
		if Vector2(float(it["x"]), float(it["s"])).distance_to(pt) < pr + r:
			return false
	return true


## The ground in front of every gate in the walls (GATE_APRON m into the map, 1 m past each side): where waves walk in
## and the hatched keep-clear box is painted; nothing is placed there.
const GATE_APRON := 12.0

static func gate_aprons(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for w: Dictionary in plan.boundary():
		var side := int(w["side"])
		var at := float(w["at"])
		var inward := -1.0 if side % 2 == 0 else 1.0
		var d0 := minf(at, at + inward * GATE_APRON)
		for g: Dictionary in w["gates"]:
			var a := float(g["a"]) - 1.0
			var b := float(g["b"]) + 1.0
			out.append(Rect2(a, d0, b - a, GATE_APRON) if side >= 2 else Rect2(d0, a, GATE_APRON, b - a))
	return out


# --- Depot sites (MissionDepots; plan data, the built deck's plan and the snapped world sites only) ------------------------


## KEEP-OUT: a depot's footprint (6 x 4 m turned by its facing) never comes within KEEP_MARGIN of a road segment's strip
## (street, lane, pedestrian; crossings are in the strips), a ramp (and its mouth / foot, RAMP_MOUTH along s), a floor
## cut, a gate's staging bay mouth and exit corridor (MissionWorld.source_bay: door -> exit, + BAY_RUN beyond), a lift /
## shaft / ramp source (SOURCE_KEEP), a flag mast or relay; and stays WALK_GAP + the edge's half-width off every
## walk-graph edge's centre line (CityGraphs.walk_graph(plan, true): what enemies and bots path along). The STANDING AREA in front
## of the socket wall (STAND_GAP out) must be clear ground (SiteFit.snap, a Strider capsule MECH_R: props, kept-
## clear boxes) and pass the WIDEST-MECH FIT below. Search: the plan site, then a 1 m grid nearest first out to
## PLACE_REACHES (widened in steps); each point also needs clear ground under the depot (SiteFit.snap at reach
## 0, the flag rule). FACING among the facings that pass: toward the nearest road (a mech walks up to it from the street),
## ties +s, +x, -s, -x.
## WIDEST-MECH FIT (2026-11-26: seed 22's d1_depot1, placed by the old plain-snap fallback inside a block, wedged a
## Bulwark): on the deck's fit mask (SiteFit.mask: Environment's grid of where a disc of fit_r() = the widest
## capsule CityPlan.MECH_R_MAX + FIT_MARGIN stands among static obstacles, the same source as the objective site fit),
## with the flag masts / relays / depots placed already as obstacles too:
##   RING  every cell whose centre is fit_r() .. fit_r() + RING_W from the footprint is open: the widest mech can walk
##         right round the depot, so the depot never narrows a passage below its width (no gap a mech squeezes into and
##         wedges: any gap between the depot and a wall is >= 2 x fit_r() + RING_W);
##   STAND the standing spot's cell is open (the widest capsule stands there, within claim range);
##   REACH the standing spot connects (8-neighbour, open cells, never through the depot) to a cell on the deck's walk
##         graph (the mask's seeds): the widest mech gets there from the street network.
## NO FALLBACK: when nothing passes within PLACE_REACHES (tier 0), the same rules over the whole deck on a PLACE_FAR_STEP
## grid nearest first (tier 1), then without the walk-edge gap (tier 2: the fit rule already keeps every passage open);
## nothing on the deck -> the depot is not placed (unplaced; its cores are not moved elsewhere).
const DEPOT_CLEAR := 4.5          ## m clear ground round a depot (snap)
const KEEP_MARGIN := 4.0
const WALK_GAP := 3.0
const WALK_HALF := {"street": 0.0, "lane": 0.0, "pedestrian": 0.0, "none": 2.5, "alley": 2.0}   ## road edges: their strip
const RAMP_MOUTH := 12.0
const BAY_RUN := 10.0
const SOURCE_KEEP := 8.0
const STAND_GAP := CityPlan.MECH_R_MAX + FIT_MARGIN + 0.5   ## m from the socket wall: inside the RING
const MECH_R := 2.2
const ROAD_LOOK := 30.0           ## m a facing looks for a road
const PLACE_REACHES: Array[float] = [25.0, 50.0, 80.0, 120.0]
const RING_W := 1.0               ## m: the ring of open cells round the footprint (one cell)
const PLACE_FAR_STEP := 2.0       ## m: the whole-deck search grid (tiers 1, 2)
const REACH_CELLS := 400000       ## most cells the REACH search visits (a whole deck is ~200k)
const FACE_DIRS: Array[Vector2] = [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]   ## (x, s) per face: 0 +s, 1 +x, 2 -s, 3 -x


## THE DEPOT SITES of mission plan `plan` on built stack `stk` with mission world `mw` (MissionDepots: every machine, the
## same answer): each plan depot, in plan order, gets find_site (see KEEP-OUT, WIDEST-MECH FIT above); a depot on a deck the
## stack doesn't have is skipped. Returns {sites: {id: find_site's dict + deck}, unplaced: [[id, deck, why]] (no valid
## site on its deck), keep: {deck: keep_out(deck)} (what the depots of that deck were placed against)}.
static func place_depots(stk: CityStack, mw: MissionWorld, plan: MissionPlan) -> Dictionary:
	var pl := DepotPlacer.new()
	pl.stk = stk
	pl.mw = mw
	pl.plan = plan
	var unplaced: Array = []
	for d: Dictionary in plan.depots:
		var id := str(d["id"])
		var k := int(d["deck"])
		if k < 0 or k >= stk.decks.size():
			continue
		var dist: CityDistrict = stk.decks[k]
		var at := Vector2(float(d["site"]["x"]), float(d["site"]["s"]))
		var snap := pl.find_site(dist, k, at, float(d.get("snap", MissionPlan.DEPOT_SNAP)))
		if not bool(snap["ok"]):
			unplaced.append([id, k, snap.get("why", "")])
			continue
		snap["deck"] = k
		pl.sites[id] = snap
	return {"sites": pl.sites, "unplaced": unplaced, "keep": pl._keep}


## The footprint rect of a depot at `at` facing `f` (deck arc coordinates).
static func footprint_rect(at: Vector2, f: int) -> Rect2:
	var half := SupplyDepot.footprint_half(f)
	return Rect2(at - half, half * 2.0)


## What a footprint at `at` facing `f` hits in `ko` (keep_out): "road", "ramp_or_cut", "corridor", "walk" (a walk-graph
## edge; skipped when `walk` is false: tier 2), or "" when clear.
static func keep_hit(ko: Dictionary, at: Vector2, f: int, walk: bool = true) -> String:
	var r := footprint_rect(at, f)
	var rm := r.grow(KEEP_MARGIN)
	for rd: Rect2 in ko["roads"]:
		if rm.intersects(rd):
			return "road"
	for rc: Rect2 in ko["rects"]:
		if rm.intersects(rc):
			return "ramp_or_cut"
	for c: Array in ko["caps"]:
		if rect_seg_dist(r, c[0], c[1]) < float(c[2]):
			return "corridor"
	if walk:
		for c: Array in ko.get("walks", []):
			if rect_seg_dist(r, c[0], c[1]) < float(c[2]):
				return "walk"
	return ""


## Distance from rect `r` to segment a-b (0 when they touch).
static func rect_seg_dist(r: Rect2, a: Vector2, b: Vector2) -> float:
	if r.has_point(a) or r.has_point(b):
		return 0.0
	var corners: Array[Vector2] = [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
			return 0.0
	var best := INF
	for p: Vector2 in [a, b]:
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		best = minf(best, p.distance_to(q))
	for cn in corners:
		best = minf(best, cn.distance_to(Geometry2D.get_closest_point_to_segment(cn, a, b)))
	return best


## The point in front of facing `f`'s socket wall where a pilot stands (STAND_GAP out from the wall).
static func stand_point(at: Vector2, f: int) -> Vector2:
	var half := SupplyDepot.footprint_half(f)
	var dir: Vector2 = FACE_DIRS[f]
	return at + dir * (absf(dir.x) * half.x + absf(dir.y) * half.y + STAND_GAP)


## Every 1 m grid offset within `reach` and beyond `inner` (< 0: from the centre), nearest first (ties smaller y, then
## x); cached.
static var _rings: Dictionary = {}

static func _ring(inner: float, reach: float) -> Array:
	var key := Vector2(inner, reach)
	if not _rings.has(key):
		var keyed := []
		var n := int(floor(reach))
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var l := Vector2(i, j).length()
				if l <= reach + 0.001 and (inner < 0.0 or l > inner + 0.001):
					keyed.append([l, float(j), float(i)])
		keyed.sort()
		var out := []
		for kk: Array in keyed:
			out.append(Vector2(float(kk[2]), float(kk[1])))
		_rings[key] = out
	return _rings[key]


static func _rect_point_dist(r: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dy := maxf(maxf(r.position.y - p.y, p.y - r.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)


## Every PLACE_FAR_STEP grid point (on `at`'s grid) inside `ext` beyond the widest PLACE_REACHES, nearest first (ties
## smaller s, then x).
static func _far_points(ext: Rect2, at: Vector2) -> Array:
	var keyed := []
	var st := PLACE_FAR_STEP
	var i0 := int(floorf((ext.position.x - at.x) / st))
	var i1 := int(ceilf((ext.end.x - at.x) / st))
	var j0 := int(floorf((ext.position.y - at.y) / st))
	var j1 := int(ceilf((ext.end.y - at.y) / st))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := at + Vector2(float(i), float(j)) * st
			var l := p.distance_to(at)
			if l > PLACE_REACHES[-1] + 0.001 and ext.has_point(p):
				keyed.append([l, p.y, p.x])
	keyed.sort()
	var out := []
	for kk: Array in keyed:
		out.append(Vector2(float(kk[2]), float(kk[1])))
	return out


## Of the facings `faces`, the one whose wall looks at the nearest road strip (within ROAD_LOOK m); ties in order.
static func _road_face(ko: Dictionary, at: Vector2, faces: Array[int]) -> int:
	var best := faces[0]
	var best_d := INF
	for f in faces:
		var half := SupplyDepot.footprint_half(f)
		var dir: Vector2 = FACE_DIRS[f]
		var from := at + dir * (absf(dir.x) * half.x + absf(dir.y) * half.y)
		var dd := INF
		var t := 0.0
		while t <= ROAD_LOOK and dd == INF:
			var p := from + dir * t
			for rd: Rect2 in ko["roads"]:
				if rd.has_point(p):
					dd = t
					break
			t += 1.0
		if dd < best_d:
			best_d = dd
			best = f
	return best


## One placement run (place_depots): the stack, mission world and plan it reads, the sites placed so far (each later
## depot keeps clear of them) and the search scratch.
class DepotPlacer extends RefCounted:
	var stk: CityStack
	var mw: MissionWorld
	var plan: MissionPlan
	var sites: Dictionary = {}        ## depot id -> its site (place_depots), in plan order
	var _open: PackedByteArray        ## find_site: the fit mask's free cells minus the avoid discs (this depot's search)
	var _stamp: PackedInt32Array      ## find_site: REACH search visit stamps
	var _stamp_n := 0
	var _keep: Dictionary = {}        ## deck -> keep_out(k) (built once per deck)

	## The keep-out of deck k (see KEEP-OUT): {roads: [Rect2 road strips], rects: [Rect2 ramps / cuts, already grown],
	## caps: [[Vector2 a, Vector2 b, float r]] corridors, discs (a == b) and walk edges}.
	func keep_out(k: int) -> Dictionary:
		if _keep.has(k):
			return _keep[k]
		var roads: Array[Rect2] = []
		var rects: Array[Rect2] = []
		var caps: Array = []
		var sec := stk.section if stk != null else null
		if sec != null:
			for sg: Dictionary in sec.segments(k):
				if str(sg["form"]) != "none":
					roads.append(sg["rect"])
		var dist: CityDistrict = stk.decks[k]
		var cp := dist.plan
		for rp: Dictionary in cp.ramps:
			var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
			var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
			rects.append(Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow_individual(2.0,
				RAMP_MOUTH, 2.0, RAMP_MOUTH))
		for c: Rect2 in cp.floor_cuts():
			rects.append(c.grow(CityStreets.HOLE_CURB + 1.0))
		var w := mw
		for src: Dictionary in plan.deck_sources(k):
			var at := Vector2(float(src["x"]), float(src["s"]))
			if str(src["kind"]) == "gate" and w != null:
				var bay: Dictionary = w.source_bay(src["id"])
				if bool(bay.get("ok", false)):
					var door: Vector2 = bay["door"]
					var ex_a := stk.to_deck_arc(bay["exit"])
					var ex := Vector2(float(ex_a["x"]), float(ex_a["s"]))
					var dir := (ex - door).normalized() if ex.distance_to(door) > 0.1 else Vector2.ZERO
					caps.append([door, ex + dir * BAY_RUN, float(bay["half_width"]) + 1.0])
					continue
			caps.append([at, at, SOURCE_KEEP])
		for av: Array in _avoid(k):     # flag masts, relays and the depots placed already
			caps.append([av[0], av[0], float(av[1]) + 2.0])
		var walks: Array = []
		var g := CityGraphs.walk_graph(cp, true)
		var nodes: Array = g["nodes"]
		var forms: Dictionary = g.get("forms", {})
		for ed: Array in g["edges"]:
			var a := int(ed[0])
			var b := int(ed[1])
			var form := str(forms.get(Vector2i(mini(a, b), maxi(a, b)), "street"))
			walks.append([nodes[a] as Vector2, nodes[b] as Vector2, float(WALK_HALF.get(form, 2.5)) + WALK_GAP])
		var ko := {"roads": roads, "rects": rects, "caps": caps, "walks": walks}
		_keep[k] = ko
		return ko

	## The depot site for plan site `at` on deck k: snap's {x, s, h, ok} + face, reach, snapped; ok false when nothing
	## within the widest PLACE_REACHES satisfies the keep-out (the caller falls back). Deterministic: plan data, the built
	## deck's plan, the snapped world sites.
	func find_site(d: CityDistrict, k: int, at: Vector2, first_reach: float) -> Dictionary:
		var ko := keep_out(k)
		var avoid := _avoid(k)
		var m := SiteFit.mask(d.plan)
		_open = m.free.duplicate()
		for av: Array in avoid:
			_block_disc(m, av[0], float(av[1]) + m.r)
		if _stamp.size() != m.free.size():
			_stamp.resize(m.free.size())
			_stamp.fill(0)
			_stamp_n = 0
		var ring_off := [_ring_cells(m, at, 0), _ring_cells(m, at, 1)]   # per footprint orientation (face % 2)
		var why := {}
		# Tier 0: out to PLACE_REACHES, 1 m grid.
		var inner := -1.0
		var reaches: Array[float] = [first_reach]
		for rr in PLACE_REACHES:
			if rr > first_reach:
				reaches.append(rr)
		for reach in reaches:
			for off: Vector2 in SiteFit._ring(inner, reach):
				var g := _try(d, m, ko, avoid, ring_off, at, at + off, true, why)
				if not g.is_empty():
					g["reach"] = reach
					g["tier"] = 0
					return g
			inner = reach
		# Tiers 1 and 2: the whole deck, PLACE_FAR_STEP grid nearest first (tier 2 without the walk-edge gap).
		var far := SiteFit._far_points(d.plan.extent, at)
		for tier in [1, 2]:
			for pt: Vector2 in far:
				var g := _try(d, m, ko, avoid, ring_off, at, pt, tier == 1, why)
				if not g.is_empty():
					g["reach"] = pt.distance_to(at)
					g["tier"] = tier
					return g
		return {"ok": false, "why": why}

	## One candidate `pt` (see WIDEST-MECH FIT): snap's {x, s, h, ok} + face, snapped when it passes, else {} (the first
	## failing rule counted in `why`).
	func _try(d: CityDistrict, m: SiteFit.FitMask, ko: Dictionary, avoid: Array, ring_off: Array, at: Vector2, pt: Vector2,
			walk: bool, why: Dictionary) -> Dictionary:
		var faces: Array[int] = []
		var fail := ""
		for o in 2:   # the ring depends only on the orientation: cheap reject first
			if not _ring_open(m, pt, ring_off[o]):
				fail = "ring"
				continue
			for f in [o, o + 2]:
				var h := SiteFit.keep_hit(ko, pt, f, walk)
				if h != "":
					fail = h
					continue
				var sp := SiteFit.stand_point(pt, f)
				var sc := m.index_of(sp)
				if sc < 0 or _open[sc] == 0:
					fail = "stand_fit"
					continue
				if not bool(SiteFit.snap(d, sp, 0.0, MECH_R, avoid)["ok"]):
					fail = "stand_clear"
					continue
				faces.append(f)
		if faces.is_empty():
			why[fail] = int(why.get(fail, 0)) + 1
			return {}
		faces.sort()
		var g := SiteFit.snap(d, pt, 0.0, DEPOT_CLEAR, avoid)
		if not bool(g["ok"]):
			why["clear"] = int(why.get("clear", 0)) + 1
			return {}
		var face := SiteFit._road_face(ko, pt, faces)
		if not _reaches_walk(m, SiteFit.footprint_rect(pt, face), SiteFit.stand_point(pt, face)):
			# the chosen facing's stand spot is cut off: try the others before giving up on the point
			var ok_f := -1
			for f in faces:
				if f != face and _reaches_walk(m, SiteFit.footprint_rect(pt, f), SiteFit.stand_point(pt, f)):
					ok_f = f
					break
			if ok_f < 0:
				why["reach"] = int(why.get("reach", 0)) + 1
				return {}
			face = ok_f
		g["face"] = face
		g["snapped"] = not pt.is_equal_approx(at)
		return g

	## The fit-mask cell offsets (relative to the cell under the candidate) of the RING round a footprint of orientation `o`
	## (0: faces 0 / 2, 1: faces 1 / 3), for candidates on `at`'s 1 m grid (every candidate shares its fractional offset, so
	## one list serves them all; the far grid's 2 m step keeps it).
	func _ring_cells(m: SiteFit.FitMask, at: Vector2, o: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		var fr := SiteFit.footprint_rect(at, o)
		var c0 := Vector2i(int(floorf((at.x - m.origin.x) / m.cell)), int(floorf((at.y - m.origin.y) / m.cell)))
		var span := int(ceilf(fr.size.x * 0.5 + m.r + RING_W)) + 2
		for dj in range(-span, span + 1):
			for di in range(-span, span + 1):
				var c := m.origin + Vector2(float(c0.x + di) + 0.5, float(c0.y + dj) + 0.5) * m.cell
				var dd := SiteFit._rect_point_dist(fr, c)
				if dd >= m.r and dd < m.r + RING_W:
					out.append(Vector2i(di, dj))
		return out

	func _ring_open(m: SiteFit.FitMask, pt: Vector2, offs: Array[Vector2i]) -> bool:
		var ci := int(floorf((pt.x - m.origin.x) / m.cell))
		var cj := int(floorf((pt.y - m.origin.y) / m.cell))
		for o: Vector2i in offs:
			var i := ci + o.x
			var j := cj + o.y
			if i < 0 or j < 0 or i >= m.nx or j >= m.ns or _open[j * m.nx + i] == 0:
				return false
		return true

	## REACH: the standing spot's cell connects to a walk-graph seed cell through open cells (8-neighbour), never within
	## the fit radius of the footprint `fr`.
	func _reaches_walk(m: SiteFit.FitMask, fr: Rect2, stand: Vector2) -> bool:
		var s0 := m.index_of(stand)
		if s0 < 0 or _open[s0] == 0:
			return false
		_stamp_n += 1
		var q := PackedInt32Array([s0])
		_stamp[s0] = _stamp_n
		var head := 0
		var block := fr.grow(m.r)
		while head < q.size() and head < REACH_CELLS:
			var c := q[head]
			head += 1
			if m.seeds[c] == 1:
				return true
			var i := c % m.nx
			var j := c / m.nx
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := i + di
					var jj := j + dj
					if ii < 0 or jj < 0 or ii >= m.nx or jj >= m.ns:
						continue
					var nb := jj * m.nx + ii
					if _stamp[nb] == _stamp_n or _open[nb] == 0:
						continue
					_stamp[nb] = _stamp_n
					var p := m.centre(nb)
					if block.has_point(p) and SiteFit._rect_point_dist(fr, p) < m.r:
						continue
					q.append(nb)
		return false

	## Mark the cells whose centre is within `rr` of `c` closed in _open.
	func _block_disc(m: SiteFit.FitMask, c: Vector2, rr: float) -> void:
		var j0 := maxi(int(floorf((c.y - rr - m.origin.y) / m.cell)), 0)
		var j1 := mini(int(ceilf((c.y + rr - m.origin.y) / m.cell)), m.ns - 1)
		var i0 := maxi(int(floorf((c.x - rr - m.origin.x) / m.cell)), 0)
		var i1 := mini(int(ceilf((c.x + rr - m.origin.x) / m.cell)), m.nx - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				if m.centre(j * m.nx + i).distance_to(c) < rr:
					_open[j * m.nx + i] = 0

	## What a depot on deck k keeps clear of: the snapped flag masts and defend relays there, and the depots placed already.
	func _avoid(k: int) -> Array:
		var out: Array = []
		var w := mw
		if w != null:
			for o: Dictionary in plan.deck_objectives(k):
				var st: Dictionary = {}
				var r := 0.0
				match str(o["type"]):
					"flag":
						st = w.flag_site(o["id"])
						r = MissionWorld.FLAG_CLEAR
					"defend":
						st = w.asset_site(o["id"])
						r = MissionWorld.ASSET_CLEAR
				if not st.is_empty():
					out.append([Vector2(float(st["x"]), float(st["s"])), r])
		for id: String in sites:
			if int(sites[id]["deck"]) == k:
				out.append([Vector2(float(sites[id]["x"]), float(sites[id]["s"])), DEPOT_CLEAR])
		return out
