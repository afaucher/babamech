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
##           (30 s by default: an ally opens the exit door meanwhile). Exactly: each evaluate adds the facts.t delta
##           since the previous evaluate (at most MAX_STEP 1 s) while at least ONE standing (not downed) crew mech is
##           inside the zone rect on its deck; enemies in the zone change nothing; with nobody in it the progress
##           PAUSES (no reset, no decay) and the objective stays active.
## Outcome: a failed primary -> "lost" (reason "objective_failed"). Every primary (hold included) done -> the EXIT
## (R2.10, "the crew walks out to win"): `exit_at` (facts.t + EXIT_LEAD, latched) is when the host opens the exit road
## door (MissionFlow orders it, replicated); then "won" (reason "objectives") on the first evaluate where every STANDING
## crew entry (not downed: a downed or redeploying pilot is recovered with the crew and never blocks) has `exit` true and
## at least one standing entry exists. crew entries' optional "exit": bool = inside the exit bay (MissionFlow decides it
## from MissionWorld.bay_contains: past the door plane by the mech's capsule radius). Option "walk_out" false (no exit
## door on the deck: MissionFlow sets it, logged), or a plan without a hold (test plans): "won" once every primary is done.
## Extra facts (all optional): "waves_left": [per deck] (PacingDirector.waves_left_all()), "zone_enemies": {id: n},
##   "assets": {id: hp 0..1}, "defend_waves": {id: {released, total, alive}} (PacingDirector.objective_waves()),
##   "waves": [[released, total] per deck] (PacingDirector.state().waves: the sweep's "waves 2 / 3").
## state() adds "objs": {id: [state, progress (0.1), total]} and "reached" (the deepest deck a standing crew mech has
## been on, latched); "current" is the first primary not done. text() reads "Proceed to deck n" (proceed_text) while the
## current objective's deck is deeper than "reached" (a deck's primary done, the crew not on the next deck yet). The flag line shows its
## capture as a whole percent (flag_percent: 100 % only once done), the hold too ("Hold the exit: 40%", then "Exit through
## the door" once the exit is open); defend keeps waves. ally_due(said): the ally's short HUD lines (once each).
## set_site(id, x, s): every machine, before the first evaluate, when the world snapped a mast / asset to clear ground.
## panel(viewer_deck, viewer_pos): the HUD's objective panel (one section per deck, every deck listed: a visited deck's
## objectives, an unvisited deck's "Proceed to deck n", the next step marked, one route hint), from the replicated state
## plus the viewer's local deck and position; fit(panel, rows) shortens it to a height.

const DEFAULTS := {"wipe": false, "wipe_grace": 1.0, "walk_out": true}
const ZONE_DEPTH := 40.0         ## m: the extraction zone's depth in from the exit door's end wall (extraction_zone)
const EXIT_LEAD := 1.0           ## s from the hold's completion (facts.t) to the exit door's open_at (clients get the order first)
const EXIT_LINE := "Exit through the door"
## The ally's lines (R2.10, approved "keep it small"): text only, once each per mission (ally_due).
const ALLY_LINES := {"working": "Working on the door", "almost": "Almost there", "open": "Door's open, go!"}
const ALLY_ALMOST := 0.7         ## hold progress share for "Almost there"
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
var exit_at := -1.0              ## shared-clock open_at of the exit door, set when every primary is done (-1 not yet)
var exit_site: Dictionary = {}   ## {deck, x, s} of the exit bay (set_exit, every machine; marker() once the exit is open)


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission's settings, fixed at creation, same everywhere
		"deck_count": Net.LOCAL, "objectives": Net.LOCAL,     # recomputed from the section plan + options everywhere
		"plan": Net.LOCAL,           # the MissionPlan, derived from the seed on every machine
		"section": Net.LOCAL,        # the SectionPlan, derived from the seed on every machine
		# The mission's progress: the host writes it (evaluate) and broadcasts state(); clients only apply_state().
		"outcome": Net.OWNER, "reason": Net.OWNER, "_done": Net.OWNER, "_left": Net.OWNER,
		"_st": Net.OWNER, "_prog": Net.OWNER, "_tot": Net.OWNER, "_reached": Net.OWNER,
		"exit_at": Net.OWNER,        # the host latches it (state "exit"); the exit door order carries the same open_at
		"exit_site": Net.LOCAL,      # from MissionWorld.exit_door(), the same on every machine (set_exit)
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
	options["walk_out"] = bool(options["walk_out"])
	deck_count = sec.deck_count
	section = sec
	_left.resize(sec.deck_count)
	_left.fill(0)


