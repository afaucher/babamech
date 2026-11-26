extends TestCase
## The Bulwark's hardpoints physically connect and clear (docs/design/chassis-rules.md 4.2-4.7, 5.5, 9.2;
## test_hardpoint_contact does the Strider and owns the triangle-soup helpers). Pure geometry, in body space (the
## "Chassis" node's frame: model units before BODY_SCALE), meshes built from source:
##  - each side mount touches the hull (the slung hull, its hip pods and the side pad on the pod's front) and its
##    flange's back face sits on the pad (SEAT_TOL);
##  - every pilot head clears the coaming round the pilot's well, with both eyes (the pupils) above its top;
##  - every item the catalog allows on each hardpoint (MechCatalog.items_for: side guns take side and shoulder weapons,
##    the back saddles every back item) touches its mount (side) or the hull (back), a back item's base footprint on its
##    plinth within SEAT_TOL;
##  - side guns across their aim range (yaw every 10 deg and at the ends, pitch at both ends and level; inward yaw capped
##    by the hardpoint's yaw_in_max) keep PIVOT_CLEAR off the hull and pads, the legs standing and in the
##    shutdown slump, every back item on that side, and every pilot head; and the line ahead of each muzzle is clear of
##    the hull;
##  - every pair of back items (left, right) is apart, and no back item touches any pilot head.
## Prints the table (the audit).

const GAP_TOL := 0.01
const SEAT_TOL := 0.02
const PIVOT_CLEAR := 0.005

const HC := preload("res://tests/test_hardpoint_contact.gd")
const TCB := preload("res://tests/test_torso_clearance_bulwark.gd")


## The side mount's flange back face (SIDE_FLANGE half size, 1 cm behind the mount origin on the pad's face): its centre,
## corners and edge middles at 0.9 of the half size.
static func side_seats() -> PackedVector3Array:
	var out := PackedVector3Array()
	var f := BulwarkMeshes.SIDE_FLANGE * 0.9
	for sx: float in [-1.0, 0.0, 1.0]:
		for sy: float in [-1.0, 0.0, 1.0]:
			out.append(Vector3(sx * f.x, sy * f.y, 0.01))
	return out


