class_name MenuBackdrop
extends Node3D
## The main menu's backdrop (concept: docs/design/menu-bg/5_hull_window_s22.png): the observation deck of our own
## assault boat, approaching the habitat. The mech stands on a low orange-edged plinth in front of a huge octagonal
## hull window divided by pressure ribs; around it a tactical table with a faint orange holo of the ring, pilot seats,
## benches, lockers, cable runs, hazard stripes, status pedestals with blinking LEDs, dust in the window light.
## Outside, black space full of stars and the whole ring habitat (docs/design/mission-section.md): two deep counter-
## rotating drums lit by rows of deck windows and light strips, spokes with lift tubes and cables (lights riding them),
## a long fixed axial spine (docking collars and ports, a cargo lattice, radiator fins, a power section with nozzles,
## an angled sun mirror), invader wedge ships clamped on (charcoal, dull red), blinking nav lights, shuttles on loops.
## Cosmetic only (no gameplay state, no network): its own clock, every random pattern from a seeded generator.
## Flat-colour low-poly merged into a few meshes (hall, spine, two rings, stars, holo, dust) plus three MultiMeshes for
## the blinking/moving lights and two shuttle nodes. Used by MechStage in turntable mode (main menu, settings; hidden
## in the hangar bay) and as the lab subject `menu_bg`.
##
## Axes: the mech stands at the origin facing -Z, the menu camera is on -Z (screen right is -X); the window wall is at
## +Z (`wall_z`), the habitat far beyond it, placed in the menu camera's view (CAM_POS, HAB_SCREEN). The habitat lives
## on its own render layer, lit by its own star light (so it reads from the camera side, which the window light does
## not reach). Room props stand between the mech and the window or off to the sides: never between camera and mech.

const WALL_DARK := Color(0.12, 0.125, 0.14)
const WALL_MID := Color(0.155, 0.16, 0.175)
const STEEL := Color(0.3, 0.32, 0.36)
const STEEL_LIGHT := Color(0.5, 0.53, 0.58)
const SEAL := Color(0.06, 0.065, 0.07)
const FLOOR := Color(0.24, 0.25, 0.27)
const PLINTH := Color(0.19, 0.2, 0.22)
const PLINTH_RIM := Color(0.9, 0.48, 0.12)
const HAZARD_Y := Color(0.85, 0.66, 0.1)
const HAZARD_K := Color(0.07, 0.07, 0.08)
const SEAT := Color(0.16, 0.15, 0.15)
const LOCKER := Color(0.21, 0.23, 0.25)
const HOLO := Color(1.0, 0.5, 0.15)
const HAB_LIGHT := Color(0.62, 0.65, 0.72)
const HAB_MID := Color(0.43, 0.46, 0.52)
const HAB_DARK := Color(0.26, 0.28, 0.32)
const PANEL := Color(0.66, 0.68, 0.72)
const MIRROR := Color(0.6, 0.66, 0.76)
const INVADER := Color(0.09, 0.09, 0.1)
const INVADER_RED := Color(0.42, 0.08, 0.06)
const WINDOW_WARM := Color(1.0, 0.84, 0.55)
const WINDOW_COOL := Color(0.72, 0.85, 1.0)
const STRIP := Color(0.85, 0.92, 1.0)
const BG := Color(0.006, 0.008, 0.016)
const AMBIENT := Color(0.32, 0.38, 0.5)
const AMBIENT_ENERGY := 0.35
const RING_LAYER := 1 << 19             ## render layer 20: the habitat and its star light only

## The hall.
const HALL_HALF := 40.0
const HALL_BACK := -30.0
const HALL_TOP := 16.0
const WINDOW_C := Vector2(-1.5, 6.6)    ## the window's centre (x, y) on the wall
const WINDOW_APOTHEM := 6.0             ## centre to the flat sill (sill at y 0.6 at scale 1)
const WINDOW_STRETCH := 1.25            ## horizontal stretch of the octagon
const REVEAL := 1.4                     ## depth of the window's bevelled reveal
const FRAME := 1.8                      ## width of the reveal around the opening
## MechStage's turntable camera for one mech (its _place_camera): the habitat is placed in this view.
const CAM_POS := Vector3(2.625, 5.025, -10.5)
const CAM_TARGET := Vector3(0.0, 2.4, 0.0)
## The habitat: distance from the camera, where its centre sits on screen (tangent offsets right / up of the view's
## centre), how far its axis turns away from the line of sight and which way the spine runs on screen.
const HAB_DIST := 580.0
const HAB_SCREEN := Vector2(-0.22, 0.15)
const HAB_AXIS_TILT := deg_to_rad(50.0)
const HAB_AXIS_ROLL := deg_to_rad(200.0)
const RING_R := 66.0                    ## outer radius of the drums
const DRUM_D := 26.0                    ## radial depth of a drum (~40 % of the radius)
const DRUM_W := 20.0                    ## a drum's width along the axis
const RING_Z := 24.0                    ## the drums sit at -RING_Z (A) and +RING_Z (B) along the spine
const RIM_SEGMENTS := 56
const SPOKES := 4
const HUB_R := 9.0
const SPINE_R := 3.5
const SPINE_Z0 := -150.0                ## the power section's end
const SPINE_Z1 := 118.0                 ## the docking end
const WINDOW_ROWS := 5                  ## rows of deck windows on a drum face
const STARS := [700, 1200, 1800]        ## by quality level (LOW, MEDIUM, HIGH)
const DUST := [30, 70, 120]
const STAR_SEED := 22
const STAR_SHELL := 1500.0

var time_scale := 1.0
var own_environment := true             ## the lab: its own environment and a mech; MechStage sets false (it has both)

var ring_spin := 0.025                  ## rad/s about the axis (drum B turns the other way)
var shuttle_speed := 1.0
var wall_z := 5.5                       ## the window wall, behind the mech
var window_scale := 1.0
var key_energy := 5.0
var window_energy := 0.8
var glow_energy := 1.1
var star_light_energy := 1.2
var star_count := -1                    ## -1: by graphics quality

var _t := 0.0
var _quality := CityQuality.HIGH
var _hall: MeshInstance3D
var _holo: MeshInstance3D
var _dust: MeshInstance3D
var _leds: MultiMeshInstance3D
var _led_data: Array = []
var _habitat: Node3D
var _ring_a: MeshInstance3D
var _ring_b: MeshInstance3D
var _lights: Array[MultiMeshInstance3D] = []   ## spine, ring A, ring B
var _light_data: Array = []                    ## per MultiMesh: [{pos, rate, phase, duty, a, b, speed}]
var _shuttles: Array[MeshInstance3D] = []
var _shuttle_paths: Array = []                 ## [{a, c, b, period, offset}]
var _stars: MeshInstance3D
var _key: SpotLight3D
var _window_light: DirectionalLight3D
var _glow: OmniLight3D
var _star_light: DirectionalLight3D
var _mats: Dictionary = {}


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
	_hall = _mesh_node("Hall")
	_holo = _mesh_node("Holo")
	_holo.material_override = _mat("add")
	_dust = _mesh_node("Dust")
	_dust.material_override = _mat("add")
	_leds = _light_node("Leds", 0.07)
	add_child(_leds)
	_stars = _mesh_node("Stars")
	_stars.material_override = _mat("glow")
	_build_habitat()

	_key = SpotLight3D.new()
	_key.name = "Key"
	_key.light_color = Color(1.0, 0.68, 0.42)
	_key.spot_range = 26.0
	_key.spot_angle = 28.0
	_key.spot_attenuation = 0.6
	var kp := Vector3(6.0, 8.5, -8.0)
	_key.transform = Transform3D(Basis.looking_at(Vector3(0, 2.0, 0) - kp, Vector3.UP), kp)
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
	_rebuild_dust()
	_apply_lights()


