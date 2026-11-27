class_name MissionBot
extends Node
## `--bot [profile]`: the AI plays the local mech through the whole mission (LAN verification, soak runs). Input only,
## like a player: it never moves a mech or an enemy itself (except the DEV travel jump below).
##   FIGHTING is antigravity's MissionBotPilot / PlayerBot (sense, aim, fire, dodge, cover), rebound to the deck the
##   mech is on (that deck's CityPlan and deck_ring).
##   GOING somewhere is this layer. The mission plan's objectives (MissionRules.plan, the host's state on a client; the
##   one mission mode): per deck in order its primary, its KNOWN bonuses (MissionBot.bonuses), then on the extraction
##   deck the hold (_task). sweep = clear the deck: a COMMITTED live enemy of that deck (kept TARGET_HOLD s at least,
##   swapped only for one much nearer, or for the one PlayerBot is shooting), waiting at the deck's arrival for its waves;
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
## HANGAR BOTS (docs/design/hangar-bots.md): the same AI drives a host-run crew bot's mech (attach_crew): its body
## (body_mech / body_rack / body_pt) is that bot's, not the local mech; no camera; its PlayerBot is its own
## (MissionBotPilot with a body). The local `--bot` path is unchanged (body = drive.mech and drive.combat's rack /
## PlayerTarget).
## Every deck change logs "[Flow] bot deck change: deck a -> b by ramp | shaft | glide | unplanned | respawn".
## Started by MissionScene once the scene is set up (attach); every other [Flow] transition is still logged by MissionScene.
##
## DEV ONLY, `--dev-bot-travel` (dev_travel): a FALLBACK when the walk can't get there: no route to the target deck,
## DEV_STALL s without 5 m of progress along the route, or DEV_FIGHT_STALL s fighting without a kill. The bot then JUMPS:
## it sets its own mech's transform to an arrival point on the floor of the target deck (the entry spawn's arc spot on that
## deck, or near the target enemy), found with a ray down (dev_jump). The snapshot stream sees the
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
## WEDGE WATCH (_wedge_watch), whatever mode drives the legs: pushing WEDGE_AFTER s without getting 2 m anywhere (the
## stall watch) is a wedge: an ESCAPE (WEDGE_ESCAPE_T s pushed away from the contacts, thrusters on for the first part,
## a hop); a second escape from the same spot (WEDGE_SPOT m) also blocks every route edge within WEDGE_BLOCK_R m of it
## and keeps the legs off it (an avoid square, _solids), then re-plans. Seed 9: a Strider grounded on the foot of a
## ramp's slope just outside its lane (6 slide contacts on the slope face, no motion either way) pushed for 72 s.
const WEDGE_AFTER := 3.5
const WEDGE_ESCAPE_T := 1.2
const WEDGE_SPOT := 5.0
const WEDGE_BLOCK_R := 9.0
const WEDGE_AVOID := 3.5      ## m half-size of the avoid square round a wedge spot
const RAMP_LOW_H := 9.0       ## m: a ramp part lower than this over the deck is kept off (a mech walks under the rest)
const RAMP_CLEAR := 0.5       ## m between the capsule and a ramp part it is not taking (_ramp_keepout)
const WEDGE_FREED := 1.0      ## m an escape must make, else the next direction is tried at once
## Escape directions, turned from "away" (the contacts, else back from where it was heading), tried in this order.
const ESCAPE_TURNS := [0.0, PI * 0.5, -PI * 0.5, PI, PI * 0.25, -PI * 0.25, PI * 0.75, -PI * 0.75]
const GLIDE_HEAT := 0.4       ## heat share above which a glide waits (cools) at its run-in point
const GLIDE_CEIL := 28.0      ## m above the lower floor: below this the glide holds height (clear of the slab above)
const STATUS_EVERY := 10.0    ## s between "[Bot]" status lines
const ROOF_H := 3.0           ## m above the deck floor inside a block: on a roof
const ROOF_OUT := 8.0         ## m past the block's side a roof escape heads for
const PERCH_MIN_H := 6.0      ## m: a target this high above its deck may need a roof to be seen from
const PERCH_HOLD := 6.0       ## s on a perch without line of sight before giving it up
const PERCH_GIVE_UP := 45.0   ## s to reach a perch at most
const PERCH_RETRY := 45.0     ## s before a roof whose climb stalled may be tried again (a later try, cooler or from
#                               another side, sometimes makes it)
const PERCH_STALL := 8.0      ## s climbing toward a perch without rising 1 m, getting 2 m nearer or moving 2 m: that try is given up
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
const ROOMY := 3.0             ## m of clear space all round a stand / cover point (the capsule is ~2.2 m in radius)
const FIT_PAD := 0.6           ## m past the capsule a fallback stand point needs all round (_plan_local)
const STAND_IN := 0.45         ## share of the zone's radius a stand point may lie from the centre
const DEFEND_HOLD_R := 20.0    ## m: a defend is held this close to its relay (its activation radius is 30)
const HUNT_AFTER := 12.0       ## s holding with no progress (flag) / no engagement (defend) before hunting
const HUNT_RANGE := 70.0       ## m from the site: enemies this close count for a hunt
const HUNT_GIVE_UP := 40.0     ## s a hunt is kept at most before going back to the zone
## A flag / hold (a zone to stand in) hunts only what BLOCKS it: an enemy inside the zone (radius + HUNT_ZONE_PAD; any
## height counts, MissionFlow._zone_enemies) or a quick kill (under HUNT_QUICK_HP of its structure, within
## HUNT_QUICK_RANGE of the site). A hunt that deals no damage for HUNT_NO_DMG s is dropped (that enemy is not hunted
## again for HUNT_SKIP s unless it blocks the zone). Seed 6 flag: the bot left the ring for a roof sniper 30 m out
## and dealt nothing for 40 s while the flag sat at 0.
const HUNT_ZONE_PAD := 3.0
const HUNT_QUICK_HP := 0.35
const HUNT_QUICK_RANGE := 45.0
const HUNT_NO_DMG := 9.0
const HUNT_SKIP := 25.0
const ZONE_SIGHT_STEP := 2.0
const BLOCKER_SIGHT_R := 160.0  ## m: a zone blocker in sight this close stops the walk there (_blocker_in_sight)
const BLOCKER_WAIT := 4.0     ## s holding a flag without progress, with an enemy inside its ring, before hunting it  ## m grid inside a zone searched for a point that sees an elevated blocker
const BONUS_GIVE_UP := 240.0   ## s on one bonus before it is skipped
const ESCORT_OFF := 0.4        ## co-op: an escort holds this share of the radius off the centre
const LOW_HP := 0.45           ## holding: weakest core part under this share -> cover inside the zone
const DEFEND_LOW_HP := 0.3     ## ...defending only under this (the relay needs the mech out front)
const PRESSURE_DROP := 0.15    ## ...or losing this share of it within PRESSURE_WIN s
const PRESSURE_WIN := 3.0
const COVER_IN := 0.85         ## cover lies within this share of the zone's radius from its centre
const COVER_RECHECK := 2.0     ## s between checks that the cover still hides it
const COVER_THREAT_R := 160.0  ## m: enemies this close count as threats to hide from
## SKILL (BotProfile mission keys, read once in _ready from the pilot's profile; veteran's equal the constants above, so
## veteran-pinned timings hold): survival_hp (for LOW_HP; a defend hides under survival_hp x DEFEND_LOW_HP / LOW_HP),
## hunt_patience (for HUNT_AFTER), engage_radius (for ENGAGE; out past engage_radius x ENGAGE_OUT / ENGAGE),
## travel_dodge (share of PlayerBot's telegraph dodges honoured while travelling: the legs are PlayerBot's for the dodge,
## with the cut veto), revive_priority (kept for revive, not built yet).
const REPAIR_AT := 0.6         ## weakest core part under this: launch a repair drone if the loadout has one
const ADVANCE_WAIT := 1.5      ## s with nothing left on a deck before moving on (a chained bonus shows up a tick late)

## Tests: plan with ramps only (no shaft drops or glides), to exercise the ramp legs.
static var ramps_only := false
## Tests / A-B: the hole guard (_guard_holes) and the hold survival (cover in the zone, repair drone) on.
static var hole_guard := true
static var survival := true
## Plan mode: do the known bonus objectives of a deck after its primary (tests may turn this off for speed).
static var bonuses := true
## Tests: let a hop-only body (the Bulwark) plan glides anyway (measuring whether its 1 m/s sink above the thrust
## ceiling carries it over an atrium); off, its planner leaves every glide out (BotRoutePlanner.fit_body).
static var hop_glides := false

