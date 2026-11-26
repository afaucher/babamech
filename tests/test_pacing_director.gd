extends TestCase
## PacingDirector (docs/design/pacing-director.md section 1), pure: a hand-made two-deck MissionPlan, facts fed tick by
## tick. Covers: the state machine (arrival rest -> build -> peak -> fade -> rest -> build), the quiet cap with its order
## lead (near / far source) and across a deck change (the pilot carries its quiet; the arrival rest does not stack), the
## quick-response source rule, objective spikes (flag + its 50 % group, defend clock, sweep none, hold two sources + clock),
## scout call limits, the patrol allowance then the garrison hunt (a deck is finite: waves_left reaches 0, patrols never
## hold a sweep open), the caps and the half-group rule, co-op scaling, determinism, and the state round trip with pilot
## ids {1, 2, -1} (a hangar bot) through JSON.

const DT := 0.25


func setup() -> void:
	_states()
	_quiet_cap()
	_transit()
	_quick_sources()
	_flag()
	_defend()
	_sweep()
	_hold()
	_scouts()
	_scout_expiry()
	_patrols_then_hunt()
	_borrow()
	_defend_by_crew()
	_caps()
	_overrides()
	_freed_mech()
	_scaling()
	_determinism()
	_round_trip()
	_rescale()
	_rescale_defend()
	_rescale_determinism()
	_rescale_round_trip()
	finish()


# --- Fixtures ----------------------------------------------------------------------------------------------------

## Two decks. Deck 0: gate_a (0, 0), gate_far (0, 400), ramp (300, 150); deck 1: gate (0, 0), gate2 (40, 330).
## Objectives deck 0: flag d0_p at (0, 200), bonus defend d0_b0 at (60, 200); deck 1: sweep d1_p, the hold.
## Reserve deck 0: 3 free groups, the flag's group, 2 defend groups; deck 1: 2 free groups, the hold's group.
func _plan() -> MissionPlan:
	var p := MissionPlan.new()
	p.deck_count = 2
	p.sources = [_src("d0_gate_a", 0, "gate", 0.0, 0.0), _src("d0_gate_far", 0, "gate", 0.0, 400.0),
		_src("d0_ramp_1", 0, "ramp", 300.0, 150.0), _src("d1_gate_a", 1, "gate", 0.0, 0.0),
		_src("d1_gate_b", 1, "gate", 40.0, 330.0)]
	p.objectives = [_obj("d0_p", "flag", 0, "primary", 0.0, 200.0, {"hold": 20.0}),
		_obj("d0_b0", "defend", 0, "bonus", 60.0, 200.0, {"waves": 2, "asset_hp": 1.0}),
		_obj("d1_p", "sweep", 1, "primary", 0.0, 300.0, {}),
		_obj("hold", "hold", 1, "primary", 0.0, 150.0, {"hold": 60.0, "zone": Rect2(-20, 130, 40, 40)})]
	p.pools = [
		{"deck": 0, "garrison": 0.5, "reserve": [_g("d0_w0", 0.1, "light"), _g("d0_w1", 0.15, "light"),
			_g("d0_w2", 0.2, "mixed"), _g("d0_w3", 0.15, "mixed", "d0_p"), _g("d0_w4", 0.2, "heavy", "d0_b0"),
			_g("d0_w5", 0.2, "heavy", "d0_b0")]},
		{"deck": 1, "garrison": 0.5, "reserve": [_g("d1_w0", 0.3, "light"), _g("d1_w1", 0.3, "mixed"),
			_g("d1_w2", 0.4, "heavy", "hold")]}]
	return p


func _src(id: String, k: int, kind: String, x: float, s: float) -> Dictionary:
	return {"id": id, "deck": k, "kind": kind, "x": x, "s": s, "toward": {"x": x, "s": s + 20.0}, "load": 6,
		"connector": -1, "edge": ""}


func _obj(id: String, ty: String, k: int, role: String, x: float, s: float, params: Dictionary) -> Dictionary:
	return {"id": id, "type": ty, "deck": k, "role": role, "site": {"x": x, "s": s}, "radius": 14.0, "needs": [],
		"params": params}


func _g(id: String, share: float, theme: String, for_id: String = "") -> Dictionary:
	return {"id": id, "share": share, "theme": theme, "source": "", "for": for_id}


## A scenario: the director, its clock, the pilots ({peer: {deck, x, s, tot, engaged, downed}}), objective states, alive /
## active / engaging per deck, wave sizes; step() ticks DT and records every order.
class Sim:
	var d: PacingDirector
	var t := 1.0
	var pilots := {}
	var objs := {}
	var alive := [0, 0]
	var active: Variant = null
	var engaging := [0, 0]
	var sizes := {}
	var wave_alive := {}
	var pending := {}
	var kills: Array = []
	var orders: Array = []
	var events: Array = []

	func _init(plan: MissionPlan, opts: Dictionary = {}, crew: int = 1) -> void:
		d = PacingDirector.make(plan, opts, crew)
		for k in plan.deck_count:
			for g: Dictionary in plan.pools[k]["reserve"]:
				sizes[g["id"]] = 4

	func facts() -> Dictionary:
		var crew: Array = []
		var pf := {}
		for peer: Variant in pilots:
			var p: Dictionary = pilots[peer]
			crew.append({"peer": peer, "downed": bool(p.get("downed", false)), "deck": int(p["deck"]), "x": float(p["x"]),
				"s": float(p["s"])})
			pf[str(peer)] = {"tot": float(p.get("tot", 100.0)), "destroyed": int(p.get("destroyed", 0)),
				"disabled": bool(p.get("downed", false)), "shutdown": false, "engaged": bool(p.get("engaged", false))}
		var st := {}
		for id: String in objs:
			st[id] = objs[id]
		var f := {"alive": alive.duplicate(), "engaging": engaging.duplicate(), "crew": crew, "pilots": pf,
			"objectives": {"objs": st}, "wave_size": sizes, "wave_alive": wave_alive, "wave_pending": pending, "kills": kills}
		if active != null:
			f["active"] = active
		return f

	func step(n: int = 1) -> Array:
		var got: Array = []
		for i in n:
			t += 0.25
			var o := d.tick(t, facts())
			kills = []
			for od: Dictionary in o:
				var e: Dictionary = od.duplicate()
				e["t"] = t
				orders.append(e)
				got.append(e)
			events.append_array(d.take_events())
		return got

	## Run until `pred` (Callable(Sim) -> bool) or `secs`.
	func until(pred: Callable, secs: float) -> bool:
		var end := t + secs
		while t < end:
			step()
			if pred.call(self):
				return true
		return false

	## Every released group's units appear and die at once (so build never waits on "beaten").
	func kill_all() -> void:
		for o: Dictionary in orders:
			wave_alive[o["wave"]] = {"alive": 0, "total": int(sizes.get(o["wave"], 2))}


