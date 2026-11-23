class_name PlayerTarget
extends CombatTarget
## The player mech as a CombatTarget (docs/design/weapons.md §2, vertical-slice.md S5 bridge):
##   - Component HP: torso 400, leg_l 200, leg_r 200, head 100, each mounted weapon hardpoint 80.
##   - Owner-authoritative (owner_peer = local_peer()): the victim's machine decides hits on its own mech.
##   - Bridges knockback impulse onto MechController.velocity, target heat onto MechController.add_heat(),
##     and exposes `component_fractions()` for MechHud + `is_slot_destroyed(hp)` for WeaponRack.
##   - Test Drive safety valve: if torso / head / leg_l / leg_r reaches 0 HP, emits `player_disabled(cause)` and
##     invokes `on_respawn` after `auto_respawn_delay` s (full HP + cold heat) so play never soft-locks.
##   - Fall damage (docs/design/weapons.md "Fall damage"): the bound mech's `hard_landing` above FALL_DAMAGE_SPEED
##     damages both legs (and the torso above FALL_TORSO_SPEED) through apply_damage, src "fall", on the owner's machine
##     only (a puppet's controller never steps, and its landings are ignored here). Landing thrusters avoid it by keeping
##     the impact low; a shut down mech has none. Component HP reaches the crew in the mech snapshots as usual.

signal player_component_destroyed(component: String)
signal player_disabled(cause: String)

const CORE_COMPONENTS := ["torso", "head", "leg_l", "leg_r"]
const COMPONENT_HP := {"torso": 400.0, "leg_l": 200.0, "leg_r": 200.0, "head": 100.0}
const WEAPON_HP := 80.0
const FALL_DAMAGE_SPEED := 20.0   ## m/s down at touchdown: below this no damage (a 9 m drop uncushioned is ~19.9)
const FALL_LEG_PER_MS := 3.0      ## HP to EACH leg per m/s above FALL_DAMAGE_SPEED
const FALL_LEG_MAX := 0.9         ## one fall takes at most this share of a leg's max HP (a healthy mech survives it)
const FALL_TORSO_SPEED := 40.0    ## m/s: extreme falls also hit the torso above this
const FALL_TORSO_PER_MS := 1.5    ## torso HP per m/s above FALL_TORSO_SPEED
## Local-space hit spheres for an 8 m Strider mech (mech_scale = 2.0, origin at feet).
const BODY_SPHERES := [
	{"component": "torso", "center": Vector3(0.0, 4.4, 0.0), "radius": 2.05},
	{"component": "head", "center": Vector3(0.0, 7.1, -0.75), "radius": 0.95},
	{"component": "leg_l", "center": Vector3(-1.35, 2.0, 0.0), "radius": 1.15},
	{"component": "leg_r", "center": Vector3(1.35, 2.0, 0.0), "radius": 1.15},
]
const HARDPOINT_SPHERES := {
	"side_l": {"center": Vector3(-2.8, 4.2, -0.6), "radius": 0.85},
	"side_r": {"center": Vector3(2.8, 4.2, -0.6), "radius": 0.85},
	"shoulder_l": {"center": Vector3(-1.9, 6.8, 0.4), "radius": 0.85},
	"shoulder_r": {"center": Vector3(1.9, 6.8, 0.4), "radius": 0.85},
	"back": {"center": Vector3(0.0, 5.8, 1.8), "radius": 0.95},
}

var mech: MechController
var model: MechModel
var world: CombatWorld
var disabled := false
var disable_cause := ""
var auto_respawn_delay := 1.5     ## s after disabled before Test Drive auto-respawn (< 0 = manual)
var on_respawn: Callable
var _respawn_left := -1.0


func _init() -> void:
	super._init()
	team = "player"
	mass_class = "mech"
	probe_height = 4.0
	body_radius = 2.2
	add_to_group("player_target")
	_setup_components({})


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"mech": Net.LOCAL, "model": Net.LOCAL, "world": Net.LOCAL, "disabled": Net.OWNER, "disable_cause": Net.OWNER,
		"auto_respawn_delay": Net.SPAWN, "on_respawn": Net.LOCAL, "_respawn_left": Net.PRIVATE})
	return f


func bind(w: CombatWorld, m: MechController, mm: MechModel = null, id: String = "player1", peer: int = 1) -> void:
	world = w
	if mech != null and is_instance_valid(mech) and mech.hard_landing.is_connected(_on_hard_landing):
		mech.hard_landing.disconnect(_on_hard_landing)
	mech = m
	if mech != null:
		mech.hard_landing.connect(_on_hard_landing)
	model = mm
	target_id = id
	owner_peer = maxi(peer, 1)
	var loadout: Dictionary = mm.loadout if mm != null else {}
	_setup_components(loadout)
	if mech != null and mech.is_inside_tree():
		global_transform = mech.global_transform
		up = mech.up()


