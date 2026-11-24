extends TestCase
## Enemies hear player fire (EnemySquad hearing + EnemyBase.hear_fire; docs/design/enemies.md "Hearing"): an un-alerted
## live enemy that a player shot passes within HEAR_SHOT_RADIUS of, or that hears an impact / blast within
## HEAR_IMPACT_RADIUS + splash radius, or a player hit on a squadmate near it, alerts toward the shooter (the normal
## ALERT_DELAY wind-up) and relays to its squad like a spotter. Enemy fire, far fire, idle AI and fire on another deck do
## nothing. Slow shots are heard when they reach the closest point. Single process, no physics (sight is only FOV / range).

const DT := 1.0 / 60.0

var _w: CombatWorld
var _sq: EnemySquad
var _p: CombatTarget


func setup() -> void:
	await _shot_near_alerts_and_turns()
	await _shot_far_does_not()
	await _impact_near_and_far()
	await _enemy_fire_ignored()
	await _idle_ai_ignores()
	await _heard_alert_relays()
	await _slow_shot_heard_on_arrival()
	await _other_deck_ignored()
	await _squadmate_hit_heard()
	finish()


# --- Fixture -----------------------------------------------------------------------------------------------

## A fresh world + squad and a player target at `player_at` (team "player", id player1, peer 1).
func _rig(player_at: Vector3) -> void:
	_w = CombatWorld.new()
	_w.mission_seed = 31
	_w.use_physics = false
	add_child(_w)
	_sq = EnemySquad.new()
	add_child(_sq)
	_sq.setup(_w)
	_p = CombatTarget.new()
	_p.target_id = "player1"
	_p.owner_peer = 1
	_p.team = "player"
	_p.mass_class = "mech"
	_p.set_max_hp({"torso": 50000.0})
	_p.add_hit_sphere("torso", Vector3(0, 4.0, 0), 2.0)
	_p.position = player_at
	add_child(_p)
	_w.register(_p)


func _enemy(type: String, id: String, at: Vector3, seed_val: int = 1) -> EnemyBase:
	var e: EnemyBase
	match type:
		"turret": e = EnemyTurret.new()
		"strider": e = EnemyStrider.new()
		_: e = EnemyTank.new()
	e.configure(type, id, _w, _sq, null, seed_val)
	e.position = at        # default facing -Z: every player here stands behind (+Z), out of its field of view
	_sq.add_enemy(e)
	return e


func _teardown() -> void:
	for n: Node in [_p, _sq, _w]:
		if is_instance_valid(n):
			n.queue_free()
	await frames(1)


func _step(seconds: float) -> void:
	for _i in int(round(seconds / DT)):
		_w.advance(DT)


## A player fire record from player1 (peer 1).
func _rec(weapon: String, origin: Vector3, aim: Vector3, idx: int) -> Dictionary:
	return Combat.fire_record("player1", 1, "side_l", weapon, origin, aim, _w.now, idx, 0.0)


## A laser (hitscan) shot along x = `x` from z = 50 to z = -50, at muzzle height: passes |x| m from an enemy at the origin.
func _laser_along(x: float, idx: int) -> void:
	_w.fire(_rec("laser", Vector3(x, 4.0, 50.0), Vector3(x, 3.0, -50.0), idx))


# --- Cases -------------------------------------------------------------------------------------------------

func _shot_near_alerts_and_turns() -> void:
	_rig(Vector3(10, 0, 50))
	var t := _enemy("turret", "hear_t1", Vector3.ZERO)
	await frames(1)
	var alert_at := [-1.0]
	var tele_at := [-1.0]
	var reason := [""]
	_sq.enemy_event.connect(func(kind: String, en: Node, pl: Dictionary) -> void:
		if en != t:
			return
		if kind == "alerted" and alert_at[0] < 0.0:
			alert_at[0] = _w.now
			reason[0] = str(pl.get("state", ""))
		elif kind == "telegraph_started" and tele_at[0] < 0.0:
			tele_at[0] = _w.now)
	_step(0.3)
	check(not t.is_alerted(), "a turret facing away from a player 51 m behind it does not see it")
	var checks0 := _sq.hear_checks
	_laser_along(10.0, 1)
	check(_sq.hear_checks > checks0, "the shot reached the hearing")
	check(t.is_alerted(), "a player laser passing 10 m from the turret alerts it at once (hitscan)")
	eq(reason[0], "spotted", "it alerts as a spotter (its own relay runs)")
	eq(t.ai_state, EnemyBase.STATE_ALERT, "it enters the normal ALERT wind-up")
	check(EnemyBase.ALERT_DELAY >= 0.3, "ALERT_DELAY %.2f s >= 0.3 s" % EnemyBase.ALERT_DELAY)
	check(_sq.known_targets.has("player1"), "the heard shooter is on the squad board")
	_step(4.0)
	var local_p := t.global_transform.affine_inverse() * (_p.global_position + Vector3.UP * 4.0)
	var want := atan2(-local_p.x, -local_p.z)
	var yaw := float(t.get("_yaw"))
	check(absf(wrapf(want - yaw, -PI, PI)) < 0.25, "the turret turned toward the shooter (yaw %.2f, want %.2f)" % [yaw, want])
	check(tele_at[0] > 0.0, "it went on to telegraph at the shooter")
	if tele_at[0] > 0.0:
		check(tele_at[0] - alert_at[0] >= 0.3 - 1e-4, "the alert wind-up before the first telegraph is >= 0.3 s (%.2f s)" % (
			tele_at[0] - alert_at[0]))
	await _teardown()


