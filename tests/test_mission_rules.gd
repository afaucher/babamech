extends TestCase
## MissionRules (docs/design/mission-objectives.md §9, docs/design/mission-section.md §14): one mode, the plan's
## objectives (user 2026-11-25 "Cut the legacy modes."; the old clear + extract checks went with it). Here: make()
## without a plan builds the section's natural plan; the extraction zone; the crew-wipe loss (off by default; every
## loss case builds its rules with W), its grace, win before loss, the latched outcome; the client's apply_state with
## floats and missing keys; then the plan's objectives, the HUD lines and the objective panel.

const W := {"wipe": true}


func setup() -> void:
	_default_plan()
	_zones()
	_no_wipe_by_default()
	_outcomes()
	_round_trip()
	_plan_basics()
	_plan_flag()
	_plan_defend()
	_plan_sweep_hold()
	_plan_hud()
	_plan_set_site()
	_plan_state()
	_plan_labels()
	_plan_flag_percent()
	_plan_next_floor()
	_panel_structure()
	_panel_coop()
	_panel_matrix()
	_panel_routes()
	_panel_states()
	_panel_fit()
	finish()


func _crew(downed: bool, deck: int = 0, x: float = 0.0, s: float = 0.0, peer: int = 1) -> Dictionary:
	return {"peer": peer, "downed": downed, "deck": deck, "x": x, "s": s}


func _zeros(n: int) -> Array:
	var a := []
	a.resize(n)
	a.fill(0)
	return a


## A section always has a mission plan: make(sec) without one evaluates MissionPlan.make(sec)'s objectives.
func _default_plan() -> void:
	for seed_ in [1, 4, 9]:
		var sec := SectionPlan.make({"seed": float(seed_), "decks": 3.0})
		var m := MissionRules.make(sec)
		var tag := "seed %d" % seed_
		if not check(m.plan != null, tag + ": make() without a plan builds one"):
			continue
		eq(m.plan.checksum(), MissionPlan.make(sec).checksum(), tag + ": the section's natural plan")
		var ids := []
		for o: Dictionary in m.objectives:
			ids.append(o["id"])
		var want := []
		for o: Dictionary in m.plan.objectives:
			want.append(o["id"])
		eq(ids, want, tag + ": the plan's objectives, nothing else")
		check(not ids.has("extract") and not ids.has("clear_0"), tag + ": no clear / extract objectives")
		check(not m.options.has("extract") and not m.options.has("zone_depth"), tag + ": no clear-and-extract options")
		eq(m.objective("hold").get("type", ""), "hold", tag + ": the extraction hold is last")


## The extraction zone (the hold's zone: MissionPlan, MissionWorld): across the spine, ZONE_DEPTH m in from the wall.
func _zones() -> void:
	for decks in [2, 3, 5]:
		for seed_ in [1, 4, 9, 17, 23]:
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var tag := "decks %d seed %d" % [decks, seed_]
			var k: int = sec.extraction["deck"]
			_check_zone(sec, MissionRules.extraction_zone(sec, MissionRules.ZONE_DEPTH), MissionRules.ZONE_DEPTH, tag)
			_check_zone(sec, MissionRules.extraction_zone(sec, 25.0), 25.0, tag + " depth 25")
			var huge := MissionRules.extraction_zone(sec, 1.0e6)
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


## A 2-deck plan with one primary: a sweep on deck 0 (active once a standing mech is on deck 0, done at 0 alive).
func _sweep_plan() -> MissionPlan:
	var mp := MissionPlan.new()
	mp.deck_count = 2
	mp.objectives = [{"id": "d0_p", "type": "sweep", "deck": 0, "role": "primary", "site": {"x": 0.0, "s": 0.0},
		"radius": 0.0, "needs": [], "params": {}}]
	return mp


func _wrules(sec: SectionPlan, opts: Dictionary = {}) -> MissionRules:
	var o := opts.duplicate()
	o["plan"] = _sweep_plan()
	return MissionRules.make(sec, o)


