extends TestCase
## The Flak Cannon (scripts/combat/weapons/flak.gd, flak_shell.gd, docs/design/weapons.md §3.10): cadence, heat per
## shell, 160 shells (+50 % with the ammo bin); a fast straight shell (140 m/s, 220 m); the proximity fuse (armed after
## 12 m, bursts at the closest approach within 6 m of a hit sphere, swept: the same burst point at dt 1/10 and 1/120);
## direct hits = one Hit of direct + splash; bursts on a wall, the ground, a prop (a tree stays standing) and at range;
## the friendly-fire rule (never the shooter, teammates only with friendly fire on, enemies always); a machine that does
## not decide the shot applies nothing; an air burst lays no decal, a ground burst does; balance vs the autocannon; the
## hangar / rack list it; the weapon_range lab fires it at its airborne dummy. ARMOUR: on an armoured target
## (CombatTarget.armored) both the direct strike and the splash do armor_mult (0.35) of their damage, an unarmoured one is
## unchanged, a weapon without armor_mult (the autocannon) does the same damage to both; who is armoured (player mechs,
## the relay, the catalog's armoured enemy classes; never drones / aircraft / troopers).

const ID := "flak"
const HIGH := 20.0                   ## altitude of the "airborne" scenes (m)
const R := 1.0                       ## hit sphere radius of the test targets


class FakeProps extends Node:
	var centre := Vector3.ZERO
	var radius := 0.6
	var impulses: Array = []       ## [id, dv]
	var blasts: Array = []         ## [point, radius, dv]

	func first_hit(a: Vector3, b: Vector3, r: float) -> Dictionary:
		var f := Combat.segment_sphere(a, b, centre, radius + r)
		if f < 0.0:
			return {}
		var p := a.lerp(b, f)
		return {"id": 3, "frac": f, "point": p, "normal": (p - centre).normalized(), "color": Color(0.2, 0.6, 0.2)}

	func apply_impulse(id: int, dv: Vector3, _src: String) -> void:
		impulses.append([id, dv])

	func blast(point: Vector3, r: float, dv: float, _src: String) -> void:
		blasts.append([point, r, dv])


func setup() -> void:
	_catalog_and_balance()
	_cadence_heat_ammo()
	await _rack_and_bin()
	_flight()
	_fuse_near_miss()
	_fuse_arming()
	_direct_hit()
	_swept_fuse()
	_who_fuses()
	_non_deciding()
	_armour()
	_armour_who()
	await _physics_bursts()
	await _prop()
	await _lab()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 4243
	w.use_physics = physics
	add_child(w)
	return w


func _target(w: CombatWorld, id: String, at: Vector3, team: String = "enemy", peer: int = 0) -> CombatTarget:
	var t := CombatTarget.new()
	t.name = id
	t.target_id = id
	t.team = team
	t.owner_peer = peer
	t.mass_class = "static"
	t.set_max_hp({"body": 5000.0})
	t.add_hit_sphere("body", Vector3.ZERO, R)
	w.add_child(t)
	t.global_position = at
	w.register(t)
	return t


func _lost(t: CombatTarget) -> float:
	return t.total_max_hp() - t.total_hp()


func _rec(origin: Vector3, to: Vector3, idx: int = 0, team: String = "player", peer: int = 1) -> Dictionary:
	var r := Combat.fire_record("me", peer, "side_r", ID, origin, to, 0.0, idx, 0.0)
	r["team"] = team
	return r


## Fire `rec` at w.now = 0 and step until the shell has ended (and its effects have run); the FlakShell.
func _fly(w: CombatWorld, rec: Dictionary, dt: float = 1.0 / 60.0) -> FlakShell:
	rec["t"] = w.now
	var s := w.fire(rec) as FlakShell
	var guard := 0
	while s != null and s.end_time < 0.0 and guard < int(4.0 / dt):
		w.advance(dt)
		guard += 1
	return s


func _clear(w: CombatWorld) -> void:
	for e in w.effects.duplicate():
		w.remove_effect(e)


# --- Catalog, balance, cadence --------------------------------------------------------------------------

