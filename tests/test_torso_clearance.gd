extends TestCase
## The flipped legs against the body (docs/design/body-detail/belly_*.png, hip_back_swing.png). The torso's lower belly
## is tucked into a keel (MechMeshes.TORSO's tuck column, BELLY_KEEL) and the hip socket's cup leans away from the thigh
## (MechModel.SOCKET_TILT / SOCKET_FOLLOW). Pure geometry, no clock: in the standing pose and in the worst leg pose of
## each of the ring-walk bot's motion cases (walk, run, strafe with the hip twist, curbs, landing; recorded with the
## envelope probe), no thigh or knee-cap vertex gets inside the torso skin; across the thigh's whole fore-aft swing no
## thigh vertex outside the hip ball gets into the socket's cup. The hull grown for the hardpoints (arm pads, shoulder
## shelves, back plinth: MechMeshes.hardpoint_pads) is checked the same way, as triangles (the pads hang over the
## thighs' sideways swing). The heat-shutdown slump (MechRig.sag_*) is checked settled and at its deepest overshoot.

const SKIN_MARGIN := 0.02     ## torso units; the shape clears these poses by about 0.04
const CUP_MARGIN := 0.01      ## socket units
## The socket cup's lathe profile (MechMeshes._hip_socket): [radius, y], 8 sides.
const CUP := [Vector2(0.37, 0.1), Vector2(0.35, 0.19), Vector2(0.27, 0.31), Vector2(0.13, 0.39)]
## [case, legs (model space), body offset, body rotation, leg yaw]: per motion case, the frame where the thigh came
## closest to the torso (MechRig poses at ring_walk's defaults).
const POSES := [
	["walk", [{"hip": Vector3(-0.6705, 1.8853, 0.0091), "knee": Vector3(-0.6729, 0.9141, 0.5257), "ankle": Vector3(-0.6750, 0.1110, -0.2260), "foot": Vector3(-0.6750, -0.4117, -0.0549)}, {"hip": Vector3(0.6785, 1.9391, 0.0052), "knee": Vector3(0.6789, 2.0679, 1.0977), "ankle": Vector3(0.6750, 0.9717, 1.0067), "foot": Vector3(0.6750, 0.4490, 1.1777)}], Vector3(0.0000, -0.2934, 0.0000), Vector3(-0.0720, 0.0000, 0.0400), 0.0000],
	["run", [{"hip": Vector3(-0.6705, 2.1139, 0.0202), "knee": Vector3(-0.6754, 1.3798, 0.8395), "ankle": Vector3(-0.6818, 0.4358, 0.2748), "foot": Vector3(-0.6818, -0.0869, 0.4459)}, {"hip": Vector3(0.6785, 2.1672, 0.0116), "knee": Vector3(0.6771, 2.4578, 1.0725), "ankle": Vector3(0.6822, 1.3657, 0.9408), "foot": Vector3(0.6822, 0.8430, 1.1119)}], Vector3(0.0000, -0.0660, 0.0000), Vector3(-0.1600, -0.0000, 0.0400), -0.0000],
	["speed sweep", [{"hip": Vector3(-0.5878, 2.2023, 0.3320), "knee": Vector3(-0.0317, 2.0649, 1.2711), "ankle": Vector3(0.2314, 1.0118, 1.0932), "foot": Vector3(0.3130, 0.4891, 1.2435)}, {"hip": Vector3(0.5976, 2.2021, -0.3141), "knee": Vector3(0.5444, 1.1080, -0.4146), "ankle": Vector3(0.0898, 0.5620, -1.2543), "foot": Vector3(0.1713, 0.0392, -1.1040)}], Vector3(0.0000, -0.0035, 0.0000), Vector3(-0.0899, 0.0000, 0.0488), -0.4968],
	["strafe walk", [{"hip": Vector3(-0.0072, 2.2322, -0.6784), "knee": Vector3(-1.1022, 2.1275, -0.6781), "ankle": Vector3(-1.1387, 1.0281, -0.6750), "foot": Vector3(-1.3097, 0.5054, -0.6750)}, {"hip": Vector3(-0.0072, 2.1782, 0.6705), "knee": Vector3(-0.6842, 1.3112, 0.6729), "ankle": Vector3(0.1438, 0.5871, 0.6750), "foot": Vector3(-0.0272, 0.0644, 0.6750)}], Vector3(0.0000, -0.0003, 0.0000), Vector3(0.0400, 0.0000, -0.0720), 1.5708],
	["strafe run", [{"hip": Vector3(-0.0055, 2.2312, -0.6785), "knee": Vector3(-1.1050, 2.2001, -0.6784), "ankle": Vector3(-0.8629, 1.1271, -0.6750), "foot": Vector3(-1.0339, 0.6044, -0.6750)}, {"hip": Vector3(-0.0055, 2.1773, 0.6705), "knee": Vector3(-0.5676, 1.2317, 0.6733), "ankle": Vector3(0.3627, 0.6448, 0.6750), "foot": Vector3(0.1917, 0.1220, 0.6750)}], Vector3(0.0000, -0.0012, 0.0000), Vector3(0.0400, 0.0000, -0.0545), 1.5708],
	["diagonal", [{"hip": Vector3(-0.5485, 2.1994, -0.3920), "knee": Vector3(-0.7966, 1.1960, -0.0157), "ankle": Vector3(-0.2787, 0.5247, -0.7165), "foot": Vector3(-0.3785, 0.0020, -0.5776)}, {"hip": Vector3(0.5482, 2.2103, 0.3952), "knee": Vector3(-0.0917, 1.9028, 1.2354), "ankle": Vector3(0.0774, 0.8935, 0.8321), "foot": Vector3(-0.0224, 0.3708, 0.9710)}], Vector3(0.0000, -0.0003, 0.0000), Vector3(-0.0158, 0.0000, -0.0014), 0.6226],
	["backward", [{"hip": Vector3(-0.6785, 2.2187, -0.0052), "knee": Vector3(-0.6740, 1.9378, 1.0583), "ankle": Vector3(-0.6593, 0.9998, 0.4839), "foot": Vector3(-0.6593, 0.4770, 0.6550)}, {"hip": Vector3(0.6705, 2.1649, -0.0091), "knee": Vector3(0.7296, 1.0708, -0.1068), "ankle": Vector3(0.7592, 0.5218, -1.0596), "foot": Vector3(0.7592, -0.0009, -0.8885)}], Vector3(0.0000, -0.0137, 0.0000), Vector3(0.0720, 0.0000, -0.0400), 0.0000],
	["circle walk", [{"hip": Vector3(-0.6705, 1.9156, 0.0091), "knee": Vector3(-0.6827, 0.9963, 0.6129), "ankle": Vector3(-0.6940, 0.1544, -0.0950), "foot": Vector3(-0.6940, -0.3683, 0.0761)}, {"hip": Vector3(0.6785, 1.9695, 0.0052), "knee": Vector3(0.6438, 2.1996, 1.0803), "ankle": Vector3(0.8070, 1.1162, 0.9833), "foot": Vector3(0.8070, 0.5934, 1.1543)}], Vector3(0.0000, -0.2630, 0.0000), Vector3(-0.0720, -0.0000, 0.0400), -0.0000],
	["circle run", [{"hip": Vector3(-0.6694, 2.2198, 0.1107), "knee": Vector3(-0.4947, 2.0303, 1.1800), "ankle": Vector3(-0.4572, 0.9494, 0.9795), "foot": Vector3(-0.4315, 0.4266, 1.1486)}, {"hip": Vector3(0.6648, 2.1661, -0.0877), "knee": Vector3(0.8320, 1.5989, 0.8399), "ankle": Vector3(0.9239, 0.5405, 1.1254), "foot": Vector3(0.9496, 0.0178, 1.2945)}], Vector3(0.0000, -0.0130, 0.0000), Vector3(-0.1154, 0.0000, -0.0229), -0.1511],
	["turn in place", [{"hip": Vector3(-0.6750, 2.2052, 0.0000), "knee": Vector3(-0.6638, 1.2336, 0.5157), "ankle": Vector3(-0.6557, 0.5321, -0.3315), "foot": Vector3(-0.6557, 0.0093, -0.1604)}, {"hip": Vector3(0.6750, 2.2052, 0.0000), "knee": Vector3(0.5310, 1.5786, 0.8926), "ankle": Vector3(0.3164, 0.6443, 0.3531), "foot": Vector3(0.3164, 0.1216, 0.5242)}], Vector3(0.0000, 0.0000, 0.0000), Vector3(-0.0000, 0.0000, 0.0000), 0.0000],
	["curb up/down walk", [{"hip": Vector3(-0.6782, 1.9213, 0.0036), "knee": Vector3(-0.6784, 1.9918, 1.1014), "ankle": Vector3(-0.6750, 0.9174, 0.8653), "foot": Vector3(-0.6750, 0.3947, 1.0364)}, {"hip": Vector3(0.6710, 1.8728, 0.0060), "knee": Vector3(0.6731, 0.9257, 0.5654), "ankle": Vector3(0.6750, 0.0860, -0.1452), "foot": Vector3(0.6750, -0.4367, 0.0258)}], Vector3(0.0000, -0.3083, 0.0000), Vector3(-0.0480, 0.0000, -0.0360), 0.0000],
	["curb up/down run", [{"hip": Vector3(-0.6750, 1.9563, 0.0128), "knee": Vector3(-0.6750, 0.9476, -0.4260), "ankle": Vector3(-0.6750, 0.1778, -1.2117), "foot": Vector3(-0.6750, -0.3449, -1.0407)}, {"hip": Vector3(0.6750, 1.9563, 0.0128), "knee": Vector3(0.6750, 2.1709, 1.0916), "ankle": Vector3(0.6750, 1.0712, 1.1190), "foot": Vector3(0.6750, 0.5485, 1.2900)}], Vector3(0.0000, -0.2497, 0.0000), Vector3(-0.1280, 0.0000, -0.0000), 0.0000],
	["jump + landing dip", [{"hip": Vector3(-0.6750, 1.9167, 0.0000), "knee": Vector3(-0.6750, 1.2035, 0.8375), "ankle": Vector3(-0.6750, 0.8540, -0.2056), "foot": Vector3(-0.6750, 0.3313, -0.0345)}, {"hip": Vector3(0.6750, 1.9167, 0.0000), "knee": Vector3(0.6750, 1.2035, 0.8375), "ankle": Vector3(0.6750, 0.8540, -0.2056), "foot": Vector3(0.6750, 0.3313, -0.0345)}], Vector3(0.0000, -0.2885, 0.0000), Vector3(0.0000, 0.0000, -0.0000), 0.0000],
]

