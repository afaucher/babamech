extends TestCase
## VISUAL: the nine mech damage diagram options (scripts/ui/hangar/mech_diagram.gd: view front / side / three x style geometric /
## traced / schematic), each inside the real status panel frame (MechDiagram.paint_frame: glass, heat arc, THRUST,
## HEAT 46%) at the HUD's bottom-left spot and size (MechHud.STATUS_SIZE), with demo damage: leg_l amber, shoulder_r
## destroyed, the rest healthy. Saves test_logs/shots/diagram_<view>_<style>.png cropped to the panel plus a margin.
## Runs only under `.\test_runner.ps1 -Visual` (hidden desktop, takes the GPU lock).

const VISUAL := true
const PAD := 10

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_mech_diagram needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var bg := ColorRect.new()
	bg.color = Color(0.32, 0.36, 0.4)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport().get_visible_rect().size
	var panel_pos := Vector2(MechHud.MARGIN, vp.y - MechHud.MARGIN - MechHud.STATUS_SIZE.y)
	for v: String in MechDiagram.VIEWS:
		for s: String in MechDiagram.STYLES:
			var frame := Control.new()
			frame.position = panel_pos
			frame.size = MechHud.STATUS_SIZE
			frame.draw.connect(func() -> void: MechDiagram.paint_frame(frame, frame.size, 0.46, 100.0, "THRUST"))
			add_child(frame)
			var d := MechDiagram.new()
			d.view = v
			d.style = s
			d.mounted = MechDiagram.DEMO_LOADOUT.duplicate()
			d.health = MechDiagram.DEMO_HEALTH.duplicate()
			frame.add_child(d)
			d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			await frames(3)
			var img := await sc.grab("diagram_frame_last")
			var r := Rect2i(Vector2i(panel_pos) - Vector2i(PAD, PAD), Vector2i(MechHud.STATUS_SIZE) + Vector2i(PAD * 2, PAD * 2))
			r = r.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
			var crop := img.get_region(r)
			var path := ProjectSettings.globalize_path("%s/diagram_%s_%s.png" % [ShotCheck.SHOT_DIR, v, s])
			crop.save_png(path)
			print("shot %s" % path)
			sc.not_blank(crop, Rect2(0.2, 0.1, 0.6, 0.6), "diagram %s / %s" % [v, s])
			frame.queue_free()
			await frames(2)
	bg.queue_free()
	finish()
