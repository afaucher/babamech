class_name HangarBay
extends Node3D
## The hangar set (docs/design/hangar.md): the vehicle bay of a military assault boat clamped to the habitat hull,
## about to force-board. Gunmetal plates, ribs and girders, yellow-black hazard stripes, ammunition racks, a breaching
## door on the end wall. The camera looks at ONE side wall: four recessed alcoves side by side, a mech standing in each,
## facing out into the aisle (toward the camera), each with its bulkhead frame, its light, its shoulder clamps and
## brace arms, and its nameplate. Two states: prep (work lights, clamps and braces open) and alert (Launch: lights drop,
## red beacons turn, amber strobes, the countdown strip over the alcoves glows, the clamps swing down onto the mechs'
## shoulders and the brace rams close on their hips). Cosmetic only (no gameplay state, no randomness). Used by
## MechStage for the hangar screen and as the lab subject `hangar`.
##
## Axes: the wall runs along X; the alcoves are recessed into it toward -Z, their front (the wall face) is at FRONT_Z;
## the aisle and the camera are on +Z. Mechs face +Z (MECH_YAW = PI: MechModel faces -Z). The framing is computed from
## the viewport's aspect (camera_frame), so the occupied alcoves always fit the preview, whatever the window shape.

const GUNMETAL := Color(0.29, 0.31, 0.34)
const GUNMETAL_DARK := Color(0.17, 0.18, 0.2)
const GUNMETAL_LIGHT := Color(0.38, 0.4, 0.43)
const HAZARD_YELLOW := Color(0.95, 0.74, 0.1)
const HAZARD_BLACK := Color(0.08, 0.08, 0.09)
const BRASS := Color(0.78, 0.6, 0.26)
const WORK_LIGHT := Color(0.85, 0.92, 1.0)
const ALERT_RED := Color(1.0, 0.14, 0.07)
const STROBE_AMBER := Color(1.0, 0.6, 0.12)

const HALF_WIDTH := 18.0                ## the bay runs x -HALF_WIDTH .. +HALF_WIDTH (end walls)
const HEIGHT := 14.0                    ## tall enough for the lab's steep preset views from far back
const NEAR_Z := 44.0                    ## the near bulkhead, behind the camera (the widest framing stands ~35 m off)
const WALL_Z := -2.1                    ## the alcoves' back face
const FRONT_Z := 2.6                    ## the wall face: the front of the alcove posts and the cradle platforms
const ALCOVE_HALF := 2.7                ## half the clear width inside an alcove (post face to post face)
const POST_W := 0.8                     ## the bulkhead posts between alcoves
const PITCH := ALCOVE_HALF * 2.0 + POST_W
## Alcove centres by seat: seats fill from the middle so the occupied alcoves are always side by side
## (1: left-centre, 2: right-centre, 3: far left, 4: far right).
const ALCOVE_X := [-PITCH * 0.5, PITCH * 0.5, -PITCH * 1.5, PITCH * 1.5]
const PLATFORM_H := 0.4                 ## the cradle platform the mech stands on
const MECH_Z := 0.0                     ## the mech's origin, inside its alcove
const LINTEL_Y := 8.0                   ## the underside of the header over the alcoves
const MECH_YAW := PI                    ## mechs face +Z: out of the alcove, toward the aisle and the camera
const ALERT_RAMP := 1.0                 ## seconds for the clamps to close and the lights to change

## Clamps. The shoulder clamp is a hinged arm on each post, stowed upright in prep, swung down level in alert so its
## pad stops CLAMP_GAP short of the mech's measured box (MechModel meshes, measured on show_crew). The brace arm is a
## ram at hip height that slides out of a sleeve in the post to the same gap.
const CLAMP_GAP := 0.06
const CLAMP_Y := 3.7                    ## above the mech's origin: the shoulder pods
const BRACE_Y := 2.2                    ## above the mech's origin: the hips
const CLAMP_Z := 0.1
const HINGE_OUT := 0.25                 ## the hinge line stands this far out of the post face (the stowed arm clears the mech)
const ARM_H := 0.5                      ## the hinged arm's thickness in its swing plane
## Box of every mech the catalog can build (all heads, loadouts, both leg bends, the idle bob), facing +Z: the
## clamps of an empty alcove are fitted to it, and it is the fallback before a mech has meshes.
const MECH_ENVELOPE := AABB(Vector3(-1.7, -0.08, -1.32), Vector3(3.4, 6.0, 3.45))

## Framing (camera_frame): vertical field of view, how far the camera looks down, the share of the view kept free on
## every side, and the drag orbit's limit (it never swings behind the wall).
const FOV := 50.0
const LOOK_DOWN := deg_to_rad(5.0)
const FRAME_MARGIN := 0.04
const ORBIT_MAX := 0.3

var time_scale := 1.0
var own_environment := true            ## its own sky and ambient (the lab takes its own out); MechStage sets false, it has one
var models: Array[MechModel] = []

