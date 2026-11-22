class_name LifeTram
extends RefCounted
## The tram of one section deck (docs/design/ambient-life.md sections 2, 5 and 13; phase 3). Three cars on the -x track of
## the spine's rail lane (a quarter of the lane in from its centre: the lane has two tracks), shuttling between the deck's two end walls: 14 m/s, 1.2 m/s^2 up and down, 20 s at every
## `station` hook's s (the middle car's centre stops there), 10 s at an end wall before it reverses. Where the end wall's
## spine gate is a `portal` the tram runs on through it, out of the map, and comes back 40 s later (its centre is beyond
## the wall for 40 s: it turns round PORTAL_RUN m past the wall, out of sight).
##
## Closed form on the shared clock: base(b) is a pure function of the plan, the seed and the base clock b. A firefight
## (a threat within 60 m of any car) halts it: it brakes at 2.5 m/s^2 to a stop, doors shut, hazards on, held until 15 s
## after the last threat in range; then it drives from where it stands to the stop it was heading for, dwells there and
## rejoins its timetable at that departure, shifted by however late it is (episodes, built from the host's threat
## events in time order, so the same on every machine). It cannot be wrecked, tipped or pushed (25 t) and shots, blasts
## and sweeps ignore it; its cars are the only ambient-life agents with collision (AmbientLife / LifeTramCars).

const CARS := 3
const CAR_W := 3.0
const CAR_L := 9.0
const CAR_H := 3.2
const CAR_GAP := 0.6
const PITCH := CAR_L + CAR_GAP          ## m, car centre to car centre
const HALF := PITCH + CAR_L * 0.5       ## m, the middle car's centre to either end of the train
const V := 14.0
const ACC := 1.2
const BRAKE := 2.5
const DWELL := 20.0
const TURN := 10.0                      ## s at an end wall before reversing
const AWAY := 40.0                      ## s with its centre beyond a portal
const PORTAL_RUN := 100.0               ## m past a portal wall where it turns round
const WALL_CLEAR := 3.0                 ## m between the train's end and an end wall when it reverses there
const HALT_R := 60.0                    ## m: a threat this close to any car halts it
const RESTART := 15.0                   ## s after the last threat in range
const REACT := 0.3                      ## s from the threat to the brakes
const STATION_MERGE := 30.0             ## m: stations closer than this are one stop
const MASS := 25000.0                   ## kg (nothing in the game can shove it)
const RUN := 0
const STOP := 1
const SNAP_VERSION := 1

var plan: CityPlan
var x := 0.0                 ## the track it runs on (the rail lane's -x track)
var wall_lo := 0.0           ## the deck's end walls (s)
var wall_hi := 0.0
var portal_lo := false       ## the end wall's spine gate is a portal: the tram leaves the map there
var portal_hi := false
var phase := 0.0             ## s, where in its period the tram is at base clock 0 (per deck, from the seed)
var period := 0.0
var stops: Array = []        ## one period's stops in order: [{s, dwell, kind: end | station | away}], stop 0 = the low end
var segs: Array = []         ## [{kind RUN | STOP, t0, t1, s0, s1, stop, prof [ta, tc, vp, dur], d}] covering [0, period)
var episodes: Array = []     ## the halts, in time order (state: decided by the host's threat events)
var _starts := PackedFloat64Array()


func net_fields() -> Dictionary:
	return {
		"plan": Net.SPAWN, "phase": Net.SPAWN,            # from the mission seed
		"episodes": Net.OWNER,                            # the host's threat events decide them on every machine
		# derived from the plan on every machine (checksum())
		"x": Net.LOCAL, "wall_lo": Net.LOCAL, "wall_hi": Net.LOCAL, "portal_lo": Net.LOCAL, "portal_hi": Net.LOCAL,
		"period": Net.LOCAL, "stops": Net.LOCAL, "segs": Net.LOCAL, "_starts": Net.LOCAL,
	}


