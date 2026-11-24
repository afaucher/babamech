class_name EnemyMeshes
extends RefCounted
## Low-poly MeshKit builders & invader livery for every enemy unit (docs/design/enemies.md §2, §7).
## Concept "repainted civic": the habitat's own civil-defence robots repainted in the invaders' slate / brick livery (L1),
## municipal details (service lamps, number plates, hatches, hazard bands) still showing under the paint, plus a small
## "Descent" emblem stencil. Cosmetic only: flat-shaded vertex colours using MechMeshes.materials() ([matte, glow]),
## cached by part id. Every part is a set of closed primitives (tests/test_geometry_audit.gd: watertight, outward winding).
## Detail level: the "B" pass of docs/design/enemy-detail/ (adopted 2026-11-22): plates on the parts' own facets over a
## dark slate under-plate (panel line), hooded optics, collars, hub caps, hinges, pistons, cables, slatted vents, lugs,
## nothing thinner than ~2.5 cm (helpers _panel / _vent / _piston / _hose / _optic_hood). Includes the gunship_* and
## dropship_* parts (EnemyGunship / EnemyDropDrone switch to them from their placeholders automatically).

const ARMOR_DARK := Color("6b6a6c")     ## L1 body slate: mid value, findable but not trivially spotted in the warm city
const ARMOR_PLATE := Color("807d7c")    ## L1 lighter warm-grey bevel plates
const STEEL := Color("939089")          ## L1 bare steel: joints, treads, barrels, lamp housings
const TRIM_RED := Color("a2453a")       ## L1 invader brick: stripes, cheek plates, the Descent arrow
const OPTIC_GLOW := Color("ff4a36")     ## unshaded red-orange eyes / sensors (weak points), telegraphs
const VENT_GLOW := Color("ff8a3a")      ## unshaded orange heat-sink radiator fins (weak points)
const SLATE := Color("4a4a4e")          ## dark slate accent: emblem backing plates, hazard bands, seams, handles
const CIVIC_CREAM := Color("d8ccb0")    ## old civic underpaint: number plates, hazard stripes, lamp lenses, emblem bars
const LAMP_AMBER := Color("c08a44")     ## matte (unlit) amber municipal service-lamp lenses
const CHARRED := Color(0.08, 0.08, 0.09)        ## destroyed part / wreck hull (far below the L1 body: wrecks read dead)
const CHARRED_EDGE := Color(0.16, 0.15, 0.15)   ## torn edges / exposed metal on wrecks
const FLASH_COL := Color(1.0, 0.72, 0.62)       ## brief hit-flash overlay tint (unshaded: brighter than any livery face)

static var _cache: Dictionary = {}
static var _flash_mat: StandardMaterial3D
static var _charred_mat: StandardMaterial3D
static var _scanner_mat: StandardMaterial3D


static func mesh(part: String) -> ArrayMesh:
	if _cache.has(part):
		return _cache[part]
	var rid := trooper_rig_id(part)
	if not rid.is_empty():
		var rk := MeshKit.new()
		_trooper(rk, rid[0], rid[1], rid[2])
		_cache[part] = rk.commit(MechMeshes.materials())
		return _cache[part]
	var tid := trooper_id(part)
	if not tid.is_empty() and part != trooper_part(tid[0], tid[1]):   # "trooper_rifle" / "trooper_at" = variant 0
		_cache[part] = mesh(trooper_part(tid[0], tid[1]))
		return _cache[part]
	var k := MeshKit.new()
	match part:
		"turret_base": _turret_base(k)
		"turret_gun": _turret_gun(k)
		"turret_sniper_gun": _turret_sniper_gun(k)
		"turret_missile_gun": _turret_missile_gun(k)
		"turret_gun_wreck": _turret_gun_wreck(k)
		"strider_chassis": _strider_chassis(k)
		"strider_breacher_chassis": _strider_breacher_chassis(k)
		"strider_sensor": _strider_sensor(k)
		"strider_leg": _strider_leg(k)
		"strider_thigh": _strider_thigh(k)
		"strider_shin": _strider_shin(k)
		"strider_foot": _strider_foot(k)
		"tank_hull": _tank_hull(k)
		"tank_turret": _tank_turret(k)
		"tank_turret_wreck": _tank_turret_wreck(k)
		"tank_vents": _tank_vents(k)
		"drone_hull": _drone_hull(k)
		"drone_optic": _drone_optic(k)
		"drone_cone": _drone_cone(k)
		"debris_plate": _debris_plate(k)
		"debris_chunk": _debris_chunk(k)
		"rupture_core": _rupture_core(k)
		"gunship_hull": _gunship_hull(k)
		"gunship_pods": _gunship_pods(k)
		"gunship_thrusters": _gunship_thrusters(k)
		"dropship_hull": _dropship_hull(k)
		"dropship_rotors": _dropship_rotors(k)
		"dropship_bay": _dropship_bay(k)
		_:
			if tid.is_empty():
				k.box(Vector3.ONE, ARMOR_DARK)
			else:
				_trooper(k, tid[0], tid[1])
	var m := k.commit(MechMeshes.materials())
	_cache[part] = m
	return m


static func instance(part: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = mesh(part)
	return mi


## Cached unshaded hit-flash overlay material (never mutates shared MechMeshes materials).
static func flash_material() -> StandardMaterial3D:
	if _flash_mat == null:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_mat.albedo_color = FLASH_COL
	return _flash_mat


## Cached lit matte charcoal material for charred surviving wreck hulks (facets still read under sunlight).
static func charred_material() -> StandardMaterial3D:
	if _charred_mat == null:
		_charred_mat = StandardMaterial3D.new()
		_charred_mat.albedo_color = Color(0.11, 0.11, 0.125)
		_charred_mat.roughness = 0.94
		_charred_mat.metallic = 0.12
	return _charred_mat


## Cached translucent unshaded scanner cone material for Patrol Scout Drones.
static func scanner_material() -> StandardMaterial3D:
	if _scanner_mat == null:
		_scanner_mat = StandardMaterial3D.new()
		_scanner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_scanner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_scanner_mat.albedo_color = Color(1.0, 0.40, 0.21, 0.22)   # between OPTIC_GLOW and VENT_GLOW
		_scanner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _scanner_mat


## Pre-cache destruction & flame meshes once at setup so first kill in combat causes zero frame spike.
static func prewarm() -> void:
	for p: String in ["debris_plate", "debris_chunk", "rupture_core", "turret_gun_wreck", "tank_turret_wreck",
			"turret_sniper_gun", "turret_missile_gun", "strider_breacher_chassis", "drone_hull", "drone_optic", "drone_cone",
			"trooper_rifle", "trooper_at", "gunship_hull", "gunship_pods", "gunship_thrusters", "dropship_hull",
			"dropship_rotors", "dropship_bay"]:
		mesh(p)
	for p: String in trooper_parts():   # all 24 look variants (~25 ms in all, ~0.4 MB)
		mesh(p)
	charred_material()
	flash_material()
	scanner_material()
	LowPolyFlame.jet()
	for b: int in [LowPolyFlame.HOT, LowPolyFlame.WARM, LowPolyFlame.COOL]:
		LowPolyFlame.tongue(b)
	for v in 4:
		CombatMeshes.scorch(ImpactFx.SCORCH_COLOR, v)
		CombatMeshes.ember_scorch(v)
	CombatMeshes.ico(ImpactFx.SMOKE)
	CombatMeshes.shard(ImpactFx.RUBBLE_COLOR)


# --- Civic detail helpers (every one emits closed primitives) ---------------------------------------------

## A frame on a surface: origin `pos`, local +Z along the outward `normal`, local +Y as close to `up` as possible.
static func _face_xf(pos: Vector3, normal: Vector3, up: Vector3 = Vector3.UP) -> Transform3D:
	var z := normal.normalized()
	var x := up.cross(z)
	if x.length_squared() < 1e-6:
		x = Vector3.FORWARD.cross(z)
	x = x.normalized()
	return Transform3D(Basis(x, z.cross(x), z), pos)


## A convex outline (local x, y) extruded from z0 to z1: a closed prism.
static func _prism(k: MeshKit, pts: Array, z0: float, z1: float, col: Color) -> void:
	var a := PackedVector3Array()
	var b := PackedVector3Array()
	for p: Vector2 in pts:
		a.append(Vector3(p.x, p.y, z0))
		b.append(Vector3(p.x, p.y, z1))
	k.loft([a, b], col)


## Invader "Descent" stencil (art/renders/banner_r1/b9_descent_s4242.png), `s` m across, on a surface at `pos` facing
## `normal`: a broad brick arrowhead pointing diagonally down-left, a thin slit up its middle, three cream bars trailing
## from its back toward the upper right; on a dark slate backing plate when `plate` (echoes the slate / brick / cream
## banner). Stands 2-5 cm proud. 64 triangles with the plate, 52 without.
static func _emblem(k: MeshKit, pos: Vector3, normal: Vector3, s: float, plate: bool = true, up: Vector3 = Vector3.UP) -> void:
	k.push(_face_xf(pos, normal, up))
	var z0 := -0.02
	if plate:
		k.box(Vector3(s, s, 0.05), SLATE, Vector3(0.0, 0.0, -0.005))
		z0 = 0.0
	var c := cos(-PI * 0.25)
	var sn := sin(-PI * 0.25)
	var rot := func(x: float, y: float) -> Vector2:   # authored pointing down (-y), turned 45 deg to point down-left
		return Vector2(x * c - y * sn - 0.03, x * sn + y * c - 0.03) * s
	_prism(k, [rot.call(-0.30, 0.0), rot.call(0.30, 0.0), rot.call(0.0, -0.52)], z0, z0 + 0.035, TRIM_RED)
	_prism(k, [rot.call(-0.035, 0.0), rot.call(0.035, 0.0), rot.call(0.0, -0.30)], z0 + 0.02, z0 + 0.045,
		SLATE)
	for i in 3:
		var x := (float(i) - 1.0) * 0.17
		var top := 0.47 if i == 1 else 0.40
		_prism(k, [rot.call(x - 0.045, 0.05), rot.call(x + 0.045, 0.05), rot.call(x + 0.045, top), rot.call(x - 0.045, top)],
			z0, z0 + 0.03, CIVIC_CREAM)
	k.pop()


## Hazard band `w` x `h` on a surface: a slate strip with `n` slanted cream stripes (civic bumper / foot markings).
static func _hazard(k: MeshKit, pos: Vector3, normal: Vector3, w: float, h: float, n: int, up: Vector3 = Vector3.UP) -> void:
	k.push(_face_xf(pos, normal, up))
	k.box(Vector3(w, h, 0.05), SLATE, Vector3(0.0, 0.0, 0.0))
	var sw := w / (2.0 * float(n))
	var sk := h * 0.6
	for i in n:
		var x0 := -w * 0.5 + (w - sk) * (float(i) + 0.25) / float(n)
		_prism(k, [Vector2(x0, -h * 0.5), Vector2(x0 + sw, -h * 0.5), Vector2(x0 + sw + sk, h * 0.5), Vector2(x0 + sk, h * 0.5)],
			0.0, 0.04, CIVIC_CREAM)
	k.pop()


## Municipal lamp: a steel housing `size` (x, y, depth) half sunk into the surface, a matte lens on its face.
static func _lamp(k: MeshKit, pos: Vector3, normal: Vector3, size: Vector3, lens: Color, up: Vector3 = Vector3.UP) -> void:
	k.push(_face_xf(pos, normal, up))
	k.box(size, STEEL, Vector3.ZERO)
	k.box(Vector3(size.x * 0.74, size.y * 0.62, 0.04), lens, Vector3(0.0, 0.0, size.z * 0.5))
	k.pop()


## Civic unit-number plate: a cream panel with a slate number block.
static func _plate(k: MeshKit, pos: Vector3, normal: Vector3, w: float, h: float, up: Vector3 = Vector3.UP) -> void:
	k.push(_face_xf(pos, normal, up))
	k.box(Vector3(w, h, 0.04), CIVIC_CREAM, Vector3.ZERO)
	k.box(Vector3(w * 0.56, h * 0.6, 0.03), SLATE, Vector3(w * 0.08, 0.0, 0.025))
	k.pop()


## Roof service light bar on a horizontal top at `pos` (base of the bar), `w` m wide along local X, matte amber lenses.
static func _light_bar(k: MeshKit, pos: Vector3, w: float) -> void:
	k.box(Vector3(w, 0.08, 0.28), STEEL, pos + Vector3(0.0, 0.04, 0.0))
	k.box(Vector3(w * 0.84, 0.14, 0.22), LAMP_AMBER, pos + Vector3(0.0, 0.15, 0.0))


## Thin antenna whip from `a` to `b` with a small tip knob.
static func _whip(k: MeshKit, a: Vector3, b: Vector3, r: float = 0.035) -> void:
	k.seg(a, b, Vector2(r, r), Vector2(r * 0.5, r * 0.5), 4, STEEL, MeshKit.SQUARE)
	k.box(Vector3(r * 2.6, r * 2.6, r * 2.6), SLATE, b)


## Raised plate `w` x `h` on a facet at `pos` facing `normal`, on a dark slate under-plate `rim` wider all round (the
## panel line). The plate stands t - 1 cm proud, the under-plate 1 cm.
static func _panel(k: MeshKit, pos: Vector3, normal: Vector3, w: float, h: float, col: Color, up: Vector3 = Vector3.UP,
		t: float = 0.05, rim: float = 0.05) -> void:
	k.push(_face_xf(pos, normal, up))
	k.box(Vector3(w + rim * 2.0, h + rim * 2.0, 0.03), SLATE, Vector3(0.0, 0.0, -0.005))
	k.box(Vector3(w, h, t), col, Vector3(0.0, 0.0, t * 0.5 - 0.01))
	k.pop()


## Vent panel: a slate frame `w` x `h` with `n` raised horizontal slats (stands 5 cm proud).
static func _vent(k: MeshKit, pos: Vector3, normal: Vector3, w: float, h: float, n: int, up: Vector3 = Vector3.UP,
		slat: Color = ARMOR_PLATE) -> void:
	k.push(_face_xf(pos, normal, up))
	k.box(Vector3(w, h, 0.04), SLATE, Vector3.ZERO)
	var pitch := h / float(n)
	for i in n:
		var y := -h * 0.5 + pitch * (float(i) + 0.5)
		k.box(Vector3(w * 0.82, maxf(pitch * 0.45, 0.03), 0.04), slat, Vector3(0.0, y, 0.03))
	k.pop()


## Hydraulic piston from a to b: a barrel over the first 55 % and a thinner steel rod.
static func _piston(k: MeshKit, a: Vector3, b: Vector3, r: float, n: int = 6, col: Color = SLATE) -> void:
	var m := a.lerp(b, 0.55)
	k.tube(a, m, r, n, col)
	k.tube(m.lerp(a, 0.08), b, r * 0.55, n, STEEL)


## Hose / cable run through `pts` (closed 4-sided pieces).
static func _hose(k: MeshKit, pts: Array, r: float, col: Color = SLATE) -> void:
	for i in pts.size() - 1:
		k.seg(pts[i], pts[i + 1], Vector2(r, r), Vector2(r, r), 4, col)


## Steel brow hood over an optic bar plus a steel side frame each side of it. `c` = optic centre, `w` x `h` its size,
## `face_z` its front (the hood reaches `reach` further forward).
static func _optic_hood(k: MeshKit, c: Vector3, w: float, h: float, face_z: float, reach: float = 0.2) -> void:
	var zc := face_z - reach * 0.5 + 0.06
	k.box(Vector3(w + 0.2, 0.08, reach + 0.12), STEEL, Vector3(c.x, c.y + h * 0.5 + 0.06, zc))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, h + 0.12, reach + 0.04), STEEL, Vector3(c.x + side * (w * 0.5 + 0.05), c.y, zc - 0.04))


