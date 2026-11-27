class_name MissionRules
extends RefCounted
## The mission's objectives and end conditions, as a pure deterministic evaluator (no nodes, no network code, no
## randomness, no clock). docs/design/mission-objectives.md §9 (the objectives), docs/design/mission-section.md §14.
##
## ONE MODE (user 2026-11-25: "Cut the legacy modes."): the rules always evaluate a MissionPlan's objectives.
## `make(sec, {"plan": MissionPlan})`; without a plan, make() builds the section's natural plan (MissionPlan.make(sec)):
## a section always has a mission plan. (The old clear-every-deck-then-extract evaluator is gone.)
##
## The crew-wipe loss is built but OFF by default: `make(sec, {"plan": p, "wipe": true})` turns it on. With "wipe" on,
## the outcome is "lost" when the whole crew has stayed downed for "wipe_grace" seconds of facts.t (so a revive seen
## late over the link doesn't end the run; immediate without facts.t or with a grace <= 0). Win is checked first; an
## empty crew never loses. Everything done is latched, and once the outcome is set nothing changes any more.
##
## Who calls what: every machine builds the same rules with `make(sec, {plan})` (the plan derives from the seed). The
## HOST feeds facts to `evaluate()` and, whenever it returns true, broadcasts `state()`; CLIENTS never evaluate, they
## `apply_state()` what the host sent. Everyone reads `text()`, `marker()`, `panel()`, `outcome`.
##
## facts = {"t": float (host shared-clock seconds, only compared, optional),
##          "enemies": [int alive on deck k] (missing entries count as 0),
##          "crew": [{"peer": int, "downed": bool, "deck": int, "x": float, "s": float, "redeploying": bool (optional:
##                   held to respawn, DownedRules; a redeploying pilot keeps the wipe from firing)}]}
## Downed / revive / respawn (user decision 2026-11-24): there is no automatic respawn any more; with "wipe" on the
## mission is lost only when every pilot is down at the same time and nobody is redeploying.
## state = {"outcome": "" | "won" | "lost", "reason": String, "done": [ids in objective order], "left": [int per deck],
##          "current": first primary not done ("" when all done)}   survives JSON and var_to_bytes round trips
##
## OBJECTIVES (docs/design/mission-objectives.md §9). Each record is
## the plan's (id, type, deck, role, site, radius, needs, params) plus "kind" (= type) and, for the hold, "zone".
## Per objective: hidden | known | active | done | failed. Primaries start known, bonuses hidden until a standing mech on
## their deck comes within DISCOVER m; an objective whose needs are not all done stays hidden. Active (latched) once a
## standing mech is inside its radius (flag, defend), on its deck (sweep) or in the zone (hold). done / failed latch.
##   sweep   done when enemies[deck] == 0 and waves_left[deck] == 0, only once active
##   flag    progress += the t delta between evaluate calls (at most 1 s a call) while a standing mech is inside its
##           radius and zone_enemies[id] == 0; done at params.hold
##   defend  done when defend_waves[id].released == total and alive == 0; failed (while active) at assets[id] <= 0,
##           never on the evaluate it became active in (the asset is untargetable before and reset to full on
##           activation; from the next evaluate on, <= 0 fails it); progress = waves beaten. No defend_waves entry:
##           stays active
##   hold    progress like a flag (no enemy condition) while a standing mech is in params.zone; done at params.hold
## Outcome: a failed primary -> "lost" (reason "objective_failed"); every primary (hold included) done -> "won".
## Extra facts (all optional): "waves_left": [per deck] (PacingDirector.waves_left_all()), "zone_enemies": {id: n},
##   "assets": {id: hp 0..1}, "defend_waves": {id: {released, total, alive}} (PacingDirector.objective_waves()),
##   "waves": [[released, total] per deck] (PacingDirector.state().waves: the sweep's "waves 2 / 3").
## state() adds "objs": {id: [state, progress (0.1), total]} and "reached" (the deepest deck a standing crew mech has
## been on, latched); "current" is the first primary not done. text() reads "Proceed to deck n" (proceed_text) while the
## current objective's deck is deeper than "reached" (a deck's primary done, the crew not on the next deck yet). The flag line shows its
## capture as a whole percent (flag_percent: 100 % only once done); hold / defend keep seconds / waves.
## set_site(id, x, s): every machine, before the first evaluate, when the world snapped a mast / asset to clear ground.
## panel(viewer_deck, viewer_pos): the HUD's objective panel (header, this deck's list, "Proceed to deck n", one line per
## visited deck with something left, route hints), from the replicated state plus the viewer's local deck and position.

