extends TestCase
## Enemy combat mechanics (docs/design/enemies.md §3–4): catalog schema, component weak points & critical kills,
## splash core-targeting & same-team skip, turret aim-kick, skirmisher stagger + wall-slam + roof-drop fall,
## tank turret break & vents meltdown, overheat shutdown, impact_spawned Audio hook, and PlayerTarget + WeaponRack
## destroyed-slot integration.

const DT := 1.0 / 60.0


func setup() -> void:
	_catalog_and_meshes()
	await _turret_combat()
	await _strider_combat_and_roof_fall()
	await _tank_combat_and_vents()
	await _team_skip_and_impact_signal()
	await _player_target_and_rack()
	finish()


func _world(physics: bool = false) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 99
	w.use_physics = physics
	add_child(w)
	return w


func _catalog_and_meshes() -> void:
	eq(EnemyCatalog.CLASS_ORDER, ["turret", "strider", "tank"], "three starter enemy classes")
	for cid: String in EnemyCatalog.CLASS_ORDER:
		var u := EnemyCatalog.unit(cid)
		check(not u.is_empty(), "class %s in catalog" % cid)
		var comps: Array = u["components"]
		check(comps.size() >= 2, "%s has multiple components" % cid)
		eq(str((comps[0] as Dictionary)["id"]), str(u["core"]), "%s core component is first" % cid)
	for wid: String in ["enemy_bolter", "enemy_pulse", "enemy_siege_shell", "enemy_mortar"]:
		check(not EnemyCatalog.weapon(wid).is_empty(), "enemy weapon %s in catalog" % wid)
		check(WeaponRegistry.built(wid), "enemy weapon %s registered" % wid)
		check(EnemyCatalog.telegraph_duration(wid, 1.0) >= EnemyCatalog.MIN_TELEGRAPH, "%s telegraph >= 0.3s" % wid)
	for part: String in ["turret_base", "turret_gun", "turret_gun_wreck", "strider_chassis", "strider_sensor",
			"strider_leg", "tank_hull", "tank_turret", "tank_turret_wreck", "tank_vents"]:
		var m := EnemyMeshes.mesh(part)
		check(m != null and m.get_surface_count() > 0, "EnemyMeshes.%s builds" % part)


