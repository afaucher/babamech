class_name AmbientLife
extends Node3D
## The civilians and driverless vehicles of one city district (docs/design/ambient-life.md; phases 1-2: people, pods,
## service carts). One node per scene, group "ambient_life". A host-arbitrated world system built from scheduled effects:
##   * calm life is a timetable (LifePlan.calm_pose, LifeTraffic.base_pose): free on the network, the same everywhere;
##   * the host raises threats (raise_threat, or bound to CombatWorld / CityProps / pushers), merges them (10 m, 0.25 s)
##     and sends at most 4 a second: "life.threat" {x, s, r, st, t}; every machine derives the reactions of people
##     (LifeCrowd) and vehicles (LifeFleet) from it;
##   * the machine that owns a shot tests it (sweep / blast, world space) and asks the host: "life.req" {id, dir, src} for a
##     person, "life.wreq" {id, dir, src, how, v0} for a vehicle; the host decides "life.down" {id, t, dir, src} and
##     "life.wreck" {id, t, x, s, yaw, tilt0, tilt1, roll, dir, v0, len, src}; a joiner gets "life.sync" {bytes}.
## Offline (no session) the same code decides locally. Transport through Session.send_event only.
## Drawing: LifeFigures and LifeCars (MultiMesh). Poses are sampled at 20 Hz in four staggered groups (each agent every
## 0.2 s, one sample ahead) and the transforms interpolated every frame.
##
## Signals for audio / HUD: civilian_killed(id, world_pos, src), civilian_event(kind, world_pos) with gasp, scream,
## run_steps, door_slam, whimper; vehicle_event(kind, world_pos) with brake, horn, hazard, doors, tip, alarm (all
## throttled); tally_changed().

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
		"brake": 0.5, "horn": 1.0, "hazard": 1.0, "doors": 0.5, "tip": 0.3, "alarm": 1.0}
const STEP_EVERY := 1.2       ## s between run_steps of one fleeing person
const CELL := 30.0            ## m, audio throttle cell
const BLINK_HZ := 1.5
const SHOT_PUSH := 3.0        ## m/s a shot nudges the vehicle it wrecks (before the vehicle's mass)
const BLAST_PUSH := 8.0
const PUSH_SHOVE := 1.0       ## a pusher shoves a vehicle at this times its speed

var district: CityDistrict
var plan: LifePlan
var crowd: LifeCrowd
var traffic: LifeTraffic
var fleet: LifeFleet
var figures: LifeFigures
var cars: LifeCars
var people := -1              ## the `people` param (-1: LifePlan.default_count)
var pods := -1                ## the `pods` / `carts` params (-1: by area)
var carts := -1
var now := 0.0                ## life clock: Session.host_time() online, local seconds offline
var time_scale := 1.0         ## offline clock speed (the lab)
var sent: Array = []          ## host: the last events it decided, [kind, data] (tests feed them to another instance)

var _ring: RingFrame
var _geo: CityGeo
var _online_clock := false
var _tick := -1               ## next logic tick index (-1: resample everything)
# people
var _ta := PackedFloat64Array()
var _tb := PackedFloat64Array()
var _xa: Array[Transform3D] = []
var _xb: Array[Transform3D] = []
var _mesh := PackedInt32Array()     ## pose mesh of sample A (-1 hidden)
var _vis_b := PackedByteArray()
var _state: Array[String] = []      ## state of sample A
var _last_b: Array = []             ## the last sample B per person (reused as the next sample A)
var _steps_at := PackedFloat64Array()
var _falling: Dictionary = {}       ## id -> true while tipping over (drawn exactly every frame)
var _px := PackedFloat32Array()     ## displayed arc x, s per person
var _ps := PackedFloat32Array()
var _pos := PackedVector3Array()    ## displayed feet, district-local
var _up := PackedVector3Array()
var _on := PackedByteArray()        ## 1: outdoors and alive (can be hit)
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
var _vbounds := AABB()
var _vany := false
# host and local bookkeeping
var _pending: Array = []            ## host: threats waiting to be sent [x, s, r, st]
var _recent: Array = []             ## host: [t, x, s, r, st] sent within MERGE_S
var _last_send := -INF
var _pushers: Array = []            ## [body, radius, src, last arc (Vector3), has_last, next proximity threat]
var _pusher_arc: Array[Vector2] = []
var _asked: Dictionary = {}
var _vasked: Dictionary = {}
var _heard: Dictionary = {}         ## "kind:cell" -> time of the last event of that kind there


