class_name ShaderWarmup
extends Node3D
## First-run shader / pipeline warm-up for a mission scene (the UHD 620 LAN test: six 0.5-3.4 s stalls in the first
## mission, none in the second, so they were shader and pipeline compilation on first draw).
##
## run(cam, scan_root) puts ONE copy of every distinct look in front of the camera, under it (so the copies sit in the
## frustum, inside the directional shadow range, lit by the same lights as play), behind an opaque "Preparing..." overlay,
## and keeps them there until the renderer stops compiling pipelines (RenderingServer's PIPELINE_COMPILATIONS counters
## still for SETTLE frames; MIN_FRAMES..MAX_FRAMES, MAX_MS), then frees them. A look is (material, vertex format, shadow
## casting, mesh / multimesh layout): the city's merged deck meshes share one palette material, so a scene of thousands
## of meshes needs a few dozen copies. Covered:
##   - everything under `scan_root` (the mission scene: every deck of the stack, hidden ones too, the mechs with their
##     hidden thruster / muzzle nodes, enemies, the pilot heads, civilians and vehicles (MultiMesh), props, HUD markers);
##   - what play makes later (extras()): every shared material on a MeshKit mesh (MechMeshes, LowPolyFlame, the trail
##     ribbon, the radiator glow, the enemy flash / charred / scanner, MechParts' opaque / see-through / emissive, the
##     city surface and strip, the aim markers' unshaded double-sided ones), the meshes the FX caches hold (CombatMeshes,
##     ImpactFx, LowPolyFlame, MuzzleFlash, EnemyMeshes with its wreck / debris prewarm), a projectile trail
##     (ImmediateMesh), a rail slug ribbon (its own shader, custom vertex format), an enemy tag (Label3D) and every pilot
##     head.
## Cosmetic and local (no state, no rolls). Nothing to do headless (nothing draws): should_run() is false there.
##
## Godot settles the rest: the shader cache (rendering/shader_compiler/shader_cache, on by default) keeps compiled shaders
## between runs, the pipeline cache (rendering/rendering_device/pipeline_cache) keeps Vulkan pipelines, so the second
## launch is quick anyway; this makes the FIRST one (and every first mission after a driver update) quick too.

const NEAR := 1.0             ## m in front of the camera
const MIN_FRAMES := 3
const MAX_FRAMES := 240
const MAX_MS := 8000          ## give up waiting for the counters after this (the copies have been drawn by then)
const SETTLE := 3             ## frames with no new pipeline compilation that end the warm-up
const OVERLAY_LAYER := 120

## The dev flag --no-shader-warmup turns it off (measuring the "before").
static var enabled := true
## Tests (--run-test) skip it (a visual test shooting the scene a few frames in would get the overlay), unless one sets
## this.
static var in_tests := false
## The materials the warm-up made, kept for the whole session. StandardMaterial3D shares one shader per feature set and frees
## it with its last user, so a feature set only transient things use (a pilot face toggling emission_enabled, an FX
## material) would be compiled again, pipelines and all, every time it comes back: measured as 2 draw-time pipeline
## compilations every few seconds of play until these were kept.
static var _keep: Array[Material] = []
static var _made_by_key: Dictionary = {}

var report: Dictionary = {}
var _keys: Dictionary = {}
var _items: Array[GeometryInstance3D] = []
var _sizes: Array[AABB] = []
var _overlay: CanvasLayer


static func should_run() -> bool:
	return enabled and DisplayServer.get_name() != "headless" \
		and (in_tests or not OS.get_cmdline_user_args().has("--run-test"))


## The renderer's pipeline compilations so far, by kind (Forward+ / Mobile; Compatibility reports zeros).
static func compilations() -> Dictionary:
	return {
		"canvas": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS),
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"specialization": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}


static func _total(c: Dictionary) -> int:
	var t := 0
	for k: String in c:
		t += int(c[k])
	return t


