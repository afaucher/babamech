extends TestCase
## Full-deck Enemy Distribution (docs/design/mission-section.md §16) & Mission Waves Phase 1
## (docs/design/mission-objectives.md §5, §7, §9) verification:
##   1. Multi-seed SectionPlan distribution (seeds 1..8 x all decks):
##        * 0 enemies within 70 m safe bubble of SectionPlan.arrival(k).
##        * 0 enemies overlapping buildings, pillars, floor cuts, or ramps.
##        * Spread across full deck (high median & max distance from arrival, spanning encounter sites).
##        * garrison_share = 0.5 spawns ~half the units of garrison_share = 1.0.
##   2. Mission Waves Phase 1 end-to-end with real MissionPlan + WaveDirector + EnemySquad + EnemySpawner:
##        * EnemyBase.wave == "" for garrison, wave_id for wave units.
##        * open_at scheduling + 25 m player proximity delay hold + safety timeout release.
##        * Partial release (source.load / max_units cap) -> pending_wave_counts() -> WaveDirector follow-up order.
##        * Wave units spawn immediately hunting nearest deck mech; lift/shaft sources never spawn tanks.

const DT := 1.0 / 60.0


func setup() -> void:
	_multi_seed_full_deck_distribution()
	_rooftop_units_seen_from_street()
	await _mission_waves_end_to_end()
	await _defend_relay_targeting_and_pool_sizing()
	finish()


func _world(ring: RingFrame = null) -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 99
	w.use_physics = false
	w.ring = ring
	add_child(w)
	return w


func _mock_player(w: CombatWorld, at: Vector3, id: String = "player1") -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = id
	p.owner_peer = 1
	p.team = "player"
	p.mass_class = "static"
	p.set_max_hp({"torso": 10000.0})
	p.add_hit_sphere("torso", Vector3(0.0, 4.0, 0.0), 2.1)
	p.position = at
	add_child(p)
	w.register(p)
	return p


## 3. Rooftop units (turrets, roof fireteams) stand where a mech in the street can shoot them: each is seen from at least
## EnemySpawner.ROOF_SIGHT_POINTS walkable street points (CityPlan.walk_graph nodes and edge midpoints) within
## ROOF_SIGHT_R m, mech weapon height to the unit's body, over the plan's building boxes. Checked here by an independent
## sampled line march (not the spawner's slab test). A perched turret no street point saw held seed 5's deck-1 sweep for
## 172 s (and seed 1's sniper lived 633 s). Non-vacuous: some roof candidates on these seeds are hidden from the street.
func _rooftop_units_seen_from_street() -> void:
	var hidden_cands := 0
	var roof_units := 0
	for s in range(1, 9):
		var sec := SectionPlan.make({"seed": float(s)})
		for k in sec.deck_count:
			var dp := CityPlan.for_deck(sec, k)
			var dr := RingFrame.new(sec.radius_of(k))
			var arr := sec.arrival(k)
			var arr_w := dr.arc_to_world(float(arr["x"]), float(arr["s"]), CityPlan.CURB_H)
			var pts: Array[Vector2] = []
			var g := dp.walk_graph()
			for n: Vector2 in g["nodes"]:
				pts.append(n)
			for ed: Array in g["edges"]:
				pts.append(((g["nodes"][int(ed[0])] as Vector2) + (g["nodes"][int(ed[1])] as Vector2)) * 0.5)
			var boxes: Array = []
			for b: Dictionary in dp.buildings:
				for t: Dictionary in b.get("tiers", []):
					if float(t["y1"]) >= 2.5:
						var sz: Vector2 = t["size"]
						boxes.append([Rect2((b["center"] as Vector2) + (t["off"] as Vector2) - sz * 0.5, sz), float(t["y1"]) + CityPlan.CURB_H])
				if bool(b.get("pillar", false)):
					var csz: Vector2 = b["core"]["size"]
					boxes.append([Rect2(Vector2(float(b["core"]["x"]), float(b["core"]["s"])) - csz * 0.5, csz), 999.0])
			for c: Dictionary in EnemySpawner._rooftop_candidates(dp, 0.0):
				if _street_sight_count(Vector2(float(c["x"]), float(c["s"])), float(c["h"]), pts, boxes,
						EnemySpawner.ROOF_SIGHT_POINTS) < EnemySpawner.ROOF_SIGHT_POINTS:
					hidden_cands += 1
			for sp: Dictionary in EnemySpawner.plan_encounters(dp, dr, arr_w, 1):
				var roof := str(sp["type"]).begins_with("turret") or bool(sp.get("on_roof", false))
				if not roof or float(sp["h"]) < 3.0:
					continue
				roof_units += 1
				var n := _street_sight_count(Vector2(float(sp["x"]), float(sp["s"])), float(sp["h"]), pts, boxes,
					EnemySpawner.ROOF_SIGHT_POINTS)
				check(n >= EnemySpawner.ROOF_SIGHT_POINTS, "seed %d deck %d: rooftop %s at (%.0f, %.0f, h %.1f) is seen from %d street points (need %d)" % [
					s, k, sp["type"], float(sp["x"]), float(sp["s"]), float(sp["h"]), n, EnemySpawner.ROOF_SIGHT_POINTS])
	print("roof sight: %d rooftop units checked, %d roof candidates hidden from the street" % [roof_units, hidden_cands])
	check(roof_units > 0 and hidden_cands > 0, "the check has rooftop units and hidden roofs to tell apart (%d, %d)" % [roof_units, hidden_cands])


