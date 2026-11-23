class_name PilotFace
extends RefCounted
## Base class of a pilot head definition: builds the rigid pieces and maps channels -> piece transforms
## (docs/design/pilot-heads.md sections 2-3). PilotHead owns the layers (moods, reactions, neck, idle); a definition only
## says what the head looks like and how its pieces move. One file per head under scripts/pilot/heads/, registered with
## one line in PilotHead.REGISTRY.
##
## THE HEAD-DEFINITION CONTRACT (what a new head file provides)
## 1. `extends PilotFace`, and in `_init()` set: `id` (the MechCatalog head id), `girth` (Vector3 scale baked into every
##    piece, e.g. MechHeadMeshes.GIRTH as Vector3(g, 1, g)), and optionally `style` (PilotNeck style keys: hz, damping,
##    upper, accel_gain, flair_hz, flair_damping, flair_inertia, pend_hz, pend_damping, step_deg, flair_raise,
##    flair_drop, footfall_gain), `pendulums` (how many pendulum springs PilotNeck runs: wattles, ears), `tics` (PilotIdle tic dicts),
##    `overrides` ({"moods": {id: {channel: v}}, "poses": {id: {...}}, "reactions": {id: {...}}}, see
##    PilotExpressions) and the mapping gains below (brow_turn, lid_skew_gain, jaw_open, ...).
## 2. `build_pieces()`: create every piece with `add_piece(name, parent, pivot)`; give each face / flair piece a mesh
##    with `add_mesh(name, k)`, where `k := kit()` is a MeshKit already scaled by `girth`.
##    COORDINATES: author every mesh AND every pivot in head-rest space, the same space as MechHeadMeshes: origin at the
##    neck base, -Z forward, +X the head's right, about 1.2 tall, before girth. The piece's pivot is the point it rotates
##    / scales about; `add_mesh` offsets the mesh so it lands where it was authored. Pivots carry no rest rotation, so a
##    piece's local axes are the head's axes.
##    STANDARD PIECES (all required, exact names): NeckLow (parent "" = the head root), NeckHigh (parent NeckLow),
##    Skull (parent NeckHigh; everything else hangs off it), BrowL, BrowR, LidL, LidR, PupilL, PupilR, Jaw. L = the
##    head's left (-X). `build_eye_set(...)` makes the six brow / lid / pupil pieces (and the eye discs into the skull
##    kit) from one eye position, like MechHeadMeshes._stern_eyes; a head with odd eyes builds its own and calls
##    `set_eye(...)` for each so the standard mapping knows its frame. Jaw: the lower beak / bill / muzzle / mouth plate,
##    pivot on the hinge, opening by rotating -X (tip down); put a dark mouth interior in the Skull behind it.
##    Flair pieces (comb, ears, husks, warts...) are any other names, listed in `flair_pieces`.
##    THE BODY IS ONE MESH (user bug 2026-11-22, a neck seam on teammates' heads): NeckLow, NeckHigh and Skull are
##    joints with NO mesh of their own. Author the whole neck-and-skull surface as ONE loft in a `kit()` (the shell:
##    every ring from the neck base, at y = 0, up to the crown, `cap_a` false, `cap_b` true; put a ring at each joint
##    pivot height, and more rings where the neck bends), close its base with `add_neck_plug(shell, base_ring)`, put
##    the skull's rigid extras (beak / bill / snout / nose, eye discs, the dark mouth: anything that must not bend) in a
##    second `kit()`, and call `add_body(shell, extras)` once the three joints exist. PilotBody binds the shell's
##    vertices to the joints by rest height (`body_bend`, `body_skull_blend`) and re-poses it every frame, so the neck
##    can never open a seam; the extras ride the Skull rigidly. Never sleeve one rigid piece over another for the body.
##    REST POSE = STERN: author the brows, lids and mouth as they look at the stern mood (the static head's look). The
##    mapping moves pieces by (channel - stern value), so stern is exactly the authored mesh.
##    LOOK: true low poly, one flat colour per face (MeshKit), no textures, no blend shapes; the body's neck faces
##    stretch with the pose (flat normals re-derived every frame, so they stay faceted). Faces across the body and all
##    pieces: 150-210 (the collar plug's PLUG_FACES on top).
## 3. Optional hooks: `pose_flair(ch, neck, extra)` (move the flair pieces from neck.flair (hinge pitch, roll, radians,
##    relative to the head) and neck.pend[i] (pendulum pitch, roll), plus channels), `pose_extra(ch, neck, extra)` (head
##    specific channel uses: mouth_curve on a beak, a tongue...), `pose_neck(neck)` (only if the neck is not the standard
##    two joints + skull squash, e.g. the pickle's jelly body). Use `set_pose(name, basis, offset)`: the piece's rest
##    transform with a basis and an offset (head-rest units, after girth).
##    `extra` carries "time" (head seconds), "drift" (0..1 dazed pupil drift), "tremble" (0..1).
## Flush: the body and every piece mesh get this head's own copy of the shared matte material (MechMeshes) as surface 0 override;
## `flush` mixes every face colour toward `flush_red` (+) or `flush_pale` (-) by lowering the albedo and adding the
## target as flat emission: it reads on dark heads (duck, pickle) as on light ones, faces keep their per-facet shading,
## and it works in every renderer. `add_mesh(name, k, false)` keeps a piece out of the flush (pupils). The *_mix gains
## are how far each goes at full strength. (A grey tint for disabled heads was dropped by the user, 2026-11-22.)
## Cosmetic only (Net.LOCAL).

