class_name CombatNet
extends Node
## Combat across machines (co-op step 3, docs/design/weapons.md §5): the crew mission's bridge between the local
## CombatWorld and the crew. Built by MissionCombat in a crew mission (child "CombatNet"). It never touches the wire
## itself: it only talks to the Session autoload through its existing reliable-event API (send_event / event_received).
##
## FIRE RECORDS are SCHEDULED EFFECTS. Every record this machine's own WeaponRack fires (CombatWorld.fired with
## peer == local peer and shooter == "player<local peer>") is queued and sent as one reliable event
##   "combat.fire" {"r": [encode(record), ...]}            at most every FLUSH_INTERVAL (30 Hz); the first after a pause
##                                                       goes out at once
## A client sends it to the host; the HOST RELAYS it unchanged to every other client with {"o": origin peer} added (a
## client only ever talks to the host). Receivers rebuild each record with `peer` and `shooter` taken from the SENDER
## (never from the payload) and call CombatWorld.fire: a record older than the clock is fast-forwarded by now - t
## (CombatWorld.fire / CombatEffect.advance_to). Duplicates (same Combat.shot_key) are dropped.
##
## HITS. The receiving machine simulates the shot like any local one, so CombatWorld.decides applies as built:
##   - a player's mech: ONLY its owner decides (victim decides). B simulates A's broadcast shot against B's own mech and
##     applies damage / impulse / heat through PlayerTarget's verbs once; A and C show the impact cosmetically (they
##     never build a Hit on a puppet). No Hit crosses for mechs, so a Hit can't be applied twice (B's stop is announced
##     as a drop: SHOT DROPS below).
##   - host-owned targets (enemies, dummies; owner_peer 0): the SHOOTER's machine decides. On a client, CombatWorld
##     emits remote_hit; this sends "combat.hit" {id, hit fields} to the host, which checks the hit's shooter is the
##     sender, drops a repeat of (shot, target), finds the target it owns by id and applies the Hit (hit_landed fires).
##     City props and ambient life have their own host-arbitrated paths (CityProps "prop.req", AmbientLife "life.req").
##
## SHOT DROPS (weapons.md §5.1): every machine runs its own copy of a shot, and positions differ a little between
## machines, so a copy can miss here what the deciding machine saw it stop at and fly on into something this machine
## decides (A's shell stops in an enemy on A, B's copy flies on into B's mech: one shot, two hits). So when a projectile
## STOPS on something this machine decides (CombatWorld.shot_decided: a host-owned target hit by our shot, our own mech
## hit by anyone's shot, a prop our shot hit), the crew is told, on the same "combat.hit" kind:
##   - a client: a hit it sends to the host anyway carries the stop as "end": [pt, n(, color)] (merged, no extra event);
##     any other stop goes to the host in {"drop": [[shot, pt, n(, color)], ...]}. Both wait for post_step (same frame).
##   - the host: ends its own copy (drop_shot) and passes every drop on as {"drop": [...]} to every client but the one
##     it came from, with its own drops, once per post_step.
## Each receiver calls CombatWorld.drop_shot: a copy still flying ends at that point (its normal impact once, splash only
## where that machine decides, as for any hit); a copy that already ended keeps its own result; a drop for a shot not
## fired here yet (its record still on the way) waits EARLY_DROP_LIFE s for it; repeats are harmless. Not covered: a
## real race (my copy already hit my mech before the drop arrives: both hits stand; the window is the drop's trip minus
## the flight time between the two contact points), stops outside the projectile sweep (the flak fuse, the mortar's
## landing probe), lasers (resolved at once everywhere) and flame chunks (not projectiles).
##
## GUIDED MISSILES: before each CombatWorld.advance, every puppet's guided track is mirrored into
## world.designators["player<peer>"] = {on, dot} from that owner's NEWEST mech snapshot (Session.mechs.newest: aim
## point + designator flag), falling back to MechPuppet's interpolated aim. So a remote missile steers toward its
## shooter's streamed aim point, and the MissileLaser line shows on every machine.
## LIVE MUZZLES: each puppet's hardpoints are registered as CombatWorld muzzles (its model's HP_<id> node, `muzzle` m
## ahead), so remote laser beams, flamer streams, missile lines and charge glows start at the puppet's weapons.
## CHARGE: weapons with stats.charge >= CHARGE_EVENT_MIN (the railgun's 1 s) send "combat.charge" {hp, t, on} when a
## charge starts and when it is cancelled (released early); receivers draw a ChargeGlow at the puppet's muzzle from t
## on the shared clock until the shot's record or the cancel arrives. The laser's 0.15 s charge is shorter than an
## event's trip, so it sends none (the beam itself is the record).
##
## REPAIR DRONE (docs/design/back-equipment.md): a scheduled effect. When this machine's own rack launches one
## (CombatWorld.drone_launched with this machine's peer / shooter) it sends ONE reliable event
##   "combat.drone" {"t": launch time on the shared clock, "hp": hardpoint}
## relayed by the host like "combat.fire" (shooter / peer from the sender, duplicates dropped by (origin, t)). Each
## receiver calls CombatWorld.launch_drone, so the drone flies from the launcher's PUPPET (an anchor this registers for
## every puppet) on the shared clock; a launch older than the drone's life is dropped, a late one fast-forwards. Nothing
## else crosses: each machine heals only its own mech (RepairDrone), so no heal message exists.
##
## HOST BOTS (docs/design/hangar-bots.md): a bot's rack runs on the host (shooter "player<bot id>", bot id < 0, peer 1).
## add_bot(id) makes this node send its records as "combat.fire" {"r": [...], "b": id} and its drone launches as
## "combat.drone" {t, hp, b} from the host. A receiver accepts "b" only from the host and only for a bot in
## Session.bots, and rebuilds shooter "player<b>" with peer 1 (the machine), so CombatWorld.decides works as for any
## host shot: a bot's hit on a mech is decided by its victim, on a host-owned target by the host.
##
## ENEMY FIRE (W4) is NOT carried here: the host's EnemySync (scripts/mission/sync/enemy_sync.gd) sends every enemy fire record in
## its ordered "enemy.ev" stream (host only, sender-checked there) and each client fires it through CombatWorld.fire with
## peer 1. This node guards it on clients through CombatWorld.fire_gate (_gate): a duplicate enemy record (same shot key)
## is dropped, and an enemy record fired on a client while its CombatWorld is stepping targets (only a locally simulated
## enemy could do that: enemies tick only where owned, i.e. on the host) is refused. Who is hurt follows CombatWorld:
## peer 1 = the victim decides about its own mech, the host about props / life / host-owned targets.
##
## Event rates (records per second while the trigger is held; one record per shot / pulse / chunk): laser 0.8,
## autocannon 2.5, gatling 12 (after its 0.6 s spin-up, which the first record's t already carries), swivel 4, rockets 6
## in 0.5 s then 4 s reload, missiles 3 in 0.6 s then 5 s, mortar 0.29, railgun 0.25 (+ one charge event per shot,
## + one per cancel), flamer 10. Batching caps one shooter at 30 "combat.fire" events a second whatever is held.

