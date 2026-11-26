extends TestCase
## VISUAL: the mission HUD in plan mode (mission objectives phase 1). Shots in test_logs/shots/:
## `objectives_hud_demo` (MechHud demo + MissionHud.demo_plan over a plain backdrop: the objective panel top right,
## DEMO_PLAN.panel: "DECK 1 OF 3", deck 1's flag and two bonuses, then "PROCEED TO DECK 2" and "RAMP DOWN 120 M"; the
## reinforcement line and zone bar under the objective line, a "? DEFEND" marker, the projected defend ring, the INBOUND
## arrow on the left edge) and `objectives_drive_flag` (a live solo stack drive in plan mode, seed 7, the mech standing
## in deck 1's flag ring with every enemy killed: the world's mast and ring, the list (the flag done: "PROCEED TO DECK 2"
## leads with its route hint, nothing of decks 2 and 3 listed), the zone bar).
## Runs only under `.\test_runner.ps1 -Visual` (hidden desktop, takes the GPU lock).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_objectives needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var bg := ColorRect.new()
	bg.color = Color(0.32, 0.36, 0.4)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var hud := MechHud.new()
	hud.demo = true
	add_child(hud)
	await frames(3)
	hud.mission_hud.demo_plan = true
	await frames(8)
	var img := await sc.grab("objectives_hud_demo")
	var vs := Vector2(img.get_width(), img.get_height())
	check(not hud.mission_hud.panel().is_empty(), "the demo draws the structured panel")
	eq(hud.mission_hud.shown_lines().slice(3), ["Proceed to deck 2", "ramp down 120 m"], "the demo: proceed to deck 2, the way")
	sc.not_blank(img, _frac(hud.mission_hud.list_panel.get_global_rect(), vs), "objective list")
	sc.not_blank(img, _frac(hud.mission_hud.alert_panel.get_global_rect(), vs), "reinforcement line")
	sc.not_blank(img, _frac(hud.mission_hud.zone_panel.get_global_rect(), vs), "zone bar")
	hud.queue_free()
	bg.queue_free()
	await frames(2)

	MissionFlow.test_plan = {"hold": 6.0}
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 7
	add_child(td)
	await frames(10)
	if check(td.mission != null and td.mission.plan != null, "plan mode drive"):
		for e in td.combat.squad.enemies.duplicate():
			if is_instance_valid(e) and not e.destroyed():
				e.apply_damage(1.0e7, e.core_component(), "test")
		td.drive_override = true
		td.mech.move_input = Vector2.ZERO
		var f := td.mission.plan.primary(0)
		var site: Dictionary = td.mission.rules.objective(f["id"])["site"]
		td.mech.global_position = td.stack.from_deck_arc(int(f["deck"]), float(site["x"]) - 6.0, float(site["s"]) - 6.0, 0.5)
		td.mech.velocity = Vector3.ZERO
		td.cam.reset_behind()
		await frames(300)
		var img2 := await sc.grab("objectives_drive_flag")
		var h2 := td.get_node_or_null("MechHud") as MechHud
		if h2 != null:
			check(h2.mission_hud.list_panel.visible, "the drive shows the objective list")
			check(str(h2.mission_hud.panel().get("header", "")).begins_with("DECK 1 of "), "the drive's panel: DECK 1 of n")
			var rows: Array = h2.mission_hud.shown_lines()
			print("drive panel rows: %s" % [rows])
			check(rows.has("Proceed to deck 2") or rows.has("Raise the flag: 100% (done)") or str(rows).contains("flag"),
				"the drive's panel lists deck 1's flag / the proceed line (%s)" % [rows])
			for r: Variant in rows:
				check(not str(r).begins_with("V1") and not str(r).contains("Deck 3"), "no prefix, deck 3 unlisted (%s)" % r)
			sc.not_blank(img2, _frac(h2.mission_hud.list_panel.get_global_rect(), Vector2(img2.get_width(), img2.get_height())),
				"drive objective list")
	td.queue_free()
	MissionFlow.test_plan = {}
	await frames(2)
	finish()


func _frac(r: Rect2, vs: Vector2) -> Rect2:
	var view := get_viewport().get_visible_rect().size
	return Rect2(r.position / view, r.size / view)
