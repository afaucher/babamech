extends TestCase
## The pilot's head and neck are ONE closed mesh and stay sealed in the cockpit (docs/design/pilot-heads.md section 2,
## "One mesh", and section 4, "Neck seal"). On a real MechModel, for every head (at two head scales):
## 1. ONE MESH: the neck-and-skull body is a single PilotBody surface under the Skull joint, the joints carry no mesh of
##    their own, and its shell (collar plug, lower neck, upper neck, skull) is closed at rest (no boundary edge from the
##    plug's bottom cap to the crown).
## 2. CLOSED IN EVERY POSE: driven through the worst poses the rig reaches LOCALLY (full acceleration lean each way, hard
##    turns, a hard landing and its rebound, the strongest flinch from each side, looks to the neck limits, every idle tic,
##    every mood, stacked combinations) and then the way a TEAMMATE'S PUPPET feeds it (velocity steps of a teleport,
##    single-frame yaw-rate spikes of a heading jump, 30 Hz stepped velocity and yaw rate, an extrapolation correction,
##    hard stream-drop flinches every 0.5 s from alternating sides, a designator look flicking side to side), measured
##    on the DEFORMED vertices actually written to the mesh every frame: every welded rest vertex stays one point (the
##    widest split of any vertex group, GAP_MAX), and at the end of every segment the deformed shell has no boundary edge.
##    No shell face collapses (each keeps MIN_AREA of its rest area) or turns inside out (its normal against its rest
##    normal carried by its dominant joint stays above MIN_FACING).
## 3. BEND LIMITS: the joints' rotation angles stay within LOW_MAX (NeckLow vs the head root), HIGH_MAX (NeckHigh vs
##    NeckLow) and TOTAL_MAX (the skull's attitude, NeckLow x NeckHigh, vs the head root), locally and on puppet inputs,
##    and the puppet's stepped / spiky / teleport inputs never shake the skull harder (degrees of turn per 60 Hz frame)
##    than the local input steps do (+ JITTER_OVER): PilotHead's input guard.
## 4. THE SEAL: the plug's bottom loop stays MARGIN below the hatch floor (hatch frame, rim at y = RIM_Y) and inside the
##    hull in every pose.
## Prints per head: the worst exposure (hatch units, + = above the rim), the bend envelopes (local / puppet), the worst
## vertex split, face area and facing, and the worst per-frame skull turn on puppet inputs.

const RIM_Y := 0.1          ## MechMeshes._hatch: the rim's top at y = 0.1 in the hatch's frame
const OPENING := 0.4        ## and the opening's inner radius
const FLOOR_Y := -0.04      ## and its dark floor disc, which covers the whole opening: below it nothing shows
const MARGIN := 0.02        ## the base loop's highest point stays at least this far below the floor (0.16 below the rim)
const DT := 1.0 / 60.0
## Bend limits (degrees). From the rig: PilotNeck caps each joint's pitch / yaw / roll at its share (NeckLow 0.4, NeckHigh
## 0.6) of 35 / 70 / 30, pose_neck_joints caps NeckLow's tilt at 24 and moves the push lean (up to atan(0.15 / 0.25) =
## 31) and the excess up to NeckHigh, the duck's slump adds 20 there. Measured worst (2026-11-22): NeckLow 33.3,
## NeckHigh 55.7 (duck, dazed + hit on puppet inputs), total 82.4; smallest face 0.28 of its rest area (pickle stalk),
## worst facing 0.64.
const LOW_MAX := 40.0
const HIGH_MAX := 65.0
const TOTAL_MAX := 90.0
const JITTER_OVER := 1.0
const GAP_MAX := 1e-5       ## head-rest units: a welded vertex group's widest split (exactly 0 by construction)
const MIN_AREA := 0.2
const MIN_FACING := 0.3
const FACE_EVERY := 3       ## frames between face shape checks (closure is checked every frame)

var _worst := {}


