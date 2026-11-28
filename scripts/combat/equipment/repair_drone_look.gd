class_name RepairDroneLook
extends RefCounted
## The repair drone's look (docs/design/back-equipment.md): COSMETIC, every machine, no messages. One per RepairDrone
## (`drone.look`); it draws into the drone's node (`host`: its children and transform) from the state the drone hands to
## `update(state)` each step, and never writes the drone's repair / flight state.
##
## LOOK: the Mech session's flying drone mesh (MechMeshes part `weapon_repair_drone_flying`, origin at its centre, facing
## -Z) in the launcher's accent colour (LowPolyMaterials.apply_accent, as MechModel tints its parts), FLY_SCALE x (about
## 1.6 m across the rotor guards); it leaves from the docked drone's spot on the back mount (HP_<hardpoint> x
## MechMeshes.DRONE_DOCK, EquipmentLook.dock) at the mount's size and grows to FLY_SCALE while it rises, then turns slowly
## toward where it travels (yaw only, YAW_FOLLOW s smoothing) and bobs a little. While it is out, the launcher's back
## mount shows the empty cradle (EquipmentLook, every machine). The placeholder MeshKit quad (spinning rotors) is the
## fallback when the part is missing. GREEN ONLY WHILE IT WORKS: a SCAN on every non-enemy target in range that is being
## repaired right now (RepairDrone.repairable: the drone's `beamed` list). No ground ring (removed 2026-11-26, R2.21: the
## scan on the repaired target is the only green). Nothing green during the rise, while idle (everyone full) or on the
## way home.
## THE SCAN (the user's pick, cell C3 of the render probe tools/scanner_beam/): one bright ring (CORE) round the target,
## level in the target's own up frame (CombatTarget.up), travelling up and down its body between SCAN_LO and SCAN_HI of
## its height once per SCAN_PERIOD s (eased at the turns), with three fainter trail rings where it was TRAIL_DT, 2x, 3x
## ago and a soft band fading back to where it was BAND_DT ago, joined to the drone's lens by a faint thin wedge (a
## fan onto the hot ring's drone-facing arc, two faint edge lines). Its height is a pure function of (clock - launch
## time) (scan_fraction): every machine draws the same scan, no RNG. Ring radius and height fit the target (scan_fit,
## cached per target: its MechModel's mesh bounds, so every chassis; else its hit spheres). Unshaded, alpha-blended,
## no shadows; cached meshes per radius bucket, only transforms change per frame; the nodes come from the world's mesh
## pool (CombatWorld.take_mesh) and go back when the drone leaves (give_back).
##
## update(state) keys (all read-only here): pos, up (the drone's), frame (its level frame), base (the launcher's
## position), now, dt, first (the first step), beamed (targets repaired this step), age, life, rise, home
## (0..1 of the flight home), dock ({pos, scale, basis} of the docked drone), launcher (its node, for the accent).

const GREEN := Color(0.25, 1.0, 0.45)
const BEAMS := 4                  ## scan sets kept (one per repaired target; a crew is at most 4)
## The scan look (user's pick: render probe tools/scanner_beam/, cell C3). Parts of one set, in order:
const SCAN_PARTS := ["head", "trail1", "trail2", "trail3", "band", "wedge", "edge", "edge"]
const CORE := Color(0.62, 1.0, 0.72)    ## the hot ring (GREEN lightened)
const SCAN_ALPHAS := [1.0, 0.5, 0.26, 0.12]   ## hot ring, then the trail rings
const HEAD_W := 0.10              ## m: hot ring bar width
const TRAIL_W := 0.06             ## m: trail ring bar width
const BAND_ALPHA := 0.16          ## the soft band's alpha at the hot ring (clear at its far edge)
const SCAN_SIDES := 12            ## ring polygon sides
const SCAN_PERIOD := 3.0          ## s: one trip up and back down
const SCAN_LO := 0.15             ## share of the target's height at the bottom of the scan ...
const SCAN_HI := 0.95             ## ... and at the top
const TRAIL_DT := 0.08            ## s: each trail ring is where the hot ring was this long before the previous one
const BAND_DT := 0.25             ## s: the band reaches back to where the hot ring was this long ago
const WEDGE_HALF := PI / 3.0      ## the wedge lands on the hot ring's arc +-60 deg either side of the drone
const EDGE_W := 0.03              ## m: the wedge's two edge lines
const RING_MIN := 1.0             ## m: ring radius clamp (before RING_PAD) ...
const RING_MAX := 3.4
const RING_PAD := 0.3             ## m outside the body
const RING_STEP := 0.1            ## m: ring radius buckets (one cached mesh set per bucket)
const DRONE_SCALE := 1.0          ## m: the placeholder drone is about 1.6 m across
const FLY_SCALE := 2.1            ## the flying mesh (~0.76 model units across the rotor guards) -> about 1.6 m
const YAW_FOLLOW := 0.25          ## s: smoothing of the turn toward the direction of travel (small: it faces along the orbit)
const YAW_MIN_SPEED := 0.4        ## m/s of horizontal travel below which it keeps its heading
const BOB := 0.15                 ## m of slow up-and-down while it circles (faded in on the rise, out on the way home)

