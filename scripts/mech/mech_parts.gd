class_name MechParts
extends RefCounted
## Mech part nodes: heads (chicken, pickle, corn, dog), weapons, and the helpers that place a leg segment between two
## joints. Everything faces -Z (Godot's forward). Pure builders: each returns a fresh Node3D.
## Two looks: the low-poly art meshes (MechMeshes, the default) and the primitive placeholders they replaced (kept
## for comparison: `lowpoly = false`). Node names (Head_<id>, Weapon_<id>) are the same for both.

static var _mats: Dictionary = {}


## A flat, slightly rough material per colour (cached). `alpha` < 1 makes it see-through (the canopy).
static func mat(c: Color, alpha: float = 1.0, emissive: bool = false) -> StandardMaterial3D:
	var key := "%s|%.2f|%s" % [c.to_html(), alpha, emissive]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c, alpha)
	m.roughness = 0.75
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.1
		m.metallic_specular = 0.9
	if emissive:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.5
	_mats[key] = m
	return m


static func box(size: Vector3, c: Color, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat(c)
	mi.position = pos
	return mi


static func sphere(radius: float, c: Color, pos: Vector3 = Vector3.ZERO, segments: int = 10, alpha: float = 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = segments
	sm.rings = maxi(segments >> 1, 3)
	mi.mesh = sm
	mi.material_override = mat(c, alpha)
	mi.position = pos
	return mi


## A cylinder along -Z (a barrel) when `forward`, else upright. top 0 = a cone.
static func cylinder(radius: float, length: float, c: Color, pos: Vector3 = Vector3.ZERO, forward: bool = true,
		top: float = -1.0, segments: int = 8) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = radius
	cm.top_radius = radius if top < 0.0 else top
	cm.height = length
	cm.radial_segments = segments
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = mat(c)
	mi.position = pos
	if forward:
		mi.rotation = Vector3(-PI / 2.0, 0.0, 0.0)   # the cylinder's +Y (its top) now points -Z
	return mi


static func capsule(radius: float, height: float, c: Color, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	cm.radial_segments = 10
	cm.rings = 3
	mi.mesh = cm
	mi.material_override = mat(c)
	mi.position = pos
	return mi


## Put a unit-box MeshInstance3D between `a` and `b` (its local Y along a->b) with cross-section `t` x `depth`.
static func span(mi: MeshInstance3D, a: Vector3, b: Vector3, t: float, depth: float = -1.0) -> void:
	var d := b - a
	var length := maxf(d.length(), 0.001)
	var y := d / length
	var ref := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var z := ref.cross(y).normalized()
	var x := y.cross(z)
	mi.transform = Transform3D(Basis(x * t, y * length, z * (t if depth < 0.0 else depth)), (a + b) * 0.5)


## Put a low-poly leg segment (origin at its upper joint, hanging along -Y for `rest` units) between joints `a` (upper)
## and `b` (lower): stretched along its length to fit, scaled `s` across, mirrored in X for the left leg.
static func aim(node: Node3D, a: Vector3, b: Vector3, rest: float, s: float, mirror: bool = false) -> void:
	var d := a - b
	var length := maxf(d.length(), 0.001)
	var y := d / length
	var x := (Vector3.RIGHT - y * y.dot(Vector3.RIGHT)).normalized()
	var z := x.cross(y)
	node.transform = Transform3D(Basis(x * (-s if mirror else s), y * (length / rest), z * s), a)


static func unit_box(c: Color) -> MeshInstance3D:
	return box(Vector3.ONE, c)


static func _eyes(root: Node3D, y: float, z: float, spread: float, r: float) -> void:
	for s in [-1.0, 1.0]:
		root.add_child(sphere(r, Color(1, 1, 1), Vector3(s * spread, y, z), 8))
		root.add_child(sphere(r * 0.5, Color(0.05, 0.05, 0.05), Vector3(s * spread, y, z - r * 0.7), 6))


## The oversized organic head, about 1 m tall at scale 1, origin at its base (where it sits in the cockpit).
static func head(id: String, scale: float = 1.0, lowpoly: bool = true) -> Node3D:
	var root := Node3D.new()
	root.name = "Head_" + id
	if lowpoly:
		root.add_child(MechMeshes.instance("head_" + (id if id in MechMeshes.HEADS else "chicken")))
		root.scale = Vector3.ONE * scale
		return root
	var col: Color = (MechCatalog.HEADS.get(id, MechCatalog.HEADS["chicken"]) as Dictionary)["color"]
	match id:
		"pickle":
			root.add_child(capsule(0.36, 1.3, col, Vector3(0, 0.65, 0)))
			var bump := col.darkened(0.25)
			for i in 7:
				var a := float(i) * 2.4
				root.add_child(sphere(0.06, bump, Vector3(cos(a) * 0.34, 0.25 + float(i) * 0.13, sin(a) * 0.34), 6))
			_eyes(root, 0.95, -0.3, 0.13, 0.08)
		"corn":
			root.add_child(capsule(0.33, 1.25, col, Vector3(0, 0.66, 0)))
			var kern := col.darkened(0.12)
			for row in 4:
				for i in 6:
					var a := float(i) * TAU / 6.0 + float(row) * 0.5
					root.add_child(box(Vector3(0.08, 0.08, 0.04), kern, Vector3(cos(a) * 0.33, 0.45 + float(row) * 0.16, sin(a) * 0.33)))
			var husk := Color(0.36, 0.58, 0.2)
			for i in 3:
				var leaf := MeshInstance3D.new()
				var pm := PrismMesh.new()
				pm.size = Vector3(0.45, 0.8, 0.05)
				leaf.mesh = pm
				leaf.material_override = mat(husk)
				var a := float(i) * TAU / 3.0 + 0.4
				leaf.position = Vector3(cos(a) * 0.3, 0.38, sin(a) * 0.3)
				leaf.rotation = Vector3(0.0, -a + PI / 2.0, 0.25)
				root.add_child(leaf)
			_eyes(root, 1.0, -0.28, 0.12, 0.08)
		"dog":
			root.add_child(sphere(0.48, col, Vector3(0, 0.55, 0), 10))
			root.add_child(box(Vector3(0.36, 0.3, 0.42), col.lightened(0.15), Vector3(0, 0.42, -0.5)))
			root.add_child(sphere(0.09, Color(0.08, 0.06, 0.05), Vector3(0, 0.52, -0.72), 6))
			var ear := col.darkened(0.35)
			for s in [-1.0, 1.0]:
				var e := box(Vector3(0.12, 0.5, 0.3), ear, Vector3(s * 0.48, 0.55, 0.05))
				e.rotation = Vector3(0.0, 0.0, s * 0.25)
				root.add_child(e)
			_eyes(root, 0.72, -0.4, 0.17, 0.08)
		_:   # chicken
			root.add_child(sphere(0.5, col, Vector3(0, 0.55, 0), 10))
			var red := Color(0.86, 0.12, 0.1)
			for i in 3:
				root.add_child(box(Vector3(0.08, 0.2, 0.14), red, Vector3(0, 1.08 + (0.04 if i == 1 else 0.0), -0.12 + float(i) * 0.12)))
			root.add_child(cylinder(0.13, 0.34, Color(0.98, 0.65, 0.15), Vector3(0, 0.5, -0.62), true, 0.0))
			root.add_child(sphere(0.08, red, Vector3(0, 0.3, -0.5), 6))
			_eyes(root, 0.7, -0.42, 0.2, 0.08)
	root.scale = Vector3.ONE * scale
	return root


## A weapon pointing -Z, origin at its mount point.
static func weapon(id: String, lowpoly: bool = true) -> Node3D:
	var root := Node3D.new()
	root.name = "Weapon_" + id
	if lowpoly and id in MechMeshes.WEAPONS:
		root.add_child(MechMeshes.instance("weapon_" + id))
		return root
	var gun := Color(0.25, 0.27, 0.3)
	match id:
		"laser":
			root.add_child(box(Vector3(0.22, 0.22, 0.5), gun, Vector3(0, 0, -0.1)))
			root.add_child(cylinder(0.06, 0.9, gun.lightened(0.2), Vector3(0, 0, -0.75)))
			var tip := cylinder(0.08, 0.08, Color(1.0, 0.2, 0.15), Vector3(0, 0, -1.22))
			tip.material_override = mat(Color(1.0, 0.2, 0.15), 1.0, true)
			root.add_child(tip)
		"autocannon":
			root.add_child(box(Vector3(0.32, 0.3, 0.6), gun, Vector3(0, 0, -0.15)))
			root.add_child(cylinder(0.09, 0.8, gun.darkened(0.3), Vector3(0, 0.02, -0.8)))
		"rockets":
			root.add_child(box(Vector3(0.55, 0.45, 0.6), Color(0.45, 0.48, 0.38), Vector3(0, 0, -0.2)))
			for ix in 2:
				for iy in 2:
					root.add_child(cylinder(0.08, 0.05, Color(0.08, 0.08, 0.08), Vector3(-0.13 + ix * 0.26, -0.1 + iy * 0.2, -0.51)))
		"flamer":
			root.add_child(sphere(0.18, Color(0.8, 0.3, 0.1), Vector3(0, 0.05, 0.05), 8))
			root.add_child(cylinder(0.07, 0.6, gun, Vector3(0, 0, -0.4), true, 0.11))
		"mortar":
			var tube := cylinder(0.16, 0.9, gun, Vector3(0, 0.35, -0.1), false)
			tube.rotation = Vector3(-0.6, 0, 0)   # leans forward, muzzle up
			root.add_child(box(Vector3(0.5, 0.2, 0.5), gun.darkened(0.2), Vector3(0, 0, 0)))
			root.add_child(tube)
	return root
