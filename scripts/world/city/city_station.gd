class_name CityStation
extends RefCounted
## The tram stop of a section's top deck (docs/design/city-spine.md section 5, docs/design/city-props.md "Station"; the
## user's pick: cell 7 of city-spine/grid_station.png, "just some basic lights and benches. Both of which we have. Just
## arranged with a small wall"). A raised kerb platform LEN x DEPTH m, H m high, on the promenade side of the track (in
## the `ramp_b` lane, against the rail lane's east edge), in the spine segment nearest the deck's middle that keeps
## BOX_CLEAR m from both junction boxes and is clear of floor cuts, ramps and kept-clear ground; a low back wall along
## its far edge with the station's name board standing on it (CitySigns' dark panel and stencil letters); the EXISTING
## street lamps and benches in a row on it (items(): ordinary knockable CityProps, appended to CityPropLayout.layout, so
## they are in its checksum). The tram's one stop is at its centre (LifeTram.stop_s).
##
## of(plan) is a pure function of the plan (gameplay: the platform and the wall are solid, the props are host-arbitrated);
## the name comes from the plan's cosmetic seed through its own generator (looks). Real fittings only: no game indicators.
## Collision (build_node): one box per 4 m floor facet for the platform and the wall (0.35 m and 1.15 m over the street:
## below the pin band, a mech steps onto both), a rounded box (CityGeo.rounded_box) for the name board; meta col_kind
## "station" for the collision survey.

const LEN := 32.0
const DEPTH := 3.5
const H := 0.35               ## platform top over the street (a mech steps onto it)
const WALL_H := 0.8           ## the back wall over the platform: its top 1.15 m over the street, out of the pin band
const WALL_T := 0.3
const BOX_CLEAR := 8.0        ## m between the platform and a junction box (clear of the zebra and the stop line)
const SLIDE := 2.0            ## m steps a platform slides along its segment to clear a cut or kept-clear ground
const EDGE_IN := 0.15         ## the tactile strip along the track edge: this far in ...
const EDGE_W := 0.45          ## ... this wide
const BOARD_W := 4.4          ## the name board on the wall: width, its top over the platform
const BOARD_TOP := 2.6
const BOARD_T := 0.24
const LAMP_S := [-14.5, -6.5, 6.5, 14.5]     ## lamps along the back, m from the centre
const BENCH_S := [-10.5, -3.5, 3.5, 10.5]    ## benches between them (the two inner ones flank the name board)
## Station names (looks): only letters the stencil face has (CitySigns: A C D E H K L N O R S T).
const NAMES := ["CENTRAL", "ARCADE", "CANAL", "CEDAR", "ALDER", "STRAND", "CRESCENT", "LANTERN", "ORCHARD", "CASTLE",
		"TORRENS", "ASHDALE", "LOCKSTEAD", "REDLANDS", "ELDERS", "HARTLAND"]


## The station of district `p`, or {} (not a section's top deck, no room): {rect (Rect2 x, s), x0, x1, s0, s1, stop_s
## (its centre along s), track_x (the rail lane's centre line), name, deck}.
static func of(p: CityPlan) -> Dictionary:
	if p == null or p.section == null or p.deck != 0:
		return {}
	var sec := p.section
	var rail := sec.lane_x("rail")
	var rb := sec.lane_x("ramp_b")
	if rail.y - rail.x <= 0.0 or rb.y - rb.x < DEPTH:
		return {}
	var x0 := rail.y
	var mid := p.extent.get_center().y
	var segs: Array = []
	for j in p.roads_s.size() - 1:
		var a := float(p.roads_s[j]["b"]) + BOX_CLEAR
		var b := float(p.roads_s[j + 1]["a"]) - BOX_CLEAR
		if b - a >= LEN:
			segs.append([absf((a + b) * 0.5 - mid), a, b])
	segs.sort()
	for sg: Array in segs:
		var a := float(sg[1])
		var b := float(sg[2])
		var c := (a + b) * 0.5
		var room := (b - a - LEN) * 0.5
		var tries := int(floor(room / SLIDE))
		for k in tries * 2 + 1:
			var off := SLIDE * ceilf(float(k) * 0.5) * (1.0 if k % 2 == 1 else -1.0)
			var cs := c + off
			var r := Rect2(x0, cs - LEN * 0.5, DEPTH, LEN)
			if _clear(p, r.grow(0.5)):
				return {"rect": r, "x0": x0, "x1": x0 + DEPTH, "s0": r.position.y, "s1": r.end.y, "stop_s": cs,
						"track_x": (rail.x + rail.y) * 0.5, "name": name_of(p), "deck": p.deck}
	return {}


