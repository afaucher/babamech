class_name EnemyStatusBar
extends Node3D
## Minimal world-space HP bar over a damaged enemy: a crisp thin red bar on a dark backing, shown only once the unit is
## damaged, hidden on a dead unit. Nothing else floats over an enemy (no alert diamonds, LOCATE beacons, status tags or
## heat bar: R2.26). Overheat and stagger read from the unit itself (EnemyHeatLook, EnemyStaggerAnim).
## Purely cosmetic (all Net.LOCAL).

const BAR_W := 3.4
const BAR_H := 0.28

var _bar_bg: MeshInstance3D
var _bar_hp: MeshInstance3D


func net_fields() -> Dictionary:
	return {"_bar_bg": Net.LOCAL, "_bar_hp": Net.LOCAL}


func _init() -> void:
	_bar_bg = _quad_mi(Color(0.06, 0.07, 0.09))
	add_child(_bar_bg)
	_bar_hp = _quad_mi(Color(0.95, 0.16, 0.18))
	add_child(_bar_hp)
	visible = false


static func _quad_mi(col: Color) -> MeshInstance3D:
	var k := MeshKit.new()
	k.glow = true
	k.shade = 0.0
	k.quad(Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0), col, Vector3(0, 0, -1))
	return CombatMeshes.instance(k.commit(LowPolyMaterials.materials()))


func refresh(hp_ratio: float, dead: bool) -> void:
	var show_bar := not dead and hp_ratio < 0.999
	visible = show_bar
	if not show_bar or not is_inside_tree():
		return
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	var dist_scale := 1.0
	if cam != null:
		global_basis = cam.global_basis
		var d := cam.global_position.distance_to(global_position)
		dist_scale = clampf(d / 45.0, 0.85, 2.4)
	var w := BAR_W * dist_scale
	var h := BAR_H * dist_scale
	_bar_bg.position = Vector3(0.0, 0.0, -0.02)
	_bar_bg.scale = Vector3(w + 0.14 * dist_scale, h + 0.12 * dist_scale, 1.0)
	var fill := clampf(hp_ratio, 0.0, 1.0)
	_bar_hp.visible = fill > 0.001
	_bar_hp.position = Vector3(-w * 0.5 * (1.0 - fill), 0.0, 0.0)
	_bar_hp.scale = Vector3(maxf(w * fill, 0.001), h, 1.0)
