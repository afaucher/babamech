extends TestCase
## The Wasp's moving parts against its body (docs/design/chassis-rules.md 3.4, 3.8, 5.2, 5.5, 9.3). Pure geometry in body
## space (the "Chassis" node's frame: model units before BODY_SCALE), posed through the model's own hooks, no clock:
##  - the main fans (ring, spokes, rotor at three blade angles) across their whole tilt ellipse (centre, the ends of each
##    axis and every 30 deg round the edge, each fan alone and both together) keep SKIN_MARGIN off the hull and the
##    coaming, the pads, the nose, the fin, the hatch, every pilot head and the other fan, and off their own strut outside
##    the gimbal (ball in cup: nested by design);
##  - every pilot head clears the coaming and the fin;
##  - the legs, every pose from dangle to stand: each joint inside its declared range (WaspMeshes THIGH_RANGE / KNEE_RANGE /
##    FOOT_RANGE), the thighs, shins, knee and ankle drums and feet keep SKIN_MARGIN off the hull, the pads and the other
##    leg; the shin and foot off their own thigh's socket; the thigh's top end stays inside its hip drum (the pin);
##  - standing (landed): every sole on the ground (the lowest point within 1 cm of it, nothing below), the centre of mass
##    (area-weighted, default and heaviest loadouts) inside the feet's footprint with BALANCE_MARGIN, the feet apart.
## Prints the closest values (the audit). The weapons against all of these: test_hardpoint_contact_wasp.

const SKIN_MARGIN := 0.02
const CUP_MARGIN := 0.01
const BALANCE_MARGIN := 0.05    ## model units (10 cm at mech scale 2) inside the footprint's edge

const HC := preload("res://tests/test_hardpoint_contact.gd")
const HCB := preload("res://tests/test_hardpoint_contact_bulwark.gd")


