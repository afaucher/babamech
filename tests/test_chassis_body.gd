extends TestCase
## Each chassis' damage body (PlayerTarget: per-chassis hit spheres, component HP, wall probe, enemy sight offsets),
## headless, fixed steps, no wall clock:
##  - COVERAGE against the real meshes (tests/chassis_body_probe.gd: a MechSpawn mech standing, default loadout, as
##    backface-colliding triangle soups): `under` = rays aimed at visible mesh points (random directions) that meet the
##    mesh but no sphere within TOL m of it ("shots pass through the visible hull"), `over` = rays through the spheres'
##    silhouettes whose first sphere is not followed by the mesh within TOL m ("sticks out"), `comp` = the share of covered
##    rays whose first sphere is the mesh's own component. Printed for both chassis (body spheres alone and with the
##    hardpoint spheres); the Bulwark's body is held to BODY_UNDER_MAX / BODY_OVER_MAX / COMP_MIN, each pilot head too.
##    The Strider's spheres are pinned unchanged (STRIDER_GOLDEN), its numbers only printed (they predate this test).
##  - the component map and HP per chassis, every id known to the codec; the wall probe from the catalog capsule.
##  - damage -> component routing through CombatWorld.first_hit from several sides, for both chassis.
##  - destroyed components: a core one downs the mech, a hardpoint does not (its slot reads destroyed).
##  - DownedCrew's reviver rule: a repair drone on the Strider's back or either Bulwark back mount, not once destroyed.
##  - the repair drone hovers over the Bulwark's back mounts (RepairDrone.back_height by chassis / hardpoint).
##  - the enemy sight offsets: the Strider's are EnemyBase's old constants, the Bulwark's land on its head / a leg.

const Probe := preload("res://tests/chassis_body_probe.gd")
const RAYS := 4000
const BODY_UNDER_MAX := 0.03      ## Bulwark: visible body rays that miss every body sphere
const BODY_OVER_MAX := 0.35       ## Bulwark: body-sphere rays with no mesh within TOL
const COMP_MIN := 0.85            ## Bulwark: covered rays routed to the mesh's own component
const HEAD_UNDER_MAX := 0.06      ## Bulwark: per pilot head, visible head rays missing every sphere
## The Strider's body spheres and HP before this change (2026-11-24): must not move.
const STRIDER_GOLDEN := [
	{"component": "torso", "center": Vector3(0.0, 4.4, 0.0), "radius": 2.05},
	{"component": "head", "center": Vector3(0.0, 7.1, -0.75), "radius": 0.95},
	{"component": "leg_l", "center": Vector3(-1.35, 2.0, 0.0), "radius": 1.15},
	{"component": "leg_r", "center": Vector3(1.35, 2.0, 0.0), "radius": 1.15},
]
const STRIDER_HP := {"torso": 400.0, "leg_l": 200.0, "leg_r": 200.0, "head": 100.0}

var _floor: StaticBody3D


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_floor = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 1, 600)
	cs.shape = box
	_floor.add_child(cs)
	_floor.position = Vector3(0, -0.5, 0)
	add_child(_floor)
	_strider_golden()
	await _coverage("strider", "chicken", true)
	await _coverage("bulwark", "chicken", true)
	for h: String in MechCatalog.HEAD_ORDER:
		if h != "chicken":
			await _coverage("bulwark", h, false)
	await _components()
	await _routing("strider")
	await _routing("bulwark")
	await _destroyed()
	await _reviver()
	await _drone_height()
	_sight()
	_audio_heft()
	finish()


func _strider_golden() -> void:
	eq(str(PlayerTarget.BODY_SPHERES), str(STRIDER_GOLDEN), "the Strider's body spheres are unchanged")
	eq(str(PlayerTarget.body_spheres("strider")), str(STRIDER_GOLDEN), "body_spheres(strider) = BODY_SPHERES")
	eq(str(PlayerTarget.COMPONENT_HP), str(STRIDER_HP), "the Strider's component HP is unchanged")
	eq(str(PlayerTarget.component_hp("strider")), str(STRIDER_HP), "component_hp(strider) = COMPONENT_HP")
	eq(str(PlayerTarget.hardpoint_spheres("strider")), str(PlayerTarget.HARDPOINT_SPHERES), "the Strider's hardpoint spheres")
	var pt := PlayerTarget.new()
	near(pt.probe_height, 4.0, 1e-6, "the Strider's wall probe height is unchanged")
	near(pt.body_radius, 2.2, 1e-6, "the Strider's body radius is unchanged")
	eq(pt.hit_shapes.size(), 4, "a bare Strider: four body spheres")
	pt.free()


