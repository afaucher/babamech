extends TestCase
## Persistent enemy destruction, pop-off ballistic debris, socket/wreck flames, LRU pooling, clean teardown,
## and curved RingFrame scorch + ember + rubble alignment.

const DT := 1.0 / 60.0


func setup() -> void:
	await _tank_turret_break_and_settle()
	await _strider_leg_break_socket_flame()
	await _all_classes_persistent_wrecks()
	await _lru_caps_and_teardown()
	await _curved_ring_scorch_and_debris()
	finish()


func _world(physics: bool = false, ring: RingFrame = null) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 101
	w.use_physics = physics
	w.ring = ring
	add_child(w)
	return w


func _make_floor(y: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120.0, 1.0, 120.0)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0.0, y - 0.5, 0.0)
	add_child(body)
	return body


func _tank_turret_break_and_settle() -> void:
	var floor_b := _make_floor(0.0)
	var w := _world(true)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var tk := EnemyTank.new()
	tk.configure("tank", "tank_pop", w, sq, null, 7)
	tk.ai_mode = "idle"
	sq.add_enemy(tk)
	await frames(2)

	# Break the tank's turret with a directional hit (non-fatal: tank stays alive, turret tosses!).
	var h := Hit.new()
	h.damage = float(tk.max_hp["turret"]) + 5.0
	h.component = "turret"
	h.impulse = Vector3(4.0, 0.0, -8.0)
	h.shooter = "player1"
	tk.apply_hit(h)

	check(not tk.destroyed(), "breaking tank turret leaves the hull alive")
	check(tk.wreck.has_active_flame(), "living tank has live LowPolyFlame.Stream shooting from ruptured turret ring")
	var df := sq.get_debris_field()
	var turrets := df.find_by_part("tank_turret")
	eq(turrets.size(), 1, "breaking tank turret pops 1 persistent tank_turret debris chunk")
	if turrets.size() == 1:
		var tur := turrets[0]
		check(not tur.settled and tur.velocity.y > 8.0, "popped tank_turret launches high upward (vy=%.2f)" % tur.velocity.y)
		var peak_y := tur.global_position.y
		var saw_bounce := false
		for _i in 300:
			w.advance(DT)
			peak_y = maxf(peak_y, tur.global_position.y)
			if tur.bounces > 0:
				saw_bounce = true
		check(peak_y > 6.5, "tossed tank_turret reaches dramatic peak height (%.2f m)" % peak_y)
		check(saw_bounce, "popped tank_turret bounces on the ground before settling")
		check(tur.settled, "popped tank_turret settles cleanly to rest (settled == true)")
		eq(df.active_count(), 0, "all settled debris chunks stop ticking (0 active -> 0.00 ms CPU)")
		check(tur.global_position.y >= 0.0 and tur.global_position.y <= tur.rest_radius + 0.35,
			"settled tank_turret rests cleanly on ground (y=%.2f, r=%.2f)" % [tur.global_position.y, tur.rest_radius])
		check(tk.wreck.has_active_flame(), "living tank turret-ring flame keeps burning while tank is alive")

	sq.queue_free()
	w.queue_free()
	floor_b.queue_free()
	await frames(1)


