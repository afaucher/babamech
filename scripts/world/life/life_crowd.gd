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
const SNAP_VERSION := 2

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


func net_fields() -> Dictionary:
	return {
		"lp": Net.SPAWN,
		# the host's events decide all of these; every machine derives them identically (life.threat, life.down, life.sync)
		"recs": Net.OWNER, "dead": Net.OWNER, "locks": Net.OWNER, "by_src": Net.OWNER,
		"killed_by_players": Net.OWNER, "killed_by_enemies": Net.OWNER, "last_threat": Net.OWNER,
		"riders_used": Net.OWNER, "occupants_killed": Net.OWNER,
	}


func _init(plan: LifePlan = null) -> void:
	lp = plan


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
			return {"x": dd["x"], "s": dd["s"], "h": dd["h"], "heading": dd["heading"], "state": "down", "mode": "down",
					"visible": true, "dist": 0.0, "na": -1, "nb": -1, "door": -1,
					"tip": clampf((t - float(dd["t"])) / TIP_S, 0.0, 1.0), "dx": dd["dx"], "ds": dd["ds"]}
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
		return _still(r, "wary", "wary")
	if int(r["kind"]) == FLEE:
		var t_in := float(r["t_flee"]) + float(r["route"]["length"]) / RUN
		if t < t_in:
			return _on_route(r["route"], (t - float(r["t_flee"])) * RUN, "fleeing", "run")
		var release := lock_end(int(r["door"]), t_in) + RELEASE_SPREAD * lp.h(id, 7)
		if t < release:
			return _indoor(id, int(r["door"]), "sheltered")
		return _timetable(id, t, release)
	var t_up := float(r["last"]) + COWER_S
	if t < t_up:
		return _still(r, "cowering", "cower")
	var walk: Dictionary = r["route"]
	if (walk["pts"] as PackedVector2Array).size() < 2:
		return _timetable(id, t, t_up)
	var speed := float(lp.person(id)["speed"])
	var u := (t - t_up) * speed
	if u < float(walk["length"]):
		return _on_route(walk, u, "calm", "walk")
	return _timetable(id, t, t_up + float(walk["length"]) / speed)


func _still(r: Dictionary, state: String, mode: String) -> Dictionary:
	return {"x": r["x"], "s": r["s"], "h": r["h"], "heading": r["face"], "state": state, "mode": mode, "visible": true,
			"dist": 0.0, "na": r["na"], "nb": r["nb"], "door": -1}


func _on_route(rt: Dictionary, u: float, state: String, mode: String) -> Dictionary:
	var at: Array = LifePlan.along(rt, u)
	var p: Vector2 = at[0]
	var seg: int = at[1]
	var pts: PackedVector2Array = rt["pts"]
	var dir := pts[seg + 1] - pts[seg]
	var ids: PackedInt32Array = rt["nodes"]
	var kind := int((rt["kinds"] as PackedByteArray)[seg])
	return {"x": p.x, "s": p.y, "h": lp.ground_h(p.x, p.y) if kind == LifePlan.CROSS or seg == 0 else CityPlan.CURB_H,
			"heading": atan2(dir.x, dir.y), "state": state, "mode": mode, "visible": true, "dist": u,
			"na": ids[seg], "nb": ids[seg + 1], "door": -1}


# --- Threats ---------------------------------------------------------------------------------------------