signal remote_fired(record: Dictionary, effect: CombatEffect)
signal remote_drone(record: Dictionary, drone: RepairDrone)

const FIRE := "combat.fire"
const HIT := "combat.hit"
const CHARGE := "combat.charge"
const DRONE := "combat.drone"
const DRONE_AHEAD := 5.0          ## s: a drone launch stamped further ahead of the clock than this is refused
const FLUSH_INTERVAL := 1.0 / 30.0
const CHARGE_EVENT_MIN := 0.3     ## s: a charge at least this long is announced (the railgun)
const CHARGE_TIMEOUT := 8.0       ## s past full charge a remote glow with no shot / cancel is dropped
const SEEN_MAX := 2048            ## shot keys remembered for duplicate drops
const MAX_RECORDS := 64           ## records accepted per event
## The fire record's fields as encode() packs them (plus shooter + peer, which come from the sender).
const RECORD_KEYS := ["hardpoint", "weapon", "origin", "dir", "target", "t", "shot_index", "spread"]

var world: CombatWorld
var rack: WeaponRack
var drive: MissionScene           ## the MissionScene (its crew_sync is read lazily: it is built after combat)
var local_peer := 0
var local_shooter := ""
## Counters for tests and diagnostics.
var stats := {"sent_events": 0, "sent_records": 0, "recv_records": 0, "dup": 0, "refused": 0, "relayed": 0,
	"hits_sent": 0, "hits_applied": 0, "hits_dup": 0, "hits_missing": 0, "charges_sent": 0, "charges_recv": 0,
	"drones_sent": 0, "drones_recv": 0, "drones_dup": 0, "drones_expired": 0,
	"enemy_dup": 0, "enemy_local_refused": 0,
	"drops_sent": 0, "drops_relayed": 0, "drops_recv": 0, "drops_applied": 0, "drops_late": 0, "drops_early": 0,
	"drops_refused": 0}

