class_name MissionRelayAsset
extends Node3D
## A relay about 6 m to the dish's rim on a plinth: a cabinet with a bold blinking cyan band, a mast, a big dish and a tall
## thin antenna (8.6 m, glowing tip) that marks it above parked props. look(level): 0 intact, 1 damaged (dish knocked
## askew, antenna bent, sparks and smoke), 2 wreck (cabinet slumped and scorched, mast snapped with its top on the
## ground, dish fallen on its rim, antenna down, nothing glows). `body` is the damageable target (MissionWorld puts it in
## group "mission_asset" with meta objective_id); the look never changes it.

var intact: Node3D
var dish: Node3D
var antenna: Node3D
var band_on: MeshInstance3D
var band_off: MeshInstance3D
var wreck: MeshInstance3D
var sparks: CPUParticles3D
var smoke: CPUParticles3D
var body: StaticBody3D
var level := 0

func build(d: CityDistrict, xf: Transform3D) -> void:
	var layer := d.render_layer
	transform = xf
	var I := Transform3D.IDENTITY
	var st := CityGeo.new()
	st.box(I, Vector3(0, 0.4, 0), Vector3(4.2, 1.2, 4.2), MissionProps.c("concrete_dark"))
	for k: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		st.box(I, Vector3(k.x * 1.8, 1.15, k.y * 1.8), Vector3(0.6, 0.3, 0.6), MissionProps.c("marking_yellow"))
	add_child(MissionProps.mesh(st, "Plinth", layer, null, true))
	intact = Node3D.new()
	intact.name = "Intact"
	var ig := CityGeo.new()
	ig.box(I, Vector3(0, 2.6, 0), Vector3(2.8, 2.8, 2.8), MissionProps.c("m_relay"))
	ig.box(I, Vector3(0, 4.1, 0), Vector3(3.2, 0.3, 3.2), MissionProps.c("metal_dark"))
	ig.prism(I, Vector3(0, 4.2, 0), 0.32, 1.4, 6, MissionProps.c("metal"))
	intact.add_child(MissionProps.mesh(ig, "Body", layer, null, true))
	var bg := CityGeo.new()
	bg.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay_band"))
	band_on = MissionProps.mesh(bg, "BandOn", layer, MissionProps.glow("m_relay_band", 4.5))
	intact.add_child(band_on)
	var bo := CityGeo.new()
	bo.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay").darkened(0.35))
	band_off = MissionProps.mesh(bo, "BandOff", layer)
	band_off.visible = false
	intact.add_child(band_off)
	dish = Node3D.new()
	dish.name = "Dish"
	dish.position = Vector3(0, 5.5, 0)
	var dg := CityGeo.new()
	var tilt := Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3.ZERO)
	dg.prism(tilt, Vector3.ZERO, 0.45, 1.1, 10, MissionProps.c("cream_light"), 2.3, null, MissionProps.c("metal"))
	dg.prism(tilt, Vector3(0, 1.1, 0), 0.1, 1.2, 4, MissionProps.c("metal_dark"))
	dish.add_child(MissionProps.mesh(dg, "Mesh", layer, null, true))
	intact.add_child(dish)
	antenna = Node3D.new()
	antenna.name = "Antenna"
	antenna.position = Vector3(1.1, 4.25, -1.1)
	var ag := CityGeo.new()
	ag.box(I, Vector3(0, 2.15, 0), Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
	for y: float in [1.2, 2.4, 3.4]:
		ag.box(I, Vector3(0, y, 0), Vector3(0.7, 0.08, 0.08), MissionProps.c("metal_dark"))
	antenna.add_child(MissionProps.mesh(ag, "Mast", layer, null, true))
	var tip := CityGeo.new()
	tip.box(I, Vector3(0, 4.4, 0), Vector3(0.32, 0.32, 0.32), MissionProps.c("m_ours"))
	antenna.add_child(MissionProps.mesh(tip, "Tip", layer, MissionProps.glow("m_ours", 4.0)))
	intact.add_child(antenna)
	add_child(intact)
	# The wreck: a slumped, scorched cabinet; the mast's stump and its snapped top on the ground; the dish fallen on its
	# rim; the antenna lying across the plinth.
	var wg := CityGeo.new()
	wg.box(Transform3D(Basis(Vector3(1, 0, 0.4).normalized(), 0.3), Vector3(0.1, 1.9, 0.0)), Vector3.ZERO, Vector3(2.8, 1.6, 2.8), MissionProps.c("m_scorch"))
	wg.box(Transform3D(Basis(Vector3.FORWARD, 0.25), Vector3(0.2, 2.8, 0.0)), Vector3.ZERO, Vector3(3.0, 0.3, 3.0), MissionProps.c("metal_dark"))
	wg.prism(Transform3D(Basis(Vector3.FORWARD, 0.2), Vector3(0.1, 2.9, 0)), Vector3.ZERO, 0.32, 0.8, 6, MissionProps.c("metal_dark"))
	wg.prism(Transform3D(Basis(Vector3.FORWARD, 1.45), Vector3(3.6, 0.35, 0.6)), Vector3.ZERO, 0.3, 2.2, 6, MissionProps.c("metal"))
	wg.prism(Transform3D(Basis(Vector3.RIGHT, 1.5) * Basis(Vector3.UP, 0.3), Vector3(-2.6, 1.6, 2.2)), Vector3.ZERO, 0.45, 1.1, 10,
			MissionProps.c("m_scorch"), 2.3, null, MissionProps.c("metal_dark"))
	wg.box(Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, 1.5), Vector3(-0.4, 1.25, -2.4)), Vector3.ZERO, Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
	wreck = MissionProps.mesh(wg, "Wreck", layer, null, true)
	wreck.visible = false
	add_child(wreck)
	body = MissionProps.body_like(d, "AssetBody")
	add_child(body)
	MissionProps.box_shape(body, I, Vector3(0, 2.5, 0), Vector3(4.2, 5.4, 4.2))

