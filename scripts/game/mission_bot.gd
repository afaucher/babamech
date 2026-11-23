class_name MissionBot
extends Node
## `--bot [profile]`: the AI plays the local mech through the whole mission (LAN verification, soak runs). Input only,
## like a player: it never moves a mech or an enemy itself (except the DEV travel jump below).
##   FIGHTING is antigravity's TestDriveBotPilot / PlayerBot (sense, aim, fire, dodge, cover), rebound to the deck the
##   mech is on (that deck's CityPlan and deck_ring).
##   GOING somewhere is this layer. The mission's current objective (MissionRules.current(), the host's on a client)
##   picks a deck and a point: "clear_k", a COMMITTED live enemy of deck k (kept TARGET_HOLD s at least, swapped only for
##   one much nearer, or for the one PlayerBot is shooting); "extract", the extraction marker on the lowest deck.
##   PLAN MODE (objectives on, MissionRules.plan): per deck in order its primary, its KNOWN bonuses (MissionBot.bonuses),
##   then on the extraction deck the hold (_task). sweep = the clear above (waits at the deck's arrival for its waves);
##   flag / defend / hold = walk to the zone (the rules' snapped site / the hold Rect2) and HOLD it (_zone_hold:
##   PlayerBot aims and fires, its legs only near the centre), leaving to hunt what stalls it (a flag contested HUNT_AFTER
##   s, a defend's wave units hanging back). Co-op: the standing crew by peer id, the first anchors the zone, the others
##   escort (off-centre, hunt at once); friendly fire guard (_ff_guard). docs/design/player-ai.md §9.
##   BotRoutePlanner (scripts/game/bot_route_planner.gd) routes there over the decks: road lines on each deck, down a
##   ramp along its lane centre, or into an open-air shaft and down (a glide on the thrusters over a stacked atrium);
##   lifts don't move yet and are never used. The route is a list of legs followed by pure pursuit (LOOK m ahead on the
##   polyline), with whisker avoidance on roads only, stuck recovery (back up, hop, then block that edge and re-plan) and
##   a veto that keeps the legs off floor cuts (shafts, ramp holes) except on the leg that means to drop.
##   FIGHT vs TRAVEL has hysteresis: fight when on the target's deck within ENGAGE m, back to travel only past ENGAGE_OUT
##   m; while fighting, PlayerBot's legs are used when it engages / dodges / takes cover (with the cut veto), and this
##   layer walks toward the target when PlayerBot has no line of sight (its own coarse navigation slid along walls),
##   moving to a vantage node with a clear line after VANTAGE_AFTER s without a kill.
## Every deck change logs "[Flow] bot deck change: deck a -> b by ramp | shaft | glide | unplanned | respawn".
## Started by TestDrive once the scene is set up (attach); every other [Flow] transition is still logged by TestDrive.
##
## DEV ONLY, `--dev-bot-travel` (dev_travel): a FALLBACK when the walk can't get there: no route to the target deck,
## DEV_STALL s without 5 m of progress along the route, or DEV_FIGHT_STALL s fighting without a kill. The bot then JUMPS:
## it sets its own mech's transform to an arrival point on the floor of the target deck (the entry spawn's arc spot on that
## deck, near the target enemy, or the extraction marker), found with a ray down (dev_jump). The snapshot stream sees the
## jump (NetMechStream bumps the teleport counter past TELEPORT_DIST), so puppets snap. Objectives, kills, the outcome and
## the end flow all still happen for real. Each jump logs "[Flow] dev travel: deck a -> b"; `dev_jumps` counts them.

const ENGAGE := 85.0          ## m: closer than this to the target enemy (same deck), fight
const ENGAGE_OUT := 125.0     ## m: fighting, travel again only past this (hysteresis)
const ARRIVE := 4.0           ## m: the end of a walk leg counts as reached
const LOOK := 9.0             ## m: pure-pursuit look-ahead on the route polyline
const REPLAN_EVERY := 3.0     ## s between checks whether the goal moved enough to re-plan
const REPLAN_MOVE := 20.0     ## m the goal must have moved since the plan
const TARGET_HOLD := 8.0      ## s a chosen target is kept at least (unless it dies)
const TARGET_SWAP := 0.6      ## a held target is swapped only for one nearer than this share of its distance...
const TARGET_SWAP_MIN := 25.0 ## ...and at least this many m nearer
const FIGHT_CLOSE := 24.0     ## m: walking toward the target without line of sight, stop this close
const VANTAGE_AFTER := 6.0    ## s fighting without a kill (and 4 s without line of sight) before moving to a vantage
const VANTAGE_HOLD := 4.0     ## s standing at a vantage without line of sight before the next one
const VANTAGE_STEP := 12.0    ## m between vantage candidates along a road
const VANTAGE_RANGE := 170.0  ## m: farthest vantage from the target (PlayerBot sees 175 m)
const VETO_AHEAD := 7.0       ## m ahead the cut veto looks
const VETO_GROW := 3.0        ## m around a floor cut the legs keep out of (fight and walk legs)
const STUCK_WIN := 1.5        ## s between progress checks
const STUCK_MIN := 1.2        ## m of progress expected per check
const BACKUP_T := 0.9         ## s backing up after a stuck check
const BLOCK_AFTER := 4        ## stuck checks on one leg before its nearest edge is blocked and the route re-planned
const GLIDE_HEAT := 0.4       ## heat share above which a glide waits (cools) at its run-in point
const GLIDE_CEIL := 28.0      ## m above the lower floor: below this the glide holds height (clear of the slab above)
const STATUS_EVERY := 10.0    ## s between "[Bot]" status lines
const ROOF_H := 3.0           ## m above the deck floor inside a block: on a roof
const ROOF_OUT := 8.0         ## m past the block's side a roof escape heads for
const PERCH_MIN_H := 6.0      ## m: a target this high above its deck may need a roof to be seen from
const PERCH_HOLD := 6.0       ## s on a perch without line of sight before giving it up
const PERCH_GIVE_UP := 45.0   ## s to reach a perch at most
const DEV_STALL := 25.0       ## DEV --dev-bot-travel: s without 5 m of progress along the route before a jump
const DEV_FIGHT_STALL := 30.0 ## DEV: s fighting without a kill before a jump near the target
const DEV_NEAR := 20.0        ## DEV: m from the target enemy a fight jump lands (each jump from another side)

const ZONE_IN := 0.55          ## plan mode: closer than this share of a zone's radius, hold there...
const ZONE_OUT := 0.85         ## ...and travel again only past this share (hysteresis)
const HOLD_DRIFT := 0.4        ## holding: walk back toward the stand point past this share
const LOCAL_R := 60.0          ## m from a zone: the last stretch is planned on a physics grid (_plan_local)
const LOCAL_HALF := 66.0       ## m: half the side of that grid (around the zone's centre)
const LOCAL_STEP := 3.0        ## m between its points
const LOCAL_SIDE := 2.4        ## m either side of a grid edge its side rays run (the mech's capsule is ~2.2 m in radius)
const STAND_IN := 0.45         ## share of the zone's radius a stand point may lie from the centre
const DEFEND_HOLD_R := 20.0    ## m: a defend is held this close to its relay (its activation radius is 30)
const HUNT_AFTER := 12.0       ## s holding with no progress (flag) / no engagement (defend) before hunting
const HUNT_RANGE := 70.0       ## m from the site: enemies this close count for a hunt
const HUNT_GIVE_UP := 40.0     ## s a hunt is kept at most before going back to the zone
const BONUS_GIVE_UP := 240.0   ## s on one bonus before it is skipped
const ESCORT_OFF := 0.4        ## co-op: an escort holds this share of the radius off the centre
const FF_CLEAR := 4.0          ## m: a teammate this close to the line of fire holds the trigger...
const FF_SPLASH := 8.0         ## m: ...or this close to the aim point
const ADVANCE_WAIT := 1.5      ## s with nothing left on a deck before moving on (a chained bonus shows up a tick late)

## Tests: plan with ramps only (no shaft drops or glides), to exercise the ramp legs.
static var ramps_only := false
## Plan mode: do the known bonus objectives of a deck after its primary (tests may turn this off for speed).
static var bonuses := true

