class_name LifeFleet
extends RefCounted
## The vehicles' state on top of their timetables (docs/design/ambient-life.md section 5): no nodes, no clock; every
## query names its time, and the state only changes through host events applied in order on every machine:
##   apply_threat(ev, crowd)      the same threat events as the people ({x, s, r, st, t})
##   wreck(ev, crowd)             life.wreck {id, t, x, s, yaw, tilt0, tilt1, roll, dir, v0, len, src}
##
## Per loop, an EPISODE starts at each event that touches it (a threat within ESTOP_R of one of its vehicles, a wreck of
## one of them, or a wreck landing in / leaving its lane). It anchors every vehicle of the loop where it is then and:
##   * on a threat (a held episode): the vehicles in range e-stop (reaction 0.2-0.5 s, 10 m/s^2, hazards); an occupied
##     pod lets 1-2 passengers out 0.8 s after stopping; a pod with nobody aboard (or 1.5 s after its last passenger got
##     out) speeds AWAY from the threat along its own lane: forward up to 14 m/s (5 m/s^2 up, 8 m/s^2 down) if the threat
##     is behind, reversing up to 8 m/s if it is ahead, until it is 80 m from the threat, short of the next stop line (or
##     the last clear point behind), and 6 m short of any vehicle or wreck; with less than 10 m of clear lane it stays
##     abandoned with hazards. The rest of the loop just brakes to a stop. All of it is held until RESTART s after the
##     last threat in range (merged lock-downs);
##   * then (or at once, for an episode that does not hold) every vehicle drives on from where it stands at its lane's
##     speeds, waits at the next stop line for its own timetable, and from there IS its timetable again, shifted by a whole
##     number of turn-phase periods (30 s) so turns still fall in the turn phases. The shift is one value per loop (the
##     episode's `shift`), the smallest that keeps every vehicle's timetable behind where it restarts, so the loop's
##     spacing is kept. A vehicle halted inside a turn finishes it in the next turn phase;
##   * at all times a vehicle stays 6 m short of the vehicle ahead on its loop and of any wreck lying in its lane; if that
##     spot is inside a junction it waits at the stop line before it instead.
## A wreck never drives again: it is shoved and tipped like a street prop (the slide is CityPropSim's SHOVE, called
## read-only, with the vehicle's mass; the tip-over is the same kind of closed form, done here). Passengers still inside
## are killed (counted, no figures).

const ESTOP_R := 30.0
const DECEL := 10.0
const RESTART := 15.0
const GAP := 6.0                ## m, bumper to bumper, to the vehicle or wreck ahead
const FWD_ACC := 5.0
const FWD_V := 14.0
const FWD_DEC := 8.0
const REV_ACC := 4.0
const REV_V := 8.0
const REV_DEC := 6.0
const FLEE_AWAY := 80.0
const FLEE_MIN := 10.0
const DOORS := 0.8              ## s after stopping, the doors open
const RIDER_GO := 1.5           ## s after the last passenger got out, the pod may leave
const IN_LANE := 2.4            ## m: a wreck this close to a loop's path blocks that loop
const SHIFT_STEP := 30.0        ## s: the turn phases repeat every half signal cycle
const MASS := {"pod": 900.0, "cart": 500.0}
const SHOVE_CAP := 10.0         ## m/s: the fastest a vehicle wreck starts sliding (before its mass)
const TIP_S := 0.7
const NONE := 0
const FWD := 1
const REV := 2
const SNAP_VERSION := 3          ## 3: the pods' unloads (2026-11-25)

var tr: LifeTraffic
var episodes: Dictionary = {}   ## loop -> its latest episode (the one before under "prev")
var locks: Dictionary = {}      ## loop -> PackedFloat64Array [a0, b0, ...]: held until b
var wrecks: Dictionary = {}     ## vid -> its last wreck event
## pod vid -> {doors, n, riders, rider0}: the one time it let its passengers out (doors: the first steps out then, rider
## k at doors + 0.4 k; n aboard, `riders` of them got a rider slot from rider0 on). Kept past the episode that planned it,
## so a later wreck knows who is out and who is still inside, and the pod never lets anyone out again (it ran empty).
var unloads: Dictionary = {}
var brute_force := false        ## the reference path for tests: every vehicle's pose on every threat
var _loop_box: Array = []       ## loop -> Rect2 holding every pose a vehicle on it can have (its path, grown LOOP_SLACK)
const LOOP_SLACK := 5.0         ## m: a vehicle that is not a wreck is on its loop's path (docked / pulled over: within this)


func net_fields() -> Dictionary:
	return {
		"tr": Net.SPAWN,
		"episodes": Net.OWNER, "locks": Net.OWNER, "wrecks": Net.OWNER,    # decided by the host's events, derived everywhere
		"unloads": Net.OWNER,                                              # the same (from the episodes), in the snapshot
		"brute_force": Net.LOCAL, "_loop_box": Net.LOCAL,                 # test switch / derived from the plan
	}


func _init(traffic: LifeTraffic = null) -> void:
	tr = traffic


