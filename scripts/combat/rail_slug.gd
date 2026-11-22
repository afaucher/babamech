class_name RailSlug
extends Projectile
## The Coil Railgun's slug (weapons.md §3.8): a straight Projectile (a scheduled effect: everything follows from the fire
## record + stats + the shared clock) that PIERCES. Each target it meets takes damage × (1 - pierce_loss)^n (n = targets
## already pierced: 200 -> 150 -> 112.5), Δv stats.knockback along the flight, an entry burst and, when the slug goes on
## through, an exit burst on the far side. A target is hit at most once (Projectile.pierced); the slug stops in the
## stats.pierce-th target, and at any world geometry or city prop.
##
## LOOK (cosmetic, a pure function of flight time): a long teal faceted spike; a wide faceted twisted ribbon trail (a
## flat band whose width turns about the flight line, TWIST_PITCH m a turn in TWIST_FACETS hard facets, so it reads as
## a zig-zag helix, with a narrower pale band at 90°) anchored to distance flown, so it hangs where the slug passed.
## Every piece of it narrows with age and is gone stats.trail (1.5 s) after the slug passed it; the node is freed by
## the world once the last piece is gone. The ribbon is built once per slug and aged on the GPU (RIBBON_SHADER). A big teal muzzle star for MUZZLE_LIFE s in three hard steps.

const FLASH_COLOR := Color(0.55, 0.95, 0.92)   ## impact flash ball: teal, a touch pale (the laser's)
const CORE_COLOR := Color(0.78, 1.0, 0.96)     ## the pale inner band / spike core
const TWIST_PITCH := 6.0          ## m of flight per full turn of the ribbon
const TWIST_FACETS := 8           ## flat facets per turn (the zig-zag)
const RIBBON_HALF := 0.55         ## m: the ribbon's half-width at launch size (× the drawn growth)
const CORE_SHARE := 0.45          ## the pale band's width as a share of the main band's
const EXIT_SHARE := 0.6           ## an exit burst's radius as a share of impact_radius
const MUZZLE_LIFE := 0.1          ## s
const MUZZLE_LEN := 4.5           ## m: the muzzle star's length at its first step

static var _spike_mesh: ArrayMesh
static var _star_mesh: ArrayMesh
static var _ribbon_shader: Shader

var _muzzle: MeshInstance3D
var _ribbon_mat: ShaderMaterial     ## this slug's ribbon material (its uniforms age the ribbon; see RIBBON_SHADER)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"_muzzle": Net.LOCAL, "_ribbon_mat": Net.LOCAL})
	return f


## A target's damage share after `n` pierces.
static func pierce_factor(st: Dictionary, n: int) -> float:
	return pow(1.0 - float(st.get("pierce_loss", 0.0)), float(n))


func on_hit(h: Dictionary, e: float) -> bool:
	var fdir := flight_dir(e)
	var target: CombatTarget = h["target"]
	var r := float(stats.get("impact_radius", 1.0))
	if target == null:      # world geometry or a city prop: the slug stops here
		world.hit_prop(record, stats, h, fdir)
		world.spawn_impact(h["point"], h["normal"], r, h.get("color", MechMeshes.GREY), false, FLASH_COLOR)
		return true
	var n := pierced.size()
	pierced.append(target.target_id)
	world.resolve_hit(record, stats, target, str(h["component"]), h["point"], h["normal"], fdir,
		float(stats.get("damage", 0.0)) * Combat.falloff(stats, flight_dist(e)) * pierce_factor(stats, n))
	world.spawn_impact(h["point"], h["normal"], r, MechMeshes.ORANGE, false, FLASH_COLOR)
	if n + 1 >= maxi(int(stats.get("pierce", 1)), 1):
		return true
	world.spawn_impact(_exit_point(target, h["point"], fdir), fdir, r * EXIT_SHARE, MechMeshes.ORANGE, false, FLASH_COLOR)
	return false


## Where the flight line leaves the hit sphere it entered at `p` (the exit burst).
func _exit_point(target: CombatTarget, p: Vector3, fdir: Vector3) -> Vector3:
	var best := INF
	var through := 0.6
	for s: Dictionary in target.world_spheres():
		var c: Vector3 = s["center"]
		var gap := absf(p.distance_to(c) - (float(s["radius"]) + Combat.PROJECTILE_RADIUS))
		if gap < best:
			best = gap
			through = maxf(2.0 * (c - p).dot(fdir), 0.6)
	return p + fdir * through


# --- Look ---------------------------------------------------------------------------------------------

## The spike: nose at the origin, 3.2 m long back along +Z (so it never pokes past what it hit), hexagonal facets.
static func spike_mesh() -> ArrayMesh:
	if _spike_mesh == null:
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.1
		k.seg(Vector3(0, 0, 0.6), Vector3(0, 0, 0.0), Vector2(0.17, 0.17), Vector2(0.01, 0.01), 6, MechMeshes.TEAL)
		k.seg(Vector3(0, 0, 3.2), Vector3(0, 0, 0.6), Vector2(0.01, 0.01), Vector2(0.17, 0.17), 6, MechMeshes.TEAL)
		k.seg(Vector3(0, 0, 1.6), Vector3(0, 0, -0.15), Vector2(0.04, 0.04), Vector2(0.09, 0.09), 3, CORE_COLOR)
		_spike_mesh = k.commit(MechMeshes.materials())
	return _spike_mesh


