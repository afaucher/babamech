extends WeaponBehaviour
## Back Mortar (weapons.md §3.7): arcing indirect fire. One shell per 3.5 s (`rate`), lobbed to the aim point on a
## ballistic arc (MortarShell): no line of sight needed, flight 2.0 s + 1 s per 100 m, seeded scatter growing to 3 m
## at 250 m, 18 heat a shell, unlimited ammo. Every number is MechCatalog.WEAPONS["mortar"].
## RANGE GATE: the aim point's horizontal distance from the muzzle must be within min_range..range (30..250 m); outside
## it the mortar holds fire (no heat, no cooldown) and says why in WeaponMount.hold_reason.


## Why the mortar can't fire at the mount's current aim point, or "".
static func range_problem(mount: WeaponMount) -> String:
	var d := MortarShell.horizontal(mount.muzzle_at, mount.aim_at)
	var lo := float(mount.stats.get("min_range", 30.0))
	var hi := float(mount.stats.get("range", 250.0))
	if d < lo:
		return "TOO CLOSE %d m < %d m" % [int(d), int(lo)]
	if d > hi:
		return "OUT OF RANGE %d m > %d m" % [int(d), int(hi)]
	return ""


func tick(mount: WeaponMount, _held: bool, _dt: float) -> void:
	mount.hold_reason = range_problem(mount)


func wants_fire(mount: WeaponMount, held: bool) -> bool:
	return held and mount.hold_reason == ""


func spread(_mount: WeaponMount) -> float:
	return 0.0          # scatter is the landing offset (MortarShell), not a cone


func look() -> Dictionary:
	return {"color": MechMeshes.DARK, "trail_color": Color(0.62, 0.62, 0.6), "width": 0.6}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var p := MortarShell.new()
	p.look = look()
	p.start(world, record, st)
	return p