func _process(delta: float) -> void:
	_t += delta * time_scale
	var spin := fmod(_t * ring_spin, TAU)
	_ring_a.rotation.z = spin
	_ring_b.rotation.z = -spin
	_holo.rotation.y = fmod(_t * 0.25, TAU)
	_dust.position = Vector3(sin(_t * 0.07) * 0.35, sin(_t * 0.05 + 1.0) * 0.25, cos(_t * 0.06) * 0.2)
	for g in _lights.size():
		_update_lights(_lights[g].multimesh, _light_data[g])
	_update_lights(_leds.multimesh, _led_data)
	for i in _shuttles.size():
		_move_shuttle(_shuttles[i], _shuttle_paths[i])


## GraphicsQuality.notify: fewer stars and motes, no key-light shadow at LOW.
func _on_graphics_quality(level: int) -> void:
	_quality = CityQuality.clamp_level(level)
	_rebuild_stars()
	_rebuild_dust()
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
	_hall.set_surface_override_material(0, _mat("hull"))
	_hall.set_surface_override_material(1, _mat("floor"))
	_hall.set_surface_override_material(2, _mat("glow"))
	_holo.mesh = _holo_mesh()
	_holo.position = Vector3(3.4, 1.55, wall_z - 2.4)


func _rebuild_stars() -> void:
	var n := star_count if star_count >= 0 else int(STARS[_quality])
	_stars.mesh = _star_mesh(n)


func _rebuild_dust() -> void:
	_dust.mesh = _dust_mesh(int(DUST[_quality]))


# --- Nodes and materials ----------------------------------------------------------------------------------------------

func _mesh_node(n: String, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## A MultiMesh of small unshaded cubes with per-instance colours (lights that blink or move).
func _light_node(n: String, size: float) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = n
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * size
	mm.mesh = bm
	mmi.multimesh = mm
	mmi.material_override = _mat("glow")
	return mmi


func _mat(kind: String) -> StandardMaterial3D:
	if _mats.has(kind):
		return _mats[kind]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	match kind:
		"hull":
			m.roughness = 0.85
		"floor":
			m.roughness = 0.45
			m.metallic_specular = 0.6
		"glow":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"add":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.no_depth_test = false
	_mats[kind] = m
	return m


## Commits a hull surface then a glow surface (each only if it has triangles) and sets their materials.
func _two_surfaces(mi: MeshInstance3D, hs: SurfaceTool, hn: int, gs: SurfaceTool, gn: int) -> void:
	var mesh := ArrayMesh.new()
	var mats: Array[StandardMaterial3D] = []
	if hn > 0:
		hs.commit(mesh)
		mats.append(_mat("hull"))
	if gn > 0:
		gs.commit(mesh)
		mats.append(_mat("glow"))
	mi.mesh = mesh
	for i in mats.size():
		mi.set_surface_override_material(i, mats[i])


# --- The habitat ------------------------------------------------------------------------------------------------------

## Where the habitat sits and how it is turned: in the menu camera's view, its axis tilted off the line of sight so
## both drums read as ellipses and the spine runs diagonally up the screen.
static func habitat_transform() -> Transform3D:
	var f := (CAM_TARGET - CAM_POS).normalized()
	var r := f.cross(Vector3.UP).normalized()       # screen right
	var u := r.cross(f)                              # screen up
	var dir := (f + r * HAB_SCREEN.x + u * HAB_SCREEN.y).normalized()
	var across := (r * cos(HAB_AXIS_ROLL) + u * sin(HAB_AXIS_ROLL)).normalized()
	var axis := (f * cos(HAB_AXIS_TILT) + across * sin(HAB_AXIS_TILT)).normalized()
	var x := u.cross(axis).normalized()
	var y := axis.cross(x)
	return Transform3D(Basis(x, y, axis), CAM_POS + dir * HAB_DIST)


func _build_habitat() -> void:
	_habitat = Node3D.new()
	_habitat.name = "Habitat"
	_habitat.transform = habitat_transform()
	add_child(_habitat)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED + 7
	var spine := _mesh_node("Spine", _habitat)
	spine.layers = RING_LAYER
	var spine_lights: Array = []
	_spine_mesh(spine, spine_lights)
	_ring_a = _mesh_node("RingA", _habitat)
	_ring_a.position = Vector3(0, 0, -RING_Z)
	_ring_b = _mesh_node("RingB", _habitat)
	_ring_b.position = Vector3(0, 0, RING_Z)
	var lights_a: Array = []
	var lights_b: Array = []
	_ring_mesh(_ring_a, rng, lights_a, false)
	_ring_mesh(_ring_b, rng, lights_b, true)
	_ring_a.layers = RING_LAYER
	_ring_b.layers = RING_LAYER
	var parents: Array[Node3D] = [_habitat, _ring_a, _ring_b]
	var datas: Array = [spine_lights, lights_a, lights_b]
	for g in 3:
		var mmi := _light_node(["SpineLights", "RingALights", "RingBLights"][g], 2.2)
		mmi.layers = RING_LAYER
		parents[g].add_child(mmi)
		var data: Array = datas[g]
		mmi.multimesh.instance_count = data.size()
		for i in data.size():
			mmi.multimesh.set_instance_color(i, data[i]["col"])
		_lights.append(mmi)
		_light_data.append(data)
	# Shuttles: from a docking port on the spine out to a drum's rim and back, on slow loops.
	var sm := _shuttle_mesh()
	var paths := [
		{"a": Vector3(13, 0, 84), "b": Vector3(0, -RING_R - 10, RING_Z + 4), "c": Vector3(30, -40, 70), "period": 46.0, "offset": 0.1},
		{"a": Vector3(-13, 0, 96), "b": Vector3(RING_R + 10, 12, -RING_Z - 6), "c": Vector3(40, 30, 60), "period": 58.0, "offset": 0.55},
		{"a": Vector3(0, 13, 72), "b": Vector3(-20, RING_R + 12, RING_Z), "c": Vector3(-30, 50, 60), "period": 52.0, "offset": 0.8},
	]
	for p: Dictionary in paths:
		var s := _mesh_node("Shuttle", _habitat)
		s.mesh = sm
		s.layers = RING_LAYER
		s.set_surface_override_material(0, _mat("hull"))
		s.set_surface_override_material(1, _mat("glow"))
		_shuttles.append(s)
		_shuttle_paths.append(p)


func _blink(pos: Vector3, col: Color, rate: float, phase: float, duty: float) -> Dictionary:
	return {"pos": pos, "col": col, "rate": rate, "phase": phase, "duty": duty}


func _mover(a: Vector3, b: Vector3, col: Color, speed: float, phase: float) -> Dictionary:
	return {"a": a, "b": b, "col": col, "speed": speed, "phase": phase}


func _update_lights(mm: MultiMesh, data: Array) -> void:
	for i in data.size():
		var d: Dictionary = data[i]
		if d.has("a"):
			var k := pingpong(_t * float(d["speed"]) + float(d["phase"]), 1.0)
			k = k * k * (3.0 - 2.0 * k)
			mm.set_instance_transform(i, Transform3D(Basis(), (d["a"] as Vector3).lerp(d["b"], k)))
		else:
			var on := fmod(_t * float(d["rate"]) + float(d["phase"]), 1.0) < float(d["duty"])
			mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * (1.0 if on else 0.001)), d["pos"]))


