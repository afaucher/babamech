extends TestCase
## Enemy animation (docs/design/enemy-anim/): planted feet (EnemyGait + LegIK) on the strider and the trooper at
## several speeds, stride / cadence following the ground speed, the stagger timeline inside the mechanical window (host
## exact, puppet guessed) ending at rest with the aim restored, the trooper's articulated crouch (hips down, muzzle and
## hit sphere where the squad logic puts them when it peeks), and the rig pieces / leg parts as closed shells.

const DT := 1.0 / 60.0
const STRIDER_TOL := 0.03     ## m a planted foot may drift (IK reach clamp, float noise)
const TROOPER_TOL := 0.02


func setup() -> void:
	timeout_sec = 120.0
	_gait_unit()
	await _planted_feet("strider", [3.0, 9.5, 13.5], STRIDER_TOL)
	await _planted_feet("trooper_rifle", [1.5, 4.5, 6.8, 9.0], TROOPER_TOL)
	await _planted_feet_ring()
	await _stagger_host("strider")
	await _stagger_host("trooper_rifle")
	await _stagger_host("tank")
	await _stagger_puppet()
	await _trooper_crouch("trooper_rifle")
	await _trooper_crouch("trooper_at")
	_rig_meshes()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 77
	add_child(w)
	return w


func _spawn(w: CombatWorld, type_id: String, id: String, puppet: bool) -> EnemyBase:
	var e: EnemyBase
	if type_id.begins_with("strider"):
		e = EnemyStrider.new()
	elif type_id.begins_with("trooper"):
		e = EnemyTrooper.new()
		(e as EnemyTrooper).force_rig = true
	elif type_id == "tank":
		e = EnemyTank.new()
	e.configure(type_id, id, w, null, null, 5)
	e.puppet = puppet
	e.ai_mode = "idle"
	add_child(e)
	w.register(e)
	return e


## World point of each displayed foot (the ankle point of the foot / boot part).
func _feet_world(e: EnemyBase) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if e is EnemyStrider:
		var s := e as EnemyStrider
		for pair: Array in [[s._rig_l, s._parts_l], [s._rig_r, s._parts_r]]:
			var rig: Node3D = pair[0]
			var parts: Array[MeshInstance3D] = pair[1]
			out.append(rig.global_transform * (parts[2].transform * EnemyMeshes.STRIDER_ANKLE))
	else:
		var t := e as EnemyTrooper
		var lx := float(t._joints["leg_x"])
		var ay := float(t._joints["ankle_y"])
		out.append(t._rig.global_transform * t.rig_point("boot_l", Vector3(-lx, ay, 0.0)))
		out.append(t._rig.global_transform * t.rig_point("boot_r", Vector3(lx, ay, 0.0)))
	return out


func _gait_of(e: EnemyBase) -> EnemyGait:
	return (e as EnemyStrider)._gait if e is EnemyStrider else (e as EnemyTrooper)._gait


## Walk a puppet straight ahead at each speed (its position written each frame, as EnemySync does): every foot that
## stays planted keeps its displayed world point; stride length and cadence grow with speed; it keeps stepping.
func _planted_feet(type_id: String, speeds: Array, tol: float) -> void:
	var w := _world()
	var strides: Array[float] = []
	var cadences: Array[float] = []
	for spd: float in speeds:
		var e := _spawn(w, type_id, "%s_walk_%d" % [type_id, int(spd * 10)], true)
		await frames(1)
		e.puppet_tick(DT)   # the first update switches the trooper's rig on (a fresh gait)
		var fwd := -e.global_basis.z
		var worst := 0.0
		var prev_feet: Array[Vector3] = []
		var prev_planted := [false, false]
		var steps0 := -1
		var t_on := 0.0
		for f in 360:
			e.global_position += fwd * spd * DT
			e.puppet_tick(DT)
			var g := _gait_of(e)
			var feet := _feet_world(e)
			if f > 30:
				if steps0 < 0:
					steps0 = g.steps
					t_on = 0.0
				t_on += DT
				for i in 2:
					var planted := g.is_planted(i)
					if planted and prev_planted[i] and not prev_feet.is_empty():
						worst = maxf(worst, feet[i].distance_to(prev_feet[i]))
					prev_planted[i] = planted
			prev_feet = feet
		var nsteps := _gait_of(e).steps - steps0
		var cadence := float(nsteps) / maxf(t_on, 0.01)
		var stride := spd / maxf(cadence, 0.01)
		strides.append(stride)
		cadences.append(cadence)
		print("[anim] %s %.1f m/s: %d steps in %.1f s (%.2f steps/s, %.2f m/step), planted drift %.4f m" % [type_id, spd,
			nsteps, t_on, cadence, stride, worst])
		check(worst <= tol, "%s at %.1f m/s: planted feet stay put (drift %.4f m <= %.2f)" % [type_id, spd, worst, tol])
		check(nsteps >= 4, "%s at %.1f m/s keeps stepping (%d steps)" % [type_id, spd, nsteps])
		e.queue_free()
		await frames(1)
	for i in range(1, speeds.size()):
		check(cadences[i] >= cadences[i - 1] - 0.05, "%s cadence rises with speed (%.2f -> %.2f steps/s)" % [type_id,
			cadences[i - 1], cadences[i]])
	check(strides[strides.size() - 1] > strides[0] * 1.5, "%s stride lengthens with speed (%.2f -> %.2f m)" % [type_id,
		strides[0], strides[strides.size() - 1]])
	w.queue_free()
	await frames(1)


