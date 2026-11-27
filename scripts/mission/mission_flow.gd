class_name MissionFlow
extends Node
## The mission's objectives and end (docs/design/mission-objectives.md §7, §9, docs/design/mission-section.md §14,
## docs/networking.md "Mission progress"). Built by MissionScene in stack mode (child "MissionFlow").
##
## ONE MODE (user 2026-11-25: "Cut the legacy modes."): every mission plays a MissionPlan (objectives, the pacing
## director, depots, the extraction hold); a section always has one. `--objectives` is accepted as a no-op,
## `--no-objectives`, the "objectives" setting and the single-district mode are gone. TEST-ONLY: `test_quiet` (set by QuietSectionFixture in
## scripts/test_support/, never by the game) builds no rules at all: the section, its crew and garrison, no director,
## no objectives, never ending, for tests of a narrow system (docs/testing.md "Fixtures").
##
## RULES: every machine builds the same rules from the plan. Who decides:
##   - SOLO (offline, no launched mission): this machine evaluates locally, no network.
##   - CREW, HOST (a host alone included): evaluates every EVAL_INTERVAL s and, whenever evaluate() returns true, sends
##     rules.state() to the crew (Session.mission.host_state -> reliable "mission.state", also carried by mission.go).
##   - CREW, CLIENT: never evaluates; applies what the host sent (Session.mission_state_changed -> rules.apply_state).
## Evaluation is GATED until the mission is released (Session.mission_go; solo at once) AND the enemies have spawned
## (MissionScene.enemies_spawned), because a clear objective latches the first time its deck counts 0 alive.
## CREW FACTS: one entry per mech of the mission still in the crew: {peer, downed, deck, x, s}, deck / x / s =
##   CityStack.to_deck_arc(position); downed = this machine's PlayerTarget.disabled / a puppet's streamed `downed`.
##   No crew-wipe loss for now (user decision): the rules run with MissionRules' "wipe" option off (its default).
##
## THE PLAN (docs/design/mission-objectives.md §7 phase 1, §9). Every machine builds plan = MissionPlan.make(section, test_plan),
## rules = MissionRules.make(section, {plan}), director = PacingDirector.make(plan, test_director, crew_scale()), then
## stack.setup_mission(plan) (Environment's MissionWorld: wave doors, flag masts, defend relays, the portal) and
## rules.set_site() from its flag_site / asset_site, all before the first evaluate. The load barrier's checksum joins
## plan.checksum() (MissionScene.mission_checksum). The HOST / SOLO tick (same gate, EVAL_INTERVAL, t = Session.host_time(),
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
##   each order     {wave, deck, source, open_at, max_units}: the host sends it (Session.mission.host_wave: reliable
##                  "mission.wave"), every machine calls stack.mission.open_source(source, open_at) (`opened` records it),
##                  and when the shared clock reaches open_at the host spawns it (EnemySpawner.spawn_wave, see
##                  _spawn_wave; a group the spawner never reports counts beaten GRACE s after its door opened)
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
## CREW SCALE (AGENTS.md rule 8; docs/networking.md "Crew scale"; user 2026-11-25: "Run it from the host, enforce this! And
## ease off when a player leaves."): crew_scale() is the ONE read of the co-op scale on this machine (1..4): the director's
## crew_n, the reserve sizes and spawn ctx (wave_sizes, _spawn_wave), the relay's HP (asset_max_hp), the depot cores
## (MissionDepots.setup). Only the host derives it (host_crew_scale): at the launch from the launch crew, hangar bots included
## (mission.launch params.scale, read here by every machine at setup: a client never counts its own crew list); on a retire
## (on_member_retired, the host's leaver hook) from the members still in the crew. A change goes out as mission.scale {n, at}
## with at = shared clock + SCALE_LEAD (before the release: now), mission.state carries the newest as "scale": [n, at], and
## every machine applies it at `at` (_tick_scale -> _apply_scale): director.rescale(n) (PacingDirector.rescale's rules), the
## relay's max HP follows while its HP FRACTION (asset_hp) stays, depot cores stay, the garrison and every unit alive stay.
## A change whose `at` is not newer than the last one known here is ignored (duplicate / late). Solo: 1.
##
## END FLOW: once rules.outcome is set ("won"; decided here or heard from the host) every machine shows the banner
## (hud_model.build().banner) for END_HOLD s, then: the HOST calls Session.mission.end(reason) (mission.end to the crew, whose
## MissionScene goes back to the hangar on Session.mission_ended); SOLO just leaves; a CLIENT waits for the host's
## mission.end and only leaves on its own after CLIENT_GRACE more seconds. `finished` tells MissionScene to leave.

