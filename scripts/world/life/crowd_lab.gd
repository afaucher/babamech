class_name CrowdLab
extends Node3D
## Lab subject "crowd": the civilians on their own, on the REAL game systems (a small seeded CityDistrict with its
## AmbientLife: LifePlan timetables, LifeCrowd threats, LifeFigures drawing), so what the figures look and move like in
## the game is what this shows. Made to judge civilian animations and looks: it only talks to AmbientLife's public API
## (state_of / mode_of / pose_of / debug_person / tally / raise_threat / blast / sweep / add_pusher / set_quality) and its
## lab-only debug hooks (debug_force_state / debug_clear / debug_people_cap / debug_profile), never to LifeFigures, so it
## keeps working when the figure drawing is replaced.
##   .\lab.ps1 crowd
##   --scene res://scenes/lab.tscn --subject crowd --shot out.png --shot-after 4 --crowd camera=close,people=60,inspect=auto
## `--crowd k=v,...` presets any param or option (inspect=auto: the visible figure nearest the crowd focus).
## Cameras: lab (the lab's orbit round the crowd focus), close (2-3 figures filling the frame), group (10-15 m), street
## (along the sidewalk, crowd scale), mech_eye (10 m up in the street, the figures 30-80 m away, like the chase camera),
## top (straight-ish down), follow (tracks the inspected figure).
## State: "timetable" (normal life) or any AmbientLife.DEBUG_STATES key, forced on the whole crowd or on the inspected
## figure only (option "state_on"); a local presentation override that the simulation never sees.
## Threat: off | gunfire (three seeded sweeps through the point + a 2-strength threat) | blast (AmbientLife.blast with
## kill_r + a 3-strength threat) | mech (a stand-in pusher walking 50 m through the point at 3 m/s: proximity threats and
## kills on contact) at (threat_x, threat_s), alarm radius threat_r; once 0.5 s after it is chosen (or the "fire" button),
## then every repeat_s s (0: once). "reset" revives everyone (restores an empty snapshot) and rewinds the clock.

const PARAMS := [
	{"id": "seed", "label": "Seed", "min": 1.0, "max": 200.0},
	{"id": "people", "label": "People", "min": 1.0, "max": 200.0},
	{"id": "area", "label": "District side, m (density = people / area)", "min": 90.0, "max": 240.0},
	{"id": "time_scale", "label": "Life clock speed", "min": 0.0, "max": 4.0},
	{"id": "threat_x", "label": "Threat x (across, arc m)", "min": -120.0, "max": 120.0},
	{"id": "threat_s", "label": "Threat s (along, arc m)", "min": -120.0, "max": 120.0},
	{"id": "threat_r", "label": "Threat radius (alarm), m", "min": 5.0, "max": 120.0},
	{"id": "kill_r", "label": "Blast kill radius, m", "min": 0.0, "max": 12.0},
	{"id": "repeat_s", "label": "Repeat threat every s (0 = once)", "min": 0.0, "max": 30.0},
	{"id": "inspect", "label": "Inspect figure (-1 = none)", "min": -1.0, "max": 199.0},
]
const CAMERAS := ["lab", "close", "group", "street", "mech_eye", "top", "follow"]
const THREATS := ["off", "gunfire", "blast", "mech"]
const STATE_ON := ["crowd", "inspected"]
const QUALITIES := ["high", "medium", "low"]
const START_T := 900.0
const SETTLE_FRAMES := 6
const MECH_SPEED := 3.0
const MECH_PATH := 50.0
const FIRE_DELAY := 0.5

var time_scale := 1.0
var params := {"seed": 1.0, "people": 24.0, "area": 130.0, "time_scale": 1.0, "threat_x": 0.0, "threat_s": 0.0,
		"threat_r": 30.0, "kill_r": 4.0, "repeat_s": 0.0, "inspect": -1.0}
var options := {"camera": "lab", "state": "timetable", "state_on": "crowd", "threat": "off", "quality": "high",
		"lighting": "day"}
var district: CityDistrict
var life: AmbientLife
var readout: Label                ## the text block (top right, clear of the lab's side panel)

