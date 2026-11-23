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
## "ramp_head" stands on the first ramp just past its head at a mech's eye (8 m) looking down it; "ramp_cut" looks across
## the cut from the side at the first cross road past the head (where the too-low first bridge was). `--city nudge=m`
## (command line only) moves every camera's eye m metres along x and s: a second frame of a view, as z-fighting shimmers.
##   --city site=stack,seed=4,camera=ramp
## Option "quality" (high / medium / low): CityQuality's draw level (CityStack.set_quality; a district's own rig only
## changes its lights and extras). `--city site=stack,camera=avenue,quality=low`.
## Side walls (docs/design/city-styles.md "Side walls: vertical farm"): "farm_far" looks across the district at the first
## farm wall from 12 m up, "farm_near" stands at mech eye height on the lane beside it looking along it, "farm_gate" faces
## the first gate in it. With no farm wall they use a window wall (the hull's, `walls=1` on its own), else the avenue.
##   --city site=section,seed=1,deck=0,camera=farm_far
## Mission world (MissionLab, site "stack" only): option "mission" puts MissionWorld's doors, flag, relay and portal in the
## stack and loops them; "mission_phase" pins one look; cameras mission_gate / _lift / _flag / _asset / _portal.
##   --city site=stack,seed=1,mission=all,mission_phase=warn,camera=mission_gate
## Downtown (docs/design/city-downtown.md): param "downtown" is the zone's share of the blocks on its own; on a section
## or stack 0 leaves the zone to the seed (CityPlan.for_deck), more forces that share. Cameras (the first deck with a
## zone): downtown_avenue (10 m up along a street through the zone), downtown_perch (on a 6.5 m podium roof at a mech's
## eye, across the block), downtown_plaza (ground, mech eye, at a plaza or corner cut), downtown_arcade (along an arcade's
## gallery), downtown_top (from above over the zone, the ceiling and the decks above hidden).
##   --city downtown=0.5,camera=downtown_avenue       --city site=stack,seed=4,camera=downtown_top

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
	{"id": "downtown", "label": "Downtown zone share (section / stack: 0 = by seed)", "min": 0.0, "max": 1.0},
]
const CAMERAS := ["lab", "avenue", "street", "rooftop", "plaza", "pillar", "park", "gate", "props", "ramp", "shaft", "ramp_foot",
		"ramp_under", "ramp_head", "ramp_cut", "farm_far", "farm_near", "farm_gate", "mission_gate", "mission_lift", "mission_flag", "mission_flag_far",
		"mission_asset", "mission_portal", "downtown_avenue", "downtown_perch", "downtown_plaza", "downtown_arcade", "downtown_top"]
const SETTLE_FRAMES := 8         ## rebuild once the sliders have been still this long
const DOZER_SPEED := 12.0        ## m/s: a mech's walk
const DOZER_RADIUS := 1.6
const DOZER_RUN_OUT := 8.0       ## the lap starts and ends this far past the block's ends

var time_scale := 1.0
var params: Dictionary = {}
var options := {"lighting": "day", "camera": "lab", "ceiling": "auto", "backdrop": "auto", "props": "idle", "site": "alone",
		"quality": "high", "mission": "off", "mission_phase": "loop"}
var district: CityDistrict      ## the district on show: on its own, or the stack's deck the cameras stand on
var stack: CityStack
var mission_lab := MissionLab.new()     ## options mission / mission_phase and the mission cameras (MissionLab)

var _alone: CityDistrict
var _cam: Camera3D
var _dirty := -1
var _dozer: CharacterBody3D
var _dozer_s := 0.0
var _hid_decks := false         ## downtown_top hid the other decks of the stack
var _nudge := 0.0               ## --city nudge=m (command line only): every camera's eye moves this far along x and s, for a
                                ## second frame of the same view (z-fighting shimmers as the camera moves)


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
		elif kv[0] == "nudge" and kv[1].is_valid_float():
			_nudge = float(kv[1])
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
		stack.build(SectionPlan.make({"seed": params["seed"]}), _deck_overrides())
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
			district.build_deck(section, clampi(int(params["deck"]), 0, section.deck_count - 1), _deck_overrides())
		else:
			district.build(params)
	_rig().apply(str(options["lighting"]))
	_apply_quality()
	mission_lab.apply(self)
	_apply_view()
	_apply_props()
	if stack != null:
		print("[city] seed %d  stack checksum %s  %s" % [int(params["seed"]), stack.checksum(), str(stack.stats)])
	else:
		print("[city] seed %d  checksum %s  %s" % [int(params["seed"]), district.plan.checksum(), str(district.stats)])


## The params as a section deck's overrides: downtown 0 is left out (the deck rolls its own zone by seed).
func _deck_overrides() -> Dictionary:
	var out := params.duplicate()
	if float(out.get("downtown", 0.0)) <= 0.0:
		out.erase("downtown")
	return out


