class_name CityPalette
extends RefCounted
## The city's flat surface colours and its two shared materials (docs/design/city-styles.md).
##
## LIGHTING IS NOT IN HERE. Every colour is a plain albedo: what the surface looks like under neutral white light. All
## shading, warmth, haze and glow come from CityLightRig (lights + environment), which never touches these colours or
## the meshes. Geometry carries the colour per vertex (one colour per face), so the whole city draws with ONE lit
## material and can be relit by swapping the rig.

const C := {
	# walls
	"cream": Color("e6d9bb"), "cream_light": Color("f1e8d0"), "sand": Color("d6c096"),
	"terracotta": Color("c2694a"), "terracotta_light": Color("d68b6b"), "terracotta_dark": Color("a4543c"),
	"sage": Color("8fa985"), "sage_light": Color("aabf9d"), "sage_dark": Color("6d8a69"),
	"sky_blue": Color("8fbad8"), "blue_grey": Color("7c98ac"),
	"concrete": Color("c0b49e"), "concrete_dark": Color("a39782"),
	# glazing (flat colour, no reflections: the low-poly look)
	"glass_teal": Color("3f6b66"), "glass_blue": Color("5a89a3"), "glass_dark": Color("2e4a4c"),
	# roofs and metal
	"roof": Color("b3a892"), "roof_dark": Color("968c79"), "metal": Color("8d918c"), "metal_dark": Color("5f6462"),
	# ground
	"asphalt": Color("6f645b"), "asphalt_light": Color("85786b"), "asphalt_dark": Color("5a514a"),
	"lane_tan": Color("b59d78"), "marking": Color("f2ead5"), "marking_yellow": Color("e0b64c"),
	"sidewalk": Color("d9ccb1"), "sidewalk_band": Color("c7b89b"), "curb": Color("ece3ce"),
	"tactile": Color("d9a05a"), "plaza": Color("dcc7a2"), "plaza_alt": Color("c98f6f"),
	# green
	"lawn": Color("8fbb6c"), "leaf": Color("6ea45a"), "leaf_dark": Color("588a4b"), "leaf_light": Color("8cc070"),
	"trunk": Color("7a5a3f"), "soil": Color("6c5645"), "water": Color("7ec0d9"),
	# ceiling (underside of the next deck)
	"ceil_a": Color("c9b58c"), "ceil_b": Color("bca87f"), "ceil_c": Color("d3c199"), "rib": Color("a5916c"),
	"strip": Color("fff6e0"),
	# vertical farm side walls (docs/design/city-styles.md "Side walls: vertical farm"): pale concrete fins and plinth, a
	# darker solid backing, pale racks, blue-grey feed pipes, and fresh greens brighter than the street trees
	"farm_fin": Color("e4dccb"), "farm_backing": Color("8e8576"), "farm_rack": Color("d6d2c6"), "farm_planter": Color("a8a091"),
	"farm_pipe": Color("7d91a1"), "farm_leaf_dark": Color("5c9a3c"), "farm_leaf": Color("7db948"), "farm_leaf_light": Color("a2d067"),
	# backdrop (far, low-detail blocks: desaturated so the haze reads)
	"far_a": Color("cfc6b2"), "far_b": Color("c0a89a"), "far_c": Color("a9b7a6"), "far_d": Color("a8bccb"),
	# mission world (MissionWorld): wave doors, the beacon, the alien banner, ours (the crew's default accent, safety
	# orange: MechMeshes.ORANGE), the defend relay, the extraction portal; glows use MissionProps' emissive materials
	"m_recess": Color("1c1d1f"), "m_leaf": Color("55595a"), "m_scorch": Color("2a2624"), "m_weld": Color("3b3e40"),
	"m_beacon": Color("ffab2e"), "m_beacon_dead": Color("4a3f30"), "m_alien": Color("3a3a40"), "m_alien_mark": Color("b23a2e"),
	"m_ours": Color("ee7520"), "m_ours_mark": Color("f4ecd8"), "m_relay": Color("7d8a8f"), "m_relay_band": Color("5fd0e6"),
	"m_portal": Color("6fe3ff"), "m_portal_off": Color("3c4446"), "m_zone": Color("f2ead5"), "m_hostile": Color("e0402e"),
	"m_done": Color("7ee08a"),
	# building variety (docs/design/city-variety.md section 2): the second colourway of each style, more awning and sign
	# fascia colours; all inside the palette family (cream, terracotta, sage, sky blue, sand)
	"apt_sky": Color("9dbfd4"), "apt_sky_dark": Color("7fa5be"), "sand_light": Color("e4d2ac"), "office_sand": Color("cdb488"),
	"sage_cream": Color("e2dcc0"), "shop_rose": Color("cf8e78"),
	"awning_teal": Color("4f8f88"), "awning_sky": Color("6fa3c4"), "awning_cream": Color("efe2c2"),
	"fascia_teal": Color("3f6b66"), "fascia_sand": Color("c9ad7c"), "fascia_rose": Color("b86650"),
	# alleys and road forms (city-variety.md section 1): service paving, a drain, lane planting, string lights
	"service": Color("8e8274"), "service_dark": Color("5d554d"), "drain": Color("4a443f"), "pipe": Color("8a8f8c"),
	"door_back": Color("6f7a78"), "planting": Color("7fae62"), "bulb": Color("ffe6b0"),
}