func _shot_far_does_not() -> void:
	_rig(Vector3(80, 0, 50))
	var t := _enemy("turret", "hear_t2", Vector3.ZERO)
	t.sight_range = 30.0   # hearing only: a firing mech is otherwise noticed by sight in any direction (EnemyBase.LOUD_TIME)
	await frames(1)
	_step(0.1)
	_laser_along(80.0, 2)
	_step(1.0)
	check(not t.is_alerted(), "the same shot 80 m away does not alert it")
	eq(_sq.pending_hearings(), 0, "and nothing is pending")
	await _teardown()


func _impact_near_and_far() -> void:
	_rig(Vector3(0, 0, 120))
	var near_t := _enemy("turret", "hear_imp_near", Vector3.ZERO)
	var far_t := _enemy("turret", "hear_imp_far", Vector3(200, 0, 0), 2)
	await frames(1)
	_step(0.1)
	var st := _w.stats("mortar")
	var rad := float(st.get("splash_radius", 0.0))
	check(rad > 0.0, "the mortar has a splash radius (%.1f m)" % rad)
	# A shell landing 30 m from near_t (inside 30 + splash radius), ~170 m from far_t.
	_w.splash(_rec("mortar", Vector3(0, 4, 120), Vector3(30, 0, 0), 3), st, Vector3(30, 0.2, 0))
	check(near_t.is_alerted(), "a player blast 30 m away (radius %.0f + %.1f) alerts the turret" % [EnemySquad.HEAR_IMPACT_RADIUS, rad])
	check(not far_t.is_alerted(), "a turret 170 m from it does not")
	# A plain round's impact (radius 0) 50 m from far_t: out of HEAR_IMPACT_RADIUS.
	_w.splash(_rec("autocannon", Vector3(0, 4, 120), Vector3(150, 0, 0), 4), _w.stats("autocannon"), Vector3(150, 0.5, 0))
	check(not far_t.is_alerted(), "a plain impact 50 m away does not alert")
	_w.splash(_rec("autocannon", Vector3(0, 4, 120), Vector3(180, 0, 0), 5), _w.stats("autocannon"), Vector3(180, 0.5, 0))
	check(far_t.is_alerted(), "a plain impact 20 m away does")
	await _teardown()


func _enemy_fire_ignored() -> void:
	_rig(Vector3(10, 0, 50))
	var t := _enemy("turret", "hear_t3", Vector3.ZERO)
	await frames(1)
	_step(0.1)
	var checks0 := _sq.hear_checks
	var r := Combat.fire_record("other_enemy", 1, "laser", "laser", Vector3(10, 4, 50), Vector3(10, 3, -50), _w.now, 6, 0.0)
	r["enemy"] = true
	r["team"] = "enemy"
	_w.fire(r)
	var r2 := r.duplicate()
	r2["weapon"] = "mortar"
	r2["shot_index"] = 7
	_w.splash(r2, _w.stats("mortar"), Vector3(5, 0.2, 0))
	_step(0.5)
	check(not t.is_alerted(), "enemy fire (a shot 10 m away, a blast 5 m away) never alerts enemies")
	eq(_sq.hear_checks, checks0, "enemy records are dropped before any hearing work")
	await _teardown()


func _idle_ai_ignores() -> void:
	_rig(Vector3(10, 0, 50))
	var t := _enemy("turret", "hear_t4", Vector3.ZERO)
	t.ai_mode = "idle"
	await frames(1)
	_step(0.1)
	_laser_along(10.0, 8)
	_w.splash(_rec("mortar", Vector3(10, 4, 50), Vector3(5, 0, 0), 9), _w.stats("mortar"), Vector3(5, 0.2, 0))
	_step(0.5)
	check(not t.is_alerted(), "an ai_mode 'idle' enemy never reacts to fire")
	eq(t.ai_state, EnemyBase.STATE_IDLE, "it stays idle")
	await _teardown()