## The extraction zone on the extraction deck, in that deck's (x, s): across the whole transit spine corridor (its four
## lanes, centred on the spine line), `depth` metres in from the end wall the exit road door is in. Clamped to the deck.
static func extraction_zone(sec: SectionPlan, depth: float) -> Rect2:
	var k := int(sec.extraction["deck"])
	var w := sec.p("width")
	var a := sec.arc_of(k)
	var x0 := maxf(sec.lane_x(str(SectionPlan.SPINE_LANES[0][0])).x, -w * 0.5)
	var x1 := minf(sec.lane_x(str(SectionPlan.SPINE_LANES[-1][0])).y, w * 0.5)
	var d := clampf(depth, 0.0, a)
	var s0 := -a * 0.5
	if int(sec.extraction["j"]) != 0:      # j == rows: the exit door is in the s1 wall
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


## Every machine, before the first evaluate: where the exit bay is (MissionWorld.exit_door(): its deck, the bay centre's
## x, s). marker() points there once the exit is open.
func set_exit(deck: int, x: float, s: float) -> void:
	exit_site = {"deck": deck, "x": x, "s": s}


## The exit door has been ordered open (every primary done, walk-out on): "Exit through the door".
func exit_open() -> bool:
	return exit_at >= 0.0


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
	elif all_done and (not bool(options["walk_out"]) or objective("hold").is_empty()):
		outcome = "won"
		reason = "objectives"
	elif all_done:
		if exit_at < 0.0:
			exit_at = (float(facts["t"]) if facts.has("t") else 0.0) + EXIT_LEAD
		if _crew_out(crew):
			outcome = "won"
			reason = "objectives"
		else:
			_check_wipe(facts, crew)
	else:
		_check_wipe(facts, crew)
	return state() != before


## The walk-out: every standing crew entry (not downed; a redeploying pilot is downed too) is in the exit bay (`exit`),
## and at least one stands.
func _crew_out(crew: Array) -> bool:
	var n := 0
	for c: Variant in crew:
		if not c is Dictionary or bool((c as Dictionary).get("downed", false)):
			continue
		if not bool((c as Dictionary).get("exit", false)):
			return false
		n += 1
	return n > 0


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
	out["exit"] = exit_at
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
	if d.has("exit"):
		exit_at = float(d["exit"])
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
	if exit_open():
		return EXIT_LINE
	var o := objective(current())
	if o.is_empty():
		return ""
	# The previous deck's primary is done and nobody of the crew has reached this objective's deck yet.
	if _reached >= 0 and _reached < int(o["deck"]):
		return proceed_text(int(o["deck"]))
	return _line(o)


## Centre of the extraction hold's zone {deck, x, s} while the hold is the current objective and known; once the exit is
## open (and the mission on), the exit bay's centre (set_exit); else {}.
func marker() -> Dictionary:
	if exit_open():
		return exit_site.duplicate() if outcome == "" else {}
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
			var exiting: bool = o["type"] == "hold" and _exiting()
			match str(_st[o["id"]]):
				"done":
					if not exiting:
						line += " (done)"
				"failed":
					line += " (failed)"
			if o["type"] == "hold" and (_st[o["id"]] != "done" or exiting):
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


## "Deck n:", the header of deck index d's section in the panel.
static func deck_header(d: int) -> String:
	return "Deck %d:" % (d + 1)


