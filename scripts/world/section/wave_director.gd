class_name WaveDirector
extends RefCounted
## The host's reinforcement queue: decides when each wave of the MissionPlan's pools is released, from which source,
## and how many units the alive caps allow (docs/design/mission-objectives.md §5.2-§5.5, §9). Pure and deterministic:
## no nodes, no network, no clock of its own (t comes in), no randomness. HOST ONLY runs tick(); clients only
## apply_state() what the host broadcast (with the mission state) and read state() / waves_left().
##
## tick(t, facts) -> orders
##   facts = {"alive": [enemies alive per deck],
##            "wave_alive": {wave id: {"alive": int, "total": int spawned so far}},
##            "wave_pending": {wave id: units of that wave still to spawn}   (the spawner's report after a partial
##                            release; > 0 makes the director order the rest from the same source when room appears),
##            "wave_size": {wave id: units the spawner expects to make for it}   (what an order whose door has not
##                            opened holds against the caps; missing: WAVE_MAX; never more than its max_units),
##            "garrison_alive": [garrison units alive per deck]   (the first value seen per deck is its total),
##            "crew_deck": [decks with a standing mech],
##            "crew": [{peer, downed, deck, x, s}]   (the same array MissionRules gets; only for the source choice),
##            "objectives": MissionRules.state() (reads only "objs": {id: [state, progress, total]}),
##            "closed": [source ids]}
##   every key optional (missing = empty / 0 / no information; without "crew" every wave uses its planned source).
##   orders = [{"wave", "deck", "source", "open_at", "max_units"}]: release that wave from that source; the door opens
##            at open_at on the shared clock (t + the source kind's telegraph, never less than t + MIN_LEAD).
##            max_units = min(DECK_CAP - alive[deck], SECTION_CAP - sum(alive)), minus units already ordered whose door
##            has not opened yet (they are not in `alive` until they spawn): each such order holds its wave's expected
##            size (wave_size, else WAVE_MAX) capped by its max_units, a follow-up its own load. A follow-up order for the same wave
##            carries the rest of a partial release.
## Rules:
##   due      objective trigger (step start: the objective is active / done / failed; step done: done), garrison_low
##            (garrison_alive <= GARRISON_LOW x its first value), linger (`after` s since a standing mech was first seen
##            on the deck while its primary is not done), and §5.4 rule 5 (garrison all dead and nothing alive or
##            arriving from waves on the deck: the next unreleased garrison_low wave, else the linger wave; without a
##            garrison_alive entry, alive[k] == 0 means the garrison is gone). Free (non-objective) waves only on a
##            deck a standing mech has been seen on.
##   release  priority waves first: the due waves of an ACTIVE defend objective (defends in plan order), then the
##            hold's wave. A priority objective's first wave goes out as soon as the caps allow, whatever else is on
##            the deck; its next waves wait for its own previous wave to be mostly beaten + the deck's lull.
##            Then, per deck, one other wave at a time: the last released wave must be mostly beaten (alive / total
##            <= BEATEN, no units pending, its door open; or, for this spacing only, its reported alive count unchanged
##            for STALL s) and the deck's lull (LULL on deck 0 -> LULL_MIN on the lowest) elapsed since; lowest-index
##            due wave first. Free waves and step-done waves (a flag's alarm) go out only while a standing mech is on
##            their deck (crew_deck); a free wave waits for the crew to come back, an alarm wave is cancelled after
##            ALARM_EXPIRE s due with nobody there. Crew decks are served first; while a crew deck's due wave is held
##            only by the section cap, no other deck releases.
##   source   chosen at release (with the "crew" fact): target = the objective's site (defend / hold waves, a flag's
##            alarm), else the standing crew's centroid on that deck (fallback: the planned source's point); the deck's
##            open source nearest the target that is >= MIN_SOURCE_DIST from every standing mech on the deck, sources
##            within MAX_SOURCE_DIST of the target preferred over any farther one (never dropped for distance). Without
##            "crew": the plan's source (after any re-route). Follow-up loads keep the wave's source.
##   cancel   unreleased step-start waves of an objective that is done or failed (a step-done wave, e.g. a flag's
##            alarm, is never cancelled by its objective's completion, only by ALARM_EXPIRE); the deck's unreleased
##            linger wave once its primary is done; a wave whose source is closed re-routes to the open source of its
##            deck nearest its planned source, or is cancelled (a released wave just stops its follow-ups).
## state() = {"waves": [[released, total] per deck], "next": {"<deck>": open_at of the order in flight},
##            "left": [waves_left per deck, as the host counts it]}   JSON-safe; clients' waves_left() reads "left"