var drive: MissionScene
var body_mech: MechController   ## the mech it drives (drive.mech, or a crew bot's)
var body_rack: WeaponRack       ## that mech's rack
var body_pt: PlayerTarget       ## that mech's PlayerTarget
var crew_bot := false           ## a host-run hangar bot (attach_crew), not the local mech
var pilot: MissionBotPilot
var planner: BotRoutePlanner
var mode := ""                ## "fight" | "travel" | "idle"
var goal_text := ""           ## what it is doing (logs, tests)
var _nav: BotNavigator        ## whisker avoidance only
var _navs: Array = []         ## per deck: BotNavigator on that deck's plan (its roofs, the thruster climb)
var _perch: Dictionary = {}   ## fighting: the roof being climbed to see the target (BotNavigator roof entry)
var _perch_t := 0.0           ## s since the perch was chosen
var _perch_hold := 0.0        ## s standing on it
var _perch_prog_t := 0.0      ## s since the climb last got anywhere (PERCH_STALL)
var _perch_best := Vector2.INF   ## (flat distance to the roof, height) at the last progress
var _bad_perch: Dictionary = {}  ## roof key -> t its climb last stalled (PERCH_RETRY)
var _perch_anchor := Vector3.ZERO   ## where the climb was when it last moved 2 m
var perch_fails := 0          ## climbs given up for stalling (tests)
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
var _esc_t := 0.0             ## s of wedge escape left (_wedge_watch)
var _esc_dir := Vector3.ZERO
var _esc_spot := Vector3.INF  ## where the last escape started
var _esc_n := 0               ## escapes from _esc_spot
var _esc_try := 0             ## which ESCAPE_TURNS direction the escape is on
var _esc_base := Vector3.ZERO ## the escape's "away" direction
var _esc_from := Vector3.ZERO ## where this escape direction started
var _esc_mark := 0.0          ## the stall clock at the last escape (the next comes WEDGE_AFTER s later)
var _avoid: Dictionary = {}   ## deck -> [Rect2] wedge spots the legs keep off (like the depots, _solids)
var wedge_escapes := 0        ## stats: escapes started
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
var _hunt_hp := 0.0           ## the hunted enemy's structure when it last took damage
var _hunt_spot := Vector3.INF ## a flag / hold zone point that sees the hunted (elevated) blocker, or INF
var _blocker: Variant = null  ## the current flag / hold's nearest blocker (PlayerBot priority), untyped (may be freed)
var _blocker_t := 0.0         ## s to the next blocker look-up
var _hunt_blocks := false     ## the hunted enemy stands in the zone (it stops the capture: kept to HUNT_GIVE_UP, vantage / perch)
var _hunt_dry := 0.0          ## s of the hunt without damage to it
var _hunt_skip: Dictionary = {}   ## enemy instance id -> s left before it may be hunted again (a dry hunt)
var _focus_hp := -1.0         ## _fight: the focus enemy's structure last frame (a hit on it is progress)
var _focus_id := 0            ## _fight: which enemy _focus_hp is of
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
var local_fits := 0           ## ...of which took the capsule-fit fallback (no roomy point near enough)
var hop_vetoes := 0           ## frames a thruster hop toward a floor cut lost its thrust (_guard_holes)
var drones := 0               ## repair drones launched (_use_repair)
var covers := 0               ## covers taken while holding a zone (tests)
var _cover_pt := Vector3.INF  ## holding and in trouble: the cover point inside the zone
var _cover_t := 0.0
var survival_hp := LOW_HP     ## the profile's (see SKILL above)
var hunt_patience := HUNT_AFTER
var engage_radius := ENGAGE
var travel_dodge := 0.0
var revive_priority := 0.8
var travel_dodges := 0          ## telegraph dodges taken while travelling (tests)
var _dodge_seen := false        ## PlayerBot was dodging last frame (travelling)
var _dodge_ok := false          ## ...and this dodge is honoured
var depot_visits := 0         ## times it went for a supply depot (tests)
var revives := 0              ## downed crewmates it stood up (tests)
var revive_declines := 0      ## revives it turned down (hot wreck while low, too many threats; tests)
var revive_log: Array = []    ## [{t, peer, kind: go | done | gone | decline | gave_up, why}] (tests, report)
var _rv_peer := 0             ## the downed crewmate it is going to revive (0 = none)
var _rv_t := 0.0              ## s since it set off
var _rv_spot := Vector3.INF   ## where it stands for the revive (a covered spot within REVIVE_STAND of the wreck)
var _rv_skip: Dictionary = {} ## pilot id -> t until which it doesn't reconsider that wreck (declined / gave up)
var _depot := ""                ## plan mode: the supply depot it is walking to ("" = none)
var _depot_t := 0.0             ## s since it set off for it
var _depot_cd := 0.0            ## s before it looks for a depot again (after a core, a give-up)
var _depot_bad: Dictionary = {}  ## depot id -> t until which it is not tried again (a give-up there)
var _solid_rects: Dictionary = {}  ## deck -> [Rect2] depot footprints the legs keep clear of (_solids)
var _hp_hist: Array = []      ## [[t, weakest core part]] over PRESSURE_WIN s
## CHASSIS (read once in _ready from the body's MechCatalog movement block; the Strider's give the constants above, so
## Strider behaviour is unchanged): a WIDE body (capsule radius over the Strider's 2.2, the Bulwark's 3.6) widens the
## grid plan's side rays and the stand / cover room by the extra radius and keeps the route off road lines its capsule
## does not pass (BotRoutePlanner.body_r + fit_body); a HOP-ONLY body (MechCatalog.bot_hop_height > 0) never glides and never
## climbs a roof above its hop (perches, PlayerBot's vantages: BotNavigator.drop_roofs_above); a slower turn stretches
## the stuck window (turning on the spot is not being stuck).
var body_r := 2.2
var hop_only := false
var local_side := LOCAL_SIDE
var roomy := ROOMY
var stuck_win := STUCK_WIN
var veto_grow := VETO_GROW      ## VETO_GROW + the extra radius: a wide body's edge keeps as far from a floor cut
const STRIDER_R := 2.2         ## m: the capsule the constants above were tuned for
const STRIDER_TURN := 1.8      ## rad/s: the turn rate the stuck window was tuned for


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "body_mech": Net.LOCAL, "body_rack": Net.LOCAL, "body_pt": Net.LOCAL, "crew_bot": Net.SPAWN,
		"pilot": Net.LOCAL, "planner": Net.LOCAL, "mode": Net.PRIVATE, "goal_text": Net.PRIVATE,
		"_nav": Net.PRIVATE, "_navs": Net.PRIVATE, "_perch": Net.PRIVATE, "_perch_t": Net.PRIVATE, "_perch_hold": Net.PRIVATE, "_perch_prog_t": Net.PRIVATE, "_perch_best": Net.PRIVATE, "_bad_perch": Net.PRIVATE, "perch_fails": Net.PRIVATE, "_perch_anchor": Net.PRIVATE, "_vantage_kind": Net.PRIVATE, "_rng": Net.PRIVATE, "_deck": Net.PRIVATE, "_legs": Net.PRIVATE, "_leg_i": Net.PRIVATE,
		"_seg_i": Net.PRIVATE, "_route_key": Net.PRIVATE, "_route_goal": Net.PRIVATE, "_route_t": Net.PRIVATE,
		"_target": Net.LOCAL, "_target_t": Net.PRIVATE, "_mode_t": Net.PRIVATE, "_said": Net.PRIVATE,
		"_status_t": Net.PRIVATE, "_last_pos": Net.PRIVATE, "_stk_t": Net.PRIVATE, "_stk_rem": Net.PRIVATE,
		"_stk_n": Net.PRIVATE, "_stk_pos": Net.PRIVATE, "_backup_t": Net.PRIVATE, "_backup_dir": Net.PRIVATE, "_hop_t": Net.PRIVATE, "_esc_t": Net.PRIVATE, "_esc_dir": Net.PRIVATE, "_esc_spot": Net.PRIVATE, "_esc_n": Net.PRIVATE, "_esc_try": Net.PRIVATE, "_esc_base": Net.PRIVATE, "_esc_from": Net.PRIVATE, "_esc_mark": Net.PRIVATE, "_avoid": Net.PRIVATE, "wedge_escapes": Net.PRIVATE,
		"_fight_t": Net.PRIVATE, "_no_los_t": Net.PRIVATE, "_alive_prev": Net.PRIVATE, "_vantage": Net.PRIVATE,
		"_tried": Net.PRIVATE, "_vantage_cd": Net.PRIVATE, "_at_vantage_t": Net.PRIVATE, "_roof_t": Net.PRIVATE, "_roof_anchor": Net.PRIVATE, "_roof_tries": Net.PRIVATE, "_roof_log_t": Net.PRIVATE, "_roof_out": Net.PRIVATE, "_roof_span": Net.PRIVATE, "roof_max": Net.PRIVATE, "stall_max": Net.PRIVATE, "_stall_t": Net.PRIVATE, "_stall_anchor": Net.PRIVATE, "last_dir": Net.PRIVATE, "t": Net.PRIVATE, "deck_changes": Net.PRIVATE,
		"stuck_events": Net.PRIVATE, "blocked_edges": Net.PRIVATE, "replans": Net.PRIVATE,
		"dev_travel": Net.PRIVATE, "dev_jumps": Net.PRIVATE, "_prog_key": Net.PRIVATE, "_prog_best": Net.PRIVATE,
		"_prog_t": Net.PRIVATE, "_prog_alive": Net.PRIVATE, "_last_dev_jump_t": Net.PRIVATE,
		"work_deck": Net.PRIVATE, "task_id": Net.PRIVATE, "role": Net.PRIVATE, "task_log": Net.PRIVATE, "ff_holds": Net.PRIVATE,
		"_task_t": Net.PRIVATE, "_skipped": Net.PRIVATE, "_hunt": Net.LOCAL, "_hunt_t": Net.PRIVATE, "_hunt_hp": Net.PRIVATE, "_hunt_spot": Net.PRIVATE, "_hunt_blocks": Net.PRIVATE, "_blocker": Net.LOCAL, "_blocker_t": Net.PRIVATE, "_hunt_dry": Net.PRIVATE, "_hunt_skip": Net.PRIVATE, "_focus_hp": Net.PRIVATE, "_focus_id": Net.PRIVATE, "_quiet_t": Net.PRIVATE,
		"_stuck_prog_t": Net.PRIVATE, "_prog_last": Net.PRIVATE, "_holding": Net.PRIVATE, "role_index": Net.PRIVATE,
		"_advance_t": Net.PRIVATE, "_stand_key": Net.PRIVATE, "_stand_pt": Net.PRIVATE, "local_plans": Net.PRIVATE,
		"local_fails": Net.PRIVATE, "local_fits": Net.PRIVATE, "hop_vetoes": Net.PRIVATE, "drones": Net.PRIVATE,
		"covers": Net.PRIVATE, "_cover_pt": Net.PRIVATE, "_cover_t": Net.PRIVATE, "_hp_hist": Net.PRIVATE,
		"survival_hp": Net.SPAWN, "hunt_patience": Net.SPAWN, "engage_radius": Net.SPAWN, "travel_dodge": Net.SPAWN,
		"revive_priority": Net.SPAWN, "travel_dodges": Net.PRIVATE, "depot_visits": Net.PRIVATE, "_depot": Net.PRIVATE,
		"_depot_t": Net.PRIVATE, "_depot_cd": Net.PRIVATE, "_depot_bad": Net.PRIVATE, "_solid_rects": Net.LOCAL,
		"revives": Net.PRIVATE, "revive_declines": Net.PRIVATE, "revive_log": Net.PRIVATE, "_rv_peer": Net.PRIVATE,
		"_rv_t": Net.PRIVATE, "_rv_spot": Net.PRIVATE, "_rv_skip": Net.PRIVATE, "_dodge_seen": Net.PRIVATE, "_dodge_ok": Net.PRIVATE,
		"body_r": Net.PRIVATE, "hop_only": Net.PRIVATE, "local_side": Net.PRIVATE, "roomy": Net.PRIVATE, "stuck_win": Net.PRIVATE, "veto_grow": Net.PRIVATE}


## MissionScene calls this once its scene is set up (and the stack built).
static func attach(td: MissionScene, profile: String) -> MissionBot:
	var mb := MissionBot.new()
	mb.name = "MissionBot"
	mb.drive = td
	mb.body_mech = td.mech
	mb.body_rack = td.combat.rack if td.combat != null else null
	mb.body_pt = td.combat.player_target if td.combat != null else null
	mb.pilot = MissionBotPilot.attach(td)
	mb.pilot.set_profile(profile if BotProfile.has_profile(profile) else "veteran")
	mb.pilot.set_active(true)
	mb.dev_travel = OS.get_cmdline_user_args().has("--dev-bot-travel") or MissionScene.dev_bot_travel
	td.add_child(mb)
	return mb


## A host-run hangar bot: the AI drives `m` (its rack `r`, its PlayerTarget `t`, pilot id `id` < 0) with skill `profile`.
## Added as a child of `parent` (the bot's CrewBot node).
static func attach_crew(td: MissionScene, parent: Node, m: MechController, r: WeaponRack, t: PlayerTarget, id: int,
		profile: String) -> MissionBot:
	var mb := MissionBot.new()
	mb.name = "MissionBot"
	mb.drive = td
	mb.body_mech = m
	mb.body_rack = r
	mb.body_pt = t
	mb.crew_bot = true
	var p := MissionBotPilot.new()
	p.name = "BotPilot"
	p.drive = td
	p.body = {"mech": m, "rack": r, "pt": t, "id": id}
	parent.add_child(p)
	mb.pilot = p
	p.set_profile(profile if BotProfile.has_profile(profile) else "veteran")
	p.set_active(true)
	mb.dev_travel = MissionScene.dev_bot_travel or OS.get_cmdline_user_args().has("--dev-bot-travel")
	parent.add_child(mb)
	return mb


