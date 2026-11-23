class_name CityBuildings
extends RefCounted
## Turns one planned building into flat-shaded geometry, per style (docs/design/city-styles.md). Works in the building's
## own flat frame (x across, y up, z along the deck), so it knows nothing about the ring: the caller passes the frame.
## All detail is real geometry in palette colours (window panes, sills, piers, ledges, balconies, awnings, roof units).
## Colour choices come from the caller's COSMETIC generator: nothing here changes what you can stand on. Everything solid
## (tiers, the office plant room, skylights, the civic portico and gable) is drawn from plan data, the same data the
## collision is built from; loose roof units are CityProps (their prototypes are roof_unit()).

const FH := CityPlan.FLOOR_H


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
	match str(b["style"]):
		"apartment": _apartment(geo, xf, b, lot, rng)
		"office": _office(geo, xf, b, lot, rng)
		"sage": _sage(geo, xf, b, lot, rng)
		"shops": _shops(geo, xf, b, lot, rng)
		"civic": _civic(geo, xf, b, lot, rng)
		"pillar": _pillar(geo, xf, core_xf, b, lot, rng, plan.p("ceiling"))
		"tower": _tower(geo, xf, b, lot, rng, plan.p("ceiling"))


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
	var main: Dictionary = b["tiers"][0]
	var floors: int = b["floors"]
	var roof: float = b["roof_h"]
	_body(geo, xf, main, wall, _c("roof"))
	var faces := _faces(xf, main, lot)
	var phase := rng.randi_range(0, 1)
	for f in faces:
		var bays := _bays(f.w, 3.4, 1.0)
		_slab(geo, f, -0.12, f.w + 0.12, -0.5, FH, 0.12, base)
		var door := bays.size() / 2
		for k in bays.size():
			var c := bays[k]
			if f.street and f.side == int(b["front"]) and k == door:
				_pane(geo, f, c - 0.9, c + 0.9, 0.05, 2.5, _c("glass_dark"), 0.17)
				_slab(geo, f, c - 1.6, c + 1.6, 2.7, 2.95, 1.3, trim)
			elif f.street:
				_pane(geo, f, c - 1.15, c + 1.15, 0.85, 2.55, glass, 0.17)
			else:
				_pane(geo, f, c - 0.6, c + 0.6, 1.3, 2.4, glass, 0.17)
		var with_balconies := (f.side / 2 == int(b["front"]) / 2) and bays.size() >= 2
		for i in range(1, floors):
			var y := float(i) * FH
			for k in bays.size():
				var c := bays[k]
				if with_balconies and (k + phase) % 2 == 0:
					_pane(geo, f, c - 0.65, c + 0.65, y + 0.1, y + 2.35, glass)
					_slab(geo, f, c - 1.3, c + 1.3, y - 0.12, y + 1.05, 1.1, balcony)
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
			_slab(geo, f, f.w * 0.5 - 3.2, f.w * 0.5 + 3.2, 3.0, 3.35, 2.2, accent)
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
				_slab(geo, f, f.w * 0.5 - 2.4, f.w * 0.5 + 2.4, 2.85, 3.1, 1.6, ledge)
	# Roof garden on the main roof, units on the penthouse.
	_roof(geo, xf, b, tiers[0], rng, ["planter", "planter", "skylight"] if tiers.size() == 1 else ["planter"])
	if tiers.size() > 1:
		_roof(geo, xf, b, tiers[1], rng, ["ac", "vent"])


# --- 4. Shop rows ----------------------------------------------------------------------------------------

