class_name CitySigns
extends RefCounted
## Deck lettering (docs/design/city-signs.md): "DECK" + the deck's two-digit number, ONE sign above every boundary-wall
## gate / portal and every freight lift door, and a way-finding sign (arrow + the destination deck) at both ends of every
## ramp. Nothing beside doors, nothing over shafts or ceiling openings (user feedback 2026-11-25). Number = section deck
## index + 1 (the top deck, with the entry portal, is 01), as the mission HUD says.
##
## Cosmetic only: baked flat polygons drawn through CityGeo (one flat colour per face, no textures, no fonts, no Label3D),
## no collision, not in the plan checksum, not in CityDistrict.geometry_digest() or stats.triangles (its own
## stats.sign_triangles), no random draw. One MeshInstance3D "DeckSigns" per district (CityDistrict chunk "signs").
##
## Two looks (grid city-signs/grid_deck_signs.png; the user picked cell 6 on 2026-11-24 after seeing both in game):
##   "dark"   warm cream on a dark blue-grey panel with chamfered corners and a thin sky-blue stripe at the bottom (cell 6),
##            the game's look
##   "white"  bold stencil numerals painted on the wall in off-white with a thin dark outline (cell 4), lab only
##   "off"    nothing
## Where the surface is not a plain wall (a farm wall's racks, a lift core's pilasters, the air over a ramp), both
## looks stand on the same panel (white: plain concrete), so switching never moves a sign.
##
## Glyphs: a small stencil face designed on a 10-unit cap height (digits 6 wide, stroke 1.9, stencil gaps 0.7): 0-9,
## D E C K, a solid triangle arrow up / down. A sign's size is one number, its glyph unit u (m per unit): numeral 10u tall.

static var style := "dark"           ## "dark" (the user's pick 2026-11-24, cell 6) | "white" (cell 4, lab only) | "off"
static var force_number := 0         ## > 0: a district with no section shows this number (tests / lab); 0: none

const OVER_CLEAR := 5.7              ## over-gate sign: its panel's bottom this far over the gate's top (bunker lintel + beacons + 1 m) ...
const OVER_MIN := 17.2               ## ... and at least this high (over a bulkhead's gallery band, 15.4-16.6 m)
const OVER_SHARE := 0.75             ## its panel is this share of the gate's width (0.6 until the side signs went, 2026-11-25) ...
const OVER_U := Vector2(0.4, 0.8)    ## ... with its glyph unit in this range (numeral 4-8 m) ...
const OVER_TOP := 4.0                ## ... and its top this far under the ceiling (the girders)

const LIFT_U := 0.36                 ## lift signs: numeral 3.6 m, the panel's bottom over the door's lamps (9.0-9.8 m)
const LIFT_BOTTOM := 10.4
const LIFT_Z := Vector2(0.3, 0.9)    ## the lift panel's back and face, out of the core's face (pilasters 0.5, channel 0.62)
const HANG_U := 0.4                  ## hung signs: numeral 4 m, the panel's bottom 10 m up (over a mech)
const HANG_BOTTOM := 10.0
const HANG_IN := 4.0                 ## m from a ramp's mouth into the cut (top deck) / past its foot (lower deck)
const HANG_SLIDE := 4.0              ## a hung sign under a ceiling opening moves this much further out, up to
const HANG_SLIDES := 9               ## this many times (else none)
const HANG_T := 0.3                 ## hung panel thickness
const ROD := 0.25                    ## its two hangers
const FARM_Z := Vector2(0.1, 1.0)    ## a farm wall's panel: face 1.0 m out (the racks' leaves reach 0.8)
const PANEL_T := 0.15                ## a dark panel on a bulkhead stands this far out of the wall

