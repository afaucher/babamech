class_name HangarBay
extends Node3D
## The hangar set (docs/design/hangar.md): the vehicle bay of a military assault boat clamped to the habitat hull,
## about to force-board. Gunmetal plates, ribs and girders, yellow-black hazard stripes, ammunition racks, four docking
## cradles along a central aisle, a breaching door at the far end. Two states: prep (work lights, clamps closed) and
## alert (Launch: lights drop, red beacons turn, amber strobes, the door's countdown strip glows, clamps swing open).
## Cosmetic only (no gameplay state, no randomness). Used by MechStage for the hangar screen and as the lab subject
## `hangar`. Aisle along Z: the near end (+Z) is the camera's, the door is at -Z. Mechs face -Z by default.

const GUNMETAL := Color(0.29, 0.31, 0.34)
const GUNMETAL_DARK := Color(0.17, 0.18, 0.2)
const GUNMETAL_LIGHT := Color(0.38, 0.4, 0.43)
const HAZARD_YELLOW := Color(0.95, 0.74, 0.1)
const HAZARD_BLACK := Color(0.08, 0.08, 0.09)
const BRASS := Color(0.78, 0.6, 0.26)
const WORK_LIGHT := Color(0.85, 0.92, 1.0)
const ALERT_RED := Color(1.0, 0.14, 0.07)
const STROBE_AMBER := Color(1.0, 0.6, 0.12)

const HALF_WIDTH := 9.0
const HEIGHT := 11.0
const NEAR_Z := 12.0
const DOOR_Z := -20.0
## Cradle centres by seat (seat 1 right-front, 2 left-front, 3 right-back, 4 left-back).
const CRADLES := [Vector3(4.8, 0, 0), Vector3(-4.8, 0, 0), Vector3(4.8, 0, -8), Vector3(-4.8, 0, -8)]
const MECH_YAW := deg_to_rad(143.0)   ## right-side mechs face the aisle and the camera; left side mirrored
const ALERT_RAMP := 1.0                ## seconds for the clamps to open and the lights to change

var time_scale := 1.0
var own_environment := true            ## its own sky and ambient (the lab takes its own out); MechStage sets false, it has one
var models: Array[MechModel] = []

var state := "prep"
var beacon_speed := 2.5                ## rad/s
var work_energy := 2.2
var alert_dim := 0.3                   ## work-light energy multiplier in alert

var _t := 0.0
var _alert_k := 0.0                    ## 0 prep .. 1 alert, eased over ALERT_RAMP
var _work_lights: Array[OmniLight3D] = []
var _beacons: Array[Node3D] = []       ## pivots, each turning one red spot
var _beacon_lights: Array[SpotLight3D] = []
var _beacon_housings: Array[MeshInstance3D] = []
var _strobes: Array[OmniLight3D] = []
var _clamps: Array[Node3D] = []        ## pivots: closed at rotation 0, open swings up
var _clamp_sides: Array[float] = []
var _countdown: MeshInstance3D
var _door_lamps: Array[MeshInstance3D] = []
var _crew_root: Node3D
var _lab_crew := "1"
var _own_env: Environment


func _init() -> void:
	name = "HangarBay"


func _ready() -> void:
	if own_environment:
		var env := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.05, 0.055, 0.065)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.4, 0.43, 0.5)
		e.ambient_light_energy = 0.5
		e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		env.environment = e
		add_child(env)
		_own_env = e
	_build_shell()
	_build_door()
	for i in CRADLES.size():
		_build_cradle(CRADLES[i])
	for z: float in [5.5, -4.0, -12.5]:
		for side: float in [1.0, -1.0]:
			_build_rack(Vector3(side * (HALF_WIDTH - 0.6), 0, z))
	_build_lights()
	_crew_root = Node3D.new()
	_crew_root.name = "Crew"
	add_child(_crew_root)
	if own_environment and models.is_empty():
		_show_lab_crew()
	_apply_lights()


# --- Crew ---------------------------------------------------------------------------------------------

