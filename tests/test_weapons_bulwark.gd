extends TestCase
## Bulwark weapons (MechCatalog "bulwark": side guns side_l / side_r with `yaw_in_max`, back saddles back_l / back_r): every
## item that fits each hardpoint works there exactly as on the Strider's. Headless, fixed step (DT), no wall clock, world
## geometry off (CombatWorld.use_physics false): shots meet hit spheres only. A Bulwark MechModel at mech scale 2 (as
## MechRig builds it) at the origin facing -Z, a WeaponRack driven through its methods, the shooter's own PlayerTarget
## registered (it must never be hit), TargetDummy posts (mass "static").
##  - slots / fire groups: one slot per hardpoint in chassis order (1 side_l, 2 side_r, 3 back_l, 4 back_r), number keys;
##  - hardpoint ranges: hardpoint_range mirrors yaw_in_max (+ yaw inward on the left gun, - on the right), the Strider's
##    hardpoints add no limit; the swivel on each side gun parks at its inward limit and holds OUT OF ARC past it, its
##    outward arc untouched;
##  - minimum convergence: an aim point on the centreline just beyond min_convergence_range is borne on; just inside it the
##    barrel parks at its inward limit and the shot leaves along the barrel (no bending), crossing the centreline at the
##    computed range;
##  - per item and hardpoint: it mounts, the barrel stays within aim_range, each record leaves from the turned barrel's
##    muzzle (rack.muzzle, WeaponPose.muzzle of the real HP_ node) along the barrel, and damage lands on a dummy at 30 and
##    80 m ahead (the flamer within its 45 m only; the mortar at 35 / 80 m: its 30 m minimum); the shooter's own target
##    is never hit; equipment: radiator cooling, ammo bin bonus, repair drone launch with its hardpoint;
##  - SHOT PATH vs own hull: from each side gun, for every weapon across its aim range (yaw every 10 deg and the ends,
##    five pitches) plus its spread cone's edge (and the swivel's two barrels), the first SEG m out of the muzzle meets no
##    triangle of the mech itself (hull, pods, pads, legs standing and in a walk, the other weapons, the pilot);
##  - the mortar launches from its tube mouth (WeaponPose.MUZZLE_TIPS), and the first MORTAR_T s of its arc, aimed every
##    way, clear the mech and the pilot's head (Bulwark and Strider);
##  - ammo / heat / cooldown: every weapon held for HOLD_T s on a Bulwark slot and on a Strider slot gives the same shot
##    count, ammo, heat and cooldown;
##  - two back items at once (mortar + mortar, mortar + repair drone): each fires / launches from its own saddle,
##    independently selectable; a destroyed weapon (its hardpoint component at 0) stops firing, the other keeps on;
##  - net: every chassis hardpoint id rides in NetMechCodec.COMPONENTS, every hardpoint that takes a pivoting weapon in
##    MOUNTS, and a Bulwark snapshot round-trips its back_l / back_r component HP within the packet budget;
##  - WeaponRegistry.playable_loadout swaps an unbuilt pick for the Bulwark slot's default; the weapon_range lab shows the
##    Bulwark (chassis option), moves the hardpoint to one that fits, fires its mortar from a back saddle.

const DT := 1.0 / 60.0
const SCALE := 2.0                 ## MechRig.mech_scale
const SHOOTER := "bulwark_t"
const SEG := 20.0                  ## m of shot path checked against the own mech
const MORTAR_T := 0.6              ## s of mortar arc checked against the own mech
const HOLD_T := 3.0                ## s the trigger is held for the ammo / heat / cooldown comparison
const SIDES := ["side_l", "side_r"]
const BACKS := ["back_l", "back_r"]

var world: CombatWorld
var model: MechModel
var mech: MechController
var rack: WeaponRack
var own: PlayerTarget
var dmg := {}                      ## target_id -> damage landed (hit_landed)
var own_hits := 0


func setup() -> void:
	timeout_sec = 600.0
	Combat.FIXED_ARC_ENABLED = false
	WeaponRegistry.set_disabled([])
	await _build("bulwark", {"side_l": "autocannon", "side_r": "laser", "back_l": "mortar", "back_r": "radiator"})
	_slots()
	_ranges()
	await _swivel_inward()
	await _convergence()
	await _items()
	await _shot_paths()
	await _mortar_launch()
	await _back_pair()
	await _destroyed()
	_teardown()
	await _same_as_strider()
	_net_codec()
	_playable()
	await _lab()
	Combat.FIXED_ARC_ENABLED = false
	finish()


# --- Fixture ---------------------------------------------------------------------------------------------------

