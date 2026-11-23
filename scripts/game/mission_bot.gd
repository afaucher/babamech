class_name MissionBot
extends Node
## `--bot [profile]`: the AI plays the local mech through the whole mission (LAN verification, soak runs). Input only,
## like a player: it never moves a mech or an enemy itself (except the DEV travel jump below).
##   FIGHTING is antigravity's TestDriveBotPilot / PlayerBot (sense, aim, fire, dodge, cover), rebound to the deck the
##   mech is on (that deck's CityPlan and deck_ring).
##   GOING somewhere is this layer. The mission's current objective (MissionRules.current(), the host's on a client)
##   picks a deck and a point: "clear_k", a COMMITTED live enemy of deck k (kept TARGET_HOLD s at least, swapped only for
##   one much nearer, or for the one PlayerBot is shooting); "extract", the extraction marker on the lowest deck.
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

## Tests: plan with ramps only (no shaft drops or glides), to exercise the ramp legs.
static var ramps_only := false

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
var _target: EnemyBase        ## the committed enemy (clear objectives)
var _target_t := 0.0          ## s it has been held
var _mode_t := 0.0            ## s in the current mode
var _said := ""
var _status_t := 0.0
var _last_pos := Vector3.INF
var _stk_t := 0.0             ## s since the last progress check
var _stk_rem := INF           ## remaining leg length at the last check
var _stk_n := 0               ## stuck checks on this leg
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


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "pilot": Net.LOCAL, "planner": Net.LOCAL, "mode": Net.PRIVATE, "goal_text": Net.PRIVATE,
		"_nav": Net.PRIVATE, "_navs": Net.PRIVATE, "_perch": Net.PRIVATE, "_perch_t": Net.PRIVATE, "_perch_hold": Net.PRIVATE, "_vantage_kind": Net.PRIVATE, "_rng": Net.PRIVATE, "_deck": Net.PRIVATE, "_legs": Net.PRIVATE, "_leg_i": Net.PRIVATE,
		"_seg_i": Net.PRIVATE, "_route_key": Net.PRIVATE, "_route_goal": Net.PRIVATE, "_route_t": Net.PRIVATE,
		"_target": Net.LOCAL, "_target_t": Net.PRIVATE, "_mode_t": Net.PRIVATE, "_said": Net.PRIVATE,
		"_status_t": Net.PRIVATE, "_last_pos": Net.PRIVATE, "_stk_t": Net.PRIVATE, "_stk_rem": Net.PRIVATE,
		"_stk_n": Net.PRIVATE, "_backup_t": Net.PRIVATE, "_backup_dir": Net.PRIVATE, "_hop_t": Net.PRIVATE,
		"_fight_t": Net.PRIVATE, "_no_los_t": Net.PRIVATE, "_alive_prev": Net.PRIVATE, "_vantage": Net.PRIVATE,
		"_tried": Net.PRIVATE, "_vantage_cd": Net.PRIVATE, "_at_vantage_t": Net.PRIVATE, "_roof_t": Net.PRIVATE, "_roof_anchor": Net.PRIVATE, "_roof_tries": Net.PRIVATE, "_roof_log_t": Net.PRIVATE, "last_dir": Net.PRIVATE, "t": Net.PRIVATE, "deck_changes": Net.PRIVATE,
		"stuck_events": Net.PRIVATE, "blocked_edges": Net.PRIVATE, "replans": Net.PRIVATE,
		"dev_travel": Net.PRIVATE, "dev_jumps": Net.PRIVATE, "_prog_key": Net.PRIVATE, "_prog_best": Net.PRIVATE,
		"_prog_t": Net.PRIVATE, "_prog_alive": Net.PRIVATE, "_last_dev_jump_t": Net.PRIVATE}


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
		"blocked": blocked_edges, "replans": replans, "t": t}