var drive: TestDrive
var pilot: TestDriveBotPilot
var planner: BotRoutePlanner
var mode := ""                ## "fight" | "travel" | "idle"
var goal_text := ""           ## what it is doing (logs, tests)
var _nav: BotNavigator        ## whisker avoidance only
var _navs: Array = []         ## per deck: BotNavigator on that deck's plan (its roofs, the thruster climb)
var _perch: Dictionary = {}   ## fighting: the roof being climbed to see the target (BotNavigator roof entry)
var _perch_t := 0.0           ## s since the perch was chosen
var _perch_hold := 0.0        ## s standing on it
var _vantage_kind := ""       ## "sight" (a road point that sees the target) | "patrol" (none does: walk round it)
var _rng := RandomNumberGenerator.new()
var _deck := -1               ## the deck PlayerBot is bound to
var _legs: Array = []         ## BotRoutePlanner legs left
var _leg_i := 0
var _seg_i := 0               ## the polyline segment of the current leg the mech is on
var _route_key := ""          ## what the route was planned for
var _route_goal := Vector3.INF
var _route_t := 0.0           ## s since the route's goal was checked
var _target: Variant = null   ## the committed enemy (clear objectives): an EnemyBase, untyped (it may be freed; _live_on)
var _target_t := 0.0          ## s it has been held
var _mode_t := 0.0            ## s in the current mode
var _said := ""
var _status_t := 0.0
var _last_pos := Vector3.INF
var _stk_t := 0.0             ## s since the last progress check
var _stk_rem := INF           ## remaining leg length at the last check
var _stk_n := 0               ## stuck checks on this leg
var _stk_pos := Vector3.INF   ## where the mech was at the last progress check
var _backup_t := 0.0          ## s of backing up left
var _backup_dir := Vector3.ZERO
var _hop_t := 0.0             ## s of hop thrust left
var _fight_t := 0.0           ## s fighting since the last kill on the target deck
var _no_los_t := 0.0          ## s fighting without PlayerBot engaging
var _alive_prev := -1
var _vantage := Vector3.INF   ## fighting: the vantage point being walked to
var _tried: Array = []        ## vantage nodes tried this fight
var _vantage_cd := 0.0        ## s before another vantage search (after one found none)
var _at_vantage_t := 0.0      ## s standing at the vantage
var _roof_t := 0.0            ## s into a roof escape (0: not escaping)
var _roof_anchor := Vector3.ZERO
var _roof_tries := 0          ## roof escape: failed checks (each turns to the next-nearest side)
var _roof_log_t := -99.0      ## t of the last "off the roof" line (contact flicker restarts the escape)
var _roof_out := Vector2.INF   ## roof escape: where it heads (arc m)
var _roof_span := 0.0         ## s into the current roof escape
var roof_max := 0.0           ## the longest roof escape so far (s; tests)
var stall_max := 0.0          ## the longest span pushing without getting 2 m anywhere (s; tests)
var _stall_t := 0.0
var _stall_anchor := Vector3.ZERO
var last_dir := Vector3.ZERO  ## the last travel direction (status line)
var t := 0.0                  ## s since the bot started
var deck_changes: Array = []  ## [{t, from, to, by}] (tests, report)
var stuck_events := 0
var blocked_edges := 0
var replans := 0
var dev_travel := false       ## DEV ONLY: --dev-bot-travel (see the header)
var dev_jumps := 0            ## DEV: jumps made (tests)
var _prog_key := ""           ## DEV: what the progress clock measures
var _prog_best := INF         ## DEV: the least route left so far
var _prog_t := 0.0            ## DEV: s since it last got 5 m closer (or killed something, fighting)
var _prog_alive := -1         ## DEV: live enemies on the target deck when the fight clock started
var _last_dev_jump_t := -1.0  ## DEV: t of the last jump (a deck change right after it is "dev travel")
var work_deck := 0            ## plan mode: the deck whose objectives it is doing (only moves on, never back)
var task_id := ""             ## plan mode: the objective it is doing now
var role := "solo"            ## plan mode: "solo" | "anchor" (holds the zone) | "escort" (clears threats near it)
var task_log: Array = []      ## plan mode: [{t, id, type}] each task as it started (tests, report)
var ff_holds := 0             ## frames the trigger was held because a teammate stood in the line of fire
var _task_t := 0.0            ## s on the current task
var _skipped: Dictionary = {} ## bonus ids given up on (BONUS_GIVE_UP)
var _hunt: Variant = null     ## plan mode: the enemy hunted away from the zone (untyped: may be freed)
var _hunt_t := 0.0            ## s into the hunt
var _quiet_t := 0.0           ## s holding without PlayerBot engaging
var _stuck_prog_t := 0.0      ## s holding a flag without its progress rising
var _prog_last := -1.0
var _holding := false         ## inside the zone hysteresis
var role_index := 0           ## plan mode: this mech's place among the standing crew, by peer id
var _advance_t := 0.0         ## plan mode: s with nothing left on work_deck (moves on after ADVANCE_WAIT)
var _stand_key := ""          ## plan mode: the goal key + role the stand point was found for
var _stand_pt := Vector3.INF  ## plan mode: a street-level point inside the zone the mech can walk to (_plan_local)
var local_plans := 0          ## physics-grid plans made (tests)
var local_fails := 0          ## ...of which found no stand point it could walk to


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "pilot": Net.LOCAL, "planner": Net.LOCAL, "mode": Net.PRIVATE, "goal_text": Net.PRIVATE,
		"_nav": Net.PRIVATE, "_navs": Net.PRIVATE, "_perch": Net.PRIVATE, "_perch_t": Net.PRIVATE, "_perch_hold": Net.PRIVATE, "_vantage_kind": Net.PRIVATE, "_rng": Net.PRIVATE, "_deck": Net.PRIVATE, "_legs": Net.PRIVATE, "_leg_i": Net.PRIVATE,
		"_seg_i": Net.PRIVATE, "_route_key": Net.PRIVATE, "_route_goal": Net.PRIVATE, "_route_t": Net.PRIVATE,
		"_target": Net.LOCAL, "_target_t": Net.PRIVATE, "_mode_t": Net.PRIVATE, "_said": Net.PRIVATE,
		"_status_t": Net.PRIVATE, "_last_pos": Net.PRIVATE, "_stk_t": Net.PRIVATE, "_stk_rem": Net.PRIVATE,
		"_stk_n": Net.PRIVATE, "_stk_pos": Net.PRIVATE, "_backup_t": Net.PRIVATE, "_backup_dir": Net.PRIVATE, "_hop_t": Net.PRIVATE,
		"_fight_t": Net.PRIVATE, "_no_los_t": Net.PRIVATE, "_alive_prev": Net.PRIVATE, "_vantage": Net.PRIVATE,
		"_tried": Net.PRIVATE, "_vantage_cd": Net.PRIVATE, "_at_vantage_t": Net.PRIVATE, "_roof_t": Net.PRIVATE, "_roof_anchor": Net.PRIVATE, "_roof_tries": Net.PRIVATE, "_roof_log_t": Net.PRIVATE, "_roof_out": Net.PRIVATE, "_roof_span": Net.PRIVATE, "roof_max": Net.PRIVATE, "stall_max": Net.PRIVATE, "_stall_t": Net.PRIVATE, "_stall_anchor": Net.PRIVATE, "last_dir": Net.PRIVATE, "t": Net.PRIVATE, "deck_changes": Net.PRIVATE,
		"stuck_events": Net.PRIVATE, "blocked_edges": Net.PRIVATE, "replans": Net.PRIVATE,
		"dev_travel": Net.PRIVATE, "dev_jumps": Net.PRIVATE, "_prog_key": Net.PRIVATE, "_prog_best": Net.PRIVATE,
		"_prog_t": Net.PRIVATE, "_prog_alive": Net.PRIVATE, "_last_dev_jump_t": Net.PRIVATE,
		"work_deck": Net.PRIVATE, "task_id": Net.PRIVATE, "role": Net.PRIVATE, "task_log": Net.PRIVATE, "ff_holds": Net.PRIVATE,
		"_task_t": Net.PRIVATE, "_skipped": Net.PRIVATE, "_hunt": Net.LOCAL, "_hunt_t": Net.PRIVATE, "_quiet_t": Net.PRIVATE,
		"_stuck_prog_t": Net.PRIVATE, "_prog_last": Net.PRIVATE, "_holding": Net.PRIVATE, "role_index": Net.PRIVATE,
		"_advance_t": Net.PRIVATE, "_stand_key": Net.PRIVATE, "_stand_pt": Net.PRIVATE, "local_plans": Net.PRIVATE,
		"local_fails": Net.PRIVATE}


## TestDrive calls this once its scene is set up (and the stack built).
static func attach(td: TestDrive, profile: String) -> MissionBot:
	var mb := MissionBot.new()
	mb.name = "MissionBot"
	mb.drive = td
	mb.pilot = TestDriveBotPilot.attach(td)
	mb.pilot.set_profile(profile if BotProfile.has_profile(profile) else "veteran")
	mb.pilot.set_active(true)
	mb.dev_travel = OS.get_cmdline_user_args().has("--dev-bot-travel") or TestDrive.dev_bot_travel
	td.add_child(mb)
	return mb


func _ready() -> void:
	process_physics_priority = -19   # after PlayerBot (-20) chose its inputs, before the mech steps
	_rng.seed = hash(["mission_bot", drive.seed_value, Net.session().local_id() if Net.session() != null else 0])
	_nav = BotNavigator.new()
	_nav.setup(null, null, _rng)
	if drive.stack != null:
		for k in drive.stack.decks.size():
			var nv := BotNavigator.new()
			nv.setup(drive.stack.decks[k].plan, drive.stack.deck_ring(k), _rng)
			_navs.append(nv)
	if drive.stack != null:
		planner = BotRoutePlanner.new()
		planner.setup(drive.stack)
		planner.no_drops = ramps_only
	var sm := planner.summary() if planner != null else {}
	FlowLog.say("bot on", "profile %s, route graph %s%s" % [pilot.profile_id, str(sm),
		", DEV travel jumps on" if dev_travel else ""])


## For tests and the report.
func stats() -> Dictionary:
	var by := {}
	for c: Dictionary in deck_changes:
		by[c["by"]] = int(by.get(c["by"], 0)) + 1
	return {"dev_jumps": dev_jumps, "deck_changes": deck_changes.duplicate(true), "by": by, "stuck": stuck_events,
		"blocked": blocked_edges, "replans": replans, "t": t, "roof_max": snappedf(roof_max, 0.1),
		"stall_max": snappedf(stall_max, 0.1), "tasks": task_log.duplicate(true), "ff_holds": ff_holds,
		"local_plans": local_plans, "local_fails": local_fails}


