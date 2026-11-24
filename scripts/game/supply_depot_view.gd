extends Node3D
## The supply depot's LOOK (PLACEHOLDER of the picked B2 "hardened bunker kiosk + socket wall",
## docs/design/supply-depot.md): a squat off-white bunker with charcoal frames, orange hazard corners and an overhanging
## roof over a socket wall of 4 round sockets (2 x 2) on its +Z face. Ice blue = a stocked core, black hole = taken or
## unused (capacity < 4: the spare sockets are black from the start). Destroyed: a scorched slumped wreck.
##
## THE VIEW INTERFACE (SupplyDepot loads this script by path from SupplyDepot.VIEW_SCRIPT; the art session's model
## replaces it by changing that one constant, no other code):
##   set_cores(stocked: int, capacity: int)   state, idempotent, safe to call any time (a late joiner calls it once)
##   core_taken(index: int)                   optional cosmetic one-shot when socket `index` empties (here: nothing)
##   set_destroyed(dead: bool)                the wreck (state, idempotent)
##   socket_point(index: int) -> Vector3      a socket's centre, in this node's space
##   setup(layer: int)                        render layers for every mesh, called by SupplyDepot before it enters the tree
## Footprint about 6 x 4 x 3 m, origin at the ground centre, socket wall on +Z. No collision here (SupplyDepot adds a box),
## no lights. Cosmetic only: nothing synced.

const SOCKETS := 4
const SOCKET_R := 0.42
const FOOT := Vector3(6.0, 3.0, 4.0)
const WALL_Z := 2.0                       ## the socket wall's plane (+Z face)
const SOCKET_AT := [Vector2(-0.75, 1.95), Vector2(0.75, 1.95), Vector2(-0.75, 0.95), Vector2(0.75, 0.95)]   ## (x, y)

var stocked := -1
var capacity := 0
var dead := false
var _layer := 1
var _intact: Node3D
var _wreck: Node3D
var _lit: Array = []                      ## per socket: the ice-blue core
var _hole: Array = []                     ## per socket: the black hole


func net_fields() -> Dictionary:
	return {"stocked": Net.LOCAL, "capacity": Net.LOCAL, "dead": Net.LOCAL, "_layer": Net.LOCAL, "_intact": Net.LOCAL,
		"_wreck": Net.LOCAL, "_lit": Net.LOCAL, "_hole": Net.LOCAL}


