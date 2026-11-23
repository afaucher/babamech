class_name MissionWorld
extends Node3D
## The world side of mission objectives phase 1 (docs/design/mission-objectives.md §5.6 / §7 / §9; this side:
## docs/design/city-ramps-and-stack.md "Mission world (phase 1)"): wave doors in blast-door gates and freight lifts, the
## flag mast and its zone ring, the defend relay, the extraction portal and its hold zone. Made by
## CityStack.setup_mission(plan) once the stack is built (stack.mission; freed when the stack rebuilds).
##
## PRESENTATION plus a little collision. No mission logic, no network, no global randomness (looks: a generator seeded from
## the section's cosmetic seed and the piece's id). TIME is the shared mission clock, given by advance_to(t) every frame on
## every machine. Every door is a SCHEDULED EFFECT: open_source(id, open_at, hold) stores times, and the door's state at
## any t is a pure function of the stored times (door_state), so two machines given the same calls show the same thing,
## and a call that arrives late (or a late joiner restored from snapshot()) snaps to the right state. Signals fire once
## per scheduled moment when the clock passes it (skipped silently when it is more than EVENT_STALE s old).
##
## Pieces are parented under their deck's CityDistrict, so a deck hidden by CityStack.set_quality hides them too.
## advance_to does nothing while no door is moving, no flag is swapping and no blink is due (one comparison).

signal source_event(kind: String, id: Variant, world_pos: Vector3)      ## warn | open | close | seal
signal flag_event(id: Variant, raised: bool, world_pos: Vector3)
signal asset_event(id: Variant, kind: String, world_pos: Vector3)       ## damaged | destroyed
signal portal_event(kind: String, world_pos: Vector3)                   ## start | open

const WARN := 5.0            ## s of telegraph before open_at (gate: beacon + klaxon 3 s, then the leaves 2 s; lift: countdown 5 s)
const GATE_OPEN := 2.0       ## s a gate's leaves take to open, ending at open_at
const LIFT_OPEN := 1.5       ## s the lift doors take, ending at open_at
const CLOSE := 2.0           ## s either takes to close
const HOLD := 12.0           ## default s open after open_at
const FLAG_SWAP := 2.0       ## s of the banner swap
const EVENT_STALE := 1.5     ## s: a scheduled moment older than this when first seen fires no signal
const BLINK := 1.2           ## s period of the relay's band (on 60 %)
const SOURCE_IN := 8.0       ## m inside the wall Missions puts a gate source (docs: where a source point lies)
const GATE_POINT := -3.0     ## m along the gate frame's +Z source_point() gives: 3 m BEHIND the wall plane, in the recess (hidden while shut)
const LIFT_POINT := 4.0      ## m in front of the lift door source_point() gives
const FLAG_CLEAR := 2.5      ## m clear round a flag mast (snap)
const ASSET_CLEAR := 3.5     ## m clear round the relay (snap)
const DEFAULT_SNAP := 45.0   ## m a site may move to clear ground when neither the record nor MissionPlan says

var stack: CityStack
var plan: Variant                ## the MissionPlan (or a Dictionary with its fields)
var now := 0.0                   ## the last advance_to time
var quality := CityQuality.HIGH

var _sources := {}               ## id -> {id, deck, kind, x, s, edge, connector}, as given
var _doors := {}                 ## id -> GateDoor / LiftDoor (gate / lift sources that found their door)
var _sched := {}                 ## id -> [open_at, close_at, prev_close_at]
var _sealed := {}                ## id -> the clock time it is sealed at
var _fired := {}                 ## id -> {warn, open, close, seal: bool}
var _door_state := {}            ## id -> last state posed
var _lights := {}                ## id -> OmniLight3D while warning
var _flags := {}                 ## id -> FlagMast
var _flag_state := {}            ## id -> [raised, from, t0]
var _sites := {}                 ## objective id -> {deck, x, s, h, snapped, ok}
var _zones := {}                 ## objective id -> MeshInstance3D (flag zone ring)
var _zone_state := {}            ## objective id -> "idle" | "contested" | "ours"
var _assets := {}                ## objective id -> RelayAsset
var _asset_hp := {}              ## objective id -> 0..1
var _asset_told := {}            ## objective id -> worst event sent (0 none, 1 damaged, 2 destroyed)
var _portal: MissionProps.Portal
var portal_progress := 0.0
var _portal_told := 0            ## 1 start sent, 2 open sent
var _hold: MeshInstance3D
var hold_state := "idle"
var _cut: Array[CollisionShape3D] = []    ## district wall shapes disabled where a gate door stands
var _walled: Array[CityDistrict] = []     ## districts whose Walls mesh was rebuilt without the door leaves
var _next := -INF                ## advance_to does nothing until this time (unless the clock goes back)
var _blink_on := true
var setup_ready := false               ## the stepped setup has finished (setup_step returned true); before it calls do nothing
var chunk_log: Array = []        ## [[label, ms], ...] of the setup's chunks, in order
var _queue: Array = []           ## [label, Callable] chunks of the setup
var _qi := 0                     ## next chunk to run
var _b_us := 0                   ## usec spent in the setup's chunks
var _wall_geo: CityGeo           ## the deck's walls being re-meshed (parts in successive chunks)
var _meta_decks: Array[CityDistrict] = []   ## districts whose plan carries the "mission_doors" meta


func net_fields() -> Dictionary:
	return {
		"stack": Net.SPAWN, "plan": Net.SPAWN,          # from the section and mission seeds, the same on every machine
		"_sources": Net.SPAWN, "_sites": Net.SPAWN,     # derived from the plan (snap rule: plan data only)
		# The host decides these; Engine carries them (wave orders, mission.state) and restores a late joiner with snapshot()
		"_sched": Net.OWNER, "_sealed": Net.OWNER, "_flag_state": Net.OWNER, "_zone_state": Net.OWNER,
		"_asset_hp": Net.OWNER, "portal_progress": Net.OWNER, "hold_state": Net.OWNER,
		"now": Net.LOCAL,                                # the shared clock
		"quality": Net.LOCAL, "_doors": Net.LOCAL, "_fired": Net.LOCAL, "_door_state": Net.LOCAL, "_lights": Net.LOCAL,
		"_flags": Net.LOCAL, "_zones": Net.LOCAL, "_assets": Net.LOCAL, "_asset_told": Net.LOCAL, "_portal": Net.LOCAL,
		"_portal_told": Net.LOCAL, "_hold": Net.LOCAL, "_cut": Net.LOCAL, "_walled": Net.LOCAL, "_next": Net.LOCAL,
		"_blink_on": Net.LOCAL, "setup_ready": Net.LOCAL, "chunk_log": Net.LOCAL, "_queue": Net.LOCAL, "_qi": Net.LOCAL,
		"_b_us": Net.LOCAL, "_wall_geo": Net.LOCAL, "_meta_decks": Net.LOCAL,
	}


