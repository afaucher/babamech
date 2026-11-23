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
const WAVE_PLAYER_CLEAR := 25.0           ## m min distance from standing player mech before wave units emerge from a source
const WAVE_PROXIMITY_MAX_DELAY := 8.0     ## s max hold if a player camps a wave door (< WaveDirector.GRACE = 10 s)
## Per-deck last-enemy hunt / reveal / anti-soft-lock thresholds (host-only, docs/design/enemies.md §5, mission-section.md §15):
## Never hunt or reveal while > HUNT_MAX_REMAINING enemies remain on a deck (including queued wave units) or before
## the crew has actually had combat contact on that deck.
const CUT_PATH_MARGIN := 2.0              ## m: paths keep a body's width clear of floor cuts (ramp mouths, holes)
const HUNT_MAX_REMAINING := 3             ## hard cap: never trigger last-enemy hunt/reveal while > 3 remain on deck
const HUNT_QUIET_S := 75.0                ## s of deck quiet after contact (<= 3 remaining) before Step 1 hunt starts
const REVEAL_HUNT_DELAY_S := 50.0         ## s further without LOS/combat after hunt starts before Step 2 reveal markers
const CULL_IDLE_S := 120.0                ## s after reveal with 0 damage dealt/taken before Step 3 anti-soft-lock cull

signal enemy_spawned(enemy: EnemyBase)
signal enemy_removed(enemy: EnemyBase)
signal enemy_event(kind: String, enemy: Node, payload: Dictionary)
signal stragglers_revealed(deck: int, units: Array)
signal enemy_deck_changed(enemy: EnemyBase, old_deck: int, new_deck: int)

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
var _occluder_rects: Array[Rect2] = [] ## flat Rect2 cache parallel to _occluders (zero Dictionary lookups in cover A*)
## Multi-deck stack (W4): deck k -> [nodes, adj] (that deck's road graph, add_deck_nav), and `deck_of` (world position ->
## deck index, CityStack.deck_at). Enemies path on their own deck's graph and only engage / hear about targets on it.
var _deck_graphs: Dictionary = {}
var _deck_plans: Dictionary = {}     ## deck k -> CityPlan (for multi-deck Drop Ship drop-zone selection)
var _deck_rings: Dictionary = {}     ## deck k -> RingFrame (learned on add_enemy / add_deck_nav for cross-deck re-homing)
var _deck_occluders: Dictionary = {} ## deck k -> Array of {rect: Rect2, h: float}
var _deck_occluder_rects: Dictionary = {} ## deck k -> Array[Rect2]
## Floor cuts (ramp mouths and floor holes, CityPlan.floor_cuts) in arc space: walkable-looking openings a ground unit
## must not step into (a ramp mouth has no railing). Not LOS occluders: they only shape paths and steering.
var _cut_rects: Array[Rect2] = []
var _deck_cut_rects: Dictionary = {}      ## deck k -> Array[Rect2]
var _deck_drops: Dictionary = {}     ## deck k -> int count of Drop Ships called in on deck k
var max_drops_per_deck := 1          ## cap per deck (1 solo, 2 in 3-4p co-op) so deck-clear never drags on
var drops_enabled := true            ## host toggle for Scout Drone -> Drop Ship call-ins
var _drop_seq := 0
var _cover_repath_at := -INF       ## combat clock stamp of last budgeted AI cover-path solve (at most 1 per frame)
var deck_of := Callable()
var _awake: Dictionary = {}       ## deck -> true while a standing crew mech stands on it (deck_awake; cached per clock step)
var _awake_at := -INF
var _awake_targets_n := -1
var _crew_pos_by_deck: Dictionary = {}  ## deck -> PackedVector3Array of standing crew mech positions (AI LOD cache)
var _live_assets: Dictionary = {}       ## asset_id -> live AssetTarget (for abandoned-defend wave wakeup)
var _heard: Array = []            ## pending hearings [{e, s (shooter), due (combat clock)}]: slow shots reach them later
var hear_checks := 0              ## player-fire stimuli the hearing evaluated here (stays 0 on a crew client)
## Per-deck last-enemy hunt / reveal / anti-soft-lock valve (docs/design/enemies.md §5, mission-section.md §15; host-only).
var hunt_last_quiet_s := HUNT_QUIET_S     ## s of deck quiet after contact (<= hunt_max_remaining left) before Step 1 hunt
var hunt_max_remaining := HUNT_MAX_REMAINING  ## hard cap: never trigger last-enemy hunt/reveal above this count
var reveal_hunt_delay_s := REVEAL_HUNT_DELAY_S ## s further without LOS/combat before Step 2 reveal markers
var cull_idle_s := CULL_IDLE_S            ## s after reveal with 0 damage dealt/taken before Step 3 anti-soft-lock cull
var _deck_quiet: Dictionary = {}          ## deck -> s since last sighting, shot, damage, or kill on that deck
var _deck_engaged: Dictionary = {}        ## deck -> true once the crew has had real combat contact on that deck
var _deck_hunt_refresh: Dictionary = {}   ## deck -> s until next 2.0 s hunt target-board refresh
var _hunt_tick_acc := 0.0                 ## 4 Hz accumulator for _step_hunt_and_reveal (0.00 ms on 14/15 frames)
## Fireteams & Mission Waves Phase 1 (docs/design/mission-objectives.md §5 & §9; host-only).
var _fireteams: Array = []        ## Array[EnemyTroopSquad] active tactical fireteams
var _pending_wave_orders: Array[Dictionary] = []  ## queued orders awaiting open_at & 25 m player clearance
var _wave_spawned_total: Dictionary = {}          ## wave_id -> int total units spawned so far
var _wave_unreleased_pending: Dictionary = {}     ## wave_id -> int units owed after a partial release (for WaveDirector)
var _wave_decks: Dictionary = {}                  ## wave_id -> int deck index (so queued waves count toward deck remaining)