var state := "prep"
var beacon_speed := 2.5                ## rad/s
var work_energy := 2.2
var alert_dim := 0.3                   ## work-light energy multiplier in alert

var _t := 0.0
var _alert_k := 0.0                    ## 0 prep .. 1 alert, eased over ALERT_RAMP
var _work_lights: Array[OmniLight3D] = []
var _alcove_lights: Array[OmniLight3D] = []
var _alcove_strips: Array[MeshInstance3D] = []
var _beacons: Array[Node3D] = []       ## pivots, each turning one red spot
var _beacon_lights: Array[SpotLight3D] = []
var _beacon_housings: Array[MeshInstance3D] = []
var _strobes: Array[OmniLight3D] = []
var _clamp_roots: Array[Node3D] = []   ## per alcove: every clamp and brace mesh (rebuilt by fit_clamps)
var _clamps: Array[Dictionary] = []    ## {"node", "kind" ("clamp" | "brace"), "side", "travel"}
var _countdown: MeshInstance3D
var _door_lamps: Array[MeshInstance3D] = []
var _crew_root: Node3D
var _lab_crew := "4"
var _own_env: Environment


func _init() -> void:
	name = "HangarBay"


func _ready() -> void:
	if own_environment:
		var env := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.05, 0.055, 0.065)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.4, 0.43, 0.5)
		e.ambient_light_energy = 0.5
		e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		env.environment = e
		add_child(env)
		_own_env = e
	_build_shell()
	_build_wall()
	for i in ALCOVE_X.size():
		_build_alcove(i)
	_build_door()
	for x: float in [-15.6, 15.6]:
		_build_rack(Vector3(x, 0, FRONT_Z + 0.75))
	_build_lights()
	_crew_root = Node3D.new()
	_crew_root.name = "Crew"
	add_child(_crew_root)
	fit_clamps()
	if own_environment and models.is_empty():
		_show_lab_crew()
	_apply_lights()


# --- Crew ---------------------------------------------------------------------------------------------

## Put these mechs in the alcoves: [{head, chassis, loadout, name, accent}] (at most four; extra entries are ignored).
func show_crew(entries: Array) -> Array[MechModel]:
	if _crew_root == null:
		_crew_root = Node3D.new()
		_crew_root.name = "Crew"
		add_child(_crew_root)
	for c in _crew_root.get_children():
		_crew_root.remove_child(c)
		c.queue_free()
	models.clear()
	for i in mini(entries.size(), ALCOVE_X.size()):
		var e: Dictionary = entries[i]
		var m := MechModel.new()
		m.configure(str(e.get("head", "chicken")), str(e.get("chassis", "strider")), e.get("loadout", {}) as Dictionary)
		MechAccent.apply(m, str(e.get("accent", MechAccent.DEFAULT)))
		m.position = Vector3(float(ALCOVE_X[i]), PLATFORM_H, MECH_Z)
		m.rotation.y = MECH_YAW
		m.time_scale = 0.0 if state == "alert" else 1.0
		_crew_root.add_child(m)
		models.append(m)
		if str(e.get("name", "")) != "":
			var tag := Label3D.new()
			tag.name = "Tag%d" % i
			tag.text = str(e["name"])
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.font_size = 64
			tag.pixel_size = TAG_PIXEL
			tag.outline_size = 12
			tag.position = m.position + Vector3(0, minf(tag_height(m), LINTEL_Y - PLATFORM_H - 0.5), 0.6)
			_crew_root.add_child(tag)
	if not _clamp_roots.is_empty():
		fit_clamps()
		_apply_lights()
	return models


## Height for a mech's name tag above its origin: the top of its meshes plus a gap (the crest, raised pods), so the
## tag never sits on the head. Falls back to a fixed height before the model has meshes.
static func tag_height(m: Node3D, gap: float = 0.7) -> float:
	var top := -INF
	var inv := m.global_transform.affine_inverse() if m.is_inside_tree() else Transform3D.IDENTITY
	var stack: Array[Node] = [m]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_inside_tree():
			continue
		var box := (inv * mi.global_transform) * mi.mesh.get_aabb()
		top = maxf(top, box.end.y)
	return top + gap if top > 0.5 else 5.8