const DEFAULTS := {"wipe": false, "wipe_grace": 1.0}
const ZONE_DEPTH := 40.0         ## m: the extraction zone's depth in from the portal's end wall (extraction_zone)
const DISCOVER := 150.0          ## a bonus is found when a standing mech on its deck comes this close
const MAX_STEP := 1.0            ## most seconds of zone time one evaluate call can add
const ROUTE_ROUND := 5.0         ## m: a route line's distance is rounded to this
## The freight lifts don't carry mechs yet (their platforms are solid; BotRoutePlanner skips them too), so no route line
## names one. Turn on once a lift ride exists: then a lift serving a deck beyond counts, up or down.
const LIFTS_RIDE := false

var options: Dictionary = {}
var deck_count := 0
var objectives: Array[Dictionary] = []
var outcome := ""
var reason := ""
var plan: MissionPlan = null
var _done: Dictionary = {}       ## objective id -> true
var _left: Array[int] = []       ## enemies alive per deck, as last reported by the host
var _wipe_t := -1.0              ## host: facts.t when the whole crew went down (-1 = not all down)
var _st: Dictionary = {}         ## objective id -> hidden | known | active | done | failed
var _prog: Dictionary = {}       ## objective id -> progress
var _tot: Dictionary = {}        ## objective id -> total
var _last_t := -1.0              ## host: facts.t of the previous evaluate (-1 none)
var _reached := -1               ## the deepest deck a standing crew mech has been on (latched; -1 none yet)
var section: SectionPlan = null  ## the section plan (panel(): the connectors a route line names)


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission's settings, fixed at creation, same everywhere
		"deck_count": Net.LOCAL, "objectives": Net.LOCAL,     # recomputed from the section plan + options everywhere
		"plan": Net.LOCAL,           # the MissionPlan, derived from the seed on every machine
		"section": Net.LOCAL,        # the SectionPlan, derived from the seed on every machine
		# The mission's progress: the host writes it (evaluate) and broadcasts state(); clients only apply_state().
		"outcome": Net.OWNER, "reason": Net.OWNER, "_done": Net.OWNER, "_left": Net.OWNER,
		"_st": Net.OWNER, "_prog": Net.OWNER, "_tot": Net.OWNER, "_reached": Net.OWNER,
		"_wipe_t": Net.PRIVATE,      # the host's pending-wipe countdown, never sent (not in state())
		"_last_t": Net.PRIVATE,      # the host's zone-time clock, never sent
	}


## The rules of `overrides.plan` (a MissionPlan; without one, the section's natural plan MissionPlan.make(sec)).
## Other overrides: "wipe", "wipe_grace" (DEFAULTS); unknown keys are ignored.
static func make(sec: SectionPlan, overrides: Dictionary = {}) -> MissionRules:
	var m := MissionRules.new()
	m._init_common(sec, overrides)
	var p: Variant = overrides.get("plan", null)
	m._use_plan(p if p is MissionPlan else MissionPlan.make(sec))
	return m


## Options, deck count, section and the per-deck counts.
func _init_common(sec: SectionPlan, overrides: Dictionary) -> void:
	options = DEFAULTS.duplicate()
	for id: String in overrides:
		if options.has(id):
			options[id] = overrides[id]
	options["wipe"] = bool(options["wipe"])
	options["wipe_grace"] = float(options["wipe_grace"])
	deck_count = sec.deck_count
	section = sec
	_left.resize(sec.deck_count)
	_left.fill(0)