func _solo(plan: MissionPlan, opts: Dictionary = {}) -> Sim:
	var s := Sim.new(plan, opts)
	s.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
	return s


# --- State machine -----------------------------------------------------------------------------------------------

func _states() -> void:
	var s := _solo(_plan(), {"quiet_cap": 1000.0})   # no cap: the state machine alone
	s.step()
	eq(s.d.pace_state(0), "rest", "a deck starts in rest when the crew arrives")
	s.until(func(x: Sim) -> bool: return x.d.pace_state(0) == "build", 20.0)
	near(s.t - 1.25, PacingDirector.ARRIVAL_REST, 0.5, "arrival rest lasts ARRIVAL_REST")
	var first: Array = s.orders.filter(func(o: Dictionary) -> bool: return o["reason"] == "build")
	if check(not first.is_empty(), "build releases a group"):
		eq(str(first[0]["wave"]), "d0_w0", "the first release after a rest is the lightest group")
	# Peak: the pilot loses 80 % structure while engaged.
	s.pilots[1]["engaged"] = true
	s.pilots[1]["tot"] = 20.0
	s.step()
	eq(s.d.pace_state(0), "peak", "crew intensity >= 70 ends build (I %.0f)" % s.d.intensity(1))
	s.until(func(x: Sim) -> bool: return x.d.pace_state(0) != "peak", 10.0)
	eq(s.d.pace_state(0), "fade", "peak lasts PEAK_HOLD then fade")
	var n0 := s.orders.size()
	s.step(8)
	eq(s.orders.size(), n0, "no release in fade")
	s.pilots[1]["engaged"] = false
	s.until(func(x: Sim) -> bool: return x.d.pace_state(0) == "rest", 40.0)
	eq(s.d.pace_state(0), "rest", "fade ends once I < 35 and nobody engaged for 5 s")
	check(s.d.intensity(1) < PacingDirector.FADE_I, "intensity decayed under FADE_I (%.0f)" % s.d.intensity(1))
	var rest_t := s.t
	s.until(func(x: Sim) -> bool: return x.d.pace_state(0) == "build", 40.0)
	near(s.t - rest_t, s.d.rest_length(0), 0.5, "rest lasts rest_length(deck 0) = REST_FIRST")
	near(s.d.rest_length(1), PacingDirector.REST_LAST, 0.001, "the last deck rests REST_LAST")
	# Build ends after BUILD_MAX even without a peak.
	var b_t := s.t
	s.until(func(x: Sim) -> bool: return x.d.pace_state(0) != "build", 120.0)
	near(s.t - b_t, PacingDirector.BUILD_MAX, 0.5, "build ends after BUILD_MAX")


# --- Quiet cap ---------------------------------------------------------------------------------------------------

func _quiet_cap() -> void:
	# Near quick source (gate 150 m): the cap orders at QUIET_CAP - ORDER_LEAD (20 s of quiet).
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0})
	s.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 60.0)
	if check(not s.orders.is_empty(), "the quiet cap releases a group"):
		var o: Dictionary = s.orders[0]
		eq(str(o["reason"]), "cap", "the release's reason is cap")
		near(s.t - 1.0, PacingDirector.QUIET_CAP - float(PacingDirector.ORDER_LEAD["gate"]), 0.5,
			"ordered at %.0f s of quiet (QUIET_CAP - ORDER_LEAD)" % (PacingDirector.QUIET_CAP - float(PacingDirector.ORDER_LEAD["gate"])))
		eq(str(o["source"]), "d0_gate_a", "from the quick source (gate 150 m)")
		eq(s.d.pace_state(0), "build", "the cap puts the deck in build")
	# One cap release per quiet stretch: none again until a whole QUIET_CAP passed without contact (build held off by a
	# crew already at ENGAGE_TARGET engaging enemies, so only the cap can release).
	s.engaging = [10, 0]
	var n := s.orders.size()
	s.step(int(30.0 / DT))
	eq(s.orders.size(), n, "no second cap release within QUIET_CAP of the first")
	s.step(int(20.0 / DT))
	check(s.orders.size() > n, "a cap release that never made contact is followed by another after QUIET_CAP")
	# An engagement resets it.
	s.pilots[1]["engaged"] = true
	s.step(4)
	s.pilots[1]["engaged"] = false
	var n2 := s.orders.size()
	var t0 := s.t
	s.until(func(x: Sim) -> bool: return x.orders.size() > n2, 60.0)
	near(s.t - t0, 20.0, 0.75, "after contact the next cap release is again at 20 s of quiet")
	# Far: only a gate 250 m by route -> lead ORDER_LEAD_FAR (ordered at 10 s of quiet).
	var p := _plan()
	p.sources = [_src("d0_gate_far", 0, "gate", 0.0, 400.0), _src("d1_gate_a", 1, "gate", 0.0, 0.0)]
	var f := _solo(p, {"rest_first": 1000.0, "arrival_rest": 1000.0})
	f.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 60.0)
	near(f.t - 1.0, PacingDirector.QUIET_CAP - PacingDirector.ORDER_LEAD_FAR, 0.5, "a 250 m source orders at 10 s of quiet")
	near(f.d.lead_for("d0_gate_far", Vector2(0, 150)), PacingDirector.ORDER_LEAD_FAR, 0.001, "lead_for a 250 m gate")
	near(f.d.lead_for("d0_gate_far", Vector2(0, 50)), PacingDirector.ORDER_LEAD_FARTHEST, 0.001, "lead_for a 350 m gate")


