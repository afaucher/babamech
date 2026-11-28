class_name NetMission
extends Node
## The shared mission start (co-op step 1; cast's M1, modelled on cast's crew_flow.gd, cut down to a launch and a load
## barrier). Child "Mission" of the Session autoload, so it survives the scene change from the hangar to the mission.
## Game and UI code reach it as Session.mission (host_launch / params / report_built / end ...) and listen to
## Session.mission_started / mission_go / mission_ended. Events ride Session's reliable events,
## kinds "mission.*".
##
##   LAUNCH   The host's Launch: mission.launch {seed, mode, start_t, crew, friendly_fire, scale} to the crew
##            (scale = the host's crew scale, see SCALE; start_t = host_time() + LAUNCH_LEAD
##            on the shared clock; mode = what the seed builds, always MODE_STACK (the multi-deck section; the mission
##            is always the plan's objectives); crew = the roster by seat, each {peer, seat, name, head, chassis, accent,
##            loadout}; friendly_fire = the host's crew option (Session.friendly_fire; absent = true):
##            MissionScene.friendly_fire).
##            Every machine, the host included, gets mission_started(params), plays the bay alert and loads the mission
##            when the shared clock reaches start_t. The crew goes to "mission" (lobby data; joiners are refused with
##            ON_MISSION until it ends).
##   LOADING  Each machine builds the mission from params.seed + mode, holds its mech still and reports its checksum (the
##            stack's CityStack.checksum() + the plan's; report_built: the host keeps its own, a client sends
##            mission.ready {sum}). The host compares each with
##            its own: a different one is a DESYNC (printed, noted in telemetry, kept in `desyncs`), and that pilot is
##            sent out (Session.kick, reason DESYNC). A member that has not reported LOAD_TIMEOUT after start_t is sent
##            out with LOAD_SLOW. A member that leaves just stops being waited for. Right before its (blocking) build a
##            machine says mission.loading {} (report_loading), and mission.ready carries the build time {sum, ms}.
##            While a member is loading (launch until it reports, or until go on a client), the session's silence
##            watchdogs allow load_allowance() instead of CLIENT_SILENCE / HOST_SILENCE: a slow machine blocked in its
##            build is not "gone" (NetSession; docs/networking.md "Timeouts").
##   WAIT     Whenever the set of members that reported changes, the host tells the crew who is ready: mission.wait
##            {ready: [peer]} (the loading screen's crew list; ready_peers() on every machine).
##   PENDING  Every remaining member reported the host's checksum: mission.go {start_at} (START_LEAD ahead on the shared
##            clock, so every machine has it in time).
##   RUNNING  start_at reached: mission_go(elapsed) on every machine; the mechs are released.
##   STATE    The mission's progress (MissionRules.state(), W6; scripts/mission/mission_flow.gd): the host evaluates the rules and
##            sends each change as a reliable mission.state {state} to the crew (host_state); clients keep the latest
##            (`state`) and get mission_state_changed(state). mission.go carries the latest state too, so a member that
##            (re)joins the barrier late starts from it. An outcome (won / lost) is followed, END_HOLD later, by the
##            host's mission.end with the outcome's reason. Plan mode: the state also carries "dir" (PacingDirector.state():
##            waves, next, left, pace {"<deck>": [state, s in state, quiet s, reason]}, intensity {"<pilot id>": I 0..100},
##            pilot ids as strings, negative for hangar bots) and "assets" ({defend id: hp}).
##   WAVES    Plan mode: each reinforcement order of the host's PacingDirector goes out as a reliable mission.wave
##            {order: {wave, deck, source, open_at, max_units, reason: build | cap | objective | scout | patrol}} (host_wave); every machine keeps them in `waves` and a
##            client gets mission_wave(order). mission.go carries "waves": the orders whose open_at is still ahead, so a
##            member that reaches the barrier late opens the same doors at the same shared-clock time.
##   DEPOTS   Plan mode, military supply depots (docs/design/pacing-director.md §2, host-arbitrated): a pilot's machine
##            asks depot.claim {depot, n} (client_depot_claim; n = that pilot's claim counter, the same n on a re-send);
##            the host answers depot.grant {depot, peer, seq, cores_left} to the whole crew (host_depot_grant; a repeat
##            answer to a re-sent claim goes to the asker only, same seq) or depot.deny {depot, reason, n} to the asker
##            (host_depot_deny). Session.depot_claimed(from, data) fires on the host, depot_granted(grant) /
##            depot_denied(data) on clients. Nothing is kept here: the cores left ride in mission.state ("depots").
##   SCALE    The crew scale (AGENTS.md rule 8, docs/networking.md "Crew scale"): the host decides it. The launch carries the
##            start value (params.scale = MissionFlow.host_crew_scale(launch crew, hangar bots included)); every change
##            after (a member left: MissionFlow.on_member_retired) goes out as a reliable mission.scale {n, at, from,
##            reason, pilot} (host_scale), `at` on the shared clock: every machine applies n at `at`. Kept in `scales`
##            (client_scale emits Session.mission_scale(change) on clients); mission.go carries "scales" for a barrier
##            latecomer. A change whose `at` is not newer than the last one this machine has is ignored (MissionFlow).
##   END      The host leaving the mission (Esc in the test drive) sends mission.end {reason}: every client gets
##            mission_ended(reason) and goes back to the hangar; the crew is back in "lobby". A client leaving the
##            mission only leaves it on its own machine (the host's mission goes on without its mech moving).
##   DEBRIEF  (playtest R2.15a) The host's end at an outcome carries the mission's debrief: end(reason, debrief) puts it
##            in mission.end {reason, debrief} (one reliable message: the board and its stats can't arrive out of step).
##            Every machine keeps it in NetMission.last_debrief (static: it survives the scene change to the hangar,
##            where FrontEnd shows the board, DebriefStats / DebriefBoard). Solo, end(reason, debrief) just keeps it.
##            Clients never compute a stat: the host's counters are the only numbers. Shape (v1), cleaned by
##            clean_debrief: {v: 1, outcome: "won" | "lost" | "", reason, time: mission s, pilots: [{id, name, bot, left}] in
##            seat order (bots: negative ids, by name; left: true = left mid-mission, the column stays, greyed), stats:
##            {"<pilot id>": {stat key: number}} (keys: DebriefStats.STATS; unknown keys still show, as extra rows;
##            non-numbers are dropped), labels: {stat key: display text} for those extra keys}.
##
## Offline (solo) none of this runs: the hangar hands its seed + mode to the test drive itself (MissionScene.solo_launch).

