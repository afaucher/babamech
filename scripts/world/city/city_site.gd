class_name CitySite
extends RefCounted
## What a district is GIVEN before it is planned: the structure it shares with the decks above and below
## (docs/design/ceiling-and-pillars.md). The city generator never invents pillar positions: pillars are load-bearing
## columns that run through every deck on the same radial line, so they come from the section plan
## (scripts/world/section/, `from_section`) or, for a district on its own (the lab, the S3 arena), from `stub`.
##
##   pillars    [{x, s, half, kind, lift}]   centre in this district's arc coordinates, half width of the structural core,
##                                           kind: urban | park | industrial | transit | lift
##   openings   [Rect2]                      holes in THIS deck's ceiling (= cuts in the floor of the deck above: open-air
##                                           shafts, ramp cuts), in this deck's arc coordinates
##   keep_clear [Rect2]                      ground that must stay unbuilt (shaft landings, ramp feet)
##   floor_holes [Rect2]                     holes in THIS deck's floor (ramp cuts between the cross roads that bridge
##                                           them, open-air shafts): no ground, no collision, a curb and railing round
##   slab       float                        thickness of the deck above (what you see in the side of an opening)

const CORE_HALF := {"urban": 7.5, "park": 2.0, "industrial": 5.0, "open": 3.0, "transit": 7.0, "lift": 12.0}
const JITTER := 6.0

var pillars: Array = []
var openings: Array[Rect2] = []
var keep_clear: Array[Rect2] = []
var floor_holes: Array[Rect2] = []
var slab := 8.0


