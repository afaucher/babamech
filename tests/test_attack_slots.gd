extends TestCase
## Attack-slot pruning (EnemySquad.request_attack_slot / prune_attack_slots). Regression: solo play allows one attacker
## per pilot (TestDriveCombat: max_attackers 1) and a holder that went to sleep (its deck lost its crew) kept the slot
## forever, so no other enemy could ever fire at that pilot (a bot run: no enemy fired for 340 s). A holder now loses its
## slot when it is dead, asleep, switched target, or held it SLOT_STALE s without telegraphing or firing.


func setup() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 5
	w.use_physics = false
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.max_attackers = 1
	sq.slot_stagger = 0.0
	var a := _enemy(w, sq, "a")
	var b := _enemy(w, sq, "b")
	a._target_id = "p1"
	b._target_id = "p1"
	check(sq.request_attack_slot("a", "p1"), "a takes the only slot")
	check(not sq.request_attack_slot("b", "p1"), "b waits while a holds it")
	# a falls asleep (dormant: the same _is_awake() a crew-less deck gives).
	a.staged = true
	check(sq.request_attack_slot("b", "p1"), "a sleeping holder loses the slot: b takes it")
	a.staged = false
	sq.release_attack_slot("b")
	# Switched target.
	check(sq.request_attack_slot("a", "p1"), "a takes it again")
	a._target_id = "p2"
	check(sq.request_attack_slot("b", "p1"), "a holder that switched target loses it")
	sq.release_attack_slot("b")
	# Stale: held SLOT_STALE s without telegraphing / firing.
	a._target_id = "p1"
	check(sq.request_attack_slot("a", "p1"), "a holds it")
	a.ai_state = EnemyBase.STATE_ENGAGE
	w.now += EnemySquad.SLOT_STALE - 1.0
	check(not sq.request_attack_slot("b", "p1"), "a fresh holder keeps it")
	a.ai_state = EnemyBase.STATE_FIRE
	w.now += 5.0
	check(not sq.request_attack_slot("b", "p1"), "a firing holder keeps it however long")
	a.ai_state = EnemyBase.STATE_ENGAGE
	check(sq.request_attack_slot("b", "p1"), "a holder idle with the slot past SLOT_STALE loses it")
	sq.release_attack_slot("b")
	# Dead.
	check(sq.request_attack_slot("a", "p1"), "a holds it")
	a.apply_damage(1.0e7, a.core_component(), "test")
	check(sq.request_attack_slot("b", "p1"), "a dead holder loses it")
	finish()


func _enemy(w: CombatWorld, sq: EnemySquad, id: String) -> EnemyBase:
	var e := EnemySpawner.make_enemy("strider")
	e.configure("strider", id, w, sq, null, 1)
	e._built_visuals = true
	sq.add_enemy(e)
	return e