const IDLE := "idle"
const LAUNCH := "launch"
const LOADING := "loading"
const PENDING := "pending"
const RUNNING := "running"

const LAUNCH_LEAD := 2.5     ## seconds of bay alert between Launch and the load, on the shared clock
const START_LEAD := 0.5      ## seconds between mission.go and the start
const LOAD_TIMEOUT := 45.0   ## host: a member that hasn't reported this long after start_t is sent out
const HOST_ENDED := "The host ended the mission"
const MODE_STACK := "stack"          ## the multi-deck mission section (CityStack): the only mode
## The crew-scale rule lives game side (MissionFlow.host_crew_scale, the only derivation of the scale): loaded when the
## host launches, not at the autoload (no game classes in the net layer's load).
const SCALE_RULE := "res://scripts/mission/mission_flow.gd"

var phase := IDLE
## {seed, mode, start_t, crew, friendly_fire} of the launched mission ({} = none).
var params: Dictionary = {}
## Shared-clock time the mission starts at (after mission.go).
var start_at := 0.0
## This machine's reported checksum (with checksum_salt).
var local_sum := ""
## Tests: appended to this machine's checksum before it is reported, to provoke a desync.
var checksum_salt := ""
## Host: every desync found at the barrier, [{peer, name, ours, theirs}].
var desyncs: Array = []
## Host: every member sent out for not loading in time, [peer].
var slow: Array = []
## The mission's progress as last decided by the host (MissionRules.state()), {} before the first decision.
var state: Dictionary = {}
## Plan mode: every wave order of this mission, in order ({wave, deck, source, open_at, max_units}).
var waves: Array = []
## Every crew-scale change of this mission (host: sent; client: heard), in order ({n, at, from, reason, pilot}).
var scales: Array = []

## The load barrier's timeout for this machine (LOAD_TIMEOUT; tests shorten it on every process).
var load_timeout := LOAD_TIMEOUT
## Host: peer -> its build time in ms (from mission.ready; the host's own under 1).
var build_ms: Dictionary = {}

## Launches on this machine since the process started (the [Flow] log tells a relaunch apart).
static var launches := 0
## The last mission's debrief (DEBRIEF above; {} = none to show). Kept across scene changes and reset(); the hangar
## clears it (clear_debrief) once the crew pressed Next or a new mission launched.
static var last_debrief: Dictionary = {}

