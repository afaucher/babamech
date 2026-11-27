class_name WeaponRegistry
extends RefCounted
## Weapon id -> its WeaponBehaviour (scripts/combat/weapons/<id>.gd), or, for a look-only weapon, a LOOKS entry. A weapon
## that is in neither is in the catalog (the hangar can mount it) but doesn't fire yet. Adding a weapon = one file + one
## line in BEHAVIOURS (or one LOOKS line when it only needs a look) + its catalog stats.

const BEHAVIOURS := {
	"laser": preload("res://scripts/combat/weapons/laser.gd"),
	"gatling": preload("res://scripts/combat/weapons/gatling.gd"),
	"rockets": preload("res://scripts/combat/weapons/rockets.gd"),
	"missiles": preload("res://scripts/combat/weapons/missiles.gd"),
	"mortar": preload("res://scripts/combat/weapons/mortar.gd"),
	"flamer": preload("res://scripts/combat/weapons/flamer.gd"),
	"railgun": preload("res://scripts/combat/weapons/railgun.gd"),
	"swivel": preload("res://scripts/combat/weapons/swivel.gd"),
	"flak": preload("res://scripts/combat/weapons/flak.gd"),
}

## Look-only weapons: WeaponBehaviour's defaults (automatic fire at stats.rate, fixed spread, ...) and a shot that is a
## stock flight with a fixed look: id -> [flight, look]. flight: "projectile" (the default Projectile), "rocket" (Rocket:
## seeded launch error, corkscrew, smoke puffs) or "mortar" (MortarShell: ballistic arc, closing ground ring). look: the
## colours for the shot ({"color", "trail_color", "width", "glow"}, WeaponBehaviour.look). One LookWeapon serves each.
## Numbers: MechCatalog.WEAPONS / EnemyCatalog.WEAPONS. (Were one file each in scripts/combat/weapons/ until 2026-11-25.)
const LOOKS := {
	# Autocannon (weapons.md §3.2): the reference weapon. Slow amber shells with a tapered tracer, the one flame palette.
	"autocannon": ["projectile", {"color": LowPolyFlame.MID, "trail_color": LowPolyFlame.OUTER, "width": 0.38, "glow": true}],
	# Enforcer Turret heavy plasma bolter (enemies.md §4): slow glowing crimson-magenta bolts, thick bright trail.
	"enemy_bolter": ["projectile", {"color": Color(1.0, 0.16, 0.24), "trail_color": Color(0.95, 0.08, 0.18), "width": 0.46, "glow": true}],
	# Hound Skirmisher rapid pulse carbine (enemies.md §4): sharp crimson-orange glowing needles.
	"enemy_pulse": ["projectile", {"color": Color(1.0, 0.34, 0.16), "trail_color": Color(0.95, 0.12, 0.16), "width": 0.34, "glow": true}],
	# Bastion Siege Tank plasma siege shell (enemies.md §4): large, slow, glowing crimson shell, heavy trail, splash.
	"enemy_siege_shell": ["projectile", {"color": Color(1.0, 0.22, 0.12), "trail_color": Color(0.88, 0.06, 0.14), "width": 0.56, "glow": true}],
	# Bastion Siege Tank cover-flushing arc mortar (enemies.md §4): MortarShell's parabola and closing ring (>= 2.4 s).
	"enemy_mortar": ["mortar", {"color": Color(0.95, 0.14, 0.18), "trail_color": Color(0.92, 0.12, 0.16), "width": 0.48, "glow": true}],
	# Enforcer Sniper Turret lance (enemy-tactics-and-drones.md §3.1): fast crimson-white bolt after a 0.95 s telegraph.
	"enemy_lance": ["projectile", {"color": Color(1.0, 0.92, 0.78), "trail_color": Color(1.0, 0.12, 0.22), "width": 0.30, "glow": true}],
	# Enforcer Missile Turret area-denial salvo (enemy-tactics-and-drones.md §3.1): 3 staggered Rockets.
	"enemy_rockets": ["rocket", {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.26, 0.14), "width": 0.26}],
	# Hound Breacher scatter cannon (enemy-tactics-and-drones.md §3.1): 5-pellet fan (EnemyBase multi-pellet support).
	"enemy_scatter": ["projectile", {"color": Color(1.0, 0.42, 0.14), "trail_color": Color(0.92, 0.14, 0.12), "width": 0.42, "glow": true}],
	# Exo-Trooper anti-armor rifle (enemy-troop-squads.md §4.2): crisp crimson-amber bolt, one per peeking trooper.
	"enemy_troop_rifle": ["projectile", {"color": Color(1.0, 0.28, 0.14), "trail_color": Color(1.0, 0.16, 0.10), "width": 0.24, "glow": true}],
	# Rooftop Anti-Armor Exo-Trooper shoulder rocket (enemy-troop-squads.md §4.2): one Rocket with a smoke trail.
	"enemy_troop_at": ["rocket", {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.34, 0.14), "width": 0.22}],
	# Valkyrie Rocket Gunship strafing salvo: 4 Rockets from alternating pods.
	"enemy_gunship_rockets": ["rocket", {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(1.0, 0.30, 0.12), "width": 0.28}],
}