## Sparks and smoke while damaged (CPUParticles3D, made on first need; none at CityQuality.LOW).
func _fx(on: bool, layer: int) -> void:
	if on and sparks == null:
		sparks = CPUParticles3D.new()
		sparks.name = "Sparks"
		sparks.amount = 14
		sparks.lifetime = 0.6
		sparks.explosiveness = 0.6
		sparks.direction = Vector3.UP
		sparks.spread = 70.0
		sparks.initial_velocity_min = 3.0
		sparks.initial_velocity_max = 6.0
		sparks.gravity = Vector3(0, -12, 0)
		sparks.scale_amount_min = 0.08
		sparks.scale_amount_max = 0.14
		var qm := BoxMesh.new()
		qm.size = Vector3.ONE
		qm.material = MissionProps.glow("m_beacon", 6.0)
		sparks.mesh = qm
		sparks.layers = layer
		sparks.position = Vector3(0, 4.6, 0)
		add_child(sparks)
		smoke = CPUParticles3D.new()
		smoke.name = "Smoke"
		smoke.amount = 10
		smoke.lifetime = 2.6
		smoke.direction = Vector3.UP
		smoke.spread = 15.0
		smoke.initial_velocity_min = 1.2
		smoke.initial_velocity_max = 2.0
		smoke.gravity = Vector3(0, 0.4, 0)
		smoke.scale_amount_min = 0.6
		smoke.scale_amount_max = 1.2
		var sm := BoxMesh.new()
		sm.size = Vector3.ONE
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.18, 0.17, 0.17)
		mat.roughness = 1.0
		sm.material = mat
		smoke.mesh = sm
		smoke.layers = layer
		smoke.position = Vector3(0, 4.4, 0)
		add_child(smoke)
	if sparks != null:
		sparks.emitting = on
		sparks.visible = on
		smoke.emitting = on
		smoke.visible = on

## lv 0 intact, 1 damaged, 2 wreck; fx = particles allowed (quality above LOW).
func look(lv: int, fx: bool, layer: int) -> void:
	level = lv
	intact.visible = lv < 2
	wreck.visible = lv == 2
	dish.position = Vector3(0.6, 4.6, 0.4) if lv == 1 else Vector3(0, 5.5, 0)
	dish.rotation = Vector3(0.9, 0.4, 0.6) if lv == 1 else Vector3.ZERO
	antenna.rotation = Vector3(0.0, 0.0, 0.55) if lv == 1 else Vector3.ZERO
	_fx(lv == 1 and fx, layer)

func blink(on: bool) -> void:
	band_on.visible = on and level == 0
	band_off.visible = not band_on.visible

func world_point() -> Vector3:
	return global_transform * Vector3(0, 3.0, 0) if is_inside_tree() else transform * Vector3(0, 3.0, 0)
