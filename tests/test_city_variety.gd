extends TestCase
## City variety (docs/design/city-variety.md): building looks (part A), service alleys (part B), the road forms drawn
## from the SectionPlan and the stand-alone roll (part C).
##   A: the looks pass changes no plan, props layout or collision (numbers captured from the code before it, 2026-11-23,
##      with alleys and stand-alone road forms off, which is exactly the plan before variety).
##   B: alleys: width at a mech's top, two open ends, rows either side, never where they may not be, no corridors, the
##      real mech capsule walks every alley of several plans, nobody's route runs through one.
##   Graphs: CityPlan.walk_graph() (mechs, enemies, bots) vs road_graph() (vehicles).
## 2026-11-23 (forms live): Missions switched the SectionPlan road forms on by default (f_lane 0.20, f_pedestrian 0.15,
## f_none 0.08). The part A / "dormant" pins are about plans with the forms OFF, so they now build their sections with the
## forms explicitly off (FORMS_OFF: every pinned value held unchanged that way); the default (forms live) plans get pins of
## their own (LIVE_*), captured 2026-11-23.

const MECH_R := 2.2
const MECH_H := 8.0
const OFF := {"alleys": 0.0, "road_variety": 0.0}
const FORMS_OFF := {"f_lane": 0.0, "f_pedestrian": 0.0, "f_none": 0.0}
## Captured before the variety work (HEAD 948ec3e + lab cameras only).
const OLD_ALONE := {1: "209989488eaa0e52", 2: "a68346ecb68daa6a", 3: "73fe80791493b23f"}
const OLD_WALLS_1 := "e4ec580da1956459"
const OLD_PROPS_1 := "7e78d4e1e3db1a61"
## Re-captured 2026-11-23 (downtown pass 2: denser zones move the decks that have one; alleys stay off here). Was 1/0
## 92a3d4bb372dd86f, 1/2 786ca59d1bee770a, 4/1 2925158a146c945d, 4/2 3c79a9e486258d7e.
const OLD_SECTION := {"1/0": "b56cf7ca1dc507da", "1/1": "5623a329a48debcb", "1/2": "023feee926d72a33",
		"4/0": "3cc51e61b1918548", "4/1": "935eb4ebb35a9945", "4/2": "6d43a4e862b20439"}
## Recaptured 2026-11-23 (map sealed: a portal's recess gets a back plate, CityDistrict._col_walls): section 4 deck 0 has
## a portal, so one shape more; with the plates left out it is exactly the old capture (PRE_PLATE_4_0, asserted in part A).
## Was "4/0": [1431, 214513608]; LIVE_COLLISION_4_0 was [1439, 2766744305].
## Recaptured 2026-11-26 (ramp-end collision, tests/test_ramp_stuck.gd: parapets as prisms ending square to the deck, end
## blocks CityDistrict.END_GUARD tall; same shape count). Was "4/0" [1432, 4221422576], PRE_PLATE_4_0 [1431, 214513608],
## LIVE_COLLISION_4_0 [1440, 1007613211].
const OLD_COLLISION := {"alone/1": [420, 3589553106], "4/0": [1432, 488446493]}
const PRE_PLATE_4_0 := [1431, 3909610205]
## The same decks with the section's DEFAULT road forms (live), alleys off: captured 2026-11-23 (forms live).
const LIVE_SECTION := {"1/0": "05a41d02d7e663dc", "1/1": "f94db9991bff3b73", "1/2": "66e58606d4bbe979",
		"4/0": "93d0af293cbfd45c", "4/1": "531d6817a20610db", "4/2": "7122f53dca9b5d32"}
## Section 4 deck 0, alleys off, forms live: 8 more boxes than OLD_COLLISION["4/0"] (its courts' / bands' raised ground).
const LIVE_COLLISION_4_0 := [1440, 3940746585]


## Section seed s with its road forms explicitly off (every segment a street: the plan before part C).
static func _sec_off(s: int) -> SectionPlan:
	var p := FORMS_OFF.duplicate()
	p["seed"] = s
	return SectionPlan.make(p)


func setup() -> void:
	timeout_sec = 300.0
	await _part_a()
	_alley_rules()
	await _alley_walk_alone(1)
	await _alley_walk_alone(2)
	await _alley_walk_alone(5)
	await _alley_walk_section(4, 0)
	await _alley_walk_section(1, 1)       # pass 2: pillar-side alleys on section decks
	await _alley_walk_section(12, 2)
	_alley_routes()
	await _forms_dormant()
	_forms_graphs()
	_forms_alone()
	for s in [2, 4, 7]:
		_forms_pockets(CityPlan.for_deck(SectionPlan.make(_mix(s)), 0), "section %d deck 0 (forms)" % s)
		_forms_pockets(CityPlan.for_deck(SectionPlan.make(_mix(s)), 1), "section %d deck 1 (forms)" % s)
	for s in [1, 3, 6]:
		_forms_pockets(CityPlan.make({"seed": s}), "alone %d" % s)
	_forms_life()
	await _forms_built(4)
	_walk_rules()
	await _walk_built()
	finish()


# --- Part A ----------------------------------------------------------------------------------------------

