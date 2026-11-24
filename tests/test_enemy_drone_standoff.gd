extends TestCase
## Scout drone standoff without the wiggle (scripts/enemy/enemy_drone.gd), in the real game: a solo stack drive in plan
## mode on seed 403112 (the playtest seed), headless, game time only. The mech is the fixture: it stands still and is
## kept standing (repair_all every frame). A wiggle is a 6 s window with a path > WIG_PATH m, a net displacement
## < WIG_NET m and >= WIG_REVS reversals of the 0.1 s heading (cos < -0.5): the old drone did that for 40+ s here
## (patrol <-> orbit on a sightline a building edge cut); a patrol that turns at a corner does not count.
## 1. Deck 2, mech at the crossing (129, 329), ~80 m from the scout's beat, 40 s: no wiggle; the scout completes a beacon;
##    dropships on the deck stay within EnemySquad.max_drops_per_deck however many beacons it pulses.
## 2. Deck edge: the deck-1 scout put 4 m inside the west edge (x ~ -121) with the mech 76 m east so its orbit backs into
##    the edge, 12 s: no wiggle, the orbit reverses at most once per EnemyDrone.FLANK_FLIP_CD.
## 3. Wave drone: the deck-1 drone made a hunting wave unit 110 m from the mech, 25 s: it closes to <= WAVE_CLOSE, then
##    never goes beyond WAVE_RELEASE, the hunt path and the orbit do not alternate, and it does not wiggle.
## 4. Fliers out of a real gate bay: a drone and a gunship rolled out, and a drone whose AI starts under the lintel, never
##    touch the bay, its lintel or the door, and end out in the deck at flying height (the drone's height floor no longer
##    snaps it up into the lintel).

const SEED := 403112
const WIG_PATH := 20.0
const WIG_NET := 6.0
const WIG_REVS := 6
const SAMPLE := 0.1
const BAY_WATCH := 12.0       ## s the bay-exit fliers are watched

var td: TestDrive
var sq: EnemySquad
var pt: PlayerTarget


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = SEED
	td.objectives = true
	add_child(td)
	await frames(4)
	if not check(td.mission != null and td.combat != null and td.combat.squad != null, "the plan-mode drive runs"):
		finish()
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	sq = td.combat.squad
	pt = td.combat.player_target
	await _standoff()
	await _deck_edge()
	await _wave_close()
	await _bay_exit()
	td.queue_free()
	await frames(2)
	finish()


func _drone(deck: int) -> EnemyDrone:
	for e in sq.enemies:
		if e is EnemyDrone and is_instance_valid(e) and not e.destroyed() and e.spawn_deck == deck and e.wave == "":
			return e
	return null


func _put_mech(deck: int, x: float, s: float) -> void:
	var p := td.stack.from_deck_arc(deck, x, s, 0.5)
	td.mech.global_position = p
	td.mech.velocity = Vector3.ZERO
	if pt != null:
		pt.global_position = p


## Steps `secs` s of game time; returns the 0.1 s arc samples of `d` [[t, Vector2]] and calls `each` every frame.
func _run(d: EnemyDrone, secs: float, each: Callable = Callable()) -> Array:
	var out: Array = []
	var t := 0.0
	var nxt := 0.0
	while t < secs:
		await get_tree().physics_frame
		t += 1.0 / float(Engine.physics_ticks_per_second)
		if pt != null:
			pt.repair_all()
		if not is_instance_valid(d) or d.destroyed():
			break
		if each.is_valid():
			each.call(t)
		if t >= nxt:
			out.append([t, d._world_to_arc2(d._world_pos())])
			nxt = t + SAMPLE
	return out


## Seconds of `samples` inside a wiggle window (see the header).
static func wiggle_secs(samples: Array) -> float:
	var flagged := {}
	var i := 0
	while i < samples.size():
		var k := i
		while k < samples.size() and float(samples[k][0]) - float(samples[i][0]) < 6.0:
			k += 1
		if k >= samples.size():
			break
		var path := 0.0
		var revs := 0
		for j in range(i + 1, k):
			path += (samples[j][1] as Vector2).distance_to(samples[j - 1][1] as Vector2)
			if j >= i + 2:
				var a: Vector2 = (samples[j - 1][1] as Vector2) - (samples[j - 2][1] as Vector2)
				var b: Vector2 = (samples[j][1] as Vector2) - (samples[j - 1][1] as Vector2)
				if a.length() > 0.3 and b.length() > 0.3 and a.normalized().dot(b.normalized()) < -0.5:
					revs += 1
		var net := (samples[k - 1][1] as Vector2).distance_to(samples[i][1] as Vector2)
		if path > WIG_PATH and net < WIG_NET and revs >= WIG_REVS:
			for j in range(i, k):
				flagged[j] = true
		i += 5
	return float(flagged.size()) * SAMPLE


