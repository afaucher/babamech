class_name MissionPlan
extends RefCounted
## What the mission is: the objectives on every deck, the doors waves can use and each deck's wave pool, derived on
## every machine from the section plan and the mission seed (docs/design/mission-objectives.md §9). Pure data: no nodes,
## no network, no clock, one seeded generator (a stream of its own, so SectionPlan never shifts). `checksum()` joins the
## load barrier: equal on two machines = the same mission.
##
## All positions are a deck's arc coordinates (x, s, metres), like SectionPlan.
##
##   objectives  [{id, type: sweep | flag | defend | hold, deck, role: primary | bonus, site: {x, s}, radius,
##                 needs: [ids], params}]
##                 ids "d<k>_p" (the deck's primary), "d<k>_b<n>" (bonuses), "hold" (last: the extraction hold).
##                 params: flag {hold: 20.0}; defend {waves: 2 (pool < 4 waves) | 3, asset_hp: 1.0}; hold {hold: s, zone: Rect2}; sweep {}.
##                 radius: flag 14, defend 30, sweep 0 (deck-wide; site = the deck's departure), hold 0 (params.zone).
##                 snap: how far the world may move the site to clear ground: SNAP (45) on flag and defend, 0 otherwise.
##                 Bonuses sit BONUS_GAP (2 x MERGE_DIST + SNAP = 125 m) from the primary and each other (except a
##                 chain defend, at its flag's site), so two snapped sites never merge.
##                 A deck whose primary is a sweep has no linger wave (all its free waves are garrison_low), and its
##                 pool's first slot is always a free garrison_low wave (a sweep ends on a fight); the extraction
##                 deck's hold wave keeps its slot too, and bonus flag alarms take what is left (a bonus flag with no
##                 slot left has no alarm wave).
##   sources     [{id, deck, kind: gate | lift | ramp | shaft, x, s, toward: {x, s}, load, connector, edge}]
##                 (x, s): the point just in front of the door where units appear (gate: on its road line, 8 m inside
##                 the wall; lift: platform centre moved toward the spine by the lift pillar's radius + 4 m; ramp: the
##                 centre of the ramp end on that deck, 4 m beyond it along the lane; shaft: the landing's centre).
##                 toward: a POINT ~20 m further along the walking direction, clamped inside the deck.
##                 connector: SectionPlan connector id (-1 for gates); edge: the gate's wall ("" otherwise).
##                 Never within SectionPlan.SAFE_RADIUS of the deck's arrival. ids "d<k>_gate_<edge>_<line>",
##                 "d<k>_lift_<connector>", "d<k>_ramp_<connector>", "d<k>_shaft_<connector>".
##   pools       [{deck, garrison: 0.5 | 1.0, waves: [{id: "d<k>_w<n>", share, theme: light | mixed | heavy, source,
##                 trigger: {kind: objective, id, step: start | done} | {kind: garrison_low} | {kind: linger, after}}]}]
##                 A flag's one alarm wave triggers on step "done" (the flag raised); a defend's params.waves waves and
##                 the hold's wave (the extraction deck's last) on step "start". A deck without sources has no waves and
##                 garrison 1.0.
##
## Options (make's overrides): types (step-1 types allowed for placement), bonus_max, hold (extraction hold seconds),
## waves_per_deck, linger (seconds before the lingering wave), primary ("" = rolled; "sweep" | "flag" | "defend":
## every deck's primary is that type wherever the deck allows it (flag: a primary site; defend: a site, a source within
## DEFEND_REACH and room for 2 waves; sweep: the departure outside the arrival's SAFE_RADIUS), ignoring `types` and the first deck's flag / sweep preference; a
## deck that cannot have it keeps the rolled type. The roll still happens, so the generator advances as without it.
## "" leaves every plan identical to before the option existed).
## primary_types(): each deck's primary type in deck order (not the hold). find_seed(type, opts): the first seed with an
## unforced primary of that type (for bots and tests).

const DEFAULTS := {"types": ["sweep", "flag", "defend"], "bonus_max": 2, "hold": 60.0, "waves_per_deck": 2,
		"linger": 360.0, "primary": ""}