# --- Enforcer Turret (4.8 W x 4.8 D x 5.6 H) ---------------------------------------------------------------

static func _turret_base(k: MeshKit) -> void:
	# Broad octagonal armored bunker plinth (y = 0..1.45), neck ring up to y = 2.15.
	k.lathe([Vector2(2.4, 0.0), Vector2(2.35, 0.55), Vector2(1.95, 1.45), Vector2(1.45, 1.55)], 8,
		[ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK], true, true)
	k.lathe([Vector2(1.25, 1.45), Vector2(1.15, 2.15)], 8, STEEL, false, true)
	# Four diagonal armored buttress feet with crimson stripes (4.8 m span).
	for i in 4:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 45.0 + 90.0 * i, 0)))
		k.box(Vector3(0.95, 1.15, 1.3), ARMOR_DARK, Vector3(0.0, 0.58, -1.85))
		k.box(Vector3(1.05, 0.24, 0.65), TRIM_RED, Vector3(0.0, 0.92, -2.05))
		k.box(Vector3(0.7, 0.22, 0.5), STEEL, Vector3(0.0, 0.11, -2.35))
		_hazard(k, Vector3(0.0, 0.47, -2.5), Vector3.FORWARD, 0.82, 0.34, 2)
		# An anchor ram from each foot's top up onto the plinth (slate barrel, steel rod).
		_piston(k, Vector3(0.0, 1.1, -2.34), Vector3(0.0, 1.5, -1.52), 0.12, 4)
		k.pop()
	# Service hatch on the front flat of the plinth (on its 22 deg slope) with a slate pull handle.
	k.push(MeshKit.xf(Vector3(0.0, 0.98, -1.99), Vector3(22.3, 0.0, 0.0)))
	k.box(Vector3(0.82, 0.56, 0.1), STEEL)
	k.box(Vector3(0.34, 0.07, 0.08), SLATE, Vector3(0.0, -0.14, -0.07))
	# A dark frame round the hatch and a hinge barrel along its top edge.
	k.box(Vector3(0.98, 0.72, 0.06), SLATE)
	k.tube(Vector3(-0.34, 0.31, -0.06), Vector3(0.34, 0.31, -0.06), 0.06, 6, STEEL)
	k.pop()
	# Status corner pips on the plinth rim.
	k.glow = true
	for i in 4:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 90.0 * i, 0)))
		k.box(Vector3(0.55, 0.14, 0.1), OPTIC_GLOW, Vector3(0.0, 1.15, -2.02))
		k.pop()
	k.glow = false
	# A vent panel on the rear flat, raised access plates on the side flats, a steel collar round the neck foot.
	_vent(k, Vector3(0.0, 0.8, 2.06), Vector3(0.0, 0.379, 0.925), 1.0, 0.4, 3)
	for side: float in [-1.0, 1.0]:
		_panel(k, Vector3(side * 2.06, 0.8, 0.0), Vector3(side * 0.925, 0.379, 0.0), 0.9, 0.36, ARMOR_DARK)
	k.lathe([Vector2(1.36, 1.47), Vector2(1.36, 1.64)], 8, STEEL, true, true)


## Rotating turret head + twin heavy blaster barrels + tall crimson optic mast (origin at pivot y = 2.2 m, faces -Z).
static func _turret_gun(k: MeshKit) -> void:
	# Main angular turret drum (3.6 W x 2.0 H x 3.6 D, centred at y = 1.05 -> world y = 2.2..4.25).
	k.loft([
		MeshKit.ring(Vector3(0, 0.1, 0.15), 1.65, 1.75, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 1.15, 0.1), 1.82, 1.85, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 2.05, 0.2), 1.4, 1.45, 8, "y", 3.2),
	], [ARMOR_DARK, ARMOR_PLATE])
	# Bold crimson side cheek plates (unmistakable from any angle).
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.32, 1.15, 2.3), TRIM_RED, Vector3(side * 1.82, 1.1, 0.1))
		k.box(Vector3(0.24, 0.65, 1.2), ARMOR_DARK, Vector3(side * 1.92, 0.95, -0.35))
	# Rear counterweight / radiator block.
	k.box(Vector3(2.2, 1.25, 0.85), ARMOR_DARK, Vector3(0.0, 1.1, 1.95))
	k.glow = true
	k.box(Vector3(1.6, 0.45, 0.16), VENT_GLOW, Vector3(0.0, 1.1, 2.38))
	k.glow = false
	# Tall crimson optic mast & antenna fin (peaks at y = +3.4 -> world 5.6 m!).
	k.box(Vector3(1.35, 0.95, 1.1), ARMOR_DARK, Vector3(0.0, 2.5, -0.15))
	k.box(Vector3(1.45, 0.22, 1.15), TRIM_RED, Vector3(0.0, 3.02, -0.15))
	k.box(Vector3(0.16, 0.95, 0.45), ARMOR_PLATE, Vector3(0.55, 2.95, 0.45))
	k.glow = true
	k.box(Vector3(1.05, 0.42, 0.18), OPTIC_GLOW, Vector3(0.0, 2.52, -0.72))
	k.glow = false
	# Twin heavy blaster barrels extending to z = -3.8 m.
	for side: float in [-1.0, 1.0]:
		var bx := side * 0.78
		k.box(Vector3(0.55, 0.65, 1.3), STEEL, Vector3(bx, 1.05, -1.6))
		k.tube(Vector3(bx, 1.05, -2.0), Vector3(bx, 1.05, -3.55), 0.22, 8, ARMOR_DARK)
		k.tube(Vector3(bx, 1.05, -3.45), Vector3(bx, 1.05, -3.8), 0.28, 8, STEEL)
		k.glow = true
		k.tube(Vector3(bx, 1.05, -3.78), Vector3(bx, 1.05, -3.86), 0.17, 6, OPTIC_GLOW)
		k.glow = false
	_turret_civic(k, 1.98, 1.15, 0.75, 2.375)
	# Old municipal service light bar on the mast cap (clear of the dorsal fin).
	_light_bar(k, Vector3(-0.2, 3.13, -0.15), 1.0)
	_turret_head_detail(k, 1.8, 1.1, 0.1, Vector3(0.26, 1.27, 2.42), Vector3(-0.45, 2.04, 0.9), 1.725, 1.95, 0.8)
	_optic_hood(k, Vector3(0.0, 2.52, -0.72), 1.05, 0.42, -0.81)
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.78, 1.05, -2.5), Vector3(side * 0.78, 1.05, -2.68), 0.3, 6, SLATE)   # barrel clamp collar


## Shared turret-head civic markings: a Descent stencil on each cheek plate's outer face (x = +-cheek_x, at y, z) and a
## unit-number plate above the rear radiator (rear face at z = rear_z).
static func _turret_civic(k: MeshKit, cheek_x: float, y: float, z: float, rear_z: float) -> void:
	for side: float in [-1.0, 1.0]:
		_emblem(k, Vector3(side * cheek_x, y, z), Vector3(side, 0.0, 0.0), 0.72)
	_plate(k, Vector3(0.0, 1.55, rear_z), Vector3.BACK, 0.7, 0.2)


## Detail shared by the three turret heads: a slate under-plate behind each brick cheek plate (cheek centre x = +-cx,
## y, z; under-plate size `us`), a round commander hatch with a hinge block on the drum top at `hatch`, and two steel
## lifting lugs on the rear radiator's top (top y, centre z, lug x).
static func _turret_head_detail(k: MeshKit, cx: float, y: float, z: float, us: Vector3, hatch: Vector3, rad_top: float,
		rad_z: float, lug_x: float) -> void:
	for side: float in [-1.0, 1.0]:
		k.box(us, SLATE, Vector3(side * cx, y, z))
		k.box(Vector3(0.22, 0.16, 0.34), STEEL, Vector3(side * lug_x, rad_top + 0.07, rad_z))
	k.tube(hatch, hatch + Vector3(0.0, 0.09, 0.0), 0.32, 8, STEEL)
	k.box(Vector3(0.3, 0.1, 0.14), SLATE, hatch + Vector3(0.0, 0.1, 0.34))


static func _turret_gun_wreck(k: MeshKit) -> void:
	k.lathe([Vector2(1.4, 0.0), Vector2(1.2, 0.55), Vector2(0.7, 0.75)], 8, CHARRED, true, true)
	k.box(Vector3(0.6, 0.45, 1.4), CHARRED, Vector3(-0.4, 0.45, -0.5))
	# Snapped barrel stub drooping off the front, a torn cheek plate leaning on the drum, a buckled hatch lid.
	k.tube(Vector3(0.45, 0.42, -0.7), Vector3(0.62, 0.28, -1.75), 0.2, 6, CHARRED_EDGE)
	k.push(MeshKit.xf(Vector3(1.05, 0.5, 0.3), Vector3(8.0, -15.0, 28.0)))
	k.box(Vector3(0.16, 0.8, 1.3), CHARRED_EDGE)
	k.pop()
	k.push(MeshKit.xf(Vector3(-0.2, 0.8, 0.35), Vector3(-14.0, 20.0, 9.0)))
	k.box(Vector3(0.7, 0.08, 0.55), CHARRED)
	k.pop()


# --- Hound Skirmisher (3.8 W x 4.2 L x 5.2 H) --------------------------------------------------------------

## Pelvis + hunched wedge chassis + wide armored shoulders + carbine + dorsal fins (origin at hip y = 2.6 m).
static func _strider_chassis(k: MeshKit) -> void:
	# Pelvis & hip axle.
	k.box(Vector3(1.5, 0.65, 1.3), STEEL, Vector3(0.0, 0.0, 0.1))
	k.tube(Vector3(-1.35, 0.0, 0.0), Vector3(1.35, 0.0, 0.0), 0.24, 8, ARMOR_DARK)
	# Forward-canting angular wedge torso (y = 0.35..2.05 -> world 2.95..4.65 m).
	k.loft([
		MeshKit.ring(Vector3(0, 0.95, 1.35), 1.05, 0.65, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 1.25, 0.25), 1.45, 0.92, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 1.15, -1.05), 1.2, 0.72, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 0.95, -1.75), 0.65, 0.42, 6, "z", 2.8),
	], [ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK])
	# Wide angular shoulder pauldrons (3.8 m total width!) with bold crimson stripes.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 1.55, 1.42, -0.15), Vector3(0.0, 0.0, -side * 18.0)))
		k.box(Vector3(0.78, 0.95, 2.15), ARMOR_DARK)
		k.box(Vector3(0.84, 0.28, 1.75), TRIM_RED, Vector3(0.0, 0.24, -0.05))
		_emblem(k, Vector3(side * 0.39, -0.17, 0.35), Vector3(side, 0.0, 0.0), 0.52, false)
		# A steel cap plate on the pauldron's front face.
		_panel(k, Vector3(0.0, -0.08, -1.075), Vector3.FORWARD, 0.54, 0.58, STEEL)
		k.pop()
	# Civic headlights either side of the carbine, unit plate over the rear vent.
	for side: float in [-1.0, 1.0]:
		_lamp(k, Vector3(side * 0.4, 0.8, -1.76), Vector3.FORWARD, Vector3(0.24, 0.2, 0.2), CIVIC_CREAM)
	_plate(k, Vector3(0.0, 1.38, 1.36), Vector3.BACK, 0.5, 0.16)
	# Twin dorsal antenna fins rising to +2.6 m above pelvis (= 5.2 m total height!).
	for side: float in [-1.0, 1.0]:
		k.seg(Vector3(side * 0.75, 1.85, 0.55), Vector3(side * 0.95, 2.6, 1.15), Vector2(0.12, 0.24), Vector2(0.05, 0.08),
			4, ARMOR_PLATE, MeshKit.SQUARE)
		k.box(Vector3(0.16, 0.32, 0.38), TRIM_RED, Vector3(side * 0.85, 2.25, 0.85))
	# Rear glowing vent slits.
	k.glow = true
	k.box(Vector3(1.15, 0.32, 0.14), VENT_GLOW, Vector3(0.0, 1.0, 1.42))
	k.glow = false
	# Underslung rapid pulse carbine (muzzle at z = -2.45 m).
	k.box(Vector3(0.55, 0.45, 1.2), STEEL, Vector3(0.0, 0.5, -1.25))
	k.tube(Vector3(0.0, 0.48, -1.6), Vector3(0.0, 0.48, -2.4), 0.15, 6, ARMOR_DARK)
	k.glow = true
	k.tube(Vector3(0.0, 0.48, -2.38), Vector3(0.0, 0.48, -2.48), 0.11, 6, OPTIC_GLOW)
	k.glow = false
	_strider_detail(k, 1.95, Vector3(0.0, 0.978, -0.208), 1.36)
	k.tube(Vector3(0.0, 0.48, -1.92), Vector3(0.0, 0.48, -2.1), 0.2, 6, SLATE)     # carbine barrel collar
	k.box(Vector3(0.22, 0.3, 0.5), SLATE, Vector3(-0.38, 0.5, -1.15))              # carbine ammo box


