class_name MissionFlow
extends Node
## The mission's objective and end (W6, win side; docs/design/mission-section.md §14, docs/networking.md "Mission
## progress"). Built by TestDrive in stack mode (child "MissionFlow"; none in district mode: MissionRules needs the
## section plan).
##
## RULES: every machine builds the same MissionRules.make(section) (no overrides: extraction on). Who decides:
##   - SOLO (offline, no launched mission): this machine evaluates locally, no network.
##   - CREW, HOST (a host alone included): evaluates every EVAL_INTERVAL s and, whenever evaluate() returns true, sends
##     rules.state() to the crew (Session.send_mission_state -> reliable "mission.state", also carried by mission.go).
##   - CREW, CLIENT: never evaluates; applies what the host sent (Session.mission_state_changed -> rules.apply_state).
## Evaluation is GATED until the mission is released (Session.mission_go; solo at once) AND the enemies have spawned
## (TestDrive.enemies_spawned), because a clear objective latches the first time its deck counts 0 alive.
## FACTS: {"t": shared clock (solo: local seconds), "enemies": TestDrive.enemies_alive_per_deck(), "crew": one entry per
##   mech of the mission still in the crew: {peer, downed, deck, x, s}}, deck / x / s = CityStack.to_deck_arc(position);
##   downed = this machine's PlayerTarget.disabled / a puppet's streamed `downed` (a disabled mech doesn't extract).
##   No crew-wipe loss for now (user decision): make() runs with MissionRules' "wipe" option off (its default), so the
##   rules never report "lost"; mechs keep their auto-respawn.
##
## END FLOW: once rules.outcome is set ("won"; decided here or heard from the host) every machine shows the banner
## (hud_state().banner) for END_HOLD s, then: the HOST calls Session.end_mission(reason) (mission.end to the crew, whose
## TestDrive goes back to the hangar on Session.mission_ended); SOLO just leaves; a CLIENT waits for the host's
## mission.end and only leaves on its own after CLIENT_GRACE more seconds. `finished` tells TestDrive to leave.

signal outcome_reached(outcome: String, reason: String)
## The end flow is over: leave the mission scene (TestDrive does, when it is the current scene).
signal finished(outcome: String)

const EVAL_INTERVAL := 0.25       ## s between host / solo evaluations (4 Hz)
const END_HOLD := 4.0             ## s the end banner shows before the mission ends
const CLIENT_GRACE := 6.0         ## s past END_HOLD a client waits for the host's mission.end before leaving alone
const WAYPOINT_H := 3.0           ## m above the floor the extraction waypoint is drawn at
const TITLES := {"won": "MISSION COMPLETE", "lost": "CREW LOST"}
const REASONS := {"objectives": "Every deck cleared, the crew reached extraction", "crew_down": "Every pilot is down"}
const END_REASONS := {"won": "Mission complete", "lost": "Crew lost"}

var drive: TestDrive
var rules: MissionRules
var crew := false                 ## a crew mission with a session (else solo)
var released := false             ## the mission started (mission_go; solo at once)
var end_left := -1.0              ## s until the end (>= 0 while the banner shows)
var ended := false                ## the end flow is over (finished emitted, or the host ended the mission)
var evaluations := 0              ## evaluate() calls (tests)
var _eval_left := 0.0
var _end_wait := 0.0              ## s since the outcome


## Authority (scripts/net/net.gd): the rules declare the mission's progress themselves (MissionRules.net_fields); the
## rest is this machine's wiring, timers and presentation.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "rules": Net.LOCAL, "crew": Net.SPAWN, "released": Net.LOCAL, "end_left": Net.LOCAL,
		"ended": Net.LOCAL, "evaluations": Net.LOCAL, "_eval_left": Net.PRIVATE, "_end_wait": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 40   # after the combat world, the crew snapshots and EnemySync stepped


func setup(td: TestDrive) -> void:
	drive = td
	var sess := Net.session()
	crew = td.crewed and sess != null and sess.online()
	rebuild()
	if crew:
		released = not td._held
		# Methods, not lambdas: Session outlives this node, and a method connection goes away with it.
		sess.mission_go.connect(_on_go)
		sess.mission_state_changed.connect(_on_state)
		sess.mission_ended.connect(_on_ended)
		if not sess.mission_state().is_empty():
			_on_state(sess.mission_state())
	else:
		released = true


## New rules for the drive's section (setup, and solo N: a new city).
func rebuild() -> void:
	var sec: SectionPlan = drive.stack.section if drive != null and drive.stack != null else null
	rules = MissionRules.make(sec) if sec != null else null
	end_left = -1.0
	_end_wait = 0.0
	ended = false
	_eval_left = 0.0


