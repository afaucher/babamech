class_name MissionGateDoor
extends Node3D
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

const LEAF_Z := -1.8         ## the leaves' face: behind a farm wall's backing (CityWalls.FARM_RECESS 1.6), hidden as they slide
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
# Sizes (the gate's by default; an air door sets its own before build(): MissionAirDoors.config).
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
		for p: Vector2 in [Vector2(-ihalf, bay_depth), Vector2(ihalf, bay_depth), Vector2(-ihalf, CityWalls.WALL_THICK),
				Vector2(ihalf, CityWalls.WALL_THICK), Vector2(0, bay_depth)]:
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
	st.stripes(Transform3D.IDENTITY, Rect2(dr.position, Vector2(dw * 0.5, dh)), D + 0.425, stripe, 1.0, MissionProps.c("m_recess"))
	st.stripes(Transform3D.IDENTITY, Rect2(dr.position + Vector2(dw * 0.5, 0), Vector2(dw * 0.5, dh)), D + 0.425, stripe, -1.0, MissionProps.c("m_recess"))
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
	_g_box(fl, arc(-w_out, 0.0), arc(w_out, CityWalls.WALL_THICK), 0.03, col)
	_g_box(fl, arc(-ihalf, CityWalls.WALL_THICK), arc(ihalf, bay_depth), 0.03, col)
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
	var F := -CityWalls.WALL_THICK
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
	bg.extrude(I, right, 0.0, frame_out, face, true, false, [0, 2], sidec)
	bg.extrude(I, left, 0.0, frame_out, face, true, false, [0, 2], sidec)
	# The lintel, extruded along X from a side profile (u = z, v = y): back beam, the lamp recess's ceiling, the
	# chamfered front fascia.
	var L := half + jamb + 0.5
	var lx := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0)), Vector3.ZERO)
	var fo := frame_out
	var pa: Array[Vector2] = [Vector2(0, gh), Vector2(0.6, gh), Vector2(0.6, top), Vector2(0, top)]
	var pb: Array[Vector2] = [Vector2(0.6, gh + 0.5), Vector2(fo - 0.2, gh + 0.5), Vector2(fo - 0.2, top), Vector2(0.6, top)]
	var pc: Array[Vector2] = [Vector2(fo - 0.2, gh), Vector2(fo + 0.4, gh), Vector2(fo + 0.4, top - 0.6), Vector2(fo - 0.2, top)]
	bg.extrude(lx, pa, -L, L, sidec, true, true, [3], face)
	bg.extrude(lx, pb, -L, L, sidec, true, true, [1, 3], face)
	bg.extrude(lx, pc, -L, L, sidec, true, true, [], face)
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
		lg.stripes(Transform3D.IDENTITY, band, LEAF_Z + 0.165, 0.32, k, MissionProps.c("m_recess"))
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
	var z0 := -CityWalls.WALL_THICK + 1.0
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
		CityGeo.convex_shape(body, I, pts)
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
