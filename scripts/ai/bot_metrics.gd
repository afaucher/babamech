class_name BotMetrics
extends RefCounted
## Signal-driven telemetry collector for combat balance simulations (docs/design/player-ai.md §5.1).
## Attaches read-only to CombatWorld, EnemySquad, PlayerTarget, MechController, WeaponRack, and PlayerBot.
## Zero global randomness, zero edits to combat code.

var scenario_id := ""
var tier := "duel"
var profile_id := "average"
var seed_value := 1
var loadout_id := "default"

var _world: CombatWorld
var _squad: EnemySquad
var _player_targets: Array[PlayerTarget] = []
var _mechs: Array[MechController] = []
var _racks: Array[WeaponRack] = []
var _bots: Array[PlayerBot] = []
var _ring: RingFrame

var _sim_t := 0.0
var _combat_t := 0.0
var _first_contact_t := -1.0
var _shutdown_t := 0.0
var _thrust_t := 0.0
var _rooftop_t := 0.0
var _peak_heat := 0.0
var _heat_sum := 0.0
var _heat_samples := 0
var _overheat_count := 0
var _hard_landings := 0

var _hp_start_total := 0.0
var _damage_taken := 0.0
var _damage_by_comp: Dictionary = {}
var _limbs_destroyed := 0
var _weapons_destroyed := 0
var _disables := 0
var _disable_cause := ""

var _player_weapons: Dictionary = {}     ## wid -> {shots, hits, damage, ammo_start, ammo_end, went_dry}
var _player_hit_keys: Dictionary = {}    ## shot_key -> true (avoid double-counting splash+direct as 2 hits for accuracy)
var _enemy_hit_keys: Dictionary = {}
var _weak_point_hits := 0
var _total_player_hits := 0
var _weak_point_kills := 0

var _enemy_types: Dictionary = {}        ## enemy_id -> enemy_type
var _enemy_engaged_at: Dictionary = {}   ## enemy_id -> sim_t when first alerted/damaged
var _enemy_stats: Dictionary = {}        ## type_id -> {count, kills, survival_sum, telegraphs, cancelled, shots, hits, dmg, mortars}
var _enemies_total := 0
var _enemies_killed := 0
var _enemies_engaged := 0


func bind(sc_id: String, sc_tier: String, prof: String, sd: int, l_id: String,
		w: CombatWorld, sq: EnemySquad, pt: PlayerTarget, m: MechController, r: WeaponRack, b: PlayerBot,
		rf: RingFrame = null) -> void:
	scenario_id = sc_id
	tier = sc_tier
	profile_id = prof
	seed_value = sd
	loadout_id = l_id
	_world = w
	_squad = sq
	_ring = rf
	_player_targets.clear()
	_mechs.clear()
	_racks.clear()
	_bots.clear()
	_hp_start_total = 0.0

	if sq != null:
		for e: EnemyBase in sq.enemies:
			_register_enemy(e)
		sq.enemy_spawned.connect(_register_enemy)
		sq.enemy_event.connect(_on_enemy_event)

	if w != null:
		w.fired.connect(_on_world_fired)
		w.hit_landed.connect(_on_hit_landed)

	if pt != null or m != null or r != null or b != null:
		add_player(pt, m, r, b)


