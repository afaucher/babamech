extends WeaponBehaviour
## Enforcer Turret heavy plasma bolter (docs/design/enemies.md §4): slow glowing crimson-magenta energy bolts
## that grow over range with a thick bright trail, readable and dodgeable from rooftops or streets.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.16, 0.24), "trail_color": Color(0.95, 0.08, 0.18), "width": 0.46, "glow": true}
