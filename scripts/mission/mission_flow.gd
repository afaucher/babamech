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
## stack.setup_mission(plan) (Environment's MissionWorld: wave doors, flag masts, defend relays, the hold zone, the road doors) and
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
## the enemies this machine sees in the ring: cosmetic), set_asset(id, hp), set_hold_zone; the ally's HUD lines
## (MissionRules.ally_due -> hud_model.ally); the mission clock goes to MissionWorld.advance_to every frame. A failed
## primary ends the mission "lost" (objective_failed).
##
## THE EXIT (R2.10, docs/design/mission-objectives.md §9 "The exit"): the extraction is a 30 s hold in the zone in front of
## the exit road door while an ally opens it. When the hold completes the rules latch exit_at (facts.t + EXIT_LEAD) and the
## HOST orders the exit door open at exit_at, held open for the rest of the mission (DOOR_HOLD): a replicated door order
## on the wave path (mission.wave {wave: "door", source: MissionWorld.EXIT_ID, door: "open", open_at, hold}; every machine
## applies it in _door_order -> MissionWorld.open_source(id, open_at, hold, open_at); a client that missed it applies the
## same from the state's "exit"). Nothing else ever opens the exit door (no plan source names it). Crew facts then carry
## `exit`: the mech is inside the exit bay (bay_contains inside, at least its capsule radius past the door plane:
## _in_exit), and the rules win once every standing pilot is in. No exit door on the deck (exit_door().ok false): the
## rules' walk_out is off and the hold's completion wins (warned).
## THE ENTRY DOOR (crew missions): at setup every machine shuts it (shut_source at ENTRY_SHUT_AT, a constant: the same
## schedule everywhere), so the crew waits behind it through the load barrier; at the release every machine opens it at
## the barrier's shared start_at (Session.mission.start_at: no message needed; the leaves are never solid while moving). The HOST shuts it again (a replicated
## door order) once no crew mech has been in its bay or doorway for ENTRY_CLEAR s, and reopens it whenever one is found
## there after that. Solo: the door's default (open from clock 0).
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
## DEBRIEF (R2.15a): at the outcome the host / solo freezes MissionStats into `debrief` (once) and the end above is
## Session.mission.end(end_reason(), debrief) (solo too: NetMission keeps it for the hangar's board). The crew quitting
## before an outcome ends with no debrief.

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
const ROLL_OUT_HOLD := 15.0       ## s a gate stays open once its staged group starts rolling out (then MissionBays holds it
                                  ## while anyone is still inside)
const STAGE_TIMEOUT := 20.0       ## s past its open_at a staged group waits for a door that never becomes passable
const LIFT_DOOR_MARGIN := 1.0     ## m behind a lift car's door plane its formation starts (no leaves inside the car)
const SCALE_LEAD := 1.0           ## s on the shared clock between the host's scale decision and `at` (every machine has it)
const SCALE_STEP := 0.001         ## s: each new change's `at` is at least this after the previous one (strict order)
const DOOR_HOLD := 100000.0       ## s a road door ordered open stays open (the rest of the mission)
const DOOR_LEAD := 0.5            ## s on the shared clock between the host's entry door decision and its `at`
const ENTRY_SHUT_AT := -1.0e6     ## the entry door's setup shut (crew): one constant, so every machine stores one schedule
const ENTRY_CLEAR := 3.0          ## s with no crew mech in the entry bay / doorway before the host shuts the entry door

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
## Host: nobody is shut in a bay (MissionBays: hold while occupied, push out, withdraw; playtest R2.4).
var bays: MissionBays
var _holds := 0                   ## host: hold orders sent (their wave key)
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
## The debrief's counters (MissionStats child, HOST / SOLO only: clients never count; docs/design/debrief-stats.md). Made
## fresh by rebuild; at the outcome _check_outcome freezes it into `debrief`, which _tick_end hands to
## Session.mission.end(end_reason(), debrief) (host: rides mission.end to the crew; solo: kept in NetMission.last_debrief).
var stats: MissionStats
var debrief: Dictionary = {}      ## host / solo: the payload built once at the outcome ({} before, and on clients)
var door_log: Array = []          ## every machine: road door orders applied here [{id, door, at}] (tests, logs)
var _exit_sent := false           ## host: the exit door order went out
var _entry_shut := false          ## host: the entry door was ordered shut (after the crew left its bay)
var _entry_clear_t := 0.0         ## host: s the entry bay and doorway have been free of crew mechs
var _entry_opened := false        ## every machine: the release's entry door opening was applied
var _ally_said: Dictionary = {}   ## every machine: the ally lines already shown (MissionRules.ally_due)


