class_name LifeCrowd
extends RefCounted
## The civilians' state on top of their timetables (docs/design/ambient-life.md sections 4, 6 and 8): the shared agent
## store and threat system. No nodes, no clock of its own: every query names its time, and the state only changes through
## two host events, applied in order on every machine:
##   apply_threat({x, s, r, st, t})       a threat at arc point (x, s), radius r, strength st, shared-clock time t
##   kill(id, t, dir, src)                a civilian is killed (life.down)
## Everything a threat does is derived here, identically on every machine: who is in range (by their pose at t), the
## flinch delay (a hash of the id), the refuge (the nearest door away from the threat, a pure function of the plan), the
## ripple (calm people within RIPPLE_R of someone who starts to flee get a threat of strength - 1 a moment later), door
## lock-downs (nobody leaves a door for LOCK_S after a threat within LOCK_R of it) and calming down.
## States: calm, wary, fleeing, sheltered, cowering, down ("hands_up" is a local look added by AmbientLife).
## Vehicles (later phases) are meant to read the same threats and add their own records next to `recs`.

const RUN := 4.5              ## m/s fleeing
const REFUGE := 40.0          ## m: no door this close (straight line) -> cower
const REFUGE_COST := 60.0     ## m of walking at most to a refuge
const COWER_NEAR := 8.0       ## m: a threat this close -> cower at once
const LOCK_R := 60.0          ## m: doors and cowering people within this of a threat (or its radius) remember it
const LOCK_S := 45.0          ## s: doors let nobody out until this long after the last threat near them
const RELEASE_SPREAD := 6.0   ## s: people leave a door over this long after it opens
const COWER_S := 20.0         ## s: a cowering person stands up this long after the last threat near them
const RIPPLE_R := 8.0         ## m
const TIP_S := 0.4            ## s: a killed person tips over in this long
const FLEE := 0
const COWER := 1
const SNAP_VERSION := 3        ## 3: alarm records carry the cowering spot (cx, cs)

var lp: LifePlan
var recs: Dictionary = {}       ## id -> alarm record (the latest; older ones chained under "prev")
var dead: Dictionary = {}       ## id -> {t, dx, ds, src, x, s, h, heading}
var locks: Dictionary = {}      ## door -> PackedFloat64Array [a0, b0, a1, b1, ...] lock-down intervals, merged, sorted
var by_src: Dictionary = {}     ## src -> civilians killed
var killed_by_players := 0
var killed_by_enemies := 0
var last_threat := -INF         ## time of the latest threat anywhere
var riders_used := 0            ## rider slots handed out (LifePlan.RIDERS at most per mission)
var occupants_killed := 0       ## pod passengers killed inside a wrecked pod (no figures; also in the tallies above)
## Per-threat cost (results identical either way; tests/test_life_threat_grid.gd runs both): door points as a packed
## array, and per person the slot its box was worked out for. brute_force: the reference path (everyone's pose).
var brute_force := false
var _door_at := PackedVector2Array()
var _ph := PackedFloat64Array()       ## person -> timetable phase / period (as LifePlan.slot_of reads them)
var _per := PackedFloat64Array()
var _box_k := PackedInt64Array()      ## person -> the slot its cached box is for (INT64_MIN: none)
var _box_ts := PackedFloat64Array()   ## ... that trip's start
var _box: Array = []                  ## ... Rect2, or false (no trip in that slot)


func net_fields() -> Dictionary:
	return {
		"lp": Net.SPAWN,
		# the host's events decide all of these; every machine derives them identically (life.threat, life.down, life.sync)
		"recs": Net.OWNER, "dead": Net.OWNER, "locks": Net.OWNER, "by_src": Net.OWNER,
		"killed_by_players": Net.OWNER, "killed_by_enemies": Net.OWNER, "last_threat": Net.OWNER,
		"riders_used": Net.OWNER, "occupants_killed": Net.OWNER,
		# derived caches (pure functions of the plan), never sent
		"brute_force": Net.LOCAL, "_door_at": Net.LOCAL, "_ph": Net.LOCAL, "_per": Net.LOCAL, "_box_k": Net.LOCAL,
		"_box_ts": Net.LOCAL, "_box": Net.LOCAL,
	}


