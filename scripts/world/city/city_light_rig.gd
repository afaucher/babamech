class_name CityLightRig
extends Node3D
## ALL of the city's lighting, and nothing else: the environment (sky colour, ambient, haze, tone mapping, contact
## shading), the "daylight" (a directional light standing in for the summed ceiling strips, with shadows), fill lights
## hung under the strips, and the glow of the strip material. The city's meshes and colours (CityPalette) don't know this
## node exists: swap the preset, or the whole rig, and the same geometry is relit. Nothing here is gameplay.
##
##   var rig := CityLightRig.new(); add_child(rig)
##   rig.setup(ring, area, ceiling_height, strip_x)     # where the strips are
##   rig.apply("dusk")
## A stack of decks (CityStack) shares one rig: setup_decks() hangs every deck's fills with a cull mask of that deck's
## render layer, and light_layers() limits the daylight (light and shadow casters) to the deck being looked at.
## Layers in ALWAYS (layer 1: mechs and everything that is not a deck; layer 20: the local pilot head, which the
## first-person camera hides, ChaseCamera.FP_HIDDEN_LAYER) are lit by every fill and by the daylight on every deck.

const PRESETS := {
	# Locked look: bright warm artificial daylight, soft blue haze (docs/design/game-design.md 11).
	"day": {
		"sky": Color("a9cfe8"), "ambient": Color("cfdcec"), "ambient_energy": 0.4,
		"sun": Color("ffe9c4"), "sun_energy": 0.95, "sun_pitch": 58.0, "sun_yaw": 32.0,
		"strip": Color("fff4dc"), "strip_energy": 3.0, "fill": Color("ffe9c4"), "fill_energy": 0.2,
		"fog": Color("b7d3e8"), "fog_density": 0.0014, "exposure": 1.0,
	},
	# Evening cycle: strips dimmed to amber, long shadows, mauve air.
	"dusk": {
		"sky": Color("4c4166"), "ambient": Color("756fa3"), "ambient_energy": 0.3,
		"sun": Color("ff9450"), "sun_energy": 0.8, "sun_pitch": 22.0, "sun_yaw": 68.0,
		"strip": Color("ffb066"), "strip_energy": 2.2, "fill": Color("ff9c50"), "fill_energy": 0.7,
		"fog": Color("7d6488"), "fog_density": 0.0022, "exposure": 1.0,
	},
	# Clinical: cold, even, shadowless-looking light straight down; thick white air.
	"clinical": {
		"sky": Color("dfe7ea"), "ambient": Color("eef3f5"), "ambient_energy": 0.62,
		"sun": Color("f2f8ff"), "sun_energy": 0.5, "sun_pitch": 86.0, "sun_yaw": 0.0,
		"strip": Color("eaf4ff"), "strip_energy": 3.4, "fill": Color("e6f1ff"), "fill_energy": 0.25,
		"fog": Color("e4ecee"), "fog_density": 0.0034, "exposure": 1.0,
	},
}
const FILL_PITCH_S := 36.0       ## spacing of fill lights along the arc (m)
const MAX_FILLS := 48            ## per deck
const ALL_LAYERS := 0xFFFFFFFF
## Render layers every light of the rig lights and the daylight takes shadows from, on every deck: layer 1 (mechs,
## enemies, effects: everything not on a deck layer) and layer 20 (the local pilot head, ChaseCamera.FP_HIDDEN_LAYER,
## so it stays lit in third person and in other views while the first-person camera culls it). Deck layers are bits
## 1..deck_count, far below bit 19.
const ALWAYS := 1 | (1 << 19)

var preset := "day"
var env: Environment
var sun: DirectionalLight3D
var quality := CityQuality.HIGH  ## local presentation (CityQuality): set_quality

var _world: WorldEnvironment
var _fills: Node3D
var _deck_fills: Array = []      ## setup_decks: deck k -> its OmniLight3Ds (empty after setup(): one district)
var _shown: Array = []           ## set_quality: deck k is drawn (true / false); empty: every deck
var _active := 0                 ## set_quality: the active deck


static func preset_ids() -> Array[String]:
	var out: Array[String] = []
	for k: String in PRESETS:
		out.append(k)
	return out


func _init() -> void:
	name = "LightRig"
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_radius = 2.5
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.2
	env.glow_hdr_threshold = 1.4
	_world = WorldEnvironment.new()
	_world.name = "Environment"
	_world.environment = env
	add_child(_world)
	sun = DirectionalLight3D.new()
	sun.name = "Daylight"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 320.0
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.5
	add_child(sun)
	_fills = Node3D.new()
	_fills.name = "Fills"
	add_child(_fills)
	apply(preset)


## Hang the fill lights under the ceiling strips over `area` (arc coordinates).
func setup(ring: RingFrame, area: Rect2, ceiling: float, strip_x: PackedFloat32Array) -> void:
	_clear_fills()
	_hang(ring, Vector3.ZERO, area, ceiling, strip_x, ceiling * 1.5, ALL_LAYERS)
	light_layers(ALL_LAYERS)
	apply(preset)


