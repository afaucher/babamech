extends TestCase
## Deck lettering (CitySigns, docs/design/city-signs.md) on every deck of sections 1, 4 and 403112: the number is the deck
## index + 1 on every sign; every gate of a bulkhead / farm wall has a sign beside it, every freight lift one over its door,
## every ramp one at both ends with the right arrow and destination; wall signs lie inside their wall, off every gate
## opening and every other sign, above the floor and under the ceiling; every vertex of every sign (both looks) lies on or
## in front of its surface within its panel and decal depth, inside its footprint. Both looks build, "off" builds nothing;
## the plan checksum, the collision and geometry_digest() are the same with lettering on and off; a district on its own
## has none.

const SEEDS := [1, 4, 403112]


func setup() -> void:
	timeout_sec = 240.0
	var old_style := CitySigns.style
	eq(old_style, "dark", "the default look is dark (the user's pick 2026-11-24, cell 6)")
	for seed_: int in SEEDS:
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			_deck(sec, seed_, k)
	await _district_on_off()
	_alone()
	CitySigns.style = old_style
	finish()


func _deck(sec: SectionPlan, seed_: int, k: int) -> void:
	var what := "section %d deck %d" % [seed_, k]
	var plan := CityPlan.for_deck(sec, k)
	var ring := RingFrame.new(plan.p("radius"))
	var signs := CitySigns.layout(plan, ring)
	var ceiling := plan.p("ceiling")
	var counts := {"wall": 0, "over_gate": 0, "lift": 0, "ramp": 0, "shaft": 0}
	var numbers_ok := true
	for s: Dictionary in signs:
		counts[s["kind"]] += 1
		if s["kind"] == "wall" or s["kind"] == "lift" or s["kind"] == "over_gate":
			numbers_ok = numbers_ok and int(s["number"]) == k + 1 and s["arrow"] == ""
		else:
			numbers_ok = numbers_ok and (s["back"] as Dictionary).has("number")
			if s["kind"] == "ramp":
				numbers_ok = numbers_ok and int(s["back"]["number"]) == k + 1
	check(numbers_ok, "%s: every sign shows deck %s (ramp backs too)" % [what, CitySigns.label(k + 1)])
	# Every gate of a bulkhead / farm wall has a sign beside it.
	var gi := 0
	var missing := []
	for w: Dictionary in plan.boundary():
		for g: Dictionary in w["gates"]:
			if w["kind"] == "bulkhead" or w["kind"] == "farm":
				var found := false
				for s: Dictionary in signs:
					found = found or (s["kind"] == "wall" and int(s["gate"]) == gi)
				if not found:
					missing.append("%d:%s %.0f..%.0f" % [int(w["side"]), str(g["kind"]), float(g["a"]), float(g["b"])])
			gi += 1
	check(missing.is_empty(), "%s: a sign beside every wall gate (missing %s)" % [what, str(missing)])
	_over_gates(plan, signs, what)
	# Every freight lift door.
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if b["pillar"] and str(b["core"]["kind"]) == "lift":
			var found := false
			for s: Dictionary in signs:
				found = found or (s["kind"] == "lift" and int(s["pillar"]) == i)
			check(found, "%s: lift %d has a sign" % [what, i])
	# Both ends of every ramp: arrow and destination.
	for ri in plan.ramps.size():
		var r: Dictionary = plan.ramps[ri]
		var cn: Dictionary = sec.connectors[int(r["connector"])]
		var top: bool = r["role"] == "top"
		var found := {}
		for s: Dictionary in signs:
			if s["kind"] == "ramp" and int(s["ramp"]) == ri:
				found = s
		if not check(not found.is_empty(), "%s: ramp %d (%s) has a sign" % [what, ri, r["role"]]):
			continue
		eq(found["arrow"], "down" if top else "up", "%s: ramp %d points %s" % [what, ri, "down" if top else "up"])
		eq(int(found["dest"]), (int(cn["to"]) + 1) if top else (int(cn["from"]) + 1), "%s: ramp %d names its destination" % [what, ri])
		eq(int(found["dest"]), k + 2 if top else k, "%s: ramp %d destination is the next deck" % [what, ri])
	# Shafts: arrow down to the deck below.
	for s: Dictionary in signs:
		if s["kind"] == "shaft":
			check(s["arrow"] == "down" and int(s["dest"]) == k + 2, "%s: shaft sign points down to %s" % [what, CitySigns.label(k + 2)])
	# Wall signs: inside the wall, off the gates and each other; every sign above the floor and under the ceiling.
	var place_ok := true
	var notes := []
	var e := plan.extent
	for w: Dictionary in plan.boundary():
		var side := int(w["side"])
		var u0 := e.position.x if side >= 2 else e.position.y
		var u1 := e.end.x if side >= 2 else e.end.y
		var mine := signs.filter(func(s: Dictionary) -> bool: return s["kind"] == "wall" and int(s["side"]) == side)
		for s: Dictionary in mine:
			if float(s["u0"]) < u0 + 1.0 or float(s["u1"]) > u1 - 1.0:
				place_ok = false
				notes.append("side %d sign outside the wall" % side)
			for g: Dictionary in w["gates"]:
				if float(s["u1"]) > float(g["a"]) - CitySigns.GATE_CLEAR + 0.01 and float(s["u0"]) < float(g["b"]) + CitySigns.GATE_CLEAR - 0.01:
					place_ok = false
					notes.append("side %d sign within %.0f m of a gate" % [side, CitySigns.GATE_CLEAR])
		var all_side := signs.filter(func(s: Dictionary) -> bool: return (s["kind"] == "wall" or s["kind"] == "over_gate") and int(s["side"]) == side)
		for s: Dictionary in all_side:
			for t: Dictionary in all_side:
				if t != s and float(s["u1"]) > float(t["u0"]) and float(s["u0"]) < float(t["u1"]) \
						and float(s["y1"]) > float(t["y0"]) and float(s["y0"]) < float(t["y1"]):
					place_ok = false
					notes.append("side %d signs overlap" % side)
	for s: Dictionary in signs:
		if float(s["y0"]) < 0.5 or float(s["y1"]) > ceiling - 2.0:
			place_ok = false
			notes.append("%s sign %.1f..%.1f m vs ceiling %.0f" % [s["kind"], float(s["y0"]), float(s["y1"]), ceiling])
	check(place_ok, "%s: signs inside their walls, off gates and each other, floor to ceiling (%s)" % [what, str(notes.slice(0, 4))])
	# Every vertex on / in front of its surface, inside its footprint (both looks).
	var tris := {}
	for st: String in ["white", "dark"]:
		var geo_ok := true
		var bad := ""
		var total := 0
		for s: Dictionary in signs:
			var geo := CityGeo.new(ring)
			CitySigns.build(geo, s, st)
			total += geo.tri_count()
			var inv := (s["xf"] as Transform3D).affine_inverse()
			var hang: bool = s["surface"] == "hang"
			var paint: bool = s["surface"] == "bulkhead" and st == "white"
			var zmin := (float(s["z0"]) - CitySigns.DECAL * 2.0 - 0.001) if hang else (-0.001 if paint else float(s["z0"]) - 0.001)
			var zmax := float(s["z1"]) + CitySigns.DECAL * 2.0 + 0.001
			if paint:
				zmax = CitySigns.DECAL * 2.0 + 0.001
			var ytop := float(s.get("ceiling", 0.0)) + 0.6 if hang else float(s["y1"]) + 0.01
			for v in geo.verts:
				var l := inv * v
				if l.z < zmin or l.z > zmax or absf(l.x) > float(s["w"]) * 0.5 + 0.01 or l.y < float(s["y0"]) - 0.01 or l.y > ytop:
					geo_ok = false
					bad = "%s %s vertex %s (z %.3f..%.3f, w %.1f, y %.1f..%.1f)" % [s["kind"], s["surface"], str(l), zmin, zmax, float(s["w"]), float(s["y0"]), ytop]
					break
			if not geo_ok:
				break
		tris[st] = total
		check(geo_ok, "%s (%s): every vertex on its surface within the decal depth and inside its footprint %s" % [what, st, bad])
	print("[signs] %s: %d signs (walls %d, over gates %d, lifts %d, ramps %d, shafts %d), triangles white %d / dark %d" % [what,
			signs.size(), counts["wall"], counts["over_gate"], counts["lift"], counts["ramp"], counts["shaft"], tris["white"], tris["dark"]])


