class_name EnemySpawner
extends RefCounted
## Deterministic seeded enemy encounter placement & wave spawning (docs/design/enemies.md §6,
## docs/design/mission-section.md §16, docs/design/mission-objectives.md §5 & §9).
## Every spawn is validated against the arrival safe bubble (70 m in a SectionPlan deck, 48 m in a lone district) and
## CityPlan geometry (buildings, pillars, columns, floor_cuts, clear_at, ramps). No global randomness (AGENTS.md rule 4).

const SPAWN_SAFE_RADIUS := 48.0    ## m around player spawn kept clear in standalone districts
const SECTION_SAFE_RADIUS := 70.0  ## m around SectionPlan.arrival(k) kept clear on mission decks (§16)
const DRONE_SAFE_RADIUS := 68.0    ## m min distance for Patrol Drone spawn (never aggro on frame 0)
const DRONE_CRUISE_ALT := 15.0     ## m default hover altitude above deck floor
const GUNSHIP_SAFE_RADIUS := 72.0  ## m min distance for Valkyrie Gunship spawn (never aggro on frame 0)
const GUNSHIP_CRUISE_ALT := 11.5   ## m default hover altitude for Gunship patrol
const MIN_ROOF_SPAN := 7.0         ## m minimum roof tier width/length for a 4.8 m Enforcer Turret
const STRIDER_CLEAR := 2.2         ## m ground clearance radius for Hound Skirmisher / Breacher
const TANK_CLEAR := 3.8            ## m ground clearance radius for Bastion Siege Tank
const TURRET_CLEAR := 2.5          ## m clearance radius for Enforcer Turret variants on rooftops
const DRONE_CLEAR := 2.2           ## m aerial clearance radius for Patrol Drone
const GUNSHIP_CLEAR := 3.2         ## m aerial clearance radius for Valkyrie Gunship
const TROOP_CLEAR := 1.6           ## m ground clearance radius for an individual Exo-Trooper
## Rooftop units must be visible from the street (roof_seen_from_street): ROOF_SIGHT_POINTS street points between
## ROOF_SIGHT_MIN and ROOF_SIGHT_R m away see from a mech's weapon height (ROOF_SIGHT_EYE above the street) to the unit's
## body (ROOF_SIGHT_AIM above the roof) over the plan's building boxes.
const ROOF_SIGHT_R := 110.0
const ROOF_SIGHT_MIN := 15.0
const ROOF_SIGHT_EYE := 6.0
const ROOF_SIGHT_AIM := 2.5
const ROOF_SIGHT_POINTS := 3
## Mission waves: every wave of a deck's pool is this many times budget x (1 - pool.garrison) x share (user playtest
## 2026-11-23: inbound waves were too small at 2-4 units). Waves only: the garrison is unchanged, so a deck's total rises.
const WAVE_POOL_SCALE := 1.75
const BAY_HEAVY_MAX := 2           ## heavies (tank, gunship) in one gate-bay opening at most


## Deterministic total unit budget for one deck (garrison + waves combined; deeper decks & larger crews scale up).
## Kept cleanly inside PacingDirector.DECK_CAP (24) so 4-mech co-op + waves never stall on caps or frame budget.
static func deck_budget(crew_size: int = 1, deck: int = 0) -> int:
	var crew := clampi(crew_size, 1, 4)
	var depth := maxi(deck, 0)
	return clampi(9 + (crew - 1) * 3 + depth, 6, 22)