## A pilot crossing to the next deck brings its quiet: the arrival rest does not delay the cap.
func _transit() -> void:
	var s := _solo(_plan(), {"rest_first": 1000.0, "rest_last": 1000.0})
	s.pilots[1]["engaged"] = true
	s.step(2)
	s.pilots[1]["engaged"] = false
	s.step(int(15.0 / DT))   # 15 s quiet on deck 0 (before its cap)
	var n := s.orders.size()
	s.pilots[1] = {"deck": 1, "x": 0.0, "s": 150.0}   # walks onto deck 1 (the deck being entered owns the pilot)
	var arrive := s.t
	s.until(func(x: Sim) -> bool: return x.orders.size() > n, 30.0)
	check(s.orders.size() > n and int(s.orders[-1]["deck"]) == 1, "deck 1's cap releases for the arriving pilot")
	check(s.t - arrive < PacingDirector.ARRIVAL_REST, "within %.1f s of arriving, less than the arrival rest (quiet carried)" % (s.t - arrive))
	near(s.d.quiet(1), 20.0, 0.75, "deck 1's quiet counts from the pilot's last engagement on deck 0")


func _quick_sources() -> void:
	var d := PacingDirector.make(_plan())
	check(d.is_quick("d0_gate_a", 150.0), "a gate 150 m away is quick")
	check(not d.is_quick("d0_gate_a", 60.0), "a gate under 80 m is not")
	check(not d.is_quick("d0_gate_far", 250.0), "a gate 250 m away is not")
	check(d.is_quick("d0_ramp_1", 400.0), "a ramp is quick at any distance")
	# Route lengths decide: the gate's road is 280 m long, the ramp wins.
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0})
	s.step()
	var f := s.facts()
	f["source_route"] = {"d0_gate_a": 280.0, "d0_gate_far": 400.0, "d0_ramp_1": 330.0}
	var got: Array = []
	var t := s.t
	while got.is_empty() and t < 60.0:
		t += DT
		got = s.d.tick(t, f)
	if check(not got.is_empty(), "the cap released with route facts"):
		eq(str(got[0]["source"]), "d0_ramp_1", "by route the ramp is the quick source (gate road 280 m)")


# --- Objectives --------------------------------------------------------------------------------------------------

func _flag() -> void:
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0})
	s.step(4)
	s.objs["d0_p"] = ["active", 0.0, 20.0]
	var o := s.step()
	var fl: Array = o.filter(func(x: Dictionary) -> bool: return x["wave"] == "d0_w3")
	if check(not fl.is_empty(), "the flag's group is ordered the tick its capture starts"):
		eq(str(fl[0]["reason"]), "objective", "reason objective")
		var src := str(fl[0]["source"])
		var at := Vector2(float(s.d.plan.source(src)["x"]), float(s.d.plan.source(src)["s"]))
		check(at.distance_to(Vector2(0, 200)) >= 80.0, "from a source >= 80 m from the flag (%s)" % src)
	eq(s.d.pace_state(0), "build", "a flag forces build")
	s.objs["d0_p"] = ["active", 10.0, 20.0]
	var o2 := s.step()
	check(o2.size() == 1 and str(o2[0]["reason"]) == "objective", "a second group at 50 %% progress (%s)" % str(o2))
	s.objs["d0_p"] = ["done", 20.0, 20.0]
	s.step()
	eq(s.d.pace_state(0), "fade", "a raised flag fades")


func _defend() -> void:
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0})
	s.step(4)
	s.engaging = [10, 0]   # build held off: only the defend's own clock releases
	s.objs["d0_b0"] = ["active", 0.0, 2.0]
	var o := s.step()
	eq(o.size(), 1, "a defend orders its first group at once")
	if not o.is_empty():
		eq(str(o[0]["wave"]), "d0_w4", "the defend's first group")
	s.step(int((float(PacingDirector.DEFEND_EVERY_BY_CREW[0]) - 1.0) / DT))
	eq(s.orders.size(), 1, "nothing more before the solo DEFEND_EVERY (45 s)")
	s.until(func(x: Sim) -> bool: return x.orders.size() > 1, 3.0)
	if check(s.orders.size() == 2, "the second group DEFEND_EVERY s later (the asset is the clock)"):
		eq(str(s.orders[1]["wave"]), "d0_w5", "the defend's second group")
	s.engaging = [0, 0]
	var ow := s.d.objective_waves()
	eq(int(ow["d0_b0"]["released"]), 2, "objective_waves counts both released")
	# Stragglers: <= DEFEND_STRAGGLERS (2) or BEATEN of a group alive DEFEND_STRAGGLE s after its door no longer hold the
	# defend open; a fresh group's do, and so do 3 of 4.
	s.wave_alive["d0_w4"] = {"alive": 1, "total": 4}
	s.wave_alive["d0_w5"] = {"alive": 1, "total": 4}
	s.step()
	var fresh := int(s.d.objective_waves()["d0_b0"]["alive"])
	check(fresh >= 1, "a fresh group's straggler still counts (%d)" % fresh)
	s.step(int((PacingDirector.DEFEND_STRAGGLE + 4.0) / DT))   # (the second group's door opened 2 s after its order)
	eq(int(s.d.objective_waves()["d0_b0"]["alive"]), 0, "mostly-beaten groups DEFEND_STRAGGLE s after their door: done")
	s.wave_alive["d0_w4"] = {"alive": 3, "total": 4}
	s.wave_alive["d0_w5"] = {"alive": 3, "total": 4}
	s.step()
	eq(int(s.d.objective_waves()["d0_b0"]["alive"]), 6, "3 of 4 alive in each group: the defend is still on")
	s.objs["d0_b0"] = ["done", 2.0, 2.0]
	s.step()
	eq(s.d.pace_state(0), "rest", "a finished defend gives a full rest")


func _sweep() -> void:
	var s := Sim.new(_plan(), {"rest_last": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0})
	s.pilots[1] = {"deck": 1, "x": 0.0, "s": 150.0}
	s.step()
	s.objs["d1_p"] = ["active", 0.0, 0.0]
	var o := s.step(4)
	eq(o.size(), 0, "a sweep spikes nothing")
	eq(s.d.waves_left(1), 2, "the sweep deck owes its 2 free groups (the hold's group is not owed before the hold)")


