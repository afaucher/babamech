class_name EnemySpawner
extends RefCounted
## Deterministic seeded enemy encounter placement on a CityPlan + RingFrame (docs/design/enemies.md §6).
## Every spawn is validated against SPAWN_SAFE_RADIUS and CityPlan building tiers/pillars/columns (`clear_of_buildings`).
## No global randomness (AGENTS.md rule 4).

const SPAWN_SAFE_RADIUS := 48.0    ## m around player spawn kept clear so you aren't ambushed on frame 0
const MIN_ROOF_SPAN := 7.0         ## m minimum roof tier width/length for a 4.8 m Enforcer Turret
const STRIDER_CLEAR := 2.2         ## m ground clearance radius for Hound Skirmisher
const TANK_CLEAR := 3.8            ## m ground clearance radius for Bastion Siege Tank
const TURRET_CLEAR := 2.5          ## m clearance radius for Enforcer Turret on rooftops


## Compute deterministic spawn specs (4–5 well-spaced enemies solo; scaled cleanly for 2–4 player co-op crews).
static func plan_encounters(plan: CityPlan, ring: RingFrame, player_spawn: Vector3, crew_size: int = 1) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if plan == null or ring == null:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([plan.checksum(), "enemies_v2"])
	var p_arc := ring.world_to_arc(player_spawn)
	var p2 := Vector2(p_arc.x, p_arc.y)
	var used_spots: Array[Vector2] = [p2]
	var next_id := [1]

	# 1. Avenue Scout (1 Hound Skirmisher ~54 m ahead, patrolling AWAY/ACROSS the avenue so it doesn't shoot on frame 0).
	var s_skirm := clampf(p_arc.y + 54.0, plan.extent.position.y + 18.0, plan.extent.end.y - 22.0)
	var x_skirm := -4.0 if rng.randi() % 2 == 0 else 4.0
	var sk_pt := _find_clear_ground(plan, Vector2(x_skirm, s_skirm), STRIDER_CLEAR, used_spots, 12.0, p2)
	if not is_nan(sk_pt.x):
		var p_a := Vector2(-5.5, minf(sk_pt.y + 14.0, plan.extent.end.y - 14.0))
		var p_b := Vector2(5.5, minf(sk_pt.y + 14.0, plan.extent.end.y - 14.0))
		var p_c := Vector2(5.5, sk_pt.y)
		# Face away down +s (yaw 0.0) so the player sees it first and chooses when to engage.
		out.append(_spec(next_id, "strider", sk_pt.x, sk_pt.y, 0.0, 0.0, "vanguard", [p_a, p_b, p_c]))
		used_spots.append(sk_pt)

	# 2. Mid-District Rooftop Turret (1 Enforcer Turret overlooking a mid-avenue / park sector, facing perpendicular/away).
	var roof_cands := _rooftop_candidates(plan)
	var ave_roof := _pick_roof(plan, roof_cands, used_spots, p2, 62.0, 110.0, true, rng)
	if ave_roof.is_empty():
		ave_roof = _pick_roof(plan, roof_cands, used_spots, p2, SPAWN_SAFE_RADIUS, 130.0, false, rng)
	if not ave_roof.is_empty():
		var rp := Vector2(float(ave_roof["x"]), float(ave_roof["s"]))
		var away_yaw := _yaw_toward(p2, rp) + (PI * 0.35 if rp.x >= 0.0 else -PI * 0.35)
		var sp := _spec(next_id, "turret", rp.x, rp.y, float(ave_roof["h"]), away_yaw, "vanguard_roof")
		sp["b_center"] = ave_roof["b_center"]
		sp["t_off"] = ave_roof["t_off"]
		sp["t_y1"] = ave_roof["t_y1"]
		out.append(sp)
		used_spots.append(rp)

	# 3. Far Avenue Siege Tank (1 Bastion Siege Tank anchoring a distant avenue intersection ~96 m ahead, outside patrol sight).
	var s_tank := clampf(p_arc.y + 96.0, plan.extent.position.y + 24.0, plan.extent.end.y - 20.0)
	var raw_tank := _nearest_avenue_crossing(plan, s_tank, p2)
	var tank_pt := _find_clear_ground(plan, raw_tank, TANK_CLEAR, used_spots, 22.0, p2)
	if not is_nan(tank_pt.x):
		out.append(_spec(next_id, "tank", tank_pt.x, tank_pt.y, 0.0, PI * 0.5, "vanguard_tank", [
			tank_pt, Vector2(tank_pt.x, clampf(tank_pt.y - 14.0, plan.extent.position.y + 20.0, plan.extent.end.y - 20.0)),
		]))
		used_spots.append(tank_pt)

	# 4. Distant Park / Plaza Patrol (1 Hound Skirmisher well away from spawn, >= 72 m out).
	var open_pts := _open_lot_centers(plan)
	for oi in open_pts.size():
		var c := _find_clear_ground(plan, open_pts[oi], STRIDER_CLEAR, used_spots, 28.0, p2)
		if is_nan(c.x) or c.distance_to(p2) < 72.0:
			continue
		var r := 8.0
		var patrol: Array[Vector2] = [c + Vector2(-r, -r * 0.5), c + Vector2(r, -r * 0.5), c + Vector2(r, r * 0.5), c + Vector2(-r, r * 0.5)]
		out.append(_spec(next_id, "strider", c.x, c.y, CityPlan.CURB_H, _yaw_toward(p2, c), "park_patrol", patrol))
		used_spots.append(c)
		break

	# 5. Far Flank Rooftop Overwatch (1 Enforcer Turret >= 95 m away on the far side of the district).
	var far_roof := _pick_roof(plan, roof_cands, used_spots, p2, 95.0, 175.0, false, rng)
	if not far_roof.is_empty():
		var rp := Vector2(float(far_roof["x"]), float(far_roof["s"]))
		var sp := _spec(next_id, "turret", rp.x, rp.y, float(far_roof["h"]), _yaw_toward(p2, rp), "rooftop")
		sp["b_center"] = far_roof["b_center"]
		sp["t_off"] = far_roof["t_off"]
		sp["t_y1"] = far_roof["t_y1"]
		out.append(sp)
		used_spots.append(rp)

	# Co-op crew reinforcements (crew_size >= 2): deterministic extra pockets; solo (crew_size == 1) untouched.
	var crew := clampi(crew_size, 1, 4)
	if crew >= 2:
		# Extra mid-district flanking Skirmisher + second rooftop Turret.
		var extra_sk := _find_clear_ground(plan, Vector2(-x_skirm * 2.0, clampf(p_arc.y + 68.0, plan.extent.position.y + 20.0, plan.extent.end.y - 20.0)), STRIDER_CLEAR, used_spots, 16.0, p2)
		if not is_nan(extra_sk.x):
			var pa := extra_sk + Vector2(-8.0, 8.0)
			var pb := extra_sk + Vector2(8.0, 8.0)
			out.append(_spec(next_id, "strider", extra_sk.x, extra_sk.y, 0.0, 0.0, "coop_flank", [pa, pb]))
			used_spots.append(extra_sk)
		var coop_roof := _pick_roof(plan, roof_cands, used_spots, p2, 60.0, 155.0, false, rng)
		if not coop_roof.is_empty():
			var crp := Vector2(float(coop_roof["x"]), float(coop_roof["s"]))
			var csp := _spec(next_id, "turret", crp.x, crp.y, float(coop_roof["h"]), _yaw_toward(p2, crp), "coop_roof")
			csp["b_center"] = coop_roof["b_center"]
			csp["t_off"] = coop_roof["t_off"]
			csp["t_y1"] = coop_roof["t_y1"]
			out.append(csp)
			used_spots.append(crp)
	if crew >= 3:
		# Second Bastion Siege Tank anchoring a side/far avenue sector + escort Skirmisher.
		var s_t2 := clampf(p_arc.y + 78.0, plan.extent.position.y + 24.0, plan.extent.end.y - 24.0)
		var side_x := 36.0 if rng.randi() % 2 == 0 else -36.0
		var t2_pt := _find_clear_ground(plan, Vector2(side_x, s_t2), TANK_CLEAR, used_spots, 22.0, p2)
		if is_nan(t2_pt.x):
			t2_pt = _find_clear_ground(plan, Vector2(-side_x, s_t2), TANK_CLEAR, used_spots, 22.0, p2)
		if is_nan(t2_pt.x):
			t2_pt = _find_clear_ground(plan, Vector2(0.0, clampf(p_arc.y + 124.0, plan.extent.position.y + 24.0, plan.extent.end.y - 20.0)), TANK_CLEAR, used_spots, 22.0, p2)
		if not is_nan(t2_pt.x):
			out.append(_spec(next_id, "tank", t2_pt.x, t2_pt.y, 0.0, _yaw_toward(p2, t2_pt), "coop_tank", [
				t2_pt, Vector2(t2_pt.x, clampf(t2_pt.y - 12.0, plan.extent.position.y + 20.0, plan.extent.end.y - 20.0)),
			]))
			used_spots.append(t2_pt)
		var esc_pt := _find_clear_ground(plan, Vector2(-side_x * 0.6, clampf(p_arc.y + 84.0, plan.extent.position.y + 20.0, plan.extent.end.y - 20.0)), STRIDER_CLEAR, used_spots, 16.0, p2)
		if not is_nan(esc_pt.x):
			out.append(_spec(next_id, "strider", esc_pt.x, esc_pt.y, 0.0, _yaw_toward(p2, esc_pt), "coop_escort", [
				esc_pt + Vector2(-7.0, 0.0), esc_pt + Vector2(7.0, 0.0),
			]))
			used_spots.append(esc_pt)
	if crew >= 4:
		# Fourth-player pressure: extra far rooftop overwatch turret.
		var r4 := _pick_roof(plan, roof_cands, used_spots, p2, 68.0, 175.0, false, rng)
		if not r4.is_empty():
			var r4p := Vector2(float(r4["x"]), float(r4["s"]))
			var r4sp := _spec(next_id, "turret", r4p.x, r4p.y, float(r4["h"]), _yaw_toward(p2, r4p), "coop_roof_4p")
			r4sp["b_center"] = r4["b_center"]
			r4sp["t_off"] = r4["t_off"]
			r4sp["t_y1"] = r4["t_y1"]
			out.append(r4sp)
			used_spots.append(r4p)

	return out


