class_name MissionLab
extends RefCounted
## The city lab's mission options (CityLab, site "stack"): option "mission" (off / doors / flag / asset / portal / all)
## puts MissionWorld in the stack from MissionWorld.stand_in_plan (MissionPlan's fields) and loops what it names; option
## "mission_phase" pins one look for a screenshot instead of the loop (shut / warn / opening / open / sealed / alien / ours /
## intact / damaged / wreck / half / full; warn: the silent state before the leaves move, opening: the leaves moving with
## the siren and lamps). Cameras mission_gate / mission_lift / mission_flag / mission_asset / mission_portal stand at a
## mech's eye height (8 m) 40-60 m off the piece, on the piece's deck; mission_bay looks into the gate's staging bay from
## the street (22 m out, 6.5 m up).
##   --city site=stack,seed=1,mission=all,mission_phase=warn,camera=mission_gate

const MODES := ["off", "doors", "flag", "asset", "portal", "all"]
const PHASES := ["loop", "shut", "warn", "opening", "open", "sealed", "alien", "ours", "intact", "damaged", "wreck", "half", "full"]
const CAMERAS := ["mission_gate", "mission_bay", "mission_air", "mission_air_farm", "mission_lift", "mission_flag", "mission_flag_far",
		"mission_asset", "mission_portal"]
const LOOP := 20.0               ## s per door cycle in the loop (the leaves start to move 8 s in, open 3 s, hold 6 s)

var mw: MissionWorld
var t := 0.0                     ## the lab's mission clock
var _gate: Variant
var _lift: Variant
var _air: Variant                ## an air door on a bulkhead end wall (else any), on the deck on show when there is one
var _air_farm: Variant           ## an air door on a farm end wall, if any
var _flag: Variant
var _asset: Variant
var _mode := "off"
var _phase := "loop"
var _cycle := -1


## (Re)build the mission on the lab's stack for its options (off, or no stack: nothing).
func apply(lab: CityLab) -> void:
	_mode = str(lab.options.get("mission", "off"))
	_phase = str(lab.options.get("mission_phase", "loop"))
	if lab.stack == null or _mode == "off" or not MODES.has(_mode):
		if lab.stack != null and lab.stack.mission != null:
			lab.stack.mission.teardown(true)
			lab.stack.remove_child(lab.stack.mission)
			lab.stack.mission.queue_free()
			lab.stack.mission = null
		mw = null
		return
	var plan: Variant = make_plan(lab.stack)
	mw = lab.stack.setup_mission(plan)
	_gate = _pick(plan, "gate", lab)
	_lift = _pick(plan, "lift", lab)
	_air = _pick_air(lab, "bulkhead")
	_air_farm = _pick_air(lab, "farm")
	if _air == null:
		_air = _air_farm
	_flag = _first_key(mw._flags)
	_asset = _first_key(mw._assets)
	t = 0.0
	_cycle = -1
	_pin()
	tick(0.0)


## The mission plan for the stack: MissionPlan.make(section) (Missions' class, scripts/world/section/mission_plan.gd);
## MissionWorld.stand_in_plan when it is not there.
static func make_plan(st: CityStack) -> Variant:
	var script := _global_class("MissionPlan")
	if script != null and st.section != null:
		return script.call("make", st.section)
	return MissionWorld.stand_in_plan(st)


static func _global_class(n: String) -> Script:
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if c["class"] == n:
			return load(str(c["path"])) as Script
	return null


static func _first_key(d: Dictionary) -> Variant:
	var keys := d.keys()
	keys.sort()
	return keys[0] if not keys.is_empty() else null


## The first source of `kind` that found a door, on the deck on show when there is one; a narrow gate (h 9) first.
func _pick(plan: Variant, kind: String, lab: CityLab) -> Variant:
	var best: Variant = null
	var best_score := -1
	for s: Dictionary in MissionWorld.field(plan, "sources", []):
		if s["kind"] != kind or not mw._doors.has(s["id"]):
			continue
		var score := 0
		if lab.district != null and int(s["deck"]) == lab.district.plan.deck:
			score += 4
		var door: Node = mw._doors[s["id"]]
		if door is MissionProps.GateDoor and (door as MissionProps.GateDoor).gh < 10.0:
			score += 2
		if score > best_score:
			best = s["id"]
			best_score = score
	return best


## The first air door whose end wall is of `kind` (bulkhead / farm), on the deck on show first; null when none.
func _pick_air(lab: CityLab, kind: String) -> Variant:
	var best: Variant = null
	var best_score := -1
	for id: Variant in mw._sources:
		var s: Dictionary = mw._sources[id]
		if str(s.get("kind", "")) != "air" or not mw._doors.has(id):
			continue
		var d := mw._deck(int(s["deck"]))
		var side := CityPlan.SIDE_EDGE.find(str(s["edge"]))
		if side < 0 or str(d.plan.boundary()[side]["kind"]) != kind:
			continue
		var score := 4 if lab.district != null and int(s["deck"]) == lab.district.plan.deck else 0
		if score > best_score:
			best = id
			best_score = score
	return best


## A pinned phase: fixed calls, then a clock that loops a short window round the moment worth showing.
func _pin() -> void:
	if _phase == "loop" or mw == null:
		return
	for id: Variant in [_gate, _lift, _air, _air_farm]:
		if id == null:
			continue
		match _phase:
			"warn", "opening", "open": mw.open_source(id, 10.0, 1.0e6, 10.0)
			"sealed": mw.close_source(id)
	match _phase:
		"ours": mw.set_flag(_flag, true, 0.0)
		"damaged": mw.set_asset(_asset, 0.4)
		"wreck": mw.set_asset(_asset, 0.0)
		"half": mw.set_portal(0.5)
		"full": mw.set_portal(1.0)
	if _phase == "ours":
		mw.set_zone(_flag, "ours")
		mw.set_hold_zone("holding")
	elif _phase == "full":
		mw.set_hold_zone("done")
	elif _phase == "half":
		mw.set_hold_zone("holding")


