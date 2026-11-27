class_name PilotBody
extends MeshInstance3D
## A pilot head's ONE continuous body surface (docs/design/pilot-heads.md section 2, "One mesh"): the collar plug, the
## lower neck, the upper neck and the skull are a single closed, flat-shaded mesh, so no pose can open a seam between them
## (user bug 2026-11-22: "you can see a neck seam when the head moves around ... We need one mesh"). The skull's rigid
## extras (beak, bill, snout, nose, eye discs, the dark mouth) are in the same surface, bound to the skull alone.
##
## Built by PilotFace.add_body from two MeshKits authored in head-rest space (after girth):
##   shell  the continuous loft (neck base ring up to the crown cap) + the collar plug. Every vertex is bound to the
##          joints NeckLow / NeckHigh / Skull by weights that depend only on its rest height (`weights_at`), so two faces
##          that share a vertex always move it to the same place: the shell stays closed in every pose, faces that span
##          a joint stretch and shear instead of separating.
##   rigid  carried by the Skull only (weight 1).
## The node hangs under the Skull joint at -skull pivot (like a PilotFace piece mesh), so the mesh is in head-rest space
## at rest and everything bound to the Skull alone is CONSTANT: each pose only recomputes the neck vertices (about 40) as
## a linear blend of the joints' rest-to-pose transforms (expressed in the Skull's space), re-derives their faces' flat
## normals and writes the vertex buffer (ArrayMesh.surface_update_vertex_region). Colours never change; the flush tint is
## the head material's job as before. `deformed` holds the exact vertices last written (tests read it, also headless,
## where the dummy renderer ignores buffer updates).
## Cosmetic only (Net.LOCAL); no randomness.

const JOINTS: Array[String] = ["NeckLow", "NeckHigh", "Skull"]
## Snap for "same rest vertex" (head-rest units): corners closer than this are one vertex.
const WELD := 0.0005
## How far (head-rest units) the moving neck can leave its rest box in the mesh's space: the custom AABB margin.
const AABB_GROW := 0.7

## Corners (3 per face), head-rest space after girth. The first `shell_faces` faces are the closed shell.
var rest := PackedVector3Array()
var colors := PackedColorArray()
## Per corner: (NeckLow, NeckHigh, Skull) weights, summing to 1.
var weights := PackedVector3Array()
var shell_faces := 0
## The corners last written to the mesh, in the mesh's space (head-rest space at rest); the rest face normals.
var deformed := PackedVector3Array()
var normals := PackedVector3Array()
## Updates that actually changed the neck (tests / diagnostics), and the last update's cost in microseconds.
var updates := 0
var last_usec := 0

var _face: PilotFace
var _pivots: Array[Vector3] = []
var _move_rest := PackedVector3Array()   ## the moving (not skull-only) welded vertices, rest positions
var _move_w := PackedVector3Array()      ## and their weights
var _corner_move := PackedInt32Array()   ## corner -> moving vertex index, or -1
var _mc := PackedInt32Array()            ## the moving corners
var _mu := PackedInt32Array()            ## and their moving vertex index
var _move_faces := PackedInt32Array()    ## faces with at least one moving corner
var _nt := PackedInt32Array()            ## the normal / tangent stream, 2 ints per corner (oct normal, tangent)
var _pos_bytes := 0                      ## byte size of the position block (vertex count x 12)
var _direct := false                     ## the vertex buffer layout is the plain one (positions, then normal+tangent)
var _last := [Transform3D(), Transform3D()]
var _cur_n := PackedVector3Array()       ## the current face normals (only kept on the fallback path)


## The weights (NeckLow, NeckHigh, Skull) of a rest point at height `y` (head-rest units): NeckLow -> NeckHigh along a
## linear ramp from bend.x to bend.y (linear, so every band of the neck takes its share of a bend and none folds up),
## NeckHigh -> Skull across [y2 - skull_blend, y2] (y2 = the Skull pivot's height; that blend only carries the skull's
## squash). Everything at or above y2 and past the ramp is the Skull's alone, so its rigid extras sit on it exactly.
static func weights_at(y: float, bend: Vector2, y2: float, skull_blend: float) -> Vector3:
	var s1 := clampf((y - bend.x) / maxf(bend.y - bend.x, 1e-4), 0.0, 1.0)
	var s2 := 1.0 if y >= y2 else smoothstep(y2 - skull_blend, y2, y)
	return Vector3(1.0 - s1, s1 * (1.0 - s2), s1 * s2)


