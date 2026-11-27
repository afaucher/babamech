class_name DepotKiosk
extends Node3D
## The supply depot's model (docs/design/supply-depot.md "Build"; pick B2): a hardened bunker kiosk with a socket wall of
## four power cores (2 x 2). Cosmetic only: the depot's gameplay state (cores left, destroyed) is host-arbitrated in the
## Missions code (scripts/mission/depots/supply_depot.gd, MissionDepots), which pushes it here. No collision (the game adds its own
## box), no networking, no randomness.
##
## Scene: res://scenes/props/supply_depot_kiosk.tscn (a root Node3D with this script). The pieces are built in _init, so
## they exist straight after instantiate(): set_render_layers() can run before the node enters the tree.
##
## Orientation: origin on the ground at the bunker's centre, up = local +Y (whatever parent it sits under), the socket
## wall faces local +Z. Footprint ~6.6 x 4.6 m with the roof overhang, roof top 4.35 m, marker lamp ~8.3 m.
## Sockets: index 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right as seen from in front of the wall (rows at 3.05
## and 2.0 m). Fill order: the first `stocked` indices hold cores, so the bottom-right core goes dark first.
##
## Interface (Missions):
##   set_cores(stocked, capacity)  state, idempotent: sockets < stocked show a core (ice-blue cell), the rest are empty
##                                 black holes (sockets >= capacity are black from the start). Only toggles visibility.
##   core_taken(index)             one-shot flourish: a copy of the core slides out 1.4 m and its light dies (0.6 s).
##                                 Call set_cores right after; the flourish runs on its own.
##   set_destroyed(dead)           wrecked look (scorched, roof slumped, marker snapped, every socket dark); reversible.
##   socket_point(index)           local position of a socket (centre of its opening on the panel's front face).
##   set_marker(on)                the roof mast and beacon (default on).
##   set_render_layers(mask)       render layers for every mesh and the light's cull mask (the stack's deck layers).
## Lights: the cores and the beacon are unshaded (emissive look); one small ice-blue OmniLight3D, no shadows, scaled by
## the cores shown (off when none or destroyed). Core light is driven only by set_cores / set_destroyed.

const SOCKETS := DepotMeshes.SOCKETS
const FLOURISH_T := 0.6         ## s: core_taken's slide-out
const FLOURISH_OUT := 1.4       ## m it slides out along +Z
const LIGHT_ENERGY := 0.9       ## the omni's energy with all four cores in
const LIGHT_RANGE := 6.0

var time_scale := 1.0
var _stocked := 0
var _capacity := SOCKETS
var _destroyed := false
var _marker_on := true
var _body: MeshInstance3D
var _wreck: MeshInstance3D
var _marker: MeshInstance3D
var _marker_wreck: MeshInstance3D
var _cores: Array[MeshInstance3D] = []
var _ghosts: Array[MeshInstance3D] = []         ## per socket: the flourish copy (own fading glow material)
var _ghost_t: PackedFloat32Array = PackedFloat32Array()   ## per socket: s into its flourish (-1: idle)
var _light: OmniLight3D


func net_fields() -> Dictionary:
	return {"time_scale": Net.LOCAL, "_stocked": Net.LOCAL, "_capacity": Net.LOCAL, "_destroyed": Net.LOCAL,
		"_marker_on": Net.LOCAL, "_body": Net.LOCAL, "_wreck": Net.LOCAL, "_marker": Net.LOCAL, "_marker_wreck": Net.LOCAL,
		"_cores": Net.LOCAL, "_ghosts": Net.LOCAL, "_ghost_t": Net.LOCAL, "_light": Net.LOCAL}


