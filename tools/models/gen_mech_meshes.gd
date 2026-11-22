extends SceneTree
## Regenerate the mech's low-poly part files from the builders in scripts/mech/mech_meshes.gd:
##   .\tools\models\gen_mech_meshes.ps1
## Writes res://assets/models/mech/<part>.res (one ArrayMesh per part) and the two shared materials
## (mech_matte.tres, mech_glow.tres). tests/test_mech_parts.gd fails when the saved files lag the builders.


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(MechMeshes.DIR)
	var mats := []
	for n: String in ["matte", "glow"]:
		var p := MechMeshes.DIR + "mech_" + n + ".tres"
		var m := MechMeshes.make_material(n == "glow")
		ResourceSaver.save(m, p)
		m.take_over_path(p)
		mats.append(m)
	MechMeshes._mats = mats
	var faces := 0
	for part: String in MechMeshes.all_parts():
		var mesh := MechMeshes.build(part)
		var err := ResourceSaver.save(mesh, MechMeshes.path(part))
		var n := 0
		for s in mesh.get_surface_count():
			n += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		faces += n
		print("%-22s %4d faces %s" % [part, n, "" if err == OK else "SAVE ERROR %d" % err])
	print("%d parts, %d faces" % [MechMeshes.all_parts().size(), faces])
	quit()