## Authority (scripts/net/net.gd): the rules and the director declare the mission's progress themselves
## (MissionRules.net_fields, PacingDirector.net_fields); the rest is this machine's wiring, timers and presentation.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "rules": Net.LOCAL, "crew": Net.SPAWN, "released": Net.LOCAL, "end_left": Net.LOCAL,
		"ended": Net.LOCAL, "evaluations": Net.LOCAL, "_eval_left": Net.PRIVATE, "_end_wait": Net.LOCAL,
		"plan": Net.LOCAL, "director": Net.LOCAL, "world": Net.LOCAL, "pacing": Net.LOCAL, "_rollouts": Net.PRIVATE,
		"bays": Net.LOCAL,             # MissionBays declares its own (host bookkeeping)
		"_holds": Net.PRIVATE,
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
		"depots": Net.LOCAL,   # MissionDepots declares its own state (net_fields)
		"stats": Net.LOCAL,    # MissionStats declares its own (host counters)
		"debrief": Net.OWNER,  # the host builds it at the outcome; mission.end carries it
		"door_log": Net.LOCAL, # this machine's applied door orders (the orders themselves ride mission.wave)
		"_exit_sent": Net.PRIVATE, "_entry_shut": Net.PRIVATE, "_entry_clear_t": Net.PRIVATE,   # host door bookkeeping
		"_entry_opened": Net.LOCAL,   # this machine applied the release's opening (from the shared start_at)
		"_ally_said": Net.LOCAL}      # this machine's HUD memory of the ally lines


func _init() -> void:
	hud_model = MissionHudModel.new(self)
	bays = MissionBays.new(self)


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
		if released:
			_entry_release()
	else:
		released = true


## New rules for the drive's section (setup, and solo N: a new city).
func rebuild() -> void:
	var sec: SectionPlan = drive.stack.section if drive != null and drive.stack != null else null
	if depots != null and is_instance_valid(depots):
		depots.teardown()
		depots.queue_free()
	depots = null
	if stats != null and is_instance_valid(stats):
		stats.queue_free()
	stats = null
	plan = null
	director = null
	if pacing != null:
		pacing.unbind()
	pacing = null
	_rollouts = []
	bays.reset()
	_holds = 0
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
	door_log = []
	_exit_sent = false
	_entry_shut = false
	_entry_clear_t = 0.0
	_entry_opened = false
	_ally_said = {}
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
		_setup_doors()
		depots = MissionDepots.new()
		depots.name = "MissionDepots"
		add_child(depots)
		depots.setup(self)
		if deciding():
			stats = MissionStats.new()
			stats.name = "MissionStats"
			add_child(stats)
			stats.setup(self)
	debrief = {}
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
	var f := {"peer": peer, "downed": downed, "redeploying": redeploying, "deck": int(a["deck"]), "x": float(a["x"]),
		"s": float(a["s"])}
	if rules != null and rules.exit_open():
		f["exit"] = _in_exit(m)
	return f