## Detail shared by both strider chassis: an access hatch (steel plate, slate rim, hinge barrel) on the torso's front
## top slope (hatch centre y at z = -0.2, slope normal) and a slate frame round the rear unit plate (rear face z).
static func _strider_detail(k: MeshKit, hatch_y: float, n: Vector3, rear_z: float) -> void:
	var hc := Vector3(0.0, hatch_y, -0.2)
	_panel(k, hc, n, 0.78, 0.58, ARMOR_DARK)
	var up_slope := Vector3(0.0, -n.z, n.y)   # along the slope, toward the back
	k.tube(hc + up_slope * 0.33 + n * 0.04 + Vector3(-0.32, 0, 0), hc + up_slope * 0.33 + n * 0.04 + Vector3(0.32, 0, 0),
		0.06, 6, STEEL)
	k.push(_face_xf(Vector3(0.0, 1.38, rear_z - 0.005), Vector3.BACK))
	k.box(Vector3(0.62, 0.28, 0.03), SLATE)
	k.pop()


## Head-level weak-point sensor pod (origin at (0, 4.3, -1.2) world -> (0, 1.7, -1.2) relative to pelvis).
static func _strider_sensor(k: MeshKit) -> void:
	k.box(Vector3(1.25, 0.78, 1.05), ARMOR_DARK, Vector3(0.0, 0.0, 0.0))
	k.box(Vector3(1.32, 0.18, 0.82), TRIM_RED, Vector3(0.0, 0.42, 0.05))
	k.glow = true
	k.box(Vector3(1.1, 0.28, 0.14), OPTIC_GLOW, Vector3(0.0, -0.02, -0.54))
	k.glow = false
	# Steel brow hood over the optic (kept clear of the glow), twin antenna whips.
	k.box(Vector3(1.2, 0.08, 0.26), STEEL, Vector3(0.0, 0.2, -0.62))
	for side: float in [-1.0, 1.0]:
		_whip(k, Vector3(side * 0.5, 0.36, 0.3), Vector3(side * 0.66, 0.82, 0.48), 0.03)
	# Steel side frames round the optic, a slatted vent on the back, steel whip-foot collars.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.08, 0.36, 0.2), STEEL, Vector3(side * 0.6, -0.02, -0.56))
		k.box(Vector3(0.14, 0.1, 0.14), STEEL, Vector3(side * 0.5, 0.54, 0.3))
	_vent(k, Vector3(0.0, -0.06, 0.525), Vector3.BACK, 0.8, 0.36, 2)


## One reverse-jointed leg hanging from hip (0, 0, 0) down to foot at y = -2.6 m (authored for +X right leg).
static func _strider_leg(k: MeshKit) -> void:
	# Hip ball + armored thigh pod angling back to reverse knee.
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.32, 0.32, 0.32), STEEL)
	k.seg(Vector3(0.0, 0.0, 0.0), Vector3(0.18, -1.05, 0.55), Vector2(0.36, 0.42), Vector2(0.28, 0.34), 6, ARMOR_DARK)
	k.box(Vector3(0.16, 0.55, 0.48), TRIM_RED, Vector3(0.36, -0.52, 0.26))
	k.tube(Vector3(-0.08, -1.05, 0.55), Vector3(0.45, -1.05, 0.55), 0.26, 8, STEEL)
	# Long forward-angling shin strut down to ankle.
	k.seg(Vector3(0.18, -1.05, 0.55), Vector3(0.18, -2.32, -0.22), Vector2(0.22, 0.26), Vector2(0.16, 0.2), 4,
		ARMOR_PLATE, MeshKit.SQUARE)
	# Wide armored foot with forward claws + rear spur resting at y = -2.6 m.
	k.box(Vector3(0.68, 0.26, 0.85), ARMOR_DARK, Vector3(0.18, -2.47, -0.25))
	for dx: float in [-0.24, 0.0, 0.24]:
		k.seg(Vector3(0.18 + dx, -2.48, -0.58), Vector3(0.18 + dx * 1.15, -2.56, -1.12), Vector2(0.11, 0.11),
			Vector2(0.03, 0.04), 4, STEEL)
	k.seg(Vector3(0.18, -2.46, 0.12), Vector3(0.18, -2.35, 0.62), Vector2(0.12, 0.12), Vector2(0.04, 0.04), 4, STEEL)
	# Hydraulic piston behind the knee (inner side), hazard band across the toe.
	k.seg(Vector3(-0.08, -0.5, 0.48), Vector3(-0.02, -1.72, 0.22), Vector2(0.06, 0.06), Vector2(0.05, 0.05), 4, STEEL,
		MeshKit.SQUARE)
	_hazard(k, Vector3(0.18, -2.47, -0.675), Vector3.FORWARD, 0.6, 0.2, 2)
	# Slate hub caps on both ends of the knee drum, a hydraulic cylinder down the front of the shin, an ankle hub,
	# A raised plate on the foot's top.
	k.tube(Vector3(0.45, -1.05, 0.55), Vector3(0.5, -1.05, 0.55), 0.19, 6, SLATE)
	k.tube(Vector3(-0.08, -1.05, 0.55), Vector3(-0.13, -1.05, 0.55), 0.19, 6, SLATE)
	var k0 := Vector3(0.18, -1.05, 0.55)
	var a0 := Vector3(0.18, -2.32, -0.22)
	var fwd := Vector3.RIGHT.cross((a0 - k0).normalized())
	_piston(k, k0.lerp(a0, 0.12) + fwd * 0.3, k0.lerp(a0, 0.86) + fwd * 0.24, 0.075)
	k.tube(Vector3(0.02, -2.32, -0.22), Vector3(0.34, -2.32, -0.22), 0.13, 6, STEEL)
	_panel(k, Vector3(0.18, -2.34, -0.12), Vector3.UP, 0.46, 0.46, ARMOR_PLATE, Vector3.FORWARD)


## The same leg in three articulated parts for EnemyStrider's foot IK (EnemyGait + LegIK), each authored in the leg's
## rest frame (hip at the origin, the coordinates of strider_leg) so a part's transform is the rotation about its joint:
## thigh (hip ball .. knee drum, STRIDER_KNEE), shin (knee .. ankle hub, STRIDER_ANKLE), foot (kept flat on the floor).
## strider_leg stays the whole leg (debris). The inner knee piston is split at the knee into a barrel and a rod.
const STRIDER_KNEE := Vector3(0.18, -1.05, 0.55)
const STRIDER_ANKLE := Vector3(0.18, -2.32, -0.22)
const STRIDER_SOLE := -2.6   ## y of the sole under the hip


static func _strider_thigh(k: MeshKit) -> void:
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.32, 0.32, 0.32), STEEL)
	k.seg(Vector3(0.0, 0.0, 0.0), STRIDER_KNEE, Vector2(0.36, 0.42), Vector2(0.28, 0.34), 6, ARMOR_DARK)
	k.box(Vector3(0.16, 0.55, 0.48), TRIM_RED, Vector3(0.36, -0.52, 0.26))
	k.tube(Vector3(-0.08, -1.05, 0.55), Vector3(0.45, -1.05, 0.55), 0.26, 8, STEEL)
	k.seg(Vector3(-0.08, -0.5, 0.48), Vector3(-0.05, -1.11, 0.35), Vector2(0.06, 0.06), Vector2(0.05, 0.05), 4, STEEL,
		MeshKit.SQUARE)
	k.tube(Vector3(0.45, -1.05, 0.55), Vector3(0.5, -1.05, 0.55), 0.19, 6, SLATE)
	k.tube(Vector3(-0.08, -1.05, 0.55), Vector3(-0.13, -1.05, 0.55), 0.19, 6, SLATE)


static func _strider_shin(k: MeshKit) -> void:
	k.seg(STRIDER_KNEE, STRIDER_ANKLE, Vector2(0.22, 0.26), Vector2(0.16, 0.2), 4, ARMOR_PLATE, MeshKit.SQUARE)
	k.seg(Vector3(-0.05, -1.11, 0.35), Vector3(-0.02, -1.72, 0.22), Vector2(0.05, 0.05), Vector2(0.05, 0.05), 4, STEEL,
		MeshKit.SQUARE)
	var fwd := Vector3.RIGHT.cross((STRIDER_ANKLE - STRIDER_KNEE).normalized())
	_piston(k, STRIDER_KNEE.lerp(STRIDER_ANKLE, 0.12) + fwd * 0.3, STRIDER_KNEE.lerp(STRIDER_ANKLE, 0.86) + fwd * 0.24, 0.075)
	k.tube(Vector3(0.02, -2.32, -0.22), Vector3(0.34, -2.32, -0.22), 0.13, 6, STEEL)


static func _strider_foot(k: MeshKit) -> void:
	k.box(Vector3(0.68, 0.26, 0.85), ARMOR_DARK, Vector3(0.18, -2.47, -0.25))
	for dx: float in [-0.24, 0.0, 0.24]:
		k.seg(Vector3(0.18 + dx, -2.48, -0.58), Vector3(0.18 + dx * 1.15, -2.56, -1.12), Vector2(0.11, 0.11),
			Vector2(0.03, 0.04), 4, STEEL)
	k.seg(Vector3(0.18, -2.46, 0.12), Vector3(0.18, -2.35, 0.62), Vector2(0.12, 0.12), Vector2(0.04, 0.04), 4, STEEL)
	_hazard(k, Vector3(0.18, -2.47, -0.675), Vector3.FORWARD, 0.6, 0.2, 2)
	_panel(k, Vector3(0.18, -2.34, -0.12), Vector3.UP, 0.46, 0.46, ARMOR_PLATE, Vector3.FORWARD)


# --- Bastion Siege Tank (6.8 W x 9.6 L x 5.4 H) ------------------------------------------------------------

