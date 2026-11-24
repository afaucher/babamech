extends Node
## Repair-drone "spread scanner" beam render probe (art direction, NOT game code: scripts/combat/repair_drone.gd is
## untouched). Builds a seeded city district under the real light rig (CityDistrict + CityLightRig "day", GraphicsQuality
## HIGH), stands a player mech (MechModel, scale 2, ~8 m) at a street intersection, hovers the real flying drone mesh
## (MechMeshes part weapon_repair_drone_flying, accent tinted, FLY_SCALE 2.1) 6 m above the mech's back and 5 m out to its
## front-right, and draws one beam variant per shot from the drone's lens onto the mech (it repairs its own launcher).
## Cells (rows = shape, columns = treatment): see README.md. "current" = the game's thin beam, for comparison.
## Run in a real renderer on the hidden desktop: tools/scanner_beam/run_scanner_beam.ps1 (takes the GPU lock).
##
## User args (after `--`):
##   --cells A1,B3     cells to render (default: current + all nine)
##   --cams gameplay,close
##   --strip 1         also a 3-frame close strip of every sweep cell (A3/B3/C3): <cell>_close_f<0..2>.png
##   --phase 0.3       sweep position of the main shot (-1..1; default 0.3)
##   --seed 7          city seed
##   --out <dir>       output dir (default res://tools/scanner_beam/shots); files <cell>_<cam>.png
## Prints "[sbeam]" lines and quits.

const CELLS := ["current", "A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3"]
const SWEEPS := ["A3", "B3", "C3"]
const STRIP := [-0.8, 0.0, 0.8]
const MECH_SCALE := 2.0
const FLY_SCALE := 2.1                ## RepairDrone.FLY_SCALE
const GREEN := Color(0.25, 1.0, 0.45) ## RepairDrone.GREEN
const CORE := Color(0.62, 1.0, 0.72)  ## hot core of the brightest lines (GREEN lightened)
const RING_GREEN := Color(0.10, 0.38, 0.17)
const HOVER := 6.0                    ## m above the back mount
const ORBIT := 5.0                    ## m out from the launcher's up axis
const PLAY_MECH := Vector2(8.0, -20.0)   ## mech arc offset from the intersection (left lane, short of it), facing +s
## The drone's spot on its orbit, arc offset from the mech: front-right (arc -x is the mech's right when it faces +s).
const DRONE_DIR := Vector2(-0.72, 0.69)
const SETTLE := 14

## Cameras, arc offsets (dx, ds, h) from the mech base.
const CAMS := {
	# The game's ChaseCamera (distance 16, pivot 9.5, right shoulder 3.2, pitch -0.18, fov 70) behind the mech.
	"gameplay": {"eye": Vector3(-3.2, -15.5, 12.0), "target": Vector3(-3.2, 20.0, 5.6), "fov": 70.0},
	# 3/4 from the mech's right front: drone, beam and mech all in frame.
	"close": {"eye": Vector3(-20.0, 9.0, 9.5), "target": Vector3(-2.2, 2.2, 8.6), "fov": 58.0},
}

var _args: PackedStringArray
var _district: CityDistrict
var _cam: Camera3D
var _mech: MechModel
var _drone: MeshInstance3D
var _ground_ring: MeshInstance3D
var _vol: MeshInstance3D         ## translucent volumes
var _lines: MeshInstance3D       ## bright lines (drawn after the volumes)
var _centre := Vector2.ZERO
var _mat_vol: StandardMaterial3D
var _mat_line: StandardMaterial3D

# Frame of the shot (world space), filled by _setup_frame.
var M := Vector3.ZERO      ## mech base
var U := Vector3.UP        ## up
var F := Vector3.FORWARD   ## horizontal, drone -> mech
var S := Vector3.RIGHT     ## horizontal, across F
var H := 8.0               ## mech height
var RB := 2.0              ## body radius (torso)
var L := Vector3.ZERO      ## the drone's lens

var _st_vol: SurfaceTool
var _st_line: SurfaceTool


func _ready() -> void:
	_run.call_deferred()


func _say(s: String) -> void:
	print("[sbeam] " + s)


func _arg(key: String, def: String) -> String:
	var v := Boot.arg_value(_args, key)
	return v if v != "" else def


