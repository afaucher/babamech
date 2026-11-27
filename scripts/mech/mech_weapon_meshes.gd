class_name MechWeaponMeshes
extends RefCounted
## The low-poly weapon and back-mount equipment meshes, shared by every chassis (MechCatalog.WEAPONS / EQUIPMENT_ORDER).
## Parts "weapon_<id>" in the MechMeshes part registry (MechMeshes.WEAPONS / EQUIPMENT): MechMeshes.build asks `build`
## for them, and they are saved and cached like the other parts. Weapons have their origin at the mount point, pointing
## -Z. Cosmetic only (no gameplay state).


# --- Weapons --------------------------------------------------------------------------------------------
# One builder per weapon, each with the details from the concept art (art/picks/, art/renders/mech_r8/): muzzle brakes,
# recoil sleeves, cooling slots, ammo boxes, lugs, bolts, hinge cheeks, pistons, cables, coloured bands.

## The weapon or equipment `id` into `k`.
static func build(k: MeshKit, id: String) -> void:
	match id:
		"laser": _weapon_laser(k)
		"autocannon": _weapon_autocannon(k)
		"rockets": _tube_pod(k, LowPolyPalette.WHITE, false)
		"missiles": _weapon_missiles(k)
		"flamer": _weapon_flamer(k)
		"mortar": _weapon_mortar(k)
		"railgun": _weapon_railgun(k)
		"gatling": _weapon_gatling(k)
		"swivel": _weapon_swivel(k)
		"flak": _weapon_flak(k)
		"repair_drone":
			_drone_cradle(k)
			k.push(MeshKit.xf(MechMeshes.DRONE_DOCK))
			_drone(k)
			k.pop()
		"repair_drone_cradle": _drone_cradle(k)
		"repair_drone_flying": _drone(k)
		"radiator": _equip_radiator(k)
		"ammo_bin": _equip_ammo_bin(k)


static func _weapon_autocannon(k: MeshKit) -> void:
	k.box(Vector3(0.28, 0.3, 0.62), LowPolyPalette.GUN, Vector3(0, 0, 0.06))
	k.box(Vector3(0.2, 0.14, 0.32), LowPolyPalette.DARK, Vector3(0, 0.2, 0.12))
	k.box(Vector3(0.34, 0.12, 0.2), LowPolyPalette.DARK, Vector3(0, -0.02, 0.02))
	k.tube(Vector3(0, 0.02, -0.25), Vector3(0, 0.02, -0.62), 0.1, 8, LowPolyPalette.GUN)
	k.tube(Vector3(0, 0.02, -0.62), Vector3(0, 0.02, -1.3), 0.062, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0, 0.02, -1.3), Vector3(0, 0.02, -1.46), 0.095, 8, LowPolyPalette.GUN)
	k.tube(Vector3(0, 0.02, -1.46), Vector3(0, 0.02, -1.465), 0.055, 6, LowPolyPalette.BLACK)
	# Stepped side armour with two cooling slots each (rear half of the receiver).
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.2, 0.24), LowPolyPalette.GREY, Vector3(s * 0.15, 0.0, 0.24))
		for i in 2:
			k.box(Vector3(0.02, 0.035, 0.18), LowPolyPalette.BLACK, Vector3(s * 0.167, 0.04 - float(i) * 0.08, 0.24))
	# Top block: two bolts and a rear sight box.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.03, 0.04), LowPolyPalette.STEEL, Vector3(s * 0.065, 0.285, 0.24))
	k.box(Vector3(0.08, 0.05, 0.1), LowPolyPalette.GREY, Vector3(0, 0.29, 0.02))
	# Orange breech band, recoil sleeve, muzzle-brake side vents.
	k.tube(Vector3(0, 0.02, -0.3), Vector3(0, 0.02, -0.37), 0.106, 8, LowPolyPalette.ORANGE)
	k.tube(Vector3(0, 0.02, -0.62), Vector3(0, 0.02, -0.8), 0.08, 6, LowPolyPalette.STEEL)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.05, 0.1), LowPolyPalette.BLACK, Vector3(s * 0.085, 0.02, -1.38))
	# Side ammo box with a dark lid (left side).
	k.box(Vector3(0.08, 0.12, 0.18), LowPolyPalette.GREY, Vector3(-0.15, -0.08, 0.27))
	k.box(Vector3(0.09, 0.025, 0.19), LowPolyPalette.DARK, Vector3(-0.15, -0.015, 0.27))


