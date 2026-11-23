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
## Drawing: LifeFigures, LifeCars and LifeTramCars (MultiMesh). Poses are sampled at 20 Hz in four staggered groups (each
## agent every 0.2 s, one sample ahead) and the transforms interpolated every frame.
##
## STACK (phase 3). setup_stack(stack) gives this node one child AmbientLife per deck ("Deck0", ...: a "unit", not in the
## group), each built from that deck's CityDistrict and working in that deck's frame (its global_transform). This node
## routes: a threat, a blast or a pusher goes to the deck stack.deck_at() names (a threat on one deck never alarms
## another); a sweep is tested on every deck (each early-outs on its own bounds); events carry "deck" on the wire
## (no new event names). IDS in a stack: deck * ID_STRIDE + the id on that deck (people and vehicles each; ids on a deck
## are 0.. as in a district on its own, so deck 0's ids equal the stand-alone ones). ids() / vehicle_ids() list them.
## A district on its own is its own single unit and keeps every id and behaviour it had.
## NEAR VIEWERS ONLY. Agents are evaluated and drawn only on decks where a viewer stands (add_viewer; in a stack with none
## registered, the current camera; none at all: everything) and only within EVAL_R m of one (5 Hz samples); EVAL_R..DRAW_R
## are drawn from 1 Hz samples; beyond, hidden and re-checked once a second. Poses are functions of the events and the
## clock, so an agent coming back into range is exactly where the events put it. A district on its own culls only with
## registered viewers.
##
## Signals for audio / HUD: civilian_killed(id, world_pos, src), civilian_event(kind, world_pos) with gasp, scream,
## run_steps, door_slam, whimper; vehicle_event(kind, world_pos) with brake, horn, hazard, doors, tip, alarm, tram_bell
## (all throttled); tally_changed().

signal civilian_killed(id: int, world_pos: Vector3, src: int)
signal civilian_event(kind: String, world_pos: Vector3)
signal vehicle_event(kind: String, world_pos: Vector3)
signal tally_changed()

const TICK := 0.05            ## s, logic tick (20 Hz)
const GROUPS := 4             ## staggered groups: each agent is sampled every GROUPS ticks
const MERGE_R := 10.0         ## m: threats closer than this ...
const MERGE_S := 0.25         ## ... and this many seconds apart are one
const SEND_EVERY := 0.25      ## s: at most 4 threat events a second leave the host
const MARGIN := 0.4           ## m added to a shot's radius
const HEIGHT := 1.8           ## m, a person's hit capsule (feet to head)
const FOOT_SPEED := 2.0       ## m/s: a pusher (mech foot) faster than this kills what it touches / wrecks a vehicle
const FOOT_HEIGHT := 2.0      ## m: ... within this height of its own
const PROX_SPEED := 0.5       ## m/s: a pusher moving faster than this near people or vehicles is a threat ...
const PROX_R := 12.0          ## ... of this radius (strength 1): within this of an outdoor person
const PROX_CAR := 20.0        ## ... or within this of a vehicle (they e-stop for any threat within 30 m)
const PROX_EVERY := 1.0       ## ... at most once a second each
const HANDS_R := 10.0         ## m: a cowering person with a mech this close and no shot for HANDS_QUIET s raises hands
const HANDS_QUIET := 3.0
const ASK_EVERY := 0.5        ## s: a client asks about one person or vehicle at most this often
const THROTTLE := {"gasp": 0.5, "scream": 1.5, "run_steps": 0.5, "door_slam": 0.5, "whimper": 2.0,
		"brake": 0.5, "horn": 1.0, "hazard": 1.0, "doors": 0.5, "tip": 0.3, "alarm": 1.0, "tram_bell": 5.0}
const STEP_EVERY := 1.2       ## s between run_steps of one fleeing person
const CELL := 30.0            ## m, audio throttle cell
const BLINK_HZ := 1.5
const SHOT_PUSH := 3.0        ## m/s a shot nudges the vehicle it wrecks (before the vehicle's mass)
const BLAST_PUSH := 8.0
const PUSH_SHOVE := 1.0       ## a pusher shoves a vehicle at this times its speed
const ID_STRIDE := 1000       ## stack ids: deck * ID_STRIDE + the id on that deck
const EVAL_R := 150.0         ## m from a viewer: evaluated at the full rate
const DRAW_R := 200.0         ## m from a viewer: drawn (1 Hz samples beyond EVAL_R)
const SLOW := 5               ## mid-range / far agents are sampled every SLOW * GROUPS ticks (1 s)
const NEAR := 0
const MID := 1
const FAR := 2

var district: CityDistrict
var plan: LifePlan
var crowd: LifeCrowd
var traffic: LifeTraffic
var fleet: LifeFleet
var tram: LifeTram            ## section mode: the deck's tram (null on a district on its own)
var figures: LifeFigures
var cars: LifeCars
var tram_cars: LifeTramCars
var barriers: MeshInstance3D  ## section mode: checkpoint and cordon dressing (LifeBarriers)
var people := -1              ## the `people` param (-1: LifePlan.default_count)
var pods := -1                ## the `pods` / `carts` params (-1: by area)
var carts := -1
var now := 0.0                ## life clock: Session.host_time() online, local seconds offline
var time_scale := 1.0         ## offline clock speed (the lab)
var sent: Array = []          ## host: the last events it decided, [kind, data] (tests feed them to another instance)
var stack: CityStack          ## setup_stack: the stack (this node then only routes to `units`)
var units: Array[AmbientLife] = []
var deck := 0                 ## a unit's deck in its stack (0 on its own)

var _root: AmbientLife        ## a unit's stack node (null: this node is the one in the group)
var _ring: RingFrame
var _geo: CityGeo
var _online_clock := false
var _tick := -1               ## next logic tick index (-1: resample everything)
# people
var _ta := PackedFloat64Array()
var _tb := PackedFloat64Array()
var _xa: Array[Transform3D] = []
var _xb: Array[Transform3D] = []
var _motion := PackedInt32Array()   ## LifeAnimRig motion of sample A (-1 hidden)
var _vis_b := PackedByteArray()
var _state: Array[String] = []      ## state of sample A
var _last_b: Array = []             ## the last sample B per person (reused as the next sample A)
var _ha := PackedFloat32Array()     ## headings of samples A / B (the route's; the drawn one lags: _yaw)
var _hb := PackedFloat32Array()
# animation (cosmetic, computed locally on every machine from the same state + clock; LifeFigures / life_anim_limbs)
var _drawn_mo := PackedInt32Array() ## motion in the person's custom data (-1: not drawn, the next motion starts fresh)
var _mo_t0 := PackedFloat64Array()  ## its start time
var _yaw := PackedFloat32Array()    ## drawn heading (district-local yaw), easing toward the route's (LifeAnimRig.TURN_TAU)
var _draw_now := 0.0                ## clock at the last drawn frame (the heading's easing step)
var _steps_at := PackedFloat64Array()
var _falling: Dictionary = {}       ## id -> true while tipping over (drawn exactly every frame)
var _px := PackedFloat32Array()     ## displayed arc x, s per person
var _ps := PackedFloat32Array()
var _pos := PackedVector3Array()    ## displayed feet, district-local
var _up := PackedVector3Array()
var _on := PackedByteArray()        ## 1: outdoors and alive (can be hit)
var _band := PackedByteArray()      ## NEAR / MID / FAR from the viewers
var _bounds := AABB()
var _any_out := false
# vehicles
var _vta := PackedFloat64Array()
var _vtb := PackedFloat64Array()
var _vxa: Array[Transform3D] = []
var _vxb: Array[Transform3D] = []
var _vhaz := PackedByteArray()      ## hazards / alarm on (sample A)
var _vstate: Array[String] = []
var _vdoors := PackedFloat64Array() ## doors time already announced per vehicle
var _vtip: Dictionary = {}          ## vid -> true while a wreck is tipping (drawn exactly every frame)
var _vpos := PackedVector3Array()   ## displayed centre (local), half axis along the length, arc x, s, heading
var _vaxis := PackedVector3Array()
var _vpx := PackedFloat32Array()
var _vps := PackedFloat32Array()
var _vdir := PackedVector2Array()
var _von := PackedByteArray()       ## 1: can be wrecked (not yet a wreck)
var _vband := PackedByteArray()
var _vbounds := AABB()
var _vany := false
var _tram_state := ""
# viewers
var _viewers: Array = []            ## registered viewer nodes (Node3D)
var _views := PackedVector3Array()  ## a unit's viewers on its deck, district-local
var _cull := false                  ## false: everything is near (no viewer known)
var _active := true                 ## false: no viewer on this deck (nothing evaluated or drawn)
var quality := CityQuality.HIGH     ## set_quality: local presentation only
var _draw_r := DRAW_R               ## quality: m from a viewer an agent is drawn (bands, hit tests and events ignore it)
# host and local bookkeeping
var _pending: Array = []            ## host: threats waiting to be sent [x, s, r, st]
var _recent: Array = []             ## host: [t, x, s, r, st] sent within MERGE_S
var _last_send := -INF
var _pushers: Array = []            ## [body, radius, src, last arc (Vector3), has_last, next proximity threat]
var _stack_pushers: Array = []      ## stack: [body, radius, src, deck it is handed to (-1 none)]
var _pusher_arc: Array[Vector2] = []
var _asked: Dictionary = {}
var _vasked: Dictionary = {}
var _heard: Dictionary = {}         ## "kind:cell" -> time of the last event of that kind there
# incremental setup (setup_stack_begin / setup_step)
var _setup_part := -1               ## a unit mid setup: its next part, SETUP_PARTS when set up but its stack is not (-1: running; else _process waits)
var _su_stack: CityStack            ## a stack node mid setup_stack_begin: the stack (`stack` is set when done)
var _su_k := 0                      ## the deck being set up
var _su_unit: AmbientLife           ## its unit
var _su_units: Array[AmbientLife] = []   ## the decks' units set up so far (they become `units` when all are done)
var _su_events: Array = []          ## life.* events heard while setting up, replayed when done
# lab-only debug hooks (the crowd lab, scripts/world/life/crowd_lab.gd): never set by the game, never sent, free unused
var debug_people_cap := LifePlan.PEOPLE_CAP   ## the people cap setup() passes to LifePlan (the crowd lab raises it)
var debug_profile := false          ## true: _process measures itself into debug_us
var debug_us := 0.0                 ## usec the last _process took (debug_profile only)
## Shot tests (sweep / blast) look people up in a grid of their displayed feet, rebuilt lazily after the positions
## change (_pos_rev) and only from the second shot test on the same positions (one shot a frame: the plain loop is
## cheaper). The same people in the same id order as the plain loop: results identical (brute_force: the reference).
const GRID := 4.0                   ## m, shot grid cell
var brute_force := false
var _pos_rev := 0                   ## bumped whenever _pos / _on are rewritten
var _grid_rev := -1                 ## _pos_rev the grid was built for
var _grid_asks := 0                 ## shot tests since the positions last changed (at _asks_rev)
var _asks_rev := -1
var _all_ids := PackedInt32Array()  ## 0 .. total - 1 (the plain loop's order)
var _grid: Dictionary = {}          ## Vector3i cell -> PackedInt32Array ids (alive and outdoors)
var _force: Dictionary = {}         ## debug_force_state: id (-1 everyone) -> [DEBUG_STATES key, clock time it was forced]


