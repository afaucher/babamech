extends TestCase
## Per-shot cost of the civilians (docs/design/ambient-life.md "Crowd spacing", costs): LifeCrowd.apply_threat computes
## a pose only for people whose trip box reaches the tested area, LifeFleet skips loops that cannot reach a threat, and
## AmbientLife.sweep / blast look people up in a grid of their displayed feet. Each has a brute_force reference path
## (everyone's pose / every loop / every person). A scripted run on the section stack (seed 1, 60 people a deck: seeded
## threats of every strength, bursts of sweeps through and past people, blasts, over STEPS frames) gives the same
## snapshot(), tally(), host event log, hit counts and per-frame states with the fast paths as with the references.

const DT := 1.0 / 30.0
const STEPS := 3600            ## 120 s of frames
const PEOPLE := 60


func _init() -> void:
	timeout_sec = 400.0


func setup() -> void:
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 1}))
	var ref := await _run(stack, true)
	var fast := await _run(stack, false)
	eq(fast["hits"], ref["hits"], "the same hits from every sweep / blast, in order (%d calls, %d hits)" % [
			(ref["hits"] as Array).size(), ref["total"]])
	eq(fast["states"], ref["states"], "the same states of everyone, sampled every second")
	eq(fast["sent"], ref["sent"], "the same host events (the last 256)")
	eq(fast["tally"], ref["tally"], "the same tally (%s)" % ref["tally"])
	eq(fast["snap"], ref["snap"], "a bit-identical snapshot()")
	check(int(ref["total"]) > 5, "the script hit people (%d)" % ref["total"])
	check(int(ref["threats"]) > 20, "the script raised threats (%d)" % ref["threats"])
	finish()


func _run(stack: CityStack, brute: bool) -> Dictionary:
	var life := AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup_stack(stack, PEOPLE)
	for u in life.units:
		u.brute_force = brute
		u.crowd.brute_force = brute
		u.fleet.brute_force = brute
	life.advance_to(900.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var hits: Array = []
	var states: Array = []
	var total := 0
	var threats := 0
	for f in STEPS:
		life._step(DT)      # (steps every deck)
		var ids := life.ids()
		if f % 15 == 0:
			var out: Array[int] = []
			for id in ids:
				if life.visible_now(id) and life.state_of(id) == "calm":
					out.append(id)
			var at := Vector3.ZERO
			if not out.is_empty():
				at = life.pose_of(out[rng.randi_range(0, out.size() - 1)]).origin
			var what := rng.randi_range(0, 9)
			if out.is_empty():
				pass
			elif what <= 3:
				life.raise_threat(at + Vector3(rng.randf_range(-6, 6), 0.5, rng.randf_range(-6, 6)), rng.randf_range(6.0, 40.0),
						rng.randi_range(1, 3))
				threats += 1
			elif what <= 7:
				# a burst of chords: through the person, beside it, and past everyone
				for k in 6:
					var a := at + Vector3(rng.randf_range(-25, 25), rng.randf_range(0.5, 6.0), rng.randf_range(-25, 25))
					var b := at + Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(0.2, 1.6), rng.randf_range(-1.5, 1.5))
					if k % 3 == 2:
						b += Vector3(0.0, 9.0, 0.0)
					var n := life.sweep(a, b, rng.randf_range(0.05, 0.6), rng.randi_range(-1, 3))
					hits.append(n)
					total += n
			else:
				var n := life.blast(at + Vector3(rng.randf_range(-3, 3), 0.3, rng.randf_range(-3, 3)), rng.randf_range(1.0, 5.0), 1)
				hits.append(n)
				total += n
		if f % 30 == 0:
			var row := PackedStringArray()
			for id in ids:
				row.append(life.state_of(id))
			states.append(",".join(row))
	var res := {"hits": hits, "states": states, "sent": str(life.sent), "tally": str(life.tally()), "snap": life.snapshot(),
			"total": total, "threats": threats}
	print("[threat grid] %s: %d shot calls, %d hits, %d threats, tally %s" % ["brute" if brute else "fast", hits.size(), total,
			threats, res["tally"]])
	remove_child(life)
	life.free()
	await get_tree().process_frame
	return res
