class_name CityPlan
extends RefCounted
## The layout of one urban district on a ring deck, as plain data (no nodes): street grid -> blocks -> lots -> buildings.
## Everything here is GAMEPLAY geometry (what you walk on, stand on and hide behind), generated from `params` alone with
## one seeded generator, so every machine builds the same district and `checksum()` proves it (AGENTS.md rule 4, game
## design 3.5). Looks that don't affect play (window patterns, colours, fixed street furniture) are rolled later by the
## meshers from `cosmetic_seed()`, a separate stream, and are not in the checksum. Skylights, the office plant room and
## the civic portico are solid, so they are plan data here; loose roof units are CityProps (CityPropLayout.layout).
##
## Coordinates are arc coordinates of the deck: x along the ring axis (level), s along the spin direction (the floor
## curves up), heights above the floor. A Rect2 is (x, s) position + size. The origin is the crossing of the central
## avenue (runs along s, so it climbs the curve) and a cross street.
## SECTION MODE (`for_deck`, docs/design/city-section-mode.md): one plan is one whole deck of a mission section. The
## section imposes the road grid, one block per cell with its zone, the pillars, floor holes and walls; coordinates are
## the deck's own (x = 0 on the section centre line, s = 0 mid-arc) and the avenue is the spine's avenue lane.
##
##   roads_x / roads_s   [{a, b, kind}]  road strips at constant x (running along s) / at constant s (along x)
##                       kind: avenue | street (stand-alone), spine | arterial | cross | perimeter (section); a spine
##                       carries `lanes` [{lane, a, b}]
##   blocks              [{rect, ix, is, kind}]   kind: built | park, and in section mode industrial | transit | open,
##                                                plus `zone` (the section's zone of the cell)
##   lots                [{rect, block, kind, building, front}] kind: building | open ; open lots carry `open`
##   buildings           [{lot, style, band, floors, roof_h, center, size, front, tiers, pillar}]
##     tiers             [{off, size, y0, y1, stand}]  boxes in the building's own frame (off/size in x,s), stand = a roof
##                       a mech can land on
##   ramps               [{connector, role, x0, x1, s_top, s_foot, h_top, h_foot}]  section mode: the part of each ramp
##                       between decks that lies on this deck (docs/design/city-ramps-and-stack.md). role "top": on the
##                       deck it leaves, h from 0 (flush at its top cross line) down to -(slab + 1); "bottom": on the deck
##                       it lands on, h from the clear height (out of the ceiling) down to 0 (flush at its foot cross
##                       line). The height is linear in s between the two ends (ramp_height).
##     kind              optional: "plant" (an office's roof plant room), "entablature" (the civic portico's beam box)
##   solids              [{kind, off, size, y0, y1}]  smaller solid boxes in the building's frame (docs/design/city-rooftops.md):
##                       kind column (civic portico), step (civic front steps), skylight (a walkable roof bump; its
##                       glass ridge runs along the longer side)
##   gable               civic only: {off, w, d, y0, rise, front} the pitched roof, ridge along the front direction
##   columns[].ring_r/h  the planted stone ring round a park column's foot: radius, top height
## DOWNTOWN (docs/design/city-downtown.md): a seeded contiguous zone of blocks (`block["downtown"]` true; a section's
## `zone` stays the section's) whose lots carry ceiling-touching towers of style "tower" on six bases (`base`: podium,
## stepped, plaza, corner, twin, arcade; a pillar in the zone gets podium or plaza). Tier kinds there: podium, terrace,
## lobby, arcade (the arcade's roof over its walk-under gallery) and tower (a shaft, `tower`: slab | point, not standable,
## up into the ceiling); solids kind column (the arcade's). `paving` [Rect2] and `planters` are looks (plaza ground).
## Sides are numbered 0:+x 1:-x 2:+s 3:-s.

const FLOOR_H := 3.25        ## storey height (m)
const SIDEWALK := 4.0        ## curb to building line (m)
const CURB_H := 0.2
const STREET_W := 12.0       ## two lanes + two parking strips
const AVENUE_W := 20.0       ## four lanes + median
const LOT_MAX := 26.0
const LOT_MIN := 11.0
const PILLAR_APRON := 4.0    ## a pillar tower's lot reaches this far past its structural core
## A cross road may bridge a ramp's cut only where a mech walking down the ramp fits under it with a margin: the clear
## height from the ramp's surface to the bridge's underside (bridge_clearance) is at least BRIDGE_CLEAR. MECH_TOP is the
## mech's collision capsule top (MechSpawn: height 4.0 x mech_scale 2.0; the drawn mech is about 8 m too).
const MECH_TOP := 8.0
const BRIDGE_CLEAR := MECH_TOP + 1.5
const STYLES := ["apartment", "office", "sage", "shops", "civic", "pillar", "tower"]
const BANDS := {"apartment": [1, 3], "office": [2, 4], "sage": [1, 3], "shops": [0, 0], "civic": [1, 1], "pillar": [1, 1]}
const SIDE_N: Array[Vector2] = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
const SIDE_EDGE: Array[String] = ["x1", "x0", "s1", "s0"]     ## the section's name for each side's wall
const ZONE_KIND := {"urban": "built", "park": "park", "industrial": "industrial", "transit": "transit", "open": "open"}

const DEFAULTS := {
	"seed": 1.0, "size_x": 220.0, "size_s": 240.0, "block": 44.0, "density": 0.9, "height": 0.5,
	"band_step": 6.5, "ceiling": 40.0, "clearance": 12.0, "pillar_bay": 90.0, "atrium": 0.0, "walls": 0.0, "jump_gap": 6.0,
	"radius": 300.0,
	"w_apartment": 1.0, "w_office": 1.0, "w_sage": 1.0, "w_shops": 0.8,
	# Downtown zone share of the blocks (docs/design/city-downtown.md). On its own: 0 = none. A section deck rolls its own
	# zone unless the overrides name this (0 = none there too).
	"downtown": 0.0,
	# City variety (docs/design/city-variety.md): the share of eligible blocks cut by a service alley, and (on its own) the
	# share of minor street segments that take a lane / pedestrian / superblock form. 0 and 0 = the plan before variety.
	"alleys": 0.33,
	"road_variety": 0.33,
}

var params: Dictionary = {}
var roads_x: Array = []
var roads_s: Array = []
var blocks: Array = []
var lots: Array = []
var buildings: Array = []
var columns: Array = []          ## slim non-building pillars (park tree-columns): [{x, s, half, kind}]
var site: CitySite               ## the structure this district was given (pillar points, ceiling openings)
var dropped_pillars := 0         ## site pillars that fell on a road and could not be built (should be 0)
var extent := Rect2()
var section: SectionPlan         ## the mission section this deck belongs to (null: a district on its own)
var deck := -1                   ## which of its decks
var ramps: Array = []
var alleys: Array = []           ## service alleys cut through blocks: [{block, rect, axis}] (city-variety.md; axis 0: runs along x)
var forms: Dictionary = {}       ## road segment key (RoadForms.seg_key) -> lane | pedestrian | none; absent = street (city-variety.md)
var raised: Array = []           ## ground raised to the sidewalk by a road form: [{rect, kind: court | band, seg}] (solid)

var _rng := RandomNumberGenerator.new()
## SiteFit's reachability mask of this plan (a SiteFit.FitMask: SiteFit.mask() builds it once and keeps it here, so it lives
## exactly as long as the plan). A cache derived from plan data; not in checksum().
var fit_mask: RefCounted = null


func net_fields() -> Dictionary:
	return {
		"params": Net.SPAWN,     # the mission seed and generator settings: all that crosses the wire
		"roads_x": Net.LOCAL, "roads_s": Net.LOCAL, "blocks": Net.LOCAL, "lots": Net.LOCAL, "buildings": Net.LOCAL,
		"columns": Net.LOCAL, "dropped_pillars": Net.LOCAL,
		"site": Net.SPAWN,       # the section's structure (pillars, openings): derived from the section seed
		"section": Net.SPAWN, "deck": Net.SPAWN,     # the section is planned from its own seed on every machine
		"ramps": Net.LOCAL,      # from the section's connectors, verified by checksum()
		"alleys": Net.LOCAL, "forms": Net.LOCAL, "raised": Net.LOCAL,     # from the seed (and the section), in checksum()
		"extent": Net.LOCAL,     # recomputed from params on every machine, verified by checksum()
		"_rng": Net.LOCAL,
		"fit_mask": Net.LOCAL,   # SiteFit.mask()'s cache, derived from the plan on every machine; not in checksum()
	}


## `given` is the structure from the section plan (CitySite.from_section); null plans a district on its own.
static func make(p: Dictionary = {}, given: CitySite = null) -> CityPlan:
	var plan := CityPlan.new()
	plan.generate(p, given)
	return plan


func p(id: String) -> float:
	return float(params[id])


func cosmetic_seed() -> int:
	return int(p("seed")) * 7919 + 104729


## The base of the street props' layout streams (CityPropLayout.layout: +1 street props, +2 roof units). GAMEPLAY, unlike the
## looks above: props are host-arbitrated by index and stop shots, so their layout joins the load checksum
## (CityStack.checksum). The same value as cosmetic_seed() (2026-11-25: named apart so that intent is visible; changing
## either alone would move every prop).
func props_seed() -> int:
	return int(p("seed")) * 7919 + 104729


func generate(overrides: Dictionary = {}, given: CitySite = null) -> void:
	params = DEFAULTS.duplicate()
	for k: String in overrides:
		if params.has(k):
			params[k] = float(overrides[k])
	_reset()
	section = null
	deck = -1
	site = given
	_rng.seed = int(p("seed")) * 2654435761 + 12345
	# Imposed pillars: no street may run through one, so each bars a band on both axes.
	var bar_x := []
	var bar_s := []
	if site != null:
		for q: Dictionary in site.pillars:
			var m := float(q["half"]) + SIDEWALK + 1.0
			bar_x.append([float(q["x"]) - m, float(q["x"]) + m])
			bar_s.append([float(q["s"]) - m, float(q["s"]) + m])
	var ax := _axis(p("size_x") * 0.5, AVENUE_W, "avenue", bar_x)
	var as_ := _axis(p("size_s") * 0.5, STREET_W, "street", bar_s)
	roads_x = ax["roads"]
	roads_s = as_["roads"]
	extent = Rect2(float(roads_x[0]["a"]), float(roads_s[0]["a"]),
			float(roads_x[-1]["b"]) - float(roads_x[0]["a"]), float(roads_s[-1]["b"]) - float(roads_s[0]["a"]))
	var bx: Array = ax["blocks"]
	var bs: Array = as_["blocks"]
	for i in bx.size():
		for j in bs.size():
			var r := Rect2(float(bx[i][0]), float(bs[j][0]), float(bx[i][1]) - float(bx[i][0]), float(bs[j][1]) - float(bs[j][0]))
			blocks.append({"rect": r, "ix": i, "is": j, "kind": "built"})
	var special := _pick_special(bx, bs)
	if site == null:
		site = CitySite.stub(self, special["civic"], special["park"])
	var by_block := _pillars_by_block()
	if int(special["civic"]) >= 0 and by_block.has(special["civic"]):
		special["civic"] = -1          # an imposed pillar stands in that block: no room for the hall
	var designs := {}
	if p("downtown") > 0.0:
		var allowed: Array[bool] = []
		var avenue: Array[bool] = []
		for bi in blocks.size():
			var r: Rect2 = blocks[bi]["rect"]
			allowed.append(bi != int(special["park"]) and bi != int(special["civic"]))
			avenue.append(absf(r.position.x - AVENUE_W * 0.5) < 0.01 or absf(r.end.x + AVENUE_W * 0.5) < 0.01)
		designs = _downtown_zone(p("downtown"), 1.0, allowed, avenue, by_block)
	var eligible: Array[bool] = []
	for bi in blocks.size():
		eligible.append(bi != int(special["park"]) and bi != int(special["civic"]) and not by_block.has(bi) and not designs.has(bi))
	var cuts := _plan_alleys(eligible)
	for bi in blocks.size():
		if designs.has(bi):
			_fill_downtown(bi, designs[bi])
		elif cuts.has(bi):
			_fill_alley(bi, cuts[bi], func() -> void: _fill_block(bi, special, []), false)
		else:
			_fill_block(bi, special, by_block.get(bi, []))
	_roll_forms(special)
	_finish()


## The layout cleared before a generate (both generate and generate_deck, ahead of seeding the rng).
func _reset() -> void:
	roads_x.clear()
	roads_s.clear()
	blocks.clear()
	lots.clear()
	buildings.clear()
	columns.clear()
	dropped_pillars = 0
	ramps.clear()
	alleys.clear()
	forms.clear()
	raised.clear()


## One whole deck of `sec`: its road grid, one block per cell filled by the cell's zone, its pillars, holes and walls.
static func for_deck(sec: SectionPlan, k: int, overrides: Dictionary = {}) -> CityPlan:
	var plan := CityPlan.new()
	plan.generate_deck(sec, k, overrides)
	return plan


## The section decides the shape of the deck (size, radius, ceiling, walls); `overrides` still tune what fills it
## (seed, density, height, styles). The seed defaults to the section's, mixed with the deck so decks differ.
func generate_deck(sec: SectionPlan, k: int, overrides: Dictionary = {}) -> void:
	params = DEFAULTS.duplicate()
	params["seed"] = sec.p("seed")
	for key: String in overrides:
		if params.has(key):
			params[key] = float(overrides[key])
	section = sec
	deck = clampi(k, 0, sec.deck_count - 1)
	params["size_x"] = sec.p("width")
	params["size_s"] = sec.arc_of(deck)
	params["radius"] = sec.radius_of(deck)
	params["ceiling"] = sec.clear_height()
	params["walls"] = 1.0
	_reset()
	_rng.seed = int(p("seed")) * 2654435761 + 12345 + (deck + 1) * 40503
	for i in sec.cols + 1:
		var hw := sec.line_width("s", i) * 0.5
		var kind := "spine" if i == sec.spine_line else ("perimeter" if i == 0 or i == sec.cols else "arterial")
		var road := {"a": sec.col_x[i] - hw, "b": sec.col_x[i] + hw, "kind": kind}
		if kind == "spine":
			var lanes := []
			for l: Array in SectionPlan.SPINE_LANES:
				var lx := sec.lane_x(str(l[0]))
				lanes.append({"lane": str(l[0]), "a": lx.x, "b": lx.y})
			road["lanes"] = lanes
		roads_x.append(road)
	for j in sec.rows + 1:
		var hw := sec.line_width("x", j) * 0.5
		var mid := sec.line_s(deck, j)
		roads_s.append({"a": mid - hw, "b": mid + hw, "kind": "perimeter" if j == 0 or j == sec.rows else "cross"})
	extent = Rect2(-sec.p("width") * 0.5, -sec.arc_of(deck) * 0.5, sec.p("width"), sec.arc_of(deck))
	for c in sec.cols:
		for r in sec.rows:
			var zone := sec.zone(deck, c, r)
			blocks.append({"rect": sec.cell_rect(deck, c, r), "ix": c, "is": r, "kind": ZONE_KIND.get(zone, "built"), "zone": zone})
	site = CitySite.for_deck(sec, deck)
	_make_ramps()
	var cut: Array[Rect2] = []
	for o in site.floor_holes:
		cut.append_array(_bridged(o))
	site.floor_holes = cut
	# Each pillar belongs to its own cell; one that does not fit inside that block's building line is dropped.
	var by_block := {}
	for q: Dictionary in site.pillars:
		var bi := int(q["col"]) * sec.rows + int(q["row"])
		var room: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK - float(q["half"]) - 0.4)
		if room.size.x < 0.0 or room.size.y < 0.0 or not room.grow(0.01).has_point(Vector2(q["x"], q["s"])):
			dropped_pillars += 1
			continue
		if not by_block.has(bi):
			by_block[bi] = []
		by_block[bi].append(q)
	# Downtown: by seed on about two decks in three, about a third of the blocks, grown from a block on the spine; the
	# overrides' `downtown` forces a share instead (0: none). Urban and industrial cells may join (industrial is urban
	# lots for now, city-section-mode.md); the section's zone of a cell is left as it is.
	var forced := overrides.has("downtown")
	var share := float(overrides["downtown"]) if forced else DT_SHARE
	var designs := {}
	if share > 0.0:
		var allowed: Array[bool] = []
		var avenue: Array[bool] = []
		for b: Dictionary in blocks:
			allowed.append(b["zone"] == "urban" or b["zone"] == "industrial")
			avenue.append(int(b["ix"]) == sec.spine_line or int(b["ix"]) + 1 == sec.spine_line)
		designs = _downtown_zone(share, 1.0 if forced else DT_DECK_CHANCE, allowed, avenue, by_block)
	# Pass 2: blocks with a pillar take alleys too (beside the core); nearly every urban section cell holds one.
	var eligible: Array[bool] = []
	for bi in blocks.size():
		var z := str(blocks[bi]["zone"])
		eligible.append((z == "urban" or z == "industrial") and not designs.has(bi))
	var cuts := _plan_alleys(eligible, by_block)
	for bi in blocks.size():
		if designs.has(bi):
			_fill_downtown(bi, designs[bi])
		elif cuts.has(bi):
			var pls: Array = by_block.get(bi, [])
			_fill_alley(bi, cuts[bi], func() -> void: _fill_zone(bi, pls), blocks[bi]["zone"] == "industrial", pls)
		else:
			_fill_zone(bi, by_block.get(bi, []))
	_section_forms()
	_finish()


