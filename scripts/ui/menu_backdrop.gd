class_name MenuBackdrop
extends Node3D
## The main menu's backdrop (concept: docs/design/menu-bg/5_hull_window_s22.png): a quiet observation hall inside the
## hull. The mech stands on a low plinth in front of a huge octagonal hull window; outside, black space full of stars
## and the enormous rim, spokes and hub of the ring habitat, turning slowly. Cold blue starlight comes in through the
## window (a rim on the mech, a pool on the floor), a soft warm key light falls on the mech; dark faceted walls.
## Cosmetic only (no gameplay state, no network): its own clock, stars from a seeded generator. Flat-colour low-poly
## like the rest of the game, merged into a few meshes (hall, ring, stars: three draw calls plus the lights).
## Used by MechStage in turntable mode (main menu, settings; hidden in the hangar bay) and as the lab subject `menu_bg`.
##
## Axes: the mech stands at the origin facing -Z, the menu camera is on -Z; the window wall is at +Z (`wall_z`), the
## ring far beyond it. The ring lives on its own render layer, lit by its own star light (so it reads from the camera
## side, which the window light does not reach).

const WALL_DARK := Color(0.12, 0.125, 0.14)
const WALL_MID := Color(0.155, 0.16, 0.175)
const STEEL := Color(0.3, 0.32, 0.36)
const STEEL_LIGHT := Color(0.5, 0.53, 0.58)
const FLOOR := Color(0.24, 0.25, 0.27)
const PLINTH := Color(0.19, 0.2, 0.22)
const PLINTH_RIM := Color(0.9, 0.48, 0.12)
const RING_LIGHT := Color(0.6, 0.63, 0.7)
const RING_MID := Color(0.42, 0.45, 0.51)
const RING_DARK := Color(0.25, 0.27, 0.31)
const BG := Color(0.006, 0.008, 0.016)
const AMBIENT := Color(0.32, 0.38, 0.5)
const AMBIENT_ENERGY := 0.35
const RING_LAYER := 1 << 19             ## render layer 20: the ring and its star light only

## The hall.
const HALL_HALF := 40.0
const HALL_BACK := -30.0
const HALL_TOP := 30.0
const WINDOW_C := Vector2(-1.5, 6.6)    ## the window's centre (x, y) on the wall
const WINDOW_APOTHEM := 6.0             ## centre to the flat sill (sill at y 0.6 at scale 1)
const WINDOW_STRETCH := 1.25            ## horizontal stretch of the octagon
const REVEAL := 1.4                     ## depth of the window's bevelled reveal
const FRAME := 1.8                      ## width of the reveal around the opening
## The ring habitat, far outside.
const RING_POS := Vector3(-15.0, -22.0, 230.0)
const RING_TILT := Vector3(-0.12, 0.42, 0.0)
const RING_R := 58.0
const RIM_SEGMENTS := 64
const SPOKES := 6
const HUB_R := 10.0
const STARS := [700, 1200, 1800]        ## by quality level (LOW, MEDIUM, HIGH)
const STAR_SEED := 22

var time_scale := 1.0
var own_environment := true             ## the lab: its own environment and a mech; MechStage sets false (it has both)

var ring_spin := 0.025                  ## rad/s about the ring's axis
var wall_z := 5.0                       ## the window wall, behind the mech
var window_scale := 1.0
var key_energy := 5.0
var window_energy := 0.8
var glow_energy := 1.1
var star_light_energy := 1.2
var star_count := -1                    ## -1: by graphics quality

var _t := 0.0
var _hall: MeshInstance3D
var _ring: Node3D
var _spin: Node3D
var _stars: MeshInstance3D
var _key: SpotLight3D
var _window_light: DirectionalLight3D
var _glow: OmniLight3D
var _star_light: DirectionalLight3D
var _quality := CityQuality.HIGH


