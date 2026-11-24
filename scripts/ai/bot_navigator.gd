class_name BotNavigator
extends RefCounted
## Curved-deck & flat-arena navigation helper for PlayerBot (docs/design/player-ai.md §2.3).
## Uses CityPlan.road_graph() A* in 2D arc (x, s) space, 5-ray horizontal obstacle avoidance,
## stuck-recovery sidesteps, rooftop perch discovery + thruster climb, and cover probing.
## Zero global randomness (uses caller's seeded RandomNumberGenerator).

const WHISKER_ANGLES := [0.0, 0.56, -0.56, 1.18, -1.18]   ## rad: forward, ±32°, ±68°
const STUCK_WINDOW := 1.4                                 ## s between displacement checks
const STUCK_MIN_DIST := 1.4                               ## m minimum progress when trying to move
const UNSTUCK_DUR := 1.05                                 ## s sidestep / hop duration

var plan: CityPlan
var ring: RingFrame
var _rng: RandomNumberGenerator

var _nodes: Array[Vector2] = []
var _adj: Array = []
var _roofs: Array[Dictionary] = []        ## {center_w, arc2, roof_h, size: Vector2, is_city: bool}
var _explore_points: Array[Vector2] = []
var _explore_idx := 0

var path_points: Array[Vector2] = []
var _path_timer := 0.0

var stuck_recoveries := 0
var _stuck_t := 0.0
var _stuck_anchor := Vector3.ZERO
var _unstuck_left := 0.0
var _unstuck_dir := Vector3.ZERO
var _unstuck_hop := false
var _last_climb_phase := ""


func setup(p: CityPlan, r: RingFrame, rng: RandomNumberGenerator) -> void:
	plan = p
	ring = r
	_rng = rng
	_nodes.clear()
	_adj.clear()
	_roofs.clear()
	_explore_points.clear()
	_explore_idx = 0
	path_points.clear()
	_path_timer = 0.0
	stuck_recoveries = 0
	_stuck_t = 0.0
	_unstuck_left = 0.0
	_unstuck_hop = false
	_last_climb_phase = ""
	if plan != null:
		_build_city_graph()
		_build_city_roofs()
		_build_explore_route()


## A hop-only chassis (MechController.thrust_ceiling > 0, the Bulwark): only the roofs it can hop onto (roof_h <= h)
## stay jumpable; a roof it cannot reach is never chosen as a vantage or perch.
func drop_roofs_above(h: float) -> void:
	for i in range(_roofs.size() - 1, -1, -1):
		if float(_roofs[i]["roof_h"]) > h:
			_roofs.remove_at(i)


## Register jumpable rooftops for flat arenas (where CityPlan is null).
## Each entry: {"center": Vector3 (on top surface), "size": Vector2 (x, z), "roof_h": float}.
func set_arena_roofs(roofs: Array[Dictionary]) -> void:
	_roofs.clear()
	for r: Dictionary in roofs:
		var c: Vector3 = r["center"]
		var sz: Vector2 = r.get("size", Vector2(12.0, 12.0))
		var h := float(r.get("roof_h", c.y))
		_roofs.append({"center_w": c, "arc2": Vector2(c.x, c.z), "roof_h": h, "size": sz, "is_city": false})


func reset_stuck(pos: Vector3) -> void:
	_stuck_t = 0.0
	_stuck_anchor = pos
	_unstuck_left = 0.0
	_unstuck_hop = false


func world_to_arc2(p: Vector3) -> Vector2:
	if ring != null:
		var a := ring.world_to_arc(p)
		return Vector2(a.x, a.y)
	return Vector2(p.x, p.z)


func arc2_to_world(a2: Vector2, h: float = 0.0) -> Vector3:
	if ring != null:
		return ring.arc_to_world(a2.x, a2.y, h)
	return Vector3(a2.x, h, a2.y)


func height_of(p: Vector3) -> float:
	return ring.height(p) if ring != null else p.y


# --- City Road Graph, Rooftops & Fair Exploration Route --------------------------------------------------

func _build_city_graph() -> void:
	# Where a mech can walk (streets, lanes, pedestrian streets, open courts), not road_graph()'s vehicle graph (Engine
	# 2026-11-23, for the road forms: docs/design/city-variety.md "Graphs"; same nodes / edges shape).
	var rg: Dictionary = plan.walk_graph() if plan.has_method("walk_graph") else plan.road_graph()
	for n: Vector2 in rg["nodes"]:
		_nodes.append(n)
		_adj.append([])
	for ed: Array in rg["edges"]:
		var a := int(ed[0])
		var b := int(ed[1])
		(_adj[a] as Array).append(b)
		(_adj[b] as Array).append(a)
	for l: Dictionary in plan.lots:
		if str(l["kind"]) == "open" and str(l.get("open", "")) in ["park", "plaza"]:
			var c: Vector2 = (l["rect"] as Rect2).get_center()
			var near := _nearest_node(c)
			if near >= 0:
				var idx := _nodes.size()
				_nodes.append(c)
				_adj.append([near])
				(_adj[near] as Array).append(idx)