## SUPPLY DEPOTS (plan mode, MissionDepots; docs/design/pacing-director.md §2): a core repairs half the missing structure,
## rebuilds destroyed parts at 30 %, refills ammo and vents heat; standing within CLAIM_RANGE of a depot for CLAIM_TIME s
## takes it (the local pilot's own claim, or the host's claim for a hangar bot while MissionDepots.needs_core says so).
## The bot goes for the nearest depot with cores on its deck (within DEPOT_RANGE) when MissionDepots.needs_core_of holds
## (structure < 70 %, a part destroyed or a weapon unusable) AND it is hurt past its profile or disarmed (_depot_wanted). It walks there (the route planner, then straight in over the last
## stretch planned on the physics grid like a zone), stands in range while PlayerBot keeps aiming and firing, and goes back to the objective once the core
## is in (or the depot ran dry, or DEPOT_GIVE_UP s passed: then DEPOT_CD s before the next look, and that depot is left
## alone DEPOT_BAD s).
const DEPOT_RANGE := 160.0
const DEPOT_MARGIN := 0.05
const DEPOT_STRUCT := 0.5
const DEPOT_ZONE := 10.0       ## m: the depot as a zone for the grid plan (a stand point within STAND_IN of it)
const DEPOT_STAND := 5.5       ## m from the footprint it stops at (MissionDepots.CLAIM_RANGE is 6; the leg veto keeps it 4 m out)
const DEPOT_BAD := 120.0       ## s a depot it gave up on is left alone
const DEPOT_GIVE_UP := 35.0
const DEPOT_CD := 8.0
const SOLID_PAD := 1.0         ## m around a depot's footprint the legs keep out of (on top of VETO_GROW)


## The depot goal {deck, at, key, text, enemy: false, depot: id}, or {} when it doesn't need one / there is none.
func _depot_goal(k: int, dt: float) -> Dictionary:
	_depot_cd = maxf(_depot_cd - dt, 0.0)
	var md: MissionDepots = drive.mission.depots if drive.mission != null else null
	if md == null or body_pt == null or body_pt.disabled:
		_depot = ""
		return {}
	var needs := MissionDepots.needs_core_of(body_pt, body_rack)
	if _depot != "":
		_depot_t += dt
		if not needs or not md.has_cores(_depot) or _depot_t > DEPOT_GIVE_UP:
			FlowLog.say("bot depot", "%s %s after %.0f s" % ["done at" if not needs else "gave up", _depot, _depot_t])
			if needs:
				_depot_bad[_depot] = t + DEPOT_BAD   # couldn't get a core there: not that one again for a while
			_depot = ""
			_depot_cd = DEPOT_CD
			_clear_route()
			return {}
	elif _depot_cd <= 0.0 and needs and _depot_wanted():
		var near := md.nearest_with_cores(k, body_mech.global_position)
		if not near.is_empty() and t < float(_depot_bad.get(str(near["id"]), -1.0)):
			near = {}
		if not near.is_empty() and body_r > STRIDER_R + 0.01 and not bool((md.sites[str(near["id"])] as Dictionary).get("ok", true)):
			# A wide body skips a depot MissionDepots could only place by the plain snap (no clear site off the roads):
			# seed 22's d1_depot1 sat inside a block and wedged the Bulwark walking in for 110 s.
			_depot_bad[str(near["id"])] = t + DEPOT_BAD * 10.0
			near = {}
		if not near.is_empty() and float(near["dist"]) < DEPOT_RANGE:
			_depot = str(near["id"])
			_depot_t = 0.0
			depot_visits += 1
			_clear_route()
			FlowLog.say("bot depot", "to %s (%.0f m): weakest core %.0f %%, structure %.0f %%, guns %d" % [_depot,
				float(near["dist"]), _core_hp() * 100.0, _structure() * 100.0, _usable_guns()])
	if _depot == "":
		return {}
	var at := md.depot_pos(_depot)
	# "zone": the last stretch is planned on the physics grid to a stand point near the depot (_plan_local), as for a
	# flag: depots stand on plazas and in courts the street graph doesn't reach.
	return {"deck": int(md.sites[_depot]["deck"]), "at": at, "key": "depot_" + _depot, "text": "to supply depot",
		"enemy": false, "depot": _depot, "zone": DEPOT_ZONE}


## Worth a core now (MissionDepots.needs_core_of already holds): hurt past the profile's survival_hp (+ DEPOT_MARGIN),
## the structure under DEPOT_STRUCT, or no gun left; holding an objective zone (it may be at risk), only under survival_hp
## itself or with no gun left. (A dry rocket pod or a lost pod alone is not worth the walk: measured, those detours cost
## the hold test 150 s.)
func _depot_wanted() -> bool:
	if mode == "hold" or _holding:   # an objective zone: it goes only in real trouble
		return _core_hp() < survival_hp or _usable_guns() == 0
	return _core_hp() < survival_hp + DEPOT_MARGIN or _structure() < DEPOT_STRUCT or _usable_guns() == 0


func _structure() -> float:
	if body_pt == null or body_pt.total_max_hp() <= 0.0:
		return 1.0
	return body_pt.total_hp() / body_pt.total_max_hp()


func _usable_guns() -> int:
	var n := 0
	if body_rack == null:
		return 0
	for i in body_rack.slot_count():
		if body_rack.weapons[i] != "" and not MechCatalog.is_equipment(body_rack.weapons[i]) and body_rack.usable(i + 1):
			n += 1
	return n


## In claim range of the depot (same deck): stand still there (PlayerBot keeps the aim and the trigger) until the core
## is in. True when this handled the legs; else the travel (street route, then the grid plan to a stand point) goes on.
func _depot_near(k: int, dep: Dictionary) -> bool:
	if int(dep["deck"]) != k:
		return false
	var md: MissionDepots = drive.mission.depots
	var mech := body_mech
	if md.depot_in_range(mech.global_position, DEPOT_STAND) != str(dep["depot"]):
		return false
	_set_mode("depot", "at supply depot", "supply depot %s on deck %d" % [str(dep["depot"]), k])
	mech.move_input = Vector2.ZERO
	mech.running = false
	mech.thrust_input = false
	return true


## REVIVE (docs/design/pacing-director.md §4, DownedCrew / DownedRules): a downed crewmate stays down until a standing
## crewmate's repair drone beams it for REVIVE_TIME s within its radius (15 m of the launcher). This bot goes when it can
## revive (DownedCrew.can_revive: a drone with a charge or one on duty, back mount intact) and a revivable wreck
## (downed_crew, not itself) is on its deck within REVIVE_REACH, weighed by _revive_score: revive_priority, minus the
## distance's share of REVIVE_REACH (x 0.3), minus REVIVE_HOLD_COST while holding an objective zone and REVIVE_HURT_COST
## under survival_hp; it goes above REVIVE_GO. It leaves the wreck to a crewmate who can revive and is REVIVE_LEAVE m
## nearer (nearest_reviver), and DECLINES (logged) a hot wreck: REVIVE_HOT_COUNT or more live enemies within REVIVE_HOT_R
## of it, or REVIVE_HOT_LOW of them while its own weakest core is under survival_hp. It walks there (route, then the grid
## plan), stands within REVIVE_STAND m (a covered spot when threats see it), launches its drone once (none out: two never
## stack, and a drone never revives its own launcher), keeps fighting (PlayerBot aims and fires, BotFireGuard has the last
## word), and is done when the wreck is no longer listed (stood up: counted in `revives`; or redeploying). REVIVE_GIVE_UP s
## at most; a declined / given-up wreck is left alone REVIVE_SKIP s.
const REVIVE_REACH := 220.0
const REVIVE_GO := 0.25
const REVIVE_HOLD_COST := 0.3
const REVIVE_HURT_COST := 0.3
const REVIVE_LEAVE := 15.0
const REVIVE_HOT_R := 45.0
const REVIVE_HOT_COUNT := 5
const REVIVE_HOT_LOW := 2
const REVIVE_STAND := 10.0
const REVIVE_GIVE_UP := 60.0
const REVIVE_SKIP := 20.0


## This bot's pilot id.
func _my_id() -> int:
	return MechSpawn.owner_of(body_mech)


## The revive goal {deck, at, key, text, enemy: false, zone, revive: pilot id}, or {}.
func _revive_goal(k: int, dt: float) -> Dictionary:
	var dc: DownedCrew = drive.downed
	if dc == null or body_pt == null or body_pt.disabled:
		_rv_peer = 0
		return {}
	var me := _my_id()
	var listed := {}
	for w: Dictionary in dc.downed_crew():
		listed[int(w["peer"])] = w
	if _rv_peer != 0:
		_rv_t += dt
		if not listed.has(_rv_peer):
			var tgt := dc.target_of(_rv_peer)
			var stood := tgt != null and not tgt.disabled
			if stood:
				revives += 1
			_revive_end("done" if stood else "gone", "")
			return {}
		if _rv_t > REVIVE_GIVE_UP or not dc.can_revive(me):
			_revive_end("gave_up", "%.0f s" % _rv_t, true)
			return {}
		var hot := _revive_hot(listed[_rv_peer]["pos"] as Vector3, k)
		if hot != "":
			revive_declines += 1
			_revive_end("decline", hot, true)
			return {}
	elif dc.can_revive(me):
		var best := 0
		var best_s := -INF
		for pid: int in listed:
			if pid == me or t < float(_rv_skip.get(pid, -1.0)):
				continue
			var at: Vector3 = listed[pid]["pos"]
			if drive.stack.deck_at(at) != k:
				continue
			var d := _flat(at - body_mech.global_position, body_mech.up()).length()
			if d > REVIVE_REACH:
				continue
			var nr := dc.nearest_reviver(pid)
			if not nr.is_empty() and int(nr["peer"]) != me and float(nr["dist"]) + REVIVE_LEAVE < d:
				continue   # a crewmate who can revive is nearer: theirs
			var sc := _revive_score(d)
			if sc <= REVIVE_GO:
				continue
			var hot := _revive_hot(at, k)
			if hot != "":
				revive_declines += 1
				_rv_skip[pid] = t + REVIVE_SKIP
				_revive_note("decline", pid, hot)
				continue
			if sc > best_s:
				best_s = sc
				best = pid
		if best != 0:
			_rv_peer = best
			_rv_t = 0.0
			_rv_spot = Vector3.INF
			_clear_route()
			_revive_note("go", best, "%.0f m, score %.2f" % [_flat((listed[best]["pos"] as Vector3) - body_mech.global_position,
				body_mech.up()).length(), best_s])
	if _rv_peer == 0:
		return {}
	var wreck: Vector3 = listed[_rv_peer]["pos"]
	return {"deck": drive.stack.deck_at(wreck), "at": wreck, "key": "revive_%d" % _rv_peer, "text": "to revive a crewmate",
		"enemy": false, "zone": REVIVE_STAND * 2.0, "revive": _rv_peer}