func setup(layer: int) -> void:
	_layer = layer
	name = "View"
	var I := Transform3D.IDENTITY
	_intact = Node3D.new()
	_intact.name = "Intact"
	var g := CityGeo.new()
	var white := MissionProps.c("marking")
	var charcoal := MissionProps.c("m_recess")
	var orange := MissionProps.c("m_ours")
	g.box(I, Vector3(0, 0.15, 0), Vector3(FOOT.x + 0.6, 0.3, FOOT.z + 0.6), MissionProps.c("concrete_dark"))
	# Sloped side slabs (stepped boxes) and the core block.
	g.box(I, Vector3(0, 1.45, -0.2), Vector3(FOOT.x - 0.4, 2.3, FOOT.z - 0.8), white)
	for sx: float in [-1.0, 1.0]:
		g.box(I, Vector3(sx * (FOOT.x * 0.5 - 0.35), 1.0, 0), Vector3(0.7, 1.7, FOOT.z), white)
		g.box(I, Vector3(sx * (FOOT.x * 0.5 - 0.35), 2.05, 0), Vector3(0.5, 0.4, FOOT.z - 0.3), white)
		g.box(I, Vector3(sx * (FOOT.x * 0.5 - 0.35), 0.45, WALL_Z - 0.2), Vector3(0.75, 0.6, 0.45), orange)   # hazard corners
		g.box(I, Vector3(sx * (FOOT.x * 0.5 - 0.35), 0.45, -WALL_Z + 0.2), Vector3(0.75, 0.6, 0.45), orange)
	# The heavy overhanging roof and the rolled-up shutter.
	g.box(I, Vector3(0, 2.8, 0.2), Vector3(FOOT.x, 0.4, FOOT.z + 0.4), white)
	g.box(I, Vector3(0, 2.62, WALL_Z + 0.25), Vector3(FOOT.x, 0.08, 0.3), orange)
	g.box(I, Vector3(0, 2.45, WALL_Z - 0.1), Vector3(2.8, 0.35, 0.4), charcoal)
	# The socket wall: a charcoal frame, a sock ring round each socket.
	g.box(I, Vector3(0, 1.45, WALL_Z - 0.15), Vector3(2.9, 2.0, 0.3), charcoal)
	for p: Vector2 in SOCKET_AT:
		g.prism(Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO), Vector3(p.x, WALL_Z, -p.y), SOCKET_R + 0.12,
			0.1, 12, MissionProps.c("metal"))
	_intact.add_child(MissionProps.mesh(g, "Body", _layer, null, true))
	var flip := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO)   # prism along +Z (out of the wall)
	for i in SOCKETS:
		var p: Vector2 = SOCKET_AT[i]
		var lg := CityGeo.new()
		lg.prism(flip, Vector3(p.x, WALL_Z, -p.y), SOCKET_R, 0.28, 12, MissionProps.c("m_portal"))
		var lit := MissionProps.mesh(lg, "Core%d" % i, _layer, MissionProps.glow("m_portal", 3.0))
		var hg := CityGeo.new()
		hg.prism(flip, Vector3(p.x, WALL_Z + 0.1, -p.y), SOCKET_R, 0.02, 12, Color(0.02, 0.02, 0.025))
		var hole := MissionProps.mesh(hg, "Hole%d" % i, _layer)
		_intact.add_child(lit)
		_intact.add_child(hole)
		_lit.append(lit)
		_hole.append(hole)
	add_child(_intact)
	_wreck = Node3D.new()
	_wreck.name = "Wreck"
	var w := CityGeo.new()
	w.box(I, Vector3(0, 0.15, 0), Vector3(FOOT.x + 0.6, 0.3, FOOT.z + 0.6), MissionProps.c("concrete_dark"))
	w.box(Transform3D(Basis(Vector3.FORWARD, 0.12), Vector3.ZERO), Vector3(0.2, 0.95, 0), Vector3(FOOT.x * 0.9, 1.5, FOOT.z * 0.9),
		MissionProps.c("m_scorch"))
	w.box(Transform3D(Basis(Vector3.RIGHT, 0.25), Vector3.ZERO), Vector3(0, 1.9, 0.6), Vector3(FOOT.x, 0.35, FOOT.z), white.darkened(0.55))
	_wreck.add_child(MissionProps.mesh(w, "Mesh", _layer, null, true))
	_wreck.visible = false
	add_child(_wreck)
	set_cores(0, 0)


func set_cores(n_stocked: int, n_capacity: int) -> void:
	capacity = clampi(n_capacity, 0, SOCKETS)
	stocked = clampi(n_stocked, 0, capacity)
	for i in _lit.size():
		var on := i < stocked
		(_lit[i] as Node3D).visible = on
		(_hole[i] as Node3D).visible = not on


func core_taken(_index: int) -> void:
	pass


func set_destroyed(is_dead: bool) -> void:
	dead = is_dead
	if _intact != null:
		_intact.visible = not dead
		_wreck.visible = dead


func socket_point(index: int) -> Vector3:
	var p: Vector2 = SOCKET_AT[clampi(index, 0, SOCKETS - 1)]
	return Vector3(p.x, p.y, WALL_Z + 0.2)


## Stocked sockets showing now (tests: the diegetic count).
func lit_count() -> int:
	if dead or _intact == null:
		return 0
	var n := 0
	for l: Node3D in _lit:
		if l.visible:
			n += 1
	return n
