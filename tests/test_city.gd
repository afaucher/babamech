extends TestCase
## The city generator (scripts/world/city/): the plan is deterministic and checksummed, every lot is used, nothing but a
## pillar reaches the ceiling, the roads connect, every roof can be hopped to, and relighting never touches geometry.
## Section mode (docs/design/city-section-mode.md): a whole deck is built from the section plan, which it follows
## exactly (cells, pillars, holes, walls), with nothing standing in a floor hole and the walls' gates open or sealed.


func setup() -> void:
	timeout_sec = 180.0
	_determinism()
	for s in [1, 2, 3, 7, 42, 99]:
		_check_plan(CityPlan.make({"seed": s}), "seed %d" % s)
	# The ends of every generator setting still give a sound plan.
	for p: Dictionary in CityLab.PARAMS:
		for v in [float(p["min"]), float(p["max"])]:
			_check_plan(CityPlan.make({"seed": 5, p["id"]: v}), "%s=%s" % [p["id"], v])
	_section_site()
	for seed_ in [1, 2, 3, 4, 5]:
		var section := SectionPlan.make({"seed": seed_})
		for deck in section.deck_count:
			_check_deck(section, deck, "section %d deck %d" % [seed_, deck])
	_golden()
	for seed_ in [1, 2, 3, 4, 5]:
		_roof_layout(CityPlan.make({"seed": seed_}), "seed %d" % seed_)
		_roof_layout(CityPlan.for_deck(SectionPlan.make({"seed": seed_}), 1), "section %d deck 1" % seed_)
	await _district()
	await _section_district()
	for seed_ in [1, 2, 3, 4, 5]:
		await _rooftops(seed_)
	await _skylight_walk()
	finish()


# --- Rooftops (docs/design/city-rooftops.md) -------------------------------------------------------------

## Golden values: the stand-alone plan of seed 1 (with and without walls), and which roofs can be reached for seeds
## 1-5 (unchanged by the rooftop pass: captured before it). A change here changes every machine's district on purpose.
## Re-captured 2026-11-23 (city variety, docs/design/city-variety.md: service alleys and stand-alone road forms, both on
## by default): was {"1": "209989488eaa0e52", "1w": "e4ec580da1956459"} (still the plan with alleys 0, road_variety 0).
const GOLDEN_PLAN := {"1": "bd1d848c575e85df", "1w": "3eb0728c9b4cffa2"}
const GOLDEN_REACH := {
	1: "1111111111101111111111011111101111111111",
	2: "111111111111011111111111011111011111111111",
	3: "111111111111111101111111110111111111111011",
	4: "111111111111111111011111111010111111111111111",
	5: "11111011011111111101111111111111111111",
}


func _golden() -> void:
	eq(CityPlan.make({"seed": 1}).checksum(), GOLDEN_PLAN["1"], "the seed 1 plan checksum (golden)")
	eq(CityPlan.make({"seed": 1, "walls": 1.0}).checksum(), GOLDEN_PLAN["1w"], "the seed 1 walled plan checksum (golden)")
	for seed_: int in GOLDEN_REACH:
		# Without the city variety's alleys and road forms (2026-11-23), which change the lots on purpose.
		var ok := CityPlan.make({"seed": seed_, "alleys": 0.0, "road_variety": 0.0}).reachable_roofs()
		var flags := ""
		for f in ok:
			flags += "1" if f else "0"
		eq(flags, GOLDEN_REACH[seed_], "seed %d: the same roofs can be reached as before the rooftop pass" % seed_)


