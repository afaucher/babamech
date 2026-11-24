class_name CameraClearance
extends RefCounted
## Fits the chase camera's pivot to what the local mech carries, so nothing of the own mech sits on the crosshair
## (playtest: a missile pod on the right shoulder covered the screen centre). Pure geometry, no clock, no nodes kept:
##
##   var sil := CameraClearance.capture(model, mech_frame)   # the mounted meshes as triangles, in the mech's frame
##   var r := CameraClearance.fit(sil, CameraClearance.config_of(cam))
##   CameraClearance.extra_at(r, pitch, yaw_lag_deg)   # Vector2(extra shoulder m, extra height m) for ChaseCamera's pivot
##
## MEASURE: the mech frame is the body's facing frame (origin at the mech's feet, x = right, y = up, -z = forward). Every
## visible mesh of the model is read (get_faces) into it; the parts under the "Body" node are placed at the body's
## standing pose (hip height, no gait bob or lean), so the result does not depend on the frame it was taken in. Weapons
## (the `Weapon_<id>` node under each `HP_<id>`) are kept in their own frame and turned per sample the way WeaponMount
## turns them (toward the aim point, clamped to the catalog's pivot range; the mortar and equipment stay fixed), so a pod
## that tilts up when the camera looks up is checked tilted.
##
## CLEARANCE of one camera pose = the smallest distance, on screen, from the crosshair (screen centre) to any of those
## triangles, in units of screen height (0.07 = 7 % of the screen's height; independent of the aspect: the FOV is
## vertical). Triangles are projected exactly (a triangle stays a triangle under perspective); a bounding-sphere tree
## per part skips everything outside the cone around the view ray.
##
## WHAT MUST CLEAR: the mounted items (weapons / equipment) stay MARGIN away from the crosshair; the hull (body, head,
## mount hardware) is only kept no closer than it already is at the default offsets (capped at MARGIN): the bare
## Strider's empty right pylon already sits ~3 % of screen height from the crosshair today, and that is not changed.
##
## SAMPLES: a grid over the chase pitch range (pitch_min .. pitch_max in PITCH_STEP) and the body lagging the camera's
## yaw (YAW_LAG deg either way), each cell checked at normal and zoomed boom (ZOOMS). FIT (fit()): per cell, the shortest
## step along one direction in (shoulder, height) space (DIRS: right only .. up only; the direction with the shortest
## worst case wins for the loadout), dilated to the 3 x 3 neighbours and re-verified per cell at that length; ChaseCamera reads it bilinearly at its live pitch
## and yaw_error() (extra_at()). A loadout that already clears everywhere gets an all-0 grid: exactly (0, 0). Beyond
## +-45 deg of yaw lag the edge column is used (not checked).
##
## Presentation only (local, never streamed); no gameplay state, so no net_fields.

const MARGIN := 0.07                 ## least crosshair-to-mech distance, as a share of screen height
const PITCH_STEP := 0.1              ## rad between pitch samples
const YAW_LAG: Array[float] = [-45.0, -30.0, -15.0, 0.0, 15.0, 30.0, 45.0]   ## deg the body lags the camera's yaw (+ = camera looks right)
const ZOOMS: Array[float] = [0.0, 1.0]   ## zoom_amount samples (the boom and FOV lerp between them)
const AIM_DIST := 60.0               ## m along the view ray from the pivot where the weapons are aimed for the pose
const STEP := 0.1                    ## m between fit candidates
const MAX_EXTRA := 5.0               ## m: the most the pivot is moved
const DIRS: Array[float] = [0.0, 20.0, 45.0, 70.0, 90.0]   ## deg in (shoulder, height): 0 = only right, 90 = only up
const CAP := 0.25                    ## clearance reported when nothing is near the crosshair (screen heights)
const HULL_SLACK := 0.003             ## the hull may come this much closer than at the default offsets (sampling noise)
const NEAR := 0.05                   ## m: geometry closer to the camera than this counts as covering the view
const LEAF := 8                      ## triangles per tree leaf

const REST_META := &"weapon_pose_rest"   ## WeaponPose.REST_META (the weapon node's rest basis)


