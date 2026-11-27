class_name PartCache
extends RefCounted
## The cache of saved low-poly part meshes shared by the chassis builders (MechMeshes, BulwarkMeshes, WaspMeshes): a part
## is the saved file <dir><part>.res when it exists, else built now by its builder; either way built once. Keyed by the
## file path, so one key is one file whichever builder asks (part names are unique across chassis: the prefixes).
## Cosmetic only (no gameplay state).

static var _meshes: Dictionary = {}   ## file path -> ArrayMesh


## The part's mesh: the saved file when it exists, else `builder.call(part)`.
static func mesh(dir: String, part: String, builder: Callable) -> ArrayMesh:
	var p := dir + part + ".res"
	if _meshes.has(p):
		return _meshes[p]
	var m: ArrayMesh = null
	if ResourceLoader.exists(p):
		m = load(p) as ArrayMesh
	if m == null:
		m = builder.call(part)
	_meshes[p] = m
	return m


## A MeshInstance3D of a part, named after it.
static func instance(dir: String, part: String, builder: Callable) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = mesh(dir, part, builder)
	return mi
