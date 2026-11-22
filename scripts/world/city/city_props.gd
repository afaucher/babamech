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
## Drawing: one MultiMeshInstance3D per prop shape; only moving props have their instance rewritten each frame.
## Roof units (docs/design/city-rooftops.md): water tanks, AC units, vents and roof planters stand on building roofs.
## Such an item has `building` >= 0 (street props: absent or -1), `tier`, and its spot (lx, ly, lz) in that building's
## flat frame (building_xf, the same as CityDistrict.building_frame); its x / s / h are that spot in arc coordinates
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
const MAX_PROP_HALF := 7.5     ## m conservative upper bound on any prop's half-height + radius
const ROOF_TOL := 0.3          ## a pusher reaches a roof prop when [feet, feet + PUSH_HEIGHT] meets the prop's height span
## Roof unit footprints (m, centre to farthest edge, at any yaw) for placing them clear of each other and of what
## stands on the roof; the contact radius in TYPES is what the sim uses.
const ROOF_FOOT := {"water_tank": 1.5, "ac": 1.35, "vent": 0.5, "planter": 1.75}
const ROOF_KIND := {"tank": "water_tank", "ac": "ac", "vent": "vent", "planter": "planter"}     ## plan slot kind -> type

signal prop_moved(id: int, type: String, kind: int, world_pos: Vector3, speed: float)

var items: Array = []           ## CityProps.layout(plan): [{id, type, x, s, h, yaw, scale, variant, pit}] (+ roof fields)
var plan: CityPlan
var ring: RingFrame
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
var _bxf: Array = []            ## building index -> its flat frame (Transform3D) in this node's space
var _bxf_inv: Array = []        ## and its inverse