## Layout, in glyph units: numeral 10 tall, two digits 6 wide with a 1.0 gap, DECK (0.25 scale, 2.5 tall) 1.0 above it;
## an arrow 8 wide 1.5 left of the numeral. Panel margins round that (dark look, and every panel).
const DIGIT_W := 6.0
const DIGIT_GAP := 1.0
const WORD_SCALE := 0.25
const WORD_GAP := 1.0
const LETTER_GAP := 1.2
const ARROW_W := 8.0
const ARROW_GAP := 1.5
const PAD_SIDE := 1.6
const PAD_TOP := 1.6
const PAD_BOTTOM := 2.8
const CHAMFER := 1.4
const STRIPE := Vector2(0.9, 1.5)    ## the stripe's bottom and top above the panel's bottom
const STRIPE_INSET := 0.9
const OUTLINE := 0.22                ## white look: outline width (units) round numerals and arrows ...
const OUTLINE_WORD := 0.12           ## ... and round the small word
const DECAL := CityStreets.DECAL_PATCH     ## one decal layer (2 cm): outline, then fill, over the surface

static var _glyphs: Dictionary = {}


static func _c(id: String) -> Color:
	return CityPalette.C[id]


## The number district `plan` shows (0: none).
static func number_of(plan: CityPlan) -> int:
	if plan.section != null:
		return plan.deck + 1
	return force_number


static func label(n: int) -> String:
	return "%02d" % n


# --- Layout (style independent) ----------------------------------------------------------------------------------

## Every sign of a district, whatever the style: [{kind (over_gate | lift | ramp), surface (bulkhead | farm | lift |
## hang), xf (frame in district coordinates: origin on the surface plane at the floor, +X reading right, +Z out of the
## surface), u, base (numeral bottom, frame y), z0 / z1 (panel back / face), w / y0 / y1 (footprint, x centred on 0),
## front / back ({number, arrow}), number, dest, arrow, at / n / ref (arc x, s of the sign's centre on its surface, its
## facing, the thing it labels), h (centre height), side, u0 / u1 (along its wall, arc), gate, pillar, ramp}].
static func layout(plan: CityPlan, ring: RingFrame) -> Array:
	var out := []
	var n := number_of(plan)
	if n <= 0:
		return out
	var geo := CityGeo.new(ring)
	_gates(out, plan, geo, n)
	_lifts(out, plan, ring, n)
	_ramps(out, plan, geo, n)
	return out


## The footprint of a sign of glyph unit u whose content is `cw` units wide: [width, y0, y1] relative to base.
static func footprint(u: float, cw: float) -> Vector3:
	return Vector3((cw + PAD_SIDE * 2.0) * u, -PAD_BOTTOM * u, (10.0 + WORD_GAP + 10.0 * WORD_SCALE + PAD_TOP) * u)


static func content_w(face: Dictionary) -> float:
	var w := DIGIT_W * 2.0 + DIGIT_GAP
	if str(face.get("arrow", "")) != "":
		w += ARROW_W + ARROW_GAP
	return w


static func _sign(kind: String, surface: String, xf: Transform3D, u: float, base: float, z: Vector2, front: Dictionary,
		back: Dictionary = {}) -> Dictionary:
	var cw := content_w(front)
	if not back.is_empty():
		cw = maxf(cw, content_w(back))
	var fp := footprint(u, cw)
	return {"kind": kind, "surface": surface, "xf": xf, "u": u, "base": base, "z0": z.x, "z1": z.y, "w": fp.x,
			"y0": base + fp.y, "y1": base + fp.z, "front": front, "back": back, "number": int(front["number"]),
			"dest": int(front["number"]) if str(front.get("arrow", "")) != "" else -1, "arrow": str(front.get("arrow", "")),
			"h": base + (fp.y + fp.z) * 0.5, "side": -1, "u0": 0.0, "u1": 0.0, "gate": -1, "pillar": -1, "ramp": -1}


