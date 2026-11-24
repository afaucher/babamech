extends TestCase
## BULWARK WORLD FIT (docs/design/chassis-rules.md "Bulwark world fit"): the heavy's 3.6 m capsule (7.2 m across, hop-only
## thrust) against the BUILT mission stack, measured with BotFit's physics probes (the real capsule against static
## collision), for several mission seeds and every deck. Per seed:
##   - the mission bot's road graph (BotRoutePlanner: every road line, ramp, shaft, glide) probed edge by edge for the
##     Strider (2.2) and the Bulwark (3.6): which edges each capsule fits, by feature (road width / form / spine lane),
##     with the narrowest clear width measured across each (BotFit.width_at);
##   - ramps (the clear width between the parapets halfway down), shafts (drop height), glides (need thrust height);
##   - the critical path: from the crew spawn to every objective of the plan (sweep: its deck's departure; flag / defend:
##     a point within its radius of the snapped site, reached from the road by a capsule grid walk; the extraction hold:
##     a point inside its zone) on the graph the capsule fits (BotRoutePlanner.fit_body, no glides for a hop-only chassis);
##   - the four crew spawn slots (CityStack.spawn_transforms(4)): each fits a Bulwark capsule, none overlaps another.
## Prints the per-feature table ("[Fit]" lines) and per seed what a Bulwark cannot reach. Checked: the spawn slots fit
## four Bulwarks; every REQUIRED objective (primaries and the hold) is reachable for a Bulwark; every ramp is wide enough.

const SEEDS := [1, 3, 4, 5, 9, 2, 6, 7]
## Required objectives a Bulwark cannot reach in the generated world, as "<seed>:<objective id>": "<why>" (checked as
## known, printed every run; anything else unreachable fails). Empty since 2026-11-24: Environment's fixes (flag / defend
## sites snap to where a 4.1 m disc reaches, tests/test_site_fit.gd; a ramp onto seed 9 deck 1) cleared 4:d1_p, 6:d0_p
## and 9:d1_p. Add an entry only with a world bug handed to Environment.
const KNOWN := {}
## The capsule grid walk from the route's end into an objective: extra path length allowed over the straight line
## (metres, on top of the zone's size), and the most cells it probes.
const WALK_SLACK := 120.0
const WALK_CELLS := 6000
const BULWARK := "bulwark"
const STRIDER := "strider"

var table := {}   # feature -> {n, min_w, strider_ok, bulwark_ok}
var unreachable := {}   # objective type -> count (Bulwark)
var totals := {}        # objective type -> count
var findings: Array = []
var counts := {}         # "required flag" / "bonus flag" / ... -> {n, strider: reached, bulwark: reached}
var bonus_out: Array = []   # bonus objectives a Bulwark cannot reach (allowed by design, reported)


func setup() -> void:
	timeout_sec = 900.0
	var only := OS.get_environment("FIT_SEED")
	var seeds: Array = [int(only)] if only.is_valid_int() else SEEDS
	for s: int in seeds:
		await _seed(s)
	print("[Fit] ==== feature table (narrowest clear width, edges the capsule fits) ====")
	var keys := table.keys()
	keys.sort()
	for f: String in keys:
		var t: Dictionary = table[f]
		print("[Fit] %-28s narrowest %5.1f m  strider fits %4d of %4d (%3.0f%%)  bulwark fits %4d of %4d (%3.0f%%)" % [f,
			float(t["min_w"]), int(t["s_ok"]), int(t["n_s"]), 100.0 * float(t["s_ok"]) / maxf(float(t["n_s"]), 1.0), int(t["b_ok"]),
			int(t["n_b"]), 100.0 * float(t["b_ok"]) / maxf(float(t["n_b"]), 1.0)])
	print("[Fit] objectives unreachable for a Bulwark: %s of %s" % [str(unreachable), str(totals)])
	var ck := counts.keys()
	ck.sort()
	for rk: String in ck:
		var c: Dictionary = counts[rk]
		print("[Fit] reached: %-16s strider %2d of %2d, bulwark %2d of %2d" % [rk, int(c[STRIDER]), int(c["n"]), int(c[BULWARK]),
			int(c["n"])])
	for line: String in bonus_out:
		print("[Fit] bonus out of a Bulwark's reach (allowed, reported): %s" % line)
	finish()