func net_fields() -> Dictionary:
	return {
		"district": Net.SPAWN, "plan": Net.SPAWN, "traffic": Net.SPAWN, "people": Net.SPAWN, "pods": Net.SPAWN,
		"carts": Net.SPAWN, "stack": Net.SPAWN, "units": Net.SPAWN, "deck": Net.SPAWN, "_root": Net.SPAWN,
		"crowd": Net.OWNER, "fleet": Net.OWNER, "tram": Net.OWNER,     # the host's events decide them on every machine
		"now": Net.LOCAL, "time_scale": Net.LOCAL, "figures": Net.LOCAL, "cars": Net.LOCAL, "tram_cars": Net.LOCAL,
		"barriers": Net.LOCAL,
		"sent": Net.PRIVATE, "_pending": Net.PRIVATE, "_recent": Net.PRIVATE, "_last_send": Net.PRIVATE,
		"_pushers": Net.PRIVATE, "_stack_pushers": Net.PRIVATE, "_asked": Net.PRIVATE, "_vasked": Net.PRIVATE,
		"_ring": Net.LOCAL, "_geo": Net.LOCAL, "_online_clock": Net.LOCAL, "_tick": Net.LOCAL, "_ta": Net.LOCAL,
		"_tb": Net.LOCAL, "_xa": Net.LOCAL, "_xb": Net.LOCAL, "_motion": Net.LOCAL, "_vis_b": Net.LOCAL, "_state": Net.LOCAL,
		"_last_b": Net.LOCAL, "_steps_at": Net.LOCAL, "_falling": Net.LOCAL, "_px": Net.LOCAL, "_ps": Net.LOCAL,
		"_pos": Net.LOCAL, "_up": Net.LOCAL, "_on": Net.LOCAL, "_band": Net.LOCAL, "_bounds": Net.LOCAL,
		"_any_out": Net.LOCAL, "_vta": Net.LOCAL, "_vtb": Net.LOCAL, "_vxa": Net.LOCAL, "_vxb": Net.LOCAL,
		"_vhaz": Net.LOCAL, "_vstate": Net.LOCAL, "_vdoors": Net.LOCAL, "_vtip": Net.LOCAL, "_vpos": Net.LOCAL,
		"_vaxis": Net.LOCAL, "_vpx": Net.LOCAL, "_vps": Net.LOCAL, "_vdir": Net.LOCAL, "_von": Net.LOCAL,
		"_vband": Net.LOCAL, "_vbounds": Net.LOCAL, "_vany": Net.LOCAL, "_tram_state": Net.LOCAL,
		"_viewers": Net.LOCAL, "_views": Net.LOCAL, "_cull": Net.LOCAL, "_active": Net.LOCAL,
		"quality": Net.LOCAL, "_draw_r": Net.LOCAL,     # drawing only (CityQuality): never what is simulated or hit
		"_pusher_arc": Net.LOCAL, "_heard": Net.LOCAL,
		"_ha": Net.LOCAL, "_hb": Net.LOCAL, "_drawn_mo": Net.LOCAL, "_mo_t0": Net.LOCAL, "_yaw": Net.LOCAL,
		"_draw_now": Net.LOCAL,     # animation only: cosmetic, derived locally
		"_setup_part": Net.LOCAL, "_su_stack": Net.LOCAL, "_su_k": Net.LOCAL, "_su_unit": Net.LOCAL, "_su_units": Net.LOCAL,
		"_su_events": Net.LOCAL,
		# crowd lab only (debug hooks): a local presentation override, never simulated for others nor sent
		"debug_people_cap": Net.LOCAL, "debug_profile": Net.LOCAL, "debug_us": Net.LOCAL, "_force": Net.LOCAL,
		# shot lookup grid: a local index of the displayed positions (results identical to the plain loop)
		"brute_force": Net.LOCAL, "_pos_rev": Net.LOCAL, "_grid_rev": Net.LOCAL, "_grid_asks": Net.LOCAL, "_grid": Net.LOCAL,
		"_asks_rev": Net.LOCAL, "_all_ids": Net.LOCAL,
	}


func _init() -> void:
	name = "AmbientLife"
	add_to_group("ambient_life")


## ONLY ONE AmbientLife may handle the session's life.* events in a scene (a stack has one for all its decks). A second
## one refuses to connect (pushed error) while the first is in the tree, so an event is never applied twice.
const LISTENER_META := "ambient_life_listener"


func _ready() -> void:
	if _root != null:
		return              # a stack's unit: its stack node talks to the session
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


