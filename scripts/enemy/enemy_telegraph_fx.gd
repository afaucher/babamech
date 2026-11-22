class_name EnemyTelegraphFx
extends Node3D
## Diegetic enemy attack telegraph & alert relay FX (docs/design/enemies.md §2, §4):
##   - Crimson-to-white-amber spinning faceted muzzle charge orb (scales up over telegraph progress 0..1).
##   - Thin 3-sided crimson targeting laser from muzzle to aim point (thickens & brightens when aim locks).
##   - Expanding crimson alert ring when a spotter relays a sighting to its squad.
## Purely cosmetic (all Net.LOCAL).

const SPIN := 9.0
const RELAY_LIFE := 0.55

var _t := 0.0
var _shell: MeshInstance3D
var _core: MeshInstance3D
var _beam: MeshInstance3D
var _relay_ring: MeshInstance3D
var _relay_age := -1.0
var _relay_pos := Vector3.ZERO
var _relay_up := Vector3.UP


func net_fields() -> Dictionary:
	return {"_t": Net.LOCAL, "_shell": Net.LOCAL, "_core": Net.LOCAL, "_beam": Net.LOCAL,
		"_relay_ring": Net.LOCAL, "_relay_age": Net.LOCAL, "_relay_pos": Net.LOCAL, "_relay_up": Net.LOCAL}


func _init() -> void:
	top_level = true
	_shell = CombatMeshes.instance(CombatMeshes.ico(EnemyMeshes.OPTIC_GLOW, true))
	add_child(_shell)
	_core = CombatMeshes.instance(CombatMeshes.ico(Color(1.0, 0.88, 0.48), true))
	add_child(_core)
	_beam = CombatMeshes.instance(CombatMeshes.prism3(EnemyMeshes.OPTIC_GLOW))
	add_child(_beam)
	_relay_ring = CombatMeshes.instance(CombatMeshes.ring(EnemyMeshes.OPTIC_GLOW, 0.86, 18))
	add_child(_relay_ring)
	hide_telegraph()
	_relay_ring.visible = false


func hide_telegraph() -> void:
	_shell.visible = false
	_core.visible = false
	_beam.visible = false


func trigger_relay_ring(at: Vector3, up: Vector3 = Vector3.UP) -> void:
	_relay_age = 0.0
	_relay_pos = at
	_relay_up = up.normalized() if up.length_squared() > 1e-6 else Vector3.UP


## Update telegraph charge orb + aim beam. `frac` 0..1 (<= 0 hides). `max_radius` scales by weapon class.
func show_telegraph(muzzle: Vector3, aim: Vector3, frac: float, locked: bool, max_radius: float,
		show_beam: bool, dt: float) -> void:
	_t += dt
	_tick_relay(dt)
	if frac <= 0.0 or not is_inside_tree():
		hide_telegraph()
		return
	var f := clampf(frac, 0.0, 1.0)
	var r := lerpf(max_radius * 0.22, max_radius, f) * (1.0 + 0.16 * sin(_t * 68.0))
	_shell.visible = true
	_core.visible = true
	_shell.global_transform = Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), _t * SPIN) * Basis.from_scale(Vector3.ONE * r), muzzle)
	var core_r := r * lerpf(0.55, 0.96, f)
	_core.global_transform = Transform3D(Basis(Vector3(1.0, 0.2, 0.4).normalized(), -_t * SPIN * 1.4) * Basis.from_scale(Vector3.ONE * core_r), muzzle)
	# Muzzle charge orb + audio telegraph warn the player; no long targeting laser cluttering the street.
	_beam.visible = false


func tick_only(dt: float) -> void:
	_t += dt
	_tick_relay(dt)


func _tick_relay(dt: float) -> void:
	if _relay_age < 0.0 or not is_inside_tree():
		_relay_ring.visible = false
		return
	_relay_age += dt
	if _relay_age >= RELAY_LIFE:
		_relay_age = -1.0
		_relay_ring.visible = false
		return
	var u := _relay_age / RELAY_LIFE
	var rad := lerpf(1.2, 9.5, u)
	var fwd := Vector3.FORWARD
	if absf(_relay_up.dot(fwd)) > 0.95:
		fwd = Vector3.RIGHT
	var x := fwd.cross(_relay_up).normalized()
	var b := Basis(x, _relay_up, x.cross(_relay_up).normalized())
	_relay_ring.visible = true
	_relay_ring.global_transform = Transform3D(b * Basis.from_scale(Vector3.ONE * rad), _relay_pos)
