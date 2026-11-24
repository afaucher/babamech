class_name CityBuildings
extends RefCounted
## Turns one planned building into flat-shaded geometry, per style (docs/design/city-styles.md). Works in the building's
## own flat frame (x across, y up, z along the deck), so it knows nothing about the ring: the caller passes the frame.
## All detail is real geometry in palette colours (window panes, sills, piers, ledges, balconies, awnings, roof units).
## Colour choices come from the caller's COSMETIC generator: nothing here changes what you can stand on. Everything solid
## (tiers, the office plant room, skylights, the civic portico and gable) is drawn from plan data, the same data the
## collision is built from; loose roof units are CityProps (their prototypes are roof_unit()).

const FH := CityPlan.FLOOR_H
const COLOURWAY := 0.24      ## share of the buildings of a style in its second colourway (city-variety.md section 2)

static var _vr := RandomNumberGenerator.new()     ## the building being meshed: its own variety stream (build())
static var _corner := -1     ## the building being meshed: the side whose far end is a street corner of its front (-1: none)


## Whether the end of a Face on side `face_side` at u = w lies toward side `other` (Face u = up x n).
static func _corner_at_high_u(face_side: int, other: int) -> bool:
	var n: Vector2 = CityPlan.SIDE_N[face_side]
	var o: Vector2 = CityPlan.SIDE_N[other]
	return n.y * o.x - n.x * o.y > 0.0


## On a corner lot (its front and a neighbouring side both face a street): that neighbouring side, else -1.
static func _corner_side(lot: Dictionary, front: int) -> int:
	var faces: Array = lot["faces"]
	if front < 0 or not faces[front]:
		return -1
	for side: int in ([2, 3] if front < 2 else [0, 1]):
		if faces[side]:
			return side
	return -1


## One wall of a tier, seen from outside: u runs right along the wall, v is height above the building's ground, n out.
class Face:
	var xf: Transform3D
	var w := 0.0
	var y0 := 0.0
	var y1 := 0.0
	var side := 0
	var street := false


static func build(geo: CityGeo, xf: Transform3D, core_xf: Transform3D, plan: CityPlan, index: int, rng: RandomNumberGenerator) -> void:
	var b: Dictionary = plan.buildings[index]
	var lot: Dictionary = plan.lots[b["lot"]]
	geo.tag("bld." + str(b["style"]))
	# The building's own variety stream (tint, colourway, shopfront variants: docs/design/city-variety.md section 2), seeded
	# per building, so the district's shared cosmetic stream `rng` is drawn exactly as before and every other look stays.
	_vr.seed = plan.cosmetic_seed() * 92821 + index * 104729 + 7
	_corner = _corner_side(lot, int(b["front"]))
	match str(b["style"]):
		"apartment": _apartment(geo, xf, b, lot, rng)
		"office": _office(geo, xf, b, lot, rng)
		"sage": _sage(geo, xf, b, lot, rng)
		"shops": _shops(geo, xf, b, lot, rng)
		"civic": _civic(geo, xf, b, lot, rng)
		"pillar": _pillar(geo, xf, core_xf, b, lot, rng, plan.p("ceiling"))
		"tower": _tower(geo, xf, b, lot, rng, plan.p("ceiling"))
	if not plan.alleys.is_empty() and str(b["style"]) in ["apartment", "office", "sage", "shops"]:
		var side := plan.alley_side(int(b["lot"]))
		if side >= 0:
			_alley_face(geo, _faces(xf, b["tiers"][0], lot)[side])
	if not plan.forms.is_empty() and str(b["style"]) in ["apartment", "office", "sage", "shops"]:
		for f in _faces(xf, b["tiers"][0], lot):
			if f.street and plan.block_side_form(int(lot["block"]), f.side) == "lane":
				_lane_face(geo, f)


## A wall on a lane (city-variety.md): wall lamps on brackets every 8 m and a hanging sign on a bracket, instead of the
## street trees a street has. Fixed looks.
static func _lane_face(geo: CityGeo, f: Face) -> void:
	if f.w < 5.0:
		return
	geo.tag("lane.dressing")
	var n := maxi(int(f.w / 8.0), 1)
	for k in n:
		var u := f.w * (float(k) + 0.5) / float(n)
		_slab(geo, f, u - 0.06, u + 0.06, 4.9, 5.05, 0.9, _c("metal_dark"))
		geo.box(f.xf, Vector3(u, 4.75, 0.85), Vector3(0.36, 0.3, 0.36), _c("cream_light"), CityGeo.ALL, _c("metal_dark"))
	var us := f.w * (LANE_SIGN_U0 + LANE_SIGN_SPAN * _vr.randf())
	_slab(geo, f, us - 0.05, us + 0.05, 6.1, 6.2, 1.5, _c("metal_dark"))
	geo.box(f.xf, Vector3(us, 5.525, 1.0), Vector3(0.08, 1.15, 0.9), _pick(_vr, ["fascia_teal", "fascia_rose", "fascia_sand", "sage_dark", "terracotta"]))


## The wall a building turns to a service alley (city-variety.md): back doors with a small hood, downpipes and a pipe run.
static func _alley_face(geo: CityGeo, f: Face) -> void:
	if f.w < 4.0:
		return
	geo.tag("alley.dressing")
	var n := maxi(int(f.w / 12.0), 1)
	for k in n:
		var c := f.w * (float(k) + 0.5) / float(n) + _vr.randf_range(-ALLEY_DOOR_JITTER, ALLEY_DOOR_JITTER)
		c = clampf(c, ALLEY_DOOR_END, f.w - ALLEY_DOOR_END)
		# 0.16 out: in front of an apartment's 0.12 m base band. Pipes stand 0.41 / 0.47 m proud, clear of every style's
		# piers (0.3), cornices (0.35) and ledges (0.3), so no face of theirs lies in a facade's plane.
		_pane(geo, f, c - 0.6, c + 0.6, 0.0, 2.3, _c("door_back"), 0.16)
		_slab(geo, f, c - ALLEY_HOOD_HALF, c + ALLEY_HOOD_HALF, ALLEY_HOOD_V0, ALLEY_HOOD_V1, ALLEY_HOOD_D, _c("metal_dark"))
	for u: float in [0.6, f.w - 0.6]:
		_slab(geo, f, u - 0.12, u + 0.12, -0.3, f.y1 - 0.4, ALLEY_PIPE_D, _c("pipe"))
	# 4.95..5.2: clear of every style's sills, ledges and balcony tops (their top faces lay in a pipe run at 4.45).
	_slab(geo, f, 0.75, f.w - 0.75, ALLEY_RUN_V0, ALLEY_RUN_V1, ALLEY_RUN_D, _c("pipe"))


# --- Shared pieces ---------------------------------------------------------------------------------------

static func _c(id: String) -> Color:
	return CityPalette.C[id]


static func _pick(rng: RandomNumberGenerator, ids: Array) -> Color:
	return CityPalette.C[ids[rng.randi_range(0, ids.size() - 1)]]


static func _faces(xf: Transform3D, t: Dictionary, lot: Dictionary) -> Array[Face]:
	var out: Array[Face] = []
	var size: Vector2 = t["size"]
	var off: Vector2 = t["off"]
	for side in 4:
		var n2: Vector2 = CityPlan.SIDE_N[side]
		var n := Vector3(n2.x, 0.0, n2.y)
		var u := Vector3.UP.cross(n)
		var f := Face.new()
		f.w = size.y if side < 2 else size.x
		var depth := size.x if side < 2 else size.y
		f.xf = xf * Transform3D(Basis(u, Vector3.UP, n), Vector3(off.x, 0.0, off.y) + n * depth * 0.5 - u * f.w * 0.5)
		f.y0 = t["y0"]
		f.y1 = t["y1"]
		f.side = side
		f.street = bool(lot["faces"][side])
		out.append(f)
	return out


## The tier's own box. A tier on the ground goes a little below it (the deck curves away under a straight wall).
static func _body(geo: CityGeo, xf: Transform3D, t: Dictionary, wall: Color, roof: Color) -> void:
	var y0: float = -1.0 if float(t["y0"]) <= 0.0 else float(t["y0"])
	var y1: float = t["y1"]
	geo.box(xf, Vector3((t["off"] as Vector2).x, (y0 + y1) * 0.5, (t["off"] as Vector2).y),
			Vector3((t["size"] as Vector2).x, y1 - y0, (t["size"] as Vector2).y), wall, CityGeo.NO_BOTTOM, roof)