func _dropships(deck: int, seen: Dictionary) -> void:
	for e in sq.enemies:
		if is_instance_valid(e) and e.enemy_type == "dropship" and e.spawn_deck == deck:
			seen[e.target_id] = true


func _standoff() -> void:
	var d := _drone(2)
	if not check(d != null, "seed %d has a deck-2 scout" % SEED):
		return
	_put_mech(2, 129.0, 329.0)
	var b0 := d._beacon_count
	var drops := {}
	var cb := func(_t: float) -> void:
		_dropships(2, drops)
	var samples := await _run(d, 40.0, cb)
	var w := wiggle_secs(samples)
	print("[Test] standoff: %s wiggle %.1f s, beacons %d, dropships %s" % [d.target_id, w, d._beacon_count - b0, str(drops.keys())])
	check(w == 0.0, "the deck-2 scout does not wiggle with the mech ~80 m away (%.1f s)" % w)
	check(d._beacon_count - b0 >= 1, "the scout completes its alarm beacon (%d)" % (d._beacon_count - b0))
	check(drops.size() <= sq.max_drops_per_deck, "dropships on deck 2 stay within the per-deck cap %d (%d, beacons %d)" % [
		sq.max_drops_per_deck, drops.size(), d._beacon_count - b0])


func _deck_edge() -> void:
	var d := _drone(1)
	if not check(d != null, "seed %d has a deck-1 scout" % SEED):
		return
	var ext: Rect2 = sq.deck_plan(1).extent.grow(-10.0)
	var dx := ext.position.x + 4.0
	var ds := -186.0
	_put_mech(1, dx + 76.0, ds)
	d.global_position = d._arc_to_world_alt(Vector2(dx, ds), 16.0)
	var flips := [0]
	var last := [d._flank_sign]
	var flip_t: Array = []
	var cb := func(t: float) -> void:
		if d._flank_sign != float(last[0]):
			flips[0] += 1
			flip_t.append(t)
			last[0] = d._flank_sign
	var samples := await _run(d, 12.0, cb)
	var w := wiggle_secs(samples)
	print("[Test] deck edge: %s at x %.0f, wiggle %.1f s, orbit flips %d at %s" % [d.target_id, dx, w, flips[0], str(flip_t)])
	check(w == 0.0, "the scout pressed against the deck edge does not wiggle (%.1f s)" % w)
	check(flips[0] <= int(12.0 / EnemyDrone.FLANK_FLIP_CD) + 1, "the orbit reverses at most once per %.0f s (%d)" % [
		EnemyDrone.FLANK_FLIP_CD, flips[0]])
	for i in range(1, flip_t.size()):
		check(float(flip_t[i]) - float(flip_t[i - 1]) >= EnemyDrone.FLANK_FLIP_CD - 0.05, "orbit flips %.2f s apart" % [
			float(flip_t[i]) - float(flip_t[i - 1])])


func _wave_close() -> void:
	var d := _drone(1)
	if not check(d != null, "the deck-1 drone is still up for the wave check"):
		return
	_put_mech(1, -45.0, -202.0)
	var m_arc := Vector2(-45.0, -202.0)
	d.wave = "test_wave"
	d.global_position = d._arc_to_world_alt(m_arc + Vector2(0.0, 110.0), 15.0)
	d.begin_hunt_pursuit(pt, d._target_aim_center(pt))
	var closed_t := [-1.0]
	var max_after := [0.0]
	var mode_flips := [0]
	var last_close := [d._wave_close]
	var cb := func(t: float) -> void:
		var dist := (d._world_to_arc2(d._world_pos()) - m_arc).length()
		if d._wave_close != bool(last_close[0]):
			mode_flips[0] += 1
			last_close[0] = d._wave_close
		if float(closed_t[0]) < 0.0 and d._wave_close:
			closed_t[0] = t
		elif float(closed_t[0]) >= 0.0:
			max_after[0] = maxf(float(max_after[0]), dist)
	var samples := await _run(d, 25.0, cb)
	var w := wiggle_secs(samples)
	print("[Test] wave drone: closed at %.1f s, max %.1f m after, close/approach switches %d, wiggle %.1f s" % [
		float(closed_t[0]), float(max_after[0]), mode_flips[0], w])
	check(float(closed_t[0]) >= 0.0, "the wave drone closes to <= %.0f m" % EnemyDrone.WAVE_CLOSE)
	check(float(max_after[0]) <= EnemyDrone.WAVE_RELEASE, "once closed it stays within %.0f m (max %.1f)" % [
		EnemyDrone.WAVE_RELEASE, float(max_after[0])])
	check(mode_flips[0] <= 2, "approach and orbit do not alternate (%d switches)" % mode_flips[0])
	check(w == 0.0, "the wave drone does not wiggle (%.1f s)" % w)


