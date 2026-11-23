class_name EnemySync
extends Node
## Enemies in a crew mission (W4, cast's M3: the host-owned world). Built by TestDrive in a crew mission, child
## "EnemySync" (`TestDrive.enemy_sync`). Solo and offline play never build it: the enemies are exactly as before.
##
## THE HOST spawns the encounter (TestDrive.spawn_enemies: EnemySpawner from the mission seed, in front of the entry on
## the entry deck) and runs every enemy's AI, as solo. Each enemy gets a net id (`EnemyBase.net_id`, its number in the
## manifest) and `spawn_deck`. This node then
##   - answers a client's "enemy.req" with the MANIFEST "enemy.spawn" {e: [entry...]} (entry = [n, id, type, deck, xform,
##     dead, broken components, hp fractions, wave id ("" = garrison; plan mode)]), so a client that loads late still gets every enemy as it is now;
##   - streams pose / AI state / aim / heat / HP (Session.enemies.send, NetWire.T_ENEMY): ACTIVE_RATE while an enemy's
##     sample changed since the last one sent, IDLE_RATE as a keep-alive, nothing once it is dead;
##   - sends DISCRETE CHANGES as one reliable "enemy.ev" {l: [[kind, n, data]...]} per physics frame (in order):
##       add {entry}        an enemy spawned after the manifest          gone {}        removed (wreck cleanup, clear)
##       alert {state}      alerted (spotted / relay / lost)              tele {w, k, t0, dur, lock}  telegraph started at
##       tele_x {reason}    telegraph cancelled                           t0 on the shared clock (rule 7: dur >= 0.3 s)
##       dmg {c, r, wk}     a component took damage (audio tick)          comp {c}       a component was destroyed
##       dead {cause, r}    destroyed (wreck)                             heat {on}      overheated / rebooted
##       fire {rec}         an ENEMY FIRE RECORD (n = 0, shooter = the enemy's target_id, peer 1): every client fires it
##                          on its CombatWorld, so every machine sees the shot and the victim's machine decides about its
##                          own mech (CombatWorld.decides). CombatNet's fire_gate drops a duplicate on a client.
## A puppet never fires (EnemyBase._fire_one_round is gated to the host), and its muzzles are posed from the streamed aim
## (EnemyBase.muzzle_world(weapon_id)), so beams and flashes can start at the puppet.
## THE CLIENT spawns nothing itself (TestDrive.spawn_enemies returns none): it asks for the manifest (every REQ_EVERY s
## until it has it), builds a PUPPET per entry (`EnemyBase.puppet`: same class, meshes and hit spheres, so its own shots
## hit it and CombatNet carries them to the host by target id; CombatWorld never ticks it here, so no AI runs), poses it
## every physics frame from Session.enemies.pose(n) and EnemyBase.puppet_apply / puppet_tick, shows a telegraph from its
## event on the shared clock, and plays the same destruction, debris (looks generator) and wreck from comp / dead.
## Replayed squad events (alert, telegraph, damage, heat) go through EnemySquad.enemy_event, so CombatAudio plays them.
##
## DAMAGE TO ENEMIES (rule 3): the attacker's machine decides; a client's hit reaches the host's real enemy through
## CombatNet ("combat.hit" by target id), and its HP / destruction come back through the stream and the events.
## MISSIONS: alive_per_deck(enemies, decks) (TestDrive.enemies_alive_per_deck()) counts alive enemies by spawn_deck.

signal telegraph_received(enemy: EnemyBase, t0: float, dur: float, arrival: float)
signal manifest_received(count: int)

const REQ := "enemy.req"
const SPAWN := "enemy.spawn"
const EV := "enemy.ev"
const REQ_EVERY := 0.75           ## s between a client's manifest requests until one arrives
const MAX_FIRE_RECORDS := 64
const SETTLE := 0.25              ## s an enemy keeps the active rate after its last change (the puppet sees it stop)

