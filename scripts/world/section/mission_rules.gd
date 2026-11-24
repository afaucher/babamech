class_name MissionRules
extends RefCounted
## The co-op demo's mission objective and end conditions, as a pure deterministic evaluator (no nodes, no network code,
## no randomness, no clock). Specified in docs/design/mission-section.md §14.
##
## Objectives, in order: clear every deck (`clear_<k>`), then, when "extract" is on, reach the extraction zone on the
## extraction deck (`extract`, needs every clear). The outcome is "won" when every objective is done. The loss rule is
## built but OFF by default until revive exists (user decision 2026-11-22: mechs auto-respawn 1.5 s after being disabled,
## which would trip the wipe grace); `make(sec, {"wipe": true})` turns it on. With "wipe" on, the outcome is "lost" when
## the whole crew has stayed downed for "wipe_grace" seconds of facts.t (so a revive seen late over the link doesn't end
## the run; immediate without facts.t or with a grace <= 0). Win is checked first; an empty crew never loses. Downed
## mechs never count for the extraction zone, wipe or not. Everything done is latched, and once the outcome is set
## nothing changes any more.
##
## Who calls what: every machine builds the same rules with `make(plan, options)` (the objectives and the zone come from
## the section plan alone). The HOST feeds facts to `evaluate()` and, whenever it returns true, broadcasts `state()`;
## CLIENTS never evaluate, they `apply_state()` what the host sent. Everyone reads `text()`, `marker()`, `outcome`.
##
## facts = {"t": float (host shared-clock seconds, only compared, optional),
##          "enemies": [int alive on deck k] (missing entries count as 0),
##          "crew": [{"peer": int, "downed": bool, "deck": int, "x": float, "s": float, "redeploying": bool (optional:
##                   held to respawn, DownedRules; a redeploying pilot keeps the wipe from firing)}]}
## Downed / revive / respawn (user decision 2026-11-24): there is no automatic respawn any more; with "wipe" on the
## mission is lost only when every pilot is down at the same time and nobody is redeploying.
## state = {"outcome": "" | "won" | "lost", "reason": String, "done": [ids in objective order], "left": [int per deck],
##          "current": first objective not done ("" when all done)}   survives JSON and var_to_bytes round trips
##
## PLAN MODE (docs/design/mission-objectives.md §9): `make(sec, {"plan": MissionPlan})` evaluates the plan's objectives
## instead of clear + extract ("extract" / "zone_depth" are then unused; the wipe options work as above). Each record is
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
## been on, latched); "current" is the first primary not done. text() reads NEXT_FLOOR while the current objective's
## deck is deeper than "reached" (a deck's primary done, the crew not on the next deck yet). The flag line shows its
## capture as a whole percent (flag_percent: 100 % only once done); hold / defend keep seconds / waves.
## set_site(id, x, s): every machine, before the first evaluate, when the world snapped a mast / asset to clear ground.
## panel(viewer_deck, viewer_pos): the HUD's structured objective panel (header, per-deck groups with direction
## prefixes, primary / optional, route lines), from the replicated state plus the viewer's local deck and position.

const DEFAULTS := {"extract": true, "zone_depth": 40.0, "wipe": false, "wipe_grace": 1.0}
const DISCOVER := 150.0          ## a bonus is found when a standing mech on its deck comes this close
const MAX_STEP := 1.0            ## most seconds of zone time one evaluate call can add
const NEXT_FLOOR := "Proceed to the next floor"   ## plan mode: a deck's primary is done, the next deck's waits
## panel(): the direction prefix glyphs (up, down, here) and the ASCII fallback the user asked for when the HUD font
## lacks them (font_has_arrows(); the HUD picks once at startup).
const ARROWS := {"up": "▲", "down": "▼", "here": "–"}
const ARROWS_ASCII := {"up": "^", "down": "V", "here": "-"}
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
var _st: Dictionary = {}         ## plan mode: objective id -> hidden | known | active | done | failed
var _prog: Dictionary = {}       ## plan mode: objective id -> progress
var _tot: Dictionary = {}        ## plan mode: objective id -> total
var _last_t := -1.0              ## plan mode, host: facts.t of the previous evaluate (-1 none)
var _reached := -1               ## plan mode: the deepest deck a standing crew mech has been on (latched; -1 none yet)
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


