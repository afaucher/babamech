extends RefCounted
## Shared by tests/test_chassis_body.gd: a chassis' visible meshes (a MechSpawn mech standing on a floor, its default
## loadout) as triangle soups per damage component, put into the physics space as one backface-colliding static body per
## component, and the ray coverage of a hit-sphere set against them:
##   under  rays aimed at a random visible point (area-weighted triangle, random direction): the share that meet the mesh
##          but no hit sphere within TOL m of the mesh entry ("shots pass through the visible hull");
##   over   rays aimed at a random point of a hit sphere's silhouette: the share whose first sphere entry is not followed by
##          the mesh within TOL m ("the volume sticks out beyond the mesh");
##   comp   of the covered under-rays, the share whose first sphere is the mesh's own component.
## Mech-local frame (the mech at the origin, unrotated): what PlayerTarget's hit spheres use.

const TOL := 0.75
const LAYER0 := 20          ## physics layer bit of the first component body (one bit per component, above the game's layers)

var comps: Array[String] = []          ## component ids, in body order
var tris := {}                         ## component -> PackedVector3Array (flat triangles)
var bodies: Array[StaticBody3D] = []
var _area_cum := PackedFloat64Array()  ## cumulative triangle areas over every component (area-weighted picks)
var _area_tri: Array = []              ## [component index, triangle index] per entry
var bounds := AABB()
var debug_component := ""              ## coverage() collects the missed mesh points of this component in debug_points
var debug_points := PackedVector3Array()


## The component a model mesh belongs to (its path under the MechModel).
static func component_of(path: String) -> String:
	if path.begins_with("Body/Chassis/Cockpit"):
		return "head"
	if path.begins_with("Body/Chassis/HP_"):
		return path.trim_prefix("Body/Chassis/HP_").get_slice("/", 0)
	if path.begins_with("Body/"):
		return "torso"
	var seg := path.get_slice("/", 0)
	if seg.ends_with("_l"):
		return "leg_l"
	if seg.ends_with("_r"):
		return "leg_r"
	return "torso"


## Gather the triangles of `mech`'s visible model meshes (mech-local), per component.
func gather(mech: MechController) -> void:
	var rig := MechSpawn.rig_of(mech)
	var inv := mech.global_transform.affine_inverse()
	for n in rig.model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var c := component_of(str(rig.model.get_path_to(mi)))
		if not tris.has(c):
			tris[c] = PackedVector3Array()
			comps.append(c)
		var xf := inv * mi.global_transform
		var out: PackedVector3Array = tris[c]
		for s in mi.mesh.get_surface_count():
			var a := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.size() > 0:
				for i in idx.size():
					out.append(xf * v[idx[i]])
			else:
				for p in v:
					out.append(xf * p)
		out.resize(out.size() - out.size() % 3)
		tris[c] = out


## Put one static body per component into `parent`'s world (layer LAYER0 + its index) and index the triangle areas.
func build(parent: Node) -> void:
	var total := 0.0
	var first := true
	for ci in comps.size():
		var t: PackedVector3Array = tris[comps[ci]]
		var sb := StaticBody3D.new()
		sb.collision_layer = 1 << (LAYER0 + ci)
		sb.collision_mask = 0
		var cs := CollisionShape3D.new()
		var sh := ConcavePolygonShape3D.new()
		sh.backface_collision = true
		sh.set_faces(t)
		cs.shape = sh
		sb.add_child(cs)
		sb.set_meta(&"component", comps[ci])
		parent.add_child(sb)
		bodies.append(sb)
		for i in range(0, t.size(), 3):
			var ar := (t[i + 1] - t[i]).cross(t[i + 2] - t[i]).length() * 0.5
			if ar <= 1e-8:
				continue
			total += ar
			_area_cum.append(total)
			_area_tri.append([ci, i])
			for k in 3:
				bounds = AABB(t[i + k], Vector3.ZERO) if first else bounds.expand(t[i + k])
				first = false


func free_bodies() -> void:
	for b in bodies:
		b.queue_free()
	bodies.clear()


func mask_all() -> int:
	var m := 0
	for ci in comps.size():
		m |= 1 << (LAYER0 + ci)
	return m


func mask_of(c: String) -> int:
	var i := comps.find(c)
	return 1 << (LAYER0 + i) if i >= 0 else 0