func _revive_end(kind: String, why: String, skip: bool = false) -> void:
	_revive_note(kind, _rv_peer, why)
	if skip:
		_rv_skip[_rv_peer] = t + REVIVE_SKIP
	_rv_peer = 0
	_rv_spot = Vector3.INF
	_clear_route()


## revive_priority weighed against the walk, the objective and its own health.
func _revive_score(d: float) -> float:
	var sc := revive_priority - 0.3 * clampf(d / REVIVE_REACH, 0.0, 1.0)
	if _holding or mode == "hold":
		sc -= REVIVE_HOLD_COST
	if _core_hp() < survival_hp:
		sc -= REVIVE_HURT_COST
	return sc


## Why the wreck at `at` is too hot to go to ("" = not): REVIVE_HOT_COUNT live enemies within REVIVE_HOT_R of it, or
## REVIVE_HOT_LOW while this bot is under survival_hp.
func _revive_hot(at: Vector3, k: int) -> String:
	var n := 0
	for e: Variant in (drive.combat.squad.enemies as Array):
		if _live_on(e, k) and (e as EnemyBase).global_position.distance_to(at) < REVIVE_HOT_R:
			n += 1
	if n >= REVIVE_HOT_COUNT:
		return "%d enemies at the wreck" % n
	if n >= REVIVE_HOT_LOW and _core_hp() < survival_hp:
		return "%d enemies at the wreck, own core %d %%" % [n, roundi(_core_hp() * 100.0)]
	return ""


func _revive_note(kind: String, pid: int, why: String) -> void:
	revive_log.append({"t": snappedf(t, 0.1), "peer": pid, "kind": kind, "why": why})
	FlowLog.say("bot revive", "%s pilot %d%s" % [kind, pid, (": " + why) if why != "" else ""])


## Within REVIVE_STAND of the wreck (same deck): stand (on a covered spot when enemies see it), launch the drone once
## (none out), keep fighting. True when this handled the legs.
func _revive_near(k: int, rv: Dictionary) -> bool:
	if int(rv["deck"]) != k:
		return false
	var mech := body_mech
	var up := mech.up()
	var wreck: Vector3 = rv["at"]
	if _flat(wreck - mech.global_position, up).length() > REVIVE_STAND + 2.0:
		return false
	_set_mode("revive", "reviving a crewmate", "revive pilot %d on deck %d" % [int(rv["revive"]), k])
	if _rv_spot == Vector3.INF:
		var eyes := _threats(k)
		_rv_spot = _pick_cover(k, mech.global_position, wreck, REVIVE_STAND / COVER_IN, eyes) if not eyes.is_empty() else Vector3.INF
		if _rv_spot == Vector3.INF:
			_rv_spot = mech.global_position
	var off := _flat(_rv_spot - mech.global_position, up)
	if off.length() > 1.5 and _flat(_rv_spot - wreck, up).length() <= REVIVE_STAND:
		var b := mech.global_transform.basis
		var dir := _veto(k, off.normalized())
		mech.move_input = Vector2(dir.dot(b.x), -dir.dot(b.z)).limit_length(1.0)   # PlayerBot keeps the facing
	else:
		mech.move_input = Vector2.ZERO
	mech.running = false
	mech.thrust_input = false
	if body_rack != null and not body_rack.drone_out():
		for i in body_rack.slot_count():
			if body_rack.weapons[i] == DownedRules.REVIVER and body_rack.can_launch(i) and body_rack.activate(i + 1):
				drones += 1
				FlowLog.say("bot revive", "drone out for pilot %d" % int(rv["revive"]))
				break
	return true


## The body's chassis (see CHASSIS above): the Strider leaves every value at its constant.
func _load_chassis() -> void:
	var mv := MechCatalog.movement(body_mech.chassis_id if body_mech != null else "strider")
	body_r = float(mv["capsule_radius"])
	hop_only = MechCatalog.bot_hop_height(body_mech.chassis_id if body_mech != null else "strider") > 0.0
	var extra := maxf(body_r - STRIDER_R, 0.0)
	local_side = LOCAL_SIDE + extra
	roomy = ROOMY + extra
	veto_grow = VETO_GROW + extra
	stuck_win = STUCK_WIN * maxf(STRIDER_TURN / maxf(float(mv["turn_rate"]), 0.1), 1.0)


## The pilot's profile's mission keys (BotProfile; a missing key keeps the veteran constant).
func _load_skill() -> void:
	var pf := BotProfile.get_profile(pilot.profile_id if pilot != null else "veteran")
	survival_hp = float(pf.get("survival_hp", LOW_HP))
	hunt_patience = float(pf.get("hunt_patience", HUNT_AFTER))
	engage_radius = float(pf.get("engage_radius", ENGAGE))
	travel_dodge = float(pf.get("travel_dodge", 0.0))
	revive_priority = float(pf.get("revive_priority", 0.8))


## Travelling and PlayerBot started dodging a telegraph: honour the dodge with chance travel_dodge (rolled once per
## dodge; no roll at all at 0, so a profile without travel dodges keeps its random sequence). True while the legs are
## PlayerBot's (only the cut veto applies).
func _travel_dodge(k: int) -> bool:
	if travel_dodge <= 0.0:
		return false
	var pb := pilot.bot if pilot != null else null
	var dodging := pb != null and is_instance_valid(pb) and pb.ai_state == PlayerBot.STATE_DODGE
	if dodging and not _dodge_seen:
		_dodge_ok = _rng.randf() < travel_dodge
		if _dodge_ok:
			travel_dodges += 1
	_dodge_seen = dodging
	if not (dodging and _dodge_ok):
		return false
	_veto_inputs(k)
	return true


## The camera to sync PlayerBot's look to: the local mech's only.
func _cam() -> ChaseCamera:
	return null if crew_bot else drive.cam


func _ready() -> void:
	process_physics_priority = -19   # after PlayerBot (-20) chose its inputs, before the mech steps
	_load_skill()
	var who := MechSpawn.owner_of(body_mech) if crew_bot else (Net.session().local_id() if Net.session() != null else 0)
	_rng.seed = hash(["mission_bot", drive.seed_value, who])
	_load_chassis()
	_nav = BotNavigator.new()
	_nav.setup(null, null, _rng)
	if drive.stack != null:
		for k in drive.stack.decks.size():
			var nv := BotNavigator.new()
			nv.setup(drive.stack.decks[k].plan, drive.stack.deck_ring(k), _rng)
			if hop_only:
				nv.drop_roofs_above(MechCatalog.bot_hop_height(body_mech.chassis_id) - PlayerBot.HOP_ROOF_MARGIN)
			_navs.append(nv)
	if drive.stack != null:
		planner = BotRoutePlanner.new()
		var wide := body_r > STRIDER_R + 0.01
		if wide:
			planner.body_r = body_r
		planner.setup(drive.stack)
		planner.no_drops = ramps_only
		if wide or hop_only:
			var fr := planner.fit_body(body_mech.get_world_3d().direct_space_state, body_r,
				float(MechCatalog.movement(body_mech.chassis_id)["capsule_height"]), MechCatalog.bot_hop_height(body_mech.chassis_id) if hop_only and not hop_glides else 0.0)
			FlowLog.say("bot fit", "%s (capsule %.1f m%s): %d road edges, %d ramp legs, %d glides left out (%d probes) %s" % [
				body_mech.chassis_id, body_r, ", hop-only" if hop_only else "", int(fr["blocked"]), int(fr.get("ramps", 0)),
				int(fr["glides"]), int(fr["probes"]), str(fr.get("where", []))])
	var sm := planner.summary() if planner != null else {}
	FlowLog.say("bot on", "profile %s, route graph %s%s" % [pilot.profile_id, str(sm),
		", DEV travel jumps on" if dev_travel else ""])


## For tests and the report.
func stats() -> Dictionary:
	var by := {}
	for c: Dictionary in deck_changes:
		by[c["by"]] = int(by.get(c["by"], 0)) + 1
	return {"dev_jumps": dev_jumps, "deck_changes": deck_changes.duplicate(true), "by": by, "stuck": stuck_events,
		"blocked": blocked_edges, "wedge_escapes": wedge_escapes, "replans": replans, "t": t, "roof_max": snappedf(roof_max, 0.1),
		"stall_max": snappedf(stall_max, 0.1), "tasks": task_log.duplicate(true), "ff_holds": ff_holds, "perch_fails": perch_fails,
		"local_plans": local_plans, "local_fails": local_fails, "local_fits": local_fits, "hop_vetoes": hop_vetoes, "drones": drones, "covers": covers,
		"profile": pilot.profile_id if pilot != null else "", "travel_dodges": travel_dodges, "depot_visits": depot_visits,
		"revives": revives, "revive_declines": revive_declines, "revive_log": revive_log.duplicate(true)}


func _physics_process(dt: float) -> void:
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd), off in play
	_step(dt)
	_wedge_watch(dt)
	if hole_guard:
		_guard_holes()
	if survival:
		_use_repair()
	_ff_guard()   # the last word on the trigger, whatever path chose it
	if PerfProbe.on:
		PerfProbe.add("bot.mission", Time.get_ticks_usec() - pp0)


## Last word on the legs every frame, whoever chose them (this layer, PlayerBot fighting / dodging / taking cover, or
## PlayerBot alone while idle): keep them out of the floor cuts (shafts, ramp holes) of the deck the mech is on, unless
## the current leg means to go down one (a ramp, a shaft drop, a glide). A thruster hop whose next second of flight ends
## over a cut loses its thrust.
func _guard_holes() -> void:
	if drive == null or drive.loading or body_mech == null or drive.stack == null or planner == null or drive.held:
		return
	if _leg_i < _legs.size() and str(_legs[_leg_i]["kind"]) != "walk":
		return
	var mech := body_mech
	var k := drive.stack.deck_at(mech.global_position)
	if k < 0 or k >= planner.cuts.size():
		return
	_veto_inputs(k)
	if mech.thrust_input:
		var up := mech.up()
		var ahead := mech.global_position + _flat(mech.velocity, up)
		var a := _arc_on(k, ahead)
		if planner.in_cut(k, Vector2(float(a["x"]), float(a["s"])), veto_grow):
			mech.thrust_input = false
			hop_vetoes += 1


