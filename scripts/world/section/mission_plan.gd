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
##                 A deck whose primary is a sweep keeps its pool's first slot for a free group (a sweep ends on a
##                 fight); the extraction
##                 deck's hold wave keeps its slot too, and flags take what is left; a flag with no slot left gets an
##                 extra wave taken from the garrison share (pool garrison < 0.5, never below GARRISON_MIN), so every
##                 flag on a deck with sources has its start wave.
##                 Flag sites (primary and bonus) sit >= FLAG_SOURCE_GAP (60 m) from every source on the deck where the
##                 deck has such a site; else the candidate farthest from its nearest source.
##   sources     [{id, deck, kind: gate | lift | ramp | shaft, x, s, toward: {x, s}, load, connector, edge}]
##                 (x, s): the point just in front of the door where units appear (gate: on its road line, 8 m inside
##                 the wall; lift: platform centre moved toward the spine by the lift pillar's radius + 4 m; ramp: the
##                 centre of the ramp end on that deck, 4 m beyond it along the lane; shaft: the landing's centre).
##                 toward: a POINT ~20 m further along the walking direction, clamped inside the deck.
##                 connector: SectionPlan connector id (-1 for gates); edge: the gate's wall ("" otherwise).
##                 Never within SectionPlan.SAFE_RADIUS of the deck's arrival. ids "d<k>_gate_<edge>_<line>",
##                 "d<k>_lift_<connector>", "d<k>_ramp_<connector>", "d<k>_shaft_<connector>".
##   pools       [{deck, garrison: 0.5 | 1.0, reserve: [{id: "d<k>_w<n>", share, theme: light | mixed | heavy, source,
##                 for: "" | objective id}]}]   (docs/design/pacing-director.md 1.1)
##                 The deck's garrison share and its RESERVE: ordered groups, light first, with no trigger: the
##                 PacingDirector decides when each goes. Free groups (for "") first, then the objective groups in plan
##                 order (a flag's one group, a defend's params.waves groups), the extraction deck's hold group last.
##                 source: the planned source (a flag's group: flag_source(), 80-200 m from the site preferred, >= 60 m;
##                 others: nearest to the deck's primary / the objective); the director picks the real one at release.
##                 A deck without sources has no reserve and garrison 1.0. Size: wave_count(k) + the deck's extra flag
##                 groups.
##   depots      [{id: "d<k>_depot<n>", deck, site: {x, s}, cores, snap}] military supply depots (pacing-director.md §2):
##                 1 or 2 per deck (2 on a deck with a defend objective or the extraction hold; else rolled), each at a
##                 non-safe encounter site, >= DEPOT_SOURCE_GAP from every source and >= DEPOT_OBJECTIVE_GAP from the deck's
##                 objective sites where the deck allows it (else the site farthest from its nearest source), two on a deck
##                 >= DEPOT_GAP apart where possible. A second depot needs a site clear of the sources (else the deck has
##                 one); a deck with no non-safe encounter site has none. Depot n of a deck with anchors (depot_anchors:
##                 its defend sites, then the hold zone) prefers a site DEPOT_NEAR_MIN..DEPOT_NEAR_MAX (60-150 m) from
##                 anchor n, the one nearest DEPOT_NEAR_BEST (after the source, depot-gap and objective-gap rules). cores: per
##                 pilot in the crew at mission start, at least DEPOT_CORES_MIN per depot (MissionDepots resolves it).
##                 Drawn LAST from a generator of their own, so objectives / sources / pools are byte-identical to a plan
##                 without depots (checksum(false) is that plan's checksum). snap: how far the world may move it (DEPOT_SNAP).
##
## Options (make's overrides): types (step-1 types allowed for placement), bonus_max, hold (extraction hold seconds),
## waves_per_deck (reserve groups per deck before depth), primary ("" = rolled; "sweep" | "flag" | "defend":
## every deck's primary is that type wherever the deck allows it (flag: a primary site; defend: a site, a source within
## DEFEND_REACH and room for 2 waves; sweep: the departure outside the arrival's SAFE_RADIUS), ignoring `types` and the first deck's flag / sweep preference; a
## deck that cannot have it keeps the rolled type. Each deck's objective and depot generators start from the state the
## UNFORCED plan had there (make() builds it first and replays its _deck_states / _depot_states), so a deck whose type is
## unchanged by the option is byte-identical to the unforced plan's, whatever was forced on the decks before it (a flag
## draws a defend-bonus coin, other types do not; a defend deck draws a second depot). "" leaves every plan identical to
## before the option existed).
## primary_types(): each deck's primary type in deck order (not the hold). find_seed(type, opts): the first seed with an
## unforced primary of that type (for bots and tests).

