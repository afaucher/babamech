class_name CityStack
extends Node3D
## Every deck of one mission section in one scene (docs/design/city-ramps-and-stack.md): one CityDistrict per deck
## (Deck0, Deck1, ...), each built with build_deck() and placed at section.deck_offset(k), so all decks turn about one
## axis and the lowest deck's floor passes through the stack's origin. A mech walks or drops from deck to deck down the
## ramps and shafts; one RingFrame (ring()) is right everywhere because the axis is shared.
##
## One CityLightRig lights the stack. Deck k's meshes are on render layer bit k + 1 (layer 1 stays for mechs and the
## rest); every deck's fill lights light only its own layer, and the daylight lights and shadows only the ACTIVE deck,
## so decks never light or shadow each other. The active deck is local presentation: each machine uses the deck its
## camera (or its mech, follow()) is on. Gameplay state lives in the decks' plans and props, not here.
##
## QUALITY (CityQuality, local presentation only): set_quality(q) hides decks away from the active one (LOW: the active
## deck and the one below it; MEDIUM: and the one above), cuts the rig's fills, shadows and screen-space extras and
## shortens the block meshes' draw range; set_active_deck re-applies it. Plans, props, collision and checksums never change.
##
## Every deck's CityProps is in group "city_props"; systems that look one up should ask props_at(pos) when a node in
## group "city_stack" exists.
##
## FRAMES (verified by tests/test_city_stack.gd). The stack may be TRANSLATED (the test drive puts the entry deck's floor
## through the world origin: stack.position = -section.deck_offset(entry deck)) but never rotated or scaled. Deck k is a
## CityDistrict translated by section.deck_offset(k) = (0, radius_of(last) - radius_of(k), 0) inside the stack and NOT
## rotated; its own `ring` (radius radius_of(k)) has its axis at (0, radius_of(k), 0) in the deck's local frame, which is
## the same line for every k: all decks share one axis.
##   - Deck k's arc coordinates (x, s, h: s in metres on THAT deck, h above THAT deck's floor) are
##     `decks[k].ring.world_to_arc(decks[k].to_local(world))`, and back `decks[k].to_global(decks[k].ring.arc_to_world(..))`.
##     to_deck_arc() / from_deck_arc() do exactly that. Using decks[k].ring on WORLD positions directly is right only for
##     the deck whose floor passes through the world origin (the test drive's entry deck, `td.city`), and off by whole
##     pitches for every other deck.
##   - deck_ring(k) is a RingFrame that works in WORLD positions with deck k's arc coordinates (DeckRing below; it follows
##     the deck's global position, so it stays right when the stack is moved after build()): hand it to code written for
##     one district at the origin (EnemySpawner, EnemySquad, BotNavigator, CombatWorld, MechAudio).
##   - ring() is deck_ring(lowest deck). Its up_at / gravity_dir / basis_at / tangent_at (and basis_at_arc's basis) are
##     right at ANY world point of any deck, because they depend only on the shared axis: one mech frame for the whole
##     stack. Its height() / world_to_arc() are relative to the LOWEST floor (s in lowest-deck metres): right for the
##     fall-out check (height_above_bottom / fell_out), wrong as a deck's arc coordinates. Any deck's `ring` (e.g.
##     td.city.ring, when that deck sits at the origin) gives the same up / basis.

const FOLLOW_EVERY := 0.25       ## s between re-checks of which deck the followed node is on
const FOOT_SLACK := 1.0          ## m a point may be below a floor and still count as on it (feet, curbs, a dip)

var section: SectionPlan
var decks: Array[CityDistrict] = []
var rig: CityLightRig
var stats: Dictionary = {}       ## totals over the decks: triangles, shapes, buildings, props, ms (whole build)
var active_deck := 0
var quality := CityQuality.HIGH  ## local presentation (CityQuality): set_quality; never touches plans, props or collision
var _quality_touched := false    ## a level below HIGH was applied since the last HIGH (HIGH then restores every flag)

var mission: MissionWorld        ## the mission's doors, flag, asset and portal (setup_mission); null until fully set up
var _mission_wip: MissionWorld   ## a stepped mission setup in progress (setup_mission_begin), null otherwise
var _follow: Node3D
var _follow_in := 0.0
var _rings: Array[RingFrame] = []   ## deck_ring(k), made in build()