## One sign per gate of every bulkhead / farm wall (portals too): the over-gate sign, and nothing beside the gate (user
## feedback 2026-11-25: "Just one sign above doors, not 3"). Window walls (the hull, a district on its own only) carry none.
static func _gates(out: Array, plan: CityPlan, geo: CityGeo, n: int) -> void:
	var gi := 0
	for w: Dictionary in plan.boundary():
		var kind := str(w["kind"])
		var gates: Array = w["gates"]
		if kind == "bulkhead" or kind == "farm":
			for gk in gates.size():
				var over := _over_gate(plan, geo, w, gates[gk], n)
				if not over.is_empty():
					over["gate"] = gi + gk
					out.append(over)
		gi += gates.size()


## Centred ABOVE gate g on the wall over it (reads from the road that ends at the gate): its panel's bottom over a
## MissionWorld bunker's lintel and the beacons standing on it (gate top + LINTEL_H 3 + housing 0.4 + beacon 1.3 m,
## MissionProps.GateDoor) with 1 m to spare, which also clears the baked hazard frame (gate top + 1.6 m), and over a
## bulkhead's gallery band (15.4-16.6 m); sized with the gate (OVER_SHARE of its width), under the ceiling's girders.
## Farm walls: on a proud panel in front of the racks.
static func _over_gate(plan: CityPlan, geo: CityGeo, w: Dictionary, g: Dictionary, n: int) -> Dictionary:
	var side := int(w["side"])
	var across := side >= 2
	var at := float(w["at"])
	var inward := -1.0 if side % 2 == 0 else 1.0
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	var bottom := maxf(float(g["h"]) + OVER_CLEAR, OVER_MIN)
	var cw := content_w({"number": n})
	var fp1 := footprint(1.0, cw)      # per unit of u
	var u := clampf((float(g["b"]) - float(g["a"])) * OVER_SHARE / fp1.x, OVER_U.x, OVER_U.y)
	u = minf(u, (plan.p("ceiling") - OVER_TOP - bottom) / (fp1.z - fp1.y))
	if u < OVER_U.x * 0.75:
		return {}
	var xf: Transform3D
	if across:
		xf = geo.frame(mid, at, 0.0, 0.0 if inward > 0.0 else PI)
	else:
		xf = geo.frame(at, mid, 0.0, PI * 0.5 if inward > 0.0 else -PI * 0.5)
	var kind := str(w["kind"])
	var z := FARM_Z if kind == "farm" else Vector2(0.0, PANEL_T)
	var s := _sign("over_gate", kind, xf, u, bottom - fp1.y * u, z, {"number": n, "arrow": ""})
	s["side"] = side
	s["u0"] = mid - float(s["w"]) * 0.5
	s["u1"] = mid + float(s["w"]) * 0.5
	var nv := Vector2(inward, 0.0) if not across else Vector2(0.0, inward)
	s["n"] = nv
	s["at"] = Vector2(mid, at) if across else Vector2(at, mid)
	s["ref"] = s["at"]
	s["gate_top"] = float(g["h"])
	s["door_key"] = "%d:%.2f" % [side, float(g["a"])]     # CityStreets.walls' key of a MissionWorld door in this gate
	return s


## Over every freight lift door (the core's `front` face: CityBuildings._pillar), on a panel above the door's lamps:
## beside the door the leaves slide over the face when they open (MissionProps.LiftDoor).
static func _lifts(out: Array, plan: CityPlan, ring: RingFrame, n: int) -> void:
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if not b["pillar"] or str(b["core"]["kind"]) != "lift":
			continue
		var front := int(b["front"])
		var size: Vector2 = b["core"]["size"]
		var n2: Vector2 = CityPlan.SIDE_N[front]
		var nv := Vector3(n2.x, 0.0, n2.y)
		var depth := size.x if front < 2 else size.y
		var core := Transform3D(CityGeo.frame_basis(ring, float(b["core"]["s"])),
				ring.arc_to_world(float(b["core"]["x"]), float(b["core"]["s"]), CityPlan.CURB_H))
		var xf := core * Transform3D(Basis(Vector3.UP.cross(nv), Vector3.UP, nv), nv * depth * 0.5)
		var s := _sign("lift", "lift", xf, LIFT_U, LIFT_BOTTOM + PAD_BOTTOM * LIFT_U, LIFT_Z, {"number": n, "arrow": ""})
		var c := Vector2(float(b["core"]["x"]), float(b["core"]["s"]))
		s["pillar"] = i
		s["n"] = n2
		s["at"] = c + n2 * depth * 0.5
		s["ref"] = s["at"]
		s["h"] = float(s["h"]) + CityPlan.CURB_H
		out.append(s)


