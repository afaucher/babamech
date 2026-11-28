class_name EnemySquad
extends Node3D
## Host-owned squad coordinator (docs/design/enemies.md §5, §6):
##   - Shared last-known-position target board fed ONLY by real LOS sightings.
##   - Delayed alert propagation (0.45 s relay from spotter to squadmates within RELAY_RADIUS).
##   - Attack-slot arbiter (max `max_attackers` firing at one target simultaneously, fair priority rotation).
##   - Owns the enemies' path service `nav` (EnemyNav: per-deck walk graphs, occluders, floor cuts, A*).
##   - Unified Audio event bus: joins group "enemy_squad" and emits `enemy_event(kind, enemy, payload)`.

const RELAY_RADIUS := 60.0        ## m (perception pass: a block's width; was 52)
const MEMORY_TIME := 14.0         ## s before a target drops off the shared target board
const SEP_MARGIN := 2.6           ## m extra separation between mobile squadmates
const MAX_WRECKS := 10            ## LRU cap on persistent charred/flaming wrecks per squad
## Hearing (host / solo only): an un-alerted live enemy hears PLAYER fire and alerts toward the shooter (hear_fire).
const HEAR_SHOT_RADIUS := 25.0    ## m from its eye to a shot's path (origin -> aim point, clamped to range)
const HEAR_IMPACT_RADIUS := 30.0  ## m (+ the splash radius) from its eye to an impact / blast / hit on a squadmate
const WAVE_PLAYER_CLEAR := 25.0           ## m min distance from standing player mech before wave units emerge from a source
const WAVE_PROXIMITY_MAX_DELAY := 8.0     ## s max hold if a player camps a wave door (< PacingDirector.GRACE = 10 s)
## Per-deck last-enemy hunt / reveal / anti-soft-lock thresholds (host-only, docs/design/enemies.md §5, mission-section.md §15):
## Never hunt or reveal while > HUNT_MAX_REMAINING enemies remain on a deck (including queued wave units) or before
## the crew has actually had combat contact on that deck.
const RAMP_ENTRY_BACK := 5.0              ## m in front of a ramp (before its mouth / past its foot) a transiting wave unit aims for
const RAMP_EXIT_PAST := 8.0               ## m past a ramp's far end on the next deck where its transit ends
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
const SLOT_STALE := 6.0           ## s an attack slot may be held without telegraphing / firing before it is pruned
var max_attackers := 2            ## max simultaneous telegraphing/firing enemies per player target
var slot_stagger := 0.8           ## s breathing gap after a burst before another enemy grabs the slot
var enemies: Array[EnemyBase] = []
var debris_field: EnemyDebrisField
var known_targets: Dictionary = {} ## target_id -> {target, pos, arc, last_seen, seen_by}
var _wrecks: Array[EnemyBase] = []
var _slots: Dictionary = {}        ## enemy_id -> target_id
var _last_slot_time: Dictionary = {} ## enemy_id -> combat clock when it last held a slot
var _slot_ready_at := 0.0          ## combat clock when the next attack slot may be granted
var nav := EnemyNav.new()          ## the enemies' path service (walk graphs, occluders, floor cuts per deck)
## Multi-deck stack (W4): deck k's plan / ring (add_deck_nav, add_enemy), and `deck_of` (world position -> deck index,
## CityStack.deck_at). Enemies path on their own deck's graph (nav) and only engage / hear about targets on it.
var _deck_plans: Dictionary = {}     ## deck k -> CityPlan (for multi-deck Drop Ship drop-zone selection)
var _deck_rings: Dictionary = {}     ## deck k -> RingFrame (learned on add_enemy / add_deck_nav for cross-deck re-homing)
var _deck_drops: Dictionary = {}     ## deck k -> int count of Drop Ships called in on deck k
var max_drops_per_deck := 1          ## cap per deck (1 solo, 2 in 3-4p co-op) so deck-clear never drags on
var drops_enabled := true            ## host toggle for Scout Drone -> Drop Ship call-ins
var air_doors_enabled := true        ## dropships use the decks' air doors when there are any (tests force the fallback)
## Host: orders air door `id` (deck, open_at, hold) open on every machine. MissionFlow sets it (its order goes out as a
## replicated mission.wave order); unset (no MissionFlow: a bare test drive) the door is opened here on this machine only.
var air_door_hook := Callable()
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
var _last_fired: Dictionary = {}  ## shooter target_id -> combat clock of its last shot (perception: a firing mech is loud)
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
var _staged: Dictionary = {}                      ## host: wave_id -> [{e, path, wait}] units waiting in a closed gate bay
var _wave_unreleased_pending: Dictionary = {}     ## wave_id -> int units owed after a partial release (for PacingDirector)
var _wave_decks: Dictionary = {}                  ## wave_id -> int deck index (so queued waves count toward deck remaining)
var _transit_refresh := 0.0                       ## s until the next wave cross-deck transit pick (_step_wave_transit)


