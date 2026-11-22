extends WeaponBehaviour
## Hound Breacher close-quarters scatter cannon (docs/design/enemy-tactics-and-drones.md §3.1):
## 5-pellet horizontal fan (7.5 deg spread, 56 m/s, 68 m range) fired by EnemyBase multi-pellet fan support.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.42, 0.14), "trail_color": Color(0.92, 0.14, 0.12), "width": 0.42, "glow": true}