## The box launcher shared by "rockets" and "missiles": a 3x2 grid of tubes with warhead tips of `tip` in a raised frame,
## lugs on the top plate, stepped side panels and a rear cable conduit. `missiles` leaves room for the designator and
## drops the orange side stripes (the missiles have their red band).
static func _tube_pod(k: MeshKit, tip: Color, missiles: bool) -> void:
	k.box(Vector3(0.7, 0.5, 0.62), LowPolyPalette.GUN, Vector3(0, 0.04, -0.02))
	k.box(Vector3(0.74, 0.08, 0.5), LowPolyPalette.DARK, Vector3(0, 0.3, -0.02))
	k.box(Vector3(0.5, 0.3, 0.08), LowPolyPalette.DARK, Vector3(0, 0.04, 0.32))
	for ix in 3:
		for iy in 2:
			var p := Vector3((float(ix) - 1.0) * 0.215, -0.07 + float(iy) * 0.22, -0.33)
			k.tube(p, p + Vector3(0, 0, -0.035), 0.09, 8, LowPolyPalette.BLACK)
			k.tube(p + Vector3(0, 0, -0.03), p + Vector3(0, 0, -0.13), 0.055, 6, tip, 0.0)
	# A raised frame around the launcher face, and a divider between the two rows.
	k.box(Vector3(0.7, 0.045, 0.05), LowPolyPalette.GREY, Vector3(0, 0.267, -0.35))
	k.box(Vector3(0.7, 0.045, 0.05), LowPolyPalette.GREY, Vector3(0, -0.187, -0.35))
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.045, 0.41, 0.05), LowPolyPalette.GREY, Vector3(s * 0.327, 0.04, -0.35))
	k.box(Vector3(0.62, 0.03, 0.04), LowPolyPalette.GREY, Vector3(0, 0.04, -0.35))
	# Lugs on the top plate (the missile pod's front-right one makes room for the designator).
	for at: Vector3 in [Vector3(-0.27, 0.36, -0.18), Vector3(0.27, 0.36, -0.18), Vector3(-0.27, 0.36, 0.14), Vector3(0.27, 0.36, 0.14)]:
		if missiles and at.x > 0.0 and at.z < 0.0:
			continue
		k.box(Vector3(0.08, 0.05, 0.08), LowPolyPalette.DARK, at)
	# Stepped side panels with two screws each, and an orange stripe above (rockets only).
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.025, 0.26, 0.34), LowPolyPalette.GREY, Vector3(s * 0.355, 0.0, -0.02))
		k.box(Vector3(0.02, 0.04, 0.04), LowPolyPalette.STEEL, Vector3(s * 0.37, 0.09, -0.15))
		k.box(Vector3(0.02, 0.04, 0.04), LowPolyPalette.STEEL, Vector3(s * 0.37, -0.09, 0.11))
		if not missiles:
			k.box(Vector3(0.025, 0.06, 0.4), LowPolyPalette.ORANGE, Vector3(s * 0.357, 0.19, -0.02))
	# Rear cable conduit from the back box down into the mount.
	k.tube(Vector3(0.16, 0.02, 0.37), Vector3(0.16, -0.17, 0.31), 0.03, 6, LowPolyPalette.BLACK)


## Same pod as the rockets, told apart by red warheads, a red band and a laser designator in a boxed housing.
static func _weapon_missiles(k: MeshKit) -> void:
	_tube_pod(k, LowPolyPalette.MISSILE_RED, true)
	k.box(Vector3(0.72, 0.52, 0.07), LowPolyPalette.MISSILE_RED, Vector3(0, 0.04, -0.2))
	k.tube(Vector3(0.24, 0.385, -0.16), Vector3(0.24, 0.385, -0.36), 0.045, 6, LowPolyPalette.DARK)
	k.glow = true
	k.tube(Vector3(0.24, 0.385, -0.36), Vector3(0.24, 0.385, -0.366), 0.03, 6, LowPolyPalette.TEAL)
	k.glow = false
	# The designator housing with a square lens hood.
	k.box(Vector3(0.12, 0.08, 0.16), LowPolyPalette.GUN, Vector3(0.24, 0.38, -0.2))
	k.seg(Vector3(0.24, 0.385, -0.31), Vector3(0.24, 0.385, -0.35), Vector2(0.06, 0.06), Vector2(0.065, 0.065), 4, LowPolyPalette.DARK, MeshKit.SQUARE)


static func _weapon_laser(k: MeshKit) -> void:
	k.tube(Vector3(0, 0, 0.36), Vector3(0, 0, -0.3), 0.13, 8, LowPolyPalette.GUN)
	k.box(Vector3(0.2, 0.2, 0.16), LowPolyPalette.DARK, Vector3(0, 0, 0.4))
	for i in 3:
		k.box(Vector3(0.05, 0.1, 0.12), LowPolyPalette.DARK, Vector3(0, 0.15, 0.2 - float(i) * 0.17))
	k.tube(Vector3(0, 0, -0.3), Vector3(0, 0, -0.84), 0.065, 8, LowPolyPalette.STEEL)
	k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -1.04), 0.13, 8, LowPolyPalette.GUN)
	k.glow = true
	k.tube(Vector3(0, 0, -1.04), Vector3(0, 0, -1.07), 0.1, 8, LowPolyPalette.TEAL, 0.06)
	k.glow = false
	# Orange band and steel bezel behind the lens (f_laser).
	k.tube(Vector3(0, 0, -0.88), Vector3(0, 0, -0.95), 0.137, 8, LowPolyPalette.ORANGE)
	k.tube(Vector3(0, 0, -1.0), Vector3(0, 0, -1.04), 0.137, 8, LowPolyPalette.STEEL)
	# Heat-sink rings on the emitter.
	for i in 3:
		var z := -0.42 - float(i) * 0.14
		k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.045), 0.098, 6, LowPolyPalette.DARK)
	# Underslung capacitor with a cable to the rear box.
	k.box(Vector3(0.12, 0.08, 0.34), LowPolyPalette.DARK, Vector3(0, -0.12, 0.04))
	k.seg(Vector3(0.06, -0.08, 0.47), Vector3(0.05, -0.14, 0.22), Vector2(0.022, 0.022), Vector2(0.022, 0.022), 6, LowPolyPalette.BLACK)
	# Front sight block and four bolts on the rear face.
	k.box(Vector3(0.06, 0.05, 0.12), LowPolyPalette.GREY, Vector3(0, 0.15, -0.22))
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			k.box(Vector3(0.04, 0.04, 0.03), LowPolyPalette.STEEL, Vector3(sx * 0.06, sy * 0.06, 0.49))


