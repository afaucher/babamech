extends TestCase
## The Back Mortar on a CURVED ring deck (code-audit-2026-11 "the mortar assumes world +Y is up"; weapons.md §3.7 "on a
## curved deck"). The deck is the real deck-0 geometry (radius 400 m, SectionPlan) in a CityStack.DeckRing (world
## positions with an offset origin, as CombatWorld.ring_at hands it out on the stack), and the shooter stands 70° round
## the ring from world-top, so its local up is 70° off world +Y; the targets are 150-250 m along the deck (they reach
## 100°+). Asserts: the shell lands on the aimed deck point (within scatter, ON the deck), its apex is apex_for(range)
## above the chord measured along the local up (height above the deck), the flight time is the flat floor's for the same
## deck distance, it never dips under the floor or reaches the 40 m ceiling, the range gate measures along the deck
## (min / max range as on a flat floor), direct-hit knockback lies along the deck (+ the weapon's lift along the target's
## up), the telegraph ring lies on the deck, and WeaponRack's in_range readout agrees with the gate.
## A flat reference shot prints its numbers (MORTAR_FLAT ...) so a change to the flat path shows.

const R := 400.0                  ## SectionPlan radius_of(0)
const CLEAR := 40.0               ## SectionPlan clear_height(): pitch 48 - slab 8
const THETA0 := 70.0              ## degrees round the ring from world-top
const MUZZLE_H := 4.0

var ring: RingFrame
var s0 := 0.0


func setup() -> void:
	var dr := CityStack.DeckRing.new(R, null)
	dr.offset = Vector3(0.0, -96.0, 0.0)     # a deck two pitches up a translated stack: the origin is not the world's
	ring = dr
	s0 = R * deg_to_rad(THETA0)
	_flat_reference()
	_frame_sanity()
	_flight()
	_gate()
	await _knockback()
	_telegraph()
	await _rack_agrees()
	finish()


func _p(s: float, h: float, x: float = 0.0) -> Vector3:
	return ring.arc_to_world(x, s, h)


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 31
	w.use_physics = false
	w.ring = ring
	add_child(w)
	return w


func _rec(from: Vector3, target: Vector3, shot: int = 0) -> Dictionary:
	return Combat.fire_record("me", 1, "back", "mortar", from, target, 0.0, shot)


## The flat floor numbers (no ring): printed, and pinned to the values the code gave before the curved-deck fix.
func _flat_reference() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 31
	add_child(w)
	var s := w.fire(Combat.fire_record("me", 1, "back", "mortar", Vector3(0, 4, 0), Vector3(1.0, 1.9, -180), 0.0, 4)) as MortarShell
	print("MORTAR_FLAT landing %s flight_time %.6f apex_h %.6f mid %s range %.6f" % [s.landing, s.flight_time, s.apex_h,
		s.flight_pos(1.3), s.range_m])
	near(s.flight_time, 3.800028, 0.00001, "flat: flight time unchanged")
	near(s.range_m, 180.002778, 0.00001, "flat: range unchanged")
	w.remove_effect(s)
	w.free()


func _frame_sanity() -> void:
	var up := ring.up_at(_p(s0, 0.0))
	near(rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))), THETA0, 0.01, "the shooter's local up is 70° off world +Y")
	near(ring.height(_p(s0 + 200.0, 0.0)), 0.0, 0.001, "deck points are on the floor")


