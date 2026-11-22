class_name LifeTraffic
extends RefCounted
## The driverless vehicles' calm life as plain data (docs/design/ambient-life.md sections 2, 3 and 14): pods and service
## carts on closed-form timetables over a CityPlan's road grid, the same on every machine (checksum()).
##
## Safe by construction, so no vehicle ever senses another:
##   * Every vehicle drives a LOOP round one block, keeping it on its right (right-hand traffic), in the lane next to that
##     block's curb, so it only ever turns right. Loops of different blocks never share a lane or a junction quadrant: the
##     loop round the block across the street uses the other lane, going the other way.
##   * Every corner is a right turn that crosses two zebras (the one on the road it leaves and the one on the road it
##     joins). It starts from the painted stop line and is timed to happen inside a junction's turn phase (both walk signals
##     red: LifePlan.all_red), and it is clear of the far zebra before the walk signal comes back. Walkers cross only on
##     walk, so pods and people never meet on a crossing.
##   * One lap's timetable is padded with a dock (parked in the parking strip; "parked cars") to a whole number of signal
##     cycles, so every lap meets the same signals and the timetable repeats exactly: pose = lap(t mod L).
##   * Several vehicles on one loop are the same lap shifted by whole multiples of K signal cycles, K chosen so the gap is
##     longer than the dock: a follower can never reach the one ahead.
## Pods stop 10 s at a pod stop on every other street side (pulled into the parking strip). Carts crawl at 4 m/s and stop
## 3 s beside each bin. Lanes: on a street (12 m) the lane next to the curb is 4.45 m out (beyond the 2.3 m parking strip
## and its edge line); on the avenue (20 m) the outer lane is 2.93 m out (between the edge line and the dashed line).
##
## ORDERS SEAM (later phase): base_pose(vid, t) is the only place a vehicle's calm motion comes from. A pod given an order
## (follow, hold, go_to) would get its own motion here instead of `_lap_pose`; LifeFleet already layers firefight
## behaviour on top of whatever base_pose returns.

const STREET_LANE := 4.45
const AVENUE_LANE := 2.93
const STRIP := 1.65                   ## parking strip centre, out from the curb
const SIZE := {"pod": Vector3(1.8, 1.9, 3.4), "cart": Vector3(1.4, 1.6, 2.6)}    ## width, height, length
const V_STREET := 9.0
const V_AVENUE := 12.0
const V_TURN := 5.0
const V_PULL := 4.0
const V_CART := 4.0
const STOP_LINE := 6.0                ## the painted stop line, metres before the junction box
const CLEAR := 7.0                    ## a turn is over when the centre is this far past the box: its back is off the zebra
const DWELL := 10.0
const BIN_STOP := 3.0
const MIN_DOCK := 10.0
const PULL_MIN_SIDE := 32.0           ## a side this long has room for a pull-over
const PODS_DEFAULT := 8
const CARTS_DEFAULT := 2
const PODS_CAP := 12
const CARTS_CAP := 4
const DRIVE := 0
const WAIT := 1
const HOLD := 2
const DOCK := 3
const MODE := ["driving", "stopped", "dwell", "docked"]
const SIDE_ORDER := [3, 0, 2, 1]      ## round a block, block on the right
const SIDE_DIR: Array[Vector2] = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]
const LEG := 5                         ## floats per lap leg: t0 t1 u0 u1 kind (t relative to the lap start)

var lp: LifePlan
var plan: CityPlan
var pods := 0
var carts := 0
var loops: Array = []      ## [{block, kind, pts, cum, speed (per segment), ctime (drive time at each point), drive (one lap's
                           ##   drive time), length, legs, L, phase, k, slots, dock, zones [{stop, clear, j, dep}]}]
var vehicles: Array = []   ## [{id, kind, loop, offset}]


func net_fields() -> Dictionary:
	return {
		"lp": Net.SPAWN, "plan": Net.SPAWN, "pods": Net.SPAWN, "carts": Net.SPAWN,     # seed + params
		"loops": Net.LOCAL, "vehicles": Net.LOCAL,          # derived on every machine, verified by checksum()
	}


