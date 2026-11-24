class_name PacingDirector
extends RefCounted
## The host's pacing director (docs/design/pacing-director.md section 1; replaces WaveDirector): decides WHEN each
## reserve group of the MissionPlan's pools is released, from which source and how many units the caps allow. The
## physical side is unchanged from the wave queue: a release is an order {wave, deck, source, open_at, max_units, reason}
## delivered through a gate, lift, ramp or shaft with its door telegraph. Pure and deterministic: no nodes, no network, no
## clock of its own (t comes in), no randomness (the same facts sequence gives the same orders). HOST ONLY runs tick();
## clients only apply_state() what the host broadcast (inside mission.state "dir") and read state() / waves_left().
##
## tick(t, facts) -> orders
##   facts (every key optional; missing = empty / 0 / no information):
##     "alive":        [enemies alive per deck] (garrison + waves, staged units included)
##     "active":       [enemies IN PLAY per deck]: wave units (staged included: they exist) + garrison units that are
##                     alerted or within IN_PLAY_RANGE of a standing mech (MissionFlow / PacingFacts). DECK_CAP and
##                     SECTION_CAP count these; idle garrison far from the crew does not starve reinforcements. Missing:
##                     "alive" is used.
##     "engaging":     [enemies engaging the crew per deck] (fired at a pilot or awake within 60 m with one as target, last 4 s)
##     "wave_alive":   {group id: {"alive", "total" spawned so far}}
##     "wave_pending": {group id: units still to spawn after a partial release} (> 0: a follow-up order from the same source)
##     "wave_size":    {group id: units the spawner will make for it} (what an order holds against the caps until its units
##                     appear; missing: WAVE_MAX)
##     "crew":         [{peer, downed, deck, x, s}] (the array MissionRules gets; deck = the deck the mech stands on or is
##                     entering: a pilot on a ramp belongs to the deck it is walking onto, CityStack.to_deck_arc)
##     "pilots":       {peer: {"tot": total structure % 0..100, "destroyed": components at 0, "disabled": bool,
##                     "shutdown": bool, "engaged": bool}} (host side, from replicated pilot state: spec 1.2)
##     "kills":        [{deck, x, s}] host-owned enemies killed since the last tick
##     "objectives":   MissionRules.state() (reads "objs": {id: [state, progress, total]})
##     "closed":       [source ids]
##   orders = [{"wave", "deck", "source", "open_at", "max_units", "reason": build | cap | objective | scout | patrol}]
##            open_at = t + TELEGRAPH[kind] (>= MIN_LEAD): for a gate the moment its leaves start to move (siren); the
##            units are staged in the bay at the order and roll out once the door is passable (MissionFlow).
## Per deck, a state machine (spec 1.3): rest -> build -> peak -> fade -> rest. A deck starts in rest for ARRIVAL_REST s
## when the crew first stands on it. Quiet cap (1.4): when no pilot on the deck has been engaged for
## QUIET_CAP - ORDER_LEAD[kind] s (quiet is carried by the PILOT: a pilot arriving from another deck or a ramp brings its
## quiet with it, so the arrival rest never stacks on top), the next free group (else a patrol) is ordered from the best
## source and the deck goes to build. Objectives spike (1.5), scout calls (1.6), co-op scaling (1.7).
## Caps: never release a group when the room under a cap is under half the group, never a 1-unit release unless the
## group is 1 unit: hold it (the cap path then tries a patrol). A follow-up load of a partial release is the exception
## (its rest arrives when room appears).
## state() = {"waves": [[released, total] per deck] (reserve groups), "next": {"<deck>": open_at in flight},
##            "left": [waves_left per deck], "pace": {"<deck>": [state, s in state, quiet s, last reason]},
##            "intensity": {"<peer>": I}}   JSON-safe; small ints.

const DECK_CAP := 24            ## enemies in play on one deck (active + in flight), 4 pilots; by crew size:
## (2026-11-24: a 2-bot crew's flag deck reached 28 alive, garrison + groups + dropship troops + wave units walking down,
## and stayed at crew intensity 100 for 200 s): the director releases nothing more while a deck holds this many in play.
const DECK_CAP_BY_CREW := [14, 16, 20, 24]
const SECTION_CAP := 40         ## ... over the whole section
const DECK_ALIVE_MAX := 36      ## hard ceiling: everything alive on one deck (idle garrison included) + in flight
const SECTION_ALIVE_MAX := 60   ## hard ceiling over the section
const WAVE_MAX := 12            ## most units in one group (EnemySpawner.plan_wave caps at it)
const TELEGRAPH := {"gate": 2.0, "lift": 5.0, "ramp": 3.0, "shaft": 3.0}   ## order -> open_at (gate: leaves start, siren)
const REVEAL := {"gate": 3.0, "lift": 1.5, "ramp": 0.0, "shaft": 0.0}      ## open_at -> passable (MissionWorld.passable_after)
## Order -> first contact budget per source kind (s): the cap orders this long before QUIET_CAP so contact lands by it.
## Measured (810 groups, 2026-11-23: order -> first shot p90 ~17-24 s for doors within 200 m by route, ramps 18 s at any
## distance): the cap orders at 20 s of quiet from a source within QUICK_MAX m (25 s lead), at 10 s when the best is
## 200-300 m away (ORDER_LEAD_FAR), at 5 s beyond (ORDER_LEAD_FARTHEST).
const ORDER_LEAD := {"gate": 25.0, "lift": 25.0, "ramp": 25.0, "shaft": 25.0}
const ORDER_LEAD_FAR := 35.0
const ORDER_LEAD_FARTHEST := 40.0
## Quick-response releases (build, cap, scout, patrol) only from sources that make contact in time (measured): ramps at
## any distance, gates QUICK_GATE_MIN..QUICK_MAX m, shafts within QUICK_MAX, lifts within QUICK_LIFT_MAX, by ROUTE length
## from the crew when MissionFlow gives it (facts.source_route), else straight. Objective groups may use any source.
const QUICK_MAX := 200.0
const QUICK_GATE_MIN := 80.0
const QUICK_LIFT_MAX := 120.0
const FAR_ROUTE := 300.0
const HUNT_UNITS := 3           ## garrison units sent hunting when the cap fires and no group can make contact in time
const MIN_LEAD := 1.0           ## every open_at is at least this after t (clients must get the order first)
const QUIET_CAP := 45.0         ## s with nobody on the deck engaged (the user adjusts it once)
const QUIET_LOG := 30.0         ## quiet stretches longer than this are logged
const ARRIVAL_REST := 10.0      ## s of rest when the crew first stands on a deck (the arrival is safe)
const REST_FIRST := 25.0        ## rest on the first deck ...
const REST_LAST := 15.0         ## ... down to this on the last
const PEAK_I := 70.0            ## crew intensity that ends build
const BUILD_MAX := 90.0         ## s of build at most
const PEAK_HOLD := 6.0          ## s of peak (whatever is ordered keeps coming, no new order)
const FADE_I := 35.0            ## fade ends under this crew intensity ...
const FADE_QUIET := 5.0         ## ... with nobody engaged this long
const FADE_MAX := 15.0          ## ... or this long in fade under FADE_I (tuning 2026-11-23: a crew kept engaged by the
								## garrison at low intensity never got 5 s of quiet and the deck stayed in fade: no builds)
