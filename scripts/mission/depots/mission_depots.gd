class_name MissionDepots
extends Node
## Military supply depots in a plan-mode mission (docs/design/pacing-director.md §2). Child "MissionDepots" of
## MissionFlow, on every machine, built in MissionFlow.rebuild from `plan.depots`.
##
## SHAPE: host-arbitrated world object (AGENTS rule 6). The pilot's machine asks, the host decides, the mech's owner
## applies the effect on its own mech (rule 2).
##   PLACE (every machine, plan data + the built deck only): each plan depot gets SiteFit.place_depots (KEEP-OUT, WIDEST-MECH FIT,
##     no fallback: see SiteFit) and a SupplyDepot (look, collision, DepotTarget) goes under its deck's CityDistrict; a depot
##     no valid site on its deck takes is not built (unplaced) and its cores are dropped.
##   CORES: cores_max = plan cores (1 per pilot) x the crew at mission start, at least MissionPlan.DEPOT_CORES_MIN (2) (the launch's crew: the same on every
##     machine); the host then decides `cores_left` / `alive`, which ride in mission.state as "depots":
##     {id: [cores_left, alive 0 | 1]} (state / apply_state), so a barrier latecomer starts from them.
##   CLAIM (this machine's own pilot): standing (PlayerTarget not disabled) within CLAIM_RANGE of a live depot's
##     footprint that has cores, for CLAIM_TIME s without a break -> claim: a client sends depot.claim {depot, n}
##     (Session.mission.client_depot_claim; n = this pilot's claim counter), the host / solo arbitrates its own at once. Unanswered after
##     RESEND s: re-sent with the same n. The HUD line "Taking power core: 60%" (progress_line) shows meanwhile.
##   ARBITRATE (host / solo only): the depot exists, is alive, has cores, the pilot (its replicated position: the host's
##     own mech or the puppet) stands on the depot's deck within CLAIM_RANGE + RANGE_SLACK of the footprint and is not
##     down, and its last grant is CLAIM_COOLDOWN s old -> cores_left - 1, seq + 1, depot.grant {depot, peer, seq,
##     cores_left} to the crew (Session.mission.host_depot_grant); else depot.deny {depot, reason, n} to the asker. One answer
##     per (pilot, n): a re-sent claim gets the same answer again (a grant to the asker only, same seq), an older n
##     nothing. Only the host decrements, so a core is never spent twice.
##   GRANT (every machine): applied once, by seq: a grant whose seq is not newer than the last one applied here is
##     ignored (duplicate or out of order). The grant's cores_left is mirrored; when grant.peer is this machine's pilot,
##     the core's effect (apply_core_to) goes on its own mech.
##   DESTROYED (host): the DepotTarget reaching 0 HP (weapons fire: crew or stray shots; enemies never target it, team "")
##     -> alive false, the remaining cores lost; mission.state carries it, every machine shows the wreck.
## Log: CombatLog.note_depot when the drive's log has it, else one "[Flow] ... depot: kind=... depot=... key=value" line.

const CLAIM_RANGE := 6.0          ## m from the depot's footprint a pilot stands in to take a core
const CLAIM_TIME := 2.0           ## s standing in range, without a break
const RANGE_SLACK := 4.0          ## m the host allows on top (the puppet lags its owner)
const CLAIM_COOLDOWN := 5.0       ## s between two grants to one pilot
const RESEND := 1.0               ## s without an answer before a claim is re-sent
const DENY_PAUSE := 1.0           ## s the local claim waits after a deny before it counts again
## The effect of one core (pacing-director.md §2.1, proposal; tune here).
const CORE_REPAIR := 0.5          ## every surviving component gets this share of its missing structure back
const CORE_REBUILD := 0.3         ## destroyed components come back at this share of their max (their weapons work again)
const CORE_REFILL := true         ## every limited-ammo weapon (and active equipment's charges) refilled
const CORE_VENT := true           ## heat to zero, shutdown cleared
const LINE := "Taking power core: %d%%"
## HOST BOTS (hangar bots: negative pilot ids, their mechs run on the host: MissionScene.crew_bots -> CrewBot with its own
## PlayerTarget / WeaponRack). The host treats each like a local pilot (the same stand timer, claim_for through the same
## arbitration, the grant broadcast to the crew, the effect applied here on the bot's own mech: rule 2, the host owns it),
## but only while it NEEDS a core (needs_core), so a bot walking past never drains a depot. Human pilots decide by standing.
const BOT_NEED_STRUCTURE := 0.7   ## a bot needs a core below this share of its total structure ...
## ... or with any component destroyed, or any weapon empty / unusable (needs_core_of).

