extends Node
## City render / physics cost probe (docs/design/city-ramps-and-stack.md section 8). Run in a REAL renderer on the hidden
## desktop (tools/city_perf/run_city_perf.ps1): it builds (i) the stand-alone district as the test drive shows it today
## (CityDistrict.build({seed, walls: 1}) with its own rig, one mech at the spawn, a chase-camera view) and (ii) the 3-deck
## section stack (seed 4) seen from the lab's cameras (`avenue` on each deck, `shaft`), plus attribution variants (other
## decks hidden, daylight shadows off, fill lights off). Per case: average / p95 / worst frame ms (wall clock between
## frames, vsync off), GPU and CPU render ms of the viewport, draw calls, primitives and objects in frame. Then the
## physics cost with all the static shapes (a mech walking: MechController.step = move_and_slide, plus 1,000 rays), and
## the build time and memory. Prints lines starting with "[cityperf]" and quits.

const WARM := 90                 ## frames before measuring (shader compiles, first shadow pass)
const MEASURE := 300             ## frames measured per case

var _vp: RID
var _rows: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	var args := OS.get_cmdline_user_args()
	var seed_ := int(Boot.arg_value(args, "--perf-seed")) if Boot.arg_value(args, "--perf-seed").is_valid_int() else 4
	_say("renderer %s, adapter %s, size %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name(),
			str(get_viewport().get_visible_rect().size)])
	if Boot.arg_value(args, "--perf-quality") != "":
		await _quality_cases(seed_, Boot.arg_value(args, "--perf-quality"))
		_say("done")
		get_tree().quit()
		return
	if args.has("--perf-drive"):
		for mode: String in ["district", "stack", "district", "stack"]:
			await _drive_case(mode)
		_say("done")
		get_tree().quit()
		return
	await _district_case()
	await _stack_cases(seed_)
	_say("done")
	get_tree().quit()


func _say(s: String) -> void:
	print("[cityperf] " + s)


func _mem() -> float:
	return Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0


func _vram() -> float:
	return Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0


## Measure the current view.
func _measure(label: String) -> void:
	for i in WARM:
		await get_tree().process_frame
	var ms: Array[float] = []
	var gpu := 0.0
	var cpu := 0.0
	var draws := 0.0
	var prims := 0.0
	var objs := 0.0
	var prev := Time.get_ticks_usec()
	for i in MEASURE:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		ms.append(float(now - prev) / 1000.0)
		prev = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp)
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		objs += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var n := float(MEASURE)
	var avg := 0.0
	for v in ms:
		avg += v
	avg /= n
	ms.sort()
	var row := "%-34s avg %6.2f  p95 %6.2f  worst %6.2f ms | gpu %6.2f  cpu-render %5.2f ms | draws %6.0f  prims %9.0f  objs %6.0f" % [
			label, avg, ms[int(n * 0.95)], ms[-1], gpu / n, cpu / n, draws / n, prims / n, objs / n]
	_rows.append(row)
	_say(row)