## Populate `d` (a built CityDistrict, on its own or one section deck; this node may be its child or anywhere else).
## Counts < 0: the defaults.
func setup(d: CityDistrict, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	_clear_units()
	_setup_begin(d, people_count, pod_count, cart_count)
	while _setup_part < SETUP_PARTS:
		_setup_chunk()
	_setup_part = -1


## setup() in SETUP_PARTS chunks (the stack's setup_step runs one per call): the same calls in the same order.
## 0: plan, crowd, figures, per-person arrays; 1: traffic; 2: tram cars and barriers; 3: the first exact draw;
## 4 .. 4 + WARM_PARTS - 1: a quarter a part of: the walk graph's shortest-path trees from every door (a threat's refuge
## choice reads them), the standing slots of crossings and benches, and the hold index for the next minutes (crowd
## spacing). Built here instead of on first use (a shot, a frame): the same data whenever it is built.
const WARM_PARTS := 4
const SETUP_PARTS := 4 + WARM_PARTS

func _setup_begin(d: CityDistrict, people_count: int, pod_count: int, cart_count: int) -> void:
	district = d
	people = people_count
	pods = pod_count
	carts = cart_count
	_setup_part = 0


func _setup_chunk() -> void:
	var part := _setup_part
	_setup_part = part + 1      # SETUP_PARTS when all are done: the caller sets -1 (setup, or the stack when every deck is)
	match part:
		0:
			_setup_people()
		1:
			_build_traffic()
		2:
			_build_section()
			_tick = -1
			_follow()
		3:
			_redraw_exact(false)
		_:
			plan.warm_trees(part - 4, WARM_PARTS)
			plan.warm_slots(part - 4, WARM_PARTS)
			plan.warm_ahead(now, plan.count, part - 4, WARM_PARTS)


func _setup_people() -> void:
	var d := district
	var people_count := people
	_ring = d.ring
	_geo = CityGeo.new(_ring)
	plan = LifePlan.make(d.plan, people_count, debug_people_cap)
	crowd = LifeCrowd.new(plan)
	tram = plan.tram
	if figures == null:
		figures = LifeFigures.new()
		figures.top_level = true
		add_child(figures)
	if cars == null:
		cars = LifeCars.new()
		cars.top_level = true
		add_child(cars)
	var n := plan.total()
	var seeds := PackedFloat32Array()
	for i in n:
		seeds.append(plan.h(i, 91))
	figures.build(plan.people + plan.riders, _local_bounds(), d.render_layer, seeds)
	_apply_figure_quality()
	_ta.resize(n)
	_tb.resize(n)
	_xa.resize(n)
	_xb.resize(n)
	_motion.resize(n)
	_ha.resize(n)
	_hb.resize(n)
	_drawn_mo.resize(n)
	_mo_t0.resize(n)
	_yaw.resize(n)
	_vis_b.resize(n)
	_state.resize(n)
	_last_b.resize(n)
	_last_b.fill(null)
	_steps_at.resize(n)
	_px.resize(n)
	_ps.resize(n)
	_pos.resize(n)
	_up.resize(n)
	_on.resize(n)
	_band.resize(n)
	for i in n:
		_motion[i] = -1
		_drawn_mo[i] = -1
		_state[i] = "calm"
		_on[i] = 0
		_band[i] = NEAR
	_falling.clear()
	_pending.clear()
	_recent.clear()
	_asked.clear()
	_heard.clear()
	sent.clear()
	_last_send = -INF
	_online_clock = Net.online()
	now = _clock()


## One AmbientLife for every deck of a built CityStack: a unit per deck (child "Deck<k>"), counts per deck as for a
## district (60 people, 12 pods, 4 carts by deck area, the same caps) and one tram per deck. Every deck's CityProps is
## bound (props going down are threats on their own deck). Counts < 0: the defaults.
func setup_stack(s: CityStack, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	setup_stack_begin(s, people_count, pod_count, cart_count)
	while not setup_step(INF):
		pass


## setup_stack() spread over frames: setup_stack_begin() is cheap (drops the old units); each setup_step(budget_ms) runs
## chunks (SETUP_PARTS per deck, then one to finish) until budget_ms of wall time is spent, always at least one, and
## returns true once done. The result is exactly setup_stack()'s. Until setup_done(): `units` is empty and `stack` null
## (ids(), sweep(), blast(), snapshot() see no life), the units being set up do not run, and life.* events heard are
## kept and replayed, in order, when the setup finishes.
func setup_stack_begin(s: CityStack, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	_clear_units()
	people = people_count
	pods = pod_count
	carts = cart_count
	district = null
	plan = null
	sent.clear()
	_online_clock = Net.online()
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
			var nu := AmbientLife.new()
			nu._root = self
			nu.deck = k
			nu.remove_from_group("ambient_life")
			nu.name = "Deck%d" % k
			nu.time_scale = time_scale
			nu.debug_people_cap = debug_people_cap
			add_child(nu)
			nu._setup_begin(s.decks[k], people, pods, carts)
			_su_unit = nu
		var u := _su_unit
		u._setup_chunk()
		if u._setup_part < SETUP_PARTS:
			return
		var base := k * ID_STRIDE
		u.civilian_killed.connect(func(id: int, p: Vector3, src: int) -> void: civilian_killed.emit(base + id, p, src))
		u.civilian_event.connect(civilian_event.emit)
		u.vehicle_event.connect(vehicle_event.emit)
		u.tally_changed.connect(tally_changed.emit)
		_su_units.append(u)
		_su_unit = null
		_su_k += 1
		return
	units = _su_units.duplicate()
	_su_units.clear()
	for u in units:
		u._setup_part = -1      # every deck is set up: the units run from now on
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


## The deck unit k of a stack (this node itself on a district of its own).
func unit(k: int) -> AmbientLife:
	if units.is_empty():
		return self
	return units[clampi(k, 0, units.size() - 1)]


func _unit_of(id: int) -> AmbientLife:
	return units[clampi(id / ID_STRIDE, 0, units.size() - 1)]


## Every person id (stack ids in a stack).
func ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	if units.is_empty():
		for i in count():
			out.append(i)
		return out
	for u in units:
		for i in u.count():
			out.append(u.deck * ID_STRIDE + i)
	return out


func vehicle_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	if units.is_empty():
		for i in vehicle_count():
			out.append(i)
		return out
	for u in units:
		for i in u.vehicle_count():
			out.append(u.deck * ID_STRIDE + i)
	return out


func _build_traffic() -> void:
	traffic = LifeTraffic.make(plan, pods, carts)
	fleet = LifeFleet.new(traffic)
	cars.build(traffic.vehicles, _local_bounds(), district.render_layer)
	var m := traffic.count()
	_vta.resize(m)
	_vtb.resize(m)
	_vxa.resize(m)
	_vxb.resize(m)
	_vhaz.resize(m)
	_vstate.resize(m)
	_vdoors.resize(m)
	_vpos.resize(m)
	_vaxis.resize(m)
	_vpx.resize(m)
	_vps.resize(m)
	_vdir.resize(m)
	_von.resize(m)
	_vband.resize(m)
	for i in m:
		_vstate[i] = "driving"
		_vdoors[i] = -INF
		_vband[i] = NEAR
	_vtip.clear()
	_vasked.clear()


## Section mode: the tram's cars and the checkpoint / cordon dressing (none on a district of its own).
func _build_section() -> void:
	_tram_state = ""
	if tram_cars != null:
		remove_child(tram_cars)
		tram_cars.queue_free()
		tram_cars = null
	if barriers != null:
		remove_child(barriers)
		barriers.queue_free()
		barriers = null
	if district.plan.section == null:
		return
	if tram != null:
		tram_cars = LifeTramCars.new()
		tram_cars.top_level = true
		add_child(tram_cars)
		tram_cars.build(_local_bounds(), district.render_layer)
	var geo := CityGeo.new(_ring)
	LifeBarriers.build(geo, district.plan)
	if not geo.is_empty():
		barriers = geo.instance("Barriers", CityPalette.surface_material())
		barriers.top_level = true
		barriers.layers = district.render_layer
		add_child(barriers)
	_tram_step()


## Change the number of people (rebuilds the plan; forgets every threat, kill and wreck).
func set_people(n: int) -> void:
	if stack != null:
		setup_stack(stack, n, pods, carts)
	elif district != null:
		setup(district, n, pods, carts)


## Change the number of pods and carts (forgets every vehicle event; the people keep theirs).
func set_vehicles(pod_count: int, cart_count: int) -> void:
	pods = pod_count
	carts = cart_count
	for u in units:
		u.set_vehicles(pod_count, cart_count)
	if plan != null:
		_build_traffic()
		_tick = -1
		_redraw_exact(false)


func _local_bounds() -> AABB:
	var e := district.plan.extent
	var box := AABB(_ring.arc_to_world(e.position.x, e.position.y), Vector3.ZERO)
	for k in 9:
		var s := lerpf(e.position.y, e.end.y, float(k) / 8.0)
		for x: float in [e.position.x, e.end.x]:
			box = box.expand(_ring.arc_to_world(x, s, -1.0))
			box = box.expand(_ring.arc_to_world(x, s, 4.0))
	return box.grow(4.0)


func _follow() -> void:
	if district == null or not district.is_inside_tree():
		return
	var xf := district.global_transform
	for n: Node3D in [figures, cars, tram_cars, barriers]:
		if n != null and n.is_inside_tree():
			n.global_transform = xf


func _to_world() -> Transform3D:
	return district.global_transform if district != null and district.is_inside_tree() else Transform3D.IDENTITY


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


## A unit: where this deck's viewers are (district-local) and whether any is on it.
func _set_view(cull: bool, pts: PackedVector3Array, active: bool) -> void:
	if cull != _cull:
		_tick = -1
	_cull = cull
	_views = pts
	if active == _active:
		return
	_active = active
	_tick = -1
	figures.visible = active
	cars.visible = active
	if barriers != null:
		barriers.visible = active
	if tram_cars != null:
		tram_cars.set_drawn(active)
	if not active:
		_any_out = false
		_vany = false
		_pos_rev += 1
		_on.fill(0)
		_von.fill(0)


func _band_of(p: Vector3) -> int:
	if not _cull:
		return NEAR
	var best := INF
	for v in _views:
		best = minf(best, v.distance_squared_to(p))
	if best <= EVAL_R * EVAL_R:
		return NEAR
	return MID if best <= DRAW_R * DRAW_R else FAR


# --- Quality (CityQuality: drawing only) --------------------------------------------------------------------

## Draw level q (CityQuality.LOW / MEDIUM / HIGH): people, vehicles and the tram are drawn only within
## CityQuality.level(q).life_draw_r of a viewer (DRAW_R at HIGH). Nothing else changes: the bands (EVAL_R / DRAW_R),
## sampling, events, `_on` / `_von` (what this machine's shots can hit), the host's decisions and every pose and state
## stay exactly as at HIGH. On a stack's node it covers every deck. Any time, before or after setup.
func set_quality(q: int) -> void:
	quality = CityQuality.clamp_level(q)
	_draw_r = minf(float(CityQuality.level(quality)["life_draw_r"]), DRAW_R)
	_apply_figure_quality()
	var all: Array[AmbientLife] = units.duplicate()
	all.append_array(_su_units)
	if _su_unit != null and is_instance_valid(_su_unit):
		all.append(_su_unit)
	for u in all:
		u._apply_figure_quality()


## The figures' shadows follow the quality: real (posed) shadows at HIGH / MEDIUM, none at LOW. Drawing only.
func _apply_figure_quality() -> void:
	if figures != null:
		var q := _root.quality if _root != null else quality
		figures.set_shadows(q != CityQuality.LOW)


## The draw radius in force (a stack's unit uses its stack node's).
func _life_draw_r() -> float:
	return _root._draw_r if _root != null else _draw_r


## Whether an agent at `p` (district-local) is drawn at this quality: always with no viewer known or at full radius.
func _drawn_at(p: Vector3) -> bool:
	var r := _life_draw_r()
	if not _cull or r >= DRAW_R:
		return true
	for v in _views:
		if v.distance_squared_to(p) <= r * r:
			return true
	return false


func _show_person(id: int, motion: int, xf: Transform3D) -> void:
	if _drawn_at(xf.origin):
		figures.place(id, motion, xf)
	else:
		figures.hide_person(id)


func _show_vehicle(vid: int, want: int, xf: Transform3D) -> void:
	if _drawn_at(xf.origin):
		cars.show_vehicle(vid, want, xf)
	else:
		cars.hide_vehicle(vid)


func _stack_views() -> void:
	var pts: Variant = _viewer_points()
	if pts == null:
		for u in units:
			u._set_view(false, PackedVector3Array(), true)
		return
	var per: Array = []
	for u in units:
		per.append(PackedVector3Array())
	for p: Vector3 in pts:
		var k := stack.deck_at(p)
		if k >= 0 and k < units.size():
			var arr: PackedVector3Array = per[k]          # (packed arrays are values: append, then put back)
			arr.append(units[k]._to_world().affine_inverse() * p)
			per[k] = arr
	for k in units.size():
		units[k]._set_view(true, per[k], not (per[k] as PackedVector3Array).is_empty())


# --- Clock -----------------------------------------------------------------------------------------------

func _clock() -> float:
	var s := Net.session()
	if s != null and s.online():
		return s.host_time()
	return now


func _process(delta: float) -> void:
	if not debug_profile:
		_step(delta)
		return
	var t0 := Time.get_ticks_usec()
	_step(delta)
	debug_us = float(Time.get_ticks_usec() - t0)


func _step(delta: float) -> void:
	if _setup_part >= 0:
		return              # a unit still being set up (setup_step)
	if stack != null:
		for u in units:
			u.time_scale = time_scale
		_route_pushers()
		_stack_views()
		if not units.is_empty():
			now = units[0].now
		return
	if plan == null:
		return
	if _root == null:
		_alone_views()
	var online := Net.online()
	if online != _online_clock:
		_online_clock = online
		_rebase(_clock())
	now = _clock() if online else now + delta * time_scale
	plan.warm_ahead(now, 1)      # crowd spacing: the hold index of the coming minutes, one person a frame
	_flush()
	_pusher_step(delta * (1.0 if online else time_scale))
	_tram_step()
	if _active:
		_advance_draw()


## A district on its own culls only with registered viewers.
func _alone_views() -> void:
	var pts := PackedVector3Array()
	for v: Variant in _viewers:
		if is_instance_valid(v) and (v as Node3D).is_inside_tree():
			pts.append(_to_world().affine_inverse() * (v as Node3D).global_position)
	_set_view(not pts.is_empty(), pts, true)


## The clock source changed (a session began or ended): alarms, halts and lock-downs on the old clock mean nothing on
## the new one. The dead stay down, wrecks stay wrecked, the tallies stay.
func _rebase(t: float) -> void:
	var keep := crowd.dead.duplicate(true)
	crowd.recs.clear()
	crowd.locks.clear()
	crowd.last_threat = -INF
	for id: int in keep:
		(keep[id] as Dictionary)["t"] = t - 1.0
	crowd.dead = keep
	fleet.episodes.clear()
	fleet.locks.clear()
	if tram != null:
		tram.episodes.clear()
	for vid: int in fleet.wrecks:
		var e: Dictionary = fleet.wrecks[vid]
		e["t0"] = t - 10.0
		e["since"] = t - 10.0
	fleet.rebuild_obstacles(t, crowd)
	now = t
	_tick = -1


## Move the clock to `t` and draw everyone exactly there (tests drive time with this, never frames).
func advance_to(t: float) -> void:
	if stack != null:
		_route_pushers()
		_stack_views()
		for u in units:
			u.advance_to(t)
		now = t
		return
	if _root == null:
		_alone_views()
	var dt := maxf(t - now, 0.0)
	now = t
	_flush()
	_pusher_step(dt)
	_tick = -1
	_tram_step()
	if _active:
		_redraw_exact(true)


# --- Sampling and drawing ----------------------------------------------------------------------------------

## [0 drawn transform (district-local, unscaled, upright: the shader topples the dead), 1 motion (LifeAnimRig; -1
## hidden), 2 state, 3 arc x, 4 s, 5 h, 6 tipping (drawn exactly every frame), 7 heading, 8 when the motion began
## (NAN: unknown, the sample's time is used), 9 metres walked (the stride), 10 fall direction (deck angle), 11 the
## person's transform (pose_of: the dead tipped over, LifeFigures.tip)]
func _sample(id: int, t: float) -> Array:
	var p := crowd.pose(id, t)
	if not _force.is_empty():
		p = _debug_pose(id, t, p)
	var frame := _geo.frame(float(p["x"]), float(p["s"]), float(p["h"]))
	var state := str(p["state"])
	var heading := float(p["heading"])
	if not p["visible"]:
		return [frame, -1, state, p["x"], p["s"], p["h"], false, heading, NAN, 0.0, 0.0, frame]
	var mode := str(p["mode"])
	var xf := Transform3D(frame.basis * Basis(Vector3.UP, heading), frame.origin)
	if mode == "down":
		var f := float(p["tip"])
		var dir := Vector3(float(p["dx"]), 0.0, float(p["ds"]))
		var start := float(p["t_start"]) if p.has("t_start") else float(crowd.dead[id]["t"]) if crowd.dead.has(id) else NAN
		return [xf, LifeAnimRig.FALL, state, p["x"], p["s"], p["h"], f < 1.0, heading, start, 0.0, atan2(dir.x, dir.z),
				LifeFigures.tip(frame, dir, f, heading)]
	var m := LifeAnimRig.IDLE
	var start := float(p["t_start"]) if p.has("t_start") else NAN
	match mode:
		"walk": m = LifeAnimRig.WALK
		"run":
			m = LifeAnimRig.RUN
			if is_nan(start):
				start = _rec_time(id, t, "t_flee")
		"sit": m = LifeAnimRig.SIT
		"wary":
			m = LifeAnimRig.FLINCH
			if is_nan(start):
				start = _rec_time(id, t, "t0")
		"hands_up":                     # only from debug_force_state (the game shows hands up through "cower" below)
			m = LifeAnimRig.HANDS
		"look_around":                  # only from debug_force_state (in the game it is one of the idle's variations)
			m = LifeAnimRig.LOOK
		"cower":
			m = LifeAnimRig.COWER
			if is_nan(start):
				start = _rec_time(id, t, "t_flee")
			if _hands_up(Vector2(p["x"], p["s"]), t):
				m = LifeAnimRig.HANDS
				state = "hands_up"
				start = NAN
	return [xf, m, state, p["x"], p["s"], p["h"], false, heading, start, float(p["dist"]), 0.0, xf]


## Field `key` of the alarm record in force for `id` at t (as LifeCrowd.pose walks them), NAN if none. Animation only.
func _rec_time(id: int, t: float, key: String) -> float:
	var r: Variant = crowd.recs.get(id)
	while r != null and t < float((r as Dictionary)["t0"]):
		r = (r as Dictionary).get("prev")
	return float((r as Dictionary)[key]) if r != null else NAN


## The animation of person `id` from its sample `a` taken at `ta` (cosmetic, local: the same state and clock give the
## same custom data on every machine). Writes LifeFigures' custom data only when the motion changes or a turn starts.
func _animate(id: int, a: Array, ta: float) -> void:
	var m := int(a[1])
	if m < 0:
		_drawn_mo[id] = -1
		return
	var was := _drawn_mo[id]
	var heading := float(a[7])
	if was < 0:
		_yaw[id] = heading          # appears (out of a door, into range): no blend, no turn
	var gap := 0.0 if m == LifeAnimRig.FALL else wrapf(heading - _yaw[id], -PI, PI)
	if m == was:
		if absf(gap) < LifeAnimRig.TURN_MIN or ta - _mo_t0[id] < 0.5 or not m in [LifeAnimRig.WALK, LifeAnimRig.RUN,
				LifeAnimRig.IDLE, LifeAnimRig.LOOK]:
			return
	var t0 := ta
	var start := float(a[8])
	if m != was and not is_nan(start):
		t0 = start if ta - start > 0.4 else maxf(start, ta - 0.08)   # live: start it now-ish, never skip the start
	var speed := float(plan.person(id)["speed"])
	var param := 0.0
	if m == LifeAnimRig.WALK:
		param = fposmod(float(a[9]) - speed * (ta - t0), 512.0)
	elif m == LifeAnimRig.RUN:
		param = fposmod(float(a[9]) - LifeCrowd.RUN * (ta - t0), 512.0)
	elif m == LifeAnimRig.FALL:
		param = wrapf(float(a[10]) - _yaw[id], -PI, PI)        # relative to the body as drawn
	var talk := false
	if m == LifeAnimRig.IDLE:
		var at := (a[0] as Transform3D).origin
		for j in plan.total():
			if j != id and (_drawn_mo[j] == LifeAnimRig.IDLE or _drawn_mo[j] == LifeAnimRig.LOOK) \
					and _pos[j].distance_squared_to(at) < 9.0:
				talk = true
				break
	figures.set_motion(id, m, m if was < 0 else was, t0, gap if absf(gap) >= 0.1 else 0.0, speed, param, talk)
	_drawn_mo[id] = m
	_mo_t0[id] = t0


## The drawn transform of `id`: `xf` turned to the drawn heading, which eases toward the route's heading `h` (step `k`
## of the exponential; frozen while falling). Positions, and so every hit test, are untouched.
func _turned(id: int, xf: Transform3D, h: float, k: float) -> Transform3D:
	if _drawn_mo[id] != LifeAnimRig.FALL:
		_yaw[id] += wrapf(h - _yaw[id], -PI, PI) * k
	var corr := wrapf(_yaw[id] - h, -PI, PI)
	if absf(corr) < 1e-4:
		return xf
	return Transform3D(xf.basis * Basis(Vector3.UP, corr), xf.origin)


## [transform (district-local), hazard, state, arc x, s, tipping, pose]
func _vsample(vid: int, t: float) -> Array:
	var p := fleet.pose(vid, t)
	var frame := _geo.frame(float(p["x"]), float(p["s"]), 0.0)
	var basis := frame.basis * Basis(Vector3.UP, float(p["heading"]))
	var origin := frame.origin
	var tilt := float(p["tilt"])
	if tilt > 1e-4:
		var size: Vector3 = LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]]
		basis = basis * Basis(Vector3.BACK, -float(p["roll"]) * tilt)
		origin += frame.basis.y * size.x * 0.5 * sin(tilt)
	var tipping: bool = p["wreck"] and tilt < float(fleet.wrecks[vid]["tilt1"]) - 1e-4
	return [Transform3D(basis, origin), bool(p["hazard"]), str(p["state"]), p["x"], p["s"], tipping, p]


func _hands_up(at: Vector2, t: float) -> bool:
	if t - crowd.last_threat < HANDS_QUIET:
		return false
	for q in _pusher_arc:
		if q.distance_to(at) <= HANDS_R:
			return true
	return false


func _advance_draw() -> void:
	_follow()
	figures.set_clock(now)
	var target := int(floor(now / TICK))
	if _tick < 0 or target - _tick > 8 or target < _tick - 2:
		_resample_all(target)
	else:
		while _tick <= target:
			_do_tick(_tick)
			_tick += 1
	_display()


func _resample_all(target: int) -> void:
	for id in plan.total():
		var k := target - posmod(target - id % GROUPS, GROUPS)
		if _cull:
			var a := _sample(id, float(k) * TICK)
			var band := _band_of((a[0] as Transform3D).origin)
			_band[id] = band
			if band == FAR:
				_far(id, a, float(k) * TICK)
				continue
			_set_samples(id, k, false, GROUPS if band == NEAR else GROUPS * SLOW)
		else:
			_band[id] = NEAR
			_set_samples(id, k, false)
	for vid in traffic.count():
		var k := target - posmod(target - vid % GROUPS, GROUPS)
		if _cull:
			var a := _vsample(vid, float(k) * TICK)
			var band := _band_of((a[0] as Transform3D).origin)
			_vband[vid] = band
			if band == FAR:
				_vfar(vid, a, float(k) * TICK)
				continue
			_set_vsamples(vid, k, false, GROUPS if band == NEAR else GROUPS * SLOW)
		else:
			_vband[vid] = NEAR
			_set_vsamples(vid, k, false)
	_tick = target + 1


func _do_tick(k: int) -> void:
	var g := posmod(k, GROUPS)
	var id := g
	while id < plan.total():
		if _cull:
			_cull_tick(id, k)
		else:
			_set_samples(id, k, true)
		id += GROUPS
	var vid := g
	while vid < traffic.count():
		if _cull:
			_vcull_tick(vid, k)
		else:
			_set_vsamples(vid, k, true)
		vid += GROUPS


## One person's tick with viewers known: near every tick of its group, mid-range when its 1 s sample runs out, far once a
## second (one sample, to see whether it has come into range).
func _cull_tick(id: int, k: int) -> void:
	var ta := float(k) * TICK
	var was := _band[id]
	var band := _band_of(_xb[id].origin)
	if band == FAR:
		if was == FAR and posmod(k / GROUPS + id, SLOW) != 0:
			return
		var a := _sample(id, ta)
		band = _band_of((a[0] as Transform3D).origin)
		if band == FAR:
			_far(id, a, ta)
			return
		_band[id] = band
		_set_samples(id, k, false, GROUPS if band == NEAR else GROUPS * SLOW)
		return
	_band[id] = band
	if band == NEAR or was != band or ta >= _tb[id] - 1e-6:
		_set_samples(id, k, was != FAR, GROUPS if band == NEAR else GROUPS * SLOW)


func _vcull_tick(vid: int, k: int) -> void:
	var ta := float(k) * TICK
	var was := _vband[vid]
	var band := _band_of(_vxb[vid].origin)
	if band == FAR:
		if was == FAR and posmod(k / GROUPS + vid, SLOW) != 0:
			return
		var a := _vsample(vid, ta)
		band = _band_of((a[0] as Transform3D).origin)
		if band == FAR:
			_vfar(vid, a, ta)
			return
		_vband[vid] = band
		_set_vsamples(vid, k, false, GROUPS if band == NEAR else GROUPS * SLOW)
		return
	_vband[vid] = band
	if band == NEAR or was != band or ta >= _vtb[vid] - 1e-6:
		_set_vsamples(vid, k, was != FAR, GROUPS if band == NEAR else GROUPS * SLOW)


## A person out of draw range: remember where it is (to notice it coming back), hidden.
func _far(id: int, a: Array, ta: float) -> void:
	_band[id] = FAR
	_ta[id] = ta
	_tb[id] = ta
	_xa[id] = a[0]
	_xb[id] = a[0]
	_motion[id] = -1
	_drawn_mo[id] = -1
	_vis_b[id] = 0
	_state[id] = str(a[2])
	_last_b[id] = null
	_falling.erase(id)


func _vfar(vid: int, a: Array, ta: float) -> void:
	_vband[vid] = FAR
	_vta[vid] = ta
	_vtb[vid] = ta
	_vxa[vid] = a[0]
	_vxb[vid] = a[0]
	_vhaz[vid] = 1 if a[1] else 0
	_vstate[vid] = str(a[2])
	_vtip.erase(vid)


## Sample A at tick k, sample B `period` ticks later. `events`: emit what changed since the last sample A.
func _set_samples(id: int, k: int, events: bool, period: int = GROUPS) -> void:
	var ta := float(k) * TICK
	var tb := float(k + period) * TICK
	var a: Array
	if events and _ta[id] < _tb[id] and is_equal_approx(_tb[id], ta) and _last_b[id] != null:
		a = _last_b[id]              # the previous sample B is this sample A
	else:
		a = _sample(id, ta)
	var b := _sample(id, tb)
	_last_b[id] = b
	if events:
		_transition(id, _state[id], str(a[2]), a, ta)
	_ta[id] = ta
	_tb[id] = tb
	_xa[id] = a[0]
	_xb[id] = b[0]
	_motion[id] = int(a[1])
	_ha[id] = float(a[7])
	_hb[id] = float(b[7])
	_vis_b[id] = 1 if int(b[1]) >= 0 else 0
	_state[id] = str(a[2])
	_animate(id, a, ta)
	if bool(a[6]):
		_falling[id] = true


func _set_vsamples(vid: int, k: int, events: bool, period: int = GROUPS) -> void:
	var ta := float(k) * TICK
	var tb := float(k + period) * TICK
	var a := _vsample(vid, ta)
	var b := _vsample(vid, tb)
	if events:
		_vtransition(vid, _vstate[vid], a, ta)
	_vta[vid] = ta
	_vtb[vid] = tb
	_vxa[vid] = a[0]
	_vxb[vid] = b[0]
	_vhaz[vid] = 1 if a[1] else 0
	_vstate[vid] = str(a[2])
	if bool(a[5]) or bool(b[5]):
		_vtip[vid] = true


func _display() -> void:
	var first := true
	_any_out = false
	_pos_rev += 1
	var k := 1.0 - exp(-clampf(now - _draw_now, 0.0, 1.0) / LifeAnimRig.TURN_TAU)
	_draw_now = now
	for id in plan.total():
		if _falling.has(id):
			var e := _sample(id, now)
			_animate(id, e, now)
			_show_person(id, int(e[1]), _turned(id, e[0], float(e[7]), k))
			_px[id] = e[3]
			_ps[id] = e[4]
			_pos[id] = (e[0] as Transform3D).origin
			_up[id] = (e[0] as Transform3D).basis.y.normalized()
			_on[id] = 0
			if not bool(e[6]):
				_falling.erase(id)
			continue
		var motion := _motion[id]
		if motion < 0:
			figures.hide_person(id)
			_on[id] = 0
			continue
		var xf: Transform3D = _xa[id]
		var h := _ha[id]
		if _vis_b[id] == 1:
			var f := clampf((now - _ta[id]) / maxf(_tb[id] - _ta[id], 1e-6), 0.0, 1.0)
			if not _xa[id].is_equal_approx(_xb[id]):
				xf = _xa[id].interpolate_with(_xb[id], f)
				h = lerp_angle(_ha[id], _hb[id], f)
		_show_person(id, motion, _turned(id, xf, h, k))
		_pos[id] = xf.origin
		_up[id] = xf.basis.y.normalized()
		var alive := not crowd.dead.has(id)
		_on[id] = 1 if alive else 0
		if alive:
			var arc := _ring.world_to_arc(xf.origin)
			_px[id] = arc.x
			_ps[id] = arc.y
			if first:
				_bounds = AABB(xf.origin, Vector3.ZERO)
				first = false
			else:
				_bounds = _bounds.expand(xf.origin)
			_any_out = true
	if _any_out:
		_bounds = _bounds.grow(0.1)
	_vdisplay()


func _vdisplay() -> void:
	var blink := fposmod(now * BLINK_HZ, 1.0) < 0.5
	var first := true
	_vany = false
	for vid in traffic.count():
		if _vband[vid] == FAR:
			cars.hide_vehicle(vid)
			_von[vid] = 0
			continue
		var xf: Transform3D
		var haz: bool
		if _vtip.has(vid):
			var e := _vsample(vid, now)
			xf = e[0]
			haz = e[1]
			if not bool(e[5]):
				_vtip.erase(vid)
		else:
			xf = _vxa[vid]
			haz = _vhaz[vid] == 1
			if not _vxa[vid].is_equal_approx(_vxb[vid]):
				xf = _vxa[vid].interpolate_with(_vxb[vid], clampf((now - _vta[vid]) / maxf(_vtb[vid] - _vta[vid], 1e-6), 0.0, 1.0))
		_show_vehicle(vid, (LifeCars.HAZARD_BRIGHT if blink else LifeCars.HAZARD_DARK) if haz else LifeCars.PLAIN, xf)
		_vstore(vid, xf)
		if first:
			_vbounds = AABB(_vpos[vid], Vector3.ZERO)
			first = false
		else:
			_vbounds = _vbounds.expand(_vpos[vid])
		_vany = true
	if _vany:
		_vbounds = _vbounds.grow(2.5)


## Keep what the hit tests need from a vehicle's drawn transform.
func _vstore(vid: int, xf: Transform3D) -> void:
	var size: Vector3 = LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]]
	var up := xf.basis.y.normalized()
	var fwd := xf.basis.z.normalized()
	_vpos[vid] = xf.origin + up * size.y * 0.5
	_vaxis[vid] = fwd * maxf(size.z * 0.5 - size.x * 0.5, 0.0)
	var arc := _ring.world_to_arc(xf.origin)
	_vpx[vid] = arc.x
	_vps[vid] = arc.y
	var fb := CityGeo.frame_basis(_ring, arc.y)
	var d := Vector2(fwd.dot(fb.x), fwd.dot(fb.z))
	_vdir[vid] = d.normalized() if d.length_squared() > 1e-8 else Vector2(0.0, 1.0)
	_von[vid] = 0 if fleet.wrecks.has(vid) else 1


