extends NetTest
## Ambient life over a real 2-process crew (docs/design/ambient-life.md section 8). Before anyone joins, the host raises a
## threat and kills a civilian; the joiner gets both from the host's snapshot (life.sync). Then the host raises another
## threat (life.threat) and both machines derive the same states and positions at the same shared-clock times. Last, the
## client fires a sweep through someone: it does not decide (life.req), the host does (life.down), and both tallies agree.
## Vehicles: a threat at a pod e-stops it on both machines alike, and a client's shot through a vehicle wrecks it through
## the host (life.wreq -> life.wreck).

const PEERS := 2

var district: CityDistrict
var life: AmbientLife


func _init() -> void:
	net_timeout = 110.0


func _build() -> void:
	district = CityDistrict.new()
	district.with_rig = false
	add_child(district)
	district.build({"seed": 3, "size_x": 120.0, "size_s": 130.0, "walls": 1.0})
	life = AmbientLife.new()
	add_child(life)
	life.setup(district, 30)
	await frames(1)


func _outdoor(alive_only: bool = true) -> int:
	for id in life.count():
		if life.visible_now(id) and (not alive_only or life.state_of(id) != "down"):
			return id
	return -1


## Every person's state and position (cm) at shared-clock time t, as one string.
func _signature(t: float) -> String:
	var out := PackedStringArray()
	for id in life.count():
		var p := life.crowd.pose(id, t)
		out.append("%s@%d,%d" % [p["state"], int(round(float(p["x"]) * 100.0)), int(round(float(p["s"]) * 100.0))])
	for v in life.vehicle_count():
		var q := life.fleet.pose(v, t)
		out.append("%s@%d,%d" % [q["state"], int(round(float(q["x"]) * 100.0)), int(round(float(q["s"]) * 100.0))])
	return ",".join(out)


func run_host() -> void:
	await _build()
	if not check(await until(func() -> bool: return _outdoor() >= 0, 30.0), "someone is outdoors on the host"):
		return
	life.raise_threat(life.pose_of(_outdoor()).origin, 20.0, 2)
	var early := _outdoor()
	if check(early >= 0, "someone outdoors to kill before the join"):
		check(life.blast(life.pose_of(early).origin, 0.5, -1) >= 1, "the host kills someone before anyone joins")
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var client := int(Session.crew()[1]["peer"])
	if not check(await wait_reports("synced", 1), "the client reports the joining snapshot"):
		return
	eq(str(reported(client, "synced")), life.snapshot().hex_encode(), "the joiner restored the host's snapshot")
	# A threat after the join: both derive the same reactions.
	if not check(await until(func() -> bool: return _outdoor() >= 0, 30.0), "someone outdoors for the second threat"):
		return
	var who := _outdoor()
	life.raise_threat(life.pose_of(who).origin, 30.0, 2)
	var t_ev := float(life.sent[life.sent.size() - 1][1]["t"])
	var T := t_ev + 6.0
	command(client, "signature", {"t": T})
	if not check(await wait_reports("signature", 1) and await wait_reports("signature_late", 1), "the client reports its states after the threat"):
		return
	eq(str(reported(client, "signature")), _signature(T), "both machines put everyone in the same state and place 6 s later")
	eq(str(reported(client, "signature_late")), _signature(T + 40.0), "and 40 s later")
	# The client shoots.
	command(client, "shoot", {})
	if not check(await wait_reports("shot", 1), "the client reports its shot"):
		return
	var victim := int(reported(client, "shot"))
	if check(victim >= 0, "the client found someone to shoot"):
		check(await until(func() -> bool: return life.state_of(victim) == "down", 10.0), "the client's shot kills on the host")
		check(int(life.tally()["by_src"].get(client, 0)) >= 1, "counted against the client's pilot")
	if not check(await wait_reports("tally", 1), "the client reports its tally"):
		return
	eq(str(reported(client, "tally")), str(life.tally()), "both machines keep the same tally")
	# Vehicles: a threat at a moving one, then a client's shot through one.
	var car := -1
	if check(await until(func() -> bool:
			for v in life.vehicle_count():
				if not life.fleet.pose(v, life.now)["held"]:
					return true
			return false, 40.0), "a vehicle on its timetable on the host"):
		for v in life.vehicle_count():
			if car < 0 and not life.fleet.pose(v, life.now)["held"]:
				car = v
		life.raise_threat(life.vehicle_pose(car).origin, 20.0, 2)
		var tv := float(life.sent[life.sent.size() - 1][1]["t"]) + 3.0
		command(client, "vsig", {"t": tv})
		if check(await wait_reports("vsig", 1), "the client reports its vehicles after the threat"):
			check(life.fleet.state_of(car, tv) in ["estop", "abandoned", "fleeing", "stopped"], "the pod near the threat has stopped (%s)" % life.fleet.state_of(car, tv))
			eq(str(reported(client, "vsig")), _signature(tv), "both machines stop the same vehicles in the same places")
	command(client, "wreck", {})
	if check(await wait_reports("wrecked", 1), "the client reports its shot at a vehicle"):
		var wv := int(reported(client, "wrecked"))
		if check(wv >= 0, "the client found a vehicle to shoot"):
			check(await until(func() -> bool: return life.vehicle_state(wv) == "wreck", 10.0), "the client's shot wrecks it on the host")
	if check(await wait_reports("tally2", 1), "the client reports its tally after the wreck"):
		eq(str(reported(client, "tally2")), str(life.tally()), "both machines keep the same tally, wrecks included")
	check(await wait_done(1), "the client is done")


