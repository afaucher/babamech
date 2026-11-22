class_name EnemySquad
extends Node3D
## Host-owned squad coordinator (docs/design/enemies.md §5, §6):
##   - Shared last-known-position target board fed ONLY by real LOS sightings.
##   - Delayed alert propagation (0.45 s relay from spotter to squadmates within RELAY_RADIUS).
##   - Attack-slot arbiter (max `max_attackers` firing at one target simultaneously, fair priority rotation).
##   - Lightweight A* pathfinder over CityPlan.road_graph() in 2D arc (x, s) space.
##   - Unified Audio event bus: joins group "enemy_squad" and emits `enemy_event(kind, enemy, payload)`.

const RELAY_RADIUS := 52.0
const MEMORY_TIME := 14.0         ## s before a target drops off the shared target board
const SEP_MARGIN := 2.6           ## m extra separation between mobile squadmates
const MAX_WRECKS := 10            ## LRU cap on persistent charred/flaming wrecks per squad

signal enemy_spawned(enemy: EnemyBase)
signal enemy_removed(enemy: EnemyBase)
signal enemy_event(kind: String, enemy: Node, payload: Dictionary)

var world: CombatWorld
var plan: CityPlan
var ring: RingFrame
var max_attackers := 2            ## max simultaneous telegraphing/firing enemies per player target
var slot_stagger := 0.8           ## s breathing gap after a burst before another enemy grabs the slot
var enemies: Array[EnemyBase] = []
var debris_field: EnemyDebrisField
var known_targets: Dictionary = {} ## target_id -> {target, pos, arc, last_seen, seen_by}
var _wrecks: Array[EnemyBase] = []
var _slots: Dictionary = {}        ## enemy_id -> target_id
var _last_slot_time: Dictionary = {} ## enemy_id -> combat clock when it last held a slot
var _slot_ready_at := 0.0          ## combat clock when the next attack slot may be granted
var _graph_nodes: Array[Vector2] = []
var _graph_adj: Array = []


func _init() -> void:
	name = "EnemySquad"
	add_to_group("enemy_squad")


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "plan": Net.SPAWN, "ring": Net.SPAWN, "max_attackers": Net.SPAWN,
		"slot_stagger": Net.SPAWN, "enemies": Net.LOCAL, "debris_field": Net.LOCAL, "known_targets": Net.OWNER,
		"_wrecks": Net.LOCAL, "_slots": Net.OWNER, "_last_slot_time": Net.PRIVATE, "_slot_ready_at": Net.PRIVATE,
		"_graph_nodes": Net.LOCAL, "_graph_adj": Net.LOCAL}


func setup(w: CombatWorld, p: CityPlan = null, r: RingFrame = null) -> void:
	if world != null and is_instance_valid(world) and world.advanced.is_connected(_on_world_advanced):
		world.advanced.disconnect(_on_world_advanced)
	world = w
	plan = p
	ring = r
	if world != null:
		if ring != null:
			world.ring = ring
		if not world.advanced.is_connected(_on_world_advanced):
			world.advanced.connect(_on_world_advanced)
	_ensure_debris_field()
	EnemyMeshes.prewarm()
	_build_nav_graph()


func _ensure_debris_field() -> EnemyDebrisField:
	if debris_field == null or not is_instance_valid(debris_field):
		debris_field = EnemyDebrisField.new()
		debris_field.ring = ring
		add_child(debris_field)
	else:
		debris_field.ring = ring
	return debris_field


func get_debris_field() -> EnemyDebrisField:
	return _ensure_debris_field()