func _init(plan: LifePlan = null) -> void:
	lp = plan
	if lp == null:
		return
	for d: Dictionary in lp.doors:
		_door_at.append(d["at"])
	for pp: Dictionary in lp.people:
		_ph.append(float(pp["phase"]))
		_per.append(float(pp["period"]))
	_box_k.resize(lp.count)
	_box_k.fill(-9223372036854775807)
	_box_ts.resize(lp.count)
	_box.resize(lp.count)


func reset() -> void:
	recs.clear()
	dead.clear()
	locks.clear()
	by_src.clear()
	killed_by_players = 0
	killed_by_enemies = 0
	last_threat = -INF
	riders_used = 0
	occupants_killed = 0


# --- Locks -----------------------------------------------------------------------------------------------

func _lock(d: int, t: float) -> void:
	var iv: PackedFloat64Array = locks.get(d, PackedFloat64Array())
	var a := t
	var b := t + LOCK_S
	var out := PackedFloat64Array()
	var placed := false
	var i := 0
	while i < iv.size():
		var ia := iv[i]
		var ib := iv[i + 1]
		if ib < a:
			out.append(ia)
			out.append(ib)
		elif ia > b:
			if not placed:
				out.append(a)
				out.append(b)
				placed = true
			out.append(ia)
			out.append(ib)
		else:
			a = minf(a, ia)
			b = maxf(b, ib)
		i += 2
	if not placed:
		out.append(a)
		out.append(b)
	locks[d] = out


func is_locked(d: int, t: float) -> bool:
	var iv: PackedFloat64Array = locks.get(d, PackedFloat64Array())
	var i := 0
	while i < iv.size():
		if t >= iv[i] and t < iv[i + 1]:
			return true
		i += 2
	return false


## The end of the lock-down that covers time t at door d (t if none).
func lock_end(d: int, t: float) -> float:
	var iv: PackedFloat64Array = locks.get(d, PackedFloat64Array())
	var i := 0
	while i < iv.size():
		if t >= iv[i] and t <= iv[i + 1]:
			return iv[i + 1]
		i += 2
	return t


# --- Poses -----------------------------------------------------------------------------------------------

## The pose of person `id` at time t: LifePlan.calm_pose's fields plus `state` (calm | wary | fleeing | sheltered |
## cowering | down), `mode` (walk | wait | sit | run | wary | cower | indoor | down) and, when down, `tip` (0..1) and
## `dx` / `ds` (the direction it falls).
func pose(id: int, t: float) -> Dictionary:
	if dead.has(id):
		var dd: Dictionary = dead[id]
		if t >= float(dd["t"]):
			var tip := clampf((t - float(dd["t"])) / TIP_S, 0.0, 1.0)
			return {"x": lerpf(float(dd.get("x0", dd["x"])), float(dd["x"]), tip),
					"s": lerpf(float(dd.get("s0", dd["s"])), float(dd["s"]), tip), "h": dd["h"], "heading": dd["heading"], "state": "down", "mode": "down",
					"visible": true, "dist": 0.0, "na": -1, "nb": -1, "door": -1,
					"tip": tip, "dx": dd["dx"], "ds": dd["ds"]}
	var r: Variant = recs.get(id)
	while r != null and t < float((r as Dictionary)["t0"]):
		r = (r as Dictionary).get("prev")
	if r == null:
		return _timetable(id, t, -INF)
	return _rec_pose(id, r, t)


func state_of(id: int, t: float) -> String:
	return str(pose(id, t)["state"])


func _indoor(id: int, door: int, state: String) -> Dictionary:
	var at: Vector2 = lp.doors[door]["at"] if door >= 0 and door < lp.doors.size() else Vector2.ZERO
	return {"x": at.x, "s": at.y, "h": CityPlan.CURB_H, "heading": 0.0, "state": state, "mode": "indoor", "visible": false,
			"dist": 0.0, "na": -1, "nb": -1, "door": door}


