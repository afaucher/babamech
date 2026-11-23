extends TestCase
## MissionRules (docs/design/mission-section.md §14): the objective list built from the section plan, the extraction
## zone, clear / extract latching, win and loss (win first, empty crew never loses), the latched outcome, evaluate's
## return value, the state round trip host -> client (JSON and var_to_bytes) and the HUD strings. The crew-wipe loss is
## off by default until revive exists (user decision 2026-11-22): every loss case builds its rules with W.

const W := {"wipe": true}


func setup() -> void:
	_objectives()
	_clearing()
	_extraction()
	_no_wipe_by_default()
	_outcomes()
	_round_trip()
	_text()
	_plan_basics()
	_plan_flag()
	_plan_defend()
	_plan_sweep_hold()
	_plan_hud()
	_plan_set_site()
	_plan_state()
	finish()


func _crew(downed: bool, deck: int = 0, x: float = 0.0, s: float = 0.0, peer: int = 1) -> Dictionary:
	return {"peer": peer, "downed": downed, "deck": deck, "x": x, "s": s}


func _zeros(n: int) -> Array:
	var a := []
	a.resize(n)
	a.fill(0)
	return a


func _objectives() -> void:
	# SectionPlan clamps decks to [MIN_DECKS, MAX_DECKS] = [2, 5]: asking for 1 gives 2.
	for decks in [1, 2, 3, 5]:
		for seed_ in [1, 4, 9, 17, 23]:
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var tag := "decks %d seed %d" % [decks, seed_]
			var n := sec.deck_count
			check(n == maxi(decks, SectionPlan.MIN_DECKS), tag + ": deck count")
			var off := MissionRules.make(sec, {"extract": false})
			eq(off.objectives.size(), n, tag + ": one clear per deck without extract")
			var m := MissionRules.make(sec)
			if not eq(m.objectives.size(), n + 1, tag + ": clears + extract"):
				continue
			var clears := []
			for k in n:
				var o: Dictionary = m.objectives[k]
				eq(o["id"], "clear_%d" % k, tag + ": clear id")
				eq(o["kind"], "clear", tag)
				eq(o["deck"], k, tag)
				eq((o["needs"] as Array).size(), 0, tag + ": a clear needs nothing")
				eq(off.objectives[k]["id"], o["id"], tag + ": same clears with extract off")
				clears.append(o["id"])
			var ex: Dictionary = m.objectives[n]
			eq(ex["id"], "extract", tag)
			eq(ex["kind"], "extract", tag)
			eq(ex["needs"], clears, tag + ": extract needs every clear")
			var k: int = sec.extraction["deck"]
			eq(ex["deck"], k, tag + ": zone on the extraction deck")
			_check_zone(sec, ex["zone"], 40.0, tag)
			_check_zone(sec, MissionRules.make(sec, {"zone_depth": 25.0}).objective("extract")["zone"], 25.0, tag + " depth 25")
			var huge: Rect2 = MissionRules.make(sec, {"zone_depth": 1.0e6}).objective("extract")["zone"]
			near(huge.size.y, sec.arc_of(k), 0.01, tag + ": a huge depth clamps to the deck")


func _check_zone(sec: SectionPlan, zone: Rect2, depth: float, tag: String) -> void:
	var k: int = sec.extraction["deck"]
	var w := sec.p("width")
	var a := sec.arc_of(k)
	var extent := Rect2(-w * 0.5, -a * 0.5, w, a)
	check(extent.grow(0.01).encloses(zone), tag + ": zone inside the deck %s / %s" % [zone, extent])
	near(zone.size.y, depth, 0.01, tag + ": zone depth")
	near(zone.size.x, SectionPlan.SPINE_W, 0.01, tag + ": zone spans the spine corridor")
	near(zone.get_center().x, sec.col_x[sec.spine_line], 0.01, tag + ": zone centred on the spine")
	var j: int = sec.extraction["j"]
	check(j == 0 or j == sec.rows, tag + ": extraction is at an end of the arc")
	if j == 0:
		near(zone.position.y, -a * 0.5, 0.01, tag + ": zone touches the s0 wall")
	else:
		near(zone.end.y, a * 0.5, 0.01, tag + ": zone touches the s1 wall")
	var node := sec.node_pos(k, int(sec.extraction["i"]), j)
	var inward := Vector2(node.x, node.y + (1.0 if j == 0 else -1.0))
	check(zone.has_point(inward), tag + ": zone holds the extraction road node %s" % node)