static func _weapon_flamer(k: MeshKit) -> void:
	k.ico(Vector3(0, 0.1, 0.16), Vector3(0.17, 0.2, 0.2), LowPolyPalette.TANK)
	k.ico(Vector3(0, -0.12, 0.2), Vector3(0.12, 0.13, 0.15), LowPolyPalette.TANK)
	k.box(Vector3(0.16, 0.2, 0.3), LowPolyPalette.GUN, Vector3(0, 0, -0.08))
	k.tube(Vector3(0, 0, -0.2), Vector3(0, 0, -0.62), 0.055, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0, 0, -0.62), Vector3(0, 0, -0.84), 0.06, 8, LowPolyPalette.GUN, 0.12)
	k.tube(Vector3(0, 0, -0.84), Vector3(0, 0, -0.845), 0.09, 8, LowPolyPalette.BLACK)
	k.glow = true
	k.box(Vector3(0.04, 0.04, 0.06), LowPolyPalette.AMBER, Vector3(0, -0.11, -0.8))
	k.glow = false
	# Straps round both tanks.
	k.seg(Vector3(0, 0.1, 0.13), Vector3(0, 0.1, 0.19), Vector2(0.168, 0.198), Vector2(0.168, 0.198), 8, LowPolyPalette.DARK)
	k.seg(Vector3(0, -0.12, 0.175), Vector3(0, -0.12, 0.225), Vector2(0.118, 0.128), Vector2(0.118, 0.128), 8, LowPolyPalette.DARK)
	# Valve with a handwheel on the big tank.
	k.tube(Vector3(0, 0.24, 0.16), Vector3(0, 0.29, 0.16), 0.03, 6, LowPolyPalette.STEEL)
	k.box(Vector3(0.1, 0.025, 0.1), LowPolyPalette.DARK, Vector3(0, 0.29, 0.16))
	# Fuel hose from the small tank under the body into the nozzle block.
	k.seg(Vector3(0.05, -0.2, 0.12), Vector3(0.05, -0.17, -0.06), Vector2(0.028, 0.028), Vector2(0.028, 0.028), 6, LowPolyPalette.BLACK)
	k.seg(Vector3(0.05, -0.17, -0.06), Vector3(0.04, -0.08, -0.2), Vector2(0.028, 0.028), Vector2(0.028, 0.028), 6, LowPolyPalette.BLACK)
	# Pilot-light shroud round the amber flame, heat bands on the nozzle, an orange stripe on the body.
	k.box(Vector3(0.07, 0.06, 0.13), LowPolyPalette.GUN, Vector3(0, -0.11, -0.71))
	k.tube(Vector3(0, 0, -0.44), Vector3(0, 0, -0.48), 0.072, 6, LowPolyPalette.STEEL)
	k.tube(Vector3(0, 0, -0.66), Vector3(0, 0, -0.7), 0.085, 6, LowPolyPalette.STEEL)
	k.box(Vector3(0.17, 0.05, 0.22), LowPolyPalette.ORANGE, Vector3(0, 0.06, -0.1))


## A base plate with trunnions and a barrel angled up and forward from `a` to the muzzle at `b`.
static func _weapon_mortar(k: MeshKit) -> void:
	var a := Vector3(0, 0.12, 0.14)
	var b := Vector3(0, 1.22, -0.3)
	var d := (b - a).normalized()
	k.box(Vector3(0.56, 0.16, 0.5), LowPolyPalette.DARK, Vector3(0, 0.02, 0.04))
	k.tube(Vector3(-0.26, 0.24, 0.08), Vector3(0.26, 0.24, 0.08), 0.1, 8, LowPolyPalette.GUN)
	k.tube(a, b, 0.16, 8, LowPolyPalette.GUN)
	k.tube(b - d * 0.16, b + d * 0.02, 0.2, 8, LowPolyPalette.DARK)
	k.tube(b + d * 0.02, b + d * 0.025, 0.13, 8, LowPolyPalette.BLACK)
	k.box(Vector3(0.1, 0.34, 0.1), LowPolyPalette.STEEL, Vector3(0, 0.3, -0.16))
	# A square clamp round the barrel (d_mortar) with a bolt each side.
	var at := func(t: float) -> Vector3: return a.lerp(b, t)
	k.seg(at.call(0.56), at.call(0.64), Vector2(0.2, 0.2), Vector2(0.2, 0.2), 4, LowPolyPalette.GUN, MeshKit.SQUARE)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.05, 0.06, 0.06), LowPolyPalette.STEEL, (at.call(0.6) as Vector3) + Vector3(s * 0.215, 0, 0))
	# Hydraulic pistons from the base up both sides of the barrel.
	for s: float in [-1.0, 1.0]:
		var foot := Vector3(s * 0.19, 0.1, -0.12)
		var top: Vector3 = (at.call(0.42) as Vector3) + Vector3(s * 0.17, 0, 0)
		k.tube(foot, foot.lerp(top, 0.55), 0.05, 6, LowPolyPalette.DARK)
		k.tube(foot.lerp(top, 0.5), top, 0.032, 6, LowPolyPalette.STEEL)
	# Trunnion caps, an orange band below the muzzle, a front step on the base.
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.25, 0.24, 0.08), Vector3(s * 0.29, 0.24, 0.08), 0.13, 6, LowPolyPalette.DARK)
	k.tube(at.call(0.76), at.call(0.8), 0.168, 8, LowPolyPalette.ORANGE)
	k.box(Vector3(0.48, 0.06, 0.1), LowPolyPalette.GREY, Vector3(0, 0.0, -0.25))


