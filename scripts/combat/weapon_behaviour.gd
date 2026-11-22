class_name WeaponBehaviour
extends RefCounted
## How one weapon fires and what its shot is. One subclass per weapon in scripts/combat/weapons/<id>.gd, registered in
## WeaponRegistry.BEHAVIOURS. STATELESS: one shared instance serves every mount; per-mount state lives on the
## WeaponMount (cooldown, ammo, spin, bloom, charge, salvo_left), so it stays OWNER state of the shooter.
##
## The defaults are a plain automatic gun: fire while the trigger is held at stats.rate, stats.salvo shots per trigger
## cycle (then stats.reload s), stats.spread degrees of fixed spread, one Projectile per shot. Override only what
## differs:
##   tick(mount, held, dt)        per step, before firing: spin-up, bloom recovery, charge build-up (hooks)
##   wants_fire(mount, held)      may a new trigger cycle start now? (charge weapons: on full charge / release)
##   spread(mount)                degrees for the next shot (bloom)
##   on_shot(mount)               after each shot (grow bloom, reset charge)
##   spawn(world, record, stats)  the effect for one fire record (another CombatEffect, a flight subclass, a look)
##   look()                       colours for the default Projectile: {"color", "trail_color", "width"}


func tick(_mount: WeaponMount, _held: bool, _dt: float) -> void:
	pass


func wants_fire(_mount: WeaponMount, held: bool) -> bool:
	return held


func spread(mount: WeaponMount) -> float:
	return float(mount.stats.get("spread", 0.0))


func on_shot(_mount: WeaponMount) -> void:
	pass


func look() -> Dictionary:
	return {"color": MechMeshes.AMBER, "trail_color": MechMeshes.AMBER, "width": 0.38}


## The effect for one shot (started, not yet in the tree: CombatWorld.fire adds it and fast-forwards it).
func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var p := Projectile.new()
	p.look = look()
	p.start(world, record, st)
	return p