## Ray coverage of `chassis` with pilot `head` (full = also print / hold the whole-model numbers).
func _coverage(chassis: String, head: String, full: bool) -> void:
	var mech := Probe.spawn(self, chassis, head)
	await frames(60)
	var pr := Probe.new()
	pr.gather(mech)
	mech.queue_free()
	await frames(2)
	pr.build(self)
	await frames(2)
	var space := get_viewport().get_world_3d().direct_space_state
	var body: Array = PlayerTarget.body_spheres_for(chassis, head)
	var all := body.duplicate()
	var hps := PlayerTarget.hardpoint_spheres(chassis)
	for hp_id: String in hps:
		if pr.comps.has(hp_id):
			all.append({"component": hp_id, "center": hps[hp_id]["center"], "radius": hps[hp_id]["radius"]})
	if chassis == "bulwark":
		pr.debug_component = "head"
	var cb := pr.coverage(space, body, RAYS, 11)
	if pr.debug_points.size() > 0:
		var bb := AABB(pr.debug_points[0], Vector3.ZERO)
		for q in pr.debug_points:
			bb = bb.expand(q)
		print("    %s head misses (%d) within %s" % [head, pr.debug_points.size(), str(bb)])
	var head_under := float(int((cb["per_miss"] as Dictionary).get("head", 0))) / maxf(int((cb["per_hit"] as Dictionary).get("head", 0)), 1)
	if full:
		var ca := pr.coverage(space, all, RAYS, 11)
		print("  [coverage] %-8s body spheres (%d): body under %.1f%%  over %.1f%%  own component %.1f%%  head under %.1f%%" % [
			chassis, body.size(), 100.0 * float(cb["body_under"]), 100.0 * float(cb["over"]), 100.0 * float(cb["comp"]), 100.0 * head_under])
		print("  [coverage] %-8s + hardpoints (%d): whole-model under %.1f%%  over %.1f%%  own component %.1f%%  misses %s" % [
			chassis, all.size(), 100.0 * float(ca["under"]), 100.0 * float(ca["over"]), 100.0 * float(ca["comp"]), str(ca["per_miss"])])
		if chassis == "bulwark":
			check(float(cb["body_under"]) <= BODY_UNDER_MAX, "Bulwark: shots at the visible hull / head / legs meet a sphere (%.1f%% miss, max %.0f%%)" % [
				100.0 * float(cb["body_under"]), 100.0 * BODY_UNDER_MAX])
			check(float(cb["over"]) <= BODY_OVER_MAX, "Bulwark: the body spheres do not stick out far past the meshes (%.1f%%, max %.0f%%)" % [
				100.0 * float(cb["over"]), 100.0 * BODY_OVER_MAX])
			check(float(ca["comp"]) >= COMP_MIN, "Bulwark: hits land on the part they strike (%.1f%%, min %.0f%%)" % [
				100.0 * float(ca["comp"]), 100.0 * COMP_MIN])
	else:
		print("  [coverage] bulwark head %-7s: head under %.1f%%" % [head, 100.0 * head_under])
	if chassis == "bulwark":
		check(head_under <= HEAD_UNDER_MAX, "Bulwark %s: shots at the pilot's head meet a sphere (%.1f%% miss)" % [head, 100.0 * head_under])
	pr.free_bodies()
	await frames(2)


func _bound(chassis: String, loadout: Dictionary = {}) -> Dictionary:
	var world := CombatWorld.new()
	add_child(world)
	var mech := MechSpawn.make("chicken", chassis, loadout, 1)
	add_child(mech)
	await frames(3)
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, MechSpawn.rig_of(mech).model, "player1", 1)
	world.register(pt)
	return {"world": world, "mech": mech, "pt": pt}


func _free(r: Dictionary) -> void:
	for k: String in ["pt", "mech", "world"]:
		(r[k] as Node).queue_free()
	await frames(2)