const HC := preload("res://tests/test_hardpoint_contact.gd")   ## its triangle-soup helpers (tris, inside, closest_on_tri)

var _skin: Array = []   ## per gap between torso sections: [z0, z1, [[a, b, c, outward normal], ...]]
var _pads := PackedVector3Array()   ## MechMeshes.hardpoint_pads, flat triangles (torso space)
var _pad_box := AABB()


func setup() -> void:
	_build_skin()
	_pads = HC.tris(MechMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	_pad_box = HC._bounds(_pads).grow(0.1)
	var m := MechModel.new()
	m.configure("chicken", "strider", {})
	add_child(m)
	await frames(1)
	_check(m, "standing", true)
	for p: Array in POSES:
		m.set_external_pose(p[1], p[2], p[3], p[4])
		_check(m, str(p[0]), true)
	# Heat shutdown slump (MechRig.sag_*), feet planted under the hips: settled, and the deepest the settle may reach.
	var rig := MechRig.new()
	for f: float in [1.0, MechRig.SAG_PEAK]:
		m.set_external_pose(_slump_legs(m, rig, f), Vector3(0, -rig.sag_depth * f, 0),
				Vector3(-rig.sag_pitch * f, 0, rig.sag_roll * f), 0.0)
		_check(m, "shutdown slump x%.2f" % f, true)
	rig.free()
	# The thigh's whole fore-aft swing (the motion cases reach -49 to +98 degrees from straight down, + = back).
	var l := m.leg_lengths()
	for deg in range(-50, 101, 10):
		var a := deg_to_rad(float(deg))
		var legs: Array = []
		for side: float in [-1.0, 1.0]:
			var hip := m.hip_posed(side, Vector3.ZERO, Vector3.ZERO)
			var knee := hip + Vector3(0, -cos(a), sin(a)) * l.x
			var ankle := knee + Vector3(0, -0.77, -0.64) * l.y
			legs.append({"hip": hip, "knee": knee, "ankle": ankle, "foot": ankle + Vector3(0, -l.z, 0)})
		m.set_external_pose(legs, Vector3.ZERO, Vector3.ZERO, 0.0)
		_check(m, "thigh swung %+d deg" % deg, false)
	m.queue_free()
	finish()


## Thigh / knee cap against the torso skin (when `torso`), each thigh against its socket cup.
func _check(m: MechModel, tag: String, torso: bool) -> void:
	if torso:
		var t := m.find_child("Torso", true, false) as MeshInstance3D
		var inv := t.global_transform.affine_inverse()
		var worst := -INF
		var worst_pad := -0.1
		for n: String in ["thigh_l", "thigh_r", "knee_l", "knee_r"]:
			var mi := m.find_child(n, true, false) as MeshInstance3D
			var xf := inv * mi.global_transform
			for v in _points(mi.mesh as ArrayMesh):
				var q := xf * v
				worst = maxf(worst, _skin_depth(q))
				if _pad_box.has_point(q):
					var pd := _pad_depth(q)
					if pd > 0.0:
						print("    in pad: %s %s %+.3f" % [n, q, pd])
					worst_pad = maxf(worst_pad, pd)
		print("  %-22s torso skin  %+.3f   pads %+.3f" % [tag, worst, worst_pad])
		check(worst < -SKIN_MARGIN, "%s: thighs and knee caps clear the torso skin (deepest %+.3f)" % [tag, worst])
		check(worst_pad < -SKIN_MARGIN, "%s: thighs and knee caps clear the hardpoint pads (deepest %+.3f)" % [tag, worst_pad])
	for side: String in ["l", "r"]:
		var so := m.find_child("socket_" + side, true, false) as Node3D
		var th := m.find_child("thigh_" + side, true, false) as MeshInstance3D
		var xf := so.global_transform.affine_inverse() * th.global_transform
		var worst := -INF
		for v in _points(th.mesh as ArrayMesh):
			var u := xf * v
			if u.length() > MechMeshes.HIP_BALL:   # inside the ball is the ball's business
				worst = maxf(worst, _cup_depth(u))
		print("  %-22s socket_%s    %+.3f" % [tag, side, worst])
		check(worst < -CUP_MARGIN, "%s: thigh_%s clears its hip socket cup (deepest %+.3f)" % [tag, side, worst])


## The legs solved as MechRig does with the body slumped by `f` of the rig's sag (feet on the ground under the hips).
static func _slump_legs(m: MechModel, rig: MechRig, f: float) -> Array:
	var off := Vector3(0, -rig.sag_depth * f, 0)
	var rot := Vector3(-rig.sag_pitch * f, 0, rig.sag_roll * f)
	var l := m.leg_lengths()
	var legs: Array = []
	for side: float in [-1.0, 1.0]:
		var hip := m.hip_posed(side, off, rot)
		var foot := Vector3(m.hip_local(side).x, 0.0, 0.0)
		var r := LegIK.solve_leg(hip, foot, l.x, l.y, l.z, Vector3.UP, Vector3.FORWARD, m.tarsus_lean(), m.leg_bend)
		legs.append({"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"]})
	return legs