func _seed(seed_n: int) -> void:
	var sec := SectionPlan.make({"seed": float(seed_n)})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	stack.position = -sec.deck_offset(int(sec.entry["deck"]))
	var plan := MissionPlan.make(sec, {})
	var mw := stack.setup_mission(plan)
	for i in 3:
		await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	var what := "seed %d" % seed_n
	# --- spawn slots -------------------------------------------------------------------------------------------
	var rb := BotFit.radius_of(BULWARK)
	var xfs := stack.spawn_transforms(4)
	var k0 := int(sec.entry["deck"])
	var ring0 := stack.deck_ring(k0)
	for i in xfs.size():
		var a := stack.to_deck_arc(xfs[i].origin)
		check(BotFit.clear_at(space, ring0, float(a["x"]), float(a["s"]), rb), "%s: spawn slot %d fits a Bulwark" % [what, i])
		for j in i:
			check(xfs[i].origin.distance_to(xfs[j].origin) >= 2.0 * rb, "%s: spawn slots %d and %d are %.1f m apart (2 x %.1f)" % [
				what, j, i, xfs[i].origin.distance_to(xfs[j].origin), rb])
	# --- the road graph, edge by edge ---------------------------------------------------------------------------
	var p_s := BotRoutePlanner.new()
	p_s.setup(stack)
	var p_b := BotRoutePlanner.new()
	p_b.body_r = rb
	p_b.setup(stack)
	var fit_s := p_s.fit_body(space, BotFit.radius_of(STRIDER), BotFit.height_of(STRIDER), 0.0)
	var fit_b := p_b.fit_body(space, rb, BotFit.height_of(BULWARK), float(MechCatalog.movement(BULWARK)["thrust_ceiling"]))
	print("[Fit] %s: graph %s; strider blocks %d edges + %d ramp legs, bulwark blocks %d + %d ramp legs %s (+ %d glides)" % [what,
		str(p_b.summary()), int(fit_s["blocked"]), int(fit_s.get("ramps", 0)), int(fit_b["blocked"]), int(fit_b.get("ramps", 0)),
		str(fit_b.get("ramp_first", "")), int(fit_b["glides"])])
	for pl: BotRoutePlanner in [p_s, p_b]:
		var bulw := pl == p_b
		var seen := {}
		for eid in pl.edges.size():
			var e: Dictionary = pl.edges[eid]
			if e["kind"] != "walk":
				continue
			var key := Vector2i(mini(int(e["a"]), int(e["b"])), maxi(int(e["a"]), int(e["b"])))
			if seen.has(key):
				continue
			seen[key] = true
			var k := int(e["from"])
			var a := pl.on_deck(k, (e["pts"] as Array)[0])
			var b := pl.on_deck(k, (e["pts"] as Array)[-1])
			var f := _feature(stack.decks[k].plan, sec, a, b)
			var w := INF
			var dir := (b - a).normalized()
			var n := maxi(int(a.distance_to(b) / 6.0), 1)
			for i in range(1, n):
				w = minf(w, BotFit.width_at(space, stack.deck_ring(k), a.lerp(b, float(i) / float(n)), dir))
			_tally(f, w, bulw, not pl.unfit.has(eid))
			if bulw and pl.unfit.has(eid) and (f.begins_with("spine") or f.begins_with("street")):
				print("[Fit] %s: deck %d %s edge (%.0f, %.0f)-(%.0f, %.0f) too narrow for a Bulwark (narrowest %.1f m)" % [what, k, f,
					a.x, a.y, b.x, b.y, w])
	# --- ramps, shafts, glides --------------------------------------------------------------------------------
	for ci in sec.connectors.size():
		var cn: Dictionary = sec.connectors[ci]
		if cn["kind"] == "ramp" and not bool(cn["locked"]):
			var low := int(cn["to"])
			var lane := Vector2(float(cn["x0"]), float(cn["x1"]))
			var s_mid := (sec.line_s(low, int(cn["top_line"])) + sec.line_s(low, int(cn["foot_line"]))) * 0.5
			var hit := _ramp_surface(space, stack, low, (lane.x + lane.y) * 0.5, s_mid)
			var w := BotFit.width_at(space, stack.deck_ring(low), Vector2((lane.x + lane.y) * 0.5, s_mid), Vector2(0, 1), hit)
			_tally("ramp", w, false, w > 2.0 * BotFit.radius_of(STRIDER))
			_tally("ramp", w, true, w > 2.0 * rb)
			check(w > 2.0 * rb + 0.4, "%s: ramp %d (deck %d -> %d) is %.1f m wide between its parapets (a Bulwark needs %.1f)" % [
				what, ci, int(cn["from"]), low, w, 2.0 * rb + 0.4])
		elif cn["kind"] == "shaft":
			var k := int(cn["from"])
			var c := sec.connector_rect(ci, k).get_center()
			var j := k + 1
			while j < sec.deck_count and p_b.in_cut(j, Vector2(c.x, c.y / sec.radius_of(k) * sec.radius_of(j)), 0.5):
				j += 1
			if j < sec.deck_count:
				print("[Fit] %s: shaft %d drops deck %d -> %d: %.1f m" % [what, ci, k, j, absf(sec.radius_of(j) - sec.radius_of(k))])
	# --- the critical path ------------------------------------------------------------------------------------
	var a0 := stack.to_deck_arc(stack.entry_transform().origin)
	var start := Vector2(float(a0["x"]), float(a0["s"]))
	for o: Dictionary in plan.objectives:
		var id := str(o["id"])
		var k := int(o["deck"])
		var typ := str(o["type"])
		var req: bool = str(o["role"]) == "primary" or typ == "hold"
		var site := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
		var radius := float(o.get("radius", 0.0))
		var zone := Rect2()
		match typ:
			"flag":
				var fs := mw.flag_site(id)
				if not fs.is_empty():
					site = Vector2(float(fs["x"]), float(fs["s"]))
			"defend":
				var ds := mw.asset_site(id)
				if not ds.is_empty():
					site = Vector2(float(ds["x"]), float(ds["s"]))
			"hold":
				zone = (o["params"] as Dictionary)["zone"]
				site = zone.get_center()
		var tag := "%s %s (%s %s, deck %d)" % [what, id, o["role"], typ, k]
		var rs := _reach(space, stack, p_s, k0, start, k, site, radius, zone, BotFit.radius_of(STRIDER))
		var rbw := _reach(space, stack, p_b, k0, start, k, site, radius, zone, rb)
		totals[typ] = int(totals.get(typ, 0)) + 1
		if not rbw["ok"]:
			unreachable[typ] = int(unreachable.get(typ, 0)) + 1
		var rk := "%s %s" % ["required" if req else "bonus", typ]
		var cnt: Dictionary = counts.get_or_add(rk, {"n": 0, STRIDER: 0, BULWARK: 0})
		cnt["n"] = int(cnt["n"]) + 1
		cnt[STRIDER] = int(cnt[STRIDER]) + (1 if rs["ok"] else 0)
		cnt[BULWARK] = int(cnt[BULWARK]) + (1 if rbw["ok"] else 0)
		if not rbw["ok"] and not req:
			bonus_out.append("%s: %s" % [tag, str(rbw["why"])])
		print("[Fit] %s: strider %s, bulwark %s%s" % [tag, "reaches" if rs["ok"] else "CANNOT (%s)" % rs["why"],
			"reaches" if rbw["ok"] else "CANNOT (%s)" % rbw["why"], " (route %s)" % str(rbw["by"]) if rbw["ok"] else ""])
		if not rbw["ok"] and rs["ok"] and rs.has("path"):
			# Where the Strider's way in is narrowest (what keeps the Bulwark out).
			var path: Array = rs["path"]
			var wmin := INF
			var at := Vector2.INF
			for i in range(1, path.size()):
				var pa: Vector2 = path[i - 1]
				var pb: Vector2 = path[i]
				if pa.distance_to(pb) < 0.1:
					continue
				var w := BotFit.width_at(space, stack.deck_ring(k), pb, (pb - pa).normalized())
				if w < wmin:
					wmin = w
					at = pb
			print("[Fit] %s: the Strider's way in is narrowest at deck %d x %.1f s %.1f: %.1f m clear (a Bulwark needs %.1f)" % [
				tag, k, at.x, at.y, wmin, 2.0 * rb])
			var dplan := stack.decks[k].plan
			if at != Vector2.INF:
				for bi in dplan.buildings.size():
					var bd: Dictionary = dplan.buildings[bi]
					for t: Dictionary in bd["tiers"]:
						var tr := dplan.tier_rect(bi, t)
						if tr.grow(5.0).has_point(at) and float(t["y0"]) < 8.0:
							print("[Fit]   beside it: building %d (%s%s) tier %s y %.1f..%.1f" % [bi, str(bd.get("style", "")),
								" " + str(bd.get("base", "")) if bd.has("base") else "", str(tr), float(t["y0"]), float(t["y1"])])
					for so: Dictionary in bd.get("solids", []):
						var sz: Vector2 = so["size"]
						var sr := Rect2((bd["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz)
						if sr.grow(5.0).has_point(at) and float(so["y0"]) < 8.0:
							print("[Fit]   beside it: building %d solid %s %s y %.1f..%.1f" % [bi, str(so.get("kind", "")), str(sr),
								float(so["y0"]), float(so["y1"])])
				for col: Dictionary in dplan.columns:
					if Vector2(float(col["x"]), float(col["s"])).distance_to(at) < 8.0:
						print("[Fit]   beside it: column at (%.1f, %.1f) half %.1f" % [float(col["x"]), float(col["s"]), float(col["half"])])
			findings.append({"seed": seed_n, "id": id, "type": typ, "role": o["role"], "deck": k, "site": site, "narrow_at": at,
				"width": wmin})
		if req:
			var known := KNOWN.has("%d:%s" % [seed_n, id])
			if known:
				print("[Fit] KNOWN (Environment note, %s): %s %s for a Bulwark" % [str(KNOWN["%d:%s" % [seed_n, id]]), tag,
					"still unreachable" if not rbw["ok"] else "NOW REACHABLE: drop it from KNOWN"])
			else:
				check(bool(rbw["ok"]) or not bool(rs["ok"]), "%s: a Bulwark reaches it (%s)" % [tag, str(rbw["why"])])
	mw.teardown(false)
	stack.queue_free()
	await frames(2)


## (route found, the end within reach of the site): plan on the planner's (fitted) graph, then a capsule grid walk from
## the route's end into the zone.
func _reach(space: PhysicsDirectSpaceState3D, stack: CityStack, pl: BotRoutePlanner, k0: int, p0: Vector2, k: int,
		site: Vector2, radius: float, zone: Rect2, r: float) -> Dictionary:
	var legs := pl.plan(k0, p0, k, site, true)
	if legs.is_empty():
		return {"ok": false, "why": "no route: %s" % pl.last_error, "by": []}
	var by: Array = []
	for l: Dictionary in legs:
		if l["kind"] != "walk":
			by.append(l["kind"])
	var end := pl.on_deck(k, (legs[-1]["pts"] as Array)[-1])
	if radius <= 0.0 and zone.size == Vector2.ZERO:
		return {"ok": true, "why": "", "by": by}   # a sweep: the deck is reached
	var inside := func(p: Vector2) -> bool:
		if zone.size != Vector2.ZERO:
			return zone.grow(-1.0).has_point(p)
		return p.distance_to(site) <= radius * 0.9
	var ring := stack.deck_ring(k)
	var plan := stack.decks[k].plan
	# Grid walk (2 m, best-first toward the site) from the clear points of the route's last stretch into the zone, the
	# capsule clear at every step. The window is the deck (its extent, less the capsule) intersected with an ellipse around
	# the route's end and the site (sum of distances <= their distance + slack), so a route that ends far from the site
	# (the graph's nearest node can be 80 m off, deep downtown blocks) still gets a walk in; a fixed disc around the site
	# used to drop every cell of such a walk before it began.
	var stp := 2.0
	var slack := 2.0 * (radius + zone.size.length() * 0.5) + WALK_SLACK
	var reach_d := end.distance_to(site) + slack
	var deck := plan.extent.grow(-r)
	var cap := WALK_CELLS
	var heap: Array = []   # [priority, point], a binary min-heap
	var seen := {}
	var last: Array = legs[-1]["pts"]
	var lp := pl.on_deck(k, last[maxi(last.size() - 2, 0)])
	var m := maxi(int(lp.distance_to(end) / stp), 1)
	for i in m + 1:
		var p := lp.lerp(end, float(i) / float(m))
		var key := Vector2i(roundi((p.x - end.x) / stp), roundi((p.y - end.y) / stp))
		if seen.has(key):
			continue
		seen[key] = true
		if not pl.in_cut(k, p, 1.0) and BotFit.clear_at(space, ring, p.x, p.y, r):
			if inside.call(p):
				return {"ok": true, "why": "", "by": by, "path": [p]}
			_heap_push(heap, p.distance_to(site), p)
	var par := {}
	var gcost := {}
	var n := 0
	while not heap.is_empty() and n < cap:
		var c: Vector2 = _heap_pop(heap)
		var ckey := Vector2i(roundi((c.x - end.x) / stp), roundi((c.y - end.y) / stp))
		n += 1
		for d: Vector2 in [Vector2(stp, 0), Vector2(-stp, 0), Vector2(0, stp), Vector2(0, -stp)]:
			var p := c + d
			var key := Vector2i(roundi((p.x - end.x) / stp), roundi((p.y - end.y) / stp))
			if seen.has(key) or not deck.has_point(p) or p.distance_to(site) + p.distance_to(end) > reach_d:
				continue
			seen[key] = true
			if pl.in_cut(k, p, 1.0) or not BotFit.clear_at(space, ring, p.x, p.y, r):
				continue
			par[key] = c
			gcost[key] = float(gcost.get(ckey, 0.0)) + stp
			if inside.call(p):
				var path: Array = [p]
				var cur := c
				while path.size() < 400:
					path.push_front(cur)
					var ck := Vector2i(roundi((cur.x - end.x) / stp), roundi((cur.y - end.y) / stp))
					if not par.has(ck):
						break
					cur = par[ck]
				return {"ok": true, "why": "", "by": by, "path": path}
			_heap_push(heap, float(gcost[key]) + p.distance_to(site), p)
	var blk := "street"
	for bi in plan.blocks.size():
		if (plan.blocks[bi]["rect"] as Rect2).has_point(site):
			blk = "block %d %s%s%s" % [bi, str(plan.blocks[bi]["rect"]), " downtown" if plan.downtown_blocks().has(bi) else "",
				" zone %s" % str(plan.blocks[bi].get("zone", "")) ]
	return {"ok": false, "why": "site (%.0f, %.0f) in %s; route ends %.0f m from it, no clear way in (%d cells%s)" % [site.x, site.y,
		blk, end.distance_to(site), n, ", cell cap hit" if n >= cap else ""], "by": by}


func _heap_push(h: Array, pri: float, p: Vector2) -> void:
	h.append([pri, p])
	var i := h.size() - 1
	while i > 0:
		var j := (i - 1) / 2
		if float(h[j][0]) <= pri:
			break
		var t: Array = h[j]
		h[j] = h[i]
		h[i] = t
		i = j


func _heap_pop(h: Array) -> Vector2:
	var top: Vector2 = h[0][1]
	var tail: Array = h.pop_back()
	if h.is_empty():
		return top
	h[0] = tail
	var i := 0
	while true:
		var l := 2 * i + 1
		var m := i
		if l < h.size() and float(h[l][0]) < float(h[m][0]):
			m = l
		if l + 1 < h.size() and float(h[l + 1][0]) < float(h[m][0]):
			m = l + 1
		if m == i:
			break
		var t: Array = h[m]
		h[m] = h[i]
		h[i] = t
		i = m
	return top


## The ramp's surface height (above deck `low`'s floor) at its lane centre, by a ray down from the upper deck's floor.
func _ramp_surface(space: PhysicsDirectSpaceState3D, stack: CityStack, low: int, x: float, s: float) -> float:
	var ring := stack.deck_ring(low)
	var top := ring.arc_to_world(x, s, 30.0)
	var q := PhysicsRayQueryParameters3D.create(top, ring.arc_to_world(x, s, -1.0))
	var hit := BotFit._static_ray(space, q)
	if hit.is_empty():
		return 0.0
	return ring.height(hit["position"])


## What kind of road the edge a-b runs along: "spine:<lane>" on the transit spine's lanes, else "<form> <width> m".
func _feature(plan: CityPlan, sec: SectionPlan, a: Vector2, b: Vector2) -> String:
	var along_s := absf(a.x - b.x) < 0.01
	var mid := (a + b) * 0.5
	if along_s:
		for i in plan.roads_x.size():
			var rd: Dictionary = plan.roads_x[i]
			if mid.x >= float(rd["a"]) - 0.01 and mid.x <= float(rd["b"]) + 0.01:
				if rd.has("lanes"):
					for l: Dictionary in rd["lanes"]:
						if mid.x >= float(l["a"]) - 0.01 and mid.x <= float(l["b"]) + 0.01:
							return "spine:%s" % str(l["lane"])
				return "%s %.0f m" % [_form(plan, "s", i, mid.y), float(rd["b"]) - float(rd["a"])]
	else:
		for j in plan.roads_s.size():
			var rd: Dictionary = plan.roads_s[j]
			if mid.y >= float(rd["a"]) - 0.01 and mid.y <= float(rd["b"]) + 0.01:
				return "%s %.0f m" % [_form(plan, "x", j, mid.x), float(rd["b"]) - float(rd["a"])]
	return "other"


func _form(plan: CityPlan, axis: String, line: int, at: float) -> String:
	var cross: Array = plan.roads_s if axis == "s" else plan.roads_x
	for idx in cross.size() - 1:
		if at >= float(cross[idx]["b"]) and at <= float(cross[idx + 1]["a"]):
			return plan.seg_form(axis, line, idx)
	return "crossing"


func _tally(f: String, w: float, bulwark: bool, ok: bool) -> void:
	var t: Dictionary = table.get_or_add(f, {"n_s": 0, "n_b": 0, "min_w": INF, "s_ok": 0, "b_ok": 0})
	t["n_b" if bulwark else "n_s"] = int(t["n_b" if bulwark else "n_s"]) + 1
	t["min_w"] = minf(float(t["min_w"]), w)
	if ok:
		t["b_ok" if bulwark else "s_ok"] = int(t["b_ok" if bulwark else "s_ok"]) + 1
