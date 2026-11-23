extends WeaponBehaviour
## Flak Cannon (weapons.md §3.10): automatic fire at stats.rate with the autocannon's fixed seeded spread (WeaponMount's
## defaults: cadence, ammo, heat per shell). A shot is a FlakShell (scripts/combat/weapons/flak_shell.gd): a fast straight
## shell with a proximity fuse. Numbers: MechCatalog.WEAPONS["flak"].
## LOOK: PLACEHOLDER, the autocannon's shell and tracer colours (no flak art yet; a distinct look needs the user's sign-off).


func look() -> Dictionary:
	return {"color": LowPolyFlame.MID, "trail_color": LowPolyFlame.OUTER, "width": 0.38, "glow": true}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var s := FlakShell.new()
	s.look = look()
	s.start(world, record, st)
	return s