func _init() -> void:
	name = "EnemySquad"
	add_to_group("enemy_squad")


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "plan": Net.SPAWN, "ring": Net.SPAWN, "max_attackers": Net.SPAWN,
		"slot_stagger": Net.SPAWN, "enemies": Net.LOCAL, "debris_field": Net.LOCAL, "known_targets": Net.OWNER,
		"_wrecks": Net.LOCAL, "_slots": Net.OWNER, "_last_slot_time": Net.PRIVATE, "_slot_ready_at": Net.PRIVATE,
		"nav": Net.LOCAL, "_deck_plans": Net.LOCAL, "_deck_rings": Net.LOCAL,
		"_deck_drops": Net.OWNER, "max_drops_per_deck": Net.SPAWN,
		"drops_enabled": Net.SPAWN, "air_doors_enabled": Net.LOCAL, "air_door_hook": Net.LOCAL, "_drop_seq": Net.PRIVATE, "_cover_repath_at": Net.PRIVATE,
		"deck_of": Net.LOCAL, "_awake": Net.PRIVATE, "_awake_at": Net.PRIVATE,
		"_awake_targets_n": Net.PRIVATE, "_crew_pos_by_deck": Net.PRIVATE, "_live_assets": Net.LOCAL,
		"_heard": Net.PRIVATE, "hear_checks": Net.PRIVATE, "_last_fired": Net.PRIVATE,
		"hunt_last_quiet_s": Net.SPAWN, "hunt_max_remaining": Net.SPAWN,
		"reveal_hunt_delay_s": Net.SPAWN, "cull_idle_s": Net.SPAWN,
		"_deck_quiet": Net.PRIVATE, "_deck_engaged": Net.PRIVATE, "_deck_hunt_refresh": Net.PRIVATE, "_hunt_tick_acc": Net.PRIVATE,
		"_fireteams": Net.PRIVATE, "_pending_wave_orders": Net.PRIVATE,
		"_wave_spawned_total": Net.PRIVATE, "_staged": Net.PRIVATE, "_wave_unreleased_pending": Net.PRIVATE, "_wave_decks": Net.PRIVATE,
		"_transit_refresh": Net.PRIVATE}


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
	_deck_plans.clear()
	_deck_rings.clear()
	_deck_drops.clear()
	_deck_quiet.clear()
	_deck_engaged.clear()
	_deck_hunt_refresh.clear()
	_fireteams.clear()
	_pending_wave_orders.clear()
	_wave_spawned_total.clear()
	_wave_unreleased_pending.clear()
	_wave_decks.clear()
	_staged.clear()
	_awake.clear()
	_awake_at = -INF
	_awake_targets_n = -1
	_crew_pos_by_deck.clear()
	_live_assets.clear()
	_hunt_tick_acc = 0.0
	_transit_refresh = 0.0
	_drop_seq = 0
	_cover_repath_at = -INF
	nav.reset(plan)


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
			_step_wave_transit(step_dt)


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
	_staged.clear()
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
	_revoke_slot(e.target_id, e)
	enemies.erase(e)
	_wrecks.erase(e)
	if e is EnemyTrooper and (e as EnemyTrooper).fireteam != null:
		(e as EnemyTrooper).fireteam.remove_member(e)
	enemy_removed.emit(e)


func register_fireteam(ft: EnemyTroopSquad) -> void:
	if ft != null and not (ft in _fireteams):
		_fireteams.append(ft)


# --- Mission Waves Phase 1 (Host Scheduler & PacingDirector Count Helpers) ----------------------------------

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


## Queue (or immediately spawn if open_at has passed and source is clear of players) a PacingDirector release order.
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


const ARRIVE_QUEUE := 4.5       ## m between ranks of a ramp group on its ramp
const RAMP_UP_START := 18.0     ## m up the ramp from this deck's end a ramp group's first rank starts
const SHAFT_SPREAD := 2.5       ## m: a shaft group's units start this far apart inside the shaft opening
const SHAFT_UNDER := 1.5        ## m under the upper deck's floor a shaft group starts (inside the opening)
const SHAFT_MIN_GAP := 6.0      ## m: no decks this close (a test fixture): no descent
const LIFT_DOOR_HALF := 5.0     ## m: half the lift door's clear width (MissionLiftDoor.W: two 5 m leaves)
const LIFT_STEP_OUT := 4.0      ## m in front of the lift door a unit steps to before heading for its spot


