extends NetTest
## Enemies in co-op (W4, cast's M3: the host-owned world; scripts/game/enemy_sync.gd, scripts/net/net_enemy_stream.gd)
## over a real crew mission in the stack, once per link (off, coast). Only the host spawns enemies and runs their AI;
## clients show puppets. At load the host turns every enemy's AI to "idle" so nothing shoots during the measured steps,
## then:
## 1. MANIFEST: the same enemies (net id, target id, type, spawn deck) exist on every machine, at the same spots; every
##    client copy is a puppet, CombatWorld doesn't own it, and no AI ran there (no attack slot, no target board, no shot).
##    PER DECK: every deck of the stack has an encounter, every machine counts the same enemies per deck, and after a
##    couple of seconds every enemy stands on its own deck (CityStack.deck_at == spawn_deck) with floor under it.
## 2. POSE: the host drives a skirmisher along the avenue (5 m/s, swaying 3 m) and turns a turret's aim; each client's
##    puppet pose at its render time follows the host's streamed path within POSE_TOL; the turret's aim arrives.
## 3. DAMAGE: client c1 hits a turret (CombatWorld.resolve_hit: the attacker decides, CombatNet carries it); the host
##    applies it, and every machine shows the same core HP; then c1 kills it: destroyed with a burning wreck everywhere,
##    and enemies_alive_per_deck() drops by one on every machine.
## 4. ENEMY FIRE: the host fires an enemy bolt at c1's mech from 12 m (a host fire record EnemySync relays); c1's machine
##    decides and takes the damage from that enemy; no other machine builds a hit on c1.
## Also checked for Weapons (their enemy-fire contract): a client's puppets are CombatWorld targets with the host's
## target_id and owner_peer 0; a client's hit leaves its puppet's HP alone (the host applies it); a puppet's muzzle
## (EnemyBase.muzzle_world) follows the host's aim.
## 5. TELEGRAPH: a turret in "telegraph_loop" next to c1 targets c1's PUPPET on the host (crew targeting; the other mechs
##    leave the "player" team for this step) and telegraphs;
##    every telegraph event reaches the clients at least 0.3 s before its shot (rule 7).
## Not a test itself: test_net_enemy (2) and test_net_enemy_3 (3) extend it.

const SEED := 11
const POSE_TOL := {"off": 0.5, "coast": 0.8}
const LEAD_MIN := 0.3

var td: TestDrive
var world: CombatWorld
var sync: EnemySync
var track_n := -1
var pose_samples: Array = []       ## client: [t, pos] of the tracked enemy's shown pose
var damage_in: Array = []          ## client: [amount, component, src] on its own PlayerTarget
var hits: Array = []               ## hit_landed: [target id, dmg]
var leads: Array = []              ## client: telegraph lead times (s before the shot when the event arrived)
var enemy_fired := 0               ## enemy records fired on this machine
var host_trace: Array = []         ## host: [t, pos] streamed for the tracked enemy
var impacts: Array = []            ## [point, radius]
var local_hp_kept := true          ## c1: its own hits never wrote its puppet's HP


