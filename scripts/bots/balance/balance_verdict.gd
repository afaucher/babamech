class_name BalanceVerdict
extends RefCounted
## Target balance bands, automated Tuning Verdict rules, and Markdown/CSV/JSON scorecard formatters
## (docs/design/player-ai.md §5.2, §5.3, §6.1). Pure data + string formatting, zero global RNG.

## Target bands keyed by "<tier>:<profile>": {win_min, hp_min, hp_max, time_min, time_max, en_hit_max, ammo_min, oh_max}.
const BANDS := {
	"duel:rookie": {"win_min": 40.0, "hp_min": 20.0, "hp_max": 85.0, "time_min": 4.0, "time_max": 35.0, "en_hit_max": 75.0, "ammo_min": 30.0, "oh_max": 2.0},
	"duel:average": {"win_min": 85.0, "hp_min": 45.0, "hp_max": 92.0, "time_min": 3.0, "time_max": 22.0, "en_hit_max": 45.0, "ammo_min": 55.0, "oh_max": 0.5},
	"duel:veteran": {"win_min": 95.0, "hp_min": 65.0, "hp_max": 100.0, "time_min": 2.0, "time_max": 16.0, "en_hit_max": 30.0, "ammo_min": 65.0, "oh_max": 0.0},
	"duel:brawler": {"win_min": 80.0, "hp_min": 35.0, "hp_max": 92.0, "time_min": 2.5, "time_max": 20.0, "en_hit_max": 50.0, "ammo_min": 50.0, "oh_max": 1.0},
	"pocket:rookie": {"win_min": 20.0, "hp_min": 10.0, "hp_max": 82.0, "time_min": 12.0, "time_max": 70.0, "en_hit_max": 75.0, "ammo_min": 15.0, "oh_max": 3.0},
	"pocket:average": {"win_min": 75.0, "hp_min": 35.0, "hp_max": 88.0, "time_min": 10.0, "time_max": 55.0, "en_hit_max": 42.0, "ammo_min": 25.0, "oh_max": 1.0},
	"pocket:veteran": {"win_min": 95.0, "hp_min": 55.0, "hp_max": 98.0, "time_min": 8.0, "time_max": 40.0, "en_hit_max": 28.0, "ammo_min": 40.0, "oh_max": 0.0},
	"pocket:brawler": {"win_min": 70.0, "hp_min": 30.0, "hp_max": 90.0, "time_min": 8.0, "time_max": 48.0, "en_hit_max": 48.0, "ammo_min": 25.0, "oh_max": 1.0},
	"city:rookie": {"win_min": 20.0, "hp_min": 10.0, "hp_max": 85.0, "time_min": 45.0, "time_max": 140.0, "en_hit_max": 70.0, "ammo_min": 10.0, "oh_max": 4.0},
	"city:average": {"win_min": 65.0, "hp_min": 30.0, "hp_max": 85.0, "time_min": 35.0, "time_max": 125.0, "en_hit_max": 40.0, "ammo_min": 15.0, "oh_max": 1.5},
	"city:veteran": {"win_min": 90.0, "hp_min": 55.0, "hp_max": 96.0, "time_min": 25.0, "time_max": 100.0, "en_hit_max": 25.0, "ammo_min": 30.0, "oh_max": 0.5},
	"city:brawler": {"win_min": 65.0, "hp_min": 25.0, "hp_max": 88.0, "time_min": 30.0, "time_max": 120.0, "en_hit_max": 45.0, "ammo_min": 15.0, "oh_max": 2.0},
	"coop:rookie": {"win_min": 35.0, "hp_min": 20.0, "hp_max": 85.0, "time_min": 35.0, "time_max": 120.0, "en_hit_max": 70.0, "ammo_min": 15.0, "oh_max": 4.0},
	"coop:average": {"win_min": 85.0, "hp_min": 45.0, "hp_max": 90.0, "time_min": 22.0, "time_max": 90.0, "en_hit_max": 40.0, "ammo_min": 25.0, "oh_max": 2.0},
	"coop:veteran": {"win_min": 95.0, "hp_min": 65.0, "hp_max": 98.0, "time_min": 15.0, "time_max": 75.0, "en_hit_max": 25.0, "ammo_min": 35.0, "oh_max": 1.0},
	"coop:mixed": {"win_min": 80.0, "hp_min": 40.0, "hp_max": 92.0, "time_min": 20.0, "time_max": 95.0, "en_hit_max": 45.0, "ammo_min": 25.0, "oh_max": 2.5},
	"coop:brawler": {"win_min": 75.0, "hp_min": 35.0, "hp_max": 90.0, "time_min": 20.0, "time_max": 90.0, "en_hit_max": 48.0, "ammo_min": 20.0, "oh_max": 2.5},
}


