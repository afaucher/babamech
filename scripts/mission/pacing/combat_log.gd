class_name CombatLog
extends Node
## The playtest's damage log: what THIS machine's player took and dealt, as "[Flow]" lines in the run's normal log (next
## to FlowLog's), so a log read after a playtest shows how close the pilot came to dying and how the fights went.
## Logging only: every var is LOCAL, nothing is synced, no network messages. Owner authority: each machine logs its own
## player (the local mech) from events that already happen on it.
##
## RECORDS (one line each; `[Flow] t=<FlowLog clock> <tag> mt=<mission s> peer=<id> key=value ...`, fields in this order):
##   dmg_in   src=<id>/<kind> wpn= comp= amt= n= dur= hp=<comp>:<cur>/<max>,... tot=<% total HP> core=<% weakest core
##            component> heat=<0..1> shut=0|1 heat_in=      damage to the local mech, per source + weapon + component
##            coalesced over WIN_IN s (mt = first hit, n = hits, dur = last - first; hp = HP when the line prints, at most
##            WIN_IN s later). Exact: the victim decides. Fall damage: src=fall/env wpn=fall; wall slams: src=wall/env.
##   dmg_out  tgt=<id>/<kind> wpn= amt= n= dur= thp=<% target HP left, -1 unknown> kill=0|1 est=0|1
##            the local player's hits per target + weapon over WIN_OUT s. est=0: this machine applied it (solo / host /
##            any host-owned target applied here), the amount after the target's own multipliers (weak points). est=1: a
##            client's hit on a host-owned target (applied on the host): the raw hit damage this machine computed, thp is
##            the local replica's, kill is never known here (0). wpn=dot: non-hit damage credited to the player (burns).
##   down     cause=<component> src=<id>/<kind> wpn=       the local mech was disabled (last hit's source)
##   help     reviver=0|1 dist=<m, -1 none>                 right after `down`: the call for help (DownedCrew.help_facts:
##                                                         a standing crewmate with a repair drone that can revive, and
##                                                         the nearest one's distance); no help source: not printed
##   revive   by=<shooter>|self down_s= tot=                stood up in place by a crewmate's drone, or by its own (self,
##                                                         R2.9 self-revive) (DownedRules): not a death
##   respawn  hold=1|0 down_s= tot=                         back up: hold=1 after the hold + redeploy (full structure and
##                                                         ammo since R2.12: tot=100),
##                                                         hold=0 any other way (the test hook, repair_all)
##   summary  hp= core= comp=<comp>:<%>,... heat= shut= in= out= near= nearest= combat=0|1 deck= obj= down=0|1
##            every SUMMARY_EVERY s of mission time: in / out = damage in this window, near = live enemies within
##            NEAR_RANGE m (nearest m, -1 none), combat = shot / hit / took damage within COMBAT_HOLD s (env damage:
##            falls, slams, doesn't count).
## amt is what the target's `damaged` reported. PlayerTarget / CombatTarget (and DepotTarget): the HP actually removed,
## no overkill (a 150 hit on a 100 HP head logs 100; a hit that removes nothing emits no `damaged` and logs nothing, or
## amt=0 with its heat_in for a heat-only hit); a hit on a player's destroyed hardpoint lands on the torso (comp=torso).
## EnemyBase: after its component multiplier (weak points), NOT clamped (overkill included; a hit on a broken non-core
## component reports its overflow_to_core share on the core). AssetTarget: the requested amount (it reports, never
## subtracts). So in / out / taken_by / dealt_by totals are true HP lost for players and plain targets, raw for enemies.
##   end      outcome= reason= in= out= kills= est= taken_by=<kind>:<amt>,... dealt_by=<wpn>:<amt>,... hp_min= hp_min_mt=
##            core_min= core_min_mt= deaths= death_mt=a;b respawns= respawn_mt= downs= revives= revives_given= down_s=
##            combat_s= quiet_s= longest_combat=
##            (deaths = downs that were not revived: respawns and a down still open at the end; downs = every down;
##            revives = revives received; revives_given = downed crewmates this pilot's drone was beaming when they stood
##            up (seen here through their owner's snapshot); down_s = total s down, redeploy included)
##            longest_combat_mt= longest_quiet= longest_quiet_mt=      once, at the outcome (won / lost) or on leaving (quit)
##            ... then (pacing, PacingStats over the whole mission): eng_s= eng_pct= quiet_max= quiet_max_mt= quiet30=
##            peaks= peak_mt= kint_med= kint_p90= kint_max= in_pm= out_pm= core_min_c= est_eng=
## THREAT AND PACING (docs/design/pacing-director.md 3; summaries per pacing-research.md 8.6):
##   shot     src=<id>/<kind> tgt=<id>/<kind>|- wpn= n= hits= hit=0|1 dist= est=0|1
##            shots per shooter + weapon + target, coalesced over WIN_SHOT s from the first one resolved (mt = first shot).
##            The local pilot's own shots on every machine: tgt = what it hit, `-` for misses (a shot is a miss when no hit
##            named its shot key within its flight time + pad); dist = muzzle to hit point (misses: to the aim point).
##            Exact (this machine decides its own shots). The host also logs ENEMY shots at pilots (tgt = the enemy's
##            target when it fired): hits exact for pilots the host owns; for a client's pilot (the victim decides there)
##            hits=-1 hit=-1 est=1. dist = muzzle to the pilot.
##   threat   i= src=host|local eng=0|1 engaging= near= sees= seen_by= nearest= est=0|1 crew_i= crew_eng=0|1 deck= alive=
##            tot= core= heat= shut=0|1 rays= pilot= bot=0|1      1 Hz for the local pilot, and on the host for each hangar bot
##            (CrewBot: host-owned pilots, negative pilot ids; bot=1, pilot = its id; the local pilot's pilot = the peer).
##            heat / shut: the pilot's MechController gauge (a bot's too, PilotTrack.controller: not its target's gauge).
##            i = intensity (PilotIntensity, 1.2): the host director's value from mission state `intensity` when present (src=host), else computed here (src=local).
##            eng = engaged (an enemy fired at the pilot, or was awake within 60 m with it as target, in the last 4 s);
##            engaging = such enemies; near = live enemies within THREAT_RANGE m; sees = awake ones among the LOS_RAYS
##            nearest the pilot has line of sight to (p>e rays, last second); seen_by = those with the pilot as target
##            and line of sight (host: the AI's own target + LOS result, read; client: replicated AI state in an engaging
##            state, in its sight range, in sight of the pilot: est=1); nearest m (-1 none); crew_i = crew intensity (max
##            over pilots when the host's values are in mission state, else i); crew_eng = any pilot engaged (host: every
##            pilot, client: the local one, est=1); alive = live enemies of this deck; rays = p>e rays in the last second.
##   los      list=<id>:<p>e 1|0|->:<e>p 1|0>,... pilot= bot=      1 Hz detail per pilot, the LOS_RAYS nearest awake enemies within range
##   quiet    from= dur= deck=      a stretch of more than PacingStats.QUIET_LIST s with nobody engaged just ended
##   deck_sum deck= from= dur= eng_s= eng_pct= quiet_max= quiet_max_mt= quiet30=<start>+<dur>;... peaks= peak_mt= kills=
##            kint_med= kint_p90= kint_max= in_pm= out_pm= hp_min= hp_min_mt= core_min= core_min_c= core_min_mt= deaths= est=
##            when the local pilot leaves a deck (DECK_HOLD s on the next) and at the end, for the deck it was on
##   pace     deck= from= to= i= reason=        director state change (note_pace, or mission state `pace` on change)
##   release  wave= deck= src= size= kinds=<kind>:<n>,... reason=      (note_release, host)
##   scout    ev=started|cancelled|completed drone= deck=             (note_scout, host)
##   source   ev=hold|push|reentry|removed|wreck src= unit= kind= why=  a wave door's occupancy (note_source, host)
##   depot    ev=claim|grant|deny|empty depot= left=                  (note_depot, every machine for its own pilot)
##   door     ev=open|shut|win id= at=      the extraction's road doors (note_door, every machine): the exit / entry door
##                                          orders as applied here (at = the shared-clock moment), win = the crew walked out
##   scale    from= to= reason=leave|state pilot= at=<shared clock>    the crew scale changed here (note_scale, every machine,
##                                                                     at the host's `at`; MissionFlow._apply_scale)
## Values never contain spaces ("-" = empty). "In combat" counts the player's own shots (CombatWorld.fired), damage taken
## and damage dealt; enemy shots that miss are not seen by it (the `shot` records see them on the host).
##
## HOOKS (no polling of combat state): PlayerTarget.damaged + player_disabled, CombatWorld.hit_landed / remote_hit /
## fired, and `damaged` of every other target (connected at start, as EnemySquad spawns them, or at their first hit). A
## hit's damage arrives as `damaged` (inside apply_hit) and is paired with the same hit's `hit_landed` (emitted right
## after, synchronously) for its weapon; damage left unpaired by the next step had no hit (fall, wall slam, burn).
## Windows and the summary accumulate numbers only; strings are built only when a line prints.
## Threat: shots pair with hits by shot key (Hit.shot, CombatWorld.hit_landed / remote_hit); enemy fire is CombatWorld.fired
## with record.enemy (the host reads the firing EnemyBase's _target_id). The threat model is CombatThreatProbe (`threat`:
## engagement, line of sight, intensity, bot tracks); this logger prints its records. A SCAN_EVERY s scan of world.targets reads the AI
## (host: _target_id, _is_awake; client: replicated ai_state), notices kills (a live enemy now destroyed) and samples the
## pacing stats. p>e line of sight: at most LOS_RAYS rays per second (the nearest awake enemies within THREAT_RANGE, chosen
## at each threat tick), RAYS_PER_FRAME per physics step, through CombatWorld.shot_ray (the weapons' sight: same query,
## mech capsules excluded), enemy eye to pilot centre with the AI's own 2.6 m slack. No other raycasts.
## Other systems call note_release / note_scout / note_depot / note_pace / note_scale (static, no-ops when no log is running).
## Attached by MissionScene once its MissionFlow exists (attach); off with `--no-combat-log` (or `enabled = false`); never in
## the lab or a district drive (no mission). Starts when the mission is released (solo at once, crew at mission_go).