func _finish() -> void:
	for i in buildings.size():
		_shape_building(i)
	_make_jumpable()
	for i in buildings.size():
		_build_tiers(i)


## A ramp's cut runs down a spine lane and so crosses the cross roads: they bridge it, so the floor is only cut
## between them. Except where a mech walking down the ramp would not fit under the bridge (BRIDGE_CLEAR): there the
## cut runs on under the cross road, which ends at the cut's curb and railing on both sides. With the section's ramp
## grades that is always exactly the first cross road past the ramp's head (about 7 m clear), never another.
func _bridged(o: Rect2) -> Array[Rect2]:
	var bridges: Array[Rect2] = []
	for road: Dictionary in roads_s:
		if not bridge_allowed(o, float(road["a"]), float(road["b"])):
			continue
		bridges.append(Rect2(o.position.x - 1.0, float(road["a"]), o.size.x + 2.0, float(road["b"]) - float(road["a"])))
	var out: Array[Rect2] = []
	for q in CityGeo.cut(o, bridges):
		if q.size.x >= 0.5 and q.size.y >= 0.5:
			out.append(q)
	return out


## Every ramp of the section that touches this deck, in this deck's arc coordinates. A ramp falls linearly by angle from
## its top cross line (one pitch above the lower floor) to its foot cross line (on it). The top part ends 1 m under the
## slab, below the ceiling of the deck beneath; the bottom part starts at that ceiling: they share 1 m of height.
func _make_ramps() -> void:
	var pitch := section.p("pitch")
	var clear := section.clear_height()
	var r := section.radius_of(deck)
	for ci in section.connectors.size():
		var cn: Dictionary = section.connectors[ci]
		if cn["kind"] != "ramp" or (int(cn["from"]) != deck and int(cn["to"]) != deck):
			continue
		var th0 := section.line_s(int(cn["from"]), int(cn["top_line"])) / section.radius_of(int(cn["from"]))
		var th1 := section.line_s(int(cn["to"]), int(cn["foot_line"])) / section.radius_of(int(cn["to"]))
		var top := int(cn["from"]) == deck
		# t runs 0..1 from the top line to the foot line; the height above the lower floor is pitch * (1 - t).
		var t0 := 0.0 if top else 1.0 - clear / pitch
		var t1 := (section.p("slab") + 1.0) / pitch if top else 1.0
		var lower := pitch if top else 0.0     # how far the lower floor is below this deck's
		ramps.append({"connector": ci, "role": "top" if top else "bottom", "x0": float(cn["x0"]), "x1": float(cn["x1"]),
				"s_top": lerpf(th0, th1, t0) * r, "s_foot": lerpf(th0, th1, t1) * r,
				"h_top": pitch * (1.0 - t0) - lower, "h_foot": pitch * (1.0 - t1) - lower})


## Height of ramp part `r` above this deck's floor at s (linear, so it carries on past the part's ends).
static func ramp_height(r: Dictionary, s: float) -> float:
	return lerpf(float(r["h_top"]), float(r["h_foot"]), (s - float(r["s_top"])) / (float(r["s_foot"]) - float(r["s_top"])))


## Where ramp part `r` is at height h.
static func ramp_s(r: Dictionary, h: float) -> float:
	return lerpf(float(r["s_top"]), float(r["s_foot"]), (h - float(r["h_top"])) / (float(r["h_foot"]) - float(r["h_top"])))


## Clear height under a bridge over a ramp's cut, on the ramp's centre line, at s (the bridge's edge nearer the ramp's
## head, where the ramp is highest under it): from the ramp's surface up to the bridge's underside, the slab's bottom
## (`slab` m under the road; the cut's faces and the soffit are drawn that deep). `r` is the ramp's top part.
static func bridge_clearance(r: Dictionary, s: float, slab: float) -> float:
	return -slab - ramp_height(r, s)


## Whether the cross road a..b may bridge floor hole `o` (always, unless `o` is a ramp's cut and a mech walking down the
## ramp would not fit under the road: bridge_clearance < BRIDGE_CLEAR). The cross road at the ramp's head is its
## mouth (floor_cuts), not a bridge.
func bridge_allowed(o: Rect2, a: float, b: float) -> bool:
	if b <= o.position.y or a >= o.end.y:
		return true
	for r: Dictionary in ramps:
		if r["role"] != "top" or absf(o.position.x - float(r["x0"])) > 0.01 or absf(o.end.x - float(r["x1"])) > 0.01:
			continue
		var top := float(r["s_top"])
		var down := signf(float(r["s_foot"]) - top)
		if a <= top and top <= b:
			continue
		var near := a if down > 0.0 else b
		if (near - top) * down < 0.0:
			continue
		if bridge_clearance(r, near, site.slab) < BRIDGE_CLEAR:
			return false
	return true


## The floor as it is actually cut: the floor holes, with the piece at each ramp's top reaching on across half its cross
## road to the cross line, where the ramp starts flush with the road (that half of the road no longer bridges the cut).
func floor_cuts() -> Array[Rect2]:
	var out: Array[Rect2] = site.floor_holes.duplicate()
	for r: Dictionary in ramps:
		if r["role"] != "top":
			continue
		var line := float(r["s_top"])
		for i in out.size():
			var o := out[i]
			if absf(o.position.x - float(r["x0"])) > 0.01 or absf(o.end.x - float(r["x1"])) > 0.01:
				continue
			if line > o.end.y and line - o.end.y < SectionPlan.ARTERIAL_W:
				out[i] = Rect2(o.position.x, o.position.y, o.size.x, line - o.position.y)
			elif line < o.position.y and o.position.y - line < SectionPlan.ARTERIAL_W:
				out[i] = Rect2(o.position.x, line, o.size.x, o.end.y - line)
	return out


## The side of floor cut `o` that is a ramp's open top (no curb or railing across it): 2 (+s), 3 (-s), or -1.
func ramp_mouth(o: Rect2) -> int:
	for r: Dictionary in ramps:
		if r["role"] != "top" or absf(o.position.x - float(r["x0"])) > 0.01 or absf(o.end.x - float(r["x1"])) > 0.01:
			continue
		if absf(o.end.y - float(r["s_top"])) < 0.01:
			return 2
		if absf(o.position.y - float(r["s_top"])) < 0.01:
			return 3
	return -1


## The x range of the avenue's carriageway: the central avenue on its own, the spine's avenue lane in a section.
func avenue_x() -> Vector2:
	if section != null:
		return section.lane_x("avenue")
	return Vector2(-AVENUE_W * 0.5, AVENUE_W * 0.5)


## False where nothing may stand: in a floor hole (or on its curb) or on ground kept clear.
func clear_at(pt: Vector2) -> bool:
	for o in site.floor_holes:
		if o.grow(CityDims.HOLE_CURB + 0.1).has_point(pt):
			return false
	for k in site.keep_clear:
		if k.has_point(pt):
			return false
	return true


# --- Streets ---------------------------------------------------------------------------------------------

## One axis of the grid: a centre road, then blocks and streets outward on both sides, ending with a perimeter street.
func _axis(half: float, centre_w: float, centre_kind: String, barred: Array) -> Dictionary:
	# With a downtown zone the blocks are at least section-cell sized: a zone block holds two towers each way.
	var block := p("block") if p("downtown") <= 0.0 else maxf(p("block"), DT_BLOCK)
	var out_blocks := []
	var out_roads := [{"a": -centre_w * 0.5, "b": centre_w * 0.5, "kind": centre_kind}]
	for side: float in [1.0, -1.0]:
		var a := centre_w * 0.5
		while true:
			var b := a + block * _rng.randf_range(0.82, 1.22)
			var last := b + STREET_W + block * 0.62 > half
			if last:
				b = maxf(a + block * 0.62, half - STREET_W)
			b = snappedf(b, 0.5)
			# Slide the street off any barred band (a pillar): to whichever side is nearer and still leaves a block.
			for attempt in 8:
				var hit := false
				for f: Array in barred:
					var lo: float = f[0] if side > 0.0 else -float(f[1])
					var hi: float = f[1] if side > 0.0 else -float(f[0])
					if b < hi and b + STREET_W > lo:
						var before := lo - STREET_W
						if before - a >= 20.0 and b - before < hi - b:
							b = snappedf(before, 0.5) - 0.5
						else:
							b = snappedf(hi, 0.5) + 0.5
						hit = true
				if not hit:
					break
			if side > 0.0:
				out_blocks.append([a, b])
				out_roads.append({"a": b, "b": b + STREET_W, "kind": "street"})
			else:
				out_blocks.append([-b, -a])
				out_roads.append({"a": -b - STREET_W, "b": -b, "kind": "street"})
			if last:
				break
			a = b + STREET_W
	out_blocks.sort_custom(func(m: Array, n: Array) -> bool: return m[0] < n[0])
	out_roads.sort_custom(func(m: Dictionary, n: Dictionary) -> bool: return m["a"] < n["a"])
	return {"blocks": out_blocks, "roads": out_roads}


## The park block and the civic block: two blocks facing each other across the avenue.
func _pick_special(bx: Array, bs: Array) -> Dictionary:
	var right := -1     # first block column on the +x side of the avenue
	for i in bx.size():
		if float(bx[i][0]) > 0.0:
			right = i
			break
	var row := _rng.randi_range(0, bs.size() - 1)
	var flip := _rng.randf() < 0.5
	var park_col := right if flip else right - 1
	var civic_col := right - 1 if flip else right
	var out := {"park": -1, "civic": -1}
	for bi in blocks.size():
		var b: Dictionary = blocks[bi]
		if b["is"] == row and b["ix"] == park_col:
			out["park"] = bi
		if b["is"] == row and b["ix"] == civic_col:
			out["civic"] = bi
	return out


# --- Blocks and lots -------------------------------------------------------------------------------------

func _fill_block(bi: int, special: Dictionary, pillars_here: Array) -> void:
	var b: Dictionary = blocks[bi]
	var zone: Rect2 = (b["rect"] as Rect2).grow(-SIDEWALK)
	if bi == special["park"]:
		b["kind"] = "park"
		_add_lot(zone, bi, zone, "park")
		for q: Dictionary in pillars_here:       # in a park a pillar is a slim tree-column, not a tower
			_add_column(q)
		return
	var rects: Array[Rect2] = []
	if bi == special["civic"]:
		# The civic hall takes the avenue side of its block; a plaza strip either side; the rest is ordinary lots.
		var toward := -1.0 if zone.position.x > 0.0 else 1.0     # direction of the avenue
		var depth := minf(zone.size.x * 0.6, 28.0)
		var width := minf(zone.size.y, 34.0)
		var x0 := zone.position.x if toward < 0.0 else zone.end.x - depth
		var s0 := zone.position.y + (zone.size.y - width) * 0.5
		var hall := Rect2(x0, s0, depth, width)
		var li := _add_lot(hall, bi, zone, "")
		_add_building(li, "civic")
		if s0 - zone.position.y >= 3.0:
			_add_lot(Rect2(x0, zone.position.y, depth, s0 - zone.position.y), bi, zone, "plaza")
			_add_lot(Rect2(x0, hall.end.y, depth, zone.end.y - hall.end.y), bi, zone, "plaza")
		var rest := Rect2(zone.position.x + depth + 4.0, zone.position.y, zone.size.x - depth - 4.0, zone.size.y) if toward < 0.0 \
				else Rect2(zone.position.x, zone.position.y, zone.size.x - depth - 4.0, zone.size.y)
		if rest.size.x >= LOT_MIN:
			_split(rest, rects)
	else:
		_carve(zone, pillars_here, bi, zone, rects)
	_fill_lots(bi, zone, rects, false)


## A section block, filled by its zone. Industrial and transit are placeholders for their own generators: industrial is
## urban lots without shops and with twice the offices and panel blocks; transit is open paving round its pillar
## (a lift or transit core). An open cell is one plaza around the shaft cut in it (it has no pillar).
func _fill_zone(bi: int, pillars_here: Array) -> void:
	var b: Dictionary = blocks[bi]
	var zone: Rect2 = (b["rect"] as Rect2).grow(-SIDEWALK)
	var rects: Array[Rect2] = []
	match str(b["zone"]):
		"park":
			_add_lot(zone, bi, zone, "park")
			for q: Dictionary in pillars_here:
				_add_column(q)
		"transit", "open":
			_carve(zone, pillars_here, bi, zone, rects, false)
			for r in rects:
				_add_lot(r, bi, zone, "plaza")
		_:
			_carve(zone, pillars_here, bi, zone, rects)
			_fill_lots(bi, zone, rects, b["zone"] == "industrial")


## Turns the lots cut from a block into buildings or open space (a lot touching ground kept clear is a plaza).
func _fill_lots(bi: int, zone: Rect2, rects: Array[Rect2], industrial: bool) -> void:
	for r in rects:
		var barred := false
		for k: Rect2 in site.keep_clear:
			if k.intersects(r):
				barred = true
		if barred:
			_add_lot(r, bi, zone, "plaza")
		elif _rng.randf() >= p("density"):
			_add_lot(r, bi, zone, ["garden", "plaza", "court"][_rng.randi_range(0, 2)])
		else:
			var li := _add_lot(r, bi, zone, "")
			_add_building(li, _pick_style(lots[li], industrial))


## Which block each site pillar stands in: {block index: [pillar]}. A pillar that is not clear inside a block is dropped.
func _pillars_by_block() -> Dictionary:
	var out := {}
	for q: Dictionary in site.pillars:
		var found := -1
		for bi in blocks.size():
			var room: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK - float(q["half"]) - 0.4)
			if room.size.x >= 0.0 and room.size.y >= 0.0 and room.grow(0.01).has_point(Vector2(q["x"], q["s"])):
				found = bi
		if found < 0:
			dropped_pillars += 1
			continue
		if not out.has(found):
			out[found] = []
		out[found].append(q)
	return out


## Lots for a rectangle that may hold pillars: each pillar gets its own lot centred on it (the tower wraps the core),
## and what is left around it is cut into ordinary lots (`split` false: left whole, for open paving).
func _carve(r: Rect2, pillars_here: Array, bi: int, zone: Rect2, out: Array[Rect2], split: bool = true) -> void:
	var inside := []
	for q: Dictionary in pillars_here:
		if r.grow(0.01).has_point(Vector2(q["x"], q["s"])):
			inside.append(q)
	if inside.is_empty():
		if not split:
			if minf(r.size.x, r.size.y) >= 4.0:
				out.append(r)
		elif minf(r.size.x, r.size.y) >= LOT_MIN:
			_split(r, out)
		elif minf(r.size.x, r.size.y) >= 4.0:
			_add_lot(r, bi, zone, "plaza")
		return
	var q: Dictionary = inside[0]
	var half := float(q["half"]) + PILLAR_APRON
	var x0 := maxf(float(q["x"]) - half, r.position.x)
	var x1 := minf(float(q["x"]) + half, r.end.x)
	var s0 := maxf(float(q["s"]) - half, r.position.y)
	var s1 := minf(float(q["s"]) + half, r.end.y)
	var alley := 3.0
	# No slivers: if what would be left beside the lot cannot hold a building, the lot takes it.
	if x0 - r.position.x < LOT_MIN + alley:
		x0 = r.position.x
	if r.end.x - x1 < LOT_MIN + alley:
		x1 = r.end.x
	if s0 - r.position.y < LOT_MIN + alley:
		s0 = r.position.y
	if r.end.y - s1 < LOT_MIN + alley:
		s1 = r.end.y
	var li := _add_lot(Rect2(x0, s0, x1 - x0, s1 - s0), bi, zone, "")
	_add_pillar(li, q)
	var rest := []
	for o: Dictionary in pillars_here:
		if o != q:
			rest.append(o)
	if x0 > r.position.x:
		_carve(Rect2(r.position.x, r.position.y, x0 - alley - r.position.x, r.size.y), rest, bi, zone, out, split)
	if x1 < r.end.x:
		_carve(Rect2(x1 + alley, r.position.y, r.end.x - x1 - alley, r.size.y), rest, bi, zone, out, split)
	if s0 > r.position.y:
		_carve(Rect2(x0, r.position.y, x1 - x0, s0 - alley - r.position.y), rest, bi, zone, out, split)
	if s1 < r.end.y:
		_carve(Rect2(x0, s1 + alley, x1 - x0, r.end.y - s1 - alley), rest, bi, zone, out, split)


## The pillar tower on lot li, wrapping structural pillar q.
func _add_pillar(li: int, q: Dictionary) -> void:
	_add_building(li, "pillar")
	var b: Dictionary = buildings[buildings.size() - 1]
	b["pillar"] = true
	b["band"] = 1
	b["setback"] = 0.5
	b["core"] = {"x": q["x"], "s": q["s"], "half": float(q["half"]), "kind": q["kind"], "size": Vector2.ZERO}