# --- Setup ---------------------------------------------------------------------------------------------------------------

## A field of the plan (a MissionPlan object or a Dictionary), or `fallback`.
static func field(p: Variant, key: String, fallback: Variant = null) -> Variant:
	if p is Dictionary:
		return (p as Dictionary).get(key, fallback)
	if p is Object and p != null:
		var v: Variant = (p as Object).get(key)
		return fallback if v == null else v
	return fallback


## Build everything in one call (setup_begin + setup_step to the end: the same result as a stepped setup).
func setup(st: CityStack, p: Variant) -> void:
	setup_begin(st, p)
	while not setup_step(INF):
		pass


# --- Stepped setup (CityStack.setup_mission_begin / _step) -------------------------------------------------------------
## setup_begin() records the plan; each setup_step(budget_ms) runs chunks until budget_ms of wall time is spent (always at
## least one) and returns true once everything is built (`setup_ready`). The first chunk matches sources to doors and queues the
## rest, in this order: one chunk per wave door (build + wall collision cut), the walls of each deck with gate doors re-meshed
## in CityDistrict's own parts (one per side, a farm side in FARM_PARTS parts), the doors posed, then per flag / defend
## objective its site search and its build, the hold zone, the portal. chunk_log = [[label, ms], ...]. Until setup_ready every
## call that changes state (open_source, set_flag, advance_to, restore, ...) returns at once.
func setup_begin(st: CityStack, p: Variant) -> void:
	stack = st
	plan = p
	setup_ready = false
	chunk_log = []
	_qi = 0
	_b_us = 0
	_queue = [["plan", _c_plan]]


func setup_step(budget_ms: float = 8.0) -> bool:
	var start := Time.get_ticks_usec()
	while _qi < _queue.size():
		var c: Array = _queue[_qi]
		_qi += 1
		var t := Time.get_ticks_usec()
		(c[1] as Callable).call()
		var dt := Time.get_ticks_usec() - t
		_b_us += dt
		chunk_log.append([c[0], float(dt) / 1000.0])
		if float(Time.get_ticks_usec() - start) >= budget_ms * 1000.0:
			break
	return setup_ready


## 0..1 through the setup (1 once setup_ready); never goes down.
func setup_progress() -> float:
	if setup_ready:
		return 1.0
	return float(_qi) / float(maxi(_queue.size(), 1)) * 0.999


## Wall time spent in the setup's chunks so far (ms).
func setup_ms() -> float:
	return float(_b_us) / 1000.0


func _c_plan() -> void:
	for src: Variant in field(plan, "sources", []):
		if not src is Dictionary:
			continue
		var sd: Dictionary = src
		var id: Variant = sd.get("id")
		if id == null:
			continue
		_sources[id] = sd
	# Match every gate / lift source to its door (a second id on the same gate or lift gets none).
	var used := {}
	var per_deck := {}        # district -> {key: true}
	var decks: Array[CityDistrict] = []
	for id: Variant in _sources:
		var sd: Dictionary = _sources[id]
		var d := _deck(sd.get("deck", 0))
		if d == null:
			continue
		match str(sd.get("kind", "")):
			"gate":
				var hit := find_gate(d, float(sd.get("x", 0.0)), float(sd.get("s", 0.0)), str(sd.get("edge", "")))
				if hit.is_empty():
					continue
				var key := "%d:%.2f" % [int(hit["w"]["side"]), float(hit["g"]["a"])]
				if used.has([d, key]):
					continue
				used[[d, key]] = true
				if not per_deck.has(d):
					per_deck[d] = {}
					decks.append(d)
				per_deck[d][key] = true
				_queue.append(["gate %s" % str(id), _c_gate.bind(id, d, hit)])
			"lift":
				var bi := find_lift(d, sd)
				if bi < 0 or used.has([d, "lift", bi]):
					continue
				used[[d, "lift", bi]] = true
				_queue.append(["lift %s" % str(id), _c_lift.bind(id, d, bi)])
	for d in decks:
		var parts := _wall_parts(d)
		for i in parts.size():
			_queue.append(["walls d%d %d/%d" % [d.plan.deck, i + 1, parts.size()],
					_c_walls.bind(d, per_deck[d], parts[i], i == 0, i == parts.size() - 1)])
	_queue.append(["pose doors", _c_pose_doors])
	# Flags first, then relays (a chained defend shares its flag's site: the relay snaps beside the mast), then the hold.
	for kind: String in ["flag", "defend", "hold"]:
		for o: Variant in field(plan, "objectives", []):
			if not o is Dictionary or str((o as Dictionary).get("type", "")) != kind:
				continue
			var id := str((o as Dictionary).get("id", ""))
			match kind:
				"flag":
					_queue.append(["site %s" % id, _c_site.bind(o, FLAG_CLEAR)])
					_queue.append(["flag %s" % id, _build_flag.bind(o)])
				"defend":
					_queue.append(["site %s" % id, _c_site.bind(o, ASSET_CLEAR)])
					_queue.append(["asset %s" % id, _build_asset.bind(o)])
				"hold":
					_queue.append(["hold %s" % id, _build_hold.bind(o)])
	_queue.append(["portal", _build_portal])
	_queue.append(["finish", _c_finish])


func _c_gate(id: Variant, d: CityDistrict, hit: Dictionary) -> void:
	var door := MissionProps.GateDoor.new()
	door.name = "MissionGate_%s" % str(id)
	door.build(d, hit["w"], hit["g"], _look(id))
	d.add_child(door)
	_doors[id] = door
	_cut_wall(d, hit["w"], hit["g"], door.body)


func _c_lift(id: Variant, d: CityDistrict, bi: int) -> void:
	var lift := MissionProps.LiftDoor.new()
	lift.name = "MissionLift_%s" % str(id)
	lift.build(d, bi)
	d.add_child(lift)
	_doors[id] = lift