func _physics_process(dt: float) -> void:
	if drive == null or drive.loading or drive.mech == null or drive.stack == null or drive.mission == null:
		return
	if drive._held:
		return   # the barrier hasn't passed: stand still like everyone else
	var mech := drive.mech
	t += dt
	_ff_guard()
	var k := drive.stack.deck_at(mech.global_position)
	var jumped := _last_pos != Vector3.INF and _last_pos.distance_to(mech.global_position) > 30.0
	_last_pos = mech.global_position
	# Trap watch (stats): the longest span the legs pushed (move input) without the mech getting 2 m anywhere.
	if mech.global_position.distance_to(_stall_anchor) > 2.0 or jumped:
		_stall_anchor = mech.global_position
		_stall_t = 0.0
	elif mech.move_input.length() > 0.5:
		_stall_t += dt
		stall_max = maxf(stall_max, _stall_t)
	if k != _deck:
		_deck_change(_deck, k, jumped)
	elif jumped:
		_clear_route()   # a respawn (or a DEV jump) on the same deck
	var pt := drive.combat.player_target if drive.combat != null else null
	if (pt != null and pt.disabled) or mech.shutdown:
		return   # PlayerBot holds still while downed / shut down
	_replan_tick(dt)
	_target_t += dt
	_mode_t += dt
	_obj_tick(dt)
	var goal := _goal(k)
	if goal.is_empty():
		_set_mode("idle", "no objective", "idle")
		return
	var t_deck := int(goal["deck"])
	var at: Vector3 = goal["at"]
	var enemy := bool(goal.get("enemy", false))
	var zone_key := ""
	if goal.has("zone"):
		zone_key = "%s/%s%d" % [str(goal["key"]), role, role_index]
		if _stand_key == zone_key and _stand_pt != Vector3.INF:
			at = _stand_pt   # the reachable point inside the zone found by _plan_local
	_status(k, t_deck, at)
	var dist := _flat(at - mech.global_position, mech.up()).length()
	# DEV: one progress clock per objective: 5 m less route left, or a kill.
	var stall := 0.0
	if dev_travel:
		var per := drive.enemies_alive_per_deck()
		var alive: int = per[t_deck] if t_deck < per.size() else 0
		stall = _dev_clock(str(goal["key"]), _route_left() if mode == "travel" else dist, dt, alive if enemy else -1)
	var in_special := _in_special()
	# Plan mode: a zone to stand in (flag, defend, hold, a sweep's wait): hold it once inside (hysteresis), or once the
	# walk there has run out on its deck.
	if goal.has("zone") and not in_special and t_deck == k:
		var zr := float(goal["zone"])
		var walked := _route_key.begins_with(str(goal["key"]) + "@") and not _legs.is_empty() and _leg_i >= _legs.size()
		if dist < zr * (ZONE_OUT if _holding else ZONE_IN) or walked:
			if not _holding:
				_clear_route()
			_holding = true
			_set_mode("hold", str(goal["text"]), "hold %s on deck %d" % [str(goal["key"]), k])
			_zone_hold(k, at, zr, dt)
			return
	_holding = false
	# Fight near the target (hysteresis: in at ENGAGE, out past ENGAGE_OUT), or once the road there has run out.
	var road_done := mode == "travel" and _route_key.begins_with(str(goal["key"]) + "@") and not _legs.is_empty() \
		and _leg_i >= _legs.size()
	var fight := not in_special and enemy and t_deck == k and (dist < (ENGAGE_OUT if mode == "fight" else ENGAGE) or road_done)
	if fight:
		if mode != "fight":
			_clear_route()
			_fight_t = 0.0
			_perch = {}
			_no_los_t = 0.0
			_tried.clear()
			_vantage = Vector3.INF
		_set_mode("fight", str(goal["text"]), "fight %s on deck %d" % [str(goal["key"]), k])
		if dev_travel and stall > DEV_FIGHT_STALL:
			_dev_jump_near(t_deck, at, k)
			return
		_fight(k, t_deck, at, goal.get("eye", at), dt)
		return
	# Travel. Up on a roof (PlayerBot climbed one to fight), come down first: routes run on the streets.
	if not in_special and _on_roof(k):
		_roof_escape(k, dt)
		return
	_roof_done()
	var key := "%s@%d" % [str(goal["key"]), t_deck]
	# The last stretch to a zone: the street graph doesn't know what stands inside a block (towers, podiums, a mast), so
	# plan it on a physics grid to a stand point inside the zone (once per goal; the street route if none is found).
	var local := zone_key != "" and t_deck == k and _flat(goal["at"] - mech.global_position, mech.up()).length() < LOCAL_R
	if local:
		key += "#local"
	if key != _route_key or (_legs.is_empty() and _route_t > 1.0 and (t_deck != k or dist > ARRIVE * 2.0)):
		if not local or not _plan_local(k, goal, key, zone_key):
			_plan(k, t_deck, at, key, enemy)
	if _legs.is_empty() and t_deck != k:
		if dev_travel:
			_dev_fallback(goal, k, t_deck, at)
			return
		_set_mode("fight", "no way to deck %d from deck %d" % [t_deck, k], "stuck: no way to deck %d from deck %d (%s)" % [
			t_deck, k, planner.last_error if planner != null else "no planner"])
		return
	if dev_travel and stall > DEV_STALL and not in_special:
		_dev_fallback(goal, k, t_deck, at)
		return
	_set_mode("travel", "%s (deck %d -> %d)" % [str(goal["text"]), k, t_deck], "travel %s, deck %d -> %d%s" % [
		str(goal["key"]), k, t_deck, _via()])
	if _leg_i >= _legs.size():
		_stand()
		return
	_drive_leg(k, dt)


# --- Goal and target ---------------------------------------------------------------------------------------

## Where the objective wants the mech: {deck, at, key, text, enemy}, or {} when there is nothing left to do.
func _goal(k: int) -> Dictionary:
	var rules := drive.mission.rules
	if rules == null or rules.outcome != "":
		return {}
	if rules.plan != null:
		return _plan_goal(k)
	var cur := rules.current()
	if cur == "extract":
		var m := rules.marker()
		if m.is_empty():
			return {}
		return {"deck": int(m["deck"]), "at": drive.stack.from_deck_arc(int(m["deck"]), float(m["x"]), float(m["s"])),
			"key": "extract", "text": "to extraction", "enemy": false}
	if cur.begins_with("clear_"):
		var td := int(cur.trim_prefix("clear_"))
		_pick_target(td, k)
		if _target == null:
			return {}   # the host hasn't counted the last kill yet (or the deck is empty): wait
		return {"deck": td, "at": _target.global_position, "key": "clear_%d" % td,
			"text": "clear deck %d (%s)" % [td, _target.name], "enemy": true, "eye": _core(_target)}
	return {}


## The last stretch to a zone on deck k, planned on a LOCAL_STEP grid of street-level points around the zone's centre
## (a point counts when a ray down from 3.5 m finds floor within 1.2 m of the deck's floor, not from inside a solid,
## with headroom above it, outside floor
## cuts; two neighbours connect when rays at 2.5 and 5.5 m between them, in the middle and LOCAL_SIDE to each side, are clear). Breadth-first from the mech to the
## grid point within STAND_IN of the radius nearest the goal's point (an escort's offset). Sets the stand point (the hold
## centre from then on) and one walk leg along the path. False when the mech is off the grid or nothing in the zone is
## reachable (the caller plans on the street graph instead).
func _plan_local(k: int, goal: Dictionary, key: String, zone_key: String) -> bool:
	var st := drive.stack
	var mech := drive.mech
	var o := drive.mission.rules.objective(task_id)
	var centre: Vector2 = _zone_of(o)[0] if not o.is_empty() and str(goal["key"]) == task_id else Vector2.INF
	var ga := _arc_on(k, goal["at"])
	var want := Vector2(float(ga["x"]), float(ga["s"]))
	if centre == Vector2.INF:
		centre = want
	var r := float(goal["zone"])
	var n := int(LOCAL_HALF * 2.0 / LOCAL_STEP) + 1
	var org := centre - Vector2(LOCAL_HALF, LOCAL_HALF)
	var ma := _arc_on(k, mech.global_position)
	var mi := Vector2i(roundi((float(ma["x"]) - org.x) / LOCAL_STEP), roundi((float(ma["s"]) - org.y) / LOCAL_STEP))
	local_plans += 1
	if mi.x < 0 or mi.y < 0 or mi.x >= n or mi.y >= n:
		local_fails += 1
		return false
	var space := mech.get_world_3d().direct_space_state
	var floor_at := {}   # Vector2i -> Vector3 floor point, or null
	var fl := func(c: Vector2i) -> Variant:
		if floor_at.has(c):
			return floor_at[c]
		var v: Variant = null
		var p2 := org + Vector2(c) * LOCAL_STEP
		if c.x >= 0 and c.y >= 0 and c.x < n and c.y < n and not planner.in_cut(k, p2, 1.5):
			var base := st.from_deck_arc(k, p2.x, p2.y, 0.0)
			var up := st.deck_ring(k).up_at(base)
			# From just above a mech's knee, counting a start inside something (a podium, a tower's solid base: their
			# colliders are solid, a ray born inside them reports nothing without hit_from_inside).
			var q := PhysicsRayQueryParameters3D.create(base + up * 3.5, base - up * 2.0)
			q.exclude = [mech.get_rid()]
			q.hit_from_inside = true
			var h := space.intersect_ray(q)
			if not h.is_empty() and (h["normal"] as Vector3).dot(up) > 0.8 and ((h["position"] as Vector3) - base).dot(up) < 1.2:
				var f: Vector3 = h["position"]
				var q2 := PhysicsRayQueryParameters3D.create(f + up * 0.5, f + up * 7.5)
				q2.exclude = [mech.get_rid()]
				q2.hit_from_inside = true
				if space.intersect_ray(q2).is_empty():
					v = f
		floor_at[c] = v
		return v
	var start := Vector2i(-1, -1)
	var best_d := INF
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var c := mi + Vector2i(dx, dy)
			if fl.call(c) != null and Vector2(dx, dy).length() < best_d:
				best_d = Vector2(dx, dy).length()
				start = c
	if start.x < 0:
		local_fails += 1
		return false
	var came := {start: start}
	var queue: Array[Vector2i] = [start]
	var best := Vector2i(-1, -1)
	var best_score := INF
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1),
		Vector2i(-1, 1), Vector2i(-1, -1)]
	var qi := 0
	while qi < queue.size():
		var c: Vector2i = queue[qi]
		qi += 1
		var p2 := org + Vector2(c) * LOCAL_STEP
		if p2.distance_to(centre) <= r * STAND_IN:
			var sc := p2.distance_to(want)
			if sc < best_score:
				best_score = sc
				best = c
		var fa: Vector3 = fl.call(c)
		var up := st.deck_ring(k).up_at(fa)
		for d in dirs:
			var nb := c + d
			if came.has(nb):
				continue
			var fb: Variant = fl.call(nb)
			if fb == null:
				continue
			# A mech's width, not a line: rays at both sides (LOCAL_SIDE) and the middle (a doorway slit isn't a way).
			var clear := true
			var side := ((fb as Vector3) - fa).cross(up).normalized() * LOCAL_SIDE
			for hh: float in [2.5, 5.5]:
				for off: Vector3 in [Vector3.ZERO, side, -side]:
					var q := PhysicsRayQueryParameters3D.create(fa + up * hh + off, (fb as Vector3) + up * hh + off)
					q.exclude = [mech.get_rid()]
					q.hit_from_inside = true
					if not space.intersect_ray(q).is_empty():
						clear = false
						break
				if not clear:
					break
			if not clear:
				continue
			came[nb] = c
			queue.append(nb)
	if best.x < 0:
		local_fails += 1
		print("[Bot] no reachable stand point in %s's zone on deck %d (%d grid points reached)" % [str(goal["key"]), k, came.size()])
		return false
	var path: Array[Vector2i] = [best]
	while path[-1] != start:
		path.append(came[path[-1]])
	path.reverse()
	var pts: Array = [planner.xt(k, Vector2(float(ma["x"]), float(ma["s"])))]
	for c in path:
		pts.append(planner.xt(k, org + Vector2(c) * LOCAL_STEP))
	var bp := org + Vector2(best) * LOCAL_STEP
	_stand_key = zone_key
	_stand_pt = fl.call(best)
	_route_key = key
	_route_goal = goal["at"]
	_route_t = 0.0
	_legs = [{"kind": "walk", "from": k, "to": k, "pts": pts, "edges": [], "connector": -1}]
	_leg_i = 0
	_seg_i = 0
	_stk_t = 0.0
	_stk_rem = INF
	replans += 1
	print("[Bot] stand point for %s on deck %d at x %.0f s %.0f (%.1f m from the centre, %d steps, %d grid points reached)" % [
		str(goal["key"]), k, bp.x, bp.y, bp.distance_to(centre), path.size(), came.size()])
	return true