func _clearing() -> void:
	var sec := SectionPlan.make({"seed": 5.0, "decks": 3.0})
	var m := MissionRules.make(sec)
	check(m.current() == "clear_0" and m.outcome == "", "starts on clear_0")
	check(m.evaluate({"enemies": [4, 2, 3], "crew": [_crew(false)]}), "first facts change the counts")
	eq(m.left_on(0), 4, "left on deck 0")
	eq(m.left_on(2), 3, "left on deck 2")
	eq(m.left_on(9), 0, "left on a missing deck")
	check(not m.evaluate({"enemies": [4, 2, 3], "crew": [_crew(false)]}), "same facts: no change")
	check(m.evaluate({"enemies": [0, 2, 3], "crew": [_crew(false)]}), "deck 0 cleared: change")
	check(m.is_done("clear_0"), "clear_0 done")
	eq(m.current(), "clear_1", "current moves on")
	m.evaluate({"enemies": [6, 2, 3], "crew": [_crew(false)]})
	check(m.is_done("clear_0"), "clear_0 stays done when enemies come back")
	eq(m.left_on(0), 6, "but the count is reported")
	m.evaluate({"enemies": [6, 0], "crew": [_crew(false)]})
	check(m.is_done("clear_1") and m.is_done("clear_2"), "a missing entry counts as 0")
	eq(m.current(), "extract", "then extract")
	eq(m.outcome, "", "not won before extracting")
	check(not m.is_done("nope"), "unknown id is not done")


func _extraction() -> void:
	for seed_ in [2, 6, 13]:
		var sec := SectionPlan.make({"seed": float(seed_)})
		var m := MissionRules.make(sec)
		var ex := m.objective("extract")
		var k: int = ex["deck"]
		var c: Vector2 = (ex["zone"] as Rect2).get_center()
		var other := 0 if k != 0 else 1
		var tag := "seed %d" % seed_
		# In the zone before the decks are clear: not done.
		var en := [1]
		m.evaluate({"enemies": en, "crew": [_crew(false, k, c.x, c.y)]})
		check(not m.is_done("extract"), tag + ": extract needs every clear")
		var clear := _zeros(sec.deck_count)
		eq(m.marker(), {}, tag + ": no marker while clearing")
		m.evaluate({"enemies": clear, "crew": [_crew(false, k, 1.0e5, 1.0e5)]})
		eq(m.current(), "extract", tag + ": all clear, extract is current")
		var mk := m.marker()
		eq(mk.get("deck", -1), k, tag + ": marker deck")
		near(float(mk.get("x", INF)), c.x, 0.001, tag + ": marker x")
		near(float(mk.get("s", INF)), c.y, 0.001, tag + ": marker s")
		check(not m.evaluate({"enemies": clear, "crew": [_crew(true, k, c.x, c.y, 1), _crew(false, k, 1.0e5, 0.0, 2)]}),
				tag + ": a downed mech in the zone does not count")
		check(not m.evaluate({"enemies": clear, "crew": [_crew(false, other, c.x, c.y)]}),
				tag + ": a standing mech on another deck does not count")
		var corner: Vector2 = (ex["zone"] as Rect2).end
		check(m.evaluate({"enemies": clear, "crew": [_crew(true, k, c.x, c.y, 1), _crew(false, k, corner.x, corner.y, 2)]}),
				tag + ": a standing mech on the zone's edge extracts")
		check(m.is_done("extract"), tag + ": extract done")
		eq(m.outcome, "won", tag)
		eq(m.reason, "objectives", tag)
		eq(m.current(), "", tag + ": nothing left")
		eq(m.marker(), {}, tag + ": no marker after")