func _build(chassis: String, loadout: Dictionary) -> void:
	_teardown()
	world = CombatWorld.new()
	world.use_physics = false
	world.mission_seed = 5
	add_child(world)
	world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		dmg[t.target_id] = float(dmg.get(t.target_id, 0.0)) + h.damage
		if t.target_id == SHOOTER:
			own_hits += 1)
	model = MechModel.new()
	model.scale = Vector3.ONE * SCALE
	add_child(model)
	model.configure("chicken", chassis, loadout)
	mech = MechController.new()          # not in the tree: heat changes only through the weapons
	rack = WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, SHOOTER, 1)
	own = PlayerTarget.new()
	add_child(own)
	own.bind(world, null, model, SHOOTER, 1)
	world.register(own)
	rack.slot_disabled = own.is_slot_destroyed
	await frames(2)


func _teardown() -> void:
	for n: Node in [rack, model, own, world]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	if mech != null and is_instance_valid(mech):
		mech.free()
	rack = null
	model = null
	own = null
	world = null
	mech = null
	dmg.clear()
	own_hits = 0


## A new loadout on the same model (the rack rebuilds on its next step; the own target re-binds its components).
func _load(loadout: Dictionary) -> void:
	model.configure("chicken", model.chassis_id, loadout)
	own.bind(world, null, model, SHOOTER, 1)
	rack.mech.heat = 0.0
	rack.mech.shutdown = false
	rack.rebuild()
	await frames(1)


func _step(n: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cb := func(rec: Dictionary) -> void: out.append(rec)
	world.fired.connect(cb)
	for i in n:
		rack.step(DT)
		world.advance(DT)
	world.fired.disconnect(cb)
	return out


func _hp(id: String) -> Node3D:
	return model.find_child("HP_" + id, true, false) as Node3D


func _slot_of(id: String) -> int:
	return rack.hardpoints.find(id) + 1


func _dummy(id: String, at: Vector3) -> TargetDummy:
	var d := TargetDummy.new()
	d.name = id
	d.target_id = id
	d.mass_class = "static"
	d.add_hit_sphere("body", Vector3(0, 1.9, 0), 3.0)   # a wide post: this checks that damage lands, not the spread
	add_child(d)
	d.global_position = at
	world.register(d)
	return d


func _drop(d: TargetDummy) -> void:
	world.unregister(d)
	d.queue_free()


# --- Slots and ranges --------------------------------------------------------------------------------------------

func _slots() -> void:
	eq(rack.hardpoints, ["side_l", "side_r", "back_l", "back_r"] as Array[String], "one slot per Bulwark hardpoint, chassis order")
	eq(rack.slot_count(), 4, "four slots")
	eq((rack.slots()[2] as Dictionary)["weapon"], "mortar", "slot 3 = back_l (the mortar)")
	check(bool((rack.slots()[3] as Dictionary)["equipment"]) and bool((rack.slots()[3] as Dictionary)["passive"]), "slot 4 = back_r (radiator, passive)")
	rack.press_slot(3, 10.0)
	check(not rack.enabled[2], "key 3 deselects the back_l mortar")
	rack.press_slot(3, 20.0)
	check(rack.enabled[2], "key 3 again selects it")
	rack.press_slot(1, 30.0)
	rack.press_slot(1, 30.1)
	check(rack.enabled[0] and not rack.enabled[1] and not rack.enabled[2], "double tap 1 solos the left side gun")
	check(rack.enabled[3], "a passive stays on")
	for i in 3:
		rack.set_enabled(i + 1, true)
	near(rack.cooling_bonus, float(MechCatalog.weapon("radiator")["cooling_bonus"]), 1e-6, "the radiator on back_r cools")


func _ranges() -> void:
	for hp: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		var id := str(hp["id"])
		var r := WeaponMount.hardpoint_range("bulwark", id)
		if hp.has("yaw_in_max"):
			var y := float(hp["yaw_in_max"])
			var side := WeaponMount.hardpoint_side("bulwark", id)
			eq(side, -1.0 if id.ends_with("_l") else 1.0, "%s: the side comes from the art's mount point" % id)
			if side < 0.0:
				check(r.y == y and is_inf(r.x), "%s: inward = + yaw, capped at %.0f (%s)" % [id, y, str(r)])
			else:
				check(r.x == -y and is_inf(r.y), "%s: inward = - yaw, capped at %.0f (%s)" % [id, y, str(r)])
		else:
			check(is_inf(r.x) and is_inf(r.y) and is_inf(r.z) and is_inf(r.w), "%s: no hardpoint limit (%s)" % [id, str(r)])
	for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
		var r := WeaponMount.hardpoint_range("strider", str(hp["id"]))
		check(is_inf(r.x) and is_inf(r.y) and is_inf(r.z) and is_inf(r.w), "strider %s: no hardpoint limit" % hp["id"])
	# The intersection with the weapon's own range.
	for id: String in SIDES:
		var m := WeaponMount.new()
		m.setup("swivel", id, SHOOTER, 1, MechCatalog.weapon("swivel"))
		m.set_hardpoint_range(WeaponMount.hardpoint_range("bulwark", id))
		var y_in := minf(float(SwivelBoom.limits(m.stats).x), float(_hpd("bulwark", id).get("yaw_in_max", INF)))
		near(m.inward_limit(WeaponMount.hardpoint_side("bulwark", id)), y_in, 1e-6, "%s swivel: inward limit %.0f" % [id, y_in])
		var a := WeaponMount.new()
		a.setup("autocannon", id, SHOOTER, 1, MechCatalog.weapon("autocannon"))
		a.set_hardpoint_range(WeaponMount.hardpoint_range("bulwark", id))
		var r4 := a.aim_range()
		var lim := Combat.pivot_limits(a.stats)
		near(a.inward_limit(WeaponMount.hardpoint_side("bulwark", id)), minf(lim.x, float(_hpd("bulwark", id).get("yaw_in_max", INF))), 1e-6,
			"%s autocannon: inward limit = min(pivot range, yaw_in_max)" % id)
		check(r4.z == lim.y and r4.w == lim.z, "%s autocannon: pitch range is the weapon's" % id)


static func _hpd(chassis: String, id: String) -> Dictionary:
	for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
		if str(hp["id"]) == id:
			return hp
	return {}


## The swivel on each side gun: aimed far inward it parks at its inward limit (mirrored) and holds; aimed far outward
## its full catalog arc applies.
func _swivel_inward() -> void:
	await _load({"side_l": "swivel", "side_r": "swivel"})
	var arc := float(SwivelBoom.limits(MechCatalog.weapon("swivel")).x)
	for id: String in SIDES:
		var side := WeaponMount.hardpoint_side("bulwark", id)
		var hp := _hp(id)
		var m: WeaponMount = rack.mounts[_slot_of(id) - 1]
		var y_in := minf(arc, float(_hpd("bulwark", id)["yaw_in_max"]))
		# Far inward: 20 m across the centreline, 2 m ahead.
		rack.aim_point = hp.global_position + Vector3(-side * 20.0, 0, -2.0)
		rack.set_trigger(true)
		var recs := _step(60)
		near(m.aim_yaw, -side * y_in, 1e-3, "%s swivel parks at its inward limit (%.1f)" % [id, m.aim_yaw])
		eq(m.hold_reason, Combat.OUT_OF_ARC, "%s swivel holds past its inward limit" % id)
		eq(recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id).size(), 0, "%s swivel fires nothing out of arc" % id)
		# Far outward (90 deg out, within its 120): it bears and fires.
		rack.aim_point = hp.global_position + Vector3(side * 30.0, 0, -0.5)
		recs = _step(60)
		check(absf(m.aim_yaw - side * 89.0) < 2.0, "%s swivel turns 90 deg outward (%.1f): the outward arc is the catalog's" % [id, m.aim_yaw])
		eq(m.hold_reason, "", "%s swivel bears outward" % id)
		check(recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id).size() > 0, "%s swivel fires outward" % id)
		rack.set_trigger(false)
		_step(5)