const CREW_GAP := 5.5            ## m at least between two mechs at the spawn (side by side they are 2 * CARRIAGE apart)
## m from the avenue lane's centre line to the middle of each carriageway: the lane is 18 m with a 3 m planted median down
## its centre (CityStreets._median, from 9 m past each junction edge: everywhere ENTRY_INSET lands), so a mech stands
## on the road between the median (1.5 m) and the lane's edge (9 m), its 2.2 m capsule clear of both.
const CARRIAGE := 5.25
const SLIDE_STEP := 2.0          ## m the whole spawn formation moves further in when a slot is blocked
const SLIDE_MAX := 30.0          ## m at most past ENTRY_INSET
const SPAWN_R := 2.2             ## m the mech's capsule radius
const SPAWN_CLEAR := 0.5         ## m kept between a capsule and a prop
const SPAWN_ROWS := 2            ## rows of the largest crew (4 mechs)

var _entry_slide := 0.0          ## m past ENTRY_INSET the formation starts (entry_slide(), from plan data in build())
const CREW_ROW := 8.0            ## m between two rows of the spawn, the second further into the map
const FALL_OUT := 25.0           ## m below the lowest floor: out of the map
## m from the entry road (6 m inside the entry wall) to the first spawn row, along the avenue into the map: the chase
## camera's boom (ChaseCamera.distance 16 m) + the mech's capsule radius (2.2 m) + 6 m margin, rounded up, so the camera
## starts well inside the wall instead of in the gate's recess.
const ENTRY_INSET := 26.0


## A RingFrame for one deck that takes and returns WORLD positions while its arc coordinates are that deck's own: radius
## radius_of(k), every point translated by the deck node's global position (read on every call, so moving the stack is
## fine; the deck is never rotated). Overrides only the primitives; height, world_to_arc, tangent_at, basis_at,
## basis_at_arc and gravity_dir go through them.
class DeckRing extends RingFrame:
	var deck: Node3D             ## the deck district whose position this ring follows
	var offset := Vector3.ZERO   ## used when the deck is gone or not in the tree: the deck's offset inside the stack

	func _init(r: float = 120.0, node: Node3D = null) -> void:
		super(r)
		deck = node
		if node != null:
			offset = node.position

	func origin() -> Vector3:
		if deck != null and is_instance_valid(deck):
			if deck.is_inside_tree():
				return deck.global_position
			var up := deck.get_parent() as Node3D
			return deck.position + (up.position if up != null else Vector3.ZERO)
		return offset

	func axis_point() -> Vector3:
		return super() + origin()

	func up_at(p: Vector3) -> Vector3:
		return super(p - origin())

	func dist_to_axis(p: Vector3) -> float:
		return super(p - origin())

	func angle(p: Vector3) -> float:
		return super(p - origin())

	func arc_to_world(x: float, s: float, h: float = 0.0) -> Vector3:
		return super(x, s, h) + origin()


func _init() -> void:
	add_to_group("city_stack")


## The render layers of deck k (a bit mask): bit k + 1.
static func deck_layer(k: int) -> int:
	return 1 << (k + 1)


## Build every deck of the section in one call (build_begin + build_step until done).
func build(sec: SectionPlan, overrides: Dictionary = {}) -> void:
	build_begin(sec, overrides)
	while not build_step(INF):
		pass


# --- Incremental build (docs/design/city-ramps-and-stack.md section 8) -----------------------------------------------
## build_begin() frees the old decks and resets; each build_step(budget_ms) runs chunks (each deck's CityDistrict chunks,
## then the light rig, then the entry) until budget_ms of wall time is spent, always at least one, and returns true once
## the stack is finished. The result is exactly build()'s. While building, the finished decks are in `decks` and in the
## tree, the deck being built is a child too, and checksum(), deck_ring(), entry_transform() and spawn_transforms() are
## valid only once build_done(). stats.ms = time spent inside the chunks (not between frames), stats.chunks and
## stats.max_chunk_ms; chunk_log = [[label, ms], ...] of every chunk in order ("d1 buildings 3/9").
enum Stage { IDLE, DECKS, RIG, ENTRY, DONE }

var chunk_log: Array = []
var _stage := Stage.IDLE
var _bk := 0                       ## the deck being built
var _building: CityDistrict        ## its district (not yet in `decks`)
var _overrides: Dictionary = {}
var _fills: Array = []
var _b_us := 0
var _b_max_us := 0