## Untyped on purpose: wrecks past MAX_WRECKS, culled enemies and kills elsewhere free them, and a freed object handed
## to a typed `EnemyBase` parameter errors at the call itself. Only a live, valid enemy of deck td passes.
func _live_on(e: Variant, td: int) -> bool:
	if e == null or not is_instance_valid(e) or not (e is EnemyBase):
		return false
	var en := e as EnemyBase
	return not en.destroyed() and not en.is_queued_for_deletion() and en.spawn_deck == td


## Commit to a target on deck td: keep it TARGET_HOLD s at least; then swap only for one clearly nearer. Fighting, follow
## the enemy PlayerBot is shooting (it has its own hysteresis).
func _pick_target(td: int, k: int) -> void:
	var pos := drive.mech.global_position
	if not _live_on(_target, td):
		_target = null
	var pb := pilot.bot if pilot != null else null
	if mode == "fight" and k == td and pb != null and is_instance_valid(pb):
		var pe: Variant = pb._current_enemy   # untyped: it may already be freed
		if _live_on(pe, td) and pe != _target and (_target == null or _target_t > 3.0):
			_target = pe
			_target_t = 0.0
			return
	var best: EnemyBase = null
	var best_d := INF
	for e: Variant in (drive.combat.squad.enemies as Array):   # untyped: the list may hold freed wrecks
		if not _live_on(e, td):
			continue
		var en := e as EnemyBase
		var d := en.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = en
	if _target == null:
		_target = best
		_target_t = 0.0
		return
	if _target_t < TARGET_HOLD or best == null or best == _target:
		return
	var cur_d: float = (_target as EnemyBase).global_position.distance_to(pos)
	if best_d < cur_d * TARGET_SWAP and cur_d - best_d > TARGET_SWAP_MIN:
		_target = best
		_target_t = 0.0


# --- Plan mode: objectives (docs/design/player-ai.md, "Mission bot: objectives") --------------------------------
## Read like a player: the rules' replicated state on this machine (host or client), the objective records (snapped sites,
## the hold zone) and the crew facts. Per deck in order: its primary, then its KNOWN bonuses in order (BONUS_GIVE_UP s
## each at most), then on the extraction deck the hold; then the next deck. work_deck only moves on.

func _plan_goal(k: int) -> Dictionary:
	var rules := drive.mission.rules
	var o := _task(rules)
	if o.is_empty():
		return {}
	var id := str(o["id"])
	var td := int(o["deck"])
	var ty := str(o["type"])
	if ty == "sweep":
		_pick_target(td, k)
		if _target != null:
			return {"deck": td, "at": _target.global_position, "key": id, "text": "sweep deck %d (%s)" % [td, _target.name],
				"enemy": true, "eye": _core(_target)}
		# Nothing alive: wait for the deck's waves at its arrival (never the site: the departure is a hole in the floor).
		var arr: Dictionary = drive.stack.section.arrival(td)
		return {"deck": td, "at": drive.stack.from_deck_arc(td, float(arr["x"]), float(arr["s"])), "key": id + ":wait",
			"text": "sweep deck %d: waiting for its waves" % td, "enemy": false, "zone": 30.0}
	if _live_on(_hunt, td) and k == td:
		var he := _hunt as EnemyBase
		return {"deck": td, "at": he.global_position, "key": id + ":hunt", "text": "%s %s: hunting %s" % [ty, id, he.name],
			"enemy": true, "eye": _core(he)}
	var z := _zone_of(o)
	var c: Vector2 = z[0]
	var r: float = z[1]
	if role == "escort":
		var ang := float(role_index) * 2.4
		c += Vector2(cos(ang), sin(ang)) * r * ESCORT_OFF
	var txt := "%s %s" % [ty, id]
	if rules.obj_state(id) != "hidden":
		txt += " (%.0f / %.0f)" % [rules.obj_progress(id), float(rules._tot.get(id, 0.0))]
	return {"deck": td, "at": drive.stack.from_deck_arc(td, c.x, c.y), "key": id, "text": txt, "enemy": false, "zone": r}


## The place an objective is held: [centre (x, s) on its deck, radius m]. The rules' record: snapped sites, the zone.
func _zone_of(o: Dictionary) -> Array:
	var ro := drive.mission.rules.objective(str(o["id"]))
	var c := Vector2(float(ro["site"]["x"]), float(ro["site"]["s"]))
	var r := float(ro["radius"])
	match str(o["type"]):
		"hold":
			var zr: Rect2 = ro["zone"]
			c = zr.get_center()
			r = minf(zr.size.x, zr.size.y) * 0.5
		"defend":
			r = minf(r, DEFEND_HOLD_R)
	return [c, r]


## The objective to do now ({} when nothing is left, or briefly between decks).
func _task(rules: MissionRules) -> Dictionary:
	var n := rules.deck_count
	var hold := rules.objective("hold")
	while work_deck < n:
		var p := rules.objective("d%d_p" % work_deck)
		if not p.is_empty() and not rules.is_done(str(p["id"])) and rules.obj_state(str(p["id"])) != "failed":
			return _start_task(p)
		if bonuses:
			for o: Dictionary in rules.objectives:
				var bid := str(o["id"])
				if int(o["deck"]) != work_deck or o["role"] != "bonus" or _skipped.has(bid):
					continue
				var st := rules.obj_state(bid)
				if st != "known" and st != "active":
					continue
				if bid == task_id and _task_t > BONUS_GIVE_UP:
					_skipped[bid] = true
					FlowLog.say("bot", "gave up on bonus %s after %.0f s" % [bid, _task_t])
					continue
				return _start_task(o)
		if not hold.is_empty() and int(hold["deck"]) == work_deck and not rules.is_done("hold"):
			return _start_task(hold)
		if _advance_t < ADVANCE_WAIT:
			return {}   # a bonus chained to what just finished may show up on the next evaluate
		work_deck += 1
		_advance_t = 0.0
		FlowLog.say("bot", "deck %d's objectives done, on to deck %d" % [work_deck - 1, work_deck])
	if not hold.is_empty() and not rules.is_done("hold"):
		return _start_task(hold)
	return {}


func _start_task(o: Dictionary) -> Dictionary:
	var id := str(o["id"])
	if id != task_id:
		task_id = id
		_task_t = 0.0
		_hunt = null
		_quiet_t = 0.0
		_stuck_prog_t = 0.0
		_prog_last = -1.0
		task_log.append({"t": snappedf(t, 0.1), "id": id, "type": str(o["type"])})
		FlowLog.say("bot task", "%s (%s %s on deck %d), role %s" % [id, str(o["role"]), str(o["type"]), int(o["deck"]), role])
	_advance_t = 0.0
	return o


## Once a frame (plan mode): the role, the timers, and whether to leave the zone to hunt.
func _obj_tick(dt: float) -> void:
	var rules := drive.mission.rules
	if rules == null or rules.plan == null:
		return
	_task_t += dt
	_advance_t += dt
	_update_role()
	var pb := pilot.bot if pilot != null else null
	var engaged := pb != null and is_instance_valid(pb) and pb.ai_state == PlayerBot.STATE_ENGAGE
	if engaged:
		_quiet_t = 0.0
	elif _holding:
		_quiet_t += dt
	if _hunt != null:
		_hunt_t += dt
		if not _live(_hunt) or _hunt_t > HUNT_GIVE_UP:
			_hunt = null
	var o := rules.objective(task_id)
	if o.is_empty() or not _holding:
		return
	var ty := str(o["type"])
	if ty == "flag":
		var pr := rules.obj_progress(task_id)
		if pr > _prog_last + 0.05:
			_prog_last = pr
			_stuck_prog_t = 0.0
		else:
			_stuck_prog_t += dt
	if _hunt != null:
		return
	var want := false
	match ty:
		"flag":   # contested: something inside the ring stops the clock
			want = _stuck_prog_t > (4.0 if role == "escort" else HUNT_AFTER)
		"defend":   # wave units hanging back (the defend is done only once they are all dead); the escort goes at once
			want = rules.obj_state(task_id) == "active" and (_quiet_t > HUNT_AFTER or role == "escort")
	if want:
		_hunt = _pick_hunt(o, ty == "defend", role == "escort" and _quiet_t <= HUNT_AFTER)
		_hunt_t = 0.0
		_stuck_prog_t = 0.0
		_quiet_t = 0.0
		if _hunt != null:
			FlowLog.say("bot", "%s: leaving the zone to hunt %s" % [task_id, (_hunt as EnemyBase).name])
			_said = ""


## An enemy of the objective's deck worth leaving the zone for: wave units first on a defend (any distance: the defend
## needs them dead; `near_only`: within HUNT_RANGE of the site), else the nearest to the site within HUNT_RANGE.
## Only EnemySquad's enemies (banners and other scenery targets are never hunted).
func _pick_hunt(o: Dictionary, waves_first: bool, near_only: bool) -> Variant:
	var td := int(o["deck"])
	var c: Vector2 = _zone_of(o)[0]
	var best: Variant = null
	var best_d := INF
	for e: Variant in (drive.combat.squad.enemies as Array):
		if not _live_on(e, td):
			continue
		var en := e as EnemyBase
		var a := drive.stack.to_deck_arc(en.global_position)
		var d := c.distance_to(Vector2(float(a["x"]), float(a["s"])))
		var wave := waves_first and en.wave != ""
		if (not wave or near_only) and d > HUNT_RANGE:
			continue
		var score := d - (1000.0 if wave else 0.0)
		if score < best_d:
			best_d = score
			best = en
	return best


func _live(e: Variant) -> bool:
	return e != null and is_instance_valid(e) and e is EnemyBase and not (e as EnemyBase).destroyed() \
		and not (e as EnemyBase).is_queued_for_deletion()


## Co-op split, the same on every machine: the standing crew sorted by peer id; the first holds the zone ("anchor"), the
## others ("escort") hold off-centre and go after threats near it. Alone: "solo".
func _update_role() -> void:
	var peers: Array = []
	for c: Dictionary in drive.mission.crew_facts():
		if not bool(c["downed"]):
			peers.append(int(c["peer"]))
	peers.sort()
	role_index = maxi(peers.find(MechSpawn.owner_of(drive.mech)), 0)
	role = "solo" if peers.size() <= 1 else ("anchor" if role_index == 0 else "escort")


