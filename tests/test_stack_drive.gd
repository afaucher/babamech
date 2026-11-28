extends TestCase
## The solo test drive in the multi-deck city stack (W2, the default city; MissionScene "THE CITY"):
## - it builds a CityStack from the seed (several decks, the entry deck at the world origin), `td.city` is the entry deck
##   (so the single-district systems still have a district), and enemies found spots on it;
## - with a mission world (CityStack.spawn_in_bay(): the solo drive plays the plan) the mech spawns in the ENTRY BAY
##   (docs/design/city-spine.md §4): crew_spawn(i, n) = CityStack.entry_bay_slots(n) for n = 1..4, every slot inside the
##   bay (MissionWorld.bay_contains), >= 7.2 m apart, facing out through the entry door; a lone mech mid front row. Without
##   one (a stack with no mission world) it spawns at CityStack.entry_transform() and a crew of 4 gets four slots on the
##   entry road, none overlapping;
## - after a few seconds it still stands on the entry deck (did not fall through), grounded, inside the deck's plan (or the
##   bay); once the entry door is passable it walks out into the map; the camera's deck is the active (daylit) deck;
## - dropped below the lowest deck it respawns at its spawn slot; N (new city, solo) rebuilds the stack on the next seed
##   (and the mission world: back in the new entry bay);
## - an offline crew (MissionScene.offline_crew = 4) spawns 3 idle puppets in the crew slots;
## - the stack is the only city: a forced city_mode or `--district` changes nothing (the district mode was cut).