## Host: a core was granted to a pilot this machine owns that is NOT its own player: a host-owned bot (negative pilot id,
## docs/design/hangar-bots.md). The bot's code applies the effect on its mech: MissionDepots.apply_core_to(its
## PlayerTarget, its WeaponRack) (rule 2: the owner, the host, changes its own bot's mech).
signal bot_core_granted(pilot_id: int, depot_id: String)
## Every machine: a grant was applied here, any pilot, once per grant (by seq). The host's MissionStats counts `cores` from it.
signal core_granted(pilot_id: int, depot_id: String)

var flow: MissionFlow
var drive: MissionScene
var plan: MissionPlan
var crew := false
var sites: Dictionary = {}        ## depot id -> {deck, x, s, h, snapped, ok}: where it stands (plan + snap rule)
var nodes: Dictionary = {}        ## depot id -> SupplyDepot
var cores_max: Dictionary = {}    ## depot id -> cores at mission start
var cores_left: Dictionary = {}   ## depot id -> cores left (the host decides; clients mirror grants and the state)
var alive: Dictionary = {}        ## depot id -> bool (the host decides)
var applied := 0                  ## cores applied to this machine's mech (tests)
var dup_grants := 0               ## grants ignored here as duplicate / out of order (tests)
var records: Array = []           ## this machine's depot records [{kind, depot, ...}] (tests, logs)
var _seq := 0                     ## host: the last grant's sequence number
var _granted_at: Dictionary = {}  ## host: peer -> mission time of its last grant
var _answered: Dictionary = {}    ## host: peer -> {n, kind, data}: its last claim's answer
var _last_seq := 0                ## the newest grant applied on this machine
var _t := 0.0                     ## local seconds (claim timers)
var _stand_depot := ""            ## the depot this pilot stands at ("" = none)
var _stand_t := 0.0               ## s standing there without a break
var _inflight: Dictionary = {}    ## {depot, n, sent}: this pilot's unanswered claim
var _nonce := 0                   ## this pilot's claim counter
var _cooldown_until := 0.0        ## _t before which no new claim counts
var _registered: Dictionary = {}  ## depot id -> true once its target is in the combat world
var _bot_nonce: Dictionary = {}   ## host: bot pilot id -> its claim counter (claim_for)
var _bot_stand: Dictionary = {}   ## host: bot pilot id -> [depot id, s standing there]
var _bot_wait: Dictionary = {}    ## host: bot pilot id -> _t before which its timer doesn't count (after an answer)
var last_grant: Dictionary = {}   ## the newest grant applied here, any pilot (tests, logs)