## Stand in the zone (centre `at`, radius r): PlayerBot aims and fires; its legs only while it engages / dodges / takes
## cover and stays near the centre; past HOLD_DRIFT of r, walk back (still facing the enemy when engaging).
func _zone_hold(k: int, at: Vector3, r: float, _dt: float) -> void:
	var mech := drive.mech
	var up := mech.up()
	var off := _flat(at - mech.global_position, up)
	var d := off.length()
	_roof_done()
	var pb := pilot.bot if pilot != null else null
	var st := pb.ai_state if pb != null and is_instance_valid(pb) else ""
	if d > r * HOLD_DRIFT:
		var dir := _nav.avoid_obstacles(mech, off.normalized(), mech.get_world_3d().direct_space_state, up)
		dir = _veto(k, dir)
		if st == PlayerBot.STATE_ENGAGE:
			var b := mech.global_transform.basis
			mech.move_input = Vector2(dir.dot(b.x), -dir.dot(b.z)).limit_length(1.0)
			mech.running = false
			mech.thrust_input = false
		else:
			_steer(dir, d > r, false)
		return
	if st in [PlayerBot.STATE_ENGAGE, PlayerBot.STATE_DODGE, PlayerBot.STATE_TAKE_COVER]:
		_veto_inputs(k)
		if st != PlayerBot.STATE_DODGE:
			mech.thrust_input = false
		return
	mech.move_input = Vector2.ZERO   # hold still; PlayerBot keeps turning toward what it heard or saw
	mech.running = false
	mech.thrust_input = false


## Friendly fire is on by default: hold the trigger (after PlayerBot chose it) while a teammate stands near the line from
## the eye to the aim point, or near the aim point itself (splash).
func _ff_guard() -> void:
	if drive.crew_sync == null or drive.combat == null or drive.combat.rack == null:
		return
	var rack := drive.combat.rack
	var mech := drive.mech
	var eye := mech.global_position + mech.up() * PlayerBot.EYE_HEIGHT
	var aim := rack.aim_point
	for p: int in drive.crew_sync.puppets:
		var pp := drive.crew_sync.puppets[p] as MechPuppet
		if pp == null or not is_instance_valid(pp) or pp.mech == null or not is_instance_valid(pp.mech):
			continue
		var c: Vector3 = pp.mech.global_position + mech.up() * 4.0
		var q := Geometry3D.get_closest_point_to_segment(c, eye, aim)
		if q.distance_to(c) < FF_CLEAR or aim.distance_to(c) < FF_SPLASH:
			rack.set_trigger(false)
			ff_holds += 1
			return


# --- Routes ------------------------------------------------------------------------------------------------

func _arc(p: Vector3) -> Dictionary:
	return drive.stack.to_deck_arc(p)


## (x, theta) of a world point.
func _xt(p: Vector3) -> Vector2:
	var a := _arc(p)
	return Vector2(float(a["x"]), float(a["s"]) / drive.stack.section.radius_of(int(a["deck"])))


func _plan(k: int, t_deck: int, at: Vector3, key: String, end_on_road: bool = false) -> void:
	_route_key = key
	_route_goal = at
	_route_t = 0.0
	_legs = []
	_leg_i = 0
	_seg_i = 0
	_stk_t = 0.0   # (a back-off in progress keeps going: it is what the re-plan starts from)
	_stk_rem = INF
	if planner == null:
		return
	var me := _arc(drive.mech.global_position)
	var goal_xt := _xt(at)
	var r := drive.stack.section.radius_of(t_deck)
	_legs = planner.plan(k, Vector2(float(me["x"]), float(me["s"])), t_deck, Vector2(goal_xt.x, goal_xt.y * r), end_on_road,
		float(me["h"]))
	replans += 1


func _clear_route() -> void:
	_legs = []
	_leg_i = 0
	_seg_i = 0
	_route_key = ""
	_reset_stuck()


func _reset_stuck() -> void:
	_stk_t = 0.0
	_stk_rem = INF
	_stk_n = 0
	_backup_t = 0.0
	_hop_t = 0.0


## Re-plan when the goal moved REPLAN_MOVE m since the plan (enemies walk), checked every REPLAN_EVERY s; never in the
## middle of a ramp or a drop.
func _replan_tick(dt: float) -> void:
	_route_t += dt
	if _route_t < REPLAN_EVERY or _legs.is_empty() or _in_special():
		return
	_route_t = 0.0
	var goal := _goal(_deck)
	if goal.is_empty() or _route_goal == Vector3.INF:
		return
	if (goal["at"] as Vector3).distance_to(_route_goal) > REPLAN_MOVE:
		_route_key = ""   # the next frame plans again


## On a ramp or in a drop now (no fight, no re-plan until it is over).
func _in_special() -> bool:
	if _leg_i >= _legs.size():
		return false
	var leg: Dictionary = _legs[_leg_i]
	if leg["kind"] == "walk":
		return false
	if leg["kind"] == "ramp":
		return _deck == int(leg["to"]) or _leg_left(leg) < _leg_len(leg) - 3.0
	return _deck != int(leg["from"]) or not drive.mech.grounded() or _leg_left(leg) < 15.0


func _via() -> String:
	var kinds: Array[String] = []
	for i in range(_leg_i, _legs.size()):
		var kd := str(_legs[i]["kind"])
		if kd != "walk":
			kinds.append("%s %d->%d" % [kd, int(_legs[i]["from"]), int(_legs[i]["to"])])
	return "" if kinds.is_empty() else " via " + ", ".join(kinds)


## Route length left (m on the current deck's scale).
func _route_left() -> float:
	if _leg_i >= _legs.size():
		return 0.0
	var tot := _leg_left(_legs[_leg_i])
	for i in range(_leg_i + 1, _legs.size()):
		tot += _leg_len(_legs[i])
	return tot


func _pts_m(leg: Dictionary) -> Array[Vector2]:
	var r := drive.stack.section.radius_of(clampi(_deck, 0, drive.stack.section.deck_count - 1))
	var out: Array[Vector2] = []
	for q: Vector2 in leg["pts"]:
		out.append(Vector2(q.x, q.y * r))
	return out


func _leg_len(leg: Dictionary) -> float:
	var p := _pts_m(leg)
	var tot := 0.0
	for i in p.size() - 1:
		tot += p[i].distance_to(p[i + 1])
	return tot


func _leg_left(leg: Dictionary) -> float:
	return float(_follow(leg, false)["left"])


## Pure pursuit on the leg's polyline: {target: Vector2 (arc m), left: float (m to its end), me: Vector2}. `advance`
## moves the segment index on.
func _follow(leg: Dictionary, advance: bool = true) -> Dictionary:
	var p := _pts_m(leg)
	var a := _arc(drive.mech.global_position)
	var me := Vector2(float(a["x"]), float(a["s"]) * drive.stack.section.radius_of(clampi(_deck, 0, 99)) \
		/ drive.stack.section.radius_of(int(a["deck"])))
	if p.size() < 2:
		return {"target": p[0] if not p.is_empty() else me, "left": me.distance_to(p[0]) if not p.is_empty() else 0.0, "me": me}
	var bi := mini(_seg_i, p.size() - 2)
	var bq := p[bi]
	var bd := INF
	for i in range(mini(_seg_i, p.size() - 2), mini(_seg_i + 4, p.size() - 1)):
		var q := Geometry2D.get_closest_point_to_segment(me, p[i], p[i + 1])
		var d := q.distance_to(me)
		if d < bd - 0.01:
			bd = d
			bi = i
			bq = q
	if advance:
		_seg_i = bi
	var left := bq.distance_to(p[bi + 1])
	for i in range(bi + 1, p.size() - 1):
		left += p[i].distance_to(p[i + 1])
	var need := LOOK
	var cur := bq
	var target := p[-1]
	var i2 := bi
	while i2 < p.size() - 1:
		var dl := cur.distance_to(p[i2 + 1])
		if dl >= need:
			target = cur + (p[i2 + 1] - cur).normalized() * need
			break
		need -= dl
		cur = p[i2 + 1]
		i2 += 1
	return {"target": target, "left": left, "me": me}


func _next_leg() -> void:
	_leg_i += 1
	_seg_i = 0
	_reset_stuck()


## Follow the current leg one physics step.
func _drive_leg(k: int, dt: float) -> void:
	var mech := drive.mech
	var leg: Dictionary = _legs[_leg_i]
	var kind := str(leg["kind"])
	var fol := _follow(leg)
	var left := float(fol["left"])
	var me: Vector2 = fol["me"]
	match kind:
		"walk":
			if left < ARRIVE:
				_next_leg()   # past the last leg: the route is done (_leg_i == _legs.size())
				if _leg_i >= _legs.size():
					_stand()
				return
		"ramp":
			if k == int(leg["to"]) and left < 6.0:
				_next_leg()
				return
		_:
			if k == int(leg["to"]) and mech.grounded():
				_next_leg()
				return
	var dir2: Vector2 = (fol["target"] as Vector2) - me
	var run := true
	var thrust := false
	var avoid := kind == "walk"
	var veto := kind == "walk"
	if kind == "shaft" or kind == "glide":
		var land := _pts_m(leg)[-1]
		if k == int(leg["from"]) and mech.grounded():
			# The run-in: a glide waits for cool thrusters; a plain drop walks over the edge (lands near the middle).
			if kind == "glide" and mech.heat / maxf(mech.heat_cap, 1.0) > GLIDE_HEAT and left > _leg_len(leg) - 3.0:
				_stand()
				return
			run = kind == "glide" or left > 18.0
		else:
			# In the air: steer for the landing point; a glide holds height (thrusters) while over the hole below.
			dir2 = land - me
			if kind == "glide":
				var a := _arc(mech.global_position)
				var lo := int(leg["to"])
				var over := planner.in_cut(lo, planner.on_deck(lo, planner.xt(int(a["deck"]), Vector2(float(a["x"]), float(a["s"])))), 4.0)
				var h_lo := float(_arc_on(lo, mech.global_position)["h"])
				var vs := mech.velocity.dot(mech.up())
				var hot := mech.heat / maxf(mech.heat_cap, 1.0) > 0.92
				if not hot and h_lo < GLIDE_CEIL:
					thrust = (over and vs < -0.5) or (not over and vs < -9.0)
			elif dir2.length() < 3.0:
				dir2 = Vector2.ZERO
	elif kind == "ramp":
		run = false   # walk the slope (what test_city_stack_walk verified: parapets, contact flicker going down)
	var dir := _arc_to_world(k, dir2)
	_stuck_tick(dt, leg, left, me, kind)
	if _backup_t > 0.0:
		_backup_t -= dt
		dir = _backup_dir
		run = false
		avoid = false
	if _hop_t > 0.0:
		_hop_t -= dt
		thrust = true
	if dir.length_squared() < 1e-4:
		_stand(thrust)
		return
	dir = dir.normalized()
	if avoid:
		dir = _nav.avoid_obstacles(mech, dir, mech.get_world_3d().direct_space_state, mech.up())
	if veto:
		dir = _veto(k, dir)
	_steer(dir, run, thrust)


