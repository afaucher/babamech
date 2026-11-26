extends TestCase
## MissionWorld (scripts/world/city/mission_world.gd, docs/design/city-ramps-and-stack.md "Mission world (phase 1)"):
## wave doors as scheduled effects on the shared clock (gate and lift: warn / opening / open / closing / shut at the right
## times, collision with them, a late call snaps, a repeat open only extends the hold, hold_source extends, sealed is solid
## and final, ramp / shaft / unknown ids are harmless), two instances given the same calls in different frame steppings
## end in the same snapshot, snapshot / restore round trip, the flag and the relay stand on clear ground inside their
## radius (deterministic), the relay body is tagged for Weapons, the portal clamps, every signal fires once, and a stack
## without a mission (or after its teardown) is exactly the stack it was.

const SEEDS_TO := 30            ## the seed loop runs seeds 1..SEEDS_TO
## test_runner's wall limit (default 120 s): about 90 s alone, 160 s on a busy machine (2026-11-25)
const TEST_TIMEOUT := 300

var flag_id: Variant
var asset_id: Variant
var issues: Array[String] = []     ## plan points worth a word to Missions (printed, not failed)


func setup() -> void:
	timeout_sec = 300.0
	var sec := SectionPlan.make({"seed": 1})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	var before := _fingerprint(stack)
	# Re-captured 2026-11-23 (city variety: alleys + stand-alone road forms on by default); was 209989488eaa0e52.
	eq(CityPlan.make({"seed": 1}).checksum(), "bd1d848c575e85df", "the district plan's golden checksum")
	var plan := _as_dict(MissionLab.make_plan(stack))
	plan["sources"].append({"id": "ramp1", "deck": 0, "kind": "ramp", "x": 0.0, "s": 0.0})
	plan["sources"].append({"id": "shaft1", "deck": 0, "kind": "shaft", "x": 0.0, "s": 0.0})
	var t0 := Time.get_ticks_usec()
	var mw := stack.setup_mission(plan)
	print("[mission] setup %.1f ms, %d doors" % [float(Time.get_ticks_usec() - t0) / 1000.0, mw._doors.size()])
	check(stack.mission == mw, "stack.mission is the MissionWorld")
	_report_tris(mw)
	eq(stack.checksum(), before["checksum"], "the stack checksum is untouched by a mission")
	for k in stack.decks.size():
		eq(stack.decks[k].get_node("Collision").get_child_count(), before["shapes"][k], "deck %d: the district's shape count is unchanged" % k)
	flag_id = _first_obj(plan, "flag")
	asset_id = _first_obj(plan, "defend")
	check(flag_id != null and asset_id != null, "the plan has a flag and a defend objective")
	var gate: Variant = _first(plan, "gate", mw)
	var lift: Variant = _first(plan, "lift", mw)
	check(gate != null, "a gate source found its blast door")
	check(lift != null, "a lift source found its lift doors")
	if gate != null:
		await _doors_over_time(mw, gate, "gate")
		await _collision(stack, mw, gate)
	if lift != null:
		await _doors_over_time(mw, lift, "lift")
		var lp := mw.source_point(lift)
		var ls: Dictionary = {}
		for src: Dictionary in plan["sources"]:
			if src["id"] == lift:
				ls = src
		eq([float(lp["x"]), float(lp["s"])], [float(ls["x"]), float(ls["s"])], "a lift source's point is the plan's point")
	if gate != null:
		_seal_while_open(mw, gate)
	_noop_ids(mw)
	_signals(stack, plan)
	_twins(stack, plan, gate, lift)
	_assets_and_portal(mw)
	_flag_sites(stack, mw, plan)
	_idle_cost(mw)
	# Teardown gives the stack back exactly.
	mw.teardown(true)
	stack.remove_child(mw)
	mw.free()
	stack.mission = null
	await frames(1)
	var after := _fingerprint(stack)
	eq(after["walls"], before["walls"], "after teardown every Walls mesh is the baked one again")
	eq(after["disabled"], before["disabled"], "and no wall shape stays disabled")
	eq(after["shapes"], before["shapes"], "and the shape counts are the same")
	stack.queue_free()
	await frames(1)
	await _stepping()
	for seed_ in range(1, SEEDS_TO + 1):
		await _seed_sites(seed_)
	# The same with the section's road forms on (docs/design/city-variety.md: lanes, pedestrian streets, superblock
	# courts drawn by the city; the mix Missions will switch on). Issues are tagged "forms".
	for seed_ in range(1, SEEDS_TO + 1):
		await _seed_sites(seed_, true)
	print("[mission] plan issues for Missions (%d):" % issues.size())
	for line in issues:
		print("[mission]   " + line)
	finish()


