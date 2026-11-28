class_name LifeTram
extends RefCounted
## The tram of a section's top deck (docs/design/city-spine.md section 5, docs/design/ambient-life.md "Tram"). ONE line,
## ONE direction: a ring line on ONE track, the centre line of the section's `rail` lane (whatever its width). A train of
## three cars comes in through the s0 tram door out of its tunnel, stops at the deck's one station (CityStation: the
## middle car's centre at the platform's centre) for DWELL s, leaves through the s1 tram door into that tunnel and runs on
## out of sight; the next train starts a fixed `period` later (PERIOD, or the pass time + GAP on a long deck). 14 m/s,
## 1.2 m/s^2 up and down. Only deck 0 has a tram (make() returns null on every other deck and on a district on its own:
## no rail lane there).
##
## Every train starts hidden behind the s0 tunnel's back plate (TUNNEL m beyond the door plane, ENTRY_RUN m more) at
## cruise speed and parks once wholly beyond the s1 tunnel's plate (hidden). Collision follows the old rule: a car is solid
## only while all of it is END_CLEAR m inside both end walls (car_solid), so it never shoves a mech into a door.
##
## DOORS (user: "the train can't run unless its door is specifically open"; "if we close the doors, the train should
## stop"): the train moves toward a tram door only while that door is fully open (DOOR_OPEN s after it starts opening).
## Shut ahead: it brakes (ACC, up to BRAKE) to wait with its nose END_CLEAR m short of the door plane and goes on once the
## door is fully open again. Shut behind (s0): the next train waits in the tunnel behind it, out of sight, so no train
## arrives; one already inside goes on. A train that can no longer stop before a door that shuts in front of it (more than
## BRAKE needed) is committed and runs through (MissionWorld should not shut a tram door on a train: door_clear()). Only
## one train runs at a time: a train whose start comes while the previous one has not parked does not run (its slot is
## skipped), so after a long wait the timetable simply resumes at the next slot.
## HALTS: a threat within HALT_R m of any car (the host's life.threat) brakes it at BRAKE after REACT s, hazards on, held
## until RESTART s after the last threat in range; then it carries on (to the station, or out). Not wreckable, not
## pushable; shots, blasts and sweeps ignore it.
##
## PURE FUNCTION of (plan, phase, the decided events): `episodes` (halts {t0, tr}) and `door_events` ({end 0 | 1, open,
## t}) in time order, on the shared clock; pose(t) replays every train from the first one an event could touch
## (_simulate: piecewise constant acceleration), memoised until the events change. Two machines with the same events agree
## at every clock time, whenever each applied them.

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
const PERIOD := 120.0                   ## s between trains (at least the pass time + GAP)
const GAP := 20.0                       ## s: one train parks at least this long before the next one starts
const TUNNEL := 40.0                    ## m: a tram tunnel's back plate beyond its door plane (CityWalls / MissionWorld)
const ENTRY_RUN := 10.0                 ## m: a train starts with its nose this far behind the s0 tunnel's plate
const DOOR_OPEN := 3.0                  ## s a tram door takes to open fully (MissionGateDoor)
const HALT_R := 60.0                    ## m: a threat this close to any car halts it
const RESTART := 15.0                   ## s after the last threat in range
const REACT := 0.3                      ## s from the threat to the brakes
const MASS := 25000.0                   ## kg (nothing in the game can shove it)
## m: a car is solid (collision on) only while ALL of it is at least this far inside both end walls (car_solid). A mech's
## capsule is 4.4 m across, so a solid car can shove a mech toward an end wall only until the mech's far side is 0.6 m
## short of the wall plane: never into a tram door (3.8 m wide: no mech fits) nor against the wall beside it. Also the
## gap a train waiting at a shut door keeps (its nose this far short of the door plane).
const END_CLEAR := 5.0
## HP to EACH leg of a mech a car pins (LifeTramCars: once per mech per train pass, then the car passes through it), like
## a hard fall at 40 m/s (PlayerTarget.fall_damage(40): 60 per leg, 30 % of a leg's 200 HP; a fall caps at 180).
const CRUSH_DAMAGE := 60.0
const SNAP_VERSION := 2                 ## 2: halts as {t0, tr} and the door events (1: derived halt episodes, two-way)
const MODES := ["running", "dwell", "halted", "waiting"]
enum { M_RUN, M_DWELL, M_HALT, M_WAIT }