## The headless test drive in one city mode, driven like tests/test_perf.gd (walk / run / strafe, no firing): frame
## wall time, and the city's own per-tick work timed by hand (every CityProps.step; the stack's follow is a 0.25 s timer).
func _drive_case(mode: String) -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = mode
	add_child(td)
	for i in 30:
		await get_tree().physics_frame
	td.drive_override = true
	var props := get_tree().get_nodes_in_group("city_props")
	var ms: Array[float] = []
	var city_ms := 0.0
	var prev := Time.get_ticks_usec()
	for f in 300:
		td.mech.move_input = Vector2(1.0 if (f / 40) % 2 == 0 else -1.0, 0.5)
		td.mech.running = (f % 80) > 40
		await get_tree().physics_frame
		var now := Time.get_ticks_usec()
		ms.append(float(now - prev) / 1000.0)
		prev = now
		var t := Time.get_ticks_usec()
		for c in props:
			(c as CityProps).step(0.0)      # the same work as its tick (a zero step moves nothing on)
		city_ms += float(Time.get_ticks_usec() - t) / 1000.0
	var avg := 0.0
	for v in ms:
		avg += v
	avg /= ms.size()
	ms.sort()
	_say("drive %-8s frames avg %.2f p95 %.2f max %.2f ms | CityProps.step x%d %.3f ms/tick | nodes %d, physics-process %.2f ms, process %.2f ms" % [
			mode, avg, ms[int(ms.size() * 0.95)], ms[-1], props.size(), city_ms / 300.0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	td.queue_free()
	for i in 3:
		await get_tree().process_frame


## (i) The test drive today: one stand-alone district with its own rig, a mech at the spawn, the chase camera's view.
func _district_case() -> void:
	var m0 := _mem()
	var t0 := Time.get_ticks_msec()
	var city := CityDistrict.new()
	city.name = "City"
	add_child(city)
	city.build({"seed": 1.0, "walls": 1.0})
	var build_ms := Time.get_ticks_msec() - t0
	_say("district seed 1: build %d ms, stats %s, static mem +%.0f MB (now %.0f MB), vram %.0f MB" % [build_ms, str(city.stats),
			_mem() - m0, _mem(), _vram()])
	var mech := MechSpawn.make()
	mech.ring = city.ring
	add_child(mech)
	var xf := Transform3D(city.ring.basis_at_arc(12.0), city.ring.arc_to_world(0.0, 12.0, CityPlan.CURB_H + 0.3))
	mech.global_transform = xf
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 70.0
	var eye := xf.origin + xf.basis.y * 9.0 + xf.basis.z * 14.0       # behind and above, like ChaseCamera
	cam.global_transform = Transform3D(Basis.looking_at(xf.origin + xf.basis.y * 5.0 - xf.basis.z * 30.0 - eye, xf.basis.y), eye)
	cam.make_current()
	await _measure("(i) district, chase view")
	await _physics(mech, city.ring, "district")
	mech.queue_free()
	cam.queue_free()
	city.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## (ii) The 3-deck stack through the lab's cameras, and what each part costs.
func _stack_cases(seed_: int) -> void:
	var m0 := _mem()
	var lab := CityLab.new()
	lab.options["site"] = "stack"
	lab.params["seed"] = float(seed_)
	var t0 := Time.get_ticks_msec()
	add_child(lab)
	var build_ms := Time.get_ticks_msec() - t0
	var stack := lab.stack
	var shapes := 0
	for d in stack.decks:
		shapes += (d.get_node("Collision") as Node).get_child_count()
	_say("stack seed %d: %d decks, lab add+build %d ms (stack.stats.ms %s), stats %s, collision shapes %d, static mem +%.0f MB (now %.0f MB), vram %.0f MB" % [
			seed_, stack.decks.size(), build_ms, str(stack.stats.get("ms", -1)), str(stack.stats), shapes, _mem() - m0, _mem(), _vram()])
	await _stepped_build(seed_)
	for k in stack.decks.size():
		lab.set_lab_param("deck", float(k))
		lab.set_lab_option("camera", "avenue")
		await _measure("(ii) stack deck %d avenue" % k)
		if k == 0:
			# Attribution, from deck 0's avenue: what the other decks, the daylight shadows and the fills cost.
			for j in stack.decks.size():
				stack.decks[j].visible = j == k
			await _measure("     deck 0, other decks hidden")
			for j in stack.decks.size():
				stack.decks[j].visible = true
			stack.rig.sun.shadow_enabled = false
			await _measure("     deck 0, daylight shadows off")
			stack.rig.sun.shadow_enabled = true
			var fills := stack.rig.get_node("Fills") as Node3D
			fills.visible = false
			await _measure("     deck 0, fill lights off")
			fills.visible = true
	lab.set_lab_param("deck", 0.0)
	lab.set_lab_option("camera", "shaft")
	await _measure("(ii) stack shaft (deck %d)" % stack.active_deck)
	for j in stack.decks.size():
		stack.decks[j].visible = j == stack.active_deck or j == stack.active_deck + 1
	await _measure("     shaft, only its deck + the one below")
	for j in stack.decks.size():
		stack.decks[j].visible = true
	var mech := MechSpawn.make()
	mech.ring = stack.ring()
	add_child(mech)
	mech.global_transform = stack.spawn_transforms(1)[0]
	lab.set_lab_option("camera", "avenue")
	await _physics(mech, stack.ring(), "stack")
	_say("summary:")
	for r in _rows:
		_say("  " + r)


## The same section built incrementally (CityStack.build_begin / build_step, one chunk per frame): total ms inside the
## chunks, chunk count, the worst chunk and the five slowest by label, and every chunk with --perf-chunks.
func _stepped_build(seed_: int) -> void:
	var st := CityStack.new()
	st.name = "SteppedStack"
	add_child(st)
	st.build_begin(SectionPlan.make({"seed": float(seed_)}))
	var frames := 0
	while not st.build_step(0.0):
		frames += 1
		await get_tree().process_frame
	var log_ := st.chunk_log.duplicate()
	if OS.get_cmdline_user_args().has("--perf-chunks"):
		for c: Array in log_:
			_say("  chunk %-28s %7.2f ms" % [c[0], c[1]])
	log_.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) > float(b[1]))
	var top := []
	for i in mini(5, log_.size()):
		top.append("%s %.1f" % [log_[i][0], log_[i][1]])
	_say("stack seed %d stepped build: %.1f ms in %d chunks (%d frames), max chunk %.1f ms; slowest: %s" % [seed_,
			float(st.stats["ms"]), int(st.stats["chunks"]), frames + 1, float(st.stats["max_chunk_ms"]), ", ".join(top)])
	st.queue_free()
	await get_tree().process_frame


