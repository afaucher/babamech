extends TestCase
## ShaderWarmup (scripts/app/shader_warmup.gd), headless: what it would draw. One copy per look (material, vertex format,
## shadow casting, mesh / multimesh layout): two meshes with the same look make one copy, a different material or a
## shadow-less instance another, hidden nodes count, a MultiMesh gets a one-instance copy of its layout; the extras cover
## the shared materials, the FX caches, the trail, the rail ribbon, the enemy tag and every pilot head. should_run() is
## false headless and in tests. (Drawing them is test_visual_shader_warmup.)


func setup() -> void:
	check(not ShaderWarmup.should_run(), "never headless")
	var root := Node3D.new()
	add_child(root)
	var mat_a := StandardMaterial3D.new()
	var mat_b := StandardMaterial3D.new()
	mat_b.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var box := BoxMesh.new()
	for i in 3:   # three of the same look
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = mat_a
		root.add_child(mi)
	var other := MeshInstance3D.new()
	other.mesh = box
	other.material_override = mat_b
	other.visible = false   # hidden: still a look to warm
	root.add_child(other)
	var no_shadow := MeshInstance3D.new()
	no_shadow.mesh = box
	no_shadow.material_override = mat_a
	no_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(no_shadow)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = 40
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat_a
	root.add_child(mmi)

	var w := ShaderWarmup.new()
	add_child(w)
	w._scan(root)
	eq(w._items.size(), 4, "one copy per look: same look x3, another material (hidden), no shadow, a multimesh")
	var copy_mm: MultiMeshInstance3D = null
	for it in w._items:
		if it is MultiMeshInstance3D:
			copy_mm = it
	check(copy_mm != null and copy_mm.multimesh.instance_count == 1 and copy_mm.multimesh.use_colors,
		"the multimesh copy keeps the layout with one instance")
	w._scan(root)
	eq(w._items.size(), 4, "a second scan adds nothing")
	var n := w._items.size()
	w._extras()
	var extra := w._items.size() - n
	check(extra >= 15, "the extras add the shared materials, FX meshes, trail, rail ribbon, tag and heads (%d)" % extra)
	var has_label := false
	var has_shader := false
	for it in w._items:
		has_label = has_label or it is Label3D
		var mi := it as MeshInstance3D
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0 and mi.mesh.surface_get_material(0) is ShaderMaterial:
			has_shader = true
	check(has_label, "an enemy tag (Label3D)")
	check(has_shader, "the rail slug ribbon (its ShaderMaterial)")
	var cam := Camera3D.new()
	add_child(cam)
	w._layout(cam)
	var far := 0.0
	for it in w._items:
		far = maxf(far, absf(it.position.z))
	check(far < ShaderWarmup.NEAR * 2.0, "laid out just in front of the camera")
	w.queue_free()
	root.queue_free()
	finish()