## The extraction zone on the extraction deck, in that deck's (x, s): across the whole transit spine corridor (its four
## lanes, centred on the spine line), `depth` metres in from the end wall the extraction portal is in. Clamped to the deck.
static func extraction_zone(sec: SectionPlan, depth: float) -> Rect2:
	var k := int(sec.extraction["deck"])
	var w := sec.p("width")
	var a := sec.arc_of(k)
	var x0 := maxf(sec.lane_x(str(SectionPlan.SPINE_LANES[0][0])).x, -w * 0.5)
	var x1 := minf(sec.lane_x(str(SectionPlan.SPINE_LANES[-1][0])).y, w * 0.5)
	var d := clampf(depth, 0.0, a)
	var s0 := -a * 0.5
	if int(sec.extraction["j"]) != 0:      # j == rows: the portal is in the s1 wall
		s0 = a * 0.5 - d
	return Rect2(x0, s0, x1 - x0, d)


# --- Host ------------------------------------------------------------------------------------------------

## Host only: update from the facts. True when state() changed.
func evaluate(facts: Dictionary) -> bool:
	if outcome != "":
		return false
	return _evaluate_plan(facts)


## The crew-wipe rule: with "wipe" on, lost once the whole crew has stayed downed for wipe_grace s.
func _check_wipe(facts: Dictionary, crew: Array) -> void:
	if options["wipe"] and not crew.is_empty() and _all_downed(crew):
		var grace := float(options["wipe_grace"])
		if not facts.has("t") or grace <= 0.0:
			_lose()
		else:
			var t := float(facts["t"])
			if _wipe_t < 0.0:
				_wipe_t = t
			if t - _wipe_t >= grace:
				_lose()
	else:
		_wipe_t = -1.0


# --- The plan's objectives --------------------------------------------------------------------------------------

func _use_plan(p: MissionPlan) -> void:
	plan = p
	for po: Dictionary in p.objectives:
		var o: Dictionary = po.duplicate(true)
		o["kind"] = o["type"]
		if o["type"] == "hold":
			o["zone"] = o["params"]["zone"]
		objectives.append(o)
		var id: String = o["id"]
		_st[id] = "known" if o["role"] == "primary" and (o["needs"] as Array).is_empty() else "hidden"
		_prog[id] = 0.0
		match str(o["type"]):
			"flag", "hold":
				_tot[id] = float(o["params"]["hold"])
			"defend":
				_tot[id] = float(o["params"]["waves"])
			_:
				_tot[id] = 0.0


## Every machine, before the first evaluate: the world moved this objective's site (a mast or an asset snapped to clear
## ground). Zone checks, discovery and markers use the new site. Unknown ids are ignored.
func set_site(id: String, x: float, s: float) -> void:
	var o := objective(id)
	if o.is_empty():
		return
	o["site"] = {"x": x, "s": s}