## Hung from the ceiling at both ends of every ramp: on the deck it leaves, 4 m into the cut past its mouth, facing the
## way in (arrow down + the deck below); on the deck it lands on, 4 m past its foot, facing the way in (arrow up + the
## deck above). The back of each shows this deck. Under a ceiling opening it moves further along the way in (HANG_SLIDE).
static func _ramps(out: Array, plan: CityPlan, geo: CityGeo, n: int) -> void:
	if plan.section == null:
		return
	for ri in plan.ramps.size():
		var r: Dictionary = plan.ramps[ri]
		var cn: Dictionary = plan.section.connectors[int(r["connector"])]
		var down := signf(float(r["s_foot"]) - float(r["s_top"]))
		var top: bool = r["role"] == "top"
		var dest := int(cn["to"]) + 1 if top else int(cn["from"]) + 1
		var sc := float(r["s_top"]) + down * HANG_IN if top else float(r["s_foot"]) + down * HANG_IN
		var facing := -down if top else down
		var xc := (float(r["x0"]) + float(r["x1"])) * 0.5
		# Where a ceiling opening (snapped to whole 12 m panels) is over that spot, further along the way in.
		var s := {}
		for step in HANG_SLIDES:
			s = _hung(plan, geo, "ramp", xc, sc + facing * HANG_SLIDE * float(step), facing,
					{"number": dest, "arrow": "down" if top else "up"}, {"number": n, "arrow": ""})
			if not s.is_empty():
				break
		if s.is_empty():
			continue
		s["ramp"] = ri
		s["ref"] = Vector2(xc, float(r["s_top"]) if top else float(r["s_foot"]))
		out.append(s)


static func _hung(plan: CityPlan, geo: CityGeo, kind: String, xc: float, sc: float, facing: float, front: Dictionary,
		back: Dictionary) -> Dictionary:
	var xf := geo.frame(xc, sc, 0.0, 0.0 if facing > 0.0 else PI)
	var s := _sign(kind, "hang", xf, HANG_U, HANG_BOTTOM + PAD_BOTTOM * HANG_U, Vector2(-HANG_T * 0.5, HANG_T * 0.5), front, back)
	var ceiling := plan.p("ceiling")
	if float(s["y1"]) > ceiling - 3.0:
		return {}
	for k: float in [-1.0, 1.0]:
		var hx := xc + k * (float(s["w"]) * 0.5 - 0.8)
		for o: Rect2 in plan.site.openings:
			if CityStreets.ceiling_opening(o).grow(1.0).has_point(Vector2(hx, sc)):
				return {}
	s["n"] = Vector2(0.0, facing)
	s["at"] = Vector2(xc, sc)
	s["ceiling"] = ceiling
	return s


# --- Geometry ----------------------------------------------------------------------------------------------------

## The district's lettering as one mesh (null when there is none: style off, no number, nothing to label). Render layers
## are set here, before the caller adds it to the tree. meta "tris": its triangle count; meta "signs": the sign count.
static func build_node(plan: CityPlan, ring: RingFrame, layer: int) -> MeshInstance3D:
	if style == "off" or number_of(plan) <= 0:
		return null
	var signs := layout(plan, ring)
	if signs.is_empty():
		return null
	var geo := CityGeo.new(ring)
	for s: Dictionary in signs:
		build(geo, s, style)
	var mi := geo.instance("DeckSigns")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = layer
	mi.set_meta("tris", geo.tri_count())
	mi.set_meta("signs", signs.size())
	return mi


