class_name MissionProps
extends RefCounted
## Shared presentation helpers for the pieces MissionWorld puts in the city for mission objectives phase 1
## (docs/design/city-ramps-and-stack.md "Mission world (phase 1)"): palette colours and emissive / matte materials, mesh and
## collision-box helpers, the gate frame, the upright site frame, and the zone marks on the ground. The pieces themselves
## are their own classes (MissionGateDoor, MissionLiftDoor, MissionFlagMast, MissionRelayAsset, MissionPortal); where a
## piece may stand is SiteFit's rule. Presentation only: no clock, no state, no network, no gameplay rule. Flat-shaded
## CityGeo boxes in CityPalette colours; glows use the emissive materials below (no Light3D here). Every mesh gets its
## render layer before it enters the tree (the stack's rule).

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


## The frame CityWalls._gate builds gate g of wall w in (district-local): origin on the wall plane at the floor, in the
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


## Half the clear opening of gate g (between the hazard portal's posts), as CityWalls._gate draws it.
static func gate_half(g: Dictionary) -> float:
	return (float(g["b"]) - float(g["a"])) * 0.5 - 0.6


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


# --- Ground marks ----------------------------------------------------------------------------------------------------------


## A thin ring of radius r round (x, s) on the faceted floor, 6 cm above whatever it crosses (road or curb), left out over
## floor cuts and inside building footprints. District-local.
static func zone_ring(d: CityDistrict, at: Vector2, r: float, width: float = 0.6) -> CityGeo:
	var geo := CityGeo.new(d.ring)
	var blocked := SiteFit.plan_blockers(d.plan)
	var cuts := d.plan.floor_cuts()
	var n := maxi(int(TAU * r / 1.5), 24)
	for i in n:
		var a0 := TAU * float(i) / float(n)
		var a1 := TAU * float(i + 1) / float(n)
		var am := (a0 + a1) * 0.5
		var mid := at + Vector2(cos(am), sin(am)) * r
		if SiteFit.in_rects(blocked, mid) or SiteFit.in_rects(cuts, mid, CityDims.HOLE_CURB + 0.2):
			continue
		var h := SiteFit.ground_h(d.plan, mid) + 0.06
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


## The upright frame at (x, s) standing on the ground there (district-local).
static func site_frame(d: CityDistrict, x: float, s: float, h: float) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	return Transform3D(CityGeo.frame_basis(d.ring, s), geo.g_point(x, s, h))