var _cam: Camera3D
var _viewer: Node3D               ## stands on the current camera: AmbientLife evaluates / draws near it (quality radius)
var _dirty := -1
var _rebuild_district := false
var _auto_inspect := false
var _threat_at_focus := false     ## --crowd threat_at=focus: the threat goes on the crowd focus once built
var _focus := Vector2.ZERO        ## arc (x, s): the busiest sidewalk point when built
var _n := Vector2(0, 1)           ## the outward normal of its block edge (into the street)
var _close_ids: Array[int] = []
var _close_at := Vector3.ZERO     ## smoothed close-up target (world)
var _next_fire := INF
var _shots := 0
var _mech: Node3D
var _mech_t0 := 0.0
var _mech_from := Vector2.ZERO
var _mech_dir := Vector2(0, 1)
var _threat_marker: Node3D
var _threat_rings: MeshInstance3D
var _pick_marker: Node3D
var _pick_label: Label3D
var _mat_cache: Dictionary = {}
var _us_sum := 0.0
var _us_n := 0
var _us_avg := 0.0
var _us_clock := 0.0
var _text_clock := 0.0
# shots (--crowd ui=hide hides the lab panel and the readout, markers=hide the threat / inspector markers;
# frames=<dir>,frame_n=N,frame_dt=s,frame_after=s saves N viewport PNGs every frame_dt wall seconds, then quits)
var _hide_ui := false
var _hide_markers := false
var _frames_dir := ""
var _frame_n := 0
var _frame_dt := 0.1
var _frame_wait := 2.0
var _frame_k := 0
var _frame_clock := 0.0
var _fire_delay := FIRE_DELAY     ## --crowd fire_after=s: the first threat this long after a (re)build (default 0.5 s)


func _init() -> void:
	var arg := Boot.arg_value(OS.get_cmdline_user_args(), "--crowd")
	for pair: String in arg.split(",", false):
		var kv := pair.split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "inspect" and kv[1] == "auto":
			_auto_inspect = true
		elif kv[0] == "threat_at" and kv[1] == "focus":
			_threat_at_focus = true
		elif kv[0] == "ui" and kv[1] == "hide":
			_hide_ui = true
		elif kv[0] == "markers" and kv[1] == "hide":
			_hide_markers = true
		elif kv[0] == "fire_after" and kv[1].is_valid_float():
			_fire_delay = float(kv[1])
		elif kv[0] == "frames":
			_frames_dir = kv[1]
		elif kv[0] == "frame_n" and kv[1].is_valid_int():
			_frame_n = int(kv[1])
		elif kv[0] == "frame_dt" and kv[1].is_valid_float():
			_frame_dt = float(kv[1])
		elif kv[0] == "frame_after" and kv[1].is_valid_float():
			_frame_wait = float(kv[1])
		elif params.has(kv[0]) and kv[1].is_valid_float():
			params[kv[0]] = float(kv[1])
		elif options.has(kv[0]):
			options[kv[0]] = kv[1]


func _ready() -> void:
	_cam = Camera3D.new()
	_cam.name = "CrowdCamera"
	_cam.fov = 50.0
	_cam.far = 900.0
	add_child(_cam)
	_viewer = Node3D.new()
	_viewer.name = "CrowdViewer"
	add_child(_viewer)
	var layer := CanvasLayer.new()
	layer.name = "CrowdReadout"
	add_child(layer)
	var box := PanelContainer.new()
	box.name = "ReadoutBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.72)
	sb.set_content_margin_all(10.0)
	box.add_theme_stylebox_override("panel", sb)
	layer.add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.offset_right = -10.0
	box.offset_top = 10.0
	readout = Label.new()
	readout.name = "Readout"
	readout.add_theme_font_size_override("font_size", 15)
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(readout)
	_rebuild_district = true
	rebuild()
	if _hide_ui:
		layer.visible = false
		_hide_lab_ui.call_deferred()


## Shots: the lab's own panels hidden (its CanvasLayers).
func _hide_lab_ui() -> void:
	var p := get_parent()
	if p == null:
		return
	for c in p.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = false


## frames=<dir>: a PNG every frame_dt wall seconds after frame_after s, frame_n of them, then quit (GIF strips).
func _frames_step(delta: float) -> void:
	if _frames_dir == "" or _frame_k >= _frame_n:
		return
	if _frame_wait > 0.0:
		_frame_wait -= delta
		return
	_frame_clock -= delta
	if _frame_clock > 0.0:
		return
	_frame_clock = _frame_dt
	DirAccess.make_dir_recursive_absolute(_frames_dir)
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/frame_%03d.png" % [_frames_dir, _frame_k])
	_frame_k += 1
	if _frame_k >= _frame_n:
		print("[crowd] saved %d frames to %s" % [_frame_n, _frames_dir])
		get_tree().quit()


