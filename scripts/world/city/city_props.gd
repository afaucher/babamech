class_name CityProps
extends Node3D
## The district's loose street props (docs/design/city-props.md): trees, lamps, signal poles, sign posts, benches and bins
## that mechs and weapons knock over and then shove about. Host-arbitrated world objects with stable ids (the layout
## index): any machine may REQUEST a topple or a shove, the host decides and stamps it with the shared clock, and every
## machine then plays the same closed-form motion (CityPropSim) from that start time. Props never block a mech.
##
## Verbs:
##   first_hit(a, b, r)               the first prop on a swept segment (a shot), {id, frac, point, normal} or {}
##   apply_impulse(id, dv, src)       a weapon's knockback: topples a standing prop at its threshold, shoves a fallen one
##   blast(point, radius, dv, src)    splash knockback, falling off with distance
##   add_pusher(body, radius)         a mover (reads global_position, velocity) that topples and shoves what it touches
##   request(id, kind, dir, v0)       ask for a topple or a shove (what the verbs and pushers call)
## Wire (through Session only): client -> host "prop.req", host -> crew "prop.ev", host -> joiner "prop.sync" (snapshot).
## Each payload carries "deck" (this node's `deck`; -1 stand-alone, absent counts as -1): in a stack every deck's props
## hear every event and act only on their own deck's.
## Drawing: one MultiMeshInstance3D per prop shape; only moving props have their instance rewritten each frame.
## Roof units (docs/design/city-rooftops.md): water tanks, AC units, vents and roof planters stand on building roofs.
## Such an item has `building` >= 0 (street props: absent or -1), `tier`, and its spot (lx, ly, lz) in that building's
## flat frame (CityPropLayout.building_xf, the same as CityDistrict.building_frame); its x / s / h are that spot in arc coordinates
## (for quick distance checks). Its poses and event directions are in the roof plane (CityPropSim): it stays at the
## roof's height, slides only inside its tier and round what stands on it, and stops at the roof's edge.

const TYPES := CityPropSim.TYPES
const STANDING := CityPropSim.STANDING
const FALLING := CityPropSim.FALLING
const DOWN := CityPropSim.DOWN
const SLIDING := CityPropSim.SLIDING
const TOPPLE := CityPropSim.TOPPLE
const SHOVE := CityPropSim.SHOVE

const PUSH_MIN_SPEED := 0.5    ## a pusher slower than this topples nothing
const PUSH_SHOVE := 0.5        ## a pusher shoves a fallen prop at this times its speed
const PUSH_HEIGHT := 6.0       ## a pusher only reaches props within this height of its feet
const ASK_EVERY := 0.25        ## at most one request per prop per this long
const SCAN_EVERY := 1.0        ## re-scan for CharacterBody3Ds this often (when nobody registered a pusher)
const GRID_CELL := 16.0        ## m spatial-hash cell size for fast first_hit / blast queries
const ARC_CELL := 8.0          ## m cell of the rest-position grid a pusher queries (arc x, s of every item)
const MAX_PROP_HALF := 7.5     ## m conservative upper bound on any prop's half-height + radius
const ROOF_TOL := 0.3          ## a pusher reaches a roof prop when [feet, feet + PUSH_HEIGHT] meets the prop's height span

signal prop_moved(id: int, type: String, kind: int, world_pos: Vector3, speed: float)

var items: Array = []           ## CityPropLayout.layout(plan): [{id, type, x, s, h, yaw, scale, variant, pit}] (+ roof fields)
var plan: CityPlan
var ring: RingFrame
var deck := -1                  ## the stack deck these props are on (CityDistrict.build_deck); -1 = a district on its own.
                                ## Every prop.req / prop.ev / prop.sync carries it, and events for another deck are ignored.
var now := 0.0                  ## prop clock: the session's host_time() online, local seconds offline