func _no_wipe_by_default() -> void:
	var sec := SectionPlan.make({"seed": 3.0, "decks": 2.0})
	var down := [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	check(not bool(MissionRules.make(sec).options["wipe"]), "wipe is off by default")
	# With t: all downed for a long time.
	var m := MissionRules.make(sec)
	m.evaluate({"t": 0.0, "enemies": [2, 2], "crew": down})
	for t in [0.5, 1.0, 5.0, 60.0, 600.0]:
		check(not m.evaluate({"t": t, "enemies": [2, 2], "crew": down}), "wipe off, all down at t %s: no change" % t)
		eq(m.outcome, "", "wipe off, all down at t %s: not lost" % t)
		eq(m._wipe_t, -1.0, "wipe off: no countdown at t %s" % t)
	# Without t (would be immediate with wipe on).
	var nt := MissionRules.make(sec)
	nt.evaluate({"enemies": [2, 2], "crew": down})
	for i in 5:
		check(not nt.evaluate({"enemies": [2, 2], "crew": down}), "wipe off, all down, no t: no change")
	eq(nt.outcome, "", "wipe off, no t: not lost")
	var solo := MissionRules.make(sec)
	solo.evaluate({"enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "", "wipe off, solo downed: not lost")
	eq(solo.text(), "Clear deck 1: 1 hostile left", "wipe off: the HUD keeps the objective")
	# The mission can still be won afterwards: clear all, then a standing mech in the zone.
	for r: MissionRules in [m, nt]:
		var ex := r.objective("extract")
		var k: int = ex["deck"]
		var c: Vector2 = (ex["zone"] as Rect2).get_center()
		check(r.evaluate({"t": 700.0, "enemies": [0, 0], "crew": down}), "wipe off: clearing while all down is a change")
		eq(r.outcome, "", "all clear but nobody standing in the zone")
		check(not r.evaluate({"t": 701.0, "enemies": [0, 0], "crew": [_crew(true, k, c.x, c.y)]}),
				"wipe off: a downed mech in the zone still does not extract")
		check(r.evaluate({"t": 702.0, "enemies": [0, 0], "crew": [_crew(false, k, c.x, c.y, 1), _crew(true, k, c.x, c.y, 2)]}),
				"wipe off: a standing mech in the zone extracts")
		eq(r.outcome, "won", "wipe off: won after a long wipe")
		eq(r.reason, "objectives", "wipe off: win reason")


func _outcomes() -> void:
	var sec := SectionPlan.make({"seed": 3.0, "decks": 2.0})
	# Lost: all downed.
	var m := MissionRules.make(sec, W)
	m.evaluate({"enemies": [2, 2], "crew": [_crew(false, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]})
	eq(m.outcome, "", "one standing: not lost")
	check(m.evaluate({"enemies": [2, 2], "crew": [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]}), "loss is a change")
	eq(m.outcome, "lost", "all downed: lost")
	eq(m.reason, "crew_down", "reason")
	# Latched.
	check(not m.evaluate({"enemies": [0, 0], "crew": [_crew(false)]}), "after the outcome nothing changes")
	eq(m.outcome, "lost", "outcome latched")
	eq(m.left_on(0), 2, "counts frozen too")
	check(not m.is_done("clear_0"), "objectives frozen too")
	# Solo downed.
	var solo := MissionRules.make(sec, W)
	solo.evaluate({"enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "lost", "solo downed: lost")
	# Empty crew.
	var empty := MissionRules.make(sec, W)
	empty.evaluate({"enemies": [1, 1], "crew": []})
	empty.evaluate({"enemies": [1, 1]})
	eq(empty.outcome, "", "an empty crew never loses")
	# Win beats loss in the same call (extract off, last enemy dies while all are downed).
	var w := MissionRules.make(sec, {"extract": false, "wipe": true})
	w.evaluate({"enemies": [0, 1], "crew": [_crew(false)]})
	eq(w.outcome, "", "not yet")
	check(w.evaluate({"enemies": [0, 0], "crew": [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]}), "change")
	eq(w.outcome, "won", "win beats loss")
	eq(w.reason, "objectives", "win reason")
	check(not w.evaluate({"enemies": [3, 3], "crew": [_crew(true)]}), "won is latched")
	eq(w.outcome, "won", "still won")
	_grace(sec)


func _grace(sec: SectionPlan) -> void:
	var down := [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	var up := [_crew(false, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	var m := MissionRules.make(sec, W)
	m.evaluate({"t": 9.0, "enemies": [2, 2], "crew": up})
	check(not m.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down}), "the wipe countdown is not a state change")
	eq(m.outcome, "", "all down at 10.0: not lost yet")
	check(not m.evaluate({"t": 10.9, "enemies": [2, 2], "crew": down}), "10.9: no change")
	eq(m.outcome, "", "not lost at 10.9")
	check(m.evaluate({"t": 11.0, "enemies": [2, 2], "crew": down}), "11.0: loss is a change")
	eq(m.outcome, "lost", "lost at 11.0")
	# A revive resets the countdown.
	var r := MissionRules.make(sec, W)
	r.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down})
	r.evaluate({"t": 10.5, "enemies": [2, 2], "crew": up})
	r.evaluate({"t": 10.6, "enemies": [2, 2], "crew": down})
	r.evaluate({"t": 11.0, "enemies": [2, 2], "crew": down})
	eq(r.outcome, "", "revived at 10.5: not lost at 11.0")
	r.evaluate({"t": 11.59, "enemies": [2, 2], "crew": down})
	eq(r.outcome, "", "not lost at 11.59")
	r.evaluate({"t": 11.6, "enemies": [2, 2], "crew": down})
	eq(r.outcome, "lost", "lost at 11.6")
	# An empty crew also resets it.
	var e := MissionRules.make(sec, W)
	e.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down})
	e.evaluate({"t": 10.5, "enemies": [2, 2], "crew": []})
	e.evaluate({"t": 11.2, "enemies": [2, 2], "crew": down})
	eq(e.outcome, "", "an empty crew resets the countdown")
	# No t, or no grace: immediate.
	var nt := MissionRules.make(sec, W)
	nt.evaluate({"enemies": [2, 2], "crew": down})
	eq(nt.outcome, "lost", "no t: immediate loss")
	var g0 := MissionRules.make(sec, {"wipe_grace": 0.0, "wipe": true})
	g0.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down})
	eq(g0.outcome, "lost", "wipe_grace 0: immediate loss")
	var solo := MissionRules.make(sec, W)
	solo.evaluate({"t": 5.0, "enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "", "solo downed: inside the grace")
	solo.evaluate({"t": 6.0, "enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "lost", "solo downed: lost after the grace")
	var empty := MissionRules.make(sec, W)
	for t in [0.0, 5.0, 50.0]:
		empty.evaluate({"t": t, "enemies": [1, 1], "crew": []})
	eq(empty.outcome, "", "an empty crew never loses (with t)")
	# Win beats loss inside the grace window.
	var w := MissionRules.make(sec, {"extract": false, "wipe": true})
	w.evaluate({"t": 10.0, "enemies": [0, 1], "crew": down})
	eq(w.outcome, "", "all down, grace running")
	w.evaluate({"t": 10.4, "enemies": [0, 0], "crew": down})
	eq(w.outcome, "won", "the last enemy dies inside the grace: won")


func _round_trip() -> void:
	var sec := SectionPlan.make({"seed": 21.0, "decks": 3.0})
	var host := MissionRules.make(sec)
	var stages := [
		{"enemies": [3, 4, 5], "crew": [_crew(false)]},
		{"enemies": [0, 1, 5], "crew": [_crew(false)]},
		{"enemies": [0, 0, 0], "crew": [_crew(false)]},
	]
	for i in stages.size():
		host.evaluate(stages[i])
		var st := host.state()
		var via_json: Variant = JSON.parse_string(JSON.stringify(st))
		check(via_json is Dictionary, "stage %d: JSON parses" % i)
		var client := MissionRules.make(sec)
		client.apply_state(via_json)
		eq(client.state(), st, "stage %d: JSON round trip reproduces state()" % i)
		eq(client.text(), host.text(), "stage %d: same text" % i)
		eq(client.marker(), host.marker(), "stage %d: same marker" % i)
		var client2 := MissionRules.make(sec)
		client2.apply_state(bytes_to_var(var_to_bytes(st)))
		eq(client2.state(), st, "stage %d: var_to_bytes round trip" % i)
	# Size on the wire: 5 decks, mid-mission and done.
	var big := SectionPlan.make({"seed": 21.0, "decks": 5.0})
	var bm := MissionRules.make(big, {"wipe": true})
	bm.evaluate({"enemies": [999, 999, 999, 999, 999], "crew": [_crew(false)]})
	var size0 := JSON.stringify(bm.state()).length()
	bm.evaluate({"enemies": [0, 0, 0, 0, 0], "crew": [_crew(true)]})
	var size1 := JSON.stringify(bm.state()).length()
	print("state JSON, 5 decks: %d bytes clearing, %d bytes all clear + lost" % [size0, size1])
	check(size0 < 512 and size1 < 512, "state() JSON stays under 512 bytes for 5 decks (%d, %d)" % [size0, size1])
	# Floats where ints were, and missing keys.
	var c := MissionRules.make(sec)
	c.apply_state({"left": [2.0, 1.0], "done": ["clear_0", "bogus"]})
	eq(c.left_on(0), 2, "float counts become ints")
	eq(c.left_on(2), 0, "short left pads with 0")
	check(c.is_done("clear_0") and not c.is_done("bogus"), "only known ids are applied")
	eq(c.outcome, "", "missing outcome leaves it")
	c.apply_state({})
	eq(c.left_on(0), 2, "an empty dict changes nothing")
	c.apply_state({"outcome": "lost", "reason": "crew_down"})
	eq(c.text(), "Crew down", "mirrored loss")


func _text() -> void:
	var sec := SectionPlan.make({"seed": 8.0, "decks": 3.0})
	var m := MissionRules.make(sec)
	m.evaluate({"enemies": [5, 1, 1], "crew": [_crew(false)]})
	eq(m.text(), "Clear deck 1: 5 hostiles left", "clearing, 1-based")
	m.evaluate({"enemies": [0, 1, 1], "crew": [_crew(false)]})
	eq(m.text(), "Clear deck 2: 1 hostile left", "singular")
	m.evaluate({"enemies": [0, 0, 0], "crew": [_crew(false)]})
	eq(m.text(), "Reach the extraction portal", "extract")
	var z: Rect2 = m.objective("extract")["zone"]
	m.evaluate({"enemies": [0, 0, 0], "crew": [_crew(false, int(sec.extraction["deck"]), z.get_center().x, z.get_center().y)]})
	eq(m.text(), "Mission complete", "won")
	var l := MissionRules.make(sec, {"wipe": true})
	l.evaluate({"enemies": [5, 1, 1], "crew": [_crew(true)]})
	eq(l.text(), "Crew down", "lost")


# --- Plan mode (docs/design/mission-objectives.md §9) ----------------------------------------------------------

## A hand-made 3-deck plan: d0 flag primary at (0, 150) + a defend bonus after it + a flag bonus far off; d1 sweep with
## a defend bonus; d2 defend primary; the hold in Rect2(-10, -10, 20, 20) on deck 2.
func _fake_plan() -> MissionPlan:
	var mp := MissionPlan.new()
	mp.deck_count = 3
	mp.objectives = [
		{"id": "d0_p", "type": "flag", "deck": 0, "role": "primary", "site": {"x": 0.0, "s": 150.0}, "radius": 14.0,
			"needs": [], "params": {"hold": 20.0}},
		{"id": "d0_b0", "type": "defend", "deck": 0, "role": "bonus", "site": {"x": 0.0, "s": 150.0}, "radius": 30.0,
			"needs": ["d0_p"], "params": {"waves": 2, "asset_hp": 1.0}},
		{"id": "d0_b1", "type": "flag", "deck": 0, "role": "bonus", "site": {"x": 100.0, "s": -200.0}, "radius": 14.0,
			"needs": [], "params": {"hold": 20.0}},
		{"id": "d1_p", "type": "sweep", "deck": 1, "role": "primary", "site": {"x": 0.0, "s": 200.0}, "radius": 0.0,
			"needs": [], "params": {}},
		{"id": "d1_b0", "type": "defend", "deck": 1, "role": "bonus", "site": {"x": 50.0, "s": 0.0}, "radius": 30.0,
			"needs": [], "params": {"waves": 3, "asset_hp": 1.0}},
		{"id": "d2_p", "type": "defend", "deck": 2, "role": "primary", "site": {"x": 0.0, "s": 100.0}, "radius": 30.0,
			"needs": [], "params": {"waves": 2, "asset_hp": 1.0}},
		{"id": "hold", "type": "hold", "deck": 2, "role": "primary", "site": {"x": 0.0, "s": 0.0}, "radius": 0.0,
			"needs": ["d0_p", "d1_p", "d2_p"], "params": {"hold": 60.0, "zone": Rect2(-10, -10, 20, 20)}},
	]
	return mp


func _prules() -> MissionRules:
	return MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0}), {"plan": _fake_plan()})


func _plan_basics() -> void:
	var m := _prules()
	eq(m.objectives.size(), 7, "plan: the plan's objectives, no clears")
	eq(m.objectives[0]["kind"], "flag", "plan: kind = type")
	check(m.objectives[6]["zone"] is Rect2, "plan: the hold carries its zone")
	eq(m.obj_state("d0_p"), "known", "primaries start known")
	eq(m.obj_state("d0_b1"), "hidden", "bonuses start hidden")
	eq(m.obj_state("hold"), "hidden", "a primary with needs starts hidden")
	eq(m.obj_state("nope"), "", "unknown id")
	eq(m.current(), "d0_p", "current = first primary not done")
	# Discovery: a standing mech on the deck within 150 m.
	m.evaluate({"t": 0.0, "crew": [_crew(false, 1, 100.0, -200.0)]})
	eq(m.obj_state("d0_b1"), "hidden", "another deck: not found")
	m.evaluate({"t": 0.5, "crew": [_crew(true, 0, 100.0, -200.0)]})
	eq(m.obj_state("d0_b1"), "hidden", "a downed mech finds nothing")
	m.evaluate({"t": 1.0, "crew": [_crew(false, 0, 100.0, -200.0 + 151.0)]})
	eq(m.obj_state("d0_b1"), "hidden", "151 m: not found")
	check(m.evaluate({"t": 1.5, "crew": [_crew(false, 0, 100.0, -200.0 + 149.0)]}), "discovery is a state change")
	eq(m.obj_state("d0_b1"), "known", "149 m: found")
	m.evaluate({"t": 2.0, "crew": [_crew(false, 1, 0.0, 0.0)]})
	eq(m.obj_state("d0_b1"), "known", "found stays found")
	# Needs gating: standing on the flag, the defend bonus that follows it stays hidden.
	m.evaluate({"t": 3.0, "crew": [_crew(false, 0, 0.0, 150.0)]})
	eq(m.obj_state("d0_b0"), "hidden", "needs not done: hidden, even next to it")
	eq(m.obj_state("d0_p"), "active", "standing in the flag zone: active")
	# Plan-less rules are untouched.
	var plain := MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0}))
	check(not plain.state().has("objs"), "no plan: no objs in state()")
	eq(plain.options, MissionRules.DEFAULTS, "no plan: same options")
	eq(plain.lines(0).size(), 0, "no plan: no lines")
	eq(plain.markers(0).size(), 0, "no plan: no markers")


