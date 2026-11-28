extends TestCase
## Military supply depots (docs/design/pacing-director.md §2; scripts/mission/depots/mission_depots.gd, supply_depot.gd,
## depot_target.gd), single process.
## A. The effect of one power core on a damaged mech (a standalone PlayerTarget + WeaponRack): surviving components +50 %
##    of their missing HP, a destroyed weapon hardpoint rebuilt at 30 % and its weapon usable again, ammo refilled, heat
##    vented and shutdown cleared; a disabled mech gets nothing.
## B. A SOLO stack drive in plan mode (seed 7): the depots stand in the world (under their deck, collision, one lit cell
##    per core), registered as neutral combat targets that no enemy ever acquires and that every shot can hit.
## C. The stand rule on deck 1's depot: out of range nothing; in range the "Taking power core" line rises and after 2 s
##    a core is taken (2 -> 1, a cell goes dark; solo has DEPOT_CORES_MIN 2) and its effect lands on the mech; after the
##    cooldown the second one; the depot is then
##    empty: no new claim, a forced one is denied "empty"; a claim from out of range is refused "range".
## D. A destroyed depot (its HP to 0 on the owner) loses its cores, shows its wreck, stops being hittable, denies claims.
## G. Never trapped (R2.23): the collision is one convex shape over the kiosk's visible footprint (roof slab), walls
##    and a flat top above every chassis' straight side (out of the pin band), no physics hit shapes; on a flat floor
##    the real capsule of the Strider, Bulwark and Wasp walks / runs into it from 16 directions, strafes along every
##    side, is dropped on its top at 9 points (bipeds), thrust-lands at it from 16 directions and is knocked against
##    it: every time it leaves the footprint + 3 m within 3 s of plain walk input,
##    never below the floor, never through the wedge nudge. On the seed 7 decks (curved) every depot, Strider and
##    Bulwark from 16 directions: never pinned where they rest.

const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}

var td: MissionScene


func _init() -> void:
	timeout_sec = 480.0


func setup() -> void:
	await _effect()
	await _view()
	await _collision_flat()
	MissionFlow.test_plan = PLAN
	await _drive()
	await _keep_out()
	MissionFlow.test_plan = {}
	finish()


# --- F. Off the roads (2026-11-24: seed 2's d0_depot0 stood on a road line and wedged the bot) ----------------------

const KEEP_SEEDS: Array[int] = [1, 2, 3, 7, 17, 22, 26, 403112]


## On built decks: every depot's footprint (+ the 4 m margin) is clear of the road strips, ramps, floor cuts, gate bay
## corridors and sources, and 3 m (+ half-width) off every walk-graph edge (tier 0 / 1; tier 2 drops the latter); the
## standing area in front of the socket wall fits a mech capsule within claim range; seed 2 deck 1's depot left the road
## line at (-57, -154). WIDEST MECH (2026-11-26, seed 22's d1_depot1 wedged a Bulwark), measured on the built deck's
## static collision with the widest capsule (CityPlan.MECH_R_MAX, BotFit): it stands at the standing spot; it gets there
## from a walk-graph edge by one or two straight lines; it walks right round the depot (a capsule probe every metre on a
## loop fit_r() off the footprint: no pocket, no gap narrower than the capsule). Every depot in sites is ok; seed 22 deck
## 1's second depot is validly placed or absent.
func _keep_out() -> void:
	var total := 0
	var dropped := 0
	var rb := CityPlan.MECH_R_MAX
	for sd in KEEP_SEEDS:
		var t := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
		t.city_mode = MissionScene.MODE_STACK
		t.seed_value = sd
		add_child(t)
		await frames(3)
		var dp := t.mission.depots if t.mission != null else null
		if not check(dp != null, "seed %d: depots" % sd):
			t.queue_free()
			await frames(2)
			continue
		dropped += dp.unplaced.size()
		var sec := t.stack.section
		var space := t.get_world_3d().direct_space_state
		for id: String in dp.sites:
			total += 1
			var st: Dictionary = dp.sites[id]
			var k := int(st["deck"])
			var at := Vector2(float(st["x"]), float(st["s"]))
			var f := int(st["face"])
			var tier := int(st.get("tier", 0))
			var tag := "seed %d %s at (%.0f, %.0f) face %d tier %d" % [sd, id, at.x, at.y, f, tier]
			check(bool(st.get("ok", false)), tag + ": ok (no fallback placement)")
			if sd == 22 and id == "d1_depot1":
				print("[Test] seed 22 d1_depot1: placed at (%.1f, %.1f), tier %d (plan site (-88, -250))" % [at.x, at.y, tier])
			var fr := SiteFit.footprint_rect(at, f)
			for sg: Dictionary in sec.segments(k):
				if str(sg["form"]) != "none" and fr.grow(SiteFit.KEEP_MARGIN).intersects(sg["rect"]):
					check(false, tag + ": clear of road %s %d/%d (%s) by 4 m" % [sg["axis"], int(sg["line"]), int(sg["index"]), sg["form"]])
			var cp := t.stack.decks[k].plan
			var g := CityGraphs.walk_graph(cp, true)
			for ed: Array in g["edges"]:
				var a: Vector2 = g["nodes"][int(ed[0])]
				var b: Vector2 = g["nodes"][int(ed[1])]
				if tier < 2 and SiteFit.rect_seg_dist(fr, a, b) < SiteFit.WALK_GAP:
					check(false, tag + ": 3 m off walk edge %s-%s" % [a, b])
			for c: Rect2 in cp.floor_cuts():
				check(not fr.grow(SiteFit.KEEP_MARGIN).intersects(c), tag + ": clear of a floor cut")
			for rp: Dictionary in cp.ramps:
				var rr := Rect2(float(rp["x0"]), minf(float(rp["s_top"]), float(rp["s_foot"])), float(rp["x1"]) - float(rp["x0"]),
					absf(float(rp["s_top"]) - float(rp["s_foot"])))
				check(not fr.grow(SiteFit.KEEP_MARGIN).intersects(rr.grow(2.0)), tag + ": clear of a ramp")
			eq(SiteFit.keep_hit(dp.keep_outs[k], at, f, tier < 2), "", tag + ": the whole keep-out (bay corridors, sources, masts)")
			var sp := SiteFit.stand_point(at, f)
			check(bool(SiteFit.snap(t.stack.decks[k], sp, 0.0, SiteFit.MECH_R)["ok"]),
				tag + ": a mech capsule fits in front of the socket wall")
			check(dp.footprint_dist(id, sp.x, sp.y) <= MissionDepots.CLAIM_RANGE, tag + ": the standing spot is within claim range")
			if sd == 2 and k == 0:
				check(at.distance_to(Vector2(-57.0, -154.0)) > 6.0, tag + ": seed 2 deck 1's depot is off the road line at (-57, -154)")
			# The widest capsule, on the built deck's static collision (the depot's own body included).
			var ring := t.stack.deck_ring(k)
			var h0 := float(st.get("h", 0.0))
			check(BotFit.clear_at(space, ring, sp.x, sp.y, rb, 8.0, h0), tag + ": the widest capsule stands at the standing spot")
			check(_reaches_walk(space, ring, g, sp, rb), tag + ": the widest capsule gets to the standing spot from a walk-graph edge")
			var stuck := []
			for q: Vector2 in _loop_points(fr, SiteFit.fit_r() + 0.1):
				if not BotFit.clear_at(space, ring, q.x, q.y, rb, 8.0, h0):
					stuck.append("(%.1f, %.1f)" % [q.x, q.y])
			check(stuck.is_empty(), tag + ": the widest capsule walks right round the depot (blocked at %s)" % [stuck])
		if sd == 22:
			check(not dp.unplaced.has("d1_depot1") or not dp.sites.has("d1_depot1"), "seed 22 d1_depot1: placed validly or absent")
		for id: String in dp.unplaced:
			print("[Test] seed %d: %s not placed (no valid site on its deck)" % [sd, id])
			check(not dp.sites.has(id) and not dp.cores_left.has(id), "seed %d %s: an unplaced depot has no site and no cores" % [sd, id])
		t.queue_free()
		await frames(3)
	print("[Test] depots: %d placed over seeds %s, %d not placed" % [total, KEEP_SEEDS, dropped])