## Put these mechs in the cradles: [{head, chassis, loadout, name}] (at most four; extra entries are ignored).
func show_crew(entries: Array) -> Array[MechModel]:
	if _crew_root == null:
		_crew_root = Node3D.new()
		_crew_root.name = "Crew"
		add_child(_crew_root)
	for c in _crew_root.get_children():
		_crew_root.remove_child(c)
		c.queue_free()
	models.clear()
	for i in mini(entries.size(), CRADLES.size()):
		var e: Dictionary = entries[i]
		var m := MechModel.new()
		m.configure(str(e.get("head", "chicken")), str(e.get("chassis", "strider")), e.get("loadout", {}) as Dictionary)
		MechAccent.apply(m, str(e.get("accent", MechAccent.DEFAULT)))
		var at: Vector3 = CRADLES[i]
		m.position = at + Vector3(0, 0.4, 0)
		m.rotation.y = MECH_YAW * signf(at.x)
		m.time_scale = 0.0 if state == "alert" else 1.0
		_crew_root.add_child(m)
		models.append(m)
		if str(e.get("name", "")) != "":
			var tag := Label3D.new()
			tag.text = str(e["name"])
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.font_size = 64
			tag.pixel_size = 0.006
			tag.outline_size = 12
			tag.position = m.position + Vector3(0, tag_height(m), 0)
			_crew_root.add_child(tag)
	return models


## Height for a mech's name tag above its origin: the top of its meshes plus a gap (the crest, raised pods), so the
## tag never sits on the head. Falls back to a fixed height before the model has meshes.
static func tag_height(m: Node3D, gap: float = 0.7) -> float:
	var top := -INF
	var inv := m.global_transform.affine_inverse() if m.is_inside_tree() else Transform3D.IDENTITY
	var stack: Array[Node] = [m]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_inside_tree():
			continue
		var box := (inv * mi.global_transform) * mi.mesh.get_aabb()
		top = maxf(top, box.end.y)
	return top + gap if top > 0.5 else 5.8


## Where the camera stands for a crew of n, and what it looks at: [position, target].
static func camera_for(n: int) -> Array:
	if n <= 1:
		return [Vector3(-1.6, 4.4, 9.0), Vector3(3.6, 2.9, -0.6)]
	if n == 2:
		return [Vector3(0.0, 5.0, 11.5), Vector3(0.0, 3.0, -1.5)]
	return [Vector3(0.0, 6.0, 11.8), Vector3(0.0, 2.6, -5.0)]


# --- States -------------------------------------------------------------------------------------------

## 0 in prep .. 1 in full alert (eased); MechStage tints its ambient light with it.
func alert_amount() -> float:
	return _alert_k * _alert_k * (3.0 - 2.0 * _alert_k)


func set_alert(on: bool) -> void:
	state = "alert" if on else "prep"
	for m in models:
		m.time_scale = 0.0 if on else 1.0


func _process(delta: float) -> void:
	var dt := delta * time_scale
	_t += dt
	var goal := 1.0 if state == "alert" else 0.0
	_alert_k = move_toward(_alert_k, goal, dt / ALERT_RAMP)
	for i in _beacons.size():
		_beacons[i].rotation.y = _t * beacon_speed + float(i) * 1.3
	_apply_lights()


func _apply_lights() -> void:
	var k := alert_amount()
	if _own_env != null:
		_own_env.ambient_light_color = Color(0.4, 0.43, 0.5).lerp(Color(0.6, 0.25, 0.22), k)
		_own_env.ambient_light_energy = lerpf(0.5, 0.3, k)
	for l in _work_lights:
		l.light_energy = work_energy * lerpf(1.0, alert_dim, k)
	for l in _beacon_lights:
		l.light_energy = 16.0 * k
		l.visible = k > 0.01
	var blink := 1.0 if fmod(_t * 2.0, 1.0) < 0.35 else 0.0
	for l in _strobes:
		l.light_energy = 4.0 * k * blink
		l.visible = k > 0.01
	for i in _clamps.size():
		_clamps[i].rotation.z = -_clamp_sides[i] * deg_to_rad(75.0) * k
	if _countdown != null:
		var pulse := 0.6 + 0.4 * sin(_t * 6.0)
		_countdown.material_override = MechParts.mat(STROBE_AMBER if k > 0.5 else Color(0.25, 0.17, 0.05), 1.0, k > 0.5)
		_countdown.scale = Vector3(lerpf(1.0, maxf(0.05, 1.0 - fmod(_t, 3.0) / 3.0), k), 1.0 + 0.3 * pulse * k, 1.0)
	for h in _beacon_housings:
		h.material_override = MechParts.mat(ALERT_RED if k > 0.5 else Color(0.3, 0.06, 0.04), 1.0, k > 0.5)
	for lamp in _door_lamps:
		lamp.material_override = MechParts.mat(ALERT_RED if k > 0.5 and blink > 0.0 else Color(0.3, 0.06, 0.04), 1.0, k > 0.5)


