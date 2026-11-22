class_name LifeLab
extends Node3D
## Lab subject "life": a city district (walled, its own daylight rig) with its civilians, pods and carts (AmbientLife).
##   .\lab.ps1 life
##   --scene res://scenes/lab.tscn --subject life --shot out.png --shot-after 4 --life camera=crowd,demo=panic,people=60
## `--life k=v,...` presets any param or option below (for screenshots).
## Cameras ("focus" = what each looks at, picked when the lab starts):
##   lab        the lab's orbit
##   street     a mech's eye (9 m) on the avenue, 22 m short of the busiest stretch of sidewalk, looking at it
##   sidewalk   2 m up just behind a walker near the busiest stretch
##   crowd      6 m up, 18 m out over the street, looking at the sidewalk point with the most people within 25 m
##   junction   7 m up on a road 30 m from the junction with the most vehicles round it, looking at the junction
##   pod        2 m up on the sidewalk beside a docked pod (the first one found), looking along it
## Demos: "calm" the timetables; "panic" a threat (40 m, strength 2) at the focus, then every 20 s along the avenue;
## "fire" a shot swept through the two people nearest the focus 1 s in, then an explosion-sized threat; "riders" a threat
## 14 m ahead of a pod with passengers (the sidewalk camera then watches them get out); "traffic" calm,
## meant with the junction camera; "wreck" a blast beside the pod nearest the focus 1 s in (the camera then frames it),
## then a mech-foot pusher walks into the wreck and shoves it.
## The life clock starts at START_T (a time on the timetable, so people are already mid-trip in the first frame).
## Site (phase 3): "alone" (the district above), "section" (one whole deck of the mission section planned from the same
## seed: CityDistrict.build_deck, its own rig; slider "deck") or "stack" (every deck at once: CityStack, one AmbientLife
## for all of them via setup_stack; the deck slider picks the deck on view, which the daylight lights). In section and
## stack the life is evaluated and drawn near a viewer node standing on the focus point (and the camera).
## Section cameras: "station" looks along the rail lane at a tram stopped at a station (the clock is moved on to a dwell);
## "tram" stands close beside that tram's middle car; "checkpoint" frames a heavy checkpoint with a pod stopped at it (the
## clock is moved on to such a stop).
##   --life site=stack,seed=4,camera=station

const PARAMS := [
	{"id": "seed", "label": "Seed", "min": 1.0, "max": 200.0},
	{"id": "people", "label": "People (0 = default for the area)", "min": 0.0, "max": 60.0},
	{"id": "pods", "label": "Pods (-1 = default for the area)", "min": -1.0, "max": 12.0},
	{"id": "carts", "label": "Service carts (-1 = default)", "min": -1.0, "max": 4.0},
	{"id": "time_scale", "label": "Life clock speed", "min": 0.0, "max": 8.0},
	{"id": "deck", "label": "Section deck (site: section / stack)", "min": 0.0, "max": 4.0},
]
const CAMERAS := ["lab", "street", "sidewalk", "crowd", "junction", "pod", "station", "tram", "checkpoint"]
const SITES := ["alone", "section", "stack"]
const DEMOS := ["calm", "panic", "fire", "traffic", "wreck", "riders"]
const START_T := 900.0
const PANIC_EVERY := 20.0
const SETTLE_FRAMES := 8

var time_scale := 1.0
var params := {"seed": 1.0, "people": 0.0, "pods": -1.0, "carts": -1.0, "time_scale": 1.0, "deck": 0.0}
var options := {"camera": "lab", "demo": "calm", "lighting": "day", "site": "alone"}
var district: CityDistrict      ## the district on view (on its own, the section deck, or the stack's deck on view)
var life: AmbientLife           ## the life on view: root itself, or root's unit for the deck on view
var root: AmbientLife           ## the scene's AmbientLife (group "ambient_life")
var stack: CityStack

var _alone: CityDistrict
var _eye: Node3D                ## section / stack: a viewer standing on the focus