var drive: TestDrive
var world: CombatWorld
var squad: EnemySquad
var ring: RingFrame
var hosting := false
var by_net: Dictionary = {}       ## net id -> EnemyBase (host: the real ones; client: the puppets)
var has_manifest := false
## Counters for tests and diagnostics.
var stats := {"manifests_sent": 0, "manifests_recv": 0, "events_sent": 0, "items_sent": 0, "items_recv": 0,
	"fire_sent": 0, "fire_recv": 0, "fire_refused": 0, "spawned": 0, "removed": 0, "streamed": 0, "posed": 0}

var _next_n := 1
var _queue: Array = []            ## host: [kind, n, data] waiting for this frame's "enemy.ev"
var _last_sent: Dictionary = {}   ## host: n -> NetEnemyState last streamed
var _sent_at: Dictionary = {}     ## host: n -> host_time it was last streamed
var _active_until: Dictionary = {} ## host: n -> host_time until which it streams at the active rate (SETTLE after a change)
var _next_req := 0.0              ## client: host_time of the next manifest request
var _tele: Dictionary = {}        ## client: n -> {w, t0, dur, lock}
var _broken: Dictionary = {}      ## client: n -> {component: true} already broken here
var _prev: Dictionary = {}        ## client: n -> [pos, aim] shown last frame (move / slew for the presentation)


## Authority (scripts/net/net.gd): scene wiring and this machine's bookkeeping; the enemies declare their own state.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "world": Net.LOCAL, "squad": Net.LOCAL, "ring": Net.LOCAL, "hosting": Net.LOCAL,
		"by_net": Net.LOCAL, "has_manifest": Net.LOCAL, "stats": Net.LOCAL, "_next_n": Net.PRIVATE, "_queue": Net.PRIVATE,
		"_last_sent": Net.PRIVATE, "_sent_at": Net.PRIVATE, "_active_until": Net.PRIVATE, "_next_req": Net.LOCAL, "_tele": Net.LOCAL,
		"_broken": Net.LOCAL, "_prev": Net.LOCAL}