## Deck `lo`'s arc coordinates of a world point (to_deck_arc picks the deck under it; this one is asked for).
func _arc_on(lo: int, p: Vector3) -> Dictionary:
	var st := drive.stack
	var d := st.decks[lo]
	var a := d.ring.world_to_arc(d.to_local(p))
	return {"deck": lo, "x": a.x, "s": a.y, "h": a.z}


## Stuck recovery: every STUCK_WIN s on the ground, less than STUCK_MIN m of the leg done is a stuck check: back up
## (turned a little, alternating sides), hop from the third, and after BLOCK_AFTER block the nearest edge and re-plan.
func _stuck_tick(dt: float, leg: Dictionary, left: float, me: Vector2, kind: String) -> void:
	var mech := drive.mech
	# Off the ground counts too (wedged against a wall the legs may never touch down), except in a drop.
	if _backup_t > 0.0 or ((kind == "shaft" or kind == "glide") and not mech.grounded()):
		return
	_stk_t += dt
	if _stk_t < STUCK_WIN:
		return
	_stk_t = 0.0
	# Progress is the leg getting shorter, or failing that the mech getting somewhere (a re-plan changes the leg).
	var moved := mech.global_position.distance_to(_stk_pos)
	_stk_pos = mech.global_position
	if (_stk_rem - left >= STUCK_MIN and _stk_rem != INF) or moved >= STUCK_MIN * 2.0:
		_stk_rem = left
		return
	_stk_rem = left
	_stk_n += 1
	stuck_events += 1
	var fwd := last_dir if last_dir.length_squared() > 0.01 else mech.forward()
	var side := 1.0 if _stk_n % 2 == 0 else -1.0
	_backup_dir = (-fwd).rotated(mech.up(), side * 0.6)
	_backup_t = BACKUP_T
	if _stk_n >= 3 and mech.heat / maxf(mech.heat_cap, 1.0) < 0.5:
		_hop_t = 0.4
	print("[Bot] stuck %d on %s leg (deck %d, %.0f m left)" % [_stk_n, kind, _deck, left])
	if _stk_n >= BLOCK_AFTER and kind == "walk":
		var r := drive.stack.section.radius_of(clampi(_deck, 0, 99))
		if planner.block_near(leg, Vector2(me.x, me.y / r)):
			blocked_edges += 1
			print("[Bot] blocked an edge near x %.0f s %.0f on deck %d, re-planning" % [me.x, me.y, _deck])
		else:
			# Off the graph (a start link, a corner): a longer back-off to a random side, then plan from there.
			_backup_dir = (-fwd).rotated(mech.up(), _rng.randf_range(-1.4, 1.4))
			_backup_t = BACKUP_T * 2.5
		_stk_n = 0
		_route_key = ""


## An arc-metre direction on deck k at the mech -> a world direction along the floor.
func _arc_to_world(k: int, d2: Vector2) -> Vector3:
	if d2.length_squared() < 1e-6:
		return Vector3.ZERO
	var ax := _axes(k)
	var w: Vector3 = ax[0] * d2.x + ax[1] * d2.y
	return _flat(w, drive.mech.up())


## World directions of +x and +s on deck k at the mech.
func _axes(k: int) -> Array:
	var st := drive.stack
	var a := _arc_on(k, drive.mech.global_position)
	var x := float(a["x"])
	var s := float(a["s"])
	var p0 := st.from_deck_arc(k, x, s)
	return [(st.from_deck_arc(k, x + 1.0, s) - p0).normalized(), (st.from_deck_arc(k, x, s + 1.0) - p0).normalized()]


## Keep a world direction from carrying the mech into a floor cut of deck k (VETO_GROW round it, VETO_AHEAD ahead):
## the part toward the cut is removed (a push out when already at its edge).
func _veto(k: int, dir: Vector3) -> Vector3:
	if planner == null or dir.length_squared() < 1e-6:
		return dir
	var ax := _axes(k)
	var a := _arc_on(k, drive.mech.global_position)
	var p := Vector2(float(a["x"]), float(a["s"]))
	var mag := dir.length()
	var d2 := Vector2(dir.dot(ax[0]), dir.dot(ax[1]))
	if d2.length_squared() < 1e-6:
		return dir
	d2 = d2.normalized()
	var changed := false
	for r: Rect2 in planner.cuts[k]:
		var g := r.grow(VETO_GROW)
		var ahead := p + d2 * VETO_AHEAD
		if not (g.has_point(ahead) or g.has_point(p) or BotRoutePlanner.seg_hits(p, ahead, g)):
			continue
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		var n := p - q
		if n.length_squared() < 1e-4:
			n = p - r.get_center()
		n = n.normalized()
		var into := d2.dot(n)
		if into < 0.0:
			d2 -= n * into
			if d2.length() < 0.25:
				d2 = n * 0.6
			changed = true
	if not changed:
		return dir
	return _flat(ax[0] * d2.x + ax[1] * d2.y, drive.mech.up()).normalized() * mag


# --- Fighting ----------------------------------------------------------------------------------------------

func _fight(k: int, t_deck: int, at: Vector3, eye: Vector3, dt: float) -> void:
	var mech := drive.mech
	var pb := pilot.bot if pilot != null else null
	var per := drive.enemies_alive_per_deck()
	var alive: int = per[t_deck] if t_deck < per.size() else 0
	_fight_t += dt
	_vantage_cd -= dt
	if alive != _alive_prev:
		if _alive_prev >= 0 and alive < _alive_prev:
			_fight_t = 0.0
			_perch = {}
			_vantage = Vector3.INF
			_tried.clear()
		_alive_prev = alive
	var st := pb.ai_state if pb != null and is_instance_valid(pb) else ""
	var engaging := st in [PlayerBot.STATE_ENGAGE, PlayerBot.STATE_DODGE, PlayerBot.STATE_CLIMB_ROOF, PlayerBot.STATE_TAKE_COVER]
	if st == PlayerBot.STATE_ENGAGE:
		_no_los_t = 0.0
		_vantage = Vector3.INF   # it sees something: fight from here
	else:
		_no_los_t += dt
	# No kill for a while, or nowhere nearer to walk, and no line of sight lately: move to a road point that sees the
	# target (its core, PlayerBot's own test).
	var walked_out := _route_key.begins_with("fightwalk") and _leg_i >= _legs.size()
	if (_fight_t > VANTAGE_AFTER or walked_out) and _no_los_t > 2.5 and _vantage == Vector3.INF and _vantage_cd <= 0.0 \
			and _perch.is_empty():
		_vantage = _pick_vantage(k, at, eye)
		if _vantage == Vector3.INF:
			_vantage_cd = 6.0
			_tried.clear()
		else:
			_no_los_t = 0.0
		# Nothing on the streets sees an enemy up on a roof: climb a roof that does (thrusters).
		if _vantage_kind != "sight" and float(_arc_on(k, eye)["h"]) > PERCH_MIN_H:
			_perch = _pick_perch(k, eye)
			if not _perch.is_empty():
				_vantage = Vector3.INF
				_perch_t = 0.0
				_perch_hold = 0.0
		_clear_route()
	if engaging:
		_clear_route()
		_veto_inputs(k)
		_roof_done()
		return
	if not _perch.is_empty():
		_perch_step(k, dt)
		return
	if _no_los_t > 3.0 and _on_roof(k):
		_roof_escape(k, dt)   # nothing to shoot from up there: back to the streets
		return
	_roof_done()
	# No line of sight: this layer drives (PlayerBot exploring would wander off the objective): to the vantage, or
	# toward the target until FIGHT_CLOSE / the road ends; there it holds, or lets PlayerBot advance on its own.
	var goal := _vantage if _vantage != Vector3.INF else at
	var close := _flat(goal - mech.global_position, mech.up()).length()
	if _vantage != Vector3.INF and close < ARRIVE * 1.5:
		_clear_route()
		_stand()   # at the vantage: hold still and look (the next one comes if nothing shows)
		_at_vantage_t += dt
		if _at_vantage_t > VANTAGE_HOLD:
			_vantage = Vector3.INF
			_no_los_t = 4.0
		return
	_at_vantage_t = 0.0
	var key := "fightwalk@%d:%s" % [k, "v%s" % str(_vantage) if _vantage != Vector3.INF else "t"]
	if _vantage == Vector3.INF and close < FIGHT_CLOSE:
		_route_key = key
		_legs = []
		_hold(k, st)
		return
	if key != _route_key or (_legs.is_empty() and _route_t > 1.0):
		_plan(k, k, goal, key, _vantage == Vector3.INF)
	if _leg_i >= _legs.size():
		_hold(k, st)
		return
	_drive_leg(k, dt)


## Fighting with nowhere to walk: PlayerBot advances on what it remembers (with the cut veto); else hold still.
func _hold(k: int, st: String) -> void:
	if st == PlayerBot.STATE_ADVANCE and _vantage_cd > 0.0:
		_veto_inputs(k)
	else:
		_stand()