func _hold() -> void:
	var s := Sim.new(_plan(), {"rest_last": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0, "build_gap": 1000.0})
	s.pilots[1] = {"deck": 1, "x": 0.0, "s": 150.0}
	s.engaging = [0, 0]   # build held off by its gap (no group of it beaten): the hold's own clock only
	s.step()
	s.objs["hold"] = ["active", 0.0, 60.0]
	var o: Array = s.step().filter(func(x: Dictionary) -> bool: return x["reason"] == "objective")
	if check(o.size() == 2, "the hold orders two groups at once (%s)" % str(o)):
		check(str(o[0]["source"]) != str(o[1]["source"]), "from two sources (%s, %s)" % [o[0]["source"], o[1]["source"]])
	var n := s.orders.size()
	s.until(func(x: Sim) -> bool: return x.orders.size() > n, PacingDirector.HOLD_EVERY + 1.0)
	near(s.t - (s.orders[n - 1]["t"] as float), PacingDirector.HOLD_EVERY, 0.5, "then a group every HOLD_EVERY s")
	s.step(int(30.0 / DT))
	check(s.d.pace_state(1) in ["build", "peak"], "no rest and no fade during the hold (%s)" % s.d.pace_state(1))
	# Bounded: the hold clock waits while the crew is at ENGAGE_TARGET, and its extra patrols stop at hold_patrols().
	s.engaging = [0, 10]
	var m := s.orders.size()
	s.step(int(60.0 / DT))
	eq(s.orders.size(), m, "no hold release while the crew already has ENGAGE_TARGET enemies engaging it")
	s.engaging = [0, 0]
	s.step(int(600.0 / DT))
	var pats: Array = s.orders.filter(func(x: Dictionary) -> bool: return str(x["wave"]).begins_with("d1_pat"))
	eq(pats.size(), s.d.patrol_allowance() + s.d.hold_patrols(), "the hold adds at most hold_patrols() beyond the allowance (%d)" % pats.size())
	eq(s.d.deck_ceiling(1, s.sizes), 4 * 3 + 2 * (s.d.patrol_allowance() + s.d.hold_patrols()),
		"deck_ceiling: reserve + patrols + hold extras, finite")


# --- Scouts ------------------------------------------------------------------------------------------------------

func _scouts() -> void:
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0})
	s.step(2)
	s.d.scout_call(0, 0.0, 300.0, "drone_a", s.t)
	var o := s.step()
	if check(o.size() == 1, "a completed beacon releases a group at once (rest or not)"):
		eq(str(o[0]["reason"]), "scout", "reason scout")
	s.step(int(10.0 / DT))
	s.d.scout_call(0, 0.0, 300.0, "drone_b", s.t)
	eq(s.step().size(), 0, "a second scout on the deck within CALL_EVERY brings nothing")
	s.step(int(25.0 / DT))
	s.d.scout_call(0, 0.0, 300.0, "drone_a", s.t)
	eq(s.step().size(), 0, "the same scout again within SCOUT_EVERY brings nothing")
	s.d.scout_call(0, 0.0, 300.0, "drone_b", s.t)
	eq(s.step().size(), 1, "another scout after CALL_EVERY does")
	# The engage ceiling: no scout release while the crew already has ENGAGE_TARGET enemies engaging it.
	s.step(int(50.0 / DT))
	s.engaging = [10, 0]
	s.d.scout_call(0, 0.0, 300.0, "drone_c", s.t)
	eq(s.step().size(), 0, "a scout call cannot push engaging past the ceiling")
	s.engaging = [0, 0]
	# The per-deck budget: SCOUT_RELEASES (+1 per extra pilot) releases, then calls bring nothing.
	var got := 2
	for i in 6:
		s.step(int(50.0 / DT))
		s.d.scout_call(0, 0.0, 300.0, "drone_x%d" % i, s.t)
		got += s.step().size()
	eq(got, s.d.scout_budget(), "scouts cause at most scout_budget() releases on a deck (%d)" % got)


## Audit 2026-11 (finding 2): a scout call held for lack of room lapses after SCOUT_CALL_TTL s (before the fix it waited
## forever and fired once room appeared, minutes later), lapses when nobody stands on its deck, and the queue is bounded.
func _scout_expiry() -> void:
	var opts := {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0, "deck_cap": 24}
	var scouts := func(x: Sim) -> Array: return x.orders.filter(func(o: Dictionary) -> bool: return o["reason"] in ["scout", "patrol"])
	# Fresh: held while there is no room, served once room appears within the lifetime.
	var a := _solo(_plan(), opts)
	a.step(2)
	a.alive = [23, 0]   # room 1: no group, no patrol fits
	a.d.scout_call(0, 0.0, 300.0, "drone_a", a.t)
	a.step(int(5.0 / DT))
	eq((scouts.call(a) as Array).size(), 0, "no room: the call is held")
	eq(a.d.pending_calls().size(), 1, "and waits")
	a.alive = [0, 0]
	a.step()
	eq((scouts.call(a) as Array).size(), 1, "room within SCOUT_CALL_TTL: the held call is served")
	# Stale: room only after the lifetime.
	var b := _solo(_plan(), opts)
	b.step(2)
	b.alive = [23, 0]
	b.d.scout_call(0, 0.0, 300.0, "drone_a", b.t)
	b.step(int((PacingDirector.SCOUT_CALL_TTL + 2.0) / DT))
	b.alive = [0, 0]
	b.step(int(10.0 / DT))
	eq((scouts.call(b) as Array).size(), 0, "a call held past SCOUT_CALL_TTL never fires (%s)" % str(b.orders))
	eq(b.d.pending_calls().size(), 0, "it lapsed")
	check(b.events.any(func(e: Dictionary) -> bool: return e["tag"] == "scout" and e["ev"] == "expired"), "logged as expired")
	# Nobody on its deck any more: lapses at once, and does not fire when the crew comes back.
	var c := _solo(_plan(), opts)
	c.step(2)
	c.alive = [23, 0]
	c.d.scout_call(0, 0.0, 300.0, "drone_a", c.t)
	c.step(4)
	c.pilots[1] = {"deck": 1, "x": 0.0, "s": 150.0}
	c.step(2)
	eq(c.d.pending_calls().size(), 0, "the crew left the call's deck: it lapsed")
	c.alive = [0, 0]
	c.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
	c.step(int(5.0 / DT))
	eq((scouts.call(c) as Array).size(), 0, "nothing fires when the crew returns (%s)" % str(c.orders))
	# Bounded.
	var q := _solo(_plan(), opts)
	q.step(2)
	q.alive = [23, 0]
	for i in 20:
		q.d.scout_call(0, 0.0, 300.0, "drone_q%d" % i, q.t)
	q.step()
	check(q.d.pending_calls().size() <= PacingDirector.SCOUT_CALL_MAX, "at most SCOUT_CALL_MAX calls wait (%d)" % q.d.pending_calls().size())


