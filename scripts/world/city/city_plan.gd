class_name CityPlan
extends RefCounted
## The layout of one urban district on a ring deck, as plain data (no nodes): street grid -> blocks -> lots -> buildings.
## Everything here is GAMEPLAY geometry (what you walk on, stand on and hide behind), generated from `params` alone with
## one seeded generator, so every machine builds the same district and `checksum()` proves it (AGENTS.md rule 4, game
## design 3.5). Looks that don't affect play (window patterns, colours, fixed street furniture) are rolled later by the
## meshers from `cosmetic_seed()`, a separate stream, and are not in the checksum. Skylights, the office plant room and
## the civic portico are solid, so they are plan data here; loose roof units are CityProps (CityProps.layout).
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
## Sides are numbered 0:+x 1:-x 2:+s 3:-s.

const FLOOR_H := 3.25        ## storey height (m)
const SIDEWALK := 4.0        ## curb to building line (m)
const CURB_H := 0.2
const STREET_W := 12.0       ## two lanes + two parking strips
const AVENUE_W := 20.0       ## four lanes + median
const LOT_MAX := 26.0
const LOT_MIN := 11.0
const PILLAR_APRON := 4.0    ## a pillar tower's lot reaches this far past its structural core
const STYLES := ["apartment", "office", "sage", "shops", "civic", "pillar"]
const BANDS := {"apartment": [1, 3], "office": [2, 4], "sage": [1, 3], "shops": [0, 0], "civic": [1, 1], "pillar": [1, 1]}
const SIDE_N: Array[Vector2] = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
const SIDE_EDGE: Array[String] = ["x1", "x0", "s1", "s0"]     ## the section's name for each side's wall
const ZONE_KIND := {"urban": "built", "park": "park", "industrial": "industrial", "transit": "transit", "open": "open"}