func run_client() -> void:
	await _build()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return int(life.tally()["dead"]) >= 1, 10.0), "the host's early kill arrives with the snapshot")
	report("synced", life.snapshot().hex_encode())
	var cmd := await wait_command(30.0)
	if str(cmd.get("cmd", "")) != "signature":
		check(false, "the host asks for a signature (%s)" % str(cmd))
		return
	check(await until(func() -> bool: return _seen >= 1, 10.0), "the threat after the join arrives")
	report("signature", _signature(float(cmd["t"])))
	report("signature_late", _signature(float(cmd["t"]) + 40.0))
	cmd = await wait_command(30.0)
	if str(cmd.get("cmd", "")) != "shoot":
		check(false, "the host asks for a shot (%s)" % str(cmd))
		return
	await until(func() -> bool: return _outdoor() >= 0, 30.0)
	var id := _outdoor()
	if id >= 0:
		var xf := life.pose_of(id)
		var up := xf.basis.y.normalized()
		var n := life.sweep(xf.origin + up - xf.basis.x * 2.0, xf.origin + up + xf.basis.x * 2.0, 0.15, Session.local_id())
		check(n >= 1, "the sweep finds the person")
		check(life.state_of(id) != "down", "a client does not decide on its own")
		check(await until(func() -> bool: return life.state_of(id) == "down", 10.0), "the person goes down when the host's event arrives")
	report("shot", id)
	await sleep(0.5)
	report("tally", str(life.tally()))
	cmd = await wait_command(60.0)
	if str(cmd.get("cmd", "")) == "vsig":
		report("vsig", _signature(float(cmd["t"])))
		cmd = await wait_command(30.0)
	if str(cmd.get("cmd", "")) != "wreck":
		check(false, "the host asks for a shot at a vehicle (%s)" % str(cmd))
		return
	var car := -1
	for v in life.vehicle_count():
		if car < 0 and life.vehicle_state(v) != "wreck":
			car = v
	if car >= 0:
		var xf := life.vehicle_pose(car)
		var up := xf.basis.y.normalized()
		var n := life.sweep(xf.origin + up - xf.basis.x * 3.0, xf.origin + up + xf.basis.x * 3.0, 0.15, Session.local_id())
		check(n >= 1, "the sweep finds the vehicle")
		check(life.vehicle_state(car) != "wreck", "a client does not wreck on its own")
		check(await until(func() -> bool: return life.vehicle_state(car) == "wreck", 10.0), "the vehicle is a wreck when the host's event arrives")
	report("wrecked", car)
	await sleep(0.5)
	report("tally2", str(life.tally()))


var _seen := 0                 ## client: life.threat events received


func _on_event(from: int, kind: String, data: Dictionary, stamp: float) -> void:
	if kind == "life.threat":
		_seen += 1
	super._on_event(from, kind, data, stamp)
