extends TestCase
## The fifth pilot head, the duck, is accepted everywhere a head is: the catalog and its order, the settings file (saved,
## loaded, not reset to the chicken), the session profile (what the join handshake / sys.profile carry; the two-process
## proof is tests/test_net_handshake.gd, whose client switches to the duck), the mech (a Head_duck in the cockpit, holding
## the duck's PilotHead rig), the static mesh and the rig (same bounds at rest).

const PATH := "user://test_pilot_duck.cfg"


func setup() -> void:
	# Catalog.
	check(MechCatalog.HEADS.has("duck"), "the duck is in the catalog")
	eq(MechCatalog.head_name("duck"), "Duck", "it is called Duck")
	check("duck" in MechCatalog.HEAD_ORDER, "the duck is in the head order (pickers list it)")
	check("duck" in MechMeshes.HEADS, "the duck has a static mesh")
	check(PilotHead.REGISTRY.has("duck"), "the duck has a rig")

	# Settings: saved and loaded back as the duck, not reset to the default.
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	var d := GameSettings.load_settings()
	d["head"] = "duck"
	check(GameSettings.save_settings(d), "saves")
	eq(str(GameSettings.load_settings()["head"]), "duck", "the duck head round-trips through the settings file")
	GameSettings.set_value("head", "duck")
	eq(str(GameSettings.load_settings()["head"]), "duck", "set_value keeps the duck")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	GameSettings.path = GameSettings.DEFAULT_PATH

	# The session profile (offline: stored, and what the hello / sys.profile send).
	var old := [Session.player_name, Session.local_head(), Session.local_chassis()]
	Session.set_profile("Drake", "duck", "strider")
	eq(Session.local_head(), "duck", "the session carries the duck head")
	Session.set_profile(old[0], old[1], old[2])

	# The mech: a Head_duck in the cockpit, holding the duck's pilot rig (MechModel.pilot, tests/test_pilot_mech.gd).
	var m := MechModel.new()
	m.configure("duck", "strider", {})
	add_child(m)
	await frames(1)
	eq(m.head_id, "duck", "MechModel keeps the duck")
	var head := m.find_child("Head_duck", true, false) as Node3D
	if check(head != null, "the duck head sits in the cockpit"):
		check(m.pilot != null and m.pilot.get_parent() == head and m.pilot.head_id == "duck", "it holds the duck's pilot rig")
	m.queue_free()

	# Static mesh vs rig at rest.
	var sb := MechMeshes.build("head_duck").get_aabb()
	check(sb.position.y > -0.01 and sb.end.y > 1.0, "the static duck stands on its neck base (%s)" % sb)
	var h := PilotHead.make("duck", 0)
	h.idle_enabled = false
	add_child(h)
	h.set_process(false)
	eq(h.head_id, "duck", "the duck builds its own rig")
	var rb := _bounds(h)
	rb.size.y += minf(rb.position.y, 0.0)   # leave out the neck seal's collar plug under the base (the static duck has none)
	rb.position.y = maxf(rb.position.y, 0.0)
	check(rb.position.distance_to(sb.position) < 0.1 and rb.end.distance_to(sb.end) < 0.1,
		"rig at rest matches the static duck's bounds (%s vs %s)" % [rb, sb])
	h.queue_free()
	finish()


func _bounds(h: PilotHead) -> AABB:
	var inv := h.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for mi in h.find_children("*", "MeshInstance3D", true, false):
		var mm := mi as MeshInstance3D
		var b := (inv * mm.global_transform) * mm.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