## Street points that see (at, roof h): marching the 3D line every 0.5 m against every box (stops at `need`).
func _street_sight_count(at: Vector2, h: float, pts: Array[Vector2], boxes: Array, need: int) -> int:
	var aim := h + EnemySpawner.ROOF_SIGHT_AIM
	var eye := CityPlan.CURB_H + EnemySpawner.ROOF_SIGHT_EYE
	var n := 0
	for p in pts:
		var d := p.distance_to(at)
		if d < EnemySpawner.ROOF_SIGHT_MIN or d > EnemySpawner.ROOF_SIGHT_R:
			continue
		var near: Array = []
		var lo := Vector2(minf(p.x, at.x), minf(p.y, at.y)) - Vector2.ONE
		var bb := Rect2(lo, (Vector2(maxf(p.x, at.x), maxf(p.y, at.y)) + Vector2.ONE) - lo)
		for bx: Array in boxes:
			if bb.intersects(bx[0] as Rect2):
				near.append(bx)
		var clear := true
		var steps := int(ceil(d / 0.5))
		for i in range(1, steps):
			var f := float(i) / float(steps)
			var q := p.lerp(at, f)
			var lh := lerpf(eye, aim, f)
			for bx: Array in near:
				if (bx[0] as Rect2).has_point(q) and lh < float(bx[1]):
					clear = false
					break
			if not clear:
				break
		if clear:
			n += 1
			if n >= need:
				return n
	return n