## A MissionPlan (or stand-in) as a Dictionary of plain arrays (so a test can add sources).
func _as_dict(p: Variant) -> Dictionary:
	var out := {}
	for k: String in ["sources", "objectives", "pools"]:
		var a: Array = []
		for e: Variant in MissionWorld.field(p, k, []):
			a.append((e as Dictionary).duplicate(true) if e is Dictionary else e)
		out[k] = a
	return out


func _first_obj(plan: Dictionary, type: String) -> Variant:
	for o: Dictionary in plan["objectives"]:
		if o["type"] == type:
			return o["id"]
	return null


func _fingerprint(stack: CityStack) -> Dictionary:
	var walls := []
	var shapes := []
	var disabled := 0
	for d in stack.decks:
		var w := d.get_node("Walls") as MeshInstance3D
		var arr: Array = w.mesh.surface_get_arrays(0)
		walls.append([(arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), hash(arr[Mesh.ARRAY_VERTEX])])
		var col := d.get_node("Collision")
		shapes.append(col.get_child_count())
		for c in col.get_children():
			if (c as CollisionShape3D).disabled:
				disabled += 1
	return {"checksum": stack.checksum(), "walls": walls, "shapes": shapes, "disabled": disabled}


func _first(plan: Dictionary, kind: String, mw: MissionWorld) -> Variant:
	for s: Dictionary in plan["sources"]:
		if s["kind"] == kind and mw._doors.has(s["id"]):
			return s["id"]
	return null


func _state(mw: MissionWorld, id: Variant, t: float) -> String:
	mw.advance_to(t)
	return str(mw.source_state(id)["state"])


func _doors_over_time(mw: MissionWorld, id: Variant, kind: String) -> void:
	# open_at is the moment the leaves START to move; passable (fully open) passable_after(kind) s later; hold s open.
	var t_open := MissionWorld.passable_after(kind)
	eq(t_open, MissionWorld.OPENING if kind == "gate" else MissionWorld.LIFT_OPEN, "%s: passable_after" % kind)
	var base := 100.0 if kind == "gate" else 200.0
	mw.advance_to(base)
	eq(_state(mw, id, base), "shut", "%s: shut before any order" % kind)
	var oa := base + 10.0
	mw.open_source(id, oa, 12.0)
	eq(_state(mw, id, oa - 5.1), "shut", "%s: still shut 5.1 s before open_at" % kind)
	eq(_state(mw, id, oa - 4.9), "warn", "%s: warning from open_at - 5 s" % kind)
	eq(_state(mw, id, oa - 0.05), "warn", "%s: still warning (leaves still) just before open_at" % kind)
	eq(_state(mw, id, oa + 0.05), "opening", "%s: the leaves start to move at open_at" % kind)
	eq(bool(mw.source_state(id)["passable"]), false, "%s: not passable while opening" % kind)
	near(float(mw.source_state(id)["passable_at"]), oa + t_open, 1e-6, "%s: passable_at = open_at + %.1f" % [kind, t_open])
	eq(_state(mw, id, oa + t_open - 0.05), "opening", "%s: opening for %.1f s" % [kind, t_open])
	eq(_state(mw, id, oa + t_open + 0.01), "open", "%s: open at open_at + %.1f" % [kind, t_open])
	eq(bool(mw.source_state(id)["passable"]), true, "%s: passable once open" % kind)
	near(float(mw.source_state(id)["t"]), oa + t_open, 1e-6, "%s: open since passable_at" % kind)
	eq(_state(mw, id, oa + t_open + 11.9), "open", "%s: open through the hold" % kind)
	eq(_state(mw, id, oa + t_open + 12.5), "closing", "%s: closing after the hold" % kind)
	eq(bool(mw.source_state(id)["passable"]), false, "%s: not passable while closing" % kind)
	eq(_state(mw, id, oa + t_open + 14.1), "shut", "%s: shut 2 s later" % kind)
	# A late call snaps: the order arrives when the door should already be open.
	var oa2 := base + 40.0
	mw.open_source(id, oa2, 12.0)
	eq(_state(mw, id, oa2 + t_open + 0.5), "open", "%s: a late order snaps straight to open" % kind)
	# A repeat open while open only extends the hold and keeps the earlier open_at.
	mw.open_source(id, oa2 + 5.0, 12.0)
	near(float(mw.source_state(id)["open_at"]), oa2, 1e-6, "%s: a repeat open keeps the earlier open_at" % kind)
	near(float(mw.source_state(id)["close_at"]), oa2 + 17.0 + t_open, 1e-6, "%s: and extends the hold" % kind)
	mw.hold_source(id, oa2 + 30.0)
	eq(_state(mw, id, oa2 + 29.0), "open", "%s: hold_source keeps it open" % kind)
	eq(_state(mw, id, oa2 + 31.0), "closing", "%s: and it closes after" % kind)
	eq(_state(mw, id, oa2 + 40.0), "shut", "%s: shut again" % kind)