## Attach a player mech (call once in solo via bind, or once per crew member in 2–4p co-op).
func add_player(pt: PlayerTarget, m: MechController, r: WeaponRack, b: PlayerBot) -> void:
	if pt != null:
		_player_targets.append(pt)
		_hp_start_total += pt.total_max_hp()
		pt.damaged.connect(_on_player_damaged)
		pt.player_component_destroyed.connect(_on_player_comp_destroyed)
		pt.player_disabled.connect(_on_player_disabled)
	if m != null:
		_mechs.append(m)
		m.overheated.connect(_on_mech_overheated)
		m.hard_landing.connect(_on_mech_hard_landing)
	if r != null:
		_racks.append(r)
		for s: Dictionary in r.slots():
			var wid := str(s["weapon"])
			if wid == "":
				continue
			if not _player_weapons.has(wid):
				_player_weapons[wid] = {
					"shots": 0, "hits": 0, "damage": 0.0,
					"ammo_start": int(s["ammo_max"]), "ammo_end": int(s["ammo"]), "went_dry": false,
				}
			else:
				var pw: Dictionary = _player_weapons[wid]
				if int(s["ammo_max"]) > 0 and int(pw["ammo_start"]) > 0:
					pw["ammo_start"] = int(pw["ammo_start"]) + int(s["ammo_max"])
	if b != null:
		_bots.append(b)


func _register_enemy(e: EnemyBase) -> void:
	if e == null or _enemy_types.has(e.target_id):
		return
	_enemy_types[e.target_id] = e.enemy_type
	_enemies_total += 1
	_ensure_enemy_class(e.enemy_type)
	(_enemy_stats[e.enemy_type] as Dictionary)["count"] = int((_enemy_stats[e.enemy_type] as Dictionary)["count"]) + 1


func _ensure_enemy_class(tid: String) -> Dictionary:
	if not _enemy_stats.has(tid):
		_enemy_stats[tid] = {
			"count": 0, "kills": 0, "survival_sum": 0.0, "telegraphs": 0,
			"cancelled": 0, "shots": 0, "hits": 0, "dmg": 0.0, "mortars": 0,
		}
	return _enemy_stats[tid] as Dictionary


func sample(dt: float) -> void:
	_sim_t += dt
	if _mechs.is_empty():
		return
	var in_combat := false
	if _squad != null:
		for e: EnemyBase in _squad.enemies:
			if is_instance_valid(e) and not e.destroyed() and e.is_alerted():
				in_combat = true
				if not _enemy_engaged_at.has(e.target_id):
					_enemy_engaged_at[e.target_id] = _sim_t
					_enemies_engaged += 1
					if _first_contact_t < 0.0:
						_first_contact_t = _sim_t
	var inv_n := 1.0 / float(_mechs.size())
	for m: MechController in _mechs:
		if not is_instance_valid(m):
			continue
		var h_frac := m.heat / maxf(m.heat_cap, 1.0)
		_peak_heat = maxf(_peak_heat, h_frac)
		if m.shutdown:
			_shutdown_t += dt * inv_n
		if m.thrusting:
			_thrust_t += dt * inv_n
		var h := _ring.height(m.global_position) if _ring != null else m.global_position.y
		if h >= 4.5 and m.grounded():
			_rooftop_t += dt * inv_n
		if in_combat:
			_heat_sum += h_frac
			_heat_samples += 1
	if in_combat:
		_combat_t += dt


func _on_world_fired(rec: Dictionary) -> void:
	var is_enemy := bool(rec.get("enemy", false)) or str(rec.get("team", "")) == "enemy"
	var wid := str(rec.get("weapon", ""))
	if is_enemy:
		var sh := str(rec.get("shooter", ""))
		var et := str(_enemy_types.get(sh, _weapon_to_enemy_class(wid)))
		var es := _ensure_enemy_class(et)
		es["shots"] = int(es["shots"]) + 1
		if wid == "enemy_mortar":
			es["mortars"] = int(es["mortars"]) + 1
		if _first_contact_t < 0.0:
			_first_contact_t = _sim_t
	else:
		if not _player_weapons.has(wid):
			_player_weapons[wid] = {"shots": 0, "hits": 0, "damage": 0.0, "ammo_start": -1, "ammo_end": -1, "went_dry": false}
		var pw: Dictionary = _player_weapons[wid]
		pw["shots"] = int(pw["shots"]) + 1
		if _first_contact_t < 0.0:
			_first_contact_t = _sim_t