## Whether nothing may forbid standing anywhere on r: no floor cut (CityPlan.clear_at), no kept-clear ground, no ramp.
static func _clear(p: CityPlan, r: Rect2) -> bool:
	for rp: Dictionary in p.ramps:
		var rr := Rect2(float(rp["x0"]), minf(float(rp["s_top"]), float(rp["s_foot"])), float(rp["x1"]) - float(rp["x0"]),
				absf(float(rp["s_foot"]) - float(rp["s_top"])))
		if rr.intersects(r):
			return false
	var nx := int(ceil(r.size.x))
	var ns := int(ceil(r.size.y))
	for i in nx + 1:
		for k in ns + 1:
			if not p.clear_at(Vector2(r.position.x + r.size.x * float(i) / float(nx), r.position.y + r.size.y * float(k) / float(ns))):
				return false
	return true


## The station's name: from the plan's cosmetic seed through its own generator (looks only: nothing else is drawn from it).
static func name_of(p: CityPlan) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([p.cosmetic_seed(), 0x57A7])
	return NAMES[rng.randi_range(0, NAMES.size() - 1)]


## The station's lamps and benches as layout items [type, x, s, h, yaw] (CityPropLayout appends them after every other
## prop, so no other id moves). Lamps against the wall with their arm over the platform, benches facing the track.
static func items(st: Dictionary) -> Array:
	var out: Array = []
	if st.is_empty():
		return out
	var x1 := float(st["x1"])
	var c := float(st["stop_s"])
	var face := -PI * 0.5             # local +Z toward -x: the track
	for ds: float in LAMP_S:
		out.append(["lamp", x1 - WALL_T - 0.35, c + ds, H, face])
	for ds: float in BENCH_S:
		out.append(["bench", x1 - WALL_T - 0.5, c + ds, H, face])
	return out


## The raised floor a fallen prop lies on (CityPropSim.floor_rects): [{rect, h}] or [].
static func floor_rect(p: CityPlan) -> Array:
	var st := of(p)
	return [] if st.is_empty() else [{"rect": st["rect"], "h": H}]


# --- Geometry and collision -------------------------------------------------------------------------------------

## Node "Station" (mesh + StaticBody3D "StationBody") for station `st` on `ring`, or null. Render layers are left to the
## caller (CityDistrict sets every GeometryInstance3D under its props before they enter the tree).
static func build_node(st: Dictionary, ring: RingFrame) -> Node3D:
	if st.is_empty():
		return null
	var root := Node3D.new()
	root.name = "Station"
	var geo := CityGeo.new(ring)
	mesh(geo, st)
	var mi := geo.instance("StationMesh", CityPalette.surface_material())
	root.add_child(mi)
	root.set_meta("tris", geo.tri_count())
	var body := StaticBody3D.new()
	body.name = "StationBody"
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)
	collision(body, st, ring)
	return root


## The platform (kerb sides, paved top, the tactile strip along the track edge), the low back wall with its coping and
## the name board standing on it, following the deck's facets.
static func mesh(geo: CityGeo, st: Dictionary) -> void:
	var x0 := float(st["x0"])
	var x1 := float(st["x1"])
	var s0 := float(st["s0"])
	var s1 := float(st["s1"])
	geo.tag("station.platform")
	geo.g_slab(x0, x1, s0, s1, 0.0, H, CityPalette.c("sidewalk"), CityPalette.c("curb"))
	geo.g_rect(x0 + EDGE_IN, x0 + EDGE_IN + EDGE_W, s0, s1, H + CityStreets.DECAL_PATCH, CityPalette.c("marking_yellow"))
	geo.tag("station.wall")
	geo.g_slab(x1 - WALL_T, x1, s0, s1, H, H + WALL_H, CityPalette.c("concrete"))
	geo.g_slab(x1 - WALL_T - 0.05, x1 + 0.05, s0, s1, H + WALL_H, H + WALL_H + 0.08, CityPalette.c("cream_light"))
	_board(geo, st)