static func band_for(tier: String, profile: String) -> Dictionary:
	var k := "%s:%s" % [tier, profile]
	if BANDS.has(k):
		return BANDS[k] as Dictionary
	return BANDS["duel:average"] as Dictionary


static func evaluate_row(m: Dictionary) -> Array[String]:
	var flags: Array[String] = []
	var tier := str(m.get("tier", "duel"))
	var prof := str(m.get("profile", "average"))
	var b := band_for(tier, prof)
	var win_pct := float(m.get("win_rate_pct", 0.0))
	var hp_pct := float(m.get("min_core_hp_pct", 100.0))
	var clear_s := float(m.get("clear_time_s", 0.0))
	var en_shots := int(m.get("enemy_shots", 0))
	var en_hit_pct := float(m.get("enemy_hit_rate_pct", 0.0))
	var dmg_taken := float(m.get("damage_taken", 0.0))
	var overheats := float(m.get("overheats", 0.0))
	var ammo_pct := float(m.get("limited_ammo_pct", -1.0))
	var ammo_dry := bool(m.get("ammo_dry", false))
	var stuck := int(m.get("stuck_recoveries", 0))
	var crew_size := maxi(int(m.get("crew_size", 1)), 1)
	var end_reason := str(m.get("end_reason", ""))
	var en_total := maxi(int(m.get("enemies_total", 1)), 1)
	var en_engaged := int(m.get("enemies_engaged", en_total))

	# 1. Separate bot navigation bugs from balance verdicts.
	if (end_reason == "timeout" and float(en_engaged) < float(en_total) * 0.5) or stuck >= 5 * crew_size:
		flags.append("BOT_STUCK")

	# 2. Toothless AI (against slow/careless rookie, enemies barely land anything).
	if prof == "rookie":
		var dmg_floor := 35.0 if tier == "duel" else 75.0
		if en_shots > 0 and (en_hit_pct < 16.0 or dmg_taken < dmg_floor):
			flags.append("TOOTHLESS_AI")

	# 3. Too easy / 1-salvo stomp.
	if prof == "rookie" and win_pct >= 99.0 and hp_pct > 85.0:
		flags.append("TOO_EASY")
	elif en_shots < maxi(1, int(floor(float(en_total) * 0.5))) and win_pct >= 99.0 and prof != "veteran":
		flags.append("TOO_EASY")
	elif tier in ["pocket", "coop"] and prof in ["average", "mixed"] and win_pct >= 99.0 and clear_s < float(b["time_min"]) and hp_pct > 90.0:
		flags.append("TOO_EASY")

	# 4. Unfair aimbot (active-dodging Veteran gets shredded or killed in solo duels).
	if prof == "veteran":
		if (en_shots >= 3 and en_hit_pct > 35.0) or (tier == "duel" and (win_pct < 100.0 or hp_pct < 45.0)):
			flags.append("UNFAIR_AIMBOT")
		elif win_pct < float(b["win_min"]) and not ("BOT_STUCK" in flags):
			flags.append("UNFAIR_AIMBOT")

	# 5. Spongey / Ammo starvation.
	if ammo_pct >= 0.0 and (ammo_dry or ammo_pct < float(b["ammo_min"])):
		if prof in ["veteran", "average"] and (tier != "city" or ammo_pct < 10.0 or ammo_dry):
			flags.append("AMMO_DRY")
	if not ("BOT_STUCK" in flags) and clear_s > float(b["time_max"]) * 1.25:
		flags.append("SPONGEY")

	# 6. Heat trap (normal burst-disciplined pilot repeatedly shuts down).
	if prof == "average" and overheats >= 2.0:
		flags.append("HEAT_TRAP")
	elif prof == "veteran" and overheats >= 1.0:
		flags.append("HEAT_TRAP")

	if flags.is_empty():
		flags.append("HEALTHY")
	return flags