func build_begin(sec: SectionPlan, overrides: Dictionary = {}) -> void:
	for m: MissionWorld in [mission, _mission_wip]:
		if m != null:
			m.teardown(false)            # its pieces live under the decks freed below
			remove_child(m)
			m.queue_free()
	mission = null
	_mission_wip = null
	for d in decks:
		remove_child(d)
		d.queue_free()
	if _building != null and is_instance_valid(_building):
		remove_child(_building)
		_building.queue_free()
	_building = null
	decks.clear()
	_rings.clear()
	section = sec
	_overrides = overrides
	_fills = []
	chunk_log = []
	stats = {"triangles": 0, "shapes": 0, "buildings": 0, "props": 0}
	_bk = 0
	_b_us = 0
	_b_max_us = 0
	_stage = Stage.DECKS if sec.deck_count > 0 else Stage.RIG


## Run chunks until budget_ms of wall time is spent (at least one); true once the whole build is finished.
func build_step(budget_ms: float = 8.0) -> bool:
	var start := Time.get_ticks_usec()
	while _stage != Stage.DONE and _stage != Stage.IDLE:
		var t := Time.get_ticks_usec()
		var label := _chunk()
		var dt := Time.get_ticks_usec() - t
		_b_us += dt
		_b_max_us = maxi(_b_max_us, dt)
		chunk_log.append([label, float(dt) / 1000.0])
		if _stage == Stage.DONE:
			stats["ms"] = float(_b_us) / 1000.0
			stats["max_chunk_ms"] = float(_b_max_us) / 1000.0
			stats["chunks"] = chunk_log.size()
			break
		if float(Time.get_ticks_usec() - start) >= budget_ms * 1000.0:
			break
	return _stage == Stage.DONE


## 0..1 through the build (each deck one share, the rig and entry one more); never goes down. 0 before any build.
func build_progress() -> float:
	var n := float(section.deck_count + 1) if section != null else 1.0
	match _stage:
		Stage.IDLE:
			return 0.0
		Stage.DECKS:
			var part := _building.build_progress() if _building != null else 0.0
			return minf((float(_bk) + part) / n, (n - 1.0) / n)
		Stage.RIG:
			return (n - 1.0) / n
		Stage.ENTRY:
			return (n - 0.5) / n
	return 1.0


## True once the last build_begin's build is finished (false before any build and while one runs).
func build_done() -> bool:
	return _stage == Stage.DONE


## One chunk of the build; returns its label.
func _chunk() -> String:
	match _stage:
		Stage.DECKS:
			var k := _bk
			if _building == null:
				var nd := CityDistrict.new()
				nd.name = "Deck%d" % k
				nd.with_rig = false
				nd.render_layer = deck_layer(k)
				nd.position = section.deck_offset(k)
				add_child(nd)
				nd.build_deck_begin(section, k, _overrides)
				_building = nd
			var d := _building
			var finished := d.build_step()
			var label := "d%d %s" % [k, d.chunk_label]
			if finished:
				decks.append(d)
				_rings.append(DeckRing.new(d.ring.radius, d))
				for key: String in ["triangles", "shapes", "buildings", "props"]:
					stats[key] = int(stats[key]) + int(d.stats[key])
				_fills.append({"ring": d.ring, "offset": d.position, "area": d.plan.extent, "ceiling": d.plan.p("ceiling"),
						"strip_x": d.strip_x, "layer": deck_layer(k), "reach": minf(d.plan.p("ceiling") * 1.5, section.p("pitch") * 0.9)})
				_building = null
				_bk += 1
				if _bk >= section.deck_count:
					_stage = Stage.RIG
			return label
		Stage.RIG:
			if rig == null:
				rig = CityLightRig.new()
				add_child(rig)
			rig.setup_decks(_fills)
			_stage = Stage.ENTRY
			return "rig"
		Stage.ENTRY:
			_entry_slide = entry_slide()
			set_active_deck(active_deck)
			_stage = Stage.DONE
			return "entry"
	return ""


## Section checksum + every deck's plan checksum: equal on two machines = the same stack.
func checksum() -> String:
	var plans: Array[CityPlan] = []
	for d in decks:
		plans.append(d.plan)
	return sum_of(section, plans)


static func sum_of(sec: SectionPlan, plans: Array[CityPlan]) -> String:
	var all := sec.checksum()
	for p in plans:
		all += p.checksum()
	return all.sha256_text().substr(0, 16)