func net_fields() -> Dictionary:
	return {
		"district": Net.SPAWN, "plan": Net.SPAWN, "traffic": Net.SPAWN, "people": Net.SPAWN, "pods": Net.SPAWN,
		"carts": Net.SPAWN,
		"crowd": Net.OWNER, "fleet": Net.OWNER,     # the host's events decide them on every machine
		"now": Net.LOCAL, "time_scale": Net.LOCAL, "figures": Net.LOCAL, "cars": Net.LOCAL,
		"sent": Net.PRIVATE, "_pending": Net.PRIVATE, "_recent": Net.PRIVATE, "_last_send": Net.PRIVATE,
		"_pushers": Net.PRIVATE, "_asked": Net.PRIVATE, "_vasked": Net.PRIVATE,
		"_ring": Net.LOCAL, "_geo": Net.LOCAL, "_online_clock": Net.LOCAL, "_tick": Net.LOCAL, "_ta": Net.LOCAL,
		"_tb": Net.LOCAL, "_xa": Net.LOCAL, "_xb": Net.LOCAL, "_mesh": Net.LOCAL, "_vis_b": Net.LOCAL, "_state": Net.LOCAL,
		"_last_b": Net.LOCAL, "_steps_at": Net.LOCAL, "_falling": Net.LOCAL, "_px": Net.LOCAL, "_ps": Net.LOCAL,
		"_pos": Net.LOCAL, "_up": Net.LOCAL, "_on": Net.LOCAL, "_bounds": Net.LOCAL, "_any_out": Net.LOCAL,
		"_vta": Net.LOCAL, "_vtb": Net.LOCAL, "_vxa": Net.LOCAL, "_vxb": Net.LOCAL, "_vhaz": Net.LOCAL, "_vstate": Net.LOCAL,
		"_vdoors": Net.LOCAL, "_vtip": Net.LOCAL, "_vpos": Net.LOCAL, "_vaxis": Net.LOCAL, "_vpx": Net.LOCAL,
		"_vps": Net.LOCAL, "_vdir": Net.LOCAL, "_von": Net.LOCAL, "_vbounds": Net.LOCAL, "_vany": Net.LOCAL,
		"_pusher_arc": Net.LOCAL, "_heard": Net.LOCAL,
	}


func _init() -> void:
	name = "AmbientLife"
	add_to_group("ambient_life")


func _ready() -> void:
	var s := Net.session()
	if s != null:
		s.event_received.connect(_on_event)
		s.peer_joined.connect(_on_peer_joined)


func _exit_tree() -> void:
	var s := Net.session()
	if s != null and s.event_received.is_connected(_on_event):
		s.event_received.disconnect(_on_event)
		s.peer_joined.disconnect(_on_peer_joined)


## Populate `d` (a built CityDistrict; this node may be its child or anywhere else). Counts < 0: the defaults.
func setup(d: CityDistrict, people_count: int = -1, pod_count: int = -1, cart_count: int = -1) -> void:
	district = d
	people = people_count
	pods = pod_count
	carts = cart_count
	_ring = d.ring
	_geo = CityGeo.new(_ring)
	plan = LifePlan.make(d.plan, people_count)
	crowd = LifeCrowd.new(plan)
	if figures == null:
		figures = LifeFigures.new()
		figures.top_level = true
		add_child(figures)
	if cars == null:
		cars = LifeCars.new()
		cars.top_level = true
		add_child(cars)
	figures.build(plan.people + plan.riders, _local_bounds())
	var n := plan.total()
	_ta.resize(n)
	_tb.resize(n)
	_xa.resize(n)
	_xb.resize(n)
	_mesh.resize(n)
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
	for i in n:
		_mesh[i] = -1
		_state[i] = "calm"
		_on[i] = 0
	_falling.clear()
	_pending.clear()
	_recent.clear()
	_asked.clear()
	_heard.clear()
	sent.clear()
	_last_send = -INF
	_online_clock = Net.online()
	now = _clock()
	_build_traffic()
	_tick = -1
	_follow()
	_redraw_exact(false)


func _build_traffic() -> void:
	traffic = LifeTraffic.make(plan, pods, carts)
	fleet = LifeFleet.new(traffic)
	cars.build(traffic.vehicles, _local_bounds())
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
	for i in m:
		_vstate[i] = "driving"
		_vdoors[i] = -INF
	_vtip.clear()
	_vasked.clear()


