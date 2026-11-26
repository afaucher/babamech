class_name HangarEgress
extends RefCounted
## The launch sequence in the hangar bay (docs/design/hangar-v2/README.md: the shared bay airlock). The crew leaves
## through the one airlock in the left end wall (HangarAirlock) in GROUPS: as many mechs as the chamber's lanes hold
## (HangarBay.lane_length, from the catalog), in queue order (nearest the airlock first). Per group:
##   enter    the inner door cycles open; each mech in turn: its clamps release, it steps out of its alcove to its
##            lane, turns toward the airlock and walks down the aisle into the chamber, to its slot (nose to tail in
##            its lane, the first one deepest)
##   seal     every mech parked: the inner door shuts
##   cycle    the chamber cycles (amber light, lamps flashing)
##   outer    the outer door opens (red)
##   leave    the group walks out into the corridor
##   shut     the outer door shuts (the group is gone), the chamber cycles back; the next group's turn
## No two mechs walk through each other: a mech starts only once the one before it has turned onto its lane and stands
## farther off than both turning radii (so wide neighbours never turn at once), and in a lane it keeps SLOT_GAP behind
## the mech ahead. Speeds and turn rates are the chassis' (MechCatalog movement, in the bay's half scale: GAME_SCALE);
## the feet are planted by Gait and the legs solved by LegIK like MechRig does in the game. Cosmetic only: no net
## state, nothing gameplay.

const GAME_SCALE := 2.0        ## the game's mechs are MechRig.mech_scale (2.0) times the bay's (scale 1) models
const RELEASE := 0.6
const STAGGER := 0.4           ## at least this long between two mechs' starts
const DOOR_SEAL := 0.35        ## a door's lamp flashes amber this long before its leaves move
const DOOR_OPEN := 1.1
const DOOR_CLOSE := 0.9
const CYCLE := 1.4             ## the chamber cycling (pressure), amber
const TURN_PAUSE := 0.15
const EXIT_GAP := 0.3          ## leaving: the last mech's back this far past the outer door's wall
const FOLLOW_GAP := 1.6        ## behind a mech that is still walking: room for both strides (legs reach past the box)

var walkers: Array[Walker] = []
var groups: Array = []         ## [[Walker, ...], ...] in order
var t := 0.0                   ## sequence time (s, natural pace)
var group := 0
var gphase := "enter"
var gphase_t := 0.0
var dry := false               ## a dry run (duration()): no models touched, no legs posed
var airlock: HangarAirlock
var _duration := -1.0


