extends TestCase
## A tram car never crushes or wedges a mech against a portal's back plate, nor pushes it through it, leaving or returning
## (playtest, section seed 403112: the tram's cars shoved the mech out through the portal; once the recess was sealed
## (CityDistrict back plate, tests/test_map_sealed.gd) they pinched it against the plate instead). And getting squished
## costs: a car pinning a mech crushes it ONCE (LifeTram.CRUSH_DAMAGE to each leg, through the victim's PlayerTarget
## apply_damage, src "crush") and then passes through it.
##
## Real stack (seed 403112), real AmbientLife driving deck 0's tram through its spine portal and back with physics frames
## (life clock and physics both at 60 Hz), a mech-sized CharacterBody3D (MechSpawn's capsule, r 2.2, h 8) standing on the
## track with ring gravity, and a stub PlayerTarget (group "player_target", `mech` = the probe) recording apply_damage:
## (a) just in front of the portal (inside the map): it may be shoved toward the wall, never into the plate; one crush;
## (b) in the recess: the cars pass through it out and back; no crush (the tram never pushes it there);
## (c) on open track ahead of a train running to a station stop: pushed along with room, no crush;
## (d) the same with a 6 m block right behind it: pinned, one crush, every car passes through it, never through the block.
## Before the fix (2026-11-23): (a) and (b) were shoved into the plate and squeezed THROUGH it (far side 13.6 m beyond the
## wall plane, plate face 5.9), pinch at t 1235.65 with car 0 enabled 1.32 m into the recess; no crush damage existed.
## Every physics frame: never past the plate's face, floor under it, never between an ENABLED car and the plate with less
## than its diameter + 0.3 m of room, never overlapping an enabled car while in the recess; at the end at rest on the floor.

const SEED := 403112
const G := 22.0
const MARGIN := 0.3
const DT := 1.0 / 60.0

var stack: CityStack
var life: AmbientLife
var u: AmbientLife
var tram: LifeTram
var ring: RingFrame
var r := 2.2
var h := 8.0
var o := 1.0            ## outward sign along s at the portal wall
var wall := 0.0
var plate_face := 0.0   ## m beyond the wall plane where the back plate's inner face is
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
	for un in life.units:
		un.set_process(false)
	u = life.unit(0)
	tram = u.tram
	ring = stack.deck_ring(0)
	if not check(tram != null and (tram.portal_lo or tram.portal_hi), "seed %d deck 0: a tram with a portal end" % SEED):
		finish()
		return
	o = 1.0 if tram.portal_hi else -1.0
	wall = tram.wall_hi if tram.portal_hi else tram.wall_lo
	# CityDistrict._col_walls: the plate box is centred GATE_RECESS - 0.05 + PORTAL_PLATE / 2 out, PORTAL_PLATE + 0.1 thick.
	plate_face = CityStreets.GATE_RECESS - 0.05 + CityDistrict.PORTAL_PLATE * 0.5 - (CityDistrict.PORTAL_PLATE + 0.1) * 0.5
	print("[tram portal] capsule r %.2f h %.2f; portal %s wall s %.1f, track x %.2f, period %.0f s" % [r, h, "hi" if o > 0 else "lo", wall, tram.x, tram.period])
	t = 1000.0
	life.advance_to(t)
	await frames(2)
	var t_out := _find_out_run(t)
	check(t_out > 0.0, "the tram runs out through the portal")
	if t_out > 0.0:
		await _portal_case("front", t_out, -(r + 1.0), 1)
		await _portal_case("recess", t_out, 3.0, 0)
	await _open_track_case(false)
	await _open_track_case(true)
	finish()


## The first time >= t0 when the train runs outward with its leading end 50 m inside the portal wall.
func _find_out_run(t0: float) -> float:
	var tt := t0
	while tt < t0 + tram.period * 2.0:
		var p := tram.pose(tt)
		var front := float(p["s"]) + o * LifeTram.HALF
		if float(p["v"]) * o > 0.5 and o * (wall - front) <= 50.0 and o * (wall - front) > 40.0:
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
	q.exclude = []
	return not stack.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Per-frame checks for a probe near the portal. Returns [past plate, no floor, pinch, overlap-in-recess] counts.
