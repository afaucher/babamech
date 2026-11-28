class_name MissionLiftDoor
extends Node3D
## The freight lift on one deck in a mission (docs/design/city-ramps-and-stack.md section 9 "Lift cars", backlog R2.22):
## the car standing at this deck behind the doorway CityBuildings._lift_doorway draws in the pillar core's `front` face
## (CityDims.LIFT_DOOR_W x CityBuildings.LIFT_DOOR_H), and the two leaves that slide apart into the core's front wall. A
## real freight lift (the station is not built for the game): no countdown, no lamps; the call panel on the jamb is the
## district's. The doors' motion is the tell. Units can be staged in the car like a gate's staging bay (MissionWorld's
## source_bay / bay_contains / bay_slots answer for a lift).
## Frame: origin on the door plane (the core's face) at floor mid-door, X along the face, Y up, +Z out of the core (the
## gate bays' convention, MissionProps.gate_frame).
## The car: a room CAR_HALF x 2 wide, from the front wall (CityBuildings.LIFT_WALL) back to car_back, CAR_H high, lit by warm
## light bars (always on: a lift car is lit), its floor on the deck's facets. Built only where the core holds it
## (has_car; every lift of section seeds 1..200 does: cores 25.1 .. 25.7 m along the face x 28 m deep).
## Collision: MissionWorld disables the district's solid core box and this body replaces it with walls round the car (the car
## is a hollow in the core); `door_shape` fills the doorway while shut / warn / sealed (blocks(): never while the leaves
## move, as MissionGateDoor), so a shut door stops units, sight and fire (CombatWorld's physics rays).
## The baked shut doors in the district mesh are hidden while this door exists (hide_fill; MissionWorld restores them).

const W := CityDims.LIFT_DOOR_W            ## the doorway's clear width (two leaves of W / 2)
const H := CityBuildings.LIFT_DOOR_H       ## its clear height
const WALL := CityBuildings.LIFT_WALL      ## the core's front wall at the doorway (the leaves run in it)
const CAR_HALF := 8.0        ## m: half the car's interior width (14 m usable after MARGIN; two Bulwark capsules, 7.2 m, abreast)
const CAR_BACK := 18.5       ## m from the door plane to the car's back wall (inner face)
const CAR_H := 10.0          ## m: the car's roof underside above the frame's floor
const MARGIN := 1.0          ## m kept clear along the car's side walls (source_bay's usable width)
const USE_FROM := 1.5        ## m behind the door plane where the usable floor starts (past the front wall)
const BACK_MARGIN := 1.0     ## m kept clear of the back wall (usable depth ends car_back - BACK_MARGIN: 16 m)
const LIGHT_DROP := 0.25     ## m the light bars hang below the roof: the lowest thing in the car
const MIN_CAR := Vector2(5.5, 12.0)   ## the smallest car built (half width, back): below it the lift keeps its solid core
const SIDE_MIN := 1.0        ## m of core kept beside / behind the car (and the open leaves' pockets beside the doorway)

var leaves: Array[Node3D] = []
var car: Node3D
var body: StaticBody3D
var door_shape: CollisionShape3D
var has_car := false         ## the core holds a car (MIN_CAR): source_bay answers ok
var car_half := CAR_HALF     ## as built (min of CAR_HALF and what the core allows)
var car_back := CAR_BACK
var core_half := 0.0         ## half the core's width along the face
var core_depth := 0.0        ## the core's depth from the face
var core_top := 0.0          ## the core box's top above the frame's floor (the district's: ceiling + 1)
var floor_rise := 0.0        ## the most the faceted floor rises above the frame's y = 0 inside the car
var arc_mid := Vector2.ZERO  ## the frame's origin in the deck's arc coordinates (x, s)
var arc_x := Vector2.RIGHT   ## the frame's +X in arc coordinates
var arc_in := Vector2.RIGHT  ## the frame's +Z (out of the car into the map) in arc coordinates
var bi := -1                 ## the pillar's building index on its district