## Compute deterministic encounter spawn specs across the full deck.
##   - In section mode (`sites` passed, or automatically read from `plan.section.encounter_sites(plan.deck)`):
##     spreads garrison across all non-safe encounter sites proportional to `share` & `weight` (light/medium/heavy),
##     respecting the 70 m safe bubble around `arrival(k)`, with static turrets at heavy/medium sites and mobile
##     units at light sites.
##   - In standalone district mode: synthesizes 5 full-extent sites so enemies span the whole district cleanly.
##   - `garrison_share`: 1.0 = full deck standing (default); 0.5 = half budget garrison (MissionPlan waves mode).
static func plan_encounters(plan: CityPlan, ring: RingFrame, player_spawn: Vector3, crew_size: int = 1,
		sites: Array = [], garrison_share: float = 1.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if plan == null or ring == null or garrison_share <= 0.0:
		return out
	var eff_sites: Array = sites
	var safe_arc := Vector2.ZERO
	var safe_r := SPAWN_SAFE_RADIUS
	var p_arc3 := ring.world_to_arc(player_spawn)
	var p2 := Vector2(p_arc3.x, p_arc3.y)
	var deck_idx := maxi(plan.deck, 0)
	if eff_sites.is_empty() and plan.section != null and plan.deck >= 0 and plan.section.has_method("encounter_sites"):
		eff_sites = plan.section.encounter_sites(plan.deck)
	if not eff_sites.is_empty() and plan.section != null and plan.deck >= 0 and plan.section.has_method("arrival"):
		var arr: Dictionary = plan.section.arrival(plan.deck)
		safe_arc = Vector2(float(arr.get("x", p2.x)), float(arr.get("s", p2.y)))
		safe_r = SECTION_SAFE_RADIUS
	else:
		safe_arc = p2
		safe_r = SECTION_SAFE_RADIUS if not eff_sites.is_empty() else SPAWN_SAFE_RADIUS

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([plan.checksum(), deck_idx, crew_size, int(round(garrison_share * 100.0)), "enemies_v5"])
	var lane := _lane_x(plan)
	if eff_sites.is_empty():
		eff_sites = _standalone_sites(plan, p2, lane)

	var active_sites: Array[Dictionary] = []
	for s_raw: Variant in eff_sites:
		if not (s_raw is Dictionary):
			continue
		var sd := s_raw as Dictionary
		if bool(sd.get("safe", false)):
			continue
		var sp := Vector2(float(sd.get("x", 0.0)), float(sd.get("s", 0.0)))
		if sp.distance_to(safe_arc) < safe_r * 0.85:
			continue
		active_sites.append(sd)
	if active_sites.is_empty():
		active_sites = _standalone_sites(plan, safe_arc, lane)

	var total_units := maxi(roundi(float(deck_budget(crew_size, deck_idx)) * clampf(garrison_share, 0.0, 1.0)), 1)
	var allocs := _allocate_site_counts(active_sites, total_units)
	var roof_cands := _rooftop_candidates(plan, lane)
	var used_spots: Array[Vector2] = [safe_arc, p2]
	var next_id := [1]
	var sq_seq := [1]
	var placed_types := {}

	# Place heavy/medium sites first so fortified anchors claim the best vantage roofs & crossings, then light sites.
	var order: Array[int] = []
	for i in active_sites.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var wa := _weight_rank(str(active_sites[a].get("weight", "light")))
		var wb := _weight_rank(str(active_sites[b].get("weight", "light")))
		if wa != wb:
			return wa > wb
		return float(active_sites[a].get("share", 0.0)) > float(active_sites[b].get("share", 0.0)))

	for idx in order:
		var count := allocs[idx]
		if count <= 0:
			continue
		var site := active_sites[idx]
		var s_pt := Vector2(float(site.get("x", lane)), float(site.get("s", 0.0)))
		var weight := str(site.get("weight", "light"))
		var kind := str(site.get("kind", "patrol"))
		var progress := float(site.get("progress", 0.5))
		var left := count

		if weight == "heavy":
			# 1. Fortified heavy anchor: rooftop overwatch (turret_sniper / turret_missile / turret) + Siege Tank!
			if left >= 1:
				var ttype := "turret_sniper" if progress >= 0.65 and rng.randf() < 0.65 else ("turret_missile" if rng.randf() < 0.55 else "turret")
				if _place_roof_turret(out, plan, roof_cands, used_spots, next_id, s_pt, safe_arc, p2, safe_r, ttype, kind, rng):
					placed_types["turret"] = true
					left -= 1
			if left >= 1:
				var tank_pt := _find_clear_ground_near(plan, s_pt, TANK_CLEAR, used_spots, 14.0, safe_arc, p2, safe_r)
				if not is_nan(tank_pt.x):
					var p2_end := _clamp_arc(plan, tank_pt + Vector2(0.0, -14.0 if tank_pt.y > safe_arc.y else 14.0))
					out.append(_spec(next_id, "tank", tank_pt.x, tank_pt.y, 0.0, _yaw_toward(safe_arc, tank_pt), kind, [tank_pt, p2_end]))
					used_spots.append(tank_pt)
					placed_types["tank"] = true
					left -= 1
			# 2. If room for 3+ more at this heavy site, deploy a ground or rooftop mixed Exo-Trooper fireteam!
			if left >= 3 and not placed_types.has("trooper"):
				var placed_n := _place_trooper_fireteam(out, plan, roof_cands, used_spots, next_id, sq_seq,
					s_pt, safe_arc, p2, safe_r, "medium", false, mini(left, 4), kind, rng)
				if placed_n > 0:
					placed_types["trooper"] = true
					left -= placed_n
			# 3. Remaining heavy budget: escort breacher/gunship/2nd turret.
			while left > 0:
				if left >= 3 and rng.randf() < 0.55:
					var pn := _place_trooper_fireteam(out, plan, roof_cands, used_spots, next_id, sq_seq,
						s_pt, safe_arc, p2, safe_r, "light", false, mini(left, 4), kind, rng)
					if pn > 0:
						placed_types["trooper"] = true
						left -= pn
						continue
				if not placed_types.has("gunship") and rng.randf() < 0.5:
					if _place_air_unit(out, plan, used_spots, next_id, s_pt, safe_arc, p2, maxf(safe_r, GUNSHIP_SAFE_RADIUS), "gunship", lane, kind, site):
						placed_types["gunship"] = true
						left -= 1
						continue
				var esc := _find_clear_ground_near(plan, s_pt, STRIDER_CLEAR, used_spots, 10.0, safe_arc, p2, safe_r)
				if not is_nan(esc.x):
					var stype := "strider_breacher" if rng.randf() < 0.55 else "strider"
					out.append(_spec(next_id, stype, esc.x, esc.y, 0.0, _yaw_toward(safe_arc, esc), kind, _short_patrol(plan, esc, rng)))
					used_spots.append(esc)
					placed_types["strider"] = true
				elif _place_roof_turret(out, plan, roof_cands, used_spots, next_id, s_pt, safe_arc, p2, safe_r, "turret", kind, rng):
					placed_types["turret"] = true
				left -= 1

		elif weight == "medium":
			# Medium site: fireteam of 3-4 individual troopers OR mixed turret + mobile unit / gunship.
			if left >= 3 and (not placed_types.has("trooper") or rng.randf() < 0.55):
				var try_roof := rng.randf() < 0.30 and placed_types.has("trooper")
				var pn := _place_trooper_fireteam(out, plan, roof_cands, used_spots, next_id, sq_seq,
					s_pt, safe_arc, p2, safe_r, "light", try_roof, mini(left, 4), kind, rng)
				if pn > 0:
					placed_types["trooper"] = true
					left -= pn
			if left >= 1 and (not placed_types.has("turret") or rng.randf() < 0.45):
				var ttype := "turret_missile" if rng.randf() < 0.5 else "turret"
				if _place_roof_turret(out, plan, roof_cands, used_spots, next_id, s_pt, safe_arc, p2, safe_r, ttype, kind, rng):
					placed_types["turret"] = true
					left -= 1
			if left >= 1 and not placed_types.has("gunship") and rng.randf() < 0.45:
				if _place_air_unit(out, plan, used_spots, next_id, s_pt, safe_arc, p2, maxf(safe_r, GUNSHIP_SAFE_RADIUS), "gunship", lane, kind, site):
					placed_types["gunship"] = true
					left -= 1
			while left > 0:
				var st_pt := _find_clear_ground_near(plan, s_pt, STRIDER_CLEAR, used_spots, 10.0, safe_arc, p2, safe_r)
				if not is_nan(st_pt.x):
					var stype := "strider_breacher" if rng.randf() < 0.5 else "strider"
					out.append(_spec(next_id, stype, st_pt.x, st_pt.y, 0.0, _yaw_toward(safe_arc, st_pt), kind, _short_patrol(plan, st_pt, rng)))
					used_spots.append(st_pt)
					placed_types["strider"] = true
				elif not placed_types.has("drone") and _place_air_unit(out, plan, used_spots, next_id, s_pt, safe_arc, p2, maxf(safe_r, DRONE_SAFE_RADIUS), "drone", lane, kind, site):
					placed_types["drone"] = true
				left -= 1

		else:
			# Light site (first_contact, patrol, station, cordon): strictly MOBILE units so §15 hunt-out works cleanly!
			if left >= 1 and not placed_types.has("drone") and (kind in ["patrol", "cordon", "station"] or progress >= 0.35):
				if _place_air_unit(out, plan, used_spots, next_id, s_pt, safe_arc, p2, maxf(safe_r, DRONE_SAFE_RADIUS), "drone", lane, kind, site):
					placed_types["drone"] = true
					left -= 1
			if left >= 3 and (not placed_types.has("trooper") or rng.randf() < 0.45):
				var pn := _place_trooper_fireteam(out, plan, roof_cands, used_spots, next_id, sq_seq,
					s_pt, safe_arc, p2, safe_r, "light", false, mini(left, 3), kind, rng)
				if pn > 0:
					placed_types["trooper"] = true
					left -= pn
			while left > 0:
				var sc_pt := _find_clear_ground_near(plan, s_pt, STRIDER_CLEAR, used_spots, 10.0, safe_arc, p2, safe_r)
				if not is_nan(sc_pt.x):
					var stype := "strider_breacher" if rng.randf() < 0.5 else "strider"
					var loop: Array = _loop_from_site(plan, site, sc_pt, rng)
					out.append(_spec(next_id, stype, sc_pt.x, sc_pt.y, 0.0, _yaw_toward(safe_arc, sc_pt), kind, loop))
					used_spots.append(sc_pt)
					placed_types["strider"] = true
				left -= 1

	# Full-deck variety guard (when garrison_share >= 0.75): guarantee a scout drone & trooper fireteam exist if budget allowed.
	if garrison_share >= 0.75 and not active_sites.is_empty():
		var mid_site := active_sites[active_sites.size() / 2]
		var mid_pt := Vector2(float(mid_site.get("x", lane)), float(mid_site.get("s", 0.0)))
		if not placed_types.has("drone"):
			if _place_air_unit(out, plan, used_spots, next_id, mid_pt, safe_arc, p2, maxf(safe_r, DRONE_SAFE_RADIUS), "drone", lane, "patrol", mid_site):
				placed_types["drone"] = true
		if not placed_types.has("trooper"):
			if _place_trooper_fireteam(out, plan, roof_cands, used_spots, next_id, sq_seq,
					mid_pt, safe_arc, p2, safe_r, "light", false, 3, "troop_patrol", rng) > 0:
				placed_types["trooper"] = true
		if not placed_types.has("tank"):
			var far_site := active_sites[-1]
			var far_pt := Vector2(float(far_site.get("x", lane)), float(far_site.get("s", 0.0)))
			var t_pt := _find_clear_ground_near(plan, far_pt, TANK_CLEAR, used_spots, 12.0, safe_arc, p2, safe_r)
			if not is_nan(t_pt.x):
				out.append(_spec(next_id, "tank", t_pt.x, t_pt.y, 0.0, _yaw_toward(safe_arc, t_pt), "heavy_anchor",
					[t_pt, _clamp_arc(plan, t_pt + Vector2(0.0, -12.0))]))
				used_spots.append(t_pt)
				placed_types["tank"] = true
	return out


