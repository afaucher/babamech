extends TestCase
## Mission objectives phase 1 end to end in the REAL game (docs/design/mission-objectives.md §5, §9): a solo stack drive,
## plan mode, seed 1 (deck 1 flag, deck 2 sweep, deck 3 defend, then the extraction hold), played by cheating: the mech
## is teleported onto each primary's site (MissionRules' snapped site / the hold zone) and the crew's fire is replaced by
## lethal EnemyBase.apply_damage (garrison: one unit on the mech's deck every GAR_EVERY s; a wave unit KILL_AFTER s after
## it appears). Bonuses are left alone (never found) and timings shortened (MissionFlow.test_plan / test_director) to stay fast. Asserts:
## - the mission is won through every primary (flag, sweep, defend, hold) and the wave spawner really spawned (no stub);
## - the flag capture brings its wave: ordered while the flag is rising (step start) and its units really spawn;
## - (PacingDirector, pacing-director.md 1.3) every "build" release on a deck comes after the deck's previous build release
##   was mostly beaten or BUILD_GAP s after its door; the hard alive ceilings (PacingDirector.DECK_ALIVE_MAX /
##   SECTION_ALIVE_MAX) are never exceeded (DECK_CAP / SECTION_CAP count enemies in play, not idle garrison);
## - the sweep completes within lull + telegraph + margin of the last enemy death on its deck, and is not done while a
##   wave ordered for its deck has not spawned its units yet (no units appear on the deck after it is done);
## - the garrison is the plan's share (fewer standing than a full deck); a group from a gate with a staging bay spawns at
##   its ORDER (staged, not hittable until the door is passable), any other group at its door's open_at.

const SEED := 1
const PLAN := {"hold": 8.0}
const DIRECTOR := {"rest_first": 4.0, "rest_last": 2.0, "arrival_rest": 1.0, "grace": 3.0, "follow_gap": 0.5}
const GAR_EVERY := 1.0
const KILL_AFTER := 1.0
const SIM_LIMIT := 300.0
const SWEEP_MARGIN := 3.0

var td: TestDrive
var mf: MissionFlow
var seen := {}             # enemy instance id -> {t, wave, deck}
var orders: Array = []     # {t, wave, deck, open_at, follow, reason, bay}
var wave_first := {}       # wave id -> t of its first unit
var wave_beaten := {}      # wave id -> t mostly beaten
var deaths := {}           # deck -> [t of each death]
var peak_deck := 0
var peak_sec := 0
var gar_next := 0.0
var sweep_id := ""
var sweep_done_t := -1.0   # first _tick that saw the sweep done


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	MissionFlow.test_plan = PLAN
	MissionFlow.test_director = DIRECTOR
	await _play()
	MissionFlow.test_plan = {}
	MissionFlow.test_director = {}
	finish()