## The walk-out's "inside" (R2.10): mech `m` is inside the exit bay (MissionWorld.bay_contains `inside`: behind the door
## plane, within the bay's walls, under its roof) with its centre at least its capsule radius behind the door plane, so
## the whole hull is through (a Bulwark 3.6 m, a Strider 2.2 m). False without a world or an exit door.
func _in_exit(m: Node3D) -> bool:
	if world == null or not is_instance_valid(world) or m == null:
		return false
	var bc := world.bay_contains(MissionWorld.EXIT_ID, m.global_position)
	return bool(bc.get("inside", false)) and float(bc.get("depth", 0.0)) >= mech_radius(m)


## The mech's capsule radius: its MechController's chassis (MechCatalog.movement capsule_radius, applied at spawn on every
## machine, puppets too: MechController.apply_chassis), the Strider's for anything else.
static func mech_radius(m: Node3D) -> float:
	var id: Variant = m.get("chassis_id")
	return float(MechCatalog.movement(str(id) if id != null else "strider")["capsule_radius"])


func _on_go(_elapsed: float) -> void:
	released = true
	_entry_release()


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
		if rules.exit_open() and not _exit_applied():
			# The state says the exit is open but its door order has not been applied here (yet): the same order.
			_door_order({"wave": "door", "source": MissionWorld.EXIT_ID, "door": "open", "open_at": rules.exit_at,
				"hold": DOOR_HOLD})
		_present()
	_check_outcome()


func _check_outcome() -> void:
	if rules.outcome == "" or end_left >= 0.0 or ended:
		return
	end_left = END_HOLD
	_end_wait = 0.0
	print("[mission] %s (%s)" % [rules.outcome, rules.reason])
	if rules.outcome == "won" and rules.exit_open():
		print("[mission] exit: the crew walked out at %.2f" % now())
		CombatLog.note_door("win", MissionWorld.EXIT_ID, now())
	if deciding() and stats != null and debrief.is_empty():
		debrief = stats.finish(rules.outcome, end_reason())   # once, at the outcome: the counters freeze here
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
		sess.mission.end(end_reason(), debrief)
	elif not crew and sess != null:
		sess.mission.end(end_reason(), debrief)   # solo: NetMission just keeps the debrief for the hangar's board
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
	if rules.exit_open() and not _exit_sent:
		_exit_sent = true
		_send_door(MissionWorld.EXIT_ID, "open", rules.exit_at)
	_tick_entry(t, crew_f)
	var orders := director.tick(t, _director_facts(enemies, crew_f, live))
	for o: Dictionary in orders:
		o["order_t"] = t   # when the host ordered it (_no_snap: a door already closing / shut then is not re-extended)
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
		"kills": pf.get("kills", []), "source_route": _source_routes(crew_f), "busy_sources": bays.busy_sources()}


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
## wave's gate (mission.wave), marked "air" (no wave, no units). `arriving` (a dropship comes out through it) gives the
## crew its alert, "Dropship, north air door", with the INBOUND marker on the door's `out` point (playtest R2.24); its way
## back in does not. Again with the same open_at and a longer hold it extends the hold (MissionWorld.open_source; clients
## apply it since NetMission dedups on wave + source + open_at + hold).
func order_air_door(id: String, deck: int, open_at: float, hold: float, arriving: bool = false) -> void:
	var o := {"wave": "air", "deck": deck, "source": id, "open_at": open_at, "hold": hold, "max_units": 0, "air": true,
		"reason": "dropship"}
	if arriving:
		o["arrive"] = true
	if crew:
		Net.session().mission.host_wave(o)
	_open(o)


## Host: keep wave door `src` open until at least `until_t` on every machine (MissionBays: someone is still inside). A
## replicated "hold" order (mission.wave, hold_only: no units, no alert) with the door's own open_at; every machine calls
## MissionWorld.hold_source (it only ever extends, never re-opens a door that is shut).
func hold_door(src: String, until_t: float) -> void:
	if world == null:
		return
	var st := world.source_state(src)
	if str(st.get("state", "")) in ["shut", "sealed"]:
		return
	var oa := float(st.get("open_at", INF))
	if oa == INF:
		return
	_holds += 1
	var o := {"wave": "hold", "deck": int(plan.source(src).get("deck", 0)) if plan != null else 0, "source": src,
		"open_at": oa, "hold": snappedf(until_t - oa, 0.01), "until": until_t, "hold_only": true, "max_units": 0,
		"reason": "hold", "n": _holds}
	if crew:
		Net.session().mission.host_wave(o)
	_open(o)