## Skylights and roof props stand inside their tier, clear of what stands on it and of each other; offices with a big
## top roof have a standable plant room on it.
func _roof_layout(plan: CityPlan, what: String) -> void:
	var feet := {}       # building -> [[centre, footprint radius]]
	for it: Dictionary in CityProps.layout(plan):
		if not CityPropSim.is_roof(it):
			continue
		var bi := int(it["building"])
		var ti := int(it["tier"])
		var at := Vector2(it["lx"], it["lz"])
		var foot := float(CityProps.ROOF_FOOT[it["type"]])
		check(plan.roof_rect(bi, ti).grow(-foot).has_point(at), "%s: roof prop %d (%s) stands inside its tier" % [what, it["id"], it["type"]])
		near(float(it["ly"]), float(plan.buildings[bi]["tiers"][ti]["y1"]), 1e-4, "%s: roof prop %d at its roof's height" % [what, it["id"]])
		for q in plan.roof_blockers(bi, ti):
			check(not q.grow(foot).has_point(at), "%s: roof prop %d (%s) stands in a bulkhead, plant room, core or skylight" % [what, it["id"], it["type"]])
		if not feet.has(bi):
			feet[bi] = []
		for o: Array in feet[bi]:
			check((o[0] as Vector2).distance_to(at) >= float(o[1]) + foot, "%s: roof prop %d overlaps another" % [what, it["id"]])
		(feet[bi] as Array).append([at, foot])
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		var tiers: Array = b["tiers"]
		for ti in tiers.size():
			var sky: Array[Rect2] = []
			for so: Dictionary in b["solids"]:
				if so["kind"] == "skylight" and absf(float(so["y0"]) - float(tiers[ti]["y1"])) < 0.01:
					var r := Rect2((so["off"] as Vector2) - (so["size"] as Vector2) * 0.5, so["size"])
					check(plan.roof_rect(i, ti).encloses(r), "%s: building %d skylight inside its roof" % [what, i])
					for u in tiers.size():
						if u != ti and absf(float(tiers[u]["y0"]) - float(tiers[ti]["y1"])) < 0.01:
							check(not plan.roof_rect(i, u).intersects(r), "%s: building %d skylight overlaps an upper tier" % [what, i])
					for o in sky:
						check(not o.intersects(r), "%s: building %d skylights overlap" % [what, i])
					sky.append(r)
		if b["style"] == "office":
			var top: Dictionary = tiers[CityBuildings.plan_top(b)]
			var big := minf((top["size"] as Vector2).x, (top["size"] as Vector2).y) >= 9.0
			var plant: Dictionary = tiers[-1] if str(tiers[-1].get("kind", "")) == "plant" else {}
			eq(not plant.is_empty(), big, "%s: office %d has a plant room exactly when its top roof is big" % [what, i])
			if not plant.is_empty():
				near(float(plant["y0"]), float(top["y1"]), 1e-4, "%s: the plant room stands on the top roof" % what)
				near(float(plant["y1"]) - float(plant["y0"]), 2.4, 1e-4, "%s: the plant room is 2.4 m tall" % what)
		if b["style"] == "civic":
			check(b.has("gable"), "%s: the civic hall has its gable in the plan" % what)


func _ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b))


