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
##          "crew": [{"peer": int, "downed": bool, "deck": int, "x": float, "s": float}]}
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
## Extra facts (all optional): "waves_left": [per deck] (WaveDirector.waves_left_all()), "zone_enemies": {id: n},
##   "assets": {id: hp 0..1}, "defend_waves": {id: {released, total, alive}} (WaveDirector.objective_waves()),
##   "waves": [[released, total] per deck] (WaveDirector.state().waves: the sweep's "waves 2 / 3").
## state() adds "objs": {id: [state, progress (0.1), total]}; "current" is the first primary not done.
## set_site(id, x, s): every machine, before the first evaluate, when the world snapped a mast / asset to clear ground.

const DEFAULTS := {"extract": true, "zone_depth": 40.0, "wipe": false, "wipe_grace": 1.0}
const DISCOVER := 150.0          ## a bonus is found when a standing mech on its deck comes this close
const MAX_STEP := 1.0            ## most seconds of zone time one evaluate call can add

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


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission's settings, fixed at creation, same everywhere
		"deck_count": Net.LOCAL, "objectives": Net.LOCAL,     # recomputed from the section plan + options everywhere
		"plan": Net.LOCAL,           # the MissionPlan, derived from the seed on every machine
		# The mission's progress: the host writes it (evaluate) and broadcasts state(); clients only apply_state().
		"outcome": Net.OWNER, "reason": Net.OWNER, "_done": Net.OWNER, "_left": Net.OWNER,
		"_st": Net.OWNER, "_prog": Net.OWNER, "_tot": Net.OWNER,
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


func _all_downed(crew: Array) -> bool:
	for c: Dictionary in crew:
		if not bool(c.get("downed", false)):
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


## Plan mode, for the HUD: one line per known objective on deck k (not hidden), primaries first; bonuses say "Bonus: ",
## finished ones end in " (done)" / " (failed)".
func lines(deck: int) -> Array[String]:
	var out: Array[String] = []
	if plan == null:
		return out
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


func _line(o: Dictionary) -> String:
	var id: String = o["id"]
	var prog := float(_prog[id])
	var tot := float(_tot[id])
	match str(o["type"]):
		"flag":
			return "Raise the flag: %d / %d s" % [int(prog), int(round(tot))]
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
	return id