const DEFAULTS := {"types": ["sweep", "flag", "defend"], "bonus_max": 2, "hold": 60.0, "waves_per_deck": 2,
		"primary": ""}
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
const FLAG_SOURCE_GAP := 60.0    ## a flag site at least this far from every source on its deck, where the deck allows
const FLAG_WAVE_NEAR := 80.0     ## a flag's start wave comes preferably from a source FLAG_WAVE_NEAR..FLAG_WAVE_FAR m away
const FLAG_WAVE_FAR := 200.0
const GARRISON_MIN := 0.25       ## a flag wave beyond the deck's pool room is taken from the garrison, down to this
const DEPOT_SOURCE_GAP := 60.0   ## a depot at least this far from every source on its deck, where the deck allows
const DEPOT_OBJECTIVE_GAP := 60.0   ## ... and this far from the deck's objective sites, where possible
const DEPOT_GAP := 80.0          ## two depots of one deck at least this far apart, where possible
const DEPOT_CORES := 1           ## power cores per pilot in the crew at mission start ...
const DEPOT_CORES_MIN := 2       ## ... but never fewer than this per depot (defend balance 2026-11-24: solo got 1)
const DEPOT_NEAR_MIN := 60.0     ## a deck's depot n sits this far ...
const DEPOT_NEAR_MAX := 150.0    ## ... to this far from its anchor n (the defend sites, then the hold zone) where it can
const DEPOT_NEAR_BEST := 100.0   ## ... the candidate nearest this distance wins (a short walk back to the objective)
const DEPOT_SNAP := 25.0         ## how far the world may move a depot to clear ground
## Off the roads (2026-11-24, a depot on a road line wedged the bot): a planned site is moved into the nearest cell's
## buildable inside (SectionPlan.cell_rect: the cell minus every road line round it), at least this far in from its edge
## (the turned 6 x 4 m footprint's half-diagonal 3.6 + the 4 m clear margin): never on a carriageway, lane, pedestrian
## street or crossing. MissionDepots then snaps it to clear ground with the same keep-out.
const DEPOT_LOT_INSET := 7.6
const DEPOT_SAME := 10.0         ## two depots of a deck never closer than this (two sites may move into one lot corner)

var options: Dictionary = {}
var deck_count := 0
var section_checksum := ""
var objectives: Array[Dictionary] = []
var sources: Array[Dictionary] = []
var pools: Array[Dictionary] = []
var depots: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
## The objective generator's state at the start of each deck, and the depot generator's (recorded on every plan; a plan
## with a forced primary replays the unforced plan's, so forcing one deck never shifts another deck's draws).
var _deck_states: Array = []
var _depot_states: Array = []


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the mission settings, fixed at creation, same everywhere
		# all of the below are recomputed from the section plan + options on every machine and verified by checksum()
		"deck_count": Net.LOCAL, "section_checksum": Net.LOCAL, "objectives": Net.LOCAL, "sources": Net.LOCAL,
		"pools": Net.LOCAL, "depots": Net.LOCAL, "_rng": Net.LOCAL, "_deck_states": Net.LOCAL, "_depot_states": Net.LOCAL,
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
	m.options["primary"] = str(m.options["primary"]) if PRIMARY_TYPES.has(str(m.options["primary"])) else ""
	m.deck_count = sec.deck_count
	m.section_checksum = sec.checksum()
	m._rng.seed = int(sec.p("seed")) * 1597334677 + 2654435761
	# A forced primary: each deck's generators start where the UNFORCED plan's did (its draws on one deck depend on the
	# deck's primary type, e.g. the flag's defend-bonus coin), so the other decks roll exactly as without the option.
	var replay: MissionPlan = null
	if str(m.options["primary"]) != "":
		var plain: Dictionary = m.options.duplicate(true)
		plain["primary"] = ""
		replay = MissionPlan.make(sec, plain)
	m._make_sources(sec)
	m._make_objectives(sec, replay._deck_states if replay != null else [])
	m._make_pools(sec)
	m._make_depots(sec, replay._depot_states if replay != null else [])    # last, own generator: nothing above shifts
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


func depot(id: String) -> Dictionary:
	for d: Dictionary in depots:
		if d["id"] == id:
			return d
	return {}