## Cut a rectangle into lots: split the long side until every piece is at most LOT_MAX, sometimes leaving an alley.
func _split(r: Rect2, out: Array[Rect2]) -> void:
	var along_x := r.size.x >= r.size.y
	var length := r.size.x if along_x else r.size.y
	if length <= LOT_MAX:
		out.append(r)
		return
	var gap: float = [0.0, 0.0, 3.0, 4.5, 6.0][_rng.randi_range(0, 4)]
	if length - gap < LOT_MIN * 2.0:
		gap = 0.0
	var t := _rng.randf_range(0.38, 0.62)
	var cut := snappedf(clampf((length - gap) * t, LOT_MIN, length - gap - LOT_MIN), 0.5)
	if along_x:
		_split(Rect2(r.position.x, r.position.y, cut, r.size.y), out)
		_split(Rect2(r.position.x + cut + gap, r.position.y, length - cut - gap, r.size.y), out)
	else:
		_split(Rect2(r.position.x, r.position.y, r.size.x, cut), out)
		_split(Rect2(r.position.x, r.position.y + cut + gap, r.size.x, length - cut - gap), out)


func _add_lot(r: Rect2, bi: int, zone: Rect2, open: String) -> int:
	# Which sides sit on the block's building line, i.e. face a street.
	var faces: Array[bool] = [
		absf(r.end.x - zone.end.x) < 0.01, absf(r.position.x - zone.position.x) < 0.01,
		absf(r.end.y - zone.end.y) < 0.01, absf(r.position.y - zone.position.y) < 0.01]
	# The front is the street side nearest the avenue, else any street side, else +x.
	var front := -1
	var av := avenue_x()
	var cx := r.get_center().x
	var pref: Array = [1, 0, 2, 3] if cx > (av.x + av.y) * 0.5 else [0, 1, 2, 3]
	for side: int in pref:
		if faces[side]:
			front = side
			break
	lots.append({"rect": r, "block": bi, "kind": "open" if open != "" else "building", "open": open, "building": -1,
			"faces": faces, "front": front})
	return lots.size() - 1


func _pick_style(lot: Dictionary, industrial: bool = false) -> String:
	var names: Array[String] = ["apartment", "office", "sage", "shops"]
	var w: Array[float] = [p("w_apartment"), p("w_office"), p("w_sage"), p("w_shops")]
	if industrial:
		w = [w[0], w[1] * 2.0, w[2] * 2.0, 0.0]
	if int(lot["front"]) < 0:
		w[3] = 0.0            # a shop needs a street
	var r: Rect2 = lot["rect"]
	if minf(r.size.x, r.size.y) < 14.0:
		w[1] *= 0.3           # offices want a big floor plate
	var total := w[0] + w[1] + w[2] + w[3]
	if total <= 0.0001:
		return "apartment"
	var roll := _rng.randf() * total
	for i in 4:
		roll -= w[i]
		if roll <= 0.0:
			return names[i]
	return names[0]


func _add_building(li: int, style: String) -> void:
	var lot: Dictionary = lots[li]
	var range_: Array = BANDS[style]
	var t := clampf(_rng.randf() + (p("height") - 0.5) * 1.2, 0.0, 0.999)
	var band := int(range_[0]) + int(t * float(int(range_[1]) - int(range_[0]) + 1))
	lot["building"] = buildings.size()
	buildings.append({"lot": li, "style": style, "band": band, "pillar": false, "front": maxi(int(lot["front"]), 0),
			"setback": snappedf(_rng.randf_range(0.5, 1.5), 0.25), "variant": _rng.randi_range(0, 999),
			"floors": 0, "roof_h": 0.0, "center": Vector2.ZERO, "size": Vector2.ZERO, "tiers": []})


# --- Heights and footprints ------------------------------------------------------------------------------

## The highest a standable roof may be: an 8 m mech must fit under the ceiling beams with room to hop.
func stand_limit() -> float:
	return p("ceiling") - p("clearance")


func band_floors(band: int) -> int:
	var cap := int(floor(stand_limit() / FLOOR_H))
	return clampi(int(round((7.0 + float(band) * p("band_step")) / FLOOR_H)), 2, maxi(cap, 2))


## Footprint from the lot: a small setback, then narrowed along s so a straight-walled box standing radially on the
## curved deck stays inside its lot all the way up (walls lean together toward the axis).
func _shape_building(i: int) -> void:
	var b: Dictionary = buildings[i]
	if b["style"] == "tower":
		_shape_tower(b)
		return
	var lot: Dictionary = lots[b["lot"]]
	var r: Rect2 = lot["rect"]
	var style: String = b["style"]
	var set_ := float(b["setback"])
	var faces: Array = lot["faces"]
	var x0 := r.position.x + (0.0 if faces[1] and style == "shops" else set_ * (1.0 if faces[1] else 0.5))
	var x1 := r.end.x - (0.0 if faces[0] and style == "shops" else set_ * (1.0 if faces[0] else 0.5))
	var s0 := r.position.y + (0.0 if faces[3] and style == "shops" else set_ * (1.0 if faces[3] else 0.5))
	var s1 := r.end.y - (0.0 if faces[2] and style == "shops" else set_ * (1.0 if faces[2] else 0.5))
	if style == "civic":      # forecourt in front of the steps
		match int(b["front"]):
			0: x1 -= 5.0
			1: x0 += 5.0
			2: s1 -= 5.0
			3: s0 += 5.0
	b["floors"] = band_floors(int(b["band"]))
	b["roof_h"] = float(b["floors"]) * FLOOR_H
	if style == "civic":
		b["roof_h"] = minf(12.0, stand_limit())
	var top := float(b["roof_h"]) + 3.0
	var lean := (p("radius") - top) / p("radius")
	var size := Vector2(x1 - x0, (s1 - s0) * lean)
	b["center"] = Vector2((x0 + x1) * 0.5, (s0 + s1) * 0.5)
	b["size"] = Vector2(snappedf(size.x, 0.01), snappedf(size.y, 0.01))
	if b["pillar"]:
		# The core stands on its own radial line (the same one on every deck), so it gets its own lean.
		var core: Dictionary = b["core"]
		var h := float(core["half"])
		core["size"] = Vector2(h * 2.0, snappedf(h * 2.0 * (p("radius") - p("ceiling") - 1.0) / p("radius"), 0.01))


## Roofs within one hop of each other: same block, facing each other across at most `jump_gap`.
func roof_neighbours() -> Array:
	var out := []
	for i in buildings.size():
		out.append([])
	var gap := p("jump_gap")
	for i in buildings.size():
		var ri: Rect2 = lots[buildings[i]["lot"]]["rect"]
		for j in range(i + 1, buildings.size()):
			if lots[buildings[i]["lot"]]["block"] != lots[buildings[j]["lot"]]["block"]:
				continue
			var rj: Rect2 = lots[buildings[j]["lot"]]["rect"]
			var dx := maxf(maxf(rj.position.x - ri.end.x, ri.position.x - rj.end.x), 0.0)
			var ds := maxf(maxf(rj.position.y - ri.end.y, ri.position.y - rj.end.y), 0.0)
			var over_x := minf(ri.end.x, rj.end.x) - maxf(ri.position.x, rj.position.x)
			var over_s := minf(ri.end.y, rj.end.y) - maxf(ri.position.y, rj.position.y)
			if (dx <= gap + 0.01 and over_s >= 3.0) or (ds <= gap + 0.01 and over_x >= 3.0):
				out[i].append(j)
				out[j].append(i)
	return out


## Which roofs a mech can reach: bands 0 and 1 from the street, then one band up per hop to a neighbour (any drop).
func reachable_roofs() -> Array[bool]:
	var nb := roof_neighbours()
	var ok: Array[bool] = []
	var queue: Array[int] = []
	for i in buildings.size():
		var start: bool = not buildings[i]["pillar"] and int(buildings[i]["band"]) <= 1
		ok.append(start)
		if start:
			queue.append(i)
	while not queue.is_empty():
		var i: int = queue.pop_back()
		for j: int in nb[i]:
			if not ok[j] and not buildings[j]["pillar"] and int(buildings[j]["band"]) <= int(buildings[i]["band"]) + 1:
				ok[j] = true
				queue.append(j)
	return ok


## Rooftop hopping is core play: lower any roof that can't be reached until every roof can.
func _make_jumpable() -> void:
	for pass_ in 8:
		var ok := reachable_roofs()
		var nb := roof_neighbours()
		var changed := false
		for i in buildings.size():
			if ok[i] or buildings[i]["pillar"]:
				continue
			var best := 0
			for j: int in nb[i]:
				if ok[j]:
					best = maxi(best, int(buildings[j]["band"]) + 1)
			buildings[i]["band"] = best if best > 0 else maxi(int(buildings[i]["band"]) - 1, 1)
			changed = true
		if not changed:
			break
		for i in buildings.size():
			_shape_building(i)


# --- Massing ---------------------------------------------------------------------------------------------

func _build_tiers(i: int) -> void:
	var b: Dictionary = buildings[i]
	var size: Vector2 = b["size"]
	var roof: float = b["roof_h"]
	var floors: int = b["floors"]
	var v: int = b["variant"]
	var tiers := []
	var solids := []
	b.erase("gable")
	match str(b["style"]):
		"apartment":
			tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
			var bulk := Vector2(minf(4.0, size.x * 0.4), minf(3.4, size.y * 0.4))
			var off := Vector2((size.x * 0.5 - bulk.x * 0.5 - 1.5) * (1.0 if v % 2 == 0 else -1.0),
					(size.y * 0.5 - bulk.y * 0.5 - 1.5) * (1.0 if (v / 2) % 2 == 0 else -1.0))
			tiers.append(_tier(off, bulk, roof, roof + 2.8, true))
		"office":
			if floors >= 6 and v % 5 < 3 and minf(size.x, size.y) >= 14.0:
				var base := float(floors - 2) * FLOOR_H
				tiers.append(_tier(Vector2.ZERO, size, 0.0, base, true))
				tiers.append(_tier(Vector2.ZERO, size - Vector2(5.0, 5.0), base, roof, true))
			else:
				tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
			# The roof plant room / stairwell bulkhead on a big top roof: solid and standable, like an apartment's stair
			# bulkhead.
			var top: Dictionary = tiers[tiers.size() - 1]
			var ts: Vector2 = top["size"]
			if minf(ts.x, ts.y) >= 9.0:
				tiers.append(_tier(top["off"], Vector2(ts.x * 0.4, ts.y * 0.35), float(top["y1"]), float(top["y1"]) + 2.4, true, "plant"))
		"sage":
			if floors >= 4 and v % 2 == 0 and minf(size.x, size.y) >= 13.0:
				var base := float(floors - 1) * FLOOR_H
				tiers.append(_tier(Vector2.ZERO, size, 0.0, base, true))
				tiers.append(_tier(Vector2.ZERO, size - Vector2(6.0, 6.0), base, roof, true))
			else:
				tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
		"shops":
			tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
		"civic":
			var front := int(b["front"])
			var n: Vector2 = SIDE_N[front]
			var across := Vector2(n.y, -n.x)
			var porch := 5.0
			tiers.append(_tier(Vector2.ZERO, size, 0.0, 1.2, true))
			var hall := size - Vector2(absf(n.x) * porch + 3.0, absf(n.y) * porch + 3.0)
			# The hall's flat top and the entablature's are both under the gable: what you stand on is the gable.
			tiers.append(_tier(-n * porch * 0.5, hall, 1.2, roof, false))
			var w := size.y if front < 2 else size.x      # across the front
			var d := size.x if front < 2 else size.y      # front to back
			tiers.append(_tier(n * 0.5, _oriented(n, d - 1.4, w - 1.0), roof - 1.2, roof, false, "entablature"))
			b["gable"] = {"off": n * 0.5, "w": w - 0.6, "d": d - 0.8, "y0": roof, "rise": 2.8, "front": front}
			var count := maxi(int(w / 3.8), 4)
			for k in count:
				var x := lerpf(-w * 0.5 + 1.6, w * 0.5 - 1.6, float(k) / float(count - 1))
				solids.append(_solid("column", across * x + n * (d * 0.5 - 1.1), Vector2(1.2, 1.2), 1.2, roof - 1.2))
			for k in 4:      # steps down from the plinth on the front, 0.3 m each
				var depth := 0.55 * float(k + 1)
				solids.append(_solid("step", n * (d * 0.5 + depth * 0.5), _oriented(n, depth, w * 0.64), -0.5, 1.2 - 0.3 * float(k)))
		"pillar":
			# A lift pillar stands bare in its plaza (the doors need the room); so does a downtown pillar on a plaza base.
			if b["core"]["kind"] != "lift" and b.get("base", "") != "plaza":
				tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
		"tower":
			_tower_tiers(b, tiers, solids)
	for t: Dictionary in tiers:
		if float(t["y1"]) > stand_limit() + 0.01:
			t["stand"] = false
	b["tiers"] = tiers
	b["solids"] = solids
	_skylights(i)


func _tier(off: Vector2, size: Vector2, y0: float, y1: float, stand: bool, kind: String = "") -> Dictionary:
	var t := {"off": off, "size": Vector2(maxf(size.x, 2.0), maxf(size.y, 2.0)), "y0": y0, "y1": y1, "stand": stand}
	if kind != "":
		t["kind"] = kind
	return t


func _solid(kind: String, off: Vector2, size: Vector2, y0: float, y1: float) -> Dictionary:
	return {"kind": kind, "off": off, "size": size, "y0": y0, "y1": y1}


## A size `along` the side normal n and `across` it, as (x, s).
static func _oriented(n: Vector2, along: float, across: float) -> Vector2:
	return Vector2(along, across) if absf(n.x) > 0.5 else Vector2(across, along)


func _add_column(q: Dictionary) -> void:
	var half := minf(float(q["half"]), 2.0)
	columns.append({"x": q["x"], "s": q["s"], "half": half, "kind": "park", "ring_r": half + 1.6, "ring_h": 0.7})


# --- Roofs: what stands on them (docs/design/city-rooftops.md) -------------------------------------------

const SKYLIGHT := Vector2(2.4, 3.4)     ## skylight footprint (m), before its quarter turn
const SKYLIGHT_H := 0.4                 ## its solid concrete curb; the glass ridge on it (0.7 m more) is drawn only
const ROOF_INSET := 2.6                 ## roof units stand at least this far in from the tier's edge (their centre)
const ROOF_MARGIN := 0.6                ## and this far clear of anything standing on the same roof

## Which tiers of building i carry roof units and which kinds: [[tier index, kinds]]. Skylights are solid plan
## geometry (_skylights); the other kinds (tank, ac, vent, planter) are knockable CityProps (CityPropLayout.layout).
func roof_slots(i: int) -> Array:
	var b: Dictionary = buildings[i]
	var tiers: Array = b["tiers"]
	match str(b["style"]):
		"apartment":
			return [[0, ["tank", "tank", "ac", "vent"]]]
		"office":
			var top := tiers.size() - 1
			if str(tiers[top].get("kind", "")) == "plant":
				top -= 1
			return [[top, ["ac", "ac", "vent"]]]
		"sage":
			if tiers.size() == 1:
				return [[0, ["planter", "planter", "skylight"]]]
			return [[0, ["planter"]], [1, ["ac", "vent"]]]
		"shops":
			return [[0, ["ac", "skylight", "vent"]]]
		"pillar":
			if not tiers.is_empty():
				return [[0, ["planter", "ac"]]]
		"tower":
			# The base's roofs (podium, terrace, arcade), never a shaft: low units only, so a mech's eye (8 m) still sees
			# over a 6.5 m roof. The shafts standing on a roof are its blockers (roof_blockers).
			var out := []
			for t in tiers.size():
				var tk := str(tiers[t].get("kind", ""))
				var ts: Vector2 = tiers[t]["size"]
				if tiers[t]["stand"] and tk != "lobby" and tk != "tower" and minf(ts.x, ts.y) >= ROOF_INSET * 2.0 + 1.0:
					out.append([t, ["planter", "ac", "vent"]])
			return out
	return []


## Tier t of building i as a rectangle in the building's flat frame (x, z).
func roof_rect(i: int, t: int) -> Rect2:
	var tier: Dictionary = buildings[i]["tiers"][t]
	var size: Vector2 = tier["size"]
	return Rect2((tier["off"] as Vector2) - size * 0.5, size)


## What stands on tier t of building i, as rectangles in the building's frame: the tiers standing on it (stair
## bulkhead, plant room, penthouse), the pillar core rising through it (1 m wider: its own radial frame) and its skylights.
func roof_blockers(i: int, t: int) -> Array[Rect2]:
	var b: Dictionary = buildings[i]
	var tiers: Array = b["tiers"]
	var y := float(tiers[t]["y1"])
	var area := roof_rect(i, t)
	var out: Array[Rect2] = []
	for u in tiers.size():
		if u != t and absf(float(tiers[u]["y0"]) - y) < 0.01 and roof_rect(i, u).intersects(area):
			out.append(roof_rect(i, u))
	if b["pillar"]:
		var cs: Vector2 = b["core"]["size"]
		var half := maxf(cs.x, cs.y) * 0.5 + 0.5
		var at := Vector2(b["core"]["x"], b["core"]["s"]) - (b["center"] as Vector2)
		out.append(Rect2(at - Vector2(half, half), Vector2(half, half) * 2.0))
	for so: Dictionary in b.get("solids", []):
		if so["kind"] == "skylight" and absf(float(so["y0"]) - y) < 0.01:
			var sz: Vector2 = so["size"]
			out.append(Rect2((so["off"] as Vector2) - sz * 0.5, sz))
	return out