func _init() -> void:
	name = "EnemySquad"
	add_to_group("enemy_squad")


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "plan": Net.SPAWN, "ring": Net.SPAWN, "max_attackers": Net.SPAWN,
		"slot_stagger": Net.SPAWN, "enemies": Net.LOCAL, "debris_field": Net.LOCAL, "known_targets": Net.OWNER,
		"_wrecks": Net.LOCAL, "_slots": Net.OWNER, "_last_slot_time": Net.PRIVATE, "_slot_ready_at": Net.PRIVATE,
		"_graph_nodes": Net.LOCAL, "_graph_adj": Net.LOCAL, "_occluders": Net.LOCAL, "_occluder_rects": Net.LOCAL,
		"_deck_graphs": Net.LOCAL, "_deck_plans": Net.LOCAL, "_deck_rings": Net.LOCAL, "_deck_occluders": Net.LOCAL,
		"_deck_occluder_rects": Net.LOCAL, "_cut_rects": Net.LOCAL, "_deck_cut_rects": Net.LOCAL, "_deck_drops": Net.OWNER, "max_drops_per_deck": Net.SPAWN,
		"drops_enabled": Net.SPAWN, "_drop_seq": Net.PRIVATE, "_cover_repath_at": Net.PRIVATE,
		"deck_of": Net.LOCAL, "_awake": Net.PRIVATE, "_awake_at": Net.PRIVATE,
		"_awake_targets_n": Net.PRIVATE, "_crew_pos_by_deck": Net.PRIVATE, "_live_assets": Net.LOCAL,
		"_heard": Net.PRIVATE, "hear_checks": Net.PRIVATE,
		"hunt_last_quiet_s": Net.SPAWN, "hunt_max_remaining": Net.SPAWN,
		"reveal_hunt_delay_s": Net.SPAWN, "cull_idle_s": Net.SPAWN,
		"_deck_quiet": Net.PRIVATE, "_deck_engaged": Net.PRIVATE, "_deck_hunt_refresh": Net.PRIVATE, "_hunt_tick_acc": Net.PRIVATE,
		"_fireteams": Net.PRIVATE, "_pending_wave_orders": Net.PRIVATE,
		"_wave_spawned_total": Net.PRIVATE, "_wave_unreleased_pending": Net.PRIVATE, "_wave_decks": Net.PRIVATE}


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
	_deck_plans.clear()
	_deck_rings.clear()
	_deck_occluders.clear()
	_deck_occluder_rects.clear()
	_deck_cut_rects.clear()
	_deck_drops.clear()
	_deck_quiet.clear()
	_deck_engaged.clear()
	_deck_hunt_refresh.clear()
	_fireteams.clear()
	_pending_wave_orders.clear()
	_wave_spawned_total.clear()
	_wave_unreleased_pending.clear()
	_wave_decks.clear()
	_awake.clear()
	_awake_at = -INF
	_awake_targets_n = -1
	_crew_pos_by_deck.clear()
	_live_assets.clear()
	_hunt_tick_acc = 0.0
	_drop_seq = 0
	_cover_repath_at = -INF
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
	if Net.is_host() and world != null and dt > 0.0:
		if not _pending_wave_orders.is_empty():
			_step_pending_waves()
		_hunt_tick_acc += dt
		if _hunt_tick_acc >= 0.25:
			var step_dt := _hunt_tick_acc
			_hunt_tick_acc = 0.0
			_step_deck_rehome()
			_step_hunt_and_reveal(step_dt)


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
	_deck_drops.clear()
	_deck_quiet.clear()
	_deck_engaged.clear()
	_deck_hunt_refresh.clear()
	_fireteams.clear()
	_pending_wave_orders.clear()
	_wave_spawned_total.clear()
	_wave_unreleased_pending.clear()
	_wave_decks.clear()
	_awake.clear()
	_awake_at = -INF
	_awake_targets_n = -1
	_crew_pos_by_deck.clear()
	_live_assets.clear()
	_hunt_tick_acc = 0.0
	_slot_ready_at = 0.0


func add_enemy(e: EnemyBase) -> void:
	add_child(e)
	if not e in enemies:
		enemies.append(e)
	if e.ring != null:
		_deck_rings[e.spawn_deck] = e.ring
	if world != null:
		world.register(e)
	enemy_spawned.emit(e)


func remove_enemy(e: EnemyBase) -> void:
	_slots.erase(e.target_id)
	enemies.erase(e)
	_wrecks.erase(e)
	if e is EnemyTrooper and (e as EnemyTrooper).fireteam != null:
		(e as EnemyTrooper).fireteam.remove_member(e)
	enemy_removed.emit(e)


func register_fireteam(ft: EnemyTroopSquad) -> void:
	if ft != null and not (ft in _fireteams):
		_fireteams.append(ft)


# --- Mission Waves Phase 1 (Host Scheduler & WaveDirector Count Helpers) ----------------------------------

## Immediate release path called by `EnemySpawner.spawn_wave(order, wave, source, ctx)` when `MissionFlow` reaches
## `order.open_at` (door just opened). Spawns up to `min(order.max_units, source.load)` units immediately, tagged with
## `wave` & `spawn_deck`, hunting on arrival, and returns units of that wave still remaining (0 when complete).
func spawn_wave_now(order: Dictionary, wave_def: Dictionary, source_def: Dictionary, deck_budget_val: int,
		d_plan: CityPlan = null, d_ring: RingFrame = null, mission_seed: int = 1,
		skip_meshes: bool = false, wave_pool_share: float = 1.0) -> int:
	if not Net.is_host():
		return 0
	var wave_id := str(order.get("wave", wave_def.get("id", "wave")))
	var deck := int(order.get("deck", source_def.get("deck", 0)))
	_wave_decks[wave_id] = deck
	var use_plan := d_plan if d_plan != null else deck_plan(deck)
	var use_ring := d_ring if d_ring != null else ring
	var already := int(_wave_spawned_total.get(wave_id, 0))
	var planned := EnemySpawner.plan_wave(use_plan, use_ring, order, wave_def, source_def, deck_budget_val,
		mission_seed, already, wave_pool_share)
	var specs: Array[Dictionary] = planned["specs"]
	var pending_after := int(planned["pending"])
	if pending_after > 0:
		_wave_unreleased_pending[wave_id] = pending_after
	else:
		_wave_unreleased_pending.erase(wave_id)
	if specs.is_empty():
		return pending_after
	var entry := {
		"wave": wave_id, "deck": deck, "open_at": float(order.get("open_at", 0.0)), "specs": specs,
		"source": source_def.duplicate(true), "plan": use_plan, "ring": use_ring,
		"seed": mission_seed + already * 31, "skip_meshes": skip_meshes,
	}
	_release_wave_entry(entry)
	return pending_after


## Queue (or immediately spawn if open_at has passed and source is clear of players) a WaveDirector release order.
## Respects `order.open_at`, `order.max_units`, `source_def.load`, 25 m player proximity hold, partial follow-ups,
## and puts every spawned wave unit immediately into active hunt mode (docs/design/mission-objectives.md §5 & §9).
func queue_wave(order: Dictionary, wave_def: Dictionary, source_def: Dictionary, deck_budget_val: int,
		d_plan: CityPlan = null, d_ring: RingFrame = null, mission_seed: int = 1,
		skip_meshes: bool = false, wave_pool_share: float = 1.0) -> Dictionary:
	if not Net.is_host():
		return {"spawned": [] as Array[EnemyBase], "queued": 0, "pending": 0, "total_units": 0}
	var wave_id := str(order.get("wave", wave_def.get("id", "wave")))
	var deck := int(order.get("deck", source_def.get("deck", 0)))
	_wave_decks[wave_id] = deck
	var use_plan := d_plan if d_plan != null else deck_plan(deck)
	var use_ring := d_ring if d_ring != null else ring
	var already := int(_wave_spawned_total.get(wave_id, 0))
	for pend: Dictionary in _pending_wave_orders:
		if str(pend["wave"]) == wave_id:
			already += (pend["specs"] as Array).size()
	var planned := EnemySpawner.plan_wave(use_plan, use_ring, order, wave_def, source_def, deck_budget_val,
		mission_seed, already, wave_pool_share)
	var specs: Array[Dictionary] = planned["specs"]
	var pending_after := int(planned["pending"])
	if pending_after > 0:
		_wave_unreleased_pending[wave_id] = pending_after
	else:
		_wave_unreleased_pending.erase(wave_id)
	if specs.is_empty():
		return {"spawned": [] as Array[EnemyBase], "queued": 0, "pending": pending_after, "total_units": int(planned["total_units"])}
	var open_at := float(order.get("open_at", 0.0))
	var entry := {
		"wave": wave_id, "deck": deck, "open_at": open_at, "specs": specs,
		"source": source_def.duplicate(true), "plan": use_plan, "ring": use_ring,
		"seed": mission_seed + already * 31, "skip_meshes": skip_meshes,
	}
	var now := world.now if world != null else 0.0
	if now >= open_at and not _player_near_wave_source(source_def, use_ring, deck):
		var spawned := _release_wave_entry(entry)
		return {"spawned": spawned, "queued": 0, "pending": pending_after, "total_units": int(planned["total_units"])}
	_pending_wave_orders.append(entry)
	return {"spawned": [] as Array[EnemyBase], "queued": specs.size(), "pending": pending_after, "total_units": int(planned["total_units"])}