const DEBRIEF_PILOTS := 8      ## at most this many pilots in a debrief (4 crew; room for later)
const DEBRIEF_STATS := 32      ## at most this many stats per pilot
const DEBRIEF_NAME := 24       ## pilot names and stat keys are cut to this many characters

var _sums: Dictionary = {}   ## host: peer -> reported checksum
var _judged: Dictionary = {}   ## host: peer -> true once its checksum was logged ok
var _started := false
var _busy := false
var _ready_heard: Array[int] = []   ## client: the ready set from the host's last mission.wait
var _ready_sent: Array[int] = []    ## host: the ready set last sent in mission.wait


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var s := _s()
	if s != null:
		s.event_received.connect(_on_event)
		s.roster_changed.connect(_on_roster_changed)


func _s() -> NetSession:
	return get_parent() as NetSession


## Forget the mission (the session ended).
func reset() -> void:
	phase = IDLE
	params = {}
	start_at = 0.0
	local_sum = ""
	state = {}
	waves = []
	scales = []
	_sums = {}
	_judged = {}
	build_ms = {}
	_started = false
	_ready_heard = []
	_ready_sent = []


## Members of the launched mission that have reported their build (the loading screen's ready ticks): the host knows
## from mission.ready, a client from the host's mission.wait (plus itself once it has reported). Everyone once the
## barrier has passed.
func ready_peers() -> Array[int]:
	var out: Array[int] = []
	if phase == PENDING or phase == RUNNING:
		return members()
	var s := _s()
	for p: int in members():
		if s != null and s.hosting:
			if _sums.has(p):
				out.append(p)
		elif _ready_heard.has(p) or (s != null and p == s.local_id() and local_sum != ""):
			out.append(p)
	return out


## Launched and not yet past the barrier on this machine (LAUNCH or LOADING): the crew is (or may be) building.
func loading() -> bool:
	return phase == LAUNCH or phase == LOADING


## Host: `peer` is a member of the loading mission that hasn't reported its build yet.
func waiting_for(peer: int) -> bool:
	return loading() and not _sums.has(peer) and members().has(peer)


## The silence a loading member (or, on a client, the host) is allowed: past the LOAD_SLOW kick, so the kick (with its
## reason) always comes first.
func load_allowance() -> float:
	return load_timeout + LAUNCH_LEAD + 5.0


## This machine is about to build the mission (a long, blocking step on a slow machine): tell the host (mission.loading).
func report_loading() -> void:
	var s := _s()
	if s == null or not s.online() or not loading():
		return
	_note("mission loading: build starts")
	if not s.hosting:
		s.send_event(1, "mission.loading", {})


## A mission was launched and has not ended on this machine.
func active() -> bool:
	return phase != IDLE and not params.is_empty()


## Seconds until this machine should load the launched mission (0 when it is time, or no mission).
func seconds_to_load() -> float:
	var s := _s()
	if params.is_empty() or s == null or not s.online():
		return 0.0
	return maxf(float(params.get("start_t", 0.0)) - s.host_time(), 0.0)


## Host: launch a mission on `seed_value` (built as `mode`: MODE_STACK, the only one) for the crew as it is now.
func host_launch(seed_value: int, mode: String = MODE_STACK) -> bool:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase != IDLE:
		return false
	var crew: Array = []
	for e: Dictionary in s.crew():
		crew.append(e.duplicate(true))
	reset()
	clear_debrief()
	desyncs.clear()
	slow.clear()
	params = {"seed": seed_value, "mode": clean_mode(mode), "start_t": s.host_time() + LAUNCH_LEAD, "crew": crew,
		"friendly_fire": s.friendly_fire, "scale": launch_scale(crew)}
	phase = LAUNCH
	s.set_crew_state("mission")
	s.send_event(0, "mission.launch", params)
	_note("mission launch: seed %d, %s, crew %d, scale %d, loads at %.3f" % [seed_value, params["mode"], crew.size(),
		int(params["scale"]), float(params["start_t"])])
	launches += 1
	FlowLog.say("relaunch" if launches > 1 else "launch", "#%d seed %d, %s, crew %d" % [launches, seed_value, params["mode"], crew.size()])
	s.mission_started.emit(params)
	return true