## The name board: the deck signs' dark panel (CitySigns "dark": chamfered, a sky-blue stripe) standing on the wall,
## the station's name in cream stencil letters on its track face, its back plain.
static func _board(geo: CityGeo, st: Dictionary) -> void:
	var c := float(st["stop_s"])
	var xm := float(st["x1"]) - WALL_T * 0.5
	var xf := geo.frame(xm, c, H, -PI * 0.5)       # +Z toward the track, +X reading right seen from it
	var y0 := WALL_H + 0.08
	var y1 := BOARD_TOP
	var hw := BOARD_W * 0.5
	var ch := 0.18
	var poly := PackedVector2Array([Vector2(-hw + ch, y0), Vector2(hw - ch, y0), Vector2(hw, y0 + ch), Vector2(hw, y1 - ch),
			Vector2(hw - ch, y1), Vector2(-hw + ch, y1), Vector2(-hw, y1 - ch), Vector2(-hw, y0 + ch)])
	geo.tag("station.board")
	CitySigns._extrude(geo, xf, poly, -BOARD_T * 0.5, BOARD_T * 0.5, CityPalette.c("sign_panel"), true)
	var title := str(st["name"])
	var u := minf(0.07, (BOARD_W - 0.5) / maxf(CitySigns.word_w(title), 1.0))
	var face := BOARD_T * 0.5 + CitySigns.DECAL
	geo.tag("station.board.stripe")
	CitySigns._flat(geo, xf, PackedVector2Array([Vector2(-hw + 0.2, y0 + 0.12), Vector2(hw - 0.2, y0 + 0.12),
			Vector2(hw - 0.2, y0 + 0.2), Vector2(-hw + 0.2, y0 + 0.2)]), face, CityPalette.c("sign_stripe"))
	geo.tag("station.board.glyph")
	var base := (y0 + 0.2 + y1) * 0.5 - 5.0 * u
	for pg: PackedVector2Array in CitySigns.word_polys(title, u, base):
		CitySigns._flat(geo, xf, pg, face, CityPalette.c("sign_cream"))


## The collision under `body` (district space): per floor facet a platform box and a wall box; a rounded box for the
## board (its top, 2.95 m over the street, is in the pin band). Every shape carries meta col_kind "station".
static func collision(body: StaticBody3D, st: Dictionary, ring: RingFrame) -> Array[CollisionShape3D]:
	var out: Array[CollisionShape3D] = []
	var geo := CityGeo.new(ring)
	var x0 := float(st["x0"])
	var x1 := float(st["x1"])
	var b := CityGeo.breaks(float(st["s0"]), float(st["s1"]))
	for i in b.size() - 1:
		var sm := (b[i] + b[i + 1]) * 0.5
		var ln := b[i + 1] - b[i]
		if ln < 0.05:
			continue
		for part: Array in [[(x0 + x1) * 0.5, x1 - x0, 0.0, H], [x1 - WALL_T * 0.5, WALL_T, H, H + WALL_H]]:
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(float(part[1]), float(part[3]) - float(part[2]), ln)
			cs.shape = box
			cs.transform = geo.frame(float(part[0]), sm, (float(part[2]) + float(part[3])) * 0.5)
			body.add_child(cs)
			out.append(cs)
	var bxf := geo.frame(x1 - WALL_T * 0.5, float(st["stop_s"]), H)
	out.append_array(CityGeo.rounded_box(body, bxf, Vector3(0.0, BOARD_TOP * 0.5, 0.0), Vector3(WALL_T, BOARD_TOP, BOARD_W)))
	for cs in out:
		cs.set_meta("col_kind", "station")
	return out
