class_name CityLab
extends Node3D
## Lab subject "city": a pristine urban district generated from a seed on a ring deck (CityDistrict), with every
## generator setting as a slider and the lighting as a drop-down, to prove that relighting never touches the geometry.
##   .\lab.ps1 city
##   .\run.ps1 --scene res://scenes/lab.tscn --subject city --shot out.png --city camera=avenue,lighting=dusk,seed=7
## `--city k=v,...` presets any param or option below (for screenshots).
## Cameras: "lab" is the lab's own orbit camera, looking at the district from outside like a model (the ceiling and the
## backdrop hide themselves so you can see in); the others stand inside it at mech height.
## Props "demo": a box bulldozer drives down the first block's furnishing band at walking speed, toppling and kicking the
## street props (CityProps), and stands them all up again each lap. `--city props=demo,camera=props` watches it.
## Site "section": one whole deck (slider "deck") of the mission section planned from the same seed
## (CityDistrict.build_deck); the section then sets the size, radius, ceiling and walls, and those sliders do nothing.
## Site "stack": every deck of that section at once (CityStack); the deck slider picks the active deck (the one the
## daylight lights) and the deck the cameras stand on. Camera "ramp" stands at the top of the first ramp looking down it,
## "shaft" at the railing of the first open-air shaft; both fall back to "avenue" where there is none. On the lower deck:
## "ramp_foot" stands on the road 30 m past the first ramp's foot looking back up it (embankment, piers, ceiling opening),
## "ramp_under" beside it where it is 12-20 m up, looking along the underside and the row of piers (cockpit height, 9 m).
##   --city site=stack,seed=4,camera=ramp

const PARAMS := [
	{"id": "seed", "label": "Seed", "min": 1.0, "max": 200.0},
	{"id": "size_x", "label": "District width, across (m)", "min": 90.0, "max": 300.0},
	{"id": "size_s", "label": "District length, along the arc (m)", "min": 90.0, "max": 320.0},
	{"id": "block", "label": "Block size (m)", "min": 30.0, "max": 70.0},
	{"id": "density", "label": "Density (built lots)", "min": 0.5, "max": 1.0},
	{"id": "height", "label": "Height bias (low..tall)", "min": 0.0, "max": 1.0},
	{"id": "band_step", "label": "Roof band step (m)", "min": 3.5, "max": 8.0},
	{"id": "ceiling", "label": "Ceiling height (m)", "min": 28.0, "max": 60.0},
	{"id": "clearance", "label": "Roof to ceiling clearance (m)", "min": 8.0, "max": 18.0},
	{"id": "pillar_bay", "label": "Pillar spacing (m)", "min": 60.0, "max": 160.0},
	{"id": "atrium", "label": "Ceiling opening over the park (0/1)", "min": 0.0, "max": 1.0},
	{"id": "walls", "label": "Boundary walls (0/1)", "min": 0.0, "max": 1.0},
	{"id": "jump_gap", "label": "Roof hop gap (m)", "min": 3.0, "max": 10.0},
	{"id": "radius", "label": "Ring radius (m)", "min": 90.0, "max": 600.0},
	{"id": "w_apartment", "label": "Mix: terracotta apartments", "min": 0.0, "max": 2.0},
	{"id": "w_office", "label": "Mix: cream offices", "min": 0.0, "max": 2.0},
	{"id": "w_sage", "label": "Mix: sage panel blocks", "min": 0.0, "max": 2.0},
	{"id": "w_shops", "label": "Mix: shop rows", "min": 0.0, "max": 2.0},
	{"id": "deck", "label": "Section deck (site: section / stack)", "min": 0.0, "max": 4.0},
]
const CAMERAS := ["lab", "avenue", "street", "rooftop", "plaza", "pillar", "park", "gate", "props", "ramp", "shaft", "ramp_foot",
		"ramp_under"]
const SETTLE_FRAMES := 8         ## rebuild once the sliders have been still this long
const DOZER_SPEED := 12.0        ## m/s: a mech's walk
const DOZER_RADIUS := 1.6
const DOZER_RUN_OUT := 8.0       ## the lap starts and ends this far past the block's ends

var time_scale := 1.0
var params: Dictionary = {}
var options := {"lighting": "day", "camera": "lab", "ceiling": "auto", "backdrop": "auto", "props": "idle", "site": "alone"}
var district: CityDistrict      ## the district on show: on its own, or the stack's deck the cameras stand on
var stack: CityStack

