extends SceneTree
## Prints the triangle count and AABB of every EnemyMeshes part (headless):
##   godot --headless --path . --script res://tools/enemy_style/tri_counts.gd

const PARTS := ["turret_base", "turret_gun", "turret_sniper_gun", "turret_missile_gun", "turret_gun_wreck", "strider_chassis",
	"strider_breacher_chassis", "strider_sensor", "strider_leg", "tank_hull", "tank_turret", "tank_turret_wreck", "tank_vents",
	"drone_hull", "drone_optic", "drone_cone", "trooper_rifle", "trooper_at", "debris_plate", "debris_chunk", "rupture_core"]


func _initialize() -> void:
	var total := 0
	for p: String in PARTS:
		var m := EnemyMeshes.mesh(p)
		var tris := 0
		for s in m.get_surface_count():
			tris += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		total += tris
		var a := m.get_aabb()
		print("[tris] %-26s %5d  aabb pos %s size %s" % [p, tris, str(a.position.snapped(Vector3.ONE * 0.01)),
				str(a.size.snapped(Vector3.ONE * 0.01))])
	print("[tris] total %d" % total)
	quit()