## This machine built the mission: report its checksum (the host keeps it as the reference).
func report_built(checksum: String, ms: int = 0) -> void:
	var s := _s()
	local_sum = checksum + checksum_salt
	if s == null or not s.online() or (phase != LAUNCH and phase != LOADING):
		return
	phase = LOADING
	_note("mission built in %d ms: checksum %s" % [ms, local_sum])
	if s.hosting:
		_sums[1] = local_sum
		build_ms[1] = ms
		_judge()
	else:
		s.send_event(1, "mission.ready", {"sum": local_sum, "ms": ms})


## Leave the mission. The host ends it for everyone; a client only for itself. `debrief` (the host's, or solo's, at an
## outcome: DEBRIEF above) is kept here and, from the host, rides mission.end to the crew. A client's is ignored: only
## the host's numbers count.
func end(reason: String = "", debrief: Dictionary = {}) -> void:
	var s := _s()
	var deciding := s == null or not s.online() or s.hosting
	if deciding and not debrief.is_empty():
		last_debrief = clean_debrief(debrief)
	if phase == IDLE and params.is_empty():
		return
	if s != null and s.online() and s.hosting:
		var msg := {"reason": reason if reason != "" else HOST_ENDED}
		if not debrief.is_empty():
			msg["debrief"] = last_debrief
		s.send_event(0, "mission.end", msg)
		FlowLog.say("mission_ended", reason if reason != "" else HOST_ENDED)
		_note("mission end: %s" % (reason if reason != "" else HOST_ENDED))
	if s != null:
		s.set_crew_state("lobby")
	reset()


## Host: the mission's progress changed (MissionRules.state()): keep it and send it to the crew (reliable mission.state).
func host_state(d: Dictionary) -> void:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase == IDLE:
		return
	state = d.duplicate(true)
	s.send_event(0, "mission.state", {"state": state})
	if str(state.get("outcome", "")) != "":
		_note("mission outcome: %s (%s)" % [state["outcome"], state.get("reason", "")])


## Host: a wave order (plan mode): keep it and send it to the crew (reliable mission.wave).
func host_wave(order: Dictionary) -> void:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase == IDLE:
		return
	var o := order.duplicate(true)
	waves.append(o)
	s.send_event(0, "mission.wave", {"order": o})
	_note("mission wave %s: deck %d, %s opens at %.2f, %d units, %s" % [str(o.get("wave", "")), int(o.get("deck", 0)),
		str(o.get("source", "")), float(o.get("open_at", 0.0)), int(o.get("max_units", 0)), str(o.get("reason", ""))])


## Host: the crew scale changes at `at` on the shared clock (MissionFlow.on_member_retired): keep it and send it to the
## crew (reliable mission.scale {n, at, from, reason, pilot}).
func host_scale(change: Dictionary) -> void:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase == IDLE:
		return
	var c := clean_scale(change)
	if c.is_empty():
		return
	scales.append(c)
	s.send_event(0, "mission.scale", c)
	_note("mission scale %d -> %d at %.3f (%s, pilot %d)" % [int(c["from"]), int(c["n"]), float(c["at"]), str(c["reason"]),
		int(c["pilot"])])


## The launch's crew scale: MissionFlow.host_crew_scale(the launch crew, hangar bots included). 1 when the rule can't load.
static func launch_scale(crew: Array) -> int:
	var rule := load(SCALE_RULE) as GDScript
	if rule == null:
		push_warning("[Net] the crew-scale rule did not load: scale 1")
		return 1
	return clampi(int(rule.call("host_crew_scale", crew)), 1, 4)


## A scale change as it may be believed from the wire: {n: 1..4, at: finite, from: 0..4, reason, pilot}, {} when malformed.
static func clean_scale(d: Dictionary) -> Dictionary:
	var at := float(d.get("at", NAN))
	var n := int(d.get("n", 0))
	if is_nan(at) or is_inf(at) or n < 1 or n > 4:
		return {}
	return {"n": n, "at": at, "from": clampi(int(d.get("from", 0)), 0, 4), "reason": str(d.get("reason", "")).left(24),
		"pilot": int(d.get("pilot", 0))}


func _take_scale(d: Dictionary) -> void:
	var c := clean_scale(d)
	if c.is_empty():
		return
	scales.append(c)
	_s().mission_scale.emit(c)