## The MechMeshes equipment part drawn in flight (tests point it at a missing part to see the fallback).
static var flying_id := "repair_drone_flying"
static var _scan_meshes: Dictionary = {}    ## cached scan meshes by part + ring radius bucket (cosmetic)
static var _scan_mats: Array = []           ## [volume material, line material]

var host: Node3D                  ## the drone's node: the look's children and transform live on it
var world: CombatWorld
var shooter := ""
var t0 := 0.0                     ## launch time on the clock (scan_fraction)
var flying_mesh := false          ## drawn with the Mech session's flying mesh (false: the placeholder)
var yaw := 0.0                    ## heading about up in the drone's frame (rad; 0 = the frame's -Z)
var _body: MeshInstance3D
var _rotors: Array = []
var _beams: Array = []            ## BEAMS scan sets: each an Array of SCAN_PARTS.size() MeshInstance3D
var _fit: Dictionary = {}         ## target instance id -> scan_fit {h, r} (cached once)
var _borrowed := false            ## scan nodes came from world.take_mesh (handed back in give_back)
var _prev_pos := Vector3.ZERO


func net_fields() -> Dictionary:
	return {"host": Net.LOCAL, "world": Net.LOCAL, "shooter": Net.LOCAL, "t0": Net.LOCAL, "flying_mesh": Net.LOCAL,
		"yaw": Net.LOCAL, "_body": Net.LOCAL, "_rotors": Net.LOCAL, "_beams": Net.LOCAL,
		"_fit": Net.LOCAL, "_borrowed": Net.LOCAL, "_prev_pos": Net.LOCAL}


func setup(h: Node3D, w: CombatWorld, s: String, start: float) -> void:
	host = h
	world = w
	shooter = s
	t0 = start


## One step of the look: turn toward travel, then draw body and scans from `s` (keys in the header).
func update(s: Dictionary) -> void:
	_turn(s)
	_draw(s)


## Scan sets showing now (one per repaired target; tests).
func scans_shown() -> int:
	if not host.visible:
		return 0
	var n := 0
	for parts: Array in _beams:
		if not parts.is_empty() and is_instance_valid(parts[0]) and (parts[0] as MeshInstance3D).visible:
			n += 1
	return n


## Pooled scan nodes are not the host's children: hide them when the drone hides (dead / launcher missing).
func hide_scans() -> void:
	for parts: Array in _beams:
		_show_scan(parts, false)


## Hand the pooled scan nodes back (the drone leaves the tree).
func give_back() -> void:
	if not _borrowed:
		return
	_borrowed = false
	var ok := world != null and is_instance_valid(world)
	for parts: Array in _beams:
		for mi: Variant in parts:
			if mi == null or not is_instance_valid(mi) or (mi as Node).get_parent() == host:
				continue
			if ok:
				world.give_mesh(mi as MeshInstance3D)
			else:
				(mi as Node).queue_free()
	_beams.clear()


## Turn slowly toward the horizontal direction of travel.
func _turn(s: Dictionary) -> void:
	var pos := s["pos"] as Vector3
	var dt := float(s["dt"])
	var moved := pos - _prev_pos
	_prev_pos = pos
	if bool(s["first"]) or dt <= 0.0:
		return
	var b := s["frame"] as Basis
	var x := moved.dot(b.x)
	var z := moved.dot(b.z)
	if Vector2(x, z).length() < YAW_MIN_SPEED * dt:
		return
	yaw = lerp_angle(yaw, atan2(-x, -z), 1.0 - exp(-dt / YAW_FOLLOW))