## Everyone drawn exactly at `now` (tests, setup, after an event). With viewers known, agents out of draw range are
## sampled once (to know where they are) and hidden.
func _redraw_exact(events: bool) -> void:
	_follow()
	figures.set_clock(now)
	var k := 1.0 - exp(-clampf(now - _draw_now, 0.0, 1.0) / LifeAnimRig.TURN_TAU)
	_draw_now = now
	var first := true
	_any_out = false
	_pos_rev += 1
	for id in plan.total():
		var e := _sample(id, now)
		if events:
			_transition(id, _state[id], str(e[2]), e, now)
		_state[id] = str(e[2])
		_ta[id] = now
		_tb[id] = now
		_xa[id] = e[0]
		_xb[id] = e[0]
		_motion[id] = int(e[1])
		_ha[id] = float(e[7])
		_hb[id] = float(e[7])
		_vis_b[id] = 0
		_last_b[id] = null
		_band[id] = _band_of((e[0] as Transform3D).origin)
		if _band[id] == FAR:
			_motion[id] = -1
		if bool(e[6]) and _motion[id] >= 0:
			_falling[id] = true
		else:
			_falling.erase(id)
		if _motion[id] < 0:
			_drawn_mo[id] = -1
			figures.hide_person(id)
			_on[id] = 0
			continue
		_animate(id, e, now)
		_show_person(id, int(e[1]), _turned(id, e[0], float(e[7]), k))
		_pos[id] = (e[0] as Transform3D).origin
		_up[id] = (e[0] as Transform3D).basis.y.normalized()
		_px[id] = e[3]
		_ps[id] = e[4]
		var alive := not crowd.dead.has(id)
		_on[id] = 1 if alive else 0
		if alive:
			_bounds = AABB(_pos[id], Vector3.ZERO) if first else _bounds.expand(_pos[id])
			first = false
			_any_out = true
	if _any_out:
		_bounds = _bounds.grow(0.1)
	var blink := fposmod(now * BLINK_HZ, 1.0) < 0.5
	var vfirst := true
	_vany = false
	for vid in traffic.count():
		var e := _vsample(vid, now)
		if events:
			_vtransition(vid, _vstate[vid], e, now)
		_vta[vid] = now
		_vtb[vid] = now
		_vxa[vid] = e[0]
		_vxb[vid] = e[0]
		_vhaz[vid] = 1 if e[1] else 0
		_vstate[vid] = str(e[2])
		_vband[vid] = _band_of((e[0] as Transform3D).origin)
		if _vband[vid] == FAR:
			_vtip.erase(vid)
			cars.hide_vehicle(vid)
			_von[vid] = 0
			continue
		if bool(e[5]):
			_vtip[vid] = true
		else:
			_vtip.erase(vid)
		_show_vehicle(vid, (LifeCars.HAZARD_BRIGHT if blink else LifeCars.HAZARD_DARK) if bool(e[1]) else LifeCars.PLAIN, e[0])
		_vstore(vid, e[0])
		_vbounds = AABB(_vpos[vid], Vector3.ZERO) if vfirst else _vbounds.expand(_vpos[vid])
		vfirst = false
		_vany = true
	if _vany:
		_vbounds = _vbounds.grow(2.5)


