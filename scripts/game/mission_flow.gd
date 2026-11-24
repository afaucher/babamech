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
##   rules never report "lost" for the crew; mechs keep their auto-respawn.
##
## PLAN MODE (DEV, TestDrive.objectives: `--objectives`, GameSettings dev objectives, mission.launch params.objectives;
## docs/design/mission-objectives.md §7 phase 1, §9). Every machine builds plan = MissionPlan.make(section, test_plan),
## rules = MissionRules.make(section, {plan}), director = PacingDirector.make(plan, test_director, crew_size()), then
## stack.setup_mission(plan) (Environment's MissionWorld: wave doors, flag masts, defend relays, the portal) and
## rules.set_site() from its flag_site / asset_site, all before the first evaluate. The load barrier's checksum joins
## plan.checksum() (TestDrive.mission_checksum). The HOST / SOLO tick (same gate, EVAL_INTERVAL, t = Session.host_time(),
## solo: this node's mission clock) evaluates the rules first, then ticks the director with the fresh state:
##   rules facts    t, enemies, crew, waves_left, waves, zone_enemies {objective id: enemies inside its radius}, assets
##                  {defend id: hp}, defend_waves
##   director facts alive, active / engaging / pilots / kills (PacingFacts: the host's view, pacing-director.md 1.2),
##                  wave_alive {wave: {alive, total}}, wave_pending, wave_size, crew, objectives = rules.state(), closed
##                  (none yet). Director events go to the combat log (CombatLog.note_release / note_pace) and to
##                  "[mission] release|pace|quiet" lines; a completed scout beacon (a drone's EnemyBase.comms_relayed) calls
##                  director.scout_call. Order reason: build | cap | objective | scout | patrol.
##   gate bays      an order from a gate with a staging bay (MissionWorld.source_bay `ok`) spawns its units AT THE ORDER,
##                  staged (dormant, not hittable) in the bay in a seeded loose formation (BayFormation); when the door
##                  is passable (source_state(id).passable, open_at + MissionWorld.OPENING) the squad rolls them out
##                  (EnemySquad.roll_out_wave) and the door is held open while they leave. Other sources spawn at open_at.
##   each order     {wave, deck, source, open_at, max_units}: the host sends it (Session.send_mission_wave: reliable
##                  "mission.wave"), every machine calls stack.mission.open_source(source, open_at) (`opened` records it),
##                  and when the shared clock reaches open_at the host spawns it (antigravity's EnemySpawner.spawn_wave,
##                  see _spawn_wave; stubbed while it is missing: nothing spawns and the director counts the wave beaten
##                  after its GRACE)
##   state          rules.state() + {"dir": director.state(), "assets": {defend id: hp}}, sent whenever it changes;
##                  clients apply both (rules.apply_state, director.apply_state)
## The defend relay's HP is held here on the host (`asset_hp`, set_asset_hp / damage_asset). Every machine registers the
## relay as Weapons' AssetTarget, live only while its defend objective is ACTIVE (_sync_asset_targets: team "player", so enemies
## shoot it and friendly fire follows the crew rule; damage_asset ignores hits otherwise, and the host resets it to full HP
## when it goes active: _arm_assets); outside that window the relay is scenery. The host's applied hits come back
## through damage_asset. PRESENTATION on every machine from the replicated state
## (_present, 4 Hz): set_flag(id, true) once a flag is done, set_zone(id, idle | contested | ours) (from the crew and
## the enemies this machine sees in the ring: cosmetic), set_asset(id, hp), set_portal(hold progress), set_hold_zone; the
## mission clock goes to MissionWorld.advance_to every frame. A failed primary ends the mission "lost" (objective_failed).
##
## END FLOW: once rules.outcome is set ("won"; decided here or heard from the host) every machine shows the banner
## (hud_state().banner) for END_HOLD s, then: the HOST calls Session.end_mission(reason) (mission.end to the crew, whose
## TestDrive goes back to the hangar on Session.mission_ended); SOLO just leaves; a CLIENT waits for the host's
## mission.end and only leaves on its own after CLIENT_GRACE more seconds. `finished` tells TestDrive to leave.

signal outcome_reached(outcome: String, reason: String)
## The end flow is over: leave the mission scene (TestDrive does, when it is the current scene).
signal finished(outcome: String)
## Plan mode, every machine: a wave's door was scheduled (stack.mission.open_source) from a host order.
signal wave_ordered(order: Dictionary)

const EVAL_INTERVAL := 0.25       ## s between host / solo evaluations (4 Hz)
const END_HOLD := 4.0             ## s the end banner shows before the mission ends
const CLIENT_GRACE := 6.0         ## s past END_HOLD a client waits for the host's mission.end before leaving alone
const WAYPOINT_H := 3.0           ## m above the floor the extraction waypoint is drawn at
const MARKER_H := 4.0             ## m above the floor objective markers are drawn at
const PANEL_STAND_H := 2.5        ## m: within this of a deck's floor the pilot stands on it (the panel's DECK n of m)
const SOURCE_H := 4.0             ## m above the floor a wave source's arrow points at
const ALERT_AFTER := 6.0          ## s past open_at the "Reinforcements, east gate" line stays
const RING_POINTS := 40           ## points of a projected objective ring
const TITLES := {"won": "MISSION COMPLETE", "lost": "CREW LOST"}
const LOST_TITLES := {"objective_failed": "MISSION FAILED"}
const REASONS := {"objectives": "Every deck cleared, the crew reached extraction", "crew_down": "Every pilot is down",
	"objective_failed": "Objective failed"}