## The deck whose floor is the nearest one below the point (by its distance from the shared axis).
func deck_at(world_pos: Vector3) -> int:
	if decks.is_empty():
		return 0
	var d := ring().dist_to_axis(world_pos)
	for k in decks.size():
		if d <= section.radius_of(k) + FOOT_SLACK:
			return k
	return decks.size() - 1


## The lowest deck's frame in world positions (deck_ring): the axis is shared, so its up_at / basis_at are right on every
## deck; its height() is above the lowest floor.
func ring() -> RingFrame:
	return deck_ring(decks.size() - 1)


## Where the first mech stands: ENTRY_INSET m into the map from the section's entry road (entry_gate_transform), on the
## avenue lane's left-hand carriageway (CARRIAGE left of the median, so the chase camera's right shoulder offset puts it
## over the avenue's middle), facing into the map, 0.3 m above the floor. Far enough in that the chase camera behind it
## is inside the end wall too (on the entry line itself the camera sat outside the wall, looking in through the gate's
## recess).
func entry_transform() -> Transform3D:
	return _avenue_transform(ENTRY_INSET + _entry_slide, -CARRIAGE)


## How far past ENTRY_INSET the spawn formation must start so that all four slots (two rows, one column per
## carriageway) are clear: no prop within the capsule + SPAWN_CLEAR, no floor cut, ramp mouth or kept-clear ground under
## the capsule, no checkpoint or cordon line across it, and the last row short of the first cross street. Steps of
## SLIDE_STEP up to SLIDE_MAX (then SLIDE_MAX). From plan data and the props' initial layout only (call right after
## build): the same on every machine.
func entry_slide() -> float:
	var k := int(section.entry["deck"])
	var j := int(section.entry["j"])
	var d := decks[k]
	var into := 1.0 if j == 0 else -1.0
	var av := section.lane_x("avenue")
	var mid := (av.x + av.y) * 0.5
	var s0 := section.line_s(k, j)
	var next_line := section.line_s(k, j + int(into))
	var cuts := d.plan.floor_cuts()
	var slide := 0.0
	while slide < SLIDE_MAX:
		var ok := true
		for row in SPAWN_ROWS:
			var s := s0 + into * (ENTRY_INSET + slide + CREW_ROW * float(row))
			if (next_line - s) * into < SectionPlan.ARTERIAL_W * 0.5 + SPAWN_R + 1.0:
				ok = false
			for side: float in [-1.0, 1.0]:
				if ok and not _slot_clear(d, Vector2(mid + side * CARRIAGE, s), cuts, k):
					ok = false
		if ok:
			return slide
		slide += SLIDE_STEP
	return SLIDE_MAX


func _slot_clear(d: CityDistrict, at: Vector2, cuts: Array[Rect2], k: int) -> bool:
	if d.props != null:
		for it: Dictionary in d.props.items:
			var r := float(CityPropSim.TYPES[it["type"]]["radius"])
			if Vector2(float(it["x"]), float(it["s"])).distance_to(at) - r < SPAWN_R + SPAWN_CLEAR:
				return false
	var box := Rect2(at - Vector2(SPAWN_R, SPAWN_R), Vector2(SPAWN_R, SPAWN_R) * 2.0)
	for o in cuts:
		if o.grow(CityStreets.HOLE_CURB + 0.5).intersects(box):
			return false
	for c in d.plan.site.keep_clear:
		if (c as Rect2).intersects(box):
			return false
	for hk: Dictionary in section.hooks:
		if int(hk["deck"]) != k or not (hk["kind"] == "checkpoint" or hk["kind"] == "cordon"):
			continue
		if absf(float(hk["s"]) - at.y) < SPAWN_R + 4.0:
			return false
	return true


## The entry road node itself (the perimeter road just inside the entry gate), on the avenue lane's centre, facing into
## the map, 0.3 m above the floor: where the crew comes through the wall, not where it stands.
func entry_gate_transform() -> Transform3D:
	return _avenue_transform(0.0, 0.0)