func run_host() -> void:
	net_timeout = 110.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 30.0), "every client has the enemy manifest"):
		return
	var c1 := _peer_named("c1")
	var c2 := _peer_named("c2")

	# 1. MANIFEST -------------------------------------------------------------------------------------------
	var mine := _manifest()
	check(mine.size() >= 3, "the host spawned an encounter (%d enemies)" % mine.size())
	var k := int(td.stack.section.entry["deck"])
	var per_deck := td.enemies_alive_per_deck()
	print("[enemy] alive per deck on the host: %s" % str(per_deck))
	for d in per_deck.size():
		check(per_deck[d] >= 1, "deck %d has enemies (%d)" % [d, per_deck[d]])
	await sleep(2.0)
	var sp := world.get_world_3d().direct_space_state
	for e in td.combat.squad.enemies:
		check(not e.puppet, "%s is a real enemy on the host" % e.target_id)
		eq(td.stack.deck_at(e.global_position), e.spawn_deck, "%s stands on its own deck %d" % [e.target_id, e.spawn_deck])
		var up := e.up
		var hit := sp.intersect_ray(PhysicsRayQueryParameters3D.create(e.global_position + up * 1.0, e.global_position - up * 2.0))
		check(not hit.is_empty(), "%s has floor under it (deck %d)" % [e.target_id, e.spawn_deck])
	for p in peers_with("ready"):
		var r: Dictionary = reported(p, "ready")
		eq(str(r["manifest"]), str(mine), "peer %d has the same enemies (net id, id, type, deck)" % p)
		check(bool(r["all_puppets"]), "peer %d: every enemy is a puppet with owner_peer 0" % p)
		check(bool(r["registered"]), "peer %d: every puppet is a CombatWorld target (same target_id as the host's)" % p)
		eq(str(r["per_deck"]), str(per_deck), "peer %d counts the same enemies per deck" % p)
		check(bool(r["own_decks"]), "peer %d: every puppet stands on its own deck" % p)
		check(bool(r["none_owned"]), "peer %d: CombatWorld owns none of them (never ticks them)" % p)
		check(bool(r["no_ai"]), "peer %d: no AI ran (no slots, no target board, no shots of its own)" % p)
		var far := 0.0
		for e in td.combat.squad.enemies:
			var cp: Variant = (r["pos"] as Dictionary).get(e.target_id)
			if cp is Vector3:
				far = maxf(far, (cp as Vector3).distance_to(e.global_position))
		check(far < 0.3, "peer %d: its puppets stand where the host's enemies stand (max %.3f m off)" % [p, far])

	# 2. POSE -----------------------------------------------------------------------------------------------
	var mover: EnemyBase = null
	var turret: EnemyBase = null
	for e in td.combat.squad.enemies:
		if mover == null and e.enemy_type == "strider":
			mover = e
		if turret == null and e.enemy_type == "turret":
			turret = e
	if mover == null:
		mover = td.combat.squad.enemies[0]
	track_n = mover.net_id
	_command_all("track", {"n": track_n})
	await sleep(0.3)
	var ring := td.stack.deck_ring(mover.spawn_deck)
	var a0 := ring.world_to_arc(mover.global_position)
	var t0 := Session.host_time()
	if turret != null:
		turret.set_puppet_aim(Vector2(0.9, 0.25))
	while Session.host_time() - t0 < 3.0:
		var s := Session.host_time() - t0
		var x := a0.x + 3.0 * sin(s * PI)
		var p := ring.arc_to_world(x, a0.y + 5.0 * s, a0.z)
		var nx := ring.arc_to_world(a0.x + 3.0 * sin((s + 0.05) * PI), a0.y + 5.0 * (s + 0.05), a0.z)
		var up := ring.up_at(p)
		var f := nx - p
		f = (f - up * f.dot(up)).normalized()
		mover.global_transform = Transform3D(Basis(f.cross(up).normalized(), up, -f), p)
		await get_tree().physics_frame
		_trace(mover)
	await sleep(0.8)
	_trace(mover)
	var st := await _collect("pose")
	var tol := float(POSE_TOL.get(link, 0.8))
	for p: int in st:
		var smp: Array = st[p]["pose"]
		var worst := 0.0
		var sum := 0.0
		var n := 0
		var worst_t := 0.0
		for it: Array in smp:
			var t := float(it[0])
			if t < float(host_trace[0][0]) or t > float(host_trace[host_trace.size() - 1][0]):
				continue
			var d := (it[1] as Vector3).distance_to(_trace_at(t))
			if d > worst:
				worst_t = t - t0
			worst = maxf(worst, d)
			sum += d
			n += 1
		print("[enemy] peer %d: %d pose samples, max %.3f m (at %.2f s), mean %.3f m off the host's path" % [p, n, worst, worst_t, sum / maxf(n, 1)])
		check(n >= 40, "peer %d recorded the puppet moving (%d samples)" % [p, n])
		check(worst < tol, "peer %d: the puppet follows the host within %.1f m (max %.3f)" % [p, tol, worst])
		check((st[p]["final"] as Vector3).distance_to(mover.global_position) < 0.1, "peer %d: the puppet ends where the host's enemy stands" % p)
		if turret != null:
			var aim: Vector2 = (st[p]["aims"] as Dictionary).get(turret.target_id, Vector2.INF)
			check(aim.distance_to(Vector2(0.9, 0.25)) < 0.01, "peer %d: the turret's aim arrived (%s)" % [p, str(aim)])
			var mz: Vector3 = (st[p]["muzzles"] as Dictionary).get(turret.target_id, Vector3.INF)
			var hm := turret.muzzle_world("enemy_bolter")
			check(mz.distance_to(hm) < 0.1, "peer %d: the turret puppet's muzzle is where the host's is (%.3f m)" % [p, mz.distance_to(hm)])

	# 3. DAMAGE by c1 ---------------------------------------------------------------------------------------
	if check(turret != null, "the encounter has a turret"):
		var deck_before := td.enemies_alive_per_deck()
		var core := turret.core_component()
		var cap := float(turret.max_hp[core])
		command(c1, "hit", {"id": turret.target_id, "comp": core, "dmg": cap * 0.4, "idx": 9500})
		await until(func() -> bool: return float(turret.hp[core]) < cap - 1.0, 5.0)
		near(float(turret.hp[core]) / cap, 0.6, 0.01, "the host applied c1's hit on its turret")
		await sleep(0.8)
		st = await _collect("damaged")
		for p: int in st:
			near(float((st[p]["core"] as Dictionary).get(turret.target_id, -1.0)), 0.6, 0.01, "peer %d shows the turret's core HP" % p)
		if st.has(c1):
			check(bool(st[c1]["local_hp_kept"]), "c1's own hit did not write its puppet's HP (the host applied it)")
		command(c1, "hit", {"id": turret.target_id, "comp": core, "dmg": 100000.0, "idx": 9501})
		await until(func() -> bool: return turret.destroyed(), 5.0)
		check(turret.destroyed(), "c1's second hit destroyed the turret on the host")
		await sleep(1.0)
		var deck_after := td.enemies_alive_per_deck()
		eq(deck_after[k], deck_before[k] - 1, "one enemy fewer alive on the entry deck (host)")
		st = await _collect("killed")
		for p: int in st:
			check(bool((st[p]["dead"] as Dictionary).get(turret.target_id, false)), "peer %d: the turret is destroyed" % p)
			check(bool((st[p]["wreck"] as Dictionary).get(turret.target_id, false)), "peer %d: it burns as a wreck" % p)
			eq(str(st[p]["alive"]), str(deck_after), "peer %d counts the same alive enemies per deck" % p)

	# 4. ENEMY FIRE at c1 -----------------------------------------------------------------------------------
	var pb: MechPuppet = td.crew_sync.puppets.get(c1)
	if check(pb != null and mover != null and not mover.destroyed(), "the host has c1's puppet and an enemy to fire"):
		var pm := pb.mech
		var up := pm.up()
		var fwd := td.mech.forward()
		var aim_at: Vector3 = pb.target.world_spheres()[0]["center"] if pb.target != null else pm.global_position + up * 4.4
		var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
		var rec := Combat.fire_record(mover.target_id, 1, w, w, aim_at + fwd * 12.0, aim_at, world.now, 9600, 0.0)
		rec["enemy"] = true
		rec["team"] = "enemy"
		world.fire(rec)
		await sleep(1.2)
		st = await _collect("shot")
		var v1: Dictionary = st.get(c1, {})
		if check(not v1.is_empty(), "c1 reported"):
			var from_mover := 0.0
			for d: Array in v1["damage"]:
				if str(d[2]) == mover.target_id:
					from_mover += float(d[0])
			check(from_mover > 0.0, "c1's machine decided the enemy bolt and took %.1f damage from %s" % [from_mover, mover.target_id])
			check(int(v1["fired"]) >= 1, "the enemy record was fired on c1")
			print("[enemy] c1 impacts: %s, mech at %s, aim %s" % [str(v1["impacts"]), str(pm.global_position), str(aim_at)])
		var me := _state()
		check(_hits_on(me, c1) == 0, "the host built no hit on c1's puppet")
		if c2 > 0 and st.has(c2):
			check(_hits_on(st[c2], c1) == 0, "c2 built no hit on c1's puppet")
			check(int(st[c2]["fired"]) >= 1, "the enemy record was fired on c2 too")

	# 5. TELEGRAPH toward c1 --------------------------------------------------------------------------------
	var t2: EnemyBase = null
	for e in td.combat.squad.enemies:   # on the entry deck: an enemy only engages mechs on its own deck
		if e.enemy_type == "turret" and not e.destroyed() and e != turret and e.spawn_deck == k:
			t2 = e
	if t2 == null:
		for e in td.combat.squad.enemies:
			if not e.destroyed() and e != mover and e.spawn_deck == k:
				t2 = e
	if check(t2 != null and pb != null, "an enemy is left to telegraph"):
		var pc := pb.mech.global_position
		var away := pc - td.mech.global_position
		var up2 := ring.up_at(pc)
		away = (away - up2 * away.dot(up2)).normalized()
		var spot := pc + td.mech.forward() * 25.0 + away * 8.0
		var f2 := (pc - spot)
		f2 = (f2 - up2 * f2.dot(up2)).normalized()
		t2.global_transform = Transform3D(Basis(f2.cross(up2).normalized(), up2, -f2), spot)
		t2.ground_y = spot.dot(up2)
		# Only c1's puppet is a target for this step (the host's mech and other puppets step out of the "player" team).
		var benched: Array[CombatTarget] = [td.combat.player_target]
		for q: int in td.crew_sync.targets:
			if q != c1:
				benched.append(td.crew_sync.targets[q])
		for bt in benched:
			bt.team = ""
		t2.ai_mode = "telegraph_loop"
		var tgt := [""]
		var tele_n := [0]
		var on_tele := func(kind: String, en: Node, _pl: Dictionary) -> void:
			if kind == "telegraph_started" and en == t2:
				tele_n[0] += 1
				tgt[0] = str(t2.get("_target_id"))
		td.combat.squad.enemy_event.connect(on_tele)
		await until(func() -> bool: return tele_n[0] >= 2, 10.0)
		t2.ai_mode = "idle"
		for bt in benched:
			bt.team = "player"
		await sleep(1.0)
		check(tele_n[0] >= 1, "the turret telegraphed on the host (%d)" % tele_n[0])
		eq(tgt[0], "player%d" % c1, "the host's turret targets c1's puppet")
		st = await _collect("tele")
		for p: int in st:
			var ls: Array = st[p]["leads"]
			var lo := INF
			for l: float in ls:
				lo = minf(lo, l)
			print("[enemy] peer %d: %d telegraphs, min lead %.3f s" % [p, ls.size(), lo])
			check(ls.size() >= 1, "peer %d got the telegraph" % p)
			check(lo >= LEAD_MIN, "peer %d: every telegraph arrived at least %.1f s before its shot (min %.3f)" % [p, LEAD_MIN, lo])
	_command_all("finish", {})
	check(await wait_done(peers - 1, 20.0), "the clients are done")


