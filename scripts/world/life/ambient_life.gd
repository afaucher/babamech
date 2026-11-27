class_name AmbientLife
extends Node3D
## The civilians and driverless vehicles of one city district or one whole section stack (docs/design/ambient-life.md;
## phases 1-3: people, pods, service carts, the tram, checkpoints). One node per scene, group "ambient_life". A
## host-arbitrated world system built from scheduled effects:
##   * calm life is a timetable (LifePlan.calm_pose, LifeTraffic.base_pose, LifeTram.base): free on the network, the same
##     everywhere;
##   * the host raises threats (raise_threat, or bound to CombatWorld / CityProps / pushers), merges them (10 m, 0.25 s)
##     and sends at most 4 a second per deck: "life.threat" {x, s, r, st, t}; every machine derives the reactions of people
##     (LifeCrowd), vehicles (LifeFleet) and the tram (LifeTram) from it;
##   * the machine that owns a shot tests it (sweep / blast, world space) and asks the host: "life.req" {id, dir, src} for a
##     person, "life.wreq" {id, dir, src, how, v0} for a vehicle; the host decides "life.down" {id, t, dir, src} and
##     "life.wreck" {id, t, x, s, yaw, tilt0, tilt1, roll, dir, v0, len, src}; a joiner gets "life.sync" {bytes}.
## Offline (no session) the same code decides locally. Transport through Session.send_event only.
##
## THIS NODE IS THE ROUTER; the life of each deck is a LifeDeck (child "Deck<k>", not in the group: sampling, drawing,
## threats, weapons, pushers). This node is the session listener and steps its decks every frame.
## A DISTRICT on its own (setup): one LifeDeck ("Deck0"), ids 0.. as they are on the deck, events without "deck", the
## deck's own snapshot bytes.
## A STACK (phase 3; setup_stack): one LifeDeck per deck, each built from that deck's CityDistrict and working in that
## deck's frame (its global_transform). A threat, a blast or a pusher goes to the deck stack.deck_at() names (a threat on
## one deck never alarms another); a sweep is tested on every deck (each early-outs on its own bounds); events carry
## "deck" on the wire (no new event names). IDS in a stack: deck * ID_STRIDE + the id on that deck (people and vehicles
## each; ids on a deck are 0.. as in a district on its own, so deck 0's ids equal the stand-alone ones). ids() /
## vehicle_ids() list them. unit(k) is deck k's LifeDeck (Deck0 for a district).
## NEAR VIEWERS ONLY. Agents are evaluated and drawn only on decks where a viewer stands (add_viewer; in a stack with none
## registered, the current camera; none at all: everything) and only within LifeDeck.EVAL_R m of one (5 Hz samples);
## EVAL_R..DRAW_R are drawn from 1 Hz samples; beyond, hidden and re-checked once a second. Poses are functions of the
## events and the clock, so an agent coming back into range is exactly where the events put it. A district on its own
## culls only with registered viewers.
##
## Signals for audio / HUD: civilian_killed(id, world_pos, src), civilian_event(kind, world_pos) with gasp, scream,
## run_steps, door_slam, whimper; vehicle_event(kind, world_pos) with brake, horn, hazard, doors, tip, alarm, tram_bell
## (all throttled); tally_changed(). The decks emit them; this node passes them on (stack ids for civilian_killed).

signal civilian_killed(id: int, world_pos: Vector3, src: int)
signal civilian_event(kind: String, world_pos: Vector3)
signal vehicle_event(kind: String, world_pos: Vector3)
signal tally_changed()

const ID_STRIDE := 1000       ## stack ids: deck * ID_STRIDE + the id on that deck

var people := -1              ## the `people` param (-1: LifePlan.default_count)
var pods := -1                ## the `pods` / `carts` params (-1: by area)
var carts := -1
## Life clock: a district's is its deck's; a stack's is deck 0's as of this frame's step (advance_to: exactly t).
var now := 0.0:
	get:
		return units[0].now if stack == null and units.size() == 1 else now