## The timetable with lock-downs, resuming only with trips that start at or after R.
func _timetable(id: int, t: float, resume: float) -> Dictionary:
	if id >= lp.count:
		return _indoor(id, -1, "calm")      # a rider: inside a pod, or gone indoors for good
	var k := lp.slot_of(id, t)
	var tr := lp.trip(id, k)
	var p := lp.pose_in_trip(tr, t)
	if p["visible"] and (float(tr["t_start"]) < resume or is_locked(int(tr["door_a"]), float(tr["t_start"]))):
		return _indoor(id, int(tr["door_a"]), "calm")
	p["mode"] = "indoor" if not p["visible"] else ("sit" if p["state"] == "sit" else ("wait" if p["state"] == "wait" else "walk"))
	p["state"] = "calm"
	return p


func _rec_pose(id: int, r: Dictionary, t: float) -> Dictionary:
	if t < float(r["t_flee"]):
		var p := _still(r, "wary", "wary")
		if int(r["kind"]) == COWER:     # a step to its own cowering spot while flinching
			var f := clampf((t - float(r["t0"])) / maxf(float(r["t_flee"]) - float(r["t0"]), 1e-3), 0.0, 1.0)
			p["x"] = lerpf(float(r["x"]), float(r["cx"]), f)
			p["s"] = lerpf(float(r["s"]), float(r["cs"]), f)
		return p
	if int(r["kind"]) == FLEE:
		var t_in := float(r["t_flee"]) + float(r["route"]["length"]) / RUN
		if t < t_in:
			return _on_route(r["route"], (t - float(r["t_flee"])) * RUN, "fleeing", "run", lp.lane_of(id))
		var release := lock_end(int(r["door"]), t_in) + RELEASE_SPREAD * lp.h(id, 7)
		if t < release:
			return _indoor(id, int(r["door"]), "sheltered")
		return _timetable(id, t, release)
	var t_up := float(r["last"]) + COWER_S
	if t < t_up:
		var c := _still(r, "cowering", "cower")
		c["x"] = r["cx"]
		c["s"] = r["cs"]
		return c
	var walk: Dictionary = r["route"]
	if (walk["pts"] as PackedVector2Array).size() < 2:
		return _timetable(id, t, t_up)
	var speed := float(lp.person(id)["speed"])
	var u := (t - t_up) * speed
	if u < float(walk["length"]):
		return _on_route(walk, u, "calm", "walk", lp.lane_of(id))
	return _timetable(id, t, t_up + float(walk["length"]) / speed)


func _still(r: Dictionary, state: String, mode: String) -> Dictionary:
	return {"x": r["x"], "s": r["s"], "h": r["h"], "heading": r["face"], "state": state, "mode": mode, "visible": true,
			"dist": 0.0, "na": r["na"], "nb": r["nb"], "door": -1}


## Point u along route rt, walked `lat` m to the right of its line (crowd spacing: the walking lanes; the route's first
## point, where the person stood, is not offset; joints are mitred so the path stays continuous).
func _on_route(rt: Dictionary, u: float, state: String, mode: String, lat: float = 0.0) -> Dictionary:
	var at: Array = LifePlan.along(rt, u)
	var seg: int = at[1]
	var pts: PackedVector2Array = rt["pts"]
	var cum: PackedFloat32Array = rt["cum"]
	var f := clampf((u - cum[seg]) / maxf(cum[seg + 1] - cum[seg], 1e-6), 0.0, 1.0)
	var a := _route_joint(pts, seg, lat)
	var b := _route_joint(pts, seg + 1, lat)
	var p := a.lerp(b, f)
	var dir := b - a if a.distance_squared_to(b) > 1e-8 else pts[seg + 1] - pts[seg]
	var ids: PackedInt32Array = rt["nodes"]
	var kind := int((rt["kinds"] as PackedByteArray)[seg])
	return {"x": p.x, "s": p.y, "h": lp.ground_h(p.x, p.y) if kind == LifePlan.CROSS or seg == 0 else CityPlan.CURB_H,
			"heading": atan2(dir.x, dir.y), "state": state, "mode": mode, "visible": true, "dist": u,
			"na": ids[seg], "nb": ids[seg + 1], "door": -1}