## Change the number of people (rebuilds the plan; forgets every threat, kill and wreck).
func set_people(n: int) -> void:
	if district != null:
		setup(district, n, pods, carts)


## Change the number of pods and carts (forgets every vehicle event; the people keep theirs).
func set_vehicles(pod_count: int, cart_count: int) -> void:
	pods = pod_count
	carts = cart_count
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
	if figures != null and figures.is_inside_tree():
		figures.global_transform = district.global_transform
	if cars != null and cars.is_inside_tree():
		cars.global_transform = district.global_transform


func _to_world() -> Transform3D:
	return district.global_transform if district != null and district.is_inside_tree() else Transform3D.IDENTITY


# --- Clock -----------------------------------------------------------------------------------------------

func _clock() -> float:
	var s := Net.session()
	if s != null and s.online():
		return s.host_time()
	return now


func _process(delta: float) -> void:
	if plan == null:
		return
	var online := Net.online()
	if online != _online_clock:
		_online_clock = online
		_rebase(_clock())
	now = _clock() if online else now + delta * time_scale
	_flush()
	_pusher_step(delta * (1.0 if online else time_scale))
	_advance_draw()


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
	for vid: int in fleet.wrecks:
		var e: Dictionary = fleet.wrecks[vid]
		e["t0"] = t - 10.0
		e["since"] = t - 10.0
	fleet.rebuild_obstacles(t, crowd)
	now = t
	_tick = -1


## Move the clock to `t` and draw everyone exactly there (tests drive time with this, never frames).
func advance_to(t: float) -> void:
	var dt := maxf(t - now, 0.0)
	now = t
	_flush()
	_pusher_step(dt)
	_tick = -1
	_redraw_exact(true)


# --- Sampling and drawing ----------------------------------------------------------------------------------

## [transform (district-local, unscaled), pose mesh (-1 hidden), state, arc x, s, h, tipping]
func _sample(id: int, t: float) -> Array:
	var p := crowd.pose(id, t)
	var frame := _geo.frame(float(p["x"]), float(p["s"]), float(p["h"]))
	var state := str(p["state"])
	if not p["visible"]:
		return [frame, -1, state, p["x"], p["s"], p["h"], false]
	var mode := str(p["mode"])
	if mode == "down":
		var f := float(p["tip"])
		var xf := LifeFigures.tip(frame, Vector3(float(p["dx"]), 0.0, float(p["ds"])), f, float(p["heading"]))
		return [xf, LifeFigures.IDLE, state, p["x"], p["s"], p["h"], f < 1.0]
	var xf := Transform3D(frame.basis * Basis(Vector3.UP, float(p["heading"])), frame.origin)
	var mesh := LifeFigures.IDLE
	match mode:
		"walk": mesh = LifeFigures.WALK_A if int(float(p["dist"]) / 0.75) % 2 == 0 else LifeFigures.WALK_B
		"run": mesh = LifeFigures.RUN_A if int(float(p["dist"]) / 1.4) % 2 == 0 else LifeFigures.RUN_B
		"sit": mesh = LifeFigures.SIT
		"wary": mesh = LifeFigures.WARY
		"cower":
			mesh = LifeFigures.COWER
			if _hands_up(Vector2(p["x"], p["s"]), t):
				mesh = LifeFigures.HANDS
				state = "hands_up"
	return [xf, mesh, state, p["x"], p["s"], p["h"], false]


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
		_set_samples(id, target - posmod(target - id % GROUPS, GROUPS), false)
	for vid in traffic.count():
		_set_vsamples(vid, target - posmod(target - vid % GROUPS, GROUPS), false)
	_tick = target + 1


func _do_tick(k: int) -> void:
	var g := posmod(k, GROUPS)
	var id := g
	while id < plan.total():
		_set_samples(id, k, true)
		id += GROUPS
	var vid := g
	while vid < traffic.count():
		_set_vsamples(vid, k, true)
		vid += GROUPS


## Sample A at tick k, sample B one period later. `events`: emit what changed since the last sample A.
func _set_samples(id: int, k: int, events: bool) -> void:
	var ta := float(k) * TICK
	var tb := float(k + GROUPS) * TICK
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
	_mesh[id] = int(a[1])
	_vis_b[id] = 1 if int(b[1]) >= 0 else 0
	_state[id] = str(a[2])
	if bool(a[6]):
		_falling[id] = true


