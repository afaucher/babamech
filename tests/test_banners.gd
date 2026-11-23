extends TestCase
## The invader banners (scripts/world/occupation/, docs/design/banners.md), single process.
## 1. Placement: BannerPlan.make on every deck of seeds 1-6 is the same from two independent plan builds, differs with the
##    mission seed, keeps 4-10 banners a deck (6-10 where the deck has the facades), SPACING apart, never over a front
##    door, never near a floor cut / ramp, a checkpoint / cordon hook or the deck's edge, at most 2 per building.
## 2. The field on a real CityStack (seed 3) with a CombatWorld (no physics): every banner is a registered BannerTarget
##    (host-owned, team "enemy", on its deck's render layer), cheap to set up.
## 3. Player autocannon fire tears a banner after 3 hits (60 HP): torn on this machine (solo = host), counted, signalled;
##    the tear settles to the heap; a torn banner takes no more hits (the shot passes to a target behind it).
## 4. Enemy fire passes through an intact banner (no damage), and a catalog turret with no player around never acquires
##    a banner.

const SEEDS := [1, 2, 3, 4, 5, 6]
const DT := 1.0 / 60.0


func setup() -> void:
	timeout_sec = 240.0
	for sd: int in SEEDS:
		_placement(sd)
	await _field()
	finish()


func _placement(sd: int) -> void:
	var sec := SectionPlan.make({"seed": float(sd)})
	var sec2 := SectionPlan.make({"seed": float(sd)})
	var counts := []
	for k in sec.deck_count:
		var plan := CityPlan.for_deck(sec, k)
		var plan2 := CityPlan.for_deck(sec2, k)
		var t0 := Time.get_ticks_usec()
		var a := BannerPlan.make(plan, sd * 31)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var b := BannerPlan.make(plan2, sd * 31)
		eq(BannerPlan.checksum(a), BannerPlan.checksum(b), "seed %d deck %d: the same placement from two builds" % [sd, k])
		var c := BannerPlan.make(plan, sd * 31 + 1)
		if a.size() >= 4:
			check(BannerPlan.checksum(a) != BannerPlan.checksum(c), "seed %d deck %d: another mission seed moves them" % [sd, k])
		counts.append("%d(%d pole, %.1f ms)" % [a.size(), a.filter(func(x: Dictionary) -> bool: return x["kind"] == "pole").size(), ms])
		check(a.size() >= 4 and a.size() <= BannerPlan.PER_DECK_MAX, "seed %d deck %d: %d banners (4-10)" % [sd, k, a.size()])
		var per_b := {}
		var gates: Array[Vector2] = []
		for hk: Dictionary in sec.hooks:
			if int(hk["deck"]) == k and str(hk["kind"]) in ["checkpoint", "cordon"]:
				gates.append(Vector2(hk["x"], hk["s"]))
		var cuts := plan.floor_cuts()
		for i in a.size():
			var bi: Dictionary = a[i]
			eq(int(bi["id"]), i, "ids are indices")
			var p := Vector2(bi["x"], bi["s"])
			for j in range(i + 1, a.size()):
				check(p.distance_to(Vector2(a[j]["x"], a[j]["s"])) >= BannerPlan.SPACING - 1e-3,
					"seed %d deck %d: banners %d and %d at least %.0f m apart" % [sd, k, i, j, BannerPlan.SPACING])
			for g: Vector2 in gates:
				check(p.distance_to(g) >= BannerPlan.GATE_CLEAR - 0.8, "seed %d deck %d banner %d: clear of the checkpoint" % [sd, k, i])
			var n: Vector2 = bi["n"]
			for o: Rect2 in cuts:
				check(not o.grow(BannerPlan.CUT_CLEAR).has_point(p + n * 2.3), "seed %d deck %d banner %d: not over a floor cut" % [sd, k, i])
			check(plan.extent.grow(-BannerPlan.EDGE_CLEAR + 1.0).has_point(p), "inside the deck's edge")
			if str(bi["kind"]) == "wall":
				var b2: Dictionary = plan.buildings[int(bi["bi"])]
				per_b[int(bi["bi"])] = int(per_b.get(int(bi["bi"]), 0)) + 1
				var front := int(b2.get("front", -1))
				if front >= 0 and CityPlan.SIDE_N[front] == n:
					var c2: Vector2 = b2["center"]
					var along := Vector2(absf(n.y), absf(n.x))
					var u := (p - c2).dot(along) - (b2["tiers"][0]["off"] as Vector2).dot(along)
					check(absf(u) >= BannerPlan.DOOR_CLEAR - 0.6, "seed %d deck %d banner %d: not over the front door (u %.1f)" % [sd, k, i, u])
				check(float(bi["len"]) >= 4.8 and float(bi["len"]) <= BannerMeshes.H, "cloth 4.8-6.4 m")
				check(float(bi["top"]) - float(bi["len"]) >= 0.5, "the cloth clears the sidewalk")
		for v: int in per_b.values():
			check(v <= BannerPlan.PER_BUILDING, "at most 2 banners on one building")
	print("seed %d banners per deck: %s" % [sd, ", ".join(counts)])