var _queue: Array = []
var _next_flush := -INF
var _seen: Dictionary = {}        ## shot key -> true
var _seen_order: Array[String] = []
var _hits_seen: Dictionary = {}   ## host: "shot|target" -> true
var _hits_order: Array[String] = []
var _charges: Dictionary = {}     ## "shooter/hardpoint" -> {"t", "need", "steps", "glow"}
var _prev_charge: Array[float] = []
var _fired_slots: Dictionary = {} ## slot index -> true: fired during this step
var _muzzled: Dictionary = {}     ## puppet peer -> true once its muzzles are registered
var _hp_nodes: Dictionary = {}    ## "shooter/hardpoint" -> Node3D
var _anchored: Dictionary = {}    ## puppet peer -> true once its CombatWorld anchor is registered
var _bots: Dictionary = {}        ## host: "player<bot id>" -> bot id (add_bot): this machine's bots' records go out too
var _bot_queues: Dictionary = {}  ## host: bot id -> encoded records waiting for the next flush
var _bot_charges: Dictionary = {} ## host: bot id -> {rack, prev: Array[float], fired: {slot index: true}} (charge events)
var _hit_out: Array = []          ## client: "combat.hit" payloads for the host, sent at post_step (a stop merges in as "end")
var _drop_out: Array = []         ## [[shot, pt, n(, color)], origin peer]: drops to send at post_step (client: to the host;
                                  ## host: to every client but the origin)


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "rack": Net.LOCAL, "drive": Net.LOCAL, "local_peer": Net.SPAWN, "local_shooter": Net.SPAWN,
		"stats": Net.LOCAL, "_queue": Net.PRIVATE, "_next_flush": Net.PRIVATE, "_seen": Net.LOCAL, "_seen_order": Net.LOCAL,
		"_hits_seen": Net.LOCAL, "_hits_order": Net.LOCAL, "_charges": Net.LOCAL, "_prev_charge": Net.PRIVATE,
		"_fired_slots": Net.PRIVATE, "_muzzled": Net.LOCAL, "_hp_nodes": Net.LOCAL,
		"_anchored": Net.LOCAL, "_bots": Net.LOCAL, "_bot_queues": Net.PRIVATE,
		"_bot_charges": Net.PRIVATE, "_hit_out": Net.PRIVATE, "_drop_out": Net.PRIVATE}


## The shared clock for CombatWorld.set_clock: Session.host_time() in a session, -1 when there is none.
static func session_clock() -> float:
	var s := Net.session()
	return s.host_time() if s != null and s.online() else -1.0


func bind(w: CombatWorld, r: WeaponRack, td: MissionScene) -> void:
	world = w
	rack = r
	drive = td
	local_peer = CombatWorld.local_peer()
	local_shooter = "player%d" % local_peer
	world.fired.connect(_on_fired)
	world.remote_hit.connect(_on_remote_hit)
	world.drone_launched.connect(_on_drone_launched)
	world.shot_decided.connect(_on_shot_decided)
	world.fire_gate = _gate
	if rack != null:
		rack.fired.connect(func(slot: int) -> void: _fired_slots[slot - 1] = true)
	var s := Net.session()
	if s != null and not s.event_received.is_connected(_on_event):
		s.event_received.connect(_on_event)


func _exit_tree() -> void:
	if world != null and is_instance_valid(world) and world.fire_gate == Callable(self, "_gate"):
		world.fire_gate = Callable()
	var s := Net.session()
	if s != null and s.event_received.is_connected(_on_event):
		s.event_received.disconnect(_on_event)


func _online() -> bool:
	var s := Net.session()
	return s != null and s.online()


## Host: bot `id` (pilot id < 0) fires on this machine: send its fire records and drone launches to the crew, and (with
## its rack `r`) its charge starts / cancels as "combat.charge" {hp, t, on, b}, like the local rack's.
func add_bot(id: int, r: WeaponRack = null) -> void:
	if id >= 0:
		return
	_bots["player%d" % id] = id
	if r != null:
		var fired := {}
		_bot_charges[id] = {"rack": r, "prev": [] as Array[float], "fired": fired}
		r.fired.connect(func(slot: int) -> void: fired[slot - 1] = true)


# --- Records on the wire ---------------------------------------------------------------------------------

## A fire record as plain data: [hardpoint, weapon, origin, dir, target, t, shot_index, spread].
static func encode(rec: Dictionary) -> Array:
	return [str(rec["hardpoint"]), str(rec["weapon"]), rec["origin"] as Vector3, rec["dir"] as Vector3,
		rec["target"] as Vector3, float(rec["t"]), int(rec["shot_index"]), float(rec.get("spread", 0.0))]


