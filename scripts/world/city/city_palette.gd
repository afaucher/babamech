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
	# backdrop (far, low-detail blocks: desaturated so the haze reads)
	"far_a": Color("cfc6b2"), "far_b": Color("c0a89a"), "far_c": Color("a9b7a6"), "far_d": Color("a8bccb"),
}

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
