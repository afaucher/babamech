extends TestCase
## The Bulwark's sumo legs against its body (docs/design/chassis-rules.md 3.4, 5.2, 9.3; test_torso_clearance does the
## Strider). Pure geometry, no clock. In every pose below, no vertex (or face centre) of a thigh, knee drum or shin (the
## knee pad included) gets inside the barrel skin, the side pads, the back plinths or the pelvis, keeping SKIN_MARGIN off
## (thigh points inside the hip ball excepted: nested by design), and no shin point within SKIN_MARGIN of the hip ball;
## no shin point gets within SKIN_MARGIN of its knee pad (on the upright knee cap);
## and no thigh vertex outside the hip ball gets into its own socket cup (CUP_MARGIN), including across the thigh's whole
## fore-aft swing. Poses (legs solved with LegIK as MechRig does, forward knees):
##   standing; a walk cycle (12 phases, stride WALK_STRIDE, foot lift WALK_LIFT); the same cycle with the hip twist at
##   +-90 deg (strafing) and +-45 deg; step-up (one foot on a ledge at the rig's max step, ahead); a landing dip; the heat
##   shutdown slump, settled and at its deepest overshoot (MechRig's sag shape scaled to the Bulwark's hip height: SAG).
## Prints the deepest value per pose (negative = clear by that much).

const SKIN_MARGIN := 0.02     ## torso units (x1.2 in model units)
const CUP_MARGIN := 0.01      ## socket units
const WALK_STRIDE := 0.6      ## model units, front foot to back foot
const WALK_LIFT := 0.2        ## model units, the swing foot's top
## MechRig's shutdown slump for the Bulwark: its depth scaled by hip height from the Strider's 0.42 at 2.2 (MechRig's
## sag_depth is one number for every chassis today; per-chassis rig tuning is phase 2), pitch and roll as MechRig.
const SAG := {"depth": 0.19, "pitch": 0.17, "roll": 0.035}
const LAND_DIP := 0.16        ## MechRig.absorb 0.35 scaled the same way

const HC := preload("res://tests/test_hardpoint_contact.gd")

var _barrel := PackedVector3Array()   ## the barrel shell, flat triangles (torso space)
var _pads := PackedVector3Array()     ## side pads + back plinths
var _pelvis := PackedVector3Array()
var _barrel_box := AABB()
var _pads_box := AABB()
var _pelvis_box := AABB()
var _worst := {}