func _part_a() -> void:
	for s: int in OLD_ALONE:
		var o := OFF.duplicate()
		o["seed"] = s
		eq(CityPlan.make(o).checksum(), OLD_ALONE[s], "A: alone seed %d plan unchanged by the looks pass" % s)
	var w := OFF.duplicate()
	w["seed"] = 1
	eq(CityProps.layout_checksum(CityProps.layout(CityPlan.make(w))), OLD_PROPS_1, "A: alone seed 1 props layout unchanged")
	w["walls"] = 1.0
	eq(CityPlan.make(w).checksum(), OLD_WALLS_1, "A: alone seed 1 walled plan unchanged")
	for key: String in OLD_SECTION:
		var sk := key.split("/")
		# 2026-11-23 (forms live): was SectionPlan.make({"seed": n}) while the defaults were dormant; now explicitly off.
		eq(CityPlan.for_deck(_sec_off(int(sk[0])), int(sk[1]), {"alleys": 0.0}).checksum(), OLD_SECTION[key],
				"A: section %s plan unchanged by the looks pass (alleys off, forms off)" % key)
		eq(CityPlan.for_deck(SectionPlan.make({"seed": int(sk[0])}), int(sk[1]), {"alleys": 0.0}).checksum(), LIVE_SECTION[key],
				"A: section %s default plan (forms live, alleys off) as captured" % key)
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	var o1 := OFF.duplicate()
	o1["seed"] = 1
	d.build(o1)
	eq(_col(d), OLD_COLLISION["alone/1"], "A: alone seed 1 collision unchanged")
	d.queue_free()
	var e := CityDistrict.new()
	e.with_rig = false
	add_child(e)
	e.build_deck(_sec_off(4), 0, {"alleys": 0.0})
	eq(_col(e), OLD_COLLISION["4/0"], "A: section 4 deck 0 collision unchanged (forms off)")
	var pre := _col(e, true)
	eq([pre[0], pre[1]], PRE_PLATE_4_0, "A: section 4 deck 0 without its portal back plates: the collision before the map was sealed")
	eq(pre[2], 1, "A: section 4 deck 0: one portal, one back plate")
	e.queue_free()
	var e2 := CityDistrict.new()
	e2.with_rig = false
	add_child(e2)
	e2.build_deck(SectionPlan.make({"seed": 4}), 0, {"alleys": 0.0})
	eq(_col(e2), LIVE_COLLISION_4_0, "A: section 4 deck 0 collision with the default (live) forms as captured")
	e2.queue_free()
	await frames(1)
	# The tint stays a small shift inside the palette family.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for id: String in ["terracotta", "cream", "sage", "sky_blue", "sand", "apt_sky"]:
		var c := CityPalette.c(id)
		for k in 40:
			var t := CityPalette.tint(c, rng)
			var dh := absf(t.h - c.h)
			check(minf(dh, 1.0 - dh) <= 0.0141 and absf(t.v / c.v - 1.0) <= 0.0701, "A: tint of %s stays close (%s)" % [id, t.to_html(false)])


## [shape count, hash]; with `skip_plates`, [count, hash, plates] leaving out the portal back plates (a box
## PORTAL_PLATE + 0.1 thick across the arc, more than GATE_RECESS - 0.5 m past an end of the extent).
func _col(d: CityDistrict, skip_plates: bool = false) -> Array:
	var h := 0
	var n := 0
	var plates := 0
	var e := d.plan.extent
	var col := d.get_node("Collision")
	for c in col.get_children():
		var cs := c as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else (cs.shape as ConvexPolygonShape3D).points
		if skip_plates and sz is Vector3 and absf((sz as Vector3).z - (CityDistrict.PORTAL_PLATE + 0.1)) < 0.001:
			var s := d.ring.world_to_arc(cs.transform.origin).y
			if s > e.end.y + CityWalls.GATE_RECESS - 0.5 or s < e.position.y - CityWalls.GATE_RECESS + 0.5:
				plates += 1
				continue
		h = hash([h, cs.transform, sz])
		n += 1
	return [n, h, plates] if skip_plates else [n, h]


# --- Part B: alleys --------------------------------------------------------------------------------------

func _plans() -> Array[CityPlan]:
	var out: Array[CityPlan] = []
	for s in range(1, 13):
		out.append(CityPlan.make({"seed": s}))
	for s in range(1, 9):
		var sec := SectionPlan.make({"seed": s})
		for k in sec.deck_count:
			out.append(CityPlan.for_deck(sec, k))
	return out