static func make(life_plan: LifePlan, pod_count: int = -1, cart_count: int = -1) -> LifeTraffic:
	var t := LifeTraffic.new()
	t.build(life_plan, pod_count, cart_count)
	return t


func build(life_plan: LifePlan, pod_count: int = -1, cart_count: int = -1) -> void:
	lp = life_plan
	plan = lp.plan
	var area := plan.p("size_x") * plan.p("size_s") / (220.0 * 240.0)
	pods = clampi(pod_count if pod_count >= 0 else int(round(PODS_DEFAULT * area)), 0, PODS_CAP)
	carts = clampi(cart_count if cart_count >= 0 else int(round(CARTS_DEFAULT * area)), 0, CARTS_CAP)
	loops.clear()
	vehicles.clear()
	var order: Array = []
	for bi in plan.blocks.size():
		order.append([lp.h(5001, bi), bi])
	order.sort()
	var next := 0
	for c in carts:
		while next < order.size():
			var li := _make_loop(int(order[next][1]), "cart")
			next += 1
			if li >= 0:
				vehicles.append({"id": vehicles.size(), "kind": "cart", "loop": li, "offset": 0.0})
				break
	var left := pods
	while left > 0 and next < order.size():
		var li := _make_loop(int(order[next][1]), "pod")
		next += 1
		if li < 0:
			continue
		var lo: Dictionary = loops[li]
		var n := mini(mini(2, int(lo["slots"])), left)
		var step := maxi(int(lo["slots"]) / n, 1)
		for i in n:
			vehicles.append({"id": vehicles.size(), "kind": "pod", "loop": li, "offset": float(i * step * int(lo["k"])) * LifePlan.CYCLE})
		left -= n
	pods -= left          # (only if the district has too few blocks)


func count() -> int:
	return vehicles.size()


# --- Loops -----------------------------------------------------------------------------------------------

## The road beside side `side` of block rect r: {kind, offset (lane centre out from the curb), parking}.
func _road_of(r: Rect2, side: int) -> Dictionary:
	var roads: Array = plan.roads_x if side < 2 else plan.roads_s
	var edge: float = [r.end.x, r.position.x, r.end.y, r.position.y][side]
	for road: Dictionary in roads:
		var hit: bool = absf(float(road["a"]) - edge) < 0.05 if side % 2 == 0 else absf(float(road["b"]) - edge) < 0.05
		if hit:
			var avenue: bool = road["kind"] == "avenue"
			return {"kind": road["kind"], "offset": AVENUE_LANE if avenue else STREET_LANE, "parking": road["kind"] == "street"}
	return {}


static func _corners(r: Rect2) -> Array:
	return [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]


## The corner a side starts from / ends at, travelling round the block.
static func _side_start(side: int) -> int:
	return [1, 3, 2, 0][side]


static func _side_end(side: int) -> int:
	return [2, 0, 3, 1][side]