const BUILD_GAP := 20.0         ## build releases the next group once the previous is beaten or this old (s after its door)
const BEATEN := 0.25            ## a group is beaten at alive / total <= this
const ENGAGE_TARGET := 6        ## enemies engaging the crew at a peak, solo (x CREW_SCALE); tuning 2026-11-23: 5 -> 6
## The reserve's unit budget = the solo deck budget x CREW_SCALE x RESERVE_SCALE (tuning 2026-11-23, bot runs and the
## user's playtests: groups of 2-3 units and a whole deck's reserve of ~8 units were far too little pressure).
const RESERVE_SCALE := 1.5
const CREW_SCALE := [1.0, 1.0, 1.6, 2.2]   ## index = pilots - 1: reserve size and ENGAGE_TARGET
const PATROLS := 3              ## patrol allowance per deck, solo (+1 per extra pilot)
const PATROL_UNITS := 2         ## units in one patrol
const DEFEND_EVERY := 30.0      ## s between a defend's groups (the asset is the clock): 3-4 pilots ...
## ... by crew size (index = pilots - 1; defend balance 2026-11-24: a lone veteran bot lost the seed-7 defend):
const DEFEND_EVERY_BY_CREW := [45.0, 38.0, 30.0, 30.0]
## Most units in one defend group by crew size (0 = no cap: the group's planned size).
const DEFEND_UNITS_MAX := [4, 5, 0, 0]
## A defend's groups come in lighter themes solo (the first light, the rest mixed); 2+ pilots keep the plan's.
const DEFEND_SOLO_THEMES := ["light", "mixed"]
## While a defend is active on a deck, or the deck's primary is a defend not finished yet, build releases free groups
## only with at least this many pilots (the defend's own clock is the pressure for 1-2; the quiet cap still runs).
const DEFEND_BUILD_MIN_CREW := 3
## s after a defend group's door its last stragglers (<= BEATEN of it alive) stop holding the defend open.
const DEFEND_STRAGGLE := 40.0
const DEFEND_STRAGGLERS := 2.0  ## ... and up to this many of it alive count as stragglers whatever the group's size
const DEFEND_REST := 15.0       ## rest capped at this while a defend is active
const HOLD_EVERY := 20.0        ## s between groups while the extraction hold runs
const SCOUT_EVERY := 45.0       ## one call per scout per this
## Scout-call releases per deck at most (+1 per extra pilot), and none while the crew's deck already has ENGAGE_TARGET
## enemies engaging it (bounded fields, 2026-11-24: scouts now complete beacons often, 0 -> 16 in one probe).
const SCOUT_RELEASES := 2
## Extra patrols the extraction hold may add beyond the deck's allowance (+1 per extra pilot); like every hold clock
## release they wait while the crew is already at ENGAGE_TARGET.
const HOLD_PATROLS := 3
const CALL_EVERY := 30.0        ## one call-release per deck per this
const GRACE := 10.0             ## a released group the spawner never reports counts beaten this long after open_at
const FOLLOW_GAP := 8.0         ## a follow-up order waits this long after the previous load's door opened (bay cleared)
const MIN_SOURCE_DIST := 60.0   ## a source at least this far from every standing mech on the deck (if any is)
const MAX_SOURCE_DIST := 300.0  ## sources within this of the target point are preferred over farther ones
const STATES: Array[String] = ["rest", "build", "peak", "fade"]

var options: Dictionary = {}
var plan: MissionPlan
var crew_n := 1                      ## pilots at mission start (co-op scaling)
var _groups: Array[Dictionary] = []  ## {id, deck, share, theme, for, kind: reserve | patrol, units, orig, source, status
									 ##  (queued | due | released | cancelled), open_at, max_units, reserve, dropped,
									 ##  reason, order_t}
var _t := 0.0
var _wave_alive: Dictionary = {}
var _pending: Dictionary = {}
var _size: Dictionary = {}
var _state: Array[String] = []       ## per deck: rest | build | peak | fade ("" = no crew seen yet)
var _since: Array[float] = []        ## per deck: t the state began
var _rest_len: Array[float] = []     ## per deck: the current rest's length
var _why: Array[String] = []         ## per deck: last state change / release reason
var _quiet: Array[float] = []        ## per deck: quiet seconds at the last tick (-1 no crew)
var _cap_t: Array[float] = []        ## per deck: t of the last cap release
var _call_t: Array[float] = []       ## per deck: t of the last scout call release
var _last: Array[int] = []           ## per deck: index into _groups of the last build release (-1 none)
var _after_rest: Array[bool] = []    ## per deck: the next build release is the first after a rest (lightest left)
var _patrols: Array[int] = []        ## per deck: patrol allowance left
var _patrol_n: Array[int] = []       ## per deck: patrols made (ids)
var _eng_t: Dictionary = {}          ## peer -> t last engaged (first seen when never)
var _int: Dictionary = {}            ## peer -> PilotIntensity
var _dest: Dictionary = {}           ## peer -> components destroyed at the last tick
var _dis: Dictionary = {}            ## peer -> disabled at the last tick
var _calls: Array = []               ## pending scout calls [{deck, x, s, id, t}]
var _scout_t: Dictionary = {}        ## scout id -> t of its last accepted call
var _obj_st: Dictionary = {}         ## objective id -> last state seen
var _flag_half: Dictionary = {}      ## flag id -> its 50 % group was handled
var _obj_t: Dictionary = {}          ## defend / hold id -> t of its last group order
var _events: Array = []              ## log events for MissionFlow (drained by take_events)
var _scout_rel: Array[int] = []      ## per deck: releases caused by scout calls
var _hold_pat: Array[int] = []       ## per deck: extra patrols the hold added
var _engaging: Array[int] = []       ## last facts.engaging (per deck)
var _route: Dictionary = {}          ## last facts.source_route: {source id: route metres from its deck's crew centre}
var _objs: Dictionary = {}           ## last facts.objectives "objs"
var _last_src: Array[String] = []    ## per deck: source of the last quick release (3+ pilots: the next comes from another)
var _sites: Dictionary = {}          ## objective id -> Vector2 (set_site)
var _released: Array[int] = []       ## per deck, what state() sends
var _total: Array[int] = []
var _next: Dictionary = {}
var _left: Array[int] = []           ## client: the host's waves_left per deck
var _mirror := false
var _pace: Dictionary = {}           ## client: the host's "pace"
var _intensity: Dictionary = {}      ## "<peer>" -> int: the host's values (host: refreshed each tick)


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN, "crew_n": Net.SPAWN,
		"plan": Net.LOCAL,           # derived from the seed on every machine
		# the host's decisions: never sent as such
		"_groups": Net.PRIVATE, "_t": Net.PRIVATE, "_wave_alive": Net.PRIVATE, "_pending": Net.PRIVATE,
		"_size": Net.PRIVATE, "_state": Net.PRIVATE, "_since": Net.PRIVATE, "_rest_len": Net.PRIVATE, "_why": Net.PRIVATE,
		"_quiet": Net.PRIVATE, "_cap_t": Net.PRIVATE, "_call_t": Net.PRIVATE, "_last": Net.PRIVATE,
		"_after_rest": Net.PRIVATE, "_patrols": Net.PRIVATE, "_patrol_n": Net.PRIVATE, "_eng_t": Net.PRIVATE,
		"_int": Net.PRIVATE, "_dest": Net.PRIVATE, "_dis": Net.PRIVATE, "_calls": Net.PRIVATE, "_scout_t": Net.PRIVATE,
		"_obj_st": Net.PRIVATE, "_flag_half": Net.PRIVATE, "_obj_t": Net.PRIVATE, "_events": Net.PRIVATE,
		"_route": Net.PRIVATE, "_last_src": Net.PRIVATE, "_objs": Net.PRIVATE, "_scout_rel": Net.PRIVATE,
		"_hold_pat": Net.PRIVATE, "_engaging": Net.PRIVATE,
		# what state() broadcasts: the host writes, clients apply_state()
		"_released": Net.OWNER, "_total": Net.OWNER, "_next": Net.OWNER, "_left": Net.OWNER, "_pace": Net.OWNER,
		"_intensity": Net.OWNER,
		"_mirror": Net.LOCAL,
		"_sites": Net.LOCAL,         # set on every machine from the world's snapped sites
	}


