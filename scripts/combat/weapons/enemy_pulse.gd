extends WeaponBehaviour
## Hound Skirmisher rapid pulse carbine (docs/design/enemies.md §4): sharp crimson-orange glowing needles.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.34, 0.16), "trail_color": Color(0.95, 0.12, 0.16), "width": 0.34, "glow": true}
