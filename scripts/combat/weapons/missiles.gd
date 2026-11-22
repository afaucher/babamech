extends WeaponBehaviour
## Guided Missiles (weapons.md §3.6): one press launches a salvo of three missiles (stats.salvo at stats.rate: 0.9 s),
## then stats.reload s; 18 missiles then dry; heat per salvo. Cadence, ammo and heat are WeaponMount's defaults; a shot is
## a Missile (scripts/combat/missile.gd), which steers toward the shooter's live aim point (world.designators) for its
## whole flight and brings up the red laser line (MissileLaser). Numbers: MechCatalog.WEAPONS["missiles"].


func look() -> Dictionary:
	return {"color": MechMeshes.WHITE, "trail_color": MechMeshes.MISSILE_RED, "width": 0.18}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var m := Missile.new()
	m.look = look()
	m.start(world, record, st)
	return m