func _multi_seed_full_deck_distribution() -> void:
	var safe_violations := 0
	var geom_violations := 0
	var total_decks := 0
	var all_dists: Array[float] = []
	var max_dists: Array[float] = []
	var half_ratio_ok := 0

	for s in range(1, 9):
		var sec := SectionPlan.make({"seed": float(s)})
		for k in sec.deck_count:
			total_decks += 1
			var dp := CityPlan.for_deck(sec, k)
			var dr := RingFrame.new(sec.radius_of(k))
			var arr := sec.arrival(k)
			var arr_arc := Vector2(float(arr["x"]), float(arr["s"]))
			var arr_w := dr.arc_to_world(arr_arc.x, arr_arc.y, CityPlan.CURB_H)

			var full_specs := EnemySpawner.plan_encounters(dp, dr, arr_w, 1)
			var half_specs := EnemySpawner.plan_encounters(dp, dr, arr_w, 1, [], 0.5)
			check(full_specs.size() >= 6, "seed %d deck %d full garrison spawns >= 6 units (%d)" % [s, k, full_specs.size()])
			if half_specs.size() > 0 and half_specs.size() < full_specs.size():
				half_ratio_ok += 1

			var deck_max_d := 0.0
			for sp in full_specs:
				var pt := Vector2(float(sp["x"]), float(sp["s"]))
				var h := float(sp["h"])
				var d := pt.distance_to(arr_arc)
				all_dists.append(d)
				deck_max_d = maxf(deck_max_d, d)
				if d < SectionPlan.SAFE_RADIUS - 0.1:
					safe_violations += 1
				var check_h := h + (0.25 if sp.has("b_center") else 0.0)
				if not EnemySpawner.clear_of_buildings(dp, pt, 1.3, check_h):
					geom_violations += 1
			max_dists.append(deck_max_d)

	all_dists.sort()
	var min_d := all_dists[0] if not all_dists.is_empty() else 0.0
	var med_d := all_dists[all_dists.size() / 2] if not all_dists.is_empty() else 0.0
	var avg_max_d := 0.0
	for md in max_dists:
		avg_max_d += md
	avg_max_d /= float(maxi(max_dists.size(), 1))

	eq(safe_violations, 0, "0 enemies inside 70 m arrival safe bubble across %d decks (min_d=%.1f m)" % [total_decks, min_d])
	eq(geom_violations, 0, "0 enemies overlapping buildings/pillars/cuts across %d decks" % total_decks)
	check(med_d >= 120.0, "enemies spread across full deck (median=%.1f m, avg_max=%.1f m from arrival)" % [med_d, avg_max_d])
	eq(half_ratio_ok, total_decks, "garrison_share=0.5 consistently trims garrison below full across all %d decks" % total_decks)
	print("[DistProbe] %d decks (seeds 1..8): min=%.1f m, median=%.1f m, avg_max=%.1f m" % [total_decks, min_d, med_d, avg_max_d])