signal outcome_reached(outcome: String, reason: String)
## The end flow is over: leave the mission scene (MissionScene does, when it is the current scene).
signal finished(outcome: String)
## Every machine: a wave's door was scheduled (stack.mission.open_source) from a host order.
signal wave_ordered(order: Dictionary)

const EVAL_INTERVAL := 0.25       ## s between host / solo evaluations (4 Hz)
const END_HOLD := 4.0             ## s the end banner shows before the mission ends
const CLIENT_GRACE := 6.0         ## s past END_HOLD a client waits for the host's mission.end before leaving alone
const END_REASONS := {"won": "Mission complete", "lost": "Crew lost"}
const LOST_END_REASONS := {"objective_failed": "Objective failed"}
const ASSET_MAX_HP := 600.0       ## a defend relay's hit points (Weapons' AssetTarget hits are in points; asset_hp is 0..1) ...
## ... times this by crew size (index = pilots - 1; defend balance 2026-11-24: a lone veteran bot at 90 %+ structure lost
## relays in 40-110 s): the relay takes hits in points against ASSET_MAX_HP x scale.
const ASSET_HP_SCALE := [1.75, 1.35, 1.0, 1.0]
const ASSET_RADIUS := 2.5         ## m, the relay's hit-sphere radius for combat
const ASSET_HEIGHT := 6.0         ## m, the hit spheres stack this high
const ROUTE_EVERY := 2.0          ## s between the host's source route measurements (PacingDirector source choice)
const ROLL_OUT_HOLD := 15.0       ## s a gate stays open once its staged group starts rolling out (none is shut in)
const SCALE_LEAD := 1.0           ## s on the shared clock between the host's scale decision and `at` (every machine has it)
const SCALE_STEP := 0.001         ## s: each new change's `at` is at least this after the previous one (strict order)

## Tests: overrides for MissionPlan.make / PacingDirector.make (set the same on every machine of a test:
## the plan's checksum includes its options).
static var test_plan: Dictionary = {}
static var test_director: Dictionary = {}
## TEST-ONLY (QuietSectionFixture, scripts/test_support/quiet_section_fixture.gd; never set by the game, its menus,
## settings or flags: tests/test_objectives_only.gd checks): no rules, plan or director are built, so the section stays
## as spawned (crew and full garrison), nothing is released and the mission never ends. Set on every machine of a test.
static var test_quiet := false