func _play() -> void:
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = SEED
	td.objectives = true
	add_child(td)
	await frames(4)
	mf = td.mission
	if not check(mf != null and mf.plan != null and mf.director != null and mf.world != null, "plan mode is on"):
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	mf.wave_ordered.connect(_on_order)
	var types := []
	for k in mf.plan.deck_count:
		types.append(str(mf.plan.primary(k)["type"]))
	if not eq(types, ["flag", "sweep", "defend"], "seed 1's primaries"):
		return
	var gar := [0, 0, 0]
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and e.wave == "" and e.spawn_deck < 3:
			gar[e.spawn_deck] += 1
	for k in 3:
		check(gar[k] > 0 and gar[k] < EnemySpawner.deck_budget(1, k), "deck %d garrison %d is a share of the budget %d" % [k,
			gar[k], EnemySpawner.deck_budget(1, k)])

	var sweep_done := -1.0
	sweep_id = str(mf.plan.primary(1)["id"])
	var tasks: Array = [mf.plan.primary(0), mf.plan.primary(1), mf.plan.primary(2), mf.plan.objective("hold")]
	for o: Dictionary in tasks:
		var id := str(o["id"])
		while mf.rules.obj_state(id) != "done" and mf.rules.outcome == "" and mf.now() < SIM_LIMIT:
			_place(o)
			for i in 6:
				await get_tree().physics_frame
			_tick()
		if str(o["type"]) == "sweep" and mf.rules.obj_state(id) == "done":
			sweep_done = mf.now()
		if str(o["type"]) == "flag":
			await _check_flag_wave(id, mf.now())
		if not check(mf.rules.obj_state(id) == "done", "%s (%s) done by t=%.0f (state %s, waves %s, alive %s)" % [id,
				o["type"], mf.now(), mf.rules.obj_state(id), str(mf.director.state()), str(td.enemies_alive_per_deck())]):
			return
	eq(mf.rules.outcome, "won", "the mission is won")
	check(mf.unspawned.is_empty(), "every wave went through EnemySpawner.spawn_wave (stub: %s)" % str(mf.unspawned))
	print("phase1: won at t=%.1f, %d orders, peak alive deck %d / section %d" % [mf.now(), orders.size(), peak_deck, peak_sec])

	# Groups: arrival (order for a staged bay group, door otherwise), build spacing, ceilings.
	check(not wave_first.is_empty(), "waves spawned units")
	var last_build := {}   # deck -> its last build order
	var staged := 0
	for e: Dictionary in orders:
		var w := str(e["wave"])
		var k := int(e["deck"])
		if wave_first.has(w) and not bool(e["follow"]):
			if bool(e["bay"]):
				staged += 1
				near(float(wave_first[w]), float(e["t"]), 0.5, "bay group %s spawns (staged) at its order" % w)
			else:
				near(float(wave_first[w]), float(e["open_at"]), 0.5, "group %s spawns at its door's open_at" % w)
		if bool(e["follow"]) or str(e["reason"]) != "build":
			continue
		if last_build.has(k):
			var p: Dictionary = last_build[k]
			var prev := str(p["wave"])
			var beaten_ok := wave_beaten.has(prev) and float(wave_beaten[prev]) <= float(e["t"]) + 0.3
			var gap := float(e["t"]) - float(p["open_at"])
			check(beaten_ok or gap >= float(mf.director.options["build_gap"]) - 0.3,
				"build group %s ordered %.1f s after %s's door (beaten %s)" % [w, gap, prev, str(wave_beaten.get(prev, "no"))])
		last_build[k] = e
	print("phase1: %d groups staged in gate bays" % staged)
	check(peak_deck <= PacingDirector.DECK_ALIVE_MAX, "deck alive ceiling: peak %d" % peak_deck)
	check(peak_sec <= PacingDirector.SECTION_ALIVE_MAX, "section alive ceiling: peak %d" % peak_sec)

	# Sweep: done soon after the deck's last death (lull + the source's telegraph + margin).
	# (Measured from the last death up to the sweep's completion: units of a wave ordered just before it arrive after it.)
	var before: Array = (deaths.get(1, []) as Array).filter(func(x: float) -> bool: return x <= sweep_done + 0.01)
	if check(sweep_done > 0.0 and not before.is_empty(), "the sweep's deck saw deaths before it was done"):
		var limit := mf.director.rest_length(1) + 5.0 + SWEEP_MARGIN
		var lag := sweep_done - float(before.max())
		print("phase1: sweep done %.1f s after the last death on deck 2" % lag)
		check(lag <= limit, "sweep done %.1f s after the last death (limit %.1f)" % [lag, limit])
	# Gap 1: the sweep is not done while a wave ordered for its deck has not spawned its units (it would spawn on a
	# "cleared" deck). Every wave ordered for deck 2 before the sweep was done had its first unit out by then, or had
	# spawned nothing until its open_at + grace (the director's rule for a wave that spawns nothing).
	var grace := float(mf.director.options["grace"])
	var swept := 0
	for e: Dictionary in orders:
		if int(e["deck"]) != 1 or bool(e["follow"]):
			continue
		var w := str(e["wave"])
		if float(e["t"]) <= sweep_done_t:
			swept += 1
			var out := wave_first.has(w) and float(wave_first[w]) <= sweep_done_t + 0.01
			check(out or float(e["open_at"]) + grace <= sweep_done_t, "deck 2 wave %s (open_at %.1f) had spawned before the sweep was done (t %.1f, first unit %s)" % [
				w, float(e["open_at"]), sweep_done_t, str(wave_first.get(w, "none"))])
		check(not wave_first.has(w) or float(wave_first[w]) <= sweep_done_t + 0.01,
			"no units of %s appear on deck 2 after the sweep is done (first %s, done %.1f)" % [w, str(wave_first.get(w, "none")), sweep_done_t])
	check(swept > 0, "deck 2 had waves before its sweep was done (%d)" % swept)
	td.queue_free()
	await frames(3)