func _alley_rules() -> void:
	var total := 0
	var eligible := 0
	var alone := 0
	var pillar_side := 0
	var section_decks := 0
	var section_alleys := 0
	var per_deck := []
	for plan in _plans():
		if plan.section != null:
			section_decks += 1
			section_alleys += plan.alleys.size()
			per_deck.append(plan.alleys.size())
		var tag := "section %d deck %d" % [int(plan.p("seed")), plan.deck] if plan.section != null else "alone %d" % int(plan.p("seed"))
		var r_ := plan.p("radius")
		var lined := 0
		for bi in plan.blocks.size():
			var b: Dictionary = plan.blocks[bi]
			if plan.section == null:
				eligible += 1 if b["kind"] == "built" else 0
			else:
				eligible += 1 if (b["zone"] == "urban" or b["zone"] == "industrial") else 0
		for a: Dictionary in plan.alleys:
			total += 1
			alone += 1 if plan.section == null else 0
			var bi := int(a["block"])
			var b: Dictionary = plan.blocks[bi]
			var r: Rect2 = a["rect"]
			var along := int(a["axis"])
			var z: Rect2 = (b["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
			var at := "%s alley in block %d" % [tag, bi]
			check((b["kind"] == "built" or b["kind"] == "industrial") and not b.get("downtown", false), at + ": in a plain built block")
			check(absf(r.position[along] - z.position[along]) < 0.01 and absf(r.end[along] - z.end[along]) < 0.01,
					at + ": runs from building line to building line (two open ends)")
			check(r.position[1 - along] - z.position[1 - along] >= CityPlan.ALLEY_ROW - 0.01 and z.end[1 - along] - r.end[1 - along] >= CityPlan.ALLEY_ROW - 0.01,
					at + ": a lot row at least %.0f m deep either side" % CityPlan.ALLEY_ROW)
			for o in plan.site.floor_holes:
				check(not o.intersects(r), at + ": not over a floor hole")
			for k in plan.site.keep_clear:
				check(not k.intersects(r), at + ": not on ground kept clear")
			for i in plan.buildings_in(bi):
				# Pass 2 (2026-11-23): a pillar block takes its alley beside the core (the pillar's podium may be one wall).
				if plan.buildings[i]["pillar"]:
					pillar_side += 1
					var cs: Vector2 = plan.buildings[i]["core"]["size"]
					var core := Rect2(Vector2(plan.buildings[i]["core"]["x"], plan.buildings[i]["core"]["s"]) - cs * 0.5, cs)
					check(not core.grow(CityPlan.ALLEY_PILLAR - 0.01).intersects(r), at + ": clear of the pillar's core")
				for t: Dictionary in plan.buildings[i]["tiers"]:
					check(not plan.tier_rect(i, t).intersects(r), at + ": no building footprint in it")
			# Clear width between the faces either side at a mech's top (walls across the arc lean together).
			var lo := -INF
			var hi := INF
			for i in plan.buildings_in(bi):
				var bc: Vector2 = plan.buildings[i]["center"]
				for t: Dictionary in plan.buildings[i]["tiers"]:
					if float(t["y1"]) < MECH_H * 0.5 or float(t["y0"]) > MECH_H:
						continue
					var h := minf(float(t["y1"]), MECH_H)
					var off: Vector2 = t["off"]
					var sz: Vector2 = t["size"]
					var a0: float
					var a1: float
					if along == 0:
						var k := r_ / (r_ - h)
						a0 = bc.y + (off.y - sz.y * 0.5) * k
						a1 = bc.y + (off.y + sz.y * 0.5) * k
					else:
						a0 = bc.x + off.x - sz.x * 0.5
						a1 = bc.x + off.x + sz.x * 0.5
					var mid := r.get_center()[1 - along]
					if a1 <= mid:
						lo = maxf(lo, a1)
					elif a0 >= mid:
						hi = minf(hi, a0)
			var gap := (hi - lo) * ((r_ - MECH_H) / r_ if along == 0 else 1.0)
			check(gap >= CityPlan.ALLEY_W - 0.01, at + ": %.2f m clear between the walls at %.0f m (>= %.0f)" % [gap, MECH_H, CityPlan.ALLEY_W])
			for a2: Dictionary in plan.alleys:
				var b2: Dictionary = plan.blocks[int(a2["block"])]
				var step := Vector2i(1, 0) if along == 0 else Vector2i(0, 1)
				var dc := Vector2i(int(b2["ix"]) - int(b["ix"]), int(b2["is"]) - int(b["is"]))
				if int(a2["axis"]) == along and dc == step:
					var q: Rect2 = a2["rect"]
					if minf(q.end[1 - along], r.end[1 - along]) - maxf(q.position[1 - along], r.position[1 - along]) > -2.0:
						lined += 1
		check(lined <= CityPlan.ALLEY_CORRIDOR, "%s: at most %d alley corridor (%d)" % [tag, CityPlan.ALLEY_CORRIDOR, lined])
	print("alleys: %d over %d eligible blocks (%d in stand-alone districts); section decks %s (%d over %d decks, %d beside a pillar)"
			% [total, eligible, alone, per_deck, section_alleys, section_decks, pillar_side])
	check(alone >= 12, "stand-alone districts get alleys (%d over 12 seeds)" % alone)
	# Pass 2: the game plays on section decks: alleys there too (about a third of the eligible blocks), mostly beside a pillar.
	check(float(section_alleys) / float(section_decks) >= 1.0, "section decks get alleys (%d over %d decks)" % [section_alleys, section_decks])
	check(pillar_side * 2 >= section_alleys, "section alleys run beside pillars (%d of %d)" % [pillar_side, section_alleys])
	var none := CityPlan.make({"seed": 3, "alleys": 0.0})
	eq(none.alleys.size(), 0, "alleys 0: none")


## The mech capsule (radius 2.2, 8 m) down the middle of every alley, sidewalk to sidewalk, touches no collision; at 8 m
## up the walls either side are 7 m apart or more.
func _walk_alleys(d: CityDistrict, tag: String) -> void:
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = MECH_R
	shape.height = MECH_H
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	var body := d.get_node("Collision")
	var walked := 0
	for a: Dictionary in d.plan.alleys:
		var r: Rect2 = a["rect"]
		var along := int(a["axis"])
		var c := r.get_center()
		var t := r.position[along] - 3.0
		var hits := 0
		var narrow := 99.0
		while t <= r.end[along] + 3.0:
			var p := c
			p[along] = t
			var h := CityPlan.CURB_H + 0.3 + MECH_H * 0.5
			q.transform = d.global_transform * Transform3D(CityGeo.frame_basis(d.ring, p.y), d.ring.arc_to_world(p.x, p.y, h))
			for hit: Dictionary in space.intersect_shape(q, 8):
				if hit["collider"] == body:
					hits += 1
			if t > r.position[along] + 2.0 and t < r.end[along] - 2.0:
				var w := 0.0
				for sgn: float in [-1.0, 1.0]:
					var o := p
					o[1 - along] += sgn * 12.0
					var a3 := d.global_transform * d.ring.arc_to_world(p.x, p.y, MECH_H)
					var b3 := d.global_transform * d.ring.arc_to_world(o.x, o.y, MECH_H)
					var rq := PhysicsRayQueryParameters3D.create(a3, b3)
					var res := space.intersect_ray(rq)
					w += a3.distance_to(res["position"]) if not res.is_empty() else 12.0
				narrow = minf(narrow, w)
			t += 1.0
			walked += 1
		check(hits == 0, "%s alley in block %d: the mech capsule walks it end to end (%d contacts)" % [tag, a["block"], hits])
		check(narrow >= CityPlan.ALLEY_W - 0.01, "%s alley in block %d: %.2f m wall to wall at 8 m" % [tag, a["block"], narrow])
	print("%s: %d alleys walked (%d capsule samples)" % [tag, d.plan.alleys.size(), walked])


func _alley_walk_alone(s: int) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": s})
	await _walk_alleys(d, "alone %d" % s)
	d.queue_free()


func _alley_walk_section(s: int, k: int) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build_deck(SectionPlan.make({"seed": s}), k)
	var beside := 0
	for a: Dictionary in d.plan.alleys:
		for i in d.plan.buildings_in(int(a["block"])):
			beside += 1 if d.plan.buildings[i]["pillar"] else 0
	check(beside > 0, "section %d deck %d: an alley beside a pillar to walk" % [s, k])
	await _walk_alleys(d, "section %d deck %d" % [s, k])
	d.queue_free()


## No walker's graph node or edge, no vehicle lap runs through an alley (v1: alleys are not routes).
func _alley_routes() -> void:
	# Pass 2 (2026-11-23): also two section decks with alleys beside pillars (ids 101.. / 112..: section seed 1 deck 1,
	# section 12 deck 2).
	var cases: Array = [[1, CityPlan.make({"seed": 1})], [2, CityPlan.make({"seed": 2})], [5, CityPlan.make({"seed": 5})],
			[101, CityPlan.for_deck(SectionPlan.make({"seed": 1}), 1)], [122, CityPlan.for_deck(SectionPlan.make({"seed": 12}), 2)]]
	for cs: Array in cases:
		var s: int = cs[0]
		var plan: CityPlan = cs[1]
		var lp := LifePlan.make(plan)
		var tr := LifeTraffic.make(lp)
		for a: Dictionary in plan.alleys:
			var r: Rect2 = (a["rect"] as Rect2).grow(-0.5)
			var rs: Array[Rect2] = [r]
			var bad := 0
			for e: Array in lp.edges:
				if LifePlan._hits(rs, lp.nodes[int(e[0])], lp.nodes[int(e[1])]):
					bad += 1
			eq(bad, 0, "alone %d alley in block %d: no walkway edge through it" % [s, a["block"]])
			var vb := 0
			for lo: Dictionary in tr.loops:
				for pt: Vector2 in lo["pts"]:
					vb += 1 if r.has_point(pt) else 0
			eq(vb, 0, "alone %d alley in block %d: no vehicle lap through it" % [s, a["block"]])


# --- Part C: road forms ----------------------------------------------------------------------------------

## Re-captured 2026-11-23 (downtown pass 2: denser zones, new tower looks, alleys beside pillars). Was 1/0 [117826459,
## 287867], 4/1 [4137878908, 344416].
const DORMANT := {"1/0": [798130471, 267705], "4/1": [1892246101, 331864]}     ## digest, triangles after parts A + B
## The same decks with the section's default (live) forms: captured 2026-11-23 (forms live; 1/0 has 4 form segments, 4/1 2).
const LIVE_DRAWN := {"1/0": [1345323907, 271361], "4/1": [2971505345, 331222]}


static func _mix(s: int) -> Dictionary:
	return {"seed": s, "f_lane": 0.20, "f_pedestrian": 0.10, "f_none": 0.08}


## With the section's forms off (every segment a street) the city draws exactly what it drew before part C.
## 2026-11-23 (forms live): "off" is now the explicit zero mix (it was the defaults while they were dormant); the default
## plans are checked to carry forms and pinned as drawn (LIVE_DRAWN).
func _forms_dormant() -> void:
	var live_forms := 0
	for key: String in DORMANT:
		var sk := key.split("/")
		var sec := SectionPlan.make({"seed": int(sk[0])})
		var zero := _sec_off(int(sk[0]))
		var plan := CityPlan.for_deck(zero, int(sk[1]))
		check(plan.forms.is_empty() and plan.raised.is_empty(), "C: section %s: no forms while the section's are off" % key)
		live_forms += CityPlan.for_deck(sec, int(sk[1])).forms.size()
		var d := CityDistrict.new()
		d.with_rig = false
		add_child(d)
		d.build_deck(zero, int(sk[1]))
		eq([d.geometry_digest(), int(d.stats["triangles"])], DORMANT[key], "C: section %s (forms off): digest and triangles identical to before part C" % key)
		check(d.get_node_or_null("StringLights") == null, "C: section %s (forms off): no string lights" % key)
		d.queue_free()
		var l := CityDistrict.new()
		l.with_rig = false
		add_child(l)
		l.build_deck(sec, int(sk[1]))
		eq([l.geometry_digest(), int(l.stats["triangles"])], LIVE_DRAWN[key], "C: section %s (default forms, live): digest and triangles as captured" % key)
		l.queue_free()
		await frames(1)
	check(live_forms > 0, "C: the default section plans carry road forms (live since 2026-11-23): %d segments" % live_forms)


## The ramp-foot segments over section seeds 1-20 (with _mix) that the built collision leaves OPEN (probed 2026-11-23,
## tools/city_downtown/foot_probe.gd: the 8 m capsule crosses the ramp lane +-3 m on 2-3 parallel lines on the toe side of
## the foot line): "seed/deck/line/index". All 20 foot segments are open, so the city graph keeps them all; Missions fixes
## the plan side. seed 1-20 lines: deck 1 cross line 2, deck 2 cross line 4.
const FOOT_OPEN := ["1/1/2/0", "2/1/2/0", "3/2/4/2", "4/1/2/1", "4/2/4/2", "5/1/2/0", "6/2/4/2", "7/2/4/2", "8/1/2/0", "9/1/2/0",
		"10/2/4/1", "11/1/2/1", "12/1/2/1", "13/2/4/1", "14/2/4/2", "15/1/2/0", "16/1/2/0", "17/2/4/1", "18/1/2/0", "18/2/4/1", "19/1/2/0",
		"20/1/2/1", "20/2/4/2"]


## CityPlan.road_graph() (bots, enemies) drops exactly the segments SectionPlan.road_graph() drops; the one other
## difference is a ramp's foot ("foot" segments: the section keeps vehicles off the cross road where a ramp comes down,
## the city graph keeps that road for walkers).
## The number of connected components of a road graph's edges (nodes with no edge left out).
static func _components(g: Dictionary) -> int:
	var adj := {}
	for ed: Array in g["edges"]:
		(adj.get_or_add(int(ed[0]), []) as Array).append(int(ed[1]))
		(adj.get_or_add(int(ed[1]), []) as Array).append(int(ed[0]))
	var seen := {}
	var n := 0
	for start: int in adj:
		if seen.has(start):
			continue
		n += 1
		var stack: Array[int] = [start]
		seen[start] = true
		while not stack.is_empty():
			for j: int in adj[stack.pop_back()]:
				if not seen.has(j):
					seen[j] = true
					stack.append(j)
	return n


func _forms_graphs() -> void:
	# 2026-11-23 (downtown pass 2): CityPlan.road_graph() is one connected network on every deck, with and without the
	# section's road forms (alleys, downtown lots and ramp-foot segments never split it).
	# 2026-11-23 (forms live): three variants now, forms off / the defaults (live) / the test's mix (was: defaults, then
	# dormant, and the mix).
	for s in range(1, 21):
		for variant in ["off", "default", "mix"]:
			var sec2: SectionPlan = _sec_off(s) if variant == "off" else (SectionPlan.make({"seed": s}) if variant == "default" else SectionPlan.make(_mix(s)))
			for k in sec2.deck_count:
				var n := _components(CityGraphs.road_graph(CityPlan.for_deck(sec2, k)))
				eq(n, 1, "C: section %d deck %d (%s forms): the city road graph is one connected network" % [s, k, variant])
	var decks := 0
	var dropped := 0
	var foot := 0
	var isolated := 0
	for s in range(1, 21):
		var sec := SectionPlan.make(_mix(s))
		var adj := sec.road_graph(true)
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var ns := plan.roads_s.size()
			var g := CityGraphs.road_graph(plan)
			var city := {}
			for ed: Array in g["edges"]:
				var a := int(ed[0])
				var b := int(ed[1])
				var na := sec.node_id(k, a / ns, a % ns)
				var nb := sec.node_id(k, b / ns, b % ns)
				city[Vector2i(mini(na, nb), maxi(na, nb))] = true
			var want := {}
			for na in adj.size():
				if sec.node_of(na)["deck"] != k:
					continue
				for l: Array in adj[na]:
					if int(l[2]) >= 0:
						continue      # ramps and lifts: not deck roads
					var nb := int(l[0])
					want[Vector2i(mini(na, nb), maxi(na, nb))] = true
			for sg: Dictionary in sec.segments(k):
				var f := str(sg["form"])
				if f == "pedestrian" or f == "none":
					dropped += 1
				if str(sg["blocked"]) == "foot" and (f == "street" or f == "lane"):
					# 2026-11-23 (downtown pass 2, ramp-foot rule): SectionPlan.road_graph() is the rule, and the city keeps
					# a foot segment only where the built geometry is open (tools/city_downtown/foot_probe.gd: the mech
					# capsule crosses the ramp lane on the toe side of the foot line). Every foot segment must be one of
					# those listed: a new one fails here until it is probed.
					var key := "%d/%d/%d/%d" % [s, k, int(sg["line"]), int(sg["index"])]
					check(FOOT_OPEN.has(key), "C: section %d deck %d: ramp-foot segment %s is a probed open one" % [s, k, key])
					want[Vector2i(mini(int(sg["a"]), int(sg["b"])), maxi(int(sg["a"]), int(sg["b"])))] = true
					foot += 1
			var deg := {}
			for e: Vector2i in city:
				deg[e.x] = true
				deg[e.y] = true
			isolated += plan.roads_x.size() * ns - deg.size()
			var extra := 0
			var missing := 0
			for e: Vector2i in city:
				if not want.has(e):
					extra += 1
			for e: Vector2i in want:
				if not city.has(e):
					missing += 1
			check(extra == 0 and missing == 0, "C: section %d deck %d: city and section road graphs agree edge for edge (%d extra, %d missing)" % [s, k, extra, missing])
			# Every block keeps a vehicle side.
			for bi in plan.blocks.size():
				var ok := false
				for side in 4:
					var f := plan.block_side_form(bi, side)
					ok = ok or f == "street" or f == "lane"
				check(ok, "C: section %d deck %d block %d keeps a vehicle side" % [s, k, bi])
			for q: Dictionary in plan.raised:
				if q["kind"] == "court":
					var r: Rect2 = q["rect"]
					var across := r.size.x if int(q["seg"]) < 65536 else r.size.y
					check(across >= 8.0, "C: section %d deck %d court opening %.1f m >= 8" % [s, k, across])
			decks += 1
	print("graphs: %d decks agree; %d pedestrian / none segments dropped, %d ramp-foot segments kept by the city graph; %d crossings with no road edge left (section forms)" % [decks, dropped, foot, isolated])
	check(dropped > 20, "the mix gives pedestrian / none segments (%d)" % dropped)


## On its own: the avenue and the edge roads never change, no two parallel neighbours share a form, vehicles keep one
## connected network, every block a vehicle side, about road_variety of the minor segments take a form.
func _forms_alone() -> void:
	var counts := {"lane": 0, "pedestrian": 0, "none": 0}
	var minor := 0
	for s in range(1, 21):
		var plan := CityPlan.make({"seed": s})
		var nx := plan.roads_x.size()
		var ns := plan.roads_s.size()
		for k: int in plan.forms:
			var axis := "x" if k >= 65536 else "s"
			var line := (k % 65536) / 256
			var index := k % 256
			var f := str(plan.forms[k])
			counts[f] += 1
			var lines := nx if axis == "s" else ns
			check(line > 0 and line < lines - 1, "C: alone %d: no form on an edge road (%s)" % [s, k])
			if axis == "s":
				check(plan.roads_x[line]["kind"] != "avenue", "C: alone %d: the avenue never changes" % s)
			check(plan.seg_form(axis, line + 1, index) != f and plan.seg_form(axis, line - 1, index) != f,
					"C: alone %d: segment %d has no parallel neighbour of the same form" % [s, k])
		minor += (nx - 2) * (ns - 1) + (ns - 2) * (nx - 1) - (ns - 1)
		var g := CityGraphs.road_graph(plan)
		var adj := {}
		for ed: Array in g["edges"]:
			for e2 in [[ed[0], ed[1]], [ed[1], ed[0]]]:
				if not adj.has(e2[0]):
					adj[e2[0]] = []
				adj[e2[0]].append(e2[1])
		var start: int = adj.keys()[0]
		var seen := {start: true}
		var queue := [start]
		while not queue.is_empty():
			var u: int = queue.pop_back()
			for v: int in adj[u]:
				if not seen.has(v):
					seen[v] = true
					queue.append(v)
		eq(seen.size(), adj.size(), "C: alone %d: one connected vehicle network" % s)
		for bi in plan.blocks.size():
			var ok := false
			for side in 4:
				var f := plan.block_side_form(bi, side)
				ok = ok or f == "street" or f == "lane"
			check(ok, "C: alone %d block %d keeps a vehicle side" % [s, bi])
	var n := int(counts["lane"]) + int(counts["pedestrian"]) + int(counts["none"])
	print("alone forms over 20 seeds: %s of %d minor segments (%.0f %%)" % [str(counts), minor, 100.0 * n / maxf(minor, 1)])
	check(n > 0.15 * minor and n < 0.45 * minor, "C: about a third of the minor segments take a form")
	eq(CityPlan.make({"seed": 2, "road_variety": 0.0}).forms.size(), 0, "C: road_variety 0: no forms")


## No sealed pocket: the ground a mech capsule (radius 2.2, 8 m) can stand on, flood-filled on a 1 m grid from the road
## crossings, reaches every alley, court, pedestrian street and lane.
func _forms_pockets(plan: CityPlan, tag: String) -> void:
	var e := plan.extent.grow(-1.0)
	var w := int(ceil(e.size.x))
	var h := int(ceil(e.size.y))
	var block := PackedByteArray()
	block.resize(w * h)
	var mark := func(r: Rect2) -> void:
		var x0 := clampi(int(floor(r.position.x - e.position.x)), 0, w)
		var x1 := clampi(int(ceil(r.end.x - e.position.x)), 0, w)
		var s0 := clampi(int(floor(r.position.y - e.position.y)), 0, h)
		var s1 := clampi(int(ceil(r.end.y - e.position.y)), 0, h)
		for j in range(s0, s1):
			for i in range(x0, x1):
				block[j * w + i] = 1
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		for t: Dictionary in b["tiers"]:
			if float(t["y0"]) < MECH_H + 0.3 and float(t["y1"]) > 1.3:
				mark.call(plan.tier_rect(i, t).grow(MECH_R))
		for so: Dictionary in b.get("solids", []):
			if float(so["y0"]) < MECH_H + 0.3 and float(so["y1"]) > 1.3:
				var sz: Vector2 = so["size"]
				mark.call(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz).grow(MECH_R))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			mark.call(Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs).grow(MECH_R))
	for o in plan.floor_cuts():
		mark.call(o.grow(MECH_R))
	for c: Dictionary in plan.columns:
		mark.call(Rect2(float(c["x"]) - float(c["ring_r"]), float(c["s"]) - float(c["ring_r"]), float(c["ring_r"]) * 2.0, float(c["ring_r"]) * 2.0).grow(MECH_R))
	var seen := PackedByteArray()
	seen.resize(w * h)
	var queue := PackedInt32Array()
	var g := CityGraphs.road_graph(plan)
	for p: Vector2 in g["nodes"]:
		var i := int(p.x - e.position.x)
		var j := int(p.y - e.position.y)
		if i >= 0 and i < w and j >= 0 and j < h and block[j * w + i] == 0 and seen[j * w + i] == 0:
			seen[j * w + i] = 1
			queue.append(j * w + i)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var i := c % w
		var j := c / w
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ni := i + d.x
			var nj := j + d.y
			if ni < 0 or nj < 0 or ni >= w or nj >= h:
				continue
			var n := nj * w + ni
			if block[n] == 0 and seen[n] == 0:
				seen[n] = 1
				queue.append(n)
	var at := func(p: Vector2) -> bool:
		var i := int(p.x - e.position.x)
		var j := int(p.y - e.position.y)
		return i >= 0 and i < w and j >= 0 and j < h and seen[j * w + i] == 1
	var n_checked := 0
	for a: Dictionary in plan.alleys:
		check(at.call((a["rect"] as Rect2).get_center()), "C: %s: the alley in block %d connects to the streets" % [tag, a["block"]])
		n_checked += 1
	for k: int in plan.forms:
		var axis := "x" if k >= 65536 else "s"
		var r := plan.seg_inner(axis, (k % 65536) / 256, k % 256)
		check(at.call(r.get_center()), "C: %s: the %s segment %d connects to the streets" % [tag, plan.forms[k], k])
		n_checked += 1
	print("%s: %d alleys / form segments reached by the mech flood fill" % [tag, n_checked])


