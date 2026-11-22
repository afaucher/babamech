class_name CityStack
extends Node3D
## Every deck of one mission section in one scene (docs/design/city-ramps-and-stack.md): one CityDistrict per deck
## (Deck0, Deck1, ...), each built with build_deck() and placed at section.deck_offset(k), so all decks turn about one
## axis and the lowest deck's floor passes through the world origin. A mech walks or drops from deck to deck down the
## ramps and shafts; one RingFrame (ring()) is right everywhere because the axis is shared.
##
## One CityLightRig lights the stack. Deck k's meshes are on render layer bit k + 1 (layer 1 stays for mechs and the
## rest); every deck's fill lights light only its own layer, and the daylight lights and shadows only the ACTIVE deck,
## so decks never light or shadow each other. The active deck is local presentation: each machine uses the deck its
## camera (or its mech, follow()) is on. Gameplay state lives in the decks' plans and props, not here.
##
## Every deck's CityProps is in group "city_props"; systems that look one up should ask props_at(pos) when a node in
## group "city_stack" exists.

const FOLLOW_EVERY := 0.25       ## s between re-checks of which deck the followed node is on
const FOOT_SLACK := 1.0          ## m a point may be below a floor and still count as on it (feet, curbs, a dip)

var section: SectionPlan
var decks: Array[CityDistrict] = []
var rig: CityLightRig
var stats: Dictionary = {}       ## totals over the decks: triangles, shapes, buildings, props, ms (whole build)
var active_deck := 0

var _follow: Node3D
var _follow_in := 0.0


func _init() -> void:
	add_to_group("city_stack")


## The render layers of deck k (a bit mask): bit k + 1.
static func deck_layer(k: int) -> int:
	return 1 << (k + 1)


func build(sec: SectionPlan, overrides: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_msec()
	for d in decks:
		remove_child(d)
		d.queue_free()
	decks.clear()
	section = sec
	var fills := []
	stats = {"triangles": 0, "shapes": 0, "buildings": 0, "props": 0}
	for k in sec.deck_count:
		var d := CityDistrict.new()
		d.name = "Deck%d" % k
		d.with_rig = false
		d.render_layer = deck_layer(k)
		d.position = sec.deck_offset(k)
		add_child(d)
		d.build_deck(sec, k, overrides)
		decks.append(d)
		for key: String in stats:
			stats[key] = int(stats[key]) + int(d.stats[key])
		fills.append({"ring": d.ring, "offset": d.position, "area": d.plan.extent, "ceiling": d.plan.p("ceiling"),
				"strip_x": d.strip_x, "layer": deck_layer(k), "reach": minf(d.plan.p("ceiling") * 1.5, sec.p("pitch") * 0.9)})
	if rig == null:
		rig = CityLightRig.new()
		add_child(rig)
	rig.setup_decks(fills)
	set_active_deck(active_deck)
	stats["ms"] = Time.get_ticks_msec() - t0


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
	var d := ring().dist_to_axis(to_local(world_pos) if is_inside_tree() else world_pos)
	for k in decks.size():
		if d <= section.radius_of(k) + FOOT_SLACK:
			return k
	return decks.size() - 1


## The lowest deck's frame: the axis is shared, so its up_at / basis_at are right on every deck.
func ring() -> RingFrame:
	return decks[-1].ring


## Where the crew comes in: on the section's entry road node, on the avenue lane, facing into the map, 0.3 m above the
## floor.
func entry_transform() -> Transform3D:
	var k := int(section.entry["deck"])
	var j := int(section.entry["j"])
	var d := decks[k]
	var av := section.lane_x("avenue")
	var s := section.line_s(k, j)
	var p := d.ring.arc_to_world((av.x + av.y) * 0.5, s, 0.3)
	var into := d.ring.tangent_at(p) * (1.0 if j == 0 else -1.0)
	var local := Transform3D(d.ring.basis_at(p, into), p)
	return (d.global_transform if d.is_inside_tree() else d.transform) * local


func props_at(world_pos: Vector3) -> CityProps:
	return decks[deck_at(world_pos)].props


## The deck the daylight lights and shadows (local presentation).
func set_active_deck(k: int) -> void:
	active_deck = clampi(k, 0, maxi(decks.size() - 1, 0))
	if rig != null:
		rig.light_layers(1 | deck_layer(active_deck))


## Keep the active deck on whichever deck `node` stands on (null stops).
func follow(node: Node3D) -> void:
	_follow = node
	_follow_in = 0.0


func _process(delta: float) -> void:
	if _follow == null or decks.is_empty():
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