func _c_pose_doors() -> void:
	for id: Variant in _doors:
		_pose_door(id, now, true)


func _c_site(o: Dictionary, clear_r: float) -> void:
	var d := _deck(o.get("deck", 0))
	if o.get("id") != null and d != null:
		_site(o, d, clear_r)


func _c_finish() -> void:
	setup_ready = true
	_next = -INF


## Free everything, give the walls back their baked leaves and their collision (restore = false when the decks are going
## away anyway: a stack rebuild).
func teardown(restore: bool = true) -> void:
	for n: Variant in _all_nodes():
		if is_instance_valid(n):
			(n as Node).queue_free()
	for l: Variant in _lights.values():
		if is_instance_valid(l):
			(l as Node).queue_free()
	_lights.clear()
	if restore:
		for cs in _cut:
			if is_instance_valid(cs):
				cs.disabled = false
		for d in _meta_decks:
			if is_instance_valid(d) and d.plan != null:
				d.plan.remove_meta("mission_doors")
		for d in _walled:
			if is_instance_valid(d):
				_rebuild_walls(d)
	_queue = []
	_qi = 0
	_wall_geo = null
	_cut.clear()
	_walled.clear()
	_meta_decks.clear()
	_doors.clear()
	_flags.clear()
	_zones.clear()
	_assets.clear()
	_portal = null
	_hold = null


func _all_nodes() -> Array:
	var out: Array = []
	out.append_array(_doors.values())
	out.append_array(_flags.values())
	out.append_array(_zones.values())
	out.append_array(_assets.values())
	if _portal != null:
		out.append(_portal)
	if _hold != null:
		out.append(_hold)
	return out


func _deck(k: Variant) -> CityDistrict:
	if stack == null or stack.decks.is_empty():
		return null
	return stack.decks[clampi(int(k), 0, stack.decks.size() - 1)]


func _look(id: Variant) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	var base := stack.section.cosmetic_seed() if stack.section != null else 1
	r.seed = hash([base, str(id), "mission"])
	return r


## The blast-door gate a gate source means on district d: {w: wall, g: gate} of the plan's boundary(), on the wall named by
## `edge` (s0 / s1 / x0 / x1; any wall when empty or unknown), nearest the point (x, s); {} when there is none.
static func find_gate(d: CityDistrict, x: float, s: float, edge: String) -> Dictionary:
	var side_want := CityPlan.SIDE_EDGE.find(edge)
	var best := {}
	var best_d := INF
	for w: Dictionary in d.plan.boundary():
		if side_want >= 0 and int(w["side"]) != side_want:
			continue
		for g: Dictionary in w["gates"]:
			if str(g["kind"]) != "blast_door":
				continue
			var mid := (float(g["a"]) + float(g["b"])) * 0.5
			var at := float(w["at"])
			var pt := Vector2(mid, at) if int(w["side"]) >= 2 else Vector2(at, mid)
			var dd := pt.distance_to(Vector2(x, s))
			if dd < best_d:
				best_d = dd
				best = {"w": w, "g": g}
	return best


## The building index of the freight-lift pillar a lift source means on district d: from its `connector` (the section's
## pillar), else the lift core nearest the point; -1 when there is none.
static func find_lift(d: CityDistrict, s: Dictionary) -> int:
	var want := Vector2(float(s.get("x", 0.0)), float(s.get("s", 0.0)))
	var sec := d.plan.section
	var ci := int(s.get("connector", -1))
	if sec != null and ci >= 0 and ci < sec.connectors.size() and int(sec.connectors[ci].get("pillar", -1)) >= 0:
		want = sec.pillar_point(d.plan.deck, int(sec.connectors[ci]["pillar"]))
	var best := -1
	var best_d := 60.0
	for i in d.plan.buildings.size():
		var b: Dictionary = d.plan.buildings[i]
		if not b["pillar"] or str(b["core"]["kind"]) != "lift":
			continue
		var dd := Vector2(float(b["core"]["x"]), float(b["core"]["s"])).distance_to(want)
		if dd < best_d:
			best_d = dd
			best = i
	return best


## Cut district d's wall collision at gate g: every wall slab box overlapping the gate is disabled and rebuilt in `body`
## round it (the slab beside the gate, and the lintel over it from the gate's height up). The door's own shapes (in
## GateDoor) close the opening while shut. The district's shape count never changes.
func _cut_wall(d: CityDistrict, w: Dictionary, g: Dictionary, body: StaticBody3D) -> void:
	var col := d.get_node_or_null("Collision") as StaticBody3D
	if col == null:
		return
	var side := int(w["side"])
	var across := side >= 2
	var out := 1.0 if side % 2 == 0 else -1.0
	var thick := CityStreets.WALL_THICK
	var at_c := float(w["at"]) + out * thick * 0.5
	var ga := float(g["a"])
	var gb := float(g["b"])
	var gh := float(g["h"])
	var ceiling := d.plan.p("ceiling")
	var geo := CityGeo.new(d.ring)
	var inv := (body.get_parent() as Node3D).transform.affine_inverse()     # the body is under the door (district space)
	for c in col.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.disabled or not cs.shape is BoxShape3D:
			continue
		var size := (cs.shape as BoxShape3D).size
		var a := d.ring.world_to_arc(cs.transform.origin)
		var lo: float
		var hi: float
		if across:
			if absf(a.y - at_c) > 0.8 or absf(size.z - thick) > 0.01 or size.y < ceiling:
				continue
			lo = a.x - size.x * 0.5
			hi = a.x + size.x * 0.5
		else:
			if absf(a.x - at_c) > 0.8 or absf(size.x - thick) > 0.01 or size.y < ceiling:
				continue
			lo = a.y - (size.z - CityDistrict.SEAM) * 0.5
			hi = a.y + (size.z - CityDistrict.SEAM) * 0.5
		if hi <= ga or lo >= gb:
			continue
		var y0 := -1.0                   # the y range CityDistrict._col_walls gives every wall slab
		var y1 := ceiling + 1.0
		cs.disabled = true
		_cut.append(cs)
		var pieces := [[lo, ga, y0], [gb, hi, y0], [maxf(lo, ga), minf(hi, gb), gh]]
		for pc: Array in pieces:
			var u0 := float(pc[0])
			var u1 := float(pc[1])
			if u1 - u0 < 0.1:
				continue
			var yb := float(pc[2])
			var xf: Transform3D
			var sz: Vector3
			if across:
				xf = geo.frame((u0 + u1) * 0.5, at_c, (yb + y1) * 0.5)
				sz = Vector3(u1 - u0, y1 - yb, thick)
			else:
				xf = geo.frame(at_c, (u0 + u1) * 0.5, (yb + y1) * 0.5)
				sz = Vector3(thick, y1 - yb, u1 - u0 + CityDistrict.SEAM)
			MissionProps.box_shape(body, inv * xf, Vector3.ZERO, sz)