var time_scale := 1.0         ## offline clock speed (the lab): handed to every deck each step
var sent: Array = []          ## host: the last events it decided, [kind, data] (tests feed them to another instance)
var stack: CityStack          ## setup_stack: the stack (null for a district on its own)
var units: Array[LifeDeck] = []   ## the decks' life (one for a district on its own)
var quality := CityQuality.HIGH   ## set_quality: local presentation only
var _draw_r := LifeDeck.DRAW_R    ## quality: m from a viewer an agent is drawn (bands, hit tests and events ignore it)
var _viewers: Array = []      ## registered viewer nodes (Node3D)
var _stack_pushers: Array = []    ## stack: [body, radius, src, deck it is handed to (-1 none)]
# incremental setup (setup_stack_begin / setup_step)
var _su_stack: CityStack      ## a stack mid setup_stack_begin: the stack (`stack` is set when done)
var _su_k := 0                ## the deck being set up
var _su_unit: LifeDeck        ## its deck
var _su_units: Array[LifeDeck] = []   ## the decks set up so far (they become `units` when all are done)
var _su_events: Array = []    ## life.* events heard while setting up, replayed when done
# lab-only debug hooks (the crowd lab, scripts/world/life/crowd_lab.gd): never set by the game, never sent, free unused
var debug_people_cap := LifePlan.PEOPLE_CAP   ## the people cap each deck passes to LifePlan (the crowd lab raises it)
var debug_profile := false    ## true: _process measures itself into debug_us
var debug_us := 0.0           ## usec the last _process took (debug_profile only)


func net_fields() -> Dictionary:
	return {
		"people": Net.SPAWN, "pods": Net.SPAWN, "carts": Net.SPAWN, "stack": Net.SPAWN, "units": Net.SPAWN,
		"now": Net.LOCAL, "time_scale": Net.LOCAL,
		"sent": Net.PRIVATE, "_stack_pushers": Net.PRIVATE,
		"_viewers": Net.LOCAL,
		"quality": Net.LOCAL, "_draw_r": Net.LOCAL,     # drawing only (CityQuality): never what is simulated or hit
		"_su_stack": Net.LOCAL, "_su_k": Net.LOCAL, "_su_unit": Net.LOCAL, "_su_units": Net.LOCAL, "_su_events": Net.LOCAL,
		# crowd lab only (debug hooks): a local presentation override, never simulated for others nor sent
		"debug_people_cap": Net.LOCAL, "debug_profile": Net.LOCAL, "debug_us": Net.LOCAL,
	}


func _init() -> void:
	name = "AmbientLife"
	add_to_group("ambient_life")


## ONLY ONE AmbientLife may handle the session's life.* events in a scene (a stack has one for all its decks). A second
## one refuses to connect (pushed error) while the first is in the tree, so an event is never applied twice.
const LISTENER_META := "ambient_life_listener"


func _ready() -> void:
	var s := Net.session()
	if s == null:
		return
	if s.has_meta(LISTENER_META):
		var other: Variant = s.get_meta(LISTENER_META)
		if is_instance_valid(other) and other != self and (other as Node).is_inside_tree() \
				and not (other as Node).is_queued_for_deletion():
			push_error("AmbientLife: %s already handles life.* events; %s will not connect (one per scene)" % [
					(other as Node).get_path(), get_path()])
			return
	s.set_meta(LISTENER_META, self)
	s.event_received.connect(_on_event)
	s.peer_joined.connect(_on_peer_joined)


func _exit_tree() -> void:
	var s := Net.session()
	if s != null and s.event_received.is_connected(_on_event):
		s.event_received.disconnect(_on_event)
		s.peer_joined.disconnect(_on_peer_joined)
	if s != null and s.has_meta(LISTENER_META) and s.get_meta(LISTENER_META) == self:
		s.remove_meta(LISTENER_META)


# --- Setup -----------------------------------------------------------------------------------------------