var _cam: Camera3D
var _dirty := -1
var _demo_t0 := 0.0
var _demo_step := 0
var _focus := Vector2.ZERO      ## arc (x, s): what the cameras look at
var _crowd_at := Vector2.ZERO   ## the sidewalk point with the most people within 25 m (at the start)
var _crowd_n := Vector2.ZERO    ## the outward normal of its block edge
var _target := -1               ## the demo's pod
var _pusher: Node3D
var _stop_heading := 0.0


func _init() -> void:
	var arg := Boot.arg_value(OS.get_cmdline_user_args(), "--life")
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
	_cam.name = "LifeCamera"
	_cam.fov = 64.0
	_cam.far = 900.0
	add_child(_cam)
	rebuild()


func rebuild() -> void:
	_dirty = -1
	var site := str(options["site"])
	var people_n := int(params["people"]) if params["people"] >= 1.0 else -1
	if root == null:
		root = AmbientLife.new()
		add_child(root)
	if site == "stack":
		if _alone != null:
			remove_child(_alone)
			_alone.queue_free()
			_alone = null
		if stack == null:
			stack = CityStack.new()
			stack.name = "Stack"
			add_child(stack)
		stack.build(SectionPlan.make({"seed": params["seed"]}))
		var k := clampi(int(params["deck"]), 0, stack.decks.size() - 1)
		district = stack.decks[k]
		stack.set_active_deck(k)
		stack.rig.apply(str(options["lighting"]))
		root.setup_stack(stack, people_n, int(params["pods"]), int(params["carts"]))
		life = root.unit(k)
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
		if site == "section":
			var sec := SectionPlan.make({"seed": params["seed"]})
			district.build_deck(sec, clampi(int(params["deck"]), 0, sec.deck_count - 1))
		else:
			district.build({"seed": params["seed"], "walls": 1.0})
		district.rig.apply(str(options["lighting"]))
		root.setup(district, people_n, int(params["pods"]), int(params["carts"]))
		root.bind_props(district.props)
		life = root
	if _eye != null:
		root.remove_viewer(_eye)
		root.remove_viewer(_cam)
	if site != "alone":
		if _eye == null:
			_eye = Node3D.new()
			_eye.name = "LifeViewer"
			add_child(_eye)
		root.add_viewer(_eye)
		root.add_viewer(_cam)
	root.advance_to(START_T)
	_pick_crowd()
	_start_demo()
	_apply_view()
	print("[life] site %s seed %d deck %d  people %d  vehicles %d  plan %s  traffic %s  doors %d  benches %d%s" % [site,
			int(params["seed"]), int(params["deck"]), life.plan.count, life.vehicle_count(), life.plan.checksum(),
			life.traffic.checksum(), life.plan.doors.size(), life.plan.benches.size(),
			("  tram period %.0f s" % life.tram.period) if life.tram != null else ""])


func _rig() -> CityLightRig:
	return stack.rig if stack != null else district.rig


func _process(_delta: float) -> void:
	if _dirty >= 0:
		_dirty -= 1
		if _dirty < 0:
			rebuild()
		return
	if root == null or life == null:
		return
	root.time_scale = time_scale * float(params["time_scale"])
	_demo()


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
	if id != "time_scale":
		value = round(value)
	if is_equal_approx(float(params[id]), value):
		return
	params[id] = value
	if id == "deck" and stack != null and not stack.decks.is_empty():
		var k := clampi(int(value), 0, stack.decks.size() - 1)     # every deck is built: only the view moves
		district = stack.decks[k]
		stack.set_active_deck(k)
		life = root.unit(k)
		_pick_crowd()
		_start_demo()
		_apply_view()
		return
	if id != "time_scale":
		_dirty = SETTLE_FRAMES


func lab_options() -> Array:
	return [
		{"id": "camera", "label": "Camera", "choices": CAMERAS, "value": options["camera"]},
		{"id": "demo", "label": "Demo", "choices": DEMOS, "value": options["demo"]},
		{"id": "lighting", "label": "Lighting", "choices": CityLightRig.preset_ids(), "value": options["lighting"]},
		{"id": "site", "label": "Site", "choices": SITES, "value": options["site"]},
	]


