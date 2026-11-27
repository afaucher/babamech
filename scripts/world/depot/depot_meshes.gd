class_name DepotMeshes
extends RefCounted
## The player-side military supply depot's meshes (docs/design/supply-depot.md, pick B2 "hardened bunker kiosk + socket
## wall"). Flat-shaded low-poly vertex colours through MeshKit with the shared mech materials, like EnemyMeshes and
## BannerMeshes. Every mesh is built once and cached; every piece is a closed, outward-wound shell. Pure looks.
##
## Model space: origin on the ground at the bunker's centre, up = +Y (the parent's local up), the socket wall faces +Z,
## +X is the right as seen from in front of the wall. Footprint ~6.6 x 4.6 m (roof overhang), roof top at ROOF_TOP.
##
##   body(wrecked)    the bunker: plinth, central block, sloped side buttresses, socket panel with four round charcoal
##                    collars and their near-black holes (an empty socket IS the hole), recess frame, rolled-up blast
##                    shutter drum, heavy roof slab, orange hazard stripes, corner marks and the cross-and-bolt emblem
##                    (+X side). wrecked = scorched colours, roof slumped, debris in front.
##   core()           one power core seated in a socket: origin on the socket axis at the panel's front face, the core
##                    pointing +Z; charcoal end-cap ring (matte) round an ice-blue cell (glow surface, unshaded).
##   marker(wrecked)  the roof mast with its beacon lamp (glow) and floodlight; wrecked = a snapped stub, lamp dark.
##
## Sockets: SOCKETS (2 x 2), index 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right as seen from the front.

const WHITE := LowPolyPalette.WHITE                 ## the player mech's off-white
const ORANGE := LowPolyPalette.ORANGE               ## the player mech's safety orange
const CHARCOAL := LowPolyPalette.DARK
const HOLE := Color(0.03, 0.03, 0.035)          ## an empty socket
const ICE := Color("7fd8ff")                    ## the core's cell
const ICE_HOT := Color("e2f8ff")                ## its bright centre
const LAMP := Color(1.0, 0.96, 0.9)             ## the beacon (orange-white, not amber)
const CHAR := Color(0.2, 0.19, 0.18)            ## wreck: scorched white
const CHAR_DARK := Color(0.1, 0.095, 0.09)

const W := 6.0                  ## m: body width (x)
const D := 4.0                  ## m: body depth (z)
const PLINTH_H := 0.35
const BODY_TOP := 3.85          ## m: top of the walls (roof slab sits on it)
const ROOF_T := 0.5
const ROOF_TOP := BODY_TOP + ROOF_T
const RECESS_X := 1.45          ## m: half width of the socket recess (inner faces of the buttresses)
const PANEL_Z := 1.3            ## m: front face of the socket panel
const SILL_TOP := 1.35          ## m: bottom of the recess opening
const BUTTRESS_TOP_X := 2.35    ## m: buttress outer face at the top (slopes in from W / 2)
const BUTTRESS_TOP_Z := 1.5     ## m: buttress front face at the top (slopes back from D / 2)
const SOCKETS := 4
const COLS := 2
const SOCKET_X := 0.66          ## m: column centres at +-SOCKET_X
const SOCKET_Y := [3.05, 2.0]   ## m: row centres (top, bottom)
const COLLAR_R := 0.5           ## m: collar outer radius (1.0 m across)
const HOLE_R := 0.4
const COLLAR_OUT := 0.12        ## m: the collar stands this far proud of the panel
const CORE_OUT := 0.24          ## m: a seated core's end stands this far proud of the panel
const CORE_CAP_R := 0.43
const CELL_R := 0.35
const DRUM_Y := 3.7
const DRUM_R := 0.15
const MAST_POS := Vector3(-2.45, ROOF_TOP, -1.45)
const MAST_H := 3.5
const N := 12                   ## sides of a round piece

static var _cache: Dictionary = {}


## Local centre of socket i's opening, on the panel's front face.
static func socket_local(i: int) -> Vector3:
	var c := i % COLS
	var r := i / COLS
	return Vector3((-1.0 if c == 0 else 1.0) * SOCKET_X, float(SOCKET_Y[r]), PANEL_Z)