const DECK_CAP := 24
const SECTION_CAP := 40
const WAVE_MAX := 8             ## informational: the spawner sizes waves from share
const LULL := 25.0              ## lull on the first deck (s)
const LULL_MIN := 15.0          ## ... down to this on the lowest
const BEATEN := 0.25            ## a wave is mostly beaten at alive / total <= this
const TELEGRAPH := {"gate": 5.0, "lift": 5.0, "ramp": 3.0, "shaft": 3.0}
const GARRISON_LOW := 0.25
const MIN_LEAD := 1.0           ## every open_at is at least this after t (clients must get the event first)
const GRACE := 10.0             ## a released wave the spawner never reports counts as beaten this long after open_at
const FOLLOW_GAP := 2.0         ## a follow-up order waits this long after the previous load's door opened
const ALARM_EXPIRE := 20.0      ## a due step-done wave with nobody on its deck this long is cancelled
const MIN_SOURCE_DIST := 60.0   ## a wave's source at least this far from every standing mech on the deck (if any is)
const MAX_SOURCE_DIST := 300.0  ## sources within this of the target point are preferred over farther ones
const STALL := 90.0             ## a reported wave whose alive count has not moved this long counts beaten for spacing

var options: Dictionary = {}
var plan: MissionPlan
var _waves: Array[Dictionary] = []   ## per pool wave: {id, deck, index, trigger, objective, orig, source, status,
									 ##   open_at, max_units, dropped, beaten_t (spacing), seen_alive, seen_t (last
									 ##   change of its reported alive count), away_t (due with nobody on the deck
									 ##   since)}   status queued | due | released | cancelled
var _seen_t: Array[float] = []       ## per deck: t a standing mech was first seen there (-1 never)
var _gar_total: Array[int] = []      ## per deck: first garrison_alive seen (-1 none yet)
var _beaten_t: Array[float] = []     ## per deck: t the last released wave became mostly beaten (-1 not yet / none)
var _last: Array[int] = []           ## per deck: index into _waves of the last released wave (-1 none)
var _t := 0.0
var _wave_alive: Dictionary = {}     ## last facts.wave_alive
var _pending: Dictionary = {}        ## last facts.wave_pending
var _size: Dictionary = {}           ## last facts.wave_size
var _released: Array[int] = []       ## per deck, what state() sends
var _total: Array[int] = []
var _next: Dictionary = {}           ## "<deck>" -> open_at
var _left: Array[int] = []           ## client: the host's waves_left per deck (state "left"; empty = not sent)
var _mirror := false                 ## a client that applied the host's state


func net_fields() -> Dictionary:
	return {
		"options": Net.SPAWN,        # the constants' overrides, fixed at creation
		"plan": Net.LOCAL,           # derived from the seed on every machine
		# the host's queue: never sent as such
		"_waves": Net.PRIVATE, "_seen_t": Net.PRIVATE, "_gar_total": Net.PRIVATE, "_beaten_t": Net.PRIVATE,
		"_last": Net.PRIVATE, "_t": Net.PRIVATE, "_wave_alive": Net.PRIVATE, "_pending": Net.PRIVATE,
		"_size": Net.PRIVATE,
		# what state() broadcasts: the host writes, clients apply_state()
		"_released": Net.OWNER, "_total": Net.OWNER, "_next": Net.OWNER, "_left": Net.OWNER,
		"_mirror": Net.LOCAL,
	}