var _ev: Dictionary = {}        ## id -> the prop's last event (absent: standing)
var _moving: Dictionary = {}    ## id -> clock time its motion ends
var _slot: Array = []           ## id -> [multimesh index, instance index]
var _mms: Array[MultiMesh] = []
var _proto_tris: Array[int] = []
var _geo: CityGeo
var _floors: Array = []
var _pushers: Array = []        ## [[body, radius]] registered with add_pusher
var _found: Array = []          ## [[body, radius]] found by scanning, used while nobody registered one
var _scan_in := 0.0
var _last_pos: Dictionary = {}  ## pusher instance id -> last arc position (for bodies without a velocity)
var _asked: Dictionary = {}     ## id -> clock time of this machine's last request about it
var _online_clock := false
var _cap_local: Array = []      ## id -> [foot, head, radius, mid, half] in local space (updated only when prop draws)
var _grid: Dictionary = {}      ## Vector2i cell -> Array[int] prop ids
var _prop_cell: Array = []      ## id -> Vector2i cell currently indexed in _grid
var _arc_grid: Dictionary = {}  ## Vector2i(x, s cell) -> ids (ascending) whose rest position (item x, s) is in it
var _reach_pad := 0.0           ## the largest prop radius: a pusher's query reaches its radius + this
var brute_force := false        ## tests only: _push checks every prop, as before the grid (tests/test_city_props.gd)
var _bxf: Array = []            ## building index -> its flat frame (Transform3D) in this node's space
var _bxf_inv: Array = []        ## and its inverse
var _tints: Dictionary = {}     ## id -> its instance tint (tree / planter: CityProps.tree_tint), what its MultiMesh carries
var _rest_xs: Dictionary = {}   ## id -> [event, motion end, rest base Vector2(x, s)] of a moved deck prop (_settled_out_of_reach)
var station: Dictionary = {}    ## CityStation.of(plan): the tram station on a section's top deck ({} elsewhere); its
                                ## platform, wall and name board are the child "Station", its lamps and benches are items


func net_fields() -> Dictionary:
	return {
		"items": Net.SPAWN,          # from the plan's props seed, the same on every machine (CityPropLayout.checksum, in CityStack.checksum)
		"plan": Net.SPAWN, "ring": Net.SPAWN,
		"deck": Net.SPAWN,           # from the section plan's deck index, the same on every machine
		"_ev": Net.OWNER,            # the host decides every event; the crew receives them (prop.ev, prop.sync)
		"now": Net.LOCAL,            # the shared clock where there is one
		"_moving": Net.LOCAL, "_slot": Net.LOCAL, "_mms": Net.LOCAL, "_proto_tris": Net.LOCAL, "_geo": Net.LOCAL,
		"_floors": Net.LOCAL, "_online_clock": Net.LOCAL,
		"_cap_local": Net.LOCAL, "_grid": Net.LOCAL, "_prop_cell": Net.LOCAL,
		"_arc_grid": Net.LOCAL, "_reach_pad": Net.LOCAL, "brute_force": Net.LOCAL,   # from the layout / a test switch
		"_bxf": Net.LOCAL, "_bxf_inv": Net.LOCAL,      # from the plan and the ring, the same on every machine
		"_tints": Net.LOCAL,         # looks: from the plan's cosmetic seed and the prop id, the same on every machine
		"_pushers": Net.PRIVATE, "_found": Net.PRIVATE, "_scan_in": Net.PRIVATE, "_last_pos": Net.PRIVATE,
		"_asked": Net.PRIVATE,
		"_rest_xs": Net.LOCAL,       # perf cache derived from _ev (_settled_out_of_reach)
		"station": Net.SPAWN,        # from the plan, the same on every machine (its lamps / benches are in the layout checksum)
	}


func _init() -> void:
	name = "Props"
	add_to_group("city_props")


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


# --- Setup and drawing -----------------------------------------------------------------------------------

## The shapes: one per type, trees one per leaf colouring. Each is [type, variant].
static func _shapes() -> Array:
	var out: Array = []
	for v in CityStreets.TREE_LEAVES.size():
		out.append(["tree", v])
	for t: String in ["lamp", "signal", "sign", "bench", "bin"]:
		out.append([t, 0])
	for v in CityBuildings.TANK_COLOURS.size():
		out.append(["water_tank", v])
	for t: String in ["planter", "ac", "vent"]:
		out.append([t, 0])
	return out


static func _proto(type: String, variant: int) -> CityGeo:
	var geo := CityGeo.new()
	var xf := Transform3D.IDENTITY
	match type:
		"tree": CityStreets.tree(geo, xf, variant)
		"lamp": CityStreets.lamp(geo, xf)
		"signal": CityStreets.signal_pole(geo, xf)
		"sign": CityStreets.sign_post(geo, xf)
		"bench": CityStreets.bench(geo, xf)
		"bin": CityStreets.bin(geo, xf)
		"water_tank", "planter", "ac", "vent": CityBuildings.roof_unit(geo, xf, type, variant)
	return geo