func _catalog_and_balance() -> void:
	var st := MechCatalog.weapon(ID)
	check(WeaponRegistry.built(ID), "the flak cannon is built")
	check(ID in MechCatalog.WEAPON_ORDER, "the hangar offers it (WEAPON_ORDER)")
	for k: String in MechCatalog.WEAPON_STATS:
		check(st.has(k), "flak carries %s" % k)
	eq(st["mounts"], MechCatalog.weapon("autocannon")["mounts"], "mounts where the autocannon mounts")
	check(ID in MechCatalog.weapons_for("side") and ID in MechCatalog.weapons_for("shoulder"), "listed for side and shoulder")
	check(not ID in MechCatalog.weapons_for("back"), "not on the back")
	near(float(st["speed"]), 140.0, 1e-6, "140 m/s")
	near(float(st["range"]), 220.0, 1e-6, "220 m")
	near(float(st["fuse_radius"]), 6.0, 1e-6, "6 m fuse")
	near(float(st["arm_distance"]), 12.0, 1e-6, "arms at 12 m")
	near(float(st["splash_radius"]), 8.0, 1e-6, "8 m burst")
	check(float(st["spread"]) <= float(MechCatalog.weapon("autocannon")["spread"]) + 1e-6, "no more spread than the autocannon")
	check(float(st["prop_blast"]) < float(CityPropSim.TYPES["tree"]["dv"]) and float(st["knockback"]) < float(CityPropSim.TYPES["tree"]["dv"]),
		"its blast and its direct shove are under a tree's topple threshold")
	check(float(st["splash_knockback"]) > 0.0 and float(st["splash_knockback"]) < 2.0, "a small splash shove")
	# Balance: a direct hit on a ground target = direct + splash at PROJECTILE_RADIUS from the sphere.
	var ac := MechCatalog.weapon("autocannon")
	var per_shell := float(st["damage"]) + float(st["splash_damage"]) * (1.0 - Combat.PROJECTILE_RADIUS / float(st["splash_radius"]))
	var dps := per_shell * float(st["rate"])
	var ac_dps := float(ac["damage"]) * float(ac["rate"])
	var share := dps / ac_dps
	print("flak: %.2f per direct shell, %.1f DPS direct vs autocannon %.1f (%.0f %%)" % [per_shell, dps, ac_dps, share * 100.0])
	check(share >= 0.55 and share <= 0.65, "direct-hit DPS is 55-65 %% of the autocannon's (%.0f %%)" % (share * 100.0))
	# A near miss 3 m from an aircraft's hull still does damage; the autocannon does none.
	var near3 := float(st["splash_damage"]) * (1.0 - 3.0 / float(st["splash_radius"])) * float(st["rate"])
	print("flak: %.1f DPS on a 3 m near miss, %.1f on a 5.9 m one" % [near3, float(st["splash_damage"]) * (1.0 - 5.9 / 8.0) * float(st["rate"])])
	check(near3 > 0.0, "a near miss counts")
	near(float(st["active_heat"]) * float(st["rate"]), 3.3, 0.01, "about 3.3 heat/s held")
	check(float(st["rate"]) >= 1.5 - 1e-6, "rapid AA fire: at least 1.5 shells/s")
	check(float(st["impact_radius"]) < float(st["splash_radius"]) * 0.5, "the drawn burst stays small against the 8 m splash")


func _records(dt: float, secs: float) -> Array[Dictionary]:
	var m := WeaponMount.new()
	m.setup(ID, "side_r", "me", 1, MechCatalog.weapon(ID))
	var out: Array[Dictionary] = []
	var t := 0.0
	for i in int(round(secs / dt)):
		out.append_array(m.update(dt, true, null, t, Vector3(0, 2, 0), Vector3(0, 2, -100)))
		t += dt
	return out


