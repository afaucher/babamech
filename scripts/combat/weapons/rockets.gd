extends WeaponBehaviour
## Rocket Pod (weapons.md §3.5): one press ripples a salvo of six unguided rockets (stats.salvo at stats.rate, then
## stats.reload s), 36 rounds then dry; heat per salvo. The cadence, ammo and heat are WeaponMount's defaults; this
## file only says what a shot is: a Rocket (scripts/combat/rocket.gd), which owns the seeded launch error + corkscrew
## wobble, the tube it leaves from, the look and the detonation. Numbers: MechCatalog.WEAPONS["rockets"].


func look() -> Dictionary:
	return {"color": MechMeshes.WHITE, "trail_color": MechMeshes.GREY, "width": 0.22}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var r := Rocket.new()
	r.look = look()
	r.start(world, record, st)
	return r


func prewarm(_st: Dictionary) -> void:
	Rocket.prewarm_rocket()
