extends TestCase
## Air doors (docs/design/city-ramps-and-stack.md "Air doors"): high hangar doors for dropships in the end walls, derived
## by MissionWorld from the stack (MissionAirDoors.spot). The guarantee sweep (_sweep: every deck of 120 + 30 sections has
## one or two usable doors, deterministic, checksummed). Over seeds 1, 4, 7, 403112, every deck: the count (printed as a table), each
## door in its end wall with its opening at 21 .. 27 m, 12 m wide, clear of every deck sign on its wall, of every gate's
## staging bay and span, and a dropship-sized box flies 40 m straight out of the opening into the deck without touching
## anything (physics), nor does the whole opening's box over its clear_len (usable, air_door_approach); the air_door
## dictionary; the door machinery (warn silent, opening with alarm and siren on the active
## deck, passable after OPENING, closing, sealed, snapshot / restore); source_point = hide, source_bay {ok = false}; the
## wrappers; the wall face and a farm wall leave the opening clear (no wall triangle inside the opening); teardown gives
## the district back exactly.

const SEEDS := [1, 4, 7, 403112]
const HULL := Vector3(5.2 + 1.6 * 2.0 - 1.0, 2.8 + 1.0, 1.0)     ## the box flown out (a dropship hull's width + margins, a thin slice)

var table: Array[String] = []


func setup() -> void:
	timeout_sec = 240.0
	_sweep()
	for seed_: int in SEEDS:
		await _seed(seed_)
	print("[air] placement (seed, deck, wall, kind, x, avenue centre, offset):")
	for line in table:
		print("[air]   " + line)
	finish()