## Life follows the forms: vehicle loops only round blocks with four streets and never on a closed segment; crossings
## over a pedestrian street or a court have no signal.
func _forms_life() -> void:
	var loops := 0
	var free := 0
	for spec: Array in [[2, 0], [4, 1], [7, 0], [-1, 1], [-1, 3]]:
		var plan := CityPlan.for_deck(SectionPlan.make(_mix(spec[0])), spec[1]) if spec[0] > 0 else CityPlan.make({"seed": spec[1]})
		var lp := LifePlan.make(plan)
		var tr := LifeTraffic.make(lp)
		var closed: Array[Rect2] = []
		var lanes := {}
		for k: int in plan.forms:
			var axis := "x" if k >= 65536 else "s"
			if str(plan.forms[k]) == "lane":
				lanes[k] = plan.seg_inner(axis, (k % 65536) / 256, k % 256).grow(-1.0)
			else:
				closed.append(plan.seg_inner(axis, (k % 65536) / 256, k % 256).grow(-1.0))
		var on_lane := {}
		for lo: Dictionary in tr.loops:
			loops += 1
			if lo.has("avenue"):
				continue
			for side in 4:
				var f := plan.block_side_form(int(lo["block"]), side)
				check(f == "street" or f == "lane", "C: %s: a vehicle loop round block %d has only vehicle roads (%s)" % [str(spec), lo["block"], f])
			for pt: Vector2 in lo["pts"]:
				for r in closed:
					check(not r.has_point(pt), "C: %s: no vehicle lap on a pedestrian / court segment" % str(spec))
				for k: int in lanes:
					if (lanes[k] as Rect2).has_point(pt):
						if not on_lane.has(k):
							on_lane[k] = {}
						on_lane[k][int(lo["block"])] = true
		for k: int in on_lane:
			eq((on_lane[k] as Dictionary).size(), 1, "C: %s: one loop at most drives lane %d (one lane)" % [str(spec), k])
		for ed: Array in lp.edges:
			if int(ed[2]) != LifePlan.CROSS:
				continue
			var mid := (lp.nodes[int(ed[0])] + lp.nodes[int(ed[1])]) * 0.5
			for k: int in plan.forms:
				var axis := "x" if k >= 65536 else "s"
				var r := plan.seg_inner(axis, (k % 65536) / 256, k % 256)
				if str(plan.forms[k]) != "lane" and r.has_point(mid):
					eq(int(ed[3]), -1, "C: %s: a crossing over a %s segment has no signal" % [str(spec), plan.forms[k]])
					free += 1
		eq(LifePlan.make(plan).checksum(), lp.checksum(), "C: %s: life stays deterministic" % str(spec))
	print("life with forms: %d loops checked, %d signal-free crossings" % [loops, free])


