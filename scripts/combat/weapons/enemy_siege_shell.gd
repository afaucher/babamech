extends WeaponBehaviour
## Bastion Siege Tank primary plasma siege shell (docs/design/enemies.md §4): large, slow, glowing crimson shell
## with a heavy bright trail and explosive splash.


func look() -> Dictionary:
	return {"color": Color(1.0, 0.22, 0.12), "trail_color": Color(0.88, 0.06, 0.14), "width": 0.56, "glow": true}