## Fills for every deck of a stack: [{ring, offset, area, ceiling, strip_x, layer, reach}], offset = where the deck's
## ring frame sits in this rig's parent. Each deck's fills light only its own layer (and layer 1, the mechs) and reach
## no further than `reach`, so a deck seen through a hole is lit by its own strips.
func setup_decks(list: Array) -> void:
	_clear_fills()
	for d: Dictionary in list:
		var before := _fills.get_child_count()
		_hang(d["ring"], d["offset"], d["area"], d["ceiling"], d["strip_x"], d["reach"], ALWAYS | int(d["layer"]))
		_deck_fills.append(_fills.get_children().slice(before))
	apply(preset)


## The render layers the daylight lights and takes shadows from (the ALWAYS layers are always added).
func light_layers(mask: int) -> void:
	sun.light_cull_mask = mask | ALWAYS
	sun.shadow_caster_mask = mask | ALWAYS


func _clear_fills() -> void:
	_deck_fills.clear()
	for c in _fills.get_children():
		_fills.remove_child(c)
		c.queue_free()


func _hang(ring: RingFrame, offset: Vector3, area: Rect2, ceiling: float, strip_x: PackedFloat32Array, reach: float, mask: int) -> void:
	var xs: Array[float] = []
	for i in strip_x.size():
		if strip_x[i] >= area.position.x and strip_x[i] <= area.end.x and i % 2 == 0:
			xs.append(strip_x[i])
	var ns := maxi(int(round(area.size.y / FILL_PITCH_S)), 1)
	while xs.size() * ns > MAX_FILLS and xs.size() > 1:
		xs.remove_at(xs.size() / 2)
	for x in xs:
		for j in ns:
			var s := area.position.y + area.size.y * (float(j) + 0.5) / float(ns)
			var l := OmniLight3D.new()
			l.position = offset + ring.arc_to_world(x, s, ceiling - 2.5)
			l.omni_range = reach
			l.omni_attenuation = 1.3
			l.shadow_enabled = false
			l.light_cull_mask = mask
			_fills.add_child(l)


func apply(id: String) -> void:
	if not PRESETS.has(id):
		return
	preset = id
	var p: Dictionary = PRESETS[id]
	env.background_color = p["sky"]
	env.ambient_light_color = p["ambient"]
	env.ambient_light_energy = p["ambient_energy"]
	env.fog_light_color = p["fog"]
	env.fog_density = p["fog_density"]
	env.tonemap_exposure = p["exposure"]
	sun.light_color = p["sun"]
	sun.light_energy = p["sun_energy"]
	sun.rotation = Vector3(-deg_to_rad(float(p["sun_pitch"])), deg_to_rad(float(p["sun_yaw"])), 0.0)
	for l: OmniLight3D in _fills.get_children():
		l.light_color = p["fill"]
		l.light_energy = p["fill_energy"]
	# The strips glow because the rig says so: their emission is lighting, not surface colour.
	var strip := CityPalette.strip_material()
	strip.emission = p["strip"]
	strip.emission_energy_multiplier = p["strip_energy"]
	_apply_quality()


# --- Quality (CityQuality: local presentation) -----------------------------------------------------------------

## Draw level q (CityQuality.LOW / MEDIUM / HIGH). `shown`: per deck of setup_decks, whether it is drawn (empty: all);
## `active`: the deck the daylight is on. Fills of a deck not shown are hidden; the active deck keeps every
## `fill_every`-th fill, other shown decks every `other_fill_every`-th; the ambient rises for the active deck's fills
## switched off; shadows, splits, SSAO and glow follow the level. HIGH restores exactly what apply() sets.
func set_quality(q: int, shown: Array = [], active: int = 0) -> void:
	quality = CityQuality.clamp_level(q)
	_shown = shown.duplicate()
	_active = active
	_apply_quality()


## Omni fills switched on now (for tests and the perf probe).
func fills_on() -> int:
	var n := 0
	for l: OmniLight3D in _fills.get_children():
		if l.visible and not l.is_queued_for_deletion():
			n += 1
	return n


func _apply_quality() -> void:
	if not PRESETS.has(preset) or _fills == null:
		return
	var lv := CityQuality.level(quality)
	var p: Dictionary = PRESETS[preset]
	env.ssao_enabled = bool(lv["ssao"])
	env.glow_enabled = bool(lv["glow"])
	sun.shadow_enabled = bool(lv["sun_shadows"])
	sun.directional_shadow_max_distance = float(lv["shadow_distance"])
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if int(lv["shadow_splits"]) >= 4 \
			else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	var groups: Array = _deck_fills
	if groups.is_empty():
		groups = [_fills.get_children()]       # one district (setup): all its fills are the active deck's
	var active := _active if not _deck_fills.is_empty() else 0
	var off_share := 0.0
	for k in groups.size():
		var shown := k >= _shown.size() or bool(_shown[k])
		var every := int(lv["fill_every"]) if k == active else int(lv["other_fill_every"])
		if not shown:
			every = 0
		var list: Array = groups[k]
		var off := 0
		for i in list.size():
			var on := every > 0 and i % every == 0
			(list[i] as OmniLight3D).visible = on
			if not on:
				off += 1
		if k == active and not list.is_empty():
			off_share = float(off) / float(list.size())
	env.ambient_light_energy = float(p["ambient_energy"]) + float(lv["ambient_add"]) * float(p["fill_energy"]) * off_share