## The calls that draw district d's walls, in CityDistrict's own order (one per side, a farm side in FARM_PARTS parts), so a
## rebuilt mesh is vertex for vertex the district's own (and exactly it again after teardown): [[side, part, parts]], or
## [[-1, 0, 1]] (all at once) when CityStreets.walls takes no parts.
static func _wall_parts(d: CityDistrict) -> Array:
	var takes_parts := false
	for m: Dictionary in (CityStreets as Script).get_script_method_list():
		if m["name"] == "walls" and (m["args"] as Array).size() >= 6:
			takes_parts = true
	if not takes_parts:
		return [[-1, 0, 1]]
	var parts := int((CityDistrict as Script).get_script_constant_map().get("FARM_PARTS", 1))
	var out := []
	for w: Dictionary in d.plan.boundary():
		var n := parts if w["kind"] == "farm" else 1
		for part in n:
			out.append([int(w["side"]), part, n])
	return out


static func _wall_part(geo: CityGeo, d: CityDistrict, lights: CityGeo, wp: Array) -> void:
	var walls := Callable(CityStreets, "walls")
	if int(wp[0]) < 0:
		walls.call(geo, d.plan, lights)
	else:
		walls.call(geo, d.plan, lights, int(wp[0]), int(wp[1]), int(wp[2]))


## One part of district d's walls re-meshed without the door leaves (CityStreets.walls reads the plan's "mission_doors"
## meta); the last part swaps the Walls mesh. The farm walls' light bars are left as they are (drawn into a throwaway
## geo: they never depend on the doors).
func _c_walls(d: CityDistrict, doors: Dictionary, wp: Array, first: bool, last: bool) -> void:
	if first:
		d.plan.set_meta("mission_doors", doors)
		_meta_decks.append(d)
		_wall_geo = CityGeo.new(d.ring)
	_wall_part(_wall_geo, d, CityGeo.new(d.ring), wp)
	if last:
		_swap_walls(d, _wall_geo)
		_wall_geo = null
		_walled.append(d)


## Rebuild district d's Walls mesh in one go (teardown: the plan's meta already removed).
func _rebuild_walls(d: CityDistrict) -> void:
	var geo := CityGeo.new(d.ring)
	for wp: Array in _wall_parts(d):
		_wall_part(geo, d, CityGeo.new(d.ring), wp)
	_swap_walls(d, geo)


func _swap_walls(d: CityDistrict, geo: CityGeo) -> void:
	var old := d.get_node_or_null("Walls") as MeshInstance3D
	if old == null:
		return
	var mi := MissionProps.mesh(geo, "Walls", d.render_layer)
	var idx := old.get_index()
	d.remove_child(old)
	old.queue_free()
	d.add_child(mi)
	d.move_child(mi, idx)


func _build_flag(o: Dictionary) -> void:
	var id: Variant = o.get("id")
	var d := _deck(o.get("deck", 0))
	if id == null or d == null:
		return
	var site: Dictionary = _sites[id] if _sites.has(id) else _site(o, d, FLAG_CLEAR)
	var mast := MissionProps.FlagMast.new()
	mast.name = "MissionFlag_%s" % str(id)
	mast.build(d, MissionProps.site_frame(d, float(site["x"]), float(site["s"]), float(site["h"])))
	d.add_child(mast)
	_flags[id] = mast
	if not _flag_state.has(id):
		_flag_state[id] = [false, false, -INF]
	var ring_geo := MissionProps.zone_ring(d, Vector2(float(site["x"]), float(site["s"])), float(o.get("radius", 14.0)))
	var zone := MissionProps.mesh(ring_geo, "MissionZone_%s" % str(id), d.render_layer)
	d.add_child(zone)
	_zones[id] = zone
	if not _zone_state.has(id):
		_zone_state[id] = "idle"
	_apply_zone(id)
	_pose_flag(id, now)


func _build_asset(o: Dictionary) -> void:
	var id: Variant = o.get("id")
	var d := _deck(o.get("deck", 0))
	if id == null or d == null:
		return
	var site: Dictionary = _sites[id] if _sites.has(id) else _site(o, d, ASSET_CLEAR)
	var a := MissionProps.RelayAsset.new()
	a.name = "MissionAsset_%s" % str(id)
	a.build(d, MissionProps.site_frame(d, float(site["x"]), float(site["s"]), float(site["h"])))
	a.body.add_to_group("mission_asset")
	a.body.set_meta("objective_id", id)
	d.add_child(a)
	_assets[id] = a
	if not _asset_hp.has(id):
		_asset_hp[id] = 1.0
	_asset_told[id] = 0
	_apply_asset(id)


func _site(o: Dictionary, d: CityDistrict, clear_r: float) -> Dictionary:
	var site: Dictionary = o.get("site", {})
	var at := Vector2(float(site.get("x", 0.0)), float(site.get("s", 0.0)))
	var avoid := []                  # the pieces already standing on this deck, with their clear radius
	for id: Variant in _sites:
		var o2: Dictionary = _sites[id]
		if int(o2["deck"]) == d.plan.deck:
			avoid.append([Vector2(float(o2["x"]), float(o2["s"])), float(o2["clear"])])
	var out := MissionProps.snap_site(d, at, snap_reach(o), clear_r, avoid)
	out["deck"] = d.plan.deck
	out["clear"] = clear_r
	_sites[o.get("id")] = out
	return out


## How far objective `o`'s site may move to clear ground: its record's `snap`, else MissionPlan.SNAP, else DEFAULT_SNAP.
static func snap_reach(o: Dictionary) -> float:
	if o.has("snap"):
		return maxf(float(o["snap"]), 0.0)
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if c["class"] == "MissionPlan":
			var v: Variant = (load(str(c["path"])) as Script).get_script_constant_map().get("SNAP")
			if v != null:
				return float(v)
	return DEFAULT_SNAP