## A transform on the entry deck, `in_m` metres into the map from the entry road along the avenue lane and `right` m to
## the right (facing into the map) of the lane's centre line, facing into the map, 0.3 m above the floor, in the stack's
## parent frame.
func _avenue_transform(in_m: float, right: float) -> Transform3D:
	var k := int(section.entry["deck"])
	var j := int(section.entry["j"])
	var d := decks[k]
	var av := section.lane_x("avenue")
	var into := 1.0 if j == 0 else -1.0
	var s := section.line_s(k, j) + into * in_m
	var c := d.ring.arc_to_world((av.x + av.y) * 0.5, s, 0.3)
	var side := signf(d.ring.basis_at(c, d.ring.tangent_at(c) * into).x.x)   # +1 when the mech's right is +x
	var p := d.ring.arc_to_world((av.x + av.y) * 0.5 + side * right, s, 0.3)
	var local := Transform3D(d.ring.basis_at(p, d.ring.tangent_at(p) * into), p)
	return (d.global_transform if d.is_inside_tree() else transform * d.transform) * local


func props_at(world_pos: Vector3) -> CityProps:
	return decks[deck_at(world_pos)].props


# --- For callers written for one CityDistrict (the test drive's `city`, combat, audio, enemies, bots) ---------------

## The deck district under the point (deck_at).
func district_at(world_pos: Vector3) -> CityDistrict:
	return decks[deck_at(world_pos)]


## The plan of the deck under the point.
func plan_at(world_pos: Vector3) -> CityPlan:
	return decks[deck_at(world_pos)].plan


## Deck k's ring in world positions with deck k's arc coordinates (see FRAMES in the header).
func deck_ring(k: int) -> RingFrame:
	return _rings[clampi(k, 0, _rings.size() - 1)]


## deck_ring of the deck under the point.
func ring_at(world_pos: Vector3) -> RingFrame:
	return deck_ring(deck_at(world_pos))


## The point in the arc coordinates of the deck under it: {deck, x, s, h} (h above that deck's floor).
func to_deck_arc(world_pos: Vector3) -> Dictionary:
	var k := deck_at(world_pos)
	var d := decks[k]
	var a := d.ring.world_to_arc(d.to_local(world_pos) if d.is_inside_tree() else world_pos - position - d.position)
	return {"deck": k, "x": a.x, "s": a.y, "h": a.z}


## World position of (x, s, h) in deck k's arc coordinates (the inverse of to_deck_arc).
func from_deck_arc(deck: int, x: float, s: float, h: float = 0.0) -> Vector3:
	var d := decks[clampi(deck, 0, decks.size() - 1)]
	var p := d.ring.arc_to_world(x, s, h)
	return d.to_global(p) if d.is_inside_tree() else p + position + d.position


## Height of the point above the LOWEST deck's floor (negative below it): the fall-out check.
func height_above_bottom(world_pos: Vector3) -> float:
	return ring().height(world_pos)


## True once the point is more than `below` m under the lowest floor (fell out of the map).
func fell_out(world_pos: Vector3, below: float = FALL_OUT) -> bool:
	return height_above_bottom(world_pos) < -below


## Where n mechs (1..4) start, in seat order, the same on every machine: the first at entry_transform() when alone;
## otherwise two columns, one on each carriageway of the avenue lane (CARRIAGE either side of its median), and rows
## CREW_ROW apart going into the map from the first spawn row (ENTRY_INSET + entry_slide() in from the entry road), a lone mech in the
## last row on the left-hand carriageway like the first. All face into the map, 0.3 m above the road.
func spawn_transforms(n: int) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	n = clampi(n, 1, 4)
	if n == 1:
		out.append(entry_transform())
		return out
	for i in n:
		var row := i / 2
		var in_row := mini(n - row * 2, 2)
		var right := -CARRIAGE if in_row == 1 or i % 2 == 0 else CARRIAGE
		out.append(_avenue_transform(ENTRY_INSET + _entry_slide + CREW_ROW * float(row), right))
	return out


## The deck the daylight lights and shadows (local presentation).
func set_active_deck(k: int) -> void:
	active_deck = clampi(k, 0, maxi(decks.size() - 1, 0))
	if rig != null:
		rig.light_layers(CityLightRig.ALWAYS | deck_layer(active_deck))
	apply_quality()


## Keep the active deck on whichever deck `node` stands on (null stops).
func follow(node: Node3D) -> void:
	_follow = node
	_follow_in = 0.0


func _process(delta: float) -> void:
	if _follow == null or decks.is_empty() or not build_done():
		return
	if not is_instance_valid(_follow):
		_follow = null
		return
	_follow_in -= delta
	if _follow_in <= 0.0:
		_follow_in = FOLLOW_EVERY
		var k := deck_at(_follow.global_position)
		if k != active_deck:
			set_active_deck(k)