static func body(wrecked: bool = false) -> ArrayMesh:
	var key := "body|%s" % wrecked
	if not _cache.has(key):
		_cache[key] = _body(wrecked)
	return _cache[key]


static func core() -> ArrayMesh:
	if not _cache.has("core"):
		var k := MeshKit.new()
		var z0 := 0.0
		# Charcoal cap ring (sits in the hole, stands out past the collar) and two thin grip bands.
		k.tube(Vector3(0, 0, z0 - 0.05), Vector3(0, 0, CORE_OUT), CORE_CAP_R, N, CHARCOAL)
		k.tube(Vector3(0, 0, CORE_OUT - 0.02), Vector3(0, 0, CORE_OUT + 0.03), CORE_CAP_R + 0.03, N, CHARCOAL.darkened(0.25))
		k.glow = true
		k.tube(Vector3(0, 0, CORE_OUT), Vector3(0, 0, CORE_OUT + 0.06), CELL_R, N, ICE)
		k.tube(Vector3(0, 0, CORE_OUT + 0.06), Vector3(0, 0, CORE_OUT + 0.09), CELL_R * 0.5, N, ICE_HOT)
		k.glow = false
		_cache["core"] = k.commit(LowPolyMaterials.materials())
	return _cache["core"]


static func marker(wrecked: bool = false) -> ArrayMesh:
	var key := "marker|%s" % wrecked
	if not _cache.has(key):
		var k := MeshKit.new()
		if wrecked:
			k.box(Vector3(0.5, 0.25, 0.5), CHAR_DARK, Vector3(0, 0.125, 0))
			k.push(MeshKit.xf(Vector3(0, 0.2, 0), Vector3(0, 0, 14)))
			k.tube(Vector3.ZERO, Vector3(0, 1.1, 0), 0.11, 6, CHAR_DARK)
			k.pop()
		else:
			k.box(Vector3(0.5, 0.25, 0.5), CHARCOAL, Vector3(0, 0.125, 0))
			k.tube(Vector3(0, 0.2, 0), Vector3(0, MAST_H, 0), 0.11, 6, CHARCOAL)
			for y: float in [1.2, 2.3]:   # orange bands on the mast
				k.tube(Vector3(0, y, 0), Vector3(0, y + 0.22, 0), 0.14, 6, ORANGE)
			# Beacon: charcoal base, glowing lamp, orange-white cap; a floodlight box aimed at the front.
			k.box(Vector3(0.5, 0.14, 0.5), CHARCOAL, Vector3(0, MAST_H + 0.07, 0))
			k.box(Vector3(0.48, 0.12, 0.48), ORANGE, Vector3(0, MAST_H + 0.76, 0))
			k.glow = true
			k.seg(Vector3(0, MAST_H + 0.14, 0), Vector3(0, MAST_H + 0.7, 0), Vector2(0.2, 0.2), Vector2(0.17, 0.17), 8, LAMP)
			k.glow = false
			k.box(Vector3(0.62, 0.36, 0.3), CHARCOAL, Vector3(0, MAST_H - 0.45, 0.16))
			k.glow = true
			k.box(Vector3(0.5, 0.25, 0.04), LAMP, Vector3(0, MAST_H - 0.45, 0.33))
			k.glow = false
		_cache[key] = k.commit(LowPolyMaterials.materials())
	return _cache[key]


## A closed six-faced solid from its 8 corners: [b0, b1, b2, b3] bottom ring, [t0, t1, t2, t3] top ring (same order).
static func hexa(k: MeshKit, b: Array, t: Array, col: Variant) -> void:
	var c := Vector3.ZERO
	for p: Vector3 in b + t:
		c += p
	c /= 8.0
	k.quad(b[0], b[1], b[2], b[3], col, c)
	k.quad(t[0], t[1], t[2], t[3], col, c)
	for i in 4:
		var j := (i + 1) % 4
		k.quad(b[i], b[j], t[j], t[i], col, c)


