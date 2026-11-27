extends TestCase
## The downtown zone (docs/design/city-downtown.md): placement (zero or one zone a deck, contiguous, grown from the
## avenue, about two decks in three), determinism, the stand-alone goldens at `downtown` 0, and every rule of the design
## as an assertion: neighbours on a block face differ, three bases or more a block, a through view a block (2D, at a
## mech's eye, against the tiers), perches at two heights, shafts 10 m apart and 6 m back from the street, no two slabs
## facing across a street, towers into the ceiling and not standable, base roofs reachable, nothing on a cut, kept-clear
## ground, the park or the civic hall, the real capsule walks under every arcade, and the triangle budget.

const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8]
const MECH_R := 2.2          ## the mech's collision capsule (MechSpawn: radius 1.1 x mech_scale 2.0)
const MECH_H := 8.0          ## and its height
const TRI_BUDGET := 1.15     ## a deck with a zone: at most 15 % more triangles than without


func setup() -> void:
	timeout_sec = 240.0
	_goldens()
	_determinism()
	var decks := 0
	var zoned := 0
	var kinds := {}
	# Pass 2 (2026-11-23): density. Zone share on zoned decks, shafts per block, slab share, pillars in the zone,
	# diagonal views.
	var shares: Array[float] = []
	var per_block := {}
	var slabs := 0
	var towers := 0
	var zone_blocks := 0
	var pillar_blocks := 0
	var diag_blocks := 0
	var corner_blocks := 0
	var corner_diag := 0
	for seed_ in SEEDS:
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			decks += 1
			var zone := plan.downtown_blocks()
			if not zone.is_empty():
				zoned += 1
				shares.append(float(zone.size()) / float(plan.blocks.size()))
			_check_zone(plan, "section %d deck %d" % [seed_, k], kinds)
			for bi in zone:
				zone_blocks += 1
				var n := plan.shaft_rects(bi).size()
				per_block[n] = int(per_block.get(n, 0)) + 1
				check(n >= 2 and n <= CityPlan.DT_MAX_SHAFTS, "section %d deck %d block %d: %d shafts (2..%d)" % [seed_, k, bi, n, CityPlan.DT_MAX_SHAFTS])
				var has_pillar := false
				var has_corner := false
				for i in plan.buildings_in(bi):
					has_pillar = has_pillar or plan.buildings[i]["pillar"]
					has_corner = has_corner or str(plan.buildings[i].get("base", "")) == "corner"
					for t: Dictionary in plan.buildings[i]["tiers"]:
						if str(t.get("kind", "")) == "tower":
							towers += 1
							slabs += 1 if str(t.get("tower", "")) == "slab" else 0
				pillar_blocks += 1 if has_pillar else 0
				var diag := not plan.diagonal_views(bi).is_empty()
				diag_blocks += 1 if diag else 0
				if has_corner:
					corner_blocks += 1
					corner_diag += 1 if diag else 0
	print("decks with a zone: %d of %d; bases %s" % [zoned, decks, kinds])
	check(float(zoned) / float(decks) >= 0.5 and float(zoned) / float(decks) <= 0.85, "about two decks in three have a zone (%d of %d)" % [zoned, decks])
	var mean := 0.0
	for v in shares:
		mean += v / float(shares.size())
		check(v >= 0.2, "a zoned deck has at least a fifth of its blocks in the zone (%.2f)" % v)
	print("zone share on zoned decks: mean %.2f, %s" % [mean, shares])
	check(mean >= 0.28, "zones are about a third of the deck (mean %.2f)" % mean)
	print("shafts per zone block: %s; slabs %d of %d towers; %d of %d zone blocks hold a pillar; diagonal views in %d blocks, %d of %d corner-cut blocks"
			% [per_block, slabs, towers, pillar_blocks, zone_blocks, diag_blocks, corner_diag, corner_blocks])
	var slab_share := float(slabs) / maxf(float(towers), 1.0)
	check(slab_share >= 0.3 and slab_share <= 0.5, "slab share about 40 %% (%.2f)" % slab_share)
	check(float(pillar_blocks) >= float(zone_blocks) * 0.5, "pillar cells join the zone (%d of %d blocks)" % [pillar_blocks, zone_blocks])
	check(diag_blocks > 0, "some blocks have a diagonal view")
	check(corner_diag * 2 >= corner_blocks, "corner cuts mostly open a diagonal view (%d of %d)" % [corner_diag, corner_blocks])
	for b: String in CityPlan.DT_BASES:
		check(int(kinds.get(b, 0)) > 0, "the %s base is built somewhere (%s)" % [b, kinds])
	for seed_ in [1, 2, 5]:
		var plan := CityPlan.make({"seed": seed_, "downtown": 0.5})
		check(not plan.downtown_blocks().is_empty(), "seed %d on its own, downtown 0.5: a zone" % seed_)
		_check_zone(plan, "seed %d alone downtown 0.5" % seed_, kinds)
	await _arcade_walk(4, 2)
	await _budget()
	finish()