static func make(p: MissionPlan, overrides: Dictionary = {}) -> WaveDirector:
	var d := WaveDirector.new()
	d.plan = p
	d.options = {"deck_cap": DECK_CAP, "section_cap": SECTION_CAP, "wave_max": WAVE_MAX, "lull": LULL,
			"lull_min": LULL_MIN, "beaten": BEATEN, "telegraph": TELEGRAPH.duplicate(), "garrison_low": GARRISON_LOW,
			"grace": GRACE, "follow_gap": FOLLOW_GAP, "alarm_expire": ALARM_EXPIRE, "min_source_dist": MIN_SOURCE_DIST,
			"max_source_dist": MAX_SOURCE_DIST, "stall": STALL}
	for id: String in overrides:
		if d.options.has(id):
			d.options[id] = overrides[id]
	var tg: Dictionary = TELEGRAPH.duplicate()
	if d.options["telegraph"] is Dictionary:
		for kind: String in d.options["telegraph"]:
			tg[kind] = float(d.options["telegraph"][kind])
	for kind: String in tg:
		tg[kind] = maxf(float(tg[kind]), MIN_LEAD)
	d.options["telegraph"] = tg
	var n := p.deck_count
	for k in n:
		d._seen_t.append(-1.0)
		d._gar_total.append(-1)
		d._beaten_t.append(-1.0)
		d._last.append(-1)
		d._released.append(0)
		d._total.append(0)
	for pl: Dictionary in p.pools:
		var waves: Array = pl["waves"]
		for i in waves.size():
			var w: Dictionary = waves[i]
			var tr: Dictionary = w["trigger"]
			d._waves.append({"id": w["id"], "deck": int(pl["deck"]), "index": i, "trigger": tr,
					"objective": str(tr.get("id", "")) if tr["kind"] == "objective" else "", "orig": w["source"],
					"source": w["source"], "status": "queued", "open_at": 0.0, "max_units": 0, "reserve": 0, "dropped": false,
					"beaten_t": -1.0, "seen_alive": -1, "seen_t": -1.0, "away_t": -1.0})
	d._summarise()
	return d


func lull(k: int) -> float:
	var n := plan.deck_count
	var f := float(k) / float(n - 1) if n > 1 else 0.0
	return lerpf(float(options["lull"]), float(options["lull_min"]), f)


# --- Host ------------------------------------------------------------------------------------------------