func setup() -> void:
	timeout_sec = 240.0
	for id: String in PilotHead.ids():
		for head_scale: float in [1.15, 1.5]:
			await _check_head(id, head_scale)
	finish()


func _check_head(id: String, head_scale: float) -> void:
	var m := MechModel.new()
	m.configure(id, "strider", {})
	add_child(m)
	m.set_lab_param("head", head_scale)
	await frames(1)
	var p := m.pilot
	var hatch := m.find_child("Hatch", true, false) as Node3D
	if not check(p != null and hatch != null, "%s: mech with a pilot and a hatch" % id):
		m.queue_free()
		return
	p.fx_enabled = false
	p.idle_always = false
	var body := p.face.body
	var tag := "%s@%.2f" % [id, head_scale]
	if not check(body != null and body.get_parent() == p.piece("Skull"), "%s: one body mesh under the Skull joint" % tag):
		m.queue_free()
		return
	if head_scale == 1.15:
		_check_one_mesh(id, p, body)
	var ctx := _context(p, hatch, body, tag)
	_worst[tag] = {"up": -1e9, "out": 0.0, "pose": "", "ring_up": -1e9, "ext": {}, "gap": 0.0, "gap_pose": "",
		"area": 1e9, "area_pose": "", "facing": 1e9, "facing_pose": "", "open": 0, "open_pose": "",
		"env": {"local": Vector3.ZERO, "puppet": Vector3.ZERO}, "env_pose": {"local": ["", "", ""], "puppet": ["", "", ""]},
		"jitter": {"local": 0.0, "puppet": 0.0}, "jitter_pose": {"local": "", "puppet": ""}, "area_y": 0.0}
	ctx["mode"] = "local"
	ctx["track_jitter"] = true   # the local input steps (accel / stop / turn / landing): the reference for the puppet's
	_measure(ctx, "rest", true)
	await _drive_local(ctx)
	ctx["mode"] = "puppet"
	p.neck.reset()
	_drive(ctx, "settle", 1.0, {})
	await _drive_puppet(ctx)
	_report(m, hatch, tag, head_scale)
	m.queue_free()
	await frames(1)


## 1: one body surface, joints without meshes, the rest shell closed.
func _check_one_mesh(id: String, p: PilotHead, body: PilotBody) -> void:
	eq(body.mesh.get_surface_count(), 1, "%s: the body is one mesh surface" % id)
	for j: String in PilotBody.JOINTS:
		var own := 0
		for c in p.piece(j).get_children():
			if c is MeshInstance3D and c != body:
				own += 1
		eq(own, 0, "%s: the %s joint carries no mesh of its own" % [id, j])
	eq(_open_edges(body.rest, body.shell_faces), 0, "%s: the body's shell is closed at rest, plug cap to crown" % id)
	check(body.shell_faces >= 80, "%s: the shell is the whole neck and skull (%d faces)" % [id, body.shell_faces])
	var lo := 1e9
	var hi := -1e9
	for i in body.shell_faces * 3:
		lo = minf(lo, body.rest[i].y)
		hi = maxf(hi, body.rest[i].y)
	check(lo <= -PilotFace.PLUG_DEPTH + 0.001 and hi > 1.0, "%s: the shell runs from the plug's bottom (%.2f) to the crown (%.2f)"
		% [id, lo, hi])


