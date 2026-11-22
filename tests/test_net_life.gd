extends NetTest
## Ambient life over a real 2-process crew (docs/design/ambient-life.md section 8). Before anyone joins, the host raises a
## threat and kills a civilian; the joiner gets both from the host's snapshot (life.sync). Then the host raises another
## threat (life.threat) and both machines derive the same states and positions at the same shared-clock times. Last, the
## client fires a sweep through someone: it does not decide (life.req), the host does (life.down), and both tallies agree.
## Vehicles: a threat at a pod e-stops it on both machines alike, and a client's shot through a vehicle wrecks it through
## the host (life.wreq -> life.wreck).
## Stack (phase 3): both machines then swap the district for the same 3-deck CityStack with one AmbientLife (setup_stack).
## Late join: the host kills someone on deck 2 and wrecks a vehicle on deck 0 before the client has its life, then the
## join handler sends the whole stack's snapshot (life.sync); the client restores both. A threat on deck 1 ("deck": 1 on
## the wire): both machines agree on every deck and nobody on deck 0 at the same arc spot reacts. The client's sweep
## kills someone on deck 1 through the host (life.req / life.down carry "deck"); the same index on deck 0 lives; tallies
## agree.

const PEERS := 2

var district: CityDistrict
var life: AmbientLife
var stack: CityStack


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


## Stack phase: drop the district and its life, build the stack (and, `with_life`, the one AmbientLife for it).
func _build_stack(with_life: bool) -> void:
	life.queue_free()
	district.queue_free()
	await frames(1)
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 1}))
	if with_life:
		_make_stack_life()
	await frames(1)


func _make_stack_life() -> void:
	life = AmbientLife.new()
	add_child(life)
	life.setup_stack(stack)


## Every deck's people, vehicles and tram at shared-clock time t (cm), as one string.
func _stack_signature(t: float) -> String:
	var out := PackedStringArray()
	for u in life.units:
		for id in u.count():
			var p := u.crowd.pose(id, t)
			out.append("%d.%s@%d,%d" % [u.deck, p["state"], int(round(float(p["x"]) * 100.0)), int(round(float(p["s"]) * 100.0))])
		for v in u.vehicle_count():
			var q := u.fleet.pose(v, t)
			out.append("%d.v%s@%d,%d" % [u.deck, q["state"], int(round(float(q["x"]) * 100.0)), int(round(float(q["s"]) * 100.0))])
		var tp := u.tram.pose(t)
		out.append("%d.tram%s@%d" % [u.deck, tp["mode"], int(round(float(tp["s"]) * 100.0))])
	return ",".join(out)


## People alarmed on deck k at time t within `r` m of arc point `at` (r < 0: anywhere).
func _stack_alarmed(k: int, t: float, at: Vector2 = Vector2.ZERO, r: float = -1.0) -> int:
	var u := life.unit(k)
	var n := 0
	for id in u.count():
		var p := u.crowd.pose(id, t)
		if p["state"] in ["wary", "fleeing", "cowering"] and (r < 0.0 or Vector2(p["x"], p["s"]).distance_to(at) <= r):
			n += 1
	return n


