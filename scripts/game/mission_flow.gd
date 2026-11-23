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
## rules = MissionRules.make(section, {plan}), director = WaveDirector.make(plan, test_director), then
## stack.setup_mission(plan) (Environment's MissionWorld: wave doors, flag masts, defend relays, the portal) and
## rules.set_site() from its flag_site / asset_site, all before the first evaluate. The load barrier's checksum joins
## plan.checksum() (TestDrive.mission_checksum). The HOST / SOLO tick (same gate, EVAL_INTERVAL, t = Session.host_time(),
## solo: this node's mission clock) evaluates the rules first, then ticks the director with the fresh state:
##   rules facts    t, enemies, crew, waves_left, waves, zone_enemies {objective id: enemies inside its radius}, assets
##                  {defend id: hp}, defend_waves
##   director facts alive, garrison_alive (wave == "" per deck), wave_alive {wave: {alive, total}}, wave_pending, crew_deck,
##                  objectives = rules.state(), closed (none in phase 1)
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
const ASSET_MAX_HP := 600.0       ## a defend relay's hit points (Weapons' AssetTarget hits are in points; asset_hp is 0..1)
const ASSET_RADIUS := 2.5         ## m, the relay's hit-sphere radius for combat
const ASSET_HEIGHT := 6.0         ## m, the hit spheres stack this high

## Tests: overrides for MissionPlan.make / WaveDirector.make in plan mode (set the same on every machine of a test:
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
var director: WaveDirector
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


## Authority (scripts/net/net.gd): the rules and the director declare the mission's progress themselves
## (MissionRules.net_fields, WaveDirector.net_fields); the rest is this machine's wiring, timers and presentation.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "rules": Net.LOCAL, "crew": Net.SPAWN, "released": Net.LOCAL, "end_left": Net.LOCAL,
		"ended": Net.LOCAL, "evaluations": Net.LOCAL, "_eval_left": Net.PRIVATE, "_end_wait": Net.LOCAL,
		"plan": Net.LOCAL, "director": Net.LOCAL, "world": Net.LOCAL,
		"_asset_targets": Net.LOCAL,   # this machine's combat registrations of the relays
		"_asset_armed": Net.PRIVATE,   # host: relays whose defend went active (their one HP reset done)
		"asset_hp": Net.OWNER,         # the host decides (damage_asset), mission.state carries it
		"opened": Net.LOCAL, "unspawned": Net.PRIVATE, "_clock": Net.PRIVATE, "_sent": Net.PRIVATE, "_spawns": Net.PRIVATE,
		"_pending": Net.PRIVATE, "_wave_total": Net.PRIVATE, "_seen": Net.PRIVATE, "_wave_size": Net.PRIVATE, "_wave_size_crew": Net.PRIVATE, "_present_left": Net.LOCAL,
		"_pushed": Net.LOCAL, "_alerts": Net.LOCAL, "_rings": Net.LOCAL, "_zone_seen": Net.LOCAL}


## DEV plan mode wanted by this machine (solo, or the crews it hosts): `--objectives` or GameSettings dev objectives.
static func objectives_wanted(args: PackedStringArray, settings: Dictionary) -> bool:
	return args.has("--objectives") or bool(settings.get("objectives", false))


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
	plan = null
	director = null
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
		director = WaveDirector.make(plan, test_director)
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
	if plan != null:
		if d.get("dir") is Dictionary:
			director.apply_state(d["dir"])
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
		_spawns.append(o)
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
		"crew_deck": decks, "crew": crew_f, "wave_size": wave_sizes(), "objectives": rules.state(), "closed": []}