## Instantiate a concrete EnemyBase subclass and attach it to `squad` + `world` at its curved-deck transform.
static func spawn_all(plan: CityPlan, ring: RingFrame, player_spawn: Vector3, world: CombatWorld,
		squad: EnemySquad, mission_seed: int, auto_remove_wreck: bool = false, crew_size: int = 1) -> Array[EnemyBase]:
	var specs := plan_encounters(plan, ring, player_spawn, crew_size)
	var spawned: Array[EnemyBase] = []
	for sp: Dictionary in specs:
		var e := make_enemy(str(sp["type"]))
		e.configure(str(sp["type"]), str(sp["id"]), world, squad, ring, mission_seed)
		e.auto_remove_wreck = auto_remove_wreck
		var x := float(sp["x"])
		var s := float(sp["s"])
		var h := float(sp["h"])
		var pos := ring.arc_to_world(x, s, h)
		if sp.has("b_center"):
			# Exact building_frame roof placement (matches CityDistrict collision box to 0.00 m).
			var bc: Vector2 = sp["b_center"]
			var off: Vector2 = sp["t_off"]
			var y1 := float(sp["t_y1"])
			var bxf := Transform3D(CityGeo.frame_basis(ring, bc.y), ring.arc_to_world(bc.x, bc.y, CityPlan.CURB_H))
			pos = bxf * Vector3(off.x, y1, off.y)
		var base_b := ring.basis_at_arc(s)
		var rot := Basis(base_b.y, float(sp["yaw_arc"]))
		e.up = ring.up_at(pos)
		e.transform = Transform3D(rot * base_b, pos)
		var pat: Array = sp.get("patrol", [])
		if not pat.is_empty():
			var pts: Array[Vector2] = []
			for pt: Vector2 in pat:
				pts.append(pt)
			e.set_patrol_points(pts)
		squad.add_enemy(e)
		spawned.append(e)
	return spawned