class Walker:
	var i := 0
	var model: MechModel
	var dry := false
	var gait: Gait
	var rig_bob := 0.1
	var rig_lean := 0.16
	var start := Vector3.ZERO
	var front := 1.0           ## box reach ahead of / behind the origin (along its facing)
	var back := 1.0
	var radius := 2.0
	var lane := 0
	var lane_z := 0.0
	var slot_x := 0.0
	var exit_x := 0.0
	var speed := 6.0           ## bay m/s
	var accel := 15.0
	var turn_rate := 1.8
	var phase := "wait"
	var phase_t := 0.0
	var started_at := -1.0
	var pos := Vector3.ZERO
	var yaw := PI
	var v := 0.0
	var clamp_k := 1.0

	func setup(bay: HangarBay) -> void:
		var id := model.chassis_id
		var mv := MechCatalog.movement(id)
		speed = float(mv.get("walk_speed", 12.0)) / GAME_SCALE
		accel = float(mv.get("accel", 30.0)) / GAME_SCALE
		turn_rate = float(mv.get("turn_rate", 1.8))
		var ext := bay.mech_extent(i)
		front = ext.x
		back = ext.y
		radius = bay.turn_radius(i)
		start = Vector3(float(HangarBay.ALCOVE_X[i]), HangarBay.PLATFORM_H, HangarBay.MECH_Z)
		pos = start
		yaw = HangarBay.MECH_YAW
		if dry:
			return
		var rig := MechRig.new()
		rig.apply_chassis_rig(id)
		gait = rig.gait
		gait.run_speed = float(mv.get("run_speed", 22.0))
		gait.foot_clearance = rig.foot_gap * GAME_SCALE
		gait.max_lift = model.max_foot_lift() * GAME_SCALE
		gait.max_step = gait.max_lift * rig.step_margin
		rig_bob = rig.bob
		rig_lean = rig.lean
		rig.free()

	func depth() -> float:
		return front + back

	## Floor height (bay space) under a point: the platform inside the alcove row, the deck elsewhere (the airlock's too).
	static func floor_y(p: Vector3) -> float:
		return HangarBay.PLATFORM_H if p.z < HangarBay.FRONT_Z and p.x > HangarBay.AIRLOCK_X else 0.0

	func begin(now: float) -> void:
		phase = "release"
		phase_t = 0.0
		started_at = now
		if not dry:
			model.time_scale = 0.0
			gait.reset([])

	## One step; `limit_x` is the least x the mech may walk to now (the inner door shut, the mech ahead in its lane).
	func step(dt: float, limit_x: float) -> void:
		if phase == "wait" or phase == "gone":
			return
		phase_t += dt
		clamp_k = 1.0 - clampf(phase_t / RELEASE, 0.0, 1.0) if phase == "release" else 0.0
		var vel := Vector3.ZERO
		match phase:
			"release":
				if phase_t >= RELEASE:
					_next("out")
			"out":
				vel = _walk(lane_z - pos.z, dt) * Vector3.BACK
				pos.z += vel.z * dt
				if absf(lane_z - pos.z) < 0.01 and v < 0.05:
					pos.z = lane_z
					_next("turn")
			"turn":
				if phase_t > TURN_PAUSE:
					yaw = move_toward(yaw, PI * 0.5, turn_rate * dt)
				if absf(yaw - PI * 0.5) < 0.001 and phase_t > TURN_PAUSE * 2.0:
					_next("walk")
			"walk", "exit":
				var goal := maxf(slot_x if phase == "walk" else exit_x, limit_x)
				vel = _walk(pos.x - goal, dt) * Vector3.LEFT
				pos.x += vel.x * dt
				var target := slot_x if phase == "walk" else exit_x
				if phase == "walk" and absf(pos.x - target) < 0.01 and v < 0.05:
					pos.x = target
					_next("parked")
				elif phase == "exit" and absf(pos.x - target) < 0.01 and v < 0.05:
					pos.x = target
					_next("out_of_sight")
		if not dry:
			model.position = Vector3(pos.x, move_toward(model.position.y, floor_y(pos), 1.6 * dt), pos.z)
			model.rotation.y = yaw
			_pose_legs(dt, vel)

	func _next(p: String) -> void:
		phase = p
		phase_t = 0.0

	## Speed toward a goal `left` metres ahead: accelerate to `speed`, brake to stop on it. Returns the new speed.
	func _walk(left: float, dt: float) -> float:
		var want := minf(speed, sqrt(2.0 * accel * maxf(left, 0.0)))
		v = move_toward(v, want, accel * dt)
		if left <= 0.005:
			v = 0.0
		return minf(v, maxf(left, 0.0) / maxf(dt, 1e-4))

	## MechRig's leg pass on the bay floor (Gait in game metres: GAME_SCALE; LegIK per leg; bob between steps).
	func _pose_legs(dt: float, vel: Vector3) -> void:
		var xf := model.transform
		var homes: Array = []
		for side: float in [-1.0, 1.0]:
			var hip := xf * model.hip_local(side)
			homes.append(Vector3(hip.x, floor_y(hip), hip.z) * GAME_SCALE)
		gait.facing = (xf.basis * Vector3.FORWARD).normalized()
		var ground := func(p: Vector3, _up: Vector3) -> Vector3:
			return Vector3(p.x, floor_y(p / GAME_SCALE) * GAME_SCALE, p.z)
		gait.update(dt, homes, Vector3.UP, vel * GAME_SCALE, ground, false, model.position * GAME_SCALE)
		var inv := xf.affine_inverse()
		var feet_l: Array = []
		var dirs_l: Array = []
		for f: Dictionary in gait.feet:
			feet_l.append(inv * ((f["pos"] as Vector3) / GAME_SCALE))
			var d: Vector3 = f.get("dir", Vector3.ZERO)
			dirs_l.append(xf.basis.inverse() * d if d.length_squared() > 1e-6 else Vector3.ZERO)
		var k := clampf(vel.length() / maxf(speed, 0.1), 0.0, 1.0)
		var offset := Vector3.ZERO
		var low := minf(0.0, minf((feet_l[0] as Vector3).y, (feet_l[1] as Vector3).y))
		offset.y = low * 0.7 - rig_bob * k * (1.0 - gait.lift_amount())
		var rot := Vector3(-rig_lean * k * 0.5, 0.0, 0.0)
		var lengths := model.leg_lengths()
		var legs: Array = []
		for li in 2:
			var side := -1.0 if li == 0 else 1.0
			var hip := model.hip_posed(side, offset, rot, 0.0)
			var r := LegIK.solve_leg(hip, feet_l[li], lengths.x, lengths.y, lengths.z, Vector3.UP, Vector3.FORWARD,
					model.tarsus_lean(), model.leg_bend)
			legs.append({"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"], "foot_dir": dirs_l[li]})
		model.set_external_pose(legs, offset, rot, 0.0)


