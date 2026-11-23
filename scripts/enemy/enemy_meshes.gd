class_name EnemyMeshes
extends RefCounted
## Low-poly MeshKit builders & high-contrast invader palette for all 3 enemy classes (docs/design/enemies.md §2).
## Cosmetic only: flat-shaded vertex colours using MechMeshes.materials() ([matte, glow]), cached by part id.

const ARMOR_DARK := Color(0.11, 0.12, 0.15)     ## obsidian charcoal-indigo: pops sharply against bright cream/sage city
const ARMOR_PLATE := Color(0.21, 0.23, 0.28)    ## cool blue-slate bevel plates so facets read under daylight
const STEEL := Color(0.34, 0.36, 0.40)          ## gunmetal joints, treads, barrels
const TRIM_RED := Color(0.76, 0.11, 0.14)       ## bold invader crimson stripes & occupation chevrons
const OPTIC_GLOW := Color(1.0, 0.14, 0.18)      ## unshaded crimson eyes / sensors
const VENT_GLOW := Color(1.0, 0.40, 0.10)       ## unshaded glowing heat-sink radiator fins
const CHARRED := Color(0.08, 0.08, 0.09)        ## destroyed part / wreck hull
const FLASH_COL := Color(1.0, 0.72, 0.62)       ## brief hit-flash overlay tint

static var _cache: Dictionary = {}
static var _flash_mat: StandardMaterial3D
static var _charred_mat: StandardMaterial3D
static var _scanner_mat: StandardMaterial3D


static func mesh(part: String) -> ArrayMesh:
	if _cache.has(part):
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
		"tank_hull": _tank_hull(k)
		"tank_turret": _tank_turret(k)
		"tank_turret_wreck": _tank_turret_wreck(k)
		"tank_vents": _tank_vents(k)
		"drone_hull": _drone_hull(k)
		"drone_optic": _drone_optic(k)
		"drone_cone": _drone_cone(k)
		"trooper_rifle": _trooper_rifle(k)
		"trooper_at": _trooper_at(k)
		"debris_plate": _debris_plate(k)
		"debris_chunk": _debris_chunk(k)
		"rupture_core": _rupture_core(k)
		_:
			k.box(Vector3.ONE, ARMOR_DARK)
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
		_scanner_mat.albedo_color = Color(1.0, 0.34, 0.14, 0.22)
		_scanner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _scanner_mat


## Pre-cache destruction & flame meshes once at setup so first kill in combat causes zero frame spike.
static func prewarm() -> void:
	for p: String in ["debris_plate", "debris_chunk", "rupture_core", "turret_gun_wreck", "tank_turret_wreck",
			"turret_sniper_gun", "turret_missile_gun", "strider_breacher_chassis", "drone_hull", "drone_optic", "drone_cone",
			"trooper_rifle", "trooper_at"]:
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


# --- Enforcer Turret (4.8 W x 4.8 D x 5.6 H) ---------------------------------------------------------------

static func _turret_base(k: MeshKit) -> void:
	# Broad octagonal armored bunker plinth (y = 0..1.45), neck ring up to y = 2.15.
	k.lathe([Vector2(2.4, 0.0), Vector2(2.35, 0.55), Vector2(1.95, 1.45), Vector2(1.45, 1.55)], 8,
		[ARMOR_DARK, ARMOR_PLATE, ARMOR_DARK], true, true)
	# Heavy steel pedestal neck.
	k.lathe([Vector2(1.25, 1.45), Vector2(1.15, 2.15)], 8, STEEL, false, true)
	# Four diagonal armored buttress feet with crimson stripes (4.8 m span).
	for i in 4:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 45.0 + 90.0 * i, 0)))
		k.box(Vector3(0.95, 1.15, 1.3), ARMOR_DARK, Vector3(0.0, 0.58, -1.85))
		k.box(Vector3(1.05, 0.24, 0.65), TRIM_RED, Vector3(0.0, 0.92, -2.05))
		k.box(Vector3(0.7, 0.22, 0.5), STEEL, Vector3(0.0, 0.11, -2.35))
		k.pop()
	# Status corner pips on the plinth rim.
	k.glow = true
	for i in 4:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 90.0 * i, 0)))
		k.box(Vector3(0.55, 0.14, 0.1), OPTIC_GLOW, Vector3(0.0, 1.15, -2.02))
		k.pop()
	k.glow = false


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
	k.box(Vector3(0.16, 0.95, 0.45), ARMOR_PLATE, Vector3(0.55, 2.95, 0.45))   # dorsal fin -> 5.6 m
	k.glow = true
	k.box(Vector3(1.05, 0.42, 0.18), OPTIC_GLOW, Vector3(0.0, 2.52, -0.72))   # bright cyclops optic bar
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