func _plan_flag() -> void:
	var m := _prules()
	var on := [_crew(false, 0, 5.0, 150.0)]
	m.evaluate({"t": 0.0, "crew": on})
	for i in 10:
		m.evaluate({"t": 0.5 * (i + 1), "crew": on})
	near(m.obj_progress("d0_p"), 5.0, 0.001, "flag: 5 s in the zone")
	m.evaluate({"t": 6.0, "crew": on, "zone_enemies": {"d0_p": 1}})
	m.evaluate({"t": 7.0, "crew": on, "zone_enemies": {"d0_p": 2}})
	near(m.obj_progress("d0_p"), 5.0, 0.001, "flag: paused while an enemy is in the zone, never backwards")
	m.evaluate({"t": 8.0, "crew": [_crew(false, 0, 30.0, 150.0)]})
	near(m.obj_progress("d0_p"), 5.0, 0.001, "flag: paused while nobody is in the zone")
	eq(m.obj_state("d0_p"), "active", "flag: active latches")
	m.evaluate({"t": 9.0, "crew": [_crew(true, 0, 0.0, 150.0)]})
	near(m.obj_progress("d0_p"), 5.0, 0.001, "flag: a downed mech does not raise it")
	m.evaluate({"t": 200.0, "crew": on})
	near(m.obj_progress("d0_p"), 6.0, 0.001, "flag: a long gap adds at most 1 s")
	m.evaluate({"t": 201.0, "crew": on, "zone_enemies": {}})
	near(m.obj_progress("d0_p"), 7.0, 0.001, "flag: missing zone_enemies entry = 0")
	var t := 201.0
	while t < 214.0:
		t += 1.0
		m.evaluate({"t": t, "crew": on})
	eq(m.obj_state("d0_p"), "done", "flag: done at 20 s")
	check(m.is_done("d0_p"), "is_done")
	eq(m.obj_state("d0_b0"), "active", "the defend that follows the flag appears and starts (mech inside)")
	m.evaluate({"t": 300.0, "crew": [], "zone_enemies": {"d0_p": 5}})
	eq(m.obj_state("d0_p"), "done", "flag: done latches")
	eq(m.outcome, "", "not won: other primaries")
	# Without t nothing accumulates.
	var nt := _prules()
	for i in 5:
		nt.evaluate({"crew": on})
	near(nt.obj_progress("d0_p"), 0.0, 0.001, "flag: no t, no progress")