func deck_depots(k: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: Dictionary in depots:
		if int(d["deck"]) == k:
			out.append(d)
	return out


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


## `replay`: the generator state per deck to start from (a forced primary: the unforced plan's _deck_states).
func _make_objectives(sec: SectionPlan, replay: Array = []) -> void:
	var types: Array = options["types"]
	var ex_deck := int(sec.extraction["deck"])
	var primaries: Array = []
	for k in deck_count:
		if k < replay.size():
			_rng.state = int(replay[k])
		_deck_states.append(_rng.state)
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
		if ptype == "flag":
			site = _flag_site(sites, k)    # clear of the deck's sources (after the roll: the generator is unchanged)
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
		for st: Dictionary in _clear_first(k, _off_route(sites, sec, k)):
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
	var zone := MissionRules.extraction_zone(sec, MissionRules.ZONE_DEPTH)
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


## Distance from `at` to the nearest source on deck k (INF without sources).
func source_clearance(k: int, at: Vector2) -> float:
	var best := INF
	for s: Dictionary in deck_sources(k):
		best = minf(best, at.distance_to(Vector2(float(s["x"]), float(s["s"]))))
	return best


## A primary flag's site: _primary_site over the sites at least FLAG_SOURCE_GAP from every source on the deck; when
## none is, the candidate farthest from its nearest source.
func _flag_site(sites: Array[Dictionary], k: int) -> Dictionary:
	var clear: Array[Dictionary] = []
	for st: Dictionary in sites:
		if source_clearance(k, Vector2(float(st["x"]), float(st["s"]))) >= FLAG_SOURCE_GAP:
			clear.append(st)
	var best := _primary_site(clear)
	if not best.is_empty():
		return best
	var far := -1.0
	for st: Dictionary in sites:
		if st["safe"] or OFF_ROUTE_KINDS.slice(0, 2).has(str(st["kind"])):
			continue
		var c := source_clearance(k, Vector2(float(st["x"]), float(st["s"])))
		if best.is_empty() or c > far:
			best = st
			far = c
	return best if not best.is_empty() else _primary_site(sites)


## Bonus flag candidates: those clear of every source (FLAG_SOURCE_GAP) first, in their order; then the rest, farthest
## from their nearest source first.
func _clear_first(k: int, cands: Array[Dictionary]) -> Array[Dictionary]:
	var clear: Array[Dictionary] = []
	var rest: Array[Dictionary] = []
	for st: Dictionary in cands:
		var c := source_clearance(k, Vector2(float(st["x"]), float(st["s"])))
		st["clear"] = c
		if c >= FLAG_SOURCE_GAP:
			clear.append(st)
		else:
			rest.append(st)
	rest.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["clear"]) > float(q["clear"]))
	clear.append_array(rest)
	return clear


## The planned source of a flag's start wave: one FLAG_WAVE_NEAR..FLAG_WAVE_FAR m from the site (nearest), else
## FLAG_SOURCE_GAP..300 m (nearest), else farther (nearest), else the farthest of the rest; "" without sources.
## `closed`: source ids left out. PacingDirector uses the same ranking at release time (from the snapped site).
func flag_source(k: int, at: Vector2, closed: Dictionary = {}) -> String:
	var best := ""
	var best_key := Vector2(INF, INF)
	for s: Dictionary in deck_sources(k):
		if closed.has(s["id"]):
			continue
		var key := flag_source_rank(at.distance_to(Vector2(float(s["x"]), float(s["s"]))))
		if key.x < best_key.x or (key.x == best_key.x and key.y < best_key.y):
			best_key = key
			best = s["id"]
	return best