## Lays the props out for `p` on `r`, standing, and builds their meshes. Forgets every event.
func setup(p: CityPlan, r: RingFrame) -> void:
	plan = p
	ring = r
	_geo = CityGeo.new(r)
	_floors = CityPropSim.floor_rects(p)
	items = CityPropLayout.layout(p)
	_bxf.clear()
	_bxf_inv.clear()
	for i in p.buildings.size():
		var xf := CityPropLayout.building_xf(r, p, i)
		_bxf.append(xf)
		_bxf_inv.append(xf.affine_inverse())
	_ev.clear()
	_moving.clear()
	_asked.clear()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_mms.clear()
	_proto_tris.clear()
	_tints.clear()
	_grid.clear()
	_arc_grid.clear()
	_reach_pad = 0.0
	for it: Dictionary in items:
		var cell := Vector2i(int(floor(float(it["x"]) / ARC_CELL)), int(floor(float(it["s"]) / ARC_CELL)))
		if not _arc_grid.has(cell):
			_arc_grid[cell] = []
		(_arc_grid[cell] as Array).append(int(it["id"]))
		_reach_pad = maxf(_reach_pad, float(TYPES[it["type"]]["radius"]))
	_cap_local.resize(items.size())
	_prop_cell.resize(items.size())
	for i in items.size():
		_cap_local[i] = null
		_prop_cell[i] = null
	var shapes := _shapes()
	var members: Array = []
	for sh: Array in shapes:
		members.append([])
	_slot.resize(items.size())
	for it: Dictionary in items:
		var k := 0
		for j in shapes.size():
			if shapes[j][0] == it["type"] and int(shapes[j][1]) == int(it["variant"]):
				k = j
		_slot[int(it["id"])] = [k, (members[k] as Array).size()]
		(members[k] as Array).append(int(it["id"]))
	for k in shapes.size():
		var geo := _proto(str(shapes[k][0]), int(shapes[k][1]))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var tinted := TINTED.has(str(shapes[k][0]))
		mm.use_custom_data = tinted       # the tree's own leaf tint (CityPalette.tree_material), set once below
		mm.mesh = geo.commit(CityPalette.tree_material() if tinted else CityPalette.surface_material())
		mm.instance_count = (members[k] as Array).size()
		if tinted:
			var seed := plan.cosmetic_seed()
			for j in mm.instance_count:
				var tid := int(members[k][j])
				_tints[tid] = tree_tint(seed, tid)
				mm.set_instance_custom_data(j, _tints[tid])
		var mi := MultiMeshInstance3D.new()
		mi.name = "%s%d" % [shapes[k][0], shapes[k][1]]
		mi.multimesh = mm
		add_child(mi)
		_mms.append(mm)
		_proto_tris.append(geo.tri_count())
	for it: Dictionary in items:
		_draw(int(it["id"]))
	# The tram station's platform, low wall and name board (static, solid; not in tri_count: CityDistrict's stats and
	# digest stay what they were). Render layers: CityDistrict sets them on every mesh under the props before add_child.
	station = CityStation.of(p)
	var sn := CityStation.build_node(station, r)
	if sn != null:
		add_child(sn)
	_online_clock = Net.online()
	now = Net.world_time(now)


## Prop types drawn with their own leaf tint (CityPalette.tree_material): trees and planters.
const TINTED := ["tree", "planter"]


## Prop `id`'s jitter u in [-1, 1]^3 and the trunk's w (CityPalette.tree_tint / tree_multiplier), from its OWN generator
## seeded from the plan's cosmetic seed and the id: no shared stream is drawn, so no other look or the layout moves, and
## every machine (and every state of the prop: standing, falling, down, sliding) has the same shade.
static func tree_jitter(cosmetic_seed: int, id: int) -> Vector4:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([cosmetic_seed, 0x7EE5, id])
	return Vector4(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))


## Prop `id`'s instance tint (MultiMesh custom data): CityPalette.tree_multiplier of its jitter.
static func tree_tint(cosmetic_seed: int, id: int) -> Color:
	var j := tree_jitter(cosmetic_seed, id)
	return CityPalette.tree_multiplier(Vector3(j.x, j.y, j.z), j.w)


## The tint prop `id`'s instance is drawn with (Color(1, 1, 1, 1) for an untinted type). Kept beside the MultiMesh: a
## headless (dummy) renderer does not read custom data back.
func tint_of(id: int) -> Color:
	return _tints.get(id, Color(1, 1, 1, 1))


## Triangles drawn by every instance together.
func tri_count() -> int:
	var n := 0
	for k in _mms.size():
		n += _proto_tris[k] * _mms[k].instance_count
	return n


func _draw(id: int) -> void:
	var slot: Array = _slot[id]
	var xf := transform_of(id)
	_mms[int(slot[0])].set_instance_transform(int(slot[1]), xf)
	_update_capsule_cache(id, xf)


func _update_capsule_cache(id: int, xf: Transform3D) -> void:
	var it: Dictionary = items[id]
	var spec: Dictionary = TYPES[it["type"]]
	var foot := xf.origin
	var head := xf * Vector3(0.0, float(spec["height"]), 0.0)
	var rad := float(spec["radius"])
	var mid := (foot + head) * 0.5
	var half := foot.distance_to(head) * 0.5 + rad
	_cap_local[id] = [foot, head, rad, mid, half]
	var cell := Vector2i(int(floor(mid.x / GRID_CELL)), int(floor(mid.z / GRID_CELL)))
	var prev: Variant = _prop_cell[id]
	if prev != null and prev is Vector2i and (prev as Vector2i) == cell:
		return
	if prev != null and prev is Vector2i and _grid.has(prev):
		(_grid[prev] as Array).erase(id)
	if not _grid.has(cell):
		_grid[cell] = []
	(_grid[cell] as Array).append(id)
	_prop_cell[id] = cell