func _plan_defend() -> void:
	var m := _prules()
	var at := [_crew(false, 2, 0.0, 100.0 + 31.0)]
	m.evaluate({"t": 0.0, "crew": at, "defend_waves": {"d2_p": {"released": 2, "total": 2, "alive": 0}}})
	eq(m.obj_state("d2_p"), "known", "defend: 31 m off, not started")
	var inside := [_crew(false, 2, 0.0, 100.0 + 29.0)]
	m.evaluate({"t": 1.0, "crew": inside})
	eq(m.obj_state("d2_p"), "active", "defend: 29 m: active")
	m.evaluate({"t": 2.0, "crew": inside})
	eq(m.obj_state("d2_p"), "active", "defend: no defend_waves fact: stays active")
	m.evaluate({"t": 3.0, "crew": inside, "defend_waves": {"d2_p": {"released": 1, "total": 2, "alive": 3}}})
	near(m.obj_progress("d2_p"), 0.0, 0.001, "defend: wave 1 alive, 0 beaten")
	eq(m.lines(2)[0], "Defend the position: wave 1 / 2", "defend line")
	m.evaluate({"t": 4.0, "crew": [], "defend_waves": {"d2_p": {"released": 2, "total": 2, "alive": 1}}})
	near(m.obj_progress("d2_p"), 1.0, 0.001, "defend: wave 2 alive, 1 beaten")
	eq(m.lines(2)[0], "Defend the position: wave 2 / 2", "defend line, wave 2")
	eq(m.obj_state("d2_p"), "active", "defend: last wave still alive")
	m.evaluate({"t": 5.0, "crew": [], "defend_waves": {"d2_p": {"released": 2, "total": 2, "alive": 0}}})
	eq(m.obj_state("d2_p"), "done", "defend: every wave released and beaten: done")
	m.evaluate({"t": 6.0, "crew": [], "assets": {"d2_p": 0.0}})
	eq(m.obj_state("d2_p"), "done", "defend: done latches over a dead asset")
	# Failure of a primary loses; of a bonus does not.
	var f := _prules()
	f.evaluate({"t": 0.0, "crew": inside})
	f.evaluate({"t": 1.0, "crew": inside, "assets": {"d2_p": 0.0}})
	eq(f.obj_state("d2_p"), "failed", "defend: asset at 0 while active: failed")
	eq(f.outcome, "lost", "a failed primary loses the mission")
	eq(f.reason, "objective_failed", "reason")
	eq(f.text(), "Objective failed", "text after a failed primary")
	var b := _prules()
	b.evaluate({"t": 0.0, "enemies": [0, 3, 0], "crew": [_crew(false, 1, 50.0, 0.0)]})
	b.evaluate({"t": 1.0, "enemies": [0, 3, 0], "crew": [_crew(false, 1, 50.0, 0.0)], "assets": {"d1_b0": 0.0}})
	eq(b.obj_state("d1_b0"), "failed", "bonus defend: failed")
	eq(b.outcome, "", "a failed bonus does not lose")
	eq(b.obj_state("d1_p"), "active", "the sweep starts with a mech on its deck")
	var k := _prules()
	k.evaluate({"t": 0.0, "crew": [_crew(false, 2, 0.0, 200.0)], "assets": {"d2_p": 0.0}})
	eq(k.outcome, "", "a known (not started) defend cannot fail")
	# A defend cannot fail on the evaluate it becomes active in (the asset is reset to full on activation).
	var g := _prules()
	g.evaluate({"t": 0.0, "crew": inside, "assets": {"d2_p": 0.0}})
	eq(g.obj_state("d2_p"), "active", "defend: asset at 0 on the activating evaluate: not failed")
	eq(g.outcome, "", "no loss on activation")
	g.evaluate({"t": 1.0, "crew": inside, "assets": {"d2_p": 0.0}})
	eq(g.obj_state("d2_p"), "failed", "defend: still 0 on the next evaluate: failed")
	var r := _prules()
	r.evaluate({"t": 0.0, "crew": inside, "assets": {"d2_p": 0.0}})
	r.evaluate({"t": 1.0, "crew": inside, "assets": {"d2_p": 1.0}})
	eq(r.obj_state("d2_p"), "active", "defend: back at 1.0 on the next evaluate: not failed")
	r.evaluate({"t": 2.0, "crew": inside, "assets": {"d2_p": 0.0}})
	eq(r.obj_state("d2_p"), "failed", "defend: 0 later on: failed")