const WIN_IN := 0.5          ## s: dmg_in coalescing window per source + weapon + component
const WIN_OUT := 1.0         ## s: dmg_out window per target + weapon
const SUMMARY_EVERY := 10.0  ## s of mission time between summaries
const COMBAT_HOLD := 6.0     ## s after the last shot / hit / damage the player counts as in combat
const NEAR_RANGE := 150.0    ## m: enemies counted around the player in the summary
const FLAG := "--no-combat-log"
const WIN_SHOT := 1.0        ## s: shot coalescing window per shooter + weapon + target
const SHOT_PAD := 0.5        ## s past a shot's flight time (range / speed) before it counts as a miss
const SHOT_WAIT_MIN := 0.3   ## s: beams, arcs (no flight)
const SHOT_WAIT_MAX := 12.0
const SCAN_EVERY := 0.25     ## s between AI / kill scans
const EST_AIM_R := 8.0       ## m: a client counts an enemy shot aimed this close to its pilot as fired at it
const DECK_HOLD := 3.0       ## s on another deck before the deck summary closes
const GIVEN_HOLD := 1.5      ## s after this pilot's drone last beamed a downed crewmate its standing up still counts as given

static var enabled := not OS.get_cmdline_user_args().has(FLAG)
static var current: CombatLog = null   ## the running log (note_* calls); null when none

var world: CombatWorld
var pt: PlayerTarget
var mech: MechController
var me := ""                       ## the local player's target / shooter id ("player1")
var sink := Callable()             ## (line: String) -> void instead of print (tests)
var running_fn := Callable()       ## () -> bool: the mission runs (released, not ended); invalid = start() by hand
var deck_fn := Callable()          ## () -> int: the local mech's deck, or invalid
var objective_fn := Callable()     ## () -> String: the current objective id, or invalid
var lines := 0                     ## lines printed
var mt := 0.0                      ## mission time: s of step() since start
var started := false
var ended := false
var _pend_in: Array = []           ## [amount, component, src] damage on the local mech not yet paired with its hit
var _pend_out: Array = []          ## [target, amount] damage by the local player not yet paired with its hit
var _win_in: Array = []            ## [t0, src, wpn, comp, amt, n, heat, t_last]
var _win_out: Array = []           ## [t0, target, tid, wpn, amt, n, est, kill, t_last]
var _hooked: Dictionary = {}       ## target instance id -> true (its `damaged` is connected)
var _kinds: Dictionary = {}        ## src id -> kind
var _ids: Dictionary = {}          ## target id -> CombatTarget (remote hits)
var _next_sum := SUMMARY_EVERY
var _sum_in := 0.0
var _sum_out := 0.0
var _tot_in := 0.0
var _tot_out := 0.0
var _kills := 0
var _est_out := false
var _by_wpn_out: Dictionary = {}
var _by_kind_in: Dictionary = {}
var _hp_min := 100.0
var _hp_min_t := 0.0
var _core_min := 100.0
var _core_min_t := 0.0
var _deaths := PackedFloat64Array()
var _respawns := PackedFloat64Array()
var _down := false
var _down_cause := ""              ## set by player_disabled, printed at the next step (after the killing hit's line)
var help_fn := Callable()          ## () -> {reviver: bool, dist: float}: the call for help (DownedCrew), or invalid
var _downs := 0                    ## every down
var _down_at := -1.0               ## mt of the open down (-1 none)
var _down_s := 0.0                 ## total s down
var _revives := 0                  ## revives received
var _revives_given := 0            ## revives this pilot's drone gave (seen on this machine)
var _given_seen: Dictionary = {}   ## downed crewmate target id -> [PlayerTarget, mt last beamed by this pilot's drone]
var _last_src := ""
var _last_wpn := ""
var _last_act := -INF
var _combat := false
var _cstart := 0.0
var _qstart := 0.0
var _combat_s := 0.0
var _quiet_s := 0.0
var _long_c := 0.0
var _long_c_t := 0.0
var _long_q := 0.0
var _long_q_t := 0.0
var state_fn := Callable()         ## () -> Dictionary: the latest mission state (host: sent, client: received), or invalid
## The threat model (engagement, p>e line of sight, per-pilot intensity, the host's bot tracks; scripts/mission/
## pacing/combat_threat_probe.gd): asked for the `threat` / `los` facts, crew engagement and intensity; its `mt` follows ours.
var threat := CombatThreatProbe.new()
var _shots: Dictionary = {}        ## shot key -> [t_fire, shooter, wpn, tgt ("" own), dist, deadline, est, origin]
var _shot_due := INF               ## earliest deadline in _shots
var _win_shot: Array = []          ## [t0, shooter, wpn, tgt, n, hits, dist_sum, est, open_mt]
var _wait_by_wpn: Dictionary = {}  ## weapon -> s a shot may fly
var _next_threat := CombatThreatProbe.THREAT_EVERY
var _next_scan := 0.0
var _deck := -1
var _deck_cand := -1
var _deck_cand_t := 0.0
var _deck_stats := PacingStats.new()
var _mission_stats := PacingStats.new()
var _pace_prev: Dictionary = {}    ## deck (String) -> director state seen in mission state
var _pace_api := false             ## note_pace was called: mission state `pace` is not diffed