## Builds the loop round block bi for vehicles of `kind`; returns its index, or -1 if the block cannot take one.
func _make_loop(bi: int, kind: String) -> int:
	var r: Rect2 = plan.blocks[bi]["rect"]
	var roads: Array = []
	for side in 4:
		var rd := _road_of(r, side)
		if rd.is_empty():
			return -1
		roads.append(rd)
	var cs := _corners(r)
	var lens := [r.size.y, r.size.y, r.size.x, r.size.x]
	var half_len := float((SIZE[kind] as Vector3).z) * 0.5
	# Where the lap starts: a pod's dock (a street side long enough to pull over), a cart's midway along a side.
	var rot := int(lp.h(5003, bi) * 4.0) % 4
	var start := -1
	for k in 4:
		var side: int = SIDE_ORDER[(rot + k) % 4]
		if kind == "cart" or (bool(roads[side]["parking"]) and float(lens[side]) >= PULL_MIN_SIDE):
			start = side
			break
	if start < 0:
		return -1
	var lo := {"block": bi, "kind": kind, "pts": PackedVector2Array(), "speed": PackedFloat32Array(), "marks": []}
	var lane := func(side: int, t: float, out: float) -> Vector2:
		return (cs[_side_start(side)] as Vector2) + CityPlan.SIDE_N[side] * out + SIDE_DIR[side] * t
	var pts: Array = []        # Vector2 (plain arrays: the lambdas below append to them by reference)
	var spd: Array = []
	var marks: Array = []
	var u := [0.0]
	var add := func(p: Vector2, v: float) -> void:
		if not pts.is_empty():
			u[0] = float(u[0]) + (pts[pts.size() - 1] as Vector2).distance_to(p)
			spd.append(v)
		pts.append(p)
	var si := SIDE_ORDER.find(start)
	var m0 := float(lens[start]) * 0.5
	var o0 := float(roads[start]["offset"])
	var v_of := func(side: int) -> float:
		return V_CART if kind == "cart" else (V_AVENUE if roads[side]["kind"] == "avenue" else V_STREET)
	# The start side, from the dock (pod) or its middle (cart) to its corner.
	if kind == "pod":
		add.call(lane.call(start, m0, STRIP), 0.0)
		add.call(lane.call(start, m0 + 3.0, STRIP), V_PULL)
		add.call(lane.call(start, m0 + 7.0, o0), V_PULL)
	else:
		add.call(lane.call(start, m0, o0), 0.0)
	for k in 4:
		var side: int = SIDE_ORDER[(si + k) % 4]
		var nxt: int = SIDE_ORDER[(si + k + 1) % 4]
		var o := float(roads[side]["offset"])
		var len_s := float(lens[side])
		# straight to the corner
		add.call(lane.call(side, len_s, o), v_of.call(side))
		var u_box := float(u[0])
		# the turn: a quarter ellipse round the block corner, from this side's lane to the next one's
		var c: Vector2 = cs[_side_end(side)]
		var on := float(roads[nxt]["offset"])
		for step in range(1, 7):
			var th := PI * 0.5 * float(step) / 6.0
			add.call(c + CityPlan.SIDE_N[nxt] * on * sin(th) + CityPlan.SIDE_N[side] * o * cos(th), minf(V_TURN, v_of.call(nxt)))
		var j := lp._junction_near(c + (CityPlan.SIDE_N[side] + CityPlan.SIDE_N[nxt]) * 4.0)
		marks.append({"u": u_box - STOP_LINE - half_len, "type": WAIT, "j": j, "clear": float(u[0]) + CLEAR})
		# the next side up to its pull-over, or (back on the start side) to the dock / start point
		var len_n := float(lens[nxt])
		var mid := len_n * 0.5
		if nxt == start:
			if kind == "pod":
				add.call(lane.call(nxt, mid - 7.0, on), v_of.call(nxt))
				add.call(lane.call(nxt, mid - 3.0, STRIP), V_PULL)
				add.call(lane.call(nxt, mid, STRIP), V_PULL)
			else:
				add.call(lane.call(nxt, mid, on), v_of.call(nxt))
			break
		if kind == "pod" and bool(roads[nxt]["parking"]) and len_n >= PULL_MIN_SIDE:
			add.call(lane.call(nxt, mid - 7.0, on), v_of.call(nxt))
			add.call(lane.call(nxt, mid - 3.0, STRIP), V_PULL)
			add.call(lane.call(nxt, mid, STRIP), V_PULL)
			marks.append({"u": float(u[0]), "type": HOLD, "dur": DWELL})
			add.call(lane.call(nxt, mid + 3.0, STRIP), V_PULL)
			add.call(lane.call(nxt, mid + 7.0, on), V_PULL)
	var ppts := PackedVector2Array(pts)
	var cum := PackedFloat32Array([0.0])
	for i in range(1, ppts.size()):
		cum.append(cum[i - 1] + ppts[i - 1].distance_to(ppts[i]))
	lo["pts"] = ppts
	lo["cum"] = cum
	lo["speed"] = PackedFloat32Array(spd)
	lo["length"] = cum[cum.size() - 1]
	if kind == "cart":
		_bin_stops(lo, bi, marks)
	marks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["u"]) < float(b["u"]))
	lo["marks"] = marks
	lo["phase"] = floorf(lp.h(5007, bi) * LifePlan.CYCLE)
	_timetable(lo, kind)
	loops.append(lo)
	return loops.size() - 1