## The record encode() packed, fired by `peer` (shooter "player<peer>"), or {} when anything is malformed or the weapon
## is not a player weapon.
static func decode(a: Variant, peer: int) -> Dictionary:
	if not (a is Array) or (a as Array).size() != RECORD_KEYS.size() or peer <= 0:
		return {}
	var v := a as Array
	if not (v[0] is String and v[1] is String and v[2] is Vector3 and v[3] is Vector3 and v[4] is Vector3):
		return {}
	if not ((v[5] is float or v[5] is int) and v[6] is int and (v[7] is float or v[7] is int)):
		return {}
	var weapon := str(v[1])
	if not MechCatalog.WEAPONS.has(weapon) or MechCatalog.is_equipment(weapon) or str(v[0]).length() > 24:
		return {}
	var o: Vector3 = v[2]
	var d: Vector3 = v[3]
	var tg: Vector3 = v[4]
	if not (o.is_finite() and d.is_finite() and tg.is_finite() and is_finite(float(v[5])) and is_finite(float(v[7]))):
		return {}
	if d.length_squared() < 1e-8:
		return {}
	return {"shooter": "player%d" % peer, "peer": peer, "hardpoint": str(v[0]), "weapon": weapon, "origin": o,
		"dir": d.normalized(), "target": tg, "t": float(v[5]), "shot_index": int(v[6]), "spread": clampf(float(v[7]), 0.0, 45.0)}


static func encode_hit(target_id: String, h: Hit) -> Dictionary:
	return {"id": target_id, "dmg": h.damage, "imp": h.impulse, "heat": h.heat, "pt": h.point, "n": h.normal,
		"comp": h.component, "w": h.weapon, "sh": h.shooter, "shot": h.shot}


static func decode_hit(d: Dictionary) -> Hit:
	if not (d.get("imp") is Vector3 and d.get("pt") is Vector3 and d.get("n") is Vector3):
		return null
	var h := Hit.new()
	h.damage = clampf(float(d.get("dmg", 0.0)), 0.0, 10000.0)
	h.impulse = d["imp"]
	h.heat = clampf(float(d.get("heat", 0.0)), 0.0, 1000.0)
	h.point = d["pt"]
	h.normal = d["n"]
	h.component = str(d.get("comp", "")).left(32)
	h.weapon = str(d.get("w", "")).left(32)
	h.shooter = str(d.get("sh", "")).left(32)
	h.shot = str(d.get("shot", "")).left(96)
	if not (h.impulse.is_finite() and h.point.is_finite() and is_finite(h.damage) and is_finite(h.heat)):
		return null
	return h


# --- Out ---------------------------------------------------------------------------------------------------

func _on_fired(rec: Dictionary) -> void:
	if int(rec.get("peer", 0)) != local_peer or not _online():
		return
	var sh := str(rec.get("shooter", ""))
	if sh != local_shooter and not _bots.has(sh):
		return
	if not MechCatalog.WEAPONS.has(str(rec.get("weapon", ""))):
		return
	_mark_seen(Combat.shot_key(rec))
	if sh == local_shooter:
		_queue.append(encode(rec))
	else:
		var b := int(_bots[sh])
		if not _bot_queues.has(b):
			_bot_queues[b] = []
		(_bot_queues[b] as Array).append(encode(rec))


## This machine's own drone launch: one reliable event (records already queued go first).
func _on_drone_launched(rec: Dictionary, _d: RepairDrone) -> void:
	var sh := str(rec.get("shooter", ""))
	if int(rec.get("peer", 0)) != local_peer or (sh != local_shooter and not _bots.has(sh)) or not _online():
		return
	var who := local_peer if sh == local_shooter else int(_bots[sh])
	_mark_seen(_drone_key(who, float(rec.get("t", 0.0))))
	flush(true)
	var d := {"t": float(rec.get("t", world.now)), "hp": str(rec.get("hardpoint", "back"))}
	if who != local_peer:
		d["b"] = who
	Net.session().send_event(0, DRONE, d)
	stats["drones_sent"] = int(stats["drones_sent"]) + 1


static func _drone_key(peer: int, t: float) -> String:
	return "drone|%d|%.4f" % [peer, t]