func set_lab_option(id: String, value: String) -> void:
	if not options.has(id):
		return
	options[id] = value
	if district == null or life == null:
		return
	match id:
		"lighting": _rig().apply(value)
		"site": _dirty = SETTLE_FRAMES
		"demo":
			root.restore(PackedByteArray())
			_start_demo()
			_apply_view()
		_:
			_apply_view()


func lab_focus() -> Vector3:
	return Vector3(0.0, 8.0, 0.0)


func lab_radius() -> float:
	if district == null or district.plan == null:
		return 90.0
	return maxf(district.plan.extent.size.x, district.plan.extent.size.y) * 0.42


# --- Picking what to look at -----------------------------------------------------------------------------

## The sidewalk point (a person's position on a block) with the most people outdoors within 25 m (for the panic demo,
## each vehicle within 30 m counts as two people, so the spot shows both).
func _pick_crowd() -> void:
	var cars: Array[Vector2] = []
	if options["demo"] == "panic" or options["site"] != "alone":
		for v in life.vehicle_count():
			var q := life.fleet.pose(v, life.now)
			cars.append(Vector2(q["x"], q["s"]))
	var pts: Array[Vector2] = []
	for id in life.count():
		var p := life.crowd.pose(id, life.now)
		if p["visible"]:
			pts.append(Vector2(p["x"], p["s"]))
	var best_n := -1
	for q in pts:
		var n := 0
		for r in pts:
			if r.distance_to(q) < 25.0:
				n += 1
		for c in cars:
			if c.distance_to(q) < 30.0:
				n += 2 if options["demo"] == "panic" else 1
		if n > best_n and _block_of(q) >= 0:
			best_n = n
			_crowd_at = q
	var bi := _block_of(_crowd_at)
	_crowd_n = Vector2(0, 1)
	if bi >= 0:
		var r: Rect2 = district.plan.blocks[bi]["rect"]
		var d: Array[float] = [r.end.x - _crowd_at.x, _crowd_at.x - r.position.x, r.end.y - _crowd_at.y, _crowd_at.y - r.position.y]
		var side := 0
		for k in 4:
			if d[k] < d[side]:
				side = k
		_crowd_n = CityPlan.SIDE_N[side]


func _block_of(at: Vector2) -> int:
	for bi in district.plan.blocks.size():
		if (district.plan.blocks[bi]["rect"] as Rect2).has_point(at):
			return bi
	return -1


## The junction with the most vehicles within 40 m: its centre (arc).
func _busy_junction() -> Vector2:
	var best := Vector2.ZERO
	var best_n := -1
	for j: Dictionary in life.plan.junctions:
		var at: Vector2 = j["at"]
		var e := district.plan.extent.grow(-30.0)
		if not e.has_point(at):
			continue
		var n := 0
		for v in life.vehicle_count():
			var q := life.fleet.pose(v, life.now)
			if Vector2(q["x"], q["s"]).distance_to(at) < 40.0:
				n += 1
		if n > best_n:
			best_n = n
			best = at
	return best


## A pod driving mid-side with passengers aboard and at least `near` people outdoors within 30 m, or -1.
func _rider_pod(near: int = 0) -> int:
	for v in life.vehicle_count():
		if life.vehicle_kind(v) != "pod" or life.vehicle_state(v) != "driving" or life.traffic.riders(v, life.now + 0.8) == 0:
			continue
		var q := life.fleet.pose(v, life.now)
		var li := int(life.traffic.vehicles[v]["loop"])
		if life.traffic.zone_at(li, float(q["u"])) < 0 and float(life.traffic.zone_ahead(li, float(q["u"]))[1]) > 25.0 				and float(q["v"]) > 5.0:
			var n := 0
			for id in life.count():
				var p := life.crowd.pose(id, life.now)
				if p["visible"] and Vector2(p["x"], p["s"]).distance_to(Vector2(q["x"], q["s"])) < 30.0:
					n += 1
			if n >= near:
				return v
	return -1


func _nearest_block(at: Vector2) -> int:
	var best := 0
	var bd := INF
	for bi in district.plan.blocks.size():
		var r: Rect2 = district.plan.blocks[bi]["rect"]
		var q := Vector2(clampf(at.x, r.position.x, r.end.x), clampf(at.y, r.position.y, r.end.y))
		if q.distance_to(at) < bd:
			bd = q.distance_to(at)
			best = bi
	return best