## Client: ask the host for a power core of depot `depot` (reliable depot.claim). The host answers it as itself (MissionDepots).
func client_depot_claim(depot: String, n: int) -> void:
	var s := _s()
	if s == null or not s.online() or s.hosting or phase == IDLE:
		return
	s.send_event(1, "depot.claim", {"depot": depot, "n": n})


## Host: a core was granted: depot.grant {depot, peer, seq, cores_left} to the crew (`to` 0) or to one member (a repeat
## answer to a re-sent claim).
func host_depot_grant(grant: Dictionary, to: int = 0) -> void:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase == IDLE:
		return
	s.send_event(to, "depot.grant", {"depot": str(grant.get("depot", "")), "peer": int(grant.get("peer", 0)),
		"seq": int(grant.get("seq", 0)), "cores_left": int(grant.get("cores_left", 0))})


## Host: a claim was refused: depot.deny {depot, reason, n} to the asker.
func host_depot_deny(peer: int, data: Dictionary) -> void:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase == IDLE or peer <= 1:
		return
	s.send_event(peer, "depot.deny", {"depot": str(data.get("depot", "")), "reason": str(data.get("reason", "")),
		"n": int(data.get("n", 0))})


func _on_depot_event(from: int, kind: String, data: Dictionary) -> void:
	var s := _s()
	if phase == IDLE:
		return
	if s.hosting:
		if kind == "depot.claim" and members().has(from):
			s.depot_claimed.emit(from, {"depot": str(data.get("depot", "")).left(48), "n": int(data.get("n", 0))})
		return
	if from != 1:
		return
	match kind:
		"depot.grant":
			s.depot_granted.emit({"depot": str(data.get("depot", "")), "peer": int(data.get("peer", 0)),
				"seq": int(data.get("seq", 0)), "cores_left": int(data.get("cores_left", 0))})
		"depot.deny":
			s.depot_denied.emit({"depot": str(data.get("depot", "")), "reason": str(data.get("reason", "")),
				"n": int(data.get("n", 0))})


## The debrief as it may be believed from the wire (DEBRIEF above): pilots with an int id and a short name, numeric
## stats only (bools / strings / nested values dropped), bounded sizes. Pilots without a stats row get an empty one.
static func clean_debrief(d: Dictionary) -> Dictionary:
	var pilots: Array = []
	var stats := {}
	var raw_stats: Dictionary = d.get("stats", {}) if d.get("stats") is Dictionary else {}
	for p: Variant in (d.get("pilots", []) if d.get("pilots") is Array else []):
		if not (p is Dictionary) or pilots.size() >= DEBRIEF_PILOTS:
			continue
		var id := int((p as Dictionary).get("id", 0))
		if id == 0 or stats.has(str(id)):
			continue
		pilots.append({"id": id, "name": str((p as Dictionary).get("name", "")).left(DEBRIEF_NAME), "bot": id < 0,
			"left": (p as Dictionary).get("left", false) is bool and bool((p as Dictionary).get("left", false))})
		var row := {}
		var src: Variant = raw_stats.get(str(id), raw_stats.get(id, {}))
		if src is Dictionary:
			for k: Variant in src:
				var v: Variant = (src as Dictionary)[k]
				if row.size() >= DEBRIEF_STATS or not (v is int or v is float):
					continue
				var f := float(v)
				if is_nan(f) or is_inf(f):
					continue
				row[str(k).left(DEBRIEF_NAME)] = v
		stats[str(id)] = row
	var labels := {}   # display text for extra stat keys ({key: text}); strings only
	var raw_labels: Dictionary = d.get("labels", {}) if d.get("labels") is Dictionary else {}
	for k: Variant in raw_labels:
		if labels.size() < DEBRIEF_STATS and raw_labels[k] is String and str(raw_labels[k]) != "":
			labels[str(k).left(DEBRIEF_NAME)] = str(raw_labels[k]).left(32)
	var t := float(d.get("time", 0.0)) if (d.get("time") is int or d.get("time") is float) else 0.0
	return {"v": 1, "outcome": str(d.get("outcome", "")).left(16), "reason": str(d.get("reason", "")).left(80),
		"time": maxf(t, 0.0) if not is_nan(t) and not is_inf(t) else 0.0, "pilots": pilots, "stats": stats, "labels": labels}


## The hangar showed the debrief (Next) or a new mission launched: nothing left to show.
static func clear_debrief() -> void:
	last_debrief = {}


## A known mission mode: the stack is the only one (anything else builds it).
static func clean_mode(_mode: String) -> String:
	return MODE_STACK