## The tram of a section deck's plan, or null for a district on its own. `rnd` in [0, 1): its phase in the period.
static func make(p: CityPlan, rnd: float) -> LifeTram:
	if p == null or p.section == null:
		return null
	var t := LifeTram.new()
	t.build(p, rnd)
	return t


func build(p: CityPlan, rnd: float) -> void:
	plan = p
	var sec := p.section
	var rail := sec.lane_x("rail")
	x = (rail.x + rail.y) * 0.5 - (rail.y - rail.x) * 0.25      # on the lane's -x track (CityStreets draws two)
	wall_lo = p.extent.position.y
	wall_hi = p.extent.end.y
	for w: Dictionary in p.boundary():
		var side := int(w["side"])
		if side < 2:
			continue
		for g: Dictionary in w["gates"]:
			if str(g["kind"]) == "portal" and float(g["a"]) <= x and float(g["b"]) >= x:
				if side == 2:
					portal_hi = true
				else:
					portal_lo = true
	var lo := wall_lo + HALF + WALL_CLEAR
	var hi := wall_hi - HALF - WALL_CLEAR
	var st: Array[float] = []
	for hk: Dictionary in sec.hooks:
		if hk["kind"] == "station" and int(hk["deck"]) == p.deck:
			st.append(clampf(float(hk["s"]), lo, hi))
	st.sort()
	var merged: Array[float] = []
	for s in st:
		if merged.is_empty() or s - merged[-1] >= STATION_MERGE:
			merged.append(s)
	# The two ends: an end stop (or the station itself when one stands right there), or the turn-round beyond a portal.
	var lo_stop := {"s": lo, "dwell": TURN, "kind": "end"}
	var hi_stop := {"s": hi, "dwell": TURN, "kind": "end"}
	if portal_lo:
		lo_stop = {"s": wall_lo - PORTAL_RUN, "dwell": 0.0, "kind": "away"}
	if portal_hi:
		hi_stop = {"s": wall_hi + PORTAL_RUN, "dwell": 0.0, "kind": "away"}
	var mid: Array = []
	for s in merged:
		if not portal_lo and s - lo < 5.0:
			lo_stop = {"s": s, "dwell": DWELL, "kind": "station"}
		elif not portal_hi and hi - s < 5.0:
			hi_stop = {"s": s, "dwell": DWELL, "kind": "station"}
		else:
			mid.append({"s": s, "dwell": DWELL, "kind": "station"})
	stops = [lo_stop]
	stops.append_array(mid)
	stops.append(hi_stop)
	for i in range(mid.size() - 1, -1, -1):
		stops.append(mid[i])
	# One period: from the departure at stop 0, RUN to each next stop and STOP there, ending with the stop at stop 0.
	var n := stops.size()
	var runs: Array = []
	for i in n:
		var a: Dictionary = stops[i]
		var b: Dictionary = stops[(i + 1) % n]
		var d := absf(float(b["s"]) - float(a["s"]))
		runs.append({"s0": float(a["s"]), "s1": float(b["s"]), "d": d, "prof": profile(d), "to": (i + 1) % n})
	# A portal's turn-round dwell: the centre is beyond the wall for AWAY s in all.
	for i in n:
		var sp: Dictionary = stops[i]
		if sp["kind"] != "away":
			continue
		var wall := wall_hi if float(sp["s"]) > 0.0 else wall_lo
		var r_in: Dictionary = runs[(i - 1 + n) % n]
		var r_out: Dictionary = runs[i]
		var dt_in := float(r_in["prof"][3]) - time_at(r_in["prof"], float(r_in["d"]), absf(wall - float(r_in["s0"])))
		var dt_out := time_at(r_out["prof"], float(r_out["d"]), absf(wall - float(r_out["s0"])))
		sp["dwell"] = maxf(AWAY - dt_in - dt_out, 0.0)
	segs.clear()
	var t := 0.0
	for i in n:
		var r: Dictionary = runs[i]
		var dur := float(r["prof"][3])
		segs.append({"kind": RUN, "t0": t, "t1": t + dur, "s0": r["s0"], "s1": r["s1"], "stop": r["to"], "prof": r["prof"], "d": r["d"]})
		t += dur
		var sp: Dictionary = stops[int(r["to"])]
		segs.append({"kind": STOP, "t0": t, "t1": t + float(sp["dwell"]), "s0": sp["s"], "s1": sp["s"], "stop": r["to"],
				"prof": [0.0, 0.0, 0.0, 0.0], "d": 0.0})
		t += float(sp["dwell"])
	period = t
	phase = floorf(rnd * period)
	_starts = PackedFloat64Array()
	for sg: Dictionary in segs:
		_starts.append(float(sg["t0"]))
	episodes.clear()