# --- Tram --------------------------------------------------------------------------------------------------

## The tram's cars at `now`: drawn on an active deck within DRAW_R of a viewer, collision bodies always moved. Rings
## "tram_bell" when it leaves a stop or restarts after a halt.
func _tram_step() -> void:
	if tram == null or tram_cars == null:
		return
	var p := tram.pose(now)
	var st := str(p["mode"])
	if st == "running" and (_tram_state == "dwell" or _tram_state == "halted"):
		_emit("tram_bell", Vector2(tram.x, float(p["s"])), 3.0, true)
	_tram_state = st
	var world := _to_world()
	var near := _active
	if near and _cull:
		var c := _geo.frame(tram.x, float(p["s"]), 0.0).origin
		near = _band_of(c) != FAR or _band_of(_geo.frame(tram.x, float(p["s"]) + LifeTram.HALF, 0.0).origin) != FAR \
				or _band_of(_geo.frame(tram.x, float(p["s"]) - LifeTram.HALF, 0.0).origin) != FAR
		if near and _life_draw_r() < DRAW_R:      # quality: drawn only within the shorter draw radius (bodies still move)
			near = _drawn_at(c) or _drawn_at(_geo.frame(tram.x, float(p["s"]) + LifeTram.HALF, 0.0).origin) \
					or _drawn_at(_geo.frame(tram.x, float(p["s"]) - LifeTram.HALF, 0.0).origin)
	var blink := fposmod(now * BLINK_HZ, 1.0) < 0.5
	var lights := (LifeTramCars.HAZARD_BRIGHT if blink else LifeTramCars.HAZARD_DARK) if bool(p["hazard"]) else LifeTramCars.PLAIN
	for i in LifeTram.CARS:
		var cs := LifeTram.car_s(float(p["s"]), i)
		var xf := _geo.frame(tram.x, cs, 0.0)
		var inside := tram.car_inside(cs)
		tram_cars.place(i, (lights if near else -2) if inside else -1, xf, world * xf)


