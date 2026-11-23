extends TestCase
## The Bulwark's hardpoints physically connect and clear (docs/design/chassis-rules.md 4.2-4.7, 5.5, 9.2;
## test_hardpoint_contact does the Strider and owns the triangle-soup helpers). Pure geometry, in body space (the
## "Chassis" node's frame: model units before BODY_SCALE), meshes built from source:
##  - each side mount touches the hull (barrel + side pad) and its disc's back face sits on the pad (SEAT_TOL);
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


## The side mount's disc back face (radius 0.3 at x -0.06): its centre and eight points at r 0.27.
static func side_seats() -> PackedVector3Array:
	var out := PackedVector3Array([Vector3(-0.06, 0, 0)])
	for i in 8:
		var a := TAU * float(i) / 8.0
		out.append(Vector3(-0.06, cos(a) * 0.27, sin(a) * 0.27))
	return out


func setup() -> void:
	timeout_sec = 300.0
	var hull := HC.tris(BulwarkMeshes.build("bulwark_torso"), Transform3D.IDENTITY)
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
	for h: String in MechCatalog.HEAD_ORDER:
		m.configure(h, "bulwark", {})
		await frames(1)
		var ch := m.find_child("Chassis", true, false) as Node3D
		var t := _node_tris(m.find_child("Head_" + h, true, false), ch.global_transform.affine_inverse())
		head_list[h] = t
		heads.append_array(t)
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
	finish()


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
