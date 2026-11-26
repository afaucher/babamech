extends TestCase
## Enemy Anti-Air verification (docs/design/wasp-ai.md §1):
##   1. 3D velocity lead on direct-fire weapons (damped vertical 0.65x), floor-plane lead on arc mortar.
##   2. Per-chassis upper pitch caps (Tank 32 deg, Strider 52 deg, Turret 62 deg, Trooper 70 deg) block primary fire
##      inside the overhead dead zone, and mobile ground units (Tank) back away to bring an overhead flier into arc.
##   3. Mortar skips airborne targets hovering high above the deck (no wasted ground-arc shells).
##   4. Trooper skips ground-rush panic scatter when a flying mech hovers > 8 m overhead.
##   5. Gunship climbs via EnemyFlier._air_match_target_alt to duel a hovering target at altitude.

const DT := 1.0 / 60.0


func setup() -> void:
	await _test_3d_velocity_lead()
	await _test_pitch_limits_and_overhead_backoff()
	await _test_mortar_skips_airborne_target()
	await _test_trooper_ignores_overhead_rush_panic()
	await _test_gunship_altitude_matching()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = false
	add_child(w)
	return w


func _airborne_player(w: CombatWorld, pos: Vector3, tid: String = "wasp_p1") -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = tid
	p.team = "player"
	p.mass_class = "static"
	p.set_max_hp({"torso": 400.0})
	p.add_hit_sphere("torso", Vector3.ZERO, 2.0)
	p.position = pos
	add_child(p)
	w.register(p)
	return p


func _test_3d_velocity_lead() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var t := EnemyTurret.new()
	t.configure("turret", "aa_lead_turret", w, sq, null, 1)
	t.position = Vector3.ZERO
	sq.add_enemy(t)
	await frames(1)

	t._has_los = true
	t._target_vel = Vector3(8.0, 12.0, 0.0)   # climbing + strafing flier
	var base_pos := Vector3(0.0, 16.0, -50.0)
	var lead_direct := t._lead_aim_point("enemy_bolter", base_pos, 0.4)
	check(lead_direct.y > base_pos.y + 1.0,
		"direct-fire 3D lead elevates aim for climbing flier (y=%.2f vs base=%.2f)" % [lead_direct.y, base_pos.y])
	check(lead_direct.x > base_pos.x + 1.0,
		"direct-fire 3D lead keeps horizontal lead (x=%.2f)" % lead_direct.x)

	var lead_arc := t._lead_aim_point("enemy_mortar", base_pos, 0.4)
	near(lead_arc.y, base_pos.y, 0.01, "arc mortar keeps floor-plane lead (no vertical extrapolation)")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _test_pitch_limits_and_overhead_backoff() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)

	# Tank (max pitch 32 deg) with a flier hovering steeply overhead at 24 m altitude, 14 m horizontal (~55 deg elev).
	var tank := EnemyTank.new()
	tank.configure("tank", "aa_tank", w, sq, null, 2)
	tank.position = Vector3(0.0, 0.0, 0.0)
	sq.add_enemy(tank)

	# Turret (max pitch 62 deg) with a flier at 50 deg (allowed) vs 75 deg (blocked).
	var tur := EnemyTurret.new()
	tur.configure("turret", "aa_turret", w, sq, null, 3)
	tur.position = Vector3(80.0, 0.0, 0.0)
	sq.add_enemy(tur)

	var flier := _airborne_player(w, Vector3(0.0, 24.0, -14.0), "wasp_high")
	await frames(1)

	tank._has_los = true
	eq(tank._choose_weapon(flier.global_position), "",
		"tank refuses primary cannon shot inside >32 deg overhead dead zone")
	tur._has_los = true
	check(tur._choose_weapon(Vector3(80.0, 24.0, -18.0)) != "",
		"turret (62 deg cap) can engage a flier at ~48 deg elevation")
	eq(tur._choose_weapon(Vector3(80.0, 30.0, -4.0)), "",
		"turret refuses shot inside >62 deg overhead dead zone")

	# Step tank in engage mode (4.0 s so heavy tank completes its 180 deg U-turn at 1.2 rad/s and opens range!).
	tank.ai_state = EnemyBase.STATE_ENGAGE
	var start_horiz := Vector2(tank.global_position.x - flier.global_position.x,
		tank.global_position.z - flier.global_position.z).length()
	for _i in 240:
		w.advance(DT)
	var end_horiz := Vector2(tank.global_position.x - flier.global_position.x,
		tank.global_position.z - flier.global_position.z).length()
	check(end_horiz > start_horiz + 4.0,
		"tank backs away from overhead flier to open firing arc (horiz %.1f -> %.1f m)" % [start_horiz, end_horiz])

	flier.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _test_mortar_skips_airborne_target() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var tank := EnemyTank.new()
	tank.configure("tank", "aa_mortar_tank", w, sq, null, 4)
	tank.position = Vector3.ZERO
	sq.add_enemy(tank)
	await frames(1)

	tank._has_los = false
	tank._no_los_time = 5.0
	eq(tank._choose_weapon(Vector3(0.0, 18.0, -70.0)), "",
		"tank skips enemy_mortar against a target hovering 18 m in midair")
	eq(tank._choose_weapon(Vector3(0.0, 3.0, -70.0)), "enemy_mortar",
		"tank still fires enemy_mortar against a grounded target with no LOS")

	sq.queue_free()
	w.queue_free()
	await frames(1)


func _test_trooper_ignores_overhead_rush_panic() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var tr := EnemyTrooper.new()
	tr.configure("trooper_rifle", "aa_trooper", w, sq, null, 5)
	tr.position = Vector3.ZERO
	sq.add_enemy(tr)
	var flier := _airborne_player(w, Vector3(0.0, 15.0, -10.0), "wasp_overhead")
	await frames(1)

	tr.ai_state = EnemyBase.STATE_ENGAGE
	tr._has_los = true
	tr._scatter_cd = 0.0
	tr._step_trooper_movement(DT, flier.global_position, null)
	check(not tr._displacing and not tr._jump_active and tr._scatter_cd <= 0.0,
		"trooper does NOT trigger ground-rush scatter when flier hovers 15 m overhead")

	flier.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _test_gunship_altitude_matching() -> void:
	var w := _world()
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var gs := EnemyGunship.new()
	gs.configure("gunship", "aa_gunship", w, sq, null, 6)
	gs.position = Vector3(0.0, EnemyGunship.ALT_ATTACK_LOW, 0.0)
	sq.add_enemy(gs)
	var flier := _airborne_player(w, Vector3(0.0, 22.0, -48.0), "wasp_duel")
	await frames(1)

	var matched := gs._air_match_target_alt(flier.global_position, EnemyGunship.ALT_ATTACK_LOW, 2.5)
	near(matched, 24.5, 0.01, "EnemyFlier._air_match_target_alt raises Gunship target altitude to 24.5 m for a 22 m flier")

	gs.ai_state = EnemyBase.STATE_ENGAGE
	gs._has_los = true
	var start_y := gs.global_position.y
	for _i in 120:
		w.advance(DT)
	check(gs.global_position.y > start_y + 6.0,
		"Gunship climbs to duel hovering Wasp at altitude (y %.1f -> %.1f m)" % [start_y, gs.global_position.y])

	flier.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)