static func _shops(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator) -> void:
	var wall := _pick(rng, ["cream", "cream_light", "terracotta_light", "sage_light", "sky_blue", "sand"])
	var trim := _c("cream_light") if wall != _c("cream_light") else _c("sand")
	var main: Dictionary = b["tiers"][0]
	var roof: float = b["roof_h"]
	_body(geo, xf, main, wall, _c("roof"))
	var faces := _faces(xf, main, lot)
	var awnings := ["terracotta", "sage_dark", "sky_blue", "marking_yellow", "terracotta_dark", "cream_light"]
	for f in faces:
		if f.street:
			var bays := _bays(f.w, 5.6, 0.3)
			var pitch := _pitch(f.w, 5.6, 0.3)
			for k in bays.size():
				var c := bays[k]
				var h := pitch * 0.5
				var col := _pick(rng, awnings)
				_pane(geo, f, c - h + 0.45, c + h - 0.45, 0.55, 3.0, _c("glass_dark"))
				_pane(geo, f, c + h - 1.9, c + h - 0.75, 0.0, 2.6, _c("glass_teal"), 0.07)
				# 2 cm clear of the pilasters (u +/- 0.3): its double-sided end gussets lay in their side faces (z-fighting).
				_awning(geo, f, c - h + 0.32, c + h - 0.32, 3.3, 2.75, 1.5, col, col.darkened(0.25))
				_slab(geo, f, c - h + 0.5, c + h - 0.5, 3.5, 4.3, 0.12, _pick(rng, ["cream_light", "sage", "terracotta", "blue_grey"]))
				_punched(geo, f, FH, PackedFloat32Array([c - h * 0.45, c + h * 0.45]), 0.65, 1.2, 2.5, _c("glass_teal"), trim)
			for k in bays.size() + 1:
				var u := 0.3 + float(k) * pitch
				_slab(geo, f, u - 0.3, u + 0.3, -0.5, 3.3, 0.15, trim)
			_slab(geo, f, f.w * 0.3, f.w * 0.7, roof + 0.6, roof + 1.3, 0.2, trim)
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
static func capital(geo: CityGeo, xf: Transform3D, half: Vector2, ceiling: float, col: Color) -> void:
	var flare := ceiling - 7.5
	var pad := CityStreets.DROP_PANEL
	geo.box(xf, Vector3(0, flare - CAPITAL_COLLAR * 0.5, 0), Vector3(half.x * 2.0 + 1.6, CAPITAL_COLLAR, half.y * 2.0 + 1.6), _c("concrete_dark"))
	geo.frustum(xf, Vector3.ZERO, flare, half + Vector2(0.5, 0.5), ceiling - 1.4, half + Vector2(pad - 1.0, pad - 1.0), col)
	geo.box(xf, Vector3(0, ceiling - 0.6, 0), Vector3((half.x + pad) * 2.0, 1.8, (half.y + pad) * 2.0), _c("rib"), CityGeo.ALL - CityGeo.PY)


# --- 7. Downtown towers (docs/design/city-downtown.md) ----------------------------------------------------
# One family on varied bases: cream / sand frame, sky-blue glass. A slab (broad) has piers every 3.2 m and a spandrel
# every two storeys over ribbon glazing; a point (slender) has broad corner piers, a centre fin and two tall glass strips
# a face, a band line every two storeys. Every shaft ends in the pillars' collar, flare and drop panel (capital). Bases
# (podium, terrace, the arcade's lobby and roof, its columns) are plan tiers and solids, drawn from the numbers the
# collision is made from. Coarse on purpose (the zone's triangle budget).

static func _tower(geo: CityGeo, xf: Transform3D, b: Dictionary, lot: Dictionary, rng: RandomNumberGenerator, ceiling: float) -> void:
	var frame := _pick(rng, ["cream", "cream", "sand", "cream_light"])
	var trim := _c("cream_light") if frame != _c("cream_light") else _c("sand")
	var glass := _pick(rng, ["sky_blue", "sky_blue", "glass_blue"])
	var shop := _pick(rng, ["glass_dark", "glass_teal"])
	var dt: Dictionary = b["dt"]
	for t: Dictionary in b["tiers"]:
		match str(t.get("kind", "")):
			"podium", "terrace":
				_dt_block(geo, xf, t, lot, frame, trim, glass, shop)
			"arcade":
				_dt_block(geo, xf, t, lot, frame, trim, glass, shop)
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


## A podium or terrace box: shop fronts on a podium's street faces, a ribbon window a storey elsewhere, floor bands and
## a cornice standing a little above the roof.
static func _dt_block(geo: CityGeo, xf: Transform3D, t: Dictionary, lot: Dictionary, frame: Color, trim: Color, glass: Color, shop: Color) -> void:
	_body(geo, xf, t, frame, _c("roof"))
	var y0 := float(t["y0"])
	var y1 := float(t["y1"])
	var floors := maxi(int(round((y1 - y0) / FH)), 1)
	for f in _faces(xf, t, lot):
		if f.w < 3.0:
			continue
		for i in floors:
			var y := y0 + float(i) * FH
			if y0 <= 0.0 and i == 0 and f.street:
				var bays := _bays(f.w, 5.2, 0.4)
				var pitch := _pitch(f.w, 5.2, 0.4)
				for c in bays:
					_pane(geo, f, c - pitch * 0.5 + 0.4, c + pitch * 0.5 - 0.4, 0.3, FH - 0.5, shop)
				for k in bays.size() + 1:
					var u := 0.4 + float(k) * pitch
					_slab(geo, f, u - 0.25, u + 0.25, -0.5, FH - 0.25, 0.15, trim)
			else:
				_pane(geo, f, 0.7, f.w - 0.7, y + 0.85, y + FH - 0.6, glass)
			if i > 0:
				_slab(geo, f, 0.0, f.w, y - 0.18, y + 0.18, 0.12, trim)
		_slab(geo, f, -0.2, f.w + 0.2, y1 - 0.45, y1 + 0.45, 0.2, trim)


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