func _no_wipe_by_default() -> void:
	var sec := SectionPlan.make({"seed": 3.0, "decks": 2.0})
	var down := [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	check(not bool(MissionRules.make(sec).options["wipe"]), "wipe is off by default")
	# With t: all downed for a long time.
	var m := _wrules(sec)
	m.evaluate({"t": 0.0, "enemies": [2, 2], "crew": down})
	for t in [0.5, 1.0, 5.0, 60.0, 600.0]:
		check(not m.evaluate({"t": t, "enemies": [2, 2], "crew": down}), "wipe off, all down at t %s: no change" % t)
		eq(m.outcome, "", "wipe off, all down at t %s: not lost" % t)
		eq(m._wipe_t, -1.0, "wipe off: no countdown at t %s" % t)
	# Without t (would be immediate with wipe on).
	var nt := _wrules(sec)
	nt.evaluate({"enemies": [2, 2], "crew": down})
	for i in 5:
		check(not nt.evaluate({"enemies": [2, 2], "crew": down}), "wipe off, all down, no t: no change")
	eq(nt.outcome, "", "wipe off, no t: not lost")
	var solo := _wrules(sec)
	solo.evaluate({"enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "", "wipe off, solo downed: not lost")
	check(solo.text().begins_with("Clear deck 1: 1 hostile"), "wipe off: the HUD keeps the objective (%s)" % solo.text())
	# The mission can still be won afterwards: a downed mech never activates the sweep, a standing one does.
	for r: MissionRules in [m, nt]:
		r.evaluate({"t": 700.0, "enemies": [0, 0], "crew": down})
		eq(r.outcome, "", "all clear but nobody standing: the sweep never went active")
		r.evaluate({"t": 702.0, "enemies": [0, 0], "crew": [_crew(false, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]})
		eq(r.outcome, "won", "wipe off: won after a long wipe")
		eq(r.reason, "objectives", "wipe off: win reason")


func _outcomes() -> void:
	var sec := SectionPlan.make({"seed": 3.0, "decks": 2.0})
	# Lost: all downed.
	var m := _wrules(sec, W)
	m.evaluate({"enemies": [2, 2], "crew": [_crew(false, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]})
	eq(m.outcome, "", "one standing: not lost")
	check(m.evaluate({"enemies": [2, 2], "crew": [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]}), "loss is a change")
	eq(m.outcome, "lost", "all downed: lost")
	eq(m.reason, "crew_down", "reason")
	eq(m.text(), "Crew down", "lost text")
	# Latched.
	check(not m.evaluate({"enemies": [0, 0], "crew": [_crew(false)]}), "after the outcome nothing changes")
	eq(m.outcome, "lost", "outcome latched")
	eq(m.left_on(0), 2, "counts frozen too")
	check(not m.is_done("d0_p"), "objectives frozen too")
	# Solo downed.
	var solo := _wrules(sec, W)
	solo.evaluate({"enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "lost", "solo downed: lost")
	# Empty crew.
	var empty := _wrules(sec, W)
	empty.evaluate({"enemies": [1, 1], "crew": []})
	empty.evaluate({"enemies": [1, 1]})
	eq(empty.outcome, "", "an empty crew never loses")
	# Win beats loss in the same call (the sweep went active, its last enemy dies while all are downed).
	var w := _wrules(sec, W)
	w.evaluate({"enemies": [1, 1], "crew": [_crew(false)]})
	eq(w.outcome, "", "not yet")
	check(w.evaluate({"enemies": [0, 0], "crew": [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]}), "change")
	eq(w.outcome, "won", "win beats loss")
	eq(w.reason, "objectives", "win reason")
	eq(w.text(), "Mission complete", "won text")
	check(not w.evaluate({"enemies": [3, 3], "crew": [_crew(true)]}), "won is latched")
	eq(w.outcome, "won", "still won")
	_grace(sec)


func _grace(sec: SectionPlan) -> void:
	var down := [_crew(true, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	var up := [_crew(false, 0, 0, 0, 1), _crew(true, 0, 0, 0, 2)]
	var m := _wrules(sec, W)
	m.evaluate({"t": 9.0, "enemies": [2, 2], "crew": up})
	check(not m.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down}), "the wipe countdown is not a state change")
	eq(m.outcome, "", "all down at 10.0: not lost yet")
	check(not m.evaluate({"t": 10.9, "enemies": [2, 2], "crew": down}), "10.9: no change")
	eq(m.outcome, "", "not lost at 10.9")
	check(m.evaluate({"t": 11.0, "enemies": [2, 2], "crew": down}), "11.0: loss is a change")
	eq(m.outcome, "lost", "lost at 11.0")
	# A revive resets the countdown.
	var r := _wrules(sec, W)
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
	var e := _wrules(sec, W)
	e.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down})
	e.evaluate({"t": 10.5, "enemies": [2, 2], "crew": []})
	e.evaluate({"t": 11.2, "enemies": [2, 2], "crew": down})
	eq(e.outcome, "", "an empty crew resets the countdown")
	# No t, or no grace: immediate.
	var nt := _wrules(sec, W)
	nt.evaluate({"enemies": [2, 2], "crew": down})
	eq(nt.outcome, "lost", "no t: immediate loss")
	var g0 := _wrules(sec, {"wipe_grace": 0.0, "wipe": true})
	g0.evaluate({"t": 10.0, "enemies": [2, 2], "crew": down})
	eq(g0.outcome, "lost", "wipe_grace 0: immediate loss")
	var solo := _wrules(sec, W)
	solo.evaluate({"t": 5.0, "enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "", "solo downed: inside the grace")
	solo.evaluate({"t": 6.0, "enemies": [1, 1], "crew": [_crew(true)]})
	eq(solo.outcome, "lost", "solo downed: lost after the grace")
	var empty := _wrules(sec, W)
	for t in [0.0, 5.0, 50.0]:
		empty.evaluate({"t": t, "enemies": [1, 1], "crew": []})
	eq(empty.outcome, "", "an empty crew never loses (with t)")
	# Win beats loss inside the grace window.
	var w := _wrules(sec, W)
	w.evaluate({"t": 9.0, "enemies": [1, 1], "crew": up})
	w.evaluate({"t": 10.0, "enemies": [1, 1], "crew": down})
	eq(w.outcome, "", "all down, grace running")
	w.evaluate({"t": 10.4, "enemies": [0, 0], "crew": down})
	eq(w.outcome, "won", "the last enemy dies inside the grace: won")


## A client's apply_state: floats where ints were, unknown ids and missing keys.
func _round_trip() -> void:
	var c := _prules()
	c.apply_state({"left": [2.0, 1.0], "done": ["d0_p", "bogus"]})
	eq(c.left_on(0), 2, "float counts become ints")
	eq(c.left_on(2), 0, "short left pads with 0")
	check(c.is_done("d0_p") and not c.is_done("bogus"), "only known ids are applied")
	eq(c.outcome, "", "missing outcome leaves it")
	c.apply_state({})
	eq(c.left_on(0), 2, "an empty dict changes nothing")
	c.apply_state({"outcome": "lost", "reason": "crew_down"})
	eq(c.text(), "Crew down", "mirrored loss")


# --- The plan's objectives (docs/design/mission-objectives.md §9) ----------------------------------------------------------

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
	# make() without a plan: the section's natural plan, the default options.
	var plain := MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0}))
	check(plain.state().has("objs"), "the natural plan: objs in state()")
	eq(plain.options, MissionRules.DEFAULTS, "no overrides: the default options")


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
	eq(m.text(), "Raise the flag: 5%", "text: the flag (1 of 20 s = 5 %)")
	eq(m.lines(0), ["Raise the flag: 5%"] as Array[String], "lines: only known objectives (bonus still hidden)")
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
		eq(lines[1], "Bonus: Raise the flag: 0%", "bonus line, after the primary")
	eq(m.markers(0).size(), 2, "and a marker")
	var t := 2.0
	for i in 22:
		t += 1.0
		m.evaluate({"t": t, "crew": [_crew(false, 0, 0.0, 150.0)], "enemies": [1, 1, 0]})
	eq(m.lines(0)[0], "Proceed to deck 2", "primary done: the deck's first line points to deck 2")
	eq(m.lines(0)[1], "Raise the flag: 100% (done)", "done line")
	for o: Dictionary in m.markers(0):
		check(o["id"] != "d0_p", "no marker for a done objective")
	eq(m.text(), "Proceed to deck 2", "text: proceed while the crew is still on deck 1")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 1, 0.0, 0.0)], "enemies": [1, 1, 0], "waves": wv})
	eq(m.text(), "Clear deck 2: 1 hostile, waves 1 / 3", "on deck 2: text moves to the next primary")


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
	var before := str(d.objectives)
	d.set_site("nope", 1.0, 1.0)
	eq(str(d.objectives), before, "an unknown id: set_site ignored")


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
	check(st.has("reached"), "state() carries reached")

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


