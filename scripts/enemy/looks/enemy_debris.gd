class_name EnemyDebris
extends Node3D
## One popped-off low-poly enemy chunk (turret dome, gun head, severed leg, armor plate): deterministic kinematic
## ballistic arc under RingFrame radial gravity (-up * 18), 1-2 damped bounces against streets/roofs/walls, then
## frozen permanently at rest (`settled = true`, 0.00 ms CPU cost). Cosmetic only (all LOCAL, no RigidBody3D).

const GRAVITY := 18.0             ## m/s^2 along local -up
const RESTITUTION := 0.35         ## normal bounce restitution
const BOUNCE_FRICTION := 0.52     ## tangent speed retained per ground bounce
const SPIN_DAMP := 0.45           ## angular tumble retained per bounce
const SETTLE_SPEED := 1.6         ## m/s post-bounce normal speed below which the piece comes to rest
const MAX_BOUNCES := 2
const MAX_FLIGHT_TIME := 6.5      ## s safety settle if flung off an open arena without floor

var part_id := ""
var velocity := Vector3.ZERO
var spin := Vector3.ZERO
var settled := false
var bounces := 0
var rest_radius := 0.35
var age := 0.0
var ring: RingFrame = null
var _mesh_node: MeshInstance3D = null
var _mesh_offset := Vector3.ZERO


func net_fields() -> Dictionary:
	return {
		"part_id": Net.LOCAL, "velocity": Net.LOCAL, "spin": Net.LOCAL, "settled": Net.LOCAL,
		"bounces": Net.LOCAL, "rest_radius": Net.LOCAL, "age": Net.LOCAL, "ring": Net.SPAWN,
		"_mesh_node": Net.LOCAL, "_mesh_offset": Net.LOCAL,
	}


func setup(part: String, start_xf: Transform3D, vel: Vector3, ang_vel: Vector3, r: RingFrame = null,
		charred: bool = false, mesh_scale: Vector3 = Vector3.ONE) -> void:
	part_id = part
	name = "Debris_%s" % part
	ring = r
	velocity = vel
	spin = ang_vel
	settled = false
	bounces = 0
	age = 0.0

	_mesh_node = EnemyMeshes.instance(part)
	_mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if charred:
		_mesh_node.material_override = EnemyMeshes.charred_material()
	_mesh_node.scale = mesh_scale

	var aabb := _mesh_node.mesh.get_aabb() if _mesh_node.mesh != null else AABB(Vector3(-0.3, -0.3, -0.3), Vector3(0.6, 0.6, 0.6))
	var scaled_center := aabb.get_center() * mesh_scale
	var scaled_size := (aabb.size * mesh_scale).abs()
	_mesh_offset = -scaled_center
	_mesh_node.position = _mesh_offset
	rest_radius = clampf(minf(scaled_size.x, minf(scaled_size.y, scaled_size.z)) * 0.42, 0.16, 0.95)
	add_child(_mesh_node)

	var basis_o := start_xf.basis.orthonormalized()
	var world_center := start_xf.origin + basis_o * scaled_center
	if is_inside_tree():
		global_transform = Transform3D(basis_o, world_center)
	else:
		transform = Transform3D(basis_o, world_center)


func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	if settled or dt <= 0.0:
		return
	age += dt
	var pos := global_position if is_inside_tree() else position
	var up := ring.up_at(pos) if ring != null else Vector3.UP
	velocity -= up * GRAVITY * dt
	var next_pos := pos + velocity * dt

	var spin_len := spin.length()
	if spin_len > 1e-4:
		var rot := Basis(spin / spin_len, spin_len * dt)
		if is_inside_tree():
			global_basis = (rot * global_basis).orthonormalized()
		else:
			basis = (rot * basis).orthonormalized()

	var move := next_pos - pos
	var move_len := move.length()
	if space != null:
		var hit := {}
		if move_len > 1e-4:
			hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(pos, next_pos + (move / move_len) * rest_radius))
		if hit.is_empty() and velocity.dot(up) <= 0.5:
			hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(next_pos + up * maxf(rest_radius, 0.35), next_pos - up * rest_radius))
		if not hit.is_empty():
			if _handle_surface_hit(hit["position"] as Vector3, (hit["normal"] as Vector3).normalized(), up):
				return
			next_pos = global_position if is_inside_tree() else position
	else:
		var next_up := ring.up_at(next_pos) if ring != null else Vector3.UP
		if ring != null:
			var rh := ring.height(next_pos)
			if rh <= rest_radius and velocity.dot(next_up) <= 0.0:
				if _handle_surface_hit(next_pos - next_up * rh, next_up, next_up):
					return
				next_pos = global_position if is_inside_tree() else position
		elif next_pos.y <= rest_radius and velocity.y <= 0.0:
			if _handle_surface_hit(Vector3(next_pos.x, 0.0, next_pos.z), Vector3.UP, Vector3.UP):
				return
			next_pos = global_position if is_inside_tree() else position

	if age >= MAX_FLIGHT_TIME:
		_settle_at(next_pos)
		return
	if is_inside_tree():
		global_position = next_pos
	else:
		position = next_pos


## Returns true if the piece settled at rest on this hit.
func _handle_surface_hit(hit_pos: Vector3, hit_n: Vector3, up: Vector3) -> bool:
	var vn := velocity.dot(hit_n)
	var rest_pos := hit_pos + hit_n * rest_radius
	if is_inside_tree():
		global_position = rest_pos
	else:
		position = rest_pos
	if vn >= 0.0:
		return false
	var v_tan := velocity - hit_n * vn
	var is_floor := hit_n.dot(up) >= 0.55
	if is_floor:
		var bounce_v := -vn * RESTITUTION
		if bounces < MAX_BOUNCES and bounce_v >= SETTLE_SPEED:
			bounces += 1
			velocity = v_tan * BOUNCE_FRICTION + hit_n * bounce_v
			spin *= SPIN_DAMP
			return false
		_settle_at(rest_pos)
		return true
	# Wall impact: reflect with damping and keep falling.
	velocity = v_tan * 0.72 - hit_n * vn * RESTITUTION
	spin *= 0.6
	return false


func _settle_at(at: Vector3) -> void:
	velocity = Vector3.ZERO
	spin = Vector3.ZERO
	settled = true
	if is_inside_tree():
		global_position = at
	else:
		position = at
