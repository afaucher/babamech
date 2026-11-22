class_name WorldAimMarkers
extends Node3D
## 3D world-space aim ring & per-weapon constant-thickness concentric tracking rings (depth-tested so buildings,
## cover and the mech naturally occlude them instead of drawing flat on top in 2D). Driven by MechHud from
## WeaponRack's read-only HUD contract. Cosmetic presentation only (no gameplay state).

const PIPS := 4
const MAX_SLOTS := 6
const SURFACE_PULL := 0.22    ## m pulled toward camera so surface markers don't z-fight walls/enemies
## Concentric ring radii (in unit screen-scaled frame) from outer (near muzzle) to inner (near target),
## all sharing the exact same stroke width so every ring has crisp, constant thickness and leaves the target unobstructed.
const PIP_RADII := [0.68, 0.54, 0.40, 0.26]
const AIM_RING_RADIUS := 0.96
const RING_STROKE := 0.068    ## constant radial stroke thickness shared across aim ring & all tracking rings
const RING_DEPTH := 0.025
const RING_SEGS := 16

const CYAN := Color(0.35, 0.95, 1.0)
const AMBER := Color(1.0, 0.68, 0.16)
const GREEN := Color(0.45, 1.0, 0.58)
const DIM := Color(0.55, 0.7, 0.78)
const WHITE := Color(0.95, 0.99, 1.0)

var rack: WeaponRack
var camera: Camera3D
var mech: MechController

var _pip_meshes: Array[ArrayMesh] = []   ## one constant-stroke ring mesh per concentric tier k = 0..PIPS-1
var _ring_mesh: ArrayMesh                ## outer aim-point surface ring (same stroke thickness)
var _x_mesh: ArrayMesh
var _mat_cache: Dictionary = {}          ## color+alpha key -> StandardMaterial3D

var _aim_root: Node3D
var _aim_ring: MeshInstance3D
var _slot_pips: Array = []               ## per slot: Array[MeshInstance3D] of PIPS
var _slot_x: Array[MeshInstance3D] = []


func _ready() -> void:
	name = "WorldAimMarkers"
	_build_meshes()
	_aim_root = Node3D.new()
	_aim_root.name = "AimPoint"
	add_child(_aim_root)
	_aim_ring = MeshInstance3D.new()
	_aim_ring.mesh = _ring_mesh
	_aim_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aim_root.add_child(_aim_ring)
	_aim_root.visible = false

	for _s in MAX_SLOTS:
		var pips: Array[MeshInstance3D] = []
		for k in PIPS:
			var mi := MeshInstance3D.new()
			mi.mesh = _pip_meshes[k]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visible = false
			add_child(mi)
			pips.append(mi)
		_slot_pips.append(pips)
		var xm := MeshInstance3D.new()
		xm.mesh = _x_mesh
		xm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		xm.material_override = _mat(AMBER, 1.0)
		xm.visible = false
		add_child(xm)
		_slot_x.append(xm)


func sync() -> void:
	if _aim_root == null:
		return
	var cam := camera if (camera != null and camera.is_inside_tree()) else (get_viewport().get_camera_3d() if is_inside_tree() else null)
	if rack == null or cam == null or not is_inside_tree():
		_hide_all()
		return
	var slots: Array = rack.slots()
	if slots.is_empty():
		_hide_all()
		return
	var aim := rack.aim()
	var cam_pos := cam.global_position
	var cam_up := cam.global_basis.y
	var fov_scale := tan(deg_to_rad(cam.fov * 0.5)) / tan(deg_to_rad(35.0))   # keeps apparent ring thickness steady while zoomed!
	var to_cam := cam_pos - aim
	var aim_dist := to_cam.length()
	var to_cam_dir := to_cam / maxf(aim_dist, 0.001)

	# 1. Surface aim ring (open center so target stays unobstructed; depth-tested).
	var designating := false
	for sd: Dictionary in slots:
		if bool(sd.get("designating", false)):
			designating = true
			break
	var aim_pos := aim + to_cam_dir * minf(SURFACE_PULL, aim_dist * 0.2)
	var aim_s := clampf(aim_dist * 0.015 * fov_scale, 0.20, 1.8)
	_aim_root.visible = true
	_aim_root.global_position = aim_pos
	_aim_root.global_basis = _face_basis(to_cam_dir, cam_up) * Basis.from_scale(Vector3.ONE * aim_s)
	_aim_ring.material_override = _mat(GREEN if designating else CYAN, 0.92)

	# 2. Per-weapon 3D constant-thickness concentric tracking rings along muzzle -> aim (or obstacle when blocked).
	var space := get_world_3d().direct_space_state
	for i in MAX_SLOTS:
		var pips: Array = _slot_pips[i]
		var xm: MeshInstance3D = _slot_x[i]
		if i >= slots.size():
			_hide_slot(pips, xm)
			continue
		var s: Dictionary = slots[i]
		if str(s["weapon"]) == "" or not bool(s["enabled"]) or not bool(s.get("built", true)) or not s.has("muzzle"):
			_hide_slot(pips, xm)
			continue
		var from: Vector3 = s["muzzle"]
		var is_blocked := bool(s.get("blocked", false))
		var end_pt := aim
		if is_blocked and space != null:
			var q := PhysicsRayQueryParameters3D.create(from, aim)
			if mech != null:
				q.exclude = [mech.get_rid()]
			var h := space.intersect_ray(q)
			if not h.is_empty():
				end_pt = h["position"] as Vector3
		var seg_len := from.distance_to(end_pt)
		if seg_len < 1.5:
			_hide_slot(pips, xm)
			continue
		var col := AMBER if is_blocked else (CYAN if bool(s.get("in_range", true)) else DIM)
		var lit := ceili(float(s.get("ready", 1.0)) * PIPS - 0.001)
		for k in PIPS:
			var t := 0.36 + 0.19 * float(k)   # 0.36, 0.55, 0.74, 0.93 along muzzle -> target
			var p := from.lerp(end_pt, t)
			var to_c := cam_pos - p
			var d_cam := to_c.length()
			var p_dir := to_c / maxf(d_cam, 0.001)
			var on := k < lit
			# Scale proportional to camera distance & FOV so stroke width stays constant on screen at every depth!
			var ring_s := clampf(d_cam * 0.015 * fov_scale, 0.18, 1.8)
			var mi: MeshInstance3D = pips[k]
			mi.visible = true
			mi.global_position = p
			mi.global_basis = _face_basis(p_dir, cam_up) * Basis.from_scale(Vector3.ONE * ring_s)
			mi.material_override = _mat(col, 0.90 if on else 0.26)
		if is_blocked:
			var d_x := cam_pos.distance_to(end_pt)
			var x_dir := (cam_pos - end_pt).normalized()
			xm.visible = true
			xm.global_position = end_pt + x_dir * minf(SURFACE_PULL, d_x * 0.2)
			xm.global_basis = _face_basis(x_dir, cam_up) * Basis.from_scale(Vector3.ONE * clampf(d_x * 0.014 * fov_scale, 0.22, 1.5))
		else:
			xm.visible = false


