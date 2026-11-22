extends TestCase
## The pilot's neck stays sealed in the cockpit (docs/design/pilot-heads.md section 4, "Neck seal"): on a real MechModel,
## for every head, the worst poses the rig can reach (full acceleration lean each way, hard turns, a hard landing and its
## rebound, the strongest flinch from each side, looks to the neck limits, every idle tic, every mood, and a few stacked
## combinations) never lift the bottom of the neck out of the hatch: every vertex of NeckLow's lowest loop stays MARGIN
## below the hatch rim plane (hatch frame, rim at y = RIM_Y), and inside the opening. The neck's bottom is capped (no open
## edges at the base), so even a glimpse from below never looks up into the hollow neck. Prints the worst exposure per
## head (hatch units = chassis units before BODY_SCALE; positive = above the rim).

const RIM_Y := 0.1          ## MechMeshes._hatch: the rim's top at y = 0.1 in the hatch's frame
const OPENING := 0.4        ## and the opening's inner radius
const FLOOR_Y := -0.04      ## and its dark floor disc, which covers the whole opening: below it nothing shows
const MARGIN := 0.02        ## the base loop's highest point stays at least this far below the floor (0.16 below the rim)
const DT := 1.0 / 60.0

var _worst := {}


func setup() -> void:
	timeout_sec = 120.0
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
	var low_mi := p.piece("NeckLow").get_node("NeckLow_mesh") as MeshInstance3D
	var loop := _base_loop(low_mi.mesh)
	check(loop.size() >= 3, "%s: NeckLow has a base loop (%d verts)" % [id, loop.size()])
	if head_scale == 1.15:
		_check_capped(id, low_mi.mesh)
	var tag := "%s@%.2f" % [id, head_scale]
	_worst[tag] = {"up": -1e9, "out": 0.0, "pose": "", "ring_up": -1e9, "slide": 0.0, "slide_pose": "", "ext": {}}
	var ring := _ring_at(low_mi.mesh, 0.0)
	var ctx := {"p": p, "hatch": hatch, "mi": low_mi, "loop": loop, "ring": ring, "tag": tag}
	ctx["rest"] = _centroid(_xf(ctx), ring)

	_measure(ctx, "rest")
	# Acceleration lean: a step in velocity each way (the neck's input saturates), then the stop.
	for d: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		_drive(ctx, "accel " + str(d), 0.7, {"vel": d * 25.0})
		_drive(ctx, "stop " + str(d), 0.9, {"vel": Vector3.ZERO})
	# Hard turns, both ways, at the rig's rates and beyond.
	for yr: float in [3.0, -3.0, 20.0, -20.0]:
		_drive(ctx, "turn %.0f" % yr, 0.8, {"yaw_rate": yr})
		_drive(ctx, "unturn", 0.6, {})
	# Turn + forward acceleration together.
	_drive(ctx, "turn+accel", 0.8, {"yaw_rate": 3.0, "vel": Vector3.FORWARD * 25.0})
	_drive(ctx, "settle", 0.8, {})
	# A hard landing: airborne falling fast, then grounded (impact + flinch, squash and rebound).
	_drive(ctx, "fall", 0.3, {"grounded": false, "vel": Vector3(0, -20, 0)})
	_drive(ctx, "land", 1.2, {"grounded": true})
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
	_drive(ctx, "stack dazed", 1.0, {"vel": Vector3.RIGHT * 25.0, "yaw_rate": -20.0})
	p.clear_mood()
	p.clear_look()

	var w: Dictionary = _worst[tag]
	print("NECK SEAL %s: base loop worst %.3f vs rim (%s), widest %.3f of %.2f opening; neck base ring worst %.3f vs rim, slides %.3f across the opening (%s)"
		% [tag, float(w["up"]), w["pose"], float(w["out"]), OPENING, float(w["ring_up"]), float(w["slide"]), w["slide_pose"]])
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
	m.queue_free()
	await frames(1)