## On a tilted floor (a ring deck's local up is not global Y): the feet stay on the unit's own floor plane and planted.
func _planted_feet_ring() -> void:
	var w := _world()
	var e := _spawn(w, "trooper_rifle", "trooper_tilt", true)
	var up := Vector3(0.0, 1.0, 0.6).normalized()
	var fwd := Vector3(1.0, 0.0, 0.0)
	e.up = up
	e.global_transform = Transform3D(Basis(fwd.cross(up).normalized(), up, -fwd), Vector3(0.0, 5.0, 0.0))
	await frames(1)
	e.puppet_tick(DT)
	var worst := 0.0
	var off_floor := 0.0
	var prev: Array[Vector3] = []
	var was := [false, false]
	for f in 240:
		e.global_position += fwd * 5.0 * DT
		e.puppet_tick(DT)
		var g := _gait_of(e)
		var feet := _feet_world(e)
		for i in 2:
			if g.is_planted(i):
				var sole := g.pos[i] - e.global_position
				off_floor = maxf(off_floor, absf(sole.dot(up)))
				if was[i] and not prev.is_empty() and f > 20:
					worst = maxf(worst, feet[i].distance_to(prev[i]))
			was[i] = g.is_planted(i)
		prev = feet
	check(off_floor < 0.01, "tilted deck: planted feet lie on the unit's floor plane (%.4f m off)" % off_floor)
	check(worst <= TROOPER_TOL, "tilted deck: planted feet stay put (%.4f m)" % worst)
	w.queue_free()
	await frames(1)


## Host stagger: the timeline starts with the mechanical stagger, its recovery (shake-off) runs in the last part of the
## window, and it ends at rest on the frame the stagger ends (aim / torso back where they were).
func _stagger_host(type_id: String) -> void:
	var w := _world()
	var e := _spawn(w, type_id, "%s_stag" % type_id, false)
	await frames(1)
	for _i in 90:
		w.advance(DT)
	var rest := _aim_pose(e)
	var dv := Vector3(2.8, 0.0, 7.0) / maxf(e.mass_factor(), 0.01)   # pushed back and to the right
	e.apply_impulse(e.global_basis * dv, "test")
	check(e.knock.staggered(), "%s: the impulse staggers it (mechanics untouched)" % type_id)
	var window := e.knock.stagger_left
	var t := 0.0
	var anim_on_while_stag := true
	var shake_first := -1.0
	var peak_k := 0.0
	var peak_aim := 0.0
	var ended_at := -1.0
	var stag_end := -1.0
	var steps0 := _gait_of(e).steps if (e is EnemyStrider or e is EnemyTrooper) else 0
	var frames_done := 0
	for _i in 120:
		w.advance(DT)
		t += DT
		frames_done += 1
		var a := e._stagger_anim
		if e.knock.staggered() and not a.active:
			anim_on_while_stag = false
		if not e.knock.staggered() and stag_end < 0.0:
			stag_end = t
		if absf(a.shake) > 1e-3 and shake_first < 0.0:
			shake_first = t
		peak_k = maxf(peak_k, a.k)
		peak_aim = maxf(peak_aim, a.aim_off)
		if not a.active and ended_at < 0.0:
			ended_at = t
		if ended_at > 0.0 and t > ended_at + 1.2:   # and let a trooper settle back into its crouch
			break
	var rec := EnemyStaggerAnim.rec_len(window)
	check(anim_on_while_stag, "%s: the animation runs for the whole mechanical stagger" % type_id)
	check(peak_k > 0.8 and peak_aim > 0.8, "%s: recoil and loss of aim read (k %.2f, aim %.2f)" % [type_id, peak_k, peak_aim])
	check(shake_first >= window - rec - 2.0 * DT and shake_first <= window, "%s: the shake-off plays in the last %.2f s of the %.2f s window (at %.3f s)" % [type_id, rec, window, shake_first])
	check(ended_at > 0.0 and absf(ended_at - stag_end) <= 2.0 * DT, "%s: the animation ends with the stagger (%.3f vs %.3f s)" % [type_id, ended_at, stag_end])
	var after := _aim_pose(e)
	check(after.distance_to(rest) < 0.02, "%s: aim pose restored after the stagger (%.4f)" % [type_id, after.distance_to(rest)])
	if e is EnemyStrider or e is EnemyTrooper:
		check(_gait_of(e).steps > steps0, "%s: stumble steps during the stagger (%d)" % [type_id, _gait_of(e).steps - steps0])
	w.queue_free()
	await frames(1)