func _physics_process(dt: float) -> void:
	if drive == null or drive.loading or drive.mech == null or drive.stack == null or drive.mission == null:
		return
	if drive._held:
		return   # the barrier hasn't passed: stand still like everyone else
	var mech := drive.mech
	t += dt
	var k := drive.stack.deck_at(mech.global_position)
	var jumped := _last_pos != Vector3.INF and _last_pos.distance_to(mech.global_position) > 30.0
	_last_pos = mech.global_position
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
	var goal := _goal(k)
	if goal.is_empty():
		_set_mode("idle", "no objective", "idle")
		return
	var t_deck := int(goal["deck"])
	var at: Vector3 = goal["at"]
	var enemy := bool(goal.get("enemy", false))
	_status(k, t_deck, at)
	var dist := _flat(at - mech.global_position, mech.up()).length()
	# DEV: one progress clock per objective: 5 m less route left, or a kill.
	var stall := 0.0
	if dev_travel:
		var per := drive.enemies_alive_per_deck()
		var alive: int = per[t_deck] if t_deck < per.size() else 0
		stall = _dev_clock(str(goal["key"]), _route_left() if mode == "travel" else dist, dt, alive if enemy else -1)
	var in_special := _in_special()
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
	_roof_t = 0.0
	var key := "%s@%d" % [str(goal["key"]), t_deck]
	if key != _route_key or (_legs.is_empty() and _route_t > 1.0 and (t_deck != k or dist > ARRIVE * 2.0)):
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


func _live_on(e: EnemyBase, td: int) -> bool:
	return e != null and is_instance_valid(e) and not e.destroyed() and not e.is_queued_for_deletion() and e.spawn_deck == td


## Commit to a target on deck td: keep it TARGET_HOLD s at least; then swap only for one clearly nearer. Fighting, follow
## the enemy PlayerBot is shooting (it has its own hysteresis).
func _pick_target(td: int, k: int) -> void:
	var pos := drive.mech.global_position
	if not _live_on(_target, td):
		_target = null
	var pb := pilot.bot if pilot != null else null
	if mode == "fight" and k == td and pb != null and is_instance_valid(pb):
		var pe: EnemyBase = pb._current_enemy
		if _live_on(pe, td) and pe != _target and (_target == null or _target_t > 3.0):
			_target = pe
			_target_t = 0.0
			return
	var best: EnemyBase = null
	var best_d := INF
	for e in drive.combat.squad.enemies:
		if not _live_on(e, td):
			continue
		var d := e.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = e
	if _target == null:
		_target = best
		_target_t = 0.0
		return
	if _target_t < TARGET_HOLD or best == null or best == _target:
		return
	var cur_d := _target.global_position.distance_to(pos)
	if best_d < cur_d * TARGET_SWAP and cur_d - best_d > TARGET_SWAP_MIN:
		_target = best
		_target_t = 0.0


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
	_legs = planner.plan(k, Vector2(float(me["x"]), float(me["s"])), t_deck, Vector2(goal_xt.x, goal_xt.y * r), end_on_road)
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
	if _stk_rem - left >= STUCK_MIN or _stk_rem == INF:
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
		_roof_t = 0.0
		return
	if not _perch.is_empty():
		_perch_step(k, dt)
		return
	if _no_los_t > 3.0 and _on_roof(k):
		_roof_escape(k, dt)   # nothing to shoot from up there: back to the streets
		return
	_roof_t = 0.0
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
	var ci := planner.cell_at(k, p)
	var r: Rect2 = planner.cells[k][ci]
	var sides := [[p.x - r.position.x, Vector2(r.position.x - ROOF_OUT, p.y)], [r.end.x - p.x, Vector2(r.end.x + ROOF_OUT, p.y)],
		[p.y - r.position.y, Vector2(p.x, r.position.y - ROOF_OUT)], [r.end.y - p.y, Vector2(p.x, r.end.y + ROOF_OUT)]]
	sides.sort_custom(func(u: Array, v: Array) -> bool: return float(u[0]) < float(v[0]))
	var out: Vector2 = sides[_roof_tries % 4][1]
	if _roof_t <= 0.0:
		if t - _roof_log_t > 5.0:
			_roof_log_t = t
			FlowLog.say("bot", "off the roof on deck %d (h %.0f m)" % [k, float(a["h"])])
		_said = ""
		_clear_route()
		_roof_anchor = mech.global_position
	_roof_t += dt
	if _roof_t > 1.2:
		if mech.global_position.distance_to(_roof_anchor) < 1.0:
			_roof_tries += 1   # try the next-nearest side, with a hop when the thrusters are cool enough
			if mech.heat / maxf(mech.heat_cap, 1.0) < 0.7:
				_hop_t = 1.1
		_roof_t = 0.01
		_roof_anchor = mech.global_position
	var thrust := _hop_t > 0.0
	if _hop_t > 0.0:
		_hop_t -= dt
	_steer(_arc_to_world(k, out - p).normalized(), true, thrust)


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
