extends TestCase
## WaveDirector (docs/design/mission-objectives.md §5.2-§5.5, §9) on scripted timelines over a hand-made plan: nothing
## before a trigger, garrison_low, spacing + lull (shorter deeper), deck and section caps, crew-deck priority, partial
## release follow-ups (wave_pending), objective triggers, cancelling (objective done / failed, linger after the primary),
## linger, closed sources (re-route / cancel), open_at = t + telegraph (never under MIN_LEAD), termination over real
## plans, the state round trip. Then the end-to-end proof: MissionPlan + MissionRules + WaveDirector driven by a fake
## world over 3-deck sections reach "won" within a bounded simulated time.

const TEST_TIMEOUT := 240

var mid_sweeps := 0


func _init() -> void:
	timeout_sec = 220.0


func setup() -> void:
	_nothing_before_trigger()
	_garrison_and_spacing()
	_lull_by_depth()
	_caps()
	_crew_priority()
	_follow_up()
	_objective_trigger()
	_cancel()
	_linger()
	_closed()
	_min_lead()
	_termination()
	_round_trip()
	_garrison_waves_in_turn()
	_sweep_not_held_by_linger()
	_door_window()
	_defend_first()
	_alarm_expiry()
	_source_choice()
	_stall()
	_reservation()
	_end_to_end()
	finish()


# --- A hand-made plan ------------------------------------------------------------------------------------

func _src(id: String, k: int, kind: String, x: float, s: float) -> Dictionary:
	return {"id": id, "deck": k, "kind": kind, "x": x, "s": s, "toward": {"x": x, "s": s + 20.0}, "load": 6,
			"connector": -1, "edge": ""}


func _wave(id: String, source: String, trigger: Dictionary) -> Dictionary:
	return {"id": id, "share": 0.2, "theme": "light", "source": source, "trigger": trigger}


func _fake_plan() -> MissionPlan:
	var mp := MissionPlan.new()
	mp.deck_count = 3
	mp.sources = [
		_src("d0_gate_a", 0, "gate", 0.0, 200.0), _src("d0_gate_b", 0, "gate", 40.0, 200.0),
		_src("d0_lift", 0, "lift", 100.0, 0.0), _src("d0_ramp", 0, "ramp", -100.0, 0.0),
		_src("d1_shaft", 1, "shaft", 0.0, 0.0), _src("d1_ramp", 1, "ramp", 50.0, 0.0),
		_src("d2_gate", 2, "gate", 0.0, 0.0),
	]
	var site := {"x": 0.0, "s": 150.0}
	mp.objectives = [
		{"id": "d0_p", "type": "flag", "deck": 0, "role": "primary", "site": site, "radius": 14.0, "needs": [],
			"params": {"hold": 20.0}},
		{"id": "d0_b0", "type": "defend", "deck": 0, "role": "bonus", "site": site, "radius": 30.0, "needs": ["d0_p"],
			"params": {"waves": 2, "asset_hp": 1.0}},
		{"id": "d1_p", "type": "sweep", "deck": 1, "role": "primary", "site": {"x": 0.0, "s": 0.0}, "radius": 0.0,
			"needs": [], "params": {}},
		{"id": "d2_p", "type": "sweep", "deck": 2, "role": "primary", "site": {"x": 0.0, "s": 0.0}, "radius": 0.0,
			"needs": [], "params": {}},
		{"id": "hold", "type": "hold", "deck": 2, "role": "primary", "site": {"x": 0.0, "s": 0.0}, "radius": 0.0,
			"needs": ["d0_p", "d1_p", "d2_p"], "params": {"hold": 60.0, "zone": Rect2(-10, -10, 20, 20)}},
	]
	var gl := {"kind": "garrison_low"}
	mp.pools = [
		{"deck": 0, "garrison": 0.5, "waves": [
			_wave("d0_w0", "d0_gate_a", gl), _wave("d0_w1", "d0_gate_a", gl),
			_wave("d0_w2", "d0_ramp", {"kind": "linger", "after": 100.0}),
			_wave("d0_w3", "d0_lift", {"kind": "objective", "id": "d0_p", "step": "done"}),
			_wave("d0_w4", "d0_gate_a", {"kind": "objective", "id": "d0_b0", "step": "start"}),
			_wave("d0_w5", "d0_gate_a", {"kind": "objective", "id": "d0_b0", "step": "start"})]},
		{"deck": 1, "garrison": 0.5, "waves": [_wave("d1_w0", "d1_shaft", gl), _wave("d1_w1", "d1_ramp", gl)]},
		{"deck": 2, "garrison": 0.5, "waves": [_wave("d2_w0", "d2_gate", gl),
			_wave("d2_w1", "d2_gate", {"kind": "objective", "id": "hold", "step": "start"})]},
	]
	return mp


func _f(alive: Array, garrison: Array, crew: Array, more: Dictionary = {}) -> Dictionary:
	var d := {"alive": alive, "garrison_alive": garrison, "crew_deck": crew}
	d.merge(more, true)
	return d


func _objs(states: Dictionary) -> Dictionary:
	var o := {}
	for id: String in states:
		o[id] = [states[id], 0.0, 0.0]
	return {"objs": o}


## Every order is well formed and its door opens t + the source kind's telegraph later.
func _orders_ok(d: WaveDirector, t: float, orders: Array, tag: String) -> void:
	for o: Dictionary in orders:
		for key in ["wave", "deck", "source", "open_at", "max_units"]:
			check(o.has(key), tag + ": order has " + key)
		var src := d.plan.source(o["source"])
		check(not src.is_empty() and int(src["deck"]) == int(o["deck"]), tag + ": order source on its deck")
		var tg := maxf(float(d.options["telegraph"][src["kind"]]), WaveDirector.MIN_LEAD)
		near(float(o["open_at"]) - t, tg, 0.0001, tag + ": open_at = t + telegraph (%s)" % src["kind"])
		check(float(o["open_at"]) - t >= WaveDirector.MIN_LEAD - 0.0001, tag + ": lead >= MIN_LEAD")
		check(int(o["max_units"]) > 0, tag + ": max_units > 0")


func _tick(d: WaveDirector, t: float, facts: Dictionary, tag: String) -> Array:
	var o := d.tick(t, facts)
	_orders_ok(d, t, o, tag)
	return o


# --- Scripted cases --------------------------------------------------------------------------------------

func _nothing_before_trigger() -> void:
	var d := WaveDirector.make(_fake_plan())
	for t in range(0, 300, 5):
		eq(_tick(d, float(t), _f([10, 10, 10], [10, 10, 10], [0, 1, 2]), "quiet").size(), 0, "no trigger at t %d: no order" % t)
		if t >= 95:
			break
	var e := WaveDirector.make(_fake_plan())
	eq(e.tick(0.0, {}).size(), 0, "empty facts: no order")
	eq(e.tick(500.0, {"objectives": {}}).size(), 0, "no crew ever, no objective: no order")
	eq(e.waves_left_all(), [2, 2, 1], "garrison_low waves are owed; linger and untriggered objective waves are not")


