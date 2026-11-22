class_name MissionBot
extends Node
## `--bot [profile]`: the AI plays the local mech through the whole mission (LAN verification, soak runs). Input only,
## like a player: it never moves a mech or an enemy itself.
##   FIGHTING is antigravity's TestDriveBotPilot / PlayerBot (sense, aim, fire, dodge, explore), rebound to the deck the
##   mech is on (that deck's CityPlan and deck_ring).
##   GOING somewhere is this layer: the mission's current objective (MissionRules.current(), the host's on a client)
##   picks a deck and a point: "clear_k", the nearest live enemy of deck k; "extract", the extraction marker. On that
##   deck, far from the enemy (> ENGAGE m) or for the marker, it walks there along the deck's roads (BotNavigator.steer_to
##   on that deck's plan). On a deck above, it goes down: the deck's critical RAMP when there is one (in at the top end,
##   along the ramp lane, out at the foot on the deck below), else the open-air SHAFT (walk in, drop, the emergency burn
##   lands it). Lifts don't move yet, so they are never used. Going up (after a respawn on the entry deck the target is
##   always below it, so this is rare) uses a ramp walked foot to top, else it gives up and fights where it is.
## While it travels, PlayerBot still aims and fires; this layer only replaces the legs (move / turn / run).
## Started by TestDrive once the scene is set up (attach); every [Flow] transition is still logged by TestDrive.
##
## DEV ONLY, `--dev-bot-travel` (dev_travel): when the walk can't get there (no route to the target deck, or no progress
## for DEV_STALL s while travelling, or no kill on the target deck for DEV_FIGHT_STALL s), the bot JUMPS: it sets its own
## mech's transform to an arrival point on the floor of the target deck (the entry spawn's arc spot on that deck, or
## near the target enemy, or the extraction marker), found with a ray down (dev_jump). The snapshot stream sees the jump
## (NetMechStream bumps the teleport counter past TELEPORT_DIST), so puppets snap. Objectives, kills, the outcome and the
## end flow all still happen for real. Each jump logs "[Flow] dev travel: deck a -> b".

const ENGAGE := 85.0          ## m: closer than this to the target enemy (same deck), PlayerBot fights unaided
const ARRIVE := 7.0           ## m: a travel waypoint counts as reached
const NEAR_DIRECT := 45.0     ## m: closer than this, steer straight at the waypoint (no road path)
const REPLAN := 1.0           ## s between goal re-evaluations
const RAMP_APPROACH := 18.0   ## m before the ramp's top end along its lane (line up first)
const RAMP_PAST := 22.0       ## m past the ramp's foot on the deck below
const STATUS_EVERY := 10.0    ## s between "[Bot]" status lines
const DEV_STALL := 8.0        ## DEV --dev-bot-travel: s without 5 m of progress toward the travel goal before a jump
const DEV_FIGHT_STALL := 15.0 ## DEV: s without a kill or progress on the objective (fighting) before a jump near it
const DEV_NEAR := 20.0        ## DEV: m from the target enemy a fight jump lands (each jump from another side)

var drive: TestDrive
var pilot: TestDriveBotPilot
var mode := ""                ## "fight" | "travel" | "idle"
var goal_text := ""           ## what it is doing (logs, tests)
var _navs: Array = []         ## per deck: BotNavigator
var _rng := RandomNumberGenerator.new()
var _deck := -1               ## the deck PlayerBot is bound to
var _route: Array = []        ## [{deck, at: Vector3, direct: bool}] the special waypoints left (ramp / shaft legs)
var _route_for := ""          ## the goal key the route was made for
var _replan := 0.0
var _said := ""
var _status_t := 0.0          ## s until the next "[Bot]" status line
var last_dir := Vector3.ZERO  ## the last travel direction (status line)
var dev_travel := false       ## DEV ONLY: --dev-bot-travel (see the header)
var dev_jumps := 0            ## DEV: jumps made (tests)
var _prog_key := ""           ## DEV: what the progress clock measures
var _prog_best := INF         ## DEV: the closest it got to it
var _prog_t := 0.0            ## DEV: s since it last got 5 m closer (or killed something, fighting)
var _prog_alive := -1         ## DEV: live enemies on the target deck when the fight clock started


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "pilot": Net.LOCAL, "mode": Net.PRIVATE, "goal_text": Net.PRIVATE, "_navs": Net.PRIVATE,
		"_rng": Net.PRIVATE, "_deck": Net.PRIVATE, "_route": Net.PRIVATE, "_route_for": Net.PRIVATE,
		"_replan": Net.PRIVATE, "_said": Net.PRIVATE, "_status_t": Net.PRIVATE, "last_dir": Net.PRIVATE,
		"dev_travel": Net.PRIVATE, "dev_jumps": Net.PRIVATE, "_prog_key": Net.PRIVATE, "_prog_best": Net.PRIVATE,
		"_prog_t": Net.PRIVATE, "_prog_alive": Net.PRIVATE}


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
	if drive.stack != null:
		for k in drive.stack.decks.size():
			var nav := BotNavigator.new()
			nav.setup(drive.stack.decks[k].plan, drive.stack.deck_ring(k), _rng)
			_navs.append(nav)
	FlowLog.say("bot on", "profile %s%s" % [pilot.profile_id, ", DEV travel jumps on" if dev_travel else ""])


