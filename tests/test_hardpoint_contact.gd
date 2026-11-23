extends TestCase
## Every hardpoint physically connects (docs/design/hardpoints/hardpoints_before_after.png). Pure geometry, no clock, in body space (the
## MechModel "Chassis" node's frame: model units before MechMeshes.BODY_SCALE; x2.4 in the game at the default mech
## scale 2.0), with the meshes built from source (MechMeshes.build):
##  - the mount part (side_mount, shoulder_pylon) touches its hull (the torso; + the shoulder pod for the pylon) and its
##    attach face sits on it: every SEAT point inside the hull or within SEAT_TOL of its skin (a flat mount, not one
##    corner touching while the rest hangs in the air);
##  - every item the catalog allows on the hardpoint touches its mount part (side, shoulder) or, on the back, the hull
##    (torso + back plate), with its base's footprint (BACK_SEATS) on it within SEAT_TOL;
##  - pivoting weapons at the corners of their pivot range: the hardpoint pads (MechMeshes.hardpoint_pads) add no
##    clipping (every corner pose that clears the hull without the pads also clears the pads; "piv-pads" is the
##    closest such pose, "piv-hull" the closest any pose comes to the hull, 0 where a barrel turned down or in already
##    cut the body before the pads existed);
##  - MOUNTS / PYLON_TOP / SIDE_REACH are unchanged (combat, the weapon pivots and the hit spheres depend on them).
## Prints the gap table (the audit).

const GAP_TOL := 0.01    ## contact: surfaces at most this far apart (model units: 2.4 cm in the game)
const SEAT_TOL := 0.02   ## seat points at most this far off the hull (4.8 cm in the game)
const PIVOT_CLEAR := 0.005   ## a pivoting weapon keeps at least this far off the pads (1.2 cm in the game)

const EXPECT_MOUNTS := {
	"side_l": Vector3(-1.21, 0.52, -0.3), "side_r": Vector3(1.21, 0.52, -0.3),
	"shoulder_l": Vector3(-0.86, 2.16, 0.3), "shoulder_r": Vector3(0.86, 2.16, 0.3),
	"back": Vector3(0, 1.55, 0.72),
}
const EXPECT_PYLON_TOP := Vector3(0.1, 0.78, 0.0)
const EXPECT_SIDE_REACH := Vector3(0.32, 0.0, 0.0)

## Attach-face points of each mount part, in its own (right-side) frame: the side mount's disc back face (radius 0.22
## at x -0.06: eight points at r 0.2 and its centre), the pylon base's bottom face (0.3 x 0.34 at y -0.05).
static func side_seats() -> PackedVector3Array:
	var out := PackedVector3Array([Vector3(-0.06, 0, 0)])
	for i in 8:
		var a := TAU * float(i) / 8.0
		out.append(Vector3(-0.06, cos(a) * 0.2, sin(a) * 0.2))
	return out


static func pylon_seats() -> PackedVector3Array:
	var out := PackedVector3Array()
	for x: float in [-0.14, 0.0, 0.14]:
		for z: float in [-0.16, 0.0, 0.16]:
			out.append(Vector3(x, -0.05, z))
	return out


## The back items' base footprint (from the back mount): the base plate's underside, 0.5 x 0.44 round (0, -0.04, 0.04)
## (the equipment plate; the mortar's is 0.56 x 0.5 at y -0.06, these points sit inside it).
static func back_seats() -> PackedVector3Array:
	var out := PackedVector3Array()
	for x: float in [-0.24, 0.0, 0.24]:
		for z: float in [-0.17, 0.04, 0.25]:
			out.append(Vector3(x, -0.06, z))
	return out


var _rows: Array[String] = []


