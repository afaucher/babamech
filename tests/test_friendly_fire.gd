extends TestCase
## Friendly fire (docs/design/weapons.md §4.6; CombatWorld.friendly_fire / CombatWorld.spares), one process, no physics.
## Two "player" mechs with different owners in one world, as each machine of a crew sees them:
##   victim view   (the mate is owned HERE, peer 1; the shooter is a remote teammate, peer 2): this machine decides.
##   attacker view (the shooter is owned here; the mate is a puppet of peer 2): nothing is decided here, the shot only
##                 stops at the puppet cosmetically (no Hit, no remote_hit, its HP untouched).
## For each weapon class (gatling round, rockets splash, mortar splash, laser, flamer with target heat, railgun pierce):
##   - friendly_fire on: the mate takes the hits (victim view), the shot stops at it (a backstop behind it is untouched;
##     the railgun pierces it, the backstop then takes the reduced share), and the attacker's machine applies nothing.
##   - friendly_fire off: the mate is untouched and the backstop takes exactly what it takes with no mate there at all
##     (today's behaviour, bit for bit).
## Also: a shooter never takes its own splash (rockets, mortar) in either mode; an enemy shot (direct and splash) never
## hurts another enemy in either mode; the camera's aim pull-in (the missiles' / mortar's track) never stops on a
## teammate in either mode.

const DT := 1.0 / 60.0
const WEAPONS := ["gatling", "rockets", "mortar", "laser", "flamer", "railgun"]
const MUZZLE := Vector3(0, 4, -3)
const MATE_AT := Vector3(0, 0, -12)
const BACK_AT := Vector3(0, 0, -24)
const MORTAR_LAND := Vector3(0, 0, -30)


func setup() -> void:
	_default_on()
	for wid: String in WEAPONS:
		await _weapon(wid)
	await _own_splash()
	await _enemy_on_enemy()
	await _aim_query()
	finish()


func _default_on() -> void:
	var w := CombatWorld.new()
	check(w.friendly_fire, "friendly fire is on by default")
	eq(w.net_fields().get("friendly_fire", -1), Net.SPAWN, "friendly_fire is a SPAWN field (a mission parameter)")
	w.free()


func _world(ff: bool) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 5
	w.use_physics = false
	w.friendly_fire = ff
	add_child(w)
	return w


func _target(w: CombatWorld, id: String, peer: int, team: String, at: Vector3, mass: String = "mech") -> CombatTarget:
	var t := CombatTarget.new()
	t.name = id
	t.target_id = id
	t.owner_peer = peer
	t.team = team
	t.mass_class = mass
	t.set_max_hp({"body": 5000.0})
	t.add_hit_sphere("body", Vector3(0, 4, 0), 2.0)
	w.add_child(t)
	t.position = at
	w.register(t)
	return t


## The records one trigger of `wid` sends from `shooter` (peer `peer`).
func _records(w: CombatWorld, wid: String, shooter: String, peer: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if wid == "mortar":
		out.append(Combat.fire_record(shooter, peer, "back", "mortar", Vector3(0, 4, 0), MORTAR_LAND, w.now, 1))
	elif wid == "flamer":
		for i in 8:
			out.append(Combat.fire_record(shooter, peer, "side_l", "flamer", MUZZLE, MUZZLE + Vector3(0, 0, -40), w.now, 10 + i))
	else:
		out.append(Combat.fire_record(shooter, peer, "side_l", wid, MUZZLE, MUZZLE + Vector3(0, 0, -40), w.now, 3))
	return out


## Run until every effect is done. Returns {hits: id -> [Hit], remote: [ids], impacts: [points]}.
func _run(w: CombatWorld, recs: Array[Dictionary]) -> Dictionary:
	var out := {"hits": {}, "remote": [], "impacts": []}
	w.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		if not (out["hits"] as Dictionary).has(t.target_id):
			out["hits"][t.target_id] = []
		(out["hits"][t.target_id] as Array).append(h))
	w.remote_hit.connect(func(id: String, _h: Hit) -> void: (out["remote"] as Array).append(id))
	w.impact_from.connect(func(_r: Dictionary, p: Vector3, _rad: float) -> void: (out["impacts"] as Array).append(p))
	w.impact_spawned.connect(func(p: Vector3, _rad: float, _x: bool, _en: bool) -> void: (out["impacts"] as Array).append(p))
	for r in recs:
		w.fire(r)
	var t := 0.0
	while w.live_shots() > 0 or _flames(w) > 0:
		w.advance(DT)
		t += DT
		if t > 10.0:
			break
	w.advance(DT)
	return out


func _flames(w: CombatWorld) -> int:
	var n := 0
	for e in w.effects:
		if e is FlameChunk and not e.finished():
			n += 1
	return n


static func _hits(r: Dictionary, id: String) -> Array:
	return (r["hits"] as Dictionary).get(id, [])


static func _sum(hits: Array) -> float:
	var s := 0.0
	for h: Hit in hits:
		s += h.damage
	return s


