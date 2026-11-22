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
## Hearing (host / solo only): an un-alerted live enemy hears PLAYER fire and alerts toward the shooter (hear_fire).
const HEAR_SHOT_RADIUS := 25.0    ## m from its eye to a shot's path (origin -> aim point, clamped to range)
const HEAR_IMPACT_RADIUS := 30.0  ## m (+ the splash radius) from its eye to an impact / blast / hit on a squadmate
const COVER_EXPOSURE_PENALTY := 140.0     ## m A* penalty for road nodes in open LOS of the threat (beats side-street detour)
const COVER_MID_EXPOSURE_PENALTY := 70.0  ## m A* penalty when edge midpoint is exposed to the threat

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
var _occluders: Array = []         ## [{rect: Rect2, h: float}] tall building tiers (>= 6 m) & pillar cores in arc space
## Multi-deck stack (W4): deck k -> [nodes, adj] (that deck's road graph, add_deck_nav), and `deck_of` (world position ->
## deck index, CityStack.deck_at). Enemies path on their own deck's graph and only engage / hear about targets on it.
var _deck_graphs: Dictionary = {}
var _deck_occluders: Dictionary = {} ## deck k -> Array of {rect: Rect2, h: float}
var deck_of := Callable()
var _awake: Dictionary = {}       ## deck -> true while an opposing target stands on it (deck_awake; cached per clock step)
var _awake_at := -INF
var _heard: Array = []            ## pending hearings [{e, s (shooter), due (combat clock)}]: slow shots reach them later
var hear_checks := 0              ## player-fire stimuli the hearing evaluated here (stays 0 on a crew client)


func _init() -> void:
	name = "EnemySquad"
	add_to_group("enemy_squad")


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "plan": Net.SPAWN, "ring": Net.SPAWN, "max_attackers": Net.SPAWN,
		"slot_stagger": Net.SPAWN, "enemies": Net.LOCAL, "debris_field": Net.LOCAL, "known_targets": Net.OWNER,
		"_wrecks": Net.LOCAL, "_slots": Net.OWNER, "_last_slot_time": Net.PRIVATE, "_slot_ready_at": Net.PRIVATE,
		"_graph_nodes": Net.LOCAL, "_graph_adj": Net.LOCAL, "_occluders": Net.LOCAL,
		"_deck_graphs": Net.LOCAL, "_deck_occluders": Net.LOCAL, "deck_of": Net.LOCAL, "_awake": Net.PRIVATE, "_awake_at": Net.PRIVATE,
		"_heard": Net.PRIVATE, "hear_checks": Net.PRIVATE}


func setup(w: CombatWorld, p: CityPlan = null, r: RingFrame = null) -> void:
	if world != null and is_instance_valid(world) and world.advanced.is_connected(_on_world_advanced):
		world.advanced.disconnect(_on_world_advanced)
	if world != null and is_instance_valid(world) and world.fired.is_connected(_on_shot_fired):
		world.fired.disconnect(_on_shot_fired)
		world.impact_from.disconnect(_on_impact_from)
		world.hit_landed.disconnect(_on_hit_landed)
	world = w
	plan = p
	ring = r
	_heard.clear()
	if world != null:
		if ring != null:
			world.ring = ring
		if not world.advanced.is_connected(_on_world_advanced):
			world.advanced.connect(_on_world_advanced)
		if not world.fired.is_connected(_on_shot_fired):   # hearing; the handlers return at once on a crew client
			world.fired.connect(_on_shot_fired)
			world.impact_from.connect(_on_impact_from)
			world.hit_landed.connect(_on_hit_landed)
	_ensure_debris_field()
	EnemyMeshes.prewarm()
	_deck_graphs.clear()
	_deck_occluders.clear()
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
	if not _heard.is_empty():
		_step_heard()


func clear_enemies() -> void:
	_heard.clear()
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
		"deck": spotter.spawn_deck,
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
		if not is_instance_valid(e) or e == spotter or e.destroyed() or e.spawn_deck != spotter.spawn_deck:
			continue
		var ep := e.global_position if e.is_inside_tree() else e.position
		if sp.distance_to(ep) <= RELAY_RADIUS:
			e.receive_squad_alert(target)