func _components() -> void:
	var r := await _bound("bulwark")
	var pt: PlayerTarget = r["pt"]
	eq(pt.chassis, "bulwark", "the target knows its chassis")
	var want := {"torso": 600.0, "leg_l": 280.0, "leg_r": 280.0, "head": 100.0, "side_l": 80.0, "side_r": 80.0, "back_l": 80.0,
		"back_r": 80.0}
	eq(pt.max_hp.size(), want.size(), "Bulwark components: %s" % str(pt.max_hp.keys()))
	for k: String in want:
		near(float(pt.max_hp.get(k, -1.0)), float(want[k]), 1e-6, "Bulwark %s HP" % k)
		check(k in NetMechCodec.COMPONENTS, "%s is a codec component" % k)
	near(pt.probe_height, 4.0, 1e-6, "Bulwark wall probe at its capsule's centre")
	near(pt.body_radius, 3.6, 1e-6, "Bulwark body radius = its capsule")
	eq(pt.hit_shapes.size(), PlayerTarget.body_spheres("bulwark").size() + 4, "body spheres + four loaded hardpoints")
	var first: Dictionary = pt.hit_shapes[0]
	eq(str(first["component"]), "torso", "the first sphere (the enemies' aim centre) is the hull")
	check((first["center"] as Vector3).y > 4.0 and (first["center"] as Vector3).y < 6.5, "the aim centre is in the hull's height band")
	await _free(r)
	var r2 := await _bound("bulwark", {"side_l": "autocannon", "side_r": "", "back_l": "", "back_r": "repair_drone"})
	eq((r2["pt"] as PlayerTarget).max_hp.has("side_r"), false, "an empty hardpoint is no component")
	eq((r2["pt"] as PlayerTarget).max_hp.has("back_r"), true, "a back mount with equipment is one")
	await _free(r2)


## Shots from several sides through CombatWorld.first_hit (the shared hit test) land on the expected component.
func _routing(chassis: String) -> void:
	var r := await _bound(chassis)
	var world: CombatWorld = r["world"]
	var pt: PlayerTarget = r["pt"]
	pt.tick(0.0)
	var cases: Array = []
	if chassis == "strider":
		cases = [[Vector3(0, 4.4, -40), Vector3(0, 4.4, 0), "torso"], [Vector3(0, 7.1, -40), Vector3(0, 7.1, 0), "head"],
			[Vector3(-40, 2.0, 0), Vector3(0, 2.0, 0), "leg_l"], [Vector3(40, 1.6, 0), Vector3(0, 1.6, 0), "leg_r"],
			[Vector3(0, 5.8, 40), Vector3(0, 5.8, 0), "back"]]
	else:
		cases = [[Vector3(0, 7.6, -40), Vector3(0, 7.6, 0), "head"], [Vector3(-40, 2.7, -1.58), Vector3(0, 2.7, -1.58), "leg_l"],
			[Vector3(40, 1.0, -0.4), Vector3(0, 1.0, -0.4), "leg_r"], [Vector3(0, 5.3, 40), Vector3(0, 5.3, 0), "torso"],
			[Vector3(-40, 6.2, 0.4), Vector3(0, 6.2, 0.4), "torso"], [Vector3(2.16, 40, 2.0), Vector3(2.16, 0, 2.0), "back_r"],
			[Vector3(3.57, 6.3, -40), Vector3(3.57, 6.3, 0), "side_r"], [Vector3(-2.0, 1.5, -40), Vector3(-2.0, 1.5, 40), ""]]
	for c: Array in cases:
		var h := world.first_hit(c[0] as Vector3, c[1] as Vector3, 0.1, "enemy_x")
		var comp := str(h.get("component", "")) if not h.is_empty() else ""
		eq(comp, str(c[2]), "%s: a shot %s -> %s hits %s" % [chassis, str(c[0]), str(c[1]), str(c[2]) if str(c[2]) != "" else "nothing (between the legs)"])
	await _free(r)


func _destroyed() -> void:
	var r := await _bound("bulwark")
	var pt: PlayerTarget = r["pt"]
	pt.apply_damage(81.0, "back_l", "test")
	check(pt.is_slot_destroyed("back_l") and not pt.disabled, "a destroyed back mount: slot destroyed, the mech fights on")
	pt.apply_damage(279.0, "leg_r", "test")
	check(not pt.disabled, "279 of 280 leg HP: still up")
	pt.apply_damage(2.0, "leg_r", "test")
	check(pt.disabled and pt.disable_cause == "leg_r", "a destroyed leg downs the Bulwark")
	pt.revive("medic")
	check(not pt.disabled, "revived")
	near(float(pt.hp["torso"]), 600.0, 1e-3, "the untouched hull stays full")
	pt.invuln_left = 0.0
	pt.apply_damage(600.0, "torso", "test")
	check(pt.disabled and pt.disable_cause == "torso", "600 hull damage downs it")
	await _free(r)