func _build_hold(o: Dictionary) -> void:
	var d := _deck(o.get("deck", stack.section.extraction.get("deck", 0) if stack.section != null else 0))
	if d == null:
		return
	var params: Dictionary = o.get("params", {})
	var z: Variant = params.get("zone")
	if not z is Rect2:
		if stack.section == null:
			return
		z = MissionRules.extraction_zone(stack.section, 40.0)
	var geo := MissionProps.zone_rect(d, z)
	_hold = MissionProps.mesh(geo, "MissionHold", d.render_layer)
	d.add_child(_hold)
	_apply_hold()


## The portal frame in the extraction portal gate (SectionPlan.extraction: the spine's portal in the lowest deck's end wall).
func _build_portal() -> void:
	if stack.section == null:
		return
	var d := _deck(stack.section.extraction.get("deck", 0))
	if d == null:
		return
	var side := 3 if int(stack.section.extraction.get("j", 0)) == 0 else 2
	for w: Dictionary in d.plan.boundary():
		if int(w["side"]) != side:
			continue
		for g: Dictionary in w["gates"]:
			if str(g["kind"]) == "portal":
				_portal = MissionProps.Portal.new()
				_portal.name = "MissionPortal"
				_portal.build(d, w, g)
				d.add_child(_portal)
				_portal.pose(portal_progress)
				return


# --- Doors ---------------------------------------------------------------------------------------------------------------

## The state of a door at clock t from its schedule [open_at, close_at, prev_close_at] (empty: never opened) and the
## time it is sealed at (INF: never): [state, u] with state shut | warn | opening | open | closing | sealed and u 0..1
## through warn / opening / closing. A door open (or opening) at seal_at closes over CLOSE s from then, then is sealed;
## one already closing finishes its closing.
static func door_state(kind: String, sched: Array, seal_at: float, t: float) -> Array:
	if t >= seal_at:
		var then := door_state(kind, sched, INF, seal_at)
		match str(then[0]):
			"open", "opening":
				if t < seal_at + CLOSE:
					return ["closing", (t - seal_at) / CLOSE]
			"closing":
				var left := (1.0 - float(then[1])) * CLOSE
				if t < seal_at + left:
					return ["closing", float(then[1]) + (t - seal_at) / CLOSE]
		return ["sealed", 1.0]
	if sched.is_empty():
		return ["shut", 0.0]
	var oa := float(sched[0])
	var ca := float(sched[1])
	var pca := float(sched[2])
	var t_open := GATE_OPEN if kind == "gate" else LIFT_OPEN
	if t < oa - WARN:
		if t < pca:
			return ["open", 1.0]
		if t < pca + CLOSE:
			return ["closing", (t - pca) / CLOSE]
		return ["shut", 0.0]
	if t < oa - t_open:
		return ["warn", (t - (oa - WARN)) / (WARN - t_open)]
	if t < oa:
		return ["opening", (t - (oa - t_open)) / t_open]
	if t < ca:
		return ["open", 1.0]
	if t < ca + CLOSE:
		return ["closing", (t - ca) / CLOSE]
	return ["shut", 0.0]


## Schedule wave source `id` to open at `open_at` (shared clock): the telegraph starts WARN s before; the door stays open
## `hold` s after open_at, then closes over CLOSE s. Called again while the door is due to be open (the new open_at is not
## after the current close time): only the hold is extended (the earlier open_at stays, no second warning). Ramp / shaft /
## unknown ids are accepted and do nothing; a sealed source stays sealed.
func open_source(id: Variant, open_at: float, hold: float = HOLD) -> void:
	if not setup_ready:
		return
	if _sealed.has(id) or not _sources.has(id):
		return
	var kind := str(_sources[id].get("kind", ""))
	if kind != "gate" and kind != "lift":
		return
	var close_at := open_at + maxf(hold, 0.0)
	if _sched.has(id):
		var sc: Array = _sched[id]
		if open_at <= float(sc[1]):
			if close_at > float(sc[1]):
				sc[1] = close_at
				(_fired[id] as Dictionary)["close"] = false
			_next = -INF
			return
		_sched[id] = [open_at, close_at, float(sc[1])]
	else:
		_sched[id] = [open_at, close_at, -INF]
	_fired[id] = {"warn": false, "open": false, "close": false, "seal": bool(_fired.get(id, {}).get("seal", false))}
	_next = -INF


## Keep source `id` open until at least `until_t` (no effect on a source never opened, or sealed).
func hold_source(id: Variant, until_t: float) -> void:
	if not setup_ready:
		return
	if _sealed.has(id) or not _sched.has(id):
		return
	var sc: Array = _sched[id]
	if until_t > float(sc[1]):
		sc[1] = until_t
		(_fired[id] as Dictionary)["close"] = false
		_next = -INF


## Close source `id` for good at clock time `at` (default: the current clock): scheduled like open_at, so a late call
## snaps. Open then: it closes over CLOSE s first. Then sealed (welded, scorched, beacon dead), solid, final; "seal" fires
## once at `at`. A second call does nothing.
func close_source(id: Variant, at: float = NAN) -> void:
	if not setup_ready:
		return
	if _sealed.has(id) or not _sources.has(id):
		return
	var kind := _door_kind(id)
	if kind != "gate" and kind != "lift":
		return
	_sealed[id] = now if is_nan(at) else at
	if not _fired.has(id):
		_fired[id] = {"warn": true, "open": true, "close": true}
	(_fired[id] as Dictionary)["seal"] = false
	_next = -INF


func _seal_at(id: Variant) -> float:
	return float(_sealed.get(id, INF))


## {state, t (when this state began, -INF if always), open_at, close_at} of source `id` at the current clock.
func source_state(id: Variant) -> Dictionary:
	var kind := str(_sources.get(id, {}).get("kind", ""))
	var sc: Array = _sched.get(id, [])
	var st := door_state(kind, sc, _seal_at(id), now)
	var began := -INF
	if str(st[0]) == "sealed":
		began = _seal_at(id)
	elif not sc.is_empty() and now < _seal_at(id):
		var oa := float(sc[0])
		var ca := float(sc[1])
		var t_open := GATE_OPEN if kind == "gate" else LIFT_OPEN
		match str(st[0]):
			"warn": began = oa - WARN
			"opening": began = oa - t_open
			"open": began = oa if now >= oa else -INF
			"closing": began = ca if now >= ca else float(sc[2])
			"shut": began = ca + CLOSE if now >= ca + CLOSE else (float(sc[2]) + CLOSE if float(sc[2]) > -INF else -INF)
	return {"state": st[0], "t": began, "open_at": float(sc[0]) if not sc.is_empty() else INF,
			"close_at": float(sc[1]) if not sc.is_empty() else INF}