## The box of every visible mesh under `n`, in the space of `space` (an ancestor of n, or n itself). Works out of the
## tree too (it composes the local transforms). Empty AABB when there are no meshes.
static func mesh_box(n: Node3D, space: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		var c3 := c as Node3D
		if c3 != null and not c3.visible:
			continue
		stack.append_array(c.get_children())
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b := _to_space(mi, space) * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


static func _to_space(n: Node3D, space: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c: Node = n
	while c != null and c != space:
		var c3 := c as Node3D
		if c3 != null:
			t = c3.transform * t
		c = c.get_parent()
	return t


## The mech in seat i, measured: the box of its meshes in the bay's space (the envelope at its alcove before it has
## meshes, or for an empty alcove).
func mech_box(i: int) -> AABB:
	var at := Vector3(float(ALCOVE_X[i]), PLATFORM_H, MECH_Z)
	if i < models.size():
		var b := mesh_box(models[i], self)
		if b.size.y > 1.0:
			return b
	return AABB(MECH_ENVELOPE.position + at, MECH_ENVELOPE.size)


# --- Framing ------------------------------------------------------------------------------------------

## The box the camera keeps in view: the occupied alcoves (posts, platforms and header included), at least seat 1's.
func frame_box() -> AABB:
	var n := clampi(models.size(), 1, ALCOVE_X.size())
	var lo := INF
	var hi := -INF
	for i in n:
		lo = minf(lo, float(ALCOVE_X[i]))
		hi = maxf(hi, float(ALCOVE_X[i]))
	var half := ALCOVE_HALF + POST_W
	return AABB(Vector3(lo - half, 0.0, WALL_Z), Vector3(hi - lo + half * 2.0, LINTEL_Y + 0.6, FRONT_Z - WALL_Z))


## Where the camera stands to frame the occupied alcoves in a view of this aspect (width / height, vertical FOV): it
## looks at the wall from the aisle, LOOK_DOWN below level, turned `orbit` about the frame's centre, and backs off
## exactly as far as the nearest-fitting corner needs, FRAME_MARGIN clear of every edge.
func camera_frame(aspect: float, orbit: float = 0.0) -> Transform3D:
	var box := frame_box()
	var target := box.get_center()
	var o := clampf(orbit, -ORBIT_MAX, ORBIT_MAX)
	var back := Vector3(sin(o) * cos(LOOK_DOWN), sin(LOOK_DOWN), cos(o) * cos(LOOK_DOWN))
	var look := Basis.looking_at(-back, Vector3.UP)
	var tv := tan(deg_to_rad(FOV) * 0.5) * (1.0 - 2.0 * FRAME_MARGIN)
	var th := tan(deg_to_rad(FOV) * 0.5) * maxf(aspect, 0.1) * (1.0 - 2.0 * FRAME_MARGIN)
	var d := 4.0
	for i in 8:
		var v := box.get_endpoint(i) - target
		var along := v.dot(back)
		d = maxf(d, absf(v.dot(look.x)) / th + along)
		d = maxf(d, absf(v.dot(look.y)) / tv + along)
	return Transform3D(look, target + back * d)


## Nameplates keep a readable size however far back the framing puts the camera: scaled with its distance (the base
## size reads at TAG_NEAR m), capped so a long name stays inside its alcove.
const TAG_PIXEL := 0.006
const TAG_NEAR := 13.0
const TAG_MAX_SCALE := 2.2

func scale_tags(cam_pos: Vector3) -> void:
	if _crew_root == null:
		return
	for c in _crew_root.get_children():
		var tag := c as Label3D
		if tag != null:
			var k := clampf(cam_pos.distance_to(to_global(tag.position)) / TAG_NEAR, 1.0, TAG_MAX_SCALE)
			tag.pixel_size = TAG_PIXEL * k


# --- States -------------------------------------------------------------------------------------------

## 0 in prep .. 1 in full alert (eased); MechStage tints its ambient light with it.
func alert_amount() -> float:
	return _alert_k * _alert_k * (3.0 - 2.0 * _alert_k)


func set_alert(on: bool) -> void:
	state = "alert" if on else "prep"
	for m in models:
		m.time_scale = 0.0 if on else 1.0


func _process(delta: float) -> void:
	var dt := delta * time_scale
	_t += dt
	var goal := 1.0 if state == "alert" else 0.0
	_alert_k = move_toward(_alert_k, goal, dt / ALERT_RAMP)
	for i in _beacons.size():
		_beacons[i].rotation.y = _t * beacon_speed + float(i) * 1.3
	_apply_lights()


func _apply_lights() -> void:
	var k := alert_amount()
	if _own_env != null:
		_own_env.ambient_light_color = Color(0.4, 0.43, 0.5).lerp(Color(0.6, 0.25, 0.22), k)
		_own_env.ambient_light_energy = lerpf(0.5, 0.3, k)
	var work := work_energy * lerpf(1.0, alert_dim, k)
	for l in _work_lights:
		l.light_energy = work * 0.6
	for i in _alcove_lights.size():
		var lit := i < maxi(models.size(), 1)   # an empty alcove stays dark
		_alcove_lights[i].visible = lit
		_alcove_lights[i].light_energy = work * 1.4
		_alcove_strips[i].material_override = MechParts.mat(WORK_LIGHT if lit else GUNMETAL_DARK, 1.0, lit)
	for l in _beacon_lights:
		l.light_energy = 16.0 * k
		l.visible = k > 0.01
	var blink := 1.0 if fmod(_t * 2.0, 1.0) < 0.35 else 0.0
	for l in _strobes:
		l.light_energy = 4.0 * k * blink
		l.visible = k > 0.01
	for c: Dictionary in _clamps:
		var node: Node3D = c["node"]
		var s: float = c["side"]
		if c["kind"] == "clamp":
			node.rotation.z = -s * (PI * 0.5) * (1.0 - k)   # upright in prep, level (closed) in alert
		else:
			node.position.x = float(c["closed_x"]) + s * float(c["travel"]) * (1.0 - k)
	if _countdown != null:
		var pulse := 0.6 + 0.4 * sin(_t * 6.0)
		_countdown.material_override = MechParts.mat(STROBE_AMBER if k > 0.5 else Color(0.25, 0.17, 0.05), 1.0, k > 0.5)
		_countdown.scale = Vector3(lerpf(1.0, maxf(0.05, 1.0 - fmod(_t, 3.0) / 3.0), k), 1.0 + 0.3 * pulse * k, 1.0)
	for h in _beacon_housings:
		h.material_override = MechParts.mat(ALERT_RED if k > 0.5 else Color(0.3, 0.06, 0.04), 1.0, k > 0.5)
	for lamp in _door_lamps:
		lamp.material_override = MechParts.mat(ALERT_RED if k > 0.5 and blink > 0.0 else Color(0.3, 0.06, 0.04), 1.0, k > 0.5)


# --- Clamps -------------------------------------------------------------------------------------------

## Fit every alcove's shoulder clamps and brace arms to the mech standing in it (its measured box; the envelope for
## an empty alcove): closed, each pad stops CLAMP_GAP short of the box. Call again after changing a mech's shape.
func fit_clamps() -> void:
	_clamps.clear()
	for i in ALCOVE_X.size():
		if i >= _clamp_roots.size():
			var r := Node3D.new()
			r.name = "Clamps%d" % i
			add_child(r)
			_clamp_roots.append(r)
		var root := _clamp_roots[i]
		for c in root.get_children():
			root.remove_child(c)
			c.free()
		var box := mech_box(i)
		var cx := float(ALCOVE_X[i])
		for s: float in [1.0, -1.0]:
			var face := cx + s * ALCOVE_HALF                       # the post's inner face
			var reach := (box.end.x if s > 0.0 else box.position.x) + s * CLAMP_GAP
			# Shoulder clamp: hinge half in the post; the arm's far corners sweep a circle that just reaches `reach`.
			var hinge_x := face - s * HINGE_OUT
			var corner := absf(hinge_x - reach)
			var arm_len := sqrt(maxf(corner * corner - (ARM_H * 0.5) * (ARM_H * 0.5), 0.09))
			root.add_child(MechParts.box(Vector3(0.5, 0.7, 0.8), GUNMETAL_DARK,
				Vector3(face - s * 0.05, PLATFORM_H + CLAMP_Y, MECH_Z + CLAMP_Z)))   # the hinge block, on the post face
			var pivot := Node3D.new()
			pivot.name = "Clamp%s" % ("R" if s > 0.0 else "L")
			pivot.position = Vector3(hinge_x, PLATFORM_H + CLAMP_Y, MECH_Z + CLAMP_Z)
			root.add_child(pivot)
			pivot.add_child(MechParts.box(Vector3(arm_len - 0.22, ARM_H * 0.7, 0.42), GUNMETAL,
				Vector3(-s * (arm_len - 0.22) * 0.5, 0, 0)))
			pivot.add_child(MechParts.box(Vector3(0.22, ARM_H, 0.62), HAZARD_YELLOW, Vector3(-s * (arm_len - 0.11), 0, 0)))
			_clamps.append({"node": pivot, "kind": "clamp", "side": s, "travel": 0.0, "closed_x": 0.0})
			# Brace arm: a ram sliding out of a sleeve in the post at hip height.
			var by := PLATFORM_H + BRACE_Y
			root.add_child(MechParts.box(Vector3(0.3, 0.5, 0.5), GUNMETAL_DARK, Vector3(face - s * 0.15, by, MECH_Z + CLAMP_Z)))
			var rod_len := absf(face - reach) + 0.3                 # the rest stays inside the post
			var ram := Node3D.new()
			ram.name = "Brace%s" % ("R" if s > 0.0 else "L")
			root.add_child(ram)
			ram.add_child(MechParts.box(Vector3(rod_len - 0.12, 0.24, 0.24), GUNMETAL_LIGHT, Vector3(s * (rod_len - 0.12) * 0.5 + s * 0.12, 0, 0)))
			ram.add_child(MechParts.box(Vector3(0.12, 0.46, 0.46), HAZARD_YELLOW, Vector3(s * 0.06, 0, 0)))
			var travel := maxf(absf(face - reach) - 0.3, 0.0)        # open: the pad sits at the sleeve's mouth
			ram.position = Vector3(reach, by, MECH_Z + CLAMP_Z)
			_clamps.append({"node": ram, "kind": "brace", "side": s, "travel": travel, "closed_x": reach})


## Every clamp and brace mesh of alcove i (the fixed hinge blocks and sleeves too), for the clearance check.
func clamp_meshes(i: int) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [_clamp_roots[i]]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
	return out


## The smallest gap (m) between alcove i's clamp / brace meshes and its mech's measured box (negative = they overlap),
## in the current pose.
func clamp_clearance(i: int) -> float:
	var mech := mech_box(i)
	var gap := INF
	for mi in clamp_meshes(i):
		var b := _to_space(mi, self) * mi.mesh.get_aabb()
		gap = minf(gap, _box_gap(b, mech))
	return gap


## The gap (m) between each moving clamp / brace arm of alcove i and its mech's measured box, in the current pose.
func pad_gaps(i: int) -> Array[float]:
	var mech := mech_box(i)
	var out: Array[float] = []
	for c: Dictionary in _clamps:
		var node: Node3D = c["node"]
		if node.get_parent() == _clamp_roots[i]:
			out.append(_box_gap(mesh_box(node, self), mech))
	return out


## Separation of two boxes: the largest axis gap when apart (> 0), minus the smallest overlap depth when they intersect.
static func _box_gap(a: AABB, b: AABB) -> float:
	var g := -INF
	var depth := INF
	for ax in 3:
		var sep := maxf(b.position[ax] - a.end[ax], a.position[ax] - b.end[ax])
		g = maxf(g, sep)
		depth = minf(depth, -sep)
	return g if g > 0.0 else -depth


# --- Set ----------------------------------------------------------------------------------------------

func _build_shell() -> void:
	var length := NEAR_Z - WALL_Z
	var mid_z := (NEAR_Z + WALL_Z) * 0.5
	var width := HALF_WIDTH * 2.0
	add_child(MechParts.box(Vector3(width, 0.2, length), GUNMETAL_DARK, Vector3(0, -0.1, mid_z)))
	# Deck plate seams along the wall, and the aisle edges in hazard yellow (parallel to the wall).
	var z := FRONT_Z + 4.0
	while z < NEAR_Z:
		add_child(MechParts.box(Vector3(width, 0.02, 0.08), HAZARD_BLACK, Vector3(0, 0.01, z)))
		z += 4.0
	var x := -HALF_WIDTH + 3.0
	while x < HALF_WIDTH:
		add_child(MechParts.box(Vector3(0.08, 0.02, length), HAZARD_BLACK, Vector3(x, 0.012, mid_z)))
		x += 6.0
	_stripes(Vector3(-HALF_WIDTH, 0.02, FRONT_Z + 0.9), Vector3(HALF_WIDTH, 0.02, FRONT_Z + 0.9), Vector3(0, 0.04, 0.35), 40)
	add_child(MechParts.box(Vector3(width, 0.03, 0.25), HAZARD_YELLOW, Vector3(0, 0.015, FRONT_Z + 9.0)))
	# End walls, ceiling, the near bulkhead behind the camera (closing the bay for the lab's 360-degree orbit).
	for side: float in [1.0, -1.0]:
		add_child(MechParts.box(Vector3(0.6, HEIGHT, length), GUNMETAL, Vector3(side * (HALF_WIDTH + 0.3), HEIGHT * 0.5, mid_z)))
		add_child(MechParts.box(Vector3(0.25, 0.5, length), HAZARD_YELLOW, Vector3(side * (HALF_WIDTH - 0.12), 0.25, mid_z)))
	add_child(MechParts.box(Vector3(width + 1.2, 0.4, length + 1.2), GUNMETAL_DARK, Vector3(0, HEIGHT + 0.2, mid_z)))
	add_child(MechParts.box(Vector3(width + 1.2, HEIGHT, 0.6), GUNMETAL, Vector3(0, HEIGHT * 0.5, NEAR_Z + 0.3)))
	# Ceiling girders across the bay (wall to near bulkhead), light strips between them.
	x = -HALF_WIDTH + 2.0
	while x < HALF_WIDTH:
		add_child(MechParts.box(Vector3(0.7, 0.8, length), GUNMETAL_LIGHT, Vector3(x, HEIGHT - 0.4, mid_z)))
		x += PITCH
	z = FRONT_Z + 3.0
	while z < NEAR_Z - 2.0:
		for lx: float in [-11.0, -3.0, 3.0, 11.0]:
			add_child(_glow(Vector3(2.4, 0.1, 0.5), WORK_LIGHT, Vector3(lx, HEIGHT - 0.05, z)))
		z += 6.0


## The wall the camera looks at: its face at FRONT_Z, solid beyond the alcove row, a header above the row carrying the
## countdown strip, the bulkhead posts between alcoves.
func _build_wall() -> void:
	var row_half := PITCH * 2.0 + POST_W * 0.5                     # outer faces of the end posts
	var depth := FRONT_Z - WALL_Z
	var mid_z := (FRONT_Z + WALL_Z) * 0.5
	# The back plate behind the alcoves, and the solid wall beyond the row on both sides.
	add_child(MechParts.box(Vector3(HALF_WIDTH * 2.0, HEIGHT, 0.6), GUNMETAL, Vector3(0, HEIGHT * 0.5, WALL_Z - 0.3)))
	var side_w := HALF_WIDTH - row_half
	for s: float in [1.0, -1.0]:
		var cx := s * (row_half + side_w * 0.5)
		add_child(MechParts.box(Vector3(side_w, HEIGHT, depth), GUNMETAL, Vector3(cx, HEIGHT * 0.5, mid_z)))
		# Ribs on the plain wall.
		var rx := row_half + 1.6
		while rx < HALF_WIDTH - 0.5:
			add_child(MechParts.box(Vector3(0.5, HEIGHT, 0.3), GUNMETAL_LIGHT, Vector3(s * rx, HEIGHT * 0.5, FRONT_Z + 0.15)))
			rx += 2.4
		add_child(MechParts.box(Vector3(side_w, 0.5, 0.25), HAZARD_YELLOW, Vector3(cx, 0.25, FRONT_Z + 0.13)))
	# The header over the row: a heavy beam, a dark band with the countdown strip, beacons on top of each post.
	var top_h := HEIGHT - LINTEL_Y
	add_child(MechParts.box(Vector3(row_half * 2.0, top_h, depth), GUNMETAL, Vector3(0, LINTEL_Y + top_h * 0.5, mid_z)))
	add_child(MechParts.box(Vector3(row_half * 2.0 + 0.4, 0.6, 0.5), GUNMETAL_LIGHT, Vector3(0, LINTEL_Y + 0.3, FRONT_Z + 0.25)))
	_stripes(Vector3(-row_half, LINTEL_Y + 0.75, FRONT_Z + 0.08), Vector3(row_half, LINTEL_Y + 0.75, FRONT_Z + 0.08),
		Vector3(0, 0.3, 0.16), 36)
	add_child(MechParts.box(Vector3(row_half * 2.0 - 2.0, 0.7, 0.12), GUNMETAL_DARK, Vector3(0, LINTEL_Y + 1.5, FRONT_Z + 0.06)))
	_countdown = MechParts.box(Vector3(row_half * 2.0 - 3.0, 0.3, 0.1), Color(0.25, 0.17, 0.05), Vector3(0, LINTEL_Y + 1.5, FRONT_Z + 0.14))
	add_child(_countdown)
	# The five bulkhead posts (between and at the ends of the four alcoves), striped at the foot.
	for p in 5:
		var px := (float(p) - 2.0) * PITCH
		add_child(MechParts.box(Vector3(POST_W, LINTEL_Y, depth), GUNMETAL_LIGHT, Vector3(px, LINTEL_Y * 0.5, mid_z)))
		add_child(MechParts.box(Vector3(POST_W * 0.55, LINTEL_Y - 0.6, 0.1), GUNMETAL, Vector3(px, LINTEL_Y * 0.5 + 0.5, FRONT_Z + 0.05)))
		_stripes(Vector3(px, 0, FRONT_Z + 0.06), Vector3(px, 1.6, FRONT_Z + 0.06), Vector3(POST_W + 0.02, 0, 0.12), 4)


func _build_alcove(i: int) -> void:
	var cx := float(ALCOVE_X[i])
	var depth := FRONT_Z - WALL_Z
	var mid_z := (FRONT_Z + WALL_Z) * 0.5
	var w := ALCOVE_HALF * 2.0
	# The cradle platform with a striped lip along the aisle, and a darker recessed back panel with ribs and a hose.
	add_child(MechParts.box(Vector3(w, PLATFORM_H, depth), GUNMETAL_DARK, Vector3(cx, PLATFORM_H * 0.5, mid_z)))
	_stripes(Vector3(cx - ALCOVE_HALF, PLATFORM_H + 0.01, FRONT_Z - 0.18), Vector3(cx + ALCOVE_HALF, PLATFORM_H + 0.01, FRONT_Z - 0.18),
		Vector3(0, 0.04, 0.3), 8)
	add_child(MechParts.box(Vector3(w, LINTEL_Y, 0.1), Color(0.13, 0.14, 0.16), Vector3(cx, LINTEL_Y * 0.5, WALL_Z + 0.05)))
	for y: float in [1.8, 4.2, 6.6]:
		add_child(MechParts.box(Vector3(w, 0.22, 0.2), GUNMETAL, Vector3(cx, y, WALL_Z + 0.1)))
	for s: float in [1.0, -1.0]:
		add_child(MechParts.box(Vector3(0.3, LINTEL_Y, 0.25), GUNMETAL, Vector3(cx + s * (ALCOVE_HALF - 0.4), LINTEL_Y * 0.5, WALL_Z + 0.12)))
	add_child(MechParts.cylinder(0.12, LINTEL_Y - 1.0, HAZARD_BLACK, Vector3(cx + 1.4, (LINTEL_Y - 1.0) * 0.5 + 0.5, WALL_Z + 0.35), false, -1.0, 6))
	# Its light: a strip under the header and a lamp above the mech (dark while the alcove is empty).
	var strip := _glow(Vector3(w - 0.6, 0.1, 0.4), WORK_LIGHT, Vector3(cx, LINTEL_Y - 0.05, FRONT_Z - 0.6))
	add_child(strip)
	_alcove_strips.append(strip)
	var l := OmniLight3D.new()
	l.light_color = WORK_LIGHT
	l.omni_range = 9.0
	l.position = Vector3(cx, LINTEL_Y - 0.6, FRONT_Z + 0.6)
	l.shadow_enabled = true
	add_child(l)
	_alcove_lights.append(l)


## The breaching door on the left end wall: two armoured leaves in a striped frame, a red lamp and a strobe each side,
## a hazard band on the deck before it.
func _build_door() -> void:
	var dx := -HALF_WIDTH
	var dz := FRONT_Z + 9.0
	for side: float in [1.0, -1.0]:
		add_child(MechParts.box(Vector3(0.5, 7.8, 3.9), GUNMETAL_LIGHT, Vector3(dx + 0.25, 3.9, dz + side * 1.98)))
		add_child(MechParts.box(Vector3(0.2, 0.5, 2.6), GUNMETAL_DARK, Vector3(dx + 0.55, 2.0, dz + side * 1.98)))
		add_child(MechParts.box(Vector3(0.2, 0.5, 2.6), GUNMETAL_DARK, Vector3(dx + 0.55, 5.6, dz + side * 1.98)))
		_stripes(Vector3(dx + 0.3, 0, dz + side * 4.35), Vector3(dx + 0.3, 8.6, dz + side * 4.35), Vector3(0.5, 0, 0.7), 8)
		var lamp := MechParts.sphere(0.35, Color(0.3, 0.06, 0.04), Vector3(dx + 0.5, 7.0, dz + side * 5.4), 8)
		add_child(lamp)
		_door_lamps.append(lamp)
		var strobe := OmniLight3D.new()
		strobe.light_color = STROBE_AMBER
		strobe.omni_range = 9.0
		strobe.position = Vector3(dx + 1.2, 7.0, dz + side * 5.4)
		add_child(strobe)
		_strobes.append(strobe)
	add_child(MechParts.box(Vector3(0.1, 7.8, 0.08), HAZARD_BLACK, Vector3(dx + 0.52, 3.9, dz)))
	_stripes(Vector3(dx + 0.3, 8.95, dz - 4.7), Vector3(dx + 0.3, 8.95, dz + 4.7), Vector3(0.5, 0.7, 0), 10)
	_stripes(Vector3(dx + 2.0, 0.02, dz - 5.0), Vector3(dx + 2.0, 0.02, dz + 5.0), Vector3(2.2, 0.04, 0), 12)


## An ammunition rack standing against the wall, facing the aisle.
func _build_rack(at: Vector3) -> void:
	add_child(MechParts.box(Vector3(3.0, 4.4, 0.9), GUNMETAL_DARK, at + Vector3(0, 2.2, 0)))
	for row in 3:
		var y := 0.5 + float(row) * 1.35
		add_child(MechParts.box(Vector3(3.0, 0.12, 1.1), GUNMETAL_LIGHT, at + Vector3(0, y - 0.06, 0)))
		for i in 5:
			var p := at + Vector3(-1.1 + float(i) * 0.55, y + 0.4, 0.15)
			add_child(MechParts.cylinder(0.18, 0.8, BRASS, p, false, -1.0, 6))
			add_child(MechParts.cylinder(0.18, 0.3, BRASS, p + Vector3(0, 0.55, 0), false, 0.0, 6))


func _build_lights() -> void:
	# Work lights over the aisle (the alcoves have their own), and a soft fill from the camera's side.
	for p: Vector3 in [Vector3(-11.0, 9.5, 8.0), Vector3(0.0, 9.5, 8.0), Vector3(11.0, 9.5, 8.0), Vector3(-HALF_WIDTH + 3.0, 8.0, FRONT_Z + 9.0)]:
		var l := OmniLight3D.new()
		l.light_color = WORK_LIGHT
		l.omni_range = 15.0
		l.position = p
		add_child(l)
		_work_lights.append(l)
	var fill := OmniLight3D.new()
	fill.light_color = Color(0.7, 0.75, 0.85)
	fill.light_energy = 1.0
	fill.omni_range = 30.0
	fill.position = Vector3(0, 6.0, 20.0)
	add_child(fill)
	# Red beacons on the header, one over each post, sweeping the deck in alert; amber strobes at the row's ends.
	for p in 5:
		var at := Vector3((float(p) - 2.0) * PITCH, LINTEL_Y + 2.4, FRONT_Z + 0.4)
		var housing := MechParts.cylinder(0.35, 0.4, Color(0.3, 0.06, 0.04), at, false, -1.0, 8)
		add_child(housing)
		_beacon_housings.append(housing)
		var pivot := Node3D.new()
		pivot.position = at + Vector3(0, -0.3, 0.3)
		add_child(pivot)
		var spot := SpotLight3D.new()
		spot.light_color = ALERT_RED
		spot.spot_range = 22.0
		spot.spot_angle = 32.0
		spot.rotation = Vector3(deg_to_rad(-58.0), 0, 0)   # sweeping the deck below the pivot
		pivot.add_child(spot)
		_beacons.append(pivot)
		_beacon_lights.append(spot)
	for x: float in [-PITCH * 2.0 - 1.5, PITCH * 2.0 + 1.5]:
		var strobe := OmniLight3D.new()
		strobe.light_color = STROBE_AMBER
		strobe.omni_range = 10.0
		strobe.position = Vector3(x, LINTEL_Y + 1.0, FRONT_Z + 1.0)
		add_child(strobe)
		_strobes.append(strobe)


## Alternating yellow / black blocks from a to b. `thick` is each block's size across the run (the run axis is filled in).
func _stripes(a: Vector3, b: Vector3, thick: Vector3, n: int) -> void:
	var d := b - a
	var step := d / float(n)
	var size := thick + step.abs()
	for i in n:
		add_child(MechParts.box(size, HAZARD_YELLOW if i % 2 == 0 else HAZARD_BLACK, a + step * (float(i) + 0.5)))


func _glow(size: Vector3, c: Color, pos: Vector3) -> MeshInstance3D:
	var mi := MechParts.box(size, c, pos)
	mi.material_override = MechParts.mat(c, 1.0, true)
	return mi


# --- Lab ----------------------------------------------------------------------------------------------

func lab_params() -> Array:
	return [
		{"id": "beacon_speed", "label": "Beacon speed (rad/s)", "min": 0.5, "max": 6.0, "value": beacon_speed},
		{"id": "work_light", "label": "Work light energy", "min": 0.0, "max": 5.0, "value": work_energy},
		{"id": "alert_dim", "label": "Work light in alert (x)", "min": 0.0, "max": 1.0, "value": alert_dim},
	]


func set_lab_param(id: String, value: float) -> void:
	match id:
		"beacon_speed": beacon_speed = value
		"work_light": work_energy = value
		"alert_dim": alert_dim = value
	_apply_lights()


func lab_options() -> Array:
	return [
		{"id": "state", "label": "State", "choices": ["prep", "alert"], "value": state},
		{"id": "crew", "label": "Crew in the bay", "choices": ["1", "2", "3", "4"], "value": _lab_crew},
	]


func set_lab_option(id: String, value: String) -> void:
	match id:
		"state": set_alert(value == "alert")
		"crew":
			_lab_crew = value
			_show_lab_crew()


func _show_lab_crew() -> void:
	var heads := MechCatalog.HEAD_ORDER
	var entries: Array = []
	for i in clampi(int(_lab_crew), 1, 4):
		entries.append({"head": heads[i % heads.size()], "chassis": "strider", "name": "Pilot %d" % (i + 1),
			"accent": MechAccent.ORDER[i % MechAccent.ORDER.size()]})
	show_crew(entries)


## The centre of the occupied alcoves (the lab orbits it).
func lab_focus() -> Vector3:
	return frame_box().get_center()


## Half the hangar screen's camera distance for a 4:3 view (the lab starts at twice this, facing the wall, with room
## for its side panel and its steeper preset pitch).
func lab_radius() -> float:
	var t := camera_frame(1.33)
	var r := t.origin.distance_to(frame_box().get_center()) * 0.5
	# The "three" preset looks down 0.35 rad: keep that camera under the ceiling.
	return minf(r, (HEIGHT - 1.0 - lab_focus().y) / sin(0.35) * 0.5)


func lab_own_ground() -> bool:
	return true


func lab_own_lighting() -> bool:
	return true


## The preset views look at the wall from the aisle: the mechs face +Z (MECH_YAW), the lab's yaw 0 looks from -Z.
## Turned back by LAB_YAW_BACK so the default "three" view (yaw 0.75) opens almost square onto the wall (0.15 rad off);
## "front" then looks from the other side at 0.6 rad.
const LAB_YAW_BACK := 0.6

func lab_view_yaw() -> float:
	return MECH_YAW - LAB_YAW_BACK