## The smallest lid shutter scale (fully open: a sliver along the top of the eye, never a degenerate basis).
const LID_MIN := 0.04
## Tint: the most any mix takes of the face colour, and the emission scale that matches a lit face's brightness.
const MAX_MIX := 0.85
const TINT_LIGHT := 0.7

const STANDARD: Array[String] = ["NeckLow", "NeckHigh", "Skull", "BrowL", "BrowR", "LidL", "LidR", "PupilL", "PupilR",
	"Jaw"]
## The neck seal (docs/design/pilot-heads.md section 4): the body continues below the neck base as a tapered, capped
## collar plug PLUG_DEPTH deep (head-rest units, bound to NeckLow), so in the cockpit the neck's bottom never shows,
## however the rig leans (tests/test_pilot_neck_seal.gd). Standalone it reads as a dark collar under the neck.
const PLUG_DEPTH := 0.18
const PLUG_TAPER := 0.72
const COLLAR := Color(0.21, 0.22, 0.24)
const PLUG_FACES := 14
## The push lean's lever (NeckHigh's joint height, at least this) and NeckLow's tilt cap (pose_neck_joints).
const PUSH_LEVER_MIN := 0.25
const LOW_TILT_MAX := deg_to_rad(24.0)

# --- Set by the definition in _init() ---
var id := ""
var girth := Vector3.ONE
var style := {}
var pendulums := 0
var tics: Array = []
var overrides := {}
var flair_pieces: Array[String] = []
## Mapping gains.
var brow_turn := 38.0           ## degrees of brow roll per unit of brow_anger
var brow_lift := 0.065          ## metres per unit of brow_raise
var brow_skew_lift := 0.09      ## metres per unit of brow_skew (one up, one down)
var brow_lift_out := 1.0        ## a raised brow also moves this much out of the face per metre up (the skull curves back
                                ## above the eyes, so a straight lift would bury it)
var lid_skew_gain := 0.45       ## lid asymmetry per unit of brow_skew (pain: one eye shut, one wide)
var lid_tilt := 10.0            ## degrees the lid line tilts with brow_anger (angry squint / worried)
var jaw_open := 28.0            ## degrees at jaw = 1
var pupil_range := Vector2(0.45, 1.7)   ## pupil scale at pupil_size -1 and +1
var gaze_reach := 0.03          ## metres of pupil travel at gaze 1
var squash_width := 0.5         ## skull widening per unit of squash
var flush_red := Color(0.86, 0.2, 0.14)    ## the colour a full red flush mixes toward
var flush_pale := Color(0.84, 0.9, 1.0)     ## a full pale flush (afraid)
var red_mix := 0.6
var pale_mix := 0.5
var tint_enabled := true        ## flush on (the lab toggles it to compare)
## The body's bend (PilotBody.weights_at, head-rest heights): the NeckLow -> NeckHigh weight ramps linearly from
## body_bend.x to body_bend.y (set it to the whole neck, below any face piece), the skull's squash blends in across
## body_skull_blend below the Skull's pivot.
var body_bend := Vector2(0.0, 0.5)
var body_skull_blend := 0.12

