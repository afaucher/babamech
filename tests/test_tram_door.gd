extends TestCase
## The tram and its doors (docs/design/city-spine.md section 5; LifeTram, AmbientLife.set_tram_door). Real stack (seed
## 403112), deck 0's tram:
## DOOR LINK (pure, the shared clock): door s1 shut ahead of a train leaving the station -> it brakes and waits with its
## nose END_CLEAR (5 m) short of the door plane, as long as the door stays shut; the door opens -> it waits until fully
## open (DOOR_OPEN s) and goes on out; door s0 shut behind -> no train comes in (no car past the s0 plane) for three
## periods; reopened -> a train comes in and stops at the station. Never through a shut door. Two instances fed the same
## events, one as they happen and one late (and a third from a snapshot), agree on the pose at every clock time.
## Through AmbientLife: the call reaches deck 0's tram only, is logged as "life.door" (deck 0) and a second instance fed
## the log agrees; decks 1.. have no tram, no cars, no tram blob.
## COLLISION (physics frames, a mech-sized capsule on the track): (a) just inside the map in front of the s1 door: shoved
## toward the wall, never past the door plane (no mech fits a tram door; tested against the plan's wall plane, whatever
## the door / tunnel geometry), one crush; (c) open track ahead of a train running to the station: pushed with room, no
## crush; (d) the same with a block behind it: pinned, one crush, then every car passes through it. A crush is
## LifeTram.CRUSH_DAMAGE to each leg through the victim's PlayerTarget (src "crush"), once per pass.

const SEED := 403112
const G := 22.0
const MARGIN := 0.3
const DT := 1.0 / 60.0

var stack: CityStack
var life: AmbientLife
var u: LifeDeck
var tram: LifeTram
var ring: RingFrame
var r := 2.2
var h := 8.0
var t := 0.0


class Probe extends CharacterBody3D:
	var ring: RingFrame
	var g := 22.0

	func _physics_process(delta: float) -> void:
		var up := ring.up_at(global_position)
		up_direction = up
		global_basis = ring.basis_at(global_position, ring.tangent_at(global_position))
		var vv := velocity.dot(up)
		if is_on_floor():
			vv = 0.0
		vv -= g * delta
		velocity = up * vv          # a mech standing still: no drive, gravity only
		move_and_slide()


class Victim extends Node:
	var mech: Node3D
	var hits: Array = []

	func _init() -> void:
		add_to_group("player_target")

	func apply_damage(amount: float, component: String, src: String) -> void:
		hits.append([amount, component, src])


func _init() -> void:
	timeout_sec = 900.0