## Skylights on the roofs whose slots list them: one roll per unit slot as the old clutter did, placed clear of the
## roof's edge, of what stands on it and of each other.
func _skylights(i: int) -> void:
	var solids: Array = buildings[i]["solids"]
	for slot: Array in roof_slots(i):
		var kinds: Array = slot[1]
		if not kinds.has("skylight"):
			continue
		var t: int = slot[0]
		var tier: Dictionary = buildings[i]["tiers"][t]
		var size: Vector2 = tier["size"]
		var off: Vector2 = tier["off"]
		var y := float(tier["y1"])
		var n := clampi(int(size.x * size.y / 70.0), 1, 5)
		var inner := roof_rect(i, t).grow(-0.8)
		for k in n:
			if kinds[_rng.randi_range(0, kinds.size() - 1)] != "skylight":
				continue
			var sz := SKYLIGHT if _rng.randf() < 0.5 else Vector2(SKYLIGHT.y, SKYLIGHT.x)
			var blockers := roof_blockers(i, t)
			for attempt in 6:
				var pos := off + Vector2(_rng.randf_range(-1.0, 1.0) * maxf(size.x * 0.5 - ROOF_INSET, 0.0),
						_rng.randf_range(-1.0, 1.0) * maxf(size.y * 0.5 - ROOF_INSET, 0.0))
				var r := Rect2(pos - sz * 0.5, sz)
				var ok := inner.encloses(r)
				for q in blockers:
					if q.grow(ROOF_MARGIN).intersects(r):
						ok = false
				if ok:
					solids.append(_solid("skylight", pos, sz, y, y + SKYLIGHT_H))
					break


## The edge of the map: one entry per side, [{side, kind: bulkhead | window | farm, at, backdrop, gates: [{a, b, h, kind:
## blast_door | portal | collapsed}]}], gate a..b along the wall (x on an arc-end wall, s on a side wall). In a section
## they are the section's walls (always on); on its own the district is open unless `walls` asks for them, and then the
## two ends across the arc are bulkheads with a sealed gate wherever a road reaches them and the two sides are the
## habitat's hull, a window wall with no backdrop behind it.
## kind "farm": the section's window walls that would look out at a backdrop are drawn as a vertical farm instead (user
## decision, docs/design/city-styles.md "Side walls: vertical farm"): a solid wall, so no backdrop. Looks only: the wall's
## collision, its gates and the checksum (which never reads boundary()) are the same as a window wall's.
func boundary() -> Array:
	var out := []
	if section == null and p("walls") < 0.5:
		return out
	var at: Array[float] = [extent.end.x, extent.position.x, extent.end.y, extent.position.y]
	for side in 4:
		var gates := []
		var kind := "bulkhead" if side >= 2 else "window"
		var backdrop := false
		if section != null:
			var w: Dictionary = section.boundary(deck, SIDE_EDGE[side])
			kind = str(w["kind"])
			backdrop = bool(w["backdrop"])
			if kind == "window" and backdrop:
				kind = "farm"
				backdrop = false
			for g: Dictionary in w["gates"]:
				var mid := float(g["x"]) if side >= 2 else float(g["s"])
				var half := float(g["width"]) * 0.5
				var spine: bool = g["axis"] == "s" and int(g["line"]) == section.spine_line
				gates.append({"a": mid - half, "b": mid + half, "h": 14.0 if spine else 9.0, "kind": str(g["kind"])})
		elif side >= 2:
			for road: Dictionary in roads_x:
				gates.append({"a": float(road["a"]), "b": float(road["b"]), "h": 14.0 if road["kind"] == "avenue" else 9.0, "kind": "blast_door"})
		out.append({"side": side, "kind": kind, "at": at[side], "backdrop": backdrop, "gates": gates})
	return out


## Highest point of building i (its tallest tier).
func top_of(i: int) -> float:
	var top := p("ceiling") + 1.0 if buildings[i]["pillar"] else 0.0
	for t: Dictionary in buildings[i]["tiers"]:
		top = maxf(top, float(t["y1"]))
	return top


# --- Downtown (docs/design/city-downtown.md) -------------------------------------------------------------
# A seeded contiguous cluster of blocks whose lots carry ceiling-touching towers of one family (a broad slab or a slender
# point, CityBuildings._tower) on six base layouts. All of it is plan data (tiers, solids: collision and checksum). The
# zone, each block's layout and its towers come from their own generators, seeded from the seed, the deck and the block,
# never from `_rng`'s sequence before the zone, so a plan without a zone is exactly what it was.
#
# A block is laid out in this order (_dt_design, pure, also the zone's test of whether a block can join): the pillar
# lots (as _carve), the THROUGH VIEW (a line across the block beside every core, at which the pieces are cut, sometimes
# with a paved gap: every lot keeps half the shaft spacing from a cut, so no shaft stands in it), lots of DT_LOT_MIN ..
# DT_LOT_MAX, each lot's shaft ROOM (street setback, half the spacing to the next lot's room, the spacing to a core, the
# lean of a tall box on the curved deck, clear of ceiling openings under its drop panel), the bases each lot can take,
# then one base per lot by a seeded search: neighbours differ, three kinds or more per block, perches at two heights.

const DT_BASES: Array[String] = ["podium", "stepped", "plaza", "corner", "twin", "arcade"]
const DT_SHARE := 1.0 / 3.0      ## a section deck's zone: about this share of its blocks
const DT_DECK_CHANCE := 0.67     ## on about two decks in three
const DT_BLOCK := 62.0           ## a district on its own with a zone plans blocks at least this big (section cells: 53-71 m)
const DT_SETBACK := 6.0          ## a shaft stands at least this far back from the building line on a street side
const DT_SPACING := 10.0         ## shafts (and pillar cores) at least this far apart: a mech always fits between
const DT_EDGE := 1.5             ## a shaft stays at least this far inside its lot
const DT_INNER := 0.25           ## a base's wall stands this far in from a lot edge that is not on a street
const DT_POINT := Vector2(8.0, 13.0)          ## a point tower's side: min, max (pass 2: 8 m on tight lots)
const DT_SLAB_LONG := Vector2(18.0, 26.0)     ## a slab's long side
const DT_SLAB_SHORT := Vector2(10.0, 13.0)    ## and its short side
const DT_SLAB_CHANCE := 0.9      ## of a single tower being a slab where one fits (twins and tight rooms are points: ~40 % slabs)
const DT_LOT_MIN := 21.0         ## a tower lot: setback + the smallest point + half the spacing
const DT_LOT_MAX := 42.0
const DT_GAP := 9.0              ## a mid-block gap at the through view (a paved through route) is this wide
const DT_GAP_CHANCE := 0.35
const DT_EYE := 8.0              ## a mech's eye: whatever rises past it blocks a view (a 6.5 m roof is seen over)
const DT_VIEW_HALF := 1.0        ## a through view is a corridor this far either side of its line
const DT_VIEW_INSET := 6.0       ## running at least this far inside the block's building line
const DT_GALLERY := 10.0         ## an arcade's walk-under gallery, from the building line in (columns included)
const DT_COLUMN := 1.2           ## an arcade column's side
const DT_COLUMN_PITCH := DT_COLUMN + 8.0     ## column centres: 8 m clear between columns
const DT_TERRACE_LIP := 1.5      ## a stepped podium keeps this much 6.5 m roof in front of its 13 m terrace
const DT_CORNER_MIN := 30.0      ## a corner cut needs a corner lot at least this big each way
const DT_WEIGHT := {"corner": 4.0, "twin": 4.0, "arcade": 0.8}     ## how often a base comes first where it fits
const DT_MAX_SHAFTS := 4         ## shafts in a block (pillar cores and twins included): towers behind towers, still gaps


## The downtown zone: {block index: its design} (empty: no zone). `share` of all the blocks, on a roll of `chance`;
## `allowed[bi]` whether block bi may join, `avenue[bi]` whether it borders the avenue (the zone grows from one of those
## through allowed neighbours whose design works).
func _downtown_zone(share: float, chance: float, allowed: Array[bool], avenue: Array[bool], by_block: Dictionary) -> Dictionary:
	var out := {}
	var zr := RandomNumberGenerator.new()
	zr.seed = int(p("seed")) * 92821 + (deck + 2) * 6271 + 17
	var roll := zr.randf()
	if share <= 0.0 or roll >= chance:
		return out
	var designs := {}
	var at := {}
	for bi in blocks.size():
		at[int(blocks[bi]["ix"]) * 1000 + int(blocks[bi]["is"])] = bi
	var starts: Array[int] = []
	for bi in blocks.size():
		if avenue[bi] and _dt_ok(bi, allowed, designs, by_block):
			starts.append(bi)
	if starts.is_empty():
		return out
	var target := maxi(1, roundi(share * float(blocks.size())))
	# Pass 2: start from an avenue block whose cluster (blocks that share a side or a crossing) can reach the target, or
	# else the biggest; urban cells are scattered among parks and transit cells, so a random start often had no room.
	var reach := {}
	var big := 0
	for bi in starts:
		reach[bi] = _dt_cluster(bi, target, at, allowed, designs, by_block).size()
		big = maxi(big, int(reach[bi]))
	var good: Array[int] = []
	for bi in starts:
		if int(reach[bi]) >= mini(big, target):
			good.append(bi)
	var zone: Array[int] = [good[zr.randi_range(0, good.size() - 1)]]
	while zone.size() < target:
		# Side neighbours first; blocks across a crossing (corner to corner) only when no side neighbour can join.
		var front: Array[int] = []
		for diag in 2:
			for bi in zone:
				for nb in _dt_neighbours(bi, at, diag == 1):
					if not zone.has(nb) and not front.has(nb) and _dt_ok(nb, allowed, designs, by_block):
						front.append(nb)
			if not front.is_empty():
				break
		if front.is_empty():
			break
		front.sort()
		zone.append(front[zr.randi_range(0, front.size() - 1)])
	for bi in zone:
		out[bi] = designs[bi]
	return out