func _on_world_advanced(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if debris_field != null and is_instance_valid(debris_field):
		debris_field.tick(dt, space)


func clear_enemies() -> void:
	for e in enemies.duplicate():
		if is_instance_valid(e):
			if world != null:
				world.unregister(e)
			enemy_removed.emit(e)
			e.queue_free()
	for w_e in _wrecks.duplicate():
		if is_instance_valid(w_e) and not w_e.is_queued_for_deletion():
			if world != null:
				world.unregister(w_e)
			w_e.queue_free()
	enemies.clear()
	_wrecks.clear()
	if debris_field != null and is_instance_valid(debris_field):
		debris_field.clear()
	known_targets.clear()
	_slots.clear()
	_last_slot_time.clear()
	_slot_ready_at = 0.0


func add_enemy(e: EnemyBase) -> void:
	add_child(e)
	if not e in enemies:
		enemies.append(e)
	if world != null:
		world.register(e)
	enemy_spawned.emit(e)


func remove_enemy(e: EnemyBase) -> void:
	_slots.erase(e.target_id)
	enemies.erase(e)
	_wrecks.erase(e)
	enemy_removed.emit(e)


func register_wreck(e: EnemyBase) -> void:
	if e == null or not is_instance_valid(e) or e in _wrecks:
		return
	_wrecks.append(e)
	while _wrecks.size() > MAX_WRECKS:
		var old: EnemyBase = _wrecks.pop_front()
		if is_instance_valid(old):
			remove_enemy(old)
			if world != null:
				world.unregister(old)
			old.queue_free()


func wreck_count() -> int:
	var n := 0
	for i in range(_wrecks.size() - 1, -1, -1):
		var w_e: EnemyBase = _wrecks[i]
		if not is_instance_valid(w_e) or w_e.is_queued_for_deletion():
			_wrecks.remove_at(i)
		elif w_e.destroyed():
			n += 1
	return n


func alive_count() -> int:
	var n := 0
	for e in enemies:
		if is_instance_valid(e) and not e.destroyed():
			n += 1
	return n


func emit_enemy_event(kind: String, enemy: Node, payload: Dictionary) -> void:
	enemy_event.emit(kind, enemy, payload)


# --- Shared Target Board & Delayed Relay ------------------------------------------------------------------

func report_sighting(spotter: EnemyBase, target: CombatTarget, pos: Vector3) -> void:
	var now := world.now if world != null else 0.0
	var arc := ring.world_to_arc(pos) if ring != null else Vector3(pos.x, pos.z, pos.y)
	known_targets[target.target_id] = {
		"target": target, "pos": pos, "arc": arc, "last_seen": now, "seen_by": spotter.target_id,
	}


func relay_alert_from(spotter: EnemyBase, tid: String) -> void:
	if not known_targets.has(tid):
		return
	var entry: Dictionary = known_targets[tid]
	var target: CombatTarget = entry.get("target")
	if target == null or not is_instance_valid(target):
		return
	var sp := spotter.global_position if spotter.is_inside_tree() else spotter.position
	for e in enemies:
		if not is_instance_valid(e) or e == spotter or e.destroyed():
			continue
		var ep := e.global_position if e.is_inside_tree() else e.position
		if sp.distance_to(ep) <= RELAY_RADIUS:
			e.receive_squad_alert(target)


func best_known_target(from_pos: Vector3) -> Dictionary:
	var now := world.now if world != null else 0.0
	var best := {}
	var best_d := INF
	for tid: String in known_targets.keys():
		var e: Dictionary = known_targets[tid]
		var t: Variant = e.get("target")
		if t == null or not is_instance_valid(t) or not (t as CombatTarget).is_hittable() or now - float(e["last_seen"]) > MEMORY_TIME:
			known_targets.erase(tid)
			continue
		var d := from_pos.distance_to(e["pos"] as Vector3)
		if d < best_d:
			best_d = d
			best = e
	return best


# --- Attack Slot Arbiter ----------------------------------------------------------------------------------

func active_slots_for(tid: String) -> int:
	var n := 0
	for eid: String in _slots.keys():
		if str(_slots[eid]) == tid:
			n += 1
	return n


func request_attack_slot(enemy_id: String, tid: String, priority: float = 1.0) -> bool:
	if _slots.get(enemy_id, "") == tid:
		return true
	# Prune dead/missing slot holders.
	for eid: String in _slots.keys():
		var alive := false
		for e in enemies:
			if is_instance_valid(e) and e.target_id == eid and not e.destroyed():
				alive = true
				break
		if not alive:
			_slots.erase(eid)
	var now := world.now if world != null else 0.0
	if active_slots_for(tid) >= maxi(max_attackers, 1):
		return false
	if slot_stagger > 0.0 and now < _slot_ready_at:
		return false
	_slots[enemy_id] = tid
	_last_slot_time[enemy_id] = now - priority * 0.05
	return true


func release_attack_slot(enemy_id: String) -> void:
	if _slots.has(enemy_id):
		_slots.erase(enemy_id)
		var now := world.now if world != null else 0.0
		var gap := slot_stagger if max_attackers <= 1 else slot_stagger * 0.35
		_slot_ready_at = maxf(_slot_ready_at, now + gap)


# --- Separation & CityPlan Road-Graph A* ------------------------------------------------------------------

func separation_vector(self_e: EnemyBase) -> Vector3:
	var acc := Vector3.ZERO
	var p := self_e.global_position if self_e.is_inside_tree() else self_e.position
	for other in enemies:
		if not is_instance_valid(other) or other == self_e or other.destroyed():
			continue
		var op := other.global_position if other.is_inside_tree() else other.position
		var diff := p - op
		var d := diff.length()
		var min_d := self_e.body_radius + other.body_radius + SEP_MARGIN
		if d > 0.001 and d < min_d:
			acc += diff.normalized() * ((min_d - d) / min_d)
	return acc


func _build_nav_graph() -> void:
	_graph_nodes.clear()
	_graph_adj.clear()
	if plan == null:
		return
	var rg := plan.road_graph()
	for n: Vector2 in rg["nodes"]:
		_graph_nodes.append(n)
		_graph_adj.append([])
	for ed: Array in rg["edges"]:
		var a := int(ed[0])
		var b := int(ed[1])
		(_graph_adj[a] as Array).append(b)
		(_graph_adj[b] as Array).append(a)
	# Also link park / plaza centers to their nearest road crossing so patrols can traverse open lots.
	for l: Dictionary in plan.lots:
		if str(l["kind"]) == "open" and str(l.get("open", "")) in ["park", "plaza"]:
			var c: Vector2 = (l["rect"] as Rect2).get_center()
			var near := _nearest_node(c)
			if near >= 0:
				var idx := _graph_nodes.size()
				_graph_nodes.append(c)
				_graph_adj.append([near])
				(_graph_adj[near] as Array).append(idx)


func _nearest_node(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _graph_nodes.size():
		var d := p.distance_squared_to(_graph_nodes[i])
		if d < best_d:
			best_d = d
			best = i
	return best


func find_arc_path(from_arc: Vector2, to_arc: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _graph_nodes.is_empty() or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_node(from_arc)
	var g := _nearest_node(to_arc)
	if s < 0 or g < 0 or s == g:
		return out
	# Small graph (~25-60 crossings): clean deterministic A*.
	var open: Array[int] = [s]
	var came := {}
	var g_score := {s: 0.0}
	var f_score := {s: _graph_nodes[s].distance_to(_graph_nodes[g])}
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
				rev.append(_graph_nodes[node])
				node = int(came[node])
			rev.reverse()
			return rev
		open.remove_at(best_i)
		closed[cur] = true
		for nb: int in _graph_adj[cur]:
			if closed.has(nb):
				continue
			var tent := float(g_score[cur]) + _graph_nodes[cur].distance_to(_graph_nodes[nb])
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + _graph_nodes[nb].distance_to(_graph_nodes[g])
				if not nb in open:
					open.append(nb)
	return out