func _ready() -> void:
	add_to_group(GraphicsQuality.GROUP)
	_quality = GraphicsQuality.level()
	if own_environment:
		var we := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = BG
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = AMBIENT
		e.ambient_light_energy = AMBIENT_ENERGY
		e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		we.environment = e
		add_child(we)
		var m := MechModel.new()
		m.name = "LabMech"
		m.configure("chicken", "strider", {})
		add_child(m)
	_hall = MeshInstance3D.new()
	_hall.name = "Hall"
	_hall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hall)
	_ring = Node3D.new()
	_ring.name = "Ring"
	_ring.position = RING_POS
	_ring.rotation = RING_TILT
	add_child(_ring)
	_spin = MeshInstance3D.new()
	_spin.name = "Spin"
	(_spin as MeshInstance3D).mesh = _ring_mesh()
	(_spin as MeshInstance3D).material_override = _vc_mat(0.85)
	(_spin as MeshInstance3D).layers = RING_LAYER
	(_spin as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.add_child(_spin)
	_stars = MeshInstance3D.new()
	_stars.name = "Stars"
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.vertex_color_use_as_albedo = true
	sm.vertex_color_is_srgb = true
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stars.material_override = sm
	add_child(_stars)

	_key = SpotLight3D.new()
	_key.name = "Key"
	_key.light_color = Color(1.0, 0.68, 0.42)
	_key.spot_range = 26.0
	_key.spot_angle = 28.0
	_key.spot_attenuation = 0.6
	_key.position = Vector3(6.0, 8.5, -8.0)
	_key.transform = Transform3D(Basis.looking_at(Vector3(0, 2.0, 0) - _key.position, Vector3.UP), _key.position)
	add_child(_key)
	_window_light = DirectionalLight3D.new()
	_window_light.name = "WindowLight"
	_window_light.light_color = Color(0.55, 0.7, 1.0)
	_window_light.transform = Transform3D(Basis.looking_at(Vector3(0.1, -0.22, -0.97), Vector3.UP), Vector3.ZERO)
	add_child(_window_light)
	_glow = OmniLight3D.new()
	_glow.name = "WindowGlow"
	_glow.light_color = Color(0.5, 0.66, 1.0)
	_glow.omni_range = 13.0
	_glow.omni_attenuation = 1.4
	add_child(_glow)
	_star_light = DirectionalLight3D.new()
	_star_light.name = "StarLight"
	_star_light.light_color = Color(0.82, 0.88, 1.0)
	_star_light.light_cull_mask = RING_LAYER
	_star_light.transform = Transform3D(Basis.looking_at(Vector3(0.5, -0.3, 0.8), Vector3.UP), Vector3.ZERO)
	add_child(_star_light)
	_rebuild_hall()
	_rebuild_stars()
	_apply_lights()


func _process(delta: float) -> void:
	_t += delta * time_scale
	_spin.rotation.z = fmod(_t * ring_spin, TAU)


## GraphicsQuality.notify: fewer stars and no key-light shadow at LOW.
func _on_graphics_quality(level: int) -> void:
	_quality = CityQuality.clamp_level(level)
	_rebuild_stars()
	_apply_lights()


func _apply_lights() -> void:
	_key.light_energy = key_energy
	_key.shadow_enabled = _quality > CityQuality.LOW
	_window_light.light_energy = window_energy
	_glow.light_energy = glow_energy
	_glow.position = Vector3(WINDOW_C.x * window_scale, 2.2, wall_z - 1.2)
	_star_light.light_energy = star_light_energy


func _rebuild_hall() -> void:
	_hall.mesh = _hall_mesh()
	_hall.set_surface_override_material(0, _vc_mat(0.85))
	# The floor is its own surface: smoother, it catches the window light.
	var fm := _vc_mat(0.45)
	fm.metallic_specular = 0.6
	_hall.set_surface_override_material(1, fm)


func _rebuild_stars() -> void:
	var n := star_count if star_count >= 0 else int(STARS[_quality])
	_stars.mesh = _star_mesh(n)


# --- Meshes -----------------------------------------------------------------------------------------------------------

func _vc_mat(rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = rough
	return m


## The octagonal window outline at apothem `a` (scaled by window_scale), stretched sideways; flat sill and top.
func _octagon(a: float, z: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var rc := a * window_scale / cos(PI / 8.0)
	var c := WINDOW_C * Vector2(window_scale, 1.0)
	c.y = 0.6 + WINDOW_APOTHEM * window_scale
	for k in 8:
		var th := PI / 8.0 + PI / 4.0 * float(k)
		out.append(Vector3(c.x + WINDOW_STRETCH * rc * cos(th), c.y + rc * sin(th), z))
	return out


func _hall_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED + 1
	# The room around the window: side walls, ceiling, back wall (inward faces).
	_quad(st, Vector3(-HALL_HALF, 0, HALL_BACK), Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3(-HALL_HALF, HALL_TOP, wall_z),
		Vector3(-HALL_HALF, 0, wall_z), Vector3.RIGHT, WALL_DARK)
	_quad(st, Vector3(HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, wall_z),
		Vector3(HALL_HALF, 0, wall_z), Vector3.LEFT, WALL_DARK)
	_quad(st, Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, wall_z),
		Vector3(-HALL_HALF, HALL_TOP, wall_z), Vector3.DOWN, WALL_DARK)
	_quad(st, Vector3(-HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK),
		Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3.BACK, WALL_DARK)
	# The window wall: a bevelled reveal (outer outline on the wall, inner one REVEAL deeper), then eight wall facets
	# from the outline out to the room's edges, each leaning a little into the hall.
	var inner := _octagon(WINDOW_APOTHEM, wall_z + REVEAL)
	var outer := _octagon(WINDOW_APOTHEM + FRAME, wall_z)
	var far := _octagon(WINDOW_APOTHEM * 6.0, wall_z - 1.2)
	for k in 8:
		var j := (k + 1) % 8
		var mid := (inner[k] + inner[j]) * 0.5
		var c := Vector3(inner[0].x + inner[3].x, inner[1].y + inner[6].y, 0.0) * 0.5
		var out_dir := Vector3(mid.x - c.x, mid.y - c.y, 0.0).normalized()
		var tone := STEEL if k % 2 == 0 else STEEL.darkened(0.12)
		_quad(st, inner[k], inner[j], outer[j], outer[k], (-out_dir + Vector3.FORWARD).normalized(), tone)
		_quad(st, outer[k], outer[j], far[j], far[k], Vector3.FORWARD, WALL_MID if k % 2 == 0 else WALL_DARK)
		# The pale trim around the glass.
		var edge := inner[j] - inner[k]
		var b := Basis(edge.normalized(), out_dir, edge.normalized().cross(out_dir))
		_box(st, Transform3D(b, mid + out_dir * 0.15), Vector3(edge.length() + 0.3, 0.3, 0.5), STEEL_LIGHT)
		# Panel seams on the facet: two raised strips across it.
		for f: float in [0.3, 0.62]:
			var p0 := outer[k].lerp(far[k], f)
			var p1 := outer[j].lerp(far[j], f)
			var se := p1 - p0
			var sn := (far[k] - outer[k]).normalized()
			var sb := Basis(se.normalized(), sn, se.normalized().cross(sn))
			_box(st, Transform3D(sb, (p0 + p1) * 0.5 + Vector3(0, 0, -0.1)), Vector3(se.length(), 0.35, 0.3), WALL_DARK.darkened(0.25))
	# A low step along the sill.
	var sill_w := inner[2].x - inner[1].x
	_box(st, Transform3D(Basis(), Vector3((inner[1].x + inner[2].x) * 0.5, 0.25, wall_z - 0.5)), Vector3(sill_w + 2.0 * FRAME + 6.0, 0.5, 1.0), WALL_MID)
	# The plinth: a low disc with an orange edge (the turntable).
	_prism(st, Transform3D(Basis(), Vector3(0, 0.03, 0)), 2.9, 0.06, 40, PLINTH_RIM)
	_prism(st, Transform3D(Basis(), Vector3(0, 0.045, 0)), 2.8, 0.09, 40, PLINTH)
	# Surface 1: the floor, faceted triangles in slightly different greys.
	var mesh := st.commit()
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cell := 3.0
	var nx := int(HALL_HALF * 2.0 / cell)
	var nz := int(ceilf((wall_z - HALL_BACK) / cell))
	for i in nx:
		for k in nz:
			var x0 := -HALL_HALF + float(i) * cell
			var z0 := HALL_BACK + float(k) * cell
			var z1 := minf(z0 + cell, wall_z)
			var a := Vector3(x0, 0, z0)
			var b2 := Vector3(x0 + cell, 0, z0)
			var c2 := Vector3(x0 + cell, 0, z1)
			var d := Vector3(x0, 0, z1)
			var s1 := rng.randf_range(-0.03, 0.03)
			var s2 := rng.randf_range(-0.03, 0.03)
			if (i + k) % 2 == 0:
				_tri(st, a, b2, c2, Vector3.UP, FLOOR.lightened(s1) if s1 > 0 else FLOOR.darkened(-s1))
				_tri(st, a, c2, d, Vector3.UP, FLOOR.lightened(s2) if s2 > 0 else FLOOR.darkened(-s2))
			else:
				_tri(st, a, b2, d, Vector3.UP, FLOOR.lightened(s1) if s1 > 0 else FLOOR.darkened(-s1))
				_tri(st, b2, c2, d, Vector3.UP, FLOOR.lightened(s2) if s2 > 0 else FLOOR.darkened(-s2))
	return st.commit(mesh)


## The ring habitat in its own frame: the rim in the XY plane, the axis along Z.
func _ring_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arc := TAU * RING_R / float(RIM_SEGMENTS)
	for i in RIM_SEGMENTS:
		var a := TAU * float(i) / float(RIM_SEGMENTS)
		var r := Vector3(cos(a), sin(a), 0.0)
		var t := Vector3(-sin(a), cos(a), 0.0)
		var b := Basis(t, r, Vector3.BACK)
		var tone := RING_MID if (i / 3) % 2 == 0 else RING_DARK.lerp(RING_MID, 0.5)
		_box(st, Transform3D(b, r * RING_R), Vector3(arc + 0.3, 5.0, 14.0), tone)
		if i % 2 == 0:
			_box(st, Transform3D(b, r * (RING_R + 4.0)), Vector3(arc * 0.62, 3.0, 9.0), RING_LIGHT)
		if i % 4 == 1:
			_box(st, Transform3D(b, r * (RING_R - 3.4)), Vector3(arc * 0.75, 1.8, 17.0), RING_DARK)
		if i % 8 == 5:
			_box(st, Transform3D(b, r * (RING_R + 1.0) + Vector3.BACK * 8.5), Vector3(arc * 1.4, 4.0, 3.0), RING_LIGHT.darkened(0.1))
	for k in SPOKES:
		var a := TAU * float(k) / float(SPOKES) + 0.2
		var r := Vector3(cos(a), sin(a), 0.0)
		var t := Vector3(-sin(a), cos(a), 0.0)
		var b := Basis(r, t, Vector3.BACK)
		var len := RING_R - 3.0 - HUB_R
		_box(st, Transform3D(b, r * (HUB_R + len * 0.5)), Vector3(len, 3.2, 3.2), RING_MID)
		_box(st, Transform3D(b, r * (HUB_R + len * 0.5) + Vector3.BACK * 2.6), Vector3(len, 1.0, 1.0), RING_DARK)
		var d := HUB_R + 10.0
		while d < RING_R - 8.0:
			_box(st, Transform3D(b, r * d), Vector3(1.6, 4.6, 4.6), RING_LIGHT.darkened(0.15))
			d += 15.0
	var axis := Basis(Vector3.RIGHT, PI / 2.0)    # prisms run along local Y: turn them onto the ring's axis (Z)
	_prism(st, Transform3D(axis, Vector3.ZERO), HUB_R + 4.0, 3.0, 16, RING_LIGHT.darkened(0.08))
	_prism(st, Transform3D(axis, Vector3.ZERO), HUB_R, 11.0, 16, RING_MID)
	_prism(st, Transform3D(axis, Vector3.ZERO), HUB_R * 0.55, 15.0, 16, RING_DARK)
	_prism(st, Transform3D(axis, Vector3.ZERO), HUB_R * 0.3, 18.0, 12, RING_LIGHT)
	return st.commit()


## Stars: small quads on a far shell, facing the centre, mostly on the window's side (+Z). One mesh, unshaded.
func _star_mesh(n: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if n <= 0:
		return mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED
	const SHELL := 600.0
	for i in n:
		# Most of them in a cone around +Z (what the window shows), the rest anywhere (the lab looks around).
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if d.length_squared() < 0.01:
			d = Vector3.BACK
		d = d.normalized()
		if rng.randf() < 0.8:
			d = (Vector3.BACK + Vector3(d.x, d.y, 0.0) * 0.9).normalized()
		var p := d * SHELL
		var u := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
		var v := d.cross(u)
		var big := pow(rng.randf(), 4.0)
		var s := lerpf(0.5, 1.7, big)
		var bright := lerpf(0.35, 1.0, maxf(big, rng.randf() * 0.7))
		var tint := [Color(0.75, 0.85, 1.0), Color(1, 1, 1), Color(1.0, 0.9, 0.75)][rng.randi_range(0, 2)] as Color
		var c := Color(tint.r * bright, tint.g * bright, tint.b * bright)
		st.set_color(c)
		st.add_vertex(p - u * s - v * s)
		st.add_vertex(p + u * s - v * s)
		st.add_vertex(p + u * s + v * s)
		st.add_vertex(p - u * s - v * s)
		st.add_vertex(p + u * s + v * s)
		st.add_vertex(p - u * s + v * s)
	return st.commit(mesh)


## One flat triangle facing `n` (Godot's front faces wind clockwise: the order is fixed up to face n).
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	var fn := (b - a).cross(c - a)
	if fn.dot(n) > 0.0:
		var tmp := b
		b = c
		c = tmp
		fn = -fn
	st.set_color(col)
	st.set_normal(-fn.normalized())
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	_tri(st, a, b, c, n, col)
	_tri(st, a, c, d, n, col)


func _box(st: SurfaceTool, xf: Transform3D, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	for axis in 3:
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = 1.0
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = 1.0
			var c := n * h[axis]
			var hu := u * h[(axis + 1) % 3]
			var hv := v * h[(axis + 2) % 3]
			var wn := (xf.basis * n).normalized()
			_quad(st, xf * (c + hu + hv), xf * (c + hu - hv), xf * (c - hu - hv), xf * (c - hu + hv), wn, col)


## A closed prism along local Y (radius r, length len, `sides` facets), centred on xf.
func _prism(st: SurfaceTool, xf: Transform3D, r: float, len: float, sides: int, col: Color) -> void:
	var top := Vector3(0, len * 0.5, 0)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * r, 0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0, sin(a1) * r)
		var am := (a0 + a1) * 0.5
		var sn := (xf.basis * Vector3(cos(am), 0, sin(am))).normalized()
		_quad(st, xf * (p0 - top), xf * (p1 - top), xf * (p1 + top), xf * (p0 + top), sn, col)
		_tri(st, xf * top, xf * (p0 + top), xf * (p1 + top), (xf.basis * Vector3.UP).normalized(), col)
		_tri(st, xf * -top, xf * (p0 - top), xf * (p1 - top), (xf.basis * Vector3.DOWN).normalized(), col.darkened(0.2))


# --- Lab ----------------------------------------------------------------------------------------------------------------

func lab_params() -> Array:
	return [
		{"id": "ring_spin", "label": "Ring spin (rad/s)", "min": 0.0, "max": 0.3, "value": ring_spin},
		{"id": "window_scale", "label": "Window size (x)", "min": 0.7, "max": 1.3, "value": window_scale},
		{"id": "wall_z", "label": "Window wall distance (m)", "min": 3.5, "max": 12.0, "value": wall_z},
		{"id": "key", "label": "Key light (warm)", "min": 0.0, "max": 12.0, "value": key_energy},
		{"id": "window", "label": "Window light (blue)", "min": 0.0, "max": 3.0, "value": window_energy},
		{"id": "glow", "label": "Window glow on the floor", "min": 0.0, "max": 6.0, "value": glow_energy},
		{"id": "star_light", "label": "Star light on the ring", "min": 0.0, "max": 3.0, "value": star_light_energy},
		{"id": "stars", "label": "Stars (-1: by quality)", "min": -1.0, "max": 4000.0, "value": float(star_count)},
	]


func set_lab_param(id: String, value: float) -> void:
	match id:
		"ring_spin": ring_spin = value
		"window_scale":
			window_scale = value
			_rebuild_hall()
		"wall_z":
			wall_z = value
			_rebuild_hall()
		"key": key_energy = value
		"window": window_energy = value
		"glow": glow_energy = value
		"star_light": star_light_energy = value
		"stars":
			star_count = int(value)
			_rebuild_stars()
	_apply_lights()


func lab_options() -> Array:
	return []


func set_lab_option(_id: String, _value: String) -> void:
	pass


func lab_focus() -> Vector3:
	return Vector3(0, 2.4, 0)


func lab_radius() -> float:
	return 5.5


func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true