static func make(sec: SectionPlan, overrides: Dictionary = {}) -> MissionRules:
	var m := MissionRules.new()
	m.options = DEFAULTS.duplicate()
	for id: String in overrides:
		if m.options.has(id):
			m.options[id] = overrides[id]
	m.options["extract"] = bool(m.options["extract"])
	m.options["zone_depth"] = maxf(float(m.options["zone_depth"]), 0.0)
	m.options["wipe"] = bool(m.options["wipe"])
	m.options["wipe_grace"] = float(m.options["wipe_grace"])
	m.deck_count = sec.deck_count
	m.section = sec
	m._left.resize(sec.deck_count)
	m._left.fill(0)
	if overrides.get("plan", null) is MissionPlan:
		m._use_plan(overrides["plan"])
		return m
	var clears: Array = []
	for k in sec.deck_count:
		var id := "clear_%d" % k
		m.objectives.append({"id": id, "kind": "clear", "deck": k, "needs": []})
		clears.append(id)
	if m.options["extract"]:
		var k := int(sec.extraction["deck"])
		m.objectives.append({"id": "extract", "kind": "extract", "deck": k, "needs": clears,
				"zone": extraction_zone(sec, float(m.options["zone_depth"]))})
	return m


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
	if plan != null:
		return _evaluate_plan(facts)
	var before := state()
	var enemies: Array = facts.get("enemies", [])
	for k in deck_count:
		_left[k] = maxi(int(enemies[k]), 0) if k < enemies.size() and enemies[k] != null else 0
	var crew: Array = facts.get("crew", [])
	for o: Dictionary in objectives:
		var id: String = o["id"]
		if _done.has(id):
			continue
		match str(o["kind"]):
			"clear":
				if _left[int(o["deck"])] == 0:
					_done[id] = true
			"extract":
				if _needs_met(o) and _someone_in(o, crew):
					_done[id] = true
	if current() == "":
		outcome = "won"
		reason = "objectives"
	else:
		_check_wipe(facts, crew)
	return state() != before


## The crew-wipe rule (both modes): with "wipe" on, lost once the whole crew has stayed downed for wipe_grace s.
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


# --- Plan mode ---------------------------------------------------------------------------------------------

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


## Plan mode, every machine, before the first evaluate: the world moved this objective's site (a mast or an asset
## snapped to clear ground). Zone checks, discovery and markers use the new site. Unknown ids are ignored.
func set_site(id: String, x: float, s: float) -> void:
	var o := objective(id)
	if plan == null or o.is_empty():
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


## Plan mode: the objective's state (hidden | known | active | done | failed), "" for an unknown id.
func obj_state(id: String) -> String:
	return str(_st.get(id, ""))


func obj_progress(id: String) -> float:
	return float(_prog.get(id, 0.0))


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
	if plan != null:
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
	if plan != null and d.has("reached"):
		_reached = int(d["reached"])
	if plan != null and d.get("objs", null) is Dictionary:

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


## Id of the first objective not done, "" when all are. Plan mode: the first PRIMARY not done.
func current() -> String:
	for o: Dictionary in objectives:
		if plan != null and o["role"] != "primary":
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
	if plan != null:
		# The previous deck's primary is done and nobody of the crew has reached this objective's deck yet.
		if _reached >= 0 and _reached < int(o["deck"]):
			return NEXT_FLOOR
		return _line(o)
	if o["kind"] == "extract":
		return "Reach the extraction portal"
	var n := left_on(int(o["deck"]))
	return "Clear deck %d: %d %s left" % [int(o["deck"]) + 1, n, "hostile" if n == 1 else "hostiles"]