func setup() -> void:
	timeout_sec = 120.0
	for id: String in EXPECT_MOUNTS:
		check((MechMeshes.MOUNTS[id] as Vector3).is_equal_approx(EXPECT_MOUNTS[id]), "MOUNTS[%s] unchanged (%s)" % [id, MechMeshes.MOUNTS[id]])
	eq(MechMeshes.MOUNTS.size(), EXPECT_MOUNTS.size(), "no hardpoint added or removed")
	check(MechMeshes.PYLON_TOP.is_equal_approx(EXPECT_PYLON_TOP), "PYLON_TOP unchanged")
	check(MechMeshes.SIDE_REACH.is_equal_approx(EXPECT_SIDE_REACH), "SIDE_REACH unchanged")
	var torso := tris(MechMeshes.build("torso"), Transform3D.IDENTITY)
	var pod := MechMeshes.build("shoulder_pod")
	var parts := {}
	for p: String in ["side_mount", "shoulder_pylon", "back_plate"]:
		parts[p] = MechMeshes.build(p)
	var bp_l: Array = MechMeshes.LAYOUT["back_plate"]
	var back_hull := torso.duplicate()
	back_hull.append_array(tris(parts["back_plate"], MeshKit.xf(bp_l[0], bp_l[1])))
	var pads := tris(MechMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	var items := {}
	print("  %-10s %-12s %8s %8s %8s %9s %9s %9s" % ["hardpoint", "item", "mnt-hull", "mnt-seat", "item-con", "item-seat", "piv-pads", "piv-hull"])
	for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
		var id := str(hp["id"])
		var mount_kind := str(hp["mount"])
		var at: Vector3 = MechMeshes.MOUNTS[id]
		var side := -1.0 if id.ends_with("_l") else 1.0
		var mirror := Basis.from_scale(Vector3(side, 1, 1))
		var hull := torso
		var mount_t := PackedVector3Array()
		var seats := PackedVector3Array()
		var mount_gap := 0.0
		var mount_seat := 0.0
		if mount_kind == "side" or mount_kind == "shoulder":
			var hw := "side_mount" if mount_kind == "side" else "shoulder_pylon"
			var reach: Vector3 = MechMeshes.SIDE_REACH if mount_kind == "side" else MechMeshes.PYLON_TOP
			var mxf := Transform3D(mirror, at - reach * Vector3(side, 1, 1))
			mount_t = tris(parts[hw], mxf)
			if mount_kind == "shoulder":
				hull = torso.duplicate()
				hull.append_array(tris(pod, Transform3D(mirror, (MechMeshes.LAYOUT["shoulder_pod"][0] as Vector3) * Vector3(side, 1, 1))))
			for s in (side_seats() if mount_kind == "side" else pylon_seats()):
				seats.append(mxf * s)
			mount_gap = contact(mount_t, hull)
			mount_seat = seat_gap(seats, hull)
			check(mount_gap <= GAP_TOL, "%s: the %s touches the hull (gap %.3f)" % [id, hw, mount_gap])
			check(mount_seat <= SEAT_TOL, "%s: the %s's attach face sits on the hull (worst seat point %.3f off)" % [id, hw, mount_seat])
		else:
			hull = back_hull
		var allowed: Array[String] = MechCatalog.weapons_for(mount_kind)
		allowed.append_array(MechCatalog.equipment_for(mount_kind))
		allowed.append("")
		for w: String in allowed:
			var item_gap := 0.0
			var item_seat := 0.0
			var pivot := INF
			var pivot_hull := INF
			if w != "":
				if not items.has(w):
					items[w] = MechMeshes.build("weapon_" + w)
				var wt := tris(items[w], Transform3D(Basis(), at))
				if mount_kind == "back":
					item_gap = contact(wt, hull)
					var bs := PackedVector3Array()
					for s in back_seats():
						bs.append(at + s)
					item_seat = seat_gap(bs, hull)
					check(item_seat <= SEAT_TOL, "%s/%s: the base sits on the saddle (worst footprint point %.3f off)" % [id, w, item_seat])
				else:
					item_gap = contact(wt, mount_t)
				check(item_gap <= GAP_TOL, "%s/%s: touches its %s (gap %.3f)" % [id, w, "hull" if mount_kind == "back" else "mount", item_gap])
				var st := MechCatalog.weapon(w)
				if mount_kind != "back" and str(st.get("kind", "")) != "arc" and w != "swivel":
					var lim := Vector3(float(st.get("yaw_arc", Combat.PIVOT_YAW)), float(st.get("pitch_down", Combat.PIVOT_PITCH_DOWN)),
						float(st.get("pitch_up", Combat.PIVOT_PITCH_UP)))
					for yaw: float in [-lim.x, 0.0, lim.x]:
						for pitch: float in [-lim.y, 0.0, lim.z]:
							var pt := tris(items[w], Transform3D(WeaponPose.rotation(yaw, pitch), at))
							var gh := surface_gap(pt, hull, 0.3)
							pivot_hull = minf(pivot_hull, gh)
							if gh > 0.0:   # a pose that already cuts the old hull (a barrel turned down into the body) is not the pads' doing
								pivot = minf(pivot, surface_gap(pt, pads, 0.3))
					check(pivot >= PIVOT_CLEAR, "%s/%s: the hardpoint pads add no clipping across its pivot range (closest %.3f)" % [id, w, pivot])
			var row := "  %-10s %-12s %8.3f %8.3f %8.3f %9.3f %9s %9s" % [id, w if w != "" else "(bare)", mount_gap, mount_seat, item_gap, item_seat,
				"-" if pivot == INF else "%.3f" % pivot, "-" if pivot_hull == INF else "%.3f" % pivot_hull]
			print(row)
			_rows.append(row)
	finish()


# --- Geometry -------------------------------------------------------------------------------------------------

## A mesh's triangles under `xf`, flat (a, b, c, a, b, c, ...).
static func tris(mesh: ArrayMesh, xf: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var flip := xf.basis.determinant() < 0.0   # a mirrored part keeps its faces pointing out (for the winding test)
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			out.append(xf * v[i])
			out.append(xf * (v[i + 2] if flip else v[i + 1]))
			out.append(xf * (v[i + 1] if flip else v[i + 2]))
	return out


static func _box_of(t: PackedVector3Array, i: int) -> AABB:
	return AABB(t[i], Vector3.ZERO).expand(t[i + 1]).expand(t[i + 2])


static func _bounds(t: PackedVector3Array) -> AABB:
	var b := AABB(t[0], Vector3.ZERO)
	for p in t:
		b = b.expand(p)
	return b


## The triangles of `t` whose boxes reach into `box` grown by `m`: [flat triangles, their boxes].
static func _near(t: PackedVector3Array, box: AABB, m: float) -> Array:
	var g := box.grow(m)
	var out := PackedVector3Array()
	var boxes: Array[AABB] = []
	for i in range(0, t.size(), 3):
		var b := _box_of(t, i)
		if b.grow(0.0001).intersects(g):
			out.append_array([t[i], t[i + 1], t[i + 2]])
			boxes.append(b)
	return [out, boxes]


## Closest distance between two triangle soups' surfaces (0 when they cross), capped at `cap`.
static func surface_gap(a: PackedVector3Array, b: PackedVector3Array, cap: float) -> float:
	if a.is_empty() or b.is_empty():
		return cap
	var na := _near(a, _bounds(b), cap)
	var nb := _near(b, _bounds(a), cap)
	var ta: PackedVector3Array = na[0]
	var tb: PackedVector3Array = nb[0]
	var ba: Array[AABB] = na[1]
	var bb: Array[AABB] = nb[1]
	var best := cap
	for i in ba.size():
		var gi := ba[i].grow(best)
		for j in bb.size():
			if not gi.intersects(bb[j]):
				continue
			var d := tri_tri(ta[i * 3], ta[i * 3 + 1], ta[i * 3 + 2], tb[j * 3], tb[j * 3 + 1], tb[j * 3 + 2])
			if d < best:
				best = d
				if best <= 0.0:
					return 0.0
				gi = ba[i].grow(best)
	return best


## Contact gap between two closed soups: 0 when their surfaces cross or one holds the other, else the closest distance.
static func contact(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var g := surface_gap(a, b, 1.0)
	if g > 0.0 and (inside(a[0], b) or inside(b[0], a)):
		return 0.0
	return g


## Worst seat point: 0 inside the hull, else its distance to the hull's skin.
static func seat_gap(pts: PackedVector3Array, hull: PackedVector3Array) -> float:
	var worst := 0.0
	for p in pts:
		if inside(p, hull):
			continue
		var best := INF
		for i in range(0, hull.size(), 3):
			best = minf(best, p.distance_to(closest_on_tri(p, hull[i], hull[i + 1], hull[i + 2])))
		worst = maxf(worst, best)
	return worst


## Inside a union of closed outward-wound shells (generalised winding number > 0.5).
static func inside(p: Vector3, t: PackedVector3Array) -> bool:
	var w := 0.0
	for i in range(0, t.size(), 3):
		var a := t[i] - p
		var b := t[i + 1] - p
		var c := t[i + 2] - p
		var la := a.length()
		var lb := b.length()
		var lc := c.length()
		var num := a.dot(b.cross(c))
		var den := la * lb * lc + a.dot(b) * lc + b.dot(c) * la + c.dot(a) * lb
		w += 2.0 * atan2(num, den)
	# Godot's front faces are clockwise, so outward faces give a negative solid angle here.
	return -w / (4.0 * PI) > 0.5


static func tri_tri(a0: Vector3, a1: Vector3, a2: Vector3, b0: Vector3, b1: Vector3, b2: Vector3) -> float:
	var ea := [[a0, a1], [a1, a2], [a2, a0]]
	var eb := [[b0, b1], [b1, b2], [b2, b0]]
	for e: Array in ea:
		if _seg_hits_tri(e[0], e[1], b0, b1, b2):
			return 0.0
	for e: Array in eb:
		if _seg_hits_tri(e[0], e[1], a0, a1, a2):
			return 0.0
	var best := INF
	for p: Vector3 in [a0, a1, a2]:
		best = minf(best, p.distance_to(closest_on_tri(p, b0, b1, b2)))
	for p: Vector3 in [b0, b1, b2]:
		best = minf(best, p.distance_to(closest_on_tri(p, a0, a1, a2)))
	for e: Array in ea:
		for f: Array in eb:
			var cp := Geometry3D.get_closest_points_between_segments(e[0], e[1], f[0], f[1])
			best = minf(best, (cp[0] as Vector3).distance_to(cp[1]))
	return best


static func _seg_hits_tri(p: Vector3, q: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	return Geometry3D.segment_intersects_triangle(p, q, a, b, c) != null


static func closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var den := 1.0 / (va + vb + vc)
	return a + ab * (vb * den) + ac * (vc * den)