## Probe points on the loop `d` off rect `r`: every metre along the four sides, every 15 degrees round the corners.
func _loop_points(r: Rect2, d: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in int(ceilf(r.size.x)) + 1:
		var x := minf(r.position.x + float(i), r.end.x)
		out.append(Vector2(x, r.position.y - d))
		out.append(Vector2(x, r.end.y + d))
	for i in int(ceilf(r.size.y)) + 1:
		var y := minf(r.position.y + float(i), r.end.y)
		out.append(Vector2(r.position.x - d, y))
		out.append(Vector2(r.end.x + d, y))
	var corners := [[r.position, PI], [Vector2(r.end.x, r.position.y), PI * 1.5], [r.end, 0.0], [Vector2(r.position.x, r.end.y), PI * 0.5]]
	for c: Array in corners:
		for a in 7:
			out.append((c[0] as Vector2) + Vector2.from_angle(float(c[1]) + PI * 0.5 * float(a) / 6.0) * d)
	return out


## The widest capsule gets from a walk-graph edge to `sp` by one straight line, or two (via a 4 m grid point within 40 m):
## the walk-graph points tried are the nearest point of each edge, nearest 12 first.
func _reaches_walk(space: PhysicsDirectSpaceState3D, ring: RingFrame, g: Dictionary, sp: Vector2, r: float) -> bool:
	var pts := []
	for ed: Array in g["edges"]:
		var a: Vector2 = g["nodes"][int(ed[0])]
		var b: Vector2 = g["nodes"][int(ed[1])]
		var c := Geometry2D.get_closest_point_to_segment(sp, a, b)
		pts.append([c.distance_to(sp), c.y, c.x])
	pts.sort()
	var ends := []
	for i in mini(12, pts.size()):
		var c := Vector2(float(pts[i][2]), float(pts[i][1]))
		if BotFit.clear_at(space, ring, c.x, c.y, r):
			ends.append(c)
	for c: Vector2 in ends:
		if float(BotFit.line_fit(space, ring, c, sp, r)["bad"]) == 0.0:
			return true
	var mids := []
	for i in range(-10, 11):
		for j in range(-10, 11):
			var m := sp + Vector2(i, j) * 4.0
			mids.append([m.distance_to(sp), m.y, m.x])
	mids.sort()
	for mm: Array in mids:
		var m := Vector2(float(mm[2]), float(mm[1]))
		if not BotFit.clear_at(space, ring, m.x, m.y, r) or float(BotFit.line_fit(space, ring, m, sp, r)["bad"]) > 0.0:
			continue
		for c: Vector2 in ends:
			if float(BotFit.line_fit(space, ring, c, m, r)["bad"]) == 0.0:
				return true
	return false


# --- A. The effect ---------------------------------------------------------------------------------------------

func _effect() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var model := MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "autocannon", "side_r": "laser", "shoulder_l": "missiles",
		"shoulder_r": "rockets", "back": "repair_drone"})
	var mech := MechController.new()     # not in the tree: its heat doesn't cool
	var pt := PlayerTarget.new()
	add_child(pt)
	pt.bind(world, mech, model, "eff", 1)
	var rack := WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	rack.slot_disabled = pt.is_slot_destroyed
	add_child(rack)
	rack.bind(world, mech, model, null, "eff", 1)
	await frames(2)
	var ms := rack.hardpoints.find("shoulder_l") + 1
	var rk := rack.hardpoints.find("shoulder_r") + 1
	var dr := rack.hardpoints.find("back") + 1
	if not check(ms > 0 and rk > 0 and rack.mounts[ms - 1] != null and rack.mounts[rk - 1] != null, "missiles and rockets mounted"):
		return
	# Damage: torso to 100 / 400, leg_r to 150 / 200, the missiles' hardpoint destroyed, ammo spent, a drone used, overheated.
	pt.apply_damage(300.0, "torso", "test")
	pt.apply_damage(50.0, "leg_r", "test")
	pt.apply_damage(1000.0, "shoulder_l", "test")
	(rack.mounts[ms - 1] as WeaponMount).ammo = 0
	(rack.mounts[rk - 1] as WeaponMount).ammo = 4
	rack.charges[dr - 1] = 0
	mech.heat = mech.heat_cap
	mech.shutdown = true
	check(not pt.disabled, "a destroyed weapon hardpoint does not disable the mech")
	check(not rack.usable(ms), "the missiles are unusable (destroyed, dry)")
	var eff := MissionDepots.apply_core_to(pt, rack)
	check(bool(eff["applied"]), "the core is applied")
	near(float(pt.hp["torso"]), 100.0 + 0.5 * 300.0, 0.01, "torso: +50 % of its missing structure")
	near(float(pt.hp["leg_r"]), 150.0 + 0.5 * 50.0, 0.01, "leg_r: +50 % of its missing structure")
	near(float(pt.hp["leg_l"]), 200.0, 0.01, "an intact leg stays full")
	near(float(pt.hp["shoulder_l"]), PlayerTarget.WEAPON_HP * MissionDepots.CORE_REBUILD, 0.01,
		"the destroyed hardpoint is rebuilt at 30 % (not +50 % on top)")
	eq(eff["rebuilt"], ["shoulder_l"] as Array[String], "the rebuilt components")
	check(not pt.is_slot_destroyed("shoulder_l"), "the hardpoint is no longer destroyed")
	eq((rack.mounts[ms - 1] as WeaponMount).ammo, rack.ammo_max[ms - 1], "the missiles are refilled")
	eq((rack.mounts[rk - 1] as WeaponMount).ammo, rack.ammo_max[rk - 1], "the rockets are refilled")
	check(rack.usable(ms), "the missiles work again")
	eq(rack.charges[dr - 1], int(MechCatalog.weapon("repair_drone").get("charges", 0)), "the repair drone's charges refilled")
	near(mech.heat, 0.0, 0.001, "heat vented to zero")
	check(not mech.shutdown, "shutdown cleared")
	# A disabled mech gets nothing (a core is not a revive).
	pt.apply_damage(1.0e6, "torso", "test")
	check(pt.disabled, "the torso destroyed disables the mech")
	var before := pt.hp.duplicate()
	eq(bool(MissionDepots.apply_core_to(pt, rack)["applied"]), false, "a disabled mech: no effect")
	eq(str(pt.hp), str(before), "a disabled mech's structure is unchanged")
	for n: Node in [rack, pt, model, world]:
		n.queue_free()
	await frames(2)