func setup() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(4)
	var st := td.stack
	if not check(st != null and td.city_mode == MissionScene.MODE_STACK, "the solo test drive builds the stack"):
		finish()
		return
	var k := int(st.section.entry["deck"])
	print("stack seed %d: %d decks, entry deck %d, checksum %s, %d enemies, build %s" % [td.seed_value, st.decks.size(), k,
		st.checksum(), td.combat.enemies.size(), str(st.stats)])
	check(st.decks.size() > 1, "several decks (%d)" % st.decks.size())
	check(td.city != null and td.city == st.decks[k], "td.city is the stack's entry deck")
	check(td.city.global_position.length() < 0.001, "the entry deck sits at the world origin (%s)" % td.city.global_position)
	check(td.city.plan.buildings.size() > 10, "the entry deck has a city (%d buildings)" % td.city.plan.buildings.size())
	check(td.mission != null and td.mission.plan != null, "the solo drive plays the plan (the one mission mode)")
	eq(td.mission_checksum(), st.checksum() + "/" + td.mission.plan.checksum(), "the mission checksum is the stack's + the plan's")
	check(td.combat.enemies.size() >= 3, "enemies found spots on the entry deck (%d)" % td.combat.enemies.size())
	for e in td.combat.enemies:
		if is_instance_valid(e):
			var arc := td.city.ring.world_to_arc(e.global_position)
			check(td.city.plan.extent.grow(1.0).has_point(Vector2(arc.x, arc.y)), "enemy %s is inside the entry deck" % e.name)
	var entry := st.entry_transform()
	var in_bay := st.spawn_in_bay()
	check(in_bay, "the solo drive's mission world has an entry bay (the crew spawns in it)")
	var home := td.crew_spawn(0, 1)
	eq(td.spawn_xf.origin.distance_to(home.origin) < 0.01, true, "spawn_xf is the solo slot")
	check(td.mech.global_position.distance_to(home.origin) < 1.0, "the mech spawns at its slot (%.2f m off)"
		% td.mech.global_position.distance_to(home.origin))
	if in_bay:
		_check_bay_slots(td)
	else:
		check(home.origin.distance_to(entry.origin) < 0.01, "no mission world: the solo slot is the entry transform")
	# Stand for a few seconds: it must stay on the entry deck, on the floor.
	td.drive_override = true
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	for i in 180:
		await get_tree().physics_frame
	var p := td.mech.global_position
	eq(st.deck_at(p), k, "the mech is still on the entry deck after 3 s")
	var arc := td.city.ring.world_to_arc(p)
	check(absf(arc.z) < 1.0, "the mech stands on the floor (height %.2f)" % arc.z)
	check(td.mech.grounded(), "the mech is grounded")
	if in_bay:
		check(bool(st.mission.bay_contains(MissionWorld.ENTRY_ID, p)["inside"]), "the mech is inside the entry bay")
	else:
		check(td.city.plan.extent.has_point(Vector2(arc.x, arc.y)), "the mech is inside the entry deck's plan")
	check(p.distance_to(home.origin) < 2.0, "the mech stayed at its slot (%.2f m)" % p.distance_to(home.origin))
	await frames(20)
	eq(st.active_deck, st.deck_at(td.cam.global_position), "the active deck follows the camera")
	if in_bay:
		# The entry door opens by itself (MissionWorld.ENTRY_OPEN_DEFAULT): passable 3 s after clock 0.
		for i in 600:
			if bool(st.mission.source_state(MissionWorld.ENTRY_ID)["passable"]):
				break
			await get_tree().physics_frame
		check(bool(st.mission.source_state(MissionWorld.ENTRY_ID)["passable"]), "the entry door becomes passable")
	# Walk into the map a little (out of the bay through the door): it stays on the deck.
	for i in 120:
		td.mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
	td.mech.move_input = Vector2.ZERO
	check(td.mech.global_position.distance_to(p) > 6.0, "the mech walks into the map (%.1f m)" % td.mech.global_position.distance_to(p))
	eq(st.deck_at(td.mech.global_position), k, "and stays on the entry deck")
	if in_bay:
		var out := st.mission.bay_contains(MissionWorld.ENTRY_ID, td.mech.global_position)
		check(not bool(out["inside"]) and float(out["depth"]) < 0.0, "the mech walked out of the bay into the map (depth %.1f m)"
			% float(out["depth"]))
	else:
		# A crew of 4 on the entry road: distinct, non-overlapping slots near the entry, facing into the map.
		_check_road_slots(td, entry)
	# Below the lowest deck: back to the entry.
	var low := st.section.radius_of(st.section.deck_count - 1)
	td.mech.global_position = td.city.ring.arc_to_world(arc.x, arc.y, td.city.ring.radius - low - MissionScene.FALL_OUT - 5.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(td.mech.global_position.distance_to(home.origin) < 1.0, "fell below the lowest deck: respawned at its slot")
	# N: a new stack on the next seed.
	var cs := td.mission_checksum()
	td.build_city(td.seed_value + 1)
	await frames(3)
	check(td.mission_checksum() != cs, "a new seed builds a different stack")
	check(td.city == td.stack.decks[int(td.stack.section.entry["deck"])], "td.city is the new stack's entry deck")
	check(td.stack.spawn_in_bay(), "the new stack's mission world has an entry bay")
	check(td.mech.global_position.distance_to(td.crew_spawn(0, 1).origin) < 1.0, "respawned at the new entry slot")
	if td.stack.spawn_in_bay():
		check(bool(td.stack.mission.bay_contains(MissionWorld.ENTRY_ID, td.mech.global_position)["inside"]),
			"respawned inside the new entry bay")
	td.queue_free()
	await frames(2)
	# An offline crew of 4 (MissionScene.offline_crew, perf tests): your mech + 3 idle puppets in the crew slots.
	MissionScene.offline_crew = 4
	var tdc := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(tdc)
	MissionScene.offline_crew = 0
	await frames(4)
	eq(tdc.mechs.size(), 4, "the offline crew has 4 mechs")
	eq(tdc.spawn_order.size(), 4, "in seat order")
	for i in 4:
		var mi := tdc.mech_of(tdc.spawn_order[i])
		check(i == 0 or mi.puppet, "offline crew mech %d is an idle puppet" % i)
		check(mi.global_position.distance_to(tdc.crew_spawn(i, 4).origin) < 1.0, "offline crew mech %d is in its slot" % i)
		if tdc.stack.spawn_in_bay():
			check(bool(tdc.stack.mission.bay_contains(MissionWorld.ENTRY_ID, mi.global_position)["inside"]),
				"offline crew mech %d starts in the entry bay" % i)
	tdc.queue_free()
	await frames(2)
	# The stack is the only city: an old forced mode ("district") still builds the stack.
	var tdd := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	tdd.city_mode = "district"
	add_child(tdd)
	await frames(4)
	check(tdd.stack != null and tdd.city_mode == MissionScene.MODE_STACK and tdd.city == tdd.stack.decks[int(tdd.stack.section.entry["deck"])],
		"a forced 'district' city_mode builds the stack")
	tdd.queue_free()
	await frames(1)
	# No mission world (the TEST-ONLY quiet fixture builds no plan): the avenue start as before.
	QuietSectionFixture.arm()
	var tdq := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(tdq)
	await frames(4)
	QuietSectionFixture.disarm()
	check(not tdq.stack.spawn_in_bay(), "quiet section: no mission world, no entry bay spawn")
	var qe := tdq.stack.entry_transform()
	check(tdq.mech.global_position.distance_to(qe.origin) < 1.0, "quiet section: the mech spawns at the entry transform (%.2f m off)"
		% tdq.mech.global_position.distance_to(qe.origin))
	_check_road_slots(tdq, qe)
	tdq.queue_free()
	await frames(1)
	finish()


## The entry bay's crew slots (docs/design/city-spine.md §4): crew_spawn = entry_bay_slots for 1..4 mechs, each inside the
## bay, >= 7.2 m apart, facing out through the door; a lone mech in the middle of the front row.
func _check_bay_slots(td: MissionScene) -> void:
	var st := td.stack
	var w := st.mission
	var door := w.entry_door()
	var facing: Vector3 = door["facing"]
	for n in range(1, 5):
		var bay := st.entry_bay_slots(n)
		eq(bay.size(), n, "%d mechs: %d entry bay slots" % [n, n])
		var pts: Array[Vector3] = []
		for i in mini(n, bay.size()):
			var xf := td.crew_spawn(i, n)
			pts.append(xf.origin)
			check(xf.is_equal_approx(bay[i]), "%d mechs: crew slot %d is entry_bay_slots(%d)[%d]" % [n, i, n, i])
			var bc := w.bay_contains(MissionWorld.ENTRY_ID, xf.origin)
			check(bool(bc["inside"]), "%d mechs: slot %d is inside the entry bay (depth %.1f m)" % [n, i, float(bc["depth"])])
			check((-xf.basis.z).dot(facing) > 0.85, "%d mechs: slot %d faces out through the entry door (aimed slots up to ~28 deg off)" % [n, i])
		for i in pts.size():
			for j in range(i + 1, pts.size()):
				check(pts[i].distance_to(pts[j]) >= 7.2, "%d mechs: slots %d and %d are >= 7.2 m apart (%.2f m)" % [n, i, j,
					pts[i].distance_to(pts[j])])
	var one := w.bay_contains(MissionWorld.ENTRY_ID, td.crew_spawn(0, 1).origin)
	near(float(one["depth"]), MissionWorld.BAY_ROWS[0], 0.5, "a lone mech stands in the front row")
	var fr: Transform3D = door["frame"]
	near((fr.affine_inverse() * td.crew_spawn(0, 1).origin).x, 0.0, 1.0, "a lone mech stands on the door's centre line (slots sit as near it as the bay allows)")


## Without a mission world: a crew of 4 on the entry road, distinct, non-overlapping slots near the entry, facing in.
func _check_road_slots(td: MissionScene, entry: Transform3D) -> void:
	var slots: Array[Vector3] = []
	for i in 4:
		var xf := td.crew_spawn(i, 4)
		slots.append(xf.origin)
		check(xf.origin.distance_to(entry.origin) < 16.0, "crew slot %d is on the entry road" % i)
		check((-xf.basis.z).dot(-entry.basis.z) > 0.95, "crew slot %d faces into the map" % i)
		near(td.city.ring.height(xf.origin), td.city.ring.height(entry.origin), 0.05, "crew slot %d is at the entry's height" % i)
	for i in 4:
		for j in range(i + 1, 4):
			check(slots[i].distance_to(slots[j]) >= 4.4, "crew slots %d and %d don't overlap (%.2f m)" % [i, j, slots[i].distance_to(slots[j])])
