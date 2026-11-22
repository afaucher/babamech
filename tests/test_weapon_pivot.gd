extends TestCase
## Pivoting direct-fire weapons (docs/design/weapons.md §4.4; WeaponMount.pivoting, WeaponPose): every direct-fire weapon
## turns at its mount toward the aim point and its shots leave straight out of the barrel. Aiming 10 m ahead and 6 m
## below settles the barrel pitched down at the right angle and the next shot leaves from the turned muzzle along a line
## through the aim point (shoulder and side pivots, every direct-fire weapon); a 30° step takes ~30 / slew s and rounds
## fired meanwhile leave along intermediate directions; an aim 80° to the side parks the barrel at 30° and it fires
## along the parked barrel (arc switch off) or holds with OUT OF ARC (on); the mortar doesn't pivot; the swivel keeps
## its ±120°; the range turns with the body; WeaponPose puts the model's muzzle on the gameplay muzzle (left / right,
## mirrored, scaled); determinism across frame steps; WeaponRack.slots().on_target; the weapon_range lab pitches down.

const SHOOTER := "piv"
const DIRECT := ["laser", "autocannon", "gatling", "rockets", "missiles", "railgun", "flamer"]
const STEPS := [1.0 / 60.0, 1.0 / 30.0, 1.0 / 144.0, 0.11]
const SCALE := 2.4                                # a mech's body scale (2 × MechMeshes.BODY_SCALE)
## Pivot points for the two kinds of hardpoint (world space, body facing -Z).
const PIVOTS := {"shoulder": Vector3(0.9, 6.2, 0.3), "side": Vector3(1.6, 3.6, -0.4)}


func setup() -> void:
	Combat.FIXED_ARC_ENABLED = false
	_classes()
	_settles_down()
	_slew()
	_limits()
	_mortar()
	_swivel()
	_rotated_body()
	_determinism()
	await _pose_marker()
	await _rack()
	await _lab()
	Combat.FIXED_ARC_ENABLED = false
	finish()


func _body(yaw_deg: float = 0.0) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis.from_scale(Vector3.ONE * SCALE)


func _mount(id: String, hp: String = "side_r") -> WeaponMount:
	var m := WeaponMount.new()
	m.setup(id, hp, SHOOTER, 1, MechCatalog.weapon(id))
	return m


## The unturned muzzle the firer passes for a weapon pivoting at `pivot` on `body`.
func _rest(id: String, pivot: Vector3, body: Basis) -> Vector3:
	return pivot + body * Vector3(0, 0, -float(MechCatalog.weapon(id)["muzzle"]))