func _strider_leg_break_socket_flame() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var st := EnemyStrider.new()
	st.configure("strider", "strider_cripple", w, sq, null, 3)
	st.ai_mode = "idle"
	sq.add_enemy(st)
	await frames(1)

	st.apply_damage(float(st.max_hp["legs"]) + 5.0, "legs", "player1")
	check(not st.destroyed(), "crippling strider legs leaves it alive")
	check(st.wreck.has_active_flame(), "crippled strider attaches a live socket flame jet")
	check(sq.get_debris_field().total_count() >= 2, "crippling strider legs pops off armor debris chunks")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _all_classes_persistent_wrecks() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	var specs := [
		["turret", "gun", "turret_gun", Vector3(-12.0, 0.0, 0.0)],
		["strider", "sensor", "strider_leg", Vector3(0.0, 0.0, 0.0)],
		["tank", "vents", "tank_turret", Vector3(14.0, 0.0, 0.0)],
	]
	var enemies: Array[EnemyBase] = []
	for sp: Array in specs:
		var e := EnemySpawner.make_enemy(str(sp[0]))
		e.configure(str(sp[0]), "w_%s" % str(sp[0]), w, sq, null, 11)
		e.ai_mode = "idle"
		e.auto_remove_wreck = false
		e.position = sp[3] as Vector3
		sq.add_enemy(e)
		enemies.append(e)
	await frames(1)

	for i in specs.size():
		var e := enemies[i]
		var wp := str(specs[i][1])
		var expected_part := str(specs[i][2])
		e.apply_damage(200.0, wp, "player1")
		check(e.destroyed(), "%s killed cleanly" % e.enemy_type)
		check(not e.is_hittable(), "%s wreck is non-hittable (shots fly cleanly past)" % e.enemy_type)
		check(e.has_charred_hulk(), "%s keeps its persistent charred hulk visible" % e.enemy_type)
		check(e.wreck.has_active_flame(), "%s wreck shoots active LowPolyFlame.Stream jet" % e.enemy_type)
		check(sq.get_debris_field().find_by_part(expected_part).size() >= 1,
			"%s kill pops persistent %s debris piece" % [e.enemy_type, expected_part])

	eq(sq.wreck_count(), 3, "squad tracks all 3 persistent wrecks")

	# Verify shots fly cleanly past downed wrecks (first_hit ignores non-hittable wrecks).
	var h := w.first_hit(Vector3(14.0, 2.5, 15.0), Vector3(14.0, 2.5, -15.0), 0.5, "player1")
	check(h.is_empty(), "shots pass cleanly through persistent downed wrecks")

	# Advance past flame + smoke lifetime (~16 s) and verify wrecks remain persistent yet fully cooled (0 ms tick).
	for _i in 320:
		w.advance(0.05)
	for e in enemies:
		check(is_instance_valid(e) and e.has_charred_hulk(), "%s charred hulk persists after flames cool" % e.enemy_type)
		check(not e.wreck.has_active_flame(), "%s wreck flame tapered and extinguished cleanly" % e.enemy_type)
		check(e._wreck_cooled, "%s wreck reached cooled idle state (0 ms CPU)" % e.enemy_type)
	eq(sq.get_debris_field().active_count(), 0, "all kill debris settled to 0 active CPU")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _lru_caps_and_teardown() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	# Kill 14 tanks -> > MAX_WRECKS (10) and > MAX_DEBRIS (28) chunks!
	for i in 14:
		var tk := EnemyTank.new()
		tk.configure("tank", "lru_tk_%d" % i, w, sq, null, 100 + i)
		tk.ai_mode = "idle"
		tk.position = Vector3(float(i) * 12.0, 0.0, 0.0)
		sq.add_enemy(tk)
		tk.apply_damage(200.0, "vents", "player1")
	await frames(2)

	check(sq.wreck_count() <= EnemySquad.MAX_WRECKS,
		"wreck LRU cap enforced (%d <= %d)" % [sq.wreck_count(), EnemySquad.MAX_WRECKS])
	var df := sq.get_debris_field()
	check(df.total_count() <= EnemyDebrisField.MAX_DEBRIS,
		"debris LRU cap enforced (%d <= %d)" % [df.total_count(), EnemyDebrisField.MAX_DEBRIS])
	check(df.total_count() == EnemyDebrisField.MAX_DEBRIS,
		"debris pool filled up to cap (%d)" % df.total_count())

	# Clean teardown on clear_enemies() (e.g., pressing N for new city).
	sq.clear_enemies()
	await frames(2)
	eq(sq.enemies.size(), 0, "clear_enemies() empties enemy list")
	eq(sq.wreck_count(), 0, "clear_enemies() clears all persistent wrecks")
	eq(df.total_count(), 0, "clear_enemies() frees all popped-off debris chunks")
	eq(df.active_count(), 0, "clear_enemies() resets active debris list")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _curved_ring_scorch_and_debris() -> void:
	var ring := RingFrame.new(120.0)
	var w := _world(false, ring)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, null, ring)

	# Far along the curved ring (s = 65 m -> ~31 deg tilt away from world +Y!).
	var street_pt := ring.arc_to_world(0.0, 65.0, 0.0)
	var local_up := ring.up_at(street_pt)
	check(local_up.dot(Vector3.UP) < 0.90, "test point on curved RingFrame has significant deck tilt (dot=%.3f)" % local_up.dot(Vector3.UP))

	var fx := w.spawn_impact(street_pt + local_up * 0.4, local_up, 4.5, EnemyMeshes.CHARRED, true)
	await frames(1)
	if check(fx != null, "curved-deck ImpactFx spawned"):
		var sn := fx.scorch_normal()
		check(sn.dot(local_up) > 0.995, "curved-deck scorch aligns flush to local radial up (dot=%.4f)" % sn.dot(local_up))
		check(sn.dot(Vector3.UP) < 0.90, "curved-deck scorch is NOT hardcoded to flat world +Y (dot=%.3f)" % sn.dot(Vector3.UP))
		check(fx.visible_parts("scorch") == 1, "outer dark faceted scorch visible")
		check(fx.visible_parts("ember") == 1, "inner glowing ember polygon visible at impact")
		var pebs := fx.visible_parts("pebble")
		check(pebs >= 3 and pebs <= 5, "3-5 perimeter faceted rubble pebbles spawned (%d)" % pebs)
		# Advance past EMBER_LIFE (2.5 s) -> ember cools away while scorch & pebbles stay.
		w.advance(ImpactFx.EMBER_LIFE + 0.15)
		eq(fx.visible_parts("ember"), 0, "inner glowing ember cools and vanishes after 2.5 s")
		eq(fx.visible_parts("scorch"), 1, "outer char polygon stays after ember cools")

	# Also verify EnemyDebris settles radially onto the curved RingFrame floor at s = 65 m.
	var df := sq.get_debris_field()
	var d := df.spawn_chunk("debris_plate", Transform3D(ring.basis_at_arc(65.0), street_pt + local_up * 3.0),
		local_up * 7.0 + Vector3(2.0, 0.0, 0.0), Vector3(3.0, 2.0, 1.0))
	for _i in 240:
		w.advance(DT)
	check(d.settled, "curved-deck debris piece settles on RingFrame")
	var settled_h := ring.height(d.global_position)
	check(settled_h >= -0.05 and settled_h <= d.rest_radius + 0.25,
		"curved-deck debris rests flush at ring height (h=%.2f, r=%.2f)" % [settled_h, d.rest_radius])

	sq.queue_free()
	w.queue_free()
	await frames(1)