func _build_city_roofs() -> void:
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if bool(b.get("pillar", false)):
			continue
		if int(b.get("band", 99)) > 1:
			continue     # jumpable directly from street level (bands 0 and 1)
		var c: Vector2 = b["center"]
		var best := {}
		for t: Dictionary in b.get("tiers", []):
			if not bool(t.get("stand", false)) or str(t.get("kind", "")) == "plant":
				continue
			var sz: Vector2 = t["size"]
			var y1 := float(t["y1"])
			if minf(sz.x, sz.y) >= 8.0 and y1 >= 5.5 and y1 <= 14.5:
				if best.is_empty() or y1 > float(best["y1"]):
					best = t
		if best.is_empty():
			continue
		var off: Vector2 = best["off"]
		var y1 := float(best["y1"])
		var bxf := Transform3D(CityGeo.frame_basis(ring, c.y), ring.arc_to_world(c.x, c.y, CityPlan.CURB_H))
		var top_w := bxf * Vector3(off.x, y1, off.y)
		var a2 := c + off
		_roofs.append({
			"center_w": top_w,
			"arc2": a2,
			"roof_h": y1 + CityPlan.CURB_H,
			"size": best["size"] as Vector2,
			"is_city": true,
		})


## Ordered fair exploration sweep: advance down the central avenue (+s), then sweep flanks/parks/return.
func _build_explore_route() -> void:
	if _nodes.is_empty():
		return
	var ave_fwd: Array[Vector2] = []
	var east_side: Array[Vector2] = []
	var west_side: Array[Vector2] = []
	for n in _nodes:
		if absf(n.x) <= 6.0 and n.y >= 10.0:
			ave_fwd.append(n)
		elif n.x > 6.0:
			east_side.append(n)
		else:
			west_side.append(n)
	ave_fwd.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
	east_side.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y > b.y)
	west_side.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
	for n in ave_fwd:
		_explore_points.append(n)
	for n in east_side:
		if absf(n.x) <= 75.0:
			_explore_points.append(n)
	for n in west_side:
		if absf(n.x) <= 75.0:
			_explore_points.append(n)
	if _explore_points.is_empty():
		_explore_points = _nodes.duplicate()


func next_explore_goal(from_w: Vector3) -> Vector3:
	if _explore_points.is_empty():
		return from_w
	var a2 := world_to_arc2(from_w)
	var guard := 0
	while guard < _explore_points.size():
		var pt := _explore_points[_explore_idx % _explore_points.size()]
		if a2.distance_to(pt) < 16.0:
			_explore_idx = (_explore_idx + 1) % _explore_points.size()
			guard += 1
		else:
			return arc2_to_world(pt, CityPlan.CURB_H)
	return arc2_to_world(_explore_points[0], CityPlan.CURB_H)