func run_client() -> void:
	net_timeout = 110.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	if not check(await until(func() -> bool: return sync.has_manifest and td.combat.squad.enemies.size() > 0, 15.0),
			"the enemy manifest arrives"):
		return
	await sleep(0.6)   # first samples
	var all_p := true
	var owned := false
	var ai := false
	var pos := {}
	var registered := true
	var own := true
	for e in td.combat.squad.enemies:
		own = own and td.stack.deck_at(e.global_position) == e.spawn_deck
		all_p = all_p and e.puppet and e.owner_peer == 0
		registered = registered and e in world.targets
		owned = owned or world.owns(e)
		ai = ai or int(e.get("_shot_index")) != 0
		pos[e.target_id] = e.global_position
	var sq := td.combat.squad
	ai = ai or not sq.known_targets.is_empty() or not (sq.get("_slots") as Dictionary).is_empty()
	report("ready", {"manifest": str(_manifest()), "all_puppets": all_p, "none_owned": not owned, "no_ai": not ai, "pos": pos,
		"registered": registered, "per_deck": str(td.enemies_alive_per_deck()), "own_decks": own})
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"report":
				report(str(c["key"]), _state())
			"track":
				track_n = int(c["n"])
				pose_samples.clear()
			"hit":
				_hit(str(c["id"]), str(c["comp"]), float(c["dmg"]), int(c["idx"]))