func _plan_sweep_hold() -> void:
	var m := _prules()
	m.evaluate({"t": 0.0, "enemies": [0, 0, 0], "waves_left": [0, 0, 0], "crew": [_crew(false, 0, 0, 0)]})
	eq(m.obj_state("d1_p"), "known", "sweep: nobody on the deck yet: not cleared")
	m.evaluate({"t": 1.0, "enemies": [0, 0, 0], "waves_left": [0, 1, 0], "crew": [_crew(false, 1, 0, 0)]})
	eq(m.obj_state("d1_p"), "active", "sweep: a mech on the deck: active")
	m.evaluate({"t": 2.0, "enemies": [0, 2, 0], "waves_left": [0, 0, 0], "crew": [_crew(false, 1, 0, 0)]})
	eq(m.obj_state("d1_p"), "active", "sweep: enemies left")
	m.evaluate({"t": 3.0, "enemies": [0, 0, 0], "waves_left": [0, 1, 0], "crew": []})
	eq(m.obj_state("d1_p"), "active", "sweep: waves left")
	m.evaluate({"t": 4.0, "enemies": [0, 0, 0], "crew": []})
	eq(m.obj_state("d1_p"), "done", "sweep: no enemies, missing waves_left = 0: done")
	# Finish the other primaries, then the hold.
	var on := [_crew(false, 0, 0.0, 150.0)]
	var t := 5.0
	m.evaluate({"t": t, "crew": on})
	for i in 25:
		t += 1.0
		m.evaluate({"t": t, "crew": on})
	eq(m.obj_state("d0_p"), "done", "flag done")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 2, 0, 100)], "defend_waves": {"d2_p": {"released": 0, "total": 0, "alive": 0}}})
	eq(m.obj_state("d2_p"), "done", "a defend with no waves is done once started")
	eq(m.obj_state("hold"), "known", "every primary done: the hold appears")
	eq(m.current(), "hold", "current: the hold")
	eq(m.text(), "Hold the extraction portal: 60 s", "hold text")
	eq(m.marker().get("deck", -1), 2, "marker on the hold")
	t += 2.0
	m.evaluate({"t": t, "crew": [_crew(false, 2, 0, 0)]})
	eq(m.obj_state("hold"), "active", "hold: a mech in the zone")
	for i in 30:
		t += 1.0
		m.evaluate({"t": t, "crew": [_crew(false, 2, 0, 0)]})
	eq(m.text(), "Hold the extraction portal: 29 s", "hold counts down (the starting call counts too)")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 2, 50, 0)]})
	for i in 28:
		t += 1.0
		m.evaluate({"t": t, "crew": [_crew(false, 2, 0, 0)]})
	eq(m.outcome, "", "hold paused while out of the zone: not yet")
	for i in 3:
		t += 1.0
		m.evaluate({"t": t, "crew": [_crew(false, 2, 0, 0)]})
	eq(m.obj_state("hold"), "done", "hold: done at 60 s")
	eq(m.outcome, "won", "every primary done: won")
	eq(m.reason, "objectives", "reason")
	eq(m.text(), "Mission complete", "text")
	check(not m.is_done("d0_b1"), "bonuses need not be done")
	# The crew-wipe rule still works in plan mode.
	var w := MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0}), {"plan": _fake_plan(), "wipe": true})
	w.evaluate({"crew": [_crew(true)]})
	eq(w.outcome, "lost", "plan mode: wipe on, all down, no t: lost")
	eq(w.reason, "crew_down", "plan mode: wipe reason")