## Every objective line reads as a sentence in every state, for every type and role: no "?", no empty name, no raw id,
## no placeholder; an undiscovered bonus is not listed; the HUD font has every glyph (lines are drawn upper-cased).
func _plan_labels() -> void:
	var font := ThemeDB.fallback_font
	var missing := {}
	for st: String in ["hidden", "known", "active", "done", "failed"]:
		for prog: float in [0.0, 7.0, 20.0]:
			var m := _prules()
			var objs := {}
			for o: Dictionary in m.objectives:
				var tot := 60.0 if o["type"] == "hold" else (20.0 if o["type"] == "flag" else 2.0)
				objs[o["id"]] = [st, minf(prog, tot), tot]
			m.apply_state({"objs": objs, "left": [3, 1, 0], "reached": 0})
			var tag := "labels %s prog %.0f" % [st, prog]
			for k in 3:
				var ls := m.lines(k)
				if st == "hidden":
					for l in ls:
						check(not l.begins_with("Bonus"), tag + ": a hidden bonus is not listed (%s)" % l)
				var all: Array[String] = ls.duplicate()
				all.append(m.text())
				for l in ls:
					check(l.strip_edges() != "", tag + ": deck %d: no empty line" % k)
				check(m.text() != "" or m.current() == "", tag + ": a text while an objective is current")
				for l in all:
					if l == "":
						continue
					check(not l.contains("?"), tag + ": no '?' in %s" % l)
					check(not l.contains("%s") and not l.contains("%d") and not l.contains("  "), tag + ": no placeholder in %s" % l)
					check(not l.contains("d0_") and not l.contains("d1_") and not l.contains("d2_") and l != "hold",
						tag + ": no raw id in %s" % l)
					check(not l.contains(": :") and not l.ends_with(":") and not l.begins_with(":"), tag + ": no empty name in %s" % l)
					for ch in (l + l.to_upper()):
						if not font.has_char(ch.unicode_at(0)):
							missing[ch] = true
	eq(missing.keys(), [], "the HUD font has every glyph the objective lines use")
	# The world markers' labels (MissionFlow): plain words, no "?".
	for ty: String in MissionHudModel.MARK_LABEL:
		var lab := str(MissionHudModel.MARK_LABEL[ty])
		check(not lab.contains("?") and lab != "", "marker label %s" % lab)


## The flag line shows its capture as a whole percent, never seconds; 100 % only once done.
func _plan_flag_percent() -> void:
	var re := RegEx.create_from_string("\\d+\\s*s\\b|/")
	for c: Array in [["known", 0.0, "0%"], ["active", 0.0, "0%"], ["active", 7.0, "35%"], ["active", 19.9, "99%"],
			["active", 20.0, "99%"], ["done", 20.0, "100%"], ["failed", 3.0, "15%"]]:
		var m := _prules()
		m.apply_state({"objs": {"d0_p": [c[0], c[1], 20.0], "d0_b1": [c[0], c[1], 20.0]}, "reached": 0})
		var ls := m.lines(0)
		var line := ""
		var b := ""
		for l in ls:
			if l.begins_with("Raise the flag"):
				line = l
			elif l.begins_with("Bonus: Raise the flag"):
				b = l
		var tag := "flag %s %.1f s" % [c[0], c[1]]
		check(line.begins_with("Raise the flag: " + str(c[2])), tag + ": '%s' shows %s" % [line, c[2]])
		check(line.contains("%"), tag + ": a percent")
		check(re.search(line) == null, tag + ": no seconds figure (%s)" % line)
		check(b.begins_with("Bonus: Raise the flag: " + str(c[2])) and re.search(b) == null, tag + ": the bonus flag too (%s)" % b)
	eq(MissionRules.flag_percent(20.0, 20.0, false), 99, "full but not done: 99 %")
	eq(MissionRules.flag_percent(10.0, 20.0, false), 50, "half: 50 %")
	eq(MissionRules.flag_percent(0.0, 0.0, false), 0, "no total: 0 %")
	# Time limits keep seconds: the hold counts down.
	var h := _prules()
	h.apply_state({"objs": {"hold": ["active", 18.0, 60.0]}})
	var hl := ""
	for l in h.lines(2):
		if l.begins_with("Hold"):
			hl = l
	eq(hl, "Hold the extraction portal: 42 s", "the hold stays a countdown in seconds")