## The blocks beside bi (sharing a side; `diag`: sharing only a crossing) by grid position.
func _dt_neighbours(bi: int, at: Dictionary, diag: bool) -> Array[int]:
	var out: Array[int] = []
	var dirs: Array = [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)] if diag \
			else [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d: Vector2i in dirs:
		var key := (int(blocks[bi]["ix"]) + d.x) * 1000 + int(blocks[bi]["is"]) + d.y
		if at.has(key):
			out.append(at[key])
	return out


## The blocks a zone grown from bi could reach (side or crossing neighbours whose design works), up to `cap` of them.
func _dt_cluster(bi: int, cap: int, at: Dictionary, allowed: Array[bool], designs: Dictionary, by_block: Dictionary) -> Array[int]:
	var seen: Array[int] = [bi]
	var i := 0
	while i < seen.size() and seen.size() < cap:
		for diag in [false, true]:
			for nb in _dt_neighbours(seen[i], at, diag):
				if not seen.has(nb) and _dt_ok(nb, allowed, designs, by_block):
					seen.append(nb)
		i += 1
	return seen


func _dt_ok(bi: int, allowed: Array[bool], designs: Dictionary, by_block: Dictionary) -> bool:
	if not allowed[bi]:
		return false
	if not designs.has(bi):
		designs[bi] = _dt_design(bi, by_block.get(bi, []))
	return bool(designs[bi]["ok"])


## The geometry of _carve without making lots: the pillar lots [{rect, q}] and the pieces left round them, in its order
## (`first` 0); `first` 1 cuts the pieces on the pillar's s sides first, as full-width bands (pass 2: a deep band beside
## a pillar holds towers where _carve's full-length strips are too narrow).
func _carve_geom(r: Rect2, pillars_here: Array, out_pillars: Array, out_pieces: Array[Rect2], first: int = 0) -> void:
	var inside := []
	for q: Dictionary in pillars_here:
		if r.grow(0.01).has_point(Vector2(q["x"], q["s"])):
			inside.append(q)
	if inside.is_empty():
		if minf(r.size.x, r.size.y) >= 4.0:
			out_pieces.append(r)
		return
	var q: Dictionary = inside[0]
	var half := float(q["half"]) + PILLAR_APRON
	var x0 := maxf(float(q["x"]) - half, r.position.x)
	var x1 := minf(float(q["x"]) + half, r.end.x)
	var s0 := maxf(float(q["s"]) - half, r.position.y)
	var s1 := minf(float(q["s"]) + half, r.end.y)
	var alley := 3.0
	if x0 - r.position.x < LOT_MIN + alley:
		x0 = r.position.x
	if r.end.x - x1 < LOT_MIN + alley:
		x1 = r.end.x
	if s0 - r.position.y < LOT_MIN + alley:
		s0 = r.position.y
	if r.end.y - s1 < LOT_MIN + alley:
		s1 = r.end.y
	out_pillars.append({"rect": Rect2(x0, s0, x1 - x0, s1 - s0), "q": q})
	var rest := []
	for o: Dictionary in pillars_here:
		if o != q:
			rest.append(o)
	if first == 1:
		if s0 > r.position.y:
			_carve_geom(Rect2(r.position.x, r.position.y, r.size.x, s0 - alley - r.position.y), rest, out_pillars, out_pieces, first)
		if s1 < r.end.y:
			_carve_geom(Rect2(r.position.x, s1 + alley, r.size.x, r.end.y - s1 - alley), rest, out_pillars, out_pieces, first)
		if x0 > r.position.x:
			_carve_geom(Rect2(r.position.x, s0, x0 - alley - r.position.x, s1 - s0), rest, out_pillars, out_pieces, first)
		if x1 < r.end.x:
			_carve_geom(Rect2(x1 + alley, s0, r.end.x - x1 - alley, s1 - s0), rest, out_pillars, out_pieces, first)
		return
	if x0 > r.position.x:
		_carve_geom(Rect2(r.position.x, r.position.y, x0 - alley - r.position.x, r.size.y), rest, out_pillars, out_pieces, first)
	if x1 < r.end.x:
		_carve_geom(Rect2(x1 + alley, r.position.y, r.end.x - x1 - alley, r.size.y), rest, out_pillars, out_pieces, first)
	if s0 > r.position.y:
		_carve_geom(Rect2(x0, r.position.y, x1 - x0, s0 - alley - r.position.y), rest, out_pillars, out_pieces, first)
	if s1 < r.end.y:
		_carve_geom(Rect2(x0, s1 + alley, x1 - x0, r.end.y - s1 - alley), rest, out_pillars, out_pieces, first)


## r with its extent along `axis` (0: x, 1: s) set to a..b.
static func _dt_cut(r: Rect2, axis: int, a: float, b: float) -> Rect2:
	if axis == 0:
		return Rect2(a, r.position.y, b - a, r.size.y)
	return Rect2(r.position.x, a, r.size.x, b - a)


## The block's through view: a line at c across the block (axis 0: it runs along s at x = c; 1: along x at s = c), clear
## of every pillar core, that the pieces it crosses are cut at, preferring cuts that leave a tower lot either side.
## {axis, c, gap} (gap: a paved mid-block gap there, 0 or DT_GAP); {} when no line clears the cores.
func _dt_lane(z: Rect2, pls: Array, pieces: Array[Rect2], rng: RandomNumberGenerator) -> Dictionary:
	var best := {}
	var best_score := -1.0e9
	for axis in 2:
		var c := ceilf(z.position[axis] + DT_VIEW_INSET + 2.0)
		while c <= z.end[axis] - DT_VIEW_INSET - 2.0:
			var ok := true
			for pl: Dictionary in pls:
				var core := float(pl["q"]["x"] if axis == 0 else pl["q"]["s"])
				if absf(c - core) < float(pl["q"]["half"]) + DT_VIEW_HALF + 2.0:
					ok = false
			var score := 0.0
			for q in pieces:
				if q.position[axis] + 0.01 < c and c < q.end[axis] - 0.01:
					if c - q.position[axis] >= DT_LOT_MIN and q.end[axis] - c >= DT_LOT_MIN:
						score += 2.0
					else:
						score -= 6.0
			if ok:
				score += rng.randf()
				if score > best_score:
					best_score = score
					best = {"axis": axis, "c": c}
			c += 1.0
	if best.is_empty():
		return best
	var gap := 0.0
	if rng.randf() < DT_GAP_CHANCE:
		var fits := true
		var crossed := 0
		var axis: int = best["axis"]
		var c: float = best["c"]
		for q in pieces:
			if q.position[axis] + 0.01 < c and c < q.end[axis] - 0.01:
				crossed += 1
				if c - DT_GAP * 0.5 - q.position[axis] < DT_LOT_MIN or q.end[axis] - c - DT_GAP * 0.5 < DT_LOT_MIN:
					fits = false
		if fits and crossed > 0:
			gap = DT_GAP
	best["gap"] = gap
	return best


## Cut r into lots of DT_LOT_MIN..DT_LOT_MAX along its long side (sometimes leaving a big one, for twins and slabs).
func _dt_split(r: Rect2, rng: RandomNumberGenerator, out: Array[Rect2]) -> void:
	var axis := 0 if r.size.x >= r.size.y else 1
	var length := r.size[axis]
	if length > DT_LOT_MAX or (length >= DT_LOT_MIN * 2.0 + 4.0 and rng.randf() < 0.6):
		var cut := snappedf(clampf(length * rng.randf_range(0.4, 0.6), DT_LOT_MIN, length - DT_LOT_MIN), 0.5)
		_dt_split(_dt_cut(r, axis, r.position[axis], r.position[axis] + cut), rng, out)
		_dt_split(_dt_cut(r, axis, r.position[axis] + cut, r.end[axis]), rng, out)
		return
	out.append(r)


## False where a base may not stand: on ground kept clear or by a floor hole.
func _dt_clear(r: Rect2) -> bool:
	for k in site.keep_clear:
		if k.intersects(r):
			return false
	for o in site.floor_holes:
		if o.grow(CityDims.HOLE_CURB + 0.5).intersects(r):
			return false
	return true


## Which sides of r lie on the building line of block zone z (face a street).
static func _dt_faces(r: Rect2, z: Rect2) -> Array[bool]:
	return [absf(r.end.x - z.end.x) < 0.01, absf(r.position.x - z.position.x) < 0.01,
			absf(r.end.y - z.end.y) < 0.01, absf(r.position.y - z.position.y) < 0.01]


## How far o lies beyond side `side` of r when it faces that side (overlapping it across), else INF.
static func _dt_gap(r: Rect2, o: Rect2, side: int) -> float:
	var axis := 0 if side < 2 else 1
	var other := 1 - axis
	if minf(r.end[other], o.end[other]) - maxf(r.position[other], o.position[other]) <= 0.0:
		return INF
	var g := o.position[axis] - r.end[axis] if side % 2 == 0 else r.position[axis] - o.end[axis]
	return g if g >= -0.01 else INF


static func _dt_core(q: Dictionary) -> Rect2:
	var h := float(q["half"])
	return Rect2(float(q["x"]) - h, float(q["s"]) - h, h * 2.0, h * 2.0)


## Where tower lot u's shaft(s) may stand (see the section header). A zero-size Rect2 when nowhere.
func _dt_room(u: Dictionary, units: Array) -> Rect2:
	var r: Rect2 = u["rect"]
	var faces: Array = u["faces"]
	var m: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for side in 4:
		if faces[side]:
			m[side] = DT_SETBACK
			continue
		# Half the spacing to the next tower lot's room; pillar cores are kept clear face to face below (pass 2).
		var need := DT_EDGE
		for o: Dictionary in units:
			if o == u or o["kind"] != "tower":
				continue
			var g := _dt_gap(r, o["rect"], side)
			if g > DT_SPACING + 1.0:
				continue
			need = maxf(need, (DT_SPACING - g) * 0.5 + 0.5)
		m[side] = need
	var room := Rect2(r.position.x + m[1], r.position.y + m[3], r.size.x - m[0] - m[1], r.size.y - m[2] - m[3])
	# Standing straight up to the ceiling on the curved deck, a shaft reaches further out along s the higher it goes: its
	# top must stay inside the lot (about the lot's centre, which is its building's).
	var rad := p("radius")
	var reach := r.size.y * 0.5 * (rad - p("ceiling") - 1.0) / rad - 0.3
	var cy := r.get_center().y
	room = _dt_clip_s(room, cy - reach, cy + reach)
	# Under a ceiling opening there is nothing to meet: keep the drop panel (and the opening's rim) clear of it.
	var kc := rad / (rad - p("ceiling"))
	for o: Rect2 in site.openings:
		if room.size.x <= 0.0 or room.size.y <= 0.0:
			break
		var f := CityDims.ceiling_opening(o).grow(CityDims.RIM + CityDims.DROP_PANEL + 0.5)
		var g := Rect2(f.position.x, cy + (f.position.y - cy) / kc, f.size.x, f.size.y / kc)
		if not g.intersects(room):
			continue
		var best := Rect2()
		for piece in CityGeo.cut(room, [g]):
			if minf(piece.size.x, piece.size.y) > minf(best.size.x, best.size.y):
				best = piece
		room = best
	var cores: Array[Rect2] = []
	for o: Dictionary in units:
		if o["kind"] == "pillar":
			cores.append(_dt_core(o["q"]))
	return _dt_avoid(room, cores)


## Face-to-face distance between two rectangles (0 when they overlap).
static func _dt_dist(a: Rect2, b: Rect2) -> float:
	var dx := maxf(maxf(b.position.x - a.end.x, a.position.x - b.end.x), 0.0)
	var ds := maxf(maxf(b.position.y - a.end.y, a.position.y - b.end.y), 0.0)
	return Vector2(dx, ds).length()


## The best part of `room` at least DT_SPACING (+0.5) face to face from every pillar core: room itself if it is clear,
## else the largest rectangle anchored at one of its corners whose far corner (searched on a 0.5 m grid) keeps the
## spacing, preferring one a point tower fits in (a tower may stand diagonally off a core: pass 2).
static func _dt_avoid(room: Rect2, cores: Array[Rect2]) -> Rect2:
	var need := DT_SPACING + 0.5
	var near: Array[Rect2] = []
	for c in cores:
		if _dt_dist(room, c) < need:
			near.append(c)
	if near.is_empty() or room.size.x <= 0.0 or room.size.y <= 0.0:
		return room
	var best := Rect2()
	var best_score := -1.0
	for corner in 4:
		var sx := 1.0 if corner % 2 == 0 else -1.0
		var ss := 1.0 if corner < 2 else -1.0
		var ax := room.position.x if sx > 0.0 else room.end.x
		var as_ := room.position.y if ss > 0.0 else room.end.y
		var i := int(room.size.x / 0.5 + 0.001)
		while i > 0:
			var w := float(i) * 0.5
			i -= 1
			if w < DT_POINT.x - 0.001:
				break
			var x0 := ax if sx > 0.0 else ax - w
			# The deepest d at this width: per core, clear across x, or behind the anchor, or d stops short of it.
			var d := room.size.y
			for c in near:
				var dx := maxf(maxf(c.position.x - (x0 + w), x0 - c.end.x), 0.0)
				if dx >= need:
					continue
				var h := sqrt(need * need - dx * dx)
				var front := c.position.y - as_ if ss > 0.0 else as_ - c.end.y
				var behind := as_ - c.end.y if ss > 0.0 else c.position.y - as_
				if behind >= h:
					continue
				d = minf(d, front - h)
			d = floorf(d / 0.5 + 0.001) * 0.5
			if d < DT_POINT.x - 0.001:
				continue
			var score := minf(w, d) * 1000.0 + w * d
			if score > best_score:
				best_score = score
				best = Rect2(x0, as_ if ss > 0.0 else as_ - d, w, d)
	return best


static func _dt_clip_s(r: Rect2, a: float, b: float) -> Rect2:
	var s0 := maxf(r.position.y, a)
	var s1 := minf(r.end.y, b)
	return Rect2(r.position.x, s0, r.size.x, maxf(s1 - s0, 0.0))


static func _dt_fits(room: Rect2, w: float, d: float) -> bool:
	return room.size.x >= w - 0.001 and room.size.y >= d - 0.001


static func _dt_shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


## The bases tower lot u can take, in a seeded order. Fills u["corner"] / u["arcade"] for those.
func _dt_options(u: Dictionary, high: bool, arcade_ok: bool, rng: RandomNumberGenerator) -> Array:
	var out := []
	var room: Rect2 = u["room"]
	if not _dt_fits(room, DT_POINT.x, DT_POINT.x):
		return out
	var faces: Array = u["faces"]
	var streets := 0
	for f: bool in faces:
		streets += 1 if f else 0
	out.append("podium")
	if high and streets > 0:
		out.append("stepped")
	if streets > 0:
		out.append("plaza")
	var cn := _dt_corner(u, rng)
	if not cn.is_empty():
		u["corner"] = cn
		out.append("corner")
	if maxf(room.size.x, room.size.y) >= DT_POINT.x * 2.0 + DT_SPACING:
		out.append("twin")
	if arcade_ok:
		var order := [0, 1, 2, 3]
		_dt_shuffle(order, rng)
		var r: Rect2 = u["rect"]
		for f: int in order:
			var axis := 0 if f < 2 else 1
			if faces[f] and r.size[axis] >= DT_GALLERY + 6.0 and room.size[1 - axis] >= DT_COLUMN_PITCH:
				u["arcade"] = f
				out.append("arcade")
				break
	# A seeded order, the rarer layouts (they need a big or a corner lot) first more often.
	var keyed := []
	for o: String in out:
		keyed.append([rng.randf() * float(DT_WEIGHT.get(o, 1.0)), o])
	keyed.sort_custom(func(m: Array, n: Array) -> bool: return m[0] > n[0])
	out.clear()
	for k: Array in keyed:
		out.append(k[1])
	return out


## A corner cut for corner lot u: the open plaza on its street corner, lot A (the tower's leg, full depth) and lot B (the
## low wing beside the plaza), and A's shaft room. {} when u is not a corner lot big enough.
func _dt_corner(u: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var r: Rect2 = u["rect"]
	var faces: Array = u["faces"]
	if r.size.x < DT_CORNER_MIN or r.size.y < DT_CORNER_MIN or not (faces[0] or faces[1]) or not (faces[2] or faces[3]):
		return {}
	var fx := 0 if faces[0] else 1
	if faces[0] and faces[1] and rng.randf() < 0.5:
		fx = 1
	var fs := 2 if faces[2] else 3
	if faces[2] and faces[3] and rng.randf() < 0.5:
		fs = 3
	var cw := snappedf(clampf(r.size.x * rng.randf_range(0.35, 0.45), 9.0, r.size.x - DT_LOT_MIN), 0.5)
	var cd := snappedf(clampf(r.size.y * rng.randf_range(0.35, 0.45), 9.0, r.size.y - 9.0), 0.5)
	var px := r.end.x - cw if fx == 0 else r.position.x
	var ps := r.end.y - cd if fs == 2 else r.position.y
	var plaza := Rect2(px, ps, cw, cd)
	var a := Rect2(r.position.x if fx == 0 else r.position.x + cw, r.position.y, r.size.x - cw, r.size.y)
	var b := Rect2(px, r.position.y if fs == 2 else r.position.y + cd, cw, r.size.y - cd)
	var room: Rect2 = u["room"]
	var x0 := room.position.x
	var x1 := room.end.x
	if fx == 0:
		x1 = minf(x1, a.end.x - DT_EDGE)
	else:
		x0 = maxf(x0, a.position.x + DT_EDGE)
	var ra := Rect2(x0, room.position.y, x1 - x0, room.size.y)
	if not _dt_fits(ra, DT_POINT.x, DT_POINT.x):
		return {}
	return {"plaza": plaza, "a": a, "b": b, "room_a": ra}


## The layout of downtown block bi (pure: no lots made): {ok, z, units: [{kind: pillar | tower | plaza, rect, faces,
## base, room, ...}], h0, h1}. ok is false when the block cannot hold the rules (a through view, three bases, perches at
## two heights): such a block stays urban.
func _dt_design(bi: int, pillars_here: Array) -> Dictionary:
	# Pass 2: a pillar block is cut both ways round its core (full-length strips, or full-width bands) and keeps the
	# layout that holds more based lots (the structural pillar is one of the block's towers).
	var best := _dt_design_try(bi, pillars_here, 0)
	if pillars_here.is_empty():
		return best
	var other := _dt_design_try(bi, pillars_here, 1)
	if _dt_design_score(other) > _dt_design_score(best):
		return other
	return best


static func _dt_design_score(d: Dictionary) -> int:
	var n := 0
	for u: Dictionary in d.get("units", []):
		if u.has("base") or (not d["ok"] and (u["kind"] == "tower" or u["kind"] == "pillar")):
			n += 1
	return (1000 if d["ok"] else 0) + n


func _dt_design_try(bi: int, pillars_here: Array, first: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(p("seed")) * 15485863 + (deck + 2) * 104723 + bi * 7919 + 3 + first * 7
	var z: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK)
	var pls := []
	var pieces: Array[Rect2] = []
	_carve_geom(z, pillars_here, pls, pieces, first)
	var lane := _dt_lane(z, pls, pieces, rng)
	if lane.is_empty():
		return {"ok": false, "why": "no through view clears the cores"}
	var units := []
	for pl: Dictionary in pls:
		units.append({"kind": "pillar", "rect": pl["rect"], "q": pl["q"]})
	var axis: int = lane["axis"]
	var c: float = lane["c"]
	var g: float = lane["gap"]
	for q in pieces:
		var parts: Array[Rect2] = [q]
		if q.position[axis] + 0.01 < c and c < q.end[axis] - 0.01:
			parts = [_dt_cut(q, axis, q.position[axis], c - g * 0.5), _dt_cut(q, axis, c + g * 0.5, q.end[axis])]
			if g > 0.0:
				units.append({"kind": "plaza", "rect": _dt_cut(q, axis, c - g * 0.5, c + g * 0.5), "gap": true})
		for part in parts:
			if part.size.x < 0.01 or part.size.y < 0.01:
				continue
			var cut: Array[Rect2] = []
			_dt_split(part, rng, cut)
			for l in cut:
				# A tower lot if its shaft room (below) fits a point; a lot that cannot is an open plaza (or a wing).
				var tall := minf(l.size.x, l.size.y) >= DT_POINT.x + DT_EDGE * 2.0 and _dt_clear(l)
				units.append({"kind": "tower" if tall else "plaza", "rect": l, "clear": _dt_clear(l)})
	for u: Dictionary in units:
		u["faces"] = _dt_faces(u["rect"], z)
	var h0 := float(band_floors(0)) * FLOOR_H
	var h1 := float(band_floors(1)) * FLOOR_H
	var high := h1 > h0 + 0.1 and h1 <= stand_limit() + 0.01
	var arcade_ok := high and h1 - FLOOR_H >= BRIDGE_CLEAR
	# Rooms twice: a lot whose room cannot hold a point is open ground, and no longer keeps its neighbours' rooms back;
	# so is a lot past DT_MAX_SHAFTS (the tightest rooms first), which keeps sightlines between the towers.
	for pass_ in 2:
		for u: Dictionary in units:
			if u["kind"] == "tower":
				u["room"] = _dt_room(u, units)
		var towers: Array = []
		for u: Dictionary in units:
			if u["kind"] == "tower" and not _dt_fits(u["room"], DT_POINT.x, DT_POINT.x):
				u["kind"] = "plaza"
			elif u["kind"] == "tower":
				towers.append(u)
		towers.sort_custom(func(m: Dictionary, n: Dictionary) -> bool:
			return minf((m["room"] as Rect2).size.x, (m["room"] as Rect2).size.y) > minf((n["room"] as Rect2).size.x, (n["room"] as Rect2).size.y))
		for k in range(maxi(DT_MAX_SHAFTS - pls.size(), 0), towers.size()):
			towers[k]["kind"] = "plaza"
	var based: Array[int] = []
	for i in units.size():
		var u: Dictionary = units[i]
		if u["kind"] == "tower":
			u["opts"] = _dt_options(u, high, arcade_ok, rng)
			if (u["opts"] as Array).is_empty():
				u["kind"] = "plaza"
		elif u["kind"] == "pillar":
			var opts := ["plaza"]
			if str(u["q"]["kind"]) != "lift":
				opts = ["podium"]
				if (u["faces"] as Array).has(true):
					opts.append("plaza")
				_dt_shuffle(opts, rng)
			u["opts"] = opts
		if u["kind"] == "tower" or u["kind"] == "pillar":
			based.append(i)
	# Three lots with a base, or two that differ (pass 2: a tight pillar block holds the pillar and one tower).
	if based.size() < 2:
		return {"ok": false, "why": "fewer than two lots with a base", "units": units}
	# Neighbours on a block face: side by side (across at most an alley) on the same street.
	var nb := {}
	for i in based:
		nb[i] = []
		for j in based:
			if i != j and _dt_touch(units[i]["rect"], units[j]["rect"], 3.6) and _dt_same_face(units[i]["faces"], units[j]["faces"]):
				(nb[i] as Array).append(j)
	if based.size() >= DT_MAX_SHAFTS:
		for i in based:
			(units[i]["opts"] as Array).erase("twin")
	var ctx := {"nodes": 0, "high": high, "h0": h0, "h1": h1}
	if not _dt_assign(units, based, nb, 0, ctx):
		return {"ok": false, "why": "no bases fit the rules", "units": units}
	_dt_wings(units, rng)
	return {"ok": true, "z": z, "units": units, "h0": h0, "h1": h1, "lane": lane}


## Pass 2: open lots left over beside a podium-like base (podium, stepped, twin, corner, a pillar's podium) mostly become
## its low WING: the same 6.5 m podium on a lot of its own (the street wall of the concept; seen over at a mech's eye,
## so it never closes a through view). The through view's paved gap and lots by a cut or kept-clear ground stay open.
const DT_WING_CHANCE := 0.75
const DT_WING_BASES: Array[String] = ["podium", "stepped", "twin", "corner"]


func _dt_wings(units: Array, rng: RandomNumberGenerator) -> void:
	for i in units.size():
		var u: Dictionary = units[i]
		var roll := rng.randf()
		if u["kind"] != "plaza" or u.get("gap", false) or not u.get("clear", false):
			continue
		var r: Rect2 = u["rect"]
		if minf(r.size.x, r.size.y) < 4.0 or roll >= DT_WING_CHANCE:
			continue
		var faces: Array = u["faces"]
		for j in units.size():
			var o: Dictionary = units[j]
			if not o.has("base") or not str(o["base"]) in DT_WING_BASES or o["kind"] == "wing":
				continue
			if not _dt_touch(r, o["rect"], 3.6):
				continue
			# Neighbours on a block face still differ: no wing beside another lot of the same base on its street.
			var clash := false
			for k in units.size():
				var w: Dictionary = units[k]
				if k != j and w.get("base", "") == o["base"] and int(w.get("wing_of", -1)) != j \
						and _dt_touch(r, w["rect"], 3.6) and _dt_same_face(faces, w["faces"]):
					clash = true
			if clash:
				continue
			u["kind"] = "wing"
			u["wing_of"] = j
			u["base"] = o["base"]
			break


## Whether rects a and b face each other across at most `tol` (overlapping by more than 1 m across).
static func _dt_touch(a: Rect2, b: Rect2, tol: float) -> bool:
	var dx := maxf(b.position.x - a.end.x, a.position.x - b.end.x)
	var ds := maxf(b.position.y - a.end.y, a.position.y - b.end.y)
	var over_x := minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	var over_s := minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	return (dx >= -0.01 and dx <= tol and over_s > 1.0) or (ds >= -0.01 and ds <= tol and over_x > 1.0)


static func _dt_same_face(a: Array, b: Array) -> bool:
	for k in 4:
		if a[k] and b[k]:
			return true
	return false


## Seeded depth-first search for one base per unit: no two neighbours alike, then _dt_rules. Bounded.
func _dt_assign(units: Array, order: Array[int], nb: Dictionary, i: int, ctx: Dictionary) -> bool:
	if i >= order.size():
		return _dt_rules(units, order, ctx)
	ctx["nodes"] = int(ctx["nodes"]) + 1
	if int(ctx["nodes"]) > 4000:
		return false
	var u: Dictionary = units[order[i]]
	for kind: String in u["opts"]:
		var clash := false
		for j: int in nb[order[i]]:
			if units[j].get("base", "") == kind:
				clash = true
		if clash:
			continue
		u["base"] = kind
		if _dt_assign(units, order, nb, i + 1, ctx):
			return true
		u.erase("base")
	return false


## Three kinds of base or more in the block, and standable roofs at two heights or more (one where the bands allow
## only one).
func _dt_rules(units: Array, order: Array[int], ctx: Dictionary) -> bool:
	var kinds := {}
	var heights := {}
	var shafts := 0
	for i in order:
		var u: Dictionary = units[i]
		var base: String = u["base"]
		kinds[base] = true
		shafts += 2 if base == "twin" else 1
		if shafts > DT_MAX_SHAFTS:
			return false
		if base in ["podium", "stepped", "corner", "twin"]:
			heights[ctx["h0"]] = true
		if (base == "stepped" or base == "arcade") and ctx["high"]:
			heights[ctx["h1"]] = true
	# A block of only two based lots: both differ (pass 2).
	return kinds.size() >= mini(3, order.size()) and heights.size() >= (2 if ctx["high"] else 1)


## Downtown block bi from its design: lots, bases and towers.
func _fill_downtown(bi: int, d: Dictionary) -> void:
	blocks[bi]["downtown"] = true
	var z: Rect2 = d["z"]
	var trng := RandomNumberGenerator.new()
	trng.seed = int(p("seed")) * 49979687 + (deck + 2) * 1299709 + bi * 104729 + 11
	var units: Array = d["units"]
	for ui in units.size():
		var u: Dictionary = units[ui]
		var r: Rect2 = u["rect"]
		match str(u["kind"]):
			"pillar":
				var li := _add_lot(r, bi, z, "")
				_add_pillar(li, u["q"])
				var pb: Dictionary = buildings[buildings.size() - 1]
				pb["base"] = u["base"]
				pb["unit"] = ui
				if u["base"] == "podium":
					pb["band"] = 0
				else:
					pb["paving"] = [r]
			"plaza":
				if minf(r.size.x, r.size.y) >= 4.0:
					_add_lot(r, bi, z, "plaza")
			"wing":
				var li := _add_lot(r, bi, z, "")
				var wb := _dt_building(li, str(u["base"]), 0, int(u["wing_of"]), trng)
				wb["wing"] = true
				var env := _dt_env(r, lots[li]["faces"])
				wb["dt"]["env"] = env
				wb["dt"]["parts"] = [_dt_part("podium", env, 0.0, d["h0"], true)]
			"tower":
				_dt_tower(bi, z, ui, u, d, trng)


## A base's walls: the lot, out to the building line on its street sides, DT_INNER in from the others.
static func _dt_env(r: Rect2, faces: Array) -> Rect2:
	var x0 := r.position.x + (0.0 if faces[1] else DT_INNER)
	var x1 := r.end.x - (0.0 if faces[0] else DT_INNER)
	var s0 := r.position.y + (0.0 if faces[3] else DT_INNER)
	var s1 := r.end.y - (0.0 if faces[2] else DT_INNER)
	return Rect2(x0, s0, x1 - x0, s1 - s0)


func _dt_building(li: int, base: String, band: int, unit: int, rng: RandomNumberGenerator) -> Dictionary:
	var lot: Dictionary = lots[li]
	lot["building"] = buildings.size()
	var b := {"lot": li, "style": "tower", "band": band, "pillar": false, "front": maxi(int(lot["front"]), 0), "setback": 0.0,
			"variant": rng.randi_range(0, 999), "floors": 0, "roof_h": 0.0, "center": Vector2.ZERO, "size": Vector2.ZERO,
			"tiers": [], "base": base, "unit": unit,
			"dt": {"env": Rect2(), "top": 0.0, "lean": 1.0, "parts": [], "shafts": [], "columns": [], "clear": 0.0}}
	buildings.append(b)
	return b


func _dt_part(kind: String, r: Rect2, y0: float, y1: float, stand: bool) -> Dictionary:
	return {"kind": kind, "rect": r, "y0": y0, "y1": y1, "stand": stand}


## The tower(s) of lot u (unit ui of block bi's design d) on its base.
func _dt_tower(bi: int, z: Rect2, ui: int, u: Dictionary, d: Dictionary, rng: RandomNumberGenerator) -> void:
	var base: String = u["base"]
	var h0: float = d["h0"]
	var h1: float = d["h1"]
	var r: Rect2 = u["rect"]
	var room: Rect2 = u["room"]
	if base == "corner":
		var cn: Dictionary = u["corner"]
		_add_lot(cn["plaza"], bi, z, "plaza")
		var la := _add_lot(cn["a"], bi, z, "")
		var ba := _dt_building(la, base, 0, ui, rng)
		var env_a := _dt_env(cn["a"], lots[la]["faces"])
		ba["dt"]["env"] = env_a
		ba["dt"]["parts"] = [_dt_part("podium", env_a, 0.0, h0, true)]
		ba["dt"]["shafts"] = [_dt_shaft(bi, cn["room_a"], rng, [], h0, true)]
		var lb := _add_lot(cn["b"], bi, z, "")
		var bb := _dt_building(lb, base, 0, ui, rng)
		var env_b := _dt_env(cn["b"], lots[lb]["faces"])
		bb["dt"]["env"] = env_b
		bb["dt"]["parts"] = [_dt_part("podium", env_b, 0.0, h0, true)]
		return
	var li := _add_lot(r, bi, z, "")
	var faces: Array = lots[li]["faces"]
	var b := _dt_building(li, base, 1 if base == "stepped" or base == "arcade" else 0, ui, rng)
	var dt: Dictionary = b["dt"]
	var env := _dt_env(r, faces)
	dt["env"] = env
	match base:
		"podium":
			dt["parts"] = [_dt_part("podium", env, 0.0, h0, true)]
			dt["shafts"] = [_dt_shaft(bi, room, rng, [], h0, true)]
		"stepped":
			# The terrace against the tower on the street side(s): the shaft hugs its room's edge there.
			var streets := []
			for side in 4:
				if faces[side]:
					streets.append(side)
			_dt_shuffle(streets, rng)
			var hug := [streets[0]]
			if streets.size() > 1 and (int(streets[1]) < 2) != (int(streets[0]) < 2) and rng.randf() < 0.5:
				hug.append(streets[1])
			var sh := _dt_shaft(bi, room, rng, hug, h0, true)
			var parts := [_dt_part("podium", env, 0.0, h0, true)]
			var s: Rect2 = sh["rect"]
			for side: int in hug:
				var t: Rect2
				match side:
					0: t = Rect2(s.end.x - 1.0, s.position.y, r.end.x - DT_TERRACE_LIP - s.end.x + 1.0, s.size.y)
					1: t = Rect2(r.position.x + DT_TERRACE_LIP, s.position.y, s.position.x + 1.0 - r.position.x - DT_TERRACE_LIP, s.size.y)
					2: t = Rect2(s.position.x, s.end.y - 1.0, s.size.x, r.end.y - DT_TERRACE_LIP - s.end.y + 1.0)
					_: t = Rect2(s.position.x, r.position.y + DT_TERRACE_LIP, s.size.x, s.position.y + 1.0 - r.position.y - DT_TERRACE_LIP)
				parts.append(_dt_part("terrace", t, h0, h1, true))
			dt["parts"] = parts
			dt["shafts"] = [sh]
		"plaza":
			# No podium: the shaft's lobby at ground in a paved plaza (its footprint is the building's).
			var sh := _dt_shaft(bi, room, rng, [], 0.0, true)
			dt["env"] = sh["rect"]
			dt["shafts"] = [sh]
			b["paving"] = [r]
			b["planters"] = _dt_planters(r, faces, sh["rect"])
		"twin":
			var la := 0 if room.size.x >= room.size.y else 1
			var side := snappedf(rng.randf_range(DT_POINT.x, DT_POINT.y), 0.5)
			side = minf(side, minf(room.size[1 - la], (room.size[la] - DT_SPACING) * 0.5))
			var across := rng.randf_range(room.position[1 - la], room.end[1 - la] - side)
			var shafts := []
			for k in 2:
				var along := room.position[la] if k == 0 else room.end[la] - side
				var pos := Vector2(along, across) if la == 0 else Vector2(across, along)
				shafts.append({"rect": Rect2(pos, Vector2(side, side)), "kind": "point", "y0": h0})
			dt["parts"] = [_dt_part("podium", env, 0.0, h0, true)]
			dt["shafts"] = shafts
		"arcade":
			var f: int = u["arcade"]
			var clear := h1 - FLOOR_H
			var axis := 0 if f < 2 else 1
			var gallery: Rect2
			var lobby: Rect2
			if f % 2 == 0:
				gallery = _dt_cut(env, axis, env.end[axis] - DT_GALLERY, env.end[axis])
				lobby = _dt_cut(env, axis, env.position[axis], env.end[axis] - DT_GALLERY)
			else:
				gallery = _dt_cut(env, axis, env.position[axis], env.position[axis] + DT_GALLERY)
				lobby = _dt_cut(env, axis, env.position[axis] + DT_GALLERY, env.end[axis])
			dt["parts"] = [_dt_part("lobby", lobby, 0.0, clear, false), _dt_part("arcade", env, clear, h1, true)]
			dt["clear"] = clear
			dt["gallery"] = gallery
			dt["front"] = f
			# Columns along the street: 8 m clear between them, over the shaft room's span (the cut lanes stay open).
			var line := env.end[axis] - 0.4 - DT_COLUMN * 0.5 if f % 2 == 0 else env.position[axis] + 0.4 + DT_COLUMN * 0.5
			var lo := room.position[1 - axis]
			var hi := room.end[1 - axis]
			var n := int((hi - lo) / DT_COLUMN_PITCH) + 1
			var cols := []
			for k in n:
				var at := lo + (hi - lo) * float(k) / float(n - 1)
				cols.append(Vector2(line, at) if axis == 0 else Vector2(at, line))
			dt["columns"] = cols
			dt["shafts"] = [_dt_shaft(bi, room, rng, [], h1, true)]
			b["paving"] = [gallery]


## A shaft in `room`: a point, or a slab where one fits (by roll, never facing another slab across a street), placed by
## seed, pushed against the room's sides in `hug`. {rect, kind, y0}.
func _dt_shaft(bi: int, room: Rect2, rng: RandomNumberGenerator, hug: Array, y0: float, slab_ok: bool) -> Dictionary:
	var la := 0 if room.size.x >= room.size.y else 1
	var size := Vector2.ZERO
	var kind := "point"
	if slab_ok and room.size[la] >= DT_SLAB_LONG.x and room.size[1 - la] >= DT_SLAB_SHORT.x and rng.randf() < DT_SLAB_CHANCE:
		var long := minf(snappedf(rng.randf_range(DT_SLAB_LONG.x, minf(DT_SLAB_LONG.y, room.size[la])), 0.5), room.size[la])
		var short := minf(snappedf(rng.randf_range(DT_SLAB_SHORT.x, minf(DT_SLAB_SHORT.y, room.size[1 - la])), 0.5), room.size[1 - la])
		size = Vector2(long, short) if la == 0 else Vector2(short, long)
		kind = "slab"
	if kind == "point":
		var side := minf(snappedf(rng.randf_range(DT_POINT.x, minf(DT_POINT.y, minf(room.size.x, room.size.y))), 0.5),
				minf(room.size.x, room.size.y))
		size = Vector2(side, side)
	var pos := Vector2(rng.randf_range(room.position.x, room.end.x - size.x), rng.randf_range(room.position.y, room.end.y - size.y))
	for side: int in hug:
		match side:
			0: pos.x = room.end.x - size.x
			1: pos.x = room.position.x
			2: pos.y = room.end.y - size.y
			3: pos.y = room.position.y
	var rect := Rect2(pos, size)
	if kind == "slab" and _dt_slab_facing(bi, rect):
		return _dt_shaft(bi, room, rng, hug, y0, false)
	return {"rect": rect, "kind": kind, "y0": y0}


## Whether a slab at `rect` in block bi would face another slab across a street: long sides parallel, overlapping along
## them, in the next block across (rule "never two slabs facing each other across a street": they wall the view).
func _dt_slab_facing(bi: int, rect: Rect2) -> bool:
	var axis := 0 if rect.size.x >= rect.size.y else 1      # along the long side
	for o: Dictionary in buildings:
		if o["style"] != "tower":
			continue
		var obi := int(lots[o["lot"]]["block"])
		var dix := absi(int(blocks[obi]["ix"]) - int(blocks[bi]["ix"]))
		var dis := absi(int(blocks[obi]["is"]) - int(blocks[bi]["is"]))
		# The long sides face across axis 1 - axis: the next block that way, same row or column the other way.
		var across := (axis == 1 and dix == 1 and dis == 0) or (axis == 0 and dis == 1 and dix == 0)
		if not across:
			continue
		for sh: Dictionary in o["dt"]["shafts"]:
			if sh["kind"] != "slab":
				continue
			var r: Rect2 = sh["rect"]
			var oaxis := 0 if r.size.x >= r.size.y else 1
			if oaxis == axis and minf(r.end[axis], rect.end[axis]) - maxf(r.position[axis], rect.position[axis]) > 0.0:
				return true
	return false


## A plaza base's fixed planters (looks only: CityStreets.furniture), on the paving between the street and the shaft:
## [[centre, size]] in arc coordinates.
static func _dt_planters(r: Rect2, faces: Array, shaft: Rect2) -> Array:
	var out := []
	for side in 4:
		if not faces[side]:
			continue
		var axis := 0 if side < 2 else 1          # the street's normal
		var at := r.end[axis] - 3.0 if side % 2 == 0 else r.position[axis] + 3.0
		var sz := Vector2(1.3, 3.2) if axis == 0 else Vector2(3.2, 1.3)
		for k in 2:
			var along := shaft.position[1 - axis] - 3.0 if k == 0 else shaft.end[1 - axis] + 3.0
			along = clampf(along, r.position[1 - axis] + 2.5, r.end[1 - axis] - 2.5)
			out.append([Vector2(at, along) if axis == 0 else Vector2(along, at), sz])
		break
	return out


## Footprint and heights of a downtown building (its envelope, narrowed along s like every building so its base's walls
## stay inside the lot on the curve; a plaza tower's footprint is its shaft, which keeps its full size).
func _shape_tower(b: Dictionary) -> void:
	var dt: Dictionary = b["dt"]
	var top := 0.0
	for part: Dictionary in dt["parts"]:
		top = maxf(top, float(part["y1"]))
	var bare := top <= 0.0
	if bare:
		top = float(band_floors(0)) * FLOOR_H
	dt["top"] = top
	var lean := 1.0 if bare else (p("radius") - top - 3.0) / p("radius")
	dt["lean"] = lean
	var env: Rect2 = dt["env"]
	b["center"] = env.get_center()
	b["size"] = Vector2(snappedf(env.size.x, 0.01), snappedf(env.size.y * lean, 0.01))
	b["floors"] = maxi(int(round(top / FLOOR_H)), 2)
	b["roof_h"] = top


## Tiers and solids of a downtown building, in its frame: base parts narrowed along s (as the footprint), shafts at full
## size from their base up into the ceiling slab (not standable), the arcade's columns.
func _tower_tiers(b: Dictionary, tiers: Array, solids: Array) -> void:
	var dt: Dictionary = b["dt"]
	var lean: float = dt["lean"]
	var c: Vector2 = b["center"]
	for part: Dictionary in dt["parts"]:
		var r: Rect2 = part["rect"]
		tiers.append(_tier(Vector2(r.get_center().x - c.x, (r.get_center().y - c.y) * lean), Vector2(r.size.x, r.size.y * lean),
				part["y0"], part["y1"], part["stand"], part["kind"]))
	if dt.has("gallery"):
		var g: Rect2 = dt["gallery"]
		dt["gallery_frame"] = Rect2(Vector2(g.position.x - c.x, (g.position.y - c.y) * lean), Vector2(g.size.x, g.size.y * lean))
	for sh: Dictionary in dt["shafts"]:
		var r: Rect2 = sh["rect"]
		var t := _tier(r.get_center() - c, r.size, sh["y0"], p("ceiling") + 1.0, false, "tower")
		t["tower"] = sh["kind"]
		tiers.append(t)
	for col: Vector2 in dt["columns"]:
		solids.append(_solid("column", Vector2(col.x - c.x, (col.y - c.y) * lean), Vector2(DT_COLUMN, DT_COLUMN), 0.0, float(dt["clear"])))


# --- Downtown: what the rules read (tests, the lab) --------------------------------------------------------

## Indices of the downtown blocks.
func downtown_blocks() -> Array[int]:
	var out: Array[int] = []
	for bi in blocks.size():
		if blocks[bi].get("downtown", false):
			out.append(bi)
	return out


## Indices of the buildings standing in block bi.
func buildings_in(bi: int) -> Array[int]:
	var out: Array[int] = []
	for i in buildings.size():
		if int(lots[buildings[i]["lot"]]["block"]) == bi:
			out.append(i)
	return out


## Tier t (a tier dictionary) of building i as a ground rectangle in arc coordinates (its frame's footprint).
func tier_rect(i: int, t: Dictionary) -> Rect2:
	var size: Vector2 = t["size"]
	return Rect2((buildings[i]["center"] as Vector2) + (t["off"] as Vector2) - size * 0.5, size)


## Every downtown shaft and every pillar core in block bi (bi < 0: all of them), as ground rectangles.
func shaft_rects(bi: int = -1) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for i in buildings.size():
		var b: Dictionary = buildings[i]
		if bi >= 0 and int(lots[b["lot"]]["block"]) != bi:
			continue
		for t: Dictionary in b["tiers"]:
			if str(t.get("kind", "")) == "tower":
				out.append(tier_rect(i, t))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			out.append(Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs))
	return out


## The through views of block bi: [{axis, c}] for every line on a 0.5 m step (axis 0: along s at x = c; 1: along x at
## s = c), at least DT_VIEW_INSET inside the building line, whose corridor (DT_VIEW_HALF either side) crosses the block
## from street to street at a mech's eye (DT_EYE) clear of whatever rises past it: tiers, shafts, columns, pillar cores.
func through_views(bi: int) -> Array:
	var z: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK)
	var blockers: Array[Rect2] = []
	for i in buildings_in(bi):
		var b: Dictionary = buildings[i]
		for t: Dictionary in b["tiers"]:
			if float(t["y0"]) < DT_EYE and float(t["y1"]) > DT_EYE:
				blockers.append(tier_rect(i, t))
		for so: Dictionary in b.get("solids", []):
			if float(so["y0"]) < DT_EYE and float(so["y1"]) > DT_EYE:
				var sz: Vector2 = so["size"]
				blockers.append(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			blockers.append(Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs))
	var out := []
	for axis in 2:
		var c := z.position[axis] + DT_VIEW_INSET
		while c <= z.end[axis] - DT_VIEW_INSET + 0.001:
			var clear := true
			for r in blockers:
				if r.position[axis] < c + DT_VIEW_HALF and c - DT_VIEW_HALF < r.end[axis]:
					clear = false
					break
			if clear:
				out.append({"axis": axis, "c": c})
			c += 0.5
	return out


