extends NetTest
## Drop-ship sync (playtest R2.24) over a crew of 2 (host + c1), once per link (off, coast). The dropship is a
## HOST-OWNED ENEMY (EnemyDropDrone, AI on the host only): EnemySync's "add" brings its puppet to the client, the enemy
## stream poses it (position, ring-frame yaw, AI state, bay / pitch as its aim), "tele" shows its drop telegraph on the
## shared clock, its troopers are "add"ed as they leave the bay and "gone" removes it once it is back in an air door's
## recess. Its air doors are scheduled effects (MissionFlow.order_air_door -> mission.wave "air").
## Real plan-mode mission (MissionWorld builds the air doors; QUIET_SECTION has none, so it would only test the in-deck
## fallback), the director held off; the garrison idle. The host calls a dropship on the entry deck (EnemySquad
## .request_dropship, as a scout's beacon does), then checks
## 1. it comes out through an air door (not the in-deck fallback), and the client shows it in every phase (recess,
##    out, approach, descent, telegraph, exfil, back in), within POSE_TOL of the host's streamed path at its render time;
## 2. the same troopers (ids, count) appear on the client, first seen under the client's own dropship puppet (never in
##    the open with no source), and they stand where the host's do afterwards;
## 3. LATE STATE: mid-exfil c1 drops every puppet and asks for the manifest again (what a client loading late gets):
##    the dropship and its troopers come back where the host has them, and the flight continues;
## 4. after it is removed on the host it is gone on the client too (no ghost ship), and every air door went through the
##    same states at the same shared-clock times on both machines (and is shut again).

const PEERS := 2
const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}
## No director pressure (no rests ending, no quiet cap, no scout call-ins, no patrols): only our dropship flies.
const DIRECTOR := {"rest_first": 100000.0, "rest_last": 100000.0, "arrival_rest": 100000.0, "quiet_cap": 100000.0,
	"scout_every": 100000.0, "call_every": 100000.0, "patrols": 0}
const FLIGHT_LIMIT := 150.0       ## s of mission time for the whole round trip
## m the client's shown dropship may be off the host's streamed path at the same (render) time.
const POSE_TOL := {"off": 1.0, "coast": 2.0}
const TROOP_TOL := 3.5            ## m: a trooper's puppet vs the host's trooper (they run; the puppet renders 0.1-0.4 s behind)
const BAY_TOL := 7.0              ## m: a trooper's first spot on the client vs its own dropship puppet (bay 2.5 m under it)
const DOOR_TOL := 0.25            ## s: the same door state change on both machines (scheduled on the shared clock)
const LATE_TOL := 3.0             ## m: 0.5 s after the re-sent manifest (a fresh buffer)

var td: MissionScene
var sync: EnemySync
var ds_n := -1
var ship_log: Array = []          ## client: [render t, shown pos] of the dropship puppet, 10 Hz
var host_trace: Array = []        ## host: [t, pos] streamed for the dropship
var phases: Array = []            ## host: [t, phase]
var doors: Array = []             ## [t, id, state] air door state changes on this machine
var door_ids: Array = []
var _door_last := {}
var first_seen := {}              ## client: target id -> [t, pos, ship puppet pos or null]
var _frame := 0
var tele_seen := false            ## client: the dropship's drop telegraph arrived


