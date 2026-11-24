extends TestCase
## The map is sealed: a mech cannot leave a deck through its boundary walls (playtest, section seed 403112: "you can fall
## out of the open portal off the edge of the map"). On the real stack of a few sections, with a MissionWorld wave door in
## most blast-door gates, the real mech capsule (MechSpawn) is swept with physics queries:
## - through every boundary-wall gate of every kind (portal, blast door with no mission door, mission door open / shut /
##   sealed, collapsed), straight out and at lateral offsets and angles, at walking height and at a hop under the lintel:
##   it gets no further than the gate's recess (CityStreets.GATE_RECESS behind the wall plane; an open mission door: its
##   staging bay, GateDoor.BAY_DEPTH; a solid gate: not past the wall plane) and there is floor under where it stops;
## - inside every open staging bay: pushed at the sides, the back and the roof (at walking height, at roof height and
##   straight up, at angles) it stays in the bay; floor under every stop and everywhere on a 2 m grid (no step: within
##   5 cm of the deck's faceted floor); from the usable floor in line with the door it rolls straight out to the street;
## - the bunker frame (jambs, lintel, sign pier) is solid and no sweep along the wall gets behind it;
## - along the whole perimeter of every deck, every PERIM_STEP m, pushed outward 30 m at two heights: stopped at the wall.
## Floor openings inside a deck (ramp cuts, shafts) are not this test's business.

const SEEDS := [403112, 1, 4, 7]
const MARGIN := 0.5             ## m of slack past a limit (capsule contact tolerance)
const STEP := 2.0               ## m per cast: the sweep re-frames on the ring's curve each step
const PUSH := 30.0              ## m pushed outward
const PERIM_STEP := 10.0
const WALK_H := 0.5             ## capsule foot above the floor
const ANGLES := [0.0, 25.0, -25.0, 45.0, -45.0]
const LATERAL := [0.0, -1.0, -0.5, 0.5, 1.0]

var cap: CapsuleShape3D
var cap_h := 0.0
var space: PhysicsDirectSpaceState3D
var kinds_seen := {}
var blocked_at_start := 0


