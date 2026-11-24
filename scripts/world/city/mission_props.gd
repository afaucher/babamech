class_name MissionProps
extends RefCounted
## The pieces MissionWorld puts in the city for mission objectives phase 1 (docs/design/city-ramps-and-stack.md "Mission
## world (phase 1)"): wave doors (a blast door in a wall gate, a freight lift's doors), the flag mast, the defend relay,
## the extraction portal, the zone rings on the ground, and the rule that snaps a site to clear ground. Presentation only:
## no clock, no state, no network; MissionWorld poses them from its schedules. Flat-shaded CityGeo boxes in CityPalette
## colours; glows use the emissive materials below (no Light3D here). Every mesh gets its render layer before it enters
## the tree (the stack's rule).

## Emissive materials by palette id and energy (shared, cached; never animated: an animated glow gets its own).
static var _glow: Dictionary = {}


static func c(id: String) -> Color:
	return CityPalette.C[id]


static func glow(id: String, energy: float = 2.5) -> StandardMaterial3D:
	var key := "%s@%.2f" % [id, energy]
	if not _glow.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c(id)
		m.roughness = 1.0
		m.emission_enabled = true
		m.emission = c(id)
		m.emission_energy_multiplier = energy
		_glow[key] = m
	return _glow[key]


## A plain matte material of palette id `id` (shared, cached): an unlit stand-in for a glow (the bay's lights off).
static var _flat: Dictionary = {}

static func flat(id: String) -> StandardMaterial3D:
	if not _flat.has(id):
		var m := StandardMaterial3D.new()
		m.albedo_color = c(id)
		m.roughness = 1.0
		_flat[id] = m
	return _flat[id]