var plan: CityPlan
var x := 0.0                 ## the track: the rail lane's centre line
var wall_lo := 0.0           ## the deck's end walls (s): the tram doors' planes
var wall_hi := 0.0
var stop_s := 0.0            ## the station stop (the platform's centre; NAN: no station, it runs through)
var s_in := 0.0              ## where a train starts (hidden behind the s0 tunnel's plate) ...
var s_out := 0.0             ## ... and parks (hidden behind the s1 plate)
var stop_lo := 0.0           ## where it waits for a shut s0 / s1 door (nose END_CLEAR short of the plane)
var stop_hi := 0.0
var phase := 0.0             ## s, where in its period the timetable is at clock 0 (from the seed)
var period := 0.0
var pass_time := 0.0         ## s from a train's start to its parking on the timetable
var stops: Array = []        ## [{s, dwell, kind: "station"}] (one, or none)
var episodes: Array = []     ## the halts [{t0, tr}] in time order (state: decided by the host's threat events)
var door_events: Array = []  ## [{end: 0 (s0) | 1 (s1), open, t}] in time order (state: the host's door calls)
var _bp: Array = []          ## the timetable train's pieces, relative to its start
var _bstarts := PackedFloat64Array()
var _jlist: Array = []       ## memo: journeys _k0 .. _k_last replayed with the events
var _k0 := 0
var _k_last := -1
var _tail: Dictionary = {}   ## after _k_last: {} the timetable, else the train that never parks (every later slot skipped)
var _dirty := true


func net_fields() -> Dictionary:
	return {
		"plan": Net.SPAWN, "phase": Net.SPAWN,            # from the mission seed
		"episodes": Net.OWNER, "door_events": Net.OWNER,  # the host's threat events and door calls decide them everywhere
		# derived from the plan on every machine (checksum())
		"x": Net.LOCAL, "wall_lo": Net.LOCAL, "wall_hi": Net.LOCAL, "stop_s": Net.LOCAL, "s_in": Net.LOCAL,
		"s_out": Net.LOCAL, "stop_lo": Net.LOCAL, "stop_hi": Net.LOCAL, "period": Net.LOCAL, "pass_time": Net.LOCAL,
		"stops": Net.LOCAL, "_bp": Net.LOCAL, "_bstarts": Net.LOCAL,
		# memo of pose(): a pure function of the above
		"_jlist": Net.LOCAL, "_k0": Net.LOCAL, "_k_last": Net.LOCAL, "_tail": Net.LOCAL, "_dirty": Net.LOCAL,
	}


## The tram of a section's top deck, or null (another deck, a district on its own: no tram). `rnd` in [0, 1): its phase.
static func make(p: CityPlan, rnd: float) -> LifeTram:
	if p == null or p.section == null or p.deck != 0:
		return null
	var rail := p.section.lane_x("rail")
	if rail.y - rail.x < CAR_W:
		return null
	var t := LifeTram.new()
	t.build(p, rnd)
	return t


func build(p: CityPlan, rnd: float) -> void:
	plan = p
	var rail := p.section.lane_x("rail")
	x = (rail.x + rail.y) * 0.5
	wall_lo = p.extent.position.y
	wall_hi = p.extent.end.y
	s_in = wall_lo - TUNNEL - ENTRY_RUN - HALF
	s_out = wall_hi + TUNNEL + HALF + 1.0
	stop_lo = wall_lo - END_CLEAR - HALF
	stop_hi = wall_hi - END_CLEAR - HALF
	var st := CityStation.of(p)
	stop_s = NAN
	stops.clear()
	if not st.is_empty():
		stop_s = clampf(float(st["stop_s"]), wall_lo + HALF + END_CLEAR, wall_hi - HALF - END_CLEAR)
		stops.append({"s": stop_s, "dwell": DWELL, "kind": "station"})
	episodes.clear()
	door_events.clear()
	var j := _simulate(0.0, false)
	_bp = j["pieces"]
	_bstarts = j["starts"]
	pass_time = float(j["end"])
	period = maxf(PERIOD, ceilf(pass_time + GAP))
	phase = floorf(rnd * period)
	_dirty = true


