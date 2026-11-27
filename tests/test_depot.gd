extends TestCase
## The supply depot model (scripts/mission/depots/, docs/design/supply-depot.md "Build"): the scene instantiates with its
## pieces built in _init; 2 x 2 socket layout on the +Z wall; set_cores state over every (stocked, capacity) incl.
## capacity < 4, clamping and idempotence; stock changes only toggle visibility (same mesh instances, no rebuild);
## core_taken flourish runs and ends; set_destroyed is reversible and darkens every socket; no collision; no
## shadow-casting light; every cached mesh is a closed, outward-wound shell (the test_geometry_audit check).

const SCENE := "res://scenes/props/supply_depot_kiosk.tscn"


func setup() -> void:
	_meshes()
	await _kiosk()
	finish()


func _kiosk() -> void:
	var k := (load(SCENE) as PackedScene).instantiate() as DepotKiosk
	if not check(k != null, "the scene instantiates a DepotKiosk"):
		return
	# Pieces exist before entering the tree (Missions sets render layers first).
	check(k.get_child_count() > 0, "pieces built in _init")
	k.set_render_layers(1 << 3)
	for c in k.get_children():
		if c is VisualInstance3D:
			eq((c as VisualInstance3D).layers, 1 << 3, "render layers set on %s" % c.name)
	add_child(k)
	await frames(1)
	eq(k.socket_count(), 4, "four sockets")
	# Layout: 2 x 2, distinct, on the front panel inside the recess, 2-5 m up.
	var pts: Array[Vector3] = []
	for i in 4:
		pts.append(k.socket_point(i))
	for i in 4:
		var p := pts[i]
		near(p.z, DepotMeshes.PANEL_Z, 0.001, "socket %d on the front panel" % i)
		check(p.y >= 1.9 and p.y + DepotMeshes.COLLAR_R <= DepotMeshes.BODY_TOP, "socket %d height %.2f within the wall" % [i, p.y])
		check(absf(p.x) + DepotMeshes.COLLAR_R <= DepotMeshes.RECESS_X, "socket %d inside the recess" % i)
		for j in range(i + 1, 4):
			check(p.distance_to(pts[j]) >= DepotMeshes.COLLAR_R * 2.0, "sockets %d and %d don't overlap" % [i, j])
	check(pts[0].x < pts[1].x and pts[0].y > pts[2].y and is_equal_approx(pts[0].x, pts[2].x), "index 0 top-left, 1 top-right, 2 bottom-left")
	eq(k.socket_point(4), Vector3.ZERO, "out-of-range socket_point -> ZERO")
	# The wall faces +Z: the cores stand out past the body's front.
	var core_aabb := DepotMeshes.core().get_aabb()
	check(core_aabb.end.z > 0.1, "a core points +Z")
	# set_cores over every combination.
	var meshes := {}
	for c in k.get_children():
		if c is MeshInstance3D:
			meshes[c.name] = (c as MeshInstance3D).mesh
	var light := k.get_node("CoreLight") as OmniLight3D
	check(light != null and not light.shadow_enabled, "one omni light, no shadows")
	for cap in range(0, 6):
		for st in range(-1, 6):
			k.set_cores(st, cap)
			var ecap := clampi(cap, 0, 4)
			var est := clampi(st, 0, ecap)
			var ok := k.stocked_count() == est and k.capacity() == ecap
			for i in 4:
				ok = ok and k.is_stocked(i) == (i < est) and k.core_shown(i) == (i < est)
			check(ok, "set_cores(%d, %d) -> %d stocked of %d" % [st, cap, est, ecap])
			eq(light.visible, est > 0, "light on only with cores (%d, %d)" % [st, cap])
	# Idempotent.
	k.set_cores(3, 3)
	var before := _shown(k)
	k.set_cores(3, 3)
	k.set_cores(3, 3)
	eq(_shown(k), before, "set_cores repeated: same state")
	eq(before, [true, true, true, false], "capacity 3 with 3: first three cores, socket 3 black")
	k.set_cores(2, 4)
	eq(_shown(k), [true, true, false, false], "capacity 4 with 2")
	# No rebuild: the same mesh resources on the same nodes.
	var same := true
	for c in k.get_children():
		if c is MeshInstance3D:
			same = same and meshes.get(c.name) == (c as MeshInstance3D).mesh
	check(same and meshes.size() == _count_mi(k), "stock changes keep every node and mesh (no rebuild)")
	# Flourish.
	k.set_cores(3, 4)
	k.core_taken(2)
	k.set_cores(2, 4)
	check(k.flourish_active(2) and (k.get_node("CoreFlourish2") as Node3D).visible, "core_taken starts the flourish")
	check(not k.core_shown(2), "set_cores after core_taken hides the seated core")
	await frames(3)
	check((k.get_node("CoreFlourish2") as Node3D).position.z > k.socket_point(2).z, "the flourish slides out +Z")
	k._process(DepotKiosk.FLOURISH_T + 0.1)
	check(not k.flourish_active(2) and not (k.get_node("CoreFlourish2") as Node3D).visible, "the flourish ends")
	# Destroyed and back.
	k.set_cores(4, 4)
	k.set_destroyed(true)
	check(k.is_destroyed() and (k.get_node("Wreck") as Node3D).visible and not (k.get_node("Body") as Node3D).visible, "wreck shown")
	eq(_shown(k), [false, false, false, false], "destroyed: every socket dark")
	check(not light.visible, "destroyed: light off")
	eq(k.stocked_count(), 4, "destroyed keeps the pushed state")
	k.set_destroyed(false)
	eq(_shown(k), [true, true, true, true], "repaired: the cores come back")
	check((k.get_node("Body") as Node3D).visible and not (k.get_node("Wreck") as Node3D).visible, "body back")
	k.set_marker(false)
	check(not (k.get_node("Marker") as Node3D).visible, "marker off")
	k.set_marker(true)
	check((k.get_node("Marker") as Node3D).visible, "marker on")
	# Collision-free.
	check(_bodies(k) == 0, "no collision objects (the game adds its own box)")
	# Scale: the bunker reads at mech scale.
	var ab := DepotMeshes.body(false).get_aabb()
	check(ab.size.x >= 5.5 and ab.size.x <= 7.5 and ab.size.z >= 3.8 and ab.size.z <= 5.0, "footprint %s" % ab.size)
	check(ab.size.y >= 3.5 and ab.size.y <= 4.6 and absf(ab.position.y) < 0.01, "height %.2f, origin on the ground" % ab.size.y)
	k.queue_free()