## Drive `m` for `seconds` at step dt; the clock passed is the step's END time ((i + 1) dt). `aim` is a Vector3 or a
## Callable(now) -> Vector3.
func _drive(m: WeaponMount, seconds: float, dt: float, held: bool, aim: Variant, pivot: Vector3, body: Basis,
		t0: float = 0.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := int(ceil(seconds / dt - 1e-9))
	m.set_body_basis(body)
	for i in n:
		var now := t0 + float(i + 1) * dt
		var a: Vector3 = aim.call(now) if aim is Callable else aim
		out.append_array(m.update(dt, held, null, now, _rest(m.weapon_id, pivot, body), a))
	return out


## Distance from point p to the line through `o` along `d`.
func _miss(o: Vector3, d: Vector3, p: Vector3) -> float:
	var v := p - o
	return (v - d.normalized() * v.dot(d.normalized())).length()


func _classes() -> void:
	for id: String in DIRECT:
		check(_mount(id).pivoting(), "%s pivots at its mount" % id)
		check(Combat.pivots(id, MechCatalog.weapon(id)), "  ... Combat.pivots(%s)" % id)
	check(not _mount("mortar").pivoting(), "the mortar doesn't pivot")
	check(not _mount("swivel").pivoting(), "the swivel aims itself (not the shared pivot)")
	check(Combat.own_arc("swivel") and not Combat.own_arc("autocannon"), "own_arc: the swivel only")
	near(float(MechCatalog.weapon("railgun")["slew"]), 90.0, 1e-6, "railgun slews 90°/s")
	near(float(MechCatalog.weapon("rockets")["slew"]), 120.0, 1e-6, "rocket pod 120°/s")
	near(float(MechCatalog.weapon("missiles")["slew"]), 120.0, 1e-6, "missile pod 120°/s")
	near(float(MechCatalog.weapon("autocannon").get("slew", Combat.PIVOT_SLEW)), 180.0, 1e-6, "autocannon 180°/s")
	eq(Combat.pivot_limits(MechCatalog.weapon("autocannon")), Vector3(30, 50, 45), "pivot range ±30° yaw, -50..+45° pitch")
	eq(Vector3(Combat.FIXED_ARC_YAW, Combat.FIXED_ARC_PITCH_DOWN, Combat.FIXED_ARC_PITCH_UP), Vector3(30, 50, 45),
		"the fixed arc is the pivot range")


## Aim 10 m ahead, 6 m below the pivot: barrel at -atan(6/10), the next shot from the turned muzzle through the aim point.
func _settles_down() -> void:
	var want_pitch := -rad_to_deg(atan2(6.0, 10.0))
	for kind: String in PIVOTS:
		var pivot: Vector3 = PIVOTS[kind]
		var aim := pivot + Vector3(0, -6, -10)
		for id: String in DIRECT:
			var m := _mount(id, "shoulder_r" if kind == "shoulder" else "side_r")
			var body := _body()
			# Start from straight ahead (a barrel already on the level), then aim low: it slews down and settles.
			_drive(m, 0.2, 1.0 / 60.0, false, pivot + Vector3(0, 0, -40), pivot, body)
			near(m.aim_pitch, 0.0, 1e-3, "%s %s starts level" % [id, kind])
			var recs := _drive(m, 4.0, 1.0 / 60.0, true, aim, pivot, body, 0.2)
			near(m.aim_pitch, want_pitch, 1e-3, "%s %s: settled pitched down %.1f° (%.3f)" % [id, kind, want_pitch, m.aim_pitch])
			near(m.aim_yaw, 0.0, 1e-3, "  ... no yaw")
			check(m.on_target(), "  ... on target")
			if not check(recs.size() > 0, "  ... fired (%d)" % recs.size()):
				continue
			var r: Dictionary = recs[recs.size() - 1]
			var dir: Vector3 = r["dir"]
			var muz := pivot + m.aim_dir * float(MechCatalog.weapon(id)["muzzle"]) * SCALE
			check((r["origin"] as Vector3).distance_to(muz) < 1e-4, "  ... the shot leaves the turned muzzle (%.4f m)" % (r["origin"] as Vector3).distance_to(muz))
			check(dir.is_equal_approx(m.aim_dir), "  ... along the barrel")
			check(_miss(r["origin"], dir, aim) < 0.01, "  ... straight through the aim point (miss %.4f m)" % _miss(r["origin"], dir, aim))
			check(m.barrel_muzzle().distance_to(muz) < 1e-4, "  ... barrel_muzzle() agrees")


func _slew() -> void:
	for id: String in ["autocannon", "railgun", "gatling"]:
		var slew := float(MechCatalog.weapon(id)["slew"])
		for dt: float in STEPS:
			var pivot: Vector3 = PIVOTS["side"]
			var body := _body()
			var m := _mount(id)
			var a0 := pivot + Combat.arc_dir(body, Vector2(-10.0, 0.0)) * 60.0
			var a1 := pivot + Combat.arc_dir(body, Vector2(20.0, 0.0)) * 60.0
			_drive(m, 0.5, dt, false, a0, pivot, body)
			near(m.aim_yaw, -10.0, 1e-3, "%s settles at -10° first" % id)
			var t0 := float(int(ceil(0.5 / dt - 1e-9))) * dt      # the clock after the settle
			var reached := -1.0
			var n := int(ceil(1.0 / dt))
			for i in n:
				var now := t0 + float(i + 1) * dt
				m.update(dt, false, null, now, _rest(id, pivot, body), a1)
				if reached < 0.0 and m.aim_yaw >= 20.0 - 1e-6:
					reached = now - t0
			near(reached, 30.0 / slew, dt + 1e-6, "%s: a 30° step takes ~%.3f s (%.3f, dt %.4f)" % [id, 30.0 / slew, reached, dt])
	# Rounds fired meanwhile leave along intermediate directions (the gatling, spun up, slew 180°/s, 12 rounds/s).
	for dt: float in STEPS:
		var pivot: Vector3 = PIVOTS["side"]
		var body := _body()
		var m := _mount("gatling")
		var st := MechCatalog.weapon("gatling").duplicate()
		st["spread"] = 0.0
		st["spread_max"] = 0.0
		m.stats = st
		var a0 := pivot + Combat.arc_dir(body, Vector2(-15.0, 0.0)) * 60.0
		var a1 := pivot + Combat.arc_dir(body, Vector2(15.0, 0.0)) * 60.0
		_drive(m, 1.2, dt, true, a0, pivot, body)
		var t0 := float(int(ceil(1.2 / dt - 1e-9))) * dt
		var recs := _drive(m, 1.0, dt, true, a1, pivot, body, t0)
		var mid := 0
		var ok := true
		for r in recs:
			var y := Combat.arc_angles(body, r["dir"]).x
			var want := clampf(-15.0 + 180.0 * (float(r["t"]) - t0), -15.0, 15.0)
			ok = ok and absf(y - want) < 0.02
			if y > -13.0 and y < 13.0:
				mid += 1
		check(ok, "each round leaves along the barrel at its time (180°/s from the step, dt %.4f)" % dt)
		check(mid >= 1, "rounds fired while slewing leave along intermediate directions (%d, dt %.4f)" % [mid, dt])


func _limits() -> void:
	var pivot: Vector3 = PIVOTS["side"]
	var body := _body()
	var aim := pivot + Combat.arc_dir(body, Vector2(80.0, 0.0)) * 50.0
	Combat.FIXED_ARC_ENABLED = false
	var m := _mount("autocannon")
	var recs := _drive(m, 2.0, 1.0 / 60.0, true, aim, pivot, body)
	near(m.aim_yaw, 30.0, 1e-3, "80° to the side: the barrel parks at +30° (%.3f)" % m.aim_yaw)
	check(not m.on_target(), "  ... not on target")
	check(recs.size() > 2, "  ... arc switch off: it still fires (%d)" % recs.size())
	eq(m.hold_reason, "", "  ... no hold")
	if recs.size() > 0:
		near(Combat.arc_angles(body, recs[recs.size() - 1]["dir"]).x, 30.0, 1e-3, "  ... along the parked barrel")
	var ml := _mount("autocannon")
	_drive(ml, 2.0, 1.0 / 60.0, false, pivot + Combat.arc_dir(body, Vector2(-80.0, 0.0)) * 50.0, pivot, body)
	near(ml.aim_yaw, -30.0, 1e-3, "-80°: parks at -30°")
	var mp := _mount("autocannon")
	_drive(mp, 2.0, 1.0 / 60.0, false, pivot + Vector3(0, -40, -10), pivot, body)
	near(mp.aim_pitch, -50.0, 1e-3, "steeply down: parks at -50° pitch")
	var mu := _mount("autocannon")
	_drive(mu, 2.0, 1.0 / 60.0, false, pivot + Vector3(0, 40, -10), pivot, body)
	near(mu.aim_pitch, 45.0, 1e-3, "steeply up: parks at +45° pitch")
	Combat.FIXED_ARC_ENABLED = true
	var m2 := _mount("autocannon")
	eq(_drive(m2, 2.0, 1.0 / 60.0, true, aim, pivot, body).size(), 0, "arc switch on: holds 80° off")
	eq(m2.hold_reason, Combat.OUT_OF_ARC, "  ... OUT OF ARC")
	near(m2.aim_yaw, 30.0, 1e-3, "  ... the barrel still parks at its limit")
	var inside := pivot + Combat.arc_dir(body, Vector2(25.0, -30.0)) * 50.0
	check(_drive(m2, 1.0, 1.0 / 60.0, true, inside, pivot, body, 2.0).size() > 0, "  ... fires inside the range (25°, -30°)")
	eq(m2.hold_reason, "", "  ... the hold clears")
	var mm := _mount("missiles", "shoulder_r")
	check(_drive(mm, 2.0, 1.0 / 60.0, true, aim, pivot, body).size() > 0, "  ... guided missiles stay exempt from the hold")
	Combat.FIXED_ARC_ENABLED = false


func _mortar() -> void:
	var pivot := Vector3(0, 5, 1)
	var body := _body()
	var m := _mount("mortar", "back")
	var aim := pivot + Vector3(40, -5, -80)
	var recs := _drive(m, 1.0, 1.0 / 60.0, true, aim, pivot, body)
	eq(m.aim_dir, Vector3.ZERO, "mortar: no barrel tracking")
	check(m.on_target(), "  ... on_target always (it lobs to the aim point)")
	if check(recs.size() == 1, "  ... fires one shell"):
		check((recs[0]["origin"] as Vector3).is_equal_approx(_rest("mortar", pivot, body)), "  ... from the fixed muzzle")
		check((recs[0]["target"] as Vector3).is_equal_approx(aim), "  ... lobbed to the aim point")


func _swivel() -> void:
	var pivot: Vector3 = PIVOTS["side"]
	var body := _body()
	var m := _mount("swivel")
	var recs := _drive(m, 1.5, 1.0 / 60.0, true, pivot + Combat.arc_dir(body, Vector2(100.0, 0.0)) * 50.0, pivot, body)
	near(m.aim_yaw, 100.0, 1e-3, "swivel: still swings to 100° (its own ±120°)")
	check(recs.size() >= 3, "  ... and fires there")
	check(m.on_target(), "  ... on target")


func _rotated_body() -> void:
	var pivot: Vector3 = PIVOTS["shoulder"]
	var body := _body(90.0)       # faces world -X
	var m := _mount("autocannon", "shoulder_r")
	_drive(m, 1.0, 1.0 / 60.0, false, pivot + Vector3(-50, 0, 0), pivot, body)
	near(m.aim_yaw, 0.0, 1e-3, "turned body: world -X is straight ahead of it")
	_drive(m, 2.0, 1.0 / 60.0, false, pivot + Vector3(0, 0, -50), pivot, body, 1.0)   # world -Z = 90° right of it
	near(m.aim_yaw, 30.0, 1e-3, "  ... world -Z is 90° to its right: parks at +30° in the body's frame")
	check(m.aim_dir.is_equal_approx(Combat.arc_dir(body, Vector2(30, 0))), "  ... the range turned with the body")


## Determinism. (a) Same inputs, same records at every frame step: a settled barrel on a low, off-axis aim point, the
## trigger held (the clock is each step's start, as the other weapon tests drive it, so a fresh press fires at 0 at any
## step; charge weapons count their charge from the step start, so they get the end-of-step clock). (b) A barrel pre-set to -30° slewing at 60°/s to +30° from clock 0 (end-of-step clock): every round, at any
## frame step, leaves along the barrel's direction at that round's exact time.
func _determinism() -> void:
	for id: String in ["gatling", "laser", "autocannon", "rockets", "railgun", "flamer"]:
		var base: Array[Dictionary] = []
		for dt: float in STEPS:
			var pivot: Vector3 = PIVOTS["shoulder"]
			var body := _body()
			var m := _mount(id, "shoulder_r")
			var aim := pivot + Combat.arc_dir(body, Vector2(12.0, -25.0)) * 30.0
			m.set_body_basis(body)
			var t0 := 0.0 if m.stats.has("charge") else -dt     # charge weapons count from the step start (end-of-step clock)
			var recs := _drive(m, 4.0, dt, true, aim, pivot, body, t0)
			if base.is_empty():
				base = recs
				check(base.size() >= 1, "%s fires (%d)" % [id, base.size()])
				continue
			var n := 0
			var t_err := 0.0
			var dir_err := 0.0
			var org_err := 0.0
			for i in mini(recs.size(), base.size()):
				if float(base[i]["t"]) > 3.8:
					break
				n += 1
				t_err = maxf(t_err, absf(float(recs[i]["t"]) - float(base[i]["t"])))
				dir_err = maxf(dir_err, (recs[i]["dir"] as Vector3).distance_to(base[i]["dir"]))
				org_err = maxf(org_err, (recs[i]["origin"] as Vector3).distance_to(base[i]["origin"]))
			check(t_err < 1e-5 and dir_err < 1e-4 and org_err < 1e-4 and n >= 1,
				"%s: same records at dt %.4f (%d compared; t %.6f, dir %.6f, origin %.6f)" % [id, dt, n, t_err, dir_err, org_err])
	for id: String in ["autocannon", "laser", "railgun"]:
		for dt: float in STEPS:
			var pivot: Vector3 = PIVOTS["side"]
			var body := _body()
			var m := _mount(id)
			var st := MechCatalog.weapon(id).duplicate()
			st["slew"] = 60.0
			st["spread"] = 0.0
			st["rate"] = 4.0 if id == "autocannon" else float(st["rate"])
			m.stats = st
			m.set_body_basis(body)
			m.aim_yaw = -30.0
			m.aim_dir = Combat.arc_dir(body, Vector2(-30.0, 0.0))
			var recs := _drive(m, 1.2, dt, true, pivot + Combat.arc_dir(body, Vector2(30.0, 0.0)) * 60.0, pivot, body)
			var worst := 0.0
			for r in recs:
				var want := clampf(-30.0 + 60.0 * float(r["t"]), -30.0, 30.0)
				worst = maxf(worst, absf(Combat.arc_angles(body, r["dir"]).x - want))
			check(recs.size() >= 1 and worst < 0.01,
				"%s: rounds during a slew leave along the barrel at their time (dt %.4f, %d rounds, worst %.4f°)" % [id, dt, recs.size(), worst])


## WeaponPose.apply puts a marker at (0, 0, -muzzle) of the turned model within 2 cm of the gameplay muzzle
## (WeaponPose.muzzle): every hardpoint of a scaled, turned mech, plus a mirrored hardpoint parent and a mirrored model.
func _pose_marker() -> void:
	var model := MechModel.new()
	model.scale = Vector3.ONE * 2.0
	model.rotation.y = deg_to_rad(35.0)
	add_child(model)
	var loadout := {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "railgun", "back": ""}
	model.configure("chicken", "strider", loadout)
	await frames(1)
	var cases := [Vector2(0, 0), Vector2(20, -35), Vector2(-30, 15), Vector2(10, -50), Vector2(-25, 45)]
	for hp_id: String in loadout:
		var w := str(loadout[hp_id])
		if w == "":
			continue
		var hp := model.find_child("HP_" + hp_id, true, false) as Node3D
		if not check(hp != null and WeaponPose.node_of(hp, w) != null, "%s has its Weapon_%s node" % [hp_id, w]):
			continue
		_marker_cases(hp, w, cases, hp_id)
	# A mirrored hardpoint parent (scale -X) and a mirrored model under it.
	var root := Node3D.new()
	root.scale = Vector3(-2.0, 2.0, 2.0)
	root.position = Vector3(3, 1, -2)
	add_child(root)
	var hp2 := Node3D.new()
	hp2.position = Vector3(0.5, 0.8, 0.1)
	root.add_child(hp2)
	var gun := MechParts.weapon("autocannon")
	gun.scale = Vector3(-1, 1, 1)
	hp2.add_child(gun)
	await frames(1)
	_marker_cases(hp2, "autocannon", cases, "mirrored")
	var g := WeaponPose.node_of(hp2, "autocannon")
	WeaponPose.reset(hp2, "autocannon")
	check(g.basis.is_equal_approx(Basis.from_scale(Vector3(-1, 1, 1))), "reset puts the mirrored rest basis back")
	root.queue_free()
	model.queue_free()
	await frames(1)


func _marker_cases(hp: Node3D, w: String, cases: Array, tag: String) -> void:
	var length := float(MechCatalog.weapon(w)["muzzle"])
	var node := WeaponPose.node_of(hp, w)
	var marker := Node3D.new()
	marker.position = Vector3(0, 0, -length)
	node.add_child(marker)
	var worst := 0.0
	for c: Vector2 in cases:
		WeaponPose.apply(hp, w, c.x, c.y)
		worst = maxf(worst, marker.global_position.distance_to(WeaponPose.muzzle(hp, c.x, c.y, length)))
	check(worst < 0.02, "%s: the model's muzzle sits on the gameplay muzzle at every yaw / pitch (worst %.4f m)" % [tag, worst])
	marker.queue_free()


## In a rack: shots leave the model's muzzle, slots() has on_target and it flips while slewing / parked.
func _rack() -> void:
	var world := CombatWorld.new()
	world.use_physics = false
	add_child(world)
	var model := MechModel.new()
	model.scale = Vector3.ONE * 2.0
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets",
		"shoulder_r": "", "back": "mortar"})
	var mech := MechController.new()
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "racker", 1)
	await frames(2)
	var hp := model.find_child("HP_side_r", true, false) as Node3D
	var at := hp.global_position
	rack.aim_point = at + Vector3(0, -6, -10)          # close and low
	rack.set_trigger(true)
	for i in 60:
		rack.step(1.0 / 60.0)
		world.advance(1.0 / 60.0)
	rack.set_trigger(false)
	var sl := rack.slots()
	check(sl[0].has("on_target"), "slots() has on_target")
	check(bool(sl[1]["on_target"]), "the autocannon settled on the close low aim point")
	check(bool(sl[4]["on_target"]), "the mortar is always on target")
	eq(bool(sl[3]["on_target"]), false, "an empty slot isn't")
	var m: WeaponMount = rack.mounts[1]
	near(m.aim_pitch, -rad_to_deg(atan2(6.0, 10.0 + 0.0)), 1.5, "the autocannon pitched down to it (%.2f°)" % m.aim_pitch)
	var gun := WeaponPose.node_of(hp, "autocannon")
	var looks := -gun.global_basis.z.normalized()
	check(looks.dot(m.aim_dir) > 0.9999, "the Weapon_autocannon model points along the barrel (dot %.5f)" % looks.dot(m.aim_dir))
	var marker := gun.global_transform * Vector3(0, 0, -float(MechCatalog.weapon("autocannon")["muzzle"]))
	check(marker.distance_to(rack.muzzle(2)) < 0.02, "rack.muzzle(2) is the model's muzzle (%.4f m)" % marker.distance_to(rack.muzzle(2)))
	check((sl[1]["muzzle"] as Vector3).distance_to(marker) < 0.02, "slots() muzzle too")
	var live := world.muzzle_of({"shooter": "racker", "hardpoint": "side_r"})
	check(live.is_valid() and (live.call() as Vector3).distance_to(marker) < 0.02, "the live muzzle (beam, flame, laser line) too")
	var ml := rack.mounts[0] as WeaponMount
	var lhp := model.find_child("HP_side_l", true, false) as Node3D
	var lmarker := WeaponPose.node_of(lhp, "laser").global_transform * Vector3(0, 0, -float(MechCatalog.weapon("laser")["muzzle"]))
	check(lmarker.distance_to(rack.muzzle(1)) < 0.02, "left side: rack.muzzle(1) is the model's muzzle (%.4f m)" % lmarker.distance_to(rack.muzzle(1)))
	check(ml.aim_pitch < -20.0, "the left laser pitched down too (%.1f°)" % ml.aim_pitch)
	# A 25° turn: off target for a few steps, then on again.
	rack.aim_point = at + Combat.arc_dir(hp.global_basis, Vector2(25.0, 0.0)) * 40.0
	rack.step(1.0 / 60.0)
	check(not bool(rack.slots()[1]["on_target"]), "on_target flips off while the barrel slews")
	for i in 30:
		rack.step(1.0 / 60.0)
	check(bool(rack.slots()[1]["on_target"]), "  ... and back on once it settles")
	rack.aim_point = at + Combat.arc_dir(hp.global_basis, Vector2(80.0, 0.0)) * 40.0
	for i in 60:
		rack.step(1.0 / 60.0)
	check(not bool(rack.slots()[1]["on_target"]), "  ... off while parked at its limit")
	near(m.aim_yaw, 30.0, 1e-3, "  ... parked at 30°")
	rack.queue_free()
	model.queue_free()
	world.queue_free()
	mech.free()
	await frames(1)