const DEFAULTS := {
	"seed": 1.0, "size_x": 220.0, "size_s": 240.0, "block": 44.0, "density": 0.9, "height": 0.5,
	"band_step": 6.5, "ceiling": 40.0, "clearance": 12.0, "pillar_bay": 90.0, "atrium": 0.0, "walls": 0.0, "jump_gap": 6.0,
	"radius": 300.0,
	"w_apartment": 1.0, "w_office": 1.0, "w_sage": 1.0, "w_shops": 0.8,
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

var _rng := RandomNumberGenerator.new()


func net_fields() -> Dictionary:
	return {
		"params": Net.SPAWN,     # the mission seed and generator settings: all that crosses the wire
		"roads_x": Net.LOCAL, "roads_s": Net.LOCAL, "blocks": Net.LOCAL, "lots": Net.LOCAL, "buildings": Net.LOCAL,
		"columns": Net.LOCAL, "dropped_pillars": Net.LOCAL,
		"site": Net.SPAWN,       # the section's structure (pillars, openings): derived from the section seed
		"section": Net.SPAWN, "deck": Net.SPAWN,     # the section is planned from its own seed on every machine
		"ramps": Net.LOCAL,      # from the section's connectors, verified by checksum()
		"extent": Net.LOCAL,     # recomputed from params on every machine, verified by checksum()
		"_rng": Net.LOCAL,
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


func generate(overrides: Dictionary = {}, given: CitySite = null) -> void:
	params = DEFAULTS.duplicate()
	for k: String in overrides:
		if params.has(k):
			params[k] = float(overrides[k])
	roads_x.clear()
	roads_s.clear()
	blocks.clear()
	lots.clear()
	buildings.clear()
	columns.clear()
	dropped_pillars = 0
	ramps.clear()
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
	for bi in blocks.size():
		_fill_block(bi, special, by_block.get(bi, []))
	_finish()


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
	roads_x.clear()
	roads_s.clear()
	blocks.clear()
	lots.clear()
	buildings.clear()
	columns.clear()
	ramps.clear()
	dropped_pillars = 0
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
	var cut: Array[Rect2] = []
	for o in site.floor_holes:
		cut.append_array(_bridged(o))
	site.floor_holes = cut
	_make_ramps()
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
	for bi in blocks.size():
		_fill_zone(bi, by_block.get(bi, []))
	_finish()


func _finish() -> void:
	for i in buildings.size():
		_shape_building(i)
	_make_jumpable()
	for i in buildings.size():
		_build_tiers(i)


## A ramp's cut runs down a spine lane and so crosses the cross roads: they bridge it, so the floor is only cut
## between them.
func _bridged(o: Rect2) -> Array[Rect2]:
	var bridges: Array[Rect2] = []
	for road: Dictionary in roads_s:
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
		if o.grow(CityStreets.HOLE_CURB + 0.1).has_point(pt):
			return false
	for k in site.keep_clear:
		if k.has_point(pt):
			return false
	return true


# --- Streets ---------------------------------------------------------------------------------------------

## One axis of the grid: a centre road, then blocks and streets outward on both sides, ending with a perimeter street.
func _axis(half: float, centre_w: float, centre_kind: String, barred: Array) -> Dictionary:
	var block := p("block")
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
	_add_building(li, "pillar")
	var b: Dictionary = buildings[buildings.size() - 1]
	b["pillar"] = true
	b["band"] = 1
	b["setback"] = 0.5
	b["core"] = {"x": q["x"], "s": q["s"], "half": float(q["half"]), "kind": q["kind"], "size": Vector2.ZERO}
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
			if b["core"]["kind"] != "lift":      # a lift pillar stands bare in its plaza: the doors need the room
				tiers.append(_tier(Vector2.ZERO, size, 0.0, roof, true))
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
## geometry (_skylights); the other kinds (tank, ac, vent, planter) are knockable CityProps (CityProps.layout).
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


## The edge of the map: one entry per side, [{side, kind: bulkhead | window, at, backdrop, gates: [{a, b, h, kind:
## blast_door | portal | collapsed}]}], gate a..b along the wall (x on an arc-end wall, s on a side wall). In a section
## they are the section's walls (always on); on its own the district is open unless `walls` asks for them, and then the
## two ends across the arc are bulkheads with a sealed gate wherever a road reaches them and the two sides are the
## habitat's hull, a window wall with no backdrop behind it.
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


# --- Roads as a graph ------------------------------------------------------------------------------------

## Road centre-line graph: a node at every crossing, an edge along every road between neighbouring crossings.
## Returns {nodes: [Vector2], edges: [[i, j]]}.
func road_graph() -> Dictionary:
	var nodes: Array[Vector2] = []
	var edges := []
	var nx := roads_x.size()
	var ns := roads_s.size()
	for i in nx:
		for j in ns:
			nodes.append(Vector2((float(roads_x[i]["a"]) + float(roads_x[i]["b"])) * 0.5,
					(float(roads_s[j]["a"]) + float(roads_s[j]["b"])) * 0.5))
	for i in nx:
		for j in ns:
			if j + 1 < ns:
				edges.append([i * ns + j, i * ns + j + 1])
			if i + 1 < nx:
				edges.append([i * ns + j, (i + 1) * ns + j])
	return {"nodes": nodes, "edges": edges}


# --- Checksum --------------------------------------------------------------------------------------------

## Hex digest of everything gameplay in the plan. Equal on two machines = the same district.
func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	for r: Dictionary in roads_x + roads_s:
		_put(buf, [r["a"], r["b"]])
		buf.put_utf8_string(str(r["kind"]))
	for b: Dictionary in blocks:
		_put_rect(buf, b["rect"])
		buf.put_utf8_string(str(b["kind"]))
	for l: Dictionary in lots:
		_put_rect(buf, l["rect"])
		buf.put_utf8_string(str(l["kind"]) + ":" + str(l["open"]))
		buf.put_32(int(l["building"]))
	for b: Dictionary in buildings:
		buf.put_utf8_string(str(b["style"]))
		buf.put_32(int(b["band"]))
		buf.put_32(int(b["floors"]))
		buf.put_32(int(b["front"]))
		_put(buf, [b["roof_h"], (b["center"] as Vector2).x, (b["center"] as Vector2).y, (b["size"] as Vector2).x, (b["size"] as Vector2).y])
		for t: Dictionary in b["tiers"]:
			_put(buf, [(t["off"] as Vector2).x, (t["off"] as Vector2).y, (t["size"] as Vector2).x, (t["size"] as Vector2).y, t["y0"], t["y1"]])
			buf.put_8(1 if t["stand"] else 0)
			buf.put_utf8_string(str(t.get("kind", "")))
		for so: Dictionary in b["solids"]:
			buf.put_utf8_string(str(so["kind"]))
			_put(buf, [(so["off"] as Vector2).x, (so["off"] as Vector2).y, (so["size"] as Vector2).x, (so["size"] as Vector2).y, so["y0"], so["y1"]])
		if b.has("gable"):
			var g: Dictionary = b["gable"]
			_put(buf, [(g["off"] as Vector2).x, (g["off"] as Vector2).y, g["w"], g["d"], g["y0"], g["rise"], g["front"]])
		if b["pillar"]:
			_put(buf, [b["core"]["x"], b["core"]["s"], (b["core"]["size"] as Vector2).x, (b["core"]["size"] as Vector2).y])
	for c: Dictionary in columns:
		_put(buf, [c["x"], c["s"], c["half"], c["ring_r"], c["ring_h"]])
	site.put(buf)
	_put(buf, [p("radius"), p("ceiling"), p("clearance"), p("walls")])
	if section != null:
		buf.put_utf8_string(section.checksum())
		buf.put_32(deck)
		for b: Dictionary in blocks:
			buf.put_utf8_string(str(b["zone"]))
		for o: Rect2 in site.floor_holes:
			_put_rect(buf, o)
		for r: Dictionary in ramps:
			buf.put_32(int(r["connector"]))
			buf.put_utf8_string(str(r["role"]))
			_put(buf, [r["x0"], r["x1"], r["s_top"], r["s_foot"], r["h_top"], r["h_foot"]])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))     # millimetres: immune to float formatting


func _put_rect(buf: StreamPeerBuffer, r: Rect2) -> void:
	_put(buf, [r.position.x, r.position.y, r.size.x, r.size.y])