## The body's size now: the docked drone's (mount scale) at launch, growing to full size while it rises, shrinking back
## to the mount's scale on the way home.
func _body_scale(s: Dictionary) -> float:
	var full := FLY_SCALE if flying_mesh else DRONE_SCALE
	var dock := s["dock"] as Dictionary
	if not flying_mesh or not dock.has("scale"):
		return full
	if float(s["age"]) >= float(s["life"]):
		return lerpf(full, float(dock["scale"]), smoothstep(0.0, 1.0, float(s["home"])))
	return lerpf(float(dock["scale"]), full, clampf(float(s["age"]) / maxf(float(s["rise"]), 1e-3), 0.0, 1.0))


## How much of the bob shows: faded in over the rise, out on the way home (it lands exactly on the dock).
func _bob_weight(s: Dictionary) -> float:
	if float(s["age"]) >= float(s["life"]):
		return 1.0 - float(s["home"])
	return clampf(float(s["age"]) / maxf(float(s["rise"]), 1e-3), 0.0, 1.0)


func _draw(s: Dictionary) -> void:
	if _body == null:
		_build(s)
	var now := float(s["now"])
	var up := s["up"] as Vector3
	var dock := s["dock"] as Dictionary
	var beamed := s["beamed"] as Array
	var b := s["frame"] as Basis
	var turn := b * Basis(Vector3.UP, yaw)
	if float(s["age"]) >= float(s["life"]) and dock.has("basis"):   # going home: turn into the docked drone's orientation as it lands
		var to := (dock["basis"] as Basis).orthonormalized()
		turn = Basis(turn.get_rotation_quaternion().slerp(to.get_rotation_quaternion(), smoothstep(0.0, 1.0, float(s["home"]))))
	host.global_transform = Transform3D(turn, (s["pos"] as Vector3) + up * sin(now * 2.6) * BOB * _bob_weight(s))
	if flying_mesh:
		_body.scale = Vector3.ONE * _body_scale(s)
	for i in _rotors.size():
		(_rotors[i] as Node3D).rotation.y = now * 40.0 * (1.0 if i % 2 == 0 else -1.0)
	if _beams.is_empty() and not beamed.is_empty():
		_build_scans()                                # (handed back on leaving the tree: borrow again)
	for i in _beams.size():
		if i >= beamed.size():
			_show_scan(_beams[i] as Array, false)
			continue
		var bt: Variant = beamed[i]
		if bt == null or not is_instance_valid(bt):      # freed since the repair step: `as` on it would raise
			_show_scan(_beams[i] as Array, false)
			continue
		_place_scan(_beams[i] as Array, bt as CombatTarget, now, up, b)


func _build(s: Dictionary) -> void:
	var accent := _accent(s.get("launcher") as Node3D)
	var fly := EquipmentLook.part_mesh(flying_id)
	flying_mesh = fly != null
	if flying_mesh:
		_body = MeshInstance3D.new()
		_body.name = "weapon_" + flying_id
		_body.mesh = fly
		LowPolyMaterials.apply_accent(_body, accent)
		_body.scale = Vector3.ONE * _body_scale(s)
		host.add_child(_body)
	else:
		_build_placeholder(accent)
	_build_scans()


## The BEAMS scan sets (pooled nodes, hidden).
func _build_scans() -> void:
	for i in BEAMS:
		var parts: Array = []
		var r0 := _bucket(1.3)
		for k in SCAN_PARTS.size():
			parts.append(_take(_scan_mesh(k, r0)))
		_beams.append(parts)


## A scan node showing `m`: borrowed from the world's mesh pool (CombatWorld.take_mesh, handed back in give_back), or
## made here as a top-level child of the host when the world isn't in the tree.
func _take(m: Mesh) -> MeshInstance3D:
	var mi: MeshInstance3D = world.take_mesh(m) if world != null and is_instance_valid(world) else null
	if mi != null:
		_borrowed = true
	else:
		mi = CombatMeshes.instance(m)
		mi.top_level = true
		host.add_child(mi)
	mi.visible = false
	return mi


func _show_scan(parts: Array, on: bool) -> void:
	for mi: Variant in parts:
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).visible = on


