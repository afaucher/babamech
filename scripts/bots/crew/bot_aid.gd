class_name BotAid
extends RefCounted
## What a bot does about being helped (playtest R2.6; docs/design/pacing-director.md §4, DownedRules): one per MissionBot,
## on the machine that runs the bot (the host for a crew bot). Reads only: drones are scheduled effects every machine
## runs (CombatWorld.effects), the crew comes from DownedCrew's queries; it writes nothing but this bot's own inputs
## (MissionBot applies the leash) and the wait its own PlayerTarget asks for (PlayerTarget.revive_wait).
##
##   LEASH    healer(world, pt): a CREWMATE's repair drone repairing this bot now (on its orbit, this bot repairable and
##            within the drone's radius, measured from the launcher like RepairDrone.reach_to; up to LEASH_CATCH m past
##            it, so a bot that drifted out walks back in). MissionBot keeps where the bot would stop (its position plus
##            its outward braking distance) inside radius - LEASH_EDGE: it may move and fight, but near that edge a move
##            outward loses its outward part (no run, no hop), and past radius - LEASH_PULL it walks back in. Its own drone orbits it, so it never leashes it.
##   WAIT     wait_s(), installed as the bot's PlayerTarget.revive_wait (the bot can't hold the respawn key): the
##            threshold its down_time is compared against each tick (only while no revive is in progress). A downed bot
##            waits while its own drone is self-reviving it (R2.9, CombatWorld.self_reviving) or a crewmate who can revive
##            (DownedCrew.can_revive) is plausibly coming: a bot whose MissionBot is set on reviving it, or anyone within
##            the drone's radius + WAIT_REACH_PAD, or anyone who got WAIT_GAIN m nearer in the last WAIT_STALL s; for the
##            first WAIT_GRACE s any reviver counts (time to react). Never past WAIT_CAP s. Nobody able to revive: the old
##            DownedRules.BOT_ALONE_WAIT. Nobody coming any more: redeploy now.
##   SKIP     self_reviving(world, id): that pilot's own drone is reviving it (MissionBot leaves the wreck alone).

const LEASH_EDGE := 3.0       ## m inside the drone's radius where an outward move stops
const LEASH_PULL := 1.0       ## m inside the radius past which the bot walks back in
const LEASH_CATCH := 12.0     ## m past the radius a repairing drone still holds the bot (it walks back in)
const WAIT_GRACE := DownedRules.BOT_REVIVE_WAIT   ## s any reviver counts as coming (time to react)
const WAIT_CAP := 45.0        ## s a downed bot waits at most (then redeploys whatever happens)
const WAIT_STALL := 6.0       ## s a reviver may go without getting WAIT_GAIN m nearer before it no longer counts
const WAIT_GAIN := 4.0        ## m nearer that counts as coming
const WAIT_REACH_PAD := 5.0   ## m past the drone's radius that counts as there (the beam is about to start)

var drive: MissionScene       ## the mission (its DownedCrew, combat world, crew bots)
var pt: PlayerTarget          ## this bot's PlayerTarget
var me := 0                   ## this bot's pilot id
var verdict := ""             ## the last wait decision: self | grace | coming | alone | stalled | cap (tests, logs)
var _seen: Dictionary = {}    ## reviver pilot id -> [nearest distance this downing, down_time when it got WAIT_GAIN nearer]
var _last_down := 0.0         ## down_time at the previous call (a smaller one = a new downing)


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "pt": Net.LOCAL, "me": Net.LOCAL, "verdict": Net.PRIVATE, "_seen": Net.PRIVATE,
		"_last_down": Net.PRIVATE}


func _init(td: MissionScene = null, target: PlayerTarget = null, pilot_id: int = 0) -> void:
	drive = td
	pt = target
	me = pilot_id


## The repair drone's radius (catalog `radius`, 15 m).
static func radius_of(d: RepairDrone) -> float:
	return float(d.stats.get("radius", 15.0))


## A crewmate's repair drone repairing `target` now (see LEASH), the nearest one; null when none.
static func healer(world: CombatWorld, target: PlayerTarget) -> RepairDrone:
	if world == null or target == null or not target.is_inside_tree() or not RepairDrone.repairable(target):
		return null
	var best: RepairDrone = null
	var best_d := INF
	for e in world.effects:
		if not (e is RepairDrone) or not is_instance_valid(e):
			continue
		var d := e as RepairDrone
		if not d.repairing() or d.shooter() == target.target_id:
			continue
		var r := d.reach_to(target.global_position)
		if r <= radius_of(d) + LEASH_CATCH and r < best_d:
			best_d = r
			best = d
	return best


## Pilot `target_id`'s own drone is reviving it (R2.9): CombatWorld.self_reviving when the combat world has it.
static func self_reviving(world: CombatWorld, target_id: String) -> bool:
	if world == null or not world.has_method("self_reviving"):
		return false
	return bool(world.call("self_reviving", target_id))


## PlayerTarget.revive_wait for this bot: the down_time threshold after which it redeploys (see WAIT).
func wait_s() -> float:
	var t := pt.down_time if pt != null else 0.0
	if t < _last_down:
		_seen.clear()                  # a new downing
	_last_down = t
	var hold := t + 1.0                # not yet: compared against down_time every tick
	if pt != null and self_reviving(_world(), pt.target_id):
		return _say("self", hold)
	var dc: DownedCrew = drive.downed if drive != null else null
	if dc == null:
		return _say("alone", DownedRules.BOT_ALONE_WAIT)
	var any := false
	var coming := false
	var at := pt.global_position if pt != null and pt.is_inside_tree() else Vector3.INF
	for m: Dictionary in dc.members():
		var id := int(m["peer"])
		if id == me or not dc.can_revive(id) or m["mech"] == null or not is_instance_valid(m["mech"]):
			continue
		any = true
		var d := (m["mech"] as Node3D).global_position.distance_to(at) if at != Vector3.INF else INF
		var s: Array = _seen.get(id, [d, t])
		if d < float(s[0]) - WAIT_GAIN:
			s = [d, t]
		_seen[id] = s
		var cb: Variant = drive.crew_bots.get(id) if bool(m["bot"]) else null
		var bot := cb as CrewBot if cb != null and is_instance_valid(cb) else null
		if bot != null and bot.ai != null and bot.ai.reviving_peer() == me:
			coming = true              # its MissionBot is on its way / beaming
		elif d <= _reach() + WAIT_REACH_PAD or t - float(s[1]) <= WAIT_STALL:
			coming = true
	if not any:
		return _say("alone", DownedRules.BOT_ALONE_WAIT)
	if t >= WAIT_CAP:
		return _say("cap", 0.0)
	if t < WAIT_GRACE:
		return _say("grace", hold)
	return _say("coming", hold) if coming else _say("stalled", 0.0)


func _world() -> CombatWorld:
	return drive.combat.world if drive != null and drive.combat != null else null


## The drone's radius from the catalog.
func _reach() -> float:
	var w := _world()
	return float(w.stats(DownedRules.REVIVER).get("radius", 15.0)) if w != null else 15.0


func _say(v: String, wait: float) -> float:
	if v != verdict:
		verdict = v
		if v != "grace":
			FlowLog.say("bot revive", "pilot %d downed %.1f s: %s" % [me, pt.down_time if pt != null else 0.0, v])
	return wait