## The prop's transform in this node's space: upright on the floor facet under its base, leaning along its lie.
func transform_of(id: int) -> Transform3D:
	var it: Dictionary = items[id]
	var p := pose_of(id)
	var base: Transform3D
	if CityPropSim.is_roof(it):      # flat on its roof, in the building's frame
		base = (_bxf[int(it["building"])] as Transform3D) * Transform3D(Basis.IDENTITY, Vector3(p["x"], float(it["ly"]), p["s"]))
	else:
		base = _geo.frame(p["x"], p["s"], p["h"])
	var lean := Basis.IDENTITY
	if float(p["tilt"]) > 1e-5:
		var d := CityPropSim.dir_of(p["lie"])
		lean = Basis(Vector3.UP.cross(Vector3(d.x, 0.0, d.y)).normalized(), p["tilt"])
	var turn := Basis(Vector3.UP, float(it["yaw"]) + float(p["spin"])).scaled(Vector3.ONE * float(it["scale"]))
	return base * Transform3D(lean * turn, Vector3.ZERO)


# --- State -----------------------------------------------------------------------------------------------

func state_of(id: int) -> int:
	return CityPropSim.state_at(_ev.get(id), str(items[id]["type"]), now)


## {x, s, h, lie, tilt, spin} at the current clock time; h is the floor under the base (the layout's while standing).
func pose_of(id: int) -> Dictionary:
	var it: Dictionary = items[id]
	if not _ev.has(id):
		var st := CityPropSim.standing(it)
		st["h"] = float(it["h"])
		return st
	var ev: Dictionary = _ev[id]
	var age := now - float(ev.get("t0", 0.0))
	var p := CityPropSim.pose_at(ev, it, age)
	if CityPropSim.is_roof(it):      # x / s in its building's frame; it never leaves its roof
		p["h"] = float(it["h"])
	else:
		p["h"] = CityPropSim.floor_at(_floors, p["x"], p["s"])
	return p


func _rest_pose(id: int) -> Dictionary:
	if not _ev.has(id):
		return CityPropSim.standing(items[id])
	return CityPropSim.end_pose(_ev[id], items[id])


## Move the clock to `t` and redraw whatever is moving (tests drive time with this instead of frames).
func advance_to(t: float) -> void:
	now = t
	_refresh()


func _refresh() -> void:
	for id: int in _moving.keys():
		_draw(id)
		if now >= float(_moving[id]):
			_moving.erase(id)


func _physics_process(delta: float) -> void:
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	step(delta)
	if PerfProbe.on:
		PerfProbe.add("main.city_props", Time.get_ticks_usec() - pp0)


## One physics step: advance the clock, let this machine's pushers touch props, redraw what moves.
func step(delta: float) -> void:
	if items.is_empty():
		return
	var online := Net.online()
	if online != _online_clock:
		# The clock source changed (a session began or ended): settle every motion at rest on the new clock.
		_online_clock = online
		var keep := snapshot()
		now = Net.world_time(now)
		restore(keep)
	now = Net.world_time(now) if online else now + delta
	_contacts(delta)
	_refresh()


# --- Events ----------------------------------------------------------------------------------------------

## Ask for a topple (kind TOPPLE) or a shove (SHOVE, at speed v0 before the mass) of prop `id` along `dir` (deck plane).
## The host (or an offline game) decides at once; a client sends the request to the host.
func request(id: int, kind: int, dir: Vector2, v0: float = 0.0) -> void:
	if id < 0 or id >= items.size() or dir.length_squared() < 1e-8:
		return
	var s := Net.session()
	if s != null and s.is_client():
		s.send_event(1, "prop.req", {"id": id, "kind": kind, "dir": dir.normalized(), "v0": v0, "deck": deck})
		return
	_decide(id, kind, dir.normalized(), v0)