## A random point on the visible meshes (area-weighted triangle, uniform inside it): [point, component].
func random_point(rng: RandomNumberGenerator) -> Array:
	var x := rng.randf() * _area_cum[_area_cum.size() - 1]
	var k := _area_cum.bsearch(x)
	k = mini(k, _area_tri.size() - 1)
	var ci: int = _area_tri[k][0]
	var ti: int = _area_tri[k][1]
	var t: PackedVector3Array = tris[comps[ci]]
	var a := rng.randf()
	var b := rng.randf()
	if a + b > 1.0:
		a = 1.0 - a
		b = 1.0 - b
	return [t[ti] + (t[ti + 1] - t[ti]) * a + (t[ti + 2] - t[ti]) * b, comps[ci]]


static func random_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf() * TAU
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(a), z, r * sin(a))


## First mesh hit along from -> to: {} or {"t": distance, "component": id, "position"}.
static func mesh_hit(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.hit_back_faces = true
	q.hit_from_inside = true
	var h := space.intersect_ray(q)
	if h.is_empty():
		return {}
	var col: Object = h["collider"]
	return {"t": from.distance_to(h["position"] as Vector3), "component": str(col.get_meta(&"component", "")), "position": h["position"]}


## First sphere entry along the unit ray o + d t: [t, component] (t INF = none). An origin inside a sphere enters at 0.
static func sphere_hit(spheres: Array, o: Vector3, d: Vector3) -> Array:
	var best := INF
	var comp := ""
	for s: Dictionary in spheres:
		var c: Vector3 = s["center"]
		var r := float(s["radius"])
		var oc := o - c
		var b := oc.dot(d)
		var cc := oc.dot(oc) - r * r
		var disc := b * b - cc
		if disc < 0.0:
			continue
		var sq := sqrt(disc)
		var t0 := -b - sq
		var t1 := -b + sq
		if t1 < 0.0:
			continue
		var t := maxf(t0, 0.0)
		if t < best:
			best = t
			comp = str(s["component"])
	return [best, comp]


## Under / over / component coverage of `spheres` ({component, center, radius}) with n rays each (seeded).
func coverage(space: PhysicsDirectSpaceState3D, spheres: Array, n: int, seed_v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var mask := mask_all()
	var reach := 60.0
	var hits := 0
	var miss := 0
	var right := 0
	var per_miss := {}
	var per_hit := {}
	for i in n:
		var pc := random_point(rng)
		var d := random_dir(rng)
		var o: Vector3 = (pc[0] as Vector3) - d * reach
		var mh := mesh_hit(space, o, (pc[0] as Vector3) + d * 1.0, mask)
		if mh.is_empty():
			continue
		hits += 1
		per_hit[mh["component"]] = int(per_hit.get(mh["component"], 0)) + 1
		var sh := sphere_hit(spheres, o, d)
		if float(sh[0]) > float(mh["t"]) + TOL:
			miss += 1
			per_miss[mh["component"]] = int(per_miss.get(mh["component"], 0)) + 1
			if str(mh["component"]) == debug_component:
				debug_points.append(mh["position"])
		elif str(sh[1]) == str(mh["component"]):
			right += 1
	var area := 0.0
	for s: Dictionary in spheres:
		area += float(s["radius"]) * float(s["radius"])
	var out_n := 0
	var over := 0
	for i in n:
		var x := rng.randf() * area
		var pick: Dictionary = spheres[0]
		for s: Dictionary in spheres:
			x -= float(s["radius"]) * float(s["radius"])
			pick = s
			if x <= 0.0:
				break
		var d := random_dir(rng)
		var u := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
		var v := d.cross(u)
		var rr := float(pick["radius"]) * sqrt(rng.randf()) * 0.999
		var a := rng.randf() * TAU
		var p: Vector3 = (pick["center"] as Vector3) + (u * cos(a) + v * sin(a)) * rr
		var o := p - d * reach
		var sh := sphere_hit(spheres, o, d)
		if float(sh[0]) == INF:
			continue
		out_n += 1
		var mh := mesh_hit(space, o, o + d * (reach * 2.0), mask)
		if mh.is_empty() or float(mh["t"]) > float(sh[0]) + TOL:
			over += 1
	var bh := 0
	var bm := 0
	for c: String in PlayerTarget.CORE_COMPONENTS:
		bh += int(per_hit.get(c, 0))
		bm += int(per_miss.get(c, 0))
	return {"under": float(miss) / maxf(hits, 1), "over": float(over) / maxf(out_n, 1),
		"comp": float(right) / maxf(hits - miss, 1), "rays": hits, "per_miss": per_miss, "per_hit": per_hit,
		"body_under": float(bm) / maxf(bh, 1)}


## A floor plus a standing MechSpawn mech of `chassis` (default loadout), settled.
static func spawn(parent: Node, chassis: String, head: String = "chicken", loadout: Dictionary = {}) -> MechController:
	var mech := MechSpawn.make(head, chassis, loadout, 1)
	parent.add_child(mech)
	return mech