func _garrison_and_spacing() -> void:
	var d := WaveDirector.make(_fake_plan())
	var al := [2, 10, 10]
	eq(_tick(d, 0.0, _f(al, [10, 10, 10], [0]), "g").size(), 0, "t 0: nothing")
	eq(_tick(d, 10.0, _f(al, [3, 10, 10], [0]), "g").size(), 0, "garrison 3 / 10: above the threshold")
	var o := _tick(d, 20.0, _f(al, [2, 10, 10], [0]), "g")
	if eq(o.size(), 1, "garrison 2 / 10 (<= 25 %): one wave"):
		eq(o[0]["wave"], "d0_w0", "the first free wave")
		eq(o[0]["source"], "d0_gate_a", "its source")
		near(float(o[0]["open_at"]), 25.0, 0.001, "gate telegraph 5 s")
		eq(int(o[0]["max_units"]), mini(24 - 2, 40 - 22), "max_units = min(deck room, section room)")
	eq(d.status("d0_w1"), "due", "the second garrison wave is due too")
	eq(_tick(d, 22.0, _f(al, [2, 10, 10], [0]), "g").size(), 0, "one wave arriving at a time")
	var wa := {"wave_alive": {"d0_w0": {"alive": 4, "total": 4}}}
	eq(_tick(d, 26.0, _f(al, [2, 10, 10], [0], wa), "g").size(), 0, "fresh wave: no second wave")
	wa = {"wave_alive": {"d0_w0": {"alive": 2, "total": 4}}}
	eq(_tick(d, 28.0, _f(al, [2, 10, 10], [0], wa), "g").size(), 0, "half alive: not mostly beaten")
	wa = {"wave_alive": {"d0_w0": {"alive": 1, "total": 4}}}
	eq(_tick(d, 30.0, _f(al, [2, 10, 10], [0], wa), "g").size(), 0, "mostly beaten at 30: lull starts")
	eq(_tick(d, 54.9, _f(al, [2, 10, 10], [0], wa), "g").size(), 0, "inside the 25 s lull")
	o = _tick(d, 55.0, _f(al, [2, 10, 10], [0], wa), "g")
	check(o.size() == 1 and o[0]["wave"] == "d0_w1", "the second wave after mostly beaten + lull")
	eq(d.state()["waves"][0], [2, 6], "state: 2 of 6 released on deck 0")
	eq(d.waves_left(0), 1, "waves left on deck 0: the second wave, behind its door (the queued linger wave is not owed)")
	_tick(d, 61.0, _f(al, [2, 10, 10], [0], {"wave_alive": {"d0_w0": {"alive": 1, "total": 4}, "d0_w1": {"alive": 4, "total": 4}}}), "g")
	eq(d.waves_left(0), 0, "waves left on deck 0: none once its units are reported")


func _lull_by_depth() -> void:
	var d := WaveDirector.make(_fake_plan())
	near(d.lull(0), 25.0, 0.001, "lull deck 0")
	near(d.lull(1), 20.0, 0.001, "lull deck 1")
	near(d.lull(2), 15.0, 0.001, "lull on the lowest deck")
	# Deck 1 scripted: first wave beaten at 10, second wave at 30 (20 s lull), not at 29.
	var x := WaveDirector.make(_fake_plan())
	_tick(x, 0.0, _f([0, 0, 0], [10, 0, 10], [1]), "l")
	var wa := {"wave_alive": {"d1_w0": {"alive": 0, "total": 3}}}
	eq(_tick(x, 10.0, _f([0, 0, 0], [10, 0, 10], [1], wa), "l").size(), 0, "deck 1: beaten at 10")
	eq(_tick(x, 29.9, _f([0, 0, 0], [10, 0, 10], [1], wa), "l").size(), 0, "deck 1: inside its 20 s lull")
	eq(_tick(x, 30.0, _f([0, 0, 0], [10, 0, 10], [1], wa), "l").size(), 1, "deck 1: second wave after 20 s")
	var bigger := WaveDirector.make(_fake_plan(), {"lull": 40.0, "lull_min": 30.0})
	near(bigger.lull(0), 40.0, 0.001, "lull override")
	near(bigger.lull(2), 30.0, 0.001, "lull_min override")


func _caps() -> void:
	var d := WaveDirector.make(_fake_plan())
	_tick(d, 0.0, _f([24, 0, 0], [0, 10, 10], [0]), "c")
	eq(d.status("d0_w0"), "due", "deck cap: the wave is due")
	eq(_tick(d, 1.0, _f([24, 0, 0], [0, 10, 10], [0]), "c").size(), 0, "deck cap 24 reached: queued")
	var o := _tick(d, 2.0, _f([20, 0, 0], [0, 10, 10], [0]), "c")
	check(o.size() == 1 and int(o[0]["max_units"]) == 4, "room for 4: released with max_units 4 (%s)" % [o])
	var s := WaveDirector.make(_fake_plan())
	eq(_tick(s, 0.0, _f([10, 20, 10], [0, 10, 10], [0]), "c").size(), 0, "section cap 40 reached: queued")
	o = _tick(s, 1.0, _f([10, 20, 5], [0, 10, 10], [0]), "c")
	check(o.size() == 1 and int(o[0]["max_units"]) == 5, "section room 5: max_units 5 (%s)" % [o])
	# Units ordered but not spawned yet count against the caps.
	var r := WaveDirector.make(_fake_plan())
	_tick(r, 0.0, _f([0, 0, 0], [10, 10, 10], [0, 1]), "c")
	var ws := {"wave_size": {"d0_w0": 12}}     # a wave expected at 12 units holds all 10 it was given
	o = _tick(r, 1.0, _f([0, 0, 30], [0, 10, 10], [0, 1], ws), "c")
	check(o.size() == 1 and int(o[0]["max_units"]) == 10, "deck 0 takes the section's 10")
	o = _tick(r, 2.0, _f([0, 0, 30], [0, 0, 10], [0, 1], ws), "c")
	eq(o.size(), 0, "deck 1 waits: the 10 in flight fill the section")
	var small := WaveDirector.make(_fake_plan(), {"deck_cap": 5, "section_cap": 7})
	o = _tick(small, 0.0, _f([1, 0, 0], [0, 10, 10], [0]), "c")
	check(o.size() == 1 and int(o[0]["max_units"]) == 4, "cap overrides (%s)" % [o])