## The gate's collision: shut blocks at the wall plane, open lets a ray into the staging bay (stopped by its back wall),
## sealed blocks again; physically, through the physics server. And source_bay / source_point agree with the bay.
func _collision(stack: CityStack, mw: MissionWorld, id: Variant) -> void:
	var door := mw._doors[id] as MissionProps.GateDoor
	var space := stack.get_world_3d().direct_space_state
	var from := door.global_transform * Vector3(0, 3.0, 4.0)
	var to := door.global_transform * Vector3(0, 3.0, -40.0)
	var base := 300.0
	var sp := mw.source_point(id)
	var ext: Rect2 = stack.decks[int(sp["deck"])].plan.extent
	var spt := Vector2(float(sp["x"]), float(sp["s"]))
	check(not ext.grow(MissionProps.GateDoor.USE_FROM - 0.5).has_point(spt), "a gate's spawn point is in the bay, past the wall and the leaves")
	check(ext.grow(MissionProps.GateDoor.USE_TO).has_point(spt), "and in front of the back door")
	_bay(mw, id, sp)
	mw.advance_to(base)
	await frames(2)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	check(not hit.is_empty() and from.distance_to(hit["position"]) < 4.3, "gate shut: a ray stops at the door (%s)" % str(hit.get("position")))
	check(door.door_shape.disabled == false, "gate shut: the door shape is on")
	mw.open_source(id, base + 6.0, 10.0)
	mw.advance_to(base + 4.5)
	check(door.door_shape.disabled == false, "gate warning: solid")
	mw.advance_to(base + 7.5)
	check(door.door_shape.disabled == false, "gate opening: still solid until passable")
	mw.advance_to(base + 6.0 + MissionWorld.OPENING + 0.1)
	check(door.door_shape.disabled, "gate open: the door shape is off")
	await frames(2)
	hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	var back := 4.0 + MissionProps.GateDoor.BAY_DEPTH
	check(not hit.is_empty() and from.distance_to(hit["position"]) > back - 1.5, "gate open: a ray goes through the bay (%s)" % str(hit.get("position")))
	check(not hit.is_empty() and from.distance_to(hit["position"]) < back + 0.5, "and stops at the bay's back wall")
	var close_at := base + 6.0 + MissionWorld.OPENING + 10.0
	mw.advance_to(close_at + 1.0)
	check(door.door_shape.disabled, "gate closing: still open to walk through")
	mw.advance_to(close_at + MissionWorld.CLOSE + 0.5)
	check(not door.door_shape.disabled, "gate shut again: solid")
	mw.close_source(id)
	eq(str(mw.source_state(id)["state"]), "sealed", "close_source seals it")
	mw.advance_to(close_at + MissionWorld.CLOSE + 0.6)
	check(not door.door_shape.disabled, "sealed is solid")
	check(door.sealed_look.visible, "and looks welded")
	mw.open_source(id, base + 30.0)
	eq(_state(mw, id, base + 31.0), "sealed", "an order after sealing does nothing")
	eq(_state(mw, id, base + 100.0), "sealed", "sealed is final")