## Re-captured 2026-11-23 (city variety: alleys + stand-alone road forms on by default). Was 209989488eaa0e52 /
## e4ec580da1956459 / props 7e78d4e1e3db1a61 (still the values with alleys 0, road_variety 0: tests/test_city_variety.gd).
func _goldens() -> void:
	eq(CityPlan.make({"seed": 1}).checksum(), "bd1d848c575e85df", "downtown 0: the seed 1 plan checksum (golden)")
	eq(CityPlan.make({"seed": 1, "walls": 1.0}).checksum(), "3eb0728c9b4cffa2", "downtown 0: the walled plan checksum (golden)")
	eq(CityPropLayout.checksum(CityPropLayout.layout(CityPlan.make({"seed": 1}))), "f321076ebd6e98f1", "downtown 0: the props layout (golden)")
	check(CityPlan.make({"seed": 1}).downtown_blocks().is_empty(), "no zone on its own by default")


func _determinism() -> void:
	var sec := SectionPlan.make({"seed": 4})
	var a := CityPlan.for_deck(sec, 2)
	var b := CityPlan.for_deck(SectionPlan.make({"seed": 4}), 2)
	eq(a.checksum(), b.checksum(), "same section, same deck: the same zone and checksum")
	eq(str(a.downtown_blocks()), str(b.downtown_blocks()), "the same zone blocks")
	check(not a.downtown_blocks().is_empty(), "section 4 deck 2 has a zone")
	var off := CityPlan.for_deck(sec, 2, {"downtown": 0.0})
	check(off.downtown_blocks().is_empty(), "overrides downtown 0: no zone")
	check(off.checksum() != a.checksum(), "the zone is in the checksum")
	var alone := CityPlan.make({"seed": 2, "downtown": 0.5})
	eq(alone.checksum(), CityPlan.make({"seed": 2, "downtown": 0.5}).checksum(), "on its own: deterministic")


