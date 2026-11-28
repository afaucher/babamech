extends TestCase
## VISUAL: the mech HUD draws. Two shots in test_logs/shots/: `hud_demo` (fixed sample data over a plain backdrop:
## every state at once, including the crew panel's three demo teammates and the mission layer's objective line and
## extraction waypoint, two revealed-enemy markers (one stuck to the right edge) and the "last hostiles
## marked" line), `hud_demo_banner` (the same plus the MISSION COMPLETE end banner) and `hud_drive` (the live test
## drive: your mech, its weapon rack and heat, the objective line).
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
	# The objectives are one panel top right since 2026-11-23 (the top-centre strip is gone; test_layout checks the place).
	sc.not_blank(img, Rect2(0.78, 0.045, 0.2, 0.06), "HUD objective panel (top right)")
	check(hud.mission_hud.list_panel.visible and hud.mission_hud.list_panel.get_global_rect().position.x > 800.0,
		"the objective panel shows, in the right half")
	# A destroyed mounted part (the demo's left-shoulder rocket pod, R2.14): drawn dark with a red outline, no cross.
	eq(float(hud.components().get("shoulder_l", 1.0)), 0.0, "the demo has a destroyed mounted part (shoulder_l)")
	hud.mission_hud.demo_banner = true
	await frames(4)
	var img2 := await sc.grab("hud_demo_banner")
	sc.not_blank(img2, Rect2(0.32, 0.29, 0.36, 0.11), "HUD end banner")
	hud.queue_free()
	bg.queue_free()
	await frames(2)

	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(60)
	img = await sc.grab("hud_drive")
	sc.not_blank(img, Rect2(0.0, 0.6, 0.22, 0.4), "drive HUD status corner")
	sc.not_blank(img, Rect2(0.72, 0.6, 0.28, 0.4), "drive HUD weapon rows")
	check(td.mission != null and str(td.mission.hud_model.build()["objective"]) != "", "the drive has an objective line")
	td.queue_free()
	await frames(2)
	finish()