func _crew_priority() -> void:
	var d := WaveDirector.make(_fake_plan())
	_tick(d, 0.0, _f([0, 0, 35], [10, 10, 10], [0, 1]), "p")
	var o := _tick(d, 1.0, _f([0, 0, 35], [0, 0, 10], [1]), "p")
	if eq(o.size(), 1, "section room 5, two decks due: one order"):
		eq(int(o[0]["deck"]), 1, "the crew's deck goes first")
		eq(int(o[0]["max_units"]), 5, "with the section's room")
	eq(d.status("d0_w0"), "due", "deck 0 stays queued")
	# Without the crew there, deck order would have served deck 0.
	var e := WaveDirector.make(_fake_plan())
	_tick(e, 0.0, _f([0, 0, 35], [10, 10, 10], [0, 1]), "p")
	o = _tick(e, 1.0, _f([0, 0, 35], [0, 0, 10], [0]), "p")
	check(o.size() == 1 and int(o[0]["deck"]) == 0, "crew on deck 0: deck 0 first")
	# A crew deck held by the section cap holds the other decks too.
	var h := WaveDirector.make(_fake_plan())
	_tick(h, 0.0, _f([0, 0, 0], [10, 10, 10], [0, 1]), "p")
	o = _tick(h, 1.0, _f([0, 0, 40], [0, 0, 10], [1]), "p")
	eq(o.size(), 0, "section full: nobody")


func _follow_up() -> void:
	var d := WaveDirector.make(_fake_plan())
	var o := _tick(d, 0.0, _f([21, 0, 0], [0, 10, 10], [0]), "f")
	check(o.size() == 1 and int(o[0]["max_units"]) == 3, "partial room: 3 units")
	var more := {"wave_alive": {"d0_w0": {"alive": 3, "total": 3}}, "wave_pending": {"d0_w0": 2}}
	eq(_tick(d, 5.0, _f([24, 0, 0], [0, 10, 10], [0], more), "f").size(), 0, "no room, and too soon")
	eq(d.waves_left(0), 2, "a released wave with units pending still counts as left (+ the due one)")
	o = _tick(d, 8.0, _f([22, 0, 0], [0, 10, 10], [0], more), "f")
	if eq(o.size(), 1, "room again: a follow-up order"):
		eq(o[0]["wave"], "d0_w0", "for the same wave")
		eq(o[0]["source"], "d0_gate_a", "from the same source")
		near(float(o[0]["open_at"]), 13.0, 0.001, "new open_at")
		eq(int(o[0]["max_units"]), 2, "the rest of the wave")
	eq(_tick(d, 9.0, _f([0, 0, 0], [0, 10, 10], [0], more), "f").size(), 0, "no duplicate follow-up, no next wave")
	more = {"wave_alive": {"d0_w0": {"alive": 1, "total": 5}}, "wave_pending": {"d0_w0": 0}}
	eq(_tick(d, 16.0, _f([0, 0, 0], [0, 10, 10], [0], more), "f").size(), 0, "all spawned, mostly beaten at 16")
	o = _tick(d, 41.0, _f([0, 0, 0], [0, 10, 10], [0], more), "f")
	check(o.size() == 1 and o[0]["wave"] == "d0_w1", "next wave after the lull")


func _objective_trigger() -> void:
	var d := WaveDirector.make(_fake_plan())
	eq(_tick(d, 0.0, {"objectives": _objs({"d0_p": "known"})}, "o").size(), 0, "known is not started")
	eq(_tick(d, 1.0, {"objectives": _objs({"d0_p": "active"})}, "o").size(), 0, "a flag being raised: no wave yet")
	var o := _tick(d, 2.0, {"objectives": _objs({"d0_p": "done"}), "crew_deck": [0]}, "o")
	if eq(o.size(), 1, "flag raised with a mech on its deck: its alarm wave"):
		eq(o[0]["wave"], "d0_w3", "the flag's wave")
		near(float(o[0]["open_at"]), 7.0, 0.001, "lift telegraph 5 s")
	eq(d.status("d0_w3"), "released", "the flag's done-wave is not cancelled by the flag being done")
	eq(d.status("d0_w0"), "queued", "free waves still wait for their trigger")
	# A step "start" trigger (a defend) fires on start.
	var e := WaveDirector.make(_fake_plan())
	o = _tick(e, 0.0, {"objectives": _objs({"d0_b0": "active"})}, "o")
	check(o.size() == 1 and o[0]["wave"] == "d0_w4", "step start: the defend's first wave on start")
	# The flag's done-wave waits its turn behind a fresh wave (not cancelled); the active defend's next wave goes
	# before it after mostly beaten + lull (active defend first).
	o = _tick(e, 1.0, {"objectives": _objs({"d0_p": "done", "d0_b0": "active"}), "crew_deck": [0]}, "o")
	eq(o.size(), 0, "flag done while the defend's wave is arriving: queued")
	eq(e.status("d0_w3"), "due", "the flag's wave is due, not cancelled")
	var wa := {"objectives": _objs({"d0_p": "done", "d0_b0": "active"}), "crew_deck": [0],
			"wave_alive": {"d0_w4": {"alive": 0, "total": 3}}}
	eq(_tick(e, 6.0, wa, "o").size(), 0, "defend wave beaten at 6: lull")
	eq(_tick(e, 30.9, wa, "o").size(), 0, "inside the lull")
	o = _tick(e, 31.0, wa, "o")
	check(o.size() == 1 and o[0]["wave"] == "d0_w5", "after the lull: the active defend's next wave first (%s)" % [o])
	eq(e.status("d0_w3"), "due", "the flag's wave waits its turn behind it")


func _cancel() -> void:
	for end: String in ["done", "failed"]:
		var d := WaveDirector.make(_fake_plan())
		_tick(d, 0.0, {"objectives": _objs({"d0_p": "active"}), "crew_deck": [0]}, "x")
		_tick(d, 1.0, {"objectives": _objs({"d0_p": "done", "d0_b0": "active"}), "crew_deck": [0]}, "x")
		eq(d.status("d0_w4"), "released", "the active defend's first wave goes out first")
		eq(d.status("d0_w3"), "due", "the flag's done-wave is due behind it")
		eq(d.status("d0_w5"), "due", "the defend's second wave is due")
		eq(d.status("d0_w2"), "cancelled", "the primary is done: its deck's linger wave is cancelled")
		eq(d.waves_left(0), 5, "due waves are owed (alarm, defend wave 2), the one behind its door, the two garrison waves")
		_tick(d, 2.0, {"objectives": _objs({"d0_p": "done", "d0_b0": end}), "crew_deck": [0]}, "x")
		eq(d.status("d0_w4"), "released", "defend %s: its released wave stays released" % end)
		eq(d.status("d0_w5"), "cancelled", "defend %s: its unreleased wave is cancelled" % end)
		eq(d.status("d0_w3"), "due", "defend %s: the flag's alarm is not cancelled" % end)
		eq(d.state()["waves"][0], [1, 4], "cancelled waves leave the total")
		var ow := d.objective_waves()
		eq(ow["d0_b0"]["total"], 1, "objective_waves after the cancel: only the released wave")