func _physics_process(dt: float) -> void:
	if drive == null or drive.loading or drive.mech == null or drive.stack == null or drive.mission == null:
		return
	if drive._held:
		return   # the barrier hasn't passed: stand still like everyone else
	var mech := drive.mech
	var k := drive.stack.deck_at(mech.global_position)
	if k != _deck:
		_bind_deck(k)
	_replan -= dt
	var goal := _goal(k)
	if goal.is_empty():
		_set_mode("idle", "no objective", "idle")
		return
	var t_deck := int(goal["deck"])
	var at: Vector3 = goal["at"]
	_status_t -= dt
	if _status_t <= 0.0:
		_status_t = STATUS_EVERY
		var a := drive.stack.to_deck_arc(mech.global_position)
		var ta := drive.stack.to_deck_arc(at)
		print("[Bot] %s %s | me deck %d x %.0f s %.0f h %.1f v %.1f in %s | goal deck %d x %.0f s %.0f, %.0f m | route %d | down %s" % [
			mode, goal_text, k, float(a["x"]), float(a["s"]), float(a["h"]), mech.velocity.length(), str(mech.move_input),
			t_deck, float(ta["x"]), float(ta["s"]),
			mech.global_position.distance_to(at), _route.size(),
			str(drive.combat.player_target.disabled) if drive.combat.player_target != null else "?"])
	# DEV: one progress clock per objective (fight and travel alternate at the ENGAGE edge): 5 m closer, or a kill.
	var stall := 0.0
	if dev_travel:
		var per := drive.enemies_alive_per_deck()
		var alive: int = per[t_deck] if t_deck < per.size() else 0
		stall = _dev_clock(str(goal["key"]), mech.global_position.distance_to(at), dt, alive if bool(goal.get("enemy", false)) else -1)
	if t_deck == k and bool(goal.get("enemy", false)) and _flat(at - mech.global_position, mech.up()).length() < ENGAGE:
		_route.clear()
		_set_mode("fight", str(goal["text"]), "fight %s on deck %d" % [str(goal["key"]), k])
		if dev_travel and stall > DEV_FIGHT_STALL:
			_dev_jump_near(t_deck, at, k)
		return
	if dev_travel:
		if stall > DEV_STALL or (t_deck != k and _plan_route(k, t_deck).is_empty()):
			if bool(goal.get("enemy", false)) and t_deck == k:
				_dev_jump_near(t_deck, at, k)
			elif str(goal["key"]) == "extract":
				var mk := drive.mission.rules.marker()
				dev_jump(int(mk["deck"]), float(mk["x"]), float(mk["s"]), k)
			else:
				_dev_jump_arrival(t_deck, k)
			return
	var key := "%s@%d" % [str(goal["key"]), k]
	if key != _route_for or _route.is_empty() and t_deck != k:
		_route = _plan_route(k, t_deck)
		_route_for = key
	var wp: Dictionary = _route[0] if not _route.is_empty() else {"deck": k, "at": at, "direct": false}
	if not _route.is_empty() and int(wp["deck"]) == k and _flat(wp["at"] - mech.global_position, mech.up()).length() < ARRIVE:
		_route.pop_front()
		wp = _route[0] if not _route.is_empty() else {"deck": k, "at": at, "direct": false}
	if _route.is_empty() and t_deck != k:
		_set_mode("fight", "no way to deck %d from deck %d" % [t_deck, k], "stuck: no way to deck %d from deck %d" % [t_deck, k])
		return
	_set_mode("travel", "%s (deck %d -> %d)" % [str(goal["text"]), k, t_deck], "travel %s, deck %d -> %d" % [str(goal["key"]), k, t_deck])
	_walk(mech, wp["at"], bool(wp["direct"]), dt)


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
func _dev_jump_arrival(t: int, from: int) -> void:
	var st := drive.stack
	var n := drive.spawn_order.size()
	var me := MechSpawn.owner_of(drive.mech)
	var i := maxi(drive.spawn_order.find(me), 0)
	var slots := st.spawn_transforms(mini(n, 4))
	var a := st.to_deck_arc(slots[mini(i, slots.size() - 1)].origin)
	dev_jump(t, float(a["x"]), float(a["s"]), from)


