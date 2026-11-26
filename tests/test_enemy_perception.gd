extends TestCase
## Enemy perception (EnemyBase header "Perception", docs/design/pacing-director.md "Perception"): an un-alerted unit
## notices a crew mech with a clear line to it inside its notice range in its forward cone (instantly close in, else
## after 0.5-1.5 s), in any direction inside NEAR_AWARE_R (wider while the mech walks, the whole notice range while it
## fires), and idle units glance round so a cone sweeps the block; it then alerts, telegraphs (>= 0.3 s) and fires.
## Cover still works: behind a building or beyond range nothing notices. A trooper sees an 11.7 m mech's head over a low
## wall. The sight cost is bounded (rays per second). Headless, physics on (a floor, boxes), deterministic: combat clock
## only, no wall-clock timing.

const DT := 1.0 / 60.0
const SHOOTERS := ["trooper_rifle", "trooper_at", "strider", "strider_breacher", "tank", "turret", "turret_sniper",
	"turret_missile", "gunship"]
const SCANNERS := ["trooper_rifle", "strider", "tank", "turret", "turret_missile"]

var _floor: StaticBody3D


func _init() -> void:
	timeout_sec = 240.0


func setup() -> void:
	_floor = _box(Vector3(1200, 1, 1200), Vector3(0, -0.5, 0))
	await frames(2)
	await _front_80_noticed_and_shot()
	await _behind_80_scan_or_fire()
	await _drone_as_before()
	await _behind_building_never()
	await _beyond_range_never()
	await _trooper_over_low_wall()
	await _sight_cost_bounded()
	_floor.queue_free()
	finish()


# --- Fixture -----------------------------------------------------------------------------------------------