## The deck arc point (x, s) `lx` m along the face from mid-door and `depth` m behind the door plane (negative: in the map).
func arc(lx: float, depth: float) -> Vector2:
	return arc_mid + arc_x * lx - arc_in * depth


## The door's frame on district d for the lift pillar bi (district-local): on the core's front face, as built.
static func frame_of(d: CityDistrict, building: int) -> Transform3D:
	var b: Dictionary = d.plan.buildings[building]
	var front := int(b["front"])
	var size: Vector2 = b["core"]["size"]
	var n2: Vector2 = CityPlan.SIDE_N[front]
	var n := Vector3(n2.x, 0.0, n2.y)
	var depth := size.x if front < 2 else size.y
	return d.core_frame(building) * Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), n * depth * 0.5)


## The car lift pillar `building` of plan can hold: Vector2(half width, back) clamped to CAR_HALF / CAR_BACK, or
## Vector2.ZERO below MIN_CAR (plan data only).
static func car_fit(plan: CityPlan, building: int) -> Vector2:
	var b: Dictionary = plan.buildings[building]
	var front := int(b["front"])
	var size: Vector2 = b["core"]["size"]
	var half := (size.y if front < 2 else size.x) * 0.5
	var depth := size.x if front < 2 else size.y
	var fit := Vector2(minf(CAR_HALF, half - SIDE_MIN), minf(CAR_BACK, depth - SIDE_MIN))
	if fit.x < MIN_CAR.x or fit.y < MIN_CAR.y or half < W + SIDE_MIN * 0.3:
		return Vector2.ZERO
	return fit


func build(d: CityDistrict, building: int) -> void:
	bi = building
	var layer := d.render_layer
	var b: Dictionary = d.plan.buildings[bi]
	var front := int(b["front"])
	var size: Vector2 = b["core"]["size"]
	core_half = (size.y if front < 2 else size.x) * 0.5
	core_depth = size.x if front < 2 else size.y
	core_top = d.plan.p("ceiling") + 1.0
	transform = frame_of(d, bi)
	arc_in = _arc_dir(d, Vector3(0, 0, 1))
	arc_x = _arc_dir(d, Vector3(1, 0, 0))
	var a0 := d.ring.world_to_arc(transform.origin)
	arc_mid = Vector2(a0.x, a0.y)
	var fit := car_fit(d.plan, bi)
	has_car = fit != Vector2.ZERO
	if has_car:
		car_half = fit.x
		car_back = fit.y
	var geo_d := CityGeo.new(d.ring)
	var inv := transform.affine_inverse()
	floor_rise = 0.0
	if has_car:
		for p: Vector2 in [Vector2(-car_half, 0.0), Vector2(car_half, 0.0), Vector2(-car_half, car_back), Vector2(car_half, car_back), Vector2(0.0, car_back)]:
			var a := arc(p.x, p.y)
			floor_rise = maxf(floor_rise, (inv * geo_d.g_point(a.x, a.y, CityPlan.CURB_H)).y)
		_build_car(d, layer, inv)
	for k: float in ([-1.0, 1.0] if has_car else []):      # no car: the district's baked doors stay (nothing opens)
		var leaf := Node3D.new()
		leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
		var g := CityGeo.new()
		g.tag("mission.lift_leaf")
		CityBuildings.lift_leaf(g, Transform3D.IDENTITY, k, false)
		leaf.add_child(MissionProps.mesh(g, "Mesh", layer, null, true))
		leaf.position = Vector3(k * W * 0.25, 0, -CityBuildings.LIFT_FILL)
		add_child(leaf)
		leaves.append(leaf)
	if has_car:
		_build_collision(d)


## Frame direction `dir` (unit, horizontal) as an arc direction (x, s) on district d, rounded to the arc axes it lies on.
func _arc_dir(d: CityDistrict, dir: Vector3) -> Vector2:
	var p0 := d.ring.world_to_arc(transform.origin)
	var p1 := d.ring.world_to_arc(transform * dir)
	var v := Vector2(p1.x - p0.x, p1.y - p0.y).normalized()
	return Vector2(roundf(v.x), roundf(v.y)) if absf(absf(v.x) - absf(v.y)) > 0.9 else v