## Alive enemies per deck (by EnemyBase.spawn_deck) for `decks` decks: MissionRules.evaluate's "enemies".
static func alive_per_deck(enemies: Array, decks: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(maxi(decks, 1))
	out.fill(0)
	for e: Variant in enemies:
		if e is EnemyBase and is_instance_valid(e) and not (e as EnemyBase).destroyed() \
				and not (e as EnemyBase).is_queued_for_deletion():
			var k := clampi((e as EnemyBase).spawn_deck, 0, out.size() - 1)
			out[k] += 1
	return out


func _ready() -> void:
	process_physics_priority = 30   # after TestDriveCombat advanced the world (0): this frame's events go out now


func setup(td: TestDrive) -> void:
	drive = td
	world = td.combat.world
	squad = td.combat.squad
	ring = td.city.ring
	var s := Net.session()
	hosting = s != null and s.hosting
	if s != null:
		if not s.event_received.is_connected(_on_event):
			s.event_received.connect(_on_event)
		if s.enemies != null:
			s.enemies.begin()
	if hosting:
		for e in squad.enemies:
			_adopt(e)
		squad.enemy_spawned.connect(_on_spawned)
		squad.enemy_removed.connect(_on_removed)
		squad.enemy_event.connect(_on_enemy_event)
		world.fired.connect(_on_fired)
		has_manifest = true


func _exit_tree() -> void:
	var s := Net.session()
	if s != null:
		if s.event_received.is_connected(_on_event):
			s.event_received.disconnect(_on_event)
		if s.enemies != null:
			s.enemies.end()


func _now() -> float:
	var s := Net.session()
	return s.host_time() if s != null and s.online() else 0.0


# --- Host -------------------------------------------------------------------------------------------------------

func _adopt(e: EnemyBase) -> int:
	if e.net_id <= 0 or by_net.get(e.net_id) != e:
		e.net_id = _next_n
		_next_n += 1
	by_net[e.net_id] = e
	return e.net_id


func _on_spawned(e: EnemyBase) -> void:
	_queue.append(["add", _adopt(e), entry_of(e)])


func _on_removed(e: EnemyBase) -> void:
	if by_net.get(e.net_id) == e:
		by_net.erase(e.net_id)
		_last_sent.erase(e.net_id)
		_sent_at.erase(e.net_id)
		_active_until.erase(e.net_id)
		_queue.append(["gone", e.net_id, {}])


## A manifest entry: [n, id, type, deck, transform, dead, broken components, hp fractions, wave].
func entry_of(e: EnemyBase) -> Array:
	var broken: Array = []
	for c in e.comp_order():
		if float(e.hp.get(c, 1.0)) <= 0.0:
			broken.append(c)
	return [e.net_id, e.target_id, e.enemy_type, e.spawn_deck, e.global_transform if e.is_inside_tree() else e.transform,
		e.destroyed(), broken, e.puppet_state()["hp"], e.wave]


func manifest() -> Array:
	var out: Array = []
	var ns := by_net.keys()
	ns.sort()
	for n: int in ns:
		var e := by_net[n] as EnemyBase
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			out.append(entry_of(e))
	return out


func _on_enemy_event(kind: String, enemy: Node, payload: Dictionary) -> void:
	var e := enemy as EnemyBase
	if e == null or by_net.get(e.net_id) != e:
		return
	var n := e.net_id
	match kind:
		"alerted":
			_queue.append(["alert", n, {"state": str(payload.get("state", "spotted"))}])
		"telegraph_started":
			_queue.append(["tele", n, {"w": str(payload.get("weapon", "")), "k": str(payload.get("kind", "cannon")),
				"t0": world.now, "dur": float(payload.get("duration", 0.5)), "lock": payload.get("target_pos", Vector3.ZERO)}])
		"telegraph_cancelled":
			_queue.append(["tele_x", n, {"reason": str(payload.get("reason", ""))}])
		"component_damaged":
			_queue.append(["dmg", n, {"c": str(payload.get("component", "")), "r": float(payload.get("hp_ratio", 0.0)),
				"wk": bool(payload.get("weak_point", false))}])
		"component_destroyed":
			_queue.append(["comp", n, {"c": str(payload.get("component", ""))}])
		"destroyed":
			_queue.append(["dead", n, {"cause": str(payload.get("cause", "core")), "r": float(payload.get("radius", 4.0))}])
		"overheated":
			_queue.append(["heat", n, {"on": true}])
		"rebooted":
			_queue.append(["heat", n, {"on": false}])


## An enemy's shot on the host: every machine fires the same record (a scheduled effect).
func _on_fired(rec: Dictionary) -> void:
	if not (bool(rec.get("enemy", false)) or str(rec.get("team", "")) == "enemy"):
		return
	_queue.append(["fire", 0, rec.duplicate()])
	stats["fire_sent"] = int(stats["fire_sent"]) + 1


## The sample of enemy `e` now.
func state_of(e: EnemyBase, now: float) -> NetEnemyState:
	var d := e.puppet_state()
	var st := NetEnemyState.new()
	st.n = e.net_id
	st.t = now
	st.pos = e.global_position
	st.yaw = CrewSync.heading_of(ring, st.pos, -e.global_basis.z)
	st.aim = d["aim"] as Vector2
	st.state = NetEnemyCodec.state_index(str(d["state"]))
	st.shutdown = bool(d["shutdown"])
	st.stagger = bool(d["stagger"])
	st.dead = bool(d["dead"])
	st.heat = float(d["heat"])
	st.kick = float(d["kick"])
	st.lock = d["lock"] as Vector3 if str(d["state"]) == EnemyBase.STATE_TELEGRAPH else st.pos
	st.hp = d["hp"] as PackedFloat32Array
	return st


func _host_step() -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	var now := s.host_time()
	var due: Array[NetEnemyState] = []
	for n: int in by_net:
		var e := by_net[n] as EnemyBase
		if not is_instance_valid(e) or not e.is_inside_tree() or e.destroyed():
			continue
		var st := state_of(e, now)
		var last := _last_sent.get(n) as NetEnemyState
		var gap := now - float(_sent_at.get(n, -INF))
		if st.changed_from(last):
			_active_until[n] = now + SETTLE
		var every := 1.0 / NetEnemyStream.ACTIVE_RATE if now < float(_active_until.get(n, -INF)) else 1.0 / NetEnemyStream.IDLE_RATE
		if gap >= every - 0.004:
			due.append(st)
			_last_sent[n] = st
			_sent_at[n] = now
	if not due.is_empty() and s.enemies != null:
		s.enemies.send(due)
		stats["streamed"] = int(stats["streamed"]) + due.size()
	flush()


## Host: send what is queued now (one reliable event).
func flush() -> void:
	if _queue.is_empty():
		return
	var s := Net.session()
	if s != null and s.online() and s.hosting:
		s.send_event(0, EV, {"l": _queue})
		stats["events_sent"] = int(stats["events_sent"]) + 1
		stats["items_sent"] = int(stats["items_sent"]) + _queue.size()
	_queue = []


# --- Client -----------------------------------------------------------------------------------------------------

func _on_event(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	if kind == REQ:
		if hosting:
			flush()   # what already happened goes first: the manifest that follows includes it
			s.send_event(from, SPAWN, {"e": manifest()})
			stats["manifests_sent"] = int(stats["manifests_sent"]) + 1
		return
	if hosting or from != 1:
		return
	if kind == SPAWN:
		var list: Variant = data.get("e")
		if list is Array:
			for en: Variant in list:
				_spawn_puppet(en)
			has_manifest = true
			stats["manifests_recv"] = int(stats["manifests_recv"]) + 1
			manifest_received.emit((list as Array).size())
	elif kind == EV:
		var items: Variant = data.get("l")
		if not (items is Array):
			return
		var fires := 0
		for it: Variant in items:
			if not (it is Array) or (it as Array).size() < 3 or not ((it as Array)[2] is Dictionary or (it as Array)[2] is Array):
				continue
			var a := it as Array
			stats["items_recv"] = int(stats["items_recv"]) + 1
			if str(a[0]) == "fire":
				fires += 1
				if fires <= MAX_FIRE_RECORDS:
					_remote_fire(a[2])
			else:
				_apply_item(str(a[0]), int(a[1]), a[2])


func _spawn_puppet(en: Variant) -> void:
	if not (en is Array) or (en as Array).size() < 8:
		return
	var a := en as Array
	var n := int(a[0])
	var id := str(a[1]).left(48)
	var type := str(a[2])
	if n <= 0 or by_net.has(n) or not (a[4] is Transform3D) or not EnemyCatalog.CLASSES.has(type):
		return
	var xf: Transform3D = a[4]
	var deck := int(a[3])
	var r := drive.stack.deck_ring(deck) if drive != null and drive.stack != null else ring   # the puppet's deck frame
	var e := EnemySpawner.make_enemy(type)
	e.configure(type, id, world, squad, r, world.mission_seed)
	e.puppet = true
	e.net_id = n
	e.spawn_deck = deck
	if a.size() > 8:
		e.wave = str(a[8]).left(32)   # the wave it arrived with (plan mode; the HUD / tests read it)
	e.up = r.up_at(xf.origin) if r != null else Vector3.UP
	e.transform = xf
	squad.add_enemy(e)
	by_net[n] = e
	if drive != null and drive.combat != null and not e in drive.combat.enemies:
		drive.combat.enemies.append(e)
	stats["spawned"] = int(stats["spawned"]) + 1
	var fr: Variant = a[7]
	if fr is PackedFloat32Array:
		e.puppet_apply({"state": e.ai_state, "hp": fr})
	var broken: Variant = a[6]
	if broken is Array:
		for c: Variant in broken:
			_break(n, e, str(c))
	if bool(a[5]):
		e.puppet_kill("core")


func _remove_puppet(n: int) -> void:
	var e := by_net.get(n) as EnemyBase
	by_net.erase(n)
	_tele.erase(n)
	_broken.erase(n)
	_prev.erase(n)
	var s := Net.session()
	if s != null and s.enemies != null:
		s.enemies.forget(n)
	if e == null or not is_instance_valid(e):
		return
	squad.remove_enemy(e)
	world.unregister(e)
	if drive != null and drive.combat != null:
		drive.combat.enemies.erase(e)
	e.queue_free()
	stats["removed"] = int(stats["removed"]) + 1


func _break(n: int, e: EnemyBase, c: String) -> void:
	var done: Dictionary = _broken.get(n, {})
	if done.has(c):
		return
	done[c] = true
	_broken[n] = done
	e.puppet_break(c)


func _apply_item(kind: String, n: int, d: Variant) -> void:
	if kind == "add":
		_spawn_puppet(d)
		return
	if kind == "gone":
		_remove_puppet(n)
		return
	var e := by_net.get(n) as EnemyBase
	if e == null or not is_instance_valid(e) or not (d is Dictionary):
		return
	var data := d as Dictionary
	var pos := e.global_position
	match kind:
		"alert":
			var st := str(data.get("state", "spotted"))
			e.alerted.emit(e, "")
			squad.emit_enemy_event("alerted", e, {"id": e.target_id, "state": st, "pos": pos})
		"tele":
			var w := str(data.get("w", ""))
			var t0 := float(data.get("t0", world.now))
			var dur := maxf(float(data.get("dur", 0.5)), 0.0)
			var lock: Variant = data.get("lock", pos)
			_tele[n] = {"w": w, "t0": t0, "dur": dur, "lock": lock if lock is Vector3 else pos}
			var arrival := _now()
			var muz := e.muzzle_world(w)
			e.telegraph_started.emit(e, w, dur, muz)
			squad.emit_enemy_event("telegraph_started", e, {"id": e.target_id, "weapon": w, "kind": str(data.get("k", "cannon")),
				"pos": muz, "target_pos": _tele[n]["lock"], "duration": maxf(t0 + dur - arrival, 0.05)})
			telegraph_received.emit(e, t0, dur, arrival)
		"tele_x":
			_tele.erase(n)
			e.puppet_telegraph_end()
			e.telegraph_cancelled.emit(e, str(data.get("reason", "")))
			squad.emit_enemy_event("telegraph_cancelled", e, {"id": e.target_id, "reason": str(data.get("reason", ""))})
		"dmg":
			var c := str(data.get("c", ""))
			e.component_damaged.emit(e, c, float(data.get("r", 0.0)), bool(data.get("wk", false)))
			squad.emit_enemy_event("component_damaged", e, {"id": e.target_id, "component": c,
				"hp_ratio": float(data.get("r", 0.0)), "weak_point": bool(data.get("wk", false)), "pos": pos})
		"comp":
			_break(n, e, str(data.get("c", "")))
		"dead":
			_tele.erase(n)
			e.puppet_kill(str(data.get("cause", "core")))
		"heat":
			var on := bool(data.get("on", false))
			if on:
				e.overheated.emit(e)
			else:
				e.rebooted.emit(e)
			squad.emit_enemy_event("overheated" if on else "rebooted", e, {"id": e.target_id, "pos": pos})


## The host's enemy fire record, fired here: the shot flies on this machine too, and CombatWorld lets this machine
## decide only about what it owns (its own mech).
func _remote_fire(d: Variant) -> void:
	if not (d is Dictionary):
		stats["fire_refused"] = int(stats["fire_refused"]) + 1
		return
	var r := d as Dictionary
	var w := str(r.get("weapon", ""))
	var ok := EnemyCatalog.WEAPONS.has(w) and r.get("origin") is Vector3 and r.get("dir") is Vector3 		and r.get("target") is Vector3 and (r.get("t") is float or r.get("t") is int)
	if ok:
		ok = (r["origin"] as Vector3).is_finite() and (r["dir"] as Vector3).is_finite() and (r["target"] as Vector3).is_finite() 			and (r["dir"] as Vector3).length_squared() > 1e-8
	if not ok:
		stats["fire_refused"] = int(stats["fire_refused"]) + 1
		return
	var rec := {"shooter": str(r.get("shooter", "enemy")).left(48), "peer": 1, "hardpoint": str(r.get("hardpoint", w)).left(32),
		"weapon": w, "origin": r["origin"], "dir": (r["dir"] as Vector3).normalized(), "target": r["target"],
		"t": float(r["t"]), "shot_index": int(r.get("shot_index", 0)), "spread": clampf(float(r.get("spread", 0.0)), 0.0, 45.0),
		"enemy": true, "team": "enemy"}
	stats["fire_recv"] = int(stats["fire_recv"]) + 1
	world.fire(rec)


func _client_step(dt: float) -> void:
	var s := Net.session()
	if s == null or not s.online():
		return
	var now := s.host_time()
	if not has_manifest and now >= _next_req:
		_next_req = now + REQ_EVERY
		s.send_event(1, REQ, {})
	for n: int in by_net:
		var e := by_net[n] as EnemyBase
		if not is_instance_valid(e) or not e.is_inside_tree():
			continue
		if not e.destroyed():
			var st := s.enemies.pose(n) if s.enemies != null else null
			if st != null:
				_pose(n, e, st, now, dt)
		e.puppet_tick(dt)


func _pose(n: int, e: EnemyBase, st: NetEnemyState, now: float, dt: float) -> void:
	var up := ring.up_at(st.pos) if ring != null else Vector3.UP
	var f := CrewSync.heading_dir(ring, st.pos, st.yaw)
	f = (f - up * f.dot(up)).normalized()
	e.up = up
	e.global_transform = Transform3D(Basis(f.cross(up).normalized(), up, -f), st.pos)
	var cfg := EnemyCatalog.unit(e.enemy_type)
	var max_s := maxf(float(cfg.get("flank_speed", cfg.get("move_speed", 1.0))), 0.1)
	var prev: Array = _prev.get(n, [st.pos, st.aim])
	var move := 0.0
	var slew := 0.0
	if dt > 0.0:
		var d := st.pos - (prev[0] as Vector3)
		d -= up * d.dot(up)
		move = clampf(d.length() / dt / max_s, 0.0, 1.0)
		var pa: Vector2 = prev[1]
		slew = (absf(angle_difference(pa.x, st.aim.x)) + absf(st.aim.y - pa.y)) / dt
	_prev[n] = [st.pos, st.aim]
	var state := NetEnemyCodec.state_name(st.state)
	var tele: Dictionary = _tele.get(n, {})
	var elapsed := now - float(tele.get("t0", 0.0))
	var tele_on := not tele.is_empty() and elapsed < float(tele.get("dur", 0.0))
	if not tele.is_empty() and not tele_on:
		_tele.erase(n)
		e.puppet_telegraph_end()
	if state == EnemyBase.STATE_TELEGRAPH and not tele_on:
		state = EnemyBase.STATE_ENGAGE   # the stream lags the telegraph's event: show it only from the event's clock
	var lock: Vector3 = st.lock if NetEnemyCodec.state_name(st.state) == EnemyBase.STATE_TELEGRAPH else tele.get("lock", st.pos)
	e.puppet_apply({"state": state, "aim": st.aim, "heat": st.heat, "shutdown": st.shutdown, "stagger": st.stagger,
		"kick": st.kick, "lock": lock, "hp": st.hp, "move": move, "slew": slew})
	if tele_on:
		e.puppet_telegraph(str(tele["w"]), elapsed, float(tele["dur"]), lock)
	stats["posed"] = int(stats["posed"]) + 1


func _physics_process(dt: float) -> void:
	if world == null:
		return
	if hosting:
		_host_step()
	else:
		_client_step(dt)