## A road point of deck k (graph nodes, and points every VANTAGE_STEP m along its road edges) at least 15 m from the
## target (up to VANTAGE_RANGE) with a clear line from a mech's eye there to `look` (the target's core, PlayerBot's own line-of-sight test),
## nearest to the mech first, not tried yet this fight. INF when none.
func _pick_vantage(k: int, at: Vector3, look: Vector3) -> Vector3:
	_vantage_kind = ""
	if planner == null:
		return Vector3.INF
	var st := drive.stack
	var ta := _arc_on(k, at)
	var tp := Vector2(float(ta["x"]), float(ta["s"]))
	var ma := _arc_on(k, drive.mech.global_position)
	var mp := Vector2(float(ma["x"]), float(ma["s"]))
	var cands: Array = []
	var seen := {}
	for e: Dictionary in planner.edges:
		if e["kind"] != "walk" or int(e["from"]) != k:
			continue
		var a := planner.on_deck(k, (e["pts"] as Array)[0])
		var b := planner.on_deck(k, (e["pts"] as Array)[-1])
		var n := maxi(int(a.distance_to(b) / VANTAGE_STEP), 1)
		for i in n + 1:
			var p := a.lerp(b, float(i) / float(n))
			var key := Vector2i(roundi(p.x), roundi(p.y))
			if seen.has(key) or _tried.has(key):
				continue
			seen[key] = true
			var d := p.distance_to(tp)
			if d >= 15.0 and d <= VANTAGE_RANGE:
				cands.append([p, p.distance_to(mp), key])
	cands.sort_custom(func(u: Array, v: Array) -> bool: return float(u[1]) < float(v[1]))
	var space := drive.mech.get_world_3d().direct_space_state
	for c: Array in cands.slice(0, 90):
		var p2: Vector2 = c[0]
		_tried.append(c[2])
		var p := st.from_deck_arc(k, p2.x, p2.y, CityPlan.CURB_H)
		var eye := p + st.deck_ring(k).up_at(p) * PlayerBot.EYE_HEIGHT
		var q := PhysicsRayQueryParameters3D.create(eye, look)
		q.exclude = [drive.mech.get_rid()]
		var hit := space.intersect_ray(q)
		var dd := eye.distance_to(look)
		if hit.is_empty() or eye.distance_to(hit["position"] as Vector3) >= dd - 2.6:
			_vantage_kind = "sight"
			print("[Bot] vantage on deck %d at x %.0f s %.0f (%.0f m from the target, target h %.1f)" % [k, p2.x, p2.y,
				p2.distance_to(tp), float(ta["h"])])
			return p
	print("[Bot] no vantage on deck %d: %d road points 15-170 m from the target (x %.0f s %.0f h %.1f) and none sees it" % [k,
		cands.size(), tp.x, tp.y, float(ta["h"])])
	# None sees it (troopers behind a parapet, a turret set back on a roof): walk round it to another road point 25-90 m
	# out, so PlayerBot gets other angles (troopers peek out of cover).
	var near: Array = cands.filter(func(c: Array) -> bool: return (c[0] as Vector2).distance_to(tp) > 25.0 and (c[0] as Vector2).distance_to(tp) < 90.0)
	if near.is_empty():
		return Vector3.INF
	var pick: Vector2 = near[_rng.randi_range(0, near.size() - 1)][0]
	_vantage_kind = "patrol"
	print("[Bot] patrol round the target on deck %d: x %.0f s %.0f" % [k, pick.x, pick.y])
	return st.from_deck_arc(k, pick.x, pick.y, CityPlan.CURB_H)



## PlayerBot drives the legs: only keep them off floor cuts.
func _veto_inputs(k: int) -> void:
	var mech := drive.mech
	var mi := mech.move_input
	if mi.length_squared() < 1e-4:
		return
	var b := mech.global_transform.basis
	var w := b.x * mi.x - b.z * mi.y
	var v := _veto(k, w)
	if v.is_equal_approx(w):
		return
	mech.move_input = Vector2(v.dot(b.x), -v.dot(b.z)).limit_length(1.0)


# --- Legs ----------------------------------------------------------------------------------------------------

## Move along `dir` (world, along the floor), facing the way it walks.
func _steer(dir: Vector3, run: bool, thrust: bool) -> void:
	var mech := drive.mech
	var up := mech.up()
	var local := mech.global_transform.basis.inverse() * dir
	mech.move_input = Vector2(local.x, -local.z).limit_length(1.0)
	var fwd := _flat(-mech.global_transform.basis.z, up).normalized()
	var ang := fwd.signed_angle_to(dir, up)
	mech.turn_input = clampf(-ang * 2.0, -1.0, 1.0)   # MechController: + turns right (clockwise about up)
	last_dir = dir
	mech.running = run
	mech.thrust_input = thrust


func _stand(thrust: bool = false) -> void:
	var mech := drive.mech
	mech.move_input = Vector2.ZERO
	mech.turn_input = 0.0
	mech.running = false
	mech.thrust_input = thrust


func _deck_change(from: int, to: int, jumped: bool) -> void:
	if from >= 0:
		var by := "unplanned"
		if jumped:
			by = "dev travel" if t - _last_dev_jump_t < 0.2 else "respawn"
		elif _leg_i < _legs.size():
			var leg: Dictionary = _legs[_leg_i]
			var lo := mini(int(leg["from"]), int(leg["to"]))
			var hi := maxi(int(leg["from"]), int(leg["to"]))
			if leg["kind"] != "walk" and from >= lo and from <= hi and to >= lo and to <= hi:
				by = str(leg["kind"])
		deck_changes.append({"t": snappedf(t, 0.1), "from": from, "to": to, "by": by})
		FlowLog.say("bot deck change", "deck %d -> %d by %s (t %.0f s)" % [from, to, by, t])
		if by == "unplanned" or by == "respawn" or by == "dev travel":
			_clear_route()
	_bind_deck(to)



func _bind_deck(k: int) -> void:
	_deck = k
	var b := pilot.bot if pilot != null else null
	if b != null and is_instance_valid(b):
		b.bind(drive.mech, drive.combat.rack, drive.combat.player_target, drive.combat.world, drive.combat.squad,
			drive.stack.decks[k].plan, drive.stack.deck_ring(k), drive.cam)
	FlowLog.say("bot deck", "now on deck %d" % k)


func _status(k: int, t_deck: int, at: Vector3) -> void:
	_status_t -= get_physics_process_delta_time()
	if _status_t > 0.0:
		return
	_status_t = STATUS_EVERY
	var mech := drive.mech
	var a := _arc(mech.global_position)
	var ta := _arc(at)
	var leg := "-"
	if _leg_i < _legs.size():
		leg = "%s %d/%d (%.0f m left)" % [str(_legs[_leg_i]["kind"]), _leg_i + 1, _legs.size(), _leg_left(_legs[_leg_i])]
	print("[Bot] t %.0f %s %s | me deck %d x %.0f s %.0f h %.1f v %.1f | goal deck %d x %.0f s %.0f, %.0f m | leg %s | pb %s | stuck %d" % [
		t, mode, goal_text, k, float(a["x"]), float(a["s"]), float(a["h"]), mech.velocity.length(), t_deck,
		float(ta["x"]), float(ta["s"]), mech.global_position.distance_to(at), leg,
		pilot.bot.ai_state if pilot != null and pilot.bot != null else "?", stuck_events])


## `say`: the [Flow] line, logged when it changes (kept free of enemy names so target switches don't spam).
func _set_mode(m: String, text: String, say: String) -> void:
	if m != mode:
		_mode_t = 0.0
	mode = m
	goal_text = text
	if say != _said:
		_said = say
		FlowLog.say("bot", say)


static func _flat(v: Vector3, up: Vector3) -> Vector3:
	return v - up * v.dot(up)


# --- DEV travel (fallback) -------------------------------------------------------------------------------------

func _dev_fallback(goal: Dictionary, k: int, t_deck: int, at: Vector3) -> void:
	if t_deck < k and _legs.is_empty():
		FlowLog.say("bot", "no way up from deck %d to deck %d (no ramp; lifts don't move yet): DEV travel" % [k, t_deck])
		_said = ""
	if bool(goal.get("enemy", false)) and t_deck == k:
		_dev_jump_near(t_deck, at, k)
	elif str(goal["key"]) == "extract":
		var mk := drive.mission.rules.marker()
		dev_jump(int(mk["deck"]), float(mk["x"]), float(mk["s"]), k)
	else:
		_dev_jump_arrival(t_deck, k)


## DEV: how long since progress on `key` (5 m closer than its best `d`, or, fighting, a kill: `alive` dropped). Resets
## when the key changes.
func _dev_clock(key: String, d: float, dt: float, alive: int) -> float:
	if key != _prog_key:
		_prog_key = key
		_prog_best = d
		_prog_t = 0.0
		_prog_alive = alive
		return 0.0
	if d < _prog_best - 5.0 or (alive >= 0 and alive < _prog_alive):
		_prog_best = minf(d, _prog_best)
		_prog_alive = alive
		_prog_t = 0.0
	_prog_t += dt
	return _prog_t


## DEV: jump to deck t's arrival point: the arc spot of this mech's entry spawn slot, on deck t.
func _dev_jump_arrival(td: int, from: int) -> void:
	var st := drive.stack
	var n := drive.spawn_order.size()
	var me := MechSpawn.owner_of(drive.mech)
	var i := maxi(drive.spawn_order.find(me), 0)
	var slots := st.spawn_transforms(clampi(n, 1, 4))
	var a := st.to_deck_arc(slots[mini(i, slots.size() - 1)].origin)
	dev_jump(td, float(a["x"]), float(a["s"]), from)


## DEV: jump to DEV_NEAR m from `at` (an enemy on deck td), at the enemy's height (a turret on a roof: onto the roof),
## each jump from another side. Only a spot with a clear line from the mech's eye to the enemy counts; 8 sides x 2
## ranges are tried, starting from another side each jump.
func _dev_jump_near(td: int, at: Vector3, from: int) -> void:
	var st := drive.stack
	var e := st.to_deck_arc(at)
	var m := st.to_deck_arc(drive.mech.global_position)
	var d := Vector2(float(m["x"]) - float(e["x"]), float(m["s"]) - float(e["s"]))
	var dir0 := (d.normalized() if d.length() > 1.0 else Vector2(0, -1)).rotated(PI * 0.25 * float(dev_jumps))
	for r: float in [DEV_NEAR, DEV_NEAR * 1.6]:
		for i in 8:
			var dir := dir0.rotated(PI * 0.25 * float(i))
			if dev_jump(td, float(e["x"]) + dir.x * r, float(e["s"]) + dir.y * r, from, maxf(float(e["h"]), 0.0), at, false):
				return
	dev_jump(td, float(e["x"]) + dir0.x * DEV_NEAR, float(e["s"]) + dir0.y * DEV_NEAR, from, maxf(float(e["h"]), 0.0))