## The camera numbers the fit needs, from a ChaseCamera (or a Dictionary with the same keys).
static func config_of(cam: Variant) -> Dictionary:
	if cam is Dictionary:
		return cam
	return {"shoulder": cam.shoulder, "zoom_shoulder": cam.zoom_shoulder, "height": cam.height, "distance": cam.distance,
		"zoom_distance": cam.zoom_distance, "fov": cam.base_fov, "zoom_fov": cam.zoom_fov, "pitch_min": cam.pitch_min,
		"pitch_max": cam.pitch_max}


# --- Capture -----------------------------------------------------------------------------------------------------

## The model's visible meshes as triangles in the mech frame `frame` (world transform: origin at the feet, basis
## x = right, y = up, z = back). Returns {"parts": [...], "tris": total}. Each part: {"bvh", "xf"} (fixed: part-local to
## mech frame) or {"bvh", "hp", "rest", "lim", "pivots"} (a weapon: hp = HP node in the mech frame, rest = the weapon
## node's rest transform under it, lim = Vector3(yaw arc, pitch down, pitch up) deg).
static func capture(model: MechModel, frame: Transform3D) -> Dictionary:
	var inv := frame.affine_inverse()
	var body := model.get_node_or_null("Body") as Node3D
	# Parts under the body are taken at its standing pose (no bob / lean / landing dip).
	var body_fix := Transform3D.IDENTITY
	if body != null:
		var rest := Transform3D(Basis(), Vector3(0, model.hip_height() + 0.1 * float(model.params.get("body", 1.0)), 0))
		body_fix = model.global_transform * rest * body.global_transform.affine_inverse()
	var fixed := PackedVector3Array()
	var weapons := {}   # Weapon_ node -> PackedVector3Array (in its own frame)
	var meshes: Array[MeshInstance3D] = []
	_meshes(model, meshes)
	for mi in meshes:
		var faces := mi.mesh.get_faces()
		if faces.is_empty():
			continue
		var wn := _weapon_node(mi, model)
		var xf: Transform3D
		if wn != null:
			xf = wn.global_transform.affine_inverse() * mi.global_transform
			var have: PackedVector3Array = weapons.get(wn, PackedVector3Array())
			have.append_array(xf * faces)
			weapons[wn] = have   # packed arrays are values: store the grown copy back
		else:
			var under_body := body != null and body.is_ancestor_of(mi)
			xf = inv * (body_fix * mi.global_transform if under_body else mi.global_transform)
			fixed.append_array(xf * faces)
	var parts: Array = []
	var total := fixed.size() / 3
	if not fixed.is_empty():
		parts.append({"bvh": build(fixed), "xf": Transform3D.IDENTITY, "item": false})
	for wn: Node3D in weapons:
		var hp := wn.get_parent() as Node3D
		var hp_xf := inv * body_fix * hp.global_transform if body != null and body.is_ancestor_of(hp) else inv * hp.global_transform
		var rb: Basis = wn.get_meta(REST_META) if wn.has_meta(REST_META) else wn.basis
		var id := str(wn.name).trim_prefix("Weapon_")
		var st := MechCatalog.weapon(id)
		var pivots := not st.is_empty() and not MechCatalog.is_equipment(id) and str(st.get("kind", "")) != "arc"
		var lim := Vector3(float(st.get("yaw_arc", Combat.PIVOT_YAW)), float(st.get("pitch_down", Combat.PIVOT_PITCH_DOWN)),
			float(st.get("pitch_up", Combat.PIVOT_PITCH_UP)))
		var t: PackedVector3Array = weapons[wn]
		total += t.size() / 3
		parts.append({"bvh": build(t), "hp": hp_xf, "rest": Transform3D(rb, wn.position), "lim": lim, "pivots": pivots, "id": id, "item": true})
	return {"parts": parts, "tris": total}


static func _meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null and mi.is_visible_in_tree():
			out.append(mi)
	for c in n.get_children():
		_meshes(c, out)