## source_bay(id): its keys, values that agree with the door (usable rectangle >= 20 m wide, clear height >= 12 m, facing
## into the map, exit in front, origin mid-depth behind door_s), source_point = its centre, the sign panel beside the frame;
## an unknown id or a lift gives {ok = false}.
func _bay(mw: MissionWorld, id: Variant, sp: Dictionary) -> void:
	var b := mw.source_bay(id)
	var door := mw._doors[id] as MissionProps.GateDoor
	if not check(bool(b.get("ok", false)), "source_bay is ok for a gate"):
		return
	for key: String in ["deck", "frame", "center", "x", "s", "h", "half_width", "depth_from", "depth_to", "height", "facing", "exit",
			"origin", "out", "width", "depth", "door_w", "door_h", "door_s", "door"]:
		check(b.has(key), "source_bay has %s" % key)
	near(float(b["x"]), float(sp["x"]), 1e-3, "source_point is the bay centre (x)")
	near(float(b["s"]), float(sp["s"]), 1e-3, "source_point is the bay centre (s)")
	check(float(b["width"]) >= 20.0 - 1e-3, "usable width >= 20 m (%.1f)" % float(b["width"]))
	check(float(b["depth"]) >= 16.0 - 1e-3, "usable depth %.1f m" % float(b["depth"]))
	check(float(b["height"]) >= 12.0, "clear height >= 12 m (%.2f)" % float(b["height"]))
	check(float(b["depth_to"]) <= MissionProps.GateDoor.BAY_DEPTH - 1.0, "usable depth ends clear of the back door")
	near(float(b["door_w"]), door.half * 2.0, 1e-3, "door_w")
	near(float(b["door_h"]), door.gh, 1e-3, "door_h")
	near((b["out"] as Vector2).length(), 1.0, 1e-4, "out is a unit vector")
	var fr := b["frame"] as Transform3D
	check((b["facing"] as Vector3).dot(fr.basis.z.normalized()) > 0.999, "facing is the frame's +Z (into the map)")
	check(((b["exit"] as Vector3) - fr.origin).dot(b["facing"]) > 5.0, "exit is on the street in front of the door")
	var o := b["origin"] as Vector2
	var out := b["out"] as Vector2
	var along := o.x if absf(out.x) > 0.5 else o.y
	near(absf(along - float(b["door_s"])), (float(b["depth_from"]) + float(b["depth_to"])) * 0.5, 0.05, "origin lies mid-depth behind door_s")
	eq(mw.source_bay("nope"), {"ok": false}, "an unknown id has no bay")
	for s: Dictionary in (MissionWorld.field(mw.plan, "sources", []) as Array):
		if str(s["kind"]) == "lift" and mw._doors.has(s["id"]):
			eq(bool(mw.source_bay(s["id"]).get("ok", true)), false, "a lift has no bay")
			break
	var panel := mw.source_sign_panel(id)
	if check(bool(panel.get("ok", false)), "a sign panel beside the frame"):
		eq(panel["size"], MissionProps.GateDoor.PANEL, "panel size")
		var pf := panel["frame"] as Transform3D
		check(pf.basis.z.normalized().dot(fr.basis.z.normalized()) > 0.999, "the panel faces the street")
		check(absf((fr.affine_inverse() * pf.origin).x) > door.half + 4.0, "beside the opening, past the buttress")


## close_source(id, at) while the door is open: it closes over 2 s from `at`, then is sealed; "seal" fires once at `at`;
## a late call snaps; snapshot / restore carry the time.
func _seal_while_open(mw: MissionWorld, id: Variant) -> void:
	var base := 600.0
	var clean := mw.snapshot()       # forget earlier schedules and seals (restore with none)
	clean.erase("sealed")
	clean["doors"] = {}
	clean["now"] = base
	mw.restore(clean)
	mw.advance_to(base)
	var got := []
	var cb := func(kind: String, i: Variant, _p: Vector3) -> void:
		if i == id:
			got.append([kind, mw.now])
	mw.source_event.connect(cb)
	mw.open_source(id, base + 6.0, 30.0)
	mw.close_source(id, base + 10.0)
	eq(_state(mw, id, base + 9.9), "open", "sealing later: still open before `at`")
	eq(_state(mw, id, base + 10.5), "closing", "an open door closes over 2 s from `at`")
	eq(_state(mw, id, base + 12.1), "sealed", "then it is sealed")
	var seals := 0
	for g: Array in got:
		if g[0] == "seal":
			seals += 1
			check(float(g[1]) >= base + 10.0 and float(g[1]) <= base + 10.5, "seal fires when the clock passes `at` (%.2f)" % float(g[1]))
	eq(seals, 1, "seal fires once")
	near(float(mw.source_state(id)["t"]), base + 10.0, 1e-6, "sealed since `at`")
	var snap := mw.snapshot()
	near(float((snap["sealed"] as Dictionary)[id]), base + 10.0, 1e-6, "the snapshot carries the seal time")
	mw.source_event.disconnect(cb)
	# Restore it as a late joiner at base + 11: still closing, then sealed.
	snap["now"] = base + 11.0
	mw.restore(snap)
	eq(str(mw.source_state(id)["state"]), "closing", "restored mid-closing")
	eq(_state(mw, id, base + 13.0), "sealed", "and sealed after")
	# Undo for the rest of the test (sealed is final, so restore without it).
	snap.erase("sealed")
	snap["doors"] = {}
	mw.restore(snap)


func _noop_ids(mw: MissionWorld) -> void:
	for id: Variant in ["ramp1", "shaft1", "nope", 12345]:
		mw.open_source(id, 1000.0)
		mw.hold_source(id, 2000.0)
		eq(_state(mw, id, 1000.5), "shut", "%s: accepted, nothing happens" % str(id))
	mw.close_source("nope")
	eq(mw.source_point("nope"), {}, "an unknown id has no point")
	var rp := mw.source_point("ramp1")
	eq([rp.get("deck"), rp.get("x"), rp.get("s")], [0, 0.0, 0.0], "a ramp source's point is the plan's point")
	eq(mw.flag_site("nope"), {}, "an unknown flag has no site")
	check(mw.asset_body("nope") == null, "an unknown asset has no body")
	mw.set_flag("nope", true)
	mw.set_asset("nope", 0.0)
	mw.set_zone("nope", "ours")