func _step(dt: float) -> void:
	if drive == null or drive.loading or body_mech == null or drive.stack == null or drive.mission == null:
		return
	if drive.held:
		return   # the barrier hasn't passed: stand still like everyone else
	var mech := body_mech
	t += dt
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
	var pt := body_pt if drive.combat != null else null
	if (pt != null and pt.disabled) or mech.shutdown:
		return   # PlayerBot holds still while downed / shut down
	_replan_tick(dt)
	_target_t += dt
	_mode_t += dt
	_obj_tick(dt)
	var goal := _goal(k)
	var dep := _depot_goal(k, dt)
	if not dep.is_empty():
		if _depot_near(k, dep):
			return
		goal = dep
	var rv := _revive_goal(k, dt) if _depot == "" else {}
	if not rv.is_empty():
		if _revive_near(k, rv):
			return
		goal = rv
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
			_zone_hold(k, at, zr, dt, goal)
			return
	_holding = false
	# Fight near the target (hysteresis: in at ENGAGE, out past ENGAGE_OUT), or once the road there has run out.
	var road_done := mode == "travel" and _route_key.begins_with(str(goal["key"]) + "@") and not _legs.is_empty() \
		and _leg_i >= _legs.size()
	var fight := not in_special and enemy and t_deck == k and (dist < (engage_radius * ENGAGE_OUT / ENGAGE if mode == "fight" \
		else engage_radius) or road_done)
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
	# A body halfway along a ramp keeps to the ramp when the goal changes (a depot, a revive, the next objective): a
	# re-plan from the slope pointed it at the parapet (Bulwark seed 4; every chassis since Strider hold seed 6, a depot detour).
	var keep_ramp := in_special and _leg_i < _legs.size() and str(_legs[_leg_i]["kind"]) == "ramp"
	if not keep_ramp and (key != _route_key or (_legs.is_empty() and _route_t > 1.0 and (t_deck != k or dist > ARRIVE * 2.0))):
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
	if _travel_dodge(k):
		return
	if _blocker_in_sight(k):
		# On the way to a flag / hold with its blocker in sight (a roof turret is often seen only from afar): stop and
		# let PlayerBot shoot it rather than walk in under it (seed 6).
		_veto_inputs(k)
		return
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
	if rules.plan == null:
		return {}   # no plan (TEST-ONLY quiet fixture): nothing to do
	return _plan_goal(k)


## The last stretch to a zone on deck k, planned on a LOCAL_STEP grid of street-level points around the zone's centre
## (a point counts when a ray down from 3.5 m finds floor within 1.2 m of the deck's floor, not from inside a solid,
## with headroom above it, outside floor
## cuts; two neighbours connect when rays at 2.5 and 5.5 m between them, in the middle and LOCAL_SIDE to each side, are clear). Breadth-first from the mech to the
## grid point within STAND_IN of the radius nearest the goal's point (an escort's offset). Sets the stand point (the hold
## centre from then on) and one walk leg along the path. False when the mech is off the grid or nothing in the zone is
## reachable (the caller plans on the street graph instead).
func _plan_local(k: int, goal: Dictionary, key: String, zone_key: String) -> bool:
	var st := drive.stack
	var mech := body_mech
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
		if not floor_at.has(c):
			var inside := c.x >= 0 and c.y >= 0 and c.x < n and c.y < n
			floor_at[c] = _street_floor(k, org + Vector2(c) * LOCAL_STEP) if inside else null
		return floor_at[c]
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
	# Fallback when nothing within STAND_IN x r is roomy (a wide body's way to a relay down an alley narrower than
	# 2 x roomy: Bulwark seed 22's defend, an 8.1 m alley, the nearest capsule fit 6.5 m from the relay): any point
	# inside the objective's own radius where the capsule fits (body_r + FIT_PAD all round), nearest the goal point.
	# Used only when the usual pick finds nothing, so a Strider's stand points stay where they were.
	var fit_r := r
	if not o.is_empty() and str(goal["key"]) == task_id:
		fit_r = maxf(r, float(o.get("radius", r)))
	var fit := Vector2i(-1, -1)
	var fit_score := INF
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1),
		Vector2i(-1, 1), Vector2i(-1, -1)]
	var qi := 0
	while qi < queue.size():
		var c: Vector2i = queue[qi]
		qi += 1
		var p2 := org + Vector2(c) * LOCAL_STEP
		var dc := p2.distance_to(centre)
		if dc <= r * STAND_IN:
			var sc := p2.distance_to(want)
			if sc < best_score and _roomy(fl.call(c), st.deck_ring(k).up_at(fl.call(c))):
				best_score = sc
				best = c
		if best.x < 0 and dc <= fit_r:
			var sf := p2.distance_to(want)
			if sf < fit_score and _roomy(fl.call(c), st.deck_ring(k).up_at(fl.call(c)), body_r + FIT_PAD):
				fit_score = sf
				fit = c
		var fa: Vector3 = fl.call(c)
		var up := st.deck_ring(k).up_at(fa)
		for d in dirs:
			var nb := c + d
			if came.has(nb):
				continue
			var fb: Variant = fl.call(nb)
			if fb == null:
				continue
			var clear := _walk_clear(fa, fb as Vector3, up)
			if not clear:
				continue
			came[nb] = c
			queue.append(nb)
	if best.x < 0 and fit.x >= 0:
		best = fit
		local_fits += 1
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
	var pos := body_mech.global_position
	if not _live_on(_target, td):
		_target = null
	var pb := pilot.bot if pilot != null else null
	if mode == "fight" and k == td and pb != null and is_instance_valid(pb):
		var pe: Variant = pb.current_target()   # untyped: it may already be freed
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
		var arr: Dictionary = SectionEncounters.arrival(drive.stack.section, td)
		return {"deck": td, "at": drive.stack.from_deck_arc(td, float(arr["x"]), float(arr["s"])), "key": id + ":wait",
			"text": "sweep deck %d: waiting for its waves" % td, "enemy": false, "zone": 30.0}
	if _live_on(_hunt, td) and k == td:
		var he := _hunt as EnemyBase
		if _hunt_spot != Vector3.INF:
			# A blocker up high (a roof turret inside a flag ring): shoot it from the zone point that sees it.
			return {"deck": td, "at": _hunt_spot, "key": id + ":huntspot", "enemy": false,
				"text": "%s %s: shooting %s from the zone" % [ty, id, he.name]}
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
		txt += " (%.0f / %.0f)" % [rules.obj_progress(id), rules.obj_total(id)]
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
	for id: int in _hunt_skip.keys():
		_hunt_skip[id] = float(_hunt_skip[id]) - dt
		if float(_hunt_skip[id]) <= 0.0:
			_hunt_skip.erase(id)
	if _hunt != null:
		_hunt_t += dt
		if not _live(_hunt) or _hunt_t > HUNT_GIVE_UP:
			_hunt = null
		else:
			var he := _hunt as EnemyBase
			var hp := he.total_hp()
			var walking := _hunt_spot != Vector3.INF and _flat(_hunt_spot - body_mech.global_position, body_mech.up()).length() > ARRIVE * 1.5
			if hp < _hunt_hp - 0.5:
				_hunt_hp = hp
				_hunt_dry = 0.0
			elif not walking:
				_hunt_dry += dt   # (not while walking to the zone point that sees it)
			if _hunt_dry > HUNT_NO_DMG and not _hunt_blocks:
				_hunt_skip[he.get_instance_id()] = HUNT_SKIP
				FlowLog.say("bot", "%s: hunt of %s dealt nothing for %.0f s, back to the zone" % [task_id, he.name, _hunt_dry])
				_hunt = null
				_said = ""
	var o := rules.objective(task_id)
	if pb != null and is_instance_valid(pb):
		# Shoot first (whenever in sight, also on the way there) what blocks the zone: the hunted enemy, else the blocker
		# of this flag / hold nearest its centre (seed 6: the roof sniper in the ring was seen and hit to 32 % from 127 m
		# on the walk in, then the bot turned to other targets and lost it under the building).
		var pri: Variant = _hunt if _live(_hunt) else null
		if pri == null and not o.is_empty() and str(o["type"]) in ["flag", "hold"] and rules.obj_state(task_id) != "done":
			_blocker_t -= dt
			if _blocker_t <= 0.0:
				_blocker_t = 0.5
				_blocker = _zone_blocker_enemy(o)
			pri = _blocker if _live(_blocker) else null
		pb.priority_id = (pri as EnemyBase).target_id if pri != null else ""
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
			# A blocker in the ring (it stops the clock outright): go for it after BLOCKER_WAIT, not the full patience.
			want = _stuck_prog_t > (BLOCKER_WAIT if role == "escort" or _zone_blocker(o) else hunt_patience)
		"defend":   # wave units hanging back (the defend is done only once they are all dead); the escort goes at once
			want = rules.obj_state(task_id) == "active" and (_quiet_t > hunt_patience or role == "escort")
	if want:
		_hunt = _pick_hunt(o, ty == "defend", role == "escort" and _quiet_t <= hunt_patience)
		_hunt_t = 0.0
		_stuck_prog_t = 0.0
		_quiet_t = 0.0
		_hunt_spot = Vector3.INF
		_hunt_blocks = false
		if _hunt != null:
			var ha := drive.stack.to_deck_arc((_hunt as EnemyBase).global_position)
			_hunt_blocks = ty != "defend" and (_zone_of(o)[0] as Vector2).distance_to(Vector2(float(ha["x"]), float(ha["s"]))) \
				<= float(o.get("radius", 0.0)) + HUNT_ZONE_PAD
			_hunt_hp = (_hunt as EnemyBase).total_hp()
			_hunt_dry = 0.0
			if ty != "defend" and float(_arc_on(int(o["deck"]), _core(_hunt))["h"]) > PERCH_MIN_H:
				_hunt_spot = _zone_sight(o, _hunt as EnemyBase)
			FlowLog.say("bot", "%s: leaving the zone to hunt %s" % [task_id, (_hunt as EnemyBase).name])
			_said = ""


## Some live enemy of the objective's deck stands inside its zone (radius + HUNT_ZONE_PAD; MissionFlow's contest rule).
func _zone_blocker(o: Dictionary) -> bool:
	return _zone_blocker_enemy(o) != null


## Travelling to the current flag / hold on deck k: its blocker is in PlayerBot's sight within BLOCKER_SIGHT_R m.
func _blocker_in_sight(k: int) -> bool:
	var pb := pilot.bot if pilot != null else null
	if pb == null or not is_instance_valid(pb) or not _live(_blocker) or _hunt != null:
		return false
	var be := _blocker as EnemyBase
	if drive.stack.deck_at(be.global_position) != k or not pb.sees(be.target_id):
		return false
	return be.global_position.distance_to(body_mech.global_position) < BLOCKER_SIGHT_R


## The live enemy inside the objective's zone nearest its centre, or null.
func _zone_blocker_enemy(o: Dictionary) -> Variant:
	var td := int(o["deck"])
	var c: Vector2 = _zone_of(o)[0]
	var zr := float(o.get("radius", 0.0)) + HUNT_ZONE_PAD
	var best: Variant = null
	var best_d := INF
	for e: Variant in (drive.combat.squad.enemies as Array):
		if _live_on(e, td):
			var a := drive.stack.to_deck_arc((e as EnemyBase).global_position)
			var d := c.distance_to(Vector2(float(a["x"]), float(a["s"])))
			if d <= zr and d < best_d:
				best_d = d
				best = e
	return best