static func _tank_hull(k: MeshKit) -> void:
	# Twin massive armored tread sponsons (1.8 W x 2.0 H x 9.6 L at x = +-2.5 m -> total width 6.8 m).
	for side: float in [-1.0, 1.0]:
		var sx := side * 2.5
		k.loft([
			MeshKit.ring(Vector3(sx, 0.95, 4.8), 0.88, 0.62, 6, "z", 3.4),
			MeshKit.ring(Vector3(sx, 1.02, 3.8), 0.92, 0.98, 6, "z", 3.4),
			MeshKit.ring(Vector3(sx, 1.02, -3.8), 0.92, 0.98, 6, "z", 3.4),
			MeshKit.ring(Vector3(sx, 0.95, -4.8), 0.88, 0.62, 6, "z", 3.4),
		], [ARMOR_DARK, ARMOR_DARK, ARMOR_DARK])
		# Side armor skirt + bold crimson occupation stripe.
		k.box(Vector3(0.24, 1.25, 7.6), ARMOR_PLATE, Vector3(sx + side * 0.86, 1.15, 0.0))
		k.box(Vector3(0.28, 0.38, 6.8), TRIM_RED, Vector3(sx + side * 0.9, 1.38, -0.1))
		# Exposed steel drive sprockets & road wheels underneath.
		for rz: float in [-3.4, -1.7, 0.0, 1.7, 3.4]:
			k.tube(Vector3(sx - 0.72, 0.45, rz), Vector3(sx + 0.72, 0.45, rz), 0.45, 8, STEEL)
		# The skirt split into three raised slate-rimmed panels under the stripe, a stowage box with a slate strap
		# On the sponson top.
		for pz: float in [-2.6, -0.8, 1.0]:
			_panel(k, Vector3(sx + side * 0.98, 0.84, pz), Vector3(side, 0.0, 0.0), 1.6, 0.5, ARMOR_DARK)
		k.box(Vector3(0.66, 0.34, 1.3), ARMOR_PLATE, Vector3(sx, 2.02, -1.9))
		k.box(Vector3(0.7, 0.37, 0.14), SLATE, Vector3(sx, 2.03, -1.9))
	# Central sloped armored glacis hull (y = 0.5..2.65).
	k.loft([
		MeshKit.ring(Vector3(0, 1.55, 4.4), 1.85, 0.95, 6, "z", 3.6),
		MeshKit.ring(Vector3(0, 1.62, 2.5), 1.95, 1.05, 6, "z", 3.6),
		MeshKit.ring(Vector3(0, 1.62, -2.6), 1.95, 1.05, 6, "z", 3.6),
		MeshKit.ring(Vector3(0, 1.25, -4.55), 1.72, 0.62, 6, "z", 3.6),
	], [ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK])
	# Front red chevron bumper & glowing crimson assault headlights.
	k.box(Vector3(3.4, 0.35, 0.45), TRIM_RED, Vector3(0.0, 1.5, -4.45))
	k.glow = true
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.65, 0.24, 0.14), OPTIC_GLOW, Vector3(side * 2.4, 1.48, -4.82))
	k.glow = false
	k.lathe([Vector2(1.9, 2.55), Vector2(1.85, 2.8)], 10, STEEL, false, true)
	# unit-number plates at the rear of the skirts, amber service beacons on the rear sponson tops.
	_hazard(k, Vector3(0.0, 0.98, -4.55), Vector3.FORWARD, 2.4, 0.36, 5)
	_emblem(k, Vector3(0.0, 2.2, -3.58), Vector3(0.0, 0.930, -0.367), 1.1, true, Vector3(0.0, 0.367, 0.930))
	for side: float in [-1.0, 1.0]:
		_plate(k, Vector3(side * 3.48, 0.86, 2.7), Vector3(side, 0.0, 0.0), 0.75, 0.26)
		_lamp(k, Vector3(side * 2.5, 1.95, 3.3), Vector3.UP, Vector3(0.34, 0.34, 0.2), LAMP_AMBER, Vector3.BACK)
	# Two crew hatches on the glacis above the stencil, steel hoods over the headlights, a rear vent panel between
	# Two exhaust stubs.
	for side: float in [-1.0, 1.0]:
		_panel(k, Vector3(side * 0.55, 2.44, -2.86), Vector3(0.0, 0.935, -0.355), 0.56, 0.4, STEEL)
		k.box(Vector3(0.8, 0.07, 0.22), STEEL, Vector3(side * 2.4, 1.64, -4.78))
		k.tube(Vector3(side * 1.0, 1.3, 4.35), Vector3(side * 1.0, 1.3, 4.74), 0.16, 6, SLATE)
	_vent(k, Vector3(0.0, 1.45, 4.42), Vector3.BACK, 1.1, 0.5, 3)


## Glowing rear/top radiator weak point (origin at (0, 2.75, 3.1), pops visually from rooftops & flanks).
static func _tank_vents(k: MeshKit) -> void:
	k.box(Vector3(3.2, 0.55, 2.3), ARMOR_DARK, Vector3(0.0, 0.15, 0.0))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.28, 0.82, 2.42), TRIM_RED, Vector3(side * 1.56, 0.32, 0.0))
		# A's thin "HOT" strip (4 cm) replaced by a chunky cream warning plate on a slate backing.
		k.box(Vector3(0.04, 0.34, 1.06), SLATE, Vector3(side * 1.71, 0.44, 0.0))
		k.box(Vector3(0.05, 0.24, 0.94), CIVIC_CREAM, Vector3(side * 1.725, 0.44, 0.0))
	k.glow = true
	for i in 4:
		var z := -0.78 + float(i) * 0.52
		k.box(Vector3(2.7, 0.32, 0.24), VENT_GLOW, Vector3(0.0, 0.58, z))
	k.box(Vector3(2.4, 0.38, 0.16), VENT_GLOW, Vector3(0.0, 0.25, 1.18))
	k.glow = false
	# Steel grille end bars across the deck before and behind the fins.
	for gz: float in [-1.06, 1.06]:
		k.box(Vector3(2.8, 0.14, 0.12), STEEL, Vector3(0.0, 0.49, gz))


## Heavy angular siege turret + 6.4 m main cannon + commander cupola + rear flush-mortar tube (origin at y = 2.7, z = -0.3).
static func _tank_turret(k: MeshKit) -> void:
	# Wide flat-topped wedge turret (4.4 W x 1.7 H x 5.0 L).
	k.loft([
		MeshKit.ring(Vector3(0, 0.1, 0.2), 2.15, 2.5, 8, "y", 3.4),
		MeshKit.ring(Vector3(0, 1.05, 0.15), 2.25, 2.55, 8, "y", 3.4),
		MeshKit.ring(Vector3(0, 1.8, 0.25), 1.65, 1.95, 8, "y", 3.4),
	], [ARMOR_DARK, ARMOR_PLATE])
	# Bold crimson side cheek plates.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.32, 0.95, 3.4), TRIM_RED, Vector3(side * 2.26, 0.95, 0.1))
	# Commander optic cupola peaking at y = +2.7 -> world 5.4 m!
	k.box(Vector3(1.55, 0.85, 1.45), ARMOR_DARK, Vector3(-0.45, 2.22, 0.35))
	k.box(Vector3(1.62, 0.18, 1.52), TRIM_RED, Vector3(-0.45, 2.66, 0.35))
	k.glow = true
	k.box(Vector3(1.3, 0.3, 0.16), OPTIC_GLOW, Vector3(-0.45, 2.25, -0.38))
	k.glow = false
	# Angled rear-right flush mortar tube.
	k.tube(Vector3(1.05, 1.55, 1.1), Vector3(1.05, 2.85, 0.55), 0.32, 8, STEEL)
	k.tube(Vector3(1.05, 2.65, 0.63), Vector3(1.05, 2.92, 0.52), 0.38, 8, ARMOR_DARK)
	# Massive 6.4 m siege cannon barrel.
	k.box(Vector3(1.2, 1.05, 1.3), STEEL, Vector3(0.0, 1.0, -2.3))
	k.tube(Vector3(0.0, 1.0, -2.6), Vector3(0.0, 1.0, -5.85), 0.34, 8, ARMOR_DARK)
	k.tube(Vector3(0.0, 1.0, -5.65), Vector3(0.0, 1.0, -6.38), 0.48, 8, STEEL)
	k.glow = true
	k.tube(Vector3(0.0, 1.0, -6.34), Vector3(0.0, 1.0, -6.45), 0.28, 6, OPTIC_GLOW)
	k.box(Vector3(0.18, 0.18, 2.2), OPTIC_GLOW, Vector3(0.0, 1.38, -4.2))
	k.glow = false
	# Descent stencils on the brick cheek plates, service light bar on the cupola.
	for side: float in [-1.0, 1.0]:
		_emblem(k, Vector3(side * 2.42, 0.95, 0.75), Vector3(side, 0.0, 0.0), 0.78)
	_light_bar(k, Vector3(-0.45, 2.75, 0.55), 1.1)
	# Slate under-plates behind the cheek plates, a hood and frames on the cupola optic, a clamp collar on the
	# Barrel behind the charge rail, a collar on the mortar tube, smoke-discharger blocks on the front corners of the
	# Roof, a stowage panel on the rear face.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.26, 1.07, 3.52), SLATE, Vector3(side * 2.24, 0.95, 0.1))
		k.box(Vector3(0.44, 0.28, 0.5), SLATE, Vector3(side * 1.3, 1.93, -0.95))
		k.tube(Vector3(side * 1.3, 2.0, -1.12), Vector3(side * 1.3, 2.14, -1.36), 0.09, 4, STEEL)
	_optic_hood(k, Vector3(-0.45, 2.25, -0.38), 1.3, 0.3, -0.46)
	k.tube(Vector3(0.0, 1.0, -2.68), Vector3(0.0, 1.0, -2.98), 0.43, 8, ARMOR_PLATE)
	var m0 := Vector3(1.05, 1.55, 1.1)
	var m1 := Vector3(1.05, 2.85, 0.55)
	k.tube(m0.lerp(m1, 0.3), m0.lerp(m1, 0.4), 0.4, 8, SLATE)
	_panel(k, Vector3(0.0, 0.6, 2.585), Vector3.BACK, 1.4, 0.48, ARMOR_PLATE)


static func _tank_turret_wreck(k: MeshKit) -> void:
	k.lathe([Vector2(1.85, 0.0), Vector2(1.5, 0.65), Vector2(1.0, 0.9)], 8, CHARRED, true, true)
	k.tube(Vector3(0.0, 0.55, -0.4), Vector3(0.3, 0.7, -2.2), 0.28, 6, CHARRED)
	# Torn muzzle sleeve, a blown-off cupola lid leaning on the ring, exposed breech block.
	k.tube(Vector3(0.28, 0.68, -2.0), Vector3(0.36, 0.72, -2.55), 0.36, 6, CHARRED_EDGE)
	k.push(MeshKit.xf(Vector3(-0.85, 0.9, 0.55), Vector3(-10.0, 25.0, 30.0)))
	k.box(Vector3(1.2, 0.14, 1.1), CHARRED_EDGE)
	k.pop()
	k.box(Vector3(0.8, 0.5, 0.7), CHARRED, Vector3(0.15, 0.95, -0.2))


# --- Pop-off Debris & Ruptured Core (strictly watertight) --------------------------------------------------

static func _debris_plate(k: MeshKit) -> void:
	k.box(Vector3(1.35, 0.20, 0.95), ARMOR_DARK)
	k.push(MeshKit.xf(Vector3(0.35, 0.08, -0.12), Vector3(0.0, 14.0, -12.0)))
	k.box(Vector3(0.75, 0.16, 0.62), ARMOR_PLATE)
	k.pop()
	k.box(Vector3(1.15, 0.23, 0.20), TRIM_RED, Vector3(0.0, 0.01, -0.34))


static func _debris_chunk(k: MeshKit) -> void:
	k.box(Vector3(0.72, 0.52, 0.66), CHARRED)
	k.push(MeshKit.xf(Vector3(-0.22, 0.12, 0.14), Vector3(18.0, 26.0, -14.0)))
	k.box(Vector3(0.46, 0.34, 0.42), STEEL)
	k.pop()


static func _rupture_core(k: MeshKit) -> void:
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.95, 0.52, 0.95), VENT_GLOW)
	k.ico(Vector3(0.38, 0.14, -0.24), Vector3(0.55, 0.42, 0.52), VENT_GLOW)
	k.ico(Vector3(-0.34, 0.10, 0.28), Vector3(0.50, 0.38, 0.48), VENT_GLOW)


# --- Long/Short Variants & Patrol Scout Drone (strictly watertight: 0 open edges) -------------------------

## Marksman Sniper Turret head: sleek drum + tall twin-vane sensor mast + 5.4 m twin-rail lance barrel.
static func _turret_sniper_gun(k: MeshKit) -> void:
	k.loft([
		MeshKit.ring(Vector3(0, 0.1, 0.2), 1.5, 1.85, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 1.1, 0.15), 1.65, 2.0, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 1.95, 0.25), 1.25, 1.55, 8, "y", 3.2),
	], [ARMOR_DARK, ARMOR_PLATE])
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.28, 0.95, 2.5), TRIM_RED, Vector3(side * 1.65, 1.08, 0.15))
		# Tall twin-vane sniper sensor mast (reads distinctly at 180+ m).
		k.seg(Vector3(side * 0.62, 1.95, 0.35), Vector3(side * 0.92, 3.85, 0.65),
			Vector2(0.14, 0.26), Vector2(0.06, 0.10), 4, ARMOR_PLATE, MeshKit.SQUARE)
		k.box(Vector3(0.20, 0.45, 0.42), TRIM_RED, Vector3(side * 0.78, 3.15, 0.50))
	k.box(Vector3(1.9, 1.15, 0.95), ARMOR_DARK, Vector3(0.0, 1.08, 2.15))
	k.glow = true
	k.box(Vector3(1.3, 0.42, 0.16), VENT_GLOW, Vector3(0.0, 1.08, 2.62))
	k.glow = false
	# Wide rangefinder optic bar above breech.
	k.box(Vector3(1.45, 0.78, 1.05), ARMOR_DARK, Vector3(0.0, 2.38, -0.2))
	k.glow = true
	k.box(Vector3(1.22, 0.32, 0.16), OPTIC_GLOW, Vector3(0.0, 2.40, -0.74))
	k.glow = false
	# Extra-long 5.4 m twin-rail lance accelerator barrel.
	k.box(Vector3(0.85, 0.75, 1.55), STEEL, Vector3(0.0, 1.05, -1.75))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.18, 0.38, 3.65), ARMOR_DARK, Vector3(side * 0.28, 1.05, -3.55))
	for i in 4:
		var z := -2.55 - float(i) * 0.80
		k.box(Vector3(0.82, 0.52, 0.20), STEEL, Vector3(0.0, 1.05, z))
	k.glow = true
	k.box(Vector3(0.16, 0.16, 3.3), OPTIC_GLOW, Vector3(0.0, 1.05, -3.75))
	k.tube(Vector3(0.0, 1.05, -5.28), Vector3(0.0, 1.05, -5.45), 0.18, 6, OPTIC_GLOW)
	k.glow = false
	_turret_civic(k, 1.79, 1.08, 0.6, 2.625)
	_turret_head_detail(k, 1.63, 1.08, 0.15, Vector3(0.22, 1.07, 2.62), Vector3(0.0, 1.93, 1.05), 1.655, 2.15, 0.7)
	_optic_hood(k, Vector3(0.0, 2.40, -0.74), 1.22, 0.32, -0.82)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.38, 0.2, 0.46), STEEL, Vector3(side * 0.64, 2.02, 0.37))   # mast foot hinge blocks
	k.box(Vector3(0.14, 0.14, 2.7), SLATE, Vector3(0.0, 0.73, -3.6))           # power cable under the rails