func _set_vsamples(vid: int, k: int, events: bool) -> void:
	var ta := float(k) * TICK
	var tb := float(k + GROUPS) * TICK
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
	for id in plan.total():
		if _falling.has(id):
			var e := _sample(id, now)
			figures.show_pose(id, int(e[1]), e[0])
			_px[id] = e[3]
			_ps[id] = e[4]
			_pos[id] = (e[0] as Transform3D).origin
			_up[id] = (e[0] as Transform3D).basis.y.normalized()
			_on[id] = 0
			if not bool(e[6]):
				_falling.erase(id)
			continue
		var mesh := _mesh[id]
		if mesh < 0:
			figures.hide_person(id)
			_on[id] = 0
			continue
		var xf: Transform3D = _xa[id]
		if _vis_b[id] == 1:
			var f := clampf((now - _ta[id]) / maxf(_tb[id] - _ta[id], 1e-6), 0.0, 1.0)
			if not _xa[id].is_equal_approx(_xb[id]):
				xf = _xa[id].interpolate_with(_xb[id], f)
		figures.show_pose(id, mesh, xf)
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
		cars.show_vehicle(vid, (LifeCars.HAZARD_BRIGHT if blink else LifeCars.HAZARD_DARK) if haz else LifeCars.PLAIN, xf)
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


## Everyone drawn exactly at `now` (tests, setup, after an event).
func _redraw_exact(events: bool) -> void:
	_follow()
	var first := true
	_any_out = false
	for id in plan.total():
		var e := _sample(id, now)
		if events:
			_transition(id, _state[id], str(e[2]), e, now)
		_state[id] = str(e[2])
		_ta[id] = now
		_tb[id] = now
		_xa[id] = e[0]
		_xb[id] = e[0]
		_mesh[id] = int(e[1])
		_vis_b[id] = 0
		_last_b[id] = null
		if bool(e[6]):
			_falling[id] = true
		else:
			_falling.erase(id)
		if int(e[1]) < 0:
			figures.hide_person(id)
			_on[id] = 0
			continue
		figures.show_pose(id, int(e[1]), e[0])
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
		if bool(e[5]):
			_vtip[vid] = true
		else:
			_vtip.erase(vid)
		cars.show_vehicle(vid, (LifeCars.HAZARD_BRIGHT if blink else LifeCars.HAZARD_DARK) if bool(e[1]) else LifeCars.PLAIN, e[0])
		_vstore(vid, e[0])
		_vbounds = AABB(_vpos[vid], Vector3.ZERO) if vfirst else _vbounds.expand(_vpos[vid])
		vfirst = false
		_vany = true
	if _vany:
		_vbounds = _vbounds.grow(2.5)


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
	return str(_sample(id, now)[2])


## The person's transform in world space now (exact, not interpolated; feet at the origin, facing local +Z).
func pose_of(id: int) -> Transform3D:
	return _to_world() * (_sample(id, now)[0] as Transform3D)


## Whether person `id` is outdoors (drawn) now.
func visible_now(id: int) -> bool:
	return int(_sample(id, now)[1]) >= 0


## People (timetabled ones, then the pod riders: drawn only once a pod lets them out).
func count() -> int:
	return plan.total() if plan != null else 0


func vehicle_count() -> int:
	return traffic.count() if traffic != null else 0


## driving | stopped | dwell | docked | estop | fleeing | abandoned | wreck, at the current clock time.
func vehicle_state(id: int) -> String:
	return fleet.state_of(id, now)


## The vehicle's transform in world space now (exact; on the road, nose along local +Z).
func vehicle_pose(id: int) -> Transform3D:
	return _to_world() * (_vsample(id, now)[0] as Transform3D)


func vehicle_kind(id: int) -> String:
	return str(traffic.vehicles[id]["kind"])


## {killed_by_players, killed_by_enemies, by_src: {src: n}, dead (figures down), occupants_killed (inside pods, no
## figures; also counted in the first three), wrecks}
func tally() -> Dictionary:
	var t := crowd.tally()
	t["wrecks"] = fleet.wrecks.size() if fleet != null else 0
	return t


# --- Threats (host) ------------------------------------------------------------------------------------------

func _decides() -> bool:
	var s := Net.session()
	return s == null or not s.online() or s.is_host()


## Host only (a client's call does nothing): a threat at `world_point`. Merged with any within MERGE_R m and MERGE_S s,
## and at most 4 events a second leave.
func raise_threat(world_point: Vector3, radius: float, strength: int) -> void:
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
	var s := Net.session()
	if s != null and s.online():
		s.send_event(0, "life.threat", ev)