## Where a ramp / shaft group really comes from (playtest R2.24: "no unit ever appears in the open with no visible source"):
##   ramp  {kind, far_deck, start (world: RAMP_ENTRY_BACK m before the ramp on the deck at its other end), path: [world
##         points: start, the far lip, this deck's end of the ramp], dir_far (Vector2 arc: along s on the far deck, toward
##         the ramp), half (the ramp's half width), xc (this end's centre x)}: the group walks down / up the ramp;
##   shaft {kind, h_up (m: the upper deck's floor above this deck's landing, this deck's frame)}: the group descends
##         through the shaft's opening from just under the upper floor.
## {} for any other source, or when the geometry is missing (a test fixture without decks): the old mouth spawn.
func connector_arrival(source_def: Dictionary, deck: int) -> Dictionary:
	var kind := str(source_def.get("kind", ""))
	var ci := int(source_def.get("connector", -1))
	var here_r := deck_ring(deck)
	if here_r == null:
		return {}
	if kind == "lift" and not source_def.has("bay"):
		# No car interior yet (R2.22 switches staging on by itself): the group steps out of the opening lift doors.
		var mw := mission_world()
		var door: Variant = mw.call("door_nodes").get(str(source_def.get("id", ""))) if mw != null and mw.has_method("door_nodes") else null
		if door == null or not is_instance_valid(door) or not (door is Node3D):
			return {}
		var xf := (door as Node3D).global_transform if (door as Node3D).is_inside_tree() else (door as Node3D).transform
		return {"kind": "lift", "frame": xf}
	if ci < 0 or (kind != "ramp" and kind != "shaft"):
		return {}
	if kind == "shaft":
		var up_r: RingFrame = _deck_rings.get(deck - 1) as RingFrame
		if up_r == null:
			var st := world.city_stack() if world != null else null
			if st != null and st.has_method("deck_ring") and deck - 1 >= 0:
				up_r = st.call("deck_ring", deck - 1) as RingFrame
		if up_r == null:
			return {}
		var gap := here_r.radius - up_r.radius
		if gap < SHAFT_MIN_GAP:
			return {}
		return {"kind": "shaft", "h_up": gap}
	var here_p := deck_plan(deck)
	if here_p == null:
		return {}
	var near_part := {}
	for r: Dictionary in here_p.ramps:
		if int(r["connector"]) == ci:
			near_part = r
	if near_part.is_empty():
		return {}
	for kk: Variant in _deck_plans.keys():
		var k2 := int(kk)
		if k2 == deck or absi(k2 - deck) != 1:
			continue
		var fp := _deck_plans[kk] as CityPlan
		var fr := deck_ring(k2)
		if fp == null or fr == null:
			continue
		for r: Dictionary in fp.ramps:
			if int(r["connector"]) != ci:
				continue
			var down := deck > k2   # deck k + 1 is below deck k: coming down from the far (upper) deck
			var fxc := (float(r["x0"]) + float(r["x1"])) * 0.5
			var fdir := signf(float(r["s_foot"]) - float(r["s_top"]))   # downhill along s on the far deck
			var lip_s := float(r["s_top"]) if down else float(r["s_foot"])
			var toward := fdir if down else -fdir                         # walking direction on the far deck
			var start_a := Vector2(fxc, lip_s - toward * RAMP_ENTRY_BACK)
			var nxc := (float(near_part["x0"]) + float(near_part["x1"])) * 0.5
			var end_s := float(near_part["s_foot"]) if down else float(near_part["s_top"])
			var start_w := fr.arc_to_world(start_a.x, start_a.y, CityPlan.CURB_H)
			return {"kind": "ramp", "far_deck": k2, "start": start_w,
				"path": [start_w, fr.arc_to_world(fxc, lip_s, CityPlan.CURB_H), here_r.arc_to_world(nxc, end_s, CityPlan.CURB_H)],
				"dir_far": Vector2(0.0, toward), "half": (float(near_part["x1"]) - float(near_part["x0"])) * 0.5, "xc": nxc,
				"far_ring": fr}
	return {}


## Ramp / shaft group: each unit starts at the connector (ramp: queued on the far deck behind the ramp's lip, in its lane;
## shaft: inside the opening under the upper floor) and walks / flies its arrival kinematically (EnemyBase.roll_out) to the
## spot the spawner gave it on this deck; the AI takes over there. Its spawn_deck stays this deck (re-homing skips units
## rolling out).
func _arrive_through_connector(entry: Dictionary, specs: Array[Dictionary], spawned: Array[EnemyBase]) -> void:
	var src_def: Dictionary = entry["source"]
	var deck := int(entry["deck"])
	var arr := connector_arrival(src_def, deck)
	if arr.is_empty():
		return
	var ring_h := deck_ring(deck)
	for i in mini(spawned.size(), specs.size()):
		var e := spawned[i]
		var sp := specs[i]
		var goal := Vector3(float(sp["x"]), float(sp["s"]), float(sp["h"]))
		var air := BayFormation.is_air(e.enemy_type)
		var r := BayFormation.radius_of(e.enemy_type)
		var path: Array[Vector3] = []
		var start_w: Vector3
		var wait := 0.0
		if str(arr["kind"]) == "lift":
			# Just behind the leaves (hidden while they are shut), across the 10 m door; out once the doors are open.
			var fxf: Transform3D = arr["frame"]
			var lat := clampf((float(i % 3) - 1.0) * 3.0, -(LIFT_DOOR_HALF - r), LIFT_DOOR_HALF - r)
			start_w = fxf * Vector3(lat, 0.0, -1.0 - float(i / 3) * 2.5)
			var step_w := fxf * Vector3(lat, 0.0, LIFT_STEP_OUT)
			var a0 := ring_h.world_to_arc(step_w)
			path.append(Vector3(a0.x, a0.y, CityPlan.CURB_H if not air else goal.z))
			path.append(goal)
			wait = MissionWorld.LIFT_OPEN + float(i) * 0.35
		elif str(arr["kind"]) == "ramp":
			var lane_half := maxf(float(arr["half"]) - r - 0.4, 0.0)
			var lane := clampf(goal.x - float(arr["xc"]), -lane_half, lane_half)
			# On the ramp itself, RAMP_UP_START m up it from this deck's end (ranks ARRIVE_QUEUE m further up, never past the
			# far lip), coming down / up it in its lane: the crew sees them come along the ramp, and contact stays as quick
			# as a ramp release is tuned for (the whole ramp from the far deck added 20+ s: test_wave_pursuit).
			var rank := i / 2
			var pts: Array = arr["path"]
			var lip_a := ring_h.world_to_arc(pts[1] as Vector3)
			var end_a := ring_h.world_to_arc(pts[2] as Vector3)
			var along := lip_a - end_a
			var up_d := minf(RAMP_UP_START + ARRIVE_QUEUE * float(rank), along.length())
			var st_a := end_a + along.normalized() * up_d if along.length() > 0.01 else end_a
			start_w = ring_h.arc_to_world(st_a.x + lane, st_a.y, st_a.z)
			path.append(Vector3(end_a.x + lane, end_a.y, end_a.z))
			path.append(goal)
		else:
			var h_up := float(arr["h_up"])
			var off := Vector2(SHAFT_SPREAD * (float(i % 2) - 0.5) * 2.0, SHAFT_SPREAD * (float((i / 2) % 2) - 0.5) * 2.0)
			var src_pt := Vector2(float(src_def.get("x", goal.x)), float(src_def.get("s", goal.y)))
			var top_h := h_up - SHAFT_UNDER
			start_w = ring_h.arc_to_world(src_pt.x + off.x, src_pt.y + off.y, top_h)
			var low := minf(goal.z, top_h) if air else CityPlan.CURB_H
			path.append(Vector3(src_pt.x + off.x, src_pt.y + off.y, low))
			path.append(goal)
		var up := ring_h.up_at(start_w)
		var f := ring_h.arc_to_world(path[0].x, path[0].y, path[0].z) - start_w
		f -= up * f.dot(up)
		e.up = up
		var xf := Transform3D(e.transform.basis, start_w)
		if f.length_squared() > 1e-4:
			f = f.normalized()
			xf = Transform3D(Basis(f.cross(up).normalized(), up, -f), start_w)
		if e.is_inside_tree():
			e.global_transform = xf
		else:
			e.transform = xf
		e.roll_out(path, wait)