func _cadence_heat_ammo() -> void:
	var rate := float(MechCatalog.weapon(ID)["rate"])
	var base := _records(1.0 / 60.0, 10.0)
	eq(base.size(), int(floor(10.0 * rate - 1e-6)) + 1, "shells in 10 s at %.2f /s" % rate)
	if base.size() >= 2:
		near(float(base[1]["t"]) - float(base[0]["t"]), 1.0 / rate, 1e-4, "one shell every %.2f s" % (1.0 / rate))
	for dt: float in [1.0 / 23.0, 1.0 / 144.0, 0.11]:
		var r := _records(dt, 10.0)
		var same := r.size() == base.size()
		for i in mini(r.size(), base.size()):
			same = same and absf(float(r[i]["t"]) - float(base[i]["t"])) < 1e-4
		check(same, "the same shot times at dt %.4f" % dt)
	var m := WeaponMount.new()
	m.setup(ID, "side_r", "me", 1, MechCatalog.weapon(ID))
	eq(m.ammo, 160, "160 shells loaded")
	var h := Heat.new(100000.0, 0.0)
	var fired := 0
	var t := 0.0
	var after_one := -1.0
	for i in 60 * 130:
		fired += m.update(1.0 / 60.0, true, h, t, Vector3.ZERO, Vector3.FORWARD).size()
		t += 1.0 / 60.0
		if after_one < 0.0 and fired == 1:
			after_one = h.value
	near(after_one, 2.2, 1e-3, "2.2 heat per shell")
	eq(fired, 160, "160 shells, then empty")
	eq(m.ammo, 0, "ammo at 0")
	near(h.value, 352.0, 1e-3, "352 heat for 160 shells, none dry")


## The rack (the HUD's slots()) and the ammo bin.
func _rack_and_bin() -> void:
	eq(WeaponRack.bonus_ammo(160, 1, 0.5), 240, "ammo bin: 160 -> 240 (salvo 1: already whole)")
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_r": ID, "shoulder_l": ID, "back": "ammo_bin"})
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "flakrack", 1)
	await frames(2)
	var sl := rack.slots()
	eq(str(sl[1]["weapon"]), ID, "the HUD row names the flak (side_r)")
	eq(str(sl[1]["name"]), "Flak Cannon", "with its catalog name")
	eq(int(sl[1]["ammo"]), 240, "loaded with 240 with the bin")
	eq(int(sl[2]["ammo_max"]), 240, "the shoulder one too")
	check(bool(sl[1]["built"]), "and it is built (fires)")
	var gun := model.find_child("HP_side_r", true, false).find_child("Weapon_" + ID, true, false) if model.find_child("HP_side_r", true, false) != null else null
	check(gun != null and gun.get_child_count() == 1, "a model shows on the hardpoint (placeholder mesh alias)")
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


func _flight() -> void:
	var w := _world()
	var s := w.fire(_rec(Vector3(0, HIGH, 0), Vector3(0, HIGH, -100))) as FlakShell
	if check(s != null, "a flak record spawns a FlakShell"):
		near(s.speed, 140.0, 1e-6, "shell speed 140 m/s")
		near(s.max_time, 220.0 / 140.0, 1e-6, "flies 220 m")
		near(s.flight_pos(1.0).distance_to(Vector3(0, HIGH, 0)), 140.0, 1e-4, "140 m in 1 s, straight")
		near(s.arm_time * s.speed, 12.0, 1e-6, "arms 12 m out")
		var guard := 0
		while s.end_time < 0.0 and guard < 400:
			w.advance(1.0 / 60.0)
			guard += 1
		eq(s.burst, FlakShell.BURST_RANGE, "with nothing near it, it air-bursts at the end of its range")
		near(s.burst_point.distance_to(Vector3(0, HIGH, 0)), 220.0, 1e-3, "220 m out")
		var fx := 0
		for e in w.effects:
			if e is ImpactFx and (e as ImpactFx).point.distance_to(s.burst_point) < 0.01:
				fx += 1
		eq(fx, 1, "the range burst draws one impact")
	_clear(w)
	w.free()


# --- The fuse --------------------------------------------------------------------------------------------

func _fuse_near_miss() -> void:
	var st := MechCatalog.weapon(ID)
	var w := _world()
	var o := Vector3(0, HIGH, 0)
	var near_t := _target(w, "air5", Vector3(R + 5.0, HIGH, -80))    # path passes 5 m from its hull
	var s := _fly(w, _rec(o, Vector3(0, HIGH, -200)))
	eq(s.burst, FlakShell.BURST_FUSE, "a shell passing 5 m from an airborne target is fused")
	eq(s.fused_by, "air5", "by that target")
	near(s.burst_point.distance_to(Vector3(0, HIGH, -80)), 0.0, 1e-3, "it bursts beside it, at the closest approach")
	var expect := float(st["splash_damage"]) * (1.0 - 5.0 / float(st["splash_radius"]))
	near(_lost(near_t), expect, 1e-3, "the target takes the splash falloff at 5 m (%.3f)" % expect)
	_clear(w)
	w.free()
	var w2 := _world()
	var far_t := _target(w2, "air7", Vector3(R + 7.0, HIGH, -80))
	var s2 := _fly(w2, _rec(o, Vector3(0, HIGH, -200)))
	eq(s2.burst, FlakShell.BURST_RANGE, "passing 7 m away it flies on (to its range burst)")
	near(_lost(far_t), 0.0, 1e-6, "and the target 7 m off is untouched")
	_clear(w2)
	w2.free()