## A few numbers describing the aim pose relative to the unit (weapon / chassis / turret orientation).
func _aim_pose(e: EnemyBase) -> Vector3:
	var inv := e.global_basis.inverse()
	if e is EnemyStrider:
		return (inv * (e as EnemyStrider)._chassis_pivot.global_basis.z)
	if e is EnemyTrooper:
		var t := e as EnemyTrooper
		return (t._rig_parts["arms"] as Node3D).transform.basis.z
	if e is EnemyTank:
		var tk := e as EnemyTank
		return inv * tk._turret_pivot.global_basis.z + inv * tk._hull_mi.global_basis.y
	return Vector3.ZERO


## Co-op puppet: only the staggered flag arrives. It plays the hit / stumble from the flag, the recovery when it drops,
## and ends at rest shortly after (MIN_REC .. REC_T), aim restored.
func _stagger_puppet() -> void:
	var w := _world()
	var e := _spawn(w, "strider", "strider_pup", true) as EnemyStrider
	await frames(1)
	for _i in 10:
		e.puppet_tick(DT)
	var rest := _aim_pose(e)
	var on_frames := 36   # the host's 0.6 s window
	var t := 0.0
	var ended := -1.0
	var shook := false
	for f in 90:
		e.puppet_apply({"state": EnemyBase.STATE_STAGGERED if f < on_frames else EnemyBase.STATE_IDLE,
			"stagger": f < on_frames, "aim": Vector2.ZERO, "hp": PackedFloat32Array()})
		e.global_position += Vector3(0.0, 0.0, 3.0 * DT) if f < 10 else Vector3.ZERO   # the knockback slide it sees
		e.puppet_tick(DT)
		t += DT
		shook = shook or absf(e._stagger_anim.shake) > 1e-3
		if f >= on_frames and not e._stagger_anim.active and ended < 0.0:
			ended = t
	var drop_t := float(on_frames) * DT
	check(shook, "puppet: the shake-off plays")
	check(ended > 0.0 and ended - drop_t <= EnemyStaggerAnim.REC_T + 2.0 * DT, "puppet: done %.3f s after the flag drops" % (ended - drop_t))
	check(e._stagger_anim.push.z > 0.5, "puppet: recoil direction from the slide it saw (push %s)" % str(e._stagger_anim.push))
	check(_aim_pose(e).distance_to(rest) < 0.02, "puppet: aim pose restored")
	w.queue_free()
	await frames(1)