## A thin plate lying on a planar face: `pts` (4 points on the face, in order), lifted `lift` off it along the outward
## normal `n` and `thick` deep. Used for stripes, marks and the emblem.
static func plate(k: MeshKit, pts: Array, n: Vector3, lift: float, thick: float, col: Variant) -> void:
	var b := []
	var t := []
	for p: Vector3 in pts:
		b.append(p + n * lift)
		t.append(p + n * (lift + thick))
	hexa(k, b, t, col)


## Bilinear point on a quad face given its corners (a = u0 v0, b = u1 v0, c = u1 v1, d = u0 v1).
static func on_quad(q: Array, u: float, v: float) -> Vector3:
	var lo: Vector3 = (q[0] as Vector3).lerp(q[1], u)
	var hi: Vector3 = (q[3] as Vector3).lerp(q[2], u)
	return lo.lerp(hi, v)


static func _body(wrecked: bool) -> ArrayMesh:
	var k := MeshKit.new()
	var white: Variant = WHITE
	var orange: Variant = ORANGE
	var charcoal: Variant = CHARCOAL
	if wrecked:
		# Scorched: soot over everything, a few panels burnt darker, the orange gone dull rust.
		white = func(c: Vector3, _n: Vector3) -> Color:
			return CHAR_DARK if hash(Vector3i((c * 3.0).round())) % 3 == 0 else CHAR
		orange = Color(0.32, 0.17, 0.1)
		charcoal = CHAR_DARK
	var hw := W * 0.5
	var hd := D * 0.5
	# Plinth.
	k.box(Vector3(W + 0.3, PLINTH_H, D + 0.3), charcoal, Vector3(0, PLINTH_H * 0.5, 0))
	# Central block behind the panel.
	var cb_h := BODY_TOP - PLINTH_H
	k.box(Vector3(RECESS_X * 2.0, cb_h, PANEL_Z - 0.3 + hd), white, Vector3(0, PLINTH_H + cb_h * 0.5, (-hd + PANEL_Z - 0.3) * 0.5))
	# Socket panel (charcoal) and the sill below the opening.
	k.box(Vector3(RECESS_X * 2.0, cb_h, 0.3), charcoal, Vector3(0, PLINTH_H + cb_h * 0.5, PANEL_Z - 0.15))
	var sill_d := hd - PANEL_Z + 0.05
	k.box(Vector3(RECESS_X * 2.0, SILL_TOP - PLINTH_H, sill_d), white,
		Vector3(0, (PLINTH_H + SILL_TOP) * 0.5, PANEL_Z + sill_d * 0.5))
	k.box(Vector3(RECESS_X * 2.0, 0.1, sill_d + 0.04), charcoal, Vector3(0, SILL_TOP - 0.05 + 0.01, PANEL_Z + sill_d * 0.5))
	# Buttresses: inner face vertical at +-RECESS_X; outer and front faces slope in toward the top.
	for sx: float in [-1.0, 1.0]:
		var b := [Vector3(sx * RECESS_X, PLINTH_H, -hd), Vector3(sx * hw, PLINTH_H, -hd), Vector3(sx * hw, PLINTH_H, hd),
			Vector3(sx * RECESS_X, PLINTH_H, hd)]
		var t := [Vector3(sx * RECESS_X, BODY_TOP, -hd), Vector3(sx * BUTTRESS_TOP_X, BODY_TOP, -hd),
			Vector3(sx * BUTTRESS_TOP_X, BODY_TOP, BUTTRESS_TOP_Z), Vector3(sx * RECESS_X, BODY_TOP, BUTTRESS_TOP_Z)]
		hexa(k, b, t, white)
		# Front slope: inner-bottom, outer-bottom, outer-top, inner-top.
		var front := [b[3], b[2], t[2], t[3]]
		var fn := ((front[3] as Vector3) - (front[0] as Vector3)).cross((front[1] as Vector3) - (front[0] as Vector3)).normalized()
		if fn.z < 0.0:
			fn = -fn
		# Hazard stripes: diagonal orange bands rising toward the outer edge.
		for v0: float in [0.06, 0.3, 0.54]:
			plate(k, [on_quad(front, 0.0, v0), on_quad(front, 1.0, v0 + 0.14), on_quad(front, 1.0, v0 + 0.25),
				on_quad(front, 0.0, v0 + 0.11)], fn, 0.0, 0.03, orange)
		# Charcoal edge trim up the inner edge of the slope (the recess frame post).
		plate(k, [on_quad(front, 0.0, 0.0), on_quad(front, 0.07, 0.0), on_quad(front, 0.07, 1.0), on_quad(front, 0.0, 1.0)],
			fn, 0.0, 0.035, charcoal)
		# Outer slope: back-bottom, front-bottom, front-top, back-top.
		var side := [b[1], b[2], t[2], t[1]]
		var sn := ((side[1] as Vector3) - (side[0] as Vector3)).cross((side[3] as Vector3) - (side[0] as Vector3)).normalized()
		if sn.x * sx < 0.0:
			sn = -sn
		# Orange corner band down the front edge, chevrons near the bottom.
		plate(k, [on_quad(side, 0.9, 0.0), on_quad(side, 1.0, 0.0), on_quad(side, 1.0, 1.0), on_quad(side, 0.9, 1.0)],
			sn, 0.0, 0.03, orange)
		for v0: float in [0.06, 0.2]:
			plate(k, [on_quad(side, 0.62, v0), on_quad(side, 0.82, v0 + 0.06), on_quad(side, 0.82, v0 + 0.1),
				on_quad(side, 0.62, v0 + 0.04)], sn, 0.0, 0.03, orange)
		plate(k, [on_quad(side, 0.0, 0.0), on_quad(side, 0.05, 0.0), on_quad(side, 0.05, 1.0), on_quad(side, 0.0, 1.0)],
			sn, 0.0, 0.035, charcoal)
		if sx > 0.0:
			_emblem(k, side, sn, orange, charcoal)
		# Frame post in the recess corner.
		k.box(Vector3(0.16, BODY_TOP - SILL_TOP, 0.3), charcoal,
			Vector3(sx * (RECESS_X - 0.08), (SILL_TOP + BODY_TOP) * 0.5, PANEL_Z + 0.15))
	# Recess lintel under the roof lip, with the shutter drum rolled up in front of it.
	k.box(Vector3(RECESS_X * 2.0, BODY_TOP - DRUM_Y - DRUM_R + 0.05, 0.5), charcoal,
		Vector3(0, (BODY_TOP + DRUM_Y + DRUM_R - 0.05) * 0.5, PANEL_Z + 0.25))
	k.push(MeshKit.xf(Vector3(0, DRUM_Y, PANEL_Z + 0.38)))
	k.seg(Vector3(-RECESS_X + 0.16, 0, 0), Vector3(RECESS_X - 0.16, 0, 0), Vector2(DRUM_R, DRUM_R), Vector2(DRUM_R, DRUM_R), 10,
		charcoal)
	for sx: float in [-1.0, 1.0]:
		k.seg(Vector3(sx * (RECESS_X - 0.18), 0, 0), Vector3(sx * (RECESS_X - 0.02), 0, 0), Vector2(DRUM_R + 0.06, DRUM_R + 0.06),
			Vector2(DRUM_R + 0.06, DRUM_R + 0.06), 8, charcoal)
	k.pop()
	# Sockets: a charcoal collar each, with its near-black hole on the front.
	for i in SOCKETS:
		var s := socket_local(i)
		k.tube(s + Vector3(0, 0, -0.02), s + Vector3(0, 0, COLLAR_OUT), COLLAR_R, N, charcoal)
		k.tube(s + Vector3(0, 0, COLLAR_OUT - 0.04), s + Vector3(0, 0, COLLAR_OUT + 0.01), HOLE_R, N, HOLE)
	# Roof slab: overhangs all round, heaviest at the front; seams and orange corner marks on top. Slumped when wrecked.
	if wrecked:
		k.push(MeshKit.xf(Vector3(0.9, BODY_TOP - 0.25, 0), Vector3(4.0, 0, -7.0)))
	else:
		k.push(MeshKit.xf(Vector3(0, BODY_TOP, 0)))
	var rz0 := -hd - 0.15
	var rz1 := hd + 0.35
	var rx := hw + 0.3
	k.box(Vector3(rx * 2.0, ROOF_T, rz1 - rz0), white, Vector3(0, ROOF_T * 0.5, (rz0 + rz1) * 0.5))
	k.box(Vector3(rx * 2.0 + 0.04, 0.1, 0.12), charcoal, Vector3(0, 0.05, rz1 - 0.05))   # front lip trim
	for x: float in [-2.0, -0.7, 0.7, 2.0]:
		k.box(Vector3(0.08, 0.03, rz1 - rz0 - 0.1), charcoal, Vector3(x, ROOF_T + 0.015, (rz0 + rz1) * 0.5))
	for sx: float in [-1.0, 1.0]:
		for z: float in [rz0, rz1]:
			var sz := -1.0 if z == rz0 else 1.0
			k.box(Vector3(0.7, 0.04, 0.14), orange, Vector3(sx * (rx - 0.35), ROOF_T + 0.02, z - sz * 0.07))
			k.box(Vector3(0.14, 0.04, 0.42), orange, Vector3(sx * (rx - 0.07), ROOF_T + 0.02, z - sz * 0.35))
		# Orange stripe on the roof's front edge face over each buttress.
		k.box(Vector3(0.9, ROOF_T * 0.6, 0.03), orange, Vector3(sx * 2.4, ROOF_T * 0.55, rz1 + 0.015))
	k.pop()
	if wrecked:
		# Debris: broken slab chunks in front and beside.
		k.ico(Vector3(-2.2, 0.25, 2.9), Vector3(0.6, 0.3, 0.45), CHAR)
		k.ico(Vector3(2.6, 0.2, 2.6), Vector3(0.45, 0.22, 0.4), CHAR_DARK)
		k.ico(Vector3(0.4, 0.15, 2.95), Vector3(0.35, 0.16, 0.3), CHAR)
		k.ico(Vector3(3.6, 0.3, -0.6), Vector3(0.55, 0.32, 0.7), CHAR)
	return k.commit(LowPolyMaterials.materials())