static func make_enemy(type_id: String) -> EnemyBase:
	match type_id:
		"turret": return EnemyTurret.new()
		"strider": return EnemyStrider.new()
		"tank": return EnemyTank.new()
	return EnemyTurret.new()


## True when arc point `pt` at elevation `height_h` does not overlap any building tier, pillar core, column, or boundary wall.
static func clear_of_buildings(plan: CityPlan, pt: Vector2, radius: float, height_h: float = 0.0) -> bool:
	if not plan.extent.grow(-maxf(radius + 1.5, 4.0)).has_point(pt):
		return false
	for b: Dictionary in plan.buildings:
		var c: Vector2 = b["center"]
		for t: Dictionary in b.get("tiers", []):
			if height_h >= float(t["y1"]) + CityPlan.CURB_H - 0.15:
				continue     # standing on or above this tier
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
	return true


static func _find_clear_ground(plan: CityPlan, want: Vector2, radius: float, used: Array[Vector2],
		min_sep: float, p2: Vector2) -> Vector2:
	var offsets: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(4.0, 0.0), Vector2(-4.0, 0.0), Vector2(0.0, 4.0), Vector2(0.0, -4.0),
		Vector2(5.5, 5.5), Vector2(-5.5, 5.5), Vector2(5.5, -5.5), Vector2(-5.5, -5.5),
		Vector2(8.0, 0.0), Vector2(-8.0, 0.0), Vector2(0.0, 8.0), Vector2(0.0, -8.0),
	]
	for off in offsets:
		var cand := want + off
		if cand.distance_to(p2) < SPAWN_SAFE_RADIUS:
			continue
		if not _clear_of(cand, used, min_sep):
			continue
		if clear_of_buildings(plan, cand, radius, 0.0):
			return cand
	return Vector2(NAN, NAN)