## The solid roof structure: rays onto the civic gable and portico, into its columns and steps, onto every plant room
## and skylight, into every park column's ring.
func _rooftops(seed_: int) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": seed_})
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var g0 := d.global_transform
	var what := "seed %d" % seed_
	var counts := {"gable": 0, "column": 0, "step": 0, "plant": 0, "skylight": 0, "ring": 0}
	for i in d.plan.buildings.size():
		var b: Dictionary = d.plan.buildings[i]
		var xf := g0 * d.building_frame(i)
		if b.has("gable"):
			var g: Dictionary = b["gable"]
			var gx := g0 * CityBuildings.gable_frame(d.building_frame(i), g)
			var w := float(g["w"])
			var dd := float(g["d"])
			var rise := float(g["rise"])
			for z: float in [dd * 0.5 - 1.0, dd * 0.25, 0.0, -dd * 0.25, -dd * 0.5 + 1.0]:
				for u: float in [-0.42, -0.25, -0.1, 0.0, 0.1, 0.25, 0.42]:
					var x := u * w
					var hit := _ray(space, gx * Vector3(x, rise + 3.0, z), gx * Vector3(x, -3.0, z))
					var want := rise * (1.0 - absf(x) / (w * 0.5))
					if check(not hit.is_empty(), "%s: the gable is solid at (%.1f, %.1f)" % [what, x, z]):
						var lp: Vector3 = gx.affine_inverse() * (hit["position"] as Vector3)
						near(lp.y, want, 0.1, "%s: the gable at (%.1f, %.1f) is at its drawn height" % [what, x, z])
					counts["gable"] += 1
			# Under the portico: the entablature is a ceiling over the columns.
			var n2: Vector2 = CityPlan.SIDE_N[int(g["front"])]
			var off: Vector2 = g["off"]
			var under := Vector2(off.x, off.y) + n2 * (dd * 0.5 - 2.6)
			var up_hit := _ray(space, xf * Vector3(under.x, 3.0, under.y), xf * Vector3(under.x, float(g["y0"]) + 5.0, under.y))
			if check(not up_hit.is_empty(), "%s: the portico has a ceiling" % what):
				near((xf.affine_inverse() * (up_hit["position"] as Vector3)).y, float(g["y0"]) - 1.2, 0.1, "%s: the entablature's underside" % what)
		for so: Dictionary in b["solids"]:
			var off: Vector2 = so["off"]
			var sz: Vector2 = so["size"]
			var y0 := float(so["y0"])
			var y1 := float(so["y1"])
			match str(so["kind"]):
				"column":
					var n2: Vector2 = CityPlan.SIDE_N[int(b["front"])]
					var from := off + n2 * 4.0
					var mid := (y0 + y1) * 0.5
					var hit := _ray(space, xf * Vector3(from.x, mid, from.y), xf * Vector3(off.x, mid, off.y))
					if check(not hit.is_empty(), "%s: a portico column is solid" % what):
						var lp: Vector3 = xf.affine_inverse() * (hit["position"] as Vector3)
						check(Vector2(lp.x, lp.z).distance_to(off) < 0.75, "%s: hit on the column's face" % what)
					counts["column"] += 1
				"step":
					var n2: Vector2 = CityPlan.SIDE_N[int(b["front"])]
					var along := sz.x if absf(n2.x) > 0.5 else sz.y
					var tread := off + n2 * (along * 0.5 - 0.275)
					var hit := _ray(space, xf * Vector3(tread.x, 3.0, tread.y), xf * Vector3(tread.x, -1.0, tread.y))
					if check(not hit.is_empty(), "%s: a front step is solid" % what):
						near((xf.affine_inverse() * (hit["position"] as Vector3)).y, y1, 0.06, "%s: the step's tread height" % what)
					counts["step"] += 1
				"skylight":
					var hit := _ray(space, xf * Vector3(off.x, y1 + 4.0, off.y), xf * Vector3(off.x, y0 - 1.0, off.y))
					if check(not hit.is_empty(), "%s: a skylight is solid" % what):
						near((xf.affine_inverse() * (hit["position"] as Vector3)).y, y1, 0.06, "%s: the skylight's curb height (0.4 m)" % what)
					counts["skylight"] += 1
		for t: Dictionary in b["tiers"]:
			if str(t.get("kind", "")) != "plant":
				continue
			var off: Vector2 = t["off"]
			var y1 := float(t["y1"])
			var hit := _ray(space, xf * Vector3(off.x, y1 + 4.0, off.y), xf * Vector3(off.x, y1 - 1.0, off.y))
			if check(not hit.is_empty(), "%s: office %d's plant room is solid" % [what, i]):
				near((xf.affine_inverse() * (hit["position"] as Vector3)).y, y1, 0.05, "%s: you stand on the plant room at its top" % what)
			var side := off + Vector2((t["size"] as Vector2).x * 0.5 + 2.0, 0.0)
			var mid := (float(t["y0"]) + y1) * 0.5
			check(not _ray(space, xf * Vector3(side.x, mid, side.y), xf * Vector3(off.x, mid, off.y)).is_empty(), "%s: the plant room's wall is solid" % what)
			counts["plant"] += 1
	for c: Dictionary in d.plan.columns:
		var cf := g0 * Transform3D(CityGeo.frame_basis(d.ring, float(c["s"])), d.ring.arc_to_world(c["x"], c["s"], CityPlan.CURB_H))
		var r := float(c["ring_r"])
		var hit := _ray(space, cf * Vector3(r + 3.0, 0.3, 0.0), cf * Vector3(0.0, 0.3, 0.0))
		if check(not hit.is_empty(), "%s: a park column's ring is solid" % what):
			var lp: Vector3 = cf.affine_inverse() * (hit["position"] as Vector3)
			check(lp.x <= r + 0.1 and lp.x >= r * 0.9, "%s: the ring is hit at its rim (%.2f of %.2f)" % [what, lp.x, r])
		counts["ring"] += 1
	print("%s rooftops: %s, shapes %d" % [what, str(counts), int(d.stats["shapes"])])
	check(int(counts["gable"]) > 0 and int(counts["column"]) >= 4 and int(counts["step"]) == 4, "%s: the civic hall was tested" % what)
	d.queue_free()
	await frames(1)


## A mech (the test drive's capsule: radius 2.2, 8 m, steps up 1.2 m) walks across a skylight on a roof.
func _skylight_walk() -> void:
	for seed_ in [1, 2, 3, 4, 5]:
		var plan := CityPlan.make({"seed": seed_})
		for i in plan.buildings.size():
			var b: Dictionary = plan.buildings[i]
			for ti in (b["tiers"] as Array).size():
				var y := float(b["tiers"][ti]["y1"])
				for so: Dictionary in b["solids"]:
					if so["kind"] != "skylight" or absf(float(so["y0"]) - y) > 0.01:
						continue
					var off: Vector2 = so["off"]
					var sz: Vector2 = so["size"]
					for dir: Vector2 in [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]:
						var lane := Rect2(off - dir * 5.5, Vector2.ZERO).expand(off + dir * 5.5).grow(2.3)
						if not plan.roof_rect(i, ti).encloses(lane):
							continue
						var free := true
						for q in plan.roof_blockers(i, ti):
							if q.intersects(lane) and not q.is_equal_approx(Rect2(off - sz * 0.5, sz)):
								free = false
						if free:
							await _walk_over(seed_, i, y, off, dir, float(so["y1"]))
							return
	check(false, "found a skylight with room to walk across it")


