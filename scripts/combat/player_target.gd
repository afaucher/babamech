class_name PlayerTarget
extends CombatTarget
## The player mech as a CombatTarget (docs/design/weapons.md §2, vertical-slice.md S5 bridge):
##   - Component HP: torso 400, leg_l 200, leg_r 200, head 100, each mounted weapon hardpoint 80 (the Strider; another
##     chassis: CHASSIS_COMPONENT_HP, its hit spheres CHASSIS_BODY_SPHERES / CHASSIS_HARDPOINT_SPHERES, its wall probe
##     the catalog capsule; all by the bound model's chassis_id, the same on every machine).
##   - Owner-authoritative (owner_peer = local_peer()): the victim's machine decides hits on its own mech.
##   - Bridges knockback impulse onto MechController.velocity, target heat onto MechController.add_heat(),
##     and exposes `component_fractions()` for MechHud + `is_slot_destroyed(hp)` for WeaponRack.
##   - DOWNED / REVIVE / RESPAWN (docs/design/pacing-director.md "Downed, revive, respawn", numbers in DownedRules; user
##     decision 2026-11-24): torso / head / leg_l / leg_r at 0 HP downs the mech (`disabled`, `player_disabled(cause)`).
##     It stays where it fell, takes no damage and is not hittable (enemies drop it); the owner's input layer stops its
##     movement and weapons (TestDrive / TestDriveCombat / CrewBot). NO automatic respawn. Then, on the OWNER's machine:
##       revive    a crewmate's repair drone beaming it (RepairDrone calls revive_tick on the machine that owns this
##                 target, so nobody writes another pilot's mech): REVIVE_TIME s of beam -> revive(from): stands up in
##                 place, destroyed components at REVIVE_STRUCTURE, every other at least that, heat 0, shutdown cleared,
##                 REVIVE_INVULN s of no damage, `player_revived(by, time_down)`. Beam gone: the bar drains over
##                 REVIVE_DECAY s.
##       respawn   `respawn_held` (the owner's key, set every step by its input layer; bots: `auto_redeploy` after
##                 `revive_wait` s while no revive is in progress) for RESPAWN_HOLD s -> `redeploying` for
##                 RESPAWN_PENALTY s (still disabled: out of the fight) -> every component at RESPAWN_STRUCTURE, heat 0,
##                 `on_respawn` places the mech (DownedCrew: the lead pilot's deck arrival point), `player_respawned`.
##     `disabled`, `redeploying`, `revive_progress` and `aid_charges` (the owner's repair-drone charges, for the crew's
##     "can revive" HUD) ride in the mech snapshot (NetMechCodec); a puppet's target mirrors them.
##     TEST / LAB HOOK: `auto_respawn_delay` >= 0 brings back the old instant respawn (full HP, cold, on_respawn) that
##     many s after going down; default -1 (off).
##   - Fall damage (docs/design/weapons.md "Fall damage"): the bound mech's `hard_landing` above FALL_DAMAGE_SPEED
##     damages both legs (and the torso above FALL_TORSO_SPEED) through apply_damage, src "fall", on the owner's machine
##     only (a puppet's controller never steps, and its landings are ignored here). Landing thrusters avoid it by keeping
##     the impact low; a shut down mech has none. Component HP reaches the crew in the mech snapshots as usual.