func _on_hit_landed(t: CombatTarget, h: Hit) -> void:
	if t == null or h == null:
		return
	if t.team == "enemy" and t is EnemyBase:
		var wid := h.weapon
		if not _player_weapons.has(wid):
			_player_weapons[wid] = {"shots": 0, "hits": 0, "damage": 0.0, "ammo_start": -1, "ammo_end": -1, "went_dry": false}
		var pw: Dictionary = _player_weapons[wid]
		pw["damage"] = float(pw["damage"]) + h.damage
		if h.shot == "" or not _player_hit_keys.has(h.shot):
			if h.shot != "":
				_player_hit_keys[h.shot] = true
			pw["hits"] = int(pw["hits"]) + 1
			_total_player_hits += 1
			if h.component in ["gun", "sensor", "vents"]:
				_weak_point_hits += 1
		if not _enemy_engaged_at.has(t.target_id):
			_enemy_engaged_at[t.target_id] = _sim_t
			_enemies_engaged += 1
	elif t.team == "player":
		var et := str(_enemy_types.get(h.shooter, _weapon_to_enemy_class(h.weapon)))
		var es := _ensure_enemy_class(et)
		es["dmg"] = float(es["dmg"]) + h.damage
		if h.shot == "" or not _enemy_hit_keys.has(h.shot):
			if h.shot != "":
				_enemy_hit_keys[h.shot] = true
			es["hits"] = int(es["hits"]) + 1


func _on_enemy_event(kind: String, enemy: Node, payload: Dictionary) -> void:
	if not (enemy is EnemyBase):
		return
	var e := enemy as EnemyBase
	var es := _ensure_enemy_class(e.enemy_type)
	match kind:
		"alerted":
			if str(payload.get("state", "")) != "lost" and not _enemy_engaged_at.has(e.target_id):
				_enemy_engaged_at[e.target_id] = _sim_t
				_enemies_engaged += 1
				if _first_contact_t < 0.0:
					_first_contact_t = _sim_t
		"telegraph_started":
			es["telegraphs"] = int(es["telegraphs"]) + 1
		"telegraph_cancelled":
			es["cancelled"] = int(es["cancelled"]) + 1
		"destroyed":
			_enemies_killed += 1
			es["kills"] = int(es["kills"]) + 1
			var eng_t := float(_enemy_engaged_at.get(e.target_id, 0.0))
			es["survival_sum"] = float(es["survival_sum"]) + maxf(_sim_t - eng_t, 0.0)
			if str(payload.get("cause", "")) in ["weak_point", "meltdown"]:
				_weak_point_kills += 1


func _on_player_damaged(amount: float, component: String, _src: String) -> void:
	_damage_taken += amount
	_damage_by_comp[component] = float(_damage_by_comp.get(component, 0.0)) + amount


func _on_player_comp_destroyed(component: String) -> void:
	if component in PlayerTarget.CORE_COMPONENTS:
		_limbs_destroyed += 1
	else:
		_weapons_destroyed += 1


func _on_player_disabled(cause: String) -> void:
	_disables += 1
	if _disable_cause == "":
		_disable_cause = cause


func _on_mech_overheated() -> void:
	_overheat_count += 1


func _on_mech_hard_landing(_speed: float, _sev: float) -> void:
	_hard_landings += 1


func _weapon_to_enemy_class(wid: String) -> String:
	match wid:
		"enemy_bolter": return "turret"
		"enemy_pulse": return "strider"
		"enemy_siege_shell", "enemy_mortar": return "tank"
	return "unknown"