## Apply a decided threat event (the host's own, or one from the host): people first, then vehicles (whose riders join
## the people).
func _apply_threat(ev: Dictionary) -> void:
	crowd.apply_threat(ev)
	fleet.apply_threat(ev, crowd)
	_tick = -1


func _log(kind: String, data: Dictionary) -> void:
	sent.append([kind, data.duplicate()])
	if sent.size() > 256:
		sent.pop_front()


## Apply one event as the host decided it ("life.threat", "life.down" or "life.wreck"): what a client does on receipt,
## and what a test does to feed a second instance.
func apply_event(kind: String, data: Dictionary) -> void:
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
## wrecked (asked of the host on a client). Returns how many people and vehicles were hit; the shot is not changed.
## Cheap when nobody is near: two bounds tests, no allocation.
func sweep(a: Vector3, b: Vector3, r: float, src: int) -> int:
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
		for id in plan.total():
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
## its side). Returns how many people and vehicles were hit.
func blast(point: Vector3, radius: float, src: int) -> int:
	if plan == null or radius <= 0.0 or (not _any_out and not _vany):
		return 0
	var lp := _to_world().affine_inverse() * point
	var n := 0
	if _any_out and AABB(lp, Vector3.ZERO).grow(radius + HEIGHT).intersects(_bounds):
		for id in plan.total():
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
			var c := _vpos[vid]            # (wrecks too: a blast shoves them)
			var near := Geometry3D.get_closest_point_to_segment(lp, c - _vaxis[vid], c + _vaxis[vid])
			var rad := float((LifeTraffic.SIZE[traffic.vehicles[vid]["kind"]] as Vector3).x) * 0.5
			if near.distance_to(lp) > radius + rad:
				continue
			if _request_wreck(vid, _deck_dir(_vps[vid], c - lp), src, 1, BLAST_PUSH):
				n += 1
	return n


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
		s.send_event(1, "life.req", {"id": id, "dir": dir, "src": src})
		return true
	return _decide_down(id, dir, src)


## Host: kill `id` now if it is outdoors and alive, and tell the crew.
func _decide_down(id: int, dir: Vector2, src: int) -> bool:
	now = _clock() if Net.online() else now
	if not _down(id, now, dir, src, false):
		return false
	var ev := {"id": id, "t": now, "dir": dir, "src": src}
	_log("life.down", ev)
	var s := Net.session()
	if s != null and s.online():
		s.send_event(0, "life.down", ev)
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
		s.send_event(1, "life.wreq", {"id": vid, "dir": dir, "src": src, "how": how, "v0": v0})
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
	var s := Net.session()
	if s != null and s.online():
		s.send_event(0, "life.wreck", ev)
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
func add_pusher(body: Node3D, radius: float = 1.0, src: int = 0) -> void:
	for p: Array in _pushers:
		if p[0] == body:
			p[1] = radius
			p[2] = src
			return
	_pushers.append([body, radius, src, Vector3.ZERO, false, -INF])


func remove_pusher(body: Node3D) -> void:
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


## Threats from street props going down (15 m, strength 1).
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

## What differs from the timetables (for a joiner): the people's snapshot, then the vehicles'.
func snapshot() -> PackedByteArray:
	var a := crowd.snapshot(now)
	var buf := StreamPeerBuffer.new()
	buf.put_u32(a.size())
	buf.put_data(a)
	buf.put_data(fleet.snapshot())
	return buf.data_array


func restore(bytes: PackedByteArray) -> void:
	if bytes.size() >= 4:
		var buf := StreamPeerBuffer.new()
		buf.data_array = bytes
		var n := buf.get_u32()
		crowd.restore(bytes.slice(4, 4 + n))
		fleet.restore(bytes.slice(4 + n))
	else:
		crowd.restore(PackedByteArray())
		fleet.restore(PackedByteArray())
	_asked.clear()
	_vasked.clear()
	_falling.clear()
	_vtip.clear()
	for i in _vdoors.size():
		_vdoors[i] = -INF
	_tick = -1
	_redraw_exact(false)
	tally_changed.emit()


func _on_event(_from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if plan == null or not kind.begins_with("life."):
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
	if s != null and s.is_host() and plan != null:
		s.send_event(peer, "life.sync", {"bytes": snapshot()})