const PRIMARY_TYPES: Array[String] = ["sweep", "flag", "defend"]
const RADIUS := {"flag": 14.0, "defend": 30.0, "sweep": 0.0, "hold": 0.0}
const FLAG_HOLD := 20.0
const LOAD := {"gate": 6, "lift": 4, "ramp": 6, "shaft": 4}
const KINDS: Array[String] = ["gate", "lift", "ramp", "shaft"]
const DEFEND_REACH := 250.0      ## a defend objective needs a source this close to its site
const WAVES_CAP := 4             ## most waves a deck's pool holds
const SHARE_GROWTH := 1.25       ## each wave of a deck ~25 % bigger than the one before
const GATE_INSET := 8.0          ## a gate's units appear this far inside the wall
const DOOR_GAP := 4.0            ## lift lobby / ramp end: this far beyond the door
const TOWARD := 20.0             ## `toward` lies this much further along the walking direction
const OFF_ROUTE_KINDS: Array[String] = ["departure", "extraction", "first_contact"]
const SNAP := 45.0               ## how far the world may move a flag mast / defend asset to clear ground (record "snap")
const BONUS_GAP := SectionPlan.MERGE_DIST * 2.0 + SNAP   ## bonuses this far from the primary and each other (125 m)

var options: Dictionary = {}
var deck_count := 0
var section_checksum := ""
var objectives: Array[Dictionary] = []
var sources: Array[Dictionary] = []
var pools: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission settings, fixed at creation, same everywhere
		# all of the below are recomputed from the section plan + options on every machine and verified by checksum()
		"deck_count": Net.LOCAL, "section_checksum": Net.LOCAL, "objectives": Net.LOCAL, "sources": Net.LOCAL,
		"pools": Net.LOCAL, "_rng": Net.LOCAL,
	}


static func make(sec: SectionPlan, overrides: Dictionary = {}) -> MissionPlan:
	var m := MissionPlan.new()
	m.options = DEFAULTS.duplicate(true)
	for id: String in overrides:
		if m.options.has(id):
			m.options[id] = overrides[id]
	var types: Array = []
	for t: Variant in m.options["types"]:
		if str(t) in ["sweep", "flag", "defend"] and not types.has(str(t)):
			types.append(str(t))
	m.options["types"] = types
	m.options["bonus_max"] = maxi(int(m.options["bonus_max"]), 0)
	m.options["hold"] = maxf(float(m.options["hold"]), 0.0)
	m.options["waves_per_deck"] = maxi(int(m.options["waves_per_deck"]), 0)
	m.options["linger"] = maxf(float(m.options["linger"]), 0.0)
	m.options["primary"] = str(m.options["primary"]) if PRIMARY_TYPES.has(str(m.options["primary"])) else ""
	m.deck_count = sec.deck_count
	m.section_checksum = sec.checksum()
	m._rng.seed = int(sec.p("seed")) * 1597334677 + 2654435761
	m._make_sources(sec)
	m._make_objectives(sec)
	m._make_pools(sec)
	return m


# --- Queries ---------------------------------------------------------------------------------------------

func objective(id: String) -> Dictionary:
	for o: Dictionary in objectives:
		if o["id"] == id:
			return o
	return {}


func source(id: String) -> Dictionary:
	for s: Dictionary in sources:
		if s["id"] == id:
			return s
	return {}