## Populate `d` (a built CityDistrict, on its own or one section deck; this node may be its child or anywhere else).
## Counts < 0: the defaults. Called again on a district, it sets up the same deck again.
func setup(d: CityDistrict, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	var dk: LifeDeck = units[0] if stack == null and units.size() == 1 else null
	if dk == null:
		_clear_units()
		dk = _new_deck(0, false)
		dk.now = now
		units.append(dk)
	people = people_count
	pods = pod_count
	carts = cart_count
	sent.clear()
	dk.debug_people_cap = debug_people_cap
	dk.setup_begin(d, people_count, pod_count, cart_count)
	while not dk.setup_chunk():
		pass
	dk.setup_finish()


## A deck's LifeDeck (child "Deck<k>"), wired to this node: its signals pass on (stack ids for civilian_killed), what it
## decides lands in `sent`, it draws at this node's quality.
func _new_deck(k: int, stacked: bool) -> LifeDeck:
	var dk := LifeDeck.new()
	dk.deck = k
	dk.stacked = stacked
	dk.name = "Deck%d" % k
	dk.time_scale = time_scale
	dk.set_draw_quality(quality, _draw_r)
	var base := k * ID_STRIDE
	dk.civilian_killed.connect(func(id: int, p: Vector3, src: int) -> void: civilian_killed.emit(base + id, p, src))
	dk.civilian_event.connect(civilian_event.emit)
	dk.vehicle_event.connect(vehicle_event.emit)
	dk.tally_changed.connect(tally_changed.emit)
	dk.decided.connect(_on_decided)
	add_child(dk)
	return dk


func _on_decided(kind: String, data: Dictionary) -> void:
	sent.append([kind, data])
	if sent.size() > 256:
		sent.pop_front()


## One LifeDeck for every deck of a built CityStack (child "Deck<k>"), counts per deck as for a district (60 people,
## 12 pods, 4 carts by deck area, the same caps) and one tram per deck. Every deck's CityProps is bound (props going down
## are threats on their own deck). Counts < 0: the defaults.
func setup_stack(s: CityStack, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	setup_stack_begin(s, people_count, pod_count, cart_count)
	while not setup_step(INF):
		pass


## setup_stack() spread over frames: setup_stack_begin() is cheap (drops the old decks); each setup_step(budget_ms) runs
## chunks (LifeDeck.SETUP_PARTS per deck, then one to finish) until budget_ms of wall time is spent, always at least one,
## and returns true once done. The result is exactly setup_stack()'s. Until setup_done(): `units` is empty and `stack`
## null (ids(), sweep(), blast(), snapshot() see no life), the decks being set up do not run, and life.* events heard are
## kept and replayed, in order, when the setup finishes.
func setup_stack_begin(s: CityStack, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	_clear_units()
	people = people_count
	pods = pod_count
	carts = cart_count
	sent.clear()
	_su_stack = s
	_su_k = 0
	_su_events.clear()


## Run setup chunks until budget_ms of wall time is spent (at least one); true once the setup is done (and when there
## is no setup in progress).
func setup_step(budget_ms: float = 8.0) -> bool:
	var start := Time.get_ticks_usec()
	while _su_stack != null:
		_setup_stack_chunk()
		if _su_stack == null or float(Time.get_ticks_usec() - start) >= budget_ms * 1000.0:
			break
	return _su_stack == null


## True when no setup_stack_begin() setup is in progress.
func setup_done() -> bool:
	return _su_stack == null


func _setup_stack_chunk() -> void:
	var s := _su_stack
	if _su_k < s.decks.size():
		var k := _su_k
		if _su_unit == null:
			var nu := _new_deck(k, true)
			nu.debug_people_cap = debug_people_cap
			nu.setup_begin(s.decks[k], people, pods, carts)
			_su_unit = nu
		var u := _su_unit
		if not u.setup_chunk():
			return
		_su_units.append(u)
		_su_unit = null
		_su_k += 1
		return
	units = _su_units.duplicate()
	_su_units.clear()
	for u in units:
		u.setup_finish()        # every deck is set up: the decks run from now on
	for k in s.decks.size():
		if s.decks[k].props != null:
			bind_props(s.decks[k].props)
	stack = s
	_su_stack = null
	now = units[0].now if not units.is_empty() else 0.0
	_route_pushers()
	_stack_views()
	var held := _su_events
	_su_events = []
	for e: Array in held:
		_on_event(e[0], e[1], e[2], e[3])


func _clear_units() -> void:
	if stack == null and units.size() == 1:
		now = units[0].now      # a district's clock stays this node's
	for u in units:
		remove_child(u)
		u.queue_free()
	units.clear()
	stack = null
	if _su_unit != null and is_instance_valid(_su_unit):
		_su_units.append(_su_unit)
	for u in _su_units:
		if is_instance_valid(u):
			remove_child(u)
			u.queue_free()
	_su_units.clear()
	_su_unit = null
	_su_stack = null


## Deck k's life (Deck0 for a district on its own); null before setup.
func unit(k: int) -> LifeDeck:
	if units.is_empty():
		return null
	return units[clampi(k, 0, units.size() - 1)]


## The deck holding id `id` (a stack id in a stack) and the id on that deck.
func _deck_of(id: int) -> LifeDeck:
	return units[0] if stack == null else units[clampi(id / ID_STRIDE, 0, units.size() - 1)]


func _local(id: int) -> int:
	return id if stack == null else id % ID_STRIDE


## Every person id (stack ids in a stack).
func ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for u in units:
		for i in u.count():
			out.append(u.deck * ID_STRIDE + i)
	return out


func vehicle_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for u in units:
		for i in u.vehicle_count():
			out.append(u.deck * ID_STRIDE + i)
	return out


## Change the number of pods and carts (forgets every vehicle event; the people keep theirs).
func set_vehicles(pod_count: int, cart_count: int) -> void:
	pods = pod_count
	carts = cart_count
	for u in units:
		u.set_vehicles(pod_count, cart_count)


# --- Viewers -----------------------------------------------------------------------------------------------

## Agents are evaluated and drawn only near viewers (a camera, a mech): register each one.
func add_viewer(node: Node3D) -> void:
	if not _viewers.has(node):
		_viewers.append(node)


func remove_viewer(node: Node3D) -> void:
	_viewers.erase(node)


## World positions of the viewers, or null when nothing is known (no culling). A stack with none registered uses the
## current camera; a district on its own does not.
func _viewer_points() -> Variant:
	var out := PackedVector3Array()
	for v: Variant in _viewers:
		if is_instance_valid(v) and (v as Node3D).is_inside_tree():
			out.append((v as Node3D).global_position)
	if not out.is_empty():
		return out
	if stack != null and is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			out.append(cam.global_position)
			return out
	return null


## Stack: hand every deck the viewers standing on it (deck-local), active only with one there.
func _stack_views() -> void:
	var pts: Variant = _viewer_points()
	if pts == null:
		for u in units:
			u.set_view(false, PackedVector3Array(), true)
		return
	var per: Array = []
	for u in units:
		per.append(PackedVector3Array())
	for p: Vector3 in pts:
		var k := stack.deck_at(p)
		if k >= 0 and k < units.size():
			var arr: PackedVector3Array = per[k]          # (packed arrays are values: append, then put back)
			arr.append(units[k].to_world().affine_inverse() * p)
			per[k] = arr
	for k in units.size():
		units[k].set_view(true, per[k], not (per[k] as PackedVector3Array).is_empty())


## A district on its own culls only with registered viewers.
func _alone_views() -> void:
	var dk := units[0]
	var pts := PackedVector3Array()
	for v: Variant in _viewers:
		if is_instance_valid(v) and (v as Node3D).is_inside_tree():
			pts.append(dk.to_world().affine_inverse() * (v as Node3D).global_position)
	dk.set_view(not pts.is_empty(), pts, true)


# --- Quality (CityQuality: drawing only) --------------------------------------------------------------------

## Draw level q (CityQuality.LOW / MEDIUM / HIGH): people, vehicles and the tram are drawn only within
## CityQuality.level(q).life_draw_r of a viewer (DRAW_R at HIGH). Nothing else changes: the bands (EVAL_R / DRAW_R),
## sampling, events, what this machine's shots can hit, the host's decisions and every pose and state stay exactly as at
## HIGH. Covers every deck. Any time, before or after setup.
func set_quality(q: int) -> void:
	quality = CityQuality.clamp_level(q)
	_draw_r = minf(float(CityQuality.level(quality)["life_draw_r"]), LifeDeck.DRAW_R)
	var all: Array[LifeDeck] = units.duplicate()
	all.append_array(_su_units)
	if _su_unit != null and is_instance_valid(_su_unit):
		all.append(_su_unit)
	for u in all:
		u.set_draw_quality(quality, _draw_r)


# --- Frames ----------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not debug_profile:
		_step(delta)
		return
	var t0 := Time.get_ticks_usec()
	_step(delta)
	debug_us = float(Time.get_ticks_usec() - t0)


## One frame: hand the decks their viewers and pushers, then step each.
func _step(delta: float) -> void:
	if stack != null:
		for u in units:
			u.time_scale = time_scale
		_route_pushers()
		_stack_views()
		if not units.is_empty():
			now = units[0].now
		for u in units:
			u.step(delta)
		return
	if units.is_empty():
		return
	var dk := units[0]
	dk.time_scale = time_scale
	if dk.plan == null:
		return
	_alone_views()
	dk.step(delta)


## Move the clock to `t` and draw everyone exactly there (tests drive time with this, never frames).
func advance_to(t: float) -> void:
	if stack != null:
		_route_pushers()
		_stack_views()
		for u in units:
			u.advance_to(t)
		now = t
		return
	if units.is_empty():
		return
	_alone_views()
	units[0].advance_to(t)


# --- Queries (stack ids in a stack) -----------------------------------------------------------------------

## calm | wary | fleeing | sheltered | cowering | hands_up | down, at the current clock time.
func state_of(id: int) -> String:
	return _deck_of(id).state_of(_local(id))


## The person's transform in world space now (exact, not interpolated; feet at the origin, facing local +Z).
func pose_of(id: int) -> Transform3D:
	return _deck_of(id).pose_of(_local(id))


## Whether person `id` is outdoors (could be drawn) now.
func visible_now(id: int) -> bool:
	return _deck_of(id).visible_now(_local(id))


## Whether person `id` is drawn now (outdoors and within a viewer's draw range).
func drawn_now(id: int) -> bool:
	return _deck_of(id).drawn_now(_local(id))


## People (timetabled ones, then the pod riders: drawn only once a pod lets them out). In a stack: all decks (use ids()).
func count() -> int:
	var n := 0
	for u in units:
		n += u.count()
	return n


func vehicle_count() -> int:
	var n := 0
	for u in units:
		n += u.vehicle_count()
	return n


## driving | stopped | dwell | docked | estop | fleeing | abandoned | wreck, at the current clock time.
func vehicle_state(id: int) -> String:
	return _deck_of(id).vehicle_state(_local(id))


## The vehicle's transform in world space now (exact; on the road, nose along local +Z).
func vehicle_pose(id: int) -> Transform3D:
	return _deck_of(id).vehicle_pose(_local(id))


func vehicle_kind(id: int) -> String:
	return _deck_of(id).vehicle_kind(_local(id))


## {killed_by_players, killed_by_enemies, by_src: {src: n}, dead (figures down), occupants_killed (inside pods, no
## figures; also counted in the first three), wrecks}. In a stack: summed over the decks.
func tally() -> Dictionary:
	if stack == null and units.size() == 1:
		return units[0].tally()
	var out := {}
	for u in units:
		var t := u.tally()
		for key: String in t:
			if t[key] is Dictionary:
				var into: Dictionary = out.get(key, {})
				for src: Variant in t[key]:
					into[src] = int(into.get(src, 0)) + int(t[key][src])
				out[key] = into
			else:
				out[key] = int(out.get(key, 0)) + int(t[key])
	return out


## The animation person `id` shows now: walk | wait | sit | run | wary | cower | hands_up | down | indoor (indoor: not
## drawn). What a figure drawer is asked to draw (with state_of for the behaviour behind it).
func mode_of(id: int) -> String:
	return _deck_of(id).mode_of(_local(id))


# --- Debug hooks (the crowd lab only; never called by the game) -----------------------------------------------

## The states a figure can be forced into (debug_force_state): key -> the behaviour state (state_of) and the animation
## mode (mode_of) it shows. Every animation the crowd system really produces today is here (LifeCrowd.pose modes, plus
## the local hands-up look): add a new animation here and the crowd lab lists it.
const DEBUG_STATES := {
	"walk": {"state": "calm", "mode": "walk"},
	"idle": {"state": "calm", "mode": "wait"},
	"sit": {"state": "calm", "mode": "sit"},
	"flinch": {"state": "wary", "mode": "wary"},
	"flee": {"state": "fleeing", "mode": "run"},
	"cower": {"state": "cowering", "mode": "cower"},
	"hands_up": {"state": "hands_up", "mode": "hands_up"},
	"down": {"state": "down", "mode": "down"},
	"look_around": {"state": "calm", "mode": "look_around"},   # animation only: an idle variation, not a crowd state
}


static func debug_states() -> Array:
	return DEBUG_STATES.keys()


## LAB ONLY: draw person `id` (-1: everyone) in state `key` (a DEBUG_STATES key; "" or "timetable" lifts it) from now
## on, where the timetable / threats put them (nobody is moved: people indoors stay hidden, the dead stay down). A
## local presentation override: state_of / mode_of / pose_of and the figures follow it; the crowd's state (threats,
## kills, snapshot, tally) never does, and nothing is sent. Free while unused (one empty-dictionary test per sample).
func debug_force_state(id: int, key: String) -> void:
	if stack == null:
		for u in units:
			u.debug_force_state(id, key)
		return
	for u in units:
		u.debug_force_state(id if id < 0 else (id % ID_STRIDE if id / ID_STRIDE == u.deck else -2), key)
	if id != -2 and key != "" and key != "timetable" and not DEBUG_STATES.has(key):
		push_warning("AmbientLife.debug_force_state: unknown state %s" % key)


## LAB ONLY: lift every debug_force_state: everyone back on the timetable / the threats' state.
func debug_clear() -> void:
	for u in units:
		u.debug_clear()


## The DEBUG_STATES key forced on `id` ("" none).
func debug_forced(id: int) -> String:
	return _deck_of(id).debug_forced(_local(id))


## Everything the crowd lab's inspector shows about person `id` (LifeDeck.debug_person), with its stack id in a stack.
func debug_person(id: int) -> Dictionary:
	var o := _deck_of(id).debug_person(_local(id))
	if stack != null and not o.is_empty():
		o["id"] = id
	return o


# --- Threats, weapons, events (routed by deck) ------------------------------------------------------------

## Host only (a client's call does nothing): a threat at `world_point`. Merged with any within MERGE_R m and MERGE_S s,
## and at most 4 events a second leave. In a stack it goes to the deck the point is on.
func raise_threat(world_point: Vector3, radius: float, strength: int) -> void:
	if units.is_empty():
		return
	if stack == null:
		units[0].raise_threat(world_point, radius, strength)
		return
	units[clampi(stack.deck_at(world_point), 0, units.size() - 1)].raise_threat(world_point, radius, strength)


## Apply one event as the host decided it ("life.threat", "life.down" or "life.wreck"): what a client does on receipt,
## and what a test does to feed a second instance. In a stack, "deck" in the data names the deck (none: deck 0, a district on its own).
func apply_event(kind: String, data: Dictionary) -> void:
	if units.is_empty():
		return
	units[clampi(int(data.get("deck", 0)), 0, units.size() - 1)].apply_event(kind, data)


## Every outdoor civilian within r + 0.4 m of the segment a -> b (world space) is killed, and every vehicle it touches is
## wrecked (asked of the host on a client). Returns how many people and vehicles were hit; the shot is not changed (the
## tram ignores it). Cheap when nobody is near: two bounds tests per deck, no allocation.
func sweep(a: Vector3, b: Vector3, r: float, src: int) -> int:
	var hits := 0
	for u in units:
		hits += u.sweep(a, b, r, src)
	return hits


## Every outdoor civilian within `radius` of `point` (world space) is killed and every vehicle in it wrecked (tipped onto
## its side). Returns how many people and vehicles were hit. In a stack only the deck the point is on is touched (a
## blast near a floor hole does not reach through it).
func blast(point: Vector3, radius: float, src: int) -> int:
	if units.is_empty():
		return 0
	if stack == null:
		return units[0].blast(point, radius, src)
	return units[clampi(stack.deck_at(point), 0, units.size() - 1)].blast(point, radius, src)


# --- Pushers ---------------------------------------------------------------------------------------------

## Register a mover (a mech's foot, or its body; LifeDeck.add_pusher). In a stack it acts on the deck it stands on
## (re-checked every frame). The tram is never touched.
func add_pusher(body: Node3D, radius: float = 1.0, src: int = 0) -> void:
	if stack != null:
		for p: Array in _stack_pushers:
			if p[0] == body:
				p[1] = radius
				p[2] = src
				p[3] = -1
				_route_pushers()
				return
		_stack_pushers.append([body, radius, src, -1])
		_route_pushers()
		return
	if not units.is_empty():
		units[0].add_pusher(body, radius, src)


func remove_pusher(body: Node3D) -> void:
	for i in range(_stack_pushers.size() - 1, -1, -1):
		if _stack_pushers[i][0] == body:
			_stack_pushers.remove_at(i)
	for u in units:
		u.remove_pusher(body)


## Stack: hand every pusher to the deck it is on.
func _route_pushers() -> void:
	for i in range(_stack_pushers.size() - 1, -1, -1):
		var p: Array = _stack_pushers[i]
		var body: Variant = p[0]
		if not is_instance_valid(body):
			for u in units:
				u.drop_pusher(body)
			_stack_pushers.remove_at(i)
			continue
		if not (body as Node3D).is_inside_tree() or units.is_empty():
			continue
		var k := clampi(stack.deck_at((body as Node3D).global_position), 0, units.size() - 1)
		if k != int(p[3]):
			if int(p[3]) >= 0 and int(p[3]) < units.size():
				units[int(p[3])].remove_pusher(body)
			units[k].add_pusher(body, float(p[1]), int(p[2]))
			p[3] = k


# --- Binding ---------------------------------------------------------------------------------------------

## Threats from combat: every shot (60 m, strength 1), every impact (40 m strength 2, 80 m strength 3 when explosive).
func bind_combat(cw: Node) -> void:
	if cw.has_signal("fired") and not cw.is_connected("fired", _on_fired):
		cw.connect("fired", _on_fired)
	if cw.has_signal("impact_spawned") and not cw.is_connected("impact_spawned", _on_impact):
		cw.connect("impact_spawned", _on_impact)


## Threats from street props going down (15 m, strength 1). setup_stack binds every deck's props itself.
func bind_props(props: CityProps) -> void:
	if not props.prop_moved.is_connected(_on_prop_moved):
		props.prop_moved.connect(_on_prop_moved)


func _on_fired(record: Dictionary) -> void:
	var o: Variant = record.get("origin")
	if o is Vector3:
		raise_threat(o, 60.0, 1)


func _on_impact(point: Vector3, _radius: float, explosive: bool, _is_energy: bool) -> void:
	raise_threat(point, 80.0 if explosive else 40.0, 3 if explosive else 2)


func _on_prop_moved(_id: int, _type: String, _kind: int, world_pos: Vector3, _speed: float) -> void:
	raise_threat(world_pos, 15.0, 1)


# --- Network ---------------------------------------------------------------------------------------------

## What differs from the timetables (for a joiner): a district's is its deck's snapshot (LifeDeck.snapshot); a stack's
## is every deck's, in deck order.
func snapshot() -> PackedByteArray:
	if stack == null:
		return units[0].snapshot() if not units.is_empty() else PackedByteArray()
	var buf := StreamPeerBuffer.new()
	buf.put_u8(units.size())
	for u in units:
		var b := u.snapshot()
		buf.put_u32(b.size())
		buf.put_data(b)
	return buf.data_array


## The bytes come from a peer (life.sync): a part's length larger than what is left is cut to what is left (that part
## then fails its own checks and is cleared), so nothing is read past the end or allocated by the peer's number; parts
## for decks this stack does not have are ignored.
func restore(bytes: PackedByteArray) -> void:
	if stack == null:
		if not units.is_empty():
			units[0].restore(bytes)
		return
	var sb := StreamPeerBuffer.new()
	sb.data_array = bytes
	var n := sb.get_u8() if bytes.size() > 0 else 0
	for k in units.size():
		var part := PackedByteArray()
		if k < n and sb.get_available_bytes() >= 4:
			var size := mini(sb.get_u32(), sb.get_available_bytes())
			part = sb.get_data(size)[1]
		units[k].restore(part)
	tally_changed.emit()


func _on_event(_from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if not kind.begins_with("life."):
		return
	if _su_stack != null:
		_su_events.append([_from, kind, data, _stamp])     # replayed when setup_step finishes
		return
	if stack != null:
		var s0 := Net.session()
		if kind == "life.sync":
			var sb: Variant = data.get("bytes", PackedByteArray())
			if s0 != null and s0.is_client() and sb is PackedByteArray:
				for u in units:
					u.now = u.clock()
				restore(sb)
			return
		if not units.is_empty():
			units[clampi(int(data.get("deck", 0)), 0, units.size() - 1)].on_event(_from, kind, data, _stamp)
		return
	if units.is_empty():
		return
	units[0].on_event(_from, kind, data, _stamp)


func _on_peer_joined(peer: int) -> void:
	var s := Net.session()
	if s != null and s.is_host() and not units.is_empty():
		s.send_event(peer, "life.sync", {"bytes": snapshot()})