func _nearest_node(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _nodes.size():
		var d := p.distance_squared_to(_nodes[i])
		if d < best_d:
			best_d = d
			best = i
	return best


func find_path(from_w: Vector3, to_w: Vector3) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _nodes.is_empty():
		return out
	var from_arc := world_to_arc2(from_w)
	var to_arc := world_to_arc2(to_w)
	if from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_node(from_arc)
	var g := _nearest_node(to_arc)
	if s < 0 or g < 0 or s == g:
		return out
	var open: Array[int] = [s]
	var came := {}
	var g_score := {s: 0.0}
	var f_score := {s: _nodes[s].distance_to(_nodes[g])}
	var closed := {}
	while not open.is_empty():
		var best_i := 0
		var best_f := float(f_score.get(open[0], INF))
		for k in range(1, open.size()):
			var fk := float(f_score.get(open[k], INF))
			if fk < best_f:
				best_f = fk
				best_i = k
		var cur := open[best_i]
		if cur == g:
			var rev: Array[Vector2] = []
			var node := cur
			while came.has(node):
				rev.append(_nodes[node])
				node = int(came[node])
			rev.reverse()
			return rev
		open.remove_at(best_i)
		closed[cur] = true
		for nb: int in _adj[cur]:
			if closed.has(nb):
				continue
			var tent := float(g_score[cur]) + _nodes[cur].distance_to(_nodes[nb])
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + _nodes[nb].distance_to(_nodes[g])
				if not nb in open:
					open.append(nb)
	return out


# --- Steering, Path Following & Stuck Recovery -----------------------------------------------------------

## Follow macro A* path toward `goal_w`, apply 5-whisker obstacle avoidance, and run stuck recovery.
## Returns {"dir": Vector3 (unit in local floor plane or ZERO), "thrust": bool, "waypoint": Vector3}.
func steer_to(mech: MechController, goal_w: Vector3, dt: float, space: PhysicsDirectSpaceState3D,
		use_macro_path: bool = true) -> Dictionary:
	var up := mech.up()
	var pos := mech.global_position
	if _unstuck_left > 0.0:
		_unstuck_left -= dt
		var ud := _unstuck_dir - up * _unstuck_dir.dot(up)
		if ud.length_squared() > 1e-4:
			ud = ud.normalized()
		return {"dir": ud, "thrust": _unstuck_hop and _unstuck_left > UNSTUCK_DUR * 0.55, "waypoint": goal_w}

	var steer_goal := goal_w
	if use_macro_path and not _nodes.is_empty():
		_path_timer -= dt
		if _path_timer <= 0.0:
			_path_timer = 1.0
			path_points = find_path(pos, goal_w)
		while not path_points.is_empty():
			var wp := arc2_to_world(path_points[0], CityPlan.CURB_H)
			var flat_d := (wp - pos) - up * (wp - pos).dot(up)
			if flat_d.length() < 9.0:
				path_points.pop_front()
			else:
				steer_goal = wp
				break

	var raw := steer_goal - pos
	raw -= up * raw.dot(up)
	if raw.length_squared() < 1.0:
		_stuck_t = 0.0
		_stuck_anchor = pos
		return {"dir": Vector3.ZERO, "thrust": false, "waypoint": steer_goal}

	var dir := avoid_obstacles(mech, raw.normalized(), space, up)

	# Stuck detection: only when grounded and intending to move.
	_stuck_t += dt
	if _stuck_t >= STUCK_WINDOW:
		var moved := pos.distance_to(_stuck_anchor)
		if moved < STUCK_MIN_DIST and mech.grounded():
			stuck_recoveries += 1
			var side_sign := 1.0 if (_rng == null or _rng.randi() % 2 == 0) else -1.0
			_unstuck_dir = (dir.rotated(up, side_sign * 1.45) - dir * 0.35).normalized()
			_unstuck_left = UNSTUCK_DUR
			_unstuck_hop = mech.heat / maxf(mech.heat_cap, 1.0) < 0.65
		_stuck_t = 0.0
		_stuck_anchor = pos

	return {"dir": dir, "thrust": false, "waypoint": steer_goal}


func avoid_obstacles(mech: MechController, want_dir: Vector3, space: PhysicsDirectSpaceState3D, up: Vector3) -> Vector3:
	if space == null or want_dir.length_squared() < 1e-4:
		return want_dir
	var dir := (want_dir - up * want_dir.dot(up)).normalized()
	var origin := mech.global_position + up * 3.8
	var probe_d := 8.5
	var excl := [mech.get_rid()]
	if not _ray_wall(space, origin, origin + dir * probe_d, up, excl):
		return dir
	var best_dir := dir
	var best_score := -INF
	for ang: float in WHISKER_ANGLES:
		if absf(ang) < 0.01:
			continue
		var cand := dir.rotated(up, ang)
		var hit_d := _ray_wall_dist(space, origin, origin + cand * probe_d, up, excl)
		var align := cand.dot(dir)
		var score := hit_d + align * 3.5
		if score > best_score:
			best_score = score
			best_dir = cand
	return best_dir


func _ray_wall(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, up: Vector3, excl: Array) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = excl
	var h := space.intersect_ray(q)
	return not h.is_empty() and absf((h["normal"] as Vector3).dot(up)) < 0.68


func _ray_wall_dist(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, up: Vector3, excl: Array) -> float:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = excl
	var h := space.intersect_ray(q)
	if h.is_empty() or absf((h["normal"] as Vector3).dot(up)) >= 0.68:
		return a.distance_to(b)
	return a.distance_to(h["position"] as Vector3)


# --- Rooftop Vantage & Thruster Climb --------------------------------------------------------------------

func find_rooftop_vantage(from_w: Vector3, enemy_w: Vector3, enemy_fwd: Vector3, enemy_type: String,
		max_dist: float = 42.0) -> Dictionary:
	var best := {}
	var best_score := -INF
	for r: Dictionary in _roofs:
		var cw: Vector3 = r["center_w"]
		var d_me := from_w.distance_to(cw)
		if d_me > max_dist:
			continue
		var d_en := cw.distance_to(enemy_w)
		if d_en < 14.0 or d_en > 88.0:
			continue
		var score := 50.0 - d_me * 0.9 - absf(d_en - 38.0) * 0.45
		if enemy_type == "tank":
			# Prefer rooftops behind or flanking the tank to expose its rear/top vents!
			var to_roof := (cw - enemy_w).normalized()
			var rear_bonus := -enemy_fwd.dot(to_roof)   # +1 directly behind tank, -1 directly in front
			score += rear_bonus * 28.0
		if score > best_score:
			best_score = score
			best = r
	return best


## Drive a controlled thruster jump onto `perch` using real MechController inputs.
## Returns {"dir": Vector3, "thrust": bool, "running": bool, "reached": bool, "aborted": bool}.
func step_rooftop_climb(mech: MechController, perch: Dictionary, up: Vector3, heat_frac: float) -> Dictionary:
	if perch.is_empty() or mech.shutdown or heat_frac >= 0.80:
		return {"dir": Vector3.ZERO, "thrust": false, "running": false, "reached": false, "aborted": true}
	var pos := mech.global_position
	var cw: Vector3 = perch["center_w"]
	var sz: Vector2 = perch["size"]
	var roof_h := float(perch["roof_h"])
	var my_h := height_of(pos)
	var to_c := cw - pos
	var flat_c := to_c - up * to_c.dot(up)
	var flat_dist := flat_c.length()
	var half_rad := minf(sz.x, sz.y) * 0.5

	# Already standing on top of this roof!
	if my_h >= roof_h - 0.8 and flat_dist <= maxf(sz.x, sz.y) * 0.52 and mech.grounded():
		return {"dir": Vector3.ZERO, "thrust": false, "running": false, "reached": true, "aborted": false}

	var dir := flat_c.normalized() if flat_dist > 0.2 else Vector3.ZERO
	var edge_dist := flat_dist - half_rad
	# Approach the building edge before igniting thrusters so we don't waste heat far away.
	if edge_dist > 9.5 and my_h < roof_h - 1.5:
		_last_climb_phase = "approach"
		return {"dir": dir, "thrust": false, "running": true, "reached": false, "aborted": false}

	# Within jump envelope: ignite thrusters until ballistic apex clears parapet, then glide onto the roof deck.
	var vy := mech.velocity.dot(up)
	var apex_h := my_h + ((vy * vy) / (2.0 * maxf(mech.gravity, 1.0)) if vy > 0.0 else 0.0)
	var need_lift := my_h < roof_h + 0.5 and apex_h < roof_h + 1.2
	if need_lift:
		_last_climb_phase = "lift"
		# Hold slight inward push while rising so we clear the wall lip cleanly once above roof_h.
		var push := dir if (my_h >= roof_h - 2.5 or edge_dist > 2.2) else -dir * 0.25
		return {"dir": push, "thrust": true, "running": false, "reached": false, "aborted": false}

	# Above roof height: glide horizontally onto the roof surface and drop gently.
	_last_climb_phase = "land"
	return {"dir": dir, "thrust": false, "running": false, "reached": false, "aborted": false}


# --- Cover Probing ---------------------------------------------------------------------------------------

## Find a nearby point (10..26 m away) that breaks physics LOS from `threat_eye`. Returns Vector3(NAN,NAN,NAN) if none.
func find_cover_point(mech: MechController, threat_eye: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	if space == null:
		return Vector3(NAN, NAN, NAN)
	var up := mech.up()
	var pos := mech.global_position
	var to_t := threat_eye - pos
	to_t -= up * to_t.dot(up)
	if to_t.length_squared() < 1.0:
		return Vector3(NAN, NAN, NAN)
	var fwd := to_t.normalized()
	var excl := [mech.get_rid()]
	var angles := [1.1, -1.1, 1.75, -1.75, 2.35, -2.35, PI]
	var dists := [12.0, 20.0]
	var best := Vector3(NAN, NAN, NAN)
	var best_d := INF
	for dist: float in dists:
		for ang: float in angles:
			var cand_dir := fwd.rotated(up, ang)
			var cand := pos + cand_dir * dist
			# Must be reachable (no wall immediately blocking straight walk) and break LOS at mech torso height.
			if _ray_wall(space, pos + up * 3.5, cand + up * 3.5, up, excl):
				continue
			var q := PhysicsRayQueryParameters3D.create(threat_eye, cand + up * 4.5)
			q.exclude = excl
			var h := space.intersect_ray(q)
			if not h.is_empty():
				var hd := threat_eye.distance_to(h["position"] as Vector3)
				if hd < threat_eye.distance_to(cand + up * 4.5) - 2.5:
					if dist < best_d:
						best_d = dist
						best = cand
	return best
