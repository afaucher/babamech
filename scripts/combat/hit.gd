class_name Hit
extends RefCounted
## One resolved hit (weapons.md §5): everything a target takes from it, in one record. The deciding machine builds it
## (CombatWorld.resolve_hit); the target's OWNER applies it through the three verbs (CombatTarget.apply_hit calls
## apply_damage, apply_impulse, apply_heat). When the decider isn't the owner, CombatWorld emits `remote_hit` with it and
## the net layer carries it to the owner (not built yet). A message, never stored on the target.

var damage := 0.0
var impulse := Vector3.ZERO     ## the weapon's Δv (m/s) along the shot, BEFORE the target's mass class
var heat := 0.0                 ## heat added to the target (flamer)
var point := Vector3.ZERO
var normal := Vector3.UP
var component := ""             ## the hit shape's component id ("body", "torso", "leg_l", ...)
var weapon := ""
var shooter := ""
var shot := ""                  ## Combat.shot_key of the shot that made it


func net_fields() -> Dictionary:
	return {"damage": Net.SPAWN, "impulse": Net.SPAWN, "heat": Net.SPAWN, "point": Net.SPAWN, "normal": Net.SPAWN,
		"component": Net.SPAWN, "weapon": Net.SPAWN, "shooter": Net.SPAWN, "shot": Net.SPAWN}