func _release_wave_entry(entry: Dictionary) -> Array[EnemyBase]:
	var wave_id := str(entry["wave"])
	var deck := int(entry["deck"])
	var use_plan := entry["plan"] as CityPlan
	var use_ring := entry["ring"] as RingFrame
	var specs: Array[Dictionary] = entry["specs"]
	var spawned := EnemySpawner.spawn_specs(specs, use_plan, use_ring, world, self,
		int(entry["seed"]), bool(entry["skip_meshes"]), "", deck, wave_id)
	_wave_spawned_total[wave_id] = int(_wave_spawned_total.get(wave_id, 0)) + spawned.size()
	# Gate-bay staging: units created in a closed bay wait (dormant) for roll_out_wave() when the door is passable.
	if not specs.is_empty() and bool(specs[0].get("staged", false)):
		var lst: Array = _staged.get(wave_id, [])
		for i in spawned.size():
			var path: Array[Vector3] = []
			for p: Variant in specs[i].get("exit", []):
				path.append(p as Vector3)
			lst.append({"e": spawned[i], "path": path, "wait": float(specs[i].get("exit_wait", 0.0))})
		_staged[wave_id] = lst
		return spawned
	# Ramp / shaft groups come in through their connector (playtest R2.24: never appear in the open with no source).
	_arrive_through_connector(entry, specs, spawned)
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


## Host: the door of a staged group is passable: wake its units, give each its hunt target and its roll-out lane
## (BayFormation: row by row). Returns the units rolled out.
func roll_out_wave(wave_id: String) -> int:
	var lst: Array = _staged.get(wave_id, [])
	_staged.erase(wave_id)
	var n := 0
	var deck := -1
	for st: Dictionary in lst:
		var ev: Variant = st["e"]
		if ev == null or not is_instance_valid(ev):
			continue   # freed while staged (culled, the drive torn down)
		var e := ev as EnemyBase
		if e.destroyed():
			continue
		deck = e.spawn_deck
		var pos := e.global_position if e.is_inside_tree() else e.position
		var hunt_t := _nearest_player_on_deck(pos, e.spawn_deck)
		if hunt_t == null and e.defend_target_id != "":
			hunt_t = _asset_target_by_id(e.defend_target_id)
		e.roll_out(st["path"], float(st["wait"]))
		if hunt_t != null:
			if not (hunt_t is AssetTarget):
				e.hear_fire(hunt_t)
			e.begin_hunt_pursuit(hunt_t, hunt_t.global_position)
		n += 1
	if n > 0 and deck >= 0:
		note_deck_activity(deck)
	return n


## Host: the units of `wave_id` still staged (waiting for their door), live ones only.
func staged_units(wave_id: String) -> Array[EnemyBase]:
	var out: Array[EnemyBase] = []
	for st: Dictionary in _staged.get(wave_id, []):
		var ev: Variant = st["e"]
		if ev != null and is_instance_valid(ev) and not (ev as EnemyBase).destroyed():
			out.append(ev as EnemyBase)
	return out


## Host: take `e` out of the mission without a death (docs/design/pacing-director.md 1.6b, playtest R2.4): a unit left in
## a bay behind a door that will not open again, or a staged unit whose door never opens. No wreck, no explosion, no kill
## credit (PacingFacts skips it: meta "withdrawn"); it leaves the squad (EnemySync sends "gone"), so a deck's sweep and the
## director's "group beaten" never wait on it. Returns false when it was already gone.
func withdraw(e: EnemyBase, cause: String) -> bool:
	if e == null or not is_instance_valid(e) or e.is_queued_for_deletion() or not (e in enemies):
		return false
	for wid: Variant in _staged.keys():
		var lst: Array = _staged[wid]
		for i in range(lst.size() - 1, -1, -1):
			if lst[i]["e"] == e:
				lst.remove_at(i)
	e.set_meta("withdrawn", cause)
	var pos := e.global_position if e.is_inside_tree() else e.position
	remove_enemy(e)
	if world != null:
		world.unregister(e)
	emit_enemy_event("withdrawn", e, {"id": e.target_id, "cause": cause, "pos": pos, "wave": e.wave})
	e.queue_free()
	return true