## One weapon in both views and both modes, plus the no-mate baseline.
func _weapon(wid: String) -> void:
	var mate_at := Vector3(3, 0, -30) if wid == "mortar" else MATE_AT
	var back_at := Vector3(-3, 0, -30) if wid == "mortar" else BACK_AT
	# Baseline: no mate at all (what the backstop takes from an unobstructed shot).
	var w0 := _world(true)
	_target(w0, "player2", 2, "player", Vector3.ZERO)
	var b0 := _target(w0, "back", 1, "", back_at)
	var base := _run(w0, _records(w0, wid, "player2", 2))
	var base_back := _hits(base, "back")
	check(not base_back.is_empty(), "%s: the backstop is hit with nobody in the way (baseline)" % wid)
	var base_lost := b0.total_max_hp() - b0.total_hp()
	w0.free()

	for ff: bool in [true, false]:
		var tag := "%s, friendly fire %s" % [wid, "on" if ff else "off"]
		# Victim view: the mate (player1) is owned here; the remote teammate player2 shoots.
		var w := _world(ff)
		var shooter := _target(w, "player2", 2, "player", Vector3.ZERO)
		var mate := _target(w, "player1", 1, "player", mate_at, "mech")
		var back := _target(w, "back", 1, "", back_at)
		var r := _run(w, _records(w, wid, "player2", 2))
		var mh := _hits(r, "player1")
		var lost := mate.total_max_hp() - mate.total_hp()
		near(shooter.total_max_hp() - shooter.total_hp(), 0.0, 1e-9, "%s: the shooter never hits itself" % tag)
		if ff:
			check(not mh.is_empty() and lost > 0.0, "%s: the teammate's own machine applies the hit (%.1f HP)" % [tag, lost])
			near(lost, _sum(mh), 1e-6, "%s: through the normal verbs (HP lost = hits delivered)" % tag)
			if wid == "flamer":
				var heat := 0.0
				for h: Hit in mh:
					heat += h.heat
				check(heat > 0.0, "%s: the flamer heats the teammate (%.1f)" % [tag, heat])
			if wid in ["rockets", "mortar"]:
				var dv := 0.0
				for h: Hit in mh:
					dv = maxf(dv, h.impulse.length())
				check(dv > 0.0, "%s: splash knocks the teammate (%.2f m/s)" % [tag, dv])
			if wid == "railgun":
				var bh := _hits(r, "back")
				if check(bh.size() == 1, "%s: the slug pierces the teammate into the backstop" % tag):
					near((bh[0] as Hit).damage, (base_back[0] as Hit).damage * RailSlug.pierce_factor(w.stats("railgun"), 1), 1e-6,
						"%s: the backstop takes the pierced share (the teammate counted as a pierce)" % tag)
			elif wid != "mortar":
				eq(_hits(r, "back").size(), 0, "%s: the shot stops at the teammate (the backstop is untouched)" % tag)
		else:
			eq(mh.size(), 0, "%s: the teammate takes nothing" % tag)
			near(lost, 0.0, 1e-9, "%s: the teammate's HP is untouched" % tag)
			var bh := _hits(r, "back")
			eq(bh.size(), base_back.size(), "%s: the backstop takes as many hits as with nobody in the way" % tag)
			near(back.total_max_hp() - back.total_hp(), base_lost, 1e-9, "%s: and exactly the same damage (today's behaviour)" % tag)
		eq((r["remote"] as Array).size(), 0, "%s: nothing goes to another machine (victim view)" % tag)
		w.free()

		# Attacker view: player1 shoots from here; the mate is player2's puppet (owned by peer 2).
		var wa := _world(ff)
		var me := _target(wa, "player1", 1, "player", Vector3.ZERO)
		var puppet := _target(wa, "player2", 2, "player", mate_at)
		var backa := _target(wa, "back", 1, "", back_at)
		var ra := _run(wa, _records(wa, wid, "player1", 1))
		eq(_hits(ra, "player2").size(), 0, "%s: the attacker's machine builds no Hit on the teammate's puppet" % tag)
		check(not "player2" in (ra["remote"] as Array), "%s: and sends no hit for it" % tag)
		near(puppet.total_max_hp() - puppet.total_hp(), 0.0, 1e-9, "%s: the puppet's HP is never written here" % tag)
		near(me.total_max_hp() - me.total_hp(), 0.0, 1e-9, "%s: the shooter never hits itself (attacker view)" % tag)
		if ff and wid not in ["railgun", "mortar"]:
			eq(_hits(ra, "back").size(), 0, "%s: the shot stops at the puppet here too" % tag)
			if wid != "flamer":     # the flamer's chunks draw no impact of their own
				var near_mate := false
				for p: Vector3 in ra["impacts"]:
					if p.distance_to(mate_at + Vector3(0, 4, 0)) < 3.0:
						near_mate = true
				check(near_mate, "%s: the impact is drawn on the puppet" % tag)
		elif not ff:
			near(backa.total_max_hp() - backa.total_hp(), base_lost, 1e-9, "%s: the shot passes the puppet into the backstop" % tag)
		wa.free()
	await frames(1)