# --- Profiles (from rest to rest over d metres) --------------------------------------------------------------

## [accel time, cruise time, peak speed, duration] of a run of d metres.
static func profile(d: float) -> Array:
	if d <= 1e-6:
		return [0.0, 0.0, 0.0, 0.0]
	if d >= V * V / ACC:
		var ta := V / ACC
		var tc := (d - V * V / ACC) / V
		return [ta, tc, V, 2.0 * ta + tc]
	var vp := sqrt(ACC * d)
	return [vp / ACC, 0.0, vp, 2.0 * vp / ACC]


static func dist_at(prof: Array, d: float, dt: float) -> float:
	var ta := float(prof[0])
	var tc := float(prof[1])
	var vp := float(prof[2])
	if dt <= 0.0:
		return 0.0
	if dt >= float(prof[3]):
		return d
	if dt < ta:
		return 0.5 * ACC * dt * dt
	if dt < ta + tc:
		return 0.5 * ACC * ta * ta + vp * (dt - ta)
	var rest := float(prof[3]) - dt
	return d - 0.5 * ACC * rest * rest


static func speed_at(prof: Array, dt: float) -> float:
	var ta := float(prof[0])
	var tc := float(prof[1])
	if dt <= 0.0 or dt >= float(prof[3]):
		return 0.0
	if dt < ta:
		return ACC * dt
	if dt < ta + tc:
		return float(prof[2])
	return ACC * (float(prof[3]) - dt)


## When a run reaches `dist` metres (the inverse of dist_at).
static func time_at(prof: Array, d: float, dist: float) -> float:
	var ta := float(prof[0])
	var vp := float(prof[2])
	var ramp := 0.5 * ACC * ta * ta
	dist = clampf(dist, 0.0, d)
	if dist <= ramp:
		return sqrt(2.0 * dist / ACC)
	if dist <= d - ramp:
		return ta + (dist - ramp) / maxf(vp, 1e-6)
	return float(prof[3]) - sqrt(2.0 * (d - dist) / ACC)


# --- The timetable -------------------------------------------------------------------------------------------

## The timetable at base clock b: {s, v (signed, along +s), mode (running | dwell | away), seg, n (period index)}.
func base(b: float) -> Dictionary:
	var w := b + phase
	var n := floorf(w / period)
	var u := w - n * period
	var i := clampi(_starts.bsearch(u, false) - 1, 0, segs.size() - 1)
	var sg: Dictionary = segs[i]
	var s := float(sg["s0"])
	var v := 0.0
	var mode := "dwell"
	if int(sg["kind"]) == RUN:
		var dir := signf(float(sg["s1"]) - float(sg["s0"]))
		var dt := u - float(sg["t0"])
		s += dir * dist_at(sg["prof"], float(sg["d"]), dt)
		v = dir * speed_at(sg["prof"], dt)
		mode = "running"
	if s < wall_lo or s > wall_hi:
		mode = "away"
	return {"s": s, "v": v, "mode": mode, "seg": i, "n": n}