## `crew`: pilots in the crew at mission start (1..4): CREW_SCALE, patrol allowance.
static func make(p: MissionPlan, overrides: Dictionary = {}, crew: int = 1) -> PacingDirector:
	var d := PacingDirector.new()
	d.plan = p
	d.crew_n = clampi(crew, 1, 4)
	d.options = {"deck_cap": DECK_CAP, "section_cap": SECTION_CAP, "deck_alive_max": DECK_ALIVE_MAX,
			"section_alive_max": SECTION_ALIVE_MAX, "wave_max": WAVE_MAX, "telegraph": TELEGRAPH.duplicate(),
			"order_lead": ORDER_LEAD.duplicate(), "quiet_cap": QUIET_CAP, "arrival_rest": ARRIVAL_REST,
			"rest_first": REST_FIRST, "rest_last": REST_LAST, "peak_i": PEAK_I, "build_max": BUILD_MAX,
			"peak_hold": PEAK_HOLD, "fade_i": FADE_I, "fade_quiet": FADE_QUIET, "fade_max": FADE_MAX, "build_gap": BUILD_GAP,
			"beaten": BEATEN, "engage_target": ENGAGE_TARGET, "patrols": PATROLS, "patrol_units": PATROL_UNITS,
			"defend_every": DEFEND_EVERY, "defend_rest": DEFEND_REST, "hold_every": HOLD_EVERY,
			"scout_every": SCOUT_EVERY, "call_every": CALL_EVERY, "grace": GRACE, "follow_gap": FOLLOW_GAP,
			"order_lead_far": ORDER_LEAD_FAR, "order_lead_farthest": ORDER_LEAD_FARTHEST, "hunt_units": HUNT_UNITS,
			"min_source_dist": MIN_SOURCE_DIST, "max_source_dist": MAX_SOURCE_DIST}
	d.options["defend_every"] = float(DEFEND_EVERY_BY_CREW[d.crew_n - 1])
	d.options["deck_cap"] = int(DECK_CAP_BY_CREW[d.crew_n - 1])
	for id: String in overrides:
		if d.options.has(id):
			d.options[id] = overrides[id]
	for key: String in ["telegraph", "order_lead"]:
		var base: Dictionary = (TELEGRAPH if key == "telegraph" else ORDER_LEAD).duplicate()
		if d.options[key] is Dictionary:
			for kind: String in d.options[key]:
				base[kind] = float(d.options[key][kind])
		if key == "telegraph":
			for kind: String in base:
				base[kind] = maxf(float(base[kind]), MIN_LEAD)
		d.options[key] = base
	for k in p.deck_count:
		d._state.append("")
		d._since.append(0.0)
		d._rest_len.append(0.0)
		d._why.append("")
		d._quiet.append(-1.0)
		d._cap_t.append(-INF)
		d._call_t.append(-INF)
		d._last.append(-1)
		d._after_rest.append(true)
		d._patrols.append(d.patrol_allowance())
		d._patrol_n.append(0)
		d._last_src.append("")
		d._scout_rel.append(0)
		d._hold_pat.append(0)
		d._released.append(0)
		d._total.append(0)
	for pl: Dictionary in p.pools:
		for g: Dictionary in pl.get("reserve", []):
			d._groups.append(_record(g, int(pl["deck"]), "reserve"))
	d._summarise()
	return d


static func _record(g: Dictionary, k: int, kind: String) -> Dictionary:
	return {"id": str(g["id"]), "deck": k, "share": float(g.get("share", 0.0)), "theme": str(g.get("theme", "light")),
			"for": str(g.get("for", "")), "kind": kind, "units": int(g.get("units", 0)), "orig": str(g.get("source", "")),
			"source": str(g.get("source", "")), "status": "queued", "open_at": 0.0, "max_units": 0, "reserve": 0,
			"dropped": false, "reason": "", "order_t": -INF}


## Co-op factor (1.7) for this crew.
func crew_scale() -> float:
	return float(CREW_SCALE[clampi(crew_n, 1, 4) - 1])


## Enemies engaging the crew a build aims for.
func engage_target() -> int:
	return maxi(roundi(float(options["engage_target"]) * crew_scale()), 1)


func scout_budget() -> int:
	return SCOUT_RELEASES + clampi(crew_n, 1, 4) - 1


func hold_patrols() -> int:
	return HOLD_PATROLS + clampi(crew_n, 1, 4) - 1


## The most units deck k can ever field from the director for this crew (reserve groups at `sizes`, patrols, hold
## extras), excluding the garrison and dropships (EnemySquad's own cap). Finite by construction.
func deck_ceiling(k: int, sizes: Dictionary) -> int:
	var n := 0
	for g: Dictionary in _groups:
		if int(g["deck"]) == k and g["kind"] == "reserve":
			n += clampi(int(sizes.get(g["id"], options["wave_max"])), 1, int(options["wave_max"]))
	var pu := int(options["patrol_units"])
	n += pu * patrol_allowance()
	for o: Dictionary in plan.deck_objectives(k):
		if str(o["type"]) == "hold":
			n += pu * hold_patrols()
	return n


func patrol_allowance() -> int:
	return int(options["patrols"]) + clampi(crew_n, 1, 4) - 1 if options.has("patrols") else PATROLS + crew_n - 1


## The unit budget a deck's reserve groups are sized from (EnemySpawner.plan_wave's `budget`): the SOLO deck budget times
## CREW_SCALE times RESERVE_SCALE. The garrison keeps EnemySpawner.deck_budget's own crew growth; the reserve uses this instead, so crew
## scaling is applied once.
static func reserve_budget(solo_budget: int, crew: int) -> int:
	return maxi(roundi(float(solo_budget) * float(CREW_SCALE[clampi(crew, 1, 4) - 1]) * RESERVE_SCALE), 1)


func set_site(id: String, x: float, s: float) -> void:
	_sites[id] = Vector2(x, s)