## Minimum convergence range of the side guns (autocannon: pivot range 30 deg; swivel: yaw_in_max).
func _convergence() -> void:
	for w: String in ["autocannon", "swivel"]:
		await _load({"side_l": w, "side_r": w})
		for id: String in SIDES:
			var side := WeaponMount.hardpoint_side("bulwark", id)
			var hp := _hp(id)
			var m: WeaponMount = rack.mounts[_slot_of(id) - 1]
			var lat := hp.global_position.x - model.global_position.x
			var y_in := m.inward_limit(side)
			var d := WeaponMount.min_convergence_range(lat, y_in)
			print("  %s %s: pivot %.2f m off the centreline, inward limit %.0f deg -> min convergence %.2f m ahead of the pivot (%.2f m ahead of the mech's origin)"
				% [id, w, absf(lat), y_in, d, d - hp.global_position.z])
			var expect: float = absf(lat) / tan(deg_to_rad(y_in))
			near(d, expect, 1e-4, "%s %s: min convergence = lateral / tan(inward limit)" % [id, w])
			# Just beyond: borne on.
			rack.aim_point = Vector3(model.global_position.x, hp.global_position.y, hp.global_position.z - d * 1.05)
			rack.set_trigger(false)
			_step(90)
			check(m.on_target(), "%s %s: an aim on the centreline at 1.05 x %.2f m is borne on (yaw %.1f)" % [id, w, d, m.aim_yaw])
			# Just inside: parked at the inward limit; the shot leaves along the barrel.
			rack.aim_point = Vector3(model.global_position.x, hp.global_position.y, hp.global_position.z - d * 0.9)
			_step(90)
			near(m.aim_yaw, -side * y_in, 1e-3, "%s %s: inside it the barrel parks at its inward limit" % [id, w])
			check(not m.on_target(), "%s %s: and is not on target" % [id, w])
			if w == "autocannon":         # pivoting weapons fire along the parked barrel (Combat.FIXED_ARC_ENABLED off)
				rack.set_trigger(true)
				var recs := _step(30).filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id)
				rack.set_trigger(false)
				if check(recs.size() > 0, "%s autocannon fires along its parked barrel" % id):
					var r: Dictionary = recs[0]
					var dir := (r["dir"] as Vector3)
					near(Combat.arc_angles(hp.global_basis, dir).x, -side * y_in, 1e-3, "%s: the shot leaves along the barrel, not bent to the aim" % id)
					# The barrel's line from the pivot crosses the centreline d m ahead of the pivot.
					var piv := hp.global_position
					var t := (model.global_position.x - piv.x) / dir.x
					near(-(dir * t).z, d, 0.02, "%s: its line crosses the centreline %.2f m ahead of the pivot" % [id, d])
			else:
				eq(m.hold_reason, Combat.OUT_OF_ARC, "%s swivel holds inside its convergence range" % id)
			_step(30)


