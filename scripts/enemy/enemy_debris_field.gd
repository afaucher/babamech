class_name EnemyDebrisField
extends Node3D
## LRU-capped container of popped-off EnemyDebris chunks owned by EnemySquad.
## Only unsettled chunks are ticked; once `chunk.settled` becomes true, it is removed from `_active` so settled
## debris in the environment costs 0.00 ms CPU. Freed cleanly when `EnemySquad.clear_enemies()` runs.

const MAX_DEBRIS := 28

var ring: RingFrame = null
var chunks: Array[EnemyDebris] = []
var _active: Array[EnemyDebris] = []


func _init() -> void:
	name = "EnemyDebrisField"


func net_fields() -> Dictionary:
	return {"ring": Net.SPAWN, "chunks": Net.LOCAL, "_active": Net.LOCAL}


func spawn_chunk(part: String, world_xf: Transform3D, vel: Vector3, ang_vel: Vector3,
		charred: bool = false, mesh_scale: Vector3 = Vector3.ONE, r: RingFrame = null) -> EnemyDebris:
	while chunks.size() >= MAX_DEBRIS:
		var old: EnemyDebris = chunks.pop_front()
		_active.erase(old)
		if is_instance_valid(old):
			old.queue_free()
	var d := EnemyDebris.new()
	add_child(d)
	d.setup(part, world_xf, vel, ang_vel, r if r != null else ring, charred, mesh_scale)   # r: the enemy's deck ring (W4)
	chunks.append(d)
	_active.append(d)
	return d


func tick(dt: float, space: PhysicsDirectSpaceState3D = null) -> void:
	if _active.is_empty() or dt <= 0.0:
		return
	for i in range(_active.size() - 1, -1, -1):
		var d: EnemyDebris = _active[i]
		if not is_instance_valid(d) or d.settled:
			_active.remove_at(i)
			continue
		d.tick(dt, space)
		if d.settled:
			_active.remove_at(i)


func clear() -> void:
	for d in chunks:
		if is_instance_valid(d):
			d.queue_free()
	chunks.clear()
	_active.clear()


func total_count() -> int:
	var n := 0
	for d in chunks:
		if is_instance_valid(d):
			n += 1
	return n


func active_count() -> int:
	return _active.size()


func find_by_part(part: String) -> Array[EnemyDebris]:
	var out: Array[EnemyDebris] = []
	for d in chunks:
		if is_instance_valid(d) and d.part_id == part:
			out.append(d)
	return out