func _linger() -> void:
	var d := WaveDirector.make(_fake_plan())
	_tick(d, 0.0, _f([5, 0, 0], [10, 10, 10], [0]), "g")
	eq(_tick(d, 99.0, _f([5, 0, 0], [10, 10, 10], [0]), "g").size(), 0, "linger: not before 100 s")
	var o := _tick(d, 100.0, _f([5, 0, 0], [10, 10, 10], [0]), "g")
	check(o.size() == 1 and o[0]["wave"] == "d0_w2", "linger fires 100 s after the crew arrived (%s)" % [o])
	var c := WaveDirector.make(_fake_plan())
	_tick(c, 0.0, _f([5, 0, 0], [10, 10, 10], [0]), "g")
	_tick(c, 50.0, _f([5, 0, 0], [10, 10, 10], [0], {"objectives": _objs({"d0_p": "done"})}), "g")
	eq(c.status("d0_w2"), "cancelled", "primary done: the linger wave is cancelled")
	eq(c.status("d0_w3"), "released", "while the flag's alarm wave goes out")
	eq(_tick(c, 100.0, _f([5, 0, 0], [10, 10, 10], [0]), "g").size(), 0, "no linger wave after")
	# Rule 5: garrison all dead, nothing alive from waves: the next free wave (here the linger) comes early.
	var r := WaveDirector.make(_fake_plan())
	_tick(r, 0.0, _f([0, 0, 0], [10, 10, 10], [0]), "g")
	var gone := _f([0, 0, 0], [0, 10, 10], [0], {"wave_alive": {"d0_w0": {"alive": 0, "total": 3},
			"d0_w1": {"alive": 0, "total": 3}}})
	_tick(r, 1.0, gone, "g")
	_tick(r, 7.0, gone, "g")
	_tick(r, 32.0, gone, "g")
	eq(r.status("d0_w1"), "released", "both garrison waves out")
	_tick(r, 38.0, gone, "g")
	eq(r.status("d0_w2"), "due", "garrison gone and waves dead: the linger wave is due early")
	var o2 := _tick(r, 63.0, gone, "g")
	check(o2.size() == 1 and o2[0]["wave"] == "d0_w2", "and comes after the lull")
	eq(r.waves_left_all(), [1, 2, 1], "deck 0: the linger wave is behind its door")
	gone["wave_alive"]["d0_w2"] = {"alive": 0, "total": 3}
	_tick(r, 67.0, gone, "g")
	eq(r.waves_left_all(), [0, 2, 1], "deck 0 owes nothing more (objective waves untriggered)")


func _closed() -> void:
	var d := WaveDirector.make(_fake_plan())
	var o := _tick(d, 0.0, _f([0, 0, 0], [0, 0, 10], [0, 1], {"closed": ["d0_gate_a", "d1_shaft", "d1_ramp"]}), "z")
	var by := {}
	for x: Dictionary in o:
		by[x["deck"]] = x
	check(by.has(0) and by[0]["source"] == "d0_gate_b", "closed gate: re-routed to the nearest open source (%s)" % [o])
	eq(d.source_of("d0_w1"), "d0_gate_b", "queued waves re-route too")
	check(not by.has(1), "deck 1 all closed: nothing")
	eq(d.status("d1_w0"), "cancelled", "deck 1: cancelled")
	eq(d.status("d1_w1"), "cancelled", "deck 1: both")
	eq(d.waves_left(1), 0, "a deck with every door closed owes nothing")


func _min_lead() -> void:
	var d := WaveDirector.make(_fake_plan(), {"telegraph": {"gate": 0.0, "ramp": 0.2}})
	near(float(d.options["telegraph"]["gate"]), 1.0, 0.0001, "telegraph clamped to MIN_LEAD")
	near(float(d.options["telegraph"]["lift"]), 5.0, 0.0001, "unnamed kinds keep their default")
	var o := _tick(d, 10.0, _f([0, 0, 0], [0, 10, 10], [0]), "m")
	check(o.size() == 1 and absf(float(o[0]["open_at"]) - 11.0) < 0.0001, "open_at >= t + 1 s (%s)" % [o])


# --- Termination over real plans -------------------------------------------------------------------------

func _termination() -> void:
	for decks in [2, 3, 5]:
		for seed_ in range(1, 11):
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var mp := MissionPlan.make(sec)
			var d := WaveDirector.make(mp)
			var tag := "decks %d seed %d" % [decks, seed_]
			var all_active := {}
			for ob: Dictionary in mp.objectives:
				all_active[ob["id"]] = ["active", 0.0, 0.0]
			var crew: Array = range(decks)
			var spawned := {}
			var wanted := {}
			var open := {}
			var zeros: Array = []
			zeros.resize(decks)
			zeros.fill(0)
			var t := 0.0
			while t < 3000.0:
				if t == 1500.0:     # the flags are raised late, so every other wave (lingers too) is out first
					for ob: Dictionary in mp.objectives:
						if ob["type"] == "flag":
							all_active[ob["id"]] = ["done", 20.0, 20.0]
				var wa := {}
				var pending := {}
				for id: String in open:
					if t >= float(open[id][0]) and not bool(open[id][2]):
						spawned[id] = int(spawned.get(id, 0)) + int(open[id][1])
						open[id][2] = true
				for id: String in spawned:
					wa[id] = {"alive": 0, "total": spawned[id]}     # killed as they arrive
					pending[id] = maxi(int(wanted[id]) - int(spawned[id]), 0)
				var orders := _tick(d, t, {"alive": zeros, "garrison_alive": zeros, "crew_deck": crew,
						"objectives": {"objs": all_active}, "wave_alive": wa, "wave_pending": pending}, tag)
				for o: Dictionary in orders:
					var id: String = o["wave"]
					if not wanted.has(id):
						wanted[id] = 6
					open[id] = [o["open_at"], mini(int(o["max_units"]), int(wanted[id]) - int(spawned.get(id, 0))), false]
				t += 1.0
				if d.waves_left_all() == zeros and open.values().all(func(v: Array) -> bool: return v[2]):
					var unreleased := 0
					for w: Dictionary in d._waves:
						unreleased += 0 if w["status"] == "released" else 1
					if unreleased == 0:
						break
			eq(d.waves_left_all(), zeros, tag + ": every wave released and spawned (t %.0f)" % t)
			for w: Dictionary in d._waves:
				eq(w["status"], "released", tag + ": %s released" % w["id"])
			check(t < 3000.0, tag + ": terminates")


