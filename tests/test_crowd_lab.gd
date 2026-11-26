extends TestCase
## The crowd lab (scripts/world/life/crowd_lab.gd) and AmbientLife's lab-only debug hooks. Forcing each state changes
## state_of / mode_of for the lab only and debug_clear returns everyone to the timetable; a blast placed in the lab knocks
## down the figures inside its kill radius and panics those near it; the people param changes the count
## deterministically for a seed; an AmbientLife that never calls the hooks, and one that calls them then debug_clear, are
## bit-identical in snapshot() / tally() over a fixed run, and equal to the values captured before the hooks existed.

## snapshot() hash / dead count of _run() on seed 3, 130 x 130 m, 30 people, captured from the code before the debug
## hooks were added. If LifePlan / LifeCrowd behaviour is changed on purpose, re-capture (print hash(life.snapshot())).
## Re-captured 2026-11-23 for crowd spacing (standing slots, walking lanes, bench capacity, cowering spots, snapshot
## version 3): was 3903048191.
## Re-captured 2026-11-25 for the FORMAT only: LifeFleet's snapshot went to version 3 (the pods' unloads, empty in this
## run: the fleet part ends in one more u16 0, its version byte is 3). With that section stripped and the version put
## back to 2 the bytes hash to the old 3798602067 exactly (same crowd, fleet, tally): was 3798602067.
const BASELINE_HASH := 4092188914
const BASELINE_DEAD := 2


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	var d := CityDistrict.new()
	add_child(d)
	d.build({"seed": 3, "walls": 1.0, "size_x": 130.0, "size_s": 130.0})
	_states(d)
	_identical(d)
	await _lab_checks()
	finish()


func _life(d: CityDistrict, n: int) -> AmbientLife:
	var life := AmbientLife.new()
	add_child(life)
	life.set_process(false)
	life.setup(d, n)
	return life


func _states(d: CityDistrict) -> void:
	var life := _life(d, 30)
	life.advance_to(900.0)
	var id := -1
	var other := -1
	for i in life.count():
		if life.visible_now(i) and life.state_of(i) == "calm":
			if id < 0:
				id = i
			elif other < 0:
				other = i
	if not check(id >= 0 and other >= 0, "two people outdoors at t 900"):
		return
	var other_mode := life.mode_of(other)
	check(not AmbientLife.debug_states().is_empty(), "the debug states list is not empty")
	for key: String in AmbientLife.debug_states():
		var spec: Dictionary = AmbientLife.DEBUG_STATES[key]
		life.debug_force_state(id, key)
		eq(life.state_of(id), str(spec["state"]), "forced %s: state_of" % key)
		eq(life.mode_of(id), str(spec["mode"]), "forced %s: mode_of" % key)
		eq(life.debug_forced(id), key, "forced %s: debug_forced" % key)
		eq(life.mode_of(other), other_mode, "forced %s on one figure: another keeps its animation" % key)
		eq(life.crowd.state_of(id, life.now), "calm", "forced %s: the crowd's own state is untouched" % key)
	life.debug_clear()
	eq(life.state_of(id), life.crowd.state_of(id, life.now), "debug_clear: state_of is the timetable's again")
	eq(life.mode_of(id), str(life.crowd.pose(id, life.now)["mode"]), "debug_clear: mode_of is the timetable's again")
	eq(life.debug_forced(id), "", "debug_clear: nothing forced")
	# the whole crowd; a forced "down" tips over in LifeCrowd.TIP_S and is not a kill
	life.debug_force_state(-1, "flee")
	eq(life.mode_of(other), "run", "forced flee on everyone: run")
	life.debug_force_state(-1, "down")
	life.advance_to(901.0)
	eq(life.mode_of(id), "down", "forced down: down")
	near(life.pose_of(id).basis.y.normalized().dot(d.ring.up_at(d.to_local(life.pose_of(id).origin))), 0.0, 0.2,
			"forced down: lying flat after TIP_S")
	eq(int(life.tally()["dead"]), 0, "forced down kills nobody")
	life.debug_force_state(-1, "timetable")
	eq(life.debug_forced(id), "", "\"timetable\" lifts it")
	life.debug_force_state(id, "no_such_state")
	eq(life.debug_forced(id), "", "an unknown state is ignored")
	var q := life.debug_person(id)
	for k: String in ["state", "mode", "activity", "speed", "heading", "door_a", "door_d", "alarm", "cloth", "build", "tall"]:
		check(q.has(k), "debug_person has %s" % k)
	check(life.debug_person(-1).is_empty() and life.debug_person(9999).is_empty(), "debug_person out of range: empty")
	remove_child(life)
	life.free()
	print("[crowd test] states checked on %d and %d" % [id, other])