## Instantiate all planned encounter specs onto the curved CityPlan deck and add them to `squad`.
static func spawn_all(plan: CityPlan, ring: RingFrame, player_spawn: Vector3, world: CombatWorld,
		squad: EnemySquad, mission_seed: int = 1, skip_meshes: bool = false, crew_size: int = 1,
		id_prefix: String = "", spawn_deck: int = 0, sites: Array = [],
		garrison_share: float = 1.0) -> Array[EnemyBase]:
	var specs := plan_encounters(plan, ring, player_spawn, crew_size, sites, garrison_share)
	return spawn_specs(specs, plan, ring, world, squad, mission_seed, skip_meshes, id_prefix, spawn_deck, "")


## Shared deterministic instantiation helper used by both garrison `spawn_all` and wave `spawn_wave`.
static func spawn_specs(specs: Array[Dictionary], plan: CityPlan, ring: RingFrame, world: CombatWorld,
		squad: EnemySquad, mission_seed: int = 1, skip_meshes: bool = false, id_prefix: String = "",
		spawn_deck: int = 0, wave_id: String = "") -> Array[EnemyBase]:
	var spawned: Array[EnemyBase] = []
	var fireteams: Dictionary = {}   ## group_id -> EnemyTroopSquad
	for i in specs.size():
		var sp := specs[i]
		var type_id := str(sp["type"])
		var e := make_enemy(type_id)
		var sid := id_prefix + str(sp["id"])
		var use_ring := ring
		e.configure(type_id, sid, world, squad, use_ring, mission_seed + i + 1)
		e.spawn_deck = spawn_deck
		e.wave = str(sp.get("wave", wave_id))
		e.defend_target_id = str(sp.get("defend_target_id", ""))
		e.staged = bool(sp.get("staged", false))   # gate bay: dormant until MissionFlow rolls the group out
		var x := float(sp["x"])
		var s := float(sp["s"])
		var h := float(sp["h"])
		var yaw_arc := float(sp["yaw_arc"])
		var pos_w: Vector3
		var b_world: Basis
		if use_ring != null:
			var base_b := use_ring.basis_at_arc(s)
			if sp.has("b_center"):
				# Exact match with CityBuildings' building-local box frame so rooftop units sit flush!
				var bc: Vector2 = sp["b_center"]
				var toff: Vector2 = sp["t_off"]
				var ty1 := float(sp["t_y1"])
				var bxf := Transform3D(CityGeo.frame_basis(use_ring, bc.y), use_ring.arc_to_world(bc.x, bc.y, CityPlan.CURB_H))
				pos_w = bxf * Vector3(toff.x, ty1, toff.y)
			else:
				pos_w = use_ring.arc_to_world(x, s, h)
			b_world = Basis(base_b.y, yaw_arc) * base_b
			e.up = use_ring.up_at(pos_w)
		else:
			pos_w = Vector3(x, h, s)
			b_world = Basis(Vector3.UP, yaw_arc)
			e.up = Vector3.UP
		e.transform = Transform3D(b_world, pos_w)
		var pat: Array[Vector2] = []
		for p in sp.get("patrol", []):
			if p is Vector2:
				pat.append(p)
			elif p is Dictionary and (p as Dictionary).has("x") and (p as Dictionary).has("s"):
				pat.append(Vector2(float(p["x"]), float(p["s"])))
		if not pat.is_empty():
			e.set_patrol_points(pat)
		if e is EnemyTrooper:
			var tr := e as EnemyTrooper
			tr.on_roof = bool(sp.get("on_roof", false))
			var gid := str(sp.get("squad_group", ""))
			if gid != "":
				if not fireteams.has(gid):
					var anc_arc: Vector2 = sp.get("squad_anchor", Vector2(x, s))
					var anc_w := use_ring.arc_to_world(anc_arc.x, anc_arc.y, h) if use_ring != null else Vector3(anc_arc.x, h, anc_arc.y)
					var ft := EnemyTroopSquad.make(id_prefix + gid, spawn_deck, anc_w, tr.on_roof)
					fireteams[gid] = ft
					if squad != null and squad.has_method("register_fireteam"):
						squad.register_fireteam(ft)
				tr.attach_fireteam(fireteams[gid] as EnemyTroopSquad, int(sp.get("member_idx", 0)))
		if skip_meshes:
			e._built_visuals = true
		if squad != null:
			squad.add_enemy(e)
		spawned.append(e)
	return spawned


# --- Mission Waves Phase 1 (docs/design/mission-objectives.md §5 & §9) ------------------------------------