func _walk_over(seed_: int, i: int, y: float, off: Vector2, dir: Vector2, top: float) -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": seed_})
	var xf := d.global_transform * d.building_frame(i)
	var m := MechController.new()
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 2.2
	cap.height = 8.0
	shape.shape = cap
	shape.position = Vector3(0, 4.0, 0)
	m.add_child(shape)
	m.ring = d.ring
	m.max_step_up = 1.2
	m.walk_speed = 4.0
	add_child(m)
	m.set_physics_process(false)
	var start := off - dir * 5.0
	var fwd := (xf.basis * Vector3(dir.x, 0, dir.y)).normalized()
	var up := (xf.basis * Vector3.UP).normalized()
	m.global_transform = Transform3D(Basis(up.cross(-fwd).normalized(), up, -fwd), xf * Vector3(start.x, y + 0.05, start.y))
	await frames(2)
	m.move_input = Vector2(0, 1)
	var peak := -INF
	var along := 0.0
	for k in 360:
		await get_tree().physics_frame
		m.step(1.0 / 60.0)
		var lp: Vector3 = xf.affine_inverse() * m.global_position
		peak = maxf(peak, lp.y)
		along = (Vector2(lp.x, lp.z) - off).dot(dir)
		if along > 3.8:
			break
	print("skylight walk: seed %d building %d, peak %.2f over roof %.2f (ridge %.2f), got %.1f m past it" % [seed_, i, peak, y, top, along])
	check(along > 3.8, "a mech walks across a skylight (got to %.1f m past its middle)" % along)
	check(peak > y + 0.3, "and steps up onto it rather than through it (peak %.2f m above the roof)" % (peak - y))
	m.queue_free()
	d.queue_free()
	await frames(1)


func _check_deck(section: SectionPlan, deck: int, what: String) -> void:
	var plan := CityPlan.for_deck(section, deck)
	_check_plan(plan, what)
	near(plan.p("radius"), section.radius_of(deck), 0.001, "%s: the deck's radius" % what)
	near(plan.p("ceiling"), section.clear_height(), 0.001, "%s: the section's clear height" % what)
	check(plan.extent.is_equal_approx(Rect2(-section.p("width") * 0.5, -section.arc_of(deck) * 0.5, section.p("width"), section.arc_of(deck))),
			"%s: the extent is the deck's ground" % what)
	# One block per cell, with the cell's rect and zone.
	eq(plan.blocks.size(), section.cols * section.rows, "%s: one block per cell" % what)
	for b: Dictionary in plan.blocks:
		var c: int = b["ix"]
		var r: int = b["is"]
		check((b["rect"] as Rect2).is_equal_approx(section.cell_rect(deck, c, r)), "%s: block %d,%d has its cell's rect" % [what, c, r])
		eq(b["zone"], section.zone(deck, c, r), "%s: block %d,%d has its cell's zone" % [what, c, r])
	# Every section pillar is built at its exact point, as a tower or a park column.
	for q: Dictionary in section.pillars:
		var at := section.pillar_point(deck, int(q["id"]))
		var found := false
		for b: Dictionary in plan.buildings:
			if b["pillar"] and Vector2(b["core"]["x"], b["core"]["s"]).distance_to(at) < 0.01:
				found = true
		for col: Dictionary in plan.columns:
			if Vector2(col["x"], col["s"]).distance_to(at) < 0.01:
				found = true
		check(found, "%s: section pillar %d is built at its point" % [what, int(q["id"])])
	# Nothing stands in a floor hole or on ground kept clear.
	var holes: Array[Rect2] = plan.site.floor_holes
	var raw := 0
	for ci in section.connectors.size():
		if section.is_hole(ci, deck):
			raw += 1
	check(holes.size() >= raw, "%s: every floor hole of the section is cut (%d of %d)" % [what, holes.size(), raw])
	var no_go: Array[Rect2] = []
	no_go.append_array(holes)
	no_go.append_array(plan.site.keep_clear)
	for b: Dictionary in plan.buildings:
		var foot := Rect2((b["center"] as Vector2) - (b["size"] as Vector2) * 0.5, b["size"])
		for o in no_go:
			check(not foot.intersects(o), "%s: a %s building stands in a hole or on kept-clear ground" % [what, b["style"]])
	for it: Dictionary in CityProps.layout(plan):
		for o in no_go:
			check(not o.has_point(Vector2(it["x"], it["s"])), "%s: prop %d (%s) stands in a hole or on kept-clear ground" % [what, it["id"], it["type"]])
	# The walls are the section's: kinds and gates.
	var sides := plan.boundary()
	eq(sides.size(), 4, "%s: four walls" % what)
	for w: Dictionary in sides:
		var src := section.boundary(deck, CityPlan.SIDE_EDGE[int(w["side"])])
		# A section window that would look out at a backdrop is a vertical farm (docs/design/city-styles.md): no backdrop.
		var farm: bool = src["kind"] == "window" and bool(src["backdrop"])
		eq(w["kind"], "farm" if farm else src["kind"], "%s: wall %d is a %s" % [what, w["side"], "farm" if farm else src["kind"]])
		eq((w["gates"] as Array).size(), (src["gates"] as Array).size(), "%s: wall %d has the section's gates" % [what, w["side"]])
		eq(bool(w["backdrop"]), bool(src["backdrop"]) and not farm, "%s: wall %d backdrop as the section says (none behind a farm)" % [what, w["side"]])
	eq(plan.checksum(), CityPlan.for_deck(section, deck).checksum(), "%s: same inputs, same checksum" % what)
	check(plan.checksum() != CityPlan.for_deck(section, (deck + 1) % section.deck_count).checksum(), "%s: another deck, another checksum" % what)


