class_name DepotTarget
extends CombatTarget
## A military supply depot's bunker as a combat target (docs/design/pacing-director.md §2): a static, host-owned world
## object (AGENTS rule 6, shape 3: host-arbitrated). Pattern: BannerTarget / AssetTarget.
##
##   target_id "depot_<id>", owner_peer 0 (host-owned: CombatWorld.decides puts a client's shot on that client, which
##   CombatNet carries to the host as "combat.hit", applied there once), mass_class "static".
##   team "" (neutral): no shot spares it (CombatWorld.spares: an empty team is never spared), so crew fire and stray enemy
##   shots both damage it; enemy AI never acquires it (EnemyBase / EnemyDrone skip team "", every other enemy scan looks
##   for team "player"), player bots only track EnemyBase, the repair drone's heal does nothing here.
##
## HP (`hp["body"]`, MAX_HP, about a turret's) is written only on the host, through apply_damage; never synced. At 0 the
## host emits `depot_down` once; MissionDepots marks the depot dead (its cores lost) in the replicated mission state and
## every machine sets `alive` false: no longer hittable (shots pass), the bunker shows its wreck.
## `mech`: the bunker's own collision body (CombatWorld._body_excludes reads that member: shots meet the depot through its
## hit spheres, like a mech's capsule).

signal depot_down(depot_id: String)

const MAX_HP := 250.0             ## about a rooftop turret's (EnemyCatalog turret: base 150 + gun 75)
const SPHERE_R := 1.6             ## m

var depot_id := ""
var alive := true                 ## mirror of the host's decision (MissionDepots sets it on every machine)
var mech: CollisionObject3D = null


func _init(id: String = "") -> void:
	super._init()
	mass_class = "static"
	owner_peer = 0
	team = ""
	set_max_hp({"body": MAX_HP})
	configure(id)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	# alive: a mirror written on every machine from the host's mission state (MissionDepots' `alive` is the authority);
	# mech: this machine's node reference.
	f.merge({"depot_id": Net.SPAWN, "alive": Net.LOCAL, "mech": Net.LOCAL})
	return f


## The id and the spheres: a row of three along the bunker's 6 m length, two high (local, origin on the ground).
func configure(id: String) -> void:
	depot_id = id
	target_id = "depot_" + id
	name = "DepotTarget"
	probe_height = 1.5
	body_radius = SPHERE_R
	hit_shapes.clear()
	add_hit_sphere("body", Vector3(0.0, 1.5, 0.0), SPHERE_R)    # first: the aim centre
	for x: float in [-1.9, 1.9]:
		add_hit_sphere("body", Vector3(x, 1.4, 0.0), SPHERE_R)
	for x: float in [-1.4, 0.0, 1.4]:
		add_hit_sphere("body", Vector3(x, 2.6, 0.0), 1.1)


func _enter_tree() -> void:
	if mech == null and get_parent() != null:
		mech = get_parent().get_node_or_null("Body") as CollisionObject3D


func is_hittable() -> bool:
	return alive


## The owner's verb (host / solo): the bunker loses HP; at 0 it reports `depot_down` once.
func apply_damage(amount: float, _component: String, src: String) -> void:
	if not alive or amount <= 0.0 or destroyed():
		return
	super.apply_damage(amount, "body", src)
	if destroyed():
		depot_down.emit(depot_id)


func apply_impulse(_dv: Vector3, _src: String) -> void:
	pass


func apply_heat(_amount: float, _src: String) -> void:
	pass


func heal(_amount: float, _src: String) -> float:
	return 0.0


func tick(_dt: float, _space: PhysicsDirectSpaceState3D = null) -> void:
	pass
