extends TestCase
## Invader banners hang clear of the facade (docs/design/banners.md "Clear of the facade"; user playtest 2026-11-23: a
## banner hung through an apartment's balconies). For seeds 1, 4, 7, 403112 and every deck, every wall banner's envelope
## (cloth, cross-bar with its end caps, brackets, plus MARGIN) on its face:
##   - meets no relief box of that face (CityFacade.relief: balconies, canopies, awnings, blade signs, alley pipes and
##     hoods, lane lamps and signs: everything standing out RELIEF_MIN or more, deeper than the cloth's back);
##   - lies within the face's width and below its tier's top, its cloth at least CLEARANCE above the ground;
##   - meets no other tier box (its own building's or a neighbour's), plan solid, park column or pillar core;
##   - meets no other banner.
## Computed here from plan data and CityFacade.relief, independently of BannerPlan's own search. Prints the counts per
## seed / deck and the number of offending banners. Before the fix (2026-11-23): 20 of 113 (15 through apartment balconies,
## 3 through lane wall lamps, 2 through lane hanging signs); after: 0 of 113, the same count on every deck.

const SEEDS := [1, 4, 7, 403112]
const MARGIN := 0.3
const HALF := BannerMeshes.W * 0.5 + 0.37        ## the cross-bar's end caps reach this far either side of the centre
const BAR_UP := 0.12                              ## the bar and its caps stand this far above `top`
const CLEARANCE := 1.5


func setup() -> void:
	timeout_sec = 240.0
	check(CityFacade.RELIEF_MIN <= BannerPlan.OUT - 0.22 - 0.05, "relief() lists everything deeper than the cloth's back")
	var bad := 0
	var total := 0
	for sd: int in SEEDS:
		var sec := SectionPlan.make({"seed": float(sd)})
		var counts: Array = []
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var list := BannerPlan.make(plan, sd)
			counts.append(str(list.size()))
			total += list.size()
			bad += _check_deck(plan, list, "seed %d deck %d" % [sd, k])
		print("banner placement: seed %d banners per deck %s" % [sd, ", ".join(counts)])
	print("banner placement: %d banners, %d offending" % [total, bad])
	eq(bad, 0, "no banner clips its facade, a neighbour or another banner (%d of %d)" % [bad, total])
	finish()


## The tier a wall banner hangs on: the first ground tier at least MIN_FACADE tall (BannerPlan.facade_spots).
static func _tier(b: Dictionary) -> int:
	var tiers: Array = b["tiers"]
	for i in tiers.size():
		if float(tiers[i]["y0"]) <= 1.5 and float(tiers[i]["y1"]) >= BannerPlan.MIN_FACADE:
			return i
	return -1


