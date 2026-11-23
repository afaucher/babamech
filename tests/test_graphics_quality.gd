extends TestCase
## GraphicsQuality (scripts/app/graphics_quality.gd), headless: apply_viewport sets the render scale / scaling mode / MSAA /
## screen-space AA expected per level (LOW 0.67 no MSAA, MEDIUM 0.85, HIGH 1.0 with the player's MSAA); apply_environment
## drops glow / SSAO / SSIL / SSR below HIGH and puts them back at HIGH; the integrated-GPU rule; the renderer
## override.cfg writer keeps other keys and removes an emptied file.

const OVR := "user://test_graphics_override.cfg"


func setup() -> void:
	GraphicsQuality.override_level = -1
	GraphicsQuality.use_settings({"quality": CityQuality.HIGH, "msaa": 2})
	var vp := SubViewport.new()
	add_child(vp)
	var fsr := GraphicsQuality.fsr_available()
	GraphicsQuality.apply_viewport(vp, CityQuality.LOW)
	near(vp.scaling_3d_scale, 0.67, 0.001, "LOW: 3D render scale 0.67")
	eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR if fsr else Viewport.SCALING_3D_MODE_BILINEAR, "LOW: FSR when available")
	eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "LOW: MSAA off whatever the setting")
	eq(vp.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED, "LOW: no screen-space AA")
	check(not vp.use_taa, "LOW: no TAA")
	GraphicsQuality.apply_viewport(vp, CityQuality.MEDIUM)
	near(vp.scaling_3d_scale, 0.85, 0.001, "MEDIUM: 3D render scale 0.85")
	eq(vp.msaa_3d, Viewport.MSAA_4X, "MEDIUM: the player's MSAA (4x)")
	GraphicsQuality.apply_viewport(vp, CityQuality.HIGH)
	near(vp.scaling_3d_scale, 1.0, 0.001, "HIGH: full resolution")
	eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_BILINEAR, "HIGH: no upscaler")
	eq(vp.msaa_3d, Viewport.MSAA_4X, "HIGH: the player's MSAA (4x)")
	GraphicsQuality.use_settings({"quality": CityQuality.LOW, "msaa": 1})
	GraphicsQuality.apply_viewport(vp)   # the level in force
	near(vp.scaling_3d_scale, 0.67, 0.001, "default level: the setting (LOW)")
	GraphicsQuality.override_level = CityQuality.HIGH
	GraphicsQuality.apply_viewport(vp)
	near(vp.scaling_3d_scale, 1.0, 0.001, "the --quality override wins")
	eq(vp.msaa_3d, Viewport.MSAA_2X, "HIGH with the 2x setting")
	GraphicsQuality.override_level = -1
	vp.queue_free()

	var env := Environment.new()
	env.glow_enabled = true
	env.ssao_enabled = true
	env.ssil_enabled = true
	env.ssr_enabled = false
	GraphicsQuality.apply_environment(env, CityQuality.LOW)
	check(not env.glow_enabled and not env.ssao_enabled and not env.ssil_enabled and not env.ssr_enabled,
			"LOW: no glow / SSAO / SSIL / SSR")
	GraphicsQuality.apply_environment(env, CityQuality.MEDIUM)
	check(env.glow_enabled and not env.ssao_enabled and not env.ssil_enabled, "MEDIUM: glow only")
	GraphicsQuality.apply_environment(env, CityQuality.HIGH)
	check(env.glow_enabled and env.ssao_enabled and env.ssil_enabled and not env.ssr_enabled,
			"HIGH: the environment's own extras back")

	# The integrated-GPU rule.
	var other_t := RenderingDevice.DEVICE_TYPE_OTHER
	check(GraphicsQuality.is_integrated("Intel(R) UHD Graphics 620", other_t), "UHD 620 is integrated")
	check(GraphicsQuality.is_integrated("Intel(R) Iris(R) Xe Graphics", other_t), "Iris Xe is integrated")
	check(GraphicsQuality.is_integrated("AMD Radeon(TM) Graphics", other_t), "a Radeon APU is integrated")
	check(GraphicsQuality.is_integrated("Some GPU", RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU), "the driver's integrated type")
	check(not GraphicsQuality.is_integrated("NVIDIA GeForce RTX 3080", RenderingDevice.DEVICE_TYPE_DISCRETE_GPU), "an RTX is dedicated")
	check(not GraphicsQuality.is_integrated("AMD Radeon RX 6700 XT", other_t), "an RX is dedicated")
	check(not GraphicsQuality.is_integrated("Intel(R) Arc(TM) A770 Graphics", other_t), "Arc A770 is dedicated")
	check(not GraphicsQuality.is_integrated("", other_t), "unknown (headless) is not integrated")
	eq(GraphicsQuality.renderer_wanted("forward_plus"), "forward_plus", "explicit Forward+")
	eq(GraphicsQuality.renderer_wanted("gl_compatibility"), "gl_compatibility", "explicit Compatibility")
	eq(GraphicsQuality.renderer_wanted("auto"), "gl_compatibility" if GraphicsQuality.detect() == CityQuality.LOW else "forward_plus",
			"auto follows the detection")
	check(not GraphicsQuality.can_switch_renderer(), "a dev run never writes override.cfg")

	# override.cfg: write Compatibility next to another key, read it back, Forward+ erases only ours, an emptied file goes.
	var path := ProjectSettings.globalize_path(OVR)
	DirAccess.remove_absolute(path)
	eq(GraphicsQuality.read_override(path), "", "no file: no override")
	check(GraphicsQuality.write_override(path, "forward_plus"), "Forward+ with no file: nothing to do")
	check(not FileAccess.file_exists(path), "Forward+ writes no file")
	var cfg := ConfigFile.new()
	cfg.set_value("display", "window/size/mode", 0)
	cfg.save(path)
	check(GraphicsQuality.write_override(path, "gl_compatibility"), "writes Compatibility")
	eq(GraphicsQuality.read_override(path), "gl_compatibility", "reads Compatibility back")
	var back := ConfigFile.new()
	back.load(path)
	eq(back.get_value("display", "window/size/mode", -1), 0, "another key survives")
	check(GraphicsQuality.write_override(path, "forward_plus"), "Forward+ erases our key")
	eq(GraphicsQuality.read_override(path), "", "no renderer override left")
	check(FileAccess.file_exists(path), "the file stays for the other key")
	DirAccess.remove_absolute(path)
	GraphicsQuality.write_override(path, "gl_compatibility")
	GraphicsQuality.write_override(path, "forward_plus")
	check(not FileAccess.file_exists(path), "an emptied override.cfg is removed")

	# The first-launch relaunch rule (integrated GPU pretended so "auto" wants Compatibility).
	GraphicsQuality.pretend_integrated = true
	var none: PackedStringArray = []
	var fp := "forward_plus"
	eq(GraphicsQuality.relaunch_block("auto", none, none, true, false, false, "", fp), "", "exported, integrated, auto, Forward+: relaunch")
	check(GraphicsQuality.relaunch_block("auto", none, none, false, false, false, "", fp) != "", "never in a dev run")
	check(GraphicsQuality.relaunch_block("auto", none, none, true, true, false, "", fp) != "", "never headless")
	check(GraphicsQuality.relaunch_block("auto", PackedStringArray([GraphicsQuality.NO_RELAUNCH_FLAG]), none, true, false, false, "", fp) != "",
		"never twice (the guard flag)")
	check(GraphicsQuality.relaunch_block("auto", PackedStringArray(["--run-test", "x"]), none, true, false, false, "", fp) != "", "never in a test")
	check(GraphicsQuality.relaunch_block("auto", none, none, true, false, false, "gl_compatibility", fp) != "",
		"not when override.cfg already chose (the second launch)")
	check(GraphicsQuality.relaunch_block("forward_plus", none, none, true, false, false, "", fp) != "", "not when the player chose")
	check(GraphicsQuality.relaunch_block("auto", none, PackedStringArray(["--rendering-method", fp]), true, false, false, "", fp) != "",
		"not when the command line names a renderer")
	check(GraphicsQuality.relaunch_block("auto", none, none, true, false, false, "", "gl_compatibility") != "", "not on Compatibility already")
	eq(GraphicsQuality.relaunch_block("auto", none, none, true, false, true, "", fp), "started by Steam", "a Steam launch only writes the file")
	GraphicsQuality.pretend_integrated = false
	if not GraphicsQuality.integrated_here():
		check(GraphicsQuality.relaunch_block("auto", none, none, true, false, false, "", fp) != "", "a dedicated GPU never relaunches")
	finish()
