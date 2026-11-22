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

const DEFAULTS := {"extract": true, "zone_depth": 40.0, "wipe": false, "wipe_grace": 1.0}

var options: Dictionary = {}
var deck_count := 0
var objectives: Array[Dictionary] = []
var outcome := ""
var reason := ""
var _done: Dictionary = {}       ## objective id -> true
var _left: Array[int] = []       ## enemies alive per deck, as last reported by the host
var _wipe_t := -1.0              ## host: facts.t when the whole crew went down (-1 = not all down)


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission's settings, fixed at creation, same everywhere
		"deck_count": Net.LOCAL, "objectives": Net.LOCAL,     # recomputed from the section plan + options everywhere
		# The mission's progress: the host writes it (evaluate) and broadcasts state(); clients only apply_state().
		"outcome": Net.OWNER, "reason": Net.OWNER, "_done": Net.OWNER, "_left": Net.OWNER,
		"_wipe_t": Net.PRIVATE,      # the host's pending-wipe countdown, never sent (not in state())
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
	elif options["wipe"] and not crew.is_empty() and _all_downed(crew):
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
	return state() != before


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
	return {"outcome": outcome, "reason": reason, "done": done, "left": left, "current": current()}


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


func is_done(id: String) -> bool:
	return _done.has(id)


## Id of the first objective not done, "" when all are.
func current() -> String:
	for o: Dictionary in objectives:
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
		return "Crew down"
	var o := objective(current())
	if o.is_empty():
		return ""
	if o["kind"] == "extract":
		return "Reach the extraction portal"
	var n := left_on(int(o["deck"]))
	return "Clear deck %d: %d %s left" % [int(o["deck"]) + 1, n, "hostile" if n == 1 else "hostiles"]


## Centre of the extraction zone {deck, x, s} while extraction is the current objective, else {}.
func marker() -> Dictionary:
	if current() != "extract":
		return {}
	var o := objective("extract")
	var c: Vector2 = (o["zone"] as Rect2).get_center()
	return {"deck": int(o["deck"]), "x": c.x, "s": c.y}