## The outward normal of the edge of block bi nearest to `at` (pointing into the street).
func _edge_normal(bi: int, at: Vector2) -> Vector2:
	var r: Rect2 = district.plan.blocks[bi]["rect"]
	var d: Array[float] = [absf(r.end.x - at.x), absf(at.x - r.position.x), absf(r.end.y - at.y), absf(at.y - r.position.y)]
	var side := 0
	for k in 4:
		if d[k] < d[side]:
			side = k
	return CityPlan.SIDE_N[side]


func _docked_pod() -> int:
	for v in life.vehicle_count():
		if life.vehicle_state(v) == "docked":
			return v
	return -1


func _pod_near(at: Vector2) -> int:
	var best := -1
	var bd := INF
	for v in life.vehicle_count():
		if life.vehicle_kind(v) != "pod" or life.vehicle_state(v) == "wreck":
			continue
		var q := life.fleet.pose(v, life.now)
		var d := Vector2(q["x"], q["s"]).distance_to(at)
		if d < bd:
			bd = d
			best = v
	return best


# --- Demos -----------------------------------------------------------------------------------------------

## Section: moves the clock on to the tram dwelling at a station (1.5 s into the dwell); the stop (arc).
func _station_stop() -> Vector2:
	var tr := life.tram
	if tr == null:
		return _crowd_at
	var t := life.now
	for i in 2400:
		var p := tr.pose(t)
		if p["mode"] == "dwell":
			for sp: Dictionary in tr.stops:
				if sp["kind"] == "station" and absf(float(sp["s"]) - float(p["s"])) < 0.05:
					root.advance_to(t + 1.5)
					return Vector2(tr.x, float(p["s"]))
		t += 0.5
	return Vector2(tr.x, float(tr.pose(life.now)["s"]))


## Section: moves the clock on to a pod standing at a heavy checkpoint's stop; that pod's position (arc), _target = it.
func _checkpoint_stop() -> Vector2:
	var tr := life.traffic
	var want: Array = []        # [loop, u]
	for li in tr.loops.size():
		for m: Dictionary in tr.loops[li]["marks"]:
			if m.has("check"):
				want.append([li, float(m["u"])])
	if want.is_empty():
		return _crowd_at
	var t := life.now
	for i in 2400:
		for w: Array in want:
			for vid in tr.loop_vehicles(int(w[0])):
				var b := tr.base_pose(vid, t)
				if b["mode"] == "dwell" and absf(float(b["u"]) - float(w[1])) < 0.1:
					root.advance_to(t + 0.3)
					_target = vid
					return Vector2(b["x"], b["s"])
		t += 0.5
	return _crowd_at


func _start_demo() -> void:
	_demo_t0 = life.now
	_demo_step = 0
	_target = -1
	if _pusher != null:
		life.remove_pusher(_pusher)
		_pusher.queue_free()
		_pusher = null
	match str(options["camera"]):
		"junction": _focus = _busy_junction()
		"station", "tram": _focus = _station_stop()
		"checkpoint": _focus = _checkpoint_stop()
		"pod":
			var v := _docked_pod()
			_focus = Vector2(life.fleet.pose(v, life.now)["x"], life.fleet.pose(v, life.now)["s"]) if v >= 0 else _crowd_at
		_: _focus = _crowd_at
	if options["demo"] == "riders" or options["demo"] == "panic":
		# wait (fast-forward up to two minutes) for a pod with passengers driving along a side, near people for "panic"
		for i in 240:
			_target = _rider_pod(4 if options["demo"] == "panic" and i < 200 else 0)
			if _target >= 0:
				break
			root.advance_to(life.now + 0.5)
		_demo_t0 = life.now
		if _target >= 0:
			var q := life.fleet.pose(_target, life.now)
			_focus = Vector2(q["x"], q["s"])
			_stop_heading = float(q["heading"])
			if options["demo"] == "panic":
				var bi := _nearest_block(_focus)
				_crowd_n = _edge_normal(bi, _focus)
	if options["demo"] == "wreck":
		_target = _pod_near(_focus)
		if _target >= 0:
			var q := life.fleet.pose(_target, life.now + 1.0)
			_focus = Vector2(q["x"], q["s"])


