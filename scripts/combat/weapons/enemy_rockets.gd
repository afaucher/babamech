extends WeaponBehaviour
## Enforcer Missile Turret area-denial rocket salvo (docs/design/enemy-tactics-and-drones.md §3.1):
## 3-rocket staggered salvo (40 m/s, 190 m range, splash 12 / 4 m) reusing Rocket's deterministic corkscrew & smoke puffs.


func look() -> Dictionary:
	return {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(0.95, 0.26, 0.14), "width": 0.26}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var r := Rocket.new()
	r.look = look()
	r.start(world, record, st)
	return r