func net_fields() -> Dictionary:
	var f := {}
	for v: String in ["world", "pt", "mech", "me", "sink", "running_fn", "deck_fn", "objective_fn", "lines", "mt", "started",
			"ended", "_pend_in", "_pend_out", "_win_in", "_win_out", "_hooked", "_kinds", "_ids", "_next_sum", "_sum_in",
			"_sum_out", "_tot_in", "_tot_out", "_kills", "_est_out", "_by_wpn_out", "_by_kind_in", "_hp_min", "_hp_min_t",
			"_core_min", "_core_min_t", "_deaths", "_respawns", "_down", "_down_cause", "_last_src", "_last_wpn", "_last_act",
			"_combat", "_cstart", "_qstart", "_combat_s", "_quiet_s", "_long_c", "_long_c_t", "_long_q", "_long_q_t",
			"state_fn", "threat", "_shots", "_shot_due",
			"_win_shot", "_wait_by_wpn", "_next_threat", "_next_scan", "_deck",
			"_deck_cand", "_deck_cand_t", "_deck_stats", "_mission_stats", "_pace_prev", "_pace_api",
			"help_fn", "_downs", "_down_at", "_down_s", "_revives", "_revives_given", "_given_seen"]:
		f[v] = Net.LOCAL
	return f


## The mission drive's log (MissionScene._finish_setup, once MissionFlow exists), or null when off / no mission.
static func attach(td: MissionScene) -> CombatLog:
	if not enabled or td == null or td.mission == null or td.combat == null or td.combat.player_target == null:
		return null
	var cl := CombatLog.new()
	cl.name = "CombatLog"
	td.add_child(cl)
	cl.bind(td.combat.world, td.combat.player_target, td.mech)
	var mf := td.mission
	cl.running_fn = func() -> bool: return is_instance_valid(mf) and mf.released and not mf.ended
	if td.stack != null:
		var st := td.stack
		cl.deck_fn = func() -> int: return int(st.deck_at(td.mech.global_position)) if is_instance_valid(td.mech) else -1
		cl.threat.deck_at_fn = func(at: Vector3) -> int: return int(st.deck_at(at))
	cl.threat.bots_fn = func() -> Dictionary: return td.crew_bots if is_instance_valid(td) else {}   # host only (else empty)
	cl.objective_fn = func() -> String: return mf.rules.current() if is_instance_valid(mf) and mf.rules != null else ""
	cl.state_fn = func() -> Dictionary:   # read only: the host's last sent state, a client's last received one
		if not is_instance_valid(mf):
			return {}
		var s := Net.session()
		if mf.crew and s != null and not mf.deciding():
			return s.mission.state
		return mf.last_sent_state()
	mf.outcome_reached.connect(cl.finish)
	if td.combat.squad != null:
		td.combat.squad.enemy_spawned.connect(cl.hook_target)
	return cl


func bind(w: CombatWorld, p: PlayerTarget, m: MechController = null) -> void:
	world = w
	pt = p
	mech = m
	me = p.target_id
	threat.bind(w, p, m)
	p.damaged.connect(_on_in_damaged)
	p.player_disabled.connect(_on_down)
	p.player_revived.connect(_on_revived)
	p.player_respawned.connect(_on_respawned)
	p.player_component_destroyed.connect(_on_comp_destroyed)
	w.hit_landed.connect(_on_hit_landed)
	w.remote_hit.connect(_on_remote_hit)
	w.fired.connect(_on_fired)
	for t in w.targets:
		hook_target(t)


## Listen to `t`'s damage (to pair the local player's hits on it with the applied amount).
func hook_target(t: Node) -> void:
	if not is_instance_valid(t) or not (t is CombatTarget) or t == pt or _hooked.has(t.get_instance_id()):
		return
	_hooked[t.get_instance_id()] = true
	(t as CombatTarget).damaged.connect(_on_out_damaged.bind(t))


func start() -> void:
	if started or not enabled:
		return
	started = true
	mt = 0.0
	threat.mt = mt
	_qstart = 0.0
	_next_sum = SUMMARY_EVERY
	_next_threat = CombatThreatProbe.THREAT_EVERY
	_next_scan = 0.0
	current = self
	threat.intensity.reset()
	threat.intensity.structure(_tot_pct())
	_deck = int(deck_fn.call()) if deck_fn.is_valid() else -1
	_deck_cand = _deck
	_deck_stats = PacingStats.new()
	_deck_stats.begin(0.0, false)
	_mission_stats = PacingStats.new()
	_mission_stats.begin(0.0, false)


func _physics_process(dt: float) -> void:
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	step(dt)
	if PerfProbe.on:
		PerfProbe.add("main.combat_log", Time.get_ticks_usec() - pp0)