var _alone: CityDistrict
var _cam: Camera3D
var _dirty := -1
var _dozer: CharacterBody3D
var _dozer_s := 0.0


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = float(CityPlan.DEFAULTS.get(p["id"], 0.0))
	var arg := Boot.arg_value(OS.get_cmdline_user_args(), "--city")
	for pair: String in arg.split(",", false):
		var kv := pair.split("=")
		if kv.size() != 2:
			continue
		if params.has(kv[0]) and kv[1].is_valid_float():
			params[kv[0]] = float(kv[1])
		elif options.has(kv[0]):
			options[kv[0]] = kv[1]


func _ready() -> void:
	_cam = Camera3D.new()
	_cam.name = "CityCamera"
	_cam.fov = 68.0
	_cam.far = 900.0
	add_child(_cam)
	rebuild()


func rebuild() -> void:
	_dirty = -1
	if options["site"] == "stack":
		if _alone != null:
			remove_child(_alone)
			_alone.queue_free()
			_alone = null
		if stack == null:
			stack = CityStack.new()
			stack.name = "Stack"
			add_child(stack)
		stack.build(SectionPlan.make({"seed": params["seed"]}), params)
		_pick_deck()
	else:
		if stack != null:
			remove_child(stack)
			stack.queue_free()
			stack = null
		if _alone == null:
			_alone = CityDistrict.new()
			_alone.name = "District"
			add_child(_alone)
		district = _alone
		if options["site"] == "section":
			var section := SectionPlan.make({"seed": params["seed"]})
			district.build_deck(section, clampi(int(params["deck"]), 0, section.deck_count - 1), params)
		else:
			district.build(params)
	_rig().apply(str(options["lighting"]))
	_apply_view()
	_apply_props()
	if stack != null:
		print("[city] seed %d  stack checksum %s  %s" % [int(params["seed"]), stack.checksum(), str(stack.stats)])
	else:
		print("[city] seed %d  checksum %s  %s" % [int(params["seed"]), district.plan.checksum(), str(district.stats)])


func _rig() -> CityLightRig:
	return stack.rig if stack != null else district.rig


## Stack: the deck slider picks the deck on show and the one the daylight lights.
func _pick_deck() -> void:
	var k := clampi(int(params["deck"]), 0, stack.decks.size() - 1)
	district = stack.decks[k]
	stack.set_active_deck(k)


func _districts() -> Array[CityDistrict]:
	if stack != null:
		return stack.decks
	var out: Array[CityDistrict] = [district]
	return out


func _process(_delta: float) -> void:
	if _dirty >= 0:
		_dirty -= 1
		if _dirty < 0:
			rebuild()


# --- Lab contract ----------------------------------------------------------------------------------------

func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true


func lab_params() -> Array:
	var out := []
	for p: Dictionary in PARAMS:
		var q := p.duplicate()
		q["value"] = params[p["id"]]
		out.append(q)
	return out


func set_lab_param(id: String, value: float) -> void:
	if not params.has(id):
		return
	if id == "seed" or id == "atrium" or id == "walls" or id == "deck":
		value = round(value)
	if is_equal_approx(float(params[id]), value):
		return
	params[id] = value
	if id == "deck" and stack != null and not stack.decks.is_empty():
		_pick_deck()       # every deck is built already: only the view and the daylight move
		_apply_view()
		_apply_props()
		return
	_dirty = SETTLE_FRAMES


func lab_options() -> Array:
	return [
		{"id": "lighting", "label": "Lighting", "choices": CityLightRig.preset_ids(), "value": options["lighting"]},
		{"id": "camera", "label": "Camera", "choices": CAMERAS, "value": options["camera"]},
		{"id": "ceiling", "label": "Ceiling", "choices": ["auto", "on", "off"], "value": options["ceiling"]},
		{"id": "backdrop", "label": "Backdrop", "choices": ["auto", "on", "off"], "value": options["backdrop"]},
		{"id": "props", "label": "Street props", "choices": ["idle", "demo"], "value": options["props"]},
		{"id": "site", "label": "Site", "choices": ["alone", "section", "stack"], "value": options["site"]},
	]


func set_lab_option(id: String, value: String) -> void:
	if not options.has(id):
		return
	options[id] = value
	if district == null or district.plan == null:
		return
	if id == "lighting":
		_rig().apply(value)      # lights only: no mesh is rebuilt
	elif id == "site":
		_dirty = SETTLE_FRAMES
	elif id == "props":
		_apply_props()
	else:
		_apply_view()


func lab_focus() -> Vector3:
	return Vector3(0.0, 8.0, 0.0)


func lab_radius() -> float:
	if district == null or district.plan == null:
		return 90.0
	return maxf(district.plan.extent.size.x, district.plan.extent.size.y) * 0.42


