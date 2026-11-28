extends NetTest
## A wave door held open while someone is still in its bay (playtest R2.4; MissionFlow.hold_door, MissionBays) over a crew
## of 2 (host + c1), once per link. Holds go out as replicated "hold" orders (mission.wave, hold_only) with the door's own
## open_at and a growing hold: before NetMission deduped on wave + source + open_at + hold (R2.24, Engine) a client dropped
## such re-sends silently and its door closed early. Checks: the host orders a gate on the entry deck, then extends its hold
## three times past the normal close; c1's door goes through the same states at the same shared-clock times (open as long
## as the host's), and a follow-up order whose open_at falls just after the close never snaps the leaves shut in between
## (MissionFlow._no_snap) on either machine. Then (MissionBays rule 5, crew never shut in) c1 parks its mech inside the
## same bay while the door is open: the host (which sees c1 only as a puppet) holds the door past its normal close on
## every machine, and once c1 walks out it shuts on both.

const PEERS := 2
const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}
const DIRECTOR := {"rest_first": 100000.0, "rest_last": 100000.0, "arrival_rest": 100000.0, "quiet_cap": 100000.0,
	"scout_every": 100000.0, "call_every": 100000.0, "patrols": 0}
const DOOR_TOL := 0.25            ## s: the same door state change on both machines
const HOLDS := 3                  ## hold extensions past the normal close
const HOLD_STEP := 4.0            ## s each extension adds
const CREW_PAST := 10.0           ## s past the normal close the door must still be open with c1 inside

var td: MissionScene
var door_id := ""
var doors: Array = []             ## [t, state] of door_id on this machine
var _last := ""
var _park: Variant = null         ## c1: where its mech is held (inside the bay), null when free


func run_host() -> void:
	net_timeout = 200.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	var c1 := _peer_named("c1")
	command(c1, "door", {"id": door_id})
	if not check(door_id != "", "the entry deck has a gate with a door"):
		_finish_all()
		return
	var mf := td.mission
	var deck := int(td.stack.section.entry["deck"])
	var t0 := Session.host_time()
	var o := {"wave": "hold_test", "deck": deck, "source": door_id, "open_at": t0 + 2.0, "max_units": 0, "reason": "test"}
	Session.mission.host_wave(o)
	mf._open(o)
	var st := td.stack.mission.source_state(door_id)
	var close0 := float(st["close_at"])
	# Hold it past its normal close three times (what MissionBays does while a unit is still in the bay).
	for i in HOLDS:
		await until(func() -> bool: return Session.host_time() >= close0 - 1.0 + HOLD_STEP * float(i), 40.0)
		mf.hold_door(door_id, close0 + HOLD_STEP * float(i + 1))
	var held_to := float(td.stack.mission.source_state(door_id)["close_at"])
	check(held_to >= close0 + HOLD_STEP * HOLDS - 0.01, "the host's door is held to %.1f (normal close %.1f)" % [held_to, close0])
	# A follow-up order whose open_at falls 1 s after the (held) close: extended, never re-scheduled into "warn".
	await until(func() -> bool: return Session.host_time() >= held_to - 2.0, 30.0)
	var o2 := {"wave": "hold_test2", "deck": deck, "source": door_id, "open_at": held_to + 1.0, "max_units": 0, "reason": "test"}
	Session.mission.host_wave(o2)
	mf._open(o2)
	var end_t := float(td.stack.mission.source_state(door_id)["close_at"]) + MissionWorld.CLOSE + 1.0
	await until(func() -> bool: return Session.host_time() >= end_t, 60.0)
	await sleep(0.5)
	command(c1, "report", {"key": "final"})
	if not await wait_reports("final", 1, 20.0):
		_finish_all()
		return
	var theirs: Array = reported(c1, "final")["doors"]
	var mine := _seq(doors)
	var other := _seq(theirs)
	print("[bay hold] host %s" % str(mine))
	print("[bay hold] c1   %s" % str(other))
	eq(str(_states(other)), str(_states(mine)), "c1's door went through the same states as the host's")
	check(not ("warn" in _states(mine).slice(1)), "the follow-up never snapped the open door shut (host: %s)" % str(_states(mine)))
	if _states(other) == _states(mine):
		var worst := 0.0
		for i in mine.size():
			worst = maxf(worst, absf(float(mine[i][0]) - float(other[i][0])))
		check(worst <= DOOR_TOL, "c1's door changed state at the host's shared-clock times (worst %.3f s): open as long" % worst)
	await _crew_case(c1, deck)
	_finish_all()