## One step of mission time: pairs leftovers, closes windows, notices a respawn, prints the summary when due.
func step(dt: float) -> void:
	if ended or not enabled:
		return
	if not started:
		if running_fn.is_valid() and bool(running_fn.call()):
			start()
		else:
			return
	if not _pend_in.is_empty():   # (damage without a hit happened at the old mt: folded before the clock moves)
		for e: Array in _pend_in:
			_fold_in(str(e[2]), str(e[2]), str(e[1]), float(e[0]), 0.0)
		_pend_in.clear()
	if not _pend_out.is_empty():
		for e: Array in _pend_out:
			var v: Variant = e[0]
			if is_instance_valid(v):
				var t := v as CombatTarget
				_fold_out(t, t.target_id, "dot", float(e[1]), false, t.destroyed())
		_pend_out.clear()
	mt += dt
	threat.mt = mt
	if _down_cause != "":
		_close_in(true)
		_say("down", "cause=%s src=%s/%s wpn=%s" % [_down_cause, _v(_last_src), _kind_of(_last_src), _v(_last_wpn)])
		_down_cause = ""
		if help_fn.is_valid():
			var h: Variant = help_fn.call()
			if h is Dictionary:
				_say("help", "reviver=%d dist=%.1f" % [1 if bool((h as Dictionary).get("reviver", false)) else 0,
					float((h as Dictionary).get("dist", -1.0))])
	if not _win_in.is_empty():
		_close_in(false)
	if not _win_out.is_empty():
		_close_out(false)
	if _down and pt != null and not pt.disabled:   # back up without a revive / respawn signal (repair_all): a respawn
		_down = false
		_respawns.append(mt)
		var ds := maxf(mt - _down_at, 0.0) if _down_at >= 0.0 else 0.0
		_down_s += ds
		_down_at = -1.0
		_say("respawn", "hold=0 down_s=%.1f tot=%d" % [ds, roundi(_tot_pct())])
	if world != null and (not _given_seen.is_empty() or world.drone_of(me) != null):
		_watch_given()
	_update_combat()
	if mt >= _shot_due or not _win_shot.is_empty():
		_step_shots(false)
	threat.cast_rays()
	if mt >= _next_scan - 1e-6:
		_next_scan = floorf(mt / SCAN_EVERY + 1e-6) * SCAN_EVERY + SCAN_EVERY
		_scan()
	threat.step(dt, pt != null and pt.disabled, _shut())   # downed: never engaged
	if mt >= _next_threat - 1e-6:
		var te := CombatThreatProbe.THREAT_EVERY
		_next_threat = floorf(mt / te + 1e-6) * te + te
		_threat()
	if mt >= _next_sum - 1e-6:
		_next_sum += SUMMARY_EVERY
		_summary()


func _live() -> bool:
	return started and not ended


# --- Hooks ---------------------------------------------------------------------------------------------------

func _on_in_damaged(amount: float, component: String, src: String) -> void:
	if _live():
		_pend_in.append([amount, component, src])


func _on_out_damaged(amount: float, _component: String, src: String, t: CombatTarget) -> void:
	if src != me or not _live():
		return
	if world != null and not world.owns(t):
		return
	_pend_out.append([t, amount])


func _on_hit_landed(t: CombatTarget, h: Hit) -> void:
	if not _live():
		return
	if not _shots.is_empty():
		_shot_hit(h.shot, t.target_id, h.point)
	if t == pt:
		var amt := 0.0
		var comp := h.component
		var i := 0
		while i < _pend_in.size():
			var e: Array = _pend_in[i]
			if str(e[2]) == h.shooter:
				amt += float(e[0])
				comp = str(e[1])
				_pend_in.remove_at(i)
			else:
				i += 1
		if amt > 0.0 or h.heat > 0.0:
			_fold_in(h.shooter, h.weapon, comp, amt, h.heat)
	elif h.shooter == me:
		var amt := 0.0
		var found := false
		var i := 0
		while i < _pend_out.size():
			var e: Array = _pend_out[i]
			if e[0] == t:
				amt += float(e[1])
				found = true
				_pend_out.remove_at(i)
			else:
				i += 1
		var est := false
		if not found:
			if _hooked.has(t.get_instance_id()):
				return   # listened to, and it took nothing (a wreck, a dormant asset)
			hook_target(t)
			amt = h.damage   # its first hit, before we listened: the hit's own amount
			est = true
		if amt > 0.0:
			_fold_out(t, t.target_id, h.weapon, amt, est, t.destroyed())


## A client's hit on a host-owned target: applied on the host, so the amount is this machine's estimate.
func _on_remote_hit(target_id: String, h: Hit) -> void:
	if not _live() or h.shooter != me:
		return
	if not _shots.is_empty():
		_shot_hit(h.shot, target_id, h.point)
	if h.damage <= 0.0:
		return
	var v: Variant = _ids.get(target_id)
	var t: CombatTarget = v as CombatTarget if is_instance_valid(v) else null
	if t == null:
		for c in world.targets:
			if is_instance_valid(c) and c.target_id == target_id:
				t = c
				_ids[target_id] = c
				break
	_fold_out(t, target_id, h.weapon, h.damage, true, false)


func _on_fired(record: Dictionary) -> void:
	if not _live():
		return
	var sh := str(record.get("shooter", ""))
	if sh == me:
		_activity()
		_shot_add(record, sh, "", false)
	elif bool(record.get("enemy", false)) and world != null:
		var e := _target_of(sh)
		if e == null:
			return
		if world.owns(e):
			# Host / solo: the real enemy; its target when it fired is exact.
			var tid: String = (e as EnemyBase).current_target_id() if e is EnemyBase else ""
			var p := _target_of(tid)
			if p is PlayerTarget:
				threat.engage(tid, e)
				_shot_add(record, sh, tid, not world.owns(p))
		else:
			# Client: a replayed enemy shot; aimed close to the local pilot counts as fired at it (estimate).
			var aim: Variant = record.get("target")
			if aim is Vector3 and (aim as Vector3).distance_to(_me_pos()) <= EST_AIM_R:
				threat.engage_est(e)


func _on_down(cause: String) -> void:
	if not _live():
		return
	_down = true
	_down_cause = cause
	_deaths.append(mt)          # a death unless a revive takes it back (_on_revived)
	_downs += 1
	_down_at = mt
	threat.intensity.disabled()
	_deck_stats.deaths += 1
	_mission_stats.deaths += 1


## PlayerTarget.player_revived: stood up in place by a crewmate's drone. Not a death: the down's death is taken back.
func _on_revived(by: String, time_down: float) -> void:
	if not _live() or not _down:
		return
	_down = false
	_down_at = -1.0
	_down_s += time_down
	_revives += 1
	if not _deaths.is_empty():
		_deaths.remove_at(_deaths.size() - 1)
	_deck_stats.deaths = maxi(_deck_stats.deaths - 1, 0)
	_mission_stats.deaths = maxi(_mission_stats.deaths - 1, 0)
	# by=self: its own repair drone stood it up (R2.9 self-revive: still a revive, never one "given" to anyone)
	_say("revive", "by=%s down_s=%.1f tot=%d" % ["self" if by != "" and by == me else _v(by), time_down, roundi(_tot_pct())])


## PlayerTarget.player_respawned: back up after the hold + redeploy (held) or the test hook's instant respawn. A death.
func _on_respawned(time_down: float, held: bool) -> void:
	if not _live() or not _down:
		return
	_down = false
	_down_at = -1.0
	_down_s += time_down
	_respawns.append(mt)
	_say("respawn", "hold=%d down_s=%.1f tot=%d" % [1 if held else 0, time_down, roundi(_tot_pct())])