func _run() -> void:
	_args = OS.get_cmdline_user_args()
	GraphicsQuality.apply_viewport(get_tree().root, CityQuality.HIGH)
	var out_dir := _arg("--out", "res://tools/scanner_beam/shots")
	if out_dir.begins_with("res://") or out_dir.begins_with("user://"):
		out_dir = ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var cells := _arg("--cells", ",".join(CELLS)).split(",", false)
	var cams := _arg("--cams", "gameplay,close").split(",", false)
	var phase := float(_arg("--phase", "0.3"))
	_build_city(int(_arg("--seed", "7")))
	_build_scene()
	_cam = Camera3D.new()
	_cam.far = 1200.0
	add_child(_cam)
	_cam.make_current()
	for i in 40:
		await get_tree().process_frame
	_setup_frame()
	for cam_id: String in cams:
		_place_camera(CAMS[cam_id])
		for c: String in cells:
			_draw_cell(c, phase)
			await _shot("%s_%s" % [c, cam_id], out_dir)
	if _arg("--strip", "1") != "0":
		_place_camera(CAMS["close"])
		for c: String in cells:
			if not c in SWEEPS:
				continue
			for f in STRIP.size():
				_draw_cell(c, STRIP[f])
				await _shot("%s_close_f%d" % [c, f], out_dir)
	_say("done")
	get_tree().quit()


func _shot(name: String, out_dir: String) -> void:
	for i in SETTLE:
		await get_tree().process_frame
	if DisplayServer.get_name() == "headless":     # nothing draws: a smoke run only checks the script
		_say("headless: skipped %s" % name)
		return
	await RenderingServer.frame_post_draw
	var img := get_tree().root.get_texture().get_image()
	var path := out_dir.path_join(name + ".png")
	if img != null:
		img.save_png(path)
		_say("saved %s" % path)
	else:
		_say("ERROR no image for %s" % path)


# --- Scene -------------------------------------------------------------------------------------------------

func _build_city(seed: int) -> void:
	_district = CityDistrict.new()
	_district.name = "District"
	add_child(_district)
	_district.build({"seed": seed, "walls": 1.0})
	_district.set_ceiling_visible(true)
	_district.set_backdrop_visible(true)
	if _district.rig != null:
		_district.rig.apply("day")
		_district.rig.set_quality(CityQuality.HIGH)
	var plan := _district.plan
	var av := plan.avenue_x()
	var best_s := 0.0
	var best_d := INF
	var mid_s := plan.extent.get_center().y
	for r: Dictionary in plan.roads_s:
		if str(r.get("kind", "")) == "perimeter":
			continue
		var s := (float(r["a"]) + float(r["b"])) * 0.5
		if absf(s - mid_s) < best_d:
			best_d = absf(s - mid_s)
			best_s = s
	_centre = Vector2((av.x + av.y) * 0.5, best_s)
	_say("city seed %d checksum %s, intersection at x %.1f s %.1f" % [seed, plan.checksum(), _centre.x, _centre.y])


func _arc_xf(x: float, s: float, h: float, yaw: float) -> Transform3D:
	var ring := _district.ring
	var base_b := ring.basis_at_arc(s)
	return Transform3D(Basis(base_b.y, yaw) * base_b, ring.arc_to_world(x, s, h))


func _arc(d: Vector3) -> Vector3:
	return _district.ring.arc_to_world(_centre.x + PLAY_MECH.x + d.x, _centre.y + PLAY_MECH.y + d.y, d.z)


func _build_scene() -> void:
	_mech = MechModel.new()
	_mech.name = "PlayerMech"
	add_child(_mech)
	_mech.configure("chicken", "strider", {})
	_mech.transform = _arc_xf(_centre.x + PLAY_MECH.x, _centre.y + PLAY_MECH.y, 0.0, 0.0).scaled_local(Vector3.ONE * MECH_SCALE)
	_drone = MeshInstance3D.new()
	_drone.name = "weapon_repair_drone_flying"
	_drone.mesh = MechMeshes.mesh("weapon_repair_drone_flying")
	add_child(_drone)
	MechMeshes.apply_accent(_drone, _mech.accent)
	_ground_ring = CombatMeshes.instance(CombatMeshes.ring(RING_GREEN, 0.985, 48))
	add_child(_ground_ring)
	_mat_vol = _material(0)
	_mat_line = _material(1)
	_vol = MeshInstance3D.new()
	_vol.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_vol)
	_lines = MeshInstance3D.new()
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)


