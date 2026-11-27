extends TestCase
## Attack-slot pruning (EnemySquad.request_attack_slot / prune_attack_slots). Regression: solo play allows one attacker
## per pilot (MissionCombat: max_attackers 1) and a holder that went to sleep (its deck lost its crew) kept the slot
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
	_pruned_holder_flag(w)
	finish()


## Audit fix (docs/code-audit-2026-11.md): pruning took the slot out of the squad's table but left the unit's own
## _has_slot set, so _request_slot answered true and the unit fired on top of max_attackers after its deck slept and
## woke. Pruning now goes through EnemySquad._revoke_slot, which clears both sides.
func _pruned_holder_flag(w: CombatWorld) -> void:
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	sq.max_attackers = 1
	sq.slot_stagger = 0.0
	var a := _enemy(w, sq, "pa")
	var b := _enemy(w, sq, "pb")
	a._target_id = "p1"
	b._target_id = "p1"
	check(a._request_slot("p1"), "pa takes the only slot through its own request")
	check(a._has_slot, "pa holds it")
	a.staged = true   # its deck sleeps
	check(b._request_slot("p1"), "pb takes the slot from the sleeping holder")
	check(not a._has_slot, "the pruned holder no longer believes it holds a slot")
	a.staged = false  # wakes
	check(not a._request_slot("p1"), "woken, pa must request again and waits (pb holds the only slot)")
	eq(sq.active_slots_for("p1"), 1, "one slot in use, no drift")
	var holders := 0
	for e: EnemyBase in [a, b]:
		if e._has_slot:
			holders += 1
	eq(holders, 1, "exactly one unit believes it holds a slot")
	# A holder pruned mid-telegraph (it switched target) drops the telegraph: no shot without a real slot.
	b._release_slot()
	check(a._request_slot("p1"), "pa holds it")
	a._begin_telegraph(str(a._cfg.get("primary_weapon", "")), Vector3(0, 0, -40))
	eq(a.ai_state, EnemyBase.STATE_TELEGRAPH, "pa telegraphs")
	a._target_id = "p2"
	check(b._request_slot("p1"), "pb takes the slot of the holder that switched target")
	check(not a._has_slot and a.ai_state != EnemyBase.STATE_TELEGRAPH, "pa lost it and its telegraph (%s)" % a.ai_state)
	# Leaving the squad clears the flag too.
	sq.remove_enemy(b)
	check(not b._has_slot, "a unit removed from the squad holds no slot")
	eq(sq.active_slots_for("p1"), 0, "no slot left in use")
	sq.queue_free()


func _enemy(w: CombatWorld, sq: EnemySquad, id: String) -> EnemyBase:
	var e := EnemySpawner.make_enemy("strider")
	e.configure("strider", id, w, sq, null, 1)
	e._built_visuals = true
	sq.add_enemy(e)
	return e