## §5.4 rule 5 on a sweep deck without any garrison facts: nothing alive -> the next garrison_low wave, one after the
## other with spacing + lull, until none is left; no timer involved.
func _garrison_waves_in_turn() -> void:
	var d := WaveDirector.make(_fake_plan())
	var o := _tick(d, 0.0, {"alive": [0, 0, 0], "crew_deck": [1]}, "q")
	check(o.size() == 1 and o[0]["wave"] == "d1_w0", "nothing alive, no garrison facts: the first garrison_low wave (%s)" % [o])
	var wa := {"alive": [0, 0, 0], "crew_deck": [1], "wave_alive": {"d1_w0": {"alive": 0, "total": 3}}}
	eq(_tick(d, 3.0, wa, "q").size(), 0, "beaten at 3: lull")
	eq(d.status("d1_w1"), "due", "the next garrison_low wave is due at once")
	eq(_tick(d, 22.9, wa, "q").size(), 0, "deck 1 lull 20 s")
	o = _tick(d, 23.0, wa, "q")
	check(o.size() == 1 and o[0]["wave"] == "d1_w1", "then the second")
	eq(d.waves_left(1), 1, "the second is owed while behind its door")
	wa["wave_alive"]["d1_w1"] = {"alive": 0, "total": 3}
	_tick(d, 27.0, wa, "q")
	eq(d.waves_left(1), 0, "none left")
	# Alive enemies (garrison not reported) hold rule 5 back.
	var h := WaveDirector.make(_fake_plan())
	eq(_tick(h, 0.0, {"alive": [0, 3, 0], "crew_deck": [1]}, "q").size(), 0, "enemies alive: no rule-5 wave")
	# The threshold having fired before does not matter: garrison reported, all due waves out, garrison 0.
	var g := WaveDirector.make(_fake_plan())
	_tick(g, 0.0, _f([0, 0, 0], [0, 10, 0], [1]), "q")
	eq(g.status("d1_w0"), "queued", "garrison 10 of 10: nothing")
	o = _tick(g, 1.0, _f([0, 0, 0], [0, 0, 0], [1]), "q")
	check(o.size() == 1 and o[0]["wave"] == "d1_w0", "garrison gone: first wave")


func _round_trip() -> void:
	var d := WaveDirector.make(_fake_plan())
	_tick(d, 0.0, _f([0, 0, 0], [0, 0, 10], [0, 1]), "r")
	var st := d.state()
	check(not (st["next"] as Dictionary).is_empty(), "next has the doors in flight")
	var via: Variant = JSON.parse_string(JSON.stringify(st))
	var c := WaveDirector.make(_fake_plan())
	c.apply_state(via)
	eq(c.state(), st, "JSON round trip reproduces state()")
	eq(c.waves_left(0), d.waves_left(0), "client: the host's waves left (state left)")
	eq(c.waves_left(0), 2, "client: the wave behind its door + the due one")
	var old := WaveDirector.make(_fake_plan())
	var st_old := st.duplicate()
	st_old.erase("left")
	old.apply_state(st_old)
	eq(old.waves_left(0), 5, "client, host without left: total - released")
	var c2 := WaveDirector.make(_fake_plan())
	c2.apply_state(bytes_to_var(var_to_bytes(st)))
	eq(c2.state(), st, "var_to_bytes round trip")
	check(JSON.stringify(st).length() < 200, "state() is small (%d bytes)" % JSON.stringify(st).length())
	var big := WaveDirector.make(MissionPlan.make(SectionPlan.make({"seed": 3.0, "decks": 5.0})))
	check(JSON.stringify(big.state()).length() < 200, "5-deck state() small")


# --- A sweep deck is not held by its free waves' timers --------------------------------------------------

## Seed 1, deck 1 (a sweep). The crew arrives at t 0 and stays; the garrison (8) dies by t 16; every wave unit dies 2 s
## after its door opens. The sweep must complete once the last free wave is out and dead (lulls + telegraphs), far
## under the 360 s linger timer. `with_garrison` false: the host never reports garrison_alive at all.
func _sweep_not_held_by_linger() -> void:
	for with_garrison in [true, false]:
		var sec := SectionPlan.make({"seed": 1.0})
		var mp := MissionPlan.make(sec)
		var tag := "sweep deck (garrison facts %s)" % with_garrison
		var k := 1
		if not check(mp.primary(k)["type"] == "sweep", tag + ": seed 1 deck 1 is a sweep"):
			return
		var rules := MissionRules.make(sec, {"plan": mp})
		var dir := WaveDirector.make(mp)
		var a := sec.arrival(k)
		var crew := [{"peer": 1, "downed": false, "deck": k, "x": float(a["x"]), "s": float(a["s"])}]
		var loads: Array = []
		var units: Array = []
		var spawned := {}
		var last_death := 0.0
		var t := 0.0
		var done_t := -1.0
		while t < 400.0 and done_t < 0.0:
			var gar := maxi(8 - int(t / 2.0), 0)
			if gar == 0 and last_death < 16.0:
				last_death = 16.0
			var rest: Array = []
			for ld: Array in loads:
				if t >= float(ld[0]):
					spawned[ld[1]] = int(spawned.get(ld[1], 0)) + int(ld[2])
					for i in int(ld[2]):
						units.append([ld[1], t + 2.0])
				else:
					rest.append(ld)
			loads = rest
			var before := units.size()
			units = units.filter(func(u: Array) -> bool: return t < float(u[1]))
			if units.size() < before:
				last_death = t
			var alive := [0, gar + units.size(), 0]
			var wa := {}
			for id: String in spawned:
				wa[id] = {"alive": 0, "total": spawned[id]}
			for u: Array in units:
				wa[u[0]]["alive"] += 1
			rules.evaluate({"t": t, "enemies": alive, "crew": crew, "waves_left": dir.waves_left_all()})
			if rules.obj_state(mp.primary(k)["id"]) == "done":
				done_t = t
				break
			var f := {"alive": alive, "crew_deck": [k], "objectives": rules.state(), "wave_alive": wa}
			if with_garrison:
				f["garrison_alive"] = [8, gar, 8]
			for o: Dictionary in dir.tick(t, f):
				loads.append([o["open_at"], o["wave"], mini(int(o["max_units"]), 4)])
			t += 0.5
		var slack := dir.lull(k) + 5.0 + 5.0
		print("%s: sweep done at t %.1f, last enemy died at %.1f, waves left %s" % [tag, done_t, last_death, dir.waves_left_all()])
		check(done_t >= 0.0 and done_t < 360.0, tag + ": the sweep completes long before the linger timer (%.1f)" % done_t)
		check(done_t >= 0.0 and done_t <= last_death + slack, tag + ": within lull + telegraph of the last death (%.1f vs %.1f)" % [done_t, last_death])


# --- Phase 1 verification gaps -----------------------------------------------------------------------------

