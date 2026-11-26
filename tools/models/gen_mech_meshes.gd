extends SceneTree
## Regenerate the mech's low-poly part files from the builders in scripts/mech/mech_meshes.gd (the Strider, the shared
## weapons, equipment and heads), scripts/mech/bulwark_meshes.gd (the Bulwark's bulwark_* parts) and
## scripts/mech/wasp_meshes.gd (the Wasp's wasp_* parts):
##   .\tools\models\gen_mech_meshes.ps1                 every part and the shared materials
##   .\tools\models\gen_mech_meshes.ps1 --only wasp_    only the parts whose name starts with the prefix (every other file,
##                                                      the materials included, left untouched)
## Writes res://assets/models/mech/<part>.res (one ArrayMesh per part) and the shared materials
## (mech_matte.tres, mech_glow.tres, mech_accent.tres, mech_heat.tres). tests/test_mech_parts.gd fails when the saved files lag the builders.


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(MechMeshes.DIR)
	var only := ""
	var ua := OS.get_cmdline_user_args()
	if ua.size() >= 2 and ua[0] == "--only":
		only = ua[1]
	if only == "":
		var mats := []
		for n: String in MeshKit.SURFACES:
			var p := MechMeshes.DIR + "mech_" + n + ".tres"
			var m := MechMeshes.make_material(n)
			ResourceSaver.save(m, p)
			m.take_over_path(p)
			mats.append(m)
		MechMeshes._mats = mats
	var faces := 0
	var all: Array[String] = MechMeshes.all_parts()
	all.append_array(BulwarkMeshes.all_parts())
	all.append_array(WaspMeshes.all_parts())
	if only != "":
		all = all.filter(func(p: String) -> bool: return p.begins_with(only))
	for part: String in all:
		var mesh := ChassisParts.build(part)
		var err := ResourceSaver.save(mesh, MechMeshes.path(part))
		var n := 0
		for s in mesh.get_surface_count():
			n += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		faces += n
		print("%-22s %4d faces %s" % [part, n, "" if err == OK else "SAVE ERROR %d" % err])
	print("%d parts, %d faces" % [all.size(), faces])
	quit()