func _site(ob: Dictionary) -> Vector2:
	var id := str(ob.get("id", ""))
	if _sites.has(id):
		return _sites[id]
	return Vector2(float(ob["site"]["x"]), float(ob["site"]["s"]))


func rest_length(k: int) -> float:
	var n := plan.deck_count
	var f := float(k) / float(n - 1) if n > 1 else 0.0
	return lerpf(float(options["rest_first"]), float(options["rest_last"]), f)


## A group's spawner definition {id, share, theme, source, for, units} (MissionFlow's spawn call; patrols included).
func group_def(id: String) -> Dictionary:
	for g: Dictionary in _groups:
		if g["id"] == id:
			var units := int(g["units"])
			var theme := str(g["theme"])
			if _is_defend_group(g):
				var cap := int(DEFEND_UNITS_MAX[crew_n - 1])
				if cap > 0:
					units = mini(int(_size.get(g["id"], cap)), cap) if units <= 0 else mini(units, cap)
				if crew_n == 1:
					theme = str(DEFEND_SOLO_THEMES[mini(_defend_index(g), DEFEND_SOLO_THEMES.size() - 1)])
			return {"id": g["id"], "share": g["share"], "theme": theme, "source": g["source"], "for": g["for"],
					"units": units, "kind": g["kind"]}
	return {}


## Deck k's primary is a defend not finished yet (the crew is heading for it): seed 7's lone bot met an 8-unit build
## group with two tanks just before the defend started and lost (defend balance 2026-11-24).
func _defend_ahead(objs: Dictionary, k: int) -> bool:
	var p := plan.primary(k)
	return str(p.get("type", "")) == "defend" and not (_obj_state(objs, str(p["id"])) in ["done", "failed"])


func _is_defend_group(g: Dictionary) -> bool:
	return g["kind"] == "reserve" and g["for"] != "" and _type_of(g["for"]) == "defend"


## The group's place among its defend's groups (0 = the first).
func _defend_index(g: Dictionary) -> int:
	var i := 0
	for o: Dictionary in _groups:
		if o == g:
			return i
		if o["for"] == g["for"]:
			i += 1
	return i


## Host: a scout drone completed its beacon on `deck` at arc (x, s) (spec 1.6). Queued; tick() applies the limits.
func scout_call(deck: int, x: float, s: float, scout_id: String, t: float) -> void:
	_calls.append({"deck": deck, "x": x, "s": s, "id": scout_id, "t": t})


## Log events since the last call: [{tag: release | pace | quiet | scout, ...}] (MissionFlow prints / CombatLog).
func take_events() -> Array:
	var out := _events
	_events = []
	return out


# --- Host ------------------------------------------------------------------------------------------------