func _move_shuttle(s: MeshInstance3D, p: Dictionary) -> void:
	var ph := fmod(_t * shuttle_speed / float(p["period"]) + float(p["offset"]), 1.0)
	# Out (0 .. 0.4), dwell at the rim, back (0.5 .. 0.9), dwell at the dock.
	var k := 0.0
	var back := false
	if ph < 0.4:
		k = ph / 0.4
	elif ph < 0.5:
		k = 1.0
	elif ph < 0.9:
		k = 1.0 - (ph - 0.5) / 0.4
		back = true
	k = k * k * (3.0 - 2.0 * k)
	var a: Vector3 = p["a"]
	var b: Vector3 = p["b"]
	var c: Vector3 = p["c"]
	var pos := a.lerp(c, k).lerp(c.lerp(b, k), k)
	var tg := (c - a).lerp(b - c, k)
	if back:
		tg = -tg
	if tg.length_squared() < 0.001:
		tg = Vector3.FORWARD
	tg = tg.normalized()
	s.transform = Transform3D(Basis.looking_at(tg, Vector3.UP if absf(tg.y) < 0.95 else Vector3.RIGHT), pos)


## A drum (deep band) with its deck windows and light strips, spokes with lift tubes and cables, the hub. In the
## ring's own frame: the band in the XY plane around the Z axis (the spine).
func _ring_mesh(mi: MeshInstance3D, rng: RandomNumberGenerator, lights: Array, invader: bool) -> void:
	var hs := SurfaceTool.new()
	hs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gs := SurfaceTool.new()
	gs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ro := RING_R
	var ri := RING_R - DRUM_D
	var hw := DRUM_W * 0.5
	var step := TAU / float(RIM_SEGMENTS)
	var gn := 0
	for i in RIM_SEGMENTS:
		var a0 := step * float(i)
		var a1 := a0 + step
		var tone := HAB_MID if (i / 4) % 2 == 0 else HAB_MID.lerp(HAB_DARK, 0.35)
		var o0 := Vector3(cos(a0), sin(a0), 0)
		var o1 := Vector3(cos(a1), sin(a1), 0)
		var om := ((o0 + o1) * 0.5).normalized()
		var zf := Vector3(0, 0, hw)
		_quad(hs, o0 * ro - zf, o1 * ro - zf, o1 * ro + zf, o0 * ro + zf, om, tone.lightened(0.06))
		_quad(hs, o0 * ri - zf, o1 * ri - zf, o1 * ri + zf, o0 * ri + zf, -om, tone.darkened(0.2))
		_quad(hs, o0 * ri + zf, o1 * ri + zf, o1 * ro + zf, o0 * ro + zf, Vector3.BACK, tone)
		_quad(hs, o0 * ri - zf, o1 * ri - zf, o1 * ro - zf, o0 * ro - zf, Vector3.FORWARD, tone.darkened(0.08))
		var tn := Vector3(-om.y, om.x, 0)
		var b := Basis(tn, om, Vector3.BACK)
		if i % 2 == 0:
			_box(hs, Transform3D(b, om * (ro + 1.2)), Vector3(ro * step * 0.5, 2.4, DRUM_W * 0.55), HAB_LIGHT)
		if i % 7 == 3:
			_box(hs, Transform3D(b, om * (ro + 2.0) + Vector3(0, 0, hw * 0.6)), Vector3(ro * step * 0.9, 4.0, 3.0), HAB_LIGHT.darkened(0.1))
		# Deck windows: rows on both faces (some dark), a row along the inner face.
		for side: float in [-1.0, 1.0]:
			var zz := Vector3(0, 0, side * (hw + 0.8))
			for row in WINDOW_ROWS:
				var rr := ri + DRUM_D * (float(row) + 0.5) / float(WINDOW_ROWS)
				for j in 3:
					if rng.randf() < 0.3:
						continue
					var aw := a0 + step * (float(j) + 0.5) / 3.0
					var ow := Vector3(cos(aw), sin(aw), 0)
					var tw := Vector3(-ow.y, ow.x, 0)
					_glow_quad(gs, ow * rr + zz, tw * 1.0, ow * 0.6, _window_col(rng))
					gn += 2
			# A light strip near the inner edge of each face.
			var rs := ri + 1.2
			_glow_quad(gs, om * rs + zz, tn * (rs * step * 0.5), om * 0.35, STRIP)
			gn += 2
		# The strip along the middle of the outer face, the windows along the inner face.
		_glow_quad(gs, om * (ro + 0.8), tn * (ro * step * 0.5), Vector3(0, 0, 0.5), STRIP.darkened(0.15))
		gn += 2
		for zr: float in [-0.25, 0.25]:
			if rng.randf() < 0.75:
				_glow_quad(gs, om * (ri - 0.8) + Vector3(0, 0, zr * DRUM_W), tn * 1.4, Vector3(0, 0, 0.7), _window_col(rng))
				gn += 2
	# Nav lights on the outer face: red / green alternating, slow.
	for k in 6:
		var a := TAU * float(k) / 6.0 + 0.3
		var o := Vector3(cos(a), sin(a), 0)
		lights.append(_blink(o * (ro + 2.5) + Vector3(0, 0, hw if k % 2 == 0 else -hw), Color(1.0, 0.2, 0.15) if k % 2 == 0 else Color(0.3, 1.0, 0.4),
			0.5, rng.randf(), 0.25))
	# Spokes: a box truss, two lift tubes beside it, diagonal cables to the drum; lights riding the lift tubes.
	for k in SPOKES:
		var a := TAU * float(k) / float(SPOKES) + (0.4 if invader else 0.0)
		var o := Vector3(cos(a), sin(a), 0)
		var tn := Vector3(-o.y, o.x, 0)
		var ln := ri - HUB_R
		var mid := o * (HUB_R + ln * 0.5)
		_box(hs, Transform3D(Basis(o, tn, Vector3.BACK), mid), Vector3(ln, 2.6, 2.6), HAB_MID)
		var tube_b := Basis(tn, o, Vector3.BACK)        # prisms run along local Y: along the spoke
		for s: float in [-1.0, 1.0]:
			_prism(hs, Transform3D(tube_b, mid + tn * s * 2.4), 0.9, ln, 6, HAB_LIGHT)
		for s: float in [-1.0, 1.0]:
			_beam(hs, o * (HUB_R + 1.0) + Vector3(0, 0, s * 4.0), o * ri + tn * 7.0 * s + Vector3(0, 0, s * hw * 0.6), 0.35, HAB_DARK)
			_beam(hs, o * (HUB_R + 1.0) + Vector3(0, 0, -s * 4.0), o * ri - tn * 7.0 * s + Vector3(0, 0, s * hw * 0.6), 0.35, HAB_DARK)
		if k % 2 == 0:
			lights.append(_mover(o * (HUB_R + 2.0) + tn * 2.4, o * (ri - 1.0) + tn * 2.4, Color(1.0, 0.9, 0.6), 0.035, rng.randf()))
			lights.append(_mover(o * (ri - 1.0) - tn * 2.4, o * (HUB_R + 2.0) - tn * 2.4, Color(1.0, 0.9, 0.6), 0.03, rng.randf()))
	# The hub turning around the fixed spine.
	var axis := Basis(Vector3.RIGHT, PI / 2.0)          # prisms run along local Y: turn them onto the axis
	_prism(hs, Transform3D(axis, Vector3.ZERO), HUB_R, DRUM_W * 0.7, 16, HAB_MID)
	_prism(hs, Transform3D(axis, Vector3.ZERO), HUB_R + 3.0, 2.5, 16, HAB_LIGHT.darkened(0.08))
	if invader:
		# An invader wedge clamped onto the rim (it turns with this drum).
		var a := 2.2
		var o := Vector3(cos(a), sin(a), 0)
		var tn := Vector3(-o.y, o.x, 0)
		var p := o * (ro + 4.5)
		_invader(hs, gs, Transform3D(Basis(Vector3.BACK.cross(o), o, -Vector3.BACK).orthonormalized(), p), 26.0, lights)
		gn += 4
		for s: float in [-1.0, 1.0]:
			_beam(hs, p + tn * s * 4.0, o * ro + tn * s * 7.0, 0.9, INVADER)
	_two_surfaces(mi, hs, 1, gs, gn)