func _evaluate_plan(facts: Dictionary) -> bool:
	var before := state()
	var enemies: Array = facts.get("enemies", [])
	for k in deck_count:
		_left[k] = maxi(int(enemies[k]), 0) if k < enemies.size() and enemies[k] != null else 0
	var crew: Array = facts.get("crew", [])
	var wl: Array = facts.get("waves_left", []) if facts.get("waves_left", []) is Array else []
	var zone_en: Dictionary = facts.get("zone_enemies", {}) if facts.get("zone_enemies", {}) is Dictionary else {}
	var assets: Dictionary = facts.get("assets", {}) if facts.get("assets", {}) is Dictionary else {}
	var dw: Dictionary = facts.get("defend_waves", {}) if facts.get("defend_waves", {}) is Dictionary else {}
	var wv: Array = facts.get("waves", []) if facts.get("waves", []) is Array else []
	var dt := 0.0
	if facts.has("t"):
		var t := float(facts["t"])
		if _last_t >= 0.0:
			dt = clampf(t - _last_t, 0.0, MAX_STEP)
		_last_t = t
	for c: Variant in crew:
		if c is Dictionary and not bool(c.get("downed", false)):
			_reached = maxi(_reached, int(c.get("deck", -1)))
	for o: Dictionary in objectives:
		var id: String = o["id"]
		var k := int(o["deck"])
		var st: String = _st[id]
		if st == "done" or st == "failed":
			continue
		if not _needs_met(o):
			continue
		if o["type"] == "sweep":      # the HUD's "waves 2 / 3", known or not
			var e: Variant = wv[k] if k < wv.size() else null
			if e is Array and (e as Array).size() > 1:
				_prog[id] = float(e[0])
				_tot[id] = float(e[1])
		if st == "hidden" and (o["role"] == "primary" or _crew_within(o, crew, DISCOVER)):
			st = "known"
		var activated := false
		if st == "known":
			var on := false
			match str(o["type"]):
				"sweep":
					on = _crew_on(k, crew)
				"hold":
					on = _someone_in(o, crew)
				_:
					on = _crew_within(o, crew, float(o["radius"]))
			if on:
				st = "active"
				activated = true
		if st == "active":
			match str(o["type"]):
				"sweep":
					var left_w := maxi(int(wl[k]), 0) if k < wl.size() and wl[k] != null else 0
					if _left[k] == 0 and left_w == 0:
						st = "done"
				"flag":
					if _crew_within(o, crew, float(o["radius"])) and int(zone_en.get(id, 0)) <= 0:
						_prog[id] = float(_prog[id]) + dt
					if float(_prog[id]) >= float(_tot[id]):
						st = "done"
				"hold":
					if _someone_in(o, crew):
						_prog[id] = float(_prog[id]) + dt
					if float(_prog[id]) >= float(_tot[id]):
						st = "done"
				"defend":
					# Not on the evaluate it became active in: the asset is reset to full on activation (safety net).
					if not activated and float(assets.get(id, 1.0)) <= 0.0:
						st = "failed"
					elif dw.get(id, null) is Dictionary:
						var d: Dictionary = dw[id]
						var rel := int(d.get("released", 0))
						var total := int(d.get("total", 0))
						var al := int(d.get("alive", 0))
						_tot[id] = float(total)
						_prog[id] = float(rel if al == 0 else maxi(rel - 1, 0))
						if rel >= total and al == 0:
							st = "done"
		_st[id] = st
		if st == "done":
			_done[id] = true
	var failed := false
	var all_done := true
	for o: Dictionary in objectives:
		if o["role"] != "primary":
			continue
		if _st[o["id"]] == "failed":
			failed = true
		if _st[o["id"]] != "done":
			all_done = false
	if failed:
		outcome = "lost"
		reason = "objective_failed"
	elif all_done:
		outcome = "won"
		reason = "objectives"
	else:
		_check_wipe(facts, crew)
	return state() != before


func _crew_on(k: int, crew: Array) -> bool:
	for c: Dictionary in crew:
		if not bool(c.get("downed", false)) and int(c.get("deck", -1)) == k:
			return true
	return false


func _crew_within(o: Dictionary, crew: Array, r: float) -> bool:
	var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
	for c: Dictionary in crew:
		if bool(c.get("downed", false)) or int(c.get("deck", -1)) != int(o["deck"]):
			continue
		if at.distance_to(Vector2(float(c.get("x", INF)), float(c.get("s", INF)))) <= r:
			return true
	return false


## The objective's state (hidden | known | active | done | failed), "" for an unknown id.
func obj_state(id: String) -> String:
	return str(_st.get(id, ""))


func obj_progress(id: String) -> float:
	return float(_prog.get(id, 0.0))


## The objective's total (the progress that completes it), 0.0 for an unknown id.
func obj_total(id: String) -> float:
	return float(_tot.get(id, 0.0))


func _lose() -> void:
	outcome = "lost"
	reason = "crew_down"


func _needs_met(o: Dictionary) -> bool:
	for n: String in o["needs"]:
		if not _done.has(n):
			return false
	return true


func _someone_in(o: Dictionary, crew: Array) -> bool:
	var zone: Rect2 = o["zone"]
	for c: Dictionary in crew:
		if bool(c.get("downed", false)) or int(c.get("deck", -1)) != int(o["deck"]):
			continue
		var x := float(c.get("x", INF))
		var s := float(c.get("s", INF))
		if x >= zone.position.x and x <= zone.end.x and s >= zone.position.y and s <= zone.end.y:
			return true
	return false