func setup() -> void:
	timeout_sec = 240.0
	var k := MeshKit.new()
	BulwarkMeshes._skin(k, BulwarkMeshes._rings(), MechMeshes.WHITE)
	_barrel = HC.tris(k.commit(MechMeshes.materials()), Transform3D.IDENTITY)
	_pads = HC.tris(BulwarkMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	_pelvis = HC.tris(BulwarkMeshes.build("bulwark_pelvis"), Transform3D.IDENTITY)   # in the Pelvis node's own frame
	_barrel_box = HC._bounds(_barrel).grow(SKIN_MARGIN + 0.01)
	_pads_box = HC._bounds(_pads).grow(SKIN_MARGIN + 0.01)
	_pelvis_box = HC._bounds(_pelvis).grow(SKIN_MARGIN + 0.01)
	var m := MechModel.new()
	m.configure("chicken", "bulwark", {})
	add_child(m)
	await frames(1)
	eq(m.leg_bend, 1.0, "the Bulwark's knees bend forward")
	_check(m, "standing", true)
	var lift := m.max_foot_lift()
	print("  hip %.3f  max foot lift %.3f  max step %.3f (model units)" % [m.hip_height(), lift, lift * 0.9])
	check(lift >= WALK_LIFT, "the legs can lift a foot %.2f (max foot lift %.3f)" % [WALK_LIFT, lift])
	for yaw: float in [0.0, PI * 0.25, -PI * 0.25, PI * 0.5, -PI * 0.5]:
		for i in 12:
			var ph := float(i) / 12.0
			m.set_external_pose(_walk(m, ph, yaw), Vector3(0, -0.03 * absf(sin(ph * TAU)), 0), Vector3(-0.05, 0, 0.03 * sin(ph * TAU)), yaw)
			_check(m, "walk twist %+.0f ph %.2f" % [rad_to_deg(yaw), ph], true)
	# Step-up: the right foot on a ledge at the max step, ahead; the left on the ground behind.
	var h := lift * 0.9
	m.set_external_pose([_leg(m, -1.0, Vector3(m.hip_local(-1.0).x, 0.0, 0.15), Vector3.ZERO, Vector3.ZERO, 0.0),
		_leg(m, 1.0, Vector3(m.hip_local(1.0).x, h, -0.3), Vector3.ZERO, Vector3.ZERO, 0.0)], Vector3.ZERO, Vector3.ZERO, 0.0)
	_check(m, "step-up %.2f" % h, true)
	# Landing dip: feet planted, the body down.
	var dip := Vector3(0, -LAND_DIP, 0)
	m.set_external_pose(_planted(m, dip, Vector3.ZERO), dip, Vector3.ZERO, 0.0)
	_check(m, "landing dip", true)
	# Heat shutdown slump, settled and at its deepest overshoot.
	for f: float in [1.0, MechRig.SAG_PEAK]:
		var off := Vector3(0, -float(SAG["depth"]) * f, 0)
		var rot := Vector3(-float(SAG["pitch"]) * f, 0, float(SAG["roll"]) * f)
		m.set_external_pose(_planted(m, off, rot), off, rot, 0.0)
		_check(m, "shutdown slump x%.2f" % f, true)
	# The thigh's fore-aft swing against its socket (+ = forward here): 30 deg back to 100 deg forward.
	var l := m.leg_lengths()
	for deg in range(-30, 101, 10):
		var a := deg_to_rad(float(deg))
		var legs: Array = []
		for side: float in [-1.0, 1.0]:
			var hip := m.hip_posed(side, Vector3.ZERO, Vector3.ZERO)
			var knee := hip + Vector3(0, -cos(a), -sin(a)) * l.x
			var ankle := knee + Vector3(0, -0.6, 0.8) * l.y
			legs.append({"hip": hip, "knee": knee, "ankle": ankle, "foot": ankle + Vector3(0, -l.z, 0)})
		m.set_external_pose(legs, Vector3.ZERO, Vector3.ZERO, 0.0)
		_check(m, "thigh swung %+d deg" % deg, false)
	print("  worst: %s" % str(_worst))
	m.queue_free()
	finish()


## The walk cycle at phase `ph` (0..1) with the legs twisted by `yaw`: each foot plants for half the cycle (moving back
## under the body) and swings forward for the other half, lifted WALK_LIFT at its top; the right foot half a cycle on.
static func _walk(m: MechModel, ph: float, yaw: float) -> Array:
	var legs: Array = []
	var tw := MechModel.twist_basis(yaw)
	var off := Vector3(0, -0.03 * absf(sin(ph * TAU)), 0)
	var rot := Vector3(-0.05, 0, 0.03 * sin(ph * TAU))
	for side: float in [-1.0, 1.0]:
		var p := fposmod(ph + (0.5 if side > 0.0 else 0.0), 1.0)
		var z := 0.0
		var y := 0.0
		if p < 0.5:
			z = lerpf(-WALK_STRIDE * 0.5, WALK_STRIDE * 0.5, p / 0.5)
		else:
			var q := (p - 0.5) / 0.5
			z = lerpf(WALK_STRIDE * 0.5, -WALK_STRIDE * 0.5, q)
			y = WALK_LIFT * sin(PI * q)
		var foot := tw * Vector3(m.hip_local(side).x, 0.0, z) + Vector3(0, y, 0)
		legs.append(_leg(m, side, foot, off, rot, yaw))
	return legs


## Feet planted under the standing hips, the body moved by off / rot.
static func _planted(m: MechModel, off: Vector3, rot: Vector3) -> Array:
	return [_leg(m, -1.0, Vector3(m.hip_local(-1.0).x, 0, 0), off, rot, 0.0), _leg(m, 1.0, Vector3(m.hip_local(1.0).x, 0, 0), off, rot, 0.0)]


static func _leg(m: MechModel, side: float, foot: Vector3, off: Vector3, rot: Vector3, yaw: float) -> Dictionary:
	var l := m.leg_lengths()
	var hip := m.hip_posed(side, off, rot, yaw)
	var fwd := MechModel.twist_basis(yaw) * Vector3.FORWARD
	var r := LegIK.solve_leg(hip, foot, l.x, l.y, l.z, Vector3.UP, fwd, m.tarsus_lean(), m.leg_bend)
	return {"hip": hip, "knee": r["knee"], "ankle": r["ankle"], "foot": r["foot"], "foot_dir": fwd}


## Thighs, knee drums and shins against the barrel, pads and pelvis (when `body`); each thigh against its socket cup.
func _check(m: MechModel, tag: String, body: bool) -> void:
	if body:
		var t := m.find_child("Torso", true, false) as MeshInstance3D
		var inv := t.global_transform.affine_inverse()
		var pel := (m.find_child("Pelvis", true, false) as Node3D).global_transform.affine_inverse()   # it turns with the legs
		var worst := {"barrel": -INF, "pads": -INF, "pelvis": -INF, "hip ball": -INF}
		var where := {}
		var r_ball := BulwarkMeshes.HIP_BALL * m.scale.x
		for n: String in ["thigh_l", "thigh_r", "knee_l", "knee_r", "shin_l", "shin_r"]:
			var mi := m.find_child(n, true, false) as MeshInstance3D
			var xf := inv * mi.global_transform
			var xp := pel * mi.global_transform
			var hip := (m.find_child("hip_" + n.right(1), true, false) as Node3D).global_position
			for v in _points(mi.mesh as ArrayMesh):
				var dh := (mi.global_transform * v).distance_to(hip)
				if n.begins_with("shin") and r_ball - dh > worst["hip ball"]:   # the shin passes the hip ball when folded
					worst["hip ball"] = r_ball - dh
					where["hip ball"] = "%s %s" % [n, v]
				if n.begins_with("thigh") and dh < r_ball:
					continue   # inside the hip ball is the ball's business (the axle ends in it)
				var q := xf * v
				for key: String in ["barrel", "pads", "pelvis"]:
					var qq := xp * v if key == "pelvis" else q
					var box: AABB = {"barrel": _barrel_box, "pads": _pads_box, "pelvis": _pelvis_box}[key]
					if box.has_point(qq):
						var d := _depth(qq, {"barrel": _barrel, "pads": _pads, "pelvis": _pelvis}[key])
						if d > worst[key]:
							worst[key] = d
							where[key] = "%s %s" % [n, q]
		for key: String in worst:
			var d: float = worst[key]
			_worst[key] = maxf(float(_worst.get(key, -INF)), d)
			if not check(d < -SKIN_MARGIN, "%s: thighs, knees and shins clear the %s (deepest %+.3f)" % [tag, key, d]):
				print("    deepest in %s: %s" % [key, where.get(key, "")])
		print("  %-26s barrel %+.3f  pads %+.3f  pelvis %+.3f  hip ball %+.3f" % [tag, worst["barrel"], worst["pads"], worst["pelvis"],
			worst["hip ball"]])
	for side: String in ["l", "r"]:   # the shin against the knee pad on its knee cap (the cap stays upright)
		var kn := m.find_child("knee_" + side, true, false) as Node3D
		var sh := m.find_child("shin_" + side, true, false) as MeshInstance3D
		var xk := kn.global_transform.affine_inverse() * sh.global_transform
		var pad := AABB(BulwarkMeshes.KNEE_PAD[0], BulwarkMeshes.KNEE_PAD[1] - BulwarkMeshes.KNEE_PAD[0])
		var into := -INF
		for v in _points(sh.mesh as ArrayMesh):
			var u := xk * v
			var d := minf(minf(minf(u.x - pad.position.x, pad.end.x - u.x), minf(u.y - pad.position.y, pad.end.y - u.y)),
				minf(u.z - pad.position.z, pad.end.z - u.z))   # + = inside the box by that much
			into = maxf(into, d)
		_worst["knee pad"] = maxf(float(_worst.get("knee pad", -INF)), into)
		check(into < -SKIN_MARGIN, "%s: shin_%s clears its knee pad (deepest %+.3f)" % [tag, side, into])
	for side: String in ["l", "r"]:
		var so := m.find_child("socket_" + side, true, false) as Node3D
		var th := m.find_child("thigh_" + side, true, false) as MeshInstance3D
		var xf := so.global_transform.affine_inverse() * th.global_transform
		var worst := -INF
		for v in _points(th.mesh as ArrayMesh):
			var u := xf * v
			if u.length() > BulwarkMeshes.HIP_BALL:
				worst = maxf(worst, _cup_depth(u))
		_worst["cup"] = maxf(float(_worst.get("cup", -INF)), worst)
		check(worst < -CUP_MARGIN, "%s: thigh_%s clears its hip socket cup (deepest %+.3f)" % [tag, side, worst])
		if not body:
			print("  %-26s socket_%s %+.3f" % [tag, side, worst])


## Signed distance to a closed soup's surface (+ = inside), capped at -0.1 outside.
static func _depth(q: Vector3, t: PackedVector3Array) -> float:
	var best := 0.1
	for i in range(0, t.size(), 3):
		best = minf(best, q.distance_to(HC.closest_on_tri(q, t[i], t[i + 1], t[i + 2])))
	var inside := HC.inside(q, t)
	if best >= 0.1 and not inside:
		return -0.1
	return best if inside else -best


static func _points(mesh: ArrayMesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			out.append_array([v[i], v[i + 1], v[i + 2], (v[i] + v[i + 1] + v[i + 2]) / 3.0])
	return out


## Depth inside the socket cup (socket mesh space): the 8-sided lathe between its bottom cap and its top.
static func _cup_depth(u: Vector3) -> float:
	var cup: Array = BulwarkMeshes.CUP
	var lo: float = cup[0].y
	var hi: float = cup[cup.size() - 1].y
	if u.y <= lo or u.y >= hi:
		return minf(u.y - lo, hi - u.y)
	var i := 0
	while u.y > cup[i + 1].y:
		i += 1
	var r := lerpf(cup[i].x, cup[i + 1].x, (u.y - cup[i].y) / (cup[i + 1].y - cup[i].y))
	var off := fposmod(rad_to_deg(atan2(u.x, -u.z)) + 22.5, 45.0) - 22.5
	var edge := r * cos(deg_to_rad(22.5)) / cos(deg_to_rad(off))
	return minf(edge - Vector2(u.x, u.z).length(), minf(u.y - lo, hi - u.y))