func net_fields() -> Dictionary:
	return {
		"items": Net.SPAWN,          # from the plan's cosmetic seed, the same on every machine (layout_checksum)
		"plan": Net.SPAWN, "ring": Net.SPAWN,
		"_ev": Net.OWNER,            # the host decides every event; the crew receives them (prop.ev, prop.sync)
		"now": Net.LOCAL,            # the shared clock where there is one
		"_moving": Net.LOCAL, "_slot": Net.LOCAL, "_mms": Net.LOCAL, "_proto_tris": Net.LOCAL, "_geo": Net.LOCAL,
		"_floors": Net.LOCAL, "_online_clock": Net.LOCAL,
		"_cap_local": Net.LOCAL, "_grid": Net.LOCAL, "_prop_cell": Net.LOCAL,
		"_bxf": Net.LOCAL, "_bxf_inv": Net.LOCAL,      # from the plan and the ring, the same on every machine
		"_pushers": Net.PRIVATE, "_found": Net.PRIVATE, "_scan_in": Net.PRIVATE, "_last_pos": Net.PRIVATE,
		"_asked": Net.PRIVATE,
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


# --- Layout ----------------------------------------------------------------------------------------------

## Every prop of the district as plain data, from its own generator so it never depends on what the meshers draw.
## Street trees every ~9 m along each block edge with a lamp in every third slot, a bin beside some lamps and a bench
## beside some trees; a signal pole and a sign post at the low end of each edge; median, garden, plaza and park trees;
## plaza and park benches. Nothing stands in a floor hole or on ground kept clear. ids are array indices.
static func layout(p: CityPlan) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = p.cosmetic_seed() + 1
	var out: Array = []
	for b: Dictionary in p.blocks:
		_block_items(out, b["rect"], rng)
	var av := p.avenue_x()
	for road: Dictionary in p.roads_x:
		if road["kind"] != "avenue" and road["kind"] != "spine":
			continue
		var mid := (av.x + av.y) * 0.5      # the median of the avenue (its own lane on a section's spine)
		for j in p.roads_s.size() - 1:
			var v0: float = float(p.roads_s[j]["b"]) + 12.0
			var v1: float = float(p.roads_s[j + 1]["a"]) - 12.0
			var n := int((v1 - v0) / 15.0)
			for i in n + 1:
				if n > 0:
					_tree(out, rng, mid, v0 + (v1 - v0) * float(i) / float(n), CityPlan.CURB_H, 0.8, false)
	for l: Dictionary in p.lots:
		if l["kind"] == "open":
			_lot_items(out, l, rng)
	var kept: Array = []
	for it: Dictionary in out:
		if p.clear_at(Vector2(it["x"], it["s"])):
			it["id"] = kept.size()
			kept.append(it)
	_roof_items(kept, p)      # after the street props, so their ids do not move
	return kept


## The flat frame building i stands in, in the district's space (the same as CityDistrict.building_frame).
static func building_xf(ring: RingFrame, p: CityPlan, i: int) -> Transform3D:
	var c: Vector2 = p.buildings[i]["center"]
	return Transform3D(CityGeo.frame_basis(ring, c.y), ring.arc_to_world(c.x, c.y, CityPlan.CURB_H))


## Roof units on every roof slot of the plan (CityPlan.roof_slots), from their own stream: as many tries as the old
## roof clutter, each at least 3.6 m from the others and clear of what stands on the roof (CityPlan.roof_blockers).
static func _roof_items(out: Array, p: CityPlan) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = p.cosmetic_seed() + 2
	var ring := RingFrame.new(p.p("radius"))
	for i in p.buildings.size():
		var xf := building_xf(ring, p, i)
		for slot: Array in p.roof_slots(i):
			var t: int = slot[0]
			var kinds: Array = []
			for k: String in slot[1]:
				if ROOF_KIND.has(k):
					kinds.append(ROOF_KIND[k])
			if kinds.is_empty():
				continue
			var tier: Dictionary = p.buildings[i]["tiers"][t]
			var size: Vector2 = tier["size"]
			var off: Vector2 = tier["off"]
			var y := float(tier["y1"])
			var blockers := p.roof_blockers(i, t)
			var n := clampi(int(size.x * size.y / 70.0), 1, 5)
			var used: Array[Vector2] = []
			for k in n:
				var pos := off + Vector2(rng.randf_range(-1.0, 1.0) * maxf(size.x * 0.5 - CityPlan.ROOF_INSET, 0.0),
						rng.randf_range(-1.0, 1.0) * maxf(size.y * 0.5 - CityPlan.ROOF_INSET, 0.0))
				var type: String = kinds[rng.randi_range(0, kinds.size() - 1)]
				var yaw := 0.0 if rng.randf() < 0.5 else PI * 0.5
				var variant := rng.randi_range(0, CityBuildings.TANK_COLOURS.size() - 1) if type == "water_tank" else 0
				var ok := true
				for q in used:
					if q.distance_to(pos) < 3.6:
						ok = false
				for q in blockers:
					if q.grow(float(ROOF_FOOT[type]) + CityPlan.ROOF_MARGIN).has_point(pos):
						ok = false
				if not ok:
					continue
				used.append(pos)
				var arc := ring.world_to_arc(xf * Vector3(pos.x, y, pos.y))
				out.append({"id": out.size(), "type": type, "x": arc.x, "s": arc.y, "h": arc.z, "yaw": yaw, "scale": 1.0,
						"variant": variant, "pit": false, "building": i, "tier": t, "lx": pos.x, "lz": pos.y, "ly": y})


static func layout_checksum(list: Array) -> String:
	var buf := StreamPeerBuffer.new()
	for it: Dictionary in list:
		buf.put_32(int(it["id"]))
		buf.put_8(CityPropSim.TYPE_ORDER.find(it["type"]))
		for k: String in ["x", "s", "h", "yaw", "scale"]:
			buf.put_32(int(round(float(it[k]) * 1000.0)))
		buf.put_8(int(it["variant"]))
		buf.put_8(1 if it["pit"] else 0)
		if CityPropSim.is_roof(it):
			buf.put_32(int(it["building"]))
			buf.put_8(int(it["tier"]))
			for k: String in ["lx", "lz", "ly"]:
				buf.put_32(int(round(float(it[k]) * 1000.0)))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


static func _add(out: Array, type: String, x: float, s: float, h: float, yaw: float, scale: float = 1.0, variant: int = 0, pit: bool = false) -> void:
	out.append({"id": out.size(), "type": type, "x": x, "s": s, "h": h, "yaw": yaw, "scale": scale, "variant": variant, "pit": pit})


static func _tree(out: Array, rng: RandomNumberGenerator, x: float, s: float, h: float, scale: float, pit: bool) -> void:
	var yaw := rng.randf() * TAU
	var sc := scale * rng.randf_range(0.9, 1.1)
	_add(out, "tree", x, s, h, yaw, sc, rng.randi_range(0, CityStreets.TREE_LEAVES.size() - 1), pit)


static func _yaw(side: int) -> float:
	var n: Vector2 = CityPlan.SIDE_N[side]
	return atan2(n.x, n.y)


## A point on the sidewalk: `t` along the block edge `side` from its low end, `d` in from the curb line.
static func _edge_point(r: Rect2, side: int, t: float, d: float) -> Vector2:
	match side:
		0: return Vector2(r.end.x - d, r.position.y + t)
		1: return Vector2(r.position.x + d, r.position.y + t)
		2: return Vector2(r.position.x + t, r.end.y - d)
	return Vector2(r.position.x + t, r.position.y + d)


static func _block_items(out: Array, r: Rect2, rng: RandomNumberGenerator) -> void:
	var h := CityPlan.CURB_H
	for side in 4:
		var length := r.size.y if side < 2 else r.size.x
		var a := 8.5
		var n := maxi(int((length - a * 2.0) / 9.0), 0)
		var yaw := _yaw(side)
		for i in n + 1:
			var t := a + (length - a * 2.0) * (float(i) / float(n) if n > 0 else 0.5)
			var d := 0.95       # distance in from the curb line
			var pos := _edge_point(r, side, t, d)
			if i % 3 == 1:
				_add(out, "lamp", pos.x, pos.y, h, yaw)
				if rng.randf() < 0.5:
					var q := _edge_point(r, side, t + 1.3, d)
					_add(out, "bin", q.x, q.y, h, yaw)
			else:
				_tree(out, rng, pos.x, pos.y, h, 0.9, true)
				if rng.randf() < 0.3:
					var q := _edge_point(r, side, t + 2.6, d + 0.1)
					_add(out, "bench", q.x, q.y, h, yaw + PI)
		# A signal pole by the crosswalk at the low end of each edge, a street sign just past the corner ramp.
		var sp := _edge_point(r, side, 1.2, 0.8)
		_add(out, "signal", sp.x, sp.y, h, yaw)
		var sg := _edge_point(r, side, 5.6, 0.6)
		_add(out, "sign", sg.x, sg.y, h, yaw)


static func _lot_items(out: Array, l: Dictionary, rng: RandomNumberGenerator) -> void:
	var r: Rect2 = (l["rect"] as Rect2).grow(-2.0)
	if r.size.x < 1.0 or r.size.y < 1.0:
		return
	var c := r.get_center()
	var h := CityPlan.CURB_H
	match str(l["open"]):
		"garden":
			var n := clampi(int(r.size.x * r.size.y / 60.0), 1, 6)
			for i in n:
				var x := rng.randf_range(r.position.x, r.end.x)
				var s := rng.randf_range(r.position.y, r.end.y)
				_tree(out, rng, x, s, h + 0.25, rng.randf_range(0.9, 1.3), false)
		"plaza":
			_tree(out, rng, c.x, c.y, h + 0.7, 1.2, false)
			if r.size.y > 8.0:
				_add(out, "bench", c.x, r.position.y + 0.5, h, 0.0)
				_add(out, "bench", c.x, r.end.y - 0.5, h, PI)
		"park":
			# Benches around the fountain, trees on the lawns.
			for k in 4:
				var ang := PI * 0.25 + PI * 0.5 * float(k)
				_add(out, "bench", c.x + sin(ang) * 5.6, c.y + cos(ang) * 5.6, h, ang + PI)
			var n := clampi(int(r.size.x * r.size.y / 55.0), 4, 40)
			for i in n:
				var q := Vector2(rng.randf_range(r.position.x, r.end.x), rng.randf_range(r.position.y, r.end.y))
				if absf(q.x - c.x) < 3.2 or absf(q.y - c.y) < 3.2 or q.distance_to(c) < 8.0:
					continue
				_tree(out, rng, q.x, q.y, h, rng.randf_range(1.0, 1.6), false)


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
	items = layout(p)
	_bxf.clear()
	_bxf_inv.clear()
	for i in p.buildings.size():
		var xf := building_xf(r, p, i)
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
	_grid.clear()
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
		mm.mesh = geo.commit(CityPalette.surface_material())
		mm.instance_count = (members[k] as Array).size()
		var mi := MultiMeshInstance3D.new()
		mi.name = "%s%d" % [shapes[k][0], shapes[k][1]]
		mi.multimesh = mm
		add_child(mi)
		_mms.append(mm)
		_proto_tris.append(geo.tri_count())
	for it: Dictionary in items:
		_draw(int(it["id"]))
	_online_clock = Net.online()
	now = _clock()


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


func _clock() -> float:
	var s := Net.session()
	if s != null and s.online():
		return s.host_time()
	return now


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
	step(delta)


## One physics step: advance the clock, let this machine's pushers touch props, redraw what moves.
func step(delta: float) -> void:
	if items.is_empty():
		return
	var online := Net.online()
	if online != _online_clock:
		# The clock source changed (a session began or ended): settle every motion at rest on the new clock.
		_online_clock = online
		var keep := snapshot()
		now = _clock()
		restore(keep)
	now = _clock() if online else now + delta
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
		s.send_event(1, "prop.req", {"id": id, "kind": kind, "dir": dir.normalized(), "v0": v0})
		return
	_decide(id, kind, dir.normalized(), v0)


## Host: a standing prop topples, a prop at rest is shoved; anything mid-motion ignores the request.
func _decide(id: int, kind: int, dir: Vector2, v0: float) -> void:
	now = _clock()
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
		s.send_event(0, "prop.ev", ev)


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


## Every prop as `bytes` says (an empty snapshot stands them all up again).
func restore(bytes: PackedByteArray) -> void:
	var touched := _ev.keys()
	_ev.clear()
	_moving.clear()
	_asked.clear()
	if bytes.size() >= 4:
		var buf := StreamPeerBuffer.new()
		buf.data_array = bytes
		var n := buf.get_u32()
		for i in n:
			var id := buf.get_u32()
			var pose := {}
			for k: String in ["x", "s", "lie", "tilt", "spin"]:
				pose[k] = buf.get_float()
			if id < items.size():
				_ev[id] = {"id": id, "kind": CityPropSim.REST, "pose": pose, "t0": now}
	for id: int in touched + _ev.keys():
		_draw(id)


func _on_event(_from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if items.is_empty():
		return
	var s := Net.session()
	match kind:
		"prop.req":
			var id := int(data.get("id", -1))
			var dir: Variant = data.get("dir")
			if s != null and s.is_host() and id >= 0 and id < items.size() and dir is Vector2 and (dir as Vector2).length_squared() > 1e-8:
				_decide(id, int(data.get("kind", -1)), (dir as Vector2).normalized(), float(data.get("v0", 0.0)))
		"prop.ev":
			if s != null and s.is_client():
				apply_event(data)
		"prop.sync":
			if s != null and s.is_client():
				restore(data.get("bytes", PackedByteArray()))


func _on_peer_joined(peer: int) -> void:
	var s := Net.session()
	if s != null and s.is_host() and not items.is_empty():
		s.send_event(peer, "prop.sync", {"bytes": snapshot()})


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
	for n in get_tree().root.find_children("*", "CharacterBody3D", true, false):
		var radius := 1.0
		for c in n.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
				radius = ((c as CollisionShape3D).shape as CapsuleShape3D).radius
		_found.append([n, radius])


## Whether this machine moves `body`: offline everything; online the owner peer (owner_peer, 0 = the host).
static func _owns(body: Node) -> bool:
	var s := Net.session()
	if s == null or not s.online():
		return true
	var owner_peer: Variant = body.get("owner_peer")
	var peer := int(owner_peer) if owner_peer != null else 0
	return peer == s.local_id() or (peer == 0 and s.is_host())


func _contacts(delta: float) -> void:
	if _pushers.is_empty():
		_scan_in -= delta
		if _scan_in <= 0.0:
			_scan_in = SCAN_EVERY
			_scan()
	var list := _pushers if not _pushers.is_empty() else _found
	for p: Array in list:
		var body := p[0] as Node3D
		if not is_instance_valid(body) or not body.is_inside_tree() or not _owns(body):
			continue
		_push(body, float(p[1]), delta)


## Touch every prop within reach of one pusher.
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
	for id in items.size():
		var t := float(_asked.get(id, -INF))
		if now - t < ASK_EVERY and now >= t:
			continue
		var it: Dictionary = items[id]
		var reach := radius + float(TYPES[it["type"]]["radius"])
		if not _ev.has(id) and here.distance_squared_to(Vector2(it["x"], it["s"])) > reach * reach:
			continue        # the common case, a standing prop out of reach, without building its pose
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