# --- Set ----------------------------------------------------------------------------------------------

func _build_shell() -> void:
	var length := NEAR_Z - DOOR_Z
	var mid_z := (NEAR_Z + DOOR_Z) * 0.5
	add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0, 0.2, length), GUNMETAL_DARK, Vector3(0, -0.1, mid_z)))
	# Deck plate seams across the floor, and the aisle edges in hazard yellow.
	var z := NEAR_Z - 2.0
	while z > DOOR_Z:
		add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0, 0.02, 0.08), HAZARD_BLACK, Vector3(0, 0.01, z)))
		z -= 4.0
	for x: float in [-2.4, 2.4]:
		add_child(MechParts.box(Vector3(0.25, 0.03, length), HAZARD_YELLOW, Vector3(x, 0.015, mid_z)))
	# Walls, ceiling, ribs and girders.
	for side: float in [1.0, -1.0]:
		add_child(MechParts.box(Vector3(0.6, HEIGHT, length), GUNMETAL, Vector3(side * (HALF_WIDTH + 0.3), HEIGHT * 0.5, mid_z)))
		add_child(MechParts.box(Vector3(0.3, 2.2, length), GUNMETAL_DARK, Vector3(side * (HALF_WIDTH - 0.1), HEIGHT - 1.6, mid_z)))
		add_child(MechParts.box(Vector3(0.25, 0.5, length), HAZARD_YELLOW, Vector3(side * (HALF_WIDTH - 0.15), 0.25, mid_z)))
	add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0 + 1.2, 0.4, length), GUNMETAL_DARK, Vector3(0, HEIGHT + 0.2, mid_z)))
	# Near bulkhead wall behind the hangar camera, closing the bay when orbiting 360 degrees in the lab.
	add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0 + 1.2, HEIGHT, 0.6), GUNMETAL, Vector3(0, HEIGHT * 0.5, NEAR_Z + 0.3)))
	z = NEAR_Z - 1.0
	while z > DOOR_Z + 1.0:
		for side: float in [1.0, -1.0]:
			add_child(MechParts.box(Vector3(0.7, HEIGHT, 0.7), GUNMETAL_LIGHT, Vector3(side * (HALF_WIDTH - 0.3), HEIGHT * 0.5, z)))
		add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0, 0.8, 0.7), GUNMETAL_LIGHT, Vector3(0, HEIGHT - 0.4, z)))
		# Light strips between the girders.
		for x: float in [-3.0, 3.0]:
			add_child(_glow(Vector3(0.5, 0.1, 2.4), WORK_LIGHT, Vector3(x, HEIGHT - 0.05, z - 2.0)))
		z -= 4.0