func tick(t: float, facts: Dictionary) -> Array:
	var dt := clampf(t - _t, 0.0, 1.0) if _t > 0.0 else 0.0
	_t = t
	var n := plan.deck_count
	var alive := _per_deck(facts.get("alive", []))
	var active := _per_deck(facts.get("active", facts.get("alive", [])))
	var engaging := _per_deck(facts.get("engaging", []))
	_engaging = engaging
	_wave_alive = facts.get("wave_alive", {}) if facts.get("wave_alive", {}) is Dictionary else {}
	_pending = facts.get("wave_pending", {}) if facts.get("wave_pending", {}) is Dictionary else {}
	_size = facts.get("wave_size", {}) if facts.get("wave_size", {}) is Dictionary else {}
	_route = facts.get("source_route", {}) if facts.get("source_route", {}) is Dictionary else {}
	var closed := {}
	for id: Variant in facts.get("closed", []):
		closed[str(id)] = true
	var objs: Dictionary = {}
	var ob: Variant = facts.get("objectives", {})
	if ob is Dictionary and (ob as Dictionary).get("objs", null) is Dictionary:
		objs = ob["objs"]
	_objs = objs
	# Pilots: positions (standing ones), intensity, engagement.
	var pts := {}        # deck -> [Vector2] standing pilots
	var peers := {}      # deck -> [peer] standing pilots
	var pilots: Dictionary = facts.get("pilots", {}) if facts.get("pilots", {}) is Dictionary else {}
	var kills: Array = facts.get("kills", []) if facts.get("kills", []) is Array else []
	var crew_arr: Array = facts.get("crew", []) if facts.get("crew", []) is Array else []
	for c: Variant in crew_arr:
		if not (c is Dictionary):
			continue
		var peer := str(c.get("peer", 0))
		var ck := int(c.get("deck", -1))
		var at := Vector2(float(c.get("x", 0.0)), float(c.get("s", 0.0)))
		if not _eng_t.has(peer):
			_eng_t[peer] = t
		var pi: PilotIntensity = _int.get(peer)
		if pi == null:
			pi = PilotIntensity.new()
			_int[peer] = pi
		var pf: Dictionary = pilots.get(peer, pilots.get(int(c.get("peer", 0)), {})) if not pilots.is_empty() else {}
		var engaged := bool(pf.get("engaged", false))
		if pf.has("tot"):
			pi.structure(float(pf["tot"]))
		var dest := int(pf.get("destroyed", 0))
		if dest > int(_dest.get(peer, 0)):
			pi.component_destroyed(dest - int(_dest.get(peer, 0)))
		_dest[peer] = dest
		var dis := bool(pf.get("disabled", bool(c.get("downed", false))))
		if dis and not bool(_dis.get(peer, false)):
			pi.disabled()
		_dis[peer] = dis
		for kv: Variant in kills:
			if kv is Dictionary and int(kv.get("deck", -1)) == ck:
				pi.kill_near(at.distance_to(Vector2(float(kv.get("x", 0.0)), float(kv.get("s", 0.0)))))
		pi.step(dt, engaged, bool(pf.get("shutdown", false)))
		if engaged:
			_eng_t[peer] = t
		if bool(c.get("downed", false)) or ck < 0 or ck >= n:
			continue
		if not pts.has(ck):
			pts[ck] = []
			peers[ck] = []
		pts[ck].append(at)
		peers[ck].append(peer)
	_intensity.clear()
	for peer: String in _int:
		_intensity[peer] = roundi((_int[peer] as PilotIntensity).value)
	# Released groups: re-route / drop on closed sources; cancel objective groups whose objective ended unreleased.
	for g: Dictionary in _groups:
		var st: String = g["status"]
		if st == "cancelled":
			continue
		if (st == "queued" or st == "due") and g["for"] != "" and not _is_flag_group(g) \
				and _obj_state(objs, g["for"]) in ["done", "failed"] and _type_of(g["for"]) != "hold":
			g["status"] = "cancelled"
			continue
		if st == "released" and _pending_of(g) > 0 and closed.has(g["source"]) and not g["dropped"]:
			g["dropped"] = true
	# Room.
	var inflight: Array[int] = []
	inflight.resize(n)
	inflight.fill(0)
	for g: Dictionary in _groups:
		if g["status"] == "released" and t < float(g["open_at"]) and not _reported(g):
			inflight[int(g["deck"])] += int(g["reserve"])
	var room := {"alive": alive, "active": active, "inflight": inflight}
	var orders: Array = []
	# Follow-up loads of partial releases (no half rule: the rest of an order already made).
	for g: Dictionary in _groups:
		if g["status"] != "released" or g["dropped"] or _pending_of(g) <= 0:
			continue
		if t < float(g["open_at"]) + float(options["follow_gap"]):
			continue
		var k := int(g["deck"])
		var r := _room(k, room)
		if r <= 0:
			continue
		var mu := mini(r, _pending_of(g))
		orders.append(_order(g, t, mu, str(g["reason"]), true))
		inflight[k] += mu
	# Objectives.
	for o: Dictionary in plan.objectives:
		_objective_step(o, objs, t, room, closed, pts, orders)
	# Scout calls.
	var keep: Array = []
	for c: Dictionary in _calls:
		var k := int(c["deck"])
		var sid := str(c["id"])
		if k < 0 or k >= n or t - float(_scout_t.get(sid, -INF)) < float(options["scout_every"]) \
				or t - _call_t[k] < float(options["call_every"]):
			_events.append({"tag": "scout", "ev": "ignored", "drone": sid, "deck": k})
			continue
		if engaging[k] >= engage_target() or _scout_rel[k] >= scout_budget():
			_events.append({"tag": "scout", "ev": "ceiling" if engaging[k] >= engage_target() else "budget", "drone": sid,
					"deck": k})
			continue
		var g := _next_free(k, false)
		var why := "scout"
		if g.is_empty():
			g = _new_patrol(k)
			why = "patrol"
		if g.is_empty():
			_events.append({"tag": "scout", "ev": "empty", "drone": sid, "deck": k})
			continue
		var target := Vector2(float(c["x"]), float(c["s"]))
		var o := _try_release(g, t, room, closed, pts.get(k, []), target, why)
		if o.is_empty():
			if g["kind"] == "patrol":
				_unmake_patrol(g)
			keep.append(c)   # no room: try again next tick (the limits are only spent on a real release)
			continue
		_scout_t[sid] = t
		_call_t[k] = t
		_scout_rel[k] += 1
		orders.append(o)
		_set_state(k, "build", t, "scout")
	_calls = keep
	# Per deck: state machine, quiet cap, build releases.
	for k in n:
		if not pts.has(k):
			_quiet[k] = -1.0
			continue
		if _state[k] == "":
			_set_state(k, "rest", t, "arrival")
			_rest_len[k] = float(options["arrival_rest"])
		var last_eng := -INF
		for peer: String in peers[k]:
			last_eng = maxf(last_eng, float(_eng_t.get(peer, t)))
		var q := t - last_eng
		if _quiet[k] > QUIET_LOG and q < _quiet[k]:
			_events.append({"tag": "quiet", "deck": k, "dur": snappedf(_quiet[k], 0.1)})
		_quiet[k] = q
		var ci := 0.0
		for peer: String in peers[k]:
			ci = maxf(ci, (_int[peer] as PilotIntensity).value)
		var hold := _active_type(objs, k, "hold")
		var flag := _active_type(objs, k, "flag")
		var defend := _active_type(objs, k, "defend")
		var in_state := t - _since[k]
		match _state[k]:
			"rest":
				var rl := _rest_len[k]
				if defend:
					rl = minf(rl, float(options["defend_rest"]))
				if hold or flag or in_state >= rl:
					_set_state(k, "build", t, "rested" if in_state >= rl else ("hold" if hold else "flag"))
			"build":
				if ci >= float(options["peak_i"]) or in_state >= float(options["build_max"]):
					_set_state(k, "peak", t, "intensity" if ci >= float(options["peak_i"]) else "build_max")
			"peak":
				if in_state >= float(options["peak_hold"]):
					_set_state(k, "build" if hold else "fade", t, "peaked")
			"fade":
				if hold:
					_set_state(k, "build", t, "hold")
				elif ci < float(options["fade_i"]) and (q >= float(options["fade_quiet"]) or in_state >= float(options["fade_max"])):
					if flag:
						_set_state(k, "build", t, "flag")
					else:
						_set_state(k, "rest", t, "faded")
						_rest_len[k] = minf(rest_length(k), float(options["defend_rest"])) if defend else rest_length(k)
		# Quiet cap: order early enough (the lead of the source it would use) that contact lands by QUIET_CAP.
		var centre := _crew_centre(pts[k])
		var src := _pick_source_at(k, centre, closed, pts[k], true, "", true)
		var lead := lead_for(src, centre)
		# Once per quiet stretch (no cap release since the last engagement), again only if a whole cap passed without contact.
		if q >= float(options["quiet_cap"]) - lead \
				and (_cap_t[k] < last_eng or t - _cap_t[k] >= float(options["quiet_cap"])):
			var g := _next_free(k, false)
			var why := "cap"
			if not g.is_empty() and not _fits(g, k, room):
				g = {}
			if g.is_empty():
				g = _new_patrol(k)
				why = "patrol"
			if not g.is_empty():
				var o := _try_release(g, t, room, closed, pts[k], Vector2.INF, why)
				if o.is_empty():
					if g["kind"] == "patrol":
						_unmake_patrol(g)
				else:
					orders.append(o)
					_cap_t[k] = t
					_set_state(k, "build", t, why)
					continue
			# No group can make contact in time (none left, no room, no source): the nearest garrison hunts instead
			# (MissionFlow: EnemySquad hunt call); it counts as the cap's release.
			_events.append({"tag": "hunt", "deck": k, "units": int(options["hunt_units"]), "x": centre.x, "s": centre.y})
			_cap_t[k] = t
			_set_state(k, "build", t, "hunt")
			continue
		# Build: the next free group while the crew is under-engaged and the previous group is beaten or old.
		if _state[k] != "build":
			continue
		if crew_n < DEFEND_BUILD_MIN_CREW and (defend or _defend_ahead(objs, k)):
			continue   # a small crew's defend deck: the defend's own clock is the pressure
		if engaging[k] >= engage_target():
			continue
		if _last[k] >= 0:
			var pg: Dictionary = _groups[_last[k]]
			if not _is_beaten(pg) and t < float(pg["open_at"]) + float(options["build_gap"]) / crew_scale():
				continue
		var nxt := _next_free(k, _after_rest[k])
		if nxt.is_empty():
			continue
		var bo := _try_release(nxt, t, room, closed, pts[k], Vector2.INF, "build")
		if not bo.is_empty():
			orders.append(bo)
	_summarise()
	return orders