# --- Built ---
var head: Node3D
## The one continuous neck-and-skull mesh (add_body).
var body: PilotBody
var rest := {}                  ## the stern channel row
var eyes: Array[Dictionary] = [{}, {}]   ## [left, right]: p, o, across, up, right, upv (head-rest, after girth), travel
var material: StandardMaterial3D
var _pieces := {}
var _pivots := {}
var _rest_xf := {}
var _flush := 0.0
var _flash := 0.0


## Builds every piece under `h`. Called once by PilotHead.
func build(h: Node3D) -> void:
	head = h
	rest = PilotExpressions.mood_row("stern", overrides)
	material = (MechMeshes.materials()[0] as StandardMaterial3D).duplicate() as StandardMaterial3D
	build_pieces()
	for n: String in STANDARD:
		if not _pieces.has(n):
			push_error("PilotFace %s: missing standard piece %s" % [id, n])
	if body == null:
		push_error("PilotFace %s: no body (add_body)" % id)


## Override: build the pieces (see the contract).
func build_pieces() -> void:
	pass


## A MeshKit scaled by `girth`: author in head-rest space.
func kit() -> MeshKit:
	var k := MeshKit.new()
	k.push(MeshKit.xf(Vector3.ZERO, Vector3.ZERO, girth))
	return k


## The collar plug under the body shell's open base ring `base` (an 8-point ring, head-rest space before girth, the first
## ring of the shell's loft) into `k` (the shell kit): a COLLAR-coloured frustum down to a 4-point ring PLUG_DEPTH lower
## and PLUG_TAPER as wide, capped, sharing the base ring's vertices so the body is closed (PLUG_FACES triangles).
func add_neck_plug(k: MeshKit, base: PackedVector3Array) -> void:
	var n := base.size()
	var c := MeshKit.centroid(base)
	var inner := c + Vector3(0.0, -PLUG_DEPTH * 0.5, 0.0)
	var q := PackedVector3Array()
	for j in n / 2:
		q.append(c + (base[j * 2] - c) * Vector3(PLUG_TAPER, 0.0, PLUG_TAPER) + Vector3(0.0, -PLUG_DEPTH, 0.0))
	var m := q.size()
	for j in m:
		var b0 := base[j * 2]
		var b1 := base[j * 2 + 1]
		var b2 := base[(j * 2 + 2) % n]
		k.tri(b0, b1, q[j], COLLAR, inner)
		k.tri(b1, q[(j + 1) % m], q[j], COLLAR, inner)
		k.tri(b1, b2, q[(j + 1) % m], COLLAR, inner)
	k.poly(q, COLLAR, inner)