func reset() -> void:
	episodes.clear()
	locks.clear()
	wrecks.clear()
	unloads.clear()


# --- Locks -----------------------------------------------------------------------------------------------

func _lock(li: int, a: float, b: float) -> void:
	var iv: PackedFloat64Array = locks.get(li, PackedFloat64Array())
	var out := PackedFloat64Array()
	var placed := false
	var i := 0
	while i < iv.size():
		if iv[i + 1] < a:
			out.append_array([iv[i], iv[i + 1]])
		elif iv[i] > b:
			if not placed:
				out.append_array([a, b])
				placed = true
			out.append_array([iv[i], iv[i + 1]])
		else:
			a = minf(a, iv[i])
			b = maxf(b, iv[i + 1])
		i += 2
	if not placed:
		out.append_array([a, b])
	locks[li] = out


## When loop li may drive again after a hold that began at t (t itself if it is not held then).
func restart_at(li: int, t: float) -> float:
	var iv: PackedFloat64Array = locks.get(li, PackedFloat64Array())
	var i := 0
	while i < iv.size():
		if t >= iv[i] and t <= iv[i + 1]:
			return iv[i + 1]
		i += 2
	return t


func _restart(e: Dictionary) -> float:
	return restart_at(int(e["loop"]), float(e["t"])) if e["hold"] else float(e["t"])


# --- Profiles --------------------------------------------------------------------------------------------

## A run of length D (> 0) from speed vs, accelerating at a up to vmax, then stopping at d: [peak, t_acc, t_cruise, t_dec].
static func _profile(vs: float, D: float, a: float, vmax: float, d: float) -> Array:
	vs = minf(vs, vmax)
	var d_acc := (vmax * vmax - vs * vs) / (2.0 * a)
	var d_dec := vmax * vmax / (2.0 * d)
	if d_acc + d_dec <= D:
		return [vmax, (vmax - vs) / a, (D - d_acc - d_dec) / vmax, vmax / d]
	var vp := sqrt(maxf((D + vs * vs / (2.0 * a)) / (1.0 / (2.0 * a) + 1.0 / (2.0 * d)), vs * vs))
	return [vp, maxf(vp - vs, 0.0) / a, 0.0, vp / d]


## [distance, speed] tau seconds into a run.
static func _run(vs: float, prof: Array, a: float, d: float, tau: float, D: float) -> Array:
	var vp: float = prof[0]
	var ta: float = prof[1]
	var tc: float = prof[2]
	var td: float = prof[3]
	if tau <= 0.0:
		return [0.0, vs]
	if tau <= ta:
		return [vs * tau + 0.5 * a * tau * tau, vs + a * tau]
	var x := vs * ta + 0.5 * a * ta * ta
	if tau <= ta + tc:
		return [x + vp * (tau - ta), vp]
	x += vp * tc
	var b := minf(tau - ta - tc, td)
	return [minf(x + vp * b - 0.5 * d * b * b, D), maxf(vp - d * b, 0.0)]


# --- Episodes ----------------------------------------------------------------------------------------------

## The shift of the timetable a loop follows from episode e on (its own and every earlier one's).
func shift_of(e: Dictionary) -> float:
	var R := _restart(e)
	var memo: Array = e.get("_shift", [])
	if not memo.is_empty() and float(memo[0]) == R:
		return float(memo[1])
	var li := int(e["loop"])
	var need := 0.0
	for vid: int in e["v"]:
		if wrecks.has(vid) and float(wrecks[vid]["since"]) <= R:
			continue
		var pl := _plan(e, vid, R, float(e["s_prev"]))
		var u_p := float(pl["p"])
		var t_p := float(pl["tp"])
		need = maxf(need, t_p - tr.last_arrival(vid, u_p, t_p, float(e["s_prev"])))
	var shift := float(e["s_prev"]) + ceilf(need / SHIFT_STEP - 1e-9) * SHIFT_STEP
	e["_shift"] = [R, shift]
	return shift


## Where vehicle vid stops in episode e (after braking / fleeing): X (distance from its anchor along the lap).
func _x_rest(a: Dictionary) -> float:
	return float(a["xs"])


## The restart plan of vehicle vid: {go, p, tp, x0, u0, z, xm, tarr} (times absolute, x relative to the anchor):
## from its rest spot (u0) it leaves at `go` (later than the restart only to finish a turn in a turn phase), drives at
## lane speeds to the stop line of turn zone z (xm), arriving at tarr. (p, tp): a lap distance it passes and when; the
## shifted timetable must pass p no earlier than tp.
func _plan(e: Dictionary, vid: int, R: float, _s_prev: float) -> Dictionary:
	var key := "_p%d" % vid
	var memo: Array = e.get(key, [])
	if not memo.is_empty() and float(memo[0]) == R:
		return memo[1]
	var li := int(e["loop"])
	var a: Dictionary = e["v"][vid]
	var length := float(tr.loops[li]["length"])
	var x0 := _x_rest(a)
	var u0 := fposmod(float(a["u"]) + x0, length)
	var go := R
	var p := u0
	var tp := R
	var from := u0
	var z_in := tr.zone_at(li, u0)
	if z_in >= 0:
		var zd: Dictionary = tr.loops[li]["zones"][z_in]
		var to_clear := fposmod(float(zd["clear"]) - u0, length)
		go = tr.lp.next_all_red(int(zd["j"]), R, tr.drive_time_over(li, u0, to_clear))
		p = float(zd["clear"])
		tp = go + tr.drive_time_over(li, u0, to_clear)
		from = p
	var ahead := tr.zone_ahead(li, from, z_in >= 0)
	var z: int = ahead[0]
	var to_stop := fposmod(from - u0, length) + float(ahead[1])
	var out := {"go": go, "p": p, "tp": tp, "x0": x0, "u0": u0, "z": z, "xm": x0 + to_stop,
			"tarr": go + tr.drive_time_over(li, u0, to_stop)}
	e[key] = [R, out]
	return out