## Host: withdraw every unit of `wave_id` still staged (its door got sealed / never opened: rule 5). Returns how many.
func unstage_wave(wave_id: String, cause: String) -> int:
	var n := 0
	for e in staged_units(wave_id):
		if withdraw(e, cause):
			n += 1
	_staged.erase(wave_id)
	return n


## Host (PacingDirector's quiet cap when no group can make contact in time): send the `n` mobile garrison units of `deck`
## nearest `near` (world) hunting the nearest standing crew mech (begin_hunt_pursuit: the fastest reliable contact).
## Units already hunting or alerted are skipped. Returns how many were sent.
func send_garrison_hunt(deck: int, n: int, near: Vector3) -> int:
	var cands: Array = []
	for e in enemies:
		if not is_instance_valid(e) or e.destroyed() or e.puppet or e.wave != "" or e.spawn_deck != deck \
				or not e.is_mobile() or e.is_alerted() or e.ai_mode != "live":
			continue
		var pos := e.global_position if e.is_inside_tree() else e.position
		cands.append([pos.distance_squared_to(near), e])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var sent := 0
	for c: Array in cands:
		if sent >= n:
			break
		var e := c[1] as EnemyBase
		var pos := e.global_position if e.is_inside_tree() else e.position
		var pt := _nearest_player_on_deck(pos, deck)
		if pt == null:
			break
		e.hear_fire(pt)
		e.begin_hunt_pursuit(pt, pt.global_position)
		sent += 1
	if sent > 0:
		note_deck_activity(deck)
	return sent


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