## For the HUD's one objective panel (playtest backlog R2.13: one section per deck, every deck always listed), from the
## replicated state plus two LOCAL facts of the viewing pilot (never sent): the deck they stand on (`viewer_deck`) and
## their (x, s) on it (`viewer_pos`). {} without decks.
##   {deck: the viewer's deck, decks, route_at: route() of the next step or {} (the HUD's waypoint goes there),
##    lines: [{text, role, deck, state, current, lead, dir}]}
## In deck order, each deck: a header row (role "header", "Deck 2:", `current` on the viewer's deck), then
##   - a VISITED deck (d <= max(reached, viewer deck): `reached` is the crew's latched deepest deck, the viewer's own deck
##     always counts): its known objectives (hidden bonuses not listed), the extraction hold first once it shows, then the
##     primary, then the bonuses ("... (optional)"); done / failed keep their final value (failed adds "(failed)");
##   - an UNVISITED deck: one row "Proceed to deck n" (role "proceed").
## The NEXT STEP (`lead`, drawn amber), only while the viewer's deck has no primary left (done, or none known) and the
## mission is on: the nearest deck below with a primary left or still unvisited (its proceed row), else the nearest deck
## above with a primary left (its unfinished primary row: "go back"). The route hint (role "route", "ramp down 120 m",
## only when a walkable way exists) sits right under that proceed row, or under that visited deck's header. Nothing
## else leads. Fitting to a height: fit(). Nothing here depends on pilot ids.
func panel(viewer_deck: int, viewer_pos: Vector2) -> Dictionary:
	if deck_count <= 0:
		return {}
	var k := clampi(viewer_deck, 0, deck_count - 1)
	var open_to := mini(maxi(_reached, k), deck_count - 1)
	var target := _next_deck(k, open_to)
	var rt := {}
	if target >= 0:
		rt = route(k, viewer_pos, 1 if target > k else -1)
	var out: Array = []
	for d in deck_count:
		var h := _prow(deck_header(d), "header", d)
		h["current"] = d == k
		out.append(h)
		if d > open_to:
			var p := _prow(proceed_text(d), "proceed", d)
			p["lead"] = d == target
			out.append(p)
			if d == target and not rt.is_empty():
				out.append(_route_row(rt, d))
			continue
		if d == target and not rt.is_empty():
			out.append(_route_row(rt, d))
		for l: Dictionary in _deck_lines(d):
			l["lead"] = bool(l.get("exit", false)) or (d == target and l["role"] == "primary" and _open(str(l["state"])))
			out.append(l)
	return {"deck": k, "decks": deck_count, "lines": out, "route_at": rt}


## The panel's rows fitted to `limit` rows (MissionHud: PANEL_FRAC of the screen height, less the crew lines), with the
## depot line(s) `pn.extra` at the end of the viewer's section (role "extra", never cut). Every header always stays.
## Too long, in this order, each step only as far as needed, other decks farthest from the viewer first: the route
## hint; other decks' done / failed rows; other decks' optional rows -> one "n optional" row (role "summary"); other
## decks' remaining rows -> one "1 objective, 2 optional" row (the proceed row is already one); then the viewer's deck's
## done / failed rows and its optional rows -> "n optional"; then other decks down to their header; then the viewer's
## rows are cut from the end. A summary keeps `lead` when a row it replaces had it.
static func fit(pn: Dictionary, limit: int) -> Array:
	var k := int(pn.get("deck", 0))
	var secs: Array = []
	for l: Dictionary in pn.get("lines", []):
		if str(l["role"]) == "header":
			secs.append({"head": l, "body": [], "deck": int(l["deck"])})
		elif not secs.is_empty():
			(secs[-1]["body"] as Array).append(l)
	var xs: Array = []
	for e: Variant in pn.get("extra", []):
		var x := _prow(str(e), "extra", k)
		xs.append(x)
	if secs.is_empty() and xs.is_empty():
		return []
	var others: Array = []
	var mine: Array = []
	for s: Dictionary in secs:
		if int(s["deck"]) == k:
			mine.append(s)
		else:
			others.append(s)
	others.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := absi(int(a["deck"]) - k)
		var db := absi(int(b["deck"]) - k)
		return da > db if da != db else int(a["deck"]) > int(b["deck"]))
	var over := func() -> bool:
		var n := secs.size() + xs.size()
		for s: Dictionary in secs:
			n += (s["body"] as Array).size()
		return n > limit
	var is_route := func(r: Dictionary) -> bool: return str(r["role"]) == "route"
	var finished := func(r: Dictionary) -> bool: return str(r["state"]) == "done" or str(r["state"]) == "failed"
	for s: Dictionary in secs:
		_drop_rows(s, is_route, over)
	for s: Dictionary in others:
		_drop_rows(s, finished, over)
	for s: Dictionary in others:
		if over.call():
			_fold_optional(s)
	for s: Dictionary in others:
		if over.call():
			_fold_all(s)
	for s: Dictionary in mine:
		_drop_rows(s, finished, over)
		if over.call():
			_fold_optional(s)
	for s: Dictionary in others:
		_drop_rows(s, func(_r: Dictionary) -> bool: return true, over)
	for s: Dictionary in mine:
		_drop_rows(s, func(_r: Dictionary) -> bool: return true, over)
	var rows: Array = []
	for s: Dictionary in secs:
		rows.append(s["head"])
		rows.append_array(s["body"])
		if int(s["deck"]) == k:
			rows.append_array(xs)
	if mine.is_empty():
		rows.append_array(xs)
	return rows