# --- The look's interface (SupplyDepot.VIEW_SCRIPT; docs/design/supply-depot.md) ---------------------------------

func _view() -> void:
	# The art model (VIEW_SCENE): the interface, layers set before it enters the tree, the socket wall on +Z.
	var k := SupplyDepot.make_view()
	if check(k != null, "VIEW_SCENE makes the model"):
		check(ResourceLoader.exists(SupplyDepot.VIEW_SCENE) and k.get_script() != load(SupplyDepot.VIEW_SCRIPT),
			"the art model, not the placeholder")
		for m: String in ["set_cores", "core_taken", "set_destroyed", "socket_point", "set_render_layers"]:
			check(k.has_method(m), "the model has " + m)
		k.call("set_render_layers", 4)
		add_child(k)
		k.call("set_cores", 2, 3)
		k.call("set_cores", 2, 3)
		k.call("core_taken", 1)
		k.call("set_cores", 1, 3)
		k.call("set_destroyed", true)
		k.call("set_destroyed", false)
		var kp: Vector3 = k.call("socket_point", 0)
		check(kp.z > 1.0 and kp.y > 1.0, "the model's socket 0 is on its +Z wall (%s)" % kp)
		k.queue_free()
	# The placeholder (VIEW_SCRIPT), kept as the fallback.
	var v := SupplyDepot.make_view(true)
	if not check(v != null, "VIEW_SCRIPT makes a view"):
		return
	for m: String in ["set_cores", "core_taken", "set_destroyed", "socket_point"]:
		check(v.has_method(m), "the view has " + m)
	v.call("setup", 1)
	add_child(v)
	v.call("set_cores", 2, 4)
	eq(int(v.call("lit_count")), 2, "2 of 4 stocked: 2 lit sockets")
	v.call("set_cores", 2, 4)
	eq(int(v.call("lit_count")), 2, "set_cores is idempotent")
	v.call("set_cores", 3, 1)
	eq(int(v.call("lit_count")), 1, "capacity 1: the unused sockets stay black")
	var sp: Vector3 = v.call("socket_point", 0)
	check(sp.z > 1.5 and sp.y > 0.5 and sp.y < 3.0 and absf(sp.x) < 3.0, "socket 0 is on the +Z wall (%s)" % sp)
	v.call("set_destroyed", true)
	eq(int(v.call("lit_count")), 0, "destroyed: nothing lit")
	v.queue_free()
	await frames(1)