## Drone Alert Beacon relay (docs/design/enemy-tactics-and-drones.md §2.2): posts fresh LKP and alerts ground defenders
## within `radius` on the same `deck`. Returns the number of newly alerted enemies.
func relay_beacon(origin: Vector3, target: CombatTarget, target_pos: Vector3, deck: int, radius: float = 130.0) -> int:
	if target == null or not is_instance_valid(target) or not target.is_hittable():
		return 0
	var now := world.now if world != null else 0.0
	var arc := ring.world_to_arc(target_pos) if ring != null else Vector3(target_pos.x, target_pos.z, target_pos.y)
	known_targets[target.target_id] = {
		"target": target, "pos": target_pos, "arc": arc, "last_seen": now, "seen_by": "beacon",
		"deck": deck,
	}
	var pulled := 0
	for e in enemies:
		if not is_instance_valid(e) or e.destroyed() or e.spawn_deck != deck or e.enemy_type == "drone":
			continue
		var ep := e.global_position if e.is_inside_tree() else e.position
		if origin.distance_to(ep) <= radius:
			var was_alert := e.is_alerted()
			e.receive_squad_alert(target)
			if not was_alert and e.is_alerted():
				pulled += 1
	return pulled


## True when `pos` is on deck `k` (always true without a deck_of: one district).
func on_deck(pos: Vector3, k: int) -> bool:
	return not deck_of.is_valid() or int(deck_of.call(pos)) == k


## Stack (W4): true while a hittable player-team target stands on deck `k`. Enemies on a deck nobody is on sleep (no AI:
## nothing there to see, and it keeps three decks of encounters within the frame budget). Always true without deck_of.
func deck_awake(k: int) -> bool:
	if not deck_of.is_valid() or world == null:
		return true
	if world.now != _awake_at:
		_awake_at = world.now
		_awake.clear()
		for t in world.targets:
			if is_instance_valid(t) and t.team == "player" and t.is_hittable() and t.is_inside_tree():
				_awake[int(deck_of.call(t.global_position))] = true
	return _awake.has(k)


func best_known_target(from_pos: Vector3, deck: int = -1) -> Dictionary:
	var now := world.now if world != null else 0.0
	var best := {}
	var best_d := INF
	for tid: String in known_targets.keys():
		var e: Dictionary = known_targets[tid]
		var t: Variant = e.get("target")
		if t == null or not is_instance_valid(t) or not (t as CombatTarget).is_hittable() or now - float(e["last_seen"]) > MEMORY_TIME:
			known_targets.erase(tid)
			continue
		if deck >= 0 and int(e.get("deck", deck)) != deck:
			continue
		var d := from_pos.distance_to(e["pos"] as Vector3)
		if d < best_d:
			best_d = d
			best = e
	return best


# --- Hearing (host / solo only) ---------------------------------------------------------------------------
# Player fire near an un-alerted live enemy alerts it toward the shooter (EnemyBase.hear_fire), which then relays like a
# spotter. Three stimuli: a shot's path passing within HEAR_SHOT_RADIUS of its eye (CombatWorld.fired: local and
# replicated shots; a slow shot is heard when it reaches the closest point, a lobbed one at its muzzle only), an impact /
# blast within HEAR_IMPACT_RADIUS + splash radius (CombatWorld.impact_from), and a player hit on a squadmate within
# HEAR_IMPACT_RADIUS of the hit point (CombatWorld.hit_landed: also when the hit kills it before its own relay). Enemy
# fire is never heard. Sound passes walls (no line of sight). Stack: only stimuli on the enemy's own deck, never while the
# deck sleeps. Enemies are host-owned: a crew client's squad holds puppets, so every handler returns at once there.

func _hearing(record: Dictionary) -> bool:
	return world != null and Net.is_host() and CombatWorld.life_src(record) != -1


func _listens(e: EnemyBase) -> bool:
	return is_instance_valid(e) and not e.puppet and not e.destroyed() and not e.is_alerted() and e.ai_mode == "live" \
		and deck_awake(e.spawn_deck)


## The player-team CombatTarget that fired `record` (by shooter id, else by owner peer), or null.
func _shooter_of(sid: String, peer: int) -> CombatTarget:
	var by_peer: CombatTarget = null
	for t in world.targets:
		if not is_instance_valid(t) or t.team != "player" or not t.is_hittable():
			continue
		if t.target_id == sid:
			return t
		if by_peer == null and peer > 0 and t.owner_peer == peer:
			by_peer = t
	return by_peer


func _hear_radius_for(e: EnemyBase, base_r: float, bonus: float = 0.0) -> float:
	var ext := float(e._cfg.get("hear_radius", 0.0))
	return maxf(base_r, ext) + bonus