## "Proceed to deck n" from a deck's primary done until a standing crew mech reaches the next deck; host and
## client read the same from the replicated state; the extraction deck points to the hold instead.
func _plan_next_floor() -> void:
	var m := _prules()
	var on := [_crew(false, 0, 0.0, 150.0)]
	var t := 0.0
	m.evaluate({"t": t, "crew": on, "enemies": [0, 4, 0]})
	check(m.text().begins_with("Raise the flag"), "before: the flag")
	check(not m.lines(0).has("Proceed to deck 2"), "before: no proceed line")
	for i in 22:
		t += 1.0
		m.evaluate({"t": t, "crew": on, "enemies": [0, 4, 0]})
	eq(m.obj_state("d0_p"), "done", "flag done")
	eq(m.text(), "Proceed to deck 2", "primary done, crew on deck 1: proceed")
	eq(m.lines(0)[0], "Proceed to deck 2", "deck 1's list says it first")
	var c := _prules()
	c.apply_state(JSON.parse_string(JSON.stringify(m.state())))
	eq(c.text(), "Proceed to deck 2", "the client reads the same from the state")
	eq(c.lines(0), m.lines(0), "same lines on the client")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(true, 1, 0.0, 0.0)], "enemies": [0, 4, 0]})
	eq(m.text(), "Proceed to deck 2", "a downed mech on deck 2 has not reached it")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 1, 0.0, 0.0)], "enemies": [0, 4, 0]})
	check(m.text().begins_with("Clear deck 2"), "crew on deck 2: its objective (%s)" % m.text())
	c.apply_state(JSON.parse_string(JSON.stringify(m.state())))
	eq(c.text(), m.text(), "the client follows")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 0, 0.0, 0.0)], "enemies": [0, 4, 0]})
	check(m.text().begins_with("Clear deck 2"), "reached latches: back on deck 1, still deck 2's objective")
	# Extraction deck: its primary done while deck 2's sweep is not: return to it; all done: the hold, no next floor.
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 2, 0.0, 100.0)], "enemies": [0, 4, 0],
		"defend_waves": {"d2_p": {"released": 0, "total": 0, "alive": 0}}})
	eq(m.obj_state("d2_p"), "done", "deck 3's defend done")
	eq(m.lines(2)[0], "Return to deck 2: objective unfinished", "extraction deck, hold waiting: return line")
	check(not " ".join(m.lines(2)).contains("Proceed"), "no proceed line on the extraction deck")
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 1, 0.0, 0.0)], "enemies": [0, 0, 0], "waves_left": [0, 0, 0]})
	eq(m.obj_state("d1_p"), "done", "sweep done")
	eq(m.lines(1)[0], "Proceed to deck 3", "deck 2 done: proceed to deck 3")
	eq(m.obj_state("hold"), "known", "the hold appears")
	check(m.lines(2)[0].begins_with("Hold the extraction portal"), "extraction deck: the hold's line first (%s)" % m.lines(2)[0])
	check(m.text().begins_with("Hold the extraction portal"), "text: the hold (the crew has been on deck 3)")


# --- The objective panel (MissionRules.panel: docs/design/mission-objectives.md §9 "Objective panel") ------------

## All the text a panel shows (header, every line).
func _panel_texts(pn: Dictionary) -> Array[String]:
	var out: Array[String] = [str(pn["header"])]
	for l: Dictionary in pn["lines"]:
		out.append(str(l["text"]))
	return out


## The panel's lines as [text] (optionally only those of `part`).
func _ptexts(pn: Dictionary, part: String = "") -> Array:
	var out: Array = []
	for l: Dictionary in pn["lines"]:
		if part == "" or l["part"] == part:
			out.append(str(l["text"]))
	return out


## The first line whose text begins with `head`, {} none.
func _pline(pn: Dictionary, head: String) -> Dictionary:
	for l: Dictionary in pn["lines"]:
		if str(l["text"]).begins_with(head):
			return l
	return {}


## "ramp down 120 m" for route() of deck k from `at` toward dir, "" when there is no way.
func _route_text(m: MissionRules, k: int, at: Vector2, dir: int) -> String:
	return str(m.route(k, at, dir).get("text", ""))


