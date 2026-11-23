extends TestCase
## NOT part of -TestAll (no "test_" prefix): headless micro-benchmark of the civilians' per-frame and per-shot costs.
##   [lifebench] step     AmbientLife._step on the crowd lab district (seed 1, 130 m, no culling), 24 / 60 / 200 people:
##                        ms per frame avg / max over 1200 frames (the first 60 frames skipped).
##   [lifebench] threat   AmbientLife.raise_threat on the section stack (seed 1, every deck evaluated), 24 / 60 people a
##                        deck: usec per call (first call, then median / max of 40 calls 0.3 s apart at people's spots).
##   [lifebench] sweep    AmbientLife.sweep on the same stack: usec per call (median / max of 400 ~3 m chords, half
##                        through someone, half missing; the positions do not change in between, as in one frame).
## Always passes. Run: .\test_runner.ps1 -TestName bench_life (compare medians of several runs; the PC is shared).

const DT := 1.0 / 60.0


func _init() -> void:
	timeout_sec = 400.0


func setup() -> void:
	var d := CityDistrict.new()
	add_child(d)
	d.build({"seed": 1, "walls": 1.0, "size_x": 130.0, "size_s": 130.0})
	for n in [24, 60, 200]:
		_step_bench(d, n)
	_layout_bench(CityPlan.make({"seed": 2}), "district 220 m")
	_layout_bench(d.plan, "lab 130 m")
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 1}))
	for n in [24, 60]:
		await _shot_bench(stack, n)
	finish()


## Crowd spacing's lazy layouts and hold index (they run on the first use at runtime): ms for every crossing node / bench,
## the worst single one, and one hold-index window.
func _layout_bench(cp: CityPlan, what: String) -> void:
	var lp := LifePlan.make(cp, 60)
	var t0 := Time.get_ticks_usec()
	var worst := 0
	var nodes := 0
	for u in lp.nodes.size():
		if lp._has_cross(u):
			var a := Time.get_ticks_usec()
			lp.wait_slots_all(u)
			worst = maxi(worst, Time.get_ticks_usec() - a)
			nodes += 1
	var t1 := Time.get_ticks_usec()
	var bworst := 0
	for b in lp.benches.size():
		var a := Time.get_ticks_usec()
		lp.bench_slots(b)
		bworst = maxi(bworst, Time.get_ticks_usec() - a)
	var t2 := Time.get_ticks_usec()
	lp._groups(15)
	var t3 := Time.get_ticks_usec()
	lp._groups(16)
	var t4 := Time.get_ticks_usec()
	print("[lifebench] layout %s: %d crossing nodes %.1f ms (worst %.2f ms), %d benches %.1f ms (worst %.2f ms), hold index window %.2f ms (cold) %.2f ms (next), %d props" % [
			what, nodes, (t1 - t0) / 1000.0, worst / 1000.0, lp.benches.size(), (t2 - t1) / 1000.0, bworst / 1000.0,
			(t3 - t2) / 1000.0, (t4 - t3) / 1000.0, lp._props.size()])


func _step_bench(d: CityDistrict, n: int) -> void:
	var life := AmbientLife.new()
	life.debug_people_cap = 200
	add_child(life)
	life.set_process(false)
	life.setup(d, n)
	life.advance_to(900.0)
	# setup warmed the crowd-spacing index for its own clock (0 offline): warm it for the jumped-to time, as a setup at 900
	# would have
	for k in AmbientLife.WARM_PARTS:
		life.plan.warm_ahead(900.0, n, k, AmbientLife.WARM_PARTS)
	var tot := 0.0
	var mx_f := 0
	var mx := 0.0
	var frames := 0
	for f in 1260:
		var t0 := Time.get_ticks_usec()
		life._step(DT)
		var us := float(Time.get_ticks_usec() - t0)
		if f >= 60:
			tot += us
			if us > mx:
				mx = us
				mx_f = f
			frames += 1
	print("[lifebench] step %3d people: avg %.3f ms  max %.3f ms (frame %d)" % [n, tot / frames / 1000.0, mx / 1000.0, mx_f])
	remove_child(life)
	life.free()