## Plan one wave release batch at `source_def` respecting `wave_pool_share` (= 1 - pool.garrison), `wave_def.share`,
## WAVE_POOL_SCALE, `PacingDirector.WAVE_MAX`, `order.max_units`, and `source_def.load`. Returns {specs, total_units,
## spawn_count, pending}. Size: clamp(round(budget x wave_pool_share x share x WAVE_POOL_SCALE), 2 (1 for a budget of 1),
## WAVE_MAX), or `wave_def.units` when > 0 (a director patrol); the caller's budget carries the crew scaling (MissionFlow:
## PacingDirector.reserve_budget).
## GATE BAYS: with `source_def.bay` (BayFormation's normalised bay) the units are laid out in the bay (BayFormation.layout:
## seeded loose staggered rows, the same generator, drawn after the type roll) instead of the recess grid, at most
## BAY_HEAVY_MAX heavies per opening; units that do not fit the bay stay pending (the follow-up load). Each spec then
## carries "staged": true, "exit": [Vector3 arc x, s, h] (BayFormation.exit_path) and "exit_wait" (s) for the roll-out.
static func plan_wave(plan: CityPlan, ring: RingFrame, order: Dictionary, wave_def: Dictionary,
		source_def: Dictionary, budget: int, mission_seed: int = 1, already_spawned: int = 0,
		wave_pool_share: float = 1.0) -> Dictionary:
	var wave_id := str(order.get("wave", wave_def.get("id", "wave")))
	var share := clampf(float(wave_def.get("share", 0.3)), 0.05, 1.0)
	var pool_share := clampf(wave_pool_share, 0.0, 1.0)
	var min_u := 1 if budget <= 1 else 2
	var total_units := clampi(roundi(float(maxi(budget, 1)) * pool_share * share * WAVE_POOL_SCALE), min_u,
			PacingDirector.WAVE_MAX)
	if int(wave_def.get("units", 0)) > 0:
		total_units = mini(int(wave_def["units"]), PacingDirector.WAVE_MAX)
	var remaining := maxi(total_units - already_spawned, 0)
	var source_load := maxi(int(source_def.get("load", 6)), 1)
	var max_u := maxi(int(order.get("max_units", remaining)), 0)
	var count := mini(remaining, mini(max_u, source_load))
	var pending := maxi(remaining - count, 0)
	var specs: Array[Dictionary] = []
	if count <= 0:
		return {"specs": specs, "total_units": total_units, "spawn_count": 0, "pending": pending}

	# Defend-objective waves (trigger: {kind: "objective", id: "<defend_id>", step: "start"}, id != "hold") may target
	# that defend relay alongside crew mechs; all other waves and garrisons ignore AssetTargets in missions.
	var defend_id := str(wave_def.get("for", ""))
	if defend_id == "hold":
		defend_id = ""
	var trig: Variant = wave_def.get("trigger", {})
	if defend_id == "" and trig is Dictionary and str((trig as Dictionary).get("kind", "")) == "objective" \
			and str((trig as Dictionary).get("step", "")) == "start":
		var tid_s := str((trig as Dictionary).get("id", ""))
		if tid_s != "" and tid_s != "hold":
			defend_id = tid_s

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([mission_seed, wave_id, already_spawned, str(source_def.get("id", "")), "wave_v1"])
	var theme := str(wave_def.get("theme", "mixed"))
	var skind := str(source_def.get("kind", "gate"))
	var exit_pt := Vector2(float(source_def.get("x", 0.0)), float(source_def.get("s", 0.0)))
	var src_pt := exit_pt
	var in_recess := false
	var sp_raw: Variant = source_def.get("point", {})
	if sp_raw is Dictionary and (sp_raw as Dictionary).has("x") and (sp_raw as Dictionary).has("s"):
		src_pt = Vector2(float((sp_raw as Dictionary)["x"]), float((sp_raw as Dictionary)["s"]))
		in_recess = (plan != null and not plan.extent.grow(-4.0).has_point(src_pt))
	var tw_dict: Dictionary = source_def.get("toward", {})
	var tw_pt := Vector2(float(tw_dict.get("x", exit_pt.x)), float(tw_dict.get("s", exit_pt.y + 18.0)))
	var fwd := (tw_pt - exit_pt).normalized() if tw_pt.distance_squared_to(exit_pt) > 0.01 else Vector2(0.0, 1.0)
	var right := Vector2(-fwd.y, fwd.x)
	var yaw_out := _yaw_toward(src_pt, tw_pt)

	var types := _roll_wave_types(rng, theme, skind, count)
	var bay: Dictionary = source_def.get("bay", {}) if source_def.get("bay") is Dictionary else {}
	var slots: Array[Dictionary] = []
	if not bay.is_empty():
		var heavies := 0
		for i in types.size():
			if types[i] in BayFormation.HEAVY:
				heavies += 1
				if heavies > BAY_HEAVY_MAX:
					types[i] = "strider_breacher"
		slots = BayFormation.layout(bay, types, rng)
		var fit: Array[String] = []
		for sl: Dictionary in slots:
			fit.append(str(sl["kind"]))
		pending += types.size() - fit.size()
		types = fit
		if types.is_empty():
			return {"specs": specs, "total_units": total_units, "spawn_count": 0, "pending": pending}
	var used: Array[Vector2] = []
	var trooper_idx := 0
	var ft_gid := "%s_ft_%d" % [wave_id, already_spawned]
	for i in types.size():
		var tid := types[i]
		var is_air := tid in ["drone", "gunship"]
		var clear_r := TANK_CLEAR if tid == "tank" else (GUNSHIP_CLEAR if tid == "gunship" else (DRONE_CLEAR if tid == "drone" else (TROOP_CLEAR if tid.begins_with("trooper_") else STRIDER_CLEAR)))
		var h := (GUNSHIP_CRUISE_ALT if tid == "gunship" else (DRONE_CRUISE_ALT if tid == "drone" else CityPlan.CURB_H))
		var row := i / 3
		var col := (i % 3) - 1
		var pt: Vector2
		if not slots.is_empty():
			pt = slots[i]["arc"]
			if is_air:
				h = CityPlan.CURB_H + float(slots[i]["h"])
		elif in_recess:
			# Hidden gate recess behind the boundary wall (MissionWorld.source_point): keep inside the recess!
			pt = src_pt + right * (float(col) * 2.2) - fwd * (float(row) * 2.4)
		else:
			var want := src_pt + fwd * (2.5 + float(row) * 4.5) + right * (float(col) * 3.8)
			pt = _snap_wave_point(plan, want, src_pt, fwd, right, clear_r, h if is_air else 0.0, used) if plan != null else want
		used.append(pt)
		var walk_out: Array = [exit_pt, tw_pt] if in_recess else [tw_pt]
		var sp := {
			"id": "%s_%02d" % [wave_id, already_spawned + i + 1],
			"type": tid, "x": pt.x, "s": pt.y, "h": h, "yaw_arc": yaw_out,
			"pocket": "wave_" + wave_id, "patrol": walk_out, "wave": wave_id,
			"defend_target_id": defend_id,
		}
		if not slots.is_empty():
			var cruise := CityPlan.CURB_H + (GUNSHIP_CRUISE_ALT if tid == "gunship" else DRONE_CRUISE_ALT)
			sp["staged"] = true
			sp["exit"] = BayFormation.exit_path(bay, slots[i], cruise, CityPlan.CURB_H)
			sp["exit_wait"] = BayFormation.exit_wait(slots[i])
		if tid.begins_with("trooper_"):
			sp["squad_group"] = ft_gid
			sp["squad_anchor"] = exit_pt + fwd * 4.0
			sp["member_idx"] = trooper_idx
			sp["on_roof"] = false
			trooper_idx += 1
		specs.append(sp)
	return {"specs": specs, "total_units": total_units, "spawn_count": specs.size(), "pending": pending}


## Engine host-loop contract (scripts/game/mission_flow.gd `_spawn_wave`, docs/design/mission-objectives.md §9):
## Called once per order when the shared clock reaches `order.open_at` (the door has just opened):
##   order  = {wave, deck, source, open_at, max_units}
##   wave   = MissionPlan pool wave {id, share, theme, source, trigger}
##   source = plan.source(order.source) + optional "point": MissionWorld.source_point(id) {deck, x, s}
##   ctx    = {stack: CityStack, world: CombatWorld, squad: EnemySquad, seed: int, crew: int, pool: Dictionary}
##            (optional overrides for tests: plan, ring, budget, skip_meshes, respect_open_at)
## Creates at most `order.max_units` (and `source.load`) units now at `source.point` (or `source`), sized from
## `budget * (1 - pool.garrison) * wave.share * WAVE_POOL_SCALE` (min 2), tagged with `e.wave = order.wave`, `e.spawn_deck = order.deck`,