func _seed(seed_: int) -> void:
	var sec := SectionPlan.make({"seed": seed_})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	var before := _fingerprint(stack)
	var mw := stack.setup_mission(MissionLab.make_plan(stack))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := stack.get_world_3d().direct_space_state
	var av := sec.lane_x("avenue")
	var centre := (av.x + av.y) * 0.5
	var total := 0
	for k in stack.decks.size():
		var d := stack.decks[k]
		var n := mw.air_door_count(k)
		total += n
		check(n >= 1 and n <= 2, "seed %d deck %d: one or two air doors (%d)" % [seed_, k, n])
		var signs := CitySigns.layout(d.plan, d.ring)
		var planned := MissionAirDoors.doors(d.plan)
		eq(planned.size(), n, "seed %d deck %d: MissionAirDoors.doors(plan) gives the doors built" % [seed_, k])
		_signs_in_keep_outs(d, signs, planned, "seed %d deck %d" % [seed_, k])
		for i in n:
			var a := mw.air_door(k, i)
			if not check(bool(a.get("ok", false)), "seed %d deck %d door %d: air_door ok" % [seed_, k, i]):
				continue
			var id := str(a["id"])
			eq(id, "air_d%d_%d" % [k, i], "the id")
			for key: String in ["deck", "frame", "center", "x", "s", "h_bottom", "h_top", "width", "height", "depth", "hide", "out", "facing"]:
				check(a.has(key), "%s: air_door has %s" % [id, key])
			near(float(a["h_bottom"]), 21.0, 1e-6, "%s: sill 21 m" % id)
			near(float(a["h_top"]), 27.0, 1e-6, "%s: head 27 m" % id)
			check(float(a["width"]) >= 10.0 and float(a["height"]) >= 6.0, "%s: opening %.0f x %.0f m" % [id, float(a["width"]), float(a["height"])])
			var src: Dictionary = mw._sources[id]
			var side := CityPlan.SIDE_EDGE.find(str(src["edge"]))
			check(side >= 2, "%s: on an end wall (%s)" % [id, str(src["edge"])])
			var w: Dictionary = d.plan.boundary()[side]
			near(float(a["s"]), float(w["at"]), 0.01, "%s: on the wall plane" % id)
			var x := float(a["x"])
			if i < planned.size():
				near(x, float(planned[i]["c"]), 1e-6, "%s: where MissionAirDoors.doors(plan) puts it" % id)
			check(x - MissionAirDoors.half() > d.plan.extent.position.x and x + MissionAirDoors.half() < d.plan.extent.end.x, "%s: inside its wall" % id)
			table.append("seed %d deck %d %s (%s): x %.1f, avenue %.1f, offset %.1f" % [seed_, k, str(src["edge"]), str(w["kind"]), x, centre, x - centre])
			# Clear of signs on its wall and of gates' bays.
			var hole := MissionAirDoors.hole(x)
			for s: Dictionary in signs:
				if int(s.get("side", -1)) != side:
					continue
				var overlap := float(s["u1"]) > float(hole["fa"]) and float(s["u0"]) < float(hole["fb"]) \
						and float(s["y1"]) > float(hole["fy0"]) and float(s["y0"]) < float(hole["fy1"])
				check(not overlap, "%s: clear of the %s sign at u %.1f..%.1f y %.1f..%.1f" % [id, s["kind"], float(s["u0"]), float(s["u1"]), float(s["y0"]), float(s["y1"])])
			for g: Dictionary in w["gates"]:
				var mid := (float(g["a"]) + float(g["b"])) * 0.5
				var r := maxf(MissionWorld.bay_half(d, w, g), (float(g["b"]) - float(g["a"])) * 0.5) + MissionGateDoor.PLATE
				check(absf(x - mid) >= r + MissionAirDoors.half(), "%s: clear of the %s gate at %.0f (%.1f m apart)" % [id, g["kind"], mid, absf(x - mid)])
			# The flight corridor: a hull-sized box from in front of the frame 40 m into the deck touches nothing.
			var fr := a["frame"] as Transform3D
			var q := PhysicsShapeQueryParameters3D.new()
			var box := BoxShape3D.new()
			box.size = HULL
			q.shape = box
			q.transform = Transform3D(fr.basis, fr * Vector3(0, 0, 3.0))
			var hull_len := minf(MissionAirDoors.CORRIDOR, float(a.get("clear_len", 0.0)) - 0.5)     # 40 m, or the usable 30+ m of a door the first pass did not place
			q.motion = fr.basis.z.normalized() * (hull_len - 3.0)
			var r := space.cast_motion(q)
			check(r[0] >= 1.0, "%s: the flight corridor is clear for %.0f m (stopped at %.0f %%)" % [id, hull_len, float(r[0]) * 100.0])
			# Usable (R2.24): the whole opening (12 x 6 m, less 0.2 m round) flies straight clear_len m in (physics).
			check(bool(a["usable"]) and float(a["clear_len"]) >= MissionAirDoors.APPROACH, "%s: usable, %.1f m clear approach" % [id, float(a["clear_len"])])
			if i < planned.size():
				near(float(a["clear_len"]), float(planned[i]["clear_len"]), 1e-6, "%s: clear_len is the plan's" % id)
			var ap := mw.air_door_approach(k, i)
			check(bool(ap.get("ok", false)) and (ap["from"] as Vector3).is_equal_approx(a["center"]) \
					and absf((ap["to"] as Vector3).distance_to(ap["from"]) - float(a["clear_len"])) < 1e-3, "%s: air_door_approach from the opening, clear_len along facing" % id)
			var big := BoxShape3D.new()
			big.size = Vector3(MissionAirDoors.W - 0.4, MissionAirDoors.HEAD - MissionAirDoors.SILL - 0.4, 1.0)
			q.shape = big
			q.motion = fr.basis.z.normalized() * (float(a["clear_len"]) - 3.5)     # its front face (0.5 m ahead) to clear_len
			var rb := space.cast_motion(q)
			check(rb[0] >= 1.0, "%s: the opening's box flies %.0f m in (stopped at %.0f %%)" % [id, float(a["clear_len"]), float(rb[0]) * 100.0])
			eq(mw.source_bay(id), {"ok": false}, "%s: no staging bay" % id)
			var sp := mw.source_point(id)
			check(Vector2(float(sp["x"]), float(sp["s"])).distance_to(Vector2(x, float(w["at"]) + (1.0 if side == 2 else -1.0) * MissionWorld.AIR_HIDE)) < 0.05,
					"%s: source_point is the hide point in the recess" % id)
			_no_wall_in_opening(d, mw._doors[id] as MissionGateDoor, id)
	check(total >= 1, "seed %d: at least one air door on the stack (%d)" % [seed_, total])
	if total > 0:
		await _machinery(stack, mw, seed_)
	mw.teardown(true)
	stack.remove_child(mw)
	mw.free()
	stack.mission = null
	await frames(1)
	var after := _fingerprint(stack)
	eq(after, before, "seed %d: teardown gives every Walls mesh and shape back" % seed_)
	stack.queue_free()
	await frames(2)


