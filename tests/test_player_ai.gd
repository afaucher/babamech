extends TestCase
## Headless regression test for PlayerBot, BotNavigator, BotMetrics, BalanceScenarios, and BalanceVerdict.
## Verifies:
##   1. Profile & loadout catalog validity.
##   2. Strict determinism & input-only fairness across repeated runs.
##   3. Reaction-delayed telegraph dodging & skill ordering (Veteran outperforms Rookie).
##   4. Heat hysteresis & weapon/ammo discipline (Average/Veteran avoid overheat shutdowns).
##   5. Rooftop thruster-climb & Tank rear-vents verticality payoff + cover/LOS navigation.
##   6. Full curved-deck CityDistrict exploration & combat sanity.
##   7. BalanceVerdict flag & cross-check unit tests.


func setup() -> void:
	_test_profiles_and_loadouts()
	await _test_determinism_and_fairness()
	await _test_dodge_and_skill_ordering()
	await _test_heat_and_weapon_discipline()
	await _test_rooftop_verticality_and_nav()
	await _test_city_district_sanity()
	await _test_coop_squad_and_callouts()
	await _test_enemy_lab_bot_spectator()
	_test_verdict_rules()
	finish()


func _test_profiles_and_loadouts() -> void:
	eq(BotProfile.PROFILE_ORDER.size(), 4, "four pilot skill profiles defined")
	for pid: String in BotProfile.PROFILE_ORDER:
		var p := BotProfile.get_profile(pid)
		check(float(p["reaction_s"]) >= 0.10, "profile %s has realistic human reaction time" % pid)
		check(float(p["aim_error_deg"]) > 0.0, "profile %s has non-zero aim error" % pid)
		var lo := BotProfile.get_loadout(pid)
		var san := MechCatalog.sanitize_loadout("strider", lo)
		eq(san, lo, "profile %s default loadout is valid for Strider chassis" % pid)
	var ov := BalanceScenarios.parse_overrides("enemy_bolter.damage=28, turret.base_hp = 120")
	near(float(ov.get("enemy_bolter.damage", 0.0)), 28.0, 0.01, "override parser parses weapon stat")
	near(float(ov.get("turret.base_hp", 0.0)), 120.0, 0.01, "override parser parses enemy hp")


func _test_determinism_and_fairness() -> void:
	var spec := {"scenario": "duel_strider", "profile": "average", "seed": 42}
	var a := await BalanceScenarios.run_scenario(self, spec)
	var b := await BalanceScenarios.run_scenario(self, spec)
	check(bool(a["won"]), "average bot wins 1v1 duel_strider (reason=%s, t=%.1fs)" % [a["end_reason"], a["clear_time_s"]])
	near(float(a["clear_time_s"]), float(b["clear_time_s"]), 0.0001, "deterministic clear time across identical seeds")
	near(float(a["damage_taken"]), float(b["damage_taken"]), 0.0001, "deterministic damage taken across identical seeds")
	eq(int(a["enemy_shots"]), int(b["enemy_shots"]), "deterministic enemy shots fired")
	near(float(a["limited_ammo_pct"]), float(b["limited_ammo_pct"]), 0.0001, "deterministic remaining ammo")
	near(float(a["peak_heat_pct"]), float(b["peak_heat_pct"]), 0.0001, "deterministic peak heat")


func _test_dodge_and_skill_ordering() -> void:
	# Compare Rookie vs Veteran across a multi-threat pocket so telegraph dodging & survival separate cleanly.
	var rookie := await BalanceScenarios.run_scenario(self, {"scenario": "pocket_crossfire", "profile": "rookie", "seed": 202})
	var vet := await BalanceScenarios.run_scenario(self, {"scenario": "pocket_crossfire", "profile": "veteran", "seed": 202})
	print("[player_ai] pocket_crossfire rookie: win=%s t=%.1fs dmg=%.0f dodges=%d | veteran: win=%s t=%.1fs dmg=%.0f dodges=%d" % [
		rookie["won"], rookie["clear_time_s"], rookie["damage_taken"], rookie["dodges_attempted"],
		vet["won"], vet["clear_time_s"], vet["damage_taken"], vet["dodges_attempted"]])
	check(bool(vet["won"]), "veteran clears pocket_crossfire")
	check(int(vet["dodges_attempted"]) >= 1, "veteran actively dodges enemy telegraphs (%d)" % vet["dodges_attempted"])
	check(float(vet["damage_taken"]) < float(rookie["damage_taken"]),
		"veteran takes strictly less damage than rookie in pocket_crossfire (%.0f vs %.0f)" % [vet["damage_taken"], rookie["damage_taken"]])
	check(float(vet["clear_time_s"]) < float(rookie["clear_time_s"]),
		"veteran clears pocket_crossfire faster than rookie (%.1fs vs %.1fs)" % [vet["clear_time_s"], rookie["clear_time_s"]])