## Cart stops beside the bins of block bi: each bin projected onto the lap, kept if it is beside a straight stretch and
## clear of every turn (from its stop line to its clear point).
func _bin_stops(lo: Dictionary, bi: int, marks: Array) -> void:
	var r: Rect2 = plan.blocks[bi]["rect"]
	var pts: PackedVector2Array = lo["pts"]
	var cum: PackedFloat32Array = lo["cum"]
	for it: Dictionary in CityProps.layout(plan):
		if it["type"] != "bin" or int(it.get("building", -1)) >= 0:
			continue
		var at := Vector2(it["x"], it["s"])
		if not r.grow(0.1).has_point(at):
			continue
		var best_u := -1.0
		var best_d := 6.0
		for i in pts.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(at, pts[i], pts[i + 1])
			var d := q.distance_to(at)
			if d < best_d:
				best_d = d
				best_u = cum[i] + pts[i].distance_to(q)
		if best_u < 0.0:
			continue
		var ok := best_u > 2.0 and best_u < float(lo["length"]) - 2.0
		for m: Dictionary in marks:
			if int(m["type"]) == WAIT and best_u > float(m["u"]) - 4.0 and best_u < float(m["clear"]) + 2.0:
				ok = false
		if ok:
			marks.append({"u": best_u, "type": HOLD, "dur": BIN_STOP})


## One lap's legs from the lap start (absolute time `phase`), padded with a dock to whole signal cycles.
func _timetable(lo: Dictionary, kind: String) -> void:
	var legs: Array = []
	var t := float(lo["phase"])
	var u := 0.0
	for m: Dictionary in lo["marks"]:
		var mu := float(m["u"])
		if mu < u:
			continue
		t = _drive(lo, legs, u, mu, t)
		u = mu
		if int(m["type"]) == WAIT:
			var need := _time_between(lo, mu, float(m["clear"]))
			var go := lp.next_all_red(int(m["j"]), t, need)
			if go > t + 1e-6:
				legs.append_array([t, go, u, u, WAIT])
				t = go
			m["dep"] = t - float(lo["phase"])      # when the lap leaves this stop line (lap time)
		else:
			legs.append_array([t, t + float(m["dur"]), u, u, HOLD])
			t += float(m["dur"])
	t = _drive(lo, legs, u, float(lo["length"]), t)
	var active := t - float(lo["phase"])
	var extra := 0.0
	if kind == "pod" and lp.h(5011, int(lo["block"])) < 0.35:
		extra = 2.0 * LifePlan.CYCLE       # some pods stay docked a good while ("parked cars")
	var L := ceilf((active + (MIN_DOCK if kind == "pod" else BIN_STOP) + extra) / LifePlan.CYCLE) * LifePlan.CYCLE
	legs.append_array([t, float(lo["phase"]) + L, float(lo["length"]), float(lo["length"]), DOCK if kind == "pod" else HOLD])
	var packed := PackedFloat64Array(legs)
	for i in packed.size() / LEG:
		packed[i * LEG] -= float(lo["phase"])
		packed[i * LEG + 1] -= float(lo["phase"])
	lo["legs"] = packed
	lo["L"] = L
	lo["dock"] = L - active
	lo["k"] = int(ceilf((L - active + 12.0) / LifePlan.CYCLE))
	lo["slots"] = maxi(int(L / (LifePlan.CYCLE * float(lo["k"]))), 1)
	var zones: Array = []
	for m: Dictionary in lo["marks"]:
		if int(m["type"]) == WAIT:
			zones.append({"stop": float(m["u"]), "clear": float(m["clear"]), "j": int(m["j"]), "dep": float(m["dep"])})
	lo["zones"] = zones
	var ct := PackedFloat64Array([0.0])
	var cum: PackedFloat32Array = lo["cum"]
	var spd: PackedFloat32Array = lo["speed"]
	for i in spd.size():
		ct.append(ct[i] + (cum[i + 1] - cum[i]) / spd[i])
	lo["ctime"] = ct
	lo["drive"] = ct[ct.size() - 1]