func _on_shot_fired(record: Dictionary) -> void:
	if not _hearing(record):
		return
	hear_checks += 1
	var st := world.stats(str(record.get("weapon", "")))
	var origin: Vector3 = record.get("origin", Vector3.ZERO)
	var dir: Vector3 = record.get("dir", Vector3.FORWARD)
	var reach := float(st.get("range", 200.0))
	var aim: Variant = record.get("target")
	var length := minf(origin.distance_to(aim as Vector3), reach) if aim is Vector3 else reach
	var end := origin + dir.normalized() * length
	var lobbed := str(st.get("kind", "")) == "arc"   # the mortar: its muzzle only; the landing is an impact
	var speed := float(st.get("speed", 0.0))
	var t0 := float(record.get("t", world.now))
	var shooter: CombatTarget = null
	for e in enemies:
		if not _listens(e):
			continue
		var eye := e.eye_world()
		var p := origin if lobbed else Geometry3D.get_closest_point_to_segment(eye, origin, end)
		var hr := _hear_radius_for(e, HEAR_SHOT_RADIUS)
		if eye.distance_squared_to(p) > hr * hr or not on_deck(p, e.spawn_deck):
			continue
		if shooter == null:
			shooter = _shooter_of(str(record.get("shooter", "")), int(record.get("peer", 0)))
			if shooter == null:
				return
		var due := t0 + origin.distance_to(p) / speed if speed > 0.0 and not lobbed else t0
		_hear(e, shooter, due)


func _on_impact_from(record: Dictionary, point: Vector3, radius: float) -> void:
	if not _hearing(record):
		return
	hear_checks += 1
	_hear_around(point, HEAR_IMPACT_RADIUS, maxf(radius, 0.0), str(record.get("shooter", "")), int(record.get("peer", 0)))


## A player hit on a squadmate is heard around the hit point (its own alert / relay is the damage path's).
func _on_hit_landed(target: CombatTarget, h: Hit) -> void:
	if world == null or h == null or not (target is EnemyBase) or not Net.is_host() or not (target as EnemyBase) in enemies:
		return
	hear_checks += 1
	_hear_around(h.point, HEAR_IMPACT_RADIUS, 0.0, h.shooter, 0)


func _hear_around(point: Vector3, base_r: float, bonus: float, sid: String, peer: int) -> void:
	var shooter: CombatTarget = null
	for e in enemies:
		if not _listens(e):
			continue
		var hr := _hear_radius_for(e, base_r, bonus)
		if e.eye_world().distance_squared_to(point) > hr * hr or not on_deck(point, e.spawn_deck):
			continue
		if shooter == null:
			shooter = _shooter_of(sid, peer)
			if shooter == null:
				return
		e.hear_fire(shooter)


## `e` hears `shooter` at clock time `due`: now, or queued (one pending hearing per enemy, the earliest kept).
func _hear(e: EnemyBase, shooter: CombatTarget, due: float) -> void:
	if due <= world.now:
		e.hear_fire(shooter)
		return
	for it: Dictionary in _heard:
		if it["e"] == e:
			if due < float(it["due"]):
				it["due"] = due
				it["s"] = shooter
			return
	_heard.append({"e": e, "s": shooter, "due": due})


func _step_heard() -> void:
	for i in range(_heard.size() - 1, -1, -1):
		var it: Dictionary = _heard[i]
		if float(it["due"]) > world.now:
			continue
		_heard.remove_at(i)
		var e: Variant = it["e"]
		var s: Variant = it["s"]
		if is_instance_valid(e) and is_instance_valid(s) and _listens(e as EnemyBase) and (s as CombatTarget).is_hittable():
			(e as EnemyBase).hear_fire(s as CombatTarget)


## Pending hearings (slow shots still on their way): read by tests.
func pending_hearings() -> int:
	return _heard.size()


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
	_occluders.clear()
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
	# Pre-cache 2D solid building footprints (tiers >= 6 m) & pillar cores for O(N) cover-path & drone clearance queries.
	for b: Dictionary in plan.buildings:
		var bc: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			var y1 := float(t["y1"])
			if y1 < 6.0:
				continue
			var sz: Vector2 = t["size"]
			var tc := bc + (t["off"] as Vector2)
			_occluders.append({"rect": Rect2(tc - sz * 0.5, sz), "h": y1 + CityPlan.CURB_H})
		if bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var csz: Vector2 = core["size"]
			var cc := Vector2(float(core["x"]), float(core["s"]))
			_occluders.append({"rect": Rect2(cc - csz * 0.5, csz), "h": 99.0})