## A MeshInstance3D of `geo` on render layers `layer` (set before it enters any tree), no shadows unless asked.
static func mesh(geo: CityGeo, node_name: String, layer: int, material: Material = null, shadows: bool = false) -> MeshInstance3D:
	var mi := geo.instance(node_name, material)
	mi.layers = layer
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A box CollisionShape3D at `center` (local) of `size` under `body`.
static func box_shape(body: StaticBody3D, xf: Transform3D, center: Vector3, size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.transform = xf * Transform3D(Basis.IDENTITY, center)
	body.add_child(cs)
	return cs


## A StaticBody3D on the same collision layer / mask as district d's own collision.
static func body_like(d: CityDistrict, node_name: String) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = node_name
	var col := d.get_node_or_null("Collision") as StaticBody3D
	if col != null:
		b.collision_layer = col.collision_layer
		b.collision_mask = col.collision_mask
	return b


## The frame CityStreets._gate builds gate g of wall w in (district-local): origin on the wall plane at the floor, in the
## middle of the gate; local X along the wall, Y up, +Z into the map.
static func gate_frame(d: CityDistrict, w: Dictionary, g: Dictionary) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	var side := int(w["side"])
	var at := float(w["at"])
	var inward := -1.0 if side % 2 == 0 else 1.0
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	if side >= 2:
		return geo.frame(mid, at, 0.0, 0.0 if inward > 0.0 else PI)
	return geo.frame(at, mid, 0.0, PI * 0.5 if inward > 0.0 else -PI * 0.5)


## Half the clear opening of gate g (between the hazard portal's posts), as CityStreets._gate draws it.
static func gate_half(g: Dictionary) -> float:
	return (float(g["b"]) - float(g["a"])) * 0.5 - 0.6


# --- Drawing helpers (flat colour per face) ------------------------------------------------------------------------------

## A convex polygon `poly` (counter-clockwise in local x / y as seen from +Z) extruded from z0 to z1 (z0 < z1) in frame xf.
## Edge i (poly[i] -> poly[i + 1]) gets no side face when listed in `skip`; the +Z cap (front) and -Z cap (back) optional.
static func extrude(geo: CityGeo, xf: Transform3D, poly: Array[Vector2], z0: float, z1: float, col: Color, front: bool = true,
		back: bool = false, skip: Array = [], side_col: Variant = null) -> void:
	var n := poly.size()
	var sc: Color = col if side_col == null else (side_col as Color)
	for i in n:
		if skip.has(i):
			continue
		var a := poly[i]
		var b := poly[(i + 1) % n]
		geo.quad(xf * Vector3(a.x, a.y, z0), xf * Vector3(b.x, b.y, z0), xf * Vector3(b.x, b.y, z1), xf * Vector3(a.x, a.y, z1), sc)
	for i in range(1, n - 1):
		if front:
			geo.tri(xf * Vector3(poly[0].x, poly[0].y, z1), xf * Vector3(poly[i].x, poly[i].y, z1), xf * Vector3(poly[i + 1].x, poly[i + 1].y, z1), col)
		if back:
			geo.tri(xf * Vector3(poly[0].x, poly[0].y, z0), xf * Vector3(poly[i + 1].x, poly[i + 1].y, z0), xf * Vector3(poly[i].x, poly[i].y, z0), col)


## Convex polygon `poly` clipped to rect r (Sutherland-Hodgman).
static func clip_rect(poly: Array, r: Rect2) -> Array:
	var out: Array = poly
	for e in 4:
		var inp: Array = out
		out = []
		for i in inp.size():
			var p: Vector2 = inp[i]
			var q: Vector2 = inp[(i + 1) % inp.size()]
			var pin := _inside(p, r, e)
			if pin:
				out.append(p)
			if pin != _inside(q, r, e):
				out.append(_cut_edge(p, q, r, e))
	return out


static func _inside(p: Vector2, r: Rect2, e: int) -> bool:
	match e:
		0: return p.x >= r.position.x
		1: return p.x <= r.end.x
		2: return p.y >= r.position.y
	return p.y <= r.end.y


static func _cut_edge(p: Vector2, q: Vector2, r: Rect2, e: int) -> Vector2:
	var t: float
	match e:
		0: t = (r.position.x - p.x) / (q.x - p.x)
		1: t = (r.end.x - p.x) / (q.x - p.x)
		2: t = (r.position.y - p.y) / (q.y - p.y)
		_: t = (r.end.y - p.y) / (q.y - p.y)
	return p.lerp(q, t)


## Dark diagonal stripes `stripe` m wide (as wide gaps between) over rect r, flat at z facing +Z in frame xf, rising to the
## right when dir > 0, to the left when dir < 0 (draw them 2.5 cm in front of a yellow face).
static func stripes(geo: CityGeo, xf: Transform3D, r: Rect2, z: float, stripe: float, dir: float, col: Color) -> void:
	var h := r.size.y
	var u := r.position.x - h - stripe * 2.0
	while u < r.end.x + h:
		var poly: Array
		if dir > 0.0:
			poly = [Vector2(u, r.position.y), Vector2(u + stripe, r.position.y), Vector2(u + stripe + h, r.end.y), Vector2(u + h, r.end.y)]
		else:
			poly = [Vector2(u + h, r.position.y), Vector2(u + h + stripe, r.position.y), Vector2(u + stripe, r.end.y), Vector2(u, r.end.y)]
		var c := clip_rect(poly, r)
		for i in range(1, c.size() - 1):
			geo.tri(xf * Vector3(c[0].x, c[0].y, z), xf * Vector3(c[i].x, c[i].y, z), xf * Vector3(c[i + 1].x, c[i + 1].y, z), col)
		u += stripe * 2.0


## A ConvexPolygonShape3D of `points` (in frame xf) under `body`.
static func convex_shape(body: StaticBody3D, xf: Transform3D, points: PackedVector3Array) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var s := ConvexPolygonShape3D.new()
	s.points = points
	cs.shape = s
	cs.transform = xf
	body.add_child(cs)
	return cs


# --- Wave door in a wall gate: the staging bay ---------------------------------------------------------------------------

## A wave gate (docs/design/city-ramps-and-stack.md "Mission world", "Staging bay"): a projecting concrete bunker frame
## round the opening on the street side, two sliding steel leaves just behind the wall plane, and behind the wall a
## staging bay (a hangar room BAY_DEPTH m deep from the wall plane, at least BAY_MIN_W wide behind the wall thickness,
## BAY_H high) with a shut blast door drawn on its back wall (static: where the units "came from"). Look: user pick
## 2026-11-23, `docs/design/city-gates/bay_sliding_bunker_s61.png` (flat colours; every look choice in this class).
## While the leaves OPEN (MissionWorld: from open_at for OPENING s) the recessed amber lamps under the lintel flash in
## turn, the beacons on the lintel turn and the siren loops (MissionSound); otherwise they are dark. The bay's light strips
## and bars glow from the warning until it is shut again. Sealed: welded bars across, scorch on the leaves, beacons dead.
## Frame: origin on the wall plane at floor mid-gate, X along the wall, Y up, +Z into the map (MissionProps.gate_frame).
## The floor follows the deck's facets (drawn and collided in the district's arc coordinates: no lip on the curve).
## Collision (the wall's own slab is cut at the gate by MissionWorld and rebuilt round it): `door_shape` fills the opening
## from the wall plane 2.8 m back while shut / warning / opening / sealed; the bay is a sealed box of PLATE m plates (floor,
## sides, back, roof) overlapping the cut wall; the bunker's jambs, lintel and sign pier are solid.
class GateDoor extends Node3D:
	const LEAF_Z := -1.8         ## the leaves' face: behind a farm wall's backing (CityStreets.FARM_RECESS 1.6), hidden as they slide
	const BAY_DEPTH := 26.0      ## m from the wall plane to the bay's back wall (inner face)
	const BAY_MIN_W := 22.0      ## m: the interior is at least this wide behind the wall thickness (20 m clear after MARGIN)
	const BAY_H := 18.0          ## m: the roof's underside above the frame's floor (the deck at the wall plane)
	const PLATE := 1.2           ## m: the bay's collision plates
	const LIGHT_DROP := 0.25     ## m the ceiling light bars hang below the roof: the lowest thing in the bay
	const MARGIN := 1.0          ## m kept clear along the bay's walls (source_bay's usable width)
	const USE_FROM := 8.0        ## m behind the wall plane where the usable volume starts (past the wall and the leaves)
	const USE_TO := 24.0         ## m behind the wall plane where it ends (clear of the back door)
	const FRAME_OUT := 2.0       ## m the bunker's jambs project into the street (its lintel 0.4 m more)
	const JAMB := 2.4            ## m wide jambs beside the opening ...
	const BUTT := 2.2            ## ... and the sloped buttress foot this much wider again
	const LINTEL_H := 3.0        ## m: the lintel from the opening's top up
	const PANEL := Vector2(6.0, 4.0)    ## the clean sign panel beside the +X buttress (stencil later; no text here)
	const PANEL_Y := 5.0         ## its centre's height
	const PIER_OUT := 1.6        ## m the sign pier stands out of the wall plane
	var half := 7.0              ## half the clear opening (between the jambs)
	var gh := 9.0                ## the opening's height (the lintel's underside)
	var w_out := 7.6             ## half the gate in the wall (the throat through the wall's thickness)
	var ihalf := 11.0            ## half the bay's interior width (behind the wall thickness)
	var floor_rise := 0.0        ## the most the faceted floor rises above the frame's y = 0 inside the bay
	var back_rise := 0.0         ## and at the back wall's middle
	var arc_mid := Vector2.ZERO  ## the frame's origin in the deck's arc coordinates (x, s)
	var arc_x := Vector2.RIGHT   ## the frame's +X in arc coordinates
	var arc_in := Vector2.DOWN   ## the frame's +Z (into the map) in arc coordinates
	var panel_xf := Transform3D.IDENTITY   ## the sign panel: centre on the pier's face, +Z out of it, X along the wall
	var leaves: Array[Node3D] = []
	var beacons_lit: Array[Node3D] = []     ## turning paddles + glowing core (opening)
	var beacons_idle: Array[Node3D] = []    ## unlit cores (any other state)
	var wigwag: Array[MeshInstance3D] = []  ## the amber lamps under the lintel, left group and right group, lit in turn while opening
	var wigwag_idle: Array[MeshInstance3D] = []
	var lights_on: MeshInstance3D           ## the bay's light strips and bars, glowing (warn .. closing)
	var lights_off: MeshInstance3D
	var siren: AudioStreamPlayer3D          ## the gate's klaxon (MissionSound), looping while opening (and audible here)
	var siren_on := false                   ## the siren was last told to play (own flag: a headless dummy driver may not report `playing`)
	var sealed_look: Node3D
	var body: StaticBody3D
	var door_shape: CollisionShape3D
	# Sizes (the gate's by default; an air door sets its own before build(): MissionWorld._c_air).
	var bay_depth := BAY_DEPTH   ## m from the wall plane to the room's back wall
	var room_h := BAY_H          ## m: the room's roof underside above its floor
	var jamb := JAMB
	var butt := BUTT
	var frame_out := FRAME_OUT
	var lintel_h := LINTEL_H
	var sill := 0.0              ## m: the opening's bottom above the deck floor at the wall (an air door's 21 m)
	var air := false             ## an air door: high on the wall, flat floor plate, a sill ledge, no sign pier, no guide lines on the street
	const AIR_LEDGE := 1.5       ## m an air door's sill ledge projects into the street ...
	const AIR_LEDGE_T := 1.2     ## ... and how thick it is under the sill

	## The deck arc point (x, s) `lx` m along the wall from mid-gate and `depth` m behind the wall plane (negative: in the map).
	func arc(lx: float, depth: float) -> Vector2:
		return arc_mid + arc_x * lx - arc_in * depth

	## ihalf_want: half the bay's interior width (MissionWorld.bay_half: the gate's, widened to BAY_MIN_W, clamped by neighbours).
	func build(d: CityDistrict, w: Dictionary, g: Dictionary, look: RandomNumberGenerator, ihalf_want: float = -1.0) -> void:
		var layer := d.render_layer
		half = MissionProps.gate_half(g)
		w_out = half + 0.6
		gh = float(g["h"])
		ihalf = maxf(ihalf_want if ihalf_want > 0.0 else maxf(w_out, BAY_MIN_W * 0.5), w_out)
		transform = MissionProps.gate_frame(d, w, g) * Transform3D(Basis.IDENTITY, Vector3(0, sill, 0))
		var side := int(w["side"])
		var mid := (float(g["a"]) + float(g["b"])) * 0.5
		var at := float(w["at"])
		arc_mid = Vector2(mid, at) if side >= 2 else Vector2(at, mid)
		arc_x = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)][side]
		arc_in = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)][side]
		var geo_d := CityGeo.new(d.ring)
		var inv := transform.affine_inverse()
		floor_rise = 0.0
		back_rise = 0.0
		if not air:      # an air door's recess has a flat floor plate in its own frame
			for p: Vector2 in [Vector2(-ihalf, bay_depth), Vector2(ihalf, bay_depth), Vector2(-ihalf, CityStreets.WALL_THICK),
					Vector2(ihalf, CityStreets.WALL_THICK), Vector2(0, bay_depth)]:
				var a := arc(p.x, p.y)
				floor_rise = maxf(floor_rise, (inv * geo_d.g_point(a.x, a.y, 0.0)).y)
			var ab := arc(0.0, bay_depth)
			back_rise = (inv * geo_d.g_point(ab.x, ab.y, 0.0)).y
		_build_bay(d, layer, geo_d, inv)
		_build_bunker(layer)
		_build_leaves(layer)
		_build_lamps(layer)
		siren = MissionSound.gate_siren(gh)
		add_child(siren)
		_build_sealed(layer, look)
		_build_collision(d, geo_d, inv)

	## The usable clear height inside the bay: under the light bars, over the floor's highest point.
	func clear_height() -> float:
		return room_h - LIGHT_DROP - floor_rise

	# The bay: throat through the wall, the room, its lights, the back blast door, the floor (arc coordinates).
	func _build_bay(d: CityDistrict, layer: int, geo_d: CityGeo, inv: Transform3D) -> void:
		var st := CityGeo.new()
		st.tag("mission.bay")
		var F := -CityStreets.WALL_THICK
		var D := -bay_depth
		var y0 := -1.2
		var throat := MissionProps.c("concrete_dark").darkened(0.55)
		var wall := MissionProps.c("m_leaf").darkened(0.3)
		var rib := MissionProps.c("metal_dark").darkened(0.35)
		var roof := MissionProps.c("m_recess")
		# Throat (the wall's thickness, the gate's own width).
		_face_px(st, -w_out, 0.0, F, -0.3, gh, throat)
		_face_nx(st, w_out, 0.0, F, -0.3, gh, throat)
		_face_ny(st, -w_out, w_out, 0.0, F, gh, throat)
		# The room: its front wall round the throat, sides, back, roof (faces turned inward).
		if ihalf > w_out + 0.01:
			_face_nz(st, -ihalf, -w_out, y0, room_h, F, wall)
			_face_nz(st, w_out, ihalf, y0, room_h, F, wall)
		_face_nz(st, -w_out, w_out, gh, room_h, F, wall)
		_face_px(st, -ihalf, F, D, y0, room_h, wall)
		_face_nx(st, ihalf, F, D, y0, room_h, wall)
		_face_pz(st, -ihalf, ihalf, y0, room_h, D, wall)
		_face_ny(st, -ihalf, ihalf, F, D, room_h, roof)
		# Ribs up the side walls, a light strip on each; light bars across the roof.
		var lg := CityGeo.new()
		lg.tag("mission.bay_lights")
		var ribs: Array[float] = []
		var z := F - 2.0
		while z > D + 1.5:
			ribs.append(z)
			z -= 4.5
		for zr in ribs:
			for k: float in [-1.0, 1.0]:
				var faces := CityGeo.ALL - CityGeo.NY - CityGeo.PY - (CityGeo.NX if k < 0.0 else CityGeo.PX)
				st.box(Transform3D.IDENTITY, Vector3(k * (ihalf - 0.3), (y0 + room_h) * 0.5, zr), Vector3(0.6, room_h - y0, 1.0), rib, faces)
				var sh := minf(8.0, room_h - 2.6)
				lg.box(Transform3D.IDENTITY, Vector3(k * (ihalf - 0.66), 1.6 + floor_rise + sh * 0.5, zr), Vector3(0.12, sh, 0.36), MissionProps.c("strip"),
						CityGeo.ALL - (CityGeo.NX if k < 0.0 else CityGeo.PX))
		z = F - 3.0
		while z > D + 1.5:
			lg.box(Transform3D.IDENTITY, Vector3(0, room_h - LIGHT_DROP * 0.5, z), Vector3(ihalf * 2.0 - 3.0, LIGHT_DROP, 0.7), MissionProps.c("strip"),
					CityGeo.ALL - CityGeo.PY)
			z -= 5.0
		# The back blast door: a steel frame on the back wall, the shut leaf with yellow / black chevrons and a centre seam.
		var dw := minf(ihalf * 2.0 - 6.0, 16.0)
		var dh := minf(12.0, room_h - 5.0) if not air else room_h - 1.6
		var by := back_rise - 0.3
		var fr := MissionProps.c("metal")
		var faces_f := CityGeo.ALL - CityGeo.NZ - CityGeo.NY
		for k: float in [-1.0, 1.0]:
			st.box(Transform3D.IDENTITY, Vector3(k * (dw * 0.5 + 0.6), by + (dh + 1.2) * 0.5, D + 0.4), Vector3(1.2, dh + 1.2, 0.8), fr, faces_f)
		st.box(Transform3D.IDENTITY, Vector3(0, by + dh + 0.6, D + 0.4), Vector3(dw, 1.2, 0.8), fr, faces_f - CityGeo.PX - CityGeo.NX)
		st.box(Transform3D.IDENTITY, Vector3(0, by + dh * 0.5, D + 0.2), Vector3(dw, dh, 0.4), MissionProps.c("marking_yellow"), CityGeo.PZ)
		var dr := Rect2(-dw * 0.5, by, dw, dh)
		var stripe := 1.1
		MissionProps.stripes(st, Transform3D.IDENTITY, Rect2(dr.position, Vector2(dw * 0.5, dh)), D + 0.425, stripe, 1.0, MissionProps.c("m_recess"))
		MissionProps.stripes(st, Transform3D.IDENTITY, Rect2(dr.position + Vector2(dw * 0.5, 0), Vector2(dw * 0.5, dh)), D + 0.425, stripe, -1.0, MissionProps.c("m_recess"))
		st.box(Transform3D.IDENTITY, Vector3(0, by + dh * 0.5, D + 0.5), Vector3(0.3, dh, 0.1), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
		add_child(MissionProps.mesh(st, "Bay", layer))
		lights_on = MissionProps.mesh(lg, "BayLights", layer, MissionProps.glow("strip", 3.0))
		lights_on.visible = false
		add_child(lights_on)
		lights_off = MissionProps.mesh(lg, "BayLightsOff", layer, MissionProps.flat("metal_dark"))
		add_child(lights_off)
		if air:
			_air_floor(layer)
			return
		# The floor and its guide lines, on the deck's facets (district coordinates; the mesh undoes the frame).
		var fl := CityGeo.new(d.ring)
		fl.tag("mission.bay_floor")
		var col := MissionProps.c("asphalt_dark")
		_g_box(fl, arc(-w_out, 0.0), arc(w_out, CityStreets.WALL_THICK), 0.03, col)
		_g_box(fl, arc(-ihalf, CityStreets.WALL_THICK), arc(ihalf, bay_depth), 0.03, col)
		var yl := MissionProps.c("marking_yellow")
		for k: float in [-1.0, 1.0]:
			var lx := k * (half - 1.4)
			_g_box(fl, arc(lx - 0.18, -1.2), arc(lx + 0.18, bay_depth - 1.0), 0.07, yl)
		_g_box(fl, arc(-(half - 1.22), USE_FROM - 0.6), arc(half - 1.22, USE_FROM - 0.25), 0.07, yl)
		var fm := MissionProps.mesh(fl, "BayFloor", layer)
		fm.transform = inv
		add_child(fm)

	# An air door's floor: flat in its frame (a 14 m recess high on the wall), guide lines out over the sill ledge.
	func _air_floor(layer: int) -> void:
		var fl := CityGeo.new()
		fl.tag("mission.bay_floor")
		var col := MissionProps.c("asphalt_dark")
		var F := -CityStreets.WALL_THICK
		_floor_quad(fl, -w_out, w_out, 0.0, F, 0.03, col)
		_floor_quad(fl, -ihalf, ihalf, F, -bay_depth, 0.03, col)
		for k: float in [-1.0, 1.0]:
			var lx := k * (half - 1.2)
			_floor_quad(fl, lx - 0.18, lx + 0.18, AIR_LEDGE - 0.2, -bay_depth + 1.0, 0.07, MissionProps.c("marking_yellow"))
		add_child(MissionProps.mesh(fl, "BayFloor", layer))

	static func _floor_quad(g: CityGeo, x0: float, x1: float, z_hi: float, z_lo: float, y: float, col: Color) -> void:
		g.quad(Vector3(x0, y, z_hi), Vector3(x1, y, z_hi), Vector3(x1, y, z_lo), Vector3(x0, y, z_lo), col)

	# The bunker frame on the street side: sloped jambs, a deep lintel with a recess for the lamps, a pier with the sign panel.
	func _build_bunker(layer: int) -> void:
		var bg := CityGeo.new()
		bg.tag("mission.bunker")
		var face := MissionProps.c("sidewalk")         # pale concrete, as the reference
		var sidec := MissionProps.c("concrete")
		var top := gh + lintel_h
		var I := Transform3D.IDENTITY
		var right: Array[Vector2] = [Vector2(half, 0), Vector2(half + jamb + butt, 0), Vector2(half + jamb, gh), Vector2(half, gh)]
		var left: Array[Vector2] = [Vector2(-half - jamb - butt, 0), Vector2(-half, 0), Vector2(-half, gh), Vector2(-half - jamb, gh)]
		MissionProps.extrude(bg, I, right, 0.0, frame_out, face, true, false, [0, 2], sidec)
		MissionProps.extrude(bg, I, left, 0.0, frame_out, face, true, false, [0, 2], sidec)
		# The lintel, extruded along X from a side profile (u = z, v = y): back beam, the lamp recess's ceiling, the
		# chamfered front fascia.
		var L := half + jamb + 0.5
		var lx := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0)), Vector3.ZERO)
		var fo := frame_out
		var pa: Array[Vector2] = [Vector2(0, gh), Vector2(0.6, gh), Vector2(0.6, top), Vector2(0, top)]
		var pb: Array[Vector2] = [Vector2(0.6, gh + 0.5), Vector2(fo - 0.2, gh + 0.5), Vector2(fo - 0.2, top), Vector2(0.6, top)]
		var pc: Array[Vector2] = [Vector2(fo - 0.2, gh), Vector2(fo + 0.4, gh), Vector2(fo + 0.4, top - 0.6), Vector2(fo - 0.2, top)]
		MissionProps.extrude(bg, lx, pa, -L, L, sidec, true, true, [3], face)
		MissionProps.extrude(bg, lx, pb, -L, L, sidec, true, true, [1, 3], face)
		MissionProps.extrude(bg, lx, pc, -L, L, sidec, true, true, [], face)
		# Beacon housings on the lintel over the jambs.
		for x: float in [-(half + jamb * 0.5), half + jamb * 0.5]:
			bg.box(I, Vector3(x, top + 0.2, 1.0), Vector3(1.8, 0.4, 1.8), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NY)
		if air:      # a sill ledge (a landing lip, its top level with the recess floor) instead of the sign pier
			bg.box(I, Vector3(0, -AIR_LEDGE_T * 0.5, AIR_LEDGE * 0.5), Vector3((half + jamb + butt) * 2.0, AIR_LEDGE_T, AIR_LEDGE), face, CityGeo.ALL - CityGeo.NZ)
			add_child(MissionProps.mesh(bg, "Bunker", layer))
			return
		# The sign pier beside the +X buttress: a plain flat face (PANEL at PANEL_Y), kept clean for a stencil.
		var px0 := half + jamb + butt + 0.3
		var pw := PANEL.x + 0.8
		var ph := PANEL_Y + PANEL.y * 0.5 + 1.0
		bg.box(I, Vector3(px0 + pw * 0.5, ph * 0.5, PIER_OUT * 0.5), Vector3(pw, ph, PIER_OUT), face, CityGeo.ALL - CityGeo.NZ - CityGeo.NY)
		panel_xf = Transform3D(Basis.IDENTITY, Vector3(px0 + pw * 0.5, PANEL_Y, PIER_OUT))
		add_child(MissionProps.mesh(bg, "Bunker", layer))

	# Two steel leaves with ribs, panel lines and a yellow / black hazard band each.
	func _build_leaves(layer: int) -> void:
		for k: float in [-1.0, 1.0]:
			var leaf := Node3D.new()
			leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
			var lg := CityGeo.new()
			lg.tag("mission.leaf")
			var lw := half
			lg.box(Transform3D.IDENTITY, Vector3(0, gh * 0.5, LEAF_Z - 0.5), Vector3(lw, gh, 1.0), MissionProps.c("m_leaf"))
			var y := 1.4
			while y < gh - 0.8:
				if absf(y - gh * 0.5) > 1.0:
					lg.box(Transform3D.IDENTITY, Vector3(0, y, LEAF_Z + 0.05), Vector3(lw - 0.4, 0.3, 0.1), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
				y += 2.2
			lg.box(Transform3D.IDENTITY, Vector3(k * lw * 0.12, gh * 0.5, LEAF_Z + 0.04), Vector3(0.14, gh - 0.6, 0.08), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
			var band := Rect2(-lw * 0.42, gh * 0.5 - 0.55, lw * 0.84, 1.1)
			lg.box(Transform3D.IDENTITY, Vector3(band.get_center().x, band.get_center().y, LEAF_Z + 0.09), Vector3(band.size.x, band.size.y, 0.1),
					MissionProps.c("marking_yellow"), CityGeo.ALL - CityGeo.NZ)
			MissionProps.stripes(lg, Transform3D.IDENTITY, band, LEAF_Z + 0.165, 0.32, k, MissionProps.c("m_recess"))
			lg.box(Transform3D.IDENTITY, Vector3(-k * (lw * 0.5 - 0.2), gh * 0.5, LEAF_Z + 0.06), Vector3(0.4, gh, 0.12), MissionProps.c("metal"), CityGeo.ALL - CityGeo.NZ)
			leaf.add_child(MissionProps.mesh(lg, "Mesh", layer, null, true))
			leaf.position = Vector3(k * half * 0.5, 0, 0)
			add_child(leaf)
			leaves.append(leaf)

	# Round amber lamps recessed in the lintel (two, four on a wide gate), in a left and a right group; beacons on the lintel.
	func _build_lamps(layer: int) -> void:
		var xs: Array[float] = [-half * 0.5, half * 0.5]
		if half > 10.0:
			xs = [-half * 0.75, -half * 0.25, half * 0.25, half * 0.75]
		var zc := (0.6 + frame_out - 0.2) * 0.5
		var lr := minf(0.5, (frame_out - 0.8) * 0.5 - 0.04)    # the lamp fits the lintel's recess (0.6 .. frame_out - 0.2)
		for grp in 2:
			var lit := CityGeo.new()
			var idle := CityGeo.new()
			lit.tag("mission.lamp")
			idle.tag("mission.lamp")
			for x in xs:
				if (x < 0.0) != (grp == 0):
					continue
				lit.prism(Transform3D.IDENTITY, Vector3(x, gh + 0.12, zc), lr, 0.38, 10, MissionProps.c("m_beacon"), -1.0, null, MissionProps.c("m_beacon"))
				idle.prism(Transform3D.IDENTITY, Vector3(x, gh + 0.12, zc), lr, 0.38, 10, MissionProps.c("m_beacon_dead"), -1.0, null, MissionProps.c("m_beacon_dead"))
			var lm := MissionProps.mesh(lit, "Lamps%s" % ("L" if grp == 0 else "R"), layer, MissionProps.glow("m_beacon", 6.0))
			lm.visible = false
			add_child(lm)
			wigwag.append(lm)
			var im := MissionProps.mesh(idle, "LampsIdle%s" % ("L" if grp == 0 else "R"), layer)
			add_child(im)
			wigwag_idle.append(im)
		var top := gh + lintel_h
		for x: float in [-(half + jamb * 0.5), half + jamb * 0.5]:
			var lit := Node3D.new()
			lit.name = "BeaconLit"
			lit.position = Vector3(x, top + 0.4, 1.0)
			var core := CityGeo.new()
			core.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6, 1.3, 6, MissionProps.c("m_beacon"))
			lit.add_child(MissionProps.mesh(core, "Core", layer, MissionProps.glow("m_beacon", 3.0)))
			var pad := CityGeo.new()
			pad.box(Transform3D.IDENTITY, Vector3(0, 0.65, 0), Vector3(3.0, 0.75, 0.16), MissionProps.c("m_beacon"))
			pad.box(Transform3D.IDENTITY, Vector3(0, 0.65, 0), Vector3(0.16, 0.75, 3.0), MissionProps.c("m_beacon"))
			lit.add_child(MissionProps.mesh(pad, "Paddles", layer, MissionProps.glow("m_beacon", 5.0)))
			lit.visible = false
			add_child(lit)
			beacons_lit.append(lit)
			var ig := CityGeo.new()
			ig.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6, 1.3, 6, MissionProps.c("m_beacon_dead"))
			var im := MissionProps.mesh(ig, "BeaconIdle", layer)
			im.position = lit.position
			add_child(im)
			beacons_idle.append(im)

	# Sealed: welded bars in an X and across, a bright weld seam, scorch on the leaves.
	func _build_sealed(layer: int, look: RandomNumberGenerator) -> void:
		var sl := CityGeo.new()
		sl.tag("mission.sealed")
		var diag := atan2(gh - 1.0, half * 2.0 - 1.0)
		var dl := Vector2(half * 2.0 - 1.0, gh - 1.0).length()
		for k: float in [-1.0, 1.0]:
			sl.box(Transform3D(Basis(Vector3.BACK, k * diag), Vector3(0, gh * 0.5, 0.25 + 0.3 * (k + 1.0))), Vector3.ZERO, Vector3(dl, 0.5, 0.25), MissionProps.c("m_weld"))
		for y2: float in [gh * 0.3, gh * 0.7]:
			sl.box(Transform3D.IDENTITY, Vector3(0, y2, 0.2), Vector3(half * 2.0, 0.6, 0.2), MissionProps.c("m_weld"))
		sl.box(Transform3D.IDENTITY, Vector3(0, gh * 0.5, 0.05), Vector3(0.25, gh - 0.4, 0.06), MissionProps.c("marking"))
		var n := look.randi_range(5, 8)
		for i in n:
			var cx := look.randf_range(-half + 1.0, half - 1.0)
			var cy := look.randf_range(0.6, gh - 1.0)
			var r := look.randf_range(0.8, 2.2)
			var pts: Array[Vector3] = []
			for j in 6:
				var a := TAU * float(j) / 6.0 + look.randf_range(-0.3, 0.3)
				var rr := r * look.randf_range(0.6, 1.0)
				pts.append(Vector3(cx + cos(a) * rr, clampf(cy + sin(a) * rr, 0.05, gh - 0.05), LEAF_Z + 0.2 + 0.002 * float(i)))
			for j in 6:
				sl.tri(Vector3(cx, cy, pts[0].z), pts[(j + 1) % 6], pts[j], MissionProps.c("m_scorch"))
		sealed_look = MissionProps.mesh(sl, "Sealed", layer)
		sealed_look.visible = false
		add_child(sealed_look)

	func _build_collision(d: CityDistrict, geo_d: CityGeo, inv: Transform3D) -> void:
		body = MissionProps.body_like(d, "DoorBody")
		add_child(body)
		var I := Transform3D.IDENTITY
		door_shape = MissionProps.box_shape(body, I, Vector3(0, gh * 0.5, -1.4), Vector3(w_out * 2.0, gh, 2.8))
		# The bay: sides, back and roof in the frame; they reach 1 m into the wall's slab and past each other's edges.
		var z0 := -CityStreets.WALL_THICK + 1.0
		var z1 := -bay_depth - PLATE
		var y0 := -2.0
		var y1 := room_h + PLATE + 0.5
		var zc := (z0 + z1) * 0.5
		for k: float in [-1.0, 1.0]:
			MissionProps.box_shape(body, I, Vector3(k * (ihalf + PLATE * 0.5), (y0 + y1) * 0.5, zc), Vector3(PLATE, y1 - y0, z0 - z1))
		MissionProps.box_shape(body, I, Vector3(0, (y0 + y1) * 0.5, -bay_depth - PLATE * 0.5), Vector3((ihalf + PLATE) * 2.0, y1 - y0, PLATE))
		MissionProps.box_shape(body, I, Vector3(0, room_h + PLATE * 0.5, zc), Vector3((ihalf + PLATE) * 2.0, PLATE, z0 - z1))
		if air:
			# An air door: one flat floor plate from the wall plane to past the back wall, and the sill ledge.
			MissionProps.box_shape(body, I, Vector3(0, -PLATE * 0.5, z1 * 0.5), Vector3((ihalf + PLATE) * 2.0, PLATE, -z1))
			MissionProps.box_shape(body, I, Vector3(0, -AIR_LEDGE_T * 0.5, AIR_LEDGE * 0.5), Vector3((half + jamb + butt) * 2.0, AIR_LEDGE_T, AIR_LEDGE))
		else:
			# The floor: one slab per deck facet, as CityDistrict._col_floor (no seam or step where it meets the deck's own).
			var a0 := arc(-(ihalf + PLATE), 0.0)
			var a1 := arc(ihalf + PLATE, bay_depth + PLATE)
			var r := Rect2(a0, Vector2.ZERO).expand(a1)
			var br := CityGeo.breaks(r.position.y, r.end.y)
			for k in br.size() - 1:
				var length := geo_d.g_point(0.0, br[k]).distance_to(geo_d.g_point(0.0, br[k + 1]))
				var xf := geo_d.frame(r.get_center().x, (br[k] + br[k + 1]) * 0.5, 0.0)
				MissionProps.box_shape(body, inv * xf, Vector3(0, -0.5, 0), Vector3(r.size.x, 1.0, length + CityDistrict.SEAM))
		# The bunker: jambs with their buttresses, the lintel, the sign pier.
		var top := gh + lintel_h
		for k: float in [-1.0, 1.0]:
			var pts := PackedVector3Array()
			for p: Vector2 in [Vector2(half, 0), Vector2(half + jamb + butt, 0), Vector2(half + jamb, gh), Vector2(half, gh)]:
				for zz: float in [0.0, frame_out]:
					pts.append(Vector3(k * p.x, p.y, zz))
			MissionProps.convex_shape(body, I, pts)
		MissionProps.box_shape(body, I, Vector3(0, (gh + top) * 0.5, (frame_out + 0.4) * 0.5), Vector3((half + jamb + 0.5) * 2.0, lintel_h, frame_out + 0.4))
		if air:
			return
		var px0 := half + jamb + butt + 0.3
		var pw := PANEL.x + 0.8
		var ph := PANEL_Y + PANEL.y * 0.5 + 1.0
		MissionProps.box_shape(body, I, Vector3(px0 + pw * 0.5, ph * 0.5, PIER_OUT * 0.5), Vector3(pw, ph, PIER_OUT))

	# Faces turned one way (CityGeo.quad: counter-clockwise from the front).
	static func _face_px(g: CityGeo, x: float, z_hi: float, z_lo: float, y0: float, y1: float, col: Color) -> void:
		g.quad(Vector3(x, y0, z_hi), Vector3(x, y0, z_lo), Vector3(x, y1, z_lo), Vector3(x, y1, z_hi), col)

	static func _face_nx(g: CityGeo, x: float, z_hi: float, z_lo: float, y0: float, y1: float, col: Color) -> void:
		g.quad(Vector3(x, y0, z_lo), Vector3(x, y0, z_hi), Vector3(x, y1, z_hi), Vector3(x, y1, z_lo), col)

	static func _face_ny(g: CityGeo, x0: float, x1: float, z_hi: float, z_lo: float, y: float, col: Color) -> void:
		g.quad(Vector3(x0, y, z_hi), Vector3(x0, y, z_lo), Vector3(x1, y, z_lo), Vector3(x1, y, z_hi), col)

	static func _face_pz(g: CityGeo, x0: float, x1: float, y0: float, y1: float, z: float, col: Color) -> void:
		g.quad(Vector3(x0, y0, z), Vector3(x1, y0, z), Vector3(x1, y1, z), Vector3(x0, y1, z), col)

	static func _face_nz(g: CityGeo, x0: float, x1: float, y0: float, y1: float, z: float, col: Color) -> void:
		g.quad(Vector3(x1, y0, z), Vector3(x0, y0, z), Vector3(x0, y1, z), Vector3(x1, y1, z), col)

	## A floor rect between arc corners a and b at height h on the facets.
	static func _g_box(g: CityGeo, a: Vector2, b: Vector2, h: float, col: Color) -> void:
		var r := Rect2(a, Vector2.ZERO).expand(b)
		g.g_rect(r.position.x, r.end.x, r.position.y, r.end.y, h, col)

	## state: shut | warn | opening | open | closing | sealed; u 0..1 through opening / closing; t the clock (beacon turn,
	## lamp flash); alarm: the door's alarm is on (MissionWorld.alarm_on: while the leaves open); audible: and the siren
	## plays here (the viewer's deck).
	func pose(state: String, u: float, t: float, alarm: bool = false, audible: Variant = null) -> void:
		var open := 0.0
		match state:
			"opening": open = smoothstep(0.0, 1.0, u)
			"open": open = 1.0
			"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
		for i in leaves.size():
			var k := -1.0 if i == 0 else 1.0
			leaves[i].position.x = k * half * (0.5 + open)
		for b in beacons_lit:
			b.visible = alarm
			if alarm:
				(b.get_child(1) as Node3D).rotation.y = fposmod(t * TAU * 1.25, TAU)
		for b in beacons_idle:
			b.visible = not alarm
		var side := fposmod(t, 0.8) < 0.4
		for i in wigwag.size():
			wigwag[i].visible = alarm and (side == (i == 0))
			wigwag_idle[i].visible = not wigwag[i].visible
		var lit := state == "warn" or state == "opening" or state == "open" or state == "closing"
		lights_on.visible = lit
		lights_off.visible = not lit
		sealed_look.visible = state == "sealed"
		var play: bool = alarm if audible == null else bool(audible)
		if play != siren_on:
			siren_on = play
			MissionSound.set_siren(siren, play, t)

	func lamps_lit() -> bool:
		return not beacons_lit.is_empty() and beacons_lit[0].visible

	func blocks(state: String) -> bool:
		return state == "shut" or state == "warn" or state == "opening" or state == "sealed"

	## Where the WarnLight hangs while the door opens and stands open: high in the bay, lighting what waits there.
	func light_point() -> Vector3:
		if air:
			return Vector3(0, room_h - 1.5, -bay_depth * 0.5)
		return Vector3(0, room_h - 4.0, -(USE_FROM + USE_TO) * 0.5)

	func world_point() -> Vector3:
		return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)


