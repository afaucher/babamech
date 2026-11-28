class_name SupplyDepot
extends Node3D
## One military supply depot in the world (docs/design/pacing-director.md §2, look: docs/design/supply-depot.md, pick B2).
## This node holds the gameplay pieces: the collision (one convex shape over the kiosk's visible footprint, walls past
## every mech's straight side and a steep cap: see COLLISION) and the DepotTarget (weapons fire, host-owned). The LOOK is a separate child: the art model VIEW_SCENE (Enemy art's DepotKiosk,
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
## COLLISION (R2.23, 2026-11-26: the user's Strider wedged at a corner of the old 6 x 4.35 x 4 box and could not move
## any way). Reproduced on real decks (tests/test_supply_depot.gd G, a probe of 8000+ approaches per shape): a capsule
## walking into a vertical box corner whose TOP lies within the capsule's straight side sinks into the corner and every
## move_and_slide is then blocked (0 m in all 8 directions; the "pin band" the Environment survey found at ramp ends:
## docs/design/collision-survey.md). The old top, 4.35 m, is inside the band of the Strider (straight side 2.2 .. 5.8 m
## above its feet) and of the Bulwark (3.6 .. 4.4 m). Measured per shape: the 4.35 m box 17 traps, the same box on the
## ring's up 18, the roof's footprint 10-11, rounded corners 73, walls to 6.5 m 0, walls to 6.2 m 0 (8000-9000 runs
## each). So the collision is one convex shape:
##   - the kiosk's VISIBLE footprint, roof overhang included (DepotMeshes: roof slab W + 0.6 wide, from -D/2 - 0.15 at
##     the back to D/2 + 0.35 at the socket wall): nothing visible sticks out of it, nothing slides under the eave;
##   - vertical walls to WALL_H (above every chassis' straight side: Strider 5.8, Bulwark 4.4, Wasp 2.8 m), each edge
##     along the ring's local up at its corner (a box square to the deck at its centre leans ~0.4 deg at 3 m);
##   - a FLAT top at WALL_H, no rim: a mech that thrust-lands on it stands there and walks off any side. It is 1.85 m
##     above the visible roof (the trade for no trap). A steep hipped cap was tried and does not help: a capsule rests
##     on any convex top's ridge / edges (their contact normal is vertical) and perched higher (up to 9.4 m), so the
##     lowest flat top out of the pin band is the least odd. (Art could raise a roof housing to WALL_H to hide it.)
## The mast has no collision (a thin pole: a mech passes through its upper part above WALL_H). No hit sphere is a
## physics shape (DepotTarget's spheres are CombatWorld math, and shots skip this body: CombatWorld._body_excludes), so nothing else is on the move layer.
const FOOT_X := 3.3                     ## m: half width of the collision (the roof slab's half width)
const FOOT_Z0 := -2.15                  ## m: its back face (local z; the roof slab's back edge)
const FOOT_Z1 := 2.35                   ## m: its front face (the socket wall side; the roof slab's front lip)
const ROOF_H := 4.35                    ## m: the visible roof top (DepotMeshes.ROOF_TOP)
const WALL_H := 6.2                     ## m: the collision's walls and flat top (above the tallest straight side, 5.8 m)
## m: the symmetric box round the collision that placement (SiteFit ring rule, keep-out) and the claim range measure from
## (footprint_half): 6.6 x 4.7 contains the 6.6 x 4.5 footprint, so every gap placement allows is at least as wide.
const BLOCK := Vector3(FOOT_X * 2.0, WALL_H, maxf(-FOOT_Z0, FOOT_Z1) * 2.0)

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
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	shape.shape = collision_shape(transform, d.ring)
	body.add_child(shape)
	add_child(body)
	target = DepotTarget.new(id)
	add_child(target)
	target.mech = body


## The depot's collision (see COLLISION) for a depot whose local frame is `xf` in ring `ring`'s coordinates (the
## district's; null = a flat world, straight up): a ConvexPolygonShape3D of 8 points: the 4 floor corners of the
## footprint and each one WALL_H up the ring's local up there. Plan data + math only: the same on every machine.
static func collision_shape(xf: Transform3D, ring: RingFrame) -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	var inv := xf.basis.inverse()
	for c: Vector2 in [Vector2(-FOOT_X, FOOT_Z0), Vector2(FOOT_X, FOOT_Z0), Vector2(FOOT_X, FOOT_Z1), Vector2(-FOOT_X, FOOT_Z1)]:
		var b := Vector3(c.x, 0.0, c.y)
		var u := (inv * ring.up_at(xf * b)).normalized() if ring != null else Vector3.UP
		pts.append(b)
		pts.append(b + u * (WALL_H / maxf(u.y, 0.5)))
	var sh := ConvexPolygonShape3D.new()
	sh.points = pts
	return sh


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