## Builds the mesh from the shell and rigid kits (head-rest space after girth). `pivots`: the joints' pivots (head-rest,
## after girth) in JOINTS order; `bend`, `skull_blend`: see weights_at. Call once.
func setup(face: PilotFace, shell: MeshKit, rigid: MeshKit, pivots: Array[Vector3], bend: Vector2,
		skull_blend: float) -> void:
	_face = face
	_pivots = pivots
	name = "Body_mesh"
	for k: MeshKit in [shell, rigid]:
		for s in range(1, MeshKit.SURFACES.size()):
			if not k._v[s].is_empty():
				push_error("PilotBody %s: only matte faces belong in the body (surface %s)" % [face.id, MeshKit.SURFACES[s]])
	rest = shell._v[0].duplicate()
	rest.append_array(rigid._v[0])
	normals = shell._n[0].duplicate()
	normals.append_array(rigid._n[0])
	colors = shell._c[0].duplicate()
	colors.append_array(rigid._c[0])
	shell_faces = shell._v[0].size() / 3
	var y2 := pivots[2].y
	weights.resize(rest.size())
	_corner_move.resize(rest.size())
	var welded := {}
	for i in rest.size():
		var w := weights_at(rest[i].y, bend, y2, skull_blend) if i < shell_faces * 3 else Vector3(0.0, 0.0, 1.0)
		weights[i] = w
		_corner_move[i] = -1
		if w.z >= 1.0 - 1e-6:
			continue
		var key := Vector3i((rest[i] / WELD).round())
		if not welded.has(key):
			welded[key] = _move_rest.size()
			_move_rest.append(rest[i])
			_move_w.append(w)
		_corner_move[i] = int(welded[key])
		_mc.append(i)
		_mu.append(int(welded[key]))
	for f in rest.size() / 3:
		if _corner_move[f * 3] >= 0 or _corner_move[f * 3 + 1] >= 0 or _corner_move[f * 3 + 2] >= 0:
			_move_faces.append(f)
	deformed = rest.duplicate()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = rest
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	m.surface_set_material(0, LowPolyMaterials.materials()[0])
	m.surface_set_name(0, "matte")
	mesh = m
	var box := m.get_aabb()
	custom_aabb = box.grow(AABB_GROW)
	position = -pivots[2]
	_read_layout()


## The plain vertex layout (positions as float32 x 3, then an oct normal + tangent per vertex) lets update() write the
## buffer directly; anything else falls back to rebuilding the surface.
func _read_layout() -> void:
	var n := rest.size()
	var fmt: int = (mesh as ArrayMesh).surface_get_format(0)
	var sd := RenderingServer.mesh_get_surface(mesh.get_rid(), 0)
	var vd: PackedByteArray = sd.get("vertex_data", PackedByteArray())
	var pos_stride := RenderingServer.mesh_surface_get_format_vertex_stride(fmt, n)
	var nt_stride := RenderingServer.mesh_surface_get_format_normal_tangent_stride(fmt, n)
	var nt_off := RenderingServer.mesh_surface_get_format_offset(fmt, n, Mesh.ARRAY_NORMAL)
	_pos_bytes = n * 12
	_direct = pos_stride == 12 and nt_stride == 8 and nt_off == _pos_bytes and vd.size() == _pos_bytes + n * 8 \
		and rest.to_byte_array().size() == _pos_bytes
	if _direct:
		_nt = vd.slice(nt_off).to_int32_array()