# --- Shared ----------------------------------------------------------------------------------------------

func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	if not check(td.crewed and td.enemy_sync != null and td.stack != null, "the crew mission runs EnemySync in the stack"):
		return false
	td.drive_override = true
	world = td.combat.world
	sync = td.enemy_sync
	world.impact_spawned.connect(func(pt: Vector3, r: float, _x: bool, _en: bool) -> void: impacts.append([pt, r]))
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void: hits.append([t.target_id, h.damage]))
	world.fired.connect(func(rec: Dictionary) -> void:
		if bool(rec.get("enemy", false)):
			enemy_fired += 1)
	td.combat.player_target.damaged.connect(func(amount: float, comp: String, src: String) -> void:
		damage_in.append([amount, comp, src]))
	td.combat.player_target.auto_respawn_delay = -1.0
	sync.telegraph_received.connect(func(_e: EnemyBase, t0: float, dur: float, arrival: float) -> void:
		leads.append(t0 + dur - arrival))
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td._held, 40.0),
			"the load barrier passes"):
		return false
	return true


func _physics_process(_delta: float) -> void:
	if td == null or not is_instance_valid(td) or is_host() or track_n < 0 or Session.enemies == null:
		return
	var st := Session.enemies.pose(track_n)
	if st != null:
		pose_samples.append([st.t, st.pos])