# --- B-D. The solo drive ---------------------------------------------------------------------------------------

func _drive() -> void:
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = SEED
	add_child(td)
	await frames(4)
	var mf := td.mission
	if not check(mf != null and mf.plan != null and mf.depots != null, "plan mode with depots"):
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var dp := mf.depots
	var world := td.combat.world
	# B. Placed in the world.
	eq(dp.nodes.size(), mf.plan.depots.size(), "a SupplyDepot per plan depot")
	for d: Dictionary in mf.plan.depots:
		var id := str(d["id"])
		var n := dp.nodes.get(id) as SupplyDepot
		if not check(n != null and n.is_inside_tree(), id + ": in the world"):
			continue
		eq(n.get_parent(), td.stack.decks[int(d["deck"])], id + ": under its deck's district")
		eq(int(dp.cores_max[id]), MissionPlan.DEPOT_CORES_MIN, id + ": solo: 2 cores (1 per pilot, at least DEPOT_CORES_MIN)")
		check(n.body != null and n.body.get_child_count() > 0, id + ": has collision")
		check(world.targets.has(n.target), id + ": its DepotTarget is a combat target")
		eq(n.target.team, "", id + ": neutral team")
		eq(n.lit_cells(), MissionPlan.DEPOT_CORES_MIN, id + ": a lit cell per core")
		var st: Dictionary = dp.sites[id]
		var plan_at := Vector2(float(d["site"]["x"]), float(d["site"]["s"]))
		check(plan_at.distance_to(Vector2(float(st["x"]), float(st["s"]))) <= float(st.get("reach", MissionPlan.DEPOT_SNAP)) + 0.01,
			id + ": placed within its search reach")
		var fd: Vector2 = SiteFit.FACE_DIRS[int(st["face"])]
		var sa := td.stack.to_deck_arc(n.socket_world(0))
		check(Vector2(float(sa["x"]) - float(st["x"]), float(sa["s"]) - float(st["s"])).dot(fd) > 1.0,
			id + ": the socket wall faces its chosen open side (face %d)" % int(st["face"]))
		check(not world.spares("enemy", n.target, "enemy_x") and not world.spares("player", n.target, "player1"),
			id + ": no shot spares it (stray enemy fire, crew fire)")
	await _collision_ring(dp)
	var list := mf.plan.deck_depots(0)
	if not check(not list.is_empty(), "deck 1 has a depot"):
		return
	var id0 := str(list[0]["id"])
	var site: Dictionary = dp.sites[id0]
	_kill_all()
	# Enemies never acquire a depot: every live enemy's target scan, the crew far away on another deck.
	td.mech.global_position = td.stack.from_deck_arc(td.stack.decks.size() - 1, 0.0, 0.0, 2.0)
	await _seconds(0.2)
	var space := world.get_world_3d().direct_space_state
	var picked := 0
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed() and e.has_method("_acquire_target"):
			var t: Variant = e.call("_acquire_target", space)
			if t is DepotTarget:
				picked += 1
	eq(picked, 0, "no enemy acquires a depot")
	# C. Out of range: nothing.
	var pt := td.combat.player_target
	pt.apply_damage(200.0, "torso", "test")
	td.mech.heat = td.mech.heat_cap * 0.9
	# Out of range: the first gap past CLAIM_RANGE + RANGE_SLACK where a Strider capsule stands clear (a prop or a tree there
	# would push the mech back toward the depot).
	var gap := MissionDepots.CLAIM_RANGE + MissionDepots.RANGE_SLACK + 2.0
	var fdir: Vector2 = SiteFit.FACE_DIRS[int(site["face"])]
	var fhalf := SupplyDepot.footprint_half(int(site["face"]))
	var ring0 := td.stack.deck_ring(int(site["deck"]))
	var sp3 := td.get_world_3d().direct_space_state
	while gap < 40.0:
		var gp := Vector2(float(site["x"]), float(site["s"])) + fdir * (absf(fdir.x) * fhalf.x + absf(fdir.y) * fhalf.y + gap)
		if BotFit.clear_at(sp3, ring0, gp.x, gp.y, 2.4, 8.0, float(site.get("h", 0.0))):
			break
		gap += 1.0
	await _stand(site, gap)
	await _seconds(2.6)
	var full := int(dp.cores_max[id0])
	eq(int(dp.cores_left[id0]), full, "out of range: no core taken")
	eq(dp.progress_line(), "", "out of range: no progress line")
	var ma := td.stack.to_deck_arc(td.mech.global_position)
	eq(dp.refusal(dp.local_peer(), id0), "range", "the host refuses a claim from out of range (mech deck %d (%.1f, %.1f), %.1f m from %s's footprint at (%.1f, %.1f) face %d)" % [
		int(ma["deck"]), float(ma["x"]), float(ma["s"]), dp.footprint_dist(id0, float(ma["x"]), float(ma["s"])), id0, float(site["x"]),
		float(site["s"]), int(site["face"])])
	# In range: the line rises, then the core is taken after 2 s.
	_kill_all()
	await _stand(site, 3.0)
	check(dp.depot_in_range(td.mech.global_position, MissionDepots.CLAIM_RANGE) == id0, "standing in range of " + id0)
	await _seconds(1.0)
	var line := dp.progress_line()
	check(line.begins_with("Taking power core: ") and int(line.trim_prefix("Taking power core: ").trim_suffix("%")) in range(35, 70),
		"halfway: the progress line (%s)" % line)
	var lines: Array = mf.hud_model.build().get("lines", [])
	check(lines.has(line), "the line is in the objective panel's lines (%s)" % [lines])
	eq(int(dp.cores_left[id0]), full, "not taken before 2 s")
	if not check(await _until(func() -> bool: return int(dp.cores_left[id0]) == full - 1, 2.0), "the core is taken after 2 s"):
		return
	eq(dp.applied, 1, "the effect is applied once")
	near(float(pt.hp["torso"]), 200.0 + 0.5 * 200.0, 0.5, "the drive's mech: torso +50 % of missing")
	near(td.mech.heat, 0.0, 1.0, "the drive's mech: heat vented")
	await _seconds(0.1)
	eq((dp.nodes[id0] as SupplyDepot).lit_cells(), full - 1, "the cell goes dark")
	eq(dp.progress_line(), "", "the line is gone once taken")
	check(not (mf.hud_model.build().get("lines", []) as Array).any(func(l: Variant) -> bool: return str(l).begins_with("Taking")),
		"no core line in the panel after")
	# Still standing: the second core after the cooldown (2 cores solo), then the depot is empty.
	check(await _until(func() -> bool: return int(dp.cores_left[id0]) == 0,
		MissionDepots.CLAIM_COOLDOWN + MissionDepots.CLAIM_TIME + 1.0), "the second core after the cooldown")
	eq(dp.applied, full, "one effect per core")
	# Empty: standing on gives nothing more; a forced claim is denied.
	await _seconds(MissionDepots.CLAIM_COOLDOWN + 0.5)
	eq(dp.applied, full, "an empty depot gives nothing more")
	dp.claim_now(id0)
	eq(str(dp.records[-1].get("reason", "")), "empty", "a claim on the empty depot is denied: empty (%s)" % [dp.records[-1]])
	eq(int(dp.cores_left[id0]), 0, "never below zero")
	await _bot(dp)
	# D. Destroyed: another depot (or this one) loses its cores.
	var victim := ""
	for d: Dictionary in mf.plan.depots:
		if dp.has_cores(str(d["id"])):
			victim = str(d["id"])
			break
	if check(victim != "", "a depot with cores left to destroy"):
		var n := dp.nodes[victim] as SupplyDepot
		n.target.apply_damage(DepotTarget.MAX_HP * 0.5, "", "test")
		check(dp.has_cores(victim), "half its HP: still standing")
		n.target.apply_damage(DepotTarget.MAX_HP, "", "test")
		check(not bool(dp.alive[victim]), "destroyed")
		eq(int(dp.cores_left[victim]), 0, "its cores are lost")
		await _seconds(0.1)
		check(not n.target.is_hittable(), "a wreck is not hittable")
		check(bool(n.view.get("dead") if "dead" in n.view else n.view.get("_destroyed")), "the wreck shows")
		eq(n.lit_cells(), 0, "no lit cell")
		eq(dp.refusal(dp.local_peer(), victim), "destroyed", "claims are refused: destroyed")
		eq(mf.plan_state()["depots"][victim], [0, 0], "the replicated state says so")
	td.queue_free()
	await frames(3)