## and `e.defend_target_id` (for defend waves), added to `ctx.squad` (streamed by EnemySync), arriving hunting.
## Returns the number of units of that wave STILL TO SPAWN (0 when complete; follow-up orders call again).
static func spawn_wave(order: Dictionary, wave: Dictionary, source: Dictionary, ctx: Dictionary) -> int:
	var squad := ctx.get("squad") as EnemySquad
	if squad == null or not Net.is_host():
		return 0
	var deck := int(order.get("deck", source.get("deck", 0)))
	var stack: Variant = ctx.get("stack", null)
	var d_plan: CityPlan = ctx.get("plan") as CityPlan
	if d_plan == null and stack != null and deck >= 0 and deck < stack.decks.size():
		d_plan = stack.decks[deck].plan
	if d_plan == null:
		d_plan = squad.deck_plan(deck)
	var d_ring: RingFrame = ctx.get("ring") as RingFrame
	if d_ring == null and stack != null:
		d_ring = stack.deck_ring(deck)
	if d_ring == null:
		d_ring = squad.ring
	var crew := int(ctx.get("crew", 1))
	var budget := int(ctx.get("budget", deck_budget(crew, deck)))
	var pool_dict: Dictionary = ctx.get("pool", {}) as Dictionary
	var wave_pool_share := clampf(1.0 - float(pool_dict.get("garrison", 0.5)), 0.0, 1.0) if not pool_dict.is_empty() else 1.0
	var seed_v := int(ctx.get("seed", 1))
	var skip_meshes := bool(ctx.get("skip_meshes", false))
	var respect_open := bool(ctx.get("respect_open_at", false))
	if respect_open:
		var qres := squad.queue_wave(order, wave, source, budget, d_plan, d_ring, seed_v, skip_meshes, wave_pool_share)
		return int(qres.get("pending", 0))
	return squad.spawn_wave_now(order, wave, source, budget, d_plan, d_ring, seed_v, skip_meshes, wave_pool_share)


static func _roll_wave_types(rng: RandomNumberGenerator, theme: String, source_kind: String, count: int) -> Array[String]:
	var out: Array[String] = []
	var can_tank := source_kind in ["gate", "ramp"]
	var can_air := source_kind in ["gate", "shaft"]
	var left := count
	if source_kind == "shaft":
		# Shaft waves favor aerial drones/gunships and jump-capable exo-troopers / light striders.
		if left >= 1 and theme != "light" and rng.randf() < 0.6:
			out.append("gunship")
			left -= 1
		elif left >= 1 and rng.randf() < 0.5:
			out.append("drone")
			left -= 1
		if left >= 3:
			var comp := EnemyTroopSquad.roll_composition(rng, "light", false, mini(left, 4))
			out.append_array(comp)
			left -= comp.size()
		while left > 0:
			out.append("strider_breacher" if rng.randf() < 0.5 else "trooper_rifle")
			left -= 1
		return out
	match theme:
		"heavy":
			if can_tank and left >= 1:
				out.append("tank")
				left -= 1
			if can_air and left >= 2 and rng.randf() < 0.55:
				out.append("gunship")
				left -= 1
			if left >= 3:
				var comp := EnemyTroopSquad.roll_composition(rng, "medium", false, mini(left, 4))
				out.append_array(comp)
				left -= comp.size()
			while left > 0:
				out.append("strider_breacher" if rng.randf() < 0.6 else "trooper_at")
				left -= 1
		"light":
			if left >= 3 and rng.randf() < 0.65:
				var comp := EnemyTroopSquad.roll_composition(rng, "light", false, mini(left, 3))
				out.append_array(comp)
				left -= comp.size()
			while left > 0:
				var r := rng.randf()
				if can_air and r < 0.25 and not ("drone" in out):
					out.append("drone")
				elif r < 0.62:
					out.append("strider")
				else:
					out.append("strider_breacher")
				left -= 1
		_:
			# "mixed"
			if left >= 3:
				var comp := EnemyTroopSquad.roll_composition(rng, "light", false, mini(left, 3))
				out.append_array(comp)
				left -= comp.size()
			if can_air and left >= 1 and rng.randf() < 0.4:
				out.append("gunship" if rng.randf() < 0.55 else "drone")
				left -= 1
			while left > 0:
				out.append("strider_breacher" if rng.randf() < 0.5 else "strider")
				left -= 1
	return out


static func _snap_wave_point(plan: CityPlan, want: Vector2, src_pt: Vector2, fwd: Vector2, right: Vector2,
		clear_r: float, height_h: float, used: Array[Vector2]) -> Vector2:
	var cands: Array[Vector2] = [want, src_pt + fwd * 3.0, src_pt + fwd * 6.0, src_pt]
	for d: float in [4.0, 8.0, 12.0, 16.0, 22.0]:
		cands.append(want + fwd * d)
		cands.append(src_pt + fwd * d)
		cands.append(src_pt + fwd * d + right * 4.0)
		cands.append(src_pt + fwd * d - right * 4.0)
		cands.append(want + right * d)
		cands.append(want - right * d)
	var check_ramps := height_h <= 1.0
	for cand in cands:
		if not _clear_of(cand, used, maxf(clear_r * 1.4, 2.8)):
			continue
		if clear_of_buildings(plan, cand, clear_r, height_h) and (not check_ramps or _clear_of_ramps(plan, cand, clear_r)):
			return cand
	# Relax inter-unit spacing if source doorway is narrow.
	for cand in cands:
		if clear_of_buildings(plan, cand, minf(clear_r, 1.5), height_h) and (not check_ramps or _clear_of_ramps(plan, cand, 0.8)):
			return cand
	for cand in cands:
		if clear_of_buildings(plan, cand, minf(clear_r, 1.5), height_h):
			return cand
	return _clamp_arc(plan, src_pt)


# --- Enemy Factory & Geometry Helpers ---------------------------------------------------------------------

static func make_enemy(type_id: String) -> EnemyBase:
	match type_id:
		"turret", "turret_sniper", "turret_missile": return EnemyTurret.new()
		"strider", "strider_breacher": return EnemyStrider.new()
		"tank": return EnemyTank.new()
		"drone": return EnemyDrone.new()
		"trooper_rifle", "trooper_at": return EnemyTrooper.new()
		"gunship": return EnemyGunship.new()
		"dropship": return EnemyDropDrone.new()
	return EnemyTurret.new()


## True when arc point `pt` at elevation `height_h` does not overlap any building tier, pillar core, column,
## floor cut, or boundary wall.
static func clear_of_buildings(plan: CityPlan, pt: Vector2, radius: float, height_h: float = 0.0) -> bool:
	if not plan.extent.grow(-maxf(radius + 1.5, 4.0)).has_point(pt):
		return false
	for b: Dictionary in plan.buildings:
		var c: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			if height_h >= float(t["y1"]) + CityPlan.CURB_H - 0.15:
				continue
			var tc := c + (t["off"] as Vector2)
			var half := (t["size"] as Vector2) * 0.5 + Vector2.ONE * radius
			if absf(pt.x - tc.x) < half.x and absf(pt.y - tc.y) < half.y:
				return false
		if bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var cc := Vector2(float(core["x"]), float(core["s"]))
			var ch := (core["size"] as Vector2) * 0.5 + Vector2.ONE * radius
			if absf(pt.x - cc.x) < ch.x and absf(pt.y - cc.y) < ch.y:
				return false
	for col: Dictionary in plan.columns:
		var cc := Vector2(float(col["x"]), float(col["s"]))
		var ch := float(col["half"]) + radius
		if absf(pt.x - cc.x) < ch and absf(pt.y - cc.y) < ch:
			return false
	if plan.site != null:
		for o: Rect2 in plan.floor_cuts():
			if o.grow(radius + 0.6).has_point(pt):
				return false
	return true


static func _clear_of_ramps(plan: CityPlan, pt: Vector2, radius: float) -> bool:
	var margin := radius + 1.0
	for r: Dictionary in plan.ramps:
		var s0 := minf(float(r["s_top"]), float(r["s_foot"]))
		var s1 := maxf(float(r["s_top"]), float(r["s_foot"]))
		if Rect2(float(r["x0"]), s0, float(r["x1"]) - float(r["x0"]), s1 - s0).grow(margin).has_point(pt):
			return false
	return true