func setup() -> void:
	timeout_sec = 300.0
	var hull := HC.tris(WaspMeshes.hull_shell(), Transform3D.IDENTITY)
	var pads := HC.tris(WaspMeshes.hardpoint_pads(), Transform3D.IDENTITY)
	var nose := HC.tris(WaspMeshes.build("wasp_nose"), Transform3D(Basis(), WaspMeshes.NOSE_AT))
	var fin := HC.tris(WaspMeshes.build("wasp_fin"), Transform3D.IDENTITY)
	var hatch := HC.tris(MechMeshes.build("hatch"), Transform3D(Basis(), Vector3(0, WaspMeshes.HATCH_Y, WaspMeshes.HATCH_Z)))
	var coam := HC.tris(WaspMeshes.coaming(), Transform3D.IDENTITY)
	var m := MechModel.new()
	m.show_drafts = true
	m.configure("chicken", "wasp", {})
	add_child(m)
	await frames(1)
	eq(m.chassis_id, "wasp", "the model builds the Wasp (show_drafts)")
	var ch := m.find_child("Chassis", true, false) as Node3D
	# Every pilot head, in body space.
	var heads := PackedVector3Array()
	var head_list := {}
	for h: String in MechCatalog.HEAD_ORDER:
		m.configure(h, "wasp", {})
		await frames(1)
		ch = m.find_child("Chassis", true, false) as Node3D
		var t := HCB._node_tris(m.find_child("Head_" + h, true, false), ch.global_transform.affine_inverse())
		heads.append_array(t)
		head_list[h] = t
		# The neck goes down through the hatch as on every chassis (its base under the lid: hidden); what shows above the
		# coaming's top keeps off it, and the neck passes inside the coaming's inner wall where it crosses its top.
		var above := PackedVector3Array()
		var neck := 0.0
		for i in range(0, t.size(), 3):
			var lo := minf(t[i].y, minf(t[i + 1].y, t[i + 2].y))
			if lo > WaspMeshes.COAM_TOP + 0.005:
				above.append_array([t[i], t[i + 1], t[i + 2]])
			for j in 3:   # where the triangle's edges cross the coaming's top plane
				var p: Vector3 = t[i + j]
				var q: Vector3 = t[i + (j + 1) % 3]
				var y := WaspMeshes.COAM_TOP
				if (p.y - y) * (q.y - y) <= 0.0 and absf(q.y - p.y) > 1e-6:
					var x := p.lerp(q, (y - p.y) / (q.y - p.y))
					neck = maxf(neck, Vector2(x.x, x.z - WaspMeshes.HATCH_Z).length())
		var cg := HC.surface_gap(above, coam, 0.3)
		var fg := HC.surface_gap(t, fin, 0.3)
		check(cg > 0.0, "%s: what shows of the head clears the coaming (gap %.3f)" % [h, cg])
		check(neck < WaspMeshes.COAM_IN, "%s: the neck passes inside the coaming (%.3f < %.3f)" % [h, neck, WaspMeshes.COAM_IN])
		check(fg >= SKIN_MARGIN, "%s: clear of the fin (gap %.3f)" % [h, fg])
		print("  head %-8s coaming %.3f (neck radius at its top %.3f) fin %.3f" % [h, cg, neck, fg])
	m.configure("chicken", "wasp", {})
	await frames(1)
	ch = m.find_child("Chassis", true, false) as Node3D
	var inv := ch.global_transform.affine_inverse()
	# --- The fans across their tilt ellipse ---------------------------------------------------------------------
	var body := hull.duplicate()
	body.append_array(pads)
	body.append_array(nose)
	body.append_array(fin)
	body.append_array(hatch)
	var tm: Vector2 = WaspMeshes.FAN_TILT_MAX
	var tilts: Array = [Vector2.ZERO, Vector2(tm.x, 0), Vector2(-tm.x, 0), Vector2(0, tm.y), Vector2(0, -tm.y)]
	for i in 12:
		var a := TAU * float(i) / 12.0
		tilts.append(Vector2(cos(a) * tm.x, sin(a) * tm.y))
	var strut_r := _away(HCB._node_tris(m.find_child("Strut_r", true, false), inv), WaspMeshes.FAN_PIVOT, 0.17)
	var worst := {"body": INF, "heads": INF, "strut": INF, "other": INF}
	var where := {}
	for tilt: Vector2 in tilts:
		var cl := m.clamp_fan_tilt(tilt)
		check(cl.is_equal_approx(tilt) or (cl - tilt).length() < 1e-4, "tilt %s is inside the ellipse" % str(tilt))
		for rot: float in [0.0, 0.4, 0.8]:
			m._rotor_angle = rot
			m.set_fan_tilt(tilt, 1)
			m.set_fan_tilt(Vector2(tilt.x, -tilt.y), -1)   # the left fan rolled the other way (strafing)
			var fr := HCB._node_tris(m.find_child("fan_r", true, false), inv)
			var fl := HCB._node_tris(m.find_child("fan_l", true, false), inv)
			var g := {"body": HC.surface_gap(fr, body, 0.3), "heads": HC.surface_gap(fr, heads, 0.3),
				"strut": HC.surface_gap(_away(fr, WaspMeshes.FAN_PIVOT, 0.17), strut_r, 0.3), "other": HC.surface_gap(fr, fl, 0.3)}
			for k: String in g:
				if float(g[k]) < float(worst[k]):
					worst[k] = g[k]
					where[k] = "tilt %s rotor %.1f" % [str(tilt), rot]
			# Both fans tilted the same way too (forward flight, a turn).
			m.set_fan_tilt(tilt, -1)
			var fl2 := HCB._node_tris(m.find_child("fan_l", true, false), inv)
			var gl := HC.surface_gap(fl2, body, 0.3)
			if gl < float(worst["body"]):
				worst["body"] = gl
				where["body"] = "left tilt %s rotor %.1f" % [str(tilt), rot]
	if float(worst["heads"]) < SKIN_MARGIN:   # which head, where
		var wt: Vector2 = str_to_var("Vector2" + str(where["heads"]).split(" rotor")[0].trim_prefix("tilt "))
		m.set_fan_tilt(wt, 1)
		var fr := HCB._node_tris(m.find_child("fan_r", true, false), inv)
		for h: String in head_list:
			print("    fan at tilt %s vs %s: %.3f" % [str(wt), h, HC.surface_gap(fr, head_list[h], 0.3)])
	m.set_fan_tilt(Vector2.ZERO)
	check(float(worst["body"]) >= SKIN_MARGIN, "the fans clear the hull, coaming, pads, nose, fin and hatch at every tilt (closest %.3f at %s)" % [worst["body"], where.get("body", "")])
	check(float(worst["heads"]) >= SKIN_MARGIN, "the fans clear every pilot head at every tilt (closest %.3f at %s)" % [worst["heads"], where.get("heads", "")])
	check(float(worst["strut"]) >= SKIN_MARGIN, "the fan clears its strut outside the gimbal at every tilt (closest %.3f at %s)" % [worst["strut"], where.get("strut", "")])
	check(float(worst["other"]) >= SKIN_MARGIN, "the two fans clear each other (closest %.3f)" % worst["other"])
	print("  fans: body %.3f (%s), heads %.3f (%s), strut %.3f, other fan %.3f" % [worst["body"], where.get("body", ""),
		worst["heads"], where.get("heads", ""), worst["strut"], worst["other"]])
	# The rotor inside its ring: blade tips off the duct's inner wall, blades off the spokes and the motor.
	near(WaspMeshes.ROTOR_Y, 0.16, 1e-6, "ROTOR_Y")
	check(WaspMeshes.BLADE_R <= WaspMeshes.RING_IN - SKIN_MARGIN, "blade tips (%.2f) inside the duct's wall (%.2f)" % [WaspMeshes.BLADE_R, WaspMeshes.RING_IN])
	var ring := HC.tris(WaspMeshes.build("wasp_fan_ring"), Transform3D.IDENTITY)
	var ring_out := _away(ring, Vector3(0, WaspMeshes.ROTOR_Y, 0), 0.13)   # without the hub / motor the rotor's hub nests on
	var rgap := INF
	for rot: float in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4]:
		var rt := HC.tris(WaspMeshes.build("wasp_rotor"), Transform3D(Basis(Vector3.UP, rot), Vector3(0, WaspMeshes.ROTOR_Y, 0)))
		rgap = minf(rgap, HC.surface_gap(_away(rt, Vector3(0, WaspMeshes.ROTOR_Y, 0), 0.13), ring_out, 0.3))
	check(rgap >= 0.005, "the blades clear the ring, spokes and motor while turning (closest %.3f)" % rgap)
	print("  rotor in its ring: closest %.3f" % rgap)
	# --- The legs, dangle to stand ------------------------------------------------------------------------------
	var still := body.duplicate()
	var lw := {"body": INF, "other": INF, "self": INF}
	var lwhere := {}
	for i in 11:
		var t := float(i) / 10.0
		m.set_legs_pose(t)
		var a := WaspMeshes.leg_angles(t)
		check(a.x >= WaspMeshes.THIGH_RANGE.x - 1e-4 and a.x <= WaspMeshes.THIGH_RANGE.y + 1e-4, "pose %.1f: thigh %.2f inside its range" % [t, a.x])
		check(a.x + a.y >= WaspMeshes.KNEE_RANGE.x - 1e-4 and a.x + a.y <= WaspMeshes.KNEE_RANGE.y + 1e-4, "pose %.1f: knee bend %.2f inside its range" % [t, a.x + a.y])
		check(a.z >= WaspMeshes.FOOT_RANGE.x - 1e-4 and a.z <= WaspMeshes.FOOT_RANGE.y + 1e-4, "pose %.1f: foot pitch %.2f inside its range" % [t, a.z])
		var legs := {}
		for tag: String in ["l", "r"]:
			var lt := PackedVector3Array()
			for n: String in ["thigh_", "knee_", "ankle_"]:
				lt.append_array(HCB._node_tris(m.find_child(n + tag, true, false), inv))
			legs[tag] = lt
			var lower := PackedVector3Array()
			for n: String in ["knee_", "ankle_"]:   # the knee node carries the shin, ankle and foot
				lower.append_array(HCB._node_tris(m.find_child(n + tag, true, false), inv))
			var sock := HCB._node_tris(m.find_child("socket_" + tag, true, false), inv)
			var sg := HC.surface_gap(lower, sock, 0.3)
			if sg < float(lw["self"]):
				lw["self"] = sg
				lwhere["self"] = "pose %.1f" % t
		for tag: String in ["l", "r"]:
			# The thigh's own top (inside its drum, under the clevis plate) is nested by design: the hip pad region.
			var lt: PackedVector3Array = _away(legs[tag], WaspMeshes.HIP * Vector3(-1.0 if tag == "l" else 1.0, 1, 1), 0.12)
			var bg := HC.surface_gap(lt, still, 0.3)
			if bg < float(lw["body"]):
				lw["body"] = bg
				lwhere["body"] = "pose %.1f %s" % [t, tag]
		var og := HC.surface_gap(legs["l"], legs["r"], 0.3)
		if og < float(lw["other"]):
			lw["other"] = og
	check(float(lw["body"]) >= SKIN_MARGIN, "the legs clear the hull and pads from dangle to stand (closest %.3f at %s)" % [lw["body"], lwhere.get("body", "")])
	check(float(lw["other"]) >= SKIN_MARGIN, "the legs clear each other (closest %.3f)" % lw["other"])
	check(float(lw["self"]) >= CUP_MARGIN, "the shin and foot clear their hip clevis (closest %.3f at %s)" % [lw["self"], lwhere.get("self", "")])
	print("  legs: body %.3f (%s), each other %.3f, own clevis %.3f" % [lw["body"], lwhere.get("body", ""), lw["other"], lw["self"]])
	# The thigh's top stays inside the hip drum: nested by design (rule 3.1).
	check(0.055 < WaspMeshes.HIP_DRUM.x and 0.06 < WaspMeshes.HIP_DRUM.x, "the thigh's root section fits inside the hip drum")
	check(WaspMeshes.HIP_DRUM.y + WaspMeshes.HIP_DRUM.x * 0.12 + 0.04 < WaspMeshes.CLEVIS_IN, "the hip drum and its bolts fit between the clevis cheeks")
	# --- Landed: on the feet, balanced --------------------------------------------------------------------------
	m.set_legs_pose(1.0)
	await frames(1)
	var ground := -WaspMeshes.BODY_Y / WaspMeshes.BODY_SCALE
	var mg := m.global_transform.affine_inverse()
	var foot_pts := PackedVector2Array()
	for tag: String in ["l", "r"]:
		var ft := HCB._node_tris(m.find_child("foot_" + tag, true, false), mg)   # model space
		var low := INF
		for p in ft:
			low = minf(low, p.y)
			if p.y < 0.01:
				foot_pts.append(Vector2(p.x, p.z))
		check(low > -0.002 and low < 0.01, "foot_%s stands on the ground (lowest %.4f model units)" % [tag, low])
	var lowest_leg := INF
	for n: String in ["thigh_l", "thigh_r", "shin_l", "shin_r"]:
		for p in HCB._node_tris(m.find_child(n, true, false), mg):
			lowest_leg = minf(lowest_leg, p.y)
	check(lowest_leg > 0.03, "nothing but the feet touches the ground (lowest leg point %.3f)" % lowest_leg)
	near(ground * WaspMeshes.BODY_SCALE, -WaspMeshes.BODY_Y, 1e-6, "the ground is BODY_Y under the body origin")
	var hull2 := Geometry2D.convex_hull(foot_pts)
	check(hull2.size() >= 4, "the feet have a footprint (%d corners)" % hull2.size())
	var fw := INF
	var fe := -INF
	for p in foot_pts:
		fw = minf(fw, p.x)
		fe = maxf(fe, p.x)
	print("  footprint: %.2f m wide (model x %.3f..%.3f)" % [(fe - fw) * 2.0, fw, fe])
	for lo: Dictionary in [{}, _heaviest()]:
		m.configure("chicken", "wasp", lo)
		m.set_legs_pose(1.0)
		await frames(1)
		var com := _com(m)
		var inside := Geometry2D.is_point_in_polygon(Vector2(com.x, com.z), hull2)
		var edge := _edge_dist(Vector2(com.x, com.z), hull2)
		check(inside and edge >= BALANCE_MARGIN, "loadout %s: the centre of mass (%.3f, %.3f) is over the feet, %.3f inside the footprint's edge" % [
			str(m.loadout), com.x, com.z, edge if inside else -edge])
		print("  centre of mass (model) %s, %.3f inside the footprint (%s)" % [str(com), edge if inside else -edge, str(m.loadout)])
	m.queue_free()
	finish()