## One objective's spike rules (spec 1.5).
func _objective_step(o: Dictionary, objs: Dictionary, t: float, room: Dictionary, closed: Dictionary, pts: Dictionary,
		orders: Array) -> void:
	var id: String = o["id"]
	var k := int(o["deck"])
	var ty := str(o["type"])
	var st := _obj_state(objs, id)
	var prev := str(_obj_st.get(id, ""))
	_obj_st[id] = st
	var mine: Array = pts.get(k, [])
	if st == "active" and prev != "active":
		if ty in ["flag", "defend", "hold"]:
			_set_state(k, "build", t, "objective")
		var got := false
		for g: Dictionary in _groups:
			if g["for"] == id and g["status"] == "queued":
				g["status"] = "due"
				got = true
				break   # one at a time (a defend / the hold: the rest on the objective's clock)
		if not got and ty == "flag" and _obj_has_group(id):
			# Its group was lent out (_next_free): the next free group, else a patrol, comes for the flag instead.
			var gf := _next_free(k, false)
			if gf.is_empty():
				gf = _new_patrol(k, true)
			if not gf.is_empty():
				gf["status"] = "due"
				gf["flag_for"] = id
		if ty == "hold":
			# Two sources at once: the hold's group and the next free group (else a patrol) from another source.
			var g2 := _next_free(k, false)
			if g2.is_empty():
				g2 = _new_patrol(k)
			if g2.is_empty() and _hold_pat[k] < hold_patrols():
				g2 = _new_patrol(k, true)
				if not g2.is_empty():
					_hold_pat[k] += 1
			if not g2.is_empty():
				g2["status"] = "due"
				g2["second"] = true
		_obj_t[id] = t
	if st != "active" and prev == "active" and st in ["done", "failed"]:
		if ty == "flag":
			_set_state(k, "fade", t, "flag_done")
		elif ty == "defend":
			_set_state(k, "rest", t, "defend_done")
			_rest_len[k] = rest_length(k)
	if st == "active":
		match ty:
			"flag":
				var e: Variant = objs.get(id)
				if not bool(_flag_half.get(id, false)) and e is Array and (e as Array).size() > 2 and float(e[2]) > 0.0 \
						and float(e[1]) >= 0.5 * float(e[2]):
					_flag_half[id] = true
					var g := _next_free(k, false)
					if not g.is_empty():
						g["status"] = "due"
						g["flag_for"] = id
			"defend":
				if t - float(_obj_t.get(id, t)) >= float(options["defend_every"]):
					for g: Dictionary in _groups:
						if g["for"] == id and g["status"] == "queued":
							g["status"] = "due"
							_obj_t[id] = t
							break
			"hold":
				if t - float(_obj_t.get(id, t)) >= float(options["hold_every"]) \
						and (k >= _engaging.size() or _engaging[k] < engage_target()):
					var g := _next_free(k, false)
					if g.is_empty():
						g = _new_patrol(k)
					if g.is_empty() and _hold_pat[k] < hold_patrols():
						g = _new_patrol(k, true)
						if not g.is_empty():
							_hold_pat[k] += 1
					if not g.is_empty():
						g["status"] = "due"
					_obj_t[id] = t
	# Order every due group of this objective (flag groups: also once the flag finished: once due, delivered).
	var first_src := ""
	for g: Dictionary in _groups:
		if g["status"] != "due" or int(g["deck"]) != k:
			continue
		var mine_obj: bool = g["for"] == id or str(g.get("flag_for", "")) == id or (ty == "hold" and st == "active"
				and g["for"] == "")
		if not mine_obj:
			continue
		var skip := {}
		if (bool(g.get("second", false)) or ty == "hold") and first_src != "":
			skip = closed.duplicate()
			skip[first_src] = true
		var target := _site(o)
		var why := "objective"
		var oo := _try_release(g, t, room, skip if not skip.is_empty() else closed, mine, target, why,
				ty == "flag" or str(g.get("flag_for", "")) != "")
		if not oo.is_empty():
			orders.append(oo)
			first_src = str(oo["source"])


## Release `g` now if the caps allow (half rule); {} when held. `target`: Vector2.INF = the crew's centre on the deck.
func _try_release(g: Dictionary, t: float, room: Dictionary, closed: Dictionary, mine: Array, target: Vector2,
		why: String, flag_rule: bool = false) -> Dictionary:
	var k := int(g["deck"])
	if not _fits(g, k, room):
		return {}
	var r := _room(k, room)
	var src := ""
	if flag_rule:
		var fo := plan.objective(str(g.get("flag_for", g["for"])))
		if not fo.is_empty():
			src = _pick_flag_source(k, _site(fo), closed, mine)
	if src == "":
		var at := target
		var from_crew := at == Vector2.INF
		if from_crew:
			at = _crew_centre(mine) if not mine.is_empty() else _source_pos(g["orig"])
		var quick := why != "objective"
		var avoid := _last_src[k] if quick and crew_n >= 3 else ""
		src = _pick_source_at(k, at, closed, mine, quick, avoid, from_crew and not mine.is_empty())
	if src == "":
		return {}
	g["source"] = src
	g["status"] = "released"
	g["reason"] = why
	g["order_t"] = t
	var size := _size_of(g)
	var o := _order(g, t, mini(r, size), why)
	(room["inflight"] as Array)[k] += int(g["reserve"])
	if g["kind"] == "reserve" and why != "objective":
		_last[k] = _groups.find(g)
		_after_rest[k] = false
	if why != "objective":
		_last_src[k] = src
	_events.append({"tag": "release", "wave": g["id"], "deck": k, "source": src, "size": size, "reason": why})
	return o


## The half rule: room under every cap >= half the group (rounded up) and >= 2 unless the group is 1 unit.
func _fits(g: Dictionary, k: int, room: Dictionary) -> bool:
	var size := _size_of(g)
	var need := maxi(ceili(float(size) * 0.5), mini(size, 2))
	return _room(k, room) >= need


func _size_of(g: Dictionary) -> int:
	if g["kind"] == "patrol":
		return maxi(int(g["units"]), 1)
	var n := clampi(int(_size.get(g["id"], options["wave_max"])), 1, int(options["wave_max"]))
	if _is_defend_group(g) and int(DEFEND_UNITS_MAX[crew_n - 1]) > 0:
		n = mini(n, int(DEFEND_UNITS_MAX[crew_n - 1]))
	return n


func _room(k: int, room: Dictionary) -> int:
	var alive: Array[int] = room["alive"]
	var active: Array[int] = room["active"]
	var inflight: Array = room["inflight"]
	var sum_alive := 0
	var sum_active := 0
	var sum_in := 0
	for i in plan.deck_count:
		sum_alive += alive[i]
		sum_active += active[i]
		sum_in += int(inflight[i])
	return mini(mini(int(options["deck_cap"]) - active[k] - int(inflight[k]),
			int(options["section_cap"]) - sum_active - sum_in),
			mini(int(options["deck_alive_max"]) - alive[k] - int(inflight[k]),
			int(options["section_alive_max"]) - sum_alive - sum_in))


func _order(g: Dictionary, t: float, max_units: int, why: String, follow: bool = false) -> Dictionary:
	var kind := str(plan.source(g["source"]).get("kind", "gate"))
	var tg: Dictionary = options["telegraph"]
	var open_at := t + maxf(float(tg.get(kind, MIN_LEAD)), MIN_LEAD)
	g["open_at"] = open_at
	g["max_units"] = max_units
	g["reserve"] = max_units if follow else mini(max_units, _size_of(g))
	return {"wave": g["id"], "deck": int(g["deck"]), "source": g["source"], "open_at": open_at, "max_units": max_units,
			"reason": why}


