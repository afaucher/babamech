class_name MissionLab
extends RefCounted
## The city lab's mission options (CityLab, site "stack"): option "mission" (off / doors / flag / asset / all) puts
## MissionWorld in the stack from MissionWorld.stand_in_plan (MissionPlan's fields) and loops what it names; option
## "mission_phase" pins one look for a screenshot instead of the loop (shut / warn / opening / open / sealed / alien / ours /
## intact / damaged / wreck / holding / done; warn: the silent state before the leaves move, opening: the leaves moving
## with the siren and lamps). The door phases apply to the wave gate, lift and air doors shown, and to the entry and exit
## road doors and both tram doors too (shut: the entry door shut at 0, the tram doors ordered shut at 0; opening / open:
## then opened at 10). Cameras mission_gate / mission_flag / mission_asset stand at a mech's eye height (8 m)
## 40-60 m off the piece, on the piece's deck; mission_bay looks into the gate's staging bay from the street (22 m out,
## 6.5 m up), mission_lift into the lift car from its plaza (24 m out, 6 m up); entry_door / exit_door look at the entry / exit road door from the main road (the bay visible through it
## when open), tram_door at the s0 tram door from beside the track.
##   --city site=stack,seed=1,mission=all,mission_phase=warn,camera=mission_gate
##   --city site=stack,seed=1,deck=0,mission=doors,mission_phase=open,camera=entry_door

const MODES := ["off", "doors", "flag", "asset", "all"]
const PHASES := ["loop", "shut", "warn", "opening", "open", "sealed", "alien", "ours", "intact", "damaged", "wreck", "holding", "done"]
const CAMERAS := ["mission_gate", "mission_bay", "mission_air", "mission_air_farm", "mission_lift", "mission_flag", "mission_flag_far",
		"mission_asset", "entry_door", "exit_door", "tram_door", "tram_door_s1"]
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
	_flag = _first_key(mw.flag_nodes())
	_asset = _first_key(mw.asset_nodes())
	t = 0.0
	_cycle = -1
	if _phase == "loop" and (_mode == "doors" or _mode == "all"):
		mw.shut_source(MissionWorld.ENTRY_ID, 0.0)       # the loop cycles it like the others
	_pin()
	tick(0.0)


## The mission plan for the stack: MissionPlan.make(section) (Missions' class, scripts/mission/mission_plan.gd);
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
		if s["kind"] != kind or not mw.door_nodes().has(s["id"]):
			continue
		var score := 0
		if lab.district != null and int(s["deck"]) == lab.district.plan.deck:
			score += 4
		var door: Node = mw.door_nodes()[s["id"]]
		if door is MissionGateDoor and (door as MissionGateDoor).gh < 10.0:
			score += 2
		if score > best_score:
			best = s["id"]
			best_score = score
	return best


