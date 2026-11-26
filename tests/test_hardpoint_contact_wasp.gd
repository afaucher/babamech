extends TestCase
## The Wasp's hardpoints physically connect and clear (docs/design/chassis-rules.md 4.2-4.7, 5.5, 5.6, 9.2). Pure geometry
## in body space (the "Chassis" node's frame: model units before BODY_SCALE), meshes built from source:
##  - each stub mount touches its flank pad and its flange's back face sits on it (SEAT_TOL); the chin turret's base plate
##    sits on the chin pad's flat face;
##  - every item the catalog allows on each hardpoint (MechCatalog.items_for with max_item_weight: no item over 7 on the
##    Wasp, 6 on the chin) touches its mount (GAP_TOL);
##  - every gun across its aim range (yaw every 10 deg and at the ends, pitch at both ends and level; the hardpoint's
##    cuts applied) keeps PIVOT_CLEAR off the hull and pads, both main fans across their whole tilt ellipse (the stub guns
##    under the rings are the known risk), the legs in every pose from dangle to stand, the other guns at rest, and every
##    pilot head; the line ahead of each muzzle (rest pose) is clear of the hull;
##  - landed (legs standing): every gun at every aim keeps GROUND_CLEAR over the ground.
## Prints the table (the audit).

const GAP_TOL := 0.01
const SEAT_TOL := 0.02
const PIVOT_CLEAR := 0.005
const GROUND_CLEAR := 0.04   ## body units (about 10 cm at mech scale 2)

const HC := preload("res://tests/test_hardpoint_contact.gd")
const HCB := preload("res://tests/test_hardpoint_contact_bulwark.gd")
const TCW := preload("res://tests/test_clearance_wasp.gd")