func _setup_components(loadout: Dictionary) -> void:
	var caps := COMPONENT_HP.duplicate()
	hit_shapes.clear()
	for s: Dictionary in BODY_SPHERES:
		add_hit_sphere(str(s["component"]), s["center"] as Vector3, float(s["radius"]))
	for hp_id: String in HARDPOINT_SPHERES:
		if str(loadout.get(hp_id, "")) != "":
			caps[hp_id] = WEAPON_HP
			var sp: Dictionary = HARDPOINT_SPHERES[hp_id]
			add_hit_sphere(hp_id, sp["center"] as Vector3, float(sp["radius"]))
	set_max_hp(caps)
	disabled = false
	disable_cause = ""
	_respawn_left = -1.0


func is_hittable() -> bool:
	return not disabled


func is_slot_destroyed(hp_id: String) -> bool:
	return hp.has(hp_id) and float(hp[hp_id]) <= 0.0


func component_fractions() -> Dictionary:
	var out := {}
	for k: String in max_hp:
		var cap := maxf(float(max_hp[k]), 0.001)
		out[k] = clampf(float(hp.get(k, 0.0)) / cap, 0.0, 1.0)
	return out


func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty() or disabled:
		return
	var c := component if hp.has(component) else "torso"
	var before := float(hp[c])
	hp[c] = maxf(before - amount, 0.0)
	damaged.emit(amount, c, src)
	if before > 0.0 and float(hp[c]) <= 0.0:
		player_component_destroyed.emit(c)
		if c in CORE_COMPONENTS and not disabled:
			disabled = true
			disable_cause = c
			_respawn_left = auto_respawn_delay
			player_disabled.emit(c)


## Damage from a touchdown at `speed` m/s down: {"leg": HP to each leg, "torso": HP} (zeros at or below the threshold).
static func fall_damage(speed: float) -> Dictionary:
	var leg := minf(maxf(speed - FALL_DAMAGE_SPEED, 0.0) * FALL_LEG_PER_MS, float(COMPONENT_HP["leg_l"]) * FALL_LEG_MAX)
	var torso := maxf(speed - FALL_TORSO_SPEED, 0.0) * FALL_TORSO_PER_MS
	return {"leg": leg, "torso": torso}


## MechController.hard_landing: the owner's own mech hit the ground hard (no thrust cushion, or not enough).
func _on_hard_landing(speed: float, _severity: float) -> void:
	if mech == null or mech.puppet or disabled:
		return
	var d := fall_damage(speed)
	if float(d["leg"]) <= 0.0:
		return
	apply_damage(float(d["leg"]), "leg_l", "fall")
	apply_damage(float(d["leg"]), "leg_r", "fall")
	apply_damage(float(d["torso"]), "torso", "fall")


func apply_impulse(dv: Vector3, src: String) -> void:
	var m := mass_factor()
	if m <= 0.0:
		return
	var kick := dv * m
	if mech != null:
		mech.velocity += kick
	if world != null and kick.length() > 0.2:
		world.shake.emit(minf(kick.length() * 0.45, 3.0), global_position)
	if knock.add(kick):
		staggered_by.emit(src)


func apply_heat(amount: float, _src: String) -> void:
	if amount <= 0.0:
		return
	if mech != null:
		mech.add_heat(amount)
	else:
		heat.add(amount)


func tick(dt: float, _space: PhysicsDirectSpaceState3D = null) -> void:
	# Follow the live MechController transform; knockback is already forwarded to MechController.velocity.
	if mech != null and is_instance_valid(mech):
		if mech.is_inside_tree() and is_inside_tree():
			global_transform = mech.global_transform
		up = mech.up()
	knock.step(dt, global_position if is_inside_tree() else position, 0.0, null, probe_height, body_radius, up)
	knock.velocity = Vector3.ZERO
	if disabled and _respawn_left >= 0.0:
		_respawn_left -= dt
		if _respawn_left <= 0.0:
			repair_all()
			if mech != null:
				mech.heat = 0.0
				mech.shutdown = false
			if on_respawn.is_valid():
				on_respawn.call()


func repair_all() -> void:
	reset_state()
	disabled = false
	disable_cause = ""
	_respawn_left = -1.0
