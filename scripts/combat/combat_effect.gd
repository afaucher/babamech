class_name CombatEffect
extends Node3D
## Base of everything a CombatWorld runs on its clock: shots (Projectile, later Beam, FlameStream) and cosmetic
## impacts (ImpactFx). The world creates it, calls `start` once, then `advance_to(now)` every step with ITS clock (so the
## lab's time scale and pause work and a late start fast-forwards), and frees it once `finished()`.
## A shot is a scheduled effect (weapons.md §5): everything about it follows from `record` + `stats` + the clock, so it
## keeps no gameplay state of its own (SPAWN params, LOCAL progress).

var world: CombatWorld
var record: Dictionary = {}
var stats: Dictionary = {}
var t0 := 0.0                ## shared-clock time it started (record.t for a shot)


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "record": Net.SPAWN, "stats": Net.SPAWN, "t0": Net.SPAWN}


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	world = w
	record = rec
	stats = st
	t0 = float(rec.get("t", w.now))


## Bring the effect to world time `now` (may be well past t0: fast-forward).
func advance_to(_now: float) -> void:
	pass


func finished() -> bool:
	return true


## The shot's key (Combat.shot_key); "" for cosmetics.
func key() -> String:
	return Combat.shot_key(record) if record.has("shot_index") else ""