## Every scheduled moment fires its signal once, stepping finely; and a second open_source during the warning replays nothing.
func _signals(stack: CityStack, plan: Dictionary) -> void:
	var mw := MissionWorld.new()
	stack.add_child(mw)
	mw.setup(stack, {"sources": plan["sources"], "objectives": []})
	var got := []
	mw.source_event.connect(func(kind: String, id: Variant, _p: Vector3) -> void: got.append([kind, id]))
	var ids := []
	for s: Dictionary in plan["sources"]:
		if s["kind"] == "gate" or s["kind"] == "lift":
			ids.append(s["id"])
			if ids.size() >= 2:
				break
	mw.advance_to(0.0)
	for id: Variant in ids:
		mw.open_source(id, 10.0, 5.0)
	var t := 0.0
	while t < 25.0:
		t += 1.0 / 30.0
		if absf(t - 7.0) < 0.02:
			mw.open_source(ids[0], 9.0, 5.0)     # during the warning: extends nothing, replays nothing
		mw.advance_to(t)
	for id: Variant in ids:
		for kind: String in ["warn", "open", "close"]:
			eq(got.count([kind, id]), 1, "%s fires once for %s" % [kind, str(id)])
	mw.close_source(ids[0])
	mw.advance_to(26.0)
	mw.advance_to(27.0)
	eq(got.count(["seal", ids[0]]), 1, "seal fires once")
	# A jump far past a schedule fires nothing stale.
	got.clear()
	mw.open_source(ids[1], 40.0, 5.0)
	mw.advance_to(100.0)
	eq(got.size(), 0, "moments more than EVENT_STALE old fire nothing (%s)" % str(got))
	mw.teardown(true)
	stack.remove_child(mw)
	mw.free()


## Two MissionWorlds given the same calls, stepped at 60 Hz and at 7 Hz, end with the same snapshot; restore round trip.
func _twins(stack: CityStack, plan: Dictionary, gate: Variant, lift: Variant) -> void:
	var a := MissionWorld.new()
	var b := MissionWorld.new()
	stack.add_child(a)
	stack.add_child(b)
	var lite := {"sources": plan["sources"], "objectives": plan["objectives"]}
	a.setup(stack, lite)
	b.setup(stack, lite)
	var calls := [[5.0, "open", gate, 12.0], [5.0, "open", lift, 8.0], [9.0, "flag", true], [12.0, "asset", 0.4],
			[14.0, "hold", gate, 30.0], [20.0, "portal", 0.5], [22.0, "zone", "contested"], [26.0, "seal", lift]]
	for w: MissionWorld in [a, b]:
		var step := 1.0 / 60.0 if w == a else 1.0 / 7.0
		var t := 0.0
		var ci := 0
		while t < 40.0:
			while ci < calls.size() and float(calls[ci][0]) <= t:
				_call(w, calls[ci])
				ci += 1
			w.advance_to(t)
			t += step
		w.advance_to(40.0)
	eq(str(a.snapshot()), str(b.snapshot()), "two steppings, one snapshot")
	if gate != null:
		eq(a.source_state(gate)["state"], b.source_state(gate)["state"], "and the same gate state")
	# Restore a's snapshot into a fresh third one: the same snapshot and the same states.
	var c := MissionWorld.new()
	stack.add_child(c)
	c.setup(stack, lite)
	c.restore(a.snapshot())
	eq(str(c.snapshot()), str(a.snapshot()), "snapshot / restore round trip")
	for id: Variant in [gate, lift]:
		if id != null:
			eq(c.source_state(id)["state"], a.source_state(id)["state"], "restored state of %s" % str(id))
	check(c.flag_raised(flag_id) == a.flag_raised(flag_id), "restored flag")
	for w: MissionWorld in [a, b, c]:
		w.teardown(true)
		stack.remove_child(w)
		w.free()


func _call(w: MissionWorld, c: Array) -> void:
	match str(c[1]):
		"open":
			if c[2] != null:
				# The order time given: by default it is the caller's clock (the last advance_to), which differs by stepping.
				w.open_source(c[2], float(c[0]) + 6.0, float(c[3]), float(c[0]))
		"hold":
			if c[2] != null:
				w.hold_source(c[2], float(c[3]))
		"seal":
			if c[2] != null:
				w.close_source(c[2], float(c[0]))
		"flag": w.set_flag(flag_id, bool(c[2]), float(c[0]))
		"asset": w.set_asset(asset_id, float(c[2]))
		"portal": w.set_portal(float(c[2]))
		"zone": w.set_zone(flag_id, str(c[2]))


