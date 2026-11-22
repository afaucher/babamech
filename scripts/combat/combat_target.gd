class_name CombatTarget
extends Node3D
## Anything a shot can hit (weapons.md §2, §5): a player mech, a turret, a dummy. Register it with a CombatWorld
## (`world.register(target)`); projectiles test their swept path against its hit spheres.
##
## STATE: HP per component (`max_hp` / `hp`), a Heat gauge (cap, cooling, overheat shutdown), Knockback (kinematic
## velocity, friction, stagger, wall slam), `aim_kick` (static targets only). All of it is OWNER state: only the
## target's owner writes it, and only through the three VERBS below. Nobody else ever writes hp, heat or position.
##   apply_damage(amount, component, src)   component = a hit shape's id ("" = the first component)
##   apply_impulse(dv, src)                 dv = the weapon's Δv (m/s) BEFORE the mass class; this multiplies it
##   apply_heat(amount, src)
##   apply_hit(hit)                         all three from one Hit record
## `src` is who did it (a shooter id, "wall" for a slam): for signals / logs, never for authority.
##
## AUTHORITY: `owner_peer` 0 = a host-owned world object (dummy, turret, enemy), > 0 = the player peer whose machine owns
## it (that player's mech). CombatWorld.owns(target) says whether this machine applies verbs; CombatWorld.decides(target,
## shooter_peer) whether this machine decides hits on it (the victim for a mech, the attacker for host-owned targets).
##
## MASS CLASS (Combat.MASS): light ×1.0, mech ×0.5, heavy ×0.25, static ×0 (takes aim kick instead: Δv × 3°, back at
## 60°/s). Ground: `up` (default world +Y; the local radial up on a curved deck) and `ground_y`, the ground plane's
## height along it ({p : p.dot(up) = ground_y}; with the default up, the flat ground height). Knockback works in that frame.

signal damaged(amount: float, component: String, src: String)
signal staggered_by(src: String)
signal slammed(speed: float, damage: float)

var target_id := ""
var owner_peer := 0
var team := ""                    ## faction ("player", "enemy", or "" neutral); shots skip same non-empty team
var mass_class := "mech"
var max_hp := {"body": 1000.0}
var hp := {}
## Hit spheres in local space: [{"component": String, "center": Vector3, "radius": float}].
var hit_shapes: Array = []
var heat: Heat
var knock: Knockback
var aim_kick := 0.0               ## degrees (static targets)
var ground_y := 0.0
var up := Vector3.UP              ## the ground frame's up (unit); ground_y is measured along it
var probe_height := 1.0           ## m above the origin where wall probes start (the body's centre)
var body_radius := 0.8            ## m: how close a wall stops it


func _init() -> void:
	heat = Heat.new()
	knock = Knockback.new()
	hp = max_hp.duplicate()


func net_fields() -> Dictionary:
	return {"target_id": Net.SPAWN, "owner_peer": Net.SPAWN, "team": Net.SPAWN, "mass_class": Net.SPAWN, "max_hp": Net.SPAWN, "hp": Net.OWNER,
		"hit_shapes": Net.SPAWN, "heat": Net.OWNER, "knock": Net.OWNER, "aim_kick": Net.OWNER, "ground_y": Net.SPAWN, "up": Net.SPAWN,
		"probe_height": Net.SPAWN, "body_radius": Net.SPAWN}


## Set HP per component (also resets hp).
func set_max_hp(by_component: Dictionary) -> void:
	max_hp = by_component.duplicate()
	hp = max_hp.duplicate()


func add_hit_sphere(component: String, center: Vector3, radius: float) -> void:
	hit_shapes.append({"component": component, "center": center, "radius": radius})


## Hit spheres in world space: [{"component", "center", "radius"}]. CombatWorld.first_hit inlines this maths over
## `hit_shapes` (hot path): change both together, and don't override this to add spheres (add hit_shapes instead).
func world_spheres() -> Array:
	var out: Array = []
	var xf := global_transform
	var s := xf.basis.get_scale().x
	for h: Dictionary in hit_shapes:
		out.append({"component": h["component"], "center": xf * (h["center"] as Vector3), "radius": float(h["radius"]) * s})
	return out


func mass_factor() -> float:
	return float(Combat.MASS.get(mass_class, 0.5))


func total_hp() -> float:
	var s := 0.0
	for c: String in hp:
		s += float(hp[c])
	return s


func total_max_hp() -> float:
	var s := 0.0
	for c: String in max_hp:
		s += float(max_hp[c])
	return s


func destroyed() -> bool:
	return total_hp() <= 0.0


## Whether projectiles and splash can still strike this target (EnemyBase overrides to skip destroyed wrecks).
func is_hittable() -> bool:
	return true


## Can fire / move: not shut down and not staggered.
func can_act() -> bool:
	return heat.can_act() and not knock.staggered()


# --- Verbs (the owner only) ------------------------------------------------------------------------------

func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty():
		return
	var c := component if hp.has(component) else str(hp.keys()[0])
	hp[c] = maxf(float(hp[c]) - amount, 0.0)
	damaged.emit(amount, c, src)


func apply_impulse(dv: Vector3, src: String) -> void:
	var m := mass_factor()
	if m <= 0.0:
		aim_kick += dv.length() * Combat.AIM_KICK_DEG
		return
	if knock.add(dv * m):
		staggered_by.emit(src)


func apply_heat(amount: float, src: String) -> void:
	if amount > 0.0:
		heat.add(amount)


func apply_hit(h: Hit) -> void:
	apply_damage(h.damage, h.component, h.shooter)
	if h.impulse != Vector3.ZERO:
		apply_impulse(h.impulse, h.shooter)
	apply_heat(h.heat, h.shooter)


# --- Owner simulation ------------------------------------------------------------------------------------

## The owner's step (CombatWorld.advance calls it on targets this machine owns): heat, aim kick, knockback motion, slams.
func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	heat.tick(dt)
	aim_kick = maxf(aim_kick - Combat.AIM_KICK_RECOVER * dt, 0.0)
	var pos := global_position if is_inside_tree() else position
	if mass_factor() <= 0.0 or (not knock.moving() and pos.dot(up) <= ground_y + 0.001):
		knock.step(dt, pos, ground_y, null, probe_height, body_radius, up)   # still ages the stagger window
		return
	var r := knock.step(dt, pos, ground_y, space, probe_height, body_radius, up)
	if is_inside_tree():
		global_position = r["position"]
	else:
		position = r["position"]
	var slam := float(r["slam"])
	if slam > Combat.SLAM_SPEED:
		var dmg := (slam - Combat.SLAM_SPEED) * Combat.SLAM_DAMAGE
		apply_damage(dmg, "", "wall")
		slammed.emit(slam, dmg)


## Full HP, cold, still.
func reset_state() -> void:
	hp = max_hp.duplicate()
	heat.reset()
	knock.reset()
	aim_kick = 0.0