func _context(p: PilotHead, hatch: Node3D, body: PilotBody, tag: String) -> Dictionary:
	var n := body.shell_faces * 3
	var lo := 1e9
	for i in n:
		lo = minf(lo, body.rest[i].y)
	var base := PackedInt32Array()
	var ring := PackedInt32Array()
	var groups := {}
	for i in n:
		var v := body.rest[i]
		if v.y <= lo + 0.005:
			base.append(i)
		if absf(v.y) < 0.002:
			ring.append(i)
		var k := _q(v)
		if not groups.has(k):
			groups[k] = PackedInt32Array()
		(groups[k] as PackedInt32Array).append(i)
	var welded: Array[PackedInt32Array] = []
	for k: String in groups:
		if (groups[k] as PackedInt32Array).size() > 1:
			welded.append(groups[k])
	var areas := PackedFloat32Array()
	var dom := PackedInt32Array()
	for f in body.shell_faces:
		var a := body.rest[f * 3]
		areas.append((body.rest[f * 3 + 2] - a).cross(body.rest[f * 3 + 1] - a).length())
		var w := body.weights[f * 3] + body.weights[f * 3 + 1] + body.weights[f * 3 + 2]
		dom.append(0 if w.x >= w.y and w.x >= w.z else (1 if w.y >= w.z else 2))
	return {"p": p, "hatch": hatch, "body": body, "tag": tag, "base": base, "ring": ring, "welded": welded,
		"areas": areas, "dom": dom, "frame": 0, "prev_skull": Basis(), "track_jitter": false}


func _drive_local(ctx: Dictionary) -> void:
	var p: PilotHead = ctx["p"]
	# Acceleration lean: a step in velocity each way (the neck's input saturates), then the stop.
	for d: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		_drive(ctx, "accel " + str(d), 0.7, {"vel": d * 25.0})
		_drive(ctx, "stop " + str(d), 0.9, {"vel": Vector3.ZERO})
	# Hard turns, both ways, at the rig's rates and at the guard's cap.
	for yr: float in [3.0, -3.0, PilotHead.YAW_RATE_MAX, -PilotHead.YAW_RATE_MAX]:
		_drive(ctx, "turn %.0f" % yr, 0.8, {"yaw_rate": yr})
		_drive(ctx, "unturn", 0.6, {})
	_drive(ctx, "turn+accel", 0.8, {"yaw_rate": 3.0, "vel": Vector3.FORWARD * 25.0})
	_drive(ctx, "settle", 0.8, {})
	# A hard landing: airborne falling fast, then grounded (impact + flinch, squash and rebound).
	_drive(ctx, "fall", 0.3, {"grounded": false, "vel": Vector3(0, -20, 0)})
	_drive(ctx, "land", 1.2, {"grounded": true})
	ctx["track_jitter"] = false
	# The strongest flinch from each side.
	for d: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT, Vector3.UP, Vector3.DOWN]:
		p.react_hit(d, 1.0)
		_drive(ctx, "hit " + str(d), 1.2, {})
	# Looks to the limits (and past them).
	var eye := p.global_transform * Vector3(0, PilotHead.EYE_HEIGHT, 0)
	for d: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.BACK,
			Vector3(1, 1, 0), Vector3(-1, -1, -1)]:
		p.look_at_point(eye + p.global_transform.basis * d * 50.0)
		_drive(ctx, "look " + str(d), 1.0, {})
	p.clear_look()
	# Moods (sink, push, roll, sway), each held, with a flinch from behind on top.
	for mood: String in PilotHead.moods():
		p.set_mood(mood)
		_drive(ctx, "mood " + mood, 1.5, {})
		p.react_hit(Vector3.BACK, 1.0)
		_drive(ctx, "mood %s + hit" % mood, 1.0, {"vel": Vector3.FORWARD * 25.0})
	p.clear_mood()
	_drive(ctx, "settle", 1.0, {})
	# Every reaction at full strength.
	for r: String in PilotHead.reactions():
		p.react(r, 1.5, Vector3.LEFT)
		_drive(ctx, "react " + r, 1.5, {})
	# Idle tics (idle on for these; the glances and blinks come along).
	p.idle_enabled = true
	for t: String in p.tics():
		p.play_tic(t)
		_drive(ctx, "tic " + t, 3.5, {})
	p.idle_enabled = false
	# Stacked: afraid + max forward lean + a landing + a hit from the front + looking down.
	p.set_mood("afraid")
	_drive(ctx, "afraid", 1.0, {})
	p.look_at_point(eye + p.global_transform.basis * Vector3(0, -1, -0.3) * 50.0)
	_drive(ctx, "stack fall", 0.3, {"grounded": false, "vel": Vector3(0, -20, -25)})
	p.react_hit(Vector3.FORWARD, 1.0)
	_drive(ctx, "stack land", 1.5, {"grounded": true, "vel": Vector3.ZERO})
	p.set_mood("dazed")
	p.look_at_point(eye + p.global_transform.basis * Vector3(1, 0, 0.2) * 50.0)
	_drive(ctx, "stack dazed", 1.0, {"vel": Vector3.RIGHT * 25.0, "yaw_rate": -PilotHead.YAW_RATE_MAX})
	p.clear_mood()
	p.clear_look()
	await frames(1)