## DEV: jump to DEV_NEAR m from `at` (an enemy on deck t), at the enemy's height (a turret on a roof: onto the roof),
## each jump from another side (the line from the mech, turned 90 degrees per jump already made).
## Only a spot with a clear line from the mech's eye to the enemy counts; 8 sides x 2 ranges are tried, starting from
## another side each jump.
func _dev_jump_near(t: int, at: Vector3, from: int) -> void:
	var st := drive.stack
	var e := st.to_deck_arc(at)
	var m := st.to_deck_arc(drive.mech.global_position)
	var d := Vector2(float(m["x"]) - float(e["x"]), float(m["s"]) - float(e["s"]))
	var dir0 := (d.normalized() if d.length() > 1.0 else Vector2(0, -1)).rotated(PI * 0.25 * float(dev_jumps))
	for r: float in [DEV_NEAR, DEV_NEAR * 1.6]:
		for i in 8:
			var dir := dir0.rotated(PI * 0.25 * float(i))
			if dev_jump(t, float(e["x"]) + dir.x * r, float(e["s"]) + dir.y * r, from, maxf(float(e["h"]), 0.0), at, false):
				return
	dev_jump(t, float(e["x"]) + dir0.x * DEV_NEAR, float(e["s"]) + dir0.y * DEV_NEAR, from, maxf(float(e["h"]), 0.0))


## DEV ONLY: put this machine's mech on the floor of deck t at (x, s) (or the first floor found stepping along s / x
## from there), standing still. Returns whether it found floor.
## `look`: also require a clear line from the mech's eye there to this point (an enemy); `steps`: try the nearby spots
## too (else only (x, s) itself).
func dev_jump(t: int, x: float, s: float, from: int, h: float = 0.0, look: Vector3 = Vector3.INF, steps_on: bool = true) -> bool:
	var st := drive.stack
	var mech := drive.mech
	var space := mech.get_world_3d().direct_space_state
	var steps := [Vector2.ZERO, Vector2(0, 8), Vector2(0, -8), Vector2(8, 0), Vector2(-8, 0), Vector2(0, 16), Vector2(0, -16),
		Vector2(16, 0), Vector2(-16, 0), Vector2(0, 24), Vector2(0, -24), Vector2(24, 0), Vector2(-24, 0)]
	if not steps_on:
		steps = [Vector2.ZERO]
	for off: Vector2 in steps:
		var base := st.from_deck_arc(t, x + off.x, s + off.y, h)
		var up := st.deck_ring(t).up_at(base)
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
			f = st.deck_ring(t).tangent_at(p)
		f = f.normalized()
		mech.global_transform = Transform3D(Basis(f.cross(up), up, -f), p)
		mech.velocity = Vector3.ZERO
		MechSpawn.rig_of(mech).gait.reset([])
		dev_jumps += 1
		_route.clear()
		_route_for = ""
		_prog_key = ""
		FlowLog.say("dev travel", "deck %d -> %d (x %.0f s %.0f)" % [from, t, x + off.x, s + off.y])
		return true
	if look == Vector3.INF:
		FlowLog.say("dev travel", "deck %d -> %d FAILED: no floor near x %.0f s %.0f" % [from, t, x, s])
		_prog_key = ""
	return false


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
		var t := int(cur.trim_prefix("clear_"))
		var best: EnemyBase = null
		var best_d := INF
		var pos := drive.mech.global_position
		for e in drive.combat.squad.enemies:
			if not is_instance_valid(e) or e.destroyed() or e.is_queued_for_deletion() or e.spawn_deck != t:
				continue
			var d := e.global_position.distance_to(pos)
			if d < best_d:
				best_d = d
				best = e
		if best == null:
			return {}   # the host hasn't counted the last kill yet (or the deck is empty): wait
		return {"deck": t, "at": best.global_position, "key": "clear_%d" % t, "text": "clear deck %d (%s)" % [t, best.name],
			"enemy": true}
	return {}


