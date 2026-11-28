class_name SectionEncounters
extends RefCounted
## The crossing of each deck as the enemy spawner sees it (docs/design/mission-section.md §16): arrival, departure and
## encounter sites derived from a finished SectionPlan. Pure reads of the plan: no rolls, no stored state, so they can
## never shift generation or SectionPlan.checksum(), and every machine derives the same list.

const SAFE_RADIUS := 70.0        ## encounter sites closer than this to a deck's arrival get no enemies (§16)
const FIRST_CONTACT_DIST := 110.0   ## how far past the arrival the first enemy group waits, along the avenue (§16)
const FIRST_CONTACT_SHARE := 0.4    ## ... but at most this fraction of the deck's arrival -> departure distance along s
const MERGE_DIST := 40.0        ## encounter sites closer than this are one place (the more specific kind wins)
## Encounter site kinds, most specific first: on a merge the earlier kind names the site (sites).
const SITE_PRIORITY: Array[String] = ["extraction", "departure", "checkpoint", "shaft_exit", "branch_landing", "holding",
		"station", "patrol", "cordon", "first_contact"]
const SITE_WEIGHT := {"light": 1.0, "medium": 2.0, "heavy": 4.0}


## Where the crew first sets foot on deck k following the critical path: {deck, kind: road_door | ramp | lift | shaft, x,
## s, connector (id, -1 for the road door)}, in deck k's (x, s). Deck 0: on the avenue's centre on the perimeter road just
## inside the entry road door (the entry node). Below: the landing of the critical connector down from deck k-1 (where a
## ramp's slope run ends on deck k, run_foot; a lift's platform centre).
static func arrival(plan: SectionPlan, k: int) -> Dictionary:
	if k <= 0:
		return _end_point(plan, 0, "road_door", -1, _avenue_mid(plan), plan.line_s(0, int(plan.entry["j"])))
	var ci := _critical_between(plan, k - 1)
	if ci < 0:
		return _end_point(plan, k, "road_door", -1, _avenue_mid(plan), 0.0)
	var c: Dictionary = plan.connectors[ci]
	var rect := plan.connector_rect(ci, k)
	if c["kind"] == "ramp":
		return _end_point(plan, k, "ramp", ci, rect.get_center().x, plan.ramp_run(ci, k).y)
	return _end_point(plan, k, str(c["kind"]), ci, rect.get_center().x, rect.get_center().y)


## Where the crew leaves deck k: same shape as arrival(), kind ramp | lift | road_door. The head of the critical
## connector down from deck k (where a ramp's slope run starts on deck k, run_top; a lift's platform centre); on the
## lowest deck the extraction node in front of the exit road door, on the avenue's centre like the entry (kind
## "road_door", connector -1).
static func departure(plan: SectionPlan, k: int) -> Dictionary:
	if k >= plan.deck_count - 1:
		var last := plan.deck_count - 1
		return _end_point(plan, last, "road_door", -1, _avenue_mid(plan), plan.line_s(last, int(plan.extraction["j"])))
	var ci := _critical_between(plan, k)
	if ci < 0:
		return _end_point(plan, k, "road_door", -1, _avenue_mid(plan), 0.0)
	var c: Dictionary = plan.connectors[ci]
	var rect := plan.connector_rect(ci, k)
	if c["kind"] == "ramp":
		return _end_point(plan, k, "ramp", ci, rect.get_center().x, plan.ramp_run(ci, k).x)
	return _end_point(plan, k, str(c["kind"]), ci, rect.get_center().x, rect.get_center().y)