const PLAN_REASONS := {"objectives": "Every primary done, the crew held the extraction portal"}
const END_REASONS := {"won": "Mission complete", "lost": "Crew lost"}
const LOST_END_REASONS := {"objective_failed": "Objective failed"}
const MARK_LABEL := {"flag": "FLAG", "defend": "DEFEND", "hold": "EXTRACT"}
const SPAWNER := "res://scripts/enemy/enemy_spawner.gd"
const ASSET_MAX_HP := 600.0       ## a defend relay's hit points (Weapons' AssetTarget hits are in points; asset_hp is 0..1) ...
## ... times this by crew size (index = pilots - 1; defend balance 2026-11-24: a lone veteran bot at 90 %+ structure lost
## relays in 40-110 s): the relay takes hits in points against ASSET_MAX_HP x scale.
const ASSET_HP_SCALE := [1.75, 1.35, 1.0, 1.0]
const ASSET_RADIUS := 2.5         ## m, the relay's hit-sphere radius for combat
const ASSET_HEIGHT := 6.0         ## m, the hit spheres stack this high
const NO_OBJECTIVES_FLAG := "--no-objectives"
const ROUTE_EVERY := 2.0          ## s between the host's source route measurements (PacingDirector source choice)
const ROLL_OUT_HOLD := 15.0       ## s a gate stays open once its staged group starts rolling out (none is shut in)

## Tests: overrides for MissionPlan.make / PacingDirector.make in plan mode (set the same on every machine of a test:
## the plan's checksum includes its options).
static var test_plan: Dictionary = {}
static var test_director: Dictionary = {}

var drive: TestDrive
var rules: MissionRules
var crew := false                 ## a crew mission with a session (else solo)
var released := false             ## the mission started (mission_go; solo at once)
var end_left := -1.0              ## s until the end (>= 0 while the banner shows)
var ended := false                ## the end flow is over (finished emitted, or the host ended the mission)
var evaluations := 0              ## evaluate() calls (tests)
## Plan mode (null otherwise): the mission plan, the host's wave queue (a client's mirrors the host's state()), the
## stack's MissionWorld.
var plan: MissionPlan
var director: PacingDirector
var pacing: PacingFacts           ## host: the fight as the director sees it (engaged, in play, kills, pilot structure)
var _rollouts: Array = []         ## host: staged gate groups waiting for their door [{wave, source, open_at}]
var _routes: Dictionary = {}      ## host: last _source_routes()
var _route_t := -INF              ## host: when they were computed
var world: MissionWorld
var asset_hp: Dictionary = {}     ## defend id -> 0..1: the host decides, clients apply the state's "assets"
var _asset_targets: Dictionary = {}   ## defend id -> Weapons' AssetTarget (every machine; LOCAL bookkeeping)
var _asset_armed: Dictionary = {}     ## host: defend id -> true once its objective went active (HP reset to full then)
var opened: Array = []            ## every machine: [{wave, source, open_at}] each open_source this machine made (tests)
var unspawned: Array = []         ## host: wave ids ordered while antigravity's spawn_wave is missing (the stub)
var _eval_left := 0.0
var _end_wait := 0.0              ## s since the outcome
var _clock := 0.0                 ## solo plan mode: the mission clock (physics seconds since release)
var _sent: Dictionary = {}        ## host: the plan state last sent
var _spawns: Array = []           ## host: orders waiting for their door (spawned at open_at)
var _pending: Dictionary = {}     ## host: wave id -> units still to spawn (the spawner's report)
var _wave_total: Dictionary = {}  ## host: wave id -> units of it seen so far
var _seen: Dictionary = {}        ## host: enemy instance id -> true (counted in _wave_total)
var _wave_size: Dictionary = {}   ## host: wave id -> units the spawner will make (EnemySpawner.plan_wave dry run)
var _wave_size_crew := 0          ## host: the crew size _wave_size was computed for
var _present_left := 0.0
var _pushed: Dictionary = {}      ## presentation: key -> last value pushed to the world
var _alerts: Array = []           ## HUD: orders heard, [{order, text, deck, pos}]
var _rings: Dictionary = {}       ## HUD: defend id -> PackedVector3Array (its ring on the floor)
var _zone_seen: Dictionary = {}   ## presentation: objective id -> {crew: bool, enemies: int} (this machine's view)
var _hud_deck := -1               ## HUD: the deck the local pilot last stood on (kept on a ramp / in a shaft; -1 none yet)
## Plan mode: the military supply depots (MissionDepots child, every machine; pacing-director.md §2). Their state rides in
## plan_state()["depots"]; the claim / grant messages are MissionDepots' own.
var depots: MissionDepots


## Authority (scripts/net/net.gd): the rules and the director declare the mission's progress themselves
## (MissionRules.net_fields, PacingDirector.net_fields); the rest is this machine's wiring, timers and presentation.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "rules": Net.LOCAL, "crew": Net.SPAWN, "released": Net.LOCAL, "end_left": Net.LOCAL,
		"ended": Net.LOCAL, "evaluations": Net.LOCAL, "_eval_left": Net.PRIVATE, "_end_wait": Net.LOCAL,
		"plan": Net.LOCAL, "director": Net.LOCAL, "world": Net.LOCAL, "pacing": Net.LOCAL, "_rollouts": Net.PRIVATE,
		"_routes": Net.PRIVATE, "_route_t": Net.PRIVATE,
		"_asset_targets": Net.LOCAL,   # this machine's combat registrations of the relays
		"_asset_armed": Net.PRIVATE,   # host: relays whose defend went active (their one HP reset done)
		"asset_hp": Net.OWNER,         # the host decides (damage_asset), mission.state carries it
		"opened": Net.LOCAL, "unspawned": Net.PRIVATE, "_clock": Net.PRIVATE, "_sent": Net.PRIVATE, "_spawns": Net.PRIVATE,
		"_pending": Net.PRIVATE, "_wave_total": Net.PRIVATE, "_seen": Net.PRIVATE, "_wave_size": Net.PRIVATE, "_wave_size_crew": Net.PRIVATE, "_present_left": Net.LOCAL,
		"_pushed": Net.LOCAL, "_alerts": Net.LOCAL, "_rings": Net.LOCAL, "_zone_seen": Net.LOCAL,
		"_hud_deck": Net.LOCAL,        # the local pilot's deck for the objective panel, never sent
		"depots": Net.LOCAL}   # MissionDepots declares its own state (net_fields)