func _drive(lo: Dictionary, legs: Array, u0: float, u1: float, t: float) -> float:
	var cum: PackedFloat32Array = lo["cum"]
	var spd: PackedFloat32Array = lo["speed"]
	for i in spd.size():
		var a := maxf(cum[i], u0)
		var b := minf(cum[i + 1], u1)
		if b - a <= 1e-6:
			continue
		var dt := (b - a) / spd[i]
		legs.append_array([t, t + dt, a, b, DRIVE])
		t += dt
	return t


func _time_between(lo: Dictionary, u0: float, u1: float) -> float:
	var cum: PackedFloat32Array = lo["cum"]
	var spd: PackedFloat32Array = lo["speed"]
	var t := 0.0
	for i in spd.size():
		var a := maxf(cum[i], u0)
		var b := minf(cum[i + 1], u1)
		if b > a:
			t += (b - a) / spd[i]
	return t


# --- Poses -----------------------------------------------------------------------------------------------

## The point and heading at lap distance u on loop li: [Vector2, heading].
func point_at(li: int, u: float) -> Array:
	var lo: Dictionary = loops[li]
	var pts: PackedVector2Array = lo["pts"]
	var cum: PackedFloat32Array = lo["cum"]
	u = fposmod(u, float(lo["length"]))
	var lo_i := 0
	var hi := pts.size() - 2
	while lo_i < hi:
		var mid := (lo_i + hi + 1) / 2
		if cum[mid] <= u:
			lo_i = mid
		else:
			hi = mid - 1
	var seg := cum[lo_i + 1] - cum[lo_i]
	var f := clampf((u - cum[lo_i]) / maxf(seg, 1e-6), 0.0, 1.0)
	var d := pts[lo_i + 1] - pts[lo_i]
	return [pts[lo_i].lerp(pts[lo_i + 1], f), atan2(d.x, d.y)]


func _lap_time(vid: int, t: float) -> float:
	var v: Dictionary = vehicles[vid]
	var lo: Dictionary = loops[int(v["loop"])]
	return fposmod(t - float(lo["phase"]) - float(v["offset"]), float(lo["L"]))


func lap_index(vid: int, t: float) -> int:
	var v: Dictionary = vehicles[vid]
	var lo: Dictionary = loops[int(v["loop"])]
	return int(floor((t - float(lo["phase"]) - float(v["offset"])) / float(lo["L"])))


## The calm pose of vehicle vid at time t: {x, s, heading, u, v (speed along the lap), mode, lap}.
func base_pose(vid: int, t: float) -> Dictionary:
	var v: Dictionary = vehicles[vid]
	var li := int(v["loop"])
	var lo: Dictionary = loops[li]
	var a := _lap_time(vid, t)
	var legs: PackedFloat64Array = lo["legs"]
	var n := legs.size() / LEG
	var l := 0
	var hi := n - 1
	while l < hi:
		var mid := (l + hi + 1) / 2
		if legs[mid * LEG] <= a:
			l = mid
		else:
			hi = mid - 1
	var o := l * LEG
	var dt := maxf(legs[o + 1] - legs[o], 1e-6)
	var f := clampf((a - legs[o]) / dt, 0.0, 1.0)
	var u := lerpf(legs[o + 2], legs[o + 3], f)
	var pa := point_at(li, u)
	return {"x": (pa[0] as Vector2).x, "s": (pa[0] as Vector2).y, "heading": pa[1], "u": u,
			"v": (legs[o + 3] - legs[o + 2]) / dt, "mode": MODE[int(legs[o + 4])], "lap": lap_index(vid, t)}


## The first lap time at which the lap reaches distance u (the start of a hold there, if it holds there).
func lap_time_at(li: int, u: float) -> float:
	var lo: Dictionary = loops[li]
	u = fposmod(u, float(lo["length"]))
	var legs: PackedFloat64Array = lo["legs"]
	for i in legs.size() / LEG:
		var o := i * LEG
		if legs[o + 3] >= u - 1e-6:
			if legs[o + 3] - legs[o + 2] <= 1e-9:
				return legs[o]
			return lerpf(legs[o], legs[o + 1], clampf((u - legs[o + 2]) / (legs[o + 3] - legs[o + 2]), 0.0, 1.0))
	return 0.0


