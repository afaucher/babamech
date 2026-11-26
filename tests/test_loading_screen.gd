extends TestCase
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## The mission loading screen (LoadingScreen, docs/design/hud.md "Loading screen") in a SOLO test drive:
## 1. Covered solo load (TestDrive.cover_solo, the game's solo path): the screen is up and opaque in the same frame the
##    scene is added (before anything was drawn), every frame until `loaded`, with the HUD hidden; it shows the mission
##    and, once known, the section; then it fades out (LoadingScreen.fade_in_tests) and is freed, and the HUD shows.
## 2. The tests' synchronous solo load (inside _ready): the screen is up during _ready and gone by the end of it.
## 3. LoadingScreen alone: phases only move the bar forward, the section line from a SectionPlan, the crew rows.
## The 2-peer crew case is test_net_loading_screen.

func setup() -> void:
	await _covered_solo()
	await _sync_solo()
	_unit()
	finish()


func _covered_solo() -> void:
	TestDrive.cover_solo = true
	LoadingScreen.fade_in_tests = true
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 3
	add_child(td)
	var ls := td.loading_screen
	if not check(ls != null and is_instance_valid(ls), "the loading screen is up as soon as the scene is added"):
		TestDrive.cover_solo = false
		LoadingScreen.fade_in_tests = false
		return
	check(ls.covering() and ls.layer >= LoadingScreen.LAYER, "it is opaque and on top from the first frame")
	check(not td.loaded, "the covered solo load has not built yet (it lets the screen draw first)")
	check(ls.mission_label.text.begins_with("Section "), "it names the mission (%s)" % ls.mission_label.text)
	var bad := 0
	var hud_seen := 0
	var frames_ := 0
	var section_seen := false
	while not td.loaded and frames_ < 2000:
		await get_tree().process_frame
		frames_ += 1
		if td.loaded:
			break
		if not is_instance_valid(ls) or not ls.covering():
			bad += 1
		var hud := td.get_node_or_null("MechHud") as MechHud
		if hud != null and hud.visible:
			hud_seen += 1
		if is_instance_valid(ls) and ls.section_label.text.contains("deck"):
			section_seen = true
	check(td.loaded, "the solo load finishes (%d frames)" % frames_)
	eq(bad, 0, "the screen covered every frame of the load")
	eq(hud_seen, 0, "the HUD stayed hidden under it")
	check(section_seen, "the section line showed the decks")
	check(td.loading_screen == null, "the drive let go of the screen at loaded")
	var gone := false
	for i in 120:
		if not is_instance_valid(ls):
			gone = true
			break
		await get_tree().process_frame
	check(gone, "the screen faded out and was freed")
	var hud2 := td.get_node_or_null("MechHud") as MechHud
	check(hud2 != null and hud2.visible, "the HUD shows after the screen")
	td.queue_free()
	await frames(2)
	TestDrive.cover_solo = false
	LoadingScreen.fade_in_tests = false


func _sync_solo() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	var seen := [false]
	td.child_entered_tree.connect(func(n: Node) -> void:
		if n is LoadingScreen and td.mech == null:
			seen[0] = true)
	add_child(td)
	check(seen[0], "the synchronous load puts the screen up before the mech exists")
	check(td.loaded, "the tests' solo load is done inside _ready")
	check(td.loading_screen == null, "and the screen is down at its end")
	await frames(1)
	eq(td.find_children("*", "LoadingScreen", true, false).size(), 0, "no loading screen left in the scene")
	var hud := td.get_node_or_null("MechHud") as MechHud
	check(hud != null and hud.visible, "the HUD shows")
	td.queue_free()
	await frames(2)


func _unit() -> void:
	var ls := LoadingScreen.cover(self)
	ls.set_phase("build", 0.5)
	var p := ls.progress
	ls.set_phase("build", 0.2)
	eq(ls.progress, p, "the bar never goes back")
	ls.set_phase("shaders", 1.0)
	near(ls.progress, 1.0, 0.001, "the end of the warm-up fills the bar")
	var sec := SectionPlan.make({"seed": 57036.0})
	var t := LoadingScreen.section_text(sec)
	check(t.begins_with("%d decks" % sec.deck_count) and t.contains("entry deck"), "the section line: %s" % t)
	ls.crew_source = func() -> Array:
		return [{"peer": 1, "name": "Host", "head": "dog", "accent": "blue", "status": "ready", "local": true},
			{"peer": 2, "name": "c1", "head": "chicken", "accent": "green", "status": "loading"}]
	ls.refresh_crew()
	eq(ls.crew_rows().size(), 2, "one row per crew member")
	check(ls.crew_box.visible, "the crew list shows in a crew")
	ls.set_phase("crew", 1.0)
	check(ls.phase_text().contains("1 / 2 ready"), "the crew phase counts the ready ones (%s)" % ls.phase_text())
	ls.queue_free()
