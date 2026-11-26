class_name LifeAnimRig
extends RefCounted
## The civilians' jointed figure and its animation data (docs/design/ambient-life.md "Civilian animation: as built";
## user pick "Build C": shader limbs + character). LifeFigures draws it with ONE MultiMesh per deck; the pose is
## computed in life_anim_limbs.gdshader from per-instance custom data packed here (pack / unpack), and the clock is one
## material uniform. Same look as the old pose meshes: LifeFigures' boxes, palette colours and proportions, split at the
## elbows and knees into ten rigid parts (UV.x = part id); shirt and trousers come from the instance's clothes index
## (UV.y = colour slot: 0 the vertex colour, 1 shirt, 2 trousers), so one mesh serves every clothes set.

const SHADER := preload("res://scripts/world/life/life_anim_limbs.gdshader")

## Motion ids: the shader's M_* constants.
const IDLE := 0
const WALK := 1
const RUN := 2
const COWER := 3
const FLINCH := 4
const FALL := 5
const SIT := 6
const HANDS := 7
const LOOK := 8
const MOTION_NAMES := ["idle", "walk", "run", "cower", "flinch", "fall", "sit", "hands_up", "look_around"]
## AmbientLife / LifeCrowd animation mode (mode_of) -> motion.
const MODE_MOTION := {"wait": IDLE, "walk": WALK, "run": RUN, "cower": COWER, "wary": FLINCH, "down": FALL, "sit": SIT,
		"hands_up": HANDS, "look_around": LOOK}

const EXAGGERATION := 1.3      ## acting amplitude (user pick ~x1.3); leg swing comes from the stride, not from this
const BLEND_S := 0.3           ## s, cross-fade between motions (cower / hands up 0.45, fall 0.18: in the shader)
const TURN_TAU := 0.16         ## s, the drawn heading closes the gap to the route's heading by exp(-t / TURN_TAU)
const TURN_MIN := 0.5          ## rad (~29 deg): a heading gap this big at a sample starts a turn (head leads)
const TURN_STEP := 5.0         ## deg, turn quantisation in the custom data
const HIP := 0.86
const PARTS := 10