## Physics with this scene's static shapes: a mech walking (its move_and_slide), the physics process time, 1,000 rays.
func _physics(mech: MechController, ring: RingFrame, label: String) -> void:
	for i in 30:
		await get_tree().physics_frame
	var step := 0.0
	var step_max := 0.0
	var phys := 0.0
	var n := 240
	for i in n:
		mech.move_input = Vector2(0.0, 1.0)
		mech.running = i > 60
		await get_tree().physics_frame
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# MechController.step measured directly (as tests/test_perf.gd does).
	mech.set_physics_process(false)
	for i in 120:
		var t := Time.get_ticks_usec()
		mech.step(1.0 / 60.0)
		var dt := float(Time.get_ticks_usec() - t) / 1000.0
		step += dt
		step_max = maxf(step_max, dt)
		await get_tree().physics_frame
	mech.set_physics_process(true)
	# The same with every CityProps' physics step off, and each CityProps.step timed on its own.
	var all_props := get_tree().get_nodes_in_group("city_props")
	for c in all_props:
		(c as Node).set_physics_process(false)
	var phys_np := 0.0
	for i in n:
		mech.move_input = Vector2(0.0, 1.0)
		await get_tree().physics_frame
		phys_np += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	mech.move_input = Vector2.ZERO
	mech.set_physics_process(false)
	var phys_idle := 0.0
	for i in 120:
		await get_tree().physics_frame
		phys_idle += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	mech.set_physics_process(true)
	_say("%s physics: physics-process with props AND the mech off (the engine step + other nodes) %.3f ms/frame" % [label, phys_idle / 120.0])
	var props_ms := 0.0
	var n_items := 0
	for c in all_props:
		var cp := c as CityProps
		n_items += cp.items.size()
		var t := Time.get_ticks_usec()
		for i in 60:
			cp.step(1.0 / 60.0)
		props_ms += float(Time.get_ticks_usec() - t) / 1000.0 / 60.0
		cp.set_physics_process(true)
	var scan_ms := 0.0
	for c in all_props:
		var t := Time.get_ticks_usec()
		(c as CityProps)._scan()
		scan_ms += float(Time.get_ticks_usec() - t) / 1000.0
	_say("%s physics: one body scan (CityProps._scan, every 1 s per deck) summed over decks %.2f ms; nodes in tree %d" % [label, scan_ms,
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	# A walking pusher: CityProps.step with the mech moving at walk speed (velocity set, no physics needed).
	for brute: bool in [true, false]:
		var walk_ms := 0.0
		mech.velocity = mech.global_basis.z * -12.0
		for c in all_props:
			var cp := c as CityProps
			var keep := cp.snapshot()
			cp.brute_force = brute
			cp._scan_in = 1e9       # no re-scan inside the timing: the scan is reported above
			var t := Time.get_ticks_usec()
			for i in 60:
				cp.step(1.0 / 60.0)
			walk_ms += float(Time.get_ticks_usec() - t) / 1000.0 / 60.0
			cp._scan_in = 0.0
			cp.brute_force = false
			cp.restore(keep)
		mech.velocity = Vector3.ZERO
		_say("%s physics: CityProps.step summed while a mech walks (scan excluded), %s: %.3f ms/tick" % [label,
				"old loop over every prop" if brute else "grid", walk_ms])
	_say("%s physics: %d CityProps nodes, %d props: physics-process with props off %.3f ms/frame; CityProps.step summed %.3f ms/frame" % [
			label, all_props.size(), n_items, phys_np / float(n), props_ms])
	var space := mech.get_world_3d().direct_space_state
	var p := mech.global_position
	var u := ring.up_at(p)
	var t0 := Time.get_ticks_usec()
	var hits := 0
	for i in 1000:
		var a := float(i) * 0.37
		var dir := (mech.global_basis.x * cos(a) + mech.global_basis.z * sin(a)) * 150.0 - u * 2.0
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(p + u * 4.0, p + u * 4.0 + dir)).is_empty():
			hits += 1
	var ray_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_say("%s physics: physics-process %.3f ms/frame avg, MechController.step %.3f avg / %.3f max ms, 1000 rays %.2f ms (%d hits), active bodies %d, pairs %d" % [
			label, phys / float(n), step / 120.0, step_max, ray_ms, hits,
			Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)])


# --- Quality levels (CityQuality; --perf-quality <0|1|2|all>, run_city_perf.ps1 -Quality) -----------------------------