# --- Every item on every hardpoint -----------------------------------------------------------------------------

func _items() -> void:
	for hpd: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		var id := str(hpd["id"])
		for w: String in MechCatalog.items_for(hpd):
			var lo := {id: w}
			await _load(lo)
			var i := _slot_of(id) - 1
			eq(rack.weapons[i], w, "%s/%s mounts" % [id, w])
			if MechCatalog.is_equipment(w):
				await _equipment(id, w)
				continue
			var m: WeaponMount = rack.mounts[i]
			if not check(m != null and m.built(), "%s/%s has a built mount" % [id, w]):
				continue
			check(_hp(id).get_node_or_null("Weapon_" + w) != null, "%s/%s: the weapon model is under HP_%s" % [id, w, id])
			var st := world.stats(w)
			var dists: Array = [35.0, 80.0] if str(st["kind"]) == "arc" else ([30.0] if float(st["range"]) < 80.0 else [30.0, 80.0])
			for dist: float in dists:
				await _fire_at(id, w, i, dist)


## Fire `w` on hardpoint `id` (slot index i) at a dummy `dist` m straight ahead of the hardpoint.
func _fire_at(id: String, w: String, i: int, dist: float) -> void:
	var hp := _hp(id)
	var m: WeaponMount = rack.mounts[i]
	var st := world.stats(w)
	var did := "d_%s_%s_%d" % [id, w, int(dist)]
	var d := _dummy(did, Vector3(hp.global_position.x, 0.0, hp.global_position.z - dist))
	rack.aim_point = d.global_position + Vector3(0, 1.9, 0)
	rack.mech.heat = 0.0
	rack.mech.shutdown = false
	m.cooldown = 0.0
	m.ammo = rack.ammo_max[i]
	dmg.erase(did)
	_step(30)                                  # settle the barrel on the aim
	rack.set_trigger(true)
	var hold := 1.4 if float(st.get("charge", 0.0)) > 0.0 or float(st.get("spin_up", 0.0)) > 0.0 else 0.4
	var recs := _step(int(hold / DT))
	rack.set_trigger(false)
	var speed := float(st.get("speed", 0.0))
	var flight := 6.0 if str(st["kind"]) in ["arc", "missile"] else (dist / speed + 0.8 if speed > 0.0 else 0.8)
	recs.append_array(_step(int(flight / DT)))
	recs = recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id)
	check(m.in_aim_range(Vector2(m.aim_yaw, m.aim_pitch)) or not m.pivoting(), "%s/%s: the barrel stays within its range" % [id, w])
	if check(recs.size() > 0, "%s/%s fires at %d m (%s)" % [id, w, int(dist), m.hold_reason]):
		var r: Dictionary = recs[0]
		eq(str(r["weapon"]), w, "  ... the record names the weapon")
		if m.pivoting() or m.behaviour.has_method("shape_record"):
			# Leaves from the turned barrel's muzzle (the HP_ node's real position) along the barrel.
			var bm := WeaponPose.muzzle(hp, m.aim_yaw, m.aim_pitch, float(st["muzzle"]))
			var off := (r["origin"] as Vector3).distance_to(bm)
			check(off < (0.2 if w == "swivel" else 0.05), "%s/%s: the shot leaves the turned muzzle (%.3f m off)" % [id, w, off])
			var bdir := Combat.arc_dir(hp.global_basis, Vector2(m.aim_yaw, m.aim_pitch))
			check(rad_to_deg((r["dir"] as Vector3).angle_to(bdir)) < 1.0, "%s/%s: along the barrel" % [id, w])
		else:   # the mortar: its tube mouth
			var tip := hp.global_transform * WeaponPose.rest_offset(w, float(st["muzzle"]))
			check((r["origin"] as Vector3).distance_to(tip) < 1e-3, "%s/mortar: the shell leaves the tube mouth" % id)
	check(float(dmg.get(did, 0.0)) > 0.0, "%s/%s: damage lands on the dummy at %d m (%.1f)" % [id, w, int(dist), float(dmg.get(did, 0.0))])
	eq(own_hits, 0, "%s/%s: the shooter's own mech is never hit" % [id, w])
	_drop(d)