## Trooper crouch (as a puppet, so the stream's peek flag drives it): crouched still -> hips well down, head under the
## old squashed height, crouched torso inside the crouch hit sphere; peeking -> standing, stepped out, the visual muzzle
## where muzzle_world() fires from and the torso inside the peek hit sphere.
func _trooper_crouch(type_id: String) -> void:
	var w := _world()
	var e := _spawn(w, type_id, "%s_crouch" % type_id, true) as EnemyTrooper
	await frames(1)
	e.set_puppet_aim(Vector2(0.0, 0.0))
	for _i in 90:
		e.puppet_tick(DT)
	var hip_y := float(e._joints["hip_y"])
	var crouch_pelvis := e._pose_pelvis
	var head_top := e.rig_point("head", Vector3(0.0, 2.25 * hip_y / EnemyMeshes.TROOPER_HIP_Y, 0.0))
	var torso_c := e.rig_point("torso", Vector3(0.0, 1.4, 0.0))
	var sph: Array[Dictionary] = e.world_spheres()
	var sc_local := e.global_transform.affine_inverse() * (sph[0]["center"] as Vector3)
	check(crouch_pelvis.y < hip_y - 0.3, "%s crouched: hips lowered %.2f m" % [type_id, hip_y - crouch_pelvis.y])
	check(head_top.y < 1.65, "%s crouched: head top at %.2f m (was 2.25 standing)" % [type_id, head_top.y])
	check(torso_c.distance_to(sc_local) < float(sph[0]["radius"]), "%s crouched: torso inside the crouch hit sphere" % type_id)
	var knee_bend := e.rig_point("thigh_l", Vector3(0.0, -1.0, 0.0)) - e.rig_point("thigh_l", Vector3.ZERO)
	check(knee_bend.z < -0.3, "%s crouched: thighs reach forward (knees bent)" % type_id)
	e.set_puppet_aim(Vector2(0.0, 1.0))
	for _i in 90:
		e.puppet_tick(DT)
	var stand_pelvis := e._pose_pelvis
	check(stand_pelvis.y > crouch_pelvis.y + 0.3, "%s peeking: stands up (pelvis %.2f -> %.2f)" % [type_id, crouch_pelvis.y, stand_pelvis.y])
	var vm := e.visual_muzzle()
	var gm := e.muzzle_world()
	check(vm.distance_to(gm) < 0.12, "%s peeking: visual muzzle %.3f m from muzzle_world()" % [type_id, vm.distance_to(gm)])
	sph = e.world_spheres()
	var tc := e._rig.global_transform * e.rig_point("torso", Vector3(0.0, 1.4, 0.0))
	check(tc.distance_to(sph[0]["center"] as Vector3) < float(sph[0]["radius"]), "%s peeking: torso inside the peek hit sphere" % type_id)
	w.queue_free()
	await frames(1)


func _gait_unit() -> void:
	# limb_basis carries the rest limb onto itself and keeps lengths.
	var b := EnemyGait.limb_basis(EnemyMeshes.STRIDER_KNEE, Vector3.BACK, EnemyMeshes.STRIDER_KNEE, Vector3.BACK)
	check(b.is_equal_approx(Basis.IDENTITY), "limb_basis(rest, rest) is identity")
	var d := Vector3(0.3, -1.0, -0.2)
	var b2 := EnemyGait.limb_basis(d, Vector3.FORWARD, Vector3.DOWN, Vector3.FORWARD)
	near((b2 * Vector3.DOWN).angle_to(d), 0.0, 1e-4, "limb_basis points the limb along the new direction")
	near(b2.determinant(), 1.0, 1e-4, "limb_basis is a rotation")


## Every rig piece and leg part: a closed, outward-wound shell (the geometry audit's rule).
func _rig_meshes() -> void:
	var parts: Array[String] = ["strider_thigh", "strider_shin", "strider_foot"]
	parts.append_array(EnemyMeshes.trooper_rig_parts())
	var open_total := 0
	var bad: Array[String] = []
	for p: String in parts:
		var m := EnemyMeshes.mesh(p)
		var open := _open_edges(m)
		if open > 0:
			bad.append("%s (%d)" % [p, open])
		open_total += open
	check(bad.is_empty(), "rig pieces watertight (%d parts; open: %s)" % [parts.size(), ", ".join(bad)])
	# The pieces add up to the whole body (same triangles, same palette).
	var whole := _tri_count(EnemyMeshes.mesh("trooper_rifle_5"))
	var sum := 0
	for pc: String in EnemyMeshes.TROOPER_PIECES:
		sum += _tri_count(EnemyMeshes.mesh(EnemyMeshes.trooper_rig_part("rifle", 5, pc)))
	eq(sum, whole, "trooper_rifle_5: the rig pieces hold exactly the whole body's triangles")


func _tri_count(m: ArrayMesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		n += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


func _open_edges(m: ArrayMesh) -> int:
	var edges := {}
	for s in m.get_surface_count():
		var v: PackedVector3Array = m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size(), 3):
			for e in 3:
				var a := v[i + e].snapped(Vector3.ONE * 1e-4)
				var b := v[i + (e + 1) % 3].snapped(Vector3.ONE * 1e-4)
				var key := [a, b]
				var rkey := [b, a]
				if edges.has(rkey):
					edges[rkey] = int(edges[rkey]) - 1
					if int(edges[rkey]) == 0:
						edges.erase(rkey)
				else:
					edges[key] = int(edges.get(key, 0)) + 1
	return edges.size()