## DownedCrew._can_revive: a standing crewmate with charges and a live repair drone on a back mount.
func _reviver() -> void:
	var dc := DownedCrew.new()
	for row: Array in [["strider", {"back": "repair_drone"}, "back", true], ["strider", {"back": "mortar"}, "", false],
			["bulwark", {"back_r": "repair_drone"}, "back_r", true], ["bulwark", {"back_l": "repair_drone"}, "back_l", true],
			["bulwark", {"back_l": "mortar", "back_r": "radiator"}, "", false]]:
		var lo := MechCatalog.sanitize_loadout(str(row[0]), row[1] as Dictionary)
		var r := await _bound(str(row[0]), lo)
		var pt: PlayerTarget = r["pt"]
		pt.aid_charges = 2
		var m := {"downed": false, "mech": r["mech"], "target": pt}
		eq(dc._can_revive(m), bool(row[3]), "%s with %s: can revive = %s" % [row[0], str(row[1]), str(row[3])])
		if str(row[2]) != "":
			pt.apply_damage(200.0, str(row[2]), "test")
			eq(dc._can_revive(m), false, "%s: with %s destroyed it cannot revive" % [row[0], row[2]])
		await _free(r)
	dc.free()


## The drone hovers `hover` m over the launcher's own back mount: the Bulwark's back_l / back_r, the Strider's back.
func _drone_height() -> void:
	near(RepairDrone.back_height(), 5.8, 1e-6, "the Strider's back mount height (unchanged)")
	near(RepairDrone.back_height("bulwark", "back_l"), 7.6, 1e-6, "the Bulwark's back_l height")
	near(RepairDrone.back_height("bulwark", "back"), 7.6, 1e-6, "an unknown back id on a Bulwark falls back to its back mount")
	var r := await _bound("bulwark", {"side_l": "", "side_r": "", "back_l": "", "back_r": "repair_drone"})
	var world: CombatWorld = r["world"]
	var mech: MechController = r["mech"]
	world.set_anchor("player1", func() -> Node3D: return mech)
	var d := world.launch_drone({"shooter": "player1", "peer": 1, "hardpoint": "back_r", "weapon": "repair_drone", "t": world.now})
	check(d != null, "the Bulwark's drone launches")
	if d != null:
		for i in 120:
			world.advance(1.0 / 60.0)
		var hover := float(MechCatalog.weapon("repair_drone").get("hover", 6.0))
		near(d.pos.y - mech.global_position.y, 7.6 + hover, 0.15, "it circles %.1f m over the Bulwark's back mount (%.2f m)" % [hover,
			d.pos.y - mech.global_position.y])
	await _free(r)


## Footfalls / landings by weight (MechAudio.heft): the Strider exactly as before, the Bulwark lower and louder.
func _audio_heft() -> void:
	var ma := MechAudio.new()
	var mc := MechController.new()
	ma._body = mc
	mc.apply_chassis("strider")
	near(ma.heft_pitch(), 1.0, 1e-9, "Strider footfall pitch unchanged")
	near(ma.heft_db(), 0.0, 1e-9, "Strider footfall level unchanged")
	mc.apply_chassis("bulwark")
	check(ma.heft_pitch() < 0.9 and ma.heft_pitch() > 0.75, "Bulwark footfalls lower (x%.2f)" % ma.heft_pitch())
	check(ma.heft_db() > 0.5 and ma.heft_db() < 2.5, "Bulwark footfalls louder (+%.1f dB)" % ma.heft_db())
	ma.free()
	mc.free()


func _sight() -> void:
	var s := PlayerTarget.new()
	var offs := s.sight_offsets()
	check((offs[0] as Vector3).is_equal_approx(Vector3.UP * EnemyBase.LOS_HEAD_UP), "Strider head offset = EnemyBase.LOS_HEAD_UP")
	check((offs[1] as Vector3).is_equal_approx(-Vector3.UP * EnemyBase.LOS_LEGS_DOWN), "Strider legs offset = EnemyBase.LOS_LEGS_DOWN")
	s._setup_components({}, "bulwark")
	offs = s.sight_offsets()
	var centre: Vector3 = (s.hit_shapes[0] as Dictionary)["center"]
	for k in 2:
		var p: Vector3 = centre + (offs[k] as Vector3)
		var want := "head" if k == 0 else "leg_r"
		var inside := false
		for hs: Dictionary in s.hit_shapes:
			if str(hs["component"]) == want and p.distance_to(hs["center"] as Vector3) < float(hs["radius"]):
				inside = true
		check(inside, "Bulwark sight offset %d lands in its %s (%s)" % [k, want, str(p)])
	s.free()