signal player_component_destroyed(component: String)
signal player_disabled(cause: String)
signal player_revived(by: String, time_down: float)
signal redeploy_started(time_down: float)
signal player_respawned(time_down: float, held: bool)

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
## Other chassis' weapon hardpoint spheres (same frame; a chassis not listed uses HARDPOINT_SPHERES). The Bulwark
## (2026-11-24, Bulwark weapons): its side guns pivot 3.57 m out, 6.4 m up, 2.9 m ahead of the origin and reach ~1.5 m
## further forward; its back saddles sit 2.16 m out, 6.8 m up, 2.2 m behind, the mortar rising ~3 m over them.
const CHASSIS_HARDPOINT_SPHERES := {
	"bulwark": {
		"side_l": {"center": Vector3(-3.57, 6.3, -3.7), "radius": 0.9},
		"side_r": {"center": Vector3(3.57, 6.3, -3.7), "radius": 0.9},
		"back_l": {"center": Vector3(-2.16, 7.6, 2.0), "radius": 0.95},
		"back_r": {"center": Vector3(2.16, 7.6, 2.0), "radius": 0.95},
	},
}
## Other chassis' body spheres (same frame; a chassis not listed uses BODY_SPHERES). The FIRST sphere of a list is the
## mech's aim centre (enemies aim at a target's first hit sphere: EnemyBase._target_aim_center), so it sits at the
## body's centre of mass. tests/test_chassis_body.gd measures every list against the real meshes (ray coverage).
## The Bulwark (2026-11-24, fitted by a greedy cover of its visible surface, standing rest pose, symmetric; numbers in
## test_chassis_body): the hull slab and hip pods as 24 overlapping spheres mid-slab (a flat 9 x 7.5 m hull needs a grid:
## a few big spheres stick out metres above and below it), the pilot in its well (4), each leg's hip cup / thigh, knee
## pad, shin, ankle and boot (6 a side). The pods are torso (one hull: no new component id for the codec / HUD).
const CHASSIS_BODY_SPHERES := {
	"bulwark": [
		{"component": "torso", "center": Vector3(0.0, 5.0, 0.2), "radius": 1.1},     # the aim centre (inside the hull)
		{"component": "torso", "center": Vector3(-3.3, 6.07, 0.22), "radius": 1.48},
		{"component": "torso", "center": Vector3(3.3, 6.07, 0.22), "radius": 1.48},
		{"component": "torso", "center": Vector3(-0.6, 5.17, -2.18), "radius": 1.5},
		{"component": "torso", "center": Vector3(0.6, 5.17, -2.18), "radius": 1.5},
		{"component": "torso", "center": Vector3(-0.9, 5.47, 1.72), "radius": 1.53},
		{"component": "torso", "center": Vector3(0.9, 5.47, 1.72), "radius": 1.53},
		{"component": "torso", "center": Vector3(-2.1, 6.07, 2.32), "radius": 1.28},
		{"component": "torso", "center": Vector3(2.1, 6.07, 2.32), "radius": 1.28},
		{"component": "torso", "center": Vector3(-0.9, 4.87, -0.08), "radius": 1.38},
		{"component": "torso", "center": Vector3(0.9, 4.87, -0.08), "radius": 1.38},
		{"component": "torso", "center": Vector3(-3.9, 6.37, -0.38), "radius": 1.22},
		{"component": "torso", "center": Vector3(3.9, 6.37, -0.38), "radius": 1.22},
		{"component": "torso", "center": Vector3(-0.6, 5.77, 2.92), "radius": 1.02},
		{"component": "torso", "center": Vector3(0.6, 5.77, 2.92), "radius": 1.02},
		{"component": "torso", "center": Vector3(-1.8, 6.07, -0.68), "radius": 1.09},
		{"component": "torso", "center": Vector3(1.8, 6.07, -0.68), "radius": 1.09},
		{"component": "torso", "center": Vector3(-3.3, 5.17, 0.22), "radius": 1.29},
		{"component": "torso", "center": Vector3(3.3, 5.17, 0.22), "radius": 1.29},
		{"component": "torso", "center": Vector3(-0.6, 5.47, -2.48), "radius": 1.4},
		{"component": "torso", "center": Vector3(0.6, 5.47, -2.48), "radius": 1.4},
		{"component": "torso", "center": Vector3(-0.6, 4.87, 1.12), "radius": 1.38},
		{"component": "torso", "center": Vector3(0.6, 4.87, 1.12), "radius": 1.38},
		{"component": "torso", "center": Vector3(-3.6, 6.07, 0.22), "radius": 1.42},
		{"component": "torso", "center": Vector3(3.6, 6.07, 0.22), "radius": 1.42},
		{"component": "head", "center": Vector3(0.0, 7.45, -0.85), "radius": 0.95},   # the pilot's head over the coaming
		{"component": "head", "center": Vector3(0.0, 7.45, 0.0), "radius": 0.95},
		{"component": "head", "center": Vector3(0.0, 8.25, -0.4), "radius": 0.75},    # crown / comb
		{"component": "head", "center": Vector3(0.0, 6.4, -0.4), "radius": 0.9},      # neck in the well
		{"component": "leg_l", "center": Vector3(-3.38, 4.2, -0.38), "radius": 1.27},
		{"component": "leg_r", "center": Vector3(3.38, 4.2, -0.38), "radius": 1.27},
		{"component": "leg_l", "center": Vector3(-3.38, 2.7, -1.58), "radius": 1.35},
		{"component": "leg_r", "center": Vector3(3.38, 2.7, -1.58), "radius": 1.35},
		{"component": "leg_l", "center": Vector3(-3.68, 2.7, -2.78), "radius": 0.87},
		{"component": "leg_r", "center": Vector3(3.68, 2.7, -2.78), "radius": 0.87},
		{"component": "leg_l", "center": Vector3(-3.38, 1.2, -0.68), "radius": 1.06},
		{"component": "leg_r", "center": Vector3(3.38, 1.2, -0.68), "radius": 1.06},
		{"component": "leg_l", "center": Vector3(-3.38, 0.6, -0.08), "radius": 1.01},
		{"component": "leg_r", "center": Vector3(3.38, 0.6, -0.08), "radius": 1.01},
		{"component": "leg_l", "center": Vector3(-3.38, 0.3, 0.22), "radius": 0.9},
		{"component": "leg_r", "center": Vector3(3.38, 0.3, 0.22), "radius": 0.9},
	],
}
## Extra head spheres for a pilot head that sticks out past a chassis' head spheres: chassis -> head id -> spheres (the
## head id is spawn data like the chassis). The Bulwark's head spheres fit the chicken / pickle / corn; the duck's bill
## and the dog's snout and ears reach further.
const CHASSIS_HEAD_EXTRA := {
	"bulwark": {
		"duck": [{"component": "head", "center": Vector3(0.0, 7.35, -1.85), "radius": 0.6}],
		"dog": [{"component": "head", "center": Vector3(0.0, 7.35, -1.85), "radius": 0.6},
			{"component": "head", "center": Vector3(-1.15, 7.75, -0.25), "radius": 0.6},
			{"component": "head", "center": Vector3(1.15, 7.75, -0.25), "radius": 0.6}],
	},
}
## Other chassis' component HP (a chassis not listed uses COMPONENT_HP). Same component ids on every chassis (the codec,
## the HUD, the revive / repair logic know them); hardpoints are WEAPON_HP on every chassis. The Bulwark (heavy, 55 t
## vs 38 t): +40 % core HP (1260 vs 900) for a hull and legs that present about twice the Strider's area; the pilot's
## head stays 100 (same pilot, sunk in a well: a smaller target than the Strider's).
const CHASSIS_COMPONENT_HP := {
	"bulwark": {"torso": 600.0, "leg_l": 280.0, "leg_r": 280.0, "head": 100.0},
}
## Where an enemy looks when a low wall hides a mech's torso (EnemyBase._sight_offset): m from the aim centre (the first
## body sphere) up to the head and down to the legs along the mech's up, and `legs_side` m along its right (the
## Bulwark's legs hang 3.4 m out under its pods: straight down from the hull's centre is the gap between them).
const CHASSIS_SIGHT := {
	"strider": {"head_up": 2.6, "legs_down": 2.3, "legs_side": 0.0},
	"bulwark": {"head_up": 2.4, "legs_down": 3.8, "legs_side": 3.4},   # head 7.4 m up; a shin 1.2 m up, 3.4 m out
}