## A mesh's vertices and face centres.
static func _points(mesh: ArrayMesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			out.append_array([v[i], v[i + 1], v[i + 2], (v[i] + v[i + 1] + v[i + 2]) / 3.0])
	return out


func _build_skin() -> void:
	var rings: Array = []
	for s: Array in MechMeshes.TORSO:
		rings.append(MechMeshes._torso_ring(s))
	for r in rings.size() - 1:
		var ra: PackedVector3Array = rings[r]
		var rb: PackedVector3Array = rings[r + 1]
		var tris: Array = []
		for k in ra.size():
			var k2 := (k + 1) % ra.size()
			for t: Array in [[ra[k], ra[k2], rb[k2]], [ra[k], rb[k2], rb[k]]]:
				var n: Vector3 = ((t[1] as Vector3) - t[0]).cross((t[2] as Vector3) - t[0]).normalized()
				var c: Vector3 = ((t[0] as Vector3) + t[1] + t[2]) / 3.0
				if n.dot(c - Vector3(0, 0.89, c.z)) < 0.0:
					n = -n
				tris.append([t[0], t[1], t[2], n])
		_skin.append([ra[0].z, rb[0].z, tris])


## Signed distance from the torso's faceted skin (+ = inside); -1 when clearly far outside.
func _skin_depth(q: Vector3) -> float:
	if Vector2(q.x / 0.97, (q.y - 0.88) / (0.96 if q.y > 0.88 else 0.8)).length() > 1.35 or q.z < -1.1 or q.z > 1.05:
		return -1.0
	var best := INF
	var sign := -1.0
	for seg: Array in _skin:
		if q.z < float(seg[0]) - 0.3 or q.z > float(seg[1]) + 0.3:
			continue
		for t: Array in seg[2]:
			var cp := _closest_on_tri(q, t[0], t[1], t[2])
			var d := q.distance_squared_to(cp)
			if d < best:
				best = d
				sign = 1.0 if (q - cp).dot(t[3]) < 0.0 else -1.0
	return -1.0 if best == INF else sqrt(best) * sign


## Signed distance from the hardpoint pads' surface (+ = inside), capped at -0.1 outside.
func _pad_depth(q: Vector3) -> float:
	var best := 0.1
	for i in range(0, _pads.size(), 3):
		best = minf(best, q.distance_to(HC.closest_on_tri(q, _pads[i], _pads[i + 1], _pads[i + 2])))
	if best >= 0.1:
		return -0.1
	return best if HC.inside(q, _pads) else -best


## Depth inside the socket cup (socket mesh space): the 8-sided lathe between its bottom cap and its top.
static func _cup_depth(u: Vector3) -> float:
	var lo: float = CUP[0].y
	var hi: float = CUP[CUP.size() - 1].y
	if u.y <= lo or u.y >= hi:
		return minf(u.y - lo, hi - u.y)
	var i := 0
	while u.y > CUP[i + 1].y:
		i += 1
	var r := lerpf(CUP[i].x, CUP[i + 1].x, (u.y - CUP[i].y) / (CUP[i + 1].y - CUP[i].y))
	var off := fposmod(rad_to_deg(atan2(u.x, -u.z)) + 22.5, 45.0) - 22.5   # from the nearest edge middle
	var edge := r * cos(deg_to_rad(22.5)) / cos(deg_to_rad(off))
	return minf(edge - Vector2(u.x, u.z).length(), minf(u.y - lo, hi - u.y))


static func _closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
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
