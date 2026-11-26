extends TestCase
## BotFireGuard (scripts/game/bot_fire_guard.gd; playtest: hangar bots shot the host with autocannon and missiles): a
## shooter engages an enemy 60 m ahead while a crew mech stands in the line of fire, crosses it, stands behind the
## enemy, walks onto the mortar's landing point or under its flying missiles. Real CombatWorld shots (no physics), fired
## by the guard's rules every frame (slot_safe before each shot, missile_abort leading flying missiles away). With the
## guard the crew mech is never damaged, for autocannon, missiles and mortar; without it (control) the same in-line
## scenes do hurt it, so the scenes are real; and with the mate well clear the guard still lets the shooter fire and hit.

const DT := 1.0 / 60.0
const SHOOTER := "player-1"
const MUZZLE := Vector3(1.5, 5.0, -1.0)
const ENEMY_AT := Vector3(0, 0, -60)
const UP := Vector3.UP


func setup() -> void:
	for wid: String in ["autocannon", "missiles", "mortar"]:
		await _weapon(wid)
	finish()


func _weapon(wid: String) -> void:
	var scenes: Dictionary = {}
	if wid == "mortar":
		scenes = {"beside the enemy": [ENEMY_AT + Vector3(5, 0, 0), Vector3.ZERO],
			"walking onto the landing point": [ENEMY_AT + Vector3(-24, 0, 0), Vector3(7, 0, 0)],
			"just short of the target": [ENEMY_AT + Vector3(0, 0, 9), Vector3.ZERO]}
	else:
		scenes = {"in the line": [Vector3(0, 0, -30), Vector3.ZERO],
			"crossing the line": [Vector3(-18, 0, -30), Vector3(6, 0, 0)],
			"behind the enemy": [ENEMY_AT + Vector3(1, 0, -25), Vector3.ZERO],
			"walking to the enemy": [ENEMY_AT + Vector3(-16, 0, 8), Vector3(5, 0, 0)]}
	for k: String in scenes:
		var r := await _scene(wid, scenes[k][0], scenes[k][1], true)
		eq(float(r["crew"]), 0.0, "%s, mate %s: the guard keeps it unhurt (%d shots, %d held frames)" % [wid, k,
			int(r["shots"]), int(r["held"])])
	var first: String = scenes.keys()[0]
	var ctl := await _scene(wid, scenes[first][0], scenes[first][1], false)
	check(float(ctl["crew"]) > 0.0, "%s, mate %s, no guard: the scene does hurt the mate (%.0f)" % [wid, first, float(ctl["crew"])])
	# A friendly relay (the defend's AssetTarget) between the shooter and the enemy (playtest: a bot's autocannon hit
	# the relay it defended): the guard keeps it unhurt; without the guard the scene does hurt it.
	var far := Vector3(200, 0, 50)
	var rg := await _scene(wid, far, Vector3.ZERO, true, Vector3(0, 0, -30) if wid != "mortar" else ENEMY_AT + Vector3(5, 0, 0))
	eq(float(rg["relay"]), 0.0, "%s, relay in the line of fire: the guard keeps it unhurt (%d shots, %d held)" % [wid,
		int(rg["shots"]), int(rg["held"])])
	var rc := await _scene(wid, far, Vector3.ZERO, false, Vector3(0, 0, -30) if wid != "mortar" else ENEMY_AT + Vector3(5, 0, 0))
	check(float(rc["relay"]) > 0.0, "%s, relay in the line, no guard: the scene does hurt the relay (%.0f)" % [wid, float(rc["relay"])])
	var ok := await _scene(wid, Vector3(30, 0, 5), Vector3.ZERO, true)
	check(int(ok["shots"]) > 0 and float(ok["enemy"]) > 0.0, "%s, mate clear: the guard lets it fire and hit (%d shots, %.0f)"
		% [wid, int(ok["shots"]), float(ok["enemy"])])