func _fuse_arming() -> void:
	var o := Vector3(0, HIGH, 0)
	var w := _world()
	var t := _target(w, "close", Vector3(R + 4.0, HIGH, -5))       # 4 m off the path, 5 m out: inside the arming distance
	var s := _fly(w, _rec(o, Vector3(0, HIGH, -200)))
	check(s.burst != FlakShell.BURST_FUSE, "no proximity burst for a target beside the path inside 12 m (%s)" % s.burst)
	near(_lost(t), 0.0, 1e-6, "it is untouched")
	_clear(w)
	w.free()
	var w2 := _world()
	var on := _target(w2, "onpath", Vector3(0, HIGH, -6))          # on the path, 6 m out
	var s2 := _fly(w2, _rec(o, Vector3(0, HIGH, -200)))
	eq(s2.burst, FlakShell.BURST_DIRECT, "a direct hit inside the arming distance still bursts it")
	check(s2.burst_point.distance_to(o) < 12.0, "there, %.2f m out" % s2.burst_point.distance_to(o))
	check(_lost(on) > float(MechCatalog.weapon(ID)["damage"]), "and the target takes direct + splash (%.2f)" % _lost(on))
	# Every burst is either a strike or at least arm_distance out.
	var w3 := _world()
	_target(w3, "slant", Vector3(R + 4.5, HIGH, -9))   # closest approach at 9 m (unarmed), still inside 6 m at 12 m
	var s3 := _fly(w3, _rec(o, Vector3(0, HIGH, -200)))
	eq(s3.burst, FlakShell.BURST_FUSE, "a target still inside the radius when the fuse arms bursts it then")
	near(s3.burst_point.distance_to(o), 12.0, 1e-4, "at the arming point, never before 12 m")
	for x: CombatWorld in [w2, w3]:
		_clear(x)
		x.free()


func _direct_hit() -> void:
	var st := MechCatalog.weapon(ID)
	var w := _world()
	var o := Vector3(0, 2, 0)
	var t := _target(w, "ground", Vector3(0, 2, -60))
	var side := _target(w, "side", Vector3(4.0, 2, -60))
	var hits := {}
	w.hit_landed.connect(func(tg: CombatTarget, _h: Hit) -> void: hits[tg.target_id] = int(hits.get(tg.target_id, 0)) + 1)
	var s := _fly(w, _rec(o, Vector3(0, 2, -60)))
	eq(s.burst, FlakShell.BURST_DIRECT, "a shell on the target strikes it")
	var expect := float(st["damage"]) + float(st["splash_damage"]) * (1.0 - Combat.PROJECTILE_RADIUS / float(st["splash_radius"]))
	near(_lost(t), expect, 1e-3, "direct hit = direct + splash, once (%.3f)" % expect)
	eq(int(hits.get("ground", 0)), 1, "one Hit on the struck target (no double count)")
	var d := (s.burst_point - Vector3(4.0, 2, -60)).length() - R
	near(_lost(side), float(st["splash_damage"]) * (1.0 - d / float(st["splash_radius"])), 1e-3, "a neighbour takes the plain splash")
	eq(int(hits.get("side", 0)), 1, "one Hit on the neighbour")
	_clear(w)
	w.free()