## The diagonal views of block bi (pass 2: across a corner cut, a plaza or the gaps between bases): [{dir, c, a, b}] for
## every 45-degree line on a 1 m step (dir 1: x - s = c, dir -1: x + s = c) whose stretch inside the building line is at
## least DT_DIAG_MIN long and whose corridor (DT_VIEW_HALF either side) is clear at a mech's eye; a, b its ends.
const DT_DIAG_MIN := 20.0


func diagonal_views(bi: int) -> Array:
	var z: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK)
	var blockers := _dt_eye_blockers(bi)
	var out := []
	for dir: float in [1.0, -1.0]:
		# x - dir * s = c over the corners of z.
		var cs: Array[float] = [z.position.x - dir * z.position.y, z.end.x - dir * z.position.y, z.position.x - dir * z.end.y, z.end.x - dir * z.end.y]
		var lo: float = cs.min()
		var hi: float = cs.max()
		var c := ceilf(lo)
		while c <= hi:
			# Clip the line x = c + dir * s to z.
			var s0 := maxf(z.position.y, (z.position.x - c) * dir if dir > 0.0 else (z.end.x - c) * dir)
			var s1 := minf(z.end.y, (z.end.x - c) * dir if dir > 0.0 else (z.position.x - c) * dir)
			if (s1 - s0) * sqrt(2.0) >= DT_DIAG_MIN:
				var a := Vector2(c + dir * s0, s0)
				var b := Vector2(c + dir * s1, s1)
				var clear := true
				for r in blockers:
					if _dt_seg_rect(a, b, r.grow(DT_VIEW_HALF)):
						clear = false
						break
				if clear:
					out.append({"dir": int(dir), "c": c, "a": a, "b": b})
			c += 1.0
	return out