## Gap 1: a released wave whose units have not been reported yet (door closed, or open and not yet seen) is still owed,
## until it reports or open_at + GRACE passes; the sweep is not done meanwhile; clients read the same count.
func _door_window() -> void:
	var d := WaveDirector.make(_fake_plan())
	var o := _tick(d, 0.0, {"alive": [0, 0, 0], "crew_deck": [2]}, "w")
	check(o.size() == 1 and o[0]["wave"] == "d2_w0", "deck 2: its garrison wave released (%s)" % [o])
	eq(d.waves_left(2), 1, "door closed: the released wave is still owed")
	_tick(d, 5.5, {"alive": [0, 0, 0], "crew_deck": [2]}, "w")
	eq(d.waves_left(2), 1, "door open, units not reported yet: still owed")
	var c := WaveDirector.make(_fake_plan())
	c.apply_state(JSON.parse_string(JSON.stringify(d.state())))
	eq(c.waves_left(2), d.waves_left(2), "client: the same count as the host in the door window")
	var sec := SectionPlan.make({"seed": 5.0, "decks": 3.0})
	var rules := MissionRules.make(sec, {"plan": d.plan})
	var crew := [{"peer": 1, "downed": false, "deck": 2, "x": 50.0, "s": 50.0}]
	rules.evaluate({"t": 5.5, "enemies": [0, 0, 0], "crew": crew, "waves_left": d.waves_left_all()})
	eq(rules.obj_state("d2_p"), "active", "the sweep is not done while its wave is behind the door")
	_tick(d, 6.0, {"alive": [0, 0, 3], "crew_deck": [2], "wave_alive": {"d2_w0": {"alive": 3, "total": 3}}}, "w")
	eq(d.waves_left(2), 0, "reported: no longer owed (its units count as enemies)")
	var g := WaveDirector.make(_fake_plan())
	_tick(g, 0.0, {"alive": [0, 0, 0], "crew_deck": [2]}, "w")
	_tick(g, 14.9, {"alive": [0, 0, 0], "crew_deck": [2]}, "w")
	eq(g.waves_left(2), 1, "never reported: owed until open_at + GRACE")
	_tick(g, 15.0, {"alive": [0, 0, 0], "crew_deck": [2]}, "w")
	eq(g.waves_left(2), 0, "never reported: not owed after open_at + GRACE (spawned nothing)")
	eq(int(g.objective_waves().get("hold", {}).get("alive", -1)), 0, "objective_waves agrees (no hold wave out)")


## Gap 2: a defend's first wave is released at once (caps allowing) even behind a fresh unrelated wave and in the lull;
## active defend waves go before a flag's alarm; the defend's next wave keeps spacing + lull after its own previous one.
func _defend_first() -> void:
	var d := WaveDirector.make(_fake_plan())
	var o := _tick(d, 0.0, _f([2, 10, 10], [0, 10, 10], [0]), "df")
	check(o.size() == 1 and o[0]["wave"] == "d0_w0", "an unrelated garrison wave goes out first")
	var ob := {"objectives": _objs({"d0_p": "done", "d0_b0": "active"})}
	ob["wave_alive"] = {"d0_w0": {"alive": 4, "total": 4}}
	o = _tick(d, 6.0, _f([6, 10, 10], [0, 10, 10], [0], ob), "df")
	check(o.size() == 1 and o[0]["wave"] == "d0_w4", "the defend's first wave at once, behind a fresh wave (%s)" % [o])
	eq(d.status("d0_w3"), "due", "the flag's alarm waits (defend first)")
	ob["wave_alive"] = {"d0_w0": {"alive": 4, "total": 4}, "d0_w4": {"alive": 0, "total": 3}}
	eq(_tick(d, 15.0, _f([6, 10, 10], [0, 10, 10], [0], ob), "df").size(), 0, "defend wave 1 beaten at 15: its lull")
	eq(_tick(d, 39.9, _f([6, 10, 10], [0, 10, 10], [0], ob), "df").size(), 0, "inside the defend's lull")
	o = _tick(d, 40.0, _f([6, 10, 10], [0, 10, 10], [0], ob), "df")
	check(o.size() == 1 and o[0]["wave"] == "d0_w5", "defend wave 2 after its own lull, unrelated wave still fresh (%s)" % [o])
	eq(d.status("d0_w3"), "due", "the alarm still waits")
	# Caps still apply.
	var c := WaveDirector.make(_fake_plan())
	eq(_tick(c, 0.0, _f([24, 0, 0], [10, 10, 10], [0], {"objectives": _objs({"d0_b0": "active"})}), "df").size(), 0,
			"deck full: the defend's first wave waits for room")
	o = _tick(c, 1.0, _f([21, 0, 0], [10, 10, 10], [0], {"objectives": _objs({"d0_b0": "active"})}), "df")
	check(o.size() == 1 and o[0]["wave"] == "d0_w4" and int(o[0]["max_units"]) == 3, "room for 3: released (%s)" % [o])
	# The hold's wave goes before an unrelated due wave and skips the deck's spacing.
	var h := WaveDirector.make(_fake_plan())
	o = _tick(h, 0.0, {"alive": [0, 0, 0], "crew_deck": [2]}, "df")
	check(o.size() == 1 and o[0]["wave"] == "d2_w0", "deck 2's garrison wave")
	o = _tick(h, 6.0, {"alive": [0, 0, 3], "crew_deck": [2], "objectives": _objs({"hold": "active"}),
			"wave_alive": {"d2_w0": {"alive": 3, "total": 3}}}, "df")
	check(o.size() == 1 and o[0]["wave"] == "d2_w1", "the hold's wave at once (%s)" % [o])


## Gap 3: a flag's alarm wave is released only with a standing mech on its deck; due with nobody there for ALARM_EXPIRE
## s, it is cancelled (and no longer owed). Free waves wait for the crew to come back (no expiry).
func _alarm_expiry() -> void:
	var d := WaveDirector.make(_fake_plan())
	var ob := {"objectives": _objs({"d0_p": "done"})}
	eq(_tick(d, 0.0, _f([5, 10, 10], [10, 10, 10], [1], ob), "a").size(), 0, "flag done, nobody on deck 0: no alarm wave")
	eq(d.status("d0_w3"), "due", "due, waiting for the crew")
	_tick(d, 19.9, _f([5, 10, 10], [10, 10, 10], [1], ob), "a")
	eq(d.status("d0_w3"), "due", "19.9 s: still due")
	_tick(d, 20.0, _f([5, 10, 10], [10, 10, 10], [1], ob), "a")
	eq(d.status("d0_w3"), "cancelled", "20 s due with nobody on the deck: cancelled")
	eq(d.waves_left(0), 2, "the cancelled alarm is not owed (2 garrison waves are)")
	var back := WaveDirector.make(_fake_plan())
	_tick(back, 0.0, _f([5, 10, 10], [10, 10, 10], [1], ob), "a")
	var o := _tick(back, 10.0, _f([5, 10, 10], [10, 10, 10], [0], ob), "a")
	check(o.size() == 1 and o[0]["wave"] == "d0_w3", "the crew back on the deck in time: the alarm goes out (%s)" % [o])
	# Free waves.
	var f := WaveDirector.make(_fake_plan())
	_tick(f, 0.0, _f([5, 10, 10], [10, 10, 10], [0]), "a")
	eq(_tick(f, 1.0, _f([2, 10, 10], [0, 10, 10], [1]), "a").size(), 0, "garrison low with the crew gone: not released")
	eq(f.status("d0_w0"), "due", "it stays due")
	_tick(f, 50.0, _f([2, 10, 10], [0, 10, 10], [1]), "a")
	eq(f.status("d0_w0"), "due", "no expiry for a free wave")
	eq(f.waves_left(0), 2, "still owed")
	o = _tick(f, 51.0, _f([2, 10, 10], [0, 10, 10], [0]), "a")
	check(o.size() == 1 and o[0]["wave"] == "d0_w0", "the crew back: released (%s)" % [o])


