class_name MissionWorld
extends Node3D
## The world side of mission objectives phase 1 (docs/design/mission-objectives.md §5.6 / §7 / §9; this side:
## docs/design/city-ramps-and-stack.md "Mission world (phase 1)"): wave doors in road-door gates and freight lifts, the
## entry and exit road doors with their bays (entry_door / exit_door), the tram doors (tram_door / set_tram_door), the
## flag mast and its zone ring, the defend relay and the extraction hold zone. Made by CityStack.setup_mission(plan) once
## the stack is built (stack.mission; freed when the stack rebuilds). The bulkhead fiction (docs/design/city-spine.md §1):
## every road door is shut for the whole mission (lockdown); waves come through some of them from the far side; the crew
## comes in through the entry door and leaves through the exit door; the tram doors stay open (the train runs only while
## its door is open). Every road door looks the same: nothing on a door marks its role.
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
## A tram door was ordered open / shut at clock `at` (set_tram_door; also sent to AmbientLife.set_tram_door when the
## scene has one): the life side's train link listens to whichever it can reach.
signal tram_door_changed(end: String, open: bool, at: float)

## The entry / exit road doors and the tram doors (ids usable with source_state, open_source / hold_source / close_source
## for the road doors; set_tram_door for the tram doors). Never wave sources: MissionPlan's sources never name them.
const ENTRY_ID := "door_entry"
const EXIT_ID := "door_exit"
const TRAM_IDS := {"s0": "tram_s0", "s1": "tram_s1"}
## Until Missions opens the entry door at the mission's release, the door opens at setup time (clock 0: the leaves start
## to move, passable OPENING s later) and stays open, so nobody spawned in the entry bay is ever locked in (lab, tests, a
## mission that never orders it). Missions overrides it any time: shut_source(ENTRY_ID, t) closes it at t (not sealed),
## open_source(ENTRY_ID, t, hold) opens it again. The exit door is shut by default.
const ENTRY_OPEN_DEFAULT := true

## TIMING (docs/design/city-ramps-and-stack.md "Staging bay"): open_at is the moment the leaves START to move. A gate's
## siren, lamps and beacons run while its leaves open (open_at .. open_at + OPENING); it is passable (fully open) from
## open_at + OPENING (passable_after) and stays open `hold` s, then closes over CLOSE s.
const WARN := 5.0            ## s of the silent "warn" state before open_at (the "warn" signal; nothing shows on a lift: its doors move at open_at)
const OPENING := 3.0         ## s a gate's leaves take to open, from open_at (the reveal; the siren runs exactly this long)
const LIFT_OPEN := 1.5       ## s the lift doors take, from open_at
const CLOSE := 2.0           ## s either takes to close
const ALARM_LEAD := 0.0      ## s of siren before the leaves start to move (0: the siren is the opening signal; an order given earlier starts it at most this long before open_at)
const HOLD := 12.0           ## default s fully open (after the opening)
const FLAG_SWAP := 2.0       ## s of the banner swap
const EVENT_STALE := 1.5     ## s: a scheduled moment older than this when first seen fires no signal
const BLINK := 1.2           ## s period of the relay's band (on 60 %)
const SOURCE_IN := 8.0       ## m inside the wall Missions puts a gate source (docs: where a source point lies)
const GATE_POINT := -16.0    ## m along the gate frame's +Z source_point() gives: the staging bay's floor centre (hidden while shut)
const EXIT := 6.0            ## m in front of a gate's door source_bay().exit lies (on the street)
const AIR_HIDE := 7.0        ## m behind the wall plane air_door().hide lies
const AIR_OUT := 8.0         ## m in front of the opening air_door().out lies
const FLAG_CLEAR := 2.5      ## m clear round a flag mast (snap)
const ASSET_CLEAR := 3.5     ## m clear round the relay (snap)
const DEFAULT_SNAP := 45.0   ## m a site may move to clear ground when neither the record nor MissionPlan says

var stack: CityStack
var plan: Variant                ## the MissionPlan (or a Dictionary with its fields)
var now := 0.0                   ## the last advance_to time
var quality := GraphicsQuality.HIGH

var _sources := {}               ## id -> {id, deck, kind, x, s, edge, connector}, as given (and the air doors, kind "air")
var _air := {}                   ## deck -> [air door source ids], derived from the stack (MissionAirDoors.spot), in boundary order
var _doors := {}                 ## id -> MissionGateDoor / MissionLiftDoor (gate / lift sources that found their door)
var _sched := {}                 ## id -> [open_at, close_at, prev_close_at, alarm_from] (alarm_from: gates' alarm, see alarm_from())
var _sealed := {}                ## id -> the clock time it is sealed at
var _fired := {}                 ## id -> {warn, open, close, seal: bool}
var _door_state := {}            ## id -> last state posed
var _lights := {}                ## id -> OmniLight3D while warning
var _flags := {}                 ## id -> MissionFlagMast
var _flag_state := {}            ## id -> [raised, from, t0]
var _sites := {}                 ## objective id -> {deck, x, s, h, snapped, ok, fit, moved_for_fit, clear}
var _zones := {}                 ## objective id -> MeshInstance3D (flag zone ring)
var _zone_state := {}            ## objective id -> "idle" | "contested" | "ours"
var _assets := {}                ## objective id -> MissionRelayAsset
var _asset_hp := {}              ## objective id -> 0..1
var _asset_told := {}            ## objective id -> worst event sent (0 none, 1 damaged, 2 destroyed)
var portal_progress := 0.0       ## DEPRECATED (set_portal's stored value; nothing shows it): goes when Missions drops set_portal
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
var _wall_doors := {}            ## district -> the gates its rebuilt walls leave for wave doors, {"<side>:<a>": true} (wall_doors())
var _lift_meshes := {}           ## block MeshInstance3D -> its original mesh (a lift car hid the baked shut doors in it: MissionLiftDoor.hide_fill)