## The fake 3-deck plan through a run: the start, a found bonus, the primary done, arrival on deck 2, deck 3 with deck
## 1's bonus left, the return line, finished decks, the outcome, plain mode.
func _panel_structure() -> void:
	var m := _prules()
	var at := Vector2(0.0, 0.0)
	var down := _route_text(m, 0, at, 1)
	check(down != "", "the fake section has a way down from deck 1 (%s)" % down)
	# Deck 1 of 3 at the start: the flag, then "Proceed to deck 2" (dim, last) and its route hint; deck 2 / 3 unlisted.
	var pn := m.panel(0, at)
	eq(str(pn["header"]), "DECK 1 of 3", "panel header on deck 1")
	eq(_ptexts(pn), ["Raise the flag: 0%", "Proceed to deck 2", down], "deck 1 at the start: the flag, then proceed")
	eq(_pline(pn, "Proceed")["role"], "next", "the proceed line's role")
	eq(_pline(pn, "Proceed")["part"], "tail", "primary to do: the proceed line trails")
	eq(_pline(pn, down)["role"], "route", "the route hint's role")
	eq((pn["route_at"] as Dictionary), {}, "no waypoint while the proceed line trails")
	for s in _panel_texts(pn):
		check(not s.contains("Clear deck") and not s.contains("Defend"), "unvisited decks' objectives are not listed (%s)" % s)
	check(not MissionRules.make(SectionPlan.make({"seed": 5.0, "decks": 3.0})).panel(0, at).is_empty(),
		"the natural plan has a panel too")
	# A found bonus is listed (optional), before the proceed line.
	m.evaluate({"t": 0.0, "crew": [_crew(false, 0, 100.0, -100.0)], "enemies": [1, 5, 0]})
	pn = m.panel(0, at)
	eq(_ptexts(pn), ["Raise the flag: 0%", "Raise the flag: 0% (optional)", "Proceed to deck 2", down],
		"the found bonus reads (optional), the proceed line stays last")
	eq(pn["lines"][1]["role"], "bonus", "the bonus's role")
	# Deck 1's primary done: "Proceed to deck 2" leads (amber), its route under it, the waypoint goes there.
	var on := [_crew(false, 0, 0.0, 150.0)]
	var t := 0.0
	for i in 22:
		t += 1.0
		m.evaluate({"t": t, "crew": on, "enemies": [0, 5, 0]})
	pn = m.panel(0, at)
	eq(_ptexts(pn), ["Proceed to deck 2", down, "Raise the flag: 100% (done)",
		"Defend the position: wave 1 / 2 (optional)", "Raise the flag: 0% (optional)"], "primary done: proceed first")
	eq(pn["lines"][0]["part"], "lead", "the proceed line leads")
	eq(pn["lines"][1]["part"], "lead", "with its route hint")
	eq(pn["route_at"], m.route(0, at, 1), "route_at: the way down while the proceed line leads")
	eq(m.text(), "Proceed to deck 2", "text(): proceed with the deck number")
	eq(m.lines(0)[0], "Proceed to deck 2", "lines(): proceed with the deck number")
	# Arrival on deck 2: its objectives open up; deck 1's two found bonuses: one line; proceed to deck 3 trails.
	t += 1.0
	m.evaluate({"t": t, "crew": [_crew(false, 1, 0.0, 0.0)], "enemies": [0, 5, 0]})
	pn = m.panel(1, at)
	eq(str(pn["header"]), "DECK 2 of 3", "panel header on deck 2")
	eq(_ptexts(pn, "here"), ["Clear deck 2: 5 hostiles", "Defend the position: wave 1 / 3 (optional)"],
		"on arrival deck 2's list opens (its bonus found 50 m away)")
	var tail := _ptexts(pn, "tail")
	eq(tail[0], "Proceed to deck 3", "deck 2's primary to do: proceed to deck 3 trails first")
	check(tail.has("Deck 1: 2 optional left"), "deck 1's found bonuses: one line (%s)" % [tail])
	eq(_pline(pn, "Deck 1")["role"], "deck", "an optional-only deck's role")
	var up := _route_text(m, 1, at, -1)
	eq(tail.has(up), up != "", "the way up only when a ramp up exists (%s)" % up)
	for s in _panel_texts(pn):
		check(not s.contains("Defend the position: wave 1 / 2") or s.begins_with("Deck"), "deck 3's defend not listed (%s)" % s)
	# Deck 3, deck 1's far bonus left, deck 2 finished: one line for deck 1, nothing for deck 2, no proceed (last deck).
	var d3 := _prules()
	d3.apply_state({"objs": {"d0_p": ["done", 20.0, 20.0], "d0_b0": ["done", 2.0, 2.0], "d0_b1": ["known", 0.0, 20.0],
		"d1_p": ["done", 0.0, 0.0], "d2_p": ["active", 0.0, 2.0]}, "reached": 2})
	pn = d3.panel(2, at)
	eq(_ptexts(pn, "here"), ["Defend the position: wave 1 / 2"], "deck 3's list (the hold hidden)")
	var l3 := _ptexts(pn, "tail")
	eq(l3[0], "Deck 1: 1 optional left", "deck 1's bonus: one line")
	check(l3.size() <= 2, "and its route hint only (%s)" % [l3])
	for s in _panel_texts(pn):
		check(not s.contains("Deck 2") and not s.contains("deck 2:") and not s.contains("Proceed"), "deck 2 done, no proceed (%s)" % s)
	# The return line: deck 3's primary done while deck 2's is not: it leads, amber, with the way up.
	var r := _prules()
	r.apply_state({"objs": {"d0_p": ["done", 20.0, 20.0], "d2_p": ["done", 2.0, 2.0]}, "reached": 2})
	pn = r.panel(2, at)
	eq(pn["lines"][0]["text"], "Return to deck 2: objective unfinished", "the return line first")
	eq(pn["lines"][0]["role"], "return", "the return line's role")
	eq(pn["lines"][0]["part"], "lead", "it leads once this deck's primary is done")
	var up3 := _route_text(r, 2, at, -1)
	if up3 != "":
		eq(pn["lines"][1]["text"], up3, "the way up under it")
		eq(int(pn["route_at"]["dir"]), -1, "the waypoint points up")
	r.apply_state({"objs": {"d2_p": ["active", 0.0, 2.0]}})
	pn = r.panel(2, at)
	eq(pn["lines"][0]["part"], "here", "this deck's primary to do: its list first")
	eq(_pline(pn, "Return")["part"], "tail", "the return line trails")
	# Finished decks contribute nothing.
	var f := _prules()
	f.apply_state({"objs": {"d0_p": ["done", 20.0, 20.0], "d0_b1": ["done", 20.0, 20.0], "d0_b0": ["done", 2.0, 2.0]},
		"reached": 1})
	for s in _panel_texts(f.panel(1, at)):
		check(not s.contains("Deck 1") and not s.contains("deck 1"), "a finished deck has no line (%s)" % s)
	# The outcome: this deck's list only.
	var o := _prules()
	o.apply_state({"outcome": "lost", "reason": "objective_failed", "objs": {"d0_p": ["failed", 2.0, 20.0]}, "reached": 0})
	eq(_ptexts(o.panel(0, at)), ["Raise the flag: 10% (failed)"], "after the outcome: this deck's list only")


## Co-op: `reached` is the crew's, the viewer's deck is local. A pilot still on deck 1 while a crewmate stands on deck 2
## sees "Deck 2: n objectives left" (visited by the crew) with the way down, never "Proceed to deck 3"; on arrival the
## full list; deck 2's primary done but a bonus left: that deck line plus "Proceed to deck 3".
func _panel_coop() -> void:
	var m := _prules()
	var at := Vector2(0.0, 0.0)
	var down := _route_text(m, 0, at, 1)
	m.apply_state({"objs": {"d1_b0": ["known", 0.0, 3.0]}, "reached": 1})
	var pn := m.panel(0, at)
	eq(_ptexts(pn), ["Raise the flag: 0%", "Deck 2: 1 objective, 1 optional left", down],
		"behind the crew: deck 2's line and the way down")
	eq(_pline(pn, "Deck 2")["role"], "next", "a visited deck below with a primary left reads like proceed")
	eq(_pline(pn, "Deck 2")["part"], "tail", "and trails while deck 1's primary is to do")
	m.apply_state({"objs": {"d0_p": ["done", 20.0, 20.0]}})
	pn = m.panel(0, at)
	eq(_ptexts(pn).slice(0, 2), ["Deck 2: 1 objective, 1 optional left", down], "deck 1 done: it leads")
	eq(pn["route_at"], m.route(0, at, 1), "the waypoint points at the way down")
	eq(_ptexts(m.panel(1, at), "here"), ["Clear deck 2: 0 hostiles", "Defend the position: wave 1 / 3 (optional)"],
		"on arrival: deck 2's full list")
	m.apply_state({"objs": {"d1_p": ["done", 0.0, 0.0]}})
	pn = m.panel(0, at)
	eq(_ptexts(pn).slice(0, 2), ["Proceed to deck 3", down], "deck 2's primary done: proceed to the next unvisited deck")
	check(_ptexts(pn).has("Deck 2: 1 optional left"), "deck 2's bonus: one line (%s)" % [_ptexts(pn)])
	# Two crews' views from one replicated state: the pilot on deck 2 sees deck 2's list, the one behind sees its line.
	var c := _prules()
	c.apply_state(JSON.parse_string(JSON.stringify(m.state())))
	eq(c.panel(0, at), m.panel(0, at), "the behind pilot's panel on a client = on the host")
	eq(c.panel(1, at), m.panel(1, at), "the front pilot's panel on a client = on the host")


