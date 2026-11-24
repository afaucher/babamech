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
##   heal(amount, src) -> float             repair, most damaged component first (never a destroyed one)
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
signal healed(amount: float, component: String, src: String)

var target_id := ""
var owner_peer := 0
var team := ""                    ## faction ("player", "enemy", or "" neutral); same team spared (CombatWorld.spares)
var mass_class := "mech"
## ARMOUR (weapons.md §3.10): spawn data, the same on every machine, never changed in play. A hit on an armoured target
## has its damage scaled by the weapon's `armor_mult` (default 1.0; flak 0.35) where the hit is decided
## (CombatWorld.armor_scaled). Player mechs, the relay and armoured enemy classes (EnemyCatalog "armored") set it.
var armored := false
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
## Bumped by add_hit_sphere: with hit_shapes.size() it tells CombatWorld.first_hit its cached world spheres are stale.
var shapes_rev := 0
## CombatWorld.first_hit's cache of the hit spheres in world space (refresh_world_cache), valid while global_transform,
## shapes_rev and hit_shapes.size() match what it was built from. Same maths as world_spheres(); local, never synced.
var wc_xf := Transform3D()
var wc_rev := -1
var wc_n := -1
var wc_centers := PackedVector3Array()
var wc_radii := PackedFloat64Array()    ## float(radius) x scale, exactly as world_spheres computes it
var wc_comps: Array = []
var wc_bound_c := Vector3.ZERO          ## a sphere holding every hit sphere (broad-phase reject), padded
var wc_bound_r := -1.0
var wc_lc := PackedVector3Array()         ## hit_shapes' local centres / radii, unpacked at shapes_rev wc_lrev
var wc_lr := PackedFloat64Array()
var wc_lrev := -1
## Bumped by every add_hit_sphere on any target: CombatWorld's packed target bounds (first_hit during advance's effect
## step) are rebuilt when it changed, so a target that gains spheres mid-step is seen at once. (Removing spheres only
## shrinks a target: the packed bound still holds it.)
static var shapes_epoch := 0


func _init() -> void:
	heat = Heat.new()
	knock = Knockback.new()
	hp = max_hp.duplicate()


func net_fields() -> Dictionary:
	return {"target_id": Net.SPAWN, "owner_peer": Net.SPAWN, "team": Net.SPAWN, "mass_class": Net.SPAWN, "armored": Net.SPAWN, "max_hp": Net.SPAWN, "hp": Net.OWNER,
		"hit_shapes": Net.SPAWN, "heat": Net.OWNER, "knock": Net.OWNER, "aim_kick": Net.OWNER, "ground_y": Net.SPAWN, "up": Net.SPAWN,
		"probe_height": Net.SPAWN, "body_radius": Net.SPAWN,
		"shapes_rev": Net.LOCAL, "wc_xf": Net.LOCAL, "wc_rev": Net.LOCAL, "wc_n": Net.LOCAL, "wc_centers": Net.LOCAL,
		"wc_radii": Net.LOCAL, "wc_comps": Net.LOCAL, "wc_bound_c": Net.LOCAL, "wc_bound_r": Net.LOCAL,
		"wc_lc": Net.LOCAL, "wc_lr": Net.LOCAL, "wc_lrev": Net.LOCAL}


## Set HP per component (also resets hp).
func set_max_hp(by_component: Dictionary) -> void:
	max_hp = by_component.duplicate()
	hp = max_hp.duplicate()


func add_hit_sphere(component: String, center: Vector3, radius: float) -> void:
	hit_shapes.append({"component": component, "center": center, "radius": radius})
	shapes_rev += 1
	shapes_epoch += 1


## Rebuild the world-space sphere cache (wc_*) from `xf` (= global_transform): CombatWorld.first_hit calls it when
## wc_xf / wc_rev / wc_n no longer match. Centres and radii use world_spheres()' exact maths, so hits are unchanged.
func refresh_world_cache(xf: Transform3D) -> void:
	wc_xf = xf
	wc_rev = shapes_rev
	var n := hit_shapes.size()
	wc_n = n
	if wc_lrev != shapes_rev or wc_lc.size() != n:
		# the local spheres unpacked once per shape change (no dictionary reads per transform change)
		wc_lrev = shapes_rev
		wc_lc.resize(n)
		wc_lr.resize(n)
		wc_comps.resize(n)
		for i in n:
			var hs: Dictionary = hit_shapes[i]
			wc_lc[i] = hs["center"] as Vector3
			wc_lr[i] = float(hs["radius"])
			wc_comps[i] = hs["component"]
	wc_centers.resize(n)
	wc_radii.resize(n)
	var sc := xf.basis.get_scale().x
	var sum := Vector3.ZERO
	for i in n:
		var c: Vector3 = xf * wc_lc[i]
		wc_centers[i] = c
		wc_radii[i] = wc_lr[i] * sc
		sum += c
	if n == 0:
		wc_bound_r = -1.0
		return
	wc_bound_c = sum / float(n)
	var br := 0.0
	for i in n:
		br = maxf(br, wc_bound_c.distance_to(wc_centers[i]) + absf(wc_radii[i]))
	wc_bound_r = br * 1.0001 + 0.01       # padded: the reject must never drop a sphere a shot would meet


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


## Repair `amount` HP (back-equipment.md: the repair drone), spent on the most damaged component first (lowest HP
## fraction), spilling to the next; a destroyed component (hp 0) is never restored, and nothing happens to a target that
## is destroyed or not hittable (a downed PlayerTarget: `disabled`; a wreck). Returns the HP actually restored. The
## OWNER calls it on its own target only (the drone heals only targets CombatWorld.owns), like every verb.
## PlayerTarget needs no override: its component HP lives in hp / max_hp and is_hittable() is false while disabled.
func heal(amount: float, src: String) -> float:
	if amount <= 0.0 or hp.is_empty() or destroyed() or not is_hittable():
		return 0.0
	var left := amount
	var done := 0.0
	while left > 1e-9:
		var best := ""
		var best_f := 2.0
		for c: String in hp:
			var cap := float(max_hp.get(c, 0.0))
			var v := float(hp[c])
			if v <= 0.0 or cap <= 0.0 or v >= cap:
				continue
			if v / cap < best_f:
				best_f = v / cap
				best = c
		if best == "":
			break
		var add := minf(left, float(max_hp[best]) - float(hp[best]))
		hp[best] = float(hp[best]) + add
		left -= add
		done += add
		healed.emit(add, best, src)
	return done


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
