extends TestCase
## SectionPlan (docs/design/mission-section.md): deterministic and checksummed; a route from the entry to the lowest
## deck for vehicles AND for mechs; pillars line up between decks; every cell is reachable; no connection sits in a
## pillar it isn't housed in; the planner holds up across seeds and at the ends of every setting. Ramp bridges too low to
## walk under are gone from the road graph; road segment forms keep their always-street rules and the repair guarantees
## (vehicle network, a vehicle side on every cell, no stubs) even at extreme mixes, and move nothing rolled before them.

const SETTINGS := [
	{}, {"decks": 2.0}, {"decks": 5.0}, {"arc": 300.0}, {"arc": 900.0}, {"width": 160.0}, {"width": 450.0},
	{"radius": 150.0}, {"radius": 600.0}, {"cell": 60.0}, {"cell": 140.0}, {"ramp_grade": 0.08}, {"ramp_grade": 0.35},
	{"shafts": 0.0}, {"shafts": 3.0}, {"express": 0.0}, {"w_urban": 0.0, "w_park": 0.0, "w_industrial": 0.0},
	{"w_park": 2.0}, {"w_industrial": 2.0}, {"decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0},
	{"radius": 150.0, "decks": 5.0},     # small radius, many decks: lower decks much longer than the top one
]


func setup() -> void:
	_determinism()
	var kinds := {}
	var shafts := 0
	for seed_ in range(1, 41):
		var plan := SectionPlan.make({"seed": float(seed_)})
		_check_plan(plan, "seed %d" % seed_)
		for c: Dictionary in plan.connectors:
			kinds[c["kind"]] = true
			if c["kind"] == "shaft":
				shafts += 1
	for id: String in ["ramp", "lift", "shaft"]:
		check(kinds.has(id), "some seed uses a " + id)
	check(shafts >= 40 * 2, "default sections get a shaft on every deck but the lowest (%d over 40 seeds)" % shafts)
	for i in SETTINGS.size():
		for seed_ in [3, 11, 29]:
			var o: Dictionary = (SETTINGS[i] as Dictionary).duplicate()
			o["seed"] = float(seed_)
			_check_plan(SectionPlan.make(o), "settings %d seed %d" % [i, seed_])
	_deck_views()
	_geometry()
	_forms_sweep()
	_hop_only()
	finish()


## The hop-only rule (docs/design/mission-section.md "Walkable connectors"): a mech that walks, hops at most 6 m and never
## glides gets from every deck to the one below without a lift: a ramp, or a shaft whose drop lands on that deck's floor
## (not into the next hole down). Checked here from the connectors directly, independent of walkable_down(), over seeds
## 1..300 at 2, 3 and 5 decks, plus the whole critical path on a hop-only graph. Walking back up (ramps only) is counted.
func _hop_only() -> void:
	var up_missing := {}
	var repaired := {}
	for decks in [2, 3, 5]:
		up_missing[decks] = 0
		repaired[decks] = 0
		for seed_ in range(1, 301):
			var plan := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var tag := "hop-only seed %d x%d" % [seed_, decks]
			var key := "%d:%d" % [decks, seed_]
			if GOLDEN_UNCHANGED.has(key):
				eq(plan.checksum(), GOLDEN_UNCHANGED[key], tag + ": a plan that met the rule is byte-identical")
				eq(plan.walk_repairs.size(), 0, tag + ": nothing repaired")
			if GOLDEN_CHANGED.has(key):
				check(plan.checksum() != GOLDEN_CHANGED[key] and not plan.walk_repairs.is_empty(), tag + ": repaired")
			if not plan.walk_repairs.is_empty():
				repaired[decks] += 1
			eq(plan.validate().size(), 0, tag + ": validate() " + str(plan.validate()))
			for k in plan.deck_count - 1:
				var ci := _hop_down(plan, k)
				check(ci >= 0, "%s: deck %d walkable from deck %d" % [tag, k + 1, k])
				eq(plan.walkable_down_connector(k), ci, "%s: walkable_down_connector(%d)" % [tag, k])
				eq(plan.walkable_down(k), ci >= 0, "%s: walkable_down(%d)" % [tag, k])
				if not plan.walkable_up(k):
					up_missing[decks] += 1
			_hop_path(plan, tag)
	print("[section] hop-only: plans repaired 2 / 3 / 5 decks: %d / %d / %d of 300; deck pairs with no way back up (no ramp): %d of 300 / %d of 600 / %d of 1200" % [
			repaired[2], repaired[3], repaired[5], up_missing[2], up_missing[3], up_missing[5]])
	# Seed 9 (the Bulwark case, 2026-11-24): deck 1 used to be reachable from deck 0 only by gliding over the deck-1
	# atrium hole (shaft 0 -> 1 stacked over shaft 1 -> 2, no ramp, lifts not carrying mechs). Now a ramp 0 -> 1 is the
	# critical way down and the crew arrives at its foot.
	var s9 := SectionPlan.make({"seed": 9.0})
	var r9 := s9.walkable_down_connector(0)
	check(r9 >= 0 and s9.connectors[r9]["kind"] == "ramp", "seed 9: a ramp from deck 0 to deck 1")
	eq(str(s9.connectors[r9]["role"]), "critical", "seed 9: the ramp is the critical way down")
	eq(int(SectionEncounters.arrival(s9, 1)["connector"]), r9, "seed 9: the crew arrives on deck 1 at the ramp's foot")
	eq(int(SectionEncounters.departure(s9, 0)["connector"]), r9, "seed 9: and leaves deck 0 by it")
	eq(str(SectionEncounters.arrival(s9, 1)["kind"]), "ramp", "seed 9: arrival kind")
	check(s9.walkable_down(1), "seed 9: deck 2 walkable from deck 1")
	# The fallbacks when no ramp fits (a grade too gentle for the grid): the stacked shaft moves, or a shaft is cut.
	for o: Dictionary in [{"ramp_grade": 0.08}, {"ramp_grade": 0.08, "decks": 5.0}, {"ramp_grade": 0.08, "shafts": 0.0},
			{"arc": 300.0}]:
		var hows := {}
		for seed_ in range(1, 21):
			var oo := o.duplicate()
			oo["seed"] = float(seed_)
			var plan := SectionPlan.make(oo)
			for w: Dictionary in plan.walk_repairs:
				hows[w["how"]] = true
			for k in plan.deck_count - 1:
				check(_hop_down(plan, k) >= 0, "%s seed %d: deck %d walkable from deck %d" % [str(o), seed_, k + 1, k])
			_hop_path(plan, "%s seed %d" % [str(o), seed_])
		check(not hows.has("ramp"), "%s: no ramp fits, none added" % str(o))
		check(not hows.is_empty(), "%s: some plan needed a fallback repair" % str(o))


## The connector a hop-only mech takes from deck k to k+1 (an unlocked ramp first, else a shaft from k whose landing
## overlaps no hole of deck k+1), recomputed from the connector list; -1 if none.
func _hop_down(plan: SectionPlan, k: int) -> int:
	var shaft := -1
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		if c["locked"] or int(c["from"]) != k or int(c["to"]) != k + 1:
			continue
		if c["kind"] == "ramp":
			return ci
		if c["kind"] != "shaft" or shaft >= 0:
			continue
		var land := plan.connector_rect(ci, k + 1)
		var lands := true
		for h in plan.connectors.size():
			var o: Dictionary = plan.connectors[h]
			if h != ci and o["kind"] != "lift" and int(o["from"]) == k + 1 and plan.connector_rect(h, k + 1).intersects(land):
				lands = false
		if lands:
			shaft = ci
	return shaft


## The critical path on a hop-only graph: the plan's walkable cells, ramps both ways, shafts one way only where the drop
## lands, no lifts: the entry reaches every cell of every deck and the extraction.
func _hop_path(plan: SectionPlan, tag: String) -> void:
	var adj := plan.mech_graph(false)
	for a in adj.size():
		var kept := []
		for e: Array in adj[a]:
			var via := int(e[2])
			if via < 0:
				kept.append(e)
				continue
			var c: Dictionary = plan.connectors[via]
			if c["kind"] == "ramp" or (c["kind"] == "shaft" and _hop_down(plan, int(c["from"])) == via):
				kept.append(e)
		adj[a] = kept
	var found := SectionPlan.walk(adj, plan.entry_cell())
	check(float(found["dist"][plan.extraction_cell()]) < INF, tag + ": hop-only, the entry reaches the extraction")
	for k in plan.deck_count:
		check(float(found["dist"][plan.cell_id(k, 0, 0)]) < INF, "%s: hop-only, deck %d reached" % [tag, k])


## Legacy digest of seeds 1..40, recorded before ramp bridges and segment forms existed (2026-11-23): everything rolled
## before them (grid, zones, regions, pillars, connectors, roads, mech route, hooks, walls and gates, ends) is unchanged.
## Re-recorded 2026-11-24 for the hop-only rule (_ensure_walkable_down): seeds 9, 12, 19 and 36 (3 decks) had no ramp
## and a stacked atrium as the only drop from deck 0 to 1, so each gained a ramp 0 -> 1 (was "3ac644959496e0cf"); the
## other 36 seeds are byte-identical (GOLDEN_UNCHANGED below holds their checksums from before the rule).
const LEGACY_1_40 := "5e98a671b4bc534c"
## checksum() of seeds 1..40, concatenated and sha256'd, recorded before ramp bridges and segment forms: with the forms
## off (fractions 0, the defaults until 2026-11-23) and the bridge rule on, the whole plan hashes exactly as before.
## Re-recorded 2026-11-24 for the hop-only rule, same four seeds (was "af844bf36222946e").
const CHECKSUM_1_40 := "a8418dac1af36fdb"
## The same digest at the DEFAULTS since the forms went live (2026-11-23: f_lane 0.20, f_pedestrian 0.15, f_none 0.08).
## Re-recorded 2026-11-24 for the hop-only rule, same four seeds (was "730d587c09108457").
const CHECKSUM_DEFAULT_1_40 := "f72178587ddf045e"
## checksum() at the defaults recorded BEFORE the hop-only rule existed, for seeds that already met it: they must never
## move. Key "decks:seed". Seeds the project pins elsewhere (mission, city, bot and net tests) included.
const GOLDEN_UNCHANGED := {
	"3:1": "e700861b676804be", "3:2": "ef9e0d7a8a993b42", "3:3": "370b9dec18720682", "3:4": "caffe96bbb70e675",
	"3:5": "cd47a331c85a5b7e", "3:6": "4a380ce7f69cfeb2", "3:7": "cf28c7ae7beeb2b2", "3:10": "23ac05ac695dc885",
	"3:16": "d13de6fdb2d2d149", "3:17": "fc9261af3c0fdf7e", "3:21": "d15aaa0164c287ee", "3:22": "7ceacce00fe79bc0",
	"3:26": "e95e24276d9b9cf7", "3:30": "349679d2ec3a3938", "3:32": "265b697c89ee42d6", "3:100": "9846a008fac9eec7",
	"3:200": "8ad2283997dffc41", "3:300": "29e290dc68a1cd74", "3:403112": "318ac97042a655c0",
	"3:747612": "01462e097f133ddb", "3:297535": "ffc9c65b84f5cb07", "3:295676": "b2121ac7aeb88ee0",
	"5:1": "149059f2d843a8cd", "5:2": "ce98374a8be8d6f7", "5:3": "3b204fd4bce2681e", "5:5": "d361cabd3411b04d",
	"5:6": "4823ccf917c00225", "5:7": "804beb15df7416b5", "5:9": "0364f89b3f798af0", "5:10": "6bb213fe0568007a",
	"5:16": "d9fd5735267c344b", "2:1": "6102607788dee884", "2:9": "a837a7611873cb14", "2:50": "ef3787f6d0774b3c",
}
## Plans the rule changed (checksum before it): seed 9 is the case that found it (deck 1 reachable only by a glide).
const GOLDEN_CHANGED := {"3:9": "0f07fdb6ead9f69c", "5:4": "e582e75aa48518a9", "5:22": "101ecacd184833a1",
		"5:32": "ac65a0a8c37a9f42"}
const ZERO_FORMS := {"f_lane": 0.0, "f_pedestrian": 0.0, "f_none": 0.0}
## The mix the DEFAULTS roll (forms live since 2026-11-23).
const FORM_MIX := {"f_lane": 0.20, "f_pedestrian": 0.15, "f_none": 0.08}
const EXTREMES := [
	{"f_pedestrian": 0.6, "f_none": 0.6}, {"f_lane": 1.0}, {"f_pedestrian": 1.0}, {"f_none": 1.0},
	{"f_pedestrian": 0.6, "f_none": 0.6, "decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0},
	{"f_pedestrian": 0.6, "f_none": 0.6, "w_industrial": 3.0, "w_park": 0.0},
]


func _forms_sweep() -> void:
	# Determinism.
	var mo := FORM_MIX.duplicate()
	mo["seed"] = 7.0
	var a := SectionPlan.make(mo)
	var b := SectionPlan.make(mo)
	eq(str(a.forms), str(b.forms), "same seed, same segment forms")
	var zo7 := ZERO_FORMS.duplicate()
	zo7["seed"] = 7.0
	check(a.checksum() != SectionPlan.make(zo7).checksum(), "forms are in the checksum")
	# Forms off: every segment a street, the plan and its checksum exactly as before forms and bridges.
	# Defaults: the forms are live (the FORM_MIX plan), some minor segment is not a street on every seed.
	var sums := ""
	var def_sums := ""
	for seed_ in range(1, 41):
		var zo := ZERO_FORMS.duplicate()
		zo["seed"] = float(seed_)
		var plan := SectionPlan.make(zo)
		sums += plan.checksum()
		var streets := true
		for k in plan.deck_count:
			for sg: Dictionary in plan.segments(k):
				streets = streets and sg["form"] == "street"
		check(streets, "seed %d: forms off, every segment a street" % seed_)
		var zb := zo.duplicate()
		zb["bridge_rule"] = 0.0
		eq(plan.checksum(), SectionPlan.make(zb).checksum(), "seed %d: the bridge rule changes nothing stored" % seed_)
		var dp := SectionPlan.make({"seed": float(seed_)})
		def_sums += dp.checksum()
		var fm := FORM_MIX.duplicate()
		fm["seed"] = float(seed_)
		eq(dp.checksum(), SectionPlan.make(fm).checksum(), "seed %d: the defaults roll FORM_MIX" % seed_)
		var formed := false
		for k in dp.deck_count:
			for sg: Dictionary in dp.segments(k):
				formed = formed or sg["form"] != "street"
		check(formed, "seed %d: forms live by default" % seed_)
	eq(sums.sha256_text().substr(0, 16), CHECKSUM_1_40, "seeds 1..40: forms-off checksums as before forms and bridges")
	eq(def_sums.sha256_text().substr(0, 16), CHECKSUM_DEFAULT_1_40, "seeds 1..40: default checksums (forms live)")
	# Old data unmoved, and at default grade one bridge goes per ramp; mix of the minor segments (intended mix).
	var all := ""
	var mix := {"street": 0, "lane": 0, "pedestrian": 0, "none": 0}
	var minor := 0
	var total := 0
	var repaired := 0
	var stubs := 0
	for seed_ in range(1, 41):
		var po := FORM_MIX.duplicate()
		po["seed"] = float(seed_)
		var plan := SectionPlan.make(po)
		_check_plan(plan, "mix seed %d" % seed_)
		all += _legacy_digest(plan)
		for ci in plan.connectors.size():
			if plan.connectors[ci]["kind"] == "ramp":
				eq(plan.bridge_lines(ci).size(), 1, "seed %d: one bridge fewer over ramp %d at the default grade" % [seed_, ci])
		for k in plan.deck_count:
			for sg: Dictionary in plan.segments(k):
				total += 1
				if sg["minor"]:
					minor += 1
					mix[sg["form"]] += 1
		repaired += int(plan.repair_stats["repaired"])
		stubs += int(plan.repair_stats["stubs"])
		# Geometry and everything rolled before the forms: the same as a plan with no minor forms at all.
		var flat_o := ZERO_FORMS.duplicate()
		flat_o["seed"] = float(seed_)
		var flat := SectionPlan.make(flat_o)
		_same_geometry(plan, flat, "seed %d" % seed_)
	eq(all.sha256_text().substr(0, 16), LEGACY_1_40, "seeds 1..40: everything rolled before forms is unchanged")
	print("[section] forms over 40 seeds: %d segments, %d minor (%.0f%%): street %.3f lane %.3f pedestrian %.3f none %.3f; repaired %.2f / plan, stubs %.2f / plan" % [
			total, minor, 100.0 * minor / total, float(mix["street"]) / minor, float(mix["lane"]) / minor,
			float(mix["pedestrian"]) / minor, float(mix["none"]) / minor, repaired / 40.0, stubs / 40.0])
	var f_lane := float(mix["lane"]) / minor
	var f_ped := float(mix["pedestrian"]) / minor
	var f_none := float(mix["none"]) / minor
	check(f_lane > 0.12 and f_lane < 0.45, "lanes roughly f_lane (%.3f)" % f_lane)
	check(f_ped > 0.05 and f_ped < 0.30, "pedestrian roughly f_pedestrian (%.3f)" % f_ped)
	check(f_none > 0.01 and f_none < 0.15, "none roughly f_none, less the zones that forbid it (%.3f)" % f_none)
	# The intended mix across the settings extremes, and deck views of mixed plans (strips carry forms, still tile).
	for i in SETTINGS.size():
		var so: Dictionary = (SETTINGS[i] as Dictionary).duplicate()
		so.merge(FORM_MIX)
		so["seed"] = 3.0
		_check_plan(SectionPlan.make(so), "mix settings %d" % i)
	for seed_ in [1, 2, 9]:
		var vo := FORM_MIX.duplicate()
		vo["seed"] = float(seed_)
		var vp := SectionPlan.make(vo)
		for k in vp.deck_count:
			_check_view(vp, k, vp.deck_view(k), "mix view seed %d deck %d" % [seed_, k])
	# All fractions 0: every segment a street, and the road graph is the full grid less ramp feet and ramp bridges.
	for o: Dictionary in [{"seed": 3.0}, {"seed": 11.0}, {"seed": 4.0, "ramp_grade": 0.08}, {"seed": 29.0, "decks": 5.0}]:
		var zo := ZERO_FORMS.duplicate()
		zo.merge(o)
		var plan := SectionPlan.make(zo)
		var edges := _grid_edges(plan)
		var bad := 0
		for k in plan.deck_count:
			for sg: Dictionary in plan.segments(k):
				if sg["form"] != "street":
					bad += 1
				var foot: bool = sg["axis"] == "x" and plan._crossing_blocked(k, int(sg["index"]), int(sg["line"]))
				var bridge := false
				for ci in plan.connectors.size():
					var c: Dictionary = plan.connectors[ci]
					if c["kind"] == "ramp" and int(c["from"]) == k and sg["axis"] == "x" and plan.bridge_lines(ci).has(int(sg["line"])) \
							and int(sg["index"]) == (plan.spine_line - 1 if c["lane"] == "ramp_a" else plan.spine_line):
						bridge = true
				var key := Vector2i(mini(int(sg["a"]), int(sg["b"])), maxi(int(sg["a"]), int(sg["b"])))
				if edges.has(key) == (foot or bridge):
					bad += 1
		eq(bad, 0, "no forms %s: all streets, road graph = grid less ramp feet and bridges" % str(o))
		eq(int(plan.repair_stats["repaired"]) + int(plan.repair_stats["stubs"]), 0, "no forms %s: nothing to repair" % str(o))
	# Extreme mixes: the repair still delivers every guarantee (the full plan checks run on them).
	for i in EXTREMES.size():
		var rep := 0
		var stub := 0
		var rolled := 0
		var n_seeds := 3 if (EXTREMES[i] as Dictionary).has("decks") else 10     # the big grid repairs ~0.7 s a plan
		for seed_ in range(1, n_seeds + 1):
			var o: Dictionary = (EXTREMES[i] as Dictionary).duplicate()
			o["seed"] = float(seed_)
			var plan := SectionPlan.make(o)
			_check_plan(plan, "extreme %d seed %d" % [i, seed_])
			rep += int(plan.repair_stats["repaired"])
			stub += int(plan.repair_stats["stubs"])
			rolled += int(plan.repair_stats["rolled"])
		print("[section] extreme %s: rolled %.1f, repaired %.1f, stubs %.1f per plan" % [str(EXTREMES[i]), float(rolled) / n_seeds,
				float(rep) / n_seeds, float(stub) / n_seeds])


func _same_geometry(a: SectionPlan, b: SectionPlan, tag: String) -> void:
	eq(str(a.decks), str(b.decks), tag + ": zones and regions unchanged by forms")
	eq(str(a.pillars), str(b.pillars), tag + ": pillars unchanged by forms")
	eq(str(a.connectors), str(b.connectors), tag + ": connectors unchanged by forms")
	eq(str(a.hooks), str(b.hooks), tag + ": hooks unchanged by forms")
	eq(str(a.boundaries), str(b.boundaries), tag + ": walls and gates unchanged by forms")
	eq(str(a.route["mech"]), str(b.route["mech"]), tag + ": mech route unchanged by forms")
	var bad := 0
	for k in a.deck_count:
		for r in a.rows:
			for c in a.cols:
				if a.cell_rect(k, c, r) != b.cell_rect(k, c, r):
					bad += 1
		for id in a.pillars.size():
			if a.pillar_point(k, id) != b.pillar_point(k, id):
				bad += 1
		for ci in a.connectors.size():
			if a.connector_rect(ci, k) != b.connector_rect(ci, k):
				bad += 1
		var sa: Array = a.deck_view(k)["road_strips"]
		var sb: Array = b.deck_view(k)["road_strips"]
		if sa.size() != sb.size():
			bad += 1
		else:
			for m in sa.size():
				if sa[m]["rect"] != sb[m]["rect"]:
					bad += 1
	eq(bad, 0, tag + ": cell rects, pillar points, connector rects and road strips unchanged by forms")


## Hash of everything SectionPlan rolled before ramp bridges and segment forms (the vehicle route left out: it now avoids
## those segments). Quantised like checksum().
static func _legacy_digest(plan: SectionPlan) -> String:
	var buf := StreamPeerBuffer.new()
	var q := func(v: float) -> void: buf.put_32(int(round(v * 1000.0)))
	for v in [plan.deck_count, plan.cols, plan.rows, plan.spine_line]:
		buf.put_32(v)
	for x in plan.col_x: q.call(x)
	for t in plan.row_theta: q.call(t * 1000.0)
	for dk: Dictionary in plan.decks:
		buf.put_32(int(dk["dir"]))
		for row: Array in dk["zones"]:
			for z: String in row:
				buf.put_utf8_string(z)
		for r: Rect2 in dk["keep_clear"]:
			for v in [r.position.x, r.position.y, r.size.x, r.size.y]: q.call(v)
		for reg: Dictionary in dk["regions"]:
			buf.put_utf8_string(str(reg["kind"]))
			for c: Vector2i in reg["cells"]:
				buf.put_32(c.x + c.y * 64)
	for p: Dictionary in plan.pillars:
		buf.put_32(int(p["col"]) + int(p["row"]) * 64)
		q.call(float(p["x"])); q.call(float(p["theta"]) * 1000.0)
		buf.put_8(1 if p["lift"] else 0)
		for k: int in p["stops"]: buf.put_8(k)
	for c: Dictionary in plan.connectors:
		var keys: Array = c.keys()
		keys.sort()
		for key: Variant in keys:
			buf.put_utf8_string(str(key))
			var v: Variant = c[key]
			if v is float: q.call(v * 1000.0)
			else: buf.put_utf8_string(str(v))
	for r: Dictionary in plan.roads:
		buf.put_utf8_string("%s:%d:%s" % [r["axis"], r["line"], r["kind"]]); q.call(float(r["width"]))
	for w: Dictionary in plan.route["mech"]:
		buf.put_32(plan.cell_id(w["deck"], w["col"], w["row"]))
	q.call(float(plan.route["mech_len"]))
	for h: Dictionary in plan.hooks:
		var keys: Array = h.keys()
		keys.sort()
		for key: Variant in keys:
			buf.put_utf8_string(str(key))
			var v: Variant = h[key]
			if v is float: q.call(v)
			elif v is Array:
				for e: Variant in v:
					if e is Vector2: q.call(e.x); q.call(e.y)
					else: buf.put_utf8_string(str(e))
			else: buf.put_utf8_string(str(v))
	for b: Dictionary in plan.boundaries:
		buf.put_utf8_string("%s:%s:%s" % [b["deck"], b["edge"], b["kind"]])
		for g: Dictionary in b["gates"]:
			buf.put_utf8_string("%s:%s:%s:%d" % [g["kind"], g["role"], g["axis"], g["line"]])
			q.call(float(g["x"])); q.call(float(g["s"])); q.call(float(g["width"]))
	for e: Dictionary in [plan.entry, plan.extraction]:
		for v in [e["deck"], e["i"], e["j"], e["col"], e["row"]]:
			buf.put_32(int(v))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _determinism() -> void:
	var a := SectionPlan.make({"seed": 7.0})
	var b := SectionPlan.make({"seed": 7.0})
	eq(a.checksum(), b.checksum(), "same seed, same plan")
	eq(str(a.decks), str(b.decks), "same seed, same zones")
	eq(str(a.connectors), str(b.connectors), "same seed, same connectors")
	b.generate({"seed": 8.0})
	check(a.checksum() != b.checksum(), "another seed, another plan")
	b.generate({"seed": 7.0})
	eq(a.checksum(), b.checksum(), "regenerating in place gives the same plan")
	var sums := {}
	for seed_ in range(1, 41):
		sums[SectionPlan.make({"seed": float(seed_)}).checksum()] = true
	check(sums.size() >= 38, "seeds give different sections (%d of 40)" % sums.size())
	check(SectionPlan.make({"seed": 7.0, "w_park": 1.5}).checksum() != a.checksum(), "the zone mix changes the plan")
	# Encounter data is derived: repeatable, the same on two plans of one seed, and reading it changes nothing.
	var sum := a.checksum()
	for k in a.deck_count:
		eq(str(SectionEncounters.arrival(a, k)), str(SectionEncounters.arrival(b, k)), "same seed, same arrival on deck %d" % k)
		eq(str(SectionEncounters.departure(a, k)), str(SectionEncounters.departure(b, k)), "same seed, same departure on deck %d" % k)
		eq(str(SectionEncounters.sites(a, k)), str(SectionEncounters.sites(b, k)), "same seed, same encounter sites on deck %d" % k)
		eq(str(SectionEncounters.sites(a, k)), str(SectionEncounters.sites(a, k)), "encounter sites are repeatable on deck %d" % k)
	eq(a.checksum(), sum, "reading encounter data leaves the plan alone")


func _check_plan(plan: SectionPlan, tag: String) -> void:
	var n := plan.deck_count
	check(n >= 2 and plan.cols >= 2 and plan.rows >= 4, tag + ": grid")
	# --- Routes: vehicles (roads, ramps, lifts; the locked express lift not needed) and mechs.
	var road := SectionPlan.walk(plan.road_graph(false), plan.entry_node())
	check(float(road["dist"][plan.extraction_node()]) < INF, tag + ": vehicles can drive from the entry to the extraction")
	for k in n:
		check(float(road["dist"][plan.node_id(k, plan.spine_line, plan.rows / 2)]) < INF, tag + ": vehicles reach deck %d" % k)
	var back := SectionPlan.walk(plan.road_graph(false), plan.extraction_node())
	check(float(back["dist"][plan.entry_node()]) < INF, tag + ": vehicles can drive back up")
	var mech := SectionPlan.walk(plan.mech_graph(false), plan.entry_cell())
	check(float(mech["dist"][plan.extraction_cell()]) < INF, tag + ": mechs can reach the extraction")
	# Every zone cell is reachable by a mech, and borders a road crossing a vehicle can reach.
	for k in n:
		for r in plan.rows:
			for c in plan.cols:
				check(float(mech["dist"][plan.cell_id(k, c, r)]) < INF, "%s: cell %d/%d,%d reachable by mechs" % [tag, k, c, r])
				var any := false
				for corner: Vector2i in [Vector2i(c, r), Vector2i(c + 1, r), Vector2i(c, r + 1), Vector2i(c + 1, r + 1)]:
					any = any or float(road["dist"][plan.node_id(k, corner.x, corner.y)]) < INF
				check(any, "%s: cell %d/%d,%d has road access" % [tag, k, c, r])
				check(plan.zone(k, c, r) in SectionPlan.ZONES, "%s: cell %d/%d,%d has a zone" % [tag, k, c, r])
	check(not (plan.route["vehicle"] as Array).is_empty() and not (plan.route["mech"] as Array).is_empty(), tag + ": routes recorded")
	eq(int(plan.route["vehicle"][0]["deck"]), 0, tag + ": the route starts on the top deck")
	eq(int(plan.route["vehicle"][-1]["deck"]), n - 1, tag + ": the route ends on the lowest deck")
	check(float(plan.route["mech_len"]) <= float(plan.route["vehicle_len"]) * 1.5, tag + ": the mech route is no detour")
	# One vehicle connection per deck transition is critical and unlocked.
	for k in n - 1:
		var found := false
		for c: Dictionary in plan.connectors:
			if c["role"] == "critical" and c["vehicles"] and not c["locked"] and int(c["from"]) <= k and int(c["to"]) >= k + 1:
				found = true
		check(found, "%s: a critical vehicle connection from deck %d down" % [tag, k])
	# --- Pillars: one column through every deck (same angle, same x), inside its cell on every deck, never in a road.
	var seen := {}
	for id in plan.pillars.size():
		var q: Dictionary = plan.pillars[id]
		eq(plan.pillar_at(q["col"], q["row"]), id, tag + ": pillar lookup")
		check(not seen.has(Vector2i(q["col"], q["row"])), tag + ": one pillar per cell")
		seen[Vector2i(q["col"], q["row"])] = true
		for k in n:
			var pt := plan.pillar_point(k, id)
			near(pt.y / plan.radius_of(k), float(q["theta"]), 1e-6, tag + ": pillar %d at the same angle on deck %d" % [id, k])
			near(pt.x, float(q["x"]), 1e-3, tag + ": pillar %d at the same x on deck %d" % [id, k])
			var rad := plan.pillar_radius(k, id)
			var cell := plan.cell_rect(k, q["col"], q["row"])
			check(cell.encloses(Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0)),
					"%s: pillar %d (%s) inside its cell on deck %d" % [tag, id, plan.pillar_style(k, id), k])
			# Stacked pillars meet: the one below ends at this deck's slab right under this one.
			if k + 1 < n:
				var top_of_lower := plan.to_world(k + 1, pt.x, plan.pillar_point(k + 1, id).y, plan.clear_height())
				var foot := plan.to_world(k, pt.x, pt.y, -plan.p("slab"))
				check(top_of_lower.distance_to(foot) < 0.001, tag + ": pillar %d stacks from deck %d to %d" % [id, k + 1, k])
	# Long-span bays (no pillar) never share an edge, and only exist under / over shafts.
	for r in plan.rows:
		for c in plan.cols:
			if plan.pillar_at(c, r) >= 0:
				continue
			check(c + 1 >= plan.cols or plan.pillar_at(c + 1, r) >= 0, "%s: long-span bays %d,%d don't touch" % [tag, c, r])
			check(r + 1 >= plan.rows or plan.pillar_at(c, r + 1) >= 0, "%s: long-span bays %d,%d don't touch" % [tag, c, r])
			var has_shaft := false
			for cn: Dictionary in plan.connectors:
				has_shaft = has_shaft or (cn["kind"] == "shaft" and int(cn["col"]) == c and int(cn["row"]) == r)
			check(has_shaft, "%s: bay %d,%d without a pillar has a shaft" % [tag, c, r])
	# --- Connections: clear of every pillar they aren't housed in, on every deck they touch; holes stay off the roads.
	for ci in plan.connectors.size():
		var cn: Dictionary = plan.connectors[ci]
		check(int(cn["to"]) > int(cn["from"]) and int(cn["from"]) >= 0 and int(cn["to"]) < n, tag + ": connector decks")
		for k: int in cn["stops"]:
			var rect := plan.connector_rect(ci, k)
			check(rect.size.x > 1.0 and rect.size.y > 1.0, tag + ": connector %d has a footprint" % ci)
			check(absf(rect.get_center().y) + rect.size.y * 0.5 <= plan.arc_of(k) * 0.5 + 0.01, tag + ": connector %d inside the section" % ci)
			for id in plan.pillars.size():
				if id == int(cn["pillar"]):
					continue
				var pt := plan.pillar_point(k, id)
				var rad := plan.pillar_radius(k, id) + SectionPlan.CONNECT_CLEAR
				check(not rect.intersects(Rect2(pt.x - rad, pt.y - rad, rad * 2.0, rad * 2.0)),
						"%s: %s %d clear of pillar %d on deck %d" % [tag, cn["kind"], ci, id, k])
		match str(cn["kind"]):
			"lift":
				check(int(cn["pillar"]) >= 0 and plan.pillars[int(cn["pillar"])]["lift"], tag + ": a lift rides in a lift pillar")
				var st: Array = cn["stops"]
				eq(st, range(int(cn["from"]), int(cn["to"]) + 1), tag + ": lift %d stops on every deck from..to" % ci)
				eq(int(cn["top"]["deck"]), int(st[0]), tag + ": lift %d top is its first stop" % ci)
				eq(int(cn["bottom"]["deck"]), int(st[-1]), tag + ": lift %d bottom is its last stop" % ci)
				for k: int in st:
					eq(plan.zone(k, cn["col"], cn["row"]), "transit", tag + ": a lift stop is a transit cell")
					eq(plan.pillar_style(k, int(cn["pillar"])), "lift", tag + ": lift pillar style")
					# The platform: the same square on every stop, centred in its pillar and inside its footprint.
					var pid := int(cn["pillar"])
					var rect := plan.connector_rect(ci, k)
					var at := plan.pillar_point(k, pid)
					near(rect.size.x, SectionPlan.LIFT_PLATFORM, 0.01, tag + ": lift %d platform width on deck %d" % [ci, k])
					near(rect.size.y, SectionPlan.LIFT_PLATFORM, 0.01, tag + ": lift %d platform length on deck %d" % [ci, k])
					check(rect.get_center().distance_to(at) < 0.01, tag + ": lift %d platform centred on its pillar on deck %d" % [ci, k])
					var half := plan.pillar_radius(k, pid)
					check(Rect2(at.x - half, at.y - half, half * 2.0, half * 2.0).grow(0.01).encloses(rect),
							tag + ": lift %d platform inside its pillar on deck %d" % [ci, k])
			"shaft":
				eq(plan.zone(cn["from"], cn["col"], cn["row"]), "open", tag + ": a shaft is cut in an open-air cell")
				check(plan.zone(cn["to"], cn["col"], cn["row"]) in ["park", "open"], tag + ": a shaft lands on open ground")
				check(plan.cell_rect(cn["from"], cn["col"], cn["row"]).encloses(plan.connector_rect(ci, cn["from"])), tag + ": shaft inside its cell")
				check(not cn["vehicles"] and not cn["two_way"], tag + ": a shaft is a one-way drop for mechs")
			"ramp":
				var lane := plan.lane_x(cn["lane"])
				near(float(cn["x0"]), lane.x, 0.001, tag + ": ramp in its spine lane")
				var length := (float(cn["theta1"]) - float(cn["theta0"])) * plan.radius_of(int(cn["from"]))
				check(plan.p("pitch") / length <= plan.p("ramp_grade") + 0.0001, tag + ": ramp no steeper than the grade (%.3f)" % (plan.p("pitch") / length))
				eq(plan.zone(cn["from"], cn["col"], cn["row"]), "transit", tag + ": ramp head is a transit cell")
				eq(plan.zone(cn["to"], cn["col"], cn["foot_row"]), "transit", tag + ": ramp foot is a transit cell")
	# Two ramps never share a lane on one deck.
	for a in plan.connectors.size():
		for b in range(a + 1, plan.connectors.size()):
			var ca: Dictionary = plan.connectors[a]
			var cb: Dictionary = plan.connectors[b]
			if ca["kind"] != "ramp" or cb["kind"] != "ramp":
				continue
			for k in n:
				if (ca["stops"] as Array).has(k) and (cb["stops"] as Array).has(k):
					check(not plan.connector_rect(a, k).intersects(plan.connector_rect(b, k)), tag + ": ramps %d and %d apart on deck %d" % [a, b, k])
	# --- Ends, regions, hooks.
	eq(plan.zone(0, plan.entry["col"], plan.entry["row"]), "transit", tag + ": the entry is a station")
	eq(plan.zone(n - 1, plan.extraction["col"], plan.extraction["row"]), "transit", tag + ": the extraction is a station")
	for k in n:
		var cells := 0
		for reg: Dictionary in plan.decks[k]["regions"]:
			cells += (reg["cells"] as Array).size()
			for cell: Vector2i in reg["cells"]:
				eq(plan.zone(k, cell.x, cell.y), str(reg["kind"]), tag + ": region kind")
				check((reg["rect"] as Rect2).grow(0.01).encloses(plan.cell_rect(k, cell.x, cell.y)), tag + ": region bounds")
		eq(cells, plan.cols * plan.rows, tag + ": regions cover deck %d" % k)
		if plan.p("w_park") > 0.001:
			var parks := 0
			for row: Array in plan.decks[k]["zones"]:
				parks += row.count("park")
			check(parks >= 1, tag + ": deck %d has a park" % k)
	# --- Boundaries: four walls a deck; the crew's portals are gates in bulkheads on the spine; gates sit on road lines.
	eq(plan.boundaries.size(), n * 4, tag + ": four walls on every deck")
	var portals := {}
	for k in n:
		for edge in SectionPlan.EDGES:
			var b := plan.boundary(k, edge)
			eq(int(b["deck"]), k, tag + ": boundary deck")
			eq(str(b["edge"]), edge, tag + ": boundary edge")
			check(b["kind"] in ["bulkhead", "window"], tag + ": boundary kind")
			eq(bool(b["backdrop"]), b["kind"] == "window", tag + ": a window wall shows the ring beyond")
			var wall := plan.boundary_rect(k, edge)
			var inside := Rect2(-plan.p("width") * 0.5, -plan.arc_of(k) * 0.5, plan.p("width"), plan.arc_of(k))
			check(not wall.grow(-0.01).intersects(inside), tag + ": wall %s outside the section's ground" % edge)
			for g: Dictionary in b["gates"]:
				check(g["kind"] in ["portal", "blast_door", "collapsed"], tag + ": gate kind")
				eq(str(g["axis"]), "s" if edge.begins_with("s") else "x", tag + ": a gate is where a road meets the wall")
				check(int(g["line"]) >= 1 and int(g["line"]) < (plan.cols if g["axis"] == "s" else plan.rows), tag + ": gate on a road line")
				check(wall.grow(0.01).has_point(Vector2(float(g["x"]), float(g["s"]))), tag + ": gate in wall %s" % edge)
				if g["kind"] == "portal":
					portals[g["role"]] = [k, edge]
					eq(str(b["kind"]), "bulkhead", tag + ": a portal is a gate in a bulkhead")
					eq(int(g["line"]), plan.spine_line, tag + ": a portal is on the spine")
				else:
					eq(str(g["role"]), "", tag + ": only portals have a role")
	eq(portals.size(), 2, tag + ": one entry portal and one extraction portal")
	eq(portals.get("entry"), [0, "s0"], tag + ": the entry portal is in the top deck's wall")
	eq(portals.get("extraction"), [n - 1, "s1" if int(plan.extraction["j"]) > 0 else "s0"], tag + ": the extraction portal")
	var checkpoints := 0
	for h: Dictionary in plan.hooks:
		check(int(h["deck"]) >= 0 and int(h["deck"]) < n, tag + ": hook deck")
		check(absf(float(h["x"])) <= plan.p("width") * 0.5 and absf(float(h["s"])) <= plan.arc_of(int(h["deck"])) * 0.5, tag + ": hook inside the section")
		if h["kind"] == "checkpoint" and h["size"] == "heavy":
			checkpoints += 1
	check(checkpoints >= n - 1, tag + ": a heavy checkpoint at every way down")
	# --- The hop-only rule: every deck walkable from the one above (no lift, no glide); a repair ramp leads the route.
	eq(plan.validate().size(), 0, tag + ": validate() " + str(plan.validate()))
	for w: Dictionary in plan.walk_repairs:
		if w["how"] == "ramp":
			var k := int(w["deck"])
			eq(int(SectionEncounters.departure(plan, k)["connector"]), int(w["connector"]), tag + ": the repair ramp is the way down from deck %d" % k)
			eq(int(SectionEncounters.arrival(plan, k + 1)["connector"]), int(w["connector"]), tag + ": the crew arrives at the repair ramp's foot")
	_check_encounters(plan, tag)
	_check_bridges(plan, tag)
	_check_forms(plan, tag)


## Ramp bridges: on a ramp's upper deck, the cross segment of its lane at every line too low to drive under (clearance
## recomputed here) is blocked and missing from the road graph; every other line keeps its bridge.
func _check_bridges(plan: SectionPlan, tag: String) -> void:
	var edges := _grid_edges(plan)
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		var lines := plan.bridge_lines(ci)
		if c["kind"] != "ramp":
			eq(lines.size(), 0, tag + ": only ramps lose bridges")
			continue
		var k := int(c["from"])
		var top := int(c["top_line"])
		var foot := int(c["foot_line"])
		var i := plan.spine_line - 1 if c["lane"] == "ramp_a" else plan.spine_line
		var run := absf(plan.line_s(k, foot) - plan.line_s(k, top))
		for j in range(mini(top, foot) + 1, maxi(top, foot)):
			var d := absf(plan.line_s(k, j) - plan.line_s(k, top)) - plan.line_width("x", j) * 0.5
			var clear := plan.p("pitch") * d / run - plan.p("slab")
			eq(lines.has(j), clear < SectionPlan.BRIDGE_CLEARANCE, "%s: ramp %d line %d bridged iff clear (%.2f m)" % [tag, ci, j, clear])
			var a := plan.node_id(k, i, j)
			var b := plan.node_id(k, i + 1, j)
			eq(edges.has(Vector2i(a, b)), not lines.has(j) and plan.segment_form(k, a, b) in ["street", "lane"],
					"%s: ramp %d line %d edge in road_graph iff bridged" % [tag, ci, j])
			if lines.has(j):
				var sg := _seg(plan, k, "x", j, i)
				eq(str(sg["blocked"]), "bridge", "%s: ramp %d line %d segment blocked by the cut" % [tag, ci, j])
		for j in lines:
			check(j != top and j != foot and (j - top) * (foot - top) > 0, "%s: ramp %d bridge line %d between head and foot" % [tag, ci, j])


## Road-graph edges between neighbouring nodes of one deck (connector edges left out), as Vector2i(lo, hi).
func _grid_edges(plan: SectionPlan) -> Dictionary:
	var out := {}
	var adj := plan.road_graph(false)
	for a in adj.size():
		for e: Array in adj[a]:
			if int(e[2]) < 0:
				out[Vector2i(mini(a, int(e[0])), maxi(a, int(e[0])))] = true
	return out


func _seg(plan: SectionPlan, k: int, axis: String, line: int, index: int) -> Dictionary:
	return plan.line_segments(k, axis, line)[index]


## Segment forms (always-street rules, graph agreement, repair guarantees, strips) on one plan.
func _check_forms(plan: SectionPlan, tag: String) -> void:
	var n := plan.deck_count
	var edges := _grid_edges(plan)
	var road := SectionPlan.walk(plan.road_graph(false), plan.entry_node())
	var hw := plan.p("width") * 0.5
	for k in n:
		var t := "%s deck %d" % [tag, k]
		var segs := plan.segments(k)
		eq(segs.size(), (plan.cols + 1) * plan.rows + (plan.rows + 1) * plan.cols, t + ": every segment listed")
		var forced := {}       # segment index in segs -> why
		var node_segs := {}    # node id -> [indices into segs]
		var cell_vehicle := {} # cell id -> true
		var bad := 0
		for si in segs.size():
			var sg: Dictionary = segs[si]
			var a := int(sg["a"])
			var b := int(sg["b"])
			var form := str(sg["form"])
			if not form in SectionPlan.FORMS:
				bad += 1
			for nd in [a, b]:
				if not node_segs.has(nd):
					node_segs[nd] = []
				node_segs[nd].append(si)
			if plan.segment_form(k, a, b) != form or plan.segment_form(k, b, a) != form:
				bad += 1
			var drive: bool = form in ["street", "lane"] and str(sg["blocked"]) == ""
			if edges.has(Vector2i(mini(a, b), maxi(a, b))) != drive:
				bad += 1
				check(false, "%s: %s %d #%d (%s, %s) in road_graph iff vehicles drive it" % [t, sg["axis"], sg["line"], sg["index"], form, sg["blocked"]])
			var cw := plan.carriageway(k, a, b)
			var want := float(SectionPlan.FORM_WIDTH[form])
			if not is_equal_approx(cw, plan.line_width(sg["axis"], sg["line"]) if want < 0.0 else want):
				bad += 1
			var line := int(sg["line"])
			var idx := int(sg["index"])
			var cells: Array[Vector2i] = []
			for side in [line - 1, line]:
				var cell := Vector2i(side, idx) if sg["axis"] == "s" else Vector2i(idx, side)
				if cell.x >= 0 and cell.x < plan.cols and cell.y >= 0 and cell.y < plan.rows:
					cells.append(cell)
			if drive:
				for cell in cells:
					cell_vehicle[plan.cell_id(k, cell.x, cell.y)] = true
			if sg["axis"] == "s" and line in [0, plan.spine_line, plan.cols]:
				forced[si] = "spine / perimeter"
			if sg["axis"] == "x" and line in [0, plan.rows]:
				forced[si] = "perimeter"
			var area: Rect2 = sg["rect"]
			for ci in plan.connectors.size():
				var c: Dictionary = plan.connectors[ci]
				var on: Array = c["stops"] if c["kind"] == "lift" else [int(c["from"]), int(c["to"])]
				if on.has(k) and area.intersects(plan.connector_rect(ci, k).grow(1.0), true):
					forced[si] = "touches connector %d" % ci
			for h: Dictionary in plan.hooks:
				if int(h["deck"]) == k and h["kind"] in ["checkpoint", "cordon"] and area.grow(1.0).has_point(Vector2(float(h["x"]), float(h["s"]))):
					forced[si] = "hook " + str(h["kind"])
			# A superblock only joins built blocks, never a connector's cell.
			if form == "none":
				for cell in cells:
					if plan.zone(k, cell.x, cell.y) in ["park", "open", "transit"]:
						bad += 1
						check(false, "%s: none segment beside a %s cell" % [t, plan.zone(k, cell.x, cell.y)])
					var crect := plan.cell_rect(k, cell.x, cell.y)
					for ci in plan.connectors.size():
						var c: Dictionary = plan.connectors[ci]
						var on: Array = c["stops"] if c["kind"] == "lift" else [int(c["from"]), int(c["to"])]
						if on.has(k) and plan.connector_rect(ci, k).intersects(crect):
							bad += 1
							check(false, "%s: none segment beside connector %d's cell" % [t, ci])
		eq(bad, 0, t + ": segment forms, symmetry, carriageway and graph agree")
		# Node-based rules: gates, ramp heads / feet, lift lobbies.
		var force_node := func(i: int, j: int, why: String) -> void:
			for si: int in node_segs.get(plan.node_id(k, i, j), []):
				forced[si] = why
		for b: Dictionary in plan.boundaries:
			if int(b["deck"]) != k:
				continue
			for g: Dictionary in b["gates"]:
				if g["axis"] == "s":
					force_node.call(int(g["line"]), 0 if b["edge"] == "s0" else plan.rows, "gate")
				else:
					force_node.call(0 if b["edge"] == "x0" else plan.cols, int(g["line"]), "gate")
		for c: Dictionary in plan.connectors:
			if c["kind"] == "ramp":
				for i in [plan.spine_line - 1, plan.spine_line, plan.spine_line + 1]:
					if int(c["from"]) == k:
						force_node.call(i, int(c["top_line"]), "ramp head")
					if int(c["to"]) == k:
						force_node.call(i, int(c["foot_line"]), "ramp foot")
			elif c["kind"] == "lift" and (c["stops"] as Array).has(k):
				force_node.call(int(c["top"]["i"]), int(c["top"]["j"]), "lift lobby")
				var cc := int(c["col"])
				var rr := int(c["row"])
				for si in segs.size():
					var sg: Dictionary = segs[si]
					if (sg["axis"] == "x" and int(sg["index"]) == cc and int(sg["line"]) in [rr, rr + 1]) or \
							(sg["axis"] == "s" and int(sg["index"]) == rr and int(sg["line"]) in [cc, cc + 1]):
						forced[si] = "lift cell"
		for si: int in forced:
			var sg: Dictionary = segs[si]
			if sg["form"] != "street" or sg["minor"]:
				check(false, "%s: %s %d #%d is a street (%s), is %s" % [t, sg["axis"], sg["line"], sg["index"], forced[si], sg["form"]])
		# Repair guarantees: every cell has a side vehicles drive; every node with a vehicle segment is on the network.
		var no_side := 0
		for r in plan.rows:
			for c in plan.cols:
				if not cell_vehicle.has(plan.cell_id(k, c, r)):
					no_side += 1
		eq(no_side, 0, t + ": every cell has a vehicle side")
		var stranded := 0
		var stubs := 0
		for nd: int in node_segs:
			var drawn := 0
			var drives := false
			for si: int in node_segs[nd]:
				var sg: Dictionary = segs[si]
				if sg["form"] != "none":
					drawn += 1
				drives = drives or (sg["form"] in ["street", "lane"] and str(sg["blocked"]) == "")
			if drawn == 1:
				stubs += 1
			if drives and float(road["dist"][nd]) == INF:
				stranded += 1
		eq(stranded, 0, t + ": vehicles reach every node with a vehicle segment")
		eq(stubs, 0, t + ": no stub streets")
		# line_segments tile each line's strip: end to end, line width across, deck edge to deck edge.
		for axis: String in ["s", "x"]:
			for line in (plan.cols + 1 if axis == "s" else plan.rows + 1):
				var ls := plan.line_segments(k, axis, line)
				var lo := -plan.arc_of(k) * 0.5 if axis == "s" else -hw
				var gaps := 0
				for m in ls.size():
					var rc: Rect2 = ls[m]["rect"]
					var along0 := rc.position.y if axis == "s" else rc.position.x
					var along1 := rc.end.y if axis == "s" else rc.end.x
					var across := rc.size.x if axis == "s" else rc.size.y
					if absf(along0 - lo) > 1e-3 or along1 <= along0 or absf(across - plan.line_width(axis, line)) > 1e-3 or int(ls[m]["index"]) != m:
						gaps += 1
					lo = along1
				var hi := plan.arc_of(k) * 0.5 if axis == "s" else hw
				eq(gaps, 0, "%s: line %s %d segments tile without gaps or overlaps" % [t, axis, line])
				near(lo, hi, 1e-3, "%s: line %s %d segments reach the deck's far edge" % [t, axis, line])


## arrival / departure / encounter_sites (mission-section.md §16): derived reads the enemy spawner places groups from.
func _check_encounters(plan: SectionPlan, tag: String) -> void:
	var n := plan.deck_count
	var av := plan.lane_x("avenue")
	var avenue := (av.x + av.y) * 0.5
	for k in n:
		var t := "%s deck %d" % [tag, k]
		var extent := Rect2(-plan.p("width") * 0.5, -plan.arc_of(k) * 0.5, plan.p("width"), plan.arc_of(k)).grow(0.01)
		var a := SectionEncounters.arrival(plan, k)
		var d := SectionEncounters.departure(plan, k)
		var ap := Vector2(float(a["x"]), float(a["s"]))
		var dp := Vector2(float(d["x"]), float(d["s"]))
		eq(int(a["deck"]), k, t + ": arrival deck")
		eq(int(d["deck"]), k, t + ": departure deck")
		check(extent.has_point(ap), t + ": arrival inside the deck " + str(ap))
		check(extent.has_point(dp), t + ": departure inside the deck " + str(dp))
		if k == 0:
			eq(str(a["kind"]), "portal", t + ": the crew arrives through the entry portal")
			check(ap.distance_to(Vector2(avenue, plan.line_s(0, int(plan.entry["j"])))) < 0.01, t + ": arrival is the entry node on the avenue")
		else:
			_check_end(plan, k, a, k - 1, t + ": arrival")
		if k == n - 1:
			eq(str(d["kind"]), "portal", t + ": the crew leaves through the extraction portal")
			eq(int(d["connector"]), -1, t + ": the extraction is no connector")
			check(dp.distance_to(Vector2(avenue, plan.line_s(k, int(plan.extraction["j"])))) < 0.01, t + ": departure is the extraction node on the avenue")
		else:
			_check_end(plan, k, d, k, t + ": departure")
		# 100 m apart, except where a ramp lands right beside the next ramp down (same cross line, neighbouring lanes:
		# the generator allows it, e.g. cell 140 seed 11 deck 1, 40 m).
		var ad := ap.distance_to(dp)
		var side_by_side: bool = a["kind"] == "ramp" and d["kind"] == "ramp" and absf(ap.y - dp.y) < 0.01
		check(ad >= 100.0 or (side_by_side and ad >= 39.9), t + ": arrival and departure apart (%.1f m)" % ad)
		# --- Sites.
		var sites := SectionEncounters.sites(plan, k)
		check(not sites.is_empty(), t + ": encounter sites")
		var total := 0.0
		var early := false
		var late := false
		var ends := 0
		for i in sites.size():
			var site: Dictionary = sites[i]
			var at := Vector2(float(site["x"]), float(site["s"]))
			var st := "%s site %d (%s)" % [t, i, site["kind"]]
			check(site["kind"] in SectionEncounters.SITE_PRIORITY, st + ": kind")
			check(site["weight"] in ["light", "medium", "heavy"], st + ": weight")
			eq(int(site["deck"]), k, st + ": deck")
			check(extent.has_point(at), st + ": inside the deck")
			check(float(site["progress"]) >= 0.0 and float(site["progress"]) <= 1.0, st + ": progress in 0..1")
			if i > 0:
				check(float(site["progress"]) >= float(sites[i - 1]["progress"]), st + ": sorted by progress")
			near(float(site["dist"]), at.distance_to(ap), 1e-3, st + ": dist from the arrival")
			eq(bool(site["safe"]), float(site["dist"]) < SectionEncounters.SAFE_RADIUS, st + ": safe iff near the arrival")
			if site["safe"]:
				eq(float(site["share"]), 0.0, st + ": nothing spawns in the safe bubble")
			else:
				check(float(site["share"]) > 0.0, st + ": a share of the budget")
				total += float(site["share"])
				early = early or float(site["progress"]) < 0.35
				late = late or float(site["progress"]) > 0.8
			if site["kind"] in ["departure", "extraction"]:
				ends += 1
				eq(str(site["kind"]), "extraction" if k == n - 1 else "departure", st + ": extraction on the lowest deck only")
				check(at.distance_to(dp) < 0.01, st + ": at departure()")
				eq(str(site["weight"]), "heavy", st + ": the way out is held heavy")
			if site["kind"] == "checkpoint":
				check(site.has("connector") and site.has("size"), st + ": checkpoint keeps connector and size")
			if site["kind"] == "patrol":
				check(site.has("loop"), st + ": patrol keeps its loop")
			for j in range(i + 1, sites.size()):
				var gap := at.distance_to(Vector2(float(sites[j]["x"]), float(sites[j]["s"])))
				check(gap >= SectionEncounters.MERGE_DIST, "%s: sites %d and %d merged (%.1f m)" % [t, i, j, gap])
		near(total, 1.0, 1e-6, t + ": shares sum to 1")
		check(early, t + ": an enemy group early on the crossing")
		check(late, t + ": an enemy group at the way out")
		eq(ends, 1, t + ": one departure or extraction site")


## `end` (an arrival or departure on deck k) stands on the critical connector from deck `upper` to upper + 1.
func _check_end(plan: SectionPlan, k: int, end: Dictionary, upper: int, tag: String) -> void:
	var ci := int(end["connector"])
	check(ci >= 0 and ci < plan.connectors.size(), tag + ": on a connector")
	if ci < 0 or ci >= plan.connectors.size():
		return
	var c: Dictionary = plan.connectors[ci]
	check(c["role"] == "critical" and not c["locked"] and int(c["from"]) <= upper and int(c["to"]) >= upper + 1,
			tag + ": the critical connector %d -> %d" % [upper, upper + 1])
	eq(str(end["kind"]), str(c["kind"]), tag + ": kind is the connector's")
	check(plan.connector_rect(ci, k).grow(0.01).has_point(Vector2(float(end["x"]), float(end["s"]))), tag + ": inside its footprint")


## deck_view: read-only, consistent with the plan's own helpers, and blocks + road strips tile each deck's ground.
func _deck_views() -> void:
	var cases := []
	for seed_ in range(1, 9):
		cases.append({"seed": float(seed_)})
	cases.append({"decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0, "seed": 11.0})
	for o: Dictionary in cases:
		var plan := SectionPlan.make(o)
		var views := []
		for k in plan.deck_count:
			var tag := "view %s deck %d" % [str(o), k]
			var sum := plan.checksum()
			var v := plan.deck_view(k)
			eq(plan.checksum(), sum, tag + ": deck_view leaves the plan alone")
			eq(str(plan.deck_view(k)), str(v), tag + ": deck_view is repeatable")
			views.append(v)
			_check_view(plan, k, v, tag)
		# Ceiling openings: the deck above's holes, at the same x and the same angles.
		eq((views[0]["ceiling_openings"] as Array).size(), 0, "view %s: the top deck has no ceiling openings" % str(o))
		for k in plan.deck_count - 1:
			var holes := []
			for cn: Dictionary in views[k]["connectors"]:
				if cn["part"] == "hole":
					holes.append(cn)
			var openings: Array = views[k + 1]["ceiling_openings"]
			eq(openings.size(), holes.size(), "view %s: deck %d's holes open deck %d's ceiling" % [str(o), k, k + 1])
			for n in mini(openings.size(), holes.size()):
				var h: Rect2 = holes[n]["rect"]
				var op: Rect2 = openings[n]["rect"]
				eq(int(openings[n]["connector"]), int(holes[n]["id"]), "view %s: opening %d matches its hole" % [str(o), n])
				near(op.position.x, h.position.x, 1e-3, "view %s: opening %d x0" % [str(o), n])
				near(op.end.x, h.end.x, 1e-3, "view %s: opening %d x1" % [str(o), n])
				near(op.position.y / plan.radius_of(k + 1), h.position.y / plan.radius_of(k), 1e-4, "view %s: opening %d theta0" % [str(o), n])
				near(op.end.y / plan.radius_of(k + 1), h.end.y / plan.radius_of(k), 1e-4, "view %s: opening %d theta1" % [str(o), n])


func _check_view(plan: SectionPlan, k: int, v: Dictionary, tag: String) -> void:
	var extent: Rect2 = v["extent"]
	near(extent.size.y, plan.arc_of(k), 1e-3, tag + ": extent spans the arc")
	near(extent.size.x, plan.p("width"), 1e-3, tag + ": extent spans the width")
	# --- Blocks.
	var blocks: Array = v["blocks"]
	eq(blocks.size(), plan.cols * plan.rows, tag + ": one block per cell")
	var regions: Array = plan.decks[k]["regions"]
	for b: Dictionary in blocks:
		var c := int(b["col"])
		var r := int(b["row"])
		eq(blocks[r * plan.cols + c], b, tag + ": blocks are row-major")
		eq(b["rect"], plan.cell_rect(k, c, r), tag + ": block rect is the cell")
		eq(str(b["zone"]), plan.zone(k, c, r), tag + ": block zone")
		var ri := int(b["region"])
		check(ri >= 0 and ri < regions.size(), tag + ": block %d,%d has a region" % [c, r])
		if ri >= 0 and ri < regions.size():
			check((regions[ri]["cells"] as Array).has(Vector2i(c, r)), tag + ": block %d,%d is in its region" % [c, r])
			eq(str(regions[ri]["kind"]), str(b["zone"]), tag + ": region kind is the block's zone")
		eq(int(b["pillar"]), plan.pillar_at(c, r), tag + ": block pillar")
	# --- Road strips: inside the ground, off every block, and with the blocks they cover it all.
	var strips: Array = v["road_strips"]
	for st: Dictionary in strips:
		var sr: Rect2 = st["rect"]
		check(extent.grow(0.01).encloses(sr), tag + ": strip %s %d inside the extent" % [st["kind"], st["line"]])
		for b: Dictionary in blocks:
			check(not sr.grow(-0.01).intersects((b["rect"] as Rect2).grow(-0.01)),
					"%s: strip %s %d off block %d,%d" % [tag, st["kind"], st["line"], b["col"], b["row"]])
	# Sample the ground every 7 m, offset so no point lands on an edge. Messages only built on failure (thousands of points).
	var block_rects: Array[Rect2] = []
	for b: Dictionary in blocks:
		block_rects.append(b["rect"])
	var strip_rects: Array[Rect2] = []
	for st: Dictionary in strips:
		strip_rects.append(st["rect"])
	var bad := 0
	var x := extent.position.x + 0.37
	while x < extent.end.x:
		var s := extent.position.y + 0.53
		while s < extent.end.y:
			var pt := Vector2(x, s)
			var in_blocks := 0
			for br in block_rects:
				if br.has_point(pt):
					in_blocks += 1
			var on_road := false
			for sr in strip_rects:
				if sr.has_point(pt):
					on_road = true
					break
			if not ((in_blocks == 1) != on_road and in_blocks <= 1):
				bad += 1
				if bad <= 5:
					check(false, "%s: %s is in one block or on a road (%d, %s)" % [tag, str(pt), in_blocks, on_road])
			s += 7.0
		x += 7.0
	eq(bad, 0, tag + ": blocks and road strips tile the ground")
	# Strips are per road segment: each carries its index and form, and matches line_segments (the spine split in lanes).
	var by_seg := {}
	for st: Dictionary in strips:
		check(st.has("index") and str(st.get("form", "")) in SectionPlan.FORMS, tag + ": strip has index and form")
		var key := "%s:%d:%d" % [st["axis"], st["line"], st["index"]]
		if not by_seg.has(key):
			by_seg[key] = []
		by_seg[key].append(st)
	eq(by_seg.size(), plan.segments(k).size(), tag + ": strips for every road segment")
	for sg: Dictionary in plan.segments(k):
		var pieces: Array = by_seg.get("%s:%d:%d" % [sg["axis"], sg["line"], sg["index"]], [])
		check(not pieces.is_empty(), tag + ": segment has strips")
		if pieces.is_empty():
			continue
		var u: Rect2 = pieces[0]["rect"]
		for pc: Dictionary in pieces:
			u = u.merge(pc["rect"])
			eq(str(pc["form"]), str(sg["form"]), tag + ": strip form is its segment's")
		check(u.is_equal_approx(sg["rect"]), tag + ": strips of %s %d #%d are its seg rect" % [sg["axis"], sg["line"], sg["index"]])
	# The spine's lanes sit side by side, west to east, and fill the spine (one segment's worth: index 0).
	var lanes := []
	for st: Dictionary in strips:
		if st["axis"] == "s" and int(st["line"]) == plan.spine_line and int(st["index"]) == 0:
			lanes.append(st)
	eq(lanes.size(), SectionPlan.SPINE_LANES.size(), tag + ": one strip per spine lane")
	if lanes.size() == SectionPlan.SPINE_LANES.size():
		for n in lanes.size():
			eq(str(lanes[n]["lane"]), str(SectionPlan.SPINE_LANES[n][0]), tag + ": spine lanes in order")
			if n > 0:
				near((lanes[n]["rect"] as Rect2).position.x, (lanes[n - 1]["rect"] as Rect2).end.x, 1e-3, tag + ": spine lanes adjacent")
		near((lanes[-1]["rect"] as Rect2).end.x - (lanes[0]["rect"] as Rect2).position.x, SectionPlan.SPINE_W, 1e-3, tag + ": spine lanes span the spine")
	# --- Pillars.
	var pils: Array = v["pillars"]
	eq(pils.size(), plan.pillars.size(), tag + ": every pillar")
	for q: Dictionary in pils:
		var half := float(q["half"])
		var cell: Rect2 = blocks[int(q["row"]) * plan.cols + int(q["col"])]["rect"]
		check(cell.encloses(Rect2(float(q["x"]) - half, float(q["s"]) - half, half * 2.0, half * 2.0)), tag + ": pillar %d inside its block" % q["id"])
		eq(bool(q["lift"]), q["kind"] == "lift", tag + ": pillar %d lift flag" % q["id"])
	# --- Connectors.
	var stops := {}
	for cn: Dictionary in v["connectors"]:
		if cn["part"] == "hole":
			check(plan.is_hole(int(cn["id"]), k), tag + ": hole %d cuts this floor" % cn["id"])
		if cn["part"] == "stop":
			stops[int(cn["id"])] = true
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		if c["kind"] == "lift" and (c["stops"] as Array).has(k):
			check(stops.has(ci), tag + ": lift %d stops here" % ci)
	# --- Walls.
	var walls: Array = v["walls"]
	eq(walls.size(), 4, tag + ": four walls")
	for n in mini(walls.size(), 4):
		var edge := SectionPlan.EDGES[n]
		var b := plan.boundary(k, edge)
		eq(str(walls[n]["edge"]), edge, tag + ": walls in EDGES order")
		eq(walls[n]["rect"], plan.boundary_rect(k, edge), tag + ": wall %s rect" % edge)
		eq(str(walls[n]["kind"]), str(b["kind"]), tag + ": wall %s kind" % edge)
		eq(bool(walls[n]["backdrop"]), bool(b["backdrop"]), tag + ": wall %s backdrop" % edge)
		eq(str(walls[n]["gates"]), str(b["gates"]), tag + ": wall %s gates" % edge)


func _geometry() -> void:
	var plan := SectionPlan.make({"seed": 5.0})
	near(plan.clear_height(), 40.0, 0.001, "40 m from floor to ceiling by default")
	near(plan.to_world(plan.deck_count - 1, 0.0, 0.0, 0.0).length(), 0.0, 0.001, "the lowest deck's floor passes through the origin")
	for k in plan.deck_count:
		var ring := plan.ring(k)
		for s in [-120.0, 0.0, 77.0]:
			var a := plan.to_world(k, 12.0, s, 3.0)
			var b := ring.arc_to_world(12.0, s, 3.0) + plan.deck_offset(k)
			check(a.distance_to(b) < 0.001, "to_world matches RingFrame + deck_offset on deck %d" % k)
		near(plan.arc_of(k), plan.span * plan.radius_of(k), 0.001, "lower decks are longer")
		# Cells sit between their roads and never overlap.
		for r in plan.rows:
			for c in plan.cols:
				var rect := plan.cell_rect(k, c, r)
				check(rect.size.x > 20.0 and rect.size.y > 20.0, "cell %d,%d has room (%s)" % [c, r, str(rect.size)])
				if c + 1 < plan.cols:
					check(plan.cell_rect(k, c + 1, r).position.x - rect.end.x >= SectionPlan.ARTERIAL_W - 0.01, "a road between columns")
				if r + 1 < plan.rows:
					check(plan.cell_rect(k, c, r + 1).position.y - rect.end.y >= SectionPlan.ARTERIAL_W - 0.01, "a road between rows")
	var lanes := 0.0
	for l: Array in SectionPlan.SPINE_LANES:
		lanes += float(l[1])
	near(lanes, SectionPlan.SPINE_W, 0.001, "the spine's lanes add up")
	# The top of deck k+1's space is the underside of deck k.
	var under := plan.to_world(0, 0.0, 0.0, -plan.p("slab"))
	var ceil_ := plan.to_world(1, 0.0, 0.0, plan.clear_height())
	check(under.distance_to(ceil_) < 0.001, "deck 1's ceiling is deck 0's underside")