## 2-, 3- and 5-deck sections (generated plans), every viewer deck, every `reached`, this deck's primary to do and done:
## unvisited decks contribute exactly one "Proceed to deck n" line (only when no visited deck below has a primary left)
## and none of their objectives; this deck's lines are this deck's; each visited deck with something left has exactly
## one line; route hints right under the first line each way, only via a walkable connector; no prefixes, no "?".
func _panel_matrix() -> void:
	var at := Vector2(30.0, -60.0)
	for n: int in [2, 3, 5]:
		var sec := SectionPlan.make({"seed": 21.0, "decks": float(n)})
		var m := MissionRules.make(sec, {"plan": MissionPlan.make(sec)})
		eq(m.deck_count, n, "%d-deck plan" % n)
		var base := {}
		for o: Dictionary in m.objectives:
			base[o["id"]] = ["known", 0.0, 20.0]
		for v in n:
			for reached in range(-1, n):
				for vdone: bool in [false, true]:
					var objs := base.duplicate()
					var vp := m.plan.primary(v)
					if vdone and not vp.is_empty():
						objs[vp["id"]] = ["done", 20.0, 20.0]
					m.apply_state({"objs": objs, "reached": reached})
					var tag := "%d decks, viewer deck %d, reached %d, primary %s" % [n, v + 1, reached, "done" if vdone else "to do"]
					_matrix_case(m, sec, v, reached, vdone, at, tag)


func _matrix_case(m: MissionRules, sec: SectionPlan, v: int, reached: int, vdone: bool, at: Vector2, tag: String) -> void:
	var n := m.deck_count
	var pn := m.panel(v, at)
	var ls: Array = pn["lines"]
	eq(str(pn["header"]), "DECK %d of %d" % [v + 1, n], tag + ": header")
	var open_to := maxi(reached, v)
	var proceed: Array = []
	var here_idx: Array = []
	var per_deck := {}
	for i in ls.size():
		var l: Dictionary = ls[i]
		var role := str(l["role"])
		var text := str(l["text"])
		check(text.strip_edges() != "" and not text.contains("?"), tag + ": text (%s)" % text)
		check(not text.begins_with("V1") and not text.begins_with("^") and not text.contains("▼") and not text.contains("▲")
			and not text.contains("–"), tag + ": no direction prefix (%s)" % text)
		if role == "primary" or role == "bonus":
			eq(int(l["deck"]), v, tag + ": this deck's lines only (%s)" % text)
			eq(l["part"], "here", tag + ": part of an objective line")
			here_idx.append(i)
		elif role == "route":
			var rx := RegEx.create_from_string("^(ramp|shaft|lift) (down|up) [0-9]+ m$")
			check(rx.search(text) != null, tag + ": route text without glyphs (%s)" % text)
			var dir := int(l["dir"])
			check(_way_exists(sec, v, dir), tag + ": a route hint only via a walkable way (%s)" % text)
			eq(text, _route_text(m, v, at, dir), tag + ": the route hint is route()")
			check(i > 0 and int(ls[i - 1]["dir"]) == dir and ls[i - 1]["role"] != "route", tag + ": right under a line its way")
			var first := -1
			for j in ls.size():
				if int(ls[j]["dir"]) == dir and ls[j]["role"] != "route" and ls[j]["part"] == ls[i]["part"]:
					first = j
					break
			eq(first, i - 1, tag + ": under the first line that way (%s)" % text)
		else:
			var d := int(l["deck"])
			if text.begins_with("Proceed"):
				proceed.append(i)
				eq(text, MissionRules.proceed_text(d), tag + ": proceed text")
			else:
				check(d <= open_to and d != v, tag + ": a deck line for a visited deck (%s)" % text)
				per_deck[d] = int(per_deck.get(d, 0)) + 1
	# Unvisited decks: one proceed line at most, never their objectives.
	check(proceed.size() <= 1, tag + ": one proceed line at most")
	var below_primary := false
	for d in range(v + 1, open_to + 1):
		below_primary = below_primary or not m.plan.primary(d).is_empty()
	var want_proceed := open_to + 1 < n and not below_primary
	eq(proceed.size() == 1, want_proceed, tag + ": a proceed line exactly when the next deck is unvisited")
	if proceed.size() == 1:
		var pl: Dictionary = ls[proceed[0]]
		eq(int(pl["deck"]), open_to + 1, tag + ": proceed to the first unvisited deck")
		if vdone:
			eq(proceed[0], 0, tag + ": primary done: the proceed line is first")
			eq(pl["part"], "lead", tag + ": and leads")
		else:
			eq(pl["part"], "tail", tag + ": primary to do: it trails")
			for i: int in here_idx:
				check(i < proceed[0], tag + ": after this deck's lines")
	# Visited decks with something left: exactly one line each; hidden bonuses aside, every deck here has its primary.
	for d in range(0, open_to + 1):
		if d == v:
			continue
		eq(int(per_deck.get(d, 0)), 1, tag + ": deck %d has one line" % (d + 1))