func setup() -> void:
	timeout_sec = 240.0
	var m := MechSpawn.make()
	var src := (m.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	cap = CapsuleShape3D.new()
	cap.radius = src.radius
	cap.height = src.height
	cap_h = src.height
	m.free()
	print("[sealed] mech capsule r %.2f h %.2f" % [cap.radius, cap.height])
	for seed_ in SEEDS:
		await _section(seed_)
	for k in ["portal", "blast_door", "door_open", "door_shut", "door_sealed", "collapsed", "bay_inside", "air_open", "air_shut"]:
		check(kinds_seen.has(k), "the sweep met a gate of kind %s" % k)
	print("[sealed] gate kinds swept: %s; perimeter samples that started inside something: %d" % [str(kinds_seen), blocked_at_start])
	finish()


func _section(seed_: int) -> void:
	var t0 := Time.get_ticks_msec()
	var sec := SectionPlan.make({"seed": seed_})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	# A wave door in every blast-door gate but the first of each deck (that one keeps the district's own solid wall).
	var sources := []
	var role := {}         # source id -> "open" | "shut" | "sealed"
	for k in stack.decks.size():
		var first := true
		for w: Dictionary in stack.decks[k].plan.boundary():
			for g: Dictionary in w["gates"]:
				if str(g["kind"]) != "blast_door":
					continue
				if first:
					first = false
					continue
				var mid := (float(g["a"]) + float(g["b"])) * 0.5
				var at := float(w["at"])
				var id := "g%d_%d_%.1f" % [k, int(w["side"]), float(g["a"])]
				sources.append({"id": id, "deck": k, "kind": "gate", "edge": CityPlan.SIDE_EDGE[int(w["side"])],
						"x": mid if int(w["side"]) >= 2 else at, "s": at if int(w["side"]) >= 2 else mid})
				role[id] = "open"
	var mw := stack.setup_mission({"sources": sources, "objectives": [], "pools": []})
	var ids: Array = mw._doors.keys()
	if ids.size() >= 3:
		role[ids[0]] = "shut"
		role[ids[1]] = "sealed"
	# Air doors (MissionWorld derives them from the stack): the first one shut, the rest open.
	var air_shut := ""
	for id: Variant in ids:
		if str(mw._sources[id].get("kind", "")) == "air":
			if air_shut == "":
				air_shut = str(id)
				role[id] = "shut"
			else:
				role[id] = "open"
	var base := 100.0
	mw.advance_to(base)
	for id: Variant in ids:
		match str(role.get(id, "shut")):
			"open": mw.open_source(id, base + 6.0, 600.0)
			"sealed": mw.close_source(id)
	mw.advance_to(base + 6.0 + MissionWorld.OPENING + 1.0)     # open_at is when the leaves start to move
	await get_tree().physics_frame
	await get_tree().physics_frame
	space = stack.get_world_3d().direct_space_state
	# door key "<side>:<a>" -> state, per deck
	var doors := {}
	for id: Variant in ids:
		var door := mw._doors[id] as MissionProps.GateDoor
		var st := str(mw.source_state(id)["state"])
		eq(door.door_shape.disabled, st == "open", "seed %d %s: the door shape is off only when open (%s)" % [seed_, id, st])
		doors[door] = st
	var gates := 0
	var perim := 0
	for k in stack.decks.size():
		var d := stack.decks[k]
		for w: Dictionary in d.plan.boundary():
			for g: Dictionary in w["gates"]:
				gates += 1
				var ds := _door_state(d, w, g, mw)
				_gate(seed_, d, w, g, ds)
				if ds == "open":
					_bay_inside(seed_, d, _door_of(d, w, g, mw))
				if ds != "":
					_bunker(seed_, d, _door_of(d, w, g, mw))
			perim += _perimeter(seed_, d, w, mw)
	for id: Variant in ids:
		if str(mw._sources[id].get("kind", "")) == "air":
			_air_door(seed_, mw, str(id), str(mw.source_state(id)["state"]))
	print("[sealed] seed %d: %d decks, %d gates, %d perimeter samples, %d doors, %d ms" % [seed_, stack.decks.size(), gates, perim,
			ids.size(), Time.get_ticks_msec() - t0])
	stack.queue_free()
	await frames(2)


## "" when gate g of wall w has no mission door, else its state (open / shut / sealed ...).
func _door_state(d: CityDistrict, w: Dictionary, g: Dictionary, mw: MissionWorld) -> String:
	for id: Variant in mw._doors:
		var door := mw._doors[id] as MissionProps.GateDoor
		if door == null or door.get_parent() != d:
			continue
		if door.transform.is_equal_approx(MissionProps.gate_frame(d, w, g)):
			return str(mw.source_state(id)["state"])
	return ""


func _door_of(d: CityDistrict, w: Dictionary, g: Dictionary, mw: MissionWorld) -> MissionProps.GateDoor:
	for id: Variant in mw._doors:
		var door := mw._doors[id] as MissionProps.GateDoor
		if door != null and door.get_parent() == d and door.transform.is_equal_approx(MissionProps.gate_frame(d, w, g)):
			return door
	return null


## Outward unit direction (in arc x, s) of wall side `side`, and the wall plane's coordinate along it.
func _out(w: Dictionary) -> Vector2:
	match int(w["side"]):
		0: return Vector2(1, 0)
		1: return Vector2(-1, 0)
		2: return Vector2(0, 1)
	return Vector2(0, -1)


## Arc point at `u` along wall w, `depth` m beyond its plane (negative: inside the map).
func _wall_point(w: Dictionary, u: float, depth: float) -> Vector2:
	var at := float(w["at"])
	var o := _out(w)
	if int(w["side"]) >= 2:
		return Vector2(u, at + o.y * depth)
	return Vector2(at + o.x * depth, u)


func _beyond(w: Dictionary, p: Vector2) -> float:
	var o := _out(w)
	return (p.x if int(w["side"]) < 2 else p.y) * (o.x + o.y) - float(w["at"]) * (o.x + o.y)


func _gate(seed_: int, d: CityDistrict, w: Dictionary, g: Dictionary, door: String) -> void:
	var kind := str(g["kind"])
	var tag := kind
	if kind == "blast_door" and door != "":
		tag = "door_" + door
	kinds_seen[tag] = int(kinds_seen.get(tag, 0)) + 1
	var open := kind == "portal" or door == "open"
	var limit := (CityStreets.GATE_RECESS if open else 0.0) + MARGIN
	if door == "open":
		limit = MissionProps.GateDoor.BAY_DEPTH + MARGIN
	var a := float(g["a"])
	var b := float(g["b"])
	var gh := float(g["h"])
	var half := (b - a) * 0.5
	var mid := (a + b) * 0.5
	var o := _out(w)
	var heights := [WALK_H]
	if gh - cap_h - 0.3 > WALK_H + 0.5:
		heights.append(gh - cap_h - 0.3)
	var label := "seed %d deck %d side %d gate %s @%.0f (%s)" % [seed_, d.plan.deck, int(w["side"]), tag, mid, "open" if open else "solid"]
	var worst := -INF
	var entered := -INF
	for h: float in heights:
		for f: float in LATERAL:
			var u := mid + f * maxf(half - cap.radius - 0.1, 0.0)
			var start := _wall_point(w, u, -(cap.radius + 1.0))
			for ang: float in ANGLES:
				var dir := o.rotated(deg_to_rad(ang))
				var p := _push(d, start, h, dir, PUSH)
				var bey := _beyond(w, p)
				worst = maxf(worst, bey)
				if f == 0.0 and ang == 0.0:
					entered = maxf(entered, bey)
				if bey > limit:
					_fail("%s: the capsule got %.1f m past the wall plane (limit %.1f) from u %.1f h %.1f angle %.0f" % [label, bey, limit, u, h, ang])
				elif not _floor_under(d, p):
					_fail("%s: no floor under where the capsule stopped (%.1f m past the wall plane, u %.1f angle %.0f)" % [label, bey, u, ang])
	# Not a vacuous pass: through an open gate the mech really steps into the recess.
	if open and entered <= 1.0:
		print("[sealed] %s: blocked by %s" % [label, _blocker(d, _wall_point(w, mid, -(cap.radius + 1.0)), WALK_H, o)])
	if open:
		check(entered > 1.0,"%s: the capsule steps into the open recess (%.1f m past the wall plane)" % [label, entered])
	print("[sealed] %s: furthest %.1f m past the wall plane (limit %.1f)" % [label, worst, limit])


## Every PERIM_STEP m along wall w, pushed straight out PUSH m at two heights: stopped at the wall (inside a gate span:
## within the recess). Returns the number of samples.
func _perimeter(seed_: int, d: CityDistrict, w: Dictionary, mw: MissionWorld) -> int:
	var e := d.plan.extent
	var across := int(w["side"]) >= 2
	var u0 := e.position.x if across else e.position.y
	var u1 := e.end.x if across else e.end.y
	var n := 0
	var u := u0 + PERIM_STEP * 0.5
	while u < u1:
		var limit := MARGIN
		for g: Dictionary in w["gates"]:
			if u > float(g["a"]) - cap.radius and u < float(g["b"]) + cap.radius:
				limit = maxf(limit, (MissionProps.GateDoor.BAY_DEPTH if _door_state(d, w, g, mw) == "open" else CityStreets.GATE_RECESS) + MARGIN)
		for h: float in [WALK_H, 6.0]:
			var start := _wall_point(w, u, -(cap.radius + 1.0))
			var p := _push(d, start, h, _out(w), PUSH)
			if p == start:
				blocked_at_start += 1
			var bey := _beyond(w, p)
			if bey > limit:
				_fail("seed %d deck %d side %d perimeter u %.1f h %.1f: the capsule got %.1f m past the wall plane (limit %.1f)"
						% [seed_, d.plan.deck, int(w["side"]), u, h, bey, limit])
			elif not _floor_under(d, p):
				_fail("seed %d deck %d side %d perimeter u %.1f: no floor under where the capsule stopped" % [seed_, d.plan.deck, int(w["side"]), u])
			n += 1
		u += PERIM_STEP
	return n


## Inside an open staging bay (door frame coordinates; the capsule foot WALK_H above the faceted floor there): pushed out
## at the sides, the back, at roof height and straight up, it stays inside; floor under every stop and on a 2 m grid; from
## the usable floor in line with the opening it rolls straight out past the wall plane to the street.
func _bay_inside(seed_: int, d: CityDistrict, door: MissionProps.GateDoor) -> void:
	if door == null:
		return
	kinds_seen["bay_inside"] = int(kinds_seen.get("bay_inside", 0)) + 1
	var label := "seed %d deck %d bay @%s" % [seed_, d.plan.deck, str(door.arc_mid.snapped(Vector2.ONE))]
	var mid := (MissionProps.GateDoor.USE_FROM + MissionProps.GateDoor.USE_TO) * 0.5
	var hi := door.clear_height() - cap_h - 0.4      # a hop: the capsule's top just under the light bars
	var lim_x := door.ihalf + MARGIN
	var lim_z := MissionProps.GateDoor.BAY_DEPTH + MARGIN
	var worst_x := 0.0
	var worst_z := 0.0
	for h: float in [WALK_H, hi]:
		for depth: float in [MissionProps.GateDoor.USE_FROM + 1.0, mid, MissionProps.GateDoor.USE_TO - 1.0]:
			for k: float in [-1.0, 1.0]:
				for ang: float in [0.0, 30.0, -30.0, 60.0]:
					var dir := Vector2(k, 0).rotated(deg_to_rad(ang))
					var p := _push_local(d, door, Vector2(0.0, depth), h, dir, 40.0)
					worst_x = maxf(worst_x, absf(p.x))
					if (absf(p.x) > lim_x and p.y > -0.5) or p.y > lim_z:      # back on the street (p.y < 0) is fine
						_fail("%s: pushed out at (0, %.0f) h %.1f dir %s it reached (%.1f, %.1f)" % [label, depth, h, str(dir), p.x, p.y])
					elif not _floor_under_local(d, door, p):
						_fail("%s: no floor under the stop (%.1f, %.1f)" % [label, p.x, p.y])
		for lx: float in [0.0, -(door.ihalf - 3.0), door.ihalf - 3.0]:
			for ang: float in [0.0, 30.0, -30.0]:
				var p := _push_local(d, door, Vector2(lx, mid), h, Vector2(0, 1).rotated(deg_to_rad(ang)), 40.0)
				worst_z = maxf(worst_z, p.y)
				if p.y > lim_z or (absf(p.x) > lim_x and p.y > -0.5):
					_fail("%s: pushed back from (%.0f, %.0f) h %.1f angle %.0f it reached (%.1f, %.1f)" % [label, lx, mid, h, ang, p.x, p.y])
				elif not _floor_under_local(d, door, p):
					_fail("%s: no floor under the stop (%.1f, %.1f)" % [label, p.x, p.y])
		check(worst_z > MissionProps.GateDoor.BAY_DEPTH - cap.radius - 1.5, "%s: the capsule reaches the bay's back (%.1f m)" % [label, worst_z])
	# Straight up from the floor: the roof stops it.
	var geo := CityGeo.new(d.ring)
	for at: Vector2 in [Vector2(0, mid), Vector2(door.ihalf - 3.0, MissionProps.GateDoor.USE_TO - 1.0)]:
		var f := _local_frame(d, door, at, WALK_H)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = cap
		q.transform = f * Transform3D(Basis.IDENTITY, Vector3(0, cap_h * 0.5, 0))
		q.motion = f.basis.y * 40.0
		var r := space.cast_motion(q)
		var rise := 40.0 * r[0] + WALK_H + cap_h
		check(r[0] < 1.0 and rise < MissionProps.GateDoor.BAY_H + MissionProps.GateDoor.PLATE, "%s: straight up the capsule stops at the roof (top %.1f m)" % [label, rise])
	# Floor on a 2 m grid, flush with the deck's faceted floor.
	var bad := 0
	var lx := -door.ihalf + 0.5
	while lx < door.ihalf:
		var dz := 0.5
		while dz < MissionProps.GateDoor.BAY_DEPTH:
			if dz >= CityStreets.WALL_THICK or absf(lx) < door.w_out - 0.3:
				var a := door.arc(lx, dz)
				var top := d.global_transform * geo.g_point(a.x, a.y, 2.0)
				var expect := d.global_transform * geo.g_point(a.x, a.y, 0.0)
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, d.global_transform * geo.g_point(a.x, a.y, -1.0)))
				if hit.is_empty() or (hit["position"] as Vector3).distance_to(expect) > 0.05:
					bad += 1
					if bad <= 3:
						_fail("%s: floor missing or not flush at (%.1f, %.1f): %s" % [label, lx, dz, str(hit.get("position"))])
			dz += 2.0
		lx += 2.0
	# Roll out: from the usable floor in line with the opening straight to the street (6 m in front of the door).
	var lane := minf(door.ihalf - MissionProps.GateDoor.MARGIN, door.half - cap.radius - 0.3)     # between the bunker's jambs
	for lx2: float in [-lane, 0.0, lane]:
		for depth: float in [MissionProps.GateDoor.USE_FROM, mid, MissionProps.GateDoor.USE_TO]:
			var p := _push_local(d, door, Vector2(lx2, depth), WALK_H, Vector2(0, -1), depth + 6.0)
			if p.y > -5.9:
				_fail("%s: rolling out from (%.1f, %.0f) the capsule stopped at (%.1f, %.1f)" % [label, lx2, depth, p.x, p.y])
	print("[sealed] %s: inside, furthest side %.1f (limit %.1f), back %.1f (limit %.1f), roll-out lane +-%.1f" % [label, worst_x, lim_x,
			worst_z, lim_z, lane])