static func _weapon_railgun(k: MeshKit) -> void:
	k.box(Vector3(0.32, 0.36, 0.72), LowPolyPalette.GUN, Vector3(0, 0, 0.12))
	k.box(Vector3(0.22, 0.12, 0.4), LowPolyPalette.DARK, Vector3(0, 0.22, 0.16))
	for side: float in [-1.0, 1.0]:
		k.seg(Vector3(side * 0.07, 0, -0.24), Vector3(side * 0.07, 0, -2.05), Vector2(0.03, 0.085), Vector2(0.03, 0.07), 4, LowPolyPalette.STEEL, MeshKit.SQUARE)
	for i in 8:
		var z := -0.42 - float(i) * 0.2
		k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.07), 0.15, 8, LowPolyPalette.DARK)
	k.glow = true
	k.box(Vector3(0.05, 0.05, 0.3), LowPolyPalette.TEAL, Vector3(0.165, 0.05, 0.1))
	k.glow = false
	# Seven thinner steel coils between the dark ones (g_railgun's tight coil pack).
	for i in 7:
		var z := -0.555 - float(i) * 0.2
		k.tube(Vector3(0, 0, z + 0.02), Vector3(0, 0, z - 0.02), 0.125, 8, LowPolyPalette.STEEL)
	# Muzzle collar round the rails.
	k.seg(Vector3(0, 0, -1.93), Vector3(0, 0, -2.0), Vector2(0.13, 0.13), Vector2(0.13, 0.13), 4, LowPolyPalette.DARK, MeshKit.SQUARE)
	# Four teal charge cells on the receiver's top shelf (the four charge steps).
	k.glow = true
	for i in 4:
		k.box(Vector3(0.04, 0.025, 0.06), LowPolyPalette.TEAL, Vector3(-0.135, 0.19, -0.16 + float(i) * 0.1))
	k.glow = false
	# Side capacitor with cooling slots (left), cable conduits to the coil pack, orange band, butt plate.
	k.box(Vector3(0.04, 0.22, 0.4), LowPolyPalette.GREY, Vector3(-0.175, -0.03, 0.18))
	for i in 3:
		k.box(Vector3(0.02, 0.03, 0.3), LowPolyPalette.BLACK, Vector3(-0.195, 0.04 - float(i) * 0.07, 0.18))
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.06, 0.2, -0.04), Vector3(s * 0.06, 0.12, -0.42), 0.025, 6, LowPolyPalette.BLACK)
	k.box(Vector3(0.33, 0.37, 0.05), LowPolyPalette.ORANGE, Vector3(0, 0, -0.19))
	k.box(Vector3(0.26, 0.28, 0.05), LowPolyPalette.DARK, Vector3(0, -0.01, 0.5))


static func _weapon_gatling(k: MeshKit) -> void:
	k.tube(Vector3(0, 0, 0.34), Vector3(0, 0, -0.22), 0.18, 8, LowPolyPalette.GUN)
	k.box(Vector3(0.22, 0.26, 0.3), LowPolyPalette.DARK, Vector3(0, -0.2, 0.12))
	for i in 6:
		var ang := TAU * float(i) / 6.0
		var o := Vector3(cos(ang), sin(ang), 0) * 0.095
		k.tube(o + Vector3(0, 0, -0.22), o + Vector3(0, 0, -1.02), 0.036, 5, LowPolyPalette.STEEL)
	k.tube(Vector3(0, 0, -0.5), Vector3(0, 0, -0.56), 0.145, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0, 0, -0.9), Vector3(0, 0, -0.96), 0.145, 8, LowPolyPalette.DARK)
	# Red ammo box with a lid and a feed chute into the housing (e_hipgatling).
	k.box(Vector3(0.1, 0.18, 0.22), LowPolyPalette.MISSILE_RED, Vector3(0.14, -0.22, 0.12))
	k.box(Vector3(0.11, 0.03, 0.23), LowPolyPalette.DARK, Vector3(0.14, -0.12, 0.12))
	k.seg(Vector3(0.14, -0.12, 0.02), Vector3(0.11, -0.05, -0.15), Vector2(0.035, 0.045), Vector2(0.035, 0.045), 4, LowPolyPalette.DARK, MeshKit.SQUARE)
	# Rear barrel collar and the spindle.
	k.tube(Vector3(0, 0, -0.22), Vector3(0, 0, -0.29), 0.15, 6, LowPolyPalette.STEEL)
	k.tube(Vector3(0, 0, -0.29), Vector3(0, 0, -1.0), 0.04, 6, LowPolyPalette.BLACK)
	# Cooling bands on the motor housing, an orange band at its front, a carry handle on top.
	for i in 3:
		var z := 0.27 - float(i) * 0.08
		k.tube(Vector3(0, 0, z), Vector3(0, 0, z - 0.035), 0.19, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0, 0, -0.14), Vector3(0, 0, -0.2), 0.188, 8, LowPolyPalette.ORANGE)
	for z: float in [0.2, -0.06]:
		k.box(Vector3(0.04, 0.05, 0.04), LowPolyPalette.DARK, Vector3(0, 0.19, z))
	k.box(Vector3(0.045, 0.03, 0.32), LowPolyPalette.STEEL, Vector3(0, 0.215, 0.07))