func _field() -> void:
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 3.0}))
	var world := CombatWorld.new()
	world.mission_seed = 3
	world.use_physics = false
	add_child(world)
	var f := OccupationBanners.new()
	add_child(f)
	var t0 := Time.get_ticks_usec()
	f.setup(stack, world)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("banner field setup: %d banners on %d decks in %.1f ms" % [f.banner_count(), stack.decks.size(), ms])
	check(f.setup_done() and f.banner_count() >= 4 * stack.decks.size(), "the field is set up on every deck")
	var f2 := OccupationBanners.new()
	add_child(f2)
	f2.setup_begin(stack, world, 3)
	var steps := 1
	while not f2.setup_step(8.0):
		steps += 1
	eq(f2.checksum(), f.checksum(), "stepped setup places the same banners (%d steps)" % steps)
	f2.queue_free()
	await frames(1)
	for k in stack.decks.size():
		for i in f.plans[k].size():
			var t := f.target(k, i)
			check(t in world.targets, "banner %d/%d registered" % [k, i])
			eq(t.team, "enemy", "team enemy")
			eq(t.owner_peer, 0, "host-owned")
			eq((f.parts(k, i)["cloth"] as MeshInstance3D).layers, CityStack.deck_layer(k), "on its deck's layer")
			eq(stack.deck_at(t.global_position + t.global_basis.y * -2.0), k, "on its deck")
	await frames(1)
	# 3. Player fire tears one.
	var t := f.target(0, 0)
	var centre := (t.world_spheres()[0]["center"] as Vector3)
	var out := t.global_basis.z.normalized()
	var torn_sig: Array = []
	f.banner_torn.connect(func(k: int, id: int) -> void: torn_sig.append([k, id]))
	var shots := 0
	for i in 6:
		if f.is_torn(0, 0):
			break
		world.fire(Combat.fire_record("player1", 1, "side_r", "autocannon", centre + out * 25.0, centre, world.now, 100 + i, 0.0))
		shots += 1
		for _j in 40:
			world.advance(DT)
	check(f.is_torn(0, 0), "player autocannon fire tears the banner")
	eq(shots, 3, "after 3 hits (60 HP, 22 a shell)")
	eq(f.torn_count(), 1, "one torn")
	eq(torn_sig.size(), 1, "banner_torn fired once")
	check(not t.is_hittable(), "a torn banner is not hittable")
	check((f.parts(0, 0)["fringe"] as MeshInstance3D).visible, "the fringe stays on the bar")
	for _i in 90:
		f._process(DT)
	check(not (f.parts(0, 0)["cloth"] as MeshInstance3D).visible and (f.parts(0, 0)["heap"] as MeshInstance3D).visible,
		"the tear settles: the cloth lies as a heap")
	var heap_y: float = stack.decks[0].ring.height(stack.decks[0].to_local((f.parts(0, 0)["heap"] as Node3D).global_position))
	check(heap_y < 0.8, "the heap lies at the foot of the facade (%.2f m)" % heap_y)
	# Torn: the next shot passes through to a target behind it.
	var behind := CombatTarget.new()
	behind.target_id = "behind"
	behind.set_max_hp({"body": 1000.0})
	behind.add_hit_sphere("body", Vector3.ZERO, 1.0)
	add_child(behind)
	behind.global_position = centre - out * 0.5
	world.register(behind)
	world.fire(Combat.fire_record("player1", 1, "side_r", "autocannon", centre + out * 25.0, centre, world.now, 200, 0.0))
	for _j in 40:
		world.advance(DT)
	check(behind.total_hp() < 1000.0, "a torn banner takes no hit: the shot reaches what is behind it")
	eq(f.torn_count(), 1, "still one torn")
	world.unregister(behind)
	behind.queue_free()
	# 4. Enemy fire passes an intact banner.
	var t2 := f.target(0, 1)
	var c2 := (t2.world_spheres()[0]["center"] as Vector3)
	var o2 := t2.global_basis.z.normalized()
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var rec := Combat.fire_record("enemy_test", 1, w, w, c2 + o2 * 25.0, c2, world.now, 300, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	world.fire(rec)
	for _j in 60:
		world.advance(DT)
	near(t2.total_hp(), BannerTarget.MAX_HP, 1e-4, "enemy fire passes through an intact banner")
	check(not f.is_torn(0, 1), "and never tears it")
	# A turret 30 m in front of a banner, no player anywhere: never acquires it.
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(world)
	var tr := EnemyTurret.new()
	tr.configure("turret", "turret_banner", world, sq, null, 1)
	sq.add_enemy(tr)
	tr.global_position = c2 + o2 * 30.0 - t2.global_basis.y * 0.0
	tr.look_at(c2, t2.global_basis.y)
	await frames(1)
	var acquired := ""
	for _i in 240:
		world.advance(DT)
		if tr._target_id != "":
			acquired = tr._target_id
	check(not acquired.begins_with("banner_"), "an enemy turret never acquires a banner (got '%s')" % acquired)
	sq.queue_free()
	f.queue_free()
	world.queue_free()
	stack.queue_free()
	await frames(2)