## Plan mode (objectives) wanted by this machine (solo, or the crews it hosts): the default. `--no-objectives` selects the
## old clear-and-extract mission, `--objectives` forces it on (kept for old scripts); else GameSettings "objectives"
## (default true). In a crew every machine plays the HOST's choice (mission.launch params.objectives).
static func objectives_wanted(args: PackedStringArray, settings: Dictionary) -> bool:
	if args.has(NO_OBJECTIVES_FLAG):
		return false
	if args.has("--objectives"):
		return true
	return bool(settings.get("objectives", true))


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
		sess.mission_wave.connect(_on_wave)
		if not sess.mission_state().is_empty():
			_on_state(sess.mission_state())
		if not deciding():
			for o: Variant in sess.mission_waves():
				if o is Dictionary:
					_on_wave(o)
	else:
		released = true


## New rules for the drive's section (setup, and solo N: a new city).
func rebuild() -> void:
	var sec: SectionPlan = drive.stack.section if drive != null and drive.stack != null else null
	if depots != null and is_instance_valid(depots):
		depots.teardown()
		depots.queue_free()
	depots = null
	plan = null
	director = null
	if pacing != null:
		pacing.unbind()
	pacing = null
	_rollouts = []
	_routes = {}
	_route_t = -INF
	world = null
	asset_hp = {}
	_asset_targets = {}
	_asset_armed = {}
	_wave_size = {}
	_wave_size_crew = 0
	opened = []
	unspawned = []
	_sent = {}
	_spawns = []
	_pending = {}
	_wave_total = {}
	_seen = {}
	_pushed = {}
	_alerts = []
	_rings = {}
	_zone_seen = {}
	_clock = 0.0
	if sec != null and drive.objectives:
		var pre := drive.prebuilt_plan
		var ready := pre != null and drive.stack.mission != null
		plan = pre if ready else MissionPlan.make(sec, test_plan)
		rules = MissionRules.make(sec, {"plan": plan})
		director = PacingDirector.make(plan, test_director, crew_size())
		# The stepped load set the world up over frames already (TestDrive.prebuilt_plan); otherwise in one call.
		world = drive.stack.mission if ready else drive.stack.setup_mission(plan)
		for o: Dictionary in plan.objectives:
			var id: String = o["id"]
			var site: Dictionary = {}
			match str(o["type"]):
				"flag":
					site = world.flag_site(id)
				"defend":
					site = world.asset_site(id)
					asset_hp[id] = clampf(float((o["params"] as Dictionary).get("asset_hp", 1.0)), 0.0, 1.0)
			if not site.is_empty() and bool(site.get("ok", true)):   # ok false: no clear ground, the plan's site stays
				rules.set_site(id, float(site["x"]), float(site["s"]))
				director.set_site(id, float(site["x"]), float(site["s"]))
		depots = MissionDepots.new()
		depots.name = "MissionDepots"
		add_child(depots)
		depots.setup(self)
	else:
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


## The mission clock: the shared clock in a crew, this node's own (physics seconds since release) solo.
func now() -> float:
	if crew:
		var sess := Net.session()
		return sess.host_time() if sess != null else 0.0
	return _clock


func _physics_process(dt: float) -> void:
	if rules == null or drive == null:
		return
	if plan != null:
		if released and not crew:
			_clock += dt
		_tick_world(dt)
	if end_left >= 0.0:
		_tick_end(dt)
		return
	if not deciding() or not released or not drive.enemies_spawned:
		return
	if plan != null:
		_spawn_due()
		_wire_air_doors()
	_eval_left -= dt
	if _eval_left > 0.0:
		return
	_eval_left = EVAL_INTERVAL
	evaluate_now()


## Host / solo: feed the facts to the rules now; send the state if it changed (crew). True when it changed.
func evaluate_now() -> bool:
	evaluations += 1
	if plan != null:
		return _evaluate_plan()
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
## Every pilot (TestDrive.crew_members: the local mech, the host's hangar bots, the puppets of members still in the crew;
## a bot's peer is its negative pilot id, docs/design/hangar-bots.md).
func crew_facts() -> Array:
	var out: Array = []
	for c: Dictionary in drive.crew_members():
		out.append(_fact(int(c["peer"]), c["mech"] as Node3D, bool(c["downed"]), bool(c.get("redeploying", false))))
	return out


## `redeploying` (DownedRules: held to respawn, the penalty runs; downed is true too): MissionRules' wipe never fires
## while anyone redeploys; everything that skips downed pilots (zones, flags, depots, the director) skips it too.
func _fact(peer: int, m: Node3D, downed: bool, redeploying: bool = false) -> Dictionary:
	var a := drive.stack.to_deck_arc(m.global_position)
	return {"peer": peer, "downed": downed, "redeploying": redeploying, "deck": int(a["deck"]), "x": float(a["x"]),
		"s": float(a["s"])}


func _on_go(_elapsed: float) -> void:
	released = true


func _on_ended(_reason: String) -> void:
	ended = true


## Client: the host's progress.
func _on_state(d: Dictionary) -> void:
	if rules == null or deciding():
		return
	rules.apply_state(d)
	if plan != null:
		if d.get("dir") is Dictionary:
			director.apply_state(d["dir"])
		if d.get("depots") is Dictionary and depots != null:
			depots.apply_state(d["depots"])
		if d.get("assets") is Dictionary:
			for id: Variant in d["assets"]:
				asset_hp[str(id)] = float(d["assets"][id])
		_present()
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
		sess.end_mission(end_reason())
	_finish()


## What mission.end says for the outcome ("Mission complete", "Crew lost", "Objective failed").
func end_reason() -> String:
	if rules.outcome == "lost" and LOST_END_REASONS.has(rules.reason):
		return str(LOST_END_REASONS[rules.reason])
	return str(END_REASONS.get(rules.outcome, ""))


func _finish() -> void:
	ended = true
	finished.emit(rules.outcome)


# --- Plan mode: the host's tick ------------------------------------------------------------------------------

