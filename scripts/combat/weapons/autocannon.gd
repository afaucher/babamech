extends WeaponBehaviour
## Autocannon (weapons.md §3.2): the reference weapon. Slow amber shells (stretched octahedron) with a tapered tracer
## ribbon, fixed seeded spread, splash and a real kick. Everything numeric is MechCatalog.WEAPONS["autocannon"]; the
## defaults of WeaponBehaviour (automatic fire at `rate`, one Projectile per shot) are all it needs.


func look() -> Dictionary:
	return {"color": LowPolyFlame.MID, "trail_color": LowPolyFlame.OUTER, "width": 0.38, "glow": true}    # the one flame palette