func deck_objectives(k: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for o: Dictionary in objectives:
		if int(o["deck"]) == k:
			out.append(o)
	return out


func deck_sources(k: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Dictionary in sources:
		if int(s["deck"]) == k:
			out.append(s)
	return out


func pool(k: int) -> Dictionary:
	for p: Dictionary in pools:
		if int(p["deck"]) == k:
			return p
	return {}


## The deck's primary objective ({} if none).
func primary(k: int) -> Dictionary:
	for o: Dictionary in objectives:
		if int(o["deck"]) == k and o["role"] == "primary" and o["type"] != "hold":
			return o
	return {}


## Each deck's primary type, in deck order (the hold excluded).
func primary_types() -> Array[String]:
	var out: Array[String] = []
	for k in deck_count:
		out.append(str(primary(k).get("type", "")))
	return out


## The first seed >= from (at most `tries` seeds) whose default plan, unforced, has a primary of `type`; -1 if none.
## `opts` goes to SectionPlan.make (its own keys, e.g. decks; not seed) and MissionPlan.make (its keys, not primary).
static func find_seed(type: String, opts: Dictionary = {}, from: int = 1, tries: int = 200) -> int:
	var sec_opts := {}
	var mis_opts := {}
	for key: Variant in opts:
		if SectionPlan.DEFAULTS.has(key) and str(key) != "seed":
			sec_opts[key] = opts[key]
		if DEFAULTS.has(key) and str(key) != "primary":
			mis_opts[key] = opts[key]
	for s in range(from, from + maxi(tries, 0)):
		var so := sec_opts.duplicate()
		so["seed"] = float(s)
		if MissionPlan.make(SectionPlan.make(so), mis_opts).primary_types().has(type):
			return s
	return -1


## Id of the source on deck k nearest to `at`, leaving out the ids in `skip`; "" if none.
func nearest_source(k: int, at: Vector2, skip: Array = []) -> String:
	var best := ""
	var best_d := INF
	for s: Dictionary in sources:
		if int(s["deck"]) != k or skip.has(s["id"]):
			continue
		var d := at.distance_to(Vector2(float(s["x"]), float(s["s"])))
		if d < best_d:
			best_d = d
			best = s["id"]
	return best


# --- Sources ---------------------------------------------------------------------------------------------

func _make_sources(sec: SectionPlan) -> void:
	var per_deck: Array = []
	for k in deck_count:
		per_deck.append([])
	var w := sec.p("width")
	var avenue := sec.lane_x("avenue")
	var spine_x := (avenue.x + avenue.y) * 0.5
	# Gates: every blast door in a boundary wall.
	for b: Dictionary in sec.boundaries:
		var k := int(b["deck"])
		var a := sec.arc_of(k)
		var edge := str(b["edge"])
		for g: Dictionary in b["gates"]:
			if g["kind"] != "blast_door":
				continue
			var inward: Vector2
			var at: Vector2
			match edge:
				"s0":
					inward = Vector2(0.0, 1.0)
					at = Vector2(float(g["x"]), -a * 0.5)
				"s1":
					inward = Vector2(0.0, -1.0)
					at = Vector2(float(g["x"]), a * 0.5)
				"x0":
					inward = Vector2(1.0, 0.0)
					at = Vector2(-w * 0.5, float(g["s"]))
				_:
					inward = Vector2(-1.0, 0.0)
					at = Vector2(w * 0.5, float(g["s"]))
			_add_source(sec, per_deck, k, "gate", "d%d_gate_%s_%d" % [k, edge, int(g["line"])], at + inward * GATE_INSET,
					inward, -1, edge)
	# Lifts, ramps, shafts.
	for ci in sec.connectors.size():
		var c: Dictionary = sec.connectors[ci]
		match str(c["kind"]):
			"lift":
				for k: int in c["stops"]:
					var mid := sec.connector_rect(ci, k).get_center()
					var dir := Vector2(signf(spine_x - mid.x) if absf(spine_x - mid.x) > 0.01 else 1.0, 0.0)
					var half := sec.pillar_radius(k, int(c["pillar"])) if int(c["pillar"]) >= 0 else SectionPlan.LIFT_HALF
					_add_source(sec, per_deck, k, "lift", "d%d_lift_%d" % [k, ci], mid + dir * (half + DOOR_GAP), dir, ci, "")
			"ramp":
				var x := (float(c["x0"]) + float(c["x1"])) * 0.5
				var th_top: float = sec.row_theta[int(c["top_line"])]
				var th_foot: float = sec.row_theta[int(c["foot_line"])]
				var up := signf(th_top - th_foot)
				var kt := int(c["from"])
				var kf := int(c["to"])
				var top_dir := Vector2(0.0, up)
				_add_source(sec, per_deck, kt, "ramp", "d%d_ramp_%d" % [kt, ci],
						Vector2(x, th_top * sec.radius_of(kt)) + top_dir * DOOR_GAP, top_dir, ci, "")
				_add_source(sec, per_deck, kf, "ramp", "d%d_ramp_%d" % [kf, ci],
						Vector2(x, th_foot * sec.radius_of(kf)) - top_dir * DOOR_GAP, -top_dir, ci, "")
			"shaft":
				var k := int(c["to"])
				var mid := sec.connector_rect(ci, k).get_center()
				var dir := Vector2(signf(spine_x - mid.x) if absf(spine_x - mid.x) > 0.01 else 1.0, 0.0)
				_add_source(sec, per_deck, k, "shaft", "d%d_shaft_%d" % [k, ci], mid, dir, ci, "")
	for k in deck_count:
		var list: Array = per_deck[k]
		list.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
			var a := KINDS.find(str(p["kind"]))
			var b := KINDS.find(str(q["kind"]))
			return a < b or (a == b and str(p["id"]) < str(q["id"])))
		for s: Dictionary in list:
			sources.append(s)


func _add_source(sec: SectionPlan, per_deck: Array, k: int, kind: String, id: String, at: Vector2, dir: Vector2,
		connector: int, edge: String) -> void:
	var ext := _extent(sec, k)
	var pt := Vector2(clampf(at.x, ext.position.x, ext.end.x), clampf(at.y, ext.position.y, ext.end.y))
	var arr := sec.arrival(k)
	if pt.distance_to(Vector2(float(arr["x"]), float(arr["s"]))) < SectionPlan.SAFE_RADIUS:
		return
	var inner := ext.grow(-1.0)
	var tw := pt + dir * TOWARD
	tw = Vector2(clampf(tw.x, inner.position.x, inner.end.x), clampf(tw.y, inner.position.y, inner.end.y))
	(per_deck[k] as Array).append({"id": id, "deck": k, "kind": kind, "x": pt.x, "s": pt.y,
			"toward": {"x": tw.x, "s": tw.y}, "load": int(LOAD[kind]), "connector": connector, "edge": edge})


static func _extent(sec: SectionPlan, k: int) -> Rect2:
	var w := sec.p("width")
	var a := sec.arc_of(k)
	return Rect2(-w * 0.5, -a * 0.5, w, a)


# --- Objectives ------------------------------------------------------------------------------------------

## Waves deck k's pool holds (0 without a source): waves_per_deck, +1 per two decks of depth, at most WAVES_CAP.
func wave_count(k: int) -> int:
	if deck_sources(k).is_empty():
		return 0
	@warning_ignore("integer_division")
	var depth := k / 2
	return clampi(int(options["waves_per_deck"]) + depth, 0, WAVES_CAP)


func _make_objectives(sec: SectionPlan) -> void:
	var types: Array = options["types"]
	var ex_deck := int(sec.extraction["deck"])
	var primaries: Array = []
	for k in deck_count:
		var sites := sec.encounter_sites(k)
		var dep := sec.departure(k)
		# Waves this deck can still tie to an objective (the extraction deck keeps its last for the hold).
		var room := wave_count(k) - (1 if k == ex_deck and wave_count(k) > 0 else 0)
		var site := _primary_site(sites)
		var cands: Array = []
		if not site.is_empty():
			for t: String in ["flag", "defend", "sweep"]:
				if not types.has(t):
					continue
				if t == "defend" and (not _source_near(k, site) or room < 2):
					continue
				cands.append(t)
			if k == 0 and (cands.has("flag") or cands.has("sweep")):
				cands.erase("defend")
		var ptype := "sweep"
		if not cands.is_empty():
			ptype = str(cands[_rng.randi_range(0, cands.size() - 1)])
		# A forced primary type replaces the roll where the deck allows it (same conditions as the candidates above).
		# A sweep's site is the departure: forced only where that is outside the arrival bubble.
		var forced := str(options["primary"])
		var arr := sec.arrival(k)
		var dep_ok := Vector2(float(dep["x"]), float(dep["s"])).distance_to(Vector2(float(arr["x"]), float(arr["s"]))) \
				>= SectionPlan.SAFE_RADIUS
		if (forced == "sweep" and dep_ok) or (forced == "flag" and not site.is_empty()) or (forced == "defend"
				and not site.is_empty() and _source_near(k, site) and room >= 2):
			ptype = forced
		var pid := "d%d_p" % k
		var p: Dictionary
		if ptype == "sweep":
			p = _record(pid, "sweep", k, "primary", Vector2(float(dep["x"]), float(dep["s"])), [])
			room -= mini(room, 1)    # a sweep ends on a fight: its pool's first slot is a free wave
		else:
			p = _record(pid, ptype, k, "primary", Vector2(float(site["x"]), float(site["s"])), [])
			room -= _waves_of(p, room)
		objectives.append(p)
		primaries.append(pid)
		# Bonuses.
		var bmax := int(options["bonus_max"])
		if bmax <= 0:
			continue
		var want := _rng.randi_range(1, bmax)
		var n := 0
		var p_at := Vector2(float(p["site"]["x"]), float(p["site"]["s"]))
		if ptype == "flag" and types.has("defend") and _rng.randf() < 0.5 and room >= 2 and _source_near(k, p["site"]):
			var b := _record("d%d_b%d" % [k, n], "defend", k, "bonus", p_at, [pid])
			room -= _waves_of(b, room)
			objectives.append(b)
			n += 1
		if not types.has("flag"):
			continue
		var used: Array[Vector2] = [p_at]
		for st: Dictionary in _off_route(sites, sec, k):
			if n >= want:
				break
			var at := Vector2(float(st["x"]), float(st["s"]))
			var ok := true
			for u in used:
				if at.distance_to(u) < BONUS_GAP:
					ok = false
					break
			if not ok:
				continue
			var b := _record("d%d_b%d" % [k, n], "flag", k, "bonus", at, [])
			room -= _waves_of(b, room)
			objectives.append(b)
			used.append(at)
			n += 1
	var zone := MissionRules.extraction_zone(sec, float(MissionRules.DEFAULTS["zone_depth"]))
	var h := _record("hold", "hold", ex_deck, "primary", zone.get_center(), primaries)
	h["params"] = {"hold": float(options["hold"]), "zone": zone}
	objectives.append(h)


func _record(id: String, type: String, k: int, role: String, at: Vector2, needs: Array) -> Dictionary:
	var params := {}
	match type:
		"flag":
			params = {"hold": FLAG_HOLD}
		"defend":
			params = {"waves": 2 if wave_count(k) < 4 else 3, "asset_hp": 1.0}
	return {"id": id, "type": type, "deck": k, "role": role, "site": {"x": at.x, "s": at.y}, "radius": float(RADIUS[type]),
			"snap": SNAP if type == "flag" or type == "defend" else 0.0, "needs": needs.duplicate(), "params": params}


## Waves the objective takes from the deck's pool (fits it into `room`): a flag one alarm wave, a defend its params.waves.
func _waves_of(o: Dictionary, room: int) -> int:
	match str(o["type"]):
		"flag":
			return 1 if room >= 1 else 0
		"defend":
			o["params"]["waves"] = mini(int(o["params"]["waves"]), room)
			return int(o["params"]["waves"])
	return 0


func _source_near(k: int, site: Dictionary) -> bool:
	var at := Vector2(float(site["x"]), float(site["s"]))
	for s: Dictionary in deck_sources(k):
		if at.distance_to(Vector2(float(s["x"]), float(s["s"]))) <= DEFEND_REACH:
			return true
	return false


## The primary's site: the heaviest non-departure, non-safe site in the far half (progress >= 0.5); else the farthest
## along the crossing; {} when the deck has none (it gets a sweep).
static func _primary_site(sites: Array[Dictionary]) -> Dictionary:
	var best: Dictionary = {}
	for st: Dictionary in sites:
		if st["safe"] or OFF_ROUTE_KINDS.slice(0, 2).has(str(st["kind"])) or float(st["progress"]) < 0.5:
			continue
		if best.is_empty() or SectionPlan.SITE_WEIGHT[st["weight"]] > SectionPlan.SITE_WEIGHT[best["weight"]] \
				or (SectionPlan.SITE_WEIGHT[st["weight"]] == SectionPlan.SITE_WEIGHT[best["weight"]] \
				and float(st["progress"]) > float(best["progress"])):
			best = st
	if not best.is_empty():
		return best
	for st: Dictionary in sites:
		if st["safe"] or OFF_ROUTE_KINDS.slice(0, 2).has(str(st["kind"])):
			continue
		if best.is_empty() or float(st["progress"]) > float(best["progress"]):
			best = st
	return best


## Bonus candidates: non-safe sites that are not on the avenue route (departure, extraction, first contact), farthest
## from the arrival -> departure line first.
static func _off_route(sites: Array[Dictionary], sec: SectionPlan, k: int) -> Array[Dictionary]:
	var a := sec.arrival(k)
	var d := sec.departure(k)
	var av := Vector2(float(a["x"]), float(a["s"]))
	var dv := Vector2(float(d["x"]), float(d["s"]))
	var out: Array[Dictionary] = []
	for st: Dictionary in sites:
		if st["safe"] or OFF_ROUTE_KINDS.has(str(st["kind"])):
			continue
		var c := st.duplicate()
		c["off"] = _seg_dist(Vector2(float(st["x"]), float(st["s"])), av, dv)
		out.append(c)
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		if absf(float(p["off"]) - float(q["off"])) > 0.001:
			return float(p["off"]) > float(q["off"])
		return float(p["progress"]) < float(q["progress"]))
	return out


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	return p.distance_to(a + ab * clampf((p - a).dot(ab) / l2, 0.0, 1.0))