func _evaluate_plan() -> bool:
	var t := now()
	var crew_f := crew_facts()
	var enemies := drive.enemies_alive_per_deck()
	var live := _live_enemies()
	var changed := rules.evaluate({"t": t, "enemies": enemies, "crew": crew_f, "waves_left": director.waves_left_all(),
		"waves": director.state()["waves"], "zone_enemies": _zone_enemies(live), "assets": asset_hp.duplicate(),
		"defend_waves": director.objective_waves()})
	_arm_assets()
	var orders := director.tick(t, _director_facts(enemies, crew_f, live))
	for o: Dictionary in orders:
		if crew:
			Net.session().send_mission_wave(o)
		_open(o)
		if not source_bay(str(o["source"])).is_empty():
			_spawn_wave(o)   # staged in the closed bay now; rolled out when the door is passable (_roll_due)
			_rollouts.append({"wave": str(o["wave"]), "source": str(o["source"]), "open_at": float(o["open_at"])})
		else:
			_spawns.append(o)
	_log_director()
	var st := plan_state()
	if st != _sent:
		_sent = st
		changed = true
		if crew:
			Net.session().send_mission_state(st)
	_present()
	_check_outcome()
	return changed


## What the host broadcasts in plan mode: rules.state() + {"dir": director.state(), "assets": {defend id: hp}}.
func plan_state() -> Dictionary:
	var st := rules.state()
	st["dir"] = director.state()
	var a := {}
	for id: String in asset_hp:
		a[id] = snappedf(float(asset_hp[id]), 0.01)
	st["assets"] = a
	if depots != null:
		st["depots"] = depots.state()
	return st


## Living enemies of this machine's squad (the host's real ones, a client's puppets): [EnemyBase].
func _live_enemies() -> Array:
	var out: Array = []
	if drive.combat == null or drive.combat.squad == null:
		return out
	for e in drive.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed():
			out.append(e)
	return out


## {objective id: living enemies inside its radius on its deck} for every flag / defend objective.
func _zone_enemies(live: Array) -> Dictionary:
	var out := {}
	var arcs: Array = []
	for e: EnemyBase in live:
		arcs.append(drive.stack.to_deck_arc(e.global_position))
	for o: Dictionary in rules.objectives:
		var ty := str(o["type"])
		if ty != "flag" and ty != "defend":
			continue
		var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
		var r := float(o["radius"])
		var n := 0
		for a: Dictionary in arcs:
			if int(a["deck"]) == int(o["deck"]) and at.distance_to(Vector2(float(a["x"]), float(a["s"]))) <= r:
				n += 1
		out[o["id"]] = n
	return out


func _director_facts(enemies: Array, crew_f: Array, live: Array) -> Dictionary:
	var n := plan.deck_count
	var pf := _pacing_facts(crew_f, live)
	var garrison: Array = []
	garrison.resize(n)
	garrison.fill(0)
	var wave_alive := {}
	if drive.combat != null and drive.combat.squad != null:
		for e in drive.combat.squad.enemies:
			if not is_instance_valid(e) or e.wave == "":
				continue
			var key := e.get_instance_id()
			if not _seen.has(key):
				_seen[key] = true
				_wave_total[e.wave] = int(_wave_total.get(e.wave, 0)) + 1
	for id: String in _wave_total:
		wave_alive[id] = {"alive": 0, "total": int(_wave_total[id])}
	for e: EnemyBase in live:
		if e.wave == "":
			if e.spawn_deck >= 0 and e.spawn_deck < n:
				garrison[e.spawn_deck] += 1
		elif wave_alive.has(e.wave):
			wave_alive[e.wave]["alive"] += 1
	var decks: Array = []
	for c: Dictionary in crew_f:
		if not bool(c["downed"]) and not decks.has(int(c["deck"])):
			decks.append(int(c["deck"]))
	return {"alive": enemies, "garrison_alive": garrison, "wave_alive": wave_alive, "wave_pending": _pending.duplicate(),
		"crew_deck": decks, "crew": crew_f, "wave_size": wave_sizes(), "objectives": rules.state(), "closed": [],
		"active": pf.get("active", enemies), "engaging": pf.get("engaging", []), "pilots": pf.get("pilots", {}),
		"kills": pf.get("kills", []), "source_route": _source_routes(crew_f)}


## Host: {source id: walk-route metres from the standing crew's centre on its deck} (EnemySquad.find_arc_path over the
## road graph), refreshed every ROUTE_EVERY s; -1 where no path was found (the director then measures straight).
func _source_routes(crew_f: Array) -> Dictionary:
	var t := now()
	if t < _route_t + ROUTE_EVERY and not _routes.is_empty():
		return _routes
	_route_t = t
	_routes = {}
	var squad: Variant = drive.combat.squad if drive.combat != null else null
	if squad == null or not (squad as Object).has_method("find_arc_path"):
		return _routes
	var sum := {}
	for c: Dictionary in crew_f:
		if bool(c["downed"]):
			continue
		var k := int(c["deck"])
		var e: Array = sum.get(k, [Vector2.ZERO, 0])
		sum[k] = [e[0] + Vector2(float(c["x"]), float(c["s"])), int(e[1]) + 1]
	for k: int in sum:
		var centre: Vector2 = sum[k][0] / float(sum[k][1])
		for s: Dictionary in plan.deck_sources(k):
			var to := Vector2(float(s["x"]), float(s["s"]))
			var path: Array = squad.call("find_arc_path", centre, to, k)
			if path.is_empty():
				_routes[str(s["id"])] = -1.0
				continue
			var d := centre.distance_to(path[0])
			for i in range(1, path.size()):
				d += (path[i - 1] as Vector2).distance_to(path[i])
			d += (path[path.size() - 1] as Vector2).distance_to(to)
			_routes[str(s["id"])] = snappedf(d, 0.1)
	return _routes


## Host: PacingFacts over every pilot (crew_facts order: the same entries as TestDrive.crew_members) and the live enemies.
func _pacing_facts(crew_f: Array, live: Array) -> Dictionary:
	if drive.combat == null or drive.combat.world == null:
		return {}
	if pacing == null:
		pacing = PacingFacts.new()
		pacing.bind(drive.combat.world, now)
		pacing.scout_call = _on_scout_call
	var targets := {}
	for tg in drive.combat.world.targets:
		if is_instance_valid(tg) and tg is PlayerTarget and (tg as PlayerTarget).mech != null:
			targets[(tg as PlayerTarget).mech.get_instance_id()] = tg
	var members: Array = drive.crew_members() if drive.has_method("crew_members") else []
	var pilots: Array = []
	for i in mini(members.size(), crew_f.size()):
		var m: Variant = members[i].get("mech")
		var pt: Variant = targets.get((m as Object).get_instance_id()) if m is Object and is_instance_valid(m) else null
		pilots.append({"peer": crew_f[i]["peer"], "target": pt, "mech": m, "deck": crew_f[i]["deck"],
				"downed": crew_f[i]["downed"]})
	return pacing.collect(pilots, drive.stack, live, plan.deck_count)