## Build (or rebuild) the district when seed / area changed, then the crowd on it.
func rebuild() -> void:
	_dirty = -1
	var cfg := {"seed": params["seed"], "walls": 1.0, "size_x": params["area"], "size_s": params["area"]}
	if district == null:
		district = CityDistrict.new()
		district.name = "District"
		add_child(district)
		_rebuild_district = true
	if _rebuild_district:
		district.build(cfg)
		_rebuild_district = false
	district.rig.apply(str(options["lighting"]))
	if life == null:
		life = AmbientLife.new()
		life.debug_people_cap = int(PARAMS[1]["max"])
		life.debug_profile = true
		add_child(life)
	life.setup(district, int(params["people"]), -1, -1)
	life.bind_props(district.props)
	life.add_viewer(_viewer)
	_place_viewer()
	life.advance_to(START_T)
	_apply_quality()
	_drop_mech()
	_pick_focus()
	if _auto_inspect:
		_auto_inspect = false
		params["inspect"] = float(_nearest_visible(_focus))
	if _threat_at_focus:
		_threat_at_focus = false
		params["threat_x"] = round(_focus.x)
		params["threat_s"] = round(_focus.y)
	_apply_state()
	_build_markers()
	_next_fire = life.now + _fire_delay if options["threat"] != "off" else INF
	_apply_view()
	print("[crowd] seed %d area %d m  people %d (+%d riders)  plan %s  focus %s" % [int(params["seed"]), int(params["area"]),
			life.unit(0).plan.count, LifePlan.RIDERS, life.unit(0).plan.checksum(), str(_focus)])


func _process(delta: float) -> void:
	if _dirty >= 0:
		_dirty -= 1
		if _dirty < 0:
			rebuild()
		return
	if life == null or life.unit(0) == null:
		return
	life.time_scale = time_scale * float(params["time_scale"])
	_place_viewer()
	_threats()
	_step_mech()
	_update_view(delta)
	_update_pick()
	_measure(delta)
	_frames_step(delta)


# --- Lab contract ----------------------------------------------------------------------------------------

func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true


func lab_params() -> Array:
	return LabRegistry.param_rows(PARAMS, params)


func set_lab_param(id: String, value: float) -> void:
	if not params.has(id):
		return
	if id in ["seed", "people", "area", "inspect"]:
		value = round(value)
	if is_equal_approx(float(params[id]), value):
		return
	params[id] = value
	if life == null:
		return
	match id:
		"seed", "area":
			_rebuild_district = true
			_dirty = SETTLE_FRAMES
		"people":
			_dirty = SETTLE_FRAMES
		"inspect":
			_apply_state()
		"threat_x", "threat_s", "threat_r", "kill_r":
			_build_markers()
		"repeat_s":
			pass


func lab_options() -> Array:
	var states := ["timetable"]
	states.append_array(AmbientLife.debug_states())
	return [
		{"id": "camera", "label": "Camera", "choices": CAMERAS, "value": options["camera"]},
		{"id": "state", "label": "State (forced, lab only)", "choices": states, "value": options["state"]},
		{"id": "state_on", "label": "State applies to", "choices": STATE_ON, "value": options["state_on"]},
		{"id": "threat", "label": "Threat", "choices": THREATS, "value": options["threat"]},
		{"id": "quality", "label": "Quality", "choices": QUALITIES, "value": options["quality"]},
		{"id": "lighting", "label": "Lighting", "choices": CityLightRig.preset_ids(), "value": options["lighting"]},
	]


func set_lab_option(id: String, value: String) -> void:
	if not options.has(id):
		return
	options[id] = value
	if life == null or district == null:
		return
	match id:
		"camera": _apply_view()
		"state", "state_on": _apply_state()
		"threat":
			_drop_mech()
			_build_markers()
			_next_fire = life.now + _fire_delay if value != "off" else INF
		"quality": _apply_quality()
		"lighting": district.rig.apply(value)


func lab_actions() -> Array:
	return [{"id": "fire", "label": "Fire threat"}, {"id": "reset", "label": "Reset crowd"},
			{"id": "pick", "label": "Inspect nearest"}]


func do_lab_action(id: String) -> void:
	if life == null or life.unit(0) == null:
		return
	match id:
		"fire": _fire()
		"reset": reset_crowd()
		"pick":
			params["inspect"] = float(_nearest_visible(_focus))
			_apply_state()