## Host: open wave door `src` again at `at` on every machine (MissionBays rule 5: a crew mech is inside its bay / car while
## it closes or is shut). A replicated "hold" order with `reopen` (no units, no alert): every machine calls
## MissionWorld.open_source (a closing door finishes closing first, then opens: never a jump). Never a sealed door.
func reopen_door(src: String, at: float) -> void:
	if world == null:
		return
	if str(world.source_state(src).get("state", "")) == "sealed":
		return
	_holds += 1
	var o := {"wave": "hold", "deck": int(plan.source(src).get("deck", 0)) if plan != null else 0, "source": src,
		"open_at": at, "hold": MissionBays.KEEP, "until": at + MissionBays.KEEP, "hold_only": true, "reopen": true,
		"max_units": 0, "reason": "crew", "n": _holds}
	if crew:
		Net.session().mission.host_wave(o)
	_open(o)


# --- The exit and entry road doors (see THE EXIT / THE ENTRY DOOR in the header) -------------------------------------

## Every machine, at rebuild once the world is set up: the exit bay for the rules (marker, walk_out), and (crew) the entry
## door shut for the load barrier.
func _setup_doors() -> void:
	if world == null or rules == null:
		return
	var ex := world.exit_door()
	if bool(ex.get("ok", false)):
		rules.set_exit(int(ex.get("deck", 0)), float(ex.get("x", 0.0)), float(ex.get("s", 0.0)))
	else:
		rules.options["walk_out"] = false
		push_warning("[mission] no exit door on this section: the hold's completion wins the mission")
		print("[mission] exit: no exit door (seed %d): the hold wins" % (drive.seed_value if drive != null else 0))
	if crew and not released and bool(world.entry_door().get("ok", false)):
		world.shut_source(MissionWorld.ENTRY_ID, ENTRY_SHUT_AT)


## Every machine of a crew, at the release: the entry door opens at the barrier's shared start_at (siren and leaves on
## every machine together; moving leaves are never solid, so nobody is held; no message: every machine has start_at). Once.
func _entry_release() -> void:
	if _entry_opened or not crew or world == null or not is_instance_valid(world):
		return
	if not bool(world.entry_door().get("ok", false)):
		return
	_entry_opened = true
	var sess := Net.session()
	var at := float(sess.mission.start_at) if sess != null and sess.mission.start_at > 0.0 else now()
	_door_order({"wave": "door", "source": MissionWorld.ENTRY_ID, "door": "open", "open_at": at, "hold": DOOR_HOLD})


## Host, every evaluation (crew): once the crew has left the entry bay (no crew mech, standing or downed, inside it or in
## its doorway for ENTRY_CLEAR s, the door fully open), order it shut; when a crew mech is found there after that (a
## respawn, a pilot walking back to it), order it open again. Never shut on a mech: the doorway counts.
func _tick_entry(t: float, _crew_f: Array) -> void:
	if not crew or world == null or not _entry_opened or not bool(world.entry_door().get("ok", false)):
		return
	var someone := false
	for c: Dictionary in drive.crew_members():
		var m: Variant = c.get("mech")
		if not is_instance_valid(m):
			continue
		var bc := world.bay_contains(MissionWorld.ENTRY_ID, (m as Node3D).global_position)
		if bool(bc.get("inside", false)) or bool(bc.get("doorway", false)):
			someone = true
			break
	if someone:
		_entry_clear_t = 0.0
		if _entry_shut:
			_entry_shut = false
			_send_door(MissionWorld.ENTRY_ID, "open", t + DOOR_LEAD)
		return
	if _entry_shut or not bool(world.source_state(MissionWorld.ENTRY_ID).get("passable", false)):
		return
	_entry_clear_t += EVAL_INTERVAL
	if _entry_clear_t >= ENTRY_CLEAR:
		_entry_shut = true
		_send_door(MissionWorld.ENTRY_ID, "shut", t + DOOR_LEAD)