## Host: a scout drone completed its beacon (PacingFacts): the director decides on its next tick.
func _on_scout_call(deck: int, x: float, s: float, scout_id: String) -> void:
	if director == null or not deciding():
		return
	director.scout_call(deck, x, s, scout_id, now())
	print("[mission] scout call: %s on deck %d at x %.0f s %.0f" % [scout_id, deck, x, s])
	CombatLog.note_scout("completed", scout_id, deck)


## Host: the director's events into the combat log (when one runs) and the run log.
func _log_director() -> void:
	for ev: Dictionary in director.take_events():
		match str(ev["tag"]):
			"release":
				print("[mission] release %s deck %d %s size %d reason %s" % [ev["wave"], int(ev["deck"]), ev["source"],
					int(ev["size"]), ev["reason"]])
				CombatLog.note_release(str(ev["wave"]), int(ev["deck"]), str(ev["source"]), int(ev["size"]), null,
					str(ev["reason"]))
			"pace":
				print("[mission] pace deck %d %s -> %s i %d reason %s" % [int(ev["deck"]), ev["from"], ev["to"], int(ev["i"]),
					ev["reason"]])
				CombatLog.note_pace(int(ev["deck"]), str(ev["from"]), str(ev["to"]), float(ev["i"]), str(ev["reason"]))
			"quiet":
				print("[mission] quiet deck %d %.1f s" % [int(ev["deck"]), float(ev["dur"])])
			"scout":
				print("[mission] scout call %s %s deck %d" % [ev["drone"], ev["ev"], int(ev["deck"])])
			"hunt":
				var k := int(ev["deck"])
				var squad: Variant = drive.combat.squad if drive.combat != null else null
				var sent := 0
				if squad != null and (squad as Object).has_method("send_garrison_hunt"):
					var near := drive.stack.from_deck_arc(k, float(ev["x"]), float(ev["s"]), 0.0)
					sent = int(squad.call("send_garrison_hunt", k, int(ev["units"]), near))
				print("[mission] release garrison-hunt deck %d size %d reason cap" % [k, sent])
				CombatLog.note_release("garrison", k, "-", sent, null, "hunt")


## Host: {group id: units} for every reserve group of the plan (the director's half rule and the cap room it holds until
## a group's units appear), from EnemySpawner.plan_wave with max_units 0 (counts, places nothing) at the reserve budget
## (PacingDirector.reserve_budget: the solo deck budget x CREW_SCALE); cached per crew size.
func wave_sizes() -> Dictionary:
	var n := director.crew_n if director != null else 1
	if n == _wave_size_crew and not _wave_size.is_empty():
		return _wave_size
	_wave_size_crew = n
	_wave_size = {}
	var spawner := load(SPAWNER) as GDScript
	if plan == null or spawner == null or not _has_static(spawner, "plan_wave") or not _has_static(spawner, "deck_budget"):
		return _wave_size
	for k in plan.deck_count:
		var pl := plan.pool(k)
		var budget := PacingDirector.reserve_budget(int(spawner.call("deck_budget", 1, k)), n)
		for w: Dictionary in pl.get("reserve", []):
			var r: Variant = spawner.call("plan_wave", null, null, {"wave": w["id"], "max_units": 0}, w, {}, budget,
				drive.seed_value, 0, 1.0 - float(pl.get("garrison", 0.0)))
			if r is Dictionary:
				_wave_size[w["id"]] = int((r as Dictionary).get("total_units", 0))
	return _wave_size


## Host: dropships order their air doors through order_air_door (EnemySquad.air_door_hook), once the squad exists.
func _wire_air_doors() -> void:
	var sq: Variant = drive.combat.squad if drive.combat != null else null
	if sq != null and (sq as Object).get("air_door_hook") is Callable and not (sq.air_door_hook as Callable).is_valid():
		sq.air_door_hook = order_air_door


## Host: open air door `id` (deck `deck`) at `open_at` for `hold` s on every machine: the same replicated order as a
## wave's gate (mission.wave), marked "air" (no wave, no units, no reinforcement alert). Again with the same open_at and a
## longer hold it extends the hold (MissionWorld.open_source).
func order_air_door(id: String, deck: int, open_at: float, hold: float) -> void:
	var o := {"wave": "air", "deck": deck, "source": id, "open_at": open_at, "hold": hold, "max_units": 0, "air": true,
		"reason": "dropship"}
	if crew:
		Net.session().send_mission_wave(o)
	_open(o)


## Every machine: a wave order from the director (host / solo) or the host (mission.wave): schedule its door. An air door
## order (o.air, a dropship's) only schedules its door with its hold.
func _open(o: Dictionary) -> void:
	var src := str(o.get("source", ""))
	var open_at := float(o.get("open_at", 0.0))
	if bool(o.get("air", false)):
		opened.append({"wave": "air", "source": src, "open_at": open_at})
		if world != null:
			world.open_source(src, open_at, float(o.get("hold", MissionWorld.HOLD)))
		return
	opened.append({"wave": str(o.get("wave", "")), "source": src, "open_at": open_at})
	if world != null:
		world.open_source(src, open_at)
	_alerts.append({"order": o.duplicate(), "text": "Reinforcements, " + source_words(src), "deck": int(o.get("deck", 0))})
	if _alerts.size() > 8:
		_alerts.pop_front()
	var wid := str(o.get("wave", ""))
	var size := str(_wave_size[wid]) if _wave_size.has(wid) else "?"
	print("[mission] wave %s: %s opens at %.2f (%s units, cap room %d, %s)" % [wid, src, open_at, size,
		int(o.get("max_units", 0)), str(o.get("reason", ""))])
	wave_ordered.emit(o)