## Apply one threat event {x, s, r, st, t} (arc coordinates, metres, strength, shared-clock seconds).
func apply_threat(ev: Dictionary) -> void:
	var T := float(ev.get("t", 0.0))
	var c := Vector2(float(ev.get("x", 0.0)), float(ev.get("s", 0.0)))
	var radius := float(ev.get("r", 0.0))
	var st := int(ev.get("st", 1))
	last_threat = maxf(last_threat, T)
	var reach := maxf(LOCK_R, radius)
	for d in lp.doors.size():
		if (lp.doors[d]["at"] as Vector2).distance_to(c) <= reach:
			_lock(d, T)
	# Cowering people near it keep cowering.
	for id: int in recs.keys():
		var r: Dictionary = recs[id]
		if int(r["kind"]) == COWER and T >= float(r["t0"]) and T < float(r["last"]) + COWER_S \
				and Vector2(r["x"], r["s"]).distance_to(c) <= reach:
			r["last"] = maxf(float(r["last"]), T)
	# Everyone at the time of the threat, for the range test and the ripple's coarse filter.
	var at_t: Array = []
	for id in lp.total():
		at_t.append(pose(id, T))
	var queue: Array = []        # [t, id, point, strength]
	for id in lp.total():
		var p: Dictionary = at_t[id]
		if p["visible"] and p["state"] == "calm" and Vector2(p["x"], p["s"]).distance_to(c) <= radius:
			_alarm(id, T, c, st, queue, at_t)
	while not queue.is_empty():
		queue.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0] or (m[0] == n[0] and m[1] < n[1]))
		var q: Array = queue.pop_front()
		var id: int = q[1]
		var p := pose(id, float(q[0]))
		if p["visible"] and p["state"] == "calm" and Vector2(p["x"], p["s"]).distance_to(q[2]) <= RIPPLE_R:
			_alarm(id, float(q[0]), q[2], int(q[3]), queue, at_t)


## Person `id` notices a threat at time T: flinch, then flee to a refuge or cower.
func _alarm(id: int, T: float, c: Vector2, st: int, queue: Array, at_t: Array) -> void:
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
		r["route"] = _home(p0, int(p["na"]), int(p["nb"]))
	else:
		_lock(door, T)
	var prev: Variant = recs.get(id)
	if prev != null:
		(prev as Dictionary).erase("prev")       # keep two records at most
		r["prev"] = prev
	recs[id] = r
	if int(r["kind"]) == FLEE and st - 1 >= 1:
		var t_flee := float(r["t_flee"])
		for b in lp.total():
			if b == id or at_t.is_empty():
				continue
			var pb: Dictionary = at_t[b]
			if not pb["visible"] or pb["state"] != "calm":
				continue
			var delay := 0.3 + 0.5 * lp.h(b, 8)
			var slack := RIPPLE_R + 2.0 * (t_flee + delay - T) + 1.0
			if Vector2(pb["x"], pb["s"]).distance_to(p0) <= slack:
				queue.append([t_flee + delay, b, p0, st - 1])


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
	dead[id] = {"t": t, "dx": d.x, "ds": d.y, "src": src, "x": float(p["x"]), "s": float(p["s"]), "h": float(p["h"]),
			"heading": float(p["heading"])}
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
		_lock(door, t)
	else:
		r["route"] = _home(p0, n, -1)
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
		for k: String in ["t0", "t_flee", "x", "s", "h", "face", "last"]:
			buf.put_double(float(r[k]))
	return buf.data_array


## Replace the whole state with a snapshot (an empty one clears it).
func restore(bytes: PackedByteArray) -> void:
	reset()
	if bytes.size() < 9:
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_u8() != SNAP_VERSION:
		return
	last_threat = buf.get_double()
	for i in buf.get_u16():
		var s := buf.get_32()
		by_src[s] = buf.get_u16()
	killed_by_players = buf.get_u16()
	killed_by_enemies = buf.get_u16()
	riders_used = buf.get_u16()
	occupants_killed = buf.get_u16()
	for i in buf.get_u16():
		var id := buf.get_u16()
		var dd := {"src": buf.get_32()}
		for k: String in ["t", "dx", "ds", "x", "s", "h", "heading"]:
			dd[k] = buf.get_double()
		dead[id] = dd
	for i in buf.get_u16():
		var d := buf.get_u16()
		var iv := PackedFloat64Array()
		for j in buf.get_u16() * 2:
			iv.append(buf.get_double())
		locks[d] = iv
	for i in buf.get_u16():
		var id := buf.get_u16()
		var r := {"kind": buf.get_u8(), "st": buf.get_u8(), "na": buf.get_32(), "nb": buf.get_32(), "door": buf.get_32()}
		for k: String in ["t0", "t_flee", "x", "s", "h", "face", "last"]:
			r[k] = buf.get_double()
		var p0 := Vector2(r["x"], r["s"])
		if int(r["kind"]) == FLEE and int(r["door"]) >= 0:
			r["route"] = lp.route(p0, int(r["na"]), int(r["nb"]), int(r["door"]))
		else:
			r["route"] = _home(p0, int(r["na"]), int(r["nb"]))
		if id < lp.total():
			recs[id] = r