## A teammate's puppet: what MechRig hands the head from 30 Hz snapshots (velocity and heading interpolated, stepped
## at worst; extrapolated then corrected; jumping on a respawn) plus PilotPuppetLink's stream flinches and looks.
func _drive_puppet(ctx: Dictionary) -> void:
	var p: PilotHead = ctx["p"]
	var run := Vector3.FORWARD * 11.0          # a full run, in model units / s (22 m/s / mech_scale 2)
	ctx["track_jitter"] = true   # input-driven shaking only: the flinch segments below snap on purpose
	# Teleports: running, then the respawn frame (velocity to rest, heading flipped: yaw rate PI / dt), and back.
	for k in 3:
		_drive(ctx, "puppet run", 0.5, {"vel": run})
		_drive(ctx, "puppet teleport", DT, {"vel": Vector3.ZERO, "yaw_rate": PI / DT})
		_drive(ctx, "puppet after teleport", 0.4, {})
		_drive(ctx, "puppet teleport mid-fall", DT, {"vel": Vector3(0, -20, 0) if k % 2 == 0 else Vector3(40, 0, -40),
			"grounded": k % 2 == 1, "yaw_rate": -PI / DT})
		_drive(ctx, "puppet after teleport 2", 0.4, {})
	# Single-frame yaw-rate spikes (heading jumps after a starve) while running.
	for i in 120:
		var spike := (PI * 0.5 / DT) * (1.0 if (i / 10) % 2 == 0 else -1.0) if i % 10 == 0 else 1.8
		_drive(ctx, "puppet yaw spikes", DT, {"vel": run, "yaw_rate": spike})
	# 30 Hz stepped velocity: a ramp to a run and a zigzag strafe, each value held two frames.
	for i in 120:
		var t := float(i - i % 2) * DT
		_drive(ctx, "puppet stepped ramp", DT, {"vel": run * minf(t, 1.0)})
	# (The zigzag reverses the strafe in one step, which no input does locally either: covered for the closure and the
	# bend, not compared for shaking.)
	ctx["track_jitter"] = false
	for i in 180:
		var t := float(i - i % 2) * DT
		_drive(ctx, "puppet stepped zigzag", DT, {"vel": run + Vector3.RIGHT * 11.0 * signf(sin(TAU * 2.0 * t))})
	_drive(ctx, "puppet settle", 1.0, {"vel": run})
	ctx["track_jitter"] = true
	# 30 Hz stepped yaw rate: a 1.8 rad/s turn shown as 3.6 / 0 on alternate frames.
	for i in 120:
		_drive(ctx, "puppet stepped turn", DT, {"vel": run, "yaw_rate": 3.6 if i % 2 == 0 else 0.0})
	# An extrapolation correction: 0.15 s turning on the last rate, then the late sample takes it all back in one frame.
	for k in 4:
		_drive(ctx, "puppet extrapolate", 0.15, {"vel": run, "yaw_rate": 1.8})
		_drive(ctx, "puppet correction", DT, {"vel": run * 0.5, "yaw_rate": -1.8 * 0.15 / DT})
	ctx["track_jitter"] = false
	# Hard stream flinches (PilotPuppetLink: at most one per STREAM_GAP), alternating sides, with pain, while running
	# stepped, and a designator look flicking side to side.
	var eye := p.global_transform * Vector3(0, PilotHead.EYE_HEIGHT, 0)
	for k in 8:
		var side := Vector3.LEFT if k % 2 == 0 else Vector3.RIGHT
		p.react_hit(side, 1.0)
		p.react("pain", 1.0)
		p.look_at_point(eye + p.global_transform.basis * (-side + Vector3(0, 0.2, -0.3)) * 50.0)
		for i in int(PilotPuppetLink.STREAM_GAP / DT):
			_drive(ctx, "puppet flinch storm", DT, {"vel": run * (1.0 if i % 4 < 2 else 0.7), "yaw_rate": 3.6 if i % 2 == 0 else 0.0})
	p.clear_look()
	# All of it at once with the worst moods.
	for mood: String in ["afraid", "overheated", "dazed"]:
		p.set_mood(mood)
		p.react_hit(Vector3.BACK, 1.0)
		_drive(ctx, "puppet %s teleport" % mood, DT, {"vel": Vector3(30, 0, 30), "yaw_rate": PI / DT})
		for i in 40:
			_drive(ctx, "puppet %s storm" % mood, DT, {"vel": run * float(i % 2), "yaw_rate": (PI / DT) if i % 9 == 0 else 3.6 * float(i % 2)})
	p.clear_mood()
	_drive(ctx, "puppet settle", 1.0, {})
	await frames(1)