var mech: MechController
var model: MechModel
var world: CombatWorld
var disabled := false             ## downed (or redeploying): a core component destroyed, out of the fight
var disable_cause := ""
var redeploying := false          ## held to respawn: the penalty runs (still disabled; streamed)
var revive_progress := 0.0        ## s of drone beam toward DownedRules.REVIVE_TIME (streamed: the crew's revive bar)
var aid_charges := 0              ## repair-drone charges left on this mech (the owner's DownedCrew writes it; streamed)
var respawn_held := false         ## the owner's respawn key this step (TestDrive input; tests set it)
var respawn_hold := 0.0           ## s the key has been held while downed
var redeploy_left := 0.0          ## s of the penalty left while redeploying
var down_time := 0.0              ## s since going down (through the penalty)
var invuln_left := 0.0            ## s of no damage left after a revive
var auto_redeploy := false        ## bots (no key): take the respawn path after revive_wait s downed
var revive_wait: Callable         ## () -> float: s a bot waits for a revive (DownedCrew); invalid = DownedRules.BOT_ALONE_WAIT
var revived_by := ""              ## the shooter whose drone beam is reviving / revived it
var auto_respawn_delay := -1.0    ## TEST / LAB HOOK: >= 0 = the old instant respawn this many s after going down
var on_respawn: Callable
var chassis := "strider"          ## the bound mech's chassis (its hit spheres, component HP, sight offsets come from it)
var sight_head_up := 2.6          ## CHASSIS_SIGHT of the chassis (EnemyBase._sight_offset)
var sight_legs_down := 2.3
var sight_legs_side := 0.0
var _respawn_left := -1.0
var _beamed := false              ## a drone beam reached it since the last tick (one beam per step counts)