func tick(t: float, facts: Dictionary) -> Array:
	_t = t
	var n := plan.deck_count
	var alive := _per_deck(facts.get("alive", []))
	var garrison: Array = facts.get("garrison_alive", [])
	_wave_alive = facts.get("wave_alive", {}) if facts.get("wave_alive", {}) is Dictionary else {}
	_pending = facts.get("wave_pending", {}) if facts.get("wave_pending", {}) is Dictionary else {}
	_size = facts.get("wave_size", {}) if facts.get("wave_size", {}) is Dictionary else {}
	var crew := {}
	for k: Variant in facts.get("crew_deck", []):
		crew[int(k)] = true
	# Standing crew positions per deck, for the source choice (null: no crew facts, planned sources).
	var crew_pts: Variant = null
	if facts.get("crew", null) is Array:
		crew_pts = {}
		for c: Variant in facts["crew"]:
			if not (c is Dictionary) or bool(c.get("downed", false)):
				continue
			var ck := int(c.get("deck", -1))
			if not crew_pts.has(ck):
				crew_pts[ck] = []
			crew_pts[ck].append(Vector2(float(c.get("x", 0.0)), float(c.get("s", 0.0))))
	var closed := {}
	for id: Variant in facts.get("closed", []):
		closed[str(id)] = true
	var objs: Dictionary = {}
	var ob: Variant = facts.get("objectives", {})
	if ob is Dictionary and (ob as Dictionary).get("objs", null) is Dictionary:
		objs = ob["objs"]
	for k in n:
		if crew.has(k) and _seen_t[k] < 0.0:
			_seen_t[k] = t
		if k < garrison.size() and garrison[k] != null and _gar_total[k] < 0:
			_gar_total[k] = maxi(int(garrison[k]), 0)
	# Released waves: when their reported alive count last moved (stall guard), when they became beaten for spacing.
	for w: Dictionary in _waves:
		if w["status"] != "released":
			continue
		var wa: Variant = _wave_alive.get(w["id"], null)
		if wa is Dictionary and int(wa.get("total", 0)) > 0 and int(wa.get("alive", 0)) != int(w["seen_alive"]):
			w["seen_alive"] = int(wa.get("alive", 0))
			w["seen_t"] = t
		if float(w["beaten_t"]) < 0.0 and _spacing_beaten(w):
			w["beaten_t"] = t
	# Mostly beaten: start the deck's lull.
	for k in n:
		if _last[k] >= 0 and _beaten_t[k] < 0.0 and _spacing_beaten(_waves[_last[k]]):
			_beaten_t[k] = t
	# Cancel and re-route.
	for w: Dictionary in _waves:
		var st: String = w["status"]
		if st == "cancelled":
			continue
		if st == "queued" or st == "due":
			var tr: Dictionary = w["trigger"]
			if tr["kind"] == "objective" and str(tr.get("step", "start")) == "start" \
					and _obj_state(objs, w["objective"]) in ["done", "failed"]:
				w["status"] = "cancelled"
				continue
			if tr["kind"] == "linger" and _primary_done(objs, int(w["deck"])):
				w["status"] = "cancelled"
				continue
		if (st != "released" or _pending_of(w) > 0) and closed.has(w["source"]) and not w["dropped"]:
			var o := plan.source(w["orig"])
			var alt := plan.nearest_source(int(w["deck"]), Vector2(float(o["x"]), float(o["s"])), closed.keys())
			if alt != "":
				w["source"] = alt
			elif st == "released":
				w["dropped"] = true
			else:
				w["status"] = "cancelled"
	# Triggers.
	for w: Dictionary in _waves:
		if w["status"] != "queued":
			continue
		var k := int(w["deck"])
		var tr: Dictionary = w["trigger"]
		match str(tr["kind"]):
			"objective":
				var s := _obj_state(objs, w["objective"])
				if str(tr.get("step", "start")) == "done":
					if s == "done":
						w["status"] = "due"
				elif s in ["active", "done", "failed"]:
					w["status"] = "due"
			"garrison_low":
				if _seen_t[k] >= 0.0 and _gar_total[k] >= 0 and k < garrison.size() and garrison[k] != null \
						and float(int(garrison[k])) <= float(options["garrison_low"]) * float(_gar_total[k]):
					w["status"] = "due"
			"linger":
				if _seen_t[k] >= 0.0 and t - _seen_t[k] >= float(tr.get("after", 0.0)) and not _primary_done(objs, k):
					w["status"] = "due"
	# §5.4 rule 5: the garrison is gone and nothing from waves is alive or arriving: the next garrison_low wave is due
	# at once (whatever the threshold saw), else the linger wave. Without a garrison_alive entry for the deck, a deck
	# with nothing alive at all (facts.alive[k] == 0) counts as garrison gone.
	var has_alive: bool = facts.get("alive", null) is Array
	for k in n:
		if _seen_t[k] < 0.0:
			continue
		var gone := false
		if k < garrison.size() and garrison[k] != null:
			gone = int(garrison[k]) <= 0
		elif has_alive:
			gone = alive[k] == 0
		if not gone or _deck_busy(k) or _any_due(k):
			continue
		var pick := {}
		for w: Dictionary in _waves:
			if int(w["deck"]) != k or w["status"] != "queued" or w["objective"] != "":
				continue
			if w["trigger"]["kind"] == "garrison_low":
				pick = w
				break
			if pick.is_empty():
				pick = w
		if not pick.is_empty():
			pick["status"] = "due"
	# An alarm (step-done) wave due with nobody on its deck for ALARM_EXPIRE s is cancelled.
	for w: Dictionary in _waves:
		if w["status"] != "due" or not _is_alarm(w):
			continue
		if crew.has(int(w["deck"])):
			w["away_t"] = -1.0
			continue
		if float(w["away_t"]) < 0.0:
			w["away_t"] = t
		if t - float(w["away_t"]) >= float(options["alarm_expire"]):
			w["status"] = "cancelled"
	# Room.
	var inflight: Array[int] = []
	inflight.resize(n)
	inflight.fill(0)
	var sum_alive := 0
	for k in n:
		sum_alive += alive[k]
	for w: Dictionary in _waves:
		if w["status"] == "released" and t < float(w["open_at"]):
			inflight[int(w["deck"])] += int(w["reserve"])
	var order_decks: Array[int] = []
	for k in n:
		if crew.has(k):
			order_decks.append(k)
	for k in n:
		if not crew.has(k):
			order_decks.append(k)
	var orders: Array = []
	var crew_blocked := false
	for k in order_decks:
		if crew_blocked and not crew.has(k):
			break
		var room := _room(k, alive, inflight, sum_alive)
		# Follow-up loads of a partial release.
		for w: Dictionary in _waves:
			if int(w["deck"]) != k or w["status"] != "released" or w["dropped"] or _pending_of(w) <= 0:
				continue
			if t < float(w["open_at"]) + float(options["follow_gap"]) or room <= 0:
				continue
			var mu := mini(room, _pending_of(w))
			orders.append(_order(w, t, mu, true))
			inflight[k] += mu
			room -= mu
		# Priority waves: an active defend's (then the hold's) next wave; the first one skips the deck's spacing.
		var held := false
		for w: Dictionary in _priority_waves(k, objs):
			var prev := _objective_last(str(w["objective"]))
			if not prev.is_empty() and (float(prev["beaten_t"]) < 0.0 or t - float(prev["beaten_t"]) < lull(k)):
				continue
			room = _room(k, alive, inflight, sum_alive)
			if room <= 0:
				if crew.has(k) and int(options["deck_cap"]) - alive[k] - inflight[k] > 0:
					crew_blocked = true
				held = true
				break
			orders.append(_release(w, t, room, closed, crew_pts))
			inflight[k] += int(w["reserve"])
		if held:
			continue
		# A new wave.
		if _deck_busy(k, true):
			continue
		if _last[k] >= 0 and (_beaten_t[k] < 0.0 or t - _beaten_t[k] < lull(k)):
			continue
		var next := {}
		for w: Dictionary in _waves:
			if int(w["deck"]) != k or w["status"] != "due" or _is_priority(w, objs):
				continue
			# Free waves and alarm waves only while a standing mech is on the deck.
			if (w["objective"] == "" or _is_alarm(w)) and not crew.has(k):
				continue
			next = w
			break
		if next.is_empty():
			continue
		room = _room(k, alive, inflight, sum_alive)
		if room <= 0:
			if crew.has(k) and int(options["deck_cap"]) - alive[k] - inflight[k] > 0:
				crew_blocked = true
			continue
		orders.append(_release(next, t, room, closed, crew_pts))
		inflight[k] += int(next["reserve"])
	_summarise()
	return orders