## Host fact for PacingDirector (`facts["garrison_alive"]`): count of living garrison enemies (`wave == ""`) per deck.
func alive_garrison_per_deck(decks: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(maxi(decks, 1))
	out.fill(0)
	for e in enemies:
		if is_instance_valid(e) and not e.destroyed() and not e.is_queued_for_deletion() and e.wave == "":
			var k := clampi(e.spawn_deck, 0, out.size() - 1)
			out[k] += 1
	return out


## Host fact for PacingDirector (`facts["wave_alive"]`): {wave_id: {"alive": int, "total": int spawned so far}}.
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


## Host fact for PacingDirector (`facts["wave_pending"]`): {wave_id: units owed after a partial release (> 0 only)}.
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
		if not is_instance_valid(e) or e.puppet or e.destroyed() or e.enemy_type == "dropship" or e.staged \
				or e.is_rolling_out():
			continue   # staged in a bay, or walking a scripted arrival / roll-out path (in its spawn deck's frame)
		var pos := e.global_position if e.is_inside_tree() else e.position
		# 1. Fell completely out below the lowest deck -> cull so it never counts toward the mission!
		if lowest_ring != null and lowest_ring.height(pos) < -18.0:
			e.despawn("fell_out")
			continue
		# 2. Crossed to another deck (e.g. knocked down a shaft or drone traversing decks) -> re-home dynamically!
		if deck_of.is_valid():
			var cur_d := int(deck_of.call(pos))
			if cur_d >= 0 and cur_d != e.spawn_deck:
				var old_d := e.spawn_deck
				e.rehome_deck(cur_d, deck_ring(cur_d))
				enemy_deck_changed.emit(e, old_d, cur_d)
				if e.wave != "" and e.is_mobile():
					# A wave unit arriving on a crewed deck (ramp transit, knocked down a shaft) hunts at once.
					var pt := _nearest_player_on_deck(pos, cur_d)
					if pt != null:
						var tp := e.target_aim_center(pt)
						var cr := deck_ring(cur_d)
						known_targets[pt.target_id] = {
							"target": pt, "pos": tp, "arc": cr.world_to_arc(tp) if cr != null else Vector3(tp.x, tp.z, tp.y),
							"last_seen": world.now, "seen_by": "hunt", "deck": cur_d,
						}
						e.begin_hunt_pursuit(pt, tp)
				continue
		# 3. Left the mission deck horizontally (past outer walls + recess margin) -> cull so it never blocks clear!
		var dp := deck_plan(e.spawn_deck)
		var dr := deck_ring(e.spawn_deck)
		if dp != null and dr != null:
			var a3 := dr.world_to_arc(pos)
			if not dp.extent.grow(28.0).has_point(Vector2(a3.x, a3.y)):
				e.despawn("fell_out")


## Host-only, 1 Hz: wave units never sleep (EnemyBase._is_awake). A mobile ground wave unit on a deck with no standing crew
## mech heads for the deck of the nearest crew (fewest decks away, then nearest) one deck at a time, over the section's
## ramps (the only connector a walker can use: lifts and shafts are wave doors, not paths). A unit already on a ramp
## finishes it, except that it turns round (EnemyBase.reverse_transit) when the crew is back on the deck it is leaving and
## not on the one it is walking to. Its target here is the entry of
## the nearest ramp on its deck that leads one deck toward the crew; EnemyBase._step_transit walks it there and down / up
## the ramp, and _step_deck_rehome re-homes it as it changes deck. A unit with a target on its own deck (a live defend
## relay, crew) ignores the transit; garrisons (wave == "") are never moved and keep sleeping.
func _step_wave_transit(dt: float) -> void:
	_transit_refresh -= dt
	if _transit_refresh > 0.0:
		return
	_transit_refresh = 1.0
	if not deck_of.is_valid() or world == null:
		return
	_refresh_awake_cache()
	for e in enemies:
		if not is_instance_valid(e) or e.puppet or e.destroyed() or e.wave == "" or e.ai_mode != "live" \
				or not e.is_mobile() or e is EnemyDrone or e is EnemyGunship or e is EnemyDropDrone:
			continue
		if e.is_on_transit_ramp():
			# Mid-ramp: finish it, unless the crew now stands on the deck it is leaving and not on the one it walks to.
			var from_d := e.transit_from_deck()
			if from_d >= 0 and _awake.has(from_d) and not _awake.has(e.transit_to_deck()):
				e.reverse_transit()
			continue
		var d := e.spawn_deck
		if _awake.has(d) or _crew_pos_by_deck.is_empty():
			e.clear_transit()   # crew on its deck (normal hunt), or no standing crew anywhere
			continue
		if e.defend_target_id != "":
			var relay := live_defend_asset(e.defend_target_id)
			if relay != null and on_deck(relay.global_position, d):
				e.clear_transit()   # pushing its live relay on this deck
				continue
		var pos := e.global_position if e.is_inside_tree() else e.position
		var goal_deck := -1
		var best := INF
		for dk: int in _crew_pos_by_deck.keys():
			var pts: PackedVector3Array = _crew_pos_by_deck[dk]
			for i in pts.size():
				var score := float(absi(dk - d)) * 1.0e6 + pos.distance_squared_to(pts[i])
				if score < best:
					best = score
					goal_deck = dk
		if goal_deck < 0 or goal_deck == d:
			continue
		var tr := _ramp_transit(pos, d, d + signi(goal_deck - d))
		if tr.is_empty():
			e.clear_transit()
			continue
		e.set_transit(int(tr["deck"]), tr["entry"] as Vector3, tr["exit"] as Vector3)


## The ramp from deck `d` to the adjacent deck `to_d` nearest `from_pos` (straight-line to its entry): {deck, entry, exit}
## in world positions, entry on deck d's floor RAMP_ENTRY_BACK m in front of the ramp (before the mouth going down,
## past the foot going up), exit on deck to_d's floor RAMP_EXIT_PAST m beyond the ramp's far end. {} when none.
func _ramp_transit(from_pos: Vector3, d: int, to_d: int) -> Dictionary:
	var dp := deck_plan(d)
	var tp := deck_plan(to_d)
	var dr := deck_ring(d)
	var tr := deck_ring(to_d)
	if dp == null or tp == null or dr == null or tr == null or dp == tp:
		return {}
	var down := to_d > d   # deck k + 1 is the one below deck k (larger radius)
	var a3 := dr.world_to_arc(from_pos)
	var a := Vector2(a3.x, a3.y)
	var out := {}
	var best := INF
	for r: Dictionary in dp.ramps:
		if str(r["role"]) != ("top" if down else "bottom"):
			continue
		var other := {}
		for r2: Dictionary in tp.ramps:
			if int(r2["connector"]) == int(r["connector"]) and str(r2["role"]) != str(r["role"]):
				other = r2
				break
		if other.is_empty():
			continue
		var xc := (float(r["x0"]) + float(r["x1"])) * 0.5
		var dir := signf(float(r["s_foot"]) - float(r["s_top"]))   # this part's downhill direction along s
		var entry := Vector2(xc, float(r["s_top"]) - dir * RAMP_ENTRY_BACK) if down \
			else Vector2(xc, float(r["s_foot"]) + dir * RAMP_ENTRY_BACK)
		var oxc := (float(other["x0"]) + float(other["x1"])) * 0.5
		var odir := signf(float(other["s_foot"]) - float(other["s_top"]))
		var exit := Vector2(oxc, float(other["s_foot"]) + odir * RAMP_EXIT_PAST) if down \
			else Vector2(oxc, float(other["s_top"]) - odir * RAMP_EXIT_PAST)
		var dd := a.distance_squared_to(entry)
		if dd < best:
			best = dd
			out = {"deck": to_d, "entry": dr.arc_to_world(entry.x, entry.y, CityPlan.CURB_H),
				"exit": tr.arc_to_world(exit.x, exit.y, CityPlan.CURB_H)}
	return out


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
			if e.is_hunting() and e.is_mobile():
				any_hunting = true
		var straggler_eligible := total_remaining <= hunt_max_remaining and bool(_deck_engaged.get(d, false))
		var step1_active := false
		if straggler_eligible:
			var quiet := float(_deck_quiet.get(d, 0.0)) + dt
			_deck_quiet[d] = quiet
			if quiet >= hunt_last_quiet_s:
				step1_active = true
				for e: EnemyBase in list:
					e.start_hunt()
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
					if not e.is_hunting() or not e.is_mobile():
						continue
					var pt := _nearest_target(e.global_position if e.is_inside_tree() else e.position, players)
					if pt == null:
						continue
					var tp := e.target_aim_center(pt)
					var d_ring := deck_ring(d)
					var arc := d_ring.world_to_arc(tp) if d_ring != null else Vector3(tp.x, tp.z, tp.y)
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
			if step1_active and e.is_hunting() and not e.revealed:
				if e.step_hunt(dt, reveal_hunt_delay_s):
					e.set_revealed(true)
			if e.revealed and not e.destroyed():
				if e.step_revealed_idle(dt, cull_idle_s):
					e.despawn("timeout")


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
	# Only ever through an air door (playtest R2.24: "no unit appears from nowhere"): a deck with no usable air door RIGHT
	# NOW (none built, sealed, not usable) gets no dropship: the call is dropped (the scout's director call still goes to
	# a ground source). There is no in-deck appear point any more.
	var drop_a := d_ring.world_to_arc(zone["drop"] as Vector3) if d_ring != null else Vector3.ZERO
	var air := pick_air_door(deck, Vector2(drop_a.x, drop_a.y), true)
	if air.is_empty():
		print("[enemy] dropship on deck %d dropped: no usable air door" % deck)
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
	# Created hidden in the air door's recess, dormant (staged, not hittable), the door ordered open (the crew's alert).
	var fw: Vector3 = air["facing"]
	var hu := d_ring.up_at(air["hide"] as Vector3) if d_ring != null else Vector3.UP
	fw = (fw - hu * fw.dot(hu)).normalized()
	ds.up = hu
	ds.transform = Transform3D(Basis(fw.cross(hu).normalized(), hu, -fw), air["hide"] as Vector3)
	ds.configure_air_arrival(air)
	add_enemy(ds)
	var now := air_door_clock()
	ds.air_ordered_at = now
	order_air_door(str(air["id"]), deck, now + EnemyDropDrone.AIR_ORDER_LEAD, EnemyDropDrone.AIR_ARRIVE_HOLD, true)
	return ds


## The deck's mission world (air doors), or null.
func mission_world() -> Object:
	var st := world.city_stack() if world != null else null
	var mw: Variant = st.get("mission") if st != null else null
	return mw if mw is Object and (mw as Object).has_method("air_door_count") else null


## Host: the air door of `deck` a dropship should use near arc point `near` ({} = none usable: no dropship).
## Usable: it exists (`ok`), Environment calls it usable (`usable`, when the key exists: a clear straight approach for the
## hull at door height) and it is not sealed. Score: the straight distance from its `out` point to `near`, + AIR_SEEN_PENALTY
## when `hidden_from_crew` and a standing crew mech on the deck is within AIR_SEEN_R of `out` with a clear sightline over
## the plan's buildings (a cheap check: the crew should not watch it come out). Deterministic (ties: lower index).
func pick_air_door(deck: int, near: Vector2, hidden_from_crew: bool) -> Dictionary:
	if not air_doors_enabled:
		return {}
	var mw := mission_world()
	if mw == null:
		return {}
	var d_ring := deck_ring(deck)
	var crew: Array[Vector2] = []
	if hidden_from_crew and world != null:
		for t: CombatTarget in world.targets:
			if is_instance_valid(t) and t.team == "player" and t.is_hittable() and t.is_inside_tree() and on_deck(t.global_position, deck):
				var ta := d_ring.world_to_arc(t.global_position) if d_ring != null else Vector3(t.global_position.x, t.global_position.z, 0.0)
				crew.append(Vector2(ta.x, ta.y))
	var best := {}
	var best_score := INF
	for i in int(mw.call("air_door_count", deck)):
		var d: Dictionary = mw.call("air_door", deck, i)
		if not bool(d.get("ok", false)) or not bool(d.get("usable", true)):
			continue
		if str((mw.call("source_state", d["id"]) as Dictionary).get("state", "")) == "sealed":
			continue
		var oa := d_ring.world_to_arc(d["out"] as Vector3) if d_ring != null else Vector3((d["out"] as Vector3).x, (d["out"] as Vector3).z, 0.0)
		var out2 := Vector2(oa.x, oa.y)
		var score := out2.distance_to(near)
		for c: Vector2 in crew:
			if c.distance_to(out2) <= AIR_SEEN_R and not nav.arc_segment_occluded(c, out2, deck):
				score += AIR_SEEN_PENALTY
				break
		if score < best_score:
			best_score = score
			best = d.duplicate()
			best["i"] = i
	return best


## Host: order air door `id` open at `open_at` for `hold` s (after its opening) on every machine (air_door_hook), or
## here only. Called again with the same open_at and a longer hold it only extends the hold (MissionWorld.open_source).
## `arriving`: a dropship comes out through it (the crew's "Dropship, north air door" alert; not for its way back in).
func order_air_door(id: String, deck: int, open_at: float, hold: float, arriving: bool = false) -> void:
	if air_door_hook.is_valid():
		air_door_hook.call(id, deck, open_at, hold, arriving)
		return
	var mw := mission_world()
	if mw != null:
		mw.call("open_source", id, open_at, hold)


## The clock air door times are on: the mission world's (MissionWorld.now: the mission clock, MissionFlow.now()), NOT
## CombatWorld.now, which runs from another start (orders and holds on the combat clock left a door open far too long).
func air_door_clock() -> float:
	var mw := mission_world()
	if mw != null:
		return float(mw.get("now"))
	return world.now if world != null else 0.0


## The door state of air door `id` (MissionWorld.source_state) or {} without a mission world.
func air_door_state(id: String) -> Dictionary:
	var mw := mission_world()
	return mw.call("source_state", id) as Dictionary if mw != null else {}


const AIR_SEEN_R := 140.0      ## m: a crew mech this close to an air door's out point with a clear sightline sees it
const AIR_SEEN_PENALTY := 260.0 ## m added to that door's score (another door, even farther, is preferred)


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
	var reachable := nav.reachable_nodes(t2, deck)
	if reachable.is_empty():
		var rg := CityGraphs.walk_graph(d_plan)   # its nodes are road_graph()'s
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
	# The ship appears / leaves there (no flying door yet): never inside a building, pillar or ramp's footprint.
	spawn_arc = _air_clear_point(spawn_arc, deck, ext)
	exfil_arc = _air_clear_point(exfil_arc, deck, ext)
	return {
		"spawn": d_ring.arc_to_world(spawn_arc.x, spawn_arc.y, EnemyDropDrone.CRUISE_ALT),
		"drop": d_ring.arc_to_world(pick_pt.x, pick_pt.y, CityPlan.CURB_H),
		"exfil": d_ring.arc_to_world(exfil_arc.x, exfil_arc.y, EnemyDropDrone.EXFIL_ALT),
		"is_roof": false,
		"half_span": 6.5,
	}


## The nearest point to `at` (searched across the deck, then inward along s, 4 m steps) whose column is clear of every
## building / pillar / tower footprint and ramp of `deck` by EnemyDropDrone.CLEAR_H: where a dropship may appear.
func _air_clear_point(at: Vector2, deck: int, ext: Rect2) -> Vector2:
	var blocks: Array[Rect2] = []
	for item: Dictionary in nav.deck_occluders(deck):
		blocks.append((item["rect"] as Rect2).grow(EnemyDropDrone.CLEAR_H))
	var d_plan := deck_plan(deck)
	if d_plan != null:
		for c: Dictionary in d_plan.columns:
			var ch := float(c.get("half", 2.0))
			blocks.append(Rect2(float(c["x"]) - ch, float(c["s"]) - ch, ch * 2.0, ch * 2.0).grow(EnemyDropDrone.CLEAR_H))
		for r: Dictionary in d_plan.ramps:
			var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
			var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
			blocks.append(Rect2(float(r["x0"]), s0, float(r["x1"]) - float(r["x0"]), s1 - s0).grow(EnemyDropDrone.CLEAR_H))
	var inward := 1.0 if at.y < ext.get_center().y else -1.0
	for ring_i in 40:
		for side: float in [0.0, 1.0, -1.0]:
			for k in (1 if side == 0.0 else ring_i):
				var p := Vector2(clampf(at.x + side * 4.0 * float(k + 1), ext.position.x, ext.end.x), at.y + inward * 4.0 * float(ring_i))
				var free := true
				for b: Rect2 in blocks:
					if b.has_point(p):
						free = false
						break
				if free:
					return p
	return at


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
	var ext := float(e.unit_cfg().get("hear_radius", 0.0))
	return maxf(base_r, ext) + bonus


## True when player target `tid` fired within `window` s (EnemyBase perception: a firing mech is noticed in any
## direction inside its notice range, with a clear line; host / solo only, like the hearing).
func fired_recently(tid: String, window: float) -> bool:
	return world != null and _last_fired.has(tid) and world.now - float(_last_fired[tid]) <= window


func _on_shot_fired(record: Dictionary) -> void:
	if not _hearing(record):
		return
	hear_checks += 1
	var who := _shooter_of(str(record.get("shooter", "")), int(record.get("peer", 0)))
	if who != null:
		_last_fired[who.target_id] = world.now
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
	var now := world.now if world != null else 0.0
	prune_attack_slots(now)
	if active_slots_for(tid) >= maxi(max_attackers, 1):
		return false
	if slot_stagger > 0.0 and now < _slot_ready_at:
		return false
	_slots[enemy_id] = tid
	_last_slot_time[enemy_id] = now - priority * 0.05
	return true


## Drop slot holders that can no longer use their slot: dead or gone, asleep (their deck has no crew: they never tick
## again to release it), switched to another target, or holding it SLOT_STALE s without telegraphing / firing (lost the
## target, wandered off). A sleeping holder used to keep a solo pilot's only slot forever (no enemy fired for 340 s).
func prune_attack_slots(now: float) -> void:
	if _slots.is_empty():
		return
	var by_id := {}
	for e in enemies:
		if is_instance_valid(e):
			by_id[e.target_id] = e
	for eid: String in _slots.keys():
		var e: EnemyBase = by_id.get(eid)
		var keep := e != null and not e.destroyed() and e.is_awake() and e.current_target_id() == str(_slots[eid])
		var busy: bool = e != null and e.ai_state in [EnemyBase.STATE_TELEGRAPH, EnemyBase.STATE_FIRE, EnemyBase.STATE_COOLDOWN]
		if keep and not busy and now - float(_last_slot_time.get(eid, now)) > SLOT_STALE:
			keep = false
		if not keep:
			_revoke_slot(eid, e)


## The one place a slot is taken away from its holder (pruned, or the unit left the squad): erases it here AND clears
## the holder's own flag (EnemyBase.slot_revoked), so the unit must request again instead of firing on a slot it no
## longer holds (it used to keep _has_slot and fire on top of max_attackers after its deck slept and woke).
func _revoke_slot(eid: String, e: EnemyBase) -> void:
	_slots.erase(eid)
	if e != null and is_instance_valid(e):
		e.slot_revoked()


func release_attack_slot(enemy_id: String) -> void:
	if _slots.has(enemy_id):
		_slots.erase(enemy_id)
		var now := world.now if world != null else 0.0
		var gap := slot_stagger if max_attackers <= 1 else slot_stagger * 0.35
		_slot_ready_at = maxf(_slot_ready_at, now + gap)


# --- Separation, Deck Registry & Cover-Path Budget (paths: EnemyNav) -------------------------------------------

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


## Registers stack deck k: its plan (deck_plan) and its walk graph / occluders / cuts in `nav`.
func add_deck_nav(k: int, deck_plan: CityPlan) -> void:
	nav.add_deck(k, deck_plan)
	_deck_plans[k] = deck_plan


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