static func _safe_point(pt: Vector2, safe_arc: Vector2, p2: Vector2, safe_r: float) -> bool:
	return pt.distance_to(safe_arc) >= safe_r and pt.distance_to(p2) >= SPAWN_SAFE_RADIUS


static func _lane_x(plan: CityPlan) -> float:
	var av := plan.avenue_x()
	return (av.x + av.y) * 0.5


static func _clamp_arc(plan: CityPlan, pt: Vector2) -> Vector2:
	var ext := plan.extent.grow(-10.0)
	return Vector2(clampf(pt.x, ext.position.x, ext.end.x), clampf(pt.y, ext.position.y, ext.end.y))


static func _weight_rank(w: String) -> int:
	match w:
		"heavy": return 3
		"medium": return 2
		_: return 1


## Largest-remainder budget allocation across active encounter sites proportional to `site["share"]`.
static func _allocate_site_counts(sites: Array[Dictionary], total_units: int) -> Array[int]:
	var n := sites.size()
	var out: Array[int] = []
	out.resize(n)
	out.fill(0)
	if n == 0 or total_units <= 0:
		return out
	var sum_w := 0.0
	for s in sites:
		sum_w += maxf(float(s.get("share", 0.0)), 0.001)
	var rem: Array[Dictionary] = []
	var assigned := 0
	for i in n:
		var exact := float(total_units) * maxf(float(sites[i].get("share", 0.0)), 0.001) / sum_w
		var whole := int(floor(exact))
		out[i] = whole
		assigned += whole
		rem.append({"i": i, "frac": exact - float(whole), "w": _weight_rank(str(sites[i].get("weight", "light")))})
	rem.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["frac"]) - float(b["frac"])) > 1e-5:
			return float(a["frac"]) > float(b["frac"])
		return int(a["w"]) > int(b["w"]))
	var left := total_units - assigned
	var ri := 0
	while left > 0 and not rem.is_empty():
		out[int(rem[ri % rem.size()]["i"])] += 1
		left -= 1
		ri += 1
	return out


## Synthesize 5 well-spread sites across a standalone CityPlan when no SectionPlan is present.
static func _standalone_sites(plan: CityPlan, p2: Vector2, lane: float) -> Array[Dictionary]:
	var ext := plan.extent.grow(-18.0)
	var span_s := maxf(ext.size.y, 120.0)
	var dir_s := 1.0 if (ext.end.y - p2.y) >= (p2.y - ext.position.y) else -1.0
	var s1 := clampf(p2.y + dir_s * minf(68.0, span_s * 0.30), ext.position.y, ext.end.y)
	var s2 := clampf(p2.y + dir_s * minf(115.0, span_s * 0.55), ext.position.y, ext.end.y)
	var s3 := clampf(p2.y + dir_s * minf(165.0, span_s * 0.82), ext.position.y, ext.end.y)
	var x_left := clampf(lane - ext.size.x * 0.28, ext.position.x, ext.end.x)
	var x_right := clampf(lane + ext.size.x * 0.28, ext.position.x, ext.end.x)
	return [
		{"kind": "first_contact", "x": lane, "s": s1, "progress": 0.25, "weight": "light", "share": 0.14, "safe": false},
		{"kind": "patrol", "x": x_left, "s": s2, "progress": 0.50, "weight": "light", "share": 0.14, "safe": false},
		{"kind": "holding", "x": x_right, "s": s2, "progress": 0.55, "weight": "medium", "share": 0.22, "safe": false},
		{"kind": "checkpoint", "x": lane, "s": s2, "progress": 0.65, "weight": "medium", "share": 0.18, "safe": false},
		{"kind": "departure", "x": lane, "s": s3, "progress": 1.0, "weight": "heavy", "share": 0.32, "safe": false},
	]


static func _place_roof_turret(out: Array[Dictionary], plan: CityPlan, roof_cands: Array[Dictionary],
		used: Array[Vector2], next_id: Array, near_pt: Vector2, safe_arc: Vector2, p2: Vector2,
		safe_r: float, ttype: String, pocket: String, rng: RandomNumberGenerator) -> bool:
	var roof := _pick_roof_near(plan, roof_cands, used, near_pt, safe_arc, p2, safe_r, 68.0, rng)
	if roof.is_empty():
		roof = _pick_roof_near(plan, roof_cands, used, near_pt, safe_arc, p2, safe_r, 115.0, rng)
	if roof.is_empty():
		return false
	var rp := Vector2(float(roof["x"]), float(roof["s"]))
	var sp := _spec(next_id, ttype, rp.x, rp.y, float(roof["h"]), _yaw_toward(safe_arc, rp), pocket)
	sp["b_center"] = roof["b_center"]
	sp["t_off"] = roof["t_off"]
	sp["t_y1"] = roof["t_y1"]
	out.append(sp)
	used.append(rp)
	return true


static func _place_air_unit(out: Array[Dictionary], plan: CityPlan, used: Array[Vector2], next_id: Array,
		near_pt: Vector2, safe_arc: Vector2, p2: Vector2, safe_r: float, atype: String, lane: float,
		pocket: String, site: Dictionary) -> bool:
	var clear_r := GUNSHIP_CLEAR if atype == "gunship" else DRONE_CLEAR
	var alt := GUNSHIP_CRUISE_ALT if atype == "gunship" else DRONE_CRUISE_ALT
	var pt := _find_clear_air_near(plan, near_pt, used, safe_arc, p2, safe_r, clear_r, alt)
	if is_nan(pt.x):
		return false
	var loop := _loop_from_site(plan, site, pt, null) if site.has("loop") else _drone_patrol_loop(plan, pt, lane)
	out.append(_spec(next_id, atype, pt.x, pt.y, alt, _yaw_toward(safe_arc, pt), pocket, loop))
	used.append(pt)
	return true