# --- Views -----------------------------------------------------------------------------------------------

func _apply_view() -> void:
	var inside: bool = options["camera"] != "lab"
	var ceil_opt := str(options["ceiling"])
	var back_opt := str(options["backdrop"])
	for d in _districts():
		d.set_ceiling_visible(ceil_opt == "on" or (ceil_opt == "auto" and inside))
		d.set_backdrop_visible(back_opt == "on" or (back_opt == "auto" and inside))
	if not inside:
		_cam.clear_current(true)
		return
	var on := district      # the deck the camera stands on (a ramp or shaft view may move it)
	var e := district.plan.extent
	var av := district.plan.avenue_x()
	var mid_x := (av.x + av.y) * 0.5
	var eye := Vector3(mid_x - 4.0, e.position.y + 8.0, 9.0)          # arc coordinates (x, s, h)
	var target := Vector3(mid_x, e.position.y + 90.0, 9.0)
	match str(options["camera"]):
		"street":
			var road: Dictionary = district.plan.roads_s[district.plan.roads_s.size() / 2]
			var mid := (float(road["a"]) + float(road["b"])) * 0.5
			eye = Vector3(e.position.x + 10.0, mid - 2.0, 7.0)
			target = Vector3(e.position.x + 80.0, mid + 1.0, 8.0)
		"rooftop":
			eye = Vector3(av.y + 6.0, e.position.y + 2.0, district.plan.p("ceiling") - 9.0)
			target = Vector3(mid_x, e.position.y + 80.0, 10.0)
		"plaza":
			for b: Dictionary in district.plan.buildings:
				if b["style"] == "civic":
					var c: Vector2 = b["center"]
					var n: Vector2 = CityPlan.SIDE_N[int(b["front"])]
					eye = Vector3(c.x + n.x * 50.0 + absf(n.y) * 10.0, c.y + n.y * 50.0 + absf(n.x) * 10.0, 10.0)
					target = Vector3(c.x, c.y, 7.0)
		"gate":        # down the avenue to the far bulkhead
			eye = Vector3(mid_x - 5.0, e.end.y - 75.0, 9.0)
			target = Vector3(mid_x, e.end.y, 9.0)
		"pillar":      # up a pillar tower to where it meets the ceiling
			for b: Dictionary in district.plan.buildings:
				if b["pillar"]:
					var at := Vector2(b["core"]["x"], b["core"]["s"])
					eye = Vector3(at.x - signf(at.x) * 40.0, at.y - 34.0, 8.0)
					target = Vector3(at.x, at.y, district.plan.p("ceiling") - 12.0)
					break
		"props":       # along the bulldozer's lane, from just before the block
			var lane := _dozer_lane()
			eye = Vector3(lane.x - 7.0, lane.y - 6.0, 5.0)
			target = Vector3(lane.x, lane.y + 30.0, 1.0)
		"park":        # across the park, looking up at the ceiling above it
			for b: Dictionary in district.plan.blocks:
				if b["kind"] == "park":
					var r: Rect2 = b["rect"]
					eye = Vector3(r.get_center().x - signf(r.get_center().x) * (r.size.x * 0.5 + 16.0), r.position.y - 6.0, 9.0)
					target = Vector3(r.get_center().x, r.get_center().y, 20.0)
		"ramp":        # on the upper deck at the top of the first ramp, looking down it
			var found := _first_ramp_top()
			if not found.is_empty():
				on = found["district"]
				var r: Dictionary = found["ramp"]
				var down := signf(float(r["s_foot"]) - float(r["s_top"]))
				var mid := (float(r["x0"]) + float(r["x1"])) * 0.5
				eye = Vector3(mid, float(r["s_top"]) - down * 12.0, 7.0)
				target = Vector3(mid, float(r["s_top"]) + down * 60.0, -10.0)
		"ramp_foot", "ramp_under":     # on the lower deck, looking back up at the first ramp's bottom part
			var found := _first_ramp("bottom")
			if not found.is_empty():
				on = found["district"]
				var r: Dictionary = found["ramp"]
				var up := signf(float(r["s_top"]) - float(r["s_foot"]))
				var mid := (float(r["x0"]) + float(r["x1"])) * 0.5
				var lane := on.plan.avenue_x()
				var side := signf((lane.x + lane.y) * 0.5 - mid)     # toward the avenue: road beside the ramp
				if side == 0.0:
					side = 1.0
				if str(options["camera"]) == "ramp_foot":
					eye = Vector3(mid + side * 21.0, float(r["s_foot"]) - up * 30.0, 9.0)
					target = Vector3(mid, CityPlan.ramp_s(r, 16.0), 9.0)
				else:
					eye = Vector3(mid + side * 14.0, CityPlan.ramp_s(r, 15.0), 9.0)
					target = Vector3(mid + side * 2.0, CityPlan.ramp_s(r, 30.0), 17.0)
		"shaft":       # at the railing of the first open-air shaft, looking down it
			var found := _first_shaft()
			if not found.is_empty():
				on = found["district"]
				var o: Rect2 = found["rect"]
				eye = Vector3(o.get_center().x, o.position.y - 2.0, 5.0)
				target = Vector3(o.get_center().x, o.get_center().y, -30.0)
	if stack != null:
		stack.set_active_deck(stack.decks.find(on))
	var ring := on.ring
	var p := on.global_transform * ring.arc_to_world(eye.x, eye.y, eye.z)
	var q := on.global_transform * ring.arc_to_world(target.x, target.y, target.z)
	_cam.global_transform = Transform3D(Basis.looking_at(q - p, on.global_transform.basis * ring.up_at(on.to_local(p))), p)
	_cam.make_current()