## Feeds `state` for `secs`, measuring after every step; a full closure check at the end of the segment.
func _drive(ctx: Dictionary, label: String, secs: float, state: Dictionary) -> void:
	var p: PilotHead = ctx["p"]
	var n := maxi(int(round(secs / DT)), 1)
	for i in n:
		p.feed(DT, state)
		_measure(ctx, label, i == n - 1)


func _measure(ctx: Dictionary, label: String, full: bool) -> void:
	var p: PilotHead = ctx["p"]
	var body: PilotBody = ctx["body"]
	var w: Dictionary = _worst[ctx["tag"]]
	var mode: String = ctx["mode"]
	ctx["frame"] = int(ctx["frame"]) + 1
	var hs := body.head_space()
	# Closure: every welded rest vertex is still one point.
	var gap := 0.0
	for g: PackedInt32Array in ctx["welded"]:
		var a := hs[g[0]]
		for j in range(1, g.size()):
			gap = maxf(gap, a.distance_to(hs[g[j]]))
	if gap > float(w["gap"]):
		w["gap"] = gap
		w["gap_pose"] = label
	if full:
		var open := _open_edges(hs, body.shell_faces)
		if open > int(w["open"]):
			w["open"] = open
			w["open_pose"] = label
	# Bend angles.
	var lowb := p.piece("NeckLow").transform.basis
	var highb := p.piece("NeckHigh").transform.basis
	var skullb := (lowb * highb).orthonormalized()   # the skull's attitude (its own squash / jelly shear left out)
	var ang := Vector3(_angle(lowb), _angle(highb), _angle(skullb))
	var env: Vector3 = w["env"][mode]
	for a in 3:
		if ang[a] > env[a]:
			env[a] = ang[a]
			w["env_pose"][mode][a] = label
	w["env"][mode] = env
	if bool(ctx["track_jitter"]):
		var step := rad_to_deg(Quaternion((ctx["prev_skull"] as Basis).inverse() * skullb).get_angle())
		if step > float(w["jitter"][mode]):
			w["jitter"][mode] = step
			w["jitter_pose"][mode] = label
	ctx["prev_skull"] = skullb
	# Face shapes: none collapsed or inside out.
	if full or int(ctx["frame"]) % FACE_EVERY == 0:
		var d := body._rest_to_pose()
		var areas: PackedFloat32Array = ctx["areas"]
		var dom: PackedInt32Array = ctx["dom"]
		for f in body.shell_faces:
			var a := hs[f * 3]
			var c := (hs[f * 3 + 2] - a).cross(hs[f * 3 + 1] - a)
			var ratio := c.length() / maxf(areas[f], 1e-9)
			if ratio < float(w["area"]):
				w["area"] = ratio
				w["area_pose"] = label
				w["area_y"] = (body.rest[f * 3].y + body.rest[f * 3 + 1].y + body.rest[f * 3 + 2].y) / 3.0
			# The rest normal carried by the face's dominant joint (inverse transpose: the squash scales too).
			var carried := (d[dom[f]] as Transform3D).basis.inverse().transposed() * _rest_normal(body, f)
			var facing := c.normalized().dot(carried.normalized()) if c.length_squared() > 1e-14 else -1.0
			if facing < float(w["facing"]):
				w["facing"] = facing
				w["facing_pose"] = label
	# The seal: the plug's bottom loop under the hatch floor, inside the opening.
	var xf := (ctx["hatch"] as Node3D).global_transform.affine_inverse() * p.global_transform
	for i: int in ctx["ring"]:
		w["ring_up"] = maxf(float(w["ring_up"]), (xf * hs[i]).y - RIM_Y)
	for i: int in ctx["base"]:
		var h := xf * hs[i]
		var up := h.y - RIM_Y
		if up > float(w["up"]):
			w["up"] = up
			w["pose"] = "%s %s" % [mode, label]
		w["out"] = maxf(float(w["out"]), Vector2(h.x, h.z).length())
		var ext: Dictionary = w["ext"]
		for k: String in ["+x", "-x", "+z", "-z", "r"]:
			var score := Vector2(h.x, h.z).length()
			match k:
				"+x": score = h.x
				"-x": score = -h.x
				"+z": score = h.z
				"-z": score = -h.z
			if not ext.has(k) or score > float(ext[k][0]):
				ext[k] = [score, h]


