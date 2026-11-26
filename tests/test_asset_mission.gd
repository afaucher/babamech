extends TestCase
## Mission assets end to end in a SOLO stack drive (objectives are the only mode; fixture from
## tests/test_mission_objectives.gd, seed 7: deck 2's primary is a defend). MissionFlow registers the relay's body through
## TestDriveCombat.add_asset; enemy-team hits on that AssetTarget go through CombatWorld.resolve_hit (the path a shell's
## direct hit takes) and must reach MissionFlow.damage_asset: asset_hp drops by damage / asset_max_hp() (ASSET_MAX_HP x the crew scale), the target's
## mirrored HP follows (set_hp), and a lethal hit ends the mission "lost" / objective_failed. Before its defend is active
## the relay is no target and damage_asset does nothing (Missions' playtest: garrisons destroyed unattended relays).

const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}
const DIRECTOR := {"rest_first": 1.5, "rest_last": 1.5, "arrival_rest": 1.0, "grace": 1.5, "follow_gap": 0.5}

var td: TestDrive


func _init() -> void:
	timeout_sec = 180.0


func setup() -> void:
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	await _run()
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}
	finish()


func _run() -> void:
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = SEED
	add_child(td)
	await frames(4)
	var mf := td.mission
	if not check(mf != null and mf.plan != null and mf.world != null, "plan mode: plan and world"):
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var p := mf.plan.primary(1)
	if not eq(str(p.get("type", "")), "defend", "seed 7: deck 2's primary is a defend"):
		return
	var id := str(p["id"])
	# Played as a crew of 3 (the scale a host would have sent; solo has no host, so the test schedules it here).
	mf.receive_scale({"n": 3, "at": mf.now(), "reason": "test"})
	mf._tick_scale()
	eq(mf.crew_scale(), 3, "scale 3")
	_kill_all()
	var site: Dictionary = mf.rules.objective(id)["site"]
	await frames(20)
	var dormant := td.combat.asset(id)
	check(mf.rules.obj_state(id) != "active" and (dormant == null or not dormant.is_hittable()),
		"before its defend is active the relay is dormant (a garrison can't wear it down)")
	mf.damage_asset(id, 300.0)
	near(float(mf.asset_hp.get(id, 0.0)), 1.0, 1e-4, "and takes no damage")
	td.mech.global_position = td.stack.from_deck_arc(int(p["deck"]), float(site["x"]), float(site["s"]), 0.5)
	td.mech.velocity = Vector3.ZERO
	if not check(await _until(func() -> bool: return mf.rules.obj_state(id) == "active", 5.0), "the defend is active"):
		return
	var w := td.combat.world
	if not check(await _until(func() -> bool: return td.combat.asset(id) != null, 3.0), "MissionFlow registered the relay (add_asset)"):
		return
	var t := td.combat.asset(id)
	check(t in w.targets and t.mech != null and t.mech.is_in_group("mission_asset"), "the AssetTarget sits on the relay body")
	near(float(mf.asset_hp.get(id, 0.0)), 1.0, 1e-4, "relay at full")
	var c: Vector3 = t.world_spheres()[0]["center"]
	var wid := "enemy_siege_shell"
	var st := w.stats(wid)
	var rec := Combat.fire_record("enemy_relay_test", 1, wid, wid, c + Vector3.UP * 10.0, c, w.now, 9100, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	var h := w.resolve_hit(rec, st, t, "body", c, Vector3.UP, Vector3.DOWN, 120.0)
	check(h != null, "the host decides the enemy hit")
	near(float(mf.asset_hp.get(id, 0.0)), 1.0 - 120.0 / mf.asset_max_hp(), 1e-4, "asset_hp dropped by 120 points (of the crew-scaled relay HP)")
	check(await _until(func() -> bool: return absf(t.hp_fraction() - float(mf.asset_hp[id])) < 0.011, 2.0),
		"the target's mirrored HP follows the mission's (%.3f vs %.3f)" % [t.hp_fraction(), float(mf.asset_hp[id])])
	eq(mf.rules.outcome, "", "still running")
	# Ease off (user 2026-11-25): two pilots leave, the scale drops 3 -> 1 at its `at`. The relay keeps its HP FRACTION;
	# its hit points rescale (600 -> 1050), on the mission side and on the AssetTarget's mirror.
	var f0 := float(mf.asset_hp[id])
	var mx0 := mf.asset_max_hp()
	var at := mf.now() + 0.5
	mf.receive_scale({"n": 1, "at": at, "reason": "leave", "pilot": 3})
	await _until(func() -> bool: return mf.crew_scale() == 1, 2.0)
	eq(mf.crew_scale(), 1, "the scale dropped at its `at`")
	near(float(mf.scale_at), at, 1e-6, "applied at the scheduled time")
	near(mx0, MissionFlow.ASSET_MAX_HP * float(MissionFlow.ASSET_HP_SCALE[2]), 0.01, "3 pilots: 600 hit points")
	near(mf.asset_max_hp(), MissionFlow.ASSET_MAX_HP * float(MissionFlow.ASSET_HP_SCALE[0]), 0.01, "1 pilot: 1050 hit points")
	near(float(mf.asset_hp[id]), f0, 1e-6, "the relay keeps its HP fraction (%.3f)" % f0)
	check(await _until(func() -> bool: return absf(t.hp_max - mf.asset_max_hp()) < 0.01, 2.0),
		"the AssetTarget's mirrored max follows (%.0f)" % t.hp_max)
	near(t.hp_fraction(), f0, 0.011, "and its fraction stays")
	near(t.hp_value, f0 * mf.asset_max_hp(), 1.0, "hp = fraction x the new max")
	rec["shot_index"] = 9101
	w.resolve_hit(rec, st, t, "body", c, Vector3.UP, Vector3.DOWN, mf.asset_max_hp())
	near(float(mf.asset_hp.get(id, 1.0)), 0.0, 1e-4, "a lethal hit empties the relay")
	if check(await _until(func() -> bool: return mf.rules.outcome != "", 3.0), "an outcome after the relay is destroyed"):
		eq(mf.rules.outcome, "lost", "lost")
		eq(mf.rules.reason, "objective_failed", "reason objective_failed")
	check(await _until(func() -> bool: return td.combat.asset(id) == null or not is_instance_valid(t) or not t.is_hittable(), 2.0),
		"the destroyed relay is no longer a target")
	td.queue_free()
	await frames(3)


func _kill_all() -> void:
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and not e.destroyed():
			e.apply_damage(1.0e7, e.core_component(), "test")


func _until(f: Callable, s: float) -> bool:
	for i in ceili(s * Engine.physics_ticks_per_second):
		if f.call():
			return true
		await get_tree().physics_frame
	return f.call()
