extends TestCase
## Civilian animation (Build C: docs/design/ambient-life.md "Civilian animation: as built"). Headless, cosmetic side only:
## the custom data packs and unpacks; one MultiMesh per deck with custom data, on the deck's layer; the animation data of
## every figure is deterministic (two instances driven alike hold identical custom data); custom data is rewritten only
## when a motion changes or a turn starts, never per frame; every DEBUG_STATES entry maps to a motion; a kill's direction
## feeds the fall; LOW and HIGH quality stay state-identical (only shadows / draw radius differ).

const DT := 1.0 / 30.0

var district: CityDistrict


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_pack_checks()
	district = CityDistrict.new()
	district.with_rig = false
	add_child(district)
	district.build({"seed": 1, "walls": 1.0})
	_one_mmi()
	_deterministic()
	_writes_only_on_change()
	_debug_states()
	_kill_direction()
	_low_high()
	finish()


func _life(n: int = 40) -> AmbientLife:
	var life := AmbientLife.new()
	life.debug_people_cap = 200
	add_child(life)
	life.set_process(false)
	life.setup(district, n)
	return life


## Run `secs` of frames through the real per-frame path (_step: ticks, samples, display).
func _run(lives: Array, secs: float, each: Callable = Callable()) -> void:
	var n := int(secs / DT)
	for f in n:
		for l: AmbientLife in lives:
			l._step(DT)
		if each.is_valid():
			each.call()


func _pack_checks() -> void:
	var c := LifeAnimRig.pack(LifeAnimRig.RUN, LifeAnimRig.WALK, 3, true, deg_to_rad(-45.0), 123.25, 1.37, 0.5, 17.5)
	var u := LifeAnimRig.unpack(c)
	eq(int(u["motion"]), LifeAnimRig.RUN, "pack: motion")
	eq(int(u["prev"]), LifeAnimRig.WALK, "pack: previous motion")
	eq(int(u["cloth"]), 3, "pack: clothes")
	eq(bool(u["talk"]), true, "pack: talk")
	check(absf(float(u["turn"]) - deg_to_rad(-45.0)) < 0.01, "pack: turn (%.3f)" % float(u["turn"]))
	check(absf(float(u["t0"]) - 123.25) < 1e-4, "pack: start time")
	check(absf(float(u["speed"]) - 1.37) < 0.006, "pack: speed")
	check(absf(float(u["seed"]) - 0.5) < 0.002, "pack: seed")
	check(absf(float(u["param"]) - 17.5) < 1e-4, "pack: param")
	check(float(c.r) < 16777216.0 and float(c.b) < 16777216.0, "pack: integer fields stay exact in float32")
	for mode: String in LifeAnimRig.MODE_MOTION:
		check(int(LifeAnimRig.MODE_MOTION[mode]) < LifeAnimRig.MOTION_NAMES.size(), "motion of mode %s is named" % mode)


func _one_mmi() -> void:
	var life := _life()
	var f := life.unit(0).figures
	var mmis := f.find_children("*", "MultiMeshInstance3D", true, false)
	eq(mmis.size(), 1, "one MultiMeshInstance3D per deck (was 45: 9 pose meshes x 5 clothes)")
	if mmis.size() == 1:
		var mi := mmis[0] as MultiMeshInstance3D
		eq(mi.multimesh.instance_count, life.unit(0).plan.total(), "one instance per person")
		check(mi.multimesh.use_custom_data, "custom data on")
		eq(mi.layers, district.render_layer, "on the deck's render layer")
		check(mi.material_override is ShaderMaterial, "posed by the shader")
	var tris := f.figure_tris()
	check(tris > 0 and tris <= 140, "triangles per figure: %d (jointed, 10 parts + hair)" % tris)
	print("[life_anim] %d MMI(s) per deck, %d triangles per figure" % [f.mesh_count(), tris])
	life.queue_free()


func _deterministic() -> void:
	var a := _life()
	var b := _life()
	a.advance_to(1000.0)
	b.advance_to(1000.0)
	_run([a, b], 20.0)
	var diff := 0
	var drawn := 0
	for id in a.count():
		if a.unit(0).figures.custom_of(id) != b.unit(0).figures.custom_of(id) or a.unit(0).figures.shown(id) != b.unit(0).figures.shown(id):
			diff += 1
		if a.unit(0).figures.shown(id) >= 0:
			drawn += 1
	check(drawn > 5, "people drawn (%d)" % drawn)
	eq(diff, 0, "two instances hold identical animation data for every figure")
	var seeds := {}
	for id in a.count():
		seeds[snappedf(float(LifeAnimRig.unpack(a.unit(0).figures.custom_of(id))["seed"]), 0.001)] = true
	check(seeds.size() > a.count() / 2, "seeds vary per person (%d distinct of %d)" % [seeds.size(), a.count()])
	a.queue_free()
	b.queue_free()