## Whether segment a-b crosses rectangle r (Liang-Barsky clip).
static func _dt_seg_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	for k in 2:
		if absf(d[k]) < 1e-9:
			if a[k] < r.position[k] or a[k] > r.end[k]:
				return false
			continue
		var ta := (r.position[k] - a[k]) / d[k]
		var tb := (r.end[k] - a[k]) / d[k]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return false
	return true


## What rises past a mech's eye in block bi: tiers, solids, pillar cores (ground rectangles).
func _dt_eye_blockers(bi: int) -> Array[Rect2]:
	var blockers: Array[Rect2] = []
	for i in buildings_in(bi):
		var b: Dictionary = buildings[i]
		for t: Dictionary in b["tiers"]:
			if float(t["y0"]) < DT_EYE and float(t["y1"]) > DT_EYE:
				blockers.append(tier_rect(i, t))
		for so: Dictionary in b.get("solids", []):
			if float(so["y0"]) < DT_EYE and float(so["y1"]) > DT_EYE:
				var sz: Vector2 = so["size"]
				blockers.append(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			blockers.append(Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs))
	return blockers


## The heights of the standable roofs in block bi (rounded to 0.1 m, sorted, unique).
func perch_heights(bi: int) -> Array[float]:
	var out: Array[float] = []
	for i in buildings_in(bi):
		for t: Dictionary in buildings[i]["tiers"]:
			var y := snappedf(float(t["y1"]), 0.1)
			if t["stand"] and not out.has(y):
				out.append(y)
	out.sort()
	return out


## Where shafts meet the ceiling, in arc coordinates: every site pillar's drop panel, then every downtown shaft's
## (CityStreets.ceiling_range keeps the light strips and ducts out of them).
func ceiling_heads() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for q: Dictionary in site.pillars:
		var m := float(q["half"]) + CityDims.DROP_PANEL
		out.append(Rect2(float(q["x"]) - m, float(q["s"]) - m, m * 2.0, m * 2.0))
	for i in buildings.size():
		for t: Dictionary in buildings[i]["tiers"]:
			if str(t.get("kind", "")) == "tower":
				out.append(shaft_head(i, t).grow(CityDims.DROP_PANEL))
	return out


## Shaft tier t of building i where it meets the ceiling, in arc coordinates: it stands straight in its building's frame,
## so along s it reaches further out the higher it goes.
func shaft_head(i: int, t: Dictionary) -> Rect2:
	var c: Vector2 = buildings[i]["center"]
	var off: Vector2 = t["off"]
	var size: Vector2 = t["size"]
	var k := p("radius") / (p("radius") - p("ceiling"))
	return Rect2(c.x + off.x - size.x * 0.5, c.y + (off.y - size.y * 0.5) * k, size.x, size.y * k)


# --- Alleys (docs/design/city-variety.md section 1) ------------------------------------------------------
# A service alley is a straight lane cut through the middle of a block from one street side to the opposite one: the
# block's lots are planned as two rows either side of it. Gameplay shape (lots, buildings, checksum), mech-walkable (it
# is on the block's sidewalk slab and opens onto the sidewalk at both ends), never a vehicle or walker route (it is in no
# graph). Its width is the clear distance between the buildings' collision faces at a mech's top (MECH_TOP): buildings
# stand radially, so walls facing each other across the arc lean together with height. Which blocks get one comes from
# a generator of its own (seed, deck), never the plan's: a deck that rolls none is exactly the plan before alleys.

const ALLEY_W := 7.0             ## clear width between collision faces at MECH_TOP (spec: >= 7 m)
const ALLEY_ROW := 14.0          ## each lot row beside an alley is at least this deep
const ALLEY_SHIFT := 4.0         ## an alley sits up to this far off its block's middle (seeded)
const ALLEY_CORRIDOR := 1        ## alleys of neighbouring blocks lined up into one corridor: at most this many per deck


## The alley's width on the ground (lot to lot): ALLEY_W at MECH_TOP for walls that lean together across the arc, on a
## 0.5 m step. (Buildings stand a setback further back still.)
func alley_band() -> float:
	var r := p("radius")
	return ceilf((ALLEY_W * r / (r - MECH_TOP) + 0.05) * 2.0) / 2.0


## {block index: {block, rect, axis}} for the blocks that get an alley (axis 0: it runs along x, a band across s).
func _plan_alleys(eligible: Array[bool], by_block: Dictionary = {}) -> Dictionary:
	var out := {}
	var share := p("alleys")
	if share <= 0.0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = int(p("seed")) * 7368787 + (deck + 2) * 1000003 + 29
	var w := alley_band()
	var at := {}
	for bi in blocks.size():
		at[Vector2i(int(blocks[bi]["ix"]), int(blocks[bi]["is"]))] = bi
	var lined := 0
	for bi in blocks.size():
		# Always the same draws per block, so one block's outcome never moves another's.
		var roll := rng.randf()
		var pick := rng.randf()
		var jit := rng.randf_range(-1.0, 1.0)
		var allow := rng.randf()
		if not eligible[bi] or roll >= share:
			continue
		var z: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK)
		var axes: Array[int] = []
		for along in 2:
			if z.size[1 - along] >= ALLEY_ROW * 2.0 + w:
				axes.append(along)
		if axes.is_empty():
			continue
		var along: int = axes[mini(int(pick * axes.size()), axes.size() - 1)]
		var across := 1 - along
		var room := (z.size[across] - w) * 0.5 - ALLEY_ROW
		var mid := z.position[across] + z.size[across] * 0.5
		var c := mid + snappedf(jit * minf(room, ALLEY_SHIFT), 0.5)
		var rect := _alley_rect(z, along, c, w)
		if by_block.has(bi):
			# Pass 2: a block with a pillar takes its alley beside the core (the pillar's podium may be one wall): the
			# position nearest the seeded one, on this axis or else the other, that keeps ALLEY_PILLAR off every core.
			var found := _alley_beside(z, by_block[bi], along, c, w)
			if found.is_empty() and axes.size() > 1:
				along = 1 - along
				across = 1 - along
				room = (z.size[across] - w) * 0.5 - ALLEY_ROW
				mid = z.position[across] + z.size[across] * 0.5
				found = _alley_beside(z, by_block[bi], along, mid + snappedf(jit * minf(room, ALLEY_SHIFT), 0.5), w)
			if found.is_empty():
				continue
			c = found["c"]
			rect = found["rect"]
		if _alley_lined(rect, along, bi, out, at):
			# Move it off the neighbour's line if the block allows, else keep it only as the deck's one corridor (seeded).
			var moved := false
			# A pillar block's moved alley must itself keep off the cores, with full rows either side (as _alley_beside asks).
			# (Until 2026-11-25 this compared _alley_beside's 0.5 m grid answer with c2 by ==; c2 = the block's middle + a
			# 0.5 m step, and the middles lie off that grid, so it never held: over section seeds 1-20 and 403112 it was
			# reached 4 times in 63 decks, held 0 times; checking c2 itself moves one alley, seed 13 deck 1.)
			for sgn: float in [1.0, -1.0]:
				var c2 := mid + sgn * snappedf(minf(room, w + 4.0), 0.5)
				var r2 := _alley_rect(z, along, c2, w)
				var beside := not by_block.has(bi) or (absf(c2 - mid) <= room + 0.001 and _alley_clear_of(z, by_block[bi], along, r2))
				if absf(c2 - mid) >= 0.5 and not _alley_lined(r2, along, bi, out, at) and beside:
					rect = r2
					moved = true
					break
			if not moved:
				if lined >= ALLEY_CORRIDOR or allow >= 0.5:
					continue
				lined += 1
		if not _alley_clear(rect):
			continue
		out[bi] = {"block": bi, "rect": rect, "axis": along}
	return out


const ALLEY_PILLAR := 1.0        ## an alley beside a pillar keeps at least this far from its core


## The alley in block zone z beside the pillars `pls` nearest to centre line c: {c, rect}, or {} when no line with a lot
## row of ALLEY_ROW either side keeps ALLEY_PILLAR off every core and leaves each core's row deep enough for its lot.
func _alley_beside(z: Rect2, pls: Array, along: int, c: float, w: float) -> Dictionary:
	var across := 1 - along
	var lo := z.position[across] + ALLEY_ROW + w * 0.5
	var hi := z.end[across] - ALLEY_ROW - w * 0.5
	var best := {}
	var best_d := INF
	var t := ceilf(lo * 2.0) / 2.0
	while t <= hi + 0.001:
		var rect := _alley_rect(z, along, t, w)
		if absf(t - c) < best_d and _alley_clear_of(z, pls, along, rect):
			best = {"c": t, "rect": rect}
			best_d = absf(t - c)
		t += 0.5
	return best


## Whether an alley at `rect` keeps ALLEY_PILLAR off every core of `pls` and leaves each core's row (the side it stands
## on) holding it whole, its apron clipped at the alley.
func _alley_clear_of(z: Rect2, pls: Array, along: int, rect: Rect2) -> bool:
	var across := 1 - along
	for q: Dictionary in pls:
		var core := _dt_core(q).grow(ALLEY_PILLAR)
		if core.intersects(rect):
			return false
		if core.position[across] < z.position[across] or core.end[across] > z.end[across]:
			return false
	return true


static func _alley_rect(z: Rect2, along: int, c: float, w: float) -> Rect2:
	if along == 0:
		return Rect2(z.position.x, c - w * 0.5, z.size.x, w)
	return Rect2(c - w * 0.5, z.position.y, w, z.size.y)


## Whether an alley at `rect` would line up with one already planned in a neighbouring block along its run.
func _alley_lined(rect: Rect2, along: int, bi: int, planned: Dictionary, at: Dictionary) -> bool:
	var cell := Vector2i(int(blocks[bi]["ix"]), int(blocks[bi]["is"]))
	var step := Vector2i(1, 0) if along == 0 else Vector2i(0, 1)
	for nb: Vector2i in [cell + step, cell - step]:
		if not at.has(nb) or not planned.has(at[nb]):
			continue
		var o: Dictionary = planned[at[nb]]
		if int(o["axis"]) != along:
			continue
		var r: Rect2 = o["rect"]
		var a := 1 - along
		if minf(r.end[a], rect.end[a]) - maxf(r.position[a], rect.position[a]) > -2.0:
			return true
	return false


## False where an alley may not run: over ground kept clear, by a floor hole or a ramp.
func _alley_clear(rect: Rect2) -> bool:
	for k in site.keep_clear:
		if k.intersects(rect.grow(1.0)):
			return false
	for o in site.floor_holes:
		if o.grow(CityDims.HOLE_CURB + 1.5).intersects(rect):
			return false
	for r: Dictionary in ramps:
		var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
		var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
		if Rect2(float(r["x0"]) - 2.0, s0, float(r["x1"]) - float(r["x0"]) + 4.0, s1 - s0).intersects(rect):
			return false
	return true


## Block bi with its alley `a`: the block is first filled as it would be without one (`normal`), so the plan's generator
## stays in step for every later block, and that fill is thrown away; then the two rows either side of the alley are cut
## into lots and filled from the alley's own generator.
func _fill_alley(bi: int, a: Dictionary, normal: Callable, industrial: bool, pillars_here: Array = []) -> void:
	var nl := lots.size()
	var nb := buildings.size()
	var kind: Variant = blocks[bi]["kind"]
	normal.call()
	lots.resize(nl)
	buildings.resize(nb)
	blocks[bi]["kind"] = kind
	var saved := _rng
	var arng := RandomNumberGenerator.new()
	arng.seed = int(p("seed")) * 104651 + (deck + 2) * 86969 + bi * 7907 + 5
	_rng = arng
	var z: Rect2 = (blocks[bi]["rect"] as Rect2).grow(-SIDEWALK)
	var r: Rect2 = a["rect"]
	var rows: Array[Rect2] = []
	if int(a["axis"]) == 0:
		rows = [Rect2(z.position.x, z.position.y, z.size.x, r.position.y - z.position.y), Rect2(z.position.x, r.end.y, z.size.x, z.end.y - r.end.y)]
	else:
		rows = [Rect2(z.position.x, z.position.y, r.position.x - z.position.x, z.size.y), Rect2(r.end.x, z.position.y, z.end.x - r.end.x, z.size.y)]
	var rects: Array[Rect2] = []
	for row in rows:
		if pillars_here.is_empty():
			_split(row, rects)
		else:
			_carve(row, pillars_here, bi, z, rects)     # the pillar's lot in its row, ending at the alley
	_fill_lots(bi, z, rects, industrial)
	_rng = saved
	alleys.append(a)