## A deck with forms built: string lights on their own node on the deck's layer, courts and bands are solid at the
## sidewalk's height.
func _forms_built(s: int) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	d.render_layer = 1 << 2
	add_child(d)
	d.build_deck(SectionPlan.make(_mix(s)), 0)
	await frames(2)
	var plan := d.plan
	var has_ped := plan.forms.values().has("pedestrian")
	var sl := d.get_node_or_null("StringLights") as MeshInstance3D
	check(sl != null or not has_ped, "C: section %d deck 0: string lights over the pedestrian streets" % s)
	if sl != null:
		eq(sl.layers, d.render_layer, "C: string lights on the deck's layer")
		eq(sl.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "C: string lights cast no shadow")
	var space := d.get_world_3d().direct_space_state
	for q: Dictionary in plan.raised:
		var c := (q["rect"] as Rect2).get_center()
		var a := d.global_transform * d.ring.arc_to_world(c.x, c.y, 3.0)
		var b := d.global_transform * d.ring.arc_to_world(c.x, c.y, -1.0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b))
		check(not hit.is_empty() and absf(d.ring.height(d.to_local(hit["position"])) - CityPlan.CURB_H) < 0.05,
				"C: the %s at (%.0f, %.0f) is solid at the sidewalk's height" % [q["kind"], c.x, c.y])
	# Stepped build == one-shot build with forms, alleys and string lights.
	var d2 := CityDistrict.new()
	d2.with_rig = false
	d2.render_layer = 1 << 2
	add_child(d2)
	d2.build_deck_begin(SectionPlan.make(_mix(s)), 0)
	while not d2.build_step():
		pass
	eq(d2.geometry_digest(), d.geometry_digest(), "C: stepped build = one-shot build (digest)")
	eq(_col(d2), _col(d), "C: stepped build = one-shot build (collision)")
	eq(CityProps.layout_checksum(d2.props.items), CityProps.layout_checksum(d.props.items), "C: stepped build = one-shot build (props)")
	d.queue_free()
	d2.queue_free()