## The bunker frame is solid: a capsule pushed along the wall in front of it (1 m out) is stopped by a jamb / the pier,
## and a capsule hopping into the lintel from the street is stopped by it.
func _bunker(seed_: int, d: CityDistrict, door: MissionProps.GateDoor) -> void:
	if door == null:
		return
	var label := "seed %d deck %d bunker @%s" % [seed_, d.plan.deck, str(door.arc_mid.snapped(Vector2.ONE))]
	var far := door.half + MissionProps.GateDoor.JAMB + MissionProps.GateDoor.BUTT + 14.0
	for k: float in [-1.0, 1.0]:
		var p := _push_local(d, door, Vector2(k * far, -(cap.radius + 0.3)), WALK_H, Vector2(-k, 0), far)
		check(absf(p.x) > door.half + MissionProps.GateDoor.JAMB - 0.1, "%s: walking along the wall from %s the frame stops the capsule (at %.1f)" % [label, "+X" if k > 0 else "-X", p.x])
	var top := door.gh + 0.6
	var f := _local_frame(d, door, Vector2(0, -(cap.radius + MissionProps.GateDoor.FRAME_OUT + 1.0)), top)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = f * Transform3D(Basis.IDENTITY, Vector3(0, cap_h * 0.5, 0))
	q.motion = -f.basis.z * 6.0
	check(space.cast_motion(q)[0] < 1.0, "%s: the lintel is solid" % label)