## One sign into `geo` in look `st` ("white" | "dark").
static func build(geo: CityGeo, s: Dictionary, st: String) -> void:
	var xf: Transform3D = s["xf"]
	var u := float(s["u"])
	var base := float(s["base"])
	var dark := st == "dark"
	var paint: bool = s["surface"] == "bulkhead" and not dark      # painted straight on the wall: no panel
	var face := 0.0
	if not paint:
		var poly := _panel_poly(s)
		var z0 := float(s["z0"])
		var z1 := float(s["z1"])
		geo.tag("deck_sign.panel")
		_extrude(geo, xf, poly, z0, z1, _c("sign_panel") if dark else _c("concrete"), s["surface"] == "hang")
		face = z1
		if s["surface"] == "hang":
			geo.tag("deck_sign.rod")
			var top := float(s["y1"])
			var ceiling := float(s["ceiling"]) + 0.5
			for k: float in [-1.0, 1.0]:
				geo.box(xf, Vector3(k * (float(s["w"]) * 0.5 - 0.8), (top + ceiling) * 0.5, 0.0), Vector3(ROD, ceiling - top, ROD), _c("metal_dark"))
	_face(geo, xf, s["front"], u, base, face, dark, float(s["w"]), float(s["y0"]))
	if not (s["back"] as Dictionary).is_empty():
		var bx := xf * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
		_face(geo, bx, s["back"], u, base, -float(s["z0"]), dark, float(s["w"]), float(s["y0"]))


## The panel outline (frame metres, CCW seen from +Z): the footprint with chamfered corners.
static func _panel_poly(s: Dictionary) -> PackedVector2Array:
	var hw := float(s["w"]) * 0.5
	var y0 := float(s["y0"])
	var y1 := float(s["y1"])
	var c := CHAMFER * float(s["u"])
	return PackedVector2Array([Vector2(-hw + c, y0), Vector2(hw - c, y0), Vector2(hw, y0 + c), Vector2(hw, y1 - c),
			Vector2(hw - c, y1), Vector2(-hw + c, y1), Vector2(-hw, y1 - c), Vector2(-hw, y0 + c)])


## A face's content on the surface at z = `face`: the stripe (dark), the outline (white) and the glyphs.
static func _face(geo: CityGeo, xf: Transform3D, f: Dictionary, u: float, base: float, face: float, dark: bool, w: float, y0: float) -> void:
	var polys := _content(f, u, base)     # [[PackedVector2Array (m), outline (m)]]
	if dark:
		geo.tag("deck_sign.stripe")
		var hw := w * 0.5 - STRIPE_INSET * u
		_flat(geo, xf, PackedVector2Array([Vector2(-hw, y0 + STRIPE.x * u), Vector2(hw, y0 + STRIPE.x * u),
				Vector2(hw, y0 + STRIPE.y * u), Vector2(-hw, y0 + STRIPE.y * u)]), face + DECAL, _c("sign_stripe"))
		geo.tag("deck_sign.glyph")
		for p: Array in polys:
			_flat(geo, xf, p[0], face + DECAL, _c("sign_cream"))
		return
	geo.tag("deck_sign.outline")
	for p: Array in polys:
		_flat(geo, xf, _grow(p[0], float(p[1])), face + DECAL, _c("sign_outline"))
	geo.tag("deck_sign.glyph")
	for p: Array in polys:
		_flat(geo, xf, p[0], face + DECAL * 2.0, _c("sign_white"))