## Scan height as a fraction of the target's height at clock time `now`: up and down between SCAN_LO and SCAN_HI once per
## SCAN_PERIOD s, eased at the turns, a pure function of the time since launch (every machine draws the same scan).
func scan_fraction(now: float) -> float:
	var k := 0.5 - 0.5 * cos(TAU * (now - t0) / SCAN_PERIOD)
	return lerpf(SCAN_LO, SCAN_HI, k)


## {h: height (m along its up), r: scan ring radius (m)} of `t`, worked out once and cached: from its MechModel's meshes
## when it has one (fits every chassis), else from its hit spheres (dummies, assets), else probe_height / body_radius.
func scan_fit(t: CombatTarget) -> Dictionary:
	var key := t.get_instance_id()
	var got: Variant = _fit.get(key)
	if got is Dictionary:
		return got
	var anchored := false
	var model: MechModel = null
	if world != null:
		var f := world.anchor_of(t.target_id)
		if f.is_valid():
			anchored = true
			var n: Variant = f.call()
			if n != null and is_instance_valid(n):
				model = EquipmentLook.find_model(n as Node)
	if model == null:
		model = EquipmentLook.find_model(t)
	var fit := {}
	if model != null and model.is_inside_tree():
		fit = _fit_model(model, t.global_position, t.up)
	if fit.is_empty():
		fit = _fit_spheres(t)
		if anchored:
			return fit                  # its model may not be built yet: look again next time
	_fit[key] = fit
	return fit


## Height along `u` of the model's mesh bounds above `origin`, and the ring radius round its body band (55-80 % of the
## height), padded a little so the ring sits just outside the body.
static func _fit_model(model: MechModel, origin: Vector3, u: Vector3) -> Dictionary:
	var hi := 0.0
	var pts: Array[Vector3] = []
	for c: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var bb := mi.mesh.get_aabb()
		var xf := mi.global_transform
		for k in 8:
			var w := xf * bb.get_endpoint(k) - origin
			pts.append(w)
			hi = maxf(hi, w.dot(u))
	if hi < 2.0:
		return {}
	var rad := 0.0
	for w in pts:
		var h := w.dot(u)
		if h > hi * 0.55 and h < hi * 0.8:
			rad = maxf(rad, (w - u * h).length())
	return {"h": hi, "r": clampf(rad * 0.6, RING_MIN, RING_MAX) + RING_PAD}


static func _fit_spheres(t: CombatTarget) -> Dictionary:
	var hi := 0.0
	var rad := 0.0
	var s := t.global_transform.basis.get_scale().x if t.is_inside_tree() else 1.0
	for hs: Dictionary in t.hit_shapes:
		var c := hs["center"] as Vector3
		var r := float(hs["radius"])
		hi = maxf(hi, (c.y + r) * s)
		rad = maxf(rad, r * s)
	if hi <= 0.0:
		hi = float(t.probe_height) * 2.0
		rad = float(t.body_radius)
	return {"h": maxf(hi, 1.0), "r": clampf(rad, RING_MIN * 0.5, RING_MAX) + RING_PAD}