func setup() -> void:
	var m := MechSpawn.make()
	var cap := (m.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	r = cap.radius
	h = cap.height
	m.free()
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": SEED}))
	life = AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup_stack(stack)
	u = life.unit(0)
	tram = u.tram
	ring = stack.deck_ring(0)
	if not check(tram != null, "seed %d deck 0: a tram" % SEED):
		finish()
		return
	print("[tram door] capsule r %.2f h %.2f; walls s %.1f / %.1f, track x %.2f, stop s %.1f, period %.0f s (pass %.1f s)" % [
			r, h, tram.wall_lo, tram.wall_hi, tram.x, tram.stop_s, tram.period, tram.pass_time])
	_deck_checks()
	_door_link()
	_two_instances()
	_ambient_route()
	t = 1000.0
	life.restore(PackedByteArray())
	life.advance_to(t)
	await frames(2)
	var t_out := _find_out_run(t)
	check(t_out > 0.0, "the tram runs out toward the s1 door")
	if t_out > 0.0:
		await _front_case(t_out)
	await _open_track_case(false)
	await _open_track_case(true)
	finish()


# --- Decks --------------------------------------------------------------------------------------------------

func _deck_checks() -> void:
	for k in range(1, life.units.size()):
		var dk := life.unit(k)
		check(dk.tram == null and dk.tram_cars == null and dk.plan.rail_edges.is_empty(), "deck %d: no tram, no cars, no rail crossing rule" % k)
	# A deck's snapshot without a tram has no tram blob: its fleet part runs to the end.
	var b := life.unit(1).snapshot()
	var n := b.decode_u32(0)
	eq(b.size(), 4 + n + life.unit(1).fleet.snapshot().size(), "deck 1's snapshot: people + fleet, no tram blob")


# --- The door link (pure) -----------------------------------------------------------------------------------

## The nose (front end) of the train at time t.
func _nose(tr: LifeTram, tt: float) -> float:
	return float(tr.pose(tt)["s"]) + LifeTram.HALF


func _door_link() -> void:
	var tr := LifeTram.make(tram.plan, 0.37)
	# A train just leaving the station (running, 20 m past the stop).
	var T := 1000.0
	while not (tr.state_of(T) == "running" and float(tr.pose(T)["s"]) > tr.stop_s + 20.0):
		T += 0.25
	tr.set_door("s1", false, T)
	var wait_s := tr.wall_hi - LifeTram.END_CLEAR - LifeTram.HALF
	var past := 0
	var tt := T
	while tt < T + 200.0:
		if _nose(tr, tt) > tr.wall_hi - LifeTram.END_CLEAR + 1e-3:
			past += 1
		tt += 0.1
	eq(past, 0, "s1 shut ahead: the nose never closer than 5 m to the door plane")
	near(float(tr.pose(T + 200.0)["s"]), wait_s, 1e-3, "s1 shut ahead: it waits with its nose 5 m short of the door")
	eq(tr.state_of(T + 200.0), "waiting", "s1 shut ahead: mode waiting")
	check(absf(float(tr.pose(T + 200.0)["v"])) < 1e-6, "s1 shut ahead: at rest")
	var hard := 0
	var prev := tr.pose(T)
	tt = T + 0.05
	while tt < T + 60.0:
		var p := tr.pose(tt)
		if absf(float(p["v"]) - float(prev["v"])) > LifeTram.BRAKE * 0.05 + 1e-3:
			hard += 1
		prev = p
		tt += 0.05
	eq(hard, 0, "s1 shut ahead: never braking harder than 2.5 m/s^2")
	# Open: still waiting until it is fully open, then out.
	var To := T + 210.0
	tr.set_door("s1", true, To)
	eq(tr.state_of(To + LifeTram.DOOR_OPEN - 0.1), "waiting", "s1 opening: waits until the door is fully open")
	check(float(tr.pose(To + LifeTram.DOOR_OPEN + 2.0)["s"]) > wait_s + 0.5, "s1 open: it goes on")
	var gone := To + LifeTram.DOOR_OPEN + 60.0
	eq(tr.state_of(gone), "away", "s1 open: out of sight a minute later")
	# s0 shut behind, while no train is in: none comes in for three periods.
	var Ts := gone
	while tr.state_of(Ts) != "away" or tr.state_of(Ts - 1.0) != "away":
		Ts += 1.0
	tr.set_door("s0", false, Ts)
	var arrived := 0
	tt = Ts
	while tt < Ts + tr.period * 3.0:
		if _nose(tr, tt) > tr.wall_lo - LifeTram.END_CLEAR + 1e-3 and tr.state_of(tt) != "away" and float(tr.pose(tt)["s"]) < tr.wall_hi:
			arrived += 1
		tt += 0.5
	eq(arrived, 0, "s0 shut behind: no train comes in for three periods")
	var waiting := tr.pose(Ts + tr.period * 3.0)
	check(float(waiting["s"]) <= tr.wall_lo - LifeTram.END_CLEAR - LifeTram.HALF + 1e-3, "s0 shut: a train waits in the tunnel behind it (s %.1f)" % float(waiting["s"]))
	# Reopen: a train comes in and dwells at the station.
	var Tr := Ts + tr.period * 3.0 + 5.0
	tr.set_door("s0", true, Tr)
	var came := -1.0
	var dwelt := false
	tt = Tr
	while tt < Tr + tr.period * 2.0:
		var p := tr.pose(tt)
		if came < 0.0 and float(p["s"]) - LifeTram.HALF > tr.wall_lo:
			came = tt
		if p["mode"] == "dwell" and absf(float(p["s"]) - tr.stop_s) < 0.01:
			dwelt = true
		tt += 0.5
	check(came > 0.0 and came >= Tr + LifeTram.DOOR_OPEN, "s0 reopened: a train comes in (after %.1f s)" % (came - Tr))
	check(dwelt, "s0 reopened: it stops at the station")
	var later := Tr + tr.period * 4.0
	near(float(tr.pose(later)["s"]), float(tr.base(later)["s"]), 1e-6, "doors open again: back on the timetable")
	print("[tram door] link: s1 shut at %.1f, waits at s %.1f; s0 shut %.1f-%.1f; next train in %.1f s after the reopening" % [T, wait_s, Ts, Tr, came - Tr])


## The same events on two trams, one applying each at its own time while time runs, one applying them all late, and one
## restored from the first's snapshot: the same pose at every clock time.
func _two_instances() -> void:
	var a := LifeTram.make(tram.plan, 0.37)
	var b := LifeTram.make(tram.plan, 0.37)
	var T := 2000.0
	while not (a.state_of(T) == "running" and float(a.pose(T)["s"]) > a.stop_s + 20.0):
		T += 0.5
	var evs := [["door", "s1", false, T], ["threat", T + 4.0], ["door", "s1", true, T + 60.0], ["door", "s0", false, T + 70.0],
			["door", "s0", true, T + 400.0]]
	var poses_a := []
	for ev: Array in evs:
		var at := float(ev[3]) if ev[0] == "door" else float(ev[1])
		for k in 10:
			poses_a.append(a.pose(at - 5.0 + float(k)))         # a running instance looks at its clock before each event
		_apply(a, ev)
	for ev: Array in evs:
		_apply(b, ev)
	var c := LifeTram.make(tram.plan, 0.37)
	c.restore(a.snapshot())
	var diff := 0
	var tt := T - 10.0
	while tt < T + 800.0:
		var pa := a.pose(tt)
		for o: LifeTram in [b, c]:
			var po := o.pose(tt)
			if absf(float(pa["s"]) - float(po["s"])) > 1e-6 or pa["mode"] != po["mode"]:
				diff += 1
		tt += 0.25
	eq(diff, 0, "two instances fed the same events at different times (and a snapshot) agree at every clock time")
	check(a.episodes.size() == 1 and a.door_events.size() == 4, "the events recorded (%d halts, %d door events)" % [a.episodes.size(), a.door_events.size()])
	# Malformed snapshots are ignored whole.
	var bad := c.snapshot()
	bad.resize(bad.size() - 3)
	c.restore(bad)
	check(c.episodes.is_empty() and c.door_events.is_empty(), "a cut snapshot is ignored")
	var lie := PackedByteArray([LifeTram.SNAP_VERSION, 0, 0, 0xFF, 0xFF])
	c.restore(lie)
	check(c.door_events.is_empty(), "a snapshot claiming 65535 door events with none in it is ignored")


func _apply(tr: LifeTram, ev: Array) -> void:
	if ev[0] == "door":
		tr.set_door(str(ev[1]), bool(ev[2]), float(ev[3]))
	else:
		var p := tr.pose(float(ev[1]))
		tr.apply_threat({"x": tr.x + 10.0, "s": float(p["s"]), "r": 40.0, "st": 2, "t": float(ev[1])})


## AmbientLife.set_tram_door reaches deck 0's tram, is logged and replayed by a second instance; the snapshot carries it.
func _ambient_route() -> void:
	life.restore(PackedByteArray())
	life.sent.clear()
	var T := 3000.0
	life.advance_to(T)
	life.set_tram_door("s1", false, T)
	eq(tram.door_events.size(), 1, "set_tram_door: recorded on deck 0's tram")
	check(not life.tram_door_open("s1") and life.tram_door_open("s0"), "tram_door_open follows the calls")
	var logged := false
	for ev: Array in life.sent:
		if ev[0] == "life.door" and int((ev[1] as Dictionary).get("deck", -1)) == 0:
			logged = true
	check(logged, "set_tram_door: logged as life.door for deck 0")
	var other := AmbientLife.new()
	add_child(other)
	other.set_process(false)
	other.setup_stack(stack)
	other.advance_to(T)
	for ev: Array in life.sent:
		other.apply_event(ev[0], ev[1])
	var same := true
	for k in 40:
		life.advance_to(T + float(k) * 5.0)
		other.advance_to(T + float(k) * 5.0)
		if absf(float(tram.pose(life.now)["s"]) - float(other.unit(0).tram.pose(other.now)["s"])) > 1e-6:
			same = false
	check(same, "a second AmbientLife fed the life.door event agrees")
	var joiner := AmbientLife.new()
	add_child(joiner)
	joiner.set_process(false)
	joiner.setup_stack(stack)
	joiner.restore(life.snapshot())
	eq(joiner.unit(0).tram.door_events.size(), 1, "the snapshot carries the door event")
	other.queue_free()
	joiner.queue_free()
	life.restore(PackedByteArray())


# --- Collision --------------------------------------------------------------------------------------------------

## The first time >= t0 when the train runs toward s1 with its nose 40-50 m short of the door plane.
func _find_out_run(t0: float) -> float:
	var tt := t0
	while tt < t0 + tram.period * 2.0:
		var p := tram.pose(tt)
		var front := float(p["s"]) + LifeTram.HALF
		if float(p["v"]) > 0.5 and tram.wall_hi - front <= 50.0 and tram.wall_hi - front > 40.0:
			return tt
		tt += 0.1
	return -1.0


func _world(x: float, s: float, hh: float) -> Vector3:
	return ring.arc_to_world(x, s, hh)


func _arc(p: Vector3) -> Vector3:
	return ring.world_to_arc(p)


func _spawn(s: float) -> Array:
	var probe := Probe.new()
	probe.ring = ring
	probe.g = G
	probe.collision_layer = 2
	probe.collision_mask = 1
	probe.floor_snap_length = 0.5
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = h
	cs.shape = cap
	cs.position = Vector3(0, h * 0.5, 0)
	probe.add_child(cs)
	add_child(probe)
	var p := _world(tram.x, s, 0.3)
	probe.global_transform = Transform3D(ring.basis_at(p, ring.tangent_at(p)), p)
	var victim := Victim.new()
	victim.mech = probe
	add_child(victim)
	return [probe, victim]


func _step() -> void:
	t += DT
	life.advance_to(t)
	await get_tree().physics_frame


func _floor_under(p: Vector3) -> bool:
	var a := _arc(p)
	var q := PhysicsRayQueryParameters3D.create(_world(a.x, a.y, 2.0), _world(a.x, a.y, -1.5))
	return not stack.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## (a) The probe r + 1 m inside the s1 wall on the track; the train runs out through the door past it.
func _front_case(t_out: float) -> void:
	t = t_out
	life.advance_to(t)
	await frames(2)
	var pv: Array = _spawn(tram.wall_hi - (r + 1.0))
	var probe: Probe = pv[0]
	var victim: Victim = pv[1]
	var past := 0
	var deepest := -INF
	var frames_n := 0
	var gone := -1
	while frames_n < 60 * 90:
		await _step()
		frames_n += 1
		var a := _arc(probe.global_position)
		deepest = maxf(deepest, a.y + r - tram.wall_hi)
		if a.y + r > tram.wall_hi + MARGIN:
			past += 1
		if gone < 0 and tram.state_of(u.now) == "away":
			gone = frames_n
		if gone >= 0 and frames_n > gone + 120:
			break
	var a := _arc(probe.global_position)
	print("[tram door] front: far side deepest %.2f m past the door plane, end %.2f, lateral %.2f, end speed %.2f, %d frames, hits %s"
			% [deepest, a.y + r - tram.wall_hi, a.x - tram.x, probe.velocity.length(), frames_n, str(victim.hits)])
	check(gone >= 0, "front: the train went out through the door")
	eq(past, 0, "front: never pushed past the door plane (%.2f m deepest)" % deepest)
	check(probe.velocity.length() < 1.0 and _floor_under(probe.global_position), "front: at rest on the floor at the end")
	check(absf(a.x - tram.x) < 3.0 and absf(a.z) < 1.0, "front: not launched (lateral %.2f, height %.2f)" % [a.x - tram.x, a.z])
	_check_hits("front", victim, 1)
	probe.queue_free()
	victim.queue_free()
	await frames(2)


func _check_hits(label: String, victim: Victim, want: int) -> void:
	var crushes := 0
	for hh: Array in victim.hits:
		check(str(hh[2]) == "crush", "%s: damage src crush (%s)" % [label, str(hh)])
		if str(hh[1]) == "leg_l":
			crushes += 1
	eq(crushes, want, "%s: %d crush(es) (%s)" % [label, want, str(victim.hits)])
	if want > 0:
		eq(victim.hits.size(), 2 * want, "%s: each crush hits both legs once" % label)
		if not victim.hits.is_empty():
			near(float(victim.hits[0][0]), LifeTram.CRUSH_DAMAGE, 1e-6, "%s: LifeTram.CRUSH_DAMAGE per leg" % label)


## A train running to the station: the probe on the track 3 m ahead of its nose. Without `block`: pushed along with room,
## no crush. With `block`: a concrete block (layer 1) right behind the probe: pinned against it, one crush, then every car
## passes through it; never through the block, not launched, at rest at the end.
func _open_track_case(block: bool) -> void:
	var label := "pinned at a block" if block else "open track"
	var found := -1.0
	var tt := 1000.0
	while tt < 1000.0 + tram.period * 2.0 and found < 0.0:
		var b := tram.base(tt)
		var stop_front := tram.stop_s + LifeTram.HALF
		var front := float(b["s"]) + LifeTram.HALF
		if b["mode"] == "running" and float(b["v"]) > 5.0 and front < stop_front and stop_front - front > 30.0 and stop_front - front < 40.0:
			found = tt
		tt += 0.1
	if not check(found > 0.0, "%s: a run to the station" % label):
		return
	t = found
	life.advance_to(t)
	await frames(2)
	var b := tram.base(t)
	var start_s := float(b["s"]) + LifeTram.HALF + r + 3.0
	var wall_s := start_s + r + 0.05 + 3.0
	var slab: StaticBody3D = null
	if block:
		slab = StaticBody3D.new()
		slab.collision_layer = 1
		var bcs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(8.0, 10.0, 6.0)
		bcs.shape = box
		slab.add_child(bcs)
		add_child(slab)
		var bp := _world(tram.x, wall_s, 5.0)
		slab.global_transform = Transform3D(ring.basis_at(bp, ring.tangent_at(bp)), bp)
		await frames(1)
	var pv: Array = _spawn(start_s)
	var probe: Probe = pv[0]
	var victim: Victim = pv[1]
	var vmax := 0.0
	var no_floor := 0
	var through := 0
	var lat_max := 0.0
	var hmax := 0.0
	for f in 60 * 25:
		await _step()
		vmax = maxf(vmax, probe.velocity.length())
		var aa := _arc(probe.global_position)
		lat_max = maxf(lat_max, absf(aa.x - tram.x))
		hmax = maxf(hmax, aa.z)
		if not _floor_under(probe.global_position):
			no_floor += 1
		if block and aa.y - wall_s > -3.0 + MARGIN - r:
			through += 1
	var a := _arc(probe.global_position)
	print("[tram door] %s: moved %.1f m (from s %.1f to %.1f), lateral max %.2f, height max %.2f, vmax %.2f, end speed %.2f, tram %s, hits %s"
			% [label, a.y - start_s, start_s, a.y, lat_max, hmax, vmax, probe.velocity.length(), tram.state_of(u.now), str(victim.hits)])
	if block:
		eq(through, 0, "%s: never pushed into / through the block" % label)
		check(lat_max < 1.5 and hmax < 1.0, "%s: not squeezed out sideways or up (lateral %.2f, height %.2f)" % [label, lat_max, hmax])
	else:
		check(a.y - start_s > 5.0, "%s: the train really pushed it (%.1f m)" % [label, a.y - start_s])
	eq(no_floor, 0, "%s: always floor under it" % label)
	check(probe.velocity.length() < 1.0 and probe.is_on_floor(), "%s: at rest on the floor at the end" % label)
	check(vmax < 15.0, "%s: never flung (max %.2f m/s)" % [label, vmax])
	_check_hits(label, victim, 1 if block else 0)
	probe.queue_free()
	victim.queue_free()
	if slab != null:
		slab.queue_free()
	await frames(2)