## A box standing `d` proud of the wall. Keeps its back face whenever it extends above the roofline, past the wall edges,
## or below an elevated tier's base.
static func _slab(geo: CityGeo, f: Face, u0: float, u1: float, v0: float, v1: float, d: float, col: Color) -> void:
	var exposed := v1 > f.y1 + 0.001 or u0 < -0.001 or u1 > f.w + 0.001 or (f.y0 > 0.001 and v0 < f.y0 - 0.001)
	var mask := CityGeo.ALL if exposed else CityGeo.NO_BACK
	geo.box(f.xf, Vector3((u0 + u1) * 0.5, (v0 + v1) * 0.5, d * 0.5), Vector3(u1 - u0, v1 - v0, d), col, mask)


## A flat pane just off the wall (windows, doors).
static func _pane(geo: CityGeo, f: Face, u0: float, u1: float, v0: float, v1: float, col: Color, out: float = 0.05) -> void:
	geo.quad(f.xf * Vector3(u0, v0, out), f.xf * Vector3(u1, v0, out), f.xf * Vector3(u1, v1, out), f.xf * Vector3(u0, v1, out), col)


## Bay centres across a wall of width w: as many bays of about `want` as fit between the margins.
static func _bays(w: float, want: float, margin: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := maxi(int(floor((w - margin * 2.0) / want)), 1)
	var pitch := (w - margin * 2.0) / float(n)
	for i in n:
		out.append(margin + pitch * (float(i) + 0.5))
	return out


static func _pitch(w: float, want: float, margin: float) -> float:
	return (w - margin * 2.0) / float(maxi(int(floor((w - margin * 2.0) / want)), 1))


static func _band(geo: CityGeo, faces: Array[Face], v0: float, v1: float, d: float, col: Color) -> void:
	for f in faces:
		_slab(geo, f, -d, f.w + d, v0, v1, d, col)


static func _awning(geo: CityGeo, f: Face, u0: float, u1: float, v_top: float, v_bot: float, depth: float, col: Color,
		under: Color) -> void:
	var a := f.xf * Vector3(u0, v_top, 0.0)
	var b := f.xf * Vector3(u1, v_top, 0.0)
	var c := f.xf * Vector3(u1, v_bot, depth)
	var d := f.xf * Vector3(u0, v_bot, depth)
	var e := f.xf * Vector3(u0, v_bot - 0.35, depth)
	var g := f.xf * Vector3(u1, v_bot - 0.35, depth)
	var wb0 := f.xf * Vector3(u0, v_bot, 0.0)
	var wb1 := f.xf * Vector3(u1, v_bot, 0.0)
	geo.quad(d, c, b, a, col)
	geo.quad(a, b, c, d, under)
	geo.quad(e, g, c, d, col)
	geo.quad(g, e, d, c, under)
	geo.tri(a, wb0, d, col)
	geo.tri(a, d, wb0, under)
	geo.tri(b, c, wb1, col)
	geo.tri(b, wb1, c, under)


# --- Facade relief (what stands out from a wall: docs/design/banners.md "Clear of the facade") --------------------
# The numbers below are the meshers' own (they draw with these constants), so relief() and the drawn facade agree.
# Plain floats (a Vector3 would round them to single precision and move the drawn vertices): *_HALF a half width,
# *_V0 / *_V1 heights, *_D how far the piece stands proud of the wall.
const APT_BAY := 3.4
const APT_BAY_MARGIN := 1.0
const APT_BALCONY_HALF := 1.3     ## v0 / v1 from the storey line
const APT_BALCONY_V0 := -0.12
const APT_BALCONY_V1 := 1.05
const APT_BALCONY_D := 1.1
const APT_CANOPY_HALF := 1.6         ## over the front door
const APT_CANOPY_V0 := 2.7
const APT_CANOPY_V1 := 2.95
const APT_CANOPY_D := 1.3
const OFFICE_CANOPY_HALF := 3.2
const OFFICE_CANOPY_V0 := 3.0
const OFFICE_CANOPY_V1 := 3.35
const OFFICE_CANOPY_D := 2.2
const SAGE_CANOPY_HALF := 2.4
const SAGE_CANOPY_V0 := 2.85
const SAGE_CANOPY_V1 := 3.1
const SAGE_CANOPY_D := 1.6
const SHOP_BAY := 5.6
const SHOP_MARGIN := 0.3
const SHOP_AWNING_IN := 0.32
const SHOP_AWNINGS := [[3.3, 2.75, 1.5], [3.3, 3.05, 1.3], [3.4, 2.5, 0.9]]   ## (v top, v bottom, depth) per shape
const SHOP_VALANCE := 0.35                          ## a sloped awning's valance hangs this far below its bottom edge
const SHOP_JAMB_D := 0.45                           ## a recessed entrance's jambs and head (0..2.8 m)
const SHOP_BLADE_V0 := 3.6        ## the corner blade sign, 0.08 either side of its u
const SHOP_BLADE_V1 := 5.9
const SHOP_BLADE_D := 0.95
const DT_SHOP_BAY := 5.2
const DT_SHOP_MARGIN := 0.4
const DT_AWNING_IN := 0.55
const DT_AWNING_D := 1.3
const DT_CANOPY_V0 := 4.4         ## a tower lobby's canopy (DT_CANOPY_D proud of the plan line)
const DT_CANOPY_V1 := 4.8
const DT_CANOPY_D := 1.6
const ALLEY_DOOR_JITTER := 1.5
const ALLEY_DOOR_END := 1.5
const ALLEY_HOOD_HALF := 0.8
const ALLEY_HOOD_V0 := 2.45
const ALLEY_HOOD_V1 := 2.65
const ALLEY_HOOD_D := 0.7
const ALLEY_PIPE_D := 0.41
const ALLEY_RUN_V0 := 4.95        ## the pipe run
const ALLEY_RUN_V1 := 5.2
const ALLEY_RUN_D := 0.47
const LANE_SIGN_U0 := 0.25        ## a lane's hanging sign: u = w * (U0 + SPAN * roll)
const LANE_SIGN_SPAN := 0.5
const RELIEF_MIN := 0.4      ## relief() lists what stands out at least this far (bands, sills, piers, cornices are shallower)


## Whether an apartment's face on `side` with `n_bays` bays carries balconies (the street side and its opposite).
static func _apt_balconied(b: Dictionary, side: int, n_bays: int) -> bool:
	return side / 2 == int(b["front"]) / 2 and n_bays >= 2


## What stands out of tier `ti` of building `index` at least RELIEF_MIN deep, per side (0..3, CityPlan.SIDE_N; the
## Face frame: u along the wall from its left end seen from outside, v up from the building's ground, depth out from the
## tier's plan line): [[{u0, u1, v0, v1, d}, ...] x 4]. Deterministic from the plan alone. Where the drawn piece depends on
## a cosmetic roll (which bays of an apartment get balconies, a shop row's awning shape, an alley door's jitter, a lane
## sign's place) it lists every place / shape the roll can give, so it is never smaller than what is drawn.
static func relief(plan: CityPlan, index: int, ti: int) -> Array:
	var b: Dictionary = plan.buildings[index]
	var lot: Dictionary = plan.lots[b["lot"]]
	var tiers: Array = b["tiers"]
	var t: Dictionary = tiers[ti]
	var out: Array = [[], [], [], []]
	var faces := _faces(Transform3D.IDENTITY, t, lot)
	var style := str(b["style"])
	var front := int(b["front"])
	var add := func(side: int, u0: float, u1: float, v0: float, v1: float, d: float) -> void:
		if d >= RELIEF_MIN:
			(out[side] as Array).append({"u0": u0, "u1": u1, "v0": v0, "v1": v1, "d": d})
	for f in faces:
		match style:
			"apartment":
				if ti != 0:
					continue
				var bays := _bays(f.w, APT_BAY, APT_BAY_MARGIN)
				if f.street and f.side == front and bays.size() > 0:
					var c := bays[bays.size() / 2]
					add.call(f.side, c - APT_CANOPY_HALF, c + APT_CANOPY_HALF, APT_CANOPY_V0, APT_CANOPY_V1, APT_CANOPY_D)
				if _apt_balconied(b, f.side, bays.size()):
					for i in range(1, int(b["floors"])):
						var y := float(i) * FH
						for c in bays:      # either phase: every bay
							add.call(f.side, c - APT_BALCONY_HALF, c + APT_BALCONY_HALF, y + APT_BALCONY_V0, y + APT_BALCONY_V1, APT_BALCONY_D)
			"office":
				if ti == 0 and f.side == front:
					add.call(f.side, f.w * 0.5 - OFFICE_CANOPY_HALF, f.w * 0.5 + OFFICE_CANOPY_HALF, OFFICE_CANOPY_V0, OFFICE_CANOPY_V1, OFFICE_CANOPY_D)
			"sage":
				if f.y0 <= 0.0 and f.side == front:
					add.call(f.side, f.w * 0.5 - SAGE_CANOPY_HALF, f.w * 0.5 + SAGE_CANOPY_HALF, SAGE_CANOPY_V0, SAGE_CANOPY_V1, SAGE_CANOPY_D)
			"shops":
				if ti != 0 or not f.street:
					continue
				var bays := _bays(f.w, SHOP_BAY, SHOP_MARGIN)
				var h := _pitch(f.w, SHOP_BAY, SHOP_MARGIN) * 0.5
				var vlo := INF
				var vhi := -INF
				var dmax := 0.0
				for k in SHOP_AWNINGS.size():
					var a: Array = SHOP_AWNINGS[k]
					vlo = minf(vlo, float(a[1]) - (SHOP_VALANCE if k != 1 else 0.0))
					vhi = maxf(vhi, float(a[0]))
					dmax = maxf(dmax, float(a[2]))
				for c in bays:
					add.call(f.side, c - h + SHOP_AWNING_IN, c + h - SHOP_AWNING_IN, vlo, vhi, dmax)
					add.call(f.side, c + h - 2.1, c + h - 0.55, 0.0, 2.8, SHOP_JAMB_D)
				var corner := _corner_side(lot, front)
				if corner >= 0 and f.side == corner:
					var ub := f.w - 0.35 if _corner_at_high_u(f.side, front) else 0.35
					add.call(f.side, ub - 0.08, ub + 0.08, SHOP_BLADE_V0, SHOP_BLADE_V1, SHOP_BLADE_D)
			"tower":
				var kind := str(t.get("kind", ""))
				var base := str(b.get("base", "podium"))
				if kind in ["podium", "terrace", "arcade"] and f.w >= 3.0 and float(t["y0"]) <= 0.0 and f.street \
						and (base == "podium" or base == "twin"):
					var bays := _bays(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
					var pitch := _pitch(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
					for c in bays:
						add.call(f.side, c - pitch * 0.5 + DT_AWNING_IN, c + pitch * 0.5 - DT_AWNING_IN, FH - 1.15 - SHOP_VALANCE, FH - 0.55, DT_AWNING_D)
				elif kind == "tower" and float(t["y0"]) <= 0.0 and f.side == front:
					var size: Vector2 = t["size"]
					var slab := str(t.get("tower", "point")) == "slab"
					var recess := DT_SPANDREL if slab else DT_PIER
					var corner_w := minf(1.8, minf(size.x, size.y) * 0.18) if not slab else 0.9
					var inset := maxf(corner_w - recess, 0.3)
					var wi := f.w - recess * 2.0      # the recessed glass face the canopy is drawn on; u shifts by recess
					add.call(f.side, recess + inset + 0.2, recess + wi - inset - 0.2, DT_CANOPY_V0, DT_CANOPY_V1, DT_CANOPY_D)
		if ti == 0 and style in ["apartment", "office", "sage", "shops"]:
			if not plan.alleys.is_empty() and plan.alley_side(int(b["lot"])) == f.side and f.w >= 4.0:
				var n := maxi(int(f.w / 12.0), 1)
				for k in n:
					var c := f.w * (float(k) + 0.5) / float(n)
					var lo := clampf(c - ALLEY_DOOR_JITTER, ALLEY_DOOR_END, f.w - ALLEY_DOOR_END)
					var hi := clampf(c + ALLEY_DOOR_JITTER, ALLEY_DOOR_END, f.w - ALLEY_DOOR_END)
					add.call(f.side, lo - ALLEY_HOOD_HALF, hi + ALLEY_HOOD_HALF, ALLEY_HOOD_V0, ALLEY_HOOD_V1, ALLEY_HOOD_D)
				for u: float in [0.6, f.w - 0.6]:
					add.call(f.side, u - 0.12, u + 0.12, -0.3, f.y1 - 0.4, ALLEY_PIPE_D)
				add.call(f.side, 0.75, f.w - 0.75, ALLEY_RUN_V0, ALLEY_RUN_V1, ALLEY_RUN_D)
			if not plan.forms.is_empty() and f.street and f.w >= 5.0 and plan.block_side_form(int(lot["block"]), f.side) == "lane":
				var n := maxi(int(f.w / 8.0), 1)
				for k in n:
					var u := f.w * (float(k) + 0.5) / float(n)
					add.call(f.side, u - 0.18, u + 0.18, 4.6, 5.05, 1.03)        # bracket (0.9) and lamp (to 1.03)
				add.call(f.side, f.w * LANE_SIGN_U0 - 0.05, f.w * (LANE_SIGN_U0 + LANE_SIGN_SPAN) + 0.05, 4.95, 6.2, 1.5)
	return out


## Where on face `side` of tier `ti` a plan point (x, s) lies: Vector2(u, depth out of the wall) in relief()'s frame.
static func face_coords(plan: CityPlan, index: int, ti: int, side: int, pt: Vector2) -> Vector2:
	var b: Dictionary = plan.buildings[index]
	var t: Dictionary = b["tiers"][ti]
	var n: Vector2 = CityPlan.SIDE_N[side]
	var sz: Vector2 = t["size"]
	var u2 := Vector2(n.y, -n.x)      # Face u = up x n
	var w := sz.y if side < 2 else sz.x
	var depth := sz.x if side < 2 else sz.y
	var origin := (b["center"] as Vector2) + (t["off"] as Vector2) + n * depth * 0.5 - u2 * w * 0.5
	return Vector2((pt - origin).dot(u2), (pt - origin).dot(n))


# --- Roof furniture --------------------------------------------------------------------------------------
# Tanks, AC units, vents and planters are knockable CityProps (docs/design/city-rooftops.md): the builders below are their
# prototypes, closed underneath so a toppled one shows no hollow. Skylights are solid plan geometry (plan solids).

const TANK_COLOURS := ["terracotta_dark", "sand", "metal"]     ## water tank variants (CityProps variant index)


## One roof unit upright at the origin of `xf`: type water_tank | ac | vent | planter (CityProps prototypes).
static func roof_unit(geo: CityGeo, xf: Transform3D, type: String, variant: int) -> void:
	match type:
		"water_tank": _water_tank(geo, xf, Vector3.ZERO, _c(TANK_COLOURS[clampi(variant, 0, TANK_COLOURS.size() - 1)]))
		"ac": _ac_unit(geo, xf, Vector3.ZERO, 0.0)
		"vent": geo.prism(xf, Vector3.ZERO, 0.45, 1.1, 6, _c("metal"), 0.45, _c("metal_dark"), _c("metal"))
		"planter": _planter(geo, xf, Vector3.ZERO, Vector2(3.2, 1.3))


static func _ac_unit(geo: CityGeo, xf: Transform3D, at: Vector3, yaw: float) -> void:
	var t := xf * Transform3D(Basis(Vector3.UP, yaw), at)
	geo.box(t, Vector3(0, 0.75, 0), Vector3(1.9, 1.1, 1.2), _c("metal"), CityGeo.ALL, _c("metal_dark"))
	geo.box(t, Vector3(0, 0.1, 0), Vector3(2.2, 0.2, 1.5), _c("concrete_dark"), CityGeo.ALL)


static func _water_tank(geo: CityGeo, xf: Transform3D, at: Vector3, col: Color) -> void:
	var t := xf * Transform3D(Basis.IDENTITY, at)
	for k: Vector2 in [Vector2(-0.8, -0.8), Vector2(0.8, -0.8), Vector2(0.8, 0.8), Vector2(-0.8, 0.8)]:
		geo.box(t, Vector3(k.x, 0.7, k.y), Vector3(0.22, 1.4, 0.22), _c("metal_dark"), CityGeo.ALL)
	geo.prism(t, Vector3(0, 1.4, 0), 1.35, 2.2, 8, col, -1.0, null, col.darkened(0.12))
	geo.prism(t, Vector3(0, 3.6, 0), 1.5, 0.7, 8, _c("roof_dark"), 0.0, null, _c("roof_dark"))


static func _planter(geo: CityGeo, xf: Transform3D, at: Vector3, size: Vector2) -> void:
	var t := xf * Transform3D(Basis.IDENTITY, at)
	geo.box(t, Vector3(0, 0.35, 0), Vector3(size.x, 0.7, size.y), _c("cream_light"), CityGeo.ALL, _c("soil"))
	var n := maxi(int(size.x / 1.6), 1)
	var leaves := ["leaf", "leaf_dark", "leaf_light"]
	for i in n:
		var x := (float(i) + 0.5) / float(n) * size.x - size.x * 0.5
		var col := _c(leaves[i % leaves.size()])
		geo.prism(t, Vector3(x, 0.7, 0), minf(size.y, 1.5) * 0.48, 0.95 - 0.15 * float(i % 2), 5, col, 0.25, null, col)


## A skylight solid of the plan (building frame): its concrete curb (the solid part) and a glass ridge along its longer side.
static func _skylight(geo: CityGeo, xf: Transform3D, so: Dictionary) -> void:
	var sz: Vector2 = so["size"]
	var yaw := PI * 0.5 if sz.x > sz.y else 0.0
	var t := xf * Transform3D(Basis(Vector3.UP, yaw), Vector3((so["off"] as Vector2).x, float(so["y0"]), (so["off"] as Vector2).y))
	var long := maxf(sz.x, sz.y)
	var short := minf(sz.x, sz.y)
	geo.box(t, Vector3(0, 0.2, 0), Vector3(short, 0.4, long), _c("concrete"), CityGeo.NO_BOTTOM)      # the solid curb (plan y1)
	geo.gable(t, Vector3(0, 0.4, 0), short - 0.2, long - 0.2, 0.7, _c("glass_blue"), _c("concrete"))


## What is drawn on a roof slot: its skylights (plan solids). The roll below keeps the cosmetic stream exactly where the
## old roof clutter left it, so every later colour pick in the district stays the same now that the loose units are
## CityProps (laid out from the gameplay stream).
static func _roof(geo: CityGeo, xf: Transform3D, b: Dictionary, t: Dictionary, rng: RandomNumberGenerator, kinds: Array) -> void:
	for so: Dictionary in b.get("solids", []):
		if so["kind"] == "skylight" and absf(float(so["y0"]) - float(t["y1"])) < 0.01:
			_skylight(geo, xf, so)
	var size: Vector2 = t["size"]
	var n := clampi(int(size.x * size.y / 70.0), 1, 5)
	var used: Array[Vector2] = []
	for i in n:
		var pos := Vector2(rng.randf_range(-1.0, 1.0) * maxf(size.x * 0.5 - 2.6, 0.0), rng.randf_range(-1.0, 1.0) * maxf(size.y * 0.5 - 2.6, 0.0))
		var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
		rng.randf()      # was the unit's yaw
		var clear := true
		for q in used:
			if q.distance_to(pos) < 3.6:
				clear = false
		if not clear:
			continue
		used.append(pos)
		if kind == "planter":      # was the planter's two bushes: height and colour each
			for k in 2:
				rng.randf_range(0.7, 1.2)
				rng.randi_range(0, 2)


static func _punched(geo: CityGeo, f: Face, y: float, bays: PackedFloat32Array, half_w: float, v0: float, v1: float,
		glass: Color, trim: Color) -> void:
	for c in bays:
		_pane(geo, f, c - half_w, c + half_w, y + v0, y + v1, glass)
		_slab(geo, f, c - half_w - 0.15, c + half_w + 0.15, y + v0 - 0.16, y + v0, 0.2, trim)


# --- 1. Terracotta apartments ----------------------------------------------------------------------------

static func _apartment(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator) -> void:
	var wall := _pick(rng, ["terracotta", "terracotta", "terracotta_light", "terracotta_dark", "cream"])
	var trim := _c("terracotta") if wall == _c("cream") else _c("cream_light")
	var base := _pick(rng, ["concrete", "cream", "sand"])
	var glass := _pick(rng, ["glass_teal", "glass_dark", "glass_teal"])
	var balcony := _pick(rng, ["cream_light", "sage_light", "cream"])
	if _vr.randf() < COLOURWAY:      # second colourway: sky-blue body, cream trim, blue glass
		wall = _c("apt_sky") if _vr.randf() < 0.7 else _c("apt_sky_dark")
		trim = _c("cream_light")
		glass = _c("glass_blue")
	wall = CityPalette.tint(wall, _vr)
	var main: Dictionary = b["tiers"][0]
	var floors: int = b["floors"]
	var roof: float = b["roof_h"]
	_body(geo, xf, main, wall, _c("roof"))
	var faces := _faces(xf, main, lot)
	var phase := rng.randi_range(0, 1)
	for f in faces:
		var bays := _bays(f.w, APT_BAY, APT_BAY_MARGIN)
		_slab(geo, f, -0.12, f.w + 0.12, -0.5, FH, 0.12, base)
		var door := bays.size() / 2
		for k in bays.size():
			var c := bays[k]
			if f.street and f.side == int(b["front"]) and k == door:
				_pane(geo, f, c - 0.9, c + 0.9, 0.05, 2.5, _c("glass_dark"), 0.17)
				_slab(geo, f, c - APT_CANOPY_HALF, c + APT_CANOPY_HALF, APT_CANOPY_V0, APT_CANOPY_V1, APT_CANOPY_D, trim)
			elif f.street:
				_pane(geo, f, c - 1.15, c + 1.15, 0.85, 2.55, glass, 0.17)
			else:
				_pane(geo, f, c - 0.6, c + 0.6, 1.3, 2.4, glass, 0.17)
		var with_balconies := _apt_balconied(b, f.side, bays.size())
		for i in range(1, floors):
			var y := float(i) * FH
			for k in bays.size():
				var c := bays[k]
				if with_balconies and (k + phase) % 2 == 0:
					_pane(geo, f, c - 0.65, c + 0.65, y + 0.1, y + 2.35, glass)
					_slab(geo, f, c - APT_BALCONY_HALF, c + APT_BALCONY_HALF, y + APT_BALCONY_V0, y + APT_BALCONY_V1, APT_BALCONY_D, balcony)
				else:
					_pane(geo, f, c - 0.7, c + 0.7, y + 0.95, y + 2.45, glass)
					_slab(geo, f, c - 0.85, c + 0.85, y + 0.79, y + 0.95, 0.2, trim)
	_band(geo, faces, FH - 0.15, FH + 0.15, 0.22, trim)
	_band(geo, faces, roof - 0.3, roof + 0.5, 0.3, trim)
	# Roof: stair bulkhead (a tier: you can stand on it), water tank, a couple of units.
	if (b["tiers"] as Array).size() > 1:
		var bulk: Dictionary = b["tiers"][1]
		_body(geo, xf, bulk, wall, _c("roof_dark"))
		var bf := _faces(xf, bulk, lot)[rng.randi_range(0, 3)]
		_pane(geo, bf, bf.w * 0.5 - 0.6, bf.w * 0.5 + 0.6, roof + 0.05, roof + 2.2, _c("metal_dark"))
	_pick(rng, TANK_COLOURS)      # was the tank colour (the tanks are CityProps now): keeps the cosmetic stream in step
	_roof(geo, xf, b, main, rng, ["tank", "tank", "ac", "vent"])


# --- 2. Cream offices ------------------------------------------------------------------------------------

static func _office(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator) -> void:
	var glass := _pick(rng, ["glass_blue", "glass_teal", "glass_blue"])
	var frame := _pick(rng, ["cream_light", "cream", "sand"])
	var spandrel := _pick(rng, ["cream", "sand", "cream_light"])
	var accent := _pick(rng, ["terracotta", "sage_dark", "blue_grey"])
	if _vr.randf() < COLOURWAY:      # second colourway: sand frame and spandrels, teal glass
		frame = _c("office_sand")
		spandrel = _c("sand_light")
		glass = _c("glass_teal")
	frame = CityPalette.tint(frame, _vr, 0.7)
	spandrel = CityPalette.tint(spandrel, _vr, 0.7)
	var tiers: Array = b["tiers"]
	var plant := {}
	for t: Dictionary in tiers:
		if str(t.get("kind", "")) == "plant":
			plant = t
			continue
		_body(geo, xf, t, glass, _c("roof"))
		_grid_facade(geo, _faces(xf, t, lot), frame, spandrel, 3.2)
	var faces := _faces(xf, tiers[0], lot)
	for f in faces:
		if f.side == int(b["front"]):
			_pane(geo, f, f.w * 0.5 - 1.7, f.w * 0.5 + 1.7, 0.0, 2.9, _c("glass_dark"), 0.03)
			_slab(geo, f, f.w * 0.5 - OFFICE_CANOPY_HALF, f.w * 0.5 + OFFICE_CANOPY_HALF, OFFICE_CANOPY_V0, OFFICE_CANOPY_V1, OFFICE_CANOPY_D, accent)
	var top: Dictionary = tiers[int(plan_top(b))]
	var ts: Vector2 = top["size"]
	if not plant.is_empty():      # plant room (a plan tier: solid, standable) and mast
		var pt := xf * Transform3D(Basis.IDENTITY, Vector3((top["off"] as Vector2).x, float(top["y1"]), (top["off"] as Vector2).y))
		_body(geo, xf, plant, frame, _c("roof_dark"))
		if rng.randf() < 0.5:
			geo.box(pt, Vector3(ts.x * 0.12, 2.4 + 1.6, 0), Vector3(0.18, 3.2, 0.18), _c("metal_dark"), CityGeo.NO_BOTTOM)
	_roof(geo, xf, b, top, rng, ["ac", "ac", "vent"])


## The office's top occupied tier (the one under its plant room, if it has one).
static func plan_top(b: Dictionary) -> int:
	var tiers: Array = b["tiers"]
	var top := tiers.size() - 1
	if str(tiers[top].get("kind", "")) == "plant":
		top -= 1
	return top


## Piers and spandrels over a glass-coloured box: ribbon glazing with real relief.
static func _grid_facade(geo: CityGeo, faces: Array[Face], frame: Color, spandrel: Color, want: float) -> void:
	for f in faces:
		var pitch := _pitch(f.w, want, 0.0)
		var n := int(round(f.w / pitch))
		var v0 := f.y0 - (0.5 if f.y0 <= 0.0 else 0.0)
		for k in n + 1:
			var u := float(k) * pitch
			var a := -0.3 if k == 0 else u - 0.35
			var c := f.w + 0.3 if k == n else u + 0.35
			if k == 0:
				c = 0.55
			if k == n:
				a = f.w - 0.55
			_slab(geo, f, a, c, v0, f.y1 + 0.5, 0.3, frame)
		var floors := int(round((f.y1 - f.y0) / FH))
		for i in range(1, floors):
			var y := f.y0 + float(i) * FH
			_slab(geo, f, 0.0, f.w, y - 0.55, y + 0.4, 0.14, spandrel)
		_slab(geo, f, -0.35, f.w + 0.35, f.y1 - 0.7, f.y1 + 0.5, 0.35, frame)


# --- 3. Sage panel blocks --------------------------------------------------------------------------------

static func _sage(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator) -> void:
	var wall := _pick(rng, ["sage", "sage", "sage_light", "sage_dark", "blue_grey"])
	var ledge := _pick(rng, ["cream_light", "cream"])
	var glass := _pick(rng, ["glass_dark", "glass_teal"])
	if _vr.randf() < COLOURWAY:      # second colourway: pale cream panels with sage ledges
		wall = _c("sage_cream")
		ledge = _c("sage_dark")
		glass = _c("glass_teal")
	wall = CityPalette.tint(wall, _vr)
	var tiers: Array = b["tiers"]
	for t: Dictionary in tiers:
		_body(geo, xf, t, wall, _c("roof"))
		var faces := _faces(xf, t, lot)
		for f in faces:
			var floors := int(round((f.y1 - f.y0) / FH))
			var bays := _bays(f.w, 2.8, 1.0)
			var pitch := _pitch(f.w, 2.8, 1.0)
			for i in floors:
				var y := f.y0 + float(i) * FH
				var ground := f.y0 <= 0.0 and i == 0
				var lo := y + (0.45 if ground and f.street else 1.0)
				var hi := y + (2.7 if ground and f.street else 2.45)
				_pane(geo, f, 1.0, f.w - 1.0, lo, hi, glass)
				for k in range(1, bays.size()):
					var u := bays[k] - pitch * 0.5
					_slab(geo, f, u - 0.2, u + 0.2, lo, hi, 0.12, wall)
				if i > 0:
					_slab(geo, f, -0.25, f.w + 0.25, y - 0.15, y + 0.15, 0.25, ledge)
			_slab(geo, f, -0.3, f.w + 0.3, f.y1 - 0.2, f.y1 + 0.5, 0.3, ledge)
			if f.y0 <= 0.0 and f.side == int(b["front"]):
				_pane(geo, f, f.w * 0.5 - 1.2, f.w * 0.5 + 1.2, 0.0, 2.7, _c("glass_dark"), 0.07)
				_slab(geo, f, f.w * 0.5 - SAGE_CANOPY_HALF, f.w * 0.5 + SAGE_CANOPY_HALF, SAGE_CANOPY_V0, SAGE_CANOPY_V1, SAGE_CANOPY_D, ledge)
	# Roof garden on the main roof, units on the penthouse.
	_roof(geo, xf, b, tiers[0], rng, ["planter", "planter", "skylight"] if tiers.size() == 1 else ["planter"])
	if tiers.size() > 1:
		_roof(geo, xf, b, tiers[1], rng, ["ac", "vent"])


# --- 4. Shop rows ----------------------------------------------------------------------------------------

static func _shops(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator) -> void:
	var wall := _pick(rng, ["cream", "cream_light", "terracotta_light", "sage_light", "sky_blue", "sand"])
	var trim := _c("cream_light") if wall != _c("cream_light") else _c("sand")
	if _vr.randf() < COLOURWAY:      # second colourway: a rose-terracotta row with cream trim
		wall = _c("shop_rose")
		trim = _c("cream_light")
	wall = CityPalette.tint(wall, _vr)
	var main: Dictionary = b["tiers"][0]
	var roof: float = b["roof_h"]
	_body(geo, xf, main, wall, _c("roof"))
	var faces := _faces(xf, main, lot)
	var awnings := ["terracotta", "sage_dark", "sky_blue", "marking_yellow", "terracotta_dark", "cream_light"]
	# Shopfront variants (one per row: awning shape, recessed doors; fascia colours per unit), from the row's own stream.
	var shape := _vr.randi_range(0, 2)          # 0 sloped awning, 1 flat canopy, 2 short steep awning
	var recessed := _vr.randf() < 0.4
	var fascias := ["cream_light", "sage", "terracotta", "blue_grey", "fascia_teal", "fascia_sand", "fascia_rose", "awning_cream"]
	var more_awnings := ["awning_teal", "awning_sky", "awning_cream", "terracotta", "sage_dark"]
	for f in faces:
		if f.street:
			var bays := _bays(f.w, SHOP_BAY, SHOP_MARGIN)
			var pitch := _pitch(f.w, SHOP_BAY, SHOP_MARGIN)
			for k in bays.size():
				var c := bays[k]
				var h := pitch * 0.5
				var col := _pick(rng, awnings)
				var fascia := _pick(rng, ["cream_light", "sage", "terracotta", "blue_grey"])
				if _vr.randf() < 0.5:
					col = _pick(_vr, more_awnings)
				if _vr.randf() < 0.5:
					fascia = _pick(_vr, fascias)
				_pane(geo, f, c - h + 0.45, c + h - 0.45, 0.55, 3.0, _c("glass_dark"))
				_pane(geo, f, c + h - 1.9, c + h - 0.75, 0.0, 2.6, _c("glass_teal"), 0.07)
				if recessed:
					# A recessed entrance: deep jambs and a head round the door, so the door reads as set into the front.
					_slab(geo, f, c + h - 2.1, c + h - 1.9, 0.0, 2.8, SHOP_JAMB_D, trim)
					_slab(geo, f, c + h - 0.75, c + h - 0.55, 0.0, 2.8, SHOP_JAMB_D, trim)
					_slab(geo, f, c + h - 2.1, c + h - 0.55, 2.6, 2.8, SHOP_JAMB_D, trim)
				# 2 cm clear of the pilasters (u +/- 0.3): its double-sided end gussets lay in their side faces (z-fighting).
				match shape:
					0: _awning(geo, f, c - h + SHOP_AWNING_IN, c + h - SHOP_AWNING_IN, float(SHOP_AWNINGS[0][0]), float(SHOP_AWNINGS[0][1]), float(SHOP_AWNINGS[0][2]), col, col.darkened(0.25))
					1: _slab(geo, f, c - h + SHOP_AWNING_IN, c + h - SHOP_AWNING_IN, float(SHOP_AWNINGS[1][1]), float(SHOP_AWNINGS[1][0]), float(SHOP_AWNINGS[1][2]), col)
					_: _awning(geo, f, c - h + SHOP_AWNING_IN, c + h - SHOP_AWNING_IN, float(SHOP_AWNINGS[2][0]), float(SHOP_AWNINGS[2][1]), float(SHOP_AWNINGS[2][2]), col, col.darkened(0.25))
				_slab(geo, f, c - h + 0.5, c + h - 0.5, 3.5, 4.3, 0.12, fascia)
				_punched(geo, f, FH, PackedFloat32Array([c - h * 0.45, c + h * 0.45]), 0.65, 1.2, 2.5, _c("glass_teal"), trim)
			for k in bays.size() + 1:
				var u := 0.3 + float(k) * pitch
				_slab(geo, f, u - 0.3, u + 0.3, -0.5, 3.3, 0.15, trim)
			_slab(geo, f, f.w * 0.3, f.w * 0.7, roof + 0.6, roof + 1.3, 0.2, trim)
			if _corner >= 0 and f.side == _corner:
				# A corner entrance on a corner lot: a door on the side street right by the corner, and a blade sign over it.
				var at_hi := _corner_at_high_u(f.side, int(b["front"]))
				var u0 := f.w - 1.9 if at_hi else 0.75
				_pane(geo, f, u0, u0 + 1.15, 0.0, 2.6, _c("glass_dark"), 0.09)
				var ub := f.w - 0.35 if at_hi else 0.35
				_slab(geo, f, ub - 0.08, ub + 0.08, SHOP_BLADE_V0, SHOP_BLADE_V1, SHOP_BLADE_D, _pick(_vr, fascias))
		else:
			_punched(geo, f, FH, _bays(f.w, 5.0, 1.0), 0.6, 1.2, 2.4, _c("glass_teal"), trim)
	_band(geo, faces, roof - 0.2, roof + 0.6, 0.2, trim)
	_roof(geo, xf, b, main, rng, ["ac", "skylight", "vent"])


# --- 5. Civic hall ---------------------------------------------------------------------------------------

static func _civic(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, _rng: RandomNumberGenerator) -> void:
	var stone := _c("cream")
	var wall := _c("sand")
	var plinth: Dictionary = b["tiers"][0]
	var hall: Dictionary = b["tiers"][1]
	var roof: float = b["roof_h"]
	var front: int = b["front"]
	_body(geo, xf, plinth, _c("concrete"), stone)
	_body(geo, xf, hall, wall, _c("blue_grey"))
	# Everything solid on the portico is plan data (solids, the entablature tier, the gable): drawn from it here, made
	# solid from the same numbers by CityDistrict.
	var back_face: int = [CityGeo.NX, CityGeo.PX, CityGeo.NZ, CityGeo.PZ][front]
	var col_top := roof - 1.2
	for so: Dictionary in b["solids"]:
		var off: Vector2 = so["off"]
		var sz: Vector2 = so["size"]
		match str(so["kind"]):
			"step":      # down from the plinth on the front (its back is inside the plinth)
				geo.box(xf, Vector3(off.x, (float(so["y0"]) + float(so["y1"])) * 0.5, off.y),
						Vector3(sz.x, float(so["y1"]) - float(so["y0"]), sz.y), stone, CityGeo.ALL - back_face)
			"column":
				var at := Vector3(off.x, float(so["y0"]), off.y)
				geo.box(xf, at + Vector3(0, 0.2, 0), Vector3(1.6, 0.4, 1.6), stone, CityGeo.NO_BOTTOM)
				geo.prism(xf, at + Vector3(0, 0.4, 0), 0.6, float(so["y1"]) - float(so["y0"]) - 0.8, 8, stone, 0.52)
				geo.box(xf, Vector3(off.x, float(so["y1"]) - 0.2, off.y), Vector3(1.6, 0.4, 1.6), stone)
	for t: Dictionary in b["tiers"]:
		if str(t.get("kind", "")) == "entablature":
			geo.box(xf, Vector3((t["off"] as Vector2).x, (float(t["y0"]) + float(t["y1"])) * 0.5, (t["off"] as Vector2).y),
					Vector3((t["size"] as Vector2).x, float(t["y1"]) - float(t["y0"]), (t["size"] as Vector2).y), stone)
	var g: Dictionary = b["gable"]
	var gx := gable_frame(xf, g)
	geo.gable(gx, Vector3.ZERO, float(g["w"]), float(g["d"]), float(g["rise"]), _c("blue_grey"), stone, stone)
	# Walls: tall windows between pilasters; a big door behind the columns.
	for f in _faces(xf, hall, lot):
		var bays := _bays(f.w, 3.8, 1.2)
		var pitch := _pitch(f.w, 3.8, 1.2)
		for k in bays.size():
			var c := bays[k]
			if f.side == front and k == bays.size() / 2:
				_pane(geo, f, c - 1.5, c + 1.5, 1.2, 6.2, _c("glass_dark"))
			else:
				_pane(geo, f, c - 0.75, c + 0.75, 3.0, col_top - 1.6, _c("glass_teal"))
				_slab(geo, f, c - 0.9, c + 0.9, 2.84, 3.0, 0.2, stone)
		for k in bays.size() + 1:
			var u := 1.2 + float(k) * pitch
			_slab(geo, f, u - 0.35, u + 0.35, 1.2, col_top, 0.25, stone)


## The frame a civic gable is built in: origin at the middle of its eaves rectangle, +Z toward the front (the ridge).
static func gable_frame(xf: Transform3D, g: Dictionary) -> Transform3D:
	var n2: Vector2 = CityPlan.SIDE_N[int(g["front"])]
	var n := Vector3(n2.x, 0.0, n2.y)
	return xf * Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), Vector3((g["off"] as Vector2).x, float(g["y0"]), (g["off"] as Vector2).y))


# --- 6. Pillars ------------------------------------------------------------------------------------------
# A pillar is structure first: its core stands on the radial line it shares with every other deck (`core_xf`), and a
# tower's podium (the building, `xf`) only wraps it. See docs/design/ceiling-and-pillars.md.

static func _pillar(geo: CityGeo, xf: Transform3D, core_xf: Transform3D, b: Dictionary, lot: Dictionary,
		rng: RandomNumberGenerator, ceiling: float) -> void:
	var stone := _c("concrete")
	var glass := _pick(rng, ["sky_blue", "glass_blue"])
	var core: Dictionary = b["core"]
	var lift: bool = core["kind"] == "lift"
	var y0 := 0.0
	if not (b["tiers"] as Array).is_empty():
		var podium: Dictionary = b["tiers"][0]
		_body(geo, xf, podium, _c("glass_teal"), _c("roof"))
		_grid_facade(geo, _faces(xf, podium, lot), _c("cream"), _c("sand"), 3.6)
		y0 = podium["y1"]
	var shaft := {"off": Vector2.ZERO, "size": core["size"], "y0": 0.0, "y1": ceiling + 1.0}
	_body(geo, core_xf, shaft, stone, stone)
	var flare := ceiling - 7.5
	for f in _faces(core_xf, shaft, lot):
		var door := lift and f.side == int(b["front"])
		var bays := _bays(f.w, 3.4, 0.9)
		var pitch := _pitch(f.w, 3.4, 0.9)
		var lo := y0 + 0.8 if not lift else 9.0
		for c in bays:
			_pane(geo, f, c - pitch * 0.5 + 0.45, c + pitch * 0.5 - 0.45, lo, flare - 0.6, glass)
		# Pilasters and the lift's channel stop under the capital's collar (flare - 0.8 .. flare, 0.8 m proud: it covers
		# them): run up to `flare`, their tops lay in the collar's top face (z-fighting, tools/geometry_audit/).
		var under := flare - CAPITAL_COLLAR
		for k in bays.size() + 1:
			var u := 0.9 + float(k) * pitch
			_slab(geo, f, u - 0.45, u + 0.45, y0 - (0.5 if y0 <= 0.0 else 0.0), under, 0.5, stone)
		var y := maxf(y0, 6.5) + FH * 2.0
		while y < flare - 2.0:
			_slab(geo, f, 0.0, f.w, y - 0.3, y + 0.3, 0.22, _c("concrete_dark"))
			y += FH * 2.0
		if door:
			# The freight lift: a mech-sized door in a hazard frame, and the guide channel running up the shaft.
			var m := f.w * 0.5
			_pane(geo, f, m - 5.0, m + 5.0, 0.0, 8.0, _c("metal_dark"), 0.56)
			_slab(geo, f, m - 5.8, m - 5.0, -0.5, 8.8, 0.7, _c("tactile"))
			_slab(geo, f, m + 5.0, m + 5.8, -0.5, 8.8, 0.7, _c("tactile"))
			_slab(geo, f, m - 5.8, m + 5.8, 8.0, 8.8, 0.7, _c("tactile"))
			_slab(geo, f, m - 1.8, m + 1.8, 8.8, under, 0.62, _c("sage_dark"))
	capital(geo, core_xf, (core["size"] as Vector2) * 0.5, ceiling, stone)
	if not (b["tiers"] as Array).is_empty():
		_roof(geo, xf, b, b["tiers"][0], rng, ["planter", "ac"])


const CAPITAL_COLLAR := 0.8     ## the collar under a pillar's capital: this tall, 0.8 m proud of the core's faces


## How a pillar meets the ceiling: a collar, a flare, and a drop panel (a thickened patch of the deck above) that the
## ceiling's girders die into.
## `collar` / `proud`: the collar's height and how far it stands out (downtown towers wear a bigger one, readable from
## the street: DT_COLLAR / DT_COLLAR_PROUD).
static func capital(geo: CityGeo, xf: Transform3D, half: Vector2, ceiling: float, col: Color,
		collar: float = CAPITAL_COLLAR, proud: float = 0.8) -> void:
	var flare := ceiling - 7.5
	var pad := CityStreets.DROP_PANEL
	geo.box(xf, Vector3(0, flare - collar * 0.5, 0), Vector3(half.x * 2.0 + proud * 2.0, collar, half.y * 2.0 + proud * 2.0), _c("concrete_dark"))
	geo.frustum(xf, Vector3.ZERO, flare, half + Vector2(0.5, 0.5), ceiling - 1.4, half + Vector2(pad - 1.0, pad - 1.0), col)
	geo.box(xf, Vector3(0, ceiling - 0.6, 0), Vector3((half.x + pad) * 2.0, 1.8, (half.y + pad) * 2.0), _c("rib"), CityGeo.ALL - CityGeo.PY)


# --- 7. Downtown towers (docs/design/city-downtown.md) ----------------------------------------------------
# One family on varied bases: the same two frame tones (cream frame, sand trim), sky-blue glass, the same band line every
# two storeys and the same big collar, flare and drop panel (capital) on both members. The SLAB (broad) reads horizontal:
# a deep spandrel every storey over ribbon glazing, shallow piers every 3.2 m, solid end piers. The POINT (slender) reads
# vertical: deep corner piers and a centre fin running full height between two glass strips a face; its band line rings
# only the piers and the fin, so the strips stay unbroken. Bases tell themselves apart at eye level within the palette:
# a shop podium with awnings, a stepped podium in sand with a terrace rail, a corner podium in a teal glass curtain, the
# arcade's columns in the frame tone. Bases (podium, terrace, the arcade's lobby and roof, its columns) are plan tiers and
# solids, drawn from the numbers the collision is made from. Coarse on purpose (the zone's triangle budget).

const DT_COLLAR := 1.6          ## a tower's collar under its capital: this tall
const DT_COLLAR_PROUD := 1.3    ## and this far proud of the shaft's faces
const DT_PIER := 1.1            ## a point's glass is this far behind its plan line: its corner piers and fin stand flush
const DT_SPANDREL := 0.45       ## a slab's glass is this far behind: its spandrels and end piers flush, its piers less
const DT_SLAB_PIER := 0.2


static func _tower(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator, ceiling: float) -> void:
	# The district stream is drawn as in pass 1 (four picks), so no other building's looks move; the family's tones are fixed.
	_pick(rng, ["cream", "cream", "sand", "cream_light"])
	_pick(rng, ["sky_blue", "sky_blue", "glass_blue"])
	var shop := _pick(rng, ["glass_dark", "glass_teal"])
	var frame := _c("cream_light") if _vr.randf() < 0.35 else _c("cream")
	var trim := _c("sand")
	var glass := _c("sky_blue")
	var dt: Dictionary = b["dt"]
	var base := str(b.get("base", "podium"))
	for t: Dictionary in b["tiers"]:
		match str(t.get("kind", "")):
			"podium", "terrace":
				_dt_block(geo, xf, t, lot, base, frame, trim, glass, shop)
			"arcade":
				_dt_block(geo, xf, t, lot, base, frame, trim, glass, shop)
				if dt.has("gallery_frame"):      # the gallery's ceiling, seen from under the arcade
					var g: Rect2 = dt["gallery_frame"]
					geo.box(xf, Vector3(g.get_center().x, float(t["y0"]) - 0.05, g.get_center().y), Vector3(g.size.x, 0.1, g.size.y),
							_c("concrete"), CityGeo.NY)
			"lobby":
				_dt_lobby(geo, xf, t, lot, int(dt.get("front", -1)), frame, trim, glass, shop)
			"tower":
				_dt_shaft(geo, xf, t, lot, b, frame, trim, glass, shop, ceiling)
	for so: Dictionary in b.get("solids", []):
		if so["kind"] == "column":
			var off: Vector2 = so["off"]
			var top := float(so["y1"]) - 0.1          # under the gallery's ceiling
			geo.box(xf, Vector3(off.x, (top - 0.5) * 0.5, off.y), Vector3(DT_COL, top + 0.5, DT_COL), frame, CityGeo.NO_BOTTOM)
			geo.box(xf, Vector3(off.x, 0.25, off.y), Vector3(DT_COL + 0.5, 0.5, DT_COL + 0.5), trim, CityGeo.NO_BOTTOM)
			geo.box(xf, Vector3(off.x, top - 0.25, off.y), Vector3(DT_COL + 0.5, 0.5, DT_COL + 0.5), trim, CityGeo.ALL - CityGeo.PY)


const DT_COL := CityPlan.DT_COLUMN


## A podium or terrace box, its face by base kind (city-downtown.md pass 2): a shop podium (podium, twin) has shop fronts
## and awnings on its street faces; a stepped podium is sand with a stone base course and tall windows, and a rail round
## its terrace's street edges; a corner podium wears a teal glass curtain; others a ribbon window a storey. Floor bands
## and a cornice standing a little above the roof on all.
static func _dt_block(geo: CityGeo, xf: Transform3D, t: Dictionary, lot: Dictionary, base: String, frame: Color, trim: Color,
		glass: Color, shop: Color) -> void:
	var y0 := float(t["y0"])
	var y1 := float(t["y1"])
	var terrace := str(t.get("kind", "")) == "terrace"
	# A stepped podium is sand; its terrace stays in the frame tone (its sides lie in the shaft's corner piers' faces).
	var wall := frame
	if base == "stepped" and not terrace:
		wall = trim
	_body(geo, xf, t, wall, _c("roof"))
	var floors := maxi(int(round((y1 - y0) / FH)), 1)
	var awning := _c(["awning_teal", "awning_sky", "awning_cream"][_vr.randi_range(0, 2)])
	for f in _faces(xf, t, lot):
		if f.w < 3.0:
			continue
		if base == "corner" and not terrace:
			# A glass curtain: full-storey teal panes between slim frame mullions.
			var bays := _bays(f.w, 2.6, 0.3)
			var pitch := _pitch(f.w, 2.6, 0.3)
			_pane(geo, f, 0.3, f.w - 0.3, y0 + 0.4 if y0 > 0.0 else 0.2, y1 - 0.6, _c("glass_teal"))
			for k in bays.size() + 1:
				var u := 0.3 + float(k) * pitch
				_slab(geo, f, u - 0.12, u + 0.12, y0 - (0.5 if y0 <= 0.0 else 0.0), y1 - 0.45, 0.14, frame)
		for i in floors:
			var y := y0 + float(i) * FH
			if base == "corner" and not terrace:
				pass
			elif y0 <= 0.0 and i == 0 and f.street and base != "stepped":
				var bays := _bays(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
				var pitch := _pitch(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
				for c in bays:
					_pane(geo, f, c - pitch * 0.5 + 0.4, c + pitch * 0.5 - 0.4, 0.3, FH - 0.5, shop)
					if base == "podium" or base == "twin":
						_awning(geo, f, c - pitch * 0.5 + DT_AWNING_IN, c + pitch * 0.5 - DT_AWNING_IN, FH - 0.55, FH - 1.15, DT_AWNING_D, awning, awning.darkened(0.25))
				for k in bays.size() + 1:
					var u := 0.4 + float(k) * pitch
					_slab(geo, f, u - 0.25, u + 0.25, -0.5, FH - 0.25, 0.15, trim)
			elif base == "stepped":
				# Tall windows over a stone base course.
				if y0 <= 0.0 and i == 0:
					_slab(geo, f, -0.1, f.w + 0.1, -0.5, 1.2, 0.1, _c("concrete"))
				var bays := _bays(f.w, 2.8, 0.6)
				for c in bays:
					_pane(geo, f, c - 0.75, c + 0.75, y + (1.4 if y0 <= 0.0 and i == 0 else 0.6), y + FH - 0.5, glass)
			else:
				_pane(geo, f, 0.7, f.w - 0.7, y + 0.85, y + FH - 0.6, glass)
			if i > 0:
				# Wrapping the corners (its ends clear of the side walls' faces, z-fight audit).
				var bd := 0.2 if base == "corner" and not terrace else 0.12
				_slab(geo, f, -bd, f.w + bd, y - 0.18, y + 0.18, bd, trim if base != "stepped" or terrace else frame)
		_slab(geo, f, -0.2, f.w + 0.2, y1 - 0.45, y1 + 0.45, 0.2, trim if base != "stepped" or terrace else frame)
		if terrace and f.street:
			# The terrace rail: posts and a top bar on its street edge, set in from the cornice.
			var n := maxi(int(f.w / 2.5), 1)
			for k in n + 1:
				var u := 0.6 + (f.w - 1.2) * float(k) / float(n)
				geo.box(f.xf, Vector3(u, y1 + 0.7, -0.55), Vector3(0.12, 1.6, 0.12), _c("metal_dark"), CityGeo.NO_BOTTOM)
			geo.box(f.xf, Vector3(f.w * 0.5, y1 + 1.55, -0.55), Vector3(f.w - 1.0, 0.14, 0.16), _c("metal_dark"))


## An arcade's lobby behind its gallery: glass across the gallery side, ribbon windows elsewhere (no cornice: the arcade's
## roof sits on it).
static func _dt_lobby(geo: CityGeo, xf: Transform3D, t: Dictionary, lot: Dictionary, front: int, frame: Color, trim: Color, glass: Color, shop: Color) -> void:
	_body(geo, xf, t, frame, frame)
	var y1 := float(t["y1"])
	for f in _faces(xf, t, lot):
		if f.w < 3.0:
			continue
		if f.side == front:
			var bays := _bays(f.w, 6.0, 0.4)
			var pitch := _pitch(f.w, 6.0, 0.4)
			for c in bays:
				_pane(geo, f, c - pitch * 0.5 + 0.4, c + pitch * 0.5 - 0.4, 0.3, y1 - 1.2, shop)
			for k in bays.size() + 1:
				var u := 0.4 + float(k) * pitch
				_slab(geo, f, u - 0.25, u + 0.25, -0.5, y1 - 0.9, 0.15, trim)
			_slab(geo, f, 0.0, f.w, y1 - 0.9, y1 - 0.5, 0.15, trim)
		else:
			var floors := maxi(int(round(y1 / FH)), 1)
			for i in floors:
				_pane(geo, f, 0.7, f.w - 0.7, float(i) * FH + 0.85, float(i + 1) * FH - 0.6, glass)


## The first band height at or above y0 + 2 (bands sit at odd storey lines, clear of the 6.5 / 13 m roofs and cornices).
static func _dt_first_band(y0: float) -> float:
	var y := FH
	while y < maxf(y0, 5.0) + 2.0:
		y += FH * 2.0
	return y


## A tower shaft: its glass recessed behind the plan line (DT_PIER / DT_SPANDREL: the frame stands flush with the
## collision box), the family's frame over it, the collar and flare.
static func _dt_shaft(geo: CityGeo, xf: Transform3D, t: Dictionary, lot: Dictionary, b: Dictionary, frame: Color, trim: Color,
		glass: Color, shop: Color, ceiling: float) -> void:
	var size: Vector2 = t["size"]
	var off: Vector2 = t["off"]
	var y0 := float(t["y0"])
	var flare := ceiling - 7.5
	var under := flare - DT_COLLAR
	var slab := str(t.get("tower", "point")) == "slab"
	var recess := DT_SPANDREL if slab else DT_PIER
	var inner := t.duplicate()
	inner["size"] = size - Vector2(recess, recess) * 2.0
	_body(geo, xf, inner, glass, glass)
	var v0 := y0 - (0.5 if y0 <= 0.0 else 0.0)
	var fin0 := 5.0 if y0 <= 0.0 else v0          # a ground lobby keeps its glass clear of the centre fin
	var first := _dt_first_band(y0)
	# Corner piers on both members: one box a corner, flush with the plan line, deep on a point and solid on a slab; the
	# band line rings it every two storeys.
	var corner := minf(1.8, minf(size.x, size.y) * 0.18) if not slab else 0.9
	var w := corner + recess
	for cx: float in [-1.0, 1.0]:
		for cz: float in [-1.0, 1.0]:
			var c := Vector2(off.x + cx * (size.x - w) * 0.5, off.y + cz * (size.y - w) * 0.5)
			geo.box(xf, Vector3(c.x, (v0 + under) * 0.5, c.y), Vector3(w, under - v0, w), frame, CityGeo.NO_BOTTOM)
			var y := first
			while y < under - 1.5:
				geo.box(xf, Vector3(c.x, y, c.y), Vector3(w + 0.24, 0.34, w + 0.24), trim)
				y += FH * 2.0
	for f in _faces(xf, inner, lot):
		if slab:
			# Shallow piers, a deep spandrel every storey (flush), the band line on every second storey line.
			var pitch := _pitch(f.w, 3.2, 0.0)
			var n := int(round(f.w / pitch))
			for k in range(1, n):
				var u := float(k) * pitch
				_slab(geo, f, u - 0.22, u + 0.22, v0, under, DT_SLAB_PIER, frame)
			var y := first - FH
			var k2 := 0
			while y < under - 1.5:
				if y > y0 + 1.0:
					_slab(geo, f, 0.35, f.w - 0.35, y - 0.5, y + 0.5, recess, frame)
					if k2 % 2 == 1:
						_slab(geo, f, 0.25, f.w - 0.25, y - 0.17, y + 0.17, recess + 0.12, trim)
				y += FH
				k2 += 1
		elif f.w >= 6.0:
			# The centre fin, flush, between two full-height glass strips; the band line rings it.
			_slab(geo, f, f.w * 0.5 - 0.4, f.w * 0.5 + 0.4, fin0, under, recess, frame)
			var y := first
			while y < under - 1.5:
				if y > fin0 + 0.5:
					_slab(geo, f, f.w * 0.5 - 0.52, f.w * 0.5 + 0.52, y - 0.17, y + 0.17, recess + 0.12, trim)
				y += FH * 2.0
		if y0 <= 0.0 and f.side == int(b["front"]):
			# A lobby at the plaza: dark glass and a canopy over the door.
			var inset := maxf(corner - recess, 0.3)
			if not slab:
				_pane(geo, f, inset + 0.3, f.w - inset - 0.3, 0.0, 4.2, shop, 0.06)
			_slab(geo, f, inset + 0.2, f.w - inset - 0.2, DT_CANOPY_V0, DT_CANOPY_V1, recess + DT_CANOPY_D, trim)
	capital(geo, xf * Transform3D(Basis.IDENTITY, Vector3(off.x, 0.0, off.y)), size * 0.5, ceiling, frame, DT_COLLAR, DT_COLLAR_PROUD)

## A park pillar: a slim trunk that branches into the ceiling like a tree, standing in a planted ring.
static func column(geo: CityGeo, xf: Transform3D, c: Dictionary, ceiling: float) -> void:
	var r := float(c["half"])
	var split := ceiling - 10.0
	var ring_r := float(c.get("ring_r", r + 1.6))     # plan data (solid: CityDistrict builds the same prism)
	geo.prism(xf, Vector3(0, -1.0, 0), ring_r, float(c.get("ring_h", 0.7)) + 1.0, 8, _c("cream_light"), ring_r, _c("leaf"))
	geo.prism(xf, Vector3(0, -1.0, 0), r, split + 1.0, 8, _c("cream"), r * 0.8)
	geo.prism(xf, Vector3(0, split, 0), r * 0.8, 10.0 - 1.2, 8, _c("cream"), 6.0)
	geo.prism(xf, Vector3(0, ceiling - 1.2, 0), 7.0, 1.6, 8, _c("rib"), 7.0, null, _c("rib"))
