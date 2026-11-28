class_name MissionGateDoor
extends Node3D
## A bulkhead door (docs/design/city-ramps-and-stack.md "Mission world", "Staging bay"; docs/design/city-spine.md §4): a
## projecting concrete bunker frame round the opening on the street side, two sliding steel leaves just behind the wall
## plane, and behind the wall a staging bay (a hangar room BAY_DEPTH m deep from the wall plane, at least BAY_MIN_W wide
## behind the wall thickness, BAY_H high) with a shut blast door drawn on its back wall (static: where the units "came
## from", the docking side). Look: user pick 2026-11-23, `docs/design/city-gates/bay_sliding_bunker_s61.png` (flat colours;
## every look choice in this class). The same class builds every road door (wave gates, the entry / exit doors), the air
## doors (MissionAirDoors.config) and the tram door: the same door "just a different size" (user 2026-11-26), its frame
## and leaves scaled by `sc` (tram_config), no bay (`bayless`: the world draws its tunnel, CityWalls._tunnel).
## While the leaves OPEN (MissionWorld: from open_at for OPENING s) the recessed amber lamps under the lintel flash in
## turn, the beacons on the lintel turn and the siren loops (MissionSound); otherwise they are dark. The bay's light strips
## and bars glow from the warning until it is shut again. Sealed: welded bars across, scorch on the leaves, beacons dead.
## Frame: origin on the wall plane at floor mid-gate, X along the wall, Y up, +Z into the map (MissionProps.gate_frame).
## The floor follows the deck's facets (drawn and collided in the district's arc coordinates: no lip on the curve).
## Neighbours on the same wall (MissionWorld.door_fit): a frame side whose neighbour is close is trimmed to the midpoint
## between the two openings (reach_lo / reach_hi: the two jambs meet as one pier), the sign pier stands on the free side
## (pier_side), and where a leaf's pocket in the wall would cross a neighbour's opening both leaves slide to the other
## side (slide: the far leaf steps back and runs behind the near one; shut, the door looks the same). The bay may sit off
## centre (ix0 .. ix1, MissionWorld.bay_span) to keep clear of a tram tunnel beside it.
## Collision (the wall's own slab is cut at the gate by MissionWorld and rebuilt round it): `door_shape` fills the opening
## from the wall plane 2.8 m back while shut / warning / sealed (blocks(): never while the leaves move, so a moving door
## can never crush or wedge a unit); the bay is a sealed box of PLATE m plates (floor, sides, back, roof) overlapping the
## cut wall; the bunker's jambs, lintel and sign pier are solid.