func lab_focus() -> Vector3:
	if district == null:
		return Vector3(0.0, 1.0, 0.0)
	return _world(_focus.x, _focus.y, 1.0)


func lab_radius() -> float:
	return 9.0


# --- Crowd -----------------------------------------------------------------------------------------------

## Everyone alive again, every threat forgotten, the clock back at START_T (the real restore path, as a late joiner's
## empty snapshot).
func reset_crowd() -> void:
	_drop_mech()
	life.restore(PackedByteArray())
	life.advance_to(START_T)
	_apply_state()
	_next_fire = life.now + _fire_delay if options["threat"] != "off" else INF


func _apply_quality() -> void:
	var q := GraphicsQuality.from_name(str(options["quality"]))
	life.set_quality(q)
	if district.rig != null:
		district.rig.set_quality(q)


## The forced state (lab-only debug hook) on the crowd or on the inspected figure.
func _apply_state() -> void:
	life.debug_clear()
	var st := str(options["state"])
	if st == "timetable" or st == "":
		return
	if options["state_on"] == "crowd":
		life.debug_force_state(-1, st)
	elif _inspected() >= 0:
		life.debug_force_state(_inspected(), st)


## The inspected id, or -1 (none, or out of range).
func _inspected() -> int:
	var id := int(params["inspect"])
	if life == null or id < 0 or id >= life.count():
		return -1
	return id


func _nearest_visible(at: Vector2) -> int:
	var best := -1
	var bd := INF
	for id in life.count():
		if not life.visible_now(id):
			continue
		var q := life.debug_person(id)
		var d := Vector2(float(q["x"]), float(q["s"])).distance_to(at)
		if d < bd:
			bd = d
			best = id
	return best


## The sidewalk point (an outdoor person on a block) with the most people outdoors within 25 m, and its edge normal.
func _pick_focus() -> void:
	var pts: Array[Vector2] = []
	for id in life.count():
		if life.visible_now(id):
			var q := life.debug_person(id)
			pts.append(Vector2(float(q["x"]), float(q["s"])))
	var plan := district.plan
	var best_n := -100000
	_focus = Vector2.ZERO
	var inner := plan.extent.grow(-28.0)      # away from the end walls when possible (the cameras stand back 26-45 m)
	for q in pts:
		if _block_of(q) < 0:
			continue
		var n := 0 if inner.has_point(q) else -1000
		for r in pts:
			if r.distance_to(q) < 25.0:
				n += 1
		if n > best_n:
			best_n = n
			_focus = q
	if best_n <= -100000 and not plan.blocks.is_empty():
		var r0: Rect2 = plan.blocks[0]["rect"]
		_focus = Vector2(r0.end.x - 3.0, r0.get_center().y)
	var bi := _block_of(_focus)
	_n = Vector2(0, 1)
	if bi >= 0:
		var r: Rect2 = plan.blocks[bi]["rect"]
		var d: Array[float] = [r.end.x - _focus.x, _focus.x - r.position.x, r.end.y - _focus.y, _focus.y - r.position.y]
		var side := 0
		for k in 4:
			if d[k] < d[side]:
				side = k
		_n = CityPlan.SIDE_N[side]


func _block_of(at: Vector2) -> int:
	for bi in district.plan.blocks.size():
		if (district.plan.blocks[bi]["rect"] as Rect2).has_point(at):
			return bi
	return -1


func _world(x: float, s: float, h: float) -> Vector3:
	return district.global_transform * district.ring.arc_to_world(x, s, h)


func _place_viewer() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		_viewer.global_position = cam.global_position


# --- Threats ---------------------------------------------------------------------------------------------

func _threat_arc() -> Vector2:
	var e := district.plan.extent.grow(-2.0)
	return Vector2(clampf(float(params["threat_x"]), e.position.x, e.end.x), clampf(float(params["threat_s"]), e.position.y, e.end.y))


func _threats() -> void:
	if options["threat"] == "off" or life.now < _next_fire:
		return
	_fire()