# The car: front wall round the doorway, sides, back, roof (faces turned inward), ribs and bump rails, light bars, floor.
func _build_car(d: CityDistrict, layer: int, inv: Transform3D) -> void:
	car = Node3D.new()
	car.name = "Car"
	add_child(car)
	var st := CityGeo.new()
	st.tag("mission.lift_car")
	var F := -WALL
	var D := -car_back
	var y0 := -0.5
	var hw := W * 0.5
	var ch := car_half
	var wall := MissionProps.c("metal")
	var panel := MissionProps.c("metal_dark")
	var roof := MissionProps.c("m_recess")
	MissionGateDoor._face_nz(st, -ch, -hw, y0, CAR_H, F, wall)
	MissionGateDoor._face_nz(st, hw, ch, y0, CAR_H, F, wall)
	MissionGateDoor._face_nz(st, -hw, hw, H, CAR_H, F, wall)
	MissionGateDoor._face_px(st, -ch, F, D, y0, CAR_H, wall)
	MissionGateDoor._face_nx(st, ch, F, D, y0, CAR_H, wall)
	MissionGateDoor._face_pz(st, -ch, ch, y0, CAR_H, D, wall)
	MissionGateDoor._face_ny(st, -ch, ch, F, D, CAR_H, roof)
	# Ribs up the side walls and the back (the car's frame), bump rails along them at a mech's knee and hip.
	var z := F - 2.5
	while z > D + 1.0:
		for k: float in [-1.0, 1.0]:
			var faces := CityGeo.ALL - CityGeo.NY - CityGeo.PY - (CityGeo.NX if k < 0.0 else CityGeo.PX)
			st.box(Transform3D.IDENTITY, Vector3(k * (ch - 0.2), (y0 + CAR_H) * 0.5, z), Vector3(0.4, CAR_H - y0, 0.6), panel, faces)
		z -= 3.2
	var xr := -ch + 2.5
	while xr < ch - 1.0:
		st.box(Transform3D.IDENTITY, Vector3(xr, (y0 + CAR_H) * 0.5, D + 0.2), Vector3(0.6, CAR_H - y0, 0.4), panel, CityGeo.ALL - CityGeo.NZ - CityGeo.NY - CityGeo.PY)
		xr += 3.0
	var rail := MissionProps.c("marking_yellow")
	for y: float in [1.4, 3.2]:
		for k: float in [-1.0, 1.0]:
			st.box(Transform3D.IDENTITY, Vector3(k * (ch - 0.55), floor_rise + y, (F + D) * 0.5 - 0.3), Vector3(0.3, 0.35, -(D - F) - 1.2), rail,
					CityGeo.ALL - (CityGeo.NX if k < 0.0 else CityGeo.PX))
		st.box(Transform3D.IDENTITY, Vector3(0, floor_rise + y, D + 0.55), Vector3(ch * 2.0 - 1.2, 0.35, 0.3), rail, CityGeo.ALL - CityGeo.NZ)
	car.add_child(MissionProps.mesh(st, "Inside", layer))
	# Light bars across the roof and a strip along the top of each side wall (warm, as the gate bays').
	var lg := CityGeo.new()
	lg.tag("mission.lift_lights")
	z = F - 3.0
	while z > D + 1.5:
		lg.box(Transform3D.IDENTITY, Vector3(0, CAR_H - LIGHT_DROP * 0.5, z), Vector3(ch * 2.0 - 2.4, LIGHT_DROP, 0.6), MissionProps.c("strip"), CityGeo.ALL - CityGeo.PY)
		z -= 4.5
	for k: float in [-1.0, 1.0]:
		lg.box(Transform3D.IDENTITY, Vector3(k * (ch - 0.08), CAR_H - 0.8, (F + D) * 0.5), Vector3(0.16, 0.3, -(D - F) - 1.0), MissionProps.c("strip"),
				CityGeo.ALL - (CityGeo.NX if k < 0.0 else CityGeo.PX))
	car.add_child(MissionProps.mesh(lg, "Light", layer, MissionProps.glow("strip", 3.0)))
	# The floor on the deck's facets (district coordinates; the mesh undoes the frame): checker plate, the threshold plate
	# through the doorway and a hazard line where the car begins.
	var fl := CityGeo.new(d.ring)
	fl.tag("mission.lift_floor")
	_g_box(fl, arc(-ch, 0.0), arc(ch, car_back), 0.03, MissionProps.c("asphalt_dark"))
	_g_box(fl, arc(-hw, 0.02), arc(hw, WALL), 0.05, MissionProps.c("metal"))      # starts inside the door plane: the apron hatch is the plaza's
	_g_box(fl, arc(-hw, WALL + 0.2), arc(hw, WALL + 0.5), 0.07, MissionProps.c("marking_yellow"))
	var fm := MissionProps.mesh(fl, "Floor", layer)
	fm.transform = inv
	car.add_child(fm)