func _test_heat_and_weapon_discipline() -> void:
	var avg := await BalanceScenarios.run_scenario(self, {"scenario": "pocket_vanguard", "profile": "average", "seed": 202})
	print("[player_ai] pocket_vanguard average: win=%s t=%.1fs oh=%d peak_heat=%.0f%% ammo=%.0f%%" % [
		avg["won"], avg["clear_time_s"], avg["overheats"], avg["peak_heat_pct"], avg["limited_ammo_pct"]])
	check(bool(avg["won"]), "average bot clears pocket_vanguard (reason=%s)" % avg["end_reason"])
	check(int(avg["overheats"]) == 0, "average bot avoids overheat shutdowns via heat hysteresis (oh=%d)" % avg["overheats"])
	check(float(avg["limited_ammo_pct"]) > 0.0, "average bot does not run rockets completely dry in pocket_vanguard (%.0f%%)" % avg["limited_ammo_pct"])


func _test_rooftop_verticality_and_nav() -> void:
	var street := await BalanceScenarios.run_scenario(self, {"scenario": "duel_tank_street", "profile": "veteran", "seed": 101})
	var roof := await BalanceScenarios.run_scenario(self, {"scenario": "duel_tank_rooftop", "profile": "veteran", "seed": 101})
	print("[player_ai] duel_tank veteran: street=%.1fs (wp=%d) | rooftop=%.1fs (thrust=%.2fs, roof=%.2fs, wp=%d)" % [
		street["clear_time_s"], street["weak_point_kills"],
		roof["clear_time_s"], roof["thrust_time_s"], roof["rooftop_time_s"], roof["weak_point_kills"]])
	check(bool(street["won"]), "veteran wins duel_tank_street (t=%.1fs)" % street["clear_time_s"])
	check(bool(roof["won"]), "veteran wins duel_tank_rooftop (t=%.1fs)" % roof["clear_time_s"])
	check(float(roof["thrust_time_s"]) > 0.3,
		"veteran fires thrusters to take elevated angle onto the 9 m perch (thrust=%.2fs)" % roof["thrust_time_s"])
	check(int(roof["weak_point_kills"]) >= 1,
		"rooftop elevation exposes tank rear vents for weak-point meltdown (wp_kills=%d)" % roof["weak_point_kills"])
	check(float(roof["clear_time_s"]) < float(street["clear_time_s"]),
		"elevated vents meltdown beats frontal street slog (%.1fs vs %.1fs)" % [roof["clear_time_s"], street["clear_time_s"]])


func _test_city_district_sanity() -> void:
	var city := await BalanceScenarios.run_scenario(self, {"scenario": "city_solo", "profile": "veteran", "seed": 1})
	print("[player_ai] city_solo s1 veteran: win=%s reason=%s killed=%d/%d t=%.1fs hp=%.0f%% stuck=%d" % [
		city["won"], city["end_reason"], city["enemies_killed"], city["enemies_total"],
		city["clear_time_s"], city["min_core_hp_pct"], city["stuck_recoveries"]])
	check(int(city["enemies_engaged"]) >= 2, "veteran explores curved CityDistrict and engages enemies (%d/%d)" % [
		city["enemies_engaged"], city["enemies_total"]])
	check(int(city["enemies_killed"]) >= 3, "veteran eliminates at least 3 district enemies (%d/%d)" % [
		city["enemies_killed"], city["enemies_total"]])
	check(int(city["stuck_recoveries"]) < 8, "veteran navigates CityDistrict cleanly (stuck=%d)" % city["stuck_recoveries"])


func _test_coop_squad_and_callouts() -> void:
	var spec := {"scenario": "city_coop_2p", "profile": "average", "seed": 1}
	var a := await BalanceScenarios.run_scenario(self, spec)
	var b := await BalanceScenarios.run_scenario(self, spec)
	print("[player_ai] city_coop_2p s1 average: win=%s crew=%.0f/%d t=%.1fs killed=%d/%d callouts=%d stuck=%d" % [
		a["won"], a["crew_survived"], a["crew_size"], a["clear_time_s"],
		a["enemies_killed"], a["enemies_total"], int(a.get("callouts_posted", 0)), a["stuck_recoveries"]])
	eq(int(a["crew_size"]), 2, "city_coop_2p spawns 2 real player bots")
	check(int(a["enemies_total"]) >= 6, "2p co-op scales district enemy count (%d)" % a["enemies_total"])
	check(int(a.get("callouts_posted", 0)) >= 1, "co-op squad posts honest LOS callouts (%d)" % int(a.get("callouts_posted", 0)))
	check(int(a["enemies_killed"]) >= 4, "2p co-op bots clear district enemies (%d/%d)" % [a["enemies_killed"], a["enemies_total"]])
	check(int(a["stuck_recoveries"]) < 14, "2p co-op bots navigate cleanly without getting stuck (%d)" % a["stuck_recoveries"])
	near(float(a["clear_time_s"]), float(b["clear_time_s"]), 0.0001, "co-op 2p scenario is 100% deterministic")
	near(float(a["damage_taken"]), float(b["damage_taken"]), 0.0001, "co-op 2p damage taken is deterministic")


