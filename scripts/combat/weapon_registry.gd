class_name WeaponRegistry
extends RefCounted
## Weapon id -> its WeaponBehaviour (scripts/combat/weapons/<id>.gd). A weapon that isn't here is in the catalog (the
## hangar can mount it) but doesn't fire yet. Adding a weapon = one file + one line here + its catalog stats.

const BEHAVIOURS := {
	"autocannon": preload("res://scripts/combat/weapons/autocannon.gd"),
	"laser": preload("res://scripts/combat/weapons/laser.gd"),
	"gatling": preload("res://scripts/combat/weapons/gatling.gd"),
	"rockets": preload("res://scripts/combat/weapons/rockets.gd"),
	"missiles": preload("res://scripts/combat/weapons/missiles.gd"),
	"mortar": preload("res://scripts/combat/weapons/mortar.gd"),
	"flamer": preload("res://scripts/combat/weapons/flamer.gd"),
	"railgun": preload("res://scripts/combat/weapons/railgun.gd"),
	"swivel": preload("res://scripts/combat/weapons/swivel.gd"),
	"enemy_bolter": preload("res://scripts/combat/weapons/enemy_bolter.gd"),
	"enemy_pulse": preload("res://scripts/combat/weapons/enemy_pulse.gd"),
	"enemy_siege_shell": preload("res://scripts/combat/weapons/enemy_siege_shell.gd"),
	"enemy_mortar": preload("res://scripts/combat/weapons/enemy_mortar.gd"),
}

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
		_instances[id] = (BEHAVIOURS[id] as GDScript).new()
	return _instances[id]


static func built(id: String) -> bool:
	return BEHAVIOURS.has(id) and not disabled.has(id)


## A loadout the test drive can fire: `loadout` sanitized for the chassis (MechCatalog.sanitize_loadout), then every
## slot holding a weapon with no behaviour yet (paused: flamer, missiles, ...) swapped for that slot's chassis default
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
		if w == "" or built(w):
			continue
		var name := str(MechCatalog.weapon(w).get("name", w))
		var fallback := str(defaults.get(id, ""))
		var fits := fallback != "" and built(fallback) and str(hp["mount"]) in (MechCatalog.weapon(fallback).get("mounts", []) as Array)
		var label := str(hp.get("label", id)).to_upper()
		if fits:
			out[id] = fallback
			notes.append("%s: %s offline, using %s" % [label, name, str(MechCatalog.weapon(fallback).get("name", fallback))])
		else:
			out[id] = ""
			notes.append("%s: %s offline, slot empty" % [label, name])
	return {"loadout": out, "notes": notes}
