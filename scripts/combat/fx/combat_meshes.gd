class_name CombatMeshes
extends RefCounted
## Low-poly meshes for combat visuals (weapons.md §1.4, §4): faceted, flat-shaded, palette colours (MechMeshes), built
## with MeshKit and cached per shape + colour. `glow` = unshaded (flashes, beams, rings); otherwise lit, so the facets
## read. Unit sizes: scale the MeshInstance3D.

static var _cache: Dictionary = {}


## Every mesh built so far (the live cache, by key): ShaderWarmup takes them all.
static func cached_meshes() -> Dictionary:
	return _cache

const RED := Color(0.92, 0.12, 0.08)
## Fire colours are LowPolyFlame's (OUTER / MID / CORE): the game has one flame palette (ImpactFx.FLAME_RAMP).


## The cached mesh under `key`, built once by `build(k: MeshKit)` (lit / glow per the kit) with the shared materials.
static func mesh(key: String, build: Callable) -> ArrayMesh:
	if not _cache.has(key):
		var k := MeshKit.new()
		build.call(k)
		_cache[key] = k.commit(LowPolyMaterials.materials())
	return _cache[key]


static func instance(m: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Colour -> the ico mesh already made for it (lit / glow): a fast path that skips building the string key, since smoke
## puffs ask for theirs every frame. Same meshes as `_cache`.
static var _ico_lit: Dictionary = {}
static var _ico_glow: Dictionary = {}


## A 20-face ball of radius 1.
static func ico(c: Color, glow: bool = false) -> ArrayMesh:
	var by_color: Dictionary = _ico_glow if glow else _ico_lit
	var m: ArrayMesh = by_color.get(c)
	if m == null:
		m = mesh("ico|%s|%s" % [c.to_html(), glow], func(k: MeshKit) -> void:
			k.glow = glow
			k.ico(Vector3.ZERO, Vector3.ONE, c))
		by_color[c] = m
	return m


## A shell: an octahedron 1 m long along -Z (nose at -0.5), `width` wide. `glow`: unshaded (a tracer round that lights
## itself), the facets kept apart by a flat shade per face.
static func shell(c: Color, width: float = 0.38, glow: bool = false) -> ArrayMesh:
	return mesh("shell|%s|%.2f|%s" % [c.to_html(), width, glow], func(k: MeshKit) -> void:
		k.glow = glow
		var w := width * 0.5
		var nose := Vector3(0, 0, -0.5)
		var tail := Vector3(0, 0, 0.5)
		var mid := [Vector3(w, 0, -0.1), Vector3(0, w, -0.1), Vector3(-w, 0, -0.1), Vector3(0, -w, -0.1)]
		for i in 4:
			var a: Vector3 = mid[i]
			var b: Vector3 = mid[(i + 1) % 4]
			k.tri(nose, a, b, c, Vector3(0, 0, -0.1))
			k.tri(tail, a, b, c.darkened(0.15), Vector3(0, 0, -0.1)))


## Colour -> the shard mesh already made for it: impacts ask for theirs per impact (same meshes as `_cache`).
static var _shard_by: Dictionary = {}


## A shard: a tetrahedron about 1 m across.
static func shard(c: Color) -> ArrayMesh:
	var m: ArrayMesh = _shard_by.get(c)
	if m == null:
		m = mesh("shard|%s" % c.to_html(), func(k: MeshKit) -> void:
			var p := [Vector3(0, 0.6, 0), Vector3(0.5, -0.3, 0.3), Vector3(-0.5, -0.3, 0.3), Vector3(0, -0.3, -0.55)]
			for f: Array in [[0, 1, 2], [0, 2, 3], [0, 3, 1], [1, 3, 2]]:
				k.tri(p[f[0]], p[f[1]], p[f[2]], c, Vector3.ZERO))
		_shard_by[c] = m
	return m


## A flat ring in XZ (facing +Y), outer radius 1, inner `inner`.
static func ring(c: Color, inner: float = 0.8, sides: int = 16) -> ArrayMesh:
	return mesh("ring|%s|%.2f|%d" % [c.to_html(), inner, sides], func(k: MeshKit) -> void:
		k.glow = true
		var o := MeshKit.ring(Vector3.ZERO, 1.0, 1.0, sides, "y")
		var i := MeshKit.ring(Vector3.ZERO, inner, inner, sides, "y")
		for n in sides:
			var n2 := (n + 1) % sides
			k.quad(i[n], o[n], o[n2], i[n2], c, Vector3(0, -1, 0)))


## A flat irregular polygon in XZ (facing +Y), radius about 1: a scorch mark.
static func scorch(c: Color, variant: int = 0) -> ArrayMesh:
	return mesh("scorch|%s|%d" % [c.to_html(), variant], func(k: MeshKit) -> void:
		k.shade = 0.0
		var pts := PackedVector3Array()
		for n in 9:
			var a := TAU * float(n) / 9.0
			var r := 0.75 + 0.25 * absf(sin(float(n * 7 + variant * 3) * 1.7))
			pts.append(Vector3(sin(a) * r, 0, cos(a) * r))
		for n in 9:
			k.tri(Vector3.ZERO, pts[n], pts[(n + 1) % 9], c, Vector3(0, -1, 0)))


## A slightly raised glowing ember polygon in XZ (facing +Y), radius ~1: outer flame orange + raised inner amber core.
static func ember_scorch(variant: int = 0) -> ArrayMesh:
	var key := "ember_scorch|%d" % variant
	if not _cache.has(key):
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.0
		var outer_pts := PackedVector3Array()
		for n in 7:
			var a := TAU * float(n) / 7.0 + float(variant) * 0.41
			var r := 0.72 + 0.28 * absf(sin(float(n * 5 + variant * 3) * 1.9))
			outer_pts.append(Vector3(sin(a) * r, 0.0, cos(a) * r))
		for n in 7:
			k.tri(Vector3.ZERO, outer_pts[n], outer_pts[(n + 1) % 7], LowPolyFlame.OUTER, Vector3(0, -1, 0))
		var inner_pts := PackedVector3Array()
		for n in 5:
			var a := TAU * float(n) / 5.0 + float(variant) * 0.73 + 0.3
			var r := 0.38 + 0.16 * absf(cos(float(n * 3 + variant * 5) * 1.6))
			inner_pts.append(Vector3(sin(a) * r, 0.025, cos(a) * r))
		var mid_c := Vector3(0.0, 0.025, 0.0)
		for n in 5:
			k.tri(mid_c, inner_pts[n], inner_pts[(n + 1) % 5], LowPolyFlame.MID, Vector3(0, -1, 0))
		_cache[key] = k.commit([LowPolyFlame.material(), LowPolyFlame.material()])
	return _cache[key]


## A 3-sided prism 1 m long along -Z, radius 1 (scale x/y for width): the designator beam.
static func prism3(c: Color) -> ArrayMesh:
	return mesh("prism3|%s" % c.to_html(), func(k: MeshKit) -> void:
		k.glow = true
		k.seg(Vector3.ZERO, Vector3(0, 0, -1), Vector2.ONE, Vector2.ONE, 3, c))


## An unshaded vertex-colour material for ribbons built each frame (trails).
static func ribbon_material() -> StandardMaterial3D:
	if not _cache.has("ribbon_mat"):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_cache["ribbon_mat"] = m
	return _cache["ribbon_mat"]