func setup() -> void:
	timeout_sec = 300.0
	var hull := HC.tris(BulwarkMeshes.build("bulwark_torso"), Transform3D.IDENTITY)
	for side: float in [-1.0, 1.0]:   # the hip pods (their own mirrored part) are hull too
		hull.append_array(HC.tris(BulwarkMeshes.build("bulwark_pod"), Transform3D(Basis.from_scale(Vector3(side, 1, 1)), Vector3.ZERO)))
	var mount_mesh := BulwarkMeshes.build("bulwark_side_mount")
	var m := MechModel.new()
	m.configure("chicken", "bulwark", {})
	add_child(m)
	await frames(1)
	var chassis := m.find_child("Chassis", true, false) as Node3D
	var inv := chassis.global_transform.affine_inverse()
	# The legs in body space, standing and slumped.
	var legs := _leg_tris(m, inv)
	var off := Vector3(0, -float(TCB.SAG["depth"]) * MechRig.SAG_PEAK, 0)
	var rot := Vector3(-float(TCB.SAG["pitch"]) * MechRig.SAG_PEAK, 0, float(TCB.SAG["roll"]) * MechRig.SAG_PEAK)
	m.set_external_pose(TCB._planted(m, off, rot), off, rot, 0.0)
	var slump := _leg_tris(m, chassis.global_transform.affine_inverse())
	m.clear_external_pose()
	# Every pilot head (the live PilotHead meshes) in body space.
	var heads := PackedVector3Array()
	var head_list := {}
	var coaming := HC.tris(BulwarkMeshes.coaming(), Transform3D.IDENTITY)
	for h: String in MechCatalog.HEAD_ORDER:
		m.configure(h, "bulwark", {})
		await frames(1)
		var ch := m.find_child("Chassis", true, false) as Node3D
		var hn := m.find_child("Head_" + h, true, false)
		var t := _node_tris(hn, ch.global_transform.affine_inverse())
		head_list[h] = t
		heads.append_array(t)
		var cg := HC.contact(t, coaming)
		check(cg > 0.0, "%s: clear of the coaming (gap %.3f)" % [h, cg])
		var eye := INF
		for pn in hn.find_children("Pupil*", "MeshInstance3D", true, false):
			var pm := pn as MeshInstance3D
			if pm.mesh != null:
				eye = minf(eye, (ch.global_transform.affine_inverse() * (pm.global_transform * pm.mesh.get_aabb().get_center())).y)
		check(eye < INF and eye > BulwarkMeshes.COAMING_TOP + 0.05, "%s: eyes above the coaming (pupils at %.3f, coaming top %.3f)" % [h, eye, BulwarkMeshes.COAMING_TOP])
		print("  head %-8s coaming gap %.3f, pupils %.3f over the coaming top" % [h, cg, eye - BulwarkMeshes.COAMING_TOP])
	m.queue_free()
	check(heads.size() > 0, "the pilot heads have triangles (%d)" % (heads.size() / 3))
	var items := {}
	var back_items := {}   # side (-1 / +1) -> every back item's triangles on that saddle
	var back_each := {}    # [hardpoint, item] -> triangles
	print("  %-7s %-12s %8s %8s %8s %9s %9s %9s" % ["hp", "item", "mnt-hull", "mnt-seat", "item-con", "item-seat", "pivot", "muzzle"])
	var hps: Array = MechCatalog.chassis("bulwark")["hardpoints"]
	# The back saddles first: their items are obstacles for the side guns.
	for hp: Dictionary in hps:
		if str(hp["mount"]) != "back":
			continue
		var id := str(hp["id"])
		var at: Vector3 = BulwarkMeshes.MOUNTS[id]
		var side := -1.0 if id.ends_with("_l") else 1.0
		var union := PackedVector3Array()
		for w: String in MechCatalog.items_for(hp):
			var wt := HC.tris(_item(items, w), Transform3D(Basis(), at))
			back_each[[id, w]] = wt
			union.append_array(wt)
			var gap := HC.contact(wt, hull)
			var bs := PackedVector3Array()
			for s in HC.back_seats():
				bs.append(at + s)
			var seat := HC.seat_gap(bs, hull)
			check(gap <= GAP_TOL, "%s/%s: touches the hull (gap %.3f)" % [id, w, gap])
			check(seat <= SEAT_TOL, "%s/%s: its base sits on the plinth (worst footprint point %.3f off)" % [id, w, seat])
			var hgap := HC.contact(wt, heads)
			check(hgap > 0.0, "%s/%s: clear of every pilot head (gap %.3f)" % [id, w, hgap])
			print("  %-7s %-12s %8s %8s %8.3f %9.3f %9s %9s   head %.3f" % [id, w, "-", "-", gap, seat, "-", "-", hgap])
		back_items[side] = union
	# Every pair of back items, left and right.
	var worst_pair := INF
	var worst_name := ""
	for wl: String in MechCatalog.items_for(hps[2]):
		for wr: String in MechCatalog.items_for(hps[3]):
			var g := HC.contact(back_each[["back_l", wl]], back_each[["back_r", wr]])
			if g < worst_pair:
				worst_pair = g
				worst_name = "%s + %s" % [wl, wr]
			check(g > 0.0, "back pair %s + %s: apart (gap %.3f)" % [wl, wr, g])
	print("  back pairs: closest %.3f (%s)" % [worst_pair, worst_name])
	# The side guns.
	var pads := HC.tris(BulwarkMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	for hp: Dictionary in hps:
		if str(hp["mount"]) != "side":
			continue
		var id := str(hp["id"])
		var at: Vector3 = BulwarkMeshes.MOUNTS[id]
		var side := -1.0 if id.ends_with("_l") else 1.0
		var mirror := Basis.from_scale(Vector3(side, 1, 1))
		var mxf := Transform3D(mirror, at - BulwarkMeshes.SIDE_REACH * Vector3(side, 1, 1))
		var mount_t := HC.tris(mount_mesh, mxf)
		var seats := PackedVector3Array()
		for s in side_seats():
			seats.append(mxf * s)
		var mgap := HC.contact(mount_t, hull)
		var mseat := HC.seat_gap(seats, hull)
		check(mgap <= GAP_TOL, "%s: the side mount touches the hull (gap %.3f)" % [id, mgap])
		check(mseat <= SEAT_TOL, "%s: the side mount's disc sits on the pad (worst seat point %.3f off)" % [id, mseat])
		var obstacles := hull.duplicate()
		obstacles.append_array(pads)
		obstacles.append_array(legs)
		obstacles.append_array(slump)
		obstacles.append_array(back_items[side])
		obstacles.append_array(heads)
		for w: String in MechCatalog.items_for(hp):
			var wt := HC.tris(_item(items, w), Transform3D(Basis(), at))
			var gap := HC.contact(wt, mount_t)
			check(gap <= GAP_TOL, "%s/%s: touches its side mount (gap %.3f)" % [id, w, gap])
			var st := MechCatalog.weapon(w)
			var lim := Combat.pivot_limits(st)
			# Inward yaw (+ on the left gun, - on the right) is capped per hardpoint (MechCatalog "yaw_in_max").
			var y_in := minf(lim.x, float(hp.get("yaw_in_max", lim.x)))
			var y0 := -lim.x if side < 0.0 else -y_in
			var y1 := y_in if side < 0.0 else lim.x
			var yaws: Array = [y0]
			var yy := ceilf(y0 / 10.0) * 10.0
			while yy < y1:
				if yy > y0:
					yaws.append(yy)
				yy += 10.0
			yaws.append(y1)
			var pivot := INF
			var worst_pose := ""
			for yaw: float in yaws:
				for pitch: float in [-lim.y, 0.0, lim.z]:
					var pt := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(yaw, pitch), at))
					var g := HC.surface_gap(pt, obstacles, 0.3)
					if g < pivot:
						pivot = g
						worst_pose = "yaw %+.0f pitch %+.0f" % [yaw, pitch]
			if not check(pivot >= PIVOT_CLEAR, "%s/%s: clears the hull, pads, legs, back items and heads across its aim range (closest %.3f at %s)"
					% [id, w, pivot, worst_pose]):
				# Which obstacle it meets at the worst pose.
				var wp := worst_pose.split(" ")
				var pw := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(float(wp[1]), float(wp[3])), at))
				var groups := {"hull": hull, "pads": pads, "legs": legs, "slump": slump, "back": back_items[side], "heads": heads}
				for gname: String in groups:
					print("    %s/%s at %s: %s gap %.3f" % [id, w, worst_pose, gname, HC.surface_gap(pw, groups[gname], 0.3)])
				# Report the widest inward yaw that would clear, to cut the range in data.
				var a := y_in
				while a > 0.0:
					a -= 5.0
					var ok := true
					for pitch: float in [-lim.y, 0.0, lim.z]:
						var pt := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(-side * a, pitch), at))
						if HC.surface_gap(pt, obstacles, 0.3) < PIVOT_CLEAR:
							ok = false
							break
					if ok:
						break
				print("    %s/%s: inward yaw clears up to %.0f deg" % [id, w, a])
			# The line ahead of the muzzle (rest pose) is clear of the hull.
			var mz := at + Vector3(0, 0, -float(st.get("muzzle", 1.0)))
			var hit := false
			for i in range(0, hull.size(), 3):
				if Geometry3D.segment_intersects_triangle(mz, mz + Vector3(0, 0, -6.0), hull[i], hull[i + 1], hull[i + 2]) != null:
					hit = true
					break
			check(not hit, "%s/%s: nothing of the hull ahead of the muzzle" % [id, w])
			print("  %-7s %-12s %8.3f %8.3f %8.3f %9s %9.3f %9s   %s" % [id, w, mgap, mseat, gap, "-", pivot, "clear" if not hit else "HIT", worst_pose])
	await _belly(hull, pads, heads, items)
	finish()