func _report(m: MechModel, hatch: Node3D, tag: String, head_scale: float) -> void:
	var w: Dictionary = _worst[tag]
	var el: Vector3 = w["env"]["local"]
	var ep: Vector3 = w["env"]["puppet"]
	print(("ONE MESH %s: shell open edges worst %d (%s), widest vertex split %.6f (%s); face area >= %.2f of rest (%s, face at rest y %.2f), "
		+ "facing >= %.2f (%s)") % [tag, int(w["open"]), w["open_pose"], float(w["gap"]), w["gap_pose"], float(w["area"]),
		w["area_pose"], float(w["area_y"]), float(w["facing"]), w["facing_pose"]])
	print("BEND %s: local low %.1f high %.1f total %.1f deg (%s); puppet low %.1f high %.1f total %.1f deg (%s); skull turn per frame on input steps: local <= %.2f deg (%s), puppet <= %.2f deg (%s)"
		% [tag, el.x, el.y, el.z, ", ".join(w["env_pose"]["local"]), ep.x, ep.y, ep.z, ", ".join(w["env_pose"]["puppet"]),
		float(w["jitter"]["local"]), w["jitter_pose"]["local"], float(w["jitter"]["puppet"]), w["jitter_pose"]["puppet"]])
	print("NECK SEAL %s: base loop worst %.3f vs rim (%s), widest %.3f of %.2f opening; neck base ring worst %.3f vs rim"
		% [tag, float(w["up"]), w["pose"], float(w["out"]), OPENING, float(w["ring_up"])])
	eq(int(w["open"]), 0, "%s: the deformed shell never has a boundary edge (worst %d, %s)" % [tag, int(w["open"]), w["open_pose"]])
	check(float(w["gap"]) <= GAP_MAX, "%s: no welded vertex ever splits (widest %.6f, %s)" % [tag, float(w["gap"]), w["gap_pose"]])
	check(float(w["area"]) >= MIN_AREA, "%s: no shell face collapses (smallest %.2f of its rest area, %s)"
		% [tag, float(w["area"]), w["area_pose"]])
	check(float(w["facing"]) > MIN_FACING, "%s: no shell face turns inside out (worst facing %.2f, %s)"
		% [tag, float(w["facing"]), w["facing_pose"]])
	for a in 3:
		var lim: float = [LOW_MAX, HIGH_MAX, TOTAL_MAX][a]
		var nm: String = ["NeckLow", "NeckHigh", "skull total"][a]
		check(maxf(el[a], ep[a]) <= lim, "%s: %s bend within %.0f deg (local %.1f, puppet %.1f)" % [tag, nm, lim, el[a], ep[a]])
	var jl := float(w["jitter"]["local"])
	var jp := float(w["jitter"]["puppet"])
	check(jp <= jl + JITTER_OVER, "%s: puppet inputs (steps, spikes, teleports) shake the skull no more than local input steps (+%.0f deg per frame): %.2f (%s) vs %.2f"
		% [tag, JITTER_OVER, jp, w["jitter_pose"]["puppet"], jl])
	check(float(w["up"]) <= FLOOR_Y - RIM_Y - MARGIN,
		"%s: the neck's base loop stays %.2f below the hatch rim (under the floor) in every pose (worst %.3f, %s)"
		% [tag, RIM_Y - FLOOR_Y + MARGIN, float(w["up"]), w["pose"]])
	# Below the hatch floor the plug is inside the hull: its bottom's extreme points are inside the torso (or the nose),
	# never poking out of the skin.
	if head_scale == 1.15:
		var meshes: Array[MeshInstance3D] = []
		for n: String in ["Torso", "Nose"]:
			var mi := m.find_child(n, true, false) as MeshInstance3D
			if mi != null:
				meshes.append(mi)
		check(meshes.size() == 2, "%s: found the torso and nose meshes" % tag)
		if meshes.size() == 2:
			check(not _inside(meshes[0], hatch.global_transform * Vector3(0, 0.3, 0)) and _inside(meshes[0],
				hatch.global_transform * Vector3(0, -0.6, 0.3)), "%s: the inside test works (above the hatch out, under it in)" % tag)
		var ext: Dictionary = w["ext"]
		for k: String in ext:
			var g := hatch.global_transform * (ext[k][1] as Vector3)
			var inside := false
			for mi in meshes:
				inside = inside or _inside(mi, g)
			check(inside, "%s: the collar plug's bottom stays inside the hull at its %s extreme (%s, hatch frame)"
				% [tag, k, ext[k][1]])