## An air door (high on an end wall; its frame's origin at the opening's sill, mid-opening, +Z into the deck). Shut: a
## 1 m sphere (anything small; a mech's 8 m capsule cannot fit the 6 m opening) pushed in from 3 m in front stops at the
## wall plane. Open: from the recess's middle, pushed at the sides, the back, up and down (straight and at angles), it
## stays in the recess; the mech capsule pushed in at the sill from the street gets no further than the wall plane + 1 m.
func _air_door(seed_: int, mw: MissionWorld, id: String, state: String) -> void:
	kinds_seen["air_" + state] = int(kinds_seen.get("air_" + state, 0)) + 1
	var door := mw._doors[id] as MissionProps.GateDoor
	var fr := door.global_transform
	var label := "seed %d %s (%s)" % [seed_, id, state]
	var ball := SphereShape3D.new()
	ball.radius = 1.0
	var mid := door.gh * 0.5
	if state != "open":
		var p := _cast_local(fr, ball, Vector3(0, mid, 3.0), Vector3(0, 0, -1), 30.0)
		check(p.z > -0.5, "%s: shut, a small body stops at the wall plane (z %.1f)" % [label, p.z])
		return
	var worst := Vector3.ZERO
	for dir: Vector3 in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(0, -1, 0),
			Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized(), Vector3(1, 1, -1).normalized(), Vector3(-1, -1, -1).normalized()]:
		for start: Vector3 in [Vector3(0, mid, -MissionWorld.AIR_DEPTH * 0.5), Vector3(0, mid, -3.0)]:
			var p := _cast_local(fr, ball, start, dir, 40.0)
			worst = Vector3(maxf(worst.x, absf(p.x)), maxf(worst.y, p.y), minf(worst.z, p.z))
			if absf(p.x) > door.ihalf + 0.5 or p.z < -MissionWorld.AIR_DEPTH - 0.5 or p.y > door.room_h + 0.5 or p.y < -0.5:
				_fail("%s: a small body pushed %s from %s got out of the recess to %s" % [label, str(dir), str(start), str(p)])
	check(worst.z < -MissionWorld.AIR_DEPTH + 2.0, "%s: it reaches the recess's back (%.1f)" % [label, worst.z])
	var cp := _cast_local(fr, cap, Vector3(0, 0.2 + cap_h * 0.5, 4.0), Vector3(0, 0, -1), 30.0)
	check(cp.z > -1.0 - cap.radius, "%s: the mech capsule does not fit in (stopped at z %.1f)" % [label, cp.z])
	print("[sealed] %s: inside |x| <= %.1f (limit %.1f), y <= %.1f (limit %.1f), back %.1f (limit %.1f)" % [label, worst.x, door.ihalf,
			worst.y, door.room_h, worst.z, -MissionWorld.AIR_DEPTH])