## The same near miss at dt 1/10 (14 m chords) and 1/120: the same burst point and damage.
func _swept_fuse() -> void:
	var res := []
	for dt: float in [1.0 / 120.0, 1.0 / 60.0, 1.0 / 10.0]:
		var w := _world()
		var t := _target(w, "air", Vector3(R + 3.0, HIGH + 1.0, -97.3))
		var s := _fly(w, _rec(Vector3(0, HIGH, 0), Vector3(0, HIGH, -200)), dt)
		res.append([dt, s.burst, s.burst_point, _lost(t)])
		_clear(w)
		w.free()
	for r: Array in res:
		eq(str(r[1]), FlakShell.BURST_FUSE, "fused at dt %.4f" % float(r[0]))
		near((r[2] as Vector3).distance_to(res[0][2]), 0.0, 0.01, "same burst point at dt %.4f (%s)" % [float(r[0]), r[2]])
		near(float(r[3]), float(res[0][3]), 0.01, "same damage at dt %.4f" % float(r[0]))
	check((res[0][2] as Vector3).distance_to(Vector3(0, HIGH, -97.3)) < 0.01, "at the closest approach (%s)" % res[0][2])


## Never the shooter; a teammate only with friendly fire on; enemies always.
func _who_fuses() -> void:
	var o := Vector3(0, HIGH, 0)
	var to := Vector3(0, HIGH, -200)
	var w := _world()
	var me := _target(w, "me", Vector3(R + 3.0, HIGH, -50), "player", 1)
	var s := _fly(w, _rec(o, to))
	check(s.burst != FlakShell.BURST_FUSE, "never fused by the shooter itself (%s)" % s.burst)
	near(_lost(me), 0.0, 1e-6, "and no self-damage")
	_clear(w)
	w.free()
	for ff: bool in [false, true]:
		var wf := _world()
		wf.friendly_fire = ff
		var mate := _target(wf, "mate", Vector3(R + 3.0, HIGH, -50), "player", 1)
		var sm := _fly(wf, _rec(o, to))
		if ff:
			eq(sm.burst, FlakShell.BURST_FUSE, "friendly fire on: a teammate fuses it")
			check(_lost(mate) > 0.0, "and takes the splash (%.2f)" % _lost(mate))
		else:
			check(sm.burst != FlakShell.BURST_FUSE, "friendly fire off: a teammate does not fuse it (%s)" % sm.burst)
			near(_lost(mate), 0.0, 1e-6, "and is untouched")
		_clear(wf)
		wf.free()
		var we := _world()
		we.friendly_fire = ff
		var foe := _target(we, "foe", Vector3(R + 3.0, HIGH, -50), "enemy", 0)
		var se := _fly(we, _rec(o, to))
		eq(se.burst, FlakShell.BURST_FUSE, "an enemy always fuses it (friendly fire %s)" % ("on" if ff else "off"))
		check(_lost(foe) > 0.0, "and takes the splash")
		_clear(we)
		we.free()


## Two machines' views of one record: the shooter's (peer 1 here, decides about the host-owned target) and another
## machine's (the record's peer is 2: this machine does not decide). Same burst, damage only where it is decided.
func _non_deciding() -> void:
	var out := []
	for peer: int in [1, 2]:
		var w := _world()
		var t := _target(w, "drone", Vector3(R + 4.0, HIGH, -70))
		var remote := [0]
		w.remote_hit.connect(func(_id: String, _h: Hit) -> void: remote[0] += 1)
		var s := _fly(w, _rec(Vector3(0, HIGH, 0), Vector3(0, HIGH, -200), 5, "player", peer))
		var fx := 0
		for e in w.effects:
			if e is ImpactFx:
				fx += 1
		out.append([s.burst, s.burst_point, _lost(t), remote[0], fx])
		_clear(w)
		w.free()
	eq(str(out[0][0]), FlakShell.BURST_FUSE, "the deciding machine fuses it")
	eq(str(out[1][0]), FlakShell.BURST_FUSE, "the other machine fuses its copy too")
	near((out[1][1] as Vector3).distance_to(out[0][1]), 0.0, 1e-4, "at the same point")
	check(float(out[0][2]) > 0.0, "the deciding machine applies the splash (%.2f)" % float(out[0][2]))
	near(float(out[1][2]), 0.0, 1e-6, "the non-deciding machine applies no damage")
	eq(int(out[1][3]), 0, "and sends no remote hit")
	check(int(out[1][4]) >= 1, "but draws the burst")


# --- Armour ------------------------------------------------------------------------------------------------