## Car i's transform in world space now (exact; floor centre, local +Z along +s), and whether it is in the map.
func tram_car_pose(i: int) -> Transform3D:
	var p := tram.pose(now)
	return _to_world() * _geo.frame(tram.x, LifeTram.car_s(float(p["s"]), i), 0.0)


## running | dwell | halted | away (beyond a portal), now; "" with no tram. In a stack: deck k's.
func tram_state(k: int = 0) -> String:
	var u := unit(k)
	return u.tram.state_of(u.now) if u.tram != null else ""


# --- Audio hooks -------------------------------------------------------------------------------------------

func _transition(id: int, was: String, is_: String, e: Array, t: float) -> void:
	var at := Vector2(float(e[3]), float(e[4]))
	if is_ == "wary" and was != "wary":
		_emit("gasp", at, float(e[5]))
	elif is_ == "fleeing" and was != "fleeing":
		_emit("scream", at, float(e[5]))
		_steps_at[id] = t
	elif is_ == "fleeing" and t - _steps_at[id] >= STEP_EVERY:
		_steps_at[id] = t
		_emit("run_steps", at, float(e[5]))
	elif is_ == "sheltered" and was == "fleeing":
		var d := crowd.pose(id, t)
		_emit("door_slam", Vector2(d["x"], d["s"]), CityPlan.CURB_H)
	elif (is_ == "cowering" or is_ == "hands_up") and was != "cowering" and was != "hands_up":
		_emit("whimper", at, float(e[5]))


func _vtransition(vid: int, was: String, e: Array, t: float) -> void:
	var is_ := str(e[2])
	var at := Vector2(float(e[3]), float(e[4]))
	if is_ == "estop" and was != "estop":
		_emit("brake", at, 0.5, true)
		if traffic.lp.h(vid + 70000, int(t * 10.0), 41) < 0.5:
			_emit("horn", at, 0.8, true)
	elif is_ == "fleeing" and was != "fleeing":
		_emit("horn", at, 0.8, true)
	elif is_ == "abandoned" and was != "abandoned":
		_emit("hazard", at, 0.8, true)
	elif is_ == "wreck" and was != "wreck":
		_emit("alarm", at, 0.8, true)
		var w: Dictionary = fleet.wrecks[vid]
		if float(w["tilt1"]) > float(w["tilt0"]) + 1e-4:
			_emit("tip", at, 0.5, true)
	var r := fleet._anchor_at(vid, t)
	if not r.is_empty():
		var doors := float(r["doors"])
		if doors >= 0.0 and t >= doors and _vdoors[vid] < doors:
			_vdoors[vid] = doors
			_emit("doors", at, 1.0, true)


func _emit(kind: String, at: Vector2, h: float, vehicle: bool = false) -> void:
	var key := "%s:%d:%d" % [kind, int(floor(at.x / CELL)), int(floor(at.y / CELL))]
	if now - float(_heard.get(key, -INF)) < float(THROTTLE[kind]):
		return
	_heard[key] = now
	var world := _to_world() * _ring.arc_to_world(at.x, at.y, h + (0.0 if vehicle else 1.0))
	if vehicle:
		vehicle_event.emit(kind, world)
	else:
		civilian_event.emit(kind, world)


# --- Queries ---------------------------------------------------------------------------------------------

## calm | wary | fleeing | sheltered | cowering | hands_up | down, at the current clock time.
func state_of(id: int) -> String:
	if not units.is_empty():
		return _unit_of(id).state_of(id % ID_STRIDE)
	return str(_sample(id, now)[2])


## The person's transform in world space now (exact, not interpolated; feet at the origin, facing local +Z).
func pose_of(id: int) -> Transform3D:
	if not units.is_empty():
		return _unit_of(id).pose_of(id % ID_STRIDE)
	return _to_world() * (_sample(id, now)[11] as Transform3D)


## Whether person `id` is outdoors (could be drawn) now.
func visible_now(id: int) -> bool:
	if not units.is_empty():
		return _unit_of(id).visible_now(id % ID_STRIDE)
	return int(_sample(id, now)[1]) >= 0


## Whether person `id` is drawn now (outdoors and within a viewer's draw range).
func drawn_now(id: int) -> bool:
	if not units.is_empty():
		return _unit_of(id).drawn_now(id % ID_STRIDE)
	return figures.shown(id) >= 0


## People (timetabled ones, then the pod riders: drawn only once a pod lets them out). In a stack: all decks (use ids()).
func count() -> int:
	if not units.is_empty():
		var n := 0
		for u in units:
			n += u.count()
		return n
	return plan.total() if plan != null else 0


func vehicle_count() -> int:
	if not units.is_empty():
		var n := 0
		for u in units:
			n += u.vehicle_count()
		return n
	return traffic.count() if traffic != null else 0


## driving | stopped | dwell | docked | estop | fleeing | abandoned | wreck, at the current clock time.
func vehicle_state(id: int) -> String:
	if not units.is_empty():
		return _unit_of(id).vehicle_state(id % ID_STRIDE)
	return fleet.state_of(id, now)


## The vehicle's transform in world space now (exact; on the road, nose along local +Z).
func vehicle_pose(id: int) -> Transform3D:
	if not units.is_empty():
		return _unit_of(id).vehicle_pose(id % ID_STRIDE)
	return _to_world() * (_vsample(id, now)[0] as Transform3D)


func vehicle_kind(id: int) -> String:
	if not units.is_empty():
		return _unit_of(id).vehicle_kind(id % ID_STRIDE)
	return str(traffic.vehicles[id]["kind"])


## {killed_by_players, killed_by_enemies, by_src: {src: n}, dead (figures down), occupants_killed (inside pods, no
## figures; also counted in the first three), wrecks}. In a stack: summed over the decks.
func tally() -> Dictionary:
	if not units.is_empty():
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
	var t := crowd.tally()
	t["wrecks"] = fleet.wrecks.size() if fleet != null else 0
	return t


## The animation person `id` shows now: walk | wait | sit | run | wary | cower | hands_up | down | indoor (indoor: not
## drawn). What a figure drawer is asked to draw (with state_of for the behaviour behind it).
func mode_of(id: int) -> String:
	if not units.is_empty():
		return _unit_of(id).mode_of(id % ID_STRIDE)
	var p := crowd.pose(id, now)
	if not _force.is_empty():
		p = _debug_pose(id, now, p)
	var mode := str(p["mode"])
	if mode == "cower" and _hands_up(Vector2(p["x"], p["s"]), now):
		return "hands_up"
	return mode


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
	for u in units:
		u.debug_force_state(id if id < 0 else (id % ID_STRIDE if id / ID_STRIDE == u.deck else -2), key)
	if id == -2:
		return
	if key == "" or key == "timetable":
		_force.erase(id)
	elif DEBUG_STATES.has(key):
		if id < 0:
			_force.clear()
		_force[id] = [key, now]
	else:
		push_warning("AmbientLife.debug_force_state: unknown state %s" % key)
		return
	_tick = -1


## LAB ONLY: lift every debug_force_state: everyone back on the timetable / the threats' state.
func debug_clear() -> void:
	for u in units:
		u.debug_clear()
	_force.clear()
	_tick = -1


## The DEBUG_STATES key forced on `id` ("" none).
func debug_forced(id: int) -> String:
	if not units.is_empty():
		return _unit_of(id).debug_forced(id % ID_STRIDE)
	var f: Variant = _force.get(id, _force.get(-1))
	return str((f as Array)[0]) if f != null else ""


## Everything the crowd lab's inspector shows about person `id`, from the crowd's data (no drawing): id, state, mode,
## forced, visible, alive, x, s, h, heading (deg), speed (m/s now), cruise (walking speed), rider, activity (timetable:
## walk | wait | sit | cross | indoor), door_a / door_d (this trip's home and destination doors, -1 none) and their arc
## points home / dest, bench, alarm ({t0, t_flee, kind flee|cower, st, door, face deg, last} or {}), down ({t, src} or
## {}), and the seeded variety: cloth, build, tall, period, phase.
func debug_person(id: int) -> Dictionary:
	if not units.is_empty():
		var o := _unit_of(id).debug_person(id % ID_STRIDE)
		if not o.is_empty():
			o["id"] = id
		return o
	if plan == null or id < 0 or id >= plan.total():
		return {}
	var p := crowd.pose(id, now)
	if not _force.is_empty():
		p = _debug_pose(id, now, p)
	var q := crowd.pose(id, now - 0.2)
	var pp := plan.person(id)
	var out := {"id": id, "state": state_of(id), "mode": mode_of(id), "forced": debug_forced(id), "visible": bool(p["visible"]),
			"alive": not crowd.dead.has(id), "x": float(p["x"]), "s": float(p["s"]), "h": float(p["h"]),
			"heading": rad_to_deg(float(p["heading"])),
			"speed": Vector2(float(p["x"]) - float(q["x"]), float(p["s"]) - float(q["s"])).length() / 0.2 if bool(q["visible"]) else 0.0,
			"cruise": float(pp["speed"]), "rider": id >= plan.count, "activity": "indoor", "door_a": -1, "door_d": -1,
			"home": Vector2.ZERO, "dest": Vector2.ZERO, "bench": -1, "alarm": {}, "down": {},
			"cloth": int(pp["cloth"]), "build": int(pp["build"]), "tall": int(pp["tall"]), "period": float(pp["period"]),
			"phase": float(pp["phase"])}
	if id < plan.count:
		var tr := plan.trip(id, plan.slot_of(id, now))
		out["activity"] = str(plan.pose_in_trip(tr, now)["state"])
		out["door_a"] = int(tr["door_a"])
		out["door_d"] = int(tr["door_d"])
		out["bench"] = int(tr["bench"])
		if not plan.doors.is_empty():
			out["home"] = plan.doors[clampi(int(tr["door_a"]), 0, plan.doors.size() - 1)]["at"]
			out["dest"] = plan.doors[clampi(int(tr["door_d"]), 0, plan.doors.size() - 1)]["at"]
	var r: Variant = crowd.recs.get(id)
	if r != null:
		var rd := r as Dictionary
		out["alarm"] = {"t0": float(rd["t0"]), "t_flee": float(rd["t_flee"]), "st": int(rd["st"]), "door": int(rd["door"]),
				"kind": "flee" if int(rd["kind"]) == LifeCrowd.FLEE else "cower", "face": rad_to_deg(float(rd["face"])),
				"last": float(rd["last"])}
	if crowd.dead.has(id):
		out["down"] = {"t": float(crowd.dead[id]["t"]), "src": int(crowd.dead[id]["src"])}
	return out