## The structure can come from the mission section plan: its pillars are built exactly where it says, on any deck.
func _section_site() -> void:
	var section := SectionPlan.make({"seed": 4})
	for deck in section.deck_count:
		var origin := Vector2((section.lane_x("avenue").x + section.lane_x("avenue").y) * 0.5, section.line_s(deck, section.rows / 2))
		var given := CitySite.from_section(section, deck, origin, Vector2(150.0, 150.0))
		check(given.pillars.size() >= 2, "deck %d: the section gives this district pillars (%d)" % [deck, given.pillars.size()])
		var plan := CityPlan.make({"seed": 4, "size_x": 300.0, "size_s": 300.0, "radius": section.radius_of(deck), "ceiling": section.clear_height()}, given)
		var built := plan.columns.size()
		for b: Dictionary in plan.buildings:
			if b["pillar"]:
				built += 1
		print("section deck %d: %d pillars given, %d built, %d dropped, %d openings" % [deck, given.pillars.size(), built, plan.dropped_pillars, given.openings.size()])
		check(built >= given.pillars.size() - plan.dropped_pillars and built > 0, "deck %d: the given pillars are built" % deck)
		eq(plan.checksum(), CityPlan.make({"seed": 4, "size_x": 300.0, "size_s": 300.0, "radius": section.radius_of(deck), "ceiling": section.clear_height()}, given).checksum(), "deck %d: same structure, same plan" % deck)


func _determinism() -> void:
	var a := CityPlan.make({"seed": 11})
	var b := CityPlan.make({"seed": 11})
	var c := CityPlan.make({"seed": 12})
	eq(a.checksum(), b.checksum(), "same seed, same checksum")
	check(a.checksum() != c.checksum(), "another seed, another checksum")
	check(a.checksum() != CityPlan.make({"seed": 11, "radius": 150.0}).checksum(), "the ring radius is part of the plan")
	check(a.checksum() != CityPlan.make({"seed": 11, "band_step": 5.0}).checksum(), "the height bands are part of the plan")
	eq(a.checksum().length(), 16, "checksum is 16 hex digits")