## Every glyph piece of a face in frame metres, centred on x = 0, the numeral's bottom at `base`; with its outline width.
static func _content(f: Dictionary, u: float, base: float) -> Array:
	var out := []
	var cw := content_w(f)
	var x := -cw * 0.5
	var arrow := str(f.get("arrow", ""))
	if arrow != "":
		for poly: PackedVector2Array in glyph("arrow_" + arrow):
			out.append([_place(poly, x, base, u, 1.0), OUTLINE * u])
		x += ARROW_W + ARROW_GAP
	var num := label(int(f["number"]))
	var nx := x
	for i in num.length():
		for poly: PackedVector2Array in glyph(num[i]):
			out.append([_place(poly, nx + float(i) * (DIGIT_W + DIGIT_GAP), base, u, 1.0), OUTLINE * u])
	# The word, centred over the numeral.
	var word := "DECK"
	var ww := -LETTER_GAP
	for ch in word:
		ww += glyph_w(ch) + LETTER_GAP
	var wx := nx + (DIGIT_W * 2.0 + DIGIT_GAP - ww * WORD_SCALE) * 0.5
	var wy := 10.0 + WORD_GAP
	for ch in word:
		for poly: PackedVector2Array in glyph(ch):
			out.append([_place(poly, wx, base + wy * u, u, WORD_SCALE), OUTLINE_WORD * u])
		wx += (glyph_w(ch) + LETTER_GAP) * WORD_SCALE
	return out