func _init() -> void:
	super._init()
	team = "player"
	mass_class = "mech"
	armored = true                # weapons.md §3.10: flak's armor_mult applies to mechs
	probe_height = 4.0
	body_radius = 2.2
	add_to_group("player_target")
	_setup_components({})


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"mech": Net.LOCAL, "model": Net.LOCAL, "world": Net.LOCAL, "disabled": Net.OWNER, "disable_cause": Net.OWNER,
		"redeploying": Net.OWNER, "revive_progress": Net.OWNER, "aid_charges": Net.OWNER, "respawn_held": Net.LOCAL,
		"respawn_hold": Net.PRIVATE, "redeploy_left": Net.PRIVATE, "down_time": Net.PRIVATE, "invuln_left": Net.PRIVATE,
		"auto_redeploy": Net.SPAWN, "revive_wait": Net.LOCAL, "revived_by": Net.PRIVATE,
		"auto_respawn_delay": Net.SPAWN, "on_respawn": Net.LOCAL, "_respawn_left": Net.PRIVATE, "_beamed": Net.PRIVATE,
		"chassis": Net.SPAWN, "sight_head_up": Net.SPAWN, "sight_legs_down": Net.SPAWN, "sight_legs_side": Net.SPAWN})
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
	_setup_components(loadout, mm.chassis_id if mm != null else "strider", mm.head_id if mm != null else "")
	if mech != null and mech.is_inside_tree():
		global_transform = mech.global_transform
		up = mech.up()


## The weapon hardpoint spheres of a chassis (CHASSIS_HARDPOINT_SPHERES, else the Strider's HARDPOINT_SPHERES).
static func hardpoint_spheres(chassis_id: String) -> Dictionary:
	return CHASSIS_HARDPOINT_SPHERES.get(chassis_id, HARDPOINT_SPHERES)


## The body spheres of a chassis (CHASSIS_BODY_SPHERES, else the Strider's BODY_SPHERES); the first is the aim centre.
static func body_spheres(chassis_id: String) -> Array:
	return CHASSIS_BODY_SPHERES.get(chassis_id, BODY_SPHERES)


## The body spheres of a chassis flown by pilot head `head_id`: body_spheres plus CHASSIS_HEAD_EXTRA's for that head.
static func body_spheres_for(chassis_id: String, head_id: String) -> Array:
	var extra: Array = (CHASSIS_HEAD_EXTRA.get(chassis_id, {}) as Dictionary).get(head_id, [])
	return body_spheres(chassis_id) if extra.is_empty() else body_spheres(chassis_id) + extra


## The core component HP of a chassis (CHASSIS_COMPONENT_HP, else the Strider's COMPONENT_HP).
static func component_hp(chassis_id: String) -> Dictionary:
	return CHASSIS_COMPONENT_HP.get(chassis_id, COMPONENT_HP)


## The enemy sight offsets of a chassis {head_up, legs_down} (CHASSIS_SIGHT, else the Strider's).
static func sight(chassis_id: String) -> Dictionary:
	return CHASSIS_SIGHT.get(chassis_id, CHASSIS_SIGHT["strider"])


## The vertical capsule round a chassis' body spheres: {r: the farthest sphere edge from the up axis, hi: the highest
## sphere top} (m). BotFireGuard's crew capsule for a chassis other than the Strider (whose guard numbers predate this).
static func body_extent(chassis_id: String) -> Dictionary:
	var r := 0.0
	var hi := 0.0
	for s: Dictionary in body_spheres(chassis_id):
		var c: Vector3 = s["center"]
		r = maxf(r, Vector2(c.x, c.z).length() + float(s["radius"]))
		hi = maxf(hi, c.y + float(s["radius"]))
	return {"r": r, "hi": hi}


## The local centre of a hardpoint's hit sphere on a chassis (Vector3.ZERO for a hardpoint it does not have).
static func hardpoint_center(chassis_id: String, hp_id: String) -> Vector3:
	var s: Dictionary = hardpoint_spheres(chassis_id).get(hp_id, {})
	return s.get("center", Vector3.ZERO)