## Every gate of a bulkhead / farm wall (portals too) has a sign centred over it: inside the gate's width (so inside the
## wall), its bottom over the gate's top + a bunker's lintel and beacons (4.7 m) and over a bulkhead's gallery band, under
## the ceiling. And it reads from the road that ends at the gate: from its centre line 40, 60 and 80 m out at 10 m up, no
## building tier of the plan stands between the eye and the sign's centre (plan data). Blocks by a ceiling-touching tower
## are listed, not failed.
var blocked_report: Array = []
func _over_gates(plan: CityPlan, signs: Array, what: String) -> void:
	var gi := 0
	var ceiling := plan.p("ceiling")
	for w: Dictionary in plan.boundary():
		for g: Dictionary in w["gates"]:
			if w["kind"] != "bulkhead" and w["kind"] != "farm":
				gi += 1
				continue
			var over := {}
			for s: Dictionary in signs:
				if s["kind"] == "over_gate" and int(s["gate"]) == gi:
					over = s
			var gname := "side %d %s %.0f..%.0f" % [int(w["side"]), str(g["kind"]), float(g["a"]), float(g["b"])]
			gi += 1
			if not check(not over.is_empty(), "%s: an over-gate sign at %s" % [what, gname]):
				continue
			check(float(over["u0"]) >= float(g["a"]) - 0.01 and float(over["u1"]) <= float(g["b"]) + 0.01,
					"%s: over-gate sign within the gate's width at %s" % [what, gname])
			check(float(over["y0"]) >= float(g["h"]) + 4.7 + 0.99 and float(over["y0"]) >= 16.6,
					"%s: over-gate sign (bottom %.1f) clears the gate top %.0f + lintel + beacons and the gallery band at %s" % [what, float(over["y0"]), float(g["h"]), gname])
			check(float(over["y1"]) <= ceiling - 3.0, "%s: over-gate sign under the ceiling at %s" % [what, gname])
			# Visibility from the road that ends at the gate.
			var at: Vector2 = over["at"]
			var nv: Vector2 = over["n"]
			var c := Vector3(at.x, at.y, float(over["h"]))
			for dist: float in [40.0, 60.0, 80.0]:
				var e := at + nv * dist
				var by := _blocker(plan, Vector3(e.x, e.y, 10.0), c)
				if by < 0:
					continue
				var b: Dictionary = plan.buildings[by]
				var tall: bool = b["style"] == "tower" or b["pillar"]
				var line := "%s %s from %.0f m: building %d (%s)" % [what, gname, dist, by, b["style"]]
				blocked_report.append(line)
				print("[signs] over-gate blocked: " + line)
				check(tall, "%s: over-gate sign at %s seen from %.0f m down its road (blocked by building %d, %s)" % [what, gname, dist, by, b["style"]])