## E. A host bot (pilot -1, a CrewBot made here as MissionScene does for a hangar bot, no AI): healthy, standing at a depot
## it takes nothing (the need rule); damaged, it takes exactly one core after 2 s and the effect lands on ITS mech.
func _bot(dp: MissionDepots) -> void:
	var idb := ""
	for d: Dictionary in td.mission.plan.depots:
		if dp.has_cores(str(d["id"])):
			idb = str(d["id"])
			break
	if not check(idb != "", "a depot with cores for the bot"):
		return
	var m := MechSpawn.make("pickle", "strider", {"side_l": "autocannon", "side_r": "laser", "shoulder_l": "missiles",
		"shoulder_r": "rockets", "back": ""}, -1, "red")
	m.ring = td.city.ring
	td.add_child(m)
	var cb := CrewBot.new()
	td.add_child(cb)
	cb.setup(td, -1, m, "veteran")
	td.crew_bots[-1] = cb
	var site: Dictionary = dp.sites[idb]
	var s := float(site["s"]) + SupplyDepot.footprint_half(int(site.get("face", 0))).y + 3.0
	m.global_position = td.stack.from_deck_arc(int(site["deck"]), float(site["x"]), s, float(site.get("h", 0.0)) + 0.5)
	m.velocity = Vector3.ZERO
	_kill_all()
	check(not dp.needs_core(-1), "a healthy bot needs no core")
	var before := int(dp.cores_left[idb])
	await _seconds(MissionDepots.CLAIM_TIME + 1.0)
	eq(int(dp.cores_left[idb]), before, "a healthy bot standing at the depot takes none")
	check(dp.depot_in_range(m.global_position, MissionDepots.CLAIM_RANGE) == idb, "the bot stands in range")
	cb.target.apply_damage(300.0, "torso", "test")
	cb.target.apply_damage(1000.0, "side_l", "test")
	check(dp.needs_core(-1), "a damaged bot (a component destroyed) needs a core")
	check(not dp.needs_core(dp.local_peer()), "the need rule applies to bots only")
	if not check(await _until(func() -> bool: return int(dp.cores_left[idb]) == before - 1, MissionDepots.CLAIM_TIME + 1.0),
			"the damaged bot takes the core"):
		return
	await _seconds(MissionDepots.CLAIM_TIME + 0.5)
	var grants := dp.records.filter(func(r: Dictionary) -> bool: return str(r["kind"]) == "grant" and int(r.get("peer", 0)) == -1)
	eq(grants.size(), 1, "exactly one core for the bot (%s)" % [grants])
	near(float(cb.target.hp["torso"]), 100.0 + 0.5 * 300.0, 0.5, "the bot's torso: +50 % of missing")
	near(float(cb.target.hp["side_l"]), PlayerTarget.WEAPON_HP * MissionDepots.CORE_REBUILD, 0.5, "the bot's hardpoint rebuilt")
	check(not dp.needs_core(-1) or float(cb.target.total_hp()) / cb.target.total_max_hp() < MissionDepots.BOT_NEED_STRUCTURE,
		"after the core the bot needs none (unless still under the structure line)")
	td.crew_bots.erase(-1)
	td.combat.world.unregister(cb.target)
	cb.queue_free()
	m.queue_free()
	await _seconds(0.1)
	# Freed mid-timer: a damaged bot (pilot -2) stands at a depot, then its CrewBot and its mech are freed while the depot
	# code still has it in crew_bots: no error, no grant.
	var idc := ""
	for d: Dictionary in td.mission.plan.depots:
		if dp.has_cores(str(d["id"])):
			idc = str(d["id"])
			break
	if not check(idc != "", "a depot with cores for the freed-bot check"):
		return
	var m2 := MechSpawn.make("corn", "strider", {}, -2, "blue")
	m2.ring = td.city.ring
	td.add_child(m2)
	var cb2 := CrewBot.new()
	td.add_child(cb2)
	cb2.setup(td, -2, m2, "veteran")
	td.crew_bots[-2] = cb2
	var site2: Dictionary = dp.sites[idc]
	var s2 := float(site2["s"]) + SupplyDepot.footprint_half(int(site2.get("face", 0))).y + 3.0
	m2.global_position = td.stack.from_deck_arc(int(site2["deck"]), float(site2["x"]), s2, float(site2.get("h", 0.0)) + 0.5)
	cb2.target.apply_damage(350.0, "torso", "test")
	cb2.target.apply_damage(150.0, "leg_l", "test")
	cb2.target.apply_damage(150.0, "leg_r", "test")
	check(dp.needs_core(-2), "the freed-bot check: the bot needs a core")
	var left2 := int(dp.cores_left[idc])
	var n0 := dp.records.size()
	await _seconds(MissionDepots.CLAIM_TIME * 0.5)
	check(dp._bot_stand.has(-2), "the freed-bot check: the bot's timer is running (needs %s, in range %s, stand %s)"
		% [dp.needs_core(-2), dp.depot_in_range(m2.global_position, MissionDepots.CLAIM_RANGE), dp._bot_stand])
	td.combat.world.unregister(cb2.target)
	cb2.free()
	await _seconds(0.3)
	m2.free()
	await _seconds(MissionDepots.CLAIM_TIME + 0.5)
	eq(int(dp.cores_left[idc]), left2, "a freed bot takes no core")
	eq(dp.records.size(), n0, "no claim or grant for a freed bot")
	check(not dp.needs_core(-2), "a freed bot needs nothing")
	td.crew_bots.erase(-2)