## Centre of the extraction zone {deck, x, s} while extraction is the current objective, else {}.
func marker() -> Dictionary:
	if plan != null:
		var h := objective(current())
		if h.is_empty() or h["type"] != "hold" or _st[h["id"]] == "hidden":
			return {}
		var hc: Vector2 = (h["zone"] as Rect2).get_center()
		return {"deck": int(h["deck"]), "x": hc.x, "s": hc.y}
	if current() != "extract":
		return {}
	var o := objective("extract")
	var c: Vector2 = (o["zone"] as Rect2).get_center()
	return {"deck": int(o["deck"]), "x": c.x, "s": c.y}


## Plan mode, for the HUD: one line per known objective on deck k (not hidden: an undiscovered bonus is not listed),
## primaries first; bonuses say "Bonus: ", finished ones end in " (done)" / " (failed)". Once the deck's primary is
## done the first line is NEXT_FLOOR (the extraction deck: the hold's line instead; if the hold still waits for another
## deck's primary, "Return to deck n: objective unfinished"). The extraction hold's line, once it shows, comes first.
func lines(deck: int) -> Array[String]:
	var out: Array[String] = []
	if plan == null:
		return out
	var p := _primary_of(deck)
	if not p.is_empty() and _st[p["id"]] == "done" and outcome == "":
		var h := objective("hold")
		if h.is_empty() or int(h["deck"]) != deck:
			out.append(NEXT_FLOOR)
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


## Plan mode: the world markers for deck k: known or active objectives (not hidden, done or failed), as
## {id, type, role, deck, x, s, radius, state}; a hold's (x, s) is its zone's centre.
func markers(deck: int) -> Array:
	var out := []
	if plan == null:
		return out
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

## Plan mode, for the HUD's one objective panel, from the replicated state plus two LOCAL facts of the viewing pilot
## (never sent): the deck they stand on (`viewer_deck`) and their (x, s) on it (`viewer_pos`). {} outside plan mode.
##   {header: "DECK 2 of 3", deck, decks,
##    groups: [{deck, rel (deck - viewer_deck: > 0 below), here: bool, title: "DECK 3", prefix: "▼1", done: bool,
##              summary: "DECK 3: 1 objective, 2 optional" | "DECK 1: done",
##              lines: [{text, role: primary | bonus | next, state, rel, prefix}],
##              route: {text: "▼ ramp 120 m", kind: ramp | shaft | lift, dist (m, rounded to 5), dir: 1 down | -1 up,
##                      deck, x, s} or {}}],
##    route_at: the route of the first "next" line (Proceed to the next floor / Return to deck n) or {}}
## Groups: this deck first (all its known objectives, done / failed ones too, the next / return line first), then the
## decks below in route order (nearest first: the crew travels downward), then the decks above, nearest first. Another
## deck's group lists only what is still to do (known / active); with nothing left it is `done` (one line). The route
## line goes on the first unfinished group in each direction (the way is the same for the decks beyond). Hidden
## (undiscovered) bonuses are never listed. A bonus line ends in " (optional)" while it is to do. `ascii`: the
## ARROWS_ASCII prefixes. Nothing here depends on pilot ids.
func panel(viewer_deck: int, viewer_pos: Vector2, ascii: bool = false) -> Dictionary:
	if plan == null or deck_count <= 0:
		return {}
	var k := clampi(viewer_deck, 0, deck_count - 1)
	var order: Array[int] = [k]
	for d in range(k + 1, deck_count):
		order.append(d)
	for d in range(k - 1, -1, -1):
		order.append(d)
	var groups: Array = []
	var routed := {}
	var route_at := {}
	for d: int in order:
		var rel := d - k
		var ls := _panel_lines(d, k, ascii)
		var g := {"deck": d, "rel": rel, "here": rel == 0, "title": "DECK %d" % (d + 1), "prefix": arrow(rel, ascii),
			"lines": ls, "route": {}, "done": rel != 0 and ls.is_empty(), "summary": ""}
		var prim := 0
		var bon := 0
		for l: Dictionary in ls:
			if l["role"] == "primary":
				prim += 1
			elif l["role"] == "bonus":
				bon += 1
		var parts: Array[String] = []
		if prim > 0:
			parts.append("%d %s" % [prim, "objective" if prim == 1 else "objectives"])
		if bon > 0:
			parts.append("%d optional" % bon)
		g["summary"] = "DECK %d: %s" % [d + 1, "done" if parts.is_empty() else ", ".join(parts)]
		if rel != 0 and not g["done"] and not routed.has(signi(rel)):
			routed[signi(rel)] = true
			g["route"] = route(k, viewer_pos, signi(rel), ascii)
		groups.append(g)
	# The first "next" line (this deck's group) says which way: the waypoint may point at that route.
	for l: Dictionary in groups[0]["lines"]:
		if l["role"] == "next" and int(l["rel"]) != 0:
			route_at = route(k, viewer_pos, signi(int(l["rel"])), ascii)
			break
	return {"header": "DECK %d of %d" % [k + 1, deck_count], "deck": k, "decks": deck_count, "groups": groups,
		"route_at": route_at}