## Host: a road door order for every machine: the wave path (mission.wave {wave: "door", source, door: open | shut,
## open_at: the moment, hold}), applied here too. An "open" holds DOOR_HOLD s; a "shut" carries hold -1 (NetMission
## dedups on wave + source + open_at + hold: two orders never share a moment).
func _send_door(id: String, what: String, at: float) -> void:
	var o := {"wave": "door", "deck": 0, "source": id, "door": what, "open_at": at,
		"hold": DOOR_HOLD if what == "open" else -1.0, "max_units": 0, "reason": "door"}
	if crew:
		Net.session().mission.host_wave(o)
	_door_order(o)


## Every machine: apply a road door order (the host's own, mission.wave, or the state's exit fallback).
func _door_order(o: Dictionary) -> void:
	var id := str(o.get("source", ""))
	var what := str(o.get("door", ""))
	var at := float(o.get("open_at", 0.0))
	if id == MissionWorld.EXIT_ID and what == "open" and _exit_applied():
		return   # the order and the state's fallback: the same open_at, once
	door_log.append({"id": id, "door": what, "at": at})
	if world != null and is_instance_valid(world):
		if what == "open":
			world.open_source(id, at, float(o.get("hold", DOOR_HOLD)), at)
		elif what == "shut":
			world.shut_source(id, at)
	print("[mission] %s %s at %.2f" % ["exit" if id == MissionWorld.EXIT_ID else "entry", what, at])
	CombatLog.note_door(what, id, at)


## The exit door's open order was applied on this machine.
func _exit_applied() -> bool:
	for d: Dictionary in door_log:
		if str(d["id"]) == MissionWorld.EXIT_ID and str(d["door"]) == "open":
			return true
	return false


## Every machine: a wave order from the director (host / solo) or the host (mission.wave): schedule its door. An air door
## order (o.air, a dropship's) only schedules its door with its hold (and, arriving, the crew's alert); a hold order
## (o.hold_only) only extends a door's hold; a road door order (o.door: the exit / entry door) goes to _door_order.
func _open(o: Dictionary) -> void:
	var src := str(o.get("source", ""))
	var open_at := float(o.get("open_at", 0.0))
	if o.has("door"):
		_door_order(o)
		return
	if bool(o.get("hold_only", false)):
		if world != null:
			if bool(o.get("reopen", false)):
				world.open_source(src, open_at, float(o.get("hold", MissionBays.KEEP)), open_at)
			else:
				world.hold_source(src, float(o.get("until", open_at)))
		return
	if bool(o.get("air", false)):
		opened.append({"wave": "air", "source": src, "open_at": open_at})
		if world != null:
			world.open_source(src, open_at, float(o.get("hold", MissionWorld.HOLD)))
		if bool(o.get("arrive", false)):
			hud_model.alert(o.duplicate(), "Dropship, " + air_words(int(o.get("deck", 0)), src), int(o.get("deck", 0)))
		return
	opened.append({"wave": str(o.get("wave", "")), "source": src, "open_at": open_at})
	if world != null:
		_no_snap(src, open_at, float(o.get("order_t", NAN)))
		world.open_source(src, open_at)
	hud_model.alert(o.duplicate(), "Reinforcements, " + source_words(src), int(o.get("deck", 0)))
	var wid := str(o.get("wave", ""))
	var size := str(_wave_size[wid]) if _wave_size.has(wid) else "?"
	print("[mission] wave %s: %s opens at %.2f (%s units, cap room %d, %s)" % [wid, src, open_at, size,
		int(o.get("max_units", 0)), str(o.get("reason", ""))])
	wave_ordered.emit(o)