func _init() -> void:
	_body = _mi("Body", DepotMeshes.body(false), Vector3.ZERO)
	_wreck = _mi("Wreck", DepotMeshes.body(true), Vector3.ZERO)
	_marker = _mi("Marker", DepotMeshes.marker(false), DepotMeshes.MAST_POS)
	_marker_wreck = _mi("MarkerWreck", DepotMeshes.marker(true), DepotMeshes.MAST_POS + Vector3(0.7, -0.35, 0.0))
	_ghost_t.resize(SOCKETS)
	var glow_i := _surface(DepotMeshes.core(), "glow")
	for i in SOCKETS:
		var c := _mi("Core%d" % i, DepotMeshes.core(), DepotMeshes.socket_local(i))
		c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_cores.append(c)
		var g := _mi("CoreFlourish%d" % i, DepotMeshes.core(), DepotMeshes.socket_local(i))
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if glow_i >= 0:
			var m := (LowPolyMaterials.materials()[1] as Material).duplicate() as StandardMaterial3D
			g.set_surface_override_material(glow_i, m)
		_ghosts.append(g)
		_ghost_t[i] = -1.0
	_light = OmniLight3D.new()
	_light.name = "CoreLight"
	_light.light_color = DepotMeshes.ICE
	_light.omni_range = LIGHT_RANGE
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 2.5, DepotMeshes.PANEL_Z + 1.6)
	add_child(_light)
	_apply()


func _mi(n: String, mesh: Mesh, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	return mi


static func _surface(mesh: ArrayMesh, sname: String) -> int:
	for s in mesh.get_surface_count():
		if mesh.surface_get_name(s) == sname:
			return s
	return -1


func set_cores(stocked: int, capacity: int) -> void:
	_capacity = clampi(capacity, 0, SOCKETS)
	_stocked = clampi(stocked, 0, _capacity)
	_apply()


func core_taken(index: int) -> void:
	if index < 0 or index >= SOCKETS or _destroyed:
		return
	_ghost_t[index] = 0.0
	_pose_ghost(index)


func set_destroyed(dead: bool) -> void:
	_destroyed = dead
	if dead:
		for i in SOCKETS:
			_ghost_t[i] = -1.0
	_apply()


func set_marker(on: bool) -> void:
	_marker_on = on
	_apply()


func set_render_layers(mask: int) -> void:
	for c in get_children():
		if c is VisualInstance3D:
			(c as VisualInstance3D).layers = mask
	_light.light_cull_mask = mask


func socket_point(index: int) -> Vector3:
	if index < 0 or index >= SOCKETS:
		return Vector3.ZERO
	return DepotMeshes.socket_local(index)


func socket_count() -> int:
	return SOCKETS


func stocked_count() -> int:
	return _stocked


func capacity() -> int:
	return _capacity


func is_stocked(index: int) -> bool:
	return index >= 0 and index < _stocked


func is_destroyed() -> bool:
	return _destroyed


## Whether socket `index`'s core is drawn right now (stocked and not destroyed).
func core_shown(index: int) -> bool:
	return index >= 0 and index < SOCKETS and _cores[index].visible


func flourish_active(index: int) -> bool:
	return index >= 0 and index < SOCKETS and _ghost_t[index] >= 0.0


func _apply() -> void:
	_body.visible = not _destroyed
	_wreck.visible = _destroyed
	_marker.visible = _marker_on and not _destroyed
	_marker_wreck.visible = _marker_on and _destroyed
	var shown := 0
	for i in SOCKETS:
		var on := i < _stocked and not _destroyed
		_cores[i].visible = on
		shown += int(on)
		_ghosts[i].visible = _ghost_t[i] >= 0.0
	_light.visible = shown > 0
	_light.light_energy = LIGHT_ENERGY * float(shown) / float(SOCKETS)


func _process(delta: float) -> void:
	for i in SOCKETS:
		if _ghost_t[i] < 0.0:
			continue
		_ghost_t[i] += delta * time_scale
		if _ghost_t[i] >= FLOURISH_T:
			_ghost_t[i] = -1.0
			_ghosts[i].visible = false
		else:
			_pose_ghost(i)


func _pose_ghost(i: int) -> void:
	var f := clampf(_ghost_t[i] / FLOURISH_T, 0.0, 1.0)
	var g := _ghosts[i]
	g.visible = true
	g.position = DepotMeshes.socket_local(i) + Vector3(0.0, 0.0, FLOURISH_OUT * (1.0 - (1.0 - f) * (1.0 - f)))
	var glow_i := _surface(DepotMeshes.core(), "glow")
	if glow_i >= 0:
		var m := g.get_surface_override_material(glow_i) as StandardMaterial3D
		if m != null:
			var b := clampf(1.0 - f * 1.4, 0.06, 1.0)
			m.albedo_color = Color(b, b, b)