## Where units of source `id` should appear, {deck, x, s} in its deck's arc coordinates, for every kind ({} for unknown
## ids): a gate with its door, the door's recess (3 m behind the wall plane, mid-gate: hidden by the leaves until they
## open, held in by the door's collision until open_at); every other source (lift, ramp, shaft, a gate without a door) the
## plan's point (a lift's lobby: the core is solid, so lift units step out in sight as the doors open).
func source_point(id: Variant) -> Dictionary:
	if not _sources.has(id):
		return {}
	var s: Dictionary = _sources[id]
	var k := int(s.get("deck", 0))
	if not _doors.get(id) is MissionProps.GateDoor:
		return {"deck": k, "x": float(s.get("x", 0.0)), "s": float(s.get("s", 0.0))}
	var door := _doors[id] as Node3D
	var d := _deck(k)
	var local := door.transform * Vector3(0, 0, GATE_POINT)
	var a := d.ring.world_to_arc(local)
	return {"deck": k, "x": a.x, "s": a.y}


func _door_kind(id: Variant) -> String:
	return str(_sources.get(id, {}).get("kind", ""))


## Pose door `id` at t; fire its signals as their moments pass; returns true while it needs posing every frame.
func _pose_door(id: Variant, t: float, force: bool = false, fire: bool = true) -> bool:
	var kind := _door_kind(id)
	var sc: Array = _sched.get(id, [])
	var st := door_state(kind, sc, _seal_at(id), t)
	var state := str(st[0])
	var door: Node3D = _doors.get(id)
	if door != null and is_instance_valid(door):
		var changed: bool = force or _door_state.get(id, "") != state
		if door is MissionProps.GateDoor:
			var gd := door as MissionProps.GateDoor
			gd.pose(state, float(st[1]), t)
			if changed:
				gd.door_shape.disabled = not gd.blocks(state)
		elif door is MissionProps.LiftDoor:
			(door as MissionProps.LiftDoor).pose(state, float(st[1]), float(sc[0]) - t if not sc.is_empty() else 0.0)
		_light(id, door, kind, state == "warn" or state == "opening")
	_door_state[id] = state
	if fire:
		_fire_door(id, sc, t)
	return state == "warn" or state == "opening" or state == "closing"


func _fire_door(id: Variant, sc: Array, t: float) -> void:
	if not _fired.has(id):
		return
	var f: Dictionary = _fired[id]
	var moments := []
	var seal := _seal_at(id)
	if seal < INF:
		moments.append(["seal", seal])
	if not sc.is_empty():
		for m: Array in [["warn", float(sc[0]) - WARN], ["open", float(sc[0])], ["close", float(sc[1])]]:
			if float(m[1]) < seal:
				moments.append(m)
	for m: Array in moments:
		var key := str(m[0])
		if bool(f.get(key, false)) or t < float(m[1]):
			continue
		f[key] = true
		if t - float(m[1]) <= EVENT_STALE:
			source_event.emit(key, id, _door_point(id))


func _door_point(id: Variant) -> Vector3:
	var door: Node3D = _doors.get(id)
	if door != null and is_instance_valid(door):
		return door.call("world_point")
	var s: Dictionary = _sources.get(id, {})
	if stack != null and not stack.decks.is_empty():
		return stack.from_deck_arc(int(s.get("deck", 0)), float(s.get("x", 0.0)), float(s.get("s", 0.0)), 4.0)
	return Vector3.ZERO


## One small OmniLight3D per door while it warns (none at CityQuality.LOW), removed afterwards.
func _light(id: Variant, door: Node3D, kind: String, on: bool) -> void:
	on = on and quality != CityQuality.LOW
	var l: OmniLight3D = _lights.get(id)
	if on and l == null:
		l = OmniLight3D.new()
		l.name = "WarnLight"
		l.light_color = CityPalette.C["m_beacon"]
		l.light_energy = 2.5
		l.omni_range = 16.0
		l.shadow_enabled = false
		var d := door.get_parent() as CityDistrict
		if d != null:
			l.light_cull_mask = d.render_layer | 1
		var gh := (door as MissionProps.GateDoor).gh if door is MissionProps.GateDoor else MissionProps.LiftDoor.H
		l.position = Vector3(0, gh + 2.5, 3.0)
		door.add_child(l)
		_lights[id] = l
	elif not on and l != null:
		if is_instance_valid(l):
			l.queue_free()
		_lights.erase(id)


# --- Flag, zones, asset, portal ------------------------------------------------------------------------------------------

## Where flag objective `id` stands: {deck, x, s, h, snapped, ok} ({} for unknown ids). ok = false: no clear ground inside
## the radius, the plan's site kept.
func flag_site(id: Variant) -> Dictionary:
	return (_sites.get(id, {}) as Dictionary).duplicate() if _flags.has(id) else {}


## Where defend objective `id`'s relay stands (as flag_site).
func asset_site(id: Variant) -> Dictionary:
	return (_sites.get(id, {}) as Dictionary).duplicate() if _assets.has(id) else {}


## The relay's collision body (group "mission_asset", meta objective_id) for Weapons to register as a damageable target.
func asset_body(id: Variant) -> StaticBody3D:
	var a: MissionProps.RelayAsset = _assets.get(id)
	return a.body if a != null else null


## Swap flag `id` to ours (raised) or the alien banner, animated over FLAG_SWAP s from `at` (default: the current clock).
func set_flag(id: Variant, raised: bool, at: float = -1.0) -> void:
	if not setup_ready:
		return
	if not _flags.has(id):
		return
	var fs: Array = _flag_state[id]
	if bool(fs[0]) == raised:
		return
	_flag_state[id] = [raised, bool(fs[0]), now if at < 0.0 else at]
	flag_event.emit(id, raised, (_flags[id] as MissionProps.FlagMast).world_point())
	_next = -INF
	_pose_flag(id, now)