## Revives given: a downed crewmate this pilot's drone beams is remembered; standing up within GIVEN_HOLD s of the last
## beam (not through a redeploy, which is not revivable) counts one.
func _watch_given() -> void:
	var d := world.drone_of(me)
	if d != null:
		for t: Variant in d.beamed():
			if t is PlayerTarget and t != pt and is_instance_valid(t) and (t as PlayerTarget).revivable():
				_given_seen[(t as PlayerTarget).target_id] = [t, mt]
	for tid: String in _given_seen.keys():
		var e: Array = _given_seen[tid]
		var t: Variant = e[0]
		if not is_instance_valid(t) or mt - float(e[1]) > GIVEN_HOLD or (t as PlayerTarget).redeploying:
			_given_seen.erase(tid)
		elif not (t as PlayerTarget).disabled:
			_revives_given += 1
			_given_seen.erase(tid)


func _on_comp_destroyed(_component: String) -> void:
	if _live():
		threat.intensity.component_destroyed()


## The outcome (MissionFlow.outcome_reached), or "quit" when the scene goes first. Prints the end record once.
func finish(outcome: String, reason: String = "") -> void:
	if not started or ended:
		return
	for e: Array in _pend_in:
		_fold_in(str(e[2]), str(e[2]), str(e[1]), float(e[0]), 0.0)
	_pend_in.clear()
	_close_in(true)
	_close_out(true)
	_step_shots(true)
	_update_combat()
	if _combat:
		_stretch_combat(mt)
	else:
		_stretch_quiet(mt)
	_close_deck()
	var q := _mission_stats.close(mt)
	if q > PacingStats.QUIET_LIST:
		_say("quiet", "from=%.1f dur=%.1f deck=%d" % [mt - q, q, _deck], mt - q)
	ended = true
	if current == self:
		current = null
	var ms := _mission_stats
	var k := ms.kill_intervals()
	_say("end", ("outcome=%s reason=%s in=%.1f out=%.1f kills=%d est=%d taken_by=%s dealt_by=%s hp_min=%d hp_min_mt=%.1f"
		+ " core_min=%d core_min_mt=%.1f deaths=%d death_mt=%s respawns=%d respawn_mt=%s downs=%d revives=%d revives_given=%d"
		+ " down_s=%.1f combat_s=%.1f quiet_s=%.1f"
		+ " longest_combat=%.1f longest_combat_mt=%.1f longest_quiet=%.1f longest_quiet_mt=%.1f"
		+ " eng_s=%.1f eng_pct=%d quiet_max=%.1f quiet_max_mt=%.1f quiet30=%s peaks=%d peak_mt=%s kint_med=%.1f kint_p90=%.1f"
		+ " kint_max=%.1f in_pm=%.1f out_pm=%.1f core_min_c=%s est_eng=%d") % [_v(outcome), _v(reason),
		_tot_in, _tot_out, _kills, 1 if _est_out else 0, _map(_by_kind_in), _map(_by_wpn_out), roundi(_hp_min), _hp_min_t,
		roundi(_core_min), _core_min_t, _deaths.size(), PacingStats.times(_deaths), _respawns.size(), PacingStats.times(_respawns), _downs, _revives,
		_revives_given, _down_s + (maxf(mt - _down_at, 0.0) if _down and _down_at >= 0.0 else 0.0), _combat_s,
		_quiet_s, _long_c, _long_c_t, _long_q, _long_q_t,
		ms.eng_s, roundi(ms.engaged_pct()), ms.q_max, ms.q_max_t, PacingStats._pairs(ms.quiet30), ms.peaks,
		PacingStats.times(ms.peak_t), k[0], k[1], k[2], ms.per_minute(ms.dmg_in), ms.per_minute(ms.dmg_out),
		_v(ms.core_min_c), 1 if threat.eng_est else 0])


func _exit_tree() -> void:
	if started and not ended:
		finish("quit", "left")
	if current == self:
		current = null


# --- Accumulation (numbers only) -----------------------------------------------------------------------------

func _fold_in(src: String, wpn: String, comp: String, amt: float, heat_in: float) -> void:
	var kind := _kind_of(src)
	if kind != "env":
		_activity()   # a hard landing or a wall slam is not a fight
	_last_src = src
	_last_wpn = wpn
	_tot_in += amt
	_sum_in += amt
	_deck_stats.dmg_in += amt
	_mission_stats.dmg_in += amt
	_by_kind_in[kind] = float(_by_kind_in.get(kind, 0.0)) + amt
	_track_hp()
	for w: Array in _win_in:
		if w[1] == src and w[2] == wpn and w[3] == comp:
			w[4] = float(w[4]) + amt
			w[5] = int(w[5]) + 1
			w[6] = float(w[6]) + heat_in
			w[7] = mt
			return
	_win_in.append([mt, src, wpn, comp, amt, 1, heat_in, mt])


func _fold_out(t: CombatTarget, tid: String, wpn: String, amt: float, est: bool, kill: bool) -> void:
	_activity()
	_tot_out += amt
	_sum_out += amt
	_deck_stats.dmg_out += amt
	_mission_stats.dmg_out += amt
	_by_wpn_out[wpn] = float(_by_wpn_out.get(wpn, 0.0)) + amt
	if est:
		_est_out = true
	if kill:
		_kills += 1
	for i in _win_out.size():
		var w: Array = _win_out[i]
		if w[2] == tid and w[3] == wpn:
			w[4] = float(w[4]) + amt
			w[5] = int(w[5]) + 1
			w[6] = bool(w[6]) or est
			w[7] = bool(w[7]) or kill
			w[8] = mt
			if kill:
				_print_out(w)
				_win_out.remove_at(i)
			return
	var nw := [mt, t, tid, wpn, amt, 1, est, kill, mt]
	if kill:
		_print_out(nw)
	else:
		_win_out.append(nw)


func _track_hp() -> void:
	if pt == null:
		return
	var tp := _tot_pct()
	if tp < _hp_min:
		_hp_min = tp
		_hp_min_t = mt
	var cp := _core_pct()
	if cp < _core_min:
		_core_min = cp
		_core_min_t = mt
	threat.intensity.structure(tp)
	var cc := _core_low()
	_deck_stats.structure(mt, tp, cp, cc)
	_mission_stats.structure(mt, tp, cp, cc)


func _activity() -> void:
	_update_combat()
	if not _combat:
		_stretch_quiet(mt)
		_combat = true
		_cstart = mt
	_last_act = mt


## Combat ends COMBAT_HOLD s after the last activity; the quiet stretch starts there.
func _update_combat() -> void:
	if _combat and mt - _last_act >= COMBAT_HOLD:
		var e := _last_act + COMBAT_HOLD
		_stretch_combat(e)
		_combat = false
		_qstart = e


func _stretch_combat(until: float) -> void:
	var d := maxf(until - _cstart, 0.0)
	_combat_s += d
	if d > _long_c:
		_long_c = d
		_long_c_t = _cstart


func _stretch_quiet(until: float) -> void:
	var d := maxf(until - _qstart, 0.0)
	_quiet_s += d
	if d > _long_q:
		_long_q = d
		_long_q_t = _qstart


