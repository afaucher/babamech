extends TestCase
## VISUAL: the menu (main, settings, hangar) and the lab (every subject) really draw. Runs only under
## `.\test_runner.ps1 -Visual` (a real renderer, the window off screen; refuses while ComfyUI holds the GPU on port 8188).
## Shots land in test_logs/shots/ for a look. Checks are coarse on purpose (no golden images: the art is changing daily):
## the UI panel and the 3D view each show detail, and they differ from each other.

const VISUAL := true
const PATH := "user://test_visual_settings.cfg"

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	Session.set_profile("Visual", "chicken", "strider")
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(20)
	var panel := Rect2(0.0, 0.0, 0.3, 1.0)       # the 520 px menu panel of 1600
	var stage := Rect2(0.4, 0.0, 0.6, 1.0)
	for s: String in ["main", "settings", "hangar"]:
		fe.show_screen(s)
		await frames(10)
		var img := await sc.grab("menu_" + s)
		sc.not_blank(img, panel, "menu %s panel" % s)
		sc.not_blank(img, stage, "menu %s mech preview" % s)
		sc.differs(img, panel, stage, "menu %s" % s)
	# Accent colours: the settings picker with blue picked (the preview mech in blue), then two crew mechs in the bay in
	# different accents (teal, pink), each against the default orange look.
	fe.show_screen("settings")
	await frames(2)
	(fe.accent_picks["blue"] as Button).pressed.emit()
	await frames(10)
	var picker := await sc.grab("menu_accent_picker")
	sc.not_blank(picker, stage, "accent picker preview")
	fe.show_screen("hangar")
	fe.stage.show_mechs([{"head": "chicken", "name": "Green", "accent": "green"}, {"head": "dog", "name": "Purple", "accent": "purple"}], true)
	await frames(10)
	var two := await sc.grab("menu_accent_crew")
	sc.not_blank(two, stage, "two accents in the bay")
	Session.set_profile(Session.player_name, Session.local_head(), Session.local_chassis(), "orange")
	GameSettings.set_value("accent", "orange")
	fe.show_screen("hangar")
	await frames(5)
	# The hangar bay's launch alert (beacons, strobes, clamps open): it must look different from prep.
	var prep := await sc.grab("menu_hangar_prep")
	fe.stage.set_alert(true)
	await frames(90)
	var alert := await sc.grab("menu_hangar_alert")
	sc.not_blank(alert, stage, "hangar alert bay")
	if prep != null and alert != null:
		var dm := absf(float(ShotCheck.stats(prep, stage)["mean"]) - float(ShotCheck.stats(alert, stage)["mean"]))
		check(dm > 0.02, "the bay's alert lighting differs from prep (mean luminance delta %.3f)" % dm)
	fe.queue_free()
	await frames(2)

	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	var ui := Rect2(0.0, 0.0, 0.22, 1.0)         # the 380 px side panel
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	for id: String in LabRegistry.ids():
		lab.pick(id)
		await frames(30)
		var img := await sc.grab("lab_" + id)
		sc.not_blank(img, ui, "lab %s panel" % id)
		sc.not_blank(img, view, "lab %s 3D view" % id)
	lab.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()