# --- One train ------------------------------------------------------------------------------------------------

## s and v at time t on piece pc [t0, t1, s0, v0, a, mode, hazard].
static func _at(pc: Array, t: float) -> Vector2:
	var dt := t - float(pc[0])
	return Vector2(float(pc[2]) + float(pc[3]) * dt + 0.5 * float(pc[4]) * dt * dt, float(pc[3]) + float(pc[4]) * dt)


## Pieces from (t, s, v) to rest at tgt (accelerate at ACC, cruise at V, brake at ACC; harder, up to what it needs, when
## it is already too close), or out to s_out (tgt INF: accelerate to V and cruise).
func _plan(t: float, s: float, v: float, tgt: float) -> Array:
	var out: Array = []
	if tgt == INF:
		if v < V - 1e-9:
			var ta := (V - v) / ACC
			var da := v * ta + 0.5 * ACC * ta * ta
			if s + da >= s_out:
				ta = (-v + sqrt(v * v + 2.0 * ACC * maxf(s_out - s, 0.0))) / ACC
				out.append([t, t + ta, s, v, ACC, M_RUN, false])
				return out
			out.append([t, t + ta, s, v, ACC, M_RUN, false])
			t += ta
			s += da
		out.append([t, t + maxf(s_out - s, 0.0) / V, s, V, 0.0, M_RUN, false])
		return out
	var d := tgt - s
	if d <= 1e-6:
		return out
	var need := v * v / (2.0 * d)
	if need > ACC + 1e-9:
		out.append([t, t + v / need, s, v, -need, M_RUN, false])
		return out
	var vc := minf(sqrt(ACC * d + v * v * 0.5), V)
	var ta := maxf((vc - v) / ACC, 0.0)
	var da := (vc * vc - v * v) / (2.0 * ACC)
	var dd := vc * vc / (2.0 * ACC)
	var dc := maxf(d - da - dd, 0.0)
	if ta > 1e-9:
		out.append([t, t + ta, s, v, ACC, M_RUN, false])
	t += ta
	s += da
	if dc > 1e-9:
		out.append([t, t + dc / vc, s, vc, 0.0, M_RUN, false])
		t += dc / vc
		s += dc
	out.append([t, t + vc / ACC, s, vc, -ACC, M_RUN, false])
	return out


## Whether door `end` (0: s0, 1: s1) is fully open at t (no call: open).
func door_ok(end: int, t: float) -> bool:
	for i in range(door_events.size() - 1, -1, -1):
		var r: Dictionary = door_events[i]
		if int(r["end"]) == end and float(r["t"]) <= t:
			return bool(r["open"]) and t >= float(r["t"]) + DOOR_OPEN
	return true


## The first time after t when a door's fully-open state may change.
func _next_door_change(t: float) -> float:
	var best := INF
	for r: Dictionary in door_events:
		var c := float(r["t"]) + (DOOR_OPEN if bool(r["open"]) else 0.0)
		if c > t + 1e-9 and c < best:
			best = c
	return best