# --- Wave door in a freight lift -----------------------------------------------------------------------------------------

## The freight lift's doors on one deck: two leaves on a track in front of the baked door pane (CityBuildings._pillar: a
## 10 x 8 m door on the core's `front` face), sliding apart to show the lit car; five lamps over the door count down the
## last 5 s (amber, one goes out a second) and all turn green when the doors open. No collision: the core is solid.
class LiftDoor extends Node3D:
	const W := 5.0
	const H := 8.0
	var leaves: Array[Node3D] = []
	var car: Node3D
	var lamps: Array[Node3D] = []
	var go: Node3D

	func build(d: CityDistrict, bi: int) -> void:
		var layer := d.render_layer
		var b: Dictionary = d.plan.buildings[bi]
		var front := int(b["front"])
		var size: Vector2 = b["core"]["size"]
		var n2: Vector2 = CityPlan.SIDE_N[front]
		var n := Vector3(n2.x, 0.0, n2.y)
		var depth := size.x if front < 2 else size.y
		transform = d.core_frame(bi) * Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), n * depth * 0.5)
		var st := CityGeo.new()
		st.box(Transform3D.IDENTITY, Vector3(0, H + 0.2, 0.86), Vector3(W * 4.2, 0.4, 0.3), MissionProps.c("metal_dark"))
		for i in 5:
			st.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.4), Vector3(0.8, 0.8, 0.8), MissionProps.c("metal_dark"))
		add_child(MissionProps.mesh(st, "Track", layer))
		car = Node3D.new()
		car.name = "Car"
		var cg := CityGeo.new()
		cg.quad(Vector3(-W, 0, 0.6), Vector3(W, 0, 0.6), Vector3(W, H, 0.6), Vector3(-W, H, 0.6), MissionProps.c("m_recess"))
		car.add_child(MissionProps.mesh(cg, "Inside", layer))
		var lg := CityGeo.new()
		lg.box(Transform3D.IDENTITY, Vector3(0, 0.15, 0.63), Vector3(W * 2.0 - 0.4, 0.3, 0.04), MissionProps.c("strip"))
		lg.box(Transform3D.IDENTITY, Vector3(0, H - 0.4, 0.63), Vector3(W * 2.0 - 0.8, 0.3, 0.04), MissionProps.c("strip"))
		car.add_child(MissionProps.mesh(lg, "Light", layer, MissionProps.glow("strip", 3.0)))
		car.visible = false
		add_child(car)
		for k: float in [-1.0, 1.0]:
			var leaf := Node3D.new()
			leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
			var g := CityGeo.new()
			g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 0.86), Vector3(W, H, 0.28), MissionProps.c("m_leaf"))
			g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 1.01), Vector3(W - 0.6, 0.8, 0.04), MissionProps.c("marking_yellow"))
			g.box(Transform3D.IDENTITY, Vector3(-k * (W * 0.5 - 0.15), H * 0.5, 1.01), Vector3(0.3, H, 0.04), MissionProps.c("metal"))
			leaf.add_child(MissionProps.mesh(g, "Mesh", layer, null, true))
			leaf.position = Vector3(k * W * 0.5, 0, 0)
			add_child(leaf)
			leaves.append(leaf)
		for i in 5:
			var lamp := Node3D.new()
			lamp.name = "Lamp%d" % i
			var g := CityGeo.new()
			g.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_beacon"))
			lamp.add_child(MissionProps.mesh(g, "Lit", layer, MissionProps.glow("m_beacon", 4.0)))
			lamp.visible = false
			add_child(lamp)
			lamps.append(lamp)
		go = Node3D.new()
		go.name = "Go"
		var gg := CityGeo.new()
		for i in 5:
			gg.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_done"))
		go.add_child(MissionProps.mesh(gg, "Lit", layer, MissionProps.glow("m_done", 4.0)))
		go.visible = false
		add_child(go)

	## state as GateDoor.pose; `left` = seconds to open_at (the countdown).
	func pose(state: String, u: float, left: float) -> void:
		var open := 0.0
		match state:
			"opening": open = smoothstep(0.0, 1.0, u)
			"open": open = 1.0
			"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
		for i in leaves.size():
			var k := -1.0 if i == 0 else 1.0
			leaves[i].position.x = k * W * (0.5 + open)
		car.visible = open > 0.0
		var counting := state == "warn" or state == "opening"     # left = s to open_at, when the doors start to move
		for i in lamps.size():
			lamps[i].visible = counting and left > float(i)
		go.visible = state == "open" or (state == "opening" and u > 0.5)

	func blocks(_state: String) -> bool:
		return false

	func world_point() -> Vector3:
		return global_transform * Vector3(0, H * 0.5, 2.0) if is_inside_tree() else transform * Vector3(0, H * 0.5, 2.0)