## The flag's start wave: ordered before the flag was done (during the capture), and its units spawned.
func _check_flag_wave(id: String, done_t: float) -> void:
	var wid := ""
	for pw: Dictionary in mf.plan.pool(0)["reserve"]:
		if str(pw["for"]) == id:
			wid = str(pw["id"])
	if not check(wid != "", "the flag %s has a wave in its deck's pool" % id):
		return
	var ot := -1.0
	for e: Dictionary in orders:
		if e["wave"] == wid and ot < 0.0:
			ot = float(e["t"])
	check(ot >= 0.0 and ot < done_t, "the flag's wave %s is ordered during the capture (t %.1f, flag done %.1f)" % [wid, ot, done_t])
	var t_end := mf.now() + 8.0
	while not wave_first.has(wid) and mf.now() < t_end:
		for i in 6:
			await get_tree().physics_frame
		_tick()
	check(wave_first.has(wid), "the flag capture spawned wave units (%s, %d seen)" % [wid, int(mf._wave_total.get(wid, 0))])
	print("phase1: flag wave %s ordered at %.1f, flag done at %.1f, first unit at %s" % [wid, ot, done_t, str(wave_first.get(wid, "none"))])


func _place(o: Dictionary) -> void:
	var k := int(o["deck"])
	var ro := mf.rules.objective(o["id"])
	var at := Vector2(float(ro["site"]["x"]), float(ro["site"]["s"]))
	if str(o["type"]) == "hold":
		at = (ro["zone"] as Rect2).get_center()
	elif str(o["type"]) == "sweep":   # its site is the deck's departure (the way down): stand at the arrival instead
		var arr: Dictionary = td.stack.section.arrival(k)
		at = Vector2(float(arr["x"]), float(arr["s"]))
	var here := td.stack.to_deck_arc(td.mech.global_position)
	if int(here["deck"]) != k or Vector2(float(here["x"]), float(here["s"])).distance_to(at) > 5.0:
		td.mech.global_position = td.stack.from_deck_arc(k, at.x, at.y, 0.5)
		td.mech.velocity = Vector3.ZERO


func _on_order(o: Dictionary) -> void:
	var follow := false
	for p: Dictionary in orders:
		if p["wave"] == o["wave"]:
			follow = true
	orders.append({"t": mf.now(), "wave": str(o["wave"]), "deck": int(o["deck"]), "open_at": float(o["open_at"]),
		"follow": follow, "reason": str(o.get("reason", "")), "bay": not mf.source_bay(str(o["source"])).is_empty()})


func _tick() -> void:
	var t := mf.now()
	if sweep_done_t < 0.0 and sweep_id != "" and mf.rules.obj_state(sweep_id) == "done":
		sweep_done_t = t
	var pt := td.combat.player_target
	if pt != null and not pt.disabled:
		pt.repair_all()
	var mk := int(td.stack.to_deck_arc(td.mech.global_position)["deck"])
	var alive := td.enemies_alive_per_deck()
	var sum := 0
	for v in alive:
		peak_deck = maxi(peak_deck, v)
		sum += v
	peak_sec = maxi(peak_sec, sum)
	var gar: Array = []
	for e in td.combat.squad.enemies:
		if not is_instance_valid(e):
			continue
		var iid: int = e.get_instance_id()
		if e.destroyed():
			if seen.has(iid) and not bool(seen[iid].get("dead", false)):
				seen[iid]["dead"] = true
				var dk := int(seen[iid]["deck"])
				if not deaths.has(dk):
					deaths[dk] = []
				deaths[dk].append(t)
			continue
		if not seen.has(iid):
			seen[iid] = {"t": t, "wave": e.wave, "deck": e.spawn_deck}
			if e.wave != "" and not wave_first.has(e.wave):
				wave_first[e.wave] = t
		if e.wave != "":
			if t - float(seen[iid]["t"]) >= KILL_AFTER:
				e.apply_damage(1.0e7, e.core_component(), "test")
		elif e.spawn_deck == mk:
			gar.append([e.global_position.distance_to(td.mech.global_position), e])
	if not gar.is_empty() and t >= gar_next:
		gar.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		(gar[0][1] as EnemyBase).apply_damage(1.0e7, (gar[0][1] as EnemyBase).core_component(), "test")
		gar_next = t + GAR_EVERY
	for id: String in mf._wave_total:
		if wave_beaten.has(id):
			continue
		var n := 0
		for e in td.combat.squad.enemies:
			if is_instance_valid(e) and not e.destroyed() and e.wave == id:
				n += 1
		if int(mf._pending.get(id, 0)) == 0 and float(n) <= PacingDirector.BEATEN * float(int(mf._wave_total[id])):
			wave_beaten[id] = t