## The behaviour of a LOOKS weapon: the stock flight with its look. Stateless like every behaviour (flight and look are
## fixed per weapon id).
class LookWeapon extends WeaponBehaviour:
	var flight: String
	var _look: Dictionary

	func _init(flight_kind: String, lk: Dictionary) -> void:
		flight = flight_kind
		_look = lk

	func look() -> Dictionary:
		return _look.duplicate()       # a fresh dictionary per call, as the per-file look() returned

	func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
		var p: Projectile
		match flight:
			"rocket":
				p = Rocket.new()
			"mortar":
				p = MortarShell.new()
			_:
				p = Projectile.new()
		p.look = look()
		p.start(world, record, st)
		return p

	func prewarm(st: Dictionary) -> void:
		match flight:
			"rocket":
				Rocket.prewarm_rocket()
			"mortar":
				MortarShell.prewarm_mortar(st)
			_:
				Projectile.prewarm_look(_look, st)

static var _instances: Dictionary = {}
## TEST HOOK: weapon ids treated as unbuilt (no behaviour, swapped by playable_loadout) although they are in BEHAVIOURS,
## so tests of the "paused weapon" paths don't depend on which weapons happen to be unbuilt. Empty in the game; a test
## that sets it resets it with set_disabled([]).
static var disabled: Dictionary = {}


static func set_disabled(ids: Array) -> void:
	disabled.clear()
	for id: Variant in ids:
		disabled[str(id)] = true


## The shared (stateless) behaviour, or null when the weapon isn't built yet.
static func behaviour(id: String) -> WeaponBehaviour:
	if not built(id):
		return null
	if not _instances.has(id):
		if LOOKS.has(id):
			_instances[id] = LookWeapon.new(str(LOOKS[id][0]), LOOKS[id][1])
		else:
			_instances[id] = (BEHAVIOURS[id] as GDScript).new()
	return _instances[id]


static func built(id: String) -> bool:
	return (BEHAVIOURS.has(id) or LOOKS.has(id)) and not disabled.has(id)


## Build every enemy weapon's cached shot meshes (WeaponBehaviour.prewarm) at mission load (MissionCombat.setup), as
## WeaponRack.rebuild does for the player's mounts, so an enemy's first shot doesn't build them mid-fight.
static func prewarm_enemy_weapons() -> void:
	for id: String in EnemyCatalog.WEAPONS:
		var b := behaviour(id)
		if b != null:
			b.prewarm(EnemyCatalog.weapon(id))


## A loadout the test drive can fire: `loadout` sanitized for the chassis (MechCatalog.sanitize_loadout), then every
## slot holding a weapon with no behaviour yet (paused: flamer, missiles, ...; back-mount equipment is kept) swapped for that slot's chassis default
## (or emptied when the default isn't built either). The player's other choices and empty slots are kept. Saved
## settings are never touched. {"loadout": Dictionary, "notes": Array[String]} with one note per swap, e.g.
## "LEFT SIDE: Flamer offline, using Side Laser".
static func playable_loadout(chassis_id: String, loadout: Dictionary) -> Dictionary:
	var c := MechCatalog.chassis(chassis_id)
	var out := MechCatalog.sanitize_loadout(chassis_id, loadout)
	var defaults: Dictionary = c.get("default_loadout", {})
	var notes: Array[String] = []
	for hp: Dictionary in c["hardpoints"]:
		var id := str(hp["id"])
		var w := str(out.get(id, ""))
		if w == "" or built(w) or MechCatalog.is_equipment(w):   # equipment has no behaviour and needs none
			continue
		var name := str(MechCatalog.weapon(w).get("name", w))
		var fallback := str(defaults.get(id, ""))
		var fits := fallback != "" and built(fallback) and MechCatalog.fits(hp, fallback)   # every mount kind it takes
		var label := str(hp.get("label", id)).to_upper()
		if fits:
			out[id] = fallback
			notes.append("%s: %s offline, using %s" % [label, name, str(MechCatalog.weapon(fallback).get("name", fallback))])
		else:
			out[id] = ""
			notes.append("%s: %s offline, slot empty" % [label, name])
	return {"loadout": out, "notes": notes}