## An outdoor, living person on deck k (id on that deck), or -1.
func _deck_outdoor(k: int) -> int:
	var u := life.unit(k)
	for id in u.count():
		if u.visible_now(id) and u.state_of(id) != "down":
			return id
	return -1


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
	# Stack: the client builds the stack but not its life yet (it misses everything the host does now: a late joiner).
	await _build_stack(true)
	if not check(await wait_reports("stack_ready", 1), "the client built the stack"):
		return
	eq(str(reported(client, "stack_ready")), stack.checksum(), "stack: both machines built the same stack")
	if not check(await until(func() -> bool: return _deck_outdoor(2) >= 0, 30.0), "stack: someone outdoors on deck 2"):
		return
	var dead2 := _deck_outdoor(2)
	check(life.blast(life.unit(2).pose_of(dead2).origin, 0.5, -1) >= 1, "stack: the host kills someone on deck 2")
	var u0 := life.unit(0)
	var wv := -1
	for v in u0.vehicle_count():
		if wv < 0 and u0.vehicle_state(v) != "wreck":
			wv = v
	if check(wv >= 0, "stack: a vehicle on deck 0"):
		var vx := u0.vehicle_pose(wv)
		check(life.blast(vx.origin + vx.basis.y * 0.8, 2.0, -1) >= 1, "stack: the host wrecks a vehicle on deck 0")
	command(client, "make_life", {})
	if not check(await wait_reports("life_ready", 1), "the client made its stack life"):
		return
	life._on_peer_joined(client)        # the join handler: life.sync with the whole stack's snapshot
	if check(await wait_reports("stack_synced", 1) and await wait_reports("stack_tally", 1), "the client reports the stack snapshot"):
		eq(str(reported(client, "stack_synced")), life.snapshot().hex_encode(), "stack late join: the joiner restored the host's snapshot")
		eq(str(reported(client, "stack_tally")), str(life.tally()), "stack late join: the dead on deck 2 and the wreck on deck 0 arrive")
	if not check(await until(func() -> bool: return _deck_outdoor(1) >= 0, 30.0), "stack: someone outdoors on deck 1"):
		return
	var w1 := _deck_outdoor(1)
	var p1 := life.unit(1).crowd.pose(w1, life.now)
	var spot := Vector2(p1["x"], p1["s"])
	life.raise_threat(life.unit(1).pose_of(w1).origin, 40.0, 2)
	var ev: Dictionary = life.sent[life.sent.size() - 1][1]
	var ts := float(ev["t"])
	eq(int(ev.get("deck", -1)), 1, "stack: the threat event carries deck 1")
	command(client, "ssig", {"t": ts + 5.0, "x": spot.x, "s": spot.y})
	if check(await wait_reports("ssig", 1) and await wait_reports("calm0", 1), "the client reports the stack after the threat"):
		eq(str(reported(client, "ssig")), _stack_signature(ts + 5.0), "stack: both machines agree on every deck 5 s after a threat on deck 1")
		check(_stack_alarmed(1, ts + 5.0) > 0, "stack: people on deck 1 react (%d)" % _stack_alarmed(1, ts + 5.0))
		eq(_stack_alarmed(0, ts + 5.0, spot, 60.0), 0, "stack: deck 0 people at the same arc spot stay calm (host)")
		eq(int(reported(client, "calm0")), 0, "stack: deck 0 people at the same arc spot stay calm (client)")
	command(client, "sshoot", {})
	if check(await wait_reports("sshot", 1), "the client reports its shot on deck 1"):
		var sv := int(reported(client, "sshot"))
		if check(sv >= 0, "the client found someone on deck 1"):
			check(await until(func() -> bool: return life.state_of(AmbientLife.ID_STRIDE + sv) == "down", 10.0), "stack: the client's shot on deck 1 kills on the host")
			check(life.state_of(sv) != "down", "stack: the same index on deck 0 is alive (host)")
			check(int(life.tally()["by_src"].get(client, 0)) >= 1, "stack: counted against the client")
	if check(await wait_reports("stally", 1) and await wait_reports("salive0", 1), "the client reports its stack tally"):
		eq(str(reported(client, "stally")), str(life.tally()), "stack: both machines keep the same tally")
		eq(str(reported(client, "salive0")), "true", "stack: the same index on deck 0 is alive (client)")
	print("[net_life] stack phase done: %s" % str(life.tally()))
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
	# Stack: build it, but make the life only when the host says (it has killed and wrecked by then).
	await _build_stack(false)
	report("stack_ready", stack.checksum())
	cmd = await wait_command(60.0)
	if str(cmd.get("cmd", "")) != "make_life":
		check(false, "the host asks for the stack life (%s)" % str(cmd))
		return
	_make_stack_life()
	await frames(1)
	var synced := _synced
	report("life_ready", true)
	check(await until(func() -> bool: return _synced > synced, 10.0), "the stack snapshot arrives")
	await frames(1)
	report("stack_synced", life.snapshot().hex_encode())
	report("stack_tally", str(life.tally()))
	var before := _seen
	cmd = await wait_command(60.0)
	if str(cmd.get("cmd", "")) != "ssig":
		check(false, "the host asks for the stack signature (%s)" % str(cmd))
		return
	check(await until(func() -> bool: return _seen > before, 10.0), "the stack threat arrives")
	report("ssig", _stack_signature(float(cmd["t"])))
	report("calm0", _stack_alarmed(0, float(cmd["t"]), Vector2(float(cmd["x"]), float(cmd["s"])), 60.0))
	cmd = await wait_command(30.0)
	if str(cmd.get("cmd", "")) != "sshoot":
		check(false, "the host asks for a shot on deck 1 (%s)" % str(cmd))
		return
	await until(func() -> bool: return _deck_outdoor(1) >= 0, 30.0)
	var u1 := life.unit(1)
	var target := _deck_outdoor(1)
	if target >= 0:
		var xf := u1.pose_of(target)
		var up := xf.basis.y.normalized()
		var n := life.sweep(xf.origin + up - xf.basis.x * 1.0, xf.origin + up + xf.basis.x * 1.0, 0.1, Session.local_id())
		check(n >= 1, "stack: the sweep finds the person on deck 1")
		check(await until(func() -> bool: return u1.state_of(target) == "down", 10.0), "stack: down when the host's event arrives")
	report("sshot", target)
	await sleep(0.5)
	report("stally", str(life.tally()))
	report("salive0", str(target >= 0 and life.unit(0).state_of(target) != "down"))


var _seen := 0                 ## client: life.threat events received
var _synced := 0               ## client: life.sync events received


func _on_event(from: int, kind: String, data: Dictionary, stamp: float) -> void:
	if kind == "life.threat":
		_seen += 1
	elif kind == "life.sync":
		_synced += 1
	super._on_event(from, kind, data, stamp)