func _demo() -> void:
	var t := life.now - _demo_t0
	var plan := district.plan
	var av := plan.avenue_x()
	var e := plan.extent
	match str(options["demo"]):
		"riders", "panic" when _target >= 0 and _demo_step == 0:
			if t >= 0.5:
				var q := life.fleet.pose(_target, life.now)
				var f := Vector2(sin(float(q["heading"])), cos(float(q["heading"])))
				var at := Vector2(q["x"], q["s"]) + f * 14.0
				life.raise_threat(_world(at.x, at.y, 1.0), 40.0 if options["demo"] == "panic" else 20.0, 2)
				_demo_step = 1
				var ep: Dictionary = life.fleet.episodes.get(int(life.traffic.vehicles[_target]["loop"]), {})
				if not ep.is_empty() and ep["v"].has(_target):
					var a: Dictionary = ep["v"][_target]
					var stop := life.fleet.pose(_target, float(a["doors"]) if float(a["doors"]) > 0.0 else life.now + 2.0)
					_focus = Vector2(stop["x"], stop["s"])
					_stop_heading = float(stop["heading"])
				_apply_view()
		"panic":
			if t >= float(_demo_step) * PANIC_EVERY + 0.5:
				var at := _focus
				if _demo_step == 0 and options["camera"] == "junction":
					# amid the vehicles round the junction, so they e-stop in view
					var sum := Vector2.ZERO
					var n := 0
					for v in life.vehicle_count():
						var q := Vector2(life.fleet.pose(v, life.now)["x"], life.fleet.pose(v, life.now)["s"])
						if q.distance_to(_focus) < 45.0:
							sum += q
							n += 1
					if n > 0:
						at = sum / float(n)
				if _demo_step > 0:
					at = Vector2((av.x + av.y) * 0.5, lerpf(e.position.y + 40.0, e.end.y - 40.0, [0.3, 0.7, 0.5, 0.1, 0.9][_demo_step % 5]))
				life.raise_threat(_world(at.x, at.y, 2.0), 40.0, 2)
				_demo_step += 1
		"fire":
			if _demo_step == 0 and t >= 1.0:
				# A gun swept along the street through the two people nearest the focus, then a big blast's threat.
				var near: Array = []
				for id in life.count():
					var p := life.crowd.pose(id, life.now)
					if p["visible"]:
						near.append([Vector2(p["x"], p["s"]).distance_to(_focus), id])
				near.sort()
				var shots := 0
				for n: Array in near:
					if shots >= 2:
						break
					var p := life.crowd.pose(int(n[1]), life.now)
					if p["state"] == "down":
						continue
					var h := float(p["heading"])
					var d := Vector2(sin(h), cos(h))
					var c := Vector2(p["x"], p["s"])
					var hits := life.sweep(_world(c.x - d.x * 40.0, c.y - d.y * 40.0, 1.0), _world(c.x + d.x * 40.0, c.y + d.y * 40.0, 1.0), 0.3, 1)
					print("[life] fire demo: a sweep through %s hits %d" % [str(c), hits])
					shots += 1
				life.raise_threat(_world(_focus.x, _focus.y, 2.0), 80.0, 3)
				_demo_step = 1
		"wreck":
			if _target < 0:
				return
			if _demo_step == 0 and t >= 1.0:
				var xf := life.vehicle_pose(_target)
				var hits := life.blast(xf.origin + xf.basis.x * 1.6 + xf.basis.y * 0.6, 3.0, 1)
				life.raise_threat(xf.origin, 80.0, 3)
				print("[life] wreck demo: a blast beside pod %d hits %d" % [_target, hits])
				_demo_step = 1
				var w := life.fleet.pose(_target, life.now + 0.8)
				_focus = Vector2(w["x"], w["s"])
				_apply_view()          # frame it from the side it rolls toward
			elif _demo_step == 1 and t >= 2.5:
				_pusher = Node3D.new()
				_pusher.name = "DemoFoot"
				add_child(_pusher)
				var xf := life.vehicle_pose(_target)
				_pusher.global_position = xf.origin - xf.basis.z * 6.0
				life.add_pusher(_pusher, 1.2, 1)
				_demo_step = 2
			elif _demo_step == 2 and _pusher != null:
				var to := life.vehicle_pose(_target).origin - _pusher.global_position
				_pusher.global_position += to.normalized() * minf(6.0 * get_process_delta_time() * maxf(life.time_scale, 0.0), to.length())
				if t >= 5.0:
					life.remove_pusher(_pusher)
					_demo_step = 3