func _shot_bench(stack: CityStack, n: int) -> void:
	var life := AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup_stack(stack, n)
	life.advance_to(900.0)
	for f in 30:
		life._step(DT)
	var spots: Array[Vector3] = []
	for id in life.ids():
		if life.visible_now(id):
			spots.append(life.pose_of(id).origin)
	if spots.is_empty():
		print("[lifebench] nobody outdoors")
		return
	# the parts of the very first threat event on deck 0 (first-call costs)
	var u0 := life.unit(0)
	var at0: Vector3 = spots[0]
	var arc0 := u0._ring.world_to_arc(u0._to_world().affine_inverse() * at0)
	var ev0 := {"x": arc0.x, "s": arc0.y, "r": 12.0, "st": 1, "t": u0.now}
	var f0 := Time.get_ticks_usec()
	u0.crowd.apply_threat(ev0)
	var f1 := Time.get_ticks_usec()
	u0.fleet.apply_threat(ev0, u0.crowd)
	var f2 := Time.get_ticks_usec()
	print("[lifebench] first threat parts %2d/deck: crowd %d us  fleet %d us" % [n, f1 - f0, f2 - f1])
	var calls: Array[float] = []
	var first := -1.0
	var t := life.now
	for i in 41:
		t += 0.3
		life.advance_to(t)
		var at: Vector3 = spots[(i * 7) % spots.size()]
		var t0 := Time.get_ticks_usec()
		life.raise_threat(at, 12.0, 1)
		var us := float(Time.get_ticks_usec() - t0)
		if i == 0:
			first = us
		else:
			calls.append(us)
	# shortest-path trees (LifeCrowd's refuge choice builds one per candidate door the first time it is asked)
	var lp0: LifePlan = life.unit(0).plan
	var tt0 := Time.get_ticks_usec()
	var built := 0
	for d: Dictionary in lp0.doors:
		if not lp0._trees.has(int(d["node"])):
			lp0.tree(int(d["node"]))
			built += 1
	print("[lifebench] trees deck 0: %d doors, %d trees built in %.1f ms (%d nodes)" % [lp0.doors.size(), built,
			float(Time.get_ticks_usec() - tt0) / 1000.0, lp0.nodes.size()])
	# the parts of one threat event on deck 0 (people / vehicles / tram), applied directly
	var u := life.unit(0)
	var parts := {"crowd": [], "fleet": [], "tram": []}
	for i in 20:
		t += 0.3
		life.advance_to(t)
		var at: Vector3 = spots[(i * 5) % spots.size()]
		var arc := u._ring.world_to_arc(u._to_world().affine_inverse() * at)
		var ev := {"x": arc.x, "s": arc.y, "r": 12.0, "st": 1, "t": u.now}
		var t0 := Time.get_ticks_usec()
		u.crowd.apply_threat(ev)
		var t1 := Time.get_ticks_usec()
		u.fleet.apply_threat(ev, u.crowd)
		var t2 := Time.get_ticks_usec()
		if u.tram != null:
			u.tram.apply_threat(ev)
		var t3 := Time.get_ticks_usec()
		parts["crowd"].append(float(t1 - t0))
		parts["fleet"].append(float(t2 - t1))
		parts["tram"].append(float(t3 - t2))
	for k: String in parts:
		var a: Array = parts[k]
		a.sort()
		print("[lifebench] threat part %s %2d/deck: median %.0f us  max %.0f us" % [k, n, a[a.size() / 2], a[-1]])
	calls.sort()
	print("[lifebench] threat %2d/deck: first %.0f us  median %.0f us  max %.0f us" % [n, first, calls[calls.size() / 2], calls[-1]])
	for brute in [true, false]:
		_sweeps(life, spots, n, brute)
	remove_child(life)
	life.free()
	await get_tree().process_frame


func _sweeps(life: AmbientLife, spots: Array[Vector3], n: int, brute: bool) -> void:
	for u in life.units:
		u.brute_force = brute
	var sw: Array[float] = []
	var up := Vector3.UP
	for i in 400:
		var at: Vector3 = spots[(i * 13) % spots.size()] + up * 1.0
		if i % 2 == 1:
			at += Vector3(40.0, 15.0, 0.0)       # a miss (above / beside)
		var a := at + Vector3(-3.0, 0.4, 1.5)      # a bullet's chord in one frame (~3 m)
		var b := at + Vector3(0.3, 0.0, 0.1)
		var t0 := Time.get_ticks_usec()
		life.sweep(a, b, 0.2, 0)
		sw.append(float(Time.get_ticks_usec() - t0))
	sw.sort()
	print("[lifebench] sweep  %2d/deck %s: median %.1f us  p90 %.1f us  max %.1f us" % [n, "brute" if brute else "grid ",
			sw[sw.size() / 2], sw[int(sw.size() * 0.9)], sw[-1]])