## The route hint: route() is the nearest way off the viewer's deck in that direction (down: a ramp mouth or a shaft that
## lands; up: a ramp foot only; never a locked or a lift connector while lifts don't ride), the distance along the deck
## rounded to 5 m, written "ramp down 120 m" (no glyph).
func _panel_routes() -> void:
	var seen := {}
	for n: int in [2, 3, 5]:
		for seed_: int in [1, 2, 3, 5, 8, 21]:
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(n)})
			var m := MissionRules.make(sec, {"plan": MissionPlan.make(sec)})
			for v in n:
				for at: Vector2 in [Vector2.ZERO, Vector2(60.0, -150.0), Vector2(-80.0, 220.0)]:
					var tag := "seed %d, %d decks, deck %d at %s" % [seed_, n, v + 1, at]
					for dir: int in [1, -1]:
						var rt := m.route(v, at, dir)
						eq(not rt.is_empty(), _way_exists(sec, v, dir), tag + ": a route exactly when a way %s exists" % ("down" if dir > 0 else "up"))
						if rt.is_empty():
							continue
						seen[rt["kind"]] = true
						check(rt["kind"] == "ramp" or (dir > 0 and rt["kind"] == "shaft"),
							tag + ": %s %s" % ["down" if dir > 0 else "up", rt["kind"]])
						var dist := int(rt["dist"])
						var real := at.distance_to(Vector2(float(rt["x"]), float(rt["s"])))
						check(dist >= 5 and dist % 5 == 0, tag + ": distance rounded to 5 (%d)" % dist)
						check(absf(real - float(dist)) <= 2.51 or (dist == 5 and real < 5.0), tag + ": the way's distance (%d, %.1f)" % [dist, real])
						eq(rt["text"], "%s %s %d m" % [rt["kind"], "down" if dir > 0 else "up", dist], tag + ": route text")
						eq(int(rt["deck"]), v, tag + ": measured on the viewer's deck")
						check(_nearest_ok(sec, v, at, dir, real), tag + ": the nearest way")
	check(seen.has("ramp"), "some route is a ramp (%s)" % [seen.keys()])
	print("panel route kinds seen: %s" % [seen.keys()])
	# Seed 9 (3 decks): shaft 0 -> 1 is stacked over shaft 1 -> 2 (an atrium dropping to deck 3); the hop-only repair
	# added a ramp 0 -> 1. From anywhere on deck 1 the way down is that ramp, never the stacked shaft, even standing on
	# the shaft's rim.
	var s9 := SectionPlan.make({"seed": 9.0, "decks": 3.0})
	var m9 := MissionRules.make(s9, {"plan": MissionPlan.make(s9)})
	var ramp9 := s9.walkable_down_connector(0)
	var atrium := -1
	for ci in s9.connectors.size():
		if s9.connectors[ci]["kind"] == "shaft" and int(s9.connectors[ci]["from"]) == 0 and not _lands(s9, ci):
			atrium = ci
	check(atrium >= 0, "seed 9: deck 1 has a stacked atrium shaft")
	check(ramp9 >= 0 and s9.connectors[ramp9]["kind"] == "ramp", "seed 9: the walkable way down from deck 1 is a ramp")
	var rc: Dictionary = s9.connectors[ramp9]
	var mouth := Vector2((float(rc["x0"]) + float(rc["x1"])) * 0.5, s9.line_s(0, int(rc["top_line"])))
	var rim := s9.connector_rect(atrium, 0).get_center() if atrium >= 0 else Vector2.ZERO
	for at: Vector2 in [Vector2.ZERO, rim, Vector2(60.0, -150.0), Vector2(-80.0, 220.0)]:
		var rt := m9.route(0, at, 1)
		eq(str(rt.get("kind", "")), "ramp", "seed 9 deck 1 at %s: the route line names the ramp" % at)
		check(Vector2(float(rt.get("x", INF)), float(rt.get("s", INF))).is_equal_approx(mouth), "seed 9 deck 1 at %s: at the new ramp's mouth" % at)


## A way off deck k in direction dir a mech can take now: down a ramp from k or a shaft from k whose drop lands on deck
## k+1 (not a stacked atrium: _lands); up a ramp to k.
func _way_exists(sec: SectionPlan, k: int, dir: int) -> bool:
	for ci in sec.connectors.size():
		var c: Dictionary = sec.connectors[ci]
		if bool(c["locked"]):
			continue
		if c["kind"] == "ramp" and ((dir > 0 and int(c["from"]) == k) or (dir < 0 and int(c["to"]) == k)):
			return true
		if c["kind"] == "shaft" and dir > 0 and int(c["from"]) == k and _lands(sec, ci):
			return true
	return false


## Shaft ci's drop lands on the deck below: its landing overlaps no floor hole (a ramp or shaft cut from that deck).
## Independent of SectionPlan.shaft_lands.
func _lands(sec: SectionPlan, ci: int) -> bool:
	var k := int(sec.connectors[ci]["to"])
	var land := sec.connector_rect(ci, k)
	for h in sec.connectors.size():
		var o: Dictionary = sec.connectors[h]
		if h != ci and o["kind"] != "lift" and int(o["from"]) == k and sec.connector_rect(h, k).intersects(land):
			return false
	return true


## No eligible way is closer than `d` (independent of route(): every ramp end / landing shaft centre on deck k).
func _nearest_ok(sec: SectionPlan, k: int, at: Vector2, dir: int, d: float) -> bool:
	for ci in sec.connectors.size():
		var c: Dictionary = sec.connectors[ci]
		if bool(c["locked"]):
			continue
		var p := Vector2(INF, INF)
		var lane := (float(c["x0"]) + float(c["x1"])) * 0.5
		if c["kind"] == "ramp" and dir > 0 and int(c["from"]) == k:
			p = Vector2(lane, sec.line_s(k, int(c["top_line"])))
		elif c["kind"] == "ramp" and dir < 0 and int(c["to"]) == k:
			p = Vector2(lane, sec.line_s(k, int(c["foot_line"])))
		elif c["kind"] == "shaft" and dir > 0 and int(c["from"]) == k and _lands(sec, ci):
			p = sec.connector_rect(ci, k).get_center()
		if p.is_finite() and at.distance_to(p) < d - 0.01:
			return false
	return true