## A floor rect between arc corners a and b at height h above the curb on the facets.
static func _g_box(g: CityGeo, a: Vector2, b: Vector2, h: float, col: Color) -> void:
	var r := Rect2(a, Vector2.ZERO).expand(b)
	g.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, CityPlan.CURB_H + h, col)


# The hollow core: walls round the car in place of the district's solid core box (MissionWorld disables it), the doorway's
# shape. The deck's own floor (the sidewalk slab under the core) is the car's floor.
func _build_collision(d: CityDistrict) -> void:
	body = MissionProps.body_like(d, "LiftBody")
	add_child(body)
	var I := Transform3D.IDENTITY
	var hw := W * 0.5
	var y0 := -1.0
	var y1 := core_top
	var ch := car_half
	_box(I, -core_half, -ch, -core_depth, 0.0, y0, y1)          # beside the car, full depth
	_box(I, ch, core_half, -core_depth, 0.0, y0, y1)
	_box(I, -ch, ch, -core_depth, -car_back, y0, y1)            # behind it
	_box(I, -ch, -hw, -WALL, 0.0, y0, y1)                       # the front wall beside the doorway
	_box(I, hw, ch, -WALL, 0.0, y0, y1)
	_box(I, -hw, hw, -WALL, 0.0, H, y1)                         # over it
	_box(I, -ch, ch, -car_back, -WALL, CAR_H, y1)               # the roof
	door_shape = MissionProps.box_shape(body, I, Vector3(0, (y0 + H) * 0.5, -WALL * 0.5), Vector3(W, H - y0, WALL))


func _box(xf: Transform3D, x0: float, x1: float, z0: float, z1: float, y0: float, y1: float) -> void:
	if x1 - x0 < 0.01 or z1 - z0 < 0.01 or y1 - y0 < 0.01:
		return
	MissionProps.box_shape(body, xf, Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5), Vector3(x1 - x0, y1 - y0, z1 - z0))


## state as MissionGateDoor.pose (shut | warn | opening | open | closing | sealed), u 0..1 through opening / closing.
func pose(state: String, u: float) -> void:
	var open := 0.0
	match state:
		"opening": open = smoothstep(0.0, 1.0, u)
		"open": open = 1.0
		"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
	for i in leaves.size():
		var k := -1.0 if i == 0 else 1.0
		leaves[i].position.x = k * W * (0.25 + 0.5 * open)


## Whether the doorway's shape is solid in `state`: only while the leaves stand still and shut (MissionGateDoor.blocks).
func blocks(state: String) -> bool:
	return state == "shut" or state == "warn" or state == "sealed"


## The usable clear height inside the car: under the light bars, over the floor's highest point.
func clear_height() -> float:
	return CAR_H - LIGHT_DROP - floor_rise