func _turret_combat() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var t := EnemyTurret.new()
	t.configure("turret", "turret_t1", w, sq, null, 1)
	t.ai_mode = "idle"
	sq.add_enemy(t)
	await frames(1)
	# Static aim-kick from a Side Laser pulse (dv 8.0 -> 24 deg kick).
	t.apply_impulse(Vector3(0, 0, -8.0), "player1")
	near(t.aim_kick, 24.0, 0.01, "static turret takes 24 deg aim kick from laser dv 8")
	eq(t.knock.velocity, Vector3.ZERO, "static turret does not move from knockback")
	# Overheat shutdown & reboot.
	var oh := [false]
	t.overheated.connect(func(_e: EnemyBase) -> void: oh[0] = true)
	t.apply_heat(65.0, "player1")
	w.advance(DT)
	check(oh[0] and t.heat.shutdown, "turret overheats at cap 60")
	t.reset_enemy()
	# Weak-point critical kill: gun has 75 HP at 1.25x -> 60 raw dmg kills (1 laser 55 + 1 AC 22).
	t.apply_damage(55.0, "gun", "player1")
	check(not t.destroyed(), "one laser leaves gun weak point nearly broken")
	t.apply_damage(22.0, "gun", "player1")
	check(t.destroyed() and not t.is_hittable(), "laser + AC on gun weak point critically kills turret")
	near(t.total_hp(), 0.0, 0.001, "critical kill zeros all remaining HP")
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _strider_combat_and_roof_fall() -> void:
	var w := _world(true)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	# Sensor 1-shot critical kill with Side Laser (55 * 1.5 = 82.5 >= 45).
	var s1 := EnemyStrider.new()
	s1.configure("strider", "strider_s1", w, sq, null, 1)
	s1.ai_mode = "idle"
	sq.add_enemy(s1)
	await frames(1)
	s1.apply_damage(55.0, "sensor", "player1")
	check(s1.destroyed(), "one Side Laser to strider sensor is a 1-shot critical kill")

	# Legs cripple + overflow to chassis + stagger from laser knockback.
	var s2 := EnemyStrider.new()
	s2.configure("strider", "strider_s2", w, sq, null, 2)
	s2.ai_mode = "idle"
	sq.add_enemy(s2)
	await frames(1)
	s2.apply_damage(60.0, "legs", "player1")
	check(not s2.destroyed(), "destroying legs cripples without instant kill")
	check(s2._speed_mult <= 0.3 and s2.knock.staggered(), "broken legs cripple speed and stagger strider")
	var core_before := float(s2.hp["chassis"])
	s2.apply_damage(20.0, "legs", "player1")
	check(float(s2.hp["chassis"]) < core_before, "subsequent leg hits overflow damage to chassis")

	# Rooftop knockback shove: build a raised roof slab at y = 14 m, shove strider off the edge -> falls & takes fall dmg!
	var roof := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8.0, 1.0, 8.0)
	cs.shape = box
	roof.add_child(cs)
	roof.position = Vector3(40.0, 13.5, 0.0)
	add_child(roof)
	var floor_b := StaticBody3D.new()
	var fcs := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(80.0, 1.0, 80.0)
	fcs.shape = fbox
	floor_b.add_child(fcs)
	floor_b.position = Vector3(40.0, -0.5, 0.0)
	add_child(floor_b)
	await frames(2)

	var s3 := EnemyStrider.new()
	s3.configure("strider", "strider_roof", w, sq, null, 3)
	s3.ai_mode = "idle"
	s3.position = Vector3(43.2, 14.0, 0.0)
	sq.add_enemy(s3)
	await frames(2)
	var hp_pre_fall := float(s3.hp["chassis"])
	s3.apply_impulse(Vector3(9.0, 0.0, 0.0), "player1")
	for _i in 180:
		w.advance(DT)
	check(s3.global_position.y < 1.5, "shoved rooftop strider fell off roof to street (y=%.2f)" % s3.global_position.y)
	check(float(s3.hp["chassis"]) < hp_pre_fall, "falling 14 m off roof dealt impact damage")

	roof.queue_free()
	floor_b.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _tank_combat_and_vents() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	# Turret break disables primary cannon & deals 90 shock dmg to hull.
	var tk := EnemyTank.new()
	tk.configure("tank", "tank_t1", w, sq, null, 1)
	tk.ai_mode = "idle"
	sq.add_enemy(tk)
	await frames(1)
	var hull0 := float(tk.hp["hull"])
	tk.apply_damage(145.0, "turret", "player1")
	check(not tk.destroyed(), "destroying tank turret leaves damaged hull alive")
	check(tk._primary_disabled, "broken tank turret disables primary siege cannon")
	near(float(tk.hp["hull"]), hull0 - 90.0, 0.1, "broken turret deals 90 shock damage to hull")

	# Vents weak point (80 HP at 1.75x): 1 Side Laser (55 * 1.75 = 96.25) triggers reactor meltdown kill!
	var tk2 := EnemyTank.new()
	tk2.configure("tank", "tank_t2", w, sq, null, 2)
	tk2.ai_mode = "idle"
	sq.add_enemy(tk2)
	await frames(1)
	var kill_cause := [""]
	tk2.destroyed_enemy.connect(func(_e: EnemyBase, c: String, _at: Vector3) -> void: kill_cause[0] = c)
	tk2.apply_damage(55.0, "vents", "player1")
	check(tk2.destroyed(), "one Side Laser to rooftop vents weak point melts down the tank")
	eq(kill_cause[0], "meltdown", "vents kill reports meltdown cause")
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _team_skip_and_impact_signal() -> void:
	var w := _world(false)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var e1 := EnemyStrider.new()
	e1.configure("strider", "e_front", w, sq, null, 1)
	e1.ai_mode = "idle"
	e1.position = Vector3(0, 0, -15)
	sq.add_enemy(e1)
	var p := CombatTarget.new()
	p.target_id = "player1"
	p.owner_peer = 1
	p.team = "player"
	p.set_max_hp({"torso": 400.0})
	p.add_hit_sphere("torso", Vector3(0, 3.5, 0), 2.0)
	p.position = Vector3(0, 0, -30)
	add_child(p)
	w.register(p)
	await frames(1)
	# Enemy shot from behind e1 skips friendly e1 and hits player p!
	var rec := Combat.fire_record("e_rear", 1, "enemy_bolter", "enemy_bolter", Vector3(0, 3.5, 0), Vector3(0, 3.5, -30), w.now, 0, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	var impacts: Array = []
	w.impact_spawned.connect(func(pt: Vector3, r: float, ex: bool, en: bool) -> void:
		impacts.append({"pt": pt, "r": r, "ex": ex, "en": en}))
	w.fire(rec)
	for _i in 90:
		w.advance(DT)
	near(e1.total_hp(), e1.total_max_hp(), 0.01, "enemy bolt skips same-team squadmate")
	check(p.total_hp() < 400.0, "enemy bolt hits opposing player target")
	check(impacts.size() >= 1, "CombatWorld emits impact_spawned on impact")
	# Laser impact flags is_energy = true.
	var lrec := Combat.fire_record("player1", 1, "side_l", "laser", Vector3(0, 3.5, -28), Vector3(0, 3.5, -15), w.now, 0, 0.0)
	w.fire(lrec)
	check(bool(impacts[-1]["en"]), "laser impact sets is_energy = true")
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _player_target_and_rack() -> void:
	var w := _world(false)
	var mech := MechController.new()
	add_child(mech)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "mortar"})
	var pt := PlayerTarget.new()
	add_child(pt)
	pt.bind(w, mech, model, "player1", 1)
	pt.auto_respawn_delay = 0.25
	var respawned := [false]
	pt.on_respawn = func() -> void: respawned[0] = true
	w.register(pt)
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	rack.slot_disabled = pt.is_slot_destroyed
	add_child(rack)
	rack.bind(w, mech, model, null, "player1", 1)
	rack.aim_point = Vector3(0, 3, -50)
	await frames(2)
	check(pt.is_in_group("player_target"), "PlayerTarget joins group player_target")
	# Destroy side_r weapon (80 HP): HUD fraction hits 0 and WeaponRack disables slot 2!
	var broken_slot := [""]
	pt.player_component_destroyed.connect(func(c: String) -> void: broken_slot[0] = c)
	pt.apply_damage(90.0, "side_r", "turret_01")
	eq(broken_slot[0], "side_r", "player_component_destroyed emits for side_r")
	near(float(pt.component_fractions()["side_r"]), 0.0, 0.001, "component_fractions reports 0 for broken hardpoint")
	check(pt.is_slot_destroyed("side_r"), "is_slot_destroyed true for side_r")
	var sl2: Dictionary = rack.slots()[1]
	eq(str(sl2["hold"]), "DESTROYED", "WeaponRack reports destroyed hold flag on broken slot")
	var shots := [0]
	rack.fired.connect(func(n: int) -> void:
		if n == 2:
			shots[0] += 1)
	rack.set_trigger(true)
	for _i in 30:
		rack.step(DT)
		w.advance(DT)
	eq(shots[0], 0, "destroyed weapon hardpoint does not fire")
	# Destroy head -> disabled -> Test Drive auto-respawn restores full HP!
	var dis_cause := [""]
	pt.player_disabled.connect(func(c: String) -> void: dis_cause[0] = c)
	pt.apply_damage(120.0, "head", "tank_01")
	eq(dis_cause[0], "head", "destroying head triggers player_disabled")
	check(pt.disabled and not pt.is_hittable(), "disabled PlayerTarget stops taking hits")
	for _i in 25:
		w.advance(DT)
	check(respawned[0] and not pt.disabled, "Test Drive auto-respawn restores player after delay")
	near(float(pt.component_fractions()["side_r"]), 1.0, 0.001, "respawn repairs weapon hardpoints")
	rack.queue_free()
	pt.queue_free()
	model.queue_free()
	mech.queue_free()
	w.queue_free()
	await frames(1)