func tick(delta: float) -> void:
	if mw == null or not is_instance_valid(mw):
		return
	t += delta
	if _phase != "loop":
		var clock := 0.0
		match _phase:
			"warn": clock = 6.5 + fposmod(t, 1.4)     # silent, leaves still shut (warn ends at open_at 10)
			"opening": clock = 10.4 + fposmod(t, 2.2)  # leaves moving, siren, lamps flashing (opening 10 .. 13)
			"open": clock = 14.0 + t
			_: clock = 20.0 + t
		mw.advance_to(clock)
		return
	var cyc := int(floor(t / LOOP))
	if cyc != _cycle:
		_cycle = cyc
		var base := float(cyc) * LOOP
		if _mode == "doors" or _mode == "all":
			for id: Variant in [_gate, _lift, _air, _air_farm]:
				if id != null:
					mw.open_source(id, base + 8.0, 6.0)
		if _mode == "flag" or _mode == "all":
			mw.set_flag(_flag, cyc % 2 == 0, base + 2.0)
			mw.set_zone(_flag, ["contested", "ours"][cyc % 2])
		if _mode == "asset" or _mode == "all":
			mw.set_asset(_asset, [1.0, 0.4, 0.0][cyc % 3])
	if _mode == "portal" or _mode == "all":
		var p := clampf(fposmod(t, LOOP) / (LOOP * 0.75), 0.0, 1.0)
		mw.set_portal(p)
		mw.set_hold_zone("done" if p >= 1.0 else "holding")
	mw.advance_to(t)


## A mission camera: {district, eye, target} (arc coordinates on the piece's deck), or {} (no such piece: the lab's
## default view).
func view(cam: String) -> Dictionary:
	if mw == null or not is_instance_valid(mw):
		return {}
	var node: Node3D = null
	var eye := Vector3.ZERO
	var target := Vector3.ZERO
	match cam:
		"mission_gate":
			node = mw._doors.get(_gate) if _gate != null else null
			if node != null:
				var gh := (node as MissionProps.GateDoor).gh
				eye = Vector3(-14.0, 8.0, 44.0)
				target = Vector3(-6.0, gh * 0.55, 0.0)
		"mission_air", "mission_air_farm":     # looking up at an air door from the street, 50 m off (its frame is at the sill)
			var aid: Variant = _air if cam == "mission_air" else _air_farm
			node = mw._doors.get(aid) if aid != null else null
			if node != null:
				eye = Vector3(-3.0, 8.0 - MissionWorld.AIR_SILL, 38.0)     # in its flight corridor (clear of tall buildings)
				target = Vector3(-1.0, 1.5, 0.0)
		"mission_bay":
			node = mw._doors.get(_gate) if _gate != null else null
			if node != null:
				eye = Vector3(0.0, 6.5, 22.0)
				target = Vector3(0.0, 4.5, -20.0)
		"mission_lift":
			node = mw._doors.get(_lift) if _lift != null else null
			eye = Vector3(-12.0, 8.0, 40.0)
			target = Vector3(-6.0, 6.0, 0.0)
		"mission_flag", "mission_flag_far", "mission_asset":     # from the clearest of 16 directions, 45 / 80 / 32 m off
			var flag := cam != "mission_asset"
			var dist: float = {"mission_flag": 45.0, "mission_flag_far": 80.0, "mission_asset": 32.0}[cam]
			node = (mw._flags.get(_flag) if _flag != null else null) if flag else (mw._assets.get(_asset) if _asset != null else null)
			if node != null:
				var dir := _open_dir(node, dist)
				eye = Vector3(dir.x, 8.0, dir.y)
				# Aim left of the piece so it stands right of centre, clear of the lab panel on the left.
				var side := Vector2(-dir.y, dir.x).normalized() * dist * 0.22
				target = Vector3(side.x, 9.0 if flag else 3.5, side.y)
		"mission_portal":
			node = mw._portal
			if node != null:
				var gh := (node as MissionProps.Portal).gh
				eye = Vector3(-14.0, 8.0, 58.0)
				target = Vector3(-10.0, gh * 0.5, 0.0)
	if node == null or not is_instance_valid(node):
		return {}
	var d := node.get_parent() as CityDistrict
	if d == null:
		return {}
	var e := d.ring.world_to_arc(node.transform * eye)
	var g := d.ring.world_to_arc(node.transform * target)
	return {"district": d, "eye": Vector3(e.x, e.y, maxf(e.z, 1.0)), "target": g}


## The offset (in the piece's frame: x, z) `dist` m off it whose sight line to it crosses the fewest building footprints
## (sampled every 3 m), nearest to -x / -z first on a tie.
func _open_dir(node: Node3D, dist: float) -> Vector2:
	var d := node.get_parent() as CityDistrict
	var blockers := MissionProps._blockers(d.plan)
	var best := Vector2(-dist, -dist).normalized() * dist
	var best_hits := 1 << 20
	for i in 16:
		var a := PI * 1.25 + TAU * float(i) / 16.0
		var off := Vector2(cos(a), sin(a)) * dist
		var hits := 0
		var n := int(dist / 3.0)
		for j in range(1, n + 1):
			var p := node.transform * Vector3(off.x * float(j) / float(n), 0.0, off.y * float(j) / float(n))
			var arc := d.ring.world_to_arc(p)
			if MissionProps._in_rects(blockers, Vector2(arc.x, arc.y), 1.0):
				hits += 1 + (4 if j == n else 0)
		if hits < best_hits:
			best_hits = hits
			best = off
	return best