func _world(x: float, s: float, h: float) -> Vector3:
	return district.global_transform * district.ring.arc_to_world(x, s, h)


# --- Views -----------------------------------------------------------------------------------------------

func _apply_view() -> void:
	var inside: bool = options["camera"] != "lab"
	district.set_ceiling_visible(inside)
	district.set_backdrop_visible(inside)
	if _eye != null:
		_eye.global_position = district.global_transform * district.ring.arc_to_world(_focus.x, _focus.y, 1.0)
	if not inside:
		_cam.clear_current(true)
		return
	var e := district.plan.extent
	var av := district.plan.avenue_x()
	var mid_x := (av.x + av.y) * 0.5
	var eye := Vector3.ZERO
	var target := Vector3(_focus.x, _focus.y, 0.8)
	var turn := -0.18          # turned a little, so what it looks at sits right of centre, clear of the lab's panel
	match str(options["camera"]):
		"street" when options["site"] != "alone":
			# section decks: a mech's eye (9 m) out over the street, 16 m off the busiest sidewalk and 12 m back along it
			var along := Vector2(_crowd_n.y, -_crowd_n.x)
			var at := _focus + _crowd_n * 16.0 - along * 12.0
			eye = Vector3(at.x, at.y, 9.0)
			target = Vector3(_focus.x, _focus.y, 1.0)
		"street":
			var back := -1.0 if _focus.y > (e.position.y + e.end.y) * 0.5 else 1.0
			var s0 := clampf(_focus.y + back * 22.0, e.position.y + 5.0, e.end.y - 5.0)
			eye = Vector3(clampf(_focus.x, av.x + 2.0, av.y - 2.0) if absf(_focus.x - mid_x) < 30.0 else mid_x, s0, 9.0)
		"crowd":
			# out over the street, slid along the block edge toward the middle of the block (the corners carry sign posts)
			var along := Vector2(_crowd_n.y, -_crowd_n.x)
			var bi := _block_of(_focus)
			if bi >= 0 and along.dot((district.plan.blocks[bi]["rect"] as Rect2).get_center() - _focus) < 0.0:
				along = -along
			var at := _focus + _crowd_n * 18.0 + along * 7.0
			if options["demo"] == "wreck" and _target >= 0:
				var q := life.fleet.pose(_target, life.now)
				var h := float(q["heading"])
				var roll := float(life.fleet.wrecks[_target]["roll"]) if life.fleet.wrecks.has(_target) else -1.0
				# from the side it rolled toward (its roof and canopy face that way), a little ahead of it
				at = _focus + Vector2(cos(h), -sin(h)) * 13.0 * signf(roll) + Vector2(sin(h), cos(h)) * 7.0
			if options["demo"] == "panic" and _target >= 0:
				at = _focus + _crowd_n * 14.0       # over the street, beside the pod, above the street trees
			eye = Vector3(at.x, at.y, 8.5 if options["demo"] == "panic" else 6.0)
			target = Vector3(_focus.x, _focus.y, 0.8)
		"junction":
			var road := Vector2(0.0, 1.0) if _focus.y < (e.position.y + e.end.y) * 0.5 else Vector2(0.0, -1.0)
			var at := _focus - road * 30.0 + Vector2(4.0, 0.0)
			eye = Vector3(at.x, at.y, 7.0)
			target = Vector3(_focus.x, _focus.y + road.y * 6.0, 0.5)
		"pod":
			var v := _docked_pod()
			if v >= 0:
				var q := life.fleet.pose(v, life.now)
				var h := float(q["heading"])
				var fwd := Vector2(sin(h), cos(h))
				var right := Vector2(-fwd.y, fwd.x)
				var c := Vector2(q["x"], q["s"])
				var at := c - right * 1.4 - fwd * 7.5       # in the lane behind it (the sidewalk side has trees)
				eye = Vector3(at.x, at.y, 2.0)
				target = Vector3(c.x, c.y, 0.9)
				turn = -0.1
		"sidewalk" when options["demo"] == "riders" and _demo_step > 0:
			# on the curb side of the stopped pod, a little behind it, at a person's eye height
			var fwd := Vector2(sin(_stop_heading), cos(_stop_heading))
			var right := Vector2(-fwd.y, fwd.x)
			var at := _focus + right * 6.8 - fwd * 7.5
			eye = Vector3(at.x, at.y, 1.8)
			target = Vector3(_focus.x + right.x * 1.5, _focus.y + right.y * 1.5, 0.9)
			turn = -0.12
		"sidewalk":
			var best := -1
			var best_d := INF
			for id in life.count():
				var p := life.crowd.pose(id, life.now)
				if not p["visible"] or p["mode"] != "walk" or int(p["na"]) < 0 or int(p["nb"]) < 0:
					continue
				var d := Vector2(p["x"], p["s"]).distance_to(_focus)
				if d < best_d:
					best_d = d
					best = id
			eye = Vector3(_focus.x, _focus.y - 8.0, 2.0)
			if best >= 0:
				var p := life.crowd.pose(best, life.now)
				var fwd := Vector2(sin(float(p["heading"])), cos(float(p["heading"])))
				var at := Vector2(p["x"], p["s"]) - fwd * 6.0
				eye = Vector3(at.x, at.y, 2.0)
				var aim := Vector2(p["x"], p["s"]) + fwd * 8.0
				target = Vector3(aim.x, aim.y, 0.8)
	match str(options["camera"]):
		"station", "tram":
			if life.tram != null:
				var x := life.tram.x
				var s := _focus.y
				var back := -1.0 if s > (e.position.y + e.end.y) * 0.5 else 1.0      # stand on the deck's longer side
				if options["camera"] == "station":
					eye = Vector3(x - 9.0 * back, s + back * 46.0, 6.0)     # the tram right of the lab's panel
					target = Vector3(x, s, 2.0)
				else:
					eye = Vector3(x - 7.0 * back, s + back * 7.0, 2.4)
					target = Vector3(x, s - back * 6.0, 1.9)
					turn = -0.1
		"checkpoint":
			var bar := Vector2(_focus.x, _focus.y)
			for it: Dictionary in LifeBarriers.items(district.plan):
				if it["kind"] == "heavy":
					bar = Vector2((float(it["a"]) + float(it["b"])) * 0.5, float(it["s"]))
					break
			if _target >= 0:
				var q := life.fleet.pose(_target, life.now)
				var c := Vector2(q["x"], q["s"])
				var fwd := (bar - c).normalized()
				var right := Vector2(-fwd.y, fwd.x)
				var at := c - fwd * 16.0 - right * 7.0
				eye = Vector3(at.x, at.y, 4.5)
				var mid := c.lerp(bar, 0.45)
				target = Vector3(mid.x, mid.y, 1.0)
				turn = -0.08
			else:
				eye = Vector3(bar.x - 8.0, bar.y - 30.0, 7.0)
				target = Vector3(bar.x, bar.y, 1.0)
	if _eye != null:
		_eye.global_position = district.global_transform * district.ring.arc_to_world(target.x, target.y, 1.0)
	var ring := district.ring
	var p0 := district.global_transform * ring.arc_to_world(eye.x, eye.y, eye.z)
	var q0 := district.global_transform * ring.arc_to_world(target.x, target.y, target.z)
	var up := district.global_transform.basis * ring.up_at(district.to_local(p0))
	_cam.global_transform = Transform3D(Basis(up.normalized(), turn) * Basis.looking_at(q0 - p0, up), p0)
	_cam.make_current()