static func _turret_gun_wreck(k: MeshKit) -> void:
	k.lathe([Vector2(1.4, 0.0), Vector2(1.2, 0.55), Vector2(0.7, 0.75)], 8, CHARRED, true, true)
	k.box(Vector3(0.6, 0.45, 1.4), CHARRED, Vector3(-0.4, 0.45, -0.5))


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
		k.pop()
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


## Head-level weak-point sensor pod (origin at (0, 4.3, -1.2) world -> (0, 1.7, -1.2) relative to pelvis).
static func _strider_sensor(k: MeshKit) -> void:
	k.box(Vector3(1.25, 0.78, 1.05), ARMOR_DARK, Vector3(0.0, 0.0, 0.0))
	k.box(Vector3(1.32, 0.18, 0.82), TRIM_RED, Vector3(0.0, 0.42, 0.05))
	k.glow = true
	k.box(Vector3(1.1, 0.28, 0.14), OPTIC_GLOW, Vector3(0.0, -0.02, -0.54))
	k.glow = false


## One reverse-jointed leg hanging from hip (0, 0, 0) down to foot at y = -2.6 m (authored for +X right leg).
static func _strider_leg(k: MeshKit) -> void:
	# Hip ball + armored thigh pod angling back to reverse knee.
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.32, 0.32, 0.32), STEEL)
	k.seg(Vector3(0.0, 0.0, 0.0), Vector3(0.18, -1.05, 0.55), Vector2(0.36, 0.42), Vector2(0.28, 0.34), 6, ARMOR_DARK)
	k.box(Vector3(0.16, 0.55, 0.48), TRIM_RED, Vector3(0.36, -0.52, 0.26))
	# Reverse knee drum.
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
	# Turret ring collar.
	k.lathe([Vector2(1.9, 2.55), Vector2(1.85, 2.8)], 10, STEEL, false, true)


## Glowing rear/top radiator weak point (origin at (0, 2.75, 3.1), pops visually from rooftops & flanks).
static func _tank_vents(k: MeshKit) -> void:
	k.box(Vector3(3.2, 0.55, 2.3), ARMOR_DARK, Vector3(0.0, 0.15, 0.0))
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.28, 0.82, 2.42), TRIM_RED, Vector3(side * 1.56, 0.32, 0.0))
	k.glow = true
	for i in 4:
		var z := -0.78 + float(i) * 0.52
		k.box(Vector3(2.7, 0.32, 0.24), VENT_GLOW, Vector3(0.0, 0.58, z))
	k.box(Vector3(2.4, 0.38, 0.16), VENT_GLOW, Vector3(0.0, 0.25, 1.18))   # rear face glow too
	k.glow = false


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
	k.box(Vector3(0.18, 0.18, 2.2), OPTIC_GLOW, Vector3(0.0, 1.38, -4.2))   # glowing charge rail along barrel
	k.glow = false


static func _tank_turret_wreck(k: MeshKit) -> void:
	k.lathe([Vector2(1.85, 0.0), Vector2(1.5, 0.65), Vector2(1.0, 0.9)], 8, CHARRED, true, true)
	k.tube(Vector3(0.0, 0.55, -0.4), Vector3(0.3, 0.7, -2.2), 0.28, 6, CHARRED)


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
	k.pop()
	# Oversized breacher shoulder shields (4.2 m span).
	for side: float in [-1.0, 1.0]:
		k.push(MeshKit.xf(Vector3(side * 1.72, 1.45, -0.25), Vector3(0.0, 0.0, -side * 12.0)))
		k.box(Vector3(0.86, 1.22, 2.35), ARMOR_DARK)
		k.box(Vector3(0.92, 0.36, 1.95), TRIM_RED, Vector3(0.0, 0.30, -0.08))
		k.pop()
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
		k.pop()


## Drone belly crimson optic dome (weak point at (0, -0.35, -0.55)).
static func _drone_optic(k: MeshKit) -> void:
	k.ico(Vector3(0.0, 0.0, 0.0), Vector3(0.48, 0.38, 0.52), ARMOR_DARK)
	k.glow = true
	k.ico(Vector3(0.0, -0.05, -0.30), Vector3(0.30, 0.24, 0.26), OPTIC_GLOW)
	k.glow = false


## Watertight downward translucent scanner frustum (origin at belly optic, extends along -Z / -Y).
static func _drone_cone(k: MeshKit) -> void:
	k.lathe([Vector2(0.18, 0.0), Vector2(2.6, -9.5)], 8, VENT_GLOW, true, true)