## Host: {wave id: units} for every wave of the plan (the director holds that much cap room until a wave's door
## opens), from antigravity's EnemySpawner.plan_wave with max_units 0 (counts, places nothing); cached per crew size.
func wave_sizes() -> Dictionary:
	var n := drive.spawn_order.size() if crew and drive != null else 1
	if n == _wave_size_crew and not _wave_size.is_empty():
		return _wave_size
	_wave_size_crew = n
	_wave_size = {}
	var spawner := load(SPAWNER) as GDScript
	if plan == null or spawner == null or not _has_static(spawner, "plan_wave") or not _has_static(spawner, "deck_budget"):
		return _wave_size
	for k in plan.deck_count:
		var pl := plan.pool(k)
		var budget := int(spawner.call("deck_budget", n, k))
		for w: Dictionary in pl.get("waves", []):
			var r: Variant = spawner.call("plan_wave", null, null, {"wave": w["id"], "max_units": 0}, w, {}, budget,
				drive.seed_value, 0, 1.0 - float(pl.get("garrison", 0.0)))
			if r is Dictionary:
				_wave_size[w["id"]] = int((r as Dictionary).get("total_units", 0))
	return _wave_size


## Every machine: a wave order from the director (host / solo) or the host (mission.wave): schedule its door.
func _open(o: Dictionary) -> void:
	var src := str(o.get("source", ""))
	var open_at := float(o.get("open_at", 0.0))
	opened.append({"wave": str(o.get("wave", "")), "source": src, "open_at": open_at})
	if world != null:
		world.open_source(src, open_at)
	_alerts.append({"order": o.duplicate(), "text": "Reinforcements, " + source_words(src), "deck": int(o.get("deck", 0))})
	if _alerts.size() > 8:
		_alerts.pop_front()
	var wid := str(o.get("wave", ""))
	var size := str(_wave_size[wid]) if _wave_size.has(wid) else "?"
	print("[mission] wave %s: %s opens at %.2f (%s units, cap room %d)" % [wid, src, open_at, size, int(o.get("max_units", 0))])
	wave_ordered.emit(o)


## Client: the host's wave order.
func _on_wave(o: Dictionary) -> void:
	if plan == null or deciding():
		return
	_open(o)


## Host: spawn the waves whose door has opened.
func _spawn_due() -> void:
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
	var wave := {}
	for w: Dictionary in pool.get("waves", []):
		if w["id"] == id:
			wave = w
	var src := plan.source(str(o["source"])).duplicate()
	src["point"] = world.source_point(str(o["source"])) if world != null else {}
	var ctx := {"stack": drive.stack, "world": drive.combat.world if drive.combat != null else null,
		"squad": drive.combat.squad if drive.combat != null else null, "seed": drive.seed_value,
		"crew": drive.spawn_order.size() if crew else 1, "pool": pool}
	var left: Variant = spawner.call("spawn_wave", o, wave, src, ctx)
	_pending[id] = maxi(int(left), 0) if (left is int or left is float) else 0


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


## Host: Weapons' AssetTarget reports an applied hit (`amount` in hit points, ASSET_MAX_HP for a full relay). Ignored
## unless the relay's defend objective is active (Missions' playtest: a garrison shot the relay with no crew on its deck).
func damage_asset(id: String, amount: float) -> void:
	if not _asset_active(id):
		return
	set_asset_hp(id, float(asset_hp.get(id, 0.0)) - amount / ASSET_MAX_HP)


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
			var hp := float(asset_hp.get(id, 1.0)) * ASSET_MAX_HP
			_push("asset_target:" + id, hp, func() -> void: (t as Object).call("set_hp", hp, ASSET_MAX_HP))


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
## markers [{pos, label, role, state, kind}], rings [PackedVector3Array], zone {label, progress, total, contested} or {},
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
	var wv: Array = director.state()["waves"]
	out["waves"] = wv[k] if k >= 0 and k < wv.size() else [0, 0]
	var marks: Array = []
	var rings: Array = []
	for m: Dictionary in rules.markers(k):
		var ty := str(m["type"])
		if ty == "sweep" or ty == "hold":
			continue   # deck-wide / the extraction waypoint
		var label := str(MARK_LABEL.get(ty, ty.to_upper()))
		if m["role"] == "bonus" and m["state"] == "known":
			label = "? " + label
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
			"countdown": ty == "hold"}
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