## Salvo Missile Turret head: armored drum + twin boxy 3-tube shoulder rocket pods flanking the drum.
static func _turret_missile_gun(k: MeshKit) -> void:
	k.loft([
		MeshKit.ring(Vector3(0, 0.1, 0.15), 1.65, 1.75, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 1.15, 0.1), 1.80, 1.82, 8, "y", 3.2),
		MeshKit.ring(Vector3(0, 2.05, 0.2), 1.40, 1.45, 8, "y", 3.2),
	], [ARMOR_DARK, ARMOR_PLATE])
	k.box(Vector3(2.1, 1.2, 0.85), ARMOR_DARK, Vector3(0.0, 1.1, 1.92))
	k.glow = true
	k.box(Vector3(1.5, 0.45, 0.16), VENT_GLOW, Vector3(0.0, 1.1, 2.34))
	k.glow = false
	# Wide target-lock optic dome on top.
	k.box(Vector3(1.75, 0.85, 1.15), ARMOR_DARK, Vector3(0.0, 2.50, -0.1))
	k.box(Vector3(1.85, 0.22, 1.22), TRIM_RED, Vector3(0.0, 2.98, -0.1))
	k.glow = true
	k.box(Vector3(1.45, 0.36, 0.18), OPTIC_GLOW, Vector3(0.0, 2.52, -0.70))
	k.glow = false
	# Twin boxy 3-tube shoulder rocket pods (x = +-1.95).
	for side: float in [-1.0, 1.0]:
		var px := side * 1.95
		k.box(Vector3(0.55, 0.48, 0.9), STEEL, Vector3(side * 1.45, 1.35, -0.05))
		k.box(Vector3(1.15, 1.35, 2.15), ARMOR_DARK, Vector3(px, 1.45, -0.15))
		k.box(Vector3(1.22, 0.34, 1.85), TRIM_RED, Vector3(px, 2.02, -0.15))
		k.box(Vector3(0.95, 0.95, 0.26), STEEL, Vector3(px, 1.45, 0.95))
		# 3 launch tubes stacked vertically/staggered on the front face with glowing red warheads.
		for ti in 3:
			var oy := 1.05 + float(ti) * 0.40
			var ox := px + (0.22 if ti == 1 else -0.18) * side
			k.tube(Vector3(ox, oy, -1.18), Vector3(ox, oy, -1.42), 0.17, 6, STEEL)
			k.glow = true
			k.tube(Vector3(ox, oy, -1.40), Vector3(ox, oy, -1.56), 0.12, 6, OPTIC_GLOW, 0.03)
			k.glow = false
		_emblem(k, Vector3(side * 2.525, 1.38, -0.2), Vector3(side, 0.0, 0.0), 0.8)
		# A raised steel frame round the launch tubes, two lifting lugs on the pod top, a vent on the pod's outer
		# Face behind the stencil, a cable from the pod's rear block into the drum.
		for fy: float in [0.84, 2.06]:
			k.box(Vector3(1.04, 0.1, 0.1), STEEL, Vector3(px, fy, -1.27))
		for fx: float in [-0.47, 0.47]:
			k.box(Vector3(0.1, 1.32, 0.1), STEEL, Vector3(px + fx, 1.45, -1.27))
		for lz: float in [-0.8, 0.5]:
			k.box(Vector3(0.24, 0.12, 0.28), STEEL, Vector3(px, 2.24, lz))
		_vent(k, Vector3(side * 2.525, 1.3, 0.62), Vector3(side, 0.0, 0.0), 0.46, 0.62, 2)
		_hose(k, [Vector3(side * 1.65, 1.88, 1.0), Vector3(side * 1.3, 2.0, 1.2), Vector3(side * 0.92, 1.9, 1.34)], 0.07)
	_plate(k, Vector3(0.0, 1.55, 2.345), Vector3.BACK, 0.7, 0.2)
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.22, 0.16, 0.34), STEEL, Vector3(side * 0.75, 1.77, 1.92))
	_optic_hood(k, Vector3(0.0, 2.52, -0.70), 1.45, 0.36, -0.79)




## Hound Breacher chassis: broad armored ramming prow + wider shield pauldrons + twin-drum scatter cannon.
static func _strider_breacher_chassis(k: MeshKit) -> void:
	k.box(Vector3(1.55, 0.65, 1.35), STEEL, Vector3(0.0, 0.0, 0.1))
	k.tube(Vector3(-1.38, 0.0, 0.0), Vector3(1.38, 0.0, 0.0), 0.25, 8, ARMOR_DARK)
	k.loft([
		MeshKit.ring(Vector3(0, 0.95, 1.35), 1.12, 0.68, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 1.25, 0.25), 1.55, 0.95, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 1.18, -1.10), 1.42, 0.80, 6, "z", 2.8),
		MeshKit.ring(Vector3(0, 1.02, -1.92), 1.05, 0.55, 6, "z", 2.8),
	], [ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK])
	# Heavy slanted armored ramming prow on the front chest.
	k.push(MeshKit.xf(Vector3(0.0, 1.18, -1.85), Vector3(18.0, 0.0, 0.0)))
	k.box(Vector3(2.15, 0.88, 0.36), ARMOR_DARK)
	k.box(Vector3(2.22, 0.28, 0.40), TRIM_RED, Vector3(0.0, 0.16, -0.02))
	_hazard(k, Vector3(0.0, -0.2, -0.18), Vector3.FORWARD, 1.9, 0.34, 4)
	# Three steel ram teeth along the prow's lower edge.
	for tx: float in [-0.7, 0.0, 0.7]:
		k.box(Vector3(0.3, 0.2, 0.18), STEEL, Vector3(tx, -0.42, -0.2))
	k.pop()
	# Oversized breacher shoulder shields (4.2 m span), Descent stencil on each.
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 1.72, 1.45, -0.25), Vector3(0.0, 0.0, -side * 12.0)))
		k.box(Vector3(0.86, 1.22, 2.35), ARMOR_DARK)
		k.box(Vector3(0.92, 0.36, 1.95), TRIM_RED, Vector3(0.0, 0.30, -0.08))
		_emblem(k, Vector3(side * 0.43, -0.2, 0.35), Vector3(side, 0.0, 0.0), 0.62, false)
		# Steel cap plate on the shield's front face.
		_panel(k, Vector3(0.0, -0.12, -1.175), Vector3.FORWARD, 0.6, 0.66, STEEL)
		k.pop()
	_plate(k, Vector3(0.0, 1.4, 1.36), Vector3.BACK, 0.5, 0.16)
	# Shorter rugged rear antenna stubs.
	for side: float in [-1.0, 1.0]:
		k.seg(Vector3(side * 0.78, 1.85, 0.55), Vector3(side * 0.92, 2.45, 0.95),
			Vector2(0.14, 0.24), Vector2(0.07, 0.10), 4, ARMOR_PLATE, MeshKit.SQUARE)
	k.glow = true
	k.box(Vector3(1.25, 0.34, 0.14), VENT_GLOW, Vector3(0.0, 1.0, 1.44))
	k.glow = false
	# Underslung twin-drum scatter cannon (muzzle at z = -2.58 m).
	k.box(Vector3(1.05, 0.55, 1.35), STEEL, Vector3(0.0, 0.48, -1.25))
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.46, 0.36, -0.95), Vector3(side * 0.46, 0.36, -1.65), 0.28, 8, ARMOR_DARK)
		k.tube(Vector3(side * 0.26, 0.50, -1.65), Vector3(side * 0.26, 0.50, -2.50), 0.16, 6, STEEL)
		k.glow = true
		k.tube(Vector3(side * 0.26, 0.50, -2.48), Vector3(side * 0.26, 0.50, -2.58), 0.13, 6, OPTIC_GLOW)
		k.glow = false
	_strider_detail(k, 2.0, Vector3(0.0, 0.989, -0.146), 1.37)
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.46, 0.36, -1.63), Vector3(side * 0.46, 0.36, -1.72), 0.22, 6, STEEL)   # drum caps
		k.tube(Vector3(side * 0.26, 0.50, -2.0), Vector3(side * 0.26, 0.50, -2.16), 0.21, 6, SLATE)    # barrel collars


## Patrol Scout Drone hull (2.4 x 2.4 x 1.1 m): hovering tri-fin shrouded rotor disc, strictly watertight.
static func _drone_hull(k: MeshKit) -> void:
	k.lathe([Vector2(0.55, -0.24), Vector2(0.92, 0.0), Vector2(0.88, 0.26), Vector2(0.52, 0.48), Vector2(0.20, 0.54)],
		6, [ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK, ARMOR_PLATE], true, true)
	# Dorsal crimson beacon crown + twin sensor fins.
	k.box(Vector3(0.70, 0.18, 0.70), TRIM_RED, Vector3(0.0, 0.58, 0.0))
	k.glow = true
	k.ico(Vector3(0.0, 0.78, 0.0), Vector3(0.22, 0.22, 0.22), OPTIC_GLOW)
	k.glow = false
	# Three swept shrouded rotor fins at 120 deg intervals (2.4 m diameter).
	for i in 3:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(0.0, float(i) * 120.0, 0.0)))
		k.box(Vector3(0.46, 0.24, 0.92), ARMOR_DARK, Vector3(0.0, 0.12, -0.78))
		k.box(Vector3(0.76, 0.30, 0.52), ARMOR_PLATE, Vector3(0.0, 0.10, -1.10))
		k.box(Vector3(0.80, 0.12, 0.32), TRIM_RED, Vector3(0.0, 0.24, -1.12))
		k.glow = true
		k.box(Vector3(0.48, 0.08, 0.26), VENT_GLOW, Vector3(0.0, -0.06, -1.10))
		k.glow = false
		# A steel hinge block where the fin leaves the hull and a steel end cap on the rotor pod.
		k.box(Vector3(0.58, 0.3, 0.14), STEEL, Vector3(0.0, 0.12, -0.86))
		k.box(Vector3(0.6, 0.22, 0.06), STEEL, Vector3(0.0, 0.1, -1.385))
		k.pop()
	# (players mostly see drones from below).
	_plate(k, Vector3(0.0, 0.13, 0.785), Vector3.BACK, 0.5, 0.18)
	_whip(k, Vector3(0.24, 0.6, 0.2), Vector3(0.34, 1.02, 0.34), 0.025)
	_emblem(k, Vector3(0.0, -0.24, 0.24), Vector3.DOWN, 0.42, false, Vector3.FORWARD)
	# A steel collar round the crown beacon's foot, a steel step ring round the equator.
	k.lathe([Vector2(0.27, 0.62), Vector2(0.27, 0.71)], 6, STEEL, true, true)
	k.lathe([Vector2(0.95, -0.04), Vector2(0.95, 0.05)], 6, STEEL, true, true)


## Drone belly crimson optic dome (weak point at (0, -0.35, -0.55)).
static func _drone_optic(k: MeshKit) -> void:
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.48, 0.38, 0.52), ARMOR_DARK)
	k.glow = true
	k.ico(Vector3(0.0, -0.05, -0.30), Vector3(0.30, 0.24, 0.26), OPTIC_GLOW)
	k.glow = false
	k.box(Vector3(0.5, 0.07, 0.24), STEEL, Vector3(0.0, 0.12, -0.42))
	# Steel side frames either side of the lens.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.07, 0.22, 0.22), STEEL, Vector3(side * 0.33, -0.04, -0.42))


## Watertight downward translucent scanner frustum (origin at belly optic, extends along -Z / -Y).
static func _drone_cone(k: MeshKit) -> void:
	k.lathe([Vector2(0.18, 0.0), Vector2(2.6, -9.5)], 8, VENT_GLOW, true, true)


# --- Exo-troopers (2.26 m, origin at the feet, facing -Z) ---------------------------------------------------
# One closed-shell mesh per (kit, look variant): part id "trooper_<kit>_<n>", kit in TROOPER_KITS, n in
# 0..TROOPER_VARIANTS-1 ("trooper_rifle" / "trooper_at" = variant 0). A squad reads as distinct people: each variant n
# picks a build (slim / standard / heavy), a helmet (dome / crest / flat-top), back gear (jump pack / radio pack + whip /
# pouch belt + low pack), a chest mark, a small value / hue shift of the L1 body and plate slate, a height within +-4 %,
# and n % 4 == 0 is a squad leader (cream helmet stripe + cream shoulder plate). Every choice is a pure function of n
# (trooper_look): no RNG, identical on every machine. The weapon, hands and muzzle are the kit's and never move (rifle
# muzzle z -1.48, AT tube mouth z -1.52), so hit spheres, aim and the squad's crouch pivot stay valid for every variant.

const TROOPER_VARIANTS := 12
const TROOPER_KITS := ["rifle", "at"]
const TROOPER_BUILDS := ["slim", "standard", "heavy"]
const TROOPER_HELMETS := ["dome", "crest", "flat"]
const TROOPER_GEAR := ["jump", "radio", "pouch"]
const TROOPER_MARKS := ["band", "chevron", "sash"]
## Per-variant height scale of the body (weapon and hands excluded), within +-4 %.
const _TROOPER_HEIGHT := [1.0, 1.03, 0.97, 1.02, 0.96, 1.03, 0.98, 1.04, 0.99, 0.97, 1.03, 1.0]
## Per-variant value shift of the body / plate slate (+ lightens, - darkens), within +-5 %.
const _TROOPER_VALUE := [0.0, -0.05, 0.04, 0.02, -0.03, 0.05, -0.04, 0.01, 0.03, -0.02, 0.05, -0.05]
## Per-variant hue lean: -1 cool (toward blue slate), 0 none, 1 warm (toward the brick).
const _TROOPER_LEAN := [0, 1, -1, -1, 0, 1, 1, -1, 0, 0, -1, 1]
## Build proportions: [width factor, limb thickness, shoulder x, pauldron size].
const _TROOPER_BUILD := [[0.88, 0.86, 0.5, 0.31], [1.0, 1.0, 0.56, 0.36], [1.14, 1.16, 0.62, 0.42]]