func _flight() -> void:
	var st := MechCatalog.weapon("mortar")
	var w := _world()
	var shot := 0
	for d: float in [150.0, 200.0, 250.0]:
		for sgn: float in [1.0, -1.0]:
			var dx := 6.0
			var origin := _p(s0, MUZZLE_H)
			var target := _p(s0 + sgn * d, 0.0, dx)
			var deck_d := sqrt(d * d + dx * dx)
			var tag := "%d m %s" % [int(d), "ahead" if sgn > 0.0 else "behind"]
			var s := w.fire(_rec(origin, target, shot)) as MortarShell
			shot += 1
			if not check(s != null, "a MortarShell (%s)" % tag):
				continue
			near(s.range_m, deck_d, 0.05, "range is the distance along the deck (%s: %.2f)" % [tag, s.range_m])
			near(s.flight_time, MortarShell.flight_time_for(st, deck_d), 0.001,
				"flight time = the flat floor's at the same deck distance (%s: %.3f s)" % [tag, s.flight_time])
			check(s.flight_pos(0.0).distance_to(origin) < 0.001, "the arc starts at the muzzle (%s)" % tag)
			check(s.flight_pos(s.flight_time).distance_to(s.landing) < 0.001, "the arc ends at the landing point (%s)" % tag)
			near(ring.height(s.landing), 0.0, 0.05, "it lands ON the deck (%s: %.3f m above)" % [tag, ring.height(s.landing)])
			var off := s.landing.distance_to(target)
			check(off <= MortarShell.scatter_for(st, deck_d) + 0.05, "within the scatter of the aim point (%s: %.2f m)" % [tag, off])
			var apex := ring.height(s.flight_pos(s.flight_time * 0.5))
			var want := (MUZZLE_H + ring.height(s.landing)) * 0.5 + MortarShell.apex_for(st, deck_d)
			near(apex, want, 0.1, "the apex is apex_for(range) above the chord, along the local up (%s: %.2f m above the deck)" % [tag, apex])
			var lo := INF
			var hi := -INF
			for i in 201:
				var hh := ring.height(s.flight_pos(s.flight_time * float(i) / 200.0))
				lo = minf(lo, hh)
				hi = maxf(hi, hh)
			check(lo >= -0.01, "it never dips under the curved floor (%s: lowest %.2f m)" % [tag, lo])
			check(hi < CLEAR, "it stays under the 40 m ceiling (%s: highest %.2f m)" % [tag, hi])
			if d == 250.0:
				print("MORTAR_CURVED %s apex %.2f m above the deck (ceiling %.0f m), flight %.3f s" % [tag, hi, CLEAR, s.flight_time])
			check(s.flight_dir(s.flight_time).dot(ring.up_at(s.landing)) < -0.3, "it comes down steeply onto the deck (%s)" % tag)
			w.remove_effect(s)
	w.free()


func _mount(st: Dictionary) -> WeaponMount:
	var m := WeaponMount.new()
	m.setup("mortar", "back", "me", 1, st)
	m.set("frame", ring)      # the deck frame the gate measures along (WeaponRack sets it from the world)
	return m


func _gate() -> void:
	var st := MechCatalog.weapon("mortar")
	var h := Heat.new(1000.0, 0.0)
	var origin := _p(s0, MUZZLE_H)
	var cases := [[20.0, 0, "TOO CLOSE"], [29.5, 0, "TOO CLOSE"], [30.5, 1, ""], [150.0, 1, ""], [249.0, 1, ""],
		[255.0, 0, "OUT OF RANGE"], [-249.0, 1, ""], [-29.0, 0, "TOO CLOSE"]]
	for c: Array in cases:
		var m := _mount(st)
		var aim := _p(s0 + float(c[0]), 0.0)
		var n := m.update(0.1, true, h, 0.0, origin, aim).size()
		eq(n, int(c[1]), "%.1f m along the deck: %d shot(s) (hold '%s')" % [float(c[0]), int(c[1]), m.hold_reason])
		check(m.hold_reason.begins_with(str(c[2])) if str(c[2]) != "" else m.hold_reason == "",
			"%.1f m along the deck says '%s' (got '%s')" % [float(c[0]), str(c[2]), m.hold_reason])
	# 249 m along the deck with the aim point 30 m up (a rooftop): range is along the deck, the height doesn't count.
	var m2 := _mount(st)
	eq(m2.update(0.1, true, h, 0.0, origin, _p(s0 + 249.0, 30.0)).size(), 1, "249 m along the deck, 30 m up: fires")