## Option "quality" (CityQuality, local presentation): the stack's decks, lights and ranges, or a district's own rig.
func _apply_quality() -> void:
	var q := CityQuality.from_name(str(options["quality"]))
	if stack != null:
		stack.set_quality(q)
	elif district != null and district.rig != null:
		district.rig.set_quality(q)


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


func _process(delta: float) -> void:
	mission_lab.tick(delta * time_scale)
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
		{"id": "quality", "label": "Draw quality (CityQuality)", "choices": ["high", "medium", "low"], "value": options["quality"]},
		{"id": "mission", "label": "Mission world (site: stack)", "choices": MissionLab.MODES, "value": options["mission"]},
		{"id": "mission_phase", "label": "Mission look", "choices": MissionLab.PHASES, "value": options["mission_phase"]},
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
	elif id == "quality":
		_apply_quality()
	elif id == "mission" or id == "mission_phase":
		mission_lab.apply(self)
		_apply_view()
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
	var top_view: bool = options["camera"] == "downtown_top"     # from above: no ceiling, no deck above in the way
	var dv := _downtown_view(str(options["camera"])) if str(options["camera"]).begins_with("downtown_") else {}
	for d in _districts():
		d.set_ceiling_visible(ceil_opt == "on" or (ceil_opt == "auto" and inside and not top_view))
		d.set_backdrop_visible(back_opt == "on" or (back_opt == "auto" and inside))
		if top_view and not dv.is_empty():
			d.visible = d == dv["district"]
		elif _hid_decks:
			d.visible = true      # the quality pass (set_active_deck below) hides again what it hides
	_hid_decks = top_view and not dv.is_empty()
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
		"ramp_head", "ramp_cut":      # the first ramp's head on the upper deck: down the ramp from a mech's eye; across the cut
			var found := _first_ramp_top()
			if not found.is_empty():
				on = found["district"]
				var r: Dictionary = found["ramp"]
				var top := float(r["s_top"])
				var down := signf(float(r["s_foot"]) - top)
				var mid := (float(r["x0"]) + float(r["x1"])) * 0.5
				if str(options["camera"]) == "ramp_head":
					eye = Vector3(mid, top + down * 3.0, CityPlan.ramp_height(r, top + down * 3.0) + 8.0)
					target = Vector3(mid, top + down * 95.0, -12.0)
				else:
					# The first cross road past the head (where the first bridge over the cut used to be), from the side.
					var line := top + down * 90.0
					for road: Dictionary in on.plan.roads_s:
						var c := (float(road["a"]) + float(road["b"])) * 0.5
						if (c - top) * down > 20.0 and absf(c - top) < absf(line - top):
							line = c
					var lane := on.plan.avenue_x()
					var side := signf((lane.x + lane.y) * 0.5 - mid)
					if side == 0.0:
						side = 1.0
					eye = Vector3(mid + side * 30.0, line - down * 22.0, 9.0)
					target = Vector3(mid, line, -3.0)
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
		"farm_far", "farm_near", "farm_gate":     # at the first farm wall (else a window wall)
			var w := _farm_wall()
			if not w.is_empty():
				var side := int(w["side"])
				var at := float(w["at"])
				var inward := -1.0 if side % 2 == 0 else 1.0
				var u0 := e.position.x if side >= 2 else e.position.y
				var u1 := e.end.x if side >= 2 else e.end.y
				var um := (u0 + u1) * 0.5
				var longest := 0.0
				for sp: Array in CityStreets.wall_spans(u0, u1, w["gates"]):     # the middle of the longest stretch without a gate
					if float(sp[1]) - float(sp[0]) > longest:
						longest = float(sp[1]) - float(sp[0])
						um = (float(sp[0]) + float(sp[1])) * 0.5
				var cam := str(options["camera"])
				# Look along the wall the way that puts it on the right of the picture (the lab panel is on the left).
				var dir := 1.0 if side == 1 or side == 2 else -1.0
				# (distance off the wall, along it, height) for the eye and the target
				var ev := Vector3(95.0, um - dir * 70.0, 12.0)
				var tv := Vector3(0.0, um + dir * 35.0, 20.0)
				if cam == "farm_near":
					ev = Vector3(7.0, um - dir * 20.0, 8.0)
					tv = Vector3(2.0, um + dir * 30.0, 6.5)
				elif cam == "farm_gate" and not (w["gates"] as Array).is_empty():
					var g: Dictionary = w["gates"][0]
					var gm := (float(g["a"]) + float(g["b"])) * 0.5
					ev = Vector3(30.0, gm - dir * 24.0, 8.0)
					tv = Vector3(0.0, gm + dir * 4.0, 12.0)
				if side >= 2:
					eye = Vector3(ev.y, at + inward * ev.x, ev.z)
					target = Vector3(tv.y, at + inward * tv.x, tv.z)
				else:
					eye = Vector3(at + inward * ev.x, ev.y, ev.z)
					target = Vector3(at + inward * tv.x, tv.y, tv.z)
		"downtown_avenue", "downtown_perch", "downtown_plaza", "downtown_arcade", "downtown_top":
			if not dv.is_empty():
				on = dv["district"]
				eye = dv["eye"]
				target = dv["target"]
		"mission_gate", "mission_lift", "mission_flag", "mission_flag_far", "mission_asset", "mission_portal":     # MissionLab
			var mv := mission_lab.view(str(options["camera"]))
			if not mv.is_empty():
				on = mv["district"]
				eye = mv["eye"]
				target = mv["target"]
		"shaft":       # at the railing of the first open-air shaft, looking down it
			var found := _first_shaft()
			if not found.is_empty():
				on = found["district"]
				var o: Rect2 = found["rect"]
				eye = Vector3(o.get_center().x, o.position.y - 2.0, 5.0)
				target = Vector3(o.get_center().x, o.get_center().y, -30.0)
	if stack != null:
		stack.set_active_deck(stack.decks.find(on))
	eye += Vector3(_nudge, _nudge, 0.0)
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