# --- Quality (CityQuality: local presentation only) -----------------------------------------------------------------

## Draw level q (CityQuality.LOW / MEDIUM / HIGH): which decks are drawn round the active one, the rig's lights and
## extras, how far block meshes are drawn. Any time, before or after build(), switchable at runtime; follows the active
## deck (set_active_deck re-applies it). Never touches a plan, a prop, a collision shape or anything synced: a hidden
## deck keeps its collision, its props simulation and its life. HIGH (the default) is the look before levels existed.
func set_quality(q: int) -> void:
	quality = CityQuality.clamp_level(q)
	apply_quality()
	if mission != null:
		mission.set_quality(quality)


# --- Mission world (docs/design/city-ramps-and-stack.md "Mission world (phase 1)") ----------------------------------

## Put the mission's pieces in the built stack (wave doors, flag masts, defend relays, the extraction portal and its hold
## zone) from `plan` (a MissionPlan, or a Dictionary with its fields): a MissionWorld, also kept as `mission`. A second
## call replaces the first; a new build() frees it. Without it the stack looks and collides exactly as before.
func setup_mission(plan: Variant) -> MissionWorld:
	setup_mission_begin(plan)
	while not setup_mission_step(INF):
		pass
	return mission


## Start setup_mission without running it (frees the current mission, or one being set up); setup_mission_step does the
## work in chunks (MissionWorld.setup_step). `mission` stays null until setup_mission_done().
func setup_mission_begin(plan: Variant) -> void:
	for m: MissionWorld in [mission, _mission_wip]:
		if m != null:
			m.teardown(true)
			remove_child(m)
			m.queue_free()
	mission = null
	_mission_wip = MissionWorld.new()
	_mission_wip.name = "Mission"
	add_child(_mission_wip)
	_mission_wip.quality = quality
	_mission_wip.setup_begin(self, plan)


## Run mission setup chunks until budget_ms of wall time is spent (at least one); true once finished (and on later calls),
## when `mission` becomes the finished MissionWorld. False when no setup was begun.
func setup_mission_step(budget_ms: float = 8.0) -> bool:
	if _mission_wip == null:
		return mission != null
	if _mission_wip.setup_step(budget_ms):
		mission = _mission_wip
		_mission_wip = null
		mission.set_quality(quality)
		return true
	return false


func setup_mission_done() -> bool:
	return _mission_wip == null and mission != null


## 0..1 through the mission setup (1 once done; 0 when none was begun).
func setup_mission_progress() -> float:
	if _mission_wip != null:
		return _mission_wip.setup_progress()
	return 1.0 if mission != null else 0.0


## Re-apply the current quality to everything built (set_active_deck calls it, so it runs at the end of every build).
## Nothing is touched while the level is HIGH and no lower level was ever applied.
func apply_quality() -> void:
	if quality == CityQuality.HIGH and not _quality_touched:
		return
	_quality_touched = quality != CityQuality.HIGH
	var lv := CityQuality.level(quality)
	var shown: Array = []
	for k in decks.size():
		var on := CityQuality.deck_drawn(quality, k, active_deck)
		shown.append(on)
		decks[k].visible = on
		_set_block_range(decks[k], float(lv["block_range"]))
	if rig != null:
		var mask := CityLightRig.ALWAYS | deck_layer(active_deck)
		if bool(lv["sun_below"]) and active_deck + 1 < decks.size() and bool(shown[active_deck + 1]):
			mask |= deck_layer(active_deck + 1)
		rig.light_layers(mask)
		rig.set_quality(quality, shown, active_deck)


## Decks drawn now (CityQuality.deck_drawn for the active deck): for tests and the perf probe.
func decks_drawn() -> Array[int]:
	var out: Array[int] = []
	for k in decks.size():
		if decks[k].visible:
			out.append(k)
	return out


## Every block mesh of deck d (Buildings/Block<n>) hidden beyond `range_m` m from the camera (0: always drawn).
static func _set_block_range(d: CityDistrict, range_m: float) -> void:
	var holder := d.get_node_or_null("Buildings")
	if holder == null:
		return
	for c in holder.get_children():
		if c is GeometryInstance3D and str(c.name).begins_with("Block"):
			(c as GeometryInstance3D).visibility_range_end = range_m