## Shared bulky 2.26 m armored exo-trooper body (obsidian/slate + crimson chest chevron + glowing visor + jump-pack).
static func _trooper_body(k: MeshKit) -> void:
	# Heavy armored boots & greaves (y = 0.0..0.95).
	for side: float in [-1.0, 1.0]:
		var lx := side * 0.24
		k.box(Vector3(0.28, 0.24, 0.44), ARMOR_DARK, Vector3(lx, 0.12, -0.05))
		k.box(Vector3(0.26, 0.44, 0.30), ARMOR_PLATE, Vector3(lx, 0.44, 0.0))
		k.box(Vector3(0.28, 0.34, 0.32), ARMOR_DARK, Vector3(lx, 0.80, 0.02))
	# Armored hip belt & torso cuirass (y = 0.94..1.80).
	k.box(Vector3(0.68, 0.22, 0.42), STEEL, Vector3(0.0, 1.02, 0.0))
	k.box(Vector3(0.84, 0.72, 0.52), ARMOR_DARK, Vector3(0.0, 1.46, 0.0))
	k.box(Vector3(0.72, 0.22, 0.56), TRIM_RED, Vector3(0.0, 1.56, -0.02))       # bold crimson chest chevron
	# Broad armored shoulder pauldrons + upper arms.
	for side: float in [-1.0, 1.0]:
		k.box(Vector3(0.36, 0.36, 0.48), ARMOR_PLATE, Vector3(side * 0.56, 1.66, 0.0))
		k.box(Vector3(0.40, 0.12, 0.42), TRIM_RED, Vector3(side * 0.58, 1.82, 0.0))
		k.box(Vector3(0.22, 0.46, 0.24), ARMOR_DARK, Vector3(side * 0.54, 1.32, -0.10))
	# Visored combat helmet (peaks ~2.26 m) + bright unshaded crimson visor strip.
	k.box(Vector3(0.46, 0.42, 0.48), ARMOR_DARK, Vector3(0.0, 2.02, -0.02))
	k.box(Vector3(0.48, 0.10, 0.44), ARMOR_PLATE, Vector3(0.0, 2.22, 0.0))
	k.glow = true
	k.box(Vector3(0.40, 0.14, 0.12), OPTIC_GLOW, Vector3(0.0, 2.02, -0.25))     # bright crimson visor
	k.glow = false
	# Backpack jump-thruster pack with twin downward nozzles.
	k.box(Vector3(0.58, 0.62, 0.30), ARMOR_PLATE, Vector3(0.0, 1.48, 0.36))
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.18, 1.24, 0.40), Vector3(side * 0.20, 1.00, 0.44), 0.09, 6, STEEL)
		k.glow = true
		k.box(Vector3(0.12, 0.06, 0.12), VENT_GLOW, Vector3(side * 0.20, 0.98, 0.44))
		k.glow = false


## Assault exo-trooper (troop_squad): heavy long anti-armor pulse rifle extending to z = -1.48 m.
static func _trooper_rifle(k: MeshKit) -> void:
	_trooper_body(k)
	# Supporting left forearm + right rifle arm.
	k.box(Vector3(0.20, 0.20, 0.46), STEEL, Vector3(-0.24, 1.32, -0.44))
	k.box(Vector3(0.20, 0.20, 0.42), STEEL, Vector3(0.32, 1.34, -0.36))
	# Heavy anti-armor rifle receiver + long barrel + glowing crimson sight.
	k.box(Vector3(0.18, 0.24, 0.92), ARMOR_DARK, Vector3(0.22, 1.38, -0.68))
	k.tube(Vector3(0.22, 1.40, -1.06), Vector3(0.22, 1.40, -1.48), 0.06, 6, STEEL)
	k.glow = true
	k.box(Vector3(0.12, 0.10, 0.14), OPTIC_GLOW, Vector3(0.22, 1.54, -0.68))
	k.glow = false


## Rooftop Anti-Armor exo-trooper (troop_roof): oversized shoulder-mounted AT rocket launcher + spare canister.
static func _trooper_at(k: MeshKit) -> void:
	_trooper_body(k)
	# Supporting arms raised to hold shoulder launcher.
	k.box(Vector3(0.20, 0.24, 0.44), STEEL, Vector3(-0.18, 1.54, -0.34))
	k.box(Vector3(0.22, 0.24, 0.36), STEEL, Vector3(0.42, 1.62, -0.22))
	# Oversized shoulder-mounted anti-armor tube (z = +0.76..-1.50 m) with crimson launch collar & optic.
	k.tube(Vector3(0.42, 1.88, 0.76), Vector3(0.42, 1.88, -1.50), 0.17, 8, ARMOR_DARK)
	k.tube(Vector3(0.42, 1.88, -1.32), Vector3(0.42, 1.88, -1.52), 0.22, 8, TRIM_RED)
	k.tube(Vector3(0.42, 1.88, 0.62), Vector3(0.42, 1.88, 0.80), 0.21, 8, STEEL)
	k.glow = true
	k.box(Vector3(0.12, 0.12, 0.22), OPTIC_GLOW, Vector3(0.24, 1.98, -0.78))
	k.glow = false
	# Spare dorsal rocket tube strapped to backpack.
	k.tube(Vector3(-0.24, 1.25, 0.56), Vector3(-0.24, 2.08, 0.56), 0.11, 6, TRIM_RED)