## The muzzle star: 1 m long along -Z, a teal cone round a pale core with four teal petals.
static func star_mesh() -> ArrayMesh:
	if _star_mesh == null:
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.08
		k.seg(Vector3.ZERO, Vector3(0, 0, -1.0), Vector2(0.3, 0.3), Vector2(0.02, 0.02), 6, MechMeshes.TEAL)
		k.seg(Vector3(0, 0, 0.05), Vector3(0, 0, -0.65), Vector2(0.18, 0.18), Vector2(0.01, 0.01), 6, CORE_COLOR)
		for i in 4:
			var a := TAU * float(i) / 4.0 + PI * 0.25
			var out := Vector3(cos(a), sin(a), -0.25).normalized() * 0.5
			k.seg(Vector3(0, 0, -0.05), Vector3(0, 0, -0.05) + out, Vector2(0.08, 0.08), Vector2(0.01, 0.01), 4, MechMeshes.TEAL)
		_star_mesh = k.commit(MechMeshes.materials())
	return _star_mesh


func _build_look() -> void:
	super._build_look()
	_build_ribbon()
	_shell.mesh = spike_mesh()
	_muzzle = CombatMeshes.instance(star_mesh())
	_muzzle.top_level = true
	_muzzle.visible = false
	add_child(_muzzle)


func _update_look() -> void:
	super._update_look()
	if _muzzle == null or not is_inside_tree():
		return
	var step := int(elapsed / (MUZZLE_LIFE / 3.0)) if elapsed < MUZZLE_LIFE else -1
	_muzzle.visible = step >= 0
	if step >= 0:
		var k: float = [1.0, 0.75, 0.5][mini(step, 2)]
		var roll := Basis(Vector3.BACK, deg_to_rad(30.0 * float(step)))
		_muzzle.global_transform = Transform3D(Combat.look_basis(dir) * roll * Basis.from_scale(Vector3(k * 1.4, k * 1.4, k) * MUZZLE_LEN),
			flight_pos(0.0))


## The twisted ribbon: two flat bands (teal, and a narrower pale one at 90°) on a grid fixed in distance flown. The
## slug flies a straight line fixed in space, so the whole ribbon (launch to range) is built ONCE into an ArrayMesh:
## each vertex holds its point on the flight line, its full half-width vector and its flight time (CUSTOM0). The
## RIBBON_SHADER narrows every vertex by its own age and folds the part past the slug's head onto the head, from three
## uniforms set each frame (elapsed, head, head_pos), so nothing is rebuilt while it flies or fades.
const RIBBON_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float elapsed = 0.0;
uniform float life = 1.0;
uniform float head = 0.0;
uniform vec3 head_pos = vec3(0.0);
void vertex() {
	float e = CUSTOM0.w;
	float k = 1.0 - clamp((elapsed - e) / max(life, 0.0001), 0.0, 1.0);
	if (e > head) {
		VERTEX = head_pos;
		k = 0.0;
	}
	VERTEX += CUSTOM0.xyz * k;
}
void fragment() {
	vec3 c = COLOR.rgb;
	ALBEDO = mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}
"""

## The ribbon's mesh for this slug's whole flight (see RIBBON_SHADER): 2 bands × one quad per facet step.
func _build_ribbon() -> void:
	if _trail == null:
		return
	if _ribbon_shader == null:
		_ribbon_shader = Shader.new()
		_ribbon_shader.code = RIBBON_SHADER
	_ribbon_mat = ShaderMaterial.new()
	_ribbon_mat.shader = _ribbon_shader
	_ribbon_mat.set_shader_parameter("life", maxf(float(stats.get("trail", 0.0)), 0.0001))
	var step_d := TWIST_PITCH / float(TWIST_FACETS)
	var d1 := speed * max_time
	var ds := PackedFloat32Array([0.0])
	var k := 1
	while float(k) * step_d < d1:
		ds.append(float(k) * step_d)
		k += 1
	ds.append(d1)
	var side0 := dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT).normalized()
	var up0 := side0.cross(dir).normalized()
	var s0 := maxf(float(stats.get("size", 1.0)), 0.001)
	var n := ds.size()
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	for band in 2:
		var col := MechMeshes.TEAL if band == 0 else CORE_COLOR
		var base := verts.size()
		for i in n:
			var e := ds[i] / speed
			var ang := ds[i] / TWIST_PITCH * TAU
			var wv := (side0 * cos(ang) + up0 * sin(ang)) * RIBBON_HALF * (drawn_scale(e) / s0)
			if band == 1:     # the pale band: turned 90° about the flight line, narrower
				wv = dir.cross(wv) * CORE_SHARE
			var p := flight_pos(e)
			for sgn: float in [-1.0, 1.0]:
				verts.append(p)
				cols.append(col)
				custom.append_array([wv.x * sgn, wv.y * sgn, wv.z * sgn, e])
		for i in n - 1:
			var a0 := base + i * 2
			var b0 := a0 + 2
			idx.append_array([a0, b0, b0 + 1, a0, b0 + 1, a0 + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	mesh.surface_set_material(0, _ribbon_mat)
	_trail.mesh = mesh
	var grow := RIBBON_HALF * float(stats.get("growth", 1.0)) + 0.5
	_trail.custom_aabb = mesh.get_aabb().grow(grow)
	_trail.visible = false


## True while some of the ribbon is drawn (between the slug's head and the end of its trail life).
func trail_drawn() -> bool:
	return _trail != null and _trail.visible


## Per frame: three uniforms; the mesh stays as built.
func _draw_trail() -> void:
	if _ribbon_mat == null:
		return
	var life := float(stats.get("trail", 0.0))
	var head := elapsed if end_time < 0.0 else minf(elapsed, end_time)
	var tail := maxf(elapsed - life, 0.0)
	_trail.visible = head - tail >= 0.002 and life > 0.0
	if not _trail.visible:
		return
	_ribbon_mat.set_shader_parameter("elapsed", elapsed)
	_ribbon_mat.set_shader_parameter("head", head)
	_ribbon_mat.set_shader_parameter("head_pos", flight_pos(head))