## The first air door whose end wall is of `kind` (bulkhead / farm), on the deck on show first; null when none.
func _pick_air(lab: CityLab, kind: String) -> Variant:
	var best: Variant = null
	var best_score := -1
	for id: Variant in mw.source_info():
		var s: Dictionary = mw.source_info()[id]
		if str(s.get("kind", "")) != "air" or not mw.door_nodes().has(id):
			continue
		var d := mw.deck_at(int(s["deck"]))
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
	# The entry / exit road doors and the tram doors.
	var door_phase := _phase in ["shut", "warn", "opening", "open", "sealed"]
	if door_phase:
		mw.shut_source(MissionWorld.ENTRY_ID, 0.0)
		for end: String in MissionWorld.TRAM_IDS:
			mw.set_tram_door(end, false, 0.0)
	for id: String in [MissionWorld.ENTRY_ID, MissionWorld.EXIT_ID]:
		match _phase:
			"warn", "opening", "open": mw.open_source(id, 10.0, 1.0e6, 10.0)
			"sealed": mw.close_source(id)
	if _phase in ["warn", "opening", "open"]:
		for end: String in MissionWorld.TRAM_IDS:
			mw.set_tram_door(end, true, 10.0)
	match _phase:
		"ours": mw.set_flag(_flag, true, 0.0)
		"damaged": mw.set_asset(_asset, 0.4)
		"wreck": mw.set_asset(_asset, 0.0)
	if _phase == "ours":
		mw.set_zone(_flag, "ours")
		mw.set_hold_zone("holding")
	elif _phase == "done":
		mw.set_hold_zone("done")
	elif _phase == "holding":
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
			for id: Variant in [_gate, _lift, _air, _air_farm, MissionWorld.ENTRY_ID, MissionWorld.EXIT_ID]:
				if id != null:
					mw.open_source(id, base + 8.0, 6.0)
			for end: String in MissionWorld.TRAM_IDS:      # the tram doors shut and open again once a cycle
				mw.set_tram_door(end, false, base + 2.0)
				mw.set_tram_door(end, true, base + 10.0)
		if _mode == "flag" or _mode == "all":
			mw.set_flag(_flag, cyc % 2 == 0, base + 2.0)
			mw.set_zone(_flag, ["contested", "ours"][cyc % 2])
		if _mode == "asset" or _mode == "all":
			mw.set_asset(_asset, [1.0, 0.4, 0.0][cyc % 3])
		if _mode == "all":
			mw.set_hold_zone(["holding", "done"][cyc % 2])
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
			node = mw.door_nodes().get(_gate) if _gate != null else null
			if node != null:
				var gh := (node as MissionGateDoor).gh
				eye = Vector3(-14.0, 8.0, 44.0)
				target = Vector3(-6.0, gh * 0.55, 0.0)
		"mission_air", "mission_air_farm":     # looking up at an air door from the street, 50 m off (its frame is at the sill)
			var aid: Variant = _air if cam == "mission_air" else _air_farm
			node = mw.door_nodes().get(aid) if aid != null else null
			if node != null:
				eye = Vector3(-3.0, 8.0 - MissionAirDoors.SILL, 38.0)     # in its flight corridor (clear of tall buildings)
				target = Vector3(-1.0, 1.5, 0.0)
		"mission_bay":
			node = mw.door_nodes().get(_gate) if _gate != null else null
			if node != null:
				eye = Vector3(0.0, 6.5, 22.0)
				target = Vector3(0.0, 4.5, -20.0)
		"mission_lift":     # into the lift car from its plaza, 24 m out, a little off the door's line
			node = mw.door_nodes().get(_lift) if _lift != null else null
			eye = Vector3(-4.0, 6.0, 24.0)
			target = Vector3(1.0, 4.0, -12.0)
		"mission_flag", "mission_flag_far", "mission_asset":     # from the clearest of 16 directions, 45 / 80 / 32 m off
			var flag := cam != "mission_asset"
			var dist: float = {"mission_flag": 45.0, "mission_flag_far": 80.0, "mission_asset": 32.0}[cam]
			node = (mw.flag_nodes().get(_flag) if _flag != null else null) if flag else (mw.asset_nodes().get(_asset) if _asset != null else null)
			if node != null:
				var dir := _open_dir(node, dist)
				eye = Vector3(dir.x, 8.0, dir.y)
				# Aim left of the piece so it stands right of centre, clear of the lab panel on the left.
				var side := Vector2(-dir.y, dir.x).normalized() * dist * 0.22
				target = Vector3(side.x, 9.0 if flag else 3.5, side.y)
		"entry_door", "exit_door":     # from the main road, 40 m out, a little off the door's line (the bay seen through it)
			node = mw.door_nodes().get(MissionWorld.ENTRY_ID if cam == "entry_door" else MissionWorld.EXIT_ID)
			if node != null:
				var gd := node as MissionGateDoor
				eye = Vector3(gd.icenter * 0.3 - 4.0, 7.0, 40.0)
				target = Vector3(gd.icenter * 0.3, 5.0, -8.0)
		"tram_door", "tram_door_s1":     # beside the track, 16 m out, the door and its tunnel
			node = mw.door_nodes().get(MissionWorld.TRAM_IDS["s0" if cam == "tram_door" else "s1"])
			if node != null:
				eye = Vector3(-5.0, 4.5, 18.0)
				target = Vector3(0.5, 2.6, -4.0)
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
	var blockers := SiteFit.plan_blockers(d.plan)
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
			if SiteFit.in_rects(blockers, Vector2(arc.x, arc.y), 1.0):
				hits += 1 + (4 if j == n else 0)
		if hits < best_hits:
			best_hits = hits
			best = off
	return best