## CombatWorld.fire_gate: on a client in a crew mission, enemy records are the host's (EnemySync relays them). Refuse a
## duplicate (same shot key) and one fired while the world steps its targets (a locally simulated enemy: never valid on
## a client). Everything else (player records, the host, offline) passes.
func _gate(rec: Dictionary) -> bool:
	if not (bool(rec.get("enemy", false)) or str(rec.get("team", "")) == "enemy"):
		return true
	var s := Net.session()
	if s == null or not s.online() or s.hosting:
		return true
	if world.stepping_targets:
		stats["enemy_local_refused"] = int(stats["enemy_local_refused"]) + 1
		return false
	var key := "e|" + Combat.shot_key(rec)
	if _seen.has(key):
		stats["enemy_dup"] = int(stats["enemy_dup"]) + 1
		return false
	_mark_seen(key)
	return true


## A shot this machine decided on a target another machine owns: a host-owned target hit from a client goes to the host
## (queued until post_step, so the shot's stop can ride along as "end").
func _on_remote_hit(target_id: String, h: Hit) -> void:
	var s := Net.session()
	if s == null or not s.online() or s.hosting:
		return
	_hit_out.append(encode_hit(target_id, h))


## A projectile stopped here on something this machine decides (CombatWorld.shot_decided): tell the crew (see SHOT DROPS).
func _on_shot_decided(rec: Dictionary, pt: Vector3, n: Vector3, c: Color) -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	var k := Combat.shot_key(rec)
	var end: Array = [pt, n]
	if not c.is_equal_approx(LowPolyPalette.GREY):
		end.append(c)
	stats["drops_sent"] = int(stats["drops_sent"]) + 1
	if not s.hosting and not _hit_out.is_empty():
		var last: Dictionary = _hit_out.back()
		if str(last.get("shot", "")) == k and not last.has("end"):
			last["end"] = end              # the hit that stopped it, sent anyway: no extra event
			return
	_drop_out.append([[k] + end, local_peer])


## Send the queued hits and drops (post_step: once a frame).
func flush_hits() -> void:
	if _hit_out.is_empty() and _drop_out.is_empty():
		return
	var s := Net.session()
	if s == null or not s.online():
		_hit_out.clear()
		_drop_out.clear()
		return
	if not s.hosting:
		for d: Dictionary in _hit_out:
			s.send_event(1, HIT, d)
			stats["hits_sent"] = int(stats["hits_sent"]) + 1
		_send_drops(s, 1, _drop_out.map(func(x: Array) -> Array: return x[0]))
	else:
		for p: int in s.roster:
			if p <= 1:
				continue
			var items: Array = []
			for x: Array in _drop_out:
				if int(x[1]) != p:
					items.append(x[0])
			_send_drops(s, p, items)
	_hit_out = []
	_drop_out = []


func _send_drops(s: NetSession, to: int, items: Array) -> void:
	var i := 0
	while i < items.size():
		s.send_event(to, HIT, {"drop": items.slice(i, i + MAX_RECORDS)})
		i += MAX_RECORDS


## Send what is queued now (at most every FLUSH_INTERVAL unless `force`).
func flush(force: bool = false) -> void:
	if _queue.is_empty() and _bot_queues.is_empty():
		return
	var s := Net.session()
	if s == null or not s.online():
		_queue.clear()
		_bot_queues.clear()
		return
	var now := world.now
	if not force and now < _next_flush:
		return
	if not _queue.is_empty():
		s.send_event(0, FIRE, {"r": _queue})
		stats["sent_events"] = int(stats["sent_events"]) + 1
		stats["sent_records"] = int(stats["sent_records"]) + _queue.size()
	for b: int in _bot_queues:
		var q: Array = _bot_queues[b]
		s.send_event(0, FIRE, {"r": q, "b": b})
		stats["sent_events"] = int(stats["sent_events"]) + 1
		stats["sent_records"] = int(stats["sent_records"]) + q.size()
	_queue = []
	_bot_queues.clear()
	_next_flush = now + FLUSH_INTERVAL


# --- Per step (MissionCombat calls these around CombatWorld.advance) --------------------------------------