func _nearest_node(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _graph_nodes.size():
		var d := p.distance_squared_to(_graph_nodes[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## Stack deck k's road graph & 2D occluders (its own plan, in its own arc coordinates) for find_arc_path / find_cover_path.
func add_deck_nav(k: int, deck_plan: CityPlan) -> void:
	var keep_n := _graph_nodes
	var keep_a := _graph_adj
	var keep_o := _occluders
	var keep_p := plan
	_graph_nodes = [] as Array[Vector2]
	_graph_adj = []
	_occluders = []
	plan = deck_plan
	_build_nav_graph()
	_deck_graphs[k] = [_graph_nodes, _graph_adj]
	_deck_occluders[k] = _occluders
	_graph_nodes = keep_n
	_graph_adj = keep_a
	_occluders = keep_o
	plan = keep_p


## Cached 2D building occluders [{rect: Rect2, h: float}] for deck `deck` (or single-district default).
func deck_occluders(deck: int = -1) -> Array:
	if _deck_occluders.has(deck):
		return _deck_occluders[deck] as Array
	return _occluders


## Fast 2D arc-space LOS occlusion check against tall building tiers (>= 6 m) and pillar cores.
func arc_segment_occluded(a: Vector2, b: Vector2, deck: int = -1) -> bool:
	return _arc_seg_occluded_list(a, b, deck_occluders(deck))


static func _arc_seg_occluded_list(a: Vector2, b: Vector2, occs: Array) -> bool:
	for item: Dictionary in occs:
		if _segment_hits_rect(a, b, item["rect"] as Rect2):
			return true
	return false


static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	if absf(d.x) < 1e-6:
		if a.x < r.position.x or a.x > r.end.x:
			return false
	else:
		var inv := 1.0 / d.x
		var tx1 := (r.position.x - a.x) * inv
		var tx2 := (r.end.x - a.x) * inv
		if tx1 > tx2:
			var tmp := tx1
			tx1 = tx2
			tx2 = tmp
		t0 = maxf(t0, tx1)
		t1 = minf(t1, tx2)
		if t0 > t1:
			return false
	if absf(d.y) < 1e-6:
		if a.y < r.position.y or a.y > r.end.y:
			return false
	else:
		var inv := 1.0 / d.y
		var ty1 := (r.position.y - a.y) * inv
		var ty2 := (r.end.y - a.y) * inv
		if ty1 > ty2:
			var tmp := ty1
			ty1 = ty2
			ty2 = tmp
		t0 = maxf(t0, ty1)
		t1 = minf(t1, ty2)
		if t0 > t1:
			return false
	return true


func find_arc_path(from_arc: Vector2, to_arc: Vector2, deck: int = -1) -> Array[Vector2]:
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_arc_path(from_arc, to_arc)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_arc_path(from_arc, to_arc)


## Cover-weighted road-graph A* (docs/design/enemy-tactics-and-drones.md §4.2): penalizes nodes and edge midpoints
## that sit in open 2D LOS of `threat_arc` outside `engage_range * 0.75`, steering flankers down occluded side streets.
func find_cover_path(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, deck: int = -1,
		engage_range: float = 60.0) -> Array[Vector2]:
	var occs := deck_occluders(deck)
	if occs.is_empty():
		return find_arc_path(from_arc, to_arc, deck)
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_cover_path_internal(from_arc, to_arc, threat_arc, occs, engage_range)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_cover_path_internal(from_arc, to_arc, threat_arc, occs, engage_range)


func _find_cover_path_internal(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, occs: Array,
		engage_range: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _graph_nodes.is_empty() or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_node(from_arc)
	var g := _nearest_node(to_arc)
	if s < 0 or g < 0 or s == g:
		return out
	var safe_band := engage_range * 0.75
	var node_exposed := {}
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
			if not rev.is_empty() and from_arc.distance_to(_graph_nodes[s]) > 6.5 \
					and _arc_seg_occluded_list(from_arc, rev[0], occs):
				rev.push_front(_graph_nodes[s])
			return rev
		open.remove_at(best_i)
		closed[cur] = true
		var cur_p := _graph_nodes[cur]
		for nb: int in _graph_adj[cur]:
			if closed.has(nb):
				continue
			var nb_p := _graph_nodes[nb]
			var step_cost := cur_p.distance_to(nb_p)
			if nb_p.distance_to(threat_arc) > safe_band:
				if not node_exposed.has(nb):
					node_exposed[nb] = not _arc_seg_occluded_list(nb_p, threat_arc, occs)
				if bool(node_exposed[nb]):
					step_cost += COVER_EXPOSURE_PENALTY
			var mid := (cur_p + nb_p) * 0.5
			if mid.distance_to(threat_arc) > safe_band and not _arc_seg_occluded_list(mid, threat_arc, occs):
				step_cost += COVER_MID_EXPOSURE_PENALTY
			var tent := float(g_score[cur]) + step_cost
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + nb_p.distance_to(_graph_nodes[g])
				if not nb in open:
					open.append(nb)
	return out


func _find_arc_path(from_arc: Vector2, to_arc: Vector2) -> Array[Vector2]:
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