## The whole crew is down at once and nobody is redeploying (a pilot who held to respawn is coming back: no wipe).
func _all_downed(crew: Array) -> bool:
	for c: Dictionary in crew:
		if not bool(c.get("downed", false)) or bool(c.get("redeploying", false)):
			return false
	return true


# --- State -----------------------------------------------------------------------------------------------

func state() -> Dictionary:
	var done: Array = []
	for o: Dictionary in objectives:
		if _done.has(o["id"]):
			done.append(o["id"])
	var left: Array = []
	for n in _left:
		left.append(n)
	var out := {"outcome": outcome, "reason": reason, "done": done, "left": left, "current": current()}
	var objs := {}
	for o: Dictionary in objectives:
		var id: String = o["id"]
		objs[id] = [_st[id], snappedf(float(_prog[id]), 0.1), snappedf(float(_tot[id]), 0.1)]
	out["objs"] = objs
	out["reached"] = _reached
	return out


## Clients: mirror the host's state() (ints may arrive as floats). Missing keys leave that part as it was.
func apply_state(d: Dictionary) -> void:
	if d.has("outcome"):
		outcome = str(d["outcome"])
	if d.has("reason"):
		reason = str(d["reason"])
	if d.has("done") and d["done"] is Array:
		_done.clear()
		for id: Variant in d["done"]:
			for o: Dictionary in objectives:
				if o["id"] == str(id):
					_done[o["id"]] = true
	if d.has("left") and d["left"] is Array:
		var src: Array = d["left"]
		for k in deck_count:
			_left[k] = int(src[k]) if k < src.size() and src[k] != null else 0
	if d.has("reached"):
		_reached = int(d["reached"])
	if d.get("objs", null) is Dictionary:
		var objs: Dictionary = d["objs"]
		for o: Dictionary in objectives:
			var id: String = o["id"]
			var e: Variant = objs.get(id, null)
			if not (e is Array) or (e as Array).size() < 3:
				continue
			_st[id] = str(e[0])
			_prog[id] = float(e[1])
			_tot[id] = float(e[2])
			if _st[id] == "done":
				_done[id] = true


func is_done(id: String) -> bool:
	return _done.has(id)


## Id of the first PRIMARY not done, "" when all are.
func current() -> String:
	for o: Dictionary in objectives:
		if o["role"] != "primary":
			continue
		if not _done.has(o["id"]):
			return o["id"]
	return ""


func left_on(k: int) -> int:
	return _left[k] if k >= 0 and k < _left.size() else 0


func objective(id: String) -> Dictionary:
	for o: Dictionary in objectives:
		if o["id"] == id:
			return o
	return {}


# --- HUD -------------------------------------------------------------------------------------------------

func text() -> String:
	if outcome == "won":
		return "Mission complete"
	if outcome == "lost":
		return "Objective failed" if reason == "objective_failed" else "Crew down"
	var o := objective(current())
	if o.is_empty():
		return ""
	# The previous deck's primary is done and nobody of the crew has reached this objective's deck yet.
	if _reached >= 0 and _reached < int(o["deck"]):
		return proceed_text(int(o["deck"]))
	return _line(o)


## Centre of the extraction hold's zone {deck, x, s} while the hold is the current objective and known, else {}.
func marker() -> Dictionary:
	var h := objective(current())
	if h.is_empty() or h["type"] != "hold" or _st[h["id"]] == "hidden":
		return {}
	var hc: Vector2 = (h["zone"] as Rect2).get_center()
	return {"deck": int(h["deck"]), "x": hc.x, "s": hc.y}


