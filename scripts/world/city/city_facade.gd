class_name CityFacade
extends RefCounted
## A building's faces and what stands out of them, from plan data alone: the Face frame of each wall of a tier (faces_of()),
## bay spacing (bay_centres / bay_pitch), corner lots, and the facade relief (relief(), face_coords(): balconies, canopies, awnings,
## blade signs, alley pipes, lane signs; docs/design/banners.md "Clear of the facade"). Plan-side geometry shared by the
## mesher (CityBuildings draws with these numbers, so relief() and the drawn facade agree) and the planners that keep
## clear of a facade (BannerPlan). Pure: no nodes, no state, no randomness.

const FH := CityPlan.FLOOR_H
## The downtown tower glass setbacks (CityBuildings._tower draws them; relief() places a lobby canopy by them).
const DT_PIER := 1.1            ## a point's glass is this far behind its plan line: its corner piers and fin stand flush
const DT_SPANDREL := 0.45       ## a slab's glass is this far behind: its spandrels and end piers flush, its piers less


## Whether the end of a Face on side `face_side` at u = w lies toward side `other` (Face u = up x n).
static func corner_at_high_u(face_side: int, other: int) -> bool:
	var n: Vector2 = CityPlan.SIDE_N[face_side]
	var o: Vector2 = CityPlan.SIDE_N[other]
	return n.y * o.x - n.x * o.y > 0.0


## On a corner lot (its front and a neighbouring side both face a street): that neighbouring side, else -1.
static func corner_side(lot: Dictionary, front: int) -> int:
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


static func faces_of(xf: Transform3D, t: Dictionary, lot: Dictionary) -> Array[Face]:
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


## Bay centres across a wall of width w: as many bays of about `want` as fit between the margins.
static func bay_centres(w: float, want: float, margin: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := maxi(int(floor((w - margin * 2.0) / want)), 1)
	var pitch := (w - margin * 2.0) / float(n)
	for i in n:
		out.append(margin + pitch * (float(i) + 0.5))
	return out


static func bay_pitch(w: float, want: float, margin: float) -> float:
	return (w - margin * 2.0) / float(maxi(int(floor((w - margin * 2.0) / want)), 1))


# --- Facade relief (what stands out from a wall: docs/design/banners.md "Clear of the facade") --------------------
# The numbers below are the mesher's own (CityBuildings draws with these constants), so relief() and the drawn facade agree.
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
static func apt_balconied(b: Dictionary, side: int, n_bays: int) -> bool:
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
	var faces := faces_of(Transform3D.IDENTITY, t, lot)
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
				var bays := bay_centres(f.w, APT_BAY, APT_BAY_MARGIN)
				if f.street and f.side == front and bays.size() > 0:
					var c := bays[bays.size() / 2]
					add.call(f.side, c - APT_CANOPY_HALF, c + APT_CANOPY_HALF, APT_CANOPY_V0, APT_CANOPY_V1, APT_CANOPY_D)
				if apt_balconied(b, f.side, bays.size()):
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
				var bays := bay_centres(f.w, SHOP_BAY, SHOP_MARGIN)
				var h := bay_pitch(f.w, SHOP_BAY, SHOP_MARGIN) * 0.5
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
				var corner := corner_side(lot, front)
				if corner >= 0 and f.side == corner:
					var ub := f.w - 0.35 if corner_at_high_u(f.side, front) else 0.35
					add.call(f.side, ub - 0.08, ub + 0.08, SHOP_BLADE_V0, SHOP_BLADE_V1, SHOP_BLADE_D)
			"tower":
				var kind := str(t.get("kind", ""))
				var base := str(b.get("base", "podium"))
				if kind in ["podium", "terrace", "arcade"] and f.w >= 3.0 and float(t["y0"]) <= 0.0 and f.street \
						and (base == "podium" or base == "twin"):
					var bays := bay_centres(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
					var pitch := bay_pitch(f.w, DT_SHOP_BAY, DT_SHOP_MARGIN)
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