func _portal_checks(probe: Probe, bad: Array, label: String) -> void:
	var a := _arc(probe.global_position)
	var bey := o * (a.y - wall)                   # centre beyond the wall plane
	if bey + r > plate_face + MARGIN:
		if bad[0] == 0:
			_fail("%s: the body went past the back plate (far side %.2f m beyond the wall, plate face %.2f) at t %.2f" % [label, bey + r, plate_face, t])
		bad[0] += 1
	if not _floor_under(probe.global_position):
		if bad[1] == 0:
			_fail("%s: no floor under the body at s %.1f (%.1f m beyond the wall) at t %.2f" % [label, a.y, bey, t])
		bad[1] += 1
	var p := tram.pose(u.now)
	for i in LifeTram.CARS:
		var shape := u.tram_cars.bodies[i].get_child(0) as CollisionShape3D
		if shape.disabled:
			continue
		var cs := LifeTram.car_s(float(p["s"]), i)
		var lat := absf(a.x - tram.x)
		if lat > LifeTram.CAR_W * 0.5 + r:
			continue
		# The body between this car and the plate, with less room than its diameter.
		var face := o * (cs + o * LifeTram.CAR_L * 0.5 - wall)      # the car's plate-side end beyond the wall plane
		if o * (a.y - cs) > 0.0 and plate_face - face < 2.0 * r + MARGIN:
			if bad[2] == 0:
				_fail("%s: pinch: car %d is enabled with its end %.2f m beyond the wall, the body between it and the plate (%.2f m of room < %.2f) at t %.2f"
						% [label, i, face, plate_face - face, 2.0 * r + MARGIN, t])
			bad[2] += 1
		# Overlapping an enabled car while in the recess.
		if bey > 0.0 and absf(a.y - cs) < LifeTram.CAR_L * 0.5 + r - MARGIN and lat < LifeTram.CAR_W * 0.5 + r - MARGIN:
			if bad[3] == 0:
				_fail("%s: overlapping enabled car %d while in the recess (%.2f m beyond the wall) at t %.2f" % [label, i, bey, t])
			bad[3] += 1


## The probe starts `depth` m beyond the wall plane (negative: inside the map) on the track; the tram runs out from t_out
## and comes back.
func _portal_case(label: String, t_out: float, depth: float, want_hits: int) -> void:
	t = t_out
	life.advance_to(t)
	await frames(2)
	var pv: Array = _spawn(wall + o * depth)
	var probe: Probe = pv[0]
	var victim: Victim = pv[1]
	var bad := [0, 0, 0, 0]
	var seen_away := false
	var deepest := -INF
	var vmax := 0.0
	var frames_n := 0
	var settle := -1
	while frames_n < 60 * 120:
		await _step()
		frames_n += 1
		_portal_checks(probe, bad, label)
		var a := _arc(probe.global_position)
		deepest = maxf(deepest, o * (a.y - wall) + r)
		vmax = maxf(vmax, probe.velocity.length())
		var p := tram.pose(u.now)
		if str(p["mode"]) == "away":
			seen_away = true
		var outer := float(p["s"]) + o * LifeTram.HALF
		if settle < 0 and seen_away and o * (wall - outer) >= 30.0:
			settle = frames_n
		if settle >= 0 and frames_n > settle + 120:
			break
	var a := _arc(probe.global_position)
	print("[tram portal] %s: start %.1f m beyond the wall, end %.2f m (far side deepest %.2f, plate face %.2f), lateral %.2f, vmax %.2f, end speed %.2f, %d frames, hits %s; past plate %d, no floor %d, pinch %d, recess overlap %d"
			% [label, depth, o * (a.y - wall), deepest, plate_face, a.x - tram.x, vmax, probe.velocity.length(), frames_n, str(victim.hits), bad[0], bad[1], bad[2], bad[3]])
	check(seen_away and settle >= 0, "%s: the tram went out through the portal and came back" % label)
	eq(bad, [0, 0, 0, 0], "%s: never past the plate, always floor, no pinch, no enabled car overlap in the recess" % label)
	check(probe.velocity.length() < 1.0, "%s: at rest at the end (%.2f m/s)" % [label, probe.velocity.length()])
	check(probe.is_on_floor() and _floor_under(probe.global_position), "%s: on the floor at the end" % label)
	check(absf(a.x - tram.x) < 3.0 and absf(a.z) < 1.0, "%s: not launched (lateral %.2f, height %.2f)" % [label, a.x - tram.x, a.z])
	_check_hits(label, victim, want_hits)
	probe.queue_free()
	victim.queue_free()
	await frames(2)