func _assets_and_portal(mw: MissionWorld) -> void:
	var body := mw.asset_body(asset_id)
	if check(body != null, "the defend relay has a body"):
		check(body.is_in_group("mission_asset"), "in group mission_asset")
		eq(body.get_meta("objective_id"), asset_id, "with meta objective_id")
		check(body.get_child_count() > 0, "with a shape")
	var told := []
	mw.asset_event.connect(func(id: Variant, kind: String, _p: Vector3) -> void: told.append([id, kind]))
	mw.set_asset(asset_id, 0.8)
	mw.set_asset(asset_id, 0.4)
	mw.set_asset(asset_id, 0.3)
	mw.set_asset(asset_id, 0.0)
	mw.set_asset(asset_id, 0.0)
	eq(told, [[asset_id, "damaged"], [asset_id, "destroyed"]], "asset events once each")
	var p := []
	mw.portal_event.connect(func(kind: String, _p: Vector3) -> void: p.append(kind))
	mw.set_portal(-1.0)
	near(mw.portal_progress, 0.0, 1e-6, "portal clamps at 0")
	mw.set_portal(0.3)
	mw.set_portal(0.6)
	mw.set_portal(2.0)
	near(mw.portal_progress, 1.0, 1e-6, "portal clamps at 1")
	mw.set_portal(1.0)
	eq(p, ["start", "open"], "portal events once each")
	check(mw._portal != null, "the extraction portal was found")
	var f := []
	mw.flag_event.connect(func(id: Variant, raised: bool, _p: Vector3) -> void: f.append([id, raised]))
	mw.set_flag(flag_id, true)
	mw.set_flag(flag_id, true)
	eq(f, [[flag_id, true]], "flag event once")
	mw.set_hold_zone("holding")
	eq(mw.hold_state, "holding", "hold zone state")
	mw.set_hold_zone("bogus")
	eq(mw.hold_state, "holding", "an unknown hold state is ignored")


func _flag_sites(stack: CityStack, mw: MissionWorld, plan: Dictionary) -> void:
	for o: Dictionary in plan["objectives"]:
		if o["type"] != "flag" and o["type"] != "defend":
			continue
		var site := mw.flag_site(o["id"]) if o["type"] == "flag" else mw.asset_site(o["id"])
		if not check(not site.is_empty(), "%s has a site" % o["id"]):
			continue
		var d := stack.decks[int(o["deck"])]
		var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
		var got := Vector2(float(site["x"]), float(site["s"]))
		check(got.distance_to(at) <= MissionWorld.snap_reach(o) + 0.01, "%s stands within its snap distance" % o["id"])
		if site["ok"]:
			var r := MissionWorld.FLAG_CLEAR if o["type"] == "flag" else MissionWorld.ASSET_CLEAR
			check(MissionProps.clear_at(d, got, r, MissionProps._blockers(d.plan), d.plan.floor_cuts()), "%s stands on clear ground" % o["id"])
		var avoid := []          # the pieces placed before it on its deck, as MissionWorld._site does
		for id: Variant in mw._sites:
			if id == o["id"]:
				break
			var o2: Dictionary = mw._sites[id]
			if int(o2["deck"]) == int(o["deck"]):
				avoid.append([Vector2(float(o2["x"]), float(o2["s"])), float(o2["clear"])])
		# The rule MissionWorld._site uses (the fit rule: snap_site's pick unless the widest mech cannot reach it; test_site_fit).
		var again := MissionProps.snap_site_fit(d, at, MissionWorld.snap_reach(o), MissionWorld.FLAG_CLEAR if o["type"] == "flag" else MissionWorld.ASSET_CLEAR,
				avoid, MissionWorld.obj_radius(o))
		check(is_equal_approx(float(again["x"]), got.x) and is_equal_approx(float(again["s"]), got.y), "%s: the snap is deterministic" % o["id"])