func _box(size: Vector3, at: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	b.add_child(cs)
	b.position = at
	add_child(b)
	return b


func _make(ty: String) -> EnemyBase:
	match ty:
		"turret", "turret_sniper", "turret_missile": return EnemyTurret.new()
		"strider", "strider_breacher": return EnemyStrider.new()
		"tank": return EnemyTank.new()
		"trooper_rifle", "trooper_at": return EnemyTrooper.new()
		"gunship": return EnemyGunship.new()
		"drone": return EnemyDrone.new()
	return EnemyTurret.new()


## A mech-sized player target (PlayerTarget's body spheres, torso first) at `at`.
func _mech(w: CombatWorld, at: Vector3) -> CombatTarget:
	var p := CombatTarget.new()
	p.target_id = "player1"
	p.owner_peer = 1
	p.team = "player"
	p.mass_class = "mech"
	p.set_max_hp({"torso": 1.0e7, "head": 1.0e7, "leg_l": 1.0e7, "leg_r": 1.0e7})
	for s: Dictionary in PlayerTarget.BODY_SPHERES:
		p.add_hit_sphere(str(s["component"]), s["center"] as Vector3, float(s["radius"]))
	p.position = at
	add_child(p)
	w.register(p)
	return p


## One enemy of type `ty` at the origin facing -Z, the mech `d` m away in direction `dir` ("front" -Z, "behind" +Z),
## `mode` "still" | "fire" (a laser shot away from the enemy every 1 s). Runs up to `cap` s; returns the clock times of
## the first alert / telegraph / shot (-1 = none) and the telegraph duration.
func _run(ty: String, d: float, dir: String, mode: String, cap: float) -> Dictionary:
	var w := CombatWorld.new()
	w.mission_seed = 297535
	w.use_physics = true
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var dvec := Vector3(0, 0, -1) if dir == "front" else Vector3(0, 0, 1)
	var p := _mech(w, dvec * d)
	var e := _make(ty)
	e.configure(ty, "%s_perc" % ty, w, sq, null, 297535)
	e.position = Vector3(0, float(EnemyCatalog.unit(ty).get("cruise_alt", 0.0)), 0)
	sq.add_enemy(e)
	var res := {"alert": -1.0, "tele": -1.0, "shot": -1.0, "dur": 0.0}
	sq.enemy_event.connect(func(kind: String, en: Node, pl: Dictionary) -> void:
		if en != e:
			return
		if kind == "alerted" and float(res["alert"]) < 0.0 and str(pl.get("state", "")) in ["spotted", "relay"]:
			res["alert"] = w.now
		elif kind == "telegraph_started" and float(res["tele"]) < 0.0:
			res["tele"] = w.now
			res["dur"] = float(pl.get("duration", 0.0))
		elif kind == "weapon_fired" and float(res["shot"]) < 0.0:
			res["shot"] = w.now)
	await frames(1)
	var t0 := w.now
	var fire_t := 0.0
	var idx := 0
	for i in int(cap / DT):
		if mode == "fire":
			fire_t -= DT
			if fire_t <= 0.0:
				fire_t = 1.0
				var o := p.position + Vector3(0, 4.0, 0)
				var aim := o + Vector3(1, 0, dvec.z).normalized() * 60.0   # away from the enemy: never heard as a pass-by
				w.fire(Combat.fire_record("player1", 1, "side_l", "laser", o, aim, w.now, idx, 0.0))
				idx += 1
		w.advance(DT)
		if float(res["shot"]) >= 0.0 or (ty == "drone" and float(res["alert"]) >= 0.0):
			break
	for k in ["alert", "tele", "shot"]:
		if float(res[k]) >= 0.0:
			res[k] = float(res[k]) - t0
	for n: Node in [p, e, sq, w]:
		n.queue_free()
	await frames(1)
	return res


# --- Cases -------------------------------------------------------------------------------------------------

func _front_80_noticed_and_shot() -> void:
	for ty: String in SHOOTERS:
		var r := await _run(ty, 80.0, "front", "still", 10.0)
		var a := float(r["alert"])
		check(a >= 0.0 and a <= 3.0, "%s notices a still mech 80 m in front within 3 s (%.2f s)" % [ty, a])
		var prim := str(EnemyCatalog.unit(ty).get("primary_weapon", ""))
		var tele := EnemyCatalog.telegraph_duration(prim)
		var s := float(r["shot"])
		# alert -> ALERT_DELAY -> aim (slew) -> telegraph -> shot; 2 s covers the slowest slew / a gunship's run-in.
		check(s >= 0.0 and s <= a + EnemyBase.ALERT_DELAY + tele + 2.0,
			"%s shoots within its alert + telegraph + aim time (alert %.2f, shot %.2f, telegraph %.2f)" % [ty, a, s, tele])
		if float(r["tele"]) >= 0.0:
			check(float(r["dur"]) >= EnemyCatalog.MIN_TELEGRAPH - 1e-4 and s - float(r["tele"]) >= EnemyCatalog.MIN_TELEGRAPH - 1e-3,
				"%s telegraphs >= 0.3 s before its first shot (%.2f s)" % [ty, s - float(r["tele"])])


func _behind_80_scan_or_fire() -> void:
	for ty: String in SCANNERS:
		var r := await _run(ty, 80.0, "behind", "still", 12.0)
		var a := float(r["alert"])
		check(a >= 0.0 and a <= 8.0, "%s (idle) notices a still mech 80 m behind it within ~8 s by glancing round (%.2f s)" % [ty, a])
		var rf := await _run(ty, 80.0, "behind", "fire", 6.0)
		var af := float(rf["alert"])
		check(af >= 0.0 and af <= 2.0, "%s notices a mech 80 m behind it at once when it fires (%.2f s)" % [ty, af])


func _drone_as_before() -> void:
	var r := await _run("drone", 80.0, "front", "still", 6.0)
	check(float(r["alert"]) >= 0.0 and float(r["alert"]) <= 3.0, "the scout drone still spots a mech 80 m ahead (%.2f s)" % float(r["alert"]))


## A 30 m tall building block between the unit and the mech: nothing notices, still or firing (away), in 15 s.
func _behind_building_never() -> void:
	var bld := _box(Vector3(40, 30, 20), Vector3(0, 15, -40))
	await frames(2)
	for ty: String in ["turret", "trooper_rifle", "tank", "strider"]:
		var r := await _run(ty, 80.0, "front", "still", 15.0)
		check(float(r["alert"]) < 0.0, "%s does not notice a still mech behind a building (%.2f)" % [ty, float(r["alert"])])
		var rf := await _run(ty, 80.0, "front", "fire", 15.0)
		check(float(rf["alert"]) < 0.0, "%s does not notice a firing mech behind a building (%.2f)" % [ty, float(rf["alert"])])
	bld.queue_free()
	await frames(2)


func _beyond_range_never() -> void:
	for ty: String in ["turret", "trooper_rifle", "tank", "strider_breacher"]:
		var nr := float(EnemyCatalog.unit(ty).get("notice_range", 100.0))
		var r := await _run(ty, nr + 30.0, "front", "still", 12.0)
		check(float(r["alert"]) < 0.0, "%s does not notice a still mech %.0f m away (notice range %.0f m)" % [ty, nr + 30.0, nr])


## A 2.65 m wall 10 m in front of a trooper hides the mech's torso (the ray from its 1.85 m eye to the aim centre 6.9 m
## up: 2.48 m at the wall) but not its head (2.8 m at the wall). Was 2.4 m before the Strider's 2026-11-24 hit-volume
## refit raised its aim centre from 4.4 m.
func _trooper_over_low_wall() -> void:
	var wall := _box(Vector3(30, 2.65, 0.6), Vector3(0, 1.325, -10))
	await frames(2)
	var w := CombatWorld.new()
	w.use_physics = true
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mech(w, Vector3(0, 0, -80))
	var e := EnemyTrooper.new()
	e.configure("trooper_rifle", "wall_trooper", w, sq, null, 1)
	sq.add_enemy(e)
	await frames(1)
	var space := w.get_world_3d().direct_space_state
	check(not e._check_los(e.eye_world(), e._target_aim_center(p), space, p), "the wall blocks the torso line from the trooper's eye")
	var shot := [-1.0]
	sq.enemy_event.connect(func(kind: String, en: Node, _pl: Dictionary) -> void:
		if en == e and kind == "weapon_fired" and shot[0] < 0.0:
			shot[0] = w.now)
	var t0 := w.now
	for _i in int(6.0 / DT):
		w.advance(DT)
		if shot[0] >= 0.0:
			break
	check(e.is_alerted(), "the trooper sees the 11.7 m mech's head over the 2.65 m wall")
	check(shot[0] >= 0.0, "and fires at it (%.2f s)" % (shot[0] - t0 if shot[0] >= 0.0 else -1.0))
	check(e._vis_off.length() > 1.0, "it aims at the part it sees (offset %.1f m)" % e._vis_off.length())
	for n: Node in [p, e, sq, w, wall]:
		n.queue_free()
	await frames(2)


## 20 idle turrets: a mech beyond every notice range costs no rays; behind a building at 100 m, about one ray per unit
## per sight check (5 Hz un-alerted); units on a deck nobody stands on cost nothing.
func _sight_cost_bounded() -> void:
	var bld := _box(Vector3(400, 30, 10), Vector3(0, 15, -60))
	await frames(2)
	var w := CombatWorld.new()
	w.use_physics = true
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := _mech(w, Vector3(0, 0, -400))
	var units: Array[EnemyBase] = []
	for i in 20:
		var e := EnemyTurret.new()
		e.configure("turret", "cost_t%d" % i, w, sq, null, i + 1)
		e.position = Vector3((float(i) - 9.5) * 8.0, 0, 0)
		sq.add_enemy(e)
		units.append(e)
	await frames(1)
	var r0 := EnemyBase.los_rays
	for _i in int(5.0 / DT):
		w.advance(DT)
	eq(EnemyBase.los_rays - r0, 0, "a mech beyond every notice range costs no sight rays")
	p.position = Vector3(0, 0, -100)
	r0 = EnemyBase.los_rays
	for _i in int(5.0 / DT):
		w.advance(DT)
	var per_s := float(EnemyBase.los_rays - r0) / 5.0 / 20.0
	check(per_s > 0.0 and per_s <= 6.0, "behind a building at 100 m: %.2f sight rays / s per idle unit (<= 6)" % per_s)
	var none_alerted := true
	for e in units:
		none_alerted = none_alerted and not e.is_alerted()
	check(none_alerted, "and none of the 20 notices it")
	# The same units on a deck nobody stands on sleep: no ticks, no rays.
	sq.deck_of = func(pos: Vector3) -> int: return 0 if pos.z > -30.0 else 1   # the mech (z = -100) is on deck 1
	for e in units:
		e.spawn_deck = 0
	r0 = EnemyBase.los_rays
	for _i in int(3.0 / DT):
		w.advance(DT)
	eq(EnemyBase.los_rays - r0, 0, "sleeping units (no crew on their deck) cast no sight rays")
	for n: Node in [p, sq, w, bld]:
		n.queue_free()
	for e in units:
		e.queue_free()
	await frames(2)