static func _rest_normal(body: PilotBody, f: int) -> Vector3:
	var a := body.rest[f * 3]
	return (body.rest[f * 3 + 2] - a).cross(body.rest[f * 3 + 1] - a)


static func _angle(b: Basis) -> float:
	return rad_to_deg(Quaternion(b.orthonormalized()).get_angle())


## Boundary edges of the first `faces` triangles of a corner list (quantized positions; a closed shell has none).
static func _open_edges(pos: PackedVector3Array, faces: int) -> int:
	var counts := {}
	for t in faces:
		var q := [_q(pos[t * 3]), _q(pos[t * 3 + 1]), _q(pos[t * 3 + 2])]
		for e in 3:
			var k := "%s>%s" % [q[e], q[(e + 1) % 3]]
			counts[k] = int(counts.get(k, 0)) + 1
	var open := 0
	for k: String in counts:
		var parts := k.split(">")
		if int(counts[k]) != int(counts.get("%s>%s" % [parts[1], parts[0]], 0)):
			open += 1
	return open


## Is the global point `g` inside the (closed) mesh of `mi`? Ray parity along a skewed direction.
static func _inside(mi: MeshInstance3D, g: Vector3) -> bool:
	var o := mi.global_transform.affine_inverse() * g
	var d := Vector3(0.123, 0.987, 0.071).normalized()
	var hits := 0
	for s in mi.mesh.get_surface_count():
		var v: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for t in v.size() / 3:
			if Geometry3D.ray_intersects_triangle(o, d, v[t * 3], v[t * 3 + 1], v[t * 3 + 2]) != null:
				hits += 1
	return hits % 2 == 1


static func _q(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 2000.0)), int(round(v.y * 2000.0)), int(round(v.z * 2000.0))]