## Stand the mech `gap` m off the socket wall of the depot at `site` (its footprint, the side its stand spot is on), still.
func _stand(site: Dictionary, gap: float) -> void:
	var f := int(site.get("face", 0))
	var dir: Vector2 = SiteFit.FACE_DIRS[f]
	var half := SupplyDepot.footprint_half(f)
	var p := Vector2(float(site["x"]), float(site["s"])) + dir * (absf(dir.x) * half.x + absf(dir.y) * half.y + gap)
	td.mech.global_position = td.stack.from_deck_arc(int(site["deck"]), p.x, p.y, float(site.get("h", 0.0)) + 0.5)
	td.mech.velocity = Vector3.ZERO
	td.mech.move_input = Vector2.ZERO
	await _seconds(0.05)


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


func _seconds(s: float) -> void:
	for i in ceili(s * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


# --- G. Never trapped on or beside a depot (R2.23, 2026-11-26) ------------------------------------------------------
# The user's Strider wedged at a corner of the old 6 x 4.35 x 4 box and could not move any way. Cause (reproduced on
# the seed 7 / 2 decks): on a curved deck the box, square to the deck at its centre, leans its end faces ~0.4 deg out
# past local vertical; a capsule walking into that overhanging corner sank into it and every move_and_slide was blocked
# (8 of 8 directions: 0 m). Also the visible roof overhung the box by 0.15-0.35 m. Now: SupplyDepot.collision_shape.

const G_DT := 1.0 / 60.0
const G_LEAVE := 3.0           ## s of plain walk input to get FOOTPRINT + G_CLEAR m away
const G_CLEAR := 3.0           ## m past the visible footprint (+ the capsule's radius)
var _g: MechController
var _gd: SupplyDepot
var _g_fail := 0
var _g_judged := 0


## The real capsule of each chassis on a flat floor, the real depot body (no ring: edges straight up). Every case must
## leave the visible footprint + G_CLEAR m within G_LEAVE s under plain walk input, never below the floor, never inside
## the depot, and never through the controller's wedge nudge (the safety net is not relied on).
func _collision_flat() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var fl := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(200, 1, 200)
	cs.shape = bx
	cs.position = Vector3(0, -0.5, 0)
	fl.add_child(cs)
	holder.add_child(fl)
	_gd = SupplyDepot.new()
	var dist := CityDistrict.new()
	_gd.build(dist, Transform3D.IDENTITY, "g", 0, 2, 0)
	dist.free()
	holder.add_child(_gd)
	await frames(2)
	# The collision matches the visible kiosk: the roof's footprint, the roof's height.
	var sh := (_gd.body.get_child(0) as CollisionShape3D).shape as ConvexPolygonShape3D
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for p: Vector3 in sh.points:
		lo = lo.min(p)
		hi = hi.max(p)
	# Out of the pin band: the walls rise past every chassis' straight side (capsule height - radius above the feet).
	for ch: String in ["strider", "bulwark", "wasp"]:
		var mv := MechCatalog.movement(ch, true)
		var band := float(mv["capsule_height"]) - float(mv["capsule_radius"])
		check(SupplyDepot.WALL_H > band + 0.3, "G: walls (%.1f m) above the %s's straight side (%.1f m)" % [SupplyDepot.WALL_H, ch, band])
	near(hi.y, SupplyDepot.WALL_H, 0.01, "G: a flat top at the walls' height (no rim, no cap)")
	near(lo.y, 0.0, 0.01, "G: from the floor")
	near(hi.x - lo.x, DepotMeshes.W + 0.6, 0.01, "G: collision as wide as the roof slab (6.6 m)")
	near(lo.z, -DepotMeshes.D * 0.5 - 0.15, 0.01, "G: back face at the roof's back edge")
	near(hi.z, DepotMeshes.D * 0.5 + 0.35, 0.01, "G: front face at the roof's front lip")
	eq(_gd.body.get_child_count(), 1, "G: one collision shape (no mast collider, no hit shape on the body)")
	check(_gd.target.find_children("*", "CollisionObject3D").is_empty(),
		"G: the DepotTarget's hit spheres are no physics bodies (nothing on the movement layer)")
	for ch: String in ["strider", "bulwark", "wasp"]:
		var m := MechSpawn.make("chicken", ch, {}, 0, "", ch == "wasp")
		holder.add_child(m)
		await frames(1)
		m.set_physics_process(false)
		_g = m
		_g_cases(ch)
		m.queue_free()
		await frames(1)
	print("[Test] G flat: %d failing cases" % _g_fail)
	holder.queue_free()
	await frames(2)


func _g_cases(ch: String) -> void:
	var r := _g_r()
	var biped := not _g.hover_mode
	for i in 16:
		var a := TAU * i / 16.0
		var dir := Vector3(cos(a), 0, sin(a))
		for run_: bool in ([false, true] if biped else [false]):
			_g_place(dir * (r + 9.0), -dir)
			_g_fly()
			_g.running = run_
			_g_drive(Vector2(0, 1), 120)
			_g.running = false
			_g_leave("%s walks into it from %d/16%s" % [ch, i, " running" if run_ else ""])
	for sd in 4:
		var n := [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0)][sd] as Vector3
		var half := 2.35 if sd % 2 == 0 else 3.3
		var along := n.cross(Vector3.UP)
		_g_place(n * (half + r + 0.05) - along * 6.0, -n)
		_g_fly()
		_g_drive(Vector2(0.4, 1.0), 30)
		_g_drive(Vector2(1.0, 0.3), 150)
		_g_leave("%s strafes along side %d" % [ch, sd])
	if not biped:
		return
	for xi: float in [-2.6, 0.0, 2.6]:
		for zi: float in [-1.6, 0.0, 1.8]:
			_g_place(Vector3(xi, 14.0, zi), Vector3(1, 0, 0))
			_g_drive(Vector2.ZERO, 150)
			near(_g_local().y, SupplyDepot.WALL_H, 0.3, "G: %s dropped on it at (%.1f, %.1f) stands on the top" % [ch, xi, zi])
			_g_leave("%s dropped on it at (%.1f, %.1f)" % [ch, xi, zi])
	for i in 16:
		var a := TAU * i / 16.0
		var dir := Vector3(cos(a), 0, sin(a))
		_g_place(dir * (r + 12.0), -dir)
		_g.thrust_input = true
		_g_drive(Vector2(0, 1), 70)
		_g.thrust_input = false
		_g_drive(Vector2(0, 1), 40)
		_g_drive(Vector2.ZERO, 120)
		_g_leave("%s thrust-lands toward it from %d/16" % [ch, i])
	for i in 8:
		var a := TAU * i / 8.0
		var dir := Vector3(cos(a), 0, sin(a))
		_g_place(dir * (r + 5.0), -dir)
		_g.velocity = -dir * 25.0 + Vector3.UP * 4.0
		_g_drive(Vector2.ZERO, 90)
		_g_leave("%s knocked against it from %d/8" % [ch, i])


