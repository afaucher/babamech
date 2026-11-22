extends TestCase
## The low-poly art parts: every part has its saved file, the file matches what the builders generate now (rerun
## tools\models\gen_mech_meshes.ps1 when this fails), pivots follow the conventions, and the assembled mech is built
## from them with every expected node, for all four heads and every weapon.


func setup() -> void:
	var parts := MechMeshes.all_parts()
	check(parts.size() >= 25, "the part list (%d)" % parts.size())
	for part: String in parts:
		if not check(ResourceLoader.exists(MechMeshes.path(part)), "%s has a saved file" % part):
			continue
		var saved := load(MechMeshes.path(part)) as ArrayMesh
		if not check(saved != null and saved.get_surface_count() > 0, "%s loads as a mesh" % part):
			continue
		var built := MechMeshes.build(part)
		eq(_faces(saved), _faces(built), "%s: the saved file matches the builder (faces)" % part)
		check(saved.get_aabb().is_equal_approx(built.get_aabb()), "%s: the saved file matches the builder (bounds)" % part)
		check(saved.surface_get_material(0) != null, "%s has its material" % part)
		check((saved.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) != 0, "%s carries a colour per face" % part)
	# Low poly: a head is about 150 faces.
	for h: String in MechMeshes.HEADS:
		var n := _faces(MechMeshes.mesh("head_" + h))
		check(n >= 100 and n <= 200, "head_%s is about 150 faces (%d)" % [h, n])
		var bb := MechMeshes.mesh("head_" + h).get_aabb()
		check(bb.position.y > -0.01 and bb.end.y > 1.0, "head_%s stands on its neck base" % h)
		check(MechCatalog.HEADS.has(h), "head %s is in the catalog" % h)
	# Pivots: a leg segment hangs from its proximal joint to its rest length; a weapon points forward from its mount.
	for seg: String in MechMeshes.REST_LENGTH:
		var bb := MechMeshes.mesh(seg).get_aabb()
		near(bb.position.y, -float(MechMeshes.REST_LENGTH[seg]), 0.12, "%s reaches its distal joint" % seg)
		check(bb.end.y < 0.3 and bb.end.y >= 0.0, "%s starts at its proximal joint" % seg)
	for w: String in MechMeshes.WEAPONS:
		var bb := MechMeshes.mesh("weapon_" + w).get_aabb()
		check(bb.grow(0.05).has_point(Vector3.ZERO), "weapon_%s sits on its mount point" % w)
		if w != "mortar":
			check(-bb.position.z > bb.end.z, "weapon_%s points forward" % w)
	for id: String in MechCatalog.WEAPON_ORDER:
		check(id in MechMeshes.WEAPONS, "catalog weapon %s has a mesh" % id)
	# The accent: the orange trim is its own surface (recoloured per mech); heads never take it.
	for part: String in ["torso", "back_plate", "shoulder_pod", "thigh"]:
		check(_accent_surface(MechMeshes.mesh(part)) >= 0, "%s has an accent surface" % part)
	for h: String in MechMeshes.HEADS:
		check(_accent_surface(MechMeshes.mesh("head_" + h)) < 0, "head_%s has no accent surface" % h)
	eq(MechMeshes.ACCENT_ORDER.size(), MechMeshes.ACCENTS.size(), "every accent id is in the order")
	check((MechMeshes.ACCENTS["orange"] as Color).is_equal_approx(MechMeshes.ORANGE), "the default accent is the orange")

	# The assembled mech, per head.
	for head: String in MechCatalog.HEAD_ORDER:
		var m := MechModel.new()
		m.configure(head, "strider", {})
		add_child(m)
		await frames(1)
		eq(m.art, "lowpoly", "the art meshes are the default look")
		for n: String in ["Torso", "Pelvis", "Nose", "Hatch", "BackPlate", "ShoulderPod_l", "ShoulderPod_r", "Cockpit", "Head_" + head,
				"thigh_l", "thigh_r", "shin_l", "shin_r", "tarsus_l", "tarsus_r", "hip_l", "knee_l", "ankle_l", "hip_r", "knee_r", "ankle_r",
				"foot_l", "foot_r", "HP_side_l", "HP_side_r", "HP_shoulder_l", "HP_shoulder_r", "HP_back"]:
			check(m.find_child(n, true, false) != null, "%s mech has %s" % [head, n])
		for side: String in ["l", "r"]:
			var foot := m.find_child("foot_" + side, true, false)
			var toes := 0
			for c in foot.get_children():
				if c.name.begins_with("toe"):
					toes += 1
			eq(toes, 3, "foot_%s has three toes" % side)
			check(foot.find_child("spur", true, false) != null, "foot_%s has its spur" % side)
		# Segments span their joints: each starts on its upper joint and its -Y end lands on the lower one.
		var pts := m.leg_points(1)
		var chain := [["thigh_r", "hip", "knee"], ["shin_r", "knee", "ankle"], ["tarsus_r", "ankle", "foot"]]
		for c: Array in chain:
			var seg := m.find_child(c[0], true, false) as Node3D
			var rest := float(MechMeshes.REST_LENGTH[str(c[0]).trim_suffix("_r")])
			check(seg.position.is_equal_approx(pts[c[1]]), "%s starts on the %s" % [c[0], c[1]])
			check((seg.transform * Vector3(0, -rest, 0)).distance_to(pts[c[2]]) < 0.001, "%s ends on the %s" % [c[0], c[2]])
		m.queue_free()
	# Every weapon mesh on a hardpoint that takes it, and the placeholder look still builds.
	var m2 := MechModel.new()
	add_child(m2)
	for id: String in MechCatalog.WEAPON_ORDER:
		var mount := str((MechCatalog.weapon(id)["mounts"] as Array)[0])
		var slot := "back" if mount == "back" else mount + "_r"
		m2.configure("chicken", "strider", {slot: id})
		var hp := m2.find_child("HP_" + slot, true, false)
		var gun := hp.find_child("Weapon_" + id, true, false) if hp != null else null
		check(gun != null and gun.get_child_count() == 1 and gun.get_child(0) is MeshInstance3D, "%s mounts its art mesh on %s" % [id, slot])
	# Back-mount equipment shows its mesh on the back hardpoint too, and the lab's Back option offers it.
	for id: String in MechCatalog.EQUIPMENT_ORDER:
		check(id in MechMeshes.EQUIPMENT, "catalog equipment %s has a mesh" % id)
		m2.configure("chicken", "strider", {"back": id})
		var hp := m2.find_child("HP_back", true, false)
		var eq_node := hp.find_child("Weapon_" + id, true, false) if hp != null else null
		check(eq_node != null and eq_node.get_child_count() == 1 and eq_node.get_child(0) is MeshInstance3D, "%s mounts its art mesh on back" % id)
	for o: Dictionary in m2.lab_options():
		if o["id"] == "hp:back":
			for id: String in MechCatalog.EQUIPMENT_ORDER:
				check(id in (o["choices"] as Array), "the lab's Back option lists %s" % id)
	# Accent: none by default, a tinted material after set_accent, kept through a rebuild, cleared by the orange.
	var blue := Color(0.16, 0.42, 0.85)
	m2.configure("chicken", "strider", {})
	var base: Material = MechMeshes.materials()[2]
	for n: String in ["Torso", "ShoulderPod_l"]:
		var o := _accent_override(m2, n)
		check(o == null or o == base, "default mech: no accent override on %s" % n)
	m2.set_accent(blue)
	for n: String in ["Torso", "ShoulderPod_l"]:
		var o := _accent_override(m2, n) as StandardMaterial3D
		check(o != null and o.albedo_color.is_equal_approx(blue), "set_accent tints %s's accent surface" % n)
	check((base as StandardMaterial3D).albedo_color.is_equal_approx(MechMeshes.ORANGE), "the shared accent material stays orange")
	m2.configure("pickle", "strider", {})
	var o2 := _accent_override(m2, "Torso") as StandardMaterial3D
	check(o2 != null and o2.albedo_color.is_equal_approx(blue), "the accent survives a rebuild")
	m2.set_lab_option("accent", "orange")
	var o3 := _accent_override(m2, "Torso")
	check(o3 == null or o3 == base, "set_accent(orange) restores the default")
	m2.set_accent(MechMeshes.ORANGE)
	check(_accent_override(m2, "ShoulderPod_l") == null, "the orange clears the override")
	m2.configure("chicken", "strider", {})
	m2.set_lab_option("art", "placeholder")
	await frames(1)
	check(m2.find_child("Chassis", true, false) == null and m2.find_child("Torso", true, false) != null, "the placeholder look still builds")
	check(m2.find_child("foot_l", true, false) != null and m2.find_child("Head_chicken", true, false) != null, "with its feet and head")
	m2.queue_free()
	_body_detail()
	_equipment()
	finish()