func _window_col(rng: RandomNumberGenerator) -> Color:
	var c := WINDOW_COOL if rng.randf() < 0.25 else WINDOW_WARM
	var k := rng.randf_range(0.55, 1.0)
	return Color(c.r * k, c.g * k, c.b * k)


## The fixed spine along Z: core, bearing collars at the drums, the docking section (collars, ports), the cargo
## lattice, radiator fins, the power section with its nozzles, the sun mirror, and two invader ships clamped on.
func _spine_mesh(mi: MeshInstance3D, lights: Array) -> void:
	var hs := SurfaceTool.new()
	hs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gs := SurfaceTool.new()
	gs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gn := 0
	var axis := Basis(Vector3.RIGHT, PI / 2.0)
	var ln := SPINE_Z1 - SPINE_Z0
	_prism(hs, Transform3D(axis, Vector3(0, 0, (SPINE_Z0 + SPINE_Z1) * 0.5)), SPINE_R, ln, 8, HAB_MID)
	for z: float in [-RING_Z - DRUM_W * 0.45, -RING_Z + DRUM_W * 0.45, RING_Z - DRUM_W * 0.45, RING_Z + DRUM_W * 0.45]:
		_prism(hs, Transform3D(axis, Vector3(0, 0, z)), 6.0, 3.0, 12, HAB_DARK)
	# Docking section: collars, then four ports on arms at two stations, their mouths lit.
	var z := 52.0
	while z < SPINE_Z1 - 4.0:
		_prism(hs, Transform3D(axis, Vector3(0, 0, z)), 6.5, 2.5, 12, HAB_LIGHT.darkened(0.05))
		z += 11.0
	for st_z: float in [80.0, 100.0]:
		for k in 4:
			var a := TAU * float(k) / 4.0 + PI / 4.0
			var o := Vector3(cos(a), sin(a), 0)
			var tn := Vector3(-o.y, o.x, 0)
			_box(hs, Transform3D(Basis(o, tn, Vector3.BACK), o * 8.0 + Vector3(0, 0, st_z)), Vector3(9.0, 1.8, 1.8), HAB_MID)
			_box(hs, Transform3D(Basis(o, tn, Vector3.BACK), o * 13.0 + Vector3(0, 0, st_z)), Vector3(3.0, 4.2, 4.2), HAB_LIGHT)
			_glow_quad(gs, o * 14.6 + Vector3(0, 0, st_z), tn * 1.4, Vector3(0, 0, 1.4), Color(0.75, 1.0, 0.85))
			gn += 2
			if k % 2 == 0:
				lights.append(_blink(o * 15.5 + Vector3(0, 0, st_z), Color(1, 1, 1), 0.8, float(k) * 0.25 + st_z * 0.01, 0.08))
	# The cargo lattice: four longerons with diagonal braces, containers inside.
	var crgb := [Color(0.45, 0.3, 0.22), Color(0.3, 0.36, 0.32), Color(0.3, 0.34, 0.42), Color(0.4, 0.4, 0.38)]
	var c0 := RING_Z + DRUM_W * 0.5 + 6.0
	var c1 := 46.0
	var corners: Array[Vector3] = []
	for k in 4:
		var a := TAU * float(k) / 4.0 + PI / 4.0
		corners.append(Vector3(cos(a), sin(a), 0) * 10.0)
	for k in 4:
		_beam(hs, corners[k] + Vector3(0, 0, c0), corners[k] + Vector3(0, 0, c1), 0.7, HAB_LIGHT.darkened(0.1))
		var zz := c0
		var flip := false
		while zz < c1 - 0.5:
			var z2 := minf(zz + 8.0, c1)
			var j := (k + 1) % 4
			_beam(hs, corners[k] + Vector3(0, 0, zz if flip else z2), corners[j] + Vector3(0, 0, z2 if flip else zz), 0.4, HAB_DARK)
			zz = z2
			flip = not flip
		var cz := c0 + 3.0
		var n := 0
		while cz < c1 - 4.0:
			var o := corners[k].normalized()
			_box(hs, Transform3D(Basis(), o * 6.2 + Vector3(0, 0, cz + 3.0)), Vector3(3.2, 3.2, 6.0), crgb[(k + n) % crgb.size()])
			cz += 7.0
			n += 1
	# Radiator fins: four flat panels, dark ribs across them, red tip lights.
	for k in 4:
		var a := TAU * float(k) / 4.0
		var o := Vector3(cos(a), sin(a), 0)
		var tn := Vector3(-o.y, o.x, 0)
		var b := Basis(o, tn, Vector3.BACK)
		_box(hs, Transform3D(b, o * 18.0 + Vector3(0, 0, -62.0)), Vector3(28.0, 0.5, 38.0), PANEL)
		var rz := -79.0
		while rz < -45.0:
			_box(hs, Transform3D(b, o * 18.0 + Vector3(0, 0, rz)), Vector3(28.0, 0.8, 0.8), HAB_DARK)
			rz += 6.0
		lights.append(_blink(o * 32.5 + Vector3(0, 0, -62.0), Color(1.0, 0.18, 0.12), 0.6, float(k) * 0.5, 0.2))
	# The power section: a fat drum, flanges, four nozzles opening aft with a faint glow.
	_prism(hs, Transform3D(axis, Vector3(0, 0, SPINE_Z0 + 16.0)), 11.0, 26.0, 12, HAB_DARK.lightened(0.05))
	for fz: float in [SPINE_Z0 + 5.0, SPINE_Z0 + 16.0, SPINE_Z0 + 27.0]:
		_prism(hs, Transform3D(axis, Vector3(0, 0, fz)), 12.5, 1.6, 12, HAB_LIGHT.darkened(0.1))
	var aft := Basis(Vector3.RIGHT, -PI / 2.0)          # prisms along local Y: toward -Z
	for k in 4:
		var a := TAU * float(k) / 4.0 + PI / 4.0
		var o := Vector3(cos(a), sin(a), 0) * 5.5
		_prism(hs, Transform3D(aft, o + Vector3(0, 0, SPINE_Z0 - 3.0)), 2.2, 6.0, 8, HAB_DARK, 3.8)
		_glow_disc(gs, o + Vector3(0, 0, SPINE_Z0 - 6.1), 3.4, Color(0.45, 0.6, 1.0))
		gn += 8
	lights.append(_blink(Vector3(12.5, 0, SPINE_Z0 + 2.0), Color(1.0, 0.2, 0.15), 1.0, 0.0, 0.1))
	lights.append(_blink(Vector3(-12.5, 0, SPINE_Z0 + 2.0), Color(0.3, 1.0, 0.4), 1.0, 0.5, 0.1))
	# The sun mirror: a big angled panel on struts beyond the docking end, a grid of dark seams, white corner lights.
	var mc := Vector3(0, 46.0, SPINE_Z1 + 6.0)
	var mb := Basis(Vector3.RIGHT, deg_to_rad(-40.0))
	_box(hs, Transform3D(mb, mc), Vector3(60.0, 1.0, 38.0), MIRROR)
	for gx in 5:
		_box(hs, Transform3D(mb, mc + mb * Vector3(-30.0 + 12.0 * float(gx) + 6.0, 0.6, 0)), Vector3(0.5, 0.4, 38.0), HAB_MID)
	for gz in 3:
		_box(hs, Transform3D(mb, mc + mb * Vector3(0, 0.6, -19.0 + 12.67 * float(gz) + 6.33)), Vector3(60.0, 0.4, 0.5), HAB_MID)
	_beam(hs, Vector3(0, 0, SPINE_Z1 - 2.0), mc + mb * Vector3(0, -0.5, 0), 1.6, HAB_MID)
	_beam(hs, Vector3(0, 0, SPINE_Z1 - 14.0), mc + mb * Vector3(20, -0.5, -12), 0.8, HAB_DARK)
	_beam(hs, Vector3(0, 0, SPINE_Z1 - 14.0), mc + mb * Vector3(-20, -0.5, -12), 0.8, HAB_DARK)
	for cx: float in [-1.0, 1.0]:
		for cz: float in [-1.0, 1.0]:
			lights.append(_blink(mc + mb * Vector3(cx * 30.0, 1.5, cz * 19.0), Color(1, 1, 1), 0.35, 0.25 * (cx + cz + 2.0), 0.12))
	# Two invader ships clamped onto the spine.
	var p1 := Vector3(14.0, 0, -100.0)
	_invader(hs, gs, Transform3D(Basis(Vector3.UP, Vector3.RIGHT, Vector3.FORWARD), p1), 30.0, lights)
	_beam(hs, p1 + Vector3(-3, 0, -6), Vector3(SPINE_R, 0, -106.0), 1.0, INVADER)
	_beam(hs, p1 + Vector3(-3, 0, 6), Vector3(SPINE_R, 0, -94.0), 1.0, INVADER)
	var p2 := Vector3(0, -14.0, 64.0)
	_invader(hs, gs, Transform3D(Basis(Vector3.RIGHT, Vector3.DOWN, -Vector3.BACK).orthonormalized(), p2), 24.0, lights)
	_beam(hs, p2 + Vector3(0, 3, -5), Vector3(0, -SPINE_R, 58.0), 0.9, INVADER)
	_beam(hs, p2 + Vector3(0, 3, 5), Vector3(0, -SPINE_R, 70.0), 0.9, INVADER)
	gn += 8
	_two_surfaces(mi, hs, 1, gs, gn)