var drive: MissionScene
var rules: MissionRules
var crew := false                 ## a crew mission with a session (else solo)
var released := false             ## the mission started (mission_go; solo at once)
var end_left := -1.0              ## s until the end (>= 0 while the banner shows)
var ended := false                ## the end flow is over (finished emitted, or the host ended the mission)
var evaluations := 0              ## evaluate() calls (tests)
## The mission plan (null in the TEST-ONLY quiet fixture), the host's wave queue (a client's mirrors the host's state()), the
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
var _eval_left := 0.0
var _end_wait := 0.0              ## s since the outcome
var _clock := 0.0                 ## solo: the mission clock (physics seconds since release)
var _sent: Dictionary = {}        ## host: the plan state last sent
var _spawns: Array = []           ## host: orders waiting for their door (spawned at open_at)
var _pending: Dictionary = {}     ## host: wave id -> units still to spawn (the spawner's report)
var _wave_total: Dictionary = {}  ## host: wave id -> units of it seen so far
var _seen: Dictionary = {}        ## host: enemy instance id -> true (counted in _wave_total)
var _wave_size: Dictionary = {}   ## host: wave id -> units the spawner will make (EnemySpawner.plan_wave dry run)
var _wave_size_by: Dictionary = {}   ## host: crew scale -> {wave id: units} (plan_wave dry runs at that scale, cached)
## The crew scale (see CREW SCALE): the host decides, every machine applies its changes at their `at`.
var _scale := 1                   ## in force here (crew_scale())
var scale_at := -INF              ## shared-clock `at` of the change in force (-INF: the launch value)
var _scale_due: Array = []        ## changes heard / decided, not applied yet, by `at` [{n, at, from, reason, pilot}]
var _scale_last_at := -INF        ## the newest `at` known here (applied or due): older / equal ones are ignored
var scale_log: Array = []         ## changes applied here [{from, to, at, t, reason, pilot}] (tests, logs)
var scale_dups := 0               ## mission.scale messages ignored as duplicate / late (tests)
var _present_left := 0.0
var _pushed: Dictionary = {}      ## presentation: key -> last value pushed to the world
## What MissionHud draws (scripts/mission/mission_hud_model.gd: the orders heard, the zone view, the panel's deck): fed by
## alert() / zones here, read through hud_model.build() (MissionHud.source).
var hud_model: MissionHudModel
## The military supply depots (MissionDepots child, every machine; pacing-director.md §2). Their state rides in
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
		"opened": Net.LOCAL, "_clock": Net.PRIVATE, "_sent": Net.PRIVATE, "_spawns": Net.PRIVATE,
		"_pending": Net.PRIVATE, "_wave_total": Net.PRIVATE, "_seen": Net.PRIVATE, "_wave_size": Net.PRIVATE, "_wave_size_by": Net.PRIVATE, "_present_left": Net.LOCAL,
		"_scale": Net.OWNER, "scale_at": Net.OWNER,   # the host decides (launch params.scale, mission.scale, state "scale")
		"_scale_due": Net.LOCAL, "_scale_last_at": Net.LOCAL,   # this machine's schedule of the host's changes
		"scale_log": Net.LOCAL, "scale_dups": Net.LOCAL,
		"_pushed": Net.LOCAL,
		"hud_model": Net.LOCAL,        # this machine's HUD view (MissionHudModel declares its own state)
		"depots": Net.LOCAL}   # MissionDepots declares its own state (net_fields)


func _init() -> void:
	hud_model = MissionHudModel.new(self)


func _ready() -> void:
	process_physics_priority = 40   # after the combat world, the crew snapshots and EnemySync stepped


func setup(td: MissionScene) -> void:
	drive = td
	var sess := Net.session()
	crew = td.crewed and sess != null and sess.online()
	# The host's crew scale before anything is built from it (it comes with the launch params that carry the crew), then
	# the changes heard while this machine loaded (due ones apply at once: the director starts at the scale in force).
	init_scale(sess.mission.params if crew else {})
	if crew:
		for c: Variant in sess.mission.scales:
			if c is Dictionary:
				receive_scale(c, false)
		_tick_scale()
	rebuild()
	if crew:
		released = not td.held
		# Methods, not lambdas: Session outlives this node, and a method connection goes away with it.
		sess.mission_go.connect(_on_go)
		sess.mission_state_changed.connect(_on_state)
		sess.mission_ended.connect(_on_ended)
		sess.mission_wave.connect(_on_wave)
		sess.mission_scale.connect(_on_scale_msg)
		if not sess.mission.state.is_empty():
			_on_state(sess.mission.state)
		if not deciding():
			for o: Variant in sess.mission.waves:
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
	_wave_size_by = {}
	opened = []
	_sent = {}
	_spawns = []
	_pending = {}
	_wave_total = {}
	_seen = {}
	_pushed = {}
	hud_model.reset()
	_clock = 0.0
	rules = null
	if sec == null or test_quiet:
		pass   # no section (defensive), or TEST-ONLY QuietSectionFixture: no rules, nothing released, never ends
	else:
		var pre := drive.prebuilt_plan
		var ready := pre != null and drive.stack.mission != null
		plan = pre if ready else MissionPlan.make(sec, test_plan)
		rules = MissionRules.make(sec, {"plan": plan})
		director = PacingDirector.make(plan, test_director, crew_scale())
		# The stepped load set the world up over frames already (MissionScene.prebuilt_plan); otherwise in one call.
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