func net_fields() -> Dictionary:
	return {
		"stack": Net.SPAWN, "plan": Net.SPAWN,          # from the section and mission seeds, the same on every machine
		"_sources": Net.SPAWN, "_sites": Net.SPAWN,     # derived from the plan (snap rule: plan data only)
		"_air": Net.SPAWN,                              # derived from the stack's plans (MissionAirDoors.spot: plan data only)
		# The host decides these; Engine carries them (wave orders, mission.state) and restores a late joiner with snapshot()
		"_sched": Net.OWNER, "_sealed": Net.OWNER, "_flag_state": Net.OWNER, "_zone_state": Net.OWNER,
		"_asset_hp": Net.OWNER, "hold_state": Net.OWNER,
		# (_sched also holds the entry / exit and tram doors' schedules: set_tram_door is a host-arbitrated world object, its
		# changes stored as times on the shared clock like every door order; snapshot() / restore() carry them)
		"now": Net.LOCAL,                                # the shared clock
		"portal_progress": Net.LOCAL,                    # deprecated: set on every machine by MissionFlow's own replicated state, shows nothing
		"quality": Net.LOCAL, "_doors": Net.LOCAL, "_fired": Net.LOCAL, "_door_state": Net.LOCAL, "_lights": Net.LOCAL,
		"_flags": Net.LOCAL, "_zones": Net.LOCAL, "_assets": Net.LOCAL, "_asset_told": Net.LOCAL,
		"_hold": Net.LOCAL, "_cut": Net.LOCAL, "_walled": Net.LOCAL, "_next": Net.LOCAL,
		"_blink_on": Net.LOCAL, "setup_ready": Net.LOCAL, "chunk_log": Net.LOCAL, "_queue": Net.LOCAL, "_qi": Net.LOCAL,
		"_b_us": Net.LOCAL, "_wall_geo": Net.LOCAL, "_wall_doors": Net.LOCAL, "_lift_meshes": Net.LOCAL,
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
## objective its site search and its build, the hold zone. chunk_log = [[label, ms], ...]. Until setup_ready every
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
	# The entry / exit road doors (gates with a role) and the tram doors: from the stack's plans (CityPlan.boundary()),
	# never from the mission plan's sources (they are no wave sources).
	for k in (stack.decks.size() if stack != null else 0):
		var d := stack.decks[k]
		for w: Dictionary in d.plan.boundary():
			var side := int(w["side"])
			for g: Dictionary in w["gates"]:
				var role := str(g.get("role", ""))
				var tram := str(g["kind"]) == "tram_door"
				if not tram and (str(g["kind"]) != "blast_door" or (role != "entry" and role != "exit")):
					continue
				var id: String = (ENTRY_ID if role == "entry" else EXIT_ID) if not tram else str(TRAM_IDS.get(CityPlan.SIDE_EDGE[side], ""))
				if id == "" or _sources.has(id):
					continue
				var key := "%d:%.2f" % [side, float(g["a"])]
				if used.has([d, key]):
					continue
				used[[d, key]] = true
				if not per_deck.has(d):
					per_deck[d] = {}
					decks.append(d)
				per_deck[d][key] = true
				var mid := (float(g["a"]) + float(g["b"])) * 0.5
				var inward := -1.0 if side % 2 == 0 else 1.0
				var at := float(w["at"]) + inward * SOURCE_IN
				_sources[id] = {"id": id, "deck": k, "kind": "tram" if tram else "gate", "role": role if not tram else "tram",
						"x": mid if side >= 2 else at, "s": at if side >= 2 else mid, "edge": CityPlan.SIDE_EDGE[side], "connector": -1}
				_queue.append(["door %s" % id, (_c_tram if tram else _c_gate).bind(id, d, {"w": w, "g": g})])
	# Air doors: derived from the stack's plans (not the mission plan), one per end wall where a spot passes MissionAirDoors.spot().
	var air_holes := {}       # district -> {side: [hole]}
	for k in (stack.decks.size() if stack != null else 0):
		var d := stack.decks[k]
		var ids: Array = []
		for ad: Dictionary in MissionAirDoors.doors(d.plan):
			var w: Dictionary = ad["wall"]
			var c := float(ad["c"])
			var id := "air_d%d_%d" % [k, ids.size()]
			ids.append(id)
			var side := int(w["side"])
			var at := float(w["at"])
			var inward := -1.0 if side % 2 == 0 else 1.0
			_sources[id] = {"id": id, "deck": k, "kind": "air", "x": c, "s": at + inward * 8.0, "edge": CityPlan.SIDE_EDGE[side],
					"u": c, "usable": bool(ad["usable"]), "clear_len": float(ad["clear_len"])}
			if not air_holes.has(d):
				air_holes[d] = {}
			if not per_deck.has(d):
				per_deck[d] = {}
				decks.append(d)
			var holes: Array = air_holes[d].get(side, [])
			holes.append(MissionAirDoors.hole(c))
			air_holes[d][side] = holes
			_queue.append(["air %s" % id, _c_air.bind(id, d, w, c)])
		_air[k] = ids
	for d in decks:
		var parts := _wall_parts(d)
		for i in parts.size():
			_queue.append(["walls d%d %d/%d" % [d.plan.deck, i + 1, parts.size()],
					_c_walls.bind(d, per_deck[d], parts[i], i == 0, i == parts.size() - 1, air_holes.get(d, {}))])
	_queue.append(["pose doors", _c_pose_doors])
	# The fit rule's reachability mask, one chunk per deck that has a flag / defend site (none elsewhere; cached on the plan).
	var fit_decks := {}
	for o: Variant in field(plan, "objectives", []):
		if o is Dictionary and str((o as Dictionary).get("type", "")) in ["flag", "defend"]:
			var fd := _deck((o as Dictionary).get("deck", 0))
			if fd != null and not fit_decks.has(fd):
				fit_decks[fd] = true
				_queue.append(["fit d%d" % fd.plan.deck, _c_fit.bind(fd)])
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
	_queue.append(["finish", _c_finish])


func _c_gate(id: Variant, d: CityDistrict, hit: Dictionary) -> void:
	var door := MissionGateDoor.new()
	door.name = "MissionGate_%s" % str(id)
	_fit(door, hit["w"], hit["g"])
	door.build(d, hit["w"], hit["g"], _look(id), bay_span(d, hit["w"], hit["g"]))
	d.add_child(door)
	_doors[id] = door
	_cut_wall(d, hit["w"], hit["g"], door.body)


## A tram door: the road door at the tram door's size (MissionGateDoor.tram_config), no bay (the world's tunnel behind
## it, open in the district's wall collision: no cut).
func _c_tram(id: Variant, d: CityDistrict, hit: Dictionary) -> void:
	var door := MissionGateDoor.new()
	door.name = "MissionTram_%s" % str(id)
	door.tram_config(float(hit["g"]["h"]))
	_fit(door, hit["w"], hit["g"])
	door.pier_side = 0
	door.build(d, hit["w"], hit["g"], _look(id))
	d.add_child(door)
	_doors[id] = door


## Set door's neighbour fit (door_fit) before its build.
static func _fit(door: MissionGateDoor, w: Dictionary, g: Dictionary) -> void:
	var f := door_fit(w, g, door.jamb, door.butt)
	door.reach_lo = float(f["reach_lo"])
	door.reach_hi = float(f["reach_hi"])
	door.pier_side = int(f["pier"])
	door.slide = int(f["slide"])


## The frame X direction (+1 / -1) of increasing wall coordinate u on side `side` (MissionGateDoor.arc_x).
static func _u_to_x(side: int) -> float:
	return 1.0 if side == 0 or side == 3 else -1.0


## How gate g of wall w fits beside the other gates on its wall (plan data only), in its frame's X: {reach_lo, reach_hi
## (m from mid-gate the bunker frame may reach on -X / +X: INF, or the midpoint between this opening and a neighbour's
## when both full frames would overlap), pier (the sign pier's side: +1 unless a neighbour's frame stands within its
## reach there, then -1, 0 when both sides are taken), slide (0: the leaves part; +-1: both slide to that side because
## the other side's leaf pocket, 2 x half + 0.3 m from mid-gate inside the wall, would cross a neighbour's gate)}.
## j / b: this door's jamb and buttress (scaled for a tram door); a neighbour's are its own kind's.
static func door_fit(w: Dictionary, g: Dictionary, j: float = MissionGateDoor.JAMB, b: float = MissionGateDoor.BUTT) -> Dictionary:
	var sx := _u_to_x(int(w["side"]))
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	var ch := CityWalls.clear_half(g)
	var reach := [INF, INF]          # u- side, u+ side
	var pier_ok := [true, true]
	var pocket_ok := [true, true]
	var std := ch + j + b
	for g2: Dictionary in w["gates"]:
		if g2 == g or is_equal_approx(float(g2["a"]), float(g["a"])):
			continue
		var mid2 := (float(g2["a"]) + float(g2["b"])) * 0.5
		var ch2 := CityWalls.clear_half(g2)
		var s2 := 1.0 if str(g2["kind"]) != "tram_door" else float(g2["h"]) / MissionGateDoor.ROAD_H
		var std2 := ch2 + (MissionGateDoor.JAMB + MissionGateDoor.BUTT) * s2
		var up := mid2 > mid
		var i := 1 if up else 0
		var dist := absf(mid2 - mid)
		if dist < std + std2:          # the full frames would overlap: both stop at the middle of the wall between the openings
			reach[i] = minf(reach[i], ch + (dist - ch - ch2) * 0.5)
		if dist - std2 < MissionGateDoor.pier_reach_for(ch, j, b) + 0.5:
			pier_ok[i] = false
		var edge2 := dist - (float(g2["b"]) - float(g2["a"])) * 0.5      # the neighbour's gate edge in the wall
		if edge2 < ch * 2.0 + 0.3:
			pocket_ok[i] = false
	var plus := 1 if sx > 0.0 else 0       # the u side that is frame +X
	var pier := 0
	if pier_ok[plus]:
		pier = 1
	elif pier_ok[1 - plus]:
		pier = -1
	var slide := 0
	if not pocket_ok[plus] and pocket_ok[1 - plus]:
		slide = -1
	elif not pocket_ok[1 - plus] and pocket_ok[plus]:
		slide = 1
	return {"reach_lo": reach[1 - plus], "reach_hi": reach[plus], "pier": pier, "slide": slide}


## An air door at `c` along end wall w of district d (MissionGateDoor configured by MissionAirDoors.config).
func _c_air(id: Variant, d: CityDistrict, w: Dictionary, c: float) -> void:
	var door := MissionGateDoor.new()
	door.name = "MissionAir_%s" % str(id)
	MissionAirDoors.config(door)
	var half := MissionAirDoors.W * 0.5 + 0.6
	door.build(d, w, {"a": c - half, "b": c + half, "h": MissionAirDoors.HEAD - MissionAirDoors.SILL, "kind": "air"}, _look(id), MissionAirDoors.W * 0.5 + 1.0)
	d.add_child(door)
	_doors[id] = door
	_cut_wall(d, w, {"a": c - half, "b": c + half, "h": MissionAirDoors.HEAD, "sill": MissionAirDoors.SILL}, door.body)


func _c_lift(id: Variant, d: CityDistrict, bi: int) -> void:
	var lift := MissionLiftDoor.new()
	lift.name = "MissionLift_%s" % str(id)
	lift.build(d, bi)
	d.add_child(lift)
	_doors[id] = lift
	if not lift.has_car:
		return
	# The car is a hollow in the core: the district's solid core box goes (restored by teardown), the car's walls stand in
	# for it (MissionLiftDoor.body), and the baked shut doors leave the district's mesh while the car is there.
	var col := d.get_node_or_null("Collision") as StaticBody3D
	var want := d.core_frame(bi) * Vector3(0, d.plan.p("ceiling") * 0.5, 0)
	if col != null:
		for c in col.get_children():
			var cs := c as CollisionShape3D
			if cs != null and not cs.disabled and str(cs.get_meta("col_kind", "")) == "core" and cs.transform.origin.distance_to(want) < 0.5:
				cs.disabled = true
				_cut.append(cs)
	var hid := lift.hide_fill(d)
	if not hid.is_empty() and not _lift_meshes.has(hid[0]):
		_lift_meshes[hid[0]] = hid[1]


func _c_pose_doors() -> void:
	for id: Variant in _doors:
		_pose_door(id, now, true)


func _c_fit(d: CityDistrict) -> void:
	SiteFit.mask(d.plan)


func _c_site(o: Dictionary, clear_r: float) -> void:
	var d := _deck(o.get("deck", 0))
	if o.get("id") != null and d != null:
		_site(o, d, clear_r)


func _c_finish() -> void:
	setup_ready = true
	for id: Variant in _doors:
		_apply_default(id)
		_pose_door(id, now, true, false)
	_next = -INF


## The schedule door `id` starts with (and restore() falls back to when a snapshot does not name it): a tram door open
## since forever (the train runs; the lockdown shuts road doors only), the entry door opening at clock 0 when
## ENTRY_OPEN_DEFAULT (open since then, no close), every other door none (shut). Sets _sched / _fired; a door that already
## has a schedule keeps it.
func _apply_default(id: Variant) -> void:
	if _sched.has(id):
		return
	var sc := default_sched(_door_kind(id), str(id))
	if sc.is_empty():
		return
	_sched[id] = sc
	_fired[id] = {"warn": true, "open": true, "close": true, "seal": bool(_fired.get(id, {}).get("seal", true))}     # a default fires no signal


## default_sched for a door of `kind` with id `id` (see _apply_default): [] for none.
static func default_sched(kind: String, id: String) -> Array:
	if kind == "tram":
		return [-INF, INF, -INF, -INF]
	if id == ENTRY_ID and ENTRY_OPEN_DEFAULT:
		return [0.0, INF, -INF, 0.0]
	return []


## Free everything, give the walls back their baked leaves and their collision (restore = false when the decks are going
## away anyway: a stack rebuild).
func teardown(restore: bool = true) -> void:
	for door: Variant in _doors.values():
		if is_instance_valid(door) and door is MissionGateDoor and (door as MissionGateDoor).siren != null:
			(door as MissionGateDoor).siren.stop()
	for n: Variant in _all_nodes():
		if is_instance_valid(n):
			var node := n as Node
			if node.get_parent() != null:      # out of the tree now: a setup begun right after reuses the names
				node.get_parent().remove_child(node)
			node.queue_free()
	for l: Variant in _lights.values():
		if is_instance_valid(l):
			(l as Node).queue_free()
	_lights.clear()
	if restore:
		for cs in _cut:
			if is_instance_valid(cs):
				cs.disabled = false
		for d in _walled:
			if is_instance_valid(d):
				_rebuild_walls(d)
		for mi: Variant in _lift_meshes:
			if is_instance_valid(mi):
				(mi as MeshInstance3D).mesh = _lift_meshes[mi]
	_queue = []
	_qi = 0
	_wall_geo = null
	_lift_meshes.clear()
	_cut.clear()
	_walled.clear()
	_wall_doors.clear()
	_doors.clear()
	_flags.clear()
	_zones.clear()
	_assets.clear()
	_hold = null


func _all_nodes() -> Array:
	var out: Array = []
	out.append_array(_doors.values())
	out.append_array(_flags.values())
	out.append_array(_zones.values())
	out.append_array(_assets.values())
	if _hold != null:
		out.append(_hold)
	return out


## Read-only views for the mission lab (the dictionaries themselves, not copies).
func door_nodes() -> Dictionary:
	return _doors


func flag_nodes() -> Dictionary:
	return _flags


func asset_nodes() -> Dictionary:
	return _assets


func source_info() -> Dictionary:
	return _sources


## District k of the stack (clamped), null without a stack.
func deck_at(k: Variant) -> CityDistrict:
	return _deck(k)


func _deck(k: Variant) -> CityDistrict:
	if stack == null or stack.decks.is_empty():
		return null
	return stack.decks[clampi(int(k), 0, stack.decks.size() - 1)]


func _look(id: Variant) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	var base := stack.section.cosmetic_seed() if stack.section != null else 1
	r.seed = hash([base, str(id), "mission"])
	return r


## The road-door gate a gate (wave) source means on district d: {w: wall, g: gate} of the plan's boundary(), on the wall
## named by `edge` (s0 / s1 / x0 / x1; any wall when empty or unknown), nearest the point (x, s); {} when there is none.
## The entry / exit doors (gates with a role) are never a wave source's, nor collapsed gates or tram doors.
static func find_gate(d: CityDistrict, x: float, s: float, edge: String) -> Dictionary:
	var side_want := CityPlan.SIDE_EDGE.find(edge)
	var best := {}
	var best_d := INF
	for w: Dictionary in d.plan.boundary():
		if side_want >= 0 and int(w["side"]) != side_want:
			continue
		for g: Dictionary in w["gates"]:
			if str(g["kind"]) != "blast_door" or str(g.get("role", "")) != "":
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
## MissionGateDoor) close the opening while shut. The district's shape count never changes.
func _cut_wall(d: CityDistrict, w: Dictionary, g: Dictionary, body: StaticBody3D) -> void:
	var col := d.get_node_or_null("Collision") as StaticBody3D
	if col == null:
		return
	var side := int(w["side"])
	var across := side >= 2
	var out := 1.0 if side % 2 == 0 else -1.0
	var thick := CityWalls.WALL_THICK
	var at_c := float(w["at"]) + out * thick * 0.5
	var ga := float(g["a"])
	var gb := float(g["b"])
	var gh := float(g["h"])
	var ceiling := d.plan.p("ceiling")
	var geo := CityGeo.new(d.ring)
	var inv := (body.get_parent() as Node3D).transform.affine_inverse()     # the body is under the door (district space)
	# The district's slabs, and the slabs an earlier door on this deck rebuilt round its own gate: two gates in one wall
	# slab (an end wall is one box) must both be cut, or the first door's rebuilt slab still fills the second's opening.
	var shapes := []         # [CollisionShape3D, its transform in district space]
	for c in col.get_children():
		shapes.append([c, (c as Node3D).transform])
	for other: Variant in _doors.values():
		var od := other as MissionGateDoor
		if od == null or od.get_parent() != d or od.body == body or od.body == null:
			continue
		for c in od.body.get_children():
			if c != od.door_shape:
				shapes.append([c, od.transform * od.body.transform * (c as Node3D).transform])
	for pair: Array in shapes:
		var cs := pair[0] as CollisionShape3D
		if cs == null or cs.disabled or not cs.shape is BoxShape3D:
			continue
		var size := (cs.shape as BoxShape3D).size
		var a := d.ring.world_to_arc((pair[1] as Transform3D).origin)
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
		if cs.get_parent() == col:      # another door's rebuilt slab goes with that door
			_cut.append(cs)
		# Beside the opening, over its head, and (an air door, whose opening starts at g.sill) under its sill.
		var pieces := [[lo, ga, y0, y1], [gb, hi, y0, y1], [maxf(lo, ga), minf(hi, gb), gh, y1]]
		if float(g.get("sill", 0.0)) > 0.0:
			pieces.append([maxf(lo, ga), minf(hi, gb), y0, float(g["sill"])])
		for pc: Array in pieces:
			var u0 := float(pc[0])
			var u1 := float(pc[1])
			if u1 - u0 < 0.1:
				continue
			var yb := float(pc[2])
			var yt := float(pc[3])
			var xf: Transform3D
			var sz: Vector3
			if across:
				xf = geo.frame((u0 + u1) * 0.5, at_c, (yb + yt) * 0.5)
				sz = Vector3(u1 - u0, yt - yb, thick)
			else:
				xf = geo.frame(at_c, (u0 + u1) * 0.5, (yb + yt) * 0.5)
				sz = Vector3(thick, yt - yb, u1 - u0 + CityDistrict.SEAM)
			MissionProps.box_shape(body, inv * xf, Vector3.ZERO, sz)


## Half the interior width of gate g's staging bay, as far as it reaches from mid-gate on its wider side (plan_bay_span):
## what keeps other things (air doors: MissionAirDoors.spot) clear of it. A tram door's: its tunnel's half width.
static func bay_half(d: CityDistrict, w: Dictionary, g: Dictionary) -> float:
	return plan_bay_half(d.plan, w, g)


## bay_half from the deck's plan alone (MissionAirDoors.spot: plan data only).
static func plan_bay_half(plan: CityPlan, w: Dictionary, g: Dictionary) -> float:
	if str(g.get("kind", "")) == "tram_door":
		return CityWalls.clear_half(g)
	var sp := plan_bay_span(plan, w, g)
	return maxf(-sp.x, sp.y)


## The interior of gate g's staging bay along its wall, relative to mid-gate in the wall coordinate u (x on an arc-end
## wall, s on a side wall): Vector2(lo, hi), lo < 0 < hi usually. Half the gate, widened behind the wall to
## MissionGateDoor.BAY_MIN_W / 2, shrunk (symmetric) so the bay with its plates stays 0.5 m clear of a neighbouring road
## door's bay or a collapsed gate on the same wall and 2 m inside the deck's corners, never below the gate's own (the rule
## before the tram doors, unchanged); then, where it would cross a tram door's tunnel (with its plates, + 0.5 m), moved
## sideways away from it (BAY_MIN_W kept: the entry bay beside the tram tunnel sits off centre) and only then trimmed.
static func plan_bay_span(plan: CityPlan, w: Dictionary, g: Dictionary) -> Vector2:
	var ga := float(g["a"])
	var gb := float(g["b"])
	var mid := (ga + gb) * 0.5
	var own := (gb - ga) * 0.5
	var want := maxf(own, MissionGateDoor.BAY_MIN_W * 0.5)
	var plate := MissionGateDoor.PLATE
	var e := plan.extent
	var across := int(w["side"]) >= 2
	var lo_lim := (e.position.x if across else e.position.y) + 2.0 + plate - mid
	var hi_lim := (e.end.x if across else e.end.y) - 2.0 - plate - mid
	var room := minf(-lo_lim, hi_lim)
	var trams := []
	for g2: Dictionary in w["gates"]:
		if g2 == g or is_equal_approx(float(g2["a"]), ga):
			continue
		var a2 := float(g2["a"])
		var b2 := float(g2["b"])
		if str(g2["kind"]) == "tram_door":
			trams.append(g2)
			continue
		var reach := 2.0                 # a collapsed gate (never opened: no bay), as the old portal's plate
		if str(g2["kind"]) == "blast_door":
			reach = maxf((b2 - a2) * 0.5, MissionGateDoor.BAY_MIN_W * 0.5) + plate - (b2 - a2) * 0.5
		var lo := a2 - reach - 0.5
		var hi := b2 + reach + 0.5
		room = minf(room, (lo - mid) - plate if lo >= mid else (mid - hi) - plate)
	var hw := maxf(minf(want, room), own)
	var x0 := -hw
	var x1 := hw
	if trams.is_empty():
		return Vector2(x0, x1)
	for g2: Dictionary in trams:
		var t0 := float(g2["a"]) - CityWalls.TUNNEL_PLATE - 0.5 - plate - mid      # the tunnel and its plates, + 0.5, + our plate
		var t1 := float(g2["b"]) + CityWalls.TUNNEL_PLATE + 0.5 + plate - mid
		if t0 >= 0.0:
			hi_lim = minf(hi_lim, t0)
		elif t1 <= 0.0:
			lo_lim = maxf(lo_lim, t1)
	var wide := maxf(hw, want)
	x0 = -wide
	x1 = wide
	if x1 > hi_lim:
		x0 -= x1 - hi_lim
		x1 = hi_lim
	if x0 < lo_lim:
		x1 += lo_lim - x0
		x0 = lo_lim
	return Vector2(maxf(x0, lo_lim), minf(x1, hi_lim))


## plan_bay_span in gate g's door frame X (MissionGateDoor.build's span: frame X runs along u or against it by side).
static func bay_span(d: CityDistrict, w: Dictionary, g: Dictionary) -> Vector2:
	var sp := plan_bay_span(d.plan, w, g)
	return sp if _u_to_x(int(w["side"])) > 0.0 else Vector2(-sp.y, -sp.x)


## The calls that draw district d's walls, in CityDistrict's own order (one per side, a farm side in FARM_PARTS parts), so a
## rebuilt mesh is vertex for vertex the district's own (and exactly it again after teardown): [[side, part, parts]].
static func _wall_parts(d: CityDistrict) -> Array:
	var parts := int((CityDistrict as Script).get_script_constant_map().get("FARM_PARTS", 1))
	var out := []
	for w: Dictionary in d.plan.boundary():
		var n := parts if w["kind"] == "farm" else 1
		for part in n:
			out.append([int(w["side"]), part, n])
	return out


## One part [side, part, parts] of district d's walls, without the leaves of the gates in `doors` and with the air holes
## in `air` (CityWalls.build's mission openings; both empty: the district's own walls).
static func _wall_part(geo: CityGeo, d: CityDistrict, lights: CityGeo, wp: Array, doors: Dictionary = {}, air: Dictionary = {}) -> void:
	CityWalls.build(geo, d.plan, lights, int(wp[0]), int(wp[1]), int(wp[2]), doors, air)


## The mission's wave-door gates of every district whose walls were rebuilt: {district: {"<side>:<a>": true}} (the lab's
## sign cameras pick a gate with a door: CitySigns.lab_view). Empty before setup and after teardown.
func wall_doors() -> Dictionary:
	return _wall_doors


## One part of district d's walls re-meshed without the door leaves and with the air holes (passed to CityWalls.build);
## the last part swaps the Walls mesh. The farm walls' light bars are left as they are (drawn into a throwaway
## geo: they never depend on the doors).
func _c_walls(d: CityDistrict, doors: Dictionary, wp: Array, first: bool, last: bool, air: Dictionary = {}) -> void:
	if first:
		_wall_doors[d] = doors
		_wall_geo = CityGeo.new(d.ring)
	_wall_part(_wall_geo, d, CityGeo.new(d.ring), wp, doors, air)     # air: openings and their frames' rects, per side
	if last:
		_swap_walls(d, _wall_geo)
		_wall_geo = null
		_walled.append(d)


## Rebuild district d's Walls mesh in one go, as the district built it (teardown: no mission openings).
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
	var mast := MissionFlagMast.new()
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
	var a := MissionRelayAsset.new()
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
	# The fit rule: the widest mech must reach the objective (SiteFit.snap_fit; SiteFit.snap's pick when it does).
	var out := SiteFit.snap_fit(d, at, snap_reach(o), clear_r, avoid, obj_radius(o))
	out["deck"] = d.plan.deck
	out["clear"] = clear_r
	_sites[o.get("id")] = out
	return out


## Objective `o`'s zone radius (its record's `radius`; else flag 14, defend 30: MissionPlan.RADIUS).
static func obj_radius(o: Dictionary) -> float:
	if float(o.get("radius", 0.0)) > 0.0:
		return float(o["radius"])
	return 30.0 if str(o.get("type", "")) == "defend" else 14.0


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
		z = MissionRules.extraction_zone(stack.section, MissionRules.ZONE_DEPTH)
	var geo := MissionProps.zone_rect(d, z)
	_hold = MissionProps.mesh(geo, "MissionHold", d.render_layer)
	d.add_child(_hold)
	_apply_hold()


# --- Doors ---------------------------------------------------------------------------------------------------------------

## s from open_at until a door of `kind` is passable (fully open): OPENING for a gate, LIFT_OPEN for a lift.
static func passable_after(kind: String = "gate") -> float:
	return LIFT_OPEN if kind == "lift" else OPENING


## The state of a door at clock t from its schedule [open_at, close_at, prev_close_at, alarm_from] (empty: never opened)
## and the time it is sealed at (INF: never): [state, u] with state shut | warn | opening | open | closing | sealed and u
## 0..1 through warn / opening / closing. warn: WARN s before open_at; opening: from open_at for passable_after(kind) s;
## open until close_at. A door open (or opening) at seal_at closes over CLOSE s from then, then is sealed; one already
## closing finishes its closing.
## NO JUMPS (a re-order landing on a moving door): the previous cycle (prev_close_at) always plays out first: open until
## prev_close_at, then closing over CLOSE s, and only then the new cycle; the new opening never starts before the
## previous closing ends (effective open_at = max(open_at, prev_close_at + CLOSE): open_source stores it so, and this
## clamps an older schedule too), and its warn (leaves shut) shows only once the leaves are shut. So the leaves never
## snap from open / closing to shut, nor pop back open. A pure function of the schedule (snapshot-restorable).
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
	var pca := float(sched[2])
	var oa := maxf(float(sched[0]), pca + CLOSE)
	var t_open := passable_after(kind)
	var ca := maxf(float(sched[1]), oa + t_open)
	if t < oa:
		if t < pca:
			return ["open", 1.0]
		if t < pca + CLOSE:
			return ["closing", (t - pca) / CLOSE]
		if t >= oa - WARN:
			return ["warn", (t - (oa - WARN)) / WARN]
		return ["shut", 0.0]
	if t < oa + t_open:
		return ["opening", (t - oa) / t_open]
	if t < ca:
		return ["open", 1.0]
	if t < ca + CLOSE:
		return ["closing", (t - ca) / CLOSE]
	return ["shut", 0.0]


## When a schedule's gate alarm starts: its stored start (open_source: the order time, clamped to
## [open_at - ALARM_LEAD, open_at]), or open_at - ALARM_LEAD for a schedule without one (an old snapshot).
static func alarm_from(sched: Array) -> float:
	if sched.is_empty():
		return INF
	var oa := eff_open_at(sched)
	if sched.size() > 3:
		return clampf(float(sched[3]), oa - ALARM_LEAD, oa)
	return oa - ALARM_LEAD


## A schedule's effective open_at: never before its previous closing ends (door_state's no-jump rule).
static func eff_open_at(sched: Array) -> float:
	return maxf(float(sched[0]), float(sched[2]) + CLOSE)


## The gate alarm (siren + lamps + beacons at the door) at clock t: a scheduled effect, on from alarm_from(sched) (with
## ALARM_LEAD 0: open_at, the leaves starting to move) until the leaves are fully open (open_at + OPENING), off once
## sealed. Gates, air and tram doors (a freight lift has no alarm: its doors' motion is the tell).
static func alarm_on(kind: String, sched: Array, seal_at: float, t: float) -> bool:
	if (kind != "gate" and kind != "air" and kind != "tram") or sched.is_empty() or t >= seal_at:
		return false
	return t >= alarm_from(sched) and t < eff_open_at(sched) + OPENING


## Whether source `id`'s gate alarm is on at the current clock.
func alarm(id: Variant) -> bool:
	return alarm_on(_door_kind(id), _sched.get(id, []), _seal_at(id), now)


## Schedule wave source `id` to open at `open_at` (shared clock; the moment the leaves START to move): the silent warn
## state WARN s before, the opening (siren) passable_after(kind) s from open_at, then fully open `hold` s, then closing over
## CLOSE s. Called again while the door is due to be open (the new open_at is not after the current close time, and the
## order came before that close time): only the hold is extended (the earlier open_at stays, no second opening). An
## order landing while the door closes, or so soon after that its warn would start before the leaves are shut, waits:
## the door finishes closing, then runs the normal warn / opening cycle (open_at moved to the end of the closing; never a
## jump from open / closing to warn, never popping back open). Ramp / shaft / unknown ids are accepted and do nothing; a
## sealed source stays sealed. `order_at` (default: the current clock) is when the order arrived: the alarm starts
## there, at most ALARM_LEAD s before open_at (ALARM_LEAD 0: at open_at); stored in the schedule (snapshot()). Pass the
## host's order time so every machine stores the same schedule.
func open_source(id: Variant, open_at: float, hold: float = HOLD, order_at: float = NAN) -> void:
	if not setup_ready:
		return
	if _sealed.has(id) or not _sources.has(id):
		return
	var kind := str(_sources[id].get("kind", ""))
	if kind != "gate" and kind != "lift" and kind != "air":
		return
	var ord := now if is_nan(order_at) else order_at
	if _sched.has(id):
		var sc: Array = _sched[id]
		var ca := float(sc[1])
		# Due to be open at open_at (not yet closing when the order came): only the hold grows. An order that lands once
		# the door is closing (or after) starts a new cycle that waits for the closing to end (no jump, door_state).
		if open_at <= ca and ord < ca:
			var keep := open_at + passable_after(kind) + maxf(hold, 0.0)
			if keep > ca:
				sc[1] = keep
				(_fired[id] as Dictionary)["close"] = false
			_next = -INF
			return
		var oa := maxf(maxf(open_at, ord if open_at <= ca else open_at), ca + CLOSE)
		_sched[id] = [oa, oa + passable_after(kind) + maxf(hold, 0.0), ca, clampf(ord, oa - ALARM_LEAD, oa)]
	else:
		_sched[id] = [open_at, open_at + passable_after(kind) + maxf(hold, 0.0), -INF, clampf(ord, open_at - ALARM_LEAD, open_at)]
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
	if kind != "gate" and kind != "lift" and kind != "air":
		return
	_sealed[id] = now if is_nan(at) else at
	if not _fired.has(id):
		_fired[id] = {"warn": true, "open": true, "close": true}
	(_fired[id] as Dictionary)["seal"] = false
	_next = -INF


## End source `id`'s hold at clock `at` (default: the current clock) without sealing it: the door closes from then over
## CLOSE s (once fully open, if it is still opening) and is shut; a later open_source opens it again. No effect on a
## source never opened, already closing / shut by then, or sealed. Missions: shut the entry door once its bay is empty.
func shut_source(id: Variant, at: float = NAN) -> void:
	if not setup_ready:
		return
	if _sealed.has(id) or not _sched.has(id):
		return
	var t := now if is_nan(at) else at
	var sc: Array = _sched[id]
	var ca := float(sc[1])
	if ca <= t:
		return
	sc[1] = maxf(t, eff_open_at(sc) + passable_after(_door_kind(id)))
	(_fired[id] as Dictionary)["close"] = false
	_next = -INF


func _seal_at(id: Variant) -> float:
	return float(_sealed.get(id, INF))


# --- Entry / exit doors, bays, tram doors (docs/design/city-spine.md §4) ---------------------------------------------------

## The entry road door (the gate with role entry: top deck, the spine's main road): source_bay(id) plus `id` (ENTRY_ID,
## an ordinary door id: open_source / hold_source / shut_source / close_source / source_state, incl. `passable`).
## {ok = false} when the section has none. Shut unless ENTRY_OPEN_DEFAULT (then open from setup until Missions orders).
func entry_door() -> Dictionary:
	return _role_door(ENTRY_ID)


## The exit road door (role exit: the lowest deck), as entry_door; shut until Missions opens it.
func exit_door() -> Dictionary:
	return _role_door(EXIT_ID)


const SLOT_R := 3.6                            ## m: the widest capsule a bay slot is laid out for (Bulwark)
const BAY_COLUMNS := 2.0 * SLOT_R + 0.2        ## m between a bay's two stand columns (7.4: two Bulwarks abreast, 0.2 m apart)
## m behind the door plane of a bay's two stand rows: the usable volume's ends (MissionGateDoor.USE_FROM / USE_TO) less
## SLOT_R, so a Bulwark fits each and two in line keep 1.6 m between them. A staggered layout (slot_layout) may put the
## far column's back slot deeper, MARGIN + SLOT_R short of the bay's back wall (21.4 m).
const BAY_ROWS: Array[float] = [MissionGateDoor.USE_FROM + SLOT_R, MissionGateDoor.USE_TO - SLOT_R]
const SLOT_CLEAR := 0.3                        ## m a slot's walk-out line keeps off the jambs / throat walls (per side)


## Where n (1..4) mechs stand in a bay of interior ix0..ix1 (door frame X, mid-gate 0) behind a door of clear half
## `half` and throat half `w_out` (MissionGateDoor), in seat order: [{x, depth, aim, clear}] (aim: the frame-X point on
## the door plane the slot faces when facing out, NAN = straight ahead; clear: the room its walk-out line keeps for a
## SLOT_R capsule, m). Two columns BAY_COLUMNS apart as close to the door's centre line as the bay's walls allow (each slot
## SLOT_R + MissionGateDoor.MARGIN inside them), rows BAY_ROWS (front row first; a lone mech in the front row nearest the
## centre line; an odd last one in the -X column). Every slot walking out along its facing passes the door without
## touching a jamb or the throat: a slot whose straight line would come within SLOT_R + SLOT_CLEAR of one (_walk_room)
## turns to face the door-plane point that keeps its line clearest of them. Plan data only (tests read it, no scene).
static func slot_layout(ix0: float, ix1: float, half: float, w_out: float, n: int) -> Array:
	n = clampi(n, 1, 4)
	var lo := ix0 + MissionGateDoor.MARGIN + SLOT_R
	var hi := ix1 - MissionGateDoor.MARGIN - SLOT_R
	if n == 1:
		return [_slot(Vector2(clampf(0.0, lo, hi), BAY_ROWS[0]), ix0, ix1, half, w_out)]
	var cols := [-BAY_COLUMNS * 0.5, BAY_COLUMNS * 0.5]
	if cols[1] > hi:
		cols = [hi - BAY_COLUMNS, hi]
	if cols[0] < lo:
		cols = [lo, lo + BAY_COLUMNS]
	# The grid: two columns, rows BAY_ROWS; seat order front row -X, +X, back row -X, +X.
	var layouts := [[Vector2(cols[0], BAY_ROWS[0]), Vector2(cols[1], BAY_ROWS[0]), Vector2(cols[0], BAY_ROWS[1]),
			Vector2(cols[1], BAY_ROWS[1])]]
	# Staggered (a bay pushed off the door's centre line): the column nearer the centre line keeps its front slot, the far
	# column's slots step back (front by dz, back to SLOT_BACK) and in towards the centre line, BAY_COLUMNS from every
	# other slot, so the far front slot's walk-out line clears the jamb.
	var near_i := 0 if absf(float(cols[0])) < absf(float(cols[1])) else 1
	var xn := float(cols[near_i])
	var side := signf(float(cols[1 - near_i]) - xn)
	var back := MissionGateDoor.BAY_DEPTH - MissionGateDoor.MARGIN - SLOT_R
	var n2 := Vector2(xn, BAY_ROWS[1])
	var f2 := Vector2(xn + side * sqrt(maxf(BAY_COLUMNS * BAY_COLUMNS - (back - BAY_ROWS[1]) * (back - BAY_ROWS[1]), 0.0)), back)
	var dz := 0.0
	while dz <= 3.0 + 1e-6:
		var f1 := Vector2(xn + side * sqrt(maxf(BAY_COLUMNS * BAY_COLUMNS - dz * dz, 0.0)), BAY_ROWS[0] + dz)
		layouts.append([Vector2(xn, BAY_ROWS[0]), f1, n2, f2])
		dz += 0.2
	var best: Array = []
	var best_m := -INF
	for lay: Array in layouts:
		var pts: Array = lay.slice(0, n)
		var fits := true
		for a in pts.size():
			var p: Vector2 = pts[a]
			if p.x < lo - 1e-3 or p.x > hi + 1e-3:
				fits = false
			for b in a:
				if p.distance_to(pts[b]) < BAY_COLUMNS - 1e-3:
					fits = false
		if not fits:
			continue
		var slots := []
		var m := INF
		for p: Vector2 in pts:
			var sl := _slot(p, ix0, ix1, half, w_out)
			slots.append(sl)
			m = minf(m, float(sl["clear"]))
		if m > best_m + 1e-3:
			best_m = m
			best = slots
		if best_m >= SLOT_R + SLOT_CLEAR:
			break       # the first layout (the grid first) that walks out clear wins
	return best


## Slot at p (frame X, depth): {x, depth, aim, clear} (slot_layout): straight ahead when that keeps SLOT_R + SLOT_CLEAR off
## the door's edges (_walk_room), else facing the door-plane point whose line keeps the most room.
static func _slot(p: Vector2, ix0: float, ix1: float, half: float, w_out: float) -> Dictionary:
	var room := _walk_room(p, p.x, ix0, ix1, half, w_out)
	var aim := NAN
	if room < SLOT_R + SLOT_CLEAR:
		var steps := 128
		for k in steps + 1:
			var xa := lerpf(-half, half, float(k) / float(steps))
			var m := _walk_room(p, xa, ix0, ix1, half, w_out)
			if m > room + 1e-6:
				room = m
				aim = xa
	return {"x": p.x, "depth": p.y, "aim": aim, "clear": room}


## The least distance (m) from the walk-out line of a mech standing at `at` (frame X, depth behind the door plane) facing
## the door-plane point x = aim, from its spot to FRAME_OUT + 0.4 + 6 m in front of the door, to the door's solid edges:
## both jambs' faces (x = +-half, from the plane to FRAME_OUT + 0.4 m out), both throat walls (x = +-w_out through the
## wall's thickness), the room's front wall beside the throat (at the wall's thickness, from w_out out to the room's
## side) and, where the room is narrower than the throat, its step (x = the room's side, the throat's last 1 m on).
static func _walk_room(at: Vector2, aim: float, ix0: float, ix1: float, half: float, w_out: float) -> float:
	var front := -(MissionGateDoor.FRAME_OUT + 0.4)
	var wt := CityWalls.WALL_THICK
	var end_z := front - 6.0
	var e := Vector2(aim + (at.x - aim) * end_z / at.y, end_z)
	var segs := []
	for k: float in [-1.0, 1.0]:
		var edge := ix1 if k > 0.0 else ix0
		segs.append([Vector2(k * half, front), Vector2(k * half, 0.0)])
		var tw := minf(w_out, k * edge)
		segs.append([Vector2(k * half, 0.0), Vector2(k * tw, 0.0)])
		segs.append([Vector2(k * tw, 0.0), Vector2(k * tw, wt + 1.2)])
		if k * edge > w_out:
			segs.append([Vector2(k * w_out, wt), Vector2(edge, wt)])
	var m := INF
	for sg: Array in segs:
		m = minf(m, _seg_dist(at, e, sg[0], sg[1]))
	return m


## Distance between 2D segments ab and cd.
static func _seg_dist(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return 0.0
	return minf(minf(Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c), Geometry2D.get_closest_point_to_segment(d, a, b).distance_to(d)),
			minf(Geometry2D.get_closest_point_to_segment(a, c, d).distance_to(a), Geometry2D.get_closest_point_to_segment(b, c, d).distance_to(b)))


## Stand points for n (1..4) mechs inside door `id`'s bay, in seat order (slot_layout: two columns BAY_COLUMNS apart as
## near the door's centre line as the bay allows, rows BAY_ROWS behind the door plane), 0.3 m above the floor (on the
## ring circle), each fitting the widest capsule (SLOT_R). `facing_out`: facing out through the door into the map (the
## entry spawn), each slot aimed so its straight walk passes the opening clear of the jambs; else facing in, away from the
## door (the exit bay). Global in the tree, district-local otherwise (as source_bay). [] for an id without a bay. A lift:
## its car (_car_slots). (CityStack.entry_bay_slots: the same rule for the entry bay.)
func bay_slots(id: Variant, n: int, facing_out: bool = true) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if _doors.get(id) is MissionLiftDoor:
		return _car_slots(_doors[id] as MissionLiftDoor, n, facing_out)
	var door := _doors.get(id) as MissionGateDoor
	if door == null or not is_instance_valid(door) or door.air or door.bayless:
		return out
	if absf(door.arc_in.y) < 0.5:
		return out       # a side-wall gate (no entry / exit door stands there)
	var d := door.get_parent() as CityDistrict
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	for sl: Dictionary in slot_layout(door.ix0, door.ix1, door.half, door.w_out, n):
		var a := door.arc(float(sl["x"]), float(sl["depth"]))
		var p := d.ring.arc_to_world(a.x, a.y, 0.3)
		var dir := d.ring.tangent_at(p) * signf(door.arc_in.y) * (1.0 if facing_out else -1.0)     # an arc-end wall's door: along s
		if facing_out and not is_nan(float(sl["aim"])):
			var t := door.arc(float(sl["aim"]), 0.0)
			dir = d.ring.arc_to_world(t.x, t.y, 0.3) - p
		out.append(to_space * Transform3D(d.ring.basis_at(p, dir), p))
	return out


const CAR_COLUMNS := 8.0                       ## m between a lift car's two stand columns (either side of mid-door)
const CAR_ROWS: Array[float] = [5.5, 13.5]     ## m behind the door plane of its two stand rows


## bay_slots for a lift car: two columns CAR_COLUMNS apart, rows CAR_ROWS behind the door plane (the widest capsule,
## Bulwark r 3.6 m, fits each: 0.8 m between two abreast or in line, 0.4 m to the car's side walls), 0.3 m above the floor;
## [] without a car.
func _car_slots(lift: MissionLiftDoor, n: int, facing_out: bool) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if not is_instance_valid(lift) or not lift.has_car:
		return out
	var d := lift.get_parent() as CityDistrict
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	var geo := CityGeo.new(d.ring)
	n = clampi(n, 1, 4)
	for i in n:
		var lx := 0.0
		if n > 1:
			lx = (-0.5 if i % 2 == 0 else 0.5) * CAR_COLUMNS
		var a := lift.arc(lx, CAR_ROWS[i / 2])
		var p := geo.g_point(a.x, a.y, CityPlan.CURB_H + 0.3)
		var fwd := lift.transform.basis.z.normalized() * (1.0 if facing_out else -1.0)
		out.append(to_space * Transform3D(d.ring.basis_at(p, fwd), p))
	return out


## The exit bay's n (1..4) stand points facing in, away from the door (bay_slots(EXIT_ID, n, false)): where a crew that
## walks out after the hold stands. [] when there is no exit door.
func exit_bay_slots(n: int) -> Array[Transform3D]:
	return bay_slots(EXIT_ID, n, false)


func _role_door(id: String) -> Dictionary:
	var b := source_bay(id)
	if not bool(b.get("ok", false)):
		return {"ok": false}
	b["id"] = id
	return b


## Where a point stands relative to door `id`'s bay, exact from the door's frame: {inside (within the bay's inner walls
## behind the door plane: in the throat through the wall, |x| <= the throat's half, or in the room, between its walls,
## to its back wall; under its roof), doorway (within 1.5 m of the door plane either side and within door_w / 2 of
## mid-door), depth (m behind the door plane, negative in front of it)}. The door plane is the wall's face on the map side
## (the frame's origin). Gates, the entry / exit doors, lift cars (_car_contains) and any door with a bay; ids without one (tram and air
## doors, unknown ids): inside false (a tram / air door still answers doorway and depth). `point` is global in the tree
## (district-local otherwise, as source_bay's frame).
func bay_contains(id: Variant, point: Vector3) -> Dictionary:
	if _doors.get(id) is MissionLiftDoor:
		return _car_contains(_doors[id] as MissionLiftDoor, point)
	var door := _doors.get(id) as MissionGateDoor
	if door == null or not is_instance_valid(door):
		return {"inside": false, "doorway": false, "depth": 0.0}
	var d := door.get_parent() as CityDistrict
	var local := d.to_local(point) if d.is_inside_tree() else point
	var a := d.ring.world_to_arc(local)
	var rel := Vector2(a.x, a.y) - door.arc_mid
	var depth := -rel.dot(door.arc_in)
	var lx := rel.dot(door.arc_x)
	var h := a.z - door.sill
	# Height in the door's own frame: from 1 m under its floor to its roof (the opening's top for a bayless door), so a
	# point on another deck at the same x / s is neither inside nor in the doorway.
	var level := h >= -1.0 and h <= (door.gh if door.bayless or door.air else door.room_h)
	var doorway := level and absf(depth) <= 1.5 and absf(lx) <= door.half
	var inside := false
	if level and not door.bayless and not door.air and depth > 0.0 and depth <= door.bay_depth:
		if depth < CityWalls.WALL_THICK:
			inside = absf(lx) <= door.w_out and h <= door.gh
		else:
			inside = lx >= door.ix0 and lx <= door.ix1
	return {"inside": inside, "doorway": doorway, "depth": depth}


## bay_contains for a lift car, exact from the door's frame: inside (in the doorway's throat through the front wall, |x| <=
## door_w / 2, or in the car between its side walls to its back wall; under its roof), doorway (within 1.5 m of the door
## plane either side and within door_w / 2 of mid-door), depth. A lift without a car: inside false.
func _car_contains(lift: MissionLiftDoor, point: Vector3) -> Dictionary:
	if not is_instance_valid(lift):
		return {"inside": false, "doorway": false, "depth": 0.0}
	var d := lift.get_parent() as CityDistrict
	var local := d.to_local(point) if d.is_inside_tree() else point
	var l := lift.transform.affine_inverse() * local
	var depth := -l.z
	var level := l.y >= -1.0 and l.y <= MissionLiftDoor.CAR_H      # this deck's car, not one a deck up or down
	var doorway := level and absf(depth) <= 1.5 and absf(l.x) <= MissionLiftDoor.W * 0.5
	var inside := false
	if level and lift.has_car and depth > 0.0 and depth <= lift.car_back:
		if depth < MissionLiftDoor.WALL:
			inside = absf(l.x) <= MissionLiftDoor.W * 0.5 and l.y <= MissionLiftDoor.H
		else:
			inside = absf(l.x) <= lift.car_half
	return {"inside": inside, "doorway": doorway, "depth": depth}


## Tram door `end` ("s0" / "s1": the arc-end wall it is in; deck 0 only): {ok, id, deck, open (ordered open at the
## current clock), state (source_state's), passable, frame (Transform3D as source_bay's: on the wall plane at floor
## mid-door, +Z into the map), door (Vector2: arc point of mid-door), door_w, door_h (clear), depth (the tunnel, wall
## plane to back plate)}; {ok = false} when there is none.
func tram_door(end: String) -> Dictionary:
	var id: String = str(TRAM_IDS.get(end, ""))
	var door := _doors.get(id) as MissionGateDoor
	if id == "" or door == null or not is_instance_valid(door):
		return {"ok": false}
	var d := door.get_parent() as CityDistrict
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	var st := source_state(id)
	return {"ok": true, "id": id, "deck": int((_sources[id] as Dictionary).get("deck", 0)), "open": tram_open(end),
			"state": st["state"], "passable": st["passable"], "frame": to_space * door.transform, "door": door.arc_mid,
			"door_w": door.half * 2.0, "door_h": door.gh, "depth": CityWalls.TUNNEL_DEPTH}


## Whether tram door `end` is ordered open at clock t (default: now): its schedule's open phase (opening / open) has begun
## and its close time is still ahead.
func tram_open(end: String, t: float = NAN) -> bool:
	var sc: Array = _sched.get(str(TRAM_IDS.get(end, "")), [])
	var tt := now if is_nan(t) else t
	return not sc.is_empty() and tt >= eff_open_at(sc) and tt < float(sc[1])


## Order tram door `end` ("s0" / "s1") open or shut at clock `at` (default: now): a host-arbitrated world object, the
## change stored as times on the shared clock like every door schedule (snapshot() / restore()); the leaves move with
## the normal mechanism (siren and lamps while they open, CLOSE s to shut, no jump: an open order on a closing door waits
## for it to shut). Default in a mission: open (the lockdown shuts road doors only). After the change: tram_door_changed
## and, when the scene has an AmbientLife (group "ambient_life"), its set_tram_door(end, open, at) (the train link).
## A train that cannot stop in time runs through a shutting door: the host shuts one only when
## AmbientLife.tram_door_clear(end) is true (or schedules `at` for when it is); this call does not check.
func set_tram_door(end: String, open: bool, at: float = NAN) -> void:
	if not setup_ready:
		return
	var id: String = str(TRAM_IDS.get(end, ""))
	if id == "" or not _doors.has(id):
		return
	var t := now if is_nan(at) else at
	var sc: Array = _sched.get(id, [])
	if open:
		if not sc.is_empty() and float(sc[1]) > t:
			sc[1] = INF                      # open, opening or due to open: stays open (opens no later than t)
			if eff_open_at(sc) > t:
				sc[0] = maxf(t, float(sc[2]) + CLOSE)
				sc[3] = sc[0]
		else:
			var ca := float(sc[1]) if not sc.is_empty() else -INF
			var oa := maxf(t, ca + CLOSE)
			_sched[id] = [oa, INF, ca, oa]
			_fired[id] = {"warn": true, "open": false, "close": false, "seal": true}
	else:
		if sc.is_empty() or float(sc[1]) <= t:
			return
		sc[1] = maxf(t, eff_open_at(sc) + passable_after("tram"))
		(_fired[id] as Dictionary)["close"] = false
	_next = -INF
	_tell_tram(end, open, t)


func _tell_tram(end: String, open: bool, t: float) -> void:
	tram_door_changed.emit(end, open, t)
	if is_inside_tree():
		var life := get_tree().get_first_node_in_group("ambient_life")
		if life != null and life.has_method("set_tram_door"):
			life.call("set_tram_door", end, open, t)


## {state, t (when this state began, -INF if always), open_at (the leaves start to move), close_at, alarm, alarm_from,
## passable (fully open: the widest unit gets through; false while opening / closing / shut / sealed), passable_at
## (open_at + passable_after(kind); INF when never scheduled)} of source `id` at the current clock.
func source_state(id: Variant) -> Dictionary:
	var kind := str(_sources.get(id, {}).get("kind", ""))
	var sc: Array = _sched.get(id, [])
	var st := door_state(kind, sc, _seal_at(id), now)
	var began := -INF
	var t_open := passable_after(kind)
	if str(st[0]) == "sealed":
		began = _seal_at(id)
	elif not sc.is_empty() and now < _seal_at(id):
		var oa := eff_open_at(sc)
		var ca := maxf(float(sc[1]), oa + t_open)
		match str(st[0]):
			"warn": began = maxf(oa - WARN, float(sc[2]) + CLOSE)
			"opening": began = oa
			"open": began = oa + t_open if now >= oa + t_open else -INF
			"closing": began = ca if now >= ca else float(sc[2])
			"shut": began = ca + CLOSE if now >= ca + CLOSE else (float(sc[2]) + CLOSE if float(sc[2]) > -INF else -INF)
	return {"state": st[0], "t": began, "open_at": eff_open_at(sc) if not sc.is_empty() else INF,
			"close_at": float(sc[1]) if not sc.is_empty() else INF, "alarm": alarm_on(kind, sc, _seal_at(id), now),
			"alarm_from": alarm_from(sc) if kind == "gate" or kind == "air" or kind == "tram" else INF, "passable": str(st[0]) == "open",
			"passable_at": eff_open_at(sc) + t_open if not sc.is_empty() else INF}


## Where units of source `id` should appear, {deck, x, s} in its deck's arc coordinates, for every kind ({} for unknown
## ids): a gate with its door, the floor centre of its staging bay (source_bay: hidden by the leaves until they open; the
## door's shape is solid only while the leaves stand shut, so the squad holds staged units until source_state().passable);
## every other source (lift, ramp, shaft, a gate without a door) the
## plan's point (a lift's lobby in front of its doors, unchanged now that the lift has a car: source_bay gives the car).
func source_point(id: Variant) -> Dictionary:
	if not _sources.has(id):
		return {}
	var s: Dictionary = _sources[id]
	var k := int(s.get("deck", 0))
	if not _doors.get(id) is MissionGateDoor:
		return {"deck": k, "x": float(s.get("x", 0.0)), "s": float(s.get("s", 0.0))}
	var gd := _doors[id] as MissionGateDoor
	if gd.air:       # an air door: its hiding point in the recess (h: its height over the deck floor)
		var a := gd.arc(0.0, AIR_HIDE)
		return {"deck": k, "x": a.x, "s": a.y, "h": MissionAirDoors.SILL + (MissionAirDoors.HEAD - MissionAirDoors.SILL) * 0.5}
	var c := gd.arc(0.0, -GATE_POINT)
	return {"deck": k, "x": c.x, "s": c.y}


## The staging bay of gate source `id` (docs/design/city-ramps-and-stack.md "Staging bay"), for placing a wave inside it
## (loose formation facing out). {ok = false} for anything else (ramps, shafts, unknown ids, a gate without a door):
## test `ok`. With ok = true:
##   deck; frame (Transform3D, global when in the tree, else district-local: origin on the wall plane at floor mid-gate, +Z
##   into the map, X along the wall, as MissionProps.gate_frame); center (Vector3, same space: the usable floor's centre);
##   x, s, h (its arc coordinates on the deck, h the floor height 0); origin (Vector2(x, s)); out (Vector2, unit, arc: from
##   the bay into the deck); facing (Vector3, unit, same space as frame: out of the bay into the map); exit (Vector3: on the
##   street EXIT m in front of the door); half_width (usable, the walls' MARGIN taken off), width (2 x half_width);
##   depth_from, depth_to (usable metres behind the wall plane), depth (depth_to - depth_from); height (true clear height
##   under the lowest thing in the bay, over the floor's highest point); door_w (clear between the jambs), door_h (clear
##   to the lintel's underside); door (Vector2: arc point of mid-gate on the wall plane); door_s (the wall plane's arc
##   coordinate along `out`: x for a side wall x0 / x1, s for an end wall s0 / s1); edge (s0 / s1 / x0 / x1); offset (m
##   along the frame's X from mid-door to the bay's centre: 0 unless the bay sits off centre beside a tram tunnel; center,
##   x, s and origin are the bay's centre, door / frame the door's).
## A LIFT source answers too (R2.22: its car, docs/design/city-ramps-and-stack.md section 9 "Lift cars"), with the same keys
## and the same frame convention (origin on the door plane, the core's face, at floor mid-door; +Z out of the car): h is
## the floor's height over the deck road (the plaza's curb), half_width / width the car's usable width (its side walls'
## MARGIN off), depth_from .. depth_to its usable depth (MissionLiftDoor.USE_FROM .. car_back - BACK_MARGIN), edge "",
## offset 0; plus `kind` "lift" and `bay_depth` (the back wall's inner face). {ok = false} for a lift whose core holds no
## car (none in section seeds 1..200).
func source_bay(id: Variant) -> Dictionary:
	if _doors.get(id) is MissionLiftDoor:
		return _car_bay(id, _doors[id] as MissionLiftDoor)
	var door := _doors.get(id) as MissionGateDoor
	if door == null or not is_instance_valid(door) or door.air or door.bayless:      # an air door has no staging bay: air_door(); a tram door none
		return {"ok": false}
	var k := int((_sources[id] as Dictionary).get("deck", 0))
	var d := door.get_parent() as CityDistrict
	var geo := CityGeo.new(d.ring)
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	var mid_depth := (MissionGateDoor.USE_FROM + MissionGateDoor.USE_TO) * 0.5
	var c := door.arc(door.icenter, mid_depth)
	var ex := door.arc(0.0, -EXIT)
	var frame := to_space * door.transform
	var hw := door.ihalf - MissionGateDoor.MARGIN
	var side := CityPlan.SIDE_EDGE.find(str(_sources[id].get("edge", "")))
	return {"ok": true, "deck": k, "frame": frame, "center": to_space * geo.g_point(c.x, c.y, 0.0),
			"x": c.x, "s": c.y, "h": 0.0, "origin": c, "out": door.arc_in, "facing": frame.basis.z.normalized(),
			"exit": to_space * geo.g_point(ex.x, ex.y, 0.0), "half_width": hw, "width": hw * 2.0,
			"depth_from": MissionGateDoor.USE_FROM, "depth_to": MissionGateDoor.USE_TO,
			"depth": MissionGateDoor.USE_TO - MissionGateDoor.USE_FROM, "height": door.clear_height(),
			"door_w": door.half * 2.0, "door_h": door.gh, "door": door.arc_mid,
			"door_s": door.arc_mid.x if absf(door.arc_in.x) > 0.5 else door.arc_mid.y,
			"edge": CityPlan.SIDE_EDGE[side] if side >= 0 else "", "offset": door.icenter}


func _car_bay(id: Variant, lift: MissionLiftDoor) -> Dictionary:
	if not is_instance_valid(lift) or not lift.has_car:
		return {"ok": false}
	var d := lift.get_parent() as CityDistrict
	var geo := CityGeo.new(d.ring)
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	var d_from := MissionLiftDoor.USE_FROM
	var d_to := lift.car_back - MissionLiftDoor.BACK_MARGIN
	var c := lift.arc(0.0, (d_from + d_to) * 0.5)
	var ex := lift.arc(0.0, -EXIT)
	var frame := to_space * lift.transform
	var hw := lift.car_half - MissionLiftDoor.MARGIN
	return {"ok": true, "kind": "lift", "deck": int((_sources[id] as Dictionary).get("deck", 0)), "frame": frame,
			"center": to_space * geo.g_point(c.x, c.y, CityPlan.CURB_H), "x": c.x, "s": c.y, "h": CityPlan.CURB_H, "origin": c,
			"out": lift.arc_in, "facing": frame.basis.z.normalized(), "exit": to_space * geo.g_point(ex.x, ex.y, CityPlan.CURB_H),
			"half_width": hw, "width": hw * 2.0, "depth_from": d_from, "depth_to": d_to, "depth": d_to - d_from,
			"height": lift.clear_height(), "door_w": MissionLiftDoor.W, "door_h": MissionLiftDoor.H, "door": lift.arc_mid,
			"door_s": lift.arc_mid.x if absf(lift.arc_in.x) > 0.5 else lift.arc_mid.y, "edge": "", "offset": 0.0,
			"bay_depth": lift.car_back}


## The clean sign panel beside gate source `id`'s bunker frame (a flat concrete face PANEL m wide x tall, for a stencilled
## deck number painted later; nothing is drawn on it): {ok, frame (Transform3D, space as source_bay: origin at the
## panel's centre on its face, +Z out of it toward the street, X along the wall, Y up), size (Vector2)}; {ok = false} for
## anything without a gate door.
func source_sign_panel(id: Variant) -> Dictionary:
	var door := _doors.get(id) as MissionGateDoor
	if door == null or not is_instance_valid(door) or door.air or door.pier_side == 0:
		return {"ok": false}
	var d := door.get_parent() as CityDistrict
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	return {"ok": true, "frame": to_space * door.transform * door.panel_xf, "size": MissionGateDoor.PANEL}


# --- Air doors (Missions' convenience API: thin wrappers over the source calls) --------------------------------------------

## How many air doors deck k has: 1 or 2 on every deck of a section (R2.24: MissionAirDoors.spot slides along the wall
## until the approach is clear; tests/test_air_doors.gd sweeps seeds), so Missions can always bring a dropship in and out
## through one. 0 only off a section (a lone district with a low ceiling) or before setup.
func air_door_count(deck: int) -> int:
	return (_air.get(deck, []) as Array).size()


## Air door i of deck k: {ok, id, deck, frame (Transform3D, global in the tree, else district-local: at the opening's
## centre, +Z into the deck, X along the wall), center (Vector3, the opening's centre, same space), x, s (arc of the
## opening's foot on the wall plane), h_bottom, h_top (the opening's sill and head above the deck floor at the wall),
## width, height (clear), depth (the recess, wall plane to back wall), hide (Vector3 in the recess at mid height, AIR_HIDE m
## behind the wall plane), out (Vector3 AIR_OUT m in front of the opening at mid height), facing (unit, into the deck),
## usable (true: at least MissionAirDoors.APPROACH m of clear straight flight for the whole opening), clear_len (m of that
## flight: air_door_approach)}; {ok = false} when there is no such door.
func air_door(deck: int, i: int) -> Dictionary:
	var ids: Array = _air.get(deck, [])
	if i < 0 or i >= ids.size() or not _doors.has(ids[i]):
		return {"ok": false}
	var door := _doors[ids[i]] as MissionGateDoor
	var d := door.get_parent() as CityDistrict
	var to_space := d.global_transform if d.is_inside_tree() else Transform3D.IDENTITY
	var mid_h := (MissionAirDoors.HEAD - MissionAirDoors.SILL) * 0.5
	var fr := to_space * door.transform * Transform3D(Basis.IDENTITY, Vector3(0, mid_h, 0))
	return {"ok": true, "id": ids[i], "deck": deck, "frame": fr, "center": fr.origin, "x": door.arc_mid.x, "s": door.arc_mid.y,
			"h_bottom": MissionAirDoors.SILL, "h_top": MissionAirDoors.HEAD, "width": MissionAirDoors.W, "height": MissionAirDoors.HEAD - MissionAirDoors.SILL, "depth": MissionAirDoors.DEPTH,
			"hide": fr * Vector3(0, 0, -AIR_HIDE), "out": fr * Vector3(0, 0, AIR_OUT), "facing": fr.basis.z.normalized(),
			"usable": bool(_sources[ids[i]].get("usable", false)), "clear_len": float(_sources[ids[i]].get("clear_len", 0.0))}


## The clear straight approach of air door i of deck k (MissionAirDoors.approach_len, plan data only): {ok, from (Vector3,
## the opening's centre on the wall plane, at mid height), to (Vector3, clear_len m straight into the deck along facing,
## same space as air_door().frame), clear_len (m, >= MissionAirDoors.APPROACH 30 for every door, at most REACH 80)}. A box
## the opening's size (12 m + 1 m a side, 6 m) flies from `from` to `to` without touching a building, pillar, column,
## ramp sign or ceiling opening. {ok = false} when there is no such door.
func air_door_approach(deck: int, i: int) -> Dictionary:
	var a := air_door(deck, i)
	if not bool(a.get("ok", false)):
		return {"ok": false}
	var cl := float(a["clear_len"])
	return {"ok": true, "from": a["center"], "to": (a["center"] as Vector3) + (a["facing"] as Vector3) * cl, "clear_len": cl}


## open_source for air door i of deck k (open_at: the leaves start to move; passable OPENING s later).
func open_air_door(deck: int, i: int, open_at: float, hold: float = HOLD) -> void:
	var ids: Array = _air.get(deck, [])
	if i >= 0 and i < ids.size():
		open_source(ids[i], open_at, hold)


## close_source (sealed for good) for air door i of deck k.
func close_air_door(deck: int, i: int) -> void:
	var ids: Array = _air.get(deck, [])
	if i >= 0 and i < ids.size():
		close_source(ids[i])


## source_state(...).passable for air door i of deck k (false when there is no such door).
func air_door_passable(deck: int, i: int) -> bool:
	var ids: Array = _air.get(deck, [])
	if i < 0 or i >= ids.size():
		return false
	return bool(source_state(ids[i])["passable"])


func _door_kind(id: Variant) -> String:
	return str(_sources.get(id, {}).get("kind", ""))


## Pose door `id` at t; fire its signals as their moments pass; returns true while it needs posing every frame.
func _pose_door(id: Variant, t: float, force: bool = false, fire: bool = true) -> bool:
	var kind := _door_kind(id)
	var sc: Array = _sched.get(id, [])
	var st := door_state(kind, sc, _seal_at(id), t)
	var state := str(st[0])
	var alarm_now := alarm_on(kind, sc, _seal_at(id), t)
	var door: Node3D = _doors.get(id)
	if door != null and is_instance_valid(door):
		var changed: bool = force or _door_state.get(id, "") != state
		if door is MissionGateDoor:
			var gd := door as MissionGateDoor
			gd.pose(state, float(st[1]), t, alarm_now, alarm_now and _heard(id))
			if changed:
				gd.door_shape.disabled = not gd.blocks(state)
			_light(id, door, kind, alarm_now or (not gd.bayless and (state == "opening" or state == "open")))
		elif door is MissionLiftDoor:
			var ld := door as MissionLiftDoor
			ld.pose(state, float(st[1]))
			if changed and ld.door_shape != null:
				ld.door_shape.disabled = not ld.blocks(state)
			_light(id, door, kind, ld.has_car and (state == "opening" or state == "open" or state == "closing"))
	_door_state[id] = state
	if fire:
		_fire_door(id, sc, t)
	return alarm_now or state == "warn" or state == "opening" or state == "closing"


## Whether source `id`'s siren is heard here: its deck is the stack's active deck (the viewer's, CityStack.follow), so
## sirens of gates on other decks stay quiet.
func _heard(id: Variant) -> bool:
	if stack == null:
		return true
	return int((_sources.get(id, {}) as Dictionary).get("deck", 0)) == stack.active_deck


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


## One small OmniLight3D per door while it is lit (none at GraphicsQuality.LOW), removed afterwards: a gate's hangs high in
## its staging bay while the leaves open and it stands open (the units waiting there readable); a lift car's high in the
## car while its doors open, stand open and close.
func _light(id: Variant, door: Node3D, kind: String, on: bool) -> void:
	on = on and quality != GraphicsQuality.LOW
	var l: OmniLight3D = _lights.get(id)
	if on and l == null:
		l = OmniLight3D.new()
		l.name = "WarnLight"
		l.shadow_enabled = false
		var d := door.get_parent() as CityDistrict
		if d != null:
			l.light_cull_mask = d.render_layer | 1
		if door is MissionGateDoor:
			l.light_color = CityPalette.C["strip"]
			l.light_energy = 3.0
			l.omni_range = 24.0
			l.position = (door as MissionGateDoor).light_point()
		else:      # a lift car's own light, lighting what stands in it while its doors are open
			l.light_color = CityPalette.C["strip"]
			l.light_energy = 3.0
			l.omni_range = 20.0
			l.position = (door as MissionLiftDoor).light_point()
		door.add_child(l)
		_lights[id] = l
	elif not on and l != null:
		if is_instance_valid(l):
			l.queue_free()
		_lights.erase(id)


# --- Flag, zones, asset, hold -------------------------------------------------------------------------------------------------

## Where flag objective `id` stands: {deck, x, s, h, snapped, ok, fit, moved_for_fit} ({} for unknown ids). ok = false: no
## clear ground inside the radius, the plan's site kept. fit: the widest mech reaches the zone (SiteFit.snap_fit);
## moved_for_fit: the old snap's pick was moved for that.
func flag_site(id: Variant) -> Dictionary:
	return (_sites.get(id, {}) as Dictionary).duplicate() if _flags.has(id) else {}


## Where defend objective `id`'s relay stands (as flag_site).
func asset_site(id: Variant) -> Dictionary:
	return (_sites.get(id, {}) as Dictionary).duplicate() if _assets.has(id) else {}


## The relay's collision body (group "mission_asset", meta objective_id) for Weapons to register as a damageable target.
func asset_body(id: Variant) -> StaticBody3D:
	var a: MissionRelayAsset = _assets.get(id)
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
	flag_event.emit(id, raised, (_flags[id] as MissionFlagMast).world_point())
	_next = -INF
	_pose_flag(id, now)


func flag_raised(id: Variant) -> bool:
	return bool((_flag_state.get(id, [false]) as Array)[0])


func _pose_flag(id: Variant, t: float) -> bool:
	var fs: Array = _flag_state[id]
	var u := clampf((t - float(fs[2])) / FLAG_SWAP, 0.0, 1.0)
	(_flags[id] as MissionFlagMast).pose(bool(fs[0]), bool(fs[1]), u)
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
	var a: MissionRelayAsset = _assets[id]
	var lv := asset_level(float(_asset_hp[id]))
	a.look(lv, quality != GraphicsQuality.LOW, a.get_parent().get("render_layer") if a.get_parent() != null else 1)
	a.blink(_blink_on)
	var told := int(_asset_told.get(id, 0))
	if lv >= 1 and told < 1:
		asset_event.emit(id, "damaged", a.world_point())
	if lv >= 2 and told < 2:
		asset_event.emit(id, "destroyed", a.world_point())
	_asset_told[id] = maxi(told, lv)


## DEPRECATED, draws nothing: the extraction portal and its curtain are gone (docs/design/city-spine.md §4: the crew
## leaves through the exit road door, exit_door()). Kept so MissionFlow's call (mission_flow.gd, _push "portal:") runs
## until Missions drops it; it only stores the value in portal_progress (read by tests/test_mission_objectives.gd).
func set_portal(p: float) -> void:
	portal_progress = clampf(p, 0.0, 1.0)


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
				(_assets[id] as MissionRelayAsset).blink(on)
		next = minf(next, t - phase + (BLINK * 0.6 if on else BLINK))
	_next = next


## The next moment after t at which door `id` changes state (INF: never).
func _next_moment(id: Variant, t: float) -> float:
	var seal := _seal_at(id)
	var ms: Array[float] = [seal, seal + CLOSE]
	var sc: Array = _sched.get(id, [])
	if not sc.is_empty() and t < seal:
		var t_open := passable_after(_door_kind(id))
		ms.append_array([float(sc[2]), float(sc[2]) + CLOSE, float(sc[0]) - WARN, float(sc[0]) + t_open, float(sc[0]), float(sc[1]),
				float(sc[1]) + CLOSE, alarm_from(sc)])
	var best := INF
	for m in ms:
		if m > t and m < best:
			best = m
	return best


# --- Quality, snapshot ------------------------------------------------------------------------------------------------------

## CityQuality level (local presentation): LOW drops the warning lights and the relay's particles.
func set_quality(q: int) -> void:
	quality = GraphicsQuality.clamp_level(q)
	for id: Variant in _doors:
		var ds := str(_door_state.get(id, ""))
		var gate := _doors[id] is MissionGateDoor
		var bayless := gate and (_doors[id] as MissionGateDoor).bayless
		_light(id, _doors[id], _door_kind(id), (alarm(id) or (not bayless and (ds == "opening" or ds == "open"))) if gate else (ds == "warn" or ds == "opening"))
	for id: Variant in _assets:
		_apply_asset(id)


## Everything a late joiner needs, in one message: door schedules (the entry / exit and tram doors' too), the sealed
## set, flags, zones, asset health, the hold zone, and the clock it was taken at.
func snapshot() -> Dictionary:
	var doors := {}
	for id: Variant in _sched:
		doors[id] = (_sched[id] as Array).duplicate()
	var flags := {}
	for id: Variant in _flag_state:
		flags[id] = (_flag_state[id] as Array).duplicate()
	return {"now": now, "doors": doors, "sealed": _sealed.duplicate(), "flags": flags, "zones": _zone_state.duplicate(),
			"assets": _asset_hp.duplicate(), "hold": hold_state}


## Take a snapshot() and show its state at its clock (no signal replays for moments already past).
func restore(d: Dictionary) -> void:
	if not setup_ready:
		return
	# From a peer (the host's mission.state): only the shapes snapshot() writes are believed; ids are bounded by this
	# machine's own sources / flags / assets, so nothing loops or allocates by the peer's numbers.
	now = float(d.get("now", now))
	_sched.clear()
	_fired.clear()
	var doors: Dictionary = d.get("doors", {}) if d.get("doors", {}) is Dictionary else {}
	for id: Variant in doors:
		if _sources.has(id) and doors[id] is Array and (doors[id] as Array).size() in [3, 4]:
			_sched[id] = (doors[id] as Array).duplicate()
			var sc: Array = _sched[id]
			if sc.size() == 3:              # a snapshot from before the gate alarm: the alarm starts ALARM_LEAD s before open_at
				sc.append(float(sc[0]) - ALARM_LEAD)
			else:                           # an older, longer lead is cut to the current rule
				sc[3] = clampf(float(sc[3]), float(sc[0]) - ALARM_LEAD, float(sc[0]))
			_fired[id] = {"warn": true, "open": true, "close": true, "seal": true}
			for pair: Array in [["warn", float(sc[0]) - WARN], ["open", float(sc[0])], ["close", float(sc[1])]]:
				(_fired[id] as Dictionary)[pair[0]] = now >= float(pair[1])
	_sealed.clear()
	var sealed: Variant = d.get("sealed", {})
	var at_of := {}                  # {id: seal_at}; an older array of ids means sealed since forever
	if sealed is Dictionary:
		at_of = sealed
	elif sealed is Array:
		for id: Variant in sealed:
			at_of[id] = -INF
	for id: Variant in at_of:
		if _sources.has(id):
			_sealed[id] = float(at_of[id])
			if not _fired.has(id):
				_fired[id] = {"warn": true, "open": true, "close": true}
			(_fired[id] as Dictionary)["seal"] = now >= float(at_of[id])
	var flags: Dictionary = d.get("flags", {}) if d.get("flags", {}) is Dictionary else {}
	for id: Variant in flags:
		if _flags.has(id) and flags[id] is Array and (flags[id] as Array).size() == 3:
			_flag_state[id] = (flags[id] as Array).duplicate()
	var zones: Dictionary = d.get("zones", {}) if d.get("zones", {}) is Dictionary else {}
	for id: Variant in zones:
		set_zone(id, str(zones[id]))
	var assets: Dictionary = d.get("assets", {}) if d.get("assets", {}) is Dictionary else {}
	for id: Variant in assets:
		if _assets.has(id):
			_asset_hp[id] = clampf(float(assets[id]), 0.0, 1.0)
			_asset_told[id] = asset_level(float(_asset_hp[id]))
			_apply_asset(id)
	set_hold_zone(str(d.get("hold", hold_state)))
	for id: Variant in _doors:
		_apply_default(id)          # a snapshot that does not name a door (an older one): its default
		_pose_door(id, now, true)
	for end: String in TRAM_IDS:
		if _doors.has(TRAM_IDS[end]):
			var sc: Array = _sched.get(TRAM_IDS[end], [])
			var open := tram_open(end) or (not sc.is_empty() and now < eff_open_at(sc) and float(sc[1]) > eff_open_at(sc))
			_tell_tram(end, open, eff_open_at(sc) if open and not sc.is_empty() else (float(sc[1]) if not sc.is_empty() else -INF))
	for id: Variant in _flags:
		_pose_flag(id, now)
	_next = -INF


# --- A stand-in plan (lab, tests) -------------------------------------------------------------------------------------------

## A Dictionary with MissionPlan's fields (§9) for stack st, until MissionPlan is usable: a gate source at every road-door
## gate without a role (not the entry / exit doors) of every deck (on the gate's road line, SOURCE_IN m inside the wall, `edge` named), a lift source at every stop of
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
				if str(g["kind"]) != "blast_door" or str(g.get("role", "")) != "":
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
					"params": {"zone": MissionRules.extraction_zone(sec, MissionRules.ZONE_DEPTH), "time": 60.0}})
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