## The crowd's pose of `id` at t with a debug_force_state applied (only called while one is set).
func _debug_pose(id: int, t: float, p: Dictionary) -> Dictionary:
	var f: Variant = _force.get(id, _force.get(-1))
	if f == null or not p["visible"] or p["state"] == "down":
		return p
	var key := str((f as Array)[0])
	var spec: Dictionary = DEBUG_STATES[key]
	var q := p.duplicate()
	q["state"] = spec["state"]
	q["mode"] = spec["mode"]
	q["t_start"] = float((f as Array)[1])      # the animation starts when it was forced
	match key:
		"walk": q["dist"] = t * float(plan.person(id)["speed"])     # the stride runs from the clock (walks in place if still)
		"flee": q["dist"] = t * LifeCrowd.RUN
		"down":
			var h := float(p["heading"])
			q["tip"] = clampf((t - float((f as Array)[1])) / LifeCrowd.TIP_S, 0.0, 1.0)
			q["dx"] = -sin(h)          # falls backward
			q["ds"] = -cos(h)
	return q


# --- Threats (host) ------------------------------------------------------------------------------------------

func _decides() -> bool:
	var s := Net.session()
	return s == null or not s.online() or s.is_host()


## Host only (a client's call does nothing): a threat at `world_point`. Merged with any within MERGE_R m and MERGE_S s,
## and at most 4 events a second leave. In a stack it goes to the deck the point is on.
func raise_threat(world_point: Vector3, radius: float, strength: int) -> void:
	if stack != null:
		if not units.is_empty():
			units[clampi(stack.deck_at(world_point), 0, units.size() - 1)].raise_threat(world_point, radius, strength)
		return
	if plan == null or not _decides():
		return
	var arc := _ring.world_to_arc(_to_world().affine_inverse() * world_point)
	var at := Vector2(arc.x, arc.y)
	for r: Array in _recent:
		if now - float(r[0]) <= MERGE_S and at.distance_to(Vector2(r[1], r[2])) <= MERGE_R \
				and float(r[3]) >= radius and int(r[4]) >= strength:
			return
	for q: Array in _pending:
		if at.distance_to(Vector2(q[0], q[1])) <= MERGE_R:
			q[2] = maxf(float(q[2]), radius)
			q[3] = maxi(int(q[3]), strength)
			_flush()
			return
	_pending.append([at.x, at.y, radius, strength])
	_flush()


func _flush() -> void:
	if _pending.is_empty() or now - _last_send < SEND_EVERY:
		return
	var q: Array = _pending.pop_front()
	_last_send = now
	var ev := {"x": float(q[0]), "s": float(q[1]), "r": float(q[2]), "st": int(q[3]), "t": now}
	_recent.append([now, q[0], q[1], q[2], q[3]])
	while not _recent.is_empty() and now - float(_recent[0][0]) > MERGE_S:
		_recent.pop_front()
	_log("life.threat", ev)
	_apply_threat(ev)
	_send(0, "life.threat", ev)


## Apply a decided threat event (the host's own, or one from the host): people first, then vehicles (whose riders join
## the people), then the tram.
func _apply_threat(ev: Dictionary) -> void:
	crowd.apply_threat(ev)
	fleet.apply_threat(ev, crowd)
	if tram != null:
		tram.apply_threat(ev)
	_tick = -1


func _log(kind: String, data: Dictionary) -> void:
	var d := data.duplicate()
	var into := self
	if _root != null:
		d["deck"] = deck
		into = _root
	into.sent.append([kind, d])
	if into.sent.size() > 256:
		into.sent.pop_front()


## Send one event through the session (a stack's unit adds its deck as "deck").
func _send(peer: int, kind: String, data: Dictionary) -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	var d := data
	if _root != null:
		d = data.duplicate()
		d["deck"] = deck
	s.send_event(peer, kind, d)


## Apply one event as the host decided it ("life.threat", "life.down" or "life.wreck"): what a client does on receipt,
## and what a test does to feed a second instance. In a stack, "deck" in the data names the deck (none: deck 0, a district on its own).
func apply_event(kind: String, data: Dictionary) -> void:
	if not units.is_empty():
		units[clampi(int(data.get("deck", 0)), 0, units.size() - 1)].apply_event(kind, data)
		return
	match kind:
		"life.threat":
			_apply_threat(data)
		"life.down":
			var dir: Variant = data.get("dir", Vector2(0, 1))
			_down(int(data.get("id", -1)), float(data.get("t", now)), dir if dir is Vector2 else Vector2(0, 1),
					int(data.get("src", 0)), true)
		"life.wreck":
			_apply_wreck(data)


# --- Weapons ---------------------------------------------------------------------------------------------

## Every outdoor civilian within r + 0.4 m of the segment a -> b (world space) is killed, and every vehicle it touches is
## wrecked (asked of the host on a client). Returns how many people and vehicles were hit; the shot is not changed (the
## tram ignores it). Cheap when nobody is near: two bounds tests per deck, no allocation.
func sweep(a: Vector3, b: Vector3, r: float, src: int) -> int:
	if not units.is_empty():
		var hits := 0
		for u in units:
			hits += u.sweep(a, b, r, src)
		return hits
	if plan == null or (not _any_out and not _vany):
		return 0
	var inv := _to_world().affine_inverse()
	var la := inv * a
	var lb := inv * b
	var reach := r + MARGIN
	var seg := AABB(la, Vector3.ZERO).expand(lb).grow(reach + HEIGHT)
	var n := 0
	if _any_out and seg.intersects(_bounds):
		var pre := (reach + HEIGHT * 0.5) * (reach + HEIGHT * 0.5)
		for id in _shot_ids(seg):
			if _on[id] == 0:
				continue
			var foot := _pos[id]
			var mid := foot + _up[id] * (HEIGHT * 0.5)
			if Geometry3D.get_closest_point_to_segment(mid, la, lb).distance_squared_to(mid) > pre:
				continue
			var pts := Geometry3D.get_closest_points_between_segments(la, lb, foot, foot + _up[id] * HEIGHT)
			if pts[0].distance_to(pts[1]) > reach:
				continue
			if _request(id, _deck_dir(_ps[id], lb - la), src):
				n += 1
	if _vany and seg.intersects(_vbounds):
		for vid in traffic.count():
			if _von[vid] == 0:
				continue
			var c := _vpos[vid]
			var rad := r + float((LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]] as Vector3).x) * 0.5 + 0.1
			var half := _vaxis[vid].length() + rad
			if Geometry3D.get_closest_point_to_segment(c, la, lb).distance_squared_to(c) > half * half:
				continue
			var pts := Geometry3D.get_closest_points_between_segments(la, lb, c - _vaxis[vid], c + _vaxis[vid])
			if pts[0].distance_to(pts[1]) > rad:
				continue
			if _request_wreck(vid, _deck_dir(_vps[vid], lb - la), src, 0, SHOT_PUSH):
				n += 1
	return n


## Every outdoor civilian within `radius` of `point` (world space) is killed and every vehicle in it wrecked (tipped onto
## its side). Returns how many people and vehicles were hit. In a stack only the deck the point is on is touched (a
## blast near a floor hole does not reach through it).
func blast(point: Vector3, radius: float, src: int) -> int:
	if stack != null:
		if units.is_empty():
			return 0
		return units[clampi(stack.deck_at(point), 0, units.size() - 1)].blast(point, radius, src)
	if plan == null or radius <= 0.0 or (not _any_out and not _vany):
		return 0
	var lp := _to_world().affine_inverse() * point
	var n := 0
	if _any_out and AABB(lp, Vector3.ZERO).grow(radius + HEIGHT).intersects(_bounds):
		for id in _shot_ids(AABB(lp, Vector3.ZERO).grow(radius + HEIGHT)):
			if _on[id] == 0:
				continue
			var foot := _pos[id]
			var near := Geometry3D.get_closest_point_to_segment(lp, foot, foot + _up[id] * HEIGHT)
			if near.distance_to(lp) > radius:
				continue
			if _request(id, _deck_dir(_ps[id], foot - lp), src):
				n += 1
	if _vany and AABB(lp, Vector3.ZERO).grow(radius + 2.5).intersects(_vbounds):
		for vid in traffic.count():
			if _vband[vid] == FAR:
				continue
			var c := _vpos[vid]            # (wrecks too: a blast shoves them)
			var near := Geometry3D.get_closest_point_to_segment(lp, c - _vaxis[vid], c + _vaxis[vid])
			var rad := float((LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]] as Vector3).x) * 0.5
			if near.distance_to(lp) > radius + rad:
				continue
			if _request_wreck(vid, _deck_dir(_vps[vid], c - lp), src, 1, BLAST_PUSH):
				n += 1
	return n


## The ids to test against a shot whose reach is the district-local box `box` (everyone whose feet can be within the
## shot's reach lies in it: the tests below need the capsule within reach + HEIGHT of the segment), ascending. All ids
## for the first shot test on fresh positions, a big box or brute_force (the plain loop).
func _shot_ids(box: AABB) -> PackedInt32Array:
	var n := plan.total()
	if _all_ids.size() != n:
		_all_ids.resize(n)
		for i in n:
			_all_ids[i] = i
	if _asks_rev != _pos_rev:
		_asks_rev = _pos_rev
		_grid_asks = 0
	_grid_asks += 1
	var lo := Vector3i((box.position / GRID).floor())
	var hi := Vector3i((box.end / GRID).floor())
	var cells := (hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1)
	if brute_force or _grid_asks < 2 or cells > 64:
		return _all_ids
	if _grid_rev != _pos_rev:
		_grid.clear()
		for i in n:
			if _on[i] == 1:
				var c := Vector3i((_pos[i] / GRID).floor())
				var arr: PackedInt32Array = _grid.get(c, PackedInt32Array())
				arr.append(i)
				_grid[c] = arr
		_grid_rev = _pos_rev
	var out := PackedInt32Array()
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var c := Vector3i(x, y, z)
				if _grid.has(c):
					out.append_array(_grid[c])
	out.sort()
	return out


## A district-local vector as a unit direction in the deck plane at arc s (x, s).
func _deck_dir(s: float, v: Vector3) -> Vector2:
	var b := CityGeo.frame_basis(_ring, s)
	var d := Vector2(v.dot(b.x), v.dot(b.z))
	return d.normalized() if d.length_squared() > 1e-8 else Vector2(0.0, 1.0)


func _request(id: int, dir: Vector2, src: int) -> bool:
	if crowd.dead.has(id):
		return false
	var s := Net.session()
	if s != null and s.is_client():
		if now - float(_asked.get(id, -INF)) < ASK_EVERY and now >= float(_asked.get(id, -INF)):
			return false
		_asked[id] = now
		_send(1, "life.req", {"id": id, "dir": dir, "src": src})
		return true
	return _decide_down(id, dir, src)


## Host: kill `id` now if it is outdoors and alive, and tell the crew.
func _decide_down(id: int, dir: Vector2, src: int) -> bool:
	now = _clock() if Net.online() else now
	if not _down(id, now, dir, src, false):
		return false
	var ev := {"id": id, "t": now, "dir": dir, "src": src}
	_log("life.down", ev)
	_send(0, "life.down", ev)
	return true