## X of vehicle vid in episode e at time t, before keeping its distance (the free motion).
func _x_free(e: Dictionary, vid: int, t: float) -> float:
	var a: Dictionary = e["v"][vid]
	if t < float(a["te"]):
		return _x_motion(a, t, float(e["t"]))
	var R := _restart(e)
	if t < R:
		return _x_rest(a)
	var pl := _plan(e, vid, R, float(e["s_prev"]))
	var li := int(e["loop"])
	if t < float(pl["go"]):
		return float(pl["x0"])
	if t < float(pl["tarr"]):
		return float(pl["x0"]) + tr.drive_dist(li, float(pl["u0"]), t - float(pl["go"]))
	var shift := shift_of(e)
	var tm := tr.next_departure(vid, int(pl["z"]), float(pl["tarr"]), shift)
	if t < tm:
		return float(pl["xm"])
	return tr.unwrapped(vid, t, shift) - tr.unwrapped(vid, tm, shift) + float(pl["xm"])


## X during the stop / flee of an anchor (t < te).
func _x_motion(a: Dictionary, t: float, t_ep: float) -> float:
	var v := float(a["v"])
	var t0 := float(a["t0"])
	if t < t0:
		return v * (t - t_ep)
	var x0 := v * (t0 - t_ep)
	var flee := int(a["flee"])
	if flee == FWD and float(a["tf"]) <= t0 + 1e-9:
		var prof: Array = a["prof"]
		return x0 + float(_run(v, prof, FWD_ACC, FWD_DEC, t - t0, float(a["D"]))[0])
	var tb := v / DECEL
	var tc := minf(t - t0, tb)
	var x := x0 + v * tc - 0.5 * DECEL * tc * tc
	if flee != NONE and t >= float(a["tf"]):
		var prof: Array = a["prof"]
		var D := absf(float(a["D"]))
		var acc := FWD_ACC if flee == FWD else REV_ACC
		var dec := FWD_DEC if flee == FWD else REV_DEC
		var run := _run(0.0, prof, acc, dec, t - float(a["tf"]), D)
		x = x0 + v * tb - 0.5 * DECEL * tb * tb + (float(run[0]) if flee == FWD else -float(run[0]))
	return x


## X of vehicle vid in episode e at time t: its free motion, kept 6 m short of a wreck in its lane and of the vehicle
## ahead (waiting at the stop line instead if that spot is in a junction).
func _x(e: Dictionary, vid: int, t: float) -> float:
	var x := minf(_x_free(e, vid, t), float(e["lim"][vid]))
	var li := int(e["loop"])
	var length := float(tr.loops[li]["length"])
	var a: Dictionary = e["v"][vid]
	for other: int in e["v"]:
		if other == vid or (wrecks.has(other) and float(wrecks[other]["since"]) <= t):
			continue
		var d0 := fposmod(float(e["v"][other]["u"]) - float(a["u"]), length)
		if d0 < 1e-4:
			continue
		var xo := minf(_x_free(e, other, t), float(e["lim"][other]))
		var lim := xo + d0 - _gap(vid, other)
		if x > lim:
			x = maxf(minf(x, _junction_safe(li, float(a["u"]), lim)), minf(x, 0.0))
	return x


func _gap(vid: int, other_or_wreck: int) -> float:
	return GAP + float((LifeTraffic.SIZE[tr.vehicles[vid]["kind"]] as Vector3).z) * 0.5 \
			+ float((LifeTraffic.SIZE[tr.vehicles[other_or_wreck]["kind"]] as Vector3).z) * 0.5


## A stopping limit (X from anchor u_a) moved back to the stop line if it falls inside a turn.
func _junction_safe(li: int, u_a: float, lim: float) -> float:
	var length := float(tr.loops[li]["length"])
	var z := tr.zone_at(li, u_a + lim)
	if z < 0:
		return lim
	var back := fposmod(u_a + lim - float(tr.loops[li]["zones"][z]["stop"]), length)
	return lim - back if lim - back >= 0.0 else lim


# --- Poses -----------------------------------------------------------------------------------------------