## For the HUD: one line per known objective on deck k (not hidden: an undiscovered bonus is not listed),
## primaries first; bonuses say "Bonus: ", finished ones end in " (done)" / " (failed)". Once the deck's primary is
## done the first line is "Proceed to deck k+2" (proceed_text; the extraction deck: the hold's line instead; if the hold still waits for another
## deck's primary, "Return to deck n: objective unfinished"). The extraction hold's line, once it shows, comes first.
func lines(deck: int) -> Array[String]:
	var out: Array[String] = []
	var p := _primary_of(deck)
	if not p.is_empty() and _st[p["id"]] == "done" and outcome == "":
		var h := objective("hold")
		if h.is_empty() or int(h["deck"]) != deck:
			out.append(proceed_text(deck + 1))
		elif _st[h["id"]] == "hidden":
			for o: Dictionary in objectives:
				if o["role"] == "primary" and o["type"] != "hold" and _st[o["id"]] != "done":
					out.append("Return to deck %d: objective unfinished" % (int(o["deck"]) + 1))
					break
	for role: String in ["primary", "bonus"]:
		for o: Dictionary in objectives:
			if int(o["deck"]) != deck or o["role"] != role or _st[o["id"]] == "hidden":
				continue
			var line := ("Bonus: " if role == "bonus" else "") + _line(o)
			match str(_st[o["id"]]):
				"done":
					line += " (done)"
				"failed":
					line += " (failed)"
			if o["type"] == "hold" and _st[o["id"]] != "done":
				out.push_front(line)      # the extraction hold, once it shows, leads the list
			else:
				out.append(line)
	return out


## The world markers for deck k: known or active objectives (not hidden, done or failed), as
## {id, type, role, deck, x, s, radius, state}; a hold's (x, s) is its zone's centre.
func markers(deck: int) -> Array:
	var out := []
	for o: Dictionary in objectives:
		var st: String = _st[o["id"]]
		if int(o["deck"]) != deck or not (st == "known" or st == "active"):
			continue
		var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
		if o["type"] == "hold":
			at = (o["zone"] as Rect2).get_center()
		out.append({"id": o["id"], "type": o["type"], "role": o["role"], "deck": int(o["deck"]), "x": at.x, "s": at.y,
				"radius": float(o["radius"]), "state": st})
	return out


# --- Objective panel (docs/design/mission-objectives.md §9 "Objective panel") ------------------------------------

## "Proceed to deck n" for deck index d (n = d + 1, the number painted on the walls).
static func proceed_text(d: int) -> String:
	return "Proceed to deck %d" % (d + 1)


## For the HUD's one objective panel, from the replicated state plus two LOCAL facts of the viewing pilot (never
## sent): the deck they stand on (`viewer_deck`) and their (x, s) on it (`viewer_pos`). {} without decks.
##   {header: "DECK 2 of 3", deck, decks,
##    lines: [{text, role, state, deck, dir (vs the viewer's deck: 1 below, -1 above, 0 here), part: lead | here | tail}],
##    route_at: the route of the first lead line (the HUD's waypoint goes there) or {}}
## Roles: primary / bonus (this deck's objectives: every known one, done / failed too, a bonus to do ends in
## " (optional)", the extraction hold first once it shows); next ("Proceed to deck 3", or a deck below the viewer that
## the crew has visited with a primary left: "Deck 3: 1 objective, 2 optional left"); return ("Return to deck 1:
## objective unfinished": a deck above with its primary not done); deck (a visited deck with only found bonuses left:
## "Deck 1: 1 optional left"); route (the way off this deck toward the line above it: "ramp down 120 m"; only when one
## exists). Decks are OPEN up to max(reached, viewer_deck) (`reached`: the crew's latched deepest deck; the viewer's own
## deck is always open): beyond that nothing is listed but one "Proceed to deck n" for the first unopened deck, and only
## when no opened deck below the viewer still has a primary left. Finished visited decks give no line. Parts: while this
## deck's primary is to do, every other line trails this deck's list (tail: down then up, the route under the first line
## each way); once it is done (or the deck has none) the next / return lines lead, only the deck lines trail. After the
## mission's outcome: this deck's list only. Nothing here depends on pilot ids.
func panel(viewer_deck: int, viewer_pos: Vector2) -> Dictionary:
	if deck_count <= 0:
		return {}
	var k := clampi(viewer_deck, 0, deck_count - 1)
	var here := _here_lines(k)
	var lead: Array = []
	var tail: Array = []
	if outcome == "":
		var p := _primary_of(k)
		var p_done: bool = p.is_empty() or _st[p["id"]] == "done"
		var open_to := mini(maxi(_reached, k), deck_count - 1)
		for dir: int in [1, -1]:
			var big: Array = []      # next / return lines, nearest first
			var small: Array = []    # deck lines (found bonuses only), nearest first
			var d := k + dir
			while d >= 0 and d <= open_to:
				var n := _left_counts(d)
				var dp := _primary_of(d)
				if dir < 0 and not dp.is_empty() and _st[dp["id"]] != "done":
					big.append(_pline("Return to deck %d: objective unfinished" % (d + 1), "return", d, dir))
				elif dir > 0 and n.x > 0:
					big.append(_pline("Deck %d: %s left" % [d + 1, _count_words(n)], "next", d, dir))
				elif n.y > 0:
					small.append(_pline("Deck %d: %s left" % [d + 1, _count_words(n)], "deck", d, dir))
				d += dir
			if dir > 0 and big.is_empty():
				var nxt := open_to + 1 if open_to + 1 < deck_count else (open_to if open_to > k else -1)
				if nxt > k:
					big.append(_pline(proceed_text(nxt), "next", nxt, dir))
			var rt := route(k, viewer_pos, dir)
			var way: Array = []
			if not rt.is_empty():
				way = [_pline(str(rt["text"]), "route", k + dir, dir)]
			if p_done:
				lead.append_array(_with_way(big, way))
				tail.append_array(_with_way(small, way if big.is_empty() else []))
			else:
				tail.append_array(_with_way(big + small, way))
	var route_at := {}
	if not lead.is_empty():
		route_at = route(k, viewer_pos, int(lead[0]["dir"]))
	var out: Array = []
	for l: Dictionary in lead:
		out.append(_with_part(l, "lead"))
	for l: Dictionary in here:
		out.append(_with_part(l, "here"))
	for l: Dictionary in tail:
		out.append(_with_part(l, "tail"))
	return {"header": "DECK %d of %d" % [k + 1, deck_count], "deck": k, "decks": deck_count, "lines": out,
		"route_at": route_at}


