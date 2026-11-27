class_name MissionFlagMast
extends Node3D
## A 16 m mast (0.55 m pole) on a stepped base, a yard at the top, and two banners about 5 x 3.2 m that differ in SHAPE as
## well as colour: the alien one dark, torn and angular (a ragged swallowtail) with a harsh dark-red emblem block and a
## glowing slit; ours a clean rectangle in the crew's safety orange with a bright cream stripe. pose(raised, from, u)
## plays the swap: the banner up comes down over the first half, the other goes up over the second. Slim collision: the
## pole (r 0.6) and the base.

const POLE := 16.0
const TOP := 15.4        ## banner top when raised (under the yard)
const LOW := 5.2         ## banner top when lowered
const W := 5.0
const H := 3.2
var alien: Node3D
var ours: Node3D
var body: StaticBody3D

func build(d: CityDistrict, xf: Transform3D) -> void:
	var layer := d.render_layer
	transform = xf
	var st := CityGeo.new()
	var I := Transform3D.IDENTITY
	st.box(I, Vector3(0, 0.2, 0), Vector3(3.6, 0.8, 3.6), MissionProps.c("concrete_dark"))
	st.box(I, Vector3(0, 0.85, 0), Vector3(2.6, 0.5, 2.6), MissionProps.c("concrete"))
	st.box(I, Vector3(0, 1.35, 0), Vector3(1.6, 0.5, 1.6), MissionProps.c("concrete_dark"))
	st.prism(I, Vector3(0, 1.6, 0), 0.55, POLE - 1.6, 8, MissionProps.c("metal"), 0.4)
	for y: float in [3.0, 3.8]:
		st.prism(I, Vector3(0, y, 0), 0.62, 0.4, 8, MissionProps.c("marking_yellow"))
	st.box(I, Vector3(W * 0.5 + 0.3, TOP + 0.2, 0), Vector3(W + 1.2, 0.35, 0.35), MissionProps.c("metal_dark"))
	st.prism(I, Vector3(0, POLE, 0), 0.55, 0.7, 8, MissionProps.c("marking_yellow"), 0.0)
	add_child(MissionProps.mesh(st, "Mast", layer, null, true))
	alien = Node3D.new()
	alien.name = "Alien"
	var ag := CityGeo.new()
	var torn: Array[Vector2] = [Vector2(0.4, 0), Vector2(0.4, -2.6), Vector2(1.2, -3.4), Vector2(1.8, -2.6), Vector2(2.9, -1.9),
			Vector2(3.6, -2.9), Vector2(4.5, -3.5), Vector2(4.9, -2.4), Vector2(5.4, -2.7), Vector2(5.0, -1.5), Vector2(5.5, -0.9),
			Vector2(5.0, 0)]
	MissionProps.flat_poly(ag, torn, 0.05, MissionProps.c("m_alien"))
	ag.box(Transform3D(Basis(Vector3.BACK, 0.18), Vector3(2.9, -1.15, 0)), Vector3.ZERO, Vector3(1.7, 1.3, 0.2), MissionProps.c("m_alien_mark"))
	for k: float in [-1.0, 1.0]:
		ag.box(Transform3D(Basis(Vector3.BACK, k * 0.75), Vector3(2.9 + k * 0.95, -2.0, 0)), Vector3.ZERO, Vector3(1.0, 0.28, 0.16), MissionProps.c("m_alien_mark"))
	alien.add_child(MissionProps.mesh(ag, "Banner", layer, null, true))
	var eye := CityGeo.new()
	eye.box(I, Vector3(2.9, -1.15, 0), Vector3(1.1, 0.26, 0.26), MissionProps.c("m_hostile"))
	alien.add_child(MissionProps.mesh(eye, "Eye", layer, MissionProps.glow("m_hostile", 4.0)))
	add_child(alien)
	ours = Node3D.new()
	ours.name = "Ours"
	var og := CityGeo.new()
	og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, H, 0.1), MissionProps.c("m_ours"))
	og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, 0.7, 0.16), MissionProps.c("m_ours_mark"))
	og.box(I, Vector3(0.4 + W * 0.5, -0.12, 0), Vector3(W, 0.24, 0.14), MissionProps.c("m_ours_mark"))
	ours.add_child(MissionProps.mesh(og, "Banner", layer, null, true))
	add_child(ours)
	body = MissionProps.body_like(d, "FlagBody")
	add_child(body)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.6
	cyl.height = POLE
	cs.shape = cyl
	cs.position = Vector3(0, POLE * 0.5, 0)
	body.add_child(cs)
	MissionProps.box_shape(body, I, Vector3(0, 0.6, 0), Vector3(3.6, 1.6, 3.6))
	pose(false, false, 1.0)

## raised: ours is (going) up; from: what was up before the last swap; u 0..1 through the swap.
func pose(raised: bool, from: bool, u: float) -> void:
	var up_node := ours if raised else alien
	var down_node := alien if raised else ours
	if raised == from or u >= 1.0:
		up_node.visible = true
		up_node.position.y = TOP
		down_node.visible = false
		return
	if u < 0.5:
		down_node.visible = true
		down_node.position.y = lerpf(TOP, LOW, u * 2.0)
		up_node.visible = false
	else:
		down_node.visible = false
		up_node.visible = true
		up_node.position.y = lerpf(LOW, TOP, u * 2.0 - 1.0)

func world_point() -> Vector3:
	return global_transform * Vector3(0, TOP, 0) if is_inside_tree() else transform * Vector3(0, TOP, 0)