## An invader ship: a sharp charcoal wedge (nose along the frame's -Z, back up along +Y), two swept blades, a dull red
## stripe and a slow red light. `l` is its length.
func _invader(hs: SurfaceTool, gs: SurfaceTool, xf: Transform3D, l: float, lights: Array) -> void:
	var w := l * 0.55
	var h := l * 0.18
	_wedge(hs, xf, l, w, h, INVADER)
	for s: float in [-1.0, 1.0]:
		var bx := xf * Transform3D(Basis(Vector3.UP, s * 0.5), Vector3(s * w * 0.42, -h * 0.1, l * 0.2))
		_wedge(hs, bx, l * 0.55, l * 0.12, h * 0.35, INVADER.lightened(0.05))
	_box(hs, xf * Transform3D(Basis(), Vector3(0, h * 0.62, l * 0.12)), Vector3(l * 0.06, 0.4, l * 0.55), INVADER_RED)
	_glow_quad(gs, xf * Vector3(0, h * 0.2, l * 0.5 + 0.5), xf.basis * Vector3(w * 0.25, 0, 0), xf.basis * Vector3(0, h * 0.2, 0), Color(0.6, 0.12, 0.06))
	_glow_quad(gs, xf * Vector3(0, h * 0.4, -l * 0.15), xf.basis * Vector3(l * 0.05, 0, 0), xf.basis * Vector3(0, 0, l * 0.04), Color(0.7, 0.1, 0.06))
	lights.append(_blink(xf * Vector3(0, h * 0.9, l * 0.3), Color(1.0, 0.12, 0.08), 0.3, l * 0.01, 0.35))


func _shuttle_mesh() -> ArrayMesh:
	var hs := SurfaceTool.new()
	hs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gs := SurfaceTool.new()
	gs.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(hs, Transform3D(Basis(), Vector3(0, 0, 0.6)), Vector3(2.4, 1.6, 4.2), HAB_LIGHT)
	_wedge(hs, Transform3D(Basis(), Vector3(0, 0, -2.4)), 2.4, 2.4, 1.0, HAB_LIGHT.darkened(0.1))
	_box(hs, Transform3D(Basis(), Vector3(0, -0.2, 1.4)), Vector3(4.4, 0.25, 1.6), HAB_MID)
	_glow_quad(gs, Vector3(0, 0, 2.75), Vector3(0.9, 0, 0), Vector3(0, 0.6, 0), Color(0.6, 0.8, 1.0))
	var mesh := ArrayMesh.new()
	hs.commit(mesh)
	gs.commit(mesh)
	return mesh


# --- The room ---------------------------------------------------------------------------------------------------------

