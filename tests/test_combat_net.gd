extends TestCase
## CombatNet's single-process pieces (docs/design/weapons.md §5, co-op step 3): every weapon's fire records are plain
## data (only CombatNet.RECORD_KEYS + shooter / peer, all of serialisable types) and survive encode -> var_to_bytes ->
## decode exactly, so a remote machine fires the identical shot (same spread draw from Combat.shot_rng); decode refuses
## malformed or non-player records; a Hit survives encode_hit / decode_hit; CombatWorld.set_clock runs `now` on a shared
## clock (never backwards, back to counting deltas while it reads negative) and without one counts deltas as before.

var _fake_t := -1.0


func setup() -> void:
	_records()
	_decode_refuses()
	_hit_roundtrip()
	_clock()
	finish()


## Every built player weapon, trigger held 3 s at 60 Hz: its records and the remote copy.
func _records() -> void:
	var a := CombatWorld.new()
	a.mission_seed = 5
	a.use_physics = false
	add_child(a)
	var b := CombatWorld.new()
	b.mission_seed = 5
	b.use_physics = false
	add_child(b)
	var origin := Vector3(0, 4, 0)
	var aim := Vector3(3, 2, -100)
	var allowed := CombatNet.RECORD_KEYS.duplicate()
	allowed.append_array(["shooter", "peer"])
	var weapons := 0
	for w: String in MechCatalog.WEAPON_ORDER:
		if WeaponRegistry.behaviour(w) == null:
			continue
		weapons += 1
		var m := WeaponMount.new()
		m.setup(w, "side_l", "player7", 7, a.stats(w))
		var recs: Array[Dictionary] = []
		for i in 180:
			recs.append_array(m.update(1.0 / 60.0, i < 170, null, float(i) / 60.0, origin, aim))
		if not check(not recs.is_empty(), "%s fires with the trigger held" % w):
			continue
		for rec in recs:
			for k: String in rec:
				check(k in allowed, "%s record field `%s` is one CombatNet carries" % [w, k])
			var wire: Variant = bytes_to_var(var_to_bytes(CombatNet.encode(rec)))
			var back := CombatNet.decode(wire, 7)
			if not check(not back.is_empty(), "%s record decodes" % w):
				break
			for k: String in rec:
				if rec[k] is Vector3:
					check((rec[k] as Vector3).is_equal_approx(back[k]), "%s %s survives the wire" % [w, k])
				else:
					eq(back[k], rec[k], "%s %s survives the wire" % [w, k])
		# The same shot on two machines: identical spread draw and path.
		var rec0: Dictionary = recs[recs.size() - 1]
		var ea := a.fire(rec0)
		var eb := b.fire(CombatNet.decode(bytes_to_var(var_to_bytes(CombatNet.encode(rec0))), 7))
		if ea is Projectile and eb is Projectile:
			check((ea as Projectile).dir.is_equal_approx((eb as Projectile).dir), "%s: the remote copy draws the same spread" % w)
			for e: float in [0.1, 0.5, 1.0]:
				check((ea as Projectile).flight_pos(e).distance_to((eb as Projectile).flight_pos(e)) < 1e-4,
					"%s: same path at %.1f s" % [w, e])
	check(weapons >= 9, "every built weapon was checked (%d)" % weapons)
	a.queue_free()
	b.queue_free()


func _decode_refuses() -> void:
	var good := [ "side_l", "autocannon", Vector3.ZERO, Vector3.FORWARD, Vector3(0, 0, -10), 1.0, 3, 0.4]
	check(not CombatNet.decode(good, 2).is_empty(), "a good record decodes")
	check(CombatNet.decode(good, 0).is_empty(), "no peer: refused")
	var bad := good.duplicate()
	bad[1] = "enemy_bolter"
	check(CombatNet.decode(bad, 2).is_empty(), "an enemy weapon is refused (enemy fire never crosses this way)")
	bad = good.duplicate()
	bad[2] = Vector3(NAN, 0, 0)
	check(CombatNet.decode(bad, 2).is_empty(), "a non-finite origin is refused")
	check(CombatNet.decode(good.slice(0, 7), 2).is_empty(), "a short record is refused")
	check(CombatNet.decode({"weapon": "laser"}, 2).is_empty(), "a dictionary is refused")
	var r := CombatNet.decode(good, 4)
	eq(str(r["shooter"]), "player4", "shooter comes from the sender")
	eq(int(r["peer"]), 4, "peer comes from the sender")


func _hit_roundtrip() -> void:
	var h := Hit.new()
	h.damage = 22.0
	h.impulse = Vector3(1, 0, 2)
	h.heat = 2.2
	h.point = Vector3(5, 6, 7)
	h.normal = Vector3.UP
	h.component = "turret"
	h.weapon = "autocannon"
	h.shooter = "player3"
	h.shot = "player3/side_l/4"
	var d: Dictionary = bytes_to_var(var_to_bytes(CombatNet.encode_hit("t1", h)))
	var b := CombatNet.decode_hit(d)
	if check(b != null, "a hit decodes"):
		near(b.damage, 22.0, 1e-6, "damage")
		check(b.impulse.is_equal_approx(h.impulse), "impulse")
		near(b.heat, 2.2, 1e-6, "heat")
		eq(b.component, "turret", "component")
		eq(b.shooter, "player3", "shooter")
		eq(b.shot, h.shot, "shot key")
	eq(str(d["id"]), "t1", "target id")


func _clock() -> void:
	var w := CombatWorld.new()
	w.use_physics = false
	add_child(w)
	w.advance(0.5)
	near(w.now, 0.5, 1e-9, "no clock: now counts deltas")
	_fake_t = 100.0
	w.set_clock(func() -> float: return _fake_t)
	near(w.now, 100.0, 1e-9, "set_clock snaps now to the shared clock")
	_fake_t = 100.25
	w.advance(1.0 / 60.0)
	near(w.now, 100.25, 1e-9, "advance reads the shared clock, not the delta")
	_fake_t = 100.2
	w.advance(1.0 / 60.0)
	near(w.now, 100.25, 1e-9, "never backwards")
	_fake_t = -1.0
	w.advance(0.5)
	near(w.now, 100.75, 1e-9, "no shared clock right now: counts deltas again")
	w.set_clock(Callable())
	w.advance(0.25)
	near(w.now, 101.0, 1e-9, "cleared: local clock")
	w.queue_free()