## A pivot node named `piece_name` under `parent` ("" = the head root) at `pivot` (head-rest space, before girth).
func add_piece(piece_name: String, parent: String, pivot: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = piece_name
	var p := pivot * girth
	var parent_node: Node3D = head if parent == "" else _pieces[parent]
	var parent_pivot: Vector3 = Vector3.ZERO if parent == "" else _pivots[parent]
	n.position = p - parent_pivot
	parent_node.add_child(n)
	_pieces[piece_name] = n
	_pivots[piece_name] = p
	_rest_xf[piece_name] = n.transform
	return n


## The one body mesh (see the contract): `shell` = the continuous neck-and-skull loft + the collar plug, `extras` = the
## skull's rigid extras, both authored in head-rest space with `kit()`. Needs NeckLow, NeckHigh and Skull; hangs under
## the Skull joint (PilotBody), in the flush.
func add_body(shell: MeshKit, extras: MeshKit) -> PilotBody:
	var pv: Array[Vector3] = []
	for n: String in PilotBody.JOINTS:
		if not _pivots.has(n):
			push_error("PilotFace %s: add_body needs the joint %s first" % [id, n])
			return null
		pv.append(_pivots[n])
	body = PilotBody.new()
	body.setup(self, shell, extras, pv, body_bend, body_skull_blend)
	body.set_surface_override_material(0, material)
	(_pieces["Skull"] as Node3D).add_child(body)
	return body


## The mesh of a piece, from a kit authored in head-rest space. `flush` false keeps it out of the colour flush.
func add_mesh(piece_name: String, k: MeshKit, flush: bool = true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = piece_name + "_mesh"
	mi.mesh = k.commit(MechMeshes.materials())
	mi.position = -(_pivots[piece_name] as Vector3)
	if flush:
		mi.set_surface_override_material(0, material)
	(_pieces[piece_name] as Node3D).add_child(mi)
	return mi


func piece(piece_name: String) -> Node3D:
	return _pieces.get(piece_name)


func piece_names() -> Array[String]:
	var out: Array[String] = []
	for k: String in _pieces:
		out.append(k)
	return out


## Sets a piece to its rest transform with `basis` and `offset` (head-rest units after girth) applied.
func set_pose(piece_name: String, basis: Basis, offset: Vector3 = Vector3.ZERO) -> void:
	var n: Node3D = _pieces.get(piece_name)
	if n == null:
		return
	var r: Transform3D = _rest_xf[piece_name]
	n.transform = Transform3D(basis * r.basis, r.origin + offset)


## Registers an eye's frame for the standard mapping. side -1 = left, 1 = right; p / o / across / up in head-rest space
## before girth (o out of the face, across toward the temple, up along the face); travel = the height of the lid plate
## authored shut, centred on its pivot (before girth): the lid opens by shrinking along `up` toward its top edge.
func set_eye(side: float, p: Vector3, o: Vector3, across: Vector3, up: Vector3, travel: float) -> void:
	var os := (o / girth).normalized()
	var ups := (up * girth)
	var e := {"side": side, "p": p * girth, "o": os, "across": (across * girth), "up": ups.normalized(),
		"travel": travel * ups.length()}
	e["right"] = (Vector3.RIGHT - os * os.dot(Vector3.RIGHT)).normalized()
	e["upv"] = (Vector3.UP - os * os.dot(Vector3.UP)).normalized()
	eyes[0 if side < 0.0 else 1] = e


## The standard stern eyes (MechHeadMeshes._stern_eyes, rigged): per side a dark eye disc (into `skull`, the Skull's
## kit), and the pieces PupilL/R (a pupil), LidL/R (a lid plate, skin coloured, authored shut, shrunk toward its top
## edge by the lid amount) and BrowL/R (a heavy brow wedge, low at the nose and high at the temple). `at` is the right eye on the
## face, `out` the way the face points there (both mirrored for the left), in head-rest space before girth.
## Colours: "brow", "lid", "iris" (the eye disc), "pupil", optional "white" (an eye-white ring behind the iris).
## Sizes scale with `size`; "eye" (iris radius), "pupil" (radius), "brow" (Vector2 half-sizes at the inner end).
func build_eye_set(skull: MeshKit, at: Vector3, out: Vector3, size: float, colours: Dictionary, dims: Dictionary = {}) -> void:
	var eye_r := float(dims.get("eye", 0.065)) * size
	var pupil_r := float(dims.get("pupil", 0.03)) * size
	var brow_in: Vector2 = dims.get("brow", Vector2(0.058, 0.062)) * size
	for side: float in [-1.0, 1.0]:
		var sfx := "L" if side < 0.0 else "R"
		var m := Vector3(side, 1, 1)
		var p := at * m
		var o := (out * m).normalized()
		var across := o.cross(Vector3.UP).normalized() * side   # toward the temple
		var up := across.cross(o).normalized() * side
		# The eye disc (and an optional white) on the skull.
		if colours.has("white"):
			skull.poly(MeshKit.ring_uv(p + o * 0.028, across * eye_r * 1.45, up * eye_r * 1.05, 6, 2.0, 0.0),
				colours["white"], p - o)
		skull.poly(MeshKit.ring_uv(p + o * 0.035, across * eye_r, up * eye_r, 6, 2.0, 0.0), colours["iris"], p - o)
		# Pupil.
		var pc := p + o * 0.045 - across * 0.01 * size
		add_piece("Pupil" + sfx, "Skull", pc)
		var kp := kit()
		kp.poly(MeshKit.ring_uv(pc, across * pupil_r, up * pupil_r, 4, 2.0, 0.0), colours["pupil"], pc - o)
		add_mesh("Pupil" + sfx, kp, false)
		# Lid: a plate authored shut over the eye, its lid line sloping down to the nose like the stern brow; it shrinks up
		# toward its top edge as it opens (a shutter), so it never leaves the eye.
		var lid_h := eye_r * 1.25
		var tilt := Basis(o, -deg_to_rad(9.0) * side)
		var lc := p + o * 0.052
		add_piece("Lid" + sfx, "Skull", lc)
		var kl := kit()
		var lid_pts := MeshKit.ring_uv(lc, tilt * across * eye_r * 1.35, tilt * up * lid_h, 4, MeshKit.SQUARE, 0.5)
		kl.poly(lid_pts, colours["lid"], lc - o)
		add_mesh("Lid" + sfx, kl)
		set_eye(side, p, o, across, up, lid_h * 2.0)
		# Brow: a heavy four-sided wedge over the eye, low at the nose, high at the temple, hugging the face.
		var inner := p - across * 0.11 * size + up * 0.02 * size + o * 0.04
		var outer := p + across * 0.1 * size + up * 0.15 * size - o * 0.03
		var bc := (inner + outer) * 0.5
		add_piece("Brow" + sfx, "Skull", bc)
		var kb := kit()
		kb.seg(inner, outer, brow_in, brow_in * 0.68, 4, colours["brow"], 2.0, true, 0.0)
		add_mesh("Brow" + sfx, kb)
	# The lids start at the stern amount.
	_pose_lids(rest)


## Applies one frame: neck, face, flair, extras, flush. Called by PilotHead after every step.
func pose(ch: Dictionary, neck: PilotNeck, extra: Dictionary) -> void:
	pose_neck(neck)
	_pose_brows(ch)
	_pose_lids(ch)
	_pose_pupils(ch, extra)
	set_pose("Jaw", Basis(Vector3.RIGHT, -deg_to_rad(jaw_open) * clampf(float(ch["jaw"]), 0.0, 1.0)))
	pose_flair(ch, neck, extra)
	pose_extra(ch, neck, extra)
	_pose_flush(float(ch["flush"]))
	if body != null:
		body.update()


## The standard neck: two joints (pose_neck_joints: the sink / push shift, sealed), the skull squash.
func pose_neck(neck: PilotNeck) -> void:
	pose_neck_joints(neck.low, neck.high, neck.shift.x, neck.shift.y)
	var sq := neck.squash
	set_pose("Skull", Basis.from_scale(Vector3(1.0 + sq * squash_width, 1.0 - sq, 1.0 + sq * squash_width)))


## NeckLow and NeckHigh with the neck seal (docs/design/pilot-heads.md section 4): NeckLow's base stays anchored in the
## hatch. `sink` (+ = down) slides it along its axis (the collar plug covers the rise); `push` (+ = forward) is not a
## slide but a lean about the base, by the angle that carries NeckHigh's joint forward by `push`, and NeckHigh turns back
## by the same angle so the head keeps its attitude. NeckLow's pitch / roll are capped at LOW_TILT_MAX; the excess moves up
## to NeckHigh (same total, the bend just sits higher). `low` / `high` (pitch, yaw, roll) rad; `high_offset` an extra
## NeckHigh slide (the duck's stretch).
func pose_neck_joints(low: Vector3, high: Vector3, sink: float, push: float, high_offset: Vector3 = Vector3.ZERO) -> void:
	var lever := maxf(float((_pivots.get("NeckHigh", Vector3.UP * 0.3) as Vector3).y), PUSH_LEVER_MIN)
	var lean := atan(push / lever)
	var want := low + Vector3(-lean, 0.0, 0.0)
	var capped := Vector3(clampf(want.x, -LOW_TILT_MAX, LOW_TILT_MAX), want.y, clampf(want.z, -LOW_TILT_MAX, LOW_TILT_MAX))
	set_pose("NeckLow", Basis.from_euler(capped), Vector3(0.0, -sink, 0.0))
	set_pose("NeckHigh", Basis.from_euler(high + Vector3(lean, 0.0, 0.0) + (want - capped)), high_offset)


## Override: flair pieces.
func pose_flair(_ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	pass


## Override: head-specific channel uses.
func pose_extra(_ch: Dictionary, _neck: PilotNeck, _extra: Dictionary) -> void:
	pass


func _pose_brows(ch: Dictionary) -> void:
	var anger := float(ch["brow_anger"]) - float(rest["brow_anger"])
	var raise := float(ch["brow_raise"]) - float(rest["brow_raise"])
	var skew := float(ch["brow_skew"]) - float(rest["brow_skew"])
	for i in 2:
		var e := eyes[i]
		if e.is_empty():
			continue
		var side := float(e["side"])
		var lift := raise * brow_lift - side * skew * brow_skew_lift
		# Rolled about the face normal: + anger = inner (nose) ends down.
		set_pose("Brow" + ("L" if i == 0 else "R"), Basis(e["o"], -deg_to_rad(brow_turn) * anger * side),
			(e["up"] as Vector3) * lift + (e["o"] as Vector3) * maxf(lift, 0.0) * brow_lift_out)


func _pose_lids(ch: Dictionary) -> void:
	var anger := float(ch["brow_anger"]) - float(rest["brow_anger"])
	for i in 2:
		var e := eyes[i]
		if e.is_empty():
			continue
		var side := float(e["side"])
		var lid := clampf(float(ch["lid"]) + side * float(ch["brow_skew"]) * lid_skew_gain, 0.0, 1.0)
		var tilt := Basis(e["o"], -deg_to_rad(lid_tilt) * anger * side)
		# A shutter: the plate (authored shut, `travel` tall) scales along `up` toward its top edge, which stays put.
		var u: Vector3 = e["up"]
		var k := maxf(lid, LID_MIN) - 1.0
		var shut := Basis(Vector3.RIGHT + u * (u.x * k), Vector3.UP + u * (u.y * k), Vector3.BACK + u * (u.z * k))
		var b := tilt * shut
		var top := u * float(e["travel"]) * 0.5
		set_pose("Lid" + ("L" if i == 0 else "R"), b, top - b * top)


func _pose_pupils(ch: Dictionary, extra: Dictionary) -> void:
	var s := float(ch["pupil_size"])
	var scl := lerpf(1.0, pupil_range.y, s) if s >= 0.0 else lerpf(1.0, pupil_range.x, -s)
	var drift := float(extra.get("drift", 0.0))
	var t := float(extra.get("time", 0.0))
	for i in 2:
		var e := eyes[i]
		if e.is_empty():
			continue
		var g := Vector2(float(ch["gaze_x"]), float(ch["gaze_y"]))
		if drift > 0.0:   # dazed: slow circles, opposite directions per eye
			var a := t * 2.2 * (1.0 if i == 0 else -1.0)
			g += Vector2(cos(a), sin(a)) * drift
		g = g.limit_length(1.0)
		var off := ((e["right"] as Vector3) * g.x + (e["upv"] as Vector3) * g.y) * gaze_reach
		set_pose("Pupil" + ("L" if i == 0 else "R"), Basis.from_scale(Vector3.ONE * scl), off)


func _pose_flush(f: float) -> void:
	if absf(f - _flush) < 0.005:
		return
	_flush = f
	_apply_tint()


## The effects' white flash (PilotFx), 0..1, on top of the flush.
func set_flash(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if absf(v - _flash) < 0.001:
		return
	_flash = v
	_apply_tint()


## Flush on / off (the lab compares them; the flash is an effect and follows fx instead).
func set_tint_enabled(on: bool) -> void:
	tint_enabled = on
	_apply_tint()


## Where a point carried by a piece is now, in the head root's local space; `p` in head-rest units after girth (the
## space of the meshes and of `eyes`). Effects and the lab use it.
func carried(piece_name: String, p: Vector3) -> Vector3:
	var n: Node3D = _pieces.get(piece_name)
	if n == null:
		return p
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != head:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t * (p - (_pivots[piece_name] as Vector3))


## colour = lerp(face colour, target, w): the albedo (which multiplies the flat vertex colours) drops to 1 - w and the
## target comes back as flat emission (x TINT_LIGHT, about how bright a lit face is), so a dark green face reddens
## instead of going black. The flash adds white on top. Faces stay flat-shaded in every renderer.
func _apply_tint() -> void:
	var f := _flush if tint_enabled else 0.0
	var wr := maxf(f, 0.0) * red_mix
	var wp := maxf(-f, 0.0) * pale_mix
	var w := wr + wp
	if w > MAX_MIX:
		var k := MAX_MIX / w
		wr *= k
		wp *= k
		w = MAX_MIX
	var emi := (flush_red * wr + flush_pale * wp) * TINT_LIGHT + Color.WHITE * _flash * 0.9
	material.albedo_color = Color(1.0 - w, 1.0 - w, 1.0 - w)
	material.emission_enabled = emi.r + emi.g + emi.b > 0.003
	material.emission = emi