func _step_pending_waves() -> void:
	if world == null or _pending_wave_orders.is_empty():
		return
	var now := world.now
	var keep: Array[Dictionary] = []
	for entry in _pending_wave_orders:
		var open_at := float(entry["open_at"])
		if now < open_at:
			keep.append(entry)
			continue
		var timed_out := now >= open_at + WAVE_PROXIMITY_MAX_DELAY
		if not timed_out and _player_near_wave_source(entry["source"] as Dictionary, entry["ring"] as RingFrame, int(entry["deck"])):
			keep.append(entry)
			continue
		_release_wave_entry(entry)
	_pending_wave_orders = keep


func _player_near_wave_source(source_def: Dictionary, use_ring: RingFrame, deck: int) -> bool:
	if world == null:
		return false
	var sx := float(source_def.get("x", 0.0))
	var ss := float(source_def.get("s", 0.0))
	var src_w := use_ring.arc_to_world(sx, ss, CityPlan.CURB_H) if use_ring != null else Vector3(sx, 0.0, ss)
	var min_sq := WAVE_PLAYER_CLEAR * WAVE_PLAYER_CLEAR
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or (t is AssetTarget) or not t.is_hittable():
			continue
		if deck_of.is_valid() and not on_deck(t.global_position, deck):
			continue
		if t.global_position.distance_squared_to(src_w) < min_sq:
			return true
	return false


func _release_wave_entry(entry: Dictionary) -> Array[EnemyBase]:
	var wave_id := str(entry["wave"])
	var deck := int(entry["deck"])
	var use_plan := entry["plan"] as CityPlan
	var use_ring := entry["ring"] as RingFrame
	var specs: Array[Dictionary] = entry["specs"]
	var spawned := EnemySpawner.spawn_specs(specs, use_plan, use_ring, world, self,
		int(entry["seed"]), bool(entry["skip_meshes"]), "", deck, wave_id)
	_wave_spawned_total[wave_id] = int(_wave_spawned_total.get(wave_id, 0)) + spawned.size()
	# Wave units arrive immediately hunting the nearest standing crew mech on their deck (docs/design/mission-objectives.md §5.7).
	var src_def: Dictionary = entry["source"]
	var sx := float(src_def.get("x", 0.0))
	var ss := float(src_def.get("s", 0.0))
	var src_w := use_ring.arc_to_world(sx, ss, CityPlan.CURB_H) if use_ring != null else Vector3(sx, 0.0, ss)
	var best_p := _nearest_player_on_deck(src_w, deck)
	for e in spawned:
		var hunt_t := best_p
		if hunt_t == null and e.defend_target_id != "":
			hunt_t = _asset_target_by_id(e.defend_target_id)
		if hunt_t != null:
			if not (hunt_t is AssetTarget):
				e.hear_fire(hunt_t)
			e.begin_hunt_pursuit(hunt_t, hunt_t.global_position)
	note_deck_activity(deck)
	return spawned


func _asset_target_by_id(asset_id: String) -> AssetTarget:
	if world == null or asset_id == "":
		return null
	for t: CombatTarget in world.targets:
		if is_instance_valid(t) and t is AssetTarget and (t as AssetTarget).asset_id == asset_id and t.is_hittable():
			return t as AssetTarget
	return null


func _nearest_player_on_deck(from_w: Vector3, deck: int) -> CombatTarget:
	if world == null:
		return null
	var best: CombatTarget = null
	var best_d := INF
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or (t is AssetTarget) or not t.is_hittable():
			continue
		if deck_of.is_valid() and not on_deck(t.global_position, deck):
			continue
		var d := from_w.distance_squared_to(t.global_position)
		if d < best_d:
			best_d = d
			best = t
	return best