## The octagonal window outline at apothem `a` (scaled by window_scale), stretched sideways; flat sill and top.
func _octagon(a: float, z: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var rc := a * window_scale / cos(PI / 8.0)
	var c := Vector2(WINDOW_C.x * window_scale, 0.6 + WINDOW_APOTHEM * window_scale)
	for k in 8:
		var th := PI / 8.0 + PI / 4.0 * float(k)
		out.append(Vector3(c.x + WINDOW_STRETCH * rc * cos(th), c.y + rc * sin(th), z))
	return out


func _in_poly(p: Vector2, poly: Array[Vector3], margin: float) -> bool:
	for k in poly.size():
		var a := Vector2(poly[k].x, poly[k].y)
		var b := Vector2(poly[(k + 1) % poly.size()].x, poly[(k + 1) % poly.size()].y)
		var e := (b - a).normalized()
		if e.cross(p - a) < margin:      # the octagon winds counter-clockwise in (x, y): inside is on the left
			return false
	return true


func _hall_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gs := SurfaceTool.new()
	gs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED + 1
	_led_data.clear()
	# The room around the window: side walls, ceiling with recessed lights, back wall (inward faces).
	_quad(st, Vector3(-HALL_HALF, 0, HALL_BACK), Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3(-HALL_HALF, HALL_TOP, wall_z),
		Vector3(-HALL_HALF, 0, wall_z), Vector3.RIGHT, WALL_DARK)
	_quad(st, Vector3(HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, wall_z),
		Vector3(HALL_HALF, 0, wall_z), Vector3.LEFT, WALL_DARK)
	_quad(st, Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, wall_z),
		Vector3(-HALL_HALF, HALL_TOP, wall_z), Vector3.DOWN, WALL_DARK)
	_quad(st, Vector3(-HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, 0, HALL_BACK), Vector3(HALL_HALF, HALL_TOP, HALL_BACK),
		Vector3(-HALL_HALF, HALL_TOP, HALL_BACK), Vector3.BACK, WALL_DARK)
	var lz := HALL_BACK + 4.0
	while lz < wall_z - 2.0:
		for lx: float in [-12.0, -1.5, 9.0]:
			_box(st, Transform3D(Basis(), Vector3(lx, HALL_TOP - 0.15, lz)), Vector3(4.0, 0.3, 1.6), STEEL)
			_glow_quad(gs, Vector3(lx, HALL_TOP - 0.32, lz), Vector3(1.7, 0, 0), Vector3(0, 0, 0.5), Color(0.75, 0.8, 0.85))
		lz += 7.0
	# The window wall: a bevelled reveal (outer outline on the wall, inner one REVEAL deeper), then eight wall facets
	# from the outline out to the room's edges, each leaning a little into the hall.
	var inner := _octagon(WINDOW_APOTHEM, wall_z + REVEAL)
	var outer := _octagon(WINDOW_APOTHEM + FRAME, wall_z)
	var far := _octagon(WINDOW_APOTHEM * 6.0, wall_z - 1.2)
	var c := Vector3(inner[0].x + inner[3].x, inner[1].y + inner[5].y, 0.0) * 0.5
	for k in 8:
		var j := (k + 1) % 8
		var mid := (inner[k] + inner[j]) * 0.5
		var out_dir := Vector3(mid.x - c.x, mid.y - c.y, 0.0).normalized()
		var tone := STEEL if k % 2 == 0 else STEEL.darkened(0.12)
		_quad(st, inner[k], inner[j], outer[j], outer[k], (-out_dir + Vector3.FORWARD).normalized(), tone)
		_quad(st, outer[k], outer[j], far[j], far[k], Vector3.FORWARD, WALL_MID if k % 2 == 0 else WALL_DARK)
		# The pale trim around the glass, bolted.
		var edge := inner[j] - inner[k]
		var en := edge.normalized()
		var b := Basis(en, out_dir, en.cross(out_dir))
		_box(st, Transform3D(b, mid + out_dir * 0.15), Vector3(edge.length() + 0.3, 0.3, 0.5), STEEL_LIGHT)
		var bolts := int(edge.length() / 0.9)
		for q in bolts:
			var bp := inner[k] + en * (0.45 + 0.9 * float(q)) + out_dir * 0.15 + Vector3(0, 0, -0.3)
			_box(st, Transform3D(b, bp), Vector3(0.12, 0.12, 0.1), STEEL.darkened(0.2))
		# Panel seams on the facet: two raised strips across it.
		for f: float in [0.3, 0.62]:
			var p0 := outer[k].lerp(far[k], f)
			var p1 := outer[j].lerp(far[j], f)
			var se := p1 - p0
			var sn := (far[k] - outer[k]).normalized()
			var sb := Basis(se.normalized(), sn, se.normalized().cross(sn))
			_box(st, Transform3D(sb, (p0 + p1) * 0.5 + Vector3(0, 0, -0.1)), Vector3(se.length(), 0.35, 0.3), WALL_DARK.darkened(0.25))
	# Pressure ribs dividing the glass into panes: two uprights and a transom, with seal strips and bolts.
	var gz := wall_z + REVEAL + 0.15
	var ws := window_scale
	var span := WINDOW_APOTHEM * 2.6 * ws
	for rx: float in [c.x - 2.4 * ws, c.x + 5.0 * ws]:   # off-centre: the habitat shows between them
		_box(st, Transform3D(Basis(), Vector3(rx, c.y, gz)), Vector3(0.4, span, 0.55), STEEL.lightened(0.05))
		for s: float in [-1.0, 1.0]:
			_box(st, Transform3D(Basis(), Vector3(rx + s * 0.3, c.y, gz + 0.12)), Vector3(0.16, span, 0.3), SEAL)
		var by := c.y - span * 0.5
		while by < c.y + span * 0.5:
			if _in_poly(Vector2(rx, by), inner, 0.4):
				_box(st, Transform3D(Basis(), Vector3(rx, by, gz - 0.32)), Vector3(0.14, 0.14, 0.1), STEEL.darkened(0.25))
			by += 0.8
	var ty := 0.6 + 5.5 * ws
	var tspan := 2.0 * WINDOW_STRETCH * WINDOW_APOTHEM * 1.1 * ws
	_box(st, Transform3D(Basis(), Vector3(c.x, ty, gz - 0.05)), Vector3(tspan, 0.36, 0.5), STEEL.lightened(0.05))
	for s: float in [-1.0, 1.0]:
		_box(st, Transform3D(Basis(), Vector3(c.x, ty + s * 0.27, gz + 0.1)), Vector3(tspan, 0.14, 0.3), SEAL)
	var bx := c.x - tspan * 0.5
	while bx < c.x + tspan * 0.5:
		if _in_poly(Vector2(bx, ty), inner, 0.4):
			_box(st, Transform3D(Basis(), Vector3(bx, ty, gz - 0.35)), Vector3(0.14, 0.14, 0.1), STEEL.darkened(0.25))
		bx += 0.8
	# A low step along the sill, hazard stripes on the floor in front of it.
	var sill_w := inner[6].x - inner[5].x
	var step_w := sill_w + 2.0 * FRAME + 6.0
	_box(st, Transform3D(Basis(), Vector3(c.x, 0.25, wall_z - 0.5)), Vector3(step_w, 0.5, 1.0), WALL_MID)
	var hx := c.x - step_w * 0.5
	var hi := 0
	while hx < c.x + step_w * 0.5 - 0.6:
		var y := 0.02
		_quad(st, Vector3(hx, y, wall_z - 1.6), Vector3(hx + 0.6, y, wall_z - 1.6), Vector3(hx + 1.2, y, wall_z - 1.05),
			Vector3(hx + 0.6, y, wall_z - 1.05), Vector3.UP, HAZARD_Y if hi % 2 == 0 else HAZARD_K)
		hx += 0.6
		hi += 1
	# The plinth: a low disc with an orange edge (the turntable).
	_prism(st, Transform3D(Basis(), Vector3(0, 0.03, 0)), 2.9, 0.06, 40, PLINTH_RIM)
	_prism(st, Transform3D(Basis(), Vector3(0, 0.045, 0)), 2.8, 0.09, 40, PLINTH)
	_props(st, gs, rng)
	# Surface 0: the room; surface 1: the floor, faceted triangles in slightly different greys; surface 2: glow.
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
			var f1 := FLOOR.lightened(s1) if s1 > 0 else FLOOR.darkened(-s1)
			var f2 := FLOOR.lightened(s2) if s2 > 0 else FLOOR.darkened(-s2)
			if (i + k) % 2 == 0:
				_tri(st, a, b2, c2, Vector3.UP, f1)
				_tri(st, a, c2, d, Vector3.UP, f2)
			else:
				_tri(st, a, b2, d, Vector3.UP, f1)
				_tri(st, b2, c2, d, Vector3.UP, f2)
	st.commit(mesh)
	gs.commit(mesh)
	_leds.multimesh.instance_count = _led_data.size()
	for i in _led_data.size():
		_leds.multimesh.set_instance_color(i, _led_data[i]["col"])
	return mesh