# --- Flag mast -----------------------------------------------------------------------------------------------------------

## A 16 m mast (0.55 m pole) on a stepped base, a yard at the top, and two banners about 5 x 3.2 m that differ in SHAPE as
## well as colour: the alien one dark, torn and angular (a ragged swallowtail) with a harsh dark-red emblem block and a
## glowing slit; ours a clean rectangle in the crew's safety orange with a bright cream stripe. pose(raised, from, u)
## plays the swap: the banner up comes down over the first half, the other goes up over the second. Slim collision: the
## pole (r 0.6) and the base.
class FlagMast extends Node3D:
	const POLE := 16.0
	const TOP := 15.4        ## banner top when raised (under the yard)
	const LOW := 5.2         ## banner top when lowered
	const W := 5.0
	const H := 3.2
	var alien: Node3D
	var ours: Node3D
	var body: StaticBody3D

	func build(d: CityDistrict, xf: Transform3D) -> void:
		var layer := d.render_layer
		transform = xf
		var st := CityGeo.new()
		var I := Transform3D.IDENTITY
		st.box(I, Vector3(0, 0.2, 0), Vector3(3.6, 0.8, 3.6), MissionProps.c("concrete_dark"))
		st.box(I, Vector3(0, 0.85, 0), Vector3(2.6, 0.5, 2.6), MissionProps.c("concrete"))
		st.box(I, Vector3(0, 1.35, 0), Vector3(1.6, 0.5, 1.6), MissionProps.c("concrete_dark"))
		st.prism(I, Vector3(0, 1.6, 0), 0.55, POLE - 1.6, 8, MissionProps.c("metal"), 0.4)
		for y: float in [3.0, 3.8]:
			st.prism(I, Vector3(0, y, 0), 0.62, 0.4, 8, MissionProps.c("marking_yellow"))
		st.box(I, Vector3(W * 0.5 + 0.3, TOP + 0.2, 0), Vector3(W + 1.2, 0.35, 0.35), MissionProps.c("metal_dark"))
		st.prism(I, Vector3(0, POLE, 0), 0.55, 0.7, 8, MissionProps.c("marking_yellow"), 0.0)
		add_child(MissionProps.mesh(st, "Mast", layer, null, true))
		alien = Node3D.new()
		alien.name = "Alien"
		var ag := CityGeo.new()
		var torn: Array[Vector2] = [Vector2(0.4, 0), Vector2(0.4, -2.6), Vector2(1.2, -3.4), Vector2(1.8, -2.6), Vector2(2.9, -1.9),
				Vector2(3.6, -2.9), Vector2(4.5, -3.5), Vector2(4.9, -2.4), Vector2(5.4, -2.7), Vector2(5.0, -1.5), Vector2(5.5, -0.9),
				Vector2(5.0, 0)]
		MissionProps.flat_poly(ag, torn, 0.05, MissionProps.c("m_alien"))
		ag.box(Transform3D(Basis(Vector3.BACK, 0.18), Vector3(2.9, -1.15, 0)), Vector3.ZERO, Vector3(1.7, 1.3, 0.2), MissionProps.c("m_alien_mark"))
		for k: float in [-1.0, 1.0]:
			ag.box(Transform3D(Basis(Vector3.BACK, k * 0.75), Vector3(2.9 + k * 0.95, -2.0, 0)), Vector3.ZERO, Vector3(1.0, 0.28, 0.16), MissionProps.c("m_alien_mark"))
		alien.add_child(MissionProps.mesh(ag, "Banner", layer, null, true))
		var eye := CityGeo.new()
		eye.box(I, Vector3(2.9, -1.15, 0), Vector3(1.1, 0.26, 0.26), MissionProps.c("m_hostile"))
		alien.add_child(MissionProps.mesh(eye, "Eye", layer, MissionProps.glow("m_hostile", 4.0)))
		add_child(alien)
		ours = Node3D.new()
		ours.name = "Ours"
		var og := CityGeo.new()
		og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, H, 0.1), MissionProps.c("m_ours"))
		og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, 0.7, 0.16), MissionProps.c("m_ours_mark"))
		og.box(I, Vector3(0.4 + W * 0.5, -0.12, 0), Vector3(W, 0.24, 0.14), MissionProps.c("m_ours_mark"))
		ours.add_child(MissionProps.mesh(og, "Banner", layer, null, true))
		add_child(ours)
		body = MissionProps.body_like(d, "FlagBody")
		add_child(body)
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.6
		cyl.height = POLE
		cs.shape = cyl
		cs.position = Vector3(0, POLE * 0.5, 0)
		body.add_child(cs)
		MissionProps.box_shape(body, I, Vector3(0, 0.6, 0), Vector3(3.6, 1.6, 3.6))
		pose(false, false, 1.0)

	## raised: ours is (going) up; from: what was up before the last swap; u 0..1 through the swap.
	func pose(raised: bool, from: bool, u: float) -> void:
		var up_node := ours if raised else alien
		var down_node := alien if raised else ours
		if raised == from or u >= 1.0:
			up_node.visible = true
			up_node.position.y = TOP
			down_node.visible = false
			return
		if u < 0.5:
			down_node.visible = true
			down_node.position.y = lerpf(TOP, LOW, u * 2.0)
			up_node.visible = false
		else:
			down_node.visible = false
			up_node.visible = true
			up_node.position.y = lerpf(LOW, TOP, u * 2.0 - 1.0)

	func world_point() -> Vector3:
		return global_transform * Vector3(0, TOP, 0) if is_inside_tree() else transform * Vector3(0, TOP, 0)