func _seed_sites(seed_: int, forms: bool = false) -> void:
	var stack := CityStack.new()
	add_child(stack)
	var so := {"seed": seed_}
	if forms:
		so.merge({"f_lane": 0.20, "f_pedestrian": 0.10, "f_none": 0.08})
	stack.build(SectionPlan.make(so))
	var n_issues := issues.size()
	var plan := _as_dict(MissionLab.make_plan(stack))
	var mw := stack.setup_mission(plan)
	_flag_sites(stack, mw, plan)
	var n_door := 0
	for s: Dictionary in plan["sources"]:
		var kind := str(s["kind"])
		if kind != "gate" and kind != "lift":
			continue
		if check(mw._doors.has(s["id"]), "seed %d: %s source %s found its door" % [seed_, kind, str(s["id"])]):
			n_door += 1
			_door_vs_point(seed_, stack, mw, s)
	for o: Dictionary in plan["objectives"]:
		if o["type"] == "flag" or o["type"] == "defend":
			var ext: Rect2 = stack.decks[int(o["deck"])].plan.extent
			if not ext.has_point(Vector2(float(o["site"]["x"]), float(o["site"]["s"]))):
				issues.append("seed %d %s (%s, deck %d): site (%.0f, %.0f) is outside the deck's walls %s" % [seed_, str(o["id"]), o["type"],
						int(o["deck"]), float(o["site"]["x"]), float(o["site"]["s"]), str(ext)])
			var site := mw.flag_site(o["id"]) if o["type"] == "flag" else mw.asset_site(o["id"])
			if not site.is_empty() and not site["ok"]:
				issues.append("seed %d %s (%s, deck %d): no clear ground within %.0f m of (%.0f, %.0f)" % [seed_, str(o["id"]), o["type"],
						int(o["deck"]), float(o["radius"]), float(o["site"]["x"]), float(o["site"]["s"])])
	# Chained defend beside its flag: never on the mast.
	for o: Dictionary in plan["objectives"]:
		if o["type"] != "defend":
			continue
		var a := mw.asset_site(o["id"])
		for f: Dictionary in plan["objectives"]:
			if f["type"] == "flag" and int(f["deck"]) == int(o["deck"]) and not a.is_empty():
				var fs := mw.flag_site(f["id"])
				var gap := Vector2(float(a["x"]), float(a["s"])).distance_to(Vector2(float(fs["x"]), float(fs["s"])))
				check(gap >= MissionWorld.FLAG_CLEAR + MissionWorld.ASSET_CLEAR - 0.01, "seed %d: relay %s stands clear of mast %s (%.1f m)" % [seed_, str(o["id"]), str(f["id"]), gap])
	if forms:
		for i in range(n_issues, issues.size()):
			issues[i] = "forms: " + str(issues[i])
	print("[mission] seed %d%s: %d doors" % [seed_, " (road forms)" if forms else "", n_door])
	stack.queue_free()
	await frames(1)


## advance_to with nothing moving costs next to nothing.
func _idle_cost(mw: MissionWorld) -> void:
	mw.advance_to(5000.0)
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		mw.advance_to(5000.0 + float(i) * 0.0005)
	var us := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[mission] idle advance_to: %.2f us per call" % us)
	check(us < 50.0, "idle advance_to is cheap (%.2f us)" % us)