# --- Pools -----------------------------------------------------------------------------------------------

func _make_pools(sec: SectionPlan) -> void:
	var ex_deck := int(sec.extraction["deck"])
	for k in deck_count:
		var n := wave_count(k)
		if n == 0:
			pools.append({"deck": k, "garrison": 1.0, "waves": []})
			continue
		# Triggers: [trigger, objective site] in wave order: free waves first, then objective waves in plan order, then
		# the hold's (the extraction deck's last wave).
		# Same room accounting as _make_objectives (plan order: primary, then bonuses), so every flag that got its alarm
		# wave there gets it here.
		var room := n - (1 if k == ex_deck else 0)
		if primary(k)["type"] == "sweep":
			room -= mini(room, 1)    # the sweep's free wave (same accounting as _make_objectives)
		var tied: Array = []
		for o: Dictionary in deck_objectives(k):
			var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
			var take := 0
			match str(o["type"]):
				"flag":
					take = 1 if room >= 1 else 0
				"defend":
					take = int(o["params"]["waves"])
			# A flag's wave answers the raised flag (step done: "raising the flag raises the alarm"); a defend's waves
			# are its schedule (step start).
			var step := "done" if o["type"] == "flag" else "start"
			for i in take:
				tied.append([{"kind": "objective", "id": o["id"], "step": step}, at])
			room -= take
		var hold_wave: Array = []
		if k == ex_deck:
			var h := objective("hold")
			hold_wave = [{"kind": "objective", "id": "hold", "step": "start"},
					Vector2(float(h["site"]["x"]), float(h["site"]["s"]))]
		var free := n - tied.size() - (1 if not hold_wave.is_empty() else 0)
		var p := primary(k)
		var p_at := Vector2(float(p["site"]["x"]), float(p["site"]["s"]))
		var trig: Array = []
		# A sweep deck delivers its whole free pool as the crew kills it: no linger wave there.
		var linger: bool = free >= 2 and p["type"] != "sweep"
		for i in maxi(free, 0):
			if i == free - 1 and linger:
				trig.append([{"kind": "linger", "after": float(options["linger"])}, p_at])
			else:
				trig.append([{"kind": "garrison_low"}, p_at])
		trig.append_array(tied)
		if not hold_wave.is_empty():
			trig.append(hold_wave)
		var total := 0.0
		for i in trig.size():
			total += pow(SHARE_GROWTH, float(i))
		var waves: Array = []
		for i in trig.size():
			var themes := ["light", "mixed", "heavy"]
			waves.append({"id": "d%d_w%d" % [k, i], "share": pow(SHARE_GROWTH, float(i)) / total,
					"theme": themes[mini(i * 3 / trig.size(), 2)], "source": nearest_source(k, trig[i][1]),
					"trigger": trig[i][0]})
		pools.append({"deck": k, "garrison": 0.5, "waves": waves})


