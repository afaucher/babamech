extends TestCase
## The project boots: the autoload is up, the menu and the lab scenes load and run a few frames, the catalog is coherent
## and the placeholder mech stands on its feet with every hardpoint's weapon on it.


func setup() -> void:
	check(Session != null and Session is NetSession, "the Session autoload is a NetSession")
	check(not Session.online() and Session.is_host(), "offline at start, and offline counts as host (solo)")
	eq(Boot.route(PackedStringArray()), Boot.MENU_SCENE, "a plain run opens the menu")
	eq(Boot.route(PackedStringArray(["--scene", "res://scenes/lab.tscn"])), "res://scenes/lab.tscn", "--scene opens that scene")

	# Catalog.
	eq(MechCatalog.HEAD_ORDER.size(), 4, "four heads")
	for h: String in ["chicken", "pickle", "corn", "dog"]:
		check(MechCatalog.HEADS.has(h), "head %s exists" % h)
	for id: String in MechCatalog.WEAPON_ORDER:
		var w := MechCatalog.weapon(id)
		for k in ["weight", "passive_heat", "active_heat", "mounts"]:
			check(w.has(k), "weapon %s has %s" % [id, k])
	var dl := MechCatalog.sanitize_loadout("strider", {})
	eq(dl.size(), 5, "the strider has five hardpoints")
	eq(str(dl["back"]), "mortar", "an empty loadout gets the chassis default")
	var bad := MechCatalog.sanitize_loadout("strider", {"side_l": "mortar", "back": "nonsense"})
	eq(str(bad["side_l"]), "", "a mortar doesn't fit a side mount")
	eq(str(bad["back"]), "", "an unknown weapon is emptied")
	var st := MechCatalog.loadout_stats("strider", dl)
	near(float(st["weight"]), 4.0 + 7.0 + 6.0 + 9.0, 0.001, "default loadout weight")

	# The mech.
	var m := MechModel.new()
	m.configure("dog", "strider", dl)
	add_child(m)
	await frames(2)
	check(m.hip_height() > 1.5, "the hips stand above 1.5 m (%.2f)" % m.hip_height())
	for side in ["l", "r"]:
		var foot := m.find_child("foot_" + side, true, false) as Node3D
		if check(foot != null, "foot_%s exists" % side):
			near(foot.position.y, 0.0, 0.05, "foot_%s is on the ground" % side)
	# Chicken-style legs (the mech faces -Z): the knee forward of the hip, the reverse joint (ankle) behind the knee, the
	# foot forward of the ankle, every joint lower than the last. (MechModel.leg_points: the joints the leg was posed on.)
	var pts := m.leg_points(0)
	var knee := (m.find_child("thigh_l", true, false) as Node3D)
	var hip: Vector3 = pts["hip"]
	var k: Vector3 = pts["knee"]
	var ankle: Vector3 = pts["ankle"]
	var foot_p: Vector3 = pts["foot"]
	check(knee != null and k.z < hip.z - 0.1, "the knee is forward of the hip (%.2f vs %.2f)" % [k.z, hip.z])
	check(ankle.z > k.z + 0.1, "the ankle is behind the knee: a reverse joint (%.2f vs %.2f)" % [ankle.z, k.z])
	check(foot_p.z < ankle.z, "the foot is forward of the ankle")
	check(hip.y > k.y and k.y > ankle.y and ankle.y > foot_p.y, "each joint is lower than the last")
	var head := m.find_child("Head_dog", true, false) as Node3D
	check(head != null, "the dog head sits in the cockpit")
	if head != null:
		check(head.global_position.z < -0.5 and head.global_position.y > m.hip_height(), "the head rides in the nose, above the hips")
	for hp in ["side_l", "side_r", "shoulder_l", "back"]:
		var node := m.find_child("HP_" + hp, true, false)
		check(node != null and node.find_child("Weapon_*", true, false) != null, "hardpoint %s carries its weapon" % hp)
	m.queue_free()

	# The scenes load and run.
	for path in [Boot.MENU_SCENE, "res://scenes/lab.tscn"]:
		var ps := load(path) as PackedScene
		if not check(ps != null, "%s loads" % path):
			continue
		var n := ps.instantiate()
		add_child(n)
		await frames(5)
		check(is_instance_valid(n) and n.is_inside_tree(), "%s runs" % path)
		n.queue_free()
		await frames(1)
	finish()
