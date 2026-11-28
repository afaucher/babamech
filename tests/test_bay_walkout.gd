extends TestCase
## THE CREW WALKS STRAIGHT OUT OF THE ENTRY BAY (R2.11a, 2026-11-27; MissionWorld.slot_layout / bay_slots). On the 40 m
## spine the entry bay sits off the door's centre (beside the tram tunnel); a mech spawned in any slot that walks straight
## along its facing must pass the open door without touching a jamb. For section seeds 1..30, with the real stack and
## mission (MissionLab.make_plan), the entry door open: every slot of entry_bay_slots(4) (and the lone slot of
## entry_bay_slots(1)) holds a Strider (r 2.2) and a Bulwark (r 3.6) capsule standing there, and each capsule swept along
## the slot's facing from the slot to 6 m past the door plane touches nothing. Slots are >= 7.2 m apart. The exit bay's
## slots face in and need no aim.

const SEEDS := 30
const PAST := 6.0
const STEP := 2.0      ## m per swept piece
const LIFT := 0.5      ## m the swept capsule rides above the slot (kerbs, the ring's curve; its 8 m top stays under the 9 m lintel)
const CAPS := {"strider": [2.2, 8.0], "bulwark": [3.6, 8.0]}   ## radius, height (MechCatalog capsule_radius / capsule_height)

var sweeps := 0
var aimed := 0


func _init() -> void:
	timeout_sec = 600.0


func setup() -> void:
	for seed_ in range(1, SEEDS + 1):
		await _seed(seed_)
	print("[bay_walkout] %d capsule sweeps, %d slots aimed at the door" % [sweeps, aimed])
	check(sweeps >= SEEDS * 5 * 2, "every slot swept with both capsules (%d)" % sweeps)
	finish()


func _seed(seed_: int) -> void:
	var sec := SectionPlan.make({"seed": seed_})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	for d in stack.decks:
		d.props.set_physics_process(false)
	var mw := stack.setup_mission(MissionLab.make_plan(stack))
	var t := maxf(mw.now, MissionWorld.OPENING + 1.0) + 1.0
	mw.advance_to(t)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var e := mw.entry_door()
	if not check(bool(e.get("ok", false)) and str(mw.source_state(MissionWorld.ENTRY_ID)["state"]) == "open", "seed %d: the entry door is built and open" % seed_):
		stack.queue_free()
		await frames(2)
		return
	var door := mw._doors[MissionWorld.ENTRY_ID] as MissionGateDoor
	var fr := e["frame"] as Transform3D
	var out_dir := (e["facing"] as Vector3).normalized()
	var space := stack.get_world_3d().direct_space_state
	var lay := MissionWorld.slot_layout(door.ix0, door.ix1, door.half, door.w_out, 4)
	print("seed %d: bay %.2f..%.2f (door clear half %.2f): slots %s" % [seed_, door.ix0, door.ix1, door.half,
			str(lay.map(func(sl: Dictionary) -> String: return "(%.2f, %.1f%s)" % [sl["x"], sl["depth"],
					"" if is_nan(float(sl["aim"])) else ", aim %.2f" % float(sl["aim"])]))])
	for sl: Dictionary in lay:
		if not is_nan(float(sl["aim"])):
			aimed += 1
	var slots: Array[Transform3D] = mw.bay_slots(MissionWorld.ENTRY_ID, 4, true)
	slots.append_array(mw.bay_slots(MissionWorld.ENTRY_ID, 1, true))
	for i in slots.size():
		var xf := slots[i]
		var tag := "seed %d entry slot %d%s" % [seed_, i, " (alone)" if i == 4 else ""]
		var fwd := -xf.basis.z.normalized()
		check(fwd.dot(out_dir) > 0.7, "%s faces out of the bay" % tag)
		if i < 4:
			for j in i:
				check(xf.origin.distance_to(slots[j].origin) >= 7.2 - 0.01, "%s: %.2f m from slot %d" % [tag, xf.origin.distance_to(slots[j].origin), j])
		# Distance along the facing to PAST m beyond the door plane (the plane through the frame origin, normal out_dir).
		var to_plane := (fr.origin - xf.origin).dot(out_dir) / maxf(fwd.dot(out_dir), 1e-3)
		var travel := to_plane + PAST / maxf(fwd.dot(out_dir), 1e-3)
		for cname: String in CAPS:
			var cap := CapsuleShape3D.new()
			cap.radius = float(CAPS[cname][0])
			cap.height = float(CAPS[cname][1])
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = cap
			q.transform = Transform3D(xf.basis, xf.origin + xf.basis.y * (cap.height * 0.5 + LIFT))
			var stands := space.intersect_shape(q, 1).is_empty()
			check(stands, "%s: a %s capsule fits there" % [tag, cname])
			# Walk the straight line in the deck's arc plane (x, s) in STEP m pieces, each piece swept from the floor under
			# its start to the floor under its end (LIFT above it): the mech follows the ring's floor, not its tangent.
			var k0 := int(e["deck"])
			var a0 := stack.to_deck_arc(xf.origin)
			var a1 := stack.to_deck_arc(xf.origin + fwd * travel)
			var from2 := Vector2(float(a0["x"]), float(a0["s"]))
			var to2 := Vector2(float(a1["x"]), float(a1["s"]))
			var pieces := int(ceil(from2.distance_to(to2) / STEP))
			var hit := ""
			var stopped := -1.0
			for pc in pieces:
				var pa := from2.lerp(to2, float(pc) / float(pieces))
				var pb := from2.lerp(to2, float(pc + 1) / float(pieces))
				var wa := stack.from_deck_arc(k0, pa.x, pa.y, 0.3 + LIFT)
				var wb := stack.from_deck_arc(k0, pb.x, pb.y, 0.3 + LIFT)
				var up := stack.ring().up_at(wa)
				q.transform = Transform3D(stack.ring().basis_at(wa, wb - wa), wa + up * (cap.height * 0.5))
				q.motion = wb - wa
				var frac := space.cast_motion(q)
				if frac.size() > 0 and frac[0] < 1.0:
					stopped = (float(pc) + frac[0]) / float(pieces)
					q.transform = Transform3D(q.transform.basis, q.transform.origin + (wb - wa) * frac[1])
					q.motion = Vector3.ZERO
					var res := space.intersect_shape(q, 1)
					if not res.is_empty():
						var col: Object = res[0]["collider"]
						hit = col.name if col is Node else str(col)
					break
			sweeps += 1
			check(stopped < 0.0, "%s: a %s walking straight out along its facing clears the door (%.1f m, stopped at %.0f %% by %s)" % [
					tag, cname, travel, 100.0 * stopped, hit])
	# The exit bay faces in, no aim.
	var xs := mw.exit_bay_slots(4)
	var x := mw.exit_door()
	for i in xs.size():
		check((-xs[i].basis.z).dot(x["facing"] as Vector3) < -0.99, "seed %d exit slot %d faces straight in" % [seed_, i])
	stack.queue_free()
	await frames(2)