const LEAF_Z := -1.8         ## the leaves' face: behind a farm wall's backing (CityWalls.FARM_RECESS 1.6), hidden as they slide
const LEAF_BACK := 1.1       ## m the far leaf of a one-sided door steps back to run behind the near one
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
const PANEL := Vector2(6.0, 4.0)    ## the clean sign panel beside a buttress (stencil later; no text here)
const PANEL_Y := 5.0         ## its centre's height
const PIER_OUT := 1.6        ## m the sign pier stands out of the wall plane
const ROAD_H := 9.0          ## m: the road door's height, the size `sc` scales from (tram_config)
const MIN_JAMB := 0.4        ## m: a trimmed jamb is never thinner than this
var half := 7.0              ## half the clear opening (between the jambs)
var gh := 9.0                ## the opening's height (the lintel's underside)
var w_out := 7.6             ## half the gate in the wall (the throat through the wall's thickness)
var ix0 := -11.0             ## the bay's inner walls (behind the wall thickness) along X: -X side ...
var ix1 := 11.0              ## ... and +X side
var ihalf := 11.0            ## half the bay's interior width ((ix1 - ix0) / 2)
var icenter := 0.0           ## the bay's interior centre along X ((ix0 + ix1) / 2; 0 unless a neighbour pushed it)
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
var lights_on: MeshInstance3D           ## the bay's light strips and bars, glowing (warn .. closing); null without a bay
var lights_off: MeshInstance3D
var siren: AudioStreamPlayer3D          ## the gate's klaxon (MissionSound), looping while opening (and audible here)
var siren_on := false                   ## the siren was last told to play (own flag: a headless dummy driver may not report `playing`)
var sealed_look: Node3D
var body: StaticBody3D
var door_shape: CollisionShape3D
# Sizes (the gate's by default; an air door sets its own before build(): MissionAirDoors.config; a tram door: tram_config).
var bay_depth := BAY_DEPTH   ## m from the wall plane to the room's back wall
var room_h := BAY_H          ## m: the room's roof underside above its floor
var jamb := JAMB
var butt := BUTT
var frame_out := FRAME_OUT
var lintel_h := LINTEL_H
var sc := 1.0                ## the scale of the frame's and leaves' details (1: a road door; tram_config: gh / ROAD_H)
var sill := 0.0              ## m: the opening's bottom above the deck floor at the wall (an air door's 21 m)
var air := false             ## an air door: high on the wall, flat floor plate, a sill ledge, no sign pier, no guide lines on the street
var bayless := false         ## no bay or throat drawn or collided (the tram door: CityWalls draws its tunnel, CityDistrict collides it)
# Neighbours (MissionWorld.door_fit, set before build()): frame X distances from mid-gate.
var reach_lo := INF          ## m the frame may reach on -X (INF: its full size)
var reach_hi := INF          ## m on +X
var pier_side := 1           ## the sign pier's side: 1 (+X), -1 (-X), 0 none
var slide := 0               ## 0: the leaves part to both sides; 1 / -1: both slide to +X / -X
var jamb_lo := JAMB          ## the jambs and buttress feet as built (trimmed by the reach)
var jamb_hi := JAMB
var butt_lo := BUTT
var butt_hi := BUTT
const AIR_LEDGE := 1.5       ## m an air door's sill ledge projects into the street ...
const AIR_LEDGE_T := 1.2     ## ... and how thick it is under the sill

## The deck arc point (x, s) `lx` m along the wall from mid-gate and `depth` m behind the wall plane (negative: in the map).
func arc(lx: float, depth: float) -> Vector2:
	return arc_mid + arc_x * lx - arc_in * depth

## The tram door: the road door scaled to its height (frame, lintel, leaves' ribs, beacons, lamps), no bay, no sign pier.
func tram_config(height: float) -> void:
	sc = height / ROAD_H
	jamb = JAMB * sc
	butt = BUTT * sc
	lintel_h = LINTEL_H * sc
	frame_out = maxf(FRAME_OUT * sc, 1.5)     # the lamps keep a recess they fit in (and it stands proud of a bulkhead rib's 1.4 m face)
	bayless = true
	pier_side = 0

## The jamb's / buttress foot's width on side k (-1: -X, 1: +X), as built.
func side_jamb(k: float) -> float:
	return jamb_hi if k > 0.0 else jamb_lo

func side_butt(k: float) -> float:
	return butt_hi if k > 0.0 else butt_lo