# --- Patrols, garrison hunt, a sweep can end -----------------------------------------------------------------------

func _patrols_then_hunt() -> void:
	var s := Sim.new(_plan(), {"rest_last": 1000.0, "arrival_rest": 1000.0})
	s.pilots[1] = {"deck": 1, "x": 0.0, "s": 150.0}
	s.objs["d1_p"] = ["active", 0.0, 0.0]
	var reasons: Array = []
	var hunts := 0
	for i in int(600.0 / DT):
		for o: Dictionary in s.step():
			reasons.append(str(o["reason"]))
			s.wave_alive[o["wave"]] = {"alive": 0, "total": 2}
		for ev: Dictionary in s.events:
			if ev["tag"] == "hunt":
				hunts += 1
		s.events = []
	var patrols := reasons.count("patrol")
	eq(patrols, PacingDirector.PATROLS, "the cap released the reserve, then PATROLS patrols (%s)" % str(reasons))
	check(reasons.count("cap") + reasons.count("build") >= 2, "the free groups came first")
	check(hunts >= 1, "with reserve and patrols spent, the cap sends the garrison hunting (%d)" % hunts)
	eq(s.d.patrols_left(1), 0, "the patrol allowance is spent")
	eq(s.d.waves_left(1), 0, "nothing more is owed: a sweep can end (patrols never hold it open)")


# --- Caps and the half rule ----------------------------------------------------------------------------------------

func _caps() -> void:
	for n in [1, 2, 3, 4]:
		eq(int(PacingDirector.make(_plan(), {}, n).options["deck_cap"]), int(PacingDirector.DECK_CAP_BY_CREW[n - 1]),
			"%d pilots: DECK_CAP %d in play" % [n, int(PacingDirector.DECK_CAP_BY_CREW[n - 1])])
	# The half rule against the 4-pilot cap of 24 (set explicitly; the rule is the same for every cap).
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 24})
	s.sizes["d0_w0"] = 6
	s.alive = [22, 0]          # room 2 under DECK_CAP 24, group of 6: held
	s.step(int(25.0 / DT))
	var held: Array = s.orders.filter(func(o: Dictionary) -> bool: return o["wave"] == "d0_w0")
	eq(held.size(), 0, "a 6-unit group is held with 2 places under the cap (half rule)")
	check(s.orders.size() == 1 and s.orders[0]["reason"] == "patrol", "the cap sent a 2-unit patrol instead (%s)" % str(s.orders))
	s.alive = [21, 0]
	var s2 := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 24})
	s2.sizes["d0_w0"] = 6
	s2.alive = [21, 0]          # room 3 = half: released, max_units 3 (the rest follows up)
	s2.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 30.0)
	if check(not s2.orders.is_empty() and s2.orders[0]["wave"] == "d0_w0", "released with room for half the group"):
		eq(int(s2.orders[0]["max_units"]), 3, "max_units = the room")
	var s3 := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 24})
	s3.alive = [23, 0]          # room 1: no 1-unit release of a bigger group, no 2-unit patrol
	s3.step(int(25.0 / DT))
	eq(s3.orders.size(), 0, "room 1: never a 1-unit release (%s)" % str(s3.orders))
	# Idle garrison does not count: alive 30 (hard ceiling 36) but only 6 in play.
	var s4 := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 24})
	s4.alive = [30, 0]
	s4.active = [6, 0]
	s4.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 30.0)
	if check(not s4.orders.is_empty(), "idle garrison far from the crew does not starve reinforcements"):
		eq(int(s4.orders[0]["max_units"]), 4, "room from the alive ceiling (36 - 30 = 6) covers the group of 4")
	var s5 := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 24})
	s5.alive = [35, 0]
	s5.active = [6, 0]
	s5.step(int(25.0 / DT))
	eq(s5.orders.size(), 0, "the hard alive ceiling still holds (35 of 36)")


## Audit 2026-11 (finding 4): the by-crew tables are only defaults; an explicit "deck_cap" / "defend_every" wins for
## every crew size, as a number or as a per-crew array (before the fix an array was stored as-is and broke the caps; the
## dead scalar DECK_CAP / DEFEND_EVERY constants are gone).
func _overrides() -> void:
	for n in [1, 2, 3, 4]:
		var d := PacingDirector.make(_plan(), {"deck_cap": 9, "defend_every": 12.0}, n)
		eq(int(d.options["deck_cap"]), 9, "%d pilots: a scalar deck_cap override wins over the table" % n)
		near(float(d.options["defend_every"]), 12.0, 0.001, "%d pilots: a scalar defend_every override wins" % n)
		var arr := PacingDirector.make(_plan(), {"deck_cap": [10, 11, 12, 13], "defend_every": [50.0, 40.0, 33.0, 31.0]}, n)
		eq(arr.options["deck_cap"], [10, 11, 12, 13][n - 1], "%d pilots: an array deck_cap override is indexed by crew" % n)
		eq(arr.options["defend_every"], [50.0, 40.0, 33.0, 31.0][n - 1], "%d pilots: an array defend_every override too" % n)
		var plain := PacingDirector.make(_plan(), {}, n)
		eq(plain.options["deck_cap"], PacingDirector.DECK_CAP_BY_CREW[n - 1], "%d pilots: no override, the table" % n)
		eq(plain.options["defend_every"], PacingDirector.DEFEND_EVERY_BY_CREW[n - 1], "%d pilots: defend_every from its table" % n)
	check(not ("DECK_CAP" in PacingDirector.new().get_script().get_script_constant_map()), "no dead scalar DECK_CAP")
	check(not ("DEFEND_EVERY" in PacingDirector.new().get_script().get_script_constant_map()), "no dead scalar DEFEND_EVERY")
	# Behaviour: solo, a cap raised to 30 releases a 4-unit group with 20 in play (the solo table's 14 would hold it).
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "deck_cap": 30})
	s.alive = [20, 0]
	s.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 30.0)
	check(not s.orders.is_empty() and int(s.orders[0]["max_units"]) == 4, "the overridden cap is the one applied (%s)" % str(s.orders))
	var t := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0})
	t.alive = [20, 0]
	t.step(int(30.0 / DT))
	eq(t.orders.size(), 0, "without it the solo table (14) holds everything at 20 in play")
	# A defend override is the defend's clock.
	var dv := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0, "defend_every": 10.0})
	dv.step(4)
	dv.engaging = [10, 0]
	dv.objs["d0_b0"] = ["active", 0.0, 2.0]
	dv.step()
	dv.step(int(11.0 / DT))
	eq(dv.orders.size(), 2, "defend_every 10: the second defend group 10 s after the first")