static func _place(poly: PackedVector2Array, x: float, y: float, u: float, sc: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(Vector2(x * u + p.x * sc * u, y + p.y * sc * u))
	return out


## `poly` grown by d (m), mitred corners (Geometry2D's offset: the outward result, whatever the winding convention).
static func _grow(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var a0 := absf(_area(poly))
	for dd: float in [d, -d]:
		var res := Geometry2D.offset_polygon(poly, dd, Geometry2D.JOIN_MITER)
		var best := PackedVector2Array()
		for r: PackedVector2Array in res:
			if absf(_area(r)) > absf(_area(best)):
				best = r
		if absf(_area(best)) > a0:
			return _ccw(best)
	return poly


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


static func _ccw(p: PackedVector2Array) -> PackedVector2Array:
	if _area(p) < 0.0:
		var r := p.duplicate()
		r.reverse()
		return r
	return p


## A flat polygon (frame metres) at depth z facing +Z, triangulated.
static func _flat(geo: CityGeo, xf: Transform3D, poly: PackedVector2Array, z: float, col: Color) -> void:
	var idx := Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		for i in range(1, poly.size() - 1):
			idx.append_array(PackedInt32Array([0, i, i + 1]))
	for t in range(0, idx.size(), 3):
		var a := poly[idx[t]]
		var b := poly[idx[t + 1]]
		var c := poly[idx[t + 2]]
		if (b - a).cross(c - a) < 0.0:
			var tmp := b
			b = c
			c = tmp
		geo.tri(xf * Vector3(a.x, a.y, z), xf * Vector3(b.x, b.y, z), xf * Vector3(c.x, c.y, z), col)


## A convex panel: face at z1, sides down to z0, a back face at z0 when `back`.
static func _extrude(geo: CityGeo, xf: Transform3D, poly: PackedVector2Array, z0: float, z1: float, col: Color, back: bool) -> void:
	_flat(geo, xf, poly, z1, col)
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		geo.quad(xf * Vector3(p.x, p.y, z0), xf * Vector3(q.x, q.y, z0), xf * Vector3(q.x, q.y, z1), xf * Vector3(p.x, p.y, z1), col)
	if back:
		var bx := xf * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
		var mir := PackedVector2Array()
		for p in poly:
			mir.append(Vector2(-p.x, p.y))
		_flat(geo, bx, _ccw(mir), -z0, col)


# --- The stencil face ---------------------------------------------------------------------------------------------

## Glyph `ch` as its stencil pieces (CCW polygons, units: cap height 10, origin bottom-left).
static func glyph(ch: String) -> Array:
	if _glyphs.is_empty():
		_glyphs = _make_glyphs()
	return _glyphs.get(ch, [])


static func glyph_w(ch: String) -> float:
	return {"E": 5.0, "C": 5.6, "arrow_up": ARROW_W, "arrow_down": ARROW_W}.get(ch, 6.0)


static func _p(a: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(0, a.size(), 2):
		out.append(Vector2(float(a[i]), float(a[i + 1])))
	return _ccw(out)


static func _mirror(p: PackedVector2Array, w: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in p:
		out.append(Vector2(w - q.x, q.y))
	return _ccw(out)


static func _rot(p: PackedVector2Array, w: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in p:
		out.append(Vector2(w - q.x, 10.0 - q.y))
	return _ccw(out)


static func _make_glyphs() -> Dictionary:
	var g := {}
	var stem := _p([0, 0, 1.9, 0, 1.9, 10, 0, 10])
	var zero := _p([2.65, 10, 1.7, 10, 0, 8.3, 0, 1.7, 1.7, 0, 2.65, 0, 2.65, 1.9, 2.4, 1.9, 1.9, 2.4, 1.9, 7.6, 2.4, 8.1, 2.65, 8.1])
	g["0"] = [zero, _mirror(zero, DIGIT_W)]
	g["1"] = [_p([2.2, 0, 4.1, 0, 4.1, 10, 2.5, 10, 0.6, 8.2, 1.3, 6.9, 2.2, 7.7])]
	g["2"] = [_p([0, 2.6, 2.7, 2.6, 6, 6.2, 6, 8.3, 4.3, 10, 1.7, 10, 0, 8.3, 0, 7.0, 1.9, 7.0, 1.9, 7.6, 2.4, 8.1, 3.6, 8.1, 4.1, 7.6, 4.1, 6.6]),
			_p([0, 0, 6, 0, 6, 1.9, 0, 1.9])]
	g["3"] = [_p([0.3, 8.1, 0.3, 10, 4.3, 10, 6, 8.3, 6, 5.4, 5.25, 4.15, 1.6, 4.15, 1.6, 5.85, 4.1, 5.85, 4.1, 7.6, 3.6, 8.1]),
			_p([0.3, 0, 4.3, 0, 6, 1.7, 6, 3.0, 5.55, 3.45, 4.1, 3.45, 4.1, 2.4, 3.6, 1.9, 0.3, 1.9])]
	g["4"] = [_p([0, 2.4, 3.2, 2.4, 3.2, 4.2, 2.15, 4.2, 3.2, 8.6, 3.2, 10, 1.5, 10, 0, 4.4]), _p([3.9, 0, 5.8, 0, 5.8, 10, 3.9, 10])]
	g["5"] = [_p([0.2, 4.5, 2.1, 4.5, 2.1, 8.1, 5.8, 8.1, 5.8, 10, 0.2, 10]),
			_p([0, 0, 4.3, 0, 6, 1.7, 6, 4.6, 4.3, 6.3, 2.8, 6.3, 2.8, 4.5, 3.6, 4.5, 4.1, 4.0, 4.1, 2.4, 3.6, 1.9, 0, 1.9])]
	var six_l := _p([2.65, 0, 1.7, 0, 0, 1.7, 0, 8.3, 1.7, 10, 5.6, 10, 5.6, 8.1, 2.4, 8.1, 1.9, 7.6, 1.9, 2.4, 2.4, 1.9, 2.65, 1.9])
	var six_r := _p([3.35, 0, 4.3, 0, 6, 1.7, 6, 4.6, 4.3, 6.3, 2.6, 6.3, 2.6, 4.5, 3.6, 4.5, 4.1, 4.0, 4.1, 2.4, 3.6, 1.9, 3.35, 1.9])
	g["6"] = [six_l, six_r]
	g["7"] = [_p([0, 8.1, 0, 10, 6, 10, 6, 8.4, 3.2, 0, 1.2, 0, 3.9, 8.1])]
	var eight := _p([2.65, 10, 1.6, 10, 0.3, 8.7, 0.3, 6.4, 1.0, 5.5, 0, 4.5, 0, 1.6, 1.6, 0, 2.65, 0, 2.65, 1.8, 2.3, 1.8, 1.9, 2.2,
			1.9, 3.8, 2.3, 4.2, 2.65, 4.2, 2.65, 5.8, 2.4, 5.8, 2.0, 6.2, 2.0, 7.8, 2.4, 8.2, 2.65, 8.2])
	g["8"] = [eight, _mirror(eight, DIGIT_W)]
	g["9"] = [_rot(six_l, DIGIT_W), _rot(six_r, DIGIT_W)]
	g["D"] = [stem, _p([2.6, 0, 4.0, 0, 6, 2.0, 6, 8.0, 4.0, 10, 2.6, 10, 2.6, 8.1, 3.4, 8.1, 4.1, 7.4, 4.1, 2.6, 3.4, 1.9, 2.6, 1.9])]
	g["E"] = [stem, _p([2.6, 8.1, 5, 8.1, 5, 10, 2.6, 10]), _p([2.6, 4.15, 4.4, 4.15, 4.4, 5.85, 2.6, 5.85]), _p([2.6, 0, 5, 0, 5, 1.9, 2.6, 1.9])]
	g["C"] = [_p([5.6, 10, 1.7, 10, 0, 8.3, 0, 1.7, 1.7, 0, 5.6, 0, 5.6, 1.9, 2.4, 1.9, 1.9, 2.4, 1.9, 7.6, 2.4, 8.1, 5.6, 8.1])]
	g["K"] = [stem, _p([3.95, 0, 6, 0, 4.5, 3.7, 2.7, 3.7]), _p([2.6, 4.4, 3.9, 4.4, 6, 10, 4.0, 10, 2.6, 6.3])]
	g["arrow_down"] = [_p([0, 9, 8, 9, 4, 1])]
	g["arrow_up"] = [_p([4, 9, 0, 1, 8, 1])]
	return g


# --- Lab ---------------------------------------------------------------------------------------------------------

## A lab camera on the first sign of a kind on the first district of `list` that has one: {district, eye, target} in arc
## coordinates (x, s, h), or {}. sign_road: a gate and its over-gate sign from its road, 80 m back at 10 m up; sign_lift:
## a lift door and its sign from 45 m; sign_ramp: a ramp's hung sign from 55 m in front of its face.
static func lab_view(list: Array, cam: String) -> Dictionary:
	var want := {"sign_lift": "lift", "sign_ramp": "ramp", "sign_road": "over_gate"}.get(cam, "") as String
	for d: Variant in list:
		if d == null or d.plan == null:
			continue
		var first := {}
		for s: Dictionary in layout(d.plan, d.ring):
			if s["kind"] != want:
				continue
			var at: Vector2 = s["at"]
			var nv: Vector2 = s["n"]
			if want == "over_gate":
				# ON the road that ends at the gate, 80 m back at 10 m: the first gate whose over-gate sign no building hides
				# (a gate with a MissionWorld door first, when the mission is on).
				var doors: Dictionary = d.plan.get_meta("mission_doors", {})
				if not doors.is_empty() and not doors.has(str(s["door_key"])):
					continue
				var e0 := at + nv * 80.0
				var v0 := {"district": d, "eye": Vector3(e0.x, e0.y, 10.0), "target": Vector3(at.x, at.y, float(s["h"]) - 4.0)}
				if first.is_empty():
					first = v0
				if _seen(d.plan, Vector3(e0.x, e0.y, 10.0), Vector3(at.x, at.y, float(s["h"]))):
					return v0
				continue
			var dist := 45.0 if want == "lift" else 55.0
			var e2 := at + nv * dist
			return {"district": d, "eye": Vector3(e2.x, e2.y, 9.0), "target": Vector3(at.x, at.y, float(s["h"]) - 1.5)}
		if not first.is_empty():
			return first
	return {}


## Whether no building tier stands between arc points a and b (x, s, h): sampled every 2 m (lab cameras only).
static func _seen(plan: CityPlan, a: Vector3, b: Vector3) -> bool:
	var n := int(ceil(Vector2(b.x - a.x, b.y - a.y).length() / 2.0))
	for i in range(1, n):
		var p := a.lerp(b, float(i) / float(n))
		for bi in plan.buildings.size():
			for t: Dictionary in plan.buildings[bi]["tiers"]:
				if p.z < float(t["y1"]) and plan.tier_rect(bi, t).has_point(Vector2(p.x, p.y)):
					return false
	return true