func _plan_hud() -> void:
	var m := _prules()
	var wv := [[0, 3], [1, 3], [0, 0]]
	m.evaluate({"t": 0.0, "enemies": [3, 5, 0], "crew": [_crew(false, 0, 0.0, 150.0)], "waves": wv})
	m.evaluate({"t": 1.0, "enemies": [3, 5, 0], "crew": [_crew(false, 0, 0.0, 150.0)], "waves": wv})
	eq(m.text(), "Raise the flag: 1 / 20 s", "text: the flag")
	eq(m.lines(0), ["Raise the flag: 1 / 20 s"] as Array[String], "lines: only known objectives (bonus still hidden)")
	eq(m.lines(1), ["Clear deck 2: 5 hostiles, waves 1 / 3"] as Array[String], "lines: the sweep with its waves")
	eq(m.lines(2), ["Defend the position: wave 1 / 2"] as Array[String], "lines: deck 2 (hold hidden)")
	var mk := m.markers(0)
	if eq(mk.size(), 1, "markers: the flag only"):
		eq(mk[0], {"id": "d0_p", "type": "flag", "role": "primary", "deck": 0, "x": 0.0, "s": 150.0, "radius": 14.0,
				"state": "active"}, "marker record")
	m.evaluate({"t": 1.5, "crew": [_crew(false, 0, 100.0, -100.0)], "enemies": [1, 5, 0]})
	var lines := m.lines(0)
	eq(lines.size(), 2, "a found bonus gets a line")
	if lines.size() == 2:
		eq(lines[1], "Bonus: Raise the flag: 0 / 20 s", "bonus line, after the primary")
	eq(m.markers(0).size(), 2, "and a marker")
	var t := 2.0
	for i in 22:
		t += 1.0
		m.evaluate({"t": t, "crew": [_crew(false, 0, 0.0, 150.0)], "enemies": [1, 1, 0]})
	eq(m.lines(0)[0], "Raise the flag: 20 / 20 s (done)", "done line")
	for o: Dictionary in m.markers(0):
		check(o["id"] != "d0_p", "no marker for a done objective")
	eq(m.text(), "Clear deck 2: 1 hostile, waves 1 / 3", "text moves to the next primary")


