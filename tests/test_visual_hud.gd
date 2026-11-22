extends TestCase
## VISUAL: the mech HUD draws. Two shots in test_logs/shots/: `hud_demo` (fixed sample data over a plain backdrop:
## every state at once, including the crew panel's three demo teammates) and `hud_drive` (the live test drive: your
## mech, its weapon rack and heat).
## Runs only under `.\test_runner.ps1 -Visual` (hidden desktop, takes the GPU lock).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_hud needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var bg := ColorRect.new()
	bg.color = Color(0.32, 0.36, 0.4)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var hud := MechHud.new()
	hud.demo = true
	add_child(hud)
	await frames(10)
	var img := await sc.grab("hud_demo")
	sc.not_blank(img, Rect2(0.0, 0.6, 0.22, 0.4), "HUD status corner")
	sc.not_blank(img, Rect2(0.72, 0.6, 0.28, 0.4), "HUD weapon rows")
	check(hud.crew_panel.visible and hud.crew_panel.cards.size() == 3, "demo crew panel shows three teammates")
	sc.not_blank(img, Rect2(0.0, 0.38, 0.21, 0.28), "HUD crew panel (above the status corner)")
	hud.queue_free()
	bg.queue_free()
	await frames(2)

	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(60)
	img = await sc.grab("hud_drive")
	sc.not_blank(img, Rect2(0.0, 0.6, 0.22, 0.4), "drive HUD status corner")
	sc.not_blank(img, Rect2(0.72, 0.6, 0.28, 0.4), "drive HUD weapon rows")
	td.queue_free()
	await frames(2)
	finish()