## Release a wave now: pick its source, mark it, order it with max_units.
func _release(w: Dictionary, t: float, max_units: int, closed: Dictionary, crew_pts: Variant) -> Dictionary:
	var k := int(w["deck"])
	if crew_pts is Dictionary:
		var src := _pick_source(w, closed, crew_pts.get(k, []))
		if src != "":
			w["source"] = src
	w["status"] = "released"
	_last[k] = _waves.find(w)
	_beaten_t[k] = -1.0
	return _order(w, t, max_units)


## The source for a wave released now (see the header, "source"); "" when the deck has no open source.
func _pick_source(w: Dictionary, closed: Dictionary, mine: Array) -> String:
	var k := int(w["deck"])
	var o := plan.source(w["orig"])
	var target := Vector2(float(o.get("x", 0.0)), float(o.get("s", 0.0)))
	var ob := plan.objective(str(w["objective"])) if w["objective"] != "" else {}
	if not ob.is_empty():
		target = Vector2(float(ob["site"]["x"]), float(ob["site"]["s"]))
	elif not mine.is_empty():
		var c := Vector2.ZERO
		for p: Vector2 in mine:
			c += p
		target = c / float(mine.size())
	var best := ""
	var best_rank := 4          # 0 inside MAX and clear of the crew, 1 inside MAX, 2 clear of the crew, 3 neither
	var best_d := INF
	for s: Dictionary in plan.deck_sources(k):
		if closed.has(s["id"]):
			continue
		var at := Vector2(float(s["x"]), float(s["s"]))
		var d := at.distance_to(target)
		var rank := 2 if d > float(options["max_source_dist"]) else 0
		for p: Vector2 in mine:
			if at.distance_to(p) < float(options["min_source_dist"]):
				rank += 1
				break
		if rank < best_rank or (rank == best_rank and d < best_d):
			best_rank = rank
			best_d = d
			best = s["id"]
	return best