## Every machine, before scheduling a wave door: when the door is still due open (or closing) less than WARN + CLOSE
## before the new open_at, MissionWorld would re-schedule it and its leaves would snap shut into the "warn" state (and
## slam on anyone in the doorway: playtest R2.4). Extend the current schedule up to the new open_at instead, so
## open_source only extends the hold. A pure function of the schedule and the order (no clock): every machine does the
## same. Not when the host ordered it at or after the door's close (`order_t`, the order's own time): extending a door
## that is already closing or shut would pop its leaves back open; open_source's own cycle waits for the closing then.
func _no_snap(src: String, open_at: float, order_t: float = NAN) -> void:
	var st := world.source_state(src)
	if str(st.get("state", "")) == "sealed":
		return
	var ca := float(st.get("close_at", INF))
	if ca == INF or open_at <= ca:
		return
	if not is_nan(order_t) and order_t >= ca:
		return
	if open_at - MissionWorld.WARN < ca + MissionWorld.CLOSE:
		world.hold_source(src, open_at)


## "north air door" (playtest R2.24's alert wording, as source_words): the side of deck `deck` air door `id` is on.
func air_words(deck: int, id: String) -> String:
	if world == null:
		return "air door"
	for i in world.air_door_count(deck):
		var d := world.air_door(deck, i)
		if str(d.get("id", "")) != id:
			continue
		var x := float(d.get("x", 0.0))
		var s := float(d.get("s", 0.0))
		var dir := ""
		if drive != null and drive.stack != null and drive.stack.section != null:
			var sec := drive.stack.section
			var fx := x / maxf(sec.p("width") * 0.5, 1.0)
			var fs := s / maxf(sec.arc_of(deck) * 0.5, 1.0)
			if absf(fx) > absf(fs):
				dir = "east" if fx > 0.0 else "west"
			else:
				dir = "north" if fs > 0.0 else "south"
		return ("%s air door" % dir) if dir != "" else "air door"
	return "air door"


## The world point a wave / air order's INBOUND marker sits on (playtest R2.24: always the real opening): an air door's
## `out` point; a gate's or lift's door opening (its door node's world_point); else (ramp, shaft) the plan's mouth point at
## MissionHudModel.SOURCE_H. null when unknown.
func alert_point(o: Dictionary) -> Variant:
	if world == null or drive == null or drive.stack == null:
		return null
	var src := str(o.get("source", ""))
	if bool(o.get("air", false)):
		var k := int(o.get("deck", 0))
		for i in world.air_door_count(k):
			var d := world.air_door(k, i)
			if str(d.get("id", "")) == src and d.get("out") is Vector3:
				return d["out"]
		return null
	var door: Variant = world.door_nodes().get(src)
	if door != null and is_instance_valid(door) and (door as Object).has_method("world_point"):
		return (door as Object).call("world_point")
	var sp := world.source_point(src)
	if sp.is_empty():
		return null
	return drive.stack.from_deck_arc(int(sp["deck"]), float(sp["x"]), float(sp["s"]), MissionHudModel.SOURCE_H)


## Client: the host's wave order.
func _on_wave(o: Dictionary) -> void:
	if plan == null or deciding():
		return
	_open(o)