## A flat polygon `pts` (counter-clockwise in local x / y, star-shaped round its centroid) drawn on both sides, `half`
## either side of z = 0.
static func flat_poly(geo: CityGeo, pts: Array[Vector2], half: float, col: Color) -> void:
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		geo.tri(Vector3(c.x, c.y, half), Vector3(a.x, a.y, half), Vector3(b.x, b.y, half), col)
		geo.tri(Vector3(c.x, c.y, -half), Vector3(b.x, b.y, -half), Vector3(a.x, a.y, -half), col)


# --- Defend asset ----------------------------------------------------------------------------------------------------------

## A relay about 6 m to the dish's rim on a plinth: a cabinet with a bold blinking cyan band, a mast, a big dish and a tall
## thin antenna (8.6 m, glowing tip) that marks it above parked props. look(level): 0 intact, 1 damaged (dish knocked
## askew, antenna bent, sparks and smoke), 2 wreck (cabinet slumped and scorched, mast snapped with its top on the
## ground, dish fallen on its rim, antenna down, nothing glows). `body` is the damageable target (MissionWorld puts it in
## group "mission_asset" with meta objective_id); the look never changes it.
class RelayAsset extends Node3D:
	var intact: Node3D
	var dish: Node3D
	var antenna: Node3D
	var band_on: MeshInstance3D
	var band_off: MeshInstance3D
	var wreck: MeshInstance3D
	var sparks: CPUParticles3D
	var smoke: CPUParticles3D
	var body: StaticBody3D
	var level := 0

	func build(d: CityDistrict, xf: Transform3D) -> void:
		var layer := d.render_layer
		transform = xf
		var I := Transform3D.IDENTITY
		var st := CityGeo.new()
		st.box(I, Vector3(0, 0.4, 0), Vector3(4.2, 1.2, 4.2), MissionProps.c("concrete_dark"))
		for k: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			st.box(I, Vector3(k.x * 1.8, 1.15, k.y * 1.8), Vector3(0.6, 0.3, 0.6), MissionProps.c("marking_yellow"))
		add_child(MissionProps.mesh(st, "Plinth", layer, null, true))
		intact = Node3D.new()
		intact.name = "Intact"
		var ig := CityGeo.new()
		ig.box(I, Vector3(0, 2.6, 0), Vector3(2.8, 2.8, 2.8), MissionProps.c("m_relay"))
		ig.box(I, Vector3(0, 4.1, 0), Vector3(3.2, 0.3, 3.2), MissionProps.c("metal_dark"))
		ig.prism(I, Vector3(0, 4.2, 0), 0.32, 1.4, 6, MissionProps.c("metal"))
		intact.add_child(MissionProps.mesh(ig, "Body", layer, null, true))
		var bg := CityGeo.new()
		bg.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay_band"))
		band_on = MissionProps.mesh(bg, "BandOn", layer, MissionProps.glow("m_relay_band", 4.5))
		intact.add_child(band_on)
		var bo := CityGeo.new()
		bo.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay").darkened(0.35))
		band_off = MissionProps.mesh(bo, "BandOff", layer)
		band_off.visible = false
		intact.add_child(band_off)
		dish = Node3D.new()
		dish.name = "Dish"
		dish.position = Vector3(0, 5.5, 0)
		var dg := CityGeo.new()
		var tilt := Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3.ZERO)
		dg.prism(tilt, Vector3.ZERO, 0.45, 1.1, 10, MissionProps.c("cream_light"), 2.3, null, MissionProps.c("metal"))
		dg.prism(tilt, Vector3(0, 1.1, 0), 0.1, 1.2, 4, MissionProps.c("metal_dark"))
		dish.add_child(MissionProps.mesh(dg, "Mesh", layer, null, true))
		intact.add_child(dish)
		antenna = Node3D.new()
		antenna.name = "Antenna"
		antenna.position = Vector3(1.1, 4.25, -1.1)
		var ag := CityGeo.new()
		ag.box(I, Vector3(0, 2.15, 0), Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
		for y: float in [1.2, 2.4, 3.4]:
			ag.box(I, Vector3(0, y, 0), Vector3(0.7, 0.08, 0.08), MissionProps.c("metal_dark"))
		antenna.add_child(MissionProps.mesh(ag, "Mast", layer, null, true))
		var tip := CityGeo.new()
		tip.box(I, Vector3(0, 4.4, 0), Vector3(0.32, 0.32, 0.32), MissionProps.c("m_ours"))
		antenna.add_child(MissionProps.mesh(tip, "Tip", layer, MissionProps.glow("m_ours", 4.0)))
		intact.add_child(antenna)
		add_child(intact)
		# The wreck: a slumped, scorched cabinet; the mast's stump and its snapped top on the ground; the dish fallen on its
		# rim; the antenna lying across the plinth.
		var wg := CityGeo.new()
		wg.box(Transform3D(Basis(Vector3(1, 0, 0.4).normalized(), 0.3), Vector3(0.1, 1.9, 0.0)), Vector3.ZERO, Vector3(2.8, 1.6, 2.8), MissionProps.c("m_scorch"))
		wg.box(Transform3D(Basis(Vector3.FORWARD, 0.25), Vector3(0.2, 2.8, 0.0)), Vector3.ZERO, Vector3(3.0, 0.3, 3.0), MissionProps.c("metal_dark"))
		wg.prism(Transform3D(Basis(Vector3.FORWARD, 0.2), Vector3(0.1, 2.9, 0)), Vector3.ZERO, 0.32, 0.8, 6, MissionProps.c("metal_dark"))
		wg.prism(Transform3D(Basis(Vector3.FORWARD, 1.45), Vector3(3.6, 0.35, 0.6)), Vector3.ZERO, 0.3, 2.2, 6, MissionProps.c("metal"))
		wg.prism(Transform3D(Basis(Vector3.RIGHT, 1.5) * Basis(Vector3.UP, 0.3), Vector3(-2.6, 1.6, 2.2)), Vector3.ZERO, 0.45, 1.1, 10,
				MissionProps.c("m_scorch"), 2.3, null, MissionProps.c("metal_dark"))
		wg.box(Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, 1.5), Vector3(-0.4, 1.25, -2.4)), Vector3.ZERO, Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
		wreck = MissionProps.mesh(wg, "Wreck", layer, null, true)
		wreck.visible = false
		add_child(wreck)
		body = MissionProps.body_like(d, "AssetBody")
		add_child(body)
		MissionProps.box_shape(body, I, Vector3(0, 2.5, 0), Vector3(4.2, 5.4, 4.2))

	## Sparks and smoke while damaged (CPUParticles3D, made on first need; none at CityQuality.LOW).
	func _fx(on: bool, layer: int) -> void:
		if on and sparks == null:
			sparks = CPUParticles3D.new()
			sparks.name = "Sparks"
			sparks.amount = 14
			sparks.lifetime = 0.6
			sparks.explosiveness = 0.6
			sparks.direction = Vector3.UP
			sparks.spread = 70.0
			sparks.initial_velocity_min = 3.0
			sparks.initial_velocity_max = 6.0
			sparks.gravity = Vector3(0, -12, 0)
			sparks.scale_amount_min = 0.08
			sparks.scale_amount_max = 0.14
			var qm := BoxMesh.new()
			qm.size = Vector3.ONE
			qm.material = MissionProps.glow("m_beacon", 6.0)
			sparks.mesh = qm
			sparks.layers = layer
			sparks.position = Vector3(0, 4.6, 0)
			add_child(sparks)
			smoke = CPUParticles3D.new()
			smoke.name = "Smoke"
			smoke.amount = 10
			smoke.lifetime = 2.6
			smoke.direction = Vector3.UP
			smoke.spread = 15.0
			smoke.initial_velocity_min = 1.2
			smoke.initial_velocity_max = 2.0
			smoke.gravity = Vector3(0, 0.4, 0)
			smoke.scale_amount_min = 0.6
			smoke.scale_amount_max = 1.2
			var sm := BoxMesh.new()
			sm.size = Vector3.ONE
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.18, 0.17, 0.17)
			mat.roughness = 1.0
			sm.material = mat
			smoke.mesh = sm
			smoke.layers = layer
			smoke.position = Vector3(0, 4.4, 0)
			add_child(smoke)
		if sparks != null:
			sparks.emitting = on
			sparks.visible = on
			smoke.emitting = on
			smoke.visible = on

	## lv 0 intact, 1 damaged, 2 wreck; fx = particles allowed (quality above LOW).
	func look(lv: int, fx: bool, layer: int) -> void:
		level = lv
		intact.visible = lv < 2
		wreck.visible = lv == 2
		dish.position = Vector3(0.6, 4.6, 0.4) if lv == 1 else Vector3(0, 5.5, 0)
		dish.rotation = Vector3(0.9, 0.4, 0.6) if lv == 1 else Vector3.ZERO
		antenna.rotation = Vector3(0.0, 0.0, 0.55) if lv == 1 else Vector3.ZERO
		_fx(lv == 1 and fx, layer)

	func blink(on: bool) -> void:
		band_on.visible = on and level == 0
		band_off.visible = not band_on.visible

	func world_point() -> Vector3:
		return global_transform * Vector3(0, 3.0, 0) if is_inside_tree() else transform * Vector3(0, 3.0, 0)