## The service emblem on the +X outer slope: an orange cross with a charcoal bolt across it.
static func _emblem(k: MeshKit, side: Array, n: Vector3, orange: Variant, charcoal: Variant) -> void:
	var cu := 0.5
	var cv := 0.6
	var arm := 0.2      # in face u (along z: 4 m) and v (along the slope: ~3.7 m) fractions
	var bar := 0.045
	var av := arm * 4.0 / 3.67
	var bv := bar * 4.0 / 3.67
	plate(k, [on_quad(side, cu - arm, cv - bv), on_quad(side, cu + arm, cv - bv), on_quad(side, cu + arm, cv + bv),
		on_quad(side, cu - arm, cv + bv)], n, 0.0, 0.03, orange)
	plate(k, [on_quad(side, cu - bar, cv - av), on_quad(side, cu + bar, cv - av), on_quad(side, cu + bar, cv - bv),
		on_quad(side, cu - bar, cv - bv)], n, 0.0, 0.03, orange)
	plate(k, [on_quad(side, cu - bar, cv + bv), on_quad(side, cu + bar, cv + bv), on_quad(side, cu + bar, cv + av),
		on_quad(side, cu - bar, cv + av)], n, 0.0, 0.03, orange)
	# Bolt: a three-stroke zigzag, proud of the cross.
	plate(k, [on_quad(side, cu - 0.07, cv + 0.2), on_quad(side, cu + 0.01, cv + 0.2), on_quad(side, cu - 0.02, cv + 0.02),
		on_quad(side, cu - 0.1, cv + 0.02)], n, 0.03, 0.02, charcoal)
	plate(k, [on_quad(side, cu - 0.1, cv + 0.02), on_quad(side, cu + 0.08, cv + 0.02), on_quad(side, cu + 0.1, cv - 0.04),
		on_quad(side, cu - 0.08, cv - 0.04)], n, 0.03, 0.02, charcoal)
	plate(k, [on_quad(side, cu + 0.02, cv - 0.04), on_quad(side, cu + 0.1, cv - 0.04), on_quad(side, cu + 0.07, cv - 0.22),
		on_quad(side, cu + 0.05, cv - 0.22)], n, 0.03, 0.02, charcoal)