## Host fact for WaveDirector (`facts["garrison_alive"]`): count of living garrison enemies (`wave == ""`) per deck.
func alive_garrison_per_deck(decks: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(maxi(decks, 1))
	out.fill(0)
	for e in enemies:
		if is_instance_valid(e) and not e.destroyed() and not e.is_queued_for_deletion() and e.wave == "":
			var k := clampi(e.spawn_deck, 0, out.size() - 1)
			out[k] += 1
	return out


## Host fact for WaveDirector (`facts["wave_alive"]`): {wave_id: {"alive": int, "total": int spawned so far}}.
func wave_counts() -> Dictionary:
	var out: Dictionary = {}
	for wid: String in _wave_spawned_total.keys():
		out[wid] = {"alive": 0, "total": int(_wave_spawned_total[wid])}
	for e in enemies:
		if not is_instance_valid(e) or e.is_queued_for_deletion() or e.wave == "":
			continue
		if not out.has(e.wave):
			out[e.wave] = {"alive": 0, "total": 1}
		if not e.destroyed():
			(out[e.wave] as Dictionary)["alive"] = int((out[e.wave] as Dictionary)["alive"]) + 1
	return out


## Host fact for WaveDirector (`facts["wave_pending"]`): {wave_id: units owed after a partial release (> 0 only)}.
func pending_wave_counts() -> Dictionary:
	var out: Dictionary = {}
	for wid: String in _wave_unreleased_pending.keys():
		var rem := int(_wave_unreleased_pending[wid])
		if rem > 0:
			out[wid] = rem
	return out


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
	if kind == "alerted" and enemy is EnemyBase:
		var eb := enemy as EnemyBase
		var st := str(payload.get("state", ""))
		if st == "revealed":
			if not eb.revealed:
				eb.revealed = true
			stragglers_revealed.emit(eb.spawn_deck, [eb])
		elif st.begins_with("deck:"):
			var nd := int(st.substr(5))
			var old_d := eb.spawn_deck
			if nd >= 0 and nd != old_d:
				eb.spawn_deck = nd
				var nr := deck_ring(nd)
				if nr != null:
					eb.ring = nr
				enemy_deck_changed.emit(eb, old_d, nd)
	enemy_event.emit(kind, enemy, payload)


## Host-only 4 Hz check: re-home enemies that fell/crossed onto another deck (updating spawn_deck, ring, targeting,
## per-deck alive counts, and syncing to clients) and cull any enemy that left the mission area completely.
func _step_deck_rehome() -> void:
	if enemies.is_empty():
		return
	var max_deck := -1
	for dk in _deck_rings.keys():
		max_deck = maxi(max_deck, int(dk))
	for dk in _deck_plans.keys():
		max_deck = maxi(max_deck, int(dk))
	var lowest_ring: RingFrame = deck_ring(max_deck) if max_deck >= 0 else ring
	for e in enemies:
		if not is_instance_valid(e) or e.puppet or e.destroyed() or e.enemy_type == "dropship":
			continue
		var pos := e.global_position if e.is_inside_tree() else e.position
		# 1. Fell completely out below the lowest deck -> cull so it never counts toward the mission!
		if lowest_ring != null and lowest_ring.height(pos) < -18.0:
			e._kill("fell_out")
			continue
		# 2. Crossed to another deck (e.g. knocked down a shaft or drone traversing decks) -> re-home dynamically!
		if deck_of.is_valid():
			var cur_d := int(deck_of.call(pos))
			if cur_d >= 0 and cur_d != e.spawn_deck:
				var old_d := e.spawn_deck
				e.rehome_deck(cur_d, deck_ring(cur_d))
				enemy_deck_changed.emit(e, old_d, cur_d)
				continue
		# 3. Left the mission deck horizontally (past outer walls + recess margin) -> cull so it never blocks clear!
		var dp := deck_plan(e.spawn_deck)
		var dr := deck_ring(e.spawn_deck)
		if dp != null and dr != null:
			var a3 := dr.world_to_arc(pos)
			if not dp.extent.grow(28.0).has_point(Vector2(a3.x, a3.y)):
				e._kill("fell_out")


func note_deck_activity(deck: int) -> void:
	_deck_quiet[deck] = 0.0
	_deck_engaged[deck] = true


func _queued_wave_units_on_deck(deck: int) -> int:
	var n := 0
	for entry in _pending_wave_orders:
		if int(entry.get("deck", -1)) == deck:
			n += (entry["specs"] as Array).size()
	for wid: String in _wave_unreleased_pending.keys():
		if int(_wave_decks.get(wid, -1)) == deck:
			n += maxi(int(_wave_unreleased_pending[wid]), 0)
	return n


## Two-step per-deck last-enemy hunt / reveal + 120 s anti-soft-lock valve (host-only, docs/design/enemies.md §5):
##   - Hard cap: NEVER triggers hunt or reveal while > hunt_max_remaining (3) enemies remain on a deck (including
##     queued wave units), and NEVER before the crew has had real combat contact on that deck (`_deck_engaged[d]`).
##   - Step 1 (hunt): at <= 3 remaining after `hunt_last_quiet_s` (75 s) quiet, mobile stragglers hunt the crew.
##   - Step 2 (reveal): after a further `reveal_hunt_delay_s` (50 s) without LOS/combat, unengaged stragglers reveal.
##   - Step 3 (safety valve): `cull_idle_s` (120 s) after reveal with 0 damage dealt/taken, unreachable units cull.
func _step_hunt_and_reveal(dt: float) -> void:
	if enemies.is_empty():
		return
	var by_deck: Dictionary = {}
	for e in enemies:
		if not is_instance_valid(e) or e.puppet or e.destroyed() or e.ai_mode != "live" or e.enemy_type == "dropship":
			continue
		var d := e.spawn_deck
		if not by_deck.has(d):
			by_deck[d] = []
		(by_deck[d] as Array).append(e)
	if by_deck.is_empty():
		return
	for deck_key in by_deck.keys():
		var d := int(deck_key)
		if not deck_awake(d):
			continue
		var players := _alive_players_on_deck(d)
		if players.is_empty():
			continue
		var list: Array = by_deck[d]
		var total_remaining := list.size() + _queued_wave_units_on_deck(d)
		var any_hunting := false
		for e: EnemyBase in list:
			if e._hunting and e.is_mobile():
				any_hunting = true
		var straggler_eligible := total_remaining <= hunt_max_remaining and bool(_deck_engaged.get(d, false))
		var step1_active := false
		if straggler_eligible:
			var quiet := float(_deck_quiet.get(d, 0.0)) + dt
			_deck_quiet[d] = quiet
			if quiet >= hunt_last_quiet_s:
				step1_active = true
				for e: EnemyBase in list:
					if not e._hunting:
						e._hunting = true
						e._hunt_t = 0.0
					if e.is_mobile():
						any_hunting = true
		else:
			_deck_quiet[d] = 0.0
		# Refresh nearest alive player onto squad target board every 2.0 s while any mobile hunter is active on this deck.
		if any_hunting:
			var ref_t := float(_deck_hunt_refresh.get(d, 0.0)) - dt
			if ref_t <= 0.0:
				_deck_hunt_refresh[d] = 2.0
				var now := world.now
				for e: EnemyBase in list:
					if not e._hunting or not e.is_mobile():
						continue
					var pt := _nearest_target(e.global_position if e.is_inside_tree() else e.position, players)
					if pt == null:
						continue
					var tp := e._target_aim_center(pt)
					var arc := ring.world_to_arc(tp) if ring != null else Vector3(tp.x, tp.z, tp.y)
					known_targets[pt.target_id] = {
						"target": pt, "pos": tp, "arc": arc, "last_seen": now, "seen_by": "hunt", "deck": d,
					}
					if not e.is_alerted():
						e.begin_hunt_pursuit(pt, tp)
			else:
				_deck_hunt_refresh[d] = ref_t
		# Step 2 (unengaged straggler reveal after further reveal_hunt_delay_s) & Step 3 (120 s cull measured from reveal).
		for e: EnemyBase in list:
			if e.destroyed():
				continue
			if step1_active and e._hunting and not e.revealed:
				if e._has_los:
					e._hunt_t = 0.0
				else:
					e._hunt_t += dt
					if e._hunt_t >= reveal_hunt_delay_s:
						e.set_revealed(true)
			if e.revealed and not e.destroyed():
				e._revealed_idle_t += dt
				if e._revealed_idle_t >= cull_idle_s:
					e._kill("timeout")


func _alive_players_on_deck(deck: int) -> Array[CombatTarget]:
	var out: Array[CombatTarget] = []
	if world == null:
		return out
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or (t is AssetTarget) or not t.is_hittable() or not t.is_inside_tree():
			continue
		if on_deck(t.global_position, deck):
			out.append(t)
	return out


static func _nearest_target(from_pos: Vector3, list: Array[CombatTarget]) -> CombatTarget:
	var best: CombatTarget = null
	var best_d2 := INF
	for t in list:
		var d2 := from_pos.distance_squared_to(t.global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = t
	return best


# --- Shared Target Board & Delayed Relay ------------------------------------------------------------------

func report_sighting(spotter: EnemyBase, target: CombatTarget, pos: Vector3) -> void:
	if target == null or not is_instance_valid(target) or (target is AssetTarget):
		return
	var now := world.now if world != null else 0.0
	var arc := ring.world_to_arc(pos) if ring != null else Vector3(pos.x, pos.z, pos.y)
	known_targets[target.target_id] = {
		"target": target, "pos": pos, "arc": arc, "last_seen": now, "seen_by": spotter.target_id,
		"deck": spotter.spawn_deck,
	}
	note_deck_activity(spotter.spawn_deck)


func relay_alert_from(spotter: EnemyBase, tid: String) -> void:
	if not known_targets.has(tid):
		return
	var entry: Dictionary = known_targets[tid]
	var target: CombatTarget = entry.get("target")
	if target == null or not is_instance_valid(target) or (target is AssetTarget):
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
	if target == null or not is_instance_valid(target) or (target is AssetTarget) or not target.is_hittable():
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


## Phase 2 Drop Ship call-in (docs/design/enemy-troop-squads.md §6): host-only, strictly capped per deck
## (1 solo / 2 in 3-4p co-op) and only while living defenders already exist on `deck` so MissionRules never soft-locks.
func request_dropship(target_pos: Vector3, deck: int) -> EnemyDropDrone:
	if not Net.is_host() or not drops_enabled or world == null:
		return null
	var count := int(_deck_drops.get(deck, 0))
	if count >= max_drops_per_deck:
		return null
	var living_defenders := 0
	for e in enemies:
		if not is_instance_valid(e) or e.destroyed() or e.spawn_deck != deck:
			continue
		if e.enemy_type == "dropship":
			return null   # one active Drop Ship per deck at a time
		living_defenders += 1
	if living_defenders <= 0:
		return null
	var d_plan: CityPlan = _deck_plans.get(deck, plan) as CityPlan
	var d_ring: RingFrame = ring
	var st := world.city_stack()
	if st != null and st.has_method("deck_ring"):
		d_ring = st.call("deck_ring", deck) as RingFrame
	var zone := _pick_drop_zone(d_plan, d_ring, target_pos, deck)
	if zone.is_empty():
		return null
	_drop_seq += 1
	_deck_drops[deck] = count + 1
	var ds := EnemySpawner.make_enemy("dropship") as EnemyDropDrone
	var sid := "d%d_dropship_%02d" % [deck, _drop_seq]
	ds.configure("dropship", sid, world, self, d_ring, world.mission_seed + _drop_seq)
	ds.spawn_deck = deck
	var spawn_w: Vector3 = zone["spawn"]
	var drop_w: Vector3 = zone["drop"]
	var exfil_w: Vector3 = zone["exfil"]
	var u := d_ring.up_at(spawn_w) if d_ring != null else Vector3.UP
	var f := drop_w - spawn_w
	f -= u * f.dot(u)
	f = f.normalized() if f.length_squared() > 1e-4 else Vector3.FORWARD
	ds.up = u
	ds.transform = Transform3D(Basis(f.cross(u).normalized(), u, -f), spawn_w)
	ds.configure_drop(drop_w, bool(zone["is_roof"]), float(zone["half_span"]), exfil_w)
	add_enemy(ds)
	return ds


func _pick_drop_zone(d_plan: CityPlan, d_ring: RingFrame, target_pos: Vector3, deck: int) -> Dictionary:
	if d_plan == null or d_ring == null:
		# Flat arena / unit-test fallback (no CityPlan): drop 55 m out along -Z from target_pos.
		var drop_f := Vector3(target_pos.x, 0.0, target_pos.z - 55.0)
		var spawn_f := Vector3(target_pos.x - 24.0, EnemyDropDrone.CRUISE_ALT, target_pos.z - 95.0)
		var exfil_f := Vector3(target_pos.x + 40.0, EnemyDropDrone.EXFIL_ALT, target_pos.z - 110.0)
		return {"spawn": spawn_f, "drop": drop_f, "exfil": exfil_f, "is_roof": false, "half_span": 6.0}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([d_plan.checksum(), deck, _drop_seq, "dropship_v2"])
	var t_arc3 := d_ring.world_to_arc(target_pos)
	var t2 := Vector2(t_arc3.x, t_arc3.y)
	var ext := d_plan.extent.grow(-10.0)
	var lane := (d_plan.avenue_x().x + d_plan.avenue_x().y) * 0.5
	# Dropships only drop on road-graph-connected, open street/plaza ground (is_roof = false) so deployed squads
	# can never land on shadowed/enclosed rooftops unreachable to ground mechs or bots.
	var reachable := _reachable_graph_nodes(t2, deck)
	if reachable.is_empty():
		var rg := d_plan.road_graph()
		for n: Vector2 in rg["nodes"]:
			reachable.append(n)
		for l: Dictionary in d_plan.lots:
			if str(l["kind"]) == "open" and str(l.get("open", "")) in ["park", "plaza"]:
				reachable.append((l["rect"] as Rect2).get_center())
	var ideal: Array[Vector2] = []
	var wide: Array[Vector2] = []
	var best_fallback := Vector2(NAN, NAN)
	var best_fallback_d := INF
	for pt in reachable:
		if not _valid_ground_drop_point(d_plan, pt):
			continue
		var d := pt.distance_to(t2)
		if d >= 38.0 and d <= 85.0:
			ideal.append(pt)
		elif d >= 24.0 and d <= 125.0:
			wide.append(pt)
		var score := absf(d - 58.0)
		if score < best_fallback_d:
			best_fallback_d = score
			best_fallback = pt
	var pick_pt := Vector2(NAN, NAN)
	if not ideal.is_empty():
		pick_pt = ideal[rng.randi_range(0, ideal.size() - 1)]
	elif not wide.is_empty():
		pick_pt = wide[rng.randi_range(0, wide.size() - 1)]
	elif not is_nan(best_fallback.x):
		pick_pt = best_fallback
	else:
		return {}
	var far_s := d_plan.extent.end.y - 10.0 if pick_pt.y >= t2.y else d_plan.extent.position.y + 10.0
	var spawn_arc := Vector2(clampf(pick_pt.x + (18.0 if pick_pt.x >= lane else -18.0), ext.position.x, ext.end.x), far_s)
	var exfil_arc := Vector2(clampf(pick_pt.x + (-24.0 if pick_pt.x >= lane else 24.0), ext.position.x, ext.end.x), far_s)
	return {
		"spawn": d_ring.arc_to_world(spawn_arc.x, spawn_arc.y, EnemyDropDrone.CRUISE_ALT),
		"drop": d_ring.arc_to_world(pick_pt.x, pick_pt.y, CityPlan.CURB_H),
		"exfil": d_ring.arc_to_world(exfil_arc.x, exfil_arc.y, EnemyDropDrone.EXFIL_ALT),
		"is_roof": false,
		"half_span": 6.5,
	}


## True when 2D arc point `pt` is open, obstacle-free street/plaza ground with a clear vertical sky shaft for dropship
## descent (no buildings, pillars, columns, floor cuts, keep_clear zones, or deck-to-deck ramps).
static func _valid_ground_drop_point(d_plan: CityPlan, pt: Vector2) -> bool:
	if not d_plan.extent.grow(-10.0).has_point(pt):
		return false
	if d_plan.site != null and not d_plan.clear_at(pt):
		return false
	if not EnemySpawner.clear_of_buildings(d_plan, pt, EnemySpawner.TROOP_CLEAR, 0.0):
		return false
	if not EnemySpawner.clear_of_buildings(d_plan, pt, 3.0, EnemyDropDrone.DROP_HOVER_OFFSET):
		return false
	var margin := EnemySpawner.TROOP_CLEAR + 1.0
	for r: Dictionary in d_plan.ramps:
		var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
		var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
		var rr := Rect2(float(r["x0"]), s0, float(r["x1"]) - float(r["x0"]), s1 - s0).grow(margin)
		if rr.has_point(pt):
			return false
	return true


## All road/plaza graph nodes on `deck` reachable via graph edges from the node nearest `start_arc`.
func _reachable_graph_nodes(start_arc: Vector2, deck: int) -> Array[Vector2]:
	var nodes: Array[Vector2] = (_deck_graphs[deck][0] as Array[Vector2]) if _deck_graphs.has(deck) else _graph_nodes
	var adj: Array = (_deck_graphs[deck][1] as Array) if _deck_graphs.has(deck) else _graph_adj
	var out: Array[Vector2] = []
	if nodes.is_empty():
		return out
	var start := 0
	var best_d := INF
	for i in nodes.size():
		var d := start_arc.distance_squared_to(nodes[i])
		if d < best_d:
			best_d = d
			start = i
	var visited := PackedByteArray()
	visited.resize(nodes.size())
	visited[start] = 1
	var queue: Array[int] = [start]
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		out.append(nodes[cur])
		for nxt: int in adj[cur]:
			if visited[nxt] == 0:
				visited[nxt] = 1
				queue.append(nxt)
	return out


## True when `pos` is on deck `k` (always true without a deck_of: one district).
func on_deck(pos: Vector3, k: int) -> bool:
	return not deck_of.is_valid() or int(deck_of.call(pos)) == k


func _refresh_awake_cache() -> void:
	if world == null:
		return
	var n := world.targets.size()
	if world.now == _awake_at and n == _awake_targets_n:
		return
	_awake_at = world.now
	_awake_targets_n = n
	_awake.clear()
	_crew_pos_by_deck.clear()
	_live_assets.clear()
	var use_decks := deck_of.is_valid()
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t) or t.team != "player" or not t.is_hittable() or not t.is_inside_tree():
			continue
		if t is AssetTarget:
			var at := t as AssetTarget
			if at.asset_id != "":
				_live_assets[at.asset_id] = at
			continue
		# Only standing crew mechs wake a deck or anchor AI LOD — skip Defend relays (AssetTarget).
		var gp := t.global_position
		var dk := int(deck_of.call(gp)) if use_decks else 0
		_awake[dk] = true
		if not _crew_pos_by_deck.has(dk):
			_crew_pos_by_deck[dk] = PackedVector3Array()
		var pts: PackedVector3Array = _crew_pos_by_deck[dk]
		pts.append(gp)
		_crew_pos_by_deck[dk] = pts


## Stack (W4): true while a standing crew mech (excludes Defend AssetTarget) stands on deck `k`. Enemies on a deck nobody
## is on sleep (no AI: nothing there to see, keeping multi-deck encounters within the frame budget). True without deck_of.
func deck_awake(k: int) -> bool:
	if not deck_of.is_valid() or world == null:
		return true
	_refresh_awake_cache()
	return _awake.has(k)


## True while the Defend relay `asset_id` is live (active & hittable) — lets ONLY its own defend wave stay awake
## and push the relay if the crew abandons that deck, while deck garrisons and dormant relays stay asleep.
func is_defend_asset_live(asset_id: String) -> bool:
	if asset_id == "" or world == null:
		return false
	_refresh_awake_cache()
	return _live_assets.has(asset_id)


func live_defend_asset(asset_id: String) -> AssetTarget:
	if asset_id == "" or world == null:
		return null
	_refresh_awake_cache()
	var t: Variant = _live_assets.get(asset_id, null)
	if t != null and is_instance_valid(t) and (t as AssetTarget).is_hittable():
		return t as AssetTarget
	return null


## Minimum squared distance from `pos` to any standing crew mech on `deck` (cached per clock tick for AI LOD & stomp gate).
## Returns -1.0 when no crew mech stands on `deck` (e.g., lab or player-less patrol tests), so callers don't LOD-throttle them.
func min_crew_dist_sq(pos: Vector3, deck: int) -> float:
	if world == null:
		return -1.0
	_refresh_awake_cache()
	var dk := deck if deck_of.is_valid() else 0
	if not _crew_pos_by_deck.has(dk):
		return -1.0
	var pts: PackedVector3Array = _crew_pos_by_deck[dk]
	var best := INF
	for i in pts.size():
		var d2 := pos.distance_squared_to(pts[i])
		if d2 < best:
			best = d2
	return best


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
	if world == null or h == null or not Net.is_host():
		return
	if target is EnemyBase and (target as EnemyBase) in enemies:
		var eb := target as EnemyBase
		note_deck_activity(eb.spawn_deck)
		eb.note_combat_activity(true)
		hear_checks += 1
		_hear_around(h.point, HEAR_IMPACT_RADIUS, 0.0, h.shooter, 0)
		return
	if target != null and target.team == "player" and h.shooter != "":
		for e in enemies:
			if is_instance_valid(e) and e.target_id == h.shooter:
				note_deck_activity(e.spawn_deck)
				e.note_combat_activity(true)
				break


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
	var deck := self_e.spawn_deck
	for other in enemies:
		if not is_instance_valid(other) or other == self_e or other.destroyed() or other.spawn_deck != deck:
			continue
		var op := other.global_position if other.is_inside_tree() else other.position
		var diff := p - op
		var min_d := self_e.body_radius + other.body_radius + SEP_MARGIN
		var d2 := diff.length_squared()
		if d2 > 1e-6 and d2 < min_d * min_d:
			var d := sqrt(d2)
			acc += (diff / d) * ((min_d - d) / min_d)
	return acc


func _build_nav_graph() -> void:
	_graph_nodes.clear()
	_graph_adj.clear()
	_occluders.clear()
	_occluder_rects.clear()
	_cut_rects = [] as Array[Rect2]
	if plan == null:
		return
	if plan.site != null:
		_cut_rects = plan.floor_cuts()
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
			var rr := Rect2(tc - sz * 0.5, sz)
			_occluders.append({"rect": rr, "h": y1 + CityPlan.CURB_H})
			_occluder_rects.append(rr)
		if bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var csz: Vector2 = core["size"]
			var cc := Vector2(float(core["x"]), float(core["s"]))
			var cr := Rect2(cc - csz * 0.5, csz)
			_occluders.append({"rect": cr, "h": 99.0})
			_occluder_rects.append(cr)


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
	var keep_r := _occluder_rects
	var keep_c := _cut_rects
	var keep_p := plan
	_graph_nodes = [] as Array[Vector2]
	_graph_adj = []
	_occluders = []
	_occluder_rects = [] as Array[Rect2]
	plan = deck_plan
	_build_nav_graph()
	_deck_graphs[k] = [_graph_nodes, _graph_adj]
	_deck_plans[k] = deck_plan
	_deck_occluders[k] = _occluders
	_deck_occluder_rects[k] = _occluder_rects
	_deck_cut_rects[k] = _cut_rects
	_graph_nodes = keep_n
	_graph_adj = keep_a
	_occluders = keep_o
	_occluder_rects = keep_r
	_cut_rects = keep_c
	plan = keep_p


## Per-frame AI budget gate: allows at most 1 cover-path A* solve per combat clock tick so enemies alerted on the same
## frame stagger their repaths instead of stacking A* latency into one spike frame.
func claim_cover_repath() -> bool:
	var now := world.now if world != null else -1.0
	if now >= 0.0 and absf(now - _cover_repath_at) < 1e-5:
		return false
	_cover_repath_at = now
	return true


## Cached CityPlan for deck `deck` (or single-district default).
func deck_plan(deck: int = -1) -> CityPlan:
	if _deck_plans.has(deck):
		return _deck_plans[deck] as CityPlan
	return plan


## Cached RingFrame for deck `deck` (or single-district default).
func deck_ring(deck: int = -1) -> RingFrame:
	if _deck_rings.has(deck):
		return _deck_rings[deck] as RingFrame
	return ring


## Nearest road-graph node in 2D arc space for deck `deck` (used by ground unstick recovery).
## Prefers real road crossings (degree >= 2) at least `min_dist` away so unsticking never picks a dead-end or own feet.
func nearest_road_point(arc2: Vector2, deck: int = -1, min_dist: float = 0.0) -> Vector2:
	var nodes: Array[Vector2] = (_deck_graphs[deck][0] as Array[Vector2]) if _deck_graphs.has(deck) else _graph_nodes
	var adj: Array = (_deck_graphs[deck][1] as Array) if _deck_graphs.has(deck) else _graph_adj
	if nodes.is_empty():
		return Vector2(NAN, NAN)
	var min_d2 := min_dist * min_dist
	var best := Vector2(NAN, NAN)
	var best_d := INF
	var fallback := nodes[0]
	var fallback_d := INF
	for i in nodes.size():
		var d := arc2.distance_squared_to(nodes[i])
		if d < fallback_d:
			fallback_d = d
			fallback = nodes[i]
		if d < min_d2:
			continue
		var deg := (adj[i] as Array).size() if i < adj.size() else 0
		var score := d + (4000.0 if deg < 2 else 0.0)
		if score < best_d:
			best_d = score
			best = nodes[i]
	return best if not is_nan(best.x) else fallback


## Cached 2D building occluders [{rect: Rect2, h: float}] for deck `deck` (or single-district default).
func deck_occluders(deck: int = -1) -> Array:
	if _deck_occluders.has(deck):
		return _deck_occluders[deck] as Array
	return _occluders


## Floor cuts of deck deck (or the single-district default) in arc space: ramp mouths and floor holes.
func deck_cuts(deck: int = -1) -> Array[Rect2]:
	if _deck_cut_rects.has(deck):
		return _deck_cut_rects[deck] as Array[Rect2]
	return _cut_rects


## True when segment a-b (arc space) passes within CUT_PATH_MARGIN of a floor cut in cuts.
static func seg_crosses_cuts(a: Vector2, b: Vector2, cuts: Array[Rect2]) -> bool:
	for o: Rect2 in cuts:
		if _segment_hits_rect(a, b, o.grow(CUT_PATH_MARGIN)):
			return true
	return false


## True when arc point p lies inside a floor cut of deck deck, grown by margin.
func in_floor_cut(p: Vector2, deck: int = -1, margin: float = 0.0) -> bool:
	for o: Rect2 in deck_cuts(deck):
		if o.grow(margin).has_point(p):
			return true
	return false


func _deck_occ_rects(deck: int = -1) -> Array[Rect2]:
	if _deck_occluder_rects.has(deck):
		return _deck_occluder_rects[deck] as Array[Rect2]
	return _occluder_rects


## Fast 2D arc-space LOS occlusion check against tall building tiers (>= 6 m) and pillar cores.
func arc_segment_occluded(a: Vector2, b: Vector2, deck: int = -1) -> bool:
	return _arc_seg_occluded_rects(a, b, _deck_occ_rects(deck))


static func _arc_seg_occluded_rects(a: Vector2, b: Vector2, rects: Array[Rect2]) -> bool:
	var min_x := minf(a.x, b.x)
	var max_x := maxf(a.x, b.x)
	var min_y := minf(a.y, b.y)
	var max_y := maxf(a.y, b.y)
	for r: Rect2 in rects:
		if max_x < r.position.x or min_x > r.end.x or max_y < r.position.y or min_y > r.end.y:
			continue
		if _segment_hits_rect(a, b, r):
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
	var rects := _deck_occ_rects(deck)
	var cuts := deck_cuts(deck)
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_arc_path(from_arc, to_arc, rects, cuts)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_arc_path(from_arc, to_arc, rects, cuts)


## Pick nearest navigable road crossing to `p`, avoiding 1-degree park/plaza dead-end spurs (which cause backtracking
## on straight avenues) and preferring un-occluded crossings; optionally restricted to nodes in `allowed` (non-zero).
func _nearest_nav_node(p: Vector2, rects: Array[Rect2], allowed: PackedByteArray = PackedByteArray(),
		cuts: Array[Rect2] = []) -> int:
	var n_count := _graph_nodes.size()
	var use_mask := allowed.size() == n_count
	var best := -1
	var best_score := INF
	for i in n_count:
		if use_mask and allowed[i] == 0:
			continue
		var np := _graph_nodes[i]
		var d2 := p.distance_squared_to(np)
		var deg := (_graph_adj[i] as Array).size()
		# Penalize 1-degree park/plaza spurs and occluded crossings behind building blocks.
		var score := d2
		if deg < 2:
			score += 2500.0
		if score >= best_score:
			continue   # cannot win: skip the segment tests below
		if not rects.is_empty() and d2 > 36.0 and _arc_seg_occluded_rects(p, np, rects):
			score += 3600.0
		# A crossing reached only across a floor cut (a ramp mouth, a hole) is not the one to walk to first.
		if score < best_score and not cuts.is_empty() and d2 > 36.0 and seg_crosses_cuts(p, np, cuts):
			score += 3600.0
		if score < best_score:
			best_score = score
			best = i
	if best >= 0:
		return best
	return _nearest_node(p)


## Mark all nodes reachable from `root` in `_graph_adj` (used as fallback when a floor cut splits the road graph).
func _component_mask(root: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(_graph_nodes.size())
	if root < 0 or root >= _graph_nodes.size():
		return mask
	mask[root] = 1
	var q: Array[int] = [root]
	var head := 0
	while head < q.size():
		var cur := q[head]
		head += 1
		for nb: int in _graph_adj[cur]:
			if mask[nb] == 0:
				mask[nb] = 1
				q.append(nb)
	return mask


## Clean up a reconstructed road path: prepend start node `s` when walking directly to `rev[0]` crosses a building,
## and drop any leading waypoint that lies behind `from_arc` relative to the next open waypoint (eliminates U-turns).
func _finalize_arc_path(from_arc: Vector2, s: int, rev: Array[Vector2], rects: Array[Rect2],
		cuts: Array[Rect2] = []) -> Array[Vector2]:
	if rev.is_empty():
		return rev
	var s_pt := _graph_nodes[s]
	if from_arc.distance_to(s_pt) > 6.5 and not rects.is_empty() and _arc_seg_occluded_rects(from_arc, rev[0], rects):
		rev.push_front(s_pt)
	elif not cuts.is_empty() and rev[0] != s_pt and seg_crosses_cuts(from_arc, rev[0], cuts):
		# The straight line to the first waypoint runs over a floor cut (e.g. diagonally across a ramp mouth, which has
		# no railing): walk to the start crossing first, along the road.
		rev.push_front(s_pt)
	while rev.size() >= 2:
		var v0 := rev[0] - from_arc
		var v1 := rev[1] - rev[0]
		if v0.dot(v1) < 0.0 and (rects.is_empty() or not _arc_seg_occluded_rects(from_arc, rev[1], rects)) \
				and (cuts.is_empty() or not seg_crosses_cuts(from_arc, rev[1], cuts)):
			rev.pop_front()
		else:
			break
	return rev


## Cover-weighted road-graph A* (docs/design/enemy-tactics-and-drones.md §4.2): penalizes nodes and edge midpoints
## that sit in open 2D LOS of `threat_arc` outside `engage_range * 0.75`, steering flankers down occluded side streets.
func find_cover_path(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, deck: int = -1,
		engage_range: float = 60.0) -> Array[Vector2]:
	var rects := _deck_occ_rects(deck)
	var cuts := deck_cuts(deck)
	if rects.is_empty():
		return find_arc_path(from_arc, to_arc, deck)
	if _deck_graphs.has(deck):
		var keep_n := _graph_nodes
		var keep_a := _graph_adj
		_graph_nodes = _deck_graphs[deck][0]
		_graph_adj = _deck_graphs[deck][1]
		var r := _find_cover_path_internal(from_arc, to_arc, threat_arc, rects, engage_range, cuts)
		_graph_nodes = keep_n
		_graph_adj = keep_a
		return r
	return _find_cover_path_internal(from_arc, to_arc, threat_arc, rects, engage_range, cuts)


func _find_cover_path_internal(from_arc: Vector2, to_arc: Vector2, threat_arc: Vector2, rects: Array[Rect2],
		engage_range: float, cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var n_count := _graph_nodes.size()
	if n_count == 0 or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_nav_node(from_arc, rects, PackedByteArray(), cuts)
	var g := _nearest_nav_node(to_arc, rects, PackedByteArray(), cuts)
	if s < 0 or g < 0 or s == g:
		return out
	var safe_band2 := (engage_range * 0.75) * (engage_range * 0.75)
	var node_exp := PackedByteArray()  # 0 = unseen, 1 = occluded, 2 = exposed
	node_exp.resize(n_count)
	var closed := PackedByteArray()
	closed.resize(n_count)
	var open: Array[int] = [s]
	var came := {}
	var g_score := {s: 0.0}
	var goal_p := _graph_nodes[g]
	var f_score := {s: _graph_nodes[s].distance_to(goal_p)}
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
			return _finalize_arc_path(from_arc, s, rev, rects, cuts)
		open.remove_at(best_i)
		closed[cur] = 1
		var cur_p := _graph_nodes[cur]
		var cur_exp := node_exp[cur]
		if cur_exp == 0:
			cur_exp = 1 if (cur_p.distance_squared_to(threat_arc) <= safe_band2 or _arc_seg_occluded_rects(cur_p, threat_arc, rects)) else 2
			node_exp[cur] = cur_exp
		for nb: int in _graph_adj[cur]:
			if closed[nb] != 0:
				continue
			var nb_p := _graph_nodes[nb]
			var step_cost := cur_p.distance_to(nb_p)
			var nb_exp := node_exp[nb]
			if nb_exp == 0:
				nb_exp = 1 if (nb_p.distance_squared_to(threat_arc) <= safe_band2 or _arc_seg_occluded_rects(nb_p, threat_arc, rects)) else 2
				node_exp[nb] = nb_exp
			if nb_exp == 2:
				step_cost += COVER_EXPOSURE_PENALTY
			if cur_exp == 2 or nb_exp == 2:
				var mid := (cur_p + nb_p) * 0.5
				if mid.distance_squared_to(threat_arc) > safe_band2 and not _arc_seg_occluded_rects(mid, threat_arc, rects):
					step_cost += COVER_MID_EXPOSURE_PENALTY
			var tent := float(g_score[cur]) + step_cost
			if tent < float(g_score.get(nb, INF)):
				came[nb] = cur
				g_score[nb] = tent
				f_score[nb] = tent + nb_p.distance_to(goal_p)
				if not nb in open:
					open.append(nb)
	return out


func _find_arc_path(from_arc: Vector2, to_arc: Vector2, rects: Array[Rect2] = [], cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _graph_nodes.is_empty() or from_arc.distance_to(to_arc) < 22.0:
		return out
	var s := _nearest_nav_node(from_arc, rects, PackedByteArray(), cuts)
	var g := _nearest_nav_node(to_arc, rects, PackedByteArray(), cuts)
	if s < 0 or g < 0 or s == g:
		return out
	var res := _astar_arc(from_arc, s, g, rects, cuts)
	if not res.is_empty():
		return res
	# Fallback when a ramp floor cut splits `s` into a disconnected stub: re-pick `s` inside `g`'s connected component.
	var comp := _component_mask(g)
	var s2 := _nearest_nav_node(from_arc, rects, comp, cuts)
	if s2 >= 0 and s2 != s:
		if s2 == g:
			return [_graph_nodes[g]]
		res = _astar_arc(from_arc, s2, g, rects, cuts)
		if not res.is_empty():
			return res
	return out


func _astar_arc(from_arc: Vector2, s: int, g: int, rects: Array[Rect2], cuts: Array[Rect2] = []) -> Array[Vector2]:
	var out: Array[Vector2] = []
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
			return _finalize_arc_path(from_arc, s, rev, rects, cuts)
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