func _mission_waves_end_to_end() -> void:
	var sec := SectionPlan.make({"seed": 4.0})
	var mplan := MissionPlan.make(sec)
	var dir := WaveDirector.make(mplan)
	var dp := CityPlan.for_deck(sec, 0)
	var dr := RingFrame.new(sec.radius_of(0))

	var w := _world(dr)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w, dp, dr)
	sq.add_deck_nav(0, dp)
	sq.drops_enabled = false

	var arr := sec.arrival(0)
	var arr_w := dr.arc_to_world(float(arr["x"]), float(arr["s"]), CityPlan.CURB_H)
	var p := _mock_player(w, arr_w, "wave_p1")

	# 1. Garrison half-split: all garrison units have wave == "".
	var pool0 := mplan.pool(0)
	var g_share := float(pool0.get("garrison", 0.5))
	var w_pool_share := clampf(1.0 - g_share, 0.0, 1.0)
	var budget0 := EnemySpawner.deck_budget(4, 0)
	var gar := EnemySpawner.spawn_all(dp, dr, arr_w, w, sq, 4, true, 4, "d0_", 0, sec.encounter_sites(0), g_share)
	check(gar.size() >= 3, "garrison spawned %d units at share %.2f" % [gar.size(), g_share])
	for e in gar:
		eq(e.wave, "", "garrison enemy %s has empty wave tag" % e.target_id)
	eq(sq.alive_garrison_per_deck(sec.deck_count)[0], gar.size(), "alive_garrison_per_deck matches standing garrison")

	# 2. Pick the largest real wave & source from MissionPlan, verify pool scaling (1 - pool.garrison) & partial release!
	var waves0: Array = pool0.get("waves", [])
	check(not waves0.is_empty(), "deck 0 MissionPlan pool has waves")
	var wdef: Dictionary = waves0[waves0.size() - 1]
	var sdef: Dictionary = mplan.source(str(wdef["source"]))
	var wid := str(wdef["id"])
	var expected_total := clampi(roundi(float(budget0) * w_pool_share * float(wdef["share"])), 2, WaveDirector.WAVE_MAX)
	var order1 := {"wave": wid, "deck": 0, "source": str(sdef["id"]), "open_at": w.now + 2.0, "max_units": 2}
	var src_w := dr.arc_to_world(float(sdef["x"]), float(sdef["s"]), CityPlan.CURB_H)
	p.global_position = src_w + Vector3(8.0, 0.0, 0.0)
	var res1 := sq.queue_wave(order1, wdef, sdef, budget0, dp, dr, 4, true, w_pool_share)
	eq(int(res1["total_units"]), expected_total, "wave sizes scale by budget * (1 - pool.garrison) * share (%d)" % expected_total)
	eq((res1["spawned"] as Array).size(), 0, "wave does not spawn before open_at")
	eq(int(res1["queued"]), 2, "2 units queued for first partial load")
	check(int(sq.pending_wave_counts().get(wid, 0)) >= 1,
		"pending_wave_counts reports remaining units after partial release (%s)" % str(sq.pending_wave_counts()))

	# Advance past open_at (2.5 s) while player is STILL within 25 m -> must hold!
	for _i in 150:
		w.advance(DT)
	eq(int((sq.wave_counts().get(wid, {}) as Dictionary).get("total", 0)), 0,
		"wave holds spawn while player stands within 25 m of door")

	# Move player 50 m away -> wave emerges on next tick, tagged with wid & hunting immediately!
	p.global_position = arr_w
	for _i in 10:
		w.advance(DT)
	var wc := sq.wave_counts()
	eq(int((wc.get(wid, {}) as Dictionary).get("alive", 0)), 2, "2 wave units emerged once player left 25 m bubble")
	eq(int((wc.get(wid, {}) as Dictionary).get("total", 0)), 2, "wave_counts total = 2 spawned so far")
	eq(sq.alive_garrison_per_deck(sec.deck_count)[0], gar.size(), "wave units do NOT inflate alive_garrison_per_deck")

	var wave_units: Array[EnemyBase] = []
	for e in sq.enemies:
		if e.wave == wid:
			wave_units.append(e)
	eq(wave_units.size(), 2, "2 enemies carry wave == '%s'" % wid)
	for e in wave_units:
		check(e._hunting, "spawned wave unit %s starts immediately in hunt mode" % e.target_id)

	# 3. Verify Engine's exact 4-arg contract: EnemySpawner.spawn_wave(order, wave, source+point, ctx) -> int
	#    including gate recess point outside plan.extent, partial follow-up return count, and EnemySync replication!
	var hsync := EnemySync.new()
	hsync.world = w
	hsync.squad = sq
	hsync.hosting = true
	sq.enemy_spawned.connect(hsync._on_spawned)
	add_child(hsync)
	var cw := _world(dr)
	var csq := EnemySquad.new()
	add_child(csq)
	csq.setup(cw, dp, dr)
	var csync := EnemySync.new()
	csync.world = cw
	csync.squad = csq
	csync.ring = dr
	csync.hosting = false
	add_child(csync)

	var rem_before := int(sq.pending_wave_counts().get(wid, 0))
	var order2 := {"wave": wid, "deck": 0, "source": str(sdef["id"]), "open_at": w.now, "max_units": rem_before}
	var src_with_recess := sdef.duplicate(true)
	var recess_pt := Vector2(dp.extent.position.x - 3.0, float(sdef["s"]))
	src_with_recess["point"] = {"deck": 0, "x": recess_pt.x, "s": recess_pt.y}
	var ctx := {"stack": null, "world": w, "squad": sq, "seed": 4, "crew": 2, "pool": pool0,
		"plan": dp, "ring": dr, "budget": budget0, "skip_meshes": true}
	var left_after := EnemySpawner.spawn_wave(order2, wdef, src_with_recess, ctx)
	eq(left_after, 0, "Engine 4-arg EnemySpawner.spawn_wave returns 0 remaining when wave completes")
	check(not sq.pending_wave_counts().has(wid), "pending_wave_counts clears once wave fully released")
	var wc2 := sq.wave_counts()
	eq(int((wc2[wid] as Dictionary)["total"]), 2 + rem_before, "wave_counts total reflects full wave")
	# Replay EnemySync "add" events from the recess wave spawn -> client spawns puppets!
	var added_puppets := 0
	for it: Array in hsync._queue:
		if str(it[0]) == "add":
			added_puppets += 1
		csync._apply_item(str(it[0]), int(it[1]), it[2])
	hsync._queue.clear()
	eq(added_puppets, rem_before, "EnemySync queued 'add' for every Engine spawn_wave unit (%d)" % added_puppets)
	eq(csync.by_net.size(), rem_before, "client spawned puppets for all %d wave units" % rem_before)
	# Verify recess units actually spawned in the recess (outside plan.extent) rather than snapped into plain view!
	var in_recess_count := 0
	for e in sq.enemies:
		if e.wave == wid and not (e in wave_units):
			var ea := dr.world_to_arc(e.position)
			if ea.x < dp.extent.position.x:
				in_recess_count += 1
	eq(in_recess_count, rem_before, "gate recess units spawn inside MissionWorld.source_point recess behind wall")

	csync.queue_free()
	csq.queue_free()
	cw.queue_free()
	hsync.queue_free()

	# Verify lift & shaft sources never spawn tanks even on heavy theme!
	var fake_lift := {"id": "d0_lift_0", "deck": 0, "kind": "lift", "x": float(sdef["x"]), "s": float(sdef["s"]),
		"toward": sdef["toward"], "load": 4}
	var fake_shaft := {"id": "d0_shaft_0", "deck": 0, "kind": "shaft", "x": float(sdef["x"]), "s": float(sdef["s"]),
		"toward": sdef["toward"], "load": 4}
	var heavy_w := {"id": "d0_wh", "share": 0.6, "theme": "heavy", "source": "d0_lift_0"}
	for src_d: Dictionary in [fake_lift, fake_shaft]:
		var pl := EnemySpawner.plan_wave(dp, dr, {"wave": "d0_wh", "deck": 0, "source": src_d["id"], "open_at": 0.0, "max_units": 4},
			heavy_w, src_d, 14, 7, 0)
		for sp: Dictionary in pl["specs"]:
			check(str(sp["type"]) != "tank", "%s wave never spawns a tank (got %s)" % [src_d["kind"], sp["type"]])

	# Quick smoke check that WaveDirector accepts our exact helper shapes cleanly.
	var facts := {
		"alive": EnemySync.alive_per_deck(sq.enemies, sec.deck_count),
		"garrison_alive": sq.alive_garrison_per_deck(sec.deck_count),
		"wave_alive": sq.wave_counts(),
		"wave_pending": sq.pending_wave_counts(),
		"crew_deck": [0],
	}
	var dir_orders := dir.tick(w.now, facts)
	check(dir_orders is Array, "WaveDirector.tick accepts EnemySquad host count helpers cleanly")

	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)


