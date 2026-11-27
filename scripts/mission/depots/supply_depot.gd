class_name SupplyDepot
extends Node3D
## One military supply depot in the world (docs/design/pacing-director.md §2, look: docs/design/supply-depot.md, pick B2).
## This node holds the gameplay pieces: the collision box (BLOCK, the size of the bunker) and the DepotTarget (weapons
## fire, host-owned). The LOOK is a separate child: the art model VIEW_SCENE (Enemy art's DepotKiosk,
## scripts/mission/depots/depot_kiosk.gd), or the placeholder VIEW_SCRIPT when that scene is missing, behind the view
## interface: set_cores(stocked, capacity), core_taken(index), set_destroyed(dead), socket_point(index), and
## set_render_layers(mask) (the placeholder: setup(layer)) called BEFORE it enters the tree. Swapping the model = one
## constant. The view builds plain meshes (no GPU work at load), so headless runs need nothing more.
## FACING: `face` (0 +s, 1 +x, 2 -s, 3 -x) turns the whole depot about its up so the socket wall (local +Z) faces open
## ground (MissionDepots picks it from the snap rule); footprint_half() is the footprint in the deck's (x, s) then.
##
## Presentation: MissionDepots builds it (build) and pushes the replicated state (show_state) on every machine. The cores
## show only on the model (lit sockets), never in the HUD.

## The look: the art model (a scene whose root has the view interface). Change this one line to swap it.
const VIEW_SCENE := "res://scenes/props/supply_depot_kiosk.tscn"
## The placeholder look, used when VIEW_SCENE is missing (kept tested).
const VIEW_SCRIPT := "res://scripts/mission/depots/supply_depot_view.gd"
const BLOCK := Vector3(6.0, 4.35, 4.0)  ## m: the bunker's collision (body 6 x 4, roof 4.35; local x, y up, z = wall side)

var depot_id := ""
var deck := 0
var cores := 1                          ## sockets in use (the depot's cores at mission start)
var cores_left := -1                    ## shown now (-1 before the first show_state)
var alive := true                       ## shown now
var body: StaticBody3D
var target: DepotTarget
var view: Node3D
var face := 0                           ## which way the socket wall looks: 0 +s, 1 +x, 2 -s, 3 -x


func net_fields() -> Dictionary:
	return {"depot_id": Net.SPAWN, "deck": Net.SPAWN, "cores": Net.SPAWN,
		# mirrors of the host's replicated state (MissionDepots' state is the authority), pushed by show_state
		"cores_left": Net.LOCAL, "alive": Net.LOCAL,
		"body": Net.LOCAL, "target": Net.LOCAL, "view": Net.LOCAL,
		"face": Net.SPAWN}   # from the plan + snap rule, the same on every machine


## Build the pieces at `xf` (district-local: MissionProps.site_frame) for district `d`. Call before adding it under d.
func build(d: CityDistrict, xf: Transform3D, id: String, k: int, core_count: int, facing: int = 0) -> void:
	depot_id = id
	deck = k
	cores = maxi(core_count, 0)
	face = posmod(facing, 4)
	name = "SupplyDepot_" + id
	transform = xf * Transform3D(Basis(Vector3.UP, face_yaw(face)), Vector3.ZERO)
	view = make_view()
	if view != null:
		if view.has_method("set_render_layers"):
			view.call("set_render_layers", d.render_layer)
		elif view.has_method("setup"):
			view.call("setup", d.render_layer)
		view.name = "View"
		add_child(view)
		view.call("set_cores", 0, cores)
	body = MissionProps.body_like(d, "Body")
	MissionProps.box_shape(body, Transform3D.IDENTITY, Vector3(0, BLOCK.y * 0.5, 0), BLOCK)
	add_child(body)
	target = DepotTarget.new(id)
	add_child(target)
	target.mech = body


## The yaw (about local up) that turns local +Z toward `f` (0 +s, 1 +x, 2 -s, 3 -x).
static func face_yaw(f: int) -> float:
	return [0.0, PI * 0.5, PI, -PI * 0.5][posmod(f, 4)]


## Half the footprint in the deck's (x, s) for facing `f`: the 6 m side lies across the facing direction.
static func footprint_half(f: int) -> Vector2:
	return Vector2(BLOCK.x, BLOCK.z) * 0.5 if posmod(f, 2) == 0 else Vector2(BLOCK.z, BLOCK.x) * 0.5


## A new look: VIEW_SCENE, else (missing) the placeholder VIEW_SCRIPT. `placeholder` forces the latter (tests).
static func make_view(placeholder: bool = false) -> Node3D:
	if not placeholder and ResourceLoader.exists(VIEW_SCENE):
		var sc := load(VIEW_SCENE) as PackedScene
		if sc != null:
			return sc.instantiate() as Node3D
	var res: Resource = load(VIEW_SCRIPT)
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	if res is GDScript:
		return (res as GDScript).new() as Node3D
	return null


## Show `left` cores and whether the depot stands (idempotent); also the combat target's mirror.
func show_state(left: int, is_alive: bool) -> void:
	var n := clampi(left, 0, cores) if is_alive else 0
	if n == cores_left and is_alive == alive:
		return
	if is_instance_valid(view):
		if cores_left > n and is_alive and view.has_method("core_taken"):
			for i in range(n, cores_left):
				view.call("core_taken", i)
		view.call("set_cores", n, cores)
		view.call("set_destroyed", not is_alive)
	cores_left = n
	alive = is_alive
	if is_instance_valid(target):
		target.alive = alive


## Stocked sockets showing now (tests: the diegetic count).
func lit_cells() -> int:
	if is_instance_valid(view) and view.has_method("lit_count"):
		return int(view.call("lit_count"))
	return cores_left if alive else 0


## World point of socket `index` (for effects: a core leaving).
func socket_world(index: int) -> Vector3:
	if is_instance_valid(view) and view.has_method("socket_point"):
		return view.global_transform * (view.call("socket_point", index) as Vector3)
	return global_position