func _crew_at(k: int, x: float, s: float, downed: bool = false) -> Dictionary:
	return {"peer": 1, "downed": downed, "deck": k, "x": x, "s": s}


## Gap 4: the source is chosen at release from the crew: nearest the target (the objective's site, else the standing
## crew's centroid), at least MIN_SOURCE_DIST from every standing mech; inside MAX_SOURCE_DIST preferred.
func _source_choice() -> void:
	var df := {"objectives": _objs({"d0_b0": "active"})}
	# Defend at (0, 150), crew on it: gate_a is 50 m off (too close to the crew), gate_b 64 m.
	var d := WaveDirector.make(_fake_plan())
	var f := _f([0, 10, 10], [10, 10, 10], [0], df)
	f["crew"] = [_crew_at(0, 0.0, 150.0)]
	var o := _tick(d, 0.0, f, "s")
	check(o.size() == 1 and o[0]["source"] == "d0_gate_b", "defend: nearest source >= 60 m from the crew (%s)" % [o])
	eq(d.source_of("d0_w4"), "d0_gate_b", "source_of reports it")
	# No crew facts: the planned source.
	var p := WaveDirector.make(_fake_plan())
	o = _tick(p, 0.0, _f([0, 10, 10], [10, 10, 10], [0], df), "s")
	check(o.size() == 1 and o[0]["source"] == "d0_gate_a", "no crew facts: the planned source (%s)" % [o])
	# Free wave: target the crew's centroid (95, 10); the lift is 11 m off, the ramp 195 m.
	var g := WaveDirector.make(_fake_plan())
	f = _f([2, 10, 10], [0, 10, 10], [0])
	f["crew"] = [_crew_at(0, 90.0, 10.0), _crew_at(0, 100.0, 10.0), _crew_at(0, -95.0, 0.0, true), _crew_at(1, 0.0, 0.0)]
	o = _tick(g, 0.0, f, "s")
	check(o.size() == 1 and o[0]["source"] == "d0_ramp", "free wave: near the standing crew, not on top of it (%s)" % [o])
	# Closed sources stay out.
	var z := WaveDirector.make(_fake_plan())
	f = _f([0, 10, 10], [10, 10, 10], [0], df)
	f["crew"] = [_crew_at(0, 0.0, 150.0)]
	f["closed"] = ["d0_gate_b"]
	o = _tick(z, 0.0, f, "s")
	check(o.size() == 1 and o[0]["source"] == "d0_lift", "closed gate_b skipped: next qualifying source (%s)" % [o])
	# MAX_SOURCE_DIST: inside the limit beats outside even too close to the crew; inside and far enough beats both.
	for mid in [false, true]:
		var mp := _fake_plan()
		mp.sources.append(_src("d2_far", 2, "gate", 0.0, 400.0))
		if mid:
			mp.sources.append(_src("d2_mid", 2, "gate", 0.0, 250.0))
		var h := WaveDirector.make(mp)
		f = {"alive": [0, 0, 5], "garrison_alive": [10, 10, 5], "crew_deck": [2], "crew": [_crew_at(2, 0.0, 0.0)],
				"objectives": _objs({"hold": "active"})}
		o = _tick(h, 0.0, f, "s")
		var want := "d2_mid" if mid else "d2_gate"
		check(o.size() == 1 and o[0]["source"] == want, "hold wave, mid source %s: %s (%s)" % [mid, want, o])


## Stall guard: a reported wave whose alive count has not moved for STALL s counts as mostly beaten for spacing.
func _stall() -> void:
	var d := WaveDirector.make(_fake_plan())
	_tick(d, 0.0, _f([2, 10, 10], [0, 10, 10], [0]), "st")
	var wa := {"wave_alive": {"d0_w0": {"alive": 4, "total": 4}}}
	eq(_tick(d, 6.0, _f([6, 10, 10], [0, 10, 10], [0], wa), "st").size(), 0, "fresh")
	eq(_tick(d, 95.9, _f([6, 10, 10], [0, 10, 10], [0], wa), "st").size(), 0, "unchanged for 89.9 s: still fresh")
	eq(_tick(d, 96.0, _f([6, 10, 10], [0, 10, 10], [0], wa), "st").size(), 0, "stalled at 96: the lull starts")
	eq(_tick(d, 120.9, _f([6, 10, 10], [0, 10, 10], [0], wa), "st").size(), 0, "inside the lull")
	var o := _tick(d, 121.0, _f([6, 10, 10], [0, 10, 10], [0], wa), "st")
	check(o.size() == 1 and o[0]["wave"] == "d0_w1", "the next wave after a stall + lull (%s)" % [o])
	# A count that moves restarts the timer.
	var m := WaveDirector.make(_fake_plan())
	_tick(m, 0.0, _f([2, 10, 10], [0, 10, 10], [0]), "st")
	_tick(m, 6.0, _f([6, 10, 10], [0, 10, 10], [0], wa), "st")
	_tick(m, 50.0, _f([5, 10, 10], [0, 10, 10], [0], {"wave_alive": {"d0_w0": {"alive": 3, "total": 4}}}), "st")
	eq(_tick(m, 125.0, _f([5, 10, 10], [0, 10, 10], [0], {"wave_alive": {"d0_w0": {"alive": 3, "total": 4}}}), "st").size(),
			0, "a kill at 50 restarts it: no wave at 125 (stall at 140, lull to 165)")