## (rank, tie-break) of a source `d` m from a flag site; lower is better (see flag_source).
static func flag_source_rank(d: float) -> Vector2:
	if d >= FLAG_WAVE_NEAR and d <= FLAG_WAVE_FAR:
		return Vector2(0, d)
	if d >= FLAG_SOURCE_GAP and d <= PacingDirector.MAX_SOURCE_DIST:
		return Vector2(1, d)
	if d > PacingDirector.MAX_SOURCE_DIST:
		return Vector2(2, d)
	return Vector2(3, -d)


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
			pools.append({"deck": k, "garrison": 1.0, "reserve": []})
			continue
		# Slots: [objective id ("" free), objective site, flag?] in reserve order: free groups first, then objective groups
		# in plan order, then the hold's (the extraction deck's last group).
		# Same room accounting as _make_objectives (plan order: primary, then bonuses), so every flag that got its alarm
		# wave there gets it here.
		var room := n - (1 if k == ex_deck else 0)
		if primary(k)["type"] == "sweep":
			room -= mini(room, 1)    # the sweep's free wave (same accounting as _make_objectives)
		var tied: Array = []
		var extra := 0      # flag waves beyond the pool's room (taken from the garrison share)
		for o: Dictionary in deck_objectives(k):
			var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
			var take := 0
			match str(o["type"]):
				"flag":
					# Every flag has one wave, ordered when its capture starts (step start: the crew holds the flag
					# under attack). Beyond the room it is an extra wave taken from the garrison share.
					take = 1
					if room >= 1:
						room -= 1
					else:
						extra += 1
				"defend":
					take = int(o["params"]["waves"])    # its schedule (step start)
					room -= take
			for i in take:
				tied.append([str(o["id"]), at, o["type"] == "flag"])
		var hold_wave: Array = []
		if k == ex_deck:
			var h := objective("hold")
			hold_wave = ["hold", Vector2(float(h["site"]["x"]), float(h["site"]["s"]))]
		var free := n - (tied.size() - extra) - (1 if not hold_wave.is_empty() else 0)
		var p := primary(k)
		var p_at := Vector2(float(p["site"]["x"]), float(p["site"]["s"]))
		var trig: Array = []
		for i in maxi(free, 0):
			trig.append(["", p_at])
		trig.append_array(tied)
		if not hold_wave.is_empty():
			trig.append(hold_wave)
		var total := 0.0
		for i in trig.size():
			total += pow(SHARE_GROWTH, float(i))
		# Extra flag waves come out of the garrison: the wave share grows so the first n waves keep their size (at most
		# down to GARRISON_MIN garrison).
		var garrison := 0.5
		if extra > 0:
			var base := 0.0
			for i in n:
				base += pow(SHARE_GROWTH, float(i))
			garrison = maxf(1.0 - (1.0 - garrison) * total / base, GARRISON_MIN)
		var reserve: Array = []
		for i in trig.size():
			var themes := ["light", "mixed", "heavy"]
			var at: Vector2 = trig[i][1]
			var src := flag_source(k, at) if trig[i].size() > 2 and bool(trig[i][2]) else nearest_source(k, at)
			reserve.append({"id": "d%d_w%d" % [k, i], "share": pow(SHARE_GROWTH, float(i)) / total,
					"theme": themes[mini(i * 3 / trig.size(), 2)], "source": src, "for": str(trig[i][0])})
		pools.append({"deck": k, "garrison": garrison, "reserve": reserve})


# --- Depots ----------------------------------------------------------------------------------------------