func _build_door() -> void:
	var dz := DOOR_Z
	add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0 + 1.2, HEIGHT, 0.6), GUNMETAL, Vector3(0, HEIGHT * 0.5, dz - 0.3)))
	# Two armoured leaves with a seam, in a striped frame.
	for side: float in [1.0, -1.0]:
		add_child(MechParts.box(Vector3(3.9, 7.8, 0.5), GUNMETAL_LIGHT, Vector3(side * 1.98, 3.9, dz + 0.25)))
		add_child(MechParts.box(Vector3(2.6, 0.5, 0.2), GUNMETAL_DARK, Vector3(side * 1.98, 2.0, dz + 0.55)))
		add_child(MechParts.box(Vector3(2.6, 0.5, 0.2), GUNMETAL_DARK, Vector3(side * 1.98, 5.6, dz + 0.55)))
		_stripes(Vector3(side * 4.35, 0, dz + 0.3), Vector3(side * 4.35, 8.6, dz + 0.3), Vector3(0.7, 0, 0.5), 8)
		var lamp := MechParts.sphere(0.35, Color(0.3, 0.06, 0.04), Vector3(side * 5.4, 7.0, dz + 0.5), 8)
		add_child(lamp)
		_door_lamps.append(lamp)
		var strobe := OmniLight3D.new()
		strobe.light_color = STROBE_AMBER
		strobe.omni_range = 9.0
		strobe.position = Vector3(side * 5.4, 7.0, dz + 1.2)
		add_child(strobe)
		_strobes.append(strobe)
	add_child(MechParts.box(Vector3(0.08, 7.8, 0.1), HAZARD_BLACK, Vector3(0, 3.9, dz + 0.52)))
	_stripes(Vector3(-4.7, 8.95, dz + 0.3), Vector3(4.7, 8.95, dz + 0.3), Vector3(0, 0.7, 0.5), 10)
	_countdown = MechParts.box(Vector3(7.6, 0.25, 0.1), Color(0.25, 0.17, 0.05), Vector3(0, 8.2, dz + 0.55))
	add_child(_countdown)
	# The hazard band on the deck in front of the door.
	_stripes(Vector3(-HALF_WIDTH, 0.02, dz + 2.0), Vector3(HALF_WIDTH, 0.02, dz + 2.0), Vector3(0, 0.04, 2.2), 14)


func _build_cradle(at: Vector3) -> void:
	var s := signf(at.x)
	add_child(MechParts.box(Vector3(4.4, 0.4, 4.4), GUNMETAL_DARK, at + Vector3(0, 0.2, 0)))
	# A striped lip on the aisle side.
	_stripes(at + Vector3(-s * 2.2, 0.42, -2.2), at + Vector3(-s * 2.2, 0.42, 2.2), Vector3(0.3, 0.06, 0), 6)
	# The back frame on the wall side: two posts and a crossbar.
	var bx := at.x + s * 2.0
	for dz: float in [-1.7, 1.7]:
		add_child(MechParts.box(Vector3(0.5, 7.2, 0.5), GUNMETAL_LIGHT, Vector3(bx, 3.8, at.z + dz)))
		# A hydraulic clamp arm from each post toward the mech's hips; it swings up to open.
		var pivot := Node3D.new()
		pivot.position = Vector3(bx, 3.3, at.z + dz)
		add_child(pivot)
		var arm := MechParts.box(Vector3(1.9, 0.38, 0.38), GUNMETAL, Vector3(-s * 0.95, 0, 0))
		pivot.add_child(arm)
		pivot.add_child(MechParts.box(Vector3(0.3, 0.6, 0.5), HAZARD_YELLOW, Vector3(-s * 1.85, 0, 0)))
		pivot.rotation.y = -s * signf(dz) * 0.35
		_clamps.append(pivot)
		_clamp_sides.append(s)
	add_child(MechParts.box(Vector3(0.5, 0.5, 4.0), GUNMETAL_LIGHT, Vector3(bx, 7.4, at.z)))
	add_child(MechParts.cylinder(0.12, 6.0, HAZARD_BLACK, Vector3(bx + s * 0.3, 7.0, at.z), true, -1.0, 6))


func _build_rack(at: Vector3) -> void:
	add_child(MechParts.box(Vector3(0.9, 4.4, 3.0), GUNMETAL_DARK, at + Vector3(0, 2.2, 0)))
	for row in 3:
		var y := 0.5 + float(row) * 1.35
		add_child(MechParts.box(Vector3(1.1, 0.12, 3.0), GUNMETAL_LIGHT, at + Vector3(0, y - 0.06, 0)))
		for i in 5:
			var p := at + Vector3(-signf(at.x) * 0.15, y + 0.4, -1.1 + float(i) * 0.55)
			add_child(MechParts.cylinder(0.18, 0.8, BRASS, p, false, -1.0, 6))
			add_child(MechParts.cylinder(0.18, 0.3, BRASS, p + Vector3(0, 0.55, 0), false, 0.0, 6))


