class_name TargetDummy
extends CombatTarget
## A range dummy (weapons.md §2: 1000 HP, heat cap 100, cooling 6, mass class selectable): a low-poly post robot with
## one "body" component (two hit spheres) and a readout (HP bar, heat bar, STAGGER / SHUTDOWN) that stays legible at
## 200 m. Host-owned (owner_peer 0). Resets itself a moment after it is destroyed.

const HP := 1000.0
const HEIGHT := 3.4
const RESET_AFTER := 1.5      ## s after destruction
const BAR := 20               ## characters in a readout bar

var home := Vector3.ZERO
var _label: Label3D
var _dead_for := 0.0
var _burn: BurnFx             ## flames stuck on it while above half heat (cosmetic)


func _init() -> void:
	super._init()     # an _init override doesn't run the parent's by itself
	set_max_hp({"body": HP})
	heat = Heat.new(100.0, 6.0)
	add_hit_sphere("body", Vector3(0, 1.9, 0), 1.0)
	add_hit_sphere("body", Vector3(0, 3.0, 0), 0.55)
	probe_height = 1.9
	body_radius = 0.9


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"home": Net.SPAWN, "_label": Net.LOCAL, "_dead_for": Net.PRIVATE, "_burn": Net.LOCAL})
	return f


func _ready() -> void:
	home = global_position
	ground_y = home.dot(up)       # the ground plane through home, along `up` (world +Y unless set before _ready)
	var k := MeshKit.new()
	k.box(Vector3(0.5, 1.0, 0.5), LowPolyPalette.DARK, Vector3(0, 0.5, 0))
	k.box(Vector3(1.0, 0.18, 1.0), LowPolyPalette.GUN, Vector3(0, 0.09, 0))
	k.ico(Vector3(0, 1.9, 0), Vector3(0.95, 0.9, 0.8), LowPolyPalette.WHITE)
	k.box(Vector3(1.5, 0.3, 0.5), LowPolyPalette.ORANGE, Vector3(0, 2.2, 0))
	k.ico(Vector3(0, 3.0, 0), Vector3(0.5, 0.45, 0.5), LowPolyPalette.ORANGE)
	k.box(Vector3(0.5, 0.12, 0.06), LowPolyPalette.BLACK, Vector3(0, 3.05, 0.47))   # the visor faces the firing line (+Z)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit(LowPolyMaterials.materials())
	add_child(mi)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0007
	_label.font_size = 26
	_label.outline_size = 8
	_label.no_depth_test = true
	_label.position = Vector3(0, HEIGHT + 0.6, 0)
	add_child(_label)
	_refresh()


func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	super.tick(dt, space)
	if destroyed():
		_dead_for += dt
		if _dead_for >= RESET_AFTER:
			reset_dummy()
	if _burn == null and heat.fraction() > BurnFx.ON_AT and is_inside_tree():
		_burn = BurnFx.attach(self)
	if _burn != null:
		_burn.step(dt)
	_refresh()


## Full HP, cold, back home.
func reset_dummy() -> void:
	reset_state()
	_dead_for = 0.0
	if is_inside_tree():
		global_position = home
	_refresh()


func readout() -> String:
	var hpf := total_hp() / total_max_hp()
	var state := "DESTROYED" if destroyed() else "SHUTDOWN" if heat.shutdown else "STAGGER" if knock.staggered() else mass_class
	return "%s\nHP   %s %4d\nHEAT %s %3d" % [state, _bar(hpf), int(round(total_hp())), _bar(heat.fraction()), int(round(heat.value))]


static func _bar(f: float) -> String:
	var n := clampi(int(round(f * BAR)), 0, BAR)
	return "[" + "#".repeat(n) + ".".repeat(BAR - n) + "]"


func _refresh() -> void:
	if _label != null:
		_label.text = readout()
		_label.modulate = Color(1, 0.4, 0.3) if destroyed() or heat.shutdown else Color(1, 0.9, 0.5) if knock.staggered() else Color.WHITE