func run_host() -> void:
	net_timeout = 260.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	var sq := td.combat.squad
	for e in sq.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 40.0), "the client has the enemy manifest"):
		return
	var c1 := _peer_named("c1")
	var deck := int(td.stack.section.entry["deck"])
	# At the avenue entry (where the crew stood before it started in the entry bay, behind the end wall: a drop there
	# lands on the wall and cuts the exfil short).
	var ds := sq.request_dropship(td.stack.entry_transform().origin, deck)
	if not check(ds != null, "the host calls a dropship on the entry deck %d" % deck):
		_finish_all()
		return
	ds_n = ds.net_id
	var air_in: Dictionary = ds.get("_air_in")
	check(not air_in.is_empty(), "it arrives through an air door (not the in-deck fallback)")
	print("[dropship] %s n %d, deck %d, door %s" % [ds.target_id, ds_n, deck, str(air_in.get("id", "-"))])
	var deployed: Array = []
	ds.troops_deployed.connect(func(_d: EnemyDropDrone, list: Array) -> void:
		for tr: EnemyBase in list:
			deployed.append([tr.target_id, Session.host_time(), tr.global_position]))
	command(c1, "track", {"n": ds_n})
	var t0 := Session.host_time()
	var late_sent := false
	var last_phase := ""
	var late_host := {}
	var ship_gone := false
	while Session.host_time() - t0 < FLIGHT_LIMIT:
		await get_tree().physics_frame
		if not is_instance_valid(ds) or ds.is_queued_for_deletion():
			ship_gone = true
			break
		_trace(ds)
		var ph := str(ds.get("_drop_phase"))
		if ph != last_phase:
			phases.append([Session.host_time(), ph])
			print("[dropship] %.2f s: %s" % [Session.host_time() - t0, ph])
			last_phase = ph
		if not late_sent and ph == EnemyDropDrone.PHASE_EXFIL and Session.host_time() - float(phases.back()[0]) > 3.0:
			late_sent = true
			command(c1, "relearn", {})
	phases.append([Session.host_time(), "gone"])
	if not check(ship_gone, "the dropship finished its round trip within %.0f s (last phase %s)" % [FLIGHT_LIMIT, last_phase]):
		_finish_all()
		return
	var seen := []
	for p: Array in phases:
		seen.append(str(p[1]))
	for want: String in [EnemyDropDrone.PHASE_DOOR_OUT, EnemyDropDrone.PHASE_APPROACH, EnemyDropDrone.PHASE_DESCEND,
			EnemyDropDrone.PHASE_TELEGRAPH, EnemyDropDrone.PHASE_EXFIL, EnemyDropDrone.PHASE_DOOR_IN]:
		check(want in seen, "the host's ship went through %s" % want)
	check(late_sent, "the late-state step ran mid-exfil")
	# The doors shut again (the last hold + closing), then compare.
	await until(func() -> bool:
		for id: String in door_ids:
			if str(_door_state(id)) != "shut":
				return false
		return true, 20.0)
	await sleep(1.0)
	var r := await _ask(c1, "final")
	_compare(r, deployed, sq)
	_finish_all()