## The back-mount equipment meshes (docs/design/back-equipment.md): on the back mount like the mortar, inside an envelope
## that keeps them off the back plate (rear face at z -0.375), the shoulder weapons (inner faces at |x| 0.51) and no
## taller than the mortar; the docked drone is the cradle plus the flying drone at DRONE_DOCK, its skids on the pad; only
## the radiator has the "heat" surface (its fins).
func _equipment() -> void:
	var mortar := MechMeshes.mesh("weapon_mortar").get_aabb()
	for id: String in MechMeshes.EQUIPMENT:
		var m := MechMeshes.mesh("weapon_" + id)
		var n := _faces(m)
		check(n >= 250 and n <= 1100, "weapon_%s: low poly (%d faces)" % [id, n])
		for s in m.get_surface_count():
			check(m.surface_get_name(s) in MeshKit.SURFACES, "weapon_%s: surface %s is a known kind" % [id, m.surface_get_name(s)])
		check(_surface_names(m).has("accent"), "weapon_%s: it carries the player's accent" % id)
		eq(_surface_names(m).has("heat"), id == "radiator", "weapon_%s: only the radiator has a heat surface" % id)
		if id == "repair_drone_flying":
			continue
		var bb := m.get_aabb()
		check(bb.grow(0.05).has_point(Vector3.ZERO), "weapon_%s sits on the back mount point" % id)
		check(maxf(-bb.position.x, bb.end.x) <= 0.45, "weapon_%s: clear of the shoulder weapons (|x| %.2f <= 0.45)" % [id, maxf(-bb.position.x, bb.end.x)])
		check(bb.end.y <= mortar.end.y, "weapon_%s: no taller than the mortar (%.2f <= %.2f)" % [id, bb.end.y, mortar.end.y])
		check(bb.position.y >= -0.45 and bb.end.z <= 0.4, "weapon_%s: stays on the rear deck (y %.2f, z %.2f)" % [id, bb.position.y, bb.end.z])
		# Only the radiator's coolant pipes reach the back plate (into its rear face); nothing else comes near it.
		var front := -0.49 if id == "radiator" else -0.36
		check(bb.position.z >= front, "weapon_%s: clear of the back plate (front z %.2f >= %.2f)" % [id, bb.position.z, front])
	for p: String in MechMeshes.all_parts():
		if p != "weapon_radiator":
			check(not _surface_names(MechMeshes.mesh(p)).has("heat"), "%s has no heat surface" % p)
	# The docked drone = the empty cradle + the flying drone at DRONE_DOCK, resting its skids on the pad (top y 0.165).
	var docked := MechMeshes.mesh("weapon_repair_drone")
	var cradle := MechMeshes.mesh("weapon_repair_drone_cradle")
	var flying := MechMeshes.mesh("weapon_repair_drone_flying")
	eq(_faces(docked), _faces(cradle) + _faces(flying), "repair_drone: docked = cradle + flying drone (faces)")
	var fb := flying.get_aabb()
	var merged := cradle.get_aabb().merge(AABB(fb.position + MechMeshes.DRONE_DOCK, fb.size))
	check(docked.get_aabb().is_equal_approx(merged), "repair_drone: docked = cradle + flying drone at DRONE_DOCK (bounds)")
	near(MechMeshes.DRONE_DOCK.y + fb.position.y, 0.165, 0.01, "repair_drone: the skids rest on the pad")
	near(fb.get_center().x, 0.0, 0.01, "repair_drone_flying: centred across")
	near(fb.get_center().z, 0.0, 0.03, "repair_drone_flying: centred fore-aft")
	check(absf(fb.get_center().y) < 0.05, "repair_drone_flying: origin at its centre (%.3f)" % fb.get_center().y)
	# The radiator's fins: the heat surface lies inside the fin stack.
	var rad := MechMeshes.mesh("weapon_radiator")
	for s in rad.get_surface_count():
		if rad.surface_get_name(s) == "heat":
			var v: PackedVector3Array = rad.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			var hb := AABB(v[0], Vector3.ZERO)
			for p in v:
				hb = hb.expand(p)
			check(hb.position.y >= 0.2 and hb.end.y <= 0.9 and maxf(-hb.position.x, hb.end.x) <= 0.26,
				"radiator: the heat surface is the fin stack (%s)" % str(hb))