## The host's streamed samples of the tracked enemy (EnemySync's last sent), once each.
func _trace(e: EnemyBase) -> void:
	var st := (sync.get("_last_sent") as Dictionary).get(e.net_id) as NetEnemyState
	if st != null and (host_trace.is_empty() or float(host_trace[host_trace.size() - 1][0]) < st.t):
		host_trace.append([st.t, st.pos])


func _trace_at(t: float) -> Vector3:
	for i in range(host_trace.size() - 1):
		var a: Array = host_trace[i]
		var b: Array = host_trace[i + 1]
		if t >= float(a[0]) and t <= float(b[0]):
			var u := (t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4)
			return (a[1] as Vector3).lerp(b[1] as Vector3, u)
	return host_trace[host_trace.size() - 1][1]


func _manifest() -> Array:
	var out: Array = []
	for e in td.combat.squad.enemies:
		out.append([e.net_id, e.target_id, e.enemy_type, e.spawn_deck])
	out.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	return out


## c1: hit a host-owned enemy as its own weapon would (the attacker decides; CombatNet sends it to the host).
func _hit(id: String, comp: String, dmg: float, idx: int) -> void:
	for e in td.combat.squad.enemies:
		if e.target_id != id:
			continue
		var p := CombatWorld.local_peer()
		var at := e.global_position + e.up * 2.0
		var from := td.mech.global_position + td.mech.up() * 4.0
		var rec := Combat.fire_record("player%d" % p, p, "side_l", "autocannon", from, at, world.now, idx, 0.0)
		var before := e.hp.duplicate()
		world.resolve_hit(rec, world.stats("autocannon"), e, comp, at, (from - at).normalized(), (at - from).normalized(), dmg)
		local_hp_kept = local_hp_kept and e.hp == before
		return


func _state() -> Dictionary:
	var core := {}
	var dead := {}
	var wreck := {}
	var aims := {}
	var muzzles := {}
	for e in td.combat.squad.enemies:
		if not is_instance_valid(e):
			continue
		core[e.target_id] = e.core_hp_ratio()
		dead[e.target_id] = e.destroyed()
		wreck[e.target_id] = e.destroyed() and e.has_active_flame()
		aims[e.target_id] = e.puppet_aim()
		muzzles[e.target_id] = e.muzzle_world("enemy_bolter" if e.enemy_type == "turret" else "")
	var final := Vector3.ZERO
	var tracked := sync.by_net.get(track_n) as EnemyBase
	if tracked != null and is_instance_valid(tracked):
		final = tracked.global_position
	return {"pose": pose_samples, "final": final, "aims": aims, "muzzles": muzzles, "local_hp_kept": local_hp_kept, "core": core, "dead": dead, "wreck": wreck,
		"alive": str(td.enemies_alive_per_deck()), "damage": damage_in, "hits": hits, "leads": leads, "fired": enemy_fired,
		"impacts": impacts.slice(maxi(impacts.size() - 4, 0))}


func _hits_on(v: Dictionary, peer: int) -> int:
	var n := 0
	for h: Array in v["hits"]:
		if str(h[0]) == "player%d" % peer:
			n += 1
	return n


func _command_all(cmd: String, data: Dictionary) -> void:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != 1:
			command(int(e["peer"]), cmd, data)


## Ask every client for its state under `key` and wait for the answers.
func _collect(key: String) -> Dictionary:
	_command_all("report", {"key": key})
	await wait_reports(key, peers - 1, 15.0)
	var out := {}
	for p in peers_with(key):
		out[p] = reported(p, key)
	return out


func _peer_named(n: String) -> int:
	for e: Dictionary in Session.crew():
		if str(e["name"]) == n:
			return int(e["peer"])
	return -1