## One repaired target's scan look this step: the hot ring at scan_fraction × its height, the trail rings where the hot
## ring was TRAIL_DT, 2 × and 3 × ago, the soft band between it and where it was BAND_DT ago, and the faint wedge from the
## drone's lens to the drone-facing arc of the hot ring. Cached meshes, transforms only.
func _place_scan(parts: Array, t: CombatTarget, now: float, up_dir: Vector3, frame: Basis) -> void:
	var fit := scan_fit(t)
	var hgt := float(fit["h"])
	var rc := _bucket(float(fit["r"]))
	var u := t.up.normalized() if t.up.length_squared() > 1e-6 else up_dir
	var base := t.global_position
	var lens := host.global_position - up_dir * 0.3
	var h0 := hgt * scan_fraction(now)
	var c0 := base + u * h0
	var tw := lens - c0                 # toward the drone, across the target's up
	tw -= u * tw.dot(u)
	if tw.length_squared() < 1e-6:
		tw = frame.z - u * frame.z.dot(u)
	tw = tw.normalized()
	var side := u.cross(tw).normalized()
	var b := Basis(side, u, tw)
	for i in SCAN_PARTS.size():
		var mi := parts[i] as MeshInstance3D
		var m := _scan_mesh(i, rc)
		if mi.mesh != m:
			mi.mesh = m
	for k in 4:                         # head + 3 trail rings
		var hk := h0 if k == 0 else hgt * scan_fraction(now - TRAIL_DT * k)
		(parts[k] as MeshInstance3D).global_transform = Transform3D(b, base + u * hk)
	var dh := h0 - hgt * scan_fraction(now - BAND_DT)   # >0 moving up (band below), <0 moving down (band above)
	if absf(dh) < 0.02:
		dh = 0.02 if dh >= 0.0 else -0.02
	(parts[4] as MeshInstance3D).global_transform = Transform3D(Basis(side, u * dh, tw), c0)
	_show_scan(parts.slice(0, 5), true)
	var reach := lens - c0
	var lens_ok := reach.length() > rc + 0.5
	for i in [5, 6, 7]:
		(parts[i] as MeshInstance3D).visible = lens_ok
	if not lens_ok:
		return
	(parts[5] as MeshInstance3D).global_transform = Transform3D(Basis(side * rc, reach, tw * rc), c0)
	for e in 2:
		var a := WEDGE_HALF * (1.0 if e == 0 else -1.0)
		var to := c0 + (side * sin(a) + tw * cos(a)) * rc
		var d := to - lens
		(parts[6 + e] as MeshInstance3D).global_transform = Transform3D(
			Combat.look_basis(d) * Basis.from_scale(Vector3(EDGE_W, EDGE_W, d.length())), lens)


## For CombatWorld.prewarm_mesh_pool: one drone's scan nodes (BEAMS sets) with their meshes built, so a launch takes
## them from the pool instead of building 32 nodes and 7 meshes mid-fight (and the shader warm-up sees the scan looks).
static func pool_plan() -> Array:
	var plan: Array = []
	for k in SCAN_PARTS.size():
		plan.append([_scan_mesh(k, _bucket(1.3)), BEAMS])
	return plan


## Ring radii come in RING_STEP buckets so a handful of meshes serve every target.
static func _bucket(r: float) -> float:
	return maxf(snappedf(r, RING_STEP), RING_STEP)