static func _place_trooper_fireteam(out: Array[Dictionary], plan: CityPlan, roof_cands: Array[Dictionary],
		used: Array[Vector2], next_id: Array, sq_seq: Array, near_pt: Vector2, safe_arc: Vector2, p2: Vector2,
		safe_r: float, weight: String, try_roof: bool, max_units: int, pocket: String,
		rng: RandomNumberGenerator) -> int:
	var comp := EnemyTroopSquad.roll_composition(rng, weight, try_roof, max_units)
	if comp.is_empty():
		return 0
	var gid := "sq_%02d" % int(sq_seq[0])
	sq_seq[0] = int(sq_seq[0]) + 1
	if try_roof:
		var low_roofs := roof_cands.filter(func(c: Dictionary) -> bool: return float(c["t_y1"]) <= 13.5)
		var roof := _pick_roof_near(plan, low_roofs if not low_roofs.is_empty() else roof_cands, used, near_pt, safe_arc, p2, safe_r, 75.0, rng)
		if not roof.is_empty():
			var bc: Vector2 = roof["b_center"]
			var toff: Vector2 = roof["t_off"]
			var tsz: Vector2 = roof["t_size"]
			var ty1 := float(roof["t_y1"])
			var h := float(roof["h"])
			var half_span := clampf(minf(tsz.x, tsz.y) * 0.5 - 1.0, 2.0, 7.0)
			var offs := EnemyTroopSquad.member_arc_offsets(rng, comp.size(), true, half_span)
			var placed := 0
			var roof_center := bc + toff
			for i in comp.size():
				var moff := toff + Vector2(clampf(offs[i].x, -tsz.x * 0.42, tsz.x * 0.42), clampf(offs[i].y, -tsz.y * 0.42, tsz.y * 0.42))
				var mpt := bc + moff
				if not clear_of_buildings(plan, mpt, 1.3, h + 0.2):
					mpt = roof_center
					moff = toff
				var sp := _spec(next_id, comp[i], mpt.x, mpt.y, h, _yaw_toward(safe_arc, mpt), pocket)
				sp["b_center"] = bc
				sp["t_off"] = moff
				sp["t_y1"] = ty1
				sp["squad_group"] = gid
				sp["squad_anchor"] = roof_center
				sp["member_idx"] = i
				sp["on_roof"] = true
				out.append(sp)
				placed += 1
			used.append(roof_center)
			return placed
	# Ground fireteam: pick an open anchor near `near_pt`, then fan each trooper to its own validated ground spot!
	var anchor := _find_clear_ground_near(plan, near_pt, TROOP_CLEAR + 0.6, used, 10.0, safe_arc, p2, safe_r)
	if is_nan(anchor.x):
		return 0
	var offs := EnemyTroopSquad.member_arc_offsets(rng, comp.size(), false, 7.0)
	var team_used: Array[Vector2] = []
	var placed := 0
	for i in comp.size():
		var want := anchor + offs[i]
		var mpt := _find_clear_ground_near(plan, want, TROOP_CLEAR, team_used, 2.8, safe_arc, p2, safe_r, 18.0)
		if is_nan(mpt.x):
			mpt = anchor
		var sp := _spec(next_id, comp[i], mpt.x, mpt.y, CityPlan.CURB_H, _yaw_toward(safe_arc, mpt), pocket)
		sp["squad_group"] = gid
		sp["squad_anchor"] = anchor
		sp["member_idx"] = i
		sp["on_roof"] = false
		out.append(sp)
		team_used.append(mpt)
		placed += 1
	used.append(anchor)
	return placed


static func _find_clear_ground(plan: CityPlan, want: Vector2, radius: float, used: Array[Vector2],
		min_sep: float, p2: Vector2) -> Vector2:
	return _find_clear_ground_near(plan, want, radius, used, min_sep, p2, p2, SPAWN_SAFE_RADIUS)


static func _find_clear_ground_near(plan: CityPlan, want: Vector2, radius: float, used: Array[Vector2],
		min_sep: float, safe_arc: Vector2, p2: Vector2, safe_r: float, max_search: float = 44.0) -> Vector2:
	var rings: Array[float] = [0.0, 5.0, 10.0, 16.0, 24.0, 34.0, 44.0]
	var dirs: Array[Vector2] = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(0.707, 0.707), Vector2(-0.707, 0.707), Vector2(0.707, -0.707), Vector2(-0.707, -0.707),
	]
	for rad in rings:
		if rad > max_search:
			break
		if rad <= 0.01:
			if _ground_spot_ok(plan, want, radius, used, min_sep, safe_arc, p2, safe_r):
				return want
			continue
		for d in dirs:
			var cand := want + d * rad
			if _ground_spot_ok(plan, cand, radius, used, min_sep, safe_arc, p2, safe_r):
				return cand
	# Fallback: nearest clear road crossing or open plaza to `want` outside the safe bubble.
	var best := Vector2(NAN, NAN)
	var best_d := INF
	var rg := plan.road_graph()
	for n: Vector2 in rg["nodes"]:
		var d := n.distance_to(want)
		if d < best_d and _ground_spot_ok(plan, n, radius, used, min_sep, safe_arc, p2, safe_r):
			best_d = d
			best = n
	return best


static func _ground_spot_ok(plan: CityPlan, cand: Vector2, radius: float, used: Array[Vector2],
		min_sep: float, safe_arc: Vector2, p2: Vector2, safe_r: float) -> bool:
	if not _safe_point(cand, safe_arc, p2, safe_r):
		return false
	if not _clear_of(cand, used, min_sep):
		return false
	if plan.site != null and not plan.clear_at(cand):
		return false
	if not _clear_of_ramps(plan, cand, radius):
		return false
	return clear_of_buildings(plan, cand, radius, 0.0)


static func _find_clear_air_near(plan: CityPlan, want: Vector2, used: Array[Vector2], safe_arc: Vector2,
		p2: Vector2, safe_r: float, clear_r: float, alt: float) -> Vector2:
	var cands: Array[Vector2] = [want]
	for rad: float in [10.0, 20.0, 32.0, 48.0]:
		cands.append(want + Vector2(rad, 0.0))
		cands.append(want + Vector2(-rad, 0.0))
		cands.append(want + Vector2(0.0, rad))
		cands.append(want + Vector2(0.0, -rad))
	var lane := _lane_x(plan)
	for rs: Dictionary in plan.roads_s:
		cands.append(Vector2(lane, (float(rs["a"]) + float(rs["b"])) * 0.5))
	for cand in cands:
		if not _safe_point(cand, safe_arc, p2, safe_r):
			continue
		if not _clear_of(cand, used, 10.0):
			continue
		if clear_of_buildings(plan, cand, clear_r, alt):
			return cand
	return Vector2(NAN, NAN)


static func _loop_from_site(plan: CityPlan, site: Dictionary, start: Vector2, rng: RandomNumberGenerator) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if site.has("loop") and site["loop"] is Array and not (site["loop"] as Array).is_empty():
		for pt: Variant in site["loop"]:
			if pt is Vector2:
				out.append(_clamp_arc(plan, pt as Vector2))
			elif pt is Dictionary and (pt as Dictionary).has("x") and (pt as Dictionary).has("s"):
				out.append(_clamp_arc(plan, Vector2(float(pt["x"]), float(pt["s"]))))
	if out.size() >= 2:
		return out
	return _short_patrol(plan, start, rng)


static func _short_patrol(plan: CityPlan, start: Vector2, rng: RandomNumberGenerator) -> Array[Vector2]:
	var dx := 14.0 if (rng == null or rng.randi() % 2 == 0) else -14.0
	var ds := 14.0 if (rng == null or rng.randi() % 2 == 0) else -14.0
	return [
		_clamp_arc(plan, start),
		_clamp_arc(plan, start + Vector2(dx, 0.0)),
		_clamp_arc(plan, start + Vector2(dx, ds)),
	]


static func _drone_patrol_loop(plan: CityPlan, start: Vector2, lane: float) -> Array[Vector2]:
	var ext := plan.extent.grow(-16.0)
	var x_lo := clampf(minf(start.x, lane) - 22.0, ext.position.x, ext.end.x)
	var x_hi := clampf(maxf(start.x, lane) + 22.0, ext.position.x, ext.end.x)
	var s_lo := clampf(start.y - 24.0, ext.position.y, ext.end.y)
	var s_hi := clampf(start.y + 28.0, ext.position.y, ext.end.y)
	return [
		Vector2(clampf(start.x, ext.position.x, ext.end.x), clampf(start.y, ext.position.y, ext.end.y)),
		Vector2(x_hi, s_hi),
		Vector2(x_lo, s_hi),
		Vector2(x_lo, s_lo),
	]


static func _spec(next_id: Array, type_id: String, x: float, s: float, h: float, yaw_arc: float,
		pocket: String, patrol: Array = []) -> Dictionary:
	var n := int(next_id[0])
	next_id[0] = n + 1
	return {"id": "%s_%02d" % [type_id, n], "type": type_id, "x": x, "s": s, "h": h, "yaw_arc": yaw_arc,
		"pocket": pocket, "patrol": patrol}


