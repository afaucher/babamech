extends TestCase
## Hangar v2 egress through the shared bay airlock (docs/design/hangar-v2/README.md). Sizes from the catalog:
##   - a lane is wider than every chassis (measured box) and its catalog capsule (bay half scale); the doors span every
##     lane and are taller than every chassis; a lane holds the deepest + the shallowest chassis (so 4 Striders and
##     2 Bulwarks + 2 Striders go in one cycle, 3 or 4 Bulwarks in two).
## For crews (solo Strider, solo Bulwark, Strider + Bulwark, 4 Striders, 2 Bulwarks + 2 Striders, 4 Bulwarks), stepped
## at a fixed 1/30 s with the bay's own clock stopped:
##   - the planned group count is right, and the group cycles run in order;
##   - no two mechs' boxes overlap at any step; in the alcove row every mech stays between its alcove's posts;
##   - no mech's box reaches into the inner door's wall while the inner door is not fully open, nor the outer one's;
##   - every mech ends out of sight (past the outer door, hidden), the doors end shut and green, the clamps opened
##     before each mech moved; the dry-run duration matches the real run;
##   - set_alert(false) puts every mech back in its cradle, visible.

const DT := 1.0 / 30.0
const TOL := 0.02


func setup() -> void:
	var bay := HangarBay.new()
	bay.own_environment = false
	add_child(bay)
	await frames(2)
	bay.time_scale = 0.0
	var lw := HangarBay.lane_width()
	var span := HangarBay.door_span()
	for id: String in MechCatalog.CHASSIS:
		var e := HangarBay.chassis_envelope(id)
		var half := maxf(absf(e.position.x), absf(e.end.x))
		check(lw >= half * 2.0 + 0.2, "a lane (%.2f m) is wider than the %s (%.2f m)" % [lw, id, half * 2.0])
		var cap := float(MechCatalog.movement(id)["capsule_radius"]) * 2.0 / HangarEgress.GAME_SCALE
		check(lw >= cap, "a lane is wider than the %s's capsule (%.2f m in the bay)" % [id, cap])
		check(HangarBay.door_height() >= e.end.y + 0.2, "the doors (%.2f m) are taller than the %s (%.2f m)" % [HangarBay.door_height(), id, e.end.y])
	near(span.y - span.x, lw * HangarBay.LANES, 0.001, "the doors span every lane")
	check(span.x > HangarBay.FRONT_Z + 1.0, "the doors open onto the aisle, clear of the alcove row")
	var s := {"head": "chicken", "chassis": "strider"}
	var b := {"head": "dog", "chassis": "bulwark"}
	for c: Array in [[[s], 1], [[b], 1], [[s, b], 1], [[s, s, s, s], 1], [[b, s, b, s], 1], [[b, b, b, b], 2]]:
		await _run(bay, c[0] as Array, int(c[1]))
	bay.queue_free()
	finish()


