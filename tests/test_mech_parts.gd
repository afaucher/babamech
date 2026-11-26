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
	await _bulwark()
	await _wasp()
	finish()


## The Bulwark's parts (BulwarkMeshes; docs/design/chassis-rules.md 6.6, 6.7, 3.3, 3.6, 9.1): saved files match the
## builders, face budgets, pivots, nothing thinner than 0.02, joints sized to the segments' necks, the assembled mech
## (every node, two toes and a spur per boot, segments spanning their joints, the knee pads on the accent surface, every
## allowed item on every hardpoint), and the whole chassis with a full loadout within 1.25x the Strider's faces.
func _bulwark() -> void:
	const BUDGET := {"bulwark_torso": 1600, "bulwark_thigh": 300, "bulwark_shin": 300, "bulwark_ankle": 300}
	for part: String in BulwarkMeshes.all_parts():
		check(part.begins_with(BulwarkMeshes.PREFIX), "%s is a bulwark_ part" % part)
		check(not MechMeshes.has_part(part), "%s is not also a MechMeshes part" % part)
		if not check(ResourceLoader.exists(BulwarkMeshes.path(part)), "%s has a saved file" % part):
			continue
		var saved := load(BulwarkMeshes.path(part)) as ArrayMesh
		var built := BulwarkMeshes.build(part)
		eq(_faces(saved), _faces(built), "%s: the saved file matches the builder (faces)" % part)
		check(saved.get_aabb().is_equal_approx(built.get_aabb()), "%s: the saved file matches the builder (bounds)" % part)
		check(saved.surface_get_material(0) != null, "%s has its material" % part)
		for s in saved.get_surface_count():
			check(saved.surface_get_name(s) in ["matte", "glow", "accent"], "%s: surface %s is matte / glow / accent" % [part, saved.surface_get_name(s)])
		var n := _faces(built)
		var cap := int(BUDGET.get(part, 400))
		check(n <= cap, "%s: within its face budget (%d <= %d)" % [part, n, cap])
		var thin := _thinnest(built)
		check(thin >= 0.0195, "%s: nothing thinner than 0.02 (thinnest shell %.4f; 0.0005 vertex quantisation allowed)" % [part, thin])
	for part: String in ["bulwark_torso", "bulwark_pod", "bulwark_knee_cap", "bulwark_side_mount"]:
		check(_accent_surface(BulwarkMeshes.mesh(part)) >= 0, "%s has an accent surface (the pod's cap, the knee pads on the knee cap)" % part)
	# Pivots: segments hang from the proximal joint to their rest length.
	for seg: String in BulwarkMeshes.REST_LENGTH:
		var part: String = {"thigh": "bulwark_thigh", "shin": "bulwark_shin", "tarsus": "bulwark_ankle"}[seg]
		var bb := BulwarkMeshes.mesh(part).get_aabb()
		near(bb.position.y, -float(BulwarkMeshes.REST_LENGTH[seg]), 0.06, "%s reaches its distal joint" % part)
		check(bb.end.y < 0.3 and bb.end.y >= 0.0, "%s starts at its proximal joint" % part)
	near(BulwarkMeshes.mesh("bulwark_side_mount").get_aabb().position.z, BulwarkMeshes.SIDE_REACH.z - 0.14, 0.02,
		"bulwark_side_mount: the pivot block's front face just ahead of SIDE_REACH")
	# Joints sized to the load (rule 3.3, read at the necks: the end section each segment enters its joint with), and the
	# two drums / the ball and drum on one segment never meeting (radii sum under the segment's length).
	var rest: Dictionary = BulwarkMeshes.REST_LENGTH
	var thigh_neck := 2.0 * maxf(_neck(BulwarkMeshes.THIGH, 0), _neck(BulwarkMeshes.THIGH, -1))
	var shin_top := 2.0 * _neck(BulwarkMeshes.SHIN, 0)
	var shin_bot := 2.0 * _neck(BulwarkMeshes.SHIN, -1)
	check(BulwarkMeshes.HIP_BALL >= 0.55 * thigh_neck, "hip ball %.2f >= 0.55 x the thigh's neck %.2f" % [BulwarkMeshes.HIP_BALL, thigh_neck])
	check(BulwarkMeshes.KNEE_DRUM.x >= 0.55 * maxf(thigh_neck, shin_top), "knee drum %.2f >= 0.55 x the thicker neck %.2f" % [BulwarkMeshes.KNEE_DRUM.x, maxf(thigh_neck, shin_top)])
	check(BulwarkMeshes.ANKLE_DRUM.x >= 0.55 * maxf(shin_bot, 0.4), "ankle drum %.2f >= 0.55 x the thicker neck %.2f" % [BulwarkMeshes.ANKLE_DRUM.x, maxf(shin_bot, 0.4)])
	check(BulwarkMeshes.HIP_BALL + BulwarkMeshes.KNEE_DRUM.x < float(rest["thigh"]), "hip ball and knee drum stay apart on the thigh")
	check(BulwarkMeshes.KNEE_DRUM.x + BulwarkMeshes.ANKLE_DRUM.x < float(rest["shin"]), "knee and ankle drums stay apart on the shin")
	# Rule 3.3 read at the segments' biggest sections too (the thigh block's full thickness): ball and knee drum >= 0.55x.
	var thigh_big := 0.0
	for s: Array in BulwarkMeshes.THIGH:
		thigh_big = maxf(thigh_big, 2.0 * maxf(absf(float(s[1])) + float(s[3]), absf(float(s[2])) + float(s[4])))
	var shin_big := 0.0
	for s: Array in BulwarkMeshes.SHIN:
		shin_big = maxf(shin_big, 2.0 * maxf(absf(float(s[1])) + float(s[3]), float(s[4])))
	check(BulwarkMeshes.HIP_BALL >= 0.55 * thigh_big, "hip ball %.2f >= 0.55 x the thigh's thickness %.2f" % [BulwarkMeshes.HIP_BALL, thigh_big])
	check(BulwarkMeshes.KNEE_DRUM.x >= 0.55 * maxf(thigh_big, shin_big), "knee drum %.2f >= 0.55 x the thicker segment %.2f" % [
		BulwarkMeshes.KNEE_DRUM.x, maxf(thigh_big, shin_big)])
	print("  bulwark joints vs the segments' biggest sections: hip %.2f, knee %.2f (rule 3.3: >= 0.55)" % [
		BulwarkMeshes.HIP_BALL / thigh_big, BulwarkMeshes.KNEE_DRUM.x / maxf(thigh_big, shin_big)])

	# The assembled Bulwark.
	var m := MechModel.new()
	m.configure("chicken", "bulwark", {})
	add_child(m)
	await frames(1)
	eq(m.leg_bend, 1.0, "the Bulwark's knees bend forward")
	# Size at game scale (MechRig's mech_scale 2): overall height (the pilot's comb), the body (torso, pelvis and any body
	# pods: the Bulwark's hip pods are its hull's flanks) and overall width, against the Strider (printed).
	var sizes := {}
	for chassis: String in ["bulwark", "strider"]:
		m.configure("chicken", chassis, {})
		await frames(1)
		var all := AABB()
		var body := AABB()
		var comb := 0.0
		var head := AABB()
		for c in m.find_children("*", "MeshInstance3D", true, false):
			var mi := c as MeshInstance3D
			if mi.mesh == null or not mi.is_visible_in_tree():
				continue
			var b := mi.global_transform * mi.mesh.get_aabb()
			all = b if all.size == Vector3.ZERO else all.merge(b)
			if str(mi.name) in ["Torso", "Pelvis"] or str(mi.name).begins_with("Pod_"):
				body = b if body.size == Vector3.ZERO else body.merge(b)
			if m.find_child("Head_chicken", true, false).is_ancestor_of(mi):
				comb = maxf(comb, b.end.y)
				head = b if head.size == Vector3.ZERO else head.merge(b)
		var eye := 0.0   # the pilot's eye line (the pupils' height): the head's centre for the height target
		for pn in m.find_child("Head_chicken", true, false).find_children("Pupil*", "MeshInstance3D", true, false):
			var pm := pn as MeshInstance3D
			eye = (pm.global_transform * pm.mesh.get_aabb().get_center()).y
		var torso_box := AABB()
		var tn := m.find_child("Torso", true, false) as MeshInstance3D
		torso_box = tn.global_transform * tn.mesh.get_aabb()
		sizes[chassis] = [all, body, head]
		sizes[chassis + "_comb"] = comb
		sizes[chassis + "_eye"] = eye
		sizes[chassis + "_torso"] = torso_box
		print("  %s at scale 2: comb %.2f m, overall height %.2f m, width %.2f m (body %.2f m wide, %.2f m deep, %.2f m tall), hip %.2f m, max step %.2f m" % [
			chassis, comb * 2.0, all.end.y * 2.0, all.size.x * 2.0, body.size.x * 2.0, body.size.z * 2.0, body.size.y * 2.0, m.hip_height() * 2.0,
			m.max_foot_lift() * 0.9 * 2.0])
	# The height (user, 2026-11-24: "the head should be about at the chest of the other mech"): the pilot's eye line within
	# 0.25 model units (0.5 m) of the Strider's chest, two thirds up its torso (the egg hull); shorter than the Strider.
	# Rule 2.4 and the slung hull (layout B1): still wider than tall to the pilot's comb with the long legs (the stance
	# widened with them; the back boxes stand above the hull line, so not to the mortar's muzzle), and much wider than the
	# Strider. The body at least 1.3x the Strider's width, wider and deeper than it is tall, and wider than its deck is high.
	var bw: Array = sizes["bulwark"]
	var sw: Array = sizes["strider"]
	var bb: AABB = bw[1]
	var st: AABB = sizes["strider_torso"]
	var chest := st.position.y + st.size.y * 2.0 / 3.0
	var eye_b := float(sizes["bulwark_eye"])
	print("  bulwark pilot's eye line %.2f m, Strider chest (2/3 up its torso %.2f..%.2f m) %.2f m; comb %.2f m = %.0f%% of the Strider's" % [
		eye_b * 2.0, st.position.y * 2.0, st.end.y * 2.0, chest * 2.0, float(sizes["bulwark_comb"]) * 2.0,
		100.0 * float(sizes["bulwark_comb"]) / float(sizes["strider_comb"])])
	check(absf(eye_b - chest) <= 0.25, "the Bulwark pilot's eyes (%.2f m) are at the Strider's chest (%.2f m, within 0.5 m)" % [eye_b * 2.0, chest * 2.0])
	check((bw[0] as AABB).size.x > float(sizes["bulwark_comb"]), "the Bulwark is wider (%.2f m) than it is tall to the pilot's comb (%.2f m)" % [
		(bw[0] as AABB).size.x * 2.0, float(sizes["bulwark_comb"]) * 2.0])
	check((bw[0] as AABB).size.x >= 1.25 * (sw[0] as AABB).size.x, "the Bulwark is at least 1.25x the Strider's overall width (%.2f vs %.2f m)" % [
		(bw[0] as AABB).size.x * 2.0, (sw[0] as AABB).size.x * 2.0])
	check((bw[0] as AABB).end.y < (sw[0] as AABB).end.y, "the Bulwark is shorter than the Strider")
	check(float(sizes["bulwark_comb"]) <= 0.85 * float(sizes["strider_comb"]), "the Bulwark's comb is at most 0.85x the Strider's")
	check(bb.size.x >= 1.3 * (sw[1] as AABB).size.x, "the Bulwark's body is at least 1.3x the Strider's width (%.2f vs %.2f m)" % [
		bb.size.x * 2.0, (sw[1] as AABB).size.x * 2.0])
	check(bb.size.x > 2.0 * bb.size.y and bb.size.z > 2.0 * bb.size.y, "the hull is over twice as wide and as deep as it is tall (%.2f x %.2f x %.2f m)" % [
		bb.size.x * 2.0, bb.size.z * 2.0, bb.size.y * 2.0])
	m.configure("chicken", "bulwark", {})
	await frames(1)
	var torso_n := m.find_child("Torso", true, false) as MeshInstance3D
	var deck_h := (torso_n.global_transform * Vector3(0, BulwarkMeshes.DECK, 0)).y
	print("  bulwark deck %.2f m off the ground at scale 2" % (deck_h * 2.0))
	check(bb.size.x > deck_h, "the body is wider (%.2f m) than its deck is high (%.2f m)" % [bb.size.x * 2.0, deck_h * 2.0])
	# The deck: the flat top faces at DECK (the pilot's well and the pods cut into it), against the chicken head's footprint
	# (both in body space).
	var deck_area := 0.0
	var tm := BulwarkMeshes.build("bulwark_torso")
	for s in tm.get_surface_count():
		var v: PackedVector3Array = tm.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			var cr := (v[i + 1] - v[i]).cross(v[i + 2] - v[i])
			if absf(cr.normalized().y) > 0.99 and absf(v[i].y - BulwarkMeshes.DECK) < 0.002 and absf(v[i + 1].y - BulwarkMeshes.DECK) < 0.002:
				deck_area += cr.length() * 0.5
	var hb: AABB = bw[2]
	var cs := torso_n.global_transform.basis.get_scale().x
	var head_area := (hb.size.x / cs) * (hb.size.z / cs)
	print("  bulwark deck area %.2f vs the chicken head's footprint %.2f (body units): %.1fx" % [deck_area, head_area, deck_area / head_area])
	check(deck_area >= 2.0 * head_area, "the deck is at least 2x the pilot head's footprint (%.1fx)" % (deck_area / head_area))
	# The legs hang from the flanks: the hip outside the hull's width between the pods, each thigh (half width 0.31, its
	# plates to 0.375) clear outside the keel, the hip pod standing out of the hull's flank over the hip and wider than the
	# thigh and its plates either side.
	var hip_x := m.hip_local(1.0).x / cs
	check(hip_x > BulwarkMeshes.HULL_HW, "the hips are outboard of the hull (hip %.3f, hull %.3f)" % [hip_x, BulwarkMeshes.HULL_HW])
	check(hip_x - BulwarkMeshes.THIGH_HW / cs > BulwarkMeshes.KEEL_HW, "the thighs hang outside the keel (hip %.3f, keel %.3f)" % [hip_x, BulwarkMeshes.KEEL_HW])
	check(BulwarkMeshes.POD_OUT > BulwarkMeshes.HULL_HW and BulwarkMeshes.POD_IN < BulwarkMeshes.HULL_HW, "the hip pods stand out of the hull's flanks")
	check(BulwarkMeshes.POD_IN < hip_x - BulwarkMeshes.THIGH_PLATES_HW / cs and BulwarkMeshes.POD_OUT > hip_x + BulwarkMeshes.THIGH_PLATES_HW / cs,
		"the pod covers the thigh's width over the hip")
	near(hip_x, BulwarkMeshes.HIP_X, 1e-4, "the default stance puts the hips at BulwarkMeshes.HIP_X")
	# The long legs (user, 2026-11-24): hip about 4.8 m, step-up at least 1.2 m (the Strider's is 1.25 m).
	check(m.hip_height() * 2.0 >= 4.5, "hip height %.2f m >= 4.5 m" % (m.hip_height() * 2.0))
	check(m.max_foot_lift() * 0.9 * 2.0 >= 1.2, "max step-up %.2f m >= 1.2 m" % (m.max_foot_lift() * 0.9 * 2.0))
	m.configure("chicken", "bulwark", {})
	await frames(1)
	near(float(m.params["thigh"]), float(rest["thigh"]), 1e-6, "the Bulwark's default thigh is its rest length")
	for n: String in ["Torso", "Pelvis", "Nose", "Hatch", "Cockpit", "Head_chicken", "thigh_l", "thigh_r", "shin_l", "shin_r", "tarsus_l",
			"tarsus_r", "socket_l", "socket_r", "hip_l", "knee_l", "ankle_l", "hip_r", "knee_r", "ankle_r", "foot_l", "foot_r",
			"HP_side_l", "HP_side_r", "HP_back_l", "HP_back_r", "Pod_l", "Pod_r"]:
		check(m.find_child(n, true, false) != null, "bulwark mech has %s" % n)
	check(m.find_child("BackPlate", true, false) == null and m.find_child("ShoulderPod_l", true, false) == null, "no Strider back plate or pods")
	for hp: String in ["HP_side_l", "HP_side_r"]:
		check(m.find_child(hp, true, false).find_child("Mount", false, false) != null, "%s has its side mount" % hp)
	for side: String in ["l", "r"]:
		var foot := m.find_child("foot_" + side, true, false)
		var toes := 0
		for c in foot.get_children():
			if c.name.begins_with("toe"):
				toes += 1
		eq(toes, 2, "foot_%s has the two toes of its clamp" % side)
		check(foot.find_child("spur", true, false) != null, "foot_%s has its heel spur" % side)
	var pts := m.leg_points(1)
	for c: Array in [["thigh_r", "hip", "knee", "thigh"], ["shin_r", "knee", "ankle", "shin"], ["tarsus_r", "ankle", "foot", "tarsus"]]:
		var seg := m.find_child(c[0], true, false) as Node3D
		var r := float(rest[c[3]])
		check(seg.position.is_equal_approx(pts[c[1]]), "bulwark %s starts on the %s" % [c[0], c[1]])
		check((seg.transform * Vector3(0, -r, 0)).distance_to(pts[c[2]]) < 0.001, "bulwark %s ends on the %s" % [c[0], c[2]])
	# The knee forward of the hip and the ankle, the foot long enough for the knee (rule 3.6).
	check(pts["knee"].z < pts["hip"].z - 0.2 and pts["knee"].z < pts["ankle"].z - 0.2, "the knee bends forward (%s)" % str(pts))
	var fb := AABB()
	for c in m.find_child("foot_r", true, false).get_children():
		var mi := c as MeshInstance3D
		var b := mi.transform * mi.mesh.get_aabb()
		fb = b if fb.size == Vector3.ZERO else fb.merge(b)
	check(fb.size.z >= 0.8 * float(rest["shin"]), "the foot is at least 0.8 x the shin long (%.2f)" % fb.size.z)
	# Every allowed item on every hardpoint shows its mesh.
	for hp: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		for w: String in MechCatalog.items_for(hp):
			m.configure("chicken", "bulwark", {hp["id"]: w})
			var node := m.find_child("HP_" + str(hp["id"]), true, false)
			var gun := node.find_child("Weapon_" + w, true, false) if node != null else null
			check(gun != null and gun.get_child_count() == 1, "bulwark %s mounts %s" % [hp["id"], w])
	# Whole chassis, heaviest loadout, against the Strider's (rule 6.6).
	var heavy := {}
	for chassis: String in ["strider", "bulwark"]:
		var lo := {}
		for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
			var best := ""
			for w: String in MechCatalog.items_for(hp):
				if w == "railgun" and lo.values().has("railgun"):
					continue
				if best == "" or _faces(MechMeshes.mesh("weapon_" + w)) > _faces(MechMeshes.mesh("weapon_" + best)):
					best = w
			lo[hp["id"]] = best
		m.configure("chicken", chassis, lo)
		await frames(1)
		heavy[chassis] = _tree_faces(m)
		print("  %s, heaviest loadout %s: %d faces" % [chassis, str(lo), heavy[chassis]])
	check(float(heavy["bulwark"]) <= 1.25 * float(heavy["strider"]), "the Bulwark's full loadout is within 1.25x the Strider's faces (%d vs %d)" % [heavy["bulwark"], heavy["strider"]])
	m.configure("chicken", "strider", {})
	eq(m.leg_bend, -1.0, "back to the Strider: its chicken legs again")
	near(float(m.params["thigh"]), 1.1, 1e-6, "back to the Strider: its thigh again")
	m.queue_free()