## The guarantee (R2.24, plan data only): over SWEEP section seeds (3 decks, and SWEEP / 4 of 2 decks), every deck has one
## or two air doors, one per end wall, every one usable (clear_len >= APPROACH, the same as approach_len); the same doors
## and checksum from a plan made again (determinism); a checksum that sees a moved door. Before R2.24, seed 261 deck 1 had
## none and about 1 door in 19 was not usable (seed 1 deck 1: both).
const SWEEP := 120
const SWEEP_DECKS := [3, 2]


func _sweep() -> void:
	var dist := {}
	for nd: int in SWEEP_DECKS:
		for seed_ in range(1, (SWEEP if nd == 3 else SWEEP / 4) + 1):
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(nd)})
			for k in sec.deck_count:
				var plan := CityPlan.for_deck(sec, k)
				var ds := MissionAirDoors.doors(plan)
				var what := "decks %d seed %d deck %d" % [nd, seed_, k]
				dist[ds.size()] = int(dist.get(ds.size(), 0)) + 1
				if not check(ds.size() >= 1 and ds.size() <= 2, "%s: one or two air doors (%d)" % [what, ds.size()]):
					continue
				var sides := {}
				for ad: Dictionary in ds:
					check(not sides.has(ad["side"]), "%s: one door per wall" % what)
					sides[ad["side"]] = true
					check(bool(ad["usable"]) and float(ad["clear_len"]) >= MissionAirDoors.APPROACH,
							"%s %s: usable (%.1f m clear)" % [what, CityPlan.SIDE_EDGE[int(ad["side"])], float(ad["clear_len"])])
					near(float(ad["clear_len"]), MissionAirDoors.approach_len(plan, ad["wall"], float(ad["c"])), 1e-9, "%s: clear_len is approach_len" % what)
				if seed_ % 10 == 0:
					var again := CityPlan.for_deck(SectionPlan.make({"seed": float(seed_), "decks": float(nd)}), k)
					var ds2 := MissionAirDoors.doors(again)
					eq(ds2.size(), ds.size(), "%s: the same doors from the plan made again" % what)
					for i in mini(ds.size(), ds2.size()):
						check(float(ds2[i]["c"]) == float(ds[i]["c"]) and float(ds2[i]["clear_len"]) == float(ds[i]["clear_len"]), "%s door %d: deterministic" % [what, i])
					eq(MissionAirDoors.checksum(again), MissionAirDoors.checksum(plan), "%s: the same air checksum" % what)
	print("[air] guarantee sweep (decks with n doors: n -> count): %s" % str(dist))
	# The checksum sees a door that moved: a tower planted in seed 1 deck 0's first door's approach slides it along the wall.
	var plan := CityPlan.for_deck(SectionPlan.make({"seed": 1.0}), 0)
	var sum := MissionAirDoors.checksum(plan)
	var ad: Dictionary = MissionAirDoors.doors(plan)[0]
	var w: Dictionary = ad["wall"]
	var inward := -1.0 if int(w["side"]) % 2 == 0 else 1.0
	plan.buildings.append({"center": Vector2(float(ad["c"]), float(w["at"]) + inward * 12.0), "size": Vector2(6.0, 6.0), "pillar": false,
			"tiers": [{"off": Vector2.ZERO, "size": Vector2(6.0, 6.0), "y0": 0.0, "y1": 30.0, "stand": false}], "solids": []})
	var moved: Dictionary = MissionAirDoors.doors(plan)[0]
	check(float(moved["c"]) != float(ad["c"]) and bool(moved["usable"]), "a tower in the approach slides the door along its wall (%.1f -> %.1f)" % [float(ad["c"]), float(moved["c"])])
	check(MissionAirDoors.checksum(plan) != sum, "and the air checksum sees it")
	plan.buildings.pop_back()
	eq(MissionAirDoors.checksum(plan), sum, "and is back without it")