## One train from its start ts: {start, end (INF: it never parks), pieces, starts, off (0: absolute times)}. `recs`:
## with the events (false: the timetable).
func _simulate(ts: float, recs: bool) -> Dictionary:
	var pieces: Array = []
	var t := ts
	var s := s_in
	var v := V
	var ph := 0                        # 0 to the station, 1 dwelling, 2 out
	if is_nan(stop_s):
		ph = 2
	var dwell_end := INF
	var commit := [false, false]
	var hi := 0
	if recs:
		while hi < episodes.size() and float(episodes[hi]["t0"]) < ts - 1e-9:
			hi += 1                    # halts before this train started are not its own
	var end := INF
	for _guard in 4000:
		if ph == 2 and s >= s_out - 1e-6:
			end = t
			break
		if recs and hi < episodes.size() and float(episodes[hi]["t0"]) <= t + 1e-9:
			var e: Dictionary = episodes[hi]
			hi += 1
			if _visible(s):
				if v > 1e-9:
					var tb := v / BRAKE
					pieces.append([t, t + tb, s, v, -BRAKE, M_HALT, true])
					s += v * v / (2.0 * BRAKE)
					v = 0.0
					t += tb
				var until := maxf(float(e["tr"]), t)
				if until > t:
					pieces.append([t, until, s, 0.0, 0.0, M_HALT, true])
					t = until
				while hi < episodes.size() and float(episodes[hi]["t0"]) < t:
					hi += 1
			continue
		var t_next := INF
		if recs:
			if hi < episodes.size():
				t_next = float(episodes[hi]["t0"])
			t_next = minf(t_next, _next_door_change(t))
		if ph == 1:
			var tn := minf(t_next, dwell_end)
			pieces.append([t, tn, s, 0.0, 0.0, M_DWELL, false])
			t = tn
			if t >= dwell_end - 1e-9:
				ph = 2
			continue
		var tgt := INF
		var door := -1
		if ph == 0:
			tgt = stop_s
			if recs and not commit[0] and s <= stop_lo + 1e-6 and not door_ok(0, t):
				tgt = stop_lo
				door = 0
		elif recs and not commit[1] and s <= stop_hi + 1e-6 and not door_ok(1, t):
			tgt = stop_hi
			door = 1
		if tgt < INF:
			var d := tgt - s
			if d <= 1e-4 and v <= 1e-4:
				s = tgt
				v = 0.0
				if door < 0:           # at the station
					ph = 1
					dwell_end = t + DWELL
					continue
				if t_next == INF:      # waiting at a door that never opens again
					pieces.append([t, INF, s, 0.0, 0.0, M_WAIT, false])
					break
				pieces.append([t, t_next, s, 0.0, 0.0, M_WAIT, false])
				t = t_next
				continue
			if door >= 0 and v * v / (2.0 * maxf(d, 1e-9)) > BRAKE + 1e-6:
				commit[door] = true    # too close to stop before it: runs through
				continue
		var pl := _plan(t, s, v, tgt)
		if pl.is_empty():
			s = tgt
			v = 0.0
			continue
		var p_end := float(pl[-1][1])
		var stop_at := minf(t_next, p_end)
		var last: Array = []
		for pc: Array in pl:
			if float(pc[0]) >= stop_at - 1e-12 and not last.is_empty():
				break
			var q := pc.duplicate()
			q[1] = minf(float(pc[1]), stop_at)
			pieces.append(q)
			last = q
		var sv := _at(last, stop_at)
		t = stop_at
		s = sv.x
		v = maxf(sv.y, 0.0)
		if stop_at >= p_end - 1e-9:
			if tgt < INF:
				s = tgt
				v = 0.0
			else:
				s = s_out
	var starts := PackedFloat64Array()
	for pc: Array in pieces:
		starts.append(float(pc[0]))
	return {"start": ts, "end": end, "pieces": pieces, "starts": starts, "off": 0.0, "cancel": false}


## Whether any car of a train whose middle car is at s is drawn (not wholly behind a tunnel's plate).
func _visible(s: float) -> bool:
	for i in CARS:
		if car_inside(car_s(s, i)):
			return true
	return false


# --- The timetable and the trains ---------------------------------------------------------------------------------

func slot_start(n: int) -> float:
	return float(n) * period - phase


func _slot(t: float) -> int:
	return floori((t + phase) / period)


## Train n on the timetable (no events).
func _base_j(n: int) -> Dictionary:
	var ts := slot_start(n)
	return {"start": ts, "end": ts + pass_time, "pieces": _bp, "starts": _bstarts, "off": ts, "cancel": false}


## Train n as the events have it ({cancel: true, owner: the train still running} when its slot is skipped).
func _journey(n: int) -> Dictionary:
	if _dirty:
		_replay()
	if _jlist.is_empty() or n < _k0:
		return _base_j(n)
	if n <= _k_last:
		return _jlist[n - _k0]
	if not _tail.is_empty():
		return {"cancel": true, "owner": _tail}
	return _base_j(n)