## The top part of the first ramp: on the deck on show if one leaves it, else on any deck of the stack. {district, ramp}
func _first_ramp_top() -> Dictionary:
	return _first_ramp("top")


## The first ramp part with `role` ("top" or "bottom"): on the deck on show if it has one, else on any deck of the stack.
func _first_ramp(role: String) -> Dictionary:
	var list: Array[CityDistrict] = [district]
	list.append_array(_districts())
	for d in list:
		for r: Dictionary in d.plan.ramps:
			if r["role"] == role:
				return {"district": d, "ramp": r}
	return {}


## The first open-air shaft cut in a floor, found the same way. {district, rect}
func _first_shaft() -> Dictionary:
	var list: Array[CityDistrict] = [district]
	list.append_array(_districts())
	for d in list:
		var sec := d.plan.section
		if sec == null:
			continue
		for ci in sec.connectors.size():
			if sec.connectors[ci]["kind"] == "shaft" and sec.is_hole(ci, d.plan.deck):
				return {"district": d, "rect": sec.connector_rect(ci, d.plan.deck)}
	return {}


# --- Props demo ------------------------------------------------------------------------------------------

## The bulldozer's lane along the first block's furnishing band: Vector3(x, start s, end s) in arc coordinates.
func _dozer_lane() -> Vector3:
	var r: Rect2 = district.plan.blocks[0]["rect"]
	return Vector3(r.position.x + 1.2, r.position.y - DOZER_RUN_OUT, r.end.y + DOZER_RUN_OUT)


func _apply_props() -> void:
	if district == null or district.props == null:
		return
	if options["props"] != "demo":
		if _dozer != null:
			_dozer.queue_free()
			_dozer = null
		return
	if _dozer == null:
		_dozer = CharacterBody3D.new()
		_dozer.name = "Bulldozer"
		_dozer.collision_layer = 0
		_dozer.collision_mask = 0
		var mat := StandardMaterial3D.new()
		mat.albedo_color = CityPalette.C["marking_yellow"]
		for part: Array in [[Vector3(0, 1.1, 0), Vector3(2.6, 1.6, 3.4)], [Vector3(0, 2.3, -0.4), Vector3(1.8, 1.0, 1.6)],
				[Vector3(0, 0.6, 2.0), Vector3(3.2, 1.0, 0.25)]]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = part[1]
			bm.material = mat
			mi.mesh = bm
			mi.position = part[0]
			_dozer.add_child(mi)
		add_child(_dozer)
	district.props.add_pusher(_dozer, DOZER_RADIUS)
	_dozer_s = _dozer_lane().y
	district.props.restore(PackedByteArray())
	_place_dozer(0.0)


## Drives the bulldozer along its lane (blade at local +Z, toward +s); each lap stands the props up again.
func _physics_process(delta: float) -> void:
	if _dozer == null or district == null or district.plan == null:
		return
	var lane := _dozer_lane()
	_dozer_s += DOZER_SPEED * delta
	if _dozer_s > lane.z:
		_dozer_s = lane.y
		district.props.restore(PackedByteArray())
	_place_dozer(DOZER_SPEED)


func _place_dozer(speed: float) -> void:
	var ring := district.ring
	var p := ring.arc_to_world(_dozer_lane().x, _dozer_s, CityPlan.CURB_H)
	_dozer.global_transform = district.global_transform * Transform3D(CityGeo.frame_basis(ring, _dozer_s), p)
	_dozer.velocity = district.global_transform.basis * ring.tangent_at(p) * speed