func net_fields() -> Dictionary:
	return {"flow": Net.LOCAL, "drive": Net.LOCAL, "plan": Net.LOCAL, "crew": Net.SPAWN,
		"sites": Net.SPAWN,           # plan + snap rule: the same on every machine
		"nodes": Net.LOCAL, "cores_max": Net.SPAWN,
		"cores_left": Net.OWNER, "alive": Net.OWNER,   # the host decides; grants + mission.state carry them
		"applied": Net.LOCAL, "dup_grants": Net.LOCAL, "records": Net.LOCAL,
		"_seq": Net.PRIVATE, "_granted_at": Net.PRIVATE, "_answered": Net.PRIVATE,
		"_last_seq": Net.LOCAL, "_t": Net.LOCAL, "_stand_depot": Net.PRIVATE, "_stand_t": Net.PRIVATE,
		"_inflight": Net.PRIVATE, "_nonce": Net.PRIVATE, "_cooldown_until": Net.PRIVATE, "_registered": Net.LOCAL,
		"_bot_nonce": Net.PRIVATE, "unplaced": Net.SPAWN, "keep_outs": Net.LOCAL,
		"_stack_ref": Net.LOCAL, "_mw_ref": Net.LOCAL, "_bot_stand": Net.PRIVATE, "_bot_wait": Net.PRIVATE, "last_grant": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 41   # after MissionFlow (40)


func setup(f: MissionFlow) -> void:
	flow = f
	drive = f.drive
	plan = f.plan
	crew = f.crew
	# The crew scale at mission start = the host's (MissionFlow.crew_scale(): the launch crew, players AND hangar bots, as
	# the host counted it), never this machine's roster / crew list. Cores placed here stay for the mission: a later rescale
	# (a pilot left) removes no socket. Pilot ids are keys everywhere (bots' are negative): no id > 0 assumption.
	var n_crew := f.crew_scale()
	for d: Dictionary in plan.depots:
		var id := str(d["id"])
		cores_max[id] = maxi(int(d["cores"]) * maxi(n_crew, 1), MissionPlan.DEPOT_CORES_MIN)
		cores_left[id] = int(cores_max[id])
		alive[id] = true
	_place()
	var s := Net.session()
	if crew and s != null:
		# Methods, not lambdas: Session outlives this node, and a method connection goes away with it.
		s.depot_claimed.connect(_on_claim)
		s.depot_granted.connect(_on_grant)
		s.depot_denied.connect(_on_deny)


## Host: pilot `pilot_id` left the crew (MissionFlow.on_member_retired): drop its claim bookkeeping (last grant time, last
## answer, a bot's claim counter / stand timer / wait). Cores and depots are unchanged.
func forget_pilot(pilot_id: int) -> void:
	for d: Dictionary in [_granted_at, _answered, _bot_nonce, _bot_stand, _bot_wait]:
		d.erase(pilot_id)


## Remove the depots from the world and the combat world (MissionFlow.rebuild, solo N).
func teardown() -> void:
	var w := _world()
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if n == null or not is_instance_valid(n):
			continue
		if w != null and is_instance_valid(n.target):
			w.unregister(n.target)
		n.queue_free()
	nodes = {}
	_registered = {}


func _world() -> CombatWorld:
	return drive.combat.world if drive != null and drive.combat != null else null


## The built stack / mission world placement reads (the drive's, or what place_on was given).
func _stk() -> CityStack:
	if _stack_ref != null:
		return _stack_ref
	return drive.stack if drive != null else null


func _mw() -> MissionWorld:
	if _mw_ref != null and is_instance_valid(_mw_ref):
		return _mw_ref
	var w := flow.world if flow != null else null
	return w if w != null and is_instance_valid(w) else null


## PLACEMENT ONLY (tests, sweeps): the sites the depots of plan `p` get on built stack `stk` with mission world `mw`
## (the same rule and the same answer as a mission's setup; no SupplyDepot nodes, no session). Free it when done.
static func place_on(stk: CityStack, mw: MissionWorld, p: MissionPlan) -> MissionDepots:
	var md := MissionDepots.new()
	md._stack_ref = stk
	md._mw_ref = mw
	md.plan = p
	for d: Dictionary in p.depots:
		var id := str(d["id"])
		md.cores_max[id] = MissionPlan.DEPOT_CORES_MIN
		md.cores_left[id] = MissionPlan.DEPOT_CORES_MIN
		md.alive[id] = true
	md._place(false)
	return md


# --- Placement (every machine) ---------------------------------------------------------------------------------

## The sites come from SiteFit.place_depots (KEEP-OUT, WIDEST-MECH FIT, no fallback: plan data, the built decks' plans and
## the mission world's snapped sites only, so every machine places the same depots); a depot no valid site on its deck
## takes is not built (unplaced) and its cores are dropped.
func _place(build_nodes: bool = true) -> void:
	var stk := _stk()
	if stk == null:
		return
	var got := SiteFit.place_depots(stk, _mw(), plan)
	keep_outs = got["keep"]
	for u: Array in got["unplaced"]:
		# No spot on the whole deck where the depot blocks nothing and the widest mech reaches it: no depot here (its
		# cores are not moved elsewhere). Counted and reported; every machine drops the same one.
		var id := str(u[0])
		unplaced.append(id)
		for dd: Dictionary in [cores_max, cores_left, alive]:
			dd.erase(id)
		push_warning("[depot] %s (deck %d): no valid site on the deck (%s), not placed" % [id, int(u[1]), str(u[2])])
	for id: String in got["sites"]:
		var snap: Dictionary = got["sites"][id]
		sites[id] = snap
		if not build_nodes:
			continue
		var k := int(snap["deck"])
		var dist: CityDistrict = stk.decks[k]
		var node := SupplyDepot.new()
		node.build(dist, MissionProps.site_frame(dist, float(snap["x"]), float(snap["s"]), float(snap["h"])), id, k,
			int(cores_max[id]), int(snap["face"]))
		dist.add_child(node)
		nodes[id] = node
		node.show_state(int(cores_left[id]), true)


var unplaced: Array[String] = []  ## plan depots no valid site on their deck took (not built; their cores dropped)
var keep_outs: Dictionary = {}    ## deck -> the keep-out its depots were placed against (SiteFit.place_depots; tests)
var _stack_ref: CityStack = null  ## place_on: the stack to place on (else the drive's)
var _mw_ref: MissionWorld = null  ## place_on: the mission world (else the flow's)


## Distance (m, in the deck's arc coordinates) from (x, s) to depot `id`'s footprint (SupplyDepot.footprint_half: the
## symmetric box round its collision).
func footprint_dist(id: String, x: float, s: float) -> float:
	var st: Dictionary = sites.get(id, {})
	if st.is_empty():
		return INF
	var half := SupplyDepot.footprint_half(int(st.get("face", 0)))
	var dx := maxf(absf(x - float(st["x"])) - half.x, 0.0)
	var ds := maxf(absf(s - float(st["s"])) - half.y, 0.0)
	return sqrt(dx * dx + ds * ds)


## World point of depot `id` on the ground (Vector3.ZERO if unknown).
func depot_pos(id: String) -> Vector3:
	var st: Dictionary = sites.get(id, {})
	if st.is_empty() or drive == null or drive.stack == null:
		return Vector3.ZERO
	return drive.stack.from_deck_arc(int(st["deck"]), float(st["x"]), float(st["s"]), float(st.get("h", 0.0)))


func has_cores(id: String) -> bool:
	return bool(alive.get(id, false)) and int(cores_left.get(id, 0)) > 0


## The live depot with cores whose footprint is nearest to world point `pos` within `reach` m on pos's deck; "" if none.
func depot_in_range(pos: Vector3, reach: float) -> String:
	if drive == null or drive.stack == null:
		return ""
	var a := drive.stack.to_deck_arc(pos)
	var best := ""
	var best_d := INF
	for id: String in sites:
		if not has_cores(id) or int(sites[id]["deck"]) != int(a["deck"]):
			continue
		var d := footprint_dist(id, float(a["x"]), float(a["s"]))
		if d <= reach and d < best_d:
			best_d = d
			best = id
	return best


## BOT HOOK (Engine's MissionBot / scripts/bots): the live depot with cores on deck `deck` nearest to world point `pos`:
## {id, deck, x, s, pos: Vector3 on the ground, cores_left, dist: m in arc coordinates}, or {} when none. Standing within
## CLAIM_RANGE of its footprint for CLAIM_TIME s takes a core automatically (the same rule as a player; nothing to call).
func nearest_with_cores(deck: int, pos: Vector3) -> Dictionary:
	if drive == null or drive.stack == null:
		return {}
	var a := drive.stack.to_deck_arc(pos)
	var best: Dictionary = {}
	var best_d := INF
	for id: String in sites:
		var st: Dictionary = sites[id]
		if not has_cores(id) or int(st["deck"]) != deck:
			continue
		var d := Vector2(float(a["x"]), float(a["s"])).distance_to(Vector2(float(st["x"]), float(st["s"])))
		if d < best_d:
			best_d = d
			best = {"id": id, "deck": deck, "x": float(st["x"]), "s": float(st["s"]), "pos": depot_pos(id),
				"cores_left": int(cores_left[id]), "dist": d}
	return best


# --- Replicated state ------------------------------------------------------------------------------------------

## What mission.state carries: {id: [cores_left, alive 0 | 1]}.
func state() -> Dictionary:
	var out := {}
	for id: String in cores_left:
		out[id] = [int(cores_left[id]), 1 if bool(alive[id]) else 0]
	return out


## Client: the host's state.
func apply_state(d: Dictionary) -> void:
	for id: Variant in d:
		var v: Variant = d[id]
		if not cores_left.has(str(id)) or not (v is Array) or (v as Array).size() < 2:
			continue
		cores_left[str(id)] = int(v[0])
		alive[str(id)] = int(v[1]) != 0


# --- Every frame -----------------------------------------------------------------------------------------------

func _physics_process(dt: float) -> void:
	_t += dt
	_register_targets()
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if n != null and is_instance_valid(n):
			n.show_state(int(cores_left.get(id, 0)), bool(alive.get(id, false)))
	_claim_tick(dt)
	_bot_tick(dt)


## Each depot's DepotTarget joins the combat world once it exists (every machine; the host / solo hears its depot_down).
func _register_targets() -> void:
	var w := _world()
	if w == null or _registered.size() == nodes.size():
		return
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if _registered.has(id) or n == null or not is_instance_valid(n.target):
			continue
		w.register(n.target)
		_registered[id] = true
		if w.owns(n.target):
			n.target.depot_down.connect(_on_depot_down)


func local_peer() -> int:
	return MechSpawn.owner_of(drive.mech) if drive != null else 0


## Host: the CrewBot of bot pilot `pilot_id` this machine runs (MissionScene.crew_bots), or null.
func _crew_bot(pilot_id: int) -> Node:
	if drive == null:
		return null
	return _live(drive.crew_bots.get(pilot_id)) as Node


## `v` when it is a live object, else null: read stored references through this BEFORE any `as` / `is` (a cast on a
## freed object raises).
static func _live(v: Variant) -> Object:
	return v as Object if is_instance_valid(v) else null   # is_instance_valid first: `is` on a freed object raises


## A CrewBot's field (mech / target / rack) when it is live, else null.
static func _bot_field(cb: Node, field: String) -> Object:
	return _live(cb.get(field)) if cb != null and is_instance_valid(cb) else null


## Whether host bot `pilot_id` needs a power core now (its own mech's state; false for anyone else). For the bot's AI:
## steer to nearest_with_cores while this is true.
func needs_core(pilot_id: int) -> bool:
	var cb := _crew_bot(pilot_id)
	if cb == null:
		return false
	return needs_core_of(_bot_field(cb, "target") as PlayerTarget, _bot_field(cb, "rack") as WeaponRack)


## The need rule: standing (not disabled) and total structure < BOT_NEED_STRUCTURE, or a component destroyed, or a
## weapon slot unusable (empty or on a destroyed hardpoint).
static func needs_core_of(pt: PlayerTarget, rack: WeaponRack) -> bool:
	if pt == null or pt.disabled:
		return false
	if pt.total_max_hp() > 0.0 and pt.total_hp() / pt.total_max_hp() < BOT_NEED_STRUCTURE:
		return true
	for c: String in pt.hp:
		if float(pt.hp[c]) <= 0.0:
			return true
	if rack != null:
		for i in rack.slot_count():
			if rack.weapons[i] != "" and not MechCatalog.is_equipment(rack.weapons[i]) and not rack.usable(i + 1):
				return true
	return false


## Host: every bot it runs takes a core like a local pilot: standing within CLAIM_RANGE of a live depot with cores for
## CLAIM_TIME s while it needs one -> claim_for.
func _bot_tick(dt: float) -> void:
	if not _deciding() or flow == null or not flow.released or flow.ended or drive == null:
		return
	for pid: int in drive.crew_bots:
		var cb := _crew_bot(pid)
		var m := _bot_field(cb, "mech") as Node3D   # null when the bot or its mech is gone: skipped this tick
		var id := ""
		if m != null and _t >= float(_bot_wait.get(pid, 0.0)) and needs_core(pid):
			id = depot_in_range(m.global_position, CLAIM_RANGE)
		var st: Array = _bot_stand.get(pid, ["", 0.0])
		if id == "":
			_bot_stand.erase(pid)
			continue
		if str(st[0]) != id:
			st = [id, 0.0]
		st[1] = float(st[1]) + dt
		_bot_stand[pid] = st
		if float(st[1]) >= CLAIM_TIME:
			_bot_stand.erase(pid)
			_note("claim", id, {"peer": pid})
			var why := claim_for(pid, id)
			_bot_wait[pid] = _t + (CLAIM_COOLDOWN if why == "" else DENY_PAUSE)


## A pilot that is a bot of the host (MissionScene.crew_bots, else Session.is_bot, else, with no Session, a negative id).
func _bot(pilot_id: int) -> bool:
	if _crew_bot(pilot_id) != null:
		return true
	var s := Net.session()
	if s != null:
		return s.is_bot(pilot_id)
	return pilot_id < 0


func _deciding() -> bool:
	return flow != null and flow.deciding()


func _claim_tick(dt: float) -> void:
	if flow == null or not flow.released or flow.ended or drive == null or drive.mech == null:
		_stand_t = 0.0
		_stand_depot = ""
		return
	if not _inflight.is_empty():
		if _t - float(_inflight["sent"]) >= RESEND:
			_inflight["sent"] = _t
			_send(str(_inflight["depot"]), int(_inflight["n"]))
		return
	var pt := drive.combat.player_target if drive.combat != null else null
	var id := ""
	if pt != null and not pt.disabled and _t >= _cooldown_until:
		id = depot_in_range(drive.mech.global_position, CLAIM_RANGE)
	if id == "":
		_stand_t = 0.0
		_stand_depot = ""
		return
	if id != _stand_depot:
		_stand_depot = id
		_stand_t = 0.0
	_stand_t += dt
	if _stand_t >= CLAIM_TIME:
		_stand_t = CLAIM_TIME
		claim_now(id)


## Claim a core of depot `id` now, skipping the stand timer (the timer calls it; tests). The answer clears it.
func claim_now(id: String) -> void:
	_nonce += 1
	_inflight = {"depot": id, "n": _nonce, "sent": _t}
	_note("claim", id, {"peer": local_peer(), "n": _nonce})
	_send(id, _nonce)


## HOST: claim a core of depot `id` for pilot `pilot_id` this machine owns (a host-owned bot, negative id): the same
## arbitration as any claim (range from the bot's mech, cooldown keyed by pilot id). The answer: a grant goes to the
## crew and bot_core_granted fires here; a deny is returned. Returns "" when granted, else the deny reason.
func claim_for(pilot_id: int, id: String) -> String:
	if not _deciding():
		return "not_host"
	var n := int(_bot_nonce.get(pilot_id, 0)) + 1
	_bot_nonce[pilot_id] = n
	_arbitrate(pilot_id, id, n)
	var ans: Dictionary = _answered.get(pilot_id, {})
	return "" if str(ans.get("kind", "")) == "grant" else str(ans.get("data", {}).get("reason", "unknown"))


func _send(id: String, n: int) -> void:
	if _deciding():
		_arbitrate(local_peer(), id, n)
	else:
		var s := Net.session()
		if s != null:
			s.mission.client_depot_claim(id, n)


## "Taking power core: 60%" while this pilot is taking one (the objective panel's line), else "".
func progress_line() -> String:
	if _stand_depot == "" or (_stand_t <= 0.0 and _inflight.is_empty()):
		return ""
	return line_for(1.0 if not _inflight.is_empty() else _stand_t / CLAIM_TIME)


static func line_for(fraction: float) -> String:
	return LINE % int(floor(clampf(fraction, 0.0, 1.0) * 100.0 + 1e-6))


# --- Host: arbitration -----------------------------------------------------------------------------------------

func _on_claim(from: int, data: Dictionary) -> void:
	if _deciding():
		_arbitrate(from, str(data.get("depot", "")), int(data.get("n", 0)))


func _arbitrate(peer: int, id: String, n: int) -> void:
	var prev: Dictionary = _answered.get(peer, {})
	if not prev.is_empty() and n <= int(prev["n"]):
		if n == int(prev["n"]):
			_reply(peer, prev, true)   # a re-sent claim: the same answer again
		return
	var reason := refusal(peer, id)
	var ans: Dictionary
	if reason == "":
		cores_left[id] = int(cores_left[id]) - 1
		_seq += 1
		_granted_at[peer] = flow.now()
		ans = {"n": n, "kind": "grant", "data": {"depot": id, "peer": peer, "seq": _seq, "cores_left": int(cores_left[id])}}
	else:
		ans = {"n": n, "kind": "deny", "data": {"depot": id, "reason": reason, "n": n}}
	_answered[peer] = ans
	_reply(peer, ans, false)


## Host: why `peer` may not take a core of depot `id` now ("" = it may).
func refusal(peer: int, id: String) -> String:
	if not cores_left.has(id):
		return "unknown"
	if not bool(alive[id]):
		return "destroyed"
	if int(cores_left[id]) <= 0:
		return "empty"
	if _granted_at.has(peer) and flow.now() - float(_granted_at[peer]) < CLAIM_COOLDOWN:
		return "cooldown"
	var p := _pilot(peer)
	if p.is_empty():
		return "no_pilot"
	if bool(p["downed"]):
		return "down"
	var a := drive.stack.to_deck_arc(p["pos"])
	if int(a["deck"]) != int(sites[id]["deck"]) or footprint_dist(id, float(a["x"]), float(a["s"])) > CLAIM_RANGE + RANGE_SLACK:
		return "range"
	return ""


## Host: {pos, downed} of `peer`'s mech as this machine knows it (its own, or the puppet of the owner's stream); {} if none.
func _pilot(peer: int) -> Dictionary:
	if peer == local_peer():
		var pt := drive.combat.player_target if drive.combat != null else null
		return {"pos": drive.mech.global_position, "downed": pt != null and pt.disabled}
	var cb := _crew_bot(peer)
	if cb != null:
		var bm := _bot_field(cb, "mech") as Node3D
		if bm == null:
			return {}   # the bot's mech is gone
		var bt := _bot_field(cb, "target") as PlayerTarget
		return {"pos": bm.global_position, "downed": bt != null and bt.disabled}
	var pp := _live(drive.crew_sync.puppets.get(peer)) as MechPuppet if drive.crew_sync != null else null
	if pp != null and is_instance_valid(pp.mech):
		return {"pos": pp.mech.global_position, "downed": pp.downed}
	return {}   # no such pilot here (every host bot has its CrewBot, every member its puppet)


func _reply(peer: int, ans: Dictionary, repeat: bool) -> void:
	var me := local_peer()
	var data: Dictionary = ans["data"]
	var s := Net.session()
	if str(ans["kind"]) == "grant":
		if repeat:
			if peer != me and crew and s != null:
				s.mission.host_depot_grant(data, peer)
			return
		if crew and s != null:
			s.mission.host_depot_grant(data, 0)
		if peer != me and not (_deciding() and _bot(peer)):   # a host bot's grant is noted with its effect
			_note("grant", str(data["depot"]), {"peer": peer, "seq": int(data["seq"])})
		_take_grant(data)
	else:
		if peer == me:
			_take_deny(data)
		else:
			_note("deny", str(data["depot"]), {"peer": peer, "reason": str(data["reason"])})
			if crew and s != null and not _bot(peer):
				s.mission.host_depot_deny(peer, data)


## Host / solo: a depot's bunker was destroyed: its cores are lost.
func _on_depot_down(id: String) -> void:
	if not alive.has(id) or not bool(alive[id]):
		return
	var lost := int(cores_left[id])
	alive[id] = false
	cores_left[id] = 0
	_note("destroyed", id, {"lost": lost})


# --- Every machine: answers ------------------------------------------------------------------------------------

func _on_grant(g: Dictionary) -> void:
	_take_grant(g)


func _on_deny(d: Dictionary) -> void:
	_take_deny(d)


## A grant (the host's own, or heard): applied once by seq; the effect on this machine's mech when it is the winner.
## True when it was new.
func _take_grant(g: Dictionary) -> bool:
	var seq := int(g.get("seq", 0))
	if seq <= _last_seq:
		dup_grants += 1
		return false
	_last_seq = seq
	var id := str(g.get("depot", ""))
	if cores_left.has(id):
		cores_left[id] = int(g.get("cores_left", 0))
	last_grant = g.duplicate()
	core_granted.emit(int(g.get("peer", 0)), id)
	if int(g.get("peer", 0)) != local_peer() or drive == null:
		var bp := int(g.get("peer", 0))
		if _deciding() and _bot(bp):
			var cb := _crew_bot(bp)
			var beff := apply_core_to(_bot_field(cb, "target") as PlayerTarget, _bot_field(cb, "rack") as WeaponRack) \
				if cb != null else {"applied": false}
			var bx := beff.duplicate()
			bx["peer"] = bp
			bx["seq"] = seq
			_note("grant", id, bx)
			bot_core_granted.emit(bp, id)
		return true
	_inflight = {}
	_stand_t = 0.0
	_stand_depot = ""
	_cooldown_until = _t + CLAIM_COOLDOWN
	var eff := apply_core_to(drive.combat.player_target if drive.combat != null else null,
		drive.combat.rack if drive.combat != null else null)
	if bool(eff.get("applied", false)):
		applied += 1
	var extra := eff.duplicate()
	extra["peer"] = local_peer()
	extra["seq"] = seq
	_note("grant", id, extra)
	return true


func _take_deny(d: Dictionary) -> void:
	if _inflight.is_empty() or str(d.get("depot", "")) != str(_inflight["depot"]) or int(d.get("n", -1)) != int(_inflight["n"]):
		return
	_inflight = {}
	_stand_t = 0.0
	_stand_depot = ""
	_cooldown_until = _t + DENY_PAUSE
	_note("deny", str(d.get("depot", "")), {"peer": local_peer(), "reason": str(d.get("reason", ""))})


## The effect of one power core on a mech, applied by its OWNER through the verbs (PlayerTarget repair_fraction /
## rebuild_destroyed / vent_heat, WeaponRack refill_ammo). A disabled mech gets nothing (no revive).
## {applied, repaired: HP, rebuilt: [components], refilled: slots}.
static func apply_core_to(pt: PlayerTarget, rack: WeaponRack) -> Dictionary:
	if pt == null or pt.disabled:
		return {"applied": false}
	var repaired := pt.repair_fraction(CORE_REPAIR, "depot")    # first: the rebuilt ones get only CORE_REBUILD
	var rebuilt := pt.rebuild_destroyed(CORE_REBUILD, "depot")
	var refilled := rack.refill_ammo() if CORE_REFILL and rack != null else 0
	if CORE_VENT:
		pt.vent_heat()
	return {"applied": true, "repaired": snappedf(repaired, 0.1), "rebuilt": rebuilt, "refilled": refilled}


# --- Log -------------------------------------------------------------------------------------------------------

func _note(kind: String, id: String, extra: Dictionary = {}) -> void:
	var left := int(cores_left.get(id, 0))
	var rec := {"kind": kind, "depot": id, "left": left}
	rec.merge(extra)
	records.append(rec)
	# CombatLog logs this machine's pilot only: the host's answers to other pilots print below.
	var pilot := int(extra.get("peer", local_peer()))
	var bot := pilot != local_peer() and _deciding() and _bot(pilot)
	var cl: Node = drive.get_node_or_null("CombatLog") if drive != null else null
	if (pilot == local_peer() or bot) and cl is CombatLog:
		var ev := "empty" if kind == "deny" and str(extra.get("reason", "")) == "empty" else kind
		if bot:
			ev += ":pilot%d" % pilot   # a host bot: its pilot id in the event (note_depot has no pilot field)
		CombatLog.note_depot(ev, id, left)
		return
	var parts := PackedStringArray()
	for key: String in extra:
		var v: Variant = extra[key]
		parts.append("%s=%s" % [key, ",".join(PackedStringArray(v)) if v is Array else str(v)])
	FlowLog.say("depot", "kind=%s depot=%s left=%d %s" % [kind, id, left, " ".join(parts)])