## The figure's ShaderMaterial. character 1 = Build C (secondary motion and acting), 0 = Build B (plain limbs).
static func material(character: float = 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("character", character)
	m.set_shader_parameter("exaggeration", EXAGGERATION)
	m.set_shader_parameter("blend_s", BLEND_S)
	m.set_shader_parameter("run_speed", LifeCrowd.RUN)
	m.set_shader_parameter("turn_tau", TURN_TAU)
	var shirts := PackedVector3Array()
	var trousers := PackedVector3Array()
	for v in 8:
		var a: Color = CityPalette.C[LifeFigures.SHIRTS[v % LifeFigures.SHIRTS.size()]]
		var b: Color = CityPalette.C[LifeFigures.TROUSERS[v % LifeFigures.TROUSERS.size()]]
		shirts.append(Vector3(a.r, a.g, a.b))
		trousers.append(Vector3(b.r, b.g, b.b))
	m.set_shader_parameter("shirts", shirts)
	m.set_shader_parameter("trousers", trousers)
	return m


## Instance custom data (layout in the shader header): motion `m` since `t0` (life clock minus the epoch), coming from
## motion `prev`, clothes `cloth`, `talk` (someone close: the idle talks), a heading gap `turn` (rad) the drawn heading
## closes from t0, walking speed `speed` (m/s), seed 0..1, and `param` (metres walked at t0, or the fall direction).
static func pack(m: int, prev: int, cloth: int, talk: bool, turn: float, t0: float, speed: float, sd: float,
		param: float) -> Color:
	var tq := clampi(int(round(rad_to_deg(wrapf(turn, -PI, PI)) / TURN_STEP)), -36, 36) + 36
	var x := (m & 15) + 16 * (prev & 15) + 256 * (cloth & 7) + (2048 if talk else 0) + 4096 * tq
	var z := clampi(int(round(speed * 100.0)), 0, 16000) * 1024 + clampi(int(sd * 1024.0), 0, 1023)
	return Color(float(x), t0, float(z), param)


## pack's fields back: {motion, prev, cloth, talk, turn (rad), t0, speed, seed, param}.
static func unpack(c: Color) -> Dictionary:
	var x := int(c.r + 0.5)
	var z := int(c.b + 0.5)
	return {"motion": x % 16, "prev": (x / 16) % 16, "cloth": (x / 256) % 8, "talk": (x / 2048) % 2 == 1,
			"turn": deg_to_rad(float(x / 4096 - 36) * TURN_STEP), "t0": c.g, "speed": float(z / 1024) * 0.01,
			"seed": float(z % 1024) / 1024.0, "param": c.a}


## The jointed civilian mesh for the shader: rest pose (arms hanging, feet at the origin, facing +Z), shirt / trousers
## as colour slots. Child boxes reach a little past their joint (and are a hair thinner) so bends never open a gap.
static func build_mesh() -> ArrayMesh:
	var geo := CityGeo.new()
	var uv := PackedVector2Array()
	_parts(geo, uv, Color.WHITE, Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = geo.verts
	arrays[Mesh.ARRAY_NORMAL] = geo.normals
	arrays[Mesh.ARRAY_COLOR] = geo.colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _parts(geo: CityGeo, uv: PackedVector2Array, shirt: Color, legs: Color, slots: bool = true) -> void:
	var skin: Color = CityPalette.C[LifeFigures.SKIN]
	var hair: Color = CityPalette.C[LifeFigures.HAIR]
	var s1 := 1 if slots else 0
	var s2 := 2 if slots else 0
	var I := Transform3D.IDENTITY
	geo.box(I, Vector3(0.0, HIP + 0.31, 0.0), Vector3(0.48, 0.64, 0.27), shirt)                    # 0 torso
	_tag(geo, uv, 0, s1)
	geo.box(I, Vector3(0.0, HIP + 0.66 + 0.15, 0.01), Vector3(0.27, 0.29, 0.27), skin)             # 1 head + hair
	geo.box(I, Vector3(0.0, HIP + 0.66 + 0.27, -0.03), Vector3(0.29, 0.09, 0.27), hair)
	_tag(geo, uv, 1, 0)
	for k in 2:
		var x := 0.31 if k == 0 else -0.31
		geo.box(I, Vector3(x, 1.46 - 0.16, 0.0), Vector3(0.13, 0.32, 0.14), shirt)          # 2 / 3 upper arm
		_tag(geo, uv, 2 + k, s1)
	for k in 2:
		var x := 0.31 if k == 0 else -0.31
		geo.box(I, Vector3(x, 1.14 - 0.16 + 0.015, 0.0), Vector3(0.12, 0.35, 0.13), shirt)  # 4 / 5 forearm
		_tag(geo, uv, 4 + k, s1)
	for k in 2:
		var x := 0.11 if k == 0 else -0.11
		geo.box(I, Vector3(x, HIP - 0.22, 0.0), Vector3(0.18, 0.44, 0.21), legs)            # 6 / 7 thigh
		_tag(geo, uv, 6 + k, s2)
	for k in 2:
		var x := 0.11 if k == 0 else -0.11
		geo.box(I, Vector3(x, 0.42 - 0.21 + 0.02, 0.0), Vector3(0.17, 0.46, 0.2), legs)     # 8 / 9 shin
		_tag(geo, uv, 8 + k, s2)


static func _tag(geo: CityGeo, uv: PackedVector2Array, part: int, slot: int) -> void:
	while uv.size() < geo.verts.size():
		uv.append(Vector2(float(part), float(slot)))


## Triangles of the jointed figure.
static func tris() -> int:
	return build_mesh().get_faces().size() / 3