func _compare(r: Dictionary, deployed: Array, sq: EnemySquad) -> void:
	var tol := float(POSE_TOL.get(link, 2.0))
	# 1. The ship in every phase.
	var log: Array = r["ship"]
	check(log.size() > 50, "c1 showed the dropship (%d samples)" % log.size())
	var worst := {}
	var count := {}
	for it: Array in log:
		var t := float(it[0])
		if t < float(host_trace[0][0]) or t > float(host_trace.back()[0]):
			continue
		var ph := _phase_at(t)
		var d := (it[1] as Vector3).distance_to(_trace_at(t))
		worst[ph] = maxf(float(worst.get(ph, 0.0)), d)
		count[ph] = int(count.get(ph, 0)) + 1
	print("[dropship] c1 worst error per phase (m): %s, samples %s" % [str(worst), str(count)])
	for ph: String in [EnemyDropDrone.PHASE_DOOR_OUT, EnemyDropDrone.PHASE_APPROACH, EnemyDropDrone.PHASE_DESCEND,
			EnemyDropDrone.PHASE_TELEGRAPH, EnemyDropDrone.PHASE_EXFIL, EnemyDropDrone.PHASE_DOOR_IN]:
		check(int(count.get(ph, 0)) > 0, "c1 showed the dropship during %s" % ph)
		check(float(worst.get(ph, 0.0)) <= tol, "c1's dropship follows the host's during %s (worst %.2f m, tol %.1f)" % [ph,
			float(worst.get(ph, 0.0)), tol])
	check(bool(r["tele_seen"]), "c1 got the drop telegraph on the ship")
	# 2. The troopers.
	check(deployed.size() >= 3, "the host's ship dropped a fireteam (%d)" % deployed.size())
	var fs: Dictionary = r["first_seen"]
	var now_pos: Dictionary = r["troops"]
	var drop_ids: Array = []
	for d: Array in deployed:
		drop_ids.append(str(d[0]))
	var client_drop: Array = []
	for id: String in fs:
		if "_drop_" in id:
			client_drop.append(id)
	drop_ids.sort()
	client_drop.sort()
	eq(str(client_drop), str(drop_ids), "c1 shows the same troopers the host's ship dropped")
	for d: Array in deployed:
		var id := str(d[0])
		var f: Variant = fs.get(id)
		if not (f is Array):
			continue
		var fa := f as Array
		check((fa[1] as Vector3).distance_to(d[2] as Vector3) <= TROOP_TOL,
			"%s first appears on c1 where the host spawned it (%.2f m)" % [id, (fa[1] as Vector3).distance_to(d[2] as Vector3)])
		check(fa[2] is Vector3 and (fa[1] as Vector3).distance_to(fa[2] as Vector3) <= BAY_TOL,
			"%s appears under c1's own dropship puppet (%s)" % [id, "%.2f m" % (fa[1] as Vector3).distance_to(fa[2] as Vector3) if fa[2] is Vector3 else "no ship"])
		check(absf(float(fa[0]) - float(d[1])) < 1.0, "%s appears on c1 within 1 s of the drop (%.2f s)" % [id, float(fa[0]) - float(d[1])])
	var far := 0.0
	var alive_host := 0
	for e in sq.enemies:
		if is_instance_valid(e) and "_drop_" in e.target_id and now_pos.has(e.target_id):
			alive_host += 1
			far = maxf(far, (now_pos[e.target_id] as Vector3).distance_to(e.global_position))
	check(alive_host >= 1, "the landed troopers are on both machines (%d)" % alive_host)
	check(far <= TROOP_TOL, "the landed troopers stand where the host's do (worst %.2f m)" % far)
	# 3. Late state.
	var late: Dictionary = r["late"]
	check(bool(late.get("ok", false)), "after the re-sent manifest c1 has the dropship again (%s)" % str(late))
	if late.has("t"):
		var off := (late["pos"] as Vector3).distance_to(_trace_at(float(late["t"])))
		check(off <= LATE_TOL, "the late manifest puts the ship where the host has it (%.2f m)" % off)
		eq(int(late.get("troops", -1)), deployed.size(), "the late manifest brings the same troopers")
	# 4. Gone, doors.
	check(not bool(r["ship_left"]), "the dropship is gone on c1 too (no ghost ship)")
	eq(int(r["dropships"]), 0, "c1 has no dropship node left")
	for id: String in door_ids:
		var mine := _door_seq(doors, id)
		var theirs := _door_seq(r["doors"], id)
		print("[dropship] door %s host %s" % [id, str(mine)])
		print("[dropship] door %s c1   %s" % [id, str(theirs)])
		eq(str(_states(theirs)), str(_states(mine)), "air door %s went through the same states on c1" % id)
		if _states(theirs) == _states(mine):
			var dt := 0.0
			for i in mine.size():
				dt = maxf(dt, absf(float(mine[i][0]) - float(theirs[i][0])))
			check(dt <= DOOR_TOL, "air door %s changed state at the same shared-clock times (worst %.3f s)" % [id, dt])
		eq(str(_door_state(id)), "shut", "air door %s is shut again on the host" % id)
	check(not door_ids.is_empty(), "the deck has air doors")