func _writes_only_on_change() -> void:
	var life := _life(60)
	life.advance_to(1200.0)
	var f := life.unit(0).figures
	var last: Array = []
	var seen: Array = []
	for id in life.count():
		last.append(f.custom_of(id))
		seen.append(f.shown(id))
	var start := f.custom_writes
	var stats := {"bad": 0, "turns": 0, "changes": 0, "visible_s": 0.0}
	_run([life], 30.0, func() -> void:
		for id in life.count():
			if f.shown(id) >= 0:
				stats["visible_s"] = float(stats["visible_s"]) + DT
			var c := f.custom_of(id)
			if c != last[id]:
				var u := LifeAnimRig.unpack(c)
				var was := LifeAnimRig.unpack(last[id])
				if int(u["motion"]) != int(was["motion"]) or float((last[id] as Color).r) < 0.0 or int(seen[id]) < 0:
					stats["changes"] = int(stats["changes"]) + 1
				elif absf(float(u["turn"])) > 0.01:
					stats["turns"] = int(stats["turns"]) + 1
				else:
					stats["bad"] = int(stats["bad"]) + 1
				last[id] = c
			seen[id] = f.shown(id))
	var writes := f.custom_writes - start
	var vis := float(stats["visible_s"])
	print("[life_anim] 30 s calm: %d custom writes (%d motion changes, %d turns) over %.0f visible person-seconds" % [
			writes, int(stats["changes"]), int(stats["turns"]), vis])
	eq(int(stats["bad"]), 0, "custom data is rewritten only when a motion changes / starts (appears) or a turn starts")
	check(vis > 100.0, "people were visible (%.0f person-seconds)" % vis)
	check(float(writes) < vis * 0.5, "far fewer writes than frames (%d writes, %.0f person-seconds, %d frames)" % [
			writes, vis, int(30.0 / DT)])
	life.queue_free()


func _debug_states() -> void:
	var life := _life()
	life.advance_to(1300.0)
	for key: String in AmbientLife.DEBUG_STATES:
		var spec: Dictionary = AmbientLife.DEBUG_STATES[key]
		check(LifeAnimRig.MODE_MOTION.has(str(spec["mode"])), "DEBUG_STATES %s maps to a motion" % key)
		life.debug_force_state(-1, key)
		_run([life], 1.0)
		var want := int(LifeAnimRig.MODE_MOTION.get(str(spec["mode"]), -9))
		var bad := 0
		var n := 0
		for id in life.count():
			if life.unit(0).figures.shown(id) < 0 or life.unit(0).crowd.dead.has(id):
				continue
			n += 1
			if life.unit(0).figures.shown(id) != want or int(LifeAnimRig.unpack(life.unit(0).figures.custom_of(id))["motion"]) != want:
				bad += 1
		check(n > 0, "forced %s: figures drawn" % key)
		eq(bad, 0, "forced %s: every figure shows %s" % [key, LifeAnimRig.MOTION_NAMES[maxi(want, 0)]])
	check(AmbientLife.DEBUG_STATES.has("look_around"), "look_around (an idle variation) can be forced")
	life.debug_clear()
	life.queue_free()


func _kill_direction() -> void:
	var life := _life()
	life.advance_to(1400.0)
	_run([life], 0.5)
	var victims: Array[int] = []
	for id in life.count():
		if life.unit(0).figures.shown(id) >= 0 and life.state_of(id) == "calm":
			victims.append(id)
		if victims.size() == 2:
			break
	if not check(victims.size() == 2, "two people outdoors"):
		life.queue_free()
		return
	var dirs := [Vector2(1.0, 0.0), Vector2(0.0, -1.0)]
	for k in 2:
		life.apply_event("life.down", {"id": victims[k], "t": life.now, "dir": dirs[k], "src": 1})
	_run([life], 2.0)
	for k in 2:
		var id := victims[k]
		var u := LifeAnimRig.unpack(life.unit(0).figures.custom_of(id))
		eq(int(u["motion"]), LifeAnimRig.FALL, "victim %d falls" % k)
		var d: Vector2 = dirs[k]
		var want := wrapf(atan2(d.x, d.y) - life.unit(0)._yaw[id], -PI, PI)
		check(absf(wrapf(float(u["param"]) - want, -PI, PI)) < 1e-3, "victim %d: the fall direction is the hit's (%.3f vs %.3f)" % [
				k, float(u["param"]), want])
		check(absf(float(u["t0"]) + life.unit(0).figures._epoch - float(life.unit(0).crowd.dead[id]["t"])) < 0.01,
				"victim %d: the fall starts at the kill" % k)
	life.queue_free()


func _low_high() -> void:
	var hi := _life()
	var lo := _life()
	lo.set_quality(CityQuality.LOW)
	hi.set_quality(CityQuality.HIGH)
	check(hi.unit(0).figures.shadows() and not lo.unit(0).figures.shadows(), "shadows at HIGH, none at LOW")
	hi.advance_to(1500.0)
	lo.advance_to(1500.0)
	_run([hi, lo], 5.0)
	for id in hi.count():
		if hi.visible_now(id) and hi.state_of(id) == "calm":
			hi.blast(hi.pose_of(id).origin, 3.0, 1)
			break
	for e: Array in hi.sent:
		lo.apply_event(str(e[0]), e[1])
	_run([hi, lo], 10.0)
	var diff := 0
	for id in hi.count():
		if hi.state_of(id) != lo.state_of(id) or not hi.pose_of(id).is_equal_approx(lo.pose_of(id)):
			diff += 1
	eq(diff, 0, "LOW and HIGH: every state and pose identical")
	eq(lo.snapshot().hex_encode(), hi.snapshot().hex_encode(), "LOW and HIGH: identical snapshots")
	eq(lo.tally(), hi.tally(), "LOW and HIGH: identical tallies")
	hi.queue_free()
	lo.queue_free()