## Feeds `state` for `secs`, measuring after every step.
func _drive(ctx: Dictionary, label: String, secs: float, state: Dictionary) -> void:
	var p: PilotHead = ctx["p"]
	var n := int(round(secs / DT))
	for i in n:
		p.feed(DT, state)
		_measure(ctx, label)


func _measure(ctx: Dictionary, label: String) -> void:
	var xf := _xf(ctx)
	var w: Dictionary = _worst[ctx["tag"]]
	for v: Vector3 in ctx["ring"]:
		w["ring_up"] = maxf(float(w["ring_up"]), (xf * v).y - RIM_Y)
	var c := _centroid(xf, ctx["ring"]) - (ctx["rest"] as Vector3)
	var slide := Vector2(c.x, c.z).length()
	if slide > float(w["slide"]):
		w["slide"] = slide
		w["slide_pose"] = label
	for v: Vector3 in ctx["loop"]:
		var h := xf * v
		var up := h.y - RIM_Y
		if up > float(w["up"]):
			w["up"] = up
			w["pose"] = label
		w["out"] = maxf(float(w["out"]), Vector2(h.x, h.z).length())
		# The extreme points of the plug's bottom (hatch frame), checked against the hull at the end.
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


## NeckLow's mesh space -> the hatch's frame.
static func _xf(ctx: Dictionary) -> Transform3D:
	return (ctx["hatch"] as Node3D).global_transform.affine_inverse() * (ctx["mi"] as MeshInstance3D).global_transform


static func _centroid(xf: Transform3D, pts: PackedVector3Array) -> Vector3:
	var s := Vector3.ZERO
	for v in pts:
		s += xf * v
	return s / float(maxi(pts.size(), 1))


## NeckLow's vertices at height y (the neck base ring at y = 0, where the neck skin meets the collar plug).
static func _ring_at(mesh: Mesh, y: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var seen := {}
	for s in mesh.get_surface_count():
		for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			var k := v.snapped(Vector3.ONE * 0.0005)
			if absf(v.y - y) < 0.002 and not seen.has(k):
				seen[k] = true
				out.append(v)
	return out


## NeckLow's lowest loop: the vertices within 5 mm of its lowest point (mesh space = head-rest space).
static func _base_loop(mesh: Mesh) -> PackedVector3Array:
	var verts := PackedVector3Array()
	var lo := 1e9
	for s in mesh.get_surface_count():
		for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			verts.append(v)
			lo = minf(lo, v.y)
	var out := PackedVector3Array()
	var seen := {}
	for v in verts:
		var k := v.snapped(Vector3.ONE * 0.0005)
		if v.y <= lo + 0.005 and not seen.has(k):
			seen[k] = true
			out.append(v)
	return out


## No open (boundary) edges in NeckLow's lower half: its bottom is capped.
func _check_capped(id: String, mesh: Mesh) -> void:
	var counts := {}
	var lo := 1e9
	var hi := -1e9
	for s in mesh.get_surface_count():
		for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
	var mid := (lo + hi) * 0.5
	for s in mesh.get_surface_count():
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for t in verts.size() / 3:
			var q := [_q(verts[t * 3]), _q(verts[t * 3 + 1]), _q(verts[t * 3 + 2])]
			var ys := [verts[t * 3].y, verts[t * 3 + 1].y, verts[t * 3 + 2].y]
			for e in 3:
				var e2 := (e + 1) % 3
				if float(ys[e]) < mid and float(ys[e2]) < mid:
					var k := "%s>%s" % [q[e], q[e2]]
					counts[k] = int(counts.get(k, 0)) + 1
	var open := 0
	for k: String in counts:
		var parts := k.split(">")
		if int(counts[k]) > int(counts.get("%s>%s" % [parts[1], parts[0]], 0)):
			open += 1
	eq(open, 0, "%s: NeckLow's bottom is capped (open edges in its lower half: %d)" % [id, open])


static func _q(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 2000.0)), int(round(v.y * 2000.0)), int(round(v.z * 2000.0))]