func _equipment(id: String, w: String) -> void:
	var i := _slot_of(id) - 1
	var sl: Dictionary = rack.slots()[i]
	check(bool(sl["equipment"]), "%s/%s is an equipment slot" % [id, w])
	match w:
		"radiator":
			near(rack.cooling_bonus, float(MechCatalog.weapon(w)["cooling_bonus"]), 1e-6, "%s radiator adds its cooling" % id)
			rack.mech.heat = 50.0
			rack.set_trigger(true)
			_step(60)
			rack.set_trigger(false)
			check(rack.mech.heat < 50.0, "%s radiator sheds heat (%.1f)" % [id, rack.mech.heat])
		"ammo_bin":
			var other: String = BACKS[1] if id == BACKS[0] else BACKS[0]
			await _load({id: w, other: "mortar"})
			var j := _slot_of(other) - 1
			eq(rack.ammo_max[j], WeaponRack.bonus_ammo(int(MechCatalog.weapon("mortar")["ammo"]), 1, float(MechCatalog.weapon(w)["ammo_bonus"])),
				"%s ammo bin raises the %s mortar's ammo" % [id, other])
		"repair_drone":
			check(not rack.enabled[i], "%s repair drone starts deselected" % id)
			check(rack.activate(i + 1), "%s repair drone launches" % id)
			var dr := world.drone_of(SHOOTER)
			check(dr != null and str(dr.record.get("hardpoint", "")) == id, "%s: the drone's record names its saddle" % id)
			_step(10)
			if dr != null:
				world.remove_effect(dr)
			rack.drone = null


# --- Shot path vs the own mech ---------------------------------------------------------------------------------