static func _route_joint(pts: PackedVector2Array, i: int, lat: float) -> Vector2:
	if i == 0 or lat == 0.0:
		return pts[i]
	var last := pts.size() - 1
	var d_in := (pts[i] - pts[i - 1]).normalized()
	if i == last:
		return pts[i] + Vector2(d_in.y, -d_in.x) * lat
	var d_out := (pts[i + 1] - pts[i]).normalized()
	return pts[i] + LifePlan.miter(d_in, d_out, lat)


# --- Threats ---------------------------------------------------------------------------------------------

## Apply one threat event {x, s, r, st, t} (arc coordinates, metres, strength, shared-clock seconds).
func apply_threat(ev: Dictionary) -> void:
	var T := float(ev.get("t", 0.0))
	var c := Vector2(float(ev.get("x", 0.0)), float(ev.get("s", 0.0)))
	var radius := float(ev.get("r", 0.0))
	var st := int(ev.get("st", 1))
	last_threat = maxf(last_threat, T)
	var reach := maxf(LOCK_R, radius)
	for d in _door_at.size():
		if _door_at[d].distance_to(c) <= reach:
			_lock(d, T)
	# Cowering people near it keep cowering.
	for id: int in recs.keys():
		var r: Dictionary = recs[id]
		if int(r["kind"]) == COWER and T >= float(r["t0"]) and T < float(r["last"]) + COWER_S \
				and Vector2(r["x"], r["s"]).distance_to(c) <= reach:
			r["last"] = maxf(float(r["last"]), T)
	# Everyone at the time of the threat, for the range test and the ripple's coarse filter: [poses, boxes]. A pose is
	# computed only when the person's box (where its current trip can be at all) reaches the area that is tested, which
	# gives exactly the results of computing everyone: the skipped could not pass the distance test. Poses that a change
	# made during this event could alter are computed before it: alarmed people and the dead (now), anyone whose trip
	# starts exactly at T (a lock-down at T could keep them in), and a person just before its record is replaced.
	var n := lp.total()
	var at_t: Array = []
	at_t.resize(n)
	var boxes: Array = []
	boxes.resize(n)
	for id in n:
		var b: Variant = null if brute_force else _reach_box(id, T)
		boxes[id] = b
		if b == null:
			at_t[id] = pose(id, T)
	var near := [at_t, boxes, T]
	var queue: Array = []        # [t, id, point, strength]
	for id in n:
		var p: Variant = _near_pose(near, id, T, c, radius)
		if p != null and p["visible"] and p["state"] == "calm" and Vector2(p["x"], p["s"]).distance_to(c) <= radius:
			_alarm(id, T, c, st, queue, near)
	while not queue.is_empty():
		queue.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0] or (m[0] == n[0] and m[1] < n[1]))
		var q: Array = queue.pop_front()
		var id: int = q[1]
		var p := pose(id, float(q[0]))
		if p["visible"] and p["state"] == "calm" and Vector2(p["x"], p["s"]).distance_to(q[2]) <= RIPPLE_R:
			_alarm(id, float(q[0]), q[2], int(q[3]), queue, near)


## Where person id can be during the trip it is on at T: a Rect2 (its pose at T is inside), false when it cannot be
## outdoors and calm at T (a rider still inside, the dead, no trip), or null when its pose must be computed exactly.
func _reach_box(id: int, T: float) -> Variant:
	if recs.has(id):
		return null
	if dead.has(id):
		return false if float(dead[id]["t"]) <= T else null
	if id >= lp.count:
		return false            # a rider not yet let out: inside its pod
	var k := int(floor((T - _ph[id]) / _per[id]))      # = LifePlan.slot_of(id, T)
	if _box_k[id] != k:
		var tr := lp.trip(id, k)
		_box_k[id] = k
		_box_ts[id] = float(tr["t_start"])
		_box[id] = false if int(tr["n"]) == 0 else lp.trip_box(tr)
	if _box[id] is bool:
		return false
	if _box_ts[id] == T:
		return null
	return _box[id]