## PROTOTYPE belly turret (MechCatalog hardpoint "belly", mount kind "belly"; docs/design/bulwark-effectiveness.md): its
## pintle mount's base plate sits on the keel's flat underside; every item it takes touches the mount; across the
## hardpoint's arc (catalog yaw_in_max / yaw_out_max / pitch_down_max / pitch_up_max, every 5 deg of yaw, pitch at both
## ends and level) each gun keeps PIVOT_CLEAR off the hull, the pads, every pilot head and the whole legs (boots too)
## standing, across a forward and a sideways walk cycle, on the landing dip and in the shutdown slump; and stays above
## the ground in the slump. Skipped when the catalog has no belly hardpoint (the prototype dropped).
func _belly(hull: PackedVector3Array, pads: PackedVector3Array, heads: PackedVector3Array, items: Dictionary) -> void:
	var hp := {}
	for h: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		if str(h["id"]) == "belly":
			hp = h
	if hp.is_empty():
		print("  no belly hardpoint in the catalog: skipped")
		return
	var at: Vector3 = BulwarkMeshes.MOUNTS["belly"]
	near((at - Vector3(0, BulwarkMeshes.BELLY_Y, BulwarkMeshes.BELLY_Z)).length(), 0.0, 1e-5, "MOUNTS.belly = (0, BELLY_Y, BELLY_Z)")
	var mxf := Transform3D(Basis(), at - BulwarkMeshes.BELLY_REACH)
	var mount_t := HC.tris(BulwarkMeshes.build("bulwark_belly_mount"), mxf)
	var mgap := HC.contact(mount_t, hull)
	var seats := PackedVector3Array()
	var r := BulwarkMeshes.BELLY_BASE * 0.85
	for i in 8:
		var a := TAU * float(i) / 8.0
		seats.append(mxf * Vector3(sin(a) * r, 0.0, cos(a) * r))
	seats.append(mxf * Vector3.ZERO)
	var mseat := HC.seat_gap(seats, hull)
	check(mgap <= GAP_TOL, "belly: the turret mount touches the keel (gap %.3f)" % mgap)
	check(mseat <= SEAT_TOL, "belly: its base plate sits on the keel's underside (worst seat point %.3f off)" % mseat)
	# The legs (boots included) in body space across the poses that move them.
	var m := MechModel.new()
	m.configure("chicken", "bulwark", {})
	add_child(m)
	await frames(1)
	var chassis := m.find_child("Chassis", true, false) as Node3D
	var poses := {"standing": _all_leg_tris(m, chassis.global_transform.affine_inverse())}
	for dir: Vector3 in [Vector3.BACK, Vector3.RIGHT, Vector3.LEFT]:
		for i in 12:
			var ph := float(i) / 12.0
			m.set_external_pose(TCB._walk(m, ph, 0.0, dir), Vector3(0, -0.03 * absf(sin(ph * TAU)), 0), Vector3(-0.05, 0, 0.03 * sin(ph * TAU)), 0.0)
			poses["walk %s %.2f" % [str(dir), ph]] = _all_leg_tris(m, chassis.global_transform.affine_inverse())
	var dip := Vector3(0, -TCB.LAND_DIP, 0)
	m.set_external_pose(TCB._planted(m, dip, Vector3.ZERO), dip, Vector3.ZERO, 0.0)
	var dip_inv := chassis.global_transform.affine_inverse()
	poses["landing dip"] = _all_leg_tris(m, dip_inv)
	var d0 := dip_inv * m.global_transform * Vector3.ZERO
	var dn := (dip_inv.basis * (m.global_transform.basis * Vector3.UP)).normalized()
	var off := Vector3(0, -float(TCB.SAG["depth"]) * MechRig.SAG_PEAK, 0)
	var rot := Vector3(-float(TCB.SAG["pitch"]) * MechRig.SAG_PEAK, 0, float(TCB.SAG["roll"]) * MechRig.SAG_PEAK)
	m.set_external_pose(TCB._planted(m, off, rot), off, rot, 0.0)
	var slump_inv := chassis.global_transform.affine_inverse()
	poses["slump"] = _all_leg_tris(m, slump_inv)
	# The ground plane (the model's y = 0) in the slumped body frame: a point and its normal.
	var g0 := slump_inv * m.global_transform * Vector3.ZERO
	var gn := (slump_inv.basis * (m.global_transform.basis * Vector3.UP)).normalized()
	m.clear_external_pose()
	m.queue_free()
	var legs_all := PackedVector3Array()
	for k: String in poses:
		legs_all.append_array(poses[k])
	var obstacles := hull.duplicate()
	obstacles.append_array(pads)
	obstacles.append_array(heads)
	obstacles.append_array(legs_all)
	var rng := WeaponMount.hardpoint_range("bulwark", "belly")
	for w: String in MechCatalog.items_for(hp):
		var wt := HC.tris(_item(items, w), Transform3D(Basis(), at))
		var gap := HC.contact(wt, mount_t)
		check(gap <= GAP_TOL, "belly/%s: touches its pintle mount (gap %.3f)" % [w, gap])
		var lim := Combat.pivot_limits(MechCatalog.weapon(w))
		var y0 := maxf(-lim.x, rng.x)
		var y1 := minf(lim.x, rng.y)
		var pd := minf(lim.y, rng.z)
		var pu := minf(lim.z, rng.w)
		var yaws: Array = []
		var yy := y0
		while yy < y1 - 0.01:
			yaws.append(yy)
			yy += 5.0
		yaws.append(y1)
		var pivot := INF
		var worst := ""
		var ground := INF
		for yaw: float in yaws:
			for pitch: float in [-pd, 0.0, pu]:
				var pt := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(yaw, pitch), at))
				var g := HC.surface_gap(pt, obstacles, 0.3)
				if g < pivot:
					pivot = g
					worst = "yaw %+.0f pitch %+.0f" % [yaw, pitch]
				for v in pt:   # live aims: the deepest live pose is the landing dip
					ground = minf(ground, (v - d0).dot(dn))
		# Shut down (the slump) the barrel parks at WeaponMount.PARK_YAW / PARK_PITCH clamped to its range.
		var park := Vector2(clampf(WeaponMount.PARK_YAW, y0, y1), maxf(WeaponMount.PARK_PITCH, -pd))
		var parked := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(park.x, park.y), at))
		var ground_park := INF
		for v in parked:
			ground_park = minf(ground_park, (v - g0).dot(gn))
		if not check(pivot >= PIVOT_CLEAR, "belly/%s: clears the hull, pads, heads and legs (all poses) across its arc (closest %.3f at %s)" % [w, pivot, worst]):
			var wp := worst.split(" ")
			var pw := HC.tris(_item(items, w), Transform3D(WeaponPose.rotation(float(wp[1]), float(wp[3])), at))
			for k: String in poses:
				var lg := HC.surface_gap(pw, poses[k], 0.3)
				if lg < PIVOT_CLEAR:
					print("    belly/%s at %s: legs (%s) gap %.3f" % [w, worst, k, lg])
			print("    belly/%s at %s: hull gap %.3f, pads %.3f" % [w, worst, HC.surface_gap(pw, hull, 0.3), HC.surface_gap(pw, pads, 0.3)])
		check(ground > 0.02, "belly/%s: above the ground at every aim on the landing dip (lowest %.3f over it)" % [w, ground])
		check(ground_park > 0.02, "belly/%s: parked, above the ground in the shutdown slump (lowest %.3f over it)" % [w, ground_park])
		var mz := at + Vector3(0, 0, -float(MechCatalog.weapon(w).get("muzzle", 1.0)))
		var hit := false
		for i in range(0, hull.size(), 3):
			if Geometry3D.segment_intersects_triangle(mz, mz + Vector3(0, 0, -6.0), hull[i], hull[i + 1], hull[i + 2]) != null:
				hit = true
				break
		check(not hit, "belly/%s: nothing of the hull ahead of the muzzle" % w)
		print("  %-7s %-12s %8.3f %8.3f %8.3f %9s %9.3f %9s   %s  ground: dip %.3f, slump parked %.3f" % ["belly", w, mgap, mseat, gap,
			"-", pivot, "clear" if not hit else "HIT", worst, ground, ground_park])