## Review 2026-11-25: a crew member's mech freed while it is still listed (a hangar bot's controller freed before its
## PlayerTarget) must not raise in PacingFacts ("Left operand of 'is' is a previously freed instance" before the fix);
## the pilot counts as not standing, and the director ticks on with it.
func _freed_mech() -> void:
	var pf := PacingFacts.new()
	var pt := PlayerTarget.new()
	pt.target_id = "bot_a"
	var gone := Node3D.new()
	gone.free()
	var alive := Node3D.new()
	var pilots := [{"peer": -1, "target": pt, "mech": gone, "deck": 0, "downed": false},
		{"peer": 1, "target": null, "mech": alive, "deck": 0, "downed": false}]
	var got := pf.collect(pilots, null, [], 2)
	var bot: Dictionary = (got["pilots"] as Dictionary).get("-1", {})
	check(bool(bot.get("disabled", false)), "a pilot whose mech was freed counts as not standing (%s)" % str(bot))
	check(not bool(bot.get("engaged", true)), "and is never engaged")
	check(not bool(((got["pilots"] as Dictionary).get("1", {}) as Dictionary).get("disabled", true)), "the other pilot stands")
	var s := _solo(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0})
	var f := s.facts()
	f["pilots"] = got["pilots"]
	s.d.tick(s.t + DT, f)
	check(true, "the director ticks with it")
	alive.free()
	pt.free()


# --- Co-op ---------------------------------------------------------------------------------------------------------

func _scaling() -> void:
	var want_e := [6, 6, 10, 13]
	var want_p := [3, 4, 5, 6]
	for n in [1, 2, 3, 4]:
		var d := PacingDirector.make(_plan(), {}, n)
		eq(d.engage_target(), want_e[n - 1], "ENGAGE_TARGET x CREW_SCALE for %d pilots" % n)
		eq(d.patrol_allowance(), want_p[n - 1], "patrol allowance for %d pilots" % n)
	eq([PacingDirector.reserve_budget(9, 1), PacingDirector.reserve_budget(9, 2), PacingDirector.reserve_budget(9, 3),
		PacingDirector.reserve_budget(9, 4)], [14, 14, 22, 30], "reserve budget = solo budget x CREW_SCALE x RESERVE_SCALE")
	# 3+ pilots: consecutive quick releases come from two directions.
	var s := Sim.new(_plan(), {"rest_first": 0.5, "arrival_rest": 0.5, "build_gap": 1.0}, 3)
	s.pilots[1] = {"deck": 0, "x": 60.0, "s": 150.0}    # quick: gate_a 161 m, the ramp 240 m
	s.pilots[2] = {"deck": 0, "x": 60.0, "s": 160.0}
	s.pilots[-1] = {"deck": 0, "x": 60.0, "s": 140.0}
	s.until(func(x: Sim) -> bool: return x.orders.size() >= 2, 40.0)
	if check(s.orders.size() >= 2, "two build releases"):
		check(str(s.orders[0]["source"]) != str(s.orders[1]["source"]), "3 pilots: the second group from another source (%s, %s)"
			% [s.orders[0]["source"], s.orders[1]["source"]])


func _determinism() -> void:
	var a := _solo(_plan())
	var b := _solo(_plan())
	for i in int(200.0 / DT):
		if i == 120:
			a.objs["d0_p"] = ["active", 0.0, 20.0]
			b.objs["d0_p"] = ["active", 0.0, 20.0]
		if i == 300:
			a.pilots[1]["engaged"] = true
			b.pilots[1]["engaged"] = true
			a.pilots[1]["tot"] = 50.0
			b.pilots[1]["tot"] = 50.0
		a.step()
		b.step()
	eq(JSON.stringify(a.orders), JSON.stringify(b.orders), "the same facts give the same orders (%d)" % a.orders.size())
	eq(JSON.stringify(a.d.state()), JSON.stringify(b.d.state()), "and the same state")


## Pilot ids {1, 2, -1} (a hangar bot): intensity per pilot, mission.state through JSON (the wire), a client's mirror.
func _round_trip() -> void:
	var s := Sim.new(_plan(), {}, 3)
	s.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
	s.pilots[2] = {"deck": 0, "x": 10.0, "s": 150.0}
	s.pilots[-1] = {"deck": 0, "x": 5.0, "s": 160.0, "engaged": true}
	s.step(4)
	s.pilots[-1]["tot"] = 60.0
	s.step()
	near(s.d.intensity(-1), 40.0, 0.6, "the bot pilot's intensity (40 %% structure lost)")
	near(s.d.intensity(1), 0.0, 0.001, "pilot 1 untouched")
	var st := s.d.state()
	var wire: Variant = JSON.parse_string(JSON.stringify(st))
	var c := PacingDirector.make(_plan(), {}, 3)
	c.apply_state(wire)
	near(c.intensity(-1), s.d.intensity(-1), 0.6, "a client reads the bot's intensity (negative id survives JSON)")
	near(c.intensity("2"), 0.0, 0.001, "and pilot 2's")
	eq(c.pace_state(0), s.d.pace_state(0), "the client mirrors the deck's pace state")
	eq(str(c.state()["waves"]), str(st["waves"]), "wave counters round-trip")
	for key: String in st["intensity"]:
		eq(int(c.state()["intensity"].get(key, -999)), int(st["intensity"][key]), "intensity of pilot %s round-trips" % key)
	eq(c.waves_left_all(), s.d.waves_left_all(), "waves_left mirrors")
	var var_trip: Variant = bytes_to_var(var_to_bytes(st))
	var c2 := PacingDirector.make(_plan(), {}, 3)
	c2.apply_state(var_trip)
	near(c2.intensity(-1), s.d.intensity(-1), 0.6, "var_to_bytes round trip too")


