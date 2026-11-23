class_name HitchLog
extends Node
## Frame hitches in a mission scene, for LAN logs and the shader warm-up measurements: every frame longer than hitch_ms
## (wall clock between two frames; HITCH_MS, or the run flag --hitch-ms N) prints one "[Hitch]" line with the phase the
## frame began in (`phase` Callable: "load", "warmup", "play") and the pipelines the renderer compiled during it
## (RenderingServer PIPELINE_COMPILATIONS; "draw" = compiled on the spot at draw time, the stalling kind). The scene's
## exit prints a summary per phase: hitches, and the pipelines compiled in that phase over every frame (a measure that
## doesn't depend on how fast this GPU compiles: draw compilations in play are first-use stalls on a slow one).
## Local, cosmetic, print only. Not headless.

const HITCH_MS := 100.0

var phase: Callable
var hitch_ms := HITCH_MS
var _last_usec := 0
var _last_comp := {}
var _last_phase := "?"           ## the phase when the current frame began (a hitch belongs to it)
var _t0_usec := 0
## phase -> {n, max_ms, total_ms, frames, compiled: {kind: n}}
var stats: Dictionary = {}
## --hitch-debug: the geometry added to the tree during a frame that compiled pipelines in play (what to warm up).
var debug := false
var _added: Array[String] = []
var _added_prev: Array[String] = []


static func attach(parent: Node, phase_fn: Callable) -> HitchLog:
	var h := HitchLog.new()
	h.name = "HitchLog"
	h.phase = phase_fn
	h.process_mode = Node.PROCESS_MODE_ALWAYS
	var v := Boot.arg_value(OS.get_cmdline_user_args(), "--hitch-ms")
	if v.is_valid_float():
		h.hitch_ms = float(v)
	h.debug = OS.get_cmdline_user_args().has("--hitch-debug")
	parent.add_child(h)
	return h


func _ready() -> void:
	_t0_usec = Time.get_ticks_usec()
	_last_usec = _t0_usec
	_last_comp = ShaderWarmup.compilations()
	_last_phase = _phase()
	if debug:
		get_tree().node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is GeometryInstance3D and _added.size() < 40:
		var gi := n as GeometryInstance3D
		var what := str(n.get_path())
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var mats: PackedStringArray = []
			for i in mi.mesh.get_surface_count():
				var m := mi.get_active_material(i)
				mats.append("%s#%d" % [m.get_class(), m.get_instance_id()] if m != null else "none")
			what += " %s [%s] shadow %d" % [mi.mesh.get_class(), ",".join(mats), gi.cast_shadow]
		_added.append(what)


func _phase() -> String:
	return str(phase.call()) if phase.is_valid() else "?"


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ms := float(now - _last_usec) / 1000.0
	_last_usec = now
	var comp := ShaderWarmup.compilations()
	var p := _last_phase
	var s: Dictionary = stats.get(p, {"n": 0, "max_ms": 0.0, "total_ms": 0.0, "frames": 0, "compiled": {}})
	s["frames"] = int(s["frames"]) + 1
	var d := {}
	for k: String in comp:
		var dk := int(comp[k]) - int(_last_comp.get(k, 0))
		if dk != 0:
			d[k] = dk
			(s["compiled"] as Dictionary)[k] = int((s["compiled"] as Dictionary).get(k, 0)) + dk
	if ms <= hitch_ms and p == "play" and int(d.get("draw", 0)) > 0:
		# A pipeline compiled at draw time in play: a stall on a slow GPU even when this one shrugged it off.
		print("[Hitch] compile at t=%.2f s (play, %.0f ms), pipelines compiled %s" % [float(now - _t0_usec) / 1e6, ms, str(d)])
		if debug:
			print("[Hitch]   added in the last two frames:\n    %s" % "\n    ".join(_added_prev + _added))
	if ms > hitch_ms:
		print("[Hitch] %.0f ms at t=%.2f s (%s), pipelines compiled %s" % [ms, float(now - _t0_usec) / 1e6, p, str(d)])
		s["n"] = int(s["n"]) + 1
		s["max_ms"] = maxf(float(s["max_ms"]), ms)
		s["total_ms"] = float(s["total_ms"]) + ms
	stats[p] = s
	_last_comp = comp
	_last_phase = _phase()
	_added_prev = _added
	_added = []


func _exit_tree() -> void:
	var parts: PackedStringArray = []
	for p: String in stats:
		var s: Dictionary = stats[p]
		parts.append("%s: %d frames, %d hitches > %.0f ms (max %.0f ms, total %.0f ms), pipelines compiled %s" % [p,
			int(s["frames"]), int(s["n"]), hitch_ms, float(s["max_ms"]), float(s["total_ms"]), str(s["compiled"])])
	print("[Hitch] summary over %.1f s: %s" % [float(Time.get_ticks_usec() - _t0_usec) / 1e6,
		"; ".join(parts) if not parts.is_empty() else "none"])
