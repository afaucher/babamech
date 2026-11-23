extends WeaponBehaviour
## Valkyrie Rocket Gunship close-range strafing rocket salvo:
## 4-rocket rapid alternating-pod salvo (44 m/s, 88 m range, 24 dmg + 14 splash / 4.2 m) with fiery smoke trails.


func look() -> Dictionary:
	return {"color": EnemyMeshes.TRIM_RED, "trail_color": Color(1.0, 0.30, 0.12), "width": 0.28}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var r := Rocket.new()
	r.look = look()
	r.start(world, record, st)
	return r