## A ball pivot at the origin (the boom turns about it at runtime, scripts/combat/weapons/swivel.gd), a boom out to an
## elbow and a twin-barrel gun box.
static func _weapon_swivel(k: MeshKit) -> void:
	k.ico(Vector3.ZERO, Vector3(0.13, 0.13, 0.13), LowPolyPalette.DARK)
	k.seg(Vector3.ZERO, Vector3(0, -0.08, -0.5), Vector2(0.05, 0.06), Vector2(0.045, 0.055), 4, LowPolyPalette.GREY, MeshKit.SQUARE)
	k.tube(Vector3(-0.09, -0.08, -0.5), Vector3(0.09, -0.08, -0.5), 0.08, 8, LowPolyPalette.DARK)
	k.box(Vector3(0.2, 0.2, 0.44), LowPolyPalette.GUN, Vector3(0, -0.08, -0.68))
	k.box(Vector3(0.12, 0.1, 0.2), LowPolyPalette.ORANGE, Vector3(0, 0.06, -0.62))
	for side: float in [-1.0, 1.0]:
		k.tube(Vector3(side * 0.05, -0.08, -0.9), Vector3(side * 0.05, -0.08, -1.25), 0.034, 6, LowPolyPalette.DARK)
	# Hinge cheeks on the boom's elbow (h_booms), a hydraulic piston under the boom, a cable along its top.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.12, 0.12), LowPolyPalette.GREY, Vector3(s * 0.105, -0.08, -0.5))
	k.tube(Vector3(0, -0.1, -0.06), Vector3(0, -0.13, -0.26), 0.035, 6, LowPolyPalette.DARK)
	k.tube(Vector3(0, -0.125, -0.24), Vector3(0, -0.155, -0.44), 0.022, 6, LowPolyPalette.STEEL)
	k.seg(Vector3(0.03, 0.07, -0.04), Vector3(0.03, 0.035, -0.5), Vector2(0.02, 0.02), Vector2(0.02, 0.02), 6, LowPolyPalette.BLACK)
	# Vent slots down both sides of the gun box, a front face plate, muzzle shrouds.
	for s: float in [-1.0, 1.0]:
		for i in 2:
			k.box(Vector3(0.02, 0.03, 0.18), LowPolyPalette.BLACK, Vector3(s * 0.104, -0.04 - float(i) * 0.07, -0.72))
		k.tube(Vector3(s * 0.05, -0.08, -0.91), Vector3(s * 0.05, -0.08, -1.0), 0.05, 6, LowPolyPalette.GUN)
	k.box(Vector3(0.21, 0.21, 0.03), LowPolyPalette.DARK, Vector3(0, -0.08, -0.9))


## The Flak Cannon (docs/design/weapons.md §3.10): a twin anti-aircraft gun, told apart from the autocannon (one long
## barrel) and the gatling (a round six-barrel cluster) by two short side-by-side barrels on steel recoil sleeves with
## flared conical flash hiders (their tips' midpoint at z -1.46, MechCatalog "muzzle"), a flat pan drum on top of a boxy
## breech, and a ring-and-spider AA sight on a post ahead of the drum. Same receiver footprint as the autocannon over the
## mount block.
const FLAK_BX := 0.095   ## the barrels' x (either side of the centre line)
const FLAK_BY := 0.03    ## the barrels' height


static func _weapon_flak(k: MeshKit) -> void:
	var bx := FLAK_BX
	var by := FLAK_BY
	# Breech: a boxy receiver, a wider belly block over the mount, the cradle face the barrels come out of.
	k.box(Vector3(0.34, 0.3, 0.56), LowPolyPalette.GUN, Vector3(0, 0, 0.08))
	k.box(Vector3(0.38, 0.12, 0.24), LowPolyPalette.DARK, Vector3(0, -0.07, 0.06))
	k.box(Vector3(0.36, 0.22, 0.1), LowPolyPalette.DARK, Vector3(0, by, -0.24))
	k.box(Vector3(0.355, 0.315, 0.06), LowPolyPalette.ORANGE, Vector3(0, 0, -0.13))
	# Twin barrels: a thick steel recoil sleeve with a dark collar, a thin barrel, a flared flash-hider cone.
	for s: float in [-1.0, 1.0]:
		var x := s * bx
		k.tube(Vector3(x, by, -0.29), Vector3(x, by, -0.68), 0.06, 8, LowPolyPalette.STEEL)
		k.tube(Vector3(x, by, -0.5), Vector3(x, by, -0.55), 0.07, 8, LowPolyPalette.DARK)
		k.tube(Vector3(x, by, -0.68), Vector3(x, by, -1.26), 0.034, 6, LowPolyPalette.DARK)
		k.tube(Vector3(x, by, -1.26), Vector3(x, by, -1.46), 0.04, 8, LowPolyPalette.GUN, 0.08)
		k.tube(Vector3(x, by, -1.46), Vector3(x, by, -1.465), 0.055, 6, LowPolyPalette.BLACK)
	# A yoke clamping the two barrels together ahead of the sleeves.
	k.box(Vector3(0.26, 0.05, 0.06), LowPolyPalette.GUN, Vector3(0, by, -0.98))
	# The pan drum on top (axis Y) with a dark hub and three radial ribs, on a steel feed neck.
	var dc := Vector3(0, 0.15, 0.1)
	k.box(Vector3(0.12, 0.04, 0.12), LowPolyPalette.STEEL, dc + Vector3(0, 0.01, 0))
	k.tube(dc + Vector3(0, 0.02, 0), dc + Vector3(0, 0.12, 0), 0.16, 10, LowPolyPalette.GREY)
	k.tube(dc + Vector3(0, 0.12, 0), dc + Vector3(0, 0.15, 0), 0.05, 6, LowPolyPalette.DARK)
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.5
		var d := Vector3(sin(a), 0, cos(a))
		k.push(Transform3D(Basis(Vector3.UP, a), dc + Vector3(0, 0.125, 0) + d * 0.1))
		k.box(Vector3(0.025, 0.02, 0.11), LowPolyPalette.DARK)
		k.pop()
	# The ring-and-spider AA sight on a post ahead of the drum.
	var sc := Vector3(0, 0.33, -0.2)
	k.box(Vector3(0.03, 0.14, 0.03), LowPolyPalette.DARK, Vector3(0, 0.2, -0.2))
	k.push(MeshKit.xf(sc, Vector3(90, 0, 0)))
	_band(k, Vector3.ZERO, 0.09, 0.07, -0.012, 0.012, 8, LowPolyPalette.STEEL)
	k.pop()
	k.box(Vector3(0.15, 0.014, 0.012), LowPolyPalette.STEEL, sc)
	k.box(Vector3(0.014, 0.15, 0.012), LowPolyPalette.STEEL, sc)
	# Side armour with two cooling slots each, and an elevation handwheel on the right.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.03, 0.18, 0.24), LowPolyPalette.GREY, Vector3(s * 0.18, 0.02, 0.2))
		for i in 2:
			k.box(Vector3(0.02, 0.035, 0.18), LowPolyPalette.BLACK, Vector3(s * 0.197, 0.06 - float(i) * 0.08, 0.2))
	k.tube(Vector3(0.195, -0.02, 0.0), Vector3(0.225, -0.02, 0.0), 0.075, 8, LowPolyPalette.DARK)
	k.tube(Vector3(0.225, -0.02, 0.0), Vector3(0.245, -0.02, 0.0), 0.03, 6, LowPolyPalette.STEEL)