## Rule 5 over the wire: c1's mech inside the open bay holds the door past its close on both machines; out, it shuts.
func _crew_case(c1: int, deck: int) -> void:
	var mw := td.stack.mission
	var mf := td.mission
	var t1 := Session.host_time()
	var o3 := {"wave": "hold_crew", "deck": deck, "source": door_id, "open_at": t1 + 2.0, "max_units": 0, "reason": "test"}
	Session.mission.host_wave(o3)
	mf._open(o3)
	var normal := float(mw.source_state(door_id)["close_at"])
	await until(func() -> bool: return bool(mw.source_state(door_id).get("passable", false)), 20.0)
	command(c1, "enter", {})
	var seen: bool = await until(func() -> bool: return mf.bays.crew_inside(door_id), 10.0)
	check(seen, "the host sees c1's mech (a puppet) inside the bay")
	await until(func() -> bool: return Session.host_time() >= normal + CREW_PAST, 60.0)
	var host_st := str(mw.source_state(door_id)["state"])
	command(c1, "report", {"key": "crew_in"})
	var ok: bool = await wait_reports("crew_in", 1, 20.0)
	eq(host_st, "open", "the host's door is still open %.0f s past its close with c1 inside" % CREW_PAST)
	if ok:
		eq(str(reported(c1, "crew_in")["state"]), "open", "c1's door is still open too (the hold reached it)")
	command(c1, "leave", {})
	var shut: bool = await until(func() -> bool: return str(mw.source_state(door_id)["state"]) == "shut", 40.0)
	check(shut, "with c1 out the door shuts")
	await sleep(1.0)
	command(c1, "report", {"key": "crew_out"})
	if await wait_reports("crew_out", 1, 20.0):
		eq(str(reported(c1, "crew_out")["state"]), "shut", "and shuts on c1 too")


func run_client() -> void:
	net_timeout = 200.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	while true:
		var c := await wait_command(150.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"door":
				door_id = str(c["id"])
			"report":
				report(str(c["key"]), {"doors": doors, "state": str(td.stack.mission.source_state(door_id).get("state", ""))})
			"enter":
				var sl := td.stack.mission.bay_slots(door_id, 1)
				_park = sl[0].origin if not sl.is_empty() else null
			"leave":
				_park = null
				var b := td.stack.mission.source_bay(door_id)
				if b.get("exit") is Vector3:
					td.mech.global_position = (b["exit"] as Vector3) + (b["facing"] as Vector3) * 30.0 + td.mech.global_transform.basis.y * 0.5


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.mission != null and td.mission.director != null, "the crew mission runs in plan mode"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.player_target.auto_respawn_delay = -1.0
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	if is_host():
		var deck := int(td.stack.section.entry["deck"])
		for s: Dictionary in td.mission.plan.deck_sources(deck):
			if str(s["kind"]) == "gate" and bool(td.stack.mission.source_bay(str(s["id"])).get("ok", false)):
				door_id = str(s["id"])
				break
		if door_id == "":   # no gate bay on the entry deck: any gate of the mission
			for s: Dictionary in td.mission.plan.sources:
				if str(s["kind"]) == "gate" and bool(td.stack.mission.source_bay(str(s["id"])).get("ok", false)):
					door_id = str(s["id"])
					break
	return true


func _physics_process(_delta: float) -> void:
	if td == null or not is_instance_valid(td) or door_id == "" or td.stack == null or td.stack.mission == null:
		return
	if _park is Vector3 and td.mech != null:
		td.mech.global_position = _park
		td.mech.velocity = Vector3.ZERO
	var st := str(td.stack.mission.source_state(door_id).get("state", ""))
	if st != _last:
		_last = st
		doors.append([Session.host_time(), st])


## State changes from the first non-"shut" one.
static func _seq(list: Array) -> Array:
	var out: Array = []
	for it: Array in list:
		if out.is_empty() and str(it[1]) in ["shut", ""]:
			continue
		out.append(it)
	return out


static func _states(seq: Array) -> Array:
	var out: Array = []
	for it: Array in seq:
		out.append(str(it[1]))
	return out


func _finish_all() -> void:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != 1:
			command(int(e["peer"]), "finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func _peer_named(n: String) -> int:
	for e: Dictionary in Session.crew():
		if str(e["name"]) == n:
			return int(e["peer"])
	return -1