## A stand-in structure for a district planned on its own: one pillar per structural bay of `plan.p("pillar_bay")`,
## moved to the nearest spot inside a block (never in a road), a seeded few of them freight-lift pillars. Call after the
## plan's blocks exist. `avoid` is a block index that stays column-free (the civic block: a long-span bay).
static func stub(plan: CityPlan, avoid: int, park: int) -> CitySite:
	var site := CitySite.new()
	var bay := plan.p("pillar_bay")
	var seed_ := int(plan.p("seed"))
	var e := plan.extent
	var ni := int(ceil(e.size.x * 0.5 / bay))
	var nj := int(ceil(e.size.y * 0.5 / bay))
	for i in range(-ni, ni):
		for j in range(-nj, nj):
			var h := _mix(seed_, i, j)
			var want := Vector2((float(i) + 0.5) * bay + (float(h % 13) / 6.0 - 1.0) * JITTER,
					(float(j) + 0.5) * bay + (float((h / 13) % 13) / 6.0 - 1.0) * JITTER)
			if not e.has_point(want):
				continue
			var lift := (h / 169) % 5 == 0
			var best := Vector2.ZERO
			var best_d := 1e9
			var best_kind := ""
			for bi in plan.blocks.size():
				if bi == avoid:
					continue
				var zone: Rect2 = (plan.blocks[bi]["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
				var kinds: Array = ["park"] if bi == park else (["lift", "urban"] if lift else ["urban"])
				for kind: String in kinds:
					var room := zone.grow(-float(CORE_HALF[kind]) - 1.0)
					if room.size.x < 0.0 or room.size.y < 0.0:
						continue
					var q := Vector2(clampf(want.x, room.position.x, room.end.x), clampf(want.y, room.position.y, room.end.y))
					if q.distance_to(want) < best_d - 0.01:
						best_d = q.distance_to(want)
						best = q
						best_kind = kind
					break
			if best_kind == "" or best_d > bay * 0.5:
				continue
			var clash := false
			for q: Dictionary in site.pillars:
				if Vector2(q["x"], q["s"]).distance_to(best) < bay * 0.55:
					clash = true
			if not clash:
				site.pillars.append({"x": snappedf(best.x, 0.01), "s": snappedf(best.y, 0.01), "half": float(CORE_HALF[best_kind]),
						"kind": best_kind, "lift": best_kind == "lift"})
	if plan.p("atrium") >= 0.5 and park >= 0:
		site.openings.append((plan.blocks[park]["rect"] as Rect2).grow(-10.0))
	return site


## The structure of deck `deck` of a mission section, for a district whose origin (its avenue / cross-street crossing)
## sits at `origin` (x, s on that deck) and which reaches `reach` from it each way. Reads the section plan; never edits it.
## `section` is a SectionPlan (untyped here so the city code has no hard dependency on the section code).
static func from_section(section: Object, deck: int, origin: Vector2, reach: Vector2) -> CitySite:
	var site := CitySite.new()
	site.slab = float(section.p("slab"))
	var area := Rect2(-reach, reach * 2.0)
	for q: Dictionary in section.pillars:
		var id := int(q["id"])
		var at: Vector2 = section.pillar_point(deck, id) - origin
		if not area.has_point(at):
			continue
		var kind := str(section.pillar_style(deck, id))
		site.pillars.append({"x": snappedf(at.x, 0.01), "s": snappedf(at.y, 0.01), "half": float(CORE_HALF.get(kind, 7.5)),
				"kind": kind, "lift": kind == "lift"})
	for r: Rect2 in section.decks[deck]["keep_clear"]:
		var local := Rect2(r.position - origin, r.size)
		if area.intersects(local):
			site.keep_clear.append(local)
	# This deck's ceiling is the floor of the deck above (deck - 1: decks count outward from the axis).
	if deck > 0:
		var scale := float(section.radius_of(deck)) / float(section.radius_of(deck - 1))
		for ci in section.connectors.size():
			if section.is_hole(ci, deck - 1):
				var r: Rect2 = section.connector_rect(ci, deck - 1)
				var local := Rect2(r.position.x - origin.x, r.position.y * scale - origin.y, r.size.x, r.size.y * scale)
				if area.intersects(local):
					site.openings.append(local)
	return site


## The structure of a whole deck of a mission section, in that deck's own coordinates (no origin shift): every pillar
## with the section's core size, the holes in its ceiling and floor, and the ground kept clear: the shaft landings, and
## the footprint of every ramp coming down onto this deck (its viaduct lands there). The floor holes are the section's
## raw connector rects: CityPlan.for_deck cuts the cross roads out of them (they bridge a ramp's cut).
static func for_deck(section: SectionPlan, deck: int) -> CitySite:
	var site := CitySite.new()
	site.slab = section.p("slab")
	for q: Dictionary in section.pillars:
		var id := int(q["id"])
		var at := section.pillar_point(deck, id)
		var kind := section.pillar_style(deck, id)
		site.pillars.append({"x": snappedf(at.x, 0.01), "s": snappedf(at.y, 0.01), "half": section.pillar_radius(deck, id),
				"kind": kind, "lift": kind == "lift", "id": id, "col": int(q["col"]), "row": int(q["row"])})
	for r: Rect2 in section.decks[deck]["keep_clear"]:
		site.keep_clear.append(r)
	for ci in section.connectors.size():
		if section.is_hole(ci, deck):
			site.floor_holes.append(section.connector_rect(ci, deck))
		if deck > 0 and section.is_hole(ci, deck - 1):
			site.openings.append(section.connector_rect(ci, deck))
		var cn: Dictionary = section.connectors[ci]
		if cn["kind"] == "ramp" and int(cn["to"]) == deck:
			site.keep_clear.append(section.connector_rect(ci, deck))
	return site


## Bytes for the plan's checksum: the structure is part of the gameplay shape.
func put(buf: StreamPeerBuffer) -> void:
	for q: Dictionary in pillars:
		for v: float in [q["x"], q["s"], q["half"]]:
			buf.put_32(int(round(v * 1000.0)))
		buf.put_utf8_string(str(q["kind"]))
	for r: Rect2 in openings + keep_clear:
		for v: float in [r.position.x, r.position.y, r.size.x, r.size.y]:
			buf.put_32(int(round(v * 1000.0)))
	buf.put_32(openings.size())


static func _mix(seed_: int, i: int, j: int) -> int:
	var h := (seed_ * 73856093) ^ (i * 19349663) ^ (j * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16)) % 1000003