## Removes section `s`'s rows matching `pick`, the last first, while `over` (a Callable -> bool) holds.
static func _drop_rows(s: Dictionary, pick: Callable, over: Callable) -> void:
	var body: Array = s["body"]
	for i in range(body.size() - 1, -1, -1):
		if not over.call():
			return
		if pick.call(body[i]):
			body.remove_at(i)


## Section `s`'s optional rows -> one "n optional" row where the first of them was (only when that saves a row).
static func _fold_optional(s: Dictionary) -> void:
	var body: Array = s["body"]
	var at := -1
	var n := 0
	for i in body.size():
		if str(body[i]["role"]) == "bonus":
			at = i if at < 0 else at
			n += 1
	if n < 2:
		return
	var keep: Array = body.filter(func(r: Dictionary) -> bool: return str(r["role"]) != "bonus")
	var sum := _prow(_count_text(0, n), "summary", int(s["deck"]))
	sum["count"] = n
	keep.insert(mini(at, keep.size()), sum)
	s["body"] = keep


## Section `s`'s rows -> one summary row ("1 objective, 2 optional"; lead if any row led). A single row stays as it is.
static func _fold_all(s: Dictionary) -> void:
	var body: Array = s["body"]
	if body.size() < 2:
		return
	var np := 0
	var nb := 0
	var lead := false
	for r: Dictionary in body:
		lead = lead or bool(r.get("lead", false))
		match str(r["role"]):
			"primary":
				np += 1
			"bonus":
				nb += 1
			"summary":
				nb += int(r.get("count", 0))
	if np + nb == 0:
		return
	var sum := _prow(_count_text(np, nb), "summary", int(s["deck"]))
	sum["lead"] = lead
	s["body"] = [sum]


## "2 optional", "1 objective", "1 objective, 2 optional", "2 objectives".
static func _count_text(np: int, nb: int) -> String:
	var parts: Array[String] = []
	if np > 0:
		parts.append("%d %s" % [np, "objective" if np == 1 else "objectives"])
	if nb > 0:
		parts.append("%d optional" % nb)
	return ", ".join(parts)


## The deck the next step is on (see panel()), -1 none: the viewer's deck still has a primary to do, or the mission
## is over, or nothing is left anywhere.
func _next_deck(k: int, open_to: int) -> int:
	if outcome != "" or _primary_left(k):
		return -1
	for d in range(k + 1, deck_count):
		if d > open_to or _primary_left(d):
			return d
	for d in range(k - 1, -1, -1):
		if _primary_left(d):
			return d
	return -1


## Deck d has a known primary (the extraction hold included, once it shows) neither done nor failed.
func _primary_left(d: int) -> bool:
	for o: Dictionary in objectives:
		if int(o["deck"]) == d and o["role"] == "primary" and _open(str(_st[o["id"]])):
			return true
	return false


static func _open(st: String) -> bool:
	return st == "known" or st == "active"


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
				# Where the slope starts / ends on deck k (SectionPlan.ramp_run: past the junction boxes, R2.17).
				var lane := (float(c["x0"]) + float(c["x1"])) * 0.5
				if dir > 0 and int(c["from"]) == k:
					p = Vector2(lane, section.ramp_run(ci, k).x)
				elif dir < 0 and int(c["to"]) == k:
					p = Vector2(lane, section.ramp_run(ci, k).y)
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