## Warm up under `cam` and return the report {items, frames, ms, compiled: {kind: n}}. Await it. `scan_root` null: the
## extras only. `text`: the overlay's line. `overlay` false: no overlay of its own (the mission's LoadingScreen covers it).
static func warm(cam: Camera3D, scan_root: Node, text: String = "Preparing shaders...", overlay: bool = true) -> Dictionary:
	if cam == null or not cam.is_inside_tree():
		return {}
	var w := ShaderWarmup.new()
	w.name = "ShaderWarmup"
	cam.add_child(w)
	var r := await w._run(cam, scan_root, text if overlay else "")
	if is_instance_valid(w):
		w.queue_free()
	return r


func _run(cam: Camera3D, scan_root: Node, text: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var before := compilations()
	if text != "":
		_show_overlay(text)
	if scan_root != null:
		_scan(scan_root)
	_extras()
	_layout(cam)
	var t_built := Time.get_ticks_msec() - t0
	var frames := 0
	var still := 0
	var last := _total(compilations())
	while frames < MAX_FRAMES and is_inside_tree():
		await RenderingServer.frame_post_draw
		frames += 1
		var now := _total(compilations())
		still = still + 1 if now == last else 0
		last = now
		if frames >= MIN_FRAMES and (still >= SETTLE or Time.get_ticks_msec() - t0 > MAX_MS):
			break
	var after := compilations()
	var compiled := {}
	for k: String in after:
		compiled[k] = int(after[k]) - int(before.get(k, 0))
	report = {"items": _items.size(), "frames": frames, "ms": Time.get_ticks_msec() - t0, "build_ms": t_built,
		"compiled": compiled, "renderer": RenderingServer.get_current_rendering_method()}
	print("[Warmup] %d looks drawn for %d frames in %d ms (built in %d ms), %s, pipelines compiled %s" % [_items.size(),
		frames, int(report["ms"]), t_built, report["renderer"], str(compiled)])
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null
	return report


func _show_overlay(text: String) -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = OVERLAY_LAYER
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.04, 0.05)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(bg)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 28)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(label)
	add_child(_overlay)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# --- What to draw ----------------------------------------------------------------------------------------------------

