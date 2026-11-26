extends TestCase
## The solo test drive in the multi-deck city stack (W2, the default city; TestDrive "THE CITY"):
## - it builds a CityStack from the seed (several decks, the entry deck at the world origin), `td.city` is the entry deck
##   (so the single-district systems still have a district), and enemies found spots on it;
## - the mech spawns at CityStack.entry_transform() and, after a few seconds, still stands on the entry deck (did not fall
##   through), grounded, inside the deck's plan; the camera's deck is the active (daylit) deck;
## - TestDrive.entry_spawn gives a crew of 4 four slots on the entry road, none overlapping;
## - dropped below the lowest deck it respawns at the entry; N (new city, solo) rebuilds the stack on the next seed;
## - an offline crew (TestDrive.offline_crew = 4) spawns 3 idle puppets in the crew slots;
## - the stack is the only city: a forced city_mode or `--district` changes nothing (the district mode was cut).


func setup() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(4)
	var st := td.stack
	if not check(st != null and td.city_mode == TestDrive.MODE_STACK, "the solo test drive builds the stack"):
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
	check(td.mech.global_position.distance_to(entry.origin) < 1.0, "the mech spawns at the entry (%.2f m off)"
		% td.mech.global_position.distance_to(entry.origin))
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
	check(td.city.plan.extent.has_point(Vector2(arc.x, arc.y)), "the mech is inside the entry deck's plan")
	check(p.distance_to(entry.origin) < 2.0, "the mech stayed at the entry (%.2f m)" % p.distance_to(entry.origin))
	await frames(20)
	eq(st.active_deck, st.deck_at(td.cam.global_position), "the active deck follows the camera")
	# Walk into the map a little: it stays on the deck.
	for i in 120:
		td.mech.move_input = Vector2(0, 1)
		await get_tree().physics_frame
	td.mech.move_input = Vector2.ZERO
	check(td.mech.global_position.distance_to(p) > 6.0, "the mech walks into the map (%.1f m)" % td.mech.global_position.distance_to(p))
	eq(st.deck_at(td.mech.global_position), k, "and stays on the entry deck")
	# A crew of 4 on the entry road: distinct, non-overlapping slots near the entry, facing into the map.
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
	# Below the lowest deck: back to the entry.
	var low := st.section.radius_of(st.section.deck_count - 1)
	td.mech.global_position = td.city.ring.arc_to_world(arc.x, arc.y, td.city.ring.radius - low - TestDrive.FALL_OUT - 5.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(td.mech.global_position.distance_to(entry.origin) < 1.0, "fell below the lowest deck: respawned at the entry")
	# N: a new stack on the next seed.
	var cs := td.mission_checksum()
	td.build_city(td.seed_value + 1)
	await frames(3)
	check(td.mission_checksum() != cs, "a new seed builds a different stack")
	check(td.city == td.stack.decks[int(td.stack.section.entry["deck"])], "td.city is the new stack's entry deck")
	check(td.mech.global_position.distance_to(td.stack.entry_transform().origin) < 1.0, "respawned at the new entry")
	td.queue_free()
	await frames(2)
	# An offline crew of 4 (TestDrive.offline_crew, perf tests): your mech + 3 idle puppets in the crew slots.
	TestDrive.offline_crew = 4
	var tdc := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(tdc)
	TestDrive.offline_crew = 0
	await frames(4)
	eq(tdc.mechs.size(), 4, "the offline crew has 4 mechs")
	eq(tdc.spawn_order.size(), 4, "in seat order")
	var ce := tdc.stack.entry_transform()
	for i in 4:
		var mi := tdc.mech_of(tdc.spawn_order[i])
		check(i == 0 or mi.puppet, "offline crew mech %d is an idle puppet" % i)
		check(mi.global_position.distance_to(tdc.crew_spawn(i, 4).origin) < 1.0, "offline crew mech %d is in its slot" % i)
	tdc.queue_free()
	await frames(2)
	# The stack is the only city: an old forced mode ("district") still builds the stack.
	var tdd := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	tdd.city_mode = "district"
	add_child(tdd)
	await frames(4)
	check(tdd.stack != null and tdd.city_mode == TestDrive.MODE_STACK and tdd.city == tdd.stack.decks[int(tdd.stack.section.entry["deck"])],
		"a forced 'district' city_mode builds the stack")
	tdd.queue_free()
	await frames(1)
	finish()
