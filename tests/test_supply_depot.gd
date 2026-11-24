extends TestCase
## Military supply depots (docs/design/pacing-director.md §2; scripts/game/mission_depots.gd, supply_depot.gd,
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

const SEED := 7
const PLAN := {"hold": 6.0, "linger": 600.0}

var td: TestDrive


func _init() -> void:
	timeout_sec = 480.0


func setup() -> void:
	await _effect()
	await _view()
	MissionFlow.test_plan = PLAN
	await _drive()
	await _keep_out()
	MissionFlow.test_plan = {}
	finish()


# --- F. Off the roads (2026-11-24: seed 2's d0_depot0 stood on a road line and wedged the bot) ----------------------

const KEEP_SEEDS: Array[int] = [1, 2, 3, 7, 17, 26, 403112]


## On built decks: every depot's footprint (+ the 4 m margin) is clear of the road strips, ramps, floor cuts, gate bay
## corridors and sources, and 3 m (+ half-width) off every walk-graph edge; the standing area in front of the socket
## wall fits a mech capsule within claim range; seed 2 deck 1's depot left the road line at (-57, -154).
func _keep_out() -> void:
	var total := 0
	var fallbacks := 0
	for sd in KEEP_SEEDS:
		var t := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
		t.city_mode = TestDrive.MODE_STACK
		t.seed_value = sd
		t.objectives = true
		add_child(t)
		await frames(3)
		var dp := t.mission.depots if t.mission != null else null
		if not check(dp != null, "seed %d: depots" % sd):
			t.queue_free()
			await frames(2)
			continue
		fallbacks += dp.placement_fallbacks
		var sec := t.stack.section
		for id: String in dp.sites:
			total += 1
			var st: Dictionary = dp.sites[id]
			var k := int(st["deck"])
			var at := Vector2(float(st["x"]), float(st["s"]))
			var f := int(st["face"])
			var tag := "seed %d %s at (%.0f, %.0f) face %d" % [sd, id, at.x, at.y, f]
			if bool(st.get("fallback", false)):
				continue
			var fr := MissionDepots.footprint_rect(at, f)
			for sg: Dictionary in sec.segments(k):
				if str(sg["form"]) != "none" and fr.grow(MissionDepots.KEEP_MARGIN).intersects(sg["rect"]):
					check(false, tag + ": clear of road %s %d/%d (%s) by 4 m" % [sg["axis"], int(sg["line"]), int(sg["index"]), sg["form"]])
			var cp := t.stack.decks[k].plan
			var g := cp.walk_graph(true)
			for ed: Array in g["edges"]:
				var a: Vector2 = g["nodes"][int(ed[0])]
				var b: Vector2 = g["nodes"][int(ed[1])]
				if MissionDepots.rect_seg_dist(fr, a, b) < MissionDepots.WALK_GAP:
					check(false, tag + ": 3 m off walk edge %s-%s" % [a, b])
			for c: Rect2 in cp.floor_cuts():
				check(not fr.grow(MissionDepots.KEEP_MARGIN).intersects(c), tag + ": clear of a floor cut")
			for rp: Dictionary in cp.ramps:
				var rr := Rect2(float(rp["x0"]), minf(float(rp["s_top"]), float(rp["s_foot"])), float(rp["x1"]) - float(rp["x0"]),
					absf(float(rp["s_top"]) - float(rp["s_foot"])))
				check(not fr.grow(MissionDepots.KEEP_MARGIN).intersects(rr.grow(2.0)), tag + ": clear of a ramp")
			eq(MissionDepots.keep_hit(dp.keep_out(k), at, f), "", tag + ": the whole keep-out (bay corridors, sources, masts)")
			var sp := MissionDepots.stand_point(at, f)
			check(bool(MissionProps.snap_site(t.stack.decks[k], sp, 0.0, MissionDepots.MECH_R)["ok"]),
				tag + ": a mech capsule fits in front of the socket wall")
			check(dp.footprint_dist(id, sp.x, sp.y) <= MissionDepots.CLAIM_RANGE, tag + ": the standing spot is within claim range")
			if sd == 2 and k == 0:
				check(at.distance_to(Vector2(-57.0, -154.0)) > 6.0, tag + ": seed 2 deck 1's depot is off the road line at (-57, -154)")
		t.queue_free()
		await frames(3)
	print("[Test] depots off the roads: %d placed over seeds %s, %d by the plain-snap fallback" % [total, KEEP_SEEDS, fallbacks])
	eq(fallbacks, 0, "no depot needed the plain-snap fallback")


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
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = SEED
	td.objectives = true
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
		var fd: Vector2 = MissionDepots.FACE_DIRS[int(st["face"])]
		var sa := td.stack.to_deck_arc(n.socket_world(0))
		check(Vector2(float(sa["x"]) - float(st["x"]), float(sa["s"]) - float(st["s"])).dot(fd) > 1.0,
			id + ": the socket wall faces its chosen open side (face %d)" % int(st["face"]))
		check(not world.spares("enemy", n.target, "enemy_x") and not world.spares("player", n.target, "player1"),
			id + ": no shot spares it (stray enemy fire, crew fire)")
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
	await _stand(site, 6.0 + 6.0)
	await _seconds(2.6)
	var full := int(dp.cores_max[id0])
	eq(int(dp.cores_left[id0]), full, "out of range: no core taken")
	eq(dp.progress_line(), "", "out of range: no progress line")
	eq(dp.refusal(dp.local_peer(), id0), "range", "the host refuses a claim from out of range")
	# In range: the line rises, then the core is taken after 2 s.
	_kill_all()
	await _stand(site, 3.0)
	check(dp.depot_in_range(td.mech.global_position, MissionDepots.CLAIM_RANGE) == id0, "standing in range of " + id0)
	await _seconds(1.0)
	var line := dp.progress_line()
	check(line.begins_with("Taking power core: ") and int(line.trim_prefix("Taking power core: ").trim_suffix("%")) in range(35, 70),
		"halfway: the progress line (%s)" % line)
	var lines: Array = mf.hud_state().get("lines", [])
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
	check(not (mf.hud_state().get("lines", []) as Array).any(func(l: Variant) -> bool: return str(l).begins_with("Taking")),
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


## E. A host bot (pilot -1, a CrewBot made here as TestDrive does for a hangar bot, no AI): healthy, standing at a depot
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


## Stand the mech `gap` m off the +s face of the depot at `site` (its footprint), still.
func _stand(site: Dictionary, gap: float) -> void:
	var s := float(site["s"]) + SupplyDepot.footprint_half(int(site.get("face", 0))).y + gap
	td.mech.global_position = td.stack.from_deck_arc(int(site["deck"]), float(site["x"]), s, float(site.get("h", 0.0)) + 0.5)
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