## Plan the sequence for the bay's crew: the queue (nearest the airlock first), its groups (packed into the lanes:
## a mech joins the current group if some lane still has room for its depth plus SLOT_GAP, else the group closes; the
## same rule for every chassis mix), each mech's lane, slot and exit point.
func plan(bay: HangarBay, dry_run: bool = false) -> void:
	dry = dry_run
	airlock = null if dry else bay.airlock()
	walkers.clear()
	groups.clear()
	t = 0.0
	group = 0
	gphase = "enter"
	gphase_t = 0.0
	for i in bay.models.size():
		var w := Walker.new()
		w.i = i
		w.model = bay.models[i]
		w.dry = dry
		w.setup(bay)
		walkers.append(w)
	var queue := walkers.duplicate()
	queue.sort_custom(func(a: Walker, b: Walker) -> bool: return a.start.x < b.start.x)
	var cap := HangarBay.lane_length()
	var used: Array[float] = []
	var cur: Array = []
	for w: Walker in queue:
		var lane := _fit(used, w.depth(), cap)
		if lane < 0:
			groups.append(cur)
			cur = []
			used.clear()
			lane = _fit(used, w.depth(), cap)
		_place(w, lane, used, cur)
	if not cur.is_empty():
		groups.append(cur)
	for g: Array in groups:
		_exits(g)


## The first lane with room for a mech `d` deep (lanes open as needed); -1 when none has.
static func _fit(used: Array[float], d: float, cap: float) -> int:
	for k in used.size():
		if used[k] + d + HangarBay.SLOT_GAP <= cap + 0.01:
			return k
	if used.size() < HangarBay.LANES and HangarBay.SLOT_GAP + d + HangarBay.SLOT_GAP <= cap + 0.01:
		used.append(HangarBay.SLOT_GAP)
		return used.size() - 1
	return -1


func _place(w: Walker, lane: int, used: Array[float], cur: Array) -> void:
	w.lane = lane
	w.lane_z = HangarBay.lane_z(lane)
	# Nose to tail from the far end: the first in a lane is deepest (its front SLOT_GAP off the outer door).
	w.slot_x = HangarBay.chamber_far_x() + used[lane] + w.front
	used[lane] += w.depth() + HangarBay.SLOT_GAP
	cur.append(w)


## Leaving: each lane's column walks out together until its last mech's back is EXIT_GAP past the outer door's wall.
func _exits(g: Array) -> void:
	var out_x := HangarBay.chamber_far_x() - HangarBay.END_WALL - EXIT_GAP
	for lane in HangarBay.LANES:
		var rear := -INF
		for w: Walker in g:
			if w.lane == lane:
				rear = maxf(rear, w.slot_x + w.back)
		for w: Walker in g:
			if w.lane == lane:
				w.exit_x = w.slot_x - (rear - out_x)


func step(dt: float) -> void:
	t += dt
	gphase_t += dt
	if group >= groups.size():
		return
	var g: Array = groups[group]
	match gphase:
		"enter":
			_gate(g)
			if _all(g, "parked"):
				_go("seal")
		"seal":
			if gphase_t >= DOOR_CLOSE:
				_go("cycle")
		"cycle":
			if gphase_t >= CYCLE:
				_go("outer")
		"outer":
			if gphase_t >= DOOR_SEAL + DOOR_OPEN:
				for w: Walker in g:
					w.phase = "exit"
					w.phase_t = 0.0
				_go("leave")
		"leave":
			if _all(g, "out_of_sight"):
				_go("shut")
		"shut":
			if gphase_t >= DOOR_CLOSE + CYCLE:
				for w: Walker in g:
					w.phase = "gone"
					if not dry:
						w.model.visible = false
				group += 1
				_go("enter" if group < groups.size() else "done")
	for w: Walker in walkers:
		w.step(dt, _limit_x(w))
	_doors()