## The vehicle's pose at time t: {x, s, heading, u, v, state, hazard, held, wreck, tilt, roll}.
## state: driving | stopped | dwell | docked | estop | fleeing | abandoned | wreck.
func pose(vid: int, t: float) -> Dictionary:
	if wrecks.has(vid) and t >= float(wrecks[vid]["since"]):
		return _wreck_pose(vid, t)
	var li := int(tr.vehicles[vid]["loop"])
	var e: Variant = episodes.get(li)
	while e != null and t < float((e as Dictionary)["t"]):
		e = (e as Dictionary).get("prev")
	if e == null or not (e as Dictionary)["v"].has(vid):
		return _base(vid, t, 0.0)
	var ep: Dictionary = e
	var a: Dictionary = ep["v"][vid]
	var x := _x(ep, vid, t)
	var v := (x - _x(ep, vid, t - 0.05)) / 0.05
	var length := float(tr.loops[li]["length"])
	var u := fposmod(float(a["u"]) + x, length)
	var pa := tr.point_at(li, u)
	var R := _restart(ep)
	var hot := bool(a["hot"])
	var state := "driving"
	var hazard := false
	if t < float(a["te"]):
		hazard = hot
		state = "estop" if hot else "stopped"
		if int(a["flee"]) != NONE and t >= float(a["tf"]):
			state = "fleeing"
	elif t < R:
		hazard = hot
		state = "abandoned" if hot else "stopped"
	else:
		var free := _x_free(ep, vid, t)
		var pl := _plan(ep, vid, R, float(ep["s_prev"]))
		if x < free - 1e-3 or absf(v) < 1e-3:
			state = "stopped"
		if t >= float(pl["tarr"]) and x >= free - 1e-3:
			var tm := tr.next_departure(vid, int(pl["z"]), float(pl["tarr"]), shift_of(ep))
			if t >= tm:
				state = str(tr.base_pose(vid, t - shift_of(ep))["mode"])
	return {"x": (pa[0] as Vector2).x, "s": (pa[0] as Vector2).y, "heading": pa[1], "u": u, "v": v, "state": state,
			"hazard": hazard, "held": t < R, "wreck": false, "tilt": 0.0, "roll": 1.0}


func state_of(vid: int, t: float) -> String:
	return str(pose(vid, t)["state"])


func _base(vid: int, t: float, shift: float) -> Dictionary:
	var b := tr.base_pose(vid, t - shift)
	b["state"] = b["mode"]
	b["hazard"] = false
	b["held"] = false
	b["wreck"] = false
	b["tilt"] = 0.0
	b["roll"] = 1.0
	return b


# --- Threats ---------------------------------------------------------------------------------------------

func apply_threat(ev: Dictionary, crowd: LifeCrowd) -> void:
	var T := float(ev.get("t", 0.0))
	var c := Vector2(float(ev.get("x", 0.0)), float(ev.get("s", 0.0)))
	var st := int(ev.get("st", 1))
	if _loop_box.size() != tr.loops.size():
		_loop_box.clear()
		for lo: Dictionary in tr.loops:
			var pts: PackedVector2Array = lo["pts"]
			var box := Rect2(pts[0] if pts.size() > 0 else Vector2.ZERO, Vector2.ZERO)
			for q in pts:
				box = box.expand(q)
			_loop_box.append(box.grow(LOOP_SLACK))
	for li in tr.loops.size():
		var hit := false
		if not brute_force:      # no vehicle of this loop can be within ESTOP_R: the loop below would find none
			var box: Rect2 = _loop_box[li]
			var q := Vector2(clampf(c.x, box.position.x, box.end.x), clampf(c.y, box.position.y, box.end.y))
			if q.distance_to(c) > ESTOP_R + 0.05:
				continue
		for vid in tr.loop_vehicles(li):
			var p := pose(vid, T)
			if not p["wreck"] and Vector2(p["x"], p["s"]).distance_to(c) <= ESTOP_R:
				hit = true
		if not hit:
			continue
		var held := T < restart_at(li, T)
		_lock(li, T, T + RESTART)
		if held:
			continue        # already held: the lock above holds it longer
		_episode(li, T, true, c, st, crowd)


