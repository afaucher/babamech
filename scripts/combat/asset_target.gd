class_name AssetTarget
extends CombatTarget
## A mission asset enemies must be able to shoot (docs/design/weapons.md §5 "Mission assets"): the Defend objective's
## relay. A static, host-owned CombatTarget with NO authority of its own: the host's mission state holds the asset's HP.
##
##   target_id "asset_<asset_id>", team "player" (enemy fire is never spared and enemy AI acquires it; player shots follow
##   the friendly-fire rule like a teammate), owner_peer 0 (host-owned: CombatWorld.decides puts enemy fire on the host and
##   a client's shot on that client, which CombatNet carries to the host as "combat.hit", applied there once).
##
## On the owner (host / solo) an applied hit subtracts nothing here: it emits `asset_damaged(asset_id, amount, src)` with
## the hit's damage (TestDriveCombat.add_asset forwards it to MissionFlow.damage_asset). No knockback, no heat, no
## repair (heal returns 0, and the inherited hp / max_hp stay full so RepairDrone.repairable is false), never destroyed by
## combat: the mission layer pushes the host's HP to every machine with set_hp, and once it is <= 0 the asset is no longer
## hittable (shots pass, enemies stop targeting it). Before the first set_hp it is hittable.
##
## Dormant until its objective is active: while `live` is false (set_live, by the mission layer on every machine from
## the replicated objective state) it is not hittable either, so nothing targets or damages it before the defend starts.
##
## Hit spheres: stacked up `height` from the parent's origin, the first one at mid-height (EnemyBase aims at the first
## sphere's centre). Place it as a child of the asset's node (TestDriveCombat.add_asset does): position comes from there.
## Looks: none (the mission layer owns the model); impacts on it are the normal target-hit burst.
##
## The parent's `damaged(amount, component, src)` signal is also emitted ("body") so generic listeners see the hit.

signal asset_damaged(asset_id: String, amount: float, src: String)

var asset_id := ""
var radius := 2.5                 ## m: each hit sphere's radius
var height := 6.0                 ## m: the spheres reach from the origin up to about this
var hp_value := -1.0              ## the host's HP mirrored by set_hp (-1 = not pushed yet)
var hp_max := 0.0
var live := true                  ## false = dormant (set_live): not hittable, whatever the HP
## The asset's own collision body (the parent, when it is a CollisionObject3D: MissionWorld's relay body). Named `mech`
## because CombatWorld._body_excludes reads that member of registered targets: shot rays, wall scorch probes and crater
## probes then ignore the body, so shots meet the asset through its hit spheres (like a mech's capsule).
var mech: CollisionObject3D = null


func _init(id: String = "", r: float = 2.5, h: float = 6.0) -> void:
	super._init()
	mass_class = "static"
	owner_peer = 0
	team = "player"
	set_max_hp({"body": 1.0})     # never written: full forever (repairable false, destroyed false)
	configure(id, r, h)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	# hp_value / hp_max: a display mirror written on every machine from the host's mission state (like MechPuppet's
	# streamed mirrors, LOCAL); the authority is MissionFlow.asset_hp on the host.
	f.merge({"asset_id": Net.SPAWN, "radius": Net.SPAWN, "height": Net.SPAWN, "hp_value": Net.LOCAL, "hp_max": Net.LOCAL,
		"live": Net.LOCAL, "mech": Net.LOCAL})
	return f


func _enter_tree() -> void:
	if mech == null and get_parent() is CollisionObject3D:
		mech = get_parent() as CollisionObject3D


## Set the id and the sphere stack (before registering it).
func configure(id: String, r: float, h: float) -> void:
	asset_id = id
	target_id = "asset_" + id
	radius = maxf(r, 0.1)
	height = maxf(h, radius)
	name = "AssetTarget_" + id if id != "" else "AssetTarget"
	probe_height = height * 0.5
	body_radius = radius
	hit_shapes.clear()
	var mid := height * 0.5
	add_hit_sphere("body", Vector3.UP * mid, radius)        # first: the aim centre for enemy AI
	var lo := radius
	var hi := height - radius
	if hi > lo + 1e-3:
		var n := int(ceil((hi - lo) / radius)) + 1
		for i in n:
			var y := lerpf(lo, hi, float(i) / float(n - 1))
			if absf(y - mid) > radius * 0.25:
				add_hit_sphere("body", Vector3.UP * y, radius)


## The mission layer, on every machine, whenever the host's HP changes.
func set_hp(value: float, max_value: float) -> void:
	hp_max = maxf(max_value, 0.0)
	hp_value = clampf(value, 0.0, hp_max) if hp_max > 0.0 else maxf(value, 0.0)


## 0..1 (1 before the first set_hp).
func hp_fraction() -> float:
	if hp_value < 0.0:
		return 1.0
	return clampf(hp_value / hp_max, 0.0, 1.0) if hp_max > 0.0 else 0.0


## The mission layer, on every machine: true while the asset's objective is active (the same replicated state
## everywhere, so every machine agrees on whether a shot meets it). False = shots pass and enemies ignore it.
func set_live(on: bool) -> void:
	live = on


func is_hittable() -> bool:
	return live and (hp_value < 0.0 or hp_value > 0.0)


## The verbs, on the owner only (CombatWorld.deliver / CombatNet's host hit): report, never subtract.
func apply_damage(amount: float, _component: String, src: String) -> void:
	if amount <= 0.0 or not is_hittable():
		return
	asset_damaged.emit(asset_id, amount, src)
	damaged.emit(amount, "body", src)


func apply_impulse(_dv: Vector3, _src: String) -> void:
	pass


func apply_heat(_amount: float, _src: String) -> void:
	pass


func heal(_amount: float, _src: String) -> float:
	return 0.0


func tick(_dt: float, _space: PhysicsDirectSpaceState3D = null) -> void:
	pass