## Host: a standing prop topples, a prop at rest is shoved; anything mid-motion ignores the request.
func _decide(id: int, kind: int, dir: Vector2, v0: float) -> void:
	now = Net.world_time(now)
	var type := str(items[id]["type"])
	var state := state_of(id)
	var ev := {}
	if kind == TOPPLE and state == STANDING:
		ev = {"id": id, "kind": TOPPLE, "dir": dir, "t0": now}
	elif kind == SHOVE and state == DOWN:
		var speed := CityPropSim.shove_speed(type, v0)
		if speed <= 0.0:
			return
		var from := _rest_pose(id)
		var want := speed * speed / (2.0 * CityPropSim.FRICTION)
		var length := 0.0
		var it: Dictionary = items[id]
		if CityPropSim.is_roof(it):      # across its roof, round what stands on it, stopping at the edge
			var bi := int(it["building"])
			var ti := int(it["tier"])
			length = CityPropSim.slide_in(plan.roof_rect(bi, ti), plan.roof_blockers(bi, ti), Vector2(from["x"], from["s"]), dir,
					want, float(TYPES[type]["radius"]))
		else:
			length = CityPropSim.slide_length(plan, Vector2(from["x"], from["s"]), dir, want, float(TYPES[type]["radius"]))
		ev = {"id": id, "kind": SHOVE, "dir": dir, "v0": speed, "len": length, "from": from, "t0": now}
	else:
		return
	apply_event(ev)
	var s := Net.session()
	if s != null and s.online():
		s.send_event(0, "prop.ev", ev.merged({"deck": deck}))


## Play a decided event (the host's own, or one received from it). A late one fast-forwards.
func apply_event(ev: Dictionary) -> void:
	var id := int(ev.get("id", -1))
	if id < 0 or id >= items.size():
		return
	_ev[id] = ev
	var kind := int(ev.get("kind", -1))
	_moving[id] = float(ev.get("t0", 0.0)) + CityPropSim.duration(ev, str(items[id]["type"]))
	_draw(id)
	if (kind == TOPPLE or kind == SHOVE) and absf(now - float(ev.get("t0", now))) < 0.25:
		var xf := global_transform * transform_of(id) if is_inside_tree() else transform_of(id)
		prop_moved.emit(id, str(items[id]["type"]), kind, xf.origin, float(ev.get("v0", 0.0)))


## Every prop that is not standing: id and its rest pose (anything still moving is written where it will stop).
func snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	var ids := _ev.keys()
	ids.sort()
	buf.put_u32(ids.size())
	for id: int in ids:
		var p := _rest_pose(id)
		buf.put_u32(id)
		for k: String in ["x", "s", "lie", "tilt", "spin"]:
			buf.put_float(float(p[k]))
	return buf.data_array


## Bytes per prop in snapshot(): its id (u32) and five floats.
const SNAP_REC := 4 + 5 * 4


## Every prop as `bytes` says (an empty snapshot stands them all up again). The bytes come from a peer (prop.sync), so
## they are checked before anything is believed: the count may not exceed this machine's own layout nor the records the
## buffer actually holds (its size must be exactly 4 + count records), every id must be one of this layout's props and
## every float finite. A malformed buffer is rejected as a whole (a warning, every prop stood up) without reading past
## its end or looping or allocating by the peer's number (valid_snapshot).
func restore(bytes: PackedByteArray) -> void:
	var touched := _ev.keys()
	_ev.clear()
	_moving.clear()
	_asked.clear()
	if bytes.size() >= 4:
		if not valid_snapshot(bytes, items.size()):
			push_warning("CityProps.restore: malformed prop snapshot (%d bytes, %d props here): ignored" % [bytes.size(), items.size()])
		else:
			var buf := StreamPeerBuffer.new()
			buf.data_array = bytes
			var n := buf.get_u32()
			for i in n:
				var id := buf.get_u32()
				var pose := {}
				for k: String in ["x", "s", "lie", "tilt", "spin"]:
					pose[k] = buf.get_float()
				_ev[id] = {"id": id, "kind": CityPropSim.REST, "pose": pose, "t0": now}
	for id: int in touched + _ev.keys():
		_draw(id)


## True when `bytes` is a well-formed snapshot() for a layout of `count` props: a u32 record count no larger than
## `count`, exactly that many SNAP_REC records after it, every id below `count` and every float finite.
static func valid_snapshot(bytes: PackedByteArray, count: int) -> bool:
	if bytes.size() < 4:
		return false
	var n := bytes.decode_u32(0)
	if n > count or bytes.size() != 4 + n * SNAP_REC:
		return false
	for i in n:
		var o := 4 + i * SNAP_REC
		if bytes.decode_u32(o) >= count:
			return false
		for k in 5:
			var f := bytes.decode_float(o + 4 + k * 4)
			if is_nan(f) or is_inf(f):
				return false
	return true