## Props between the mech and the window, or off to the sides (never between the camera and the mech): the tactical
## table (screen left), two pilot seats (screen right), status pedestals, lockers, benches, cable runs.
func _props(st: SurfaceTool, gs: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var led_cols := [Color(0.3, 1.0, 0.4), Color(1.0, 0.65, 0.15), Color(1.0, 0.2, 0.15), Color(0.4, 0.75, 1.0)]
	# Tactical table: pedestal, slab, a dim orange plate under the holo, LEDs along its front edge.
	var tp := Vector3(3.4, 0, wall_z - 2.4)
	_box(st, Transform3D(Basis(), tp + Vector3(0, 0.45, 0)), Vector3(0.9, 0.9, 0.7), STEEL.darkened(0.2))
	_box(st, Transform3D(Basis(), tp + Vector3(0, 0.96, 0)), Vector3(2.3, 0.12, 1.5), STEEL)
	_box(st, Transform3D(Basis(), tp + Vector3(0, 1.04, 0)), Vector3(2.0, 0.05, 1.2), SEAL)
	_glow_quad(gs, tp + Vector3(0, 1.075, 0), Vector3(0.8, 0, 0), Vector3(0, 0, 0.5), Color(0.35, 0.16, 0.05))
	for q in 7:
		_led_data.append(_blink(tp + Vector3(-0.9 + 0.3 * float(q), 0.96, -0.77), led_cols[rng.randi_range(0, 3)],
			rng.randf_range(0.3, 2.0), rng.randf(), rng.randf_range(0.3, 0.8)))
	# Two pilot seats facing the window.
	for sp: Vector3 in [Vector3(-5.2, 0, wall_z - 2.3), Vector3(-7.4, 0, wall_z - 2.6)]:
		_prism(st, Transform3D(Basis(), sp + Vector3(0, 0.25, 0)), 0.18, 0.5, 6, STEEL.darkened(0.2))
		_box(st, Transform3D(Basis(), sp + Vector3(0, 0.55, 0)), Vector3(0.75, 0.16, 0.75), SEAT)
		var bb := Basis(Vector3.RIGHT, -0.25)
		_box(st, Transform3D(bb, sp + Vector3(0, 1.05, -0.42)), Vector3(0.72, 0.95, 0.14), SEAT)
		_box(st, Transform3D(bb, sp + Vector3(0, 1.05, -0.5)), Vector3(0.16, 0.8, 0.02), PLINTH_RIM.darkened(0.3))
		for s: float in [-1.0, 1.0]:
			_box(st, Transform3D(Basis(), sp + Vector3(s * 0.43, 0.78, 0.0)), Vector3(0.1, 0.1, 0.6), STEEL)
	# Status pedestals with a screen and a block of blinking LEDs.
	for pp: Vector3 in [Vector3(6.4, 0, wall_z - 2.1), Vector3(-9.6, 0, wall_z - 2.0)]:
		_box(st, Transform3D(Basis(), pp + Vector3(0, 0.6, 0)), Vector3(0.7, 1.2, 0.45), STEEL.darkened(0.15))
		_glow_quad(gs, pp + Vector3(0, 0.95, -0.235), Vector3(0.25, 0, 0), Vector3(0, 0.12, 0), Color(0.12, 0.3, 0.35))
		for q in 8:
			_led_data.append(_blink(pp + Vector3(-0.21 + 0.14 * float(q % 4), 0.55 + 0.12 * float(q / 4), -0.24),
				led_cols[rng.randi_range(0, 3)], rng.randf_range(0.2, 1.6), rng.randf(), rng.randf_range(0.2, 0.9)))
	# Lockers against the wall either side of the window, door seams and vents; benches before the right-hand row.
	for row: Array in [[7.6, 1.0], [-11.0, -1.0]]:
		var x0: float = row[0]
		var dir: float = row[1]
		for q in 4:
			var lp := Vector3(x0 + dir * (0.5 + 1.05 * float(q)), 1.2, wall_z - 0.45)
			_box(st, Transform3D(Basis(), lp), Vector3(1.0, 2.4, 0.6), LOCKER if q % 2 == 0 else LOCKER.darkened(0.1))
			_box(st, Transform3D(Basis(), lp + Vector3(0, 0, -0.31)), Vector3(0.04, 2.3, 0.02), SEAL)
			_box(st, Transform3D(Basis(), lp + Vector3(0.3, 0.1, -0.31)), Vector3(0.06, 0.3, 0.04), STEEL_LIGHT)
			for v in 3:
				_box(st, Transform3D(Basis(), lp + Vector3(0, 0.75 + 0.1 * float(v), -0.31)), Vector3(0.6, 0.03, 0.02), SEAL)
		# A cable tray above the lockers and two sagging cable runs.
		var tx := x0 + dir * 2.2
		_box(st, Transform3D(Basis(), Vector3(tx, 6.4, wall_z - 0.3)), Vector3(5.0, 0.15, 0.5), STEEL.darkened(0.1))
		for cable in 2:
			var a := Vector3(x0 + dir * 0.2, 6.2 - 0.25 * float(cable), wall_z - 0.35 - 0.12 * float(cable))
			var b := Vector3(x0 + dir * 4.4, 6.1 - 0.2 * float(cable), wall_z - 0.35 - 0.12 * float(cable))
			var prev := a
			for s in 8:
				var k := float(s + 1) / 8.0
				var p := a.lerp(b, k) + Vector3(0, -(0.9 + 0.3 * float(cable)) * 4.0 * k * (1.0 - k), 0)
				_beam(st, prev, p, 0.07, SEAL)
				prev = p
	for q in 2:
		var bp := Vector3(-11.6 - 1.9 * float(q), 0, wall_z - 1.9)
		_box(st, Transform3D(Basis(), bp + Vector3(0, 0.45, 0)), Vector3(1.7, 0.1, 0.5), SEAT)
		for s: float in [-1.0, 1.0]:
			_box(st, Transform3D(Basis(), bp + Vector3(s * 0.7, 0.2, 0)), Vector3(0.08, 0.4, 0.4), STEEL)


## The holo over the tactical table: a tiny ring habitat (two rings, a spine), additive orange, turning slowly.
func _holo_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tilt := Basis(Vector3.RIGHT, 1.1)
	for rz: float in [-0.1, 0.1]:
		for i in 24:
			var a0 := TAU * float(i) / 24.0
			var a1 := a0 + TAU / 24.0
			var p0 := tilt * Vector3(cos(a0) * 0.42, sin(a0) * 0.42, rz)
			var p1 := tilt * Vector3(cos(a1) * 0.42, sin(a1) * 0.42, rz)
			_beam(st, p0, p1, 0.035, HOLO.darkened(0.55))
		for k in 4:
			var a := TAU * float(k) / 4.0
			_beam(st, tilt * Vector3(0, 0, rz), tilt * Vector3(cos(a) * 0.42, sin(a) * 0.42, rz), 0.012, HOLO.darkened(0.7))
	_beam(st, tilt * Vector3(0, 0, -0.5), tilt * Vector3(0, 0, 0.45), 0.025, HOLO.darkened(0.55))
	return st.commit()


## Dust motes drifting in the window light between the mech and the glass: tiny additive specks.
func _dust_mesh(n: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if n <= 0:
		return mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED + 3
	for i in n:
		var p := Vector3(rng.randf_range(-8.0, 5.0), rng.randf_range(0.3, 7.5), rng.randf_range(1.2, wall_z - 0.2))
		var s := rng.randf_range(0.012, 0.03)
		var k := rng.randf_range(0.08, 0.22)
		_glow_quad(st, p, Vector3(s, 0, 0), Vector3(0, s, 0), Color(0.6 * k, 0.75 * k, 1.0 * k))
	return st.commit(mesh)


## Stars: small quads on a far shell, facing the centre, mostly on the window's side (+Z). One mesh, unshaded.
func _star_mesh(n: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if n <= 0:
		return mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED
	var sscale := STAR_SHELL / 600.0
	for i in n:
		# Most of them in a cone around +Z (what the window shows), the rest anywhere (the lab looks around).
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if d.length_squared() < 0.01:
			d = Vector3.BACK
		d = d.normalized()
		if rng.randf() < 0.8:
			d = (Vector3.BACK + Vector3(d.x, d.y, 0.0) * 0.9).normalized()
		var p := d * STAR_SHELL
		var u := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
		var v := d.cross(u)
		var big := pow(rng.randf(), 4.0)
		var s := lerpf(0.5, 1.7, big) * sscale
		var bright := lerpf(0.35, 1.0, maxf(big, rng.randf() * 0.7))
		var tint := [Color(0.75, 0.85, 1.0), Color(1, 1, 1), Color(1.0, 0.9, 0.75)][rng.randi_range(0, 2)] as Color
		_glow_quad(st, p, u * s, v * s, Color(tint.r * bright, tint.g * bright, tint.b * bright))
	return st.commit(mesh)


# --- Geometry helpers -------------------------------------------------------------------------------------------------

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


## An unlit quad centred on p with half-extent vectors u, v (drawn double-sided).
func _glow_quad(st: SurfaceTool, p: Vector3, u: Vector3, v: Vector3, col: Color) -> void:
	var n := u.cross(v).normalized()
	_quad(st, p - u - v, p + u - v, p + u + v, p - u + v, n, col)


## An unlit octagonal disc (a nozzle's glow) facing -Z.
func _glow_disc(st: SurfaceTool, p: Vector3, r: float, col: Color) -> void:
	for i in 8:
		var a0 := TAU * float(i) / 8.0
		var a1 := a0 + TAU / 8.0
		_tri(st, p, p + Vector3(cos(a0), sin(a0), 0) * r, p + Vector3(cos(a1), sin(a1), 0) * r, Vector3.FORWARD, col)


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


## A square beam of thickness t from a to b.
func _beam(st: SurfaceTool, a: Vector3, b: Vector3, t: float, col: Color) -> void:
	var d := b - a
	var ln := d.length()
	if ln < 0.001:
		return
	var x := d / ln
	var y := x.cross(Vector3.UP if absf(x.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	_box(st, Transform3D(Basis(x, y, z), (a + b) * 0.5), Vector3(ln, t, t), col)


## A closed prism along local Y (radius r, length ln, `sides` facets), centred on xf; `top` >= 0 tapers its +Y end.
func _prism(st: SurfaceTool, xf: Transform3D, r: float, ln: float, sides: int, col: Color, top: float = -1.0) -> void:
	var rt := r if top < 0.0 else top
	var hy := Vector3(0, ln * 0.5, 0)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var am := (a0 + a1) * 0.5
		var sn := (xf.basis * Vector3(cos(am), (r - rt) / maxf(ln, 0.001), sin(am))).normalized()
		_quad(st, xf * (d0 * r - hy), xf * (d1 * r - hy), xf * (d1 * rt + hy), xf * (d0 * rt + hy), sn, col)
		_tri(st, xf * hy, xf * (d0 * rt + hy), xf * (d1 * rt + hy), (xf.basis * Vector3.UP).normalized(), col)
		_tri(st, xf * -hy, xf * (d0 * r - hy), xf * (d1 * r - hy), (xf.basis * Vector3.DOWN).normalized(), col.darkened(0.2))


## A sharp wedge: nose at local -Z, flat-ish belly, a ridge along +Y at the back. l long, w wide at the back, h tall.
func _wedge(st: SurfaceTool, xf: Transform3D, l: float, w: float, h: float, col: Color) -> void:
	var nose := xf * Vector3(0, 0, -l * 0.5)
	var top := xf * Vector3(0, h, l * 0.5)
	var lt := xf * Vector3(-w * 0.5, 0, l * 0.5)
	var rt := xf * Vector3(w * 0.5, 0, l * 0.5)
	var bot := xf * Vector3(0, -h * 0.35, l * 0.4)
	var ctr := (nose + top + lt + rt + bot) / 5.0
	for f: Array in [[nose, lt, top], [nose, top, rt], [nose, rt, bot], [nose, bot, lt]]:
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var c: Vector3 = f[2]
		_tri(st, a, b, c, (a + b + c) / 3.0 - ctr, col.lightened(0.04) if f[2] == top or f[1] == top else col)
	var back := xf.basis * Vector3.BACK
	_tri(st, lt, top, rt, back, col.darkened(0.3))
	_tri(st, lt, rt, bot, back, col.darkened(0.3))


# --- Lab ----------------------------------------------------------------------------------------------------------------

func lab_params() -> Array:
	return [
		{"id": "ring_spin", "label": "Ring spin (rad/s, drums counter-rotate)", "min": 0.0, "max": 0.3, "value": ring_spin},
		{"id": "shuttle_speed", "label": "Shuttle speed (x)", "min": 0.0, "max": 5.0, "value": shuttle_speed},
		{"id": "window_scale", "label": "Window size (x)", "min": 0.7, "max": 1.3, "value": window_scale},
		{"id": "wall_z", "label": "Window wall distance (m)", "min": 4.5, "max": 12.0, "value": wall_z},
		{"id": "key", "label": "Key light (warm)", "min": 0.0, "max": 12.0, "value": key_energy},
		{"id": "window", "label": "Window light (blue)", "min": 0.0, "max": 3.0, "value": window_energy},
		{"id": "glow", "label": "Window glow on the floor", "min": 0.0, "max": 6.0, "value": glow_energy},
		{"id": "star_light", "label": "Star light on the habitat", "min": 0.0, "max": 3.0, "value": star_light_energy},
		{"id": "stars", "label": "Stars (-1: by quality)", "min": -1.0, "max": 4000.0, "value": float(star_count)},
	]


func set_lab_param(id: String, value: float) -> void:
	match id:
		"ring_spin": ring_spin = value
		"shuttle_speed": shuttle_speed = value
		"window_scale":
			window_scale = value
			_rebuild_hall()
		"wall_z":
			wall_z = value
			_rebuild_hall()
			_rebuild_dust()
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