## The plan state the host last sent (read only; {} before the first send).
func last_sent_state() -> Dictionary:
	return _sent


## The mission clock: the shared clock in a crew, this node's own (physics seconds since release) solo.
func now() -> float:
	if crew:
		var sess := Net.session()
		return sess.host_time() if sess != null else 0.0
	return _clock


func _physics_process(dt: float) -> void:
	if rules == null or drive == null:
		return
	_tick_scale()
	if released and not crew:
		_clock += dt
	if plan != null:
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
	return false   # no plan: TEST-ONLY QuietSectionFixture (or no section), nothing to evaluate


## [{peer, downed, deck, x, s}] for this machine's mech and (crew) every teammate's puppet still in the crew.
## Every pilot (MissionScene.crew_members: the local mech, the host's hangar bots, the puppets of members still in the crew;
## a bot's peer is its negative pilot id, docs/design/hangar-bots.md).
## One entry per crew_members() entry, in its order (_pacing_facts pairs them by index); a member whose mech was freed
## while still listed is not standing: downed, deck -1.
func crew_facts() -> Array:
	var out: Array = []
	for c: Dictionary in drive.crew_members():
		var m: Variant = c.get("mech")
		var mech := (m as Node3D) if is_instance_valid(m) else null   # validity before `as`: a freed instance raises
		out.append(_fact(int(c["peer"]), mech, bool(c["downed"]), bool(c.get("redeploying", false))))
	return out


## `redeploying` (DownedRules: held to respawn, the penalty runs; downed is true too): MissionRules' wipe never fires
## while anyone redeploys; everything that skips downed pilots (zones, flags, depots, the director) skips it too.
## `m` null (its mech is gone): downed, on no deck.
func _fact(peer: int, m: Node3D, downed: bool, redeploying: bool = false) -> Dictionary:
	if m == null:
		return {"peer": peer, "downed": true, "redeploying": false, "deck": -1, "x": 0.0, "s": 0.0}
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
	if d.has("scale"):
		apply_scale_state(d["scale"])
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
			sess.mission.end()
		_finish()
		return
	if end_left > 0.0:
		return
	if crew and sess != null and sess.online():
		sess.mission.end(end_reason())
	_finish()


## What mission.end says for the outcome ("Mission complete", "Crew lost", "Objective failed").
func end_reason() -> String:
	if rules.outcome == "lost" and LOST_END_REASONS.has(rules.reason):
		return str(LOST_END_REASONS[rules.reason])
	return str(END_REASONS.get(rules.outcome, ""))


func _finish() -> void:
	ended = true
	finished.emit(rules.outcome)


# --- The host's tick ------------------------------------------------------------------------------------------

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
			Net.session().mission.host_wave(o)
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
			Net.session().mission.host_state(st)
	_present()
	_check_outcome()
	return changed


## What the host broadcasts: rules.state() + {"dir": director.state(), "assets": {defend id: hp}}.
func plan_state() -> Dictionary:
	var st := rules.state()
	st["dir"] = director.state()
	var a := {}
	for id: String in asset_hp:
		a[id] = snappedf(float(asset_hp[id]), 0.01)
	st["assets"] = a
	if depots != null:
		st["depots"] = depots.state()
	var sc := scale_state()
	if not sc.is_empty():
		st["scale"] = sc
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