## Half the larger extent of a segment's end ring (0 = proximal, -1 = distal) from its axis, its offset included.
static func _neck(spec: Array, i: int) -> float:
	var s: Array = spec[i if i >= 0 else spec.size() + i]
	return maxf(absf(float(s[1])) + float(s[3]), absf(float(s[2])) + float(s[4]))


## Faces of every mesh under a node (the pilot head included).
func _tree_faces(root: Node) -> int:
	var n := 0
	for c in root.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh != null and mi.is_visible_in_tree():
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				n += ((idx as PackedInt32Array).size() if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n


## The thinnest closed shell in a mesh: its triangles grouped by shared vertex positions, each group's smallest bounding
## box extent (a proxy for its thickness: a 0.012 strip shows 0.012; curved shells only read thicker).
static func _thinnest(mesh: ArrayMesh) -> float:
	var parent := {}
	var tris: Array = []
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			var keys: Array = []
			for j in 3:
				var q := Vector3i((v[i + j] * 2000.0).round())
				keys.append(q)
				if not parent.has(q):
					parent[q] = q
			tris.append([keys, v[i], v[i + 1], v[i + 2]])
			var r0: Vector3i = _find(parent, keys[0])
			for j in [1, 2]:
				var rj: Vector3i = _find(parent, keys[j])
				if rj != r0:
					parent[rj] = r0
	var boxes := {}
	for t: Array in tris:
		var root: Vector3i = _find(parent, (t[0] as Array)[0])
		var b: AABB = boxes.get(root, AABB(t[1], Vector3.ZERO))
		boxes[root] = b.expand(t[1]).expand(t[2]).expand(t[3])
	var thin := INF
	for b: AABB in boxes.values():
		thin = minf(thin, minf(b.size.x, minf(b.size.y, b.size.z)))
	return thin


static func _find(parent: Dictionary, q: Vector3i) -> Vector3i:
	while parent[q] != q:
		parent[q] = parent[parent[q]]
		q = parent[q]
	return q


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



## The Wasp's parts (WaspMeshes; a draft chassis: art phase 1, docs/design/chassis-rules.md 6.6, 6.7, 3.3, 9.1): saved
## files match the builders, face budgets, nothing thinner than 0.02, joints sized to the segments, the team colour on the
## fan rings, the legs in the Strider's leg colours, the assembled model (every named node the future hover controller
## will drive, no pusher fans), its pose hooks, the catalog entry (not playable: not in CHASSIS / CHASSIS_ORDER /
## BOT_CHASSIS_ORDER; max_item_weight), its size against the Strider and the Bulwark at game scale (printed) and its faces
## with the heaviest loadout.
func _wasp() -> void:
	const BUDGET := {"wasp_hull": 1600, "wasp_fan_ring": 550, "wasp_thigh": 300, "wasp_shin": 300}
	for part: String in WaspMeshes.all_parts():
		check(part.begins_with(WaspMeshes.PREFIX), "%s is a wasp_ part" % part)
		check(not MechMeshes.has_part(part) and not BulwarkMeshes.has_part(part), "%s belongs to WaspMeshes only" % part)
		if not check(ResourceLoader.exists(WaspMeshes.path(part)), "%s has a saved file" % part):
			continue
		var saved := load(WaspMeshes.path(part)) as ArrayMesh
		var built := WaspMeshes.build(part)
		eq(_faces(saved), _faces(built), "%s: the saved file matches the builder (faces)" % part)
		check(saved.get_aabb().is_equal_approx(built.get_aabb()), "%s: the saved file matches the builder (bounds)" % part)
		for s in saved.get_surface_count():
			check(saved.surface_get_name(s) in ["matte", "glow", "accent"], "%s: surface %s is matte / glow / accent" % [part, saved.surface_get_name(s)])
		var n := _faces(built)
		var cap := int(BUDGET.get(part, 400))
		check(n <= cap, "%s: within its face budget (%d <= %d)" % [part, n, cap])
		var thin := _thinnest(built)
		check(thin >= 0.0195, "%s: nothing thinner than 0.02 (thinnest shell %.4f)" % [part, thin])
	for part: String in ["wasp_hull", "wasp_fan_ring", "wasp_thigh", "wasp_shin"]:
		check(_accent_surface(WaspMeshes.mesh(part)) >= 0, "%s has an accent surface (on the fan ring: the team-colour read)" % part)
	# The legs wear the Strider's leg colours in the same places (user, 2026-11-25): the same surfaces as its parts.
	for pair: Array in [["wasp_thigh", "thigh"], ["wasp_shin", "shin"], ["wasp_foot", "foot"], ["wasp_spur", "spur"], ["wasp_toe", "toe"],
			["wasp_knee_cap", "knee_cap"], ["wasp_ankle_cap", "ankle_cap"]]:
		eq(str(_surface_names(WaspMeshes.mesh(pair[0]))), str(_surface_names(MechMeshes.mesh(pair[1]))), "%s has %s's surfaces" % pair)
	# Joints sized to the load (rule 3.3): drum radius >= 0.55 x the thicker segment it joins (WaspMeshes THIGH_THICK, SHIN_FOOT_THICK).
	check(WaspMeshes.HIP_DRUM.x >= 0.55 * WaspMeshes.THIGH_THICK, "hip drum %.3f >= 0.55 x the thigh's thickness" % WaspMeshes.HIP_DRUM.x)
	check(WaspMeshes.KNEE_DRUM.x >= 0.55 * WaspMeshes.THIGH_THICK, "knee drum %.3f >= 0.55 x the thigh's thickness" % WaspMeshes.KNEE_DRUM.x)
	check(WaspMeshes.ANKLE_DRUM.x >= 0.55 * WaspMeshes.SHIN_FOOT_THICK, "ankle drum %.3f >= 0.55 x the shin's foot end" % WaspMeshes.ANKLE_DRUM.x)
	near(WaspMeshes.mesh("wasp_thigh").get_aabb().position.y, -WaspMeshes.THIGH_L, 0.02, "wasp_thigh reaches its knee pin")
	near(WaspMeshes.mesh("wasp_shin").get_aabb().position.y, -WaspMeshes.SHIN_L, 0.02, "wasp_shin reaches its ankle pin")
	# The catalog: a draft (not playable), the light chassis' weight limit, and the Strider / Bulwark untouched by it.
	check(not MechCatalog.CHASSIS.has("wasp"), "the Wasp is not in MechCatalog.CHASSIS (no gameplay yet)")
	check(not "wasp" in MechCatalog.CHASSIS_ORDER and not "wasp" in MechCatalog.BOT_CHASSIS_ORDER, "nor in the hangar's or the bots' order")
	check(MechCatalog.DRAFT_CHASSIS.has("wasp") and ChassisParts.has("wasp") and not "wasp" in ChassisParts.ORDER, "a draft chassis with built art")
	eq(str(MechCatalog.chassis("wasp")["name"]), "Strider", "gameplay's chassis('wasp') is the Strider (unknown)")
	eq(str(MechCatalog.entry("wasp")["name"]), "Wasp", "entry('wasp') is the Wasp")
	eq(MechCatalog.max_item_weight("wasp"), 7.0, "the Wasp: no item over weight 7")
	check(is_inf(MechCatalog.max_item_weight("strider")) and is_inf(MechCatalog.max_item_weight("bulwark")), "no item limit on the Strider or the Bulwark")
	for hp: Dictionary in MechCatalog.entry("wasp")["hardpoints"]:
		for w: String in MechCatalog.WEAPON_ORDER + MechCatalog.EQUIPMENT_ORDER:
			if float(MechCatalog.weapon(w)["weight"]) > float(hp["max_item_weight"]):
				check(not MechCatalog.fits(hp, w), "wasp %s refuses %s (weight %.0f)" % [hp["id"], w, MechCatalog.weapon(w)["weight"]])
		check(MechCatalog.items_for(hp).size() >= 4, "wasp %s takes at least four light weapons (%s)" % [hp["id"], str(MechCatalog.items_for(hp))])
	for c: String in ["strider", "bulwark"]:
		for hp: Dictionary in MechCatalog.chassis(c)["hardpoints"]:
			var plain: Array[String] = []
			for w: String in MechCatalog.WEAPON_ORDER + MechCatalog.EQUIPMENT_ORDER:
				for kind: Variant in MechCatalog.hardpoint_mounts(hp):
					if kind in (MechCatalog.weapon(w)["mounts"] as Array) and not plain.has(w):
						plain.append(w)
			eq(str(MechCatalog.items_for(hp)), str(plain), "%s %s: items_for unchanged by the weight rule" % [c, hp["id"]])
		eq(str(MechCatalog.sanitize_loadout(c, {})), str(MechCatalog.sanitize_loadout(c, {}, true)), "%s: sanitize_loadout the same with drafts" % c)
	var sl := MechCatalog.sanitize_loadout("wasp", {"stub_l": "railgun", "stub_r": "autocannon", "chin": "autocannon"}, true)
	eq(str(sl), str({"stub_l": "", "stub_r": "autocannon", "chin": ""}), "wasp sanitize: the railgun (a shoulder item, 14) and the chin's autocannon (7 > 6) emptied")
	eq(str(MechCatalog.sanitize_loadout("wasp", {}, true)), str(MechCatalog.entry("wasp")["default_loadout"]), "the Wasp's default loadout is valid")
	check(not MechCatalog.sanitize_loadout("wasp", {}).has("stub_l"), "without drafts a 'wasp' loadout is the Strider's (gameplay)")
	# Unreachable from the game: without show_drafts a model asked for the Wasp builds the Strider.
	var plain_m := MechModel.new()
	plain_m.configure("chicken", "wasp", {})
	add_child(plain_m)
	await frames(1)
	eq(plain_m.chassis_id, "strider", "MechModel without show_drafts: 'wasp' gives the Strider")
	plain_m.queue_free()
	# The assembled Wasp.
	var m := MechModel.new()
	m.show_drafts = true
	m.configure("chicken", "wasp", {})
	add_child(m)
	await frames(1)
	eq(m.chassis_id, "wasp", "show_drafts: the model builds the Wasp")
	check(m.is_hover() and ChassisParts.is_hover("wasp") and not ChassisParts.is_hover("strider") and not ChassisParts.is_hover("bulwark"),
		"the Wasp is the hover chassis")
	for n: String in ["Torso", "Nose", "Hatch", "Fin", "Cockpit", "Head_chicken", "Strut_l", "Strut_r", "fan_l", "fan_r", "rotor_l", "rotor_r",
			"HP_stub_l", "HP_stub_r", "HP_chin", "socket_l", "socket_r", "hip_l", "hip_r", "thigh_l", "thigh_r", "knee_l", "knee_r", "shin_l",
			"shin_r", "ankle_l", "ankle_r", "foot_l", "foot_r"]:
		check(m.find_child(n, true, false) != null, "wasp has %s" % n)
	for n: String in ["pusher_l", "pusher_r", "BackPlate", "Pelvis", "tarsus_l", "ShoulderPod_l", "Pod_l"]:
		check(m.find_child(n, true, false) == null, "wasp has no %s" % n)
	for hp: String in ["HP_stub_l", "HP_stub_r", "HP_chin"]:
		check(m.find_child(hp, true, false).find_child("Mount", false, false) != null, "%s has its mount" % hp)
	for side: String in ["l", "r"]:
		var foot := m.find_child("foot_" + side, true, false)
		var toes := 0
		for c in foot.get_children():
			if c.name.begins_with("toe"):
				toes += 1
		eq(toes, 3, "wasp foot_%s has three toes" % side)
		check(foot.find_child("spur", true, false) != null, "wasp foot_%s has its spur" % side)
		check((m.find_child("fan_" + side, true, false) as Node3D).find_child("Ring", false, false) != null, "fan_%s has its ring" % side)
	# Every allowed item on every hardpoint shows its mesh.
	for hp: Dictionary in MechCatalog.entry("wasp")["hardpoints"]:
		for w: String in MechCatalog.items_for(hp):
			m.configure("chicken", "wasp", {hp["id"]: w})
			var node := m.find_child("HP_" + str(hp["id"]), true, false)
			var gun := node.find_child("Weapon_" + w, true, false) if node != null else null
			check(gun != null and gun.get_child_count() == 1, "wasp %s mounts %s" % [hp["id"], w])
	m.configure("chicken", "wasp", {})
	await frames(1)
	# The hooks (cosmetic, local).
	m.time_scale = 0.0
	var rotor := m.find_child("rotor_r", true, false) as Node3D
	var rotor_l := m.find_child("rotor_l", true, false) as Node3D
	m._rotor_angle = 0.0
	m.set_fan_spin(2.0)
	m.step_fans(0.1)
	m.pose()
	near(rotor.rotation.y, 0.2 * TAU, 1e-4, "set_fan_spin + step_fans turn the rotor (2 rev/s for 0.1 s)")
	near(rotor_l.rotation.y, -0.2 * TAU, 1e-4, "the left rotor turns the other way")
	var fan := m.find_child("fan_r", true, false) as Node3D
	m.set_fan_tilt(Vector2(0.2, 0.0))
	near(fan.rotation.x, -0.2, 1e-5, "set_fan_tilt pitches the fan (front edge down)")
	m.set_fan_tilt(Vector2(5.0, 5.0))
	var cl := m.fan_tilt(1)
	var tm: Vector2 = WaspMeshes.FAN_TILT_MAX
	near(Vector2(cl.x / tm.x, cl.y / tm.y).length(), 1.0, 1e-4, "set_fan_tilt clamps to the tilt ellipse")
	check(tm.x >= deg_to_rad(15.0) and tm.y >= deg_to_rad(10.0), "the fans vector: at least 15 deg forward / back, 10 deg sideways (%s rad)" % str(tm))
	m.set_fan_tilt(Vector2.ZERO)
	m.set_fan_tilt(Vector2(0.1, 0.0), -1)
	check(m.fan_tilt(-1).is_equal_approx(Vector2(0.1, 0.0)) and m.fan_tilt(1).is_equal_approx(Vector2.ZERO), "set_fan_tilt(side) tilts one fan")
	m.set_fan_tilt(Vector2.ZERO)
	var foot_r := m.find_child("foot_r", true, false) as Node3D
	m.set_legs_pose(0.0)
	var dangle := foot_r.global_position
	m.set_legs_pose(1.0)
	var stand := foot_r.global_position
	check(dangle.y > stand.y + 0.05, "set_legs_pose: the dangling foot is tucked up (%.3f over the standing one)" % (dangle.y - stand.y))
	near(stand.y, 0.0, 0.002, "set_legs_pose(1): the foot stands on the model's ground")
	var body := m.find_child("Body", false, false) as Node3D
	m.set_bank(0.3, -0.1)
	near(body.rotation.z, -0.3, 1e-5, "set_bank rolls the body (right side down)")
	near(body.rotation.x, -0.1, 1e-5, "set_bank pitches the body")
	m.set_bank(0.0, 0.0)
	m.set_external_pose([{}, {}], Vector3(0, 0.5, 0), Vector3.ZERO, 0.3)   # MechRig's call: ignored by a hover chassis
	near(body.position.y, m.hip_height(), 1e-4, "set_external_pose does not move a hover chassis")
	m.clear_external_pose()
	# The lab: every Wasp param to its ends (test_lab sweeps the subject's first chassis only).
	for p: Dictionary in m.lab_params():
		for v: float in [float(p["min"]), float(p["max"])]:
			m.set_lab_param(str(p["id"]), v)
	for p: Dictionary in m.param_specs():
		m.set_lab_param(str(p["id"]), float(p["value"]))
	var lab := MechModel.new()
	add_child(lab)
	lab.set_lab_option("chassis", "wasp")
	eq(lab.chassis_id, "wasp", "the lab's chassis option reaches the Wasp")
	check("wasp" in (lab.lab_options()[2]["choices"] as Array), "the lab lists the Wasp")
	lab.set_lab_option("chassis", "strider")
	eq(lab.chassis_id, "strider", "and back to the Strider")
	lab.queue_free()
	# Size at game scale (mech scale 2) against the Strider and the Bulwark (printed: the report's table).
	var sizes := {}
	for c: String in ["strider", "bulwark", "wasp"]:
		m.configure("chicken", c, {})
		if c == "wasp":
			m.set_legs_pose(1.0)
		await frames(1)
		var all := AABB()
		var comb := 0.0
		for mi_n in m.find_children("*", "MeshInstance3D", true, false):
			var mi := mi_n as MeshInstance3D
			if mi.mesh == null or not mi.is_visible_in_tree():
				continue
			var b := mi.global_transform * mi.mesh.get_aabb()
			all = b if all.size == Vector3.ZERO else all.merge(b)
			if m.find_child("Head_chicken", true, false).is_ancestor_of(mi):
				comb = maxf(comb, b.end.y)
		sizes[c] = [all, comb * 2.0]
	var hb := WaspMeshes.mesh("wasp_hull").get_aabb()
	var k := 2.0 * WaspMeshes.BODY_SCALE
	var hull_w := hb.size.x * k
	var hull_l := hb.size.z * k
	var hull_h := (WaspMeshes.HATCH_Y + 0.1 - hb.position.y) * k   # belly to the hatch rim
	var fan_d := 2.0 * (WaspMeshes.RING_OUT + 0.018) * k
	var wasp_all: AABB = sizes["wasp"][0]
	var width := wasp_all.size.x * 2.0
	var comb_w: float = sizes["wasp"][1]
	var belly := (WaspMeshes.BODY_Y + hb.position.y * WaspMeshes.BODY_SCALE) * 2.0
	var leg := (WaspMeshes.THIGH_L + WaspMeshes.SHIN_L + WaspMeshes.FOOT_H) * k
	print("  size at scale 2 (m): comb landed  strider %.2f  bulwark %.2f  wasp %.2f" % [sizes["strider"][1], sizes["bulwark"][1], comb_w])
	print("    overall width     strider %.2f  bulwark %.2f  wasp %.2f (across the fans)" % [(sizes["strider"][0] as AABB).size.x * 2.0,
		(sizes["bulwark"][0] as AABB).size.x * 2.0, width])
	print("    overall height    strider %.2f  bulwark %.2f  wasp %.2f (landed)" % [(sizes["strider"][0] as AABB).end.y * 2.0,
		(sizes["bulwark"][0] as AABB).end.y * 2.0, wasp_all.end.y * 2.0])
	print("    wasp hull %.2f wide x %.2f tall (belly to hatch rim; %.2f to the coaming) x %.2f long; fan diameter %.2f; belly %.2f over the ground landed; leg (thigh + shin + foot) %.2f" % [
		hull_w, hull_h, hb.size.y * k, hull_l, fan_d, belly, leg])
	check(hull_w >= 3.85 and hull_w <= 4.05, "the hull pod is about 3.9-4.0 m wide (pass 2: a smidge wider; %.2f)" % hull_w)
	check(hull_h >= 3.2 and hull_h <= 3.8, "the hull pod is 3.2-3.8 m tall to the hatch rim (%.2f)" % hull_h)
	check(hull_l >= 4.85 and hull_l <= 5.15, "the hull pod is about 4.9-5.1 m long, chin block included (pass 2: slightly longer; %.2f)" % hull_l)
	check(width <= 8.8, "no more than about 8.8 m across the fans (8.5 grown with the hull in pass 2; %.2f)" % width)
	check(fan_d >= 0.75 * hull_w, "each main fan about the hull's width (%.2f vs %.2f)" % [fan_d, hull_w])
	check(comb_w < 0.7 * float(sizes["strider"][1]) and comb_w < float(sizes["bulwark"][1]) - 1.0, "small next to the others: comb %.2f m (Strider %.2f, Bulwark %.2f)" % [
		comb_w, sizes["strider"][1], sizes["bulwark"][1]])
	check(width < (sizes["bulwark"][0] as AABB).size.x * 2.0, "narrower than the Bulwark")
	# Faces, heaviest loadout (rule 6.6: the light chassis is the cheapest).
	var heavy := {}
	for c: String in ["strider", "bulwark", "wasp"]:
		var lo := {}
		for hp: Dictionary in MechCatalog.entry(c)["hardpoints"]:
			var best := ""
			for w: String in MechCatalog.items_for(hp):
				if w == "railgun" and lo.values().has("railgun"):
					continue
				if best == "" or _faces(MechMeshes.mesh("weapon_" + w)) > _faces(MechMeshes.mesh("weapon_" + best)):
					best = w
			lo[hp["id"]] = best
		m.configure("chicken", c, lo)
		await frames(1)
		heavy[c] = _tree_faces(m)
		print("  %s, heaviest loadout %s: %d faces" % [c, str(lo), heavy[c]])
	var parts_faces := {}
	for n: String in ["Torso", "Nose", "Hatch", "Fin", "Strut_r", "fan_r", "HP_stub_r", "HP_chin", "socket_r", "hip_r", "Cockpit"]:
		var pn := m.find_child(n, true, false)
		var own := pn as MeshInstance3D
		parts_faces[n] = _tree_faces(pn) + (_faces(own.mesh as ArrayMesh) if own != null else 0)
	print("  wasp faces by part (right side): %s" % str(parts_faces))
	check(int(heavy["wasp"]) < int(heavy["bulwark"]) and float(heavy["wasp"]) <= 0.85 * float(heavy["strider"]),
		"the Wasp is the cheapest chassis (%d faces vs Strider %d, Bulwark %d)" % [heavy["wasp"], heavy["strider"], heavy["bulwark"]])
	m.configure("chicken", "strider", {})
	eq(m.leg_bend, -1.0, "back to the Strider from the Wasp: its chicken legs")
	near(float(m.params["thigh"]), 1.1, 1e-6, "and its thigh")
	check(m.find_child("fan_l", true, false) == null and m.find_child("thigh_l", true, false) != null, "and its biped node tree")
	m.queue_free()