## Ease off when a pilot leaves (user 2026-11-25; MissionFlow applies PacingDirector.rescale at the host's `at`): from 3
## to 2 pilots mid-mission the BY_CREW options, ENGAGE_TARGET and the allowances follow at once (used counts stay counted),
## a released group keeps the scale it was released at (its spawner definition and size), groups not released yet take
## the new one; a scale going back UP is applied the same way.
func _rescale() -> void:
	var s := Sim.new(_plan(), {"rest_first": 0.5, "arrival_rest": 0.5, "build_gap": 1.0}, 3)
	s.pilots[1] = {"deck": 0, "x": 60.0, "s": 150.0}
	s.pilots[2] = {"deck": 0, "x": 60.0, "s": 160.0}
	s.pilots[-1] = {"deck": 0, "x": 60.0, "s": 140.0}
	s.sizes["d0_w4"] = 9
	s.sizes["d0_w5"] = 9
	s.until(func(x: Sim) -> bool: return not x.orders.is_empty(), 30.0)
	if not check(not s.orders.is_empty(), "3 pilots: a build release before the rescale"):
		return
	var rel := str(s.orders[0]["wave"])
	eq(s.d.status(rel), "released", "group %s is released" % rel)
	var rel_def := s.d.group_def(rel)
	# Two patrols taken on deck 0 before the leave (the allowance's used count).
	var p1 := s.d._new_patrol(0)
	var p2 := s.d._new_patrol(0)
	check(not p1.is_empty() and not p2.is_empty(), "two patrols taken")
	eq(s.d.patrols_left(0), s.d.patrol_allowance() - 2, "3 pilots: allowance 5, 2 used, 3 left")
	s.d._scout_rel[0] = 3
	eq(int(s.d.group_def("d0_w4")["units"]), 0, "3 pilots: the defend group is not capped (plan size)")
	var old := s.d.rescale(2)
	eq(old, 3, "rescale returns the old scale")
	eq(s.d.crew_n, 2, "crew_n 2")
	eq(int(s.d.options["deck_cap"]), int(PacingDirector.DECK_CAP_BY_CREW[1]), "deck cap follows (16)")
	near(float(s.d.options["defend_every"]), float(PacingDirector.DEFEND_EVERY_BY_CREW[1]), 0.001, "defend cadence follows (38 s)")
	eq(s.d.engage_target(), 6, "ENGAGE_TARGET x CREW_SCALE[2 pilots]")
	eq(s.d.patrol_allowance(), 4, "patrol allowance 4")
	eq(s.d.patrols_left(0), 2, "patrols left = max(0, 4 - 2 used)")
	eq(s.d.patrols_left(1), 4, "an untouched deck gets the whole new allowance")
	eq(s.d.scout_budget(), 3, "scout budget 3 ...")
	check(s.d._scout_rel[0] >= s.d.scout_budget(), "... and 3 already used: no scout release left on deck 0")
	eq(s.d.hold_patrols(), 4, "hold patrols 4")
	eq(int(s.d.group_def("d0_w4")["units"]), int(PacingDirector.DEFEND_UNITS_MAX[1]), "an unreleased defend group takes the 2-pilot cap (5)")
	eq(s.d.release_crew(rel), 3, "the released group keeps the scale it was released at")
	eq(s.d.release_crew("d0_w2"), 2, "an unreleased group reads the new scale")
	eq(str(s.d.group_def(rel)), str(rel_def), "the released group's spawner definition is untouched")
	eq(s.d.release_crews(), {rel: 3}, "release_crews lists the released group at its scale")
	# Allowances never go negative.
	s.d._patrols[0] = 0
	s.d.rescale(1)
	eq(s.d.patrols_left(0), 0, "an allowance used up stays at 0 (max(0, 3 - 5 used))")
	# Up again (no mid-mission join exists; MissionFlow warns): applied the same way.
	eq(s.d.rescale(4), 1, "a rescale up is accepted")
	eq(int(s.d.options["deck_cap"]), int(PacingDirector.DECK_CAP_BY_CREW[3]), "deck cap 24 at 4 pilots")
	eq(s.d.rescale(4), 4, "the same scale again changes nothing")
	# An override keeps winning across a rescale.
	var o := PacingDirector.make(_plan(), {"deck_cap": [10, 11, 12, 13], "defend_every": 20.0}, 3)
	o.rescale(1)
	eq(int(o.options["deck_cap"]), 10, "an array override is re-indexed by the new scale")
	near(float(o.options["defend_every"]), 20.0, 0.001, "a number override stays")
	# A leaver's per-pilot entries go.
	s.d.forget_pilot(-1)
	check(not s.d.state()["intensity"].has("-1") and not s.d._int.has("-1") and not s.d._eng_t.has("-1"),
		"forget_pilot drops the leaver's intensity and engagement")


## A defend in progress when the crew shrinks 3 -> 1: its next group comes on the new cadence (counted from its last group)
## with the new size cap and the solo theme; the group already released keeps its own.
func _rescale_defend() -> void:
	var s := Sim.new(_plan(), {"rest_first": 1000.0, "arrival_rest": 1000.0, "quiet_cap": 1000.0}, 3)
	s.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
	s.sizes["d0_w4"] = 9
	s.sizes["d0_w5"] = 9
	s.step(4)
	s.engaging = [30, 0]   # build held off: only the defend's own clock releases
	s.objs["d0_b0"] = ["active", 0.0, 2.0]
	var o := s.step()
	if not check(o.size() == 1 and str(o[0]["wave"]) == "d0_w4", "3 pilots: the defend's first group at once (%s)" % str(o)):
		return
	var t0 := float(o[0]["t"])
	var first := s.d.group_def("d0_w4")
	s.step(int(10.0 / DT))
	s.d.rescale(1)
	s.until(func(x: Sim) -> bool: return x.orders.size() > 1, 60.0)
	if check(s.orders.size() == 2, "the second defend group comes"):
		near(float(s.orders[1]["t"]) - t0, float(PacingDirector.DEFEND_EVERY_BY_CREW[0]), 0.5,
			"on the solo cadence (45 s after the first, not 30)")
		var g5 := s.d.group_def("d0_w5")
		eq(int(g5["units"]), int(PacingDirector.DEFEND_UNITS_MAX[0]), "with the solo cap (4)")
		eq(str(g5["theme"]), "mixed", "and the solo theme")
		eq(int(s.orders[1]["max_units"]), int(PacingDirector.DEFEND_UNITS_MAX[0]), "the order holds 4 units of room")
	eq(str(s.d.group_def("d0_w4")), str(first), "the first group (released at 3) is unchanged")