func _scan(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == self:
			continue
		if n is MeshInstance3D:
			_take_instance(n as MeshInstance3D)
		elif n is MultiMeshInstance3D:
			_take_multimesh(n as MultiMeshInstance3D)
		for c: Node in n.get_children():
			stack.append(c)


static func _id(o: Object) -> int:
	return o.get_instance_id() if o != null else 0


static func _format(mesh: Mesh, i: int) -> String:
	return str((mesh as ArrayMesh).surface_get_format(i)) if mesh is ArrayMesh else mesh.get_class()


## A MeshInstance3D: copied when one of its surfaces is a look not seen yet.
func _take_instance(mi: MeshInstance3D) -> void:
	var mesh := mi.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var shadow := mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fresh := false
	for i in mesh.get_surface_count():
		var k := "m|%d|%s|%s|%d" % [_id(mi.get_active_material(i)), _format(mesh, i), shadow, _id(mi.material_overlay)]
		if not _keys.has(k):
			_keys[k] = true
			fresh = true
	if not fresh:
		return
	var c := MeshInstance3D.new()
	c.mesh = mesh
	c.material_override = mi.material_override
	c.material_overlay = mi.material_overlay
	for i in mi.get_surface_override_material_count():
		c.set_surface_override_material(i, mi.get_surface_override_material(i))
	c.cast_shadow = mi.cast_shadow
	c.transparency = mi.transparency
	c.layers = mi.layers
	_add(c, mesh.get_aabb())


## A MultiMeshInstance3D (crowds, cars, props): one instance in a MultiMesh of the same layout.
func _take_multimesh(mmi: MultiMeshInstance3D) -> void:
	var src := mmi.multimesh
	if src == null or src.mesh == null or src.mesh.get_surface_count() == 0:
		return
	var shadow := mmi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fresh := false
	for i in src.mesh.get_surface_count():
		var mat: Material = mmi.material_override if mmi.material_override != null else src.mesh.surface_get_material(i)
		var k := "mm|%d|%s|%s|%d|%s|%s" % [_id(mat), _format(src.mesh, i), shadow, src.transform_format, src.use_colors,
			src.use_custom_data]
		if not _keys.has(k):
			_keys[k] = true
			fresh = true
	if not fresh:
		return
	var mm := MultiMesh.new()
	mm.transform_format = src.transform_format
	mm.use_colors = src.use_colors
	mm.use_custom_data = src.use_custom_data
	mm.mesh = src.mesh
	mm.instance_count = 1
	if mm.transform_format == MultiMesh.TRANSFORM_3D:
		mm.set_instance_transform(0, Transform3D.IDENTITY)
	else:
		mm.set_instance_transform_2d(0, Transform2D.IDENTITY)
	if mm.use_colors:
		mm.set_instance_color(0, Color.WHITE)
	if mm.use_custom_data:
		mm.set_instance_custom_data(0, Color(0, 0, 0, 0))
	var c := MultiMeshInstance3D.new()
	c.multimesh = mm
	c.material_override = mmi.material_override
	c.cast_shadow = mmi.cast_shadow
	c.layers = mmi.layers
	_add(c, src.mesh.get_aabb())


## A mesh resource on its own (an FX cache): drawn as the FX draw it (CombatMeshes.instance: no shadow).
func _take_mesh(mesh: Mesh, shadow: bool = false) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_take_instance(mi)
	mi.free()


## A material on a MeshKit mesh (the format nearly everything in the game has).
func _take_material(mat: Material, shadow: bool = true) -> void:
	if mat == null:
		return
	if not _keep.has(mat):
		_keep.append(mat)
	var mi := MeshInstance3D.new()
	mi.mesh = CombatMeshes.ico(LowPolyPalette.GREY)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_take_instance(mi)
	mi.free()


func _extras() -> void:
	# Shared materials (StandardMaterial3D shares a compiled shader between materials with the same features, so one per
	# feature set covers every copy and tint: the accents, each mech's radiator glow, each head's face).
	for m: Variant in LowPolyMaterials.materials():
		_take_material(m as Material)
	_take_material(LowPolyFlame.material(), false)
	_take_material(CombatMeshes.ribbon_material(), false)
	_take_material(_made("glow", func() -> Material: return EquipmentLook.make_glow_material()))
	_take_material(EnemyMeshes.flash_material(), false)
	_take_material(EnemyMeshes.charred_material())
	_take_material(EnemyMeshes.scanner_material(), false)
	_take_material(MechParts.mat(LowPolyPalette.GREY))
	_take_material(MechParts.mat(LowPolyPalette.GREY, 0.5))
	_take_material(MechParts.mat(LowPolyPalette.GREY, 1.0, true))
	_take_material(CityPalette.surface_material())
	_take_material(CityPalette.strip_material())
	_take_material(_made("unshaded", func() -> Material: return _unshaded(1.0)), false)   # opaque aim markers
	_take_material(_made("unshaded_alpha", func() -> Material: return _unshaded(0.5)), false)   # see-through aim markers
	# Meshes play builds on demand: make the common FX ones now, then take every FX cache.
	EnemyMeshes.prewarm()
	ImpactFx.flame_ball(LowPolyFlame.MID)
	LowPolyFlame.jet()
	MuzzleFlash.mesh()
	CombatMeshes.ico(LowPolyPalette.WHITE, true)
	CombatMeshes.shell(LowPolyPalette.AMBER, 0.38, true)
	CombatMeshes.ring(LowPolyPalette.ORANGE, 0.9, 16)
	for cache: Dictionary in [CombatMeshes.cached_meshes(), ImpactFx.cached_meshes(), LowPolyFlame.cached_meshes(), EnemyMeshes.cached_meshes()]:
		for m: Variant in cache.values():
			if m is Mesh:
				_take_mesh(m as Mesh)
	_trail()
	_rail_ribbon()
	_tag()
	_heads()


## A material this class makes once per session (kept in _keep by _take_material).
static func _made(key: String, make: Callable) -> Material:
	if not _made_by_key.has(key):
		_made_by_key[key] = make.call()
	return _made_by_key[key]


static func _unshaded(alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(1, 1, 1, alpha)
	if alpha < 0.99:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## A projectile / mortar trail: an ImmediateMesh with the ribbon material, vertex colours (Projectile._draw_trail).
func _trail() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, CombatMeshes.ribbon_material())
	im.surface_set_color(LowPolyPalette.AMBER)
	im.surface_add_vertex(Vector3(-0.5, -0.5, 0))
	im.surface_add_vertex(Vector3(0.5, -0.5, 0))
	im.surface_add_vertex(Vector3(0, 0.5, 0))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(mi, AABB(Vector3(-0.5, -0.5, -0.05), Vector3(1, 1, 0.1)))


## A rail slug ribbon: RailSlug's own shader (the same Shader object, made the way RailSlug makes it) on its vertex
## format (vertex, colour, CUSTOM0 RGBA float).
func _rail_ribbon() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = RailSlug.ribbon_shader()
	mat.set_shader_parameter("life", 1.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0, 0.5, 0)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_CUSTOM0] = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(mi, AABB(Vector3(-0.5, -0.5, -0.05), Vector3(1, 1, 0.1)))