## The places on deck k worth an enemy group, by `progress` ascending: [{deck, kind, x, s, progress, dist, weight, share,
## safe}] (+ connector and size on a checkpoint, loop on a patrol, connector on a departure). Kinds: first_contact (a
## synthetic site on the avenue, FIRST_CONTACT_DIST past the arrival), checkpoint / station / patrol / holding / cordon
## (from hooks), shaft_exit (landing under a shaft from above), branch_landing (stop of a non-critical connector, e.g. the
## locked express lift), departure (departure(k)) or, on the lowest deck, extraction. Sites closer than MERGE_DIST are one
## (heavier weight, kind by SITE_PRIORITY). progress: 0..1 projection on arrival -> departure; dist: metres from the
## arrival; safe: dist < SAFE_RADIUS (nothing spawns there, share 0); share: the site's fraction of the deck's enemy budget
## (weight 1 / 2 / 4 x (0.6 + 0.8 x progress), normalised over the non-safe sites).
static func sites(plan: SectionPlan, k: int) -> Array[Dictionary]:
	var a := arrival(plan, k)
	var d := departure(plan, k)
	var av := Vector2(float(a["x"]), float(a["s"]))
	var dv := Vector2(float(d["x"]), float(d["s"]))
	var raw: Array[Dictionary] = []
	# First contact: up the avenue toward the way down, short enough to stay in the first third of the crossing.
	var along := dv.y - av.y
	var dir := signf(along) if absf(along) > 1.0 else float(int(plan.decks[k]["dir"]))
	var reach := minf(FIRST_CONTACT_DIST, absf(along) * FIRST_CONTACT_SHARE)
	raw.append({"kind": "first_contact", "x": _avenue_mid(plan), "s": av.y + dir * reach, "weight": "light"})
	for h: Dictionary in plan.hooks:
		if int(h["deck"]) != k:
			continue
		match str(h["kind"]):
			"checkpoint":
				raw.append({"kind": "checkpoint", "x": float(h["x"]), "s": float(h["s"]), "weight": str(h["size"]),
						"connector": int(h["connector"]), "size": str(h["size"])})
			"station", "cordon":
				raw.append({"kind": str(h["kind"]), "x": float(h["x"]), "s": float(h["s"]), "weight": "light"})
			"patrol":
				raw.append({"kind": "patrol", "x": float(h["x"]), "s": float(h["s"]), "weight": "light",
						"loop": (h["loop"] as Array).duplicate()})
			"holding":
				raw.append({"kind": "holding", "x": float(h["x"]), "s": float(h["s"]), "weight": "medium"})
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		var mid := plan.connector_rect(ci, k).get_center()
		if c["kind"] == "shaft":
			if int(c["to"]) == k:
				raw.append({"kind": "shaft_exit", "x": mid.x, "s": mid.y, "weight": "medium"})
		elif c["role"] != "critical" and (c["stops"] as Array).has(k):
			raw.append({"kind": "branch_landing", "x": mid.x, "s": mid.y, "weight": "medium"})
	raw.append({"kind": "extraction" if k == plan.deck_count - 1 else "departure", "x": dv.x, "s": dv.y, "weight": "heavy",
			"connector": int(d["connector"])})
	# Merge: most specific first; a site within MERGE_DIST of one already kept folds into it.
	var order := range(raw.size())
	order.sort_custom(func(i: int, j: int) -> bool:
		var pi := SITE_PRIORITY.find(str(raw[i]["kind"]))
		var pj := SITE_PRIORITY.find(str(raw[j]["kind"]))
		return pi < pj or (pi == pj and i < j))
	var w := plan.p("width")
	var arc := plan.arc_of(k)
	var kept: Array[Dictionary] = []
	for i: int in order:
		var site: Dictionary = raw[i]
		site["x"] = clampf(float(site["x"]), -w * 0.5, w * 0.5)
		site["s"] = clampf(float(site["s"]), -arc * 0.5, arc * 0.5)
		var at := Vector2(float(site["x"]), float(site["s"]))
		var into := -1
		var best := MERGE_DIST
		for n in kept.size():
			var gap := at.distance_to(Vector2(float(kept[n]["x"]), float(kept[n]["s"])))
			if gap < best:
				best = gap
				into = n
		if into < 0:
			kept.append(site)
		elif SITE_WEIGHT[site["weight"]] > SITE_WEIGHT[kept[into]["weight"]]:
			kept[into]["weight"] = site["weight"]
	# Place every site on the crossing, then split the budget.
	var axis := dv - av
	var len2 := axis.length_squared()
	var total := 0.0
	for site in kept:
		var at := Vector2(float(site["x"]), float(site["s"]))
		site["deck"] = k
		site["dist"] = at.distance_to(av)
		site["progress"] = clampf((at - av).dot(axis) / len2, 0.0, 1.0) if len2 > 1.0 else 0.0
		site["safe"] = float(site["dist"]) < SAFE_RADIUS
		site["share"] = 0.0 if site["safe"] else float(SITE_WEIGHT[site["weight"]]) * (0.6 + 0.8 * float(site["progress"]))
		total += float(site["share"])
	for site in kept:
		site["share"] = float(site["share"]) / total if total > 0.0 else 0.0
	kept.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if x["progress"] != y["progress"]:
			return x["progress"] < y["progress"]
		if x["dist"] != y["dist"]:
			return x["dist"] < y["dist"]
		return SITE_PRIORITY.find(str(x["kind"])) < SITE_PRIORITY.find(str(y["kind"])))
	return kept


## The critical (route) connector that takes the crew from deck k down to deck k+1, or -1: one that starts on deck k
## (a ramp first: a ramp added by the hop-only repair can share its pair with a lift merged into another's pillar), else
## one passing deck k.
static func _critical_between(plan: SectionPlan, k: int) -> int:
	var any := -1
	var here := -1
	for ci in plan.connectors.size():
		var c: Dictionary = plan.connectors[ci]
		if c["role"] != "critical" or c["kind"] == "shaft" or int(c["from"]) > k or int(c["to"]) < k + 1:
			continue
		if int(c["from"]) == k:
			if c["kind"] == "ramp":
				return ci
			if here < 0:
				here = ci
		if any < 0:
			any = ci
	return here if here >= 0 else any


static func _avenue_mid(plan: SectionPlan) -> float:
	var av := plan.lane_x("avenue")
	return (av.x + av.y) * 0.5


static func _end_point(plan: SectionPlan, k: int, kind: String, ci: int, x: float, s: float) -> Dictionary:
	var half := plan.arc_of(k) * 0.5
	return {"deck": k, "kind": kind, "x": clampf(x, -plan.p("width") * 0.5, plan.p("width") * 0.5), "s": clampf(s, -half, half),
			"connector": ci}