## The mech's own triangles, per mesh part with its world AABB, without the subtree `skip` (the firing weapon).
func _parts(skip: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == skip:
			continue
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var xf := mi.global_transform
		var tris := PackedVector3Array()
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
				for k: int in idx as PackedInt32Array:
					tris.append(xf * v[k])
			else:
				for p in v:
					tris.append(xf * p)
		out.append({"name": str(mi.get_path()).get_file() if mi.name == "" else String(mi.name), "aabb": (xf * mi.mesh.get_aabb()).grow(0.01), "tris": tris})
	return out


## The first part segment a -> b meets, or "".
static func _seg_hits(parts: Array, a: Vector3, b: Vector3) -> String:
	for p: Dictionary in parts:
		if not (p["aabb"] as AABB).intersects_segment(a, b):
			continue
		var t: PackedVector3Array = p["tris"]
		for i in range(0, t.size() - 2, 3):
			if Geometry3D.segment_intersects_triangle(a, b, t[i], t[i + 1], t[i + 2]) != null:
				return str(p["name"])
	return ""


func _shot_paths() -> void:
	var worst := {}
	for pose: String in ["stand", "walk0", "walk1", "walk2", "walk3"]:
		for id: String in SIDES:
			var hpd := _hpd("bulwark", id)
			for w: String in MechCatalog.items_for(hpd):
				var other := "rockets" if w != "rockets" else "autocannon"
				var lo := {id: w, ("side_r" if id == "side_l" else "side_l"): other, "back_l": "mortar", "back_r": "repair_drone"}
				await _load(lo)
				_pose(pose)
				if w == "laser" and id == "side_l":
					print("  pose %s: foot_l at %s, knee_l at %s" % [pose, str((model.find_child("foot_l", true, false) as Node3D).global_position),
						str((model.find_child("knee_l", true, false) as Node3D).global_position)])
				var hp := _hp(id)
				var m: WeaponMount = rack.mounts[_slot_of(id) - 1]
				var st := m.stats
				var parts := _parts(hp.get_node_or_null("Weapon_" + w))
				# Control: a line from the muzzle back into the hull does meet the mech (the check can fail).
				var mz0 := WeaponPose.muzzle(hp, 0.0, 0.0, float(st["muzzle"]))
				check(_seg_hits(parts, mz0, model.global_position + Vector3(0, hp.global_position.y - 0.5, 0)) != "",
					"%s/%s (%s): control: a line from the muzzle into the hull meets it (%d parts)" % [id, w, pose, parts.size()])
				var r := m.aim_range()
				var yaws: Array = [r.x]
				var yy := ceilf(r.x / 10.0) * 10.0
				while yy < r.y:
					if yy > r.x:
						yaws.append(yy)
					yy += 10.0
				yaws.append(r.y)
				var cone := maxf(float(st.get("spread", 0.0)), float(st.get("spread_max", 0.0)))
				var hits := 0
				var first := ""
				for yaw: float in yaws:
					for pitch: float in [-r.z, -r.z * 0.5, 0.0, r.w * 0.5, r.w]:
						var dir := Combat.arc_dir(hp.global_basis, Vector2(yaw, pitch))
						var mz := WeaponPose.muzzle(hp, yaw, pitch, float(st["muzzle"]))
						var dirs: Array = [dir]
						if cone >= 1.0:
							var side := dir.cross(Vector3.UP).normalized()
							var up := side.cross(dir).normalized()
							for ax: Vector3 in [side, -side, up, -up]:
								dirs.append(dir.rotated(ax.cross(dir).normalized(), deg_to_rad(cone)))
						var origins: Array = [mz]
						if w == "swivel":
							var s := dir.cross(hp.global_basis.orthonormalized().y).normalized() * SwivelBoom.BARREL * hp.global_basis.x.length()
							origins = [mz + s, mz - s]
						for o: Vector3 in origins:
							for dd: Vector3 in dirs:
								var hit := _seg_hits(parts, o, o + dd * SEG)
								if hit != "":
									hits += 1
									if first == "":
										first = "yaw %+.0f pitch %+.0f -> %s" % [yaw, pitch, hit]
				check(hits == 0, "%s/%s (%s): the shot path clears the own mech across the aim range (%d hits; first %s)" % [id, w, pose, hits, first])
				worst["%s/%s" % [id, w]] = int(worst.get("%s/%s" % [id, w], 0)) + hits
	_pose("stand")
	print("  shot path self-hits per side gun item (all poses): ", worst)


## The model's leg pose: "stand" (the rest pose) or "walkN" (a lab walk cycle, a quarter cycle per N).
func _pose(p: String) -> void:
	if p == "stand":
		model.set_lab_param("gait", 0.0)
		model.time_scale = 0.0
		model.pose()
		return
	model.set_lab_param("gait", 1.0)
	model.time_scale = 1.0
	model._process(0.25 * float(p.trim_prefix("walk").to_int()) + 0.01)
	model.time_scale = 0.0


# --- Mortar launch -----------------------------------------------------------------------------------------------

func _mortar_launch() -> void:
	for chassis: String in ["bulwark", "strider"]:
		var lo := {"back_l": "mortar", "back_r": "mortar"} if chassis == "bulwark" else {"back": "mortar"}
		await _build(chassis, lo)
		var head := model.find_child("Head_chicken", true, false) as Node3D
		for id: String in (BACKS if chassis == "bulwark" else ["back"]):
			var hp := _hp(id)
			var i := _slot_of(id) - 1
			var parts := _parts(hp.get_node_or_null("Weapon_mortar"))
			var tip := rack.muzzle(i + 1)
			check(_seg_hits(parts, tip, head.global_position) != "", "%s %s: control: a line from the tube mouth to the head meets it" % [chassis, id])
			var bad := ""
			for bearing: float in [0.0, 30.0, -30.0, 90.0, -90.0, 180.0]:
				for dist: float in [32.0, 120.0, 245.0]:
					var aim := Vector3(sin(deg_to_rad(bearing)) * dist, 0.0, -cos(deg_to_rad(bearing)) * dist) + Vector3(tip.x, 0, tip.z)
					var rec := Combat.fire_record(SHOOTER, 1, id, "mortar", tip, aim, world.now, 999, 0.0)
					var sh := MortarShell.new()
					sh.start(world, rec, world.stats("mortar"))
					var prev := sh.flight_pos(0.0)
					var t := 0.02
					while t <= MORTAR_T + 1e-6:
						var p := sh.flight_pos(t)
						var h := _seg_hits(parts, prev, p)
						if h != "" and bad == "":
							bad = "bearing %+.0f %d m at %.2f s -> %s" % [bearing, int(dist), t, h]
						prev = p
						t += 0.02
					sh.free()
			check(bad == "", "%s %s: the mortar's arc clears the mech and the pilot for its first %.1f s (%s)" % [chassis, id, MORTAR_T, bad])
			var hd := tip.distance_to(head.global_position)
			check(tip.y > head.global_position.y + 0.5, "%s %s: the mortar leaves above the pilot's head (tip %.2f m up, head %.2f m)" % [chassis, id, tip.y, head.global_position.y])
			print("  %s %s mortar tube mouth %s, %.2f m from the pilot's head" % [chassis, id, str(tip), hd])
		_teardown()


# --- Two back items, destroyed weapons ---------------------------------------------------------------------------

func _back_pair() -> void:
	await _build("bulwark", {"side_l": "", "side_r": "", "back_l": "mortar", "back_r": "mortar"})
	var d := _dummy("d_back", Vector3(0, 0, -90))
	rack.aim_point = d.global_position + Vector3(0, 1.9, 0)
	var keys := {}
	for case: Array in [[true, false], [false, true], [true, true]]:
		rack.set_enabled(3, case[0])
		rack.set_enabled(4, case[1])
		for i in [2, 3]:
			(rack.mounts[i] as WeaponMount).cooldown = 0.0
		rack.set_trigger(true)
		var recs := _step(20)
		rack.set_trigger(false)
		var l := recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == "back_l").size()
		var r := recs.filter(func(r2: Dictionary) -> bool: return r2["hardpoint"] == "back_r").size()
		eq([l > 0, r > 0], case, "two mortars: back_l %s / back_r %s fire independently (%d / %d)" % [str(case[0]), str(case[1]), l, r])
		for rec: Dictionary in recs:
			keys[Combat.shot_key(rec)] = true
		_step(int(4.0 / DT))
	check(keys.size() >= 4, "each saddle's shells have their own shot keys (%d)" % keys.size())
	check(float(dmg.get("d_back", 0.0)) > 0.0, "the shells land")
	# Mortar + repair drone: one trigger pull fires the mortar and launches the selected drone.
	await _load({"side_l": "", "side_r": "", "back_l": "mortar", "back_r": "repair_drone"})
	rack.set_enabled(4, true)
	(rack.mounts[2] as WeaponMount).cooldown = 0.0
	rack.set_trigger(true)
	var recs2 := _step(5)
	rack.set_trigger(false)
	check(recs2.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == "back_l").size() > 0, "mortar + drone: the mortar fires")
	var dr := world.drone_of(SHOOTER)
	check(dr != null and str(dr.record.get("hardpoint", "")) == "back_r", "mortar + drone: the drone launches from back_r")
	if dr != null:
		world.remove_effect(dr)
	_drop(d)