## The same facts and the same rescale tick give the same orders and state.
func _rescale_determinism() -> void:
	var a := Sim.new(_plan(), {}, 3)
	var b := Sim.new(_plan(), {}, 3)
	for sm: Sim in [a, b]:
		sm.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
		sm.pilots[2] = {"deck": 0, "x": 10.0, "s": 150.0}
	for i in int(160.0 / DT):
		if i == 200:
			for sm: Sim in [a, b]:
				sm.d.rescale(2)
				sm.pilots.erase(2)
				sm.d.forget_pilot(2)
		if i == 300:
			a.objs["d0_p"] = ["active", 0.0, 20.0]
			b.objs["d0_p"] = ["active", 0.0, 20.0]
		a.step()
		b.step()
	eq(JSON.stringify(a.orders), JSON.stringify(b.orders), "a rescale mid-run: the same orders (%d)" % a.orders.size())
	eq(JSON.stringify(a.d.state()), JSON.stringify(b.d.state()), "and the same state")


## State round trip with the scale: the host's director rescaled, its state() through JSON to a client's director that
## applied the same mission.scale: the mirror and the scale-dependent reads agree.
func _rescale_round_trip() -> void:
	var s := Sim.new(_plan(), {}, 3)
	s.pilots[1] = {"deck": 0, "x": 0.0, "s": 150.0}
	s.pilots[-1] = {"deck": 0, "x": 5.0, "s": 160.0, "engaged": true}
	s.step(8)
	s.d.rescale(2)
	s.step(4)
	var c := PacingDirector.make(_plan(), {}, 3)
	c.rescale(2)   # the client applies the same change at the same `at`
	c.apply_state(JSON.parse_string(JSON.stringify(s.d.state())))
	eq(c.crew_n, s.d.crew_n, "crew_n agrees")
	eq(int(c.options["deck_cap"]), int(s.d.options["deck_cap"]), "deck cap agrees")
	eq(c.engage_target(), s.d.engage_target(), "ENGAGE_TARGET agrees")
	eq(str(c.state()["waves"]), str(s.d.state()["waves"]), "wave counters round-trip")
	eq(c.waves_left_all(), s.d.waves_left_all(), "waves_left mirrors")
	near(c.intensity(-1), s.d.intensity(-1), 0.6, "the bot's intensity round-trips")


## A bonus flag's group is lent to build / the cap once the free groups are gone; the flag, started later, still gets one.
func _borrow() -> void:
	var p := _plan()
	p.objectives.append(_obj("d0_b1", "flag", 0, "bonus", -60.0, 250.0, {"hold": 20.0}))
	(p.pools[0]["reserve"] as Array).append(_g("d0_w6", 0.2, "heavy", "d0_b1"))
	var s := _solo(p, {"rest_first": 0.5, "arrival_rest": 0.5, "build_gap": 1.0})
	s.objs["d0_p"] = ["done", 20.0, 20.0]
	s.objs["d0_b0"] = ["hidden", 0.0, 2.0]
	s.objs["d0_b1"] = ["known", 0.0, 20.0]
	s.until(func(x: Sim) -> bool: return x.orders.filter(func(o: Dictionary) -> bool: return o["wave"] == "d0_w6").size() > 0, 120.0)
	var lent: Array = s.orders.filter(func(o: Dictionary) -> bool: return o["wave"] == "d0_w6")
	if check(not lent.is_empty(), "the unstarted bonus flag's group is released once the free groups are gone"):
		check(str(lent[0]["reason"]) != "objective", "as a build / cap release (%s)" % lent[0]["reason"])
		var frees: Array = s.orders.filter(func(o: Dictionary) -> bool: return o["wave"] in ["d0_w0", "d0_w1", "d0_w2"])
		eq(frees.size(), 3, "after every free group")
	var n := s.orders.size()
	s.objs["d0_b1"] = ["active", 0.0, 20.0]
	var o := s.step()
	check(o.size() >= 1 and str(o[0]["reason"]) == "objective", "the flag, started later, still brings a group (%s)" % str(o))
	check(s.orders.size() > n, "ordered at its start")


## Defend balance (2026-11-24): the interval, the group cap and the solo themes by crew size; free build releases are held
## during a defend for 1-2 pilots (its own clock is the pressure), kept for 3+.
func _defend_by_crew() -> void:
	for n in [1, 2, 3, 4]:
		var s := Sim.new(_plan(), {"rest_first": 0.5, "arrival_rest": 0.5}, n)
		s.sizes["d0_w4"] = 9
		s.sizes["d0_w5"] = 9
		near(float(s.d.options["defend_every"]), float(PacingDirector.DEFEND_EVERY_BY_CREW[n - 1]), 0.001,
			"%d pilots: a defend group every %.0f s" % [n, float(PacingDirector.DEFEND_EVERY_BY_CREW[n - 1])])
		var cap := int(PacingDirector.DEFEND_UNITS_MAX[n - 1])
		s.step()
		var g4 := s.d.group_def("d0_w4")
		var g5 := s.d.group_def("d0_w5")
		eq(int(g4["units"]), cap if cap > 0 else 0, "%d pilots: defend group units %s" % [n, "capped at %d" % cap if cap > 0 else "as planned"])
		if n == 1:
			eq([str(g4["theme"]), str(g5["theme"])], ["light", "mixed"], "solo: the defend's groups come light, then mixed")
		else:
			eq([str(g4["theme"]), str(g5["theme"])], ["heavy", "heavy"], "%d pilots: the plan's themes" % n)
		check(str(s.d.group_def("d0_w0")["theme"]) == "light" and int(s.d.group_def("d0_w0")["units"]) == 0,
			"free groups untouched")
		# Build during an active defend.
		s.pilots[1] = {"deck": 0, "x": 60.0, "s": 150.0}
		s.objs["d0_b0"] = ["active", 0.0, 2.0]
		s.step(int(20.0 / DT))
		var builds: Array = s.orders.filter(func(o: Dictionary) -> bool: return o["reason"] == "build")
		if n < PacingDirector.DEFEND_BUILD_MIN_CREW:
			eq(builds.size(), 0, "%d pilots: no free build release during the defend (%s)" % [n, str(s.orders)])
		else:
			check(builds.size() >= 1, "%d pilots: build keeps releasing during the defend" % n)