## A new episode for loop li at T. `hold`: brake and wait for the loop's restart; `c` / `st`: the threat (vehicles within
## ESTOP_R of it e-stop or speed away); without a threat (c = Vector2.INF) nobody does.
func _episode(li: int, T: float, hold: bool, c: Vector2, st: int, crowd: LifeCrowd) -> void:
	var prev: Variant = episodes.get(li)
	var s_prev := shift_of(prev) if prev != null else 0.0
	var length := float(tr.loops[li]["length"])
	var e := {"loop": li, "t": T, "hold": hold, "s_prev": s_prev, "v": {}, "lim": {}}
	var ids: Array[int] = []
	var poses := {}
	for vid in tr.loop_vehicles(li):
		if wrecks.has(vid) and float(wrecks[vid]["since"]) <= T:
			continue
		ids.append(vid)
		poses[vid] = pose(vid, T)
	for vid in ids:
		var p: Dictionary = poses[vid]
		var keep_hot: bool = p["hazard"] and p["held"]
		var a := {"u": float(p["u"]), "v": maxf(float(p["v"]), 0.0) if hold else 0.0, "t0": T, "tep": T, "hot": keep_hot,
				"flee": NONE, "tf": INF, "D": 0.0, "doors": -1.0, "riders": 0, "rider0": -1}
		if hold:
			a["t0"] = T + 0.2 + 0.3 * tr.lp.h(vid + 70000, 9)
			if c != Vector2.INF and Vector2(p["x"], p["s"]).distance_to(c) <= ESTOP_R:
				a["hot"] = true
				# A pod that already let its passengers out runs empty from then on (unloads): nobody gets out twice.
				var n := tr.riders(vid, T) if p["state"] in ["driving", "stopped", "dwell"] and not p["held"] and not unloads.has(vid) else 0
				a["n"] = n
		e["v"][vid] = a
	# limits from wrecks lying in the lane
	for vid in ids:
		var a: Dictionary = e["v"][vid]
		var lim := INF
		for w: int in wrecks:
			if float(wrecks[w]["since"]) > T:
				continue
			var rest := _wreck_rest(w)
			var uw := tr.lane_u(li, Vector2(rest["x"], rest["s"]), IN_LANE)
			if uw < 0.0:
				continue
			var l := fposmod(uw - _gap(vid, w) - float(a["u"]), length)
			if l > length - _gap(vid, w) * 2.0:
				continue          # it lies right on or just behind us
			lim = minf(lim, _junction_safe(li, float(a["u"]), l))
		e["lim"][vid] = maxf(lim, 0.0)
	# riders and fleeing
	for vid in ids:
		var a: Dictionary = e["v"][vid]
		if hold and a["hot"] and a.has("n"):
			_plan_flee(e, vid, c, st, crowd, poses)
		_finish(a)
	if prev != null:
		(prev as Dictionary).erase("prev")
		e["prev"] = prev
	episodes[li] = e


## Riders out, and whether (and how far) a hot pod speeds away.
func _plan_flee(e: Dictionary, vid: int, c: Vector2, st: int, crowd: LifeCrowd, poses: Dictionary) -> void:
	var li := int(e["loop"])
	var length := float(tr.loops[li]["length"])
	var a: Dictionary = e["v"][vid]
	var p: Dictionary = poses[vid]
	var v := float(a["v"])
	var t0 := float(a["t0"])
	var x_t0 := v * (t0 - float(e["t"]))
	var n := int(a["n"])
	var tb := v / DECEL
	var x_stop := x_t0 + v * tb - 0.5 * DECEL * tb * tb
	if n > 0:
		a["doors"] = t0 + tb + DOORS
		var pa := tr.point_at(li, float(a["u"]) + x_stop)
		var pp: Vector2 = pa[0]
		var d := Vector2(sin(float(pa[1])), cos(float(pa[1])))
		var right := Vector2(-d.y, d.x)
		for k in n:
			var rid := crowd.spawn_rider(float(a["doors"]) + 0.4 * float(k), pp + right * 1.5 + d * (0.8 * float(k) - 0.4), c, st)
			if rid >= 0:
				if int(a["riders"]) == 0:
					a["rider0"] = rid
				a["riders"] = int(a["riders"]) + 1
		unloads[vid] = {"doors": float(a["doors"]), "n": n, "riders": int(a["riders"]), "rider0": int(a["rider0"])}
	if tr.vehicles[vid]["kind"] != "pod":
		return
	var fwd := Vector2(sin(float(p["heading"])), cos(float(p["heading"])))
	var at := Vector2(p["x"], p["s"])
	var ahead := (c - at).dot(fwd) > 0.0
	var flee := REV if ahead else FWD
	var start_x := x_stop
	var tf := t0 + tb
	if n > 0:
		tf = float(a["doors"]) + 0.4 * float(n - 1) + RIDER_GO
	elif flee == FWD:
		start_x = x_t0
		tf = t0                  # no need to stop first: it just goes
	var u_start := float(a["u"]) + start_x
	if tr.zone_at(li, u_start) >= 0:
		return
	var room := INF
	if flee == FWD:
		room = float(tr.zone_ahead(li, u_start)[1])
		room = minf(room, tr.dist_until_away(li, u_start, 1.0, c, FLEE_AWAY, 200.0))
		room = minf(room, float(e["lim"][vid]) - start_x)
		for other: int in e["v"]:
			if other != vid:
				var o: Dictionary = e["v"][other]
				var ob := float(o["v"]) * float(o["v"]) / (2.0 * DECEL) + float(o["v"]) * 0.5
				room = minf(room, fposmod(float(o["u"]) - float(a["u"]), length) + ob - start_x - _gap(vid, other))
	else:
		room = float(tr.zone_behind(li, u_start)[1])
		room = minf(room, tr.dist_until_away(li, u_start, -1.0, c, FLEE_AWAY, 200.0))
		for other: int in e["v"]:
			if other != vid:
				var o: Dictionary = e["v"][other]
				var ob := float(o["v"]) * float(o["v"]) / (2.0 * DECEL) + float(o["v"]) * 0.5
				room = minf(room, fposmod(float(a["u"]) + start_x - float(o["u"]), length) - ob - _gap(vid, other))
		for w: int in wrecks:
			var rest := _wreck_rest(w)
			var uw := tr.lane_u(li, Vector2(rest["x"], rest["s"]), IN_LANE)
			if uw >= 0.0:
				room = minf(room, fposmod(u_start - uw, length) - _gap(vid, w))
	if is_inf(room) or room < FLEE_MIN:
		return
	var vs := v if (flee == FWD and n == 0) else 0.0
	if flee == FWD and vs * vs / (2.0 * FWD_DEC) > room:
		return
	a["flee"] = flee
	a["tf"] = tf
	a["D"] = room if flee == FWD else -room