# --- Back-mount equipment -------------------------------------------------------------------------------
# docs/design/back-equipment.md. Origin at MOUNTS["back"], like the mortar. The rear deck under the mount slopes down
# toward the tail (about 0.15 above the mount 0.2 ahead of it, 0.3 below it 0.2 behind it), so every item stands on the
# mortar's base plate with two braces down to the deck behind. Kept inside |x| < 0.45 (the shoulder weapons' inner
# faces are at 0.51), behind z -0.33 (the back plate's rear face is at -0.375) and lower than the mortar's muzzle.

## The shared base plate (the mortar's footprint) on a wedge that fills the gap down to the falling deck behind it.
static func _back_base(k: MeshKit, bolts: bool) -> void:
	k.box(Vector3(0.5, 0.12, 0.44), LowPolyPalette.DARK, Vector3(0, 0.02, 0.04))
	var prof := [Vector2(-0.06, -0.03), Vector2(0.25, -0.03), Vector2(0.25, -0.4), Vector2(0.2, -0.42), Vector2(0.04, -0.19)]
	var rings: Array = []
	for s: float in [-1.0, 1.0]:
		var r := PackedVector3Array()
		for p: Vector2 in prof:
			r.append(Vector3(s * 0.19, p.y, p.x))
		rings.append(r)
	k.loft(rings, LowPolyPalette.GUN)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.02, 0.16, 0.12), LowPolyPalette.DARK, Vector3(s * 0.195, -0.14, 0.18))
		k.box(Vector3(0.03, 0.04, 0.04), LowPolyPalette.STEEL, Vector3(s * 0.2, -0.06, 0.18))
	if bolts:
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				k.box(Vector3(0.045, 0.035, 0.045), LowPolyPalette.STEEL, Vector3(sx * 0.2, 0.09, 0.04 + sz * 0.17))


## A closed flat ring (a rotor guard): outer and inner walls, top and bottom faces, around Y at `c`, from y0 to y1.
static func _band(k: MeshKit, c: Vector3, r_out: float, r_in: float, y0: float, y1: float, n: int, col: Color) -> void:
	var ob := MeshKit.ring(c + Vector3(0, y0, 0), r_out, r_out, n)
	var ot := MeshKit.ring(c + Vector3(0, y1, 0), r_out, r_out, n)
	var ib := MeshKit.ring(c + Vector3(0, y0, 0), r_in, r_in, n)
	var it := MeshKit.ring(c + Vector3(0, y1, 0), r_in, r_in, n)
	var mid := c + Vector3(0, (y0 + y1) * 0.5, 0)
	for i in n:
		var j := (i + 1) % n
		k.quad(ob[i], ob[j], ot[j], ot[i], col, mid)
		var out := (ib[i] + ib[j]) * 0.5 - c
		out.y = 0.0
		k.quad(ib[i], ib[j], it[j], it[i], col, (ib[i] + it[j]) * 0.5 + out.normalized())
		k.quad(ot[i], ot[j], it[j], it[i], col, mid - Vector3(0, 1, 0))
		k.quad(ob[i], ob[j], ib[j], ib[i], col, mid + Vector3(0, 1, 0))