## span: the bay's interior along X (MissionWorld.bay_span): a Vector2(ix0, ix1), or a float half width (centred), or
## <= 0 for the default (the gate's, widened to BAY_MIN_W).
func build(d: CityDistrict, w: Dictionary, g: Dictionary, look: RandomNumberGenerator, span: Variant = -1.0) -> void:
	var layer := d.render_layer
	half = MissionProps.gate_half(g)
	w_out = half + 0.6
	gh = float(g["h"])
	if span is Vector2:
		ix0 = (span as Vector2).x
		ix1 = (span as Vector2).y
	else:
		var hw := float(span) if float(span) > 0.0 else maxf(w_out, BAY_MIN_W * 0.5)
		hw = maxf(hw, w_out)
		ix0 = -hw
		ix1 = hw
	ihalf = (ix1 - ix0) * 0.5
	icenter = (ix0 + ix1) * 0.5
	for k: float in [-1.0, 1.0]:
		var room := (reach_hi if k > 0.0 else reach_lo) - half
		var j := clampf(room, MIN_JAMB, jamb)
		var b := clampf(room - j, 0.0, butt)
		if k > 0.0:
			jamb_hi = j
			butt_hi = b
		else:
			jamb_lo = j
			butt_lo = b
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
	if not air and not bayless:      # an air door's recess has a flat floor plate in its own frame
		for p: Vector2 in [Vector2(ix0, bay_depth), Vector2(ix1, bay_depth), Vector2(ix0, CityWalls.WALL_THICK),
				Vector2(ix1, CityWalls.WALL_THICK), Vector2(icenter, bay_depth)]:
			var a := arc(p.x, p.y)
			floor_rise = maxf(floor_rise, (inv * geo_d.g_point(a.x, a.y, 0.0)).y)
		var ab := arc(icenter, bay_depth)
		back_rise = (inv * geo_d.g_point(ab.x, ab.y, 0.0)).y
	if not bayless:
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
	var F := -CityWalls.WALL_THICK
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
	# The room: its front wall round the throat (or, where the room is narrower than the throat, the step facing the
	# street), sides, back, roof (faces turned inward).
	if ix0 < -w_out - 0.01:
		_face_nz(st, ix0, -w_out, y0, room_h, F, wall)
	elif ix0 > -w_out + 0.01:
		_face_pz(st, -w_out, ix0, y0, gh, F, throat)
	if ix1 > w_out + 0.01:
		_face_nz(st, w_out, ix1, y0, room_h, F, wall)
	elif ix1 < w_out - 0.01:
		_face_pz(st, ix1, w_out, y0, gh, F, throat)
	_face_nz(st, maxf(-w_out, ix0), minf(w_out, ix1), gh, room_h, F, wall)
	_face_px(st, ix0, F, D, y0, room_h, wall)
	_face_nx(st, ix1, F, D, y0, room_h, wall)
	_face_pz(st, ix0, ix1, y0, room_h, D, wall)
	_face_ny(st, ix0, ix1, F, D, room_h, roof)
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
			var xw := ix1 if k > 0.0 else ix0
			var faces := CityGeo.ALL - CityGeo.NY - CityGeo.PY - (CityGeo.NX if k < 0.0 else CityGeo.PX)
			st.box(Transform3D.IDENTITY, Vector3(xw - k * 0.3, (y0 + room_h) * 0.5, zr), Vector3(0.6, room_h - y0, 1.0), rib, faces)
			var sh := minf(8.0, room_h - 2.6)
			lg.box(Transform3D.IDENTITY, Vector3(xw - k * 0.66, 1.6 + floor_rise + sh * 0.5, zr), Vector3(0.12, sh, 0.36), MissionProps.c("strip"),
					CityGeo.ALL - (CityGeo.NX if k < 0.0 else CityGeo.PX))
	z = F - 3.0
	while z > D + 1.5:
		lg.box(Transform3D.IDENTITY, Vector3(icenter, room_h - LIGHT_DROP * 0.5, z), Vector3(ihalf * 2.0 - 3.0, LIGHT_DROP, 0.7), MissionProps.c("strip"),
				CityGeo.ALL - CityGeo.PY)
		z -= 5.0
	# The back blast door: a steel frame on the back wall, the shut leaf with yellow / black chevrons and a centre seam.
	var dw := minf(ihalf * 2.0 - 6.0, 16.0)
	var dh := minf(12.0, room_h - 5.0) if not air else room_h - 1.6
	var by := back_rise - 0.3
	var cx := icenter
	var fr := MissionProps.c("metal")
	var faces_f := CityGeo.ALL - CityGeo.NZ - CityGeo.NY
	for k: float in [-1.0, 1.0]:
		st.box(Transform3D.IDENTITY, Vector3(cx + k * (dw * 0.5 + 0.6), by + (dh + 1.2) * 0.5, D + 0.4), Vector3(1.2, dh + 1.2, 0.8), fr, faces_f)
	st.box(Transform3D.IDENTITY, Vector3(cx, by + dh + 0.6, D + 0.4), Vector3(dw, 1.2, 0.8), fr, faces_f - CityGeo.PX - CityGeo.NX)
	st.box(Transform3D.IDENTITY, Vector3(cx, by + dh * 0.5, D + 0.2), Vector3(dw, dh, 0.4), MissionProps.c("marking_yellow"), CityGeo.PZ)
	var dr := Rect2(cx - dw * 0.5, by, dw, dh)
	var stripe := 1.1
	st.stripes(Transform3D.IDENTITY, Rect2(dr.position, Vector2(dw * 0.5, dh)), D + 0.425, stripe, 1.0, MissionProps.c("m_recess"))
	st.stripes(Transform3D.IDENTITY, Rect2(dr.position + Vector2(dw * 0.5, 0), Vector2(dw * 0.5, dh)), D + 0.425, stripe, -1.0, MissionProps.c("m_recess"))
	st.box(Transform3D.IDENTITY, Vector3(cx, by + dh * 0.5, D + 0.5), Vector3(0.3, dh, 0.1), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
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
	_g_box(fl, arc(-w_out, 0.0), arc(w_out, CityWalls.WALL_THICK), 0.03, col)
	_g_box(fl, arc(ix0, CityWalls.WALL_THICK), arc(ix1, bay_depth), 0.03, col)
	var yl := MissionProps.c("marking_yellow")
	for k: float in [-1.0, 1.0]:
		var lx := k * (half - 1.4)
		lx = clampf(lx, ix0 + 0.6, ix1 - 0.6)
		_g_box(fl, arc(lx - 0.18, -1.2), arc(lx + 0.18, bay_depth - 1.0), 0.07, yl)
	_g_box(fl, arc(maxf(-(half - 1.22), ix0 + 0.4), USE_FROM - 0.6), arc(minf(half - 1.22, ix1 - 0.4), USE_FROM - 0.25), 0.07, yl)
	var fm := MissionProps.mesh(fl, "BayFloor", layer)
	fm.transform = inv
	add_child(fm)

# An air door's floor: flat in its frame (a 14 m recess high on the wall), guide lines out over the sill ledge.
func _air_floor(layer: int) -> void:
	var fl := CityGeo.new()
	fl.tag("mission.bay_floor")
	var col := MissionProps.c("asphalt_dark")
	var F := -CityWalls.WALL_THICK
	_floor_quad(fl, -w_out, w_out, 0.0, F, 0.03, col)
	_floor_quad(fl, ix0, ix1, F, -bay_depth, 0.03, col)
	for k: float in [-1.0, 1.0]:
		var lx := k * (half - 1.2)
		_floor_quad(fl, lx - 0.18, lx + 0.18, AIR_LEDGE - 0.2, -bay_depth + 1.0, 0.07, MissionProps.c("marking_yellow"))
	add_child(MissionProps.mesh(fl, "BayFloor", layer))

static func _floor_quad(g: CityGeo, x0: float, x1: float, z_hi: float, z_lo: float, y: float, col: Color) -> void:
	g.quad(Vector3(x0, y, z_hi), Vector3(x1, y, z_hi), Vector3(x1, y, z_lo), Vector3(x0, y, z_lo), col)

## The -X / +X end of the lintel (it overhangs the jamb by 0.5 m, never past the frame's reach).
func _lintel_end(k: float) -> float:
	return minf(half + side_jamb(k) + 0.5 * sc, reach_hi if k > 0.0 else reach_lo)

# The bunker frame on the street side: sloped jambs, a deep lintel with a recess for the lamps, a pier with the sign panel.
func _build_bunker(layer: int) -> void:
	var bg := CityGeo.new()
	bg.tag("mission.bunker")
	var face := MissionProps.c("sidewalk")         # pale concrete, as the reference
	var sidec := MissionProps.c("concrete")
	var top := gh + lintel_h
	var I := Transform3D.IDENTITY
	var right: Array[Vector2] = [Vector2(half, 0), Vector2(half + jamb_hi + butt_hi, 0), Vector2(half + jamb_hi, gh), Vector2(half, gh)]
	var left: Array[Vector2] = [Vector2(-half - jamb_lo - butt_lo, 0), Vector2(-half, 0), Vector2(-half, gh), Vector2(-half - jamb_lo, gh)]
	bg.extrude(I, right, 0.0, frame_out, face, true, false, [0, 2], sidec)
	bg.extrude(I, left, 0.0, frame_out, face, true, false, [0, 2], sidec)
	# The lintel, extruded along X from a side profile (u = z, v = y): back beam, the lamp recess's ceiling, the
	# chamfered front fascia. Extruded from -X to +X (a trimmed side ends at its reach).
	var l0 := -_lintel_end(-1.0)
	var l1 := _lintel_end(1.0)
	var lx := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0)), Vector3.ZERO)
	var fo := frame_out
	var c := 0.6 * sc
	var pa: Array[Vector2] = [Vector2(0, gh), Vector2(c, gh), Vector2(c, top), Vector2(0, top)]
	var pb: Array[Vector2] = [Vector2(c, gh + 0.5 * sc), Vector2(fo - 0.2, gh + 0.5 * sc), Vector2(fo - 0.2, top), Vector2(c, top)]
	var pc: Array[Vector2] = [Vector2(fo - 0.2, gh), Vector2(fo + 0.4, gh), Vector2(fo + 0.4, top - c), Vector2(fo - 0.2, top)]
	bg.extrude(lx, pa, -l1, -l0, sidec, true, true, [3], face)
	bg.extrude(lx, pb, -l1, -l0, sidec, true, true, [1, 3], face)
	bg.extrude(lx, pc, -l1, -l0, sidec, true, true, [], face)
	# Beacon housings on the lintel over the jambs.
	for k: float in [-1.0, 1.0]:
		var x := k * (half + side_jamb(k) * 0.5)
		bg.box(I, Vector3(x, top + 0.2 * sc, 1.0 * sc), Vector3(1.8, 0.4, 1.8) * sc, MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NY)
	if air:      # a sill ledge (a landing lip, its top level with the recess floor) instead of the sign pier
		bg.box(I, Vector3(0, -AIR_LEDGE_T * 0.5, AIR_LEDGE * 0.5), Vector3((half + jamb + butt) * 2.0, AIR_LEDGE_T, AIR_LEDGE), face, CityGeo.ALL - CityGeo.NZ)
		add_child(MissionProps.mesh(bg, "Bunker", layer))
		return
	if pier_side != 0:
		# The sign pier beside a buttress (+X unless a neighbour stands there): a plain flat face (PANEL at PANEL_Y), kept
		# clean for a stencil.
		var k := float(pier_side)
		var px0 := half + side_jamb(k) + side_butt(k) + 0.3
		var pw := PANEL.x + 0.8
		var ph := PANEL_Y + PANEL.y * 0.5 + 1.0
		bg.box(I, Vector3(k * (px0 + pw * 0.5), ph * 0.5, PIER_OUT * 0.5), Vector3(pw, ph, PIER_OUT), face, CityGeo.ALL - CityGeo.NZ - CityGeo.NY)
		panel_xf = Transform3D(Basis.IDENTITY, Vector3(k * (px0 + pw * 0.5), PANEL_Y, PIER_OUT))
	add_child(MissionProps.mesh(bg, "Bunker", layer))

