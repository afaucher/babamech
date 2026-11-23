extends WeaponBehaviour
## Flamer (weapons.md §3.9): the close-range heat jet. Hold for 10 flame chunks a second in a focused 5° cone, 45 m
## reach, 32 m/s. Each chunk is a fire record like any shot (the default automatic trigger, 0.6 heat to the shooter per chunk)
## and a FlameChunk effect (scripts/combat/flame_stream.gd): invisible, first target it meets takes +2.2 heat and 1.5
## damage, no knockback, walls stop it. The look is one LowPolyFlame.Stream per firing mount (FlamerFx), kept lit by the
## chunks. Every number is MechCatalog.WEAPONS["flamer"].


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var c := FlameChunk.new()
	c.start(world, record, st)
	FlamerFx.note(world, record, st)
	return c


func prewarm(_st: Dictionary) -> void:
	pass          # no shell: the look is FlamerFx's stream