## A step-done objective wave (a flag's alarm).
static func _is_alarm(w: Dictionary) -> bool:
	var tr: Dictionary = w["trigger"]
	return tr["kind"] == "objective" and str(tr.get("step", "start")) == "done"


## A due-able wave of an ACTIVE defend or hold objective (step start): goes through the priority path.
func _is_priority(w: Dictionary, objs: Dictionary, type: String = "") -> bool:
	var tr: Dictionary = w["trigger"]
	if tr["kind"] != "objective" or str(tr.get("step", "start")) != "start":
		return false
	if _obj_state(objs, w["objective"]) != "active":
		return false
	var ty := str(plan.objective(w["objective"]).get("type", ""))
	return ty == type if type != "" else ty in ["defend", "hold"]


## Deck k's priority waves now, one per objective (its lowest due wave): active defends in plan order, then the hold.
func _priority_waves(k: int, objs: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids := {}
	for type: String in ["defend", "hold"]:
		for w: Dictionary in _waves:
			if int(w["deck"]) != k or w["status"] != "due" or ids.has(w["objective"]) or not _is_priority(w, objs, type):
				continue
			ids[w["objective"]] = true
			out.append(w)
	return out


## The last released wave of an objective ({} none).
func _objective_last(id: String) -> Dictionary:
	var out := {}
	for w: Dictionary in _waves:
		if w["objective"] == id and w["status"] == "released":
			out = w
	return out


func _room(k: int, alive: Array[int], inflight: Array[int], sum_alive: int) -> int:
	var total_inflight := 0
	for v in inflight:
		total_inflight += v
	return mini(int(options["deck_cap"]) - alive[k] - inflight[k],
			int(options["section_cap"]) - sum_alive - total_inflight)


## `follow`: a follow-up load (max_units is already its pending units).
func _order(w: Dictionary, t: float, max_units: int, follow: bool = false) -> Dictionary:
	var src := plan.source(w["source"])
	var tg: Dictionary = options["telegraph"]
	var open_at := t + maxf(float(tg.get(str(src.get("kind", "gate")), MIN_LEAD)), MIN_LEAD)
	w["open_at"] = open_at
	w["max_units"] = max_units
	# Held against the caps until the door opens: the wave's expected size (facts.wave_size, else WAVE_MAX), at most
	# max_units; a follow-up holds its own load.
	var est := max_units if follow else maxi(int(_size.get(w["id"], options["wave_max"])), 1)
	w["reserve"] = mini(max_units, est)
	return {"wave": w["id"], "deck": int(w["deck"]), "source": w["source"], "open_at": open_at, "max_units": max_units}


func _per_deck(a: Variant) -> Array[int]:
	var out: Array[int] = []
	for k in plan.deck_count:
		out.append(maxi(int(a[k]), 0) if a is Array and k < (a as Array).size() and a[k] != null else 0)
	return out


func _pending_of(w: Dictionary) -> int:
	if w["dropped"]:
		return 0
	return maxi(int(_pending.get(w["id"], 0)), 0)


## Released and done arriving: door open, nothing pending, and at most BEATEN of it alive (or never reported for GRACE s).
func _is_beaten(w: Dictionary) -> bool:
	if _t < float(w["open_at"]) or _pending_of(w) > 0:
		return false
	var wa: Variant = _wave_alive.get(w["id"], null)
	if wa is Dictionary and int(wa.get("total", 0)) > 0:
		return float(int(wa.get("alive", 0))) <= float(options["beaten"]) * float(int(wa["total"]))
	return _t >= float(w["open_at"]) + float(options["grace"])


## For spacing only: beaten, or reported with its alive count unchanged for STALL s (stuck far away, never arriving).
func _spacing_beaten(w: Dictionary) -> bool:
	if _is_beaten(w):
		return true
	return float(w["seen_t"]) >= 0.0 and _t >= float(w["open_at"]) and _t - float(w["seen_t"]) >= float(options["stall"])


## Reported by the spawner: at least one of its units has appeared.
func _reported(w: Dictionary) -> bool:
	var wa: Variant = _wave_alive.get(w["id"], null)
	return wa is Dictionary and int(wa.get("total", 0)) > 0


## A wave on deck k is arriving or still fresh (`spacing`: the stall guard counts as beaten).
func _deck_busy(k: int, spacing: bool = false) -> bool:
	if _last[k] < 0:
		return false
	return not (_spacing_beaten(_waves[_last[k]]) if spacing else _is_beaten(_waves[_last[k]]))


func _any_due(k: int) -> bool:
	for w: Dictionary in _waves:
		if int(w["deck"]) == k and w["status"] == "due":
			return true
	return false


static func _obj_state(objs: Dictionary, id: String) -> String:
	var e: Variant = objs.get(id, null)
	if e is Array and (e as Array).size() > 0:
		return str(e[0])
	return ""


func _primary_done(objs: Dictionary, k: int) -> bool:
	var p := plan.primary(k)
	return not p.is_empty() and _obj_state(objs, p["id"]) == "done"


func _summarise() -> void:
	_next.clear()
	for k in plan.deck_count:
		_released[k] = 0
		_total[k] = 0
	for w: Dictionary in _waves:
		var k := int(w["deck"])
		if w["status"] == "cancelled":
			continue
		_total[k] += 1
		if w["status"] == "released":
			_released[k] += 1
			if _t < float(w["open_at"]):
				var key := str(k)
				_next[key] = maxf(float(_next.get(key, 0.0)), snappedf(float(w["open_at"]), 0.01))


# --- Reads -----------------------------------------------------------------------------------------------

## Waves still owed to deck k: due waves and queued garrison_low waves (not cancelled), plus released waves with units
## pending or not reported yet (door closed, or open and no unit seen) until open_at + GRACE (as objective_waves()).
## Not owed: a wave tied to an objective that has not started (it may never come: a bonus never found, the hold), a
## queued linger wave (a punishment, not a debt) and a cancelled alarm wave, so none holds a sweep up. On a client:
## the host's count from state()["left"] (total - released if the host did not send it).
func waves_left(k: int) -> int:
	if k < 0 or k >= plan.deck_count:
		return 0
	if _mirror:
		if _left.size() == plan.deck_count:
			return _left[k]
		return maxi(_total[k] - _released[k], 0)
	var n := 0
	for w: Dictionary in _waves:
		if int(w["deck"]) != k:
			continue
		match str(w["status"]):
			"due":
				n += 1
			"queued":
				if w["objective"] == "" and w["trigger"]["kind"] != "linger":
					n += 1
			"released":
				if _pending_of(w) > 0 or (not _reported(w) and _t < float(w["open_at"]) + float(options["grace"])):
					n += 1
	return n


func waves_left_all() -> Array:
	var out := []
	for k in plan.deck_count:
		out.append(waves_left(k))
	return out


## For MissionRules' defend_waves fact: {objective id: {released, total, alive}} for every objective with waves. alive
## counts a wave's reported alive + pending units, and a released wave whose units have not appeared yet as its order.
func objective_waves() -> Dictionary:
	var out := {}
	for w: Dictionary in _waves:
		var id: String = w["objective"]
		if id == "":
			continue
		if not out.has(id):
			out[id] = {"released": 0, "total": 0, "alive": 0}
		var e: Dictionary = out[id]
		if w["status"] == "cancelled":
			continue
		e["total"] += 1
		if w["status"] != "released":
			continue
		e["released"] += 1
		var wa: Variant = _wave_alive.get(w["id"], null)
		if _reported(w):
			e["alive"] += maxi(int(wa.get("alive", 0)), 0)
		elif _t < float(w["open_at"]) + float(options["grace"]):
			e["alive"] += maxi(int(w["reserve"]), 1)
		e["alive"] += _pending_of(w)
	return out


## Status of one wave: queued | due | released | cancelled ("" for an unknown id). Host only.
func status(id: String) -> String:
	for w: Dictionary in _waves:
		if w["id"] == id:
			return w["status"]
	return ""


## Current source of one wave (after any re-route). Host only.
func source_of(id: String) -> String:
	for w: Dictionary in _waves:
		if w["id"] == id:
			return w["source"]
	return ""


func state() -> Dictionary:
	var waves := []
	for k in plan.deck_count:
		waves.append([_released[k], _total[k]])
	return {"waves": waves, "next": _next.duplicate(), "left": waves_left_all()}


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