## Client: the host's wave order.
func _on_wave(o: Dictionary) -> void:
	if plan == null or deciding():
		return
	_open(o)


## Host: spawn the waves whose door has opened; roll out staged gate groups whose door is passable.
func _spawn_due() -> void:
	_roll_due()
	if _spawns.is_empty():
		return
	var t := now()
	var rest: Array = []
	for o: Dictionary in _spawns:
		if t >= float(o["open_at"]):
			_spawn_wave(o)
		else:
			rest.append(o)
	_spawns = rest


## Host: create the order's units at its source (antigravity's spawner). The call, when it exists:
##   EnemySpawner.spawn_wave(order: {wave, deck, source, open_at, max_units}, wave: the plan's pool wave {id, share,
##     theme, source, trigger}, source: the plan's source + "point": MissionWorld.source_point(id) {deck, x, s},
##     ctx: {stack: CityStack, world: CombatWorld, squad: EnemySquad, seed: int, crew: int, pool: plan.pool(deck)}) -> int
##   creates at most max_units units now, tagged wave = order.wave and spawn_deck = order.deck, arriving hunting, added
##   to the squad (so EnemySync streams them), and returns the units of that wave still to spawn (wave_pending).
## TODO(antigravity): EnemySpawner.spawn_wave is not built yet; until it is, nothing spawns (the wave id goes to
## `unspawned`) and the director counts the wave beaten GRACE s after its door opened.
func _spawn_wave(o: Dictionary) -> void:
	var id := str(o["wave"])
	var spawner := load(SPAWNER) as GDScript
	if spawner == null or not _has_static(spawner, "spawn_wave"):
		if not unspawned.has(id):
			unspawned.append(id)
			print("[mission] TODO antigravity: EnemySpawner.spawn_wave missing, wave %s not spawned" % id)
		return
	var k := int(o["deck"])
	var pool := plan.pool(k)
	var wave := director.group_def(id)
	var src := plan.source(str(o["source"])).duplicate()
	src["point"] = world.source_point(str(o["source"])) if world != null else {}
	var bay := source_bay(str(o["source"]))
	if not bay.is_empty():
		src["bay"] = bay
	var ctx := {"stack": drive.stack, "world": drive.combat.world if drive.combat != null else null,
		"squad": drive.combat.squad if drive.combat != null else null, "seed": drive.seed_value,
		"crew": director.crew_n, "pool": pool,
		"budget": PacingDirector.reserve_budget(EnemySpawner.deck_budget(1, k), director.crew_n)}
	var left: Variant = spawner.call("spawn_wave", o, wave, src, ctx)
	_pending[id] = maxi(int(left), 0) if (left is int or left is float) else 0


## Host: staged gate groups whose door is passable roll out (EnemySquad.roll_out_wave); the door is held open while they
## leave (MissionWorld.hold_source), so none is shut in.
func _roll_due() -> void:
	if _rollouts.is_empty():
		return
	var t := now()
	var rest: Array = []
	for r: Dictionary in _rollouts:
		if t >= float(r["open_at"]) and _passable(str(r["source"]), float(r["open_at"]), t):
			var squad: Variant = drive.combat.squad if drive.combat != null else null
			if squad != null and (squad as Object).has_method("roll_out_wave"):
				squad.call("roll_out_wave", str(r["wave"]))
			if world != null:
				world.hold_source(str(r["source"]), t + ROLL_OUT_HOLD)
		else:
			rest.append(r)
	_rollouts = rest


## A gate's door is passable now: MissionWorld's source_state passable / passable_at, else open_at + OPENING.
func _passable(src: String, open_at: float, t: float) -> bool:
	if world == null:
		return true
	var st: Dictionary = world.source_state(src)
	if st.has("passable_at"):
		return bool(st.get("passable", false)) or t >= float(st["passable_at"])
	return t >= open_at + MissionWorld.passable_after(str(plan.source(src).get("kind", "gate")))


## The staging bay of a gate source in arc coordinates (BayFormation.from_world_bay of MissionWorld.source_bay), {} when
## the source has none (lift, ramp, shaft, a gate without a door).
func source_bay(src: String) -> Dictionary:
	if world == null or plan == null or str(plan.source(src).get("kind", "")) != "gate" or not world.has_method("source_bay"):
		return {}
	var b: Variant = world.call("source_bay", src)
	if not (b is Dictionary) or not bool((b as Dictionary).get("ok", false)):
		return {}
	var d := (b as Dictionary).duplicate()
	if d.get("exit") is Vector3 and drive != null and drive.stack != null:
		var a := drive.stack.to_deck_arc(d["exit"] as Vector3)
		d["exit_arc"] = Vector2(float(a["x"]), float(a["s"]))
	return BayFormation.from_world_bay(d)


## Pilots in the crew (players and hangar bots): Session.crew() in a crew, this machine's pilots solo. Co-op scaling.
func crew_size() -> int:
	var sess := Net.session()
	if crew and sess != null and sess.has_method("crew"):
		return clampi(sess.crew().size(), 1, 4)
	if drive != null and drive.has_method("crew_members"):
		return clampi(drive.crew_members().size(), 1, 4)
	return 1


static func _has_static(s: GDScript, method: String) -> bool:
	for m: Dictionary in s.get_script_method_list():
		if str(m.get("name", "")) == method:
			return true
	return false


## Host / tests: the defend relay `id`'s health (0..1). Weapons' relay target calls damage_asset (TODO Weapons).
func set_asset_hp(id: String, hp: float) -> void:
	if not asset_hp.has(id) or not deciding():
		return
	asset_hp[id] = clampf(hp, 0.0, 1.0)


## A defend relay's hit points for this crew (ASSET_MAX_HP x ASSET_HP_SCALE[pilots - 1]); every machine computes the same
## from the launch's crew.
func asset_max_hp() -> float:
	var n := director.crew_n if director != null else 1
	return ASSET_MAX_HP * float(ASSET_HP_SCALE[clampi(n, 1, 4) - 1])