func _check_plan(plan: CityPlan, what: String) -> void:
	var ceiling := plan.p("ceiling")
	check(plan.blocks.size() >= 4, "%s: at least four blocks (%d)" % [what, plan.blocks.size()])
	check(plan.buildings.size() >= 4, "%s: has buildings (%d)" % [what, plan.buildings.size()])
	# Every lot has a building or is open space, and sits inside its block's building line.
	var built := 0
	for li in plan.lots.size():
		var l: Dictionary = plan.lots[li]
		var has_building: bool = int(l["building"]) >= 0
		var is_open: bool = l["kind"] == "open" and l["open"] != ""
		check(has_building != is_open, "%s: lot %d is a building or open space, not neither or both" % [what, li])
		if has_building:
			built += 1
			eq(int(plan.buildings[l["building"]]["lot"]), li, "%s: lot and building point at each other" % what)
		var zone: Rect2 = (plan.blocks[l["block"]]["rect"] as Rect2).grow(-CityPlan.SIDEWALK + 0.01)
		check(zone.encloses(l["rect"]), "%s: lot %d inside its block" % [what, li])
	eq(built, plan.buildings.size(), "%s: every building has a lot" % what)
	for i in plan.lots.size():
		for j in range(i + 1, plan.lots.size()):
			check(not (plan.lots[i]["rect"] as Rect2).grow(-0.01).intersects(plan.lots[j]["rect"]), "%s: lots %d and %d overlap" % [what, i, j])
	# Heights: only pillars and downtown shafts reach the ceiling; a standable roof leaves room for a mech. Footprints stay
	# inside their lot.
	var r := plan.p("radius")
	var limit := plan.stand_limit()
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		var lot: Rect2 = plan.lots[b["lot"]]["rect"]
		var c: Vector2 = b["center"]
		var size: Vector2 = b["size"]
		if b["pillar"]:
			check(plan.top_of(i) >= ceiling, "%s: pillar %d reaches the ceiling" % [what, i])
			# The core stands exactly on its structural point, inside its lot, clear of every road.
			var core: Dictionary = b["core"]
			var at := Vector2(core["x"], core["s"])
			var found := false
			for q: Dictionary in plan.site.pillars:
				if Vector2(q["x"], q["s"]).is_equal_approx(at):
					found = true
			check(found, "%s: pillar %d stands on a structural point" % [what, i])
			check(lot.grow(-float(core["half"]) + 0.01).has_point(at), "%s: pillar %d core inside its lot" % [what, i])
		else:
			check(float(b["roof_h"]) >= 6.0, "%s: building %d has a roof height" % [what, i])
			check(size.x >= 4.0 and size.y >= 4.0, "%s: building %d has a usable footprint %s" % [what, i, size])
		check(lot.grow(0.01).encloses(Rect2(c - size * 0.5, size)), "%s: building %d inside its lot" % [what, i])
		for t: Dictionary in b["tiers"]:
			var top: float = t["y1"]
			if str(t.get("kind", "")) == "tower":
				# A downtown shaft (docs/design/city-downtown.md) reaches into the ceiling slab, never standable.
				check(b["style"] == "tower" and top >= ceiling and not t["stand"], "%s: building %d shaft meets the ceiling, not standable" % [what, i])
			else:
				check(top <= ceiling - 2.0, "%s: building %d (%s) tier top %.1f under the ceiling" % [what, i, b["style"], top])
			if t["stand"]:
				check(top <= limit + 0.01, "%s: building %d standable roof %.1f leaves %.1f m for a mech" % [what, i, top, plan.p("clearance")])
			# Standing radially, the tier's top must still be inside the lot's arc span (walls lean together on a ring).
			var reach := (absf((t["off"] as Vector2).y) + (t["size"] as Vector2).y * 0.5) * r / (r - top)
			check(c.y - reach >= lot.position.y - 0.05 and c.y + reach <= lot.end.y + 0.05, "%s: building %d leans out of its lot" % [what, i])
	# Structure: every given pillar is built (tower or park column), none was dropped, none stands in a road.
	eq(plan.dropped_pillars, 0, "%s: no structural pillar was dropped" % what)
	var built_pillars := plan.columns.size()
	for b: Dictionary in plan.buildings:
		if b["pillar"]:
			built_pillars += 1
	eq(built_pillars, plan.site.pillars.size(), "%s: every structural pillar is built" % what)
	for q: Dictionary in plan.site.pillars:
		for road: Dictionary in plan.roads_x:
			check(float(q["x"]) + float(q["half"]) < float(road["a"]) or float(q["x"]) - float(q["half"]) > float(road["b"]), "%s: a pillar stands in a road" % what)
		for road: Dictionary in plan.roads_s:
			check(float(q["s"]) + float(q["half"]) < float(road["a"]) or float(q["s"]) - float(q["half"]) > float(road["b"]), "%s: a pillar stands in a cross street" % what)
	if what.begins_with("seed"):
		check(plan.site.pillars.size() >= 2, "%s: the default district has pillars (%d)" % [what, plan.site.pillars.size()])
	# Roads: the graph is one piece, with a crossing wherever two roads meet.
	var g := CityGraphs.road_graph(plan)
	var nodes: Array = g["nodes"]
	var seen := {0: true}
	var queue := [0]
	while not queue.is_empty():
		var n: int = queue.pop_back()
		for e: Array in g["edges"]:
			var other := -1
			if e[0] == n:
				other = e[1]
			elif e[1] == n:
				other = e[0]
			if other >= 0 and not seen.has(other):
				seen[other] = true
				queue.append(other)
	eq(seen.size(), nodes.size(), "%s: every crossing is reachable by road" % what)
	eq(nodes.size(), plan.roads_x.size() * plan.roads_s.size(), "%s: a crossing wherever two roads meet" % what)
	# Every block has a road on all four sides (so every lot can be reached from the street).
	for b: Dictionary in plan.blocks:
		var br: Rect2 = b["rect"]
		check(_road_at(plan.roads_x, br.position.x, true) and _road_at(plan.roads_x, br.end.x, false)
				and _road_at(plan.roads_s, br.position.y, true) and _road_at(plan.roads_s, br.end.y, false), "%s: block has a road on each side" % what)
	# Rooftop hopping: every ordinary roof can be reached.
	var ok := plan.reachable_roofs()
	for i in plan.buildings.size():
		if not plan.buildings[i]["pillar"]:
			check(ok[i], "%s: roof %d (band %d) can't be reached" % [what, i, int(plan.buildings[i]["band"])])