## The special legs from deck `from` to deck `to` (one deck at a time): ramp or shaft waypoints, then the goal.
func _plan_route(from: int, to: int) -> Array:
	var out: Array = []
	var sec := drive.stack.section
	var k := from
	while k != to:
		var down := to > k
		var leg := _leg(sec, k, down)
		if leg.is_empty():
			return out if not out.is_empty() else []
		out.append_array(leg)
		k += 1 if down else -1
	return out


func _leg(sec: SectionPlan, k: int, down: bool) -> Array:
	var ramp := -1
	var shaft := -1
	for ci in sec.connectors.size():
		var c: Dictionary = sec.connectors[ci]
		var pair := (int(c["from"]) == k) if down else (int(c["to"]) == k)
		if not pair:
			continue
		if c["kind"] == "ramp":
			ramp = ci
		elif c["kind"] == "shaft" and down and shaft < 0:
			shaft = ci
	if ramp >= 0:
		var c: Dictionary = sec.connectors[ramp]
		var upper := int(c["from"])
		var lower := int(c["to"])
		var xm := (float(c["x0"]) + float(c["x1"])) * 0.5
		var s_top := sec.line_s(upper, int(c["top_line"]))
		var s_foot_lo := sec.line_s(lower, int(c["foot_line"]))
		var s_foot_up := sec.line_s(upper, int(c["foot_line"]))
		var dir := signf(s_foot_up - s_top)
		var st := drive.stack
		var top_out := st.from_deck_arc(upper, xm, s_top - dir * RAMP_APPROACH, CityPlan.CURB_H)
		var top_in := st.from_deck_arc(upper, xm, s_top + dir * 4.0, CityPlan.CURB_H)
		var foot_in := st.from_deck_arc(lower, xm, s_foot_lo - dir * 4.0, CityPlan.CURB_H)
		var foot_out := st.from_deck_arc(lower, xm, s_foot_lo + dir * RAMP_PAST, CityPlan.CURB_H)
		if down:
			return [{"deck": upper, "at": top_out, "direct": false}, {"deck": upper, "at": top_in, "direct": true},
				{"deck": lower, "at": foot_out, "direct": true}]
		return [{"deck": lower, "at": foot_out, "direct": false}, {"deck": lower, "at": foot_in, "direct": true},
			{"deck": upper, "at": top_out, "direct": true}]
	if shaft >= 0:
		var r := sec.connector_rect(shaft, k)
		var c2 := r.get_center()
		var edge := drive.stack.from_deck_arc(k, c2.x, c2.y, CityPlan.CURB_H)
		return [{"deck": k, "at": edge, "direct": false}]
	return []


func _bind_deck(k: int) -> void:
	_deck = k
	_route_for = ""
	var b := pilot.bot if pilot != null else null
	if b != null and is_instance_valid(b):
		b.bind(drive.mech, drive.combat.rack, drive.combat.player_target, drive.combat.world, drive.combat.squad,
			drive.stack.decks[k].plan, drive.stack.deck_ring(k), drive.cam)
	FlowLog.say("bot deck", "now on deck %d" % k)


## The legs only: move toward `at` (along the deck's roads unless `direct` or close), facing the way it walks.
func _walk(mech: MechController, at: Vector3, direct: bool, dt: float) -> void:
	var up := mech.up()
	var nav: BotNavigator = _navs[clampi(_deck, 0, _navs.size() - 1)] if not _navs.is_empty() else null
	var close := _flat(at - mech.global_position, up).length() < NEAR_DIRECT
	var dir := Vector3.ZERO
	var thrust := false
	if nav != null:
		var st := nav.steer_to(mech, at, dt, mech.get_world_3d().direct_space_state, not (direct or close))
		dir = st["dir"]
		thrust = bool(st["thrust"])
	else:
		dir = _flat(at - mech.global_position, up).normalized()
	if dir.length_squared() < 1e-4:
		return
	var local := mech.global_transform.basis.inverse() * dir
	mech.move_input = Vector2(local.x, -local.z).limit_length(1.0)
	var fwd := _flat(-mech.global_transform.basis.z, up).normalized()
	var ang := fwd.signed_angle_to(dir, up)
	mech.turn_input = clampf(-ang * 2.0, -1.0, 1.0)   # MechController: + turns right (clockwise about up)
	last_dir = dir
	mech.running = true
	mech.thrust_input = thrust


## `say`: the [Flow] line, logged when it changes (kept free of enemy names so target switches don't spam).
func _set_mode(m: String, text: String, say: String) -> void:
	mode = m
	goal_text = text
	if say != _said:
		_said = say
		FlowLog.say("bot", say)


static func _flat(v: Vector3, up: Vector3) -> Vector3:
	return v - up * v.dot(up)