## Host: {source id: walk-route metres from the standing crew's centre on its deck} (EnemyNav.find_arc_path over the
## road graph), refreshed every ROUTE_EVERY s; -1 where no path was found (the director then measures straight).
func _source_routes(crew_f: Array) -> Dictionary:
	var t := now()
	if t < _route_t + ROUTE_EVERY and not _routes.is_empty():
		return _routes
	_route_t = t
	_routes = {}
	var squad: Variant = drive.combat.squad if drive.combat != null else null
	if not is_instance_valid(squad) or not squad is EnemySquad or (squad as EnemySquad).nav == null:
		return _routes
	var nav: EnemyNav = (squad as EnemySquad).nav
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
			var path: Array = nav.find_arc_path(centre, to, k)
			if path.is_empty():
				_routes[str(s["id"])] = -1.0
				continue
			var d := centre.distance_to(path[0])
			for i in range(1, path.size()):
				d += (path[i - 1] as Vector2).distance_to(path[i])
			d += (path[path.size() - 1] as Vector2).distance_to(to)
			_routes[str(s["id"])] = snappedf(d, 0.1)
	return _routes


## Host: PacingFacts over every pilot (crew_facts order: the same entries as MissionScene.crew_members) and the live enemies.
func _pacing_facts(crew_f: Array, live: Array) -> Dictionary:
	if drive.combat == null or drive.combat.world == null:
		return {}
	if pacing == null:
		pacing = PacingFacts.new()
		pacing.bind(drive.combat.world, now)
		pacing.scout_call = _on_scout_call
	var targets := {}
	for tg in drive.combat.world.targets:
		# Validity before `is` / member reads: a PlayerTarget may outlive its MechController (a bot's freed first).
		if is_instance_valid(tg) and tg is PlayerTarget and is_instance_valid((tg as PlayerTarget).mech):
			targets[(tg as PlayerTarget).mech.get_instance_id()] = tg
	var members: Array = drive.crew_members()
	var pilots: Array = []
	for i in mini(members.size(), crew_f.size()):
		var m: Variant = members[i].get("mech")
		if not is_instance_valid(m):
			m = null   # freed while still listed: PacingFacts treats the pilot as not standing
		var pt: Variant = targets.get((m as Object).get_instance_id()) if m != null else null
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
				if is_instance_valid(squad):
					var near := drive.stack.from_deck_arc(k, float(ev["x"]), float(ev["s"]), 0.0)
					sent = (squad as EnemySquad).send_garrison_hunt(k, int(ev["units"]), near)
				print("[mission] release garrison-hunt deck %d size %d reason cap" % [k, sent])
				CombatLog.note_release("garrison", k, "-", sent, null, "hunt")


## Host: {group id: units} for every reserve group of the plan (the director's half rule and the cap room it holds until
## a group's units appear), from EnemySpawner.plan_wave with max_units 0 (counts, places nothing) at the reserve budget
## (PacingDirector.reserve_budget: the solo deck budget x CREW_SCALE) of the crew scale: crew_scale() for a group not released
## yet (a rescale resizes it), the scale it was released at for a released one (PacingDirector.release_crew: untouched).
## Cached per scale.
func wave_sizes() -> Dictionary:
	if plan == null or director == null:
		_wave_size = {}
		return _wave_size
	var n := crew_scale()
	var out := _sizes_at(n).duplicate()
	var rel := director.release_crews()
	for id: Variant in rel:
		if int(rel[id]) != n and out.has(id):
			out[id] = int(_sizes_at(int(rel[id])).get(id, out[id]))
	_wave_size = out
	return _wave_size


## {group id: units} of every reserve group sized at crew scale `n` (EnemySpawner.plan_wave dry runs, cached per n).
func _sizes_at(n: int) -> Dictionary:
	if _wave_size_by.has(n):
		return _wave_size_by[n]
	var sizes := {}
	for k in plan.deck_count:
		var pl := plan.pool(k)
		var budget := PacingDirector.reserve_budget(EnemySpawner.deck_budget(1, k), n)
		for w: Dictionary in pl.get("reserve", []):
			var r := EnemySpawner.plan_wave(null, null, {"wave": w["id"], "max_units": 0}, w, {}, budget,
				drive.seed_value, 0, 1.0 - float(pl.get("garrison", 0.0)))
			sizes[w["id"]] = int(r.get("total_units", 0))
	_wave_size_by[n] = sizes
	return sizes


## Host: dropships order their air doors through order_air_door (EnemySquad.air_door_hook), once the squad exists.
func _wire_air_doors() -> void:
	var sq: Variant = drive.combat.squad if drive.combat != null else null
	if is_instance_valid(sq) and (sq as Object).get("air_door_hook") is Callable and not (sq.air_door_hook as Callable).is_valid():
		sq.air_door_hook = order_air_door