func _destroyed() -> void:
	await _build("bulwark", {"side_l": "autocannon", "side_r": "autocannon", "back_l": "mortar", "back_r": "mortar"})
	var d := _dummy("d_destroy", Vector3(0, 0, -80))
	rack.aim_point = d.global_position + Vector3(0, 1.9, 0)
	for id: String in ["side_l", "back_l"]:
		check(own.hp.has(id), "%s is a damage component of the Bulwark" % id)
		own.apply_damage(PlayerTarget.WEAPON_HP + 1.0, id, "test")
		check(own.is_slot_destroyed(id), "%s destroyed" % id)
	rack.set_trigger(true)
	var recs := _step(30)
	rack.set_trigger(false)
	for id: String in ["side_l", "back_l"]:
		eq(recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id).size(), 0, "destroyed %s stops firing" % id)
		eq(str((rack.slots()[_slot_of(id) - 1] as Dictionary)["hold"]), "DESTROYED", "  ... and says so")
	for id: String in ["side_r", "back_r"]:
		check(recs.filter(func(r: Dictionary) -> bool: return r["hardpoint"] == id).size() > 0, "intact %s keeps firing" % id)
	_drop(d)


# --- Same numbers as on the Strider ------------------------------------------------------------------------------

func _same_as_strider() -> void:
	for w: String in MechCatalog.WEAPON_ORDER:
		var got := {}
		for chassis: String in ["bulwark", "strider"]:
			var hpid := ""
			for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
				if MechCatalog.fits(hp, w) and hpid == "":
					hpid = str(hp["id"])
			if not check(hpid != "", "%s fits a %s hardpoint" % [w, chassis]):
				continue
			await _build(chassis, {hpid: w})
			var i := _slot_of(hpid) - 1
			var hp := _hp(hpid)
			rack.aim_point = hp.global_position + Vector3(0, 0, -100.0)
			rack.set_trigger(true)
			var recs := _step(int(HOLD_T / DT))
			rack.set_trigger(false)
			var m: WeaponMount = rack.mounts[i]
			got[chassis] = [recs.size(), m.ammo, snappedf(rack.mech.heat, 1e-3), snappedf(m.cooldown, 1e-4), m.shot_index]
			_teardown()
		if got.size() == 2:
			eq(got["bulwark"], got["strider"], "%s: shots, ammo, heat, cooldown, shot index equal on both chassis" % w)


# --- Net --------------------------------------------------------------------------------------------------------