## Re-poses the neck from the joint nodes (call after the joints moved). Returns true when the mesh changed.
func update() -> bool:
	var t0 := Time.get_ticks_usec()
	var d := _rest_to_pose()
	if d.size() < 3:
		return false
	var skull_inv: Transform3D = (d[2] as Transform3D).affine_inverse()
	var m_low: Transform3D = skull_inv * (d[0] as Transform3D)
	var m_high: Transform3D = skull_inv * (d[1] as Transform3D)
	if m_low.is_equal_approx(_last[0]) and m_high.is_equal_approx(_last[1]) and updates > 0:
		return false
	_last = [m_low, m_high]
	var moved := PackedVector3Array()
	moved.resize(_move_rest.size())
	for i in _move_rest.size():
		var p := _move_rest[i]
		var w := _move_w[i]
		moved[i] = (m_low * p) * w.x + (m_high * p) * w.y + p * w.z
	for j in _mc.size():
		deformed[_mc[j]] = moved[_mu[j]]
	if not _direct and _cur_n.is_empty():
		_cur_n = normals.duplicate()
	for f in _move_faces:
		var a := deformed[f * 3]
		var n := (deformed[f * 3 + 2] - a).cross(deformed[f * 3 + 1] - a)
		n = n.normalized() if n.length_squared() > 1e-14 else normals[f * 3]
		if _direct:
			var o := n.octahedron_encode()
			var packed := clampi(int(o.x * 65535.0), 0, 65535) | (clampi(int(o.y * 65535.0), 0, 65535) << 16)
			_nt[f * 6] = packed
			_nt[f * 6 + 2] = packed
			_nt[f * 6 + 4] = packed
		else:
			_cur_n[f * 3] = n
			_cur_n[f * 3 + 1] = n
			_cur_n[f * 3 + 2] = n
	_write()
	updates += 1
	last_usec = Time.get_ticks_usec() - t0
	return true


func _write() -> void:
	var m := mesh as ArrayMesh
	if _direct:
		var bytes := deformed.to_byte_array()
		bytes.append_array(_nt.to_byte_array())
		m.surface_update_vertex_region(0, 0, bytes)
		return
	var mat := m.surface_get_material(0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = deformed
	arrays[Mesh.ARRAY_NORMAL] = _cur_n
	arrays[Mesh.ARRAY_COLOR] = colors
	m.clear_surfaces()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	m.surface_set_material(0, mat)
	m.surface_set_name(0, "matte")


## Each joint's rest-to-pose transform in the head root's space (rest = a pure translation to its pivot).
func _rest_to_pose() -> Array:
	var out := []
	var acc := Transform3D.IDENTITY
	for j in JOINTS.size():
		var n := _face.piece(JOINTS[j])
		if n == null:
			return []
		acc = acc * n.transform
		out.append(acc * Transform3D(Basis.IDENTITY, -_pivots[j]))
	return out


## The corners as they are now, in the head root's space (the mesh's space carried by the Skull joint).
func head_space() -> PackedVector3Array:
	var d := _rest_to_pose()
	var out := PackedVector3Array()
	if d.size() < 3:
		return out
	var xf: Transform3D = d[2]
	out.resize(deformed.size())
	for i in deformed.size():
		out[i] = xf * deformed[i]
	return out


## The rest box of the faces carried by the Skull alone (the skull and its extras), head-rest space.
func skull_box() -> AABB:
	var box := AABB()
	var first := true
	for i in rest.size():
		if weights[i].z < 1.0 - 1e-6:
			continue
		if first:
			box = AABB(rest[i], Vector3.ZERO)
			first = false
		else:
			box = box.expand(rest[i])
	return box


## The colours of the faces carried by the Skull alone (one per corner, like the mesh's colour array).
func skull_colours() -> PackedColorArray:
	var out := PackedColorArray()
	for f in rest.size() / 3:
		if weights[f * 3].z >= 1.0 - 1e-6 and weights[f * 3 + 1].z >= 1.0 - 1e-6 and weights[f * 3 + 2].z >= 1.0 - 1e-6:
			out.append_array([colors[f * 3], colors[f * 3 + 1], colors[f * 3 + 2]])
	return out