## The prefix of something `rel` decks from the viewer (rel > 0: below): "–" on this deck, "▲n" n decks above, "▼n"
## n decks below; `ascii`: "-", "^n", "Vn".
static func arrow(rel: int, ascii: bool = false) -> String:
	var a: Dictionary = ARROWS_ASCII if ascii else ARROWS
	if rel == 0:
		return str(a["here"])
	return "%s%d" % [str(a["down"] if rel > 0 else a["up"]), absi(rel)]


## True when `font` draws every ARROWS glyph (else the HUD uses ARROWS_ASCII).
static func font_has_arrows(font: Font) -> bool:
	if font == null:
		return false
	for ch: String in ARROWS.values():
		if not font.has_char(ch.unicode_at(0)):
			return false
	return true


## The nearest way off deck k in direction `dir` (1 down, -1 up) from (x, s) `at`, straight-line along the deck:
## {text: "▼ ramp 120 m", kind, dist, dir, deck, x, s} or {} (none). Down: a ramp's mouth (its top on deck k) or a shaft
## whose drop lands on the next floor (never a stacked atrium shaft that drops two decks); up: a ramp's foot on deck k
## (shafts are one way). Every down candidate is a hop-only walkable one (SectionPlan.walkable_down_connector picks among
## the same set), so the nearest is always walkable. Lifts only with LIFTS_RIDE. Locked connectors (the express lift)
## never count.
func route(k: int, at: Vector2, dir: int, ascii: bool = false) -> Dictionary:
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
	var a: Dictionary = ARROWS_ASCII if ascii else ARROWS
	best["dist"] = m
	best["text"] = "%s %s %d m" % [str(a["down"] if dir > 0 else a["up"]), best["kind"], m]
	return best


## The panel lines of deck d seen from deck k (see panel()).
func _panel_lines(d: int, k: int, ascii: bool) -> Array:
	var head: Array = []
	var lead: Array = []
	var rest: Array = []
	var here := d == k
	if here:
		var p := _primary_of(d)
		if not p.is_empty() and _st[p["id"]] == "done" and outcome == "":
			var h := objective("hold")
			if h.is_empty() or int(h["deck"]) != d:
				head.append(_pline(NEXT_FLOOR, "next", "", 1, ascii))
			elif _st[h["id"]] == "hidden":
				for o: Dictionary in objectives:
					if o["role"] == "primary" and o["type"] != "hold" and _st[o["id"]] != "done":
						var od := int(o["deck"])
						head.append(_pline("Return to deck %d: objective unfinished" % (od + 1), "next", "", od - k, ascii))
						break
	for role: String in ["primary", "bonus"]:
		for o: Dictionary in objectives:
			if int(o["deck"]) != d or o["role"] != role:
				continue
			var st: String = _st[o["id"]]
			if st == "hidden" or (not here and (st == "done" or st == "failed")):
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
			var l := _pline(text, role, st, d - k, ascii)
			if o["type"] == "hold" and st != "done":
				lead.append(l)      # the extraction hold, once it shows, leads its deck's list
			else:
				rest.append(l)
	return head + lead + rest


static func _pline(text: String, role: String, st: String, rel: int, ascii: bool) -> Dictionary:
	return {"text": text, "role": role, "state": st, "rel": rel, "prefix": arrow(rel, ascii)}


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