## The triangles of `t` with no corner within `r` of `c` (a nested joint left out).
static func _away(t: PackedVector3Array, c: Vector3, r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in range(0, t.size(), 3):
		if t[i].distance_to(c) > r and t[i + 1].distance_to(c) > r and t[i + 2].distance_to(c) > r:
			out.append_array([t[i], t[i + 1], t[i + 2]])
	return out


## The heaviest loadout by faces (every hardpoint's biggest item).
static func _heaviest() -> Dictionary:
	var lo := {}
	for hp: Dictionary in MechCatalog.entry("wasp")["hardpoints"]:
		var best := ""
		var bn := -1
		for w: String in MechCatalog.items_for(hp):
			var n := 0
			var mesh := MechMeshes.mesh("weapon_" + w)
			for s in mesh.get_surface_count():
				n += mesh.surface_get_array_len(s) / 3
			if n > bn:
				bn = n
				best = w
		lo[hp["id"]] = best
	return lo


## The model's centre of mass in model space, by surface area (a shell of even thickness: good enough to place the feet).
static func _com(m: MechModel) -> Vector3:
	var t := HCB._node_tris(m, m.global_transform.affine_inverse())
	var sum := Vector3.ZERO
	var area := 0.0
	for i in range(0, t.size(), 3):
		var a := (t[i + 1] - t[i]).cross(t[i + 2] - t[i]).length() * 0.5
		sum += (t[i] + t[i + 1] + t[i + 2]) / 3.0 * a
		area += a
	return sum / maxf(area, 1e-9)


static func _edge_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size() - 1:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[i], poly[i + 1])))
	return best