## Before the world advances: mirror every puppet's guided track into world.designators, register its muzzles.
func pre_advance() -> void:
	var cs: Variant = drive.crew_sync if drive != null else null
	if cs == null or not is_instance_valid(cs):
		return
	var s := Net.session()
	var puppets: Dictionary = (cs as CrewSync).puppets
	for p: int in puppets:
		var pp := puppets[p] as MechPuppet
		if pp == null or not is_instance_valid(pp):
			continue
		var on := pp.designator
		var dot := pp.aim_point
		var st: NetMechState = s.mechs.newest(p) if s != null and s.mechs != null else null
		if st != null:
			on = st.designator
			dot = st.aim
		var key := "player%d" % p
		if not _anchored.has(p):
			_register_anchor(p)
		var d: Variant = world.designators.get(key)
		if d is Dictionary:
			(d as Dictionary)["on"] = on and pp.shown != null
			(d as Dictionary)["dot"] = dot
		else:
			world.designators[key] = {"on": on and pp.shown != null, "dot": dot}
		if not _muzzled.has(p) and pp.rig != null and pp.rig.model != null:
			_muzzled[p] = true
			var model := pp.rig.model
			for hp: Variant in model.loadout:
				var w := str(model.loadout[hp])
				if w != "":
					world.set_muzzle(key, str(hp), _puppet_muzzle.bind(model, key, str(hp), float(MechCatalog.weapon(w).get("muzzle", 0.0))))


## Register puppet `p`'s mech as the CombatWorld anchor of "player<p>" (a remote repair drone follows it).
func _register_anchor(p: int) -> void:
	var cs: Variant = drive.crew_sync if drive != null else null
	if cs == null or not is_instance_valid(cs):
		return
	var pp := (cs as CrewSync).puppets.get(p) as MechPuppet
	if pp == null or not is_instance_valid(pp) or pp.mech == null:
		return
	_anchored[p] = true
	world.set_anchor("player%d" % p, _puppet_anchor.bind(pp))


func _puppet_anchor(pp: MechPuppet) -> Node3D:
	return pp.mech if is_instance_valid(pp) and pp.mech != null and is_instance_valid(pp.mech) else null


## A puppet's hardpoint muzzle now: `ahead` m ahead of its HP_<id> node (its weapon models are not turned remotely).
func _puppet_muzzle(model: MechModel, key: String, hp: String, ahead: float) -> Vector3:
	var k := key + "/" + hp
	var n: Variant = _hp_nodes.get(k)
	if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
		n = null
		if is_instance_valid(model):
			n = model.find_child("HP_" + hp, true, false)
		_hp_nodes[k] = n
	if n == null:
		return model.global_position if is_instance_valid(model) and model.is_inside_tree() else Vector3.ZERO
	return (n as Node3D).global_transform * Vector3(0, 0, -ahead)


## After the world advanced: announce charges, send the queued records, draw remote charge glows.
func post_step(dt: float) -> void:
	_watch_charges(rack, _prev_charge, _fired_slots, 0)
	for b: int in _bot_charges:
		var c: Dictionary = _bot_charges[b]
		var br: Variant = c["rack"]
		if br != null and is_instance_valid(br):
			_watch_charges(br as WeaponRack, c["prev"], c["fired"], b)
		(c["fired"] as Dictionary).clear()
	flush()
	flush_hits()
	_fired_slots.clear()
	_draw_charges(dt)


## A rack's charges this step: a start or a cancel (released without firing) of a long charge goes out. `bot` != 0:
## a host bot's rack (the event carries "b").
func _watch_charges(r: WeaponRack, prev_charge: Array[float], fired: Dictionary, bot: int) -> void:
	if r == null:
		return
	prev_charge.resize(r.slot_count())
	for i in r.slot_count():
		var m: WeaponMount = r.mounts[i]
		var cur := m.charge if m != null else 0.0
		var prev := prev_charge[i]
		prev_charge[i] = cur
		if m == null or float(m.stats.get("charge", 0.0)) < CHARGE_EVENT_MIN:
			continue
		var d := {}
		if prev <= 0.0 and cur > 0.0:
			d = {"hp": r.hardpoints[i], "t": world.now - cur, "on": true}
		elif prev > 0.0 and cur <= 0.0 and not fired.has(i):
			d = {"hp": r.hardpoints[i], "on": false}
		if d.is_empty():
			continue
		if bot != 0:
			d["b"] = bot
		_send_charge(d)


func _send_charge(d: Dictionary) -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	flush(true)                       # keep the order: records already fired go first
	s.send_event(0, CHARGE, d)
	stats["charges_sent"] = int(stats["charges_sent"]) + 1


func _draw_charges(dt: float) -> void:
	for k: String in _charges.keys():
		var c: Dictionary = _charges[k]
		var need := float(c["need"])
		var e := world.now - float(c["t"])
		var glow := c["glow"] as ChargeGlow
		if e > need + CHARGE_TIMEOUT or not is_instance_valid(glow):
			_drop_charge(k)
			continue
		var f := clampf(e / maxf(need, 1e-3), 0.0, 1.0)
		var steps := int(c["steps"])
		if steps > 0 and f > 0.0:
			f = maxf(floorf(f * float(steps)), 1.0) / float(steps)
		var parts := k.split("/")
		var m := world.muzzle_of({"shooter": parts[0], "hardpoint": parts[1] if parts.size() > 1 else ""})
		glow.show_charge(m.call() if m.is_valid() else Vector3.ZERO, f if m.is_valid() else 0.0, dt)


