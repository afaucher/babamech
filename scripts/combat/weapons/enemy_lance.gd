extends WeaponBehaviour
## Enforcer Sniper Turret long-range marksman lance (docs/design/enemy-tactics-and-drones.md §3.1):
## fast, bright crimson-white lance bolt (115 m/s, 215 m range) preceded by a loud 0.95 s telegraph.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.92, 0.78), "trail_color": Color(1.0, 0.12, 0.22), "width": 0.30, "glow": true}