## Where the timetable (shifted by `shift`) is heading at time t, or dwelling: {ps, pdwell, dep_sched (absolute time it
## leaves that stop), dep_base (the same departure on the base clock)}.
func _base_dest(t: float, shift: float) -> Dictionary:
	var b := base(t - shift)
	var k := int(b["seg"])
	if int(segs[k]["kind"]) == RUN:
		k += 1
	var sg: Dictionary = segs[k]
	var dep_base := float(b["n"]) * period + float(sg["t1"]) - phase
	return {"ps": float(sg["s0"]), "pdwell": float(sg["t1"]) - float(sg["t0"]), "dep_sched": dep_base + shift, "dep_base": dep_base}


## The tram's pose at time t, halts included: {s, v, mode (running | dwell | halted | away), hazard}.
func pose(t: float) -> Dictionary:
	var e := _episode_at(t)
	if e.is_empty():
		return _shifted(t, 0.0)
	return _ep_pose(e, t)


func state_of(t: float) -> String:
	return str(pose(t)["mode"])


func _episode_at(t: float) -> Dictionary:
	for i in range(episodes.size() - 1, -1, -1):
		if float(episodes[i]["t0"]) <= t:
			return episodes[i]
	return {}


func _shifted(t: float, shift: float) -> Dictionary:
	var b := base(t - shift)
	return {"s": b["s"], "v": b["v"], "mode": b["mode"], "hazard": false}


func _ep_pose(e: Dictionary, t: float) -> Dictionary:
	var t0 := float(e["t0"])
	if t < float(e["t1"]):
		var v0 := float(e["v0"])
		var sg := signf(v0)
		var dt := t - t0
		return {"s": float(e["s0"]) + v0 * dt - sg * 0.5 * BRAKE * dt * dt, "v": v0 - sg * BRAKE * dt, "mode": "halted", "hazard": true}
	if t < float(e["tr"]):
		return {"s": e["s1"], "v": 0.0, "mode": "halted", "hazard": true}
	if t < float(e["ta"]):
		var dir := signf(float(e["ps"]) - float(e["s1"]))
		var dt := t - float(e["tr"])
		var s := float(e["s1"]) + dir * dist_at(e["prof"], float(e["d"]), dt)
		return {"s": s, "v": dir * speed_at(e["prof"], dt), "mode": "away" if s < wall_lo or s > wall_hi else "running", "hazard": false}
	if t < float(e["dep"]):
		var s := float(e["ps"])
		return {"s": s, "v": 0.0, "mode": "away" if s < wall_lo or s > wall_hi else "dwell", "hazard": false}
	return _shifted(t, float(e["shift"]))


## Where the current model (episodes so far) is heading at time t (see _base_dest).
func _dest(t: float) -> Dictionary:
	var e := _episode_at(t)
	if e.is_empty():
		return _base_dest(t, 0.0)
	if t >= float(e["dep"]):
		return _base_dest(t, float(e["shift"]))
	return {"ps": e["ps"], "pdwell": e["pdwell"], "dep_sched": e["dep"], "dep_base": e["dep_base"]}


## The train's ends at its pose: Vector2(s of the low end, s of the high end).
static func extent_of(s: float) -> Vector2:
	return Vector2(s - HALF, s + HALF)


## The centre s of car i (0..2) when the middle car's centre is at s.
static func car_s(s: float, i: int) -> float:
	return s + float(i - 1) * PITCH


## Whether car i (at centre cs) is drawn: not wholly beyond an end wall.
func car_inside(cs: float) -> bool:
	return cs + CAR_L * 0.5 > wall_lo and cs - CAR_L * 0.5 < wall_hi


## Distance from arc point c to the nearest car of a train whose middle car is at s.
func dist_to(c: Vector2, s: float) -> float:
	var q := Vector2(x, clampf(c.y, s - HALF, s + HALF))
	return q.distance_to(c)


# --- Threats -----------------------------------------------------------------------------------------------