## Evaluate cross-scenario checks: skill expression & rooftop tank verticality payoff.
static func evaluate_cross_checks(rows: Array[Dictionary]) -> Array[Dictionary]:
	var checks: Array[Dictionary] = []

	# Skill expression: compare average damage taken & clear time between rookie and veteran on shared scenarios.
	var rookie_by_sc := {}
	var vet_by_sc := {}
	for r: Dictionary in rows:
		var sc := str(r["scenario"])
		if str(r["profile"]) == "rookie":
			rookie_by_sc[sc] = r
		elif str(r["profile"]) == "veteran":
			vet_by_sc[sc] = r
	var r_dmg := 0.0
	var v_dmg := 0.0
	var r_t := 0.0
	var v_t := 0.0
	var shared := 0
	for sc: String in rookie_by_sc:
		if vet_by_sc.has(sc):
			r_dmg += float((rookie_by_sc[sc] as Dictionary)["damage_taken"])
			v_dmg += float((vet_by_sc[sc] as Dictionary)["damage_taken"])
			r_t += float((rookie_by_sc[sc] as Dictionary)["clear_time_s"])
			v_t += float((vet_by_sc[sc] as Dictionary)["clear_time_s"])
			shared += 1
	if shared > 0:
		var dmg_ratio := v_dmg / maxf(r_dmg, 1.0)
		var time_ratio := v_t / maxf(r_t, 0.1)
		var ok := (r_dmg < 10.0 or dmg_ratio <= 0.65) and time_ratio <= 0.85
		checks.append({
			"id": "skill_expression",
			"ok": ok,
			"summary": "Skill expression %s (vet dmg %.2fx rookie, vet time %.2fx rookie across %d shared)" % [
				"OK" if ok else "WARN", dmg_ratio, time_ratio, shared],
		})

	# Verticality payoff: veteran duel_tank_rooftop vs duel_tank_street.
	if vet_by_sc.has("duel_tank_street") and vet_by_sc.has("duel_tank_rooftop"):
		var st_t := float((vet_by_sc["duel_tank_street"] as Dictionary)["clear_time_s"])
		var rf_t := float((vet_by_sc["duel_tank_rooftop"] as Dictionary)["clear_time_s"])
		var delta_pct := (rf_t - st_t) / maxf(st_t, 0.1) * 100.0
		var ok := rf_t <= st_t * 0.85
		checks.append({
			"id": "rooftop_payoff",
			"ok": ok,
			"flag": "" if ok else "NO_VERT_PAYOFF",
			"summary": "Rooftop tank payoff %s (street %.1fs -> roof %.1fs, %+.0f%% TTK)" % [
				"OK" if ok else "NO_VERT_PAYOFF", st_t, rf_t, delta_pct],
		})
	return checks


static func format_markdown(rows: Array[Dictionary], cross_checks: Array[Dictionary], elapsed_s: float,
		suite_name: String, baseline_map: Dictionary = {}) -> String:
	var lines: Array[String] = []
	var has_base := not baseline_map.is_empty()
	lines.append("=== BABAMECH BALANCE SCORECARD (suite=%s, %d rows, %.2f s)%s ===" % [
		suite_name, rows.size(), elapsed_s, " [A/B DIFF]" if has_base else ""])
	lines.append("")
	var has_coop := false
	for r: Dictionary in rows:
		if int(r.get("crew_size", 1)) > 1:
			has_coop = true
			break
	if has_coop:
		lines.append("| Scenario | Profile | Crew | Win | Time | MinHP% | DmgIn | Downs | EnHit% | OH | Ammo% | WP Kill% | Top Weapon | Verdict |")
		lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")
	else:
		lines.append("| Scenario | Profile | Win | Time | MinHP% | DmgIn | EnHit% | OH | Ammo% | WP Kill% | Top Weapon | Verdict |")
		lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")
	for r: Dictionary in rows:
		var key := "%s:%s" % [r["scenario"], r["profile"]]
		var base: Dictionary = baseline_map.get(key, {})
		var flags: Array[String] = r.get("verdict", evaluate_row(r))
		var v_str := ", ".join(flags)
		var win_s := "%3.0f%%" % float(r.get("win_rate_pct", 0.0))
		var t_s := "%.1fs" % float(r.get("clear_time_s", 0.0))
		var hp_s := "%.0f%%" % float(r.get("min_core_hp_pct", 100.0))
		var dmg_s := "%.0f" % float(r.get("damage_taken", 0.0))
		var eh_s := "%.1f%%" % float(r.get("enemy_hit_rate_pct", 0.0))
		var oh_s := "%.1f" % float(r.get("overheats", 0.0)) if int(r.get("runs", 1)) > 1 else "%d" % int(round(float(r.get("overheats", 0.0))))
		var am_v := float(r.get("limited_ammo_pct", -1.0))
		var am_s := ("%.0f%%" % am_v) if am_v >= 0.0 else "-"
		var wp_s := "%.0f%%" % float(r.get("weak_point_kill_share_pct", 0.0))
		var tw_s := "%s (%.0f%%)" % [str(r.get("top_weapon", "-")), float(r.get("top_weapon_share_pct", 0.0))]
		if not base.is_empty():
			t_s += " (%+.1f)" % [float(r["clear_time_s"]) - float(base.get("clear_time_s", r["clear_time_s"]))]
			hp_s += " (%+.0f)" % [float(r["min_core_hp_pct"]) - float(base.get("min_core_hp_pct", r["min_core_hp_pct"]))]
			eh_s += " (%+.1f)" % [float(r["enemy_hit_rate_pct"]) - float(base.get("enemy_hit_rate_pct", r["enemy_hit_rate_pct"]))]
		if has_coop:
			var cs := maxi(int(r.get("crew_size", 1)), 1)
			var surv := float(r.get("crew_survived", float(cs)))
			var crew_s := ("%.1f/%d" % [surv, cs]) if int(r.get("runs", 1)) > 1 else ("%d/%d" % [int(round(surv)), cs])
			var dn := float(r.get("downs", r.get("disables", 0.0)))
			var dn_s := ("%.1f" % dn) if int(r.get("runs", 1)) > 1 else ("%d" % int(round(dn)))
			lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % [
				str(r["scenario"]), str(r["profile"]), crew_s, win_s, t_s, hp_s, dmg_s, dn_s, eh_s, oh_s, am_s, wp_s, tw_s, v_str])
		else:
			lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % [
				str(r["scenario"]), str(r["profile"]), win_s, t_s, hp_s, dmg_s, eh_s, oh_s, am_s, wp_s, tw_s, v_str])
	if not cross_checks.is_empty():
		lines.append("")
		var parts: Array[String] = []
		for cc: Dictionary in cross_checks:
			parts.append(str(cc["summary"]))
		lines.append("Cross-checks: " + " | ".join(parts))
	return "\n".join(lines)