## An enemy's name tag (EnemyStatusBar): billboard, fixed size, outline, no depth test.
func _tag() -> void:
	var t := Label3D.new()
	t.text = "W"
	t.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	t.fixed_size = true
	t.pixel_size = 0.00055
	t.font_size = 24
	t.outline_size = 6
	t.no_depth_test = true
	add_child(t)
	_items.append(t)
	_sizes.append(AABB(Vector3(-0.05, -0.05, -0.05), Vector3(0.1, 0.1, 0.1)))


## Every pilot head (a crew shows only its own): built, scanned for its looks, freed.
func _heads() -> void:
	for id: String in PilotHead.ids():
		var h := PilotHead.make(id, 0)
		_scan(h)
		h.free()


func _add(c: GeometryInstance3D, aabb: AABB) -> void:
	add_child(c)
	_items.append(c)
	_sizes.append(aabb)


## A grid filling the view NEAR m ahead, each look scaled into its cell.
func _layout(cam: Camera3D) -> void:
	var n := _items.size()
	if n == 0:
		return
	var vp := get_viewport()
	var aspect := 16.0 / 9.0
	if vp != null and vp.get_visible_rect().size.y > 0.0:
		aspect = vp.get_visible_rect().size.x / vp.get_visible_rect().size.y
	var hh := tan(deg_to_rad(cam.fov * 0.5)) * NEAR * 0.9
	var hw := hh * aspect
	var cols := maxi(int(ceil(sqrt(float(n) * aspect))), 1)
	var rows := maxi(int(ceil(float(n) / float(cols))), 1)
	var cell := minf(2.0 * hw / float(cols), 2.0 * hh / float(rows))
	position = Vector3.ZERO
	rotation = Vector3.ZERO
	for i in n:
		var col := i % cols
		var row := i / cols
		var at := Vector3(-hw + cell * (float(col) + 0.5), hh - cell * (float(row) + 0.5), -NEAR)
		var item := _items[i]
		if item is Label3D:
			item.position = at
			continue
		var box := _sizes[i]
		var big := maxf(maxf(box.size.x, box.size.y), maxf(box.size.z, 0.001))
		var s := cell * 0.8 / big
		item.scale = Vector3.ONE * s
		item.position = at - box.get_center() * s