## Fly one shot of `weapon` from `o` to `to` (generic: any projectile) until it ends or 3 s pass.
func _fly_any(w: CombatWorld, weapon: String, o: Vector3, to: Vector3, idx: int) -> void:
	var r := Combat.fire_record("me", 1, "side_r", weapon, o, to, w.now, idx, 0.0)
	r["team"] = "player"
	var e := w.fire(r)
	var guard := 0
	while e != null and is_instance_valid(e) and not e.finished() and guard < 180:
		w.advance(1.0 / 60.0)
		guard += 1


func _armour() -> void:
	var st := MechCatalog.weapon(ID)
	var am := float(st.get("armor_mult", 1.0))
	near(am, 0.35, 1e-6, "flak armor_mult 0.35")
	check(not MechCatalog.weapon("autocannon").has("armor_mult"), "the autocannon has no armor_mult (x1)")
	var plain := float(st["damage"]) + float(st["splash_damage"]) * (1.0 - Combat.PROJECTILE_RADIUS / float(st["splash_radius"]))
	print("flak vs armour: %.2f -> %.2f a direct shell, %.1f -> %.1f DPS" % [plain, plain * am, plain * float(st["rate"]), plain * am * float(st["rate"])])
	# A direct strike on an armoured target, an armoured and an unarmoured neighbour in the splash.
	var w := _world()
	var o := Vector3(0, 2, 0)
	var t := _target(w, "tankish", Vector3(0, 2, -60))
	t.armored = true
	var side_a := _target(w, "side_a", Vector3(4.0, 2, -60))
	side_a.armored = true
	var side_u := _target(w, "side_u", Vector3(-4.0, 2, -60))
	var hits := {}
	w.hit_landed.connect(func(tg: CombatTarget, _h: Hit) -> void: hits[tg.target_id] = int(hits.get(tg.target_id, 0)) + 1)
	var s := _fly(w, _rec(o, Vector3(0, 2, -60)))
	eq(s.burst, FlakShell.BURST_DIRECT, "a shell on the armoured target strikes it")
	near(_lost(t), plain * am, 1e-3, "armoured: (direct + splash) x 0.35 = %.3f" % (plain * am))
	eq(int(hits.get("tankish", 0)), 1, "still one Hit on the struck armoured target")
	var da := (s.burst_point - side_a.global_position).length() - R
	var du := (s.burst_point - side_u.global_position).length() - R
	var spl_a := float(st["splash_damage"]) * (1.0 - da / float(st["splash_radius"]))
	var spl_u := float(st["splash_damage"]) * (1.0 - du / float(st["splash_radius"]))
	near(_lost(side_a), spl_a * am, 1e-3, "an armoured neighbour takes splash x 0.35 (%.3f)" % (spl_a * am))
	near(_lost(side_u), spl_u, 1e-3, "an unarmoured neighbour takes the full splash (%.3f)" % spl_u)
	_clear(w)
	w.free()
	# A fused near miss on an armoured aircraft-sized target: splash x 0.35.
	var w2 := _world()
	var air := _target(w2, "air_arm", Vector3(R + 5.0, HIGH, -80))
	air.armored = true
	var s2 := _fly(w2, _rec(Vector3(0, HIGH, 0), Vector3(0, HIGH, -200)))
	eq(s2.burst, FlakShell.BURST_FUSE, "the armoured target fuses it")
	near(_lost(air), float(st["splash_damage"]) * (1.0 - 5.0 / float(st["splash_radius"])) * am, 1e-3, "fused splash x 0.35 on armour")
	_clear(w2)
	w2.free()
	# The shared rule: x armor_mult on armour only, x1 for weapons without it.
	var ac_st := MechCatalog.weapon("autocannon")
	var dummy := CombatTarget.new()
	near(CombatWorld.armor_scaled(st, dummy, 10.0), 10.0, 1e-9, "armor_scaled: unarmoured unchanged")
	dummy.armored = true
	near(CombatWorld.armor_scaled(st, dummy, 10.0), 3.5, 1e-9, "armor_scaled: flak on armour x 0.35")
	near(CombatWorld.armor_scaled(ac_st, dummy, 10.0), 10.0, 1e-9, "armor_scaled: autocannon on armour unchanged")
	dummy.free()
	# A non-flak weapon: the autocannon does the same damage to an armoured and an unarmoured target.
	var lost := []
	for arm: bool in [false, true]:
		var wa := _world()
		var ta := _target(wa, "ac_t", Vector3(0, 2, -40))
		ta.armored = arm
		_fly_any(wa, "autocannon", Vector3(0, 2, 0), Vector3(0, 2, -40), 9)
		lost.append(_lost(ta))
		_clear(wa)
		wa.free()
	check(float(lost[0]) > 0.0, "the autocannon round hits (%.3f)" % float(lost[0]))
	near(float(lost[1]), float(lost[0]), 1e-6, "autocannon: the same damage on armour (%.3f vs %.3f)" % [float(lost[1]), float(lost[0])])
	near(float(lost[0]), float(ac_st["damage"]), 1e-3, "= its catalog damage, as before")