## The detailed chassis parts (docs/design/body-detail/, B adopted for every part): the weapons still sit where they
## should, the hatch rim keeps its strictly up-facing faces, and every surface is matte / glow / accent.
func _body_detail() -> void:
	eq(MechMeshes.PYLON_TOP, Vector3(0.1, 0.78, 0.0), "PYLON_TOP unchanged")
	eq(MechMeshes.SIDE_REACH, Vector3(0.32, 0.0, 0.0), "SIDE_REACH unchanged")
	eq(MechMeshes.BODY_SCALE, 1.2, "BODY_SCALE unchanged")
	for id: String in MechMeshes.BODY_PARTS:
		var m := MechMeshes.mesh(id)
		for s in m.get_surface_count():
			check(m.surface_get_name(s) in MeshKit.SURFACES, "%s: surface %s is named matte / glow / accent" % [id, m.surface_get_name(s)])
	for id: String in ["torso", "hatch", "back_plate", "pelvis", "shoulder_pylon", "shoulder_pod", "side_mount"]:
		check(_surface_names(MechMeshes.mesh(id)).has("accent"), "%s: its orange trim is on the accent surface" % id)
	# The pylon's top plate is the mount face: its top sits at PYLON_TOP and nothing pokes more than 2 cm above it.
	var top := MechMeshes.PYLON_TOP
	var pt := _top_near(MechMeshes.mesh("shoulder_pylon"), top, 0.25)
	near(pt, top.y, 0.03, "shoulder_pylon: the top of the mount is at PYLON_TOP (%.3f)" % pt)
	check(pt <= top.y + 0.02, "shoulder_pylon: nothing pokes more than 2 cm above the mount point (%.3f)" % pt)
	# The side mount's block ends at SIDE_REACH (its outer face, half the block's 0.1 width past it).
	near(MechMeshes.mesh("side_mount").get_aabb().end.x, MechMeshes.SIDE_REACH.x + 0.05, 0.02, "side_mount: the block's outer face at SIDE_REACH")
	# The back-mount saddle sits 2-9 cm proud of the torso skin under MOUNTS["back"].
	var back: Vector3 = MechMeshes.MOUNTS["back"]
	var skin: float = (MechMeshes._torso_at(back.z, 0.0)[0] as Vector3).y
	var deck := _top_at(MechMeshes.mesh("torso"), back.x, back.z)
	check(deck - skin > 0.02 and deck - skin < 0.09,
		"torso: the back-mount saddle sits 2-9 cm proud of the deck under the back mount (skin %.3f, saddle %.3f)" % [skin, deck])
	# The hatch rim (y = 0.1) has only its own up-facing faces there (tests/test_geometry_audit.gd's check).
	var up := 0
	var down := 0
	for t: Array in _tris(MechMeshes.mesh("hatch")):
		var c: Vector3 = (t[0] + t[1] + t[2]) / 3.0
		var n: Vector3 = t[3]
		var r := Vector2(c.x, c.z).length()
		if absf(c.y - 0.1) < 0.01 and r > 0.38 and r < 0.48:
			if n.y > 0.9:
				up += 1
			elif n.y < -0.9:
				down += 1
	check(up == 20 and down == 0, "hatch: rim faces strictly +Y (up=%d, down=%d)" % [up, down])


