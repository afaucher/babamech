extends TestCase
## The world z-fighting audit (tools/geometry_audit/world_zfight_audit.gd, docs/design/city-geometry-audit.md) on a
## small case: section seed 4's stack with its mission, deck 0 only (the ramp's head, the cut, its curbs, a farm wall,
## bulkheads, every building style but civic, the ceiling and the deck above's soffits seen from below). Fails on any
## group of z-fighting findings (near-coplanar, same facing, different colour, closer than 2 cm, overlapping) over
## AREA_MAX m^2 that is not in ALLOWED with a written reason. Also checks the decal rule's constants and that tagging
## (CityGeo.audit) leaves geometry_digest() unchanged. The whole stack, every deck: run_world_zfight_audit.ps1.

const SEED := 4
const DECK := 0
const AREA_MAX := 1.0          ## m^2 of overlap per group (pairs of labels) tolerated without a reason
## "A|B" (labels sorted) -> why it is not a z-fight anyone sees.
const ALLOWED := {
	"Walls:wall.bulkhead|Walls:wall.bulkhead": "back faces of a bulkhead's buttress posts and base / gallery boxes on the wall's own plane, facing out of the map (behind a solid 6 m wall); where wall facets meet, the classifier misses the wall face under them, so they are not all counted as 'buried'",
	"Walls:wall.bulkhead|Walls:wall.farm": "the corner where a bulkhead meets a farm wall: the end post's and boxes' back and side faces inside the other wall's solid",
}


func setup() -> void:
	timeout_sec = 180.0
	eq(CityStreets.DECAL_LINE - CityStreets.DECAL_PATCH, 0.02, "decal layers are 2 cm apart")
	check(CityStreets.DECAL_PATCH >= 0.02 and CityStreets.MARK == CityStreets.DECAL_LINE, "markings are a decal layer, at least 2 cm up")
	var sec := SectionPlan.make({"seed": SEED})
	# Tagging must not change a single vertex or colour.
	var plain := CityDistrict.new()
	plain.with_rig = false
	add_child(plain)
	plain.build_deck(sec, DECK)
	var digest := plain.geometry_digest()
	remove_child(plain)
	plain.free()
	CityGeo.audit = true
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	eq(stack.decks[DECK].geometry_digest(), digest, "CityGeo.audit tags leave geometry_digest() unchanged")
	stack.setup_mission(MissionPlan.make(sec))
	CityGeo.audit = false
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var audit := WorldZfightAudit.new()
	audit.deck_of = stack.deck_at
	audit.arc_of = stack.to_deck_arc
	audit.add_node(stack.decks[DECK])
	if stack.mission != null:
		audit.add_node(stack.mission)
	audit.run(DECK)
	for line in audit.report(25):
		print("[zfight] " + line)
	print("[zfight] deck %d audited in %d ms" % [DECK, Time.get_ticks_msec() - t0])
	check(audit.tri_count() > 100000, "the deck's geometry was collected (%d triangles)" % audit.tri_count())
	for g: Dictionary in audit.sorted_groups("finding"):
		var key := "%s|%s" % [g["a"], g["b"]]
		if float(g["area"]) <= AREA_MAX or ALLOWED.has(key):
			continue
		check(false, "z-fighting: " + audit.describe(g))
	finish()