func _build_lights() -> void:
	var spots := [Vector3(4.0, 9.6, 2.0), Vector3(-4.0, 9.6, 2.0), Vector3(4.0, 9.6, -8.0), Vector3(-4.0, 9.6, -8.0),
		Vector3(0.0, 8.0, -15.0)]
	for i in spots.size():
		var l := OmniLight3D.new()
		l.light_color = WORK_LIGHT
		l.omni_range = 15.0
		l.position = spots[i]
		l.shadow_enabled = i < 2
		add_child(l)
		_work_lights.append(l)
	var fill := OmniLight3D.new()
	fill.light_color = Color(0.7, 0.75, 0.85)
	fill.light_energy = 1.0
	fill.omni_range = 16.0
	fill.position = Vector3(0, 6.0, 10.0)
	add_child(fill)
	for p: Vector3 in [Vector3(7.4, 10.0, 5.0), Vector3(-7.4, 10.0, 5.0), Vector3(7.4, 10.0, -11.0), Vector3(-7.4, 10.0, -11.0)]:
		var housing := MechParts.cylinder(0.35, 0.4, Color(0.3, 0.06, 0.04), p, false, -1.0, 8)
		add_child(housing)
		_beacon_housings.append(housing)
		var pivot := Node3D.new()
		pivot.position = p + Vector3(0, -0.3, 0)
		add_child(pivot)
		var spot := SpotLight3D.new()
		spot.light_color = ALERT_RED
		spot.spot_range = 22.0
		spot.spot_angle = 32.0
		spot.rotation = Vector3(deg_to_rad(-58.0), 0, 0)   # sweeping the deck below the pivot
		pivot.add_child(spot)
		_beacons.append(pivot)
		_beacon_lights.append(spot)


## Alternating yellow / black blocks from a to b. `thick` is each block's size across the run (the run axis is filled in).
func _stripes(a: Vector3, b: Vector3, thick: Vector3, n: int) -> void:
	var d := b - a
	var step := d / float(n)
	var size := thick + step.abs()
	for i in n:
		add_child(MechParts.box(size, HAZARD_YELLOW if i % 2 == 0 else HAZARD_BLACK, a + step * (float(i) + 0.5)))


func _glow(size: Vector3, c: Color, pos: Vector3) -> MeshInstance3D:
	var mi := MechParts.box(size, c, pos)
	mi.material_override = MechParts.mat(c, 1.0, true)
	return mi


# --- Lab ----------------------------------------------------------------------------------------------

func lab_params() -> Array:
	return [
		{"id": "beacon_speed", "label": "Beacon speed (rad/s)", "min": 0.5, "max": 6.0, "value": beacon_speed},
		{"id": "work_light", "label": "Work light energy", "min": 0.0, "max": 5.0, "value": work_energy},
		{"id": "alert_dim", "label": "Work light in alert (x)", "min": 0.0, "max": 1.0, "value": alert_dim},
	]


func set_lab_param(id: String, value: float) -> void:
	match id:
		"beacon_speed": beacon_speed = value
		"work_light": work_energy = value
		"alert_dim": alert_dim = value
	_apply_lights()


func lab_options() -> Array:
	return [
		{"id": "state", "label": "State", "choices": ["prep", "alert"], "value": state},
		{"id": "crew", "label": "Crew in the bay", "choices": ["1", "2", "3", "4"], "value": _lab_crew},
	]


func set_lab_option(id: String, value: String) -> void:
	match id:
		"state": set_alert(value == "alert")
		"crew":
			_lab_crew = value
			_show_lab_crew()


func _show_lab_crew() -> void:
	var heads := MechCatalog.HEAD_ORDER
	var entries: Array = []
	for i in clampi(int(_lab_crew), 1, 4):
		entries.append({"head": heads[i % heads.size()], "chassis": "strider", "name": "Pilot %d" % (i + 1),
			"accent": MechAccent.ORDER[i % MechAccent.ORDER.size()]})
	show_crew(entries)


func lab_focus() -> Vector3:
	return Vector3(3.6, 2.8, -0.5)   # seat 1's mech; the camera orbits inside the walls


func lab_radius() -> float:
	return 4.5   # the lab starts at twice this: still inside the walls and under the ceiling


func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true


## The preset views look at seat 1's mech from its front (it is turned MECH_YAW to face the aisle).
func lab_view_yaw() -> float:
	return -MECH_YAW