## Triangles the mission adds per deck (every MeshInstance3D under its pieces, shown or not), for the doc.
func _report_tris(mw: MissionWorld) -> void:
	var per := {}
	for n: Variant in mw._all_nodes():
		var node := n as Node
		var k := int((node.get_parent() as CityDistrict).plan.deck)
		var tris := 0
		for mi in node.find_children("*", "MeshInstance3D", true, false) + ([node] if node is MeshInstance3D else []):
			var m := (mi as MeshInstance3D).mesh
			if m != null and m.get_surface_count() > 0:
				tris += (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		per[k] = int(per.get(k, 0)) + tris
		print("[mission] %s deck %d: %d tris" % [node.name, k, tris])
	print("[mission] triangles per deck: %s" % str(per))


## Report (to Missions) a source point inside a building / pillar footprint or the door's own geometry, and a door that faces
## away from its `toward` point.
func _door_vs_point(seed_: int, stack: CityStack, mw: MissionWorld, s: Dictionary) -> void:
	var k := int(s["deck"])
	var d := stack.decks[k]
	var door := mw._doors[s["id"]] as Node3D
	var pt := Vector2(float(s["x"]), float(s["s"]))
	var inv := door.transform.affine_inverse()
	var local := inv * d.ring.arc_to_world(pt.x, pt.y, 1.0)
	var what := "seed %d %s (%s, deck %d, (%.0f, %.0f))" % [seed_, str(s["id"]), s["kind"], k, pt.x, pt.y]
	if MissionProps._in_rects(MissionProps._blockers(d.plan), pt):
		issues.append(what + ": the source point is inside a building / pillar footprint")
	if local.z < 1.5:
		issues.append(what + ": the source point is at or behind the door plane (local z %.1f m)" % local.z)
	var tw: Dictionary = s.get("toward", {})
	if not tw.is_empty():
		var tl := inv * d.ring.arc_to_world(float(tw["x"]), float(tw["s"]), 1.0)
		if tl.z <= local.z:
			issues.append(what + ": its door faces away from `toward` (door z %.1f, toward z %.1f)" % [local.z, tl.z])


## The stepped setup (CityStack.setup_mission_begin / _step / _done / _progress): with a zero budget (one chunk a step)
## it gives the same snapshot, sites, nodes, walls and collision as setup_mission in one call; progress climbs to 1;
## calls before it is done do nothing; starting again mid-setup (a teardown) leaves nothing behind. Prints the chunk table.
func _stepping() -> void:
	var sec := SectionPlan.make({"seed": 1})
	var one := CityStack.new()
	add_child(one)
	one.build(sec)
	var two := CityStack.new()
	add_child(two)
	two.build(sec)
	var clean := _fingerprint(two)
	var plan_a := _as_dict(MissionLab.make_plan(one))
	var plan_b := _as_dict(MissionLab.make_plan(two))
	var mw_a := one.setup_mission(plan_a)
	# A setup interrupted half way, then begun again: the first one must leave nothing behind.
	two.setup_mission_begin(plan_b)
	for i in 6:
		two.setup_mission_step(0.0)
	var wip: MissionWorld = two._mission_wip
	check(two.mission == null and not two.setup_mission_done(), "mission is null until the setup is done")
	if wip != null:
		wip.open_source("nope", 1.0)
		wip.advance_to(3.0)
		wip.set_flag(flag_id, true)
		wip.set_portal(0.5)
		wip.restore({})
		eq(wip.source_state("nope")["state"], "shut", "calls before the setup is done do nothing")
	two.setup_mission_begin(plan_b)
	var last := -1.0
	var steps := 0
	var mono := true
	while not two.setup_mission_step(0.0):
		var p := two.setup_mission_progress()
		if p < last:
			mono = false
		last = p
		steps += 1
	check(mono, "progress never goes down")
	near(two.setup_mission_progress(), 1.0, 1e-6, "progress ends at 1")
	check(two.setup_mission_done() and two.mission != null, "done, and mission is set")
	var mw_b := two.mission
	print("[mission] stepped setup: %d steps" % steps)
	eq(str(mw_b.snapshot()), str(mw_a.snapshot()), "stepped and one-shot setups give the same snapshot")
	eq(str(mw_b._sites), str(mw_a._sites), "and the same sites")
	eq(_mission_nodes(two), _mission_nodes(one), "and the same nodes")
	var fa := _fingerprint(one)
	var fb := _fingerprint(two)
	eq(fb["walls"], fa["walls"], "and the same walls")
	eq(fb["disabled"], fa["disabled"], "and the same disabled wall shapes")
	eq(_body_shapes(two), _body_shapes(one), "and the same mission collision")
	# The chunk table (one-shot setup, this PC).
	var worst := 0.0
	var worst_label := ""
	var lines: Array[String] = []
	for c: Array in mw_a.chunk_log:
		lines.append("%s %.1f" % [c[0], float(c[1])])
		if float(c[1]) > worst:
			worst = float(c[1])
			worst_label = str(c[0])
	print("[mission] setup total %.1f ms in %d chunks, max %.1f ms (%s)" % [mw_a.setup_ms(), mw_a.chunk_log.size(), worst, worst_label])
	print("[mission] chunks: " + ", ".join(lines))
	# Teardown after a full stepped setup gives the clean stack back.
	two.setup_mission_begin(plan_b)
	for i in 4:
		two.setup_mission_step(0.0)
	var w2: MissionWorld = two._mission_wip
	if w2 != null:
		w2.teardown(true)
		two.remove_child(w2)
		w2.free()
		two._mission_wip = null
	await frames(1)
	var back := _fingerprint(two)
	eq(back["walls"], clean["walls"], "a setup torn down half way leaves the walls as built")
	eq(back["disabled"], clean["disabled"], "and no wall shape disabled")
	# A stack rebuild mid-setup is clean too.
	one.setup_mission_begin(plan_a)
	one.setup_mission_step(0.0)
	one.setup_mission_step(0.0)
	one.build(sec)
	check(one.mission == null and one._mission_wip == null, "a rebuild frees a setup in progress")
	one.queue_free()
	two.queue_free()
	await frames(1)


func _mission_nodes(st: CityStack) -> Array:
	var out := []
	for d in st.decks:
		for c in d.get_children():
			if str(c.name).begins_with("Mission"):
				out.append("%d/%s" % [d.plan.deck, c.name])
	out.sort()
	return out


func _body_shapes(st: CityStack) -> Array:
	var out := []
	for d in st.decks:
		for c in d.get_children():
			if not str(c.name).begins_with("Mission"):
				continue
			for b in c.find_children("*", "CollisionShape3D", true, false):
				var cs := b as CollisionShape3D
				out.append("%s %s %s" % [c.name, str(cs.transform.origin.snapped(Vector3.ONE * 0.001)), str(cs.disabled)])
	out.sort()
	return out
