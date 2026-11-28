class_name EnemyGlow
extends RefCounted
## The enemy meshes' lit surface (MeshKit "glow": unshaded vertex colours) as ONE shared ShaderMaterial driven per unit
## by instance uniforms (R2.27, docs/design/enemy-ai-structure.md "Overheat look"), so a unit's heat never costs a
## material of its own:
##   vent_heat  -1 (default): the old look, every lit face at its vertex colour. 0..1: the unit's heat as shown: the
##              VENT_GLOW fins go from a dim ember (cool) through their full orange to white-hot (at the cap).
##   lights     0..1: the optics / lamps (every other lit face): 1 lit, 0 dark (shut down).
##   optic_heat 0 | 1: 1 for units whose fins are not their main lit part (troopers): the optics also heat toward
##              white (never dimmer than their colour when cool).
## A face is a fin when its vertex colour is EnemyMeshes.VENT_GLOW. Meshes shown without the uniforms set (debris,
## galleries, a dead unit: EnemyHeatLook.reset) look exactly as before. Cosmetic only (no gameplay state).

const SHADER := """
shader_type spatial;
render_mode unshaded;

instance uniform float vent_heat = -1.0;
instance uniform float lights = 1.0;
instance uniform float optic_heat = 0.0;

const vec3 VENT = vec3(1.0, 0.5412, 0.2275);   // EnemyMeshes.VENT_GLOW (sRGB)
const vec3 WHITE_HOT = vec3(1.0, 0.88, 0.66);

varying vec3 v_col;
varying float v_vent;

void vertex() {
	vec3 c = COLOR.rgb;
	v_vent = 1.0 - smoothstep(0.035, 0.07, distance(c, VENT));
	v_col = mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), vec3(lessThan(c, vec3(0.04045))));
}

void fragment() {
	vec3 c = v_col;
	if (vent_heat >= 0.0) {
		float h = clamp(vent_heat, 0.0, 1.0);
		float white = smoothstep(0.55, 1.0, h);
		vec3 hot = mix(c, WHITE_HOT, white);
		vec3 vent = hot * (mix(0.18, 1.0, smoothstep(0.0, 0.6, h)) + 2.4 * smoothstep(0.55, 1.0, h));
		vec3 optic = mix(c, hot * (1.0 + 1.6 * smoothstep(0.6, 1.0, h)), optic_heat);
		optic *= mix(0.03, 1.0, clamp(lights, 0.0, 1.0));
		c = mix(optic, vent, v_vent);
	}
	ALBEDO = c;
}
"""

static var _mat: ShaderMaterial
static var _mats: Array = []
static var _vent_pts: Dictionary = {}   ## mesh instance id -> Array[Vector3]: centres of its fins (mesh space)


## The shared lit-surface material (one for every enemy mesh).
static func material() -> ShaderMaterial:
	if _mat == null:
		var sh := Shader.new()
		sh.code = SHADER
		_mat = ShaderMaterial.new()
		_mat.shader = sh
	return _mat


## The fins' colour (linear, unshaded, may exceed 1) at heat fraction `h`: the shader's vent branch in GDScript (keep the
## two in step; tests read this one).
static func vent_color(h: float) -> Color:
	h = clampf(h, 0.0, 1.0)
	var c := EnemyMeshes.VENT_GLOW.srgb_to_linear()
	var hot := c.lerp(Color(1.0, 0.88, 0.66), smoothstep(0.55, 1.0, h))
	var e := lerpf(0.18, 1.0, smoothstep(0.0, 0.6, h)) + 2.4 * smoothstep(0.55, 1.0, h)
	return Color(hot.r * e, hot.g * e, hot.b * e)


## LowPolyMaterials.materials() with the lit surface swapped for material(): what EnemyMeshes commits its parts with.
static func materials() -> Array:
	if _mats.is_empty():
		_mats = LowPolyMaterials.materials().duplicate()
		_mats[1] = material()
	return _mats


## True when `mi` shows a mesh whose lit surface is the shared enemy material (it takes the instance uniforms).
static func drives(mi: MeshInstance3D) -> bool:
	var am := mi.mesh as ArrayMesh if mi != null else null
	if am == null:
		return false
	for i in am.get_surface_count():
		if am.surface_get_name(i) == "glow" and am.surface_get_material(i) == material():
			return true
	return false


## The fins of `mesh` (mesh space): one point per cluster of VENT_GLOW faces (clustered on a 1 m grid), cached per mesh.
## Steam puffs start there. Empty when the mesh has no fins.
static func vent_points(mesh: Mesh) -> Array:
	var am := mesh as ArrayMesh
	if am == null:
		return []
	var key := am.get_instance_id()
	if _vent_pts.has(key):
		return _vent_pts[key]
	var cells: Dictionary = {}   ## Vector3i -> [sum, n]
	var vc := EnemyMeshes.VENT_GLOW
	for i in am.get_surface_count():
		if am.surface_get_name(i) != "glow":
			continue
		var arr := am.surface_get_arrays(i)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var cs: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		for j in mini(vs.size(), cs.size()):
			var c := cs[j]
			if absf(c.r - vc.r) + absf(c.g - vc.g) + absf(c.b - vc.b) > 0.06:
				continue
			var cell := Vector3i(floori(vs[j].x), floori(vs[j].y), floori(vs[j].z))
			var e: Array = cells.get(cell, [Vector3.ZERO, 0])
			e[0] = (e[0] as Vector3) + vs[j]
			e[1] = int(e[1]) + 1
			cells[cell] = e
	var out: Array = []
	for e: Array in cells.values():
		out.append((e[0] as Vector3) / float(e[1]))
	_vent_pts[key] = out
	return out
