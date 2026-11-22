class_name ChargeGlow
extends Node3D
## The charge telegraph of a charging weapon (weapons.md §3.1: the laser's 0.15 s, later the railgun's 1 s): a teal
## faceted glow at the muzzle that grows with the mount's charge (WeaponMount.charge / stats.charge): a teal ball
## with a pale counter-turning ball inside whose points poke through its facets, unshaded flat colours. Cosmetic and
## local: whoever draws a mount (the weapon_range lab, WeaponRack in the test drive) owns one per charging weapon and
## calls `show_charge` every step.
##
##   var g := ChargeGlow.new(); add_child(g)
##   g.show_charge(muzzle_position, ChargeGlow.fraction(mount), dt)

const R_MIN := 0.12               ## m: shell radius as the charge starts ...
const R_MAX := 0.6                ## ... and at full charge
const SPIN := 7.0                 ## rad/s

var frac := 0.0
var _t := 0.0
var _core: MeshInstance3D
var _shell: MeshInstance3D


func net_fields() -> Dictionary:
	return {"frac": Net.LOCAL, "_t": Net.LOCAL, "_core": Net.LOCAL, "_shell": Net.LOCAL}


func _init() -> void:
	top_level = true
	_shell = CombatMeshes.instance(CombatMeshes.ico(MechMeshes.TEAL, true))
	add_child(_shell)
	_core = CombatMeshes.instance(CombatMeshes.ico(MechMeshes.TEAL.lerp(MechMeshes.WHITE, 0.6), true))
	add_child(_core)
	visible = false


## Charge share 0..1 of a mount (0 for a weapon that doesn't charge).
static func fraction(m: WeaponMount) -> float:
	if m == null:
		return 0.0
	var need := float(m.stats.get("charge", 0.0))
	var f := clampf(m.charge / need, 0.0, 1.0) if need > 0.0 else 0.0
	var steps := int(m.stats.get("charge_steps", 0))    # stats.charge_steps > 0: grows in steps (the railgun's coils light one by one)
	if steps > 0 and f > 0.0:
		f = maxf(floorf(f * float(steps)), 1.0) / float(steps)
	return f


func show_charge(at: Vector3, f: float, dt: float) -> void:
	frac = f
	_t += dt
	visible = f > 0.0
	if not visible or not is_inside_tree():
		return
	global_position = at
	var r := lerpf(R_MIN, R_MAX, f)
	var flick := 1.0 + 0.12 * sin(_t * 61.0)
	_shell.transform = Transform3D(Basis(Vector3(0.3, 1, 0.2).normalized(), _t * SPIN) * Basis.from_scale(Vector3.ONE * r * flick), Vector3.ZERO)
	_core.transform = Transform3D(Basis(Vector3(1, 0.2, 0.4).normalized(), -_t * SPIN * 1.3) * Basis.from_scale(Vector3.ONE * r * 0.92), Vector3.ZERO)