## Replays every train from the last one no event can touch to the first one after every event that runs to the
## timetable (or one that never parks: a door shut for good).
func _replay() -> void:
	_dirty = false
	_jlist.clear()
	_tail = {}
	_k_last = -1
	if episodes.is_empty() and door_events.is_empty():
		return
	var r_min := INF
	var r_max := -INF
	for e: Dictionary in episodes:
		r_min = minf(r_min, float(e["t0"]))
		r_max = maxf(r_max, float(e["tr"]))
	for r: Dictionary in door_events:
		r_min = minf(r_min, float(r["t"]))
		r_max = maxf(r_max, float(r["t"]) + DOOR_OPEN)
	_k0 = _slot(r_min) - 1                   # its train parked before r_min (pass_time < period)
	var active := _base_j(_k0)
	_jlist.append(active)
	var k := _k0
	for _guard in 100000:
		k += 1
		var ts := slot_start(k)
		var j: Dictionary
		if float(active["end"]) > ts + 1e-9:
			j = {"cancel": true, "owner": active}
		else:
			j = _simulate(ts, true)
			active = j
		_jlist.append(j)
		if float(active["end"]) == INF:
			_tail = active
			break
		if not bool(j["cancel"]) and ts > r_max:
			break                              # runs to the timetable, and so does every later train
	_k_last = k


func _eval(j: Dictionary, t: float) -> Dictionary:
	if t >= float(j["end"]) or t < float(j["start"]):
		return {"s": s_out, "v": 0.0, "mode": "away", "hazard": false}
	var tt := t - float(j["off"])
	var starts: PackedFloat64Array = j["starts"]
	var pieces: Array = j["pieces"]
	if pieces.is_empty():
		return {"s": s_out, "v": 0.0, "mode": "away", "hazard": false}
	var i := clampi(starts.bsearch(tt, false) - 1, 0, pieces.size() - 1)
	var pc: Array = pieces[i]
	var sv := _at(pc, minf(tt, float(pc[1])))
	var vis := _visible(sv.x)
	return {"s": sv.x, "v": maxf(sv.y, 0.0), "mode": MODES[int(pc[5])] if vis else "away", "hazard": bool(pc[6]) and vis}


## The timetable at clock b (no events): {s, v, mode, n (its slot)}. People crossing the rail lane go by this.
func base(b: float) -> Dictionary:
	var n := _slot(b)
	var p := _eval(_base_j(n), b)
	p["n"] = n
	return p


## The tram's pose at time t, events included: {s (the middle car's centre), v (along +s), mode (running | dwell |
## halted | waiting | away), hazard}. "away": no car drawn (in a tunnel behind its plate, or no train).
func pose(t: float) -> Dictionary:
	var j := _journey(_slot(t))
	if bool(j["cancel"]):
		j = j["owner"]
	return _eval(j, t)


func state_of(t: float) -> String:
	return str(pose(t)["mode"])


## The centre s of car i (0..2) when the middle car's centre is at s.
static func car_s(s: float, i: int) -> float:
	return s + float(i - 1) * PITCH


## Whether car i (at centre cs) is drawn: not wholly behind either tunnel's back plate.
func car_inside(cs: float) -> bool:
	return cs + CAR_L * 0.5 > wall_lo - TUNNEL and cs - CAR_L * 0.5 < wall_hi + TUNNEL


## Whether car i (at centre cs) is solid: wholly inside the map and at least END_CLEAR m from both end walls (a car in a
## tunnel or within END_CLEAR of a wall is drawn but has no collision).
func car_solid(cs: float) -> bool:
	return cs - CAR_L * 0.5 >= wall_lo + END_CLEAR and cs + CAR_L * 0.5 <= wall_hi - END_CLEAR


## Distance from arc point c to the nearest car of a train whose middle car is at s.
func dist_to(c: Vector2, s: float) -> float:
	var q := Vector2(x, clampf(c.y, s - HALF, s + HALF))
	return q.distance_to(c)


## Whether no car is in door `end`'s doorway (within END_CLEAR m of its plane, either side) at time t: when
## MissionWorld may shut that tram door without closing it on a train.
func door_clear(end: String, t: float) -> bool:
	var p := pose(t)
	var plane := wall_lo if end == "s0" else wall_hi
	return absf(float(p["s"]) - plane) > HALF + END_CLEAR


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
			_dirty = true
			return
	var t0 := T + REACT
	if pose(t0)["mode"] == "away":
		return
	episodes.append({"t0": t0, "tr": T + RESTART})
	_dirty = true


# --- Doors -------------------------------------------------------------------------------------------------

