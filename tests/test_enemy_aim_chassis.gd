extends TestCase
## Enemies aim at a player mech from its own chassis data (PlayerTarget: the first body sphere is the aim centre,
## CHASSIS_SIGHT the head / legs offsets over low cover, the capsule radius the "reached the body" slack of a sight ray):
## a rifle trooper 80 m off, for a Strider and a Bulwark (a real PlayerTarget of each, set up from its chassis):
##  - in the open: notices, fires, and its rounds damage the mech;
##  - behind a wall 5 m in front of it (partial cover: the torso line blocked; 5 m for the Bulwark, 8 m for the 11.7 m
##    Strider, whose aim centre is 6.9 m up since its 2026-11-24 hit-volume refit): it still sees the mech's head over
##    the wall, aims at it (the sight offset) and hits it;
##  - behind a 30 m building (full cover): never alerted, never fires, no damage.
## Headless, physics on (a floor, boxes), combat clock only.

const DT := 1.0 / 60.0
const CAP := 8.0

var _floor: StaticBody3D


func _init() -> void:
	timeout_sec = 180.0


func setup() -> void:
	_floor = _box(Vector3(1200, 1, 1200), Vector3(0, -0.5, 0))
	await frames(2)
	for chassis: String in ["strider", "bulwark"]:
		var open := await _run(chassis, "open")
		check(bool(open["alert"]), "%s in the open: the trooper notices it" % chassis)
		check(float(open["damage"]) > 0.0, "%s in the open: and its rounds hit (%.0f HP, parts %s)" % [chassis, open["damage"], str(open["parts"])])
		var low := await _run(chassis, "low")
		check(bool(low["torso_blocked"]), "%s behind the low wall: the torso line is blocked" % chassis)
		check(bool(low["alert"]), "%s behind the low wall: seen over it" % chassis)
		check(float(low["off"]) > 1.0, "%s behind the low wall: aims at the part it sees (offset %.1f m)" % [chassis, low["off"]])
		check(float(low["damage"]) > 0.0, "%s behind the low wall: and hits it (%.0f HP, parts %s)" % [chassis, low["damage"], str(low["parts"])])
		var full := await _run(chassis, "full")
		check(not bool(full["alert"]) and not bool(full["fired"]), "%s behind a building: never seen, never shot at" % chassis)
		eq(float(full["damage"]), 0.0, "%s behind a building: no damage" % chassis)
		print("  [aim] %-8s open %.0f HP %s | low wall offset %.1f m, %.0f HP %s | building %.0f HP" % [chassis, open["damage"],
			str(open["parts"]), low["off"], low["damage"], str(low["parts"]), full["damage"]])
	_floor.queue_free()
	finish()


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


## The mech 80 m in front (-Z) of a rifle trooper at the origin; `cover` "open" | "low" (a 5 m wall 5 m in front of the
## mech: it hides the torso, not the head) | "full" (30 m building 20 m ahead). Returns {alert, fired, damage, parts, off, torso_blocked}.
func _run(chassis: String, cover: String) -> Dictionary:
	var wall: StaticBody3D = null
	if cover == "low":
		var wh := 8.0 if chassis == "strider" else 5.0
		wall = _box(Vector3(30, wh, 0.6), Vector3(0, wh * 0.5, -75))
	elif cover == "full":
		wall = _box(Vector3(60, 30, 4), Vector3(0, 15, -20))
	await frames(2)
	var w := CombatWorld.new()
	w.use_physics = true
	add_child(w)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var p := PlayerTarget.new()
	p.target_id = "player1"
	p.owner_peer = 1
	p.auto_respawn_delay = -1.0
	p._setup_components({}, chassis)
	p.set_max_hp({"torso": 1.0e7, "head": 1.0e7, "leg_l": 1.0e7, "leg_r": 1.0e7})   # never downed mid-test
	p.position = Vector3(0, 0, -80)
	add_child(p)
	w.register(p)
	var dmg := [0.0]
	var parts := {}
	p.damaged.connect(func(a: float, c: String, _s: String) -> void:
		dmg[0] += a
		parts[c] = true)
	var e := EnemyTrooper.new()
	e.configure("trooper_rifle", "aim_trooper_%s_%s" % [chassis, cover], w, sq, null, 1)
	sq.add_enemy(e)
	await frames(1)
	var space := w.get_world_3d().direct_space_state
	var blocked := not e._check_los(e.eye_world(), e._target_aim_center(p), space, p)
	var fired := [false]
	sq.enemy_event.connect(func(kind: String, en: Node, _pl: Dictionary) -> void:
		if en == e and kind == "weapon_fired":
			fired[0] = true)
	var off := 0.0
	for _i in int(CAP / DT):
		w.advance(DT)
		off = maxf(off, e._vis_off.length())
	var out := {"alert": e.is_alerted(), "fired": fired[0], "damage": dmg[0], "parts": parts.keys(), "off": off,
		"torso_blocked": blocked}
	for n: Node in [p, e, sq, w]:
		n.queue_free()
	if wall != null:
		wall.queue_free()
	await frames(2)
	return out