## The stack (lab, site stack) at each requested quality level through the same cameras (the entry deck's avenue, the
## first ramp's top looking down it, the first shaft's railing): frame ms (avg, p95), the viewport's GPU / CPU render ms,
## draw calls, primitives, objects, omni fills switched on, decks drawn and whether the daylight casts shadows.
func _quality_cases(seed_: int, which: String) -> void:
	var levels: Array[int] = []
	if which == "all":
		levels.assign([GraphicsQuality.HIGH, GraphicsQuality.MEDIUM, GraphicsQuality.LOW])
	else:
		for part in which.split(",", false):
			levels.append(GraphicsQuality.clamp_level(int(part)))
	# --perf-size WxH: force the window (and so the 3D render, stretch mode canvas_items) to that many pixels; --resolution
	# alone is scaled by the desktop's DPI on the hidden desktop.
	var want := Boot.arg_value(OS.get_cmdline_user_args(), "--perf-size").split("x")
	if want.size() == 2 and want[0].is_valid_int() and want[1].is_valid_int():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(int(want[0]), int(want[1])))
		for i in 5:
			await get_tree().process_frame
	var lab := CityLab.new()
	lab.options["site"] = "stack"
	lab.params["seed"] = float(seed_)
	add_child(lab)
	var stack := lab.stack
	var entry := int(stack.section.entry["deck"])
	_say("quality: stack seed %d, %d decks, entry deck %d, window %s, render target %s, msaa_3d %d, scaling 3d %.2f" % [seed_,
			stack.decks.size(), entry, str(DisplayServer.window_get_size()), str(get_viewport().get_texture().get_size()),
			get_viewport().msaa_3d, get_viewport().scaling_3d_scale])
	var rows: Array[String] = []
	for view: String in ["avenue", "ramp", "shaft"]:
		for q in levels:
			lab.set_lab_param("deck", float(entry))
			lab.set_lab_option("camera", view)
			stack.set_quality(q)
			rows.append(await _measure_quality("%-6s %-6s" % [view, GraphicsQuality.name_of(q)], stack))
	if levels.has(GraphicsQuality.LOW):
		# Attribution at LOW, from the avenue and the ramp: the deck below (drawn at LOW so holes and ramp mouths are not a
		# void), and settings outside the city (Engine's): MSAA off, 3D render scale 0.75.
		var vp := get_viewport()
		var msaa := vp.msaa_3d
		for view: String in ["avenue", "ramp"]:
			lab.set_lab_param("deck", float(entry))
			lab.set_lab_option("camera", view)
			stack.set_quality(GraphicsQuality.LOW)
			if stack.active_deck + 1 < stack.decks.size():
				stack.decks[stack.active_deck + 1].visible = false
				rows.append(await _measure_quality("%-6s low, no deck below" % view, stack))
				stack.decks[stack.active_deck + 1].visible = true
		lab.set_lab_option("camera", "avenue")
		stack.set_quality(GraphicsQuality.LOW)
		vp.msaa_3d = Viewport.MSAA_DISABLED
		rows.append(await _measure_quality("avenue low, msaa off  ", stack))
		vp.scaling_3d_scale = 0.75
		rows.append(await _measure_quality("avenue low, msaa off, scale 0.75", stack))
		vp.scaling_3d_scale = 1.0
		vp.msaa_3d = msaa
		stack.set_quality(GraphicsQuality.HIGH)
		vp.msaa_3d = Viewport.MSAA_DISABLED
		rows.append(await _measure_quality("avenue high, msaa off ", stack))
		vp.msaa_3d = msaa
	stack.set_quality(GraphicsQuality.HIGH)
	_say("quality summary (view, level, avg / p95 frame ms, GPU / CPU render ms, draws, primitives, objects, omni fills on, decks drawn, sun shadows):")
	for r in rows:
		_say("  " + r)
	lab.queue_free()
	await get_tree().process_frame


func _measure_quality(label: String, stack: CityStack) -> String:
	for i in WARM:
		await get_tree().process_frame
	var ms: Array[float] = []
	var gpu := 0.0
	var cpu := 0.0
	var draws := 0.0
	var prims := 0.0
	var objs := 0.0
	var prev := Time.get_ticks_usec()
	for i in MEASURE:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		ms.append(float(now - prev) / 1000.0)
		prev = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp)
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		objs += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var n := float(MEASURE)
	var avg := 0.0
	for v in ms:
		avg += v
	avg /= n
	ms.sort()
	var row := "%s avg %6.2f  p95 %6.2f ms | gpu %6.2f  cpu-render %5.2f ms | draws %5.0f  prims %8.0f  objs %5.0f | omni %3d  decks %s  shadows %s" % [
			label, avg, ms[int(n * 0.95)], gpu / n, cpu / n, draws / n, prims / n, objs / n, stack.rig.fills_on(),
			str(stack.decks_drawn()), "on" if stack.rig.sun.shadow_enabled else "off"]
	_say(row)
	return row