static func _surface_names(m: ArrayMesh) -> Array:
	var out: Array = []
	for s in m.get_surface_count():
		out.append(m.surface_get_name(s))
	return out


static func _tris(m: ArrayMesh) -> Array:
	var out: Array = []
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in v.size() / 3:
			out.append([v[i * 3], v[i * 3 + 1], v[i * 3 + 2], nn[i * 3]])
	return out


## The highest vertex within `r` (horizontally) of `p`.
static func _top_near(m: ArrayMesh, p: Vector3, r: float) -> float:
	var best := -INF
	for t: Array in _tris(m):
		for i in 3:
			var v: Vector3 = t[i]
			if Vector2(v.x - p.x, v.z - p.z).length() <= r:
				best = maxf(best, v.y)
	return best


## The highest surface point straight above / below (x, z).
static func _top_at(m: ArrayMesh, x: float, z: float) -> float:
	var best := -INF
	var p := Vector2(x, z)
	for t: Array in _tris(m):
		var a := Vector2(t[0].x, t[0].z)
		var b := Vector2(t[1].x, t[1].z)
		var c := Vector2(t[2].x, t[2].z)
		var den := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
		if absf(den) < 1e-9:
			continue
		var w0 := ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / den
		var w1 := ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / den
		var w2 := 1.0 - w0 - w1
		if w0 >= 0.0 and w1 >= 0.0 and w2 >= 0.0:
			best = maxf(best, w0 * t[0].y + w1 * t[1].y + w2 * t[2].y)
	return best


func _accent_surface(mesh: ArrayMesh) -> int:
	for s in mesh.get_surface_count():
		if mesh.surface_get_name(s) == "accent":
			return s
	return -1


func _accent_override(m: Node, node_name: String) -> Material:
	var mi := m.find_child(node_name, true, false) as MeshInstance3D
	if mi == null:
		return null
	var s := _accent_surface(mi.mesh as ArrayMesh)
	return mi.get_surface_override_material(s) if s >= 0 else null


func _faces(mesh: ArrayMesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		n += mesh.surface_get_array_len(s) / 3
	return n