func _knockback() -> void:
	var w := _world()
	w.overrides["mortar"] = {"scatter_max": 0.0}
	var st := w.stats("mortar")
	var at := _p(s0 + 120.0, 0.0)
	var d := TargetDummy.new()
	d.name = "deck_dummy"
	d.target_id = "deck_dummy"
	d.mass_class = "light"
	d.up = ring.up_at(at)
	d.transform = Transform3D(ring.basis_at(at), at)
	add_child(d)
	w.register(d)
	await frames(1)
	var hits := {}
	w.hit_landed.connect(func(t: CombatTarget, hh: Hit) -> void: hits[t.target_id] = hh)
	w.fire(_rec(_p(s0, MUZZLE_H), at + d.up * 1.9, 3))
	var t := 0.0
	while w.live_shots() > 0 and t < 10.0:
		w.advance(1.0 / 60.0)
		t += 1.0 / 60.0
	if check(hits.has("deck_dummy"), "the dummy on the curved deck takes a direct hit"):
		var hh: Hit = hits["deck_dummy"]
		near(hh.damage, 80.0, 0.001, "80 direct damage")
		var up := d.up
		near(hh.impulse.dot(up), float(st["splash_lift"]), 0.01,
			"the only push along the target's up is the weapon's lift (%.2f)" % hh.impulse.dot(up))
		near((hh.impulse - up * hh.impulse.dot(up)).length(), float(st["knockback"]), 0.01,
			"the radial knockback lies along the deck (%.2f)" % (hh.impulse - up * hh.impulse.dot(up)).length())
	d.free()
	w.free()
	await frames(1)


func _telegraph() -> void:
	var w := _world()
	var s := w.fire(_rec(_p(s0, MUZZLE_H), _p(s0 + 160.0, 0.0), 7)) as MortarShell
	w.advance(1.0 / 60.0)
	if check(s != null and s._ring_outer != null, "the telegraph ring exists"):
		var up := ring.up_at(s.landing)
		var at := s._ring_outer.global_position
		near(ring.height(at), 0.06, 0.02, "the ring lies on the deck under the landing point (%.3f m)" % ring.height(at))
		check(at.distance_to(s.landing) < 0.2, "at the landing point (%.3f m)" % at.distance_to(s.landing))
		check(s._ring_outer.global_transform.basis.y.normalized().dot(up) > 0.999, "flat on the deck (its normal is the local up)")
	w.free()


## WeaponRack on the curved deck: the HUD's in_range and the hold reason agree with the gate (along the deck).
func _rack_agrees() -> void:
	var w := _world()
	var at := _p(s0, 0.0)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", MechCatalog.chassis("strider")["default_loadout"])
	model.global_transform = Transform3D(ring.basis_at(at, ring.tangent_at(at)), at)
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(w, mech, model, null, "curved", 1)
	await frames(2)
	var slot := rack.weapons.find("mortar")
	if check(slot >= 0, "the Strider's default loadout carries the mortar"):
		for c: Array in [[20.0, false, "TOO CLOSE"], [120.0, true, ""], [245.0, true, ""], [-240.0, true, ""], [262.0, false, "OUT OF RANGE"]]:
			rack.aim_point = _p(s0 + float(c[0]), 0.0)
			rack.step(1.0 / 60.0)
			var sl: Dictionary = rack.slots()[slot]
			eq(bool(sl["in_range"]), bool(c[1]), "rack in_range at %.0f m along the deck" % float(c[0]))
			check(str(sl["hold"]).begins_with(str(c[2])) if str(c[2]) != "" else str(sl["hold"]) == "",
				"rack hold at %.0f m along the deck: '%s'" % [float(c[0]), str(sl["hold"])])
	rack.free()
	mech.free()
	model.free()
	w.free()
	await frames(1)