func _tot_pct() -> float:
	if pt == null:
		return 100.0
	return 100.0 * pt.total_hp() / maxf(pt.total_max_hp(), 0.001)


func _core_pct() -> float:
	if pt == null:
		return 100.0
	var lo := 1.0
	for c: String in PlayerTarget.CORE_COMPONENTS:
		if pt.max_hp.has(c):
			lo = minf(lo, float(pt.hp.get(c, 0.0)) / maxf(float(pt.max_hp[c]), 0.001))
	return 100.0 * lo


## The weakest core component's name ("" without a pilot).
func _core_low() -> String:
	if pt == null:
		return ""
	var lo := INF
	var which := ""
	for c: String in PlayerTarget.CORE_COMPONENTS:
		if pt.max_hp.has(c):
			var f := float(pt.hp.get(c, 0.0)) / maxf(float(pt.max_hp[c]), 0.001)
			if f < lo:
				lo = f
				which = c
	return which


# --- Shots ---------------------------------------------------------------------------------------------------

## A shot to resolve: `tgt` "" = the local pilot's own (its target is what it hits), else the pilot an enemy fired at.
func _shot_add(record: Dictionary, sh: String, tgt: String, est: bool) -> void:
	if not record.has("hardpoint") or not record.has("shot_index"):
		return
	var wpn := str(record.get("weapon", ""))
	var o: Vector3 = record.get("origin", Vector3.ZERO)
	var dist := 0.0
	if tgt != "":
		dist = o.distance_to(_pos(_target_of(tgt)))
	else:
		var aim: Variant = record.get("target")
		dist = o.distance_to(aim as Vector3) if aim is Vector3 else 0.0
	var due := mt + _shot_wait(wpn)
	_shots[Combat.shot_key(record)] = [mt, sh, wpn, tgt, dist, due, est, o]
	_shot_due = minf(_shot_due, due)


func _shot_wait(wpn: String) -> float:
	var v: Variant = _wait_by_wpn.get(wpn)
	if v != null:
		return float(v)
	var st := world.stats(wpn) if world != null else {}
	var sp := float(st.get("speed", 0.0))
	var w := SHOT_WAIT_MIN if sp <= 0.0 else clampf(float(st.get("range", 200.0)) / sp + SHOT_PAD, SHOT_WAIT_MIN, SHOT_WAIT_MAX)
	_wait_by_wpn[wpn] = w
	return w


func _shot_hit(key: String, tid: String, point: Vector3) -> void:
	var v: Variant = _shots.get(key)
	if v == null:
		return
	var a: Array = v
	var tgt := str(a[3])
	if tid == str(a[1]) or (tgt != "" and tid != tgt):
		return   # an enemy shot counts only on the pilot it was fired at
	_shots.erase(key)
	_fold_shot(a, tid, true, (a[7] as Vector3).distance_to(point))


func _step_shots(force: bool) -> void:
	if force or mt >= _shot_due:
		_shot_due = INF
		if not _shots.is_empty():
			for k: String in _shots.keys():
				var a: Array = _shots[k]
				if force or float(a[5]) <= mt + 1e-6:
					_shots.erase(k)
					_fold_shot(a, "", false, float(a[4]))
				else:
					_shot_due = minf(_shot_due, float(a[5]))
	var i := 0
	while i < _win_shot.size():
		var w: Array = _win_shot[i]
		if force or mt - float(w[8]) >= WIN_SHOT - 1e-6:
			var est := bool(w[7])
			var tgt := str(w[3])
			_say("shot", "src=%s/%s tgt=%s wpn=%s n=%d hits=%d hit=%d dist=%.1f est=%d" % [_v(str(w[1])), _kind_of(str(w[1])),
				("%s/%s" % [tgt, _kind_of(tgt)]) if tgt != "" else "-", _v(str(w[2])), int(w[4]), -1 if est else int(w[5]),
				-1 if est else (1 if int(w[5]) > 0 else 0), float(w[6]) / maxf(float(w[4]), 1.0), 1 if est else 0], float(w[0]))
			_win_shot.remove_at(i)
		else:
			i += 1


func _fold_shot(a: Array, hit_tid: String, hit: bool, dist: float) -> void:
	var sh := str(a[1])
	var wpn := str(a[2])
	var tgt := str(a[3]) if str(a[3]) != "" else hit_tid
	for w: Array in _win_shot:
		if w[1] == sh and w[2] == wpn and w[3] == tgt:
			w[0] = minf(float(w[0]), float(a[0]))
			w[4] = int(w[4]) + 1
			w[5] = int(w[5]) + (1 if hit else 0)
			w[6] = float(w[6]) + dist
			return
	_win_shot.append([float(a[0]), sh, wpn, tgt, 1, 1 if hit else 0, dist, bool(a[6]), mt])


# --- Threat (the model is CombatThreatProbe; the records are printed here) -----------------------------------

## SCAN_EVERY s: the probe's AI / kill scan (kills into the pacing stats, new enemies hooked), the director state in
## mission state, the pacing stats' sample.
func _scan() -> void:
	if world == null:
		return
	var r := threat.scan()
	for i in int(r["kills"]):
		_deck_stats.kill(mt)
		_mission_stats.kill(mt)
	for t: Variant in r["fresh"]:
		hook_target(t)
	_read_state()
	var crew := threat.crew_engaged()
	_deck_stats.sample(mt, crew, threat.crew_i)
	var q := _mission_stats.sample(mt, crew, threat.crew_i)
	if q > PacingStats.QUIET_LIST:
		_say("quiet", "from=%.1f dur=%.1f deck=%d" % [mt - q, q, _deck], mt - q)


## Intensity and director state from mission state (the host director's), when present.
func _read_state() -> void:
	var st: Dictionary = state_fn.call() if state_fn.is_valid() else {}
	var iv: Variant = _state_key(st, "intensity")
	var d: Dictionary = iv if iv is Dictionary else {}
	threat.read_intensity(d)
	if _pace_api:
		return
	var pv: Variant = _state_key(st, "pace")
	if pv is Dictionary:
		for k: Variant in pv:
			var row: Variant = (pv as Dictionary)[k]
			var s := str((row as Array)[0]) if row is Array and not (row as Array).is_empty() else str(row)
			var prev := str(_pace_prev.get(str(k), ""))
			if s != prev:
				_pace_prev[str(k)] = s
				var why := str((row as Array)[3]) if row is Array and (row as Array).size() > 3 else ""
				_say("pace", "deck=%s from=%s to=%s i=%d reason=%s" % [_v(str(k)), _v(prev), _v(s), roundi(threat.crew_i), _v(why)])


static func _state_key(st: Dictionary, k: String) -> Variant:
	if st.has(k):
		return st[k]
	var d: Variant = st.get("dir")
	if d is Dictionary and (d as Dictionary).has(k):
		return (d as Dictionary)[k]
	return null