# --- Graphs: walk_graph (mechs, enemies, bots) vs road_graph (vehicles) --------------------------------------------

## road_graph() is the vehicle graph and did not change when walk_graph() was added (2026-11-23, forms live): hashes of
## var_to_bytes(road_graph()) captured with walk_graph added (road_graph's code untouched), "section/deck" (default forms,
## live) and "alone/seed".
const ROAD_PINS := {"1/0": 2808164362, "4/1": 4162149389, "7/2": 4160505198, "alone/1": 43452835, "alone/5": 274673334}

const WALK_FORMS := ["street", "lane", "pedestrian", "none", "alley"]


static func _ekey(ed: Array) -> Vector2i:
	return Vector2i(mini(int(ed[0]), int(ed[1])), maxi(int(ed[0]), int(ed[1])))


static func _pin_plan(key: String) -> CityPlan:
	if key.begins_with("alone/"):
		return CityPlan.make({"seed": int(key.substr(6))})
	var sk := key.split("/")
	return CityPlan.for_deck(SectionPlan.make({"seed": int(sk[0])}), int(sk[1]))


## Every plan the graph rules run over: section seeds 1-20 with the default (live) forms, every deck; stand-alone 1-20.
func _walk_plans() -> Array:
	var out := []
	for s in range(1, 21):
		var sec := SectionPlan.make({"seed": s})
		for k in sec.deck_count:
			out.append(["section %d deck %d" % [s, k], CityPlan.for_deck(sec, k)])
	for s in range(1, 21):
		out.append(["alone %d" % s, CityPlan.make({"seed": s})])
	return out