## A street-level point inside the objective's zone (radius - 1 m, a ZONE_SIGHT_STEP grid) with a clear line from a
## mech's eye (PlayerBot.EYE_HEIGHT) to `en`'s core, nearest to the mech; INF when none. Seed 6 flag: a roof sniper
## 13 m up, 12 m from the flag inside its ring, seen from 18 of 68 points in the ring and from none right below it.
func _zone_sight(o: Dictionary, en: EnemyBase) -> Vector3:
	var k := int(o["deck"])
	var z := _zone_of(o)
	var c: Vector2 = z[0]
	var r := maxf(float(z[1]) - 1.0, 3.0)   # the far rim counts (seed 6: only it sees over the parapet)
	var st := drive.stack
	var space := body_mech.get_world_3d().direct_space_state
	var aims: Array = []   # every live hit sphere (any one seen can be shot), else the core point
	for sp: Dictionary in en.world_spheres():
		if float(en.hp.get(sp["component"], 1.0)) > 0.0:
			aims.append(sp["center"])
	if aims.is_empty():
		aims.append(_core(en))
	var best := Vector3.INF
	var best_d := INF
	var n := int(r / ZONE_SIGHT_STEP)
	for ix in range(-n, n + 1):
		for iy in range(-n, n + 1):
			var p := c + Vector2(ix, iy) * ZONE_SIGHT_STEP
			if p.distance_to(c) > r or planner.in_cut(k, p, 1.5):
				continue
			var base := st.from_deck_arc(k, p.x, p.y, 0.0)
			var up := st.deck_ring(k).up_at(base)
			var sees := false
			for aim: Vector3 in aims:
				var q := PhysicsRayQueryParameters3D.create(base + up * PlayerBot.EYE_HEIGHT, aim)
				q.exclude = [body_mech.get_rid()]
				var hit := space.intersect_ray(q)
				var hn := hit.get("collider") as Node if not hit.is_empty() else null
				if hit.is_empty() or (hn != null and (hn == en or en.is_ancestor_of(hn))) \
						or (hit["position"] as Vector3).distance_to(aim) < 1.5:
					sees = true
					break
			if not sees or _street_floor(k, p) == null:
				continue
			var d := base.distance_to(body_mech.global_position)
			if d < best_d:
				best_d = d
				best = base
	return best


## An enemy of the objective's deck worth leaving the zone for: wave units first on a defend (any distance: the defend
## needs them dead; `near_only`: within HUNT_RANGE of the site), else the nearest to the site within HUNT_RANGE.
## Only EnemySquad's enemies (banners and other scenery targets are never hunted).
func _pick_hunt(o: Dictionary, waves_first: bool, near_only: bool) -> Variant:
	var td := int(o["deck"])
	var c: Vector2 = _zone_of(o)[0]
	var zone := str(o["type"]) != "defend"   # a flag / hold: only blockers and quick kills (HUNT_ZONE_PAD above)
	var zr := float(o.get("radius", 0.0)) + HUNT_ZONE_PAD
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
		var blocks := zone and d <= zr
		if zone and not blocks:
			var quick := en.total_hp() < en.total_max_hp() * HUNT_QUICK_HP and d <= HUNT_QUICK_RANGE
			if not quick:
				continue
		if not blocks and _hunt_skip.has(en.get_instance_id()):
			continue
		var score := d - (1000.0 if wave else 0.0) - (2000.0 if blocks else 0.0)
		if score < best_d:
			best_d = score
			best = en
	return best


## Deck k's street-level floor point at arc (x, s) = p2, or null: outside floor cuts, a ray down from 3.5 m (a start
## inside a solid counts: podiums and tower bases are solid colliders) finds floor within 1.2 m of the deck's floor, with
## 7 m of headroom above it.
func _street_floor(k: int, p2: Vector2) -> Variant:
	if planner.in_cut(k, p2, 1.5):
		return null
	var st := drive.stack
	var mech := body_mech
	var space := mech.get_world_3d().direct_space_state
	var base := st.from_deck_arc(k, p2.x, p2.y, 0.0)
	var up := st.deck_ring(k).up_at(base)
	var q := PhysicsRayQueryParameters3D.create(base + up * 3.5, base - up * 2.0)
	q.exclude = [mech.get_rid()]
	q.hit_from_inside = true
	var h := space.intersect_ray(q)
	if h.is_empty() or (h["normal"] as Vector3).dot(up) <= 0.8 or ((h["position"] as Vector3) - base).dot(up) >= 1.2:
		return null
	var f: Vector3 = h["position"]
	var q2 := PhysicsRayQueryParameters3D.create(f + up * 0.5, f + up * 7.5)
	q2.exclude = [mech.get_rid()]
	q2.hit_from_inside = true
	return f if space.intersect_ray(q2).is_empty() else null


## A mech can walk straight from floor point a to b: rays at 2.5 and 5.5 m, in the middle and LOCAL_SIDE to each side
## (a mech's width: a doorway slit isn't a way), all clear.
func _walk_clear(a: Vector3, b: Vector3, up: Vector3) -> bool:
	var space := body_mech.get_world_3d().direct_space_state
	var side := (b - a).cross(up).normalized() * local_side
	for hh: float in [2.5, 5.5]:
		for off: Vector3 in [Vector3.ZERO, side, -side]:
			var q := PhysicsRayQueryParameters3D.create(a + up * hh + off, b + up * hh + off)
			q.exclude = [body_mech.get_rid()]
			q.hit_from_inside = true
			if not space.intersect_ray(q).is_empty():
				return false
	return true


## Room for a mech to stand at floor point p: eight rays at 2.5 m height, ROOMY m out, all clear (a stand point or a
## cover point pressed against the relay, the mast or a wall wedges the mech; seen on seed 2: wedged by the relay).
func _roomy(p: Vector3, up: Vector3, dist: float = -1.0) -> bool:
	var reach := roomy if dist <= 0.0 else dist
	var space := body_mech.get_world_3d().direct_space_state
	var ref := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	var o := p + up * 2.5
	for i in 8:
		var q := PhysicsRayQueryParameters3D.create(o, o + ref.rotated(up, TAU * float(i) / 8.0) * reach)
		q.exclude = [body_mech.get_rid()]
		q.hit_from_inside = true
		if not space.intersect_ray(q).is_empty():
			return false
	return true


## The mech's weakest core component, 0..1 (PlayerTarget.CORE_COMPONENTS: one at 0 downs the mech).
func _core_hp() -> float:
	var pt := body_pt if drive.combat != null else null
	if pt == null:
		return 1.0
	var fr := pt.component_fractions()
	var lo := 1.0
	for c: String in PlayerTarget.CORE_COMPONENTS:
		if fr.has(c):
			lo = minf(lo, float(fr[c]))
	return lo


## Holding a zone and in trouble: the weakest core part under survival_hp (the profile's; veteran = LOW_HP), or down PRESSURE_DROP in the last PRESSURE_WIN s.
## Defending, only under DEFEND_LOW_HP: hiding leaves the relay to the enemy.
func _pressed() -> bool:
	var hp := _core_hp()
	_hp_hist.append([t, hp])
	while _hp_hist.size() > 1 and t - float(_hp_hist[0][0]) > PRESSURE_WIN:
		_hp_hist.pop_front()
	var drop := float(_hp_hist[0][1]) - hp
	if str(drive.mission.rules.objective(task_id).get("type", "")) == "defend":
		# Low, or already under survival_hp and losing fast (a tank shell takes ~35 % of the torso: one more and it is
		# down, and a dead defender leaves the relay alone for the whole walk back).
		return hp < survival_hp * DEFEND_LOW_HP / LOW_HP or (hp < survival_hp and drop > PRESSURE_DROP)
	return hp < survival_hp or drop > PRESSURE_DROP


## The live enemies of deck k worth hiding from: up to 4, nearest first, within COVER_THREAT_R m.
func _threats(k: int) -> Array:
	var out: Array = []
	var pos := body_mech.global_position
	for e: Variant in (drive.combat.squad.enemies as Array):
		if not _live_on(e, k):
			continue
		var d := (e as EnemyBase).global_position.distance_to(pos)
		if d < COVER_THREAT_R:
			out.append([d, e])
	out.sort_custom(func(u: Array, v: Array) -> bool: return float(u[0]) < float(v[0]))
	var eyes: Array = []
	for u: Array in out.slice(0, 4):
		eyes.append((u[1] as EnemyBase).eye_world())
	return eyes


## How many of the threat eyes don't see a mech's chest at floor point p.
func _covered(p: Vector3, up: Vector3, eyes: Array) -> int:
	var space := body_mech.get_world_3d().direct_space_state
	var n := 0
	var chest := p + up * 4.5
	for eye: Vector3 in eyes:
		var q := PhysicsRayQueryParameters3D.create(eye, chest)
		q.exclude = [body_mech.get_rid()]
		var h := space.intersect_ray(q)
		if not h.is_empty() and eye.distance_to(h["position"] as Vector3) < eye.distance_to(chest) - 2.5:
			n += 1
	return n


## A street-level point near the stand point `at`, inside the zone (COVER_IN of r from the centre `zc`), the mech can
## walk to straight, hidden from the most threats (at least one), nearest the mech among equals. INF when none.
func _pick_cover(k: int, at: Vector3, zc: Vector3, r: float, eyes: Array) -> Vector3:
	if eyes.is_empty():
		return Vector3.INF
	var st := drive.stack
	var mech := body_mech
	var up := mech.up()
	var sa := _arc_on(k, at)
	var za := _arc_on(k, zc)
	var zc2 := Vector2(float(za["x"]), float(za["s"]))
	var best := Vector3.INF
	var best_n := 0
	var best_d := INF
	for dist: float in [0.0, 4.0, 7.0, 10.0]:
		for i in (1 if dist == 0.0 else 12):
			var p2 := Vector2(float(sa["x"]), float(sa["s"])) + Vector2.from_angle(TAU * float(i) / 12.0) * dist
			if p2.distance_to(zc2) > r * COVER_IN:
				continue
			var f: Variant = _street_floor(k, p2)
			if f == null:
				continue
			var fp: Vector3 = f
			if not _roomy(fp, up):
				continue
			var d := _flat(fp - mech.global_position, up).length()
			if d > 1.5 and not _walk_clear(mech.global_position + up * 0.3, fp, up):
				continue
			var n := _covered(fp, up, eyes)
			if n > best_n or (n == best_n and n > 0 and d < best_d):
				best_n = n
				best_d = d
				best = fp
	return best


## Low on HP: launch a repair drone from active equipment if the loadout has one (WeaponRack.activate, the bots' way).
func _use_repair() -> void:
	if drive == null or drive.combat == null or body_rack == null or body_mech == null or drive.held:
		return
	var pt := body_pt
	if pt == null or pt.disabled or _core_hp() > REPAIR_AT:
		return
	var rack := body_rack
	for i in rack.slot_count():
		if rack.can_launch(i) and rack.activate(i + 1):
			drones += 1
			FlowLog.say("bot", "repair drone out (weakest core part at %.0f %%)" % (_core_hp() * 100.0))
			return


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
	role_index = maxi(peers.find(MechSpawn.owner_of(body_mech)), 0)
	role = "solo" if peers.size() <= 1 else ("anchor" if role_index == 0 else "escort")


