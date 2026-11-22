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