## The earliest time >= after when vehicle vid's own timetable is at lap distance u again (to rejoin it with no jump).
func rejoin_time(vid: int, u: float, after: float) -> float:
	var v: Dictionary = vehicles[vid]
	var lo: Dictionary = loops[int(v["loop"])]
	var a := lap_time_at(int(v["loop"]), u)
	return after + fposmod(a - _lap_time(vid, after), float(lo["L"]))


## Whether pod vid carries passengers on the lap running at time t, and how many (0 for carts, and while docked).
func riders(vid: int, t: float) -> int:
	if vehicles[vid]["kind"] != "pod":
		return 0
	var k := lap_index(vid, t)
	if lp.h(vid + 70000, k, 77) >= 0.5:
		return 0
	return 1 + (1 if lp.h(vid + 70000, k, 78) < 0.5 else 0)


## The lap distance between two vehicles of one loop, going backward from `ahead` to `behind`.
func gap_behind(li: int, ahead_u: float, behind_u: float) -> float:
	return fposmod(ahead_u - behind_u, float(loops[li]["length"]))


func loop_vehicles(li: int) -> Array[int]:
	var out: Array[int] = []
	for v: Dictionary in vehicles:
		if int(v["loop"]) == li:
			out.append(int(v["id"]))
	return out


## Junction boxes (where roads cross), for the tests: [{rect, j}].
func boxes() -> Array:
	var out: Array = []
	var ns := plan.roads_s.size()
	for i in plan.roads_x.size():
		for k in ns:
			var rx: Dictionary = plan.roads_x[i]
			var rs: Dictionary = plan.roads_s[k]
			out.append({"rect": Rect2(float(rx["a"]), float(rs["a"]), float(rx["b"]) - float(rx["a"]), float(rs["b"]) - float(rs["a"])),
					"j": i * ns + k})
	return out


# --- Driving off-timetable (resuming, fleeing) ---------------------------------------------------------------

## Drive time from lap start to lap distance u (in [0, length]) at the segment speeds, no stops.
func drive_time(li: int, u: float) -> float:
	var lo: Dictionary = loops[li]
	var cum: PackedFloat32Array = lo["cum"]
	var ct: PackedFloat64Array = lo["ctime"]
	var spd: PackedFloat32Array = lo["speed"]
	var i := cum.bsearch(u, false) - 1
	i = clampi(i, 0, spd.size() - 1)
	return ct[i] + (u - cum[i]) / spd[i]


## Inverse of drive_time within one lap.
func _u_at_drive(li: int, tt: float) -> float:
	var lo: Dictionary = loops[li]
	var cum: PackedFloat32Array = lo["cum"]
	var ct: PackedFloat64Array = lo["ctime"]
	var spd: PackedFloat32Array = lo["speed"]
	var i := ct.bsearch(tt, false) - 1
	i = clampi(i, 0, spd.size() - 1)
	return minf(cum[i] + (tt - ct[i]) * spd[i], cum[i + 1])


## Distance driven in time tau from lap distance u0 at the segment speeds, no stops (can run past the lap's end).
func drive_dist(li: int, u0: float, tau: float) -> float:
	var lo: Dictionary = loops[li]
	var length := float(lo["length"])
	var lap := float(lo["drive"])
	var a := fposmod(u0, length)
	var t0 := drive_time(li, a) + maxf(tau, 0.0)
	var laps := floorf(t0 / lap)
	return laps * length + _u_at_drive(li, t0 - laps * lap) - a


## Drive time over `dist` metres from lap distance u0 (dist >= 0, may run past the lap's end).
func drive_time_over(li: int, u0: float, dist: float) -> float:
	var lo: Dictionary = loops[li]
	var length := float(lo["length"])
	var a := fposmod(u0, length)
	var b := a + dist
	var laps := floorf(b / length)
	return laps * float(lo["drive"]) + drive_time(li, b - laps * length) - drive_time(li, a)


## The turn zone (stop line .. clear point) that lap distance u is inside, as an index, or -1.
func zone_at(li: int, u: float) -> int:
	var lo: Dictionary = loops[li]
	var length := float(lo["length"])
	u = fposmod(u, length)
	for z in (lo["zones"] as Array).size():
		var zd: Dictionary = lo["zones"][z]
		var a := float(zd["stop"])
		var d := fposmod(u - a, length)
		if d > 1e-4 and d < fposmod(float(zd["clear"]) - a, length):
			return z
	return -1


