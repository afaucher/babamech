extends WeaponBehaviour
## Rooftop Anti-Armor Exo-Trooper shoulder rocket (docs/design/enemy-troop-squads.md §4.2):
## single-shot shoulder AT rocket (38 m/s, 190 m range, 26 dmg + 12 splash / 3.8 m) with smoke trail.


func look() -> Dictionary:
	return {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.34, 0.14), "width": 0.22}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var r := Rocket.new()
	r.look = look()
	r.start(world, record, st)
	return r