## The extent of the sign pier along X from mid-gate on its side (0 without one): what a neighbour must keep clear of.
func pier_reach() -> float:
	return pier_reach_for(half, jamb, butt) if pier_side != 0 else 0.0

static func pier_reach_for(h: float, j: float, b: float) -> float:
	return h + j + b + 0.3 + PANEL.x + 0.8

# Two steel leaves with ribs, panel lines and a yellow / black hazard band each.
func _build_leaves(layer: int) -> void:
	for k: float in [-1.0, 1.0]:
		var leaf := Node3D.new()
		leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
		var lg := CityGeo.new()
		lg.tag("mission.leaf")
		var lw := half
		# The slab runs LEAF_TUCK past the opening's edge into the wall (no face on the edge's plane: a tram tunnel's wall).
		lg.box(Transform3D.IDENTITY, Vector3(k * LEAF_TUCK * 0.5, gh * 0.5, LEAF_Z - 0.5), Vector3(lw + LEAF_TUCK, gh, 1.0), MissionProps.c("m_leaf"))
		var y := 1.4 * sc
		while y < gh - 0.8 * sc:
			if absf(y - gh * 0.5) > 1.0 * sc:
				lg.box(Transform3D.IDENTITY, Vector3(0, y, LEAF_Z + 0.05), Vector3(lw - 0.4 * sc, 0.3 * sc, 0.1), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
			y += 2.2 * sc
		lg.box(Transform3D.IDENTITY, Vector3(k * lw * 0.12, gh * 0.5, LEAF_Z + 0.04), Vector3(0.14 * sc, gh - 0.6 * sc, 0.08), MissionProps.c("metal_dark"), CityGeo.ALL - CityGeo.NZ)
		var band := Rect2(-lw * 0.42, gh * 0.5 - 0.55 * sc, lw * 0.84, 1.1 * sc)
		lg.box(Transform3D.IDENTITY, Vector3(band.get_center().x, band.get_center().y, LEAF_Z + 0.09), Vector3(band.size.x, band.size.y, 0.1),
				MissionProps.c("marking_yellow"), CityGeo.ALL - CityGeo.NZ)
		lg.stripes(Transform3D.IDENTITY, band, LEAF_Z + 0.165, 0.32 * sc, k, MissionProps.c("m_recess"))
		lg.box(Transform3D.IDENTITY, Vector3(-k * (lw * 0.5 - 0.2 * sc), gh * 0.5, LEAF_Z + 0.06), Vector3(0.4 * sc, gh, 0.12), MissionProps.c("metal"), CityGeo.ALL - CityGeo.NZ)
		leaf.add_child(MissionProps.mesh(lg, "Mesh", layer, null, true))
		leaf.position = Vector3(k * half * 0.5, 0, 0)
		add_child(leaf)
		leaves.append(leaf)

# Round amber lamps recessed in the lintel (two, four on a wide gate), in a left and a right group; beacons on the lintel.
func _build_lamps(layer: int) -> void:
	var xs: Array[float] = [-half * 0.5, half * 0.5]
	if half > 10.0:
		xs = [-half * 0.75, -half * 0.25, half * 0.25, half * 0.75]
	var zc := (0.6 * sc + frame_out - 0.2) * 0.5
	var lr := minf(0.5, (frame_out - 0.2 - 0.6 * sc) * 0.5 - 0.04)    # the lamp fits the lintel's recess (0.6 sc .. frame_out - 0.2)
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
	for k: float in [-1.0, 1.0]:
		var x := k * (half + side_jamb(k) * 0.5)
		var lit := Node3D.new()
		lit.name = "BeaconLit"
		lit.position = Vector3(x, top + 0.4 * sc, 1.0 * sc)
		var core := CityGeo.new()
		core.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6 * sc, 1.3 * sc, 6, MissionProps.c("m_beacon"))
		lit.add_child(MissionProps.mesh(core, "Core", layer, MissionProps.glow("m_beacon", 3.0)))
		var pad := CityGeo.new()
		pad.box(Transform3D.IDENTITY, Vector3(0, 0.65 * sc, 0), Vector3(3.0, 0.75, 0.16) * sc, MissionProps.c("m_beacon"))
		pad.box(Transform3D.IDENTITY, Vector3(0, 0.65 * sc, 0), Vector3(0.16, 0.75, 3.0) * sc, MissionProps.c("m_beacon"))
		lit.add_child(MissionProps.mesh(pad, "Paddles", layer, MissionProps.glow("m_beacon", 5.0)))
		lit.visible = false
		add_child(lit)
		beacons_lit.append(lit)
		var ig := CityGeo.new()
		ig.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6 * sc, 1.3 * sc, 6, MissionProps.c("m_beacon_dead"))
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
		sl.box(Transform3D(Basis(Vector3.BACK, k * diag), Vector3(0, gh * 0.5, 0.25 + 0.3 * (k + 1.0))), Vector3.ZERO, Vector3(dl, 0.5 * sc, 0.25), MissionProps.c("m_weld"))
	for y2: float in [gh * 0.3, gh * 0.7]:
		sl.box(Transform3D.IDENTITY, Vector3(0, y2, 0.2), Vector3(half * 2.0, 0.6 * sc, 0.2), MissionProps.c("m_weld"))
	sl.box(Transform3D.IDENTITY, Vector3(0, gh * 0.5, 0.05), Vector3(0.25, gh - 0.4, 0.06), MissionProps.c("marking"))
	var n := look.randi_range(5, 8)
	for i in n:
		var cx := look.randf_range(-half + 1.0 * sc, half - 1.0 * sc)
		var cy := look.randf_range(0.6 * sc, gh - 1.0 * sc)
		var r := look.randf_range(0.8, 2.2) * sc
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
	if not bayless:
		# The bay: sides, back and roof in the frame; they reach 1 m into the wall's slab and past each other's edges.
		var z0 := -CityWalls.WALL_THICK + 1.0
		var z1 := -bay_depth - PLATE
		var y0 := -2.0
		var y1 := room_h + PLATE + 0.5
		var zc := (z0 + z1) * 0.5
		var cx := icenter
		var wide := ihalf + PLATE
		MissionProps.box_shape(body, I, Vector3(ix0 - PLATE * 0.5, (y0 + y1) * 0.5, zc), Vector3(PLATE, y1 - y0, z0 - z1))
		MissionProps.box_shape(body, I, Vector3(ix1 + PLATE * 0.5, (y0 + y1) * 0.5, zc), Vector3(PLATE, y1 - y0, z0 - z1))
		MissionProps.box_shape(body, I, Vector3(cx, (y0 + y1) * 0.5, -bay_depth - PLATE * 0.5), Vector3(wide * 2.0, y1 - y0, PLATE))
		MissionProps.box_shape(body, I, Vector3(cx, room_h + PLATE * 0.5, zc), Vector3(wide * 2.0, PLATE, z0 - z1))
		# Where the room is narrower than the throat: a block closing the step behind the wall (no slot past the plate).
		for k: float in [-1.0, 1.0]:
			var edge := ix1 if k > 0.0 else ix0
			if k * edge < w_out - 0.01:
				var xa := edge
				var xb := k * (w_out + 0.6)
				MissionProps.box_shape(body, I, Vector3((xa + xb) * 0.5, (y0 + y1) * 0.5, z0 - PLATE * 0.5 - 0.5),
						Vector3(absf(xb - xa), y1 - y0, PLATE + 1.0))
		if air:
			# An air door: one flat floor plate from the wall plane to past the back wall, and the sill ledge.
			MissionProps.box_shape(body, I, Vector3(cx, -PLATE * 0.5, z1 * 0.5), Vector3(wide * 2.0, PLATE, -z1))
			MissionProps.box_shape(body, I, Vector3(0, -AIR_LEDGE_T * 0.5, AIR_LEDGE * 0.5), Vector3((half + jamb + butt) * 2.0, AIR_LEDGE_T, AIR_LEDGE))
		else:
			# The floor: one slab per deck facet, as CityDistrict._col_floor (no seam or step where it meets the deck's own).
			var a0 := arc(minf(ix0 - PLATE, -w_out), 0.0)
			var a1 := arc(maxf(ix1 + PLATE, w_out), bay_depth + PLATE)
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
		var j := side_jamb(k)
		for p: Vector2 in [Vector2(half, 0), Vector2(half + j + side_butt(k), 0), Vector2(half + j, gh), Vector2(half, gh)]:
			for zz: float in [0.0, frame_out]:
				pts.append(Vector3(k * p.x, p.y, zz))
		CityGeo.convex_shape(body, I, pts)
	var l0 := -_lintel_end(-1.0)
	var l1 := _lintel_end(1.0)
	MissionProps.box_shape(body, I, Vector3((l0 + l1) * 0.5, (gh + top) * 0.5, (frame_out + 0.4) * 0.5), Vector3(l1 - l0, lintel_h, frame_out + 0.4))
	if air or pier_side == 0:
		return
	var kp := float(pier_side)
	var px0 := half + side_jamb(kp) + side_butt(kp) + 0.3
	var pw := PANEL.x + 0.8
	var ph := PANEL_Y + PANEL.y * 0.5 + 1.0
	MissionProps.box_shape(body, I, Vector3(kp * (px0 + pw * 0.5), ph * 0.5, PIER_OUT * 0.5), Vector3(pw, ph, PIER_OUT))

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