## The part id for a trooper of `kit` ("rifle" / "at") whose look comes from `look_seed` (any int, e.g. from spawn data).
static func trooper_part(kit: String, look_seed: int) -> String:
	return "trooper_%s_%d" % [kit, posmod(look_seed, TROOPER_VARIANTS)]


## Optional helper: look seeds for a squad of `count` (up to 10) from one squad seed: slot 0 is a leader variant (0 / 4 /
## 8), slots 1.. are distinct non-leader variants. Pure arithmetic (162 distinct squads), the same on every machine.
static func trooper_squad_seeds(squad_seed: int, count: int) -> Array[int]:
	var s := posmod(squad_seed, 162)
	var non := [1, 2, 3, 5, 6, 7, 9, 10, 11]
	var start := (s / 3) % 9
	var step: int = [1, 2, 4, 5, 7, 8][(s / 27) % 6]   # coprime with 9: no repeats within a squad
	var out: Array[int] = [[0, 4, 8][s % 3]]
	for i in range(1, count):
		out.append(non[(start + (i - 1) * step) % 9])
	return out


## Every trooper variant part id (both kits), for prewarm and checks.
static func trooper_parts() -> Array[String]:
	var out: Array[String] = []
	for kit: String in TROOPER_KITS:
		for n in TROOPER_VARIANTS:
			out.append(trooper_part(kit, n))
	return out


## Articulated trooper (EnemyTrooper's near rig): the same variant split into the pieces in TROOPER_PIECES, each a
## closed shell authored in the standing model frame (feet at the origin, facing -Z), so the variant's look, colours and
## sizes are exactly the whole-body part's (the whole body = every piece together). EnemyTrooper poses a piece by a
## rotation about its joint (trooper_joints). The whole-body ids stay for the far LOD, the wreck and everything else.
## Left = -X (the trooper faces -Z). The knee pad rides the shin.
const TROOPER_PIECES := ["torso", "head", "arms", "thigh_l", "thigh_r", "shin_l", "shin_r", "boot_l", "boot_r"]
const TROOPER_HIP_Y := 0.97      ## hip joint (top of the thigh), before the variant height scale
const TROOPER_KNEE_Y := 0.62
const TROOPER_ANKLE_Y := 0.2     ## ankle (top of the boot)
const TROOPER_SHOULDER_Y := 1.62
const TROOPER_NECK_Y := 1.8


## Part id of piece `piece` of trooper variant `look_seed` (wrapped like trooper_part).
static func trooper_rig_part(kit: String, look_seed: int, piece: String) -> String:
	return "trooperrig_%s_%d_%s" % [kit, posmod(look_seed, TROOPER_VARIANTS), piece]


## [kit, n, piece] for a trooper rig piece id, or [].
static func trooper_rig_id(part: String) -> Array:
	if not part.begins_with("trooperrig_"):
		return []
	var bits := part.trim_prefix("trooperrig_").split("_", false, 2)
	if bits.size() != 3 or not bits[0] in TROOPER_KITS or not bits[1].is_valid_int() or not bits[2] in TROOPER_PIECES:
		return []
	var n := int(bits[1])
	if n < 0 or n >= TROOPER_VARIANTS:
		return []
	return [bits[0], n, bits[2]]


## Every rig piece id of every variant (checks).
static func trooper_rig_parts() -> Array[String]:
	var out: Array[String] = []
	for kit: String in TROOPER_KITS:
		for n in TROOPER_VARIANTS:
			for pc: String in TROOPER_PIECES:
				out.append(trooper_rig_part(kit, n, pc))
	return out


## The joints of variant n in its standing model frame: hip_y / knee_y / ankle_y / shoulder_y / neck_y (height-scaled),
## leg_x (each leg's centre, + for the right leg), thigh / shin lengths.
static func trooper_joints(n: int) -> Dictionary:
	var lk := trooper_look(n)
	var bp: Array = _TROOPER_BUILD[int(lk["build"])]
	var hs := float(lk["height"])
	var w := float(bp[0])
	return {"hip_y": TROOPER_HIP_Y * hs, "knee_y": TROOPER_KNEE_Y * hs, "ankle_y": TROOPER_ANKLE_Y * hs,
		"shoulder_y": TROOPER_SHOULDER_Y * hs, "neck_y": TROOPER_NECK_Y * hs, "leg_x": 0.24 * (0.9 + 0.1 * w),
		"thigh": (TROOPER_HIP_Y - TROOPER_KNEE_Y) * hs, "shin": (TROOPER_KNEE_Y - TROOPER_ANKLE_Y) * hs}


## [kit, n] for a trooper part id ("trooper_rifle" / "trooper_at" -> variant 0), or [] for any other part.
static func trooper_id(part: String) -> Array:
	if not part.begins_with("trooper_"):
		return []
	var rest := part.trim_prefix("trooper_")
	if rest in TROOPER_KITS:
		return [rest, 0]
	var cut := rest.rfind("_")
	if cut < 0 or not rest.substr(0, cut) in TROOPER_KITS or not rest.substr(cut + 1).is_valid_int():
		return []
	var n := int(rest.substr(cut + 1))
	if n < 0 or n >= TROOPER_VARIANTS:
		return []
	return [rest.substr(0, cut), n]


## The look choices of variant n (pure arithmetic + tables). build / helmet / gear form a Latin square over n 0..8 (every
## build x helmet once, every gear once per build and per helmet); 9..11 repeat the dome with a new gear per build.
## Leaders: n 0 (standard), 4 (heavy), 8 (slim).
static func trooper_look(n: int) -> Dictionary:
	n = posmod(n, TROOPER_VARIANTS)
	var q := n / 3
	return {
		"build": (n + 1) % 3,
		"helmet": q % 3,
		"gear": (n % 3 + q + n / 9) % 3,
		"mark": (n / 2) % 3,
		"leader": n % 4 == 0,
		"height": float(_TROOPER_HEIGHT[n]),
		"colours": trooper_colours(n),
	}


## [body, plate] colours of variant n: the L1 ARMOR_DARK / ARMOR_PLATE shifted in value (+-5 %) and leaned a touch
## cool or warm. The only non-palette colours any trooper uses.
static func trooper_colours(n: int) -> Array[Color]:
	n = posmod(n, TROOPER_VARIANTS)
	var v := float(_TROOPER_VALUE[n])
	var lean := int(_TROOPER_LEAN[n])
	var out: Array[Color] = []
	for base: Color in [ARMOR_DARK, ARMOR_PLATE]:
		var c := base.lightened(v) if v >= 0.0 else base.darkened(-v)
		if lean > 0:
			c = c.lerp(TRIM_RED, 0.06)
		elif lean < 0:
			c = Color(c.r - 0.012, c.g - 0.002, c.b + 0.016)
		out.append(c)
	return out


## A box-section limb from a to b (half sizes r x r).
static func _limb(k: MeshKit, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	k.seg(a, b, Vector2(r, r), Vector2(r * 0.92, r * 0.92), 4, col, MeshKit.SQUARE)


## Whether piece `want` is built when building `piece` ("" = the whole body).
static func _pc(piece: String, want: String) -> bool:
	return piece == "" or piece == want


static func _trooper(k: MeshKit, kit: String, n: int, piece: String = "") -> void:
	var lk := trooper_look(n)
	var bp: Array = _TROOPER_BUILD[int(lk["build"])]
	var hs := float(lk["height"])
	var cols: Array = lk["colours"]
	var body: Color = cols[0]
	var plate: Color = cols[1]
	k.push(MeshKit.xf(Vector3.ZERO, Vector3.ZERO, Vector3(1.0, hs, 1.0)))
	_trooper_body(k, lk, bp, body, plate, kit == "at", piece)
	k.pop()
	if not _pc(piece, "arms"):
		return
	# Arms: shoulder (inside the pauldron, moves with the build and height) -> elbow -> hand (the kit's, fixed).
	var sx := float(bp[2])
	var lt := float(bp[1])
	var hands: Array = []   # [shoulder, elbow, hand] per arm
	if kit == "at":
		hands = [[Vector3(sx, 1.62 * hs, 0.0), Vector3(sx + 0.02, 1.28, -0.24), Vector3(0.42, 1.55, -0.6)],
			[Vector3(-sx, 1.62 * hs, 0.0), Vector3(-0.22, 1.34, -0.52), Vector3(0.34, 1.66, -1.0)]]
	else:
		hands = [[Vector3(sx, 1.62 * hs, 0.0), Vector3(sx * 0.94, 1.16, -0.18), Vector3(0.22, 1.2, -0.42)],
			[Vector3(-sx, 1.62 * hs, 0.0), Vector3(-0.3, 1.18, -0.46), Vector3(0.2, 1.28, -0.9)]]
	for arm: Array in hands:
		_limb(k, arm[0], arm[1], 0.095 * lt, body)
		_limb(k, arm[1], arm[2], 0.07 * lt, STEEL)
	if kit == "at":
		_trooper_at_kit(k)
	else:
		_trooper_rifle_kit(k)


## Legs, belt, cuirass with its brick mark, pauldrons, helmet, back gear (in the height-scaled frame).
static func _trooper_body(k: MeshKit, lk: Dictionary, bp: Array, body: Color, plate: Color, spare_tube: bool,
		piece: String = "") -> void:
	var w := float(bp[0])
	var lt := float(bp[1])
	var sx := float(bp[2])
	var ps := float(bp[3])
	var dz := (1.0 + w) * 0.5
	var leader: bool = lk["leader"]
	# Boots, greaves, thighs, cream civic shin bands, knee pads (y = 0..0.97).
	for side: float in [-1.0, 1.0]:
		var lx := side * 0.24 * (0.9 + 0.1 * w)
		var sd := "_l" if side < 0.0 else "_r"
		if _pc(piece, "boot" + sd):
			k.box(Vector3(0.28 * lt, 0.24, 0.44), body, Vector3(lx, 0.12, -0.05))
		if _pc(piece, "shin" + sd):
			k.box(Vector3(0.26 * lt, 0.44, 0.3 * lt), plate, Vector3(lx, 0.44, 0.0))
		if _pc(piece, "thigh" + sd):
			k.box(Vector3(0.28 * lt, 0.34, 0.32 * lt), body, Vector3(lx, 0.8, 0.02))
		if _pc(piece, "shin" + sd):
			k.box(Vector3(0.26 * lt + 0.02, 0.07, 0.3 * lt + 0.02), CIVIC_CREAM, Vector3(lx, 0.5, 0.0))
			k.box(Vector3(0.2 * lt, 0.16, 0.08), plate, Vector3(lx, 0.66, -0.15 * lt - 0.02))
	if piece == "head":
		_trooper_helmet(k, int(lk["helmet"]), body, plate, leader)
		return
	if not _pc(piece, "torso"):
		return
	# Hip belt with two front pouches, cuirass (y = 0.91..1.82).
	var tw := 0.84 * w
	var td := 0.52 * dz
	k.box(Vector3(0.68 * w, 0.22, 0.42 * dz), STEEL, Vector3(0.0, 1.02, 0.0))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.15, 0.14, 0.1), SLATE, Vector3(side * 0.2 * w, 1.0, -0.21 * dz - 0.04))
	k.box(Vector3(tw, 0.72, td), body, Vector3(0.0, 1.46, 0.0))
	match int(lk["mark"]):
		0:   # full brick chest band
			k.box(Vector3(tw - 0.12, 0.22, td + 0.04), TRIM_RED, Vector3(0.0, 1.56, -0.02))
		1:   # brick chevron on the chest front, point down
			for side: float in [-1.0, 1.0]:
				k.push(MeshKit.xf(Vector3(side * 0.13 * w, 1.58, -td * 0.5 - 0.015), Vector3(0.0, 0.0, side * 28.0)))
				k.box(Vector3(0.36 * w, 0.12, 0.06), TRIM_RED)
				k.pop()
		_:   # brick sash over the left shoulder
			k.push(MeshKit.xf(Vector3(0.0, 1.47, 0.0), Vector3(0.0, 0.0, -38.0)))
			k.box(Vector3(0.16, 0.86, td + 0.04), TRIM_RED)
			k.pop()
	if int(lk["build"]) == 2:   # heavy: a raised plate over the belly
		_panel(k, Vector3(0.0, 1.27, -td * 0.5), Vector3.FORWARD, 0.46 * w, 0.18, plate, Vector3.UP, 0.05, 0.03)
	# Pauldrons with brick (or, on the leader's left, cream) trim.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(ps, ps, ps * 1.33), plate, Vector3(side * sx, 1.66, 0.0))
		var lead_side := leader and side < 0.0   # the leader's left pauldron is capped cream (reads from the chase cam)
		k.box(Vector3(ps + 0.04, 0.12, ps * 1.17), CIVIC_CREAM if lead_side else TRIM_RED,
			Vector3(side * sx, 1.64 + ps * 0.5, 0.0))
	if leader:   # and a cream plate on its outer face
		k.box(Vector3(0.05, ps * 0.66, ps * 0.92), CIVIC_CREAM, Vector3(-(sx + ps * 0.5 + 0.015), 1.62, 0.0))
	if piece == "":
		_trooper_helmet(k, int(lk["helmet"]), body, plate, leader)
	var back := _trooper_gear(k, int(lk["gear"]), w, td * 0.5, body, plate)
	if spare_tube:   # the AT trooper's spare rocket tube strapped behind the pack
		k.tube(Vector3(-0.24, 1.25, back + 0.06), Vector3(-0.24, 2.06, back + 0.06), 0.11, 6, TRIM_RED)