## The first building whose tier box stands between arc points a and b (x, s, h), or -1.
func _blocker(plan: CityPlan, a: Vector3, b: Vector3) -> int:
	var n := int(ceil(Vector2(b.x - a.x, b.y - a.y).length() / 1.0))
	for i in range(1, n):
		var p := a.lerp(b, float(i) / float(n))
		for bi in plan.buildings.size():
			for t: Dictionary in plan.buildings[bi]["tiers"]:
				if p.z < float(t["y1"]) and plan.tier_rect(bi, t).has_point(Vector2(p.x, p.y)):
					return bi
	return -1


## A whole deck with lettering on and off: same plan checksum, collision and digest; DeckSigns only when on.
func _district_on_off() -> void:
	var sec := SectionPlan.make({"seed": 1})
	var res := {}
	for st: String in ["white", "dark", "off"]:
		CitySigns.style = st
		var d := CityDistrict.new()
		d.with_rig = false
		add_child(d)
		d.build_deck(sec, 1)
		var node := d.get_node_or_null("DeckSigns") as MeshInstance3D
		res[st] = {"sum": d.plan.checksum(), "shapes": d.get_node("Collision").get_child_count(), "digest": d.geometry_digest(),
				"node": node != null, "tris": int(d.stats.get("sign_triangles", -1)), "layer": node.layers == d.render_layer if node else true}
		# The look switch on a built district: rebuild_signs gives the same as a fresh build in that look.
		if st == "white":
			CitySigns.style = "dark"
			d.rebuild_signs()
			await frames(1)
			var dn := d.get_node_or_null("DeckSigns") as MeshInstance3D
			check(dn != null and d.get_children().filter(func(c: Node) -> bool: return str(c.name).begins_with("DeckSigns")).size() == 1,
					"rebuild_signs replaces the lettering (one DeckSigns)")
			res["white_to_dark"] = int(d.stats["sign_triangles"])
			CitySigns.style = st
		d.queue_free()
		await frames(1)
	for st: String in ["white", "dark"]:
		check(res[st]["node"] and res[st]["tris"] > 0, "%s look: a DeckSigns mesh (%d triangles)" % [st, res[st]["tris"]])
		check(res[st]["layer"], "%s look: DeckSigns on the district's render layer" % st)
		eq(res[st]["sum"], res["off"]["sum"], "%s look: plan checksum as with lettering off" % st)
		eq(res[st]["shapes"], res["off"]["shapes"], "%s look: collision shape count as with lettering off" % st)
		eq(res[st]["digest"], res["off"]["digest"], "%s look: geometry digest as with lettering off" % st)
	check(not res["off"]["node"] and res["off"]["tris"] == 0, "off: no DeckSigns")
	eq(res["white_to_dark"], res["dark"]["tris"], "switching white -> dark gives the dark look's triangles")


## A district on its own (no section) has no lettering; force_number gives it some.
func _alone() -> void:
	CitySigns.style = "white"
	var plan := CityPlan.make({"seed": 2.0, "walls": 1.0})
	var ring := RingFrame.new(plan.p("radius"))
	check(CitySigns.layout(plan, ring).is_empty(), "a district on its own: no lettering")
	check(CitySigns.build_node(plan, ring, 1) == null, "a district on its own: no DeckSigns node")
	CitySigns.force_number = 7
	var forced := CitySigns.layout(plan, ring)
	check(not forced.is_empty() and int(forced[0]["number"]) == 7, "force_number gives a district on its own its lettering")
	CitySigns.force_number = 0
	CitySigns.style = "off"
	var sec := SectionPlan.make({"seed": 1})
	var p2 := CityPlan.for_deck(sec, 0)
	check(CitySigns.build_node(p2, RingFrame.new(p2.p("radius")), 1) == null, "style off: build_node gives nothing")