func finalize(won: bool, end_reason: String) -> Dictionary:
	# Snapshot final weapon ammo & compute damage shares.
	var total_player_dmg := 0.0
	for wid: String in _player_weapons:
		total_player_dmg += float((_player_weapons[wid] as Dictionary)["damage"])
	if not _racks.is_empty():
		# Reset ammo_end sums first for multi-mount / multi-mech same weapon.
		for wid: String in _player_weapons:
			var pw: Dictionary = _player_weapons[wid]
			if int(pw["ammo_start"]) > 0:
				pw["ammo_end"] = 0
		for r: WeaponRack in _racks:
			if not is_instance_valid(r):
				continue
			for s: Dictionary in r.slots():
				var wid := str(s["weapon"])
				if wid == "" or not _player_weapons.has(wid):
					continue
				var pw: Dictionary = _player_weapons[wid]
				if int(s["ammo_max"]) > 0:
					pw["ammo_end"] = int(pw["ammo_end"]) + int(s["ammo"])
					if int(s["ammo"]) == 0:
						pw["went_dry"] = true

	var top_weapon := "-"
	var top_weapon_share := 0.0
	var limited_ammo_pct := 100.0
	var any_limited := false
	var any_dry := false
	var weapons_out := {}
	for wid: String in _player_weapons:
		var pw: Dictionary = (_player_weapons[wid] as Dictionary).duplicate()
		var sh := int(pw["shots"])
		var ht := int(pw["hits"])
		var dmg := float(pw["damage"])
		pw["hit_rate_pct"] = (100.0 * float(ht) / float(sh)) if sh > 0 else 0.0
		pw["dmg_share_pct"] = (100.0 * dmg / total_player_dmg) if total_player_dmg > 0.01 else 0.0
		if float(pw["dmg_share_pct"]) > top_weapon_share:
			top_weapon_share = float(pw["dmg_share_pct"])
			top_weapon = wid
		var a0 := int(pw["ammo_start"])
		if a0 > 0:
			any_limited = true
			var pct := 100.0 * float(int(pw["ammo_end"])) / float(a0)
			pw["ammo_rem_pct"] = pct
			limited_ammo_pct = minf(limited_ammo_pct, pct)
			if bool(pw["went_dry"]) or int(pw["ammo_end"]) <= 0:
				any_dry = true
		else:
			pw["ammo_rem_pct"] = -1.0
		weapons_out[wid] = pw

	# Aggregate enemy totals.
	var en_shots := 0
	var en_hits := 0
	var en_tele := 0
	var en_cancel := 0
	var en_dmg := 0.0
	var en_out := {}
	for et: String in _enemy_stats:
		var es: Dictionary = (_enemy_stats[et] as Dictionary).duplicate()
		var ks := int(es["kills"])
		var ss := int(es["shots"])
		var hs := int(es["hits"])
		var ts := int(es["telegraphs"])
		var cs := int(es["cancelled"])
		es["avg_survival_s"] = (float(es["survival_sum"]) / float(ks)) if ks > 0 else _sim_t
		es["hit_rate_pct"] = (100.0 * float(hs) / float(ss)) if ss > 0 else 0.0
		es["cancel_rate_pct"] = (100.0 * float(cs) / float(ts)) if ts > 0 else 0.0
		en_out[et] = es
		en_shots += ss
		en_hits += hs
		en_tele += ts
		en_cancel += cs
		en_dmg += float(es["dmg"])

	var crew_size := maxi(_player_targets.size(), 1)
	var crew_survived := 0
	var min_core_sum := 0.0
	var hp_end_sum := 0.0
	if not _player_targets.is_empty():
		for pt: PlayerTarget in _player_targets:
			if not is_instance_valid(pt):
				continue
			if not pt.disabled:
				crew_survived += 1
			hp_end_sum += pt.total_hp()
			var mc := 100.0
			var fracs := pt.component_fractions()
			for c: String in PlayerTarget.CORE_COMPONENTS:
				if fracs.has(c):
					mc = minf(mc, float(fracs[c]) * 100.0)
			min_core_sum += mc
	else:
		crew_survived = 1 if won else 0
		min_core_sum = 100.0
		hp_end_sum = maxf(_hp_start_total, 1.0)
	var min_core_pct := min_core_sum / float(crew_size)
	var hp_rem_pct := 100.0 * hp_end_sum / maxf(_hp_start_total, 1.0)

	var stuck_total := 0
	var dodges_att := 0
	var dodges_cln := 0
	for b: PlayerBot in _bots:
		if is_instance_valid(b):
			var dbg := b.debug_state()
			stuck_total += int(dbg.get("stuck_recoveries", 0))
			dodges_att += int(dbg.get("dodges_attempted", 0))
			dodges_cln += int(dbg.get("dodges_clean", 0))
	var avg_combat_heat := (100.0 * _heat_sum / float(_heat_samples)) if _heat_samples > 0 else 0.0

	return {
		"scenario": scenario_id,
		"tier": tier,
		"profile": profile_id,
		"seed": seed_value,
		"loadout": loadout_id,
		"runs": 1,
		"crew_size": crew_size,
		"crew_survived": float(crew_survived),
		"downs": float(_disables),
		"won": won,
		"win_rate_pct": 100.0 if won else 0.0,
		"end_reason": end_reason,
		"clear_time_s": _sim_t,
		"combat_time_s": _combat_t,
		"traversal_time_s": maxf(_sim_t - _combat_t, 0.0),
		"first_contact_s": _first_contact_t,
		"enemies_total": _enemies_total,
		"enemies_killed": _enemies_killed,
		"enemies_engaged": _enemies_engaged,
		"hp_remaining_pct": hp_rem_pct,
		"min_core_hp_pct": min_core_pct,
		"damage_taken": _damage_taken,
		"damage_by_comp": _damage_by_comp.duplicate(),
		"limbs_destroyed": _limbs_destroyed,
		"weapons_destroyed": _weapons_destroyed,
		"disables": _disables,
		"disable_cause": _disable_cause,
		"hard_landings": _hard_landings,
		"peak_heat_pct": _peak_heat * 100.0,
		"avg_combat_heat_pct": avg_combat_heat,
		"overheats": _overheat_count,
		"shutdown_time_s": _shutdown_t,
		"thrust_time_s": _thrust_t,
		"rooftop_time_s": _rooftop_t,
		"stuck_recoveries": stuck_total,
		"dodges_attempted": dodges_att,
		"dodges_clean": dodges_cln,
		"enemy_shots": en_shots,
		"enemy_hits": en_hits,
		"enemy_hit_rate_pct": (100.0 * float(en_hits) / float(en_shots)) if en_shots > 0 else 0.0,
		"enemy_telegraphs": en_tele,
		"enemy_cancel_rate_pct": (100.0 * float(en_cancel) / float(en_tele)) if en_tele > 0 else 0.0,
		"enemy_damage_dealt": en_dmg,
		"enemy_classes": en_out,
		"player_weapons": weapons_out,
		"top_weapon": top_weapon,
		"top_weapon_share_pct": top_weapon_share,
		"limited_ammo_pct": limited_ammo_pct if any_limited else -1.0,
		"ammo_dry": any_dry,
		"weak_point_hits": _weak_point_hits,
		"weak_point_kills": _weak_point_kills,
		"weak_point_kill_share_pct": (100.0 * float(_weak_point_kills) / float(_enemies_killed)) if _enemies_killed > 0 else 0.0,
	}