## A downtown camera (docs/design/city-downtown.md) on the deck on show if it has a zone, else the first deck that does:
## {district, eye, target} in arc coordinates (x, s, h), framed right of the lab's panel; {} when no deck has a zone.
func _downtown_view(cam: String) -> Dictionary:
	var list: Array[CityDistrict] = [district]
	list.append_array(_districts())
	for d in list:
		if d == null or d.plan == null:
			continue
		var plan := d.plan
		var zone := plan.downtown_blocks()
		if zone.is_empty():
			continue
		var box: Rect2 = plan.blocks[zone[0]]["rect"]
		for bi in zone:
			box = box.merge(plan.blocks[bi]["rect"])
		var c := box.get_center()
		# The overview: from above the zone, looking down at it (the default when a view finds nothing to stand at).
		var eye := Vector3(c.x, box.position.y - box.size.y * 0.25, 125.0)
		var target := Vector3(c.x, c.y + box.size.y * 0.05, 0.0)
		match cam:
			"downtown_avenue":
				var v := _downtown_street(plan, zone)
				if not v.is_empty():
					eye = v["eye"]
					target = v["target"]
			"downtown_perch":
				for bi in zone:
					var found := false
					for i in plan.buildings_in(bi):
						var b: Dictionary = plan.buildings[i]
						if b["style"] != "tower" or not (b["base"] in ["podium", "twin", "corner", "stepped"]):
							continue
						var t: Dictionary = b["tiers"][0]
						var r := plan.tier_rect(i, t).grow(-2.5)
						var shaft := Vector2.ZERO
						for u: Dictionary in b["tiers"]:
							if str(u.get("kind", "")) == "tower":
								shaft = plan.tier_rect(i, u).get_center()
						# The roof's corner farthest from its shaft, looking along the roof's longer edge past it over the
						# block's other roofs.
						var at := r.position
						for cn: Vector2 in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
							if cn.distance_to(shaft) > at.distance_to(shaft):
								at = cn
						var along := Vector2(signf(r.get_center().x - at.x), 0.0) if r.size.x >= r.size.y else Vector2(0.0, signf(r.get_center().y - at.y))
						eye = Vector3(at.x, at.y, float(t["y1"]) + CityPlan.MECH_TOP)
						var far := at + along * 70.0
						target = Vector3(far.x, far.y, 9.0)
						found = true
						break
					if found:
						break
			"downtown_plaza":
				var v := _downtown_plaza(plan, zone)
				if not v.is_empty():
					eye = v["eye"]
					target = v["target"]
			"downtown_arcade":
				for i in plan.buildings.size():
					var b: Dictionary = plan.buildings[i]
					if b["style"] != "tower" or b["base"] != "arcade" or not zone.has(int(plan.lots[b["lot"]]["block"])):
						continue
					var g: Rect2 = b["dt"]["gallery"]
					var f := int(b["dt"]["front"])
					var axis := 0 if f < 2 else 1           # the street's normal
					var out := 1.0 if f % 2 == 0 else -1.0
					var line := (g.end[axis] if f % 2 == 0 else g.position[axis]) + out * 6.0
					var mid := g.get_center()[axis] + out * 1.0
					var a := Vector2.ZERO
					var bb := Vector2.ZERO
					a[axis] = line
					a[1 - axis] = g.position[1 - axis] + 2.0
					bb[axis] = mid
					bb[1 - axis] = g.end[1 - axis] + 6.0
					eye = Vector3(a.x, a.y, 5.0)
					target = Vector3(bb.x, bb.y, 4.5)
					break
		return {"district": d, "eye": eye, "target": _right_of_panel(eye, target)}
	return {}