## A shooter's own splash never hurts it, in either mode: rockets into an enemy right in front, a mortar shell landing at
## the shooter's feet (the record's muzzle is far away).
func _own_splash() -> void:
	for ff: bool in [true, false]:
		var tag := "friendly fire %s" % ("on" if ff else "off")
		var w := _world(ff)
		var me := _target(w, "player1", 1, "player", Vector3.ZERO)
		var foe := _target(w, "foe", 0, "enemy", Vector3(0, 0, -6))
		var r := _run(w, [Combat.fire_record("player1", 1, "shoulder_l", "rockets", MUZZLE, MUZZLE + Vector3(0, 0, -20), w.now, 1)])
		check(not _hits(r, "foe").is_empty(), "%s: the rocket hits the enemy 2 m in front" % tag)
		eq(_hits(r, "player1").size(), 0, "%s: the rocket's splash spares its own shooter" % tag)
		near(me.total_max_hp() - me.total_hp(), 0.0, 1e-9, "%s: no self-damage from rockets" % tag)
		foe.position = Vector3(-4, 0, -30)
		me.position = Vector3(3, 0, -30)
		var rm := _run(w, [Combat.fire_record("player1", 1, "back", "mortar", Vector3(0, 4, 0), MORTAR_LAND, w.now, 2)])
		check(not _hits(rm, "foe").is_empty(), "%s: the mortar's splash reaches the enemy by the landing point" % tag)
		eq(_hits(rm, "player1").size(), 0, "%s: the mortar's splash spares its own shooter standing there" % tag)
		w.free()
	await frames(1)


## Enemy fire never hurts another enemy, in either mode (direct: a bolt through a squadmate; splash: rockets beside one).
func _enemy_on_enemy() -> void:
	for ff: bool in [true, false]:
		var tag := "friendly fire %s" % ("on" if ff else "off")
		var w := _world(ff)
		_target(w, "e_rear", 0, "enemy", Vector3.ZERO)
		var e_front := _target(w, "e_front", 0, "enemy", MATE_AT)
		var e_side := _target(w, "e_side", 0, "enemy", BACK_AT + Vector3(3.5, 0, 0))
		var pl := _target(w, "player1", 1, "player", BACK_AT)
		var rec := Combat.fire_record("e_rear", 1, "enemy_bolter", "enemy_bolter", MUZZLE, MUZZLE + Vector3(0, 0, -40), w.now, 0)
		rec["enemy"] = true
		rec["team"] = "enemy"
		var rk := Combat.fire_record("e_rear", 1, "rockets", "rockets", MUZZLE, MUZZLE + Vector3(0, 0, -40), w.now, 1)
		rk["enemy"] = true
		rk["team"] = "enemy"
		var r := _run(w, [rec, rk])
		eq(_hits(r, "e_front").size() + _hits(r, "e_side").size(), 0, "%s: enemy fire spares other enemies (direct and splash)" % tag)
		near(e_front.total_max_hp() - e_front.total_hp() + e_side.total_max_hp() - e_side.total_hp(), 0.0, 1e-9,
			"%s: no enemy lost HP to enemy fire" % tag)
		check(pl.total_hp() < pl.total_max_hp(), "%s: the enemy fire reaches the player behind its squadmate" % tag)
		w.free()
	await frames(1)


## The camera's aim pull-in is a query (first_hit with query = true): it never stops on a teammate, so the aim point (the
## missiles' guided track, the mortar's landing point) stays on what is behind, in either mode. Shots still stop there.
func _aim_query() -> void:
	for ff: bool in [true, false]:
		var tag := "friendly fire %s" % ("on" if ff else "off")
		var w := _world(ff)
		_target(w, "player1", 1, "player", Vector3.ZERO)
		_target(w, "player2", 2, "player", MATE_AT)
		_target(w, "foe", 0, "enemy", BACK_AT)
		var a := MUZZLE
		var b := MUZZLE + Vector3(0, 0, -60)
		var q := w.first_hit(a, b, 0.0, "player1", [], true)
		check(not q.is_empty() and q["target"] != null and (q["target"] as CombatTarget).target_id == "foe",
			"%s: the aim query passes the teammate and finds the enemy" % tag)
		var s := w.first_hit(a, b, 0.0, "player1")
		var sid := (s["target"] as CombatTarget).target_id if not s.is_empty() and s["target"] != null else ""
		eq(sid, "player2" if ff else "foe", "%s: a shot's sweep %s" % [tag, "stops at the teammate" if ff else "passes the teammate"])
		# WeaponRack's own pull-in, through a real ChaseCamera looking down -Z from behind the shooter.
		var cam := ChaseCamera.new()
		w.add_child(cam)
		cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 4, 2))
		var rack := WeaponRack.new()
		rack.world = w
		rack.camera = cam
		rack.shooter = "player1"
		var p: Vector3 = rack._camera_aim()
		check(p.z < BACK_AT.z + 2.5 and p.z > BACK_AT.z - 2.5, "%s: the rack's aim point lands on the enemy, not the teammate (z %.1f)" % [tag, p.z])
		rack.free()
		w.free()
	await frames(1)