## THREAT_EVERY s: the deck, then per pilot track the threat (and los) record (CombatThreatProbe.tick: its facts, and its
## next second's p>e rays).
func _threat() -> void:
	_check_deck()
	threat.sync_bots()
	threat.intensity.structure(_tot_pct())   # repairs move the baseline
	if world == null:
		return
	for f: Dictionary in threat.tick(_deck):
		var tr := f["track"] as PilotTrack
		var bot := bool(f["bot"])
		var heat := _heat() if not bot else tr.heat_frac()   # a bot's heat lives on its MechController (PilotTrack)
		var shut := _shut() if not bot else tr.shutdown()
		var pilot := int(f["pilot"])
		_say("threat", ("i=%d src=%s eng=%d engaging=%d near=%d sees=%d seen_by=%d nearest=%.1f est=%d crew_i=%d crew_eng=%d"
			+ " deck=%d alive=%d tot=%d core=%d heat=%.2f shut=%d rays=%d pilot=%d bot=%d") % [roundi(float(f["i"])), str(f["src"]),
			1 if bool(f["eng"]) else 0, int(f["engaging"]), int(f["near"]), int(f["sees"]), int(f["seen_by"]), float(f["nearest"]),
			1 if bool(f["est"]) else 0, roundi(float(f["crew_i"])), 1 if bool(f["crew_eng"]) else 0, int(f["deck"]),
			int(f["alive"]), roundi(float(f["tot"])), roundi(float(f["core"])), heat, 1 if shut else 0, int(f["rays"]), pilot,
			1 if bot else 0])
		var los: Array = f["los"]
		if not los.is_empty():
			var parts := PackedStringArray()
			for l: Array in los:
				var pe := int(l[1])
				parts.append("%s:%s:%d" % [_v(str(l[0])), "-" if pe < 0 else str(pe), int(l[2])])
			_say("los", "list=%s pilot=%d bot=%d" % [",".join(parts), pilot, 1 if bot else 0])


func _me_pos() -> Vector3:
	return _pos(mech) if mech != null and is_instance_valid(mech) else _pos(pt)


func _target_of(tid: String) -> CombatTarget:
	if tid == "" or world == null:
		return null
	var v: Variant = _ids.get(tid)
	if is_instance_valid(v):
		return v as CombatTarget
	for c in world.targets:
		if is_instance_valid(c) and c.target_id == tid:
			_ids[tid] = c
			return c
	return null


## The local pilot's deck: a change holds DECK_HOLD s before the deck summary closes.
func _check_deck() -> void:
	if not deck_fn.is_valid():
		return
	var d := int(deck_fn.call())
	if d < 0 or d == _deck:
		_deck_cand = _deck
		return
	if d != _deck_cand:
		_deck_cand = d
		_deck_cand_t = mt
		return
	if mt - _deck_cand_t >= DECK_HOLD - 1e-6:
		_close_deck()
		_deck = d
		_deck_stats = PacingStats.new()
		_deck_stats.begin(mt, threat.crew_engaged(), threat.crew_i)
		_deck_stats.structure(mt, _tot_pct(), _core_pct(), _core_low())   # the deck starts from the damage carried in


func _close_deck() -> void:
	if _deck_stats.closed:
		return
	_deck_stats.close(mt)
	_say("deck_sum", "deck=%d from=%.1f %s" % [_deck, _deck_stats.t0, _deck_stats.body(threat.eng_est)])


# --- Notes from other systems (static; no-ops when no log runs) ----------------------------------------------

static func _running() -> CombatLog:
	var c := current
	return c if c != null and is_instance_valid(c) and c._live() else null


## The pacing director released a group (host).
static func note_release(wave: String, deck: int, source: String, size: int, kinds: Variant = null, reason: String = "") -> void:
	var c := _running()
	if c != null:
		c._say("release", "wave=%s deck=%d src=%s size=%d kinds=%s reason=%s" % [_v(wave), deck, _v(source), size,
			_kinds_str(kinds), _v(reason)])


## A scout's call: started / cancelled / completed (host).
static func note_scout(event: String, drone_id: String, deck: int = -1) -> void:
	var c := _running()
	if c != null:
		c._say("scout", "ev=%s drone=%s deck=%d" % [_v(event), _v(drone_id), deck])


## A wave door's occupancy event (host, MissionBays): hold / push / reentry / removed (counted gone, no kill) / wreck.
static func note_source(event: String, source: String, unit_id: String = "", kind: String = "", why: String = "") -> void:
	var c := _running()
	if c != null:
		c._say("source", "ev=%s src=%s unit=%s kind=%s why=%s" % [_v(event), _v(source), _v(unit_id), _v(kind), _v(why)])


## A road door order applied on this machine (open / shut: the exit or entry door, MissionFlow) or the walk-out win (win).
static func note_door(event: String, door_id: String, at: float) -> void:
	var c := _running()
	if c != null:
		c._say("door", "ev=%s id=%s at=%.3f" % [_v(event), _v(door_id), at])


## A depot event for this machine's pilot: claim / grant / deny / empty.
static func note_depot(event: String, depot_id: String, cores_left: int = -1) -> void:
	var c := _running()
	if c != null:
		c._say("depot", "ev=%s depot=%s left=%d" % [_v(event), _v(depot_id), cores_left])


## A director state change (host). Once called, mission state `pace` is no longer diffed (no double lines).
static func note_pace(deck: int, from: String, to: String, crew_i: float, reason: String = "") -> void:
	var c := _running()
	if c != null:
		c._pace_api = true
		c._say("pace", "deck=%d from=%s to=%s i=%d reason=%s" % [deck, _v(from), _v(to), roundi(crew_i), _v(reason)])


## The crew scale changed on this machine (MissionFlow._apply_scale, every machine at the host's `at`): from -> to, why
## (leave: a pilot left; state: learned from mission.state), the pilot who left (0 none), the shared-clock `at`.
static func note_scale(from: int, to: int, reason: String, pilot: int, at: float) -> void:
	var c := _running()
	if c != null:
		c._say("scale", "from=%d to=%d reason=%s pilot=%d at=%.3f" % [from, to, _v(reason), pilot, at])


## The host's (solo's) debrief at the outcome (MissionStats.finish, once): `debrief outcome= time= pilots=<id>,...` then
## one `<id>=<key>:<value>,...` per pilot (a leaver's id marked `<id>L`). Printed through the running log, else as a plain
## FlowLog line (the log is off, or already ended): the debrief line is never lost to --no-combat-log.
static func note_debrief(d: Dictionary) -> void:
	var ids := PackedStringArray()
	var rows := PackedStringArray()
	var stats: Dictionary = d.get("stats", {})
	for p: Dictionary in d.get("pilots", []):
		var id := str(int(p["id"])) + ("L" if bool(p.get("left", false)) else "")
		ids.append(id)
		var kv := PackedStringArray()
		var row: Dictionary = stats.get(str(int(p["id"])), {})
		for k: String in row:
			kv.append("%s:%s" % [k, str(row[k])])
		rows.append("%s=%s" % [id, ",".join(kv) if not kv.is_empty() else "-"])
	var body := "outcome=%s time=%.1f pilots=%s %s" % [_v(str(d.get("outcome", ""))), float(d.get("time", 0.0)),
		_v(",".join(ids)), " ".join(rows)]
	var c := current
	if c != null and is_instance_valid(c) and c.started:
		c._say("debrief", body)
	else:
		FlowLog.say("debrief", body)