## The nearest way off deck k in direction `dir` (1 down, -1 up) from (x, s) `at`, straight-line along the deck:
## {text: "ramp down 120 m", kind, dist, dir, deck, x, s} or {} (none). Down: a ramp's mouth (its top on deck k) or a
## shaft whose drop lands on the next floor (never a stacked atrium shaft that drops two decks); up: a ramp's foot on
## deck k (shafts are one way). Every down candidate is a hop-only walkable one (SectionPlan.walkable_down_connector
## picks among the same set), so the nearest is always walkable. Lifts only with LIFTS_RIDE. Locked connectors (the
## express lift) never count.
func route(k: int, at: Vector2, dir: int) -> Dictionary:
	if section == null or dir == 0:
		return {}
	var best := {}
	var bd := INF
	for ci in section.connectors.size():
		var c: Dictionary = section.connectors[ci]
		if bool(c.get("locked", false)):
			continue
		var p := Vector2(INF, INF)
		match str(c["kind"]):
			"ramp":
				var lane := (float(c["x0"]) + float(c["x1"])) * 0.5
				if dir > 0 and int(c["from"]) == k:
					p = Vector2(lane, section.line_s(k, int(c["top_line"])))
				elif dir < 0 and int(c["to"]) == k:
					p = Vector2(lane, section.line_s(k, int(c["foot_line"])))
			"shaft":
				# Only a shaft whose drop lands on deck k+1 (SectionPlan.shaft_lands): a stacked atrium drops through
				# k+1's hole to k+2 and skips that deck (the hop-only rule, docs/design/mission-section.md §6).
				if dir > 0 and int(c["from"]) == k and section.shaft_lands(ci):
					p = section.connector_rect(ci, k).get_center()
			"lift":
				var stops: Array = c.get("stops", [])
				if LIFTS_RIDE and int(c["pillar"]) >= 0 and stops.has(k) and \
						((dir > 0 and int(stops.max()) > k) or (dir < 0 and int(stops.min()) < k)):
					p = section.pillar_point(k, int(c["pillar"]))
		if not p.is_finite():
			continue
		var d := at.distance_to(p)
		if d < bd:
			bd = d
			best = {"kind": str(c["kind"]), "deck": k, "x": p.x, "s": p.y, "dir": dir}
	if best.is_empty():
		return best
	var m := maxi(int(round(bd / ROUTE_ROUND)) * int(ROUTE_ROUND), int(ROUTE_ROUND))
	best["dist"] = m
	best["text"] = "%s %s %d m" % [best["kind"], "down" if dir > 0 else "up", m]
	return best