func _drop_charge(k: String) -> void:
	var c: Dictionary = _charges.get(k, {})
	var g: Variant = c.get("glow")
	if g != null and is_instance_valid(g):
		(g as Node).queue_free()
	_charges.erase(k)


# --- In ----------------------------------------------------------------------------------------------------

func _on_event(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if kind != FIRE and kind != HIT and kind != CHARGE and kind != DRONE:
		return
	var s := Net.session()
	if s == null or not s.online() or world == null:
		return
	if kind == HIT:
		if s.hosting:
			if data.has("drop"):
				_recv_drops(from, data.get("drop"))
			else:
				_host_hit(from, data)
		elif from == 1:
			_recv_drops(0, data.get("drop"))
		return
	# The origin: a client's event reaches only the host (from = the client); the host's relay says who fired ("o").
	var origin := from
	if not s.hosting and from == 1:
		origin = int(data.get("o", 1))
	if origin <= 0 or origin == local_peer or not s.roster.has(origin):
		return
	# A host bot's records / drone ("b"): only from the host, only for a seated bot (never relayed: the host sent them
	# to everyone).
	var bot := 0
	if data.has("b"):
		bot = int(data.get("b", 0))
		if origin != 1 or s.hosting or not s.is_bot(bot):
			stats["refused"] = int(stats["refused"]) + 1
			return
	if s.hosting and from != 1:
		var fwd := data.duplicate()
		fwd["o"] = from
		for p: int in s.roster:
			if p != 1 and p != from:
				s.send_event(p, kind, fwd)
				stats["relayed"] = int(stats["relayed"]) + 1
	if kind == FIRE:
		var recs: Variant = data.get("r")
		if not (recs is Array):
			return
		var n := 0
		for a: Variant in recs:
			n += 1
			if n > MAX_RECORDS:
				break
			var rec := decode(a, origin)
			if bot != 0 and not rec.is_empty():
				rec["shooter"] = "player%d" % bot
			_apply_record(rec)
	elif kind == DRONE:
		_remote_drone(bot if bot != 0 else origin, data)
	else:
		_remote_charge(bot if bot != 0 else origin, data)


func _apply_record(rec: Dictionary) -> void:
	if rec.is_empty():
		stats["refused"] = int(stats["refused"]) + 1
		return
	var key := Combat.shot_key(rec)
	if _seen.has(key):
		stats["dup"] = int(stats["dup"]) + 1
		return
	_mark_seen(key)
	stats["recv_records"] = int(stats["recv_records"]) + 1
	_drop_charge("%s/%s" % [rec["shooter"], rec["hardpoint"]])
	var e := world.fire(rec)
	remote_fired.emit(rec, e)


## Another crew member's drone launch: validated, duplicates dropped, expired ones ignored, then launched here from
## that member's puppet on the shared clock (CombatWorld.launch_drone fast-forwards a late one).
## `origin`: the launcher's pilot id (a bot's is negative; its record's peer is the host's, 1).
func _remote_drone(origin: int, data: Dictionary) -> void:
	var tv: Variant = data.get("t")
	if not (tv is float or tv is int) or not is_finite(float(tv)) or float(tv) > world.now + DRONE_AHEAD:
		stats["refused"] = int(stats["refused"]) + 1
		return
	var t := float(tv)
	var key := _drone_key(origin, t)
	if _seen.has(key):
		stats["drones_dup"] = int(stats["drones_dup"]) + 1
		return
	_mark_seen(key)
	if world.now - t >= float(world.stats("repair_drone").get("life", 60.0)):
		stats["drones_expired"] = int(stats["drones_expired"]) + 1
		return
	if not _anchored.has(origin):
		_register_anchor(origin)
	var rec := {"shooter": "player%d" % origin, "peer": maxi(origin, 1), "hardpoint": str(data.get("hp", "back")).left(24),
		"weapon": "repair_drone", "t": t}
	var d := world.launch_drone(rec)
	stats["drones_recv"] = int(stats["drones_recv"]) + 1
	remote_drone.emit(rec, d)


## `origin`: the charging pilot's id (a host bot's is negative).
func _remote_charge(origin: int, data: Dictionary) -> void:
	var hp := str(data.get("hp", "")).left(24)
	var k := "player%d/%s" % [origin, hp]
	_drop_charge(k)
	if not bool(data.get("on", false)):
		return
	var w := ""
	var cs: Variant = drive.crew_sync if drive != null else null
	if cs != null and is_instance_valid(cs):
		var pp := (cs as CrewSync).puppets.get(origin) as MechPuppet
		if pp != null and pp.rig != null and pp.rig.model != null:
			w = str(pp.rig.model.loadout.get(hp, ""))
	var st := world.stats(w) if w != "" else {}
	var need := float(st.get("charge", 0.0))
	if need <= 0.0:
		return
	stats["charges_recv"] = int(stats["charges_recv"]) + 1
	var g := ChargeGlow.new()
	add_child(g)
	_charges[k] = {"t": float(data.get("t", world.now)), "need": need, "steps": int(st.get("charge_steps", 0)), "glow": g}


func _host_hit(from: int, data: Dictionary) -> void:
	var h := decode_hit(data)
	var id := str(data.get("id", "")).left(64)
	if h == null or id == "" or h.shooter != "player%d" % from:
		stats["refused"] = int(stats["refused"]) + 1
		return
	var k := "%s|%s" % [h.shot, id]
	if _hits_seen.has(k):
		stats["hits_dup"] = int(stats["hits_dup"]) + 1
		return
	_hits_seen[k] = true
	_hits_order.append(k)
	if _hits_order.size() > SEEN_MAX:
		_hits_seen.erase(_hits_order.pop_front())
	var applied := false
	for t in world.targets:
		if is_instance_valid(t) and t.target_id == id and t.owner_peer <= 0 and world.owns(t):
			t.apply_hit(h)
			world.hit_landed.emit(t, h)
			stats["hits_applied"] = int(stats["hits_applied"]) + 1
			applied = true
			break
	if not applied:
		stats["hits_missing"] = int(stats["hits_missing"]) + 1
	var end: Variant = data.get("end")
	if end is Array:                      # the shot stopped there on the sender: its drop, for here and the other clients
		_recv_drops(from, [[h.shot] + (end as Array)])


## Drops (see SHOT DROPS) from `origin` (a client, on the host: applied here and passed on to the other clients) or from
## the host (origin 0, on a client: applied). Malformed entries are refused one by one.
func _recv_drops(origin: int, items: Variant) -> void:
	if not (items is Array):
		stats["drops_refused"] = int(stats["drops_refused"]) + 1
		return
	var host := origin > 0
	var n := 0
	for a: Variant in items:
		n += 1
		if n > MAX_RECORDS:
			break
		var d := decode_drop(a)
		if d.is_empty():
			stats["drops_refused"] = int(stats["drops_refused"]) + 1
			continue
		stats["drops_recv"] = int(stats["drops_recv"]) + 1
		var key := str(d["shot"])
		var remember := not _seen.has(key) and not _seen.has("e|" + key)
		match world.drop_shot(key, d["pt"], d["n"], d["c"], remember):
			1:
				stats["drops_applied"] = int(stats["drops_applied"]) + 1
			-1:
				stats["drops_early"] = int(stats["drops_early"]) + 1
			_:
				stats["drops_late"] = int(stats["drops_late"]) + 1
		if host:
			_drop_out.append([a, origin])
			stats["drops_relayed"] = int(stats["drops_relayed"]) + 1


## A drop entry [shot, pt, n(, color)] as {shot, pt, n, c}, or {} when malformed.
static func decode_drop(a: Variant) -> Dictionary:
	if not (a is Array) or (a as Array).size() < 3 or (a as Array).size() > 4:
		return {}
	var v := a as Array
	if not (v[0] is String and v[1] is Vector3 and v[2] is Vector3) or str(v[0]).length() > 96 or str(v[0]) == "":
		return {}
	var pt: Vector3 = v[1]
	var n: Vector3 = v[2]
	if not (pt.is_finite() and n.is_finite()):
		return {}
	var c: Color = LowPolyPalette.GREY
	if v.size() == 4:
		if not (v[3] is Color):
			return {}
		c = v[3]
	return {"shot": str(v[0]), "pt": pt, "n": n, "c": c}


func _mark_seen(key: String) -> void:
	if _seen.has(key):
		return
	_seen[key] = true
	_seen_order.append(key)
	if _seen_order.size() > SEEN_MAX:
		_seen.erase(_seen_order.pop_front())