## Person id's pose at T if its box reaches the disc (c, r), else null (it cannot be within r of c). Memoised in `near`.
func _near_pose(near: Array, id: int, T: float, c: Vector2, r: float) -> Variant:
	var at_t: Array = near[0]
	if at_t[id] != null:
		return at_t[id]
	var b: Variant = (near[1] as Array)[id]
	if b is bool:
		return null
	var box: Rect2 = b
	var q := Vector2(clampf(c.x, box.position.x, box.end.x), clampf(c.y, box.position.y, box.end.y))
	if q.distance_to(c) > r + 0.05:
		return null
	at_t[id] = pose(id, T)
	return at_t[id]


## Person `id` notices a threat at time T: flinch, then flee to a refuge or cower.
func _alarm(id: int, T: float, c: Vector2, st: int, queue: Array, near: Array) -> void:
	if dead.has(id) and float(dead[id]["t"]) <= T:
		return
	var t_alarm := T + 0.1 + 0.3 * lp.h(id, 5)
	var p := pose(id, t_alarm)
	if not p["visible"] or p["state"] != "calm":
		return
	var p0 := Vector2(p["x"], p["s"])
	var wary := 0.15 if st >= 2 else 0.5 + 0.5 * lp.h(id, 6)
	var r := {"t0": t_alarm, "t_flee": t_alarm + wary, "x": p0.x, "s": p0.y, "h": p["h"], "na": p["na"], "nb": p["nb"],
			"face": atan2(c.x - p0.x, c.y - p0.y), "st": st, "door": -1, "last": T, "kind": COWER}
	var door := -1
	if p0.distance_to(c) >= COWER_NEAR:
		door = lp.pick_door(p0, int(p["na"]), int(p["nb"]), REFUGE, REFUGE_COST, c)
	if door >= 0:
		r["kind"] = FLEE
		r["door"] = door
		r["route"] = lp.route(p0, int(p["na"]), int(p["nb"]), door)
		if (r["route"]["pts"] as PackedVector2Array).size() < 2:
			r["kind"] = COWER
	if int(r["kind"]) == COWER:
		var spot := _cower_spot(id, p0, T)
		r["cx"] = spot.x
		r["cs"] = spot.y
		r["route"] = _home(spot, int(p["na"]), int(p["nb"]))
	else:
		r["cx"] = p0.x
		r["cs"] = p0.y
		_lock(door, T)
	var at_t: Array = near[0]
	if at_t[id] == null and not ((near[1] as Array)[id] is bool):
		at_t[id] = pose(id, float(near[2]))      # its pose at the event's time, before its record changes
	var prev: Variant = recs.get(id)
	if prev != null:
		(prev as Dictionary).erase("prev")       # keep two records at most
		r["prev"] = prev
	recs[id] = r
	if int(r["kind"]) == FLEE and st - 1 >= 1:
		var t_flee := float(r["t_flee"])
		var t_ev := float(near[2])
		var reach := RIPPLE_R + 2.0 * (t_flee + 0.8 - T) + 1.0     # the largest slack below (delay <= 0.8 s)
		for b in lp.total():
			if b == id:
				continue
			var pv: Variant = _near_pose(near, b, t_ev, p0, reach)
			if pv == null:
				continue
			var pb: Dictionary = pv
			if not pb["visible"] or pb["state"] != "calm":
				continue
			var delay := 0.3 + 0.5 * lp.h(b, 8)
			var slack := RIPPLE_R + 2.0 * (t_flee + delay - T) + 1.0
			if Vector2(pb["x"], pb["s"]).distance_to(p0) <= slack:
				queue.append([t_flee + delay, b, p0, st - 1])