## The next free (non-objective) reserve group of deck k still queued; `lightest`: the one with the smallest share.
## Once the free groups are gone, the queued group of a BONUS flag that has not started is borrowed (tuning 2026-11-23:
## most pools held one free group, the rest tied to bonus flags the crew never finds, so a deck ran dry at once); the
## bonus, if started later, gets the next free group or a patrol instead.
func _next_free(k: int, lightest: bool) -> Dictionary:
	var best := {}
	for g: Dictionary in _groups:
		if int(g["deck"]) != k or g["kind"] != "reserve" or g["for"] != "" or g["status"] != "queued":
			continue
		if not lightest:
			return g
		if best.is_empty() or float(g["share"]) < float(best["share"]):
			best = g
	if not best.is_empty():
		return best
	for g: Dictionary in _groups:
		if int(g["deck"]) == k and g["kind"] == "reserve" and g["status"] == "queued" and _borrowable(g):
			return g
	return {}


func _obj_has_group(id: String) -> bool:
	for g: Dictionary in _groups:
		if g["for"] == id:
			return true
	return false


## A queued group of a bonus flag whose capture has not started (_next_free may lend it out).
func _borrowable(g: Dictionary) -> bool:
	if g["for"] == "":
		return false
	var o := plan.objective(str(g["for"]))
	return str(o.get("type", "")) == "flag" and str(o.get("role", "")) == "bonus" 			and not (_obj_state(_objs, str(g["for"])) in ["active", "done", "failed"])


## A patrol for deck k from its allowance ({} when spent; `free`: the extraction hold, not counted).
func _new_patrol(k: int, free: bool = false) -> Dictionary:
	if not free and _patrols[k] <= 0:
		return {}
	if not free:
		_patrols[k] -= 1
	_patrol_n[k] += 1
	var g := _record({"id": "d%d_pat%d" % [k, _patrol_n[k]], "share": 0.0, "theme": "light",
			"units": int(options["patrol_units"]), "source": _first_source(k)}, k, "patrol")
	g["free"] = free
	_groups.append(g)
	return g


## A patrol made but not released (no room): give its allowance back.
func _unmake_patrol(g: Dictionary) -> void:
	var k := int(g["deck"])
	_groups.erase(g)
	_patrol_n[k] -= 1
	if not bool(g.get("free", false)):
		_patrols[k] += 1


func _first_source(k: int) -> String:
	var s := plan.deck_sources(k)
	return str(s[0]["id"]) if not s.is_empty() else ""


func _set_state(k: int, s: String, t: float, why: String) -> void:
	if _state[k] == s and why != "cap" and why != "scout" and why != "objective":
		return
	var old := _state[k]
	_state[k] = s
	_since[k] = t
	_why[k] = why
	if s == "rest":
		_after_rest[k] = true
		_rest_len[k] = rest_length(k)
	if old != s:
		var ci := 0.0
		for peer: String in _int:
			ci = maxf(ci, (_int[peer] as PilotIntensity).value)
		_events.append({"tag": "pace", "deck": k, "from": old, "to": s, "i": roundi(ci), "reason": why})


func _active_type(objs: Dictionary, k: int, ty: String) -> bool:
	for o: Dictionary in plan.deck_objectives(k):
		if str(o["type"]) == ty and _obj_state(objs, o["id"]) == "active":
			return true
	return false


func _type_of(id: String) -> String:
	return str(plan.objective(id).get("type", ""))


func _is_flag_group(g: Dictionary) -> bool:
	return g["for"] != "" and _type_of(g["for"]) == "flag"


func _crew_centre(mine: Array) -> Vector2:
	if mine.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for p: Vector2 in mine:
		c += p
	return c / float(mine.size())


func _source_pos(id: String) -> Vector2:
	var o := plan.source(id)
	return Vector2(float(o.get("x", 0.0)), float(o.get("s", 0.0)))


## Distance from the crew (route length when `route` and MissionFlow gave one, else straight) to source `id`.
func _dist(id: String, target: Vector2, route: bool) -> float:
	if route and _route.has(id) and float(_route[id]) >= 0.0:
		return float(_route[id])
	return _source_pos(id).distance_to(target)


## A quick-response source (see QUICK_MAX): contact in time by the measured latencies.
func is_quick(id: String, d: float) -> bool:
	match str(plan.source(id).get("kind", "")):
		"ramp":
			return true
		"gate":
			return d >= QUICK_GATE_MIN and d <= QUICK_MAX
		"shaft":
			return d <= QUICK_MAX
		"lift":
			return d <= QUICK_LIFT_MAX
	return false


## How long before QUIET_CAP the cap orders from `src` (ORDER_LEAD by kind within QUICK_MAX by route, else the far leads).
func lead_for(src: String, centre: Vector2) -> float:
	if src == "":
		return float((options["order_lead"] as Dictionary).get("gate", 25.0))
	var d := _dist(src, centre, true)
	if d <= QUICK_MAX or str(plan.source(src).get("kind", "")) == "ramp":
		return float((options["order_lead"] as Dictionary).get(str(plan.source(src).get("kind", "gate")), 25.0))
	return float(options["order_lead_far"]) if d <= FAR_ROUTE else float(options["order_lead_farthest"])


## The deck's open source for a release toward `target` ("" when the deck has none open). Every source is >= MIN_SOURCE_DIST
## from every standing mech where possible. `quick` (build, cap, scout, patrol): quick-response sources first (is_quick),
## nearest by route; `avoid` (3+ pilots: the previous quick source) only when no other quick one is open. Otherwise (and
## when nothing quick is open) the nearest within MAX_SOURCE_DIST, then farther.
func _pick_source_at(k: int, target: Vector2, closed: Dictionary, mine: Array, quick: bool = false, avoid: String = "",
		route: bool = false) -> String:
	var best := ""
	var best_rank := 99
	var best_d := INF
	for s: Dictionary in plan.deck_sources(k):
		if closed.has(s["id"]):
			continue
		var id := str(s["id"])
		var at := Vector2(float(s["x"]), float(s["s"]))
		var d := _dist(id, target, route)
		var rank := 2 if at.distance_to(target) > float(options["max_source_dist"]) else 0
		for p: Vector2 in mine:
			if at.distance_to(p) < float(options["min_source_dist"]):
				rank += 1
				break
		if quick:
			if not is_quick(id, d):
				rank += 10
			elif id == avoid:
				rank += 5
		if rank < best_rank or (rank == best_rank and d < best_d):
			best_rank = rank
			best_d = d
			best = id
	return best


## A flag's groups measure from the (snapped) flag site: MissionPlan.flag_source_rank (80-200 m preferred).
func _pick_flag_source(k: int, at: Vector2, closed: Dictionary, mine: Array) -> String:
	var best := ""
	var best_key := Vector3(INF, INF, INF)
	for s: Dictionary in plan.deck_sources(k):
		if closed.has(s["id"]):
			continue
		var p := Vector2(float(s["x"]), float(s["s"]))
		var near_crew := 0.0
		for m: Vector2 in mine:
			if p.distance_to(m) < float(options["min_source_dist"]):
				near_crew = 1.0
				break
		var r := MissionPlan.flag_source_rank(p.distance_to(at))
		var key := Vector3(near_crew, r.x, r.y)
		if key < best_key:
			best_key = key
			best = s["id"]
	return best


func _per_deck(a: Variant) -> Array[int]:
	var out: Array[int] = []
	for k in plan.deck_count:
		out.append(maxi(int(a[k]), 0) if a is Array and k < (a as Array).size() and a[k] != null else 0)
	return out