## The threat now, through the real paths (as combat raises them), and when the next one is due.
func _fire() -> void:
	var kind := str(options["threat"])
	var at := _threat_arc()
	var w := _world(at.x, at.y, 1.0)
	var r := float(params["threat_r"])
	_shots += 1
	match kind:
		"gunfire":
			var rng := RandomNumberGenerator.new()
			rng.seed = int(params["seed"]) * 7919 + _shots
			var base := rng.randf() * TAU
			for k in 3:
				var a := base + (float(k) - 1.0) * 0.18
				var d := Vector2(sin(a), cos(a)) * 30.0
				life.sweep(_world(at.x - d.x, at.y - d.y, 1.0), _world(at.x + d.x, at.y + d.y, 1.0), 0.3, 0)
			life.raise_threat(w, r, 2)
		"blast":
			life.blast(w, float(params["kill_r"]), 0)
			life.raise_threat(w, r, 3)
		"mech":
			_start_mech(at)
		_:
			return
	var every := float(params["repeat_s"])
	_next_fire = life.now + every if every > 0.0 and kind != "off" else INF


func _start_mech(at: Vector2) -> void:
	_drop_mech()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params["seed"]) * 104729 + _shots
	var a := rng.randf() * TAU
	_mech_dir = Vector2(sin(a), cos(a))
	_mech_from = at - _mech_dir * MECH_PATH * 0.5
	_mech_t0 = life.now
	_mech = Node3D.new()
	_mech.name = "MechStandIn"
	var body := _box(Vector3(2.6, 7.0, 2.6), Vector3(0.0, 2.5, 0.0), Color(0.42, 0.45, 0.5))
	_mech.add_child(body)
	add_child(_mech)
	_mech.global_transform = _frame(_mech_from)
	life.add_pusher(_mech, 1.2, 0)


func _step_mech() -> void:
	if _mech == null:
		return
	var u := (life.now - _mech_t0) * MECH_SPEED
	if u > MECH_PATH:
		_drop_mech()
		return
	_mech.global_transform = _frame(_mech_from + _mech_dir * u)


func _drop_mech() -> void:
	if _mech == null:
		return
	if life != null:
		life.remove_pusher(_mech)
	remove_child(_mech)
	_mech.queue_free()
	_mech = null


## The upright floor frame at arc point `at` (feet at the origin, local Y up the ring), world space.
func _frame(at: Vector2) -> Transform3D:
	var p := district.ring.arc_to_world(at.x, at.y, 1.0)
	var up := district.ring.up_at(p)
	var fwd := (district.ring.arc_to_world(at.x, at.y + 1.0, 1.0) - p).normalized()
	var right := up.cross(fwd).normalized()
	return district.global_transform * Transform3D(Basis(right, up, right.cross(up).normalized()), p)


# --- Markers ---------------------------------------------------------------------------------------------

func _mat(c: Color) -> StandardMaterial3D:
	var key := c.to_html()
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_cache[key] = m
	return m