const SPREAD := 0.8           ## m: cowering spots and resting bodies keep at least this far apart (crowd spacing)


## Where person `id` cowers when alarmed at p0 at time T: p0, or the nearest of a few deterministic spots round it that is
## SPREAD m clear of everyone already cowering there (records are made in event order, the same on every machine).
func _cower_spot(id: int, p0: Vector2, T: float) -> Vector2:
	var taken := PackedVector2Array()
	for o: int in recs:
		var r: Dictionary = recs[o]
		if o != id and int(r["kind"]) == COWER and T < float(r["last"]) + COWER_S and r.has("cx"):
			var q := Vector2(r["cx"], r["cs"])
			if q.distance_to(p0) < SPREAD * 4.0:
				taken.append(q)
	return _clear_spot(id, p0, taken, true)


## p0 or the first spot on rings of SPREAD round it (start angle from the id) clear of `taken`; on a person's footing
## (never in a building or a floor cut) when `walkable`.
func _clear_spot(id: int, p0: Vector2, taken: PackedVector2Array, walkable: bool) -> Vector2:
	var a0 := lp.h(id, 63) * TAU
	for ring in 4:
		var n := 1 if ring == 0 else 6 * ring
		for k in n:
			var ang := a0 + TAU * float(k) / float(n)
			var p := p0 + Vector2(cos(ang), sin(ang)) * (SPREAD * float(ring))
			var ok := true
			for q in taken:
				if q.distance_to(p) < SPREAD:
					ok = false
					break
			if ok and walkable and ring > 0:
				for r in lp._foot:
					if r.grow(0.3).has_point(p):
						ok = false
						break
				for r in lp._cuts:
					if r.has_point(p):
						ok = false
						break
			if ok:
				return p
	return p0


## The calm walk to the nearest door after cowering (empty pts if none within reach).
func _home(p0: Vector2, na: int, nb: int) -> Dictionary:
	var d := lp.pick_door(p0, na, nb, 120.0, 400.0)
	if d < 0:
		return {"pts": PackedVector2Array(), "kinds": PackedByteArray(), "nodes": PackedInt32Array(), "cum": PackedFloat32Array(), "length": 0.0}
	return lp.route(p0, na, nb, d)


# --- Killing ---------------------------------------------------------------------------------------------

## Person `id` is killed at time t, falling along `dir` (deck plane, x / s). `force`: even if this machine thinks the
## person is indoors (an event from the host). Returns whether it changed anything.
func kill(id: int, t: float, dir: Vector2, src: int, force: bool = false) -> bool:
	if id < 0 or id >= lp.total() or dead.has(id):
		return false
	var p := pose(id, t)
	if not p["visible"] and not force:
		return false
	var d := dir.normalized() if dir.length_squared() > 1e-8 else Vector2(0.0, 1.0)
	# Bodies settle apart: a body that would lie within SPREAD of another rests at the nearest clear spot (kills apply in
	# the host's event order on every machine, so every machine picks the same; a dead body is not a hit target).
	var at := Vector2(float(p["x"]), float(p["s"]))
	var near := PackedVector2Array()
	for o: int in dead:
		var q := Vector2(dead[o]["x"], dead[o]["s"])
		if q.distance_to(at) < SPREAD * 4.0:
			near.append(q)
	if not near.is_empty():
		at = _clear_spot(id, at, near, true)
	dead[id] = {"t": t, "dx": d.x, "ds": d.y, "src": src, "x": at.x, "s": at.y, "h": float(p["h"]),
			"heading": float(p["heading"]), "x0": float(p["x"]), "s0": float(p["s"])}
	by_src[src] = int(by_src.get(src, 0)) + 1
	if src >= 0:
		killed_by_players += 1
	else:
		killed_by_enemies += 1
	return true


func tally() -> Dictionary:
	return {"killed_by_players": killed_by_players, "killed_by_enemies": killed_by_enemies, "by_src": by_src.duplicate(),
			"dead": dead.size(), "occupants_killed": occupants_killed}