## This deck's list (see panel()): every known objective, done / failed too, primaries then bonuses, the extraction hold
## first once it shows.
func _here_lines(d: int) -> Array:
	var lead: Array = []
	var rest: Array = []
	for role: String in ["primary", "bonus"]:
		for o: Dictionary in objectives:
			if int(o["deck"]) != d or o["role"] != role:
				continue
			var st: String = _st[o["id"]]
			if st == "hidden":
				continue
			var text := _line(o)
			match st:
				"done":
					text += " (done)"
				"failed":
					text += " (failed)"
				_:
					if role == "bonus":
						text += " (optional)"
			var l := _pline(text, role, d, 0)
			l["state"] = st
			if o["type"] == "hold" and st != "done":
				lead.append(l)      # the extraction hold, once it shows, leads its deck's list
			else:
				rest.append(l)
	return lead + rest


## Deck d's objectives still to do, (primaries, found bonuses), known or active (hidden bonuses are not counted).
func _left_counts(d: int) -> Vector2i:
	var n := Vector2i.ZERO
	for o: Dictionary in objectives:
		var st: String = _st[o["id"]]
		if int(o["deck"]) != d or not (st == "known" or st == "active"):
			continue
		if o["role"] == "primary":
			n.x += 1
		else:
			n.y += 1
	return n


## "2 objectives", "1 objective, 2 optional", "1 optional".
static func _count_words(n: Vector2i) -> String:
	var parts: Array[String] = []
	if n.x > 0:
		parts.append("%d %s" % [n.x, "objective" if n.x == 1 else "objectives"])
	if n.y > 0:
		parts.append("%d optional" % n.y)
	return ", ".join(parts)


## `ls` with the route line `way` under its first line ([] when ls is empty).
static func _with_way(ls: Array, way: Array) -> Array:
	if ls.is_empty():
		return []
	return ls.slice(0, 1) + way + ls.slice(1)


static func _pline(text: String, role: String, deck: int, dir: int) -> Dictionary:
	return {"text": text, "role": role, "state": "", "deck": deck, "dir": dir}


static func _with_part(l: Dictionary, part: String) -> Dictionary:
	var o := l.duplicate()
	o["part"] = part
	return o


func _line(o: Dictionary) -> String:
	var id: String = o["id"]
	var prog := float(_prog[id])
	var tot := float(_tot[id])
	match str(o["type"]):
		"flag":
			return "Raise the flag: %d%%" % flag_percent(prog, tot, _st[id] == "done")
		"defend":
			if tot <= 0.0:
				return "Defend the position"
			return "Defend the position: wave %d / %d" % [mini(int(prog) + 1, int(round(tot))), int(round(tot))]
		"hold":
			return "Hold the extraction portal: %d s" % int(ceil(maxf(tot - prog, 0.0) - 0.001))
		"sweep":
			var n := left_on(int(o["deck"]))
			var head := "Clear deck %d: %d %s" % [int(o["deck"]) + 1, n, "hostile" if n == 1 else "hostiles"]
			if tot > 0.0:
				head += ", waves %d / %d" % [int(round(prog)), int(round(tot))]
			return head
	return "Complete the objective"


## A capture's progress in whole percent: floor(progress / total), 100 only once done (99 at most before).
static func flag_percent(prog: float, tot: float, done: bool) -> int:
	if done:
		return 100
	if tot <= 0.0:
		return 0
	return clampi(int(floor(prog / tot * 100.0 + 0.0001)), 0, 99)


## The deck's primary record ({} none; the hold is not a deck primary).
func _primary_of(deck: int) -> Dictionary:
	for o: Dictionary in objectives:
		if int(o["deck"]) == deck and o["role"] == "primary" and o["type"] != "hold":
			return o
	return {}