## Host: open air door `id` (deck `deck`) at `open_at` for `hold` s on every machine: the same replicated order as a
## wave's gate (mission.wave), marked "air" (no wave, no units, no reinforcement alert). Again with the same open_at and a
## longer hold it extends the hold (MissionWorld.open_source).
func order_air_door(id: String, deck: int, open_at: float, hold: float) -> void:
	var o := {"wave": "air", "deck": deck, "source": id, "open_at": open_at, "hold": hold, "max_units": 0, "air": true,
		"reason": "dropship"}
	if crew:
		Net.session().mission.host_wave(o)
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
	hud_model.alert(o.duplicate(), "Reinforcements, " + source_words(src), int(o.get("deck", 0)))
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


## Host: create the order's units at its source:
##   EnemySpawner.spawn_wave(order: {wave, deck, source, open_at, max_units}, wave: the director's group_def {id, share,
##     theme, source, for, units, kind}, source: the plan's source + "point": MissionWorld.source_point(id) {deck, x, s}
##     (+ "bay" for a gate with a staging bay), ctx: {stack, world, squad, seed, crew, pool: plan.pool(deck), budget}) -> int
##   creates at most max_units units now, tagged wave = order.wave and spawn_deck = order.deck, arriving hunting, added
##   to the squad (so EnemySync streams them), and returns the units of that wave still to spawn (wave_pending).
func _spawn_wave(o: Dictionary) -> void:
	var id := str(o["wave"])
	var k := int(o["deck"])
	var pool := plan.pool(k)
	var wave := director.group_def(id)
	var src := plan.source(str(o["source"])).duplicate()
	src["point"] = world.source_point(str(o["source"])) if world != null else {}
	var bay := source_bay(str(o["source"]))
	if not bay.is_empty():
		src["bay"] = bay
	var cn := director.release_crew(id)   # the scale it was released at (a later rescale leaves it as it was ordered)
	var ctx := {"stack": drive.stack, "world": drive.combat.world if drive.combat != null else null,
		"squad": drive.combat.squad if drive.combat != null else null, "seed": drive.seed_value,
		"crew": cn, "pool": pool, "budget": PacingDirector.reserve_budget(EnemySpawner.deck_budget(1, k), cn)}
	_pending[id] = maxi(EnemySpawner.spawn_wave(o, wave, src, ctx), 0)


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
			if is_instance_valid(squad):
				(squad as EnemySquad).roll_out_wave(str(r["wave"]))
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
	if world == null or plan == null or str(plan.source(src).get("kind", "")) != "gate":
		return {}
	var b := world.source_bay(src)
	if not bool(b.get("ok", false)):
		return {}
	var d := b.duplicate()
	if d.get("exit") is Vector3 and drive != null and drive.stack != null:
		var a := drive.stack.to_deck_arc(d["exit"] as Vector3)
		d["exit_arc"] = Vector2(float(a["x"]), float(a["s"]))
	return BayFormation.from_world_bay(d)


# --- Crew scale (see CREW SCALE in the header) -----------------------------------------------------------------

## The crew scale in force on THIS machine (1..4): the host's decision (launch params.scale, then each mission.scale from
## its `at`); 1 solo. Every crew-scaled gameplay value reads this and nothing else (AGENTS.md rule 8).
func crew_scale() -> int:
	return _scale


## HOST ONLY: the one derivation of the crew scale from a crew: `members` = the launch crew entries (mission.launch
## params.crew, hangar bots included: NetMission.launch_scale) at the launch, the members still in the crew
## (MissionScene.crew_members(): players and hangar bots alike) on a retire. 1..4.
static func host_crew_scale(members: Array) -> int:
	return clampi(members.size(), 1, 4)


## The crew scale a launch carries (params.scale, the host's), 1 when it carries none (a solo launch). Never recomputed from
## the params' crew list.
static func launch_scale(params: Dictionary) -> int:
	if params.is_empty():
		return 1
	if not params.has("scale"):
		push_warning("[mission] the launch carries no crew scale: 1")
		return 1
	return clampi(int(params["scale"]), 1, 4)


