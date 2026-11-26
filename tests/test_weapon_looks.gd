extends TestCase
## The look-only weapons (the enemy weapons and the autocannon: a fixed look on the default Projectile, a Rocket or a
## MortarShell, no behaviour of their own). Audit 2026-11 folded their one-file-each behaviours into data
## (WeaponRegistry.LOOKS + one generic behaviour); this pins what they were BEFORE that, captured from the old files:
## same effect class, same look dictionary (colours, width, glow: the cache keys CombatMeshes.shell builds on), same
## flight numbers. And each weapon's prewarm builds the meshes its shots draw (the enemy rocket weapons used to skip
## Rocket.prewarm_rocket, the enemy mortar MortarShell.prewarm_mortar), and TestDriveCombat prewarms every enemy weapon.

const P := "projectile"
const R := "rocket"
const M := "mortar"

## id -> [flight, look]. Values copied from the old scripts/combat/weapons/<id>.gd (2026-11-25).
const BEFORE := {
	"autocannon": [P, {"color": LowPolyFlame.MID, "trail_color": LowPolyFlame.OUTER, "width": 0.38, "glow": true}],
	"enemy_bolter": [P, {"color": Color(1.0, 0.16, 0.24), "trail_color": Color(0.95, 0.08, 0.18), "width": 0.46, "glow": true}],
	"enemy_pulse": [P, {"color": Color(1.0, 0.34, 0.16), "trail_color": Color(0.95, 0.12, 0.16), "width": 0.34, "glow": true}],
	"enemy_siege_shell": [P, {"color": Color(1.0, 0.22, 0.12), "trail_color": Color(0.88, 0.06, 0.14), "width": 0.56, "glow": true}],
	"enemy_lance": [P, {"color": Color(1.0, 0.92, 0.78), "trail_color": Color(1.0, 0.12, 0.22), "width": 0.30, "glow": true}],
	"enemy_scatter": [P, {"color": Color(1.0, 0.42, 0.14), "trail_color": Color(0.92, 0.14, 0.12), "width": 0.42, "glow": true}],
	"enemy_troop_rifle": [P, {"color": Color(1.0, 0.28, 0.14), "trail_color": Color(1.0, 0.16, 0.10), "width": 0.24, "glow": true}],
	"enemy_mortar": [M, {"color": Color(0.95, 0.14, 0.18), "trail_color": Color(0.92, 0.12, 0.16), "width": 0.48, "glow": true}],
	"enemy_rockets": [R, {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.26, 0.14), "width": 0.26}],
	"enemy_troop_at": [R, {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.34, 0.14), "width": 0.22}],
	"enemy_gunship_rockets": [R, {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(1.0, 0.30, 0.12), "width": 0.28}],
}

## id -> [speed, max_time] of the spawned effect for the shot in _shot (origin 0,2,0, aim / target 0,2,-60), captured
## from the old code on 2026-11-25.
const FLIGHT := {
	"autocannon": [70.0, 3.1429], "enemy_bolter": [42.0, 3.8095], "enemy_pulse": [48.0, 2.3958],
	"enemy_siege_shell": [36.0, 5.0], "enemy_lance": [115.0, 1.8696], "enemy_scatter": [56.0, 1.2143],
	"enemy_troop_rifle": [58.0, 2.5862], "enemy_mortar": [19.1083, 3.14], "enemy_rockets": [40.0, 4.75],
	"enemy_troop_at": [38.0, 5.0], "enemy_gunship_rockets": [44.0, 2.0],
}


func setup() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 4242
	w.use_physics = false
	add_child(w)
	_prewarm()
	for id: String in BEFORE:
		_same(w, id)
	_enemy_prewarm()
	finish()


func _shot(id: String, i: int) -> Dictionary:
	return {"weapon": id, "shooter": "e_%s" % id, "hardpoint": "gun", "shot_index": i, "t": 0.0,
		"origin": Vector3(0, 2, 0), "dir": Vector3(0, 0, -1), "target": Vector3(0, 2, -60), "spread": 0.0}


func _same(w: CombatWorld, id: String) -> void:
	var b := WeaponRegistry.behaviour(id)
	if not check(b != null, "%s still resolves to a behaviour" % id):
		return
	var flight: String = BEFORE[id][0]
	var lk: Dictionary = BEFORE[id][1]
	eq(b.look(), lk, "%s: same look" % id)
	var e := b.spawn(w, _shot(id, 0), w.stats(id))
	var cls := "rocket" if e is Rocket else ("mortar" if e is MortarShell else ("projectile" if e is Projectile else "other"))
	eq(cls, flight, "%s: same effect class" % id)
	if e is Projectile:
		eq((e as Projectile).look, lk, "%s: the shot carries the same look" % id)
		var p := e as Projectile
		near(p.speed, float(FLIGHT[id][0]), 0.0001, "%s: same speed" % id)
		near(p.max_time, float(FLIGHT[id][1]), 0.0001, "%s: same max_time" % id)
	e.free()


## Each look-only weapon's prewarm builds what its shots draw (cleared first, so the check is real).
func _prewarm() -> void:
	CombatMeshes._cache.erase("rocket_mesh")
	CombatMeshes._cache.erase("mortar_shell")
	WeaponRegistry.behaviour("enemy_rockets").prewarm(EnemyCatalog.weapon("enemy_rockets"))
	check(CombatMeshes._cache.has("rocket_mesh"), "enemy rocket prewarm builds the rocket mesh (Rocket.prewarm_rocket)")
	WeaponRegistry.behaviour("enemy_mortar").prewarm(EnemyCatalog.weapon("enemy_mortar"))
	check(CombatMeshes._cache.has("mortar_shell"), "enemy mortar prewarm builds the mortar shell (MortarShell.prewarm_mortar)")


## TestDriveCombat.setup prewarms every enemy weapon (WeaponRegistry.prewarm_enemy_weapons): all of EnemyCatalog.WEAPONS
## resolve to a behaviour, and after the call the rocket mesh is built.
func _enemy_prewarm() -> void:
	for id: String in EnemyCatalog.WEAPONS:
		check(WeaponRegistry.behaviour(id) != null, "enemy weapon %s has a behaviour" % id)
	CombatMeshes._cache.erase("rocket_mesh")
	WeaponRegistry.prewarm_enemy_weapons()
	check(CombatMeshes._cache.has("rocket_mesh"), "prewarm_enemy_weapons builds the enemy rocket mesh")
	check(FileAccess.get_file_as_string("res://scripts/combat/test_drive_combat.gd").contains("WeaponRegistry.prewarm_enemy_weapons()"),
		"TestDriveCombat.setup calls WeaponRegistry.prewarm_enemy_weapons()")
