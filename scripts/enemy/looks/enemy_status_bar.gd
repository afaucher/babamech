class_name EnemyStatusBar
extends Node3D
## Minimal world-space HP/heat bar for damaged or overheated enemies (no floating alert diamonds or LOCATE beacons).
##   - Crisp thin red HP bar + thin amber heat sliver ONLY when actually damaged, overheated, or staggered.
##   - Compact 1-word status tag ONLY when STAGGER or OVERHEAT (never LOCATE or alerted diamonds).
## Purely cosmetic (all Net.LOCAL).

const BAR_W := 3.4
const BAR_H := 0.28
const HEAT_H := 0.12

var _bar_bg: MeshInstance3D
var _bar_hp: MeshInstance3D
var _bar_heat: MeshInstance3D
var _tag: Label3D
var _t := 0.0


func net_fields() -> Dictionary:
	return {"_bar_bg": Net.LOCAL, "_bar_hp": Net.LOCAL, "_bar_heat": Net.LOCAL, "_tag": Net.LOCAL, "_t": Net.LOCAL}


func _init() -> void:
	_bar_bg = _quad_mi(Color(0.06, 0.07, 0.09))
	add_child(_bar_bg)
	_bar_hp = _quad_mi(Color(0.95, 0.16, 0.18))
	add_child(_bar_hp)
	_bar_heat = _quad_mi(Color(1.0, 0.56, 0.14))
	add_child(_bar_heat)
	_tag = Label3D.new()
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.fixed_size = true
	_tag.pixel_size = 0.00055
	_tag.font_size = 24
	_tag.outline_size = 6
	_tag.no_depth_test = true
	_tag.position = Vector3(0.0, 0.75, 0.0)
	_tag.visible = false
	add_child(_tag)
	visible = false


static func _quad_mi(col: Color) -> MeshInstance3D:
	var k := MeshKit.new()
	k.glow = true
	k.shade = 0.0
	k.quad(Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0), col, Vector3(0, 0, -1))
	return CombatMeshes.instance(k.commit(LowPolyMaterials.materials()))


func refresh(hp_ratio: float, heat_ratio: float, _alerted: bool, _telegraphing: bool, status_text: String,
		dead: bool, dt: float, _revealed: bool = false) -> void:
	_t += dt
	var damaged := hp_ratio < 0.999
	var show_heat := heat_ratio > 0.15
	var show_any := not dead and (damaged or show_heat or status_text != "")
	visible = show_any
	if not show_any or not is_inside_tree():
		return
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	var dist_scale := 1.0
	if cam != null:
		global_basis = cam.global_basis
		var d := cam.global_position.distance_to(global_position)
		dist_scale = clampf(d / 45.0, 0.85, 2.4)
	var show_bar := damaged or status_text != ""
	var w := BAR_W * dist_scale
	var h := BAR_H * dist_scale
	_bar_bg.visible = show_bar
	_bar_hp.visible = show_bar and hp_ratio > 0.001
	if show_bar:
		_bar_bg.position = Vector3(0.0, 0.0, -0.02)
		_bar_bg.scale = Vector3(w + 0.14 * dist_scale, h + 0.12 * dist_scale, 1.0)
		var fill := clampf(hp_ratio, 0.0, 1.0)
		_bar_hp.position = Vector3(-w * 0.5 * (1.0 - fill), 0.0, 0.0)
		_bar_hp.scale = Vector3(maxf(w * fill, 0.001), h, 1.0)
	_bar_heat.visible = show_heat
	if show_heat:
		var hf := clampf(heat_ratio, 0.0, 1.0)
		var hh := HEAT_H * dist_scale
		_bar_heat.position = Vector3(-w * 0.5 * (1.0 - hf), -(h + hh) * 0.65, 0.0)
		_bar_heat.scale = Vector3(maxf(w * hf, 0.001), hh, 1.0)
	_tag.visible = status_text != ""
	if _tag.visible:
		_tag.text = status_text
		_tag.position = Vector3(0.0, h * 1.45 + 0.45 * dist_scale, 0.0)
		_tag.modulate = Color(1.0, 0.45, 0.25) if status_text == "OVERHEAT" else Color(1.0, 0.88, 0.35)