static func format_csv(rows: Array[Dictionary]) -> String:
	var lines: Array[String] = [
		"scenario,tier,profile,crew_size,crew_survived,downs,runs,win_rate_pct,clear_time_s,combat_time_s,min_core_hp_pct,hp_remaining_pct,damage_taken,enemy_shots,enemy_hit_rate_pct,overheats,limited_ammo_pct,weak_point_kill_share_pct,top_weapon,top_weapon_share_pct,stuck_recoveries,verdict"
	]
	for r: Dictionary in rows:
		var flags: Array[String] = r.get("verdict", evaluate_row(r))
		var cs := maxi(int(r.get("crew_size", 1)), 1)
		lines.append("%s,%s,%s,%d,%.2f,%.2f,%d,%.1f,%.2f,%.2f,%.1f,%.1f,%.1f,%d,%.1f,%.2f,%.1f,%.1f,%s,%.1f,%d,\"%s\"" % [
			str(r.get("scenario", "")), str(r.get("tier", "")), str(r.get("profile", "")),
			cs, float(r.get("crew_survived", float(cs))), float(r.get("downs", r.get("disables", 0.0))),
			int(r.get("runs", 1)),
			float(r.get("win_rate_pct", 0.0)), float(r.get("clear_time_s", 0.0)), float(r.get("combat_time_s", 0.0)),
			float(r.get("min_core_hp_pct", 100.0)), float(r.get("hp_remaining_pct", 100.0)), float(r.get("damage_taken", 0.0)),
			int(r.get("enemy_shots", 0)), float(r.get("enemy_hit_rate_pct", 0.0)), float(r.get("overheats", 0.0)),
			float(r.get("limited_ammo_pct", -1.0)), float(r.get("weak_point_kill_share_pct", 0.0)),
			str(r.get("top_weapon", "-")), float(r.get("top_weapon_share_pct", 0.0)), int(r.get("stuck_recoveries", 0)),
			";".join(flags)])
	return "\n".join(lines)


static func to_json_dict(rows: Array[Dictionary], cross_checks: Array[Dictionary], meta: Dictionary) -> Dictionary:
	return {"meta": meta, "rows": rows, "cross_checks": cross_checks}


static func load_baseline(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return {}
	var out := {}
	for r: Variant in (parsed as Dictionary).get("rows", []):
		if r is Dictionary:
			var rd := r as Dictionary
			out["%s:%s" % [rd.get("scenario", ""), rd.get("profile", "")]] = rd
	return out