func _net_codec() -> void:
	for c: String in MechCatalog.CHASSIS:
		for hp: Dictionary in MechCatalog.chassis(c)["hardpoints"]:
			var id := str(hp["id"])
			check(id in NetMechCodec.COMPONENTS, "%s %s rides in NetMechCodec.COMPONENTS" % [c, id])
			var pivots := false
			for w: String in MechCatalog.items_for(hp):
				if not MechCatalog.is_equipment(w) and (Combat.pivots(w, MechCatalog.weapon(w)) or Combat.own_arc(w)):
					pivots = true
			check(not pivots or id in NetMechCodec.MOUNTS, "%s %s (takes a turning weapon) rides in NetMechCodec.MOUNTS" % [c, id])
	var s := NetMechState.new()
	s.peer = 1
	s.t = 1.0
	s.comp.resize(NetMechCodec.COMPONENTS.size())
	for i in s.comp.size():
		s.comp[i] = -1.0
	for id: String in ["torso", "head", "leg_l", "leg_r", "side_l", "side_r", "back_l", "back_r"]:
		s.comp[NetMechCodec.COMPONENTS.find(id)] = 1.0
	s.comp[NetMechCodec.COMPONENTS.find("back_l")] = 0.5
	s.comp[NetMechCodec.COMPONENTS.find("back_r")] = 0.0
	s.disable_cause = "back_r"
	s.mount_aim.resize(NetMechCodec.MOUNTS.size() * 2)
	var states: Array[NetMechState] = [s]
	var bytes := NetMechCodec.encode(states, {1: 1}, 1.0)
	eq(bytes.size(), NetMechCodec.COUNT_SIZE + NetMechCodec.ENTRY_SIZE, "one entry is ENTRY_SIZE bytes")
	check(NetWire.HEADER + NetMechCodec.COUNT_SIZE + 3 * NetMechCodec.ENTRY_SIZE <= NetMechCodec.MAX_PACKET,
		"three mechs fit the packet budget (%d <= %d)" % [NetWire.HEADER + NetMechCodec.COUNT_SIZE + 3 * NetMechCodec.ENTRY_SIZE, NetMechCodec.MAX_PACKET])
	var back := NetMechCodec.decode(bytes, {1: 1}, 1.0)
	if check(back.size() == 1, "the entry decodes"):
		var b: NetMechState = back[0]
		near(b.comp[NetMechCodec.COMPONENTS.find("back_l")], 0.5, 0.005, "back_l HP rides the snapshot")
		near(b.comp[NetMechCodec.COMPONENTS.find("back_r")], 0.0, 0.005, "back_r HP rides the snapshot")
		check(b.comp[NetMechCodec.COMPONENTS.find("shoulder_l")] < 0.0, "a Strider-only hardpoint is absent on a Bulwark")
		eq(b.disable_cause, "back_r", "a back saddle can be the disable cause")


func _playable() -> void:
	WeaponRegistry.set_disabled(["gatling"])
	var r := WeaponRegistry.playable_loadout("bulwark", {"side_l": "gatling", "side_r": "rockets", "back_l": "mortar", "back_r": "ammo_bin"})
	var lo: Dictionary = r["loadout"]
	var def: Dictionary = MechCatalog.chassis("bulwark")["default_loadout"]
	eq(str(lo["side_l"]), str(def["side_l"]), "an unbuilt pick on a Bulwark side gun becomes its default")
	eq(str(lo["side_r"]), "rockets", "a shoulder weapon on a Bulwark side gun is kept")
	eq(str(lo["back_r"]), "ammo_bin", "equipment on a back saddle is kept")
	WeaponRegistry.set_disabled([])


func _lab() -> void:
	var lab := LabRegistry.make("weapon_range") as WeaponRangeLab
	if not check(lab != null, "weapon_range is registered"):
		return
	add_child(lab)
	await frames(2)
	var ch: Array = []
	for o: Dictionary in lab.lab_options():
		if o["id"] == "chassis":
			ch = o["choices"]
	check("bulwark" in ch, "the lab offers the Bulwark (%s)" % str(ch))
	lab.set_lab_option("chassis", "bulwark")
	eq(lab.mech.chassis_id, "bulwark", "the lab mech is a Bulwark")
	check(lab.hardpoint in ["side_l", "side_r"], "the autocannon stays on a side gun (%s)" % lab.hardpoint)
	check(lab.mech.find_child("HP_" + lab.hardpoint + "/Weapon_autocannon", true, false) != null or
		(lab.mech.find_child("HP_" + lab.hardpoint, true, false) as Node).get_node_or_null("Weapon_autocannon") != null, "the autocannon is on the Bulwark's side gun")
	lab.set_lab_option("weapon", "mortar")
	check(lab.hardpoint in BACKS, "the mortar moves to a back saddle (%s)" % lab.hardpoint)
	lab.set_lab_option("aim", "dummy_100")
	lab.set_lab_option("fire", "hold")
	for i in int(1.0 / DT):
		lab.step(DT)
	check(lab.mount.shot_index >= 1, "the Bulwark's mortar fires in the lab (%d)" % lab.mount.shot_index)
	lab.set_lab_option("weapon", "radiator")
	eq(lab.equipped(), "radiator", "equipment works on a Bulwark back saddle in the lab")
	var hps: Array = []
	for o: Dictionary in lab.lab_options():
		if o["id"] == "hardpoint":
			hps = o["choices"]
	eq(hps, ["side_l", "side_r", "back_l", "back_r"], "the lab lists the Bulwark's hardpoints")
	lab.set_lab_option("chassis", "strider")
	lab.set_lab_option("weapon", "mortar")
	eq(lab.hardpoint, "back", "back on the Strider: the mortar on its back")
	lab.queue_free()
	await frames(1)
