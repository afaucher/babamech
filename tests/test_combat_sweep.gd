extends TestCase
## Curved-flight sweep (Projectile._sweep, used by the rocket and, since this pass, the mortar shell): chords run on the
## fixed Combat.SWEEP_STEP grid from the last grid point swept, plus max_time as the final point. Checked: a frame step
## that doesn't reach the next grid point sweeps nothing yet; the hit time is the same at any frame step (smaller and
## larger than the grid) and when started late; the last partial chord up to range is swept (a target sitting only in
## it is hit).

const SUB := Combat.SWEEP_STEP


func setup() -> void:
	await _waits_for_grid()
	await _same_at_any_step("rockets", Vector3(0, 1.9, -60), Vector3(0, 0, -60))
	await _same_at_any_step("mortar", Vector3(0, 1.9, -80), Vector3(0, 0, -80))
	await _last_partial_chord()
	finish()


func _world() -> CombatWorld:
	var w := CombatWorld.new()
	w.mission_seed = 3
	w.use_physics = false
	add_child(w)
	return w


func _waits_for_grid() -> void:
	for weapon: String in ["rockets", "mortar"]:
		var w := _world()
		var p := w.fire(Combat.fire_record("me", 1, "hp", weapon, Vector3(0, 2, 0), Vector3(0, 2, -100), 0.0, 0)) as Projectile
		w.advance(SUB * 0.4)
		near(p._swept, 0.0, 1e-9, "%s: a step short of the first grid point sweeps nothing yet" % weapon)
		w.advance(SUB * 0.4)
		near(p._swept, 0.0, 1e-9, "%s: still short (0.8 of a grid step)" % weapon)
		w.advance(SUB * 0.4)
		near(p._swept, SUB, 1e-9, "%s: past it, swept exactly to the grid point" % weapon)
		w.advance(SUB * 2.5)
		near(p._swept, SUB * 3.0, 1e-9, "%s: a long step sweeps whole grid chords only" % weapon)
		w.free()
		await frames(1)


## The hit time on a target in the path is the same at any frame step and when the record arrives late.
func _same_at_any_step(weapon: String, aim: Vector3, at: Vector3) -> void:
	var base := -1.0
	for dt: float in [SUB, 0.007, 0.013, 0.05, 0.25, -1.0]:
		var w := _world()
		var d := TargetDummy.new()
		d.target_id = "d"
		d.mass_class = "static"
		d.position = at
		add_child(d)
		w.register(d)
		await frames(1)
		var late := dt < 0.0
		var rec := Combat.fire_record("me", 1, "hp", weapon, Vector3(0, 2, 0), aim, -0.73 if late else 0.0, 0)
		var p := w.fire(rec) as Projectile
		var step := SUB if late else dt
		var guard := 0
		while p.end_time < 0.0 and guard < 2000:
			w.advance(step)
			guard += 1
		var tag := "late" if late else "dt %.4f" % dt
		check(p.end_time > 0.0, "%s %s: it ends" % [weapon, tag])
		if base < 0.0:
			base = p.end_time
			check(base < p.max_time - 1e-6, "%s: it hits the target before range (%.4f s)" % [weapon, base])
		else:
			near(p.end_time, base, 1e-6, "%s: same hit time at %s" % [weapon, tag])
		d.free()
		w.free()
		await frames(1)


## A tiny target that only the final, partial chord (last grid point -> max_time) reaches.
func _last_partial_chord() -> void:
	var w := _world()
	var st := w.stats("rockets")
	var speed := float(st["speed"])
	var k := 300
	w.overrides["rockets"] = {"range": speed * (float(k) + 0.9) * SUB, "wobble": 0.0}
	var rec := Combat.fire_record("me", 1, "hp", "rockets", Vector3(0, 2, 0), Vector3(0, 2, -300), 0.0, 0)
	var probe := w.fire(rec) as Projectile
	var max_t := probe.max_time
	var centre := probe.flight_pos(max_t - 0.15 * SUB)
	var grid_end := probe.flight_pos(float(k) * SUB)
	w.remove_effect(probe)
	var t := CombatTarget.new()
	t.target_id = "tiny"
	t.mass_class = "static"
	t.add_hit_sphere("body", Vector3.ZERO, 0.05)
	t.position = centre
	add_child(t)
	w.register(t)
	await frames(1)
	check(grid_end.distance_to(centre) > 0.05 + Combat.PROJECTILE_RADIUS,
		"the target is out of reach of every whole grid chord")
	var rec2 := rec.duplicate()
	rec2["t"] = w.now
	var p := w.fire(rec2) as Projectile
	var guard := 0
	while not p.finished() and guard < 2000 and p.end_time < 0.0:
		w.advance(1.0 / 60.0)
		guard += 1
	check("tiny" in p.pierced, "the last partial chord up to range is swept: the target is hit")
	check(p.end_time < max_t, "it ends on the target, before range (%.4f < %.4f)" % [p.end_time, max_t])
	t.free()
	w.free()
	await frames(1)