func _material(prio: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = prio
	return m


## Mech size from its meshes, the drone's spot, the world frame of the shot.
func _setup_frame() -> void:
	M = _arc(Vector3.ZERO)
	U = _district.ring.up_at(M)
	# Height along U and the torso's horizontal radius from the real vertices (transformed AABBs overstate both).
	var hi := 0.0
	var rad := 0.0
	var pts: Array[Vector3] = []
	for mi: MeshInstance3D in _mesh_instances(_mech):
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var xf := mi.global_transform
		for si in mi.mesh.get_surface_count():
			var v: PackedVector3Array = mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			for k in range(0, v.size(), 3):
				var w := xf * v[k] - M
				pts.append(w)
				hi = maxf(hi, w.dot(U))
	H = hi if hi > 2.0 else 8.0
	for w in pts:       # torso band: 55-80 % of the height
		var h := w.dot(U)
		if h > H * 0.55 and h < H * 0.8:
			rad = maxf(rad, (w - U * h).length())
	RB = clampf(rad * 0.8, 1.3, 2.6)
	var mount_h := H * 0.72
	var dpos := _arc(Vector3(DRONE_DIR.x * ORBIT, DRONE_DIR.y * ORBIT, mount_h + HOVER))
	var fwd := (M - dpos)
	fwd -= U * fwd.dot(U)
	F = fwd.normalized()
	S = U.cross(F).normalized()
	_drone.global_transform = Transform3D(Basis.looking_at(-S, U).scaled(Vector3.ONE * FLY_SCALE), dpos)
	L = dpos - U * 0.3
	_ground_ring.global_transform = Transform3D(Basis(S, U, F).scaled(Vector3(15.0, 1.0, 15.0)), M + U * 0.08)
	_say("mech height %.2f m, body radius %.2f m, drone %.1f m up, %.1f m out" % [H, RB, mount_h + HOVER, ORBIT])


func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_mesh_instances(c))
	return out


func _place_camera(cam: Dictionary) -> void:
	var p := _arc(cam["eye"])
	var q := _arc(cam["target"])
	_cam.fov = float(cam["fov"])
	_cam.global_transform = Transform3D(Basis.looking_at(q - p, _district.ring.up_at(p)), p)
	_cam.make_current()


# --- Geometry helpers --------------------------------------------------------------------------------------

func _c(a: float, col: Color = GREEN) -> Color:
	return Color(col.r, col.g, col.b, a)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	st.set_color(ca)
	st.add_vertex(a)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_color(cc)
	st.add_vertex(c)


## Quad a-b-c-d (in order around), colours per corner.
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	_tri(st, a, b, c, ca, cb, cc)
	_tri(st, a, c, d, ca, cc, cd)


## A thin square-section bar from a to b, `w` m across (an effect line: reads the same from any side).
func _line(a: Vector3, b: Vector3, w: float, col: Color, col_b: Variant = null) -> void:
	var cb: Color = col if col_b == null else col_b
	var d := b - a
	if d.length() < 1e-4:
		return
	var dn := d.normalized()
	var p := dn.cross(U if absf(dn.dot(U)) < 0.95 else S).normalized() * w * 0.5
	var q := dn.cross(p).normalized() * w * 0.5
	var ofs := [p + q, p - q, -p - q, -p + q]
	for i in 4:
		var o1: Vector3 = ofs[i]
		var o2: Vector3 = ofs[(i + 1) % 4]
		_quad(_st_line, a + o1, a + o2, b + o2, b + o1, col, col, cb, cb)


## Points of a horizontal polygon ring around `c` (radius r, n sides), starting toward the drone (-F).
func _ring_pts(c: Vector3, r: float, n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + (-F * cos(a) + S * sin(a)) * r)
	return out


func _ring_line(c: Vector3, r: float, n: int, w: float, col: Color) -> void:
	var pts := _ring_pts(c, r, n)
	for i in n:
		_line(pts[i], pts[(i + 1) % n], w, col)


## A point on the mech's drone-facing surface at height h, offset x across.
func _front(h: float, x: float = 0.0, out: float = 0.0) -> Vector3:
	return M + U * h - F * (RB * 0.8 + out) + S * x


# --- Cells -------------------------------------------------------------------------------------------------

func _draw_cell(cell: String, p: float) -> void:
	_st_vol = SurfaceTool.new()
	_st_vol.begin(Mesh.PRIMITIVE_TRIANGLES)
	_st_line = SurfaceTool.new()
	_st_line.begin(Mesh.PRIMITIVE_TRIANGLES)
	match cell:
		"current": _current()
		"A1": _fan(1, p)
		"A2": _fan(2, p)
		"A3": _fan(3, p)
		"B1": _cone(1, p)
		"B2": _cone(2, p)
		"B3": _cone(3, p)
		"C1": _scan(1, p)
		"C2": _scan(2, p)
		"C3": _scan(3, p)
	_vol.mesh = _commit(_st_vol, _mat_vol)
	_lines.mesh = _commit(_st_line, _mat_line)