## Crew members of the launched mission still in the roster, host first.
func members() -> Array[int]:
	var out: Array[int] = []
	var s := _s()
	for e: Variant in params.get("crew", []) as Array:
		var p := int((e as Dictionary).get("peer", 0))
		if s != null and s.roster.has(p):
			out.append(p)
	return out


# --- Events ------------------------------------------------------------------------------------------

func _on_event(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if kind.begins_with("depot."):
		_on_depot_event(from, kind, data)
		return
	if not kind.begins_with("mission."):
		return
	var s := _s()
	if s.hosting:
		if kind == "mission.loading" and loading() and members().has(from):
			_note("peer %d (%s) is building the mission" % [from, _name_of(from)])
		elif kind == "mission.ready" and (phase == LAUNCH or phase == LOADING) and members().has(from):
			_sums[from] = str(data.get("sum", ""))
			build_ms[from] = int(data.get("ms", 0))
			_note("peer %d (%s) built the mission in %d ms" % [from, _name_of(from), int(build_ms[from])])
			_judge()
		return
	if from != 1:
		return
	match kind:
		"mission.launch":
			reset()
			clear_debrief()
			var crew: Array = []
			for e: Variant in data.get("crew", []) as Array:
				if e is Dictionary:
					crew.append((e as Dictionary).duplicate(true))
			params = {"seed": int(data.get("seed", 1)), "mode": clean_mode(str(data.get("mode", MODE_STACK))),
				"start_t": float(data.get("start_t", 0.0)), "crew": crew,
				"friendly_fire": bool(data.get("friendly_fire", true))}
			if data.has("scale"):   # the host's crew scale (MissionFlow.crew_scale reads it; never recomputed here)
				params["scale"] = clampi(int(data["scale"]), 1, 4)
			phase = LAUNCH
			s.set_crew_state("mission")
			_note("mission launch heard: seed %d, %s, crew %d, loads at %.3f" % [int(params["seed"]), params["mode"], crew.size(), float(params["start_t"])])
			launches += 1
			FlowLog.say("launch received", "#%d seed %d, %s, crew %d" % [launches, int(params["seed"]), params["mode"], crew.size()])
			s.mission_started.emit(params)
		"mission.go":
			if phase == LAUNCH or phase == LOADING:
				start_at = float(data.get("start_at", 0.0))
				phase = PENDING
				FlowLog.say("checksum ok", "the barrier passed, starts at %.3f" % start_at)
				_started = false
				if data.get("state") is Dictionary and not (data["state"] as Dictionary).is_empty():
					_take_state(data["state"])
				for o: Variant in data.get("waves", []) as Array:
					if o is Dictionary:
						_take_wave(o)
				for c: Variant in data.get("scales", []) as Array:
					if c is Dictionary:
						_take_scale(c)   # MissionFlow ignores one it already has (by `at`)
		"mission.scale":
			if phase != IDLE:
				_take_scale(data)
		"mission.wave":
			if phase != IDLE and data.get("order") is Dictionary:
				_take_wave(data["order"])
		"mission.state":
			if phase != IDLE and data.get("state") is Dictionary:
				_take_state(data["state"])
		"mission.end":
			if phase != IDLE:
				var why := str(data.get("reason", HOST_ENDED))
				if data.get("debrief") is Dictionary and not (data["debrief"] as Dictionary).is_empty():
					last_debrief = clean_debrief(data["debrief"])
				FlowLog.say("mission_ended", why)
				s.set_crew_state("lobby")
				reset()
				s.mission_ended.emit(why)


func _take_state(d: Dictionary) -> void:
	state = d.duplicate(true)
	if str(state.get("outcome", "")) != "":
		_note("mission outcome heard: %s (%s)" % [state["outcome"], state.get("reason", "")])
	_s().mission_state_changed.emit(state)


func _take_wave(o: Dictionary) -> void:
	var order := o.duplicate(true)
	# A duplicate is the same order (mission.go and mission.wave may both carry it): same wave, source, open_at AND hold.
	# An air door's hold extension (a dropship still in the doorway, MissionFlow.order_air_door) repeats wave "air" and
	# the open_at with a longer hold: it is NOT a duplicate (R2.24: dropped, the client's door closed ~2 s early).
	for w: Dictionary in waves:
		if str(w.get("wave", "")) == str(order.get("wave", "")) and str(w.get("source", "")) == str(order.get("source", "")) \
				and is_equal_approx(float(w.get("open_at", 0.0)), float(order.get("open_at", 0.0))) \
				and is_equal_approx(float(w.get("hold", -1.0)), float(order.get("hold", -1.0))):
			return
	waves.append(order)
	_s().mission_wave.emit(order)


func _on_roster_changed() -> void:
	var s := _s()
	if s != null and s.hosting and (phase == LAUNCH or phase == LOADING):
		_judge()


# --- Host: the barrier -------------------------------------------------------------------------------

## Compare every reported checksum with the host's own, send out the ones that differ, and send mission.go once every
## remaining member has reported.
func _judge() -> void:
	if _busy or not _sums.has(1):
		return   # the host's own checksum is the reference
	_busy = true
	var s := _s()
	var mine := str(_sums[1])
	for p: int in _sums.keys():
		if p == 1 or str(_sums[p]) == mine:
			continue
		var who := _name_of(p)
		print("[Net] DESYNC: %s built a different city (ours %s, theirs %s): sent out" % [who, mine, str(_sums[p])])
		_note("DESYNC peer %d (%s): ours %s, theirs %s" % [p, who, mine, str(_sums[p])])
		desyncs.append({"peer": p, "name": who, "ours": mine, "theirs": str(_sums[p])})
		FlowLog.say("checksum mismatch", "%s (peer %d): ours %s, theirs %s" % [who, p, mine, str(_sums[p])])
		_sums.erase(p)
		s.kick(p, NetSession.DESYNC)
	for p: int in _sums.keys():
		if not _judged.has(p) and str(_sums[p]) == mine:
			_judged[p] = true
			FlowLog.say("checksum ok", "%s (peer %d) %s" % [_name_of(p), p, mine])
	var waiting := false
	for p: int in members():
		if not _sums.has(p):
			waiting = true
	_send_wait()
	if not waiting:
		_send_go()
	_busy = false


## Host: tell the crew who has reported (mission.wait), when that set changed.
func _send_wait() -> void:
	var now := ready_peers()
	now.sort()
	if now == _ready_sent:
		return
	_ready_sent = now
	var s := _s()
	for p: int in members():
		if p != 1:
			s.send_event(p, "mission.wait", {"ready": now})


func _send_go() -> void:
	var s := _s()
	var others := members().size() > 1
	start_at = s.host_time() + (START_LEAD if others else 0.0)
	phase = PENDING
	_started = false
	for p: int in members():
		if p != 1:
			var go := {"start_at": start_at}
			if not state.is_empty():
				go["state"] = state   # a member reaching the barrier late starts from the latest progress
			var ahead: Array = []
			for w: Dictionary in waves:
				if float(w.get("open_at", 0.0)) > s.host_time():
					ahead.append(w)
			if not ahead.is_empty():
				go["waves"] = ahead   # ... and opens the doors still to open at the same time
			if not scales.is_empty():
				go["scales"] = scales   # ... and plays at the crew scale in force (changes decided during the load)
			s.send_event(p, "mission.go", go)
	_note("mission go: %d at the barrier, starts at %.3f" % [members().size(), start_at])


func _name_of(peer: int) -> String:
	for e: Variant in params.get("crew", []) as Array:
		if int((e as Dictionary).get("peer", 0)) == peer:
			return str((e as Dictionary).get("name", peer))
	return str(peer)


func _note(text: String) -> void:
	var s := _s()
	print("[Net] ", text)
	if s != null and s.telemetry != null:
		s.telemetry.note(s.host_time(), text)


# --- Every frame -------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var s := _s()
	if s == null or not s.online() or phase == IDLE:
		return
	if s.hosting and (phase == LAUNCH or phase == LOADING) and _sums.has(1) \
			and s.host_time() > float(params.get("start_t", 0.0)) + load_timeout:
		for p: int in members():
			if p != 1 and not _sums.has(p) and not slow.has(p):
				slow.append(p)
				_note("peer %d (%s) didn't load in %.0f s: sent out (%s)" % [p, _name_of(p), load_timeout, NetSession.LOAD_SLOW])
				s.kick(p, NetSession.LOAD_SLOW)
		_judge()
	if phase == PENDING and not _started and s.host_time() >= start_at:
		_started = true
		phase = RUNNING
		FlowLog.say("mission_go", "crew %d" % members().size())
		s.mission_go.emit(s.host_time() - start_at)