func _plan_set_site() -> void:
	var m := _prules()
	m.set_site("d0_p", 20.0, 160.0)
	m.set_site("bogus", 0.0, 0.0)
	eq(m.objective("d0_p")["site"], {"x": 20.0, "s": 160.0}, "set_site moves the site")
	m.evaluate({"t": 0.0, "crew": [_crew(false, 0, 0.0, 150.0)]})
	eq(m.obj_state("d0_p"), "known", "the old spot is outside the moved zone")
	m.evaluate({"t": 1.0, "crew": [_crew(false, 0, 20.0, 165.0)]})
	eq(m.obj_state("d0_p"), "active", "the new spot is inside")
	var mk := m.markers(0)
	check(mk.size() == 1 and float(mk[0]["x"]) == 20.0 and float(mk[0]["s"]) == 160.0, "markers use the moved site")
	check(not JSON.stringify(m.state()).contains("160"), "the site is not in state()")
	var d := _prules()
	d.set_site("d0_b1", 100.0, 100.0)
	d.evaluate({"t": 0.0, "crew": [_crew(false, 0, 100.0, -60.0)]})
	eq(d.obj_state("d0_b1"), "hidden", "discovery measures from the moved site (160 m)")
	d.evaluate({"t": 1.0, "crew": [_crew(false, 0, 100.0, -40.0)]})
	eq(d.obj_state("d0_b1"), "known", "found within 150 m of the moved site")
	var plain := MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0}))
	plain.set_site("clear_0", 1.0, 1.0)
	check(not plain.objective("clear_0").has("site"), "no plan: set_site ignored")


func _plan_state() -> void:
	var m := _prules()
	m.evaluate({"t": 0.0, "enemies": [2, 2, 2], "crew": [_crew(false, 0, 0.0, 150.0)], "waves": [[0, 3], [1, 2], [0, 0]]})
	for i in 7:
		m.evaluate({"t": 0.3 * (i + 1), "enemies": [2, 2, 2], "crew": [_crew(false, 0, 0.0, 150.0)]})
	var st := m.state()
	check(st.has("objs"), "state() carries objs")
	eq(st["objs"]["d0_p"][0], "active", "objs state")
	near(float(st["objs"]["d0_p"][1]), 2.1, 0.0001, "objs progress rounded to 0.1")
	near(float(st["objs"]["d0_p"][2]), 20.0, 0.0001, "objs total")
	var c := _prules()
	c.apply_state(JSON.parse_string(JSON.stringify(st)))
	eq(c.state(), st, "plan state: JSON round trip")
	eq(c.text(), m.text(), "same text on the client")
	eq(c.lines(0), m.lines(0), "same lines")
	eq(c.markers(1), m.markers(1), "same markers")
	var c2 := _prules()
	c2.apply_state(bytes_to_var(var_to_bytes(st)))
	eq(c2.state(), st, "plan state: var_to_bytes round trip")
	# Size: real 5-deck plans with every objective mid-way.
	for seed_ in [1, 2, 3, 21]:
		var sec := SectionPlan.make({"seed": float(seed_), "decks": 5.0})
		var mp := MissionPlan.make(sec)
		var r := MissionRules.make(sec, {"plan": mp})
		var o := {}
		for ob: Dictionary in mp.objectives:
			o[ob["id"]] = ["active", 123.4, 360.0]
		r.apply_state({"objs": o, "left": [999, 999, 999, 999, 999], "done": []})
		var size := JSON.stringify(r.state()).length()
		print("plan state JSON, 5 decks seed %d: %d objectives, %d bytes" % [seed_, mp.objectives.size(), size])
		check(size < 1024, "plan state() under 1 KB for 5 decks (%d)" % size)