## The side of lot li that faces an alley (0:+x 1:-x 2:+s 3:-s), or -1.
func alley_side(li: int) -> int:
	var r: Rect2 = lots[li]["rect"]
	for a: Dictionary in alleys:
		if int(a["block"]) != int(lots[li]["block"]):
			continue
		var q: Rect2 = a["rect"]
		if int(a["axis"]) == 0:
			if absf(r.end.y - q.position.y) < 0.01:
				return 2
			if absf(r.position.y - q.end.y) < 0.01:
				return 3
		else:
			if absf(r.end.x - q.position.x) < 0.01:
				return 0
			if absf(r.position.x - q.end.x) < 0.01:
				return 1
	return -1


# --- Road forms (docs/design/city-variety.md sections 1, 3b) ----------------------------------------------

# A SEGMENT is one stretch of a road between two neighbouring crossings, keyed as RoadForms.seg_key: axis "s" line i
# index j is roads_x[i] between roads_s[j] and roads_s[j + 1]; axis "x" line j index i is roads_s[j] between roads_x[i]
# and roads_x[i + 1] (in section mode these are exactly the section's segments). Its FORM says what is drawn in its strip
# (the strip never moves): street (absent from `forms`), lane (an 8 m one-lane carriageway, the rest of the strip a raised
# planting band each side), pedestrian (paved, no vehicles; the blocks' 0.2 m curbs stay as the one low step) or none (the
# stretch between the crossings raised to the sidewalk as a paved court: the two blocks read as one superblock, entered
# from both crossings across the strip's whole width). In a section the forms are the SectionPlan's; on its own the plan
# rolls them (`road_variety`) from a generator of its own with the same rules.

const BAND_END := 6.0            ## a lane's raised bands stop this far from each crossing (the zebra and stop line stay)
const FORM_MIX := {"lane": 0.20, "pedestrian": 0.10, "none": 0.08}     ## relative shares of the forms (the section's mix)
const CLOSED_PER := 6            ## on its own: at most one pedestrian / none segment per this many blocks


## The form of a segment: street | lane | pedestrian | none.
func seg_form(axis: String, line: int, index: int) -> String:
	return str(forms.get(RoadForms.seg_key(axis, line, index), "street"))


## Vehicles drive the segment (street or lane).
func seg_drives(axis: String, line: int, index: int) -> bool:
	var f := seg_form(axis, line, index)
	return f == "street" or f == "lane"


## The stretch of a segment strictly between its two crossings, in arc coordinates.
func seg_inner(axis: String, line: int, index: int) -> Rect2:
	if axis == "s":
		var r: Dictionary = roads_x[line]
		return Rect2(float(r["a"]), float(roads_s[index]["b"]), float(r["b"]) - float(r["a"]), float(roads_s[index + 1]["a"]) - float(roads_s[index]["b"]))
	var q: Dictionary = roads_s[line]
	return Rect2(float(roads_x[index]["b"]), float(q["a"]), float(roads_x[index + 1]["a"]) - float(roads_x[index]["b"]), float(q["b"]) - float(q["a"]))


## The form of the road beside side `side` of block bi (its edge is exactly one segment's inner stretch).
func block_side_form(bi: int, side: int) -> String:
	if forms.is_empty():
		return "street"
	return str(forms.get(block_side_seg(bi, side), "street"))


## The key (RoadForms.seg_key) of the segment beside side `side` of block bi.
func block_side_seg(bi: int, side: int) -> int:
	var i := int(blocks[bi]["ix"])
	var j := int(blocks[bi]["is"])
	match side:
		0: return RoadForms.seg_key("s", i + 1, j)
		1: return RoadForms.seg_key("s", i, j)
		2: return RoadForms.seg_key("x", j + 1, i)
	return RoadForms.seg_key("x", j, i)


## Section mode: the section's forms (SectionPlan.segments; all `street` while its defaults are dormant).
func _section_forms() -> void:
	for sg: Dictionary in section.segments(deck):
		if str(sg["form"]) != "street":
			forms[RoadForms.seg_key(str(sg["axis"]), int(sg["line"]), int(sg["index"]))] = str(sg["form"])
	_make_raised()


## On its own: about `road_variety` of the minor segments take a form (never the avenue or the edge roads; a superblock
## never joins the park or the civic block); no two parallel neighbours take the same form; then repaired so vehicles
## still reach every crossing they reached (one connected network), every block keeps a vehicle side, and no crossing
## is left with exactly one drawn segment (a stub).
func _roll_forms(special: Dictionary) -> void:
	var share := p("road_variety")
	if share <= 0.0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(p("seed")) * 3266489917 + 668265263
	var nx := roads_x.size()
	var ns := roads_s.size()
	var total := 0.0
	for f: String in FORM_MIX:
		total += float(FORM_MIX[f])
	var cell := {}
	for bi in blocks.size():
		cell[Vector2i(int(blocks[bi]["ix"]), int(blocks[bi]["is"]))] = bi
	for axis: String in ["s", "x"]:
		var lines := nx if axis == "s" else ns
		var count := ns - 1 if axis == "s" else nx - 1
		for line in lines:
			for index in count:
				var roll := rng.randf()
				var which := rng.randf() * total
				if line == 0 or line == lines - 1:
					continue
				if axis == "s" and roads_x[line]["kind"] == "avenue":
					continue
				if roll >= share:
					continue
				var form := "none"
				var acc := 0.0
				for f: String in FORM_MIX:
					acc += float(FORM_MIX[f])
					if which < acc:
						form = f
						break
				if form == "none":
					# Only between two plain blocks (not the park or the civic hall's).
					var a := Vector2i(line - 1, index) if axis == "s" else Vector2i(index, line - 1)
					var b := Vector2i(line, index) if axis == "s" else Vector2i(index, line)
					for c: Vector2i in [a, b]:
						var bi := int(cell.get(c, -1))
						if bi < 0 or bi == int(special["park"]) or bi == int(special["civic"]) or blocks[bi]["kind"] != "built":
							form = "pedestrian"
				# No two parallel neighbours the same form (the segment facing it across a block, on the next line).
				if seg_form(axis, line - 1, index) == form or seg_form(axis, line + 1, index) == form:
					form = "lane" if form != "lane" else "pedestrian"
					if seg_form(axis, line - 1, index) == form or seg_form(axis, line + 1, index) == form:
						continue
				forms[RoadForms.seg_key(axis, line, index)] = form
	# A district on its own is small (about 16 blocks): every closed segment (pedestrian / none) takes the vehicle loop of
	# both blocks beside it (LifeTraffic), so keep at most one closed segment per CLOSED_PER blocks (the last ones rolled
	# go back to streets).
	var keys := forms.keys()
	keys.sort()
	var closed: Array[int] = []
	for k: int in keys:
		if forms[k] == "pedestrian" or forms[k] == "none":
			closed.append(k)
	var cap := maxi(1, blocks.size() / CLOSED_PER)
	while closed.size() > cap:
		forms.erase(closed.pop_back())
	_repair_forms()
	_make_raised()


## Every segment as [axis, line, index, node a, node b] (nodes as in road_graph: i * ns + j).
func _all_segments() -> Array:
	var out := []
	var nx := roads_x.size()
	var ns := roads_s.size()
	for i in nx:
		for j in ns - 1:
			out.append(["s", i, j, i * ns + j, i * ns + j + 1])
	for j in ns:
		for i in nx - 1:
			out.append(["x", j, i, i * ns + j, (i + 1) * ns + j])
	return out


## Greedy, deterministic: turn pedestrian / none segments back into streets until the vehicle network is one piece,
## every block has a vehicle side and no crossing is a stub.
func _repair_forms() -> void:
	var segs := _all_segments()
	var n := roads_x.size() * roads_s.size()
	for guard in 200:
		var parent := PackedInt32Array()
		parent.resize(n)
		for i in n:
			parent[i] = i
		var deg := PackedInt32Array()
		deg.resize(n)
		var drawn := PackedInt32Array()
		drawn.resize(n)
		for sg: Array in segs:
			if seg_drives(sg[0], sg[1], sg[2]):
				RoadForms.uf_join(parent, sg[3], sg[4])
				deg[sg[3]] += 1
				deg[sg[4]] += 1
			if seg_form(sg[0], sg[1], sg[2]) != "none":
				drawn[sg[3]] += 1
				drawn[sg[4]] += 1
		var fix := -1
		# A block with no vehicle side: its first closed side back.
		for bi in blocks.size():
			var ok := false
			for side in 4:
				var f := block_side_form(bi, side)
				ok = ok or f == "street" or f == "lane"
			if not ok:
				for k in segs.size():
					if fix < 0 and _seg_touches_block(segs[k], bi) and not seg_drives(segs[k][0], segs[k][1], segs[k][2]):
						fix = k
				break
		# The vehicle network in more than one piece: the first closed segment joining two pieces.
		if fix < 0:
			var root := -1
			var split := false
			for i in n:
				if deg[i] > 0:
					var r := RoadForms.uf_find(parent, i)
					if root < 0:
						root = r
					elif r != root:
						split = true
			if split:
				for k in segs.size():
					var sg: Array = segs[k]
					if not seg_drives(sg[0], sg[1], sg[2]) and RoadForms.uf_find(parent, sg[3]) != RoadForms.uf_find(parent, sg[4]):
						fix = k
						break
		# A crossing no vehicle reaches (every segment at it closed): its first closed segment back, so the road graph
		# (bots, enemies) has every crossing.
		if fix < 0:
			for k in segs.size():
				var sg: Array = segs[k]
				if not seg_drives(sg[0], sg[1], sg[2]) and (deg[sg[3]] == 0 or deg[sg[4]] == 0):
					fix = k
					break
		# A stub: a crossing with exactly one drawn segment gets a superblock's segment back.
		if fix < 0:
			for k in segs.size():
				var sg: Array = segs[k]
				if seg_form(sg[0], sg[1], sg[2]) == "none" and (drawn[sg[3]] == 1 or drawn[sg[4]] == 1):
					fix = k
					break
		if fix < 0:
			return
		forms.erase(RoadForms.seg_key(segs[fix][0], segs[fix][1], segs[fix][2]))


func _seg_touches_block(sg: Array, bi: int) -> bool:
	var i := int(blocks[bi]["ix"])
	var j := int(blocks[bi]["is"])
	if sg[0] == "s":
		return (int(sg[1]) == i or int(sg[1]) == i + 1) and int(sg[2]) == j
	return (int(sg[1]) == j or int(sg[1]) == j + 1) and int(sg[2]) == i


## The ground the forms raise to the sidewalk (solid, in the checksum): a superblock's court over its segment's inner
## stretch; a lane's two planting bands beside its carriageway, short of the crossings.
func _make_raised() -> void:
	raised.clear()
	var keys := forms.keys()
	keys.sort()
	for k: int in keys:
		var axis := "x" if k >= 65536 else "s"
		var line := (k % 65536) / 256
		var index := k % 256
		var r := seg_inner(axis, line, index)
		match str(forms[k]):
			"none":
				raised.append({"rect": r, "kind": "court", "seg": k})
			"lane":
				var across := 0 if axis == "s" else 1
				var along := 1 - across
				var mid := r.get_center()[across]
				var a0 := r.position[along] + BAND_END
				var a1 := r.end[along] - BAND_END
				if a1 - a0 < 2.0:
					continue
				for side in 2:
					var u0 := r.position[across] if side == 0 else mid + RoadForms.LANE_W * 0.5
					var u1 := mid - RoadForms.LANE_W * 0.5 if side == 0 else r.end[across]
					if u1 - u0 < 0.5:
						continue
					var q := Rect2(u0, a0, u1 - u0, a1 - a0) if across == 0 else Rect2(a0, u0, a1 - a0, u1 - u0)
					raised.append({"rect": q, "kind": "band", "seg": k, "side": side})


# --- Mech sizes the graphs and fit rules use (CityGraphs, MissionProps) --------------------------------------

const MECH_R := 2.2              ## the mech's collision capsule radius (walk_graph / court_open)
## The WIDEST player chassis capsule radius (MechCatalog movement "capsule_radius": the Bulwark's 3.6 m; tests/test_site_fit
## asserts it covers every chassis). Mission objective sites must be reachable by it (SiteFit.snap_fit); the
## layout itself (walk_graph, court_open) still uses MECH_R.
const MECH_R_MAX := 3.6
const WALK_MARGIN := 1.0         ## a walk corridor is at least this much wider than the capsule
const STEP_H := 0.5              ## anything up to this high is stepped onto, not walked round (curbs, courts: 0.2 m)


# --- Checksum --------------------------------------------------------------------------------------------

## Hex digest of everything gameplay in the plan. Equal on two machines = the same district.
func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	for r: Dictionary in roads_x + roads_s:
		PlanHash.put(buf, [r["a"], r["b"]])
		buf.put_utf8_string(str(r["kind"]))
	for b: Dictionary in blocks:
		PlanHash.put_rect(buf, b["rect"])
		buf.put_utf8_string(str(b["kind"]))
	for l: Dictionary in lots:
		PlanHash.put_rect(buf, l["rect"])
		buf.put_utf8_string(str(l["kind"]) + ":" + str(l["open"]))
		buf.put_32(int(l["building"]))
	for b: Dictionary in buildings:
		buf.put_utf8_string(str(b["style"]))
		buf.put_32(int(b["band"]))
		buf.put_32(int(b["floors"]))
		buf.put_32(int(b["front"]))
		PlanHash.put(buf, [b["roof_h"], (b["center"] as Vector2).x, (b["center"] as Vector2).y, (b["size"] as Vector2).x, (b["size"] as Vector2).y])
		for t: Dictionary in b["tiers"]:
			PlanHash.put(buf, [(t["off"] as Vector2).x, (t["off"] as Vector2).y, (t["size"] as Vector2).x, (t["size"] as Vector2).y, t["y0"], t["y1"]])
			buf.put_8(1 if t["stand"] else 0)
			buf.put_utf8_string(str(t.get("kind", "")))
		for so: Dictionary in b["solids"]:
			buf.put_utf8_string(str(so["kind"]))
			PlanHash.put(buf, [(so["off"] as Vector2).x, (so["off"] as Vector2).y, (so["size"] as Vector2).x, (so["size"] as Vector2).y, so["y0"], so["y1"]])
		if b.has("gable"):
			var g: Dictionary = b["gable"]
			PlanHash.put(buf, [(g["off"] as Vector2).x, (g["off"] as Vector2).y, g["w"], g["d"], g["y0"], g["rise"], g["front"]])
		if b["pillar"]:
			PlanHash.put(buf, [b["core"]["x"], b["core"]["s"], (b["core"]["size"] as Vector2).x, (b["core"]["size"] as Vector2).y])
		if b.has("base"):     # downtown only: a plan without a zone hashes exactly as before
			buf.put_utf8_string("base:" + str(b["base"]))
	var zone := ""
	for bi in blocks.size():
		if blocks[bi].get("downtown", false):
			zone += str(bi) + ","
	if zone != "":
		buf.put_utf8_string("downtown:" + zone)
	# City variety: only when there is any, so a plan without alleys or forms hashes exactly as before.
	for a: Dictionary in alleys:
		buf.put_utf8_string("alley:%d:%d" % [int(a["block"]), int(a["axis"])])
		PlanHash.put_rect(buf, a["rect"])
	var keys := forms.keys()
	keys.sort()
	for k: int in keys:
		buf.put_utf8_string("form:%d:%s" % [k, str(forms[k])])
	for q: Dictionary in raised:
		buf.put_utf8_string("raised:" + str(q["kind"]))
		PlanHash.put_rect(buf, q["rect"])
	for c: Dictionary in columns:
		PlanHash.put(buf, [c["x"], c["s"], c["half"], c["ring_r"], c["ring_h"]])
	site.put(buf)
	PlanHash.put(buf, [p("radius"), p("ceiling"), p("clearance"), p("walls")])
	if section != null:
		buf.put_utf8_string(section.checksum())
		buf.put_32(deck)
		for b: Dictionary in blocks:
			buf.put_utf8_string(str(b["zone"]))
		for o: Rect2 in site.floor_holes:
			PlanHash.put_rect(buf, o)
		for r: Dictionary in ramps:
			buf.put_32(int(r["connector"]))
			buf.put_utf8_string(str(r["role"]))
			PlanHash.put(buf, [r["x0"], r["x1"], r["s_top"], r["s_foot"], r["h_top"], r["h_foot"]])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)