func _on_event(_from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	var s := Net.session()
	receive(kind, data, s != null and s.is_host(), s != null and s.is_client())


## True if a prop event's payload is for this node's deck (a missing "deck" counts as -1: a district on its own).
func for_me(data: Dictionary) -> bool:
	return int(data.get("deck", -1)) == deck


## One prop event as this machine plays it (`host` / `client`: its role; split from the Session hook so tests can drive
## it in-process). Events for another deck are ignored: in a stack every deck's props hear every prop event.
func receive(kind: String, data: Dictionary, host: bool, client: bool) -> void:
	if items.is_empty() or not kind.begins_with("prop.") or not for_me(data):
		return
	match kind:
		"prop.req":
			var id := int(data.get("id", -1))
			var dir: Variant = data.get("dir")
			if host and id >= 0 and id < items.size() and dir is Vector2 and (dir as Vector2).length_squared() > 1e-8:
				_decide(id, int(data.get("kind", -1)), (dir as Vector2).normalized(), float(data.get("v0", 0.0)))
		"prop.ev":
			if client:
				apply_event(data)
		"prop.sync":
			var b: Variant = data.get("bytes", PackedByteArray())
			if client and b is PackedByteArray:
				restore(b)


func _on_peer_joined(peer: int) -> void:
	var s := Net.session()
	if s != null and s.is_host() and not items.is_empty():
		s.send_event(peer, "prop.sync", {"bytes": snapshot(), "deck": deck})


# --- Weapons ---------------------------------------------------------------------------------------------

## The prop's hit capsule in world space: [foot, head, radius].
func _capsule(id: int) -> Array:
	var it: Dictionary = items[id]
	var xf := global_transform * transform_of(id) if is_inside_tree() else transform_of(id)
	var foot := xf.origin
	var head := xf * Vector3(0.0, float(TYPES[it["type"]]["height"]), 0.0)
	return [foot, head, float(TYPES[it["type"]]["radius"])]


## The first prop a sphere of radius `r` meets moving from `a` to `b` (world space): {id, frac, point, normal}, or {}.
func first_hit(a: Vector3, b: Vector3, r: float) -> Dictionary:
	var best := {}
	var has_xf := is_inside_tree() and global_transform != Transform3D.IDENTITY
	var la := global_transform.affine_inverse() * a if has_xf else a
	var lb := global_transform.affine_inverse() * b if has_xf else b
	var seg := lb - la
	var length := seg.length()
	if length < 1e-6 or _grid.is_empty():
		return best
	var pad := r + MAX_PROP_HALF
	var x0 := int(floor((minf(la.x, lb.x) - pad) / GRID_CELL))
	var x1 := int(floor((maxf(la.x, lb.x) + pad) / GRID_CELL))
	var z0 := int(floor((minf(la.z, lb.z) - pad) / GRID_CELL))
	var z1 := int(floor((maxf(la.z, lb.z) + pad) / GRID_CELL))
	var best_t := 2.0
	var best_id := -1
	var best_pt := Vector3.ZERO
	var best_n := Vector3.UP
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var bucket: Variant = _grid.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for id: int in (bucket as Array):
				var cap: Array = _cap_local[id]
				var mid: Vector3 = cap[3]
				var half := float(cap[4]) + r
				if mid.distance_squared_to(Geometry3D.get_closest_point_to_segment(mid, la, lb)) > half * half:
					continue
				var foot: Vector3 = cap[0]
				var head: Vector3 = cap[1]
				var reach := r + float(cap[2])
				var pts := Geometry3D.get_closest_points_between_segments(la, lb, foot, head)
				var on_shot: Vector3 = pts[0]
				var on_axis: Vector3 = pts[1]
				var d2 := on_shot.distance_squared_to(on_axis)
				if d2 > reach * reach:
					continue
				var t := (on_shot - la).length() / length - sqrt(maxf(reach * reach - d2, 0.0)) / length
				t = clampf(t, 0.0, 1.0)
				if t < best_t:
					best_t = t
					best_id = id
					best_pt = la + seg * t
					var axis_pt := Geometry3D.get_closest_point_to_segment(best_pt, foot, head)
					var n := best_pt - axis_pt
					best_n = n.normalized() if n.length_squared() > 1e-10 else -seg / length
	if best_id >= 0:
		if has_xf:
			best_pt = global_transform * best_pt
			best_n = (global_transform.basis * best_n).normalized()
		best = {"id": best_id, "frac": best_t, "point": best_pt, "normal": best_n}
	return best


## A weapon's knockback dv (world space, m/s) on prop `id`: topples a standing prop when |dv| reaches its threshold,
## shoves a fallen one. `src` is who did it, for logs only.
func apply_impulse(id: int, dv: Vector3, _src: String) -> void:
	if id < 0 or id >= items.size():
		return
	var dir := _deck_dir(id, dv)
	match state_of(id):
		STANDING:
			if dv.length() >= float(TYPES[items[id]["type"]]["dv"]):
				request(id, TOPPLE, dir)
		DOWN:
			request(id, SHOVE, dir, dv.length())


## Splash: every prop within `radius` of `point` (world space) gets dv x (1 - d / radius), pointing away from it.
func blast(point: Vector3, radius: float, dv: float, src: String) -> void:
	if radius <= 0.0 or _grid.is_empty():
		return
	var has_xf := is_inside_tree() and global_transform != Transform3D.IDENTITY
	var lp := global_transform.affine_inverse() * point if has_xf else point
	var pad := radius + MAX_PROP_HALF
	var x0 := int(floor((lp.x - pad) / GRID_CELL))
	var x1 := int(floor((lp.x + pad) / GRID_CELL))
	var z0 := int(floor((lp.z - pad) / GRID_CELL))
	var z1 := int(floor((lp.z + pad) / GRID_CELL))
	var hits: Array[Array] = []
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var bucket: Variant = _grid.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for id: int in (bucket as Array):
				var cap: Array = _cap_local[id]
				var near := Geometry3D.get_closest_point_to_segment(lp, cap[0], cap[1])
				var d := near.distance_to(lp)
				if d >= radius:
					continue
				var away := (cap[0] as Vector3) - lp
				if has_xf:
					away = global_transform.basis * away
				if away.length_squared() < 1e-8:
					away = Vector3.UP
				hits.append([id, away.normalized() * dv * (1.0 - d / radius)])
	for h: Array in hits:
		apply_impulse(int(h[0]), h[1] as Vector3, src)


## A world-space vector as a unit direction in the deck plane at prop `id` ((0, 1) along +s when it has no level part).
func _deck_dir(id: int, v: Vector3) -> Vector2:
	var local := global_transform.basis.inverse() * v if is_inside_tree() else v
	var p := pose_of(id)
	var b := CityGeo.frame_basis(ring, p["s"])
	if CityPropSim.is_roof(items[id]):
		b = (_bxf[int(items[id]["building"])] as Transform3D).basis
	var d := Vector2(local.dot(b.x), local.dot(b.z))
	return d.normalized() if d.length_squared() > 1e-8 else Vector2(0.0, 1.0)


# --- Pushers ---------------------------------------------------------------------------------------------

## Register a mover this machine owns: it topples what it walks into and shoves what lies on the ground.
func add_pusher(body: Node3D, radius: float) -> void:
	for p: Array in _pushers:
		if p[0] == body:
			p[1] = radius
			return
	_pushers.append([body, radius])


func _scan() -> void:
	_found.clear()
	if not is_inside_tree():
		return
	var bodies: Array[Node] = []
	_bodies_under(get_tree().root, bodies)
	for n in bodies:
		var radius := 1.0
		for c in n.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
				radius = ((c as CollisionShape3D).shape as CapsuleShape3D).radius
		_found.append([n, radius])


## Every CharacterBody3D under `node`, in the order find_children gives (depth first, a node before its children), without
## walking into static bodies: a city's collision is thousands of shapes under one StaticBody3D per deck, and walking them
## every second on every deck cost 4 ms a scan in a three-deck stack.
static func _bodies_under(node: Node, out: Array[Node]) -> void:
	for c in node.get_children():
		if c is CharacterBody3D:
			out.append(c)
		if not (c is StaticBody3D):
			_bodies_under(c, out)


func _contacts(delta: float) -> void:
	if _pushers.is_empty():
		_scan_in -= delta
		if _scan_in <= 0.0:
			_scan_in = SCAN_EVERY
			_scan()
	var list := _pushers if not _pushers.is_empty() else _found
	var dead := false
	for p: Array in list:
		# A freed body (a mech that left) is checked before any cast: casting a freed object is a script error.
		if not is_instance_valid(p[0]):
			dead = true
			continue
		var body := p[0] as Node3D
		if body == null or not body.is_inside_tree() or not Net.moves(body):
			continue
		_push(body, float(p[1]), delta)
	if dead:      # drop freed pushers / found bodies from the list for good
		var keep := list.filter(func(p: Array) -> bool: return is_instance_valid(p[0]))
		list.clear()
		list.append_array(keep)


## The props a pusher at arc (x, s) `here` with `radius` may touch, ascending: every standing prop whose rest position
## is within radius + its own radius (from the rest-position grid), and every prop that has moved (it may lie anywhere).
## The same set the old loop over every prop let through its distance test, in the same order.
func push_candidates(here: Vector2, radius: float) -> Array[int]:
	var out: Array[int] = []
	var pad := radius + _reach_pad
	for cx in range(int(floor((here.x - pad) / ARC_CELL)), int(floor((here.x + pad) / ARC_CELL)) + 1):
		for cs in range(int(floor((here.y - pad) / ARC_CELL)), int(floor((here.y + pad) / ARC_CELL)) + 1):
			var bucket: Variant = _arc_grid.get(Vector2i(cx, cs))
			if bucket != null:
				for id: int in bucket:
					if not _ev.has(id):
						out.append(id)
	for id: int in _ev:
		out.append(id)
	out.sort()
	return out


## Perf (bots topple many props; every pusher used to build the pose of every moved prop every frame): true when moved
## deck prop `id` has come to rest and its base is farther from `here` than `reach` + its full length, so _push's
## distance test (to the base standing, to the base..tip segment lying, tip within height * scale of the base) is sure to
## skip it. Same pushes as without it. The rest base is cached per event ([event, motion end, base]): a new event, or a
## clock before the end, falls back to the full test. Roof props (building frame) always take the full test.
func _settled_out_of_reach(id: int, it: Dictionary, here: Vector2, reach: float) -> bool:
	if CityPropSim.is_roof(it):
		return false
	var ev: Dictionary = _ev[id]
	var c: Variant = _rest_xs.get(id)
	if c == null or not is_same((c as Array)[0], ev):
		var end := float(ev.get("t0", 0.0)) + CityPropSim.duration(ev, str(it["type"]))
		if now < end:
			return false
		var p := pose_of(id)
		c = [ev, end, Vector2(p["x"], p["s"])]
		_rest_xs[id] = c
	if now < float((c as Array)[1]):
		return false
	var span := reach + float(TYPES[it["type"]]["height"]) * float(it["scale"])
	return here.distance_squared_to((c as Array)[2] as Vector2) > span * span


## Touch every prop within reach of one pusher (the candidates from push_candidates; brute_force: every prop).
func _push(body: Node3D, radius: float, delta: float) -> void:
	var local := to_local(body.global_position)
	var at := ring.world_to_arc(local)
	var key := body.get_instance_id()
	var vel: Variant = body.get("velocity")
	var v2 := Vector2.ZERO
	var v := Vector3.ZERO
	var has_v := vel is Vector3
	if has_v:
		v = global_transform.basis.inverse() * (vel as Vector3)
		v2 = Vector2(v.x, v.dot(ring.tangent_at(local)))
	elif _last_pos.has(key) and delta > 0.0:
		v2 = (Vector2(at.x, at.y) - (_last_pos[key] as Vector2)) / delta
	_last_pos[key] = Vector2(at.x, at.y)
	var speed := v2.length()
	if speed < PUSH_MIN_SPEED:
		return
	var dir := v2 / speed
	var here := Vector2(at.x, at.y)
	if not brute_force and (at.z < -(PUSH_HEIGHT + 1.0) or at.z > plan.p("ceiling") + 1.0):
		return      # on another deck (below this floor or above this ceiling): nothing here is within its reach
	for id: int in (range(items.size()) if brute_force else push_candidates(here, radius)):
		var t := float(_asked.get(id, -INF))
		if now - t < ASK_EVERY and now >= t:
			continue
		var it: Dictionary = items[id]
		var reach := radius + float(TYPES[it["type"]]["radius"])
		if not _ev.has(id):
			if here.distance_squared_to(Vector2(it["x"], it["s"])) > reach * reach:
				continue        # the common case, a standing prop out of reach, without building its pose
		elif not brute_force and _settled_out_of_reach(id, it, here, reach):
			continue            # a moved prop at rest far away: the segment test below would skip it too (perf)
		var state := state_of(id)
		if state == FALLING or state == SLIDING:
			continue
		var pose := pose_of(id)
		var me := here
		var way := dir
		if CityPropSim.is_roof(it):
			# On a roof: the pusher's span [feet, feet + PUSH_HEIGHT] must meet the prop's, all in the roof's frame (a mech
			# in the street under the roof never reaches it, one on the roof does).
			var bi := int(it["building"])
			var lp: Vector3 = (_bxf_inv[bi] as Transform3D) * local
			var ly := float(it["ly"])
			var top := ly + float(TYPES[it["type"]]["height"]) * float(it["scale"])
			if lp.y + PUSH_HEIGHT < ly - ROOF_TOL or lp.y > top + ROOF_TOL:
				continue
			me = Vector2(lp.x, lp.z)
			if has_v:
				var vb := (_bxf[bi] as Transform3D).basis.inverse() * v
				var w := Vector2(vb.x, vb.z)
				if w.length_squared() > 1e-8:
					way = w.normalized()
		elif absf(at.z - float(pose["h"])) >= PUSH_HEIGHT:
			continue
		var base := Vector2(pose["x"], pose["s"])
		var d := me.distance_to(base)
		if state == DOWN:
			# A fallen prop lies along its lie: test against that segment.
			var length := float(TYPES[it["type"]]["height"]) * float(it["scale"]) * sin(float(pose["tilt"]))
			var tip := base + CityPropSim.dir_of(pose["lie"]) * length
			d = me.distance_to(Geometry2D.get_closest_point_to_segment(me, base, tip))
		if d > reach:
			continue
		_asked[id] = now
		if state == STANDING:
			request(id, TOPPLE, way)
		else:
			request(id, SHOVE, way, PUSH_SHOVE * speed)