func _road_at(roads: Array, at: float, ends_here: bool) -> bool:
	for r: Dictionary in roads:
		if absf(float(r["b"] if ends_here else r["a"]) - at) < 0.01:
			return true
	return false


func _district() -> void:
	var small := {"seed": 3, "size_x": 100.0, "size_s": 110.0}
	var d := CityDistrict.new()
	add_child(d)
	small["atrium"] = 1.0
	d.build(small)
	await frames(1)
	eq(d.plan.site.openings.size(), 1, "the atrium opens the ceiling over the park")
	var styles := {}
	for b: Dictionary in CityPlan.make({"seed": 3}).buildings:
		styles[b["style"]] = true
	check(styles.size() >= 4, "the default district shows at least four styles (%s)" % str(styles.keys()))
	check(d.stats["triangles"] > 5000, "it has geometry (%d triangles)" % d.stats["triangles"])
	check(d.stats["shapes"] > d.plan.buildings.size(), "it has collision (%d shapes)" % d.stats["shapes"])
	check(d.get_node_or_null("Ground") != null and d.get_node_or_null("Ceiling") != null and d.get_node_or_null("Furniture") != null,
			"ground, ceiling and furniture exist")
	# Lighting is separate from surface colour: relighting changes the rig and nothing else.
	var digest := d.geometry_digest()
	var albedo := CityPalette.surface_material()
	check(albedo.vertex_color_use_as_albedo and not albedo.emission_enabled, "surfaces are flat vertex colour, lit, no glow")
	var looks := {}
	for id in CityLightRig.preset_ids():
		d.rig.apply(id)
		looks[d.rig.sun.light_color.to_html() + d.rig.env.background_color.to_html()] = true
		eq(d.geometry_digest(), digest, "relighting to %s leaves the geometry alone" % id)
	check(looks.size() >= 3, "at least three different lighting set-ups")
	# Boundary walls: a gate on every road that reaches a bulkhead, and the wall is solid.
	check(d.plan.boundary().is_empty(), "no walls unless asked")
	var w := CityDistrict.new()
	add_child(w)
	w.build({"seed": 3, "size_x": 100.0, "size_s": 110.0, "walls": 1.0})
	var sides := w.plan.boundary()
	eq(sides.size(), 4, "a walled district has four sides")
	for side: Dictionary in sides:
		eq((side["gates"] as Array).size(), w.plan.roads_x.size() if side["kind"] == "bulkhead" else 0, "a gate where each road meets a bulkhead")
	check(w.get_node_or_null("Walls") != null and w.get_node_or_null("Backdrop") == null, "walls replace the backdrop")
	check(w.plan.checksum() != CityPlan.make({"seed": 3, "size_x": 100.0, "size_s": 110.0}).checksum(), "walls are part of the plan")
	await frames(2)
	var wspace := w.get_world_3d().direct_space_state
	var end_s := w.plan.extent.end.y
	var from := w.ring.arc_to_world(0.0, end_s - 10.0, 5.0)
	var to := w.ring.arc_to_world(0.0, end_s + 10.0, 5.0)
	check(not wspace.intersect_ray(PhysicsRayQueryParameters3D.create(from, to)).is_empty(), "the avenue's gate is sealed (solid)")
	var side_x := w.plan.extent.end.x
	check(not wspace.intersect_ray(PhysicsRayQueryParameters3D.create(w.ring.arc_to_world(side_x - 5.0, 3.0, 20.0), w.ring.arc_to_world(side_x + 8.0, 3.0, 20.0))).is_empty(), "the hull wall is solid")
	w.queue_free()
	# The same seed builds the same vertices; another seed doesn't.
	var e := CityDistrict.new()
	e.with_rig = false
	add_child(e)
	e.build(small)
	eq(e.geometry_digest(), digest, "same seed, same vertices and colours")
	check(e.rig == null, "a district can be built without the rig")
	e.build({"seed": 4, "size_x": 100.0, "size_s": 110.0})
	check(e.geometry_digest() != digest, "another seed, other vertices")
	# A foot on the avenue stands on the deck: something solid under the origin.
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0, 5, 0), Vector3(0, -5, 0)))
	check(not hit.is_empty() and absf((hit["position"] as Vector3).y) < 0.05, "the road at the origin is solid at height 0")
	for s in [0.0, 4.0, 22.0, -31.0]:      # facet creases included: a ray down a seam must not slip through
		var top := d.ring.arc_to_world(0.0, s, 3.0)
		var under := d.ring.arc_to_world(0.0, s, -3.0)
		check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(top, under)).is_empty(), "the avenue is solid at s=%s" % s)
	print("district: ", d.stats)
	d.queue_free()
	e.queue_free()