## The looks fit the gameplay keep-outs (2026-11-25: air doors are placed from plan data alone, MissionAirDoors.spot):
## every over-gate deck sign within GATE_SIGN_HALF of its gate's centre line, every hung ramp sign inside its ramp's
## keep-out (MissionAirDoors.ramp_keep_out) or clear of every door's flight corridor, and no other sign on an end wall over a door's frame
## (the frame check per door, below).
func _signs_in_keep_outs(d: CityDistrict, signs: Array, planned: Array, what: String) -> void:
	var walls := d.plan.boundary()
	for s: Dictionary in signs:
		match str(s["kind"]):
			"over_gate":
				var side := int(s["side"])
				var mid := (float(s["u0"]) + float(s["u1"])) * 0.5
				var gate_mid := INF
				for w: Dictionary in walls:
					if int(w["side"]) == side:
						for g: Dictionary in w["gates"]:
							var gm := (float(g["a"]) + float(g["b"])) * 0.5
							if absf(gm - mid) < absf(gate_mid - mid):
								gate_mid = gm
				check(absf(mid - gate_mid) < 0.01 and float(s["u1"]) - float(s["u0"]) <= MissionAirDoors.GATE_SIGN_HALF * 2.0 + 1e-4,
						"%s: the over-gate sign (%.1f m wide) fits the band kept over its gate (%.1f m)" % [what, float(s["u1"]) - float(s["u0"]),
						MissionAirDoors.GATE_SIGN_HALF * 2.0])
			"ramp":
				var at: Vector2 = s["at"]
				var panel := Rect2(at - Vector2(float(s["w"]) * 0.5, CitySigns.HANG_T), Vector2(float(s["w"]), CitySigns.HANG_T * 2.0))
				var inside := MissionAirDoors.ramp_keep_out(d.plan.ramps[int(s["ramp"])]).encloses(panel)
				var clear := true
				for ad: Dictionary in planned:
					var w: Dictionary = ad["wall"]
					var inward := -1.0 if int(w["side"]) % 2 == 0 else 1.0
					var s0 := minf(float(w["at"]), float(w["at"]) + inward * MissionAirDoors.CORRIDOR)
					var c := float(ad["c"])
					var cor := Rect2(c - MissionAirDoors.W * 0.5 - MissionAirDoors.MARGIN, s0, MissionAirDoors.W + MissionAirDoors.MARGIN * 2.0, MissionAirDoors.CORRIDOR)
					if cor.intersects(panel):
						clear = false
				check(inside or clear, "%s: the ramp %d sign at %s lies in its ramp's keep-out or clear of every flight corridor" % [what, int(s["ramp"]), str(at)])


func _fingerprint(stack: CityStack) -> Array:
	var out := []
	for d in stack.decks:
		var wm := d.get_node("Walls") as MeshInstance3D
		var arr: Array = wm.mesh.surface_get_arrays(0)
		var col := d.get_node("Collision")
		var dis := 0
		for c in col.get_children():
			dis += 1 if (c as CollisionShape3D).disabled else 0
		out.append([(arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), hash(arr[Mesh.ARRAY_VERTEX]), col.get_child_count(), dis])
	return out