# --- Extraction portal -----------------------------------------------------------------------------------------------------

## A charging frame in the extraction portal gate: SEGMENTS pairs of segments up both posts and along the lintel to its
## middle, the first `progress` of them lit, and an energy curtain across the opening: none below CURTAIN_FROM, then
## rising from the floor with a bright top edge, thin until 1.0, where it fills the opening and turns solid.
class Portal extends Node3D:
	const SEGMENTS := 12
	const CURTAIN_FROM := 0.15   ## progress below which there is no curtain
	var half := 20.0
	var gh := 14.0
	var lit: Array[Node3D] = []
	var curtain: MeshInstance3D
	var curtain_mat: StandardMaterial3D
	var edge: MeshInstance3D          ## the curtain's bright rising top edge

	func build(d: CityDistrict, w: Dictionary, g: Dictionary) -> void:
		var layer := d.render_layer
		half = MissionProps.gate_half(g)
		gh = float(g["h"])
		transform = MissionProps.gate_frame(d, w, g)
		var off := CityGeo.new()
		var segs := _segments()
		for sg: Array in segs:
			off.box(sg[0], Vector3.ZERO, sg[1], MissionProps.c("m_portal_off"))
		add_child(MissionProps.mesh(off, "Frame", layer))
		for i in SEGMENTS:
			var n := Node3D.new()
			n.name = "Lit%d" % i
			var g2 := CityGeo.new()
			for sg: Array in [segs[i * 2], segs[i * 2 + 1]]:
				g2.box(sg[0], Vector3.ZERO, (sg[1] as Vector3) + Vector3(0.04, 0.04, 0.04), MissionProps.c("m_portal"))
			n.add_child(MissionProps.mesh(g2, "Mesh", layer, MissionProps.glow("m_portal", 4.0)))
			n.visible = false
			add_child(n)
			lit.append(n)
		var cg := CityGeo.new()           # one metre tall: pose() scales it up from the floor
		var x := half - 0.7
		cg.quad(Vector3(-x, 0.0, -0.6), Vector3(x, 0.0, -0.6), Vector3(x, 1.0, -0.6), Vector3(-x, 1.0, -0.6), MissionProps.c("m_portal"))
		curtain_mat = StandardMaterial3D.new()
		curtain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		curtain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		curtain_mat.albedo_color = MissionProps.c("m_portal")
		curtain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		curtain = MissionProps.mesh(cg, "Curtain", layer, curtain_mat)
		curtain.visible = false
		add_child(curtain)
		var eg := CityGeo.new()
		eg.box(Transform3D.IDENTITY, Vector3(0, 0, -0.5), Vector3(x * 2.0, 0.3, 0.2), MissionProps.c("m_portal"))
		edge = MissionProps.mesh(eg, "Edge", layer, MissionProps.glow("m_portal", 5.0))
		edge.visible = false
		add_child(edge)

	## [xf, size] of every segment, in pairs (left, right), bottom of the posts first, the lintel's middle last.
	func _segments() -> Array:
		var out := []
		var post := gh - 0.6
		var top := half - 0.4
		var total := post + top
		var step := total / float(SEGMENTS)
		for i in SEGMENTS:
			var a := step * float(i) + 0.15
			var b := step * float(i + 1) - 0.15
			for k: float in [-1.0, 1.0]:
				if b <= post:
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + b) * 0.5, 1.0)), Vector3(0.7, b - a, 0.6)])
				elif a >= post:
					var u0 := half - 0.4 - (a - post)
					var u1 := half - 0.4 - (b - post)
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (u0 + u1) * 0.5, gh - 0.35, 1.0)), Vector3(absf(u0 - u1), 0.7, 0.6)])
				else:
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + post) * 0.5, 1.0)), Vector3(0.7, post - a, 0.6)])
		return out

	func pose(progress: float) -> void:
		for i in lit.size():
			lit[i].visible = progress >= float(i + 1) / float(SEGMENTS) - 0.0001
		# The curtain: nothing below CURTAIN_FROM, then rising from the floor to the lintel as progress goes to 1, thin at
		# first and solid only at 1 (a bright edge on its top while it rises).
		var f := clampf((progress - CURTAIN_FROM) / (1.0 - CURTAIN_FROM), 0.0, 1.0)
		curtain.visible = f > 0.0
		edge.visible = f > 0.0 and f < 1.0
		var top := 0.1 + (gh - 0.5) * f
		curtain.scale = Vector3(1.0, maxf(top, 0.01), 1.0)
		edge.position.y = top
		var col := MissionProps.c("m_portal")
		col.a = 0.12 + 0.43 * f + (0.35 if f >= 1.0 else 0.0)
		curtain_mat.albedo_color = col

	func world_point() -> Vector3:
		return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)


# --- Ground marks ----------------------------------------------------------------------------------------------------------

## Height of the walking surface at (x, s): curb height on a block (sidewalk, plaza, park), else the road.
static func ground_h(plan: CityPlan, pt: Vector2) -> float:
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).has_point(pt):
			return CityPlan.CURB_H
	return 0.0


## A thin ring of radius r round (x, s) on the faceted floor, 6 cm above whatever it crosses (road or curb), left out over
## floor cuts and inside building footprints. District-local.
static func zone_ring(d: CityDistrict, at: Vector2, r: float, width: float = 0.6) -> CityGeo:
	var geo := CityGeo.new(d.ring)
	var blocked := _blockers(d.plan)
	var cuts := d.plan.floor_cuts()
	var n := maxi(int(TAU * r / 1.5), 24)
	for i in n:
		var a0 := TAU * float(i) / float(n)
		var a1 := TAU * float(i + 1) / float(n)
		var am := (a0 + a1) * 0.5
		var mid := at + Vector2(cos(am), sin(am)) * r
		if _in_rects(blocked, mid) or _in_rects(cuts, mid, CityStreets.HOLE_CURB + 0.2):
			continue
		var h := ground_h(d.plan, mid) + 0.06
		var p0i := at + Vector2(cos(a0), sin(a0)) * (r - width * 0.5)
		var p0o := at + Vector2(cos(a0), sin(a0)) * (r + width * 0.5)
		var p1i := at + Vector2(cos(a1), sin(a1)) * (r - width * 0.5)
		var p1o := at + Vector2(cos(a1), sin(a1)) * (r + width * 0.5)
		geo.g_quad(Vector3(p0i.x, p0i.y, h), Vector3(p0o.x, p0o.y, h), Vector3(p1o.x, p1o.y, h), Vector3(p1i.x, p1i.y, h), c("m_zone"))
	return geo