func _commit(st: SurfaceTool, mat: Material) -> ArrayMesh:
	var m := st.commit()
	if m != null and m.get_surface_count() > 0:
		m.surface_set_material(0, mat)
	return m


## The game's look today: a 0.06 m unshaded prism from just under the drone to the mech's chest.
func _current() -> void:
	_line(L, M + U * H * 0.6, 0.06, _c(1.0))


## Row A, the flat FAN: a triangular sheet from the lens onto a line across the mech's front.
func _fan(t: int, p: float) -> void:
	var hc := H * 0.62
	var w := RB + 0.9
	if t == 3:
		# A vertical blade (knees to head) panning side to side across the body.
		var x := p * (RB + 1.3)
		var lo := _front(H * 0.22, x)
		var hi := _front(H * 0.98, x)
		var on := absf(x) < RB * 0.95
		_tri(_st_vol, L, lo, hi, _c(0.05), _c(0.20), _c(0.20))
		# Where it has just been: a faint swept band trailing behind the blade on the body's front.
		var dir := 1.0 if p >= 0.0 else -1.0
		var tx := x - dir * 1.1
		_quad(_st_vol, _front(H * 0.22, tx), lo, hi, _front(H * 0.98, tx), _c(0.0), _c(0.16), _c(0.16), _c(0.0))
		_line(lo, hi, 0.12 if on else 0.07, _c(1.0 if on else 0.5, CORE if on else GREEN))
		_line(L, lo, 0.035, _c(0.30))
		_line(L, hi, 0.035, _c(0.30))
		return
	var a := _front(hc, -w)
	var b := _front(hc, w)
	if t == 1:
		_tri(_st_vol, L, a, b, _c(0.06), _c(0.24), _c(0.24))
		# A second, narrower brighter core sheet down the middle.
		_tri(_st_vol, L, _front(hc, -w * 0.45), _front(hc, w * 0.45), _c(0.03), _c(0.12), _c(0.12))
		_line(a, b, 0.11, _c(1.0, CORE))
		_line(L, a, 0.04, _c(0.15), _c(0.45))
		_line(L, b, 0.04, _c(0.15), _c(0.45))
	else:
		_tri(_st_vol, L, a, b, _c(0.015), _c(0.05), _c(0.05))
		_line(a, b, 0.09, _c(0.95, CORE))
		_line(L, a, 0.06, _c(0.85))
		_line(L, b, 0.06, _c(0.85))
		for i in range(1, 6):         # rays
			var k := float(i) / 6.0
			_line(L, a.lerp(b, k), 0.03, _c(0.08), _c(0.35))
		for k: float in [0.45, 0.72]:  # cross lines
			_line(L.lerp(a, k), L.lerp(b, k), 0.03, _c(0.35))
		for i in range(0, 13):        # barcode ticks along the leading edge
			var q := a.lerp(b, float(i) / 12.0)
			_line(q, q + U * (0.28 if i % 3 == 0 else 0.14), 0.035, _c(0.7))