func _run(bay: HangarBay, crew: Array, want_groups: int) -> void:
	var entries: Array = []
	for i in crew.size():
		var e: Dictionary = (crew[i] as Dictionary).duplicate()
		e["loadout"] = HangarBay.WIDE_LOADOUT
		entries.append(e)
	bay.show_crew(entries)
	await frames(1)
	var tag := "+".join(crew.map(func(e: Dictionary) -> String: return str(e["chassis"])))
	for i in bay.models.size():
		check(bay.clamp_amount(i) > 0.99, "%s: seat %d is clamped while stored" % [tag, i + 1])
	bay.set_alert(true)
	var eg := bay.egress()
	check(eg != null and eg.walkers.size() == crew.size(), "%s: a walker per mech" % tag)
	eq(eg.groups.size(), want_groups, "%s: %d airlock cycle(s)" % [tag, want_groups])
	var natural := eg.duration(bay)
	var al := bay.airlock()
	var in_wall := Vector2(HangarBay.AIRLOCK_X - HangarBay.END_WALL, HangarBay.AIRLOCK_X)
	var out_wall := Vector2(HangarBay.chamber_far_x() - HangarBay.END_WALL, HangarBay.chamber_far_x())
	var door_bad := 0
	var post_bad := 0
	var overlap := 0
	var clamp_bad := 0
	var order_bad := 0
	var last_group := 0
	var t := 0.0
	while not eg.finished() and t < 120.0:
		bay.egress_step(DT)
		t += DT
		if eg.group < last_group:
			order_bad += 1
		last_group = eg.group
		var boxes: Array[AABB] = []
		for i in bay.models.size():
			var m := bay.models[i]
			if not m.visible:
				continue
			var box := HangarBay.mesh_box(m, bay)
			boxes.append(box)
			var cx := float(HangarBay.ALCOVE_X[i])
			if box.position.x < in_wall.y - TOL and box.end.x > in_wall.x and al.inner_k < 0.999:
				door_bad += 1
			if box.position.x < out_wall.y - TOL and box.end.x > out_wall.x and al.outer_k < 0.999:
				door_bad += 1
			if box.position.z < HangarBay.FRONT_Z - 0.3 and box.position.x > HangarBay.AIRLOCK_X:
				if box.position.x < cx - HangarBay.ALCOVE_HALF - TOL or box.end.x > cx + HangarBay.ALCOVE_HALF + TOL:
					post_bad += 1
			if m.position.distance_to(Vector3(cx, HangarBay.PLATFORM_H, HangarBay.MECH_Z)) > 0.05 and bay.clamp_amount(i) > 0.01:
				clamp_bad += 1
		for a in boxes.size():
			for c in range(a + 1, boxes.size()):
				if boxes[a].grow(-TOL).intersects(boxes[c].grow(-TOL)):
					overlap += 1
	check(eg.finished(), "%s: the egress finishes (%.1f s)" % [tag, t])
	near(t, natural, 0.2, "%s: the dry run's duration matches (%.1f vs %.1f s)" % [tag, natural, t])
	eq(order_bad, 0, "%s: the cycles run in order" % tag)
	eq(door_bad, 0, "%s: no mech reaches into a door that is not fully open" % tag)
	eq(post_bad, 0, "%s: in the alcove row every mech stays between its posts" % tag)
	eq(overlap, 0, "%s: no two mechs overlap" % tag)
	eq(clamp_bad, 0, "%s: the clamps are open whenever a mech has moved" % tag)
	for i in bay.models.size():
		check(not bay.models[i].visible, "%s: seat %d has gone through the airlock" % [tag, i + 1])
		check(bay.models[i].position.x < HangarBay.chamber_far_x() - HangarBay.END_WALL, "%s: seat %d is past the outer door" % [tag, i + 1])
	check(al.inner_k < 0.001 and al.outer_k < 0.001 and al.inner_lamp == "sealed" and al.outer_lamp == "sealed",
		"%s: both doors end shut and green" % tag)
	var rate := clampf(natural / HangarBay.EGRESS_TARGET, HangarBay.EGRESS_RATE, HangarBay.EGRESS_MAX_RATE)
	check(natural / rate <= HangarBay.EGRESS_TARGET + 2.0 or rate >= HangarBay.EGRESS_MAX_RATE,
		"%s: played at %.1fx it lasts %.1f s" % [tag, rate, natural / rate])
	print("hangar egress %s: %.1f s natural, %d cycle(s), plays %.1f s at %.2fx" % [tag, t, eg.groups.size(), natural / rate, rate])
	bay.set_alert(false)
	for i in bay.models.size():
		check(bay.models[i].visible and bay.models[i].position.distance_to(Vector3(float(HangarBay.ALCOVE_X[i]), HangarBay.PLATFORM_H, HangarBay.MECH_Z)) < 0.001,
			"%s: set_alert(false) puts seat %d back in its cradle" % [tag, i + 1])