## A tower shaft: glass box from its base into the ceiling slab, the family's frame over it, the collar and flare.
static func _dt_shaft(geo: CityGeo, xf: Transform3D, t: Dictionary, lot: Dictionary, b: Dictionary, frame: Color, trim: Color,
		glass: Color, shop: Color, ceiling: float) -> void:
	var size: Vector2 = t["size"]
	var off: Vector2 = t["off"]
	var y0 := float(t["y0"])
	var flare := ceiling - 7.5
	var under := flare - CAPITAL_COLLAR
	_body(geo, xf, t, glass, glass)
	var slab := str(t.get("tower", "point")) == "slab"
	var v0 := y0 - (0.5 if y0 <= 0.0 else 0.0)
	var fin0 := 5.0 if y0 <= 0.0 else v0          # a ground lobby keeps its glass clear of the centre fin
	for f in _faces(xf, t, lot):
		var corner := minf(1.6, f.w * 0.16)
		if slab:
			var pitch := _pitch(f.w, 3.2, 0.0)
			var n := int(round(f.w / pitch))
			for k in n + 1:
				var u := float(k) * pitch
				var a := u - 0.3
				var c := u + 0.3
				if k == 0:
					a = -0.35
					c = 0.6
				if k == n:
					a = f.w - 0.6
					c = f.w + 0.35
				_slab(geo, f, a, c, v0, under, 0.35, frame)
			var y := _dt_first_band(y0)
			while y < under - 1.5:
				_slab(geo, f, 0.0, f.w, y - 0.5, y + 0.5, 0.2, frame)
				y += FH * 2.0
		else:
			_slab(geo, f, -0.5, corner, v0, under, 0.5, frame)
			_slab(geo, f, f.w - corner, f.w + 0.5, v0, under, 0.5, frame)
			if f.w >= 10.0:
				_slab(geo, f, f.w * 0.5 - 0.35, f.w * 0.5 + 0.35, fin0, under, 0.45, frame)
			var y := _dt_first_band(y0)
			while y < under - 1.5:
				_slab(geo, f, corner, f.w - corner, y - 0.16, y + 0.16, 0.12, trim)
				y += FH * 2.0
		if y0 <= 0.0 and f.side == int(b["front"]):
			# A lobby at the plaza: dark glass and a canopy over the door.
			if not slab:
				_pane(geo, f, corner + 0.3, f.w - corner - 0.3, 0.0, 4.2, shop, 0.06)
			_slab(geo, f, corner + 0.2, f.w - corner - 0.2, 4.4, 4.8, 2.0, trim)
	capital(geo, xf * Transform3D(Basis.IDENTITY, Vector3(off.x, 0.0, off.y)), size * 0.5, ceiling, frame)


## A park pillar: a slim trunk that branches into the ceiling like a tree, standing in a planted ring.
static func column(geo: CityGeo, xf: Transform3D, c: Dictionary, ceiling: float) -> void:
	var r := float(c["half"])
	var split := ceiling - 10.0
	var ring_r := float(c.get("ring_r", r + 1.6))     # plan data (solid: CityDistrict builds the same prism)
	geo.prism(xf, Vector3(0, -1.0, 0), ring_r, float(c.get("ring_h", 0.7)) + 1.0, 8, _c("cream_light"), ring_r, _c("leaf"))
	geo.prism(xf, Vector3(0, -1.0, 0), r, split + 1.0, 8, _c("cream"), r * 0.8)
	geo.prism(xf, Vector3(0, split, 0), r * 0.8, 10.0 - 1.2, 8, _c("cream"), 6.0)
	geo.prism(xf, Vector3(0, ceiling - 1.2, 0), 7.0, 1.6, 8, _c("rib"), 7.0, null, _c("rib"))