## Host: Weapons' AssetTarget reports an applied hit (`amount` in hit points, ASSET_MAX_HP for a full relay). Ignored
## unless the relay's defend objective is active (Missions' playtest: a garrison shot the relay with no crew on its deck).
func damage_asset(id: String, amount: float) -> void:
	if not _asset_active(id):
		return
	set_asset_hp(id, float(asset_hp.get(id, 0.0)) - amount / asset_max_hp())


## Whether defend `id` is active now (the rules' state: the host's own, a client's replicated copy).
func _asset_active(id: String) -> bool:
	return rules != null and rules.obj_state(id) == "active"


## Host: each relay whose defend objective has just gone active starts at full HP (once per relay).
func _arm_assets() -> void:
	if not deciding():
		return
	for id: String in asset_hp:
		if not _asset_armed.has(id) and _asset_active(id):
			_asset_armed[id] = true
			asset_hp[id] = 1.0


## Every machine: register each defend relay's body as a combat target once the combat world exists (Weapons'
## `combat.add_asset`: same id everywhere, host hits come back through damage_asset), keep its HP mirrored, and keep it
## LIVE only while its defend objective is active (AssetTarget.set_live, from the replicated objective state so every
## machine agrees): dormant, shots pass, enemies ignore it and nothing reaches damage_asset, so a garrison can't wear it
## down before the crew arrives.
func _sync_asset_targets() -> void:
	if world == null or drive == null or drive.combat == null or not drive.combat.has_method("add_asset"):
		return
	for id: String in asset_hp:
		if not _asset_targets.has(id):
			var body: Node3D = world.asset_body(id)
			if body == null or not body.is_inside_tree():
				continue
			_asset_targets[id] = drive.combat.call("add_asset", id, body, ASSET_RADIUS, ASSET_HEIGHT)
		var t: Variant = _asset_targets[id]
		if t != null and is_instance_valid(t) and (t as Object).has_method("set_live"):
			(t as Object).call("set_live", _asset_active(id))
		if t != null and is_instance_valid(t) and (t as Object).has_method("set_hp"):
			var hp := float(asset_hp.get(id, 1.0)) * asset_max_hp()
			var mx := asset_max_hp()
			_push("asset_target:" + id, hp, func() -> void: (t as Object).call("set_hp", hp, mx))


# --- Plan mode: presentation on every machine ------------------------------------------------------------------

func _tick_world(dt: float) -> void:
	if world != null and is_instance_valid(world):
		world.advance_to(now())
	_present_left -= dt
	if _present_left <= 0.0:
		_present_left = EVAL_INTERVAL
		_present()


## Push the replicated state to the world (flags, zones, relays, portal) and refresh this machine's zone view.
func _present() -> void:
	_sync_asset_targets()
	if plan == null or world == null or not is_instance_valid(world) or drive == null or drive.stack == null:
		return
	var crew_f := crew_facts()
	var live := _live_enemies()
	var zen := _zone_enemies(live)
	_zone_seen = {}
	for o: Dictionary in rules.objectives:
		var id: String = o["id"]
		var st := rules.obj_state(id)
		match str(o["type"]):
			"flag":
				var inside := _crew_within(o, crew_f)
				_zone_seen[id] = {"crew": inside, "enemies": int(zen.get(id, 0))}
				if st == "done":
					_push("flag:" + id, true, func() -> void: world.set_flag(id, true))
				var z := "idle"
				if st == "done" or (inside and int(zen.get(id, 0)) == 0):
					z = "ours"
				elif int(zen.get(id, 0)) > 0:
					z = "contested"
				_push("zone:" + id, z, func() -> void: world.set_zone(id, z))
			"defend":
				_zone_seen[id] = {"crew": _crew_within(o, crew_f), "enemies": int(zen.get(id, 0))}
				var hp := float(asset_hp.get(id, 1.0))
				_push("asset:" + id, hp, func() -> void: world.set_asset(id, hp))
			"hold":
				var tot := maxf(float(rules.state().get("objs", {}).get(id, [0, 0, 0])[2]), 0.001)
				var p := clampf(rules.obj_progress(id) / tot, 0.0, 1.0)
				if st == "done":
					p = 1.0
				var inside := _crew_in_zone(o, crew_f)
				_zone_seen[id] = {"crew": inside, "enemies": 0}
				_push("portal:" + id, snappedf(p, 0.005), func() -> void: world.set_portal(p))
				var hz := "done" if st == "done" else ("holding" if inside and st == "active" else "idle")
				_push("hold:" + id, hz, func() -> void: world.set_hold_zone(hz))


func _push(key: String, v: Variant, f: Callable) -> void:
	if _pushed.has(key) and _pushed[key] == v:
		return
	_pushed[key] = v
	f.call()


func _crew_within(o: Dictionary, crew_f: Array) -> bool:
	var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
	for c: Dictionary in crew_f:
		if not bool(c["downed"]) and int(c["deck"]) == int(o["deck"]) \
				and at.distance_to(Vector2(float(c["x"]), float(c["s"]))) <= float(o["radius"]):
			return true
	return false


func _crew_in_zone(o: Dictionary, crew_f: Array) -> bool:
	var z: Rect2 = o.get("zone", Rect2())
	for c: Dictionary in crew_f:
		if not bool(c["downed"]) and int(c["deck"]) == int(o["deck"]) and z.has_point(Vector2(float(c["x"]), float(c["s"]))):
			return true
	return false


## "east gate", "north lift", "west ramp": a wave source in words, from its wall (gates) or its place on the deck
## (+s = north, +x = east, the deck's own frame; the same words on every machine).
func source_words(id: String) -> String:
	var src := plan.source(id) if plan != null else {}
	if src.is_empty():
		return "unknown source"
	var kind := str(src.get("kind", "gate"))
	var dir := ""
	match str(src.get("edge", "")):
		"s0": dir = "south"
		"s1": dir = "north"
		"x0": dir = "west"
		"x1": dir = "east"
	if dir == "" and drive != null and drive.stack != null and drive.stack.section != null:
		var sec := drive.stack.section
		var hw := maxf(sec.p("width") * 0.5, 1.0)
		var ha := maxf(sec.arc_of(int(src["deck"])) * 0.5, 1.0)
		var fx := float(src["x"]) / hw
		var fs := float(src["s"]) / ha
		if absf(fx) > absf(fs):
			dir = "east" if fx > 0.0 else "west"
		else:
			dir = "north" if fs > 0.0 else "south"
	return "%s %s" % [dir, kind]


