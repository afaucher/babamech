class_name MissionLiftDoor
extends Node3D
## The freight lift's doors on one deck: two leaves on a track in front of the baked door pane (CityBuildings._pillar: a
## 10 x 8 m door on the core's `front` face), sliding apart to show the lit car; five lamps over the door count down the
## last 5 s (amber, one goes out a second) and all turn green when the doors open. No collision: the core is solid.

const W := 5.0
const H := 8.0
var leaves: Array[Node3D] = []
var car: Node3D
var lamps: Array[Node3D] = []
var go: Node3D

func build(d: CityDistrict, bi: int) -> void:
	var layer := d.render_layer
	var b: Dictionary = d.plan.buildings[bi]
	var front := int(b["front"])
	var size: Vector2 = b["core"]["size"]
	var n2: Vector2 = CityPlan.SIDE_N[front]
	var n := Vector3(n2.x, 0.0, n2.y)
	var depth := size.x if front < 2 else size.y
	transform = d.core_frame(bi) * Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), n * depth * 0.5)
	var st := CityGeo.new()
	st.box(Transform3D.IDENTITY, Vector3(0, H + 0.2, 0.86), Vector3(W * 4.2, 0.4, 0.3), MissionProps.c("metal_dark"))
	for i in 5:
		st.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.4), Vector3(0.8, 0.8, 0.8), MissionProps.c("metal_dark"))
	add_child(MissionProps.mesh(st, "Track", layer))
	car = Node3D.new()
	car.name = "Car"
	var cg := CityGeo.new()
	cg.quad(Vector3(-W, 0, 0.6), Vector3(W, 0, 0.6), Vector3(W, H, 0.6), Vector3(-W, H, 0.6), MissionProps.c("m_recess"))
	car.add_child(MissionProps.mesh(cg, "Inside", layer))
	var lg := CityGeo.new()
	lg.box(Transform3D.IDENTITY, Vector3(0, 0.15, 0.63), Vector3(W * 2.0 - 0.4, 0.3, 0.04), MissionProps.c("strip"))
	lg.box(Transform3D.IDENTITY, Vector3(0, H - 0.4, 0.63), Vector3(W * 2.0 - 0.8, 0.3, 0.04), MissionProps.c("strip"))
	car.add_child(MissionProps.mesh(lg, "Light", layer, MissionProps.glow("strip", 3.0)))
	car.visible = false
	add_child(car)
	for k: float in [-1.0, 1.0]:
		var leaf := Node3D.new()
		leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
		var g := CityGeo.new()
		g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 0.86), Vector3(W, H, 0.28), MissionProps.c("m_leaf"))
		g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 1.01), Vector3(W - 0.6, 0.8, 0.04), MissionProps.c("marking_yellow"))
		g.box(Transform3D.IDENTITY, Vector3(-k * (W * 0.5 - 0.15), H * 0.5, 1.01), Vector3(0.3, H, 0.04), MissionProps.c("metal"))
		leaf.add_child(MissionProps.mesh(g, "Mesh", layer, null, true))
		leaf.position = Vector3(k * W * 0.5, 0, 0)
		add_child(leaf)
		leaves.append(leaf)
	for i in 5:
		var lamp := Node3D.new()
		lamp.name = "Lamp%d" % i
		var g := CityGeo.new()
		g.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_beacon"))
		lamp.add_child(MissionProps.mesh(g, "Lit", layer, MissionProps.glow("m_beacon", 4.0)))
		lamp.visible = false
		add_child(lamp)
		lamps.append(lamp)
	go = Node3D.new()
	go.name = "Go"
	var gg := CityGeo.new()
	for i in 5:
		gg.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_done"))
	go.add_child(MissionProps.mesh(gg, "Lit", layer, MissionProps.glow("m_done", 4.0)))
	go.visible = false
	add_child(go)

## state as MissionGateDoor.pose; `left` = seconds to open_at (the countdown).
func pose(state: String, u: float, left: float) -> void:
	var open := 0.0
	match state:
		"opening": open = smoothstep(0.0, 1.0, u)
		"open": open = 1.0
		"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
	for i in leaves.size():
		var k := -1.0 if i == 0 else 1.0
		leaves[i].position.x = k * W * (0.5 + open)
	car.visible = open > 0.0
	var counting := state == "warn" or state == "opening"     # left = s to open_at, when the doors start to move
	for i in lamps.size():
		lamps[i].visible = counting and left > float(i)
	go.visible = state == "open" or (state == "opening" and u > 0.5)

func blocks(_state: String) -> bool:
	return false

func world_point() -> Vector3:
	return global_transform * Vector3(0, H * 0.5, 2.0) if is_inside_tree() else transform * Vector3(0, H * 0.5, 2.0)