## Aggregate several runs (e.g. multiple city seeds) into a single scorecard row.
static func aggregate(runs: Array[Dictionary], label: String = "") -> Dictionary:
	if runs.is_empty():
		return {}
	if runs.size() == 1:
		var one := runs[0].duplicate(true)
		if label != "":
			one["scenario"] = label
		return one
	var n := float(runs.size())
	var first := runs[0]
	var wins := 0
	var time_s := 0.0
	var combat_s := 0.0
	var hp_rem := 0.0
	var min_core := 0.0
	var dmg_taken := 0.0
	var overheats := 0.0
	var stuck := 0
	var crew_surv := 0.0
	var downs := 0.0
	var en_shots := 0
	var en_hits := 0
	var en_total := 0
	var en_killed := 0
	var en_engaged := 0
	var wp_kills := 0
	var ammo_sum := 0.0
	var ammo_n := 0
	var any_dry := false
	var any_timeout := false
	var weapon_dmg := {}
	var total_wdmg := 0.0
	for r: Dictionary in runs:
		if bool(r["won"]):
			wins += 1
		if str(r["end_reason"]) == "timeout":
			any_timeout = true
		time_s += float(r["clear_time_s"])
		combat_s += float(r["combat_time_s"])
		hp_rem += float(r["hp_remaining_pct"])
		min_core += float(r["min_core_hp_pct"])
		dmg_taken += float(r["damage_taken"])
		overheats += float(r["overheats"])
		stuck += int(r["stuck_recoveries"])
		crew_surv += float(r.get("crew_survived", 1.0 if bool(r["won"]) else 0.0))
		downs += float(r.get("downs", r.get("disables", 0.0)))
		en_shots += int(r["enemy_shots"])
		en_hits += int(r["enemy_hits"])
		en_total += int(r["enemies_total"])
		en_killed += int(r["enemies_killed"])
		en_engaged += int(r["enemies_engaged"])
		wp_kills += int(r["weak_point_kills"])
		if float(r["limited_ammo_pct"]) >= 0.0:
			ammo_sum += float(r["limited_ammo_pct"])
			ammo_n += 1
		if bool(r["ammo_dry"]):
			any_dry = true
		for wid: String in (r.get("player_weapons", {}) as Dictionary):
			var d := float(((r["player_weapons"] as Dictionary)[wid] as Dictionary).get("damage", 0.0))
			weapon_dmg[wid] = float(weapon_dmg.get(wid, 0.0)) + d
			total_wdmg += d
	var top_w := "-"
	var top_sh := 0.0
	for wid: String in weapon_dmg:
		var sh := (100.0 * float(weapon_dmg[wid]) / total_wdmg) if total_wdmg > 0.01 else 0.0
		if sh > top_sh:
			top_sh = sh
			top_w = wid
	return {
		"scenario": label if label != "" else str(first["scenario"]),
		"tier": str(first["tier"]),
		"profile": str(first["profile"]),
		"seed": 0,
		"loadout": str(first["loadout"]),
		"runs": runs.size(),
		"crew_size": int(first.get("crew_size", 1)),
		"crew_survived": crew_surv / n,
		"downs": downs / n,
		"won": wins == runs.size(),
		"win_rate_pct": 100.0 * float(wins) / n,
		"end_reason": "cleared" if wins == runs.size() else ("timeout" if any_timeout else "mixed"),
		"clear_time_s": time_s / n,
		"combat_time_s": combat_s / n,
		"hp_remaining_pct": hp_rem / n,
		"min_core_hp_pct": min_core / n,
		"damage_taken": dmg_taken / n,
		"overheats": overheats / n,
		"stuck_recoveries": int(round(float(stuck) / n)),
		"enemies_total": int(round(float(en_total) / n)),
		"enemies_killed": int(round(float(en_killed) / n)),
		"enemies_engaged": int(round(float(en_engaged) / n)),
		"enemy_shots": int(round(float(en_shots) / n)),
		"enemy_hits": int(round(float(en_hits) / n)),
		"enemy_hit_rate_pct": (100.0 * float(en_hits) / float(en_shots)) if en_shots > 0 else 0.0,
		"top_weapon": top_w,
		"top_weapon_share_pct": top_sh,
		"limited_ammo_pct": (ammo_sum / float(ammo_n)) if ammo_n > 0 else -1.0,
		"ammo_dry": any_dry,
		"weak_point_kills": wp_kills,
		"weak_point_kill_share_pct": (100.0 * float(wp_kills) / float(en_killed)) if en_killed > 0 else 0.0,
	}
