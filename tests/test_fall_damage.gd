extends TestCase
## Fall damage (docs/design/weapons.md, "Fall damage"): a mech that lands faster than MechController.fall_damage_speed
## takes damage to both legs on its own machine (PlayerTarget, the normal damage path), scaled by the impact speed, plus a
## little to the torso on extreme falls. Landing thrusters (the emergency burn) prevent it when they can fire; a shut down
## (overheated) mech has no cushion. Flat world (+Y up, gravity 22), a floor slab, the mech dropped from deck heights
## (SectionPlan "pitch" = 48 m floor to floor):
## (a) two decks (96 m) while shut down: both legs heavily damaged, not destroyed, the mech not disabled;
## (b) the same drop with working thrusters: no damage;
## (c) one deck (48 m) with working thrusters: no damage;
## (d) a puppet of the mech shows the damaged legs through the snapshot path (CrewSync.component_fractions ->
##     MechPuppet._apply_damage), and a puppet's own controller never applies fall damage.

const PITCH := 48.0


func setup() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -1, 0)
	add_child(floor_body)
	var mech := MechSpawn.make("chicken", "strider", {}, 1)
	add_child(mech)
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, MechSpawn.rig_of(mech).model, "player1", 1)
	world.register(pt)
	var hits := []
	pt.damaged.connect(func(amount: float, component: String, src: String) -> void: hits.append([amount, component, src]))

	# (a) Two decks, shut down.
	var impact := await _drop(mech, pt, PITCH * 2.0, true)
	var legs := [float(pt.hp["leg_l"]), float(pt.hp["leg_r"])]
	print("[fall] two decks shut down: impact %.1f m/s, legs %.0f / %.0f, torso %.0f, hits %s" % [impact, legs[0], legs[1],
		float(pt.hp["torso"]), str(hits)])
	check(mech.shutdown, "still shut down at touchdown (no cushion)")
	check(impact > 50.0, "lands hard (%.1f m/s)" % impact)
	for i in 2:
		var cap := float(PlayerTarget.COMPONENT_HP["leg_l"])
		check(legs[i] < cap * 0.5, "leg %d heavily damaged (%.0f / %.0f)" % [i, legs[i], cap])
		check(legs[i] > 0.0, "leg %d not destroyed by a two-deck fall (%.0f)" % [i, legs[i]])
	check(not pt.disabled, "a healthy mech survives a two-deck fall")
	check(float(pt.hp["torso"]) < float(PlayerTarget.COMPONENT_HP["torso"]), "an extreme fall also dents the torso")
	check(float(pt.hp["head"]) >= float(PlayerTarget.COMPONENT_HP["head"]), "the head is untouched")
	var srcs := {}
	for h: Array in hits:
		srcs[str(h[2])] = true
	check(srcs.has("fall") and srcs.size() == 1, "damage arrives through PlayerTarget.damaged, src \"fall\" (%s)" % str(srcs))

	# (d) A puppet of this mech on another machine shows the legs (the owner's snapshot fractions).
	var pmech := MechSpawn.make("chicken", "strider", {}, 2)
	pmech.puppet = true
	add_child(pmech)
	var ppt := PlayerTarget.new()
	ppt.auto_respawn_delay = -1.0
	add_child(ppt)
	ppt.bind(world, pmech, MechSpawn.rig_of(pmech).model, "player2", 2)
	var pup := MechPuppet.new()
	pup.target = ppt
	var st := NetMechState.new()
	st.comp = CrewSync.component_fractions(pt)
	pup._apply_damage(st)
	near(float(ppt.hp["leg_l"]), legs[0], 1.0, "the puppet shows the owner's left leg")
	near(float(ppt.hp["leg_r"]), legs[1], 1.0, "the puppet shows the owner's right leg")
	pup.free()
	# A puppet's hard_landing (posing / audio) never deals damage: its owner decides.
	var before := float(ppt.hp["leg_l"])
	pmech.hard_landing.emit(60.0, 1.0)
	near(float(ppt.hp["leg_l"]), before, 1e-6, "a puppet's landing does no damage here")

	# (b) The same drop with working thrusters: the emergency burn cushions it.
	pt.repair_all()
	hits.clear()
	impact = await _drop(mech, pt, PITCH * 2.0, false)
	print("[fall] two decks, thrusters live: impact %.1f m/s, heat %.0f, hits %s" % [impact, mech.heat, str(hits)])
	check(not mech.shutdown, "thrusters stayed available")
	check(hits.is_empty(), "no fall damage with working thrusters (%s)" % str(hits))

	# (c) One deck with working thrusters.
	pt.repair_all()
	hits.clear()
	impact = await _drop(mech, pt, PITCH, false)
	print("[fall] one deck, thrusters live: impact %.1f m/s, hits %s" % [impact, str(hits)])
	check(hits.is_empty(), "no fall damage on a one-deck drop with working thrusters (%s)" % str(hits))
	finish()


## Place the mech `height` m above the floor at rest (cold, or overheated and shut down), let it fall; the impact speed.
func _drop(mech: MechController, pt: PlayerTarget, height: float, shut: bool) -> float:
	mech.velocity = Vector3.ZERO
	mech.move_input = Vector2.ZERO
	mech.thrust_input = false
	mech.heat = 0.0
	mech.shutdown = false
	mech.global_position = Vector3(0, height, 0)
	if shut:
		mech.add_heat(mech.heat_cap)
	pt.global_position = mech.global_position
	await get_tree().physics_frame
	var n := 0
	while n < 900:
		await get_tree().physics_frame
		n += 1
		if mech.grounded() and n > 10:
			break
	for i in 5:
		await get_tree().physics_frame
	return mech.last_impact