func flag_raised(id: Variant) -> bool:
	return bool((_flag_state.get(id, [false]) as Array)[0])


func _pose_flag(id: Variant, t: float) -> bool:
	var fs: Array = _flag_state[id]
	var u := clampf((t - float(fs[2])) / FLAG_SWAP, 0.0, 1.0)
	(_flags[id] as MissionProps.FlagMast).pose(bool(fs[0]), bool(fs[1]), u)
	return u < 1.0


const ZONE_MAT := {"idle": ["m_zone", 0.6], "contested": ["m_hostile", 1.6], "ours": ["m_ours", 1.6]}
const HOLD_MAT := {"idle": ["m_zone", 0.6], "holding": ["m_ours", 1.6], "contested": ["m_hostile", 1.6], "done": ["m_done", 1.6]}


## The flag zone ring's colour: idle (pale), contested (red), ours (orange).
func set_zone(id: Variant, state: String) -> void:
	if not setup_ready:
		return
	if not _zones.has(id) or not ZONE_MAT.has(state):
		return
	_zone_state[id] = state
	_apply_zone(id)


func _apply_zone(id: Variant) -> void:
	var m: Array = ZONE_MAT[_zone_state[id]]
	(_zones[id] as MeshInstance3D).material_override = MissionProps.glow(m[0], m[1])


## The relay's look from its health 0..1 (> 0.5 intact, <= 0.5 damaged, 0 wreck). Look only: no HP is held here.
func set_asset(id: Variant, hp: float) -> void:
	if not setup_ready:
		return
	if not _assets.has(id):
		return
	_asset_hp[id] = clampf(hp, 0.0, 1.0)
	_apply_asset(id)


static func asset_level(hp: float) -> int:
	return 2 if hp <= 0.0 else (1 if hp <= 0.5 else 0)


func _apply_asset(id: Variant) -> void:
	var a: MissionProps.RelayAsset = _assets[id]
	var lv := asset_level(float(_asset_hp[id]))
	a.look(lv, quality != CityQuality.LOW, a.get_parent().get("render_layer") if a.get_parent() != null else 1)
	a.blink(_blink_on)
	var told := int(_asset_told.get(id, 0))
	if lv >= 1 and told < 1:
		asset_event.emit(id, "damaged", a.world_point())
	if lv >= 2 and told < 2:
		asset_event.emit(id, "destroyed", a.world_point())
	_asset_told[id] = maxi(told, lv)


## The extraction portal's charge 0..1 (segments light up, the curtain brightens; dark at 0, fully lit at 1).
func set_portal(progress: float) -> void:
	if not setup_ready:
		return
	portal_progress = clampf(progress, 0.0, 1.0)
	if _portal != null:
		_portal.pose(portal_progress)
	var at := _portal.world_point() if _portal != null else Vector3.ZERO
	if portal_progress > 0.0 and _portal_told < 1:
		_portal_told = 1
		portal_event.emit("start", at)
	if portal_progress >= 1.0 and _portal_told < 2:
		_portal_told = 2
		portal_event.emit("open", at)


## The extraction hold zone's colour: idle, holding (orange), contested (red), done (green).
func set_hold_zone(state: String) -> void:
	if not setup_ready:
		return
	if not HOLD_MAT.has(state):
		return
	hold_state = state
	_apply_hold()


func _apply_hold() -> void:
	if _hold != null:
		var m: Array = HOLD_MAT[hold_state]
		_hold.material_override = MissionProps.glow(m[0], m[1])


# --- Clock -----------------------------------------------------------------------------------------------------------------

## The shared mission clock: pose everything that moves at t and fire what t has passed. Nothing to do (one comparison)
## until the next scheduled moment while nothing animates.
func advance_to(t: float) -> void:
	if not setup_ready:
		return
	if t >= now and t < _next:
		now = t
		return
	now = t
	var next := INF
	for id: Variant in _sched:
		if _pose_door(id, t):
			next = t
		else:
			next = minf(next, _next_moment(id, t))
	for id: Variant in _sealed:
		if not _sched.has(id):
			if _pose_door(id, t):
				next = t
			else:
				next = minf(next, _next_moment(id, t))
	for id: Variant in _flags:
		if _pose_flag(id, t):
			next = t
	if not _assets.is_empty():
		var phase := fposmod(t, BLINK)
		var on := phase < BLINK * 0.6
		if on != _blink_on:
			_blink_on = on
			for id: Variant in _assets:
				(_assets[id] as MissionProps.RelayAsset).blink(on)
		next = minf(next, t - phase + (BLINK * 0.6 if on else BLINK))
	_next = next


## The next moment after t at which door `id` changes state (INF: never).
func _next_moment(id: Variant, t: float) -> float:
	var seal := _seal_at(id)
	var ms: Array[float] = [seal, seal + CLOSE]
	var sc: Array = _sched.get(id, [])
	if not sc.is_empty() and t < seal:
		var t_open := GATE_OPEN if _door_kind(id) == "gate" else LIFT_OPEN
		ms.append_array([float(sc[2]), float(sc[2]) + CLOSE, float(sc[0]) - WARN, float(sc[0]) - t_open, float(sc[0]), float(sc[1]),
				float(sc[1]) + CLOSE])
	var best := INF
	for m in ms:
		if m > t and m < best:
			best = m
	return best


# --- Quality, snapshot ------------------------------------------------------------------------------------------------------

## CityQuality level (local presentation): LOW drops the warning lights and the relay's particles.
func set_quality(q: int) -> void:
	quality = CityQuality.clamp_level(q)
	for id: Variant in _doors:
		_light(id, _doors[id], _door_kind(id), _door_state.get(id, "") == "warn" or _door_state.get(id, "") == "opening")
	for id: Variant in _assets:
		_apply_asset(id)


## Everything a late joiner needs, in one message: door schedules, the sealed set, flags, zones, asset health, portal and
## hold zone, and the clock it was taken at.
func snapshot() -> Dictionary:
	var doors := {}
	for id: Variant in _sched:
		doors[id] = (_sched[id] as Array).duplicate()
	var flags := {}
	for id: Variant in _flag_state:
		flags[id] = (_flag_state[id] as Array).duplicate()
	return {"now": now, "doors": doors, "sealed": _sealed.duplicate(), "flags": flags, "zones": _zone_state.duplicate(),
			"assets": _asset_hp.duplicate(), "portal": portal_progress, "hold": hold_state}


