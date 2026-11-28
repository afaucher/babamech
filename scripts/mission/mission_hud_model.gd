class_name MissionHudModel
extends RefCounted
## What MissionHud draws, built from its MissionFlow (one per flow: MissionFlow.hud_model). Presentation only: it reads the
## flow's rules, plan, director, depots, world and drive, never writes them; its own state is this machine's HUD memory
## (the orders heard, the projected rings, the zone view, the deck the panel holds). Every var LOCAL, nothing is synced.
## Interface: build() (MissionHud.source); the flow feeds it alert(order, text, deck) when an order opens a door, `zones`
## (this machine's view of the flag / defend / hold zones) from its presentation tick, and reset() on a rebuild.

const WAYPOINT_H := 3.0           ## m above the floor the extraction waypoint is drawn at
const MARKER_H := 4.0             ## m above the floor objective markers are drawn at
const PANEL_STAND_H := 2.5        ## m: within this of a deck's floor the pilot stands on it (the panel's current deck)
const SOURCE_H := 4.0             ## m above the floor a wave source's arrow points at
const ALERT_AFTER := 6.0          ## s past open_at the "Reinforcements, east gate" line stays
const RING_POINTS := 40           ## points of a projected objective ring
const ALERTS_MAX := 8             ## orders remembered
const TITLES := {"won": "MISSION COMPLETE", "lost": "CREW LOST"}
const LOST_TITLES := {"objective_failed": "MISSION FAILED"}
const ALLY_FOR := 5.0             ## s an ally line stays (MissionRules.ally_due; text only, the alert strip's style)
const REASONS := {"objectives": "Every primary done, the crew walked out through the exit",
	"crew_down": "Every pilot is down", "objective_failed": "Objective failed"}
const MARK_LABEL := {"flag": "FLAG", "defend": "DEFEND", "hold": "EXTRACT"}

var flow: MissionFlow
var zones: Dictionary = {}        ## objective id -> {crew: bool, enemies: int} (this machine's view; MissionFlow._present)
var _alerts: Array = []           ## orders heard, [{order, text, deck}]
var _ally: Array = []             ## the ally's lines said, [{text, t}] (mission clock)
var _rings: Dictionary = {}       ## defend id -> PackedVector3Array (its ring on the floor)
var _hud_deck := -1               ## the deck the local pilot last stood on (kept on a ramp / in a shaft; -1 none yet)


func net_fields() -> Dictionary:
	return {"flow": Net.LOCAL, "zones": Net.LOCAL, "_alerts": Net.LOCAL, "_rings": Net.LOCAL, "_ally": Net.LOCAL,
		"_hud_deck": Net.LOCAL}   # the local pilot's deck for the objective panel, never sent


func _init(f: MissionFlow = null) -> void:
	flow = f


## A new mission on the flow (MissionFlow.rebuild): forget the orders, rings and zones (the panel's deck stays).
func reset() -> void:
	_alerts = []
	_ally = []
	_rings = {}
	zones = {}


## An order opened a wave door: its "Reinforcements, <source>" line.
func alert(order: Dictionary, text: String, deck: int) -> void:
	_alerts.append({"order": order, "text": text, "deck": deck, "t": flow.now() if flow != null else 0.0})
	if _alerts.size() > ALERTS_MAX:
		_alerts.pop_front()


## The ally said `text` at mission clock `t` (MissionFlow._present from MissionRules.ally_due): shown ALLY_FOR s in the
## alert strip, text only.
func ally(text: String, t: float) -> void:
	_ally.append({"text": text, "t": t})


## The ally's lines said so far (tests).
func ally_said() -> Array:
	return _ally.map(func(a: Dictionary) -> String: return str(a["text"]))


## What MissionHud draws (its contract, MissionHud header): {objective: String, waypoint: {pos: Vector3, deck, label}
## or {}, banner: {title, reason, won} or {}}; plan mode adds plan: true, deck, lines, waves [released, total],
## markers [{pos, label, role, state, kind}], rings [PackedVector3Array], zone {label, progress, total, contested,
## countdown (hold: seconds left), percent (flag: whole percent)} or {}, panel (MissionRules.panel() for this pilot's
## deck and position, plus extra: [the depot line]; its route_at, the way toward the next step (the amber "Proceed to
## deck n", or a visited deck's unfinished primary), is also the waypoint "RAMP DOWN" / "RAMP UP" / "SHAFT DOWN" when
## there is no extraction waypoint),
## alerts [{text, pos: Vector3 or null, left: s to the door, t: when heard, ally: true for the ally's lines (no door, no
## marker)}], oldest first (MissionHud draws the last).
func build() -> Dictionary:
	var out := {"objective": "", "waypoint": {}, "banner": {}}
	if flow == null:
		return out
	var rules := flow.rules
	var drive := flow.drive
	if rules == null or drive == null:
		return out
	out["objective"] = rules.text()
	var mk := rules.marker()
	if not mk.is_empty() and drive.stack != null:
		out["waypoint"] = {"pos": drive.stack.from_deck_arc(int(mk["deck"]), float(mk["x"]), float(mk["s"]), WAYPOINT_H),
			"deck": int(mk["deck"]), "label": "EXIT" if rules.exit_open() else "EXTRACT"}
	if rules.outcome != "":
		var title := str(TITLES.get(rules.outcome, rules.outcome.to_upper()))
		if rules.outcome == "lost" and LOST_TITLES.has(rules.reason):
			title = str(LOST_TITLES[rules.reason])
		var why := str(REASONS.get(rules.reason, rules.reason))
		out["banner"] = {"title": title, "reason": why, "won": rules.outcome == "won"}
	if flow.plan != null and drive.stack != null and drive.mech != null:
		_plan_hud(out)
	return out