## Stand in the zone (centre `at`, radius r): PlayerBot aims and fires; its legs only while it engages / dodges / takes
## cover and stays near the centre; past HOLD_DRIFT of r, walk back (still facing the enemy when engaging).
func _zone_hold(k: int, at: Vector3, r: float, dt: float, goal: Dictionary = {}) -> void:
	var mech := body_mech
	var up := mech.up()
	var off := _flat(at - mech.global_position, up)
	var d := off.length()
	_roof_done()
	var pb := pilot.bot if pilot != null else null
	var st := pb.ai_state if pb != null and is_instance_valid(pb) else ""
	# In trouble (low, or losing HP fast): into cover inside the zone (it keeps counting), still shooting what it sees.
	if survival and _pressed():
		_cover_t += dt
		var eyes := _threats(k)
		if _cover_pt == Vector3.INF or (_cover_t > COVER_RECHECK and _covered(_cover_pt, up, eyes) == 0):
			var zc := at
			var o := drive.mission.rules.objective(task_id)
			if not o.is_empty() and str(goal.get("key", "")) == task_id:
				var zz := _zone_of(o)
				zc = drive.stack.from_deck_arc(k, (zz[0] as Vector2).x, (zz[0] as Vector2).y)
			_cover_pt = _pick_cover(k, at, zc, r, eyes)
			_cover_t = 0.0
			if _cover_pt != Vector3.INF:
				covers += 1
				print("[Bot] taking cover in the zone (weakest core part %.0f %%)" % (_core_hp() * 100.0))
		if _cover_pt != Vector3.INF:
			var co := _flat(_cover_pt - mech.global_position, up)
			if co.length() > 1.5:
				var cdir := _veto(k, co.normalized())
				var cb := mech.global_transform.basis
				mech.move_input = Vector2(cdir.dot(cb.x), -cdir.dot(cb.z)).limit_length(1.0)   # keep PlayerBot's facing
				mech.running = co.length() > 6.0
			else:
				mech.move_input = Vector2.ZERO
				mech.running = false
			mech.thrust_input = false
			return
	else:
		_cover_pt = Vector3.INF
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


## Friendly fire (on by default): BotFireGuard holds every slot whose shot could reach a crew mech (MissionScene.mechs: the
## players' puppets, the host's own mech, the other hangar bots), from the slot's real muzzle along the whole flight
## (range, spread, splash, travel time against the mate's motion, missiles' homing, the mortar's landing), and leads this
## shooter's flying missiles away from a mate. Called last every physics frame (after PlayerBot and this layer).
func _ff_guard() -> void:
	if drive == null or drive.combat == null or body_rack == null or body_mech == null:
		return
	var n := BotFireGuard.apply(body_rack, drive.combat.world, body_mech, drive.mechs.values(),
		body_mech.get_world_3d().direct_space_state if body_mech.is_inside_tree() else null)
	if n > 0:
		ff_holds += 1


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
	var me := _arc(body_mech.global_position)
	var goal_xt := _xt(at)
	var r := drive.stack.section.radius_of(t_deck)
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation, off in play
	_legs = planner.plan(k, Vector2(float(me["x"]), float(me["s"])), t_deck, Vector2(goal_xt.x, goal_xt.y * r), end_on_road,
		float(me["h"]))
	if PerfProbe.on:
		PerfProbe.add("bot.route_plan", Time.get_ticks_usec() - pp0)
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
	return _deck != int(leg["from"]) or not body_mech.grounded() or _leg_left(leg) < 15.0


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
	var a := _arc(body_mech.global_position)
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
	var mech := body_mech
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
	var mech := body_mech
	# Off the ground counts too (wedged against a wall the legs may never touch down), except in a drop.
	if _backup_t > 0.0 or ((kind == "shaft" or kind == "glide") and not mech.grounded()):
		return
	_stk_t += dt
	if _stk_t < stuck_win:
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
	if _stk_n >= BLOCK_AFTER and (kind == "walk" or kind == "ramp"):
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


## The wedge watch (WEDGE_AFTER above): after the frame's legs are chosen (this layer or PlayerBot), before the hole
## guard. Escapes push away from the slide contacts (else back from where it was heading), thrust on for the first
## part; the second from one spot blocks the route edges round it and adds an avoid square, then re-plans.
func _wedge_watch(dt: float) -> void:
	var mech := body_mech
	if mech == null or drive == null or drive.stack == null or planner == null:
		return
	var pt := body_pt if drive.combat != null else null
	if (pt != null and pt.disabled) or mech.shutdown:
		_esc_t = 0.0
		return
	var up := mech.up()
	if _holding or not (mode == "travel" or mode == "fight"):
		_esc_t = 0.0   # holding a zone (dodging in place is not a wedge), idle, depot / revive stands
		_esc_mark = _stall_t
		return
	if _esc_t > 0.0:
		_esc_t -= dt
		var hot := mech.heat / maxf(mech.heat_cap, 1.0) > 0.85
		_steer(_esc_dir, false, not hot and _esc_t > WEDGE_ESCAPE_T * 0.6)
		if _esc_t <= 0.0 and mech.global_position.distance_to(_esc_from) < WEDGE_FREED and _esc_try < ESCAPE_TURNS.size() - 1:
			# Still held: the next direction at once (seed 9's wedge let the body go one way only; CharacterBody3D.test_move
			# called every direction free there, so each is tried for real).
			_esc_try += 1
			_esc_dir = _esc_base.rotated(up, ESCAPE_TURNS[_esc_try])
			_esc_from = mech.global_position
			_esc_t = WEDGE_ESCAPE_T
			wedge_escapes += 1
		return
	if _stall_t < _esc_mark:
		_esc_mark = 0.0   # the stall clock restarted: the mech got somewhere
	if _stall_t - _esc_mark < WEDGE_AFTER:
		return
	_esc_mark = _stall_t
	var away := Vector3.ZERO
	for i in mech.get_slide_collision_count():
		away += _flat(mech.get_slide_collision(i).get_normal(), up)
	if away.length() < 0.2:
		away = -_flat(last_dir, up)
	if away.length() < 0.2:
		away = -_flat(mech.forward(), up)
	_esc_base = away.normalized()
	_esc_try = 0
	_esc_dir = _esc_base
	_esc_from = mech.global_position
	if _esc_spot != Vector3.INF and _esc_spot.distance_to(mech.global_position) < WEDGE_SPOT:
		_esc_n += 1
	else:
		_esc_spot = mech.global_position
		_esc_n = 1
	wedge_escapes += 1
	_esc_t = WEDGE_ESCAPE_T
	var k := drive.stack.deck_at(mech.global_position)
	var a := _arc_on(k, mech.global_position)
	var me := Vector2(float(a["x"]), float(a["s"]))
	print("[Bot] wedged %.1f s at x %.0f s %.0f on deck %d: escape %d" % [_stall_t, me.x, me.y, k, _esc_n])
	if _esc_n >= 2 and mode == "travel":
		var nb := planner.block_around(k, me, WEDGE_BLOCK_R)
		blocked_edges += nb
		if not _avoid.has(k):
			_avoid[k] = []
		(_avoid[k] as Array).append(Rect2(me - Vector2.ONE * WEDGE_AVOID, Vector2.ONE * WEDGE_AVOID * 2.0))
		print("[Bot] wedge spot x %.0f s %.0f on deck %d: %d route edges blocked, legs kept off it, re-planning" % [me.x,
			me.y, k, nb])
		FlowLog.say("bot", "wedge at x %.0f s %.0f on deck %d: %d edges blocked" % [me.x, me.y, k, nb])
		_clear_route()


## An arc-metre direction on deck k at the mech -> a world direction along the floor.
func _arc_to_world(k: int, d2: Vector2) -> Vector3:
	if d2.length_squared() < 1e-6:
		return Vector3.ZERO
	var ax := _axes(k)
	var w: Vector3 = ax[0] * d2.x + ax[1] * d2.y
	return _flat(w, body_mech.up())


## World directions of +x and +s on deck k at the mech.
func _axes(k: int) -> Array:
	var st := drive.stack
	var a := _arc_on(k, body_mech.global_position)
	var x := float(a["x"])
	var s := float(a["s"])
	var p0 := st.from_deck_arc(k, x, s)
	return [(st.from_deck_arc(k, x + 1.0, s) - p0).normalized(), (st.from_deck_arc(k, x, s + 1.0) - p0).normalized()]


## Keep a world direction from carrying the mech into a floor cut of deck k (VETO_GROW round it, VETO_AHEAD ahead):
## the part toward the cut is removed (a push out when already at its edge).
## Solid mission props the legs keep clear of like floor cuts (same veto): the supply depots' footprints on deck k
## (+ SOLID_PAD), in deck arc metres. Playtest seeds 2 / 17 / 26: a depot snapped onto a road line (seed 2: d0_depot0
## at x -57 s -154) wedged the mech against it for the whole run.
func _solids(k: int) -> Array:
	var md: MissionDepots = drive.mission.depots if drive != null and drive.mission != null else null
	if md == null:
		return []
	if not _solid_rects.has(k):
		var out: Array = []
		for id: String in md.sites:
			var st: Dictionary = md.sites[id]
			if int(st.get("deck", -1)) != k or not bool(st.get("ok", true)):
				continue
			var half := SupplyDepot.footprint_half(int(st.get("face", 0))) + Vector2(SOLID_PAD, SOLID_PAD)
			out.append(Rect2(Vector2(float(st["x"]), float(st["s"])) - half, half * 2.0))
		if body_r > STRIDER_R + 0.01 and drive.stack.section != null:
			# A wide body keeps out of the lift wells too (seed 3: a Bulwark walked into deck 1's critical lift while
			# fighting, dropped onto the sunken platform and stayed wedged there for the rest of the mission).
			var sec := drive.stack.section
			for ci in sec.connectors.size():
				if str(sec.connectors[ci]["kind"]) == "lift":
					var lr := sec.connector_rect(ci, k)
					if lr.size != Vector2.ZERO:
						out.append(lr)
		_solid_rects[k] = out
	return _solid_rects[k]


## The ramp parts standing on deck k (their lanes and parapets, BotRoutePlanner.unders) the legs keep off like a cut,
## except a ramp the route is about to take or is on (its connector in a ramp leg from the current one on). Seed 9: a
## Strider walking past deck 1's ramp foot ended with its capsule on the foot's corner just outside the lane, where
## move_and_slide made no motion any way, thrust included, for 72 s (a collision snag of that corner, reported).
func _ramp_keepout(k: int) -> Array:
	if k < 0 or k >= planner.unders.size():
		return []
	var taking := {}
	for i in range(_leg_i, _legs.size()):
		if str(_legs[i]["kind"]) == "ramp":
			taking[int(_legs[i]["connector"])] = true
	var out: Array = []
	for u: Dictionary in planner.unders[k]:
		var part: Dictionary = u.get("part", {})
		if not taking.has(int(part.get("connector", -1))):
			# Only its LOW stretch (under RAMP_LOW_H over the deck): higher up a mech walks under the slope (seed 9's
			# roads cross under deck 0's ramp at s 0 and s 101). _veto grows every rect by veto_grow (meant for holes); a
			# ramp part only needs the capsule clear of it.
			var r: Rect2 = u["rect"]
			var hf := float(part.get("h_foot", 0.0))
			var ht := float(part.get("h_top", 0.0))
			if part.has("s_foot") and part.has("s_top") and absf(ht - hf) > 0.1:
				var sf := float(part["s_foot"])
				var stp := float(part["s_top"])
				var s_low := sf + (stp - sf) * clampf((RAMP_LOW_H - hf) / (ht - hf), 0.0, 1.0)
				var s0 := minf(sf, s_low)
				var s1 := maxf(sf, s_low)
				r = Rect2(r.position.x, maxf(r.position.y, s0), r.size.x, minf(r.end.y, s1) - maxf(r.position.y, s0))
				if r.size.y <= 0.0:
					continue
			out.append(r.grow(body_r + RAMP_CLEAR - veto_grow))
	return out