## Cast `shape` from `start` (in frame fr, its centre) along `dir` (frame) up to `dist`: where its centre stops (frame).
func _cast_local(fr: Transform3D, shape: Shape3D, start: Vector3, dir: Vector3, dist: float) -> Vector3:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(fr.basis.orthonormalized(), fr * start)
	q.motion = fr.basis.orthonormalized() * dir * dist
	var r := space.cast_motion(q)
	return start + dir * dist * r[0]


## The ring frame (global) at door-local floor point `at` = (x along the wall, depth behind the wall plane), `h` above the
## faceted floor, oriented like the door.
func _local_frame(d: CityDistrict, door: MissionProps.GateDoor, at: Vector2, h: float) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	var a := door.arc(at.x, at.y)
	var o := d.global_transform * geo.g_point(a.x, a.y, h)
	return Transform3D((d.global_transform * door.transform).basis.orthonormalized(), o)


## Sweep the capsule in the door's frame from `from` (x, depth) along `dir` (x, depth: +y deeper into the bay) up to
## `dist` m, STEP m per cast, re-seated on the floor each step. Returns where it stopped (x, depth).
func _push_local(d: CityDistrict, door: MissionProps.GateDoor, from: Vector2, h: float, dir: Vector2, dist: float) -> Vector2:
	var p := from
	var gone := 0.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	while gone < dist - 0.001:
		var step := minf(STEP, dist - gone)
		var f := _local_frame(d, door, p, h)
		q.transform = f * Transform3D(Basis.IDENTITY, Vector3(0, cap_h * 0.5, 0))
		q.motion = f.basis * Vector3(dir.x, 0, -dir.y) * step
		var r := space.cast_motion(q)
		p += dir * step * r[0]
		gone += step
		if r[0] < 1.0:
			break
	return p