## The hardpoint ids of a chassis that carry back equipment (MechCatalog mount "back": the Strider's "back", the
## Bulwark's back_l / back_r), in catalog order.
static func back_hardpoints(chassis_id: String) -> Array[String]:
	var out: Array[String] = []
	for hp: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		if "back" in MechCatalog.hardpoint_mounts(hp):
			out.append(str(hp["id"]))
	return out


func _setup_components(loadout: Dictionary, chassis_id: String = "strider", head_id: String = "") -> void:
	chassis = chassis_id
	var caps := component_hp(chassis_id).duplicate()
	var mv := MechCatalog.movement(chassis_id)
	probe_height = float(mv["capsule_height"]) * 0.5   # the capsule's centre (Strider 4)
	body_radius = float(mv["capsule_radius"])          # Strider 2.2, Bulwark 3.6
	var sg := sight(chassis_id)
	sight_head_up = float(sg["head_up"])
	sight_legs_down = float(sg["legs_down"])
	sight_legs_side = float(sg.get("legs_side", 0.0))
	hit_shapes.clear()
	for s: Dictionary in body_spheres_for(chassis_id, head_id):
		add_hit_sphere(str(s["component"]), s["center"] as Vector3, float(s["radius"]))
	var spheres := hardpoint_spheres(chassis_id)
	for hp_id: String in spheres:
		if str(loadout.get(hp_id, "")) != "":
			caps[hp_id] = WEAPON_HP
			var sp: Dictionary = spheres[hp_id]
			add_hit_sphere(hp_id, sp["center"] as Vector3, float(sp["radius"]))
	set_max_hp(caps)
	_clear_down()
	invuln_left = 0.0


## The world-space offsets from the aim centre an enemy tries when low cover hides the torso: [head, legs]. The Strider:
## [up * 2.6, -up * 2.3] (EnemyBase's old constants).
func sight_offsets() -> Array:
	var right := global_basis.x.normalized() if is_inside_tree() else transform.basis.x.normalized()
	return [up * sight_head_up, -up * sight_legs_down + right * sight_legs_side]


func is_hittable() -> bool:
	return not disabled


## Downed and waiting (not redeploying): a drone beam can revive it.
func revivable() -> bool:
	return disabled and not redeploying


func is_slot_destroyed(hp_id: String) -> bool:
	return hp.has(hp_id) and float(hp[hp_id]) <= 0.0


func component_fractions() -> Dictionary:
	var out := {}
	for k: String in max_hp:
		var cap := maxf(float(max_hp[k]), 0.001)
		out[k] = clampf(float(hp.get(k, 0.0)) / cap, 0.0, 1.0)
	return out


func apply_damage(amount: float, component: String, src: String) -> void:
	if amount <= 0.0 or hp.is_empty() or disabled or invuln_left > 0.0:
		return
	var c := component if hp.has(component) else "torso"
	var before := float(hp[c])
	hp[c] = maxf(before - amount, 0.0)
	damaged.emit(amount, c, src)
	if before > 0.0 and float(hp[c]) <= 0.0:
		player_component_destroyed.emit(c)
		if c in CORE_COMPONENTS and not disabled:
			_clear_down()
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
	if invuln_left > 0.0:
		invuln_left = maxf(invuln_left - dt, 0.0)
	if not disabled:
		_beamed = false
		return
	down_time += dt
	if auto_respawn_delay >= 0.0 and _respawn_left >= 0.0:   # the test / lab hook: the old instant respawn
		_respawn_left -= dt
		if _respawn_left <= 0.0:
			var t := down_time
			repair_all()
			if mech != null:
				mech.heat = 0.0
				mech.shutdown = false
			if on_respawn.is_valid():
				on_respawn.call()
			player_respawned.emit(t, false)
		return
	if redeploying:
		redeploy_left -= dt
		if redeploy_left <= 0.0:
			_finish_redeploy()
		return
	if not _beamed and revive_progress > 0.0:
		revive_progress = maxf(revive_progress - dt * DownedRules.decay_rate(), 0.0)
	_beamed = false
	if respawn_held:
		respawn_hold += dt
		if respawn_hold >= DownedRules.RESPAWN_HOLD - 1e-6:
			start_redeploy()
			return
	else:
		respawn_hold = 0.0
	if auto_redeploy and revive_progress <= 0.0:
		var wait := float(revive_wait.call()) if revive_wait.is_valid() else DownedRules.BOT_ALONE_WAIT
		if down_time >= wait - 1e-6:
			start_redeploy()