func _walk_rules() -> void:
	for key: String in ROAD_PINS:
		eq(hash(var_to_bytes(CityGraphs.road_graph(_pin_plan(key)))), ROAD_PINS[key], "graphs: %s road_graph() byte-identical to before walk_graph" % key)
	var extra := {"pedestrian": 0, "none": 0}
	var closed_courts := 0
	var alleys := 0
	var alley_edges := 0
	for pc: Array in _walk_plans():
		var tag: String = pc[0]
		var plan: CityPlan = pc[1]
		var rg := CityGraphs.road_graph(plan)
		var wg := CityGraphs.walk_graph(plan)
		check(not rg.has("forms"), "graphs: %s road_graph() has no forms key (unchanged shape)" % tag)
		eq(wg["nodes"], rg["nodes"], "graphs: %s walk_graph nodes = road_graph nodes (ids and positions)" % tag)
		var re: Array = rg["edges"]
		var we: Array = wg["edges"]
		check(we.slice(0, re.size()) == re, "graphs: %s walk_graph starts with every road_graph edge, in order" % tag)
		eq(_components(wg), 1, "graphs: %s walk_graph is one connected network" % tag)
		var wf: Dictionary = wg["forms"]
		eq(wf.size(), we.size(), "graphs: %s one form per edge" % tag)
		var ns := plan.roads_s.size()
		var cuts: Array[Rect2] = plan.floor_cuts() if plan.site != null else ([] as Array[Rect2])
		for i in we.size():
			var ed: Array = we[i]
			var f := str(wf.get(_ekey(ed), "?"))
			check(WALK_FORMS.has(f), "graphs: %s edge %s has a form (%s)" % [tag, str(ed), f])
			if i < re.size():
				check(f == "street" or f == "lane", "graphs: %s road edge %s is a vehicle form (%s)" % [tag, str(ed), f])
				continue
			check(f == "pedestrian" or f == "none", "graphs: %s extra edge %s is pedestrian / none (%s)" % [tag, str(ed), f])
			extra[f] += 1
			var a := int(ed[0])
			var b := int(ed[1])
			var axis := "s" if b == a + 1 else "x"
			eq(plan.seg_form(axis, a / ns if axis == "s" else a % ns, a % ns if axis == "s" else a / ns), f, "graphs: %s extra edge %s is that segment's form" % [tag, str(ed)])
			check(not CityGraphs.crosses_cut(wg["nodes"][a], wg["nodes"][b], cuts), "graphs: %s extra edge %s crosses no floor cut" % [tag, str(ed)])
		# Every pedestrian segment the cut rule allows is in; a court exactly when court_open says the capsule crosses it.
		var have := {}
		for ed: Array in we:
			have[_ekey(ed)] = true
		for k: int in plan.forms:
			var axis := "x" if k >= 65536 else "s"
			var line := (k % 65536) / 256
			var index := k % 256
			var a := line * ns + index if axis == "s" else index * ns + line
			var b := a + 1 if axis == "s" else a + ns
			var f := str(plan.forms[k])
			var cut := CityGraphs.crosses_cut(wg["nodes"][a], wg["nodes"][b], cuts)
			if f == "pedestrian":
				eq(have.has(Vector2i(a, b)), not cut, "graphs: %s pedestrian segment %d walkable unless cut" % [tag, k])
			elif f == "none":
				var open := CityGraphs.court_open(plan, axis, line, index)
				closed_courts += 0 if open else 1
				eq(have.has(Vector2i(a, b)), open and not cut, "graphs: %s court %d in the walk graph exactly when open" % [tag, k])
		# with_alleys: the grid's ids unchanged, new ids after them, one edge through every alley, still one network.
		var wa := CityGraphs.walk_graph(plan, true)
		var n0: int = rg["nodes"].size()
		eq((wa["nodes"] as Array).slice(0, n0), rg["nodes"], "graphs: %s with alleys: existing node ids unchanged" % tag)
		eq(_components(wa), 1, "graphs: %s with alleys: one connected network" % tag)
		eq((wa["forms"] as Dictionary).size(), (wa["edges"] as Array).size(), "graphs: %s with alleys: one form per edge" % tag)
		for al: Dictionary in plan.alleys:
			alleys += 1
			var r: Rect2 = al["rect"]
			var walked := false
			for ed: Array in wa["edges"]:
				if str(wa["forms"][_ekey(ed)]) != "alley":
					continue
				var mid: Vector2 = ((wa["nodes"][int(ed[0])] as Vector2) + (wa["nodes"][int(ed[1])] as Vector2)) * 0.5
				if r.has_point(mid) and int(ed[0]) >= n0 and int(ed[1]) >= n0:
					walked = true
			check(walked, "graphs: %s with alleys: an edge walks the alley in block %d" % [tag, al["block"]])
		var ae := 0
		for ed: Array in wa["edges"]:
			ae += 1 if str(wa["forms"][_ekey(ed)]) == "alley" else 0
		alley_edges += ae
		if plan.alleys.is_empty():
			check(wa["edges"] == wg["edges"] and wa["nodes"] == wg["nodes"], "graphs: %s with alleys, none on the deck: the same graph" % tag)
	print("walk graphs: extra edges %s, %d courts closed to the capsule, %d alleys, %d alley edges" % [str(extra), closed_courts, alleys, alley_edges])
	check(int(extra["pedestrian"]) > 20 and int(extra["none"]) > 0, "graphs: the live forms give walk-only edges (%s)" % str(extra))
	eq(alley_edges, alleys, "graphs: one walk edge per alley")
	# Every court the live forms make is open (the section keeps them clear), so court_open's "closed" side is checked on
	# a court with an obstacle put in it: a park column at the court's middle closes it, and the walk graph drops it.
	var probe_done := false
	for pc: Array in _walk_plans():
		var plan: CityPlan = pc[1]
		for k: int in plan.forms:
			if probe_done or str(plan.forms[k]) != "none":
				continue
			var axis := "x" if k >= 65536 else "s"
			var line := (k % 65536) / 256
			var index := k % 256
			var c := plan.seg_inner(axis, line, index).get_center()
			var before: int = CityGraphs.walk_graph(plan)["edges"].size()
			plan.columns.append({"x": c.x, "s": c.y, "ring_r": 1.5, "half": 1.0, "ring_h": 0.6})
			check(not CityGraphs.court_open(plan, axis, line, index), "graphs: %s court %d with a column in it is closed" % [pc[0], k])
			eq(CityGraphs.walk_graph(plan)["edges"].size(), before - 1, "graphs: %s the closed court leaves the walk graph" % pc[0])
			plan.columns.pop_back()
			probe_done = true
	check(probe_done, "graphs: a court to close")
	# Forms off: walk_graph is road_graph (plus the forms key: every edge street / lane).
	for s in range(1, 21):
		var sec := _sec_off(s)
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var rg := CityGraphs.road_graph(plan)
			var wg := CityGraphs.walk_graph(plan)
			check(wg["nodes"] == rg["nodes"] and wg["edges"] == rg["edges"], "graphs: section %d deck %d (forms off): walk_graph == road_graph" % [s, k])
	for s in range(1, 6):
		var plan := CityPlan.make({"seed": s, "road_variety": 0.0})
		var rg := CityGraphs.road_graph(plan)
		var wg := CityGraphs.walk_graph(plan)
		check(wg["nodes"] == rg["nodes"] and wg["edges"] == rg["edges"], "graphs: alone %d (road_variety 0): walk_graph == road_graph" % s)