## Start this mission's scale from `params` (a crew mission's launch params; {} solo: 1). Forgets any schedule.
func init_scale(params: Dictionary) -> void:
	_scale = MissionFlow.launch_scale(params) if crew else 1
	scale_at = -INF
	_scale_due = []
	_scale_last_at = -INF
	scale_log = []
	scale_dups = 0


## The newest scale decided ({} when none since the launch): what mission.state carries as "scale": [n, at].
func scale_state() -> Array:
	if _scale_last_at == -INF:
		return []
	return [_scale_target(), _scale_last_at]


## The newest decided scale (the last change due, else the one in force).
func _scale_target() -> int:
	return int((_scale_due.back() as Dictionary)["n"]) if not _scale_due.is_empty() else _scale


## The host's leaver hook (MissionScene.member_retired, after crew_members() stopped listing the pilot; a hangar bot counts the
## same). Host only (no-op on clients and solo): forget the pilot's bookkeeping, recompute host_crew_scale from the members
## still in the crew and, if it changed, decide it for every machine: mission.scale {n, at} with at = shared clock +
## SCALE_LEAD (before the release: now, so the start value just changes), applied here at `at` too.
func on_member_retired(pilot_id: int) -> void:
	if not crew or not deciding() or drive == null:
		return
	_forget_pilot(pilot_id)
	var n := MissionFlow.host_crew_scale(drive.crew_members())
	var cur := _scale_target()
	if n == cur:
		return
	var t := now()
	var at := maxf(t + SCALE_LEAD if released else t, _scale_last_at + SCALE_STEP)
	var change := {"n": n, "at": at, "from": cur, "reason": "leave", "pilot": pilot_id}
	print("[mission] scale decided %d -> %d at %.3f (pilot %d left)" % [cur, n, at, pilot_id])
	var sess := Net.session()
	if sess != null:
		sess.mission.host_scale(change)
	receive_scale(change, false)


## Session.mission_scale (a client): the host's change.
func _on_scale_msg(change: Dictionary) -> void:
	if deciding():
		return
	receive_scale(change)


## A change {n, at, from?, reason?, pilot?} for this machine's schedule (the host's own decision, mission.scale, the
## state's "scale"): ignored when its `at` is not newer than the newest known here (a duplicate, a late copy; counted in
## scale_dups when `count`); otherwise applied by _tick_scale once the mission clock reaches `at`.
func receive_scale(change: Dictionary, count: bool = true) -> void:
	var at := float(change.get("at", NAN))
	var n := int(change.get("n", 0))
	if is_nan(at) or is_inf(at) or n < 1 or n > 4:
		return
	if at <= _scale_last_at:
		if count:
			scale_dups += 1
		return
	_scale_last_at = at
	_scale_due.append({"n": n, "at": at, "from": int(change.get("from", _scale_target())),
		"reason": str(change.get("reason", "")), "pilot": int(change.get("pilot", 0))})


## mission.state's "scale": [n, at] (a late state, a barrier latecomer): scheduled like a mission.scale, never counted.
func apply_scale_state(v: Variant) -> void:
	if v is Array and (v as Array).size() >= 2:
		receive_scale({"n": int(v[0]), "at": float(v[1]), "reason": "state"}, false)


## Apply every change whose `at` has come (every machine, every physics step and at setup).
func _tick_scale() -> void:
	while not _scale_due.is_empty() and now() >= float((_scale_due[0] as Dictionary)["at"]):
		_apply_scale(_scale_due.pop_front())