func _g_r() -> float:
	return ((_g.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D).radius


func _g_local() -> Vector3:
	return _gd.global_transform.affine_inverse() * _g.global_position


func _g_place(p: Vector3, fwd: Vector3) -> void:
	var w := _gd.global_transform * p
	var u := _g.ring.up_at(w) if _g.ring != null else Vector3.UP
	var f := _gd.global_basis * fwd
	f = (f - u * f.dot(u)).normalized()
	_g.global_transform = Transform3D(Basis(f.cross(u), u, -f), w)
	_g.velocity = Vector3.ZERO
	_g.move_input = Vector2.ZERO
	_g.thrust_input = false
	_g.running = false
	_g.heat = 0.0
	_g.shutdown = false
	_g._wedge_t = 0.0
	_g._wedge_nudge = 0.0
	_g._climbing = false


## A hover chassis lifts off first (it does not walk landed).
func _g_fly() -> void:
	if not _g.hover_mode:
		return
	_g.climb_input = 1.0
	_g_drive(Vector2.ZERO, 20)
	_g.climb_input = 0.0


func _g_face(dv: Vector3) -> void:
	var u := _g.up()
	var f := _gd.global_basis * dv
	f = (f - u * f.dot(u)).normalized()
	_g.global_basis = Basis(f.cross(u), u, -f)


func _g_drive(mv: Vector2, steps: int) -> void:
	_g.move_input = mv
	for i in steps:
		_g.step(G_DT)
	_g.move_input = Vector2.ZERO


## Distance (m) from depot-local point lp to the visible footprint (the roof slab), across the floor.
static func _g_foot(lp: Vector3) -> float:
	var dx := maxf(absf(lp.x) - SupplyDepot.FOOT_X, 0.0)
	var dz := maxf(maxf(SupplyDepot.FOOT_Z0 - lp.z, lp.z - SupplyDepot.FOOT_Z1), 0.0)
	return sqrt(dx * dx + dz * dz)


## From where the mech rests: plain walk input straight away from the depot's centre.
func _g_leave(tag: String) -> void:
	var start := _g_local()
	var away := Vector3(start.x, 0, start.z)
	away = away.normalized() if away.length() > 0.3 else Vector3(1, 0, 0)
	_g_face(away)
	_g.move_input = Vector2(0, 1)
	var nudge := 0.0
	var low := false
	var t := 0
	var goal := _g_r() + G_CLEAR
	while t < roundi(G_LEAVE / G_DT) and _g_foot(_g_local()) < goal:
		_g.step(G_DT)
		nudge = maxf(nudge, _g._wedge_nudge)
		low = low or _g_local().y < -0.3
		t += 1
	_g.move_input = Vector2.ZERO
	var end := _g_local()
	var ok := _g_foot(end) >= goal and nudge <= 0.0 and not low
	if not ok:
		_g_fail += 1
	check(ok, "G: %s: rests at (%.2f, %.2f, %.2f), walking away reaches (%.2f, %.2f, %.2f) in %.2f s (needs %.1f m past the footprint; nudge %.2f, below floor %s)" % [
		tag, start.x, start.y, start.z, end.x, end.y, end.z, t * G_DT, goal, nudge, low])


## On the real seed 7 decks (curved: the depot's edges follow the ring's up): every depot, Strider and Bulwark walking
## into it from 16 directions (walk and run): from where it rests it must not be pinned: free (>= 1 m in 1.5 s) in at
## least 4 of 8 directions and straight away from the depot, with no wedge nudge (judged where it rests touching the
## depot; a rest against other scenery is not the depot's). (The full escape distance is the flat
## case's: real sites have props and kerbs round them.)
func _collision_ring(dp: MissionDepots) -> void:
	_kill_all()
	for id: String in dp.nodes:
		_gd = dp.nodes[id]
		for ch: String in ["strider", "bulwark"]:
			var m := MechSpawn.make("chicken", ch, {}, 0, "", false)
			td.add_child(m)
			await frames(1)
			m.set_physics_process(false)
			m.ring = td.stack.deck_ring(_gd.deck)
			_g = m
			var r := _g_r()
			for i in 16:
				var a := TAU * i / 16.0
				var dir := Vector3(cos(a), 0, sin(a))
				for run_: bool in [false, true]:
					_g_place(dir * (r + 9.0), -dir)
					_g.running = run_
					_g_drive(Vector2(0, 1), 120)
					_g.running = false
					_g_free("%s %s walks into it from %d/16%s" % [id, ch, i, " running" if run_ else ""])
			m.queue_free()
			await frames(1)
	print("[Test] G ring: %d rests against a depot judged" % _g_judged)
	check(_g_judged >= 100, "G ring: enough rests against the depots (%d)" % _g_judged)


func _g_free(tag: String) -> void:
	var startw := _g.global_transform
	var start := _g_local()
	if _g_foot(start) > _g_r() + 0.5:
		return   # it rests against something else (a prop, a kerb, a tree): not the depot's matter
	_g_judged += 1
	var away := Vector3(start.x, 0, start.z).normalized()
	var free := 0
	var away_ok := false
	var nudge := 0.0
	var moves := PackedStringArray()
	for k in 9:
		_g.global_transform = startw
		_g.velocity = Vector3.ZERO
		_g._wedge_t = 0.0
		_g._wedge_nudge = 0.0
		var dv := away if k == 8 else Vector3(cos(TAU * k / 8.0), 0, sin(TAU * k / 8.0))
		_g_face(dv)
		_g_drive(Vector2(0, 1), 90)
		nudge = maxf(nudge, _g._wedge_nudge)
		var d := _g_local() - start
		var hm := Vector2(d.x, d.z).length()
		moves.append("%.1f" % hm)
		if k == 8:
			away_ok = hm >= 1.0
		elif hm >= 1.0:
			free += 1
	check(free >= 4 and away_ok and nudge <= 0.0, "G ring: %s: rests at (%.2f, %.2f, %.2f) and is pinned (moves %s, away last; nudge %.2f)" % [
		tag, start.x, start.y, start.z, ",".join(moves), nudge])