## Passengers killed inside a pod (no figures): counted like any civilian, and in occupants_killed.
func add_occupant_kills(n: int, src: int) -> void:
	if n <= 0:
		return
	occupants_killed += n
	by_src[src] = int(by_src.get(src, 0)) + n
	if src >= 0:
		killed_by_players += n
	else:
		killed_by_enemies += n


## A pod passenger gets out at time t at arc point p0 (on the road beside the pod) and reacts at once to the threat at c
## (strength st): a rider slot is taken (the next free one, so every machine picks the same), or -1 when all are used.
func spawn_rider(t: float, p0: Vector2, c: Vector2, st: int) -> int:
	if riders_used >= LifePlan.RIDERS:
		return -1
	var id := lp.count + riders_used
	riders_used += 1
	var n := lp.nearest_node(p0)
	var r := {"t0": t, "t_flee": t + 0.3 + 0.3 * lp.h(id, 6), "x": p0.x, "s": p0.y, "h": lp.ground_h(p0.x, p0.y),
			"na": n, "nb": -1, "face": atan2(c.x - p0.x, c.y - p0.y), "st": st, "door": -1, "last": t, "kind": COWER}
	var door := -1
	if p0.distance_to(c) >= COWER_NEAR:
		door = lp.pick_door(p0, n, -1, REFUGE, REFUGE_COST, c)
	if door >= 0:
		r["kind"] = FLEE
		r["door"] = door
		r["route"] = lp.route(p0, n, -1, door)
		r["cx"] = p0.x
		r["cs"] = p0.y
		_lock(door, t)
	else:
		var spot := _cower_spot(id, p0, t)
		r["cx"] = spot.x
		r["cs"] = spot.y
		r["route"] = _home(spot, n, -1)
	recs[id] = r
	return id


## How many sheltered people are inside door d at time t.
func door_count(d: int, t: float) -> int:
	var n := 0
	for id: int in recs.keys():
		if int(recs[id]["door"]) == d and state_of(id, t) == "sheltered":
			n += 1
	return n


# --- Snapshot (late join) ----------------------------------------------------------------------------------

## What differs from the timetable at time `now`: tallies, the dead, live lock-downs and live alarm records.
func snapshot(now: float) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(SNAP_VERSION)
	buf.put_double(last_threat)
	var srcs := by_src.keys()
	srcs.sort()
	buf.put_u16(srcs.size())
	for s: int in srcs:
		buf.put_32(s)
		buf.put_u16(int(by_src[s]))
	buf.put_u16(killed_by_players)
	buf.put_u16(killed_by_enemies)
	buf.put_u16(riders_used)
	buf.put_u16(occupants_killed)
	var ids := dead.keys()
	ids.sort()
	buf.put_u16(ids.size())
	for id: int in ids:
		var dd: Dictionary = dead[id]
		buf.put_u16(id)
		buf.put_32(int(dd["src"]))
		for k: String in ["t", "dx", "ds", "x", "s", "h", "heading"]:
			buf.put_double(float(dd[k]))
	var ds := locks.keys()
	ds.sort()
	var keep_locks: Array = []
	for d: int in ds:
		var iv: PackedFloat64Array = locks[d]
		var kept := PackedFloat64Array()
		var i := 0
		while i < iv.size():
			if iv[i + 1] > now - 400.0:
				kept.append(iv[i])
				kept.append(iv[i + 1])
			i += 2
		if not kept.is_empty():
			keep_locks.append([d, kept])
	buf.put_u16(keep_locks.size())
	for l: Array in keep_locks:
		buf.put_u16(int(l[0]))
		var kept: PackedFloat64Array = l[1]
		buf.put_u16(kept.size() / 2)
		for v in kept:
			buf.put_double(v)
	var rids := recs.keys()
	rids.sort()
	var live: Array = []
	for id: int in rids:
		if float(recs[id]["last"]) > now - 400.0:
			live.append(id)
	buf.put_u16(live.size())
	for id: int in live:
		var r: Dictionary = recs[id]
		buf.put_u16(id)
		buf.put_u8(int(r["kind"]))
		buf.put_u8(int(r["st"]))
		buf.put_32(int(r["na"]))
		buf.put_32(int(r["nb"]))
		buf.put_32(int(r["door"]))
		for k: String in ["t0", "t_flee", "x", "s", "h", "face", "last", "cx", "cs"]:
			buf.put_double(float(r[k]))
	return buf.data_array


