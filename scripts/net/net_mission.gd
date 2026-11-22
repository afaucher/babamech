class_name NetMission
extends Node
## The shared mission start (co-op step 1; cast's M1, modelled on cast's crew_flow.gd, cut down to a launch and a load
## barrier). Child "Mission" of the Session autoload, so it survives the scene change from the hangar to the mission.
## Game and UI code never call this directly: they use Session.start_mission / mission_params / report_mission_built /
## end_mission and listen to Session.mission_started / mission_go / mission_ended. Events ride Session's reliable events,
## kinds "mission.*".
##
##   LAUNCH   The host's Launch: mission.launch {seed, start_t, crew} to the crew (start_t = host_time() + LAUNCH_LEAD on
##            the shared clock; crew = the roster by seat, each {peer, seat, name, head, chassis, accent, loadout}).
##            Every machine, the host included, gets mission_started(params), plays the bay alert and loads the mission
##            when the shared clock reaches start_t. The crew goes to "mission" (lobby data; joiners are refused with
##            ON_MISSION until it ends).
##   LOADING  Each machine builds the mission from params.seed, holds its mech still and reports its city checksum
##            (report_built: the host keeps its own, a client sends mission.ready {sum}). The host compares each with
##            its own: a different one is a DESYNC (printed, noted in telemetry, kept in `desyncs`), and that pilot is
##            sent out (Session.kick, reason DESYNC). A member that has not reported LOAD_TIMEOUT after start_t is sent
##            out with LOAD_SLOW. A member that leaves just stops being waited for.
##   PENDING  Every remaining member reported the host's checksum: mission.go {start_at} (START_LEAD ahead on the shared
##            clock, so every machine has it in time).
##   RUNNING  start_at reached: mission_go(elapsed) on every machine; the mechs are released.
##   END      The host leaving the mission (Esc in the test drive) sends mission.end {reason}: every client gets
##            mission_ended(reason) and goes back to the hangar; the crew is back in "lobby". A client leaving the
##            mission only leaves it on its own machine (the host's mission goes on without its mech moving).
##
## Offline (solo) none of this runs: the hangar loads the test drive itself, which takes its seed from --seed.

const IDLE := "idle"
const LAUNCH := "launch"
const LOADING := "loading"
const PENDING := "pending"
const RUNNING := "running"

const LAUNCH_LEAD := 2.5     ## seconds of bay alert between Launch and the load, on the shared clock
const START_LEAD := 0.5      ## seconds between mission.go and the start
const LOAD_TIMEOUT := 45.0   ## host: a member that hasn't reported this long after start_t is sent out
const HOST_ENDED := "The host ended the mission"

var phase := IDLE
## {seed, start_t, crew} of the launched mission ({} = none).
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

var _sums: Dictionary = {}   ## host: peer -> reported checksum
var _started := false
var _busy := false


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
	_sums = {}
	_started = false


## A mission was launched and has not ended on this machine.
func active() -> bool:
	return phase != IDLE and not params.is_empty()


## Seconds until this machine should load the launched mission (0 when it is time, or no mission).
func seconds_to_load() -> float:
	var s := _s()
	if params.is_empty() or s == null or not s.online():
		return 0.0
	return maxf(float(params.get("start_t", 0.0)) - s.host_time(), 0.0)


## Host: launch a mission on `seed_value` for the crew as it is now.
func host_launch(seed_value: int) -> bool:
	var s := _s()
	if s == null or not s.online() or not s.hosting or phase != IDLE:
		return false
	var crew: Array = []
	for e: Dictionary in s.crew():
		crew.append(e.duplicate(true))
	reset()
	desyncs.clear()
	slow.clear()
	params = {"seed": seed_value, "start_t": s.host_time() + LAUNCH_LEAD, "crew": crew}
	phase = LAUNCH
	s.set_crew_state("mission")
	s.send_event(0, "mission.launch", params)
	_note("mission launch: seed %d, crew %d, loads at %.3f" % [seed_value, crew.size(), float(params["start_t"])])
	s.mission_started.emit(params)
	return true


## This machine built the mission: report its checksum (the host keeps it as the reference).
func report_built(checksum: String) -> void:
	var s := _s()
	local_sum = checksum + checksum_salt
	if s == null or not s.online() or (phase != LAUNCH and phase != LOADING):
		return
	phase = LOADING
	_note("mission built: checksum %s" % local_sum)
	if s.hosting:
		_sums[1] = local_sum
		_judge()
	else:
		s.send_event(1, "mission.ready", {"sum": local_sum})


## Leave the mission. The host ends it for everyone; a client only for itself.
func end(reason: String = "") -> void:
	if phase == IDLE and params.is_empty():
		return
	var s := _s()
	if s != null and s.online() and s.hosting:
		s.send_event(0, "mission.end", {"reason": reason if reason != "" else HOST_ENDED})
		_note("mission end: %s" % (reason if reason != "" else HOST_ENDED))
	if s != null:
		s.set_crew_state("lobby")
	reset()


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
	if not kind.begins_with("mission."):
		return
	var s := _s()
	if s.hosting:
		if kind == "mission.ready" and (phase == LAUNCH or phase == LOADING) and members().has(from):
			_sums[from] = str(data.get("sum", ""))
			_judge()
		return
	if from != 1:
		return
	match kind:
		"mission.launch":
			reset()
			var crew: Array = []
			for e: Variant in data.get("crew", []) as Array:
				if e is Dictionary:
					crew.append((e as Dictionary).duplicate(true))
			params = {"seed": int(data.get("seed", 1)), "start_t": float(data.get("start_t", 0.0)), "crew": crew}
			phase = LAUNCH
			s.set_crew_state("mission")
			_note("mission launch heard: seed %d, crew %d, loads at %.3f" % [int(params["seed"]), crew.size(), float(params["start_t"])])
			s.mission_started.emit(params)
		"mission.go":
			if phase == LAUNCH or phase == LOADING:
				start_at = float(data.get("start_at", 0.0))
				phase = PENDING
				_started = false
		"mission.end":
			if phase != IDLE:
				var why := str(data.get("reason", HOST_ENDED))
				s.set_crew_state("lobby")
				reset()
				s.mission_ended.emit(why)


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
		_sums.erase(p)
		s.kick(p, NetSession.DESYNC)
	var waiting := false
	for p: int in members():
		if not _sums.has(p):
			waiting = true
	if not waiting:
		_send_go()
	_busy = false


func _send_go() -> void:
	var s := _s()
	var others := members().size() > 1
	start_at = s.host_time() + (START_LEAD if others else 0.0)
	phase = PENDING
	_started = false
	for p: int in members():
		if p != 1:
			s.send_event(p, "mission.go", {"start_at": start_at})
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
			and s.host_time() > float(params.get("start_t", 0.0)) + LOAD_TIMEOUT:
		for p: int in members():
			if p != 1 and not _sums.has(p) and not slow.has(p):
				slow.append(p)
				_note("peer %d (%s) didn't load in time: sent out" % [p, _name_of(p)])
				s.kick(p, NetSession.LOAD_SLOW)
		_judge()
	if phase == PENDING and not _started and s.host_time() >= start_at:
		_started = true
		phase = RUNNING
		s.mission_go.emit(s.host_time() - start_at)