## Where the car's light hangs while the doors open and stand open (frame).
func light_point() -> Vector3:
	return Vector3(0, CAR_H - 1.5, -car_back * 0.5)


func world_point() -> Vector3:
	return global_transform * Vector3(0, H * 0.5, 2.0) if is_inside_tree() else transform * Vector3(0, H * 0.5, 2.0)


# --- The baked shut doors (CityBuildings._lift_doorway) ------------------------------------------------------------------

## Whether district-local point p (in this door's frame: `local`) lies on the baked fill (the shut doors across the doorway).
static func in_fill(local: Vector3) -> bool:
	return absf(local.x) <= W * 0.5 + 0.01 and local.y >= -0.01 and local.y <= H + 0.01 \
			and local.z >= -CityBuildings.LIFT_FILL - 0.01 and local.z <= -CityBuildings.LIFT_FILL + 0.06


## Hide the baked shut doors of this lift in district d's mesh: the triangles of the pillar's block mesh lying wholly on
## the fill are left out of a copy of the mesh (the district's own mesh is kept to restore). Returns [MeshInstance3D,
## original Mesh], or [] when nothing was found (an audit build keeps its tags' indices: nothing is hidden).
func hide_fill(d: CityDistrict) -> Array:
	var block := int(d.plan.lots[int(d.plan.buildings[bi]["lot"])]["block"])
	var mi := d.get_node_or_null("Buildings/Block%d" % block) as MeshInstance3D
	if mi == null or mi.has_meta("audit_tags") or not (mi.mesh is ArrayMesh):
		return []
	var rel := Transform3D.IDENTITY
	var nd: Node = mi
	while nd != d and nd != null:
		rel = (nd as Node3D).transform * rel
		nd = nd.get_parent()
	var to_door := transform.affine_inverse() * rel
	var src := mi.mesh as ArrayMesh
	var out := ArrayMesh.new()
	var cut := 0
	for si in src.get_surface_count():
		var arr := src.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if arr[Mesh.ARRAY_INDEX] != null or v.size() % 3 != 0:
			return []
		var keep := PackedInt32Array()
		for i in range(0, v.size(), 3):
			if in_fill(to_door * v[i]) and in_fill(to_door * v[i + 1]) and in_fill(to_door * v[i + 2]):
				cut += 1
			else:
				keep.append(i)
		var na := []
		na.resize(Mesh.ARRAY_MAX)
		for a in Mesh.ARRAY_MAX:
			na[a] = _pick(arr[a], keep, v.size())
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, na)
		out.surface_set_material(si, src.surface_get_material(si))
	if cut == 0:
		return []
	mi.mesh = out
	return [mi, src]


## The triangles starting at `keep` of a per-vertex array (null and arrays of another length are passed through).
static func _pick(a: Variant, keep: PackedInt32Array, n: int) -> Variant:
	if a == null:
		return null
	if a is PackedVector3Array and (a as PackedVector3Array).size() == n:
		var o := PackedVector3Array()
		for i in keep:
			o.append((a as PackedVector3Array)[i])
			o.append((a as PackedVector3Array)[i + 1])
			o.append((a as PackedVector3Array)[i + 2])
		return o
	if a is PackedColorArray and (a as PackedColorArray).size() == n:
		var o := PackedColorArray()
		for i in keep:
			o.append((a as PackedColorArray)[i])
			o.append((a as PackedColorArray)[i + 1])
			o.append((a as PackedColorArray)[i + 2])
		return o
	if a is PackedVector2Array and (a as PackedVector2Array).size() == n:
		var o := PackedVector2Array()
		for i in keep:
			o.append((a as PackedVector2Array)[i])
			o.append((a as PackedVector2Array)[i + 1])
			o.append((a as PackedVector2Array)[i + 2])
		return o
	if a is PackedFloat32Array and (a as PackedFloat32Array).size() == n * 4:     # tangents
		var o := PackedFloat32Array()
		for i in keep:
			for j in 12:
				o.append((a as PackedFloat32Array)[i * 4 + j])
		return o
	return null