## Helmet `h` (0 dome + visor, 1 angular crest, 2 flat-top with comm box). Peaks 2.22-2.29 m before the height scale.
static func _trooper_helmet(k: MeshKit, h: int, body: Color, plate: Color, leader: bool) -> void:
	match h:
		0:
			k.lathe([Vector2(0.21, 1.8), Vector2(0.255, 1.98), Vector2(0.2, 2.15), Vector2(0.075, 2.25)], 6, body)
			k.box(Vector3(0.36, 0.05, 0.12), STEEL, Vector3(0.0, 2.08, -0.2))           # brow ridge
			k.box(Vector3(0.38, 0.1, 0.12), plate, Vector3(0.0, 1.86, 0.19))           # neck guard
			k.glow = true
			k.box(Vector3(0.3, 0.1, 0.08), OPTIC_GLOW, Vector3(0.0, 1.99, -0.215))
			k.glow = false
			if leader:   # cream stripe front to back over the crown
				var pts := [Vector3(0.0, 2.07, -0.215), Vector3(0.0, 2.245, -0.04), Vector3(0.0, 2.245, 0.04),
					Vector3(0.0, 2.07, 0.215)]
				for i in 3:
					k.seg(pts[i], pts[i + 1], Vector2(0.075, 0.04), Vector2(0.075, 0.04), 4, CIVIC_CREAM, MeshKit.SQUARE)
		1:
			k.box(Vector3(0.44, 0.36, 0.48), body, Vector3(0.0, 1.99, -0.02))
			k.box(Vector3(0.46, 0.06, 0.42), plate, Vector3(0.0, 2.18, 0.0))
			# Crest fin rising toward the back (brick; cream on a leader).
			k.push(_face_xf(Vector3(0.0, 2.2, 0.0), Vector3.RIGHT))
			_prism(k, [Vector2(0.2, -0.01), Vector2(-0.25, -0.01), Vector2(-0.25, 0.075), Vector2(0.06, 0.05)], -0.06,
				0.06, CIVIC_CREAM if leader else TRIM_RED)
			k.pop()
			for side: float in [-1.0, 1.0]:   # angled steel cheek guards
				k.push(MeshKit.xf(Vector3(side * 0.235, 1.92, -0.12), Vector3(0.0, side * 14.0, 0.0)))
				k.box(Vector3(0.06, 0.22, 0.26), STEEL)
				k.pop()
			k.glow = true
			k.box(Vector3(0.34, 0.1, 0.1), OPTIC_GLOW, Vector3(0.0, 2.0, -0.25))
			k.glow = false
		_:
			k.box(Vector3(0.48, 0.36, 0.48), body, Vector3(0.0, 2.0, -0.02))
			k.box(Vector3(0.56, 0.07, 0.56), plate, Vector3(0.0, 2.195, -0.03))       # flat top / brim
			k.box(Vector3(0.36, 0.08, 0.1), STEEL, Vector3(0.0, 1.86, -0.25))         # chin guard
			k.box(Vector3(0.1, 0.2, 0.2), STEEL, Vector3(0.29, 2.0, 0.04))            # comm box
			_whip(k, Vector3(0.3, 2.1, 0.08), Vector3(0.36, 2.56, 0.2), 0.018)
			if leader:
				k.box(Vector3(0.16, 0.04, 0.58), CIVIC_CREAM, Vector3(0.0, 2.24, -0.03))
			k.glow = true
			k.box(Vector3(0.42, 0.07, 0.1), OPTIC_GLOW, Vector3(0.0, 1.96, -0.25))
			k.glow = false


## Back gear `g` (0 jump pack with nozzles, 1 tall radio pack with a long whip, 2 pouch belt + low pack with a bedroll) on a
## cuirass of width factor `w` whose back face is at z = `zb`, with the Descent stencil on the pack. Returns the pack's
## back face z.
static func _trooper_gear(k: MeshKit, g: int, w: float, zb: float, body: Color, plate: Color) -> float:
	var back := zb
	match g:
		0:
			back = zb + 0.29
			k.box(Vector3(0.58 * w, 0.62, 0.3), plate, Vector3(0.0, 1.48, back - 0.15))
			for side: float in [-1.0, 1.0]:
				k.tube(Vector3(side * 0.18, 1.24, back - 0.11), Vector3(side * 0.2, 1.0, back - 0.07), 0.09, 4, STEEL)
				k.glow = true
				k.box(Vector3(0.12, 0.06, 0.12), VENT_GLOW, Vector3(side * 0.2, 0.98, back - 0.07))
				k.glow = false
			_emblem(k, Vector3(0.0, 1.55, back), Vector3.BACK, 0.42, false)
		1:
			back = zb + 0.27
			k.box(Vector3(0.44, 0.8, 0.28), body, Vector3(-0.04, 1.52, back - 0.14))
			k.box(Vector3(0.32, 0.12, 0.22), STEEL, Vector3(-0.04, 1.97, back - 0.15))   # radio head
			k.box(Vector3(0.12, 0.22, 0.16), SLATE, Vector3(-0.31, 1.36, back - 0.14))   # handset pouch
			_whip(k, Vector3(0.1, 2.0, back - 0.1), Vector3(0.2, 2.78, back + 0.12), 0.022)
			_emblem(k, Vector3(-0.04, 1.6, back), Vector3.BACK, 0.34, false)
		_:
			back = zb + 0.22
			k.box(Vector3(0.5 * w, 0.42, 0.22), plate, Vector3(0.0, 1.4, back - 0.11))
			k.tube(Vector3(-0.27 * w, 1.68, back - 0.1), Vector3(0.27 * w, 1.68, back - 0.1), 0.09, 6, SLATE)  # bedroll
			for side: float in [-1.0, 1.0]:   # side and rear belt pouches
				k.box(Vector3(0.1, 0.16, 0.18), SLATE, Vector3(side * (0.34 * w + 0.04), 1.0, 0.0))
				k.box(Vector3(0.14, 0.15, 0.1), body, Vector3(side * 0.17 * w, 1.0, zb * 0.81 + 0.04))
			_emblem(k, Vector3(0.0, 1.4, back), Vector3.BACK, 0.34, false)
	return back


## Assault kit: long anti-armour pulse rifle (muzzle z -1.48 m) with stock, sight, magazine and service lamp.
static func _trooper_rifle_kit(k: MeshKit) -> void:
	k.box(Vector3(0.18, 0.24, 0.92), ARMOR_DARK, Vector3(0.22, 1.38, -0.68))
	k.box(Vector3(0.12, 0.16, 0.3), SLATE, Vector3(0.22, 1.4, -0.12))              # stock into the shoulder
	k.tube(Vector3(0.22, 1.4, -1.06), Vector3(0.22, 1.4, -1.48), 0.06, 6, STEEL)
	k.glow = true
	k.box(Vector3(0.12, 0.1, 0.14), OPTIC_GLOW, Vector3(0.22, 1.54, -0.68))
	k.glow = false
	k.box(Vector3(0.1, 0.22, 0.14), SLATE, Vector3(0.22, 1.2, -0.66))
	_lamp(k, Vector3(0.22, 1.23, -1.1), Vector3.FORWARD, Vector3(0.09, 0.09, 0.14), CIVIC_CREAM)
	k.box(Vector3(0.12, 0.11, 0.1), SLATE, Vector3(0.22, 1.4, -1.44))              # muzzle brake


## Anti-armour kit: oversized shoulder launcher (z +0.76..-1.52 m) with brick launch collar, cream band and optic.
static func _trooper_at_kit(k: MeshKit) -> void:
	k.tube(Vector3(0.42, 1.88, 0.76), Vector3(0.42, 1.88, -1.5), 0.18, 6, ARMOR_DARK)
	k.tube(Vector3(0.42, 1.88, -1.32), Vector3(0.42, 1.88, -1.52), 0.23, 6, TRIM_RED)
	k.tube(Vector3(0.42, 1.88, 0.62), Vector3(0.42, 1.88, 0.8), 0.22, 6, STEEL)
	k.tube(Vector3(0.42, 1.88, -0.32), Vector3(0.42, 1.88, -0.16), 0.2, 6, CIVIC_CREAM)
	k.glow = true
	k.box(Vector3(0.12, 0.12, 0.22), OPTIC_GLOW, Vector3(0.24, 1.98, -0.78))
	k.glow = false
	k.box(Vector3(0.14, 0.08, 0.28), STEEL, Vector3(0.24, 1.88, -0.78))
	k.box(Vector3(0.1, 0.2, 0.14), SLATE, Vector3(0.42, 1.68, -0.6))


# --- Close-Range Rocket Gunship (5.6 W x 6.8 L x 2.8 H; origin at the fuselage centre, faces -Z) ------------
# The habitat's old civil-defence rescue VTOL, repainted. Three parts share the gunship's frame (EnemyGunship mounts all
# three at BodyPivot's origin): hull (core), pods (disarmable, muzzles at (+-1.9, -0.25, -2.1)), thrusters (weak point).

## Outward centre and normal of the facet between ring points a and b (an axis-"z" loft ring around centre c).
static func _facet(c: Vector3, a: Vector3, b: Vector3) -> Array:
	var m := (a + b) * 0.5
	var e := b - a
	var n := Vector3(e.y, -e.x, 0.0).normalized()
	if n.dot(m - c) < 0.0:
		n = -n
	return [m, n]


## Fuselage, cockpit hump with the red visor, stub wings, twin canted tail fins, chin searchlight. Civic leftovers: crew
## doors, unit-number plates, amber beacons, a Descent stencil on the belly (players mostly see it from below).
static func _gunship_hull(k: MeshKit) -> void:
	k.loft([
		MeshKit.ring(Vector3(0.0, 0.15, 3.0), 0.65, 0.42, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, 0.12, 1.40), 1.15, 0.82, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, 0.05, -0.80), 1.22, 0.88, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, -0.10, -2.65), 0.85, 0.56, 6, "z", 2.8),
		MeshKit.ring(Vector3(0.0, -0.22, -3.40), 0.42, 0.28, 6, "z", 2.8),
	], [ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK, ARMOR_PLATE])
	# Brick dorsal spine with an amber service light bar.
	k.box(Vector3(0.9, 0.16, 2.5), TRIM_RED, Vector3(0.0, 0.88, 0.35))
	_light_bar(k, Vector3(0.0, 0.96, 1.15), 0.7)
	# Cockpit hump: red visor bar under a steel hood, a roof hatch.
	k.box(Vector3(1.0, 0.42, 1.3), ARMOR_DARK, Vector3(0.0, 0.62, -1.75))
	k.glow = true
	k.box(Vector3(0.9, 0.22, 0.16), OPTIC_GLOW, Vector3(0.0, 0.62, -2.42))
	k.glow = false
	_optic_hood(k, Vector3(0.0, 0.62, -2.42), 0.9, 0.22, -2.5)
	_panel(k, Vector3(0.0, 0.83, -1.62), Vector3.UP, 0.6, 0.5, STEEL, Vector3.FORWARD)
	for side: float in [-1.0, 1.0]:
		# Swept stub wing (the pod hangs under its tip): slate-rimmed top plate, brick leading-edge band, amber tip lamp.
		k.push(MeshKit.xf(Vector3(side * 1.75, 0.18, -0.35), Vector3(0.0, side * 12.0, -side * 8.0)))
		k.box(Vector3(1.45, 0.26, 1.5), ARMOR_PLATE)
		k.box(Vector3(1.2, 0.1, 0.46), TRIM_RED, Vector3(0.0, 0.16, -0.3))
		_panel(k, Vector3(0.05, 0.13, 0.35), Vector3.UP, 0.9, 0.5, ARMOR_DARK, Vector3.FORWARD)
		_lamp(k, Vector3(side * 0.725, 0.0, 0.0), Vector3(side, 0.0, 0.0), Vector3(0.3, 0.16, 0.14), LAMP_AMBER)
		k.pop()
		# Canted tail fin with a brick tip and a unit plate.
		k.push(MeshKit.xf(Vector3(side * 0.85, 0.92, 2.55), Vector3(-16.0, 0.0, -side * 22.0)))
		k.box(Vector3(0.18, 1.15, 1.10), ARMOR_DARK)
		k.box(Vector3(0.22, 0.26, 0.85), TRIM_RED, Vector3(0.0, 0.42, 0.05))
		_plate(k, Vector3(side * 0.09, -0.08, 0.0), Vector3(side, 0.0, 0.0), 0.5, 0.18)
		k.pop()
		# A crew door on the forward upper flank, a unit plate on the rear lower flank.
		var fc := Vector3(0.0, -0.007, -1.5)
		var fwd := MeshKit.ring(fc, 1.08, 0.759, 6, "z", 2.8)
		var f0 := _facet(fc, fwd[0], fwd[1])
		var door_pos: Vector3 = f0[0]
		var door_n: Vector3 = f0[1]
		_panel(k, Vector3(side * door_pos.x, door_pos.y, -1.5), Vector3(side * door_n.x, door_n.y, 0.0), 0.7, 0.5, STEEL)
		var ac := Vector3(0.0, 0.104, 0.9)
		var aft := MeshKit.ring(ac, 1.166, 0.834, 6, "z", 2.8)
		var f1 := _facet(ac, aft[1], aft[2])
		var pl_pos: Vector3 = f1[0]
		var pl_n: Vector3 = f1[1]
		_plate(k, Vector3(side * pl_pos.x, pl_pos.y, 0.9), Vector3(side * pl_n.x, pl_n.y, 0.0), 0.6, 0.22)
	# Chin searchlight turret (amber lens, slate hub caps).
	k.box(Vector3(0.7, 0.38, 0.8), STEEL, Vector3(0.0, -0.62, -2.05))
	_lamp(k, Vector3(0.0, -0.64, -2.45), Vector3.FORWARD, Vector3(0.4, 0.24, 0.14), LAMP_AMBER)
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.35, -0.62, -2.05), Vector3(side * 0.41, -0.62, -2.05), 0.15, 6, SLATE)
	# Slatted vent on the rear top slope, amber tail lamp, Descent stencil on the belly.
	_vent(k, Vector3(0.0, 0.74, 2.05), Vector3(0.0, 0.979, 0.203), 0.6, 0.45, 3)
	_lamp(k, Vector3(0.0, 0.15, 3.0), Vector3.BACK, Vector3(0.3, 0.2, 0.14), LAMP_AMBER)
	_emblem(k, Vector3(0.0, -0.643, 1.0), Vector3.DOWN, 0.8, true, Vector3.FORWARD)