## The next turn zone whose stop line is at or ahead of u: [index, distance ahead to its stop line].
func zone_ahead(li: int, u: float, strict: bool = false) -> Array:
	var lo: Dictionary = loops[li]
	var length := float(lo["length"])
	var best := -1
	var bd := INF
	for z in (lo["zones"] as Array).size():
		var d := fposmod(float(lo["zones"][z]["stop"]) - u, length)
		if strict and d < 1e-4:
			d += length
		if d < bd:
			bd = d
			best = z
	return [best, bd]


## The turn zone just behind u: [index, distance back to its clear point].
func zone_behind(li: int, u: float) -> Array:
	var lo: Dictionary = loops[li]
	var length := float(lo["length"])
	var best := -1
	var bd := INF
	for z in (lo["zones"] as Array).size():
		var d := fposmod(u - float(lo["zones"][z]["clear"]), length)
		if d < bd:
			bd = d
			best = z
	return [best, bd]


## How far along the lap (sign +1 ahead, -1 back) from u until the lane is `away` metres from point c (INF if never
## within `max_d`).
func dist_until_away(li: int, u: float, sign: float, c: Vector2, away: float, max_d: float) -> float:
	var d := 0.0
	while d <= max_d:
		var p: Vector2 = point_at(li, u + sign * d)[0]
		if p.distance_to(c) >= away:
			return d
		d += 1.0
	return INF


## The lap distance on loop li nearest to arc point p, if p lies within `reach` of the loop's path, else -1.
func lane_u(li: int, p: Vector2, reach: float) -> float:
	var lo: Dictionary = loops[li]
	var pts: PackedVector2Array = lo["pts"]
	var cum: PackedFloat32Array = lo["cum"]
	var best := -1.0
	var bd := reach
	for i in pts.size() - 1:
		var q := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		var d := q.distance_to(p)
		if d <= bd:
			bd = d
			best = cum[i] + pts[i].distance_to(q)
	return best


## Absolute time (vehicle vid, timetable shifted by `shift`) of its first arrival at lap distance u at or before `t`.
func last_arrival(vid: int, u: float, t: float, shift: float) -> float:
	var v: Dictionary = vehicles[vid]
	var li := int(v["loop"])
	var lo: Dictionary = loops[li]
	var L := float(lo["L"])
	var base := float(lo["phase"]) + float(v["offset"]) + shift + lap_time_at(li, u)
	return base + floorf((t - base) / L) * L


## Absolute time (shifted by `shift`) of the first departure from turn zone z at or after `t`.
func next_departure(vid: int, z: int, t: float, shift: float) -> float:
	var v: Dictionary = vehicles[vid]
	var li := int(v["loop"])
	var lo: Dictionary = loops[li]
	var L := float(lo["L"])
	var base := float(lo["phase"]) + float(v["offset"]) + shift + float(lo["zones"][z]["dep"])
	return base + ceilf((t - base) / L - 1e-9) * L


## The timetable's position unwrapped over laps (lap index x length + lap distance), shifted by `shift`.
func unwrapped(vid: int, t: float, shift: float) -> float:
	var b := base_pose(vid, t - shift)
	return float(b["lap"]) * float(loops[int(vehicles[vid]["loop"])]["length"]) + float(b["u"])


func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	buf.put_utf8_string(lp.checksum())
	for lo: Dictionary in loops:
		buf.put_32(int(lo["block"]))
		buf.put_utf8_string(str(lo["kind"]))
		buf.put_32(int(round(float(lo["length"]) * 1000.0)))
		buf.put_32(int(lo["L"]))
		buf.put_32(int(lo["phase"]))
		var legs: PackedFloat64Array = lo["legs"]
		for x in legs:
			buf.put_32(int(round(x * 1000.0)))
	for v: Dictionary in vehicles:
		buf.put_32(int(v["loop"]))
		buf.put_32(int(round(float(v["offset"]))))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