## "tank:2,drone:1" from an Array of kinds (counted, first-seen order), a Dictionary kind -> n, or a String.
static func _kinds_str(kinds: Variant) -> String:
	if kinds is Dictionary:
		var parts := PackedStringArray()
		for k: Variant in kinds:
			parts.append("%s:%d" % [_v(str(k)), int((kinds as Dictionary)[k])])
		return _v(",".join(parts))
	if kinds is Array or kinds is PackedStringArray:
		var counts := {}
		for k: Variant in kinds:
			counts[str(k)] = int(counts.get(str(k), 0)) + 1
		return _kinds_str(counts)
	return _v(str(kinds)) if kinds != null else "-"


# --- Lines (strings built only here) ---------------------------------------------------------------------------

func _close_in(force: bool) -> void:
	var i := 0
	while i < _win_in.size():
		var w: Array = _win_in[i]
		if force or mt - float(w[0]) >= WIN_IN - 1e-6:
			_say("dmg_in", "src=%s/%s wpn=%s comp=%s amt=%.1f n=%d dur=%.2f hp=%s tot=%d core=%d heat=%.2f shut=%d heat_in=%.1f" % [
				_v(str(w[1])), _kind_of(str(w[1])), _v(str(w[2])), _v(str(w[3])), float(w[4]), int(w[5]),
				float(w[7]) - float(w[0]), _hp_list(), roundi(_tot_pct()), roundi(_core_pct()), _heat(), 1 if _shut() else 0,
				float(w[6])], float(w[0]))
			_win_in.remove_at(i)
		else:
			i += 1


func _close_out(force: bool) -> void:
	var i := 0
	while i < _win_out.size():
		var w: Array = _win_out[i]
		if force or mt - float(w[0]) >= WIN_OUT - 1e-6:
			_print_out(w)
			_win_out.remove_at(i)
		else:
			i += 1


func _print_out(w: Array) -> void:
	var t: CombatTarget = (w[1] as CombatTarget) if is_instance_valid(w[1]) else null
	_say("dmg_out", "tgt=%s/%s wpn=%s amt=%.1f n=%d dur=%.2f thp=%d kill=%d est=%d" % [_v(str(w[2])), _kind_t(t),
		_v(str(w[3])), float(w[4]), int(w[5]), float(w[8]) - float(w[0]), roundi(_target_pct(t)), 1 if bool(w[7]) else 0,
		1 if bool(w[6]) else 0], float(w[0]))


func _summary() -> void:
	var near := 0
	var nearest := -1.0
	var at := _pos(pt) if mech == null or not is_instance_valid(mech) else _pos(mech)
	if world != null:
		for t in world.targets:
			if not is_instance_valid(t) or t.team != "enemy" or not t.is_hittable() or t.destroyed() or t is AssetTarget \
					or t is BannerTarget:
				continue
			var d := _pos(t).distance_to(at)
			if d <= NEAR_RANGE:
				near += 1
				if nearest < 0.0 or d < nearest:
					nearest = d
	var comps := PackedStringArray()
	if pt != null:
		for c: String in pt.max_hp:
			comps.append("%s:%d" % [c, roundi(100.0 * float(pt.hp.get(c, 0.0)) / maxf(float(pt.max_hp[c]), 0.001))])
	var deck := int(deck_fn.call()) if deck_fn.is_valid() else -1
	var obj := str(objective_fn.call()) if objective_fn.is_valid() else ""
	_say("summary", "hp=%d core=%d comp=%s heat=%.2f shut=%d in=%.1f out=%.1f near=%d nearest=%.1f combat=%d deck=%d obj=%s down=%d" % [
		roundi(_tot_pct()), roundi(_core_pct()), _v(",".join(comps)), _heat(), 1 if _shut() else 0, _sum_in, _sum_out, near,
		nearest, 1 if _combat else 0, deck, _v(obj), 1 if pt != null and pt.disabled else 0])
	_sum_in = 0.0
	_sum_out = 0.0


## One line: `[Flow] t=<FlowLog's clock> <tag> mt=<mission s> peer=<id> <body>`.
func _say(tag: String, body: String, at_mt: float = NAN) -> void:
	var s := Net.session()
	var online := s != null and s.online()
	var t := s.host_time() if online else Time.get_ticks_msec() / 1000.0
	var line := "[Flow] t=%.3f %s mt=%.1f peer=%d %s" % [t, tag, mt if is_nan(at_mt) else at_mt,
		s.local_id() if s != null else 0, body]
	lines += 1
	if sink.is_valid():
		sink.call(line)
	else:
		print(line)


func _hp_list() -> String:
	if pt == null:
		return "-"
	var parts := PackedStringArray()
	for c: String in pt.max_hp:
		parts.append("%s:%d/%d" % [c, roundi(float(pt.hp.get(c, 0.0))), roundi(float(pt.max_hp[c]))])
	return ",".join(parts)


func _heat() -> float:
	if mech != null and is_instance_valid(mech):
		return mech.heat / maxf(mech.heat_cap, 0.001)
	return pt.heat.fraction() if pt != null else 0.0


func _shut() -> bool:
	if mech != null and is_instance_valid(mech):
		return mech.shutdown
	return pt != null and pt.heat.shutdown


func _kind_of(src: String) -> String:
	if src == "fall" or src == "wall":
		return "env"
	if src == "":
		return "-"
	var k: Variant = _kinds.get(src)
	if k != null:
		return str(k)
	var kind := "?"
	if world != null:
		for t in world.targets:
			if is_instance_valid(t) and t.target_id == src:
				kind = _kind_t(t)
				break
	_kinds[src] = kind
	return kind


static func _kind_t(t: CombatTarget) -> String:
	if t == null:
		return "?"
	if t is AssetTarget:
		return "asset"
	if t is BannerTarget:
		return "banner"
	if t is PlayerTarget:
		return "player"
	if "enemy_type" in t:
		return _v(str(t.get("enemy_type")))
	return "target"


static func _target_pct(t: CombatTarget) -> float:
	if t == null:
		return -1.0
	if t is AssetTarget:
		var a := t as AssetTarget
		return 100.0 * a.hp_fraction() if a.hp_value >= 0.0 else -1.0
	return 100.0 * t.total_hp() / maxf(t.total_max_hp(), 0.001)


static func _pos(n: Node3D) -> Vector3:
	if n == null or not is_instance_valid(n):
		return Vector3.ZERO
	return n.global_position if n.is_inside_tree() else n.position


static func _v(s: String) -> String:
	return "-" if s == "" else s.replace(" ", "_")


static func _map(d: Dictionary) -> String:
	if d.is_empty():
		return "-"
	var parts := PackedStringArray()
	for k: Variant in d:
		parts.append("%s:%.1f" % [_v(str(k)), float(d[k])])
	return ",".join(parts)