## The outline of rect z (deck arc coords) on the floor: four bands `width` wide, each cut at the block edges so it sits
## 6 cm above the road on the road and above the curb on a block; corner squares. District-local.
static func zone_rect(d: CityDistrict, z: Rect2, width: float = 0.9) -> CityGeo:
	var geo := CityGeo.new(d.ring)
	geo.holes = d.plan.floor_cuts()
	var bands: Array[Rect2] = [Rect2(z.position.x, z.position.y, z.size.x, width), Rect2(z.position.x, z.end.y - width, z.size.x, width),
			Rect2(z.position.x, z.position.y, width, z.size.y), Rect2(z.end.x - width, z.position.y, width, z.size.y)]
	var blocks: Array[Rect2] = []
	for b: Dictionary in d.plan.blocks:
		blocks.append(b["rect"])
	for band in bands:
		for q in CityGeo.cut(band, blocks):
			geo.g_rect(q.position.x, q.end.x, q.position.y, q.end.y, 0.06, c("m_zone"))
		for bk in blocks:
			if bk.intersects(band):
				var q := bk.intersection(band)
				geo.g_rect(q.position.x, q.end.x, q.position.y, q.end.y, CityPlan.CURB_H + 0.06, c("m_zone"))
	return geo


static func _in_rects(rects: Array, pt: Vector2, grow: float = 0.0) -> bool:
	for r: Rect2 in rects:
		if r.grow(grow).has_point(pt):
			return true
	return false