func _test_enemy_lab_bot_spectator() -> void:
	var lab := EnemyLab.new()
	add_child(lab)
	await frames(2)
	eq(lab.preset, "showcase", "EnemyLab default preset stays showcase")
	eq(lab.target_mode, "strafe", "EnemyLab default target_mode stays strafe")
	lab.set_lab_option("preset", "skirmish")
	await frames(1)
	check(lab.mock_target != null and lab.bot_ai == null, "skirmish starts with mock_target in strafe mode")
	lab.set_lab_option("target_mode", "bot_veteran")
	await frames(2)
	check(lab.mock_target == null and lab.bot_ai != null and lab.bot_mech != null, "bot_veteran spawns real PlayerBot mech")
	for _i in 60:
		lab.step(1.0 / 60.0)
	check(is_instance_valid(lab.bot_ai) and is_instance_valid(lab.bot_mech), "EnemyLab steps bot_veteran cleanly for 1 s")
	lab.set_lab_option("target_mode", "bot_rookie")
	lab.set_lab_option("target_mode", "strafe")
	await frames(2)
	check(lab.bot_ai == null and lab.bot_mech == null and lab.mock_target != null,
		"switching back from bot_* to strafe cleans up bot nodes and restores mock_target")
	lab.queue_free()
	await frames(1)


func _test_verdict_rules() -> void:
	var healthy := {
		"scenario": "duel_turret", "tier": "duel", "profile": "average", "win_rate_pct": 100.0,
		"min_core_hp_pct": 72.0, "clear_time_s": 9.0, "enemy_shots": 4, "enemy_hit_rate_pct": 25.0,
		"damage_taken": 68.0, "overheats": 0.0, "limited_ammo_pct": 83.0, "ammo_dry": false,
		"stuck_recoveries": 0, "end_reason": "cleared", "enemies_total": 1, "enemies_engaged": 1,
	}
	eq(BalanceVerdict.evaluate_row(healthy), ["HEALTHY"] as Array[String], "healthy row gets HEALTHY verdict")

	var stomp := healthy.duplicate()
	stomp["profile"] = "rookie"
	stomp["min_core_hp_pct"] = 95.0
	stomp["damage_taken"] = 10.0
	stomp["enemy_hit_rate_pct"] = 5.0
	var stomp_f := BalanceVerdict.evaluate_row(stomp)
	check("TOO_EASY" in stomp_f and "TOOTHLESS_AI" in stomp_f, "stomp fixture flags TOO_EASY + TOOTHLESS_AI (%s)" % str(stomp_f))

	var aimbot := healthy.duplicate()
	aimbot["profile"] = "veteran"
	aimbot["enemy_shots"] = 6
	aimbot["enemy_hit_rate_pct"] = 66.0
	aimbot["min_core_hp_pct"] = 30.0
	check("UNFAIR_AIMBOT" in BalanceVerdict.evaluate_row(aimbot), "high hit-rate vs veteran flags UNFAIR_AIMBOT")

	var sponge := healthy.duplicate()
	sponge["clear_time_s"] = 45.0
	sponge["ammo_dry"] = true
	sponge["limited_ammo_pct"] = 0.0
	var sp_f := BalanceVerdict.evaluate_row(sponge)
	check("SPONGEY" in sp_f and "AMMO_DRY" in sp_f, "slow/dry fixture flags SPONGEY + AMMO_DRY (%s)" % str(sp_f))

	var trap := healthy.duplicate()
	trap["overheats"] = 2.0
	check("HEAT_TRAP" in BalanceVerdict.evaluate_row(trap), "repeated average overheats flag HEAT_TRAP")

	var stuck := healthy.duplicate()
	stuck["end_reason"] = "timeout"
	stuck["enemies_total"] = 5
	stuck["enemies_engaged"] = 1
	check("BOT_STUCK" in BalanceVerdict.evaluate_row(stuck), "timeout with low engagement flags BOT_STUCK")

	var md := BalanceVerdict.format_markdown([healthy], [], 1.2, "unit")
	check(md.contains("BABAMECH BALANCE SCORECARD") and md.contains("HEALTHY"), "markdown formatter emits scorecard table")
	var csv := BalanceVerdict.format_csv([healthy])
	check(csv.contains("scenario,tier,profile") and csv.contains("duel_turret"), "csv formatter emits header and row")