static func _spec(next_id: Array, type_id: String, x: float, s: float, h: float, yaw_arc: float,
		pocket: String, patrol: Array = []) -> Dictionary:
	var n := int(next_id[0])
	next_id[0] = n + 1
	return {"id": "%s_%02d" % [type_id, n], "type": type_id, "x": x, "s": s, "h": h, "yaw_arc": yaw_arc,
		"pocket": pocket, "patrol": patrol}


static func _rooftop_candidates(plan: CityPlan) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
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
			out.append({"x": pos.x, "s": pos.y, "h": h, "near_ave": absf(pos.x) < 36.0,
				"b_center": c, "t_off": off, "t_y1": float(best_tier["y1"])})
	return out


static func _pick_roof(plan: CityPlan, cands: Array[Dictionary], used: Array[Vector2], p2: Vector2,
		min_d: float, max_d: float, prefer_avenue_ahead: bool, rng: RandomNumberGenerator) -> Dictionary:
	var pool: Array[Dictionary] = []
	for c: Dictionary in cands:
		var pt := Vector2(float(c["x"]), float(c["s"]))
		var h := float(c["h"])
		var d := pt.distance_to(p2)
		if d < min_d or d > max_d or not _clear_of(pt, used, 22.0):
			continue
		if not clear_of_buildings(plan, pt, TURRET_CLEAR, h + 0.2):
			continue
		if prefer_avenue_ahead and (not bool(c["near_ave"]) or pt.y < p2.y + 18.0):
			continue
		pool.append(c)
	if pool.is_empty() and prefer_avenue_ahead:
		return _pick_roof(plan, cands, used, p2, min_d, max_d + 30.0, false, rng)
	if pool.is_empty():
		return {}
	return pool[rng.randi_range(0, pool.size() - 1)]


static func _nearest_avenue_crossing(plan: CityPlan, want_s: float, p2: Vector2) -> Vector2:
	var best := Vector2(0.0, want_s)
	var best_err := INF
	for rs: Dictionary in plan.roads_s:
		var s := (float(rs["a"]) + float(rs["b"])) * 0.5
		if s < p2.y + 34.0:
			continue
		var err := absf(s - want_s)
		if err < best_err:
			best_err = err
			best = Vector2(0.0, s)
	return best


static func _open_lot_centers(plan: CityPlan) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for l: Dictionary in plan.lots:
		if str(l["kind"]) == "open" and str(l.get("open", "")) in ["park", "plaza"]:
			var r: Rect2 = l["rect"]
			if minf(r.size.x, r.size.y) >= 14.0:
				out.append(r.get_center())
	return out


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