## 4. Fliers out of a real gate bay (the pacing director's staging: BayFormation slots, EnemyBase.roll_out): a drone and a
## gunship with their full roll-out paths, and a second drone whose path is cut after the funnel point so its own AI takes
## over UNDER the lintel (low, inside the bay). The door is opened and held; for BAY_WATCH s none of their hull boxes
## touches geometry (lintel, door frame, bay walls), and all three end up out in the deck at flying height.
func _bay_exit() -> void:
	var mf := td.mission
	var mw: MissionWorld = td.stack.mission
	var k := -1
	var sid := ""
	var bay := {}
	for dk in td.stack.decks.size():
		for s: Dictionary in mf.plan.deck_sources(dk):
			var b := mf.source_bay(str(s["id"]))
			if not b.is_empty():
				k = dk
				sid = str(s["id"])
				bay = b
				break
		if k >= 0:
			break
	if not check(k >= 0, "seed %d has a gate with a staging bay" % SEED):
		return
	var out: Vector2 = bay["out"]
	var door: Vector2 = bay["door"]
	var mech_at := door + out * 90.0
	_put_mech(k, mech_at.x, mech_at.y)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var slots := BayFormation.layout(bay, ["gunship", "drone", "drone"], rng)
	var specs: Array[Dictionary] = []
	var paths: Array = []
	for i in slots.size():
		var sl: Dictionary = slots[i]
		var kind := str(sl["kind"])
		var cruise := CityPlan.CURB_H + (EnemySpawner.GUNSHIP_CRUISE_ALT if kind == "gunship" else EnemySpawner.DRONE_CRUISE_ALT)
		var path := BayFormation.exit_path(bay, sl, cruise, CityPlan.CURB_H)
		paths.append(path)
		var at: Vector2 = sl["arc"]
		specs.append({"id": "bayx_%d" % i, "type": kind, "x": at.x, "s": at.y, "h": CityPlan.CURB_H + float(sl["h"]),
			"yaw_arc": 0.0, "wave": "bayx", "staged": true})
	var made := EnemySpawner.spawn_specs(specs, td.stack.decks[k].plan, td.stack.deck_ring(k), td.combat.world, sq, 9, true, "", k, "bayx")
	mw.open_source(sid, mw.now + 0.5, 30.0)
	var w := 0.0
	while w < 10.0 and not bool(mw.source_state(sid).get("passable", false)):
		await get_tree().physics_frame
		w += 1.0 / float(Engine.physics_ticks_per_second)
	var cut_done := false
	for i in made.size():
		var e: EnemyBase = made[i]
		var p: Array[Vector3] = paths[i]
		if e.enemy_type == "drone" and not cut_done:
			p = [p[0]] as Array[Vector3]   # AI takes over inside the bay, under the lintel
			cut_done = true
		e.begin_hunt_pursuit(pt, pt.global_position)
		e.roll_out(p, 0.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.collide_with_areas = false
	q.exclude = [td.mech.get_rid()] as Array[RID]
	var contacts := {}
	var t := 0.0
	while t < BAY_WATCH:
		await get_tree().physics_frame
		t += 1.0 / float(Engine.physics_ticks_per_second)
		pt.repair_all()
		for e: EnemyBase in made:
			if not is_instance_valid(e) or e.destroyed():
				continue
			var b := BoxShape3D.new()
			b.size = (EnemyCatalog.unit(e.enemy_type)["size"] as Vector3) * 0.9
			q.shape = b
			q.transform = e.global_transform
			for hh: Dictionary in e.get_world_3d().direct_space_state.intersect_shape(q, 2):
				if not (hh["collider"] is CharacterBody3D):
					contacts[e.target_id] = int(contacts.get(e.target_id, 0)) + 1
					break
	for e: EnemyBase in made:
		if not is_instance_valid(e) or e.destroyed():
			continue
		var a := td.stack.to_deck_arc(e.global_position)
		var behind := -(Vector2(float(a["x"]), float(a["s"])) - door).dot(out)
		var h := e.ring.height(e._world_pos())
		print("[Test] bay exit %s (%s): contacts %d, %.1f m in front of the door, h %.1f" % [e.target_id, e.enemy_type,
			int(contacts.get(e.target_id, 0)), -behind, h])
		eq(int(contacts.get(e.target_id, 0)), 0, "%s (%s) never touches the bay, its lintel or the door" % [e.target_id, e.enemy_type])
		check(behind < -2.0, "%s (%s) is out in the deck (%.1f m past the door)" % [e.target_id, e.enemy_type, -behind])
		check(h >= (EnemyDrone.ALT_MIN - 1.5 if e.enemy_type == "drone" else EnemyGunship.ALT_MIN - 1.0),
			"%s (%s) flies at its height again (%.1f m)" % [e.target_id, e.enemy_type, h])
		e.apply_damage(1.0e7, e.core_component(), "test")
