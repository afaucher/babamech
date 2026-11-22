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
	m2.set_lab_option("art", "placeholder")
	await frames(1)
	check(m2.find_child("Chassis", true, false) == null and m2.find_child("Torso", true, false) != null, "the placeholder look still builds")
	check(m2.find_child("foot_l", true, false) != null and m2.find_child("Head_chicken", true, false) != null, "with its feet and head")
	m2.queue_free()
	finish()


func _faces(mesh: ArrayMesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		n += mesh.surface_get_array_len(s) / 3
	return n
