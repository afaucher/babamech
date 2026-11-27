extends TestCase
## VISUAL: no "BUG, indexing did not unpair geometries from light" from the renderer (a user playtest spammed it).
##
## Godot's scene cull pairs a geometry with every omni light whose AABB it touches and whose cull mask has one of the
## geometry's layers, and unpairs it with the same mask test. On Forward+ (clustered) changing a geometry's `layers` while
## it is in the tree does NOT unpair it first (renderer_scene_cull.cpp instance_set_layer_mask only does on the
## mobile / compatibility paths), so a geometry moved from layer 1 (lit by every deck's fills: CityLightRig.ALWAYS) to
## its deck's layer stays in the fills of the OTHER decks for good; freeing such a fill prints the error (and the light
## keeps a dangling pointer once the geometry is gone). Needs a real renderer: headless has no scene cull.
##
## What it exercises, the way a crew mission loads (frames between the steps, so the renderer pairs in between): a
## stack with its rig, ambient life set up one chunk per frame, quality switches (fills hidden and shown, decks hidden),
## a first-person toggle (ChaseCamera.hide_from_first_person moves the pilot head to layer 20), the stack rebuilt (fills
## freed), then everything freed. The engine log (--log-file, which the runner gives every visual test) must not have
## the line.

const VISUAL := true
const NEEDLE := "did not unpair geometries"
const SEED := 4


func setup() -> void:
	timeout_sec = 240.0
	if not ShotCheck.available():
		print("test_render_unpair needs a renderer: run .\\test_runner.ps1 -Visual -TestName test_render_unpair")
		finish()
		return
	var log_path := _log_path()
	check(log_path != "", "the runner's log file test_logs/test_render_unpair.log exists")
	var base := _count(log_path)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var st := CityStack.new()
	add_child(st)
	st.build_begin(SectionPlan.make({"seed": SEED}))
	while not st.build_step(4.0):
		await frames(1)
	await frames(3)
	var at := st.entry_transform()
	cam.global_transform = at.translated_local(Vector3(0, 6, 8))
	var life := AmbientLife.new()
	add_child(life)
	life.setup_stack_begin(st)
	while not life.setup_step(0.0):
		await frames(2)       # a frame drawn between every chunk: the renderer pairs what is there
	await frames(10)
	print("[Unpair] after life setup: %d" % (_count(log_path) - base))
	eq(_count(log_path) - base, 0, "no unpair error after the stepped life setup")
	for q: int in [GraphicsQuality.LOW, GraphicsQuality.MEDIUM, GraphicsQuality.HIGH, GraphicsQuality.LOW]:
		st.set_quality(q)
		await frames(5)
	for k in st.decks.size():
		st.set_active_deck(k)
		await frames(4)
	st.set_quality(GraphicsQuality.HIGH)
	await frames(5)
	# First person: a mech's pilot head moves to ChaseCamera.FP_HIDDEN_LAYER (in CityLightRig.ALWAYS).
	var mech := MechModel.new()
	add_child(mech)
	mech.global_transform = at
	await frames(3)
	ChaseCamera.hide_from_first_person(mech)
	await frames(3)
	mech.queue_free()
	await frames(3)
	print("[Unpair] after switches: %d" % (_count(log_path) - base))
	eq(_count(log_path) - base, 0, "no unpair error after quality / active deck / first-person switches")
	# The rig's fills freed while life is still there (CityLightRig._clear_fills on a rebuild of the rig).
	if st.rig != null:
		st.rig.setup_decks([])
	await frames(5)
	print("[Unpair] after fills freed: %d" % (_count(log_path) - base))
	eq(_count(log_path) - base, 0, "no unpair error when the fills are freed")
	life.queue_free()
	st.queue_free()
	await frames(5)
	print("[Unpair] after all freed: %d" % (_count(log_path) - base))
	eq(_count(log_path) - base, 0, "no unpair error when everything is freed")
	cam.queue_free()
	finish()


## The runner's --log-file for this test (test_logs/<name>.log; Godot keeps engine options out of get_cmdline_args).
static func _log_path() -> String:
	var path := ProjectSettings.globalize_path("res://test_logs/test_render_unpair.log")
	return path if FileAccess.file_exists(path) else ""


## Lines of the engine log with NEEDLE so far (the file logger flushes on every error).
static func _count(path: String) -> int:
	if path == "":
		return 0
	var text := FileAccess.get_file_as_string(path)
	return text.count(NEEDLE)