## No triangle of the deck's Walls mesh (wall face, farm backing, racks, fins, bars, posts) lies inside the opening's box
## (the wall plane 2 m out to 1.8 m in, the opening less 0.2 m): the opening is clear to see and fly through.
func _no_wall_in_opening(d: CityDistrict, door: MissionGateDoor, id: String) -> void:
	var wm := d.get_node("Walls") as MeshInstance3D
	var arr: Array = wm.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var inv := door.transform.affine_inverse() * wm.transform
	var hx := door.half - 0.2
	var bad := 0
	var i := 0
	while i < verts.size():
		var c := (inv * verts[i] + inv * verts[i + 1] + inv * verts[i + 2]) / 3.0
		if absf(c.x) < hx and c.y > 0.2 and c.y < door.gh - 0.2 and c.z < 2.0 and c.z > -1.8:
			bad += 1
		i += 3
	eq(bad, 0, "%s: no wall / farm triangle inside the opening" % id)


## The door machinery for the first air door: warn silent, opening with the alarm (siren on its deck only), passable,
## closing, a restore mid-opening, sealed solid; the wrappers.
func _machinery(stack: CityStack, mw: MissionWorld, seed_: int) -> void:
	var k := -1
	for kk in stack.decks.size():
		if mw.air_door_count(kk) > 0:
			k = kk
			break
	var id := str(mw.air_door(k, 0)["id"])
	var door := mw._doors[id] as MissionGateDoor
	stack.set_active_deck(k)
	eq(MissionWorld.passable_after("air"), MissionWorld.OPENING, "air doors open over OPENING s")
	var base := 100.0
	mw.advance_to(base)
	mw.open_air_door(k, 0, base + 6.0, 5.0)
	mw.advance_to(base + 2.0)
	eq(str(mw.source_state(id)["state"]), "warn", "seed %d %s: warn" % [seed_, id])
	check(not mw.alarm(id) and not door.siren_on, "warn is silent")
	check(not door.door_shape.disabled, "shut while warning")
	mw.advance_to(base + 6.5)
	eq(str(mw.source_state(id)["state"]), "opening", "opening from open_at")
	check(mw.alarm(id) and door.siren_on and door.lamps_lit(), "the alarm and siren run while it opens")
	check(not mw.air_door_passable(k, 0), "not passable while opening")
	check(door.door_shape.disabled, "not solid while the leaves move (R2.11a: MissionGateDoor.blocks)")
	var snap := mw.snapshot()
	mw.advance_to(base + 9.1)
	check(mw.air_door_passable(k, 0) and door.door_shape.disabled, "passable (and open) at open_at + OPENING")
	check(not mw.alarm(id) and not door.siren_on, "the siren stops once open")
	near(float(mw.source_state(id)["passable_at"]), base + 9.0, 1e-6, "passable_at")
	mw.advance_to(base + 15.0)
	eq(str(mw.source_state(id)["state"]), "closing", "closes after the hold")
	snap["now"] = base + 7.0
	mw.restore(snap)
	eq(str(mw.source_state(id)["state"]), "opening", "restored mid-opening")
	check(door.siren_on, "restored: siren on")
	var other := (k + 1) % stack.decks.size()
	stack.set_active_deck(other)
	mw.advance_to(base + 7.5)
	check(mw.alarm(id) and not door.siren_on, "on another deck the siren is quiet")
	stack.set_active_deck(k)
	mw.advance_to(base + 30.0)
	mw.close_air_door(k, 0)
	mw.advance_to(base + 31.0)
	eq(str(mw.source_state(id)["state"]), "sealed", "close_air_door seals it")
	check(not door.door_shape.disabled and door.sealed_look.visible, "sealed: solid and welded")
	eq(mw.air_door(k, 9), {"ok": false}, "no such door: ok false")
	check(not mw.air_door_passable(k, 9), "no such door: not passable")