func _pending_of(g: Dictionary) -> int:
	if g["dropped"]:
		return 0
	return maxi(int(_pending.get(g["id"], 0)), 0)


func _reported(g: Dictionary) -> bool:
	var wa: Variant = _wave_alive.get(g["id"], null)
	return wa is Dictionary and int(wa.get("total", 0)) > 0


## Released and done arriving: door open, nothing pending, at most BEATEN of it alive (or never reported for GRACE s).
func _is_beaten(g: Dictionary) -> bool:
	if _t < float(g["open_at"]) or _pending_of(g) > 0:
		return false
	var wa: Variant = _wave_alive.get(g["id"], null)
	if wa is Dictionary and int(wa.get("total", 0)) > 0:
		return float(int(wa.get("alive", 0))) <= float(options["beaten"]) * float(int(wa["total"]))
	return _t >= float(g["open_at"]) + float(options["grace"])


static func _obj_state(objs: Dictionary, id: String) -> String:
	var e: Variant = objs.get(id, null)
	if e is Array and (e as Array).size() > 0:
		return str(e[0])
	return ""


func _summarise() -> void:
	_next.clear()
	for k in plan.deck_count:
		_released[k] = 0
		_total[k] = 0
	for g: Dictionary in _groups:
		var k := int(g["deck"])
		if g["status"] == "released" and _t < float(g["open_at"]):
			var key := str(k)
			_next[key] = maxf(float(_next.get(key, 0.0)), snappedf(float(g["open_at"]), 0.01))
		if g["kind"] != "reserve" or g["status"] == "cancelled":
			continue
		_total[k] += 1
		if g["status"] == "released":
			_released[k] += 1
	if not _mirror:
		_pace.clear()
		for k in plan.deck_count:
			if _state[k] == "":
				continue
			_pace[str(k)] = [_state[k], roundi(_t - _since[k]), roundi(maxf(_quiet[k], 0.0)), _why[k]]


# --- Reads -----------------------------------------------------------------------------------------------

## Groups still owed to deck k: free reserve groups not released yet, due objective groups, released groups with units
## pending or not reported yet (until open_at + GRACE). Not owed: groups of an objective that has not started (a bonus never
## found), patrols (the allowance never holds a sweep open), cancelled groups. On a client: the host's count.
func waves_left(k: int) -> int:
	if k < 0 or k >= plan.deck_count:
		return 0
	if _mirror:
		if _left.size() == plan.deck_count:
			return _left[k]
		return maxi(_total[k] - _released[k], 0)
	var n := 0
	for g: Dictionary in _groups:
		if int(g["deck"]) != k:
			continue
		match str(g["status"]):
			"due":
				n += 1
			"queued":
				if g["kind"] == "reserve" and (g["for"] == "" or _borrowable(g)):
					n += 1
			"released":
				if g["kind"] == "reserve" and (_pending_of(g) > 0 or (not _reported(g)
						and _t < float(g["open_at"]) + float(options["grace"]))):
					n += 1
	return n


func waves_left_all() -> Array:
	var out := []
	for k in plan.deck_count:
		out.append(waves_left(k))
	return out


## For MissionRules' defend_waves fact: {objective id: {released, total, alive}} for every objective with groups.
func objective_waves() -> Dictionary:
	var out := {}
	for g: Dictionary in _groups:
		var id: String = g["for"]
		if id == "":
			continue
		if not out.has(id):
			out[id] = {"released": 0, "total": 0, "alive": 0}
		var e: Dictionary = out[id]
		if g["status"] == "cancelled":
			continue
		e["total"] += 1
		if g["status"] != "released":
			continue
		e["released"] += 1
		var wa: Variant = _wave_alive.get(g["id"], null)
		if _reported(g):
			var al := maxi(int(wa.get("alive", 0)), 0)
			# A defend group mostly beaten (<= BEATEN of it, or <= DEFEND_STRAGGLERS units, alive) DEFEND_STRAGGLE s after its door no longer holds the defend
			# open: its last stragglers (a drone circling, a trooper in cover) fight on, the relay is safe.
			if _type_of(id) == "defend" and _pending_of(g) == 0 and _t >= float(g["open_at"]) + DEFEND_STRAGGLE 					and float(al) <= maxf(float(options["beaten"]) * float(maxi(int(wa.get("total", 0)), 1)), DEFEND_STRAGGLERS):
				al = 0
			e["alive"] += al
		elif _t < float(g["open_at"]) + float(options["grace"]):
			e["alive"] += maxi(int(g["reserve"]), 1)
		e["alive"] += _pending_of(g)
	return out


## queued | due | released | cancelled ("" unknown). Host only.
func status(id: String) -> String:
	for g: Dictionary in _groups:
		if g["id"] == id:
			return g["status"]
	return ""


func source_of(id: String) -> String:
	for g: Dictionary in _groups:
		if g["id"] == id:
			return g["source"]
	return ""


## Deck k's director state (host: its own; client: the replicated one); "" before the crew stood on it.
func pace_state(k: int) -> String:
	var row: Variant = _pace.get(str(k))
	return str((row as Array)[0]) if row is Array and not (row as Array).is_empty() else ""


## Quiet seconds of deck k (-1 without crew) as of the last tick (host) / state (client).
func quiet(k: int) -> float:
	if not _mirror:
		return _quiet[k] if k >= 0 and k < _quiet.size() else -1.0
	var row: Variant = _pace.get(str(k))
	return float((row as Array)[2]) if row is Array and (row as Array).size() > 2 else -1.0


func intensity(peer: Variant) -> float:
	return float(_intensity.get(str(peer), 0))


func patrols_left(k: int) -> int:
	return _patrols[k] if k >= 0 and k < _patrols.size() else 0


func state() -> Dictionary:
	var waves := []
	for k in plan.deck_count:
		waves.append([_released[k], _total[k]])
	return {"waves": waves, "next": _next.duplicate(), "left": waves_left_all(), "pace": _pace.duplicate(true),
			"intensity": _intensity.duplicate()}


## Clients: mirror the host's state() (ints may arrive as floats).
func apply_state(d: Dictionary) -> void:
	_mirror = true
	if d.get("waves", null) is Array:
		var src: Array = d["waves"]
		for k in plan.deck_count:
			var e: Variant = src[k] if k < src.size() else null
			_released[k] = int(e[0]) if e is Array and (e as Array).size() > 1 else 0
			_total[k] = int(e[1]) if e is Array and (e as Array).size() > 1 else 0
	if d.get("next", null) is Dictionary:
		_next.clear()
		for key: Variant in d["next"]:
			_next[str(key)] = float(d["next"][key])
	_left.clear()
	if d.get("left", null) is Array and (d["left"] as Array).size() == plan.deck_count:
		for v: Variant in d["left"]:
			_left.append(maxi(int(v), 0) if v != null else 0)
	if d.get("pace", null) is Dictionary:
		_pace = (d["pace"] as Dictionary).duplicate(true)
	if d.get("intensity", null) is Dictionary:
		_intensity.clear()
		for key: Variant in d["intensity"]:
			_intensity[str(key)] = int(d["intensity"][key])