func _target(w: CombatWorld, id: String, team: String, peer: int, at: Vector3, mech: bool) -> CombatTarget:
	var t := CombatTarget.new()
	t.name = id
	t.target_id = id
	t.owner_peer = peer
	t.team = team
	t.mass_class = "mech"
	t.set_max_hp({"torso": 100000.0, "head": 100000.0, "leg_l": 100000.0, "leg_r": 100000.0})
	if mech:
		for s: Dictionary in PlayerTarget.BODY_SPHERES:
			t.add_hit_sphere(str(s["component"]), s["center"] as Vector3, float(s["radius"]))
	else:
		t.add_hit_sphere("torso", Vector3(0, 3, 0), 2.5)
	w.add_child(t)
	t.position = at
	w.register(t)
	return t


## One scene: {crew: damage to the mate, enemy: damage to the enemy, shots, held: frames the guard held fire}.
## `relay_at`: also a friendly defend relay (AssetTarget "asset_d1_p", team player) there, guarded through
## BotFireGuard.asset_states; its damage comes back as "relay".
func _scene(wid: String, mate_at: Vector3, mate_vel: Vector3, guard: bool, relay_at: Vector3 = Vector3.INF) -> Dictionary:
	var w := CombatWorld.new()
	w.mission_seed = 3
	w.use_physics = false
	w.friendly_fire = true
	add_child(w)
	_target(w, SHOOTER, "player", 1, Vector3.ZERO, true)
	var mate := _target(w, "player2", "player", 1, mate_at, true)
	var enemy := _target(w, "enemy1", "enemy", 0, ENEMY_AT, false)
	var dmg := {"crew": 0.0, "enemy": 0.0, "relay": 0.0}
	var relay: AssetTarget = null
	if relay_at != Vector3.INF:
		var holder := Node3D.new()
		w.add_child(holder)
		holder.position = relay_at
		relay = AssetTarget.new("d1_p", 2.5, 6.0)
		holder.add_child(relay)
		w.register(relay)
	w.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		if relay != null and t == relay:
			dmg["relay"] = float(dmg["relay"]) + h.damage
		elif t == mate:
			dmg["crew"] = float(dmg["crew"]) + h.damage
		elif t == enemy:
			dmg["enemy"] = float(dmg["enemy"]) + h.damage)
	var st := w.stats(wid)
	var interval := 1.0 / maxf(float(st.get("rate", 1.0)), 0.01)
	var cool := 0.0
	var shots := 0
	var held := 0
	var aim := ENEMY_AT + Vector3(0, 3, 0)
	var fire_for := 6.0
	var t := 0.0
	while t < fire_for + 9.0:
		mate.position += mate_vel * DT
		# the mate as BotFireGuard.crew_states describes a Strider (its body_extent capsule)
		var ext := PlayerTarget.body_extent("strider")
		var mates := [{"pos": mate.position, "vel": mate_vel, "up": UP, "r": maxf(float(ext["r"]), BotFireGuard.HULL_R),
			"hi": maxf(float(ext["hi"]), BotFireGuard.HULL_HI)}] + BotFireGuard.asset_states(w)
		var dot := aim
		var abort := BotFireGuard.missile_abort(w, SHOOTER, aim, mates, UP) if guard else Vector3.INF
		if abort != Vector3.INF:
			dot = abort
		w.designators[SHOOTER] = {"on": true, "dot": dot}
		cool -= DT
		if t < fire_for and cool <= 0.0:
			var ok := not guard or (abort == Vector3.INF and BotFireGuard.slot_safe(w, wid, MUZZLE, aim, mates, UP))
			if ok:
				var hp := "back" if wid == "mortar" else ("shoulder_l" if wid == "missiles" else "side_r")
				w.fire(Combat.fire_record(SHOOTER, 1, hp, wid, MUZZLE, aim, w.now, shots, float(st.get("spread", 0.0))))
				shots += 1
				cool = interval
			else:
				held += 1
		w.advance(DT)
		t += DT
		if t >= fire_for and w.live_shots() == 0:
			break
	w.queue_free()
	await frames(1)
	return {"crew": dmg["crew"], "enemy": dmg["enemy"], "relay": dmg["relay"], "shots": shots, "held": held}