## A box mesh instance (layers set before it enters the tree).
func _box(size: Vector3, at: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = at
	mi.material_override = _mat(c)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = district.render_layer if district != null else 1
	return mi


## Ribbons on the floor following the ring: one ring per [centre arc, radius, width, colour] (district-local).
func _rings_mesh(rings: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for rg: Array in rings:
		var c: Vector2 = rg[0]
		var r := float(rg[1])
		var w := float(rg[2])
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var seg := clampi(int(r * 2.0), 24, 160)
		for i in seg:
			var a0 := TAU * float(i) / float(seg)
			var a1 := TAU * float(i + 1) / float(seg)
			var p: Array[Vector3] = []
			for q: Array in [[a0, r - w * 0.5], [a0, r + w * 0.5], [a1, r + w * 0.5], [a1, r - w * 0.5]]:
				var rr := maxf(float(q[1]), 0.0)
				p.append(district.ring.arc_to_world(c.x + cos(float(q[0])) * rr, c.y + sin(float(q[0])) * rr, 0.45))
			for k: int in [0, 1, 2, 0, 2, 3]:
				st.add_vertex(p[k])
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _mat(rg[3]))
	return mesh


func _build_markers() -> void:
	if _threat_marker == null:
		_threat_marker = Node3D.new()
		_threat_marker.name = "ThreatMarker"
		var post := _box(Vector3(0.25, 3.2, 0.25), Vector3(0.0, 1.6, 0.0), Color(0.95, 0.2, 0.15))
		_threat_marker.add_child(post)
		var cap := _box(Vector3(0.7, 0.7, 0.7), Vector3(0.0, 3.4, 0.0), Color(1.0, 0.55, 0.1))
		_threat_marker.add_child(cap)
		add_child(_threat_marker)
		_threat_rings = MeshInstance3D.new()
		_threat_rings.name = "ThreatRings"
		_threat_rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_threat_rings.layers = district.render_layer
		add_child(_threat_rings)
	if _pick_marker == null:
		_pick_marker = Node3D.new()
		_pick_marker.name = "InspectMarker"
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.55
		tm.outer_radius = 0.7
		ring.mesh = tm
		ring.position = Vector3(0.0, 0.08, 0.0)
		ring.material_override = _mat(Color(1.0, 0.85, 0.1))
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.layers = district.render_layer
		_pick_marker.add_child(ring)
		var cone := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.22
		cm.bottom_radius = 0.0
		cm.height = 0.45
		cone.mesh = cm
		cone.position = Vector3(0.0, 2.45, 0.0)
		cone.material_override = _mat(Color(1.0, 0.85, 0.1))
		cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cone.layers = district.render_layer
		_pick_marker.add_child(cone)
		_pick_label = Label3D.new()
		_pick_label.position = Vector3(0.0, 2.95, 0.0)
		_pick_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_pick_label.no_depth_test = true
		_pick_label.font_size = 40
		_pick_label.pixel_size = 0.006
		_pick_label.outline_size = 10
		_pick_label.modulate = Color(1.0, 0.92, 0.4)
		_pick_label.layers = district.render_layer
		_pick_marker.add_child(_pick_label)
		add_child(_pick_marker)
		_pick_marker.visible = false
	var on: bool = options["threat"] != "off"
	_threat_marker.visible = on and not _hide_markers
	_threat_rings.visible = on and not _hide_markers
	if not on:
		return
	var at := _threat_arc()
	_threat_marker.global_transform = _frame(at)
	var rings: Array = [[at, 1.2, 0.25, Color(1.0, 0.25, 0.15)],
			[at, float(params["threat_r"]), 0.4, Color(1.0, 0.35, 0.2, 0.45)]]
	if options["threat"] == "blast" and float(params["kill_r"]) > 0.0:
		rings.append([at, float(params["kill_r"]), 0.2, Color(1.0, 0.1, 0.1, 0.8)])
	_threat_rings.mesh = _rings_mesh(rings)
	_threat_rings.global_transform = district.global_transform


func _update_pick() -> void:
	var id := _inspected()
	if _pick_marker == null:
		return
	_pick_marker.visible = id >= 0 and life.visible_now(id) and not _hide_markers
	if _pick_marker.visible:
		var xf := life.pose_of(id)
		var up := district.ring.up_at(district.to_local(xf.origin))
		_pick_marker.global_transform = Transform3D(_frame_basis(up), xf.origin)
		_pick_label.text = "#%d %s" % [id, life.mode_of(id)]


func _frame_basis(up: Vector3) -> Basis:
	var u := (district.global_transform.basis * up).normalized()
	var f := Vector3(0, 0, 1)
	if absf(f.dot(u)) > 0.95:
		f = Vector3(1, 0, 0)
	var x := u.cross(f).normalized()
	return Basis(x, u, x.cross(u).normalized())


# --- Readout ---------------------------------------------------------------------------------------------

func _measure(delta: float) -> void:
	_us_sum += life.debug_us
	_us_n += 1
	_us_clock += delta
	if _us_clock >= 1.0:
		_us_avg = _us_sum / maxf(float(_us_n), 1.0)
		_us_sum = 0.0
		_us_n = 0
		_us_clock = 0.0
	_text_clock -= delta
	if _text_clock > 0.0:
		return
	_text_clock = 0.25
	readout.text = readout_text()


## The readout: totals, the state / animation histograms, the figures' draw calls, life's own time per frame, the
## threat, the forced state, then the inspected figure.
func readout_text() -> String:
	if life == null or life.unit(0) == null:
		return ""
	var t := life.tally()
	var states := {}
	var modes := {}
	var outdoors := 0
	var drawn := 0
	for id in life.count():
		var st := life.state_of(id)
		states[st] = int(states.get(st, 0)) + 1
		var md := life.mode_of(id)
		modes[md] = int(modes.get(md, 0)) + 1
		if md != "indoor":
			outdoors += 1
		if life.drawn_now(id):
			drawn += 1
	var mmis := 0
	var inst := 0
	for n in life.unit(0).figures.find_children("*", "GeometryInstance3D", true, false):
		if (n as GeometryInstance3D).is_visible_in_tree():
			mmis += 1
			if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
				inst += (n as MultiMeshInstance3D).multimesh.instance_count
	var lines: Array[String] = []
	lines.append("CROWD  seed %d  %d x %d m  people %d (+%d riders)  t %.1f" % [int(params["seed"]), int(params["area"]),
			int(params["area"]), life.unit(0).plan.count, LifePlan.RIDERS, life.now])
	lines.append("alive %d  down %d  outdoors %d  drawn %d  quality %s" % [life.count() - int(t["dead"]), int(t["dead"]),
			outdoors, drawn, options["quality"]])
	lines.append("states  " + _hist(states))
	lines.append("anims   " + _hist(modes))
	lines.append("figures %d draw calls (MMIs), %d instances" % [mmis, inst])
	lines.append("life update %.3f ms / frame (avg 1 s)" % (_us_avg / 1000.0))
	var at := _threat_arc()
	if options["threat"] != "off":
		lines.append("threat %s at (%.0f, %.0f)  r %.0f%s%s" % [options["threat"], at.x, at.y, float(params["threat_r"]),
				("  kill %.1f" % float(params["kill_r"])) if options["threat"] == "blast" else "",
				("  every %.0f s" % float(params["repeat_s"])) if float(params["repeat_s"]) > 0.0 else "  once"])
	if options["state"] != "timetable":
		lines.append("forced %s on %s" % [options["state"], options["state_on"]])
	var id := _inspected()
	if int(params["inspect"]) >= 0 and id < 0:
		lines.append("")
		lines.append("inspect #%d: no such figure (0..%d)" % [int(params["inspect"]), life.count() - 1])
	elif id >= 0:
		lines.append("")
		lines.append_array(inspect_lines(id))
	return "\n".join(lines)


func inspect_lines(id: int) -> Array[String]:
	var q := life.debug_person(id)
	var out: Array[String] = []
	if q.is_empty():
		return out
	out.append("#%d  %s / %s%s  %s%s" % [id, q["state"], q["mode"], ("  (forced %s)" % q["forced"]) if q["forced"] != "" else "",
			"alive" if q["alive"] else "DOWN", "" if q["visible"] else "  indoors (not drawn)"])
	out.append("timetable %s  speed %.2f m/s (walks %.2f)  heading %.0f deg" % [q["activity"], float(q["speed"]),
			float(q["cruise"]), float(q["heading"])])
	var home: Vector2 = q["home"]
	var dest: Vector2 = q["dest"]
	out.append("at (%.1f, %.1f)  home door %d (%.0f, %.0f) -> door %d (%.0f, %.0f)%s" % [float(q["x"]), float(q["s"]),
			int(q["door_a"]), home.x, home.y, int(q["door_d"]), dest.x, dest.y,
			("  bench %d" % int(q["bench"])) if int(q["bench"]) >= 0 else ""])
	var al: Dictionary = q["alarm"]
	if al.is_empty():
		out.append("panic: none")
	else:
		out.append("panic: %s at t %.1f, strength %d, refuge door %d, faces threat %.0f deg, last threat %.1f" % [al["kind"],
				float(al["t0"]), int(al["st"]), int(al["door"]), float(al["face"]), float(al["last"])])
	var dn: Dictionary = q["down"]
	if not dn.is_empty():
		out.append("down at t %.1f by src %d" % [float(dn["t"]), int(dn["src"])])
	out.append("variety: cloth %d  build %d  tall %d  period %.0f s  phase %.0f s%s" % [int(q["cloth"]), int(q["build"]),
			int(q["tall"]), float(q["period"]), float(q["phase"]), "  (pod rider)" if q["rider"] else ""])
	return out


static func _hist(h: Dictionary) -> String:
	var keys := h.keys()
	keys.sort()
	var parts: Array[String] = []
	for k: Variant in keys:
		parts.append("%s %d" % [str(k), int(h[k])])
	return "  ".join(parts)


# --- Views -----------------------------------------------------------------------------------------------

func _apply_view() -> void:
	var cam_id := str(options["camera"])
	district.set_ceiling_visible(cam_id != "lab" and cam_id != "top")
	district.set_backdrop_visible(cam_id != "lab")
	_close_ids.clear()
	if cam_id == "lab":
		_cam.clear_current(true)
		return
	if cam_id == "close":
		# the 2-3 outdoor figures nearest the focus (or the inspected one and its neighbours)
		var c := _focus
		if _inspected() >= 0 and life.visible_now(_inspected()):
			var q := life.debug_person(_inspected())
			c = Vector2(float(q["x"]), float(q["s"]))
		var near: Array = []
		for id in life.count():
			if life.visible_now(id):
				var q := life.debug_person(id)
				near.append([Vector2(float(q["x"]), float(q["s"])).distance_to(c), id])
		near.sort()
		for k in mini(3, near.size()):
			if float(near[k][0]) < 12.0 or k == 0:
				_close_ids.append(int(near[k][1]))
		_close_at = _close_target()
	_update_view(1.0)
	_cam.make_current()


func _close_target() -> Vector3:
	if _close_ids.is_empty():
		return _world(_focus.x, _focus.y, 0.9)
	var sum := Vector3.ZERO
	for id in _close_ids:
		sum += life.pose_of(id).origin
	return sum / float(_close_ids.size()) + _up_at(_focus) * 0.9


func _up_at(at: Vector2) -> Vector3:
	return (district.global_transform.basis * district.ring.up_at(district.ring.arc_to_world(at.x, at.y, 0.0))).normalized()


func _update_view(delta: float) -> void:
	var cam_id := str(options["camera"])
	if cam_id == "lab" or district == null:
		return
	var along := Vector2(-_n.y, _n.x)      # looking this way along the street, the focus sidewalk is on the right
	var e := district.plan.extent.grow(-4.0)
	var eye := Vector3.ZERO
	var target := Vector3(_focus.x, _focus.y, 0.9)
	var turn := -0.16          # what it looks at sits right of centre, clear of the lab's 380 px panel
	var pid := _inspected()
	match cam_id:
		"close":
			var c := _close_target()
			_close_at = _close_at.lerp(c, clampf(delta * 3.0, 0.0, 1.0))
			var spread := 0.0
			for id in _close_ids:
				spread = maxf(spread, life.pose_of(id).origin.distance_to(c))
			var arc := district.ring.world_to_arc(district.to_local(_close_at))
			var at := Vector2(arc.x, arc.y) + _n * (4.6 + spread * 1.1) + along * 1.5
			eye = Vector3(at.x, at.y, 1.8)
			target = Vector3(arc.x, arc.y, 1.15)
			turn = -0.2
		"group":
			var at := _focus + _n * 9.0 - along * 7.0
			eye = Vector3(at.x, at.y, 5.5)
		"street":
			var at := _focus + _n * 9.0 - along * 22.0     # over the middle of the street, above the street trees
			eye = Vector3(at.x, at.y, 7.5)
			var aim := _focus + along * 4.0
			target = Vector3(aim.x, aim.y, 1.0)
		"mech_eye":
			var at := _focus + _n * 9.0 - along * 45.0
			eye = Vector3(at.x, at.y, 10.0)
			var aim := _focus + along * 8.0
			target = Vector3(aim.x, aim.y, 1.0)
			turn = -0.12
		"top":
			var at := _focus - along * 8.0 + _n * 4.0
			eye = Vector3(at.x, at.y, 34.0)
			turn = 0.0
		"follow":
			if pid >= 0:
				var q := life.debug_person(pid)
				var h := deg_to_rad(float(q["heading"]))
				var fwd := Vector2(sin(h), cos(h))
				var p := Vector2(float(q["x"]), float(q["s"]))
				var at := p - fwd * 5.0 + Vector2(-fwd.y, fwd.x) * 1.5
				eye = Vector3(at.x, at.y, 2.4)
				target = Vector3(p.x + fwd.x * 2.0, p.y + fwd.y * 2.0, 0.9)
				turn = -0.24
			else:
				var at := _focus + _n * 9.0 + along * 5.0
				eye = Vector3(at.x, at.y, 4.5)
	eye.x = clampf(eye.x, e.position.x, e.end.x)
	eye.y = clampf(eye.y, e.position.y, e.end.y)
	var ring := district.ring
	var p0 := district.global_transform * ring.arc_to_world(eye.x, eye.y, eye.z)
	var q0 := district.global_transform * ring.arc_to_world(target.x, target.y, target.z)
	var up := (district.global_transform.basis * ring.up_at(district.to_local(p0))).normalized()
	var dir := q0 - p0
	if dir.length_squared() < 1e-6:
		return
	if absf(dir.normalized().dot(up)) > 0.98:
		up = (district.global_transform.basis * ring.arc_to_world(eye.x, eye.y + 1.0, eye.z) - p0).normalized()
	_cam.global_transform = Transform3D(Basis(up, turn) * Basis.looking_at(dir, up), p0)