func _veto(k: int, dir: Vector3) -> Vector3:
	if planner == null or dir.length_squared() < 1e-6:
		return dir
	var ax := _axes(k)
	var a := _arc_on(k, body_mech.global_position)
	var p := Vector2(float(a["x"]), float(a["s"]))
	var mag := dir.length()
	var d2 := Vector2(dir.dot(ax[0]), dir.dot(ax[1]))
	if d2.length_squared() < 1e-6:
		return dir
	d2 = d2.normalized()
	var changed := false
	for r: Rect2 in planner.cuts[k] + _solids(k) + (_avoid.get(k, []) as Array) + _ramp_keepout(k):
		var g := r.grow(veto_grow)
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
	return _flat(ax[0] * d2.x + ax[1] * d2.y, body_mech.up()).normalized() * mag


# --- Fighting ----------------------------------------------------------------------------------------------

func _fight(k: int, t_deck: int, at: Vector3, eye: Vector3, dt: float) -> void:
	var mech := body_mech
	var pb := pilot.bot if pilot != null else null
	var per := drive.enemies_alive_per_deck()
	var alive: int = per[t_deck] if t_deck < per.size() else 0
	_fight_t += dt
	_vantage_cd -= dt
	# Progress is a hit on the enemy this fight is about when it is a hunt (a zone's blocker); a kill elsewhere on the
	# deck is not (seed 6 flag: wave units dying round the bot kept resetting the clock, so it never looked for a
	# vantage on the roof sniper it could not see from below). Otherwise any kill on the deck counts, as before.
	var focus: Variant = _hunt if _live(_hunt) else null   # (a sweep's committed target keeps the old any-kill clock)
	var progress := false
	if focus != null:
		var fhp := (focus as EnemyBase).total_hp()
		var fid := (focus as EnemyBase).get_instance_id()
		progress = fid == _focus_id and _focus_hp >= 0.0 and fhp < _focus_hp - 0.5
		_focus_hp = fhp
		_focus_id = fid
	else:
		_focus_hp = -1.0
		progress = _alive_prev >= 0 and alive < _alive_prev
	_alive_prev = alive
	if progress:
		_fight_t = 0.0
		_perch = {}
		_vantage = Vector3.INF
		_tried.clear()
	var st := pb.ai_state if pb != null and is_instance_valid(pb) else ""
	var engaging := st in [PlayerBot.STATE_ENGAGE, PlayerBot.STATE_DODGE, PlayerBot.STATE_CLIMB_ROOF, PlayerBot.STATE_TAKE_COVER]
	# Hunting a zone blocker: line of sight means seeing IT (seed 6: PlayerBot engaged the wave units round the flag the
	# whole time, so the vantage / perch search for the roof sniper never started).
	var focus_los := true
	if _hunt_blocks and _live(_hunt) and pb != null and is_instance_valid(pb):
		focus_los = pb.sees((_hunt as EnemyBase).target_id)
	if st == PlayerBot.STATE_ENGAGE and focus_los:
		_no_los_t = 0.0
		_vantage = Vector3.INF   # it sees something: fight from here
	else:
		_no_los_t += dt
	# No kill for a while, or nowhere nearer to walk, and no line of sight lately: move to a road point that sees the
	# target (its core, PlayerBot's own test).
	var walked_out := _route_key.begins_with("fightwalk") and _leg_i >= _legs.size()
	var blocker_blind := _hunt_blocks and not focus_los and _fight_t > 1.5
	if (_fight_t > VANTAGE_AFTER or walked_out or blocker_blind) and (_no_los_t > 2.5 or blocker_blind) and _vantage == Vector3.INF and _vantage_cd <= 0.0 \
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
	if engaging and (focus_los or (_vantage == Vector3.INF and _perch.is_empty())):
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
	var ma := _arc_on(k, body_mech.global_position)
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
	var space := body_mech.get_world_3d().direct_space_state
	for c: Array in cands.slice(0, 90):
		var p2: Vector2 = c[0]
		_tried.append(c[2])
		var p := st.from_deck_arc(k, p2.x, p2.y, CityPlan.CURB_H)
		var eye := p + st.deck_ring(k).up_at(p) * PlayerBot.EYE_HEIGHT
		var q := PhysicsRayQueryParameters3D.create(eye, look)
		q.exclude = [body_mech.get_rid()]
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
	var mech := body_mech
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
	var mech := body_mech
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
	var mech := body_mech
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
		b.bind(body_mech, body_rack, body_pt, drive.combat.world, drive.combat.squad,
			drive.stack.decks[k].plan, drive.stack.deck_ring(k), _cam())
	FlowLog.say("bot deck", "now on deck %d" % k)


func _status(k: int, t_deck: int, at: Vector3) -> void:
	_status_t -= get_physics_process_delta_time()
	if _status_t > 0.0:
		return
	_status_t = STATUS_EVERY
	var mech := body_mech
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
	var me := MechSpawn.owner_of(body_mech)
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
	var m := st.to_deck_arc(body_mech.global_position)
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
	var mech := body_mech
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
	if planner == null or not body_mech.grounded():
		return false
	var a := _arc_on(k, body_mech.global_position)
	return float(a["h"]) > ROOF_H and planner.cell_at(k, Vector2(float(a["x"]), float(a["s"]))) >= 0


## Off the roof: straight for the nearest side of the block (ROOF_OUT m past it), a thruster hop whenever it doesn't
## move (parapets, roof units).
func _roof_escape(k: int, dt: float) -> void:
	var mech := body_mech
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
	var space := body_mech.get_world_3d().direct_space_state
	var up := st.deck_ring(k).up_at(from_w)
	var clear: Array = []
	for sd: Array in sides:
		var q := PhysicsRayQueryParameters3D.create(from_w + up * 4.0, st.from_deck_arc(k, (sd[1] as Vector2).x, (sd[1] as Vector2).y, h + 4.0))
		q.exclude = [body_mech.get_rid()]
		if space.intersect_ray(q).is_empty():
			clear.append(sd[1])
	if clear.is_empty():
		return sides[skip % 4][1] if skip > 0 else Vector2.INF
	return clear[skip % clear.size()]


## A roof of deck k (BotNavigator's jumpable roofs) 14-110 m from the target whose top sees `look` from a mech's eye,
## nearest to the mech first, not tried this fight. {} when none.
func _pick_perch(k: int, look: Vector3) -> Dictionary:
	if k >= _navs.size():   # (a hop-only body's navigators keep only the roofs it can hop onto)
		return {}
	var nav: BotNavigator = _navs[k]
	var st := drive.stack
	var mp := body_mech.global_position
	var cands: Array = []
	for r: Dictionary in nav.all_roofs():
		var cw: Vector3 = r["center_w"]
		var key := "roof:%d:%d" % [roundi((r["arc2"] as Vector2).x), roundi((r["arc2"] as Vector2).y)]
		var d := cw.distance_to(look)
		if d < 14.0 or d > 110.0 or _tried.has(key) or t - float(_bad_perch.get(key, -INF)) < PERCH_RETRY:
			continue
		cands.append([r, cw.distance_to(mp), key])
	cands.sort_custom(func(u: Array, v: Array) -> bool: return float(u[1]) < float(v[1]))
	var space := body_mech.get_world_3d().direct_space_state
	for c: Array in cands.slice(0, 30):
		_tried.append(c[2])
		var cw: Vector3 = (c[0] as Dictionary)["center_w"]
		var eye := cw + st.deck_ring(k).up_at(cw) * (PlayerBot.EYE_HEIGHT + 0.3)
		var q := PhysicsRayQueryParameters3D.create(eye, look)
		q.exclude = [body_mech.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or eye.distance_to(hit["position"] as Vector3) >= eye.distance_to(look) - 2.6:
			var a := _arc_on(k, cw)
			# Only a roof it can walk off again: a side of its block with nothing taller in the way.
			if _exit_side(k, Vector2(float(a["x"]), float(a["s"])), float(a["h"]), cw) == Vector2.INF:
				continue
			FlowLog.say("bot", "climbing a roof on deck %d (x %.0f s %.0f, %.0f m up) to see the target" % [k, float(a["x"]),
				float(a["s"]), float((c[0] as Dictionary)["roof_h"])])
			_said = ""
			_perch_prog_t = 0.0
			_perch_best = Vector2.INF
			var pr: Dictionary = (c[0] as Dictionary).duplicate()
			pr["_key"] = c[2]
			return pr
	return {}


## Get onto the perch: along the roads to near it, then BotNavigator's thruster climb; hold there PERCH_HOLD s.
func _perch_step(k: int, dt: float) -> void:
	var mech := body_mech
	var up := mech.up()
	var heat := mech.heat / maxf(mech.heat_cap, 1.0)
	_perch_t += dt
	if _perch_t > PERCH_GIVE_UP:
		_perch = {}
		return
	var cw: Vector3 = _perch["center_w"]
	var flat := _flat(cw - mech.global_position, up).length()
	var my_h := float(_arc_on(k, mech.global_position)["h"])
	var high := my_h > ROOF_H
	# A climb that gets nowhere (a wall too tall for the thrusters, a ledge it slides off): give it up for PERCH_RETRY s.
	if _perch_best == Vector2.INF:
		_perch_best = Vector2(flat, my_h)
		_perch_prog_t = 0.0
		_perch_anchor = mech.global_position
	elif flat < _perch_best.x - 2.0 or my_h > _perch_best.y + 1.0:
		_perch_best = Vector2(minf(flat, _perch_best.x), maxf(my_h, _perch_best.y))
		_perch_prog_t = 0.0
	elif mech.global_position.distance_to(_perch_anchor) > 2.0:
		_perch_anchor = mech.global_position   # moving about (a hop, sliding along the wall): not stuck yet
		_perch_prog_t = maxf(_perch_prog_t - 1.0, 0.0)
	else:
		_perch_prog_t += dt
	if _perch_prog_t > PERCH_STALL and not bool(_perch.get("_reached", false)):
		_bad_perch[str(_perch.get("_key", ""))] = t
		perch_fails += 1
		FlowLog.say("bot", "giving up the roof climb on deck %d after %.0f s without getting higher or nearer" % [k, _perch_prog_t])
		_said = ""
		_perch = {}
		_stand()
		return
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
		_perch["_reached"] = true
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