func _defend_relay_targeting_and_pool_sizing() -> void:
	# 1. Verify wave pool sizing stays in proportion to deck budget: units = clamp(round(budget * (1 - garrison) * share), 2, WAVE_MAX).
	var sec := SectionPlan.make({"seed": 1.0})
	var mplan := MissionPlan.make(sec)
	for k in sec.deck_count:
		var pool := mplan.pool(k)
		var g_share := float(pool.get("garrison", 0.5))
		var b := EnemySpawner.deck_budget(1, k)
		var sum_wave_u := 0
		for wv: Dictionary in pool.get("waves", []):
			var sdef := mplan.source(str(wv["source"]))
			var pl := EnemySpawner.plan_wave(null, null, {"wave": wv["id"], "deck": k, "source": sdef["id"], "open_at": 0.0, "max_units": 20},
				wv, sdef, b, 1, 0, 1.0 - g_share)
			var exp_u := clampi(roundi(float(b) * (1.0 - g_share) * float(wv["share"])), 2, WaveDirector.WAVE_MAX)
			eq(int(pl["total_units"]), exp_u, "deck %d wave %s sized by budget*(1-garrison)*share (%d)" % [k, str(wv["id"]), exp_u])
			sum_wave_u += int(pl["total_units"])
		check(sum_wave_u <= b, "deck %d total wave units (%d) stay within deck budget (%d)" % [k, sum_wave_u, b])

	# 2. Defend relay targeting rule: garrisons & unrelated waves ignore AssetTarget; only the matching defend wave targets it (plus crew).
	var w := _world(null)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.deck_of = func(_pos: Vector3) -> int: return 0

	var relay_a := AssetTarget.new("d0_p", 2.5, 6.0)
	relay_a.position = Vector3(0, 0, -25.0)
	add_child(relay_a)
	w.register(relay_a)

	var relay_b := AssetTarget.new("d0_b0", 2.5, 6.0)
	relay_b.position = Vector3(4.0, 0, -25.0)
	add_child(relay_b)
	w.register(relay_b)

	# Put crew mech 120 m away (within deck 0, outside patrol sight range so only the 25 m relays are in front of the enemies).
	var p := _mock_player(w, Vector3(120.0, 0.0, 0.0), "crew_defend")

	# A. Garrison enemy facing the relays at 25 m must ignore BOTH relays!
	var gar_e := EnemyTurret.new()
	gar_e.configure("turret", "gar_ignore_relay", w, sq, null, 1)
	gar_e.spawn_deck = 0
	gar_e.position = Vector3(0, 0, 0)
	sq.add_enemy(gar_e)

	# B. Unrelated wave (flag alarm wave) facing the relays at 25 m must ALSO ignore both relays!
	var src_stub := {"id": "s0", "deck": 0, "kind": "gate", "x": 0.0, "s": 0.0, "toward": {"x": 0.0, "s": -25.0}, "load": 4}
	var flag_wave := {"id": "w_flag", "share": 0.5, "theme": "light", "source": "s0",
		"trigger": {"kind": "objective", "id": "d0_p", "step": "done"}}
	var defend_wave := {"id": "w_defend", "share": 0.5, "theme": "light", "source": "s0",
		"trigger": {"kind": "objective", "id": "d0_p", "step": "start"}}
	EnemySpawner.spawn_wave({"wave": "w_flag", "deck": 0, "source": "s0", "open_at": 0.0, "max_units": 2},
		flag_wave, src_stub, {"world": w, "squad": sq, "budget": 10, "pool": {"garrison": 0.5}, "skip_meshes": true})
	EnemySpawner.spawn_wave({"wave": "w_defend", "deck": 0, "source": "s0", "open_at": 0.0, "max_units": 2},
		defend_wave, src_stub, {"world": w, "squad": sq, "budget": 10, "pool": {"garrison": 0.5}, "skip_meshes": true})
	await frames(1)

	var flag_e: EnemyBase = null
	var def_e: EnemyBase = null
	for e in sq.enemies:
		if e.wave == "w_flag" and flag_e == null:
			flag_e = e
		elif e.wave == "w_defend" and def_e == null:
			def_e = e
	check(flag_e != null and def_e != null, "flag and defend wave units spawned cleanly")
	eq(flag_e.defend_target_id, "", "flag wave (step=done) gets empty defend_target_id")
	eq(def_e.defend_target_id, "d0_p", "defend wave (step=start) gets defend_target_id == objective id")
	check(not gar_e._can_target_asset(relay_a), "garrison enemy cannot target AssetTarget")
	check(not flag_e._can_target_asset(relay_a), "non-defend wave cannot target AssetTarget")
	check(def_e._can_target_asset(relay_a), "matching defend wave CAN target its own defend relay")
	check(not def_e._can_target_asset(relay_b), "defend wave CANNOT target a different relay")

	# Place crew mech closer to def_e than relay_a -> def_e targets the crew (not exclusively the relay!).
	def_e.global_position = Vector3(0.0, 0.0, 0.0)
	p.global_position = Vector3(0.0, 0.0, -10.0)
	def_e._perc_valid = false
	var t_near := def_e._acquire_target(null)
	check(t_near == p, "defend wave engages crew mech when crew is closer than the relay (not relay-exclusive)")

	# Move crew mech back -> def_e acquires its own defend relay while gar_e still ignores it!
	p.global_position = Vector3(180.0, 0.0, 0.0)
	def_e._perc_valid = false
	gar_e._perc_valid = false
	var t_def := def_e._acquire_target(null)
	var t_gar := gar_e._acquire_target(null)
	check(t_def == relay_a, "defend wave acquires its own defend relay when in range")
	check(t_gar == null, "garrison enemy ignores the defend relay even right in front of it")

	relay_a.queue_free()
	relay_b.queue_free()
	p.queue_free()
	sq.queue_free()
	w.queue_free()
	await frames(1)