## The crew scale becomes change.n here, at change.at: the director rescales (PacingDirector.rescale), the relay's max HP
## follows through asset_max_hp() while asset_hp (its fraction) stays (destroyed stays destroyed), depot cores and the
## garrison stay. Logged ([mission] scale a -> b, CombatLog `scale`). Going up is accepted with a warning.
func _apply_scale(change: Dictionary) -> void:
	var old := _scale
	var n := clampi(int(change["n"]), 1, 4)
	var at := float(change["at"])
	scale_at = at
	if n == old:
		return
	if n > old:
		push_warning("[mission] crew scale goes UP %d -> %d (no mid-mission join exists): accepted" % [old, n])
	_scale = n
	if director != null:
		director.rescale(n)
	var reason := str(change.get("reason", ""))
	var pilot := int(change.get("pilot", 0))
	scale_log.append({"from": old, "to": n, "at": at, "t": now(), "reason": reason, "pilot": pilot})
	print("[mission] scale %d -> %d (reason %s, pilot %d, at %.3f)" % [old, n, reason, pilot, at])
	CombatLog.note_scale(old, n, reason, pilot, at)


## Host: pilot `pilot_id` left: no per-pilot entry of it stays in the director (intensity, engagement), the fight facts or
## the depots' claim bookkeeping.
func _forget_pilot(pilot_id: int) -> void:
	if director != null:
		director.forget_pilot(pilot_id)
	if pacing != null:
		pacing.forget_pilot(pilot_id)
	if depots != null:
		depots.forget_pilot(pilot_id)


## Host / tests: the defend relay `id`'s health (0..1). Weapons' relay target reports hits through damage_asset.
func set_asset_hp(id: String, hp: float) -> void:
	if not asset_hp.has(id) or not deciding():
		return
	asset_hp[id] = clampf(hp, 0.0, 1.0)


## A defend relay's hit points at the crew scale (ASSET_MAX_HP x ASSET_HP_SCALE[crew_scale() - 1]); every machine computes
## the same from the host's scale. asset_hp is the FRACTION, so a rescale keeps it and only the hit points change.
func asset_max_hp() -> float:
	return ASSET_MAX_HP * float(ASSET_HP_SCALE[clampi(crew_scale(), 1, 4) - 1])


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
	if world == null or drive == null or drive.combat == null:
		return
	for id: String in asset_hp:
		if not _asset_targets.has(id):
			var body: Node3D = world.asset_body(id)
			if body == null or not body.is_inside_tree():
				continue
			_asset_targets[id] = drive.combat.add_asset(id, body, ASSET_RADIUS, ASSET_HEIGHT)
		var t: Variant = _asset_targets[id]
		if t != null and is_instance_valid(t):
			(t as AssetTarget).set_live(_asset_active(id))
		if t != null and is_instance_valid(t):
			var hp := float(asset_hp.get(id, 1.0)) * asset_max_hp()
			var mx := asset_max_hp()
			_push("asset_target:" + id, [hp, mx], func() -> void: (t as AssetTarget).set_hp(hp, mx))   # a rescale moves mx


# --- Presentation on every machine ------------------------------------------------------------------------------

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
	hud_model.zones = {}
	for o: Dictionary in rules.objectives:
		var id: String = o["id"]
		var st := rules.obj_state(id)
		match str(o["type"]):
			"flag":
				var inside := _crew_within(o, crew_f)
				hud_model.zones[id] = {"crew": inside, "enemies": int(zen.get(id, 0))}
				if st == "done":
					_push("flag:" + id, true, func() -> void: world.set_flag(id, true))
				var z := "idle"
				if st == "done" or (inside and int(zen.get(id, 0)) == 0):
					z = "ours"
				elif int(zen.get(id, 0)) > 0:
					z = "contested"
				_push("zone:" + id, z, func() -> void: world.set_zone(id, z))
			"defend":
				hud_model.zones[id] = {"crew": _crew_within(o, crew_f), "enemies": int(zen.get(id, 0))}
				var hp := float(asset_hp.get(id, 1.0))
				_push("asset:" + id, hp, func() -> void: world.set_asset(id, hp))
			"hold":
				var tot := maxf(float(rules.state().get("objs", {}).get(id, [0, 0, 0])[2]), 0.001)
				var p := clampf(rules.obj_progress(id) / tot, 0.0, 1.0)
				if st == "done":
					p = 1.0
				var inside := _crew_in_zone(o, crew_f)
				hud_model.zones[id] = {"crew": inside, "enemies": 0}
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