func _down(id: int, t: float, dir: Vector2, src: int, force: bool) -> bool:
	if not crowd.kill(id, t, dir, src, force):
		return false
	_on[id] = 0
	_falling[id] = true
	_last_b[id] = null
	_tick = -1
	var dd: Dictionary = crowd.dead[id]
	var world := _to_world() * _ring.arc_to_world(float(dd["x"]), float(dd["s"]), float(dd["h"]))
	civilian_killed.emit(id, world, src)
	tally_changed.emit()
	return true


## Ask for vehicle vid to be wrecked (how 0 shot, 1 blast) or a wreck shoved (how 2, a push) along `dir` at v0 m/s.
func _request_wreck(vid: int, dir: Vector2, src: int, how: int, v0: float) -> bool:
	if fleet.wrecks.has(vid) and how == 0:
		return false
	var s := Net.session()
	if s != null and s.is_client():
		if now - float(_vasked.get(vid, -INF)) < ASK_EVERY and now >= float(_vasked.get(vid, -INF)):
			return false
		_vasked[vid] = now
		_send(1, "life.wreq", {"id": vid, "dir": dir, "src": src, "how": how, "v0": v0})
		return true
	return _decide_wreck(vid, dir, src, how, v0)


## Host: wreck (or shove a wreck) now, and tell the crew.
func _decide_wreck(vid: int, dir: Vector2, src: int, how: int, v0: float) -> bool:
	now = _clock() if Net.online() else now
	if vid < 0 or vid >= traffic.count() or (fleet.wrecks.has(vid) and how == 0):
		return false
	if how == 2 and now - float(_vasked.get(vid, -INF)) < ASK_EVERY and now >= float(_vasked.get(vid, -INF)):
		return false
	_vasked[vid] = now
	var ev := fleet.wreck_event(vid, now, dir, src, how, v0)
	_apply_wreck(ev)
	_log("life.wreck", ev)
	_send(0, "life.wreck", ev)
	return true


func _apply_wreck(ev: Dictionary) -> void:
	var killed := fleet.wreck(ev, crowd)
	var vid := int(ev.get("id", -1))
	if vid >= 0 and vid < traffic.count():
		_von[vid] = 0
		_vtip[vid] = true
	_tick = -1
	if killed > 0:
		tally_changed.emit()


# --- Pushers ---------------------------------------------------------------------------------------------

## Register a mover (a mech's foot, or its body): reads global_position and `velocity` if it has one. On the machine that
## owns it, it kills the civilians within `radius` m and wrecks (or shoves) the vehicles it touches while it moves faster
## than 2 m/s; on the host it is also a threat (12 m, strength 1, once a second) while it moves faster than 0.5 m/s within
## 12 m of someone outdoors or 20 m of a vehicle. `src`: who it counts against (the pilot's peer id, -1 for enemies).
## In a stack it acts on the deck it stands on (re-checked every frame). The tram is never touched.
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
	for p: Array in _pushers:
		if p[0] == body:
			p[1] = radius
			p[2] = src
			return
	_pushers.append([body, radius, src, Vector3.ZERO, false, -INF])


func remove_pusher(body: Node3D) -> void:
	for i in range(_stack_pushers.size() - 1, -1, -1):
		if _stack_pushers[i][0] == body:
			_stack_pushers.remove_at(i)
	for u in units:
		u.remove_pusher(body)
	for i in range(_pushers.size() - 1, -1, -1):
		if _pushers[i][0] == body:
			_pushers.remove_at(i)


## Stack: hand every pusher to the unit of the deck it is on.
func _route_pushers() -> void:
	for i in range(_stack_pushers.size() - 1, -1, -1):
		var p: Array = _stack_pushers[i]
		var body: Variant = p[0]
		if not is_instance_valid(body):
			for u in units:
				u._drop_pusher(body)
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


func _drop_pusher(body: Variant) -> void:
	for i in range(_pushers.size() - 1, -1, -1):
		if _pushers[i][0] == body:
			_pushers.remove_at(i)


static func _owns(body: Node) -> bool:
	var s := Net.session()
	if s == null or not s.online():
		return true
	var owner_peer: Variant = body.get("owner_peer")
	var peer := int(owner_peer) if owner_peer != null else 0
	return peer == s.local_id() or (peer == 0 and s.is_host())


func _pusher_step(delta: float) -> void:
	_pusher_arc.clear()
	if _pushers.is_empty() or plan == null:
		return
	var inv := _to_world().affine_inverse()
	for p: Array in _pushers:
		var body := p[0] as Node3D
		if not is_instance_valid(body) or not body.is_inside_tree():
			continue
		var local := inv * body.global_position
		var arc := _ring.world_to_arc(local)
		var here := Vector2(arc.x, arc.y)
		_pusher_arc.append(here)
		var v2 := Vector2.ZERO
		var vel: Variant = body.get("velocity")
		if vel is Vector3:
			var v := inv.basis * (vel as Vector3)
			var fb := CityGeo.frame_basis(_ring, arc.y)
			v2 = Vector2(v.dot(fb.x), v.dot(fb.z))
		elif bool(p[4]) and delta > 0.0:
			var last: Vector3 = p[3]
			v2 = Vector2(arc.x - last.x, arc.y - last.y) / delta
		p[3] = arc
		p[4] = true
		var speed := v2.length()
		if speed > PROX_SPEED and _decides() and now >= float(p[5]) and _near_life(here):
			p[5] = now + PROX_EVERY
			raise_threat(body.global_position, PROX_R, 1)
		if speed <= FOOT_SPEED or not _owns(body):
			continue
		var reach := float(p[1])
		var dir := v2 / speed
		for id in plan.total():
			if _on[id] == 0:
				continue
			if here.distance_to(Vector2(_px[id], _ps[id])) > reach:
				continue
			if absf(_ring.world_to_arc(_pos[id]).z - arc.z) > FOOT_HEIGHT:
				continue
			_request(id, dir, int(p[2]))
		if arc.z > 4.0:
			continue          # a vehicle is only touched by something at road level
		for vid in traffic.count():
			if _vband[vid] == FAR:
				continue
			var size: Vector3 = LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]]
			var c := Vector2(_vpx[vid], _vps[vid])
			var half := _vdir[vid] * maxf(size.z * 0.5 - size.x * 0.5, 0.0)
			if Geometry2D.get_closest_point_to_segment(here, c - half, c + half).distance_to(here) > reach + size.x * 0.5:
				continue
			_request_wreck(vid, dir, int(p[2]), 2, PUSH_SHOVE * speed)


## Whether anyone outdoors is within PROX_R of `at`, or a vehicle (not a wreck) within PROX_CAR.
func _near_life(at: Vector2) -> bool:
	for id in plan.total():
		if _on[id] == 1 and at.distance_to(Vector2(_px[id], _ps[id])) <= PROX_R:
			return true
	for vid in traffic.count():
		if _von[vid] == 1 and at.distance_to(Vector2(_vpx[vid], _vps[vid])) <= PROX_CAR:
			return true
	return false


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

## What differs from the timetables (for a joiner): the people's snapshot, then the vehicles' (and on a section deck the
## tram's). A stack: every deck's, in deck order.
func snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	if not units.is_empty():
		buf.put_u8(units.size())
		for u in units:
			var b := u.snapshot()
			buf.put_u32(b.size())
			buf.put_data(b)
		return buf.data_array
	var a := crowd.snapshot(now)
	buf.put_u32(a.size())
	buf.put_data(a)
	var f := fleet.snapshot()
	if tram != null:
		buf.put_u32(f.size())
		buf.put_data(f)
		buf.put_data(tram.snapshot())
	else:
		buf.put_data(f)
	return buf.data_array


func restore(bytes: PackedByteArray) -> void:
	if not units.is_empty():
		var sb := StreamPeerBuffer.new()
		sb.data_array = bytes
		var n := sb.get_u8() if bytes.size() > 0 else 0
		for k in units.size():
			var part := PackedByteArray()
			if k < n and sb.get_available_bytes() >= 4:
				var size := sb.get_u32()
				part = sb.get_data(size)[1]
			units[k].restore(part)
		tally_changed.emit()
		return
	if bytes.size() >= 4:
		var buf := StreamPeerBuffer.new()
		buf.data_array = bytes
		var n := buf.get_u32()
		crowd.restore(bytes.slice(4, 4 + n))
		if tram != null:
			buf.seek(4 + n)
			var m := buf.get_u32() if buf.get_available_bytes() >= 4 else 0
			fleet.restore(bytes.slice(8 + n, 8 + n + m))
			tram.restore(bytes.slice(8 + n + m))
		else:
			fleet.restore(bytes.slice(4 + n))
	else:
		crowd.restore(PackedByteArray())
		fleet.restore(PackedByteArray())
		if tram != null:
			tram.restore(PackedByteArray())
	_asked.clear()
	_vasked.clear()
	_falling.clear()
	_vtip.clear()
	for i in _vdoors.size():
		_vdoors[i] = -INF
	_tick = -1
	_tram_step()
	if _active:
		_redraw_exact(false)
	tally_changed.emit()


func _on_event(_from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if not kind.begins_with("life."):
		return
	if _su_stack != null:
		_su_events.append([_from, kind, data, _stamp])     # replayed when setup_step finishes
		return
	if not units.is_empty():
		var s0 := Net.session()
		if kind == "life.sync":
			if s0 != null and s0.is_client():
				for u in units:
					u.now = u._clock()
				restore(data.get("bytes", PackedByteArray()))
			return
		units[clampi(int(data.get("deck", 0)), 0, units.size() - 1)]._on_event(_from, kind, data, _stamp)
		return
	if plan == null:
		return
	var s := Net.session()
	if Net.online() != _online_clock:
		_online_clock = Net.online()          # settle the clock change before an event on the new clock
		_rebase(_clock())
	match kind:
		"life.req":
			var id := int(data.get("id", -1))
			var dir: Variant = data.get("dir")
			if s != null and s.is_host() and id >= 0 and id < plan.total() and dir is Vector2:
				now = _clock()
				_decide_down(id, dir, int(data.get("src", 0)))
		"life.wreq":
			var vid := int(data.get("id", -1))
			var dir: Variant = data.get("dir")
			if s != null and s.is_host() and vid >= 0 and vid < traffic.count() and dir is Vector2:
				now = _clock()
				_decide_wreck(vid, dir, int(data.get("src", 0)), clampi(int(data.get("how", 0)), 0, 2), float(data.get("v0", 0.0)))
		"life.threat", "life.down", "life.wreck":
			if s != null and s.is_client():
				now = _clock()
				apply_event(kind, data)
		"life.sync":
			if s != null and s.is_client():
				now = _clock()
				restore(data.get("bytes", PackedByteArray()))


func _on_peer_joined(peer: int) -> void:
	var s := Net.session()
	if s != null and s.is_host() and (plan != null or not units.is_empty()):
		s.send_event(peer, "life.sync", {"bytes": snapshot()})