## Replace the whole state with a snapshot (an empty one clears it). The bytes come from a peer (life.sync): every count
## is checked against the bytes left before its records are read (a truncated or padded-out buffer is rejected as a
## whole: a warning and the cleared state), and a record naming a person, door or walk node this plan does not have is
## skipped, so nothing reads past the end, loops on garbage or routes from an index out of range.
func restore(bytes: PackedByteArray) -> void:
	reset()
	if bytes.size() < 9:
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_u8() != SNAP_VERSION:
		return
	if not _restore_from(buf):
		reset()
		push_warning("LifeCrowd.restore: malformed snapshot (%d bytes): ignored" % bytes.size())


## Bytes of one record in snapshot(): a dead body, an alarm record.
const SNAP_DEAD := 2 + 4 + 7 * 8
const SNAP_REC := 2 + 1 + 1 + 3 * 4 + 9 * 8


func _restore_from(buf: StreamPeerBuffer) -> bool:
	last_threat = buf.get_double()
	if buf.get_available_bytes() < 2:
		return false
	var n := buf.get_u16()
	if buf.get_available_bytes() < n * 6 + 8:
		return false
	for i in n:
		var s := buf.get_32()
		by_src[s] = buf.get_u16()
	killed_by_players = buf.get_u16()
	killed_by_enemies = buf.get_u16()
	riders_used = buf.get_u16()
	occupants_killed = buf.get_u16()
	if buf.get_available_bytes() < 2:
		return false
	n = buf.get_u16()
	if buf.get_available_bytes() < n * SNAP_DEAD:
		return false
	for i in n:
		var id := buf.get_u16()
		var dd := {"src": buf.get_32()}
		for k: String in ["t", "dx", "ds", "x", "s", "h", "heading"]:
			dd[k] = buf.get_double()
		if id < lp.total():
			dead[id] = dd
	if buf.get_available_bytes() < 2:
		return false
	n = buf.get_u16()
	for i in n:
		if buf.get_available_bytes() < 4:
			return false
		var d := buf.get_u16()
		var m := buf.get_u16()
		if buf.get_available_bytes() < m * 16:
			return false
		var iv := PackedFloat64Array()
		for j in m * 2:
			iv.append(buf.get_double())
		if d < lp.doors.size():
			locks[d] = iv
	if buf.get_available_bytes() < 2:
		return false
	n = buf.get_u16()
	if buf.get_available_bytes() != n * SNAP_REC:
		return false
	var nodes := lp.nodes.size()
	for i in n:
		var id := buf.get_u16()
		var r := {"kind": buf.get_u8(), "st": buf.get_u8(), "na": buf.get_32(), "nb": buf.get_32(), "door": buf.get_32()}
		for k: String in ["t0", "t_flee", "x", "s", "h", "face", "last", "cx", "cs"]:
			r[k] = buf.get_double()
		if id >= lp.total() or int(r["kind"]) not in [FLEE, COWER] or int(r["na"]) < -1 or int(r["na"]) >= nodes \
				or int(r["nb"]) < -1 or int(r["nb"]) >= nodes or int(r["door"]) < -1 or int(r["door"]) >= lp.doors.size():
			continue
		var p0 := Vector2(r["x"], r["s"])
		if int(r["kind"]) == FLEE and int(r["door"]) >= 0:
			r["route"] = lp.route(p0, int(r["na"]), int(r["nb"]), int(r["door"]))
		else:
			r["route"] = _home(Vector2(r["cx"], r["cs"]), int(r["na"]), int(r["nb"]))
		recs[id] = r
	return true