func _check_zone(plan: CityPlan, what: String, kinds: Dictionary) -> void:
	var zone := plan.downtown_blocks()
	if zone.is_empty():
		return
	# Contiguous, sized as designed, grown from the avenue.
	check(zone.size() <= maxi(1, roundi(plan.blocks.size() * (CityPlan.DT_SHARE if plan.section != null else plan.p("downtown")))),
			"%s: zone of %d blocks is not more than its share" % [what, zone.size()])
	var seen := {zone[0]: true}
	var queue: Array = [zone[0]]
	while not queue.is_empty():
		var bi: int = queue.pop_back()
		for o in zone:
			# Pass 2: blocks sharing a side or a crossing (corner to corner) are one cluster.
			if not seen.has(o) and maxi(absi(int(plan.blocks[o]["ix"]) - int(plan.blocks[bi]["ix"])), absi(int(plan.blocks[o]["is"]) - int(plan.blocks[bi]["is"]))) == 1:
				seen[o] = true
				queue.append(o)
	eq(seen.size(), zone.size(), "%s: the zone is one contiguous cluster" % what)
	var on_avenue := false
	var av := plan.avenue_x()
	for bi in zone:
		var r: Rect2 = plan.blocks[bi]["rect"]
		if plan.section != null:
			on_avenue = on_avenue or int(plan.blocks[bi]["ix"]) == plan.section.spine_line or int(plan.blocks[bi]["ix"]) + 1 == plan.section.spine_line
		else:
			on_avenue = on_avenue or absf(r.position.x - av.y) < 0.01 or absf(r.end.x - av.x) < 0.01
		check(plan.blocks[bi]["kind"] == "built" or plan.blocks[bi]["kind"] == "industrial", "%s: block %d in the zone is a built block" % [what, bi])
		if plan.section != null:
			check(plan.blocks[bi]["zone"] == "urban" or plan.blocks[bi]["zone"] == "industrial", "%s: block %d keeps its section zone" % [what, bi])
	check(on_avenue, "%s: the zone touches the avenue" % what)
	var no_go: Array[Rect2] = []
	no_go.append_array(plan.floor_cuts())
	no_go.append_array(plan.site.keep_clear)
	for l: Dictionary in plan.lots:
		if l["open"] == "park":
			no_go.append(l["rect"])
	for b: Dictionary in plan.buildings:
		if b["style"] == "civic":
			no_go.append(Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"]))
	var ceiling := plan.p("ceiling")
	var reach := plan.reachable_roofs()
	for bi in zone:
		var tag := "%s block %d" % [what, bi]
		var z: Rect2 = (plan.blocks[bi]["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
		var units := {}
		var heights := plan.perch_heights(bi)
		for i in plan.buildings_in(bi):
			var b: Dictionary = plan.buildings[i]
			check(b.has("base") and str(b["base"]) in CityPlan.DT_BASES, "%s: building %d (%s) has a base" % [tag, i, b["style"]])
			units[int(b.get("unit", -1))] = str(b.get("base", ""))
			if b["style"] == "tower":
				check(reach[i], "%s: building %d (%s) roofs reachable" % [tag, i, b["base"]])
			var foot := Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"])
			for o in no_go:
				check(not foot.intersects(o), "%s: building %d stands on a cut, kept-clear ground, the park or the hall" % [tag, i])
				for r: Rect2 in b.get("paving", []):
					check(not r.intersects(o), "%s: building %d's plaza overlaps a cut or kept-clear ground" % [tag, i])
			var lot: Dictionary = plan.lots[b["lot"]]
			for t: Dictionary in b["tiers"]:
				if str(t.get("kind", "")) != "tower":
					continue
				check(float(t["y1"]) >= ceiling and not t["stand"], "%s: building %d's tower meets the ceiling and is not standable" % [tag, i])
				var sr := plan.tier_rect(i, t)
				var gaps := [z.end.x - sr.end.x, sr.position.x - z.position.x, z.end.y - sr.end.y, sr.position.y - z.position.y]
				for side in 4:
					if lot["faces"][side]:
						check(gaps[side] >= CityPlan.DT_SETBACK - 0.01, "%s: building %d's tower %.1f m from the street (side %d)" % [tag, i, gaps[side], side])
		for u: int in units:
			kinds[units[u]] = int(kinds.get(units[u], 0)) + 1
		var distinct := {}
		for u: int in units:
			distinct[units[u]] = true
		# Three bases or more; a block of only two based lots: both differ (pass 2).
		check(distinct.size() >= mini(3, units.size()), "%s: three bases or more (%s)" % [tag, units.values()])
		check(heights.size() >= 2, "%s: perches at two heights or more (%s)" % [tag, heights])
		check(not plan.through_views(bi).is_empty(), "%s: a through view at the mech's eye" % tag)
		# Neighbours on a block face differ.
		var ids := plan.buildings_in(bi)
		for a in ids:
			for c in ids:
				var ba: Dictionary = plan.buildings[a]
				var bc: Dictionary = plan.buildings[c]
				if a >= c or int(ba.get("unit", -1)) == int(bc.get("unit", -2)):
					continue
				var la: Dictionary = plan.lots[ba["lot"]]
				var lc: Dictionary = plan.lots[bc["lot"]]
				if CityPlan._dt_touch(la["rect"], lc["rect"], 3.6) and CityPlan._dt_same_face(la["faces"], lc["faces"]):
					check(ba["base"] != bc["base"], "%s: neighbours %d and %d on a block face both %s" % [tag, a, c, ba["base"]])
	# Shafts (and pillar cores) 10 m apart.
	var shafts: Array[Rect2] = []
	for bi in zone:
		shafts.append_array(plan.shaft_rects(bi))
	for a in shafts.size():
		for c in range(a + 1, shafts.size()):
			var dx := maxf(maxf(shafts[c].position.x - shafts[a].end.x, shafts[a].position.x - shafts[c].end.x), 0.0)
			var ds := maxf(maxf(shafts[c].position.y - shafts[a].end.y, shafts[a].position.y - shafts[c].end.y), 0.0)
			check(Vector2(dx, ds).length() >= CityPlan.DT_SPACING - 0.01, "%s: two shafts %.1f m apart" % [what, Vector2(dx, ds).length()])
	# No two slabs facing each other across a street.
	var slabs := []
	for i in plan.buildings.size():
		for t: Dictionary in plan.buildings[i]["tiers"]:
			if str(t.get("tower", "")) == "slab":
				slabs.append([int(plan.lots[plan.buildings[i]["lot"]]["block"]), plan.tier_rect(i, t)])
	for a in slabs.size():
		for c in range(a + 1, slabs.size()):
			var ba: Dictionary = plan.blocks[slabs[a][0]]
			var bc: Dictionary = plan.blocks[slabs[c][0]]
			var ra: Rect2 = slabs[a][1]
			var rc: Rect2 = slabs[c][1]
			var axis := 0 if ra.size.x >= ra.size.y else 1
			if axis != (0 if rc.size.x >= rc.size.y else 1):
				continue
			var dix := absi(int(ba["ix"]) - int(bc["ix"]))
			var dis := absi(int(ba["is"]) - int(bc["is"]))
			var across := (axis == 1 and dix == 1 and dis == 0) or (axis == 0 and dis == 1 and dix == 0)
			var over := minf(ra.end[axis], rc.end[axis]) - maxf(ra.position[axis], rc.position[axis])
			check(not (across and over > 0.0), "%s: two slabs face each other across a street" % what)


## The mech's capsule fits under every arcade of a real deck: along each gallery, and in from the street between columns.
func _arcade_walk(seed_: int, k: int) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build_deck(SectionPlan.make({"seed": seed_}), k, {})
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = MECH_R
	shape.height = MECH_H
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	var plan := d.plan
	var body := d.get_node("Collision")
	var arcades := 0
	var samples := 0
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if b["style"] != "tower" or b["base"] != "arcade":
			continue
		arcades += 1
		var dt: Dictionary = b["dt"]
		check(float(dt["clear"]) >= CityPlan.BRIDGE_CLEAR, "arcade %d clear height %.2f" % [i, float(dt["clear"])])
		var g: Rect2 = dt["gallery"]
		var f := int(dt["front"])
		var axis := 0 if f < 2 else 1
		var out := 1.0 if f % 2 == 0 else -1.0
		var line := (g.end[axis] if f % 2 == 0 else g.position[axis])
		var cols: Array = dt["columns"]
		for c in range(1, cols.size()):
			var gap := absf((cols[c] as Vector2)[1 - axis] - (cols[c - 1] as Vector2)[1 - axis]) - CityPlan.DT_COLUMN
			check(gap >= 8.0 - 0.01, "arcade %d: columns %.2f m apart" % [i, gap])
		var paths := []
		# Along the gallery, at its middle.
		var mid := g.get_center()[axis]
		paths.append([_v(axis, mid, g.position[1 - axis] + MECH_R + 0.5), _v(axis, mid, g.end[1 - axis] - MECH_R - 0.5)])
		# In from the street between the first two columns, to the gallery's middle.
		if cols.size() >= 2:
			var between := ((cols[0] as Vector2)[1 - axis] + (cols[1] as Vector2)[1 - axis]) * 0.5
			paths.append([_v(axis, line + out * (CityPlan.SIDEWALK + 2.0), between), _v(axis, mid, between)])
		for pth: Array in paths:
			var a: Vector2 = pth[0]
			var bb: Vector2 = pth[1]
			var n := maxi(int(a.distance_to(bb) / 1.0), 1)
			for s in n + 1:
				var p := a.lerp(bb, float(s) / float(n))
				var h := CityPlan.CURB_H + 0.3 + MECH_H * 0.5
				q.transform = d.global_transform * Transform3D(CityGeo.frame_basis(d.ring, p.y), d.ring.arc_to_world(p.x, p.y, h))
				var solid := false
				for hit: Dictionary in space.intersect_shape(q, 8):
					solid = solid or hit["collider"] == body      # street props (knocked aside) are not the arcade
				samples += 1
				check(not solid, "arcade %d: the capsule hits the plan's solids under the arcade at (%.1f, %.1f)" % [i, p.x, p.y])
				if solid:
					break
	check(arcades > 0, "section %d deck %d has arcades to walk under" % [seed_, k])
	print("arcade walk: %d arcades, %d capsule samples" % [arcades, samples])
	remove_child(d)
	d.free()


static func _v(axis: int, normal: float, along: float) -> Vector2:
	return Vector2(normal, along) if axis == 0 else Vector2(along, normal)


## A deck with a zone draws at most TRI_BUDGET times the same deck without one.
func _budget() -> void:
	for pair: Array in [[1, 2], [4, 1], [4, 2]]:
		var sec := SectionPlan.make({"seed": pair[0]})
		var on := _tris(sec, pair[1], {})
		var off := _tris(sec, pair[1], {"downtown": 0.0})
		print("section %d deck %d: %d triangles with the zone, %d without (%+.1f %%)" % [pair[0], pair[1], on, off, (float(on) / float(off) - 1.0) * 100.0])
		check(float(on) <= float(off) * TRI_BUDGET, "section %d deck %d: zone within the triangle budget" % [pair[0], pair[1]])
		await frames(1)


func _tris(sec: SectionPlan, k: int, ov: Dictionary) -> int:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build_deck(sec, k, ov)
	var t := int(d.stats["triangles"])
	remove_child(d)
	d.free()
	return t