func _plan_hud(out: Dictionary) -> void:
	var rules := flow.rules
	var drive := flow.drive
	var here := drive.stack.to_deck_arc(drive.mech.global_position)
	var k := int(here["deck"])
	out["plan"] = true
	out["deck"] = k
	out["lines"] = rules.lines(k)
	var core_line := flow.depots.progress_line() if flow.depots != null else ""
	if core_line != "":   # this pilot taking a power core: an objective-style line, kept inside the panel's LIST_MAX
		(out["lines"] as Array).insert(mini((out["lines"] as Array).size(), MissionHud.LIST_MAX - 1), core_line)
	out["panel"] = _panel(here, core_line)
	var to: Dictionary = (out["panel"] as Dictionary).get("route_at", {})
	if (out["waypoint"] as Dictionary).is_empty() and not to.is_empty():   # the next step's way
		out["waypoint"] = {"pos": drive.stack.from_deck_arc(int(to["deck"]), float(to["x"]), float(to["s"]), WAYPOINT_H),
			"deck": int(to["deck"]), "label": "%s %s" % [str(to["kind"]).to_upper(), "DOWN" if int(to["dir"]) > 0 else "UP"]}
	var wv: Array = flow.director.state()["waves"]
	out["waves"] = wv[k] if k >= 0 and k < wv.size() else [0, 0]
	var marks: Array = []
	var rings: Array = []
	for m: Dictionary in rules.markers(k):
		var ty := str(m["type"])
		if ty == "sweep" or ty == "hold":
			continue   # deck-wide / the extraction waypoint
		var label := str(MARK_LABEL.get(ty, ty.to_upper()))   # a bonus reads like a primary: the plain type name
		marks.append({"pos": drive.stack.from_deck_arc(k, float(m["x"]), float(m["s"]), MARKER_H), "label": label,
			"role": m["role"], "state": m["state"], "kind": ty})
		if ty == "defend":
			rings.append(_ring(m))
	out["markers"] = marks
	out["rings"] = rings
	out["zone"] = _zone_hud()
	var alerts: Array = []
	var t := flow.now()
	for a: Dictionary in _alerts:
		var o: Dictionary = a["order"]
		var open_at := float(o["open_at"])
		if t > open_at + ALERT_AFTER:
			continue
		var text := str(a["text"])
		var pos: Variant = null
		if int(a["deck"]) != k:
			text += ", deck %d" % (int(a["deck"]) + 1)
		elif flow.world != null:
			pos = flow.alert_point(o)   # the real opening: door, air door `out`, ramp / shaft mouth (playtest R2.24)
		alerts.append({"text": text, "pos": pos, "left": maxf(open_at - t, 0.0), "t": float(a.get("t", 0.0))})
	for a: Dictionary in _ally:
		if t >= float(a["t"]) and t < float(a["t"]) + ALLY_FOR:
			alerts.append({"text": str(a["text"]), "pos": null, "left": 0.0, "ally": true, "t": float(a["t"])})
	alerts.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["t"]) < float(y["t"]))   # the newest last
	out["alerts"] = alerts


## The objective panel (MissionRules.panel) for the local pilot: their deck, held while they are off every floor (on a
## ramp, falling down a shaft: more than PANEL_STAND_H from the floor under them) until they stand on the next one, and
## their (x, s) on it; `extra` the depot line (MissionDepots.progress_line()), drawn at the end of this deck's section
## (MissionRules.fit). Local facts only.
func _panel(here: Dictionary, core_line: String) -> Dictionary:
	var k := int(here["deck"])
	if _hud_deck < 0 or absf(float(here.get("h", 0.0))) <= PANEL_STAND_H:
		_hud_deck = k
	var s := float(here["s"])
	var sec := flow.drive.stack.section
	if _hud_deck != k and sec != null:   # the same top-down point on the held deck (decks are concentric)
		s *= sec.radius_of(_hud_deck) / maxf(sec.radius_of(k), 1.0)
	var pn := flow.rules.panel(_hud_deck, Vector2(float(here["x"]), s))
	pn["extra"] = [core_line] if core_line != "" else []
	return pn


## The zone progress bar while anyone stands in an active flag / hold zone: {label, progress, total, contested}.
func _zone_hud() -> Dictionary:
	var rules := flow.rules
	for o: Dictionary in rules.objectives:
		var id: String = o["id"]
		var ty := str(o["type"])
		if (ty != "flag" and ty != "hold") or rules.obj_state(id) != "active":
			continue
		var zs: Dictionary = zones.get(id, {})
		if not bool(zs.get("crew", false)):
			continue
		var objs: Dictionary = rules.state().get("objs", {})
		var tot := float((objs.get(id, [0, 0, 0]) as Array)[2])
		return {"id": id, "label": "RAISING THE FLAG" if ty == "flag" else "HOLDING THE EXIT",
			"progress": rules.obj_progress(id), "total": tot, "contested": int(zs.get("enemies", 0)) > 0,
			"countdown": false, "percent": true}

	return {}


func _ring(m: Dictionary) -> PackedVector3Array:
	var id := str(m["id"])
	if _rings.has(id):
		return _rings[id]
	var pts := PackedVector3Array()
	var r := float(m["radius"])
	for i in RING_POINTS + 1:
		var a := TAU * float(i) / float(RING_POINTS)
		pts.append(flow.drive.stack.from_deck_arc(int(m["deck"]), float(m["x"]) + cos(a) * r, float(m["s"]) + sin(a) * r, 0.3))
	_rings[id] = pts
	return pts