## Building footprints on a plan (the footprint of every building, and a pillar's core), as Rect2.
static func _blockers(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for b: Dictionary in plan.buildings:
		var sz: Vector2 = b.get("size", Vector2.ZERO)
		if sz.x > 0.0 and not (b["pillar"] and (b["tiers"] as Array).is_empty()):
			out.append(Rect2((b["center"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			var cc := Vector2(float(b["core"]["x"]), float(b["core"]["s"]))
			out.append(Rect2(cc - cs * 0.5, cs))
	return out


# --- Site snapping ---------------------------------------------------------------------------------------------------------

const SNAP_STEP := 1.0        ## m between candidate points
const ROAD_COST := 6.0        ## m a road point counts further away than a sidewalk / plaza point (prefer the latter)
const WALL_MARGIN := 4.0      ## m kept between a placed piece's disc and the boundary walls

## The SNAP RULE (the same on every machine: plan data and the props' initial layout only). Candidates: `site` and every
## point of a SNAP_STEP grid centred on it within `reach` (the snap distance: MissionWorld.snap_reach); each scored by its distance from the site, plus ROAD_COST when
## it is not on a block (sidewalk, plaza, park). In score order (ties: smaller s, then smaller x), the first CLEAR point
## wins: a disc of `clear_r` round it is inside the walls (WALL_MARGIN 4 m to spare), clear of every building footprint and pillar core,
## floor cut (+ its curb), ramp, park column, kept-clear rect, prop (its radius), the ground in front of every wall gate (gate_aprons), the rail lane and the avenue's median, and
## `avoid` ([[Vector2, radius]]: pieces placed before it, e.g. the mast a chained defend relay stands beside).
## Returns {x, s, h (ground height there), snapped: moved off the site, ok: a clear point was found}; when none is, the
## site itself with ok = false.
static func snap_site(d: CityDistrict, site: Vector2, reach: float, clear_r: float, avoid: Array = []) -> Dictionary:
	var plan := d.plan
	var cx := _snap_ctx(d, site, reach, clear_r)
	var blockers: Array[Rect2] = cx["blockers"]
	var cuts: Array[Rect2] = cx["cuts"]
	var items: Array = cx["items"]
	var blocks: Array[Rect2] = cx["blocks"]
	var inner: Rect2 = cx["inner"]
	# Nearest first: a candidate's score is at least its distance, so once the distance passes the best score found
	# nothing later can win; among equal scores the smaller s, then x (the same pick as sorting every candidate).
	var best := []
	for off: Vector2 in _offsets(reach):
		var dist := off.length()
		if not best.is_empty() and dist > float(best[0]) + 1e-9:
			break
		var pt := site + off
		var cost := dist + (0.0 if _in_rects(blocks, pt) else ROAD_COST)
		var key := [cost, pt.y, pt.x]
		if not best.is_empty() and key >= best:
			continue
		if inner.has_point(pt) and clear_at(d, pt, clear_r, blockers, cuts, avoid, items, cx["aprons"]):
			best = key
	if best.is_empty():
		return {"x": site.x, "s": site.y, "h": ground_h(plan, site), "snapped": false, "ok": false}
	var at := Vector2(float(best[2]), float(best[1]))
	return {"x": at.x, "s": at.y, "h": ground_h(plan, at), "snapped": not at.is_equal_approx(site), "ok": true}


## What snap_site checks a candidate against, kept to what can touch a candidate's disc within `reach` of `site` (the same
## answer, far fewer checks over a 45 m reach): {blockers, cuts, items, blocks, inner, aprons}.
static func _snap_ctx(d: CityDistrict, site: Vector2, reach: float, clear_r: float) -> Dictionary:
	var plan := d.plan
	var area := Rect2(site, Vector2.ZERO).grow(reach + clear_r + 1.0)
	var blockers: Array[Rect2] = []
	for b in _blockers(plan):
		if b.intersects(area):
			blockers.append(b)
	var cuts: Array[Rect2] = []
	for o in plan.floor_cuts():
		if o.grow(CityStreets.HOLE_CURB + 1.0).intersects(area):
			cuts.append(o)
	var items := []
	if d.props != null:
		for it: Dictionary in d.props.items:
			if area.grow(3.0).has_point(Vector2(float(it["x"]), float(it["s"]))):
				items.append(it)
	var blocks: Array[Rect2] = []
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).intersects(area):
			blocks.append(b["rect"])
	return {"blockers": blockers, "cuts": cuts, "items": items, "blocks": blocks, "aprons": gate_aprons(plan),
			"inner": plan.extent.grow(-(clear_r + WALL_MARGIN))}


# --- The fit rule: a snapped objective site the widest mech can reach ----------------------------------------------------

const FIT_MARGIN := 0.5        ## m added to CityPlan.MECH_R_MAX: the disc that must get through (a corridor >= 8.2 m)
const FIT_GOAL := 0.9          ## the disc's centre must get within this share of the objective's radius of the site
const FIT_CELL := 1.0          ## m: the reachability grid's cell
const FIT_FALLBACK := 2.0      ## x the snap reach: how far the road-side fallback looks when nothing in reach fits

## The fit radius: the widest player capsule plus the margin.
static func fit_r() -> float:
	return CityPlan.MECH_R_MAX + FIT_MARGIN


## THE FIT RULE (MissionWorld's flag, defend relay sites; plan data only, the same on every machine; opt-in: snap_site
## itself is unchanged for every other caller). First the old rule (snap_site). Its pick stands when a disc of fit_r()
## gets from the deck's walk graph (FitMask) to within FIT_GOAL x `obj_r` of it: then the result is snap_site's,
## byte for byte, plus fit = true, moved_for_fit = false. Otherwise, among the candidates snap_site would accept (inside
## `reach`, clear), in snap_site's order (score, then s, then x), the first that the disc reaches wins. If none does, the
## nearest clear ROAD point (not on a block) within FIT_FALLBACK x reach that it reaches (nearest first, ties smaller s
## then x). If even that fails, snap_site's pick with fit = false. Adds keys: fit, moved_for_fit.
static func snap_site_fit(d: CityDistrict, site: Vector2, reach: float, clear_r: float, avoid: Array, obj_r: float) -> Dictionary:
	var plan := d.plan
	var out := snap_site(d, site, reach, clear_r, avoid)
	var mask := fit_mask(plan)
	var goal_r := obj_r * FIT_GOAL
	var q := mask.query(avoid, goal_r)
	var old_at := Vector2(float(out["x"]), float(out["s"]))
	if q.reaches(old_at):
		out["fit"] = true
		out["moved_for_fit"] = false
		return out
	var cx := _snap_ctx(d, site, reach, clear_r)
	var keyed := []
	for off: Vector2 in _offsets(reach):
		var pt := site + off
		keyed.append([off.length() + (0.0 if _in_rects(cx["blocks"], pt) else ROAD_COST), pt.y, pt.x])
	keyed.sort()
	var picked := Vector2.INF
	for key: Array in keyed:
		var pt := Vector2(float(key[2]), float(key[1]))
		if (cx["inner"] as Rect2).has_point(pt) and clear_at(d, pt, clear_r, cx["blockers"], cx["cuts"], avoid, cx["items"], cx["aprons"]) \
				and q.reaches(pt):
			picked = pt
			break
	if picked == Vector2.INF:
		var far := reach * FIT_FALLBACK
		var fx := _snap_ctx(d, site, far, clear_r)
		for off: Vector2 in _offsets(far):
			var pt := site + off
			if _in_rects(fx["blocks"], pt):
				continue
			if (fx["inner"] as Rect2).has_point(pt) and clear_at(d, pt, clear_r, fx["blockers"], fx["cuts"], avoid, fx["items"], fx["aprons"]) \
					and q.reaches(pt):
				picked = pt
				break
	if picked == Vector2.INF:
		out["fit"] = false
		out["moved_for_fit"] = false
		return out
	return {"x": picked.x, "s": picked.y, "h": ground_h(plan, picked), "snapped": not picked.is_equal_approx(site), "ok": true,
			"fit": true, "moved_for_fit": true}


## Plan `plan`'s reachability mask for the fit disc (cached on the plan: plan data only, built once per deck).
static func fit_mask(plan: CityPlan) -> FitMask:
	var key := "site_fit_mask"
	if plan.has_meta(key):
		var m: FitMask = plan.get_meta(key)
		if m != null and is_equal_approx(m.r, fit_r()):
			return m
	var m := FitMask.new()
	m.build(plan, fit_r())
	plan.set_meta(key, m)
	return m


## Whether plan `plan` already has its fit mask built (MissionWorld builds it in its own setup chunk).
static func has_fit_mask(plan: CityPlan) -> bool:
	return plan.has_meta("site_fit_mask")


## Where a disc of radius `r` (the fit disc) can stand on a deck and where it can get to, from plan data: a FIT_CELL grid
## over the extent. A cell is FREE when the disc centred on it touches nothing a mech cannot walk through below
## CityPlan.MECH_TOP (CityPlan.court_open's obstacles): building tiers and solids lower than MECH_TOP and higher than a
## step (STEP_H), pillar cores, park columns (their ring), floor cuts (+ their curb), ramps (+ 0.5 m parapet), and it stays
## r inside the walls. Sidewalks, curbs, raised courts and street props (knockable) are walkable. SEED cells are free cells on
## the walk graph's edges (CityPlan.walk_graph(): every road, pedestrian street and open court). query(avoid, goal_r)
## answers whether a point's goal disc touches a cell connected (4-neighbour, through free cells clear of the `avoid` discs)
## to a seed.
class FitMask extends RefCounted:
	var r := 0.0
	var origin := Vector2.ZERO
	var cell := FIT_CELL
	var nx := 0
	var ns := 0
	var free := PackedByteArray()    ## 1: the disc fits there (static obstacles)
	var seeds := PackedByteArray()   ## 1: a free cell on a walk-graph edge
	var build_ms := 0.0
	var graph_ms := 0.0              ## of which CityPlan.walk_graph()

	func build(plan: CityPlan, radius: float) -> void:
		var t0 := Time.get_ticks_usec()
		r = radius
		var e := plan.extent
		origin = e.position
		nx = int(ceilf(e.size.x / cell))
		ns = int(ceilf(e.size.y / cell))
		free.resize(nx * ns)
		free.fill(1)
		# The walls: the centre stays r inside the extent.
		var inner := e.grow(-r)
		var x_lo := origin.x - 10.0
		var x_hi := origin.x + float(nx) * cell + 10.0
		for j in ns:
			var cy := origin.y + (float(j) + 0.5) * cell
			if cy <= inner.position.y or cy >= inner.end.y:
				_block_span(j, x_lo, x_hi)
				continue
			_block_span(j, x_lo, inner.position.x + 1e-4)    # centres at or outside the inner edge
			_block_span(j, inner.end.x - 1e-4, x_hi)
		var step_h := CityPlan.STEP_H
		var top := CityPlan.MECH_TOP
		for bi in plan.buildings.size():
			var b: Dictionary = plan.buildings[bi]
			for t: Dictionary in b["tiers"]:
				if float(t["y0"]) < top and float(t["y1"]) > step_h:
					block_rect(plan.tier_rect(bi, t), 0.0)
			for so: Dictionary in b.get("solids", []):
				if float(so["y0"]) < top and float(so["y1"]) > step_h:
					var sz: Vector2 = so["size"]
					block_rect(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz), 0.0)
			if b["pillar"]:
				var cs: Vector2 = b["core"]["size"]
				block_rect(Rect2(Vector2(float(b["core"]["x"]), float(b["core"]["s"])) - cs * 0.5, cs), 0.0)
		for col: Dictionary in plan.columns:
			block_disc(Vector2(float(col["x"]), float(col["s"])), maxf(float(col.get("ring_r", 0.0)), float(col["half"])))
		if plan.site != null:
			for o in plan.floor_cuts():
				block_rect(o, CityStreets.HOLE_CURB)
		for rp: Dictionary in plan.ramps:
			var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
			var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
			block_rect(Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0), 0.5)
		# Seeds: along every walk-graph edge, every half metre.
		seeds.resize(nx * ns)
		seeds.fill(0)
		var tg := Time.get_ticks_usec()
		var g := plan.walk_graph()
		graph_ms = float(Time.get_ticks_usec() - tg) / 1000.0
		var nodes: Array = g["nodes"]
		for ed: Array in g["edges"]:
			var a: Vector2 = nodes[int(ed[0])]
			var bb: Vector2 = nodes[int(ed[1])]
			var n := maxi(int(ceilf(a.distance_to(bb) / 0.5)), 1)
			for k in n + 1:
				var c := index_of(a.lerp(bb, float(k) / float(n)))
				if c >= 0 and free[c] == 1:
					seeds[c] = 1
		build_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	## The cell under point p (-1 off the grid).
	func index_of(p: Vector2) -> int:
		var i := int(floorf((p.x - origin.x) / cell))
		var j := int(floorf((p.y - origin.y) / cell))
		if i < 0 or j < 0 or i >= nx or j >= ns:
			return -1
		return j * nx + i

	func centre(c: int) -> Vector2:
		return origin + Vector2(float(c % nx) + 0.5, float(c / nx) + 0.5) * cell

	## Mark every cell whose centre is closer than r to rect q (grown by `grow`) as blocked: row by row, exact.
	func block_rect(q0: Rect2, grow: float) -> void:
		var q := q0.grow(grow)
		var j0 := maxi(int(floorf((q.position.y - r - origin.y) / cell - 0.5)), 0)
		var j1 := mini(int(ceilf((q.end.y + r - origin.y) / cell - 0.5)), ns - 1)
		for j in range(j0, j1 + 1):
			var cy := origin.y + (float(j) + 0.5) * cell
			var dy := maxf(maxf(q.position.y - cy, cy - q.end.y), 0.0)
			if dy >= r:
				continue
			var ext := sqrt(r * r - dy * dy)
			_block_span(j, q.position.x - ext, q.end.x + ext)

	## Mark every cell whose centre is closer than rad + r to c as blocked.
	func block_disc(c: Vector2, rad: float) -> void:
		var rr := rad + r
		var j0 := maxi(int(floorf((c.y - rr - origin.y) / cell - 0.5)), 0)
		var j1 := mini(int(ceilf((c.y + rr - origin.y) / cell - 0.5)), ns - 1)
		for j in range(j0, j1 + 1):
			var dy := absf(origin.y + (float(j) + 0.5) * cell - c.y)
			if dy >= rr:
				continue
			var ext := sqrt(rr * rr - dy * dy)
			_block_span(j, c.x - ext, c.x + ext)

	# Row j: the cells whose centre lies strictly between x0 and x1.
	func _block_span(j: int, x0: float, x1: float) -> void:
		var i0 := maxi(int(floorf((x0 - origin.x) / cell - 0.5)) + 1, 0)
		var i1 := mini(int(ceilf((x1 - origin.x) / cell - 0.5)) - 1, nx - 1)
		var row := j * nx
		for i in range(i0, i1 + 1):
			free[row + i] = 0

	## A query for one snap call: `avoid` ([[Vector2, radius]], the pieces already standing) block the disc too.
	func query(avoid: Array, goal_r: float) -> FitQuery:
		var fq := FitQuery.new()
		fq.m = self
		fq.avoid = avoid
		fq.goal_r = goal_r
		fq.dead.resize(nx * ns)
		fq.dead.fill(0)
		fq.seen.resize(nx * ns)
		fq.seen.fill(0)
		var n := int(ceilf(goal_r / cell)) + 1
		for dj in range(-n, n + 1):
			for di in range(-n, n + 1):
				fq.disc.append(Vector2i(di, dj))
		return fq


## One snap call's reachability questions on a FitMask (see FitMask.query). reaches(pt): some cell whose centre is within
## goal_r of pt is connected to a seed. Cells found to belong to seedless regions are remembered for the rest of the call.
class FitQuery extends RefCounted:
	var m: FitMask
	var avoid: Array = []
	var goal_r := 0.0
	var disc: Array[Vector2i] = []
	var dead := PackedByteArray()     ## 1: in a region with no seed (explored)
	var seen := PackedInt32Array()    ## BFS stamp per cell
	var stamp := 0
	var cells_visited := 0            ## total BFS work (cells) in this query, for the cost report

	func _open(c: int) -> bool:
		if m.free[c] == 0 or dead[c] == 1:
			return false
		if not avoid.is_empty():
			var p := m.centre(c)
			for av: Array in avoid:
				var rr := float(av[1]) + m.r
				if (av[0] as Vector2).distance_squared_to(p) < rr * rr:
					return false
		return true

	func reaches(pt: Vector2) -> bool:
		stamp += 1
		var q := PackedInt32Array()
		var head := 0
		var ci := int(floorf((pt.x - m.origin.x) / m.cell))
		var cj := int(floorf((pt.y - m.origin.y) / m.cell))
		var g2 := goal_r * goal_r
		for o in disc:
			var i := ci + o.x
			var j := cj + o.y
			if i < 0 or j < 0 or i >= m.nx or j >= m.ns:
				continue
			var c := j * m.nx + i
			if seen[c] == stamp or m.centre(c).distance_squared_to(pt) > g2:
				continue
			seen[c] = stamp
			if not _open(c):
				continue
			if m.seeds[c] == 1:
				return true
			q.append(c)
		while head < q.size():
			var c := q[head]
			head += 1
			cells_visited += 1
			var i := c % m.nx
			for nb: int in [c - 1 if i > 0 else -1, c + 1 if i < m.nx - 1 else -1, c - m.nx, c + m.nx]:
				if nb < 0 or nb >= m.free.size() or seen[nb] == stamp:
					continue
				seen[nb] = stamp
				if not _open(nb):
					continue
				if m.seeds[nb] == 1:
					return true
				q.append(nb)
		# No seed anywhere connected: every cell reached is in a seedless region.
		for c in q:
			dead[c] = 1
		return false


## Every SNAP_STEP grid offset within `reach`, nearest first (ties: smaller y, then x); cached per reach.
static var _offset_cache: Dictionary = {}

static func _offsets(reach: float) -> Array:
	if not _offset_cache.has(reach):
		var keyed := []
		var n := int(floor(reach / SNAP_STEP))
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var off := Vector2(float(i), float(j)) * SNAP_STEP
				if off.length() <= reach + 0.001:
					keyed.append([off.length(), off.y, off.x])
		keyed.sort()
		var out := []
		for k: Array in keyed:
			out.append(Vector2(float(k[2]), float(k[1])))
		_offset_cache[reach] = out
	return _offset_cache[reach]


## Whether a disc of radius r at pt is clear ground (see snap_site).
## `aprons`: gate_aprons(plan) when the caller has it already (the same answer, computed once).
static func clear_at(d: CityDistrict, pt: Vector2, r: float, blockers: Array[Rect2], cuts: Array[Rect2], avoid: Array = [],
		items: Variant = null, aprons: Variant = null) -> bool:
	var plan := d.plan
	for av: Array in avoid:      # [Vector2, radius]: pieces already placed (a defend relay beside its flag's mast)
		if (av[0] as Vector2).distance_to(pt) < float(av[1]) + r:
			return false
	var box := Rect2(pt - Vector2(r, r), Vector2(r, r) * 2.0)
	for b in blockers:
		if b.intersects(box):
			return false
	for o in cuts:
		if o.grow(CityStreets.HOLE_CURB + 0.5).intersects(box):
			return false
	for k: Rect2 in plan.site.keep_clear:
		if k.intersects(box):
			return false
	for ap: Rect2 in (aprons if aprons != null else gate_aprons(plan)):
		if ap.intersects(box):
			return false
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(2.0).intersects(box):
			return false
	for col: Dictionary in plan.columns:
		if Vector2(float(col["x"]), float(col["s"])).distance_to(pt) < float(col["half"]) + 2.0 + r:
			return false
	if plan.section != null:
		var rail := plan.section.lane_x("rail")
		if pt.x + r > rail.x and pt.x - r < rail.y:
			return false
		var av := plan.section.lane_x("avenue")
		if absf(pt.x - (av.x + av.y) * 0.5) < 1.5 + r:
			return false
	var props: Array = items if items != null else (d.props.items if d.props != null else [])
	for it: Dictionary in props:
		var pr := float(CityPropSim.TYPES[it["type"]]["radius"])
		if Vector2(float(it["x"]), float(it["s"])).distance_to(pt) < pr + r:
			return false
	return true


## The ground in front of every gate in the walls (GATE_APRON m into the map, 1 m past each side): where waves walk in
## and the hatched keep-clear box is painted; nothing is placed there.
const GATE_APRON := 12.0

static func gate_aprons(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for w: Dictionary in plan.boundary():
		var side := int(w["side"])
		var at := float(w["at"])
		var inward := -1.0 if side % 2 == 0 else 1.0
		var d0 := minf(at, at + inward * GATE_APRON)
		for g: Dictionary in w["gates"]:
			var a := float(g["a"]) - 1.0
			var b := float(g["b"]) + 1.0
			out.append(Rect2(a, d0, b - a, GATE_APRON) if side >= 2 else Rect2(d0, a, GATE_APRON, b - a))
	return out


## The upright frame at (x, s) standing on the ground there (district-local).
static func site_frame(d: CityDistrict, x: float, s: float, h: float) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	return Transform3D(CityGeo.frame_basis(d.ring, s), geo.g_point(x, s, h))
