extends WeaponBehaviour
## Exo-Trooper Squad single-shot anti-armor rifle (docs/design/enemy-troop-squads.md §4.2):
## crisp high-contrast crimson-amber bolt (58 m/s, 150 m range, 15 dmg) fired 1 round per peeking trooper.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.28, 0.14), "trail_color": Color(1.0, 0.16, 0.10), "width": 0.24, "glow": true}