## Seed 1 deck 0 has a ramp cut (bridged by the cross roads), a shaft, an entry portal and blast doors.
func _section_district() -> void:
	var section := SectionPlan.make({"seed": 1})
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	for deck in section.deck_count:
		d.build_deck(section, deck)
		var built := d.plan.columns.size()
		for b: Dictionary in d.plan.buildings:
			if b["pillar"]:
				built += 1
		print("section 1 deck %d: %d blocks, %d buildings, pillars %d given %d built %d dropped, %d floor holes, %d ceiling openings, %s" % [
				deck, d.plan.blocks.size(), d.plan.buildings.size(), d.plan.site.pillars.size(), built, d.plan.dropped_pillars,
				d.plan.site.floor_holes.size(), d.plan.site.openings.size(), str(d.stats)])
	d.build_deck(section, 0)
	check(d.get_node_or_null("Walls") != null and d.get_node_or_null("Ground") != null, "a section deck has walls and ground")
	eq(d.get_node_or_null("Backdrop") != null, d.plan.boundary().any(func(w: Dictionary) -> bool: return w["backdrop"]),
			"a backdrop only beyond window walls")
	await frames(2)
	var space := d.get_world_3d().direct_space_state
	var ring := d.ring
	var down := func(x: float, s: float) -> Dictionary:
		return space.intersect_ray(PhysicsRayQueryParameters3D.create(ring.arc_to_world(x, s, 5.0), ring.arc_to_world(x, s, -5.0)))
	var shaft := Rect2()
	var ramp: Array[Rect2] = []
	for o: Rect2 in d.plan.site.floor_holes:
		if o.size.x > 20.0:
			shaft = o
		else:
			ramp.append(o)
	check(shaft.has_area() and ramp.size() >= 2, "deck 0 has a shaft and a ramp cut in pieces (%d)" % ramp.size())
	check((down.call(shaft.get_center().x, shaft.get_center().y) as Dictionary).is_empty(), "a ray down the shaft hits nothing within 10 m")
	for o in ramp:
		check((down.call(o.get_center().x, o.get_center().y) as Dictionary).is_empty(), "a ray down the ramp cut at s=%.0f hits nothing" % o.get_center().y)
	var x := ramp[0].get_center().x
	# Cross roads bridge the cut except where a mech would not fit under them (CityPlan.BRIDGE_CLEAR: the first past the
	# ramp's head): there the cut runs on under the road.
	var bridged := 0
	var open := 0
	for road: Dictionary in d.plan.roads_s:
		var s := (float(road["a"]) + float(road["b"])) * 0.5
		if s > ramp[0].position.y and s < ramp[-1].end.y:
			var hit: Dictionary = down.call(x, s)
			var cut := false
			for o in ramp:
				cut = cut or o.has_point(Vector2(x, s))
			if cut:
				check(hit.is_empty(), "the cross road at s=%.0f is too low over the ramp: the cut runs on under it" % s)
				open += 1
			else:
				check(not hit.is_empty() and absf(ring.height(hit["position"])) < 0.1, "the cross road at s=%.0f bridges the ramp cut" % s)
				bridged += 1
	check(bridged >= 1, "a cross road bridges the ramp cut (%d)" % bridged)
	check(open >= 1, "the first cross road past the ramp's head does not (%d)" % open)
	# Gates: through the portal is the way out; a blast door is solid.
	var portal := 0
	var sealed := 0
	for w: Dictionary in d.plan.boundary():
		if int(w["side"]) < 2:
			continue
		var inward := -1.0 if int(w["side"]) == 2 else 1.0
		var at: float = w["at"]
		for g: Dictionary in w["gates"]:
			var gx := (float(g["a"]) + float(g["b"])) * 0.5
			var ray := PhysicsRayQueryParameters3D.create(ring.arc_to_world(gx, at + inward * 10.0, 4.0), ring.arc_to_world(gx, at - inward * 10.0, 4.0))
			var hit := space.intersect_ray(ray)
			if g["kind"] == "portal":
				# 2026-11-23 (map sealed): was "a ray through the portal hits nothing"; a mech walked out that way and
				# fell off the map. Now the ray goes into the recess and stops at its back plate (test_map_sealed).
				var beyond := -inward * (ring.world_to_arc(hit["position"]).y - at) if not hit.is_empty() else INF
				check(not hit.is_empty() and absf(beyond - CityWalls.GATE_RECESS) < 0.3,
						"a ray through the portal goes into the recess and stops at its back plate (%.1f m past the wall plane)" % beyond)
				portal += 1
			elif g["kind"] == "blast_door":
				check(not hit.is_empty(), "a ray into a blast door hits the wall")
				sealed += 1
	check(portal >= 1 and sealed >= 1, "deck 0 has a portal (%d) and a blast door (%d)" % [portal, sealed])
	d.queue_free()