## The repair drone alone, origin at its centre, facing -Z: a boxy hull in the accent colour with a white top deck and a
## green repair cross on it, a green sensor eye in a bezel on the nose, four diagonal arms out to motors with dark rotor
## discs (a blade across each) inside white guard rings, and two landing skids (their soles at y -0.145).
static func _drone(k: MeshKit) -> void:
	k.box(Vector3(0.28, 0.11, 0.34), LowPolyPalette.ORANGE)
	k.box(Vector3(0.22, 0.04, 0.26), LowPolyPalette.WHITE, Vector3(0, 0.07, 0.02))
	k.box(Vector3(0.22, 0.05, 0.28), LowPolyPalette.DARK, Vector3(0, -0.07, 0.0))
	# The nose: a dark visor block, a bezel and the green eye.
	k.box(Vector3(0.18, 0.08, 0.04), LowPolyPalette.DARK, Vector3(0, 0.0, -0.18))
	k.tube(Vector3(0, 0, -0.19), Vector3(0, 0, -0.215), 0.05, 6, LowPolyPalette.GUN)
	k.glow = true
	k.tube(Vector3(0, 0, -0.213), Vector3(0, 0, -0.223), 0.034, 6, LowPolyPalette.REPAIR_GREEN)
	# The repair cross on the top deck, and a tail light.
	k.box(Vector3(0.13, 0.012, 0.04), LowPolyPalette.REPAIR_GREEN, Vector3(0, 0.095, 0.03))
	k.box(Vector3(0.04, 0.012, 0.13), LowPolyPalette.REPAIR_GREEN, Vector3(0, 0.095, 0.03))
	k.box(Vector3(0.08, 0.025, 0.012), LowPolyPalette.REPAIR_GREEN, Vector3(0, 0.0, 0.175))
	k.glow = false
	# Arms, motors, rotors, guards.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var hub := Vector3(sx * 0.23, 0.0, sz * 0.23)
			var dir := Vector3(sx, 0, sz).normalized()
			k.seg(Vector3(sx * 0.1, 0.0, sz * 0.1), hub + dir * 0.135, Vector2(0.026, 0.02), Vector2(0.022, 0.018), 4, LowPolyPalette.GREY, MeshKit.SQUARE)
			k.tube(hub - Vector3(0, 0.035, 0), hub + Vector3(0, 0.04, 0), 0.038, 6, LowPolyPalette.DARK)
			k.tube(hub + Vector3(0, 0.04, 0), hub + Vector3(0, 0.048, 0), 0.112, 8, LowPolyPalette.GUN)
			k.push(MeshKit.xf(hub + Vector3(0, 0.054, 0), Vector3(0, 45.0 * sx * sz, 0)))
			k.box(Vector3(0.21, 0.01, 0.03), LowPolyPalette.BLACK)
			k.pop()
			_band(k, hub, 0.135, 0.12, 0.012, 0.062, 8, LowPolyPalette.WHITE)
	# Skids: two deep rails under the belly.
	for sx: float in [-1.0, 1.0]:
		k.box(Vector3(0.024, 0.05, 0.3), LowPolyPalette.STEEL, Vector3(sx * 0.1, -0.12, 0.0))


## The drone's launch cradle on the back mount (the docked mesh without the drone): the base plate, a pedestal and a pad
## (top at y 0.165, where the skids land) with an H mark, two clamp jaws that grip the hull's sides, an accent lip with
## two green status lights on the rear edge, and a cable from the pad down into the deck.
static func _drone_cradle(k: MeshKit) -> void:
	_back_base(k, false)
	k.box(Vector3(0.3, 0.06, 0.3), LowPolyPalette.GUN, Vector3(0, 0.1, 0.02))
	k.box(Vector3(0.56, 0.05, 0.56), LowPolyPalette.GREY, Vector3(0, 0.14, 0.02))
	# The H on the pad.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.035, 0.008, 0.2), LowPolyPalette.WHITE, Vector3(s * 0.07, 0.168, 0.02))
	k.box(Vector3(0.105, 0.008, 0.035), LowPolyPalette.WHITE, Vector3(0, 0.168, 0.02))
	# Clamp jaws on both sides: an upright, a jaw reaching in over the hull's side, a hinge pin.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.04, 0.17, 0.09), LowPolyPalette.STEEL, Vector3(s * 0.215, 0.245, 0.02))
		k.box(Vector3(0.09, 0.045, 0.09), LowPolyPalette.DARK, Vector3(s * 0.175, 0.31, 0.02))
		k.tube(Vector3(s * 0.215, 0.2, -0.04), Vector3(s * 0.215, 0.2, 0.08), 0.022, 6, LowPolyPalette.DARK)
	# The rear lip in the accent colour, with two green status lights.
	k.box(Vector3(0.5, 0.06, 0.035), LowPolyPalette.ORANGE, Vector3(0, 0.15, 0.315))
	k.glow = true
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.05, 0.025, 0.012), LowPolyPalette.REPAIR_GREEN, Vector3(s * 0.17, 0.155, 0.337))
	k.glow = false
	# The charge cable from under the pad down into the deck.
	var cable := [Vector3(0.2, 0.12, 0.24), Vector3(0.24, 0.02, 0.3), Vector3(0.22, -0.3, 0.27)]
	for i in cable.size() - 1:
		k.tube(cable[i], cable[i + 1], 0.024, 6, LowPolyPalette.BLACK)