func _hide_all() -> void:
	if _aim_root != null:
		_aim_root.visible = false
	for i in MAX_SLOTS:
		_hide_slot(_slot_pips[i], _slot_x[i])


static func _hide_slot(pips: Array, xm: MeshInstance3D) -> void:
	for mi: MeshInstance3D in pips:
		mi.visible = false
	xm.visible = false


static func _face_basis(to_cam_dir: Vector3, up_hint: Vector3) -> Basis:
	var z := to_cam_dir.normalized()
	if z.length_squared() < 1e-6:
		return Basis.IDENTITY
	var u := up_hint if absf(z.dot(up_hint)) < 0.96 else Vector3.RIGHT
	var x := u.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _mat(col: Color, alpha: float) -> StandardMaterial3D:
	var key := "%d_%d_%d_%d" % [int(round(col.r * 255)), int(round(col.g * 255)), int(round(col.b * 255)), int(round(alpha * 100))]
	if _mat_cache.has(key):
		return _mat_cache[key] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	if alpha < 0.99:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Depth-tested (no_depth_test = false) so buildings, trees and the mech occlude world markers naturally.
	m.no_depth_test = false
	_mat_cache[key] = m
	return m


func _make_ring_mesh(outer_r: float, stroke: float) -> ArrayMesh:
	var kr := MeshKit.new()
	kr.shade = 0.0
	var r1 := outer_r
	var r0 := maxf(outer_r - stroke, 0.04)
	var r_mid := (r0 + r1) * 0.5
	var seg_l := 2.0 * r_mid * sin(PI / float(RING_SEGS)) * 1.08
	for i in RING_SEGS:
		var mid := TAU * (float(i) + 0.5) / float(RING_SEGS)
		var c := Vector3(cos(mid) * r_mid, sin(mid) * r_mid, 0.0)
		kr.push(Transform3D(Basis(Vector3.BACK, mid + PI * 0.5), c))
		kr.box(Vector3(seg_l, r1 - r0, RING_DEPTH), Color.WHITE)
		kr.pop()
	return kr.commit([_mat(WHITE, 1.0)])


func _build_meshes() -> void:
	_pip_meshes.clear()
	for r: float in PIP_RADII:
		_pip_meshes.append(_make_ring_mesh(r, RING_STROKE))
	_ring_mesh = _make_ring_mesh(AIM_RING_RADIUS, RING_STROKE)

	# Thin crossed X for blocked line-of-sight points.
	var kx := MeshKit.new()
	kx.shade = 0.0
	kx.push(Transform3D(Basis(Vector3.BACK, PI * 0.25), Vector3.ZERO))
	kx.box(Vector3(1.1, RING_STROKE * 1.5, RING_DEPTH), Color.WHITE)
	kx.pop()
	kx.push(Transform3D(Basis(Vector3.BACK, -PI * 0.25), Vector3.ZERO))
	kx.box(Vector3(1.1, RING_STROKE * 1.5, RING_DEPTH), Color.WHITE)
	kx.pop()
	_x_mesh = kx.commit([_mat(AMBER, 1.0)])