## The cached mesh for scan part `part` (index into SCAN_PARTS) at ring radius `r` (bucketed). Rings are square-section
## bars round a SCAN_SIDES-gon of radius r in XZ (vertex 0 on +Z); the band is the same polygon's open side from y -1
## (clear) to y 0; the wedge is a fan from an apex at (0, 1, 0) to the unit polygon's +Z arc (its transform shears it
## onto the lens and the hot ring); an edge is a square bar along -Z, 1 m long, 1 m across (scaled).
static func _scan_mesh(part: int, r: float) -> ArrayMesh:
	var key := Vector2i(mini(part, 6), roundi(r * 100.0) if part < 5 else 0)    # (no string per frame; both edges share)
	var got: Variant = _scan_meshes.get(key)
	if got != null:
		return got
	var kind := str(SCAN_PARTS[part])
	if _scan_mats.is_empty():
		_scan_mats = [_scan_material(0), _scan_material(1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := SCAN_SIDES
	var poly: Array[Vector3] = []
	for i in n:
		var a := TAU * float(i) / float(n)
		poly.append(Vector3(sin(a), 0.0, cos(a)))
	var line := true
	match kind:
		"head", "trail1", "trail2", "trail3":
			var k := ["head", "trail1", "trail2", "trail3"].find(kind)
			var col := _a(SCAN_ALPHAS[k], CORE if k == 0 else GREEN)
			for i in n:
				_bar(st, poly[i] * r, poly[(i + 1) % n] * r, HEAD_W if k == 0 else TRAIL_W, col, col)
		"band":
			line = false
			for i in n:
				var p: Vector3 = poly[i] * r
				var q: Vector3 = poly[(i + 1) % n] * r
				_quad(st, p - Vector3.UP, q - Vector3.UP, q, p, _a(0.0), _a(0.0), _a(BAND_ALPHA), _a(BAND_ALPHA))
		"wedge":
			line = false
			var steps := roundi(WEDGE_HALF / (TAU / float(n)))
			for i in range(-steps, steps):
				var a0 := TAU * float(i) / float(n)
				var a1 := TAU * float(i + 1) / float(n)
				_tri(st, Vector3.UP, Vector3(sin(a0), 0, cos(a0)), Vector3(sin(a1), 0, cos(a1)),
					_a(0.02), _a(0.08), _a(0.08))
		"edge":
			_bar(st, Vector3.ZERO, Vector3(0, 0, -1), 1.0, _a(0.08), _a(0.3))
	st.set_material(_scan_mats[1 if line else 0])
	var m := st.commit()
	_scan_meshes[key] = m
	return m


## Unshaded, alpha-blended, vertex colour, both faces; volumes draw before lines (render_priority).
static func _scan_material(prio: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = prio
	return m


static func _a(alpha: float, col: Color = GREEN) -> Color:
	return Color(col.r, col.g, col.b, alpha)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	st.set_color(ca)
	st.add_vertex(a)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_color(cc)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color,
		cd: Color) -> void:
	_tri(st, a, b, c, ca, cb, cc)
	_tri(st, a, c, d, ca, cc, cd)


## A thin square-section bar from a to b, `w` across (reads the same from any side), colour ca at a to cb at b.
static func _bar(st: SurfaceTool, a: Vector3, b: Vector3, w: float, ca: Color, cb: Color) -> void:
	var d := b - a
	if d.length() < 1e-5:
		return
	var dn := d.normalized()
	var p := dn.cross(Vector3.UP if absf(dn.y) < 0.95 else Vector3.RIGHT).normalized() * w * 0.5
	var q := dn.cross(p).normalized() * w * 0.5
	var ofs := [p + q, p - q, -p - q, -p + q]
	for i in 4:
		var o1: Vector3 = ofs[i]
		var o2: Vector3 = ofs[(i + 1) % 4]
		_quad(st, a + o1, a + o2, b + o2, b + o1, ca, ca, cb, cb)


## The fallback look (no flying mesh): the MeshKit quad body and four spinning rotors.
func _build_placeholder(accent: Color) -> void:
	_body = CombatMeshes.instance(body_mesh(accent))
	_body.scale = Vector3.ONE * DRONE_SCALE
	host.add_child(_body)
	for i in 4:
		var rot := CombatMeshes.instance(rotor_mesh())
		var ang := PI * 0.25 + PI * 0.5 * i
		rot.position = Vector3(cos(ang), 0.12, sin(ang)) * 0.8 * DRONE_SCALE
		rot.scale = Vector3.ONE * DRONE_SCALE
		host.add_child(rot)
		_rotors.append(rot)


## The launcher's accent colour: its MechModel's (EquipmentLook's source, else found under the launcher `node`), else the
## default orange.
func _accent(node: Node3D) -> Color:
	var mm := world.equipment_look.model_of(world, shooter) if world != null else null
	if mm != null:
		return mm.accent
	var stack: Array = [node] if node != null else []
	var depth := 0
	while not stack.is_empty() and depth < 4:
		var next: Array = []
		for n: Variant in stack:
			if n is MechModel:
				return (n as MechModel).accent
			next.append_array((n as Node).get_children())
		stack = next
		depth += 1
	return LowPolyPalette.ORANGE


## The drone body: a flat hub, four arms, a sensor ball underneath; accent hub, grey arms. Cached per colour.
static func body_mesh(accent: Color) -> ArrayMesh:
	return CombatMeshes.mesh("drone|%s" % accent.to_html(), func(k: MeshKit) -> void:
		k.box(Vector3(0.7, 0.22, 0.7), accent)
		k.box(Vector3(0.45, 0.14, 0.45), accent.darkened(0.25), Vector3(0, 0.17, 0))
		for i in 4:
			var ang := PI * 0.25 + PI * 0.5 * i
			var tip := Vector3(cos(ang), 0.0, sin(ang)) * 0.8
			k.tube(Vector3(0, 0.02, 0), tip, 0.05, 4, LowPolyPalette.GUN)
			k.tube(tip - Vector3(0, 0.1, 0), tip + Vector3(0, 0.1, 0), 0.08, 6, LowPolyPalette.GUN)
		k.glow = true
		k.ico(Vector3(0, -0.16, 0), Vector3.ONE * 0.12, GREEN))


## One rotor: a thin flat bar (spun about its local Y each step).
static func rotor_mesh() -> ArrayMesh:
	return CombatMeshes.mesh("drone_rotor", func(k: MeshKit) -> void:
		k.box(Vector3(0.62, 0.02, 0.08), Color(0.12, 0.12, 0.13)))