## Motion end time and rest spot of an anchor.
func _finish(a: Dictionary) -> void:
	var v := float(a["v"])
	var t0 := float(a["t0"])
	var tb := v / DECEL
	match int(a["flee"]):
		FWD:
			var vs := v if float(a["tf"]) <= t0 + 1e-9 else 0.0
			var prof := _profile(vs, float(a["D"]), FWD_ACC, FWD_V, FWD_DEC)
			a["prof"] = prof
			var dur := float(prof[1]) + float(prof[2]) + float(prof[3])
			a["te"] = float(a["tf"]) + dur
			a["xs"] = (v * (t0 - float(a["tep"])) if vs > 0.0 else _x_stop(a)) + float(a["D"])
		REV:
			var prof := _profile(0.0, -float(a["D"]), REV_ACC, REV_V, REV_DEC)
			a["prof"] = prof
			a["te"] = float(a["tf"]) + float(prof[1]) + float(prof[2]) + float(prof[3])
			a["xs"] = _x_stop(a) + float(a["D"])
		_:
			a["te"] = t0 + tb
			a["xs"] = _x_stop(a)


func _x_stop(a: Dictionary) -> float:
	var v := float(a["v"])
	var tb := v / DECEL
	return v * (float(a["t0"]) - float(a["tep"])) + v * tb - 0.5 * DECEL * tb * tb


# --- Wrecks ----------------------------------------------------------------------------------------------

## The event a hit makes (host side): wrecked where it is now (or shoved again if it already is a wreck).
## `how` 0: a shot (no tip, a nudge along it), 1: a blast (tipped onto its side, pushed away), 2: a push (shoved; tipped
## when faster than 8 m/s).
func wreck_event(vid: int, t: float, dir: Vector2, src: int, how: int, v0: float) -> Dictionary:
	var p := pose(vid, t)
	var kind := str(tr.vehicles[vid]["kind"])
	var d := dir.normalized() if dir.length_squared() > 1e-8 else Vector2(0.0, 1.0)
	var yaw := float(p["heading"])
	var tilt0 := float(p["tilt"])
	var tilt1 := tilt0
	var roll := float(p["roll"])
	if how == 1 or (how == 2 and v0 > 8.0):
		tilt1 = PI * 0.5
		var right := Vector2(cos(yaw), -sin(yaw))      # the vehicle's local +X in (x, s)
		roll = 1.0 if right.dot(d) >= 0.0 else -1.0
	var speed := minf(maxf(v0, 0.0), SHOVE_CAP) * minf(CityPropSim.SHOVE_MASS * 2.0 / float(MASS[kind]), 1.0)
	var want := speed * speed / (2.0 * CityPropSim.FRICTION)
	var length := CityPropSim.slide_length(tr.plan, Vector2(p["x"], p["s"]), d, want, 1.2)
	return {"id": vid, "t": t, "x": float(p["x"]), "s": float(p["s"]), "yaw": yaw, "tilt0": tilt0, "tilt1": tilt1, "roll": roll,
			"dir": d, "v0": speed, "len": length, "src": src}


## Apply a wreck event. Passengers still inside a pod are killed (counted, no figures). Returns how many.
func wreck(ev: Dictionary, crowd: LifeCrowd) -> int:
	var vid := int(ev.get("id", -1))
	if vid < 0 or vid >= tr.count():
		return 0
	var t := float(ev.get("t", 0.0))
	var first := not wrecks.has(vid)
	var killed := 0
	var before := {}
	if first:
		var p := pose(vid, t)
		if str(p["state"]) != "docked":
			killed = _aboard(vid, t, crowd)
		crowd.add_occupant_kills(killed, int(ev.get("src", 0)))
	else:
		before = _wreck_rest(vid)
	var e := ev.duplicate()
	e["t0"] = t
	e["since"] = float(wrecks[vid]["since"]) if not first else t
	if not first:
		var old: Dictionary = wrecks[vid]
		old.erase("prev")
		e["prev"] = old              # (the pose before this shove, for queries of the past)
	wrecks[vid] = e
	# The loops it touches: its own (first time), and every loop whose lane it lay in or lies in now.
	var after := _wreck_rest(vid)
	var own := int(tr.vehicles[vid]["loop"])
	for li in tr.loops.size():
		var touched := first and li == own
		if tr.lane_u(li, Vector2(after["x"], after["s"]), IN_LANE) >= 0.0:
			touched = true
		if not before.is_empty() and tr.lane_u(li, Vector2(before["x"], before["s"]), IN_LANE) >= 0.0:
			touched = true
		if not touched:
			continue
		if first and li == own:
			_lock(li, t, t + RESTART)
		_episode(li, t, t < restart_at(li, t), Vector2.INF, 0, crowd)
	return killed