## The leaves' X positions and z steps at `open` 0..1: [[x, z], [x, z]] for leaves L (-X) and R (+X). Both parting
## (slide 0): each to its own side. One-sided (slide +-1): the near leaf (on the slide side) slides half its width less
## far than the far leaf, which first steps back LEAF_BACK (over the first OPEN_BACK of the travel) and runs behind it.
## Open, every leaf slides LEAF_TUCK further, so its inner edge too stands inside the wall (off the opening's edge plane).
const OPEN_BACK := 0.12
const LEAF_TUCK := 0.1
func leaf_pose(open: float) -> Array:
	var out := []
	for i in 2:
		var k := -1.0 if i == 0 else 1.0
		if slide == 0 or k == float(slide):
			out.append([k * (half * (0.5 + open) + LEAF_TUCK * open), 0.0])
		else:
			var dir := float(slide)
			var back := -LEAF_BACK * clampf(open / OPEN_BACK, 0.0, 1.0)
			out.append([-dir * half * 0.5 + dir * (half * 2.0 + LEAF_TUCK * 2.0) * open, back])
	return out

## state: shut | warn | opening | open | closing | sealed; u 0..1 through opening / closing; t the clock (beacon turn,
## lamp flash); alarm: the door's alarm is on (MissionWorld.alarm_on: while the leaves open); audible: and the siren
## plays here (the viewer's deck).
func pose(state: String, u: float, t: float, alarm: bool = false, audible: Variant = null) -> void:
	var open := 0.0
	match state:
		"opening": open = smoothstep(0.0, 1.0, u)
		"open": open = 1.0
		"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
	var lp := leaf_pose(open)
	for i in leaves.size():
		leaves[i].position.x = float(lp[i][0])
		leaves[i].position.z = float(lp[i][1])
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
	if lights_on != null:
		lights_on.visible = lit
		lights_off.visible = not lit
	sealed_look.visible = state == "sealed"
	var play: bool = alarm if audible == null else bool(audible)
	if play != siren_on:
		siren_on = play
		MissionSound.set_siren(siren, play, t)

func lamps_lit() -> bool:
	return not beacons_lit.is_empty() and beacons_lit[0].visible

## Whether the door's own shape fills the opening in `state`: only while the leaves stand still and shut (shut, warn,
## sealed). Never while they move: a closing door gets solid once fully shut, so it can never crush or wedge a unit (a
## unit still in the opening then is pushed out by the physics), and an opening one is not solid either.
func blocks(state: String) -> bool:
	return state == "shut" or state == "warn" or state == "sealed"

## Where the WarnLight hangs while the door opens and stands open: high in the bay, lighting what waits there.
func light_point() -> Vector3:
	if air:
		return Vector3(icenter, room_h - 1.5, -bay_depth * 0.5)
	if bayless:
		return Vector3(0, gh + lintel_h + 1.0, 2.0)
	return Vector3(icenter, room_h - 4.0, -(USE_FROM + USE_TO) * 0.5)

func world_point() -> Vector3:
	return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)