# --- HUD -----------------------------------------------------------------------------------------------------

## What MissionHud draws (its contract, MissionHud header): {objective: String, waypoint: {pos: Vector3, deck, label}
## or {}, banner: {title, reason, won} or {}}; plan mode adds plan: true, deck, lines, waves [released, total],
## markers [{pos, label, role, state, kind}], rings [PackedVector3Array], zone {label, progress, total, contested,
## countdown (hold: seconds left), percent (flag: whole percent)} or {}, panel (MissionRules.panel() for this pilot's
## deck and position, plus extra: [the depot line]; its route_at, while "Proceed to the next floor" shows, is also the
## waypoint "RAMP DOWN" / "SHAFT DOWN" when there is no extraction waypoint),

## alerts [{text, pos: Vector3 or null, left: s to the door}].
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
		var title := str(TITLES.get(rules.outcome, rules.outcome.to_upper()))
		if rules.outcome == "lost" and LOST_TITLES.has(rules.reason):
			title = str(LOST_TITLES[rules.reason])
		var why := str(REASONS.get(rules.reason, rules.reason))
		if plan != null and PLAN_REASONS.has(rules.reason):
			why = str(PLAN_REASONS[rules.reason])
		out["banner"] = {"title": title, "reason": why, "won": rules.outcome == "won"}
	if plan != null and drive.stack != null and drive.mech != null:
		_plan_hud(out)
	return out


func _plan_hud(out: Dictionary) -> void:
	var here := drive.stack.to_deck_arc(drive.mech.global_position)
	var k := int(here["deck"])
	out["plan"] = true
	out["deck"] = k
	out["lines"] = rules.lines(k)
	var core_line := depots.progress_line() if depots != null else ""
	if core_line != "":   # this pilot taking a power core: an objective-style line, kept inside the panel's LIST_MAX
		(out["lines"] as Array).insert(mini((out["lines"] as Array).size(), MissionHud.LIST_MAX - 1), core_line)
	out["panel"] = _panel(here, core_line)
	var to: Dictionary = (out["panel"] as Dictionary).get("route_at", {})
	if (out["waypoint"] as Dictionary).is_empty() and not to.is_empty():   # "Proceed to the next floor": the way there
		out["waypoint"] = {"pos": drive.stack.from_deck_arc(int(to["deck"]), float(to["x"]), float(to["s"]), WAYPOINT_H),
			"deck": int(to["deck"]), "label": "%s %s" % [str(to["kind"]).to_upper(), "DOWN" if int(to["dir"]) > 0 else "UP"]}
	var wv: Array = director.state()["waves"]
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
	var t := now()
	for a: Dictionary in _alerts:
		var o: Dictionary = a["order"]
		var open_at := float(o["open_at"])
		if t > open_at + ALERT_AFTER:
			continue
		var text := str(a["text"])
		var pos: Variant = null
		if int(a["deck"]) != k:
			text += ", deck %d" % (int(a["deck"]) + 1)
		elif world != null:
			var sp := world.source_point(str(o["source"]))
			if not sp.is_empty():
				pos = drive.stack.from_deck_arc(int(sp["deck"]), float(sp["x"]), float(sp["s"]), SOURCE_H)
		alerts.append({"text": text, "pos": pos, "left": maxf(open_at - t, 0.0)})
	out["alerts"] = alerts


## The objective panel (MissionRules.panel) for the local pilot: their deck, held while they are off every floor (on a
## ramp, falling down a shaft: more than PANEL_STAND_H from the floor under them) until they stand on the next one, and
## their (x, s) on it; `extra` the depot line (MissionDepots.progress_line()) under this deck's lines. Local facts only.
func _panel(here: Dictionary, core_line: String) -> Dictionary:
	var k := int(here["deck"])
	if _hud_deck < 0 or absf(float(here.get("h", 0.0))) <= PANEL_STAND_H:
		_hud_deck = k
	var s := float(here["s"])
	var sec := drive.stack.section
	if _hud_deck != k and sec != null:   # the same top-down point on the held deck (decks are concentric)
		s *= sec.radius_of(_hud_deck) / maxf(sec.radius_of(k), 1.0)
	var pn := rules.panel(_hud_deck, Vector2(float(here["x"]), s), MissionHud.ascii_arrows())
	pn["extra"] = [core_line] if core_line != "" else []
	return pn


## The zone progress bar while anyone stands in an active flag / hold zone: {label, progress, total, contested}.
func _zone_hud() -> Dictionary:
	for o: Dictionary in rules.objectives:
		var id: String = o["id"]
		var ty := str(o["type"])
		if (ty != "flag" and ty != "hold") or rules.obj_state(id) != "active":
			continue
		var zs: Dictionary = _zone_seen.get(id, {})
		if not bool(zs.get("crew", false)):
			continue
		var objs: Dictionary = rules.state().get("objs", {})
		var tot := float((objs.get(id, [0, 0, 0]) as Array)[2])
		return {"id": id, "label": "RAISING THE FLAG" if ty == "flag" else "HOLDING THE PORTAL",
			"progress": rules.obj_progress(id), "total": tot, "contested": int(zs.get("enemies", 0)) > 0,
			"countdown": ty == "hold", "percent": ty == "flag"}

	return {}


func _ring(m: Dictionary) -> PackedVector3Array:
	var id := str(m["id"])
	if _rings.has(id):
		return _rings[id]
	var pts := PackedVector3Array()
	var r := float(m["radius"])
	for i in RING_POINTS + 1:
		var a := TAU * float(i) / float(RING_POINTS)
		pts.append(drive.stack.from_deck_arc(int(m["deck"]), float(m["x"]) + cos(a) * r, float(m["s"]) + sin(a) * r, 0.3))
	_rings[id] = pts
	return pts