## A visited deck's rows (see panel()): every known objective, done / failed too, the extraction hold first once it
## shows, then the primary, then the bonuses; the section wording (_line(o, true)).
func _deck_lines(d: int) -> Array:
	var lead: Array = []
	var rest: Array = []
	for role: String in ["primary", "bonus"]:
		for o: Dictionary in objectives:
			if int(o["deck"]) != d or o["role"] != role:
				continue
			var st: String = _st[o["id"]]
			if st == "hidden":
				continue
			var text := _line(o, true)
			if role == "bonus" and st == "failed":
				text += " (optional, failed)"
			elif role == "bonus":
				text += " (optional)"
			elif st == "failed":
				text += " (failed)"
			var l := _prow(text, role, d)
			l["state"] = st
			if o["type"] == "hold" and _exiting():
				l["state"] = "active"     # "Exit through the door": the next step, amber wherever the viewer is
				l["exit"] = true
				lead.append(l)
			elif o["type"] == "hold" and st != "done":
				lead.append(l)      # the extraction hold, once it shows, leads its deck's list
			else:
				rest.append(l)
	return lead + rest


static func _prow(text: String, role: String, deck: int) -> Dictionary:
	return {"text": text, "role": role, "deck": deck, "state": "", "current": false, "lead": false, "dir": 0}


## The route hint row for route() `rt` toward deck `d` (always the next step: lead).
static func _route_row(rt: Dictionary, d: int) -> Dictionary:
	var r := _prow(str(rt["text"]), "route", d)
	r["dir"] = int(rt["dir"])
	r["lead"] = true
	return r


## The objective's line. `section` (the panel, under a "Deck n:" header): the deck is not repeated and counts read
## "2/3": "Clear hostiles, waves 2/3", "Defend the position: wave 1/3". Otherwise (text(), lines()):
## "Clear deck 2: 5 hostiles, waves 2 / 3", "Defend the position: wave 1 / 3".
func _line(o: Dictionary, section: bool = false) -> String:
	var id: String = o["id"]
	var prog := float(_prog[id])
	var tot := float(_tot[id])
	var sep := "/" if section else " / "
	match str(o["type"]):
		"flag":
			return "Raise the flag: %d%%" % flag_percent(prog, tot, _st[id] == "done")
		"defend":
			if tot <= 0.0:
				return "Defend the position"
			return "Defend the position: wave %d%s%d" % [mini(int(prog) + 1, int(round(tot))), sep, int(round(tot))]
		"hold":
			if _exiting():
				return EXIT_LINE
			return "Hold the exit: %d%%" % flag_percent(prog, tot, _st[id] == "done")
		"sweep":
			if section:   # the user's wording (R2.13); the hostiles left only while no wave count is known
				if tot > 0.0:
					return "Clear hostiles, waves %d/%d" % [int(round(prog)), int(round(tot))]
				return "Clear hostiles: %d left" % left_on(int(o["deck"]))
			var n := left_on(int(o["deck"]))
			var head := "Clear deck %d: %d %s" % [int(o["deck"]) + 1, n, "hostile" if n == 1 else "hostiles"]
			if tot > 0.0:
				head += ", waves %d / %d" % [int(round(prog)), int(round(tot))]
			return head
	return "Complete the objective"


## The exit is open and the mission still on (the walk-out: the hold's row reads EXIT_LINE).
func _exiting() -> bool:
	return exit_open() and outcome == ""


## The ally's lines due now (R2.10: someone opens the exit door for the crew), each at most once per mission: `said`
## (the caller's memory, LOCAL, updated here) remembers them. "Working on the door" once the hold goes active (a standing
## mech entered the zone), "Almost there" at ALLY_ALMOST of the hold, "Door's open, go!" once the exit is open. Lines
## that fall due in the same call (a late state): only the newest is returned, the older ones are marked said. From the
## replicated state only, so every machine says the same.
func ally_due(said: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var h := objective("hold")
	if h.is_empty() or outcome != "":
		return out
	var id: String = h["id"]
	var st := str(_st.get(id, ""))
	var tot := float(_tot.get(id, 0.0))
	var share := float(_prog.get(id, 0.0)) / tot if tot > 0.0 else 0.0
	var due := {"working": st == "active" or st == "done",
		"almost": st == "done" or (st == "active" and share >= ALLY_ALMOST), "open": exit_open()}
	var newest := ""
	for key: String in ["working", "almost", "open"]:
		if bool(due[key]) and not said.has(key):
			said[key] = true
			newest = key       # an older line overtaken in the same step is skipped
	if newest != "":
		out.append(str(ALLY_LINES[newest]))
	return out


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