## DEV ONLY: put this machine's mech on the floor of deck td at (x, s) (or the first floor found stepping along s / x
## from there), standing still. Returns whether it found floor.
## `look`: also require a clear line from the mech's eye there to this point (an enemy); `steps_on`: try the nearby spots
## too (else only (x, s) itself).
func dev_jump(td: int, x: float, s: float, from: int, h: float = 0.0, look: Vector3 = Vector3.INF, steps_on: bool = true) -> bool:
	var st := drive.stack
	var mech := drive.mech
	var space := mech.get_world_3d().direct_space_state
	var steps := [Vector2.ZERO, Vector2(0, 8), Vector2(0, -8), Vector2(8, 0), Vector2(-8, 0), Vector2(0, 16), Vector2(0, -16),
		Vector2(16, 0), Vector2(-16, 0), Vector2(0, 24), Vector2(0, -24), Vector2(24, 0), Vector2(-24, 0)]
	if not steps_on:
		steps = [Vector2.ZERO]
	for off: Vector2 in steps:
		var base := st.from_deck_arc(td, x + off.x, s + off.y, h)
		var up := st.deck_ring(td).up_at(base)
		var q := PhysicsRayQueryParameters3D.create(base + up * 4.0, base - up * (h + 3.0))
		q.exclude = [mech.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or (hit["normal"] as Vector3).dot(up) < 0.8:
			continue
		var p: Vector3 = (hit["position"] as Vector3) + up * 0.3
		# Clear above: a mech's height of free space (not inside a building or a prop).
		var q2 := PhysicsRayQueryParameters3D.create(p + up * 0.5, p + up * 8.0)
		q2.exclude = [mech.get_rid()]
		if not space.intersect_ray(q2).is_empty():
			continue
		if look != Vector3.INF:
			var q3 := PhysicsRayQueryParameters3D.create(p + up * 6.5, look)
			q3.exclude = [mech.get_rid()]
			var h3 := space.intersect_ray(q3)
			if not h3.is_empty() and (h3["position"] as Vector3).distance_to(look) > 4.0:
				continue
		var f := -mech.global_transform.basis.z
		f = f - up * f.dot(up)
		if f.length_squared() < 0.01:
			f = st.deck_ring(td).tangent_at(p)
		f = f.normalized()
		mech.global_transform = Transform3D(Basis(f.cross(up), up, -f), p)
		mech.velocity = Vector3.ZERO
		MechSpawn.rig_of(mech).gait.reset([])
		dev_jumps += 1
		_last_dev_jump_t = t
		_clear_route()
		_prog_key = ""
		FlowLog.say("dev travel", "deck %d -> %d (x %.0f s %.0f)" % [from, td, x + off.x, s + off.y])
		return true
	if look == Vector3.INF:
		FlowLog.say("dev travel", "deck %d -> %d FAILED: no floor near x %.0f s %.0f" % [from, td, x, s])
		_prog_key = ""
	return false


## Where PlayerBot looks at an enemy (its first hit sphere, else 3 m above its feet): the vantage test aims there.
static func _core(e: EnemyBase) -> Vector3:
	if e.hit_shapes.size() > 0:
		var ws := e.world_spheres()
		for s: Dictionary in ws:   # a troop squad: the first trooper still up (PlayerBot._enemy_core_pos does the same)
			if float(e.hp.get(s["component"], 1.0)) > 0.0:
				return s["center"] as Vector3
		return (ws[0] as Dictionary)["center"] as Vector3
	return e.global_position + e.up * 3.0


## Standing on something inside a block (a roof PlayerBot climbed), ROOF_H above deck k's floor.
func _on_roof(k: int) -> bool:
	if planner == null or not drive.mech.grounded():
		return false
	var a := _arc_on(k, drive.mech.global_position)
	return float(a["h"]) > ROOF_H and planner.cell_at(k, Vector2(float(a["x"]), float(a["s"]))) >= 0


## Off the roof: straight for the nearest side of the block (ROOF_OUT m past it), a thruster hop whenever it doesn't
## move (parapets, roof units).
func _roof_escape(k: int, dt: float) -> void:
	var mech := drive.mech
	var a := _arc_on(k, mech.global_position)
	var p := Vector2(float(a["x"]), float(a["s"]))
	if _roof_t <= 0.0:
		if t - _roof_log_t > 5.0:
			_roof_log_t = t
			FlowLog.say("bot", "off the roof on deck %d (h %.0f m)" % [k, float(a["h"])])
		_said = ""
		_clear_route()
		_roof_anchor = mech.global_position
		_roof_out = _exit_side(k, p, float(a["h"]), mech.global_position, _roof_tries)
	_roof_t += dt
	_roof_span += dt
	if _roof_t > 1.0:
		if mech.global_position.distance_to(_roof_anchor) < 1.0:
			# Not moving: the next clear side, with a hop over whatever holds it (parapet, roof unit).
			_roof_tries += 1
			_roof_out = _exit_side(k, p, float(a["h"]), mech.global_position, _roof_tries)
			if mech.heat / maxf(mech.heat_cap, 1.0) < 0.7:
				_hop_t = 0.9
		_roof_t = 0.01
		_roof_anchor = mech.global_position
	var thrust := _hop_t > 0.0
	if _hop_t > 0.0:
		_hop_t -= dt
	if _roof_out == Vector2.INF:
		_stand(thrust)
		return
	_steer(_arc_to_world(k, _roof_out - p).normalized(), true, thrust)


## Off the roof for now: remember the longest escape (stats: roof_max).
func _roof_done() -> void:
	if _roof_span > 0.0:
		roof_max = maxf(roof_max, _roof_span)
		if _roof_span > 3.0:
			print("[Bot] off the roof after %.1f s" % _roof_span)
	_roof_span = 0.0
	_roof_t = 0.0
	_roof_tries = 0


## Where to walk off a roof (or the top of anything inside a block) at p, h m above deck k's floor: ROOF_OUT m past a
## side of its block, onto the road. The sides are taken nearest first; one counts when a ray at a mech's chest height
## from `from_w` to above that point hits nothing (nothing taller in the way). `skip` passes over that many clear sides
## (the escape got stuck on the earlier ones). INF when no side is clear (the caller hops, or rejects the roof).
func _exit_side(k: int, p: Vector2, h: float, from_w: Vector3, skip: int = 0) -> Vector2:
	var ci := planner.cell_at(k, p)
	if ci < 0:
		return Vector2.INF
	var r: Rect2 = planner.cells[k][ci]
	var sides := [[p.x - r.position.x, Vector2(r.position.x - ROOF_OUT, p.y)], [r.end.x - p.x, Vector2(r.end.x + ROOF_OUT, p.y)],
		[p.y - r.position.y, Vector2(p.x, r.position.y - ROOF_OUT)], [r.end.y - p.y, Vector2(p.x, r.end.y + ROOF_OUT)]]
	sides.sort_custom(func(u: Array, v: Array) -> bool: return float(u[0]) < float(v[0]))
	var st := drive.stack
	var space := drive.mech.get_world_3d().direct_space_state
	var up := st.deck_ring(k).up_at(from_w)
	var clear: Array = []
	for sd: Array in sides:
		var q := PhysicsRayQueryParameters3D.create(from_w + up * 4.0, st.from_deck_arc(k, (sd[1] as Vector2).x, (sd[1] as Vector2).y, h + 4.0))
		q.exclude = [drive.mech.get_rid()]
		if space.intersect_ray(q).is_empty():
			clear.append(sd[1])
	if clear.is_empty():
		return sides[skip % 4][1] if skip > 0 else Vector2.INF
	return clear[skip % clear.size()]


## A roof of deck k (BotNavigator's jumpable roofs) 14-110 m from the target whose top sees `look` from a mech's eye,
## nearest to the mech first, not tried this fight. {} when none.
func _pick_perch(k: int, look: Vector3) -> Dictionary:
	if k >= _navs.size():
		return {}
	var nav: BotNavigator = _navs[k]
	var st := drive.stack
	var mp := drive.mech.global_position
	var cands: Array = []
	for r: Dictionary in nav._roofs:
		var cw: Vector3 = r["center_w"]
		var key := "roof:%d:%d" % [roundi((r["arc2"] as Vector2).x), roundi((r["arc2"] as Vector2).y)]
		var d := cw.distance_to(look)
		if d < 14.0 or d > 110.0 or _tried.has(key):
			continue
		cands.append([r, cw.distance_to(mp), key])
	cands.sort_custom(func(u: Array, v: Array) -> bool: return float(u[1]) < float(v[1]))
	var space := drive.mech.get_world_3d().direct_space_state
	for c: Array in cands.slice(0, 30):
		_tried.append(c[2])
		var cw: Vector3 = (c[0] as Dictionary)["center_w"]
		var eye := cw + st.deck_ring(k).up_at(cw) * (PlayerBot.EYE_HEIGHT + 0.3)
		var q := PhysicsRayQueryParameters3D.create(eye, look)
		q.exclude = [drive.mech.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or eye.distance_to(hit["position"] as Vector3) >= eye.distance_to(look) - 2.6:
			var a := _arc_on(k, cw)
			# Only a roof it can walk off again: a side of its block with nothing taller in the way.
			if _exit_side(k, Vector2(float(a["x"]), float(a["s"])), float(a["h"]), cw) == Vector2.INF:
				continue
			FlowLog.say("bot", "climbing a roof on deck %d (x %.0f s %.0f, %.0f m up) to see the target" % [k, float(a["x"]),
				float(a["s"]), float((c[0] as Dictionary)["roof_h"])])
			_said = ""
			return c[0]
	return {}


## Get onto the perch: along the roads to near it, then BotNavigator's thruster climb; hold there PERCH_HOLD s.
func _perch_step(k: int, dt: float) -> void:
	var mech := drive.mech
	var up := mech.up()
	var heat := mech.heat / maxf(mech.heat_cap, 1.0)
	_perch_t += dt
	if _perch_t > PERCH_GIVE_UP:
		_perch = {}
		return
	var cw: Vector3 = _perch["center_w"]
	var flat := _flat(cw - mech.global_position, up).length()
	var high := float(_arc_on(k, mech.global_position)["h"]) > ROOF_H
	if flat > 32.0 and not high:
		var key := "perch@%d:%s" % [k, str(cw)]
		if key != _route_key or (_legs.is_empty() and _route_t > 1.0):
			_plan(k, k, cw, key, true)
		if _leg_i < _legs.size():
			_drive_leg(k, dt)
			return
	var res := (_navs[k] as BotNavigator).step_rooftop_climb(mech, _perch, up, heat)
	if bool(res["aborted"]):
		_stand()   # too hot: cool down first (PERCH_GIVE_UP ends it if this never works)
		return
	if bool(res["reached"]):
		_stand()
		_perch_hold += dt
		if _perch_hold > PERCH_HOLD:
			_perch = {}   # nothing seen from here: give it up (the roof escape takes the mech down)
		return
	var d: Vector3 = res["dir"]
	if d.length_squared() < 1e-4:
		_stand(bool(res["thrust"]))
		return
	_steer(d.normalized(), bool(res["running"]), bool(res["thrust"]))