## Twin 2x2 close-range rocket pods under the wing tips (muzzles at (+-1.9, -0.25, -2.1), facing -Z).
static func _gunship_pods(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		var px := side * 1.9
		k.box(Vector3(0.9, 0.84, 2.2), ARMOR_DARK, Vector3(px, -0.2, -0.85))
		k.box(Vector3(0.96, 0.12, 1.6), TRIM_RED, Vector3(px, 0.2, -0.75))
		k.box(Vector3(0.32, 0.36, 1.1), STEEL, Vector3(side * 1.5, 0.12, -0.75))   # pylon
		for r in 2:
			for c in 2:
				var ox := px + (float(c) - 0.5) * 0.40
				var oy := -0.25 + (float(r) - 0.5) * 0.36
				k.tube(Vector3(ox, oy, -1.9), Vector3(ox, oy, -2.1), 0.14, 6, STEEL)
				k.glow = true
				k.tube(Vector3(ox, oy, -2.08), Vector3(ox, oy, -2.2), 0.1, 4, OPTIC_GLOW, 0.03)
				k.glow = false
		# Raised steel frame above and below the tube block, a red sight lamp on the pod top.
		for fy: float in [0.14, -0.6]:
			k.box(Vector3(0.94, 0.1, 0.1), STEEL, Vector3(px, fy, -2.0))
		k.glow = true
		k.box(Vector3(0.4, 0.1, 0.12), OPTIC_GLOW, Vector3(px, 0.27, -1.75))
		k.glow = false
		# Lifting lugs, a slatted vent on the outer face, a rear hub cap.
		for lz: float in [-1.2, -0.3]:
			k.box(Vector3(0.2, 0.1, 0.24), STEEL, Vector3(px, 0.3, lz))
		_vent(k, Vector3(side * 2.35, -0.25, -0.5), Vector3(side, 0.0, 0.0), 0.9, 0.4, 2)
		k.tube(Vector3(px, -0.2, 0.25), Vector3(px, -0.2, 0.33), 0.3, 6, STEEL)


## Twin ducted jet nacelles at (+-2.2, 0.45, 1.1): the critical weak point. Glowing intake fan, exhaust and belly VTOL
## vent read from the front, the back and below.
static func _gunship_thrusters(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		var tx := side * 2.2
		k.box(Vector3(1.1, 0.26, 0.7), STEEL, Vector3(side * 1.6, 0.45, 1.1))   # pylon
		_hose(k, [Vector3(side * 1.15, 0.62, 0.9), Vector3(side * 1.75, 0.64, 0.9)], 0.06)
		k.loft([
			MeshKit.ring(Vector3(tx, 0.45, 0.14), 0.44, 0.44, 8, "z"),
			MeshKit.ring(Vector3(tx, 0.45, 0.3), 0.5, 0.5, 8, "z"),
			MeshKit.ring(Vector3(tx, 0.45, 1.75), 0.5, 0.5, 8, "z"),
			MeshKit.ring(Vector3(tx, 0.45, 2.1), 0.4, 0.4, 8, "z"),
		], [ARMOR_PLATE, ARMOR_PLATE, ARMOR_DARK])
		k.tube(Vector3(tx, 0.45, 0.66), Vector3(tx, 0.45, 0.92), 0.53, 8, TRIM_RED)   # brick band
		k.tube(Vector3(tx, 0.45, 0.02), Vector3(tx, 0.45, 0.16), 0.47, 8, STEEL)     # intake lip
		k.tube(Vector3(tx, 0.45, 2.05), Vector3(tx, 0.45, 2.36), 0.36, 8, STEEL)     # exhaust nozzle
		_panel(k, Vector3(tx, 0.912, 1.3), Vector3.UP, 0.42, 0.5, STEEL, Vector3.FORWARD)
		_lamp(k, Vector3(tx + side * 0.462, 0.45, 1.45), Vector3(side, 0.0, 0.0), Vector3(0.24, 0.16, 0.12), LAMP_AMBER)
		k.seg(Vector3(tx, 0.45, 0.0), Vector3(tx, 0.45, -0.14), Vector2(0.12, 0.12), Vector2.ZERO, 8, STEEL)   # spinner
		k.glow = true
		k.tube(Vector3(tx, 0.45, 0.04), Vector3(tx, 0.45, 0.0), 0.34, 8, VENT_GLOW)     # intake fan
		k.tube(Vector3(tx, 0.45, 2.34), Vector3(tx, 0.45, 2.40), 0.27, 8, VENT_GLOW)    # exhaust
		k.box(Vector3(0.56, 0.12, 0.9), VENT_GLOW, Vector3(tx, -0.05, 1.1))             # belly VTOL vent
		k.glow = false


# --- Armored Drop Ship (5.2 W x 6.8 L x 2.8 H; origin at the fuselage centre, faces -Z) -----------------------
# The habitat's old civil-defence heavy lifter, repainted. hull (core), rotors (critical weak point), bay (ventral troop
# bay; EnemyDropDrone slides it down 0.35 m as it opens, and the drop telegraph's orb sits at its door, (0, -1.2, 0.1)).

## Boxy cabin with a sloped red windscreen, twin tail booms with brick fins, the rotor spar. Civic leftovers: crew doors,
## Descent stencils, unit plates, amber beacons, a roof hatch and vent, a chin searchlight.
static func _dropship_hull(k: MeshKit) -> void:
	k.loft([
		MeshKit.ring(Vector3(0.0, 0.15, 2.1), 1.12, 0.72, 8, "z", 4.0),
		MeshKit.ring(Vector3(0.0, 0.15, 1.8), 1.2, 0.78, 8, "z", 4.0),
		MeshKit.ring(Vector3(0.0, 0.15, -1.9), 1.2, 0.78, 8, "z", 4.0),
		MeshKit.ring(Vector3(0.0, 0.05, -2.65), 1.0, 0.62, 8, "z", 4.0),
		MeshKit.ring(Vector3(0.0, -0.05, -3.35), 0.6, 0.38, 8, "z", 4.0),
	], [ARMOR_DARK, ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK])
	k.box(Vector3(1.6, 0.16, 3.4), ARMOR_PLATE, Vector3(0.0, 0.96, -0.1))   # roof plate
	# Sloped windscreen: a red visor in a steel frame.
	k.push(_face_xf(Vector3(0.0, 0.48, -3.0), Vector3(0.0, 0.904, -0.427)))
	k.box(Vector3(1.0, 0.42, 0.05), STEEL)
	k.glow = true
	k.box(Vector3(0.86, 0.28, 0.08), OPTIC_GLOW)
	k.glow = false
	k.pop()
	_lamp(k, Vector3(0.0, -0.47, -3.05), Vector3(0.0, -0.5, -0.866), Vector3(0.36, 0.26, 0.16), LAMP_AMBER)   # searchlight
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.22, 3.4), TRIM_RED, Vector3(side * 1.17, -0.18, -0.05))   # brick flank band
		_panel(k, Vector3(side * 1.153, 0.27, -1.1), Vector3(side, 0.0, 0.0), 1.0, 0.56, ARMOR_PLATE)   # crew door
		_emblem(k, Vector3(side * 1.153, 0.27, 1.0), Vector3(side, 0.0, 0.0), 0.62)
		# Tail boom with a brick fin, unit plate and amber tail lamp.
		k.box(Vector3(0.5, 0.6, 1.5), ARMOR_PLATE, Vector3(side * 0.85, 0.42, 2.45))
		k.box(Vector3(0.2, 0.7, 0.85), TRIM_RED, Vector3(side * 0.95, 1.0, 2.75))
		_plate(k, Vector3(side * 1.1, 0.42, 2.5), Vector3(side, 0.0, 0.0), 0.6, 0.22)
		_lamp(k, Vector3(side * 0.85, 0.42, 3.2), Vector3.BACK, Vector3(0.24, 0.18, 0.12), LAMP_AMBER)
	k.box(Vector3(2.0, 0.16, 0.55), ARMOR_DARK, Vector3(0.0, 0.95, 2.95))   # tail stabiliser bridge
	k.box(Vector3(3.2, 0.3, 0.9), STEEL, Vector3(0.0, 0.52, 0.0))           # rotor spar
	# Roof: a hatch with a hinge barrel, a slatted vent, an amber service light bar.
	_panel(k, Vector3(0.0, 1.04, 0.9), Vector3.UP, 0.8, 0.6, STEEL, Vector3.FORWARD)
	k.tube(Vector3(-0.38, 1.08, 1.25), Vector3(0.38, 1.08, 1.25), 0.05, 6, STEEL)
	_vent(k, Vector3(0.0, 1.04, -0.4), Vector3.UP, 1.0, 0.5, 3, Vector3.FORWARD)
	_light_bar(k, Vector3(0.0, 1.04, -1.5), 1.0)


## Twin ducted lift fans at (+-2.2, 0.55, 0): the critical weak point. An octagonal duct of closed slabs round a glowing
## fan disc set at mid-depth (reads from below and from above), glowing intake slits on the fairings' front and back faces.
static func _dropship_rotors(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		var c := Vector3(side * 2.2, 0.55, 0.0)
		for i in 8:
			k.push(Transform3D(Basis(Vector3.UP, TAU * (float(i) + 0.5) / 8.0), c))
			k.box(Vector3(0.54, 0.62, 0.14), ARMOR_PLATE, Vector3(0.0, 0.0, -0.55))
			k.pop()
		for fz: float in [-0.78, 0.78]:
			k.box(Vector3(0.5, 0.5, 0.5), ARMOR_DARK, c + Vector3(0.0, 0.0, fz))
			k.box(Vector3(0.54, 0.1, 0.46), TRIM_RED, c + Vector3(0.0, 0.3, fz))
		k.box(Vector3(0.36, 0.26, 0.6), STEEL, Vector3(side * 1.62, 0.52, 0.0))   # strut to the spar
		_hose(k, [Vector3(side * 1.4, 0.7, 0.35), Vector3(side * 1.95, 0.75, 0.62)], 0.06)
		_lamp(k, c + Vector3(side * 0.25, 0.1, -0.78), Vector3(side, 0.0, 0.0), Vector3(0.22, 0.16, 0.12), LAMP_AMBER)
		# Fan: steel hub and three blades over the glowing disc.
		k.tube(c + Vector3(0.0, -0.1, 0.0), c + Vector3(0.0, 0.2, 0.0), 0.14, 6, STEEL)
		for b in 3:
			k.push(Transform3D(Basis(Vector3.UP, TAU * float(b) / 3.0), c))
			k.box(Vector3(0.12, 0.05, 0.42), STEEL, Vector3(0.0, 0.13, -0.27))
			k.pop()
		k.glow = true
		k.tube(c + Vector3(0.0, -0.01, 0.0), c + Vector3(0.0, 0.07, 0.0), 0.47, 8, VENT_GLOW)
		for fz: float in [-1.035, 1.035]:
			k.box(Vector3(0.32, 0.2, 0.04), VENT_GLOW, c + Vector3(0.0, 0.05, fz))
		k.glow = false


## Ventral troop bay (X +-1.1, Y -1.25..-0.55, Z -1.2..1.4): two steel door leaves on a slate seam that glows amber, a
## chunky hazard band, hinge barrels, amber jump-light strips down both sides, latch blocks, a unit plate.
static func _dropship_bay(k: MeshKit) -> void:
	k.box(Vector3(2.1, 0.6, 2.5), ARMOR_DARK, Vector3(0.0, -0.88, 0.1))
	k.box(Vector3(1.96, 0.04, 2.36), SLATE, Vector3(0.0, -1.19, 0.1))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.94, 0.05, 2.3), STEEL, Vector3(side * 0.5, -1.2, 0.1))
		k.tube(Vector3(side * 0.98, -1.18, -1.0), Vector3(side * 0.98, -1.18, 1.2), 0.05, 6, STEEL)
		for sz: float in [-1.0, 1.0]:
			k.box(Vector3(0.16, 0.14, 0.16), STEEL, Vector3(side * 1.0, -1.1, 0.1 + sz * 1.17))
	_hazard(k, Vector3(0.0, -1.215, -0.95), Vector3.DOWN, 1.8, 0.36, 3, Vector3.FORWARD)
	_plate(k, Vector3(0.0, -0.88, 1.35), Vector3.BACK, 0.6, 0.2)
	k.glow = true
	k.box(Vector3(0.05, 0.04, 1.9), VENT_GLOW, Vector3(0.0, -1.2, 0.2))   # glowing door seam
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.06, 0.12, 2.0), VENT_GLOW, Vector3(side * 1.07, -1.02, 0.1))
	k.glow = false