## The deck's objective points a depot keeps clear of (flag / defend sites, the hold zone's centre; not a sweep's).
func _objective_points(k: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for o: Dictionary in deck_objectives(k):
		if str(o["type"]) != "sweep":
			out.append(Vector2(float(o["site"]["x"]), float(o["site"]["s"])))
	return out


## `replay`: the depot generator's state per deck to start from (a forced primary: the unforced plan's _depot_states).
func _make_depots(sec: SectionPlan, replay: Array = []) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(sec.p("seed")) * 2246822519 + 3266489917
	var ex_deck := int(sec.extraction["deck"])
	for k in deck_count:
		if k < replay.size():
			rng.state = int(replay[k])
		_depot_states.append(rng.state)
		var two := k == ex_deck
		for o: Dictionary in deck_objectives(k):
			if str(o["type"]) == "defend":
				two = true
		var roll := rng.randi_range(1, 2)    # drawn on every deck, so one deck's rule never shifts the next's
		var want := 2 if two else roll
		var cands: Array[Dictionary] = []
		var arr := sec.arrival(k)
		var arr_at := Vector2(float(arr["x"]), float(arr["s"]))
		for st: Dictionary in sec.encounter_sites(k):
			if bool(st["safe"]):
				continue
			var lot := depot_site_for(sec, k, Vector2(float(st["x"]), float(st["s"])))
			if lot.distance_to(arr_at) < SectionPlan.SAFE_RADIUS:
				continue
			var c := st.duplicate()
			c["x"] = lot.x
			c["s"] = lot.y
			cands.append(c)
		var objs := _objective_points(k)
		var anchors := depot_anchors(k)
		var chosen: Array[Vector2] = []
		for n in want:
			var anchor: Variant = anchors[n] if n < anchors.size() else null
			var best_tier := 99
			var group: Array[Dictionary] = []
			for st: Dictionary in cands:
				var at := Vector2(float(st["x"]), float(st["s"]))
				var dup := false
				for c in chosen:
					dup = dup or at.distance_to(c) < DEPOT_SAME
				if dup:
					continue
				var tier := 0
				if source_clearance(k, at) < DEPOT_SOURCE_GAP:
					tier += 8
				for c in chosen:
					if at.distance_to(c) < DEPOT_GAP:
						tier += 4
						break
				for p in objs:
					if at.distance_to(p) < DEPOT_OBJECTIVE_GAP:
						tier += 2
						break
				if anchor != null:
					var da := at.distance_to(anchor as Vector2)
					if da < DEPOT_NEAR_MIN or da > DEPOT_NEAR_MAX:
						tier += 1
				if tier < best_tier:
					best_tier = tier
					group = []
				if tier == best_tier:
					group.append(st)
			var pick := rng.randi_range(0, maxi(group.size() - 1, 0))
			if anchor != null and not group.is_empty():
				# Near an objective: the candidate nearest DEPOT_NEAR_BEST from it (the draw above still happens).
				var bd := INF
				for i in group.size():
					var dd := absf(Vector2(float(group[i]["x"]), float(group[i]["s"])).distance_to(anchor as Vector2) - DEPOT_NEAR_BEST)
					if dd < bd:
						bd = dd
						pick = i
			if group.is_empty() or (n > 0 and best_tier >= 8):
				break    # a second depot only on a site clear of the sources

			if best_tier >= 8:
				# No site clear of the sources: the one farthest from its nearest source.
				var far := -1.0
				for i in group.size():
					var c := source_clearance(k, Vector2(float(group[i]["x"]), float(group[i]["s"])))
					if c > far:
						far = c
						pick = i
			var at := Vector2(float(group[pick]["x"]), float(group[pick]["s"]))
			chosen.append(at)
			depots.append({"id": "d%d_depot%d" % [k, n], "deck": k, "site": {"x": at.x, "s": at.y}, "cores": DEPOT_CORES,
					"snap": DEPOT_SNAP})


## Where a depot planned at encounter site `at` on deck k goes: the nearest point of any cell's buildable inside
## (SectionPlan.cell_rect) inset by DEPOT_LOT_INSET, so off every road line and crossing. `at` itself when no cell is
## big enough (never in the section plans tested).
static func depot_site_for(sec: SectionPlan, k: int, at: Vector2) -> Vector2:
	var best := at
	var best_d := INF
	for c in sec.cols:
		for r in sec.rows:
			var cr := sec.cell_rect(k, c, r).grow(-DEPOT_LOT_INSET)
			if cr.size.x < 0.0 or cr.size.y < 0.0:
				continue
			var p := Vector2(clampf(at.x, cr.position.x, cr.end.x), clampf(at.y, cr.position.y, cr.end.y))
			var d := p.distance_to(at)
			if d < best_d - 1e-6:
				best_d = d
				best = p
	return best


## The points deck k's depots are placed near (defend balance, 2026-11-24): its defend sites (primary first), then the
## hold zone's centre; depot n prefers DEPOT_NEAR_MIN..DEPOT_NEAR_MAX m from anchor n (straight line: a pure plan has no
## walk routes; a road walk is a little longer).
func depot_anchors(k: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for role: String in ["primary", "bonus"]:
		for o: Dictionary in deck_objectives(k):
			if str(o["type"]) == "defend" and str(o["role"]) == role:
				out.append(Vector2(float(o["site"]["x"]), float(o["site"]["s"])))
	for o: Dictionary in deck_objectives(k):
		if str(o["type"]) == "hold":
			out.append(Vector2(float(o["site"]["x"]), float(o["site"]["s"])))
	return out


# --- Checksum --------------------------------------------------------------------------------------------

## Hex digest of the whole mission (includes the section's checksum). Equal on two machines = the same mission.
## `with_depots` false: the digest of the same plan without its depots (what it was before depots existed).
func checksum(with_depots: bool = true) -> String:
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
		for g: Dictionary in p["reserve"]:
			buf.put_utf8_string("%s:%s:%s:%s" % [g["id"], g["theme"], g["source"], g["for"]])
			_put(buf, [g["share"]])
	if with_depots:
		for dp: Dictionary in depots:
			buf.put_utf8_string("depot:" + str(dp["id"]))
			buf.put_32(int(dp["deck"]))
			buf.put_32(int(dp["cores"]))
			_put(buf, [dp["site"]["x"], dp["site"]["s"], dp["snap"]])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


func _put(buf: StreamPeerBuffer, values: Array) -> void:
	for v: Variant in values:
		buf.put_32(int(round(float(v) * 1000.0)))