## Take a snapshot() and show its state at its clock (no signal replays for moments already past).
func restore(d: Dictionary) -> void:
	if not setup_ready:
		return
	now = float(d.get("now", now))
	_sched.clear()
	_fired.clear()
	var doors: Dictionary = d.get("doors", {})
	for id: Variant in doors:
		if _sources.has(id):
			_sched[id] = (doors[id] as Array).duplicate()
			_fired[id] = {"warn": true, "open": true, "close": true, "seal": true}
			var sc: Array = _sched[id]
			for pair: Array in [["warn", float(sc[0]) - WARN], ["open", float(sc[0])], ["close", float(sc[1])]]:
				(_fired[id] as Dictionary)[pair[0]] = now >= float(pair[1])
	_sealed.clear()
	var sealed: Variant = d.get("sealed", {})
	var at_of := {}                  # {id: seal_at}; an older array of ids means sealed since forever
	if sealed is Dictionary:
		at_of = sealed
	else:
		for id: Variant in sealed:
			at_of[id] = -INF
	for id: Variant in at_of:
		if _sources.has(id):
			_sealed[id] = float(at_of[id])
			if not _fired.has(id):
				_fired[id] = {"warn": true, "open": true, "close": true}
			(_fired[id] as Dictionary)["seal"] = now >= float(at_of[id])
	var flags: Dictionary = d.get("flags", {})
	for id: Variant in flags:
		if _flags.has(id):
			_flag_state[id] = (flags[id] as Array).duplicate()
	var zones: Dictionary = d.get("zones", {})
	for id: Variant in zones:
		set_zone(id, str(zones[id]))
	var assets: Dictionary = d.get("assets", {})
	for id: Variant in assets:
		if _assets.has(id):
			_asset_hp[id] = clampf(float(assets[id]), 0.0, 1.0)
			_asset_told[id] = asset_level(float(_asset_hp[id]))
			_apply_asset(id)
	portal_progress = clampf(float(d.get("portal", portal_progress)), 0.0, 1.0)
	_portal_told = 2 if portal_progress >= 1.0 else (1 if portal_progress > 0.0 else 0)
	if _portal != null:
		_portal.pose(portal_progress)
	set_hold_zone(str(d.get("hold", hold_state)))
	for id: Variant in _doors:
		_pose_door(id, now, true)
	for id: Variant in _flags:
		_pose_flag(id, now)
	_next = -INF


# --- A stand-in plan (lab, tests) -------------------------------------------------------------------------------------------

## A Dictionary with MissionPlan's fields (§9) for stack st, until MissionPlan is usable: a gate source at every blast-door
## gate of every deck (on the gate's road line, SOURCE_IN m inside the wall, `edge` named), a lift source at every stop of
## every freight lift (the platform centre moved toward the spine by the pillar radius + 4 m, `connector` named), one flag
## on the top deck, one defend relay on the second, and the extraction hold.
static func stand_in_plan(st: CityStack) -> Dictionary:
	var sources := []
	var sec := st.section
	for k in st.decks.size():
		var d := st.decks[k]
		for w: Dictionary in d.plan.boundary():
			var side := int(w["side"])
			var inward := -1.0 if side % 2 == 0 else 1.0
			for g: Dictionary in w["gates"]:
				if str(g["kind"]) != "blast_door":
					continue
				var mid := (float(g["a"]) + float(g["b"])) * 0.5
				var at := float(w["at"]) + inward * SOURCE_IN
				var x := mid if side >= 2 else at
				var s := at if side >= 2 else mid
				var tw := Vector2(x, s) + (Vector2(0, inward) if side >= 2 else Vector2(inward, 0)) * 20.0
				sources.append({"id": "g%d_%d_%d" % [k, side, sources.size()], "deck": k, "kind": "gate", "x": x, "s": s,
						"toward": {"x": tw.x, "s": tw.y}, "load": 4, "edge": CityPlan.SIDE_EDGE[side], "connector": -1})
	if sec != null:
		var av := sec.lane_x("avenue")
		var spine := (av.x + av.y) * 0.5
		for ci in sec.connectors.size():
			var cn: Dictionary = sec.connectors[ci]
			if cn["kind"] != "lift" or int(cn["pillar"]) < 0:
				continue
			for k: int in cn["stops"]:
				var at := sec.pillar_point(k, int(cn["pillar"]))
				var dir := signf(spine - at.x)
				var x := at.x + dir * (sec.pillar_radius(k, int(cn["pillar"])) + 4.0)
				sources.append({"id": "l%d_%d" % [k, ci], "deck": k, "kind": "lift", "x": x, "s": at.y,
						"toward": {"x": x + dir * 20.0, "s": at.y}, "load": 3, "edge": "", "connector": ci})
	var objectives := []
	if not st.decks.is_empty():
		objectives.append({"id": "flag0", "type": "flag", "deck": 0, "role": "primary", "site": _stand_in_site(st, 0, 0),
				"radius": 14.0, "needs": [], "params": {"hold": 20.0}})
		var kd := mini(1, st.decks.size() - 1)
		objectives.append({"id": "defend1", "type": "defend", "deck": kd, "role": "primary", "site": _stand_in_site(st, kd, 1),
				"radius": 14.0, "needs": [], "params": {"waves": 2, "asset_hp": 1.0}})
		if sec != null:
			objectives.append({"id": "hold", "type": "hold", "deck": int(sec.extraction["deck"]), "role": "primary",
					"site": {}, "radius": 0.0, "needs": ["flag0", "defend1"],
					"params": {"zone": MissionRules.extraction_zone(sec, 40.0), "time": 60.0}})
	return {"sources": sources, "objectives": objectives, "pools": []}


## A plaza near the middle of deck k (the n-th open plaza lot from the centre), else the deck's centre.
static func _stand_in_site(st: CityStack, k: int, n: int) -> Dictionary:
	var d := st.decks[k]
	var lots := []
	for l: Dictionary in d.plan.lots:
		if str(l["open"]) == "plaza":
			var c := (l["rect"] as Rect2).get_center()
			lots.append([c.length(), c.x, c.y])
	lots.sort()
	if lots.is_empty():
		return {"x": 0.0, "s": 0.0}
	var pick: Array = lots[mini(n, lots.size() - 1)]
	return {"x": float(pick[1]), "s": float(pick[2])}