func _run(life: AmbientLife, d: CityDistrict) -> void:
	life.advance_to(900.0)
	var c := d.plan.extent.get_center()
	life.raise_threat(d.global_transform * d.ring.arc_to_world(c.x, c.y, 1.0), 40.0, 2)
	life.advance_to(905.0)
	for id in life.count():
		if life.visible_now(id):
			life.blast(life.pose_of(id).origin, 3.0, 0)
			break
	life.advance_to(930.0)
	life.raise_threat(d.global_transform * d.ring.arc_to_world(c.x + 20.0, c.y - 15.0, 1.0), 60.0, 3)
	life.advance_to(960.0)


func _identical(d: CityDistrict) -> void:
	# one after the other (one AmbientLife listens to the session at a time)
	var a := _life(d, 30)
	_run(a, d)
	var snap_a := a.snapshot()
	var tally_a := str(a.tally())
	eq(hash(snap_a), BASELINE_HASH, "snapshot equal to the one captured before the debug hooks existed")
	eq(int(a.tally()["dead"]), BASELINE_DEAD, "dead equal to the baseline")
	remove_child(a)
	a.free()
	var b := _life(d, 30)
	b.debug_force_state(-1, "flee")
	b.debug_force_state(3, "down")
	b.state_of(3)
	b.debug_clear()
	_run(b, d)
	eq(b.snapshot(), snap_a, "hooks called then cleared: snapshot bit-identical to an instance that never called them")
	eq(str(b.tally()), tally_a, "... and the same tally")
	remove_child(b)
	b.free()


func _lab_checks() -> void:
	var lab := CrowdLab.new()
	add_child(lab)
	await frames(1)
	var life := lab.life
	eq(life.plan.count, 24, "default people 24")
	# people param: count changes, deterministic for a seed
	lab.set_lab_param("seed", 3.0)
	lab.set_lab_param("people", 50.0)
	lab.rebuild()
	eq(life.plan.count, 50, "people 50")
	eq(life.count(), 50 + LifePlan.RIDERS, "people 50 + riders")
	var sum := life.plan.checksum()
	lab.set_lab_param("people", 200.0)
	lab.rebuild()
	eq(life.plan.count, 200, "people 200 (the lab's raised cap)")
	lab.set_lab_param("people", 50.0)
	lab.rebuild()
	eq(life.plan.checksum(), sum, "people 50 again: the same plan checksum")
	lab.set_lab_param("people", 1.0)
	lab.rebuild()
	eq(life.plan.count, 1, "people 1")
	lab.set_lab_param("people", 60.0)
	lab.rebuild()
	# a blast placed on a figure: it goes down, people near it panic
	var victim := -1
	for id in life.count():
		if life.visible_now(id) and life.state_of(id) == "calm":
			victim = id
			break
	if not check(victim >= 0, "someone outdoors to blast"):
		lab.queue_free()
		return
	var vq := life.debug_person(victim)
	var at := Vector2(float(vq["x"]), float(vq["s"]))
	var near_ids: Array[int] = []
	for id in life.count():
		if id == victim or not life.visible_now(id) or life.state_of(id) != "calm":
			continue
		var q := life.debug_person(id)
		var dd := Vector2(float(q["x"]), float(q["s"])).distance_to(at)
		if dd > 6.0 and dd < 25.0:
			near_ids.append(id)
	lab.set_lab_param("threat_x", at.x)
	lab.set_lab_param("threat_s", at.y)
	lab.set_lab_param("threat_r", 30.0)
	lab.set_lab_param("kill_r", 3.0)
	lab.set_lab_option("threat", "blast")
	lab.do_lab_action("fire")
	life.advance_to(life.now + 1.5)
	eq(life.state_of(victim), "down", "the figure under the blast is down")
	var panicked := 0
	for id in near_ids:
		if life.state_of(id) in ["wary", "fleeing", "cowering", "sheltered", "hands_up"]:
			panicked += 1
	print("[crowd test] blast on %d: %d of %d near panicked" % [victim, panicked, near_ids.size()])
	check(near_ids.is_empty() or panicked > 0, "people 6-25 m from the blast panic (%d of %d)" % [panicked, near_ids.size()])
	check(lab.readout_text().contains("down 1") or int(life.tally()["dead"]) >= 1, "the readout counts the dead")
	# quality switch mid-panic, inspect out of range, reset revives
	lab.set_lab_option("quality", "low")
	lab.set_lab_option("quality", "medium")
	lab.set_lab_param("inspect", 199.0)
	check(lab.readout_text().contains("no such figure"), "inspect out of range is reported, not an error")
	lab.set_lab_param("inspect", float(victim))
	check(lab.readout_text().contains("#%d" % victim), "the inspector shows the figure")
	lab.set_lab_option("state_on", "inspected")
	lab.set_lab_option("state", "cower")
	await frames(2)
	lab.do_lab_action("reset")
	eq(int(life.tally()["dead"]), 0, "reset revives everyone")
	eq(life.state_of(victim), "cowering", "the forced state survives a reset")
	lab.set_lab_option("state", "timetable")
	eq(life.debug_forced(victim), "", "state timetable lifts it")
	lab.queue_free()
	await frames(1)