func _go(p: String) -> void:
	gphase = p
	gphase_t = 0.0


func _all(g: Array, p: String) -> bool:
	for w: Walker in g:
		if w.phase != p:
			return false
	return true


## Start the group's mechs in order: the first at once, each next one STAGGER after the one before it, once that one
## has turned onto its lane and stands clear (farther than both turning radii from this one's alcove).
func _gate(g: Array) -> void:
	for n in g.size():
		var w: Walker = g[n]
		if w.phase != "wait":
			continue
		if n == 0:
			w.begin(t)
			return
		var prev: Walker = g[n - 1]
		if prev.phase in ["wait", "release", "out", "turn"] or t - prev.started_at < STAGGER:
			return
		var gap := Vector2(prev.pos.x - w.start.x, prev.pos.z - w.start.z).length()
		if gap <= prev.radius + w.radius + HangarBay.TURN_GAP:
			return
		w.begin(t)
		return


## How far along -x a walking mech may go now: not into the chamber while the inner door is not fully open (nor out
## while the outer one isn't), and SLOT_GAP behind the mech ahead in its lane (one that is still in the bay or chamber).
func _limit_x(w: Walker) -> float:
	var lim := -INF
	var inner_open := _inner_k() >= 0.999
	if w.phase == "walk" and not inner_open:
		lim = HangarBay.AIRLOCK_X + w.front + 0.2
	for o: Walker in walkers:
		if o == w or o.lane != w.lane or o.phase in ["wait", "release", "out", "turn", "gone"] or o.pos.x >= w.pos.x:
			continue
		var moving := o.phase in ["walk", "exit"]
		lim = maxf(lim, o.pos.x + o.back + (FOLLOW_GAP if moving else HangarBay.SLOT_GAP * 0.6) + w.front)
	return lim


func _inner_k() -> float:
	match gphase:
		"enter":
			return clampf((gphase_t - DOOR_SEAL) / DOOR_OPEN, 0.0, 1.0)
		"seal":
			return 1.0 - clampf(gphase_t / DOOR_CLOSE, 0.0, 1.0)
	return 0.0


func _outer_k() -> float:
	match gphase:
		"outer":
			return clampf((gphase_t - DOOR_SEAL) / DOOR_OPEN, 0.0, 1.0)
		"leave":
			return 1.0
		"shut":
			return 1.0 - clampf(gphase_t / DOOR_CLOSE, 0.0, 1.0)
	return 0.0


func _doors() -> void:
	if airlock == null:
		return
	airlock.inner_k = _inner_k()
	airlock.outer_k = _outer_k()
	var opening_in := gphase == "enter" and gphase_t < DOOR_SEAL + DOOR_OPEN
	airlock.inner_lamp = "cycle" if (opening_in or gphase == "seal") else ("open" if gphase == "enter" else "sealed")
	var opening_out := gphase == "outer" or (gphase == "shut" and gphase_t < DOOR_CLOSE)
	airlock.outer_lamp = "cycle" if (opening_out and gphase_t < DOOR_SEAL) or gphase == "cycle" or (gphase == "shut" and gphase_t < DOOR_CLOSE) else ("open" if gphase in ["outer", "leave"] else "sealed")
	airlock.cycling = gphase == "cycle" or (gphase == "shut" and gphase_t >= DOOR_CLOSE)


func finished() -> bool:
	return gphase == "done"


## Clamp closedness for alcove i (1 = closed): its mech's, opening as it starts.
func clamp_k(i: int) -> float:
	for w: Walker in walkers:
		if w.i == i:
			return w.clamp_k
	return 1.0


## The sequence's natural length (s): a dry run of the same plan (no models touched), cached.
func duration(bay: HangarBay) -> float:
	if _duration < 0.0:
		var d := HangarEgress.new()
		d.plan(bay, true)
		var n := 0
		while not d.finished() and n < 6000:
			d.step(1.0 / 30.0)
			n += 1
		_duration = d.t
	return _duration
