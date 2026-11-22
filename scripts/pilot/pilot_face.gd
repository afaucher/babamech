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
## 2. `build_pieces()`: create every piece with `add_piece(name, parent, pivot)` and give it a mesh with
##    `add_mesh(name, k)`, where `k := kit()` is a MeshKit already scaled by `girth`.
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
##    REST POSE = STERN: author the brows, lids and mouth as they look at the stern mood (the static head's look). The
##    mapping moves pieces by (channel - stern value), so stern is exactly the authored mesh.
##    LOOK: true low poly, one flat colour per face (MeshKit), no textures, no blend shapes, no skinning. Faces across all
##    pieces: 150-210.
## 3. Optional hooks: `pose_flair(ch, neck, extra)` (move the flair pieces from neck.flair (hinge pitch, roll, radians,
##    relative to the head) and neck.pend[i] (pendulum pitch, roll), plus channels), `pose_extra(ch, neck, extra)` (head
##    specific channel uses: mouth_curve on a beak, a tongue...), `pose_neck(neck)` (only if the neck is not the standard
##    two joints + skull squash, e.g. the pickle's jelly body). Use `set_pose(name, basis, offset)`: the piece's rest
##    transform with a basis and an offset (head-rest units, after girth).
##    `extra` carries "time" (head seconds), "drift" (0..1 dazed pupil drift), "tremble" (0..1).
## Flush: every piece mesh gets this head's own copy of the shared matte material (MechMeshes) as surface 0 override;
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

# --- Built ---
var head: Node3D
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


## Override: build the pieces (see the contract).
func build_pieces() -> void:
	pass


## A MeshKit scaled by `girth`: author in head-rest space.
func kit() -> MeshKit:
	var k := MeshKit.new()
	k.push(MeshKit.xf(Vector3.ZERO, Vector3.ZERO, girth))
	return k


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


## The standard neck: two joints, the sink / push shift on the lower one, the skull squash.
func pose_neck(neck: PilotNeck) -> void:
	set_pose("NeckLow", Basis.from_euler(neck.low), Vector3(0.0, -neck.shift.x, -neck.shift.y))
	set_pose("NeckHigh", Basis.from_euler(neck.high))
	var sq := neck.squash
	set_pose("Skull", Basis.from_scale(Vector3(1.0 + sq * squash_width, 1.0 - sq, 1.0 + sq * squash_width)))


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