## Host: spawn the waves whose door has opened; roll out staged gate groups whose door is passable.
func _spawn_due() -> void:
	_roll_due()
	bays.tick(get_physics_process_delta_time())
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
	var squad: Variant = drive.combat.squad if drive.combat != null else null
	for r: Dictionary in _rollouts:
		var src := str(r["source"])
		var wid := str(r["wave"])
		var gone := _door_gone(src, float(r["open_at"]), t)
		if gone != "":
			# Rule 5: a staged group whose door got sealed / never opens is not left dormant behind it: withdrawn.
			var n := (squad as EnemySquad).unstage_wave(wid, "bay:" + gone) if is_instance_valid(squad) else 0
			print("[mission] bay %s: wave %s never got its door (%s): %d staged units withdrawn" % [src, wid, gone, n])
			CombatLog.note_source("removed", src, wid, "staged", "%s:%d" % [gone, n])
		elif t >= float(r["open_at"]) and _passable(src, float(r["open_at"]), t):
			if is_instance_valid(squad):
				(squad as EnemySquad).roll_out_wave(wid)
			hold_door(src, t + ROLL_OUT_HOLD)
			if world != null:
				bays.track(src, t + ROLL_OUT_HOLD, world.source_bay(src), source_bay(src))
		else:
			rest.append(r)
	_rollouts = rest


## A staged group's door will not let it out: "sealed", or "stuck" (still not passable STAGE_TIMEOUT s after its open_at);
## "" while it may still open.
func _door_gone(src: String, open_at: float, t: float) -> String:
	if world == null:
		return ""
	var st: Dictionary = world.source_state(src)
	if str(st.get("state", "")) == "sealed":
		return "sealed"
	if t >= open_at + STAGE_TIMEOUT and not bool(st.get("passable", false)):
		return "stuck"
	return ""


## A bay's door is passable now: MissionWorld's source_state passable (fully open); a world without a schedule
## (passable_at but no state) at open_at + OPENING. Never through a sealed door.
func _passable(src: String, open_at: float, t: float) -> bool:
	if world == null:
		return true
	var st: Dictionary = world.source_state(src)
	if str(st.get("state", "")) == "sealed":
		return false
	if st.has("passable"):
		return bool(st["passable"])
	if st.has("passable_at"):
		return t >= float(st["passable_at"])
	return t >= open_at + MissionWorld.passable_after(str(plan.source(src).get("kind", "gate")))


## The staging bay of a gate or lift source in arc coordinates (BayFormation.from_world_bay of MissionWorld.source_bay), {}
## when the source has none (ramp, shaft, a gate without a door, a lift until Environment builds its car: R2.22 switches on
## by itself when source_bay(id) answers `ok` for a lift). A lift car's door has no leaves to clear inside, so its
## formation starts LIFT_DOOR_MARGIN m behind the door plane (a gate bay's, BayFormation.DOOR_MARGIN).
func source_bay(src: String) -> Dictionary:
	if world == null or plan == null:
		return {}
	var kind := str(plan.source(src).get("kind", ""))
	if kind != "gate" and kind != "lift":
		return {}
	var b := world.source_bay(src)
	if not bool(b.get("ok", false)):
		return {}
	return arc_bay(b, drive.stack if drive != null else null, kind)


## BayFormation's arc bay from a source_bay dictionary `b` (`kind`: gate | lift), `exit_arc` from its world `exit`.
static func arc_bay(b: Dictionary, stack: CityStack, kind: String = "gate") -> Dictionary:
	var d := b.duplicate()
	if d.get("exit") is Vector3 and stack != null:
		var a := stack.to_deck_arc(d["exit"] as Vector3)
		d["exit_arc"] = Vector2(float(a["x"]), float(a["s"]))
	if kind == "lift" and not d.has("door_margin"):
		d["door_margin"] = LIFT_DOOR_MARGIN
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


## Push the replicated state to the world (flags, zones, relays, the hold zone) and refresh this machine's zone view and
## the ally's lines.
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
				var inside := _crew_in_zone(o, crew_f)
				hud_model.zones[id] = {"crew": inside, "enemies": 0}
				var hz := "done" if st == "done" else ("holding" if inside and st == "active" else "idle")
				_push("hold:" + id, hz, func() -> void: world.set_hold_zone(hz))
	for line in rules.ally_due(_ally_said):
		hud_model.ally(line, now())
		print("[mission] ally: %s" % line)


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