## Round 2: an order whose door has not opened reserves the wave's expected size (facts.wave_size, else WAVE_MAX),
## capped by its max_units, not the whole cap room it was given.
func _reservation() -> void:
	var df := _objs({"d0_b0": "active"})
	for sized in [false, true]:
		var d := WaveDirector.make(_fake_plan())
		var f := _f([2, 0, 0], [0, 10, 10], [0])
		if sized:
			f["wave_size"] = {"d0_w0": 3}
		var o := _tick(d, 0.0, f, "rv")
		check(o.size() == 1 and o[0]["wave"] == "d0_w0" and int(o[0]["max_units"]) == 22, "first wave: max_units = cap room 22 (%s)" % [o])
		f = _f([2, 0, 0], [0, 10, 10], [0], {"objectives": df})
		if sized:
			f["wave_size"] = {"d0_w0": 3}
		o = _tick(d, 1.0, f, "rv")
		var want := 24 - 2 - (3 if sized else WaveDirector.WAVE_MAX)
		check(o.size() == 1 and o[0]["wave"] == "d0_w4" and int(o[0]["max_units"]) == want,
				"defend wave in the same door window: room %d (wave_size %s) (%s)" % [want, sized, o])
	# A small room caps the reservation: a 4-unit order reserves 4, not WAVE_MAX.
	var s := WaveDirector.make(_fake_plan(), {"deck_cap": 12})
	var o2 := _tick(s, 0.0, _f([8, 10, 10], [0, 10, 10], [0]), "rv")
	check(o2.size() == 1 and int(o2[0]["max_units"]) == 4, "deck cap 12, 8 alive: 4 (%s)" % [o2])
	o2 = _tick(s, 1.0, _f([6, 10, 10], [0, 10, 10], [0], {"objectives": df}), "rv")
	check(o2.size() == 1 and int(o2[0]["max_units"]) == 2, "then 12 - 6 - 4 reserved = 2 (%s)" % [o2])


# --- End to end ------------------------------------------------------------------------------------------

## A host loop over a 3-deck mission: one mech walks objective to objective (20 m/s, down the critical path), the
## garrison dies one unit every 3 s while the mech is on its deck, wave units spawn at their door's open_at and die 4 s
## later. Facts flow rules -> director (objectives) and director -> rules (waves_left, defend_waves, waves).
func _end_to_end() -> void:
	mid_sweeps = 0
	for seed_ in range(1, 11):
		var sec := SectionPlan.make({"seed": float(seed_), "decks": 3.0})
		var mp := MissionPlan.make(sec)
		var rules := MissionRules.make(sec, {"plan": mp})
		var dir := WaveDirector.make(mp)
		var tag := "e2e seed %d" % seed_
		var n := sec.deck_count
		var garrison: Array = []
		var gar_clock: Array = []
		for k in n:
			garrison.append(8)
			gar_clock.append(0.0)
		var size := {}         # wave id -> planned units
		for pl: Dictionary in mp.pools:
			for w: Dictionary in pl["waves"]:
				size[w["id"]] = clampi(int(round(float(w["share"]) * 16.0)), 1, 8)
		var spawned := {}
		var loads: Array = []  # [open_at, wave, deck, units]
		var units: Array = []  # [wave, deck, die_at]
		var deck := 0
		var a0 := sec.arrival(0)
		var pos := Vector2(float(a0["x"]), float(a0["s"]))
		var t := 0.0
		var dt := 0.5
		var orders_n := 0
		var idle_since: Array = []
		var worst_idle: Array = []
		for k in n:
			idle_since.append(-1.0)
			worst_idle.append(0.0)
			if k > 0 and k < n - 1 and mp.primary(k)["type"] == "sweep":
				mid_sweeps += 1
		while t < 3600.0 and rules.outcome == "":
			# World.
			var rest: Array = []
			for ld: Array in loads:
				if t >= float(ld[0]):
					var room := int(size[ld[1]]) - int(spawned.get(ld[1], 0))
					var c := mini(int(ld[3]), room)
					spawned[ld[1]] = int(spawned.get(ld[1], 0)) + c
					for i in c:
						units.append([ld[1], ld[2], t + 4.0])
				else:
					rest.append(ld)
			loads = rest
			units = units.filter(func(u: Array) -> bool: return t < float(u[2]))
			if garrison[deck] > 0 and t - float(gar_clock[deck]) >= 3.0:
				garrison[deck] -= 1
				gar_clock[deck] = t
			var alive: Array = garrison.duplicate()
			var wa := {}
			for id: String in spawned:
				wa[id] = {"alive": 0, "total": spawned[id]}
			for u: Array in units:
				alive[int(u[1])] += 1
				wa[u[0]]["alive"] += 1
			var pending := {}
			for id: String in spawned:
				pending[id] = int(size[id]) - int(spawned[id])
			# Rules, then the director.
			var crew := [{"peer": 1, "downed": false, "deck": deck, "x": pos.x, "s": pos.y}]
			rules.evaluate({"t": t, "enemies": alive, "crew": crew, "waves_left": dir.waves_left_all(),
					"defend_waves": dir.objective_waves(), "waves": dir.state()["waves"]})
			var orders := dir.tick(t, {"alive": alive, "garrison_alive": garrison, "crew_deck": [deck], "crew": crew,
					"objectives": rules.state(), "wave_alive": wa, "wave_pending": pending})
			_orders_ok(dir, t, orders, tag)
			# A sweep deck never sits empty (nothing alive, sweep active, not done) longer than lull + telegraph + slack.
			for k in n:
				var sp := mp.primary(k)
				if sp["type"] == "sweep" and rules.obj_state(sp["id"]) == "active" and int(alive[k]) == 0:
					if idle_since[k] < 0.0:
						idle_since[k] = t
					worst_idle[k] = maxf(float(worst_idle[k]), t - float(idle_since[k]))
				else:
					idle_since[k] = -1.0
			for o: Dictionary in orders:
				loads.append([o["open_at"], o["wave"], o["deck"], o["max_units"]])
				orders_n += 1
			# The mech: to its deck's primary (a sweep waits on the deck), then down; on the extraction deck, then the hold.
			var p := mp.primary(deck)
			var goal: Vector2
			if rules.obj_state(p["id"]) != "done":
				goal = Vector2(float(p["site"]["x"]), float(p["site"]["s"]))
			elif deck < n - 1:
				var dep := sec.departure(deck)
				goal = Vector2(float(dep["x"]), float(dep["s"]))
				if pos.distance_to(goal) < 1.0:
					deck += 1
					var ar := sec.arrival(deck)
					pos = Vector2(float(ar["x"]), float(ar["s"]))
					goal = pos
			else:
				goal = (mp.objective("hold")["params"]["zone"] as Rect2).get_center()
			pos = pos.move_toward(goal, 20.0 * dt)
			t += dt
		print("%s: %s at t %.0f s, %d orders, lines on the last deck %s" % [tag, rules.outcome, t, orders_n, rules.lines(n - 1)])
		for k in n:
			if mp.primary(k)["type"] == "sweep":
				var slack := dir.lull(k) + 5.0 + 3.0
				check(float(worst_idle[k]) <= slack, tag + ": deck %d sweep idle at most lull + telegraph + 3 s (%.1f > %.1f)" % [k, worst_idle[k], slack])
		eq(rules.outcome, "won", tag + ": the mission is won (t %.0f, current %s, text %s)" % [t, rules.current(), rules.text()])
		check(orders_n > 0, tag + ": waves were ordered")
	check(mid_sweeps >= 1, "the e2e seeds include a sweep primary on a middle deck (%d)" % mid_sweeps)