## Who is armoured: player mechs, the relay, the catalog's armoured enemy classes (turrets, striders, the tank); never
## drones, aircraft or troopers. Read off real configured enemies (EnemyBase reads the catalog's "armored").
func _armour_who() -> void:
	var pt := PlayerTarget.new()
	check(pt.armored, "a player mech is armoured")
	pt.free()
	var at := AssetTarget.new("relay")
	check(at.armored, "the relay (AssetTarget) is armoured")
	at.free()
	var w := _world()
	var expect := {"turret": true, "turret_sniper": true, "turret_missile": true, "strider": true, "strider_breacher": true,
		"tank": true, "drone": false, "trooper_rifle": false, "trooper_at": false, "gunship": false, "dropship": false}
	for id: String in EnemyCatalog.CLASS_ORDER:
		check(expect.has(id), "armour split covers enemy class %s" % id)
		var e := EnemySpawner.make_enemy(id)
		e.configure(id, "arm_" + id, w, null, null, 1)
		eq(e.armored, bool(expect.get(id, false)), "%s armoured: %s" % [id, str(expect.get(id, false))])
		e.free()
	w.free()


# --- World geometry, props, decals ------------------------------------------------------------------------

func _body(size: Vector3, at: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	b.position = at
	add_child(b)
	return b


func _decals(fx: ImpactFx) -> int:
	var n := 0
	for p: Dictionary in fx._parts:
		if str(p["kind"]) in ["scorch", "ember", "ring", "pebble"]:
			n += 1
	return n


func _fx_at(w: CombatWorld, p: Vector3) -> ImpactFx:
	for e in w.effects:
		if e is ImpactFx and (e as ImpactFx).point.distance_to(p) < 0.05:
			return e
	return null


func _physics_bursts() -> void:
	var w := _world(true)
	var ground := _body(Vector3(600, 1, 600), Vector3(0, -0.5, -200))
	var wall := _body(Vector3(20, 12, 1), Vector3(0, 6, -50.5))
	await frames(3)
	# A wall.
	var s := _fly(w, _rec(Vector3(0, 3, 0), Vector3(0, 3, -60), 1))
	eq(s.burst, FlakShell.BURST_CONTACT, "a wall bursts it")
	near(s.burst_point.z, -50.0, 0.05, "on the wall's face")
	var fxw := _fx_at(w, s.burst_point)
	check(fxw != null and _decals(fxw) > 0, "a wall burst scorches the wall")
	_clear(w)
	# The ground (aimed down, short of the wall).
	var sg := _fly(w, _rec(Vector3(0, 6, 0), Vector3(0, 0, -30), 2))
	eq(sg.burst, FlakShell.BURST_CONTACT, "the ground bursts it")
	near(sg.burst_point.y, 0.0, 0.05, "on the ground")
	var fxg := _fx_at(w, sg.burst_point)
	if check(fxg != null, "a ground burst draws an impact"):
		var rings := 0
		var scorch := 0
		for p: Dictionary in fxg._parts:
			rings += 1 if str(p["kind"]) == "ring" else 0
			scorch += 1 if str(p["kind"]) == "scorch" else 0
		check(rings == 1 and scorch == 1, "a ground burst lays a ring and a scorch (%d, %d)" % [rings, scorch])
	_clear(w)
	# An air burst on the fuse, 20 m up beside a hovering target, behind the wall's line (off to the side).
	var air := _target(w, "air", Vector3(30.0 + R + 4.0, HIGH, -80))
	var sa := _fly(w, _rec(Vector3(30, HIGH, 0), Vector3(30, HIGH, -200), 3))
	eq(sa.burst, FlakShell.BURST_FUSE, "fused beside the hovering target")
	check(_lost(air) > 0.0, "which takes damage")
	var fxa := _fx_at(w, sa.burst_point)
	if check(fxa != null, "the air burst draws an impact"):
		eq(_decals(fxa), 0, "an air burst lays no scorch / ember / ring / pebble")
		check(fxa.visible_parts("flash") == 1, "but its flash shows")
		check(is_equal_approx(fxa.radius, float(MechCatalog.weapon(ID)["impact_radius"])), "at the flak's impact radius")
	_clear(w)
	w.unregister(air)
	air.queue_free()
	# The range air burst: climbing away, 220 m out.
	var sr := _fly(w, _rec(Vector3(-40, 3, 0), Vector3(-40, 120, -100), 4))
	eq(sr.burst, FlakShell.BURST_RANGE, "climbing into the open it bursts at its range")
	var fxr := _fx_at(w, sr.burst_point)
	check(fxr != null and _decals(fxr) == 0, "the range air burst lays no decal")
	_clear(w)
	w.queue_free()
	ground.queue_free()
	wall.queue_free()
	await frames(1)


func _prop() -> void:
	var w := _world()
	var props := FakeProps.new()
	props.centre = Vector3(0, 2, -40)
	props.add_to_group("city_props")
	add_child(props)
	await frames(1)
	w.advance(1.0 / 60.0)
	check(w.props() == props, "the world finds the props node")
	var s := _fly(w, _rec(Vector3(0, 2, 0), Vector3(0, 2, -80), 6))
	eq(s.burst, FlakShell.BURST_CONTACT, "a prop bursts it")
	near(s.burst_point.z, -40.0 + props.radius + Combat.PROJECTILE_RADIUS, 0.05, "on the prop")
	var tree_dv := float(CityPropSim.TYPES["tree"]["dv"])
	if check(props.impulses.size() == 1, "the prop takes the direct shove once"):
		var dv := ((props.impulses[0] as Array)[1] as Vector3).length()
		check(dv < tree_dv, "the shove (%.2f m/s) is under a tree's topple threshold (%.1f): a tree stays standing" % [dv, tree_dv])
	if check(props.blasts.size() == 1, "and the blast once"):
		var bdv := float((props.blasts[0] as Array)[2])
		check(bdv < tree_dv, "the blast (%.2f m/s at the centre) is under it too" % bdv)
	_clear(w)
	w.queue_free()
	props.queue_free()
	await frames(1)


# --- Lab --------------------------------------------------------------------------------------------------

func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	lab.time_scale = 0.0
	var weapons: Array = []
	var aims: Array = []
	for o: Dictionary in lab.lab_options():
		if o["id"] == "weapon":
			weapons = o["choices"]
		elif o["id"] == "aim":
			aims = o["choices"]
	check(ID in weapons, "the lab lists the flak")
	check(WeaponRangeLab.AIR_AIM in aims and WeaponRangeLab.AIR_NEAR_AIM in aims, "and the airborne aim choices")
	lab.set_lab_option("weapon", ID)
	lab.set_lab_option("aim", WeaponRangeLab.AIR_NEAR_AIM)
	lab.set_lab_option("fire", "hold")
	check(lab.air_dummy.global_position.y > 15.0, "the airborne dummy hovers (y %.1f)" % lab.air_dummy.global_position.y)
	var fused := 0
	for i in 60 * 3:
		lab.step(1.0 / 60.0)
		for e in lab.world.effects:
			if e is FlakShell and (e as FlakShell).fused_by == WeaponRangeLab.AIR_AIM:
				fused += 1
	check(fused > 0, "a lab shell aimed beside the airborne dummy is fused by it")
	check(lab.air_dummy.total_hp() < lab.air_dummy.total_max_hp(), "the airborne dummy takes the near misses (%.0f HP)" % lab.air_dummy.total_hp())
	check(lab._heat_label.text.contains("AMMO") and lab._heat_label.text.contains("/ 160"), "the shooter shows its ammo: " + lab._heat_label.text.replace("\n", " | "))
	lab.queue_free()
	await frames(1)