func _shown(k: DepotKiosk) -> Array:
	var out := []
	for i in 4:
		out.append(k.core_shown(i))
	return out


func _count_mi(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is MeshInstance3D:
			c += 1
	return c


func _bodies(n: Node) -> int:
	var c := 1 if n is CollisionObject3D or n is CollisionShape3D else 0
	for ch in n.get_children():
		c += _bodies(ch)
	return c


func _meshes() -> void:
	var all := {"body": DepotMeshes.body(false), "body_wreck": DepotMeshes.body(true), "core": DepotMeshes.core(),
		"marker": DepotMeshes.marker(false), "marker_wreck": DepotMeshes.marker(true)}
	for n: String in all:
		var st := _check_mesh(all[n], "DepotMeshes.%s" % n)
		eq(int(st["open_edges"]), 0, "DepotMeshes.%s: watertight (0 open edges)" % n)
		eq(int(st["inward"]), 0, "DepotMeshes.%s: no face points into its own shell" % n)
	check(DepotMeshes.body(false) == DepotMeshes.body(false) and DepotMeshes.core() == DepotMeshes.core(), "meshes cached")
	# The cell glows: the core has a glow (unshaded) surface in ice blue.
	var core := DepotMeshes.core()
	var has_glow := false
	for s in core.get_surface_count():
		has_glow = has_glow or core.surface_get_name(s) == "glow"
	check(has_glow, "the core's cell is on the glow surface")
	# No green, red or amber anywhere (the repair beam / enemies own those).
	for n: String in all:
		eq(_forbidden(all[n]), 0, "DepotMeshes.%s: no green / red / amber faces" % n)


## The geometry audit's winding / watertight check (tests/test_geometry_audit.gd), plus a coarse inward test: a face
## whose normal points at the mesh's AABB centre while sitting on the AABB's outer skin is wound inside out.
func _check_mesh(mesh: ArrayMesh, label: String) -> Dictionary:
	var stats := {"tris": 0, "bad_winding": 0, "degenerate": 0, "open_edges": 0, "inward": 0}
	var edges := {}
	var ab := mesh.get_aabb()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for t in verts.size() / 3:
			var v0 := verts[t * 3]
			var v1 := verts[t * 3 + 1]
			var v2 := verts[t * 3 + 2]
			stats["tris"] = int(stats["tris"]) + 1
			var cr := (v2 - v0).cross(v1 - v0)
			if cr.length() < 1e-8:
				stats["degenerate"] = int(stats["degenerate"]) + 1
				continue
			if (cr.normalized()).dot(norms[t * 3].normalized()) < 0.95:
				stats["bad_winding"] = int(stats["bad_winding"]) + 1
			var c := (v0 + v1 + v2) / 3.0
			var n := norms[t * 3]
			for ax in 3:
				if absf(n[ax]) > 0.99:
					if (n[ax] > 0.0 and absf(c[ax] - ab.end[ax]) < 1e-3) or (n[ax] < 0.0 and absf(c[ax] - ab.position[ax]) < 1e-3):
						pass
					elif (n[ax] > 0.0 and absf(c[ax] - ab.position[ax]) < 1e-3) or (n[ax] < 0.0 and absf(c[ax] - ab.end[ax]) < 1e-3):
						stats["inward"] = int(stats["inward"]) + 1
			var q := [_q(v0), _q(v1), _q(v2)]
			for e in [[q[0], q[1]], [q[1], q[2]], [q[2], q[0]]]:
				var key := "%s>%s" % [e[0], e[1]]
				edges[key] = int(edges.get(key, 0)) + 1
	for key: String in edges:
		var p := key.split(">")
		var rev := "%s>%s" % [p[1], p[0]]
		var f := int(edges[key])
		var r := int(edges.get(rev, 0))
		if f > r:
			stats["open_edges"] = int(stats["open_edges"]) + (f - r)
	check(int(stats["tris"]) > 0, "%s: has triangles (%d)" % [label, stats["tris"]])
	eq(int(stats["degenerate"]), 0, "%s: zero degenerate triangles" % label)
	eq(int(stats["bad_winding"]), 0, "%s: every triangle winding matches its normal" % label)
	return stats


static func _q(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 2000.0)), int(round(v.y * 2000.0)), int(round(v.z * 2000.0))]


## Faces whose colour is clearly green, red or amber (hue bands, saturated and bright enough to read as such).
func _forbidden(mesh: ArrayMesh) -> int:
	var bad := 0
	for s in mesh.get_surface_count():
		var cols: PackedColorArray = mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR]
		for i in range(0, cols.size(), 3):
			var c := cols[i]
			if c.s < 0.45 or c.v < 0.45:
				continue
			var h := c.h * 360.0
			if (h >= 80.0 and h <= 160.0) or h < 12.0 or h > 345.0 or (h >= 36.0 and h <= 55.0):
				bad += 1
	return bad