## Apply one decided threat {x, s, r, st, t}: halts the tram if any car is within HALT_R m. Threats arrive in time order.
func apply_threat(ev: Dictionary) -> void:
	var T := float(ev.get("t", 0.0))
	var c := Vector2(float(ev.get("x", 0.0)), float(ev.get("s", 0.0)))
	var p := pose(T)
	if p["mode"] == "away" or dist_to(c, float(p["s"])) > HALT_R:
		return
	if not episodes.is_empty():
		var last: Dictionary = episodes[-1]
		if T < float(last["tr"]):
			last["tr"] = maxf(float(last["tr"]), T + RESTART)
			_finish(last)
			return
	var t0 := T + REACT
	var q := pose(t0)
	if q["mode"] == "away":
		return
	var v0 := float(q["v"])
	var e := {"t0": t0, "s0": float(q["s"]), "v0": v0, "t1": t0 + absf(v0) / BRAKE,
			"s1": float(q["s"]) + signf(v0) * v0 * v0 / (2.0 * BRAKE)}
	e["tr"] = maxf(T + RESTART, float(e["t1"]))
	var d := _dest(t0)
	for k: String in d:
		e[k] = d[k]
	_finish(e)
	episodes.append(e)


## The restart after a halt: from rest at s1 at tr to the stop it was heading for, its dwell there, then the timetable
## from that departure (shifted).
func _finish(e: Dictionary) -> void:
	var d := absf(float(e["ps"]) - float(e["s1"]))
	if d < 0.05:
		e["d"] = 0.0
		e["prof"] = [0.0, 0.0, 0.0, 0.0]
		e["ta"] = float(e["tr"])
		e["dep"] = maxf(float(e["tr"]), float(e["dep_sched"]))
	else:
		e["d"] = d
		e["prof"] = profile(d)
		e["ta"] = float(e["tr"]) + float(e["prof"][3])
		e["dep"] = maxf(float(e["ta"]) + float(e["pdwell"]), float(e["dep_sched"]))
	e["shift"] = float(e["dep"]) - float(e["dep_base"])


## The time the tram restarts (or last restarted) after a halt at or before t, or -INF.
func restart_time(t: float) -> float:
	var e := _episode_at(t)
	return -INF if e.is_empty() else float(e["tr"])


# --- For people crossing the rail lane (pure: the timetable only) ---------------------------------------------

## The earliest time >= t from which the timetable keeps every car more than `gap` m (along the rail) from the cross
## line s_line for `dur` seconds. Sampled every 0.5 s with 7 m of slack (the most a car moves in that time).
func next_clear(s_line: float, t: float, dur: float, gap: float = 40.0) -> float:
	var go := t
	for _try in 600:
		var bad := -INF
		var k := 0.0
		while k <= dur + 0.5:
			var b := base(go + k)
			if absf(float(b["s"]) - s_line) - HALF < gap + 7.0:
				bad = go + k
			k += 0.5
		if bad == -INF:
			return go
		go = bad + 0.5
	return go


# --- Network -----------------------------------------------------------------------------------------------

const EP_KEYS := ["t0", "s0", "v0", "t1", "s1", "tr", "ps", "pdwell", "dep_sched", "dep_base"]


func snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(SNAP_VERSION)
	buf.put_u16(episodes.size())
	for e: Dictionary in episodes:
		for k: String in EP_KEYS:
			buf.put_double(float(e[k]))
	return buf.data_array


func restore(bytes: PackedByteArray) -> void:
	episodes.clear()
	if bytes.size() < 3:
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_u8() != SNAP_VERSION:
		return
	var n := buf.get_u16()
	for i in n:
		var e := {}
		for k: String in EP_KEYS:
			e[k] = buf.get_double()
		_finish(e)
		episodes.append(e)


func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	buf.put_32(int(round(x * 1000.0)))
	buf.put_32(int(round(period * 1000.0)))
	buf.put_32(int(round(phase * 1000.0)))
	buf.put_8(1 if portal_lo else 0)
	buf.put_8(1 if portal_hi else 0)
	for sp: Dictionary in stops:
		buf.put_32(int(round(float(sp["s"]) * 1000.0)))
		buf.put_32(int(round(float(sp["dwell"]) * 1000.0)))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