func _heard_alert_relays() -> void:
	_rig(Vector3(-10, 0, 50))
	var t := _enemy("turret", "hear_relay_t", Vector3.ZERO)
	var buddy := _enemy("strider", "hear_relay_buddy", Vector3(30, 0, -20), 2)
	buddy.sight_range = 10.0
	await frames(1)
	_step(0.1)
	var buddy_reason := [""]
	_sq.enemy_event.connect(func(kind: String, en: Node, pl: Dictionary) -> void:
		if en == buddy and kind == "alerted" and buddy_reason[0] == "":
			buddy_reason[0] = str(pl.get("state", "")))
	_laser_along(-10.0, 10)   # 10 m from the turret, 40 m from the buddy (out of hearing), buddy 36 m from the turret
	check(t.is_alerted() and not buddy.is_alerted(), "the turret hears the shot; its squadmate 40 m off the path does not")
	_step(0.25)
	check(not buddy.is_alerted(), "no relay before RELAY_DELAY")
	_step(0.4)
	check(buddy.is_alerted(), "the heard alert relays to a squadmate in RELAY_RADIUS after the 0.45 s comm relay")
	eq(buddy_reason[0], "relay", "the squadmate alerts through the relay")
	await _teardown()


func _slow_shot_heard_on_arrival() -> void:
	_rig(Vector3(10, 0, 100))
	var t := _enemy("turret", "hear_t5", Vector3.ZERO)
	t.sight_range = 30.0   # hearing only: a firing mech is otherwise noticed by sight in any direction (EnemyBase.LOUD_TIME)
	await frames(1)
	_step(0.1)
	var st := _w.stats("autocannon")
	var speed := float(st["speed"])
	var arrive := 100.0 / speed
	check(arrive > 0.6, "the autocannon shell needs %.2f s to reach the turret's closest point" % arrive)
	_w.fire(_rec("autocannon", Vector3(10, 4, 100), Vector3(10, 3, -50), 11))
	check(not t.is_alerted(), "a slow shell is not heard at fire time")
	eq(_sq.pending_hearings(), 1, "its hearing is pending")
	_step(arrive - 0.25)
	check(not t.is_alerted(), "nor just before it arrives (%.2f s)" % (arrive - 0.25))
	_step(0.35)
	check(t.is_alerted(), "it is heard when it reaches the closest point (%.2f s)" % arrive)
	eq(_sq.pending_hearings(), 0, "the pending queue is empty again")
	await _teardown()


func _other_deck_ignored() -> void:
	_rig(Vector3(0, 0, 60))   # the player stands on deck 0 (x < 5), so deck 0 is awake
	var t := _enemy("turret", "hear_t6", Vector3.ZERO)
	t.spawn_deck = 0
	_sq.deck_of = func(pos: Vector3) -> int: return 0 if pos.x < 5.0 else 1
	await frames(1)
	_step(0.1)
	_laser_along(10.0, 12)   # its closest point (x = 10) is on deck 1
	_step(0.3)
	check(not t.is_alerted(), "a shot whose closest point is on another deck is not heard")
	_w.splash(_rec("mortar", Vector3(0, 4, 60), Vector3(12, 0, 0), 13), _w.stats("mortar"), Vector3(12, 0.2, 0))
	check(not t.is_alerted(), "nor a blast on another deck")
	_laser_along(-8.0, 14)   # x = -8: deck 0
	check(t.is_alerted(), "the same kind of shot on its own deck is")
	await _teardown()
	# A sleeping deck (no player on it) hears nothing.
	_rig(Vector3(20, 0, 60))   # the player is on deck 1
	var t2 := _enemy("turret", "hear_t7", Vector3.ZERO)
	_sq.deck_of = func(pos: Vector3) -> int: return 0 if pos.x < 5.0 else 1
	await frames(1)
	_step(0.1)
	_laser_along(-8.0, 15)
	_step(0.3)
	check(not t2.is_alerted(), "an enemy on a sleeping deck hears nothing")
	await _teardown()


func _squadmate_hit_heard() -> void:
	_rig(Vector3(0, 0, 80))
	var victim := _enemy("strider", "hear_victim", Vector3(20, 0, 0))
	var near_t := _enemy("turret", "hear_mate_near", Vector3.ZERO, 2)
	# 50 m from the hit (out of hearing), 67 m from near_t (out of its relay): only the dead victim could have told it.
	var far_t := _enemy("turret", "hear_mate_far", Vector3(60, 0, -30), 3)
	await frames(1)
	_step(0.1)
	var at := victim.eye_world()
	var r := _rec("railgun", Vector3(20, 4, 80), at, 16)
	_w.resolve_hit(r, _w.stats("railgun"), victim, "sensor", at, Vector3.BACK, Vector3.FORWARD, 100000.0)
	check(victim.destroyed(), "the squadmate dies in one hit (before its own 0.45 s relay)")
	check(near_t.is_alerted(), "a squadmate 20 m from the hit hears it and alerts")
	_step(1.0)
	check(not far_t.is_alerted(), "a squadmate 50 m from the hit does not hear it (killing the spotter still cuts its relay)")
	await _teardown()