## Every walk-only edge (pedestrian, court, alley) in built collision: the mech capsule (radius 2.2, 8 m, its foot 0.3 m
## over the sidewalk) swept crossing to crossing on 1 m steps touches nothing of the deck's collision. Decks: the first
## three of section seeds 1-20 (default forms) holding a court, two more with pedestrian streets and alleys, alone 1.
## A court court_open rejects (if any) must be blocked in the built collision too.
func _walk_built() -> void:
	var picks := []
	var courts := 0
	var peds := 0
	for s in range(1, 21):
		var sec := SectionPlan.make({"seed": s})
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var f := plan.forms.values()
			if f.has("none") and courts < 3:
				courts += 1
				picks.append([s, k])
			elif f.has("pedestrian") and peds < 2 and not plan.alleys.is_empty():
				peds += 1
				picks.append([s, k])
	picks.append([-1, 1])
	var swept := 0
	for pk: Array in picks:
		var d := CityDistrict.new()
		d.with_rig = false
		add_child(d)
		if int(pk[0]) > 0:
			d.build_deck(SectionPlan.make({"seed": int(pk[0])}), int(pk[1]))
		else:
			d.build({"seed": int(pk[1])})
		await frames(2)
		var tag := "section %d deck %d" % [pk[0], pk[1]] if int(pk[0]) > 0 else "alone %d" % pk[1]
		var plan := d.plan
		var g := CityGraphs.walk_graph(plan, true)
		for ed: Array in g["edges"]:
			var f := str(g["forms"][_ekey(ed)])
			if f == "street" or f == "lane":
				continue
			var hits := _sweep(d, g["nodes"][int(ed[0])], g["nodes"][int(ed[1])])
			check(hits == 0, "graphs: %s %s edge %s: the mech capsule crosses it in built collision (%d contacts)" % [tag, f, str(ed), hits])
			swept += 1
		var ns := plan.roads_s.size()
		for k: int in plan.forms:
			if str(plan.forms[k]) != "none":
				continue
			var axis := "x" if k >= 65536 else "s"
			var line := (k % 65536) / 256
			var index := k % 256
			if CityGraphs.court_open(plan, axis, line, index):
				continue
			var a := line * ns + index if axis == "s" else index * ns + line
			var b := a + 1 if axis == "s" else a + ns
			check(_sweep(d, g["nodes"][a], g["nodes"][b]) > 0, "graphs: %s court %d closed by plan data is closed in built collision" % [tag, k])
		d.queue_free()
		await frames(1)
	print("walk graphs in built collision: %d walk-only edges swept over %d decks" % [swept, picks.size()])
	check(swept >= 10, "graphs: walk-only edges swept (%d)" % swept)


## Contacts of the mech capsule with the district's collision along p..q (arc), 1 m steps.
func _sweep(d: CityDistrict, p: Vector2, q: Vector2) -> int:
	var space := d.get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = MECH_R
	shape.height = MECH_H
	var qp := PhysicsShapeQueryParameters3D.new()
	qp.shape = shape
	var body := d.get_node("Collision")
	var n := maxi(1, int(ceil(p.distance_to(q))))
	var hits := 0
	for i in n + 1:
		var c := p.lerp(q, float(i) / float(n))
		var h := CityPlan.CURB_H + 0.3 + MECH_H * 0.5
		qp.transform = d.global_transform * Transform3D(CityGeo.frame_basis(d.ring, c.y), d.ring.arc_to_world(c.x, c.y, h))
		for hit: Dictionary in space.intersect_shape(qp, 8):
			if hit["collider"] == body:
				hits += 1
	return hits