## The `Weapon_<id>` node (child of an `HP_<id>` node) a mesh belongs to, or null.
static func _weapon_node(n: Node, stop: Node) -> Node3D:
	var p := n
	while p != null and p != stop:
		if str(p.name).begins_with("Weapon_") and p.get_parent() != null and str(p.get_parent().name).begins_with("HP_"):
			return p as Node3D
		p = p.get_parent()
	return null


## A bounding-sphere tree over flat triangles (a, b, c, a, b, c, ...): per node a sphere (c, r), children (l, rt; -1 for
## a leaf) and, for a leaf, a triangle range (s, n) into the reordered `t`.
class SphereTree:
	extends RefCounted
	var t := PackedVector3Array()
	var c := PackedVector3Array()
	var r := PackedFloat32Array()
	var l := PackedInt32Array()
	var rt := PackedInt32Array()
	var s := PackedInt32Array()
	var n := PackedInt32Array()
	var _src: PackedVector3Array
	var _cen: PackedVector3Array

	func node(ids: PackedInt32Array) -> int:
		var box := AABB(_src[ids[0] * 3], Vector3.ZERO)
		var cbox := AABB(_cen[ids[0]], Vector3.ZERO)
		for i in ids:
			box = box.expand(_src[i * 3]).expand(_src[i * 3 + 1]).expand(_src[i * 3 + 2])
			cbox = cbox.expand(_cen[i])
		var mid_p := box.get_center()
		var rr := 0.0
		for i in ids:
			for k in 3:
				rr = maxf(rr, mid_p.distance_squared_to(_src[i * 3 + k]))
		var me := c.size()
		c.append(mid_p)
		r.append(sqrt(rr))
		l.append(-1)
		rt.append(-1)
		s.append(0)
		n.append(0)
		if ids.size() <= LEAF:
			s[me] = t.size() / 3
			n[me] = ids.size()
			for i in ids:
				t.append(_src[i * 3])
				t.append(_src[i * 3 + 1])
				t.append(_src[i * 3 + 2])
			return me
		var ax := cbox.get_longest_axis_index()
		var mid := cbox.get_center()[ax]
		var a := PackedInt32Array()
		var b := PackedInt32Array()
		for i in ids:
			if _cen[i][ax] < mid:
				a.append(i)
			else:
				b.append(i)
		if a.is_empty() or b.is_empty():   # every centroid on one side (degenerate): split the list in half
			a = ids.slice(0, ids.size() / 2)
			b = ids.slice(ids.size() / 2)
		var left := node(a)
		var right := node(b)
		l[me] = left
		rt[me] = right
		return me


static func build(tris: PackedVector3Array) -> SphereTree:
	var tree := SphereTree.new()
	var cnt := tris.size() / 3
	var ids := PackedInt32Array()
	ids.resize(cnt)
	var cen := PackedVector3Array()
	cen.resize(cnt)
	for i in cnt:
		ids[i] = i
		cen[i] = (tris[i * 3] + tris[i * 3 + 1] + tris[i * 3 + 2]) / 3.0
	tree._src = tris
	tree._cen = cen
	if cnt > 0:
		tree.node(ids)
	tree._src = PackedVector3Array()
	tree._cen = PackedVector3Array()
	return tree


# --- Camera poses ------------------------------------------------------------------------------------------------