func _floor_under_local(d: CityDistrict, door: MissionProps.GateDoor, p: Vector2) -> bool:
	var a := door.arc(p.x, p.y)
	return _floor_under(d, a)


## Sweep the capsule from arc point `from` (foot `h` above the floor) along `dir` (arc x, s) up to `dist` m, re-framing on
## the ring every STEP m. Returns the arc point where it stopped (or the end).
func _push(d: CityDistrict, from: Vector2, h: float, dir: Vector2, dist: float) -> Vector2:
	var geo := CityGeo.new(d.ring)
	var p := from
	var gone := 0.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	while gone < dist - 0.001:
		var step := minf(STEP, dist - gone)
		var f := d.global_transform * geo.frame(p.x, p.y, h)
		q.transform = f * Transform3D(Basis.IDENTITY, Vector3(0, cap_h * 0.5, 0))
		q.motion = f.basis * Vector3(dir.x, 0, dir.y) * step
		var r := space.cast_motion(q)
		p += dir * step * r[0]
		gone += step
		if r[0] < 1.0:
			break
	return p


## What stops the capsule pushed from `from` along `dir` (for the log): "<node path> shape <i>".
func _blocker(d: CityDistrict, from: Vector2, h: float, dir: Vector2) -> String:
	var p := _push(d, from, h, dir, PUSH)
	var geo := CityGeo.new(d.ring)
	var f := d.global_transform * geo.frame(p.x, p.y, h)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = f * Transform3D(Basis.IDENTITY, Vector3(0, cap_h * 0.5, 0))
	q.motion = f.basis * Vector3(dir.x, 0, dir.y) * 0.5
	var r := space.cast_motion(q)
	q.transform.origin += q.motion * minf(r[1] + 0.02, 1.0)
	q.motion = Vector3.ZERO
	var out := []
	for hit: Dictionary in space.intersect_shape(q, 4):
		var obj := hit["collider"] as Node
		var cs := (obj as CollisionObject3D).shape_owner_get_owner((obj as CollisionObject3D).shape_find_owner(int(hit["shape"]))) as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else cs.shape
		var arc := d.ring.world_to_arc(d.to_local(cs.global_position))
		out.append("%s/%s size %s at arc %s" % [str(obj.get_path()).get_file(), cs.name, str(sz), str(arc)])
	return ", ".join(out)


## A floor within 1 m under arc point p (a ray from 2 m up to 1 m down).
func _floor_under(d: CityDistrict, p: Vector2) -> bool:
	var geo := CityGeo.new(d.ring)
	var a := d.global_transform * geo.g_point(p.x, p.y, 2.0)
	var b := d.global_transform * geo.g_point(p.x, p.y, -1.0)
	return not space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b)).is_empty()