## Door `end` ("s0" | "s1") starts to open (open = true; fully open DOOR_OPEN s later) or shuts at clock time `at`.
## Kept in time order; an exact repeat is ignored. Returns whether it was recorded.
func set_door(end: String, open: bool, at: float) -> bool:
	var e := 0 if end == "s0" else (1 if end == "s1" else -1)
	if e < 0 or is_nan(at) or is_inf(at):
		return false
	for r: Dictionary in door_events:
		if int(r["end"]) == e and bool(r["open"]) == open and absf(float(r["t"]) - at) < 1e-4:
			return false
	var i := door_events.size()
	while i > 0 and float(door_events[i - 1]["t"]) > at:
		i -= 1
	door_events.insert(i, {"end": e, "open": open, "t": at})
	_dirty = true
	return true


## Whether door `end` ("s0" | "s1") is open (or opening) at t by the calls so far (no call: open).
func door_open(end: String, t: float) -> bool:
	var e := 0 if end == "s0" else 1
	for i in range(door_events.size() - 1, -1, -1):
		var r: Dictionary = door_events[i]
		if int(r["end"]) == e and float(r["t"]) <= t:
			return bool(r["open"])
	return true


## The clock source changed (LifeDeck._rebase): halts on the old clock mean nothing on the new one; a door shut at
## `old_now` stays shut (from long before `t`).
func rebase(old_now: float, t: float) -> void:
	var shut := [not door_open("s0", old_now), not door_open("s1", old_now)]
	episodes.clear()
	door_events.clear()
	for e in 2:
		if shut[e]:
			door_events.append({"end": e, "open": false, "t": t - period * 2.0})
	_dirty = true


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

## [u8 SNAP_VERSION, u16 halts, halts x (t0, tr) doubles, u16 door events, events x (u8 end, u8 open, double t)].
func snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(SNAP_VERSION)
	buf.put_u16(episodes.size())
	for e: Dictionary in episodes:
		buf.put_double(float(e["t0"]))
		buf.put_double(float(e["tr"]))
	buf.put_u16(door_events.size())
	for r: Dictionary in door_events:
		buf.put_u8(int(r["end"]))
		buf.put_u8(1 if r["open"] else 0)
		buf.put_double(float(r["t"]))
	return buf.data_array


## From a peer (life.sync): the counts must match the bytes exactly, ends must be 0 / 1, times finite and in order, else
## the whole buffer is ignored (no reading past its end, no allocating by the peer's count). Empty: no events.
func restore(bytes: PackedByteArray) -> void:
	episodes.clear()
	door_events.clear()
	_dirty = true
	if bytes.is_empty():
		return
	var ok := bytes.size() >= 5 and bytes[0] == SNAP_VERSION
	var nh := 0
	var nd := 0
	if ok:
		nh = bytes.decode_u16(1)
		ok = bytes.size() >= 5 + nh * 16
	if ok:
		nd = bytes.decode_u16(3 + nh * 16)
		ok = bytes.size() == 5 + nh * 16 + nd * 10
	var hs: Array = []
	var ds: Array = []
	if ok:
		var prev := -INF
		for i in nh:
			var t0 := bytes.decode_double(3 + i * 16)
			var tr := bytes.decode_double(3 + i * 16 + 8)
			if not (is_finite(t0) and is_finite(tr)) or t0 < prev:
				ok = false
				break
			prev = t0
			hs.append({"t0": t0, "tr": tr})
		var o := 5 + nh * 16
		prev = -INF
		for i in nd:
			if not ok:
				break
			var e := bytes[o + i * 10]
			var op := bytes[o + i * 10 + 1]
			var t := bytes.decode_double(o + i * 10 + 2)
			if e > 1 or op > 1 or not is_finite(t) or t < prev:
				ok = false
				break
			prev = t
			ds.append({"end": e, "open": op == 1, "t": t})
	if not ok:
		push_warning("LifeTram.restore: malformed snapshot (%d bytes): ignored" % bytes.size())
		return
	episodes = hs
	door_events = ds


func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	for f: float in [x, wall_lo, wall_hi, -1.0 if is_nan(stop_s) else stop_s, s_in, s_out, period, phase, pass_time]:
		buf.put_32(int(round(f * 1000.0)))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