## The chase camera for one sample, in the mech frame: {"o": eye, "view", "right", "up", "tan": tan(fov / 2), "pivot"}.
## Mirrors ChaseCamera._process (no wall collision): pivot = up * height + right * shoulder (both + extra), the eye
## `distance` behind it along the pitched view. `yaw_lag` deg: + = the camera looks right of the body's facing.
static func pose(cfg: Dictionary, pitch: float, yaw_lag: float, zoom: float, extra: Vector2) -> Dictionary:
	var a := deg_to_rad(yaw_lag)
	var look := Vector3(sin(a), 0.0, -cos(a))
	var right := look.cross(Vector3.UP).normalized()
	var view := (look * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
	var sh := lerpf(float(cfg["shoulder"]), float(cfg["zoom_shoulder"]), zoom) + extra.x
	var dist := lerpf(float(cfg["distance"]), float(cfg["zoom_distance"]), zoom)
	var fov := lerpf(float(cfg["fov"]), float(cfg["zoom_fov"]), zoom)
	var pivot := Vector3.UP * (float(cfg["height"]) + extra.y) + right * sh
	var b := Basis.looking_at(view, Vector3.UP)
	return {"o": pivot - view * dist, "view": view, "right": b.x, "up": b.y, "tan": tan(deg_to_rad(fov) * 0.5), "pivot": pivot}


## Every sample of the fit: [pitch, yaw_lag, zoom] for the config's pitch range.
static func samples(cfg: Dictionary, zooms: Array[float] = ZOOMS, yaws: Array[float] = YAW_LAG) -> Array:
	var out: Array = []
	for z: float in zooms:
		for y: float in yaws:
			for p in pitches(cfg):
				out.append([p, y, z])
	return out


## The weapon part's transform (its frame to the mech frame) for a camera pose: turned toward the aim point
## (AIM_DIST along the view from the pivot), clamped to its pivot range, like WeaponMount + WeaponPose.
static func part_xf(part: Dictionary, cam: Dictionary) -> Transform3D:
	if part.has("xf"):
		return part["xf"]
	var hp: Transform3D = part["hp"]
	var rest: Transform3D = part["rest"]
	if not bool(part["pivots"]):
		return hp * rest
	var origin := hp * rest.origin
	var aim: Vector3 = (cam["pivot"] as Vector3) + (cam["view"] as Vector3) * AIM_DIST
	var d := (aim - origin).normalized()
	var lim: Vector3 = part["lim"]
	var yaw := clampf(rad_to_deg(atan2(d.x, -d.z)), -lim.x, lim.x)
	var pitch := clampf(rad_to_deg(asin(clampf(d.y, -1.0, 1.0))), -lim.y, lim.z)
	return hp * Transform3D(Basis.from_euler(Vector3(deg_to_rad(pitch), -deg_to_rad(yaw), 0.0)) * rest.basis, rest.origin)


# --- Clearance ---------------------------------------------------------------------------------------------------

## Clearance of one camera pose: Vector2(hull, items) in screen heights, each capped at `cap` (hull = the chassis'
## own meshes and mount hardware; items = the mounted weapons / equipment). Stops early once the items are below
## `stop_items` or the hull below `stop_hull` (the returned value is then only an upper bound).
static func pose_clearance(sil: Dictionary, cam: Dictionary, cap: float = CAP, stop_items: float = -1.0,
		stop_hull: float = -1.0) -> Vector2:
	var out := Vector2(cap, cap)
	for part: Dictionary in sil["parts"]:
		if bool(part.get("item", false)):
			out.y = _part_clearance(part["bvh"], part_xf(part, cam), cam, out.y, stop_items)
			if out.y < stop_items:
				return out
		else:
			out.x = _part_clearance(part["bvh"], part_xf(part, cam), cam, out.x, stop_hull)
			if out.x < stop_hull:
				return out
	return out


static func _part_clearance(tree: SphereTree, xf: Transform3D, cam: Dictionary, best: float, stop_below: float) -> float:
	var cs := tree.c
	if cs.is_empty():
		return best
	var inv := xf.affine_inverse()
	var k := inv.basis.x.length()   # local units per metre (uniform scale)
	var o: Vector3 = inv * (cam["o"] as Vector3)
	var view: Vector3 = (inv.basis * (cam["view"] as Vector3)).normalized()
	var rx: Vector3 = (inv.basis * (cam["right"] as Vector3)).normalized()
	var uy: Vector3 = (inv.basis * (cam["up"] as Vector3)).normalized()
	if inv.basis.determinant() < 0.0:
		rx = -rx   # a mirrored part: keep the screen axes right-handed (only distances matter, but stay tidy)
	var tanf: float = cam["tan"]
	var near := NEAR * k
	var rs := tree.r
	var ls := tree.l
	var rts := tree.rt
	var ss := tree.s
	var ns := tree.n
	var t := tree.t
	var stack := PackedInt32Array([0])
	while not stack.is_empty():
		var i := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		# Skip a sphere outside the cone (half-angle atan(2 best tan(fov/2))) round the view ray.
		var ta := 2.0 * best * tanf
		var ca := 1.0 / sqrt(1.0 + ta * ta)
		var v := cs[i] - o
		var d := v.dot(view)
		var lat := (v - view * d).length()
		if lat * ca - d * ta * ca > rs[i]:
			continue
		if ls[i] >= 0:
			stack.append(ls[i])
			stack.append(rts[i])
			continue
		for j in range(ss[i], ss[i] + ns[i]):
			var a := t[j * 3] - o
			var b := t[j * 3 + 1] - o
			var c := t[j * 3 + 2] - o
			var da := a.dot(view)
			var db := b.dot(view)
			var dc := c.dot(view)
			var behind := int(da < near) + int(db < near) + int(dc < near)
			if behind == 3:
				continue
			var s := 0.0
			if behind == 0:
				var pa := Vector2(a.dot(rx) / da, a.dot(uy) / da)
				var pb := Vector2(b.dot(rx) / db, b.dot(uy) / db)
				var pc := Vector2(c.dot(rx) / dc, c.dot(uy) / dc)
				s = _origin_to_tri(pa, pb, pc) / (2.0 * tanf)
			if s < best:
				best = s
				if best < stop_below:
					return best
	return best


## Distance from (0, 0) to a 2D triangle (0 inside).
static func _origin_to_tri(a: Vector2, b: Vector2, c: Vector2) -> float:
	var s1 := a.cross(b)
	var s2 := b.cross(c)
	var s3 := c.cross(a)
	if (s1 >= 0.0 and s2 >= 0.0 and s3 >= 0.0) or (s1 <= 0.0 and s2 <= 0.0 and s3 <= 0.0):
		return 0.0
	return minf(_origin_to_seg(a, b), minf(_origin_to_seg(b, c), _origin_to_seg(c, a)))


static func _origin_to_seg(a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var u := clampf(-a.dot(ab) / l2, 0.0, 1.0) if l2 > 1e-12 else 0.0
	return (a + ab * u).length()


## The worst samples for an offset (cap CAP): {"items", "items_at", "hull", "hull_at"} (clearances in screen heights,
## *_at = [pitch, yaw_lag, zoom]). `extra`: a constant Vector2 or a fit() result (the offset at each sample's pitch).
static func measure(sil: Dictionary, cfg: Dictionary, extra: Variant, smp: Array = []) -> Dictionary:
	if smp.is_empty():
		smp = samples(cfg)
	var out := {"items": CAP, "items_at": [], "hull": CAP, "hull_at": []}
	for s: Array in smp:
		var x: Vector2 = extra if extra is Vector2 else extra_at(extra, float(s[0]), float(s[1]))
		var c := pose_clearance(sil, pose(cfg, float(s[0]), float(s[1]), float(s[2]), x))
		if c.y < float(out["items"]):
			out["items"] = c.y
			out["items_at"] = s
		if c.x < float(out["hull"]):
			out["hull"] = c.x
			out["hull_at"] = s
	return out


## The pitch samples (rad): pitch_min .. pitch_max in PITCH_STEP, both ends included.
static func pitches(cfg: Dictionary) -> PackedFloat32Array:
	var p0 := float(cfg.get("pitch_min", -1.0))
	var p1 := float(cfg.get("pitch_max", 0.55))
	var n := int(ceil((p1 - p0) / PITCH_STEP - 0.001))
	var out := PackedFloat32Array()
	for i in n + 1:
		out.append(minf(p0 + PITCH_STEP * i, p1))
	return out


## The pivot offset a fit() result gives at `pitch` (rad) with the body lagging the camera's yaw by `yaw_lag` deg (+ =
## the camera looks right of the body; clamped to the fitted range): its direction times the length grid, bilinear.
static func extra_at(f: Dictionary, pitch: float, yaw_lag: float = 0.0) -> Vector2:
	var ps: PackedFloat32Array = f.get("pitches", PackedFloat32Array())
	var ys: PackedFloat32Array = f.get("yaws", PackedFloat32Array())
	var ls: PackedFloat32Array = f.get("len", PackedFloat32Array())
	if ps.is_empty() or ys.is_empty() or ls.size() != ps.size() * ys.size():
		return Vector2.ZERO
	var pi := _cell(ps, pitch)
	var yi := _cell(ys, yaw_lag)
	var ny := ys.size()
	var i0 := int(pi.x)
	var j0 := int(yi.x)
	var i1 := mini(i0 + 1, ps.size() - 1)
	var j1 := mini(j0 + 1, ny - 1)
	var l0 := lerpf(ls[i0 * ny + j0], ls[i0 * ny + j1], yi.y)
	var l1 := lerpf(ls[i1 * ny + j0], ls[i1 * ny + j1], yi.y)
	return (f["dir"] as Vector2) * lerpf(l0, l1, pi.y)


## Vector2(lower sample index, blend 0..1 to the next) for `v` in the ascending samples `xs` (clamped at the ends).
static func _cell(xs: PackedFloat32Array, v: float) -> Vector2:
	if v <= xs[0] or xs.size() == 1:
		return Vector2(0, 0)
	for i in range(1, xs.size()):
		if v <= xs[i]:
			return Vector2(i - 1, (v - xs[i - 1]) / maxf(xs[i] - xs[i - 1], 1e-6))
	return Vector2(xs.size() - 1, 0)


## True when `extra` clears every sample in `smp` (the items by `margin`, the hull no lower than `floor_h` minus
## HULL_SLACK). `order` (indices into smp) is reordered move-to-front: the next candidate tries the last failure first.
static func clears(sil: Dictionary, cfg: Dictionary, extra: Vector2, smp: Array, floor_h: PackedFloat32Array,
		margin: float, order: PackedInt32Array) -> bool:
	for oi in order.size():
		var si := order[oi]
		var s: Array = smp[si]
		var need_h := floor_h[si] - HULL_SLACK
		var c := pose_clearance(sil, pose(cfg, float(s[0]), float(s[1]), float(s[2]), extra), margin, margin, need_h)
		if c.y < margin or c.x < need_h:
			if oi > 0:
				order.remove_at(oi)
				order.insert(0, si)
			return false
	return true


## Fit the pivot offset to the silhouette: {"dir": Vector2 (unit, in (shoulder, height)), "pitches" (rad), "yaws"
## (deg of body yaw lag), "len" (m along dir per [pitch][yaw] cell, flat: i * yaws.size() + j), "max": longest, "solved":
## every cell cleared within MAX_EXTRA, "evals"}. Per cell, the shortest length along each direction of DIRS that clears
## both zoom samples there: the items by `margin`, the hull no worse than at the default offsets (capped at `margin`:
## what the bare chassis shows today is not the loadout's doing and stays as it is). The direction with the shortest
## worst length wins (one direction per loadout, so the camera slides along one line); each length is then raised to the
## largest of its neighbours (3 x 3) so the grid, bilinear in between, keeps clear between samples, and every cell is
## re-checked at that final length (clearance is not monotonic in the offset: a part can cross the crosshair on the way
## out, as on the taller Bulwark), a failing cell raised to the next length that clears, until the grid holds (_repair);
## if that makes the winner's grid longer, the other directions are compared on their repaired grids. A loadout that
## clears everywhere at the default offsets gets an all-0 grid (extra_at = exactly (0, 0)).
static func fit(sil: Dictionary, cfg: Dictionary, margin: float = MARGIN) -> Dictionary:
	var ps := pitches(cfg)
	var ys := PackedFloat32Array(YAW_LAG)
	var ny := ys.size()
	var cells: Array = []   # per cell: [samples, hull floor, order]
	var zero_ok: Array[bool] = []
	var evals := 0
	for p in ps:
		for y in ys:
			var smp: Array = []
			var floor_h := PackedFloat32Array()
			var order := PackedInt32Array()
			for z: float in ZOOMS:
				smp.append([p, y, z])
				floor_h.append(pose_clearance(sil, pose(cfg, p, y, z, Vector2.ZERO), margin).x)
				order.append(order.size())
			cells.append([smp, floor_h, order])
			evals += 1
			zero_ok.append(clears(sil, cfg, Vector2.ZERO, smp, floor_h, margin, order))
	var zeros := PackedFloat32Array()
	zeros.resize(cells.size())
	var out := {"dir": Vector2.RIGHT, "pitches": ps, "yaws": ys, "len": zeros, "max": 0.0, "solved": true, "evals": evals}
	if not zero_ok.has(false):
		return out
	# Pass 1: per direction, the per-cell minimum lengths; a direction whose worst cell already needs more than the
	# best solved one is dropped early.
	var raws: Array = []   # per DIRS index: {"lens", "max", "solved"} or null (dropped)
	var best := -1
	for d in DIRS.size():
		var bound: float = float(raws[best]["max"]) if best >= 0 and bool(raws[best]["solved"]) else INF
		var r := _fit_dir(sil, cfg, margin, cells, zero_ok, _dir_of(d), bound)
		evals += int(r["evals"])
		raws.append(r if not bool(r["beaten"]) else null)
		if r["beaten"]:
			continue
		if best < 0 or _better(r, raws[best]):
			best = d
	# Pass 2: dilate and repair the winner. Dilation assumes clearance only improves as the pivot moves out; it does
	# not always (a part can cross the crosshair on the way), so every cell is re-checked at its final length.
	var fin := _repair(sil, cfg, margin, cells, ps.size(), ny, raws[best]["lens"], _dir_of(best))
	evals += int(fin["evals"])
	fin["solved"] = bool(fin["solved"]) and bool(raws[best]["solved"])
	if float(fin["max"]) > float(raws[best]["max"]) + 0.0001:
		# The repair made the winner's grid longer: weigh every direction by its repaired grid instead. Directions
		# dropped (or longer than the winner) on their minimum lengths are searched / repaired against the new bound.
		var best_fin := fin
		var best_d := best
		for d in DIRS.size():
			if d == best:
				continue
			var r: Variant = raws[d]
			var bound: float = float(best_fin["max"]) if bool(best_fin["solved"]) else INF
			if r == null:
				r = _fit_dir(sil, cfg, margin, cells, zero_ok, _dir_of(d), bound)
				evals += int(r["evals"])
				if r["beaten"]:
					continue
			if bool(best_fin["solved"]) and float(r["max"]) > bound + 0.0001:
				continue
			var f2 := _repair(sil, cfg, margin, cells, ps.size(), ny, r["lens"], _dir_of(d))
			evals += int(f2["evals"])
			f2["solved"] = bool(f2["solved"]) and bool(r["solved"])
			if _better(f2, best_fin) or (d < best_d and not _better(best_fin, f2)):
				best_fin = f2
				best_d = d
		fin = best_fin
		best = best_d
	out["dir"] = _dir_of(best)
	out["len"] = fin["len"]
	out["max"] = fin["max"]
	out["solved"] = fin["solved"]
	out["evals"] = evals
	return out


static func _dir_of(d: int) -> Vector2:
	return Vector2(cos(deg_to_rad(DIRS[d])), sin(deg_to_rad(DIRS[d])))


## Fit result a beats b: solved first, then the shorter worst length.
static func _better(a: Dictionary, b: Dictionary) -> bool:
	return (bool(a["solved"]) and not bool(b["solved"])) or (bool(a["solved"]) == bool(b["solved"]) \
		and float(a["max"]) < float(b["max"]) - 0.0001)


## Per cell, the shortest length (in STEPs) along `dir` that clears the cell's samples. Gives up ("beaten") once a cell
## needs more than `bound`. {"lens", "max", "solved", "beaten", "evals"}.
static func _fit_dir(sil: Dictionary, cfg: Dictionary, margin: float, cells: Array, zero_ok: Array[bool], dir: Vector2,
		bound: float) -> Dictionary:
	var n := int(round(MAX_EXTRA / STEP))
	var lens := PackedFloat32Array()
	var mx := 0.0
	var solved := true
	var beaten := false
	var prev := 0
	var evals := 0
	for k in cells.size():
		var ln := 0.0
		if not zero_ok[k]:
			# Warm start from the last cell's length (neighbours need about the same): walk down while it still
			# clears, else up until it does.
			var i := maxi(prev, 1)
			if STEP * i > bound + 0.0001:
				beaten = true   # this direction already needs more than the best one: stop
				break
			evals += 1
			if clears(sil, cfg, dir * (STEP * i), cells[k][0], cells[k][1], margin, cells[k][2]):
				while i > 1:
					evals += 1
					if not clears(sil, cfg, dir * (STEP * (i - 1)), cells[k][0], cells[k][1], margin, cells[k][2]):
						break
					i -= 1
				ln = STEP * i
			else:
				ln = -1.0
				while i < n:
					i += 1
					if STEP * i > bound + 0.0001:
						beaten = true
						break
					evals += 1
					if clears(sil, cfg, dir * (STEP * i), cells[k][0], cells[k][1], margin, cells[k][2]):
						ln = STEP * i
						break
				if beaten:
					break
				if ln < 0.0:
					ln = MAX_EXTRA
					solved = false
			prev = int(round(ln / STEP))
		lens.append(ln)
		mx = maxf(mx, ln)
	return {"lens": lens, "max": mx, "solved": solved, "beaten": beaten, "evals": evals}


## Dilate the per-cell minimum lengths `raw` to their 3 x 3 neighbours (so the bilinear grid keeps clear between
## samples), then make it true: every cell is checked at its final (stored) length; one that fails is raised to the
## next STEP above that clears (never below its minimum), and the grid is dilated and checked again until nothing
## changes. {"len" (final grid), "max", "solved" (every cell verified within MAX_EXTRA), "evals"}.
static func _repair(sil: Dictionary, cfg: Dictionary, margin: float, cells: Array, np: int, ny: int,
		raw: PackedFloat32Array, dir: Vector2) -> Dictionary:
	var base := raw.duplicate()
	var n := int(round(MAX_EXTRA / STEP))
	var verified := PackedFloat32Array()   # the stored length each cell was last verified at (-1 = not yet)
	verified.resize(cells.size())
	verified.fill(-1.0)
	var stuck := PackedByteArray()   # cells with no clearing length within MAX_EXTRA
	stuck.resize(cells.size())
	var solved := true
	var evals := 0
	var dil := PackedFloat32Array()
	for _round in 64:   # each round raises at least one cell by >= STEP, so this is far more than ever needed
		dil = _dilate(base, np, ny)
		var changed := false
		for k in cells.size():
			var v := dil[k]   # the value extra_at reads (float32, snapped)
			if v == verified[k] or stuck[k] != 0:
				continue
			evals += 1
			if clears(sil, cfg, dir * v, cells[k][0], cells[k][1], margin, cells[k][2]):
				verified[k] = v
				continue
			# Next clearing length above v. The stored value of a candidate (snapped, float32) must clear too, and
			# must not drop below v.
			var i := int(floor(v / STEP + 0.0001)) + 1
			var found := -1.0
			while i <= n:
				var c := _stored(STEP * i)
				if c > v:
					evals += 1
					if clears(sil, cfg, dir * c, cells[k][0], cells[k][1], margin, cells[k][2]):
						found = c
						break
				i += 1
			if found < 0.0:
				stuck[k] = 1
				solved = false
				base[k] = maxf(base[k], MAX_EXTRA)
			else:
				base[k] = found
				verified[k] = found
			changed = true
		if not changed:
			break
		if _round == 63:
			solved = false
	var mx := 0.0
	for v in dil:
		mx = maxf(mx, v)
	return {"len": dil, "max": mx, "solved": solved, "evals": evals}


## The 3 x 3 neighbourhood max of `lens` (np x ny cells), snapped to mm and stored as float32.
static func _dilate(lens: PackedFloat32Array, np: int, ny: int) -> PackedFloat32Array:
	var dil := PackedFloat32Array()
	for i in np:
		for j in ny:
			var v := 0.0
			for di in range(maxi(i - 1, 0), mini(i + 2, np)):
				for dj in range(maxi(j - 1, 0), mini(j + 2, ny)):
					v = maxf(v, lens[di * ny + dj])
			dil.append(_stored(v))
	return dil


## `v` as the grid stores it: snapped to mm, then float32 (never below v by more than float32 rounding).
static func _stored(v: float) -> float:
	var a := PackedFloat32Array([snappedf(v, 0.001)])
	return a[0]