## Every leg part of a posed model (thighs, knee drums, shins, ankle blocks and drums, hip balls, boots with toes and
## spur), in body space.
static func _all_leg_tris(m: MechModel, inv: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n: String in ["thigh_l", "thigh_r", "knee_l", "knee_r", "shin_l", "shin_r", "hip_l", "hip_r", "tarsus_l", "tarsus_r",
			"ankle_l", "ankle_r", "foot_l", "foot_r"]:
		var nd := m.find_child(n, true, false)
		if nd != null:
			out.append_array(_node_tris(nd, inv))
	return out


static func _item(cache: Dictionary, w: String) -> ArrayMesh:
	if not cache.has(w):
		cache[w] = MechMeshes.build("weapon_" + w)
	return cache[w]


## The thighs, knee drums, shins (with the knee pads) and hip balls of a posed model, in body space.
static func _leg_tris(m: MechModel, inv: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n: String in ["thigh_l", "thigh_r", "knee_l", "knee_r", "shin_l", "shin_r", "hip_l", "hip_r"]:
		out.append_array(_node_tris(m.find_child(n, true, false), inv))
	return out


## Every visible mesh under (and including) `root`, in the frame `inv` maps world space into.
static func _node_tris(root: Node, inv: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var xf := inv * mi.global_transform
		var flip := xf.basis.determinant() < 0.0
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
				var ii: PackedInt32Array = idx
				for i in range(0, ii.size() - 2, 3):
					out.append_array([xf * v[ii[i]], xf * v[ii[i + (2 if flip else 1)]], xf * v[ii[i + (1 if flip else 2)]]])
			else:
				for i in range(0, v.size() - 2, 3):
					out.append_array([xf * v[i], xf * v[i + (2 if flip else 1)], xf * v[i + (1 if flip else 2)]])
	return out
