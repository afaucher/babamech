extends Node
## Graphics quality probe (GraphicsQuality + CityQuality) in the REAL test drive: the solo stack mission, the chase camera
## at the spawn, the mech walking back and forth. For each level (HIGH, MEDIUM, LOW, HIGH again): the root viewport's
## GraphicsQuality settings + stack.set_quality + life.set_quality, then average / p95 frame ms (wall clock, vsync off) and
## the viewport's GPU / CPU render ms, plus a screenshot (test_logs/shots/quality_<renderer>_<level>.png). Run in a real
## renderer on the hidden desktop: tools/quality_probe/run_quality_probe.ps1 (optionally -Compatibility). Prints
## "[qprobe]" lines and quits.

const WARM := 90
const MEASURE := 240

var _vp: RID


func _ready() -> void:
	_run.call_deferred()


func _say(s: String) -> void:
	print("[qprobe] " + s)


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var root := get_tree().root
	_vp = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	var method := RenderingServer.get_current_rendering_method()
	_say("renderer %s, adapter %s (%s), window %s, detected default %s" % [method, GraphicsQuality.adapter_name(),
			"integrated" if GraphicsQuality.is_integrated(GraphicsQuality.adapter_name(), RenderingServer.get_video_adapter_type()) else "dedicated",
			str(root.size), CityQuality.name_of(GraphicsQuality.detect())])
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	for i in 30:
		await get_tree().physics_frame
	td.drive_override = true
	var shots := ProjectSettings.globalize_path("res://test_logs/shots")
	DirAccess.make_dir_recursive_absolute(shots)
	for q: int in [CityQuality.HIGH, CityQuality.MEDIUM, CityQuality.LOW, CityQuality.HIGH]:
		GraphicsQuality.apply_viewport(root, q)
		if td.stack != null:
			td.stack.set_quality(q)
		if td.life != null:
			td.life.set_quality(q)
		var ms: Array[float] = []
		var gpu := 0.0
		var cpu := 0.0
		for f in WARM + MEASURE:
			td.mech.move_input = Vector2(0.0, 1.0 if (f / 60) % 2 == 0 else -1.0)
			var prev := Time.get_ticks_usec()
			await get_tree().process_frame
			if f >= WARM:
				ms.append(float(Time.get_ticks_usec() - prev) / 1000.0)
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
				cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp)
			if f == WARM - 1:
				var img := root.get_texture().get_image()
				if img != null:
					img.save_png(shots.path_join("quality_%s_%s.png" % [method, CityQuality.name_of(q)]))
		var avg := 0.0
		for v in ms:
			avg += v
		avg /= ms.size()
		ms.sort()
		_say("%-6s scale %.2f %-8s msaa %d | frame avg %6.2f p95 %6.2f ms | gpu %6.2f cpu-render %5.2f ms" % [
				CityQuality.name_of(q), root.scaling_3d_scale, ["bilinear", "fsr", "fsr2", "metalfx_s", "metalfx_t"][root.scaling_3d_mode],
				root.msaa_3d, avg, ms[int(ms.size() * 0.95)], gpu / MEASURE, cpu / MEASURE])
	_say("done")
	get_tree().quit()