func _check_hits(label: String, victim: Victim, want: int) -> void:
	# One crush = one apply_damage per leg.
	var crushes := 0
	for hh: Array in victim.hits:
		check(str(hh[2]) == "crush", "%s: damage src crush (%s)" % [label, str(hh)])
		if str(hh[1]) == "leg_l":
			crushes += 1
	eq(crushes, want, "%s: %d crush(es) (%s)" % [label, want, str(victim.hits)])
	if want > 0:
		eq(victim.hits.size(), 2 * want, "%s: each crush hits both legs once" % label)
		if not victim.hits.is_empty():
			near(float(victim.hits[0][0]), _crush_damage(), 1e-6, "%s: LifeTram.CRUSH_DAMAGE per leg" % label)


func _crush_damage() -> float:
	return float((load("res://scripts/world/life/life_tram.gd") as GDScript).get_script_constant_map().get("CRUSH_DAMAGE", -1.0))


## A train running to a station stop: the probe on the track 3 m ahead of its leading end. Without `block`: pushed along
## with room, no crush. With `block`: a 1 m concrete block (layer 1) right behind the probe: pinned against it, one crush,
## then every car passes through it; never through the block, not launched, at rest at the end.
func _open_track_case(block: bool) -> void:
	var label := "pinned at a block" if block else "open track"
	var found := -1.0
	var tt := 1000.0
	while tt < 1000.0 + tram.period * 2.0 and found < 0.0:
		var b := tram.base(tt)
		var sg: Dictionary = tram.segs[int(b["seg"])]
		if int(sg["kind"]) == LifeTram.RUN and str(tram.stops[int(sg["stop"])]["kind"]) == "station":
			var dir := signf(float(sg["s1"]) - float(sg["s0"]))
			var stop_front := float(sg["s1"]) + dir * LifeTram.HALF
			var front := float(b["s"]) + dir * LifeTram.HALF
			if absf(float(b["v"])) > 5.0 and dir * (stop_front - front) > 30.0 and dir * (stop_front - front) < 40.0:
				found = tt
		tt += 0.1
	if not check(found > 0.0, "%s: a run to a station stop" % label):
		return
	t = found
	life.advance_to(t)
	await frames(2)
	var b := tram.base(t)
	var dir := signf(float(b["v"]))
	var start_s := float(b["s"]) + dir * (LifeTram.HALF + r + 3.0)
	var wall_s := start_s + dir * (r + 0.05 + 3.0)
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
		if block and dir * (aa.y - wall_s) > -3.0 + MARGIN - r:     # its centre past the block's near face - r (+ slack)
			through += 1
	var a := _arc(probe.global_position)
	print("[tram portal] %s: moved %.1f m (from s %.1f to %.1f), lateral max %.2f, height max %.2f, vmax %.2f, end speed %.2f, tram %s, hits %s"
			% [label, dir * (a.y - start_s), start_s, a.y, lat_max, hmax, vmax, probe.velocity.length(), tram.state_of(u.now), str(victim.hits)])
	if block:
		eq(through, 0, "%s: never pushed into / through the block" % label)
		check(lat_max < 1.5 and hmax < 1.0, "%s: not squeezed out sideways or up (lateral %.2f, height %.2f)" % [label, lat_max, hmax])
	else:
		check(dir * (a.y - start_s) > 5.0, "%s: the train really pushed it (%.1f m)" % [label, dir * (a.y - start_s)])
	eq(no_floor, 0, "%s: always floor under it" % label)
	check(probe.velocity.length() < 1.0 and probe.is_on_floor(), "%s: at rest on the floor at the end" % label)
	check(vmax < 15.0, "%s: never flung (max %.2f m/s)" % [label, vmax])
	_check_hits(label, victim, 1 if block else 0)
	probe.queue_free()
	victim.queue_free()
	if slab != null:
		slab.queue_free()
	await frames(2)