# --- Checksum --------------------------------------------------------------------------------------------

## Hex digest of the whole mission (includes the section's checksum). Equal on two machines = the same mission.
func checksum() -> String:
	var buf := StreamPeerBuffer.new()
	buf.put_utf8_string(section_checksum)
	buf.put_32(deck_count)
	for o: Dictionary in objectives:
		buf.put_utf8_string("%s:%s:%s:%s" % [o["id"], o["type"], o["role"], ",".join(PackedStringArray(o["needs"]))])
		buf.put_32(int(o["deck"]))
		_put(buf, [o["site"]["x"], o["site"]["s"], o["radius"], o.get("snap", 0.0)])
		var keys: Array = (o["params"] as Dictionary).keys()
		keys.sort()
		for key: String in keys:
			buf.put_utf8_string(key)
			var v: Variant = o["params"][key]
			if v is Rect2:
				_put(buf, [v.position.x, v.position.y, v.size.x, v.size.y])
			else:
				_put(buf, [v])
	for s: Dictionary in sources:
		buf.put_utf8_string("%s:%s:%s" % [s["id"], s["kind"], s["edge"]])
		for v in [s["deck"], s["load"], s["connector"]]:
			buf.put_32(int(v))
		_put(buf, [s["x"], s["s"], s["toward"]["x"], s["toward"]["s"]])
	for p: Dictionary in pools:
		buf.put_32(int(p["deck"]))
		_put(buf, [p["garrison"]])
		for wv: Dictionary in p["waves"]:
			var tr: Dictionary = wv["trigger"]
			buf.put_utf8_string("%s:%s:%s:%s:%s:%s" % [wv["id"], wv["theme"], wv["source"], tr["kind"], tr.get("id", ""),
					tr.get("step", "")])
			_put(buf, [wv["share"], tr.get("after", 0.0)])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))