## This machine decides the progress (host or solo).
func deciding() -> bool:
	if not crew:
		return true
	var sess := Net.session()
	return sess != null and sess.online() and sess.hosting


func _physics_process(dt: float) -> void:
	if rules == null or drive == null:
		return
	if end_left >= 0.0:
		_tick_end(dt)
		return
	if not deciding() or not released or not drive.enemies_spawned:
		return
	_eval_left -= dt
	if _eval_left > 0.0:
		return
	_eval_left = EVAL_INTERVAL
	evaluate_now()


## Host / solo: feed the facts to the rules now; send the state if it changed (crew). True when it changed.
func evaluate_now() -> bool:
	evaluations += 1
	if not rules.evaluate(facts()):
		return false
	if crew:
		Net.session().send_mission_state(rules.state())
	_check_outcome()
	return true


func facts() -> Dictionary:
	var sess := Net.session()
	var t := sess.host_time() if crew and sess != null else Time.get_ticks_msec() / 1000.0
	return {"t": t, "enemies": drive.enemies_alive_per_deck(), "crew": crew_facts()}


## [{peer, downed, deck, x, s}] for this machine's mech and (crew) every teammate's puppet still in the crew.
func crew_facts() -> Array:
	var out: Array = []
	var pt := drive.combat.player_target if drive.combat != null else null
	out.append(_fact(MechSpawn.owner_of(drive.mech), drive.mech, pt != null and pt.disabled))
	if not crew or drive.crew_sync == null:
		return out
	var sess := Net.session()
	for p: int in drive.crew_sync.puppets:
		if sess != null and not sess.roster.has(p):
			continue   # left the crew: no longer extracts
		var pp := drive.crew_sync.puppets[p] as MechPuppet
		if pp == null or not is_instance_valid(pp) or pp.mech == null:
			continue
		out.append(_fact(p, pp.mech, pp.downed))
	return out


func _fact(peer: int, m: Node3D, downed: bool) -> Dictionary:
	var a := drive.stack.to_deck_arc(m.global_position)
	return {"peer": peer, "downed": downed, "deck": int(a["deck"]), "x": float(a["x"]), "s": float(a["s"])}


func _on_go(_elapsed: float) -> void:
	released = true


func _on_ended(_reason: String) -> void:
	ended = true


## Client: the host's progress.
func _on_state(d: Dictionary) -> void:
	if rules == null or deciding():
		return
	rules.apply_state(d)
	_check_outcome()


func _check_outcome() -> void:
	if rules.outcome == "" or end_left >= 0.0 or ended:
		return
	end_left = END_HOLD
	_end_wait = 0.0
	print("[mission] %s (%s)" % [rules.outcome, rules.reason])
	outcome_reached.emit(rules.outcome, rules.reason)


func _tick_end(dt: float) -> void:
	if ended:
		return
	end_left = maxf(end_left - dt, 0.0)
	_end_wait += dt
	var sess := Net.session()
	if crew and not deciding():
		# A client: the host's mission.end takes it back (Session.mission_ended); alone only after the grace.
		if _end_wait < END_HOLD + CLIENT_GRACE:
			return
		if sess != null:
			sess.end_mission()
		_finish()
		return
	if end_left > 0.0:
		return
	if crew and sess != null and sess.online():
		sess.end_mission(str(END_REASONS.get(rules.outcome, "")))
	_finish()


func _finish() -> void:
	ended = true
	finished.emit(rules.outcome)


# --- HUD -----------------------------------------------------------------------------------------------------

## What MissionHud draws (its contract, MissionHud header): {objective: String, waypoint: {pos: Vector3, deck, label}
## or {}, banner: {title, reason, won} or {}}.
func hud_state() -> Dictionary:
	var out := {"objective": "", "waypoint": {}, "banner": {}}
	if rules == null or drive == null:
		return out
	out["objective"] = rules.text()
	var mk := rules.marker()
	if not mk.is_empty() and drive.stack != null:
		out["waypoint"] = {"pos": drive.stack.from_deck_arc(int(mk["deck"]), float(mk["x"]), float(mk["s"]), WAYPOINT_H),
			"deck": int(mk["deck"]), "label": "EXTRACT"}
	if rules.outcome != "":
		out["banner"] = {"title": str(TITLES.get(rules.outcome, rules.outcome.to_upper())),
			"reason": str(REASONS.get(rules.reason, rules.reason)), "won": rules.outcome == "won"}
	return out
