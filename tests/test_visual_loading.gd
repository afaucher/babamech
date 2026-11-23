extends TestCase
## VISUAL: the mission loading screen (LoadingScreen, docs/design/hud.md "Loading screen") really draws, and covers the
## mission scene while it loads. Runs only under `.\test_runner.ps1 -Visual`. Shots in test_logs/shots/:
##   loading_solo_midload   a real solo test drive (TestDrive.cover_solo) caught before its build: only the screen shows
##   loading_solo_done      the same drive once the screen has faded: the world (the screen is gone)
##   loading_coop_wait      the screen with a crew of three waiting at the barrier (demo crew rows)

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_loading needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	timeout_sec = 120.0
	var centre := Rect2(0.3, 0.3, 0.4, 0.4)
	var edge := Rect2(0.0, 0.0, 0.12, 1.0)
	# 1. A real solo drive, covered: shot while the screen is up and the city not built yet.
	TestDrive.cover_solo = true
	LoadingScreen.fade_in_tests = true
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 57036
	add_child(td)
	await get_tree().process_frame
	check(td.loading_screen != null and td.loading_screen.covering() and not td.loaded, "the solo drive is covered mid-load")
	var mid := await sc.grab("loading_solo_midload")
	sc.not_blank(mid, centre, "the loading screen's centre (title, bar)")
	if mid != null:
		check(float(ShotCheck.stats(mid, edge)["mean"]) < 0.12, "the edges are the dark backdrop, no world showing")
	while not td.loaded:
		await get_tree().process_frame
	await frames(40)
	check(td.loading_screen == null, "the screen came down after the load")
	var done := await sc.grab("loading_solo_done")
	if mid != null and done != null:
		var dm := absf(float(ShotCheck.stats(mid, edge)["mean"]) - float(ShotCheck.stats(done, edge)["mean"]))
		check(dm > 0.02 or float(ShotCheck.stats(done, edge)["colours"]) > float(ShotCheck.stats(mid, edge)["colours"]),
			"the world shows once the screen is gone")
	td.queue_free()
	await frames(2)
	TestDrive.cover_solo = false
	# 2. The crew wait: three members, two ready.
	var ls := LoadingScreen.cover(self)
	ls.set_mission(57036)
	ls.set_section(SectionPlan.make({"seed": 57036.0}))
	ls.crew_source = func() -> Array:
		return [{"peer": 1, "name": "Alpha", "head": "dog", "accent": "orange", "status": "ready", "local": true},
			{"peer": 2, "name": "Bravo", "head": "chicken", "accent": "blue", "status": "ready"},
			{"peer": 3, "name": "Charlie", "head": "pickle", "accent": "green", "status": "loading"}]
	ls.set_phase("crew", 1.0)
	await frames(30)
	var wait := await sc.grab("loading_coop_wait")
	sc.not_blank(wait, centre, "the crew wait screen")
	ls.queue_free()
	LoadingScreen.fade_in_tests = false
	await frames(1)
	finish()