## Along the road with the most zone blocks beside it: 10 m up, from just before the zone to past its far end.
func _downtown_street(plan: CityPlan, zone: Array[int]) -> Dictionary:
	var best := {}
	var best_n := 0
	for axis in 2:
		var roads: Array = plan.roads_x if axis == 0 else plan.roads_s
		for road: Dictionary in roads:
			if road["kind"] == "spine":      # ramps and the rail run down it: a cross street or arterial reads better
				continue
			var n := 0
			var lo := INF
			var hi := -INF
			var sides := {}
			for bi in zone:
				var r: Rect2 = plan.blocks[bi]["rect"]
				var before := absf(r.end[axis] - float(road["a"])) < 0.5
				if before or absf(r.position[axis] - float(road["b"])) < 0.5:
					n += 1 if sides.has(before) else 3     # zone blocks on both sides first
					sides[before] = true
					lo = minf(lo, r.position[1 - axis])
					hi = maxf(hi, r.end[1 - axis])
			if n > best_n:
				best_n = n
				var mid := (float(road["a"]) + float(road["b"])) * 0.5
				var e := Vector2.ZERO
				var t := Vector2.ZERO
				e[axis] = mid - 2.0
				e[1 - axis] = lo - 22.0
				t[axis] = mid + 1.0
				t[1 - axis] = hi + 10.0
				best = {"eye": Vector3(e.x, e.y, 10.0), "target": Vector3(t.x, t.y, 15.0)}
	return best


## At a plaza base's plaza from the street at a mech's eye (else at a corner cut's plaza, from its street corner).
func _downtown_plaza(plan: CityPlan, zone: Array[int]) -> Dictionary:
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if b["style"] != "tower" or b["base"] != "plaza" or not zone.has(int(plan.lots[b["lot"]]["block"])):
			continue
		var lot: Dictionary = plan.lots[b["lot"]]
		var r: Rect2 = lot["rect"]
		for side in 4:
			if not lot["faces"][side]:
				continue
			var n: Vector2 = CityPlan.SIDE_N[side]
			var edge := r.get_center() + Vector2(n.x * r.size.x, n.y * r.size.y) * 0.5
			var e := edge + n * 16.0 + Vector2(n.y, n.x) * 6.0
			var c: Vector2 = b["center"]
			return {"eye": Vector3(e.x, e.y, CityPlan.MECH_TOP), "target": Vector3(c.x, c.y, 9.0)}
	for bi in zone:
		var z: Rect2 = (plan.blocks[bi]["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
		for l: Dictionary in plan.lots:
			if int(l["block"]) != bi or l["open"] != "plaza":
				continue
			var faces: Array = l["faces"]
			if not ((faces[0] or faces[1]) and (faces[2] or faces[3])):
				continue
			var r: Rect2 = l["rect"]
			var corner := Vector2(r.end.x if faces[0] else r.position.x, r.end.y if faces[2] else r.position.y)
			var out := (corner - z.get_center()).normalized()
			var e := corner + out * 14.0
			var t := r.get_center() - out * 8.0
			return {"eye": Vector3(e.x, e.y, CityPlan.MECH_TOP), "target": Vector3(t.x, t.y, 7.0)}
	return {}


## The target turned about 21 degrees to the side, so what the camera looks at sits in the middle of the picture's right
## two thirds (the lab's panel covers the left third).
func _right_of_panel(eye: Vector3, target: Vector3) -> Vector3:
	var d := Vector2(target.x - eye.x, target.y - eye.y)
	if d.length() < 0.01:
		return target
	var side := Vector2(d.y, -d.x).normalized() * Vector3(target - eye).length() * tan(deg_to_rad(21.0)) * PANEL_SIDE
	return target + Vector3(side.x, side.y, 0.0)


const PANEL_SIDE := 1.0          ## which way _right_of_panel turns (checked on a shot)


## The wall the farm cameras look at on the deck on show: the first farm wall (a side along the arc before an end, one
## with a gate first for "farm_gate"), else the first window wall; {} when there is neither.
func _farm_wall() -> Dictionary:
	var best := {}
	var best_score := -1
	for w: Dictionary in district.plan.boundary():
		var kind := str(w["kind"])
		if kind != "farm" and kind != "window":
			continue
		var score := (4 if kind == "farm" else 0) + (2 if int(w["side"]) < 2 else 0)
		if options["camera"] == "farm_gate" and not (w["gates"] as Array).is_empty():
			score += 8
		if score > best_score:
			best = w
			best_score = score
	return best


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