func _check_deck(plan: CityPlan, list: Array, tag: String) -> int:
	var bad := 0
	var envs: Array = []      # [Rect2 plan, y0, y1] per banner
	for bn: Dictionary in list:
		var n: Vector2 = bn["n"]
		var at := Vector2(bn["x"], bn["s"])
		if str(bn["kind"]) != "wall":
			var cx := at + Vector2(BannerMeshes.ARM_X * n.y, 0.0)
			var r := Rect2(at, Vector2.ZERO).expand(cx).grow(BannerMeshes.W * 0.5)
			envs.append([r, BannerMeshes.ARM_H - float(bn["len"]), BannerMeshes.POLE_H])
			continue
		var bi := int(bn["bi"])
		var b: Dictionary = plan.buildings[bi]
		var ti := _tier(b)
		var side := CityPlan.SIDE_N.find(n)
		var face := at - n * BannerPlan.OUT
		var fc := CityFacade.face_coords(plan, bi, ti, side, face)
		var t: Dictionary = b["tiers"][ti]
		var w := (t["size"] as Vector2).y if side < 2 else (t["size"] as Vector2).x
		var top := float(bn["top"])
		var bottom := top - float(bn["len"])
		var why: Array[String] = []
		if absf(fc.y) > 0.05:
			why.append("not on its face (%.2f m off)" % fc.y)
		if fc.x - HALF < 0.0 or fc.x + HALF > w:
			why.append("past the face's end (u %.1f of %.1f)" % [fc.x, w])
		if top + BAR_UP > float(t["y1"]) - 0.3:
			why.append("above its tier's top")
		if bottom < CLEARANCE:
			why.append("cloth %.1f m above the ground" % bottom)
		var u0 := fc.x - HALF - MARGIN
		var u1 := fc.x + HALF + MARGIN
		var v0 := bottom - MARGIN
		var v1 := top + BAR_UP + MARGIN
		for rb: Dictionary in CityFacade.relief(plan, bi, ti)[side]:
			if float(rb["u0"]) < u1 and float(rb["u1"]) > u0 and float(rb["v0"]) < v1 and float(rb["v1"]) > v0:
				why.append("relief u %.1f..%.1f v %.1f..%.1f %.1f m deep" % [rb["u0"], rb["u1"], rb["v0"], rb["v1"], rb["d"]])
				break
		# The envelope in plan space: from just off the wall out past the bar.
		var along := Vector2(n.y, -n.x)
		var p0 := face + along * (u0 - fc.x) + n * 0.02
		var p1 := face + along * (u1 - fc.x) + n * (BannerPlan.OUT + BAR_UP + MARGIN)
		var env := Rect2(p0, Vector2.ZERO).expand(p1)
		envs.append([env, v0, v1])
		var hit := _box_hit(plan, env, v0, v1, bi, ti)
		if hit != "":
			why.append(hit)
		if not why.is_empty():
			bad += 1
			print("  %s banner %d (building %d %s, side %d, u %.1f, top %.1f): %s" % [tag, int(bn["id"]), bi,
				str(b["style"]), side, fc.x, top, "; ".join(why)])
	for i in envs.size():
		for j in range(i + 1, envs.size()):
			var a: Array = envs[i]
			var c: Array = envs[j]
			if (a[0] as Rect2).intersects(c[0]) and float(a[1]) < float(c[2]) and float(c[1]) < float(a[2]):
				bad += 1
				print("  %s banners %d and %d overlap" % [tag, i, j])
	return bad


## The first plan box (tier, solid, column, core) other than tier `ti` of building `bi` the envelope meets, or "".
static func _box_hit(plan: CityPlan, env: Rect2, v0: float, v1: float, bi: int, ti: int) -> String:
	for j in plan.buildings.size():
		var b: Dictionary = plan.buildings[j]
		var c: Vector2 = b["center"]
		var tiers: Array = b["tiers"]
		for k in tiers.size():
			if j == bi and k == ti:
				continue
			var t: Dictionary = tiers[k]
			var sz: Vector2 = t["size"]
			var r := Rect2(c + (t["off"] as Vector2) - sz * 0.5, sz)
			if r.intersects(env) and float(t["y0"]) < v1 and float(t["y1"]) > v0:
				return "building %d tier %d" % [j, k]
		for so: Dictionary in b.get("solids", []):
			var sz: Vector2 = so["size"]
			var r := Rect2(c + (so["off"] as Vector2) - sz * 0.5, sz)
			if r.intersects(env) and float(so["y0"]) < v1 and float(so["y1"]) > v0:
				return "building %d solid %s" % [j, str(so["kind"])]
		if b.has("core") and bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var cs: Vector2 = core["size"]
			if Rect2(Vector2(float(core["x"]), float(core["s"])) - cs * 0.5, cs).intersects(env):
				return "pillar core %d" % j
	for col: Dictionary in plan.columns:
		var h := float(col["half"])
		if Rect2(float(col["x"]) - h, float(col["s"]) - h, h * 2.0, h * 2.0).intersects(env):
			return "column"
	return ""