## The weapon_range lab: a shoulder autocannon aimed at the ground 10 m out pitches down and fires along its barrel.
func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	var aims: Array = []
	for o: Dictionary in lab.lab_options():
		if str(o["id"]) == "aim":
			aims = o["choices"]
	check(WeaponRangeLab.GROUND_AIM in aims, "the lab offers the close ground aim point")
	lab.set_lab_option("weapon", "autocannon")
	lab.set_lab_option("hardpoint", "shoulder_r")
	lab.set_lab_option("aim", WeaponRangeLab.GROUND_AIM)
	lab.set_lab_option("fire", "hold")
	for i in 60:
		await frames(1)
	check(lab.mount.aim_pitch < -15.0, "aiming at the ground close ahead pitches the shoulder gun down (%.1f°)" % lab.mount.aim_pitch)
	check(lab.mount.on_target(), "  ... onto the aim point")
	check(lab.mount.shot_index >= 2, "  ... and it fires (%d)" % lab.mount.shot_index)
	var hp := lab.mech.find_child("HP_shoulder_r", true, false) as Node3D
	var gun := WeaponPose.node_of(hp, "autocannon")
	var looks := -gun.global_basis.z.normalized()
	check(looks.dot(Vector3.DOWN) > 0.25, "  ... the model visibly points down (%.2f)" % looks.dot(Vector3.DOWN))
	var marker := gun.global_transform * Vector3(0, 0, -float(MechCatalog.weapon("autocannon")["muzzle"]))
	check(marker.distance_to(lab.muzzle()) < 0.02, "  ... lab.muzzle() is the model's muzzle (%.4f m)" % marker.distance_to(lab.muzzle()))
	lab.queue_free()
	await frames(1)
