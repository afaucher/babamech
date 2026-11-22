extends WeaponBehaviour
## Bastion Siege Tank cover-flushing arc mortar (docs/design/enemies.md §4): reuses MortarShell's deterministic
## ballistic parabola and closing ground-ring telegraph (>= 2.4 s flight) to flush rooftop campers.


func look() -> Dictionary:
	return {"color": Color(0.95, 0.14, 0.18), "trail_color": Color(0.92, 0.12, 0.16), "width": 0.48, "glow": true}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var s := MortarShell.new()
	s.look = look()
	s.start(world, record, st)
	return s