## Every panel text reads as a sentence in every state and from every `reached` (no "?", empty name, raw id,
## placeholder, "V1" / "^1" prefix), the HUD font has every glyph the panel uses, and a client fed the host's state()
## (JSON and var_to_bytes) shows the same panel from every deck.
func _panel_states() -> void:
	var font := ThemeDB.fallback_font
	var missing := {}
	for st: String in ["hidden", "known", "active", "done", "failed"]:
		for reached in range(-1, 3):
			var m := _prules()
			var objs := {}
			for o: Dictionary in m.objectives:
				var tot := 60.0 if o["type"] == "hold" else (20.0 if o["type"] == "flag" else 2.0)
				objs[o["id"]] = [st, 7.0, tot]
			m.apply_state({"objs": objs, "left": [3, 1, 0], "reached": reached})
			for v in 3:
				var pn := m.panel(v, Vector2(10.0, 20.0))
				var tag := "panel %s reached %d deck %d" % [st, reached, v + 1]
				for s in _panel_texts(pn):
					check(s.strip_edges() != "", tag + ": no empty text")
					check(not s.contains("?"), tag + ": no '?' in %s" % s)
					check(not s.begins_with("V1") and not s.begins_with("V2") and not s.begins_with("^1"), tag + ": no prefix in %s" % s)
					check(not s.contains("%s") and not s.contains("%d") and not s.contains("  "), tag + ": no placeholder in %s" % s)
					check(not s.contains("d0_") and not s.contains("d1_") and not s.contains("d2_") and s != "hold",
						tag + ": no raw id in %s" % s)
					check(not s.ends_with(":") and not s.begins_with(":"), tag + ": no empty name in %s" % s)
					for ch in (s + s.to_upper()):
						if not font.has_char(ch.unicode_at(0)):
							missing[ch] = true
				for l: Dictionary in pn["lines"]:
					if st == "hidden":
						check(l["role"] != "bonus", tag + ": no hidden bonus listed (%s)" % l["text"])
	eq(missing.keys(), [], "the HUD font has every glyph the panel uses")
	# State round trip: the client's panel equals the host's from every deck (a hangar bot's negative id in the crew
	# changes nothing), the co-op case included (one pilot on deck 2, the viewer behind on deck 1).
	var h := _prules()
	var t := 0.0
	for i in 12:
		t += 1.0
		h.evaluate({"t": t, "crew": [_crew(false, 0, 0.0, 150.0), _crew(false, 1, 100.0, -100.0, -3)], "enemies": [2, 4, 1],
			"waves": [[1, 3], [0, 2], [0, 0]]})
	eq(h.state()["reached"], 1, "a crewmate on deck 2: reached")
	var cl := _prules()
	cl.apply_state(JSON.parse_string(JSON.stringify(h.state())))
	var cb := _prules()
	cb.apply_state(bytes_to_var(var_to_bytes(h.state())))
	for v in 3:
		eq(cl.panel(v, Vector2(5.0, -40.0)), h.panel(v, Vector2(5.0, -40.0)), "client panel = host panel (JSON), deck %d" % (v + 1))
		eq(cb.panel(v, Vector2(5.0, -40.0)), h.panel(v, Vector2(5.0, -40.0)), "client panel = host panel (var_to_bytes), deck %d" % (v + 1))


## MissionHud.panel_rows fits the panel to a row limit: the trailing route hints drop first (the last first), then the
## trailing "Deck n: ... left" lines, then this deck's done / failed lines, then the end is cut; the lead lines and the
## depot line stay.
func _panel_fit() -> void:
	var L := func(text: String, role: String, part: String, st: String = "") -> Dictionary:
		return {"text": text, "role": role, "state": st, "deck": 0, "dir": 0, "part": part}
	var pn := {"extra": ["Taking power core: 60%"], "lines": [
		L.call("Return to deck 1: objective unfinished", "return", "lead"), L.call("ramp up 80 m", "route", "lead"),
		L.call("Raise the flag: 40%", "primary", "here", "active"), L.call("Raise the flag: 100% (done)", "bonus", "here", "done"),
		L.call("Deck 3: 1 objective left", "next", "tail"), L.call("shaft down 90 m", "route", "tail"),
		L.call("Deck 2: 1 optional left", "deck", "tail")]}
	var all := MissionHud.panel_rows(pn, 99).map(func(r: Dictionary) -> String: return r["text"])
	eq(all, ["Return to deck 1: objective unfinished", "ramp up 80 m", "Raise the flag: 40%", "Raise the flag: 100% (done)",
		"Taking power core: 60%", "Deck 3: 1 objective left", "shaft down 90 m", "Deck 2: 1 optional left"],
		"rows: lead, this deck, the depot line, the tail")
	eq(MissionHud.panel_rows(pn, 7).map(func(r: Dictionary) -> String: return r["text"]), all.filter(func(t: String) -> bool: return t != "shaft down 90 m"),
		"too long: the trailing route hint drops first")
	eq(MissionHud.panel_rows(pn, 6).size(), 6, "then the optional-only deck line")
	check(not MissionHud.panel_rows(pn, 6).map(func(r: Dictionary) -> String: return r["text"]).has("Deck 2: 1 optional left"), "the deck line went")
	var five := MissionHud.panel_rows(pn, 5).map(func(r: Dictionary) -> String: return r["text"])
	eq(five, ["Return to deck 1: objective unfinished", "ramp up 80 m", "Raise the flag: 40%", "Taking power core: 60%",
		"Deck 3: 1 objective left"], "then this deck's done line; the lead lines and the depot line stay")
	eq(MissionHud.panel_rows(pn, 3).size(), 3, "then the end is cut")