# --- Downed: revive and respawn (the OWNER's machine only: these are verbs on its own mech) ----------------------------

## A repair drone's beam reached this downed mech for `dt` s (RepairDrone, on the machine that owns this target). One beam
## per step counts (two drones don't stack); REVIVE_TIME s of it revive the mech.
func revive_tick(dt: float, from: String) -> void:
	if not revivable() or dt <= 0.0 or _beamed:
		return
	_beamed = true
	revived_by = from
	revive_progress = minf(revive_progress + dt, DownedRules.REVIVE_TIME)
	if revive_progress >= DownedRules.REVIVE_TIME - 1e-6:
		revive(from)


## Stand the downed mech up IN PLACE (the revive): destroyed components at REVIVE_STRUCTURE, every other at least that,
## heat 0, shutdown cleared, REVIVE_INVULN s of no damage. Ammo unchanged. Not a death.
func revive(from: String) -> void:
	if not revivable():
		return
	var t := down_time
	_set_structure(DownedRules.REVIVE_STRUCTURE, true)
	_clear_down()
	vent_heat()
	invuln_left = DownedRules.REVIVE_INVULN
	revived_by = from
	player_revived.emit(from, t)


## The respawn path starts (the hold completed, or a bot's wait ran out): RESPAWN_PENALTY s redeploying.
func start_redeploy() -> void:
	if not revivable():
		return
	redeploying = true
	redeploy_left = DownedRules.RESPAWN_PENALTY
	respawn_hold = 0.0
	revive_progress = 0.0
	redeploy_started.emit(down_time)


## The penalty is over: every component at RESPAWN_STRUCTURE, heat 0, placed by on_respawn. Ammo unchanged. A death.
func _finish_redeploy() -> void:
	var t := down_time
	_set_structure(DownedRules.RESPAWN_STRUCTURE, false)
	_clear_down()
	vent_heat()
	if on_respawn.is_valid():
		on_respawn.call()
	player_respawned.emit(t, true)


## Every component to `fraction` of its max (`at_least`: only those below it are raised; destroyed ones are rebuilt
## either way).
func _set_structure(fraction: float, at_least: bool) -> void:
	for c: String in hp:
		var v := float(max_hp.get(c, 0.0)) * fraction
		hp[c] = maxf(float(hp[c]), v) if at_least else v


func _clear_down() -> void:
	disabled = false
	disable_cause = ""
	redeploying = false
	revive_progress = 0.0
	respawn_hold = 0.0
	redeploy_left = 0.0
	down_time = 0.0
	_respawn_left = -1.0
	_beamed = false


func repair_all() -> void:
	reset_state()
	_clear_down()
	invuln_left = 0.0


# --- Resupply verbs (the owner only, on its own mech: a supply depot's power core, MissionDepots) -------------------

## Every SURVIVING component (hp > 0) gets `fraction` of its missing HP back. Nothing while disabled. Returns the HP
## restored (emits healed per component).
func repair_fraction(fraction: float, src: String) -> float:
	if disabled or fraction <= 0.0:
		return 0.0
	var done := 0.0
	for c: String in hp:
		var cap := float(max_hp.get(c, 0.0))
		var v := float(hp[c])
		if v <= 0.0 or v >= cap:
			continue
		var add := (cap - v) * clampf(fraction, 0.0, 1.0)
		hp[c] = v + add
		done += add
		healed.emit(add, c, src)
	return done


## Every DESTROYED component (hp 0) is rebuilt at `fraction` of its max HP (a weapon on it works again: WeaponRack reads
## is_slot_destroyed). Nothing while disabled (a core does not revive a downed mech). Returns the rebuilt components.
func rebuild_destroyed(fraction: float, src: String) -> Array[String]:
	var out: Array[String] = []
	if disabled or fraction <= 0.0:
		return out
	for c: String in hp:
		var cap := float(max_hp.get(c, 0.0))
		if float(hp[c]) <= 0.0 and cap > 0.0:
			hp[c] = cap * clampf(fraction, 0.0, 1.0)
			out.append(c)
			healed.emit(float(hp[c]), c, src)
	return out


## Heat to zero and any heat shutdown cleared, on the bound mech's gauge (and this target's own).
func vent_heat() -> void:
	heat.reset()
	if mech != null and is_instance_valid(mech):
		mech.heat = 0.0
		mech.shutdown = false