func setup() -> void:
	timeout_sec = 400.0
	var hull := HC.tris(WaspMeshes.build("wasp_hull"), Transform3D.IDENTITY)
	var pads := HC.tris(WaspMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	var m := MechModel.new()
	m.show_drafts = true
	m.configure("chicken", "wasp", {})
	add_child(m)
	await frames(1)
	var ch := m.find_child("Chassis", true, false) as Node3D
	var inv := ch.global_transform.affine_inverse()
	# The fans across their tilt ellipse, both sides (one soup).
	var fans := PackedVector3Array()
	var tm: Vector2 = WaspMeshes.FAN_TILT_MAX
	var tilts: Array = [Vector2.ZERO]
	for i in 12:
		var a := TAU * float(i) / 12.0
		tilts.append(Vector2(cos(a) * tm.x, sin(a) * tm.y))
	for t: Vector2 in tilts:
		m.set_fan_tilt(t)
		for tag: String in ["l", "r"]:
			fans.append_array(HCB._node_tris(m.find_child("fan_" + tag, true, false), inv))
	m.set_fan_tilt(Vector2.ZERO)
	# The legs from dangle to stand (one soup).
	var legs := PackedVector3Array()
	for i in 6:
		m.set_legs_pose(float(i) / 5.0)
		for tag: String in ["l", "r"]:
			legs.append_array(HCB._node_tris(m.find_child("hip_" + tag, true, false), inv))
	m.set_legs_pose(0.0)
	# Every pilot head.
	var heads := PackedVector3Array()
	for h: String in MechCatalog.HEAD_ORDER:
		m.configure(h, "wasp", {})
		await frames(1)
		ch = m.find_child("Chassis", true, false) as Node3D
		heads.append_array(HCB._node_tris(m.find_child("Head_" + h, true, false), ch.global_transform.affine_inverse()))
	m.queue_free()
	var items := {}
	var hps: Array = MechCatalog.entry("wasp")["hardpoints"]
	check(MechCatalog.max_item_weight("wasp") == 7.0, "the Wasp takes no item over weight 7")
	# Every gun at rest (the other guns' obstacles).
	var rest := {}
	for hp: Dictionary in hps:
		var u := PackedVector3Array()
		for w: String in MechCatalog.items_for(hp):
			u.append_array(HC.tris(HCB._item(items, w), Transform3D(Basis(), WaspMeshes.MOUNTS[hp["id"]])))
		rest[hp["id"]] = u
	var ground := -WaspMeshes.BODY_Y / WaspMeshes.BODY_SCALE
	print("  %-7s %-11s %8s %8s %8s %9s %9s %8s   %s" % ["hp", "item", "mnt-hull", "mnt-seat", "item-con", "pivot", "muzzle", "ground", "worst"])
	for hp: Dictionary in hps:
		var id := str(hp["id"])
		var at: Vector3 = WaspMeshes.MOUNTS[id]
		var side := -1.0 if id.ends_with("_l") else (1.0 if id.ends_with("_r") else 0.0)
		var sm := Vector3(-1.0 if side < 0.0 else 1.0, 1, 1)
		var hw: Array = ChassisParts.of("wasp")["mount_hw"][str(hp["mount"])]
		var mxf := Transform3D(Basis.from_scale(sm), at - (hw[1] as Vector3) * sm)
		var mount_t := HC.tris(WaspMeshes.build(str(hw[0])), mxf)
		var seats := PackedVector3Array()
		if str(hp["mount"]) == "stub":
			for sy: float in [-0.9, 0.0, 0.9]:
				for sz: float in [-0.9, 0.0, 0.9]:
					seats.append(mxf * Vector3(-0.01, sy * 0.12, sz * 0.15))
		else:
			for i in 8:
				var a := TAU * float(i) / 8.0
				seats.append(mxf * Vector3(sin(a) * 0.1, 0.0, cos(a) * 0.1))
			seats.append(mxf * Vector3.ZERO)
		var mgap := HC.contact(mount_t, pads)
		var mseat := HC.seat_gap(seats, pads)
		check(mgap <= GAP_TOL, "%s: the mount touches its pad (gap %.3f)" % [id, mgap])
		check(mseat <= SEAT_TOL, "%s: the mount's base sits on the pad's face (worst seat point %.3f off)" % [id, mseat])
		var obstacles := hull.duplicate()
		obstacles.append_array(pads)
		obstacles.append_array(fans)
		obstacles.append_array(legs)
		obstacles.append_array(heads)
		for o: String in rest:
			if o != id:
				obstacles.append_array(rest[o])
		check(MechCatalog.items_for(hp).size() > 0, "%s takes weapons" % id)
		for w: String in MechCatalog.items_for(hp):
			check(float(MechCatalog.weapon(w)["weight"]) <= float(hp.get("max_item_weight", INF)), "%s/%s: within the hardpoint's weight limit" % [id, w])
			var wt := HC.tris(HCB._item(items, w), Transform3D(Basis(), at))
			var gap := HC.contact(wt, mount_t)
			check(gap <= GAP_TOL, "%s/%s: touches its mount (gap %.3f)" % [id, w, gap])
			var r := aim_range(hp, w, side)
			var yaws: Array = [r.x]
			var yy := ceilf(r.x / 10.0) * 10.0
			while yy < r.y:
				if yy > r.x:
					yaws.append(yy)
				yy += 10.0
			yaws.append(r.y)
			var pivot := INF
			var worst := ""
			var low := INF
			for yaw: float in yaws:
				for pitch: float in [-r.z, 0.0, r.w]:
					var pt := HC.tris(HCB._item(items, w), Transform3D(WeaponPose.rotation(yaw, pitch), at))
					var g := HC.surface_gap(pt, obstacles, 0.3)
					if g < pivot:
						pivot = g
						worst = "yaw %+.0f pitch %+.0f" % [yaw, pitch]
					for v in pt:
						low = minf(low, v.y - ground)
			if not check(pivot >= PIVOT_CLEAR, "%s/%s: clears the hull, pads, fans, legs, other guns and heads across its aim range (closest %.3f at %s)" % [id, w, pivot, worst]):
				var wp := worst.split(" ")
				var pw := HC.tris(HCB._item(items, w), Transform3D(WeaponPose.rotation(float(wp[1]), float(wp[3])), at))
				var groups := {"hull": hull, "pads": pads, "fans": fans, "legs": legs, "heads": heads}
				for gname: String in groups:
					print("    %s/%s at %s: %s gap %.3f" % [id, w, worst, gname, HC.surface_gap(pw, groups[gname], 0.3)])
			check(low >= GROUND_CLEAR, "%s/%s: landed, above the ground at every aim (lowest %.3f over it)" % [id, w, low])
			var mz := at + Vector3(0, 0, -float(MechCatalog.weapon(w).get("muzzle", 1.0)))
			var hit := false
			for i in range(0, hull.size(), 3):
				if Geometry3D.segment_intersects_triangle(mz, mz + Vector3(0, 0, -6.0), hull[i], hull[i + 1], hull[i + 2]) != null:
					hit = true
					break
			check(not hit, "%s/%s: nothing of the hull ahead of the muzzle" % [id, w])
			print("  %-7s %-11s %8.3f %8.3f %8.3f %9.3f %9s %8.3f   %s" % [id, w, mgap, mseat, gap, pivot, "clear" if not hit else "HIT", low, worst])
	finish()


## A weapon's aim range on a hardpoint: Vector4(yaw min, yaw max, pitch down, pitch up) in degrees: the weapon's own arc
## (Combat.pivot_limits) cut by the hardpoint's yaw_in_max / yaw_out_max / pitch_down_max / pitch_up_max (inward = toward
## the centre line: + yaw on a left gun, - on a right one).
static func aim_range(hp: Dictionary, w: String, side: float) -> Vector4:
	var lim := Combat.pivot_limits(MechCatalog.weapon(w))
	var y_in := minf(lim.x, float(hp.get("yaw_in_max", lim.x)))
	var y_out := minf(lim.x, float(hp.get("yaw_out_max", lim.x)))
	var r := Vector4(-y_out, y_in, minf(lim.y, float(hp.get("pitch_down_max", lim.y))), minf(lim.z, float(hp.get("pitch_up_max", lim.z))))
	if side > 0.0:
		r = Vector4(-y_in, y_out, r.z, r.w)
	elif side == 0.0:
		r = Vector4(-y_in, y_in, r.z, r.w)
	return r