func run_client() -> void:
	net_timeout = 260.0
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	if not check(await until(func() -> bool: return sync.has_manifest and td.combat.squad.enemies.size() > 0, 15.0),
			"the enemy manifest arrives"):
		return
	report("ready", {})
	sync.telegraph_received.connect(func(e: EnemyBase, _t0: float, _d: float, _a: float) -> void:
		if e.net_id == ds_n:
			tele_seen = true)
	var late := {}
	while true:
		var c := await wait_command(180.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"track":
				ds_n = int(c["n"])
			"relearn":
				late = await _relearn()
			"report":
				var troops := {}
				var ships := 0
				for e in td.combat.squad.enemies:
					if not is_instance_valid(e):
						continue
					if "_drop_" in e.target_id:
						troops[e.target_id] = e.global_position
					if e.enemy_type == "dropship":
						ships += 1
				for n: Node in td.combat.squad.get_children():
					if n is EnemyDropDrone and not n.is_queued_for_deletion() and not (n in td.combat.squad.enemies):
						ships += 1
				report(str(c["key"]), {"ship": ship_log, "first_seen": first_seen, "troops": troops, "late": late,
					"ship_left": sync.by_net.has(ds_n), "dropships": ships, "doors": doors, "tele_seen": tele_seen})


## TEST-ONLY late state: drop every puppet and ask the host for the manifest again (what a client loading while the ship
## is mid-drop gets), then report where the ship came back.
func _relearn() -> Dictionary:
	var before := 0
	for n: int in sync.by_net.keys():
		sync.call("_remove_puppet", n)
		before += 1
	sync.has_manifest = false
	sync.set("_next_req", 0.0)
	var keep := first_seen.duplicate()
	if not await until(func() -> bool: return sync.has_manifest, 6.0):
		return {"ok": false, "why": "no manifest"}
	first_seen = keep   # the troopers' first appearance is the drop, not this re-send
	var ship := sync.by_net.get(ds_n) as EnemyBase
	if ship == null or not is_instance_valid(ship):
		return {"ok": false, "why": "no ship in the manifest", "removed": before}
	var troops := 0
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and "_drop_" in e.target_id:
			troops += 1
	await sleep(0.5)   # the stream takes over again
	var st := Session.enemies.pose(ds_n) if Session.enemies != null else null
	if st == null or not is_instance_valid(ship):
		return {"ok": false, "why": "no stream after the manifest", "troops": troops}
	return {"ok": true, "t": st.t, "pos": ship.global_position, "troops": troops}


# --- Shared ----------------------------------------------------------------------------------------------

func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.enemy_sync != null and td.mission != null and td.mission.director != null,
			"the crew mission runs in plan mode with EnemySync"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.player_target.auto_respawn_delay = -1.0
	sync = td.enemy_sync
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	var mw := td.stack.mission
	if mw != null:
		var deck := int(td.stack.section.entry["deck"])
		for i in mw.air_door_count(deck):
			var d: Dictionary = mw.air_door(deck, i)
			if bool(d.get("ok", false)):
				door_ids.append(str(d["id"]))
	return true


func _physics_process(_delta: float) -> void:
	if td == null or not is_instance_valid(td) or sync == null:
		return
	var now := Session.host_time()
	for id: String in door_ids:
		var st := str(_door_state(id))
		if st != str(_door_last.get(id, "")):
			_door_last[id] = st
			doors.append([now, id, st])
	if is_host() or ds_n < 0:
		return
	_frame += 1
	var ship := sync.by_net.get(ds_n) as EnemyBase
	var ship_pos: Variant = ship.global_position if ship != null and is_instance_valid(ship) else null
	for n: int in sync.by_net:
		var e := sync.by_net[n] as EnemyBase
		if is_instance_valid(e) and "_drop_" in e.target_id and not first_seen.has(e.target_id):
			first_seen[e.target_id] = [now, e.global_position, ship_pos]
	if _frame % 6 == 0 and ship != null and is_instance_valid(ship) and Session.enemies != null:
		var st := Session.enemies.pose(ds_n)
		if st != null:
			ship_log.append([st.t, ship.global_position])


func _door_state(id: String) -> String:
	var mw := td.stack.mission if td != null and td.stack != null else null
	return str((mw.source_state(id) as Dictionary).get("state", "")) if mw != null else ""


## Door `id`'s state changes, leaving out the idle "shut" before its first order.
static func _door_seq(list: Array, id: String) -> Array:
	var out: Array = []
	for it: Array in list:
		if str(it[1]) == id and not (out.is_empty() and str(it[2]) in ["shut", ""]):
			out.append(it)
	return out


static func _states(seq: Array) -> Array:
	var out: Array = []
	for it: Array in seq:
		out.append(str(it[2]))
	return out


func _trace(e: EnemyBase) -> void:
	var st := (sync.get("_last_sent") as Dictionary).get(e.net_id) as NetEnemyState
	if st != null and (host_trace.is_empty() or float(host_trace.back()[0]) < st.t):
		host_trace.append([st.t, st.pos])


func _trace_at(t: float) -> Vector3:
	for i in range(host_trace.size() - 1):
		var a: Array = host_trace[i]
		var b: Array = host_trace[i + 1]
		if t >= float(a[0]) and t <= float(b[0]):
			var u := (t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4)
			return (a[1] as Vector3).lerp(b[1] as Vector3, u)
	return host_trace.back()[1]


func _phase_at(t: float) -> String:
	var ph := ""
	for p: Array in phases:
		if float(p[0]) <= t:
			ph = str(p[1])
	return ph


func _ask(peer: int, key: String) -> Dictionary:
	command(peer, "report", {"key": key})
	if not await wait_reports(key, 1, 20.0):
		return {}
	return reported(peer, key)


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
