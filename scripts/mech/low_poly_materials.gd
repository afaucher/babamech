class_name LowPolyMaterials
extends RefCounted
## The shared materials of the low-poly art and the accent recolouring. Vertex colours carry the palette
## (LowPolyPalette); the materials are saved beside the mech meshes as mech_<kind>.tres (tools/models/gen_mech_meshes.gd)
## and built here when the files are missing. Cosmetic only (no gameplay state).

static var _mats: Array = []
static var _accent_mats: Dictionary = {}   ## colour html -> accent material copy


## [matte, glow, accent, heat]: the shared materials in MeshKit.SURFACES order (the accent material's albedo colour
## tints the white accent faces).
static func materials() -> Array:
	if _mats.is_empty():
		for n: String in MeshKit.SURFACES:
			var p := MechMeshes.DIR + "mech_" + n + ".tres"
			_mats.append(load(p) if ResourceLoader.exists(p) else make_material(n))
	return _mats


## A shared material: kind "matte" | "glow" | "accent" | "heat" (lit like matte; the radiator's fins, which the game
## overrides with an emissive copy by surface name to show heat).
static func make_material(kind: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.8
	m.metallic_specular = 0.3
	if kind == "glow":
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	elif kind == "accent":
		m.albedo_color = LowPolyPalette.ORANGE
	return m


## The accent material for a colour: the shared one for (about) ORANGE, else a tinted copy, cached per colour.
static func accent_material(color: Color) -> StandardMaterial3D:
	var base: StandardMaterial3D = materials()[2]
	if color.is_equal_approx(LowPolyPalette.ORANGE):
		return base
	var key := color.to_html()
	if not _accent_mats.has(key):
		var m := base.duplicate() as StandardMaterial3D
		m.albedo_color = color
		_accent_mats[key] = m
	return _accent_mats[key]


## Recolour the accent surface of every mesh under `root` (root included). ORANGE clears the overrides (the default).
static func apply_accent(root: Node, color: Color) -> void:
	var mat: Material = null if color.is_equal_approx(LowPolyPalette.ORANGE) else accent_material(color)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_name(i) == "accent":
				mi.set_surface_override_material(i, mat)