## A building's own shade of its body colour (cosmetic, `rng` is the building's own stream): a small shift in hue,
## saturation and value, so a row of one style is not one colour while staying in the palette family.
static func tint(col: Color, rng: RandomNumberGenerator, amount: float = 1.0) -> Color:
	var h := fposmod(col.h + rng.randf_range(-0.014, 0.014) * amount, 1.0)
	var s := clampf(col.s * (1.0 + rng.randf_range(-0.12, 0.12) * amount), 0.0, 1.0)
	var v := clampf(col.v * (1.0 + rng.randf_range(-0.07, 0.07) * amount), 0.0, 1.0)
	return Color.from_hsv(h, s, v, col.a)

static var _surface: StandardMaterial3D
static var _strip: StandardMaterial3D


static func c(id: String) -> Color:
	return C[id]


## The one lit material every city surface uses: albedo = vertex colour, fully rough, no texture.
static func surface_material() -> StandardMaterial3D:
	if _surface == null:
		_surface = StandardMaterial3D.new()
		_surface.vertex_color_use_as_albedo = true
		_surface.vertex_color_is_srgb = true
		_surface.roughness = 1.0
		_surface.metallic = 0.0
		_surface.metallic_specular = 0.1
	return _surface


## The ceiling light strips. Its albedo is a palette colour like any other; its emission belongs to the light rig
## (CityLightRig sets it), because a glowing strip is light, not surface.
static func strip_material() -> StandardMaterial3D:
	if _strip == null:
		_strip = StandardMaterial3D.new()
		_strip.albedo_color = C["strip"]
		_strip.roughness = 1.0
		_strip.emission_enabled = true
		_strip.emission = Color.WHITE
		_strip.emission_energy_multiplier = 2.0
	return _strip


## A farm wall's light bars: the same kind of material as the strips, tinted warm (FARM_LIGHT_TINT); CityLightRig sets
## its glow from the strips' preset colour times that tint, a little dimmer, so a bar reads as a warm fixture, not a
## white line blooming across the wall.
const FARM_LIGHT_TINT := Color(1.0, 0.86, 0.62)
const FARM_LIGHT_ENERGY := 0.55     ## of the strips' energy
static var _farm_light: StandardMaterial3D


static func farm_light_material() -> StandardMaterial3D:
	if _farm_light == null:
		_farm_light = StandardMaterial3D.new()
		_farm_light.albedo_color = FARM_LIGHT_TINT
		_farm_light.roughness = 1.0
		_farm_light.emission_enabled = true
		_farm_light.emission = FARM_LIGHT_TINT
		_farm_light.emission_energy_multiplier = 2.0 * FARM_LIGHT_ENERGY
	return _farm_light