## Row B, the CONE: an octagonal frustum from the lens onto the mech, a bright footprint where it lands.
func _cone(t: int, p: float) -> void:
	var n := 8
	var top := _ring_pts(L, 0.22, n)
	if t == 3:
		# A narrower spot whose footprint (a disc facing the drone, on the mech's front) slides across the body.
		var cen := _front(H * (0.62 - 0.12 * p), p * RB * 0.9, 0.35)
		var axis := (cen - L).normalized()
		var e1 := axis.cross(U).normalized()
		var e2 := axis.cross(e1).normalized()
		var r := 1.35
		var foot: Array[Vector3] = []
		for i in n:
			var a := TAU * float(i) / float(n)
			foot.append(cen + (e1 * cos(a) + e2 * sin(a)) * r)
		var lens: Array[Vector3] = []
		for i in n:
			var a := TAU * float(i) / float(n)
			lens.append(L + (e1 * cos(a) + e2 * sin(a)) * 0.2)
		for i in n:
			var j := (i + 1) % n
			_quad(_st_vol, lens[i], lens[j], foot[j], foot[i], _c(0.04), _c(0.04), _c(0.13), _c(0.13))
			_tri(_st_vol, cen, foot[i], foot[j], _c(0.38), _c(0.24), _c(0.24))
			_line(foot[i], foot[j], 0.09, _c(1.0, CORE))
		# A ghost of where the spot was (trailing), fainter.
		var dir := 1.0 if p >= 0.0 else -1.0
		var g := _front(H * (0.62 - 0.12 * (p - dir * 0.45)), (p - dir * 0.45) * RB * 0.9, 0.35)
		for i in n:
			var j := (i + 1) % n
			_line(g + (foot[i] - cen) * 0.9, g + (foot[j] - cen) * 0.9, 0.05, _c(0.30))
		return
	var hb := H * 0.5
	var rb := RB + 0.55
	var foot := _ring_pts(M + U * hb, rb, n)
	if t == 1:
		for i in n:
			var j := (i + 1) % n
			_quad(_st_vol, top[i], top[j], foot[j], foot[i], _c(0.03), _c(0.03), _c(0.14), _c(0.14))
		_ring_line(M + U * hb, rb, n, 0.11, _c(1.0, CORE))
		_ring_line(M + U * (hb + 0.35), rb * 0.98, n, 0.05, _c(0.35))
		# Footprint fill: a soft horizontal disc where it lands (cut by the body).
		for i in n:
			_tri(_st_vol, M + U * hb, foot[i], foot[(i + 1) % n], _c(0.10), _c(0.22), _c(0.22))
	else:
		for i in n:
			var j := (i + 1) % n
			_quad(_st_vol, top[i], top[j], foot[j], foot[i], _c(0.01), _c(0.01), _c(0.04), _c(0.04))
			_line(top[i], foot[i], 0.05, _c(0.25), _c(0.85))
		_ring_line(M + U * hb, rb, n, 0.10, _c(1.0, CORE))
		for k: float in [0.4, 0.7]:   # lattice rings up the cone
			var c := L.lerp(M + U * hb, k)
			_ring_line(c, lerpf(0.22, rb, k), n, 0.03, _c(0.35))
		_ring_line(L, 0.22, n, 0.04, _c(0.7))


## Row C, SCAN LINES: a few bright horizontal rings around the mech, joined to the drone by a faint thin frustum.
func _scan(t: int, p: float) -> void:
	var n := 12
	var rc := RB + 0.3
	var h0 := H * 0.5
	var heights: Array[float] = []
	var alphas: Array[float] = []
	if t == 3:
		# One bright line scanning up the full height, a fading trail below it.
		var h := H * (0.15 + 0.8 * (p + 1.0) * 0.5)
		var dir := 1.0       # moving up: trail below
		for k in 4:
			heights.append(h - dir * 0.38 * k)
			alphas.append([1.0, 0.5, 0.26, 0.12][k])
		var band := _ring_pts(M + U * (h - dir * 1.2), rc, n)
		var head := _ring_pts(M + U * h, rc, n)
		for i in n:
			var j := (i + 1) % n
			_quad(_st_vol, band[i], band[j], head[j], head[i], _c(0.0), _c(0.0), _c(0.16), _c(0.16))
	elif t == 1:
		heights = [h0 + 1.2, h0 + 0.8, h0 + 0.4]
		alphas = [1.0, 0.45, 0.3]
		var lo := _ring_pts(M + U * (h0 - 0.1), rc, n)
		var hi := _ring_pts(M + U * (h0 + 1.2), rc, n)
		for i in n:
			var j := (i + 1) % n
			_quad(_st_vol, lo[i], lo[j], hi[j], hi[i], _c(0.03), _c(0.03), _c(0.20), _c(0.20))
	else:
		heights = [h0 + 1.2, h0 + 0.8, h0 + 0.4, h0]
		alphas = [1.0, 0.75, 0.55, 0.4]
		var lo := _ring_pts(M + U * h0, rc, n)
		var hi := _ring_pts(M + U * (h0 + 1.2), rc, n)
		for i in n:                   # vertical lattice ticks
			_line(lo[i], hi[i], 0.03, _c(0.35))
	for k in heights.size():
		_ring_line(M + U * heights[k], rc, n, 0.10 if k == 0 else 0.06, _c(alphas[k], CORE if k == 0 else GREEN))
	# The faint thin frustum: from the lens to the drone-facing arc of the top ring.
	var top := _ring_pts(M + U * heights[0], rc, n)
	var arc: Array[Vector3] = [top[n - 2], top[n - 1], top[0], top[1], top[2]]
	if t == 2:
		_line(L, arc[0], 0.035, _c(0.4))
		_line(L, arc[4], 0.035, _c(0.4))
		_line(L, arc[2], 0.025, _c(0.2))
	else:
		for i in arc.size() - 1:
			_tri(_st_vol, L, arc[i], arc[i + 1], _c(0.02), _c(0.08), _c(0.08))
		_line(L, arc[0], 0.03, _c(0.08), _c(0.3))
		_line(L, arc[4], 0.03, _c(0.08), _c(0.3))