## How many passengers are still inside pod vid when it is wrecked at t (0 for a cart). A pod that never unloaded holds
## its timetable's riders. One that did (unloads): rider k steps out at doors + 0.4 k, so those whose moment has come are
## out and live on; the rest of its rider slots never get out (their alarm records are dropped on every machine, so no
## one steps out of the wreck later), and they die inside with those who got no slot. (Before 2026-11-25 every rider
## with a slot counted as out once the doors opened, though the later ones were still aboard and then stepped out of the
## wreck; a later threat on the same lap let the timetable's riders out again; a pod held by another stop counted 0.)
func _aboard(vid: int, t: float, crowd: LifeCrowd) -> int:
	if not unloads.has(vid):
		return tr.riders(vid, t)
	var u: Dictionary = unloads[vid]
	var out := 0
	for k in int(u["riders"]):
		if t >= float(u["doors"]) + 0.4 * float(k):
			out += 1
		else:
			crowd.recs.erase(int(u["rider0"]) + k)      # still aboard: never gets out
	return maxi(int(u["n"]) - out, 0)


## The clock source changed (AmbientLife._rebase): every pod that unloaded did so on the old clock, long ago.
func rebase_unloads() -> void:
	for vid: int in unloads:
		(unloads[vid] as Dictionary)["doors"] = -INF


## After a clock change (no episodes left): every loop a wreck lies on gets an episode that keeps its vehicles short of it.
func rebuild_obstacles(t: float, crowd: LifeCrowd) -> void:
	for li in tr.loops.size():
		var touched := false
		for w: int in wrecks:
			var rest := _wreck_rest(w)
			if int(tr.vehicles[w]["loop"]) == li or tr.lane_u(li, Vector2(rest["x"], rest["s"]), IN_LANE) >= 0.0:
				touched = true
		if touched:
			_episode(li, t, false, Vector2.INF, 0, crowd)


## The anchor of vid in the episode that covers time t, or {}.
func _anchor_at(vid: int, t: float) -> Dictionary:
	var e: Variant = episodes.get(int(tr.vehicles[vid]["loop"]))
	while e != null and t < float((e as Dictionary)["t"]):
		e = (e as Dictionary).get("prev")
	if e == null or not (e as Dictionary)["v"].has(vid):
		return {}
	return (e as Dictionary)["v"][vid]


func _wreck_rest(vid: int) -> Dictionary:
	var e: Dictionary = wrecks[vid]
	return _wreck_pose(vid, float(e["t0"]) + 30.0)


func _wreck_pose(vid: int, t: float) -> Dictionary:
	var e: Dictionary = wrecks[vid]
	while t < float(e["t0"]) and e.has("prev"):
		e = e["prev"]
	var a := t - float(e["t0"])
	var slide := {"kind": CityPropSim.SHOVE, "dir": e["dir"], "v0": float(e["v0"]), "len": float(e["len"]),
			"from": {"x": float(e["x"]), "s": float(e["s"]), "lie": float(e["yaw"]), "tilt": 0.0, "spin": 0.0}}
	var q := CityPropSim.pose_at(slide, {"type": "vehicle"}, a)
	var f := clampf(a / TIP_S, 0.0, 1.0)
	var tilt := lerpf(float(e["tilt0"]), float(e["tilt1"]), f * f)
	return {"x": float(q["x"]), "s": float(q["s"]), "heading": float(e["yaw"]) + float(q["spin"]), "u": 0.0, "v": 0.0,
			"state": "wreck", "hazard": true, "held": true, "wreck": true, "tilt": tilt, "roll": float(e["roll"]),
			"src": int(e["src"])}


# --- Snapshot --------------------------------------------------------------------------------------------

const ANCHOR_KEYS := ["u", "v", "t0", "tf", "D", "doors"]


func snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(SNAP_VERSION)
	var lis := locks.keys()
	lis.sort()
	buf.put_u16(lis.size())
	for li: int in lis:
		var iv: PackedFloat64Array = locks[li]
		buf.put_u16(li)
		buf.put_u16(iv.size())
		for x in iv:
			buf.put_double(x)
	var eps := episodes.keys()
	eps.sort()
	buf.put_u16(eps.size())
	for li: int in eps:
		var e: Dictionary = episodes[li]
		buf.put_u16(li)
		buf.put_double(float(e["t"]))
		buf.put_u8(1 if e["hold"] else 0)
		buf.put_double(float(e["s_prev"]))
		var ids: Array = (e["v"] as Dictionary).keys()
		ids.sort()
		buf.put_u16(ids.size())
		for vid: int in ids:
			var a: Dictionary = e["v"][vid]
			buf.put_u16(vid)
			buf.put_u8(int(a["flee"]))
			buf.put_u8(1 if a["hot"] else 0)
			buf.put_u8(int(a["riders"]))
			buf.put_u8(int(a.get("n", 0)))
			buf.put_32(int(a["rider0"]))
			for k: String in ANCHOR_KEYS:
				buf.put_double(float(a[k]))
			buf.put_double(float(e["lim"][vid]))
	var ws := wrecks.keys()
	ws.sort()
	buf.put_u16(ws.size())
	for vid: int in ws:
		var e: Dictionary = wrecks[vid]
		buf.put_u16(vid)
		buf.put_32(int(e["src"]))
		for k: String in ["t0", "since", "x", "s", "yaw", "tilt0", "tilt1", "roll", "v0", "len"]:
			buf.put_double(float(e[k]))
		buf.put_double((e["dir"] as Vector2).x)
		buf.put_double((e["dir"] as Vector2).y)
	var us := unloads.keys()
	us.sort()
	buf.put_u16(us.size())
	for vid: int in us:
		var u: Dictionary = unloads[vid]
		buf.put_u16(vid)
		buf.put_double(float(u["doors"]))
		buf.put_u8(int(u["n"]))
		buf.put_u8(int(u["riders"]))
		buf.put_32(int(u["rider0"]))
	return buf.data_array


## Bytes of one record in snapshot(): an episode's head, one of its anchors, a wreck, an unload.
const SNAP_EP := 2 + 8 + 1 + 8 + 2
const SNAP_ANCHOR := 2 + 4 + 4 + 6 * 8 + 8
const SNAP_WRECK := 2 + 4 + 12 * 8
const SNAP_UNLOAD := 2 + 8 + 1 + 1 + 4


## Replace the whole state with a snapshot (an empty one clears it). The bytes come from a peer (life.sync): every count
## is checked against the bytes left before its records are read and the buffer must end where the last record does (a
## truncated or padded buffer is rejected as a whole: a warning and the cleared state); a record naming a loop or vehicle
## this traffic plan does not have is skipped.
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
		push_warning("LifeFleet.restore: malformed snapshot (%d bytes): ignored" % bytes.size())


func _restore_from(buf: StreamPeerBuffer) -> bool:
	if buf.get_available_bytes() < 2:
		return false
	for i in buf.get_u16():
		if buf.get_available_bytes() < 4:
			return false
		var li := buf.get_u16()
		var m := buf.get_u16()
		if buf.get_available_bytes() < m * 8:
			return false
		var iv := PackedFloat64Array()
		for k in m:
			iv.append(buf.get_double())
		if li < tr.loops.size() and m % 2 == 0:
			locks[li] = iv
	if buf.get_available_bytes() < 2:
		return false
	for i in buf.get_u16():
		if buf.get_available_bytes() < SNAP_EP:
			return false
		var li := buf.get_u16()
		var e := {"loop": li, "t": buf.get_double(), "hold": buf.get_u8() == 1, "s_prev": buf.get_double(), "v": {}, "lim": {}}
		var m := buf.get_u16()
		if buf.get_available_bytes() < m * SNAP_ANCHOR:
			return false
		var ok := li < tr.loops.size()
		for k in m:
			var vid := buf.get_u16()
			var a := {"flee": buf.get_u8(), "hot": buf.get_u8() == 1, "riders": buf.get_u8()}
			var n := buf.get_u8()
			if n > 0:
				a["n"] = n
			a["rider0"] = buf.get_32()
			for key: String in ANCHOR_KEYS:
				a[key] = buf.get_double()
			a["tep"] = float(e["t"])
			var lim := buf.get_double()
			if not ok or vid >= tr.count() or int(a["flee"]) not in [NONE, FWD, REV]:
				ok = false
				continue
			e["v"][vid] = a
			e["lim"][vid] = lim
			_finish(a)
		if ok:
			episodes[li] = e
	if buf.get_available_bytes() < 2:
		return false
	var nw := buf.get_u16()
	if buf.get_available_bytes() < nw * SNAP_WRECK:
		return false
	for i in nw:
		var vid := buf.get_u16()
		var e := {"id": vid, "src": buf.get_32()}
		for k: String in ["t0", "since", "x", "s", "yaw", "tilt0", "tilt1", "roll", "v0", "len"]:
			e[k] = buf.get_double()
		e["t"] = e["t0"]
		e["dir"] = Vector2(buf.get_double(), buf.get_double())
		if vid < tr.count():
			wrecks[vid] = e
	if buf.get_available_bytes() < 2:
		return false
	var nu := buf.get_u16()
	if buf.get_available_bytes() != nu * SNAP_UNLOAD:
		return false
	for i in nu:
		var vid := buf.get_u16()
		var u := {"doors": buf.get_double(), "n": buf.get_u8(), "riders": buf.get_u8(), "rider0": buf.get_32()}
		if vid < tr.count():
			unloads[vid] = u
	return true
