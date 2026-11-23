class_name BannerTarget
extends CombatTarget
## One invader banner's cloth as a combat target (docs/design/banners.md): a static, host-owned world object
## (AGENTS rule 6, shape 3: host-arbitrated). Pattern: AssetTarget (scripts/combat/asset_target.gd).
##
##   target_id "banner_<deck>_<id>", owner_peer 0 (host-owned: CombatWorld.decides puts a client's shot on that client,
##   which CombatNet carries to the host as "combat.hit", applied there once), mass_class "static".
##   team "enemy": enemy fire passes through (CombatWorld.spares: same team, not "player"), enemy AI never acquires or
##   alerts on it (EnemyBase / EnemyDrone skip their own team; every other team-"player" scan ignores it), player bots
##   only track EnemyBase, the repair drone skips team "enemy". Player fire damages it (different teams are never spared).
##
## HP (`hp["cloth"]`, MAX_HP) is written only on the host, through apply_damage; it is never synced. When it reaches 0
## the host emits `cloth_down` once; OccupationBanners decides the tear, sends one "banner.torn" event and sets `torn` on
## every machine. A torn banner is no longer hittable (shots pass, no impacts). No knockback, no heat, no repair.
##
## Hit spheres: two columns by enough rows to cover the 4 m wide cloth hanging down -Y from the origin (the cross-bar).

signal cloth_down(deck: int, banner_id: int)

const MAX_HP := 60.0              ## a few autocannon hits (22 each), one rocket salvo
const SPHERE_R := 1.15            ## m

var deck := 0
var banner_id := 0
var cloth_len := BannerMeshes.H   ## m: the cloth's length (sets the sphere rows)
var torn := false                 ## mirror of the host's decision (OccupationBanners sets it on every machine)


func _init(k: int = 0, id: int = 0, length: float = BannerMeshes.H) -> void:
	super._init()
	mass_class = "static"
	owner_peer = 0
	team = "enemy"
	set_max_hp({"cloth": MAX_HP})
	configure(k, id, length)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	# torn: a mirror written on every machine from the host's "banner.torn" (OccupationBanners.torn is the authority).
	f.merge({"deck": Net.SPAWN, "banner_id": Net.SPAWN, "cloth_len": Net.SPAWN, "torn": Net.LOCAL})
	return f


func configure(k: int, id: int, length: float) -> void:
	deck = k
	banner_id = id
	cloth_len = clampf(length, 2.0, 8.0)
	target_id = "banner_%d_%d" % [k, id]
	name = "BannerTarget"
	probe_height = -cloth_len * 0.5
	body_radius = SPHERE_R
	hit_shapes.clear()
	var rows := maxi(int(ceil((cloth_len - 0.4) / (SPHERE_R * 1.75))), 1)
	for r in rows:
		var y := -lerpf(SPHERE_R * 0.85, cloth_len - SPHERE_R * 1.1, (float(r) / float(rows - 1)) if rows > 1 else 0.5)
		for sx: float in [-1.0, 1.0]:
			add_hit_sphere("cloth", Vector3(sx * 0.95, y, 0.0), SPHERE_R)


func is_hittable() -> bool:
	return not torn


## The owner's verb (the host / solo): the cloth loses HP; at 0 the host decides the tear (cloth_down, once).
func apply_damage(amount: float, component: String, src: String) -> void:
	if torn or amount <= 0.0 or destroyed():
		return
	super.apply_damage(amount, "cloth" if component == "" else component, src)
	if destroyed():
		cloth_down.emit(deck, banner_id)


func apply_impulse(_dv: Vector3, _src: String) -> void:
	pass


func apply_heat(_amount: float, _src: String) -> void:
	pass


func heal(_amount: float, _src: String) -> float:
	return 0.0


func tick(_dt: float, _space: PhysicsDirectSpaceState3D = null) -> void:
	pass