## Radiator fins: seven tall flat fins across the mount (on the "heat" surface, which the game makes glow with heat;
## edge on to the camera behind, broadside from the sides) on a header box, a manifold pipe through them with accent end
## caps, two tie bars through their rear halves, and two coolant pipes forward into the back plate's rear face.
static func _equip_radiator(k: MeshKit) -> void:
	_back_base(k, true)
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.1, 0.05, 0.2), LowPolyPalette.DARK, Vector3(s * 0.15, 0.1, 0.02))
	k.box(Vector3(0.6, 0.1, 0.34), LowPolyPalette.GUN, Vector3(0, 0.17, 0.02))
	# The fins: chamfered plates stepping down and in toward the sides, so the side view shows their nested edges.
	k.heat = true
	for i in 7:
		var x := (float(i) - 3.0) * 0.08
		var a := absf(float(i) - 3.0) / 3.0
		var top := 0.86 - 0.3 * a
		var zf := -0.17 + 0.12 * a
		var zb := 0.21 - 0.1 * a
		var prof := [Vector2(zf, 0.22), Vector2(zb, 0.22), Vector2(zb, top - 0.1), Vector2(zb - 0.08, top), Vector2(zf + 0.08, top),
			Vector2(zf, top - 0.08)]
		var rings: Array = []
		for side: float in [-1.0, 1.0]:
			var r := PackedVector3Array()
			for p: Vector2 in prof:
				r.append(Vector3(x + side * 0.011, p.y, p.x))
			rings.append(r)
		k.loft(rings, LowPolyPalette.STEEL)
	k.heat = false
	# The manifold through the fins with accent end caps, two tie bars through the rear halves.
	k.tube(Vector3(-0.3, 0.5, 0.03), Vector3(0.3, 0.5, 0.03), 0.045, 8, LowPolyPalette.GUN)
	for s: float in [-1.0, 1.0]:
		k.tube(Vector3(s * 0.29, 0.5, 0.03), Vector3(s * 0.33, 0.5, 0.03), 0.065, 8, LowPolyPalette.ORANGE)
	for y: float in [0.34, 0.47]:
		k.box(Vector3(0.5, 0.035, 0.035), LowPolyPalette.GREY, Vector3(0, y, 0.08))
	# Coolant pipes from the header's sides forward into the back plate, with collars where they enter.
	for s: float in [-1.0, 1.0]:
		var pts := [Vector3(s * 0.27, 0.17, -0.08), Vector3(s * 0.33, 0.23, -0.2), Vector3(s * 0.33, 0.3, -0.45)]
		for i in pts.size() - 1:
			k.tube(pts[i], pts[i + 1], 0.032, 6, LowPolyPalette.STEEL)
		k.tube(Vector3(s * 0.33, 0.29, -0.36), Vector3(s * 0.33, 0.3, -0.41), 0.05, 6, LowPolyPalette.DARK)
	# A heat gauge (amber) in a dark frame and an accent plate on the header's rear face.
	k.box(Vector3(0.1, 0.06, 0.02), LowPolyPalette.DARK, Vector3(0.16, 0.17, 0.195))
	k.glow = true
	k.box(Vector3(0.07, 0.03, 0.012), LowPolyPalette.AMBER, Vector3(0.16, 0.17, 0.207))
	k.glow = false
	k.box(Vector3(0.2, 0.05, 0.02), LowPolyPalette.ORANGE, Vector3(-0.12, 0.17, 0.195))


## Ammo bin: a ribbed magazine crate with a lid and a carry handle, two latches and a hazard stripe (accent with black
## slats) on the rear face, accent unit plates on the sides, and a segmented feed chute from its right side curving down
## into the deck toward the body.
static func _equip_ammo_bin(k: MeshKit) -> void:
	_back_base(k, false)
	k.box(Vector3(0.58, 0.42, 0.48), LowPolyPalette.GUN, Vector3(0, 0.31, 0.04))
	for z: float in [-0.14, 0.04, 0.22]:
		k.box(Vector3(0.62, 0.44, 0.04), LowPolyPalette.GREY, Vector3(0, 0.31, z))
	k.box(Vector3(0.6, 0.05, 0.5), LowPolyPalette.DARK, Vector3(0, 0.545, 0.04))
	# The carry handle on the lid.
	k.box(Vector3(0.22, 0.025, 0.04), LowPolyPalette.STEEL, Vector3(0, 0.615, 0.1))
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.025, 0.05, 0.025), LowPolyPalette.STEEL, Vector3(s * 0.1, 0.59, 0.1))
	# Latches over the lid's rear edge.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.07, 0.12, 0.03), LowPolyPalette.STEEL, Vector3(s * 0.17, 0.49, 0.295))
		k.box(Vector3(0.05, 0.03, 0.04), LowPolyPalette.DARK, Vector3(s * 0.17, 0.455, 0.315))
	# The hazard stripe: an accent band with four black diagonal slats.
	k.box(Vector3(0.5, 0.09, 0.02), LowPolyPalette.ORANGE, Vector3(0, 0.2, 0.29))
	for i in 4:
		k.push(MeshKit.xf(Vector3(-0.18 + float(i) * 0.12, 0.2, 0.302), Vector3(0, 0, 45.0)))
		k.box(Vector3(0.026, 0.095, 0.012), LowPolyPalette.BLACK)
		k.pop()
	# Accent unit plates on both sides, between the rear ribs.
	for s: float in [-1.0, 1.0]:
		k.box(Vector3(0.02, 0.12, 0.12), LowPolyPalette.ORANGE, Vector3(s * 0.295, 0.38, 0.13))
	# The feed chute: an outlet on the right side, three square segments curving down into the deck, steel collars.
	k.box(Vector3(0.05, 0.14, 0.16), LowPolyPalette.DARK, Vector3(0.31, 0.3, -0.06))
	var pts := [Vector3(0.3, 0.3, -0.06), Vector3(0.35, 0.27, -0.08), Vector3(0.375, 0.16, -0.1), Vector3(0.375, -0.02, -0.12)]
	for i in pts.size() - 1:
		k.seg(pts[i], pts[i + 1], Vector2(0.04, 0.055), Vector2(0.04, 0.055), 4, LowPolyPalette.DARK, MeshKit.SQUARE)
	for i: int in [1, 2]:
		var d: Vector3 = ((pts[i + 1] as Vector3) - (pts[i - 1] as Vector3)).normalized()
		k.seg((pts[i] as Vector3) - d * 0.02, (pts[i] as Vector3) + d * 0.02, Vector2(0.05, 0.066), Vector2(0.05, 0.066), 4, LowPolyPalette.STEEL, MeshKit.SQUARE)