static func _rooftop_candidates(plan: CityPlan, lane: float = 0.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var sight := _roof_sight_context(plan)   # shared by every candidate (one reference), read lazily
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if bool(b.get("pillar", false)):
			continue
		var c: Vector2 = b["center"]
		var best_tier := {}
		for t: Dictionary in b.get("tiers", []):
			if not bool(t.get("stand", false)) or str(t.get("kind", "")) == "plant":
				continue
			var sz: Vector2 = t["size"]
			var y1 := float(t["y1"])
			if minf(sz.x, sz.y) >= MIN_ROOF_SPAN and y1 >= 6.0 and y1 <= 22.0:
				if best_tier.is_empty() or y1 > float(best_tier["y1"]):
					best_tier = t
		if not best_tier.is_empty():
			var off: Vector2 = best_tier["off"]
			var pos := c + off
			var h := float(best_tier["y1"]) + CityPlan.CURB_H
			out.append({"x": pos.x, "s": pos.y, "h": h, "near_ave": absf(pos.x - lane) < 36.0,
				"b_center": c, "t_off": off, "t_y1": float(best_tier["y1"]), "t_size": best_tier["size"], "sight": sight})
	return out


## Street sight for rooftop units (turrets, roof fireteams): a stationary unit on a roof that no street point can see
## keeps a sweep open until a crew climbs a roof (seed 5 deck 1: a sniper turret on a 13 m roof that 17 street points
## 15-170 m away could not see, 172 s of a sweep spent on it). Street points: the walk graph's nodes and edge midpoints
## (where a mech walks); occluders: every building tier >= 2.5 m and pillar cores, as boxes from the plan (no physics).
static func _roof_sight_context(plan: CityPlan) -> Dictionary:
	var pts: Array[Vector2] = []
	var rg: Dictionary = plan.walk_graph() if plan.has_method("walk_graph") else plan.road_graph()
	var nodes: Array = rg["nodes"]
	for n: Vector2 in nodes:
		pts.append(n)
	for ed: Array in rg["edges"]:
		pts.append(((nodes[int(ed[0])] as Vector2) + (nodes[int(ed[1])] as Vector2)) * 0.5)
	var rects: Array[Rect2] = []
	var tops: PackedFloat32Array = []
	for b: Dictionary in plan.buildings:
		var bc: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			var y1 := float(t["y1"])
			if y1 < 2.5:
				continue
			var sz: Vector2 = t["size"]
			rects.append(Rect2(bc + (t["off"] as Vector2) - sz * 0.5, sz))
			tops.append(y1 + CityPlan.CURB_H)
		if bool(b.get("pillar", false)):
			var core: Dictionary = b["core"]
			var csz: Vector2 = core["size"]
			rects.append(Rect2(Vector2(float(core["x"]), float(core["s"])) - csz * 0.5, csz))
			tops.append(999.0)
	return {"pts": pts, "rects": rects, "tops": tops}


## True when at least ROOF_SIGHT_POINTS street points ROOF_SIGHT_MIN-ROOF_SIGHT_R m from a rooftop candidate see a mech's
## weapon height (ROOF_SIGHT_EYE) to the unit's body (ROOF_SIGHT_AIM above the roof). Cached in the candidate. A candidate
## without sight data (built elsewhere) passes.
static func roof_seen_from_street(c: Dictionary) -> bool:
	if c.has("seen"):
		return bool(c["seen"])
	var ctx: Dictionary = c.get("sight", {})
	if ctx.is_empty():
		return true
	var at := Vector2(float(c["x"]), float(c["s"]))
	var aim_h := float(c["h"]) + ROOF_SIGHT_AIM
	var near_r: Array[Rect2] = []
	var near_t: PackedFloat32Array = []
	var area := Rect2(at - Vector2.ONE * ROOF_SIGHT_R, Vector2.ONE * ROOF_SIGHT_R * 2.0)
	var rects: Array[Rect2] = ctx["rects"]
	var tops: PackedFloat32Array = ctx["tops"]
	for i in rects.size():
		if area.intersects(rects[i]):
			near_r.append(rects[i])
			near_t.append(tops[i])
	var cand: Array = []
	for p: Vector2 in ctx["pts"]:
		var d := p.distance_to(at)
		if d >= ROOF_SIGHT_MIN and d <= ROOF_SIGHT_R:
			cand.append([d, p])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var seen := 0
	for e: Array in cand:
		if _street_line_clear(e[1] as Vector2, CityPlan.CURB_H + ROOF_SIGHT_EYE, at, aim_h, near_r, near_t):
			seen += 1
			if seen >= ROOF_SIGHT_POINTS:
				break
	c["seen"] = seen >= ROOF_SIGHT_POINTS
	return bool(c["seen"])


## The 3D segment (a, ha) -> (b, hb) over the arc plane passes above every box (rect, top). The segment rises toward b
## (hb > ha for a rooftop target), so inside a box its lowest point is where it enters: compare that with the top.
static func _street_line_clear(a: Vector2, ha: float, b: Vector2, hb: float, rects: Array[Rect2],
		tops: PackedFloat32Array) -> bool:
	var dvec := b - a
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	for i in rects.size():
		var r := rects[i]
		if r.end.x < lo.x or r.position.x > hi.x or r.end.y < lo.y or r.position.y > hi.y:
			continue
		var t0 := 0.0
		var t1 := 1.0
		var ok := true
		for ax in 2:
			var p0 := a.x if ax == 0 else a.y
			var dv := dvec.x if ax == 0 else dvec.y
			var mn := r.position.x if ax == 0 else r.position.y
			var mx := r.end.x if ax == 0 else r.end.y
			if absf(dv) < 1e-6:
				if p0 < mn or p0 > mx:
					ok = false
					break
				continue
			var ta := (mn - p0) / dv
			var tb := (mx - p0) / dv
			if ta > tb:
				var tmp := ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				ok = false
				break
		if not ok:
			continue
		var h_low := lerpf(ha, hb, t0) if hb >= ha else lerpf(ha, hb, t1)
		if h_low < tops[i]:
			return false
	return true


static func _pick_roof_near(plan: CityPlan, cands: Array[Dictionary], used: Array[Vector2], near_pt: Vector2,
		safe_arc: Vector2, p2: Vector2, safe_r: float, max_dist: float, rng: RandomNumberGenerator) -> Dictionary:
	var pool: Array[Dictionary] = []
	for c: Dictionary in cands:
		var pt := Vector2(float(c["x"]), float(c["s"]))
		if pt.distance_to(near_pt) > max_dist:
			continue
		if not _safe_point(pt, safe_arc, p2, safe_r):
			continue
		if not _clear_of(pt, used, 18.0):
			continue
		if not clear_of_buildings(plan, pt, TURRET_CLEAR, float(c["h"]) + 0.2):
			continue
		if not roof_seen_from_street(c):
			continue
		pool.append(c)
	if pool.is_empty():
		return {}
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Vector2(float(a["x"]), float(a["s"])).distance_squared_to(near_pt) \
			< Vector2(float(b["x"]), float(b["s"])).distance_squared_to(near_pt))
	return pool[rng.randi_range(0, mini(pool.size() - 1, 2))]


static func _clear_of(pt: Vector2, used: Array[Vector2], min_d: float) -> bool:
	for u in used:
		if pt.distance_to(u) < min_d:
			return false
	return true


static func _yaw_toward(from_arc: Vector2, to_arc: Vector2) -> float:
	var d := to_arc - from_arc
	if d.length_squared() < 1e-4:
		return PI
	return atan2(d.x, d.y)
